'use client'

import { useState, useEffect } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import {
  ShoppingBag, TrendingUp, Users, DollarSign,
  Loader2, ArrowUpRight, Clock, CheckCircle2
} from 'lucide-react'

interface Stats {
  todayOrders: number
  todayCups: number
  todayRevenue: number
  activeDrivers: number
  avgOrderValue: number
}

interface RecentOrder {
  id: string
  order_number: string
  total_amount: number
  payment_method: string
  created_at: string
  driver: { full_name: string }[] | null
}

export default function AdminDashboard() {
  const [stats, setStats] = useState<Stats>({
    todayOrders: 0, todayCups: 0, todayRevenue: 0, activeDrivers: 0, avgOrderValue: 0
  })
  const [recentOrders, setRecentOrders] = useState<RecentOrder[]>([])
  const [loading, setLoading] = useState(true)
  const supabase = createClient()

  useEffect(() => {
    loadData()

    // Real-time subscription for new orders
    const channel = supabase
      .channel('admin-orders')
      .on('postgres_changes', {
        event: 'INSERT',
        schema: 'public',
        table: 'orders',
      }, () => {
        loadData()
      })
      .subscribe()

    return () => { supabase.removeChannel(channel) }
  }, [])

  async function loadData() {
    try {
      // Ringkasan dijumlahkan database. Versi lama menarik seluruh pesanan
      // hari ini ke browser — pada 100 gerobak itu ribuan baris setiap kali
      // halaman dibuka DAN setiap kali Realtime memicu pembaruan.
      const [{ data: summary }, { data: recent }] = await Promise.all([
        supabase.rpc('admin_daily_summary'),
        supabase
          .from('orders')
          .select(`
            id, order_number, total_amount, payment_method, created_at,
            driver:profiles!orders_driver_id_fkey (full_name)
          `)
          .order('created_at', { ascending: false })
          .limit(10),
      ])

      const row = (Array.isArray(summary) ? summary[0] : summary) as
        | { orders_today: number; cups_today: number; revenue_today: number; active_drivers: number }
        | null
        | undefined

      const orderCount = row?.orders_today ?? 0
      const totalRev = Number(row?.revenue_today ?? 0)

      setStats({
        todayOrders: orderCount,
        todayCups: row?.cups_today ?? 0,
        todayRevenue: totalRev,
        activeDrivers: row?.active_drivers ?? 0,
        avgOrderValue: orderCount > 0 ? Math.round(totalRev / orderCount) : 0,
      })

      setRecentOrders(recent ? (recent as RecentOrder[]) : [])
    } catch {
      setStats({
        todayOrders: 0,
        todayCups: 0,
        todayRevenue: 0,
        activeDrivers: 0,
        avgOrderValue: 0,
      })
      setRecentOrders([])
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-72 gap-2 text-zinc-400">
        <Loader2 className="w-7 h-7 animate-spin text-[#be1a1a]" />
        <span className="text-xs">Memuat ringkasan eksekutif...</span>
      </div>
    )
  }

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
      sub: `${stats.todayOrders} transaksi`,
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
          <span className="inline-flex items-center gap-1.5 bg-white border border-zinc-200/80 px-3 py-1.5 rounded-full text-xs font-semibold text-zinc-700 shadow-card">
            <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse" />
            <span>Sistem Realtime Aktif</span>
          </span>
        </div>
      </div>

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
