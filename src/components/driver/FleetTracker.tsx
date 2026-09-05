'use client'

import { useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { useDriverTracking } from '@/hooks/useDriverTracking'
import { Satellite, SatelliteDish, TriangleAlert } from 'lucide-react'

/**
 * Mengirim posisi gerobak selama shift aktif, dari halaman driver mana pun.
 *
 * Dipasang di layout, bukan di satu halaman, supaya pelacakan tetap
 * berjalan ketika driver berpindah ke halaman pesanan atau riwayat —
 * justru di sanalah driver menghabiskan waktu saat berjualan.
 */
export default function FleetTracker() {
  const { user } = useAuth()
  const [shiftActive, setShiftActive] = useState(false)
  const [supabase] = useState(() => createClient())
  const tracking = useDriverTracking(shiftActive)

  useEffect(() => {
    if (!user) {
      setShiftActive(false)
      return
    }

    let cancelled = false

    async function readShift() {
      const { data } = await supabase
        .from('shifts')
        .select('id')
        .eq('driver_id', user!.id)
        .eq('status', 'active')
        .maybeSingle()

      if (!cancelled) setShiftActive(!!data)
    }

    void readShift()

    // Shift dibuka atau ditutup dari halaman lain — ikuti perubahannya tanpa
    // memaksa driver memuat ulang aplikasi.
    const channel = supabase
      .channel(`driver-shift-${user.id}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'shifts',
          filter: `driver_id=eq.${user.id}`,
        },
        () => { void readShift() }
      )
      .subscribe()

    return () => {
      cancelled = true
      void supabase.removeChannel(channel)
    }
  }, [user, supabase])

  if (!user || user.role !== 'driver') return null

  if (!shiftActive) {
    return (
      <span
        title="Pelacakan berjalan saat shift dimulai"
        className="flex items-center gap-1 text-[10px] font-semibold text-zinc-400 bg-zinc-100/80 px-2 py-1 rounded-full"
      >
        <Satellite className="w-3 h-3" />
        <span className="hidden sm:inline">GPS siaga</span>
      </span>
    )
  }

  if (tracking.error) {
    return (
      <span
        title={tracking.error}
        className="flex items-center gap-1 text-[10px] font-semibold text-amber-700 bg-amber-50 border border-amber-200 px-2 py-1 rounded-full"
      >
        <TriangleAlert className="w-3 h-3" />
        <span className="hidden sm:inline">GPS bermasalah</span>
      </span>
    )
  }

  return (
    <span
      title={
        tracking.lastSentAt
          ? `Posisi terkirim ${tracking.lastSentAt.toLocaleTimeString('id-ID')}`
          : 'Mencari sinyal GPS'
      }
      className="flex items-center gap-1 text-[10px] font-semibold text-emerald-700 bg-emerald-50 border border-emerald-200 px-2 py-1 rounded-full"
    >
      <SatelliteDish className="w-3 h-3" />
      <span className="hidden sm:inline">
        {tracking.lastSentAt ? 'Terpantau' : 'Mencari sinyal'}
      </span>
    </span>
  )
}
