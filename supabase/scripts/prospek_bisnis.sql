-- ============================================================
-- Diagnosa prospek bisnis RAMU
--
-- Tempel SELURUHNYA ke SQL Editor Supabase lalu Run, kemudian salin
-- hasilnya. Hanya membaca; tidak mengubah apa pun.
--
-- Satu pernyataan tunggal, karena SQL Editor Supabase hanya menampilkan
-- hasil kueri terakhir. Keluarannya berupa daftar metrik bernama supaya
-- bisa disalin-tempel utuh tanpa kehilangan konteks.
--
-- "Cup" memakai definisi yang sama dengan dashboard dan aplikasi driver:
-- kuantitas produk berkategori 'smoothie'. Topping seperti stevia tidak
-- dihitung sebagai cup, hanya menambah omzet.
--
-- Batas hari memakai zona Asia/Jakarta, bukan UTC. Penjualan jam 23.00 WIB
-- masuk ke hari itu, bukan hari berikutnya.
-- ============================================================

WITH
-- Penjualan per hari kalender WIB.
harian AS (
  SELECT (o.created_at AT TIME ZONE 'Asia/Jakarta')::date            AS hari,
         count(DISTINCT o.id)                                        AS transaksi,
         COALESCE(sum(oi.quantity) FILTER (WHERE p.category = 'smoothie'), 0) AS cup,
         COALESCE(sum(oi.subtotal), 0)                               AS omzet
    FROM public.orders o
    LEFT JOIN public.order_items oi ON oi.order_id = o.id
    LEFT JOIN public.products    p  ON p.id = oi.product_id
   GROUP BY 1
),
rentang AS (
  SELECT min(hari) AS awal, max(hari) AS akhir, count(*) AS hari_jualan
    FROM harian
),
-- Dua jendela 7 hari terakhir, untuk melihat arah, bukan cuma rata-rata.
jendela AS (
  SELECT
    COALESCE(avg(cup) FILTER (
      WHERE hari > (SELECT akhir FROM rentang) - 7), 0)  AS cup_7_terakhir,
    COALESCE(avg(cup) FILTER (
      WHERE hari <= (SELECT akhir FROM rentang) - 7
        AND hari >  (SELECT akhir FROM rentang) - 14), 0) AS cup_7_sebelumnya
    FROM harian
),
-- Jam paling ramai. Hanya cup, karena inilah yang menentukan rute.
per_jam AS (
  SELECT to_char(o.created_at AT TIME ZONE 'Asia/Jakarta', 'HH24') AS jam,
         sum(oi.quantity) AS cup
    FROM public.orders o
    JOIN public.order_items oi ON oi.order_id = o.id
    JOIN public.products    p  ON p.id = oi.product_id AND p.category = 'smoothie'
   GROUP BY 1
),
-- Racikan mana yang menarik, mana yang menumpang muatan.
per_menu AS (
  SELECT p.name,
         p.category,
         COALESCE(sum(oi.quantity), 0) AS cup,
         COALESCE(sum(oi.subtotal), 0) AS omzet
    FROM public.products p
    LEFT JOIN public.order_items oi ON oi.product_id = p.id
   GROUP BY p.id, p.name, p.category
),
-- Muatan vs terjual: apakah gerobak membawa jauh lebih banyak dari yang laku.
muatan AS (
  SELECT COALESCE(sum(ai.initial_quantity), 0) AS dibawa,
         COALESCE(sum(ai.sold_quantity), 0)    AS terjual,
         COALESCE(sum(ai.waste_quantity), 0)   AS rusak
    FROM public.driver_allocation_items ai
    JOIN public.driver_daily_allocations a ON a.id = ai.allocation_id
),
-- Baris audit yang mustahil secara fisik. Ini penanda seberapa jauh data
-- historis boleh dipercaya; migrasi 0014 mencegahnya terjadi lagi.
mustahil AS (
  SELECT count(*) FILTER (
           WHERE ai.physical_remaining IS NOT NULL
             AND ai.sold_quantity + ai.physical_remaining + ai.waste_quantity
                 > ai.initial_quantity) AS baris_mustahil,
         count(*) FILTER (WHERE ai.physical_remaining IS NOT NULL) AS baris_diaudit
    FROM public.driver_allocation_items ai
),
-- Pembelian ulang menurut perkiraan driver saat mencatat pesanan.
pelanggan AS (
  SELECT count(*) FILTER (WHERE customer_type = 'returning') AS ulang,
         count(*) FILTER (WHERE customer_type = 'new')       AS baru,
         count(*) FILTER (WHERE customer_type IS NULL)       AS tidak_dicatat
    FROM public.orders
),
metrik(urutan, bagian, nama, nilai) AS (
  -- A. Skala
  SELECT 1, 'A. Skala', 'Rentang data',
         COALESCE(to_char((SELECT awal FROM rentang), 'DD Mon YYYY') || ' s/d ' ||
                  to_char((SELECT akhir FROM rentang), 'DD Mon YYYY'), 'belum ada penjualan')
  UNION ALL SELECT 2, 'A. Skala', 'Hari ada penjualan',
         (SELECT hari_jualan FROM rentang)::text || ' hari'
  UNION ALL SELECT 3, 'A. Skala', 'Total cup terjual',
         (SELECT COALESCE(sum(cup), 0) FROM harian)::text || ' cup'
  UNION ALL SELECT 4, 'A. Skala', 'Total omzet',
         'Rp' || to_char((SELECT COALESCE(sum(omzet), 0) FROM harian), 'FM999G999G999')
  UNION ALL SELECT 5, 'A. Skala', 'Total transaksi',
         (SELECT COALESCE(sum(transaksi), 0) FROM harian)::text || ' transaksi'

  -- B. Arah — yang paling menentukan prospek
  UNION ALL SELECT 10, 'B. Arah', 'Rata-rata cup/hari (keseluruhan)',
         to_char((SELECT COALESCE(avg(cup), 0) FROM harian), 'FM990.0') || ' cup'
  UNION ALL SELECT 11, 'B. Arah', 'Rata-rata cup/hari (7 hari terakhir)',
         to_char((SELECT cup_7_terakhir FROM jendela), 'FM990.0') || ' cup'
  UNION ALL SELECT 12, 'B. Arah', 'Rata-rata cup/hari (7 hari sebelumnya)',
         to_char((SELECT cup_7_sebelumnya FROM jendela), 'FM990.0') || ' cup'
  UNION ALL SELECT 13, 'B. Arah', 'Perubahan antar minggu',
         CASE WHEN (SELECT cup_7_sebelumnya FROM jendela) > 0
              THEN to_char(((SELECT cup_7_terakhir FROM jendela) /
                            (SELECT cup_7_sebelumnya FROM jendela) - 1) * 100, 'FM990.0') || '%'
              ELSE 'belum cukup data (perlu 14 hari)' END
  UNION ALL SELECT 14, 'B. Arah', 'Hari terbaik',
         COALESCE((SELECT to_char(hari, 'DD Mon') || ' — ' || cup || ' cup'
                     FROM harian ORDER BY cup DESC, hari DESC LIMIT 1), '-')
  UNION ALL SELECT 15, 'B. Arah', 'Hari terburuk',
         COALESCE((SELECT to_char(hari, 'DD Mon') || ' — ' || cup || ' cup'
                     FROM harian ORDER BY cup ASC, hari DESC LIMIT 1), '-')

  -- C. Titik impas (17 cup/hari pada margin Rp5.000)
  UNION ALL SELECT 20, 'C. Titik impas', 'Hari TEMBUS 17 cup',
         (SELECT count(*) FROM harian WHERE cup >= 17)::text || ' dari ' ||
         (SELECT hari_jualan FROM rentang)::text || ' hari'
  UNION ALL SELECT 21, 'C. Titik impas', 'Hari di bawah 17 cup',
         (SELECT count(*) FROM harian WHERE cup < 17)::text || ' hari'
  UNION ALL SELECT 22, 'C. Titik impas', 'Perkiraan margin terkumpul (Rp5.000/cup)',
         'Rp' || to_char((SELECT COALESCE(sum(cup), 0) FROM harian) * 5000, 'FM999G999G999')

  -- D. Nilai transaksi
  UNION ALL SELECT 30, 'D. Transaksi', 'Cup per transaksi',
         to_char((SELECT COALESCE(sum(cup), 0)::numeric /
                  NULLIF((SELECT sum(transaksi) FROM harian), 0) FROM harian), 'FM990.00') || ' cup'
  UNION ALL SELECT 31, 'D. Transaksi', 'Rata-rata nilai transaksi',
         'Rp' || to_char((SELECT COALESCE(sum(omzet), 0)::numeric /
                  NULLIF((SELECT sum(transaksi) FROM harian), 0) FROM harian), 'FM999G999')

  -- E. Pelanggan
  UNION ALL SELECT 40, 'E. Pelanggan', 'Pesanan pembeli ULANG',
         (SELECT ulang FROM pelanggan)::text || ' pesanan'
  UNION ALL SELECT 41, 'E. Pelanggan', 'Pesanan pembeli BARU',
         (SELECT baru FROM pelanggan)::text || ' pesanan'
  UNION ALL SELECT 42, 'E. Pelanggan', 'Porsi pembeli ulang',
         CASE WHEN (SELECT ulang + baru FROM pelanggan) > 0
              THEN to_char((SELECT ulang FROM pelanggan)::numeric * 100 /
                           (SELECT ulang + baru FROM pelanggan), 'FM990.0') || '%'
              ELSE 'belum dicatat' END
  UNION ALL SELECT 43, 'E. Pelanggan', 'Pesanan tanpa catatan profil',
         (SELECT tidak_dicatat FROM pelanggan)::text || ' pesanan'

  -- F. Jam ramai — menentukan rute
  UNION ALL SELECT 50, 'F. Jam ramai', 'Tiga jam paling laku',
         COALESCE((SELECT string_agg(jam || ':00 (' || cup || ' cup)', '  ·  ' ORDER BY cup DESC)
                     FROM (SELECT jam, cup FROM per_jam ORDER BY cup DESC LIMIT 3) t), '-')
  UNION ALL SELECT 51, 'F. Jam ramai', 'Tiga jam paling sepi',
         COALESCE((SELECT string_agg(jam || ':00 (' || cup || ' cup)', '  ·  ' ORDER BY cup ASC)
                     FROM (SELECT jam, cup FROM per_jam ORDER BY cup ASC LIMIT 3) t), '-')

  -- G. Menu
  UNION ALL SELECT 60, 'G. Menu', 'Racikan terlaris',
         COALESCE((SELECT string_agg(name || ' (' || cup || ')', '  ·  ' ORDER BY cup DESC)
                     FROM (SELECT name, cup FROM per_menu
                            WHERE category = 'smoothie' ORDER BY cup DESC LIMIT 3) t), '-')
  UNION ALL SELECT 61, 'G. Menu', 'Racikan TIDAK PERNAH terjual',
         COALESCE((SELECT string_agg(name, '  ·  ' ORDER BY name)
                     FROM per_menu WHERE category = 'smoothie' AND cup = 0), 'tidak ada')
  UNION ALL SELECT 62, 'G. Menu', 'Porsi omzet racikan terlaris',
         CASE WHEN (SELECT sum(omzet) FROM per_menu) > 0
              THEN to_char((SELECT max(omzet) FROM per_menu WHERE category = 'smoothie')::numeric
                           * 100 / (SELECT sum(omzet) FROM per_menu), 'FM990.0') || '%'
              ELSE '-' END

  -- H. Muatan
  UNION ALL SELECT 70, 'H. Muatan', 'Total cup dibawa ke gerobak',
         (SELECT dibawa FROM muatan)::text || ' cup'
  UNION ALL SELECT 71, 'H. Muatan', 'Total tercatat terjual di audit',
         (SELECT terjual FROM muatan)::text || ' cup'
  UNION ALL SELECT 72, 'H. Muatan', 'Tingkat laku muatan',
         CASE WHEN (SELECT dibawa FROM muatan) > 0
              THEN to_char((SELECT terjual FROM muatan)::numeric * 100 /
                           (SELECT dibawa FROM muatan), 'FM990.0') || '%'
              ELSE '-' END
  UNION ALL SELECT 73, 'H. Muatan', 'Cup tercatat rusak/hilang',
         (SELECT rusak FROM muatan)::text || ' cup'

  -- I. Kesehatan data — seberapa jauh angka di atas boleh dipercaya
  UNION ALL SELECT 80, 'I. Kesehatan data', 'Baris audit yang MUSTAHIL',
         (SELECT baris_mustahil FROM mustahil)::text || ' dari ' ||
         (SELECT baris_diaudit FROM mustahil)::text || ' baris diaudit'
  UNION ALL SELECT 81, 'I. Kesehatan data', 'Porsi baris mustahil',
         CASE WHEN (SELECT baris_diaudit FROM mustahil) > 0
              THEN to_char((SELECT baris_mustahil FROM mustahil)::numeric * 100 /
                           (SELECT baris_diaudit FROM mustahil), 'FM990.0') || '%'
              ELSE 'belum ada audit' END
  UNION ALL SELECT 82, 'I. Kesehatan data', 'Selisih cup: audit vs pesanan nyata',
         ((SELECT terjual FROM muatan) - (SELECT COALESCE(sum(cup), 0) FROM harian))::text || ' cup'
)
SELECT bagian, nama AS metrik, nilai
  FROM metrik
 ORDER BY urutan;
