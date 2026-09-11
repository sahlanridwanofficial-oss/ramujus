'use client'

/**
 * Tombol "Mangkal di sini".
 *
 * Satu ketuk saat gerobak sampai di titik, satu saat pindah. Dari situ lama
 * mangkal terekam langsung — tidak lagi diperkirakan dari stempel pesanan.
 *
 * Perkiraan lama runtuh karena kebiasaan yang nyata: driver sering mencatat
 * pesanan setelah selesai melayani, beberapa sekaligus. Stempel waktunya
 * jadi waktu ia sempat mengetik, bukan waktu orang membeli — dan rentang
 * pesanan menyusut dari satu jam jadi hitungan detik. Cup per jam ikut
 * tampil berkali-kali lipat lebih tinggi dari kenyataan, ke arah yang
 * paling berbahaya untuk keputusan sewa.
 *
 * Ketukan yang gagal terkirim disimpan di perangkat dan dicoba ulang,
 * memakai pola yang sama dengan antrean pesanan. Tiap ketukan membawa
 * kunci idempotensi, jadi mengirim ulang tidak pernah menghasilkan dua
 * catatan mangkal.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { MapPin, Loader2, Navigation, TriangleAlert } from 'lucide-react'

interface CurrentStop {
  id: string
  started_at: string
  latitude: number | null
  longitude: number | null
  minutes: number
  cups: number
}

const PENDING_KEY = 'ramu.stop-pending.v1'

interface PendingTap {
  action: 'start' | 'end'
  client_stop_id: string
  latitude: number | null
  longitude: number | null
  accuracy: number | null
}

function readPending(): PendingTap | null {
  if (typeof window === 'undefined') return null
  try {
    const raw = window.localStorage.getItem(PENDING_KEY)
    return raw ? (JSON.parse(raw) as PendingTap) : null
  } catch {
    return null
  }
}

function writePending(tap: PendingTap | null): void {
  if (typeof window === 'undefined') return
  try {
    if (tap) window.localStorage.setItem(PENDING_KEY, JSON.stringify(tap))
    else window.localStorage.removeItem(PENDING_KEY)
  } catch {
    // Penyimpanan penuh atau mode privat — ketukan tetap dikirim sekali.
  }
}

function newId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = (Math.random() * 16) | 0
    const v = c === 'x' ? r : (r & 0x3) | 0x8
    return v.toString(16)
  })
}

/** Posisi saat ini; null bila ditolak atau perangkat tidak mendukung. */
function getPosition(): Promise<GeolocationPosition | null> {
  return new Promise(resolve => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) return resolve(null)
    navigator.geolocation.getCurrentPosition(
      pos => resolve(pos),
      () => resolve(null),
      { enableHighAccuracy: true, timeout: 8000, maximumAge: 30000 }
    )
  })
}

function lamanya(menit: number): string {
  if (menit < 60) return `${menit} menit`
  const jam = Math.floor(menit / 60)
  const sisa = menit % 60
  return sisa === 0 ? `${jam} jam` : `${jam} jam ${sisa} menit`
}

export default function StopTracker({ shiftActive }: { shiftActive: boolean }) {
  const [stop, setStop] = useState<CurrentStop | null>(null)
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [supabase] = useState(() => createClient())
  const tick = useRef<ReturnType<typeof setInterval> | null>(null)

  const refresh = useCallback(async () => {
    const { data, error: err } = await supabase.rpc('driver_current_stop')
    if (err) {
      // Fungsi belum ada berarti migrasi 0020 belum dijalankan. Diam saja —
      // fitur ini tambahan, bukan syarat berjualan.
      setStop(null)
      setLoading(false)
      return
    }
    const row = Array.isArray(data) ? data[0] : data
    setStop((row as CurrentStop) ?? null)
    setLoading(false)
  }, [supabase])

  useEffect(() => {
    refresh()
  }, [refresh])

  // Kirim ulang ketukan yang tertinggal saat sinyal kembali.
  useEffect(() => {
    async function flush() {
      const tap = readPending()
      if (!tap) return
      const { error: err } =
        tap.action === 'start'
          ? await supabase.rpc('driver_start_stop', {
              p_latitude: tap.latitude,
              p_longitude: tap.longitude,
              p_accuracy: tap.accuracy,
              p_client_stop_id: tap.client_stop_id,
            })
          : await supabase.rpc('driver_end_stop')
      if (!err) {
        writePending(null)
        refresh()
      }
    }
    flush()
    window.addEventListener('online', flush)
    return () => window.removeEventListener('online', flush)
  }, [supabase, refresh])

  // Penghitung waktu berjalan, supaya driver melihat lamanya tanpa memuat ulang.
  useEffect(() => {
    if (!stop) {
      if (tick.current) clearInterval(tick.current)
      return
    }
    tick.current = setInterval(() => {
      setStop(s => (s ? { ...s, minutes: s.minutes + 1 } : s))
    }, 60_000)
    return () => {
      if (tick.current) clearInterval(tick.current)
    }
  }, [stop?.id]) // eslint-disable-line react-hooks/exhaustive-deps

  async function mulai() {
    setBusy(true)
    setError(null)
    const pos = await getPosition()
    const tap: PendingTap = {
      action: 'start',
      client_stop_id: newId(),
      latitude: pos?.coords.latitude ?? null,
      longitude: pos?.coords.longitude ?? null,
      accuracy: pos?.coords.accuracy ?? null,
    }
    const { error: err } = await supabase.rpc('driver_start_stop', {
      p_latitude: tap.latitude,
      p_longitude: tap.longitude,
      p_accuracy: tap.accuracy,
      p_client_stop_id: tap.client_stop_id,
    })
    if (err) {
      writePending(tap)
      setError('Belum terkirim — disimpan dan dicoba lagi saat sinyal kembali.')
    } else {
      await refresh()
    }
    setBusy(false)
  }

  async function pindah() {
    setBusy(true)
    setError(null)
    const { error: err } = await supabase.rpc('driver_end_stop')
    if (err) {
      writePending({
        action: 'end', client_stop_id: newId(),
        latitude: null, longitude: null, accuracy: null,
      })
      setError('Belum terkirim — disimpan dan dicoba lagi saat sinyal kembali.')
    } else {
      setStop(null)
    }
    setBusy(false)
  }

  // Mangkal hanya masuk akal selama shift berjalan.
  if (!shiftActive || loading) return null

  return (
    <div
      className={`rounded-xl border p-4 ${
        stop ? 'border-brand bg-brand-soft' : 'border-zinc-200/80 bg-white'
      }`}
    >
      <div className="flex items-center gap-3">
        <div
          className={`w-9 h-9 rounded-lg flex items-center justify-center shrink-0 ${
            stop ? 'bg-brand text-white' : 'bg-zinc-100 text-zinc-400'
          }`}
        >
          {stop ? <MapPin strokeWidth={2} className="w-4 h-4" />
                : <Navigation strokeWidth={2} className="w-4 h-4" />}
        </div>

        <div className="flex-1 min-w-0">
          {stop ? (
            <>
              <p className="text-sm font-bold text-zinc-900 leading-tight">
                Sedang mangkal · {lamanya(stop.minutes)}
              </p>
              <p className="text-[11px] text-zinc-500 mt-0.5">
                {stop.cups} cup terjual sejak mangkal di sini
              </p>
            </>
          ) : (
            <>
              <p className="text-sm font-bold text-zinc-900 leading-tight">Belum mangkal</p>
              <p className="text-[11px] text-zinc-500 mt-0.5">
                Tekan saat sampai di titik jualan
              </p>
            </>
          )}
        </div>

        <button
          type="button"
          onClick={stop ? pindah : mulai}
          disabled={busy}
          className={`shrink-0 px-4 py-2.5 rounded-lg text-xs font-bold transition-colors disabled:opacity-60 ${
            stop
              ? 'bg-white text-brand border border-brand-border hover:bg-red-50'
              : 'bg-brand text-white hover:bg-brand-dark'
          }`}
        >
          {busy ? (
            <Loader2 className="w-4 h-4 animate-spin" />
          ) : stop ? (
            'Pindah'
          ) : (
            'Mangkal di sini'
          )}
        </button>
      </div>

      {error && (
        <p className="mt-2.5 pt-2.5 border-t border-zinc-200/70 flex items-start gap-2 text-[11px] text-amber-700 leading-relaxed">
          <TriangleAlert strokeWidth={2} className="w-3.5 h-3.5 shrink-0 mt-px" />
          {error}
        </p>
      )}
    </div>
  )
}
