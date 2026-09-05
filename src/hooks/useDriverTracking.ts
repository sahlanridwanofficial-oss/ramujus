'use client'

import { useEffect, useRef, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { TRACKING_CONFIG } from '@/lib/constants'

export interface DriverTrackingState {
  /** Browser sedang mengawasi GPS. */
  watching: boolean
  /** Waktu posisi terakhir yang berhasil dikirim ke server. */
  lastSentAt: Date | null
  /** Pesan siap tampil bila pelacakan tidak dapat berjalan. */
  error: string | null
}

/** Jarak dua koordinat dalam meter (haversine). */
function distanceMeters(
  aLat: number, aLng: number, bLat: number, bLng: number
): number {
  const R = 6371000
  const toRad = (d: number) => (d * Math.PI) / 180
  const dLat = toRad(bLat - aLat)
  const dLng = toRad(bLng - aLng)
  const lat1 = toRad(aLat)
  const lat2 = toRad(bLat)
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2
  return 2 * R * Math.asin(Math.sqrt(h))
}

/**
 * Mengirim posisi driver ke server selama shift berlangsung.
 *
 * Memakai watchPosition, bukan getCurrentPosition berulang, supaya posisi
 * mengikuti pergerakan gerobak. Pengiriman dibatasi dua arah: minimal
 * `minIntervalMs` sejak kiriman terakhir, dan diabaikan bila gerobak belum
 * bergerak lebih dari `minDistanceMeters` — kecuali sudah melewati
 * `heartbeatMs`, agar admin tetap bisa membedakan "diam di tempat" dari
 * "aplikasi mati".
 *
 * Batas yang perlu diketahui: ini pelacakan foreground. Saat tab
 * disembunyikan atau layar ponsel mati, browser menahan pembaruan
 * geolokasi. Posisi akan tampak basi di peta admin sampai driver membuka
 * aplikasinya lagi — itulah sebabnya peta menandai umur posisi.
 */
export function useDriverTracking(enabled: boolean): DriverTrackingState {
  const [state, setState] = useState<DriverTrackingState>({
    watching: false,
    lastSentAt: null,
    error: null,
  })

  const supabase = useRef(createClient())
  const watchId = useRef<number | null>(null)
  const lastSent = useRef<{ at: number; lat: number; lng: number } | null>(null)
  const sending = useRef(false)

  useEffect(() => {
    if (!enabled) {
      if (watchId.current !== null) {
        navigator.geolocation.clearWatch(watchId.current)
        watchId.current = null
      }
      setState(prev => ({ ...prev, watching: false }))
      return
    }

    if (typeof navigator === 'undefined' || !navigator.geolocation) {
      setState({
        watching: false,
        lastSentAt: null,
        error: 'Perangkat ini tidak mendukung GPS.',
      })
      return
    }

    let cancelled = false

    async function send(position: GeolocationPosition) {
      // Satu kiriman pada satu waktu; jaringan lambat tidak boleh menumpuk.
      if (sending.current) return

      const { latitude, longitude, accuracy, speed, heading } = position.coords
      const now = Date.now()
      const previous = lastSent.current

      if (previous) {
        const elapsed = now - previous.at
        if (elapsed < TRACKING_CONFIG.minIntervalMs) return

        const moved = distanceMeters(previous.lat, previous.lng, latitude, longitude)
        if (moved < TRACKING_CONFIG.minDistanceMeters && elapsed < TRACKING_CONFIG.heartbeatMs) {
          return
        }
      }

      sending.current = true
      try {
        const { error } = await supabase.current.rpc('update_driver_position', {
          p_latitude: latitude,
          p_longitude: longitude,
          p_accuracy: accuracy ?? null,
          p_speed: speed ?? null,
          p_heading: heading ?? null,
          p_history_interval_seconds: TRACKING_CONFIG.historyIntervalSeconds,
        })

        if (cancelled) return

        if (error) {
          // Shift ditutup dari perangkat lain — hentikan, jangan banjiri server.
          if (error.message?.includes('SHIFT_NOT_ACTIVE')) {
            if (watchId.current !== null) {
              navigator.geolocation.clearWatch(watchId.current)
              watchId.current = null
            }
            setState({
              watching: false,
              lastSentAt: null,
              error: 'Shift sudah tidak aktif, pelacakan dihentikan.',
            })
            return
          }
          setState(prev => ({ ...prev, error: 'Posisi gagal terkirim. Menunggu sinyal.' }))
          return
        }

        lastSent.current = { at: now, lat: latitude, lng: longitude }
        setState(prev => ({ ...prev, lastSentAt: new Date(now), error: null }))
      } catch {
        if (!cancelled) {
          setState(prev => ({ ...prev, error: 'Posisi gagal terkirim. Menunggu sinyal.' }))
        }
      } finally {
        sending.current = false
      }
    }

    watchId.current = navigator.geolocation.watchPosition(
      (position) => { void send(position) },
      (err) => {
        if (cancelled) return
        setState(prev => ({
          ...prev,
          watching: false,
          error:
            err.code === err.PERMISSION_DENIED
              ? 'Izin lokasi ditolak. Admin tidak dapat memantau gerobak Anda.'
              : 'Sinyal GPS belum didapat.',
        }))
      },
      {
        enableHighAccuracy: true,
        timeout: TRACKING_CONFIG.timeoutMs,
        maximumAge: TRACKING_CONFIG.maximumAgeMs,
      }
    )

    setState(prev => ({ ...prev, watching: true, error: null }))

    return () => {
      cancelled = true
      if (watchId.current !== null) {
        navigator.geolocation.clearWatch(watchId.current)
        watchId.current = null
      }
    }
  }, [enabled])

  return state
}
