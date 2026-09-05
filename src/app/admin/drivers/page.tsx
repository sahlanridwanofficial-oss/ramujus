'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { Loader2, Users, TrendingUp, ShoppingBag, Circle } from 'lucide-react'
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
    // Get all drivers
    const { data: profiles } = await supabase
      .from('profiles')
      .select('*')
      .eq('role', 'driver')
      .order('created_at')

    if (!profiles) { setLoading(false); return }

    // Get stats for each driver
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
    setLoading(false)
  }

  async function toggleStatus(driver: DriverWithStats) {
    await supabase
      .from('profiles')
      .update({ status: driver.status === 'active' ? 'inactive' : 'active' })
      .eq('id', driver.id)
    loadDrivers()
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 className="w-6 h-6 animate-spin text-primary" />
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-bold text-gray-900">Mitra / Driver</h1>
        <p className="text-sm text-muted-foreground">{drivers.length} mitra terdaftar</p>
      </div>

      {drivers.length === 0 ? (
        <div className="bg-white rounded-2xl border p-12 text-center">
          <Users className="w-10 h-10 text-gray-200 mx-auto mb-3" />
          <p className="text-sm text-muted-foreground">Belum ada mitra terdaftar</p>
          <p className="text-xs text-muted-foreground mt-1">
            Daftarkan mitra melalui Supabase Dashboard → Authentication
          </p>
        </div>
      ) : (
        <div className="space-y-3">
          {drivers.map(driver => (
            <div key={driver.id} className="bg-white rounded-2xl border p-4">
              <div className="flex items-center justify-between mb-3">
                <div className="flex items-center gap-3">
                  <div className="w-10 h-10 bg-primary/10 rounded-full flex items-center justify-center">
                    <span className="text-sm font-bold text-primary">
                      {driver.full_name.charAt(0)}
                    </span>
                  </div>
                  <div>
                    <div className="flex items-center gap-2">
                      <p className="font-medium text-gray-900">{driver.full_name}</p>
                      {driver.has_active_shift && (
                        <span className="flex items-center gap-1 text-[10px] bg-green-50 text-green-600 px-2 py-0.5 rounded-full font-medium">
                          <Circle className="w-1.5 h-1.5 fill-current" />
                          Online
                        </span>
                      )}
                    </div>
                    <p className="text-xs text-muted-foreground">{driver.phone || 'No phone'}</p>
                  </div>
                </div>
                <button
                  onClick={() => toggleStatus(driver)}
                  className={`px-3 py-1 rounded-lg text-xs font-medium transition-colors ${
                    driver.status === 'active'
                      ? 'bg-green-50 text-green-600'
                      : 'bg-red-50 text-red-600'
                  }`}
                >
                  {driver.status === 'active' ? 'Aktif' : 'Nonaktif'}
                </button>
              </div>

              <div className="grid grid-cols-2 gap-2">
                <div className="bg-gray-50 rounded-xl px-3 py-2">
                  <div className="flex items-center gap-1.5 text-xs text-muted-foreground mb-0.5">
                    <ShoppingBag className="w-3 h-3" /> Pesanan
                  </div>
                  <p className="text-sm font-bold">{driver.total_orders}</p>
                </div>
                <div className="bg-gray-50 rounded-xl px-3 py-2">
                  <div className="flex items-center gap-1.5 text-xs text-muted-foreground mb-0.5">
                    <TrendingUp className="w-3 h-3" /> Omzet
                  </div>
                  <p className="text-sm font-bold">{formatRupiah(driver.total_revenue)}</p>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
