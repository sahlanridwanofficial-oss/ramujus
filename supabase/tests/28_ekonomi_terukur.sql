-- Pengujian migrasi 0035: ekonomi terukur menggantikan margin yang diketik.
-- Bukan bagian aplikasi.
--
-- Yang dijaga berkas ini: tiga vonis uang — titik impas harian, ambang
-- gerobak per jam, ambang ruko per jam — berhenti bersandar pada angka yang
-- diketik seseorang, dan mulai berasal dari cup yang benar-benar terjual.
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
  ('aaaaaaaa-0000-0000-0000-000000000001', 'PASCA - Pisang Salted Caramel', 10000, 'smoothie', 1, 900, true);

INSERT INTO public.shifts (id, driver_id, status) VALUES
  ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'active');

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

-- Resep dua bahan supaya angkanya bisa dihitung tangan:
-- Pisang 100 g @ Rp30/g = Rp3.000, Cup 1 @ Rp600. HPP Rp3.600.
-- Jual Rp10.000 -> laba Rp6.400 per cup.
DO $$
DECLARE v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  PERFORM public.admin_simpan_takaran(
    'aaaaaaaa-0000-0000-0000-000000000001',
    format('[{"bahan_id":"%s","jumlah":100},{"bahan_id":"%s","jumlah":1}]',
           (SELECT id FROM public.bahan WHERE nama = 'Pisang'),
           (SELECT id FROM public.bahan WHERE nama = 'Cup'))::jsonb,
    v_hari - 10);

  PERFORM public.admin_catat_belanja(
    (SELECT id FROM public.bahan WHERE nama = 'Pisang'), v_hari - 2, 7000, 210000);
  PERFORM public.admin_catat_belanja(
    (SELECT id FROM public.bahan WHERE nama = 'Cup'),    v_hari - 2, 1000, 600000);
END;
$$;

\echo ''
\echo '=== 1. Belum ada cup ternilai: semuanya NULL, bukan nol ==='
-- Layar yang menerima nol akan menampilkan "impas 0 cup/hari" dan
-- "laba bersih Rp0" — dua kalimat yang terdengar seperti fakta padahal
-- keduanya berarti "belum tahu".
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  SELECT * INTO r FROM public.admin_ekonomi_terkini(v_hari - 60, v_hari - 50);

  IF NOT FOUND THEN RAISE EXCEPTION 'GAGAL: tidak mengembalikan baris'; END IF;
  IF r.laba_per_cup IS NOT NULL OR r.impas_per_hari IS NOT NULL
     OR r.laba_bersih IS NOT NULL OR r.impas_gerobak_jam IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: ada angka yang dikarang untuk rentang tanpa penjualan';
  END IF;
  IF r.lengkap THEN RAISE EXCEPTION 'GAGAL: ditandai lengkap'; END IF;

  RAISE NOTICE 'OK: NULL semua, dan tidak ditandai lengkap';
END;
$$;

\echo ''
\echo '=== 2. Laba per cup dan laba bersih, dihitung tangan ==='
DO $$
DECLARE
  r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
  v_tetap_hari NUMERIC := 2500000::numeric / 26;
BEGIN
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);
  -- 20 cup hari ini.
  PERFORM public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":20}]'::jsonb);
  PERFORM set_config('test.uid', '22222222-2222-2222-2222-222222222222', true);

  SELECT * INTO r FROM public.admin_ekonomi_terkini(v_hari, v_hari);

  IF r.cup <> 20 OR r.cup_ternilai <> 20 THEN
    RAISE EXCEPTION 'GAGAL: cup %/%', r.cup_ternilai, r.cup;
  END IF;
  IF r.laba_per_cup <> 6400 THEN
    RAISE EXCEPTION 'GAGAL: laba per cup %, harusnya 6.400 (10.000 - 3.600)', r.laba_per_cup;
  END IF;
  IF r.laba_kotor <> 20 * 6400 THEN
    RAISE EXCEPTION 'GAGAL: laba kotor %, harusnya %', r.laba_kotor, 20 * 6400;
  END IF;

  -- Satu hari jualan -> biaya tetap satu hari.
  IF r.hari_jualan <> 1 THEN
    RAISE EXCEPTION 'GAGAL: hari jualan %, harusnya 1', r.hari_jualan;
  END IF;
  IF r.biaya_tetap <> ROUND(v_tetap_hari, 2) THEN
    RAISE EXCEPTION 'GAGAL: biaya tetap %, harusnya %', r.biaya_tetap, ROUND(v_tetap_hari, 2);
  END IF;
  IF r.laba_bersih <> ROUND(20 * 6400 - v_tetap_hari, 2) THEN
    RAISE EXCEPTION 'GAGAL: laba bersih %, harusnya %',
      r.laba_bersih, ROUND(20 * 6400 - v_tetap_hari, 2);
  END IF;

  RAISE NOTICE 'OK: laba Rp6.400/cup, kotor Rp128.000, bersih Rp%', r.laba_bersih;
END;
$$;

\echo ''
\echo '=== 3. Titik impas turun karena marginnya naik ==='
-- Inti seluruh berkas ini. Margin tebakan Rp5.000 memberi impas 20
-- cup/hari; margin terukur Rp6.400 memberi ~15 cup/hari. Selisih lima cup
-- sehari itu selisih antara "masih jauh" dan "tinggal sedikit".
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; v_harap NUMERIC;
BEGIN
  SELECT * INTO r FROM public.admin_ekonomi_terkini(v_hari, v_hari);

  v_harap := ROUND((2500000::numeric / 26) / 6400, 2);
  IF r.impas_per_hari <> v_harap THEN
    RAISE EXCEPTION 'GAGAL: impas %, harusnya %', r.impas_per_hari, v_harap;
  END IF;
  IF r.impas_per_hari >= 20 THEN
    RAISE EXCEPTION 'GAGAL: impas % tidak turun dari tebakan lama 20', r.impas_per_hari;
  END IF;

  RAISE NOTICE 'OK: impas % cup/hari, turun dari 20', r.impas_per_hari;
END;
$$;

\echo ''
\echo '=== 4. Ambang gerobak dan ruko berasal dari MARGIN YANG SAMA ==='
-- Sebelum 0035, satu memakai Rp5.000 dan satunya Rp6.500 untuk menilai
-- titik yang sama di peta yang sama — selisih yang tidak pernah bisa
-- dijelaskan. Yang membedakan seharusnya cuma biaya tetap dan jam buka.
DO $$
DECLARE
  r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
  v_gerobak NUMERIC; v_ruko NUMERIC;
BEGIN
  SELECT * INTO r FROM public.admin_ekonomi_terkini(v_hari, v_hari);

  v_gerobak := ROUND((2500000::numeric / 26) / 6400 / 9.8, 2);
  v_ruko    := ROUND((6000000::numeric / 26) / 6400 / 9,   2);

  IF r.impas_gerobak_jam <> v_gerobak THEN
    RAISE EXCEPTION 'GAGAL: ambang gerobak %, harusnya %', r.impas_gerobak_jam, v_gerobak;
  END IF;
  IF r.impas_ruko_jam <> v_ruko THEN
    RAISE EXCEPTION 'GAGAL: ambang ruko %, harusnya %', r.impas_ruko_jam, v_ruko;
  END IF;

  -- Perbandingannya harus sebanding dengan biaya tetap dan jam buka saja,
  -- karena marginnya sudah sama. Toleransi 0,02 karena kedua ambang
  -- dibulatkan ke dua desimal lebih dulu — membandingkan angka bulat
  -- dengan rasio tak bulat akan selalu meleset sedikit.
  IF abs(r.impas_ruko_jam / r.impas_gerobak_jam
         - (6000000::numeric / 2500000) * (9.8 / 9)) > 0.02 THEN
    RAISE EXCEPTION 'GAGAL: rasio ruko:gerobak % — ada margin berbeda yang menyelinap',
      ROUND(r.impas_ruko_jam / r.impas_gerobak_jam, 3);
  END IF;

  RAISE NOTICE 'OK: gerobak %/jam, ruko %/jam, dari margin yang sama',
    r.impas_gerobak_jam, r.impas_ruko_jam;
END;
$$;

\echo ''
\echo '=== 5. Biaya tetap mengikuti HARI JUALAN, bukan panjang kalender ==='
-- Menagih biaya tetap pada hari gerobak libur membuat laba bersih tampak
-- lebih buruk daripada kenyataannya.
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  -- Rentang 30 hari, tapi jualannya cuma satu hari.
  SELECT * INTO r FROM public.admin_ekonomi_terkini(v_hari - 29, v_hari);

  IF r.hari_jualan <> 1 THEN
    RAISE EXCEPTION 'GAGAL: hari jualan %, harusnya 1 walau rentangnya 30 hari', r.hari_jualan;
  END IF;
  IF r.biaya_tetap <> ROUND(2500000::numeric / 26, 2) THEN
    RAISE EXCEPTION 'GAGAL: biaya tetap % — 29 hari libur ikut ditagih', r.biaya_tetap;
  END IF;

  RAISE NOTICE 'OK: 30 hari kalender, 1 hari jualan, 1 hari biaya tetap';
END;
$$;

\echo ''
\echo '=== 6. Parameter diubah, seluruh vonis ikut bergeser ==='
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; v_sebelum NUMERIC;
BEGIN
  SELECT impas_per_hari INTO v_sebelum
    FROM public.admin_ekonomi_terkini(v_hari, v_hari);

  -- Gaji driver naik: biaya tetap jadi Rp3,2 juta.
  UPDATE public.parameter_ekonomi SET biaya_tetap_bulanan = 3200000 WHERE id;

  SELECT * INTO r FROM public.admin_ekonomi_terkini(v_hari, v_hari);
  IF r.impas_per_hari <= v_sebelum THEN
    RAISE EXCEPTION 'GAGAL: impas % tidak naik dari % walau biaya tetap naik',
      r.impas_per_hari, v_sebelum;
  END IF;
  IF r.impas_per_hari <> ROUND((3200000::numeric / 26) / 6400, 2) THEN
    RAISE EXCEPTION 'GAGAL: impas % tidak mengikuti parameter baru', r.impas_per_hari;
  END IF;

  UPDATE public.parameter_ekonomi SET biaya_tetap_bulanan = 2500000 WHERE id;
  RAISE NOTICE 'OK: satu tempat diubah, seluruh vonis ikut';
END;
$$;

\echo ''
\echo '=== 7. Barisnya tepat satu, selamanya ==='
DO $$
DECLARE v_n INTEGER;
BEGIN
  BEGIN
    INSERT INTO public.parameter_ekonomi
      (id, biaya_tetap_bulanan, hari_jualan_per_bulan, jam_mangkal_per_hari,
       biaya_tetap_ruko_bulanan, jam_buka_ruko_per_hari)
    VALUES (true, 1, 1, 1, 1, 1);
    RAISE EXCEPTION 'GAGAL: baris kedua berhasil ditambahkan';
  EXCEPTION WHEN unique_violation OR insufficient_privilege THEN
    NULL;
  END;

  DELETE FROM public.parameter_ekonomi;
  SELECT count(*)::INTEGER INTO v_n FROM public.parameter_ekonomi;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GAGAL: % baris tersisa — parameternya bisa dihapus', v_n;
  END IF;

  RAISE NOTICE 'OK: tetap satu baris, tidak bisa ditambah maupun dihapus';
END;
$$;

\echo ''
\echo '=== 8. Driver tidak bisa membaca ekonomi maupun parameternya ==='
DO $$
DECLARE v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; v_lihat INTEGER;
BEGIN
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);

  BEGIN
    PERFORM public.admin_ekonomi_terkini(v_hari, v_hari);
    RAISE EXCEPTION 'GAGAL: driver bisa membaca ekonomi';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ADMIN_ONLY' THEN RAISE; END IF;
  END;

  SELECT count(*)::INTEGER INTO v_lihat FROM public.parameter_ekonomi;
  IF v_lihat <> 0 THEN
    RAISE EXCEPTION 'GAGAL: driver melihat parameter biaya tetap';
  END IF;

  RAISE NOTICE 'OK: tertutup untuk driver';
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0035 LULUS ==='
