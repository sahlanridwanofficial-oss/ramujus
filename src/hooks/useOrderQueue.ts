'use client'

import { useCallback, useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import {
  getQueue, getRejected, markAttempt, removeFromQueue, rejectOrder,
  isPermanentFailure, type QueuedOrder, type RejectedOrder,
} from '@/lib/offlineQueue'

export interface OrderQueueState {
  pending: QueuedOrder[]
  rejected: RejectedOrder[]
  syncing: boolean
  online: boolean
  /** Kirim ulang antrean sekarang. Aman dipanggil kapan saja. */
  flush: () => Promise<void>
  refresh: () => void
}

const RETRY_INTERVAL_MS = 30_000

/**
 * Menjaga antrean pesanan offline tetap terkirim.
 *
 * Mencoba mengirim saat koneksi kembali, saat aplikasi dibuka lagi, dan
 * secara berkala. Pengiriman berurutan, bukan paralel: 100 gerobak yang
 * serentak kembali online sesudah pemadaman tidak boleh membanjiri server.
 */
export function useOrderQueue(): OrderQueueState {
  const [pending, setPending] = useState<QueuedOrder[]>([])
  const [rejected, setRejected] = useState<RejectedOrder[]>([])
  const [syncing, setSyncing] = useState(false)
  const [online, setOnline] = useState(true)
  const [supabase] = useState(() => createClient())

  const refresh = useCallback(() => {
    setPending(getQueue())
    setRejected(getRejected())
  }, [])

  const flush = useCallback(async () => {
    const queue = getQueue()
    if (queue.length === 0) return

    setSyncing(true)
    try {
      for (const order of queue) {
        try {
          const { error } = await supabase.rpc('create_order', {
            p_shift_id: order.shift_id,
            p_items: order.items,
            p_payment_method: order.payment_method,
            p_latitude: order.latitude,
            p_longitude: order.longitude,
            p_accuracy: order.accuracy,
            p_client_order_id: order.client_order_id,
            p_created_at: order.created_at,
            p_customer_gender: order.customer_gender,
            p_customer_age_range: order.customer_age_range,
            p_customer_type: order.customer_type,
          })

          if (!error) {
            removeFromQueue(order.client_order_id)
            continue
          }

          if (isPermanentFailure(error.message)) {
            rejectOrder(order, error.message)
            continue
          }

          markAttempt(order.client_order_id)
          // Kegagalan sementara: hentikan putaran ini, coba lagi nanti.
          break
        } catch {
          markAttempt(order.client_order_id)
          break
        }
      }
    } finally {
      setSyncing(false)
      refresh()
    }
  }, [supabase, refresh])

  useEffect(() => {
    refresh()
    setOnline(typeof navigator === 'undefined' ? true : navigator.onLine)

    const handleOnline = () => { setOnline(true); void flush() }
    const handleOffline = () => setOnline(false)
    const handleVisible = () => {
      if (document.visibilityState === 'visible') void flush()
    }

    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)
    document.addEventListener('visibilitychange', handleVisible)

    void flush()
    const timer = setInterval(() => { void flush() }, RETRY_INTERVAL_MS)

    return () => {
      clearInterval(timer)
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
      document.removeEventListener('visibilitychange', handleVisible)
    }
  }, [flush, refresh])

  return { pending, rejected, syncing, online, flush, refresh }
}
