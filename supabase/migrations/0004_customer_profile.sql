-- ============================================================
-- 0004 — Profil pembeli pada transaksi
--
-- Jalankan di Supabase SQL Editor SETELAH 0003, sebelum men-deploy versi
-- aplikasi yang menyertainya. Aman dijalankan berulang.
--
-- Mencatat perkiraan profil pembeli agar pemilik tahu siapa yang benar-
-- benar membeli, jam berapa, dan rasa apa. Semuanya opsional: driver yang
-- sedang melayani antrean panjang boleh melewatinya, dan data kosong jauh
-- lebih baik daripada tebakan asal.
--
-- Sengaja TIDAK menyimpan nama, nomor telepon, atau apa pun yang dapat
-- mengidentifikasi orang. Hanya kelompok kasar, dan isinya perkiraan
-- driver — bukan data identitas.
-- ============================================================

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS customer_gender    TEXT,
  ADD COLUMN IF NOT EXISTS customer_age_range TEXT,
  ADD COLUMN IF NOT EXISTS customer_type      TEXT;

DO $$
BEGIN
  ALTER TABLE public.orders
    ADD CONSTRAINT orders_customer_gender_check
    CHECK (customer_gender IS NULL OR customer_gender IN ('male', 'female'));
EXCEPTION WHEN duplicate_object THEN NULL;
END;
$$;

DO $$
BEGIN
  ALTER TABLE public.orders
    ADD CONSTRAINT orders_customer_age_range_check
    CHECK (customer_age_range IS NULL OR customer_age_range IN
      ('kid', 'teen', 'young_adult', 'adult', 'senior'));
EXCEPTION WHEN duplicate_object THEN NULL;
END;
$$;

DO $$
BEGIN
  ALTER TABLE public.orders
    ADD CONSTRAINT orders_customer_type_check
    CHECK (customer_type IS NULL OR customer_type IN ('new', 'returning'));
EXCEPTION WHEN duplicate_object THEN NULL;
END;
$$;

-- ------------------------------------------------------------
-- create_order menerima profil pembeli
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_order(
  UUID, JSONB, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, UUID, TIMESTAMPTZ
);

CREATE OR REPLACE FUNCTION public.create_order(
  p_shift_id           UUID,
  p_items              JSONB,
  p_payment_method     TEXT DEFAULT 'cash',
  p_latitude           DOUBLE PRECISION DEFAULT NULL,
  p_longitude          DOUBLE PRECISION DEFAULT NULL,
  p_accuracy           DOUBLE PRECISION DEFAULT NULL,
  p_customer_notes     TEXT DEFAULT NULL,
  p_client_order_id    UUID DEFAULT NULL,
  p_created_at         TIMESTAMPTZ DEFAULT NULL,
  p_customer_gender    TEXT DEFAULT NULL,
  p_customer_age_range TEXT DEFAULT NULL,
  p_customer_type      TEXT DEFAULT NULL
)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_driver       UUID := auth.uid();
  v_order        public.orders;
  v_order_number TEXT;
  v_total        INTEGER := 0;
  v_alloc_id     UUID;
  v_item         JSONB;
  v_product_id   UUID;
  v_product_name TEXT;
  v_qty          INTEGER;
  v_price        INTEGER;
  v_remaining    INTEGER;
  v_created_at   TIMESTAMPTZ;
BEGIN
  IF v_driver IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '28000';
  END IF;

  IF p_client_order_id IS NOT NULL THEN
    SELECT * INTO v_order
      FROM public.orders
     WHERE client_order_id = p_client_order_id
       AND driver_id = v_driver;
    IF FOUND THEN
      RETURN v_order;
    END IF;
  END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_CART' USING ERRCODE = '22023';
  END IF;

  IF p_payment_method NOT IN ('cash', 'qris', 'transfer') THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD' USING ERRCODE = '22023';
  END IF;

  -- Nilai profil yang tidak dikenal diabaikan, bukan ditolak: satu pilihan
  -- salah dari klien tidak boleh menggagalkan penjualan yang sah.
  IF p_customer_gender IS NOT NULL AND p_customer_gender NOT IN ('male', 'female') THEN
    p_customer_gender := NULL;
  END IF;
  IF p_customer_age_range IS NOT NULL AND p_customer_age_range NOT IN
     ('kid', 'teen', 'young_adult', 'adult', 'senior') THEN
    p_customer_age_range := NULL;
  END IF;
  IF p_customer_type IS NOT NULL AND p_customer_type NOT IN ('new', 'returning') THEN
    p_customer_type := NULL;
  END IF;

  PERFORM 1 FROM public.shifts
   WHERE id = p_shift_id AND driver_id = v_driver AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHIFT_NOT_ACTIVE' USING ERRCODE = '22023';
  END IF;

  v_created_at := COALESCE(p_created_at, NOW());
  IF v_created_at > NOW() + INTERVAL '2 minutes'
     OR v_created_at < NOW() - INTERVAL '2 days' THEN
    v_created_at := NOW();
  END IF;

  SELECT id INTO v_alloc_id
    FROM public.driver_daily_allocations
   WHERE driver_id = v_driver
     AND date = (v_created_at AT TIME ZONE 'Asia/Jakarta')::date
     AND status <> 'reconciled';

  v_order_number := 'RMJ-'
    || to_char(v_created_at AT TIME ZONE 'Asia/Jakarta', 'YYYYMMDD-HH24MISS')
    || '-' || lpad((nextval('public.order_number_seq') % 100000)::text, 5, '0');

  INSERT INTO public.orders (
    shift_id, driver_id, order_number,
    latitude, longitude, total_amount, payment_method, customer_notes,
    client_order_id, created_at,
    customer_gender, customer_age_range, customer_type
  )
  VALUES (
    p_shift_id, v_driver, v_order_number,
    p_latitude, p_longitude, 0, p_payment_method, p_customer_notes,
    p_client_order_id, v_created_at,
    p_customer_gender, p_customer_age_range, p_customer_type
  )
  RETURNING * INTO v_order;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::UUID;
    v_qty        := (v_item->>'quantity')::INTEGER;

    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'INVALID_QUANTITY' USING ERRCODE = '22023';
    END IF;

    SELECT price, name INTO v_price, v_product_name
      FROM public.products
     WHERE id = v_product_id AND is_available = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'PRODUCT_UNAVAILABLE' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
    VALUES (v_order.id, v_product_id, v_qty, v_price, v_price * v_qty);

    v_total := v_total + (v_price * v_qty);

    IF v_alloc_id IS NOT NULL THEN
      SELECT initial_quantity - sold_quantity INTO v_remaining
        FROM public.driver_allocation_items
       WHERE allocation_id = v_alloc_id AND product_id = v_product_id
       FOR UPDATE;

      IF FOUND THEN
        IF v_remaining < v_qty THEN
          RAISE EXCEPTION 'INSUFFICIENT_STOCK:%', v_product_name USING ERRCODE = '22023';
        END IF;

        UPDATE public.driver_allocation_items
           SET sold_quantity = sold_quantity + v_qty
         WHERE allocation_id = v_alloc_id AND product_id = v_product_id;
      END IF;
    END IF;
  END LOOP;

  UPDATE public.orders
     SET total_amount = v_total
   WHERE id = v_order.id
  RETURNING * INTO v_order;

  IF p_latitude IS NOT NULL AND p_longitude IS NOT NULL THEN
    INSERT INTO public.location_logs (driver_id, shift_id, latitude, longitude, accuracy)
    VALUES (v_driver, p_shift_id, p_latitude, p_longitude, p_accuracy);
  END IF;

  RETURN v_order;
END;
$$;

REVOKE ALL ON FUNCTION public.create_order(UUID, JSONB, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, UUID, TIMESTAMPTZ, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_order(UUID, JSONB, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, UUID, TIMESTAMPTZ, TEXT, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- Sebaran pembeli — satu query, bentuk dimensi/kelompok
--
-- Pesanan tanpa profil dikelompokkan sebagai 'unknown' agar terlihat
-- berapa banyak transaksi yang belum dicatat profilnya. Tanpa itu,
-- persentasenya akan menyesatkan.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_customer_insights(p_days INTEGER DEFAULT 30)
RETURNS TABLE (
  dimension TEXT,
  bucket    TEXT,
  orders    INTEGER,
  revenue   BIGINT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH scoped AS (
    SELECT * FROM public.orders o
     WHERE o.created_at >= NOW() - make_interval(days => GREATEST(p_days, 1))
       AND public.get_user_role(auth.uid()) = 'admin'
  )
  SELECT 'gender', COALESCE(customer_gender, 'unknown'),
         count(*)::INTEGER, COALESCE(sum(total_amount), 0)::BIGINT
    FROM scoped GROUP BY 2
  UNION ALL
  SELECT 'age', COALESCE(customer_age_range, 'unknown'),
         count(*)::INTEGER, COALESCE(sum(total_amount), 0)::BIGINT
    FROM scoped GROUP BY 2
  UNION ALL
  SELECT 'type', COALESCE(customer_type, 'unknown'),
         count(*)::INTEGER, COALESCE(sum(total_amount), 0)::BIGINT
    FROM scoped GROUP BY 2;
$$;

REVOKE ALL ON FUNCTION public.admin_customer_insights(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_customer_insights(INTEGER) TO authenticated;

-- ------------------------------------------------------------
-- Jam ramai per kelompok usia
--
-- Menjawab "remaja ramai jam berapa" — dasar untuk menentukan gerobak
-- mangkal di mana dan jam berapa. Waktu sudah tercatat otomatis pada
-- setiap pesanan, jadi tidak perlu input tambahan dari driver.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_customer_hourly(p_days INTEGER DEFAULT 30)
RETURNS TABLE (
  hour      INTEGER,
  age_range TEXT,
  orders    INTEGER,
  revenue   BIGINT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXTRACT(HOUR FROM (o.created_at AT TIME ZONE 'Asia/Jakarta'))::INTEGER,
         COALESCE(o.customer_age_range, 'unknown'),
         count(*)::INTEGER,
         COALESCE(sum(o.total_amount), 0)::BIGINT
    FROM public.orders o
   WHERE o.created_at >= NOW() - make_interval(days => GREATEST(p_days, 1))
     AND public.get_user_role(auth.uid()) = 'admin'
   GROUP BY 1, 2
   ORDER BY 1, 2;
$$;

REVOKE ALL ON FUNCTION public.admin_customer_hourly(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_customer_hourly(INTEGER) TO authenticated;

-- ------------------------------------------------------------
-- Produk favorit per kelompok pembeli
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_products_by_segment(p_days INTEGER DEFAULT 30)
RETURNS TABLE (
  dimension    TEXT,
  bucket       TEXT,
  product_name TEXT,
  total_qty    INTEGER,
  revenue      BIGINT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH scoped AS (
    SELECT o.id, o.customer_gender, o.customer_age_range
      FROM public.orders o
     WHERE o.created_at >= NOW() - make_interval(days => GREATEST(p_days, 1))
       AND public.get_user_role(auth.uid()) = 'admin'
  ),
  lines AS (
    SELECT s.customer_gender, s.customer_age_range,
           COALESCE(pr.name, 'Item') AS product_name,
           oi.quantity, oi.subtotal
      FROM scoped s
      JOIN public.order_items oi ON oi.order_id = s.id
      LEFT JOIN public.products pr ON pr.id = oi.product_id
  )
  SELECT 'gender', COALESCE(customer_gender, 'unknown'), product_name,
         sum(quantity)::INTEGER, sum(subtotal)::BIGINT
    FROM lines GROUP BY 2, 3
  UNION ALL
  SELECT 'age', COALESCE(customer_age_range, 'unknown'), product_name,
         sum(quantity)::INTEGER, sum(subtotal)::BIGINT
    FROM lines GROUP BY 2, 3;
$$;

REVOKE ALL ON FUNCTION public.admin_products_by_segment(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_products_by_segment(INTEGER) TO authenticated;
