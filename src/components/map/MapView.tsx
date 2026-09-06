'use client'

import { useEffect, useMemo } from 'react'
import { MapContainer, TileLayer, Marker, Popup, CircleMarker, useMap } from 'react-leaflet'
import L from 'leaflet'
import { formatRupiah } from '@/lib/format'
import { DEFAULT_MAP_CENTER, DEFAULT_MAP_ZOOM } from '@/lib/constants'
import type { FleetUnit, FleetPresence } from '@/types/fleet'

interface OrderLocation {
  id: string
  latitude: number
  longitude: number
  total_amount: number
  order_number: string
  created_at: string
}

interface MapViewProps {
  fleet: FleetUnit[]
  orders: OrderLocation[]
  showOrders: boolean
  focusDriverId?: string | null
}

const PRESENCE_STYLE: Record<FleetPresence, { color: string; label: string }> = {
  live: { color: '#059669', label: 'Terpantau' },
  stale: { color: '#d97706', label: 'Sinyal tertunda' },
  offline: { color: '#71717a', label: 'Tidak terpantau' },
}

/** Ikon gerobak: warna mengikuti kesegaran posisi, denyut hanya saat live. */
function cartIcon(unit: FleetUnit): L.DivIcon {
  const { color } = PRESENCE_STYLE[unit.presence]
  const initials = unit.full_name
    .split(' ')
    .slice(0, 2)
    .map(w => w[0] ?? '')
    .join('')
    .toUpperCase()

  return L.divIcon({
    className: 'ramu-cart-marker',
    html: `
      <div style="position:relative;display:flex;align-items:center;justify-content:center;">
        ${unit.presence === 'live'
          ? `<span style="position:absolute;width:38px;height:38px;border-radius:50%;background:${color};opacity:0.22;"></span>`
          : ''}
        <div style="
          position:relative;
          background:${color};
          color:#fff;
          width:30px;height:30px;
          border-radius:50%;
          border:2.5px solid #fff;
          box-shadow:0 3px 10px rgba(0,0,0,0.28);
          display:flex;align-items:center;justify-content:center;
          font:700 10px/1 ui-sans-serif,system-ui,sans-serif;
          letter-spacing:0.02em;
        ">${initials}</div>
      </div>
    `,
    iconSize: [38, 38],
    iconAnchor: [19, 19],
    popupAnchor: [0, -18],
  })
}

function relativeTime(seconds: number | null): string {
  if (seconds === null) return 'belum pernah mengirim posisi'
  if (seconds < 60) return `${seconds} detik lalu`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes} menit lalu`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} jam lalu`
  return `${Math.floor(hours / 24)} hari lalu`
}

/** Menggeser peta ke gerobak yang dipilih dari daftar di samping. */
function FocusController({ fleet, focusDriverId }: { fleet: FleetUnit[]; focusDriverId?: string | null }) {
  const map = useMap()

  useEffect(() => {
    if (!focusDriverId) return
    const unit = fleet.find(f => f.driver_id === focusDriverId)
    if (unit?.latitude != null && unit.longitude != null) {
      map.flyTo([unit.latitude, unit.longitude], 16, { duration: 0.8 })
    }
  }, [focusDriverId, fleet, map])

  return null
}

export default function MapView({ fleet, orders, showOrders, focusDriverId }: MapViewProps) {
  const positioned = useMemo(
    () => fleet.filter(f => f.latitude != null && f.longitude != null),
    [fleet]
  )

  // Peta berpusat pada armada yang sedang terpantau; kalau belum ada satu
  // pun posisi, jatuh ke titik bawaan agar peta tidak melompat ke laut.
  const center = useMemo<[number, number]>(() => {
    const source = positioned.length > 0 ? positioned : null
    if (!source) return DEFAULT_MAP_CENTER
    return [
      source.reduce((s, f) => s + (f.latitude as number), 0) / source.length,
      source.reduce((s, f) => s + (f.longitude as number), 0) / source.length,
    ]
  }, [positioned])

  return (
    <MapContainer
      center={center}
      zoom={DEFAULT_MAP_ZOOM}
      scrollWheelZoom
      className="w-full h-[560px] z-10"
    >
      {/* Tile OpenStreetMap standar: gratis, tanpa API key, tanpa watermark.
          Penyedia sebelumnya (CARTO) memunculkan watermark "API key required"
          saat diakses anonim di produksi. */}
      <TileLayer
        attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
        url="https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        maxZoom={19}
      />

      <FocusController fleet={fleet} focusDriverId={focusDriverId} />

      {/* Lapisan sebaran transaksi — titik kecil agar tidak menutupi gerobak */}
      {showOrders && orders.map(order => (
        <CircleMarker
          key={order.id}
          center={[order.latitude, order.longitude]}
          radius={4}
          pathOptions={{ color: '#be1a1a', weight: 1, fillColor: '#be1a1a', fillOpacity: 0.45 }}
        >
          <Popup>
            <div className="p-1 text-xs">
              <span className="font-mono font-bold text-zinc-900 block">{order.order_number}</span>
              <span className="font-black text-[#be1a1a] text-sm block mt-0.5">
                {formatRupiah(order.total_amount)}
              </span>
              <span className="text-[10px] text-zinc-400 block mt-1">
                {new Date(order.created_at).toLocaleString('id-ID', {
                  day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit',
                })}
              </span>
            </div>
          </Popup>
        </CircleMarker>
      ))}

      {/* Lapisan gerobak — posisi driver sebenarnya */}
      {positioned.map(unit => (
        <Marker
          key={unit.driver_id}
          position={[unit.latitude as number, unit.longitude as number]}
          icon={cartIcon(unit)}
        >
          <Popup>
            <div className="p-1 text-xs min-w-[170px]">
              <span className="font-bold text-zinc-900 block text-[13px]">{unit.full_name}</span>
              <span
                className="inline-block mt-1 px-1.5 py-0.5 rounded-full text-[10px] font-bold"
                style={{
                  color: PRESENCE_STYLE[unit.presence].color,
                  background: `${PRESENCE_STYLE[unit.presence].color}1a`,
                }}
              >
                {PRESENCE_STYLE[unit.presence].label}
              </span>
              <div className="mt-1.5 space-y-0.5 text-[11px] text-zinc-500">
                <div>Posisi {relativeTime(unit.seconds_since)}</div>
                <div>
                  Hari ini: <span className="font-bold text-zinc-800">{unit.cups_today} cup</span>
                  <span className="text-zinc-400"> · {unit.orders_today} transaksi</span>
                </div>
                <div className="font-bold text-[#be1a1a]">{formatRupiah(unit.revenue_today)}</div>
                {unit.accuracy != null && (
                  <div className="text-[10px] text-zinc-400">Akurasi ±{Math.round(unit.accuracy)} m</div>
                )}
              </div>
            </div>
          </Popup>
        </Marker>
      ))}
    </MapContainer>
  )
}
