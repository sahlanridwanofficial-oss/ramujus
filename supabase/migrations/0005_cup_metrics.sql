-- ============================================================
-- 0005 — Metrik cup yang benar & konsisten
--
-- Jalankan di Supabase SQL Editor SETELAH 0004, sebelum men-deploy versi
-- aplikasi yang menyertainya. Aman dijalankan berulang.
--
-- Masalah: dashboard, analitik, dan laporan admin menampilkan JUMLAH
-- PESANAN tetapi memberinya label "Cup". Satu pesanan bisa berisi beberapa
-- cup, jadi angkanya keliru. "Cup" yang benar adalah jumlah unit smoothie
-- yang terjual (kategori 'smoothie'); topping dan add-on punya satuan
-- sendiri dan tidak dihitung sebagai cup — sejalan dengan pemisahan di
-- layar muatan gerobak.
--
-- Fungsi ringkasan di sini menambahkan hitungan cup di sisi server, supaya
-- setiap menu admin menampilkan "transaksi" dan "cup" sebagai dua angka
-- yang berbeda dan konsisten, bukan satu angka yang salah label.
-- ============================================================

-- Definisi cup dipusatkan: satu pesanan menyumbang sekian cup dari baris
-- item berkategori smoothie miliknya.
CREATE OR REPLACE FUNCTION public.order_cup_count(p_order_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(sum(oi.quantity), 0)::INTEGER
    FROM public.order_items oi
    JOIN public.products pr ON pr.id = oi.product_id
   WHERE oi.order_id = p_order_id
     AND pr.category = 'smoothie';
$$;

-- ------------------------------------------------------------
-- 1. Ringkasan dashboard — tambah cups_today
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_daily_summary();

CREATE OR REPLACE FUNCTION public.admin_daily_summary()
RETURNS TABLE (
  orders_today        INTEGER,
  cups_today          INTEGER,
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
    SELECT * FROM public.orders, today
     WHERE (orders.created_at AT TIME ZONE 'Asia/Jakarta')::date = today.d
  ),
  cups AS (
    SELECT COALESCE(sum(oi.quantity), 0)::INTEGER AS n
      FROM public.order_items oi
      JOIN o ON o.id = oi.order_id
      JOIN public.products pr ON pr.id = oi.product_id
     WHERE pr.category = 'smoothie'
  ),
  a AS (
    SELECT * FROM public.driver_daily_allocations, today
     WHERE driver_daily_allocations.date = today.d
  )
  SELECT (SELECT count(*) FROM o)::INTEGER,
         (SELECT n FROM cups),
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

REVOKE ALL ON FUNCTION public.admin_daily_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_daily_summary() TO authenticated;

-- ------------------------------------------------------------
-- 2. Tren harian — tambah cups per hari
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_sales_daily(INTEGER);

CREATE OR REPLACE FUNCTION public.admin_sales_daily(p_days INTEGER DEFAULT 30)
RETURNS TABLE (
  day     DATE,
  revenue BIGINT,
  orders  INTEGER,
  cups    INTEGER
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH scoped AS (
    SELECT o.id,
           (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS day,
           o.total_amount
      FROM public.orders o
     WHERE o.created_at >= NOW() - make_interval(days => GREATEST(p_days, 1))
       AND public.get_user_role(auth.uid()) = 'admin'
  ),
  cups AS (
    SELECT s.day, COALESCE(sum(oi.quantity), 0)::INTEGER AS cups
      FROM scoped s
      JOIN public.order_items oi ON oi.order_id = s.id
      JOIN public.products pr ON pr.id = oi.product_id
     WHERE pr.category = 'smoothie'
     GROUP BY s.day
  )
  SELECT s.day,
         COALESCE(sum(s.total_amount), 0)::BIGINT,
         count(*)::INTEGER,
         COALESCE(max(c.cups), 0)::INTEGER
    FROM scoped s
    LEFT JOIN cups c ON c.day = s.day
   GROUP BY s.day
   ORDER BY s.day;
$$;

REVOKE ALL ON FUNCTION public.admin_sales_daily(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_sales_daily(INTEGER) TO authenticated;

-- ------------------------------------------------------------
-- 3. Peta armada — tambah cups_today per gerobak
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.fleet_overview();

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
     WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date = today.d
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

REVOKE ALL ON FUNCTION public.fleet_overview() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fleet_overview() TO authenticated;

-- ------------------------------------------------------------
-- 4. Ringkasan laporan rentang tanggal — tidak terpotong batas baris
--
-- Halaman laporan menampilkan maksimal 1000 baris transaksi. Sebelumnya
-- angka ringkasan (volume, omzet) dihitung dari 1000 baris itu, sehingga
-- untuk rentang besar totalnya kurang. Fungsi ini menghitung ringkasan di
-- server atas SELURUH rentang, terlepas dari batas tampilan.
--
-- p_from dan p_to adalah tanggal kalender WIB (inklusif).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_report_summary(p_from DATE, p_to DATE)
RETURNS TABLE (
  orders          INTEGER,
  cups            INTEGER,
  revenue         BIGINT,
  cash_revenue    BIGINT,
  qris_revenue    BIGINT,
  transfer_revenue BIGINT,
  cash_orders     INTEGER,
  qris_orders     INTEGER,
  transfer_orders INTEGER
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH scoped AS (
    SELECT o.id, o.total_amount, o.payment_method
      FROM public.orders o
     WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date >= p_from
       AND (o.created_at AT TIME ZONE 'Asia/Jakarta')::date <= p_to
       AND public.get_user_role(auth.uid()) = 'admin'
  ),
  cups AS (
    SELECT COALESCE(sum(oi.quantity), 0)::INTEGER AS n
      FROM scoped s
      JOIN public.order_items oi ON oi.order_id = s.id
      JOIN public.products pr ON pr.id = oi.product_id
     WHERE pr.category = 'smoothie'
  )
  SELECT count(*)::INTEGER,
         (SELECT n FROM cups),
         COALESCE(sum(total_amount), 0)::BIGINT,
         COALESCE(sum(total_amount) FILTER (WHERE payment_method = 'cash'), 0)::BIGINT,
         COALESCE(sum(total_amount) FILTER (WHERE payment_method = 'qris'), 0)::BIGINT,
         COALESCE(sum(total_amount) FILTER (WHERE payment_method = 'transfer'), 0)::BIGINT,
         count(*) FILTER (WHERE payment_method = 'cash')::INTEGER,
         count(*) FILTER (WHERE payment_method = 'qris')::INTEGER,
         count(*) FILTER (WHERE payment_method = 'transfer')::INTEGER
    FROM scoped
    -- Agregat tanpa GROUP BY selalu menghasilkan satu baris; HAVING
    -- menyaring baris itu supaya non-admin mendapat NOL baris, konsisten
    -- dengan fungsi ringkasan lain.
   HAVING public.get_user_role(auth.uid()) = 'admin';
$$;

REVOKE ALL ON FUNCTION public.admin_report_summary(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_report_summary(DATE, DATE) TO authenticated;
