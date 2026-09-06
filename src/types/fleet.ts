import { FLEET_STATUS_THRESHOLDS } from '@/lib/constants'

/** Baris mentah yang dikembalikan RPC fleet_overview(). */
export interface FleetOverviewRow {
  driver_id: string
  full_name: string
  phone: string | null
  driver_status: string
  latitude: number | null
  longitude: number | null
  accuracy: number | null
  speed: number | null
  heading: number | null
  recorded_at: string | null
  seconds_since: number | null
  shift_id: string | null
  shift_started_at: string | null
  on_shift: boolean
  orders_today: number
  cups_today: number
  revenue_today: number
}

/**
 * Seberapa dapat dipercaya posisi terakhir sebuah gerobak.
 *
 * Dibedakan dari "sedang shift": gerobak bisa berdinas tetapi posisinya
 * basi karena ponsel terkunci atau sinyal hilang. Menyamakan keduanya akan
 * membuat admin mengira gerobak berhenti di titik yang sebenarnya sudah
 * lama ditinggalkan.
 */
export type FleetPresence = 'live' | 'stale' | 'offline'

export interface FleetUnit extends FleetOverviewRow {
  presence: FleetPresence
}

export function resolvePresence(row: FleetOverviewRow): FleetPresence {
  if (!row.on_shift) return 'offline'
  if (row.seconds_since === null) return 'offline'
  if (row.seconds_since <= FLEET_STATUS_THRESHOLDS.liveSeconds) return 'live'
  if (row.seconds_since <= FLEET_STATUS_THRESHOLDS.staleSeconds) return 'stale'
  return 'offline'
}

export function toFleetUnit(row: FleetOverviewRow): FleetUnit {
  return { ...row, presence: resolvePresence(row) }
}
