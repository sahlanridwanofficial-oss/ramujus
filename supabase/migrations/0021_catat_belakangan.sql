-- ============================================================
-- 0021 — Jendela catat-belakangan dilebarkan jadi 30 menit
-- ============================================================
--
-- Driver mencatat pesanan setelah selesai melayani, kadang beberapa
-- sekaligus. Migrasi 0020 sudah mengantisipasi itu dengan kelonggaran
-- 15 menit setelah mangkal ditutup — tapi produksi menunjukkan 15 menit
-- masih kekencangan.
--
-- Sabtu 12 Sep 2026: mangkal ditutup 21:00, dua pesanan terakhir (3 cup)
-- tercatat 21:17. Lewat 2 menit dari jendela, jadi tiga cup itu tidak
-- terhitung ke titik mana pun. Titik B melaporkan 9 cup, padahal yang
-- benar 12 — cup per jam jatuh dari 2,06 ke 1,55, meleset 25%.
--
-- Arah kesalahannya penting: menjatuhkan cup membuat sebuah titik
-- terlihat LEBIH BURUK dari kenyataan. Ini kebalikan dari bug 0019
-- (rentang 11 detik yang melambungkan angka), tapi sama-sama merusak
-- keputusan sewa — yang satu bikin salah tanda tangan, yang satu bikin
-- melewatkan titik yang sebenarnya layak.
--
-- 30 menit dipilih karena itu batas wajar seorang driver membereskan
-- gerobak lalu mencatat sisa pesanan. Melebarkan jendela aman: begitu
-- mangkal berikutnya dimulai, mangkal itu langsung menang sebagai
-- "mangkal terakhir yang sudah berjalan", jadi penjualan di tempat baru
-- tidak pernah tertarik ke tempat lama. Jendela ini hanya menjaga
-- mangkal TERAKHIR dalam sehari agar tidak menyedot pesanan esok hari.
--
-- Idempoten. Tipe baris kembalian tidak berubah dari 0020, jadi
-- CREATE OR REPLACE cukup — tidak perlu DROP.
-- ============================================================

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
  stops               INTEGER,
  measured_stops      INTEGER,
  hours_measured      NUMERIC,
  cups_measured       INTEGER,
  cups_per_hour       NUMERIC,
  -- 'tercatat' = dari tombol mangkal. 'perkiraan' = dari rentang pesanan.
  -- NULL = belum cukup bukti dengan cara mana pun.
  dwell_source        TEXT
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
    SELECT o.id, o.driver_id, o.created_at, o.latitude, o.longitude,
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
       AND o.latitude IS NOT NULL AND o.longitude IS NOT NULL
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
  -- --- Jalur A: lama mangkal yang benar-benar direkam ---
  mangkal AS (
    SELECT floor(st.latitude::NUMERIC  / a.d_lat) AS ix,
           floor(st.longitude::NUMERIC / a.d_lng) AS iy,
           st.id, st.driver_id, st.started_at,
           LEAST(COALESCE(st.ended_at, NOW()), st.started_at + INTERVAL '6 hours') AS ended_at
      FROM public.driver_stops st, acuan a, span s
     WHERE st.latitude IS NOT NULL AND st.longitude IS NOT NULL
       AND st.started_at >= public.wib_day_start(s.d_from)
       AND st.started_at <  public.wib_day_start(s.d_to + 1)
  ),
  mangkal_sah AS (
    -- Di bawah 5 menit hampir selalu salah pencet, bukan mangkal.
    SELECT * FROM mangkal
     WHERE ended_at - started_at >= INTERVAL '5 minutes'
  ),
  -- Pesanan dipasangkan ke mangkal TERAKHIR yang sudah berjalan saat ia
  -- dicatat, dengan kelonggaran 30 menit setelah mangkal itu ditutup.
  --
  -- Kelonggaran itu bukan kelonggaran asal. Justru karena driver mencatat
  -- setelah selesai melayani, catatannya sering mendarat tepat saat atau
  -- sesudah gerobak pindah. Jendela yang ketat akan membuang persis
  -- pesanan yang ingin diukur — dan pengujian menemukan itu: mangkal
  -- 10:00–11:00 dengan tiga pesanan tercatat 11:00:00, 11:00:11, dan
  -- 11:00:22 menghasilkan nol cup.
  --
  -- Produksi kemudian menunjukkan 15 menit masih kurang: 12 Sep 2026,
  -- mangkal tutup 21:00, dua pesanan terakhir tercatat 21:17 — lewat dua
  -- menit, dan tiga cup hilang dari titiknya. Karena itu 30 menit.
  --
  -- Mangkal berikutnya tetap menang: begitu gerobak memulai mangkal baru,
  -- ia menjadi "mangkal terakhir yang sudah berjalan", sehingga penjualan
  -- di tempat baru tidak pernah tertarik ke tempat lama.
  pesanan_bermangkal AS (
    SELECT m.ix, m.iy, m.id AS stop_id, p.cup
      FROM pesanan p
      JOIN LATERAL (
        SELECT s.*
          FROM mangkal_sah s
         WHERE s.driver_id = p.driver_id
           AND s.started_at <= p.created_at
         ORDER BY s.started_at DESC
         LIMIT 1
      ) m ON p.created_at < m.ended_at + INTERVAL '30 minutes'
  ),
  tercatat AS (
    SELECT m.ix, m.iy,
           count(*)::INTEGER AS jumlah,
           sum(EXTRACT(EPOCH FROM (m.ended_at - m.started_at)) / 3600.0) AS jam,
           COALESCE((
             SELECT sum(pb.cup)::INTEGER FROM pesanan_bermangkal pb
              WHERE pb.ix = m.ix AND pb.iy = m.iy
           ), 0) AS cup
      FROM mangkal_sah m
     GROUP BY m.ix, m.iy
  ),
  -- --- Jalur B: perkiraan dari rentang pesanan (cadangan) ---
  kunjungan AS (
    SELECT ix, iy, hari, driver_id,
           count(*) AS pesanan, sum(cup) AS cup,
           EXTRACT(EPOCH FROM (max(created_at) - min(created_at))) / 3600.0 AS jam_mangkal
      FROM petak GROUP BY ix, iy, hari, driver_id
  ),
  perkiraan AS (
    SELECT ix, iy,
           count(*)::INTEGER AS jumlah,
           sum(jam_mangkal)  AS jam,
           sum(cup)::INTEGER AS cup
      FROM kunjungan
     WHERE pesanan >= 2 AND jam_mangkal >= 0.25
     GROUP BY ix, iy
  ),
  agg AS (
    SELECT p.ix, p.iy,
           avg(p.latitude) AS c_lat, avg(p.longitude) AS c_lng,
           sum(p.cup)::INTEGER AS cups, sum(p.omzet)::BIGINT AS revenue,
           count(*)::INTEGER AS orders, count(DISTINCT p.hari)::INTEGER AS days_active,
           sqrt(((max(p.latitude) - min(p.latitude)) * 111320.0) ^ 2 +
                ((max(p.longitude) - min(p.longitude)) * 111320.0 *
                 GREATEST(cos(radians((SELECT lat0 FROM acuan))), 0.01)) ^ 2) AS spread
      FROM petak p GROUP BY p.ix, p.iy
  ),
  jumlah_kunjungan AS (
    SELECT ix, iy, count(*)::INTEGER AS stops FROM kunjungan GROUP BY ix, iy
  ),
  jam_terbaik AS (
    SELECT DISTINCT ON (ix, iy) ix, iy, jam
      FROM (SELECT ix, iy, jam, sum(cup) AS cup FROM petak GROUP BY ix, iy, jam) t
     ORDER BY ix, iy, cup DESC, jam
  ),
  total AS (SELECT COALESCE(sum(revenue), 0)::BIGINT AS rev FROM agg),
  -- Yang direkam selalu menang atas yang diperkirakan.
  dipilih AS (
    SELECT a.ix, a.iy,
           COALESCE(t.jumlah, e.jumlah, 0)                  AS measured_stops,
           COALESCE(t.jam, e.jam, 0)                        AS hours_measured,
           COALESCE(t.cup, e.cup, 0)                        AS cups_measured,
           CASE WHEN t.jam > 0 THEN 'tercatat'
                WHEN e.jam > 0 THEN 'perkiraan'
                ELSE NULL END                               AS dwell_source
      FROM agg a
      LEFT JOIN tercatat  t ON t.ix = a.ix AND t.iy = a.iy
      LEFT JOIN perkiraan e ON e.ix = a.ix AND e.iy = a.iy
  )
  SELECT a.c_lat::DOUBLE PRECISION, a.c_lng::DOUBLE PRECISION,
         a.cups, a.revenue, a.orders, a.days_active,
         round(a.cups::NUMERIC / NULLIF(a.days_active, 0), 1),
         j.jam,
         CASE WHEN (SELECT rev FROM total) > 0
              THEN round(a.revenue * 100.0 / (SELECT rev FROM total), 1) ELSE 0 END,
         round(a.spread)::INTEGER,
         k.stops,
         d.measured_stops,
         round(d.hours_measured, 2),
         d.cups_measured,
         CASE WHEN d.hours_measured > 0
              THEN round(d.cups_measured::NUMERIC / d.hours_measured, 2)
              ELSE NULL END,
         d.dwell_source
    FROM agg a
    JOIN jumlah_kunjungan k ON k.ix = a.ix AND k.iy = a.iy
    JOIN dipilih          d ON d.ix = a.ix AND d.iy = a.iy
    LEFT JOIN jam_terbaik j ON j.ix = a.ix AND j.iy = a.iy
   WHERE public.get_user_role(auth.uid()) = 'admin'
   ORDER BY a.cups DESC, a.revenue DESC;
$$;

REVOKE ALL ON FUNCTION public.admin_location_clusters(DATE, DATE, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_location_clusters(DATE, DATE, INTEGER) TO authenticated;

NOTIFY pgrst, 'reload schema';
