-- ============================================================
-- 0003 — Pesanan tahan sinyal putus & penguncian audit kas
--
-- Jalankan di Supabase SQL Editor SETELAH 0002, sebelum men-deploy versi
-- aplikasi yang menyertainya. Aman dijalankan berulang.
--
-- Dua risiko operasional pada 100 gerobak:
--
-- 1. Driver berjualan keliling dengan sinyal yang putus-nyambung. Bila
--    permintaan pesanan gagal di tengah jalan, driver tidak tahu apakah
--    pesanan sudah tersimpan. Mencoba lagi berisiko membuat pesanan ganda
--    dan memotong stok dua kali. Diselesaikan dengan kunci idempotensi
--    dari sisi klien.
--
-- 2. Rekonsiliasi kas malam bisa dikunci, tetapi tidak ada yang benar-benar
--    mencegah angkanya diubah setelah itu. Untuk 100 gerobak yang menyetor
--    tunai setiap hari, itu berarti tidak ada catatan yang final.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Kunci idempotensi pesanan
--
-- Klien membuat satu UUID per percobaan pesanan dan mengirim ulang UUID
-- yang sama saat mencoba kembali. Pesanan yang sudah tersimpan akan
-- dikembalikan apa adanya, bukan dibuat ulang.
-- ------------------------------------------------------------
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS client_order_id UUID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_client_order_id
  ON public.orders (client_order_id)
  WHERE client_order_id IS NOT NULL;

-- Tanda tangan create_order berubah, jadi versi lama dilepas lebih dulu
-- agar tidak tersisa dua fungsi bernama sama dengan jumlah argumen berbeda.
DROP FUNCTION IF EXISTS public.create_order(
  UUID, JSONB, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT
);

CREATE OR REPLACE FUNCTION public.create_order(
  p_shift_id       UUID,
  p_items          JSONB,
  p_payment_method TEXT DEFAULT 'cash',
  p_latitude       DOUBLE PRECISION DEFAULT NULL,
  p_longitude      DOUBLE PRECISION DEFAULT NULL,
  p_accuracy       DOUBLE PRECISION DEFAULT NULL,
  p_customer_notes TEXT DEFAULT NULL,
  p_client_order_id UUID DEFAULT NULL,
  p_created_at     TIMESTAMPTZ DEFAULT NULL
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

  -- Percobaan ulang dari antrean offline: kembalikan pesanan yang sudah ada.
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

  PERFORM 1 FROM public.shifts
   WHERE id = p_shift_id
     AND driver_id = v_driver
     AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHIFT_NOT_ACTIVE' USING ERRCODE = '22023';
  END IF;

  -- Waktu transaksi asli dipakai untuk pesanan yang tertahan di antrean,
  -- supaya laporan harian tidak menggeser penjualan ke jam sinkronisasi.
  -- Dibatasi agar tidak bisa dipakai menyisipkan penjualan ke masa lalu
  -- yang jauh atau ke masa depan.
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
    client_order_id, created_at
  )
  VALUES (
    p_shift_id, v_driver, v_order_number,
    p_latitude, p_longitude, 0, p_payment_method, p_customer_notes,
    p_client_order_id, v_created_at
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
       WHERE allocation_id = v_alloc_id
         AND product_id = v_product_id
       FOR UPDATE;

      IF FOUND THEN
        IF v_remaining < v_qty THEN
          RAISE EXCEPTION 'INSUFFICIENT_STOCK:%', v_product_name USING ERRCODE = '22023';
        END IF;

        UPDATE public.driver_allocation_items
           SET sold_quantity = sold_quantity + v_qty
         WHERE allocation_id = v_alloc_id
           AND product_id = v_product_id;
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

REVOKE ALL ON FUNCTION public.create_order(UUID, JSONB, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_order(UUID, JSONB, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, UUID, TIMESTAMPTZ) TO authenticated;

-- ------------------------------------------------------------
-- 2. Jejak audit penguncian kas
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.allocation_audit_log (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  allocation_id UUID REFERENCES public.driver_daily_allocations(id) ON DELETE CASCADE NOT NULL,
  action        TEXT NOT NULL CHECK (action IN ('reconciled', 'unlocked')),
  actor_id      UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  cash_settled  INTEGER,
  cash_expected INTEGER,
  note          TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_allocation_audit_allocation
  ON public.allocation_audit_log (allocation_id, created_at DESC);

ALTER TABLE public.allocation_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin can read allocation audit" ON public.allocation_audit_log;
CREATE POLICY "Admin can read allocation audit" ON public.allocation_audit_log
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'admin');

-- ------------------------------------------------------------
-- 3. Rekonsiliasi yang sudah dikunci bersifat final
--
-- Sebelumnya status 'reconciled' hanya label: seluruh angka kas dan stok
-- masih bisa diubah setelahnya tanpa jejak. Sekarang perubahan ditolak,
-- kecuali admin membuka kunci secara eksplisit — dan pembukaan itu tercatat.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_reconciled_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.status <> 'reconciled' THEN
    RETURN NEW;
  END IF;

  -- Satu-satunya perubahan yang diizinkan atas alokasi terkunci adalah
  -- membukanya kembali, dan hanya admin yang boleh.
  IF NEW.status = 'active' THEN
    IF auth.uid() IS NOT NULL
       AND public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
      RAISE EXCEPTION 'RECONCILIATION_UNLOCK_FORBIDDEN' USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.allocation_audit_log (allocation_id, action, actor_id, cash_settled, cash_expected)
    VALUES (OLD.id, 'unlocked', auth.uid(), OLD.cash_settled, OLD.total_cash_collected);

    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'RECONCILIATION_LOCKED' USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS allocations_reconciled_guard ON public.driver_daily_allocations;
CREATE TRIGGER allocations_reconciled_guard
  BEFORE UPDATE ON public.driver_daily_allocations
  FOR EACH ROW EXECUTE FUNCTION public.guard_reconciled_allocation();

-- Baris muatan juga ikut terkunci; kalau tidak, angka stok masih bisa
-- diubah setelah selisihnya disepakati.
CREATE OR REPLACE FUNCTION public.guard_reconciled_allocation_items()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status TEXT;
BEGIN
  SELECT status INTO v_status
    FROM public.driver_daily_allocations
   WHERE id = COALESCE(NEW.allocation_id, OLD.allocation_id);

  IF v_status = 'reconciled' THEN
    RAISE EXCEPTION 'RECONCILIATION_LOCKED' USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS allocation_items_reconciled_guard ON public.driver_allocation_items;
CREATE TRIGGER allocation_items_reconciled_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.driver_allocation_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_reconciled_allocation_items();

-- Mencatat penguncian, dipanggil aplikasi admin saat mengunci audit malam.
CREATE OR REPLACE FUNCTION public.lock_reconciliation(
  p_allocation_id UUID,
  p_note          TEXT DEFAULT NULL
)
RETURNS public.driver_daily_allocations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_alloc public.driver_daily_allocations;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  UPDATE public.driver_daily_allocations
     SET status        = 'reconciled',
         reconciled_at = NOW(),
         reconciled_by = auth.uid(),
         notes         = COALESCE(p_note, notes)
   WHERE id = p_allocation_id
     AND status <> 'reconciled'
  RETURNING * INTO v_alloc;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ALLOCATION_NOT_FOUND_OR_ALREADY_LOCKED' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.allocation_audit_log (allocation_id, action, actor_id, cash_settled, cash_expected, note)
  VALUES (v_alloc.id, 'reconciled', auth.uid(), v_alloc.cash_settled, v_alloc.total_cash_collected, p_note);

  RETURN v_alloc;
END;
$$;

REVOKE ALL ON FUNCTION public.lock_reconciliation(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lock_reconciliation(UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 4. Ringkasan dashboard admin dalam satu query
--
-- Dashboard menarik seluruh pesanan hari ini lalu menjumlahkannya di
-- browser. Pada 100 gerobak itu ribuan baris setiap kali halaman dibuka
-- dan setiap kali Realtime memicu pembaruan.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_daily_summary()
RETURNS TABLE (
  orders_today        INTEGER,
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
  a AS (
    SELECT * FROM public.driver_daily_allocations, today
     WHERE driver_daily_allocations.date = today.d
  )
  SELECT (SELECT count(*) FROM o)::INTEGER,
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
