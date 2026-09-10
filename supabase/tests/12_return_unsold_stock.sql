-- Pengujian migrasi 0013: sisa cup kembali ke stok pusat saat audit malam.
-- Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id', '{"full_name":"Driver Satu"}'::jsonb),
  ('33333333-3333-3333-3333-333333333333', 'd2@ramu.id', '{"full_name":"Driver Dua"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order, stock_quantity) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Jus Mangga', 15000, 'smoothie', 1, 100);

INSERT INTO public.shifts (id, driver_id, status) VALUES
  ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'active'),
  ('cccccccc-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333', 'active');

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

-- ------------------------------------------------------------
\echo ''
\echo '=== 1. Muat gerobak 50 cup: stok pusat 100 -> 50 (perilaku lama, tetap) ==='
SELECT public.save_morning_allocation(
  '11111111-1111-1111-1111-111111111111',
  (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
  '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","initial_quantity":50}]'::jsonb
) IS NOT NULL AS alokasi_dibuat;

DO $$
DECLARE v_stock INTEGER;
BEGIN
  SELECT stock_quantity INTO v_stock FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_stock <> 50 THEN RAISE EXCEPTION 'GAGAL: stok = %, harusnya 50', v_stock; END IF;
  RAISE NOTICE 'OK: stok pusat 100 -> 50 setelah muat gerobak';
END;
$$;

\echo ''
\echo '=== Driver menjual 42 cup ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
BEGIN
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":42}]'::jsonb);
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 2. Audit malam TANPA mengisi apa pun: seluruh sisa fisik kembali ==='
-- Inti perilaku otomatis: admin hanya mencatat sisa fisik dan cup rusak,
-- lalu mengunci. returned_quantity dibiarkan NULL — tidak disentuh sama
-- sekali — dan keenam cup sisa tetap kembali ke stok pusat.
SET test.uid = '22222222-2222-2222-2222-222222222222';
UPDATE public.driver_allocation_items
   SET physical_remaining = 6, waste_quantity = 2
 WHERE allocation_id = (SELECT id FROM public.driver_daily_allocations
                         WHERE driver_id = '11111111-1111-1111-1111-111111111111');

DO $$
DECLARE v_ret INTEGER;
BEGIN
  SELECT returned_quantity INTO v_ret FROM public.driver_allocation_items
   WHERE allocation_id = (SELECT id FROM public.driver_daily_allocations
                           WHERE driver_id = '11111111-1111-1111-1111-111111111111');
  IF v_ret IS NOT NULL THEN
    RAISE EXCEPTION 'Prasyarat uji salah: returned_quantity = %, harusnya NULL', v_ret;
  END IF;
END;
$$;

DO $$
DECLARE v_alloc UUID; v_stock INTEGER; v_mv INTEGER; v_flag TIMESTAMPTZ;
BEGIN
  SELECT id INTO v_alloc FROM public.driver_daily_allocations
   WHERE driver_id = '11111111-1111-1111-1111-111111111111';

  PERFORM public.lock_reconciliation(v_alloc, 'audit malam');

  SELECT stock_quantity INTO v_stock FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_stock <> 56 THEN
    RAISE EXCEPTION 'GAGAL: stok = %, harusnya 56 (50 + 6 sisa fisik)', v_stock;
  END IF;

  SELECT count(*) INTO v_mv FROM public.stock_movements
   WHERE reason = 'allocation_return' AND reference_id = v_alloc AND delta = 6;
  IF v_mv <> 1 THEN RAISE EXCEPTION 'GAGAL: pergerakan allocation_return = % baris', v_mv; END IF;

  SELECT stock_returned_at INTO v_flag FROM public.driver_daily_allocations WHERE id = v_alloc;
  IF v_flag IS NULL THEN RAISE EXCEPTION 'GAGAL: penanda pengembalian tidak tercatat'; END IF;

  RAISE NOTICE 'OK: 6 cup kembali otomatis (50 -> 56) tanpa admin mengisi apa pun';
END;
$$;

\echo ''
\echo '=== 3. Cup rusak TIDAK ikut kembali ==='
DO $$
DECLARE v_stock INTEGER;
BEGIN
  SELECT stock_quantity INTO v_stock FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  -- Dibawa 50, laku 42, sisa fisik 6, rusak 2. Yang kembali hanya 6.
  -- Kalau cup rusak ikut terhitung, angkanya jadi 58.
  IF v_stock = 58 THEN
    RAISE EXCEPTION 'GAGAL: cup rusak ikut dikembalikan ke stok';
  END IF;
  IF v_stock <> 56 THEN RAISE EXCEPTION 'GAGAL: stok = %', v_stock; END IF;
  RAISE NOTICE 'OK: 2 cup rusak tetap di luar stok — hanya sisa fisik yang kembali';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 4. Buka kunci membalik pengembalian (56 -> 50) ==='
DO $$
DECLARE v_alloc UUID; v_stock INTEGER; v_flag TIMESTAMPTZ; v_mv INTEGER;
BEGIN
  SELECT id INTO v_alloc FROM public.driver_daily_allocations
   WHERE driver_id = '11111111-1111-1111-1111-111111111111';

  UPDATE public.driver_daily_allocations SET status = 'active' WHERE id = v_alloc;

  SELECT stock_quantity INTO v_stock FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_stock <> 50 THEN RAISE EXCEPTION 'GAGAL: stok = %, harusnya 50 lagi', v_stock; END IF;

  SELECT stock_returned_at INTO v_flag FROM public.driver_daily_allocations WHERE id = v_alloc;
  IF v_flag IS NOT NULL THEN RAISE EXCEPTION 'GAGAL: penanda pengembalian tidak dihapus'; END IF;

  SELECT count(*) INTO v_mv FROM public.stock_movements
   WHERE reference_id = v_alloc AND delta = -6 AND reason = 'adjustment';
  IF v_mv <> 1 THEN RAISE EXCEPTION 'GAGAL: pembatalan tidak tercatat di jejak'; END IF;

  RAISE NOTICE 'OK: stok kembali 50 dan pembatalannya tercatat, bukan menghilang diam-diam';
END;
$$;

\echo ''
\echo '=== 5. Kunci ulang menghitung sekali, bukan dua kali ==='
DO $$
DECLARE v_alloc UUID; v_stock INTEGER;
BEGIN
  SELECT id INTO v_alloc FROM public.driver_daily_allocations
   WHERE driver_id = '11111111-1111-1111-1111-111111111111';

  PERFORM public.lock_reconciliation(v_alloc, 'audit malam ulang');

  SELECT stock_quantity INTO v_stock FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_stock = 62 THEN RAISE EXCEPTION 'GAGAL: pengembalian terhitung dua kali (62)'; END IF;
  IF v_stock <> 56 THEN RAISE EXCEPTION 'GAGAL: stok = %, harusnya 56', v_stock; END IF;
  RAISE NOTICE 'OK: buka-kunci-lalu-kunci-lagi tetap 56 — tidak ada cup yang terhitung dua kali';
END;
$$;

\echo ''
\echo '=== 6. Mengunci yang sudah terkunci tetap ditolak ==='
DO $$
DECLARE v_alloc UUID; v_stock_before INTEGER; v_stock_after INTEGER;
BEGIN
  SELECT id INTO v_alloc FROM public.driver_daily_allocations
   WHERE driver_id = '11111111-1111-1111-1111-111111111111';
  SELECT stock_quantity INTO v_stock_before FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';

  BEGIN
    PERFORM public.lock_reconciliation(v_alloc);
    RAISE EXCEPTION 'GAGAL: penguncian kedua diterima';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  SELECT stock_quantity INTO v_stock_after FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_stock_after <> v_stock_before THEN
    RAISE EXCEPTION 'GAGAL: stok bergerak % -> % pada penguncian yang ditolak',
      v_stock_before, v_stock_after;
  END IF;
  RAISE NOTICE 'OK: penguncian kedua ditolak dan tidak menyentuh stok';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 7. Mengembalikan lebih banyak dari sisa fisik ditolak ==='
DO $$
DECLARE v_alloc UUID; v_stock_before INTEGER; v_stock_after INTEGER; v_msg TEXT;
BEGIN
  -- Gerobak kedua: bawa 20, laku 0, sisa fisik 20, tetapi admin salah
  -- mengetik 25 sebagai jumlah yang diseal ulang.
  PERFORM public.save_morning_allocation(
    '33333333-3333-3333-3333-333333333333',
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","initial_quantity":20}]'::jsonb);

  SELECT id INTO v_alloc FROM public.driver_daily_allocations
   WHERE driver_id = '33333333-3333-3333-3333-333333333333';

  UPDATE public.driver_allocation_items
     SET physical_remaining = 20, returned_quantity = 25
   WHERE allocation_id = v_alloc;

  SELECT stock_quantity INTO v_stock_before FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';

  BEGIN
    PERFORM public.lock_reconciliation(v_alloc);
    RAISE EXCEPTION 'GAGAL: pengembalian melebihi sisa fisik diterima';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'RETURN_EXCEEDS_REMAINING:%' THEN
      RAISE EXCEPTION 'GAGAL: pesan = %', v_msg;
    END IF;
  END;

  SELECT stock_quantity INTO v_stock_after FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_stock_after <> v_stock_before THEN
    RAISE EXCEPTION 'GAGAL: stok bergerak walau penguncian ditolak';
  END IF;

  IF (SELECT status FROM public.driver_daily_allocations WHERE id = v_alloc) = 'reconciled' THEN
    RAISE EXCEPTION 'GAGAL: alokasi terkunci walau ditolak';
  END IF;

  RAISE NOTICE 'OK: RETURN_EXCEEDS_REMAINING, stok tidak bergerak, alokasi tidak terkunci';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 8. Membuka kunci ditolak bila cup-nya sudah dimuat ke gerobak lain ==='
DO $$
DECLARE v_alloc1 UUID; v_alloc2 UUID; v_stock INTEGER; v_msg TEXT; v_status TEXT;
BEGIN
  SELECT id INTO v_alloc1 FROM public.driver_daily_allocations
   WHERE driver_id = '11111111-1111-1111-1111-111111111111';
  SELECT id INTO v_alloc2 FROM public.driver_daily_allocations
   WHERE driver_id = '33333333-3333-3333-3333-333333333333';

  -- Rapikan gerobak kedua lalu habiskan stok pusat ke gerobak itu.
  UPDATE public.driver_allocation_items
     SET returned_quantity = 0, physical_remaining = 0
   WHERE allocation_id = v_alloc2;

  SELECT stock_quantity INTO v_stock FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';

  PERFORM public.save_morning_allocation(
    '33333333-3333-3333-3333-333333333333',
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    format('[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","initial_quantity":%s}]',
           20 + v_stock)::jsonb);

  SELECT stock_quantity INTO v_stock FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_stock <> 0 THEN RAISE EXCEPTION 'Prasyarat uji salah: stok = %', v_stock; END IF;

  BEGIN
    UPDATE public.driver_daily_allocations SET status = 'active' WHERE id = v_alloc1;
    RAISE EXCEPTION 'GAGAL: kunci dibuka walau cup-nya sudah dipakai gerobak lain';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'UNLOCK_STOCK_UNAVAILABLE:%' THEN
      RAISE EXCEPTION 'GAGAL: pesan = %', v_msg;
    END IF;
  END;

  SELECT status INTO v_status FROM public.driver_daily_allocations WHERE id = v_alloc1;
  IF v_status <> 'reconciled' THEN
    RAISE EXCEPTION 'GAGAL: alokasi ikut terbuka walau pembalikannya gagal (%)', v_status;
  END IF;

  SELECT stock_quantity INTO v_stock FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_stock <> 0 THEN RAISE EXCEPTION 'GAGAL: stok jadi % — sempat negatif/berubah', v_stock; END IF;

  RAISE NOTICE 'OK: ditolak dengan sebab jelas, kunci tetap utuh, stok tidak dipaksa negatif';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 9. Tanpa pengembalian, stok tidak bergerak sama sekali ==='
DO $$
DECLARE v_alloc UUID; v_before INTEGER; v_after INTEGER; v_mv INTEGER;
BEGIN
  SELECT id INTO v_alloc FROM public.driver_daily_allocations
   WHERE driver_id = '33333333-3333-3333-3333-333333333333';

  SELECT stock_quantity INTO v_before FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  SELECT count(*) INTO v_mv FROM public.stock_movements;

  PERFORM public.lock_reconciliation(v_alloc, 'tanpa pengembalian');

  SELECT stock_quantity INTO v_after FROM public.products
   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_after <> v_before THEN RAISE EXCEPTION 'GAGAL: stok % -> %', v_before, v_after; END IF;
  IF (SELECT count(*) FROM public.stock_movements) <> v_mv THEN
    RAISE EXCEPTION 'GAGAL: ada pergerakan stok kosong yang tercatat';
  END IF;
  RAISE NOTICE 'OK: tanpa sisa fisik, tidak ada pergerakan stok kosong yang tercatat';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 10. Driver tidak boleh mengunci maupun mengubah angka pengembalian ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v_alloc UUID; v_ret INTEGER;
BEGIN
  SELECT id INTO v_alloc FROM public.driver_daily_allocations
   WHERE driver_id = '33333333-3333-3333-3333-333333333333';

  BEGIN
    PERFORM public.lock_reconciliation(v_alloc);
    RAISE EXCEPTION 'GAGAL: driver berhasil mengunci rekonsiliasi';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- Policy UPDATE untuk driver sudah dicabut sejak 0001; perubahan tidak
  -- ditolak dengan galat, melainkan tidak mengenai baris apa pun.
  UPDATE public.driver_allocation_items SET returned_quantity = 99
   WHERE allocation_id = v_alloc;

  SET LOCAL test.uid = '22222222-2222-2222-2222-222222222222';
  SELECT max(returned_quantity) INTO v_ret FROM public.driver_allocation_items
   WHERE allocation_id = v_alloc;
  IF v_ret = 99 THEN RAISE EXCEPTION 'GAGAL: driver mengubah angka pengembalian'; END IF;

  RAISE NOTICE 'OK: penguncian dan angka pengembalian tertutup untuk driver';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 11. admin_pending_returns: cup yang menunggu keputusan terlihat ==='
SET test.uid = '22222222-2222-2222-2222-222222222222';
DO $$
DECLARE v_alloc UUID; n INTEGER; v_pending INTEGER;
BEGIN
  -- Gerobak ketiga yang masih terbuka, sisa fisik 9, belum diputuskan.
  PERFORM public.save_morning_allocation(
    '11111111-1111-1111-1111-111111111111',
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","initial_quantity":0}]'::jsonb);

  SELECT id INTO v_alloc FROM public.driver_daily_allocations
   WHERE driver_id = '11111111-1111-1111-1111-111111111111'
     AND date = (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1;

  UPDATE public.driver_allocation_items
     SET physical_remaining = 9, returned_quantity = 0
   WHERE allocation_id = v_alloc;

  SELECT pending_cups INTO v_pending FROM public.admin_pending_returns()
   WHERE product_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_pending <> 9 THEN
    RAISE EXCEPTION 'GAGAL: menunggu keputusan = %, harusnya 9', v_pending;
  END IF;

  SET LOCAL test.uid = '11111111-1111-1111-1111-111111111111';
  SELECT count(*) INTO n FROM public.admin_pending_returns();
  IF n <> 0 THEN RAISE EXCEPTION 'GAGAL: driver melihat % baris', n; END IF;

  RAISE NOTICE 'OK: 9 cup menunggu keputusan terlihat admin, tertutup untuk driver';
END;
$$;

RESET ROLE;
\echo ''
\echo '=== SEMUA UJI 12 LULUS ==='
