-- Pengujian migrasi 0024: "sebut menu tanpa lihat" menggantikan
-- tebakan langganan. Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id',    '{"full_name":"Gerobak Satu"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order, stock_quantity, is_available)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'KPK', 13000, 'smoothie', 1, 900, true);

INSERT INTO public.shifts (id, driver_id, status)
VALUES ('cccccccc-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'active');

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '=== 1. Nilai tersimpan apa adanya ==='
DO $$
DECLARE v public.orders;
BEGIN
  v := public.create_order(
    p_shift_id           => 'cccccccc-0000-0000-0000-000000000001',
    p_items              => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
    p_customer_gender    => 'male',
    p_customer_age_range => 'young_adult',
    p_cara_pesan         => 'sebut');
  IF v.cara_pesan <> 'sebut' THEN
    RAISE EXCEPTION 'GAGAL: tersimpan %, harusnya sebut', v.cara_pesan;
  END IF;

  v := public.create_order(
    p_shift_id           => 'cccccccc-0000-0000-0000-000000000001',
    p_items              => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
    p_customer_gender    => 'female',
    p_customer_age_range => 'young_adult',
    p_cara_pesan         => 'lihat');
  IF v.cara_pesan <> 'lihat' THEN
    RAISE EXCEPTION 'GAGAL: tersimpan %, harusnya lihat', v.cara_pesan;
  END IF;

  RAISE NOTICE 'OK: sebut dan lihat tersimpan';
END;
$$;

\echo ''
\echo '=== 2. Nilai ngawur diabaikan, PENJUALAN TETAP TERSIMPAN ==='
-- Pola yang sama dengan kolom profil lain: satu ketukan salah tidak
-- boleh membuat uang yang nyata hilang.
DO $$
DECLARE v public.orders;
BEGIN
  v := public.create_order(
    p_shift_id   => 'cccccccc-0000-0000-0000-000000000001',
    p_items      => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":2}]'::jsonb,
    p_cara_pesan => 'langganan-banget');

  IF v.id IS NULL THEN
    RAISE EXCEPTION 'GAGAL: pesanan hilang gara-gara nilai cara_pesan ngawur';
  END IF;
  IF v.cara_pesan IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: nilai ngawur % ikut tersimpan', v.cara_pesan;
  END IF;
  IF v.total_amount <> 26000 THEN
    RAISE EXCEPTION 'GAGAL: total %, harusnya 26000', v.total_amount;
  END IF;

  RAISE NOTICE 'OK: nilai ngawur dibuang, Rp26.000 tetap tercatat';
END;
$$;

\echo ''
\echo '=== 3. Constraint database ikut menolak, bukan cuma fungsinya ==='
DO $$
BEGIN
  INSERT INTO public.orders (shift_id, driver_id, order_number, total_amount,
                             payment_method, cara_pesan)
  VALUES ('cccccccc-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111',
          'RMJ-LANGSUNG', 13000, 'cash', 'mungkin');
  RAISE EXCEPTION 'GAGAL: constraint tidak menahan nilai di luar daftar';
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE 'OK: constraint menolak nilai di luar daftar';
END;
$$;

\echo ''
\echo '=== 4. Pesanan tanpa cara_pesan tetap jalan ==='
-- Driver sedang ramai dan melewatkan ketukan itu. Penjualannya tidak
-- boleh ikut hilang — kolom pengamatan tidak pernah jadi syarat jualan.
DO $$
DECLARE v public.orders;
BEGIN
  v := public.create_order(
    p_shift_id        => 'cccccccc-0000-0000-0000-000000000001',
    p_items           => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
    p_payment_method  => 'cash',
    p_client_order_id => gen_random_uuid());

  IF v.id IS NULL THEN
    RAISE EXCEPTION 'GAGAL: pesanan tanpa cara_pesan ditolak';
  END IF;
  IF v.cara_pesan IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: cara_pesan terisi padahal tidak dikirim';
  END IF;

  RAISE NOTICE 'OK: pesanan tanpa catatan pengamatan tetap tersimpan';
END;
$$;

\echo ''
\echo '=== 4b. Aplikasi lama yang masih kirim p_customer_type tetap jalan ==='
-- PWA di ponsel driver belum tentu sudah memuat versi baru. Kalau
-- tanda tangannya tidak cocok, PostgREST menolak SETIAP penjualan.
DO $$
DECLARE v public.orders;
BEGIN
  v := public.create_order(
    p_shift_id        => 'cccccccc-0000-0000-0000-000000000001',
    p_items           => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
    p_payment_method  => 'cash',
    p_client_order_id => gen_random_uuid(),
    p_customer_type   => 'new');
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'GAGAL: aplikasi versi lama ditolak — gerobak tidak bisa jualan';
  END IF;
  RAISE NOTICE 'OK: aplikasi versi lama tetap bisa mencatat penjualan';
END;
$$;

\echo ''
\echo '=== 4c. Kolom customer_type benar-benar hilang, bukan cuma disembunyikan ==='
-- Selama kolomnya ada, seseorang akan membacanya sebagai kebenaran.
-- Itu sudah pernah terjadi.
DO $$
DECLARE v INTEGER;
BEGIN
  SELECT count(*) INTO v FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'orders'
     AND column_name = 'customer_type';
  IF v <> 0 THEN
    RAISE EXCEPTION 'GAGAL: kolom customer_type masih ada';
  END IF;
  RAISE NOTICE 'OK: kolom customer_type sudah tidak ada';
END;
$$;

\echo ''
\echo '=== 5. Hanya ada SATU create_order ==='
-- Menambah parameter lewat CREATE OR REPLACE akan membuat fungsi kedua,
-- dan PostgREST tidak bisa memilih di antara dua yang bernama sama.
DO $$
DECLARE v INTEGER;
BEGIN
  SELECT count(*) INTO v FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_order';
  IF v <> 1 THEN
    RAISE EXCEPTION 'GAGAL: ada % fungsi create_order, harusnya tepat 1', v;
  END IF;
  RAISE NOTICE 'OK: create_order tunggal, tidak ada kembarannya';
END;
$$;

\echo ''
\echo '=== 6. Laporan membuka penyebutnya ==='
-- Lima pesanan tersimpan: 1 sebut, 1 lihat, 3 belum dicatat. (Tes 3
-- ditolak constraint, jadi tidak menjadi baris.)
--
-- Persentase harus 1/2 = 50%, BUKAN 1/4 = 25% — yang belum dicatat tidak
-- boleh ikut jadi penyebut, supaya angkanya tidak turun hanya karena
-- driver sedang sibuk dan melewatkan pencatatan.
SET test.uid = '22222222-2222-2222-2222-222222222222';

SELECT hari, transaksi, sebut, lihat, belum_dicatat, persen_sebut
  FROM public.admin_hafal_menu(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date);

DO $$
DECLARE rec RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  SELECT * INTO rec FROM public.admin_hafal_menu(v_hari, v_hari);

  IF rec.transaksi <> 5 THEN
    RAISE EXCEPTION 'GAGAL: % transaksi, harusnya 5', rec.transaksi;
  END IF;
  IF rec.sebut <> 1 OR rec.lihat <> 1 OR rec.belum_dicatat <> 3 THEN
    RAISE EXCEPTION 'GAGAL: sebut %, lihat %, belum %', rec.sebut, rec.lihat, rec.belum_dicatat;
  END IF;
  IF abs(rec.persen_sebut - 50.0) > 0.05 THEN
    RAISE EXCEPTION 'GAGAL: persen %, harusnya 50.0 (1 dari 2 yang dicatat), bukan 20.0 dari 5',
                    rec.persen_sebut;
  END IF;

  RAISE NOTICE 'OK: 1 sebut / 2 tercatat = 50%% — yang belum dicatat tidak menyeret angkanya turun';
END;
$$;

\echo ''
\echo '=== 7. Driver tidak bisa membaca laporan admin ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
DECLARE v INTEGER;
BEGIN
  SELECT count(*) INTO v FROM public.admin_hafal_menu(
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 7,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date);
  IF v <> 0 THEN
    RAISE EXCEPTION 'GAGAL: driver mendapat % baris laporan admin', v;
  END IF;
  RAISE NOTICE 'OK: driver tidak mendapat satu pun baris';
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0024 LULUS ==='
