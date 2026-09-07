-- Pengujian migrasi 0008: status akun benar-benar menolak. Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id', '{"full_name":"Driver Satu"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Jus Mangga', 15000, 'smoothie', 1);

-- Muatan gerobak hari ini, supaya penolakan bisa dibuktikan tidak memotong stok.
INSERT INTO public.driver_daily_allocations (id, driver_id, date, status)
VALUES ('bbbbbbbb-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        (NOW() AT TIME ZONE 'Asia/Jakarta')::date, 'allocated');
INSERT INTO public.driver_allocation_items (allocation_id, product_id, initial_quantity, sold_quantity)
VALUES ('bbbbbbbb-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000001', 50, 0);

SET ROLE authenticated;

-- ------------------------------------------------------------
\echo ''
\echo '=== 1. Akun aktif: shift terbuka dan penjualan tercatat (garis dasar) ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');
DO $$
BEGIN
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":2}]'::jsonb);
  RAISE NOTICE 'OK: driver aktif berhasil membuka shift dan menjual 2 cup';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 2. Admin menonaktifkan driver ==='
SET test.uid = '22222222-2222-2222-2222-222222222222';
UPDATE public.profiles SET status = 'inactive'
 WHERE id = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE s TEXT;
BEGIN
  SELECT public.get_user_status('11111111-1111-1111-1111-111111111111') INTO s;
  IF s <> 'inactive' THEN RAISE EXCEPTION 'GAGAL: status = %, harusnya inactive', s; END IF;
  RAISE NOTICE 'OK: status tersimpan sebagai inactive';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 3. Driver nonaktif TIDAK bisa membuka shift baru ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
BEGIN
  -- Shift lama ditutup dulu, supaya yang menolak adalah status akun,
  -- bukan aturan "satu shift aktif per driver".
  UPDATE public.shifts SET status = 'completed', end_time = NOW()
   WHERE id = 'cccccccc-0000-0000-0000-000000000001';

  BEGIN
    INSERT INTO public.shifts (id, driver_id, status)
    VALUES ('cccccccc-0000-0000-0000-000000000002',
            '11111111-1111-1111-1111-111111111111', 'active');
    RAISE EXCEPTION 'GAGAL: driver nonaktif berhasil membuka shift baru';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    RAISE NOTICE 'OK: policy RLS menolak shift baru untuk akun nonaktif';
  END;
END;
$$;

\echo ''
\echo '=== 4. Menutup shift sendiri tetap boleh (tidak ada shift menggantung) ==='
DO $$
DECLARE s TEXT;
BEGIN
  SELECT status INTO s FROM public.shifts
   WHERE id = 'cccccccc-0000-0000-0000-000000000001';
  IF s <> 'completed' THEN
    RAISE EXCEPTION 'GAGAL: driver nonaktif tidak dapat menutup shift-nya (status %)', s;
  END IF;
  RAISE NOTICE 'OK: shift lama dapat ditutup walau akun sudah nonaktif';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 5. Shift yang masih aktif pun tidak menolong: create_order menolak ==='
RESET ROLE;
-- Dibuka lagi sebagai pemilik tabel, meniru shift yang sudah berjalan
-- sebelum penonaktifan.
UPDATE public.shifts SET status = 'active', end_time = NULL
 WHERE id = 'cccccccc-0000-0000-0000-000000000001';
SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v_orders_before INTEGER; v_orders_after INTEGER;
        v_sold_before INTEGER;   v_sold_after INTEGER;
        v_msg TEXT;
BEGIN
  SELECT count(*) INTO v_orders_before FROM public.orders;
  SELECT sold_quantity INTO v_sold_before FROM public.driver_allocation_items
   WHERE allocation_id = 'bbbbbbbb-0000-0000-0000-000000000001';

  BEGIN
    PERFORM public.create_order(
      'cccccccc-0000-0000-0000-000000000001'::uuid,
      '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":3}]'::jsonb);
    RAISE EXCEPTION 'GAGAL: driver nonaktif berhasil mencatat pesanan';
  EXCEPTION WHEN SQLSTATE '28000' THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg <> 'ACCOUNT_INACTIVE' THEN
      RAISE EXCEPTION 'GAGAL: kode error = %, harusnya ACCOUNT_INACTIVE', v_msg;
    END IF;
  END;

  SELECT count(*) INTO v_orders_after FROM public.orders;
  SELECT sold_quantity INTO v_sold_after FROM public.driver_allocation_items
   WHERE allocation_id = 'bbbbbbbb-0000-0000-0000-000000000001';

  IF v_orders_after <> v_orders_before THEN
    RAISE EXCEPTION 'GAGAL: pesanan bertambah dari % ke %', v_orders_before, v_orders_after;
  END IF;
  IF v_sold_after <> v_sold_before THEN
    RAISE EXCEPTION 'GAGAL: stok terpotong dari % ke %', v_sold_before, v_sold_after;
  END IF;

  RAISE NOTICE 'OK: ACCOUNT_INACTIVE, tanpa pesanan separuh dan tanpa stok terpotong';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 6. Driver tidak bisa mengaktifkan dirinya sendiri kembali ==='
DO $$
BEGIN
  BEGIN
    UPDATE public.profiles SET status = 'active'
     WHERE id = '11111111-1111-1111-1111-111111111111';
    RAISE EXCEPTION 'GAGAL: driver berhasil mengaktifkan dirinya sendiri';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK: FORBIDDEN_STATUS_CHANGE — hanya admin yang boleh';
  END;
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 7. Diaktifkan kembali oleh admin: penjualan berjalan lagi ==='
SET test.uid = '22222222-2222-2222-2222-222222222222';
UPDATE public.profiles SET status = 'active'
 WHERE id = '11111111-1111-1111-1111-111111111111';

SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v_sold INTEGER;
BEGIN
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":3}]'::jsonb);

  SELECT sold_quantity INTO v_sold FROM public.driver_allocation_items
   WHERE allocation_id = 'bbbbbbbb-0000-0000-0000-000000000001';
  IF v_sold <> 5 THEN
    RAISE EXCEPTION 'GAGAL: terjual = %, harusnya 5 (2 + 3)', v_sold;
  END IF;
  RAISE NOTICE 'OK: setelah diaktifkan lagi, penjualan tercatat dan stok terpotong (5 cup)';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 8. Akun admin tidak ikut terkunci oleh aturan ini ==='
SET test.uid = '22222222-2222-2222-2222-222222222222';
DO $$
DECLARE n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.admin_daily_summary();
  IF n <> 1 THEN RAISE EXCEPTION 'GAGAL: admin kehilangan akses ringkasan'; END IF;
  RAISE NOTICE 'OK: admin tetap membaca ringkasan seperti biasa';
END;
$$;

RESET ROLE;
\echo ''
\echo '=== SEMUA UJI 09 LULUS ==='
