-- ============================================================
-- 0022 — Shift dan mangkal yang lupa ditutup, ditutup otomatis
-- ============================================================
--
-- Masalahnya nyata di produksi: shift Mahaliriki terbuka sejak 9 Sep
-- 10:46 dan masih terbuka 83 jam kemudian. Shift Budi terbuka sejak
-- 12 Sep 01:41 tanpa satu pun penjualan. Mangkal titik B tanggal 12 Sep
-- ditinggal terbuka saat driver pulang.
--
-- Merapikan yang sudah telanjur tidak menyelesaikan apa pun — besok
-- terjadi lagi. Yang menyelesaikan adalah penutupan otomatis.
--
-- ------------------------------------------------------------
-- Ditutup pukul berapa, dan kenapa itu penting
-- ------------------------------------------------------------
-- Laju sebuah titik = cup dibagi jam mangkal. Jam mangkal adalah
-- penyebutnya, jadi jam tutup yang salah langsung menggeser angka yang
-- dipakai memutuskan sewa ruko. Tiga pilihan, tiga akibat:
--
--   * tengah malam       -> jam membengkak   -> laju terlihat rendah
--   * penjualan terakhir -> jam menyusut     -> laju terlihat TINGGI
--   * jam pulang rutin   -> jam sebenarnya   -> laju sebenarnya
--
-- Yang kedua tampak paling "akurat" tapi justru paling berbahaya, dan
-- data sendiri yang menunjukkannya: Senin 7 Sep 2026 penjualan terakhir
-- pukul 18:08, padahal driver baru pulang pukul 21:00. Menutup di 18:08
-- mencatat 6,25 jam untuk hari yang sebenarnya 9 jam — laju melompat
-- dari 1,76 ke 2,56 cup/jam, melambung 45% ke arah "ya, sewa ruko itu".
--
-- Pilihan ketiga yang dipakai di sini. Driver RAMU berangkat dan pulang
-- pada jam yang sama setiap hari, jadi jam pulang adalah fakta rutin,
-- bukan tebakan. Kalaupun meleset, melesetnya ke arah aman: jam sedikit
-- kepanjangan membuat laju sedikit kerendahan.
--
-- Penjualan terakhir tetap dipakai sebagai LANTAI. Kalau ternyata ada
-- pesanan sesudah jam pulang, mangkal diperpanjang sampai pesanan itu —
-- penjualan yang nyata tidak boleh jatuh di luar mangkalnya sendiri.
--
-- Karena jam tutupnya masuk akal, baris ini tetap dipakai menghitung
-- cup per jam. Mengeluarkannya justru melempar titik itu ke penaksir
-- lama dari rentang pesanan — penaksir yang dulu menghasilkan 959
-- cup/jam dan yang seluruh 0019-0021 dibangun untuk menghindarinya.
-- Kolom auto_closed tetap ada supaya asal-usul angkanya bisa ditelusuri.
--
-- ------------------------------------------------------------
-- Pengaman agar tidak menutup orang yang masih kerja
-- ------------------------------------------------------------
-- Sapuan berjalan pukul 01:00 WIB dan hanya menyentuh baris yang
-- dimulai SEBELUM tengah malam WIB hari ini DAN yang drivernya tidak
-- mencatat pesanan apa pun dalam 60 menit terakhir. Baris yang ditutup
-- normal oleh driver tidak pernah terlihat oleh sapuan ini, karena
-- syarat pertamanya adalah masih terbuka.
--
-- Idempoten: aman dijalankan berulang kali.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Penanda "ditutup oleh mesin, bukan oleh manusia"
-- ------------------------------------------------------------
ALTER TABLE public.driver_stops
  ADD COLUMN IF NOT EXISTS auto_closed BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.shifts
  ADD COLUMN IF NOT EXISTS auto_closed BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.driver_stops.auto_closed IS
  'true bila ditutup oleh sapuan 0022 di jam pulang rutin, bukan oleh '
  'ketukan driver. Tetap dipakai menghitung cup per jam.';

COMMENT ON COLUMN public.shifts.auto_closed IS
  'true bila ditutup oleh sapuan 0022, bukan oleh driver.';

-- ------------------------------------------------------------
-- 2. Jam pulang rutin
-- ------------------------------------------------------------
-- Satu-satunya tempat angka ini ditulis. Kalau jam operasional gerobak
-- berubah, ubah di sini — bukan di beberapa tempat sekaligus.
CREATE OR REPLACE FUNCTION public.jam_pulang_rutin(p_hari DATE)
RETURNS TIMESTAMPTZ
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT (p_hari::timestamp + INTERVAL '21 hours 30 minutes') AT TIME ZONE 'Asia/Jakarta';
$fn$;

COMMENT ON FUNCTION public.jam_pulang_rutin(DATE) IS
  'Pukul 21:30 WIB pada tanggal itu: jam gerobak berhenti berjualan.';

-- ------------------------------------------------------------
-- 3. Sapuan
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tutup_yang_lupa_ditutup()
RETURNS TABLE (mangkal_ditutup INTEGER, shift_ditutup INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_batas TIMESTAMPTZ := public.wib_day_start((NOW() AT TIME ZONE 'Asia/Jakarta')::date);
  v_diam  INTERVAL    := INTERVAL '60 minutes';
  v_stop  INTEGER;
  v_shift INTEGER;
BEGIN
  -- --- Mangkal ---
  -- Selesai = jam pulang rutin pada hari mangkal itu, ditarik lebih jauh
  -- bila ada pesanan sesudahnya. GREATEST dengan started_at menjaga
  -- mangkal yang kebetulan dibuka setelah jam pulang: panjangnya nol,
  -- lalu dibuang aturan "di bawah 5 menit bukan mangkal" — bukan
  -- menghasilkan durasi negatif.
  WITH kandidat AS (
    SELECT s.id, s.started_at, s.driver_id,
           (SELECT min(b.started_at) FROM public.driver_stops b
             WHERE b.driver_id = s.driver_id AND b.started_at > s.started_at) AS mangkal_berikut
      FROM public.driver_stops s
     WHERE s.ended_at IS NULL
       AND s.started_at < v_batas
       AND NOT EXISTS (
             SELECT 1 FROM public.orders o
              WHERE o.driver_id = s.driver_id
                AND o.created_at > NOW() - v_diam)
  ),
  waktu AS (
    SELECT k.id,
           GREATEST(
             k.started_at,
             public.jam_pulang_rutin((k.started_at AT TIME ZONE 'Asia/Jakarta')::date),
             -- Lantai ini dibatasi ke HARI mangkal itu sendiri. Tanpa
             -- batas hari, mangkal Senin yang lupa ditutup akan menyedot
             -- penjualan Selasa dan tutup hari Rabu — satu mangkal
             -- menelan tiga hari kerja sekaligus.
             COALESCE((SELECT max(o.created_at) FROM public.orders o
                        WHERE o.driver_id = k.driver_id
                          AND o.created_at >= k.started_at
                          AND o.created_at < public.wib_day_start(
                                (k.started_at AT TIME ZONE 'Asia/Jakarta')::date + 1)
                          AND (k.mangkal_berikut IS NULL
                               OR o.created_at < k.mangkal_berikut)),
                      k.started_at)
           ) AS selesai
      FROM kandidat k
  )
  UPDATE public.driver_stops d
     SET ended_at = w.selesai, auto_closed = true
    FROM waktu w
   WHERE d.id = w.id;
  GET DIAGNOSTICS v_stop = ROW_COUNT;

  -- --- Shift ---
  -- Shift tidak dipakai analitik mana pun. Ia hanya perlu berhenti
  -- menampilkan "sedang bekerja" di aplikasi driver berhari-hari.
  WITH kandidat AS (
    SELECT sh.id, sh.start_time,
           GREATEST(
             sh.start_time,
             public.jam_pulang_rutin((sh.start_time AT TIME ZONE 'Asia/Jakarta')::date),
             -- Dibatasi ke hari shift itu dimulai, alasan yang sama.
             COALESCE((SELECT max(o.created_at) FROM public.orders o
                        WHERE o.shift_id = sh.id
                          AND o.created_at < public.wib_day_start(
                                (sh.start_time AT TIME ZONE 'Asia/Jakarta')::date + 1)),
                      sh.start_time)
           ) AS selesai
      FROM public.shifts sh
     WHERE sh.status = 'active'
       AND sh.start_time < v_batas
       AND NOT EXISTS (
             SELECT 1 FROM public.orders o
              WHERE o.driver_id = sh.driver_id
                AND o.created_at > NOW() - v_diam)
  )
  UPDATE public.shifts s
     SET end_time    = k.selesai,
         status      = 'completed',
         auto_closed = true
    FROM kandidat k
   WHERE s.id = k.id;
  GET DIAGNOSTICS v_shift = ROW_COUNT;

  mangkal_ditutup := v_stop;
  shift_ditutup   := v_shift;
  RETURN NEXT;
END;
$fn$;

-- Tidak ada peran aplikasi yang perlu menjalankan ini; penjadwal
-- berjalan sebagai pemilik basis data.
REVOKE ALL ON FUNCTION public.tutup_yang_lupa_ditutup() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 4. Penjadwalan: 01:00 WIB = 18:00 UTC
-- ------------------------------------------------------------
-- Pola yang sama dengan 0011: pg_cron tidak selalu ada (basis data uji
-- lokal tidak punya, dan hak akses skema cron berbeda antar proyek).
-- Ketiadaannya tidak boleh menggagalkan migrasi — fungsinya tetap
-- terpasang dan tetap bisa dipanggil manual.
DO $sched$
DECLARE
  v_has_cron BOOLEAN;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') INTO v_has_cron;

  IF NOT v_has_cron THEN
    RAISE NOTICE 'pg_cron belum aktif — penjadwalan dilewati.';
    RAISE NOTICE 'Aktifkan di Dashboard Supabase → Database → Extensions → pg_cron,';
    RAISE NOTICE 'lalu jalankan berkas migrasi ini sekali lagi.';
    RAISE NOTICE 'Sementara itu, tutup manual: SELECT public.tutup_yang_lupa_ditutup();';
    RETURN;
  END IF;

  BEGIN
    PERFORM cron.unschedule('ramujus-tutup-yang-lupa-ditutup');
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- belum pernah dijadwalkan
  END;

  PERFORM cron.schedule(
    'ramujus-tutup-yang-lupa-ditutup',
    '0 18 * * *',
    $job$SELECT public.tutup_yang_lupa_ditutup();$job$
  );

  RAISE NOTICE 'Terjadwal: tutup shift & mangkal yang lupa, setiap hari 01:00 WIB.';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Penjadwalan pg_cron gagal (%). Jadwalkan manual:', SQLERRM;
  RAISE NOTICE '  SELECT cron.schedule(''ramujus-tutup-yang-lupa-ditutup'', ''0 18 * * *'', $$SELECT public.tutup_yang_lupa_ditutup();$$);';
END;
$sched$;


-- ------------------------------------------------------------
-- 5. Batas 6 jam hanya untuk mangkal yang masih terbuka
-- ------------------------------------------------------------
-- Sama persis dengan 0021, satu perubahan: mangkal yang SUDAH ditutup
-- dipakai apa adanya. Sebelum 0022 setiap mangkal dipotong 6 jam karena
-- yang terbuka bisa menggantung berhari-hari. Sekarang yang menggantung
-- ditutup sapuan, jadi pemotongan itu hanya menyakiti hari kerja penuh:
-- mangkal 11:02-21:30 akan tercatat 6 jam, bukan 10,5 — dan lajunya
-- melambung 75%.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_location_clusters(
  p_from         DATE,
  p_to           DATE,
  p_grid_meters  INTEGER DEFAULT 300
)
RETURNS TABLE (
  cluster_lat         DOUBLE PRECISION,
  cluster_lng         DOUBLE PRECISION,
  cups                INTEGER,
  revenue             BIGINT,
  orders              INTEGER,
  days_active         INTEGER,
  cups_per_active_day NUMERIC,
  best_hour           INTEGER,
  revenue_share       NUMERIC,
  spread_meters       INTEGER,
  stops               INTEGER,
  measured_stops      INTEGER,
  hours_measured      NUMERIC,
  cups_measured       INTEGER,
  cups_per_hour       NUMERIC,
  -- 'tercatat' = dari tombol mangkal. 'perkiraan' = dari rentang pesanan.
  -- NULL = belum cukup bukti dengan cara mana pun.
  dwell_source        TEXT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  WITH span AS (
    SELECT LEAST(p_from, p_to) AS d_from,
           LEAST(GREATEST(p_from, p_to), LEAST(p_from, p_to) + 365) AS d_to,
           GREATEST(COALESCE(p_grid_meters, 300), 50) AS grid
  ),
  pesanan AS (
    SELECT o.id, o.driver_id, o.created_at, o.latitude, o.longitude,
           (o.created_at AT TIME ZONE 'Asia/Jakarta')::date AS hari,
           EXTRACT(HOUR FROM o.created_at AT TIME ZONE 'Asia/Jakarta')::INTEGER AS jam,
           COALESCE(sum(oi.quantity) FILTER (WHERE pr.category = 'smoothie'), 0) AS cup,
           COALESCE(sum(oi.subtotal), 0) AS omzet
      FROM public.orders o
      LEFT JOIN public.order_items oi ON oi.order_id = o.id
      LEFT JOIN public.products    pr ON pr.id = oi.product_id,
           span s
     WHERE o.created_at >= public.wib_day_start(s.d_from)
       AND o.created_at <  public.wib_day_start(s.d_to + 1)
       AND o.latitude IS NOT NULL AND o.longitude IS NOT NULL
     GROUP BY o.id, o.driver_id, o.created_at, o.latitude, o.longitude, 6, 7
  ),
  acuan AS (
    SELECT (SELECT grid FROM span)::NUMERIC / 111320.0 AS d_lat,
           (SELECT grid FROM span)::NUMERIC /
             (111320.0 * GREATEST(cos(radians(avg(latitude))), 0.01)) AS d_lng,
           avg(latitude) AS lat0
      FROM pesanan
  ),
  petak AS (
    SELECT floor(p.latitude::NUMERIC  / a.d_lat) AS ix,
           floor(p.longitude::NUMERIC / a.d_lng) AS iy,
           p.driver_id, p.created_at, p.latitude, p.longitude,
           p.hari, p.jam, p.cup, p.omzet
      FROM pesanan p, acuan a
  ),
  -- --- Jalur A: lama mangkal yang benar-benar direkam ---
  mangkal AS (
    SELECT floor(st.latitude::NUMERIC  / a.d_lat) AS ix,
           floor(st.longitude::NUMERIC / a.d_lng) AS iy,
           st.id, st.driver_id, st.started_at,
           -- 0022: batas 6 jam adalah pengaman untuk mangkal yang BELUM
           -- ditutup. Mangkal yang sudah ditutup dipercaya apa adanya —
           -- hari kerja gerobak 9-11 jam, dan memotongnya jadi 6 akan
           -- memendekkan penyebut lalu melambungkan laju.
           COALESCE(st.ended_at,
                    LEAST(NOW(), st.started_at + INTERVAL '6 hours')) AS ended_at
      FROM public.driver_stops st, acuan a, span s
     WHERE st.latitude IS NOT NULL AND st.longitude IS NOT NULL
       AND st.started_at >= public.wib_day_start(s.d_from)
       AND st.started_at <  public.wib_day_start(s.d_to + 1)
  ),
  mangkal_sah AS (
    -- Di bawah 5 menit hampir selalu salah pencet, bukan mangkal.
    SELECT * FROM mangkal
     WHERE ended_at - started_at >= INTERVAL '5 minutes'
  ),
  -- Pesanan dipasangkan ke mangkal TERAKHIR yang sudah berjalan saat ia
  -- dicatat, dengan kelonggaran 30 menit setelah mangkal itu ditutup.
  --
  -- Kelonggaran itu bukan kelonggaran asal. Justru karena driver mencatat
  -- setelah selesai melayani, catatannya sering mendarat tepat saat atau
  -- sesudah gerobak pindah. Jendela yang ketat akan membuang persis
  -- pesanan yang ingin diukur — dan pengujian menemukan itu: mangkal
  -- 10:00–11:00 dengan tiga pesanan tercatat 11:00:00, 11:00:11, dan
  -- 11:00:22 menghasilkan nol cup.
  --
  -- Produksi kemudian menunjukkan 15 menit masih kurang: 12 Sep 2026,
  -- mangkal tutup 21:00, dua pesanan terakhir tercatat 21:17 — lewat dua
  -- menit, dan tiga cup hilang dari titiknya. Karena itu 30 menit.
  --
  -- Mangkal berikutnya tetap menang: begitu gerobak memulai mangkal baru,
  -- ia menjadi "mangkal terakhir yang sudah berjalan", sehingga penjualan
  -- di tempat baru tidak pernah tertarik ke tempat lama.
  pesanan_bermangkal AS (
    SELECT m.ix, m.iy, m.id AS stop_id, p.cup
      FROM pesanan p
      JOIN LATERAL (
        SELECT s.*
          FROM mangkal_sah s
         WHERE s.driver_id = p.driver_id
           AND s.started_at <= p.created_at
         ORDER BY s.started_at DESC
         LIMIT 1
      ) m ON p.created_at < m.ended_at + INTERVAL '30 minutes'
  ),
  tercatat AS (
    SELECT m.ix, m.iy,
           count(*)::INTEGER AS jumlah,
           sum(EXTRACT(EPOCH FROM (m.ended_at - m.started_at)) / 3600.0) AS jam,
           COALESCE((
             SELECT sum(pb.cup)::INTEGER FROM pesanan_bermangkal pb
              WHERE pb.ix = m.ix AND pb.iy = m.iy
           ), 0) AS cup
      FROM mangkal_sah m
     GROUP BY m.ix, m.iy
  ),
  -- --- Jalur B: perkiraan dari rentang pesanan (cadangan) ---
  kunjungan AS (
    SELECT ix, iy, hari, driver_id,
           count(*) AS pesanan, sum(cup) AS cup,
           EXTRACT(EPOCH FROM (max(created_at) - min(created_at))) / 3600.0 AS jam_mangkal
      FROM petak GROUP BY ix, iy, hari, driver_id
  ),
  perkiraan AS (
    SELECT ix, iy,
           count(*)::INTEGER AS jumlah,
           sum(jam_mangkal)  AS jam,
           sum(cup)::INTEGER AS cup
      FROM kunjungan
     WHERE pesanan >= 2 AND jam_mangkal >= 0.25
     GROUP BY ix, iy
  ),
  agg AS (
    SELECT p.ix, p.iy,
           avg(p.latitude) AS c_lat, avg(p.longitude) AS c_lng,
           sum(p.cup)::INTEGER AS cups, sum(p.omzet)::BIGINT AS revenue,
           count(*)::INTEGER AS orders, count(DISTINCT p.hari)::INTEGER AS days_active,
           sqrt(((max(p.latitude) - min(p.latitude)) * 111320.0) ^ 2 +
                ((max(p.longitude) - min(p.longitude)) * 111320.0 *
                 GREATEST(cos(radians((SELECT lat0 FROM acuan))), 0.01)) ^ 2) AS spread
      FROM petak p GROUP BY p.ix, p.iy
  ),
  jumlah_kunjungan AS (
    SELECT ix, iy, count(*)::INTEGER AS stops FROM kunjungan GROUP BY ix, iy
  ),
  jam_terbaik AS (
    SELECT DISTINCT ON (ix, iy) ix, iy, jam
      FROM (SELECT ix, iy, jam, sum(cup) AS cup FROM petak GROUP BY ix, iy, jam) t
     ORDER BY ix, iy, cup DESC, jam
  ),
  total AS (SELECT COALESCE(sum(revenue), 0)::BIGINT AS rev FROM agg),
  -- Yang direkam selalu menang atas yang diperkirakan.
  dipilih AS (
    SELECT a.ix, a.iy,
           COALESCE(t.jumlah, e.jumlah, 0)                  AS measured_stops,
           COALESCE(t.jam, e.jam, 0)                        AS hours_measured,
           COALESCE(t.cup, e.cup, 0)                        AS cups_measured,
           CASE WHEN t.jam > 0 THEN 'tercatat'
                WHEN e.jam > 0 THEN 'perkiraan'
                ELSE NULL END                               AS dwell_source
      FROM agg a
      LEFT JOIN tercatat  t ON t.ix = a.ix AND t.iy = a.iy
      LEFT JOIN perkiraan e ON e.ix = a.ix AND e.iy = a.iy
  )
  SELECT a.c_lat::DOUBLE PRECISION, a.c_lng::DOUBLE PRECISION,
         a.cups, a.revenue, a.orders, a.days_active,
         round(a.cups::NUMERIC / NULLIF(a.days_active, 0), 1),
         j.jam,
         CASE WHEN (SELECT rev FROM total) > 0
              THEN round(a.revenue * 100.0 / (SELECT rev FROM total), 1) ELSE 0 END,
         round(a.spread)::INTEGER,
         k.stops,
         d.measured_stops,
         round(d.hours_measured, 2),
         d.cups_measured,
         CASE WHEN d.hours_measured > 0
              THEN round(d.cups_measured::NUMERIC / d.hours_measured, 2)
              ELSE NULL END,
         d.dwell_source
    FROM agg a
    JOIN jumlah_kunjungan k ON k.ix = a.ix AND k.iy = a.iy
    JOIN dipilih          d ON d.ix = a.ix AND d.iy = a.iy
    LEFT JOIN jam_terbaik j ON j.ix = a.ix AND j.iy = a.iy
   WHERE public.get_user_role(auth.uid()) = 'admin'
   ORDER BY a.cups DESC, a.revenue DESC;
$$;

REVOKE ALL ON FUNCTION public.admin_location_clusters(DATE, DATE, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_location_clusters(DATE, DATE, INTEGER) TO authenticated;

NOTIFY pgrst, 'reload schema';
