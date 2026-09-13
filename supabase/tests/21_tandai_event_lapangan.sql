-- Pengujian migrasi 0027: penandaan event dipasang driver di lapangan.
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
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'KPK', 13000, 'smoothie', 1, 900, true);

INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '=== 1. Mangkal biasa tetap bukan event ==='
DO $$
DECLARE v public.driver_stops;
BEGIN
  v := public.driver_start_stop(-6.2900, 106.8580, 10, NULL);
  IF v.is_event THEN
    RAISE EXCEPTION 'GAGAL: mangkal biasa ikut ditandai event';
  END IF;
  PERFORM public.driver_end_stop();
  RAISE NOTICE 'OK: mangkal biasa bersih';
END;
$$;

\echo ''
\echo '=== 2. Booth event ditandai sejak ketukan pertama ==='
-- Inilah yang menutup lubang 0023: penandaannya tidak lagi bergantung
-- pada ada tidaknya orang yang ingat memberitahu admin belakangan.
DO $$
DECLARE v public.driver_stops;
BEGIN
  v := public.driver_start_stop(-6.3700, 106.9200, 10, NULL, true);
  IF NOT v.is_event THEN
    RAISE EXCEPTION 'GAGAL: booth event tidak tertandai saat dibuka';
  END IF;
  RAISE NOTICE 'OK: ditandai event sejak awal, bukan koreksi belakangan';
END;
$$;

\echo ''
\echo '=== 3. Salah tekan bisa dibalik TANPA merusak lama mangkal ==='
-- Menutup lalu membuka ulang akan memotong jam mangkalnya. Yang dibalik
-- harus penandanya, bukan mangkalnya.
DO $$
DECLARE v public.driver_stops; v_id UUID; v_mulai TIMESTAMPTZ;
BEGIN
  SELECT id, started_at INTO v_id, v_mulai
    FROM public.driver_stops
   WHERE driver_id = '11111111-1111-1111-1111-111111111111' AND ended_at IS NULL;

  v := public.driver_tandai_event_sekarang(false);
  IF v.is_event THEN
    RAISE EXCEPTION 'GAGAL: penanda tidak bisa dicabut';
  END IF;

  v := public.driver_tandai_event_sekarang(true);
  IF NOT v.is_event THEN
    RAISE EXCEPTION 'GAGAL: penanda tidak bisa dipasang ulang';
  END IF;

  IF v.id <> v_id OR v.started_at <> v_mulai THEN
    RAISE EXCEPTION 'GAGAL: mangkalnya ikut berubah — lama mangkal rusak';
  END IF;

  RAISE NOTICE 'OK: penanda bisa dibalik-balik, mangkalnya tetap yang sama';
END;
$$;

\echo ''
\echo '=== 4. Layar driver bisa melihat keadaannya ==='
-- Tanpa ini salah tekan tidak pernah terlihat oleh drivernya sendiri.
DO $$
DECLARE rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.driver_current_stop();
  IF rec.id IS NULL THEN
    RAISE EXCEPTION 'GAGAL: mangkal berjalan tidak terbaca';
  END IF;
  IF NOT rec.is_event THEN
    RAISE EXCEPTION 'GAGAL: driver_current_stop tidak melaporkan penanda event';
  END IF;
  RAISE NOTICE 'OK: aplikasi bisa menampilkan bahwa ini booth event';
END;
$$;

\echo ''
\echo '=== 5. Aplikasi versi lama (4 argumen) tetap bisa membuka mangkal ==='
-- PWA tersimpan di ponsel driver. Kalau tanda tangannya tidak cocok,
-- setiap ketukan "Mangkal di sini" gagal sampai ponselnya memuat ulang.
DO $$
DECLARE v public.driver_stops;
BEGIN
  v := public.driver_start_stop(
    p_latitude       => -6.2950,
    p_longitude      => 106.8600,
    p_accuracy       => 12,
    p_client_stop_id => gen_random_uuid());
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'GAGAL: aplikasi versi lama ditolak — driver tidak bisa mangkal';
  END IF;
  IF v.is_event THEN
    RAISE EXCEPTION 'GAGAL: aplikasi lama menghasilkan mangkal bertanda event';
  END IF;
  RAISE NOTICE 'OK: aplikasi versi lama tetap jalan, dan hasilnya bukan event';
END;
$$;

\echo ''
\echo '=== 6. Hanya ada SATU driver_start_stop ==='
DO $$
DECLARE v INTEGER;
BEGIN
  SELECT count(*) INTO v FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'driver_start_stop';
  IF v <> 1 THEN
    RAISE EXCEPTION 'GAGAL: ada % fungsi driver_start_stop, harusnya 1', v;
  END IF;
  RAISE NOTICE 'OK: tidak ada kembaran yang membingungkan PostgREST';
END;
$$;

\echo ''
\echo '=== 7. Penjualan di booth event benar-benar keluar dari peta ==='
RESET ROLE;
DO $$
DECLARE v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1;
        v_jam  TIMESTAMPTZ; v_order UUID;
BEGIN
  v_jam := (v_hari::timestamp + INTERVAL '13 hours') AT TIME ZONE 'Asia/Jakarta';

  -- Titik jalanan biasa: 2 cup dalam 2 jam.
  INSERT INTO public.driver_stops (driver_id, started_at, ended_at, latitude, longitude, is_event)
  VALUES ('11111111-1111-1111-1111-111111111111',
          v_jam - INTERVAL '3 hours', v_jam - INTERVAL '1 hour', -6.2900, 106.8580, false);

  FOR i IN 0..1 LOOP
    v_order := gen_random_uuid();
    INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount,
                               payment_method, latitude, longitude, created_at)
    VALUES (v_order, 'cccccccc-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'RMJ-JALAN-' || i, 13000, 'cash', -6.2900, 106.8580,
            v_jam - INTERVAL '3 hours' + (i * INTERVAL '1 hour'));
    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
    VALUES (v_order, 'aaaaaaaa-0000-0000-0000-000000000001', 1, 13000, 13000);
  END LOOP;

  -- Booth event: 40 cup dalam 2 jam = 20 cup/jam.
  INSERT INTO public.driver_stops (driver_id, started_at, ended_at, latitude, longitude, is_event)
  VALUES ('11111111-1111-1111-1111-111111111111',
          v_jam, v_jam + INTERVAL '2 hours', -6.3700, 106.9200, true);

  FOR i IN 0..3 LOOP
    v_order := gen_random_uuid();
    INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount,
                               payment_method, latitude, longitude, created_at)
    VALUES (v_order, 'cccccccc-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'RMJ-EVENT-' || i, 130000, 'cash', -6.3700, 106.9200,
            v_jam + (i * INTERVAL '20 minutes'));
    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
    VALUES (v_order, 'aaaaaaaa-0000-0000-0000-000000000001', 10, 13000, 130000);
  END LOOP;
END;
$$;

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

SELECT round(cluster_lat::numeric,4) AS lat, cups, cups_per_hour, dwell_source
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
  IF rec.cups <> 2 THEN
    RAISE EXCEPTION 'GAGAL: % cup di peta, harusnya 2 dari titik jalanan saja', rec.cups;
  END IF;

  RAISE NOTICE 'OK: 40 cup booth event tidak muncul; peta hanya memuat 2 cup jalanan';
END;
$$;

\echo ''
\echo '=== 8. Admin bisa MELIHAT apa yang dikeluarkan, bukan mempercayainya ==='
-- Penyaring yang bekerja diam-diam tidak bisa dipercaya, karena tidak ada
-- yang tahu kalau ia salah. Inilah jendela untuk memeriksanya.
SELECT driver_name, jam, cups, omzet
  FROM public.admin_mangkal_event(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1);

DO $$
DECLARE rec RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1;
BEGIN
  SELECT * INTO rec FROM public.admin_mangkal_event(v_hari, v_hari);

  IF rec.stop_id IS NULL THEN
    RAISE EXCEPTION 'GAGAL: mangkal event tidak terlihat oleh admin';
  END IF;
  IF rec.cups <> 40 THEN
    RAISE EXCEPTION 'GAGAL: % cup dilaporkan, harusnya 40', rec.cups;
  END IF;
  IF rec.omzet <> 520000 THEN
    RAISE EXCEPTION 'GAGAL: omzet %, harusnya 520000', rec.omzet;
  END IF;
  IF abs(rec.jam - 2.0) > 0.01 THEN
    RAISE EXCEPTION 'GAGAL: jam %, harusnya 2.0', rec.jam;
  END IF;

  RAISE NOTICE 'OK: admin melihat persis 40 cup / Rp520.000 yang dikeluarkan dari peta';
END;
$$;

\echo ''
\echo '=== 9. Driver tidak bisa membaca daftar mangkal event ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v INTEGER;
BEGIN
  SELECT count(*) INTO v FROM public.admin_mangkal_event(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 7,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date);
  IF v <> 0 THEN
    RAISE EXCEPTION 'GAGAL: driver mendapat % baris laporan admin', v;
  END IF;
  RAISE NOTICE 'OK: driver tidak mendapat satu pun baris';
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0027 LULUS ==='
