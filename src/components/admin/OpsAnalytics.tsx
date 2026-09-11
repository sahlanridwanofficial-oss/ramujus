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
import { describeRpcError } from '@/lib/rpc'
import { BREAK_EVEN_CUPS_PER_DAY, MARGIN_PER_CUP } from '@/lib/constants'
import {
  Loader2, Clock, MapPin, TriangleAlert, ExternalLink,
  Gauge, CalendarRange, Info, Target, Navigation,
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
}

/**
 * Di atas jarak ini, sebuah kelompok bukan titik mangkal melainkan ruas
 * yang dilewati — dan satu pin peta tidak mewakilinya, betapa pun benar
 * titik tengahnya dihitung.
 */
const SPREAD_IS_A_ROUTE_M = 150

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
  const [grid, setGrid] = useState(300)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const supabase = createClient()

    async function load() {
      setLoading(true)
      setError(null)

      const [h, c, k, d, m] = await Promise.all([
        supabase.rpc('admin_hourly_performance', { p_from: from, p_to: to }),
        supabase.rpc('admin_location_clusters', { p_from: from, p_to: to, p_grid_meters: grid }),
        supabase.rpc('admin_cart_productivity', { p_from: from, p_to: to }),
        supabase.rpc('admin_daily_productivity', { p_from: from, p_to: to }),
        supabase.rpc('admin_daypart_matrix', { p_from: from, p_to: to }),
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
        (m.error && ['admin_daypart_matrix', m.error] as const)

      if (firstError) {
        setError(describeRpcError(firstError[1], firstError[0]))
        setHours([]); setClusters([]); setCarts([]); setDays([]); setMatrix([])
        setLoading(false)
        return
      }

      setHours((h.data ?? []) as HourRow[])
      setClusters((c.data ?? []) as ClusterRow[])
      setCarts((k.data ?? []) as CartRow[])
      setDays((d.data ?? []) as DayRow[])
      setMatrix((m.data ?? []) as MatrixRow[])
      setLoading(false)
    }

    load()
    return () => { cancelled = true }
  }, [from, to, grid])

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
    const gap = BREAK_EVEN_CUPS_PER_DAY - cupsPerDay

    return { best, topTwoShare, bestBlock, cupsPerDay, gap, avg }
    // thinCoverage bergantung pada totalDays, yang sudah ikut sebagai dependensi.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [clusters, hours, days, totalDays])

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
              perlu <b className="text-zinc-700 tabular-nums">{BREAK_EVEN_CUPS_PER_DAY}</b> cup/hari
              agar tidak rugi (margin {formatRupiah(MARGIN_PER_CUP)}/cup).
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
                    {['Titik', 'Sebaran', 'Cup', 'Cup/hari aktif', 'Hari', 'Jam terbaik', 'Omzet', ''].map(t => (
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
                      <td className="px-4 py-2.5 font-bold text-zinc-900 tabular-nums">{c.cups}</td>
                      <td className="px-4 py-2.5 text-zinc-700 tabular-nums">
                        {num(c.cups_per_active_day).toFixed(1)}
                      </td>
                      <td
                        className={`px-4 py-2.5 tabular-nums ${
                          thinCoverage(c.days_active) ? 'text-amber-600 font-semibold' : 'text-zinc-500'
                        }`}
                      >
                        {c.days_active}/{totalDays}
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
            <p className="px-5 py-3 text-[11px] text-zinc-400 leading-relaxed border-t border-zinc-100">
              Pesanan dikelompokkan ke petak <b className="text-zinc-600">{grid} m</b>, tetapi
              koordinat yang ditampilkan adalah <b className="text-zinc-600">rata-rata posisi
              pesanan sebenarnya</b> — bukan pusat petak, supaya pin peta jatuh di tempat gerobak
              benar-benar berjualan. Kolom <b className="text-zinc-600">Sebaran</b> menunjukkan
              seberapa rapat pesanannya: di atas {SPREAD_IS_A_ROUTE_M} m, itu ruas jalan dan satu
              pin tidak mewakilinya.
            </p>
          </>
        )}
      </section>

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
