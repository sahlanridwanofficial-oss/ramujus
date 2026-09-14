-- Pengujian migrasi 0031: biaya bahan per cup dari takaran.
-- Bukan bagian aplikasi.
--
-- Berkas ini lahir dari angka nyata yang ngawur di layar pada 15 September
-- 2026: belanja Rp1.988.374 dibagi 133 cup = Rp14.951 per cup, lebih mahal
-- dari harga jualnya. Sebabnya satu belanja kemasan 1.000 cup yang akan
-- terpakai tujuh puluh hari, dibagi cup yang terjual seminggu.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id',    '{"full_name":"Mahaliriki"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order, stock_quantity, is_available) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'PASCA - Pisang Salted Caramel', 10000, 'smoothie', 1, 900, true),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'BNN - Buah Nanas Nyusu',        13000, 'smoothie', 2, 900, true),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'Stevia',                         2000, 'topping',  3, 900, true);

INSERT INTO public.shifts (id, driver_id, status) VALUES
  ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'active');

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

-- PASCA disederhanakan jadi dua bahan supaya angkanya bisa dihitung tangan.
DO $$
BEGIN
  PERFORM public.admin_simpan_takaran(
    'aaaaaaaa-0000-0000-0000-000000000001',
    format('[{"bahan_id":"%s","jumlah":100},{"bahan_id":"%s","jumlah":1}]',
           (SELECT id FROM public.bahan WHERE nama = 'Pisang'),
           (SELECT id FROM public.bahan WHERE nama = 'Cup'))::jsonb,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 10);
END;
$$;

\echo ''
\echo '=== 1. Belanja borongan tidak boleh dibagi cup ==='
-- Kejadian aslinya: kemasan dibeli 1.000 pcs sekaligus. admin_belanja_ringkas
-- melaporkan rupiahnya apa adanya dan TIDAK membaginya dengan apa pun.
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  PERFORM public.admin_catat_belanja(
    (SELECT id FROM public.bahan WHERE nama = 'Cup'),    v_hari - 6, 1000, 600000);
  PERFORM public.admin_catat_belanja(
    (SELECT id FROM public.bahan WHERE nama = 'Pisang'), v_hari - 6, 7000, 210000, 10000);

  SELECT * INTO r FROM public.admin_belanja_ringkas(v_hari - 30, v_hari);

  IF r.rupiah <> 810000 THEN
    RAISE EXCEPTION 'GAGAL: belanja %, harusnya 810.000', r.rupiah;
  END IF;
  IF r.rupiah_kemasan <> 600000 THEN
    RAISE EXCEPTION 'GAGAL: kemasan %, harusnya 600.000 — bagian inilah yang bikin "belanja dibagi cup" ngawur',
      r.rupiah_kemasan;
  END IF;

  RAISE NOTICE 'OK: Rp810.000 dilaporkan apa adanya, Rp600.000 di antaranya kemasan';
END;
$$;

\echo ''
\echo '=== 2. Biaya per cup dari takaran, dihitung tangan ==='
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; v_harap NUMERIC;
BEGIN
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);
  -- 4 cup PASCA hari ini.
  PERFORM public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":4}]'::jsonb);
  PERFORM set_config('test.uid', '22222222-2222-2222-2222-222222222222', true);

  SELECT * INTO r FROM public.admin_biaya_per_cup_takaran(v_hari - 30, v_hari);

  -- Pisang 100 g x (210.000 / 7.000 = Rp30/g) = Rp3.000
  -- Cup      1 pcs x (600.000 / 1.000 = Rp600) = Rp  600
  --                                              --------
  --                                              Rp3.600
  v_harap := 100 * (210000::numeric / 7000) + 1 * (600000::numeric / 1000);

  IF r.cup <> 4 THEN RAISE EXCEPTION 'GAGAL: cup %, harusnya 4', r.cup; END IF;
  IF r.biaya_per_cup <> ROUND(v_harap, 2) THEN
    RAISE EXCEPTION 'GAGAL: biaya per cup %, harusnya %', r.biaya_per_cup, ROUND(v_harap, 2);
  END IF;
  IF r.biaya_total <> ROUND(4 * v_harap, 2) THEN
    RAISE EXCEPTION 'GAGAL: biaya total %, harusnya %', r.biaya_total, ROUND(4 * v_harap, 2);
  END IF;
  IF NOT r.lengkap THEN RAISE EXCEPTION 'GAGAL: ditandai tidak lengkap'; END IF;

  -- Margin: Rp10.000 jual - Rp3.600 bahan
  IF r.margin_per_cup <> ROUND(10000 - v_harap, 2) THEN
    RAISE EXCEPTION 'GAGAL: margin %, harusnya %', r.margin_per_cup, ROUND(10000 - v_harap, 2);
  END IF;

  RAISE NOTICE 'OK: Rp% per cup, margin Rp%', r.biaya_per_cup, r.margin_per_cup;
END;
$$;

\echo ''
\echo '=== 3. Topping tidak ikut dihitung sebagai cup ==='
-- Stevia tidak punya takaran dan tidak akan pernah punya. Ikut dihitung,
-- ia membuat laporan ini tampak tidak lengkap selamanya.
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);
  PERFORM public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000003","quantity":5}]'::jsonb);
  PERFORM set_config('test.uid', '22222222-2222-2222-2222-222222222222', true);

  SELECT * INTO r FROM public.admin_biaya_per_cup_takaran(v_hari - 30, v_hari);

  IF r.cup <> 4 THEN
    RAISE EXCEPTION 'GAGAL: cup % — topping ikut terhitung', r.cup;
  END IF;
  IF NOT r.lengkap THEN
    RAISE EXCEPTION 'GAGAL: topping bikin laporan tampak tidak lengkap';
  END IF;

  RAISE NOTICE 'OK: 5 stevia tidak menggeser apa pun';
END;
$$;

\echo ''
\echo '=== 4. Cup yang belum bisa dinilai dihitung terpisah, bukan dianggap gratis ==='
-- BNN belum punya takaran. Cupnya tetap masuk hitungan "cup", tapi tidak
-- masuk "cup ternilai" — dan pembagi biayanya adalah yang ternilai.
-- Membagi biaya 4 cup dengan 7 cup akan melaporkan biaya per cup yang
-- terlalu murah, dan arahnya persis yang paling berbahaya.
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; v_harap NUMERIC;
BEGIN
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);
  PERFORM public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":3}]'::jsonb);
  PERFORM set_config('test.uid', '22222222-2222-2222-2222-222222222222', true);

  SELECT * INTO r FROM public.admin_biaya_per_cup_takaran(v_hari - 30, v_hari);
  v_harap := 100 * (210000::numeric / 7000) + 600;

  IF r.cup <> 7 THEN RAISE EXCEPTION 'GAGAL: cup %, harusnya 7', r.cup; END IF;
  IF r.cup_ternilai <> 4 THEN
    RAISE EXCEPTION 'GAGAL: cup ternilai %, harusnya 4', r.cup_ternilai;
  END IF;
  IF r.lengkap THEN
    RAISE EXCEPTION 'GAGAL: ditandai lengkap padahal 3 cup belum punya takaran';
  END IF;
  IF r.biaya_per_cup <> ROUND(v_harap, 2) THEN
    RAISE EXCEPTION 'GAGAL: biaya per cup % — pembaginya seluruh cup, bukan cup ternilai (harusnya %)',
      r.biaya_per_cup, ROUND(v_harap, 2);
  END IF;

  RAISE NOTICE 'OK: 7 cup, 4 ternilai, biayanya dibagi 4 — bukan 7';
END;
$$;

\echo ''
\echo '=== 5. Cup dinilai dengan harga saat ia terjual, bukan harga hari ini ==='
-- Kalau penjualan lama dinilai dengan harga terbaru, laporan bulan lalu
-- berubah tiap kali ada belanja baru. Cacat yang sama yang membuat takaran
-- dibuat berversi sejak awal.
DO $$
DECLARE
  v_hari    DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
  v_sebelum NUMERIC;
  v_sesudah NUMERIC;
BEGIN
  SELECT biaya_per_cup INTO v_sebelum
    FROM public.admin_biaya_per_cup_takaran(v_hari, v_hari);

  -- Pisang naik drastis HARI INI. Penjualan hari ini memang ikut naik
  -- (rata-rata bergerak), jadi yang diuji adalah rentang yang sudah lewat.
  PERFORM public.admin_catat_belanja(
    (SELECT id FROM public.bahan WHERE nama = 'Pisang'),
    v_hari, 1000, 90000);

  SELECT biaya_per_cup INTO v_sesudah
    FROM public.admin_biaya_per_cup_takaran(v_hari - 6, v_hari - 6);

  -- Tidak ada penjualan pada hari itu, jadi harusnya NULL — bukan angka
  -- yang dikarang dari harga hari ini.
  IF v_sesudah IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: hari tanpa penjualan mengembalikan %, harusnya NULL', v_sesudah;
  END IF;

  RAISE NOTICE 'OK: hari tanpa penjualan tidak dikarang angkanya (sebelumnya Rp%)', v_sebelum;
END;
$$;

\echo ''
\echo '=== 6. Rentang tanpa penjualan sama sekali: nol dan NULL, bukan galat ==='
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  SELECT * INTO r FROM public.admin_biaya_per_cup_takaran(v_hari - 60, v_hari - 50);

  IF NOT FOUND THEN RAISE EXCEPTION 'GAGAL: tidak mengembalikan baris sama sekali'; END IF;
  IF r.cup <> 0 THEN RAISE EXCEPTION 'GAGAL: cup %, harusnya 0', r.cup; END IF;
  IF r.biaya_per_cup IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: biaya per cup % untuk rentang tanpa penjualan', r.biaya_per_cup;
  END IF;
  IF r.lengkap THEN
    RAISE EXCEPTION 'GAGAL: rentang kosong ditandai lengkap — layar akan mengira angkanya sah';
  END IF;

  RAISE NOTICE 'OK: satu baris berisi nol dan NULL, bukan tabel kosong yang harus ditebak klien';
END;
$$;

\echo ''
\echo '=== 7. Dua fungsi baru tertutup untuk driver ==='
DO $$
DECLARE v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);

  BEGIN
    PERFORM public.admin_biaya_per_cup_takaran(v_hari - 30, v_hari);
    RAISE EXCEPTION 'GAGAL: driver bisa membaca biaya per cup';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ADMIN_ONLY' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM public.admin_belanja_ringkas(v_hari - 30, v_hari);
    RAISE EXCEPTION 'GAGAL: driver bisa membaca total belanja';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ADMIN_ONLY' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'OK: keduanya tertutup untuk driver';
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0031 LULUS ==='

-- ============================================================
-- Migrasi 0032: penjualan yang mendahului nota pertama
-- ============================================================
SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== 8. Penjualan sebelum nota pertama dinilai harga paling awal, DITANDAI ==='
-- Keadaan nyata 15 September 2026: seluruh penjualan 7-14 Sep, seluruh nota
-- 15 Sep. Tidak ada satu hari pun yang beririsan, jadi tanpa kemunduran ini
-- laporannya berbunyi "0 dari 133 cup ternilai" — benar secara aturan, tapi
-- tampak seperti kerusakan.
DO $$
DECLARE
  r       RECORD;
  v_hari  DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
  v_harap NUMERIC;
BEGIN
  -- Penjualan 9 hari lalu; nota pertama baru 6 hari lalu (uji 1).
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);
  INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount, payment_method, created_at)
  VALUES ('dddddddd-0000-0000-0000-00000000000a',
          'cccccccc-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111',
          'RMJ-TEST-SEBELUM', 20000, 'cash',
          public.wib_day_start(v_hari - 9) + INTERVAL '10 hours');
  INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
  VALUES ('dddddddd-0000-0000-0000-00000000000a',
          'aaaaaaaa-0000-0000-0000-000000000001', 2, 10000, 20000);
  PERFORM set_config('test.uid', '22222222-2222-2222-2222-222222222222', true);

  SELECT * INTO r FROM public.admin_biaya_per_cup_takaran(v_hari - 9, v_hari - 9);

  -- Harga paling awal: Pisang Rp30/g, Cup Rp600 -> 100 g + 1 pcs = Rp3.600
  v_harap := 100 * (210000::numeric / 7000) + 600;

  IF r.cup_ternilai <> 2 THEN
    RAISE EXCEPTION 'GAGAL: % dari 2 cup ternilai — penjualan sebelum nota pertama tidak dinilai',
      r.cup_ternilai;
  END IF;
  IF r.biaya_per_cup <> ROUND(v_harap, 2) THEN
    RAISE EXCEPTION 'GAGAL: biaya %, harusnya % (harga nota paling awal)', r.biaya_per_cup, v_harap;
  END IF;
  IF NOT r.harga_perkiraan THEN
    RAISE EXCEPTION 'GAGAL: dipakai harga yang dimundurkan tapi TIDAK ditandai perkiraan — '
                    'layar akan menyebutnya angka terukur';
  END IF;
  IF r.nota_pertama <> v_hari - 6 THEN
    RAISE EXCEPTION 'GAGAL: nota pertama %, harusnya %', r.nota_pertama, v_hari - 6;
  END IF;

  RAISE NOTICE 'OK: 2 cup dinilai Rp% dari harga nota paling awal, ditandai perkiraan', r.biaya_per_cup;
END;
$$;

\echo ''
\echo '=== 9. Rentang setelah nota pertama TIDAK ditandai perkiraan ==='
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  SELECT * INTO r FROM public.admin_biaya_per_cup_takaran(v_hari, v_hari);
  IF r.harga_perkiraan THEN
    RAISE EXCEPTION 'GAGAL: penjualan hari ini ditandai perkiraan padahal notanya sudah ada';
  END IF;
  RAISE NOTICE 'OK: hari yang notanya sudah ada tidak ditandai perkiraan';
END;
$$;

\echo ''
\echo '=== 10. Bahan yang belum pernah dibeli tetap tidak punya harga ==='
-- Batas kemundurannya. Yang dimundurkan adalah bukti yang ADA; ketiadaan
-- bukti tetap ketiadaan, dan tetap membuat HPP menu itu NULL.
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  SELECT * INTO r FROM public.harga_bahan_pada(v_hari, 'rata')
   WHERE bahan_id = (SELECT id FROM public.bahan WHERE nama = 'Kurma' LIMIT 1);
  IF FOUND AND r.harga IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: bahan yang belum pernah dibeli dapat harga %', r.harga;
  END IF;

  SELECT * INTO r FROM public.harga_bahan_pada(v_hari, 'rata')
   WHERE bahan_id = (SELECT id FROM public.bahan WHERE nama = 'Mangga');
  IF r.harga IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: Mangga belum pernah dibeli di berkas uji ini, tapi dapat harga %', r.harga;
  END IF;

  RAISE NOTICE 'OK: tidak ada harga yang dikarang dari ketiadaan';
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0031 & 0032 LULUS ==='
