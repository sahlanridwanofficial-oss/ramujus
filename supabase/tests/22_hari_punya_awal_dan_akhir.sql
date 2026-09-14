-- Pengujian migrasi 0028: setiap hari jualan punya awal dan akhir.
-- Bukan bagian aplikasi.
--
-- Yang dijaga berkas ini adalah satu janji: SETELAH create_order selesai,
-- tidak mungkin ada cup yang tercatat terjual tanpa punya baris alokasi
-- yang bisa dipertanggungjawabkan. Sebelum 0028 janji itu bocor di tiga
-- tempat sekaligus, dan ketiganya pernah terjadi di produksi.
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
  ('aaaaaaaa-0000-0000-0000-000000000001', 'PAMAN',   13000, 'smoothie', 1, 900, true),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'PASUTRI', 13000, 'smoothie', 2, 900, true);

INSERT INTO public.shifts (id, driver_id, status) VALUES
  ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'active');

-- Sengaja TIDAK ada baris driver_daily_allocations. Itu keadaan 10 dan 11
-- September: gerobak berangkat, tidak ada yang mencatat muatannya.

SET ROLE authenticated;
SET test.uid = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '=== 1. Hari tanpa alokasi: penjualan TETAP masuk, barisnya dibuat ==='
-- Kejadian 10 & 11 September: 22 cup terjual, nol baris alokasi. Dulu
-- pesanannya tersimpan dan seluruh pemotongan stok dilewati dalam diam.
DO $$
DECLARE
  v          public.orders;
  v_alloc    public.driver_daily_allocations;
  v_terjual  INTEGER;
  v_muatan   INTEGER;
BEGIN
  v := public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":3}]'::jsonb);

  IF v.total_amount <> 39000 THEN
    RAISE EXCEPTION 'GAGAL: penjualan ditolak/salah total % — driver tidak boleh kena getahnya', v.total_amount;
  END IF;

  SELECT * INTO v_alloc FROM public.driver_daily_allocations
   WHERE driver_id = '11111111-1111-1111-1111-111111111111'
     AND date = (NOW() AT TIME ZONE 'Asia/Jakarta')::date;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'GAGAL: hari berjualan masih tanpa baris alokasi — lubang 10-11 Sep belum tertutup';
  END IF;
  IF NOT v_alloc.dibuat_otomatis THEN
    RAISE EXCEPTION 'GAGAL: baris tidak ditandai dibuat_otomatis — admin tidak akan tahu muatannya tak pernah dicatat';
  END IF;

  SELECT initial_quantity, sold_quantity INTO v_muatan, v_terjual
    FROM public.driver_allocation_items
   WHERE allocation_id = v_alloc.id
     AND product_id = 'aaaaaaaa-0000-0000-0000-000000000001';

  IF v_muatan <> 0 THEN
    RAISE EXCEPTION 'GAGAL: muatan % dikarang — yang tidak dicatat harus tetap 0', v_muatan;
  END IF;
  IF v_terjual <> 3 THEN
    RAISE EXCEPTION 'GAGAL: terjual % — cup tidak terhubung ke alokasi mana pun', v_terjual;
  END IF;

  RAISE NOTICE 'OK: alokasi lahir dari penjualan, muatan 0, terjual 3';
END;
$$;

\echo ''
\echo '=== 2. Produk kedua yang tak ada di alokasi ikut dapat baris ==='
-- Lubang ketiga: "IF FOUND" pada driver_allocation_items. Alokasinya ada,
-- tapi produk ini tidak di dalamnya, jadi dulu dilewati diam-diam.
DO $$
DECLARE v public.orders; v_terjual INTEGER;
BEGIN
  v := public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":2}]'::jsonb);

  SELECT ai.sold_quantity INTO v_terjual
    FROM public.driver_allocation_items ai
    JOIN public.driver_daily_allocations a ON a.id = ai.allocation_id
   WHERE a.driver_id = '11111111-1111-1111-1111-111111111111'
     AND a.date = (NOW() AT TIME ZONE 'Asia/Jakarta')::date
     AND ai.product_id = 'aaaaaaaa-0000-0000-0000-000000000002';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'GAGAL: produk di luar alokasi tidak dapat baris — 2 cup hilang dari pertanggungjawaban';
  END IF;
  IF v_terjual <> 2 THEN
    RAISE EXCEPTION 'GAGAL: terjual %, harusnya 2', v_terjual;
  END IF;

  RAISE NOTICE 'OK: produk di luar alokasi dapat barisnya sendiri';
END;
$$;

\echo ''
\echo '=== 3. Terjual melebihi muatan: dicatat, BUKAN ditolak ==='
-- Kejadian 12 September: PAMAN dibawa 5, terjual 6. Dulu cup keenam
-- ditolak INSUFFICIENT_STOCK — pembelinya sudah dilayani, jadi yang batal
-- cuma catatannya.
DO $$
DECLARE v public.orders; v_terjual INTEGER; v_muatan INTEGER;
BEGIN
  -- Admin baru mencatat muatan SEKARANG, setelah 3 cup terjual — persis
  -- 12 September, ketika alokasi jam 13:05 menyusul penjualan jam 12:17.
  -- Sekalian menguji bahwa save_morning_allocation tidak menimpa angka
  -- terjual yang sudah telanjur terkumpul di baris otomatis.
  PERFORM set_config('test.uid', '22222222-2222-2222-2222-222222222222', true);
  PERFORM public.save_morning_allocation(
    '11111111-1111-1111-1111-111111111111',
    (NOW() AT TIME ZONE 'Asia/Jakarta')::date,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","initial_quantity":5}]'::jsonb);

  SELECT ai.sold_quantity INTO v_terjual
    FROM public.driver_allocation_items ai
    JOIN public.driver_daily_allocations a ON a.id = ai.allocation_id
   WHERE a.driver_id = '11111111-1111-1111-1111-111111111111'
     AND a.date = (NOW() AT TIME ZONE 'Asia/Jakarta')::date
     AND ai.product_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_terjual <> 3 THEN
    RAISE EXCEPTION 'GAGAL: mencatat muatan menimpa angka terjual jadi % — 3 cup pagi hilang', v_terjual;
  END IF;

  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);

  -- 3 sudah terjual, muatan 5, sekarang jual 4 lagi -> 7 dari 5.
  v := public.create_order(
    p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
    p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":4}]'::jsonb);

  IF v.total_amount <> 52000 THEN
    RAISE EXCEPTION 'GAGAL: penjualan melebihi muatan ditolak — 4 cup asli jadi hilang';
  END IF;

  SELECT ai.initial_quantity, ai.sold_quantity INTO v_muatan, v_terjual
    FROM public.driver_allocation_items ai
    JOIN public.driver_daily_allocations a ON a.id = ai.allocation_id
   WHERE a.driver_id = '11111111-1111-1111-1111-111111111111'
     AND a.date = (NOW() AT TIME ZONE 'Asia/Jakarta')::date
     AND ai.product_id = 'aaaaaaaa-0000-0000-0000-000000000001';

  IF v_terjual <> 7 THEN
    RAISE EXCEPTION 'GAGAL: terjual %, harusnya 7', v_terjual;
  END IF;
  IF v_muatan <> 5 THEN
    RAISE EXCEPTION 'GAGAL: muatan diam-diam dinaikkan jadi % — selisihnya harus tetap kelihatan', v_muatan;
  END IF;

  RAISE NOTICE 'OK: terjual 7 dari muatan 5 — janggal, tercatat, dan masih bisa ditanyakan';
END;
$$;

\echo ''
\echo '=== 4. Hari yang muatannya tak pernah dicatat tidak bisa dikunci ==='
SET test.uid = '22222222-2222-2222-2222-222222222222';
DO $$
DECLARE v_alloc UUID;
BEGIN
  SELECT id INTO v_alloc FROM public.driver_daily_allocations
   WHERE driver_id = '11111111-1111-1111-1111-111111111111'
     AND date = (NOW() AT TIME ZONE 'Asia/Jakarta')::date;

  BEGIN
    PERFORM public.lock_reconciliation(v_alloc, 'coba kunci');
    RAISE EXCEPTION 'GAGAL: hari tanpa catatan muatan berhasil dikunci';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'MUATAN_BELUM_DICATAT:%' THEN
      RAISE EXCEPTION 'GAGAL: sebab penolakan "%" tidak menyebut jalan keluarnya', SQLERRM;
    END IF;
  END;

  RAISE NOTICE 'OK: ditolak MUATAN_BELUM_DICATAT — sebab yang bisa ditindaklanjuti';
END;
$$;

\echo ''
\echo '=== 5. Mengakui muatan: stok pusat ikut terpotong, lalu bisa dikunci ==='
DO $$
DECLARE
  v_alloc    UUID;
  v_diakui   INTEGER;
  v_stok_paman_sebelum INTEGER;
  v_stok_paman_sesudah INTEGER;
  v_stok_pas_sesudah   INTEGER;
BEGIN
  SELECT id INTO v_alloc FROM public.driver_daily_allocations
   WHERE driver_id = '11111111-1111-1111-1111-111111111111'
     AND date = (NOW() AT TIME ZONE 'Asia/Jakarta')::date;

  SELECT stock_quantity INTO v_stok_paman_sebelum
    FROM public.products WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';

  -- PAMAN: terjual 7, muatan 5  -> kurang 2
  -- PASUTRI: terjual 2, muatan 0 -> kurang 2
  v_diakui := public.admin_akui_muatan_dari_penjualan(v_alloc);

  IF v_diakui <> 4 THEN
    RAISE EXCEPTION 'GAGAL: % cup diakui, harusnya 4 (PAMAN 2 + PASUTRI 2)', v_diakui;
  END IF;

  SELECT stock_quantity INTO v_stok_paman_sesudah
    FROM public.products WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  SELECT stock_quantity INTO v_stok_pas_sesudah
    FROM public.products WHERE id = 'aaaaaaaa-0000-0000-0000-000000000002';

  IF v_stok_paman_sesudah <> v_stok_paman_sebelum - 2 THEN
    RAISE EXCEPTION 'GAGAL: stok pusat PAMAN % -> %, harusnya turun 2 — cup itu fisik keluar basecamp',
      v_stok_paman_sebelum, v_stok_paman_sesudah;
  END IF;
  IF v_stok_pas_sesudah <> 898 THEN
    RAISE EXCEPTION 'GAGAL: stok pusat PASUTRI %, harusnya 898', v_stok_pas_sesudah;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.allocation_audit_log
                  WHERE allocation_id = v_alloc AND action = 'muatan_diakui') THEN
    RAISE EXCEPTION 'GAGAL: pengakuan muatan tidak meninggalkan jejak';
  END IF;

  -- Sekarang sisa fisik diisi dan hari ditutup.
  UPDATE public.driver_allocation_items SET physical_remaining = 0
   WHERE allocation_id = v_alloc;
  UPDATE public.driver_daily_allocations
     SET total_cash_collected = 117000, cash_settled = 117000
   WHERE id = v_alloc;

  PERFORM public.lock_reconciliation(v_alloc, 'ditutup setelah muatan diakui');

  IF (SELECT status FROM public.driver_daily_allocations WHERE id = v_alloc) <> 'reconciled' THEN
    RAISE EXCEPTION 'GAGAL: hari masih belum terkunci setelah muatan diakui';
  END IF;

  RAISE NOTICE 'OK: 4 cup diakui, stok pusat menyusul, hari terkunci';
END;
$$;

\echo ''
\echo '=== 6. Hari yang sudah dikunci tetap menolak penjualan baru ==='
SET test.uid = '11111111-1111-1111-1111-111111111111';
DO $$
BEGIN
  BEGIN
    PERFORM public.create_order(
      p_shift_id => 'cccccccc-0000-0000-0000-000000000001',
      p_items    => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb);
    RAISE EXCEPTION 'GAGAL: penjualan masuk ke hari yang angkanya sudah final';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DAY_RECONCILED' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'OK: DAY_RECONCILED masih menjaga angka yang sudah dikunci';
END;
$$;

\echo ''
\echo '=== 7. Daftar hari yang perlu perhatian: hari ini tidak ditagih ==='
DO $$
DECLARE
  v_kemarin DATE := (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1;
  v_baris   RECORD;
  v_jumlah  INTEGER;
BEGIN
  -- Penjualan kemarin, tanpa alokasi — hari yang menggantung.
  PERFORM public.create_order(
    p_shift_id   => 'cccccccc-0000-0000-0000-000000000001',
    p_items      => '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":5}]'::jsonb,
    p_created_at => NOW() - INTERVAL '1 day');

  PERFORM set_config('test.uid', '22222222-2222-2222-2222-222222222222', true);

  SELECT count(*) INTO v_jumlah FROM public.admin_hari_perlu_perhatian();
  IF v_jumlah <> 1 THEN
    RAISE EXCEPTION 'GAGAL: % hari ditagih, harusnya 1 (hari ini sudah dikunci, dan hari berjalan tidak ditagih)', v_jumlah;
  END IF;

  SELECT * INTO v_baris FROM public.admin_hari_perlu_perhatian();

  IF v_baris.hari <> v_kemarin THEN
    RAISE EXCEPTION 'GAGAL: yang ditagih % bukan %', v_baris.hari, v_kemarin;
  END IF;
  IF v_baris.cup <> 5 THEN
    RAISE EXCEPTION 'GAGAL: cup %, harusnya 5', v_baris.cup;
  END IF;
  IF v_baris.muatan_dicatat THEN
    RAISE EXCEPTION 'GAGAL: hari ini dianggap muatannya tercatat padahal tidak pernah';
  END IF;
  IF v_baris.cup_di_luar_muatan <> 5 THEN
    RAISE EXCEPTION 'GAGAL: cup di luar muatan %, harusnya 5', v_baris.cup_di_luar_muatan;
  END IF;

  RAISE NOTICE 'OK: 1 hari ditagih (%), 5 cup, muatan belum tercatat', v_baris.hari;
END;
$$;

\echo ''
\echo '=== 8. Bukan admin ditolak dengan sebab, bukan dijawab daftar kosong ==='
DO $$
DECLARE v_alloc UUID;
BEGIN
  PERFORM set_config('test.uid', '11111111-1111-1111-1111-111111111111', true);

  BEGIN
    PERFORM public.admin_hari_perlu_perhatian();
    RAISE EXCEPTION 'GAGAL: driver bisa membaca daftar hari yang menggantung';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ADMIN_ONLY' THEN RAISE; END IF;
  END;

  SELECT id INTO v_alloc FROM public.driver_daily_allocations
   WHERE date = (NOW() AT TIME ZONE 'Asia/Jakarta')::date - 1;

  BEGIN
    PERFORM public.admin_akui_muatan_dari_penjualan(v_alloc);
    RAISE EXCEPTION 'GAGAL: driver bisa mengakui muatannya sendiri';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ADMIN_ONLY' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'OK: dua fungsi baru tertutup untuk selain admin';
END;
$$;

RESET ROLE;

\echo ''
\echo '=== SELURUH UJI 0028 LULUS ==='
