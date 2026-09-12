-- ============================================================
-- 0024 — "Sebut menu tanpa lihat" menggantikan tebakan langganan
-- ============================================================
--
-- Kolom customer_type tidak pernah bisa dipercaya, dan sebabnya bukan
-- bug: ia meminta driver mengingat wajah. Driver tidak hafal wajah, jadi
-- 55 dari 64 transaksi tercatat 'new' dan hanya 2 yang 'returning'.
-- Angka 2,5% itu bukan tingkat beli-ulang RAMU — itu tingkat keberhasilan
-- driver mengenali orang.
--
-- Padahal beli-ulang adalah angka yang menentukan keputusan ruko. Ruko
-- hidup dari langganan, bukan dari orang lewat.
--
-- Yang berubah: pertanyaannya. Bukan lagi "orang ini pernah beli?" —
-- itu soal INGATAN. Tapi "orang ini menyebut menu tanpa lihat daftar?" —
-- itu soal APA YANG TERJADI DI DEPAN MATA, sekarang, dan driver selalu
-- bisa menjawabnya jujur.
--
-- Sinyalnya datang dari lapangan lebih dulu: driver melaporkan makin
-- banyak pembeli yang langsung menyebut "KPK" atau "BNN" tanpa melihat
-- menu. Data menguatkan bahwa dua nama itu memang laku — KPK 7 cup di 4
-- dari 6 hari, BNN 15 cup di 5 dari 6 hari.
--
-- Orang yang menyebut nama berarti namanya sudah keluar dari gerobak:
-- entah ia pernah beli, entah ada yang bercerita kepadanya. Keduanya
-- persis yang dibutuhkan sebuah merek.
--
-- Cara membacanya per titik mangkal:
--   * titik tetap  -> persentase naik = lingkungan menghangat, langganan tumbuh
--   * titik baru   -> mulai dari nol; tetap nol setelah dua minggu = tidak nyangkut
--
-- Itu yang membedakan "area ini jadi pasar" dari "area ini cuma kita
-- datangi" — dan itu yang menentukan ruko.
--
-- customer_type dibuang sampai ke akarnya: parameter, kolom, dan
-- barisnya di laporan. Membiarkannya lebih berbahaya daripada
-- menghapusnya — selama ada, seseorang akan membacanya sebagai
-- kebenaran. Itu sudah terjadi: angka "17% jadi langganan, 5 langganan =
-- 37% bisnis" dikutip berkali-kali dalam analisis sebelum ketahuan
-- tidak pernah ada di basis data.
--
-- Kolom dan barisnya di laporan dihapus sekarang karena tidak ada
-- antrean offline yang menggantung di ponsel driver.
--
-- PARAMETERNYA tetap diterima, dan itu bukan kehati-hatian berlebih:
-- aplikasi driver adalah PWA yang tersimpan di ponsel. Selama ponsel itu
-- belum memuat versi baru, ia masih mengirim p_customer_type — dan
-- PostgREST mencocokkan fungsi berdasarkan seluruh tanda tangannya, jadi
-- satu parameter yang hilang membuat SETIAP penjualan ditolak dengan
-- "fungsi tidak ditemukan". Harganya satu parameter yang tidak dipakai;
-- risikonya kalau tidak: gerobak tidak bisa mencatat apa pun seharian.
--
-- Idempoten.
-- ============================================================

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS cara_pesan TEXT;

DO $c$
BEGIN
  ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_cara_pesan_check;
  ALTER TABLE public.orders
    ADD CONSTRAINT orders_cara_pesan_check
    CHECK (cara_pesan IS NULL OR cara_pesan IN ('sebut', 'lihat'));
END;
$c$;

COMMENT ON COLUMN public.orders.cara_pesan IS
  '"sebut" = pembeli menyebut nama menu tanpa melihat daftar. "lihat" = '
  'membaca menu dulu. NULL = tidak sempat dicatat. Pengganti customer_type '
  'yang meminta driver mengingat wajah.';

-- Parameter bertambah satu, jadi tanda tangannya berubah dan
-- CREATE OR REPLACE akan membuat fungsi KEDUA, bukan mengganti yang lama.
-- Dua create_order sekaligus membuat PostgREST tidak bisa memilih.
DROP FUNCTION IF EXISTS public.create_order(
  UUID, JSONB, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
  TEXT, UUID, TIMESTAMPTZ, TEXT, TEXT, TEXT);

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
  -- penjualan gagal sampai ponselnya memuat ulang aplikasi. Dihapus
  -- setelah semua perangkat dipastikan sudah pada versi baru.
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
REVOKE ALL ON FUNCTION public.create_order(UUID, JSONB, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, UUID, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_order(UUID, JSONB, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, UUID, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- Laporan: berapa persen pembeli yang sudah hafal
-- ------------------------------------------------------------
-- Penyebutnya dibuka. "Belum dicatat" ditampilkan terpisah dan TIDAK
-- ikut jadi penyebut, supaya persentase tidak turun hanya karena driver
-- sedang sibuk dan melewatkan pencatatan.
DROP FUNCTION IF EXISTS public.admin_hafal_menu(DATE, DATE);

CREATE OR REPLACE FUNCTION public.admin_hafal_menu(
  p_from DATE,
  p_to   DATE
)
RETURNS TABLE (
  hari           DATE,
  transaksi      INTEGER,
  sebut          INTEGER,
  lihat          INTEGER,
  belum_dicatat  INTEGER,
  persen_sebut   NUMERIC
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $fn$
  WITH span AS (
    SELECT LEAST(p_from, p_to) AS d_from,
           LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365) AS d_to
  ),
  pes AS (
    SELECT (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS d,
           o.cara_pesan
      FROM public.orders o, span s
     WHERE o.created_at >= public.wib_day_start(s.d_from)
       AND o.created_at <  public.wib_day_start(s.d_to + 1)
  )
  SELECT d,
         count(*)::INTEGER,
         count(*) FILTER (WHERE cara_pesan = 'sebut')::INTEGER,
         count(*) FILTER (WHERE cara_pesan = 'lihat')::INTEGER,
         count(*) FILTER (WHERE cara_pesan IS NULL)::INTEGER,
         CASE WHEN count(*) FILTER (WHERE cara_pesan IS NOT NULL) > 0
              THEN round(100.0 * count(*) FILTER (WHERE cara_pesan = 'sebut')
                         / count(*) FILTER (WHERE cara_pesan IS NOT NULL), 1)
              ELSE NULL END
    FROM pes
   WHERE public.get_user_role(auth.uid()) = 'admin'
   GROUP BY d
   ORDER BY d;
$fn$;

REVOKE ALL ON FUNCTION public.admin_hafal_menu(DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_hafal_menu(DATE, DATE) TO authenticated;

-- ------------------------------------------------------------
-- Laporan profil: baris 'type' diganti 'cara_pesan'
-- ------------------------------------------------------------
-- Kolomnya dibuang, jadi laporan yang membacanya harus ikut diperbaiki
-- pada migrasi yang sama. Kalau tidak, admin_customer_insights langsung
-- rusak begitu kolomnya hilang.
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
AS $fn$
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
  SELECT 'cara_pesan', COALESCE(cara_pesan, 'unknown'),
         count(*)::INTEGER, COALESCE(sum(total_amount), 0)::BIGINT
    FROM scoped GROUP BY 2;
$fn$;

REVOKE ALL ON FUNCTION public.admin_customer_insights(INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_customer_insights(INTEGER) TO authenticated;

-- ------------------------------------------------------------
-- Kolomnya dibuang paling akhir, setelah tidak ada lagi yang membacanya
-- ------------------------------------------------------------
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_customer_type_check;
ALTER TABLE public.orders DROP COLUMN IF EXISTS customer_type;

NOTIFY pgrst, 'reload schema';
