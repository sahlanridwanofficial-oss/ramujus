-- Pengujian migrasi 0017: fungsi admin tertutup untuk anon. Bukan bagian aplikasi.
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- Peran anon tidak dibuat oleh schema.sql di lingkungan uji; dibuat di sini
-- agar hak aksesnya bisa diperiksa persis seperti di Supabase.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
END;
$$;
GRANT USAGE ON SCHEMA public TO anon;

\echo ''
\echo '=== 1. Tidak ada satu pun fungsi admin yang bisa dipanggil anon ==='
DO $$
DECLARE v_terbuka TEXT; v_jumlah INT;
BEGIN
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname), count(*)
    INTO v_terbuka, v_jumlah
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND (p.proname LIKE 'admin\_%' OR p.proname = 'fleet_overview')
     AND has_function_privilege('anon', p.oid, 'EXECUTE');

  IF v_jumlah > 0 THEN
    RAISE EXCEPTION 'GAGAL: anon masih bisa memanggil % fungsi — %', v_jumlah, v_terbuka;
  END IF;
  RAISE NOTICE 'OK: nol fungsi admin terbuka untuk anon';
END;
$$;

\echo ''
\echo '=== 2. Admin yang sah TIDAK ikut terkunci ==='
DO $$
DECLARE v_tertutup TEXT; v_jumlah INT;
BEGIN
  -- Pencabutan yang terlalu luas akan mematikan seluruh dashboard. Itu
  -- kegagalan yang sama buruknya dengan lubangnya sendiri.
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname), count(*)
    INTO v_tertutup, v_jumlah
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND (p.proname LIKE 'admin\_%' OR p.proname = 'fleet_overview')
     AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE');

  IF v_jumlah > 0 THEN
    RAISE EXCEPTION 'GAGAL: % fungsi tertutup untuk authenticated — %', v_jumlah, v_tertutup;
  END IF;
  RAISE NOTICE 'OK: seluruh fungsi admin tetap bisa dipanggil peran authenticated';
END;
$$;

\echo ''
\echo '=== 3. Fungsi driver tidak ikut tercabut ==='
DO $$
BEGIN
  -- driver_daily_summary dipakai layar driver. Pola nama di 0017 sengaja
  -- tidak menyentuhnya; uji ini yang menjaga agar tetap begitu.
  IF NOT has_function_privilege('authenticated',
        'public.driver_daily_summary()'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GAGAL: driver_daily_summary ikut tercabut dari authenticated';
  END IF;
  RAISE NOTICE 'OK: driver_daily_summary tetap utuh';
END;
$$;

\echo ''
\echo '=== 4. Cakupannya benar-benar mengenai fungsi 0016 yang baru ==='
DO $$
DECLARE v_baru TEXT[] := ARRAY['admin_hourly_performance','admin_location_clusters',
                               'admin_daypart_matrix','admin_cart_productivity',
                               'admin_daily_productivity'];
        v_nama TEXT;
        v_oid  OID;
BEGIN
  FOREACH v_nama IN ARRAY v_baru LOOP
    SELECT p.oid INTO v_oid
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = v_nama
     LIMIT 1;

    IF v_oid IS NULL THEN
      RAISE EXCEPTION 'GAGAL: fungsi % tidak ditemukan', v_nama;
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GAGAL: anon masih bisa memanggil %', v_nama;
    END IF;
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GAGAL: authenticated tidak bisa memanggil %', v_nama;
    END IF;
  END LOOP;
  RAISE NOTICE 'OK: kelima fungsi 0016 tertutup untuk anon, terbuka untuk authenticated';
END;
$$;

\echo ''
\echo '=== 5. Lapis kedua tetap ada: gerbang peran di dalam fungsi ==='
-- Izin dan penyaring peran adalah dua pertahanan terpisah. Uji ini
-- memastikan 0017 tidak membuat siapa pun berpikir gerbang di dalam
-- fungsi jadi boleh dihapus.
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id',    '{"full_name":"Driver Satu"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';

DO $$
DECLARE v_today DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date; v INT;
BEGIN
  SELECT count(*) INTO v FROM public.admin_cart_productivity(v_today - 3, v_today);
  IF v <> 0 THEN
    RAISE EXCEPTION 'GAGAL: driver yang sudah login melihat % baris', v;
  END IF;
  RAISE NOTICE 'OK: driver yang login pun tetap ditolak gerbang peran di dalam fungsi';
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0017 LULUS ==='
