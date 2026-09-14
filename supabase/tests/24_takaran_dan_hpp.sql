-- Pengujian migrasi 0030: takaran per menu, dan HPP yang dihitung darinya.
-- Bukan bagian aplikasi.
--
-- Janji berkas ini ada dua, dan keduanya soal menolak berbohong:
--   1. Bahan yang belum punya harga membuat HPP NULL, bukan nol.
--   2. Resep yang berubah tidak mengubah HPP bulan yang sudah lewat.
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
  ('aaaaaaaa-0000-0000-0000-000000000002', 'BNN - Buah Nanas Nyusu',        13000, 'smoothie', 2, 900, true);

-- Bahan TIDAK disemai di sini: migrasi 0030 sudah memasang ke-15 bahan RAMU
-- dengan UUID-nya sendiri. Tes mencarinya lewat nama, sama seperti yang
-- dilakukan layar admin.

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== 1. Takaran tersimpan sebagai satu versi utuh ==='
DO $$
DECLARE v_n INTEGER; v_baris INTEGER;
BEGIN
  v_n := public.admin_simpan_takaran(
    'aaaaaaaa-0000-0000-0000-000000000001',
    format('[{"bahan_id":"%s","jumlah":90},
             {"bahan_id":"%s","jumlah":10},
             {"bahan_id":"%s","jumlah":1}]',
           (SELECT id FROM public.bahan WHERE nama = 'Pisang'),
           (SELECT id FROM public.bahan WHERE nama = 'Caramel'),
           (SELECT id FROM public.bahan WHERE nama = 'Cup'))::jsonb,
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 10);

  IF v_n <> 3 THEN RAISE EXCEPTION 'GAGAL: % bahan tersimpan, harusnya 3', v_n; END IF;

  SELECT count(*)::INTEGER INTO v_baris FROM public.takaran
   WHERE product_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_baris <> 3 THEN RAISE EXCEPTION 'GAGAL: % baris di tabel', v_baris; END IF;

  RAISE NOTICE 'OK: 3 bahan, satu versi';
END;
$$;

\echo ''
\echo '=== 2. Bahan tanpa harga bikin HPP NULL, bukan nol ==='
-- Aturan yang paling gampang dilanggar. Kalau ketiadaan harga dibaca
-- sebagai nol, PASCA tampil untung Rp10.000 penuh — menu yang datanya
-- paling tidak lengkap justru tampil paling untung.
DO $$
DECLARE r RECORD;
BEGIN
  SELECT * INTO r FROM public.admin_hpp_menu()
   WHERE product_id = 'aaaaaaaa-0000-0000-0000-000000000001';

  IF r.hpp IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: HPP % padahal belum satu bahan pun punya harga', r.hpp;
  END IF;
  IF r.margin IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: margin % dikarang dari HPP yang tidak diketahui', r.margin;
  END IF;
  IF r.lengkap THEN
    RAISE EXCEPTION 'GAGAL: ditandai lengkap padahal tidak';
  END IF;
  IF array_length(r.bahan_tanpa_harga, 1) <> 3 THEN
    RAISE EXCEPTION 'GAGAL: % bahan disebut kurang harga, harusnya 3',
      array_length(r.bahan_tanpa_harga, 1);
  END IF;

  RAISE NOTICE 'OK: HPP NULL, dan layar diberi tahu 3 bahan mana yang kurang: %',
    array_to_string(r.bahan_tanpa_harga, ', ');
END;
$$;

\echo ''
\echo '=== 3. Satu bahan saja yang kurang tetap membatalkan seluruh angkanya ==='
DO $$
DECLARE r RECORD;
BEGIN
  -- Pisang dan Cup dikasih harga; Caramel sengaja dibiarkan kosong.
  PERFORM public.admin_catat_belanja(
    (SELECT id FROM public.bahan WHERE nama = 'Pisang'),
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 5, 650, 20000, 1000);
  PERFORM public.admin_catat_belanja(
    (SELECT id FROM public.bahan WHERE nama = 'Cup'),
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 5, 100, 85000);

  SELECT * INTO r FROM public.admin_hpp_menu()
   WHERE product_id = 'aaaaaaaa-0000-0000-0000-000000000001';

  IF r.hpp IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: HPP % dihitung padahal Caramel belum punya harga', r.hpp;
  END IF;
  IF r.bahan_tanpa_harga <> ARRAY['Caramel'] THEN
    RAISE EXCEPTION 'GAGAL: yang disebut kurang %, harusnya {Caramel}', r.bahan_tanpa_harga;
  END IF;

  RAISE NOTICE 'OK: dua dari tiga bahan berharga tetap tidak cukup — HPP tetap NULL';
END;
$$;

\echo ''
\echo '=== 4. Lengkap: HPP, margin, dan rinciannya cocok ==='
DO $$
DECLARE r RECORD; v_hpp NUMERIC; v_jumlah_rincian NUMERIC;
BEGIN
  -- Caramel Rp60.000 per 250 g = Rp240/gram.
  PERFORM public.admin_catat_belanja(
    (SELECT id FROM public.bahan WHERE nama = 'Caramel'),
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 5, 250, 60000);

  SELECT * INTO r FROM public.admin_hpp_menu()
   WHERE product_id = 'aaaaaaaa-0000-0000-0000-000000000001';

  -- Pisang  90 g  x Rp30,769230…/g  = Rp2.769,23
  -- Caramel 10 g  x Rp240/g         = Rp2.400
  -- Cup      1 pcs x Rp850          = Rp  850
  --                                   ---------
  --                                   Rp6.019,23
  v_hpp := ROUND(90 * (20000::numeric / 650) + 10 * 240 + 1 * 850, 2);

  IF r.hpp <> v_hpp THEN
    RAISE EXCEPTION 'GAGAL: HPP %, harusnya %', r.hpp, v_hpp;
  END IF;
  IF r.margin <> ROUND(10000 - v_hpp, 2) THEN
    RAISE EXCEPTION 'GAGAL: margin %, harusnya %', r.margin, ROUND(10000 - v_hpp, 2);
  END IF;
  IF NOT r.lengkap THEN RAISE EXCEPTION 'GAGAL: masih ditandai tidak lengkap'; END IF;

  -- Rincian harus berjumlah persis sama dengan HPP-nya. Kalau tidak,
  -- pemecahan "naik karena bahan apa" menunjuk ke angka yang salah.
  SELECT sum(biaya) INTO v_jumlah_rincian
    FROM public.admin_hpp_rincian('aaaaaaaa-0000-0000-0000-000000000001');
  IF ROUND(v_jumlah_rincian, 2) <> r.hpp THEN
    RAISE EXCEPTION 'GAGAL: rincian berjumlah % tapi HPP % — pemecahannya tidak bisa dipercaya',
      v_jumlah_rincian, r.hpp;
  END IF;

  RAISE NOTICE 'OK: HPP Rp%, margin Rp%, rinciannya berjumlah sama', r.hpp, r.margin;
END;
$$;

\echo ''
\echo '=== 5. Rincian menunjuk bahan termahal lebih dulu ==='
DO $$
DECLARE r RECORD;
BEGIN
  SELECT * INTO r FROM public.admin_hpp_rincian('aaaaaaaa-0000-0000-0000-000000000001') LIMIT 1;
  IF r.nama <> 'Pisang' THEN
    RAISE EXCEPTION 'GAGAL: baris teratas %, harusnya Pisang (Rp2.769 dari Rp6.019)', r.nama;
  END IF;
  IF r.porsi IS NULL OR r.porsi < 40 OR r.porsi > 50 THEN
    RAISE EXCEPTION 'GAGAL: porsi pisang % persen, harusnya sekitar 46', r.porsi;
  END IF;
  RAISE NOTICE 'OK: Pisang teratas, % persen dari HPP', r.porsi;
END;
$$;

\echo ''
\echo '=== 6. Resep berubah tidak mengubah HPP bulan yang sudah lewat ==='
-- Inti kenapa takaran berversi. Kalau resep bisa ditimpa, seluruh
-- riwayat HPP ikut berubah tiap kali takaran disesuaikan sedikit.
DO $$
DECLARE v_lama NUMERIC; v_baru NUMERIC; v_kemarin DATE;
BEGIN
  v_kemarin := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1;

  SELECT hpp INTO v_lama FROM public.admin_hpp_menu(v_kemarin)
   WHERE product_id = 'aaaaaaaa-0000-0000-0000-000000000001';

  -- Versi baru berlaku hari ini: pisangnya dinaikkan 90 -> 120 g.
  PERFORM public.admin_simpan_takaran(
    'aaaaaaaa-0000-0000-0000-000000000001',
    format('[{"bahan_id":"%s","jumlah":120},
             {"bahan_id":"%s","jumlah":10},
             {"bahan_id":"%s","jumlah":1}]',
           (SELECT id FROM public.bahan WHERE nama = 'Pisang'),
           (SELECT id FROM public.bahan WHERE nama = 'Caramel'),
           (SELECT id FROM public.bahan WHERE nama = 'Cup'))::jsonb);

  SELECT hpp INTO v_baru FROM public.admin_hpp_menu()
   WHERE product_id = 'aaaaaaaa-0000-0000-0000-000000000001';

  IF v_baru <= v_lama THEN
    RAISE EXCEPTION 'GAGAL: HPP hari ini % tidak naik dari % walau pisang ditambah', v_baru, v_lama;
  END IF;

  IF (SELECT hpp FROM public.admin_hpp_menu(v_kemarin)
       WHERE product_id = 'aaaaaaaa-0000-0000-0000-000000000001') <> v_lama THEN
    RAISE EXCEPTION 'GAGAL: HPP kemarin ikut bergeser — riwayatnya berubah surut';
  END IF;

  RAISE NOTICE 'OK: hari ini Rp%, kemarin tetap Rp%', v_baru, v_lama;
END;
$$;

\echo ''
\echo '=== 7. Versi mundur ditolak ==='
DO $$
BEGIN
  BEGIN
    PERFORM public.admin_simpan_takaran(
      'aaaaaaaa-0000-0000-0000-000000000001',
      format('[{"bahan_id":"%s","jumlah":10}]', (SELECT id FROM public.bahan WHERE nama = 'Pisang'))::jsonb,
      (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 30);
    RAISE EXCEPTION 'GAGAL: versi bertanggal lebih tua diterima';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'VERSI_MUNDUR' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'OK: HPP bulan yang sudah dilaporkan tidak bisa ditulis ulang';
END;
$$;

\echo ''
\echo '=== 8. Menu tanpa takaran sama sekali: NULL, dan barisnya tetap muncul ==='
DO $$
DECLARE r RECORD;
BEGIN
  SELECT * INTO r FROM public.admin_hpp_menu()
   WHERE product_id = 'aaaaaaaa-0000-0000-0000-000000000002';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'GAGAL: menu tanpa takaran hilang dari daftar — layar tidak akan tahu ia perlu diisi';
  END IF;
  IF r.hpp IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: HPP % untuk menu yang belum punya resep', r.hpp;
  END IF;
  IF r.bahan_dipakai <> 0 THEN
    RAISE EXCEPTION 'GAGAL: % bahan untuk menu tanpa resep', r.bahan_dipakai;
  END IF;

  RAISE NOTICE 'OK: BNN belum ada resepnya — NULL, bukan untung penuh Rp13.000';
END;
$$;

\echo ''
\echo '=== 9. Dua dasar harga memberi angka berbeda, dan tidak tertukar ==='
DO $$
DECLARE v_terakhir NUMERIC; v_rata NUMERIC;
BEGIN
  -- Pisang dibeli lagi hari ini, jauh lebih mahal.
  PERFORM public.admin_catat_belanja(
    (SELECT id FROM public.bahan WHERE nama = 'Pisang'),
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date, 500, 30000, 1000);

  SELECT hpp INTO v_terakhir FROM public.admin_hpp_menu(NULL, 'terakhir')
   WHERE product_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  SELECT hpp INTO v_rata FROM public.admin_hpp_menu(NULL, 'rata')
   WHERE product_id = 'aaaaaaaa-0000-0000-0000-000000000001';

  IF v_terakhir <= v_rata THEN
    RAISE EXCEPTION 'GAGAL: harga terakhir (%) tidak lebih tinggi dari rata-rata (%) setelah beli mahal',
      v_terakhir, v_rata;
  END IF;

  RAISE NOTICE 'OK: terakhir Rp% (buat harga jual), rata Rp% (buat laporan)', v_terakhir, v_rata;
END;
$$;

\echo ''
\echo '=== 10. Takaran tidak bisa diubah langsung dari aplikasi ==='
DO $$
DECLARE v_sisa INTEGER;
BEGIN
  UPDATE public.takaran SET jumlah = 999;
  SELECT count(*) INTO v_sisa FROM public.takaran WHERE jumlah = 999;
  IF v_sisa > 0 THEN
    RAISE EXCEPTION 'GAGAL: % baris takaran diubah langsung — riwayat HPP jadi tidak berarti', v_sisa;
  END IF;

  DELETE FROM public.takaran;
  SELECT count(*) INTO v_sisa FROM public.takaran;
  IF v_sisa = 0 THEN
    RAISE EXCEPTION 'GAGAL: takaran bisa dihapus dari aplikasi';
  END IF;

  RAISE NOTICE 'OK: % baris bertahan; perubahan hanya lewat admin_simpan_takaran', v_sisa;
END;
$$;

\echo ''
\echo '=== 11. Driver tidak bisa membaca HPP maupun resep ==='
DO $$
BEGIN
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);

  BEGIN
    PERFORM public.admin_hpp_menu();
    RAISE EXCEPTION 'GAGAL: driver bisa membaca HPP';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ADMIN_ONLY' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM public.admin_takaran_menu();
    RAISE EXCEPTION 'GAGAL: driver bisa membaca resep';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ADMIN_ONLY' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'OK: HPP dan resep tertutup untuk driver';
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0030 LULUS ==='
