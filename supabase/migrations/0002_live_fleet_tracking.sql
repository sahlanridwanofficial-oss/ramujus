-- ============================================================
-- 0002 — Pelacakan armada realtime & penskalaan untuk 100 gerobak
--
-- Jalankan di Supabase SQL Editor SETELAH 0001, sebelum men-deploy
-- versi aplikasi yang menyertainya. Aman dijalankan berulang.
--
-- Latar belakang:
-- Peta admin sebelumnya menampilkan titik ORDER, bukan posisi driver, dan
-- location_logs hanya ditulis satu kali per pesanan. Tidak ada posisi
-- terkini yang bisa dibaca. Sekaligus, halaman Mitra Driver melakukan
-- 1 + 2N query dan menarik SELURUH riwayat pesanan tiap driver hanya untuk
-- dijumlahkan di browser — pada 100 gerobak itu 201 query per pembukaan
-- halaman.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Posisi terkini per driver
--
-- Dipisah dari location_logs secara sengaja. Pada 100 gerobak yang
-- mengirim posisi tiap 30 detik selama 12 jam, histori tumbuh ~144 ribu
-- baris per hari. Membaca "posisi sekarang" dengan memindai tabel sebesar
-- itu tidak layak, dan Realtime pada tabel append-only sebesar itu boros.
-- Tabel ini selalu berisi tepat satu baris per driver.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.driver_positions (
  driver_id   UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  shift_id    UUID REFERENCES public.shifts(id) ON DELETE SET NULL,
  latitude    DOUBLE PRECISION NOT NULL,
  longitude   DOUBLE PRECISION NOT NULL,
  accuracy    DOUBLE PRECISION,
  speed       DOUBLE PRECISION,
  heading     DOUBLE PRECISION,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_driver_positions_recorded
  ON public.driver_positions (recorded_at DESC);

ALTER TABLE public.driver_positions ENABLE ROW LEVEL SECURITY;

-- Penulisan hanya lewat update_driver_position(); tidak ada policy INSERT
-- atau UPDATE, sehingga driver tidak bisa memalsukan posisinya lewat
-- PostgREST langsung dengan koordinat sembarang di luar validasi.
DROP POLICY IF EXISTS "Admin can view all driver positions" ON public.driver_positions;
CREATE POLICY "Admin can view all driver positions" ON public.driver_positions
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'admin');

DROP POLICY IF EXISTS "Drivers can view own position" ON public.driver_positions;
CREATE POLICY "Drivers can view own position" ON public.driver_positions
  FOR SELECT USING (auth.uid() = driver_id);

-- ------------------------------------------------------------
-- 2. Indeks untuk kueri yang akan tumbuh besar
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_location_logs_driver_recorded
  ON public.location_logs (driver_id, recorded_at DESC);

CREATE INDEX IF NOT EXISTS idx_location_logs_recorded
  ON public.location_logs (recorded_at DESC);

CREATE INDEX IF NOT EXISTS idx_orders_driver_created
  ON public.orders (driver_id, created_at DESC);

-- Peta sebaran penjualan hanya memakai pesanan yang punya koordinat.
CREATE INDEX IF NOT EXISTS idx_orders_geo_created
  ON public.orders (created_at DESC)
  WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

-- ------------------------------------------------------------
-- 3. Kirim posisi (dipanggil aplikasi driver secara berkala)
--
-- Menulis posisi terkini setiap kali dipanggil, tetapi hanya menambah
-- baris histori bila jarak waktunya sudah melewati ambang. Tanpa
-- pembatasan ini, 100 gerobak dengan interval 30 detik akan menulis
-- ~144 ribu baris histori per hari.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_driver_position(
  p_latitude   DOUBLE PRECISION,
  p_longitude  DOUBLE PRECISION,
  p_accuracy   DOUBLE PRECISION DEFAULT NULL,
  p_speed      DOUBLE PRECISION DEFAULT NULL,
  p_heading    DOUBLE PRECISION DEFAULT NULL,
  p_history_interval_seconds INTEGER DEFAULT 120
)
RETURNS public.driver_positions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_driver   UUID := auth.uid();
  v_shift_id UUID;
  v_last_log TIMESTAMPTZ;
  v_position public.driver_positions;
BEGIN
  IF v_driver IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '28000';
  END IF;

  IF p_latitude IS NULL OR p_longitude IS NULL THEN
    RAISE EXCEPTION 'COORDINATES_REQUIRED' USING ERRCODE = '22023';
  END IF;

  IF p_latitude < -90 OR p_latitude > 90 OR p_longitude < -180 OR p_longitude > 180 THEN
    RAISE EXCEPTION 'COORDINATES_OUT_OF_RANGE' USING ERRCODE = '22023';
  END IF;

  -- Pelacakan hanya berjalan selama driver sedang berdinas.
  SELECT id INTO v_shift_id
    FROM public.shifts
   WHERE driver_id = v_driver AND status = 'active'
   LIMIT 1;

  IF v_shift_id IS NULL THEN
    RAISE EXCEPTION 'SHIFT_NOT_ACTIVE' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.driver_positions AS dp (
    driver_id, shift_id, latitude, longitude, accuracy, speed, heading,
    recorded_at, updated_at
  )
  VALUES (
    v_driver, v_shift_id, p_latitude, p_longitude, p_accuracy, p_speed, p_heading,
    NOW(), NOW()
  )
  ON CONFLICT (driver_id) DO UPDATE
    SET shift_id    = EXCLUDED.shift_id,
        latitude    = EXCLUDED.latitude,
        longitude   = EXCLUDED.longitude,
        accuracy    = EXCLUDED.accuracy,
        speed       = EXCLUDED.speed,
        heading     = EXCLUDED.heading,
        recorded_at = EXCLUDED.recorded_at,
        updated_at  = NOW()
  RETURNING dp.* INTO v_position;

  SELECT max(recorded_at) INTO v_last_log
    FROM public.location_logs
   WHERE driver_id = v_driver AND shift_id = v_shift_id;

  IF v_last_log IS NULL
     OR v_last_log < NOW() - make_interval(secs => GREATEST(p_history_interval_seconds, 0))
  THEN
    INSERT INTO public.location_logs (driver_id, shift_id, latitude, longitude, accuracy)
    VALUES (v_driver, v_shift_id, p_latitude, p_longitude, p_accuracy);
  END IF;

  RETURN v_position;
END;
$$;

REVOKE ALL ON FUNCTION public.update_driver_position(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_driver_position(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, INTEGER) TO authenticated;

-- ------------------------------------------------------------
-- 4. Ringkasan armada untuk peta admin — satu query untuk 100 gerobak
--
-- Mengembalikan satu baris per driver aktif beserta posisi terkini,
-- umur posisi, dan penjualan hari ini. Versi lama akan memerlukan
-- ratusan query terpisah untuk informasi yang sama.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fleet_overview()
RETURNS TABLE (
  driver_id        UUID,
  full_name        TEXT,
  phone            TEXT,
  driver_status    TEXT,
  latitude         DOUBLE PRECISION,
  longitude        DOUBLE PRECISION,
  accuracy         DOUBLE PRECISION,
  speed            DOUBLE PRECISION,
  heading          DOUBLE PRECISION,
  recorded_at      TIMESTAMPTZ,
  seconds_since    INTEGER,
  shift_id         UUID,
  shift_started_at TIMESTAMPTZ,
  on_shift         BOOLEAN,
  orders_today     INTEGER,
  revenue_today    BIGINT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH today AS (
    SELECT (NOW() AT TIME ZONE 'Asia/Jakarta')::date AS d
  ),
  sales AS (
    SELECT o.driver_id,
           count(*)::INTEGER          AS orders_today,
           COALESCE(sum(o.total_amount), 0)::BIGINT AS revenue_today
      FROM public.orders o, today
     WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date = today.d
     GROUP BY o.driver_id
  ),
  active_shift AS (
    SELECT s.driver_id, s.id, s.start_time
      FROM public.shifts s
     WHERE s.status = 'active'
  )
  SELECT p.id,
         p.full_name,
         p.phone,
         p.status,
         dp.latitude,
         dp.longitude,
         dp.accuracy,
         dp.speed,
         dp.heading,
         dp.recorded_at,
         CASE WHEN dp.recorded_at IS NULL THEN NULL
              ELSE EXTRACT(EPOCH FROM (NOW() - dp.recorded_at))::INTEGER
         END,
         a.id,
         a.start_time,
         (a.id IS NOT NULL),
         COALESCE(s.orders_today, 0),
         COALESCE(s.revenue_today, 0)
    FROM public.profiles p
    LEFT JOIN public.driver_positions dp ON dp.driver_id = p.id
    LEFT JOIN active_shift a             ON a.driver_id = p.id
    LEFT JOIN sales s                    ON s.driver_id = p.id
   WHERE p.role = 'driver'
     AND public.get_user_role(auth.uid()) = 'admin'
   ORDER BY (a.id IS NOT NULL) DESC, p.full_name;
$$;

REVOKE ALL ON FUNCTION public.fleet_overview() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fleet_overview() TO authenticated;

-- ------------------------------------------------------------
-- 5. Statistik mitra driver — menggantikan pola 1 + 2N query
--
-- Halaman Mitra Driver sebelumnya mengambil seluruh baris orders milik
-- setiap driver hanya untuk menjumlahkannya di browser. Pada 100 driver
-- dengan riwayat satu tahun, itu puluhan ribu baris per pembukaan halaman.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_driver_stats()
RETURNS TABLE (
  driver_id        UUID,
  total_orders     INTEGER,
  total_revenue    BIGINT,
  orders_today     INTEGER,
  revenue_today    BIGINT,
  has_active_shift BOOLEAN,
  last_order_at    TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH today AS (
    SELECT (NOW() AT TIME ZONE 'Asia/Jakarta')::date AS d
  ),
  agg AS (
    SELECT o.driver_id,
           count(*)::INTEGER AS total_orders,
           COALESCE(sum(o.total_amount), 0)::BIGINT AS total_revenue,
           count(*) FILTER (
             WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date = (SELECT d FROM today)
           )::INTEGER AS orders_today,
           COALESCE(sum(o.total_amount) FILTER (
             WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date = (SELECT d FROM today)
           ), 0)::BIGINT AS revenue_today,
           max(o.created_at) AS last_order_at
      FROM public.orders o
     GROUP BY o.driver_id
  )
  SELECT p.id,
         COALESCE(a.total_orders, 0),
         COALESCE(a.total_revenue, 0),
         COALESCE(a.orders_today, 0),
         COALESCE(a.revenue_today, 0),
         EXISTS (SELECT 1 FROM public.shifts s
                  WHERE s.driver_id = p.id AND s.status = 'active'),
         a.last_order_at
    FROM public.profiles p
    LEFT JOIN agg a ON a.driver_id = p.id
   WHERE p.role = 'driver'
     AND public.get_user_role(auth.uid()) = 'admin';
$$;

REVOKE ALL ON FUNCTION public.admin_driver_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_driver_stats() TO authenticated;

-- ------------------------------------------------------------
-- 6. Pemangkasan histori lokasi
--
-- Histori GPS tumbuh paling cepat di antara semua tabel. Jadwalkan lewat
-- pg_cron bila tersedia, atau panggil manual secara berkala.
--   SELECT public.prune_location_logs(60);
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prune_location_logs(p_keep_days INTEGER DEFAULT 60)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_deleted INTEGER;
BEGIN
  DELETE FROM public.location_logs
   WHERE recorded_at < NOW() - make_interval(days => GREATEST(p_keep_days, 1));
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_location_logs(INTEGER) FROM PUBLIC;

-- ------------------------------------------------------------
-- 7. Realtime untuk posisi armada
-- ------------------------------------------------------------
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.driver_positions;
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_object THEN
    RAISE NOTICE 'Publikasi supabase_realtime tidak ditemukan; lewati.';
END;
$$;

-- ------------------------------------------------------------
-- 8. Agregasi analitik di server
--
-- Halaman analitik sebelumnya menarik SELURUH baris pesanan pada rentang
-- yang dipilih lalu menjumlahkannya di browser. Pada 100 gerobak dengan
-- rentang 90 hari itu ratusan ribu baris untuk menghasilkan satu grafik.
--
-- Kueri produk terlaris juga memfilter order_items.created_at — kolom yang
-- tidak pernah ada di tabel itu — sehingga selalu gagal dan menampilkan
-- daftar kosong tanpa pesan error. Di sini rentang waktu diambil dari
-- orders.created_at lewat join, sebagaimana mestinya.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_sales_daily(p_days INTEGER DEFAULT 30)
RETURNS TABLE (
  day      DATE,
  revenue  BIGINT,
  orders   INTEGER
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS day,
         COALESCE(sum(o.total_amount), 0)::BIGINT,
         count(*)::INTEGER
    FROM public.orders o
   WHERE o.created_at >= NOW() - make_interval(days => GREATEST(p_days, 1))
     AND public.get_user_role(auth.uid()) = 'admin'
   GROUP BY 1
   ORDER BY 1;
$$;

REVOKE ALL ON FUNCTION public.admin_sales_daily(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_sales_daily(INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_top_products(
  p_days  INTEGER DEFAULT 30,
  p_limit INTEGER DEFAULT 10
)
RETURNS TABLE (
  name      TEXT,
  total_qty INTEGER,
  revenue   BIGINT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(pr.name, 'Item'),
         sum(oi.quantity)::INTEGER,
         sum(oi.subtotal)::BIGINT
    FROM public.order_items oi
    JOIN public.orders o    ON o.id = oi.order_id
    LEFT JOIN public.products pr ON pr.id = oi.product_id
   WHERE o.created_at >= NOW() - make_interval(days => GREATEST(p_days, 1))
     AND public.get_user_role(auth.uid()) = 'admin'
   GROUP BY 1
   ORDER BY 3 DESC
   LIMIT GREATEST(p_limit, 1);
$$;

REVOKE ALL ON FUNCTION public.admin_top_products(INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_top_products(INTEGER, INTEGER) TO authenticated;
