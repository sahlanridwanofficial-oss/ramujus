-- ============================================================
-- 0009 — Satu definisi cup untuk driver dan admin
--
-- Jalankan di Supabase SQL Editor SETELAH 0008. Aman dijalankan berulang.
--
-- Masalah: dua layar menghitung "cup terjual" dari sumber yang berbeda.
--
--   Admin  → order_items, disaring kategori 'smoothie'
--   Driver → driver_allocation_items.sold_quantity
--
-- sold_quantity hanya bertambah bila ada alokasi muatan untuk hari itu
-- (create_order menaikkannya di dalam blok IF v_alloc_id IS NOT NULL). Jadi
-- pada hari admin belum membuat muatan gerobak, driver melihat 0 cup
-- terjual walau penjualannya tercatat sempurna di server — dan tidak ada
-- yang salah menurut kode masing-masing layar.
--
-- driver_daily_summary() memberi driver angka dari sumber yang sama persis
-- dengan admin. Angka alokasi tetap dipakai, tetapi untuk apa yang memang
-- diwakilinya: sisa muatan di gerobak, bukan jumlah yang terjual.
--
-- admin_driver_stats_range() melengkapi sisi admin: cup per mitra, pada
-- rentang tanggal yang dipilih. admin_driver_stats() versi lama tidak punya
-- keduanya, sehingga halaman Mitra Driver hanya bisa menampilkan jumlah
-- transaksi sepanjang masa dan melabelinya "Cup".
--
-- Seluruh batas hari memakai kalender WIB, sama seperti 0007.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Ringkasan hari ini untuk driver yang sedang masuk
--
-- Tidak menerima parameter driver: selalu auth.uid(). Dengan begitu tidak
-- ada cara memakainya untuk mengintip angka mitra lain, sekalipun fungsinya
-- SECURITY DEFINER.
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
       AND (orders.created_at AT TIME ZONE 'Asia/Jakarta')::date = today.d
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

REVOKE ALL ON FUNCTION public.driver_daily_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.driver_daily_summary() TO authenticated;

-- ------------------------------------------------------------
-- 2. Statistik mitra pada rentang tanggal
--
-- Mengembalikan satu baris per driver, termasuk mitra tanpa penjualan pada
-- rentang itu — sebuah gerobak yang tidak menjual apa pun adalah informasi,
-- bukan baris yang boleh hilang dari daftar.
--
-- Rentang dibatasi 366 hari, sejalan dengan admin_sales_range.
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
     WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date BETWEEN b.d_from AND b.d_to
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

REVOKE ALL ON FUNCTION public.admin_driver_stats_range(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_driver_stats_range(DATE, DATE) TO authenticated;

-- Bentuk fungsi bertambah; minta PostgREST memuat ulang cache skemanya.
NOTIFY pgrst, 'reload schema';
