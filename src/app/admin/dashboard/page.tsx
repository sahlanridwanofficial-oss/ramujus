'use client'

import { useState, useEffect, useRef, useCallback } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { jakartaToday, jakartaDayRange } from '@/lib/date'
import { CUP_CATEGORY } from '@/lib/constants'
import { describeRpcError, firstRow, LATEST_MIGRATION } from '@/lib/rpc'
import {
  ShoppingBag, TrendingUp, Users, DollarSign,
  Loader2, ArrowUpRight, Clock, CheckCircle2, PackageX, TriangleAlert,
  RefreshCw, WifiOff
} from 'lucide-react'

interface Stats {
  todayOrders: number
  todayCups: number
  todayItems: number
  todayRevenue: number
  activeDrivers: number
  avgOrderValue: number
}

interface SummaryRow {
  orders_today: number
  cups_today: number | null
  items_today: number | null
  revenue_today: number
  active_drivers: number
}

interface RecentOrder {
  id: string
  order_number: string
  total_amount: number
  payment_method: string
  created_at: string
  driver: { full_name: string }[] | null
}

const EMPTY_STATS: Stats = {
  todayOrders: 0, todayCups: 0, todayItems: 0, todayRevenue: 0, activeDrivers: 0, avgOrderValue: 0,
}

export default function AdminDashboard() {
  const [stats, setStats] = useState<Stats>(EMPTY_STATS)
  const [recentOrders, setRecentOrders] = useState<RecentOrder[]>([])
  const [lowStock, setLowStock] = useState<{ out: number; low: number }>({ out: 0, low: 0 })
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [lastSync, setLastSync] = useState<Date | null>(null)
  // Dua keadaan yang dulu sama-sama tampil sebagai angka nol: server menolak
  // menjawab (error), dan server menjawab lewat jalur cadangan di browser
  // karena fungsi ringkasannya versi lama (degraded).
  const [error, setError] = useState<string | null>(null)
  const [degraded, setDegraded] = useState(false)
  const [supabase] = useState(() => createClient())
  const reloadTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  /**
   * Jalur cadangan: hitung angka hari ini langsung dari tabel.
   *
   * Dipakai hanya bila fungsi ringkasan server tidak tersedia atau belum
   * mengenal cup (instance yang belum menjalankan migrasi). Rentangnya
   * sengaja cuma satu hari WIB dan dibatasi barisnya, jadi tetap ringan —
   * ini penyelamat sementara, bukan pengganti agregasi di server.
   */
  const loadFallback = useCallback(async (): Promise<Partial<Stats> | null> => {
    const { start, endExclusive } = jakartaDayRange(jakartaToday())

    const [orderRes, itemRes, shiftRes] = await Promise.all([
      supabase
        .from('orders')
        .select('id, total_amount')
        .gte('created_at', start)
        .lt('created_at', endExclusive)
        .limit(5000),
      supabase
        .from('order_items')
        .select('quantity, products(category), orders!inner(created_at)')
        .gte('orders.created_at', start)
        .lt('orders.created_at', endExclusive)
        .limit(5000),
      supabase
        .from('shifts')
        .select('id', { count: 'exact', head: true })
        .eq('status', 'active'),
    ])

    if (orderRes.error) return null

    const orderRows = (orderRes.data ?? []) as Array<{ id: string; total_amount: number }>
    const itemRows = (itemRes.data ?? []) as Array<{
      quantity: number
      products: { category: string } | { category: string }[] | null
    }>

    let cups = 0
    let items = 0
    for (const row of itemRows) {
      const product = Array.isArray(row.products) ? row.products[0] : row.products
      items += row.quantity
      if (product?.category === CUP_CATEGORY) cups += row.quantity
    }

    const revenue = orderRows.reduce((sum, o) => sum + Number(o.total_amount ?? 0), 0)

    return {
      todayOrders: orderRows.length,
      todayCups: itemRes.error ? 0 : cups,
      todayItems: itemRes.error ? 0 : items,
      todayRevenue: revenue,
      activeDrivers: shiftRes.count ?? 0,
    }
  }, [supabase])

  const loadData = useCallback(async () => {
    setRefreshing(true)
    try {
      const [summaryRes, recentRes, stockRes] = await Promise.all([
        supabase.rpc('admin_daily_summary'),
        supabase
          .from('orders')
          .select(`
            id, order_number, total_amount, payment_method, created_at,
            driver:profiles!orders_driver_id_fkey (full_name)
          `)
          .order('created_at', { ascending: false })
          .limit(10),
        supabase.rpc('admin_low_stock_count'),
      ])

      const stockRow = firstRow<{ out_of_stock: number; low_stock: number }>(stockRes.data)
      setLowStock({ out: stockRow?.out_of_stock ?? 0, low: stockRow?.low_stock ?? 0 })
      setRecentOrders((recentRes.data ?? []) as RecentOrder[])

      const row = firstRow<SummaryRow>(summaryRes.data)

      // Server menolak menjawab. Jangan menampilkan nol seolah-olah itu
      // hasil penjualan — katakan sebabnya, lalu coba jalur cadangan.
      if (summaryRes.error || !row) {
        const message = summaryRes.error
          ? describeRpcError(summaryRes.error, 'admin_daily_summary')
          : 'Server tidak mengembalikan ringkasan hari ini. Pastikan akun yang masuk berperan admin.'
        const fallback = await loadFallback()
        if (fallback) {
          const orders = fallback.todayOrders ?? 0
          const revenue = fallback.todayRevenue ?? 0
          setStats({
            todayOrders: orders,
            todayCups: fallback.todayCups ?? 0,
            todayItems: fallback.todayItems ?? 0,
            todayRevenue: revenue,
            activeDrivers: fallback.activeDrivers ?? 0,
            avgOrderValue: orders > 0 ? Math.round(revenue / orders) : 0,
          })
          setDegraded(true)
        } else {
          setStats(EMPTY_STATS)
          setDegraded(false)
        }
        setError(message)
        return
      }

      // Ringkasan versi lama tidak punya cups_today. Angkanya dilengkapi
      // dari tabel, jadi cup yang sudah terjual tetap terlihat sementara
      // migrasi belum dijalankan.
      let cups = row.cups_today
      let items = row.items_today
      let usedFallback = false
      if (cups == null || items == null) {
        const fallback = await loadFallback()
        if (fallback) {
          if (cups == null) cups = fallback.todayCups ?? 0
          if (items == null) items = fallback.todayItems ?? 0
          usedFallback = true
        }
      }

      const orderCount = row.orders_today ?? 0
      const totalRev = Number(row.revenue_today ?? 0)

      setStats({
        todayOrders: orderCount,
        todayCups: cups ?? 0,
        todayItems: items ?? 0,
        todayRevenue: totalRev,
        activeDrivers: row.active_drivers ?? 0,
        avgOrderValue: orderCount > 0 ? Math.round(totalRev / orderCount) : 0,
      })
      setDegraded(usedFallback)
      setError(
        usedFallback
          ? `Fungsi ringkasan di database masih versi lama sehingga jumlah cup dihitung di browser. Jalankan ${LATEST_MIGRATION} agar kembali dihitung server.`
          : null
      )
      setLastSync(new Date())
    } catch (err) {
      setError(
        'Tidak dapat menghubungi server. Periksa koneksi, lalu coba muat ulang. ' +
        (err instanceof Error ? err.message : '')
      )
    } finally {
      setLoading(false)
      setRefreshing(false)
    }
  }, [supabase, loadFallback])

  useEffect(() => {
    loadData()

    // Satu pesanan menghasilkan beberapa perubahan (baris orders, lalu
    // total_amount-nya diperbarui, lalu baris order_items). Muat ulang
    // ditunda sebentar supaya rentetan itu menjadi satu kali pembacaan,
    // bukan empat.
    const scheduleReload = () => {
      if (reloadTimer.current) clearTimeout(reloadTimer.current)
      reloadTimer.current = setTimeout(() => { loadData() }, 500)
    }

    const channel = supabase
      .channel('admin-orders')
      // Dulu hanya INSERT pada orders. Total pesanan ditulis lewat UPDATE
      // sesudahnya dan cup baru muncul saat order_items masuk, jadi omzet
      // dan cup bisa tertinggal satu langkah sampai halaman dimuat ulang.
      .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, scheduleReload)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'order_items' }, scheduleReload)
      .subscribe()

    return () => {
      if (reloadTimer.current) clearTimeout(reloadTimer.current)
      supabase.removeChannel(channel)
    }
  }, [supabase, loadData])

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-72 gap-2 text-zinc-400">
        <Loader2 className="w-7 h-7 animate-spin text-[#be1a1a]" />
        <span className="text-xs">Memuat ringkasan eksekutif...</span>
      </div>
    )
  }

  // Cup nol sementara ada unit terjual berarti produk yang laku bukan
  // berkategori "smoothie" — salah kategori di katalog, bukan data hilang.
  const miscategorised = stats.todayCups === 0 && stats.todayItems > 0

  const statCards = [
    {
      label: 'Omzet Hari Ini',
      value: formatRupiah(stats.todayRevenue),
      sub: 'Total penjualan masuk',
      icon: TrendingUp,
      accent: 'text-[#be1a1a] bg-red-50',
    },
    {
      label: 'Cup Terjual Hari Ini',
      value: stats.todayCups.toString() + ' Cup',
      sub: `${stats.todayOrders} transaksi · ${stats.todayItems} unit terjual`,
      icon: ShoppingBag,
      accent: 'text-zinc-900 bg-zinc-100',
    },
    {
      label: 'Mitra Driver Aktif',
      value: stats.activeDrivers.toString() + ' Gerobak',
      sub: 'Sedang beroperasi di lapangan',
      icon: Users,
      accent: 'text-emerald-700 bg-emerald-50',
    },
    {
      label: 'Rata-rata/Transaksi',
      value: formatRupiah(stats.avgOrderValue),
      sub: 'Basket size per nota',
      icon: DollarSign,
      accent: 'text-zinc-700 bg-zinc-100',
    },
  ]

  return (
    <div className="space-y-6">
      {/* Top Welcome Title */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
        <div>
          <h1 className="text-2xl font-black text-zinc-900 tracking-tight">
            Dashboard Operasional
          </h1>
          <p className="text-xs text-zinc-500 mt-0.5">
            Monitoring penjualan real-time unit armada gerobak ramu.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={() => loadData()}
            disabled={refreshing}
            className="inline-flex items-center gap-1.5 bg-white border border-zinc-200/80 px-3 py-1.5 rounded-full text-xs font-semibold text-zinc-700 shadow-card hover:border-zinc-300 disabled:opacity-60 transition-colors"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${refreshing ? 'animate-spin' : ''}`} />
            <span>Muat Ulang</span>
          </button>
          <span className="inline-flex items-center gap-1.5 bg-white border border-zinc-200/80 px-3 py-1.5 rounded-full text-xs font-semibold text-zinc-700 shadow-card">
            <span className={`w-2 h-2 rounded-full ${error ? 'bg-amber-500' : 'bg-emerald-500 animate-pulse'}`} />
            <span>
              {error
                ? 'Sinkronisasi Bermasalah'
                : lastSync
                ? `Tersinkron ${lastSync.toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' })}`
                : 'Sistem Realtime Aktif'}
            </span>
          </span>
        </div>
      </div>

      {/* Kegagalan sinkronisasi — dulu tampil sebagai angka nol tanpa penjelasan */}
      {error && (
        <div
          role="alert"
          className={`flex items-start gap-3 p-3.5 rounded-2xl border ${
            degraded
              ? 'bg-amber-50 border-amber-300'
              : 'bg-red-50 border-red-300'
          }`}
        >
          <WifiOff className={`w-5 h-5 shrink-0 mt-px ${degraded ? 'text-amber-600' : 'text-[#be1a1a]'}`} />
          <div className="flex-1 min-w-0">
            <p className={`text-xs font-bold ${degraded ? 'text-amber-900' : 'text-[#be1a1a]'}`}>
              {degraded
                ? 'Angka ditampilkan lewat perhitungan cadangan di browser'
                : 'Ringkasan hari ini tidak dapat dibaca dari server'}
            </p>
            <p className={`text-[11px] mt-0.5 leading-relaxed ${degraded ? 'text-amber-800/90' : 'text-red-900/80'}`}>
              {error}
            </p>
          </div>
        </div>
      )}

      {/* Selisih cup vs unit terjual: katalog salah kategori */}
      {miscategorised && (
        <Link
          href="/admin/products"
          className="flex items-center gap-3 p-3.5 bg-amber-50 border border-amber-300 rounded-2xl hover:bg-amber-100/70 transition-colors"
        >
          <TriangleAlert className="w-5 h-5 text-amber-600 shrink-0" />
          <div className="flex-1 min-w-0">
            <p className="text-xs font-bold text-amber-900">
              {stats.todayItems} unit terjual hari ini, tetapi 0 dihitung sebagai cup
            </p>
            <p className="text-[11px] text-amber-800/80 mt-0.5">
              Hanya produk berkategori &quot;Smoothie&quot; yang dihitung sebagai cup. Ketuk untuk memperbaiki kategori menu.
            </p>
          </div>
          <ArrowUpRight className="w-4 h-4 text-amber-700 shrink-0" />
        </Link>
      )}

      {/* Peringatan stok menipis/habis */}
      {(lowStock.out > 0 || lowStock.low > 0) && (
        <Link
          href="/admin/stock"
          className="flex items-center gap-3 p-3.5 bg-amber-50 border border-amber-300 rounded-2xl hover:bg-amber-100/70 transition-colors"
        >
          {lowStock.out > 0
            ? <PackageX className="w-5 h-5 text-[#be1a1a] shrink-0" />
            : <TriangleAlert className="w-5 h-5 text-amber-600 shrink-0" />}
          <div className="flex-1 min-w-0">
            <p className="text-xs font-bold text-amber-900">
              {lowStock.out > 0 && `${lowStock.out} produk habis`}
              {lowStock.out > 0 && lowStock.low > 0 && ' · '}
              {lowStock.low > 0 && `${lowStock.low} produk menipis`}
            </p>
            <p className="text-[11px] text-amber-800/80 mt-0.5">Ketuk untuk mengelola stok di menu Inventori.</p>
          </div>
          <ArrowUpRight className="w-4 h-4 text-amber-700 shrink-0" />
        </Link>
      )}

      {/* KPI Cards Grid */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        {statCards.map(card => (
          <div
            key={card.label}
            className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-card flex flex-col justify-between hover:border-zinc-300 transition-colors"
          >
            <div>
              <div className="flex items-center justify-between mb-3">
                <span className="text-xs font-bold text-zinc-500 uppercase tracking-wider">
                  {card.label}
                </span>
                <div className={`w-8 h-8 rounded-xl flex items-center justify-center ${card.accent}`}>
                  <card.icon strokeWidth={2} className="w-4 h-4" />
                </div>
              </div>
              <p className="text-2xl font-black text-zinc-900 tracking-tight">
                {card.value}
              </p>
            </div>
            <p className="text-[11px] text-zinc-400 mt-2 font-medium">
              {card.sub}
            </p>
          </div>
        ))}
      </div>

      {/* Recent Orders Stream */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
        <div className="px-6 py-4 border-b border-zinc-100 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Clock strokeWidth={2} className="w-4 h-4 text-zinc-400" />
            <h2 className="font-bold text-sm text-zinc-900">Transaksi Terbaru Masuk</h2>
          </div>
          <Link
            href="/admin/reports"
            className="text-xs text-[#be1a1a] font-bold flex items-center gap-1 hover:underline"
          >
            <span>Semua Laporan</span>
            <ArrowUpRight className="w-3.5 h-3.5" />
          </Link>
        </div>

        <div className="divide-y divide-zinc-100">
          {recentOrders.length === 0 ? (
            <div className="px-6 py-12 text-center text-xs text-zinc-400">
              Belum ada pesanan yang tercatat hari ini
            </div>
          ) : (
            recentOrders.map(order => {
              const driverName = Array.isArray(order.driver)
                ? order.driver[0]?.full_name || 'Mitra'
                : (order.driver as unknown as { full_name: string } | null)?.full_name || 'Mitra'

              return (
                <div key={order.id} className="px-6 py-3.5 flex items-center justify-between hover:bg-zinc-50/60 transition-colors">
                  <div className="flex items-center gap-3">
                    <div className="w-9 h-9 rounded-xl bg-zinc-100 flex items-center justify-center text-zinc-700 font-bold text-xs shrink-0">
                      <ShoppingBag className="w-4 h-4 text-zinc-500" />
                    </div>
                    <div>
                      <div className="flex items-center gap-2">
                        <p className="text-xs font-bold font-mono text-zinc-900">{order.order_number}</p>
                        <span className="text-[10px] uppercase font-bold text-zinc-500 bg-zinc-100 px-2 py-0.5 rounded">
                          {order.payment_method}
                        </span>
                      </div>
                      <p className="text-xs text-zinc-500 mt-0.5">
                        {driverName} • {new Date(order.created_at).toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' })} WIB
                      </p>
                    </div>
                  </div>

                  <div className="text-right">
                    <p className="text-sm font-black text-zinc-900 tracking-tight">
                      {formatRupiah(order.total_amount)}
                    </p>
                    <span className="text-[10px] font-medium text-emerald-600 flex items-center justify-end gap-1 mt-0.5">
                      <CheckCircle2 className="w-3 h-3" /> Berhasil
                    </span>
                  </div>
                </div>
              )
            })
          )}
        </div>
      </div>
    </div>
  )
}
