-- Pengujian migrasi 0009: driver dan admin memakai definisi cup yang sama.
-- Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id', '{"full_name":"Driver Satu"}'::jsonb),
  ('33333333-3333-3333-3333-333333333333', 'd2@ramu.id', '{"full_name":"Driver Dua"}'::jsonb),
  ('44444444-4444-4444-4444-444444444444', 'd3@ramu.id', '{"full_name":"Driver Tiga"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Jus Mangga',   15000, 'smoothie', 1),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'Jus Alpukat',  20000, 'smoothie', 2),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'Topping Keju',  5000, 'topping',  3);

INSERT INTO public.shifts (id, driver_id, status) VALUES
  ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'active'),
  ('cccccccc-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333', 'active');

-- PENTING: tidak ada driver_daily_allocations yang disemai di sini, dan
-- tidak ada satu cup pun muatan yang dicatat admin. Justru itu keadaan yang
-- membuat angka lama berbeda — sold_quantity tidak pernah bertambah karena
-- tidak ada alokasi untuk dinaikkan.
--
-- Sejak 0028 create_order membuatkan barisnya sendiri saat penjualan pertama
-- masuk, jadi barisnya akan ada — tapi dengan initial_quantity 0, yang
-- artinya tetap tidak ada muatan yang pernah tercatat. Itulah keadaan yang
-- diuji berkas ini.

SET ROLE authenticated;

\echo ''
\echo '=== Menjual hari ini TANPA muatan gerobak yang dicatat admin ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
BEGIN
  -- 3 cup mangga + 1 topping -> 3 cup, 4 item, Rp50.000
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":3},
      {"product_id":"aaaaaaaa-0000-0000-0000-000000000003","quantity":1}]'::jsonb);
  -- 2 cup alpukat -> 2 cup, 2 item, Rp40.000
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":2}]'::jsonb);
END;
$$;

SET test.uid = '33333333-3333-3333-3333-333333333333';
DO $$
BEGIN
  -- 1 cup mangga -> 1 cup, 1 item, Rp15.000
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000002'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb);
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 1. Tanpa muatan dicatat, driver tetap melihat cup yang benar (bug yang dilaporkan) ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
SELECT orders_today, cups_today, items_today, revenue_today FROM public.driver_daily_summary();
DO $$
DECLARE o INTEGER; c INTEGER; i INTEGER; r BIGINT; v_alloc INTEGER; v_muatan INTEGER;
BEGIN
  -- Sejak 0028 hari yang belum dialokasikan DIBUATKAN barisnya oleh
  -- create_order, jadi "nol baris alokasi" tidak mungkin lagi. Yang diuji
  -- di sini tetap sama isinya: driver melihat cup yang benar walau MUATAN
  -- gerobaknya tidak pernah dicatat siapa pun. Prasyaratnya yang berubah
  -- bentuk — dari "tidak ada barisnya" jadi "barisnya lahir dari penjualan,
  -- muatannya 0".
  SELECT count(*) INTO v_alloc FROM public.driver_daily_allocations
   WHERE NOT dibuat_otomatis;
  IF v_alloc <> 0 THEN
    RAISE EXCEPTION 'Prasyarat uji salah: ada % alokasi yang dicatat admin', v_alloc;
  END IF;

  SELECT COALESCE(sum(initial_quantity), 0) INTO v_muatan
    FROM public.driver_allocation_items;
  IF v_muatan <> 0 THEN
    RAISE EXCEPTION 'Prasyarat uji salah: ada % cup muatan tercatat', v_muatan;
  END IF;

  SELECT orders_today, cups_today, items_today, revenue_today
    INTO o, c, i, r FROM public.driver_daily_summary();

  IF c <> 5 THEN
    RAISE EXCEPTION 'GAGAL: cup driver = %, harusnya 5 walau tanpa alokasi muatan', c;
  END IF;
  IF o <> 2 OR i <> 6 OR r <> 90000 THEN
    RAISE EXCEPTION 'GAGAL: transaksi=% item=% omzet=%', o, i, r;
  END IF;
  RAISE NOTICE 'OK: 5 cup, 6 item, 2 transaksi, Rp90.000 — tanpa satu cup pun muatan tercatat';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 2. Angka driver dan angka admin cocok persis ==='
DO $$
DECLARE d1_cups INTEGER; d2_cups INTEGER; admin_cups INTEGER;
        d1_items INTEGER; d2_items INTEGER; admin_items INTEGER;
BEGIN
  SET LOCAL test.uid = '11111111-1111-1111-1111-111111111111';
  SELECT cups_today, items_today INTO d1_cups, d1_items FROM public.driver_daily_summary();

  SET LOCAL test.uid = '33333333-3333-3333-3333-333333333333';
  SELECT cups_today, items_today INTO d2_cups, d2_items FROM public.driver_daily_summary();

  SET LOCAL test.uid = '22222222-2222-2222-2222-222222222222';
  SELECT cups_today, items_today INTO admin_cups, admin_items FROM public.admin_daily_summary();

  IF d1_cups + d2_cups <> admin_cups THEN
    RAISE EXCEPTION 'GAGAL: cup driver (%+%) <> cup admin (%)', d1_cups, d2_cups, admin_cups;
  END IF;
  IF d1_items + d2_items <> admin_items THEN
    RAISE EXCEPTION 'GAGAL: item driver (%+%) <> item admin (%)', d1_items, d2_items, admin_items;
  END IF;
  RAISE NOTICE 'OK: % + % = % cup — dua layar, satu definisi', d1_cups, d2_cups, admin_cups;
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 3. Driver hanya melihat angkanya sendiri ==='
SET test.uid = '33333333-3333-3333-3333-333333333333';
DO $$
DECLARE c INTEGER; r BIGINT;
BEGIN
  SELECT cups_today, revenue_today INTO c, r FROM public.driver_daily_summary();
  IF c <> 1 OR r <> 15000 THEN
    RAISE EXCEPTION 'GAGAL: Driver Dua melihat % cup / Rp% — harusnya 1 cup / Rp15.000', c, r;
  END IF;
  RAISE NOTICE 'OK: Driver Dua melihat 1 cup, bukan 6 cup milik seluruh armada';
END;
$$;

\echo ''
\echo '=== 4. Driver tanpa penjualan mendapat nol, bukan galat ==='
SET test.uid = '44444444-4444-4444-4444-444444444444';
DO $$
DECLARE n INTEGER; c INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.driver_daily_summary();
  IF n <> 1 THEN RAISE EXCEPTION 'GAGAL: % baris, harusnya tepat 1', n; END IF;
  SELECT cups_today INTO c FROM public.driver_daily_summary();
  IF c <> 0 THEN RAISE EXCEPTION 'GAGAL: cup = %, harusnya 0', c; END IF;
  RAISE NOTICE 'OK: satu baris berisi nol, bukan tabel kosong yang harus ditebak klien';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== Menyemai riwayat H-2 untuk Driver Satu (4 cup mangga) ==='
RESET ROLE;
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount, payment_method, created_at)
  VALUES ('dddddddd-0000-0000-0000-000000000002',
          'cccccccc-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111',
          'RMJ-TEST-H2', 60000, 'qris',
          ((v_today - 2)::timestamp + INTERVAL '10 hours') AT TIME ZONE 'Asia/Jakarta');
  INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
  VALUES ('dddddddd-0000-0000-0000-000000000002',
          'aaaaaaaa-0000-0000-0000-000000000001', 4, 15000, 60000);
END;
$$;
SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== 5. admin_driver_stats_range: cup per mitra pada rentang tanggal ==='
SELECT p.full_name, s.orders, s.cups, s.items, s.revenue, s.active_days
  FROM public.admin_driver_stats_range(
         (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 2,
         (NOW() AT TIME ZONE 'Asia/Jakarta')::date) s
  JOIN public.profiles p ON p.id = s.driver_id
 ORDER BY p.full_name;
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_driver_stats_range(v_today - 2, v_today)
   WHERE driver_id = '11111111-1111-1111-1111-111111111111';
  IF rec.orders <> 3 OR rec.cups <> 9 OR rec.items <> 10 OR rec.revenue <> 150000 THEN
    RAISE EXCEPTION 'GAGAL Driver Satu: %', rec;
  END IF;
  IF rec.active_days <> 2 THEN
    RAISE EXCEPTION 'GAGAL: hari aktif = %, harusnya 2 (hari ini dan H-2)', rec.active_days;
  END IF;
  IF NOT rec.has_active_shift THEN RAISE EXCEPTION 'GAGAL: shift aktif tidak terbaca'; END IF;

  SELECT * INTO rec FROM public.admin_driver_stats_range(v_today - 2, v_today)
   WHERE driver_id = '33333333-3333-3333-3333-333333333333';
  IF rec.orders <> 1 OR rec.cups <> 1 OR rec.active_days <> 1 THEN
    RAISE EXCEPTION 'GAGAL Driver Dua: %', rec;
  END IF;

  RAISE NOTICE 'OK: cup, item, omzet, dan hari aktif benar per mitra';
END;
$$;

\echo ''
\echo '=== 6. Mitra tanpa penjualan tetap muncul sebagai baris nol ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; rec RECORD; n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.admin_driver_stats_range(v_today - 2, v_today);
  IF n <> 3 THEN RAISE EXCEPTION 'GAGAL: % baris, harusnya 3 mitra', n; END IF;

  SELECT * INTO rec FROM public.admin_driver_stats_range(v_today - 2, v_today)
   WHERE driver_id = '44444444-4444-4444-4444-444444444444';
  IF rec.orders <> 0 OR rec.cups <> 0 OR rec.revenue <> 0 OR rec.last_order_at IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: mitra tanpa penjualan tidak nol (%)', rec;
  END IF;
  RAISE NOTICE 'OK: gerobak yang tidak menjual apa pun tetap terdaftar — itu informasi';
END;
$$;

\echo ''
\echo '=== 7. Rentang benar-benar mempersempit: hari ini saja ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_driver_stats_range(v_today, v_today)
   WHERE driver_id = '11111111-1111-1111-1111-111111111111';
  IF rec.cups <> 5 OR rec.orders <> 2 OR rec.active_days <> 1 THEN
    RAISE EXCEPTION 'GAGAL rentang hari ini: %', rec;
  END IF;

  -- Rentang terbalik dirapikan, sejalan dengan admin_sales_range.
  SELECT * INTO rec FROM public.admin_driver_stats_range(v_today, v_today - 2)
   WHERE driver_id = '11111111-1111-1111-1111-111111111111';
  IF rec.cups <> 9 THEN RAISE EXCEPTION 'GAGAL rentang terbalik: %', rec; END IF;

  RAISE NOTICE 'OK: 5 cup hari ini, 9 cup tiga hari — rentang tanggal benar-benar dipakai';
END;
$$;

\echo ''
\echo '=== 8. Jumlah per mitra sama dengan total armada di analitik ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
        v_per_driver INTEGER; v_fleet INTEGER;
BEGIN
  SELECT sum(cups) INTO v_per_driver
    FROM public.admin_driver_stats_range(v_today - 2, v_today);
  SELECT sum(cups) INTO v_fleet
    FROM public.admin_sales_range(v_today - 2, v_today);
  IF v_per_driver <> v_fleet THEN
    RAISE EXCEPTION 'GAGAL: total per mitra = %, total armada = %', v_per_driver, v_fleet;
  END IF;
  RAISE NOTICE 'OK: % cup, dihitung per mitra maupun per tanggal', v_fleet;
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 9. Driver tidak dapat membaca statistik mitra lain ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.admin_driver_stats_range(v_today - 2, v_today);
  IF n <> 0 THEN RAISE EXCEPTION 'GAGAL: driver melihat % baris statistik armada', n; END IF;
  RAISE NOTICE 'OK: statistik per mitra tertutup untuk driver';
END;
$$;

RESET ROLE;
\echo ''
\echo '=== SEMUA UJI 10 LULUS ==='
