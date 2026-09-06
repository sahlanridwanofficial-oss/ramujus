'use client'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { Loader2, Navigation, RefreshCw, MapPin, TriangleAlert, Search } from 'lucide-react'
import dynamic from 'next/dynamic'
import { formatRupiah } from '@/lib/format'
import { toFleetUnit, type FleetOverviewRow, type FleetUnit, type FleetPresence } from '@/types/fleet'

const MapView = dynamic(() => import('@/components/map/MapView'), {
  ssr: false,
  loading: () => (
    <div className="w-full h-[560px] bg-zinc-100 rounded-3xl animate-pulse flex flex-col items-center justify-center text-zinc-400 gap-2">
      <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
      <span className="text-xs font-semibold">Menginisialisasi peta armada ramu...</span>
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

// Peta sebaran transaksi dibatasi supaya jumlah penanda tidak tumbuh tanpa
// batas seiring armada bertambah. Pada 100 gerobak, 7 hari transaksi sudah
// jauh lebih banyak dari yang berguna dibaca sekaligus.
const ORDER_LAYER_DAYS = 7
const ORDER_LAYER_LIMIT = 500

const PRESENCE_LABEL: Record<FleetPresence, string> = {
  live: 'Terpantau',
  stale: 'Sinyal tertunda',
  offline: 'Tidak terpantau',
}

const PRESENCE_DOT: Record<FleetPresence, string> = {
  live: 'bg-emerald-500',
  stale: 'bg-amber-500',
  offline: 'bg-zinc-300',
}

function relativeTime(seconds: number | null): string {
  if (seconds === null) return '—'
  if (seconds < 60) return `${seconds} dtk`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes} mnt`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} jam`
  return `${Math.floor(hours / 24)} hr`
}

export default function MapPage() {
  const [fleet, setFleet] = useState<FleetUnit[]>([])
  const [orders, setOrders] = useState<OrderLocation[]>([])
  const [showOrders, setShowOrders] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [lastRefresh, setLastRefresh] = useState<Date | null>(null)
  const [focusDriverId, setFocusDriverId] = useState<string | null>(null)
  const [query, setQuery] = useState('')

  const [supabase] = useState(() => createClient())
  const inFlight = useRef(false)

  const loadFleet = useCallback(async () => {
    // Realtime dapat memicu beberapa pembaruan sekaligus saat 100 gerobak
    // mengirim posisi; satu permintaan pada satu waktu sudah cukup.
    if (inFlight.current) return
    inFlight.current = true

    try {
      const { data, error: rpcError } = await supabase.rpc('fleet_overview')

      if (rpcError) {
        setError('Gagal memuat posisi armada. Coba muat ulang.')
        return
      }

      const rows = (data ?? []) as FleetOverviewRow[]
      setFleet(rows.map(toFleetUnit))
      setLastRefresh(new Date())
      setError(null)
    } catch {
      setError('Tidak dapat terhubung ke server.')
    } finally {
      inFlight.current = false
      setLoading(false)
    }
  }, [supabase])

  const loadOrders = useCallback(async () => {
    const since = new Date()
    since.setDate(since.getDate() - ORDER_LAYER_DAYS)

    const { data } = await supabase
      .from('orders')
      .select('id, latitude, longitude, total_amount, order_number, created_at')
      .not('latitude', 'is', null)
      .not('longitude', 'is', null)
      .gte('created_at', since.toISOString())
      .order('created_at', { ascending: false })
      .limit(ORDER_LAYER_LIMIT)

    setOrders((data ?? []) as OrderLocation[])
  }, [supabase])

  useEffect(() => {
    void loadFleet()

    // Posisi baru mendorong pembaruan; tidak ada polling ketat.
    const channel = supabase
      .channel('fleet-positions')
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'driver_positions' },
        () => { void loadFleet() }
      )
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'shifts' },
        () => { void loadFleet() }
      )
      .subscribe()

    // Penyegaran lambat hanya untuk memperbarui umur posisi ("3 menit lalu")
    // dan menangkap gerobak yang berhenti mengirim tanpa peristiwa apa pun.
    const ticker = setInterval(() => { void loadFleet() }, 60_000)

    return () => {
      clearInterval(ticker)
      void supabase.removeChannel(channel)
    }
  }, [supabase, loadFleet])

  useEffect(() => {
    if (showOrders && orders.length === 0) void loadOrders()
  }, [showOrders, orders.length, loadOrders])

  const counts = useMemo(() => ({
    live: fleet.filter(f => f.presence === 'live').length,
    stale: fleet.filter(f => f.presence === 'stale').length,
    offline: fleet.filter(f => f.presence === 'offline').length,
    onShift: fleet.filter(f => f.on_shift).length,
  }), [fleet])

  const visibleFleet = useMemo(() => {
    const q = query.trim().toLowerCase()
    const rows = q ? fleet.filter(f => f.full_name.toLowerCase().includes(q)) : fleet
    // Yang perlu perhatian admin naik ke atas: sinyal tertunda dulu, lalu
    // yang terpantau, lalu yang tidak berdinas.
    const rank: Record<FleetPresence, number> = { stale: 0, live: 1, offline: 2 }
    return [...rows].sort((a, b) => rank[a.presence] - rank[b.presence] || a.full_name.localeCompare(b.full_name))
  }, [fleet, query])

  return (
    <div className="space-y-4">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-black text-zinc-900 tracking-tight">Peta Armada Gerobak</h1>
          <p className="text-xs text-zinc-500 mt-0.5">
            Posisi gerobak dikirim langsung dari aplikasi driver selama shift berjalan.
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <span className="inline-flex items-center gap-1.5 bg-emerald-50 border border-emerald-200 px-3 py-1.5 rounded-full text-xs font-bold text-emerald-700">
            <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse" />
            {counts.live} terpantau
          </span>
          {counts.stale > 0 && (
            <span className="inline-flex items-center gap-1.5 bg-amber-50 border border-amber-200 px-3 py-1.5 rounded-full text-xs font-bold text-amber-700">
              <TriangleAlert className="w-3.5 h-3.5" />
              {counts.stale} tertunda
            </span>
          )}
          <span className="inline-flex items-center gap-1.5 bg-white border border-zinc-200/80 px-3 py-1.5 rounded-full text-xs font-semibold text-zinc-600">
            <Navigation className="w-3.5 h-3.5 text-zinc-400" />
            {counts.onShift} dari {fleet.length} berdinas
          </span>
          <button
            onClick={() => { void loadFleet() }}
            className="inline-flex items-center gap-1.5 bg-white hover:bg-zinc-50 border border-zinc-200/80 px-3 py-1.5 rounded-full text-xs font-semibold text-zinc-700 transition-colors"
          >
            <RefreshCw className="w-3.5 h-3.5" />
            Segarkan
          </button>
        </div>
      </div>

      {error && (
        <div role="alert" className="p-3 bg-red-50 border border-red-300 rounded-xl flex items-center gap-2 text-xs text-[#be1a1a] font-semibold">
          <TriangleAlert className="w-4 h-4 shrink-0" />
          <span>{error}</span>
        </div>
      )}

      {loading ? (
        <div className="flex flex-col items-center justify-center h-80 gap-2 text-zinc-400">
          <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
          <span className="text-xs">Memuat posisi armada...</span>
        </div>
      ) : (
        <div className="grid grid-cols-1 lg:grid-cols-[1fr_300px] gap-4 items-start">
          <div className="rounded-3xl overflow-hidden border border-zinc-200/80 shadow-card bg-white">
            <MapView
              fleet={fleet}
              orders={orders}
              showOrders={showOrders}
              focusDriverId={focusDriverId}
            />
            <div className="flex flex-wrap items-center justify-between gap-2 px-4 py-2.5 border-t border-zinc-100 bg-zinc-50/60">
              <label className="flex items-center gap-2 text-[11px] font-semibold text-zinc-600 cursor-pointer">
                <input
                  type="checkbox"
                  checked={showOrders}
                  onChange={(e) => setShowOrders(e.target.checked)}
                  className="accent-[#be1a1a]"
                />
                <MapPin className="w-3.5 h-3.5 text-[#be1a1a]" />
                Tampilkan sebaran transaksi {ORDER_LAYER_DAYS} hari terakhir
                {showOrders && <span className="text-zinc-400 font-medium">({orders.length} titik)</span>}
              </label>
              <span className="text-[10px] text-zinc-400">
                {lastRefresh ? `Diperbarui ${lastRefresh.toLocaleTimeString('id-ID')}` : ''}
              </span>
            </div>
          </div>

          {/* Daftar armada — pada 100 gerobak, peta saja tidak cukup dibaca */}
          <div className="bg-white rounded-3xl border border-zinc-200/80 shadow-card overflow-hidden">
            <div className="p-3 border-b border-zinc-100">
              <div className="relative">
                <Search className="w-3.5 h-3.5 text-zinc-400 absolute left-2.5 top-1/2 -translate-y-1/2" />
                <input
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  placeholder="Cari nama mitra..."
                  className="w-full bg-zinc-50 border border-zinc-200 rounded-xl pl-8 pr-3 py-2 text-xs focus:outline-none focus:border-[#be1a1a]"
                />
              </div>
            </div>

            <div className="max-h-[500px] overflow-y-auto divide-y divide-zinc-100">
              {visibleFleet.length === 0 && (
                <p className="p-4 text-xs text-zinc-400 text-center">Tidak ada mitra yang cocok.</p>
              )}

              {visibleFleet.map(unit => (
                <button
                  key={unit.driver_id}
                  onClick={() => setFocusDriverId(unit.driver_id)}
                  disabled={unit.latitude === null}
                  className={`w-full text-left p-3 hover:bg-zinc-50 transition-colors disabled:hover:bg-transparent disabled:cursor-default ${
                    focusDriverId === unit.driver_id ? 'bg-red-50/50' : ''
                  }`}
                >
                  <div className="flex items-center justify-between gap-2">
                    <div className="flex items-center gap-2 min-w-0">
                      <span className={`w-2 h-2 rounded-full shrink-0 ${PRESENCE_DOT[unit.presence]}`} />
                      <span className="text-xs font-bold text-zinc-900 truncate">{unit.full_name}</span>
                    </div>
                    <span className="text-[10px] text-zinc-400 font-mono shrink-0">
                      {relativeTime(unit.seconds_since)}
                    </span>
                  </div>
                  <div className="flex items-center justify-between gap-2 mt-1 pl-4">
                    <span className="text-[10px] text-zinc-500">{PRESENCE_LABEL[unit.presence]}</span>
                    <span className="text-[10px] font-bold text-zinc-700">
                      {unit.cups_today} cup · {unit.orders_today} transaksi · {formatRupiah(unit.revenue_today)}
                    </span>
                  </div>
                </button>
              ))}
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
