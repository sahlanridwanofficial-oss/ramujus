-- ============================================================
-- 0011 — Retensi histori GPS benar-benar berjalan
--
-- Jalankan di Supabase SQL Editor SETELAH 0010. Aman dijalankan berulang.
--
-- Masalah: prune_location_logs() sudah ada sejak 0002, lengkap dengan
-- catatan "jadwalkan lewat pg_cron bila tersedia" — dan tidak pernah
-- dipanggil dari mana pun. Tidak ada satu pun pemanggil di aplikasi, dan
-- tidak ada penjadwal di repositori.
--
-- location_logs adalah tabel yang tumbuh paling cepat. Dengan
-- historyIntervalSeconds 120 detik (src/lib/constants.ts), satu gerobak
-- menyimpan sekitar 360 baris per hari kerja 12 jam; pada 100 gerobak itu
-- ±36.000 baris per hari, atau belasan juta per tahun — di tabel yang tidak
-- pernah dibaca lebih dari beberapa hari ke belakang. Yang habis lebih dulu
-- adalah kuota penyimpanan, dan itu terjadi diam-diam.
--
-- Berkas ini menjadwalkan pemangkasan harian. Bila pg_cron tidak tersedia
-- (Postgres polos, atau ekstensinya belum diaktifkan di Supabase), berkas
-- ini TIDAK gagal: ia memberi tahu apa yang harus dilakukan dan berhenti.
-- Aktifkan lewat Dashboard Supabase → Database → Extensions → pg_cron, lalu
-- jalankan berkas ini sekali lagi.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Pembungkus yang aman dipanggil penjadwal
--
-- prune_location_logs() sengaja tidak diberikan ke role mana pun, dan
-- pg_cron menjalankan perintahnya sebagai pemilik job. Pembungkus ini
-- mencatat hasilnya ke log server, sehingga jumlah baris yang terhapus
-- terlihat di Logs Supabase alih-alih menghilang tanpa jejak.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prune_location_logs_job(p_keep_days INTEGER DEFAULT 60)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_deleted INTEGER;
BEGIN
  v_deleted := public.prune_location_logs(p_keep_days);
  RAISE LOG 'prune_location_logs: % baris histori GPS dihapus (retensi % hari)',
    v_deleted, p_keep_days;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_location_logs_job(INTEGER) FROM PUBLIC;

-- ------------------------------------------------------------
-- 2. Jadwalkan harian pukul 03:00 WIB
--
-- pg_cron memakai UTC, jadi 03:00 WIB adalah 20:00 UTC hari sebelumnya —
-- jam sepi, jauh dari jam operasional gerobak.
--
-- Seluruhnya dibungkus penanganan galat: berkas migrasi tidak boleh gagal
-- hanya karena ekstensi opsional belum aktif.
-- ------------------------------------------------------------
DO $do$
DECLARE
  v_has_cron BOOLEAN;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') INTO v_has_cron;

  IF NOT v_has_cron THEN
    RAISE NOTICE 'pg_cron belum aktif — penjadwalan dilewati.';
    RAISE NOTICE 'Aktifkan di Dashboard Supabase → Database → Extensions → pg_cron,';
    RAISE NOTICE 'lalu jalankan berkas migrasi ini sekali lagi.';
    RAISE NOTICE 'Sementara itu, pangkas manual: SELECT public.prune_location_logs(60);';
    RETURN;
  END IF;

  -- Hapus job lama dengan nama yang sama supaya berkas ini idempoten dan
  -- tidak menumpuk jadwal ganda setiap kali dijalankan.
  BEGIN
    PERFORM cron.unschedule('ramujus-prune-location-logs');
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- belum pernah dijadwalkan
  END;

  PERFORM cron.schedule(
    'ramujus-prune-location-logs',
    '0 20 * * *',
    $job$SELECT public.prune_location_logs_job(60);$job$
  );

  RAISE NOTICE 'Terjadwal: pemangkasan histori GPS setiap hari 03:00 WIB, retensi 60 hari.';
EXCEPTION WHEN OTHERS THEN
  -- Hak akses ke skema cron berbeda antar proyek; jangan gagalkan migrasi.
  RAISE NOTICE 'Penjadwalan pg_cron gagal (%). Jadwalkan manual:', SQLERRM;
  RAISE NOTICE '  SELECT cron.schedule(''ramujus-prune-location-logs'', ''0 20 * * *'', $$SELECT public.prune_location_logs_job(60);$$);';
END;
$do$;
