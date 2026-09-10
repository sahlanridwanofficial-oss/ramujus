-- ============================================================
-- 0017 — Cabut izin panggil fungsi admin dari peran anon
--
-- Jalankan di Supabase SQL Editor SETELAH 0016. Aman dijalankan berulang.
--
-- Temuan pada database produksi: peran `anon` — peran yang dipakai setiap
-- pengunjung yang BELUM login — punya izin EXECUTE pada seluruh fungsi
-- admin. Termasuk admin_daily_summary, admin_sales_range, fleet_overview,
-- dan semua yang ditambahkan sesudahnya.
--
-- Penyebabnya bukan kelalaian menulis GRANT, melainkan bawaan Supabase:
-- ALTER DEFAULT PRIVILEGES memberi EXECUTE kepada anon, authenticated, dan
-- service_role untuk setiap fungsi baru di skema public. Baris
--
--   REVOKE ALL ON FUNCTION ... FROM PUBLIC;
--
-- yang sudah ada di migrasi sebelumnya TIDAK menghapusnya, karena hibah itu
-- diberikan langsung ke peran `anon`, bukan lewat PUBLIC. Mencabut dari
-- PUBLIC tidak menyentuh hibah eksplisit ke sebuah peran.
--
-- Seberapa gawat? Datanya sendiri tidak pernah bocor: setiap fungsi admin
-- menyaring dengan `WHERE public.get_user_role(auth.uid()) = 'admin'`, dan
-- pemanggil anon tidak punya auth.uid() sehingga selalu menerima nol baris.
-- Itu sudah diuji langsung, bukan diasumsikan.
--
-- Tetapi itu satu lapis, bukan dua. Selama izinnya masih ada, satu fungsi
-- baru yang lupa menyertakan penyaring peran akan langsung terbuka untuk
-- publik — dan tidak ada yang menahannya. Migrasi ini mengembalikan lapis
-- kedua: anon tidak boleh memanggilnya sama sekali.
--
-- Cakupannya sengaja dipilih dengan pola nama, bukan daftar tetap, supaya
-- fungsi admin yang ditambahkan di masa depan ikut tertutup begitu berkas
-- ini dijalankan ulang.
--
-- Yang TIDAK disentuh: driver_daily_summary dan fungsi lain yang memang
-- dipanggil driver. Keduanya berjalan sebagai `authenticated`, bukan anon.
-- ============================================================

DO $do$
DECLARE
  r          RECORD;
  v_dicabut  INT := 0;
BEGIN
  FOR r IN
    SELECT p.oid,
           p.proname,
           pg_get_function_identity_arguments(p.oid) AS args
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND (p.proname LIKE 'admin\_%' OR p.proname = 'fleet_overview')
  LOOP
    -- PUBLIC dicabut ulang juga: murah, dan membuat berkas ini berdiri
    -- sendiri tanpa bergantung pada migrasi sebelumnya sudah benar.
    EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM PUBLIC', r.proname, r.args);
    EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM anon',   r.proname, r.args);
    -- Ditegaskan ulang supaya aplikasi tidak ikut mati bila urutan
    -- pencabutan di atas kebetulan mengenai hibah yang masih dipakai.
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO authenticated', r.proname, r.args);
    v_dicabut := v_dicabut + 1;
  END LOOP;

  RAISE NOTICE '0017: % fungsi admin ditutup untuk anon.', v_dicabut;
END;
$do$;

-- ------------------------------------------------------------
-- Cegah kambuh: fungsi admin BARU tidak lagi otomatis diberi ke anon.
--
-- Hanya berlaku untuk objek yang dibuat oleh peran yang sama dengan yang
-- menjalankan perintah ini. Itu sudah cukup, karena seluruh migrasi
-- repositori ini dijalankan lewat SQL Editor sebagai peran yang sama.
-- ------------------------------------------------------------
DO $do$
BEGIN
  EXECUTE format(
    'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon',
    current_user
  );
  RAISE NOTICE '0017: fungsi baru di skema public tidak lagi otomatis bisa dipanggil anon (peran %).', current_user;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE '0017: tidak berwenang mengubah default privileges — lewati. Fungsi yang sudah ada tetap tertutup.';
END;
$do$;

-- ------------------------------------------------------------
-- Pemeriksaan mandiri: gagalkan migrasi bila masih ada yang terbuka.
--
-- Tanpa ini, berkas bisa "berhasil" tapi tidak mencapai tujuannya, dan
-- tidak ada yang tahu sampai ada yang memeriksa manual.
-- ------------------------------------------------------------
DO $do$
DECLARE v_sisa TEXT;
BEGIN
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_sisa
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND (p.proname LIKE 'admin\_%' OR p.proname = 'fleet_overview')
     AND has_function_privilege('anon', p.oid, 'EXECUTE');

  IF v_sisa IS NOT NULL THEN
    RAISE EXCEPTION '0017 GAGAL: anon masih bisa memanggil %', v_sisa;
  END IF;

  RAISE NOTICE '0017: diperiksa — tidak ada satu pun fungsi admin yang bisa dipanggil anon.';
END;
$do$;

NOTIFY pgrst, 'reload schema';
