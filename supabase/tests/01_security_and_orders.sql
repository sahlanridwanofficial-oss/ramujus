-- Pengujian perilaku migrasi 0001. Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

-- Supabase memberi hak tabel ke role authenticated secara default.
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- ---------- data uji ----------
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'driver@ramu.id',
   '{"full_name":"Driver Satu","role":"admin"}'::jsonb),   -- sengaja klaim admin
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id',
   '{"full_name":"Admin Asli"}'::jsonb);

-- Admin dipromosikan manual (jalur sah).
UPDATE public.profiles SET role = 'admin'
 WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Jus Mangga', 15000, 'smoothie', 1),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'Jus Alpukat', 20000, 'smoothie', 2);

\echo ''
\echo '=== TES 1: signUp tidak boleh menentukan peran sendiri ==='
SELECT role AS peran_driver_setelah_signup
  FROM public.profiles WHERE id = '11111111-1111-1111-1111-111111111111';

-- ---------- masuk sebagai driver ----------
SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '=== TES 2: driver menaikkan dirinya jadi admin (harus DITOLAK) ==='
DO $$
BEGIN
  UPDATE public.profiles SET role = 'admin' WHERE id = auth.uid();
  RAISE EXCEPTION 'GAGAL: eskalasi peran berhasil!';
EXCEPTION
  WHEN insufficient_privilege THEN
    -- Harus ditolak oleh guard aplikasi, bukan karena kekurangan hak lain
    -- pada harness (mis. "permission denied for schema auth").
    IF SQLERRM NOT LIKE '%FORBIDDEN_ROLE_CHANGE%' THEN
      RAISE EXCEPTION 'GAGAL: ditolak karena sebab lain, bukan guard: %', SQLERRM;
    END IF;
    RAISE NOTICE 'OK ditolak oleh guard: %', SQLERRM;
END;
$$;

\echo ''
\echo '=== TES 3: driver mengubah nama sendiri (harus BOLEH) ==='
UPDATE public.profiles SET full_name = 'Driver Satu Edit' WHERE id = auth.uid();
SELECT full_name FROM public.profiles WHERE id = auth.uid();

-- ---------- alokasi dibuat admin ----------
RESET ROLE;
INSERT INTO public.driver_daily_allocations (id, driver_id, date)
VALUES ('bbbbbbbb-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        (now() AT TIME ZONE 'Asia/Jakarta')::date);

INSERT INTO public.driver_allocation_items (allocation_id, product_id, initial_quantity)
VALUES ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 10),
       ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', 4);

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '=== TES 4: driver mengecilkan initial_quantity (harus DITOLAK) ==='
DO $$
DECLARE n INTEGER;
BEGIN
  UPDATE public.driver_allocation_items SET initial_quantity = 1
   WHERE product_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n > 0 THEN
    RAISE EXCEPTION 'GAGAL: driver berhasil mengubah % baris muatan!', n;
  END IF;
  RAISE NOTICE 'OK ditolak: RLS tidak mengizinkan UPDATE (0 baris terpengaruh)';
END;
$$;

\echo ''
\echo '=== TES 5: create_order tanpa shift aktif (harus DITOLAK) ==='
DO $$
BEGIN
  PERFORM public.create_order(
    '99999999-9999-9999-9999-999999999999'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb);
  RAISE EXCEPTION 'GAGAL: pesanan dibuat tanpa shift aktif!';
EXCEPTION
  WHEN sqlstate '22023' THEN RAISE NOTICE 'OK ditolak: %', SQLERRM;
END;
$$;

-- Mulai shift.
INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

\echo ''
\echo '=== TES 6: shift aktif kedua untuk driver yang sama (harus DITOLAK) ==='
DO $$
BEGIN
  INSERT INTO public.shifts (driver_id, status)
  VALUES ('11111111-1111-1111-1111-111111111111', 'active');
  RAISE EXCEPTION 'GAGAL: shift aktif kedua diterima!';
EXCEPTION
  WHEN unique_violation THEN RAISE NOTICE 'OK ditolak: shift aktif ganda dicegah indeks unik';
END;
$$;

\echo ''
\echo '=== TES 7: pesanan normal — total dihitung server ==='
SELECT order_number, total_amount
  FROM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":2},
      {"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":1}]'::jsonb,
    'cash', -6.2088, 106.8456, 12.5);

\echo '--- item pesanan tersimpan ---'
SELECT p.name, oi.quantity, oi.unit_price, oi.subtotal
  FROM public.order_items oi JOIN public.products p ON p.id = oi.product_id
 ORDER BY p.name;

\echo '--- stok gerobak berkurang otomatis ---'
SELECT p.name, i.initial_quantity, i.sold_quantity,
       i.initial_quantity - i.sold_quantity AS sisa
  FROM public.driver_allocation_items i
  JOIN public.products p ON p.id = i.product_id
 ORDER BY p.name;

\echo '--- log lokasi tercatat ---'
SELECT count(*) AS jumlah_log_lokasi FROM public.location_logs;

\echo ''
\echo '=== TES 8: stok tidak cukup — harus ditolak DAN tidak meninggalkan pesanan separuh ==='
DO $$
DECLARE v_orders_before INTEGER;
BEGIN
  SELECT count(*) INTO v_orders_before FROM public.orders;
  BEGIN
    PERFORM public.create_order(
      'cccccccc-0000-0000-0000-000000000001'::uuid,
      '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":99}]'::jsonb);
    RAISE EXCEPTION 'GAGAL: pesanan melebihi stok diterima!';
  EXCEPTION
    WHEN sqlstate '22023' THEN
      RAISE NOTICE 'OK ditolak: %', SQLERRM;
  END;
  IF (SELECT count(*) FROM public.orders) <> v_orders_before THEN
    RAISE EXCEPTION 'GAGAL: pesanan gagal meninggalkan baris orders yatim!';
  END IF;
  RAISE NOTICE 'OK: tidak ada pesanan separuh yang tertinggal (rollback bekerja)';
END;
$$;

\echo ''
\echo '=== TES 9: driver lain tidak bisa memakai shift milik orang lain ==='
RESET ROLE;
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('33333333-3333-3333-3333-333333333333', 'driver2@ramu.id', '{"full_name":"Driver Dua"}'::jsonb);
SET ROLE authenticated;
SET test.uid = '33333333-3333-3333-3333-333333333333';
DO $$
BEGIN
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb);
  RAISE EXCEPTION 'GAGAL: driver lain memakai shift bukan miliknya!';
EXCEPTION
  WHEN sqlstate '22023' THEN RAISE NOTICE 'OK ditolak: %', SQLERRM;
END;
$$;

RESET ROLE;
\echo ''
\echo '=== RINGKASAN AKHIR ==='
SELECT (SELECT count(*) FROM public.orders)      AS pesanan,
       (SELECT count(*) FROM public.order_items) AS item_pesanan,
       (SELECT sum(total_amount) FROM public.orders) AS total_rupiah;
