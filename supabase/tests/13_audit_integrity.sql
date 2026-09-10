-- Pengujian migrasi 0014: angka audit malam tidak bisa berbohong.
-- Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id', '{"full_name":"Driver Satu"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order, stock_quantity) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'LAKNAT - Kelapa Kacang Nikmat', 15000, 'smoothie', 1, 100);

INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== Muat gerobak 4 cup, driver menjual 1 ==='
SELECT public.save_morning_allocation(
  '11111111-1111-1111-1111-111111111111',
  (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
  '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","initial_quantity":4}]'::jsonb
) IS NOT NULL AS dimuat;

SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
BEGIN
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb);
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 1. Angka mustahil DITOLAK, bukan dikunci ==='
-- Persis bentuk data yang ditemukan di lapangan: dibawa 4, terjual 3,
-- sisa fisik 4. Tujuh cup dipertanggungjawabkan dari empat yang dibawa.
SET test.uid = '22222222-2222-2222-2222-222222222222';
DO $$
DECLARE v_alloc UUID; v_msg TEXT; v_status TEXT;
BEGIN
  SELECT id INTO v_alloc FROM public.driver_daily_allocations;

  -- Admin mencatat sisa fisik 4 (seolah belum ada yang terjual saat dihitung).
  UPDATE public.driver_allocation_items
     SET physical_remaining = 4, waste_quantity = 0
   WHERE allocation_id = v_alloc;

  BEGIN
    PERFORM public.lock_reconciliation(v_alloc, 'audit malam');
    RAISE EXCEPTION 'GAGAL: angka mustahil berhasil dikunci';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'AUDIT_NUMBERS_IMPOSSIBLE:%' THEN
      RAISE EXCEPTION 'GAGAL: pesan = %', v_msg;
    END IF;
  END;

  SELECT status INTO v_status FROM public.driver_daily_allocations WHERE id = v_alloc;
  IF v_status = 'reconciled' THEN
    RAISE EXCEPTION 'GAGAL: alokasi terkunci walau angkanya ditolak';
  END IF;

  RAISE NOTICE 'OK: AUDIT_NUMBERS_IMPOSSIBLE — dibawa 4 tidak bisa jadi terjual 1 + sisa 4';
END;
$$;

\echo ''
\echo '=== 2. Setelah angkanya dibetulkan, penguncian berjalan ==='
DO $$
DECLARE v_alloc UUID; v_stock INTEGER;
BEGIN
  SELECT id INTO v_alloc FROM public.driver_daily_allocations;

  UPDATE public.driver_allocation_items
     SET physical_remaining = 3
   WHERE allocation_id = v_alloc;

  PERFORM public.lock_reconciliation(v_alloc, 'audit malam');

  IF (SELECT status FROM public.driver_daily_allocations WHERE id = v_alloc) <> 'reconciled' THEN
    RAISE EXCEPTION 'GAGAL: tidak terkunci';
  END IF;

  -- Muat 4, terjual 1, sisa 3 kembali ke stok: 100 - 4 + 3 = 99.
  SELECT stock_quantity INTO v_stock FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_stock <> 99 THEN RAISE EXCEPTION 'GAGAL: stok = %, harusnya 99', v_stock; END IF;

  RAISE NOTICE 'OK: 1 + 3 = 4 cocok, terkunci, dan 3 cup kembali ke stok';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 3. Penjualan setelah hari dikunci DITOLAK ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v_msg TEXT; v_orders_before INTEGER; v_orders_after INTEGER; v_stock_before INTEGER;
BEGIN
  SELECT count(*) INTO v_orders_before FROM public.orders;
  SELECT stock_quantity INTO v_stock_before FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';

  BEGIN
    PERFORM public.create_order(
      'cccccccc-0000-0000-0000-000000000001'::uuid,
      '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":2}]'::jsonb);
    RAISE EXCEPTION 'GAGAL: penjualan diterima setelah audit dikunci';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg <> 'DAY_RECONCILED' THEN
      RAISE EXCEPTION 'GAGAL: pesan = %, harusnya DAY_RECONCILED', v_msg;
    END IF;
  END;

  SELECT count(*) INTO v_orders_after FROM public.orders;
  IF v_orders_after <> v_orders_before THEN
    RAISE EXCEPTION 'GAGAL: pesanan tetap tersimpan (% -> %)', v_orders_before, v_orders_after;
  END IF;

  IF (SELECT stock_quantity FROM public.products
       WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001') <> v_stock_before THEN
    RAISE EXCEPTION 'GAGAL: stok bergerak walau pesanan ditolak';
  END IF;

  RAISE NOTICE 'OK: DAY_RECONCILED — tidak ada pesanan siluman sesudah kunci';
END;
$$;

\echo ''
\echo '=== 4. Setelah kunci dibuka, penjualan diterima lagi ==='
SET test.uid = '22222222-2222-2222-2222-222222222222';
UPDATE public.driver_daily_allocations SET status = 'active';
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v_sold INTEGER;
BEGIN
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb);

  SELECT sold_quantity INTO v_sold FROM public.driver_allocation_items;
  IF v_sold <> 2 THEN RAISE EXCEPTION 'GAGAL: terjual = %, harusnya 2', v_sold; END IF;
  RAISE NOTICE 'OK: hari dibuka lagi, penjualan tercatat dan memotong muatan seperti biasa';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 5. Penguncian menyegarkan angka terjual dari transaksi ==='
SET test.uid = '22222222-2222-2222-2222-222222222222';
DO $$
DECLARE v_alloc UUID; v_sold INTEGER;
BEGIN
  SELECT id INTO v_alloc FROM public.driver_daily_allocations;

  -- Meniru cuplikan yang tertinggal: angka terjual dipaksa mundur ke 1,
  -- padahal transaksi sebenarnya sudah 2 cup.
  UPDATE public.driver_allocation_items
     SET sold_quantity = 1, physical_remaining = 2, waste_quantity = 0
   WHERE allocation_id = v_alloc;

  PERFORM public.lock_reconciliation(v_alloc, 'audit ulang');

  SELECT sold_quantity INTO v_sold FROM public.driver_allocation_items
   WHERE allocation_id = v_alloc;
  IF v_sold <> 2 THEN
    RAISE EXCEPTION 'GAGAL: terjual terkunci di %, harusnya disegarkan jadi 2', v_sold;
  END IF;
  RAISE NOTICE 'OK: yang dibekukan kebenaran saat penguncian, bukan angka layar yang basi';
END;
$$;

\echo ''
\echo '=== 6. Selisih ke arah kehilangan tetap boleh dikunci ==='
DO $$
DECLARE v_alloc UUID;
BEGIN
  -- Cup hilang adalah kejadian nyata; justru harus tercatat, bukan ditolak.
  UPDATE public.driver_daily_allocations SET status = 'active';
  SELECT id INTO v_alloc FROM public.driver_daily_allocations;

  UPDATE public.driver_allocation_items
     SET physical_remaining = 0, waste_quantity = 0, returned_quantity = NULL
   WHERE allocation_id = v_alloc;

  -- Dibawa 4, terjual 2, sisa 0, rusak 0 -> 2 cup hilang.
  PERFORM public.lock_reconciliation(v_alloc, 'dua cup hilang di jalan');

  IF (SELECT status FROM public.driver_daily_allocations WHERE id = v_alloc) <> 'reconciled' THEN
    RAISE EXCEPTION 'GAGAL: kehilangan ikut ditolak';
  END IF;
  RAISE NOTICE 'OK: 2 cup hilang tetap bisa dikunci — itu kenyataan yang perlu tercatat';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 7. Penolakan tidak meninggalkan angka terjual setengah jalan ==='
DO $$
DECLARE v_alloc UUID; v_sold_before INTEGER; v_sold_after INTEGER;
BEGIN
  UPDATE public.driver_daily_allocations SET status = 'active';
  SELECT id INTO v_alloc FROM public.driver_daily_allocations;

  UPDATE public.driver_allocation_items
     SET sold_quantity = 1, physical_remaining = 99, waste_quantity = 0
   WHERE allocation_id = v_alloc;
  SELECT sold_quantity INTO v_sold_before FROM public.driver_allocation_items;

  BEGIN
    PERFORM public.lock_reconciliation(v_alloc);
    RAISE EXCEPTION 'GAGAL: sisa 99 dari 4 cup diterima';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;

  -- Penyegaran terjadi di dalam pemanggilan yang gagal itu. Karena seluruh
  -- fungsi berjalan dalam satu transaksi, penolakan harus mengembalikannya.
  SELECT sold_quantity INTO v_sold_after FROM public.driver_allocation_items;
  IF v_sold_after <> v_sold_before THEN
    RAISE EXCEPTION 'GAGAL: sold_quantity berubah % -> % pada penguncian yang ditolak',
      v_sold_before, v_sold_after;
  END IF;
  RAISE NOTICE 'OK: penolakan tidak menyisakan perubahan apa pun';
END;
$$;

RESET ROLE;
\echo ''
\echo '=== SEMUA UJI 13 LULUS ==='
