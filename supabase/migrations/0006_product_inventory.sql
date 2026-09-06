-- ============================================================
-- 0006 — Inventori stok cup jadi per produk
--
-- Jalankan di Supabase SQL Editor SETELAH 0005, sebelum men-deploy versi
-- aplikasi yang menyertainya. Aman dijalankan berulang.
--
-- Tiap menu diproduksi sebagai cup tersegel siap jual. Migrasi ini melacak
-- stok cup itu di pusat/base:
--   - stok masuk (produksi/restock) menaikkan stok,
--   - muat gerobak harian otomatis mengurangi stok,
--   - stock opname menyetel angka ke hasil hitung fisik,
--   - setiap perubahan tercatat di jejak pergerakan.
--
-- Catatan cakupan: cup yang tidak terjual dan kembali ke base pada
-- rekonsiliasi malam TIDAK otomatis ditambahkan kembali ke stok pusat di
-- versi ini; kembalikan lewat "Tambah Stok" bila memang diseal ulang.
-- ============================================================

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS stock_quantity INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS low_stock_threshold INTEGER NOT NULL DEFAULT 0;

DO $$
BEGIN
  ALTER TABLE public.products ADD CONSTRAINT products_stock_nonneg CHECK (stock_quantity >= 0);
EXCEPTION WHEN duplicate_object THEN NULL;
END;
$$;

DO $$
BEGIN
  ALTER TABLE public.products ADD CONSTRAINT products_threshold_nonneg CHECK (low_stock_threshold >= 0);
EXCEPTION WHEN duplicate_object THEN NULL;
END;
$$;

-- ------------------------------------------------------------
-- Jejak pergerakan stok — setiap perubahan stok tercatat di sini
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.stock_movements (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  product_id    UUID REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
  delta         INTEGER NOT NULL,           -- bertanda: + masuk, - keluar
  balance_after INTEGER NOT NULL,
  reason        TEXT NOT NULL CHECK (reason IN
                  ('restock', 'opname', 'allocation', 'allocation_return', 'adjustment')),
  note          TEXT,
  reference_id  UUID,                        -- mis. id alokasi harian
  actor_id      UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stock_movements_product
  ON public.stock_movements (product_id, created_at DESC);

ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin can read stock movements" ON public.stock_movements;
CREATE POLICY "Admin can read stock movements" ON public.stock_movements
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'admin');
-- Tidak ada policy INSERT/UPDATE: penulisan hanya lewat RPC SECURITY DEFINER.

-- ------------------------------------------------------------
-- Ubah stok relatif (delta). Dipakai untuk restock (+) dan koreksi.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.adjust_product_stock(
  p_product_id UUID,
  p_delta      INTEGER,
  p_reason     TEXT DEFAULT 'restock',
  p_note       TEXT DEFAULT NULL
)
RETURNS public.products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_product public.products;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  IF p_reason NOT IN ('restock', 'adjustment') THEN
    RAISE EXCEPTION 'INVALID_REASON' USING ERRCODE = '22023';
  END IF;

  -- Kunci baris produk agar dua restock/muat serentak tidak bertabrakan.
  SELECT * INTO v_product FROM public.products WHERE id = p_product_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = '22023';
  END IF;

  IF v_product.stock_quantity + p_delta < 0 THEN
    RAISE EXCEPTION 'INSUFFICIENT_STOCK:%', v_product.name USING ERRCODE = '22023';
  END IF;

  UPDATE public.products
     SET stock_quantity = stock_quantity + p_delta
   WHERE id = p_product_id
  RETURNING * INTO v_product;

  INSERT INTO public.stock_movements (product_id, delta, balance_after, reason, note, actor_id)
  VALUES (p_product_id, p_delta, v_product.stock_quantity, p_reason, p_note, auth.uid());

  RETURN v_product;
END;
$$;

REVOKE ALL ON FUNCTION public.adjust_product_stock(UUID, INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.adjust_product_stock(UUID, INTEGER, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- Stock opname: setel stok ke hasil hitung fisik (absolut).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_product_stock(
  p_product_id UUID,
  p_new_qty    INTEGER,
  p_note       TEXT DEFAULT NULL
)
RETURNS public.products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_product public.products;
  v_delta   INTEGER;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  IF p_new_qty < 0 THEN
    RAISE EXCEPTION 'INVALID_QUANTITY' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_product FROM public.products WHERE id = p_product_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = '22023';
  END IF;

  v_delta := p_new_qty - v_product.stock_quantity;

  UPDATE public.products SET stock_quantity = p_new_qty WHERE id = p_product_id
  RETURNING * INTO v_product;

  -- Selalu catat, walau delta 0, agar audit opname tetap ada jejaknya.
  INSERT INTO public.stock_movements (product_id, delta, balance_after, reason, note, actor_id)
  VALUES (p_product_id, v_delta, v_product.stock_quantity, 'opname', p_note, auth.uid());

  RETURN v_product;
END;
$$;

REVOKE ALL ON FUNCTION public.set_product_stock(UUID, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_product_stock(UUID, INTEGER, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- Muat gerobak pagi — transaksional, sekaligus mengurangi stok pusat.
--
-- Menggantikan upsert dari klien. Menghitung selisih per produk terhadap
-- alokasi yang sudah ada, lalu:
--   - selisih positif  → kurangi stok pusat (movement 'allocation'),
--   - selisih negatif  → kembalikan ke stok  (movement 'allocation_return').
-- Idempoten: menyimpan angka yang sama dua kali tidak menggeser stok.
-- Menolak bila stok pusat tidak cukup, atau bila alokasi sudah dikunci.
--
-- p_items: [{product_id, initial_quantity, physical_remaining, waste_quantity}]
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_morning_allocation(
  p_driver_id UUID,
  p_date      DATE,
  p_items     JSONB
)
RETURNS public.driver_daily_allocations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_alloc   public.driver_daily_allocations;
  v_item    JSONB;
  v_pid     UUID;
  v_new     INTEGER;
  v_old     INTEGER;
  v_delta   INTEGER;
  v_prod    public.products;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  -- Header alokasi: ambil yang ada atau buat baru.
  SELECT * INTO v_alloc
    FROM public.driver_daily_allocations
   WHERE driver_id = p_driver_id AND date = p_date
   FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.driver_daily_allocations (driver_id, date, status)
    VALUES (p_driver_id, p_date, 'allocated')
    RETURNING * INTO v_alloc;
  ELSIF v_alloc.status = 'reconciled' THEN
    RAISE EXCEPTION 'RECONCILIATION_LOCKED' USING ERRCODE = '42501';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_pid := (v_item->>'product_id')::UUID;
    v_new := GREATEST(COALESCE((v_item->>'initial_quantity')::INTEGER, 0), 0);

    SELECT COALESCE(initial_quantity, 0) INTO v_old
      FROM public.driver_allocation_items
     WHERE allocation_id = v_alloc.id AND product_id = v_pid;
    v_old := COALESCE(v_old, 0);

    v_delta := v_new - v_old;

    IF v_delta <> 0 THEN
      SELECT * INTO v_prod FROM public.products WHERE id = v_pid FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = '22023';
      END IF;

      IF v_delta > 0 AND v_prod.stock_quantity < v_delta THEN
        RAISE EXCEPTION 'INSUFFICIENT_STOCK:%', v_prod.name USING ERRCODE = '22023';
      END IF;

      UPDATE public.products
         SET stock_quantity = stock_quantity - v_delta
       WHERE id = v_pid
      RETURNING * INTO v_prod;

      INSERT INTO public.stock_movements (product_id, delta, balance_after, reason, note, reference_id, actor_id)
      VALUES (v_pid, -v_delta, v_prod.stock_quantity,
              CASE WHEN v_delta > 0 THEN 'allocation' ELSE 'allocation_return' END,
              'Muat gerobak ' || p_date, v_alloc.id, auth.uid());
    END IF;

    INSERT INTO public.driver_allocation_items
      (allocation_id, product_id, initial_quantity, physical_remaining, waste_quantity)
    VALUES (
      v_alloc.id, v_pid, v_new,
      COALESCE((v_item->>'physical_remaining')::INTEGER, NULL),
      COALESCE((v_item->>'waste_quantity')::INTEGER, 0)
    )
    ON CONFLICT (allocation_id, product_id) DO UPDATE
      SET initial_quantity   = EXCLUDED.initial_quantity,
          physical_remaining = EXCLUDED.physical_remaining,
          waste_quantity     = EXCLUDED.waste_quantity;
  END LOOP;

  RETURN v_alloc;
END;
$$;

REVOKE ALL ON FUNCTION public.save_morning_allocation(UUID, DATE, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_morning_allocation(UUID, DATE, JSONB) TO authenticated;

-- ------------------------------------------------------------
-- Ikhtisar stok untuk halaman inventori admin — satu query
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_stock_overview()
RETURNS TABLE (
  product_id          UUID,
  name                TEXT,
  category            TEXT,
  price               INTEGER,
  is_available        BOOLEAN,
  stock_quantity      INTEGER,
  low_stock_threshold INTEGER,
  allocated_today     INTEGER,
  status              TEXT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH today AS (SELECT (NOW() AT TIME ZONE 'Asia/Jakarta')::date AS d),
  alloc_today AS (
    SELECT i.product_id, COALESCE(sum(i.initial_quantity), 0)::INTEGER AS n
      FROM public.driver_allocation_items i
      JOIN public.driver_daily_allocations a ON a.id = i.allocation_id, today
     WHERE a.date = today.d
     GROUP BY i.product_id
  )
  SELECT p.id, p.name, p.category, p.price, p.is_available,
         p.stock_quantity, p.low_stock_threshold,
         COALESCE(at.n, 0),
         CASE
           WHEN p.stock_quantity <= 0 THEN 'out'
           WHEN p.low_stock_threshold > 0 AND p.stock_quantity <= p.low_stock_threshold THEN 'low'
           ELSE 'ok'
         END
    FROM public.products p
    LEFT JOIN alloc_today at ON at.product_id = p.id
   WHERE public.get_user_role(auth.uid()) = 'admin'
   ORDER BY p.sort_order, p.name;
$$;

REVOKE ALL ON FUNCTION public.admin_stock_overview() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_stock_overview() TO authenticated;

-- ------------------------------------------------------------
-- Jumlah produk berstok menipis/habis — untuk lencana dashboard
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_low_stock_count()
RETURNS TABLE (out_of_stock INTEGER, low_stock INTEGER)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT
    count(*) FILTER (WHERE stock_quantity <= 0)::INTEGER,
    count(*) FILTER (WHERE stock_quantity > 0
                       AND low_stock_threshold > 0
                       AND stock_quantity <= low_stock_threshold)::INTEGER
    FROM public.products
   WHERE is_available = true
   HAVING public.get_user_role(auth.uid()) = 'admin';
$$;

REVOKE ALL ON FUNCTION public.admin_low_stock_count() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_low_stock_count() TO authenticated;
