'use client'

import { useState, useEffect, useCallback, useMemo } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import {
  jakartaToday, shiftDate, daysInRange,
  weekdayIndex, weekdayName, formatCalendarDate,
} from '@/lib/date'
import { describeRpcError, isMissingFunction, LATEST_MIGRATION } from '@/lib/rpc'
import {
  Loader2, TrendingUp, ShoppingBag, Award, BarChart2,
  Calendar, CalendarDays, Clock, Receipt, ChevronDown, TriangleAlert, X,
} from 'lucide-react'
import CustomerInsights from '@/components/admin/CustomerInsights'

interface DailyRow {
  day: string
  orders: number
  cups: number
  items: number | null
  revenue: number
}

interface HourRow {
  hour: number
  orders: number
  cups: number
  revenue: number
}

interface ProductRank {
  name: string
  category: string | null
  total_qty: number
  revenue: number
}

type Preset = 'today' | '7d' | '30d' | '90d' | 'custom'

// Rentang maksimum yang dilayani admin_sales_range dalam satu permintaan.
const MAX_RANGE_DAYS = 366

const PRESETS: { key: Exclude<Preset, 'custom'>; label: string; days: number }[] = [
  { key: 'today', label: 'Hari Ini', days: 1 },
  { key: '7d', label: '7 Hari', days: 7 },
  { key: '30d', label: '30 Hari', days: 30 },
  { key: '90d', label: '90 Hari', days: 90 },
]

export default function AnalyticsPage() {
  const [preset, setPreset] = useState<Preset>('7d')
  const [dateFrom, setDateFrom] = useState(() => shiftDate(jakartaToday(), -6))
  const [dateTo, setDateTo] = useState(() => jakartaToday())

  const [rows, setRows] = useState<DailyRow[]>([])
  const [topProducts, setTopProducts] = useState<ProductRank[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [openDate, setOpenDate] = useState<string | null>(null)
  const [hourly, setHourly] = useState<HourRow[]>([])
  const [hourlyLoading, setHourlyLoading] = useState(false)
  const [hourlyError, setHourlyError] = useState<string | null>(null)

  const [supabase] = useState(() => createClient())

  const rangeDays = daysInRange(dateFrom, dateTo)
  const rangeTooLong = rangeDays > MAX_RANGE_DAYS

  function applyPreset(p: Exclude<Preset, 'custom'>, days: number) {
    const today = jakartaToday()
    setPreset(p)
    setDateFrom(shiftDate(today, -(days - 1)))
    setDateTo(today)
    setOpenDate(null)
  }

  const loadAnalytics = useCallback(async () => {
    setLoading(true)
    setError(null)
    setOpenDate(null)

    const from = dateFrom <= dateTo ? dateFrom : dateTo
    const to = dateFrom <= dateTo ? dateTo : dateFrom
    const days = daysInRange(from, to)

    try {
      const [rangeRes, topRes] = await Promise.all([
        supabase.rpc('admin_sales_range', { p_from: from, p_to: to }),
        supabase.rpc('admin_top_products_range', { p_from: from, p_to: to, p_limit: 10 }),
      ])

      // Instance yang belum menjalankan migrasi 0007 masih punya fungsi
      // versi jendela-bergulir. Dipakai sebagai cadangan supaya halaman
      // tetap berisi, dengan pemberitahuan bahwa rentang tanggalnya tidak
      // persis seperti yang dipilih.
      if (rangeRes.error && isMissingFunction(rangeRes.error)) {
        const legacy = await supabase.rpc('admin_sales_daily', { p_days: days })
        if (legacy.error) {
          setRows([])
          setError(describeRpcError(legacy.error, 'admin_sales_daily'))
        } else {
          const legacyRows = (legacy.data ?? []) as Array<{
            day: string; revenue: number; orders: number; cups?: number
          }>
          setRows(legacyRows.map(r => ({
            day: r.day,
            orders: r.orders,
            cups: r.cups ?? 0,
            items: null,
            revenue: Number(r.revenue),
          })))
          setError(
            `Database belum mengenal analitik per tanggal, jadi halaman ini memakai jendela "${days} hari terakhir" dan tidak bisa dipecah per jam. Jalankan ${LATEST_MIGRATION} di SQL Editor Supabase untuk mengaktifkannya.`
          )
        }
      } else if (rangeRes.error) {
        setRows([])
        setError(describeRpcError(rangeRes.error, 'admin_sales_range'))
      } else {
        const data = (rangeRes.data ?? []) as Array<{
          day: string; orders: number; cups: number; items: number; revenue: number
        }>
        setRows(data.map(r => ({
          day: r.day,
          orders: r.orders,
          cups: r.cups,
          items: r.items,
          revenue: Number(r.revenue),
        })))
        if (data.length === 0) {
          setError('Server tidak mengembalikan data untuk rentang ini. Pastikan akun yang masuk berperan admin.')
        }
      }

      if (topRes.error && isMissingFunction(topRes.error)) {
        const legacyTop = await supabase.rpc('admin_top_products', { p_days: days, p_limit: 10 })
        const list = (legacyTop.data ?? []) as Array<{ name: string; total_qty: number; revenue: number }>
        setTopProducts(list.map(p => ({
          name: p.name, category: null, total_qty: p.total_qty, revenue: Number(p.revenue),
        })))
      } else {
        const list = (topRes.data ?? []) as ProductRank[]
        setTopProducts(list.map(p => ({ ...p, revenue: Number(p.revenue) })))
      }
    } catch (err) {
      setRows([])
      setTopProducts([])
      setError(
        'Tidak dapat menghubungi server analitik. ' +
        (err instanceof Error ? err.message : 'Periksa koneksi lalu coba lagi.')
      )
    } finally {
      setLoading(false)
    }
  }, [supabase, dateFrom, dateTo])

  useEffect(() => {
    if (rangeTooLong) {
      setLoading(false)
      setRows([])
      setTopProducts([])
      setError(`Rentang maksimal ${MAX_RANGE_DAYS} hari dalam satu tampilan. Persempit tanggalnya.`)
      return
    }
    loadAnalytics()
  }, [loadAnalytics, rangeTooLong])

  async function toggleDate(day: string) {
    if (openDate === day) {
      setOpenDate(null)
      return
    }
    setOpenDate(day)
    setHourly([])
    setHourlyError(null)
    setHourlyLoading(true)

    const { data, error: hourErr } = await supabase.rpc('admin_sales_hourly', { p_date: day })
    if (hourErr) {
      setHourlyError(describeRpcError(hourErr, 'admin_sales_hourly'))
    } else {
      setHourly((data ?? []) as HourRow[])
    }
    setHourlyLoading(false)
  }

  const totals = useMemo(() => {
    const revenue = rows.reduce((s, r) => s + r.revenue, 0)
    const orders = rows.reduce((s, r) => s + r.orders, 0)
    const cups = rows.reduce((s, r) => s + r.cups, 0)
    const items = rows.reduce((s, r) => s + (r.items ?? 0), 0)
    const activeDays = rows.filter(r => r.orders > 0).length
    return { revenue, orders, cups, items, activeDays }
  }, [rows])

  // Performa per hari dalam pekan: "Sabtu selalu ramai" hanya terlihat
  // kalau tanggal-tanggal dikelompokkan ulang menurut nama harinya.
  const byWeekday = useMemo(() => {
    const buckets = Array.from({ length: 7 }, (_, i) => ({
      index: i, days: 0, orders: 0, cups: 0, revenue: 0,
    }))
    for (const r of rows) {
      const b = buckets[weekdayIndex(r.day)]
      b.days += 1
      b.orders += r.orders
      b.cups += r.cups
      b.revenue += r.revenue
    }
    // Pekan operasional dibaca Senin→Minggu.
    return [1, 2, 3, 4, 5, 6, 0].map(i => buckets[i]).filter(b => b.days > 0)
  }, [rows])

  const maxRevenue = Math.max(...rows.map(r => r.revenue), 1)
  const maxWeekdayRevenue = Math.max(...byWeekday.map(b => b.revenue), 1)
  const maxHourRevenue = Math.max(...hourly.map(h => h.revenue), 1)
  const descRows = useMemo(() => [...rows].reverse(), [rows])

  const rangeLabel = `${formatCalendarDate(dateFrom, true)} – ${formatCalendarDate(dateTo, true)}`

  return (
    <div className="space-y-6">
      {/* Judul & pemilih rentang */}
      <div className="flex flex-col gap-3">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
          <div>
            <h1 className="text-2xl font-black text-zinc-900 tracking-tight">Analitik Performa</h1>
            <p className="text-xs text-zinc-500 mt-0.5">
              Penjualan per tanggal, per hari, dan per jam — kalender WIB.
            </p>
          </div>
          <div className="flex flex-wrap bg-white border border-zinc-200/80 rounded-xl p-1 shadow-card">
            {PRESETS.map(p => (
              <button
                key={p.key}
                onClick={() => applyPreset(p.key, p.days)}
                className={`px-3.5 py-1.5 rounded-lg text-xs font-bold transition-all ${
                  preset === p.key
                    ? 'bg-zinc-900 text-white shadow-card'
                    : 'text-zinc-500 hover:text-zinc-900'
                }`}
              >
                {p.label}
              </button>
            ))}
          </div>
        </div>

        {/* Rentang tanggal bebas — inti dari "analitik by tanggal" */}
        <div className="bg-white rounded-2xl border border-zinc-200/80 p-3.5 shadow-card flex flex-col sm:flex-row sm:items-end gap-3">
          <div className="flex items-center gap-2 text-zinc-500 shrink-0">
            <CalendarDays className="w-4 h-4" />
            <span className="text-xs font-bold uppercase tracking-wider">Rentang Tanggal</span>
          </div>
          <div className="flex flex-1 flex-wrap items-end gap-3">
            <label className="flex flex-col gap-1">
              <span className="text-[11px] font-semibold text-zinc-500">Dari</span>
              <input
                type="date"
                value={dateFrom}
                max={dateTo}
                onChange={e => { setPreset('custom'); setDateFrom(e.target.value) }}
                className="border border-zinc-200 rounded-lg px-2.5 py-1.5 text-xs font-semibold text-zinc-800 focus:outline-none focus:ring-2 focus:ring-brand/30"
              />
            </label>
            <label className="flex flex-col gap-1">
              <span className="text-[11px] font-semibold text-zinc-500">Sampai</span>
              <input
                type="date"
                value={dateTo}
                min={dateFrom}
                max={jakartaToday()}
                onChange={e => { setPreset('custom'); setDateTo(e.target.value) }}
                className="border border-zinc-200 rounded-lg px-2.5 py-1.5 text-xs font-semibold text-zinc-800 focus:outline-none focus:ring-2 focus:ring-brand/30"
              />
            </label>
            <span className="text-[11px] text-zinc-400 font-medium pb-2">
              {rangeDays} hari · {rangeLabel}
            </span>
          </div>
        </div>
      </div>

      {error && (
        <div role="alert" className="flex items-start gap-3 p-3.5 bg-amber-50 border border-amber-300 rounded-2xl">
          <TriangleAlert className="w-5 h-5 text-amber-600 shrink-0 mt-px" />
          <p className="text-[11px] text-amber-900 font-semibold leading-relaxed">{error}</p>
        </div>
      )}

      {loading ? (
        <div className="flex flex-col items-center justify-center h-64 gap-2 text-zinc-400">
          <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
          <span className="text-xs">Menganalisis data penjualan...</span>
        </div>
      ) : (
        <>
          {/* Ringkasan rentang */}
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
            <SummaryCard
              label="Total Pendapatan"
              value={formatRupiah(totals.revenue)}
              sub={`${totals.activeDays} dari ${rows.length} hari ada transaksi`}
              icon={TrendingUp}
              accent="bg-red-50 text-[#be1a1a]"
            />
            <SummaryCard
              label="Total Cup Terjual"
              value={`${totals.cups} cup`}
              sub={totals.items > 0
                ? `${totals.items} unit terjual (termasuk topping & add-on)`
                : `${totals.orders} transaksi`}
              icon={ShoppingBag}
              accent="bg-zinc-100 text-zinc-800"
            />
            <SummaryCard
              label="Transaksi"
              value={totals.orders.toString()}
              sub={`Rata-rata ${formatRupiah(totals.orders > 0 ? Math.round(totals.revenue / totals.orders) : 0)}/nota`}
              icon={Receipt}
              accent="bg-zinc-100 text-zinc-800"
            />
            <SummaryCard
              label="Rata-rata Per Hari"
              value={`${rows.length > 0 ? Math.round(totals.cups / rows.length) : 0} cup`}
              sub={`${formatRupiah(rows.length > 0 ? Math.round(totals.revenue / rows.length) : 0)}/hari kalender`}
              icon={Calendar}
              accent="bg-emerald-50 text-emerald-700"
            />
          </div>

          {/* Penjualan per tanggal — inti permintaan: angka per hari/tanggal */}
          <div className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
            <div className="px-6 py-4 border-b border-zinc-100 flex items-center justify-between gap-2">
              <div className="flex items-center gap-2">
                <BarChart2 className="w-4 h-4 text-zinc-400" />
                <h2 className="font-bold text-sm text-zinc-900">Penjualan per Tanggal</h2>
              </div>
              <span className="text-[11px] font-semibold text-zinc-400">Ketuk baris untuk rincian per jam</span>
            </div>

            {rows.length === 0 ? (
              <div className="px-6 py-12 text-center text-xs text-zinc-400">
                Tidak ada data pada rentang tanggal ini.
              </div>
            ) : (
              <div className="max-h-[30rem] overflow-y-auto divide-y divide-zinc-100">
                {descRows.map(r => {
                  const percentage = Math.round((r.revenue / maxRevenue) * 100)
                  const isOpen = openDate === r.day
                  return (
                    <div key={r.day}>
                      <button
                        onClick={() => toggleDate(r.day)}
                        className={`w-full text-left px-4 sm:px-6 py-3 hover:bg-zinc-50/70 transition-colors ${
                          isOpen ? 'bg-zinc-50' : ''
                        }`}
                      >
                        <div className="flex items-center gap-3">
                          <div className="w-20 shrink-0">
                            <p className="text-xs font-bold text-zinc-900">{formatCalendarDate(r.day)}</p>
                            <p className="text-[10px] text-zinc-400 font-medium">{weekdayName(weekdayIndex(r.day))}</p>
                          </div>

                          <div className="flex-1 min-w-0 bg-zinc-100 rounded-lg h-7 relative overflow-hidden flex items-center px-3">
                            <div
                              className={`absolute left-0 top-0 bottom-0 rounded-lg transition-all duration-500 ${
                                r.revenue > 0 ? 'bg-[#be1a1a] opacity-90' : 'bg-zinc-200'
                              }`}
                              style={{ width: `${r.revenue > 0 ? Math.max(percentage, 6) : 100}%` }}
                            />
                            <span className={`relative z-10 text-[11px] font-bold ${
                              r.revenue > 0 ? 'text-white drop-shadow-sm' : 'text-zinc-400'
                            }`}>
                              {r.revenue > 0 ? formatRupiah(r.revenue) : 'Tidak ada penjualan'}
                            </span>
                          </div>

                          <div className="w-28 shrink-0 text-right">
                            <p className="text-xs font-black text-zinc-900">{r.cups} cup</p>
                            <p className="text-[10px] text-zinc-400 font-medium">{r.orders} transaksi</p>
                          </div>

                          <ChevronDown
                            className={`w-4 h-4 text-zinc-300 shrink-0 transition-transform ${isOpen ? 'rotate-180' : ''}`}
                          />
                        </div>
                      </button>

                      {isOpen && (
                        <div className="px-4 sm:px-6 pb-4 bg-zinc-50/60">
                          <div className="flex items-center justify-between mb-2">
                            <div className="flex items-center gap-1.5 text-zinc-500">
                              <Clock className="w-3.5 h-3.5" />
                              <span className="text-[11px] font-bold uppercase tracking-wider">
                                Sebaran per Jam · {formatCalendarDate(r.day, true)}
                              </span>
                            </div>
                            <button
                              onClick={() => setOpenDate(null)}
                              className="text-zinc-400 hover:text-zinc-700 transition-colors"
                              aria-label="Tutup rincian jam"
                            >
                              <X className="w-3.5 h-3.5" />
                            </button>
                          </div>

                          {hourlyLoading ? (
                            <div className="flex items-center gap-2 text-[11px] text-zinc-400 py-3">
                              <Loader2 className="w-3.5 h-3.5 animate-spin" /> Memuat rincian jam...
                            </div>
                          ) : hourlyError ? (
                            <p className="text-[11px] text-[#be1a1a] font-semibold py-2">{hourlyError}</p>
                          ) : hourly.every(h => h.orders === 0) ? (
                            <p className="text-[11px] text-zinc-400 py-2">Tidak ada transaksi sepanjang hari ini.</p>
                          ) : (
                            <div className="flex items-end gap-1 h-24 pt-2">
                              {hourly.map(h => (
                                <div key={h.hour} className="flex-1 flex flex-col items-center justify-end gap-1 group">
                                  <div
                                    className={`w-full rounded-t transition-all ${
                                      h.orders > 0 ? 'bg-[#be1a1a]/85 group-hover:bg-[#be1a1a]' : 'bg-zinc-200'
                                    }`}
                                    style={{ height: `${Math.max(Math.round((h.revenue / maxHourRevenue) * 100), h.orders > 0 ? 8 : 2)}%` }}
                                    title={`${String(h.hour).padStart(2, '0')}.00 WIB — ${h.cups} cup · ${h.orders} transaksi · ${formatRupiah(h.revenue)}`}
                                  />
                                  {h.hour % 3 === 0 && (
                                    <span className="text-[9px] text-zinc-400 font-mono">{String(h.hour).padStart(2, '0')}</span>
                                  )}
                                </div>
                              ))}
                            </div>
                          )}
                        </div>
                      )}
                    </div>
                  )
                })}
              </div>
            )}
          </div>

          {/* Performa per hari dalam pekan */}
          {byWeekday.length > 0 && (
            <div className="bg-white rounded-2xl border border-zinc-200/80 p-6 shadow-card">
              <div className="flex items-center gap-2 mb-5">
                <Calendar className="w-4 h-4 text-zinc-400" />
                <h2 className="font-bold text-sm text-zinc-900">Performa per Hari dalam Pekan</h2>
              </div>
              <div className="space-y-2.5">
                {byWeekday.map(b => (
                  <div key={b.index} className="flex items-center gap-3 text-xs">
                    <span className="w-14 shrink-0 text-[11px] font-semibold text-zinc-600">
                      {weekdayName(b.index)}
                    </span>
                    <div className="flex-1 bg-zinc-100 rounded-lg h-6 relative overflow-hidden">
                      <div
                        className="absolute left-0 top-0 bottom-0 bg-zinc-800 rounded-lg transition-all duration-500"
                        style={{ width: `${Math.max(Math.round((b.revenue / maxWeekdayRevenue) * 100), b.revenue > 0 ? 5 : 0)}%` }}
                      />
                    </div>
                    <span className="w-32 shrink-0 text-right text-[11px] font-bold text-zinc-900">
                      {formatRupiah(b.revenue)}
                    </span>
                    <span className="w-28 shrink-0 text-right text-[11px] text-zinc-400 font-medium">
                      {b.cups} cup · {Math.round(b.cups / b.days)}/hari
                    </span>
                  </div>
                ))}
              </div>
              <p className="text-[11px] text-zinc-400 mt-4">
                Dihitung dari {rows.length} tanggal pada rentang terpilih — berguna untuk menentukan hari mana yang butuh muatan gerobak lebih banyak.
              </p>
            </div>
          )}

          {/* Peringkat produk pada rentang yang sama */}
          <div className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
            <div className="px-6 py-4 border-b border-zinc-100 flex items-center gap-2">
              <Award className="w-4 h-4 text-[#be1a1a]" />
              <h2 className="font-bold text-sm text-zinc-900">Peringkat Menu · {rangeLabel}</h2>
            </div>

            <div className="divide-y divide-zinc-100">
              {topProducts.length === 0 ? (
                <div className="px-6 py-12 text-center text-xs text-zinc-400">
                  Belum ada produk terjual pada rentang ini.
                </div>
              ) : topProducts.map((p, i) => (
                <div key={`${p.name}-${i}`} className="px-6 py-3.5 flex items-center justify-between hover:bg-zinc-50/50 transition-colors">
                  <div className="flex items-center gap-3">
                    <span className={`w-6 h-6 rounded-lg flex items-center justify-center text-xs font-black ${
                      i === 0 ? 'bg-[#be1a1a] text-white shadow-card' :
                      i === 1 ? 'bg-zinc-800 text-white' :
                      i === 2 ? 'bg-zinc-200 text-zinc-800' :
                      'bg-zinc-100 text-zinc-400'
                    }`}>
                      {i + 1}
                    </span>
                    <div>
                      <div className="flex items-center gap-2">
                        <p className="text-xs font-bold text-zinc-900">{p.name}</p>
                        {p.category && (
                          <span className="text-[10px] uppercase font-bold text-zinc-400 bg-zinc-100 px-1.5 py-0.5 rounded">
                            {p.category}
                          </span>
                        )}
                      </div>
                      {/* Satuan mengikuti kategori: topping dan add-on bukan cup. */}
                      <p className="text-[11px] text-zinc-400 mt-0.5">
                        {p.total_qty} {p.category === null || p.category === 'smoothie' ? 'cup' : 'porsi'} terjual
                      </p>
                    </div>
                  </div>
                  <p className="text-sm font-black text-zinc-900 tracking-tight">{formatRupiah(p.revenue)}</p>
                </div>
              ))}
            </div>
          </div>

          {/* Profil pembeli — hasil pencatatan driver saat transaksi */}
          <CustomerInsights days={rangeDays} />
        </>
      )}
    </div>
  )
}

function SummaryCard({
  label, value, sub, icon: Icon, accent,
}: {
  label: string
  value: string
  sub: string
  icon: typeof TrendingUp
  accent: string
}) {
  return (
    <div className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-card">
      <div className="flex items-center justify-between mb-3">
        <span className="text-xs font-bold text-zinc-400 uppercase tracking-wider">{label}</span>
        <div className={`w-8 h-8 rounded-xl flex items-center justify-center ${accent}`}>
          <Icon strokeWidth={2} className="w-4 h-4" />
        </div>
      </div>
      <p className="text-2xl font-black text-zinc-900 tracking-tight">{value}</p>
      <span className="text-[11px] text-zinc-400 mt-1 block">{sub}</span>
    </div>
  )
}
