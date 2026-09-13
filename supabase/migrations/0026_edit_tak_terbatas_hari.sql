-- ============================================================
-- 0026 — Batas "hanya hari ini" dicabut dari perbaikan pesanan
-- ============================================================
--
-- Migrasi 0025 menolak perbaikan atas pesanan hari sebelumnya, dengan
-- alasan memperbaiki hari kemarin berarti menggeser angka yang mungkin
-- sudah dipakai menghitung.
--
-- Alasan itu tidak salah, tetapi penjaganya keliru. Yang benar-benar
-- menandai "angka hari ini sudah dipakai" bukan pergantian tanggal,
-- melainkan REKONSILIASI: saat admin menutup hari itu, mencocokkan kas,
-- dan menguncinya. Kunci itu sudah ada sejak 0003 dan sudah diperiksa di
-- boleh_ubah_pesanan.
--
-- Jadi batas tanggal hanyalah lapisan kedua di atas penjaga yang sudah
-- benar — dan lapisan itu menimbulkan kerugian nyata: salah ketik yang
-- baru ketahuan keesokan harinya menjadi mustahil diperbaiki, padahal
-- justru begitulah kebanyakan salah ketik ketahuan. Angka yang salah
-- lalu menetap selamanya, dan itu persis keadaan yang hendak dihindari
-- seluruh berkas ini.
--
-- Yang tersisa sebagai penjaga, dan memang cukup:
--   1. Hanya pesanan milik driver itu sendiri (admin boleh semuanya).
--   2. Ditolak bila hari itu sudah direkonsiliasi.
--   3. Setiap perubahan menyimpan potret sebelum dan sesudahnya di
--      order_audit_log, yang tidak bisa dihapus dari aplikasi.
--
-- Catatan yang perlu disadari pemakainya: karena batas tanggal hilang,
-- hari yang TIDAK PERNAH direkonsiliasi tetap bisa diubah selamanya.
-- Yang menutupnya adalah disiplin merekonsiliasi, bukan kode ini.
-- Jejak audit tetap merekam setiap perubahan apa pun.
--
-- Idempoten.
-- ============================================================

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

  -- Satu-satunya batas waktu yang berarti: hari yang sudah ditutup dan
  -- kasnya dicocokkan. Tanggal kalender tidak menandai apa pun.
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

NOTIFY pgrst, 'reload schema';
