-- Pengujian perilaku migrasi 0002 (pelacakan armada). Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- ---------- data uji ----------
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id', '{"full_name":"Driver Satu"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb),
  ('33333333-3333-3333-3333-333333333333', 'd2@ramu.id', '{"full_name":"Driver Dua"}'::jsonb);

UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'Jus Mangga', 15000, 'smoothie', 1);

\echo ''
\echo '=== TES 1: kirim posisi tanpa shift aktif (harus DITOLAK) ==='
SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
BEGIN
  PERFORM public.update_driver_position(-6.2088, 106.8456);
  RAISE EXCEPTION 'GAGAL: posisi diterima tanpa shift aktif!';
EXCEPTION
  WHEN sqlstate '22023' THEN RAISE NOTICE 'OK ditolak: %', SQLERRM;
END;
$$;

-- Mulai shift.
INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

\echo ''
\echo '=== TES 2: koordinat di luar rentang bumi (harus DITOLAK) ==='
DO $$
BEGIN
  PERFORM public.update_driver_position(999, 106.8456);
  RAISE EXCEPTION 'GAGAL: lintang 999 diterima!';
EXCEPTION
  WHEN sqlstate '22023' THEN RAISE NOTICE 'OK ditolak: %', SQLERRM;
END;
$$;

\echo ''
\echo '=== TES 3: kirim posisi pertama ==='
SELECT latitude, longitude, accuracy FROM public.update_driver_position(-6.2088, 106.8456, 12.5);
SELECT count(*) AS baris_posisi FROM public.driver_positions;
SELECT count(*) AS baris_histori FROM public.location_logs;

\echo ''
\echo '=== TES 4: 20 kiriman berikutnya — posisi ditimpa, histori DIBATASI ==='
DO $$
DECLARE i INTEGER;
BEGIN
  FOR i IN 1..20 LOOP
    -- interval histori 120 detik, jadi kiriman beruntun tidak boleh menambah histori
    PERFORM public.update_driver_position(-6.2088 + i * 0.0001, 106.8456, 10);
  END LOOP;
END;
$$;

SELECT count(*) AS baris_posisi_setelah_21_kiriman FROM public.driver_positions;
SELECT count(*) AS baris_histori_setelah_21_kiriman FROM public.location_logs;

DO $$
DECLARE v_pos INTEGER; v_log INTEGER;
BEGIN
  SELECT count(*) INTO v_pos FROM public.driver_positions;
  SELECT count(*) INTO v_log FROM public.location_logs;
  IF v_pos <> 1 THEN
    RAISE EXCEPTION 'GAGAL: driver_positions harus tetap 1 baris, dapat %', v_pos;
  END IF;
  IF v_log <> 1 THEN
    RAISE EXCEPTION 'GAGAL: histori harus tetap 1 baris karena dibatasi interval, dapat %', v_log;
  END IF;
  RAISE NOTICE 'OK: 21 kiriman -> 1 baris posisi, 1 baris histori';
END;
$$;

\echo ''
\echo '=== TES 5: histori bertambah setelah melewati ambang interval ==='
-- Mundurkan histori 5 menit untuk meniru waktu berjalan.
RESET ROLE;
UPDATE public.location_logs SET recorded_at = NOW() - INTERVAL '5 minutes';
SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';
SELECT latitude FROM public.update_driver_position(-6.21, 106.85, 8) LIMIT 1;
DO $$
DECLARE v_log INTEGER;
BEGIN
  SELECT count(*) INTO v_log FROM public.location_logs;
  IF v_log <> 2 THEN
    RAISE EXCEPTION 'GAGAL: histori seharusnya 2 baris, dapat %', v_log;
  END IF;
  RAISE NOTICE 'OK: histori bertambah setelah ambang terlewati (2 baris)';
END;
$$;

\echo ''
\echo '=== TES 6: driver tidak bisa memalsukan posisi lewat tabel langsung ==='
DO $$
DECLARE n INTEGER;
BEGIN
  UPDATE public.driver_positions SET latitude = 0, longitude = 0;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n > 0 THEN
    RAISE EXCEPTION 'GAGAL: driver mengubah % baris posisi langsung!', n;
  END IF;
  RAISE NOTICE 'OK ditolak: tidak ada policy UPDATE (0 baris terpengaruh)';
END;
$$;

\echo ''
\echo '=== TES 7: driver tidak bisa melihat posisi driver lain ==='
RESET ROLE;
INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000002',
        '33333333-3333-3333-3333-333333333333', 'active');
SET ROLE authenticated;
SET test.uid = '33333333-3333-3333-3333-333333333333';
SELECT latitude FROM public.update_driver_position(-6.30, 106.90, 9) LIMIT 1;
DO $$
DECLARE n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.driver_positions;
  IF n <> 1 THEN
    RAISE EXCEPTION 'GAGAL: driver melihat % baris posisi, seharusnya hanya miliknya (1)', n;
  END IF;
  RAISE NOTICE 'OK: driver hanya melihat posisinya sendiri';
END;
$$;

\echo ''
\echo '=== TES 8: driver TIDAK boleh memanggil fleet_overview ==='
DO $$
DECLARE n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.fleet_overview();
  IF n > 0 THEN
    RAISE EXCEPTION 'GAGAL: driver mendapat % baris dari fleet_overview!', n;
  END IF;
  RAISE NOTICE 'OK: fleet_overview kosong untuk non-admin';
END;
$$;

\echo ''
\echo '=== TES 9: admin melihat seluruh armada dalam SATU query ==='
SET test.uid = '22222222-2222-2222-2222-222222222222';
SELECT full_name, round(latitude::numeric, 4) AS lat, round(longitude::numeric, 4) AS lng,
       on_shift, orders_today, revenue_today,
       (seconds_since IS NOT NULL) AS punya_posisi
  FROM public.fleet_overview()
 ORDER BY full_name;

\echo ''
\echo '=== TES 10: admin_driver_stats menggantikan pola N+1 ==='
RESET ROLE;
INSERT INTO public.orders (shift_id, driver_id, order_number, total_amount, payment_method)
VALUES ('cccccccc-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','RMJ-T-1', 30000,'cash'),
       ('cccccccc-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','RMJ-T-2', 15000,'qris');
SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';
SELECT p.full_name, s.total_orders, s.total_revenue, s.orders_today, s.has_active_shift
  FROM public.admin_driver_stats() s
  JOIN public.profiles p ON p.id = s.driver_id
 ORDER BY p.full_name;

\echo ''
\echo '=== TES 11: pemangkasan histori lokasi ==='
RESET ROLE;
INSERT INTO public.location_logs (driver_id, shift_id, latitude, longitude, recorded_at)
VALUES ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000001',
        -6.2, 106.8, NOW() - INTERVAL '200 days');
SELECT public.prune_location_logs(60) AS baris_lama_dihapus;
SELECT count(*) AS histori_tersisa FROM public.location_logs;

\echo ''
\echo '=== TES 12: peta armada terbaca dari indeks, bukan pemindaian penuh ==='
EXPLAIN (COSTS OFF)
SELECT * FROM public.location_logs
 WHERE driver_id = '11111111-1111-1111-1111-111111111111'
 ORDER BY recorded_at DESC LIMIT 1;
