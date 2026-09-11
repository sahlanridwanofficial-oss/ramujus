-- ============================================================
-- 0020 — Lama mangkal direkam, bukan ditebak
--
-- Jalankan di Supabase SQL Editor SETELAH 0019. Aman dijalankan berulang.
--
-- 0019 memperkirakan lama mangkal dari rentang stempel pesanan. Perkiraan
-- itu runtuh karena satu kebiasaan nyata: driver sering mencatat pesanan
-- SETELAH selesai melayani, beberapa sekaligus.
--
-- Pada data produksi polanya terbaca bersih. Dari 44 pasang pesanan
-- berurutan, 7 berjarak 10–25 detik, dan sisanya berjarak 14 menit ke
-- atas. Tidak ada satu pun di antara 25 detik dan 14 menit. Celah sebersih
-- itu berarti yang pendek bukan penjualan beruntun — itu jari yang baru
-- sempat mengetik.
--
-- Akibatnya ke arah yang paling berbahaya untuk keputusan sewa:
--
--   Dilayani 16:00, 16:30, 17:00 -> dicatat semua pukul 17:00
--   Rentang terbaca 1 menit, padahal sebenarnya 1 jam
--   Cup per jam tampil berkali-kali lipat lebih tinggi dari kenyataan
--
-- Ambang 15 menit di 0019 menangkis kunjungan yang SELURUHNYA dicatat
-- belakangan, tetapi tidak yang sebagian. Dan tidak ada SQL yang bisa
-- memperbaikinya, karena waktunya memang tidak pernah direkam.
--
-- Maka direkam. Satu ketukan saat gerobak sampai di titik, satu saat
-- pindah. Sekitar lima sampai delapan ketukan sehari, dan lama mangkal
-- berhenti jadi tebakan.
--
-- Perkiraan lama dipertahankan sebagai cadangan untuk hari-hari yang
-- tombolnya tidak dipakai, tetapi hasilnya ditandai berbeda: analitik
-- harus bisa memisahkan angka yang diukur dari angka yang diperkirakan.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Tabel
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.driver_stops (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  driver_id   UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  shift_id    UUID REFERENCES public.shifts(id) ON DELETE SET NULL,
  started_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at    TIMESTAMPTZ,
  latitude    DOUBLE PRECISION,
  longitude   DOUBLE PRECISION,
  accuracy    DOUBLE PRECISION,
  -- Kunci idempotensi: ketukan yang gagal terkirim boleh dicoba ulang
  -- tanpa menghasilkan dua catatan mangkal.
  client_stop_id UUID UNIQUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT driver_stops_urutan_waktu CHECK (ended_at IS NULL OR ended_at >= started_at)
);

CREATE INDEX IF NOT EXISTS idx_driver_stops_driver_waktu
  ON public.driver_stops (driver_id, started_at DESC);

-- Satu gerobak hanya boleh punya satu mangkal terbuka. Ditegakkan indeks,
-- bukan hanya kode aplikasi: dua ketukan beruntun karena sinyal lambat
-- tidak boleh menghasilkan dua mangkal yang berjalan bersamaan.
CREATE UNIQUE INDEX IF NOT EXISTS idx_driver_stops_satu_terbuka
  ON public.driver_stops (driver_id) WHERE ended_at IS NULL;

ALTER TABLE public.driver_stops ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  CREATE POLICY driver_stops_baca_sendiri ON public.driver_stops
    FOR SELECT TO authenticated
    USING (driver_id = auth.uid() OR public.get_user_role(auth.uid()) = 'admin');
EXCEPTION WHEN duplicate_object THEN NULL;
END;
$$;

DO $$
BEGIN
  -- Sengaja tidak ada kebijakan INSERT/UPDATE untuk siapa pun. Menulis
  -- hanya lewat fungsi di bawah, supaya aturan "satu mangkal terbuka" dan
  -- penutupan otomatis tidak bisa dilewati dari klien.
  CREATE POLICY driver_stops_tanpa_tulis_langsung ON public.driver_stops
    FOR UPDATE TO authenticated USING (false);
EXCEPTION WHEN duplicate_object THEN NULL;
END;
$$;

-- ------------------------------------------------------------
-- 2. Mulai mangkal
--
-- Menutup mangkal sebelumnya secara otomatis. Driver yang lupa menekan
-- "pindah" tetap menghasilkan data yang benar — dan lupa itu pasti terjadi,
-- jadi lebih baik ditangani daripada diminta untuk tidak terjadi.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.driver_start_stop(
  p_latitude       DOUBLE PRECISION DEFAULT NULL,
  p_longitude      DOUBLE PRECISION DEFAULT NULL,
  p_accuracy       DOUBLE PRECISION DEFAULT NULL,
  p_client_stop_id UUID DEFAULT NULL
)
RETURNS public.driver_stops
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_driver UUID := auth.uid();
  v_shift  UUID;
  v_stop   public.driver_stops;
BEGIN
  IF v_driver IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  -- Ketukan yang sama dikirim ulang: kembalikan catatan yang sudah ada.
  IF p_client_stop_id IS NOT NULL THEN
    SELECT * INTO v_stop FROM public.driver_stops
     WHERE client_stop_id = p_client_stop_id AND driver_id = v_driver;
    IF FOUND THEN
      RETURN v_stop;
    END IF;
  END IF;

  UPDATE public.driver_stops
     SET ended_at = NOW()
   WHERE driver_id = v_driver AND ended_at IS NULL;

  SELECT id INTO v_shift FROM public.shifts
   WHERE driver_id = v_driver AND status = 'active'
   ORDER BY start_time DESC LIMIT 1;

  INSERT INTO public.driver_stops
    (driver_id, shift_id, latitude, longitude, accuracy, client_stop_id)
  VALUES
    (v_driver, v_shift, p_latitude, p_longitude, p_accuracy, p_client_stop_id)
  RETURNING * INTO v_stop;

  RETURN v_stop;
END;
$$;

-- ------------------------------------------------------------
-- 3. Selesai mangkal
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.driver_end_stop()
RETURNS public.driver_stops
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_driver UUID := auth.uid();
  v_stop   public.driver_stops;
BEGIN
  IF v_driver IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  UPDATE public.driver_stops
     SET ended_at = NOW()
   WHERE driver_id = v_driver AND ended_at IS NULL
  RETURNING * INTO v_stop;

  -- Tidak ada mangkal terbuka bukan kesalahan: driver bisa menekan dua
  -- kali, atau menekan setelah aplikasi dimuat ulang.
  RETURN v_stop;
END;
$$;

-- ------------------------------------------------------------
-- 4. Mangkal yang sedang berjalan — untuk layar driver
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.driver_current_stop()
RETURNS TABLE (
  id          UUID,
  started_at  TIMESTAMPTZ,
  latitude    DOUBLE PRECISION,
  longitude   DOUBLE PRECISION,
  minutes     INTEGER,
  cups        INTEGER
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT s.id,
         s.started_at,
         s.latitude,
         s.longitude,
         (EXTRACT(EPOCH FROM (NOW() - s.started_at)) / 60)::INTEGER,
         COALESCE((
           SELECT sum(oi.quantity)::INTEGER
             FROM public.orders o
             JOIN public.order_items oi ON oi.order_id = o.id
             JOIN public.products pr ON pr.id = oi.product_id AND pr.category = 'smoothie'
            WHERE o.driver_id = s.driver_id AND o.created_at >= s.started_at
         ), 0)
    FROM public.driver_stops s
   WHERE s.driver_id = auth.uid() AND s.ended_at IS NULL
   LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.driver_start_stop(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.driver_end_stop() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.driver_current_stop() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.driver_start_stop(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.driver_end_stop() TO authenticated;
GRANT EXECUTE ON FUNCTION public.driver_current_stop() TO authenticated;

-- ------------------------------------------------------------
-- 5. Analitik lokasi memakai lama mangkal yang direkam
--
-- Kalau ada catatan mangkal, ia yang dipakai. Kalau tidak, perkiraan dari
-- rentang pesanan tetap jalan — tetapi hasilnya ditandai lewat kolom
-- dwell_source, supaya angka yang diukur tidak pernah terbaca sama
-- meyakinkan dengan angka yang diperkirakan.
--
-- Mangkal yang lupa ditutup dibatasi 6 jam. Gerobak tidak mangkal di satu
-- titik lebih lama dari itu; sisanya pasti tombol yang terlupa.
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
  -- dicatat, dengan kelonggaran 15 menit setelah mangkal itu ditutup.
  --
  -- Kelonggaran itu bukan kelonggaran asal. Justru karena driver mencatat
  -- setelah selesai melayani, catatannya sering mendarat tepat saat atau
  -- sesudah gerobak pindah. Jendela yang ketat akan membuang persis
  -- pesanan yang ingin diukur — dan pengujian menemukan itu: mangkal
  -- 10:00–11:00 dengan tiga pesanan tercatat 11:00:00, 11:00:11, dan
  -- 11:00:22 menghasilkan nol cup.
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
      ) m ON p.created_at < m.ended_at + INTERVAL '15 minutes'
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
