-- Pengujian migrasi 0003: idempotensi pesanan offline & penguncian kas.
-- Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id', '{"full_name":"Driver Satu"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'Jus Mangga', 15000, 'smoothie', 1);

INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

INSERT INTO public.driver_daily_allocations (id, driver_id, date)
VALUES ('bbbbbbbb-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        (NOW() AT TIME ZONE 'Asia/Jakarta')::date);

INSERT INTO public.driver_allocation_items (allocation_id, product_id, initial_quantity)
VALUES ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 50);

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '=== TES 1: kirim ulang pesanan antrean offline TIDAK boleh menggandakan ==='
SELECT order_number, total_amount
  FROM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":2}]'::jsonb,
    'cash', NULL, NULL, NULL, NULL,
    'dddddddd-0000-0000-0000-000000000001'::uuid);

-- Meniru driver yang mencoba lagi karena responsnya hilang di jalan.
DO $$
DECLARE i INTEGER; v_orders INTEGER; v_sold INTEGER;
BEGIN
  FOR i IN 1..5 LOOP
    PERFORM public.create_order(
      'cccccccc-0000-0000-0000-000000000001'::uuid,
      '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":2}]'::jsonb,
      'cash', NULL, NULL, NULL, NULL,
      'dddddddd-0000-0000-0000-000000000001'::uuid);
  END LOOP;

  SELECT count(*) INTO v_orders FROM public.orders;
  SELECT sold_quantity INTO v_sold FROM public.driver_allocation_items;

  IF v_orders <> 1 THEN
    RAISE EXCEPTION 'GAGAL: 6 percobaan menghasilkan % pesanan!', v_orders;
  END IF;
  IF v_sold <> 2 THEN
    RAISE EXCEPTION 'GAGAL: stok terpotong % kali, seharusnya 2 cup sekali saja', v_sold;
  END IF;
  RAISE NOTICE 'OK: 6 percobaan dengan kunci sama -> 1 pesanan, stok terpotong 2 cup';
END;
$$;

\echo ''
\echo '=== TES 2: kunci berbeda tetap membuat pesanan baru ==='
SELECT order_number FROM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
    'cash', NULL, NULL, NULL, NULL,
    'dddddddd-0000-0000-0000-000000000002'::uuid);
SELECT count(*) AS jumlah_pesanan FROM public.orders;

\echo ''
\echo '=== TES 3: waktu transaksi antrean dipertahankan ==='
SELECT (created_at < NOW() - INTERVAL '30 minutes') AS waktu_asli_dipakai
  FROM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
    'cash', NULL, NULL, NULL, NULL,
    'dddddddd-0000-0000-0000-000000000003'::uuid,
    NOW() - INTERVAL '45 minutes');

\echo ''
\echo '=== TES 4: waktu yang tidak masuk akal diabaikan (anti sisip mundur) ==='
SELECT (created_at > NOW() - INTERVAL '5 minutes') AS waktu_dikoreksi_ke_sekarang
  FROM public.create_order(
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
    'cash', NULL, NULL, NULL, NULL,
    'dddddddd-0000-0000-0000-000000000004'::uuid,
    NOW() - INTERVAL '300 days');

\echo ''
\echo '=== TES 5: driver TIDAK boleh mengunci rekonsiliasi ==='
DO $$
BEGIN
  PERFORM public.lock_reconciliation('bbbbbbbb-0000-0000-0000-000000000001'::uuid);
  RAISE EXCEPTION 'GAGAL: driver berhasil mengunci audit kas!';
EXCEPTION
  WHEN insufficient_privilege THEN RAISE NOTICE 'OK ditolak: %', SQLERRM;
END;
$$;

\echo ''
\echo '=== TES 6: admin mengunci rekonsiliasi ==='
SET test.uid = '22222222-2222-2222-2222-222222222222';
RESET ROLE;
UPDATE public.driver_daily_allocations
   SET total_cash_collected = 60000, cash_settled = 58000
 WHERE id = 'bbbbbbbb-0000-0000-0000-000000000001';
SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

SELECT status, (reconciled_by IS NOT NULL) AS penanggung_jawab_tercatat
  FROM public.lock_reconciliation('bbbbbbbb-0000-0000-0000-000000000001'::uuid, 'Selisih 2.000 disepakati');

\echo ''
\echo '=== TES 7: angka kas TIDAK bisa diubah setelah dikunci ==='
DO $$
BEGIN
  UPDATE public.driver_daily_allocations
     SET cash_settled = 999999
   WHERE id = 'bbbbbbbb-0000-0000-0000-000000000001';
  RAISE EXCEPTION 'GAGAL: kas terkunci masih bisa diubah!';
EXCEPTION
  WHEN insufficient_privilege THEN RAISE NOTICE 'OK ditolak: %', SQLERRM;
END;
$$;

\echo ''
\echo '=== TES 8: angka stok TIDAK bisa diubah setelah dikunci ==='
DO $$
BEGIN
  UPDATE public.driver_allocation_items
     SET physical_remaining = 0
   WHERE allocation_id = 'bbbbbbbb-0000-0000-0000-000000000001';
  RAISE EXCEPTION 'GAGAL: stok terkunci masih bisa diubah!';
EXCEPTION
  WHEN insufficient_privilege THEN RAISE NOTICE 'OK ditolak: %', SQLERRM;
END;
$$;

\echo ''
\echo '=== TES 9: admin boleh membuka kunci, dan pembukaannya tercatat ==='
UPDATE public.driver_daily_allocations
   SET status = 'active'
 WHERE id = 'bbbbbbbb-0000-0000-0000-000000000001';

SELECT action, (actor_id IS NOT NULL) AS pelaku_tercatat, cash_settled, cash_expected
  FROM public.allocation_audit_log
 ORDER BY created_at;

\echo ''
\echo '=== TES 10: setelah dibuka, angka bisa dikoreksi lagi ==='
UPDATE public.driver_daily_allocations
   SET cash_settled = 60000
 WHERE id = 'bbbbbbbb-0000-0000-0000-000000000001';
SELECT cash_settled AS kas_setelah_koreksi
  FROM public.driver_daily_allocations
 WHERE id = 'bbbbbbbb-0000-0000-0000-000000000001';

\echo ''
\echo '=== TES 11: ringkasan dashboard dalam satu query ==='
SELECT orders_today, revenue_today, cash_today, active_drivers, total_drivers
  FROM public.admin_daily_summary();

\echo ''
\echo '=== TES 12: driver tidak mendapat ringkasan dashboard ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.admin_daily_summary();
  IF n > 0 THEN
    RAISE EXCEPTION 'GAGAL: driver mendapat % baris ringkasan admin!', n;
  END IF;
  RAISE NOTICE 'OK: ringkasan admin kosong untuk driver';
END;
$$;
