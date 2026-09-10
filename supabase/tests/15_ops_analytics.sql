-- Pengujian migrasi 0016: analitik operasional (jam & lokasi). Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id',    '{"full_name":"Gerobak Satu"}'::jsonb),
  ('11111111-1111-1111-1111-111111111112', 'd2@ramu.id',    '{"full_name":"Gerobak Dua"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order, stock_quantity, is_available) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'PASUTRI', 13000, 'smoothie', 1, 900, true),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'Stevia',   2000, 'addon',    3, 900, true);

INSERT INTO public.shifts (id, driver_id, status) VALUES
  ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'active'),
  ('cccccccc-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111112', 'active');

-- Penolong: satu pesanan berisi n cup PASUTRI pada jam & koordinat tertentu.
CREATE OR REPLACE FUNCTION pg_temp.jual(
  p_driver UUID, p_shift UUID, p_day DATE, p_hour INT, p_cup INT,
  p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION
) RETURNS VOID LANGUAGE plpgsql AS $fn$
DECLARE v_order UUID := gen_random_uuid();
BEGIN
  INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount,
                             payment_method, latitude, longitude, created_at)
  VALUES (v_order, p_shift, p_driver, 'RMJ-' || left(v_order::text, 8),
          p_cup * 13000, 'cash', p_lat, p_lng,
          (p_day::timestamp + make_interval(hours => p_hour)) AT TIME ZONE 'Asia/Jakarta');
  INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
  VALUES (v_order, 'aaaaaaaa-0000-0000-0000-000000000001', p_cup, 13000, p_cup * 13000);
END;
$fn$;

DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
        d1 UUID := '11111111-1111-1111-1111-111111111111';
        s1 UUID := 'cccccccc-0000-0000-0000-000000000001';
BEGIN
  -- ---------------------------------------------------------------
  -- Inti pengujian: jebakan yang membuat migrasi ini ada.
  --
  -- Jam 17 dijalani 4 hari, 2 cup tiap hari  -> total 8 cup
  -- Jam 15 dijalani 2 hari, 2 cup tiap hari  -> total 4 cup
  --
  -- Angka MENTAH bilang jam 17 dua kali lebih baik.
  -- Angka DINORMALKAN bilang keduanya sama persis: 2,0 cup/hari aktif.
  -- ---------------------------------------------------------------
  FOR i IN 0..3 LOOP
    PERFORM pg_temp.jual(d1, s1, v_today - i, 17, 2, -6.2900, 106.8580);
  END LOOP;
  FOR i IN 0..1 LOOP
    PERFORM pg_temp.jual(d1, s1, v_today - i, 15, 2, -6.2900, 106.8580);
  END LOOP;

  -- Lokasi kedua, ~3,3 km ke selatan. Harus jadi kelompok terpisah.
  PERFORM pg_temp.jual(d1, s1, v_today, 12, 5, -6.3200, 106.8580);
  -- Titik ~55 m dari lokasi pertama. Harus MENYATU dengan lokasi pertama.
  PERFORM pg_temp.jual(d1, s1, v_today, 12, 3, -6.2905, 106.8580);

  -- Gerobak Dua, hari ini: 12 cup dalam 2 jam (11:00 & 13:00) = 6 cup/jam.
  -- Gerobak Satu hari ini juga 12 cup (2+2+5+3), tapi dari 12:00 sampai
  -- 17:00 = 5 jam = 2,4 cup/jam. Cup per HARI sama, cup per JAM jauh beda.
  PERFORM pg_temp.jual('11111111-1111-1111-1111-111111111112',
                       'cccccccc-0000-0000-0000-000000000002',
                       v_today, 11, 6, -6.2800, 106.8580);
  PERFORM pg_temp.jual('11111111-1111-1111-1111-111111111112',
                       'cccccccc-0000-0000-0000-000000000002',
                       v_today, 13, 6, -6.2800, 106.8580);

  -- Hari terpisah jauh ke belakang dengan SATU pesanan saja: rentangnya
  -- nol jam, dan tanpa penjepitan akan jadi pembagian dengan nol.
  PERFORM pg_temp.jual(d1, s1, v_today - 20, 14, 3, -6.2900, 106.8580);
END;
$$;

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== Performa per jam pada 4 hari terakhir ==='
SELECT hour_wib, cups, days_active, cups_per_active_day
  FROM public.admin_hourly_performance(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 3,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date)
 ORDER BY hour_wib;

-- ------------------------------------------------------------
\echo ''
\echo '=== 1. Jam "ramai" ternyata cuma jam yang lebih sering dijalani ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
        j17 RECORD; j15 RECORD;
BEGIN
  SELECT * INTO j17 FROM public.admin_hourly_performance(v_today - 3, v_today) WHERE hour_wib = 17;
  SELECT * INTO j15 FROM public.admin_hourly_performance(v_today - 3, v_today) WHERE hour_wib = 15;

  IF j17.cups <> 8 OR j15.cups <> 4 THEN
    RAISE EXCEPTION 'GAGAL total mentah: jam17=%, jam15=%', j17.cups, j15.cups;
  END IF;
  IF j17.days_active <> 4 OR j15.days_active <> 2 THEN
    RAISE EXCEPTION 'GAGAL hari aktif: jam17=%, jam15=%', j17.days_active, j15.days_active;
  END IF;

  -- Inti perbaikannya: setelah dibagi hari aktif, keduanya identik.
  IF j17.cups_per_active_day <> j15.cups_per_active_day THEN
    RAISE EXCEPTION 'GAGAL normalisasi: jam17=% vs jam15=%, seharusnya sama',
      j17.cups_per_active_day, j15.cups_per_active_day;
  END IF;
  IF j17.cups_per_active_day <> 2.0 THEN
    RAISE EXCEPTION 'GAGAL: cup per hari aktif = %, harusnya 2.0', j17.cups_per_active_day;
  END IF;

  RAISE NOTICE 'OK: mentah 8 vs 4 (jam 17 terlihat 2x lebih baik), dinormalkan 2.0 vs 2.0 (sama persis)';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 2. Pembaginya ikut dilaporkan, tidak disembunyikan ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; rec RECORD;
BEGIN
  -- Tanpa kolom days_active, admin tidak bisa tahu bahwa angka "bagus"
  -- berasal dari satu hari saja.
  SELECT * INTO rec FROM public.admin_hourly_performance(v_today - 3, v_today) WHERE hour_wib = 12;
  IF rec.days_active <> 1 THEN
    RAISE EXCEPTION 'GAGAL: jam 12 hari aktif = %, harusnya 1', rec.days_active;
  END IF;
  IF rec.cups <> 8 OR rec.cups_per_active_day <> 8.0 THEN
    RAISE EXCEPTION 'GAGAL jam 12: cup=%, per hari=%', rec.cups, rec.cups_per_active_day;
  END IF;
  RAISE NOTICE 'OK: jam 12 tampak 8.0 cup/hari, tapi days_active=1 membuka bahwa itu dari 1 hari saja';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 3. Titik berdekatan menyatu, titik jauh terpisah ==='
SELECT round(cluster_lat::numeric, 4) AS lat, cups, orders, days_active, best_hour
  FROM public.admin_location_clusters(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 3,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date, 300)
 ORDER BY cups DESC;

DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
        v_jumlah INT; v_tengah INT; v_utara INT; v_selatan INT;
BEGIN
  -- Tiga titik mangkal yang dipakai: Gerobak Dua di -6.2800, Gerobak Satu
  -- di -6.2900/-6.2905 (harus menyatu), dan titik selatan di -6.3200.
  SELECT count(*) INTO v_jumlah
    FROM public.admin_location_clusters(v_today - 3, v_today, 300);
  IF v_jumlah <> 3 THEN
    RAISE EXCEPTION 'GAGAL: % kelompok, harusnya 3', v_jumlah;
  END IF;

  SELECT cups INTO v_utara FROM public.admin_location_clusters(v_today - 3, v_today, 300)
   WHERE cluster_lat > -6.285;
  IF v_utara <> 12 THEN
    RAISE EXCEPTION 'GAGAL kelompok Gerobak Dua: % cup, harusnya 12', v_utara;
  END IF;

  -- Yang diuji di sini: 8 (jam 17) + 4 (jam 15) + 3 (titik 55 m) = 15 cup.
  -- Titik yang berjarak 55 m WAJIB menyatu pada petak 300 m.
  SELECT cups INTO v_tengah FROM public.admin_location_clusters(v_today - 3, v_today, 300)
   WHERE cluster_lat <= -6.285 AND cluster_lat > -6.31;
  IF v_tengah <> 15 THEN
    RAISE EXCEPTION 'GAGAL kelompok tengah: % cup, harusnya 15 (titik 55 m harus menyatu)', v_tengah;
  END IF;

  SELECT cups INTO v_selatan FROM public.admin_location_clusters(v_today - 3, v_today, 300)
   WHERE cluster_lat <= -6.31;
  IF v_selatan <> 5 THEN
    RAISE EXCEPTION 'GAGAL kelompok selatan: % cup, harusnya 5', v_selatan;
  END IF;

  RAISE NOTICE 'OK: 3 kelompok — 12, 15 (tiga titik menyatu), dan 5 cup';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 4. Petak terlalu kecil dijepit ke 50 m, tidak memecah satu titik mangkal ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
        v_5 INT; v_0 INT; v_50 INT; v_beda INT;
BEGIN
  -- Diminta 5 m — di bawah ketelitian GPS ponsel, harus dijepit ke 50 m.
  -- Buktinya: hasil petak 5 m dan 0 m WAJIB identik dengan petak 50 m.
  SELECT count(*) INTO v_5  FROM public.admin_location_clusters(v_today - 3, v_today, 5);
  SELECT count(*) INTO v_0  FROM public.admin_location_clusters(v_today - 3, v_today, 0);
  SELECT count(*) INTO v_50 FROM public.admin_location_clusters(v_today - 3, v_today, 50);

  IF v_5 <> v_50 OR v_0 <> v_50 THEN
    RAISE EXCEPTION 'GAGAL penjepitan: petak 5 m -> % kelompok, 0 m -> %, 50 m -> %',
      v_5, v_0, v_50;
  END IF;

  -- Bukan cuma jumlah barisnya — isinya juga harus sama persis.
  SELECT count(*) INTO v_beda FROM (
    SELECT cluster_lat, cluster_lng, cups FROM public.admin_location_clusters(v_today - 3, v_today, 5)
    EXCEPT
    SELECT cluster_lat, cluster_lng, cups FROM public.admin_location_clusters(v_today - 3, v_today, 50)
  ) t;
  IF v_beda <> 0 THEN
    RAISE EXCEPTION 'GAGAL: % baris berbeda antara petak 5 m dan 50 m', v_beda;
  END IF;

  -- Pada petak 50 m, titik yang berjarak 55 m memang sudah wajar terpisah.
  IF v_50 <= 3 THEN
    RAISE EXCEPTION 'GAGAL: petak 50 m harusnya memecah titik 55 m, dapat % kelompok', v_50;
  END IF;

  RAISE NOTICE 'OK: petak 5 m dan 0 m menghasilkan hasil identik dengan petak 50 m (% kelompok)', v_50;
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 5. Cup per JAM memisahkan lokasi bagus dari driver yang kerja lama ==='
SELECT driver_name, days_worked, hours_worked, cups, cups_per_day, cups_per_hour
  FROM public.admin_cart_productivity(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date);

DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
        g1 RECORD; g2 RECORD;
BEGIN
  SELECT * INTO g1 FROM public.admin_cart_productivity(v_today, v_today) WHERE driver_name = 'Gerobak Satu';
  SELECT * INTO g2 FROM public.admin_cart_productivity(v_today, v_today) WHERE driver_name = 'Gerobak Dua';

  IF g1.cups <> 12 OR g2.cups <> 12 THEN
    RAISE EXCEPTION 'GAGAL: cup g1=% g2=%, keduanya harus 12', g1.cups, g2.cups;
  END IF;
  IF g1.cups_per_day <> g2.cups_per_day THEN
    RAISE EXCEPTION 'GAGAL: cup/hari harus sama (% vs %)', g1.cups_per_day, g2.cups_per_day;
  END IF;
  IF g2.cups_per_hour <= g1.cups_per_hour THEN
    RAISE EXCEPTION 'GAGAL: cup/jam g2=% harus di atas g1=%', g2.cups_per_hour, g1.cups_per_hour;
  END IF;
  IF g2.hours_worked <> 2.0 OR g1.hours_worked <> 5.0 THEN
    RAISE EXCEPTION 'GAGAL jam kerja: g1=%, g2=%', g1.hours_worked, g2.hours_worked;
  END IF;

  RAISE NOTICE 'OK: cup/hari sama (12 vs 12), cup/jam berbeda jauh (% vs %) — inilah yang memisahkan lokasi dari jam kerja',
    g1.cups_per_hour, g2.cups_per_hour;
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 6. Jam-gerobak dijumlahkan, bukan jam dinding ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_daily_productivity(v_today, v_today);
  IF rec.drivers <> 2 THEN
    RAISE EXCEPTION 'GAGAL: % driver, harusnya 2', rec.drivers;
  END IF;
  -- Gerobak Satu 5 jam + Gerobak Dua 2 jam = 7 jam-gerobak.
  -- Kalau dihitung dari jam dinding (11:00-17:00) hasilnya 6 jam, dan
  -- cup/jam akan terlihat lebih tinggi dari kenyataan.
  IF rec.hours_worked <> 7.0 THEN
    RAISE EXCEPTION 'GAGAL: jam kerja = %, harusnya 7 (5 + 2 jam-gerobak)', rec.hours_worked;
  END IF;
  IF rec.cups <> 24 THEN
    RAISE EXCEPTION 'GAGAL: % cup, harusnya 24', rec.cups;
  END IF;
  RAISE NOTICE 'OK: 7 jam-gerobak (bukan 6 jam dinding), 24 cup, % cup/jam', rec.cups_per_hour;
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 7. Hari dengan satu pesanan tidak membagi dengan nol ==='
DO $$
DECLARE v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 20;
        rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_daily_productivity(v_hari, v_hari);
  IF rec.hours_worked <> 1.0 THEN
    RAISE EXCEPTION 'GAGAL: jam kerja = %, harusnya dijepit ke 1.0', rec.hours_worked;
  END IF;
  IF rec.cups_per_hour <> 3.0 THEN
    RAISE EXCEPTION 'GAGAL: cup/jam = %, harusnya 3.0', rec.cups_per_hour;
  END IF;
  RAISE NOTICE 'OK: rentang nol dijepit ke 1 jam, hasilnya 3.0 cup/jam — bukan tak hingga';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 8. Matriks hari x jam memisahkan hari yang berbeda ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
        v_baris INT;
BEGIN
  SELECT count(*) INTO v_baris FROM public.admin_daypart_matrix(v_today - 3, v_today);
  IF v_baris < 4 THEN
    RAISE EXCEPTION 'GAGAL: matriks cuma % baris', v_baris;
  END IF;
  -- Jam 17 dijalani 4 hari berturut-turut, jadi harus muncul pada 4 dow berbeda.
  SELECT count(DISTINCT dow) INTO v_baris
    FROM public.admin_daypart_matrix(v_today - 3, v_today) WHERE hour_wib = 17;
  IF v_baris <> 4 THEN
    RAISE EXCEPTION 'GAGAL: jam 17 muncul di % hari, harusnya 4', v_baris;
  END IF;
  RAISE NOTICE 'OK: jam 17 terpecah ke 4 hari berbeda, bukan menumpuk jadi satu angka';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 9. Bukan admin tidak mendapat satu baris pun ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; v INT;
BEGIN
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);

  SELECT count(*) INTO v FROM public.admin_hourly_performance(v_today - 3, v_today);
  IF v <> 0 THEN RAISE EXCEPTION 'GAGAL: driver melihat % baris jam', v; END IF;

  SELECT count(*) INTO v FROM public.admin_location_clusters(v_today - 3, v_today, 300);
  IF v <> 0 THEN RAISE EXCEPTION 'GAGAL: driver melihat % baris lokasi', v; END IF;

  SELECT count(*) INTO v FROM public.admin_cart_productivity(v_today - 3, v_today);
  IF v <> 0 THEN RAISE EXCEPTION 'GAGAL: driver melihat % baris produktivitas', v; END IF;

  SELECT count(*) INTO v FROM public.admin_daily_productivity(v_today - 3, v_today);
  IF v <> 0 THEN RAISE EXCEPTION 'GAGAL: driver melihat % baris harian', v; END IF;

  SELECT count(*) INTO v FROM public.admin_daypart_matrix(v_today - 3, v_today);
  IF v <> 0 THEN RAISE EXCEPTION 'GAGAL: driver melihat % baris matriks', v; END IF;

  RAISE NOTICE 'OK: kelima fungsi tertutup untuk non-admin';
END;
$$;

\echo ''
\echo '=== SELURUH UJI 0016 LULUS ==='
