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

// GPS Settings
export const GPS_CONFIG = {
  enableHighAccuracy: true,
  timeout: 15000,
  maximumAge: 0,
  trackingIntervalMs: 300000, // 5 minutes
} as const

// Default map center (Jakarta)
export const DEFAULT_MAP_CENTER: [number, number] = [-6.2088, 106.8456]
export const DEFAULT_MAP_ZOOM = 13
