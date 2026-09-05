'use client'

import { useState, useEffect } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { useGeolocation } from '@/hooks/useGeolocation'
import { formatRupiah, getGreeting } from '@/lib/format'
import {
  Play, Square, MapPin, ShoppingBag, TrendingUp,
  Loader2, CheckCircle2, AlertCircle, Plus, ChevronRight, Navigation,
  PackageCheck, Package, Layers
} from 'lucide-react'
import type { Shift } from '@/types/database'

interface CartStockItem {
  id: string
  product_id: string
  product_name: string
  category: string
  initial_quantity: number
  sold_quantity: number
  remaining: number
}

interface CartAllocationSummary {
  id: string
  status: string
  total_initial: number
  total_sold: number
  total_remaining: number
  items: CartStockItem[]
}

export default function DriverDashboard() {
  const { user } = useAuth()
  const { latitude, longitude, getPosition, loading: gpsLoading } = useGeolocation()
  const [activeShift, setActiveShift] = useState<Shift | null>(null)
  const [todayStats, setTodayStats] = useState({ orders: 0, revenue: 0 })
  const [cartAllocation, setCartAllocation] = useState<CartAllocationSummary | null>(null)
  const [loading, setLoading] = useState(true)
  const [shiftLoading, setShiftLoading] = useState(false)
  const supabase = createClient()

  useEffect(() => {
    if (user) {
      loadData()
      getPosition()
    }
  }, [user])

  async function loadData() {
    if (!user) return
    setLoading(true)

    if (user.id === 'demo-driver-id') {
      setActiveShift(null)
      setTodayStats({ orders: 0, revenue: 0 })
      setCartAllocation(null)
      setLoading(false)
      return
    }

    try {
      // 1. Get active shift
      const { data: shift } = await supabase
        .from('shifts')
        .select('*')
        .eq('driver_id', user.id)
        .eq('status', 'active')
        .maybeSingle()

      setActiveShift(shift)

      // 2. Get today's stats
      const today = new Date().toISOString().slice(0, 10)
      const { data: orders } = await supabase
        .from('orders')
        .select('total_amount')
        .eq('driver_id', user.id)
        .gte('created_at', `${today}T00:00:00`)

      if (orders) {
        setTodayStats({
          orders: orders.length,
          revenue: orders.reduce((sum, o) => sum + o.total_amount, 0),
        })
      }

      // 3. Get today's cart allocation for this driver
      const { data: alloc } = await supabase
        .from('driver_daily_allocations')
        .select(`
          id,
          status,
          driver_allocation_items (
            id,
            product_id,
            initial_quantity,
            sold_quantity,
            products (
              name,
              category
            )
          )
        `)
        .eq('driver_id', user.id)
        .eq('date', today)
        .maybeSingle()

      if (alloc && alloc.driver_allocation_items && alloc.driver_allocation_items.length > 0) {
        const rawItems = alloc.driver_allocation_items as Array<{
          id: string
          product_id: string
          initial_quantity: number | null
          sold_quantity: number | null
          products: {
            name: string
            category: string
          } | null
        }>

        const items: CartStockItem[] = rawItems.map((it) => {
          const initQty = it.initial_quantity || 0
          const soldQty = it.sold_quantity || 0
          return {
            id: it.id,
            product_id: it.product_id,
            product_name: it.products?.name || 'Produk',
            category: it.products?.category || 'smoothie',
            initial_quantity: initQty,
            sold_quantity: soldQty,
            remaining: Math.max(0, initQty - soldQty)
          }
        })

        const totalInit = items.reduce((s, i) => s + i.initial_quantity, 0)
        const totalSold = items.reduce((s, i) => s + i.sold_quantity, 0)

        setCartAllocation({
          id: alloc.id,
          status: alloc.status,
          total_initial: totalInit,
          total_sold: totalSold,
          total_remaining: Math.max(0, totalInit - totalSold),
          items
        })
      } else {
        setCartAllocation(null)
      }
    } catch {
      // fallback
    } finally {
      setLoading(false)
    }
  }

  async function startShift() {
    if (!user) return
    setShiftLoading(true)
    getPosition()

    if (user.id === 'demo-driver-id') {
      setTimeout(() => {
        setActiveShift({
          id: 'demo-shift-id',
          driver_id: 'demo-driver-id',
          start_time: new Date().toISOString(),
          end_time: null,
          start_lat: latitude || -6.2088,
          start_lng: longitude || 106.8456,
          end_lat: null,
          end_lng: null,
          status: 'active',
          notes: null,
          created_at: new Date().toISOString()
        })
        setShiftLoading(false)
      }, 350)
      return
    }

    const { data, error } = await supabase
      .from('shifts')
      .insert({
        driver_id: user.id,
        start_lat: latitude,
        start_lng: longitude,
        status: 'active',
      })
      .select()
      .single()

    if (!error && data) {
      setActiveShift(data)
    }
    setShiftLoading(false)
  }

  async function endShift() {
    if (!activeShift) return
    setShiftLoading(true)
    getPosition()

    if (user?.id === 'demo-driver-id') {
      setTimeout(() => {
        setActiveShift(null)
        setShiftLoading(false)
      }, 350)
      return
    }

    await supabase
      .from('shifts')
      .update({
        end_time: new Date().toISOString(),
        end_lat: latitude,
        end_lng: longitude,
        status: 'completed',
      })
      .eq('id', activeShift.id)

    setActiveShift(null)
    setShiftLoading(false)
    loadData()
  }

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-72 gap-2 text-zinc-400">
        <Loader2 className="w-7 h-7 animate-spin text-[#be1a1a]" />
        <span className="text-xs">Memuat data dashboard...</span>
      </div>
    )
  }

  return (
    <div className="p-4 space-y-4">
      {/* Driver Header Greeting */}
      <div className="pt-1">
        <p className="text-xs font-semibold text-zinc-400 uppercase tracking-wider">
          {new Date().toLocaleDateString('id-ID', { weekday: 'long', day: 'numeric', month: 'long' })}
        </p>
        <h1 className="text-xl font-black text-zinc-900 tracking-tight mt-0.5">
          {getGreeting()}, {user?.full_name?.split(' ')[0]} 👋
        </h1>
      </div>

      {/* Modern Shift Management Card */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-xs space-y-4">
        <div className="flex items-center justify-between">
          <div>
            <span className="text-[11px] font-semibold uppercase tracking-wider text-zinc-400 block mb-1">
              Status Operasional
            </span>
            <div className="flex items-center gap-2">
              {activeShift ? (
                <div className="flex items-center gap-1.5 bg-red-50 text-[#be1a1a] border border-red-100 px-3 py-1 rounded-full">
                  <span className="w-2 h-2 rounded-full bg-[#be1a1a] animate-pulse" />
                  <span className="text-xs font-bold">Shift Sedang Aktif</span>
                </div>
              ) : (
                <div className="flex items-center gap-1.5 bg-zinc-100 text-zinc-600 px-3 py-1 rounded-full">
                  <span className="w-2 h-2 rounded-full bg-zinc-400" />
                  <span className="text-xs font-medium">Shift Belum Dimulai</span>
                </div>
              )}
            </div>
          </div>

          <button
            onClick={activeShift ? endShift : startShift}
            disabled={shiftLoading}
            className={`flex items-center gap-2 px-4 py-2.5 rounded-xl font-semibold text-xs transition-all active:scale-[0.98] ${
              activeShift
                ? 'bg-zinc-100 hover:bg-zinc-200 text-zinc-800 border border-zinc-200'
                : 'bg-[#be1a1a] hover:bg-[#a61515] text-white shadow-sm shadow-red-900/20'
            }`}
          >
            {shiftLoading ? (
              <Loader2 className="w-4 h-4 animate-spin" />
            ) : activeShift ? (
              <Square strokeWidth={2.2} className="w-3.5 h-3.5" />
            ) : (
              <Play strokeWidth={2.2} className="w-3.5 h-3.5 fill-current" />
            )}
            <span>{activeShift ? 'Akhiri Shift' : 'Mulai Shift'}</span>
          </button>
        </div>

        {/* GPS Tracking Indicator */}
        <div className="flex items-center justify-between text-xs bg-zinc-50 border border-zinc-100 rounded-xl px-3 py-2 text-zinc-500">
          <div className="flex items-center gap-2">
            <Navigation strokeWidth={2} className="w-3.5 h-3.5 text-zinc-400" />
            <span>Lokasi GPS Gerobak</span>
          </div>
          <div>
            {gpsLoading ? (
              <span className="text-zinc-400 animate-pulse text-[11px]">Mencari koordinat...</span>
            ) : latitude ? (
              <span className="text-emerald-700 font-medium text-[11px] flex items-center gap-1">
                <CheckCircle2 className="w-3 h-3 text-emerald-600 inline" />
                {latitude.toFixed(4)}, {longitude?.toFixed(4)}
              </span>
            ) : (
              <span className="text-amber-700 font-medium text-[11px] flex items-center gap-1">
                <AlertCircle className="w-3 h-3 text-amber-600 inline" />
                Izin GPS dibutuhkan
              </span>
            )}
          </div>
        </div>
      </div>

      {/* Main KPI Stats Grid */}
      <div className="grid grid-cols-2 gap-3">
        <div className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-xs">
          <div className="flex items-center justify-between mb-3">
            <span className="text-xs font-semibold text-zinc-500">Penjualan Hari Ini</span>
            <div className="w-7 h-7 rounded-lg bg-red-50 flex items-center justify-center text-[#be1a1a]">
              <TrendingUp strokeWidth={2} className="w-4 h-4" />
            </div>
          </div>
          <p className="text-xl font-black text-zinc-900 tracking-tight">
            {formatRupiah(todayStats.revenue)}
          </p>
          <span className="text-[11px] text-zinc-400 mt-1 block">Total penerimaan</span>
        </div>

        <div className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-xs">
          <div className="flex items-center justify-between mb-3">
            <span className="text-xs font-semibold text-zinc-500">Cup Terjual</span>
            <div className="w-7 h-7 rounded-lg bg-zinc-100 flex items-center justify-center text-zinc-700">
              <ShoppingBag strokeWidth={2} className="w-4 h-4" />
            </div>
          </div>
          <p className="text-xl font-black text-zinc-900 tracking-tight">
            {todayStats.orders} <span className="text-xs font-medium text-zinc-500">transaksi</span>
          </p>
          <span className="text-[11px] text-zinc-400 mt-1 block">Tercatat hari ini</span>
        </div>
      </div>

      {/* ========================================================= */}
      {/* Realtime Cart Stock Allocation Card for Driver */}
      {/* ========================================================= */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 p-4.5 shadow-xs space-y-3.5">
        <div className="flex items-center justify-between pb-2.5 border-b border-zinc-100">
          <div className="flex items-center gap-2.5">
            <div className="w-8 h-8 rounded-xl bg-red-50 text-[#be1a1a] flex items-center justify-center">
              <PackageCheck className="w-4 h-4" />
            </div>
            <div>
              <h3 className="font-bold text-zinc-900 text-xs">Muatan Stok Gerobak Hari Ini</h3>
              <p className="text-[10px] text-zinc-400">Pantau sisa cup di coolbox secara realtime</p>
            </div>
          </div>

          {cartAllocation ? (
            <span className="text-[10px] bg-emerald-50 text-emerald-700 border border-emerald-200 font-bold px-2 py-0.5 rounded-full">
              Teralokasi
            </span>
          ) : (
            <span className="text-[10px] bg-zinc-100 text-zinc-500 font-medium px-2 py-0.5 rounded-full">
              Belum Diisi Admin
            </span>
          )}
        </div>

        {cartAllocation ? (
          <div className="space-y-3">
            {/* Quick Numbers Header */}
            <div className="grid grid-cols-3 gap-2 bg-zinc-50/80 rounded-xl p-2.5 border border-zinc-100 text-center">
              <div>
                <span className="text-[10px] text-zinc-400 block font-medium">Bawa Pagi</span>
                <span className="text-base font-black text-zinc-800">{cartAllocation.total_initial}</span>
              </div>
              <div className="border-x border-zinc-200/80">
                <span className="text-[10px] text-zinc-400 block font-medium">Terjual</span>
                <span className="text-base font-black text-[#be1a1a]">{cartAllocation.total_sold}</span>
              </div>
              <div>
                <span className="text-[10px] text-zinc-400 block font-medium">Sisa di Cart</span>
                <span className="text-base font-black text-emerald-700">{cartAllocation.total_remaining}</span>
              </div>
            </div>

            {/* Progress Bar of Sold Cups */}
            <div>
              <div className="flex items-center justify-between text-[11px] font-medium text-zinc-500 mb-1">
                <span>Progres Penjualan Gerobak</span>
                <span className="font-bold text-zinc-900">
                  {cartAllocation.total_initial > 0
                    ? Math.round((cartAllocation.total_sold / cartAllocation.total_initial) * 100)
                    : 0}%
                </span>
              </div>
              <div className="w-full h-2 bg-zinc-100 rounded-full overflow-hidden">
                <div
                  className="h-full bg-[#be1a1a] rounded-full transition-all duration-300"
                  style={{
                    width: `${cartAllocation.total_initial > 0
                      ? Math.min(100, Math.round((cartAllocation.total_sold / cartAllocation.total_initial) * 100))
                      : 0}%`
                  }}
                />
              </div>
            </div>

            {/* Breakdown per Item */}
            <div className="pt-2 divide-y divide-zinc-100">
              {cartAllocation.items.map(item => (
                <div key={item.id} className="py-2 flex items-center justify-between text-xs">
                  <div>
                    <p className="font-bold text-zinc-900">{item.product_name}</p>
                    <p className="text-[10px] text-zinc-400 font-mono">
                      Bawa: {item.initial_quantity} • Terjual: {item.sold_quantity}
                    </p>
                  </div>
                  <div>
                    <span
                      className={`inline-flex items-center px-2 py-0.5 rounded-md font-bold text-xs ${
                        item.remaining > 5
                          ? 'bg-emerald-50 text-emerald-700'
                          : item.remaining > 0
                          ? 'bg-amber-50 text-amber-800'
                          : 'bg-red-50 text-[#be1a1a]'
                      }`}
                    >
                      Sisa {item.remaining}
                    </span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        ) : (
          <div className="text-center py-4 px-2 space-y-1.5">
            <Package className="w-8 h-8 text-zinc-300 mx-auto" />
            <p className="text-xs font-bold text-zinc-700">Muatan Gerobak Belum Dialokasikan</p>
            <p className="text-[11px] text-zinc-400 max-w-xs mx-auto">
              Admin pangkalan belum mencatat kuota cup harian untuk gerobak Anda. Hubungi admin sebelum mulai berjualan.
            </p>
          </div>
        )}
      </div>

      {/* Primary Call To Action */}
      {activeShift ? (
        <Link
          href="/driver/order"
          className="flex items-center justify-between bg-[#be1a1a] hover:bg-[#a61515] active:scale-[0.99] text-white rounded-2xl p-4.5 px-5 transition-all shadow-md shadow-red-900/15 group"
        >
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-xl bg-white/20 flex items-center justify-center text-white">
              <Plus strokeWidth={2.5} className="w-5 h-5" />
            </div>
            <div>
              <p className="font-bold text-sm">Buat Pesanan Baru</p>
              <p className="text-xs text-white/80">Input cup smoothies & topping</p>
            </div>
          </div>
          <ChevronRight className="w-5 h-5 text-white/70 group-hover:translate-x-0.5 transition-transform" />
        </Link>
      ) : (
        <div className="bg-white border border-amber-200 rounded-2xl p-4 text-center shadow-xs">
          <p className="text-xs font-semibold text-amber-800">
            ⚠️ Klik &quot;Mulai Shift&quot; di atas untuk membuka kasir pesanan
          </p>
          <p className="text-[11px] text-amber-600 mt-0.5">
            Sistem secara otomatis akan mengunci posisi GPS gerobak Anda
          </p>
        </div>
      )}

      {/* Quick Links Section */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 p-3 shadow-xs divide-y divide-zinc-100">
        <Link
          href="/driver/history"
          className="flex items-center justify-between p-2.5 hover:bg-zinc-50 rounded-xl transition-colors text-xs font-medium text-zinc-700"
        >
          <div className="flex items-center gap-2.5">
            <ShoppingBag className="w-4 h-4 text-zinc-400" />
            <span>Lihat Riwayat Penjualan Hari Ini</span>
          </div>
          <ChevronRight className="w-4 h-4 text-zinc-400" />
        </Link>
        <Link
          href="/driver/profile"
          className="flex items-center justify-between p-2.5 hover:bg-zinc-50 rounded-xl transition-colors text-xs font-medium text-zinc-700"
        >
          <div className="flex items-center gap-2.5">
            <MapPin className="w-4 h-4 text-zinc-400" />
            <span>Informasi Unit Gerobak & Akun</span>
          </div>
          <ChevronRight className="w-4 h-4 text-zinc-400" />
        </Link>
      </div>
    </div>
  )
}
