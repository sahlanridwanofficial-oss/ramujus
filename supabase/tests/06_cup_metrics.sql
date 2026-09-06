-- Pengujian migrasi 0005: metrik cup vs transaksi. Bukan bagian aplikasi.
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
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Jus Mangga', 15000, 'smoothie', 1),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'Jus Alpukat', 20000, 'smoothie', 2),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'Topping Keju', 5000, 'topping', 3);

INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '=== Membuat 3 TRANSAKSI berisi total 9 CUP + 2 topping ==='
DO $$
BEGIN
  -- Transaksi 1: 3 mangga + 1 topping  -> 3 cup
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":3},
      {"product_id":"aaaaaaaa-0000-0000-0000-000000000003","quantity":1}]'::jsonb);
  -- Transaksi 2: 4 alpukat            -> 4 cup
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":4}]'::jsonb);
  -- Transaksi 3: 2 mangga + 1 topping -> 2 cup
  PERFORM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":2},
      {"product_id":"aaaaaaaa-0000-0000-0000-000000000003","quantity":1}]'::jsonb);
END;
$$;

SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== admin_daily_summary: 3 transaksi, 9 cup (topping tidak dihitung) ==='
SELECT orders_today, cups_today, revenue_today FROM public.admin_daily_summary();
DO $$
DECLARE v_orders INTEGER; v_cups INTEGER;
BEGIN
  SELECT orders_today, cups_today INTO v_orders, v_cups FROM public.admin_daily_summary();
  IF v_orders <> 3 THEN RAISE EXCEPTION 'GAGAL: transaksi = %, harusnya 3', v_orders; END IF;
  IF v_cups <> 9 THEN RAISE EXCEPTION 'GAGAL: cup = %, harusnya 9 (topping tidak dihitung)', v_cups; END IF;
  RAISE NOTICE 'OK: transaksi=3, cup=9 — cup dan transaksi angka berbeda, topping dikecualikan';
END;
$$;

\echo ''
\echo '=== admin_sales_daily: cup per hari ==='
SELECT day, orders, cups, revenue FROM public.admin_sales_daily(7);
DO $$
DECLARE v_orders INTEGER; v_cups INTEGER;
BEGIN
  SELECT sum(orders), sum(cups) INTO v_orders, v_cups FROM public.admin_sales_daily(7);
  IF v_orders <> 3 OR v_cups <> 9 THEN
    RAISE EXCEPTION 'GAGAL sales_daily: orders=% cups=%, harusnya 3 dan 9', v_orders, v_cups;
  END IF;
  RAISE NOTICE 'OK: tren harian orders=3, cups=9';
END;
$$;

\echo ''
\echo '=== fleet_overview: cups_today per gerobak ==='
SELECT full_name, orders_today, cups_today, revenue_today FROM public.fleet_overview();
DO $$
DECLARE v_orders INTEGER; v_cups INTEGER;
BEGIN
  SELECT orders_today, cups_today INTO v_orders, v_cups
    FROM public.fleet_overview() WHERE driver_id = '11111111-1111-1111-1111-111111111111';
  IF v_orders <> 3 OR v_cups <> 9 THEN
    RAISE EXCEPTION 'GAGAL fleet: orders=% cups=%, harusnya 3 dan 9', v_orders, v_cups;
  END IF;
  RAISE NOTICE 'OK: gerobak orders=3, cups=9';
END;
$$;

\echo ''
\echo '=== admin_report_summary: ringkasan rentang, cup benar ==='
SELECT orders, cups, revenue, cash_revenue FROM public.admin_report_summary(
  (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1,
  (NOW() AT TIME ZONE 'Asia/Jakarta')::date + 1);
DO $$
DECLARE v_orders INTEGER; v_cups INTEGER; v_rev BIGINT;
BEGIN
  SELECT orders, cups, revenue INTO v_orders, v_cups, v_rev
    FROM public.admin_report_summary(
      (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1,
      (NOW() AT TIME ZONE 'Asia/Jakarta')::date + 1);
  -- revenue = 3*15000+5000 + 4*20000 + 2*15000+5000 = 50000+80000+35000 = 165000
  IF v_orders <> 3 OR v_cups <> 9 THEN
    RAISE EXCEPTION 'GAGAL report: orders=% cups=%', v_orders, v_cups;
  END IF;
  IF v_rev <> 165000 THEN
    RAISE EXCEPTION 'GAGAL report: revenue=%, harusnya 165000', v_rev;
  END IF;
  RAISE NOTICE 'OK: ringkasan laporan orders=3, cups=9, revenue=165000';
END;
$$;

\echo ''
\echo '=== order_cup_count: satu pesanan multi-cup ==='
DO $$
DECLARE v UUID; n INTEGER;
BEGIN
  SELECT id INTO v FROM public.orders ORDER BY total_amount DESC LIMIT 1; -- transaksi 3 cup mangga? cari yg 4 alpukat=80000
  SELECT public.order_cup_count(v) INTO n;
  RAISE NOTICE 'order_cup_count pesanan omzet tertinggi = % cup', n;
END;
$$;

\echo ''
\echo '=== driver tidak boleh membaca ringkasan/laporan ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE a INTEGER; b INTEGER;
BEGIN
  SELECT count(*) INTO a FROM public.admin_daily_summary();
  SELECT count(*) INTO b FROM public.admin_report_summary(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date);
  IF a > 0 OR b > 0 THEN
    RAISE EXCEPTION 'GAGAL: driver mendapat ringkasan admin (summary=%, report=%)', a, b;
  END IF;
  RAISE NOTICE 'OK: ringkasan & laporan kosong untuk driver';
END;
$$;
