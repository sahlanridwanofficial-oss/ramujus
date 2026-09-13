-- ============================================================
-- 0027 — Penandaan event pindah ke driver, di lapangan
-- ============================================================
--
-- 0023 membuat booth event bisa dikeluarkan dari analitik lokasi, dan
-- penyaringnya bekerja: pada data 13 Sep 2026 seluruh 7 transaksi dan 29
-- cup kesaring, tidak ada yang bocor ke peta.
--
-- Tetapi penandaannya hanya bisa dipasang admin, SESUDAH kejadian, dan
-- hanya bila ada yang ingat memberitahu. Itu titik rapuh yang serius:
-- kalau tidak ada yang cerita, booth event menyelinap ke peta sebagai
-- titik terbaik yang pernah terukur — dan tidak ada satu pun tanda bahwa
-- ada yang keliru. Kesalahan yang diam adalah kesalahan yang paling mahal
-- di sini, karena yang dibelokkan adalah keputusan sewa.
--
-- Yang tahu sebuah tempat itu booth event atau titik mangkal biasa adalah
-- orang yang berdiri di sana. Maka penandaannya dipindahkan ke sana:
-- satu ketukan saat mangkal dimulai, bukan koreksi belakangan.
--
-- ------------------------------------------------------------
-- Kenapa tanda tangan driver_start_stop diganti, bukan ditambah
-- ------------------------------------------------------------
-- Menambah parameter lewat CREATE OR REPLACE membuat fungsi KEDUA dengan
-- nama sama, dan PostgREST tidak bisa memilih di antara keduanya. Jadi
-- yang lama dibuang lebih dulu.
--
-- Parameter barunya ditaruh paling belakang dan berdefault, supaya
-- aplikasi yang masih tersimpan di ponsel driver (PWA) — yang mengirim
-- empat argumen lama — tetap diterima. Tanpa itu, setiap ketukan
-- "Mangkal di sini" gagal sampai ponselnya memuat ulang aplikasi.
--
-- Idempoten.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Mangkal bisa dibuka langsung sebagai booth event
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.driver_start_stop(
  DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, UUID);

CREATE OR REPLACE FUNCTION public.driver_start_stop(
  p_latitude       DOUBLE PRECISION DEFAULT NULL,
  p_longitude      DOUBLE PRECISION DEFAULT NULL,
  p_accuracy       DOUBLE PRECISION DEFAULT NULL,
  p_client_stop_id UUID DEFAULT NULL,
  p_is_event       BOOLEAN DEFAULT false
)
RETURNS public.driver_stops
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_driver UUID := auth.uid();
  v_shift  UUID;
  v_stop   public.driver_stops;
BEGIN
  IF v_driver IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  -- Ketukan yang sama dikirim ulang: kembalikan catatan yang sudah ada.
  IF p_client_stop_id IS NOT NULL THEN
    SELECT * INTO v_stop FROM public.driver_stops
     WHERE client_stop_id = p_client_stop_id AND driver_id = v_driver;
    IF FOUND THEN
      RETURN v_stop;
    END IF;
  END IF;

  UPDATE public.driver_stops
     SET ended_at = NOW()
   WHERE driver_id = v_driver AND ended_at IS NULL;

  SELECT id INTO v_shift FROM public.shifts
   WHERE driver_id = v_driver AND status = 'active'
   ORDER BY start_time DESC LIMIT 1;

  INSERT INTO public.driver_stops
    (driver_id, shift_id, latitude, longitude, accuracy, client_stop_id, is_event)
  VALUES
    (v_driver, v_shift, p_latitude, p_longitude, p_accuracy, p_client_stop_id,
     COALESCE(p_is_event, false))
  RETURNING * INTO v_stop;

  RETURN v_stop;
END;
$fn$;

REVOKE ALL ON FUNCTION public.driver_start_stop(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, UUID, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.driver_start_stop(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, UUID, BOOLEAN) TO authenticated;

-- ------------------------------------------------------------
-- 2. Salah tekan bisa dibetulkan tanpa menutup mangkalnya
-- ------------------------------------------------------------
-- Driver baru sadar "oh ini event" setelah setengah jam berjualan, atau
-- sebaliknya salah tekan tombol event di titik biasa. Menutup lalu
-- membuka ulang mangkal akan merusak lama mangkalnya — jadi penandanya
-- yang bisa dibalik, bukan mangkalnya yang diulang.
CREATE OR REPLACE FUNCTION public.driver_tandai_event_sekarang(
  p_is_event BOOLEAN DEFAULT true
)
RETURNS public.driver_stops
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_driver UUID := auth.uid();
  v_stop   public.driver_stops;
BEGIN
  IF v_driver IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  UPDATE public.driver_stops
     SET is_event = COALESCE(p_is_event, true)
   WHERE driver_id = v_driver AND ended_at IS NULL
  RETURNING * INTO v_stop;

  IF v_stop.id IS NULL THEN
    RAISE EXCEPTION 'NO_OPEN_STOP' USING ERRCODE = '22023';
  END IF;

  RETURN v_stop;
END;
$fn$;

REVOKE ALL ON FUNCTION public.driver_tandai_event_sekarang(BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.driver_tandai_event_sekarang(BOOLEAN) TO authenticated;

-- ------------------------------------------------------------
-- 3. Layar driver perlu tahu keadaannya, bukan menebak
-- ------------------------------------------------------------
-- Tanpa ini aplikasi tidak bisa menampilkan bahwa mangkal yang sedang
-- berjalan bertanda event, sehingga salah tekan tidak pernah terlihat.
DROP FUNCTION IF EXISTS public.driver_current_stop();

CREATE OR REPLACE FUNCTION public.driver_current_stop()
RETURNS TABLE (
  id          UUID,
  started_at  TIMESTAMPTZ,
  latitude    DOUBLE PRECISION,
  longitude   DOUBLE PRECISION,
  minutes     INTEGER,
  cups        INTEGER,
  is_event    BOOLEAN
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT s.id,
         s.started_at,
         s.latitude,
         s.longitude,
         (EXTRACT(EPOCH FROM (NOW() - s.started_at)) / 60)::INTEGER,
         COALESCE((
           SELECT sum(oi.quantity)::INTEGER
             FROM public.orders o
             JOIN public.order_items oi ON oi.order_id = o.id
             JOIN public.products pr ON pr.id = oi.product_id AND pr.category = 'smoothie'
            WHERE o.driver_id = s.driver_id AND o.created_at >= s.started_at
         ), 0),
         s.is_event
    FROM public.driver_stops s
   WHERE s.driver_id = auth.uid() AND s.ended_at IS NULL
   LIMIT 1;
$fn$;

REVOKE ALL ON FUNCTION public.driver_current_stop() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.driver_current_stop() TO authenticated;

-- ------------------------------------------------------------
-- 4. Admin bisa melihat apa yang dikeluarkan, bukan mempercayainya
-- ------------------------------------------------------------
-- Penyaring yang bekerja diam-diam tidak bisa dipercaya, karena tidak
-- ada yang tahu kalau ia salah. Fungsi ini membuat isinya kelihatan:
-- mangkal mana yang ditandai event, berapa cup dan rupiah yang ikut
-- keluar dari peta, dan di titik mana.
CREATE OR REPLACE FUNCTION public.admin_mangkal_event(
  p_from DATE,
  p_to   DATE
)
RETURNS TABLE (
  stop_id     UUID,
  driver_name TEXT,
  mulai       TIMESTAMPTZ,
  selesai     TIMESTAMPTZ,
  jam         NUMERIC,
  cups        INTEGER,
  omzet       BIGINT,
  latitude    DOUBLE PRECISION,
  longitude   DOUBLE PRECISION
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $fn$
  WITH span AS (
    SELECT LEAST(p_from, p_to) AS d_from,
           LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365) AS d_to
  )
  SELECT s.id,
         COALESCE(pr.full_name, '(tanpa nama)'),
         s.started_at,
         s.ended_at,
         round(EXTRACT(EPOCH FROM (COALESCE(s.ended_at, NOW()) - s.started_at)) / 3600.0, 2),
         COALESCE((
           SELECT sum(oi.quantity)::INTEGER
             FROM public.orders o
             JOIN public.order_items oi ON oi.order_id = o.id
             JOIN public.products p2 ON p2.id = oi.product_id AND p2.category = 'smoothie'
            WHERE o.driver_id = s.driver_id
              AND o.created_at >= s.started_at
              AND o.created_at <  COALESCE(s.ended_at, NOW()) + INTERVAL '30 minutes'
         ), 0),
         COALESCE((
           SELECT sum(oi.subtotal)::BIGINT
             FROM public.orders o
             JOIN public.order_items oi ON oi.order_id = o.id
            WHERE o.driver_id = s.driver_id
              AND o.created_at >= s.started_at
              AND o.created_at <  COALESCE(s.ended_at, NOW()) + INTERVAL '30 minutes'
         ), 0),
         s.latitude,
         s.longitude
    FROM public.driver_stops s
    LEFT JOIN public.profiles pr ON pr.id = s.driver_id,
         span sp
   WHERE s.is_event
     AND s.started_at >= public.wib_day_start(sp.d_from)
     AND s.started_at <  public.wib_day_start(sp.d_to + 1)
     AND public.get_user_role(auth.uid()) = 'admin'
   ORDER BY s.started_at DESC;
$fn$;

REVOKE ALL ON FUNCTION public.admin_mangkal_event(DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_mangkal_event(DATE, DATE) TO authenticated;

NOTIFY pgrst, 'reload schema';
