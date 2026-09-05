-- Pengujian migrasi 0004: profil pembeli. Bukan bagian aplikasi.
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
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Jus Mangga', 15000, 'smoothie', 1),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'Jus Alpukat', 20000, 'smoothie', 2);

INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '=== TES 1: pesanan dengan profil pembeli ==='
SELECT customer_gender, customer_age_range, customer_type
  FROM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
    'cash', NULL, NULL, NULL, NULL, NULL, NULL,
    'female', 'teen', 'new');

\echo ''
\echo '=== TES 2: profil boleh dikosongkan seluruhnya ==='
SELECT (customer_gender IS NULL AND customer_age_range IS NULL AND customer_type IS NULL)
         AS profil_kosong_diterima
  FROM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
    'cash');

\echo ''
\echo '=== TES 3: nilai profil ngawur DIABAIKAN, penjualan tetap tersimpan ==='
DO $$
DECLARE v_gender TEXT; v_total INTEGER;
BEGIN
  SELECT customer_gender, total_amount INTO v_gender, v_total
    FROM public.create_order(
      'cccccccc-0000-0000-0000-000000000001'::uuid,
      '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
      'cash', NULL, NULL, NULL, NULL, NULL, NULL,
      'alien', 'balita', 'vip');

  IF v_gender IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: nilai ngawur tersimpan sebagai %', v_gender;
  END IF;
  IF v_total <> 15000 THEN
    RAISE EXCEPTION 'GAGAL: penjualan ikut rusak, total %', v_total;
  END IF;
  RAISE NOTICE 'OK: profil ngawur diabaikan, penjualan tetap tercatat Rp%', v_total;
END;
$$;

\echo ''
\echo '=== TES 4: constraint database menolak nilai di luar daftar ==='
RESET ROLE;
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT id INTO v_id FROM public.orders ORDER BY created_at LIMIT 1;
  UPDATE public.orders SET customer_gender = 'robot' WHERE id = v_id;
  RAISE EXCEPTION 'GAGAL: constraint tidak bekerja, nilai ngawur diterima!';
EXCEPTION
  WHEN check_violation THEN
    RAISE NOTICE 'OK ditolak constraint: %', SQLERRM;
END;
$$;

\echo ''
\echo '=== TES 5: data uji untuk laporan ==='
SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE
  genders TEXT[] := ARRAY['male','female'];
  ages    TEXT[] := ARRAY['kid','teen','young_adult','adult','senior'];
  types   TEXT[] := ARRAY['new','returning'];
  i INTEGER;
BEGIN
  FOR i IN 1..40 LOOP
    PERFORM public.create_order(
      'cccccccc-0000-0000-0000-000000000001'::uuid,
      jsonb_build_array(jsonb_build_object(
        'product_id', (ARRAY['aaaaaaaa-0000-0000-0000-000000000001',
                             'aaaaaaaa-0000-0000-0000-000000000002'])[1 + (i % 2)],
        'quantity', 1)),
      'cash', NULL, NULL, NULL, NULL, NULL, NULL,
      genders[1 + (i % 2)], ages[1 + (i % 5)], types[1 + (i % 2)]);
  END LOOP;
END;
$$;

SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo '--- sebaran pembeli ---'
SELECT dimension, bucket, orders, revenue
  FROM public.admin_customer_insights(30)
 ORDER BY dimension, bucket;

\echo '--- jam ramai per kelompok usia (5 teratas) ---'
SELECT hour, age_range, orders FROM public.admin_customer_hourly(30)
 ORDER BY orders DESC, age_range LIMIT 5;

\echo '--- produk favorit per gender ---'
SELECT bucket, product_name, total_qty
  FROM public.admin_products_by_segment(30)
 WHERE dimension = 'gender'
 ORDER BY bucket, total_qty DESC;

\echo ''
\echo '=== TES 6: transaksi tanpa profil terlihat sebagai unknown ==='
DO $$
DECLARE v_unknown INTEGER;
BEGIN
  SELECT orders INTO v_unknown
    FROM public.admin_customer_insights(30)
   WHERE dimension = 'gender' AND bucket = 'unknown';

  IF COALESCE(v_unknown, 0) < 2 THEN
    RAISE EXCEPTION 'GAGAL: pesanan tanpa profil tidak terhitung sebagai unknown (dapat %)', v_unknown;
  END IF;
  RAISE NOTICE 'OK: % transaksi tanpa profil terlihat jelas sebagai unknown', v_unknown;
END;
$$;

\echo ''
\echo '=== TES 7: driver tidak boleh membaca laporan pembeli ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.admin_customer_insights(30);
  IF n > 0 THEN
    RAISE EXCEPTION 'GAGAL: driver mendapat % baris laporan pembeli!', n;
  END IF;
  RAISE NOTICE 'OK: laporan pembeli kosong untuk driver';
END;
$$;
