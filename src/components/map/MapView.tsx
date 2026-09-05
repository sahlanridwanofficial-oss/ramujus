'use client'

import { useEffect } from 'react'
import { MapContainer, TileLayer, Marker, Popup } from 'react-leaflet'
import L from 'leaflet'
import { formatRupiah } from '@/lib/format'

// Fix default marker icons
delete (L.Icon.Default.prototype as any)._getIconUrl
L.Icon.Default.mergeOptions({
  iconRetinaUrl: 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png',
  iconUrl: 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon.png',
  shadowUrl: 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-shadow.png',
})

interface OrderLocation {
  id: string
  latitude: number
  longitude: number
  total_amount: number
  order_number: string
  created_at: string
}

interface MapViewProps {
  locations: OrderLocation[]
}

export default function MapView({ locations }: MapViewProps) {
  // Calculate center from locations or use default (Jakarta)
  const center: [number, number] = locations.length > 0
    ? [
        locations.reduce((s, l) => s + l.latitude, 0) / locations.length,
        locations.reduce((s, l) => s + l.longitude, 0) / locations.length,
      ]
    : [-6.2088, 106.8456]

  return (
    <MapContainer
      center={center}
      zoom={13}
      scrollWheelZoom={true}
      className="w-full h-[500px]"
    >
      <TileLayer
        attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
        url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
      />
      {locations.map(loc => (
        <Marker key={loc.id} position={[loc.latitude, loc.longitude]}>
          <Popup>
            <div className="text-sm">
              <p className="font-bold">{loc.order_number}</p>
              <p>{formatRupiah(loc.total_amount)}</p>
              <p className="text-gray-500">
                {new Date(loc.created_at).toLocaleDateString('id-ID')}
              </p>
            </div>
          </Popup>
        </Marker>
      ))}
    </MapContainer>
  )
}
