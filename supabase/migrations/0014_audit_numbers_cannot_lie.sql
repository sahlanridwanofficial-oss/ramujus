-- ============================================================
-- 0014 — Angka audit malam tidak bisa lagi berbohong
--
-- Jalankan di Supabase SQL Editor SETELAH 0013. Aman dijalankan berulang.
--
-- Ditemukan dari data sungguhan. Sebuah audit yang sudah dikunci mencatat
-- angka yang mustahil secara fisik:
--
--     dibawa 4, terjual 3, sisa fisik 4
--
-- Tujuh cup dipertanggungjawabkan dari empat yang dibawa. Ada dua sebab, dan
-- keduanya ditutup di sini.
--
-- SEBAB PERTAMA: penjualan berlanjut setelah audit dikunci.
-- create_order mencari alokasi hari itu dengan syarat status <> 'reconciled'.
-- Setelah dikunci, syarat itu tidak terpenuhi, jadi v_alloc_id NULL — dan
-- pesanannya tetap TERSIMPAN, hanya tanpa memotong stok dan tanpa menaikkan
-- sold_quantity. Omzet bertambah, stok pusat tidak berkurang, dan angka
-- audit yang sudah "final" jadi tidak cocok dengan kenyataan. Sekarang
-- ditolak dengan DAY_RECONCILED.
--
-- SEBAB KEDUA: yang dibekukan adalah angka layar, bukan kenyataan.
-- sold_quantity adalah cuplikan; sisa fisik diketik admin pada satu saat.
-- Bila audit disimpan lebih dulu lalu penjualan berlanjut, keduanya bergerak
-- terpisah dan penguncian mengabadikan selisihnya. Sekarang lock_reconciliation
-- menyegarkan sold_quantity dari transaksi yang sebenarnya, lalu MENOLAK
-- angka yang mustahil alih-alih menguncinya.
--
-- Selisih ke arah sebaliknya — ada cup yang hilang — tetap diizinkan. Itu
-- kejadian nyata yang justru perlu tercatat, bukan disembunyikan.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Penjualan ditolak setelah hari itu dikunci
-- ------------------------------------------------------------
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
  v_alloc_status TEXT;
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

  -- Hari yang auditnya sudah dikunci tidak boleh menerima penjualan baru.
  --
  -- Versi lama menyaring alokasi dengan status <> 'reconciled', sehingga
  -- pesanan sesudah penguncian tetap TERSIMPAN — hanya saja tanpa memotong
  -- stok dan tanpa menaikkan sold_quantity. Akibatnya angka audit yang sudah
  -- final berbohong: omzet bertambah, stok pusat tidak berkurang, dan
  -- "terjual + sisa" bisa melebihi "dibawa" pada catatan yang sama.
  -- Sekarang ditolak dengan sebab yang jelas; admin dapat membuka kunci
  -- lebih dulu bila memang masih ada penjualan yang sah.
  SELECT id, status INTO v_alloc_id, v_alloc_status
    FROM public.driver_daily_allocations
   WHERE driver_id = v_driver
     AND date = (v_created_at AT TIME ZONE 'Asia/Jakarta')::date;

  IF v_alloc_status = 'reconciled' THEN
    RAISE EXCEPTION 'DAY_RECONCILED' USING ERRCODE = '22023';
  END IF;

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
-- 2. Penguncian menyegarkan angka terjual, lalu menolak yang mustahil
-- ------------------------------------------------------------
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
  v_alloc            public.driver_daily_allocations;
  v_already_returned BOOLEAN;
  v_item             RECORD;
  v_prod             public.products;
  v_total_returned   INTEGER := 0;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_alloc
    FROM public.driver_daily_allocations
   WHERE id = p_allocation_id
   FOR UPDATE;

  IF NOT FOUND OR v_alloc.status = 'reconciled' THEN
    RAISE EXCEPTION 'ALLOCATION_NOT_FOUND_OR_ALREADY_LOCKED' USING ERRCODE = '22023';
  END IF;

  v_already_returned := v_alloc.stock_returned_at IS NOT NULL;

  -- Angka terjual disegarkan dari transaksi yang sebenarnya sebelum apa pun
  -- dinilai. sold_quantity adalah cuplikan yang dinaikkan create_order, dan
  -- bisa tertinggal dari kenyataan; menguncinya apa adanya berarti
  -- mengabadikan selisih itu selamanya. Yang dibekukan haruslah kebenaran
  -- pada saat penguncian, bukan kebenaran pada saat layar dibuka.
  UPDATE public.driver_allocation_items ai
     SET sold_quantity = COALESCE((
           SELECT sum(oi.quantity)::INTEGER
             FROM public.orders o
             JOIN public.order_items oi ON oi.order_id = o.id
            WHERE o.driver_id = v_alloc.driver_id
              AND oi.product_id = ai.product_id
              AND o.created_at >= public.wib_day_start(v_alloc.date)
              AND o.created_at <  public.wib_day_start(v_alloc.date + 1)
         ), 0)
   WHERE ai.allocation_id = p_allocation_id;

  -- Angka yang mustahil ditolak, bukan dikunci.
  --
  --     terjual + sisa fisik + rusak  tidak boleh melebihi  dibawa
  --
  -- Melebihi berarti ada yang salah catat: mengunci angka seperti itu
  -- membuat laporan stok dan kas ikut salah, dan tidak bisa dikoreksi lagi
  -- tanpa membuka kunci. Selisih ke arah sebaliknya (ada cup yang hilang)
  -- tetap diizinkan — itu kejadian nyata yang memang perlu tercatat.
  FOR v_item IN
    SELECT p.name,
           ai.initial_quantity,
           ai.sold_quantity,
           COALESCE(ai.physical_remaining, 0) AS sisa,
           ai.waste_quantity
      FROM public.driver_allocation_items ai
      JOIN public.products p ON p.id = ai.product_id
     WHERE ai.allocation_id = p_allocation_id
       AND ai.sold_quantity + COALESCE(ai.physical_remaining, 0) + ai.waste_quantity
           > ai.initial_quantity
  LOOP
    RAISE EXCEPTION 'AUDIT_NUMBERS_IMPOSSIBLE:%', v_item.name USING ERRCODE = '22023';
  END LOOP;

  -- Yang dikembalikan tidak boleh melebihi yang benar-benar ada di tangan.
  -- Diperiksa sebelum apa pun ditulis, supaya penolakan tidak meninggalkan
  -- stok yang sudah terlanjur bergerak.
  FOR v_item IN
    SELECT ai.returned_quantity, ai.physical_remaining, p.name
      FROM public.driver_allocation_items ai
      JOIN public.products p ON p.id = ai.product_id
     WHERE ai.allocation_id = p_allocation_id
       AND ai.returned_quantity IS NOT NULL
       AND ai.returned_quantity > COALESCE(ai.physical_remaining, 0)
  LOOP
    RAISE EXCEPTION 'RETURN_EXCEEDS_REMAINING:%', v_item.name USING ERRCODE = '22023';
  END LOOP;

  UPDATE public.driver_daily_allocations
     SET status            = 'reconciled',
         reconciled_at     = NOW(),
         reconciled_by     = auth.uid(),
         notes             = COALESCE(p_note, notes),
         stock_returned_at = COALESCE(stock_returned_at, NOW())
   WHERE id = p_allocation_id
  RETURNING * INTO v_alloc;

  INSERT INTO public.allocation_audit_log (allocation_id, action, actor_id, cash_settled, cash_expected, note)
  VALUES (v_alloc.id, 'reconciled', auth.uid(), v_alloc.cash_settled, v_alloc.total_cash_collected, p_note);

  -- Pengembalian hanya diterapkan sekali. Bila alokasi ini pernah dikunci
  -- lalu dibuka, pembukaannya sudah membalik stok dan menghapus penandanya,
  -- jadi penguncian ini menerapkannya lagi dari awal.
  IF NOT v_already_returned THEN
    FOR v_item IN
      SELECT ai.product_id,
             COALESCE(ai.returned_quantity, COALESCE(ai.physical_remaining, 0)) AS returned_quantity
        FROM public.driver_allocation_items ai
       WHERE ai.allocation_id = p_allocation_id
         AND COALESCE(ai.returned_quantity, COALESCE(ai.physical_remaining, 0)) > 0
    LOOP
      UPDATE public.products
         SET stock_quantity = stock_quantity + v_item.returned_quantity
       WHERE id = v_item.product_id
      RETURNING * INTO v_prod;

      INSERT INTO public.stock_movements
        (product_id, delta, balance_after, reason, note, reference_id, actor_id)
      VALUES (v_item.product_id, v_item.returned_quantity, v_prod.stock_quantity,
              'allocation_return',
              'Sisa gerobak kembali ' || v_alloc.date, v_alloc.id, auth.uid());

      v_total_returned := v_total_returned + v_item.returned_quantity;
    END LOOP;
  END IF;

  RETURN v_alloc;
END;
$$;

REVOKE ALL ON FUNCTION public.lock_reconciliation(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lock_reconciliation(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
