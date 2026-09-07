-- ============================================================
-- 0012 — Pesanan antrean yang kedaluwarsa ditolak, bukan digeser tanggalnya
--
-- Jalankan di Supabase SQL Editor SETELAH 0011. Aman dijalankan berulang.
--
-- Masalah: create_order menerima p_created_at dari antrean offline supaya
-- waktu transaksi yang sebenarnya dipertahankan. Untuk menghadang penyisipan
-- tanggal palsu, waktu di luar rentang wajar dikoreksi ke NOW(). Koreksi itu
-- benar untuk waktu di MASA DEPAN, tetapi salah untuk waktu yang terlalu
-- tua: pesanan yang menunggu sinyal berhari-hari tersimpan dengan tanggal
-- hari pengiriman, bukan tanggal penjualannya.
--
-- Akibatnya omzet berpindah hari tanpa memberi tahu siapa pun, dan setelah
-- tersimpan tidak ada cara membedakannya dari penjualan hari itu. Dua angka
-- yang dipercaya untuk menutup kas — laporan harian dan rekonsiliasi
-- gerobak — jadi tidak bisa dipertanggungjawabkan.
--
-- Sekarang ditolak dengan ORDER_TOO_OLD. Aplikasi driver memperlakukannya
-- sebagai penolakan permanen, sehingga pesanan itu keluar dari antrean dan
-- masuk ke daftar "tidak tercatat" yang memang sudah ditampilkan kepada
-- driver — masih terlihat, masih bisa ditindaklanjuti, dan tidak merusak
-- angka hari mana pun.
--
-- Batas dua harinya tidak berubah; yang berubah hanya apa yang terjadi saat
-- batas itu terlampaui.
-- ============================================================

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

  -- Akun yang dinonaktifkan admin tidak boleh mencatat penjualan, walau
  -- shift-nya sudah dibuka sebelum penonaktifan. Diperiksa lebih dulu dari
  -- apa pun yang lain supaya tidak ada baris yang tertulis.
  IF public.get_user_status(v_driver) <> 'active' THEN
    RAISE EXCEPTION 'ACCOUNT_INACTIVE' USING ERRCODE = '28000';
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

  -- Waktu di masa depan dikoreksi diam-diam: itu upaya menaruh penjualan
  -- pada tanggal yang belum terjadi, dan tidak ada alasan sah untuk itu.
  IF v_created_at > NOW() + INTERVAL '2 minutes' THEN
    v_created_at := NOW();
  END IF;

  -- Waktu yang terlalu tua DITOLAK, bukan digeser ke sekarang.
  --
  -- Pesanan yang menunggu sinyal berhari-hari dulu tersimpan dengan tanggal
  -- hari pengiriman, bukan tanggal penjualannya — omzet berpindah hari
  -- tanpa memberi tahu siapa pun, dan tidak ada cara mengetahuinya setelah
  -- tersimpan. Ditolak dengan sebab yang jelas, penjualan itu muncul di
  -- daftar "tidak tercatat" milik driver dan masih bisa ditindaklanjuti.
  IF v_created_at < NOW() - INTERVAL '2 days' THEN
    RAISE EXCEPTION 'ORDER_TOO_OLD' USING ERRCODE = '22023';
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

NOTIFY pgrst, 'reload schema';
