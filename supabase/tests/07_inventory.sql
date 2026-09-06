-- Pengujian migrasi 0006: inventori stok per produk. Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id', '{"full_name":"Driver Satu"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order, low_stock_threshold) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Jus Mangga', 15000, 'smoothie', 1, 10),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'Jus Alpukat', 20000, 'smoothie', 2, 10);

INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== TES 1: restock menaikkan stok & mencatat pergerakan ==='
SELECT stock_quantity FROM public.adjust_product_stock('aaaaaaaa-0000-0000-0000-000000000001', 100, 'restock', 'Produksi pagi');
SELECT stock_quantity FROM public.adjust_product_stock('aaaaaaaa-0000-0000-0000-000000000002', 50, 'restock', NULL);
DO $$
DECLARE s INTEGER; m INTEGER;
BEGIN
  SELECT stock_quantity INTO s FROM public.products WHERE id='aaaaaaaa-0000-0000-0000-000000000001';
  SELECT count(*) INTO m FROM public.stock_movements WHERE reason='restock';
  IF s <> 100 THEN RAISE EXCEPTION 'GAGAL: stok = %, harusnya 100', s; END IF;
  IF m <> 2 THEN RAISE EXCEPTION 'GAGAL: pergerakan restock = %, harusnya 2', m; END IF;
  RAISE NOTICE 'OK: restock -> stok 100, 2 pergerakan tercatat';
END; $$;

\echo ''
\echo '=== TES 2: muat gerobak mengurangi stok pusat ==='
SELECT (public.save_morning_allocation(
  '11111111-1111-1111-1111-111111111111', (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
  '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","initial_quantity":30},
    {"product_id":"aaaaaaaa-0000-0000-0000-000000000002","initial_quantity":20}]'::jsonb)).status AS alokasi_status;
DO $$
DECLARE s1 INTEGER; s2 INTEGER;
BEGIN
  SELECT stock_quantity INTO s1 FROM public.products WHERE id='aaaaaaaa-0000-0000-0000-000000000001';
  SELECT stock_quantity INTO s2 FROM public.products WHERE id='aaaaaaaa-0000-0000-0000-000000000002';
  IF s1 <> 70 OR s2 <> 30 THEN RAISE EXCEPTION 'GAGAL: stok setelah muat = %/%, harusnya 70/30', s1, s2; END IF;
  RAISE NOTICE 'OK: muat 30+20 -> stok pusat 70/30';
END; $$;

\echo ''
\echo '=== TES 3: menyimpan alokasi yang sama lagi TIDAK menggeser stok (idempoten) ==='
DO $$
DECLARE s1 INTEGER;
BEGIN
  PERFORM public.save_morning_allocation(
    '11111111-1111-1111-1111-111111111111', (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","initial_quantity":30},
      {"product_id":"aaaaaaaa-0000-0000-0000-000000000002","initial_quantity":20}]'::jsonb);
  SELECT stock_quantity INTO s1 FROM public.products WHERE id='aaaaaaaa-0000-0000-0000-000000000001';
  IF s1 <> 70 THEN RAISE EXCEPTION 'GAGAL: simpan ulang menggeser stok jadi %', s1; END IF;
  RAISE NOTICE 'OK: simpan ulang -> stok tetap 70';
END; $$;

\echo ''
\echo '=== TES 4: menaikkan muatan mengurangi stok selisihnya saja ==='
DO $$
DECLARE s1 INTEGER;
BEGIN
  PERFORM public.save_morning_allocation(
    '11111111-1111-1111-1111-111111111111', (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","initial_quantity":40}]'::jsonb); -- +10
  SELECT stock_quantity INTO s1 FROM public.products WHERE id='aaaaaaaa-0000-0000-0000-000000000001';
  IF s1 <> 60 THEN RAISE EXCEPTION 'GAGAL: naik 10 -> stok %, harusnya 60', s1; END IF;
  RAISE NOTICE 'OK: muatan 30->40 -> stok 70->60';
END; $$;

\echo ''
\echo '=== TES 5: menurunkan muatan mengembalikan stok ==='
DO $$
DECLARE s1 INTEGER; r INTEGER;
BEGIN
  PERFORM public.save_morning_allocation(
    '11111111-1111-1111-1111-111111111111', (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","initial_quantity":25}]'::jsonb); -- -15 dari 40
  SELECT stock_quantity INTO s1 FROM public.products WHERE id='aaaaaaaa-0000-0000-0000-000000000001';
  SELECT count(*) INTO r FROM public.stock_movements WHERE reason='allocation_return';
  IF s1 <> 75 THEN RAISE EXCEPTION 'GAGAL: turun 15 -> stok %, harusnya 75', s1; END IF;
  IF r < 1 THEN RAISE EXCEPTION 'GAGAL: pengembalian tidak tercatat'; END IF;
  RAISE NOTICE 'OK: muatan 40->25 -> stok 60->75, pengembalian tercatat';
END; $$;

\echo ''
\echo '=== TES 6: muat melebihi stok pusat DITOLAK ==='
DO $$
BEGIN
  PERFORM public.save_morning_allocation(
    '11111111-1111-1111-1111-111111111111', (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","initial_quantity":9999}]'::jsonb);
  RAISE EXCEPTION 'GAGAL: muat melebihi stok diterima!';
EXCEPTION WHEN sqlstate '22023' THEN RAISE NOTICE 'OK ditolak: %', SQLERRM;
END; $$;

\echo ''
\echo '=== TES 7: stock opname menyetel absolut & catat selisih ==='
SELECT stock_quantity FROM public.set_product_stock('aaaaaaaa-0000-0000-0000-000000000002', 28, 'Opname sore');
DO $$
DECLARE s INTEGER; d INTEGER;
BEGIN
  SELECT stock_quantity INTO s FROM public.products WHERE id='aaaaaaaa-0000-0000-0000-000000000002';
  SELECT delta INTO d FROM public.stock_movements WHERE reason='opname' ORDER BY created_at DESC LIMIT 1;
  IF s <> 28 THEN RAISE EXCEPTION 'GAGAL: opname -> stok %, harusnya 28', s; END IF;
  RAISE NOTICE 'OK: opname -> stok 28, selisih tercatat %', d;
END; $$;

\echo ''
\echo '=== TES 8: ikhtisar stok + status low/out ==='
-- Buat satu produk habis dan satu menipis
SELECT stock_quantity FROM public.set_product_stock('aaaaaaaa-0000-0000-0000-000000000001', 0, 'habis');
SELECT stock_quantity FROM public.set_product_stock('aaaaaaaa-0000-0000-0000-000000000002', 5, 'menipis'); -- threshold 10
SELECT name, stock_quantity, allocated_today, status
  FROM public.admin_stock_overview() ORDER BY name;
DO $$
DECLARE v_out TEXT; v_low TEXT;
BEGIN
  SELECT status INTO v_out FROM public.admin_stock_overview() WHERE product_id='aaaaaaaa-0000-0000-0000-000000000001';
  SELECT status INTO v_low FROM public.admin_stock_overview() WHERE product_id='aaaaaaaa-0000-0000-0000-000000000002';
  IF v_out <> 'out' THEN RAISE EXCEPTION 'GAGAL: status habis = %, harusnya out', v_out; END IF;
  IF v_low <> 'low' THEN RAISE EXCEPTION 'GAGAL: status menipis = %, harusnya low', v_low; END IF;
  RAISE NOTICE 'OK: status out & low benar';
END; $$;

\echo ''
\echo '=== TES 9: lencana dashboard menghitung menipis/habis ==='
SELECT out_of_stock, low_stock FROM public.admin_low_stock_count();

\echo ''
\echo '=== TES 10: driver tidak boleh mengubah stok atau membaca ikhtisar ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE n INTEGER;
BEGIN
  BEGIN
    PERFORM public.adjust_product_stock('aaaaaaaa-0000-0000-0000-000000000001', 100, 'restock');
    RAISE EXCEPTION 'GAGAL: driver berhasil restock!';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  BEGIN
    PERFORM public.save_morning_allocation('11111111-1111-1111-1111-111111111111',
      (NOW() AT TIME ZONE 'Asia/Jakarta')::date, '[]'::jsonb);
    RAISE EXCEPTION 'GAGAL: driver berhasil muat gerobak!';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  SELECT count(*) INTO n FROM public.admin_stock_overview();
  IF n > 0 THEN RAISE EXCEPTION 'GAGAL: driver melihat % baris ikhtisar', n; END IF;

  SELECT count(*) INTO n FROM public.stock_movements;
  IF n > 0 THEN RAISE EXCEPTION 'GAGAL: driver membaca % pergerakan stok', n; END IF;

  RAISE NOTICE 'OK: driver ditolak restock, muat, ikhtisar, dan riwayat pergerakan';
END; $$;
