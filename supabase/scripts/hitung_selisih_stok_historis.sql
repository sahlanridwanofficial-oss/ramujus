-- ============================================================
-- Sekali jalan: berapa banyak stok yang sudah melayang sebelum 0013
--
-- BUKAN migrasi. Jangan ditaruh di supabase/migrations/ dan jangan
-- dijadwalkan. Jalankan manual di SQL Editor Supabase, sekali, setelah
-- 0013 terpasang.
--
-- Latar: sebelum 0013, muat gerobak pagi mengurangi products.stock_quantity
-- tetapi audit malam tidak pernah mengembalikan apa pun. Setiap hari, cup
-- yang kembali ke base hilang dari angka sistem. Alokasi yang sudah dikunci
-- sebelum 0013 tidak ikut terkoreksi oleh migrasi itu — perbaikannya hanya
-- berlaku untuk audit yang dikunci setelahnya.
--
-- Berkas ini TIDAK mengubah apa pun. Ia hanya menghitung dan menampilkan.
-- Bagian penerapan sengaja dikomentari di bawah: memasukkan kembali cup
-- yang mungkin sudah dibuang berbulan-bulan lalu adalah keputusan Anda,
-- bukan keputusan sebuah skrip.
-- ============================================================

\echo ''
\echo '=== 1. Ringkasan per produk: cup yang hilang dari angka stok ==='

WITH melayang AS (
  SELECT ai.product_id,
         sum(COALESCE(ai.physical_remaining, 0))::INTEGER AS cup_melayang,
         count(DISTINCT ai.allocation_id)::INTEGER        AS jumlah_audit,
         min(a.date)                                      AS sejak,
         max(a.date)                                      AS sampai
    FROM public.driver_allocation_items ai
    JOIN public.driver_daily_allocations a ON a.id = ai.allocation_id
   WHERE a.status = 'reconciled'
     -- Hanya audit yang dikunci SEBELUM 0013 berlaku. Yang dikunci sesudahnya
     -- sudah mengembalikan cupnya sendiri, jadi tidak boleh dihitung lagi.
     AND a.stock_returned_at IS NULL
     AND COALESCE(ai.physical_remaining, 0) > 0
   GROUP BY ai.product_id
)
SELECT p.name                AS produk,
       p.category            AS kategori,
       p.stock_quantity      AS stok_tercatat_sekarang,
       m.cup_melayang        AS cup_tidak_pernah_kembali,
       (p.stock_quantity + m.cup_melayang) AS stok_bila_semua_dikembalikan,
       m.jumlah_audit        AS dari_berapa_audit,
       m.sejak,
       m.sampai
  FROM melayang m
  JOIN public.products p ON p.id = m.product_id
 ORDER BY m.cup_melayang DESC;

\echo ''
\echo '=== 2. Total keseluruhan ==='

SELECT count(*)                                    AS produk_terdampak,
       COALESCE(sum(COALESCE(ai.physical_remaining, 0)), 0)::INTEGER AS total_cup_melayang
  FROM public.driver_allocation_items ai
  JOIN public.driver_daily_allocations a ON a.id = ai.allocation_id
 WHERE a.status = 'reconciled'
   AND a.stock_returned_at IS NULL
   AND COALESCE(ai.physical_remaining, 0) > 0;

\echo ''
\echo '=== 3. Rinciannya per audit, untuk ditelusuri bila angkanya mengejutkan ==='

SELECT a.date            AS tanggal,
       pr.full_name      AS mitra,
       p.name            AS produk,
       ai.initial_quantity AS dibawa,
       ai.sold_quantity    AS terjual,
       ai.physical_remaining AS sisa_fisik,
       ai.waste_quantity     AS rusak
  FROM public.driver_allocation_items ai
  JOIN public.driver_daily_allocations a ON a.id = ai.allocation_id
  JOIN public.profiles pr ON pr.id = a.driver_id
  JOIN public.products p  ON p.id = ai.product_id
 WHERE a.status = 'reconciled'
   AND a.stock_returned_at IS NULL
   AND COALESCE(ai.physical_remaining, 0) > 0
 ORDER BY a.date DESC, pr.full_name, p.name;

-- ============================================================
-- 4. PENERAPAN — jalankan hanya bila Anda memang ingin mengoreksi stok
--
-- Angka di atas adalah cup yang PERNAH kembali ke base menurut catatan
-- audit. Belum tentu semuanya masih ada: sebagian mungkin sudah dibuang,
-- dipakai sendiri, atau memang tidak layak jual sejak awal. Karena itu
-- jangan menerapkannya membabi buta.
--
-- Cara yang disarankan, berurutan:
--
--   a. Hitung fisik cup yang benar-benar ada di base sekarang.
--   b. Pakai "Stock Opname" di halaman Inventori Stok untuk menyetel angka
--      sistem ke hasil hitungan itu. Cara ini paling jujur: yang dicatat
--      adalah kenyataan, bukan rekonstruksi dari riwayat.
--
-- Bila Anda tetap ingin mengembalikan seluruh angka historis di atas apa
-- adanya, hapus komentar blok di bawah lalu jalankan. Ia menaikkan stok dan
-- menandai audit-audit lama sebagai sudah dikembalikan, sehingga menjalankan
-- skrip ini dua kali tidak menghitung ganda.
--
-- Penjaga rekonsiliasi dimatikan sementara di dalam transaksi yang sama.
-- Penjaga itu menolak SEMUA perubahan atas alokasi terkunci — termasuk
-- penandaan ini, yang justru diperlukan supaya koreksinya tidak terulang.
-- Karena satu transaksi, kegagalan di tengah jalan mengembalikan penjaga
-- itu apa adanya.
-- ============================================================

-- BEGIN;
--
-- ALTER TABLE public.driver_daily_allocations DISABLE TRIGGER allocations_reconciled_guard;
--
-- WITH melayang AS (
--   SELECT ai.product_id,
--          sum(COALESCE(ai.physical_remaining, 0))::INTEGER AS cup
--     FROM public.driver_allocation_items ai
--     JOIN public.driver_daily_allocations a ON a.id = ai.allocation_id
--    WHERE a.status = 'reconciled'
--      AND a.stock_returned_at IS NULL
--      AND COALESCE(ai.physical_remaining, 0) > 0
--    GROUP BY ai.product_id
-- ),
-- terapkan AS (
--   UPDATE public.products p
--      SET stock_quantity = p.stock_quantity + m.cup
--     FROM melayang m
--    WHERE p.id = m.product_id
--   RETURNING p.id, p.stock_quantity, m.cup
-- )
-- INSERT INTO public.stock_movements
--   (product_id, delta, balance_after, reason, note, actor_id)
-- SELECT t.id, t.cup, t.stock_quantity, 'adjustment',
--        'Koreksi historis: sisa gerobak sebelum pengembalian otomatis berlaku',
--        NULL
--   FROM terapkan t;
--
-- UPDATE public.driver_daily_allocations a
--    SET stock_returned_at = NOW()
--  WHERE a.status = 'reconciled'
--    AND a.stock_returned_at IS NULL
--    AND EXISTS (SELECT 1 FROM public.driver_allocation_items ai
--                 WHERE ai.allocation_id = a.id
--                   AND COALESCE(ai.physical_remaining, 0) > 0);
--
-- ALTER TABLE public.driver_daily_allocations ENABLE TRIGGER allocations_reconciled_guard;
--
-- COMMIT;
