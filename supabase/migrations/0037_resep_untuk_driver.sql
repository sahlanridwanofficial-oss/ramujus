-- ============================================================
-- 0037 — Resep bisa dibaca driver
--
-- Takaran sudah tercatat rapi sejak 0030, tetapi hanya admin yang boleh
-- membacanya. Orang yang benar-benar menuangkannya justru tidak bisa
-- membukanya di ponselnya sendiri.
--
-- Akibatnya takaran hidup di dua tempat: di basis data, dan di kepala
-- Mahaliriki. Ketika keduanya berbeda, yang menang selalu yang di kepala,
-- dan HPP yang dihitung sistem diam-diam mengukur minuman yang tidak
-- pernah dibuat. Koreksi 0036 persis kejadian itu.
--
-- ------------------------------------------------------------
-- TAKARAN SAJA, TANPA RUPIAH
--
-- Fungsi ini sengaja tidak mengembalikan harga bahan, HPP, maupun margin.
-- Driver perlu tahu cara membuatnya, bukan biayanya. Memisahkan keduanya
-- di lapisan basis data lebih aman daripada memisahkannya di layar, sebab
-- layar bisa diubah tanpa sengaja sedangkan fungsi ini tidak pernah
-- membaca tabel belanja sama sekali.
--
-- ------------------------------------------------------------
-- VERSI YANG BERLAKU HARI INI
--
-- Yang dikembalikan adalah versi takaran yang berlaku hari ini menurut
-- waktu Jakarta, bukan versi terbaru. Kalau admin menyiapkan resep baru
-- yang berlaku pekan depan, driver tetap membaca takaran yang benar untuk
-- hari ini sampai tanggalnya tiba.
--
-- Urutannya menurun berdasarkan jumlah, sehingga bahan utama berada di
-- atas dan kemasan yang selalu satuan jatuh ke bawah dengan sendirinya.
-- Tidak ada daftar nama kemasan yang perlu dirawat.
-- ============================================================

CREATE OR REPLACE FUNCTION public.driver_resep()
RETURNS TABLE (
  product_id   UUID,
  menu         TEXT,
  harga        INTEGER,
  berlaku_dari DATE,
  bahan        TEXT,
  satuan       TEXT,
  jumlah       NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tgl DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  -- Admin ikut diizinkan supaya layar driver bisa diperiksa tanpa perlu
  -- akun driver sungguhan.
  IF public.get_user_role(auth.uid()) NOT IN ('driver', 'admin')
     OR public.get_user_status(auth.uid()) IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'DRIVER_ONLY' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT p.id, p.name, p.price,
         t.berlaku_dari, b.nama, b.satuan, t.jumlah
    FROM public.products p
    JOIN public.takaran t ON t.product_id = p.id
                         AND t.berlaku_dari = public.takaran_berlaku(p.id, v_tgl)
    JOIN public.bahan b ON b.id = t.bahan_id
   WHERE p.is_available
   ORDER BY p.sort_order, p.name, t.jumlah DESC, b.nama;
END;
$$;

REVOKE ALL ON FUNCTION public.driver_resep() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.driver_resep() TO authenticated;

NOTIFY pgrst, 'reload schema';
