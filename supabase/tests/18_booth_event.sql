-- Pengujian migrasi 0023: booth event keluar dari analitik lokasi.
-- Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id',    '{"full_name":"Gerobak Satu"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order, stock_quantity, is_available)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'PASUTRI', 13000, 'smoothie', 1, 9000, true);

INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

-- Dua hari, dua tempat:
--   * kemarin  — titik jalanan biasa, 4 cup dalam 4 jam  = 1,0 cup/jam
--   * kemarin  — booth kampus,        60 cup dalam 4 jam = 15,0 cup/jam
-- Tanpa 0023, kampus tampil sebagai lokasi terbaik yang pernah terukur
-- dan mengalahkan titik nyata 15 kali lipat.
DO $$
DECLARE v_hari  DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1;
        v_pagi  TIMESTAMPTZ;
        v_sore  TIMESTAMPTZ;
        v_order UUID;
BEGIN
  v_pagi := (v_hari::timestamp + INTERVAL '10 hours') AT TIME ZONE 'Asia/Jakarta';
  v_sore := (v_hari::timestamp + INTERVAL '15 hours') AT TIME ZONE 'Asia/Jakarta';

  -- Titik jalanan biasa.
  INSERT INTO public.driver_stops (id, driver_id, started_at, ended_at, latitude, longitude)
  VALUES ('eeeeeeee-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111',
          v_pagi, v_pagi + INTERVAL '4 hours', -6.2900, 106.8580);

  FOR i IN 0..3 LOOP
    v_order := gen_random_uuid();
    INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount,
                               payment_method, latitude, longitude, created_at)
    VALUES (v_order, 'cccccccc-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'RMJ-JALAN-' || i, 13000, 'cash', -6.2900, 106.8580,
            v_pagi + (i * INTERVAL '1 hour'));
    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
    VALUES (v_order, 'aaaaaaaa-0000-0000-0000-000000000001', 1, 13000, 13000);
  END LOOP;

  -- Booth kampus, jauh dari titik jalanan supaya jadi petak sendiri.
  INSERT INTO public.driver_stops (id, driver_id, started_at, ended_at, latitude, longitude, is_event)
  VALUES ('eeeeeeee-0000-0000-0000-000000000002',
          '11111111-1111-1111-1111-111111111111',
          v_sore, v_sore + INTERVAL '4 hours', -6.3700, 106.9200, true);

  -- 30 transaksi x 2 cup = 60 cup.
  FOR i IN 0..29 LOOP
    v_order := gen_random_uuid();
    INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount,
                               payment_method, latitude, longitude, created_at)
    VALUES (v_order, 'cccccccc-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'RMJ-EVENT-' || i, 26000, 'cash', -6.3700, 106.9200,
            v_sore + (i * INTERVAL '8 minutes'));
    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
    VALUES (v_order, 'aaaaaaaa-0000-0000-0000-000000000001', 2, 13000, 26000);
  END LOOP;
END;
$$;

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== 1. Booth event tidak muncul sama sekali di analitik lokasi ==='
SELECT round(cluster_lat::numeric,4) AS lat, cups, hours_measured, cups_per_hour, dwell_source
  FROM public.admin_location_clusters(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1, 300);

DO $$
DECLARE v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1;
        v_baris INTEGER; rec RECORD;
BEGIN
  SELECT count(*) INTO v_baris FROM public.admin_location_clusters(v_hari, v_hari, 300);
  IF v_baris <> 1 THEN
    RAISE EXCEPTION 'GAGAL: % petak, harusnya 1 — booth event ikut terhitung', v_baris;
  END IF;

  SELECT * INTO rec FROM public.admin_location_clusters(v_hari, v_hari, 300);

  -- Kalau yang lolos adalah petak kampus, lat-nya -6.37 dan cup-nya 60.
  IF round(rec.cluster_lat::numeric, 2) <> -6.29 THEN
    RAISE EXCEPTION 'GAGAL: petak yang lolos di lat %, harusnya titik jalanan -6.29',
                    round(rec.cluster_lat::numeric, 2);
  END IF;
  IF rec.cups <> 4 THEN
    RAISE EXCEPTION 'GAGAL: % cup, harusnya 4 dari titik jalanan saja', rec.cups;
  END IF;
  IF abs(rec.cups_per_hour - 1.0) > 0.01 THEN
    RAISE EXCEPTION 'GAGAL: laju %, harusnya 1.0 — bukan 15,0 dari kampus', rec.cups_per_hour;
  END IF;

  RAISE NOTICE 'OK: kampus 15 cup/jam tidak muncul; yang tersisa titik jalanan 1,0 cup/jam';
END;
$$;

\echo ''
\echo '=== 2. Uangnya TIDAK hilang — omset dan cup tetap utuh ==='
-- Yang dibuang hanya anggapan bahwa tempat itu bisa disewa, bukan
-- penjualannya. 4 + 60 = 64 cup, 52.000 + 780.000 = 832.000.
DO $$
DECLARE v_cup INTEGER; v_omset BIGINT;
        v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1;
BEGIN
  SELECT COALESCE(sum(oi.quantity), 0), COALESCE(sum(oi.subtotal), 0)
    INTO v_cup, v_omset
    FROM public.orders o JOIN public.order_items oi ON oi.order_id = o.id
   WHERE o.created_at >= public.wib_day_start(v_hari)
     AND o.created_at <  public.wib_day_start(v_hari + 1);

  IF v_cup <> 64 THEN
    RAISE EXCEPTION 'GAGAL: % cup, harusnya 64 — penjualan event ikut terbuang', v_cup;
  END IF;
  IF v_omset <> 832000 THEN
    RAISE EXCEPTION 'GAGAL: omset %, harusnya 832000', v_omset;
  END IF;

  RAISE NOTICE 'OK: 64 cup / Rp832.000 tetap utuh — yang dibuang hanya petaknya';
END;
$$;

\echo ''
\echo '=== 3. Tanpa penanda, kampus MEMANG merebut peta (bukti penyaringnya bekerja) ==='
-- Tes yang membuktikan tes 1 punya gigi: lepaskan penandanya sebentar,
-- kampus langsung muncul sebagai titik terkuat.
RESET ROLE;
UPDATE public.driver_stops SET is_event = false
 WHERE id = 'eeeeeeee-0000-0000-0000-000000000002';

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

DO $$
DECLARE v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1; rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_location_clusters(v_hari, v_hari, 300)
   ORDER BY cups DESC LIMIT 1;

  IF rec.cups <> 60 THEN
    RAISE EXCEPTION 'GAGAL: tanpa penanda kampus harusnya muncul dengan 60 cup, dapat %', rec.cups;
  END IF;
  IF rec.cups_per_hour < 10 THEN
    RAISE EXCEPTION 'GAGAL: tanpa penanda kampus harusnya >10 cup/jam, dapat %', rec.cups_per_hour;
  END IF;

  RAISE NOTICE 'OK: tanpa penanda kampus merebut peta dengan % cup/jam — penyaring 0023 memang yang menahannya',
               rec.cups_per_hour;
END;
$$;

\echo ''
\echo '=== 4. Hanya admin yang boleh memasang penanda ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
BEGIN
  PERFORM public.admin_tandai_mangkal_event('eeeeeeee-0000-0000-0000-000000000002', true);
  RAISE EXCEPTION 'GAGAL: driver berhasil memasang penanda event';
EXCEPTION WHEN sqlstate 'P0001' THEN
  IF SQLERRM LIKE 'GAGAL:%' THEN RAISE; END IF;
  RAISE NOTICE 'OK: driver ditolak (%)', SQLERRM;
END;
$$;

SET test.uid = '22222222-2222-2222-2222-222222222222';
DO $$
DECLARE v public.driver_stops;
BEGIN
  v := public.admin_tandai_mangkal_event('eeeeeeee-0000-0000-0000-000000000002', true);
  IF NOT v.is_event THEN
    RAISE EXCEPTION 'GAGAL: admin memasang penanda tapi tidak tersimpan';
  END IF;
  RAISE NOTICE 'OK: admin bisa memasang penanda, dan petanya bersih lagi';
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0023 LULUS ==='
