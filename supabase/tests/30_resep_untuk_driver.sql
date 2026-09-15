-- Pengujian migrasi 0037: resep bisa dibaca driver. Bukan bagian aplikasi.
--
-- Yang dijaga berkas ini: orang yang menuangkan minumannya bisa membaca
-- takarannya sendiri, tetapi tidak ikut membaca rupiahnya.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id',    '{"full_name":"Mahaliriki"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb),
  ('33333333-3333-3333-3333-333333333333', 'd2@ramu.id',    '{"full_name":"Driver Nonaktif"}'::jsonb);
UPDATE public.profiles SET role = 'admin'  WHERE id = '22222222-2222-2222-2222-222222222222';
UPDATE public.profiles SET status = 'inactive' WHERE id = '33333333-3333-3333-3333-333333333333';

INSERT INTO public.products (id, name, price, category, sort_order, stock_quantity, is_available) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'PASCA - Pisang Salted Caramel', 10000, 'smoothie', 1, 100, true),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'MENU DITARIK',                 12000, 'smoothie', 2, 100, false);

-- PASCA: versi hari ini, dan versi yang baru berlaku pekan depan.
INSERT INTO public.takaran (product_id, berlaku_dari, bahan_id, jumlah)
SELECT 'aaaaaaaa-0000-0000-0000-000000000001',
       (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 7, b.id, x.j
  FROM (VALUES ('Pisang', 90), ('Es batu', 135), ('Air', 80),
               ('Gula', 25), ('Caramel', 10), ('Cup', 1)) AS x(n, j)
  JOIN public.bahan b ON b.nama = x.n;

INSERT INTO public.takaran (product_id, berlaku_dari, bahan_id, jumlah)
SELECT 'aaaaaaaa-0000-0000-0000-000000000001',
       (NOW() AT TIME ZONE 'Asia/Jakarta')::date + 7, b.id, 999
  FROM public.bahan b WHERE b.nama = 'Pisang';

-- Menu yang sudah ditarik tetap punya takaran tersimpan.
INSERT INTO public.takaran (product_id, berlaku_dari, bahan_id, jumlah)
SELECT 'aaaaaaaa-0000-0000-0000-000000000002',
       (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 7, b.id, 50
  FROM public.bahan b WHERE b.nama = 'Nanas';

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '=== 1. Driver bisa membaca takarannya sendiri ==='
-- Sebelum 0037 hanya admin yang boleh, sehingga takaran hidup di dua
-- tempat: di basis data dan di kepala driver.
DO $$
DECLARE v_n INTEGER; v_pisang NUMERIC;
BEGIN
  SELECT count(*)::INTEGER INTO v_n FROM public.driver_resep();
  IF v_n = 0 THEN
    RAISE EXCEPTION 'GAGAL: driver tidak mendapat satu baris pun';
  END IF;

  SELECT jumlah INTO v_pisang FROM public.driver_resep() WHERE bahan = 'Pisang';
  IF v_pisang <> 90 THEN
    RAISE EXCEPTION 'GAGAL: Pisang terbaca % gram', v_pisang;
  END IF;

  RAISE NOTICE 'OK: % baris terbaca, Pisang 90 gram', v_n;
END;
$$;

\echo ''
\echo '=== 2. Versi yang berlaku HARI INI, bukan versi terbaru ==='
-- Resep yang disiapkan untuk pekan depan tidak boleh bocor ke hari ini.
-- Kalau bocor, driver menuang 999 gram pisang mulai sekarang.
DO $$
DECLARE v_pisang NUMERIC; v_versi DATE;
BEGIN
  SELECT jumlah, berlaku_dari INTO v_pisang, v_versi
    FROM public.driver_resep() WHERE bahan = 'Pisang';

  IF v_pisang = 999 THEN
    RAISE EXCEPTION 'GAGAL: versi pekan depan sudah terbaca hari ini';
  END IF;
  IF v_versi <> (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 7 THEN
    RAISE EXCEPTION 'GAGAL: versi yang terbaca %, harusnya yang seminggu lalu', v_versi;
  END IF;

  RAISE NOTICE 'OK: versi % yang terbaca, bukan yang belum berlaku', v_versi;
END;
$$;

\echo ''
\echo '=== 3. Rupiah biaya tidak ikut keluar ==='
-- Driver perlu tahu cara membuatnya, bukan biayanya. Pemisahan ini di
-- lapisan basis data, bukan di layar, sebab layar bisa berubah tanpa
-- sengaja sedangkan fungsi ini tidak pernah menyentuh tabel belanja.
DO $$
DECLARE v_kolom TEXT; v_def TEXT;
BEGIN
  SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO v_kolom
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN unnest(p.proargnames, p.proargmodes)
         WITH ORDINALITY AS a(attname, mode, attnum) ON a.mode IN ('o', 't')
   WHERE n.nspname = 'public' AND p.proname = 'driver_resep';

  IF v_kolom ~* '(harga_bahan|hpp|margin|biaya|modal)' THEN
    RAISE EXCEPTION 'GAGAL: kolom biaya ikut dikembalikan — %', v_kolom;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'driver_resep';

  IF v_def ~* '\mbelanja\M' OR v_def ~* 'harga_bahan_pada' THEN
    RAISE EXCEPTION 'GAGAL: fungsinya membaca tabel atau harga belanja';
  END IF;

  RAISE NOTICE 'OK: kolomnya % — tanpa rupiah biaya', v_kolom;
END;
$$;

\echo ''
\echo '=== 4. Menu yang sudah ditarik tidak ikut muncul ==='
DO $$
DECLARE v_n INTEGER;
BEGIN
  SELECT count(*)::INTEGER INTO v_n FROM public.driver_resep()
   WHERE menu = 'MENU DITARIK';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GAGAL: % baris menu yang sudah ditarik ikut muncul', v_n;
  END IF;

  RAISE NOTICE 'OK: menu ditarik tetap tersimpan, tetapi tidak ditampilkan';
END;
$$;

\echo ''
\echo '=== 5. Kemasan jatuh ke bawah dengan sendirinya ==='
-- Urutannya menurun berdasarkan jumlah, sehingga tidak ada daftar nama
-- kemasan yang perlu dirawat.
DO $$
DECLARE v_pertama TEXT; v_terakhir TEXT;
BEGIN
  SELECT bahan INTO v_pertama FROM public.driver_resep() LIMIT 1;
  SELECT bahan INTO v_terakhir FROM public.driver_resep()
   OFFSET (SELECT count(*) - 1 FROM public.driver_resep());

  IF v_pertama <> 'Es batu' THEN
    RAISE EXCEPTION 'GAGAL: baris pertama %, harusnya bahan terbanyak', v_pertama;
  END IF;
  IF v_terakhir <> 'Cup' THEN
    RAISE EXCEPTION 'GAGAL: baris terakhir %, harusnya kemasan', v_terakhir;
  END IF;

  RAISE NOTICE 'OK: % di atas, % di bawah', v_pertama, v_terakhir;
END;
$$;

\echo ''
\echo '=== 6. Takaran tetap tidak bisa dibaca langsung dari tabelnya ==='
-- Pintunya satu: lewat fungsi. Kalau tabelnya ikut terbuka, kolom apa pun
-- yang ditambahkan nanti otomatis ikut terlihat driver.
DO $$
DECLARE v_n INTEGER;
BEGIN
  SELECT count(*)::INTEGER INTO v_n FROM public.takaran;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GAGAL: driver membaca % baris langsung dari takaran', v_n;
  END IF;

  SELECT count(*)::INTEGER INTO v_n FROM public.belanja;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GAGAL: driver membaca % baris nota belanja', v_n;
  END IF;

  RAISE NOTICE 'OK: tabel takaran dan belanja tetap tertutup';
END;
$$;

\echo ''
\echo '=== 7. Akun nonaktif ditolak ==='
DO $$
BEGIN
  PERFORM set_config('test.uid', '33333333-3333-3333-3333-333333333333', true);
  BEGIN
    PERFORM public.driver_resep();
    RAISE EXCEPTION 'GAGAL: driver nonaktif masih bisa membaca resep';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DRIVER_ONLY' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'OK: akun nonaktif ditolak';
END;
$$;

\echo ''
\echo '=== 8. Admin ikut diizinkan, anon tidak ==='
DO $$
DECLARE v_n INTEGER; v_boleh BOOLEAN;
BEGIN
  PERFORM set_config('test.uid', '22222222-2222-2222-2222-222222222222', true);
  SELECT count(*)::INTEGER INTO v_n FROM public.driver_resep();
  IF v_n = 0 THEN
    RAISE EXCEPTION 'GAGAL: admin tidak bisa memeriksa layar driver';
  END IF;

  SELECT has_function_privilege('anon', 'public.driver_resep()', 'EXECUTE')
    INTO v_boleh;
  IF v_boleh THEN
    RAISE EXCEPTION 'GAGAL: anon boleh menjalankan driver_resep';
  END IF;

  RAISE NOTICE 'OK: admin % baris, anon tertutup', v_n;
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0037 LULUS ==='
