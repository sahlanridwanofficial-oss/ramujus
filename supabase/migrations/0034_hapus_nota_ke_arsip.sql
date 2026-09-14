-- ============================================================
-- 0034 — Nota salah bisa dihapus, dan yang dibatalkan berhenti
--        menyetir harga
--
-- Dua hal, ditemukan dari satu keluhan yang sama: "kalau tidak dihapus,
-- itu masuk ke perhitungan."
--
-- ------------------------------------------------------------
-- 1. BUG: BARIS YANG DIBATALKAN MASIH MENYETIR "HARGA TERAKHIR"
--
-- harga_bahan_pada() dan admin_bahan_ringkas() memilih harga terakhir
-- dengan satu-satunya saringan "jumlah > 0". Baris yang sudah dibatalkan
-- lolos saringan itu.
--
-- Akibatnya: batalkan nota terbaru tanpa menggantinya, dan harga bahan
-- itu TETAP diambil dari nota yang barusan dibatalkan. Angka yang sudah
-- dinyatakan salah tetap dipakai memutuskan harga jual.
--
-- Belum menggigit di data produksi hanya karena kebetulan — nota terbaru
-- untuk tiap bahan kebetulan yang masih berlaku. Kebetulan bukan jaminan.
--
-- ------------------------------------------------------------
-- 2. NOTA SALAH TIDAK PUNYA JALAN KELUAR YANG BERSIH
--
-- Pembatalan menetralkan angkanya, dan itu cukup untuk jumlah dan
-- rata-rata. Tapi yang salah ketik sejak awal — nota yang memang tidak
-- pernah ada peristiwanya — meninggalkan dua baris di layar untuk
-- sesuatu yang seharusnya nol baris. Yang membacanya harus menahan
-- pasangan itu di kepala setiap kali.
--
-- Lebih buruk lagi kalau pembatalannya sempat terlepas dari pasangannya,
-- seperti yang terjadi pada nota Mangga: satu baris negatif tanpa
-- pasangan, yang BENAR-BENAR masuk perhitungan dan membuat rupiahnya
-- jadi nol.
--
-- ------------------------------------------------------------
-- HAPUS = PINDAH KE ARSIP, BUKAN LENYAP
--
-- Menghapus baris begitu saja akan membuat riwayat harga bisa berubah
-- surut — persis yang dijaga 0029 sejak awal. Jadi menghapus di sini
-- berarti MEMINDAHKAN barisnya ke belanja_terhapus, lengkap dengan siapa
-- yang menghapus, kapan, dan alasannya.
--
-- Layar jadi bersih, buktinya tidak hilang. Dua kebutuhan yang selama
-- ini dianggap bertentangan, padahal cuma butuh dua tabel.
--
-- Pasangan dihapus bersama-sama. Menghapus nota tanpa pembatalnya
-- meninggalkan baris negatif yatim yang justru menambah kekacauan —
-- kejadian Mangga persis begitu.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Arsip
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.belanja_terhapus (
  id             UUID PRIMARY KEY,
  tanggal        DATE NOT NULL,
  bahan_id       UUID NOT NULL REFERENCES public.bahan(id),
  jumlah         NUMERIC NOT NULL,
  jumlah_beli    NUMERIC,
  total_rupiah   NUMERIC NOT NULL,
  catatan        TEXT,
  dicatat_oleh   UUID,
  dicatat_pada   TIMESTAMPTZ NOT NULL,
  membatalkan_id UUID,
  alasan         TEXT,
  dihapus_oleh   UUID REFERENCES auth.users(id),
  dihapus_pada   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.belanja_terhapus IS
  'Nota yang dihapus dari riwayat. Menghapus di aplikasi ini berarti '
  'memindahkan, bukan melenyapkan: layar jadi bersih tanpa membuat '
  'riwayat harga bisa berubah surut tanpa bekas.';

ALTER TABLE public.belanja_terhapus ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin membaca nota terhapus" ON public.belanja_terhapus;
CREATE POLICY "Admin membaca nota terhapus" ON public.belanja_terhapus
  FOR SELECT TO authenticated
  USING (public.get_user_role(auth.uid()) = 'admin');

-- Tidak ada kebijakan INSERT/UPDATE/DELETE: arsipnya hanya diisi
-- admin_hapus_belanja(), dan tidak bisa dikosongkan dari aplikasi.

-- ------------------------------------------------------------
-- 2. Menghapus nota — beserta pasangannya
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_hapus_belanja(
  p_belanja_id UUID,
  p_alasan     TEXT DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ids UUID[];
  v_n   INTEGER;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  -- Satu peristiwa bisa berupa satu atau dua baris. Keduanya ikut, dari
  -- arah mana pun penghapusan dimulai: menghapus nota tanpa pembatalnya
  -- meninggalkan baris negatif yatim yang benar-benar masuk perhitungan,
  -- dan menghapus pembatal tanpa notanya menghidupkan kembali angka yang
  -- sudah dinyatakan salah.
  SELECT array_agg(x.id) INTO v_ids
    FROM public.belanja x
   WHERE x.id = p_belanja_id
      OR x.membatalkan_id = p_belanja_id
      OR x.id = (SELECT y.membatalkan_id FROM public.belanja y WHERE y.id = p_belanja_id);

  IF v_ids IS NULL OR array_length(v_ids, 1) = 0 THEN
    RAISE EXCEPTION 'NOTA_NOT_FOUND' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.belanja_terhapus
    (id, tanggal, bahan_id, jumlah, jumlah_beli, total_rupiah, catatan,
     dicatat_oleh, dicatat_pada, membatalkan_id, alasan, dihapus_oleh)
  SELECT bl.id, bl.tanggal, bl.bahan_id, bl.jumlah, bl.jumlah_beli,
         bl.total_rupiah, bl.catatan, bl.dicatat_oleh, bl.created_at,
         bl.membatalkan_id, p_alasan, auth.uid()
    FROM public.belanja bl
   WHERE bl.id = ANY(v_ids)
  ON CONFLICT (id) DO NOTHING;

  -- Penunjuk dilepas dulu supaya kunci asing tidak menghalangi urutan
  -- penghapusan di dalam satu pasangan.
  UPDATE public.belanja SET membatalkan_id = NULL WHERE id = ANY(v_ids);
  DELETE FROM public.belanja WHERE id = ANY(v_ids);

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_hapus_belanja(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_hapus_belanja(UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 3. Harga terakhir berhenti membaca nota yang sudah dibatalkan
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.harga_bahan_pada(
  p_tanggal DATE,
  p_dasar   TEXT DEFAULT 'terakhir'
)
RETURNS TABLE (bahan_id UUID, harga NUMERIC)
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT b.id,
         COALESCE(
           CASE
             WHEN p_dasar = 'rata' THEN
               -- Rata-rata menjumlahkan semuanya, termasuk baris pembatal
               -- yang bernilai negatif — pasangannya memang saling
               -- meniadakan, jadi tidak perlu disaring.
               (SELECT CASE WHEN sum(bl.jumlah) > 0
                            THEN sum(bl.total_rupiah) / sum(bl.jumlah) END
                  FROM public.belanja bl
                 WHERE bl.bahan_id = b.id
                   AND bl.tanggal <= p_tanggal
                   AND bl.tanggal >  p_tanggal - 30)
             ELSE
               (SELECT bl.total_rupiah / bl.jumlah
                  FROM public.belanja bl
                 WHERE bl.bahan_id = b.id
                   AND bl.jumlah > 0
                   AND bl.tanggal <= p_tanggal
                   -- Nota yang sudah dibatalkan tidak boleh menetapkan
                   -- harga: angka yang sudah dinyatakan salah tidak boleh
                   -- dipakai memutuskan harga jual.
                   AND NOT EXISTS (SELECT 1 FROM public.belanja x
                                    WHERE x.membatalkan_id = bl.id)
                 ORDER BY bl.tanggal DESC, bl.created_at DESC
                 LIMIT 1)
           END,
           (SELECT bl.total_rupiah / bl.jumlah
              FROM public.belanja bl
             WHERE bl.bahan_id = b.id
               AND bl.jumlah > 0
               AND NOT EXISTS (SELECT 1 FROM public.belanja x
                                WHERE x.membatalkan_id = bl.id)
             ORDER BY bl.tanggal ASC, bl.created_at ASC
             LIMIT 1)
         )
    FROM public.bahan b;
$$;

-- ------------------------------------------------------------
-- 4. Ringkasan bahan ikut berhenti membacanya
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_bahan_ringkas(
  p_jendela_hari INTEGER DEFAULT 30
)
RETURNS TABLE (
  bahan_id          UUID,
  nama              TEXT,
  satuan            TEXT,
  aktif             BOOLEAN,
  harga_terakhir    NUMERIC,
  tanggal_terakhir  DATE,
  rendemen_terakhir NUMERIC,
  harga_rata        NUMERIC,
  jumlah_jendela    NUMERIC,
  rupiah_jendela    NUMERIC,
  stok_masuk_total  NUMERIC,
  nilai_masuk_total NUMERIC,
  jumlah_belanja    INTEGER
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT b.id,
         b.nama,
         b.satuan,
         b.aktif,
         t.harga_terakhir,
         t.tanggal_terakhir,
         t.rendemen_terakhir,
         CASE WHEN COALESCE(j.jumlah, 0) > 0
              THEN ROUND(j.rupiah / j.jumlah, 2) END,
         COALESCE(j.jumlah, 0),
         COALESCE(j.rupiah, 0),
         COALESCE(s.jumlah, 0),
         COALESCE(s.rupiah, 0),
         COALESCE(s.baris, 0)::INTEGER
    FROM public.bahan b
    LEFT JOIN LATERAL (
      -- Nota terbaru yang menambah barang DAN belum dibatalkan.
      SELECT ROUND(bl.total_rupiah / bl.jumlah, 2) AS harga_terakhir,
             bl.tanggal                            AS tanggal_terakhir,
             CASE WHEN bl.jumlah_beli > 0
                  THEN ROUND(bl.jumlah / bl.jumlah_beli, 4) END AS rendemen_terakhir
        FROM public.belanja bl
       WHERE bl.bahan_id = b.id
         AND bl.jumlah > 0
         AND NOT EXISTS (SELECT 1 FROM public.belanja x
                          WHERE x.membatalkan_id = bl.id)
       ORDER BY bl.tanggal DESC, bl.created_at DESC
       LIMIT 1
    ) t ON true
    LEFT JOIN LATERAL (
      SELECT sum(bl.jumlah)       AS jumlah,
             sum(bl.total_rupiah) AS rupiah
        FROM public.belanja bl
       WHERE bl.bahan_id = b.id
         AND bl.tanggal >= (NOW() AT TIME ZONE 'Asia/Jakarta')::date
                           - GREATEST(COALESCE(p_jendela_hari, 30), 1)
    ) j ON true
    LEFT JOIN LATERAL (
      SELECT sum(bl.jumlah)       AS jumlah,
             sum(bl.total_rupiah) AS rupiah,
             count(*)             AS baris
        FROM public.belanja bl
       WHERE bl.bahan_id = b.id
    ) s ON true
   ORDER BY b.aktif DESC, b.nama;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_bahan_ringkas(INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_bahan_ringkas(INTEGER) TO authenticated;

NOTIFY pgrst, 'reload schema';
