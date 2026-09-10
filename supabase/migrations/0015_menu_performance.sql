-- ============================================================
-- 0015 — Analitik menu: yang laku, yang tidak, dan arahnya
--
-- Jalankan di Supabase SQL Editor SETELAH 0014. Aman dijalankan berulang.
--
-- Masalah: peringkat menu di halaman Analitik hanya mendaftar produk yang
-- TERJUAL, diurutkan dari omzet terbesar. Menu yang tidak laku sama sekali
-- tidak muncul di mana pun — padahal justru itu yang perlu ditindaklanjuti.
-- Pada data sungguhan ada menu yang dibawa 10 cup dan terjual 0; menu itu
-- memakan muatan gerobak setiap hari tanpa pernah menghasilkan apa pun, dan
-- tidak ada satu layar pun yang menunjukkannya.
--
-- admin_menu_performance mengembalikan SELURUH produk, termasuk yang nol,
-- dengan tiga hal yang tidak bisa dilihat dari peringkat biasa:
--
--   1. loaded      — berapa yang dibawa ke gerobak pada rentang itu.
--                    Dibandingkan dengan qty_sold, inilah yang memisahkan
--                    "tidak laku" dari "tidak pernah dibawa".
--   2. revenue_share— kontribusi omzet dalam persen, dihitung di server agar
--                    seluruh layar memakai pembagi yang sama.
--   3. prev_*      — angka periode sebelumnya yang sama panjangnya, supaya
--                    arah naik/turun terbaca tanpa membandingkan manual.
--
-- Batas hari memakai wib_day_start dari 0010 supaya penyaringnya tetap bisa
-- memakai indeks created_at.
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_menu_performance(p_from DATE, p_to DATE)
RETURNS TABLE (
  product_id    UUID,
  name          TEXT,
  category      TEXT,
  is_available  BOOLEAN,
  price         INTEGER,
  qty_sold      INTEGER,
  revenue       BIGINT,
  revenue_share NUMERIC,
  loaded        INTEGER,
  days_sold     INTEGER,
  prev_qty      INTEGER,
  prev_revenue  BIGINT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH span AS (
    SELECT d_from,
           d_to,
           -- Periode pembanding: sama panjang, tepat sebelum rentang ini.
           d_from - ((d_to - d_from) + 1) AS p_from,
           d_from - 1                     AS p_to
      FROM (
        SELECT LEAST(p_from, p_to)                                      AS d_from,
               LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365) AS d_to
      ) b
  ),
  cur AS (
    SELECT oi.product_id,
           sum(oi.quantity)::INTEGER AS qty,
           sum(oi.subtotal)::BIGINT  AS revenue,
           count(DISTINCT (o.created_at AT TIME ZONE 'Asia/Jakarta')::date)::INTEGER AS days_sold
      FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id,
           span s
     WHERE o.created_at >= public.wib_day_start(s.d_from)
       AND o.created_at <  public.wib_day_start(s.d_to + 1)
     GROUP BY oi.product_id
  ),
  prev AS (
    SELECT oi.product_id,
           sum(oi.quantity)::INTEGER AS qty,
           sum(oi.subtotal)::BIGINT  AS revenue
      FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id,
           span s
     WHERE o.created_at >= public.wib_day_start(s.p_from)
       AND o.created_at <  public.wib_day_start(s.p_to + 1)
     GROUP BY oi.product_id
  ),
  dimuat AS (
    SELECT ai.product_id, sum(ai.initial_quantity)::INTEGER AS qty
      FROM public.driver_allocation_items ai
      JOIN public.driver_daily_allocations a ON a.id = ai.allocation_id,
           span s
     WHERE a.date BETWEEN s.d_from AND s.d_to
     GROUP BY ai.product_id
  ),
  total AS (SELECT COALESCE(sum(revenue), 0)::BIGINT AS rev FROM cur)
  SELECT p.id,
         p.name,
         p.category,
         p.is_available,
         p.price,
         COALESCE(c.qty, 0),
         COALESCE(c.revenue, 0)::BIGINT,
         CASE WHEN (SELECT rev FROM total) > 0
              THEN round(COALESCE(c.revenue, 0) * 100.0 / (SELECT rev FROM total), 1)
              ELSE 0
         END,
         COALESCE(d.qty, 0),
         COALESCE(c.days_sold, 0),
         COALESCE(pv.qty, 0),
         COALESCE(pv.revenue, 0)::BIGINT
    FROM public.products p
    LEFT JOIN cur    c  ON c.product_id  = p.id
    LEFT JOIN prev   pv ON pv.product_id = p.id
    LEFT JOIN dimuat d  ON d.product_id  = p.id
   WHERE public.get_user_role(auth.uid()) = 'admin'
   ORDER BY COALESCE(c.revenue, 0) DESC, p.name;
$$;

REVOKE ALL ON FUNCTION public.admin_menu_performance(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_menu_performance(DATE, DATE) TO authenticated;

NOTIFY pgrst, 'reload schema';
