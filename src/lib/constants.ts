export const APP_NAME = 'RAMUJUS'
export const APP_DESCRIPTION = 'Sistem Manajemen Penjualan Smoothies'
export const APP_VERSION = '1.0.0'

export const COLORS = {
  primary: '#16a34a',     // green-600
  primaryDark: '#15803d', // green-700
  primaryLight: '#22c55e', // green-500
  accent: '#f59e0b',      // amber-500
} as const

export const PAYMENT_METHODS = [
  { value: 'cash', label: 'Cash', icon: 'Banknote' },
  { value: 'qris', label: 'QRIS', icon: 'QrCode' },
  { value: 'transfer', label: 'Transfer', icon: 'ArrowRightLeft' },
] as const

export const PRODUCT_CATEGORIES = [
  { value: 'smoothie', label: 'Smoothie' },
  { value: 'topping', label: 'Topping' },
  { value: 'addon', label: 'Add-on' },
] as const

export const SHIFT_STATUS = {
  active: { label: 'Aktif', color: 'text-green-600 bg-green-50' },
  completed: { label: 'Selesai', color: 'text-gray-600 bg-gray-50' },
  cancelled: { label: 'Dibatalkan', color: 'text-red-600 bg-red-50' },
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
