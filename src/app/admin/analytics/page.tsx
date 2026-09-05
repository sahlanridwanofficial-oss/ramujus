'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { Loader2, TrendingUp, ShoppingBag, Award, BarChart2 } from 'lucide-react'
import CustomerInsights from '@/components/admin/CustomerInsights'

interface DailyData { date: string; revenue: number; orders: number }
interface ProductRank { name: string; total_qty: number; revenue: number }

export default function AnalyticsPage() {
  const [period, setPeriod] = useState<'7d' | '30d' | '90d'>('7d')
  const [dailyData, setDailyData] = useState<DailyData[]>([])
  const [topProducts, setTopProducts] = useState<ProductRank[]>([])
  const [totalRevenue, setTotalRevenue] = useState(0)
  const [totalOrders, setTotalOrders] = useState(0)
  const [loading, setLoading] = useState(true)
  const supabase = createClient()

  useEffect(() => { loadAnalytics() }, [period])

  async function loadAnalytics() {
    setLoading(true)
    const days = period === '7d' ? 7 : period === '30d' ? 30 : 90

    try {
      // Agregasi dikerjakan database. Versi lama menarik seluruh baris
      // pesanan pada rentang terpilih lalu menjumlahkannya di browser —
      // pada 100 gerobak dan rentang 90 hari itu ratusan ribu baris.
      const [{ data: daily }, { data: top }] = await Promise.all([
        supabase.rpc('admin_sales_daily', { p_days: days }),
        supabase.rpc('admin_top_products', { p_days: days, p_limit: 10 }),
      ])

      const rows = (daily ?? []) as Array<{ day: string; revenue: number; orders: number }>
      setDailyData(rows.map(r => ({ date: r.day, revenue: Number(r.revenue), orders: r.orders })))
      setTotalRevenue(rows.reduce((s, r) => s + Number(r.revenue), 0))
      setTotalOrders(rows.reduce((s, r) => s + r.orders, 0))

      const products = (top ?? []) as Array<{ name: string; total_qty: number; revenue: number }>
      setTopProducts(products.map(p => ({
        name: p.name,
        total_qty: p.total_qty,
        revenue: Number(p.revenue),
      })))
    } catch {
      setDailyData([])
      setTotalRevenue(0)
      setTotalOrders(0)
      setTopProducts([])
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-64 gap-2 text-zinc-400">
        <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
        <span className="text-xs">Menganalisis data penjualan...</span>
      </div>
    )
  }

  const maxRevenue = Math.max(...dailyData.map(d => d.revenue), 1)

  return (
    <div className="space-y-6">
      {/* Title & Filter Tabs */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-black text-zinc-900 tracking-tight">Analitik Performa</h1>
          <p className="text-xs text-zinc-500 mt-0.5">Statistik pendapatan dan produk terfavorit ramu.</p>
        </div>
        <div className="flex bg-white border border-zinc-200/80 rounded-xl p-1 shadow-card">
          {(['7d', '30d', '90d'] as const).map(p => (
            <button
              key={p}
              onClick={() => setPeriod(p)}
              className={`px-3.5 py-1.5 rounded-lg text-xs font-bold transition-all ${
                period === p
                  ? 'bg-zinc-900 text-white shadow-card'
                  : 'text-zinc-500 hover:text-zinc-900'
              }`}
            >
              {p === '7d' ? '7 Hari' : p === '30d' ? '30 Hari' : '90 Hari'}
            </button>
          ))}
        </div>
      </div>

      {/* High-level Summary Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-card">
          <div className="flex items-center justify-between mb-3">
            <span className="text-xs font-bold text-zinc-400 uppercase tracking-wider">Total Pendapatan</span>
            <div className="w-8 h-8 rounded-xl bg-red-50 text-[#be1a1a] flex items-center justify-center">
              <TrendingUp strokeWidth={2} className="w-4 h-4" />
            </div>
          </div>
          <p className="text-2xl font-black text-zinc-900 tracking-tight">{formatRupiah(totalRevenue)}</p>
          <span className="text-[11px] text-zinc-400 mt-1 block">Periode {period} berjalan</span>
        </div>

        <div className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-card">
          <div className="flex items-center justify-between mb-3">
            <span className="text-xs font-bold text-zinc-400 uppercase tracking-wider">Total Cup Terjual</span>
            <div className="w-8 h-8 rounded-xl bg-zinc-100 text-zinc-800 flex items-center justify-center">
              <ShoppingBag strokeWidth={2} className="w-4 h-4" />
            </div>
          </div>
          <p className="text-2xl font-black text-zinc-900 tracking-tight">
            {totalOrders} <span className="text-sm font-semibold text-zinc-500">transaksi</span>
          </p>
          <span className="text-[11px] text-zinc-400 mt-1 block">Rata-rata {dailyData.length > 0 ? Math.round(totalOrders / dailyData.length) : 0} cup / hari</span>
        </div>
      </div>

      {/* Visual Trend Bars */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 p-6 shadow-card">
        <div className="flex items-center justify-between mb-5">
          <div className="flex items-center gap-2">
            <BarChart2 className="w-4 h-4 text-zinc-400" />
            <h2 className="font-bold text-sm text-zinc-900">Distribusi Penjualan Harian</h2>
          </div>
          <span className="text-xs font-semibold text-zinc-400">Nilai (Rp)</span>
        </div>

        <div className="space-y-2.5">
          {dailyData.slice(-14).map(d => {
            const percentage = Math.round((d.revenue / maxRevenue) * 100)
            return (
              <div key={d.date} className="flex items-center gap-3 text-xs">
                <span className="text-zinc-500 font-mono w-16 shrink-0 text-[11px]">
                  {new Date(d.date).toLocaleDateString('id-ID', { day: 'numeric', month: 'short' })}
                </span>
                <div className="flex-1 bg-zinc-100 rounded-lg h-7 relative overflow-hidden flex items-center px-3">
                  <div
                    className="absolute left-0 top-0 bottom-0 bg-[#be1a1a] opacity-90 transition-all duration-500 rounded-lg"
                    style={{ width: `${Math.max(percentage, 4)}%` }}
                  />
                  <span className="relative z-10 text-[11px] font-bold text-white drop-shadow-sm">
                    {formatRupiah(d.revenue)}
                  </span>
                  <span className="relative z-10 ml-auto text-[10px] font-semibold text-zinc-400">
                    {d.orders} cup
                  </span>
                </div>
              </div>
            )
          })}
        </div>
      </div>

      {/* Top Products Leaderboard */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
        <div className="px-6 py-4 border-b border-zinc-100 flex items-center gap-2">
          <Award className="w-4 h-4 text-[#be1a1a]" />
          <h2 className="font-bold text-sm text-zinc-900">Peringkat Menu Smoothies & Topping</h2>
        </div>

        <div className="divide-y divide-zinc-100">
          {topProducts.map((p, i) => (
            <div key={p.name} className="px-6 py-3.5 flex items-center justify-between hover:bg-zinc-50/50 transition-colors">
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
                  <p className="text-xs font-bold text-zinc-900">{p.name}</p>
                  <p className="text-[11px] text-zinc-400 mt-0.5">{p.total_qty} cup dipesan</p>
                </div>
              </div>
              <div className="text-right">
                <p className="text-sm font-black text-zinc-900 tracking-tight">{formatRupiah(p.revenue)}</p>
                <span className="text-[10px] font-semibold text-[#be1a1a]">Kontribusi Utama</span>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Profil pembeli — hasil pencatatan driver saat transaksi */}
      <CustomerInsights days={period === '7d' ? 7 : period === '30d' ? 30 : 90} />
    </div>
  )
}
