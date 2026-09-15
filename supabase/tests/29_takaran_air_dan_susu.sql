-- Pengujian migrasi 0036: koreksi takaran Air dan Susu UHT. Bukan bagian
-- aplikasi.
--
-- Yang dijaga berkas ini: koreksi salah catat memperbaiki versi resep yang
-- sudah ada, bukan membuat versi baru, sehingga HPP hari-hari yang sudah
-- lewat ikut benar. Koreksi itu juga tidak boleh meleber ke menu lain, ke
-- kemasan, maupun ke versi yang sudah disesuaikan admin.
--
-- Basis data uji lahir tanpa produk, jadi semaian 0030 dan koreksi 0036
-- sama-sama tidak menemukan apa pun saat dipasang. Berkas ini menyemai
-- keadaan salahnya lebih dulu, lalu memanggil berkas migrasinya yang asli
-- dengan \ir supaya yang diuji benar-benar berkas itu, bukan salinan
-- logikanya.
\set ON_ERROR_STOP on
\pset pager off

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id',    '{"full_name":"Mahaliriki"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

INSERT INTO public.products (id, name, price, category, sort_order, stock_quantity, is_available) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'KPK - Kacang Pisang Kokoa',          13000, 'smoothie', 1, 100, true),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'PASUTRI - Pisang Asli Suka Stroberi', 13000, 'smoothie', 2, 100, true),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'BNN - Buah Nanas Nyusu',              13000, 'smoothie', 3, 100, true),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'PASCA - Pisang Salted Caramel',       10000, 'smoothie', 4, 100, true),
  ('aaaaaaaa-0000-0000-0000-000000000005', 'PAMAN - Pisang Mangga Nyusu',         13000, 'smoothie', 5, 100, true);

-- Takaran seperti yang disemai 0030: Air 85 dan Susu UHT 80, yaitu dua
-- angka yang ternyata salah salin.
DO $$
DECLARE
  v_mulai DATE := DATE '2026-09-07';
  v_resep JSONB;
  v_item  JSONB;
  v_p     RECORD;
BEGIN
  FOR v_p IN SELECT id, name FROM public.products LOOP
    v_resep := CASE
      WHEN v_p.name LIKE 'KPK%' THEN
        '[{"n":"Pisang","j":90},{"n":"Kacang","j":5},{"n":"Coklat","j":5},
          {"n":"Gula","j":25},{"n":"Es batu","j":135},{"n":"Air","j":85}]'::jsonb
      WHEN v_p.name LIKE 'PASUTRI%' THEN
        '[{"n":"Strawberry","j":45},{"n":"Pisang","j":45},{"n":"Es batu","j":135},
          {"n":"Air","j":85},{"n":"Gula","j":25}]'::jsonb
      WHEN v_p.name LIKE 'BNN%' THEN
        '[{"n":"Nanas","j":90},{"n":"Gula","j":25},{"n":"Es batu","j":135},
          {"n":"Susu UHT","j":80}]'::jsonb
      WHEN v_p.name LIKE 'PASCA%' THEN
        '[{"n":"Pisang","j":90},{"n":"Caramel","j":10},{"n":"Gula","j":25},
          {"n":"Es batu","j":135},{"n":"Air","j":85}]'::jsonb
      WHEN v_p.name LIKE 'PAMAN%' THEN
        '[{"n":"Pisang","j":30},{"n":"Mangga","j":60},{"n":"Gula","j":25},
          {"n":"Susu UHT","j":80},{"n":"Es batu","j":135}]'::jsonb
    END;

    v_resep := v_resep || '[{"n":"Cup","j":1},{"n":"Tutup cup","j":1},
                            {"n":"Sedotan","j":1},{"n":"Plastik vakum","j":1}]'::jsonb;

    FOR v_item IN SELECT * FROM jsonb_array_elements(v_resep) LOOP
      INSERT INTO public.takaran (product_id, berlaku_dari, bahan_id, jumlah)
      SELECT v_p.id, v_mulai, b.id, (v_item->>'j')::NUMERIC
        FROM public.bahan b WHERE b.nama = v_item->>'n';
    END LOOP;
  END LOOP;
END;
$$;

\echo ''
\echo '=== Menjalankan berkas migrasi 0036 yang asli ==='
\ir ../migrations/0036_takaran_air_dan_susu.sql

\echo ''
\echo '=== 1. Air jadi 80 ml pada KPK, PASUTRI, dan PASCA ==='
DO $$
DECLARE r RECORD; v_n INTEGER := 0;
BEGIN
  FOR r IN
    SELECT p.name, t.jumlah
      FROM public.takaran t
      JOIN public.products p ON p.id = t.product_id
      JOIN public.bahan b ON b.id = t.bahan_id
     WHERE b.nama = 'Air'
  LOOP
    IF r.jumlah <> 80 THEN
      RAISE EXCEPTION 'GAGAL: Air pada % masih % ml', r.name, r.jumlah;
    END IF;
    v_n := v_n + 1;
  END LOOP;

  IF v_n <> 3 THEN
    RAISE EXCEPTION 'GAGAL: % baris Air ditemukan, harusnya 3', v_n;
  END IF;

  RAISE NOTICE 'OK: tiga menu memakai Air 80 ml';
END;
$$;

\echo ''
\echo '=== 2. Susu UHT jadi 90 ml pada BNN, tetapi PAMAN tetap 80 ==='
-- Saringan nama menu wajib ada: dua menu ini sama-sama memakai 80 ml
-- sebelum koreksi, dan hanya BNN yang berubah.
DO $$
DECLARE v_bnn NUMERIC; v_paman NUMERIC;
BEGIN
  SELECT t.jumlah INTO v_bnn
    FROM public.takaran t
    JOIN public.products p ON p.id = t.product_id
    JOIN public.bahan b ON b.id = t.bahan_id
   WHERE b.nama = 'Susu UHT' AND p.name LIKE 'BNN%';

  SELECT t.jumlah INTO v_paman
    FROM public.takaran t
    JOIN public.products p ON p.id = t.product_id
    JOIN public.bahan b ON b.id = t.bahan_id
   WHERE b.nama = 'Susu UHT' AND p.name LIKE 'PAMAN%';

  IF v_bnn <> 90 THEN
    RAISE EXCEPTION 'GAGAL: Susu UHT pada BNN % ml, harusnya 90', v_bnn;
  END IF;
  IF v_paman <> 80 THEN
    RAISE EXCEPTION 'GAGAL: Susu UHT pada PAMAN ikut berubah jadi % ml', v_paman;
  END IF;

  RAISE NOTICE 'OK: BNN 90 ml, PAMAN tetap 80 ml';
END;
$$;

\echo ''
\echo '=== 3. PAMAN tidak berubah sama sekali ==='
DO $$
DECLARE r RECORD; v_harap JSONB;
BEGIN
  v_harap := '{"Pisang":30,"Mangga":60,"Gula":25,"Susu UHT":80,"Es batu":135,
               "Cup":1,"Tutup cup":1,"Sedotan":1,"Plastik vakum":1}'::jsonb;

  FOR r IN
    SELECT b.nama, t.jumlah
      FROM public.takaran t
      JOIN public.products p ON p.id = t.product_id
      JOIN public.bahan b ON b.id = t.bahan_id
     WHERE p.name LIKE 'PAMAN%'
  LOOP
    IF (v_harap->>r.nama)::NUMERIC IS DISTINCT FROM r.jumlah THEN
      RAISE EXCEPTION 'GAGAL: PAMAN % jadi %, harusnya %',
        r.nama, r.jumlah, v_harap->>r.nama;
    END IF;
  END LOOP;

  RAISE NOTICE 'OK: sembilan baris PAMAN utuh';
END;
$$;

\echo ''
\echo '=== 4. Koreksi memperbaiki versi lama, bukan menambah versi baru ==='
-- Inti seluruh berkas ini. Kalau koreksinya jadi versi baru, delapan hari
-- pertama akan selamanya dihitung memakai takaran yang tidak pernah dituang.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT p.name, count(DISTINCT t.berlaku_dari) AS versi, min(t.berlaku_dari) AS mulai
      FROM public.takaran t
      JOIN public.products p ON p.id = t.product_id
     GROUP BY p.name
  LOOP
    IF r.versi <> 1 THEN
      RAISE EXCEPTION 'GAGAL: % punya % versi takaran, harusnya 1', r.name, r.versi;
    END IF;
    IF r.mulai <> DATE '2026-09-07' THEN
      RAISE EXCEPTION 'GAGAL: versi % mulai %, harusnya 7 September', r.name, r.mulai;
    END IF;
  END LOOP;

  RAISE NOTICE 'OK: setiap menu tetap satu versi, tetap mulai 7 September';
END;
$$;

\echo ''
\echo '=== 5. Kemasan tidak ikut terhapus ==='
-- Daftar resep yang dikirim pemakai hanya menyebut isi, tanpa kemasan.
-- Koreksi yang menulis ulang seluruh versi akan melenyapkan cup dan
-- tutupnya tanpa suara, lalu HPP turun seolah kemasannya gratis.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT p.name,
           count(*) FILTER (WHERE b.nama IN ('Cup','Tutup cup','Sedotan','Plastik vakum')) AS kemasan
      FROM public.takaran t
      JOIN public.products p ON p.id = t.product_id
      JOIN public.bahan b ON b.id = t.bahan_id
     GROUP BY p.name
  LOOP
    IF r.kemasan <> 4 THEN
      RAISE EXCEPTION 'GAGAL: % punya % baris kemasan, harusnya 4', r.name, r.kemasan;
    END IF;
  END LOOP;

  RAISE NOTICE 'OK: empat baris kemasan bertahan di setiap menu';
END;
$$;

\echo ''
\echo '=== 6. Versi yang dibuat admin sesudahnya tidak disentuh ==='
-- Versi kedua adalah keputusan admin, bukan salah catat. Koreksi ini hanya
-- berhak atas versi paling awal.
INSERT INTO public.takaran (product_id, berlaku_dari, bahan_id, jumlah)
SELECT 'aaaaaaaa-0000-0000-0000-000000000004', DATE '2026-09-20', b.id, 85
  FROM public.bahan b WHERE b.nama = 'Air';

\ir ../migrations/0036_takaran_air_dan_susu.sql

DO $$
DECLARE v_awal NUMERIC; v_baru NUMERIC;
BEGIN
  SELECT t.jumlah INTO v_awal FROM public.takaran t
    JOIN public.bahan b ON b.id = t.bahan_id
   WHERE t.product_id = 'aaaaaaaa-0000-0000-0000-000000000004'
     AND t.berlaku_dari = DATE '2026-09-07' AND b.nama = 'Air';

  SELECT t.jumlah INTO v_baru FROM public.takaran t
    JOIN public.bahan b ON b.id = t.bahan_id
   WHERE t.product_id = 'aaaaaaaa-0000-0000-0000-000000000004'
     AND t.berlaku_dari = DATE '2026-09-20' AND b.nama = 'Air';

  IF v_awal <> 80 THEN
    RAISE EXCEPTION 'GAGAL: versi awal bergeser jadi % saat dijalankan ulang', v_awal;
  END IF;
  IF v_baru <> 85 THEN
    RAISE EXCEPTION 'GAGAL: versi admin 20 September ikut diubah jadi %', v_baru;
  END IF;

  RAISE NOTICE 'OK: dijalankan ulang, versi awal diam dan versi admin utuh';
END;
$$;

\echo ''
\echo '=== SELURUH UJI 0036 LULUS ==='
