'use client'

import { useMemo } from 'react'
import { MapContainer, TileLayer, Marker, Popup } from 'react-leaflet'
import L from 'leaflet'
import { formatRupiah } from '@/lib/format'

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
  const customPin = useMemo(() => {
    return L.divIcon({
      className: 'custom-map-pin',
      html: `
        <div style="
          background-color: #be1a1a;
          width: 28px;
          height: 28px;
          border-radius: 50% 50% 50% 0;
          transform: rotate(-45deg);
          border: 2.5px solid #ffffff;
          box-shadow: 0 4px 12px rgba(190, 26, 26, 0.4);
          display: flex;
          align-items: center;
          justify-content: center;
        ">
          <div style="width: 8px; height: 8px; background-color: #ffffff; border-radius: 50%; transform: rotate(45deg);"></div>
        </div>
      `,
      iconSize: [28, 28],
      iconAnchor: [14, 28],
      popupAnchor: [0, -28],
    })
  }, [])

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
      scrollWheelZoom={false}
      className="w-full h-[520px] z-10"
    >
      <TileLayer
        attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
        url="https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png"
      />
      {locations.map(loc => (
        <Marker key={loc.id} position={[loc.latitude, loc.longitude]} icon={customPin}>
          <Popup className="custom-popup">
            <div className="p-1 text-xs">
              <span className="font-mono font-bold text-zinc-900 block">{loc.order_number}</span>
              <span className="font-black text-[#be1a1a] text-sm block mt-0.5">{formatRupiah(loc.total_amount)}</span>
              <span className="text-[10px] text-zinc-400 block mt-1">
                {new Date(loc.created_at).toLocaleDateString('id-ID', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
              </span>
            </div>
          </Popup>
        </Marker>
      ))}
    </MapContainer>
  )
}
