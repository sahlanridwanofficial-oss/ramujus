-- ============================================================
-- 0035 — Ekonomi terukur menggantikan margin yang diketik tangan
--
-- Sejak awal proyek ini, satu angka menyetir setiap vonis uang:
--
--     MARGIN_PER_CUP = 5000        (src/lib/constants.ts)
--
-- Dari situ turun titik impas 20 cup/hari, ambang gerobak 2,0 cup/jam,
-- dan ambang ruko 4,4 cup/jam — tiga angka yang dipakai memutuskan
-- apakah sebuah titik layak disewa dan apakah gerobak kedua masuk akal.
-- Dua di antaranya bahkan memakai asumsi margin yang BERBEDA (Rp5.000
-- dan Rp6.500) untuk menilai titik yang sama di peta yang sama.
--
-- 0029 sampai 0034 memasang bahannya: harga bahan dari nota, takaran per
-- menu, dan HPP yang dihitung pada hari cupnya terjual. Berkas ini
-- menyambungkannya ke vonis.
--
-- Laba kotor dari 133 cup yang benar-benar terjual: Rp809.829, atau
-- Rp6.089 per cup — 22% lebih besar daripada tebakan Rp5.000. Titik
-- impasnya ikut bergeser dari 20 cup/hari jadi ~15,8.
--
-- ------------------------------------------------------------
-- BIAYA TETAP PINDAH KE BASIS DATA
--
-- Selama biaya tetap cuma ada sebagai konstanta TypeScript, SQL tidak
-- bisa menghitung laba BERSIH — dan angka yang cuma bisa dihitung di
-- peramban tidak bisa diuji, tidak bisa dipakai laporan, dan diam-diam
-- berbeda antar layar.
--
-- Satu baris, satu tempat mengubahnya ketika gaji driver atau sewa
-- berubah. Itu justru yang dijanjikan komentar constants.ts sejak awal
-- tapi belum pernah benar-benar dipenuhi.
--
-- ------------------------------------------------------------
-- LABA KOTOR, BUKAN LABA BERSIH SEUTUHNYA
--
-- Yang dikurangkan dari omzet di sini baru biaya BAHAN menurut takaran.
-- Susut, tumpah, dan kelebihan tuang belum termasuk — itu pekerjaan
-- hitung stok bulanan. Jadi laba bersih yang dilaporkan selalu sedikit
-- lebih besar daripada kenyataan, dan arah kelebihannya disebutkan
-- terang-terangan di layar alih-alih disembunyikan.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Parameter ekonomi — satu baris, bisa diubah admin
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.parameter_ekonomi (
  -- Kunci boolean dengan CHECK: tabel ini hanya boleh punya satu baris.
  id                       BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),
  biaya_tetap_bulanan      NUMERIC NOT NULL CHECK (biaya_tetap_bulanan  > 0),
  hari_jualan_per_bulan    INTEGER NOT NULL CHECK (hari_jualan_per_bulan > 0),
  jam_mangkal_per_hari     NUMERIC NOT NULL CHECK (jam_mangkal_per_hari  > 0),
  biaya_tetap_ruko_bulanan NUMERIC NOT NULL CHECK (biaya_tetap_ruko_bulanan > 0),
  jam_buka_ruko_per_hari   NUMERIC NOT NULL CHECK (jam_buka_ruko_per_hari   > 0),
  catatan                  TEXT,
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by               UUID REFERENCES auth.users(id)
);

COMMENT ON TABLE public.parameter_ekonomi IS
  'Biaya tetap dan jam operasi. Satu baris saja. Dipindah dari konstanta '
  'TypeScript supaya laba bersih bisa dihitung di SQL — angka yang cuma '
  'bisa dihitung di peramban tidak bisa diuji dan diam-diam berbeda '
  'antar layar.';

INSERT INTO public.parameter_ekonomi
  (id, biaya_tetap_bulanan, hari_jualan_per_bulan, jam_mangkal_per_hari,
   biaya_tetap_ruko_bulanan, jam_buka_ruko_per_hari, catatan)
VALUES
  (true, 2500000, 26, 9.8, 6000000, 9,
   'Nilai awal dipindahkan dari src/lib/constants.ts dan komentar OpsAnalytics. '
   'Gerobak: gaji driver, basecamp, penyusutan. 26 hari — driver manusia butuh '
   'satu hari libur per pekan. 9,8 jam mangkal dari pengukuran nyata 12 Sep 2026.')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.parameter_ekonomi ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin membaca parameter ekonomi" ON public.parameter_ekonomi;
DROP POLICY IF EXISTS "Admin mengubah parameter ekonomi" ON public.parameter_ekonomi;

CREATE POLICY "Admin membaca parameter ekonomi" ON public.parameter_ekonomi
  FOR SELECT TO authenticated
  USING (public.get_user_role(auth.uid()) = 'admin');

CREATE POLICY "Admin mengubah parameter ekonomi" ON public.parameter_ekonomi
  FOR UPDATE TO authenticated
  USING (public.get_user_role(auth.uid()) = 'admin')
  WITH CHECK (public.get_user_role(auth.uid()) = 'admin');

-- Tidak ada kebijakan INSERT maupun DELETE: barisnya tepat satu, selamanya.

-- ------------------------------------------------------------
-- 2. Ekonomi terukur pada sebuah rentang
--
-- Semua yang selama ini ditebak, dihitung di satu tempat:
--
--   laba_per_cup   menggantikan MARGIN_PER_CUP
--   impas_per_hari menggantikan BREAK_EVEN_CUPS_PER_DAY
--   impas_gerobak  menggantikan GEROBAK_BREAK_EVEN_CUPS_PER_HOUR
--   impas_ruko     menggantikan RUKO_BREAK_EVEN_CUPS_PER_HOUR
--
-- Keduanya yang terakhir kini berasal dari margin yang SAMA. Sebelumnya
-- satu memakai Rp5.000 dan satunya Rp6.500 untuk menilai titik yang sama
-- di peta yang sama — selisih yang tidak pernah bisa dijelaskan.
--
-- Bila belum ada cup yang bisa dinilai, seluruhnya NULL. Layar yang
-- memanggilnya wajib jatuh ke konstanta lama dan mengatakannya, bukan
-- menampilkan nol.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_ekonomi_terkini(
  p_dari   DATE,
  p_sampai DATE,
  p_dasar  TEXT DEFAULT 'rata'
)
RETURNS TABLE (
  cup                INTEGER,
  cup_ternilai       INTEGER,
  omzet              BIGINT,
  biaya_bahan        NUMERIC,
  laba_kotor         NUMERIC,
  laba_per_cup       NUMERIC,
  hari_jualan        INTEGER,
  biaya_tetap        NUMERIC,
  laba_bersih        NUMERIC,
  impas_per_hari     NUMERIC,
  impas_gerobak_jam  NUMERIC,
  impas_ruko_jam     NUMERIC,
  harga_perkiraan    BOOLEAN,
  lengkap            BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_p            public.parameter_ekonomi;
  v_nota_pertama DATE;
  v_hari         INTEGER;
  v_cup          INTEGER;
  v_ternilai     INTEGER;
  v_omzet        BIGINT;
  v_biaya        NUMERIC;
  v_laba_cup     NUMERIC;
  v_tetap_hari   NUMERIC;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_p FROM public.parameter_ekonomi WHERE id;
  SELECT min(bl.tanggal) INTO v_nota_pertama FROM public.belanja bl;

  -- Hari jualan = hari yang benar-benar ada penjualannya, bukan panjang
  -- kalender rentangnya. Menagih biaya tetap pada hari gerobak libur akan
  -- membuat laba bersih tampak lebih buruk daripada kenyataannya.
  SELECT count(DISTINCT (o.created_at AT TIME ZONE 'Asia/Jakarta')::date)::INTEGER
    INTO v_hari
    FROM public.orders o
   WHERE o.created_at >= public.wib_day_start(p_dari)
     AND o.created_at <  public.wib_day_start(p_sampai + 1);

  SELECT t.cup, t.cup_ternilai, t.omzet, t.biaya_total
    INTO v_cup, v_ternilai, v_omzet, v_biaya
    FROM public.admin_biaya_per_cup_takaran(p_dari, p_sampai, p_dasar) t;

  IF COALESCE(v_ternilai, 0) = 0 THEN
    RETURN QUERY SELECT COALESCE(v_cup, 0), 0, COALESCE(v_omzet, 0)::BIGINT,
                        NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC,
                        COALESCE(v_hari, 0), NULL::NUMERIC, NULL::NUMERIC,
                        NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC,
                        false, false;
    RETURN;
  END IF;

  v_laba_cup   := (v_omzet - v_biaya) / v_ternilai;
  v_tetap_hari := v_p.biaya_tetap_bulanan / v_p.hari_jualan_per_bulan;

  RETURN QUERY SELECT
    v_cup,
    v_ternilai,
    v_omzet,
    ROUND(v_biaya, 2),
    ROUND(v_omzet - v_biaya, 2),
    ROUND(v_laba_cup, 2),
    v_hari,
    ROUND(v_tetap_hari * v_hari, 2),
    ROUND((v_omzet - v_biaya) - v_tetap_hari * v_hari, 2),
    -- Impas harian: biaya tetap sehari dibagi laba sebuah cup.
    ROUND(v_tetap_hari / v_laba_cup, 2),
    -- Ambang per jam: impas harian dibagi jam operasi. Gerobak dan ruko
    -- memakai margin yang SAMA; yang membedakan cuma biaya tetap dan jam
    -- bukanya.
    ROUND(v_tetap_hari / v_laba_cup / v_p.jam_mangkal_per_hari, 2),
    ROUND(v_p.biaya_tetap_ruko_bulanan / v_p.hari_jualan_per_bulan
          / v_laba_cup / v_p.jam_buka_ruko_per_hari, 2),
    (v_nota_pertama IS NOT NULL AND p_dari < v_nota_pertama),
    (v_cup > 0 AND v_ternilai = v_cup);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_ekonomi_terkini(DATE, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_ekonomi_terkini(DATE, DATE, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
