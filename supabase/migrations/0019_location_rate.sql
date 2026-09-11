-- ============================================================
-- 0019 — Cup per JAM per lokasi
--
-- Jalankan di Supabase SQL Editor SETELAH 0018. Aman dijalankan berulang.
--
-- Yang dijawab: "kalau buka toko di titik ini, sanggup tidak?"
--
-- Sampai sekarang analitik lokasi hanya bisa bilang cup per HARI-AKTIF.
-- Itu tidak cukup untuk memutuskan sewa, karena angka yang sama berarti
-- dua hal yang sangat berbeda:
--
--   8,5 cup dari 2 jam mangkal  = 4,25 cup/jam  -> toko di situ hidup
--   8,5 cup dari 7 jam mangkal  = 1,2  cup/jam  -> toko di situ tercekik
--
-- Titik impas ruko kecil (sewa + 1 pegawai) ada di kisaran 4,4 cup/jam.
-- Tanpa angka ini, keputusan sewa dua tahun diambil sambil menebak.
--
-- ------------------------------------------------------------
-- Kenapa bukan dari GPS
--
-- Tabel location_logs terlihat seperti sumber yang tepat, tetapi datanya
-- tidak sanggup: 105 titik untuk 5 hari berjualan, jeda median 5 menit
-- sementara rata-ratanya 30 menit. Sebaran seperti itu berarti perekaman
-- hanya jalan saat aplikasi terbuka, bukan sepanjang shift. Menghitung
-- lama mangkal dari titik yang bolong-bolong akan menghasilkan angka yang
-- terlihat presisi tetapi salah.
--
-- Dipakai rentang pesanan — metode yang sama dengan jam kerja harian.
-- Ia meremehkan (waktu menunggu sebelum penjualan pertama tidak
-- terhitung), tetapi ia konsisten, dan konsistensi itulah yang dibutuhkan
-- untuk membandingkan titik dengan titik.
--
-- ------------------------------------------------------------
-- Kejujuran yang harus dijaga: kunjungan satu pesanan
--
-- Satu kunjungan dengan satu pesanan punya rentang nol. Gerobak mungkin
-- mangkal 2 jam dan cuma laku sekali, atau lewat 5 menit dan langsung
-- laku. Keduanya tercatat identik.
--
-- Godaannya adalah memasang lantai — misalnya "anggap saja 15 menit" —
-- supaya setiap titik punya angka. Itu ditolak di sini. Lantai yang
-- dikarang membuat titik ramai dan titik sepi sama-sama menghasilkan
-- bilangan yang kelihatan meyakinkan, dan yang membaca tidak punya cara
-- membedakannya.
--
-- Sebagai gantinya, cup per jam dihitung HANYA dari kunjungan yang
-- rentangnya benar-benar terukur (dua pesanan atau lebih). Titik yang
-- tidak punya satu pun kunjungan seperti itu mengembalikan NULL — bukan
-- nol, bukan tebakan. NULL berarti "belum diketahui", dan itu jawaban
-- yang benar.
--
-- Kolom stops dan measured_stops ikut dikembalikan supaya cakupannya
-- terlihat: angka 5 cup/jam dari 1 kunjungan terukur tidak boleh terbaca
-- sama meyakinkan dengan angka yang sama dari 12 kunjungan.
--
-- ------------------------------------------------------------
-- Rentang yang terlalu pendek juga bukan bukti
--
-- Syarat "dua pesanan atau lebih" saja ternyata belum cukup. Pada data
-- produksi ada titik dengan dua pesanan berjarak 11 DETIK — hampir pasti
-- satu pembeli yang dicatat dua kali. Rentangnya lolos syarat "lebih besar
-- dari nol", lalu membagi 3 cup dengan 0,003 jam dan menghasilkan
-- 959 cup/jam.
--
-- Angka itu bukan sekadar aneh; ia berbahaya, karena tampil sebagai titik
-- terbaik dan akan menarik keputusan sewa ke tempat yang salah.
--
-- Karena itu kunjungan harus terentang minimal MIN_MENIT menit untuk ikut
-- membentuk laju. Ini bukan lantai yang dikarang — nilainya tidak dipakai
-- menggantikan apa pun. Ini ambang bukti: di bawah itu, dua penjualan
-- berdekatan tidak memberi tahu apa pun tentang laju per jam, sama seperti
-- kunjungan satu pesanan.
--
-- Bentuk baris keluaran berubah, jadi fungsinya dilepas dulu (42P13).
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
  spread_meters       INTEGER,
  -- Kunjungan = satu gerobak, satu hari, di petak ini.
  stops               INTEGER,
  -- Kunjungan yang rentangnya benar-benar terukur (>= 2 pesanan).
  measured_stops      INTEGER,
  hours_measured      NUMERIC,
  cups_measured       INTEGER,
  -- NULL bila belum ada kunjungan terukur. Jangan diisi nol.
  cups_per_hour       NUMERIC
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
           o.driver_id,
           o.created_at,
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
     GROUP BY o.id, o.driver_id, o.created_at, o.latitude, o.longitude, 6, 7
  ),
  acuan AS (
    SELECT (SELECT grid FROM span)::NUMERIC / 111320.0 AS d_lat,
           (SELECT grid FROM span)::NUMERIC /
             (111320.0 * GREATEST(cos(radians(avg(latitude))), 0.01)) AS d_lng,
           avg(latitude) AS lat0
      FROM pesanan
  ),
  petak AS (
    SELECT floor(p.latitude::NUMERIC  / a.d_lat) AS ix,
           floor(p.longitude::NUMERIC / a.d_lng) AS iy,
           p.driver_id, p.created_at, p.latitude, p.longitude,
           p.hari, p.jam, p.cup, p.omzet
      FROM pesanan p, acuan a
  ),
  -- Satu kunjungan: satu gerobak, satu hari, satu petak.
  kunjungan AS (
    SELECT ix, iy, hari, driver_id,
           count(*)  AS pesanan,
           sum(cup)  AS cup,
           EXTRACT(EPOCH FROM (max(created_at) - min(created_at))) / 3600.0 AS jam_mangkal
      FROM petak
     GROUP BY ix, iy, hari, driver_id
  ),
  -- Hanya kunjungan yang rentangnya nyata DAN cukup panjang yang boleh
  -- membentuk laju. 15 menit adalah ambang bukti: di bawah itu, dua
  -- penjualan berdekatan tidak memberi tahu apa pun tentang laju per jam.
  terukur AS (
    SELECT ix, iy,
           count(*)::INTEGER      AS measured_stops,
           sum(jam_mangkal)       AS hours_measured,
           sum(cup)::INTEGER      AS cups_measured
      FROM kunjungan
     WHERE pesanan >= 2 AND jam_mangkal >= 0.25
     GROUP BY ix, iy
  ),
  agg AS (
    SELECT p.ix, p.iy,
           avg(p.latitude)                 AS c_lat,
           avg(p.longitude)                AS c_lng,
           sum(p.cup)::INTEGER             AS cups,
           sum(p.omzet)::BIGINT            AS revenue,
           count(*)::INTEGER               AS orders,
           count(DISTINCT p.hari)::INTEGER AS days_active,
           sqrt(
             ((max(p.latitude)  - min(p.latitude))  * 111320.0) ^ 2 +
             ((max(p.longitude) - min(p.longitude)) * 111320.0 *
              GREATEST(cos(radians((SELECT lat0 FROM acuan))), 0.01)) ^ 2
           ) AS spread
      FROM petak p
     GROUP BY p.ix, p.iy
  ),
  jumlah_kunjungan AS (
    SELECT ix, iy, count(*)::INTEGER AS stops FROM kunjungan GROUP BY ix, iy
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
         round(a.spread)::INTEGER,
         k.stops,
         COALESCE(m.measured_stops, 0),
         round(COALESCE(m.hours_measured, 0), 2),
         COALESCE(m.cups_measured, 0),
         -- NULL, bukan nol: "belum diketahui" berbeda dari "tidak laku".
         CASE WHEN m.hours_measured > 0
              THEN round(m.cups_measured::NUMERIC / m.hours_measured, 2)
              ELSE NULL
         END
    FROM agg a
    JOIN jumlah_kunjungan k ON k.ix = a.ix AND k.iy = a.iy
    LEFT JOIN terukur      m ON m.ix = a.ix AND m.iy = a.iy
    LEFT JOIN jam_terbaik  j ON j.ix = a.ix AND j.iy = a.iy
   WHERE public.get_user_role(auth.uid()) = 'admin'
   ORDER BY a.cups DESC, a.revenue DESC;
$$;

REVOKE ALL ON FUNCTION public.admin_location_clusters(DATE, DATE, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_location_clusters(DATE, DATE, INTEGER) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_location_clusters(DATE, DATE, INTEGER) TO authenticated;

NOTIFY pgrst, 'reload schema';
