-- Pengujian migrasi 0025: driver memperbaiki pesanan yang salah ketik.
-- Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id',    '{"full_name":"Gerobak Satu"}'::jsonb),
  ('33333333-3333-3333-3333-333333333333', 'd2@ramu.id',    '{"full_name":"Gerobak Dua"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order, stock_quantity, is_available) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'KPK',     13000, 'smoothie', 1, 900, true),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'PASCA',   10000, 'smoothie', 2, 900, true);

INSERT INTO public.shifts (id, driver_id, status) VALUES
  ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'active'),
  ('cccccccc-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333', 'active');

-- Alokasi hari ini: 50 KPK, 50 PASCA.
INSERT INTO public.driver_daily_allocations (id, driver_id, date, status)
VALUES ('bbbbbbbb-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        (NOW() AT TIME ZONE 'Asia/Jakarta')::date, 'active');

INSERT INTO public.driver_allocation_items (allocation_id, product_id, initial_quantity, sold_quantity) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 50, 0),
  ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', 50, 0);

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '=== 1. Salah ketik 9, dibetulkan jadi 4 ==='
-- Kejadian nyata yang jadi alasan migrasi ini: 33 cup dicatat dalam satu
-- menit saat event, dan salah ketik di situ pasti terjadi.
DO $$
DECLARE v public.orders; v_terjual INTEGER;
BEGIN
  v := public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":9}]'::jsonb);

  SELECT sold_quantity INTO v_terjual FROM public.driver_allocation_items
   WHERE allocation_id = 'bbbbbbbb-0000-0000-0000-000000000001'
     AND product_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_terjual <> 9 THEN
    RAISE EXCEPTION 'GAGAL: stok awal terpotong %, harusnya 9', v_terjual;
  END IF;

  v := public.driver_edit_order(
    v.id, '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":4}]'::jsonb);

  IF v.total_amount <> 52000 THEN
    RAISE EXCEPTION 'GAGAL: total %, harusnya 4 x 13000 = 52000', v.total_amount;
  END IF;

  -- Inti: lima cup harus KEMBALI ke alokasi, bukan hilang jadi selisih.
  SELECT sold_quantity INTO v_terjual FROM public.driver_allocation_items
   WHERE allocation_id = 'bbbbbbbb-0000-0000-0000-000000000001'
     AND product_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_terjual <> 4 THEN
    RAISE EXCEPTION 'GAGAL: terjual %, harusnya 4 — lima cup tidak dikembalikan', v_terjual;
  END IF;

  RAISE NOTICE 'OK: 9 jadi 4, dan 5 cup kembali ke alokasi';
END;
$$;

\echo ''
\echo '=== 2. Ganti menu, bukan cuma jumlah ==='
DO $$
DECLARE v public.orders; v_kpk INTEGER; v_pasca INTEGER;
BEGIN
  v := public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":2}]'::jsonb);

  v := public.driver_edit_order(
    v.id, '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":3}]'::jsonb);

  IF v.total_amount <> 30000 THEN
    RAISE EXCEPTION 'GAGAL: total %, harusnya 3 x 10000', v.total_amount;
  END IF;

  SELECT sold_quantity INTO v_kpk FROM public.driver_allocation_items
   WHERE allocation_id = 'bbbbbbbb-0000-0000-0000-000000000001'
     AND product_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  SELECT sold_quantity INTO v_pasca FROM public.driver_allocation_items
   WHERE allocation_id = 'bbbbbbbb-0000-0000-0000-000000000001'
     AND product_id = 'aaaaaaaa-0000-0000-0000-000000000002';

  -- KPK kembali ke 4 (dari tes 1), PASCA jadi 3.
  IF v_kpk <> 4 OR v_pasca <> 3 THEN
    RAISE EXCEPTION 'GAGAL: KPK %, PASCA % — harusnya 4 dan 3', v_kpk, v_pasca;
  END IF;

  RAISE NOTICE 'OK: menu ditukar, stok kedua produk ikut benar';
END;
$$;

\echo ''
\echo '=== 3. Edit melebihi muatan gerobak ditolak, dan TIDAK merusak apa pun ==='
DO $$
DECLARE v public.orders; v_id UUID; v_total INTEGER; v_terjual INTEGER;
BEGIN
  v := public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb);
  v_id := v.id;

  BEGIN
    v := public.driver_edit_order(
      v_id, '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":9999}]'::jsonb);
    RAISE EXCEPTION 'GAGAL: edit melebihi muatan diterima';
  EXCEPTION WHEN sqlstate '22023' THEN
    IF SQLERRM NOT LIKE 'INSUFFICIENT_STOCK%' THEN RAISE; END IF;
  END;

  -- Penolakan harus mengembalikan keadaan seperti semula, bukan
  -- meninggalkan pesanan tanpa item dan stok yang sudah dikembalikan.
  SELECT total_amount INTO v_total FROM public.orders WHERE id = v_id;
  IF v_total <> 13000 THEN
    RAISE EXCEPTION 'GAGAL: total jadi % setelah edit gagal, harusnya tetap 13000', v_total;
  END IF;
  IF (SELECT count(*) FROM public.order_items WHERE order_id = v_id) <> 1 THEN
    RAISE EXCEPTION 'GAGAL: item pesanan hilang setelah edit gagal';
  END IF;

  SELECT sold_quantity INTO v_terjual FROM public.driver_allocation_items
   WHERE allocation_id = 'bbbbbbbb-0000-0000-0000-000000000001'
     AND product_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_terjual <> 5 THEN
    RAISE EXCEPTION 'GAGAL: terjual %, harusnya tetap 5 (4 + 1)', v_terjual;
  END IF;

  RAISE NOTICE 'OK: edit ditolak dan pesanan lamanya utuh — tidak ada stok yang bocor';
END;
$$;

\echo ''
\echo '=== 4. Batal mengembalikan stok dan menghapus pesanan ==='
DO $$
DECLARE v public.orders; v_id UUID; v_terjual INTEGER;
BEGIN
  v := public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":6}]'::jsonb);
  v_id := v.id;

  PERFORM public.driver_batal_order(v_id, 'dobel input');

  IF EXISTS (SELECT 1 FROM public.orders WHERE id = v_id) THEN
    RAISE EXCEPTION 'GAGAL: pesanan masih ada setelah dibatalkan';
  END IF;
  IF EXISTS (SELECT 1 FROM public.order_items WHERE order_id = v_id) THEN
    RAISE EXCEPTION 'GAGAL: item pesanan tertinggal';
  END IF;

  SELECT sold_quantity INTO v_terjual FROM public.driver_allocation_items
   WHERE allocation_id = 'bbbbbbbb-0000-0000-0000-000000000001'
     AND product_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_terjual <> 5 THEN
    RAISE EXCEPTION 'GAGAL: terjual %, harusnya kembali ke 5', v_terjual;
  END IF;

  RAISE NOTICE 'OK: pesanan hilang, enam cup kembali ke alokasi';
END;
$$;

\echo ''
\echo '=== 5. Jejaknya tersimpan, dan tetap ada setelah pesanan dihapus ==='
-- Ini yang membedakan "boleh memperbaiki" dari "boleh menghapus jejak".
SELECT action, order_number, alasan,
       sebelum->'item'->0->>'jumlah' AS jumlah_sebelum,
       COALESCE(sesudah->'item'->0->>'jumlah', '(dibatalkan)') AS jumlah_sesudah
  FROM public.order_audit_log
 ORDER BY created_at;

DO $$
DECLARE v_edit INTEGER; v_batal INTEGER; rec RECORD;
BEGIN
  SELECT count(*) INTO v_edit  FROM public.order_audit_log WHERE action = 'edit';
  SELECT count(*) INTO v_batal FROM public.order_audit_log WHERE action = 'batal';

  IF v_edit <> 2 THEN
    RAISE EXCEPTION 'GAGAL: % jejak edit, harusnya 2', v_edit;
  END IF;
  IF v_batal <> 1 THEN
    RAISE EXCEPTION 'GAGAL: % jejak batal, harusnya 1', v_batal;
  END IF;

  SELECT * INTO rec FROM public.order_audit_log WHERE action = 'batal';
  IF rec.alasan <> 'dobel input' THEN
    RAISE EXCEPTION 'GAGAL: alasan %, harusnya "dobel input"', rec.alasan;
  END IF;
  IF (rec.sebelum->'item'->0->>'jumlah')::int <> 6 THEN
    RAISE EXCEPTION 'GAGAL: potret sebelum tidak menyimpan 6 cup yang dibatalkan';
  END IF;

  RAISE NOTICE 'OK: jejak edit dan batal tersimpan, potret sebelumnya utuh';
END;
$$;

\echo ''
\echo '=== 6. Driver tidak bisa mengubah pesanan driver lain ==='
DO $$
DECLARE v public.orders; v_id UUID;
BEGIN
  SET LOCAL test.uid = '33333333-3333-3333-3333-333333333333';
  v := public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000002',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb);
  v_id := v.id;

  SET LOCAL test.uid = '11111111-1111-1111-1111-111111111111';
  BEGIN
    v := public.driver_edit_order(
      v_id, '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":99}]'::jsonb);
    RAISE EXCEPTION 'GAGAL: driver mengubah pesanan driver lain';
  EXCEPTION WHEN sqlstate '22023' THEN
    IF SQLERRM <> 'FORBIDDEN' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM public.driver_batal_order(v_id, 'iseng');
    RAISE EXCEPTION 'GAGAL: driver membatalkan pesanan driver lain';
  EXCEPTION WHEN sqlstate '22023' THEN
    IF SQLERRM <> 'FORBIDDEN' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'OK: pesanan driver lain tidak bisa disentuh';
END;
$$;

\echo ''
\echo '=== 7. Pesanan kemarin tidak bisa diubah ==='
-- Memperbaiki hari kemarin berarti menggeser angka yang mungkin sudah
-- dipakai menghitung. Itu pintu belakang ke audit kas.
RESET ROLE;
DO $$
DECLARE v_id UUID := gen_random_uuid();
BEGIN
  INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount,
                             payment_method, created_at)
  VALUES (v_id, 'cccccccc-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111', 'RMJ-KEMARIN', 13000, 'cash',
          NOW() - INTERVAL '1 day');
  INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
  VALUES (v_id, 'aaaaaaaa-0000-0000-0000-000000000001', 1, 13000, 13000);
END;
$$;

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT id INTO v_id FROM public.orders WHERE order_number = 'RMJ-KEMARIN';
  BEGIN
    PERFORM public.driver_edit_order(
      v_id, '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":5}]'::jsonb);
    RAISE EXCEPTION 'GAGAL: pesanan kemarin bisa diubah';
  EXCEPTION WHEN sqlstate '22023' THEN
    IF SQLERRM <> 'ORDER_NOT_TODAY' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'OK: pesanan kemarin ditolak';
END;
$$;

\echo ''
\echo '=== 8. Hari yang sudah direkonsiliasi terkunci ==='
RESET ROLE;
UPDATE public.driver_daily_allocations SET status = 'reconciled'
 WHERE id = 'bbbbbbbb-0000-0000-0000-000000000001';

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT id INTO v_id FROM public.orders
   WHERE driver_id = '11111111-1111-1111-1111-111111111111'
     AND order_number <> 'RMJ-KEMARIN'
   LIMIT 1;

  BEGIN
    PERFORM public.driver_edit_order(
      v_id, '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb);
    RAISE EXCEPTION 'GAGAL: hari terkunci masih bisa diedit';
  EXCEPTION WHEN sqlstate '22023' THEN
    IF SQLERRM <> 'DAY_RECONCILED' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM public.driver_batal_order(v_id, 'coba');
    RAISE EXCEPTION 'GAGAL: hari terkunci masih bisa dibatalkan';
  EXCEPTION WHEN sqlstate '22023' THEN
    IF SQLERRM <> 'DAY_RECONCILED' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'OK: setelah rekonsiliasi, angka penjualan tidak bisa digeser';
END;
$$;

\echo ''
\echo '=== 9. Jejak tidak bisa dihapus dari aplikasi ==='
DO $$
DECLARE v_sisa INTEGER;
BEGIN
  DELETE FROM public.order_audit_log;
  SELECT count(*) INTO v_sisa FROM public.order_audit_log;
  IF v_sisa = 0 THEN
    RAISE EXCEPTION 'GAGAL: jejak bisa dihapus dari aplikasi — audit jadi tidak berarti';
  END IF;
  RAISE NOTICE 'OK: % baris jejak bertahan; RLS menahan penghapusan', v_sisa;
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0025 LULUS ==='
