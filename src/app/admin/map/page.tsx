'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { Loader2, MapPin, Navigation } from 'lucide-react'
import dynamic from 'next/dynamic'

const MapView = dynamic(() => import('@/components/map/MapView'), {
  ssr: false,
  loading: () => (
    <div className="w-full h-[540px] bg-zinc-100 rounded-3xl animate-pulse flex flex-col items-center justify-center text-zinc-400 gap-2">
      <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
      <span className="text-xs font-semibold">Menginisialisasi peta geospatial ramu...</span>
    </div>
  ),
})

interface OrderLocation {
  id: string
  latitude: number
  longitude: number
  total_amount: number
  order_number: string
  created_at: string
}

export default function MapPage() {
  const [locations, setLocations] = useState<OrderLocation[]>([])
  const [loading, setLoading] = useState(true)
  const supabase = createClient()

  useEffect(() => { loadLocations() }, [])

  async function loadLocations() {
    const thirtyDaysAgo = new Date()
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30)

    try {
      const { data } = await supabase
        .from('orders')
        .select('id, latitude, longitude, total_amount, order_number, created_at')
        .not('latitude', 'is', null)
        .not('longitude', 'is', null)
        .gte('created_at', thirtyDaysAgo.toISOString())

      if (data) {
        setLocations(data as OrderLocation[])
      } else {
        setLocations([])
      }
    } catch {
      setLocations([])
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
        <div>
          <h1 className="text-2xl font-black text-zinc-900 tracking-tight">Peta Sebaran Armada Gerobak</h1>
          <p className="text-xs text-zinc-500 mt-0.5">
            Titik koordinat transaksi dan posisi GPS unit penjualan ramu.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <span className="inline-flex items-center gap-1.5 bg-white border border-zinc-200/80 px-3 py-1.5 rounded-full text-xs font-semibold text-zinc-700 shadow-xs">
            <Navigation className="w-3.5 h-3.5 text-[#be1a1a]" />
            <span>{locations.length} Titik Penjualan</span>
          </span>
        </div>
      </div>

      {loading ? (
        <div className="flex flex-col items-center justify-center h-80 gap-2 text-zinc-400">
          <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
          <span className="text-xs">Memuat data geolokasi...</span>
        </div>
      ) : (
        <div className="rounded-3xl overflow-hidden border border-zinc-200/80 shadow-xs bg-white">
          <MapView locations={locations} />
        </div>
      )}
    </div>
  )
}
