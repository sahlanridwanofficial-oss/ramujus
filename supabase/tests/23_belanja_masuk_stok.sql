-- Pengujian migrasi 0029: belanja bahan masuk stok, harganya punya riwayat.
-- Bukan bagian aplikasi.
--
-- Janji berkas ini: harga bahan tidak pernah jadi angka yang diketik
-- seseorang. Ia selalu hasil bagi rupiah nota dengan berat daging yang
-- benar-benar didapat — jadi rendemen tidak pernah perlu ditebak, dan
-- riwayatnya tidak bisa diubah surut.
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
  ('aaaaaaaa-0000-0000-0000-000000000001', 'PASUTRI', 13000, 'smoothie', 1, 900, true);

INSERT INTO public.shifts (id, driver_id, status) VALUES
  ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'active');

INSERT INTO public.bahan (id, nama, satuan) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001', 'Pisang',   'gram'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Susu UHT', 'ml');

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== 1. Harga per gram datang dari berat DAGING, bukan berat beli ==='
-- Beli 1 kg pisang Rp20.000, dapat daging 650 g. Harga per gram daging
-- Rp30,77 — bukan Rp20 seperti kalau dihitung dari berat beli. Rendemen
-- tidak dimasukkan siapa pun; ia terukur sendiri dari dua angka ini.
DO $$
DECLARE r RECORD;
BEGIN
  PERFORM public.admin_catat_belanja(
    p_bahan_id     => 'bbbbbbbb-0000-0000-0000-000000000001',
    p_tanggal      => (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    p_jumlah       => 650,
    p_total_rupiah => 20000,
    p_jumlah_beli  => 1000);

  SELECT * INTO r FROM public.admin_bahan_ringkas()
   WHERE bahan_id = 'bbbbbbbb-0000-0000-0000-000000000001';

  IF r.harga_terakhir <> 30.77 THEN
    RAISE EXCEPTION 'GAGAL: harga per gram %, harusnya 30,77 (20000 / 650 daging)', r.harga_terakhir;
  END IF;
  IF r.rendemen_terakhir <> 0.65 THEN
    RAISE EXCEPTION 'GAGAL: rendemen % — harusnya 0,65 dan terukur sendiri', r.rendemen_terakhir;
  END IF;
  IF r.stok_masuk_total <> 650 THEN
    RAISE EXCEPTION 'GAGAL: stok masuk %, harusnya 650 — belanja harus LANGSUNG jadi stok', r.stok_masuk_total;
  END IF;

  RAISE NOTICE 'OK: Rp30,77/gram daging, rendemen 0,65 terukur, 650 g masuk stok';
END;
$$;

\echo ''
\echo '=== 2. Belanja kedua menggeser rata-rata secara tertimbang ==='
-- Harga naik. Rata-ratanya harus bergerak ke arah belanja yang lebih
-- besar, bukan rata-rata polos dari dua harga.
DO $$
DECLARE r RECORD; v_harap NUMERIC;
BEGIN
  PERFORM public.admin_catat_belanja(
    p_bahan_id     => 'bbbbbbbb-0000-0000-0000-000000000001',
    p_tanggal      => (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    p_jumlah       => 1240,
    p_total_rupiah => 44000,
    p_jumlah_beli  => 2000);

  SELECT * INTO r FROM public.admin_bahan_ringkas()
   WHERE bahan_id = 'bbbbbbbb-0000-0000-0000-000000000001';

  -- 64.000 / 1.890 = 33,86.  Rata-rata polos (30,77 + 35,48) / 2 = 33,13.
  v_harap := ROUND(64000::numeric / 1890, 2);
  IF r.harga_rata <> v_harap THEN
    RAISE EXCEPTION 'GAGAL: rata-rata %, harusnya % — belanja besar dan kecil tidak boleh berbobot sama',
      r.harga_rata, v_harap;
  END IF;
  IF r.stok_masuk_total <> 1890 THEN
    RAISE EXCEPTION 'GAGAL: stok %, harusnya 1.890 g', r.stok_masuk_total;
  END IF;
  IF r.harga_terakhir <> 35.48 THEN
    RAISE EXCEPTION 'GAGAL: harga terakhir %, harusnya 35,48', r.harga_terakhir;
  END IF;

  RAISE NOTICE 'OK: rata-rata % (tertimbang), terakhir 35,48, stok 1.890 g', r.harga_rata;
END;
$$;

\echo ''
\echo '=== 3. Buah makin jelek terbaca terpisah dari harga naik ==='
-- Inti kenapa jumlah_beli ada. Harga per kg PERSIS SAMA dengan belanja
-- pertama (Rp20/g kotor), tapi dagingnya turun 650 -> 520 g. Biaya naik
-- tanpa harga naik sedikit pun.
DO $$
DECLARE r RECORD;
BEGIN
  PERFORM public.admin_catat_belanja(
    p_bahan_id     => 'bbbbbbbb-0000-0000-0000-000000000001',
    p_tanggal      => (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    p_jumlah       => 520,
    p_total_rupiah => 20000,
    p_jumlah_beli  => 1000,
    p_catatan      => 'supplier baru, buahnya kecil-kecil');

  SELECT * INTO r FROM public.admin_bahan_ringkas()
   WHERE bahan_id = 'bbbbbbbb-0000-0000-0000-000000000001';

  IF r.rendemen_terakhir <> 0.52 THEN
    RAISE EXCEPTION 'GAGAL: rendemen %, harusnya 0,52', r.rendemen_terakhir;
  END IF;
  IF r.harga_terakhir <> 38.46 THEN
    RAISE EXCEPTION 'GAGAL: harga %, harusnya 38,46 — naik dari 30,77 walau rupiah per kg sama',
      r.harga_terakhir;
  END IF;

  RAISE NOTICE 'OK: Rp20.000/kg yang sama jadi Rp38,46/gram — sebabnya buah, bukan harga';
END;
$$;

\echo ''
\echo '=== 4. Koreksi ditulis sebagai baris baru, baris lama tak tersentuh ==='
DO $$
DECLARE v_baris INTEGER; v_stok NUMERIC;
BEGIN
  PERFORM public.admin_catat_belanja(
    p_bahan_id     => 'bbbbbbbb-0000-0000-0000-000000000001',
    p_tanggal      => (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    p_jumlah       => -520,
    p_total_rupiah => -20000,
    p_catatan      => 'batal, dikembalikan ke penjual');

  SELECT count(*)::INTEGER INTO v_baris FROM public.belanja
   WHERE bahan_id = 'bbbbbbbb-0000-0000-0000-000000000001';
  IF v_baris <> 4 THEN
    RAISE EXCEPTION 'GAGAL: % baris — koreksi harus MENAMBAH baris, bukan mengubah', v_baris;
  END IF;

  SELECT stok_masuk_total INTO v_stok FROM public.admin_bahan_ringkas()
   WHERE bahan_id = 'bbbbbbbb-0000-0000-0000-000000000001';
  IF v_stok <> 1890 THEN
    RAISE EXCEPTION 'GAGAL: stok %, harusnya balik ke 1.890 g', v_stok;
  END IF;

  RAISE NOTICE 'OK: 4 baris, stok balik 1.890 g, tidak ada angka lama yang ditimpa';
END;
$$;

\echo ''
\echo '=== 5. Riwayat tidak bisa diubah surut dari aplikasi ==='
-- Seluruh nilai berkas ini ada pada riwayat harga. Riwayat yang bisa
-- diedit tidak bisa dipakai memutuskan apa pun.
DO $$
DECLARE v_sisa INTEGER; v_masih NUMERIC;
BEGIN
  UPDATE public.belanja SET total_rupiah = 1;
  SELECT count(*) INTO v_sisa FROM public.belanja WHERE total_rupiah = 1;
  IF v_sisa > 0 THEN
    RAISE EXCEPTION 'GAGAL: % baris belanja berhasil diubah — riwayat harga jadi tidak berarti', v_sisa;
  END IF;

  DELETE FROM public.belanja;
  SELECT count(*) INTO v_sisa FROM public.belanja;
  IF v_sisa = 0 THEN
    RAISE EXCEPTION 'GAGAL: riwayat belanja bisa dihapus dari aplikasi';
  END IF;

  SELECT stok_masuk_total INTO v_masih FROM public.admin_bahan_ringkas()
   WHERE bahan_id = 'bbbbbbbb-0000-0000-0000-000000000001';
  IF v_masih <> 1890 THEN
    RAISE EXCEPTION 'GAGAL: angka bergeser jadi % setelah percobaan ubah/hapus', v_masih;
  END IF;

  RAISE NOTICE 'OK: % baris bertahan, angkanya tidak bergeser', v_sisa;
END;
$$;

\echo ''
\echo '=== 6. Angka yang mustahil ditolak ==='
DO $$
BEGIN
  -- Daging lebih berat dari buah utuhnya.
  BEGIN
    PERFORM public.admin_catat_belanja(
      p_bahan_id => 'bbbbbbbb-0000-0000-0000-000000000001',
      p_tanggal  => (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
      p_jumlah => 1200, p_total_rupiah => 20000, p_jumlah_beli => 1000);
    RAISE EXCEPTION 'GAGAL: daging 1.200 g dari buah 1.000 g diterima';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DAGING_LEBIH_BERAT_DARI_BELI' THEN RAISE; END IF;
  END;

  -- Nota bertanggal besok.
  BEGIN
    PERFORM public.admin_catat_belanja(
      p_bahan_id => 'bbbbbbbb-0000-0000-0000-000000000001',
      p_tanggal  => (NOW() AT TIME ZONE 'Asia/Jakarta')::date + 1,
      p_jumlah => 100, p_total_rupiah => 5000);
    RAISE EXCEPTION 'GAGAL: nota bertanggal besok diterima';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'TANGGAL_DI_MASA_DEPAN' THEN RAISE; END IF;
  END;

  -- Baris yang tidak mengubah apa pun.
  BEGIN
    PERFORM public.admin_catat_belanja(
      p_bahan_id => 'bbbbbbbb-0000-0000-0000-000000000001',
      p_tanggal  => (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
      p_jumlah => 0, p_total_rupiah => 0);
    RAISE EXCEPTION 'GAGAL: baris kosong diterima';
  EXCEPTION WHEN sqlstate '23514' THEN
    NULL;
  END;

  RAISE NOTICE 'OK: tiga angka mustahil ditolak dengan sebabnya masing-masing';
END;
$$;

\echo ''
\echo '=== 7. Biaya bahan per cup: belanja dibagi cup, apa adanya ==='
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);
  -- 10 cup terjual hari ini.
  PERFORM public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":10}]'::jsonb);
  PERFORM set_config('test.uid', '22222222-2222-2222-2222-222222222222', true);

  SELECT * INTO r FROM public.admin_biaya_bahan_per_cup(v_hari, v_hari);

  -- Belanja bersih: 20.000 + 44.000 + 20.000 - 20.000 = 64.000
  IF r.belanja_rupiah <> 64000 THEN
    RAISE EXCEPTION 'GAGAL: belanja %, harusnya 64.000 (koreksi ikut terhitung)', r.belanja_rupiah;
  END IF;
  IF r.cup <> 10 THEN
    RAISE EXCEPTION 'GAGAL: cup %, harusnya 10', r.cup;
  END IF;
  IF r.biaya_per_cup <> 6400 THEN
    RAISE EXCEPTION 'GAGAL: biaya per cup %, harusnya 6.400', r.biaya_per_cup;
  END IF;

  RAISE NOTICE 'OK: Rp64.000 / 10 cup = Rp6.400 per cup — tanpa satu pun tebakan';
END;
$$;

\echo ''
\echo '=== 8. Kelengkapan dilaporkan sebagai fakta, bukan ditebak ambang ==='
-- Minggu yang ada penjualannya tapi tidak ada notanya bukan berarti
-- bahannya gratis. Yang dilaporkan: berapa minggu punya catatan, dari
-- berapa minggu yang ada jualannya.
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  SELECT * INTO r FROM public.admin_biaya_bahan_per_cup(v_hari, v_hari);
  IF NOT r.lengkap THEN
    RAISE EXCEPTION 'GAGAL: minggu ini punya nota DAN penjualan, harusnya lengkap';
  END IF;

  -- Penjualan dua minggu lalu, tanpa nota sama sekali di minggu itu.
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);
  INSERT INTO public.orders (id, shift_id, driver_id, order_number, total_amount, payment_method, created_at)
  VALUES ('dddddddd-0000-0000-0000-000000000001',
          'cccccccc-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111',
          'RMJ-TEST-LAMA', 26000, 'cash',
          public.wib_day_start(v_hari - 14) + INTERVAL '10 hours');
  INSERT INTO public.order_items (order_id, product_id, quantity, unit_price, subtotal)
  VALUES ('dddddddd-0000-0000-0000-000000000001',
          'aaaaaaaa-0000-0000-0000-000000000001', 2, 13000, 26000);
  PERFORM set_config('test.uid', '22222222-2222-2222-2222-222222222222', true);

  SELECT * INTO r FROM public.admin_biaya_bahan_per_cup(v_hari - 14, v_hari);

  IF r.lengkap THEN
    RAISE EXCEPTION 'GAGAL: dua minggu jualan cuma satu minggu ada nota, tapi dilaporkan lengkap';
  END IF;
  IF r.minggu_ada >= r.minggu_total THEN
    RAISE EXCEPTION 'GAGAL: minggu_ada % >= minggu_total % — celahnya tidak kelihatan',
      r.minggu_ada, r.minggu_total;
  END IF;

  -- Angkanya TETAP dihitung dan dilaporkan; yang dilakukan sistem adalah
  -- memberi tahu bahwa ia belum boleh dipercaya, bukan menyembunyikannya.
  IF r.biaya_per_cup IS NULL THEN
    RAISE EXCEPTION 'GAGAL: angkanya disembunyikan, bukan ditandai';
  END IF;

  RAISE NOTICE 'OK: % dari % minggu punya nota — ditandai belum lengkap, angkanya tetap terbaca',
    r.minggu_ada, r.minggu_total;
END;
$$;

\echo ''
\echo '=== 9. Driver tidak bisa membaca maupun menulis harga bahan ==='
DO $$
DECLARE v_lihat INTEGER;
BEGIN
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);

  BEGIN
    PERFORM public.admin_bahan_ringkas();
    RAISE EXCEPTION 'GAGAL: driver bisa membaca harga bahan';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ADMIN_ONLY' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM public.admin_catat_belanja(
      p_bahan_id => 'bbbbbbbb-0000-0000-0000-000000000001',
      p_tanggal  => (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
      p_jumlah => 100, p_total_rupiah => 1);
    RAISE EXCEPTION 'GAGAL: driver bisa mencatat belanja';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ADMIN_ONLY' THEN RAISE; END IF;
  END;

  SELECT count(*)::INTEGER INTO v_lihat FROM public.belanja;
  IF v_lihat <> 0 THEN
    RAISE EXCEPTION 'GAGAL: driver melihat % baris belanja lewat tabel langsung', v_lihat;
  END IF;

  RAISE NOTICE 'OK: harga bahan tertutup untuk driver, lewat fungsi maupun tabel';
END;
$$;

\echo ''
\echo '=== 10. Bahan tanpa belanja: nol dan kosong, bukan galat ==='
DO $$
DECLARE r RECORD;
BEGIN
  PERFORM set_config('test.uid', '22222222-2222-2222-2222-222222222222', true);

  SELECT * INTO r FROM public.admin_bahan_ringkas()
   WHERE bahan_id = 'bbbbbbbb-0000-0000-0000-000000000002';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'GAGAL: bahan tanpa belanja hilang dari daftar — layar tidak akan tahu ia perlu diisi';
  END IF;
  IF r.harga_terakhir IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: harga % dikarang untuk bahan yang belum pernah dibeli', r.harga_terakhir;
  END IF;
  IF r.stok_masuk_total <> 0 OR r.jumlah_belanja <> 0 THEN
    RAISE EXCEPTION 'GAGAL: stok % / % baris untuk bahan yang belum pernah dibeli',
      r.stok_masuk_total, r.jumlah_belanja;
  END IF;

  RAISE NOTICE 'OK: harga NULL (bukan 0), stok 0, barisnya tetap muncul';
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0029 LULUS ==='
