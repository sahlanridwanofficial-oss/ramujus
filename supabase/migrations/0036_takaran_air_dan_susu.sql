-- ============================================================
-- 0036 — Koreksi takaran: Air 85→80 ml, Susu UHT BNN 80→90 ml
--
-- Resep yang disemai 0030 berasal dari catatan yang ditulis terburu-buru.
-- Setelah dicek ulang terhadap resep kerja yang dipakai di dapur, dua
-- angka ternyata salah salin:
--
--     Air       85 → 80 ml   pada KPK, PASUTRI, dan PASCA
--     Susu UHT  80 → 90 ml   pada BNN
--
-- PAMAN tidak berubah sama sekali.
--
-- ------------------------------------------------------------
-- KENAPA VERSI LAMA YANG DIPERBAIKI, BUKAN BIKIN VERSI BARU
--
-- Tabel takaran sengaja dibuat berversi supaya resep yang berubah di
-- tengah jalan tidak mengubah HPP bulan-bulan sebelumnya. Aturan itu
-- melindungi dari PERUBAHAN resep, bukan dari SALAH CATAT.
--
-- Gerobaknya tidak mengganti resep hari ini. Takaran ini memang yang
-- dipakai sejak 7 September. Kalau dibuat sebagai versi baru, delapan
-- hari pertama akan selamanya dihitung dengan takaran yang tidak pernah
-- benar-benar dituang. Jadi versi pertamanya yang diperbaiki.
--
-- ------------------------------------------------------------
-- HANYA MENYENTUH YANG MASIH SALAH
--
-- Setiap UPDATE menyaring nilai lamanya. Berkas ini aman dijalankan
-- ulang, dan tidak akan menimpa takaran yang sudah diperbaiki admin
-- lewat layar. Versi selain yang paling awal juga tidak disentuh.
--
-- Dampaknya pada biaya bahan kecil tapi searah pada BNN: Air Rp1,00/ml
-- membuat tiga menu turun Rp5 per cup, sedangkan Susu UHT Rp20,30/ml
-- membuat BNN naik Rp203 per cup.
-- ============================================================

DO $$
DECLARE
  v_air     UUID := (SELECT id FROM public.bahan WHERE nama = 'Air');
  v_susu    UUID := (SELECT id FROM public.bahan WHERE nama = 'Susu UHT');
  v_n_air   INTEGER := 0;
  v_n_susu  INTEGER := 0;
BEGIN
  IF v_air IS NULL OR v_susu IS NULL THEN
    RAISE EXCEPTION '0036: bahan Air atau Susu UHT belum ada — jalankan 0030 dulu';
  END IF;

  -- Air 85 → 80 pada KPK, PASUTRI, PASCA, versi paling awal saja.
  WITH sasaran AS (
    SELECT t.product_id, t.berlaku_dari, t.bahan_id
      FROM public.takaran t
      JOIN public.products p ON p.id = t.product_id
     WHERE t.bahan_id = v_air
       AND t.jumlah = 85
       AND (p.name LIKE 'KPK%' OR p.name LIKE 'PASUTRI%' OR p.name LIKE 'PASCA%')
       AND t.berlaku_dari = (SELECT min(x.berlaku_dari) FROM public.takaran x
                              WHERE x.product_id = t.product_id)
  )
  UPDATE public.takaran t SET jumlah = 80
    FROM sasaran s
   WHERE t.product_id   = s.product_id
     AND t.berlaku_dari = s.berlaku_dari
     AND t.bahan_id     = s.bahan_id;
  GET DIAGNOSTICS v_n_air = ROW_COUNT;

  -- Susu UHT 80 → 90 pada BNN saja. PAMAN juga memakai 80 ml dan memang
  -- tetap 80, jadi saringan namanya wajib ada.
  WITH sasaran AS (
    SELECT t.product_id, t.berlaku_dari, t.bahan_id
      FROM public.takaran t
      JOIN public.products p ON p.id = t.product_id
     WHERE t.bahan_id = v_susu
       AND t.jumlah = 80
       AND p.name LIKE 'BNN%'
       AND t.berlaku_dari = (SELECT min(x.berlaku_dari) FROM public.takaran x
                              WHERE x.product_id = t.product_id)
  )
  UPDATE public.takaran t SET jumlah = 90
    FROM sasaran s
   WHERE t.product_id   = s.product_id
     AND t.berlaku_dari = s.berlaku_dari
     AND t.bahan_id     = s.bahan_id;
  GET DIAGNOSTICS v_n_susu = ROW_COUNT;

  RAISE NOTICE '0036: Air diperbaiki pada % menu, Susu UHT pada % menu',
    v_n_air, v_n_susu;
END;
$$;

NOTIFY pgrst, 'reload schema';
