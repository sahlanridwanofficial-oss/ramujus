-- ============================================================
-- Migrasi mana yang sudah terpasang di database ini?
--
-- Tempel seluruhnya ke SQL Editor Supabase lalu Run. Hanya membaca katalog
-- Postgres; tidak mengubah apa pun.
--
-- Repositori ini tidak memakai tabel riwayat migrasi, jadi pemeriksaannya
-- dilakukan dengan mencari objek penanda yang dibuat masing-masing berkas.
-- Cara ini juga lebih jujur daripada tabel riwayat: yang dilaporkan adalah
-- keadaan database yang sebenarnya, bukan catatan tentang apa yang pernah
-- dijalankan.
--
-- Jalankan berkas migrasi yang berstatus BELUM, berurutan dari nomor
-- terkecil. Semuanya aman dijalankan ulang bila ragu.
--
-- Batasnya: satu penanda hanya membuktikan sebuah migrasi PERNAH DIMULAI,
-- bukan bahwa ia tuntas. Berkas yang berhenti di tengah jalan tetap bisa
-- terbaca "sudah" bila penandanya dibuat di bagian awal. Karena itu,
-- menjalankan ulang berkas yang sudah berstatus "sudah" tidak pernah
-- merugikan — seluruh migrasi di repositori ini dirancang aman diulang.
-- ============================================================

WITH penanda(urutan, migrasi, penjelasan, ada) AS (
  VALUES
    (0, 'schema.sql', 'Tabel dasar & RLS',
        to_regclass('public.driver_daily_allocations') IS NOT NULL),

    (1, '0001_security_hardening', 'Peran tidak bisa dinaikkan sendiri',
        to_regprocedure('public.enforce_profile_field_guard()') IS NOT NULL),

    (2, '0002_live_fleet_tracking', 'Pelacakan posisi armada',
        to_regclass('public.driver_positions') IS NOT NULL),

    (3, '0003_offline_orders_and_cash_lock', 'Pesanan offline & kunci kas',
        to_regclass('public.allocation_audit_log') IS NOT NULL),

    (4, '0004_customer_profile', 'Profil pembeli pada pesanan',
        EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='orders'
                   AND column_name='customer_gender')),

    (5, '0005_cup_metrics', 'Cup dibedakan dari transaksi',
        to_regprocedure('public.order_cup_count(uuid)') IS NOT NULL),

    (6, '0006_product_inventory', 'Stok pusat per produk',
        EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='products'
                   AND column_name='stock_quantity')),

    (7, '0007_analytics_by_date', 'Analitik per tanggal & per jam',
        to_regprocedure('public.admin_sales_range(date,date)') IS NOT NULL),

    (8, '0008_account_status_enforcement', 'Akun nonaktif benar-benar ditolak',
        to_regprocedure('public.get_user_status(uuid)') IS NOT NULL),

    (9, '0009_shared_cup_definition', 'Cup driver = cup admin',
        to_regprocedure('public.driver_daily_summary()') IS NOT NULL),

    (10, '0010_sargable_date_filters', 'Kueri tanggal memakai indeks',
         to_regprocedure('public.wib_day_start(date)') IS NOT NULL),

    (11, '0011_gps_history_retention', 'Pemangkasan histori GPS',
         to_regprocedure('public.prune_location_logs_job(integer)') IS NOT NULL),

    (12, '0012_reject_stale_queued_orders', 'Pesanan antrean basi ditolak',
         EXISTS (SELECT 1 FROM pg_proc p
                  JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname='public' AND p.proname='create_order'
                   AND pg_get_functiondef(p.oid) LIKE '%ORDER_TOO_OLD%')),

    (13, '0013_return_unsold_stock', 'Sisa cup kembali ke stok otomatis',
         EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='driver_daily_allocations'
                    AND column_name='stock_returned_at')),

    (14, '0014_audit_numbers_cannot_lie', 'Angka audit mustahil ditolak',
         EXISTS (SELECT 1 FROM pg_proc p
                  JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname='public' AND p.proname='lock_reconciliation'
                   AND pg_get_functiondef(p.oid) LIKE '%AUDIT_NUMBERS_IMPOSSIBLE%')),

    (15, '0015_menu_performance', 'Analitik menu: yang laku & yang tidak',
         to_regprocedure('public.admin_menu_performance(date,date)') IS NOT NULL),

    (16, '0016_ops_analytics', 'Analitik jam & lokasi (cup per jam)',
         to_regprocedure('public.admin_cart_productivity(date,date)') IS NOT NULL),

    (17, '0017_lock_admin_functions', 'Fungsi admin tertutup untuk anon',
         NOT EXISTS (SELECT 1 FROM pg_proc p
                       JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public'
                        AND (p.proname LIKE 'admin\_%' OR p.proname = 'fleet_overview')
                        AND has_function_privilege('anon', p.oid, 'EXECUTE'))),

    (18, '0018_cluster_real_centroid', 'Titik peta = pusat pesanan asli, bukan tengah petak',
         EXISTS (SELECT 1 FROM pg_proc p
                   JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'public' AND p.proname = 'admin_location_clusters'
                    AND pg_get_functiondef(p.oid) LIKE '%spread_meters%')),

    (19, '0019_location_rate', 'Laju cup per jam per titik, dengan ambang bukti',
         EXISTS (SELECT 1 FROM pg_proc p
                   JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'public' AND p.proname = 'admin_location_clusters'
                    AND pg_get_functiondef(p.oid) LIKE '%cups_per_hour%')),

    (20, '0020_driver_stops', 'Tombol "Mangkal di sini": lama mangkal direkam, bukan ditebak',
         to_regclass('public.driver_stops') IS NOT NULL
         AND to_regprocedure('public.driver_start_stop(double precision,double precision,double precision,uuid)') IS NOT NULL),

    (21, '0021_catat_belakangan', 'Jendela catat-belakangan 30 menit (bukan 15)',
         EXISTS (SELECT 1 FROM pg_proc p
                   JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'public' AND p.proname = 'admin_location_clusters'
                    AND pg_get_functiondef(p.oid) LIKE '%30 minutes%')),

    (22, '0022_tutup_otomatis', 'Shift & mangkal yang lupa ditutup, ditutup di 21:30',
         to_regprocedure('public.tutup_yang_lupa_ditutup()') IS NOT NULL
         AND to_regprocedure('public.jam_pulang_rutin(date)') IS NOT NULL
         AND EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name = 'driver_stops'
                        AND column_name = 'auto_closed')),

    (23, '0023_booth_event', 'Booth event keluar dari analitik lokasi (tetap masuk omset)',
         to_regprocedure('public.admin_tandai_mangkal_event(uuid,boolean)') IS NOT NULL
         AND EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name = 'driver_stops'
                        AND column_name = 'is_event')),

    (24, '0024_hafal_menu', '"Sebut menu tanpa lihat" gantikan tebakan langganan',
         to_regprocedure('public.admin_hafal_menu(date,date)') IS NOT NULL
         AND EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name = 'orders'
                        AND column_name = 'cara_pesan')
         AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                          WHERE table_schema = 'public' AND table_name = 'orders'
                            AND column_name = 'customer_type')),

    (25, '0025_edit_pesanan', 'Driver bisa memperbaiki pesanan salah ketik, berjejak',
         to_regprocedure('public.driver_edit_order(uuid,jsonb)') IS NOT NULL
         AND to_regprocedure('public.driver_batal_order(uuid,text)') IS NOT NULL
         AND to_regclass('public.order_audit_log') IS NOT NULL),

    (26, '0026_edit_tak_terbatas_hari', 'Batas "hanya hari ini" dicabut; kunci rekonsiliasi yang menjaga',
         EXISTS (SELECT 1 FROM pg_proc p
                   JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'public' AND p.proname = 'boleh_ubah_pesanan'
                    AND position('ORDER_NOT_TODAY' in pg_get_functiondef(p.oid)) = 0))
)
SELECT migrasi,
       penjelasan,
       CASE WHEN ada THEN 'sudah' ELSE '>>> BELUM <<<' END AS status
  FROM penanda
 ORDER BY urutan;
