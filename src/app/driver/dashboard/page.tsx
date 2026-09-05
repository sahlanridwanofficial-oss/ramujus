'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { useGeolocation } from '@/hooks/useGeolocation'
import { formatRupiah, getGreeting } from '@/lib/format'
import {
  Play, Square, MapPin, ShoppingBag, TrendingUp,
  Loader2, CheckCircle2, AlertCircle
} from 'lucide-react'
import type { Shift } from '@/types/database'

export default function DriverDashboard() {
  const { user } = useAuth()
  const { latitude, longitude, getPosition, loading: gpsLoading } = useGeolocation()
  const [activeShift, setActiveShift] = useState<Shift | null>(null)
  const [todayStats, setTodayStats] = useState({ orders: 0, revenue: 0 })
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
      setActiveShift({
        id: 'demo-shift-id',
        driver_id: 'demo-driver-id',
        start_time: new Date().toISOString(),
        end_time: null,
        start_lat: -6.2088,
        start_lng: 106.8456,
        end_lat: null,
        end_lng: null,
        status: 'active',
        notes: null,
        created_at: new Date().toISOString()
      })
      setTodayStats({
        orders: 14,
        revenue: 286000
      })
      setLoading(false)
      return
    }

    try {
      // Get active shift
      const { data: shift } = await supabase
        .from('shifts')
        .select('*')
        .eq('driver_id', user.id)
        .eq('status', 'active')
        .maybeSingle()

      setActiveShift(shift)

      // Get today's stats
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
    } catch {
      // ignore
    }

    setLoading(false)
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
      }, 400)
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
      }, 400)
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
      <div className="flex items-center justify-center h-64">
        <Loader2 className="w-6 h-6 animate-spin text-primary" />
      </div>
    )
  }

  return (
    <div className="p-4 space-y-5">
      {/* Greeting */}
      <div>
        <h1 className="text-xl font-bold text-gray-900">
          {getGreeting()} 👋
        </h1>
        <p className="text-sm text-muted-foreground">{user?.full_name}</p>
      </div>

      {/* Shift Control */}
      <div className="bg-white rounded-2xl border p-5">
        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="font-semibold text-gray-900">Status Shift</h2>
            <div className="flex items-center gap-1.5 mt-1">
              {activeShift ? (
                <>
                  <span className="w-2 h-2 rounded-full bg-red-500 animate-pulse" />
                  <span className="text-sm text-red-600 font-medium">Aktif</span>
                </>
              ) : (
                <>
                  <span className="w-2 h-2 rounded-full bg-gray-300" />
                  <span className="text-sm text-gray-500">Belum mulai</span>
                </>
              )}
            </div>
          </div>
          <button
            onClick={activeShift ? endShift : startShift}
            disabled={shiftLoading}
            className={`flex items-center gap-2 px-5 py-2.5 rounded-xl font-medium text-sm transition-all ${
              activeShift
                ? 'bg-red-50 text-red-600 hover:bg-red-100'
                : 'bg-primary text-white hover:bg-primary/90 shadow-sm'
            }`}
          >
            {shiftLoading ? (
              <Loader2 className="w-4 h-4 animate-spin" />
            ) : activeShift ? (
              <Square className="w-4 h-4" />
            ) : (
              <Play className="w-4 h-4" />
            )}
            {activeShift ? 'Akhiri Shift' : 'Mulai Shift'}
          </button>
        </div>

        {/* GPS Status */}
        <div className="flex items-center gap-2 text-xs text-muted-foreground bg-gray-50 rounded-xl px-3 py-2">
          <MapPin className="w-3.5 h-3.5" />
          {gpsLoading ? (
            <span>Mencari lokasi...</span>
          ) : latitude ? (
            <span className="text-red-600">
              <CheckCircle2 className="w-3 h-3 inline mr-1" />
              GPS Aktif ({latitude.toFixed(4)}, {longitude?.toFixed(4)})
            </span>
          ) : (
            <span className="text-amber-600">
              <AlertCircle className="w-3 h-3 inline mr-1" />
              GPS belum aktif
            </span>
          )}
        </div>
      </div>

      {/* Today Stats */}
      <div className="grid grid-cols-2 gap-3">
        <div className="bg-white rounded-2xl border p-4">
          <div className="flex items-center gap-2 mb-2">
            <div className="w-8 h-8 bg-blue-50 rounded-lg flex items-center justify-center">
              <ShoppingBag className="w-4 h-4 text-blue-600" />
            </div>
          </div>
          <p className="text-2xl font-bold text-gray-900">{todayStats.orders}</p>
          <p className="text-xs text-muted-foreground">Pesanan Hari Ini</p>
        </div>
        <div className="bg-white rounded-2xl border p-4">
          <div className="flex items-center gap-2 mb-2">
            <div className="w-8 h-8 bg-red-50 rounded-lg flex items-center justify-center">
              <TrendingUp className="w-4 h-4 text-red-600" />
            </div>
          </div>
          <p className="text-2xl font-bold text-gray-900">{formatRupiah(todayStats.revenue)}</p>
          <p className="text-xs text-muted-foreground">Omzet Hari Ini</p>
        </div>
      </div>

      {/* Quick Action */}
      {activeShift && (
        <a
          href="/driver/order"
          className="block bg-primary text-white rounded-2xl p-4 text-center font-medium hover:bg-primary/90 transition-colors shadow-sm shadow-red-200"
        >
          + Pesanan Baru
        </a>
      )}

      {!activeShift && (
        <div className="bg-amber-50 rounded-2xl p-4 text-center">
          <p className="text-sm text-amber-700">
            Mulai shift terlebih dahulu untuk menginput pesanan
          </p>
        </div>
      )}
    </div>
  )
}
