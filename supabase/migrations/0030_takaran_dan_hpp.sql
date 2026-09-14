-- ============================================================
-- 0030 — Takaran per menu, dan HPP yang dihitung darinya
--
-- 0029 memasang harga bahan yang terukur dari nota. Berkas ini memakainya
-- untuk menjawab pertanyaan yang sejak awal tidak pernah bisa dijawab:
-- menu mana yang tipis, dan kalau biayanya naik, naik karena bahan apa.
--
-- ------------------------------------------------------------
-- TAKARAN PER SATU CUP, DALAM SATUAN PAKAI
--
-- Angkanya datang dari resep kerja yang benar-benar dipakai, bukan dari
-- perhitungan mundur. Untuk buah, satuannya berat DAGING — sejalan
-- dengan 0029, sehingga tidak ada satu pun titik konversi di seluruh
-- rantai: nota masuk sebagai gram daging, resep memakai gram daging,
-- stok berkurang dalam gram daging.
--
-- Isi cup lima menu berkisar 330–345 g/ml. Selisih di bawah 5% itu
-- tanda takarannya angka kerja, bukan kira-kira.
--
-- ------------------------------------------------------------
-- TAKARAN BERVERSI, TIDAK PERNAH DITIMPA
--
-- Kunci utamanya (product_id, berlaku_dari, bahan_id). Resep yang
-- berubah ditulis sebagai versi baru bertanggal, bukan menimpa yang
-- lama. Sebabnya sama dengan belanja yang hanya bisa ditambah: HPP
-- Oktober harus tetap dihitung dengan resep yang berlaku di Oktober.
-- Resep yang bisa ditimpa membuat seluruh riwayat HPP berubah surut
-- setiap kali takaran disesuaikan sedikit.
--
-- ------------------------------------------------------------
-- BAHAN TANPA HARGA MEMBUAT HPP NULL, BUKAN NOL
--
-- Ini aturan yang paling gampang dilanggar dan paling mahal akibatnya.
-- Bahan yang belum pernah dibeli tidak punya harga. Kalau ketiadaan itu
-- dibaca sebagai nol, menu yang datanya paling tidak lengkap justru
-- tampil paling untung — persis pola yang dulu membuat dasbor
-- menampilkan "0 cup" padahal driver sudah jualan.
--
-- Jadi: satu bahan saja tanpa harga, seluruh HPP menu itu NULL, dan
-- nama bahannya ikut dikembalikan supaya layar bisa menyebut apa yang
-- kurang alih-alih menampilkan angka yang salah.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Takaran
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.takaran (
  product_id   UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  berlaku_dari DATE NOT NULL,
  bahan_id     UUID NOT NULL REFERENCES public.bahan(id),
  -- Untuk SATU cup, dalam satuan bahan.
  jumlah       NUMERIC NOT NULL CHECK (jumlah > 0),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (product_id, berlaku_dari, bahan_id)
);

CREATE INDEX IF NOT EXISTS takaran_produk_versi_idx
  ON public.takaran (product_id, berlaku_dari DESC);

COMMENT ON TABLE public.takaran IS
  'Resep per SATU cup, dalam satuan pakai (gram daging untuk buah). '
  'Berversi: resep yang berubah jadi baris bertanggal baru, tidak '
  'menimpa — supaya HPP bulan lalu tetap dihitung dengan resep bulan lalu.';

ALTER TABLE public.takaran ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin membaca takaran" ON public.takaran;
CREATE POLICY "Admin membaca takaran" ON public.takaran
  FOR SELECT TO authenticated
  USING (public.get_user_role(auth.uid()) = 'admin');

-- Tidak ada kebijakan INSERT/UPDATE/DELETE: perubahan hanya lewat
-- admin_simpan_takaran(), yang menjaga aturan versinya.

-- ------------------------------------------------------------
-- 2. Versi takaran yang berlaku pada sebuah tanggal
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.takaran_berlaku(
  p_product_id UUID,
  p_tanggal    DATE
)
RETURNS DATE
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT max(t.berlaku_dari)
    FROM public.takaran t
   WHERE t.product_id = p_product_id
     AND t.berlaku_dari <= p_tanggal;
$$;

-- ------------------------------------------------------------
-- 3. Harga tiap bahan pada sebuah tanggal
--
-- Dua dasar, dan keduanya tidak boleh tertukar:
--
--   'terakhir' — nota terbaru sampai tanggal itu. Untuk KEPUTUSAN HARGA
--                JUAL: cup yang terjual hari ini harus diganti besok di
--                harga hari ini.
--   'rata'     — rata-rata tertimbang 30 hari ke belakang. Untuk
--                LAPORAN bulan yang sudah lewat.
--
-- Bahan yang belum pernah dibeli tidak muncul. Yang memanggil wajib
-- memperlakukan ketiadaannya sebagai "tidak diketahui", bukan nol.
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
         CASE
           WHEN p_dasar = 'rata' THEN
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
               ORDER BY bl.tanggal DESC, bl.created_at DESC
               LIMIT 1)
         END
    FROM public.bahan b;
$$;

-- ------------------------------------------------------------
-- 4. HPP per menu
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_hpp_menu(
  p_tanggal DATE DEFAULT NULL,
  p_dasar   TEXT DEFAULT 'terakhir'
)
RETURNS TABLE (
  product_id        UUID,
  nama              TEXT,
  harga_jual        INTEGER,
  hpp               NUMERIC,
  margin            NUMERIC,
  margin_persen     NUMERIC,
  versi_takaran     DATE,
  bahan_dipakai     INTEGER,
  bahan_tanpa_harga TEXT[],
  lengkap           BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tgl DATE := COALESCE(p_tanggal, (NOW() AT TIME ZONE 'Asia/Jakarta')::date);
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT p.id,
         p.name,
         p.price,
         r.hpp,
         CASE WHEN r.hpp IS NOT NULL THEN ROUND(p.price - r.hpp, 2) END,
         CASE WHEN r.hpp IS NOT NULL AND p.price > 0
              THEN ROUND((p.price - r.hpp) / p.price * 100, 1) END,
         r.versi,
         COALESCE(r.bahan_dipakai, 0)::INTEGER,
         r.tanpa_harga,
         (r.hpp IS NOT NULL)
    FROM public.products p
    LEFT JOIN LATERAL (
      SELECT public.takaran_berlaku(p.id, v_tgl) AS versi,
             count(*)::INTEGER                   AS bahan_dipakai,
             -- Satu bahan tanpa harga membatalkan seluruh angkanya.
             -- bool_and atas himpunan kosong bernilai true, jadi menu
             -- tanpa takaran sama sekali dijaga terpisah oleh count.
             CASE WHEN count(*) > 0 AND bool_and(h.harga IS NOT NULL)
                  THEN ROUND(sum(t.jumlah * h.harga), 2) END AS hpp,
             array_agg(b.nama ORDER BY b.nama)
               FILTER (WHERE h.harga IS NULL)    AS tanpa_harga
        FROM public.takaran t
        JOIN public.bahan b ON b.id = t.bahan_id
        LEFT JOIN public.harga_bahan_pada(v_tgl, p_dasar) h ON h.bahan_id = t.bahan_id
       WHERE t.product_id = p.id
         AND t.berlaku_dari = public.takaran_berlaku(p.id, v_tgl)
    ) r ON true
   WHERE p.is_available
   ORDER BY p.sort_order, p.name;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_hpp_menu(DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_hpp_menu(DATE, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 5. Rincian HPP satu menu — "naiknya karena bahan apa"
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_hpp_rincian(
  p_product_id UUID,
  p_tanggal    DATE DEFAULT NULL,
  p_dasar      TEXT DEFAULT 'terakhir'
)
RETURNS TABLE (
  bahan_id   UUID,
  nama       TEXT,
  satuan     TEXT,
  jumlah     NUMERIC,
  harga      NUMERIC,
  biaya      NUMERIC,
  porsi      NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tgl   DATE := COALESCE(p_tanggal, (NOW() AT TIME ZONE 'Asia/Jakarta')::date);
  v_versi DATE;
  v_total NUMERIC;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  v_versi := public.takaran_berlaku(p_product_id, v_tgl);

  SELECT sum(t.jumlah * h.harga) INTO v_total
    FROM public.takaran t
    LEFT JOIN public.harga_bahan_pada(v_tgl, p_dasar) h ON h.bahan_id = t.bahan_id
   WHERE t.product_id = p_product_id AND t.berlaku_dari = v_versi;

  RETURN QUERY
  SELECT b.id,
         b.nama,
         b.satuan,
         t.jumlah,
         h.harga,
         CASE WHEN h.harga IS NOT NULL THEN ROUND(t.jumlah * h.harga, 2) END,
         CASE WHEN h.harga IS NOT NULL AND v_total > 0
              THEN ROUND(t.jumlah * h.harga / v_total * 100, 1) END
    FROM public.takaran t
    JOIN public.bahan b ON b.id = t.bahan_id
    LEFT JOIN public.harga_bahan_pada(v_tgl, p_dasar) h ON h.bahan_id = t.bahan_id
   WHERE t.product_id = p_product_id
     AND t.berlaku_dari = v_versi
   ORDER BY (t.jumlah * h.harga) DESC NULLS LAST, b.nama;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_hpp_rincian(UUID, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_hpp_rincian(UUID, DATE, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 6. Menyimpan takaran — satu versi utuh sekaligus
--
-- Versi hanya boleh maju. Menulis versi bertanggal lebih tua daripada
-- versi terakhir berarti mengubah HPP bulan yang sudah dilaporkan, dan
-- itu ditolak. Versi terbaru masih boleh diperbaiki selama tanggalnya
-- sama — itu masih menyusun resep yang sama, bukan menulis ulang sejarah.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_simpan_takaran(
  p_product_id   UUID,
  p_items        JSONB,
  p_berlaku_dari DATE DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tgl     DATE := COALESCE(p_berlaku_dari, (NOW() AT TIME ZONE 'Asia/Jakarta')::date);
  v_terbaru DATE;
  v_item    JSONB;
  v_n       INTEGER := 0;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  PERFORM 1 FROM public.products WHERE id = p_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = '22023';
  END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'TAKARAN_KOSONG' USING ERRCODE = '22023';
  END IF;

  SELECT max(berlaku_dari) INTO v_terbaru
    FROM public.takaran WHERE product_id = p_product_id;

  IF v_terbaru IS NOT NULL AND v_tgl < v_terbaru THEN
    RAISE EXCEPTION 'VERSI_MUNDUR' USING ERRCODE = '22023';
  END IF;

  -- Versi dengan tanggal ini disusun ulang seluruhnya; versi-versi
  -- sebelumnya tidak disentuh.
  DELETE FROM public.takaran
   WHERE product_id = p_product_id AND berlaku_dari = v_tgl;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    PERFORM 1 FROM public.bahan WHERE id = (v_item->>'bahan_id')::UUID;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'BAHAN_NOT_FOUND' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.takaran (product_id, berlaku_dari, bahan_id, jumlah)
    VALUES (p_product_id, v_tgl,
            (v_item->>'bahan_id')::UUID,
            (v_item->>'jumlah')::NUMERIC);
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_simpan_takaran(UUID, JSONB, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_simpan_takaran(UUID, JSONB, DATE) TO authenticated;

-- ------------------------------------------------------------
-- 7. Membaca takaran yang berlaku
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_takaran_menu(
  p_tanggal DATE DEFAULT NULL
)
RETURNS TABLE (
  product_id   UUID,
  produk       TEXT,
  berlaku_dari DATE,
  bahan_id     UUID,
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
  v_tgl DATE := COALESCE(p_tanggal, (NOW() AT TIME ZONE 'Asia/Jakarta')::date);
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT p.id, p.name, t.berlaku_dari, b.id, b.nama, b.satuan, t.jumlah
    FROM public.products p
    JOIN public.takaran t ON t.product_id = p.id
                         AND t.berlaku_dari = public.takaran_berlaku(p.id, v_tgl)
    JOIN public.bahan b ON b.id = t.bahan_id
   ORDER BY p.sort_order, p.name, t.jumlah DESC, b.nama;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_takaran_menu(DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_takaran_menu(DATE) TO authenticated;

-- ------------------------------------------------------------
-- 8. Semai bahan dan takaran RAMU
--
-- Angkanya dari resep kerja yang dipakai Mahaliriki, bukan hasil
-- perhitungan mundur. Berlaku sejak hari jualan pertama supaya HPP
-- bulan-bulan yang sudah lewat ikut bisa dihitung — resep ini memang
-- yang dipakai sejak awal.
--
-- Aman dijalankan ulang: bahan disemai bila namanya belum ada, dan
-- takaran hanya disemai untuk produk yang belum punya takaran sama
-- sekali. Resep yang sudah disesuaikan admin tidak akan ditimpa.
-- ------------------------------------------------------------
DO $$
DECLARE
  v_mulai  DATE;
  v_produk RECORD;
  v_resep  JSONB;
  v_n      INTEGER := 0;
  v_item   JSONB;
BEGIN
  -- Bahan. ON CONFLICT pada nama: yang sudah ada dibiarkan apa adanya.
  INSERT INTO public.bahan (nama, satuan) VALUES
    ('Pisang',         'gram'),
    ('Strawberry',     'gram'),
    ('Nanas',          'gram'),
    ('Mangga',         'gram'),
    ('Kacang',         'gram'),
    ('Coklat',         'gram'),
    ('Caramel',        'gram'),
    ('Es batu',        'gram'),
    ('Gula',           'ml'),
    ('Air',            'ml'),
    ('Susu UHT',       'ml'),
    ('Cup',            'pcs'),
    ('Tutup cup',      'pcs'),
    ('Sedotan',        'pcs'),
    ('Plastik vakum',  'pcs')
  ON CONFLICT (nama) DO NOTHING;

  SELECT COALESCE(min((created_at AT TIME ZONE 'Asia/Jakarta')::date),
                  (NOW() AT TIME ZONE 'Asia/Jakarta')::date)
    INTO v_mulai
    FROM public.orders;

  FOR v_produk IN
    SELECT id, name FROM public.products
     WHERE name LIKE 'KPK%' OR name LIKE 'PASUTRI%' OR name LIKE 'BNN%'
        OR name LIKE 'PASCA%' OR name LIKE 'PAMAN%'
  LOOP
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.takaran WHERE product_id = v_produk.id);

    v_resep :=
      CASE
        WHEN v_produk.name LIKE 'KPK%' THEN
          '[{"n":"Pisang","j":90},{"n":"Kacang","j":5},{"n":"Coklat","j":5},
            {"n":"Gula","j":25},{"n":"Es batu","j":135},{"n":"Air","j":85}]'::jsonb
        WHEN v_produk.name LIKE 'PASUTRI%' THEN
          '[{"n":"Strawberry","j":45},{"n":"Pisang","j":45},{"n":"Es batu","j":135},
            {"n":"Air","j":85},{"n":"Gula","j":25}]'::jsonb
        WHEN v_produk.name LIKE 'BNN%' THEN
          '[{"n":"Nanas","j":90},{"n":"Gula","j":25},{"n":"Es batu","j":135},
            {"n":"Susu UHT","j":80}]'::jsonb
        WHEN v_produk.name LIKE 'PASCA%' THEN
          '[{"n":"Pisang","j":90},{"n":"Caramel","j":10},{"n":"Gula","j":25},
            {"n":"Es batu","j":135},{"n":"Air","j":85}]'::jsonb
        WHEN v_produk.name LIKE 'PAMAN%' THEN
          '[{"n":"Pisang","j":30},{"n":"Mangga","j":60},{"n":"Gula","j":25},
            {"n":"Susu UHT","j":80},{"n":"Es batu","j":135}]'::jsonb
      END;

    -- Kemasan sama untuk seluruh menu.
    v_resep := v_resep || '[{"n":"Cup","j":1},{"n":"Tutup cup","j":1},
                            {"n":"Sedotan","j":1},{"n":"Plastik vakum","j":1}]'::jsonb;

    FOR v_item IN SELECT * FROM jsonb_array_elements(v_resep)
    LOOP
      INSERT INTO public.takaran (product_id, berlaku_dari, bahan_id, jumlah)
      SELECT v_produk.id, v_mulai, b.id, (v_item->>'j')::NUMERIC
        FROM public.bahan b
       WHERE b.nama = v_item->>'n'
      ON CONFLICT DO NOTHING;
    END LOOP;

    v_n := v_n + 1;
    RAISE NOTICE 'Takaran disemai untuk % (berlaku sejak %)', v_produk.name, v_mulai;
  END LOOP;

  RAISE NOTICE '0030: takaran disemai untuk % menu', v_n;
END;
$$;

NOTIFY pgrst, 'reload schema';
