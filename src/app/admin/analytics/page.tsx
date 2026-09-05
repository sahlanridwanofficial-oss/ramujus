'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { Loader2, TrendingUp, ShoppingBag, Award } from 'lucide-react'

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
    const fromDate = new Date()
    fromDate.setDate(fromDate.getDate() - days)

    const { data: orders } = await supabase
      .from('orders')
      .select('total_amount, created_at')
      .gte('created_at', fromDate.toISOString())
      .order('created_at')

    if (orders) {
      // Aggregate by day
      const byDay: Record<string, DailyData> = {}
      orders.forEach(o => {
        const date = o.created_at.slice(0, 10)
        if (!byDay[date]) byDay[date] = { date, revenue: 0, orders: 0 }
        byDay[date].revenue += o.total_amount
        byDay[date].orders += 1
      })
      setDailyData(Object.values(byDay))
      setTotalRevenue(orders.reduce((s, o) => s + o.total_amount, 0))
      setTotalOrders(orders.length)
    }

    // Top products
    const { data: items } = await supabase
      .from('order_items')
      .select(`
        quantity, subtotal,
        product:products (name)
      `)
      .gte('created_at', fromDate.toISOString())

    if (items) {
      const byProduct: Record<string, ProductRank> = {}
      items.forEach((item: any) => {
        const name = item.product?.name || 'Unknown'
        if (!byProduct[name]) byProduct[name] = { name, total_qty: 0, revenue: 0 }
        byProduct[name].total_qty += item.quantity
        byProduct[name].revenue += item.subtotal
      })
      const sorted = Object.values(byProduct).sort((a, b) => b.revenue - a.revenue)
      setTopProducts(sorted.slice(0, 10))
    }

    setLoading(false)
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 className="w-6 h-6 animate-spin text-primary" />
      </div>
    )
  }

  const maxRevenue = Math.max(...dailyData.map(d => d.revenue), 1)

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-bold text-gray-900">Analitik</h1>
          <p className="text-sm text-muted-foreground">Performa penjualan</p>
        </div>
        <div className="flex bg-gray-100 rounded-xl p-0.5">
          {(['7d', '30d', '90d'] as const).map(p => (
            <button
              key={p}
              onClick={() => setPeriod(p)}
              className={`px-3 py-1.5 rounded-lg text-xs font-medium transition-colors ${
                period === p ? 'bg-white text-gray-900 shadow-sm' : 'text-gray-500'
              }`}
            >
              {p === '7d' ? '7 Hari' : p === '30d' ? '30 Hari' : '90 Hari'}
            </button>
          ))}
        </div>
      </div>

      {/* Summary Cards */}
      <div className="grid grid-cols-2 gap-3">
        <div className="bg-white rounded-2xl border p-4">
          <TrendingUp className="w-5 h-5 text-emerald-600 mb-2" />
          <p className="text-xl font-bold">{formatRupiah(totalRevenue)}</p>
          <p className="text-xs text-muted-foreground">Total Omzet</p>
        </div>
        <div className="bg-white rounded-2xl border p-4">
          <ShoppingBag className="w-5 h-5 text-blue-600 mb-2" />
          <p className="text-xl font-bold">{totalOrders}</p>
          <p className="text-xs text-muted-foreground">Total Pesanan</p>
        </div>
      </div>

      {/* Bar Chart */}
      <div className="bg-white rounded-2xl border p-5">
        <h2 className="font-semibold text-gray-900 mb-4">Tren Penjualan</h2>
        {dailyData.length === 0 ? (
          <p className="text-sm text-muted-foreground text-center py-8">Belum ada data</p>
        ) : (
          <div className="space-y-2">
            {dailyData.slice(-14).map(d => (
              <div key={d.date} className="flex items-center gap-3">
                <span className="text-xs text-muted-foreground w-12 shrink-0">
                  {new Date(d.date).toLocaleDateString('id-ID', { day: 'numeric', month: 'short' })}
                </span>
                <div className="flex-1 bg-gray-100 rounded-full h-6 relative overflow-hidden">
                  <div
                    className="bg-primary/80 h-full rounded-full transition-all duration-500"
                    style={{ width: `${(d.revenue / maxRevenue) * 100}%` }}
                  />
                  <span className="absolute right-2 top-1/2 -translate-y-1/2 text-[10px] font-medium text-gray-600">
                    {formatRupiah(d.revenue)}
                  </span>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Top Products */}
      <div className="bg-white rounded-2xl border">
        <div className="px-5 py-4 border-b flex items-center gap-2">
          <Award className="w-4 h-4 text-amber-500" />
          <h2 className="font-semibold text-gray-900">Produk Terlaris</h2>
        </div>
        <div className="divide-y">
          {topProducts.length === 0 ? (
            <p className="px-5 py-8 text-center text-sm text-muted-foreground">Belum ada data</p>
          ) : (
            topProducts.map((p, i) => (
              <div key={p.name} className="px-5 py-3 flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <span className={`w-6 h-6 rounded-full flex items-center justify-center text-xs font-bold ${
                    i === 0 ? 'bg-amber-100 text-amber-700' :
                    i === 1 ? 'bg-gray-100 text-gray-600' :
                    i === 2 ? 'bg-orange-50 text-orange-600' :
                    'bg-gray-50 text-gray-400'
                  }`}>
                    {i + 1}
                  </span>
                  <span className="text-sm font-medium text-gray-900">{p.name}</span>
                </div>
                <div className="text-right">
                  <p className="text-sm font-bold text-gray-900">{formatRupiah(p.revenue)}</p>
                  <p className="text-xs text-muted-foreground">{p.total_qty} terjual</p>
                </div>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  )
}
