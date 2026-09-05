export const APP_NAME = 'ramu.'
export const APP_DESCRIPTION = 'Sistem Manajemen Penjualan Smoothies ramu.'
export const APP_VERSION = '1.0.0'

export const COLORS = {
  primary: '#be1a1a',     // official ramu red
  primaryDark: '#9f1414',
  primaryLight: '#d62828',
  accent: '#18181b',      // zinc-900 for clean high-contrast
} as const

export const PAYMENT_METHODS = [
  { value: 'cash', label: 'Tunai', icon: 'Banknote' },
  { value: 'qris', label: 'QRIS', icon: 'QrCode' },
  { value: 'transfer', label: 'Transfer', icon: 'ArrowRightLeft' },
] as const

export const PRODUCT_CATEGORIES = [
  { value: 'smoothie', label: 'Smoothie' },
  { value: 'topping', label: 'Topping' },
  { value: 'addon', label: 'Add-on' },
] as const

// Hanya smoothie yang dijual per cup. Topping dan add-on adalah pelengkap
// dengan satuan sendiri (porsi/pcs), jadi tidak boleh ikut dijumlahkan ke
// dalam angka "Total Muatan Cup" — itu membuat jumlah cup di gerobak salah.
export const CUP_CATEGORY = 'smoothie'

export function isCupCategory(category: string | null | undefined): boolean {
  return category === CUP_CATEGORY
}

export const SHIFT_STATUS = {
  active: { label: 'Aktif', color: 'text-[#be1a1a] bg-red-50' },
  completed: { label: 'Selesai', color: 'text-zinc-600 bg-zinc-100' },
  cancelled: { label: 'Dibatalkan', color: 'text-red-700 bg-red-100' },
} as const

export const ROLES = {
  admin: 'Admin',
  driver: 'Driver',
} as const

// Pelacakan posisi gerobak selama shift.
//
// Angka-angka ini menentukan beban server pada 100 gerobak. Dengan
// minIntervalMs 30 detik, satu gerobak mengirim paling sering 2x/menit,
// jadi armada penuh menghasilkan ~200 panggilan/menit pada puncaknya —
// hanya menyentuh satu baris per gerobak di driver_positions.
// historyIntervalSeconds membatasi pertumbuhan location_logs secara
// terpisah: 120 detik berarti maksimal ~360 baris histori per gerobak per
// hari 12 jam, atau ~36 ribu baris armada penuh per hari.
export const TRACKING_CONFIG = {
  /** Jeda minimum antar kiriman posisi. */
  minIntervalMs: 30_000,
  /** Di bawah jarak ini dianggap belum berpindah. */
  minDistanceMeters: 25,
  /** Tetap kirim walau diam, agar admin tahu gerobak masih hidup. */
  heartbeatMs: 120_000,
  /** Jeda minimum antar baris histori yang disimpan server. */
  historyIntervalSeconds: 120,
  timeoutMs: 20_000,
  maximumAgeMs: 15_000,
} as const

// Umur posisi sebelum sebuah gerobak dianggap tidak lagi terpantau.
// Ambang "stale" sengaja beberapa kali heartbeat, supaya satu kali sinyal
// hilang tidak langsung menandai gerobak sebagai bermasalah.
export const FLEET_STATUS_THRESHOLDS = {
  liveSeconds: 180,
  staleSeconds: 900,
} as const

// Default map center (Jakarta)
export const DEFAULT_MAP_CENTER: [number, number] = [-6.2088, 106.8456]
export const DEFAULT_MAP_ZOOM = 13
