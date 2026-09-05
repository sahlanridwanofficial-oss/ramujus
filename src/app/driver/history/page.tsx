'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { formatRupiah, formatTime, formatDate } from '@/lib/format'
import { ShoppingBag, MapPin, Clock, Loader2, ChevronRight } from 'lucide-react'
import type { Order, OrderItem, Product } from '@/types/database'

interface OrderWithItems extends Order {
  order_items: (OrderItem & { product: Product | null })[]
}

export default function HistoryPage() {
  const { user } = useAuth()
  const [orders, setOrders] = useState<OrderWithItems[]>([])
  const [loading, setLoading] = useState(true)
  const [selectedDate, setSelectedDate] = useState(
    new Date().toISOString().slice(0, 10)
  )
  const [expandedOrder, setExpandedOrder] = useState<string | null>(null)
  const supabase = createClient()

  useEffect(() => {
    if (user) loadOrders()
  }, [user, selectedDate])

  async function loadOrders() {
    if (!user) return
    setLoading(true)

    const { data } = await supabase
      .from('orders')
      .select(`
        *,
        order_items (
          *,
          product:products (*)
        )
      `)
      .eq('driver_id', user.id)
      .gte('created_at', `${selectedDate}T00:00:00`)
      .lte('created_at', `${selectedDate}T23:59:59`)
      .order('created_at', { ascending: false })

    if (data) setOrders(data as OrderWithItems[])
    setLoading(false)
  }

  const totalRevenue = orders.reduce((sum, o) => sum + o.total_amount, 0)

  return (
    <div className="p-4 space-y-4">
      <h1 className="font-bold text-gray-900 text-lg">Riwayat Penjualan</h1>

      {/* Date Picker */}
      <input
        type="date"
        value={selectedDate}
        onChange={e => setSelectedDate(e.target.value)}
        className="w-full bg-white border rounded-xl px-3.5 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-primary/20"
      />

      {/* Summary */}
      <div className="bg-white rounded-2xl border p-4 flex items-center justify-between">
        <div>
          <p className="text-xs text-muted-foreground">Total Hari Ini</p>
          <p className="text-xl font-bold text-gray-900">{formatRupiah(totalRevenue)}</p>
        </div>
        <div className="text-right">
          <p className="text-xs text-muted-foreground">Pesanan</p>
          <p className="text-xl font-bold text-primary">{orders.length}</p>
        </div>
      </div>

      {/* Order List */}
      {loading ? (
        <div className="flex items-center justify-center h-32">
          <Loader2 className="w-5 h-5 animate-spin text-primary" />
        </div>
      ) : orders.length === 0 ? (
        <div className="text-center py-12">
          <ShoppingBag className="w-10 h-10 text-gray-200 mx-auto mb-3" />
          <p className="text-sm text-muted-foreground">Belum ada pesanan</p>
        </div>
      ) : (
        <div className="space-y-2">
          {orders.map(order => (
            <div key={order.id} className="bg-white rounded-xl border overflow-hidden">
              <button
                onClick={() => setExpandedOrder(
                  expandedOrder === order.id ? null : order.id
                )}
                className="w-full p-3.5 flex items-center justify-between text-left"
              >
                <div>
                  <p className="text-sm font-semibold text-gray-900">
                    {order.order_number}
                  </p>
                  <div className="flex items-center gap-3 mt-1 text-xs text-muted-foreground">
                    <span className="flex items-center gap-1">
                      <Clock className="w-3 h-3" />
                      {formatTime(order.created_at)}
                    </span>
                    {order.latitude && (
                      <span className="flex items-center gap-1">
                        <MapPin className="w-3 h-3" />
                        GPS ✓
                      </span>
                    )}
                    <span className="capitalize bg-gray-100 px-2 py-0.5 rounded-full">
                      {order.payment_method}
                    </span>
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  <span className="font-bold text-sm text-gray-900">
                    {formatRupiah(order.total_amount)}
                  </span>
                  <ChevronRight className={`w-4 h-4 text-gray-400 transition-transform ${
                    expandedOrder === order.id ? 'rotate-90' : ''
                  }`} />
                </div>
              </button>

              {expandedOrder === order.id && (
                <div className="border-t px-3.5 py-3 bg-gray-50 space-y-1.5">
                  {order.order_items.map(item => (
                    <div key={item.id} className="flex justify-between text-sm">
                      <span className="text-gray-600">
                        {item.product?.name || 'Produk'} × {item.quantity}
                      </span>
                      <span className="font-medium">{formatRupiah(item.subtotal)}</span>
                    </div>
                  ))}
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
