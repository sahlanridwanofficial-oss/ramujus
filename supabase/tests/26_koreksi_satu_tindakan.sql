-- Pengujian migrasi 0033: koreksi nota jadi satu tindakan.
-- Bukan bagian aplikasi.
--
-- Berkas ini lahir dari keluhan pemakai pada nota pertama yang salah ketik:
-- "fitur koreksinya bikin bingung, ada angka yang double, yang lama masih
-- ada". Datanya benar — 360 salah, 500 benar, -360 pembatal, nettonya 500 —
-- tapi layar tidak bisa menunjukkan pasangan mana yang sudah saling
-- meniadakan, karena pasangannya memang tidak pernah tercatat.
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
\echo '=== 1. Satu tekan menulis dua baris: pembatal dan penggantinya ==='
-- Kejadian aslinya: Mangga dicatat 360 g, seharusnya 500 g.
DO $$
DECLARE
  v_asli   public.belanja;
  v_baru   public.belanja;
  v_mangga UUID := (SELECT id FROM public.bahan WHERE nama = 'Mangga');
  v_n      INTEGER;
  v_stok   NUMERIC;
BEGIN
  v_asli := public.admin_catat_belanja(
    v_mangga, (NOW() AT TIME ZONE 'Asia/Jakarta')::date, 360, 20000);

  v_baru := public.admin_perbaiki_belanja(v_asli.id, 500, 20000);

  SELECT count(*)::INTEGER INTO v_n FROM public.belanja WHERE bahan_id = v_mangga;
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'GAGAL: % baris, harusnya 3 (asli + pembatal + pengganti)', v_n;
  END IF;

  IF v_baru.jumlah <> 500 OR v_baru.total_rupiah <> 20000 THEN
    RAISE EXCEPTION 'GAGAL: pengganti % g / Rp%', v_baru.jumlah, v_baru.total_rupiah;
  END IF;

  -- Nettonya harus 500 g, bukan 500 + 360.
  SELECT stok_masuk_total INTO v_stok FROM public.admin_bahan_ringkas()
   WHERE bahan_id = v_mangga;
  IF v_stok <> 500 THEN
    RAISE EXCEPTION 'GAGAL: stok % g — inilah angka dobel yang dikeluhkan', v_stok;
  END IF;

  RAISE NOTICE 'OK: 3 baris tercatat, netto 500 g';
END;
$$;

\echo ''
\echo '=== 2. Pasangannya tercatat, bukan ditebak dari kesamaan angka ==='
-- Tanpa penunjuk, layar harus menebak pasangan dari angka yang sama — dan
-- tebakan itu salah begitu ada dua nota kembar pada hari yang sama.
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
BEGIN
  SELECT count(*) FILTER (WHERE keadaan = 'berlaku')    AS berlaku,
         count(*) FILTER (WHERE keadaan = 'dibatalkan') AS dibatalkan,
         count(*) FILTER (WHERE keadaan = 'pembatal')   AS pembatal
    INTO r
    FROM public.admin_riwayat_belanja(v_hari - 30, v_hari);

  IF r.berlaku <> 1 OR r.dibatalkan <> 1 OR r.pembatal <> 1 THEN
    RAISE EXCEPTION 'GAGAL: berlaku=% dibatalkan=% pembatal=% — harusnya 1/1/1',
      r.berlaku, r.dibatalkan, r.pembatal;
  END IF;

  RAISE NOTICE 'OK: 1 berlaku, 1 dibatalkan, 1 pembatal — layar bisa melipat';
END;
$$;

\echo ''
\echo '=== 3. Dua nota kembar: yang dibatalkan tepat satu, bukan dua ==='
-- Inti kenapa penunjuk harus fakta, bukan tebakan. Dua nota identik pada
-- hari yang sama; satu dibatalkan. Penebak dari kesamaan angka akan
-- menandai dua-duanya.
DO $$
DECLARE
  v_a public.belanja; v_b public.belanja;
  v_nanas UUID := (SELECT id FROM public.bahan WHERE nama = 'Nanas');
  v_hari  DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
  v_batal INTEGER; v_stok NUMERIC;
BEGIN
  v_a := public.admin_catat_belanja(v_nanas, v_hari, 350, 10000);
  v_b := public.admin_catat_belanja(v_nanas, v_hari, 350, 10000);

  PERFORM public.admin_perbaiki_belanja(v_a.id);  -- pembatalan murni

  SELECT count(*)::INTEGER INTO v_batal
    FROM public.admin_riwayat_belanja(v_hari - 30, v_hari)
   WHERE keadaan = 'dibatalkan' AND bahan_id = v_nanas;

  IF v_batal <> 1 THEN
    RAISE EXCEPTION 'GAGAL: % nota nanas ditandai dibatalkan, harusnya tepat 1', v_batal;
  END IF;

  SELECT stok_masuk_total INTO v_stok FROM public.admin_bahan_ringkas()
   WHERE bahan_id = v_nanas;
  IF v_stok <> 350 THEN
    RAISE EXCEPTION 'GAGAL: stok nanas % g, harusnya 350', v_stok;
  END IF;

  RAISE NOTICE 'OK: dari dua nota kembar, tepat satu ditandai dibatalkan';
END;
$$;

\echo ''
\echo '=== 4. Pembatalan murni tidak meninggalkan pengganti ==='
DO $$
DECLARE r RECORD; v_hari DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date;
        v_nanas UUID := (SELECT id FROM public.bahan WHERE nama = 'Nanas');
BEGIN
  SELECT count(*) FILTER (WHERE keadaan = 'berlaku') AS berlaku INTO r
    FROM public.admin_riwayat_belanja(v_hari - 30, v_hari)
   WHERE bahan_id = v_nanas;

  IF r.berlaku <> 1 THEN
    RAISE EXCEPTION 'GAGAL: % nota nanas berlaku, harusnya 1', r.berlaku;
  END IF;
  RAISE NOTICE 'OK: pembatalan murni tidak mengarang pengganti';
END;
$$;

\echo ''
\echo '=== 5. Satu nota tidak bisa dibatalkan dua kali ==='
-- Dua pembatal untuk satu nota akan mengurangi stok dua kali dari satu
-- peristiwa — stoknya jadi minus tanpa ada yang salah di lapangan.
DO $$
DECLARE
  v_a public.belanja; v_stok_sebelum NUMERIC; v_stok_sesudah NUMERIC;
  v_gula UUID := (SELECT id FROM public.bahan WHERE nama = 'Gula');
BEGIN
  v_a := public.admin_catat_belanja(
    v_gula, (NOW() AT TIME ZONE 'Asia/Jakarta')::date, 5000, 76519);
  PERFORM public.admin_perbaiki_belanja(v_a.id);

  SELECT stok_masuk_total INTO v_stok_sebelum FROM public.admin_bahan_ringkas()
   WHERE bahan_id = v_gula;

  BEGIN
    PERFORM public.admin_perbaiki_belanja(v_a.id);
    RAISE EXCEPTION 'GAGAL: nota yang sudah dibatalkan bisa dibatalkan lagi';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'NOTA_SUDAH_DIBATALKAN' THEN RAISE; END IF;
  END;

  SELECT stok_masuk_total INTO v_stok_sesudah FROM public.admin_bahan_ringkas()
   WHERE bahan_id = v_gula;
  IF v_stok_sesudah <> v_stok_sebelum THEN
    RAISE EXCEPTION 'GAGAL: stok bergeser % -> % walau ditolak', v_stok_sebelum, v_stok_sesudah;
  END IF;

  RAISE NOTICE 'OK: ditolak, dan stoknya tidak bergeser';
END;
$$;

\echo ''
\echo '=== 6. Baris pembatal tidak bisa dibatalkan ==='
DO $$
DECLARE v_pembatal UUID;
BEGIN
  SELECT id INTO v_pembatal FROM public.belanja
   WHERE membatalkan_id IS NOT NULL LIMIT 1;

  BEGIN
    PERFORM public.admin_perbaiki_belanja(v_pembatal);
    RAISE EXCEPTION 'GAGAL: baris pembatal bisa dibatalkan lagi';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'NOTA_ADALAH_PEMBATAL' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'OK: membatalkan pembatalan ditolak';
END;
$$;

\echo ''
\echo '=== 7. Pembatal memakai TANGGAL ASLINYA, bukan hari ini ==='
-- Dibatalkan pada tanggal lain, hari asalnya tetap menyimpan harga yang
-- salah, dan harga_bahan_pada() untuk hari itu tetap keliru.
DO $$
DECLARE
  v_a public.belanja; v_tgl DATE; v_harga NUMERIC;
  v_kacang UUID := (SELECT id FROM public.bahan WHERE nama = 'Kacang');
  v_lampau DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 5;
BEGIN
  v_a := public.admin_catat_belanja(v_kacang, v_lampau, 1000, 999000);
  PERFORM public.admin_perbaiki_belanja(v_a.id, 2000, 160200);

  SELECT tanggal INTO v_tgl FROM public.belanja WHERE membatalkan_id = v_a.id;
  IF v_tgl <> v_lampau THEN
    RAISE EXCEPTION 'GAGAL: pembatal bertanggal %, harusnya %', v_tgl, v_lampau;
  END IF;

  -- Harga pada hari itu harus jadi 160.200/2.000 = Rp80,10 — bukan Rp999.
  SELECT harga INTO v_harga FROM public.harga_bahan_pada(v_lampau, 'rata')
   WHERE bahan_id = v_kacang;
  IF ROUND(v_harga, 2) <> 80.10 THEN
    RAISE EXCEPTION 'GAGAL: harga pada hari asal %, harusnya 80,10 — pembatalnya tidak meniadakan',
      ROUND(v_harga, 2);
  END IF;

  RAISE NOTICE 'OK: hari asal ikut terkoreksi jadi Rp80,10/gram';
END;
$$;

\echo ''
\echo '=== 8. Angka mustahil tetap ditolak saat memperbaiki ==='
DO $$
DECLARE
  v_a public.belanja;
  v_pisang UUID := (SELECT id FROM public.bahan WHERE nama = 'Pisang');
  v_n_sebelum INTEGER; v_n_sesudah INTEGER;
BEGIN
  v_a := public.admin_catat_belanja(
    v_pisang, (NOW() AT TIME ZONE 'Asia/Jakarta')::date, 7000, 200000);

  SELECT count(*)::INTEGER INTO v_n_sebelum FROM public.belanja;

  BEGIN
    PERFORM public.admin_perbaiki_belanja(v_a.id, 1200, 200000, 1000);
    RAISE EXCEPTION 'GAGAL: daging 1.200 g dari buah 1.000 g diterima';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DAGING_LEBIH_BERAT_DARI_BELI' THEN RAISE; END IF;
  END;

  -- Yang penting: penolakannya tidak meninggalkan pembatal yatim.
  SELECT count(*)::INTEGER INTO v_n_sesudah FROM public.belanja;
  IF v_n_sesudah <> v_n_sebelum THEN
    RAISE EXCEPTION 'GAGAL: % baris tertinggal dari perbaikan yang gagal',
      v_n_sesudah - v_n_sebelum;
  END IF;

  RAISE NOTICE 'OK: ditolak tanpa meninggalkan pembatal yatim';
END;
$$;

\echo ''
\echo '=== 9. Driver tidak bisa memperbaiki nota ==='
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT id INTO v_id FROM public.belanja WHERE membatalkan_id IS NULL LIMIT 1;
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);

  BEGIN
    PERFORM public.admin_perbaiki_belanja(v_id, 1, 1);
    RAISE EXCEPTION 'GAGAL: driver bisa memperbaiki nota belanja';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ADMIN_ONLY' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'OK: tertutup untuk driver';
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0033 LULUS ==='
