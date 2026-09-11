-- ============================================================
-- 0018 — Titik lokasi yang dilaporkan harus tempat jualan sebenarnya
--
-- Jalankan di Supabase SQL Editor SETELAH 0017. Aman dijalankan berulang.
--
-- Bug yang diperbaiki: admin_location_clusters mengembalikan PUSAT PETAK
-- grid sebagai koordinat kelompok, lalu halaman Analitik menautkannya ke
-- peta seolah-olah itu tempat yang bisa didatangi. Bukan — itu titik
-- buatan, hasil pembulatan ke kisi 300 m.
--
-- Pada data produksi melesetnya terukur:
--
--   pesanan   dilaporkan        sebenarnya        meleset   sebaran nyata
--   -------   ---------------   ---------------   -------   -------------
--   14        -6.29671          -6.29670          136 m     25 m
--             106.86005         106.86128
--   4         -6.31558          -6.31517          139 m     10 m
--             106.86005         106.85886
--   2         -6.28863          -6.28804          129 m      6 m
--             106.86005         106.85904
--
-- Perhatikan kolom terakhir: penjualannya sendiri mengumpul dalam radius
-- 6–28 meter — praktis satu titik mangkal. Yang meleset 139 meter adalah
-- laporannya, bukan gerobaknya. Pada jarak segitu pin peta bisa jatuh di
-- seberang jalan atau blok sebelah, dan admin yang mendatanginya tidak
-- akan menemukan apa pun.
--
-- Penyebabnya satu kekeliruan: petak dipakai untuk DUA hal sekaligus —
-- mengelompokkan pesanan yang berdekatan, DAN melaporkan posisinya.
-- Tugas pertama memang butuh pembulatan; tugas kedua tidak boleh
-- memakainya sama sekali.
--
-- Perbaikannya: petak tetap mengelompokkan, tetapi koordinat yang
-- dikembalikan adalah RATA-RATA koordinat asli pesanan di kelompok itu.
-- Karena sebarannya rapat, rata-rata itu jatuh tepat di tempat gerobak
-- benar-benar berjualan.
--
-- Ditambah kolom spread_meters supaya kelompok yang TIDAK rapat bisa
-- dikenali. Satu titik dengan sebaran 20 m layak dijadikan titik mangkal;
-- sebaran 280 m berarti itu sebenarnya perjalanan, bukan tempat — dan
-- pin tunggal akan menyesatkan betapa pun benarnya ia dihitung.
--
-- Bentuk baris keluaran berubah, jadi fungsinya harus DILEPAS dulu:
-- CREATE OR REPLACE tidak bisa mengubah OUT parameter (galat 42P13).
-- ============================================================

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
  revenue_share       NUMERIC,
  -- Seberapa rapat pesanan dalam kelompok ini, dalam meter. Kecil berarti
  -- titik mangkal; besar berarti gerobak bergerak dan pin tunggal tidak
  -- mewakili apa pun.
  spread_meters       INTEGER
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH span AS (
    SELECT LEAST(p_from, p_to) AS d_from,
           LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365) AS d_to,
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
             (111320.0 * GREATEST(cos(radians(avg(latitude))), 0.01)) AS d_lng,
           -- Garis lintang acuan disimpan supaya konversi derajat ke meter
           -- pada spread_meters memakai skala yang sama dengan petaknya.
           avg(latitude) AS lat0
      FROM pesanan
  ),
  petak AS (
    -- Nomor petak dipakai HANYA sebagai kunci pengelompokan. Koordinat
    -- aslinya ikut dibawa utuh, tidak dibulatkan.
    SELECT floor(p.latitude::NUMERIC  / a.d_lat) AS ix,
           floor(p.longitude::NUMERIC / a.d_lng) AS iy,
           p.latitude, p.longitude, p.hari, p.jam, p.cup, p.omzet
      FROM pesanan p, acuan a
  ),
  agg AS (
    SELECT ix, iy,
           avg(latitude)                 AS c_lat,
           avg(longitude)                AS c_lng,
           sum(cup)::INTEGER             AS cups,
           sum(omzet)::BIGINT            AS revenue,
           count(*)::INTEGER             AS orders,
           count(DISTINCT hari)::INTEGER AS days_active,
           -- Diagonal kotak pembatas: perkiraan atas yang cukup untuk
           -- membedakan titik mangkal dari perjalanan.
           sqrt(
             ((max(latitude)  - min(latitude))  * 111320.0) ^ 2 +
             ((max(longitude) - min(longitude)) * 111320.0 *
              GREATEST(cos(radians((SELECT lat0 FROM acuan))), 0.01)) ^ 2
           ) AS spread
      FROM petak
     GROUP BY ix, iy
  ),
  jam_terbaik AS (
    SELECT DISTINCT ON (ix, iy) ix, iy, jam
      FROM (SELECT ix, iy, jam, sum(cup) AS cup
              FROM petak GROUP BY ix, iy, jam) t
     ORDER BY ix, iy, cup DESC, jam
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
              ELSE 0 END,
         round(a.spread)::INTEGER
    FROM agg a
    LEFT JOIN jam_terbaik j ON j.ix = a.ix AND j.iy = a.iy
   WHERE public.get_user_role(auth.uid()) = 'admin'
   ORDER BY a.cups DESC, a.revenue DESC;
$$;

REVOKE ALL ON FUNCTION public.admin_location_clusters(DATE, DATE, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_location_clusters(DATE, DATE, INTEGER) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_location_clusters(DATE, DATE, INTEGER) TO authenticated;

NOTIFY pgrst, 'reload schema';
