-- ============================================================
-- 0025 — Driver bisa memperbaiki pesanan yang salah ketik
-- ============================================================
--
-- Sampai sekarang pesanan yang sudah tersimpan tidak bisa diubah sama
-- sekali. Di lapangan itu berarti salah ketik menetap selamanya, dan
-- angka yang dipakai mengambil keputusan ikut salah.
--
-- Minggu 13 Sep 2026 menunjukkan kenapa ini mendesak: 33 cup dicatat
-- dalam rentang satu menit (14:09-14:10) saat event kampus. Mengetik
-- cepat sambil melayani antrean adalah keadaan di mana salah ketik bukan
-- kemungkinan, melainkan kepastian.
--
-- ------------------------------------------------------------
-- Kenapa perubahannya dicatat, bukan diam-diam
-- ------------------------------------------------------------
-- Seluruh repositori ini dibangun di atas satu gagasan: angka penjualan
-- tidak boleh bisa berbohong. Migrasi 0014 menolak angka audit yang
-- mustahil, 0003 mengunci kas setelah direkonsiliasi.
--
-- Membiarkan pesanan diubah tanpa jejak akan melubangi semua itu. Selisih
-- kas apa pun bisa dirapikan belakangan dengan menurunkan satu angka
-- penjualan, dan tidak ada yang bisa membedakannya dari koreksi jujur.
--
-- Karena itu setiap edit dan pembatalan menyimpan potret sebelum dan
-- sesudahnya. Yang dibuka adalah kemampuan memperbaiki, bukan kemampuan
-- menghapus jejak.
--
-- ------------------------------------------------------------
-- Batasnya
-- ------------------------------------------------------------
--   1. Hanya pesanan milik driver itu sendiri (admin boleh semuanya).
--   2. Hanya pesanan HARI INI menurut WIB. Memperbaiki hari kemarin
--      berarti menggeser angka yang mungkin sudah dipakai menghitung,
--      dan itu pintu belakang ke audit kas.
--   3. Ditolak bila hari itu sudah direkonsiliasi — aturan yang sama
--      dengan create_order.
--   4. Stok alokasi ikut dikembalikan dan dipotong ulang, jadi
--      "terjual + sisa" tetap menjumlah ke "dibawa".
--
-- Idempoten.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Jejak perubahan
-- ------------------------------------------------------------
-- Sengaja TANPA foreign key ke orders: baris pembatalan harus tetap ada
-- setelah pesanannya dihapus. Justru itu baris yang paling perlu dibaca.
CREATE TABLE IF NOT EXISTS public.order_audit_log (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id     UUID,
  order_number TEXT        NOT NULL,
  driver_id    UUID        NOT NULL,
  actor_id     UUID,
  action       TEXT        NOT NULL,
  sebelum      JSONB       NOT NULL,
  sesudah      JSONB,
  alasan       TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

DO $c$
BEGIN
  ALTER TABLE public.order_audit_log DROP CONSTRAINT IF EXISTS order_audit_log_action_check;
  ALTER TABLE public.order_audit_log
    ADD CONSTRAINT order_audit_log_action_check
    CHECK (action IN ('edit', 'batal'));
END;
$c$;

CREATE INDEX IF NOT EXISTS idx_order_audit_driver_waktu
  ON public.order_audit_log (driver_id, created_at DESC);

ALTER TABLE public.order_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin membaca seluruh jejak pesanan" ON public.order_audit_log;
CREATE POLICY "Admin membaca seluruh jejak pesanan"
  ON public.order_audit_log FOR SELECT
  USING (public.get_user_role(auth.uid()) = 'admin');

DROP POLICY IF EXISTS "Driver membaca jejaknya sendiri" ON public.order_audit_log;
CREATE POLICY "Driver membaca jejaknya sendiri"
  ON public.order_audit_log FOR SELECT
  USING (driver_id = auth.uid());

-- Tidak ada policy INSERT/UPDATE/DELETE. Jejak hanya ditulis oleh fungsi
-- SECURITY DEFINER di bawah, dan tidak bisa dihapus dari aplikasi.

-- ------------------------------------------------------------
-- 2. Potret satu pesanan
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.potret_pesanan(p_order_id UUID)
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT jsonb_build_object(
    'total', (SELECT total_amount FROM public.orders WHERE id = p_order_id),
    'item', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'product_id', oi.product_id,
               'nama',       pr.name,
               'jumlah',     oi.quantity,
               'harga',      oi.unit_price
             ) ORDER BY pr.name)
        FROM public.order_items oi
        LEFT JOIN public.products pr ON pr.id = oi.product_id
       WHERE oi.order_id = p_order_id
    ), '[]'::jsonb)
  );
$fn$;

-- ------------------------------------------------------------
-- 3. Pemeriksaan yang sama untuk edit maupun batal
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.boleh_ubah_pesanan(p_order_id UUID)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_order  public.orders;
  v_actor  UUID := auth.uid();
  v_status TEXT;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE = '22023';
  END IF;

  IF v_order.driver_id <> v_actor
     AND public.get_user_role(v_actor) <> 'admin' THEN
    RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE = '22023';
  END IF;

  -- Hanya hari ini. Memperbaiki hari kemarin berarti menggeser angka yang
  -- mungkin sudah dipakai menghitung, dan itu pintu belakang ke audit kas.
  IF (v_order.created_at AT TIME ZONE 'Asia/Jakarta')::date
     <> (NOW() AT TIME ZONE 'Asia/Jakarta')::date THEN
    RAISE EXCEPTION 'ORDER_NOT_TODAY' USING ERRCODE = '22023';
  END IF;

  SELECT status INTO v_status
    FROM public.driver_daily_allocations
   WHERE driver_id = v_order.driver_id
     AND date = (v_order.created_at AT TIME ZONE 'Asia/Jakarta')::date;

  IF v_status = 'reconciled' THEN
    RAISE EXCEPTION 'DAY_RECONCILED' USING ERRCODE = '22023';
  END IF;

  RETURN v_order;
END;
$fn$;

-- ------------------------------------------------------------
-- 4. Kembalikan stok alokasi dari item pesanan yang sedang berlaku
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.kembalikan_stok_pesanan(p_order_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_order    public.orders;
  v_alloc_id UUID;
  v_item     RECORD;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;

  SELECT id INTO v_alloc_id
    FROM public.driver_daily_allocations
   WHERE driver_id = v_order.driver_id
     AND date = (v_order.created_at AT TIME ZONE 'Asia/Jakarta')::date;

  IF v_alloc_id IS NULL THEN
    RETURN;  -- pesanan tanpa alokasi; tidak ada yang perlu dikembalikan
  END IF;

  -- Diurutkan menurut product_id agar dua perubahan bersamaan mengunci
  -- baris dalam urutan yang sama dan tidak saling menunggu.
  FOR v_item IN
    SELECT product_id, sum(quantity) AS jumlah
      FROM public.order_items
     WHERE order_id = p_order_id
     GROUP BY product_id
     ORDER BY product_id
  LOOP
    UPDATE public.driver_allocation_items
       SET sold_quantity = GREATEST(sold_quantity - v_item.jumlah, 0)
     WHERE allocation_id = v_alloc_id AND product_id = v_item.product_id;
  END LOOP;
END;
$fn$;

-- ------------------------------------------------------------
-- 5. Edit pesanan
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.driver_edit_order(
  p_order_id UUID,
  p_items    JSONB
)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_order     public.orders;
  v_sebelum   JSONB;
  v_alloc_id  UUID;
  v_item      JSONB;
  v_product   UUID;
  v_qty       INTEGER;
  v_price     INTEGER;
  v_nama      TEXT;
  v_total     INTEGER := 0;
  v_sisa      INTEGER;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    -- Mengosongkan pesanan bukan edit, itu pembatalan — dan pembatalan
    -- punya jejaknya sendiri yang menyimpan alasannya.
    RAISE EXCEPTION 'ITEMS_EMPTY' USING ERRCODE = '22023';
  END IF;

  v_order   := public.boleh_ubah_pesanan(p_order_id);
  v_sebelum := public.potret_pesanan(p_order_id);

  SELECT id INTO v_alloc_id
    FROM public.driver_daily_allocations
   WHERE driver_id = v_order.driver_id
     AND date = (v_order.created_at AT TIME ZONE 'Asia/Jakarta')::date;

  -- Kembalikan dulu seluruh stok pesanan lama, baru potong ulang dengan
  -- item yang baru. Cara ini menangani perubahan menu, bukan hanya
  -- perubahan jumlah, dan memakai pemeriksaan stok yang sama persis
  -- dengan create_order.
  PERFORM public.kembalikan_stok_pesanan(p_order_id);
  DELETE FROM public.order_items WHERE order_id = p_order_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product := (v_item->>'product_id')::UUID;
    v_qty     := (v_item->>'quantity')::INTEGER;

    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'INVALID_QUANTITY' USING ERRCODE = '22023';
    END IF;

    SELECT price, name INTO v_price, v_nama
      FROM public.products
     WHERE id = v_product AND is_available = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'PRODUCT_UNAVAILABLE' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
    VALUES (p_order_id, v_product, v_qty, v_price, v_price * v_qty);

    v_total := v_total + (v_price * v_qty);

    IF v_alloc_id IS NOT NULL THEN
      SELECT initial_quantity - sold_quantity INTO v_sisa
        FROM public.driver_allocation_items
       WHERE allocation_id = v_alloc_id AND product_id = v_product
       FOR UPDATE;

      IF FOUND THEN
        IF v_sisa < v_qty THEN
          RAISE EXCEPTION 'INSUFFICIENT_STOCK:%', v_nama USING ERRCODE = '22023';
        END IF;

        UPDATE public.driver_allocation_items
           SET sold_quantity = sold_quantity + v_qty
         WHERE allocation_id = v_alloc_id AND product_id = v_product;
      END IF;
    END IF;
  END LOOP;

  UPDATE public.orders
     SET total_amount = v_total
   WHERE id = p_order_id
  RETURNING * INTO v_order;

  INSERT INTO public.order_audit_log
    (order_id, order_number, driver_id, actor_id, action, sebelum, sesudah)
  VALUES
    (p_order_id, v_order.order_number, v_order.driver_id, auth.uid(), 'edit',
     v_sebelum, public.potret_pesanan(p_order_id));

  RETURN v_order;
END;
$fn$;

-- ------------------------------------------------------------
-- 6. Batalkan pesanan
-- ------------------------------------------------------------
-- Pesanannya benar-benar dihapus, bukan ditandai. Menandai berarti setiap
-- fungsi analitik — dan jumlahnya lebih dari dua puluh — harus ingat
-- menyaringnya; satu yang lupa menghasilkan angka yang berbeda diam-diam
-- dari angka di sebelahnya. Jejaknya disimpan penuh di order_audit_log,
-- jadi yang hilang hanya barisnya, bukan kejadiannya.
CREATE OR REPLACE FUNCTION public.driver_batal_order(
  p_order_id UUID,
  p_alasan   TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_order   public.orders;
  v_sebelum JSONB;
BEGIN
  v_order   := public.boleh_ubah_pesanan(p_order_id);
  v_sebelum := public.potret_pesanan(p_order_id);

  PERFORM public.kembalikan_stok_pesanan(p_order_id);

  INSERT INTO public.order_audit_log
    (order_id, order_number, driver_id, actor_id, action, sebelum, sesudah, alasan)
  VALUES
    (p_order_id, v_order.order_number, v_order.driver_id, auth.uid(), 'batal',
     v_sebelum, NULL, NULLIF(btrim(COALESCE(p_alasan, '')), ''));

  DELETE FROM public.order_items WHERE order_id = p_order_id;
  DELETE FROM public.orders      WHERE id = p_order_id;

  RETURN true;
END;
$fn$;

-- ------------------------------------------------------------
-- 7. Izin
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.potret_pesanan(UUID)            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.boleh_ubah_pesanan(UUID)        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kembalikan_stok_pesanan(UUID)   FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.driver_edit_order(UUID, JSONB)  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.driver_edit_order(UUID, JSONB) TO authenticated;

REVOKE ALL ON FUNCTION public.driver_batal_order(UUID, TEXT)  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.driver_batal_order(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
