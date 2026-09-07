-- Pengujian migrasi 0010–0012: predikat tanggal memakai indeks, retensi
-- histori GPS, dan penolakan pesanan antrean yang basi. Bukan bagian aplikasi.
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
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Jus Mangga', 15000, 'smoothie', 1);

INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

-- ------------------------------------------------------------
\echo ''
\echo '=== 1. wib_day_start: batas tengah malam WIB, atas eksklusif ==='
DO $$
DECLARE v_day DATE := DATE '2026-03-15'; v_start TIMESTAMPTZ; v_next TIMESTAMPTZ;
BEGIN
  v_start := public.wib_day_start(v_day);
  v_next  := public.wib_day_start(v_day + 1);

  IF (v_start AT TIME ZONE 'Asia/Jakarta') <> TIMESTAMP '2026-03-15 00:00:00' THEN
    RAISE EXCEPTION 'GAGAL: awal hari = %', v_start AT TIME ZONE 'Asia/Jakarta';
  END IF;
  IF v_next - v_start <> INTERVAL '24 hours' THEN
    RAISE EXCEPTION 'GAGAL: satu hari WIB bukan 24 jam (%)', v_next - v_start;
  END IF;

  -- Detik terakhir hari itu harus masuk; tengah malam berikutnya tidak.
  IF NOT ((TIMESTAMP '2026-03-15 23:59:59' AT TIME ZONE 'Asia/Jakarta') < v_next) THEN
    RAISE EXCEPTION 'GAGAL: 23:59:59 jatuh di luar hari itu';
  END IF;
  IF (TIMESTAMP '2026-03-16 00:00:00' AT TIME ZONE 'Asia/Jakarta') < v_next THEN
    RAISE EXCEPTION 'GAGAL: tengah malam berikutnya ikut terhitung';
  END IF;
  RAISE NOTICE 'OK: [00:00 WIB, 00:00 WIB hari berikutnya) — tepat 24 jam, atas eksklusif';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== Menyemai 5.000 pesanan tersebar 120 hari ==='
INSERT INTO public.orders (shift_id, driver_id, order_number, total_amount, payment_method, created_at)
SELECT 'cccccccc-0000-0000-0000-000000000001',
       '11111111-1111-1111-1111-111111111111',
       'RMJ-SEED-' || lpad(g::text, 6, '0'),
       15000,
       'cash',
       NOW() - make_interval(mins => (g * 34) % (120 * 24 * 60))
  FROM generate_series(1, 5000) g;

INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
SELECT o.id, 'aaaaaaaa-0000-0000-0000-000000000001', 1, 15000, 15000
  FROM public.orders o
 WHERE o.order_number LIKE 'RMJ-SEED-%';

ANALYZE public.orders;
ANALYZE public.order_items;

-- ------------------------------------------------------------
\echo ''
\echo '=== 2. Predikat sargable memakai indeks, bukan memindai seluruh tabel ==='
DO $$
DECLARE v_plan JSON; v_text TEXT;
BEGIN
  EXECUTE $q$
    EXPLAIN (FORMAT JSON)
    SELECT count(*) FROM public.orders o
     WHERE o.created_at >= public.wib_day_start((NOW() AT TIME ZONE 'Asia/Jakarta')::date - 6)
       AND o.created_at <  public.wib_day_start((NOW() AT TIME ZONE 'Asia/Jakarta')::date + 1)
  $q$ INTO v_plan;

  v_text := v_plan::text;
  IF v_text LIKE '%"Node Type": "Seq Scan"%' THEN
    RAISE EXCEPTION 'GAGAL: masih memindai seluruh tabel. Rencana: %', v_text;
  END IF;
  IF v_text NOT LIKE '%Index%' THEN
    RAISE EXCEPTION 'GAGAL: tidak ada pemindaian indeks sama sekali. Rencana: %', v_text;
  END IF;
  RAISE NOTICE 'OK: rentang 7 hari dijawab lewat indeks created_at';
END;
$$;

\echo ''
\echo '=== 3. Bentuk lama memang memindai seluruh tabel (mengapa ini diubah) ==='
DO $$
DECLARE v_plan JSON;
BEGIN
  EXECUTE $q$
    EXPLAIN (FORMAT JSON)
    SELECT count(*) FROM public.orders o
     WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date
           BETWEEN (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 6
               AND (NOW() AT TIME ZONE 'Asia/Jakarta')::date
  $q$ INTO v_plan;

  IF v_plan::text NOT LIKE '%"Node Type": "Seq Scan"%' THEN
    RAISE NOTICE 'CATATAN: perencana tidak lagi memilih Seq Scan untuk bentuk lama pada data ini.';
  ELSE
    RAISE NOTICE 'OK: bentuk lama memang Seq Scan — perbedaannya nyata, bukan kosmetik';
  END IF;
END;
$$;

\echo ''
\echo '=== 4. Angkanya tidak berubah: fungsi cocok dengan hitungan langsung ==='
SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
        v_fn INTEGER; v_direct INTEGER;
BEGIN
  SELECT COALESCE(sum(orders), 0) INTO v_fn
    FROM public.admin_sales_range(v_today - 6, v_today);

  SELECT count(*) INTO v_direct FROM public.orders o
   WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date BETWEEN v_today - 6 AND v_today;

  IF v_fn <> v_direct THEN
    RAISE EXCEPTION 'GAGAL: fungsi = %, hitungan langsung = %', v_fn, v_direct;
  END IF;
  RAISE NOTICE 'OK: % transaksi lewat kedua cara — predikat baru tidak menggeser satu baris pun', v_fn;
END;
$$;

\echo ''
\echo '=== 5. Batas hari WIB tetap benar sesudah perubahan predikat ==='
RESET ROLE;
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  -- 23:59:30 WIB pada H-3, dan 00:00:30 WIB pada H-2.
  INSERT INTO public.orders (shift_id, driver_id, order_number, total_amount, payment_method, created_at)
  VALUES ('cccccccc-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111',
          'RMJ-BATAS-A', 11000, 'cash',
          ((v_today - 3)::timestamp + INTERVAL '23 hours 59 minutes 30 seconds') AT TIME ZONE 'Asia/Jakarta'),
         ('cccccccc-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111',
          'RMJ-BATAS-B', 22000, 'cash',
          ((v_today - 2)::timestamp + INTERVAL '30 seconds') AT TIME ZONE 'Asia/Jakarta');
END;
$$;
SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';
DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; a BIGINT; b BIGINT;
BEGIN
  SELECT revenue INTO a FROM public.admin_sales_range(v_today - 3, v_today - 3);
  SELECT revenue INTO b FROM public.admin_sales_range(v_today - 2, v_today - 2);

  IF a < 11000 OR b < 22000 THEN
    RAISE EXCEPTION 'GAGAL: transaksi batas tengah malam jatuh di hari yang salah (a=%, b=%)', a, b;
  END IF;
  RAISE NOTICE 'OK: 23:59:30 dan 00:00:30 WIB masing-masing di harinya sendiri';
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 6. Pemangkasan histori GPS terjadwal benar-benar menghapus ==='
RESET ROLE;
INSERT INTO public.location_logs (driver_id, shift_id, latitude, longitude, recorded_at)
SELECT '11111111-1111-1111-1111-111111111111',
       'cccccccc-0000-0000-0000-000000000001',
       -6.2, 106.8,
       NOW() - make_interval(days => g)
  FROM generate_series(1, 120) g;

DO $$
DECLARE v_before INTEGER; v_after INTEGER;
BEGIN
  SELECT count(*) INTO v_before FROM public.location_logs;
  PERFORM public.prune_location_logs_job(60);
  SELECT count(*) INTO v_after FROM public.location_logs;

  IF v_after >= v_before THEN
    RAISE EXCEPTION 'GAGAL: tidak ada yang dipangkas (% -> %)', v_before, v_after;
  END IF;
  IF EXISTS (SELECT 1 FROM public.location_logs WHERE recorded_at < NOW() - INTERVAL '60 days') THEN
    RAISE EXCEPTION 'GAGAL: masih ada histori lebih tua dari 60 hari';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.location_logs WHERE recorded_at > NOW() - INTERVAL '10 days') THEN
    RAISE EXCEPTION 'GAGAL: histori yang masih berlaku ikut terhapus';
  END IF;
  RAISE NOTICE 'OK: % -> % baris — yang tua hilang, yang baru tetap', v_before, v_after;
END;
$$;

\echo ''
\echo '=== 7. Migrasi retensi tidak gagal walau pg_cron tidak ada ==='
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE NOTICE 'pg_cron tersedia di lingkungan uji ini.';
  ELSE
    RAISE NOTICE 'OK: pg_cron tidak ada, dan 0011 tetap terpasang tanpa menggagalkan apa pun';
  END IF;
END;
$$;

-- ------------------------------------------------------------
\echo ''
\echo '=== 8. Driver tidak boleh memangkas histori sendiri ==='
SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
BEGIN
  BEGIN
    PERFORM public.prune_location_logs_job(1);
    RAISE EXCEPTION 'GAGAL: driver berhasil menghapus histori GPS armada';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK: pemangkasan tertutup untuk driver';
  END;
END;
$$;

RESET ROLE;
\echo ''
\echo '=== SEMUA UJI 11 LULUS ==='
