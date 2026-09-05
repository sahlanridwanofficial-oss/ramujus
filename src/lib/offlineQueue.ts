/**
 * Antrean pesanan yang belum terkirim ke server.
 *
 * Driver gerobak berjualan keliling dengan sinyal yang putus-nyambung.
 * Tanpa antrean, satu kegagalan jaringan berarti penjualan hilang dan stok
 * tidak terpotong. Pesanan yang gagal terkirim disimpan di perangkat lalu
 * dikirim ulang begitu sinyal kembali.
 *
 * Setiap antrean membawa client_order_id. Server mengembalikan pesanan yang
 * sudah ada bila kunci itu pernah masuk, jadi mengirim ulang aman walau
 * sebenarnya pesanan pertama berhasil dan yang hilang hanya responsnya.
 *
 * Disimpan di localStorage, bukan IndexedDB: muatannya kecil (beberapa
 * pesanan berisi id produk dan jumlah), sinkron sehingga tidak ada
 * penulisan yang tertinggal saat halaman ditutup, dan tidak menambah kode
 * asinkron yang sulit diuji. Keduanya sama-sama bisa dihapus browser saat
 * penyimpanan penuh.
 */

const QUEUE_KEY = 'ramu.order-queue.v1'
const REJECTED_KEY = 'ramu.order-rejected.v1'

export interface QueuedOrderItem {
  product_id: string
  quantity: number
}

export interface QueuedOrder {
  /** Kunci idempotensi; sama untuk setiap percobaan kirim pesanan ini. */
  client_order_id: string
  shift_id: string
  items: QueuedOrderItem[]
  payment_method: string
  latitude: number | null
  longitude: number | null
  accuracy: number | null
  /** Waktu transaksi sebenarnya, bukan waktu sinkronisasi. */
  created_at: string
  /** Hanya untuk ditampilkan ke driver selagi menunggu. */
  total_estimate: number
  attempts: number
}

export interface RejectedOrder extends QueuedOrder {
  reason: string
  rejected_at: string
}

function readList<T>(key: string): T[] {
  if (typeof window === 'undefined') return []
  try {
    const raw = window.localStorage.getItem(key)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? (parsed as T[]) : []
  } catch {
    // Isi rusak atau penyimpanan diblokir — jangan sampai menghentikan aplikasi.
    return []
  }
}

function writeList<T>(key: string, list: T[]): void {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.setItem(key, JSON.stringify(list))
  } catch {
    // Kuota penuh atau mode privat. Pesanan tetap diproses di memori.
  }
}

export function newClientOrderId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }
  // Cadangan untuk browser lama atau konteks non-HTTPS.
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = (Math.random() * 16) | 0
    const v = c === 'x' ? r : (r & 0x3) | 0x8
    return v.toString(16)
  })
}

export function getQueue(): QueuedOrder[] {
  return readList<QueuedOrder>(QUEUE_KEY)
}

export function enqueueOrder(order: QueuedOrder): void {
  const queue = getQueue()
  if (queue.some(o => o.client_order_id === order.client_order_id)) return
  queue.push(order)
  writeList(QUEUE_KEY, queue)
}

export function removeFromQueue(clientOrderId: string): void {
  writeList(QUEUE_KEY, getQueue().filter(o => o.client_order_id !== clientOrderId))
}

export function markAttempt(clientOrderId: string): void {
  writeList(
    QUEUE_KEY,
    getQueue().map(o =>
      o.client_order_id === clientOrderId ? { ...o, attempts: o.attempts + 1 } : o
    )
  )
}

export function getRejected(): RejectedOrder[] {
  return readList<RejectedOrder>(REJECTED_KEY)
}

/**
 * Pesanan yang ditolak server secara permanen — stok habis, produk
 * dinonaktifkan, shift sudah ditutup. Dikeluarkan dari antrean tetapi tetap
 * ditampilkan, karena driver perlu tahu penjualan itu tidak tercatat.
 */
export function rejectOrder(order: QueuedOrder, reason: string): void {
  removeFromQueue(order.client_order_id)
  const rejected = getRejected()
  rejected.unshift({ ...order, reason, rejected_at: new Date().toISOString() })
  writeList(REJECTED_KEY, rejected.slice(0, 20))
}

export function clearRejected(): void {
  writeList(REJECTED_KEY, [])
}

/**
 * Kegagalan yang tidak akan membaik dengan mencoba lagi.
 * Sisanya (jaringan, timeout, 5xx) dianggap sementara dan tetap diantre.
 */
export function isPermanentFailure(message: string | undefined): boolean {
  if (!message) return false
  return [
    'INSUFFICIENT_STOCK',
    'PRODUCT_UNAVAILABLE',
    'SHIFT_NOT_ACTIVE',
    'EMPTY_CART',
    'INVALID_QUANTITY',
    'INVALID_PAYMENT_METHOD',
  ].some(code => message.includes(code))
}
