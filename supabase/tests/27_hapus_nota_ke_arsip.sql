-- Pengujian migrasi 0034: nota salah bisa dihapus; yang dibatalkan berhenti
-- menyetir harga. Bukan bagian aplikasi.
--
-- Dua-duanya berasal dari satu keluhan pemakai: "kalau tidak dihapus, itu
-- masuk ke perhitungan."
\set ON_ERROR_STOP on
\pset pager off

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'd1@ramu.id',    '{"full_name":"Mahaliriki"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'admin@ramu.id', '{"full_name":"Admin"}'::jsonb);
UPDATE public.profiles SET role = 'admin' WHERE id = '22222222-2222-2222-2222-222222222222';

SET ROLE authenticated;
SET test.uid = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== 1. BUG LAMA: nota yang dibatalkan tidak boleh jadi harga terakhir ==='
-- Batalkan nota terbaru tanpa menggantinya. Sebelum 0034, harga bahan itu
-- tetap diambil dari nota yang barusan dinyatakan salah.
DO $$
DECLARE
  v_lama public.belanja; v_baru public.belanja;
  v_pisang UUID := (SELECT id FROM public.bahan WHERE nama = 'Pisang');
  v_hari   DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
  v_harga  NUMERIC; r RECORD;
BEGIN
  -- Nota lama yang benar: Rp28,57/gram.
  v_lama := public.admin_catat_belanja(v_pisang, v_hari - 3, 7000, 200000);
  -- Nota baru yang salah ketik: Rp285,71/gram.
  v_baru := public.admin_catat_belanja(v_pisang, v_hari,     700,  200000);

  PERFORM public.admin_perbaiki_belanja(v_baru.id);  -- batalkan, tanpa pengganti

  SELECT harga INTO v_harga FROM public.harga_bahan_pada(v_hari, 'terakhir')
   WHERE bahan_id = v_pisang;
  IF ROUND(v_harga, 2) <> 28.57 THEN
    RAISE EXCEPTION 'GAGAL: harga terakhir % — nota yang sudah dibatalkan masih menyetir harga',
      ROUND(v_harga, 2);
  END IF;

  SELECT * INTO r FROM public.admin_bahan_ringkas() WHERE bahan_id = v_pisang;
  IF r.harga_terakhir <> 28.57 THEN
    RAISE EXCEPTION 'GAGAL: ringkasan bahan masih menampilkan %', r.harga_terakhir;
  END IF;
  IF r.tanggal_terakhir <> v_hari - 3 THEN
    RAISE EXCEPTION 'GAGAL: tanggal terakhir %, harusnya nota yang masih berlaku', r.tanggal_terakhir;
  END IF;

  RAISE NOTICE 'OK: harga jatuh kembali ke nota yang masih berlaku, Rp28,57';
END;
$$;

\echo ''
\echo '=== 2. Menghapus nota memindahkannya ke arsip, tidak melenyapkan ==='
DO $$
DECLARE
  v_a public.belanja;
  v_nanas UUID := (SELECT id FROM public.bahan WHERE nama = 'Nanas');
  v_n INTEGER; v_arsip INTEGER;
BEGIN
  v_a := public.admin_catat_belanja(
    v_nanas, (NOW() AT TIME ZONE 'Asia/Jakarta')::date, 350, 10000, NULL, 'salah bahan');

  v_n := public.admin_hapus_belanja(v_a.id, 'salah pilih bahan');

  IF v_n <> 1 THEN RAISE EXCEPTION 'GAGAL: % baris dihapus, harusnya 1', v_n; END IF;

  IF EXISTS (SELECT 1 FROM public.belanja WHERE id = v_a.id) THEN
    RAISE EXCEPTION 'GAGAL: barisnya masih ada di riwayat';
  END IF;

  SELECT count(*)::INTEGER INTO v_arsip FROM public.belanja_terhapus WHERE id = v_a.id;
  IF v_arsip <> 1 THEN
    RAISE EXCEPTION 'GAGAL: barisnya lenyap, tidak masuk arsip — buktinya hilang';
  END IF;

  IF (SELECT alasan FROM public.belanja_terhapus WHERE id = v_a.id) <> 'salah pilih bahan' THEN
    RAISE EXCEPTION 'GAGAL: alasannya tidak tersimpan';
  END IF;
  IF (SELECT dihapus_oleh FROM public.belanja_terhapus WHERE id = v_a.id)
     <> '22222222-2222-2222-2222-222222222222' THEN
    RAISE EXCEPTION 'GAGAL: penghapusnya tidak tercatat';
  END IF;

  RAISE NOTICE 'OK: pindah ke arsip, lengkap dengan siapa dan kenapa';
END;
$$;

\echo ''
\echo '=== 3. Nota yang dihapus berhenti masuk perhitungan ==='
DO $$
DECLARE
  v_a public.belanja; v_stok NUMERIC;
  v_mangga UUID := (SELECT id FROM public.bahan WHERE nama = 'Mangga');
BEGIN
  v_a := public.admin_catat_belanja(
    v_mangga, (NOW() AT TIME ZONE 'Asia/Jakarta')::date, 9999, 999999);

  SELECT stok_masuk_total INTO v_stok FROM public.admin_bahan_ringkas()
   WHERE bahan_id = v_mangga;
  IF v_stok <> 9999 THEN RAISE EXCEPTION 'Prasyarat salah: stok %', v_stok; END IF;

  PERFORM public.admin_hapus_belanja(v_a.id);

  SELECT stok_masuk_total INTO v_stok FROM public.admin_bahan_ringkas()
   WHERE bahan_id = v_mangga;
  IF v_stok <> 0 THEN
    RAISE EXCEPTION 'GAGAL: stok % setelah dihapus — inilah yang dikeluhkan', v_stok;
  END IF;

  RAISE NOTICE 'OK: hilang dari perhitungan, bukan cuma dari pandangan';
END;
$$;

\echo ''
\echo '=== 4. Pasangan dihapus bersama, dari arah mana pun ==='
-- Menghapus nota tanpa pembatalnya meninggalkan baris negatif yatim yang
-- BENAR-BENAR masuk perhitungan — persis kejadian Mangga di produksi yang
-- membuat rupiahnya jadi nol.
DO $$
DECLARE
  v_a public.belanja; v_n INTEGER; v_sisa INTEGER; v_stok NUMERIC;
  v_gula UUID := (SELECT id FROM public.bahan WHERE nama = 'Gula');
BEGIN
  v_a := public.admin_catat_belanja(
    v_gula, (NOW() AT TIME ZONE 'Asia/Jakarta')::date, 5000, 76519);
  PERFORM public.admin_perbaiki_belanja(v_a.id);   -- jadi 2 baris

  v_n := public.admin_hapus_belanja(v_a.id);
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'GAGAL: % baris dihapus, harusnya 2 (nota + pembatalnya)', v_n;
  END IF;

  SELECT count(*)::INTEGER INTO v_sisa FROM public.belanja WHERE bahan_id = v_gula;
  IF v_sisa <> 0 THEN
    RAISE EXCEPTION 'GAGAL: % baris gula tersisa — ada yang jadi yatim', v_sisa;
  END IF;

  SELECT stok_masuk_total INTO v_stok FROM public.admin_bahan_ringkas()
   WHERE bahan_id = v_gula;
  IF v_stok <> 0 THEN RAISE EXCEPTION 'GAGAL: stok gula %', v_stok; END IF;

  RAISE NOTICE 'OK: dua baris satu peristiwa, hilang berbarengan';
END;
$$;

\echo ''
\echo '=== 5. Menghapus dari sisi PEMBATAL juga membawa notanya ==='
-- Menghapus pembatal sendirian akan menghidupkan kembali angka yang sudah
-- dinyatakan salah.
DO $$
DECLARE
  v_a public.belanja; v_pembatal UUID; v_n INTEGER; v_sisa INTEGER;
  v_coklat UUID := (SELECT id FROM public.bahan WHERE nama = 'Coklat');
BEGIN
  v_a := public.admin_catat_belanja(
    v_coklat, (NOW() AT TIME ZONE 'Asia/Jakarta')::date, 1000, 125875);
  PERFORM public.admin_perbaiki_belanja(v_a.id);

  SELECT id INTO v_pembatal FROM public.belanja WHERE membatalkan_id = v_a.id;

  v_n := public.admin_hapus_belanja(v_pembatal);
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'GAGAL: % baris dihapus dari sisi pembatal, harusnya 2', v_n;
  END IF;

  SELECT count(*)::INTEGER INTO v_sisa FROM public.belanja WHERE bahan_id = v_coklat;
  IF v_sisa <> 0 THEN
    RAISE EXCEPTION 'GAGAL: % baris coklat tersisa — angka yang salah hidup lagi', v_sisa;
  END IF;

  RAISE NOTICE 'OK: dari arah pembatal pun, pasangannya ikut';
END;
$$;

\echo ''
\echo '=== 6. Arsip tidak bisa dikosongkan dari aplikasi ==='
DO $$
DECLARE v_sisa INTEGER;
BEGIN
  DELETE FROM public.belanja_terhapus;
  SELECT count(*)::INTEGER INTO v_sisa FROM public.belanja_terhapus;
  IF v_sisa = 0 THEN
    RAISE EXCEPTION 'GAGAL: arsip bisa dihapus — "hapus" jadi benar-benar melenyapkan';
  END IF;

  UPDATE public.belanja_terhapus SET total_rupiah = 1;
  IF EXISTS (SELECT 1 FROM public.belanja_terhapus WHERE total_rupiah = 1) THEN
    RAISE EXCEPTION 'GAGAL: isi arsip bisa diubah';
  END IF;

  RAISE NOTICE 'OK: % baris arsip bertahan, isinya tidak bisa digeser', v_sisa;
END;
$$;

\echo ''
\echo '=== 7. Driver tidak bisa menghapus nota maupun membaca arsip ==='
DO $$
DECLARE v_id UUID; v_lihat INTEGER;
BEGIN
  SELECT id INTO v_id FROM public.belanja LIMIT 1;
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);

  BEGIN
    PERFORM public.admin_hapus_belanja(v_id);
    RAISE EXCEPTION 'GAGAL: driver bisa menghapus nota';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ADMIN_ONLY' THEN RAISE; END IF;
  END;

  SELECT count(*)::INTEGER INTO v_lihat FROM public.belanja_terhapus;
  IF v_lihat <> 0 THEN
    RAISE EXCEPTION 'GAGAL: driver melihat % baris arsip', v_lihat;
  END IF;

  RAISE NOTICE 'OK: tertutup untuk driver, lewat fungsi maupun tabel';
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0034 LULUS ==='
