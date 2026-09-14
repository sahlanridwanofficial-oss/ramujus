-- ============================================================
-- 0032 — Penjualan yang mendahului nota pertama dinilai dengan harga
--        paling awal yang diketahui, dan ditandai perkiraan
--
-- Keadaan nyata pada 15 September 2026: seluruh penjualan jatuh pada
-- 7-14 September, sedangkan seluruh nota belanja dicatat pada 15
-- September. Tidak ada satu hari pun yang beririsan.
--
-- Akibatnya harga_bahan_pada() mengembalikan NULL untuk setiap hari
-- penjualan, dan admin_biaya_per_cup_takaran melaporkan "0 dari 133 cup
-- ternilai". Benar secara aturan, tapi tidak berguna — dan yang lebih
-- buruk, ia tampak seperti kerusakan.
--
-- ------------------------------------------------------------
-- KENAPA MEMUNDURKAN HARGA ITU SAH DI SINI
--
-- 0030 sudah menyemai takaran dengan berlaku_dari = hari jualan
-- pertama, dengan alasan "resep ini memang yang dipakai sejak awal".
-- Memperlakukan harga secara berbeda — resep boleh dimundurkan, harga
-- tidak — bukan kehati-hatian, melainkan ketidakkonsistenan yang
-- hasilnya justru layar kosong.
--
-- Nota paling awal adalah bukti harga paling tua yang RAMU punya. Untuk
-- penjualan sebelum itu, ia perkiraan terbaik yang ada. Yang tidak boleh
-- adalah memakainya diam-diam: fungsi ini mengembalikan penanda
-- terpisah supaya layar menyebutnya perkiraan, bukan angka terukur.
--
-- ------------------------------------------------------------
-- YANG TIDAK BERUBAH
--
-- Bahan yang BELUM PERNAH dibeli sama sekali tetap tidak punya harga,
-- dan tetap membuat HPP menu itu NULL. Kemunduran ini hanya berlaku
-- untuk bahan yang punya nota — sekadar notanya bertanggal lebih muda
-- daripada penjualannya. Tidak ada harga yang dikarang dari ketiadaan.
-- ============================================================

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
           END,
           -- Penjualan yang mendahului nota pertama: dipakai harga
           -- paling awal yang diketahui. Bahan yang belum pernah dibeli
           -- sama sekali tetap NULL — tidak ada yang dikarang dari
           -- ketiadaan, hanya dimundurkan dari bukti yang ada.
           (SELECT bl.total_rupiah / bl.jumlah
              FROM public.belanja bl
             WHERE bl.bahan_id = b.id
               AND bl.jumlah > 0
             ORDER BY bl.tanggal ASC, bl.created_at ASC
             LIMIT 1)
         )
    FROM public.bahan b;
$$;

-- ------------------------------------------------------------
-- Penanda perkiraan pada laporan biaya per cup
--
-- Penambahan kolom pada RETURNS TABLE tidak bisa lewat CREATE OR
-- REPLACE, jadi fungsinya dibuang dulu. Tanda tangan argumennya tidak
-- berubah, sehingga pemanggil lama tetap cocok.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_biaya_per_cup_takaran(DATE, DATE, TEXT);

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
  lengkap          BOOLEAN,
  harga_perkiraan  BOOLEAN,
  nota_pertama     DATE
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_nota_pertama DATE;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  SELECT min(bl.tanggal) INTO v_nota_pertama FROM public.belanja bl;

  RETURN QUERY
  WITH jual AS (
    SELECT (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS hari,
           oi.product_id,
           sum(oi.quantity)::INTEGER AS qty,
           sum(oi.subtotal)::BIGINT  AS rupiah
      FROM public.orders o
      JOIN public.order_items oi ON oi.order_id = o.id
      JOIN public.products p     ON p.id = oi.product_id
     WHERE o.created_at >= public.wib_day_start(p_dari)
       AND o.created_at <  public.wib_day_start(p_sampai + 1)
       AND p.category = 'smoothie'
     GROUP BY 1, 2
  ), dinilai AS (
    SELECT j.qty, j.rupiah, j.hari,
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
         -- Pembaginya cup yang TERNILAI, bukan seluruh cup.
         CASE WHEN sum(qty) FILTER (WHERE hpp IS NOT NULL) > 0
              THEN ROUND(sum(qty * hpp) FILTER (WHERE hpp IS NOT NULL)
                         / sum(qty) FILTER (WHERE hpp IS NOT NULL), 2) END,
         COALESCE(sum(rupiah), 0)::BIGINT,
         CASE WHEN sum(qty) FILTER (WHERE hpp IS NOT NULL) > 0
              THEN ROUND((sum(rupiah) FILTER (WHERE hpp IS NOT NULL)
                          - sum(qty * hpp) FILTER (WHERE hpp IS NOT NULL))
                         / sum(qty) FILTER (WHERE hpp IS NOT NULL), 2) END,
         (COALESCE(sum(qty), 0) > 0
          AND COALESCE(sum(qty) FILTER (WHERE hpp IS NOT NULL), 0) = COALESCE(sum(qty), 0)),
         -- Benar bila ADA cup yang terjual sebelum nota pertama dicatat,
         -- sehingga sebagian angkanya bersandar pada harga yang dimundurkan.
         (v_nota_pertama IS NOT NULL
          AND COALESCE(min(hari) FILTER (WHERE hpp IS NOT NULL), v_nota_pertama) < v_nota_pertama),
         v_nota_pertama
    FROM dinilai;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_biaya_per_cup_takaran(DATE, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_biaya_per_cup_takaran(DATE, DATE, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
