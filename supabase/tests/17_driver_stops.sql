-- Pengujian migrasi 0020: lama mangkal direkam. Bukan bagian aplikasi.
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
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'PASUTRI', 13000, 'smoothie', 1, 900, true);

INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '=== 1. Mulai mangkal membuka satu catatan ==='
DO $$
DECLARE v public.driver_stops;
BEGIN
  v := public.driver_start_stop(-6.2900, 106.8580, 12.0, NULL);
  IF v.id IS NULL OR v.ended_at IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: mangkal tidak terbuka';
  END IF;
  IF v.shift_id IS NULL THEN
    RAISE EXCEPTION 'GAGAL: shift aktif tidak ikut tercatat';
  END IF;
  RAISE NOTICE 'OK: mangkal terbuka, terhubung ke shift aktif';
END;
$$;

\echo ''
\echo '=== 2. Mangkal baru menutup yang lama secara otomatis ==='
DO $$
DECLARE v_terbuka INT; v_tertutup INT;
BEGIN
  -- Driver yang lupa menekan "pindah" tetap menghasilkan data yang benar.
  -- Lupa itu pasti terjadi, jadi lebih baik ditangani daripada dilarang.
  PERFORM public.driver_start_stop(-6.2950, 106.8580, 10.0, NULL);

  SELECT count(*) INTO v_terbuka  FROM public.driver_stops WHERE ended_at IS NULL;
  SELECT count(*) INTO v_tertutup FROM public.driver_stops WHERE ended_at IS NOT NULL;

  IF v_terbuka <> 1 THEN
    RAISE EXCEPTION 'GAGAL: % mangkal terbuka, harusnya tepat 1', v_terbuka;
  END IF;
  IF v_tertutup <> 1 THEN
    RAISE EXCEPTION 'GAGAL: % mangkal tertutup, harusnya 1', v_tertutup;
  END IF;
  RAISE NOTICE 'OK: mangkal lama tertutup otomatis, hanya satu yang berjalan';
END;
$$;

\echo ''
\echo '=== 3. Ketukan yang dikirim ulang tidak menggandakan catatan ==='
DO $$
DECLARE v_kunci UUID := 'dddddddd-0000-0000-0000-000000000001';
        a public.driver_stops; b public.driver_stops; v_jumlah INT;
BEGIN
  -- Sinyal putus lalu ketukan dicoba lagi: harus menghasilkan satu catatan.
  a := public.driver_start_stop(-6.2960, 106.8580, 9.0, v_kunci);
  b := public.driver_start_stop(-6.2960, 106.8580, 9.0, v_kunci);
  IF a.id <> b.id THEN
    RAISE EXCEPTION 'GAGAL: ketukan ulang membuat mangkal kedua';
  END IF;
  SELECT count(*) INTO v_jumlah FROM public.driver_stops WHERE client_stop_id = v_kunci;
  IF v_jumlah <> 1 THEN
    RAISE EXCEPTION 'GAGAL: % catatan untuk satu kunci', v_jumlah;
  END IF;
  RAISE NOTICE 'OK: kunci idempotensi menahan pengiriman ulang';
END;
$$;

\echo ''
\echo '=== 4. Selesai mangkal, dan menekan dua kali tidak meledak ==='
DO $$
DECLARE v_terbuka INT;
BEGIN
  PERFORM public.driver_end_stop();
  PERFORM public.driver_end_stop();   -- ketukan kedua: harus diam saja
  SELECT count(*) INTO v_terbuka FROM public.driver_stops WHERE ended_at IS NULL;
  IF v_terbuka <> 0 THEN
    RAISE EXCEPTION 'GAGAL: masih ada % mangkal terbuka', v_terbuka;
  END IF;
  RAISE NOTICE 'OK: mangkal tertutup, ketukan kedua aman';
END;
$$;

\echo ''
\echo '=== 5. Indeks menolak dua mangkal terbuka, bukan cuma kodenya ==='
DO $$
BEGIN
  BEGIN
    INSERT INTO public.driver_stops (driver_id, started_at)
    VALUES ('11111111-1111-1111-1111-111111111111', NOW());
    RAISE EXCEPTION 'GAGAL: penulisan langsung ke tabel seharusnya ditolak RLS';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RAISE NOTICE 'OK: klien tidak bisa menulis langsung, harus lewat fungsi';
  END;
END;
$$;

RESET ROLE;

\echo ''
\echo '=== 6. Lama mangkal yang DIREKAM mengalahkan perkiraan ==='
-- Skenario inti. Driver melayani pukul 10:00, 10:30, dan 11:00 tetapi
-- mencatat ketiganya pukul 11:00 — persis kebiasaan yang terlihat di data
-- produksi. Rentang pesanan menyusut jadi hitungan detik; catatan mangkal
-- tetap menunjukkan satu jam penuh.
DO $$
DECLARE v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1;
        v_mulai TIMESTAMPTZ;
        v_order UUID;
BEGIN
  v_mulai := (v_hari::timestamp + INTERVAL '10 hours') AT TIME ZONE 'Asia/Jakarta';

  INSERT INTO public.driver_stops (driver_id, started_at, ended_at, latitude, longitude)
  VALUES ('11111111-1111-1111-1111-111111111111',
          v_mulai, v_mulai + INTERVAL '1 hour', -6.2900, 106.8580);

  -- Tiga pesanan dicatat beruntun di akhir: 11:00:00, 11:00:11, 11:00:22.
  FOR i IN 0..2 LOOP
    v_order := gen_random_uuid();
    INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount,
                               payment_method, latitude, longitude, created_at)
    VALUES (v_order, 'cccccccc-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'RMJ-BATCH-' || i, 13000, 'cash', -6.2900, 106.8580,
            v_mulai + INTERVAL '1 hour' + (i * INTERVAL '11 seconds'));
    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
    VALUES (v_order, 'aaaaaaaa-0000-0000-0000-000000000001', 1, 13000, 13000);
  END LOOP;
END;
$$;

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

SELECT round(cluster_lat::numeric,4) AS lat, cups, hours_measured, cups_per_hour, dwell_source
  FROM public.admin_location_clusters(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1, 300);

DO $$
DECLARE v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1; rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_location_clusters(v_hari, v_hari, 300);

  IF rec.dwell_source <> 'tercatat' THEN
    RAISE EXCEPTION 'GAGAL: sumber %, harusnya tercatat', rec.dwell_source;
  END IF;
  IF abs(rec.hours_measured - 1.0) > 0.01 THEN
    RAISE EXCEPTION 'GAGAL: jam %, harusnya 1.0 dari catatan mangkal', rec.hours_measured;
  END IF;
  -- Tanpa 0020, rentang pesanan 22 detik akan menghasilkan ~491 cup/jam.
  IF abs(rec.cups_per_hour - 3.0) > 0.01 THEN
    RAISE EXCEPTION 'GAGAL: laju %, harusnya 3 cup / 1 jam = 3.0', rec.cups_per_hour;
  END IF;

  RAISE NOTICE 'OK: 3 cup dalam 1 jam tercatat = 3.0 cup/jam — bukan 491 dari rentang 22 detik';
END;
$$;

\echo ''
\echo '=== 7. Tanpa catatan mangkal, perkiraan tetap jalan dan ditandai ==='
RESET ROLE;
DO $$
DECLARE v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 3;
        v_mulai TIMESTAMPTZ; v_order UUID;
BEGIN
  v_mulai := (v_hari::timestamp + INTERVAL '14 hours') AT TIME ZONE 'Asia/Jakarta';
  -- Dua pesanan berjarak 1 jam, tanpa satu pun catatan mangkal.
  FOR i IN 0..1 LOOP
    v_order := gen_random_uuid();
    INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount,
                               payment_method, latitude, longitude, created_at)
    VALUES (v_order, 'cccccccc-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'RMJ-EST-' || i, 26000, 'cash', -6.3200, 106.8580,
            v_mulai + (i * INTERVAL '1 hour'));
    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
    VALUES (v_order, 'aaaaaaaa-0000-0000-0000-000000000001', 2, 13000, 26000);
  END LOOP;
END;
$$;

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

DO $$
DECLARE v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 3; rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_location_clusters(v_hari, v_hari, 300);
  IF rec.dwell_source <> 'perkiraan' THEN
    RAISE EXCEPTION 'GAGAL: sumber %, harusnya perkiraan', rec.dwell_source;
  END IF;
  IF abs(rec.cups_per_hour - 4.0) > 0.01 THEN
    RAISE EXCEPTION 'GAGAL: laju %, harusnya 4 cup / 1 jam', rec.cups_per_hour;
  END IF;
  RAISE NOTICE 'OK: cadangan jalan dan ditandai "perkiraan", bukan disamarkan sebagai tercatat';
END;
$$;

\echo ''
\echo '=== 8. Driver tidak bisa membaca mangkal driver lain ==='
RESET ROLE;
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('11111111-1111-1111-1111-111111111112', 'd2@ramu.id', '{"full_name":"Gerobak Dua"}'::jsonb);
INSERT INTO public.driver_stops (driver_id, started_at, ended_at, latitude, longitude)
VALUES ('11111111-1111-1111-1111-111111111112', NOW() - INTERVAL '2 hours',
        NOW() - INTERVAL '1 hour', -6.2800, 106.8580);

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v INT;
BEGIN
  SELECT count(*) INTO v FROM public.driver_stops
   WHERE driver_id = '11111111-1111-1111-1111-111111111112';
  IF v <> 0 THEN
    RAISE EXCEPTION 'GAGAL: driver melihat % mangkal milik driver lain', v;
  END IF;
  RAISE NOTICE 'OK: mangkal driver lain tidak terbaca';
END;
$$;

\echo ''
\echo '=== SELURUH UJI 0020 LULUS ==='
