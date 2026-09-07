-- ============================================================
-- 0007 — Analitik per hari/tanggal, dan angka cup yang tidak diam-diam nol
--
-- Jalankan di Supabase SQL Editor SETELAH 0006, sebelum men-deploy versi
-- aplikasi yang menyertainya. Aman dijalankan berulang.
--
-- Dua masalah yang diperbaiki di sini.
--
-- 1) Dashboard admin menampilkan "0 Cup" padahal driver sudah menjual.
--    Penyebab yang bisa diperbaiki dari sisi database: sebuah instance yang
--    belum menjalankan 0005 masih memakai admin_daily_summary() versi lama
--    yang TIDAK punya kolom cups_today, jadi aplikasi selalu membaca nol.
--    Fungsi ringkasan di bawah ditulis ulang lengkap (tidak bergantung pada
--    0005), sehingga menjalankan berkas ini saja sudah menyembuhkan angka
--    cup di dashboard, analitik, dan laporan.
--
--    Ringkasan sekarang juga mengembalikan items_today — total unit terjual
--    dari SEMUA kategori. Bila cup = 0 tetapi item > 0, artinya produk yang
--    terjual tidak berkategori 'smoothie'; itu salah kategori di katalog,
--    bukan data yang hilang. Aplikasi menampilkan keduanya supaya selisih
--    itu terbaca, bukan jadi teka-teki.
--
-- 2) Tidak ada analitik per hari/tanggal. admin_sales_daily(p_days) hanya
--    mengenal jendela bergulir "N hari terakhir" dari NOW(), memotong hari
--    berjalan di tengah, dan melewatkan hari tanpa transaksi sama sekali —
--    sehingga tren harian bolong dan rata-rata per hari terlalu tinggi.
--    admin_sales_range(dari, sampai) menggantinya dengan rentang tanggal
--    kalender WIB yang eksplisit dan lengkap (hari nol tetap muncul), dan
--    admin_sales_hourly(tanggal) memecah satu tanggal menjadi 24 jam.
--
-- Seluruh batas hari memakai kalender WIB (Asia/Jakarta), sama seperti
-- create_order dan alokasi muatan gerobak.
-- ============================================================

-- ------------------------------------------------------------
-- Definisi cup dipusatkan (idempoten; sama seperti 0005).
-- ------------------------------------------------------------
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
-- 1. Ringkasan dashboard — cup, item, dan omzet hari ini
--
-- items_today ditambahkan agar "0 cup" tidak pernah lagi tampil tanpa
-- penjelasan: jumlah transaksi, cup, dan unit terjual terlihat bersamaan.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_daily_summary();

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
     WHERE (orders.created_at AT TIME ZONE 'Asia/Jakarta')::date = today.d
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

REVOKE ALL ON FUNCTION public.admin_daily_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_daily_summary() TO authenticated;

-- ------------------------------------------------------------
-- 2. Tren per TANGGAL kalender WIB, rentang eksplisit
--
-- Hari tanpa transaksi tetap dikembalikan sebagai baris nol. Tanpa itu,
-- grafik tren melompati hari libur dan "rata-rata per hari" dihitung dari
-- jumlah hari yang ada datanya saja — selalu lebih tinggi dari kenyataan.
--
-- Rentang dibatasi 366 hari supaya satu permintaan tidak bisa meminta
-- ribuan baris.
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
     WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date BETWEEN b.d_from AND b.d_to
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

REVOKE ALL ON FUNCTION public.admin_sales_range(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_sales_range(DATE, DATE) TO authenticated;

-- ------------------------------------------------------------
-- 3. Satu tanggal dipecah per jam WIB — 24 baris, jam sepi tetap muncul.
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
     WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date = p_date
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

REVOKE ALL ON FUNCTION public.admin_sales_hourly(DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_sales_hourly(DATE) TO authenticated;

-- ------------------------------------------------------------
-- 4. Produk terlaris pada rentang tanggal yang sama dengan grafik.
--
-- admin_top_products(p_days) memakai jendela bergulir dari NOW(), jadi
-- angkanya tidak pernah persis cocok dengan rentang tanggal yang dipilih
-- admin. Versi rentang ini memakai batas hari WIB yang sama, dan
-- menyertakan kategori supaya "cup" tidak tertukar dengan topping.
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
   WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date BETWEEN b.d_from AND b.d_to
     AND public.get_user_role(auth.uid()) = 'admin'
   GROUP BY 1, 2
   ORDER BY 4 DESC
   LIMIT GREATEST(p_limit, 1);
$$;

REVOKE ALL ON FUNCTION public.admin_top_products_range(DATE, DATE, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_top_products_range(DATE, DATE, INTEGER) TO authenticated;

-- ------------------------------------------------------------
-- 5. admin_sales_daily tetap ada demi kompatibilitas, tapi sekarang
--    memakai kalender WIB lewat admin_sales_range: "7 hari" berarti hari
--    ini plus enam hari sebelumnya, bukan 168 jam terakhir yang memotong
--    hari berjalan di tengah.
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
  SELECT r.day, r.revenue, r.orders, r.cups
    FROM public.admin_sales_range(
           ((NOW() AT TIME ZONE 'Asia/Jakarta')::date - (GREATEST(p_days, 1) - 1)),
           (NOW() AT TIME ZONE 'Asia/Jakarta')::date
         ) r
   ORDER BY r.day;
$$;

REVOKE ALL ON FUNCTION public.admin_sales_daily(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_sales_daily(INTEGER) TO authenticated;

-- ------------------------------------------------------------
-- 6. Ringkasan laporan rentang tanggal — ditulis ulang lengkap supaya
--    instance yang belum menjalankan 0005 pun mendapat angka cup di
--    halaman Laporan. Tambahan kolom items sejalan dengan dashboard.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_report_summary(DATE, DATE);

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
     WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date >= LEAST(p_from, p_to)
       AND (o.created_at AT TIME ZONE 'Asia/Jakarta')::date <= GREATEST(p_from, p_to)
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

REVOKE ALL ON FUNCTION public.admin_report_summary(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_report_summary(DATE, DATE) TO authenticated;

-- Bentuk fungsi berubah; minta PostgREST memuat ulang cache skemanya
-- sekarang, bukan menunggu. Tanpa ini panggilan RPC dari aplikasi bisa
-- terus memakai definisi lama sampai API di-restart.
NOTIFY pgrst, 'reload schema';
