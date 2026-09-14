-- ============================================================
-- 0028 — Setiap hari jualan punya awal dan akhir
--
-- MASALAHNYA, dari data produksi 7–14 September 2026:
--
--   Rp677.000 dari Rp1.644.000 (41%) tidak pernah diakui masuk.
--   Empat dari delapan hari:
--
--     9 Sep  — muatan dicatat, hari tidak pernah ditutup
--    10 Sep  — TIDAK ADA baris alokasi sama sekali; 9 cup terjual
--    11 Sep  — TIDAK ADA baris alokasi sama sekali; 13 cup terjual
--    12 Sep  — alokasi dibuat jam 13:05, penjualan pertama jam 12:17
--
-- Ketiganya satu sebab: create_order menulis pesanan walau tidak ada
-- alokasi untuk hari itu, lalu MELEWATI seluruh pemotongan stok dalam
-- diam:
--
--     IF v_alloc_id IS NOT NULL THEN        -- tidak ada alokasi -> lewat
--       SELECT ... INTO v_remaining ...
--       IF FOUND THEN                       -- produk tidak di alokasi -> lewat
--
-- Pesanannya tersimpan lengkap — cup, menu, jam, lokasi. Yang hilang
-- cuma pembandingnya: berapa yang dibawa pagi itu. Tanpa pembanding,
-- selisih setoran mustahil dihitung, bukan karena selisihnya nol,
-- melainkan karena pertanyaannya tidak pernah bisa diajukan.
--
-- Bukti 12 Sep yang paling jelas: PAMAN dibawa 5, terjual 6. Enam
-- pesanan terpisah, satu cup masing-masing. Yang jam 12:17 jatuh
-- sebelum alokasi ada, jadi tidak ikut terpotong. sold_quantity
-- berhenti di 5 dan hari itu sampai sekarang TIDAK BISA dikunci:
-- lock_reconciliation menyegarkan terjual jadi 6, lalu menolak karena
-- 6 > 5 (AUDIT_NUMBERS_IMPOSSIBLE).
--
-- ------------------------------------------------------------
-- YANG TIDAK DILAKUKAN MIGRASI INI, DAN KENAPA
--
-- Jalan yang kelihatannya benar adalah menolak pesanan pada hari yang
-- belum dialokasikan. Itu keliru, dan arah kelirunya berbahaya.
--
-- Driver bukan pihak yang lalai — yang lalai adalah yang lupa mencatat
-- muatan. Menolak pesanannya tidak membatalkan penjualan; pembeli sudah
-- berdiri di depan gerobak dan tetap dilayani. Yang batal cuma
-- PENCATATANNYA. Pada 10 dan 11 September, penolakan akan mengubah 22
-- cup yang sekarang tercatat-tapi-tak-berpasangan menjadi 22 cup yang
-- tidak ada sama sekali.
--
-- Karena itu aturannya dibalik: penjualan TIDAK PERNAH ditolak, dan
-- sebagai gantinya tidak ada lagi jalan keluar yang sunyi. Hari selalu
-- punya baris. Produk selalu punya baris. Yang tidak tercatat muncul
-- sebagai muatan 0 dengan terjual 6 — angka janggal yang menuntut
-- jawaban, bukan celah yang tidak meninggalkan bekas.
--
-- Konsekuensinya INSUFFICIENT_STOCK dicabut dari create_order. Pagar
-- itu dipasang untuk menahan salah ketik, tapi harganya adalah
-- penjualan sah yang hilang — dan sejak 0025 salah ketik sudah punya
-- jalan perbaikan sendiri yang berjejak (driver_edit_order). Menahan
-- salah ketik dengan cara membuang penjualan asli itu tukar yang rugi.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Penanda: hari ini lahir dari penjualan, bukan dari pencatatan
-- ------------------------------------------------------------
ALTER TABLE public.driver_daily_allocations
  ADD COLUMN IF NOT EXISTS dibuat_otomatis BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.driver_daily_allocations.dibuat_otomatis IS
  'true bila baris ini dibuat create_order karena hari itu belum '
  'dialokasikan. Muatannya tidak pernah dicatat siapa pun, jadi '
  'initial_quantity-nya 0 dan tidak bisa dipakai sebagai pembanding '
  'sampai admin mengakuinya lewat admin_akui_muatan_dari_penjualan().';

-- Jejak audit alokasi selama ini cuma mengenal 'reconciled' dan
-- 'unlocked'. Pengakuan muatan adalah tindakan ketiga yang menggeser
-- angka final sebuah hari, jadi ia harus meninggalkan jejak yang setara —
-- kalau tidak, satu-satunya cara mengetahui muatan pernah diubah adalah
-- membandingkan angka yang sudah tidak ada pembandingnya.
ALTER TABLE public.allocation_audit_log
  DROP CONSTRAINT IF EXISTS allocation_audit_log_action_check;

ALTER TABLE public.allocation_audit_log
  ADD CONSTRAINT allocation_audit_log_action_check
  CHECK (action IN ('reconciled', 'unlocked', 'muatan_diakui'));

-- ------------------------------------------------------------
-- 2. create_order: tidak ada lagi jalan keluar yang sunyi
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
  -- Diterima tapi tidak dipakai. Aplikasi yang sudah ter-cache di ponsel
  -- driver (PWA) masih mengirim parameter ini; kalau tanda tangannya
  -- tidak cocok, PostgREST menjawab "fungsi tidak ditemukan" dan SETIAP
  -- penjualan gagal sampai ponselnya memuat ulang aplikasi.
  p_customer_type      TEXT DEFAULT NULL,
  p_cara_pesan         TEXT DEFAULT NULL
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
  v_qty          INTEGER;
  v_price        INTEGER;
  v_created_at   TIMESTAMPTZ;
  v_alloc_status TEXT;
  v_hari         DATE;
BEGIN
  IF v_driver IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '28000';
  END IF;

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
  IF p_cara_pesan IS NOT NULL AND p_cara_pesan NOT IN ('sebut', 'lihat') THEN
    p_cara_pesan := NULL;
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

  -- Waktu yang terlalu tua DITOLAK, bukan digeser ke sekarang: pesanan
  -- yang menunggu sinyal berhari-hari dulu tersimpan dengan tanggal
  -- pengiriman, dan omzet berpindah hari tanpa memberi tahu siapa pun.
  IF v_created_at < NOW() - INTERVAL '2 days' THEN
    RAISE EXCEPTION 'ORDER_TOO_OLD' USING ERRCODE = '22023';
  END IF;

  v_hari := (v_created_at AT TIME ZONE 'Asia/Jakarta')::date;

  SELECT id, status INTO v_alloc_id, v_alloc_status
    FROM public.driver_daily_allocations
   WHERE driver_id = v_driver AND date = v_hari;

  -- Hari yang auditnya sudah dikunci tidak boleh menerima penjualan baru.
  -- Ini satu-satunya penolakan yang tersisa yang berkaitan dengan alokasi,
  -- dan ia sah: angka yang sudah final tidak boleh bergerak diam-diam.
  IF v_alloc_status = 'reconciled' THEN
    RAISE EXCEPTION 'DAY_RECONCILED' USING ERRCODE = '22023';
  END IF;

  -- Hari yang belum dialokasikan DIBUATKAN barisnya, bukan ditolak.
  -- ON CONFLICT menjaga dua pesanan pertama yang datang bersamaan dari
  -- antrean luring tidak saling menjatuhkan; DO UPDATE (bukan DO NOTHING)
  -- dipakai supaya RETURNING tetap memberi id pada kedua jalur.
  IF v_alloc_id IS NULL THEN
    INSERT INTO public.driver_daily_allocations (driver_id, date, status, dibuat_otomatis)
    VALUES (v_driver, v_hari, 'active', true)
    ON CONFLICT (driver_id, date) DO UPDATE SET driver_id = EXCLUDED.driver_id
    RETURNING id INTO v_alloc_id;
  END IF;

  v_order_number := 'RMJ-'
    || to_char(v_created_at AT TIME ZONE 'Asia/Jakarta', 'YYYYMMDD-HH24MISS')
    || '-' || lpad((nextval('public.order_number_seq') % 100000)::text, 5, '0');

  INSERT INTO public.orders (
    shift_id, driver_id, order_number,
    latitude, longitude, total_amount, payment_method, customer_notes,
    client_order_id, created_at,
    customer_gender, customer_age_range, cara_pesan
  )
  VALUES (
    p_shift_id, v_driver, v_order_number,
    p_latitude, p_longitude, 0, p_payment_method, p_customer_notes,
    p_client_order_id, v_created_at,
    p_customer_gender, p_customer_age_range, p_cara_pesan
  )
  RETURNING * INTO v_order;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::UUID;
    v_qty        := (v_item->>'quantity')::INTEGER;

    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'INVALID_QUANTITY' USING ERRCODE = '22023';
    END IF;

    SELECT price INTO v_price
      FROM public.products
     WHERE id = v_product_id AND is_available = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'PRODUCT_UNAVAILABLE' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
    VALUES (v_order.id, v_product_id, v_qty, v_price, v_price * v_qty);

    v_total := v_total + (v_price * v_qty);

    -- Produk yang tidak ada di alokasi DIBUATKAN barisnya dengan muatan 0,
    -- bukan dilewati. Terjual 6 dari muatan 0 adalah angka janggal yang
    -- menuntut jawaban; tidak adanya baris sama sekali tidak menuntut apa
    -- pun, dan itulah yang membuat 22 cup pada 10–11 September lolos tanpa
    -- seorang pun tahu.
    --
    -- Upsert ini sekaligus mengunci barisnya, jadi tidak perlu SELECT
    -- ... FOR UPDATE terpisah dan tidak ada celah antara memeriksa dan
    -- menulis.
    INSERT INTO public.driver_allocation_items
      (allocation_id, product_id, initial_quantity, sold_quantity)
    VALUES (v_alloc_id, v_product_id, 0, v_qty)
    ON CONFLICT (allocation_id, product_id) DO UPDATE
      SET sold_quantity = driver_allocation_items.sold_quantity + EXCLUDED.sold_quantity;
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

-- ------------------------------------------------------------
-- 3. Mengakui muatan yang tidak pernah dicatat
--
-- Untuk hari yang terlanjur berjalan tanpa pencatatan muatan. Yang
-- terjual diakui sebagai yang dibawa — bukan tebakan, melainkan batas
-- bawah yang pasti: cup itu nyata keluar dari gerobak, jadi ia nyata
-- pernah dimuat.
--
-- Stok pusat ikut dipotong sebesar selisihnya, karena cup-cup itu
-- memang fisik meninggalkan basecamp dan selama ini tidak pernah
-- tercatat keluar. Bila potongan itu membuat stok jadi negatif, angkanya
-- dibiarkan negatif: itu bukan kerusakan, itu pengakuan bahwa angka stok
-- selama ini lebih besar daripada barang yang benar-benar ada.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_akui_muatan_dari_penjualan(
  p_allocation_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_alloc  public.driver_daily_allocations;
  v_item   RECORD;
  v_prod   public.products;
  v_diakui INTEGER := 0;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_alloc
    FROM public.driver_daily_allocations
   WHERE id = p_allocation_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ALLOCATION_NOT_FOUND' USING ERRCODE = '22023';
  END IF;
  IF v_alloc.status = 'reconciled' THEN
    RAISE EXCEPTION 'RECONCILIATION_LOCKED' USING ERRCODE = '42501';
  END IF;

  -- Disegarkan dari transaksi sebenarnya dulu, sama seperti yang dilakukan
  -- lock_reconciliation: sold_quantity adalah cuplikan yang bisa tertinggal,
  -- dan yang diakui haruslah kenyataan pada saat ini.
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

  FOR v_item IN
    SELECT ai.product_id,
           ai.sold_quantity - ai.initial_quantity AS kurang
      FROM public.driver_allocation_items ai
     WHERE ai.allocation_id = p_allocation_id
       AND ai.sold_quantity > ai.initial_quantity
  LOOP
    UPDATE public.products
       SET stock_quantity = stock_quantity - v_item.kurang
     WHERE id = v_item.product_id
    RETURNING * INTO v_prod;

    INSERT INTO public.stock_movements
      (product_id, delta, balance_after, reason, note, reference_id, actor_id)
    VALUES (v_item.product_id, -v_item.kurang, v_prod.stock_quantity,
            'allocation',
            'Muatan diakui dari penjualan ' || v_alloc.date,
            v_alloc.id, auth.uid());

    UPDATE public.driver_allocation_items
       SET initial_quantity = sold_quantity
     WHERE allocation_id = p_allocation_id AND product_id = v_item.product_id;

    v_diakui := v_diakui + v_item.kurang;
  END LOOP;

  UPDATE public.driver_daily_allocations
     SET dibuat_otomatis = false
   WHERE id = p_allocation_id;

  INSERT INTO public.allocation_audit_log
    (allocation_id, action, actor_id, cash_settled, cash_expected, note)
  VALUES (p_allocation_id, 'muatan_diakui', auth.uid(),
          v_alloc.cash_settled, v_alloc.total_cash_collected,
          v_diakui || ' cup diakui sebagai muatan dari angka penjualan');

  RETURN v_diakui;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_akui_muatan_dari_penjualan(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_akui_muatan_dari_penjualan(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 4. lock_reconciliation: sebab penolakan yang bisa ditindaklanjuti
--
-- Hari yang muatannya tidak pernah dicatat selalu punya terjual > dibawa,
-- jadi ia selalu tertolak AUDIT_NUMBERS_IMPOSSIBLE — sebab yang benar
-- tapi tidak memberi tahu apa yang harus dilakukan. Kasus itu sekarang
-- punya sebabnya sendiri, dan sebabnya menyebut jalan keluarnya.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lock_reconciliation(
  p_allocation_id UUID,
  p_note TEXT DEFAULT NULL
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
  -- dinilai. Yang dibekukan haruslah kebenaran pada saat penguncian, bukan
  -- kebenaran pada saat layar dibuka.
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

  -- Muatan yang tidak pernah dicatat: sebabnya sendiri, supaya admin tahu
  -- harus memanggil admin_akui_muatan_dari_penjualan(), bukan mengira
  -- angkanya rusak.
  FOR v_item IN
    SELECT p.name
      FROM public.driver_allocation_items ai
      JOIN public.products p ON p.id = ai.product_id
     WHERE ai.allocation_id = p_allocation_id
       AND ai.initial_quantity = 0
       AND ai.sold_quantity > 0
  LOOP
    RAISE EXCEPTION 'MUATAN_BELUM_DICATAT:%', v_item.name USING ERRCODE = '22023';
  END LOOP;

  -- Angka yang mustahil ditolak, bukan dikunci.
  --
  --     terjual + sisa fisik + rusak  tidak boleh melebihi  dibawa
  --
  -- Selisih ke arah sebaliknya (ada cup yang hilang) tetap diizinkan —
  -- itu kejadian nyata yang memang perlu tercatat.
  FOR v_item IN
    SELECT p.name
      FROM public.driver_allocation_items ai
      JOIN public.products p ON p.id = ai.product_id
     WHERE ai.allocation_id = p_allocation_id
       AND ai.sold_quantity + COALESCE(ai.physical_remaining, 0) + ai.waste_quantity
           > ai.initial_quantity
  LOOP
    RAISE EXCEPTION 'AUDIT_NUMBERS_IMPOSSIBLE:%', v_item.name USING ERRCODE = '22023';
  END LOOP;

  -- Yang dikembalikan tidak boleh melebihi yang benar-benar ada di tangan.
  FOR v_item IN
    SELECT p.name
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

  INSERT INTO public.allocation_audit_log
    (allocation_id, action, actor_id, cash_settled, cash_expected, note)
  VALUES (v_alloc.id, 'reconciled', auth.uid(),
          v_alloc.cash_settled, v_alloc.total_cash_collected, p_note);

  -- Pengembalian hanya diterapkan sekali.
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
    END LOOP;
  END IF;

  RETURN v_alloc;
END;
$$;

-- ------------------------------------------------------------
-- 5. Hari yang perlu perhatian
--
-- Penyaring yang bekerja diam-diam tidak bisa dipercaya. Pagar di
-- create_order menahan kejadian baru, tapi ia tidak memberi tahu siapa
-- pun bahwa ada hari lama yang menggantung. Fungsi inilah yang membuat
-- tagihan itu kelihatan.
--
-- Hari ini tidak pernah masuk daftar: hari yang sedang berjalan memang
-- belum ditutup, dan menagihnya membuat daftar ini berisik tiap hari
-- lalu berhenti dibaca.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_hari_perlu_perhatian()
RETURNS TABLE (
  allocation_id   UUID,
  hari            DATE,
  driver_id       UUID,
  driver_name     TEXT,
  cup             INTEGER,
  omzet           BIGINT,
  umur_hari       INTEGER,
  muatan_dicatat  BOOLEAN,
  cup_di_luar_muatan INTEGER
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Ditolak dengan sebab, bukan dijawab daftar kosong. Daftar kosong dari
  -- pertanyaan yang tidak pernah diizinkan terbaca sebagai "tidak ada hari
  -- yang menggantung" — kebohongan yang persis sama bentuknya dengan
  -- dashboard yang dulu menampilkan "0 cup".
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT a.id,
         a.date,
         a.driver_id,
         COALESCE(pr.full_name, '(tanpa nama)'),
         COALESCE(j.cup, 0)::INTEGER,
         COALESCE(j.omzet, 0)::BIGINT,
         ((NOW() AT TIME ZONE 'Asia/Jakarta')::date - a.date)::INTEGER,
         NOT (a.dibuat_otomatis
              OR EXISTS (SELECT 1 FROM public.driver_allocation_items ai
                          WHERE ai.allocation_id = a.id
                            AND ai.initial_quantity = 0
                            AND ai.sold_quantity > 0)),
         COALESCE((SELECT sum(GREATEST(ai.sold_quantity - ai.initial_quantity, 0))
                     FROM public.driver_allocation_items ai
                    WHERE ai.allocation_id = a.id), 0)::INTEGER
    FROM public.driver_daily_allocations a
    LEFT JOIN public.profiles pr ON pr.id = a.driver_id
    LEFT JOIN LATERAL (
      SELECT sum(public.order_cup_count(o.id))::INTEGER AS cup,
             sum(o.total_amount)::BIGINT               AS omzet
        FROM public.orders o
       WHERE o.driver_id = a.driver_id
         AND o.created_at >= public.wib_day_start(a.date)
         AND o.created_at <  public.wib_day_start(a.date + 1)
    ) j ON true
   WHERE a.reconciled_at IS NULL
     AND a.date < (NOW() AT TIME ZONE 'Asia/Jakarta')::date
   ORDER BY a.date;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_hari_perlu_perhatian() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_hari_perlu_perhatian() TO authenticated;

-- ------------------------------------------------------------
-- 6. Perbaikan data lama: hari yang berjualan tanpa baris alokasi
--
-- 10 dan 11 September tidak punya baris sama sekali, jadi keduanya tidak
-- muncul di layar rekonsiliasi mana pun — tidak bisa ditutup karena
-- tidak bisa dilihat. Barisnya dibuat di sini supaya hari-hari itu punya
-- tempat, dengan muatan 0 dan terjual sesuai transaksi yang benar-benar
-- ada.
--
-- Yang SENGAJA TIDAK dilakukan: menyentuh stok pusat dan mengarang angka
-- setoran. Keduanya keputusan yang harus diambil manusia yang ingat hari
-- itu, lewat admin_akui_muatan_dari_penjualan() dan layar rekonsiliasi.
-- Migrasi yang diam-diam merapikan angka uang adalah persis penyakit
-- yang sedang diobati berkas ini.
--
-- Aman dijalankan ulang: mencari yang belum ada, bukan membuat ulang.
-- ------------------------------------------------------------
DO $$
DECLARE
  v_hari    RECORD;
  v_alloc   UUID;
  v_dibuat  INTEGER := 0;
BEGIN
  FOR v_hari IN
    SELECT h.driver_id, h.tanggal
      FROM (
        SELECT o.driver_id,
               (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS tanggal
          FROM public.orders o
         GROUP BY 1, 2
      ) h
     WHERE NOT EXISTS (
             SELECT 1 FROM public.driver_daily_allocations a
              WHERE a.driver_id = h.driver_id
                AND a.date = h.tanggal)
     ORDER BY h.tanggal
  LOOP
    INSERT INTO public.driver_daily_allocations (driver_id, date, status, dibuat_otomatis)
    VALUES (v_hari.driver_id, v_hari.tanggal, 'active', true)
    RETURNING id INTO v_alloc;

    INSERT INTO public.driver_allocation_items
      (allocation_id, product_id, initial_quantity, sold_quantity)
    SELECT v_alloc, oi.product_id, 0, sum(oi.quantity)::INTEGER
      FROM public.orders o
      JOIN public.order_items oi ON oi.order_id = o.id
     WHERE o.driver_id = v_hari.driver_id
       AND o.created_at >= public.wib_day_start(v_hari.tanggal)
       AND o.created_at <  public.wib_day_start(v_hari.tanggal + 1)
     GROUP BY oi.product_id;

    v_dibuat := v_dibuat + 1;
    RAISE NOTICE 'Alokasi dibuat untuk % (%)', v_hari.tanggal, v_hari.driver_id;
  END LOOP;

  RAISE NOTICE '0028: % hari berjualan tanpa alokasi diberi baris', v_dibuat;
END;
$$;

-- Angka terjual pada hari yang alokasinya terlambat dibuat juga tertinggal
-- (12 September: PAMAN terjual 6, tercatat 5, karena pesanan jam 12:17
-- mendahului alokasi jam 13:05). Disegarkan dari transaksi untuk seluruh
-- hari yang belum dikunci; hari yang sudah dikunci tidak disentuh, karena
-- angka yang sudah final tidak boleh bergerak.
UPDATE public.driver_allocation_items ai
   SET sold_quantity = COALESCE((
         SELECT sum(oi.quantity)::INTEGER
           FROM public.orders o
           JOIN public.order_items oi ON oi.order_id = o.id
          WHERE o.driver_id = a.driver_id
            AND oi.product_id = ai.product_id
            AND o.created_at >= public.wib_day_start(a.date)
            AND o.created_at <  public.wib_day_start(a.date + 1)
       ), 0)
  FROM public.driver_daily_allocations a
 WHERE a.id = ai.allocation_id
   AND a.reconciled_at IS NULL;

NOTIFY pgrst, 'reload schema';
