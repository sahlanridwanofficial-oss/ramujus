'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { Loader2, MapPin } from 'lucide-react'
import dynamic from 'next/dynamic'

const MapView = dynamic(() => import('@/components/map/MapView'), {
  ssr: false,
  loading: () => (
    <div className="w-full h-[500px] bg-gray-100 rounded-2xl animate-pulse flex items-center justify-center text-muted-foreground">
      Memuat peta...
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

    const { data } = await supabase
      .from('orders')
      .select('id, latitude, longitude, total_amount, order_number, created_at')
      .not('latitude', 'is', null)
      .not('longitude', 'is', null)
      .gte('created_at', thirtyDaysAgo.toISOString())

    if (data) setLocations(data as OrderLocation[])
    setLoading(false)
  }

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-bold text-gray-900">Peta Penjualan</h1>
        <p className="text-sm text-muted-foreground">
          <MapPin className="w-3.5 h-3.5 inline mr-1" />
          {locations.length} lokasi penjualan (30 hari terakhir)
        </p>
      </div>

      {loading ? (
        <div className="flex items-center justify-center h-64">
          <Loader2 className="w-6 h-6 animate-spin text-primary" />
        </div>
      ) : (
        <div className="rounded-2xl overflow-hidden border">
          <MapView locations={locations} />
        </div>
      )}
    </div>
  )
}
