'use client'

import { useState, useEffect, useCallback } from 'react'

export interface Coordinates {
  latitude: number | null
  longitude: number | null
  accuracy: number | null
}

interface GeolocationState extends Coordinates {
  loading: boolean
  error: string | null
}

const EMPTY_COORDINATES: Coordinates = {
  latitude: null,
  longitude: null,
  accuracy: null,
}

export function useGeolocation() {
  const [state, setState] = useState<GeolocationState>({
    latitude: null,
    longitude: null,
    accuracy: null,
    loading: false,
    error: null,
  })

  // Mengembalikan koordinat yang baru didapat, bukan hanya menyetel state.
  // Pemanggil yang perlu menyimpan lokasi ke database harus meng-await ini —
  // membaca `latitude`/`longitude` tepat setelah memanggil getPosition() akan
  // memberi nilai dari render sebelumnya (atau null pada pemanggilan pertama).
  const getPosition = useCallback((): Promise<Coordinates> => {
    if (!navigator.geolocation) {
      setState(prev => ({
        ...prev,
        error: 'Geolocation tidak didukung di browser ini',
        loading: false,
      }))
      return Promise.resolve(EMPTY_COORDINATES)
    }

    setState(prev => ({ ...prev, loading: true, error: null }))

    return new Promise<Coordinates>((resolve) => {
      navigator.geolocation.getCurrentPosition(
        (position) => {
          const coords: Coordinates = {
            latitude: position.coords.latitude,
            longitude: position.coords.longitude,
            accuracy: position.coords.accuracy,
          }
          setState({ ...coords, loading: false, error: null })
          resolve(coords)
        },
        (error) => {
          let message = 'Gagal mendapatkan lokasi'
          switch (error.code) {
            case error.PERMISSION_DENIED:
              message = 'Izin lokasi ditolak. Aktifkan GPS di pengaturan browser.'
              break
            case error.POSITION_UNAVAILABLE:
              message = 'Lokasi tidak tersedia'
              break
            case error.TIMEOUT:
              message = 'Request lokasi timeout'
              break
          }
          setState(prev => ({ ...prev, error: message, loading: false }))
          // Lokasi bersifat pelengkap: transaksi tetap boleh jalan tanpanya.
          resolve(EMPTY_COORDINATES)
        },
        {
          enableHighAccuracy: true,
          timeout: 15000,
          maximumAge: 0,
        }
      )
    })
  }, [])

  return { ...state, getPosition }
}
