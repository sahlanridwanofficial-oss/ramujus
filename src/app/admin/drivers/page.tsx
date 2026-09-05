'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { Loader2, Users, TrendingUp, ShoppingBag, Circle, Bike, CheckCircle2 } from 'lucide-react'
import type { Profile } from '@/types/database'

interface DriverWithStats extends Profile {
  total_orders: number
  total_revenue: number
  has_active_shift: boolean
}

export default function DriversPage() {
  const [drivers, setDrivers] = useState<DriverWithStats[]>([])
  const [loading, setLoading] = useState(true)
  const supabase = createClient()

  useEffect(() => { loadDrivers() }, [])

  async function loadDrivers() {
    const fallbackDrivers: DriverWithStats[] = [
      {
        id: 'd1',
        full_name: 'Budi Santoso',
        phone: '0812-8888-1001',
        avatar_url: null,
        role: 'driver',
        status: 'active',
        home_base_lat: -6.2088,
        home_base_lng: 106.8456,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        total_orders: 28,
        total_revenue: 580000,
        has_active_shift: true
      },
      {
        id: 'd2',
        full_name: 'Agus Pratama',
        phone: '0813-7777-2002',
        avatar_url: null,
        role: 'driver',
        status: 'active',
        home_base_lat: -6.2140,
        home_base_lng: 106.8320,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        total_orders: 22,
        total_revenue: 462000,
        has_active_shift: true
      },
      {
        id: 'd3',
        full_name: 'Rian Hidayat',
        phone: '0819-3333-4004',
        avatar_url: null,
        role: 'driver',
        status: 'active',
        home_base_lat: -6.2250,
        home_base_lng: 106.8010,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        total_orders: 19,
        total_revenue: 399000,
        has_active_shift: false
      },
      {
        id: 'd4',
        full_name: 'Dedi Kurniawan',
        phone: '0812-4444-5005',
        avatar_url: null,
        role: 'driver',
        status: 'inactive',
        home_base_lat: null,
        home_base_lng: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        total_orders: 0,
        total_revenue: 0,
        has_active_shift: false
      },
    ]

    try {
      const { data: profiles } = await supabase
        .from('profiles')
        .select('*')
        .eq('role', 'driver')
        .order('created_at')

      if (!profiles || profiles.length === 0) {
        setDrivers(fallbackDrivers)
        setLoading(false)
        return
      }

      const driversWithStats = await Promise.all(
        profiles.map(async (driver) => {
          const { data: orders } = await supabase
            .from('orders')
            .select('total_amount')
            .eq('driver_id', driver.id)

          const { data: activeShift } = await supabase
            .from('shifts')
            .select('id')
            .eq('driver_id', driver.id)
            .eq('status', 'active')
            .maybeSingle()

          return {
            ...driver,
            total_orders: orders?.length || 0,
            total_revenue: orders?.reduce((s, o) => s + o.total_amount, 0) || 0,
            has_active_shift: !!activeShift,
          }
        })
      )

      setDrivers(driversWithStats)
    } catch {
      setDrivers(fallbackDrivers)
    } finally {
      setLoading(false)
    }
  }

  async function toggleStatus(driver: DriverWithStats) {
    const nextStatus = driver.status === 'active' ? 'inactive' : 'active'
    setDrivers(prev => prev.map(d => d.id === driver.id ? { ...d, status: nextStatus } : d))

    try {
      await supabase
        .from('profiles')
        .update({ status: nextStatus })
        .eq('id', driver.id)
    } catch {
      // optimistic update
    }
  }

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-64 gap-2 text-zinc-400">
        <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
        <span className="text-xs">Memuat data armada mitra...</span>
      </div>
    )
  }

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-2xl font-black text-zinc-900 tracking-tight">Armada Mitra Driver</h1>
        <p className="text-xs text-zinc-500 mt-0.5">Daftar personel operator gerobak keliling ramu.</p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {drivers.map(driver => (
          <div key={driver.id} className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-xs space-y-4">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-3">
                <div className="w-11 h-11 bg-zinc-900 text-white rounded-xl flex items-center justify-center font-bold text-sm">
                  {driver.full_name.charAt(0)}
                </div>
                <div>
                  <div className="flex items-center gap-2">
                    <p className="text-sm font-bold text-zinc-900">{driver.full_name}</p>
                    {driver.has_active_shift ? (
                      <span className="inline-flex items-center gap-1 text-[10px] bg-red-50 text-[#be1a1a] border border-red-100 px-2 py-0.5 rounded-full font-bold">
                        <span className="w-1.5 h-1.5 rounded-full bg-[#be1a1a] animate-pulse" />
                        Online
                      </span>
                    ) : (
                      <span className="inline-flex items-center text-[10px] bg-zinc-100 text-zinc-400 px-2 py-0.5 rounded-full font-medium">
                        Off-shift
                      </span>
                    )}
                  </div>
                  <p className="text-xs text-zinc-400 font-mono mt-0.5">{driver.phone || '08xx-xxxx-xxxx'}</p>
                </div>
              </div>

              <button
                onClick={() => toggleStatus(driver)}
                className={`px-3 py-1.5 rounded-xl text-xs font-bold transition-all ${
                  driver.status === 'active'
                    ? 'bg-emerald-50 text-emerald-700 hover:bg-emerald-100'
                    : 'bg-zinc-100 text-zinc-500 hover:bg-zinc-200'
                }`}
              >
                {driver.status === 'active' ? 'Aktif' : 'Nonaktif'}
              </button>
            </div>

            {/* Driver Stats */}
            <div className="grid grid-cols-2 gap-2 pt-2 border-t border-zinc-100">
              <div className="bg-zinc-50/80 rounded-xl p-3 border border-zinc-100">
                <div className="flex items-center gap-1.5 text-[11px] font-semibold text-zinc-400 mb-1">
                  <ShoppingBag className="w-3.5 h-3.5" />
                  <span>Total Transaksi</span>
                </div>
                <p className="text-base font-black text-zinc-900">{driver.total_orders} Cup</p>
              </div>

              <div className="bg-zinc-50/80 rounded-xl p-3 border border-zinc-100">
                <div className="flex items-center gap-1.5 text-[11px] font-semibold text-zinc-400 mb-1">
                  <TrendingUp className="w-3.5 h-3.5" />
                  <span>Total Omzet</span>
                </div>
                <p className="text-base font-black text-[#be1a1a]">{formatRupiah(driver.total_revenue)}</p>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
