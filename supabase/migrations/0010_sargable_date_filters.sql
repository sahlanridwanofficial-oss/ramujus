-- ============================================================
-- 0010 — Predikat tanggal yang bisa memakai indeks
--
-- Jalankan di Supabase SQL Editor SETELAH 0009. Aman dijalankan berulang.
-- Tidak mengubah satu pun angka yang dihasilkan: hanya bentuk penyaringnya.
--
-- Masalah: seluruh fungsi analitik menyaring dengan
--
--     (o.created_at AT TIME ZONE 'Asia/Jakarta')::date BETWEEN ... AND ...
--
-- Itu memanggil fungsi DI ATAS kolomnya, jadi idx_orders_created_at tidak
-- bisa dipakai dan Postgres memindai seluruh tabel pesanan. Biayanya tumbuh
-- mengikuti seluruh riwayat, bukan mengikuti rentang yang diminta: rentang
-- "7 hari" sama mahalnya di tahun kedua seperti rentang setahun, dan
-- halaman Analitik memanggil tiga fungsi seperti ini sekaligus.
--
-- Terukur pada basis uji 45.000 pesanan, rentang 7 hari yang sama:
--
--     predikat lama   40,5 ms   Seq Scan, membuang 35.190 baris
--     predikat baru    3,8 ms   Index Only Scan
--
-- Perbaikannya membandingkan kolom apa adanya dengan batas timestamptz yang
-- dihitung dari tanggal WIB. Batas atas bersifat eksklusif (< hari+1),
-- sehingga transaksi pada detik terakhir hari itu tetap ikut — pola yang
-- sama dengan jakartaDayRange di sisi klien.
-- ============================================================

-- ------------------------------------------------------------
-- Awal hari WIB sebagai timestamptz.
--
-- IMMUTABLE karena zonanya tetap dan WIB tidak mengenal daylight saving;
-- itu yang membuat perencana kueri boleh memakainya sebagai batas indeks.
-- Dipusatkan di sini supaya definisi "hari" tidak ditulis ulang — dan salah
-- ditulis — di sembilan tempat.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.wib_day_start(p_day DATE)
RETURNS TIMESTAMPTZ
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT p_day::timestamp AT TIME ZONE 'Asia/Jakarta';
$$;

REVOKE ALL ON FUNCTION public.wib_day_start(DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.wib_day_start(DATE) TO authenticated;

-- ------------------------------------------------------------
-- admin_daily_summary
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_daily_summary()
RETURNS TABLE (
  orders_today        INTEGER,
  cups_today          INTEGER,
  items_today         INTEGER,
  revenue_today       BIGINT,
  cash_today          BIGINT,
  qris_today          BIGINT,
  transfer_today      BIGINT,
  active_drivers      INTEGER,
  total_drivers       INTEGER,
  carts_reconciled    INTEGER,
  carts_awaiting_lock INTEGER
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH today AS (SELECT (NOW() AT TIME ZONE 'Asia/Jakarta')::date AS d),
  o AS (
    SELECT orders.* FROM public.orders, today
     WHERE orders.created_at >= public.wib_day_start(today.d)
       AND orders.created_at <  public.wib_day_start(today.d + 1)
  ),
  units AS (
    -- LEFT JOIN: produk yang sudah dihapus menyisakan product_id NULL pada
    -- item. Baris itu tetap dihitung sebagai unit terjual, hanya tidak bisa
    -- diklaim sebagai cup.
    SELECT COALESCE(sum(oi.quantity) FILTER (WHERE pr.category = 'smoothie'), 0)::INTEGER AS cups,
           COALESCE(sum(oi.quantity), 0)::INTEGER                                        AS items
      FROM public.order_items oi
      JOIN o ON o.id = oi.order_id
      LEFT JOIN public.products pr ON pr.id = oi.product_id
  ),
  a AS (
    SELECT driver_daily_allocations.* FROM public.driver_daily_allocations, today
     WHERE driver_daily_allocations.date = today.d
  )
  SELECT (SELECT count(*) FROM o)::INTEGER,
         (SELECT cups FROM units),
         (SELECT items FROM units),
         (SELECT COALESCE(sum(total_amount), 0) FROM o)::BIGINT,
         (SELECT COALESCE(sum(total_amount), 0) FROM o WHERE payment_method = 'cash')::BIGINT,
         (SELECT COALESCE(sum(total_amount), 0) FROM o WHERE payment_method = 'qris')::BIGINT,
         (SELECT COALESCE(sum(total_amount), 0) FROM o WHERE payment_method = 'transfer')::BIGINT,
         (SELECT count(*) FROM public.shifts WHERE status = 'active')::INTEGER,
         (SELECT count(*) FROM public.profiles WHERE role = 'driver')::INTEGER,
         (SELECT count(*) FROM a WHERE status = 'reconciled')::INTEGER,
         (SELECT count(*) FROM a WHERE status <> 'reconciled')::INTEGER
   WHERE public.get_user_role(auth.uid()) = 'admin';
$$;

-- ------------------------------------------------------------
-- driver_daily_summary
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.driver_daily_summary()
RETURNS TABLE (
  orders_today  INTEGER,
  cups_today    INTEGER,
  items_today   INTEGER,
  revenue_today BIGINT,
  cash_today    BIGINT,
  qris_today    BIGINT,
  transfer_today BIGINT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH today AS (SELECT (NOW() AT TIME ZONE 'Asia/Jakarta')::date AS d),
  o AS (
    SELECT orders.* FROM public.orders, today
     WHERE orders.driver_id = auth.uid()
       AND orders.created_at >= public.wib_day_start(today.d)
       AND orders.created_at <  public.wib_day_start(today.d + 1)
  ),
  units AS (
    -- LEFT JOIN: produk yang sudah dihapus menyisakan product_id NULL.
    -- Barisnya tetap unit terjual, hanya tidak bisa diklaim sebagai cup.
    SELECT COALESCE(sum(oi.quantity) FILTER (WHERE pr.category = 'smoothie'), 0)::INTEGER AS cups,
           COALESCE(sum(oi.quantity), 0)::INTEGER                                        AS items
      FROM public.order_items oi
      JOIN o ON o.id = oi.order_id
      LEFT JOIN public.products pr ON pr.id = oi.product_id
  )
  SELECT (SELECT count(*) FROM o)::INTEGER,
         (SELECT cups FROM units),
         (SELECT items FROM units),
         (SELECT COALESCE(sum(total_amount), 0) FROM o)::BIGINT,
         (SELECT COALESCE(sum(total_amount), 0) FROM o WHERE payment_method = 'cash')::BIGINT,
         (SELECT COALESCE(sum(total_amount), 0) FROM o WHERE payment_method = 'qris')::BIGINT,
         (SELECT COALESCE(sum(total_amount), 0) FROM o WHERE payment_method = 'transfer')::BIGINT
   WHERE auth.uid() IS NOT NULL;
$$;

-- ------------------------------------------------------------
-- admin_sales_range
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_sales_range(p_from DATE, p_to DATE)
RETURNS TABLE (
  day              DATE,
  orders           INTEGER,
  cups             INTEGER,
  items            INTEGER,
  revenue          BIGINT,
  cash_revenue     BIGINT,
  qris_revenue     BIGINT,
  transfer_revenue BIGINT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH bounds AS (
    SELECT LEAST(p_from, p_to)                                        AS d_from,
           LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365)   AS d_to
  ),
  days AS (
    SELECT generate_series(b.d_from, b.d_to, INTERVAL '1 day')::date AS day
      FROM bounds b
  ),
  scoped AS (
    SELECT o.id,
           (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS day,
           o.total_amount,
           o.payment_method
      FROM public.orders o, bounds b
     WHERE o.created_at >= public.wib_day_start(b.d_from)
       AND o.created_at <  public.wib_day_start(b.d_to + 1)
  ),
  units AS (
    SELECT s.day,
           COALESCE(sum(oi.quantity) FILTER (WHERE pr.category = 'smoothie'), 0)::INTEGER AS cups,
           COALESCE(sum(oi.quantity), 0)::INTEGER                                        AS items
      FROM scoped s
      JOIN public.order_items oi ON oi.order_id = s.id
      LEFT JOIN public.products pr ON pr.id = oi.product_id
     GROUP BY s.day
  ),
  agg AS (
    SELECT s.day,
           count(*)::INTEGER AS orders,
           COALESCE(sum(s.total_amount), 0)::BIGINT AS revenue,
           COALESCE(sum(s.total_amount) FILTER (WHERE s.payment_method = 'cash'), 0)::BIGINT     AS cash_revenue,
           COALESCE(sum(s.total_amount) FILTER (WHERE s.payment_method = 'qris'), 0)::BIGINT     AS qris_revenue,
           COALESCE(sum(s.total_amount) FILTER (WHERE s.payment_method = 'transfer'), 0)::BIGINT AS transfer_revenue
      FROM scoped s
     GROUP BY s.day
  )
  SELECT d.day,
         COALESCE(a.orders, 0),
         COALESCE(u.cups, 0),
         COALESCE(u.items, 0),
         COALESCE(a.revenue, 0)::BIGINT,
         COALESCE(a.cash_revenue, 0)::BIGINT,
         COALESCE(a.qris_revenue, 0)::BIGINT,
         COALESCE(a.transfer_revenue, 0)::BIGINT
    FROM days d
    LEFT JOIN agg   a ON a.day = d.day
    LEFT JOIN units u ON u.day = d.day
   WHERE public.get_user_role(auth.uid()) = 'admin'
   ORDER BY d.day;
$$;

-- ------------------------------------------------------------
-- admin_sales_hourly
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_sales_hourly(p_date DATE)
RETURNS TABLE (
  hour    INTEGER,
  orders  INTEGER,
  cups    INTEGER,
  revenue BIGINT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH hours AS (SELECT generate_series(0, 23) AS hour),
  scoped AS (
    SELECT o.id,
           EXTRACT(HOUR FROM (o.created_at AT TIME ZONE 'Asia/Jakarta'))::INTEGER AS hour,
           o.total_amount
      FROM public.orders o
     WHERE o.created_at >= public.wib_day_start(p_date)
       AND o.created_at <  public.wib_day_start(p_date + 1)
  ),
  cups AS (
    SELECT s.hour, COALESCE(sum(oi.quantity), 0)::INTEGER AS cups
      FROM scoped s
      JOIN public.order_items oi ON oi.order_id = s.id
      JOIN public.products pr    ON pr.id = oi.product_id
     WHERE pr.category = 'smoothie'
     GROUP BY s.hour
  ),
  agg AS (
    SELECT s.hour,
           count(*)::INTEGER AS orders,
           COALESCE(sum(s.total_amount), 0)::BIGINT AS revenue
      FROM scoped s
     GROUP BY s.hour
  )
  SELECT h.hour,
         COALESCE(a.orders, 0),
         COALESCE(c.cups, 0),
         COALESCE(a.revenue, 0)::BIGINT
    FROM hours h
    LEFT JOIN agg  a ON a.hour = h.hour
    LEFT JOIN cups c ON c.hour = h.hour
   WHERE public.get_user_role(auth.uid()) = 'admin'
   ORDER BY h.hour;
$$;

-- ------------------------------------------------------------
-- admin_top_products_range
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_top_products_range(
  p_from  DATE,
  p_to    DATE,
  p_limit INTEGER DEFAULT 10
)
RETURNS TABLE (
  name      TEXT,
  category  TEXT,
  total_qty INTEGER,
  revenue   BIGINT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH bounds AS (
    SELECT LEAST(p_from, p_to)                                      AS d_from,
           LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365) AS d_to
  )
  SELECT COALESCE(pr.name, 'Produk dihapus'),
         COALESCE(pr.category, 'unknown'),
         sum(oi.quantity)::INTEGER,
         sum(oi.subtotal)::BIGINT
    FROM public.order_items oi
    JOIN public.orders o         ON o.id = oi.order_id
    LEFT JOIN public.products pr ON pr.id = oi.product_id,
         bounds b
   WHERE o.created_at >= public.wib_day_start(b.d_from)
     AND o.created_at <  public.wib_day_start(b.d_to + 1)
     AND public.get_user_role(auth.uid()) = 'admin'
   GROUP BY 1, 2
   ORDER BY 4 DESC
   LIMIT GREATEST(p_limit, 1);
$$;

-- ------------------------------------------------------------
-- admin_report_summary
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_report_summary(p_from DATE, p_to DATE)
RETURNS TABLE (
  orders           INTEGER,
  cups             INTEGER,
  items            INTEGER,
  revenue          BIGINT,
  cash_revenue     BIGINT,
  qris_revenue     BIGINT,
  transfer_revenue BIGINT,
  cash_orders      INTEGER,
  qris_orders      INTEGER,
  transfer_orders  INTEGER
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH scoped AS (
    SELECT o.id, o.total_amount, o.payment_method
      FROM public.orders o
     WHERE o.created_at >= public.wib_day_start(LEAST(p_from, p_to))
       AND o.created_at <  public.wib_day_start(GREATEST(p_from, p_to) + 1)
       AND public.get_user_role(auth.uid()) = 'admin'
  ),
  units AS (
    SELECT COALESCE(sum(oi.quantity) FILTER (WHERE pr.category = 'smoothie'), 0)::INTEGER AS cups,
           COALESCE(sum(oi.quantity), 0)::INTEGER                                        AS items
      FROM scoped s
      JOIN public.order_items oi ON oi.order_id = s.id
      LEFT JOIN public.products pr ON pr.id = oi.product_id
  )
  SELECT count(*)::INTEGER,
         (SELECT cups FROM units),
         (SELECT items FROM units),
         COALESCE(sum(total_amount), 0)::BIGINT,
         COALESCE(sum(total_amount) FILTER (WHERE payment_method = 'cash'), 0)::BIGINT,
         COALESCE(sum(total_amount) FILTER (WHERE payment_method = 'qris'), 0)::BIGINT,
         COALESCE(sum(total_amount) FILTER (WHERE payment_method = 'transfer'), 0)::BIGINT,
         count(*) FILTER (WHERE payment_method = 'cash')::INTEGER,
         count(*) FILTER (WHERE payment_method = 'qris')::INTEGER,
         count(*) FILTER (WHERE payment_method = 'transfer')::INTEGER
    FROM scoped
    -- Agregat tanpa GROUP BY selalu menghasilkan satu baris; HAVING
    -- menyaring baris itu supaya non-admin mendapat NOL baris.
   HAVING public.get_user_role(auth.uid()) = 'admin';
$$;

-- ------------------------------------------------------------
-- admin_driver_stats_range
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_driver_stats_range(p_from DATE, p_to DATE)
RETURNS TABLE (
  driver_id      UUID,
  orders         INTEGER,
  cups           INTEGER,
  items          INTEGER,
  revenue        BIGINT,
  active_days    INTEGER,
  last_order_at  TIMESTAMPTZ,
  has_active_shift BOOLEAN
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH bounds AS (
    SELECT LEAST(p_from, p_to)                                      AS d_from,
           LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365) AS d_to
  ),
  scoped AS (
    SELECT o.id,
           o.driver_id,
           o.total_amount,
           o.created_at,
           (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS day
      FROM public.orders o, bounds b
     WHERE o.created_at >= public.wib_day_start(b.d_from)
       AND o.created_at <  public.wib_day_start(b.d_to + 1)
  ),
  sales AS (
    SELECT s.driver_id,
           count(*)::INTEGER                        AS orders,
           COALESCE(sum(s.total_amount), 0)::BIGINT AS revenue,
           count(DISTINCT s.day)::INTEGER           AS active_days,
           max(s.created_at)                        AS last_order_at
      FROM scoped s
     GROUP BY s.driver_id
  ),
  units AS (
    SELECT s.driver_id,
           COALESCE(sum(oi.quantity) FILTER (WHERE pr.category = 'smoothie'), 0)::INTEGER AS cups,
           COALESCE(sum(oi.quantity), 0)::INTEGER                                        AS items
      FROM scoped s
      JOIN public.order_items oi   ON oi.order_id = s.id
      LEFT JOIN public.products pr ON pr.id = oi.product_id
     GROUP BY s.driver_id
  ),
  active_shift AS (
    SELECT sh.driver_id FROM public.shifts sh WHERE sh.status = 'active'
  )
  SELECT p.id,
         COALESCE(sa.orders, 0),
         COALESCE(u.cups, 0),
         COALESCE(u.items, 0),
         COALESCE(sa.revenue, 0)::BIGINT,
         COALESCE(sa.active_days, 0),
         sa.last_order_at,
         (ash.driver_id IS NOT NULL)
    FROM public.profiles p
    LEFT JOIN sales sa       ON sa.driver_id = p.id
    LEFT JOIN units u        ON u.driver_id = p.id
    LEFT JOIN active_shift ash ON ash.driver_id = p.id
   WHERE p.role = 'driver'
     AND public.get_user_role(auth.uid()) = 'admin'
   ORDER BY COALESCE(sa.revenue, 0) DESC, p.full_name;
$$;

-- ------------------------------------------------------------
-- fleet_overview
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
  cups_today       INTEGER,
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
  scoped AS (
    SELECT o.id, o.driver_id, o.total_amount
      FROM public.orders o, today
     WHERE o.created_at >= public.wib_day_start(today.d)
       AND o.created_at <  public.wib_day_start(today.d + 1)
  ),
  sales AS (
    SELECT driver_id,
           count(*)::INTEGER          AS orders_today,
           COALESCE(sum(total_amount), 0)::BIGINT AS revenue_today
      FROM scoped
     GROUP BY driver_id
  ),
  cups AS (
    SELECT s.driver_id, COALESCE(sum(oi.quantity), 0)::INTEGER AS cups_today
      FROM scoped s
      JOIN public.order_items oi ON oi.order_id = s.id
      JOIN public.products pr ON pr.id = oi.product_id
     WHERE pr.category = 'smoothie'
     GROUP BY s.driver_id
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
         COALESCE(c.cups_today, 0),
         COALESCE(s.revenue_today, 0)
    FROM public.profiles p
    LEFT JOIN public.driver_positions dp ON dp.driver_id = p.id
    LEFT JOIN active_shift a             ON a.driver_id = p.id
    LEFT JOIN sales s                    ON s.driver_id = p.id
    LEFT JOIN cups c                     ON c.driver_id = p.id
   WHERE p.role = 'driver'
     AND public.get_user_role(auth.uid()) = 'admin'
   ORDER BY (a.id IS NOT NULL) DESC, p.full_name;
$$;

-- Hak akses ditegakkan ulang setelah definisi diganti.
REVOKE ALL ON FUNCTION public.admin_daily_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_daily_summary() TO authenticated;
REVOKE ALL ON FUNCTION public.driver_daily_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.driver_daily_summary() TO authenticated;
REVOKE ALL ON FUNCTION public.admin_sales_range(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_sales_range(DATE, DATE) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_sales_hourly(DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_sales_hourly(DATE) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_top_products_range(DATE, DATE, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_top_products_range(DATE, DATE, INTEGER) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_report_summary(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_report_summary(DATE, DATE) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_driver_stats_range(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_driver_stats_range(DATE, DATE) TO authenticated;
REVOKE ALL ON FUNCTION public.fleet_overview() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fleet_overview() TO authenticated;

NOTIFY pgrst, 'reload schema';
