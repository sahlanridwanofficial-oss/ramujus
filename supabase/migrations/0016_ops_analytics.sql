-- ============================================================
-- 0016 — Analitik operasional: keputusan JAM dan LOKASI
--
-- Jalankan di Supabase SQL Editor SETELAH 0015. Aman dijalankan berulang.
--
-- Masalah yang diperbaiki: analitik lama menjumlahkan cup per jam secara
-- mentah. Itu menyesatkan, dan pada data sungguhan sempat menghasilkan
-- kesimpulan yang salah.
--
-- Contohnya nyata. Jam 17:00 tercatat 10 cup dan jam 15:00 hanya 4 cup,
-- sehingga 17:00 terlihat dua setengah kali lebih ramai. Padahal gerobak
-- berjualan di jam 17:00 pada 4 hari dan di jam 15:00 hanya pada 2 hari.
-- Dibagi hari aktifnya, keduanya sama-sama sekitar 2 cup per jam.
--
-- Yang terlihat sebagai "jam ramai" ternyata cuma "jam yang lebih sering
-- ditongkrongi". Angka mentah mengukur kebiasaan driver, bukan permintaan
-- pembeli — dan keputusan jam yang diambil dari situ akan salah.
--
-- Karena itu setiap fungsi di sini melaporkan pembaginya secara terbuka
-- (days_active, hours_worked) berdampingan dengan angka yang dinormalkan.
-- Admin harus bisa melihat bahwa sebuah angka bagus datang dari 1 hari
-- atau dari 30 hari.
--
-- Jam kerja dihitung dari rentang pesanan pertama sampai terakhir, BUKAN
-- dari tabel shifts. Pada data sungguhan shifts tidak bisa dipercaya:
-- 3 shift untuk 4 hari berjualan, dua di antaranya tidak pernah ditutup,
-- dan satu tercatat terbuka 12 jam. Rentang pesanan memang meremehkan
-- (waktu menunggu sebelum penjualan pertama tidak terhitung), tapi ia
-- konsisten — dan konsistensi itulah yang dibutuhkan untuk membandingkan
-- gerobak dengan gerobak, atau lokasi dengan lokasi.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Performa per jam, dinormalkan terhadap hari aktif
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_hourly_performance(DATE, DATE);

CREATE OR REPLACE FUNCTION public.admin_hourly_performance(p_from DATE, p_to DATE)
RETURNS TABLE (
  hour_wib            INTEGER,
  cups                INTEGER,
  revenue             BIGINT,
  orders              INTEGER,
  -- Pembagi, sengaja ikut dikembalikan: angka per jam tidak bisa dibaca
  -- tanpa tahu berapa hari jam itu benar-benar dijalani.
  days_active         INTEGER,
  cups_per_active_day NUMERIC,
  revenue_share       NUMERIC
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH span AS (
    SELECT LEAST(p_from, p_to) AS d_from,
           LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365) AS d_to
  ),
  base AS (
    SELECT EXTRACT(HOUR FROM o.created_at AT TIME ZONE 'Asia/Jakarta')::INTEGER AS jam,
           (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS hari,
           o.id AS order_id,
           COALESCE(sum(oi.quantity) FILTER (WHERE pr.category = 'smoothie'), 0) AS cup,
           COALESCE(sum(oi.subtotal), 0) AS omzet
      FROM public.orders o
      LEFT JOIN public.order_items oi ON oi.order_id = o.id
      LEFT JOIN public.products    pr ON pr.id = oi.product_id,
           span s
     WHERE o.created_at >= public.wib_day_start(s.d_from)
       AND o.created_at <  public.wib_day_start(s.d_to + 1)
     GROUP BY 1, 2, 3
  ),
  agg AS (
    SELECT jam,
           sum(cup)::INTEGER                  AS cups,
           sum(omzet)::BIGINT                 AS revenue,
           count(*)::INTEGER                  AS orders,
           count(DISTINCT hari)::INTEGER      AS days_active
      FROM base
     GROUP BY jam
  ),
  total AS (SELECT COALESCE(sum(revenue), 0)::BIGINT AS rev FROM agg)
  SELECT a.jam,
         a.cups,
         a.revenue,
         a.orders,
         a.days_active,
         round(a.cups::NUMERIC / NULLIF(a.days_active, 0), 1),
         CASE WHEN (SELECT rev FROM total) > 0
              THEN round(a.revenue * 100.0 / (SELECT rev FROM total), 1)
              ELSE 0 END
    FROM agg a
   WHERE public.get_user_role(auth.uid()) = 'admin'
   ORDER BY a.jam;
$$;

REVOKE ALL ON FUNCTION public.admin_hourly_performance(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_hourly_performance(DATE, DATE) TO authenticated;

-- ------------------------------------------------------------
-- 2. Kelompok lokasi penjualan
--
-- Koordinat pesanan dibulatkan ke petak seukuran p_grid_meters, lalu
-- dijumlahkan per petak. Ini memberi jawaban "ruas jalan mana yang
-- menghasilkan", bukan sekadar titik-titik yang berserakan di peta.
--
-- Ukuran petak dibuat parameter karena jawabannya berbeda menurut
-- pertanyaannya: 200 m untuk memilih titik mangkal, 1000 m untuk memilih
-- wilayah gerobak berikutnya.
--
-- Konversi derajat ke meter memakai satu garis lintang acuan (rata-rata
-- data), bukan per baris. Untuk wilayah operasi gerobak — beberapa
-- kilometer — selisihnya jauh di bawah ukuran petak terkecil, dan acuan
-- tunggal membuat batas petak tetap lurus.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_location_clusters(DATE, DATE, INTEGER);

CREATE OR REPLACE FUNCTION public.admin_location_clusters(
  p_from         DATE,
  p_to           DATE,
  p_grid_meters  INTEGER DEFAULT 300
)
RETURNS TABLE (
  cluster_lat         DOUBLE PRECISION,
  cluster_lng         DOUBLE PRECISION,
  cups                INTEGER,
  revenue             BIGINT,
  orders              INTEGER,
  days_active         INTEGER,
  cups_per_active_day NUMERIC,
  best_hour           INTEGER,
  revenue_share       NUMERIC
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH span AS (
    SELECT LEAST(p_from, p_to) AS d_from,
           LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365) AS d_to,
           -- Petak di bawah 50 m tidak bermakna: ketelitian GPS ponsel
           -- sendiri sudah di kisaran itu, jadi petak lebih kecil hanya
           -- memecah satu titik mangkal jadi beberapa baris palsu.
           GREATEST(COALESCE(p_grid_meters, 300), 50) AS grid
  ),
  pesanan AS (
    SELECT o.id,
           o.latitude,
           o.longitude,
           (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS hari,
           EXTRACT(HOUR FROM o.created_at AT TIME ZONE 'Asia/Jakarta')::INTEGER AS jam,
           COALESCE(sum(oi.quantity) FILTER (WHERE pr.category = 'smoothie'), 0) AS cup,
           COALESCE(sum(oi.subtotal), 0) AS omzet
      FROM public.orders o
      LEFT JOIN public.order_items oi ON oi.order_id = o.id
      LEFT JOIN public.products    pr ON pr.id = oi.product_id,
           span s
     WHERE o.created_at >= public.wib_day_start(s.d_from)
       AND o.created_at <  public.wib_day_start(s.d_to + 1)
       AND o.latitude IS NOT NULL
       AND o.longitude IS NOT NULL
     GROUP BY o.id, o.latitude, o.longitude, 4, 5
  ),
  acuan AS (
    SELECT (SELECT grid FROM span)::NUMERIC / 111320.0 AS d_lat,
           (SELECT grid FROM span)::NUMERIC /
             (111320.0 * GREATEST(cos(radians(avg(latitude))), 0.01)) AS d_lng
      FROM pesanan
  ),
  petak AS (
    SELECT floor(p.latitude::NUMERIC  / a.d_lat) * a.d_lat + a.d_lat / 2 AS c_lat,
           floor(p.longitude::NUMERIC / a.d_lng) * a.d_lng + a.d_lng / 2 AS c_lng,
           p.hari, p.jam, p.cup, p.omzet
      FROM pesanan p, acuan a
  ),
  agg AS (
    SELECT c_lat, c_lng,
           sum(cup)::INTEGER             AS cups,
           sum(omzet)::BIGINT            AS revenue,
           count(*)::INTEGER             AS orders,
           count(DISTINCT hari)::INTEGER AS days_active
      FROM petak
     GROUP BY c_lat, c_lng
  ),
  jam_terbaik AS (
    SELECT DISTINCT ON (c_lat, c_lng) c_lat, c_lng, jam
      FROM (SELECT c_lat, c_lng, jam, sum(cup) AS cup
              FROM petak GROUP BY c_lat, c_lng, jam) t
     ORDER BY c_lat, c_lng, cup DESC, jam
  ),
  total AS (SELECT COALESCE(sum(revenue), 0)::BIGINT AS rev FROM agg)
  SELECT a.c_lat::DOUBLE PRECISION,
         a.c_lng::DOUBLE PRECISION,
         a.cups,
         a.revenue,
         a.orders,
         a.days_active,
         round(a.cups::NUMERIC / NULLIF(a.days_active, 0), 1),
         j.jam,
         CASE WHEN (SELECT rev FROM total) > 0
              THEN round(a.revenue * 100.0 / (SELECT rev FROM total), 1)
              ELSE 0 END
    FROM agg a
    LEFT JOIN jam_terbaik j ON j.c_lat = a.c_lat AND j.c_lng = a.c_lng
   WHERE public.get_user_role(auth.uid()) = 'admin'
   ORDER BY a.cups DESC, a.revenue DESC;
$$;

REVOKE ALL ON FUNCTION public.admin_location_clusters(DATE, DATE, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_location_clusters(DATE, DATE, INTEGER) TO authenticated;

-- ------------------------------------------------------------
-- 3. Matriks hari × jam
--
-- Menjawab pertanyaan yang tidak bisa dijawab rata-rata per jam saja:
-- "Sabtu sore ramai, tapi Selasa sore tidak" tidak akan pernah terlihat
-- kalau seluruh sore dijumlahkan jadi satu angka.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_daypart_matrix(DATE, DATE);

CREATE OR REPLACE FUNCTION public.admin_daypart_matrix(p_from DATE, p_to DATE)
RETURNS TABLE (
  dow                 INTEGER,   -- 0 = Minggu, sesuai EXTRACT(DOW)
  hour_wib            INTEGER,
  cups                INTEGER,
  revenue             BIGINT,
  days_active         INTEGER,
  cups_per_active_day NUMERIC
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH span AS (
    SELECT LEAST(p_from, p_to) AS d_from,
           LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365) AS d_to
  ),
  base AS (
    SELECT (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS hari,
           EXTRACT(DOW  FROM o.created_at AT TIME ZONE 'Asia/Jakarta')::INTEGER AS dow,
           EXTRACT(HOUR FROM o.created_at AT TIME ZONE 'Asia/Jakarta')::INTEGER AS jam,
           o.id,
           COALESCE(sum(oi.quantity) FILTER (WHERE pr.category = 'smoothie'), 0) AS cup,
           COALESCE(sum(oi.subtotal), 0) AS omzet
      FROM public.orders o
      LEFT JOIN public.order_items oi ON oi.order_id = o.id
      LEFT JOIN public.products    pr ON pr.id = oi.product_id,
           span s
     WHERE o.created_at >= public.wib_day_start(s.d_from)
       AND o.created_at <  public.wib_day_start(s.d_to + 1)
     GROUP BY 1, 2, 3, 4
  )
  SELECT b.dow,
         b.jam,
         sum(b.cup)::INTEGER,
         sum(b.omzet)::BIGINT,
         count(DISTINCT b.hari)::INTEGER,
         round(sum(b.cup)::NUMERIC / NULLIF(count(DISTINCT b.hari), 0), 1)
    FROM base b
   WHERE public.get_user_role(auth.uid()) = 'admin'
   GROUP BY b.dow, b.jam
   ORDER BY b.dow, b.jam;
$$;

REVOKE ALL ON FUNCTION public.admin_daypart_matrix(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_daypart_matrix(DATE, DATE) TO authenticated;

-- ------------------------------------------------------------
-- 4. Produktivitas per gerobak (per driver)
--
-- Ini angka pembanding utama begitu ada lebih dari satu gerobak.
-- Cup per HARI mencampur dua hal yang berbeda — lokasi yang bagus dan
-- driver yang kerja lebih lama. Cup per JAM memisahkannya.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_cart_productivity(DATE, DATE);

CREATE OR REPLACE FUNCTION public.admin_cart_productivity(p_from DATE, p_to DATE)
RETURNS TABLE (
  driver_id        UUID,
  driver_name      TEXT,
  days_worked      INTEGER,
  hours_worked     NUMERIC,
  cups             INTEGER,
  revenue          BIGINT,
  orders           INTEGER,
  cups_per_hour    NUMERIC,
  cups_per_day     NUMERIC,
  revenue_per_hour NUMERIC,
  avg_start_hour   NUMERIC,
  avg_end_hour     NUMERIC
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH span AS (
    SELECT LEAST(p_from, p_to) AS d_from,
           LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365) AS d_to
  ),
  pesanan AS (
    SELECT o.id, o.driver_id, o.created_at,
           (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS hari,
           COALESCE(sum(oi.quantity) FILTER (WHERE pr.category = 'smoothie'), 0) AS cup,
           COALESCE(sum(oi.subtotal), 0) AS omzet
      FROM public.orders o
      LEFT JOIN public.order_items oi ON oi.order_id = o.id
      LEFT JOIN public.products    pr ON pr.id = oi.product_id,
           span s
     WHERE o.created_at >= public.wib_day_start(s.d_from)
       AND o.created_at <  public.wib_day_start(s.d_to + 1)
     GROUP BY o.id, o.driver_id, o.created_at, 4
  ),
  per_hari AS (
    SELECT driver_id,
           hari,
           sum(cup)   AS cup,
           sum(omzet) AS omzet,
           count(*)   AS orders,
           -- Satu jam sebagai lantai: hari dengan satu pesanan punya
           -- rentang nol, dan membaginya akan meledak jadi tak hingga.
           GREATEST(
             EXTRACT(EPOCH FROM (max(created_at) - min(created_at))) / 3600.0,
             1.0
           ) AS jam_kerja,
           EXTRACT(HOUR FROM min(created_at) AT TIME ZONE 'Asia/Jakarta') AS jam_mulai,
           EXTRACT(HOUR FROM max(created_at) AT TIME ZONE 'Asia/Jakarta') AS jam_selesai
      FROM pesanan
     GROUP BY driver_id, hari
  ),
  agg AS (
    SELECT driver_id,
           count(*)::INTEGER        AS days_worked,
           sum(jam_kerja)::NUMERIC  AS hours_worked,
           sum(cup)::INTEGER        AS cups,
           sum(omzet)::BIGINT       AS revenue,
           sum(orders)::INTEGER     AS orders,
           avg(jam_mulai)           AS avg_start,
           avg(jam_selesai)         AS avg_end
      FROM per_hari
     GROUP BY driver_id
  )
  SELECT a.driver_id,
         COALESCE(pf.full_name, 'Driver tidak dikenal'),
         a.days_worked,
         round(a.hours_worked, 1),
         a.cups,
         a.revenue,
         a.orders,
         round(a.cups::NUMERIC / NULLIF(a.hours_worked, 0), 2),
         round(a.cups::NUMERIC / NULLIF(a.days_worked, 0), 1),
         round(a.revenue::NUMERIC / NULLIF(a.hours_worked, 0), 0),
         round(a.avg_start, 1),
         round(a.avg_end, 1)
    FROM agg a
    LEFT JOIN public.profiles pf ON pf.id = a.driver_id
   WHERE public.get_user_role(auth.uid()) = 'admin'
   ORDER BY round(a.cups::NUMERIC / NULLIF(a.hours_worked, 0), 2) DESC NULLS LAST;
$$;

REVOKE ALL ON FUNCTION public.admin_cart_productivity(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_cart_productivity(DATE, DATE) TO authenticated;

-- ------------------------------------------------------------
-- 5. Produktivitas harian
--
-- Menjawab "hari ini bagus karena ramai, atau karena kerjanya lebih
-- lama?" — pertanyaan yang tidak bisa dijawab kolom omzet saja.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_daily_productivity(DATE, DATE);

CREATE OR REPLACE FUNCTION public.admin_daily_productivity(p_from DATE, p_to DATE)
RETURNS TABLE (
  day           DATE,
  cups          INTEGER,
  revenue       BIGINT,
  orders        INTEGER,
  hours_worked  NUMERIC,
  cups_per_hour NUMERIC,
  start_hour    INTEGER,
  end_hour      INTEGER,
  drivers       INTEGER
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH span AS (
    SELECT LEAST(p_from, p_to) AS d_from,
           LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365) AS d_to
  ),
  pesanan AS (
    SELECT o.id, o.driver_id, o.created_at,
           (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS hari,
           COALESCE(sum(oi.quantity) FILTER (WHERE pr.category = 'smoothie'), 0) AS cup,
           COALESCE(sum(oi.subtotal), 0) AS omzet
      FROM public.orders o
      LEFT JOIN public.order_items oi ON oi.order_id = o.id
      LEFT JOIN public.products    pr ON pr.id = oi.product_id,
           span s
     WHERE o.created_at >= public.wib_day_start(s.d_from)
       AND o.created_at <  public.wib_day_start(s.d_to + 1)
     GROUP BY o.id, o.driver_id, o.created_at, 4
  ),
  -- Jam kerja dijumlahkan per driver lebih dulu. Dua gerobak yang jalan
  -- bersamaan dari 11:00 sampai 18:00 berarti 14 jam-gerobak, bukan 7 —
  -- kalau tidak, cup per jam akan terlihat dua kali lipat begitu gerobak
  -- kedua mulai jalan.
  per_driver AS (
    SELECT hari, driver_id,
           GREATEST(EXTRACT(EPOCH FROM (max(created_at) - min(created_at))) / 3600.0, 1.0) AS jam
      FROM pesanan
     GROUP BY hari, driver_id
  ),
  jam_harian AS (
    SELECT hari, sum(jam) AS jam_kerja, count(*)::INTEGER AS drivers
      FROM per_driver GROUP BY hari
  )
  SELECT p.hari,
         sum(p.cup)::INTEGER,
         sum(p.omzet)::BIGINT,
         count(*)::INTEGER,
         round(j.jam_kerja, 1),
         round(sum(p.cup)::NUMERIC / NULLIF(j.jam_kerja, 0), 2),
         EXTRACT(HOUR FROM min(p.created_at) AT TIME ZONE 'Asia/Jakarta')::INTEGER,
         EXTRACT(HOUR FROM max(p.created_at) AT TIME ZONE 'Asia/Jakarta')::INTEGER,
         j.drivers
    FROM pesanan p
    JOIN jam_harian j ON j.hari = p.hari
   WHERE public.get_user_role(auth.uid()) = 'admin'
   GROUP BY p.hari, j.jam_kerja, j.drivers
   ORDER BY p.hari;
$$;

REVOKE ALL ON FUNCTION public.admin_daily_productivity(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_daily_productivity(DATE, DATE) TO authenticated;

NOTIFY pgrst, 'reload schema';
