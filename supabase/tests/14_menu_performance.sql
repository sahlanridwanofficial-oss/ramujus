-- Pengujian migrasi 0015: analitik menu. Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id', '{"full_name":"Driver Satu"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order, stock_quantity, is_available) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'PASUTRI', 20000, 'smoothie', 1, 500, true),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'LAKNAT',  10000, 'smoothie', 2, 500, true),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'Stevia',   5000, 'addon',    3, 500, true),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'Menu Baru', 8000, 'smoothie', 4, 500, true);

INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

-- Penjualan disisipkan langsung supaya tanggalnya bisa diatur bebas.
-- Rentang uji: H-2 s/d hari ini (3 hari). Pembandingnya H-5 s/d H-3.
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
        v_order UUID;
BEGIN
  -- ---- PERIODE SEKARANG (H-2 .. hari ini) ----
  -- PASUTRI: 10 cup @20.000 = 200.000, laku pada 2 hari berbeda
  -- LAKNAT :  5 cup @10.000 =  50.000, laku pada 1 hari
  -- Stevia :  0 cup  -> dibawa tapi tidak laku sama sekali
  -- Menu Baru: 4 cup @8.000 = 32.000, sebelumnya tidak pernah laku
  FOR i IN 0..1 LOOP
    v_order := gen_random_uuid();
    INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount, payment_method, created_at)
    VALUES (v_order, 'cccccccc-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'RMJ-CUR-' || i, 100000, 'cash',
            ((v_today - i)::timestamp + INTERVAL '10 hours') AT TIME ZONE 'Asia/Jakarta');
    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
    VALUES (v_order, 'aaaaaaaa-0000-0000-0000-000000000001', 5, 20000, 100000);
  END LOOP;

  v_order := gen_random_uuid();
  INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount, payment_method, created_at)
  VALUES (v_order, 'cccccccc-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111',
          'RMJ-CUR-L', 82000, 'cash',
          (v_today::timestamp + INTERVAL '11 hours') AT TIME ZONE 'Asia/Jakarta');
  INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal) VALUES
    (v_order, 'aaaaaaaa-0000-0000-0000-000000000002', 5, 10000, 50000),
    (v_order, 'aaaaaaaa-0000-0000-0000-000000000004', 4,  8000, 32000);

  -- ---- PERIODE PEMBANDING (H-5 .. H-3) ----
  -- PASUTRI: 4 cup = 80.000  -> naik pada periode sekarang
  -- LAKNAT : 20 cup = 200.000 -> turun tajam
  v_order := gen_random_uuid();
  INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount, payment_method, created_at)
  VALUES (v_order, 'cccccccc-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111',
          'RMJ-PREV-1', 280000, 'cash',
          ((v_today - 4)::timestamp + INTERVAL '10 hours') AT TIME ZONE 'Asia/Jakarta');
  INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal) VALUES
    (v_order, 'aaaaaaaa-0000-0000-0000-000000000001',  4, 20000,  80000),
    (v_order, 'aaaaaaaa-0000-0000-0000-000000000002', 20, 10000, 200000);

  -- Muatan gerobak pada periode sekarang: Stevia dibawa 10 tapi tidak laku.
  INSERT INTO public.driver_daily_allocations (id, driver_id, date, status)
  VALUES ('bbbbbbbb-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111', v_today, 'active');
  INSERT INTO public.driver_allocation_items (allocation_id, product_id, initial_quantity) VALUES
    ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000003', 10),
    ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 12);
END;
$$;

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== Hasil admin_menu_performance untuk 3 hari terakhir ==='
SELECT name, qty_sold, revenue, revenue_share, loaded, days_sold, prev_qty, prev_revenue
  FROM public.admin_menu_performance(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 2,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date);

-- ------------------------------------------------------------
\echo ''
\echo '=== 1. Menu yang TIDAK laku tetap muncul, tidak hilang dari daftar ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_menu_performance(v_today - 2, v_today)
   WHERE name = 'Stevia';
  IF rec IS NULL THEN
    RAISE EXCEPTION 'GAGAL: menu yang tidak laku hilang dari hasil';
  END IF;
  IF rec.qty_sold <> 0 OR rec.revenue <> 0 THEN
    RAISE EXCEPTION 'GAGAL Stevia: terjual %, omzet %', rec.qty_sold, rec.revenue;
  END IF;
  IF rec.loaded <> 10 THEN
    RAISE EXCEPTION 'GAGAL: dibawa = %, harusnya 10', rec.loaded;
  END IF;
  RAISE NOTICE 'OK: Stevia dibawa 10, terjual 0 — persis kasus yang selama ini tak terlihat';
END;
$$;

\echo ''
\echo '=== 2. "Tidak laku" bisa dibedakan dari "tidak pernah dibawa" ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; rec RECORD;
BEGIN
  -- Menu Baru laku tetapi tidak pernah dimuat lewat alokasi.
  SELECT * INTO rec FROM public.admin_menu_performance(v_today - 2, v_today)
   WHERE name = 'Menu Baru';
  IF rec.loaded <> 0 OR rec.qty_sold <> 4 THEN
    RAISE EXCEPTION 'GAGAL Menu Baru: dibawa %, terjual %', rec.loaded, rec.qty_sold;
  END IF;
  RAISE NOTICE 'OK: dibawa 0 dan terjual 4 — dua keadaan berbeda, dua angka terpisah';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 3. Kontribusi omzet dalam persen, jumlahnya 100 ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
        v_total NUMERIC; rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_menu_performance(v_today - 2, v_today)
   WHERE name = 'PASUTRI';
  -- Omzet rentang ini: PASUTRI 200.000 + LAKNAT 50.000 + Menu Baru 32.000 = 282.000
  IF rec.revenue <> 200000 THEN
    RAISE EXCEPTION 'GAGAL: omzet PASUTRI = %', rec.revenue;
  END IF;
  IF rec.revenue_share <> round(200000 * 100.0 / 282000, 1) THEN
    RAISE EXCEPTION 'GAGAL: kontribusi = %, harusnya %',
      rec.revenue_share, round(200000 * 100.0 / 282000, 1);
  END IF;

  SELECT sum(revenue_share) INTO v_total
    FROM public.admin_menu_performance(v_today - 2, v_today);
  IF abs(v_total - 100) > 0.3 THEN
    RAISE EXCEPTION 'GAGAL: jumlah kontribusi = %, harusnya ~100', v_total;
  END IF;
  RAISE NOTICE 'OK: PASUTRI %%%, dan seluruh kontribusi berjumlah ~100', rec.revenue_share;
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 4. Pembanding periode sebelumnya sama panjang dan tidak tumpang tindih ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; rec RECORD;
BEGIN
  -- Rentang 3 hari (H-2..H0) -> pembanding H-5..H-3.
  SELECT * INTO rec FROM public.admin_menu_performance(v_today - 2, v_today)
   WHERE name = 'PASUTRI';
  IF rec.prev_qty <> 4 OR rec.prev_revenue <> 80000 THEN
    RAISE EXCEPTION 'GAGAL PASUTRI periode lalu: % cup / %', rec.prev_qty, rec.prev_revenue;
  END IF;

  SELECT * INTO rec FROM public.admin_menu_performance(v_today - 2, v_today)
   WHERE name = 'LAKNAT';
  IF rec.qty_sold <> 5 OR rec.prev_qty <> 20 THEN
    RAISE EXCEPTION 'GAGAL LAKNAT: sekarang %, dulu %', rec.qty_sold, rec.prev_qty;
  END IF;

  -- Penjualan periode lalu tidak boleh ikut terhitung di periode sekarang.
  IF (SELECT qty_sold FROM public.admin_menu_performance(v_today - 2, v_today)
       WHERE name = 'PASUTRI') <> 10 THEN
    RAISE EXCEPTION 'GAGAL: periode sekarang tercampur periode pembanding';
  END IF;

  RAISE NOTICE 'OK: PASUTRI naik 4->10, LAKNAT turun 20->5, tanpa tumpang tindih';
END;
$$;

\echo ''
\echo '=== 5. Menu yang baru laku: periode lalu nol ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_menu_performance(v_today - 2, v_today)
   WHERE name = 'Menu Baru';
  IF rec.prev_qty <> 0 OR rec.prev_revenue <> 0 THEN
    RAISE EXCEPTION 'GAGAL: menu baru punya angka periode lalu (% / %)', rec.prev_qty, rec.prev_revenue;
  END IF;
  RAISE NOTICE 'OK: menu baru terbaca sebagai nol di periode lalu, bukan disembunyikan';
END;
$$;

\echo ''
\echo '=== 6. days_sold menghitung hari, bukan transaksi ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; rec RECORD;
BEGIN
  SELECT * INTO rec FROM public.admin_menu_performance(v_today - 2, v_today)
   WHERE name = 'PASUTRI';
  IF rec.days_sold <> 2 THEN
    RAISE EXCEPTION 'GAGAL: hari laku = %, harusnya 2', rec.days_sold;
  END IF;
  RAISE NOTICE 'OK: PASUTRI laku pada 2 hari berbeda dari rentang 3 hari';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 7. Seluruh produk ikut, termasuk yang tidak pernah tersentuh ==='
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.admin_menu_performance(v_today - 2, v_today);
  IF n <> 4 THEN RAISE EXCEPTION 'GAGAL: % baris, harusnya 4 produk', n; END IF;
  RAISE NOTICE 'OK: keempat produk terdaftar — peringkat lama hanya menampilkan yang laku';
END;
$$;

\echo ''
\echo '=== 8. Driver tidak dapat membaca analitik menu ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.admin_menu_performance(v_today - 2, v_today);
  IF n <> 0 THEN RAISE EXCEPTION 'GAGAL: driver melihat % baris', n; END IF;
  RAISE NOTICE 'OK: tertutup untuk driver';
END;
$$;

RESET ROLE;
\echo ''
\echo '=== SEMUA UJI 14 LULUS ==='
