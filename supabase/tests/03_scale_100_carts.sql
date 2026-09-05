-- Uji skala: 100 gerobak dengan riwayat pesanan dan histori GPS.
-- Membuktikan bahwa kueri yang dipakai halaman admin tetap satu kali jalan
-- dan memakai indeks, bukan pemindaian tabel penuh. Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off
\timing off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

\echo '=== Menyiapkan armada: 100 driver, 1 admin ==='

INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin Pusat"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO auth.users (id, email, raw_user_meta_data)
SELECT gen_random_uuid(),
       'driver' || g || '@ramu.id',
       jsonb_build_object('full_name', 'Mitra Gerobak ' || lpad(g::text, 3, '0'))
  FROM generate_series(1, 100) g;

INSERT INTO public.products (id, name, price, category, sort_order)
SELECT gen_random_uuid(), 'Menu ' || g, 12000 + g * 500, 'smoothie', g
  FROM generate_series(1, 12) g;

-- Setiap driver membuka shift.
INSERT INTO public.shifts (driver_id, status)
SELECT id, 'active' FROM public.profiles WHERE role = 'driver';

\echo '=== Mengisi posisi terkini untuk seluruh armada ==='
INSERT INTO public.driver_positions (driver_id, shift_id, latitude, longitude, accuracy, recorded_at)
SELECT p.id,
       s.id,
       -6.2088 + (random() - 0.5) * 0.15,
       106.8456 + (random() - 0.5) * 0.15,
       5 + random() * 20,
       -- Sebagian sengaja dibuat basi untuk menguji pembedaan status.
       NOW() - make_interval(secs => (random() * 1800)::int)
  FROM public.profiles p
  JOIN public.shifts s ON s.driver_id = p.id AND s.status = 'active'
 WHERE p.role = 'driver';

\echo '=== Mengisi 30 hari riwayat: ~45.000 pesanan + ~90.000 item ==='
INSERT INTO public.orders (shift_id, driver_id, order_number, latitude, longitude,
                           total_amount, payment_method, created_at)
SELECT s.id,
       s.driver_id,
       'RMJ-SEED-' || s.driver_id::text || '-' || d || '-' || n,
       -6.2088 + (random() - 0.5) * 0.15,
       106.8456 + (random() - 0.5) * 0.15,
       (15000 + floor(random() * 40000))::int,
       (ARRAY['cash','qris','transfer'])[1 + floor(random() * 3)],
       NOW() - make_interval(days => d, secs => (random() * 86400)::int)
  FROM public.shifts s,
       generate_series(0, 29) d,
       generate_series(1, 15) n
 WHERE s.status = 'active';

INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
SELECT o.id, pr.id, 1 + floor(random() * 3)::int, pr.price, pr.price * (1 + floor(random() * 3))::int
  FROM public.orders o
  JOIN LATERAL (
    SELECT id, price FROM public.products ORDER BY random() LIMIT 2
  ) pr ON true;

\echo '=== Mengisi histori GPS 7 hari ==='
INSERT INTO public.location_logs (driver_id, shift_id, latitude, longitude, accuracy, recorded_at)
SELECT s.driver_id, s.id,
       -6.2088 + (random() - 0.5) * 0.15,
       106.8456 + (random() - 0.5) * 0.15,
       10,
       NOW() - make_interval(days => d, secs => (random() * 86400)::int)
  FROM public.shifts s, generate_series(0, 6) d, generate_series(1, 60) n
 WHERE s.status = 'active';

ANALYZE;

\echo ''
\echo '=== Ukuran data yang diuji ==='
SELECT (SELECT count(*) FROM public.profiles WHERE role='driver') AS driver,
       (SELECT count(*) FROM public.orders)          AS pesanan,
       (SELECT count(*) FROM public.order_items)     AS item_pesanan,
       (SELECT count(*) FROM public.location_logs)   AS histori_gps,
       (SELECT count(*) FROM public.driver_positions) AS baris_posisi;

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== fleet_overview: SATU query untuk seluruh armada ==='
SELECT count(*) AS baris_dikembalikan,
       count(*) FILTER (WHERE seconds_since <= 180)  AS terpantau,
       count(*) FILTER (WHERE seconds_since > 180)   AS tertunda_atau_offline,
       sum(orders_today)  AS pesanan_hari_ini,
       sum(revenue_today) AS omzet_hari_ini
  FROM public.fleet_overview();

\echo ''
\echo '=== admin_driver_stats: SATU query menggantikan 201 query ==='
SELECT count(*) AS baris,
       sum(total_orders)  AS total_pesanan_seluruh_armada,
       sum(total_revenue) AS total_omzet_seluruh_armada
  FROM public.admin_driver_stats();

\echo ''
\echo '=== admin_sales_daily 30 hari ==='
SELECT count(*) AS hari, sum(orders) AS pesanan, sum(revenue) AS omzet
  FROM public.admin_sales_daily(30);

\echo ''
\echo '=== admin_top_products 30 hari (dulu SELALU kosong karena kolom tidak ada) ==='
SELECT name, total_qty, revenue FROM public.admin_top_products(30, 5);

\echo ''
\echo '=== Rencana eksekusi: peta sebaran transaksi memakai indeks parsial ==='
RESET ROLE;
EXPLAIN (COSTS OFF)
SELECT id, latitude, longitude FROM public.orders
 WHERE latitude IS NOT NULL AND longitude IS NOT NULL
   AND created_at >= NOW() - INTERVAL '7 days'
 ORDER BY created_at DESC
 LIMIT 500;

\echo ''
\echo '=== Rencana eksekusi: riwayat GPS satu driver memakai indeks ==='
EXPLAIN (COSTS OFF)
SELECT * FROM public.location_logs
 WHERE driver_id = (SELECT id FROM public.profiles WHERE role='driver' LIMIT 1)
 ORDER BY recorded_at DESC LIMIT 100;

\echo ''
\echo '=== Pemangkasan histori lokasi ==='
SELECT public.prune_location_logs(3) AS baris_dihapus_lebih_tua_dari_3_hari;
SELECT count(*) AS histori_tersisa FROM public.location_logs;
