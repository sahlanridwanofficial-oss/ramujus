'use client'

import { useOrderQueue } from '@/hooks/useOrderQueue'
import { clearRejected } from '@/lib/offlineQueue'
import { formatRupiah } from '@/lib/format'
import { CloudOff, Loader2, TriangleAlert, X } from 'lucide-react'

/**
 * Pemberitahuan tetap tentang pesanan yang belum sampai ke server.
 *
 * Sengaja ditempatkan di layout dan selalu terlihat selama ada antrean:
 * driver menutup kas berdasarkan apa yang tercatat, jadi ia harus tahu
 * kalau ada penjualan yang belum terkirim — atau yang ditolak server.
 */
export default function QueueStatus() {
  const { pending, rejected, syncing, online, flush, refresh } = useOrderQueue()

  if (pending.length === 0 && rejected.length === 0) return null

  const pendingTotal = pending.reduce((sum, o) => sum + o.total_estimate, 0)

  return (
    <div className="px-4 pt-3 space-y-2">
      {pending.length > 0 && (
        <div className="bg-amber-50 border border-amber-300 rounded-xl p-3">
          <div className="flex items-start gap-2.5">
            {syncing
              ? <Loader2 className="w-4 h-4 text-amber-600 shrink-0 mt-px animate-spin" />
              : <CloudOff className="w-4 h-4 text-amber-600 shrink-0 mt-px" />}
            <div className="flex-1 min-w-0">
              <p className="text-xs font-bold text-amber-900">
                {pending.length} pesanan menunggu terkirim
                <span className="font-mono font-semibold"> · {formatRupiah(pendingTotal)}</span>
              </p>
              <p className="text-[11px] text-amber-800/80 mt-0.5 leading-relaxed">
                {syncing
                  ? 'Sedang mengirim ke server...'
                  : online
                    ? 'Akan terkirim otomatis. Tetap buka aplikasi sebentar.'
                    : 'Perangkat sedang offline. Pesanan aman tersimpan di ponsel.'}
              </p>
            </div>
            {online && !syncing && (
              <button
                onClick={() => { void flush() }}
                className="text-[10px] font-bold text-amber-900 bg-amber-100 hover:bg-amber-200 border border-amber-300 px-2 py-1 rounded-lg shrink-0 transition-colors"
              >
                Kirim
              </button>
            )}
          </div>
        </div>
      )}

      {rejected.length > 0 && (
        <div className="bg-red-50 border border-red-300 rounded-xl p-3">
          <div className="flex items-start gap-2.5">
            <TriangleAlert className="w-4 h-4 text-[#be1a1a] shrink-0 mt-px" />
            <div className="flex-1 min-w-0">
              <p className="text-xs font-bold text-[#be1a1a]">
                {rejected.length} pesanan ditolak server
              </p>
              <p className="text-[11px] text-red-800/80 mt-0.5 leading-relaxed">
                Penjualan ini <span className="font-bold">tidak tercatat</span>. Laporkan ke admin
                sebelum tutup kas.
              </p>
              <ul className="mt-1.5 space-y-1">
                {rejected.slice(0, 3).map(order => (
                  <li key={order.client_order_id} className="text-[10px] text-red-900/80 font-mono">
                    {formatRupiah(order.total_estimate)} ·{' '}
                    {order.reason.includes('INSUFFICIENT_STOCK')
                      ? 'stok gerobak tidak cukup'
                      : order.reason.includes('SHIFT_NOT_ACTIVE')
                        ? 'shift sudah ditutup'
                        : order.reason.includes('PRODUCT_UNAVAILABLE')
                          ? 'produk dinonaktifkan admin'
                          : 'ditolak server'}
                  </li>
                ))}
              </ul>
            </div>
            <button
              onClick={() => { clearRejected(); refresh() }}
              title="Sudah dilaporkan ke admin"
              className="text-red-400 hover:text-[#be1a1a] shrink-0 transition-colors"
            >
              <X className="w-3.5 h-3.5" />
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
