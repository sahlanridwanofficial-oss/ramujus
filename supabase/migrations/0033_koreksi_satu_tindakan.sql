-- ============================================================
-- 0033 — Koreksi nota jadi satu tindakan, dan pasangannya tercatat
--
-- 0029 membuat belanja hanya bisa ditambah; koreksi ditulis sebagai baris
-- bernilai negatif. Aturannya benar dan tetap. Yang salah adalah
-- akibatnya di layar, dan pemakainya menabraknya pada nota pertama yang
-- salah ketik:
--
--     Mangga  15 Sep   360 g   Rp20.000     <- salah
--     Mangga  15 Sep   500 g   Rp20.000     <- benar
--     Mangga  15 Sep  -360 g  -Rp20.000     <- pembatal
--
-- Nettonya 500 g, dan itu benar. Tapi yang terbaca adalah angka dobel
-- dengan yang lama masih nangkring di situ. Buku besar yang jujur tapi
-- tidak terbaca sama saja dengan tidak jujur: yang membacanya berhenti
-- mempercayainya.
--
-- Dua sebabnya, dan keduanya diperbaiki di sini.
--
-- ------------------------------------------------------------
-- 1. PASANGANNYA TIDAK PERNAH TERCATAT
--
-- Baris pembatal tidak menunjuk baris mana yang dibatalkannya. Layar
-- hanya bisa menebak dari kesamaan angka, dan tebakan itu salah begitu
-- ada dua nota kembar pada hari yang sama. membatalkan_id membuat
-- pasangannya jadi fakta, bukan tebakan — sehingga layar bisa melipat
-- keduanya dan menampilkan yang benar-benar berlaku saja.
--
-- ------------------------------------------------------------
-- 2. KOREKSI MEMBUTUHKAN DUA LANGKAH TERPISAH
--
-- Membatalkan dulu, lalu mengetik ulang, adalah dua kali menekan simpan
-- untuk satu peristiwa yang di kepala pemakainya cuma "saya salah
-- ketik". Di antara keduanya, angkanya sempat salah. Dan bila langkah
-- kedua terlupa, yang tertinggal adalah stok yang hilang tanpa
-- penggantinya.
--
-- admin_perbaiki_belanja menulis keduanya dalam satu panggilan: baris
-- pembatal yang menunjuk aslinya, lalu baris penggantinya. Satu tekan,
-- satu peristiwa, dan buku besarnya tetap hanya-tambah.
-- ============================================================

-- ------------------------------------------------------------
-- Penunjuk pasangan
-- ------------------------------------------------------------
ALTER TABLE public.belanja
  ADD COLUMN IF NOT EXISTS membatalkan_id UUID REFERENCES public.belanja(id);

COMMENT ON COLUMN public.belanja.membatalkan_id IS
  'Diisi pada baris PEMBATAL, menunjuk baris yang dibatalkannya. '
  'Membuat pasangannya jadi fakta alih-alih tebakan dari kesamaan angka, '
  'sehingga layar bisa melipat keduanya.';

-- Satu nota hanya boleh dibatalkan sekali. Dua pembatal untuk satu nota
-- akan mengurangi stok dua kali dari satu peristiwa.
CREATE UNIQUE INDEX IF NOT EXISTS belanja_satu_pembatalan
  ON public.belanja (membatalkan_id) WHERE membatalkan_id IS NOT NULL;

-- ------------------------------------------------------------
-- Memperbaiki nota: batalkan dan ganti, sekaligus
--
-- p_jumlah NULL berarti pembatalan murni — nota itu memang tidak pernah
-- terjadi, bukan salah angka.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_perbaiki_belanja(
  p_belanja_id   UUID,
  p_jumlah       NUMERIC DEFAULT NULL,
  p_total_rupiah NUMERIC DEFAULT NULL,
  p_jumlah_beli  NUMERIC DEFAULT NULL,
  p_catatan      TEXT    DEFAULT NULL
)
RETURNS public.belanja
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_asli   public.belanja;
  v_batal  public.belanja;
  v_baru   public.belanja;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_asli FROM public.belanja WHERE id = p_belanja_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOTA_NOT_FOUND' USING ERRCODE = '22023';
  END IF;

  -- Baris pembatal tidak bisa dibatalkan lagi: dua baris berlawanan sudah
  -- saling meniadakan, dan membatalkan pembatalan hanya menambah baris
  -- tanpa menambah keterangan.
  IF v_asli.membatalkan_id IS NOT NULL THEN
    RAISE EXCEPTION 'NOTA_ADALAH_PEMBATAL' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (SELECT 1 FROM public.belanja WHERE membatalkan_id = p_belanja_id) THEN
    RAISE EXCEPTION 'NOTA_SUDAH_DIBATALKAN' USING ERRCODE = '22023';
  END IF;

  IF p_jumlah_beli IS NOT NULL AND p_jumlah IS NOT NULL
     AND p_jumlah > p_jumlah_beli THEN
    RAISE EXCEPTION 'DAGING_LEBIH_BERAT_DARI_BELI' USING ERRCODE = '22023';
  END IF;

  -- Pembatal memakai TANGGAL ASLINYA, bukan hari ini. Dibatalkan pada
  -- tanggal lain, hari asalnya tetap menyimpan harga yang salah dan
  -- harga_bahan_pada() untuk hari itu tetap keliru.
  INSERT INTO public.belanja
    (tanggal, bahan_id, jumlah, jumlah_beli, total_rupiah, catatan,
     dicatat_oleh, membatalkan_id)
  VALUES
    (v_asli.tanggal, v_asli.bahan_id, -v_asli.jumlah, NULL, -v_asli.total_rupiah,
     COALESCE(p_catatan, 'Koreksi nota'), auth.uid(), v_asli.id)
  RETURNING * INTO v_batal;

  IF p_jumlah IS NULL THEN
    RETURN v_batal;
  END IF;

  INSERT INTO public.belanja
    (tanggal, bahan_id, jumlah, jumlah_beli, total_rupiah, catatan, dicatat_oleh)
  VALUES
    (v_asli.tanggal, v_asli.bahan_id, p_jumlah, p_jumlah_beli,
     COALESCE(p_total_rupiah, v_asli.total_rupiah), p_catatan, auth.uid())
  RETURNING * INTO v_baru;

  RETURN v_baru;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_perbaiki_belanja(UUID, NUMERIC, NUMERIC, NUMERIC, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_perbaiki_belanja(UUID, NUMERIC, NUMERIC, NUMERIC, TEXT)
  TO authenticated;

-- ------------------------------------------------------------
-- Riwayat menyebut apa yang masih berlaku
--
-- Tiga keadaan yang selama ini tampak sama di layar:
--
--   berlaku      — nota biasa, angkanya masih dipakai
--   dibatalkan   — ada pembatalnya; angkanya sudah tidak berlaku
--   pembatal     — baris yang membatalkan; ia mekanismenya, bukan
--                  peristiwanya, jadi layar boleh melipatnya
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_riwayat_belanja(DATE, DATE, UUID);

CREATE OR REPLACE FUNCTION public.admin_riwayat_belanja(
  p_dari     DATE,
  p_sampai   DATE,
  p_bahan_id UUID DEFAULT NULL
)
RETURNS TABLE (
  id             UUID,
  tanggal        DATE,
  bahan_id       UUID,
  nama           TEXT,
  satuan         TEXT,
  jumlah         NUMERIC,
  jumlah_beli    NUMERIC,
  total_rupiah   NUMERIC,
  harga_satuan   NUMERIC,
  rendemen       NUMERIC,
  catatan        TEXT,
  keadaan        TEXT,
  membatalkan_id UUID
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
  SELECT bl.id,
         bl.tanggal,
         bl.bahan_id,
         b.nama,
         b.satuan,
         bl.jumlah,
         bl.jumlah_beli,
         bl.total_rupiah,
         CASE WHEN bl.jumlah <> 0
              THEN ROUND(bl.total_rupiah / bl.jumlah, 2) END,
         CASE WHEN bl.jumlah_beli > 0
              THEN ROUND(bl.jumlah / bl.jumlah_beli, 4) END,
         bl.catatan,
         CASE
           WHEN bl.membatalkan_id IS NOT NULL THEN 'pembatal'
           WHEN EXISTS (SELECT 1 FROM public.belanja x
                         WHERE x.membatalkan_id = bl.id) THEN 'dibatalkan'
           ELSE 'berlaku'
         END,
         bl.membatalkan_id
    FROM public.belanja bl
    JOIN public.bahan b ON b.id = bl.bahan_id
   WHERE bl.tanggal >= p_dari
     AND bl.tanggal <= p_sampai
     AND (p_bahan_id IS NULL OR bl.bahan_id = p_bahan_id)
   ORDER BY bl.tanggal DESC, bl.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_riwayat_belanja(DATE, DATE, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_riwayat_belanja(DATE, DATE, UUID) TO authenticated;

-- ------------------------------------------------------------
-- Menyambungkan pasangan yang terlanjur dibuat tanpa penunjuk
--
-- Baris pembatal yang dibuat sebelum migrasi ini tidak menunjuk apa pun,
-- jadi layar tidak bisa melipatnya dan pemakainya melihat angka yang
-- tampak dobel. Pasangannya disambungkan di sini, dan HANYA bila
-- pasangannya tidak mungkin keliru: bahan sama, tanggal sama, jumlah dan
-- rupiahnya kebalikan persis, dan belum ada pembatal lain untuknya.
--
-- Yang ambigu sengaja dibiarkan: menyambungkan pasangan yang salah lebih
-- buruk daripada membiarkannya tampak terpisah.
-- ------------------------------------------------------------
DO $$
DECLARE
  v_pembatal RECORD;
  v_asli     UUID;
  v_n        INTEGER := 0;
BEGIN
  FOR v_pembatal IN
    SELECT * FROM public.belanja
     WHERE membatalkan_id IS NULL AND (jumlah < 0 OR total_rupiah < 0)
     ORDER BY created_at
  LOOP
    SELECT a.id INTO v_asli
      FROM public.belanja a
     WHERE a.bahan_id     = v_pembatal.bahan_id
       AND a.tanggal      = v_pembatal.tanggal
       AND a.jumlah       = -v_pembatal.jumlah
       AND a.total_rupiah = -v_pembatal.total_rupiah
       AND a.created_at   < v_pembatal.created_at
       AND a.membatalkan_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.belanja x WHERE x.membatalkan_id = a.id)
     ORDER BY a.created_at
     LIMIT 1;

    IF v_asli IS NOT NULL THEN
      UPDATE public.belanja SET membatalkan_id = v_asli WHERE id = v_pembatal.id;
      v_n := v_n + 1;
    END IF;
    v_asli := NULL;
  END LOOP;

  RAISE NOTICE '0033: % pasangan pembatalan lama disambungkan', v_n;
END;
$$;

NOTIFY pgrst, 'reload schema';
