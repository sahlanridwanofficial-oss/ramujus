-- ============================================================
-- 0001 — Security hardening & transactional order creation
--
-- Jalankan seluruh file ini di Supabase SQL Editor SEBELUM men-deploy
-- versi aplikasi yang menyertainya. Aplikasi baru memanggil fungsi
-- public.create_order() yang dibuat di sini.
--
-- File ini aman dijalankan berulang (idempotent).
-- ============================================================

-- ------------------------------------------------------------
-- 1. get_user_role: kunci search_path
--
-- Fungsi SECURITY DEFINER tanpa search_path tetap dapat diarahkan ke
-- skema lain oleh pemanggil, sehingga "profiles" bisa merujuk tabel
-- palsu milik penyerang.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_user_role(user_id UUID)
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT role FROM public.profiles WHERE id = user_id;
$$;

-- ------------------------------------------------------------
-- 2. Pendaftaran mandiri tidak boleh menentukan peran sendiri
--
-- Sebelumnya peran diambil dari raw_user_meta_data, yang sepenuhnya
-- dikontrol pendaftar: signUp({ data: { role: 'admin' } }) langsung
-- menghasilkan admin. Peran baru selalu 'driver'; promosi ke admin
-- dilakukan manual lewat SQL atau service role.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, phone, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email),
    NEW.raw_user_meta_data->>'phone',
    'driver'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- ------------------------------------------------------------
-- 3. Driver tidak boleh mengangkat dirinya sendiri jadi admin
--
-- Policy "Users can update own profile" tidak punya WITH CHECK yang
-- membatasi kolom, sehingga driver dapat menjalankan
--   UPDATE profiles SET role = 'admin' WHERE id = auth.uid()
-- RLS tidak bisa membatasi per kolom, jadi dijaga lewat trigger yang
-- membandingkan OLD dan NEW.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_profile_field_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Tanpa JWT (service role / SQL Editor) tidak dibatasi.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF public.get_user_role(auth.uid()) = 'admin' THEN
    RETURN NEW;
  END IF;

  IF NEW.role IS DISTINCT FROM OLD.role THEN
    RAISE EXCEPTION 'FORBIDDEN_ROLE_CHANGE' USING ERRCODE = '42501';
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'FORBIDDEN_STATUS_CHANGE' USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profiles_field_guard ON public.profiles;
CREATE TRIGGER profiles_field_guard
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.enforce_profile_field_guard();

-- ------------------------------------------------------------
-- 4. Driver tidak boleh mengubah angka muatan gerobaknya sendiri
--
-- Policy lama bernama "...sold_qty" tetapi RLS memberi izin seluruh
-- kolom, sehingga driver dapat mengecilkan initial_quantity atau
-- membesarkan waste_quantity untuk menutupi selisih stok.
-- Penjualan sekarang ditulis lewat create_order(), jadi hak UPDATE
-- langsung dicabut sepenuhnya.
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "Drivers can update own allocation items sold_qty"
  ON public.driver_allocation_items;

-- ------------------------------------------------------------
-- 5. Satu driver hanya boleh punya satu shift aktif
-- ------------------------------------------------------------
DO $$
BEGIN
  CREATE UNIQUE INDEX idx_one_active_shift_per_driver
    ON public.shifts (driver_id)
    WHERE status = 'active';
EXCEPTION
  WHEN duplicate_table THEN
    NULL; -- indeks sudah ada
  WHEN unique_violation THEN
    RAISE NOTICE 'Indeks shift aktif dilewati: masih ada driver dengan lebih dari satu shift berstatus active. Rapikan dulu, lalu jalankan ulang file ini.';
END;
$$;

-- ------------------------------------------------------------
-- 6. Pembuatan pesanan yang atomik
--
-- Sebelumnya klien menulis orders, order_items, driver_allocation_items
-- dan location_logs lewat 4+ round trip terpisah tanpa transaksi, dan
-- error pada order_items diabaikan — menghasilkan pesanan bertotal tapi
-- tanpa item. Total juga dihitung di browser lalu dipercaya mentah.
--
-- Fungsi ini menjalankan semuanya dalam satu transaksi, menghitung total
-- dari tabel products (bukan dari klien), dan mengunci baris stok
-- (FOR UPDATE) agar dua pesanan beruntun tidak saling menimpa.
-- ------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS public.order_number_seq;

CREATE OR REPLACE FUNCTION public.create_order(
  p_shift_id       UUID,
  p_items          JSONB,
  p_payment_method TEXT DEFAULT 'cash',
  p_latitude       DOUBLE PRECISION DEFAULT NULL,
  p_longitude      DOUBLE PRECISION DEFAULT NULL,
  p_accuracy       DOUBLE PRECISION DEFAULT NULL,
  p_customer_notes TEXT DEFAULT NULL
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
BEGIN
  IF v_driver IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '28000';
  END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_CART' USING ERRCODE = '22023';
  END IF;

  IF p_payment_method NOT IN ('cash', 'qris', 'transfer') THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD' USING ERRCODE = '22023';
  END IF;

  -- Shift wajib milik pemanggil dan masih aktif.
  PERFORM 1 FROM public.shifts
   WHERE id = p_shift_id
     AND driver_id = v_driver
     AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHIFT_NOT_ACTIVE' USING ERRCODE = '22023';
  END IF;

  -- Alokasi hari ini yang belum dikunci, kalau ada.
  SELECT id INTO v_alloc_id
    FROM public.driver_daily_allocations
   WHERE driver_id = v_driver
     AND date = (now() AT TIME ZONE 'Asia/Jakarta')::date
     AND status <> 'reconciled';

  v_order_number := 'RMJ-'
    || to_char(now() AT TIME ZONE 'Asia/Jakarta', 'YYYYMMDD-HH24MISS')
    || '-' || lpad((nextval('public.order_number_seq') % 100000)::text, 5, '0');

  INSERT INTO public.orders (
    shift_id, driver_id, order_number,
    latitude, longitude, total_amount, payment_method, customer_notes
  )
  VALUES (
    p_shift_id, v_driver, v_order_number,
    p_latitude, p_longitude, 0, p_payment_method, p_customer_notes
  )
  RETURNING * INTO v_order;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::UUID;
    v_qty        := (v_item->>'quantity')::INTEGER;

    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'INVALID_QUANTITY' USING ERRCODE = '22023';
    END IF;

    -- Harga selalu diambil dari database, tidak pernah dari klien.
    SELECT price, name INTO v_price, v_product_name
      FROM public.products
     WHERE id = v_product_id AND is_available = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'PRODUCT_UNAVAILABLE' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
    VALUES (v_order.id, v_product_id, v_qty, v_price, v_price * v_qty);

    v_total := v_total + (v_price * v_qty);

    -- Kurangi kuota gerobak bila produk ini memang dialokasikan hari ini.
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

REVOKE ALL ON FUNCTION public.create_order(UUID, JSONB, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_order(UUID, JSONB, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT) TO authenticated;
