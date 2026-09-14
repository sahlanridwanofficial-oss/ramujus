-- ============================================================
-- 0031 — Biaya bahan per cup dari takaran, bukan dari belanja dibagi cup
--
-- MASALAHNYA, dari pemakaian nyata pada 15 September 2026:
--
--   Belanja 30 hari   Rp1.988.374
--   Cup terjual              133
--   ---------------------------------
--   "Biaya per cup"   Rp14.951   <- lebih mahal dari harga jualnya
--
-- Angka itu bukan meleset sedikit; ia tidak berarti apa-apa. Sebabnya
-- satu belanja kemasan 1.000 cup yang akan terpakai tujuh puluh hari ke
-- depan, dibagi dengan cup yang terjual seminggu.
--
-- Rumus "belanja dibagi cup" hanya benar kalau tinggi stok di awal dan
-- di akhir rentang kira-kira sama. Pada gerobak yang baru pertama kali
-- belanja borongan, syarat itu jauh dari terpenuhi. Itulah pekerjaan
-- fase 3 (hitung stok):
--
--     bahan terpakai = stok awal + belanja - stok akhir
--
-- Sampai itu ada, angka "nyata" tidak bisa dihitung. Yang BISA dihitung
-- sekarang — dan sudah benar sejak 0030 memasang takaran dan 0029
-- memasang harga — adalah biaya menurut takaran:
--
--     biaya = SUM( cup terjual tiap menu  x  HPP menu itu )
--
-- Angka ini tidak memuat susut, tumpah, dan kelebihan tuang, jadi ia
-- selalu lebih murah daripada kenyataan. Perbedaannya justru gunanya:
-- begitu fase 3 ada, SELISIH antara keduanya adalah bocor.
--
-- ------------------------------------------------------------
-- HPP DIAMBIL PADA TANGGAL PENJUALANNYA, BUKAN HARI INI
--
-- Cup yang terjual 7 September dinilai dengan resep dan harga yang
-- berlaku 7 September. Memakai harga hari ini untuk penjualan bulan lalu
-- membuat laporan lama berubah tiap kali ada belanja baru — cacat yang
-- sama yang membuat takaran dibuat berversi sejak awal.
--
-- Konsekuensi yang sengaja diterima: cup yang terjual SEBELUM nota
-- pertama dicatat tidak punya harga, jadi tidak bisa dinilai. Cup itu
-- dihitung terpisah dan dilaporkan apa adanya, bukan diam-diam dinilai
-- nol atau diam-diam dinilai dengan harga hari ini.
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_biaya_per_cup_takaran(
  p_dari   DATE,
  p_sampai DATE,
  p_dasar  TEXT DEFAULT 'rata'
)
RETURNS TABLE (
  cup              INTEGER,
  cup_ternilai     INTEGER,
  biaya_total      NUMERIC,
  biaya_per_cup    NUMERIC,
  omzet            BIGINT,
  margin_per_cup   NUMERIC,
  lengkap          BOOLEAN
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
  WITH jual AS (
    -- Cup per menu per hari. Harinya dipertahankan supaya tiap cup bisa
    -- dinilai dengan harga yang berlaku saat ia terjual.
    SELECT (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS hari,
           oi.product_id,
           sum(oi.quantity)::INTEGER AS qty,
           sum(oi.subtotal)::BIGINT  AS rupiah
      FROM public.orders o
      JOIN public.order_items oi ON oi.order_id = o.id
      JOIN public.products p     ON p.id = oi.product_id
     WHERE o.created_at >= public.wib_day_start(p_dari)
       AND o.created_at <  public.wib_day_start(p_sampai + 1)
       -- Hanya yang berkategori cup. Topping punya satuan sendiri dan
       -- tidak punya takaran; ikut dihitung, ia akan selamanya membuat
       -- laporan ini tampak tidak lengkap.
       AND p.category = 'smoothie'
     GROUP BY 1, 2
  ), dinilai AS (
    SELECT j.qty, j.rupiah,
           (SELECT CASE WHEN count(*) > 0 AND bool_and(h.harga IS NOT NULL)
                        THEN sum(t.jumlah * h.harga) END
              FROM public.takaran t
              LEFT JOIN public.harga_bahan_pada(j.hari, p_dasar) h
                     ON h.bahan_id = t.bahan_id
             WHERE t.product_id = j.product_id
               AND t.berlaku_dari = public.takaran_berlaku(j.product_id, j.hari)
           ) AS hpp
      FROM jual j
  )
  SELECT COALESCE(sum(qty), 0)::INTEGER,
         COALESCE(sum(qty) FILTER (WHERE hpp IS NOT NULL), 0)::INTEGER,
         ROUND(COALESCE(sum(qty * hpp), 0), 2),
         -- Pembaginya cup yang TERNILAI, bukan seluruh cup. Membagi biaya
         -- 100 cup dengan 133 cup akan melaporkan biaya per cup yang
         -- terlalu murah, dan arah kesalahannya persis yang paling
         -- berbahaya: margin tampak lebih bagus daripada kenyataannya.
         CASE WHEN sum(qty) FILTER (WHERE hpp IS NOT NULL) > 0
              THEN ROUND(sum(qty * hpp) FILTER (WHERE hpp IS NOT NULL)
                         / sum(qty) FILTER (WHERE hpp IS NOT NULL), 2) END,
         COALESCE(sum(rupiah), 0)::BIGINT,
         -- Margin dihitung dari omzet cup YANG SAMA dengan yang biayanya
         -- terhitung. Mencampur omzet seluruh cup dengan biaya sebagian
         -- cup akan melaporkan margin yang terlalu bagus.
         CASE WHEN sum(qty) FILTER (WHERE hpp IS NOT NULL) > 0
              THEN ROUND((sum(rupiah) FILTER (WHERE hpp IS NOT NULL)
                          - sum(qty * hpp) FILTER (WHERE hpp IS NOT NULL))
                         / sum(qty) FILTER (WHERE hpp IS NOT NULL), 2) END,
         (COALESCE(sum(qty), 0) > 0
          AND COALESCE(sum(qty) FILTER (WHERE hpp IS NOT NULL), 0) = COALESCE(sum(qty), 0))
    FROM dinilai;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_biaya_per_cup_takaran(DATE, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_biaya_per_cup_takaran(DATE, DATE, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- Belanja pada rentang, TANPA dibagi cup
--
-- Angka belanjanya sendiri tetap berguna — ia jumlah uang yang benar
-- keluar. Yang tidak sah adalah membaginya dengan cup terjual selama
-- sebagian besarnya masih menumpuk sebagai stok. Fungsi ini melaporkan
-- angkanya apa adanya, dan menyebut berapa bagian yang jatuh pada
-- kemasan — yang paling sering dibeli borongan dan paling sering bikin
-- rumus "belanja dibagi cup" ngawur.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_belanja_ringkas(
  p_dari   DATE,
  p_sampai DATE
)
RETURNS TABLE (
  rupiah          NUMERIC,
  rupiah_kemasan  NUMERIC,
  jumlah_nota     INTEGER,
  bahan_terisi    INTEGER,
  bahan_total     INTEGER
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
  SELECT COALESCE(sum(bl.total_rupiah), 0),
         COALESCE(sum(bl.total_rupiah) FILTER (WHERE b.satuan = 'pcs'), 0),
         count(*)::INTEGER,
         (SELECT count(DISTINCT bahan_id)::INTEGER FROM public.belanja),
         (SELECT count(*)::INTEGER FROM public.bahan WHERE aktif)
    FROM public.belanja bl
    JOIN public.bahan b ON b.id = bl.bahan_id
   WHERE bl.tanggal >= p_dari AND bl.tanggal <= p_sampai;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_belanja_ringkas(DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_belanja_ringkas(DATE, DATE) TO authenticated;

NOTIFY pgrst, 'reload schema';
