-- ============================================================
-- 0029 — Belanja bahan masuk stok, dan harganya punya riwayat
--
-- Sampai sekarang margin RAMU adalah satu angka yang diketik tangan:
--
--     MARGIN_PER_CUP = 5000        (src/lib/constants.ts)
--
-- Dari angka itu turun titik impas 20 cup/hari, ambang gerobak 2,0
-- cup/jam, dan ambang ruko 4,4 cup/jam — tiga angka yang dipakai
-- memutuskan apakah sebuah titik layak disewa. Dua di antaranya bahkan
-- memakai asumsi margin yang BERBEDA (Rp5.000 dan Rp6.500) untuk menilai
-- titik yang sama di peta yang sama.
--
-- Berkas ini memasang sumber angka yang sebenarnya: nota belanja.
--
-- ------------------------------------------------------------
-- SATUANNYA BERAT DAGING, BUKAN BERAT BELI
--
-- Rancangan pertama menyimpan harga per gram buah UTUH lalu membaginya
-- dengan rendemen (pisang ±65%, nanas ±50%) untuk mendapat harga daging.
-- Itu dibatalkan: rendemen adalah tebakan yang dipasang sekali lalu
-- dipakai berbulan-bulan, padahal ia bergerak mengikuti ukuran buah,
-- musim, dan supplier.
--
-- Yang dipakai sekarang: buah dikupas dulu, dagingnya ditimbang, dan
-- ANGKA ITU yang masuk. Rendemen tidak pernah ada sebagai kolom — ia
-- terukur sendiri pada setiap belanja. Buah jelek minggu ini langsung
-- muncul sebagai harga per gram yang lebih tinggi, tanpa ada yang perlu
-- menyadarinya lebih dulu.
--
-- Penimbangan itu juga bukan kerja tambahan: freezer berisi daging,
-- bukan buah utuh, jadi hitung stok nanti menimbang daging juga.
--
-- ------------------------------------------------------------
-- BERAT BELI TETAP DICATAT, DAN GUNANYA SATU
--
-- jumlah_beli boleh kosong dan tidak pernah dipakai menghitung biaya.
-- Ia ada untuk memisahkan dua sebab kenaikan yang obatnya berbeda:
--
--     harga per kg naik      -> harga pasar, tidak bisa diapa-apakan
--     daging per kg turun    -> buahnya makin jelek, ganti supplier
--
-- Supplier yang menjual Rp18.000/kg dengan daging 550 g lebih MAHAL
-- daripada yang Rp20.000/kg dengan daging 650 g — Rp32,7 lawan Rp30,8
-- per gram. Notanya berkata sebaliknya. Tanpa jumlah_beli, selisih itu
-- terlihat sebagai kenaikan harga yang tidak bisa dijelaskan.
--
-- ------------------------------------------------------------
-- TIDAK ADA BARIS YANG PERNAH DITIMPA
--
-- belanja hanya bisa ditambah. Nota yang salah dikoreksi dengan baris
-- bernilai negatif, bukan dengan mengedit baris lama. Sebabnya bukan
-- kerapian: seluruh nilai berkas ini ada pada riwayat harga yang
-- terbentuk sendiri dari baris-baris bertanggal. Riwayat yang bisa
-- berubah surut setiap kali ada koreksi tidak bisa dipakai memutuskan
-- apa pun.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Bahan
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.bahan (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nama       TEXT NOT NULL UNIQUE,
  -- Satuan pakai, bukan satuan beli. Untuk buah: gram daging.
  satuan     TEXT NOT NULL CHECK (satuan IN ('gram', 'ml', 'pcs')),
  -- Bahan yang berhenti dipakai disembunyikan, tidak dihapus: belanjanya
  -- sudah terlanjur jadi bagian dari riwayat harga.
  aktif      BOOLEAN NOT NULL DEFAULT true,
  catatan    TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.bahan IS
  'Bahan baku. Satuannya satuan PAKAI (gram daging, ml, pcs), bukan '
  'satuan beli — lihat komentar kepala 0029.';

-- ------------------------------------------------------------
-- 2. Belanja — sekaligus pemasukan stok
--
-- Tidak ada langkah "catat belanja" lalu "input stok" terpisah. Satu
-- baris di sini menambah stok dan menggeser harga rata-ratanya
-- sekaligus, karena keduanya memang satu kejadian yang sama.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.belanja (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tanggal      DATE NOT NULL,
  bahan_id     UUID NOT NULL REFERENCES public.bahan(id),
  -- Yang benar-benar masuk freezer, dalam satuan bahan. Untuk buah:
  -- berat daging setelah dikupas. Boleh negatif — itu baris koreksi.
  jumlah       NUMERIC NOT NULL,
  -- Berat kotor sebelum dikupas. Boleh kosong; tidak pernah dipakai
  -- menghitung biaya, hanya untuk memisahkan sebab kenaikan.
  jumlah_beli  NUMERIC CHECK (jumlah_beli IS NULL OR jumlah_beli > 0),
  total_rupiah NUMERIC NOT NULL,
  catatan      TEXT,
  dicatat_oleh UUID REFERENCES auth.users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Baris yang tidak mengubah apa pun tidak boleh ada: ia cuma bikin
  -- riwayat berisik tanpa menambah keterangan.
  CONSTRAINT belanja_bukan_baris_kosong
    CHECK (jumlah <> 0 OR total_rupiah <> 0)
);

CREATE INDEX IF NOT EXISTS belanja_tanggal_idx ON public.belanja (tanggal DESC);
CREATE INDEX IF NOT EXISTS belanja_bahan_tanggal_idx ON public.belanja (bahan_id, tanggal DESC);

COMMENT ON COLUMN public.belanja.jumlah IS
  'Yang masuk stok, dalam satuan PAKAI. Untuk buah: berat daging setelah '
  'dikupas — bukan berat beli. Negatif berarti baris koreksi.';
COMMENT ON COLUMN public.belanja.jumlah_beli IS
  'Berat kotor sebelum dikupas. Opsional, tidak dipakai menghitung biaya. '
  'jumlah / jumlah_beli = rendemen nyata belanja itu, satu-satunya cara '
  'membedakan "harga naik" dari "buahnya makin jelek".';

-- ------------------------------------------------------------
-- 3. RLS — hanya admin, dan hanya boleh menambah
--
-- Sengaja TIDAK ada kebijakan UPDATE maupun DELETE. Tanpa kebijakan,
-- PostgREST menolak keduanya. Koreksi ditulis sebagai baris negatif;
-- riwayat harga tidak boleh bisa diubah surut dari aplikasi.
-- ------------------------------------------------------------
ALTER TABLE public.bahan   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.belanja ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin membaca bahan"   ON public.bahan;
DROP POLICY IF EXISTS "Admin menulis bahan"   ON public.bahan;
DROP POLICY IF EXISTS "Admin mengubah bahan"  ON public.bahan;
DROP POLICY IF EXISTS "Admin membaca belanja" ON public.belanja;
DROP POLICY IF EXISTS "Admin menambah belanja" ON public.belanja;

CREATE POLICY "Admin membaca bahan" ON public.bahan
  FOR SELECT TO authenticated
  USING (public.get_user_role(auth.uid()) = 'admin');

CREATE POLICY "Admin menulis bahan" ON public.bahan
  FOR INSERT TO authenticated
  WITH CHECK (public.get_user_role(auth.uid()) = 'admin');

-- Bahan boleh diubah (ganti nama, dinonaktifkan) — yang tidak boleh
-- diubah adalah belanjanya.
CREATE POLICY "Admin mengubah bahan" ON public.bahan
  FOR UPDATE TO authenticated
  USING (public.get_user_role(auth.uid()) = 'admin')
  WITH CHECK (public.get_user_role(auth.uid()) = 'admin');

CREATE POLICY "Admin membaca belanja" ON public.belanja
  FOR SELECT TO authenticated
  USING (public.get_user_role(auth.uid()) = 'admin');

CREATE POLICY "Admin menambah belanja" ON public.belanja
  FOR INSERT TO authenticated
  WITH CHECK (public.get_user_role(auth.uid()) = 'admin');

-- ------------------------------------------------------------
-- 4. Mencatat belanja
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_catat_belanja(
  p_bahan_id     UUID,
  p_tanggal      DATE,
  p_jumlah       NUMERIC,
  p_total_rupiah NUMERIC,
  p_jumlah_beli  NUMERIC DEFAULT NULL,
  p_catatan      TEXT    DEFAULT NULL
)
RETURNS public.belanja
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.belanja;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  PERFORM 1 FROM public.bahan WHERE id = p_bahan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'BAHAN_NOT_FOUND' USING ERRCODE = '22023';
  END IF;

  IF p_tanggal IS NULL OR p_tanggal > (NOW() AT TIME ZONE 'Asia/Jakarta')::date THEN
    RAISE EXCEPTION 'TANGGAL_DI_MASA_DEPAN' USING ERRCODE = '22023';
  END IF;

  -- Daging tidak mungkin lebih berat daripada buah utuhnya. Kalau ini
  -- terjadi, salah satu angkanya salah ketik — dan diterima diam-diam ia
  -- akan muncul sebagai rendemen di atas 100% yang tidak berarti apa-apa.
  IF p_jumlah_beli IS NOT NULL AND p_jumlah > p_jumlah_beli THEN
    RAISE EXCEPTION 'DAGING_LEBIH_BERAT_DARI_BELI' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.belanja
    (tanggal, bahan_id, jumlah, jumlah_beli, total_rupiah, catatan, dicatat_oleh)
  VALUES
    (p_tanggal, p_bahan_id, p_jumlah, p_jumlah_beli, p_total_rupiah, p_catatan, auth.uid())
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_catat_belanja(UUID, DATE, NUMERIC, NUMERIC, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_catat_belanja(UUID, DATE, NUMERIC, NUMERIC, NUMERIC, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 5. Keadaan tiap bahan sekarang
--
-- Dua harga, dan keduanya dilaporkan terpisah karena pekerjaannya
-- berbeda:
--
--   harga_terakhir  — dari nota paling baru. Dipakai untuk KEPUTUSAN
--                     HARGA JUAL: tiap cup yang terjual hari ini harus
--                     diganti besok di harga hari ini.
--   harga_rata      — rata-rata tertimbang belanja dalam jendela
--                     terakhir. Dipakai untuk LAPORAN bulan yang sudah
--                     lewat.
--
-- Catatan jujur soal harga_rata: selama fase 3 (hitung stok) belum ada,
-- ini rata-rata BELANJA pada jendela waktu, bukan penilaian stok yang
-- benar-benar ada di freezer. Keduanya berdekatan selama stok berputar
-- cepat, dan berbeda begitu stok menumpuk. Namanya disebut apa adanya
-- di layar supaya tidak dikira lebih dari itu.
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
         -- Rata-rata tertimbang: jumlah rupiah dibagi jumlah satuan, bukan
         -- rata-rata dari harga per baris. Belanja 10 kg dan belanja 1 kg
         -- tidak boleh berbobot sama.
         CASE WHEN COALESCE(j.jumlah, 0) > 0
              THEN ROUND(j.rupiah / j.jumlah, 2) END,
         COALESCE(j.jumlah, 0),
         COALESCE(j.rupiah, 0),
         COALESCE(s.jumlah, 0),
         COALESCE(s.rupiah, 0),
         COALESCE(s.baris, 0)::INTEGER
    FROM public.bahan b
    LEFT JOIN LATERAL (
      -- Nota terbaru yang benar-benar menambah barang. Baris koreksi
      -- (jumlah <= 0) dilewati: ia mengoreksi angka, bukan menetapkan
      -- harga beli baru.
      SELECT ROUND(bl.total_rupiah / bl.jumlah, 2) AS harga_terakhir,
             bl.tanggal                            AS tanggal_terakhir,
             CASE WHEN bl.jumlah_beli > 0
                  THEN ROUND(bl.jumlah / bl.jumlah_beli, 4) END AS rendemen_terakhir
        FROM public.belanja bl
       WHERE bl.bahan_id = b.id AND bl.jumlah > 0
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

-- ------------------------------------------------------------
-- 6. Riwayat belanja — riwayat harga terbentuk sendiri dari sini
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_riwayat_belanja(
  p_dari     DATE,
  p_sampai   DATE,
  p_bahan_id UUID DEFAULT NULL
)
RETURNS TABLE (
  id            UUID,
  tanggal       DATE,
  bahan_id      UUID,
  nama          TEXT,
  satuan        TEXT,
  jumlah        NUMERIC,
  jumlah_beli   NUMERIC,
  total_rupiah  NUMERIC,
  harga_satuan  NUMERIC,
  rendemen      NUMERIC,
  catatan       TEXT,
  koreksi       BOOLEAN
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
         (bl.jumlah < 0 OR bl.total_rupiah < 0)
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
-- 7. Biaya bahan per cup — angka yang menggantikan tebakan Rp5.000
--
-- Belanja dibagi cup terjual pada rentang yang sama. Di dalamnya sudah
-- termasuk kulit, bonggol, buah busuk, tumpah, dan harga yang sedang
-- mahal — semuanya, tanpa satu pun tebakan, karena semuanya memang
-- sudah dibayar.
--
-- KELENGKAPAN DILAPORKAN, BUKAN DITEBAK.
--
-- Godaan besarnya adalah memasang ambang: "kalau biaya per cup di bawah
-- Rp sekian, berarti notanya belum lengkap." Ambang seperti itu adalah
-- angka karangan lain yang menggantikan angka karangan yang sedang
-- dicabut. Yang dilaporkan di sini adalah fakta yang bisa diperiksa:
-- berapa MINGGU dalam rentang ini yang punya catatan belanja, dari
-- berapa minggu seluruhnya.
--
-- Nol nota selama dua minggu sementara gerobak jalan tiap hari bukan
-- berarti bahannya gratis. Layar yang memakai angka ini wajib menolak
-- memakainya sebagai dasar titik impas selama lengkap = false.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_biaya_bahan_per_cup(
  p_dari   DATE,
  p_sampai DATE
)
RETURNS TABLE (
  belanja_rupiah  NUMERIC,
  cup             INTEGER,
  biaya_per_cup   NUMERIC,
  minggu_ada      INTEGER,
  minggu_total    INTEGER,
  lengkap         BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rupiah NUMERIC;
  v_cup    INTEGER;
  v_ada    INTEGER;
  v_total  INTEGER;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(sum(bl.total_rupiah), 0) INTO v_rupiah
    FROM public.belanja bl
   WHERE bl.tanggal >= p_dari AND bl.tanggal <= p_sampai;

  SELECT COALESCE(sum(public.order_cup_count(o.id)), 0)::INTEGER INTO v_cup
    FROM public.orders o
   WHERE o.created_at >= public.wib_day_start(p_dari)
     AND o.created_at <  public.wib_day_start(p_sampai + 1);

  -- Minggu yang punya PENJUALAN dibanding minggu yang punya BELANJA.
  -- Pembandingnya penjualan, bukan kalender: minggu gerobak libur
  -- memang tidak perlu ada notanya.
  SELECT count(*)::INTEGER INTO v_total
    FROM (
      SELECT DISTINCT date_trunc('week', (o.created_at AT TIME ZONE 'Asia/Jakarta')::date)
        FROM public.orders o
       WHERE o.created_at >= public.wib_day_start(p_dari)
         AND o.created_at <  public.wib_day_start(p_sampai + 1)
    ) m;

  SELECT count(*)::INTEGER INTO v_ada
    FROM (
      SELECT DISTINCT date_trunc('week', bl.tanggal)
        FROM public.belanja bl
       WHERE bl.tanggal >= p_dari AND bl.tanggal <= p_sampai
    ) m;

  RETURN QUERY SELECT
    v_rupiah,
    v_cup,
    CASE WHEN v_cup > 0 THEN ROUND(v_rupiah / v_cup, 2) END,
    v_ada,
    v_total,
    (v_total > 0 AND v_ada >= v_total);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_biaya_bahan_per_cup(DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_biaya_bahan_per_cup(DATE, DATE) TO authenticated;

NOTIFY pgrst, 'reload schema';
