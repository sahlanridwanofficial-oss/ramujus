-- Pengujian migrasi 0007: analitik per hari/tanggal & cup yang tidak nol
-- diam-diam. Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id', '{"full_name":"Driver Satu"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Jus Mangga',   15000, 'smoothie', 1),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'Jus Alpukat',  20000, 'smoothie', 2),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'Topping Keju',  5000, 'topping',  3);

INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

-- Tanggal acuan: kalender WIB, sama seperti yang dipakai seluruh fungsi.
\echo ''
\echo '=== Menyemai penjualan: hari ini, H-2 (23:30 WIB), H-3 (00:30 WIB); H-1 sengaja kosong ==='

-- Hari ini lewat jalur nyata (create_order), sebagai driver.
SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
BEGIN
  -- 3 cup mangga + 1 topping  -> 3 cup, 4 item, Rp50.000
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":3},
      {"product_id":"aaaaaaaa-0000-0000-0000-000000000003","quantity":1}]'::jsonb);
  -- 2 cup alpukat            -> 2 cup, 2 item, Rp40.000
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":2}]'::jsonb);
END;
$$;
RESET ROLE;

-- Hari-hari sebelumnya disisipkan langsung: create_order sengaja menolak
-- tanggal yang jauh mundur, jadi riwayat dibuat di sini sebagai pemilik tabel.
-- Jam ditulis eksplisit di ujung hari WIB untuk menguji batas tengah malam.
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  -- H-2, 23:30 WIB — 4 cup mangga, QRIS
  INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount, payment_method, created_at)
  VALUES ('dddddddd-0000-0000-0000-000000000002',
          'cccccccc-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111',
          'RMJ-TEST-H2', 60000, 'qris',
          ((v_today - 2)::timestamp + INTERVAL '23 hours 30 minutes') AT TIME ZONE 'Asia/Jakarta');
  INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
  VALUES ('dddddddd-0000-0000-0000-000000000002',
          'aaaaaaaa-0000-0000-0000-000000000001', 4, 15000, 60000);

  -- H-3, 00:30 WIB — 1 cup alpukat + 2 topping, transfer
  INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount, payment_method, created_at)
  VALUES ('dddddddd-0000-0000-0000-000000000003',
          'cccccccc-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111',
          'RMJ-TEST-H3', 30000, 'transfer',
          ((v_today - 3)::timestamp + INTERVAL '30 minutes') AT TIME ZONE 'Asia/Jakarta');
  INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal) VALUES
    ('dddddddd-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000002', 1, 20000, 20000),
    ('dddddddd-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000003', 2,  5000, 10000);
END;
$$;

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

-- ------------------------------------------------------------
\echo ''
\echo '=== 1. admin_daily_summary: cup dan item hari ini adalah dua angka ==='
SELECT orders_today, cups_today, items_today, revenue_today FROM public.admin_daily_summary();
DO $$
DECLARE o INTEGER; c INTEGER; i INTEGER; r BIGINT;
BEGIN
  SELECT orders_today, cups_today, items_today, revenue_today
    INTO o, c, i, r FROM public.admin_daily_summary();
  IF o <> 2 THEN RAISE EXCEPTION 'GAGAL: transaksi = %, harusnya 2', o; END IF;
  IF c <> 5 THEN RAISE EXCEPTION 'GAGAL: cup = %, harusnya 5', c; END IF;
  IF i <> 6 THEN RAISE EXCEPTION 'GAGAL: item = %, harusnya 6 (topping ikut item)', i; END IF;
  IF r <> 90000 THEN RAISE EXCEPTION 'GAGAL: omzet = %, harusnya 90000', r; END IF;
  RAISE NOTICE 'OK: 2 transaksi, 5 cup, 6 item, Rp90.000 — cup terjual TIDAK nol';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 2. admin_sales_range: satu baris per TANGGAL, hari kosong ikut ==='
SELECT day, orders, cups, items, revenue, cash_revenue, qris_revenue, transfer_revenue
  FROM public.admin_sales_range(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 3,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date);
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
        n INTEGER; rec RECORD;
BEGIN
  SELECT count(*) INTO n FROM public.admin_sales_range(v_today - 3, v_today);
  IF n <> 4 THEN RAISE EXCEPTION 'GAGAL: % baris, harusnya 4 tanggal berurutan', n; END IF;

  -- H-1 tidak punya transaksi sama sekali; barisnya tetap harus ada, berisi nol.
  SELECT * INTO rec FROM public.admin_sales_range(v_today - 3, v_today) WHERE day = v_today - 1;
  IF rec IS NULL THEN RAISE EXCEPTION 'GAGAL: hari tanpa transaksi hilang dari tren'; END IF;
  IF rec.orders <> 0 OR rec.cups <> 0 OR rec.revenue <> 0 THEN
    RAISE EXCEPTION 'GAGAL: hari kosong tidak nol (%)', rec;
  END IF;

  -- Transaksi 23:30 WIB milik H-2, bukan H-1 (UTC-nya sudah lewat tengah malam).
  SELECT * INTO rec FROM public.admin_sales_range(v_today - 3, v_today) WHERE day = v_today - 2;
  IF rec.orders <> 1 OR rec.cups <> 4 OR rec.revenue <> 60000 OR rec.qris_revenue <> 60000 THEN
    RAISE EXCEPTION 'GAGAL H-2: %', rec;
  END IF;

  -- Transaksi 00:30 WIB milik H-3, bukan H-4.
  SELECT * INTO rec FROM public.admin_sales_range(v_today - 3, v_today) WHERE day = v_today - 3;
  IF rec.orders <> 1 OR rec.cups <> 1 OR rec.items <> 3 OR rec.transfer_revenue <> 30000 THEN
    RAISE EXCEPTION 'GAGAL H-3: %', rec;
  END IF;

  SELECT * INTO rec FROM public.admin_sales_range(v_today - 3, v_today) WHERE day = v_today;
  IF rec.orders <> 2 OR rec.cups <> 5 OR rec.items <> 6 OR rec.cash_revenue <> 90000 THEN
    RAISE EXCEPTION 'GAGAL hari ini: %', rec;
  END IF;

  RAISE NOTICE 'OK: 4 tanggal berurutan, hari kosong tetap tampil, batas tengah malam WIB benar';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 3. Rentang terbalik dirapikan, bukan mengembalikan kosong ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.admin_sales_range(v_today, v_today - 3);
  IF n <> 4 THEN RAISE EXCEPTION 'GAGAL: rentang terbalik menghasilkan % baris', n; END IF;
  RAISE NOTICE 'OK: dari/sampai tertukar tetap menghasilkan 4 tanggal';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 4. admin_sales_hourly: 24 jam, jam sepi tetap ada ==='
SELECT hour, orders, cups, revenue
  FROM public.admin_sales_hourly((NOW() AT TIME ZONE 'Asia/Jakarta')::date - 2)
 WHERE orders > 0;
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; n INTEGER; rec RECORD;
BEGIN
  SELECT count(*) INTO n FROM public.admin_sales_hourly(v_today - 2);
  IF n <> 24 THEN RAISE EXCEPTION 'GAGAL: % baris jam, harusnya 24', n; END IF;

  SELECT * INTO rec FROM public.admin_sales_hourly(v_today - 2) WHERE hour = 23;
  IF rec.orders <> 1 OR rec.cups <> 4 THEN RAISE EXCEPTION 'GAGAL jam 23 H-2: %', rec; END IF;

  SELECT * INTO rec FROM public.admin_sales_hourly(v_today - 3) WHERE hour = 0;
  IF rec.orders <> 1 OR rec.cups <> 1 THEN RAISE EXCEPTION 'GAGAL jam 00 H-3: %', rec; END IF;

  SELECT count(*) INTO n FROM public.admin_sales_hourly(v_today - 1) WHERE orders > 0;
  IF n <> 0 THEN RAISE EXCEPTION 'GAGAL: hari kosong punya % jam berisi', n; END IF;

  RAISE NOTICE 'OK: jam ramai jatuh pada jam WIB yang benar, 24 baris penuh';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 5. admin_top_products_range: mengikuti rentang tanggal & membawa kategori ==='
SELECT name, category, total_qty, revenue
  FROM public.admin_top_products_range(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 3,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date, 10);
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_top_products_range(v_today - 3, v_today, 10)
   WHERE name = 'Jus Mangga';
  IF rec.total_qty <> 7 OR rec.category <> 'smoothie' THEN
    RAISE EXCEPTION 'GAGAL: mangga % (%), harusnya 7 smoothie', rec.total_qty, rec.category;
  END IF;

  -- Rentang hanya hari ini: mangga tinggal 3.
  SELECT * INTO rec FROM public.admin_top_products_range(v_today, v_today, 10)
   WHERE name = 'Jus Mangga';
  IF rec.total_qty <> 3 THEN RAISE EXCEPTION 'GAGAL: mangga hari ini = %', rec.total_qty; END IF;

  RAISE NOTICE 'OK: peringkat produk mengikuti rentang tanggal yang dipilih';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 6. admin_sales_daily kini kalender WIB, bukan jendela 168 jam ==='
DO $$
DECLARE n INTEGER; v_cups INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.admin_sales_daily(4);
  IF n <> 4 THEN RAISE EXCEPTION 'GAGAL: admin_sales_daily(4) = % baris', n; END IF;

  SELECT sum(cups) INTO v_cups FROM public.admin_sales_daily(4);
  IF v_cups <> 10 THEN RAISE EXCEPTION 'GAGAL: total cup 4 hari = %, harusnya 10', v_cups; END IF;

  SELECT sum(cups) INTO v_cups FROM public.admin_sales_daily(1);
  IF v_cups <> 5 THEN RAISE EXCEPTION 'GAGAL: cup hari ini = %, harusnya 5', v_cups; END IF;

  RAISE NOTICE 'OK: N hari = N tanggal kalender WIB, hari berjalan utuh';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 7. admin_report_summary: cup dan item atas seluruh rentang ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_report_summary(v_today - 3, v_today);
  IF rec.orders <> 4 OR rec.cups <> 10 OR rec.items <> 13 OR rec.revenue <> 180000 THEN
    RAISE EXCEPTION 'GAGAL ringkasan laporan: %', rec;
  END IF;
  IF rec.qris_revenue <> 60000 OR rec.transfer_revenue <> 30000 OR rec.cash_revenue <> 90000 THEN
    RAISE EXCEPTION 'GAGAL rincian pembayaran: %', rec;
  END IF;
  RAISE NOTICE 'OK: 4 transaksi, 10 cup, 13 item, Rp180.000';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 8. Salah kategori terbaca: cup tetap, item naik ==='
RESET ROLE;
INSERT INTO public.products (id, name, price, category, sort_order)
VALUES ('aaaaaaaa-0000-0000-0000-000000000004', 'Jus Botol Salah Kategori', 12000, 'addon', 4);
SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
BEGIN
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":2}]'::jsonb);
END;
$$;
SET test.uid = '22222222-2222-2222-2222-222222222222';
DO $$
DECLARE c INTEGER; i INTEGER;
BEGIN
  SELECT cups_today, items_today INTO c, i FROM public.admin_daily_summary();
  IF c <> 5 THEN RAISE EXCEPTION 'GAGAL: produk addon ikut terhitung cup (%)', c; END IF;
  IF i <> 8 THEN RAISE EXCEPTION 'GAGAL: item = %, harusnya 8', i; END IF;
  RAISE NOTICE 'OK: cup=5 item=8 — selisihnya menunjukkan produk salah kategori, bukan data hilang';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 9. Driver tidak mendapat analitik admin (nol baris) ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; a INTEGER; b INTEGER; c INTEGER; d INTEGER;
BEGIN
  SELECT count(*) INTO a FROM public.admin_sales_range(v_today - 3, v_today);
  SELECT count(*) INTO b FROM public.admin_sales_hourly(v_today);
  SELECT count(*) INTO c FROM public.admin_top_products_range(v_today - 3, v_today, 10);
  SELECT count(*) INTO d FROM public.admin_daily_summary();
  IF a <> 0 OR b <> 0 OR c <> 0 OR d <> 0 THEN
    RAISE EXCEPTION 'GAGAL: driver melihat analitik admin (%, %, %, %)', a, b, c, d;
  END IF;
  RAISE NOTICE 'OK: seluruh analitik tertutup untuk driver';
END;
$$;

RESET ROLE;
\echo ''
\echo '=== SEMUA UJI 08 LULUS ==='
