'use client'

/**
 * Analitik operasional: bahan untuk memutuskan JAM dan LOKASI.
 *
 * Dipisah dari halaman Analitik karena menjawab pertanyaan yang berbeda.
 * Bagian lain menjawab "berapa yang terjual"; bagian ini menjawab "di mana
 * dan kapan gerobak sebaiknya berada".
 *
 * Satu gagasan menjalankan seluruh layar ini: CUP PER JAM, bukan cup per
 * hari. Cup per hari mencampur dua hal yang harus dipisah — lokasi yang
 * ramai dan driver yang kebetulan kerja lebih lama. Hanya cup per jam yang
 * bisa membandingkan gerobak dengan gerobak, dan titik dengan titik.
 *
 * Untuk alasan yang sama, setiap angka rata-rata di sini selalu ditemani
 * pembaginya (hari aktif / jam kerja). Angka bagus dari satu hari tidak
 * boleh terlihat sama meyakinkan dengan angka bagus dari tiga puluh hari.
 */

import { useEffect, useMemo, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { describeRpcError, firstRow } from '@/lib/rpc'
import { BREAK_EVEN_CUPS_PER_DAY, MARGIN_PER_CUP } from '@/lib/constants'
import {
  Loader2, Clock, MapPin, TriangleAlert, ExternalLink,
  Gauge, CalendarRange, Info, Target, Navigation, Tent, Wallet,
} from 'lucide-react'

interface HourRow {
  hour_wib: number
  cups: number
  revenue: number
  orders: number
  days_active: number
  cups_per_active_day: number
  revenue_share: number
}

interface ClusterRow {
  cluster_lat: number
  cluster_lng: number
  cups: number
  revenue: number
  orders: number
  days_active: number
  cups_per_active_day: number
  best_hour: number | null
  revenue_share: number
  /** Seberapa rapat pesanannya, dalam meter. Besar = itu perjalanan, bukan titik. */
  spread_meters: number
  /** Kunjungan = satu gerobak, satu hari, di titik ini. */
  stops: number
  /** Kunjungan yang lama mangkalnya benar-benar terukur (≥ 2 pesanan). */
  measured_stops: number
  hours_measured: number
  cups_measured: number
  /** null = belum bisa diketahui. Bukan nol. */
  cups_per_hour: number | null
  /**
   * 'tercatat'  — dari tombol mangkal driver. Akurat.
   * 'perkiraan' — dari rentang stempel pesanan. Bisa kelebihan bila driver
   *               mencatat beberapa pesanan sekaligus setelah melayani.
   */
  dwell_source: 'tercatat' | 'perkiraan' | null
}

/**
 * Di atas jarak ini, sebuah kelompok bukan titik mangkal melainkan ruas
 * yang dilewati — dan satu pin peta tidak mewakilinya, betapa pun benar
 * titik tengahnya dihitung.
 */
const SPREAD_IS_A_ROUTE_M = 150

/**
 * Laju yang harus dicapai satu titik agar ruko kecil di situ tidak rugi.
 *
 * Biaya tetap ruko kecil (sewa + 1 pegawai) ±Rp6 juta/bulan. Di margin
 * Rp6.500/cup itu ±923 cup/bulan; dibagi 26 hari dan 9 jam buka, keluar
 * angka di bawah. Ini ambang untuk MEMUTUSKAN SEWA, bukan target harian
 * gerobak — gerobak untung jauh di bawah ini karena nyaris tanpa biaya tetap.
 */
const CADANGAN_RUKO_PER_JAM = 4.4

/**
 * Laju yang harus dicapai satu titik agar GEROBAK di situ tidak rugi.
 *
 * Gerobak dan ruko berjalan berdampingan, dan biayanya jauh berbeda:
 * gerobak tidak bayar sewa. Biaya tetapnya Rp2,5 juta/bulan, di margin
 * Rp5.000/cup itu 20 cup/hari (26 hari jual), dibagi ±9,8 jam mangkal
 * yang benar-benar terekam pada 12 Sep 2026.
 *
 * Satu ambang saja menyesatkan, dan arah kesalahannya berbahaya: titik
 * sore pada 12 Sep mencatat 2,06 cup/jam. Diukur dengan ambang ruko ia
 * "jauh dari layak" — padahal untuk gerobak ia sudah lewat. Data yang
 * sama, kesimpulan berlawanan, semata karena struktur biayanya beda.
 * Menyembunyikan itu berarti membuang titik yang sebenarnya sudah
 * menghasilkan.
 */
const CADANGAN_GEROBAK_PER_JAM = 2.0

/**
 * Bukti minimum sebelum sebuah titik boleh disebut "tembus ambang ruko".
 *
 * Database sudah menolak rentang yang terlalu pendek, tetapi laju yang sah
 * pun bisa menyesatkan bila datangnya dari satu kunjungan singkat. Pada
 * data produksi ada titik dengan 4 cup total dalam satu mampir 25 menit —
 * secara hitungan 9,6 cup/jam, dan tanpa syarat ini ia akan tampil hijau
 * seolah-olah layak disewa. Empat cup bukan alasan menandatangani kontrak
 * dua tahun.
 */
const ENOUGH_EVIDENCE = { stops: 2, hours: 1 }

function hasEnoughEvidence(c: ClusterRow): boolean {
  return c.measured_stops >= ENOUGH_EVIDENCE.stops && num(c.hours_measured) >= ENOUGH_EVIDENCE.hours
}

/**
 * Angka perkiraan tidak pernah boleh dipakai memutuskan sewa.
 *
 * Perkiraan datang dari rentang stempel pesanan, dan driver sering mencatat
 * beberapa pesanan sekaligus setelah selesai melayani — rentangnya menyusut
 * dan lajunya tampil lebih tinggi dari kenyataan. Kelebihannya selalu ke
 * arah yang menggoda untuk menyewa.
 */
function isTrustedForLease(c: ClusterRow): boolean {
  return c.dwell_source === 'tercatat' && hasEnoughEvidence(c)
}

function clearsRukoBar(c: ClusterRow, bar: Ambang): boolean {
  return (
    c.cups_per_hour != null &&
    num(c.cups_per_hour) >= bar.ruko &&
    isTrustedForLease(c)
  )
}

/**
 * Syarat buktinya sama ketatnya dengan ruko.
 *
 * Taruhannya memang lebih kecil — menaruh gerobak di tempat yang salah
 * bisa dibatalkan besok, kontrak sewa tidak. Tapi angka yang dipakai
 * tetap angka yang sama, dan perkiraan dari rentang pesanan tetap
 * melambung ke arah yang menggoda. Melonggarkan bukti di sini hanya akan
 * membuat gerobak berdiri berminggu-minggu di titik yang sebenarnya sepi.
 */
function clearsGerobakBar(c: ClusterRow, bar: Ambang): boolean {
  return (
    c.cups_per_hour != null &&
    num(c.cups_per_hour) >= bar.gerobak &&
    isTrustedForLease(c)
  )
}

/**
 * Ambang cup per jam untuk dua struktur biaya yang berjalan bersamaan.
 *
 * Sampai 0035 keduanya konstanta modul — dan yang satu memakai asumsi
 * margin Rp5.000 sementara satunya Rp6.500, untuk menilai titik yang
 * sama di peta yang sama. Sekarang keduanya datang dari margin yang
 * sama, terukur dari cup yang benar-benar terjual. Yang membedakan cuma
 * biaya tetap dan jam bukanya.
 */
interface Ambang { gerobak: number; ruko: number }

/**
 * Ekonomi terukur pada rentang terpilih. Seluruh medannya boleh NULL:
 * belum ada cup yang bisa dinilai berarti belum tahu, bukan nol.
 */
interface EkonomiRow {
  cup: number
  cup_ternilai: number
  omzet: number
  biaya_bahan: number | null
  laba_kotor: number | null
  laba_per_cup: number | null
  hari_jualan: number
  biaya_tetap: number | null
  laba_bersih: number | null
  impas_per_hari: number | null
  impas_gerobak_jam: number | null
  impas_ruko_jam: number | null
  harga_perkiraan: boolean
  lengkap: boolean
}

/** Vonis satu titik terhadap dua struktur biaya yang berjalan bersamaan. */
function verdictLabel(c: ClusterRow, bar: Ambang): { text: string; tone: string } {
  if (!isTrustedForLease(c))     return { text: 'Belum cukup bukti', tone: 'text-amber-600' }
  if (clearsRukoBar(c, bar))     return { text: 'Gerobak ✓ · Ruko ✓',  tone: 'text-emerald-600' }
  if (clearsGerobakBar(c, bar))  return { text: 'Gerobak ✓ · Ruko ✗',  tone: 'text-emerald-600' }
  return { text: 'Gerobak ✗ · Ruko ✗', tone: 'text-zinc-400' }
}

interface CartRow {
  driver_id: string
  driver_name: string
  days_worked: number
  hours_worked: number
  cups: number
  revenue: number
  orders: number
  cups_per_hour: number
  cups_per_day: number
  revenue_per_hour: number
  avg_start_hour: number
  avg_end_hour: number
}

interface DayRow {
  day: string
  cups: number
  revenue: number
  orders: number
  hours_worked: number
  cups_per_hour: number
  start_hour: number
  end_hour: number
  drivers: number
}

/**
 * Satu booth event yang dikeluarkan dari peta.
 *
 * Penyaring yang bekerja diam-diam tidak bisa dipercaya, karena tidak ada
 * yang tahu kalau ia salah. Baris-baris ini adalah jendela untuk
 * memeriksanya: mangkal mana yang ditandai, berapa cup dan rupiah yang
 * ikut keluar, dan di titik mana.
 */
interface EventRow {
  stop_id: string
  driver_name: string
  mulai: string
  selesai: string | null
  jam: number | string
  cups: number
  omzet: number
  latitude: number
  longitude: number
}

interface MatrixRow {
  dow: number
  hour_wib: number
  cups: number
  revenue: number
  days_active: number
  cups_per_active_day: number
}

const DOW_LABEL = ['Min', 'Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab']

/** Pilihan ukuran petak, dipasangkan dengan keputusan yang dijawabnya. */
const GRID_OPTIONS = [
  { meters: 150, label: '150 m', hint: 'titik mangkal persis' },
  { meters: 300, label: '300 m', hint: 'ruas jalan' },
  { meters: 500, label: '500 m', hint: 'lingkungan' },
  { meters: 1000, label: '1 km', hint: 'wilayah gerobak' },
]

function num(v: unknown): number {
  const n = typeof v === 'number' ? v : parseFloat(String(v ?? 0))
  return Number.isFinite(n) ? n : 0
}

function jam(h: number | null | undefined): string {
  if (h == null) return '—'
  return `${String(Math.round(h)).padStart(2, '0')}:00`
}

export default function OpsAnalytics({ from, to }: { from: string; to: string }) {
  const [hours, setHours] = useState<HourRow[]>([])
  const [clusters, setClusters] = useState<ClusterRow[]>([])
  const [carts, setCarts] = useState<CartRow[]>([])
  const [days, setDays] = useState<DayRow[]>([])
  const [matrix, setMatrix] = useState<MatrixRow[]>([])
  const [events, setEvents] = useState<EventRow[]>([])
  const [ekonomi, setEkonomi] = useState<EkonomiRow | null>(null)
  const [grid, setGrid] = useState(300)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const supabase = createClient()

    async function load() {
      setLoading(true)
      setError(null)

      const [h, c, k, d, m, e, x] = await Promise.all([
        supabase.rpc('admin_hourly_performance', { p_from: from, p_to: to }),
        supabase.rpc('admin_location_clusters', { p_from: from, p_to: to, p_grid_meters: grid }),
        supabase.rpc('admin_cart_productivity', { p_from: from, p_to: to }),
        supabase.rpc('admin_daily_productivity', { p_from: from, p_to: to }),
        supabase.rpc('admin_daypart_matrix', { p_from: from, p_to: to }),
        supabase.rpc('admin_mangkal_event', { p_from: from, p_to: to }),
        supabase.rpc('admin_ekonomi_terkini', { p_dari: from, p_sampai: to }),
      ])

      if (cancelled) return

      // Satu kegagalan cukup untuk membuat seluruh bagian ini menyesatkan,
      // jadi yang pertama gagal langsung dilaporkan apa adanya — bukan
      // ditampilkan sebagai nol seperti bug yang dulu.
      const firstError =
        (h.error && ['admin_hourly_performance', h.error] as const) ||
        (c.error && ['admin_location_clusters', c.error] as const) ||
        (k.error && ['admin_cart_productivity', k.error] as const) ||
        (d.error && ['admin_daily_productivity', d.error] as const) ||
        (m.error && ['admin_daypart_matrix', m.error] as const) ||
        (e.error && ['admin_mangkal_event', e.error] as const)

      if (firstError) {
        setError(describeRpcError(firstError[1], firstError[0]))
        setHours([]); setClusters([]); setCarts([]); setDays([]); setMatrix([]); setEvents([])
        setEkonomi(null)
        setLoading(false)
        return
      }

      setHours((h.data ?? []) as HourRow[])
      setClusters((c.data ?? []) as ClusterRow[])
      setCarts((k.data ?? []) as CartRow[])
      setDays((d.data ?? []) as DayRow[])
      setMatrix((m.data ?? []) as MatrixRow[])
      setEvents((e.data ?? []) as EventRow[])
      // Ekonomi sengaja tidak ikut memutus halaman. Bila migrasinya belum
      // terpasang atau belum ada cup yang bisa dinilai, seluruh analitik
      // lain tetap berguna — yang terjadi hanya ambangnya jatuh ke angka
      // cadangan, dan itu dikatakan di layar.
      setEkonomi(x.error ? null : firstRow<EkonomiRow>(x.data))
      setLoading(false)
    }

    load()
    return () => { cancelled = true }
  }, [from, to, grid])

  /**
   * Ambang yang benar-benar dipakai menilai titik.
   *
   * Dari ekonomi terukur bila ada; kalau belum, jatuh ke konstanta
   * cadangan — dan layar mengatakannya, bukan diam-diam memakai tebakan
   * lama seolah-olah itu hasil pengukuran.
   */
  const bar: Ambang = useMemo(() => ({
    gerobak: num(ekonomi?.impas_gerobak_jam) || CADANGAN_GEROBAK_PER_JAM,
    ruko:    num(ekonomi?.impas_ruko_jam)    || CADANGAN_RUKO_PER_JAM,
  }), [ekonomi])

  const impasHarian = num(ekonomi?.impas_per_hari) || BREAK_EVEN_CUPS_PER_DAY
  const labaPerCup  = num(ekonomi?.laba_per_cup)   || MARGIN_PER_CUP
  const terukur     = ekonomi?.laba_per_cup != null

  const totalDays = days.length
  const maxHourNorm = useMemo(
    () => Math.max(1, ...hours.map(h => num(h.cups_per_active_day))),
    [hours]
  )
  const maxClusterCups = useMemo(
    () => Math.max(1, ...clusters.map(c => c.cups)),
    [clusters]
  )
  const maxMatrix = useMemo(
    () => Math.max(1, ...matrix.map(m => num(m.cups_per_active_day))),
    [matrix]
  )
  const bestCart = useMemo(
    () => (carts.length > 0 ? Math.max(...carts.map(c => num(c.cups_per_hour))) : 0),
    [carts]
  )

  /** Jam dianggap belum bisa dipercaya bila dijalani kurang dari sepertiga hari. */
  const thinCoverage = (daysActive: number) =>
    totalDays >= 3 && daysActive < Math.max(2, Math.ceil(totalDays / 3))

  /**
   * Kesimpulan yang bisa langsung ditindaklanjuti.
   *
   * Semuanya diturunkan dari baris yang sudah ada di layar — tidak ada
   * angka baru dari server. Tujuannya supaya kesimpulan yang sama tidak
   * perlu disusun ulang dengan mata setiap kali membuka halaman ini.
   */
  const verdict = useMemo(() => {
    // Titik terbaik diurutkan dari cup per hari aktif, bukan total cup:
    // titik yang cuma sekali didatangi tapi laku keras lebih layak diuji
    // daripada titik yang sering didatangi dengan hasil biasa saja.
    const ranked = [...clusters].sort(
      (a, b) => num(b.cups_per_active_day) - num(a.cups_per_active_day)
    )
    const best = ranked[0] ?? null

    // Berapa persen omzet datang dari dua titik teratas. Angka tinggi
    // berarti keliling ke titik lain sedang mengencerkan hasil.
    const byRevenue = [...clusters].sort((a, b) => b.revenue - a.revenue)
    const topTwoShare = byRevenue
      .slice(0, 2)
      .reduce((s, c) => s + num(c.revenue_share), 0)

    // Blok jam terbaik: jam berurutan yang nilainya di atas rata-rata.
    // Dibaca sebagai rentang kerja, bukan jam-jam terpisah, karena gerobak
    // tidak bisa muncul dan hilang tiap satu jam.
    const solid = hours.filter(h => !thinCoverage(h.days_active))
    const avg =
      solid.length > 0
        ? solid.reduce((s, h) => s + num(h.cups_per_active_day), 0) / solid.length
        : 0
    const strong = solid
      .filter(h => num(h.cups_per_active_day) >= avg && avg > 0)
      .map(h => h.hour_wib)
      .sort((a, b) => a - b)

    let bestBlock: number[] = []
    let run: number[] = []
    for (let i = 0; i < strong.length; i++) {
      if (i > 0 && strong[i] === strong[i - 1] + 1) run.push(strong[i])
      else run = [strong[i]]
      if (run.length > bestBlock.length) bestBlock = [...run]
    }

    const totalCups = days.reduce((s, d) => s + d.cups, 0)
    const cupsPerDay = totalDays > 0 ? totalCups / totalDays : 0
    const gap = impasHarian - cupsPerDay

    return { best, topTwoShare, bestBlock, cupsPerDay, gap, avg }
    // thinCoverage bergantung pada totalDays, yang sudah ikut sebagai dependensi.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [clusters, hours, days, totalDays, impasHarian])

  if (loading) {
    return (
      <div className="bg-white rounded-2xl border border-zinc-200/80 shadow-card p-10 flex items-center justify-center">
        <Loader2 className="w-5 h-5 animate-spin text-zinc-300" />
      </div>
    )
  }

  if (error) {
    return (
      <div className="bg-white rounded-2xl border border-brand-border shadow-card p-5">
        <div className="flex gap-3">
          <TriangleAlert strokeWidth={2} className="w-4 h-4 text-brand shrink-0 mt-0.5" />
          <div>
            <h3 className="text-sm font-bold text-zinc-900">Analitik operasional belum bisa dibaca</h3>
            <p className="mt-1 text-xs text-zinc-500 leading-relaxed">{error}</p>
          </div>
        </div>
      </div>
    )
  }

  if (totalDays === 0) {
    return (
      <div className="bg-white rounded-2xl border border-zinc-200/80 shadow-card p-8 text-center">
        <Clock strokeWidth={1.5} className="w-6 h-6 text-zinc-300 mx-auto mb-2" />
        <p className="text-sm text-zinc-500">Belum ada penjualan pada rentang ini.</p>
      </div>
    )
  }

  return (
    <div className="space-y-5">

      {/* ── Laba bersih ────────────────────────────────────────────
          Ditaruh paling atas karena ia satu-satunya angka yang menjawab
          pertanyaan yang sebenarnya dibawa orang ke halaman ini: hari-hari
          ini menghasilkan uang atau menghabiskannya.

          Omzet sendirian tidak pernah menjawabnya, dan selama ini omzet
          yang paling besar di layar. */}
      {ekonomi && ekonomi.laba_bersih != null && (
        <section className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
          <div className="px-5 py-3.5 border-b border-zinc-100 flex items-center gap-2">
            <Wallet strokeWidth={2} className="w-4 h-4 text-brand" />
            <h3 className="text-sm font-bold text-zinc-900">Laba Bersih</h3>
          </div>

          <div className="px-5 py-5">
            <div className="flex flex-wrap items-end gap-x-10 gap-y-5">
              <div>
                <p className="text-[10px] font-mono uppercase tracking-wider text-zinc-400">
                  Laba bersih {ekonomi.hari_jualan} hari jualan
                </p>
                <p className={`text-4xl font-extrabold tabular-nums leading-none mt-1.5 ${
                  num(ekonomi.laba_bersih) >= 0 ? 'text-emerald-600' : 'text-brand'}`}>
                  {num(ekonomi.laba_bersih) >= 0 ? '' : '\u2212'}
                  {formatRupiah(Math.abs(Math.round(num(ekonomi.laba_bersih))))}
                </p>
              </div>
              <div>
                <p className="text-[10px] font-mono uppercase tracking-wider text-zinc-400">Laba per cup</p>
                <p className="text-2xl font-extrabold text-zinc-900 tabular-nums leading-none mt-1.5">
                  {formatRupiah(Math.round(num(ekonomi.laba_per_cup)))}
                </p>
              </div>
              <div>
                <p className="text-[10px] font-mono uppercase tracking-wider text-zinc-400">Impas</p>
                <p className="text-2xl font-extrabold text-zinc-900 tabular-nums leading-none mt-1.5">
                  {num(ekonomi.impas_per_hari).toFixed(1)}
                  <span className="text-sm font-semibold text-zinc-500"> cup/hari</span>
                </p>
              </div>
            </div>

            {/* Susunannya dibuat kelihatan supaya angka besar di atas tidak
                perlu dipercaya begitu saja. */}
            <dl className="mt-5 pt-4 border-t border-zinc-100 flex flex-col gap-2 max-w-md">
              <div className="flex justify-between gap-4 text-[13px]">
                <dt className="text-zinc-500">Omzet {ekonomi.cup} cup</dt>
                <dd className="tabular-nums font-semibold text-zinc-900">
                  {formatRupiah(num(ekonomi.omzet))}
                </dd>
              </div>
              <div className="flex justify-between gap-4 text-[13px]">
                <dt className="text-zinc-500">Biaya bahan menurut takaran</dt>
                <dd className="tabular-nums text-zinc-600">
                  &minus;{formatRupiah(Math.round(num(ekonomi.biaya_bahan)))}
                </dd>
              </div>
              <div className="flex justify-between gap-4 text-[13px] pt-2 border-t border-zinc-100">
                <dt className="font-semibold text-zinc-700">Laba kotor</dt>
                <dd className="tabular-nums font-bold text-zinc-900">
                  {formatRupiah(Math.round(num(ekonomi.laba_kotor)))}
                </dd>
              </div>
              <div className="flex justify-between gap-4 text-[13px]">
                <dt className="text-zinc-500">
                  Biaya tetap &times; {ekonomi.hari_jualan} hari jualan
                </dt>
                <dd className="tabular-nums text-zinc-600">
                  &minus;{formatRupiah(Math.round(num(ekonomi.biaya_tetap)))}
                </dd>
              </div>
            </dl>
          </div>

          <div className="px-5 py-3.5 border-t border-zinc-100 flex flex-col gap-2">
            <p className="text-[11px] text-zinc-500 leading-relaxed">
              <b className="text-zinc-900">Belum termasuk susut.</b> Buah busuk, tumpah, dan
              kelebihan tuang tidak ada di takaran, jadi laba di atas selalu sedikit lebih besar
              daripada kenyataan. Selisihnya baru bisa diukur setelah isi freezer dihitung bulanan.
            </p>
            <p className="text-[11px] text-zinc-500 leading-relaxed">
              Biaya tetap ditagihkan per <b className="text-zinc-900">hari jualan</b>, bukan per hari
              kalender &mdash; hari gerobak libur tidak ikut ditagih.
            </p>
            {ekonomi.harga_perkiraan && (
              <p className="text-[11px] text-amber-800 leading-relaxed flex items-start gap-2">
                <Info strokeWidth={2} className="w-3.5 h-3.5 shrink-0 mt-px" />
                <span>
                  Sebagian cup terjual sebelum nota belanja pertama dicatat, jadi dinilai dengan
                  harga bahan paling awal yang diketahui.
                </span>
              </p>
            )}
            {!ekonomi.lengkap && ekonomi.cup > ekonomi.cup_ternilai && (
              <p className="text-[11px] text-amber-800 leading-relaxed flex items-start gap-2">
                <Info strokeWidth={2} className="w-3.5 h-3.5 shrink-0 mt-px" />
                <span>
                  {ekonomi.cup - ekonomi.cup_ternilai} dari {ekonomi.cup} cup belum bisa dinilai
                  &mdash; takarannya belum lengkap atau bahannya belum punya harga. Yang di atas
                  dihitung dari {ekonomi.cup_ternilai} cup yang ternilai saja.
                </span>
              </p>
            )}
          </div>
        </section>
      )}

      {/* Kesimpulan yang bisa langsung dikerjakan besok pagi */}
      <section className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
        <div className="px-5 py-3.5 border-b border-zinc-100 flex items-center gap-2">
          <Target strokeWidth={2} className="w-4 h-4 text-brand" />
          <h3 className="text-sm font-bold text-zinc-900">Keputusan Hari Ini</h3>
        </div>

        <div className="p-4 grid gap-3 sm:grid-cols-3">
          {/* Titik terbaik */}
          <div className="rounded-xl border border-zinc-200/80 bg-zinc-50/50 p-4">
            <span className="block text-[10px] font-bold uppercase tracking-wider text-zinc-400 mb-2">
              Parkir di sini
            </span>
            {verdict.best ? (
              <>
                <div className="flex items-baseline gap-1.5">
                  <span className="text-2xl font-bold text-zinc-900 tabular-nums">
                    {num(verdict.best.cups_per_active_day).toFixed(1)}
                  </span>
                  <span className="text-xs text-zinc-500">cup / hari</span>
                </div>
                <p className="mt-1 text-[11px] text-zinc-400 tabular-nums">
                  {verdict.best.cluster_lat.toFixed(5)}, {verdict.best.cluster_lng.toFixed(5)}
                </p>
                <p className="mt-1.5 text-[11px] text-zinc-500 leading-relaxed">
                  Jam terbaiknya {jam(verdict.best.best_hour)} ·{' '}
                  <span className={thinCoverage(verdict.best.days_active) ? 'text-amber-600 font-semibold' : ''}>
                    baru {verdict.best.days_active} dari {totalDays} hari
                  </span>
                </p>
                <p className="mt-1 text-[11px] leading-relaxed">
                  {verdict.best.spread_meters > SPREAD_IS_A_ROUTE_M ? (
                    <span className="text-amber-600 font-semibold">
                      Sebaran {verdict.best.spread_meters} m — ini ruas jalan, bukan satu titik.
                      Perkecil petak untuk memilih tempat mangkal.
                    </span>
                  ) : (
                    <span className="text-zinc-400">
                      Penjualannya mengumpul dalam {verdict.best.spread_meters} m
                    </span>
                  )}
                </p>

                {/* Angka yang memutuskan sewa, diangkat ke atas agar tidak terlewat. */}
                <div className="mt-2.5 pt-2.5 border-t border-zinc-200/70">
                  {verdict.best.cups_per_hour == null ? (
                    <p className="text-[11px] text-zinc-400 leading-relaxed">
                      <b className="text-zinc-600">Cup/jam belum terukur</b> — titik ini belum pernah
                      menghasilkan dua pesanan dalam satu kunjungan. Mangkal lebih lama di sini untuk
                      mendapatkannya.
                    </p>
                  ) : (
                    <>
                      <div className="flex items-baseline gap-1.5">
                        <span
                          className={`text-lg font-bold tabular-nums ${
                            clearsRukoBar(verdict.best, bar) ? 'text-emerald-600' : 'text-zinc-900'
                          }`}
                        >
                          {num(verdict.best.cups_per_hour).toFixed(2)}
                        </span>
                        <span className="text-[11px] text-zinc-500">cup/jam</span>
                      </div>
                      <p className="mt-0.5 text-[11px] text-zinc-400 leading-relaxed">
                        {!hasEnoughEvidence(verdict.best) ? (
                          <span className="text-amber-600 font-semibold">
                            Bukti masih tipis — baru {verdict.best.measured_stops} kunjungan,{' '}
                            {num(verdict.best.hours_measured).toFixed(1)} jam. Belum cukup untuk
                            memutuskan sewa.
                          </span>
                        ) : clearsRukoBar(verdict.best, bar) ? (
                          <>Tembus dua-duanya — gerobak {bar.gerobak}/jam
                          dan ruko {bar.ruko}/jam. Dari{' '}
                          {verdict.best.measured_stops} kunjungan terukur.</>
                        ) : clearsGerobakBar(verdict.best, bar) ? (
                          <>Tembus ambang <b className="text-emerald-600">gerobak</b>{' '}
                          ({bar.gerobak}/jam) — taruh gerobak di sini.
                          Untuk ruko masih kurang ({bar.ruko}/jam). Dari{' '}
                          {verdict.best.measured_stops} kunjungan terukur.</>
                        ) : (
                          <>Belum tembus ambang mana pun — gerobak{' '}
                          {bar.gerobak}/jam, ruko{' '}
                          {bar.ruko}/jam. Dari{' '}
                          {verdict.best.measured_stops} kunjungan terukur.</>
                        )}
                      </p>
                    </>
                  )}
                </div>
                <a
                  href={`https://www.google.com/maps?q=${verdict.best.cluster_lat},${verdict.best.cluster_lng}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="mt-2.5 inline-flex items-center gap-1 text-[11px] font-semibold text-brand hover:underline"
                >
                  <Navigation strokeWidth={2.5} className="w-3 h-3" />
                  Buka di peta
                </a>
              </>
            ) : (
              <p className="text-xs text-zinc-400">Belum ada koordinat.</p>
            )}
          </div>

          {/* Blok jam */}
          <div className="rounded-xl border border-zinc-200/80 bg-zinc-50/50 p-4">
            <span className="block text-[10px] font-bold uppercase tracking-wider text-zinc-400 mb-2">
              Jam paling menghasilkan
            </span>
            {verdict.bestBlock.length > 0 ? (
              <>
                <div className="text-2xl font-bold text-zinc-900 tabular-nums">
                  {jam(verdict.bestBlock[0])}–{jam(verdict.bestBlock[verdict.bestBlock.length - 1] + 1)}
                </div>
                <p className="mt-1.5 text-[11px] text-zinc-500 leading-relaxed">
                  {verdict.bestBlock.length} jam berurutan yang hasilnya di atas rata-rata{' '}
                  ({verdict.avg.toFixed(1)} cup/jam). Jam dengan cakupan tipis tidak ikut dihitung.
                </p>
              </>
            ) : (
              <p className="text-xs text-zinc-400 leading-relaxed">
                Belum cukup hari untuk menyimpulkan blok jam. Perlu beberapa hari lagi dengan jam
                kerja yang konsisten.
              </p>
            )}
          </div>

          {/* Jarak ke titik impas */}
          <div
            className={`rounded-xl border p-4 ${
              verdict.gap > 0 ? 'border-brand-border bg-brand-soft' : 'border-emerald-200 bg-emerald-50'
            }`}
          >
            <span className="block text-[10px] font-bold uppercase tracking-wider text-zinc-400 mb-2">
              Titik impas
            </span>
            <div className="flex items-baseline gap-1.5">
              <span
                className={`text-2xl font-bold tabular-nums ${
                  verdict.gap > 0 ? 'text-brand' : 'text-emerald-700'
                }`}
              >
                {verdict.gap > 0 ? `−${verdict.gap.toFixed(1)}` : `+${Math.abs(verdict.gap).toFixed(1)}`}
              </span>
              <span className="text-xs text-zinc-500">cup / hari</span>
            </div>
            <p className="mt-1.5 text-[11px] text-zinc-500 leading-relaxed">
              Sekarang <b className="text-zinc-700 tabular-nums">{verdict.cupsPerDay.toFixed(1)}</b>,
              perlu <b className="text-zinc-700 tabular-nums">{impasHarian.toFixed(1)}</b> cup/hari
              agar tidak rugi (laba {formatRupiah(Math.round(labaPerCup))}/cup
              {terukur ? ' — terukur dari nota belanja' : ' — masih tebakan di kode'}).
            </p>
          </div>
        </div>

        {verdict.topTwoShare > 0 && clusters.length > 2 && (
          <div className="px-5 pb-4">
            <div className="rounded-xl bg-zinc-50 border border-zinc-200/80 px-4 py-3 flex gap-2.5">
              <Info strokeWidth={2} className="w-3.5 h-3.5 text-brand shrink-0 mt-0.5" />
              <p className="text-[11px] text-zinc-600 leading-relaxed">
                <b className="text-zinc-900 tabular-nums">
                  2 titik menghasilkan {verdict.topTwoShare.toFixed(0)}% omzet
                </b>{' '}
                dari total {clusters.length} titik yang didatangi. Semakin tinggi angka ini, semakin
                besar kemungkinan berkeliling ke titik lain justru mengencerkan hasil — waktu yang
                sama akan menghasilkan lebih banyak bila dihabiskan di titik teratas.
              </p>
            </div>
          </div>
        )}
      </section>

      {/* Penjelasan metrik — tanpa ini angkanya mudah disalahbaca */}
      <div className="bg-brand-soft border border-brand-border rounded-2xl px-5 py-4 flex gap-3">
        <Gauge strokeWidth={2} className="w-4 h-4 text-brand shrink-0 mt-0.5" />
        <div className="text-xs text-zinc-700 leading-relaxed">
          <b className="text-zinc-900">Angka kunci di bagian ini adalah cup per JAM, bukan cup per hari.</b>{' '}
          Cup per hari mencampur lokasi yang ramai dengan driver yang kerja lebih lama — dua hal yang
          harus dipisah sebelum memutuskan jam atau memindahkan gerobak. Setiap rata-rata di sini
          ditemani pembaginya (hari aktif / jam kerja), supaya angka bagus dari satu hari tidak
          terbaca sama meyakinkan dengan angka bagus dari sebulan.
        </div>
      </div>

      {/* ── 1. Produktivitas per gerobak ────────────────────────────── */}
      <section className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
        <div className="px-5 py-3.5 border-b border-zinc-100 flex items-center gap-2">
          <Gauge strokeWidth={2} className="w-4 h-4 text-brand" />
          <h3 className="text-sm font-bold text-zinc-900">Produktivitas Gerobak</h3>
          <span className="ml-auto text-[10px] font-semibold text-zinc-400 uppercase tracking-wider">
            {carts.length} gerobak aktif
          </span>
        </div>

        <div className="p-4 grid gap-3 sm:grid-cols-2">
          {carts.map(c => {
            const perHour = num(c.cups_per_hour)
            const isBest = carts.length > 1 && perHour === bestCart
            return (
              <div
                key={c.driver_id}
                className={`rounded-xl border p-4 ${
                  isBest ? 'border-brand bg-brand-soft' : 'border-zinc-200/80 bg-zinc-50/50'
                }`}
              >
                <div className="flex items-baseline justify-between gap-2">
                  <span className="text-sm font-bold text-zinc-900 truncate">{c.driver_name}</span>
                  {isBest && (
                    <span className="text-[9px] font-bold uppercase tracking-wider text-brand shrink-0">
                      tertinggi
                    </span>
                  )}
                </div>

                <div className="mt-3 flex items-baseline gap-1.5">
                  <span className="text-2xl font-bold text-zinc-900 tabular-nums">
                    {perHour.toFixed(2)}
                  </span>
                  <span className="text-xs text-zinc-500">cup / jam</span>
                </div>

                <dl className="mt-3 pt-3 border-t border-zinc-200/70 grid grid-cols-2 gap-y-1.5 text-[11px]">
                  <dt className="text-zinc-400">Cup / hari</dt>
                  <dd className="text-right font-semibold text-zinc-700 tabular-nums">
                    {num(c.cups_per_day).toFixed(1)}
                  </dd>
                  <dt className="text-zinc-400">Total cup</dt>
                  <dd className="text-right font-semibold text-zinc-700 tabular-nums">{c.cups}</dd>
                  <dt className="text-zinc-400">Hari kerja</dt>
                  <dd className="text-right font-semibold text-zinc-700 tabular-nums">{c.days_worked}</dd>
                  <dt className="text-zinc-400">Jam kerja</dt>
                  <dd className="text-right font-semibold text-zinc-700 tabular-nums">
                    {num(c.hours_worked).toFixed(1)} j
                  </dd>
                  <dt className="text-zinc-400">Omzet / jam</dt>
                  <dd className="text-right font-semibold text-zinc-700 tabular-nums">
                    {formatRupiah(num(c.revenue_per_hour))}
                  </dd>
                  <dt className="text-zinc-400">Jam biasanya</dt>
                  <dd className="text-right font-semibold text-zinc-700 tabular-nums">
                    {jam(c.avg_start_hour)}–{jam(c.avg_end_hour)}
                  </dd>
                </dl>
              </div>
            )
          })}
        </div>

        {carts.length > 1 && (
          <p className="px-5 pb-4 text-[11px] text-zinc-400 leading-relaxed">
            Bandingkan baris <b className="text-zinc-600">cup/jam</b>, bukan total cup. Gerobak yang
            totalnya lebih besar bisa saja cuma bekerja lebih lama di lokasi yang sama sepinya.
          </p>
        )}
      </section>

      {/* ── 2. Jam ──────────────────────────────────────────────────── */}
      <section className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
        <div className="px-5 py-3.5 border-b border-zinc-100 flex items-center gap-2">
          <Clock strokeWidth={2} className="w-4 h-4 text-brand" />
          <h3 className="text-sm font-bold text-zinc-900">Jam Mana yang Benar-Benar Menghasilkan</h3>
        </div>

        <div className="p-4 space-y-1.5">
          {hours.map(h => {
            const norm = num(h.cups_per_active_day)
            const thin = thinCoverage(h.days_active)
            return (
              <div key={h.hour_wib} className="flex items-center gap-3">
                <span className="w-11 shrink-0 text-[11px] font-semibold text-zinc-500 tabular-nums">
                  {jam(h.hour_wib)}
                </span>

                <div className="flex-1 h-6 bg-zinc-100 rounded-md overflow-hidden relative">
                  <div
                    className={`h-full rounded-md ${thin ? 'bg-zinc-300' : 'bg-brand'}`}
                    style={{ width: `${Math.max((norm / maxHourNorm) * 100, 3)}%` }}
                  />
                  <span className="absolute inset-y-0 left-2 flex items-center text-[10px] font-bold text-white mix-blend-difference tabular-nums">
                    {norm.toFixed(1)} cup/hari
                  </span>
                </div>

                <span
                  className={`w-24 shrink-0 text-right text-[10px] tabular-nums ${
                    thin ? 'text-amber-600 font-semibold' : 'text-zinc-400'
                  }`}
                  title={thin ? 'Terlalu sedikit hari untuk disimpulkan' : undefined}
                >
                  {h.days_active}/{totalDays} hari
                </span>

                <span className="w-14 shrink-0 text-right text-[11px] font-semibold text-zinc-600 tabular-nums">
                  {h.cups} cup
                </span>
              </div>
            )
          })}
        </div>

        <div className="px-5 pb-4 flex gap-2 text-[11px] text-zinc-400 leading-relaxed">
          <Info strokeWidth={2} className="w-3.5 h-3.5 shrink-0 mt-0.5 text-amber-500" />
          <p>
            Batang <b className="text-zinc-600">abu-abu</b> berarti jam itu dijalani terlalu sedikit
            hari untuk disimpulkan. Kolom &ldquo;hari&rdquo; adalah pembaginya — jam dengan total cup
            besar tetapi hari sedikit bukan jam ramai, melainkan jam yang kebetulan lebih sering
            ditongkrongi.
          </p>
        </div>
      </section>

      {/* ── 3. Lokasi ───────────────────────────────────────────────── */}
      <section className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
        <div className="px-5 py-3.5 border-b border-zinc-100 flex flex-wrap items-center gap-2">
          <MapPin strokeWidth={2} className="w-4 h-4 text-brand" />
          <h3 className="text-sm font-bold text-zinc-900">Lokasi yang Menghasilkan</h3>
          <div className="ml-auto flex gap-1">
            {GRID_OPTIONS.map(g => (
              <button
                key={g.meters}
                type="button"
                onClick={() => setGrid(g.meters)}
                title={g.hint}
                className={`px-2.5 py-1 rounded-lg text-[10px] font-bold transition-colors ${
                  grid === g.meters
                    ? 'bg-brand text-white'
                    : 'bg-zinc-100 text-zinc-500 hover:bg-zinc-200'
                }`}
              >
                {g.label}
              </button>
            ))}
          </div>
        </div>

        {clusters.length === 0 ? (
          <p className="p-6 text-center text-xs text-zinc-400">
            Belum ada pesanan yang membawa koordinat pada rentang ini.
          </p>
        ) : (
          <>
            <div className="overflow-x-auto">
              <table className="w-full text-sm min-w-[560px]">
                <thead>
                  <tr className="bg-zinc-50/80">
                    {['Titik', 'Cup/jam', 'Cup', 'Cup/hari aktif', 'Sebaran', 'Jam terbaik', 'Omzet', ''].map(t => (
                      <th
                        key={t}
                        className="text-left px-4 py-2.5 text-[10px] font-bold uppercase tracking-wider text-zinc-400 whitespace-nowrap"
                      >
                        {t}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-100">
                  {clusters.map(c => (
                    <tr key={`${c.cluster_lat}-${c.cluster_lng}`}>
                      <td className="px-4 py-2.5">
                        <div className="h-1.5 w-24 bg-zinc-100 rounded-full overflow-hidden mb-1">
                          <div
                            className="h-full bg-brand rounded-full"
                            style={{ width: `${(c.cups / maxClusterCups) * 100}%` }}
                          />
                        </div>
                        <span className="text-[10px] text-zinc-400 tabular-nums">
                          {c.cluster_lat.toFixed(5)}, {c.cluster_lng.toFixed(5)}
                        </span>
                      </td>
                      {/*
                        Kolom penentu sewa. Titik yang belum punya kunjungan
                        berpesanan ganda sengaja tampil "belum terukur", bukan
                        angka — lama mangkalnya memang tidak diketahui, dan
                        menebaknya di sinilah keputusan sewa jadi salah.
                      */}
                      <td className="px-4 py-2.5 whitespace-nowrap">
                        {c.cups_per_hour == null ? (
                          <span className="text-[11px] text-zinc-400 italic">belum terukur</span>
                        ) : (
                          <>
                            <span
                              className={`font-bold tabular-nums ${
                                clearsGerobakBar(c, bar) ? 'text-emerald-600' : 'text-zinc-900'
                              }`}
                            >
                              {num(c.cups_per_hour).toFixed(2)}
                            </span>
                            {/* Vonis dua ambang sekaligus. Satu ambang saja
                                membuang titik yang untuk gerobak sudah
                                menghasilkan, hanya karena ia belum cukup
                                untuk menanggung sewa. */}
                            <span className={`block text-[10px] font-semibold ${verdictLabel(c, bar).tone}`}>
                              {verdictLabel(c, bar).text}
                            </span>
                            <span
                              className={`block text-[10px] tabular-nums ${
                                isTrustedForLease(c) ? 'text-zinc-400' : 'text-amber-600 font-semibold'
                              }`}
                              title={
                                c.dwell_source === 'perkiraan'
                                  ? 'Dihitung dari rentang stempel pesanan. Bisa kelebihan bila driver mencatat beberapa pesanan sekaligus.'
                                  : undefined
                              }
                            >
                              {c.dwell_source === 'perkiraan'
                                ? 'perkiraan'
                                : !hasEnoughEvidence(c)
                                  ? `bukti tipis · ${num(c.hours_measured).toFixed(1)} jam`
                                  : `${c.measured_stops} mangkal · ${num(c.hours_measured).toFixed(1)} jam`}
                            </span>
                          </>
                        )}
                      </td>
                      <td className="px-4 py-2.5 font-bold text-zinc-900 tabular-nums">{c.cups}</td>
                      <td
                        className={`px-4 py-2.5 tabular-nums ${
                          thinCoverage(c.days_active) ? 'text-amber-600 font-semibold' : 'text-zinc-700'
                        }`}
                      >
                        {num(c.cups_per_active_day).toFixed(1)}
                        <span className="block text-[10px] text-zinc-400">
                          {c.days_active}/{totalDays} hari
                        </span>
                      </td>
                      <td
                        className={`px-4 py-2.5 tabular-nums whitespace-nowrap ${
                          c.spread_meters > SPREAD_IS_A_ROUTE_M
                            ? 'text-amber-600 font-semibold'
                            : 'text-zinc-500'
                        }`}
                        title={
                          c.spread_meters > SPREAD_IS_A_ROUTE_M
                            ? 'Terlalu menyebar untuk disebut satu titik — perkecil petak'
                            : 'Pesanannya mengumpul rapat, layak jadi titik mangkal'
                        }
                      >
                        {c.spread_meters} m
                      </td>
                      <td className="px-4 py-2.5 text-zinc-500 tabular-nums">{jam(c.best_hour)}</td>
                      <td className="px-4 py-2.5 text-zinc-700 tabular-nums whitespace-nowrap">
                        {formatRupiah(c.revenue)}
                      </td>
                      <td className="px-4 py-2.5">
                        <a
                          href={`https://www.google.com/maps?q=${c.cluster_lat},${c.cluster_lng}`}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="inline-flex items-center gap-1 text-[10px] font-semibold text-brand hover:underline whitespace-nowrap"
                        >
                          Peta
                          <ExternalLink strokeWidth={2.5} className="w-3 h-3" />
                        </a>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="px-5 py-3.5 border-t border-zinc-100 space-y-2">
              <p className="text-[11px] text-zinc-500 leading-relaxed">
                <b className="text-zinc-900">Satu titik dinilai dua kali, karena biayanya dua macam.</b>{' '}
                Gerobak tidak bayar sewa, jadi ambangnya{' '}
                <b className="text-zinc-900 tabular-nums">{bar.gerobak} cup/jam</b>{' '}
                (Rp2,5jt/bulan ÷ 26 hari ÷ ±9,8 jam mangkal). Ruko kecil menanggung sewa dan
                satu pegawai, jadi ambangnya{' '}
                <b className="text-zinc-900 tabular-nums">{bar.ruko} cup/jam</b>.
              </p>
              <p className="text-[11px] text-zinc-500 leading-relaxed">
                Angka hijau berarti titik itu <b className="text-emerald-600">sudah cukup untuk
                gerobak</b> — taruh gerobak di sana sekarang, tanpa menunggu apa pun. Vonis di
                bawah angkanya menyebut keduanya sekaligus. Menilai dengan satu ambang saja akan
                membuang titik yang sebenarnya sudah menghasilkan, hanya karena ia belum sanggup
                menanggung sewa.
              </p>
              <p className="text-[11px] text-zinc-400 leading-relaxed">
                <b className="text-amber-700">&ldquo;perkiraan&rdquo;</b> berarti lamanya dihitung
                dari rentang stempel pesanan, bukan dari tombol mangkal. Angka itu{' '}
                <b className="text-zinc-600">bisa kelebihan</b> — driver sering mencatat beberapa
                pesanan sekaligus setelah selesai melayani, sehingga rentangnya menyusut dan lajunya
                tampil lebih tinggi dari kenyataan. Karena kelebihannya selalu ke arah yang menggoda
                untuk menyewa, baris perkiraan tidak pernah ditandai hijau. Minta driver menekan{' '}
                <b className="text-zinc-600">&ldquo;Mangkal di sini&rdquo;</b> untuk menggantinya
                dengan angka yang tercatat.
              </p>
              <p className="text-[11px] text-zinc-400 leading-relaxed">
                <b className="text-zinc-600">&ldquo;Belum terukur&rdquo;</b> berarti titik itu belum
                pernah menghasilkan dua pesanan dalam satu kunjungan dan belum pernah dimangkali,
                jadi lamanya memang tidak diketahui — sengaja tidak ditebak.
              </p>
              <p className="text-[11px] text-zinc-400 leading-relaxed">
                Koordinat yang ditampilkan adalah rata-rata posisi pesanan sebenarnya, bukan pusat
                petak <b className="text-zinc-600">{grid} m</b>. Kolom{' '}
                <b className="text-zinc-600">Sebaran</b> di atas {SPREAD_IS_A_ROUTE_M} m berarti itu
                ruas jalan, bukan satu titik.
              </p>
            </div>
          </>
        )}
      </section>

      {/* ── 3b. Booth event yang dikeluarkan dari peta ───────────────
          Penyaring yang bekerja diam-diam tidak bisa dipercaya, karena
          tidak ada yang tahu kalau ia salah. Bagian ini membuat isinya
          kelihatan: yang dikeluarkan apa saja, berapa, dan di mana.
          Uangnya tetap dihitung di seluruh laporan penjualan — yang
          dibuang hanya anggapan bahwa tempat itu bisa disewa. */}
      {events.length > 0 && (
        <section className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
          <div className="px-5 py-3.5 border-b border-zinc-100 flex items-center gap-2">
            <Tent strokeWidth={2} className="w-4 h-4 text-zinc-400" />
            <h2 className="text-xs font-bold text-zinc-900">
              Dikeluarkan dari peta: {events.length} booth event
            </h2>
          </div>

          <div className="divide-y divide-zinc-100">
            {events.map(ev => (
              <div key={ev.stop_id} className="px-5 py-3 flex items-center gap-3">
                <div className="flex-1 min-w-0">
                  <p className="text-xs font-bold text-zinc-900">
                    {new Date(ev.mulai).toLocaleString('id-ID', {
                      timeZone: 'Asia/Jakarta',
                      day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit',
                    })}
                    {' · '}
                    <span className="font-medium text-zinc-500">{ev.driver_name}</span>
                  </p>
                  <p className="text-[11px] text-zinc-400 tabular-nums mt-0.5">
                    {num(ev.jam).toFixed(2)} jam · {ev.cups} cup · {formatRupiah(ev.omzet)}
                    {num(ev.jam) > 0 && (
                      <> · {(ev.cups / num(ev.jam)).toFixed(2)} cup/jam</>
                    )}
                  </p>
                </div>
                <a
                  href={`https://www.google.com/maps?q=${ev.latitude},${ev.longitude}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="shrink-0 inline-flex items-center gap-1 text-[10px] font-semibold text-brand hover:underline"
                >
                  Peta
                  <ExternalLink strokeWidth={2.5} className="w-3 h-3" />
                </a>
              </div>
            ))}
          </div>

          <div className="px-5 py-3.5 border-t border-zinc-100">
            <p className="text-[11px] text-zinc-500 leading-relaxed">
              Booth event — kampus, bazar, pasar malam — punya kerumunan yang sudah
              berkumpul dan tidak berulang. Kalau ikut masuk peta, ia tampil sebagai
              titik terbaik yang pernah terukur dan menarik keputusan sewa ke tempat
              yang tidak ada.{' '}
              <b className="text-zinc-900">Uangnya tetap dihitung penuh</b> di omzet,
              total cup, dan analitik menu — yang dibuang hanya anggapan bahwa tempat
              itu bisa disewa.
            </p>
            <p className="text-[11px] text-zinc-400 leading-relaxed mt-1.5">
              Penandanya dipasang dari sisi admin, bukan oleh driver — layar driver
              dipakai sambil melayani antrean, dan tombol tambahan di situ lebih
              sering jadi salah tekan daripada koreksi. Daftar ini gunanya untuk
              memeriksa: kalau ada baris yang seharusnya mangkal biasa, atau ada
              event yang belum tercatat di sini, penandanya dicabut atau dipasang
              sebelum hari itu direkonsiliasi.
            </p>
          </div>
        </section>
      )}

      {/* ── 4. Harian ───────────────────────────────────────────────── */}
      <section className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
        <div className="px-5 py-3.5 border-b border-zinc-100 flex items-center gap-2">
          <CalendarRange strokeWidth={2} className="w-4 h-4 text-brand" />
          <h3 className="text-sm font-bold text-zinc-900">Ramai, atau Cuma Kerja Lebih Lama?</h3>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-sm min-w-[560px]">
            <thead>
              <tr className="bg-zinc-50/80">
                {['Tanggal', 'Cup', 'Jam kerja', 'Cup/jam', 'Rentang', 'Gerobak', 'Omzet'].map(t => (
                  <th
                    key={t}
                    className="text-left px-4 py-2.5 text-[10px] font-bold uppercase tracking-wider text-zinc-400 whitespace-nowrap"
                  >
                    {t}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-100">
              {days.map(d => {
                const dt = new Date(`${d.day}T00:00:00`)
                return (
                  <tr key={d.day}>
                    <td className="px-4 py-2.5 font-semibold text-zinc-900 whitespace-nowrap">
                      {DOW_LABEL[dt.getDay()]} {dt.getDate()}/{dt.getMonth() + 1}
                    </td>
                    <td className="px-4 py-2.5 font-bold text-zinc-900 tabular-nums">{d.cups}</td>
                    <td className="px-4 py-2.5 text-zinc-500 tabular-nums">
                      {num(d.hours_worked).toFixed(1)} j
                    </td>
                    <td className="px-4 py-2.5 tabular-nums font-bold text-brand">
                      {num(d.cups_per_hour).toFixed(2)}
                    </td>
                    <td className="px-4 py-2.5 text-zinc-400 tabular-nums whitespace-nowrap">
                      {jam(d.start_hour)}–{jam(d.end_hour)}
                    </td>
                    <td className="px-4 py-2.5 text-zinc-500 tabular-nums">{d.drivers}</td>
                    <td className="px-4 py-2.5 text-zinc-700 tabular-nums whitespace-nowrap">
                      {formatRupiah(d.revenue)}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
        <p className="px-5 py-3 text-[11px] text-zinc-400 leading-relaxed border-t border-zinc-100">
          Jam kerja dihitung dari pesanan pertama sampai terakhir, dijumlahkan per gerobak — dua
          gerobak yang jalan bersamaan 11:00–18:00 berarti 14 jam-gerobak, bukan 7.
        </p>
      </section>

      {/* ── 5. Matriks hari × jam ───────────────────────────────────── */}
      {matrix.length > 0 && (
        <section className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
          <div className="px-5 py-3.5 border-b border-zinc-100 flex items-center gap-2">
            <CalendarRange strokeWidth={2} className="w-4 h-4 text-brand" />
            <h3 className="text-sm font-bold text-zinc-900">Hari × Jam</h3>
          </div>

          <div className="p-4 overflow-x-auto">
            <table className="border-separate border-spacing-1 min-w-[560px]">
              <thead>
                <tr>
                  <th className="w-9" />
                  {Array.from({ length: 14 }, (_, i) => i + 7).map(h => (
                    <th key={h} className="text-[9px] font-semibold text-zinc-400 tabular-nums w-7">
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {[1, 2, 3, 4, 5, 6, 0].map(dow => (
                  <tr key={dow}>
                    <td className="text-[10px] font-bold text-zinc-500 pr-1 text-right">
                      {DOW_LABEL[dow]}
                    </td>
                    {Array.from({ length: 14 }, (_, i) => i + 7).map(h => {
                      const cell = matrix.find(m => m.dow === dow && m.hour_wib === h)
                      const v = cell ? num(cell.cups_per_active_day) : 0
                      const intensity = v / maxMatrix
                      return (
                        <td key={h} className="p-0">
                          <div
                            className="h-6 w-7 rounded-[3px] flex items-center justify-center text-[9px] font-bold tabular-nums"
                            style={{
                              backgroundColor:
                                v > 0 ? `rgba(190, 26, 26, ${0.12 + intensity * 0.88})` : '#F4F4F5',
                              color: intensity > 0.5 ? '#fff' : '#71717A',
                            }}
                            title={
                              cell
                                ? `${DOW_LABEL[dow]} ${jam(h)} — ${v.toFixed(1)} cup/hari aktif (${cell.days_active} hari)`
                                : `${DOW_LABEL[dow]} ${jam(h)} — belum pernah berjualan`
                            }
                          >
                            {v > 0 ? v.toFixed(0) : ''}
                          </div>
                        </td>
                      )
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="px-5 pb-4 text-[11px] text-zinc-400 leading-relaxed">
            Angka di kotak adalah cup per hari aktif. Kotak kosong berarti gerobak belum pernah
            berjualan di hari dan jam itu — bukan berarti sepi. Pola ini baru bisa dipercaya setelah
            beberapa pekan.
          </p>
        </section>
      )}
    </div>
  )
}
