'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { formatRupiah, formatTime, formatDate } from '@/lib/format'
import { ShoppingBag, MapPin, Clock, Loader2, ChevronRight, Calendar } from 'lucide-react'
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

    if (user.id === 'demo-driver-id') {
      const demoOrders: OrderWithItems[] = [
        {
          id: 'demo-1',
          shift_id: 'shift-1',
          driver_id: 'demo-driver-id',
          order_number: 'RMJ-' + selectedDate.replace(/-/g, '') + '-012',
          total_amount: 42000,
          payment_method: 'qris',
          latitude: -6.2088,
          longitude: 106.8456,
          address: null,
          customer_notes: null,
          created_at: `${selectedDate}T14:32:00Z`,
          order_items: [
            { id: 'item-1', order_id: 'demo-1', product_id: '1', quantity: 2, unit_price: 18000, subtotal: 36000, product: { id: '1', name: 'Green Paradise', description: null, image_url: null, price: 18000, category: 'smoothie', is_available: true, sort_order: 1, created_at: '' } },
            { id: 'item-2', order_id: 'demo-1', product_id: '7', quantity: 1, unit_price: 6000, subtotal: 6000, product: { id: '7', name: 'Extra Granola', description: null, image_url: null, price: 6000, category: 'topping', is_available: true, sort_order: 2, created_at: '' } }
          ]
        },
        {
          id: 'demo-2',
          shift_id: 'shift-1',
          driver_id: 'demo-driver-id',
          order_number: 'RMJ-' + selectedDate.replace(/-/g, '') + '-011',
          total_amount: 20000,
          payment_method: 'cash',
          latitude: -6.2092,
          longitude: 106.8462,
          address: null,
          customer_notes: null,
          created_at: `${selectedDate}T12:15:00Z`,
          order_items: [
            { id: 'item-3', order_id: 'demo-2', product_id: '2', quantity: 1, unit_price: 20000, subtotal: 20000, product: { id: '2', name: 'Berry Blast', description: null, image_url: null, price: 20000, category: 'smoothie', is_available: true, sort_order: 2, created_at: '' } }
          ]
        }
      ]
      setOrders(demoOrders)
      setLoading(false)
      return
    }

    try {
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
    } finally {
      setLoading(false)
    }
  }

  const totalRevenue = orders.reduce((sum, o) => sum + o.total_amount, 0)

  return (
    <div className="p-4 space-y-4">
      {/* Header */}
      <div>
        <h1 className="font-black text-xl text-zinc-900 tracking-tight">Riwayat Penjualan</h1>
        <p className="text-xs text-zinc-500 mt-0.5">Daftar transaksi penjualan unit gerobak</p>
      </div>

      {/* Date Filter Input */}
      <div className="bg-white border border-zinc-200/80 rounded-2xl p-2.5 flex items-center gap-2.5 shadow-xs">
        <Calendar className="w-4 h-4 text-zinc-400 ml-1 shrink-0" />
        <input
          type="date"
          value={selectedDate}
          onChange={e => setSelectedDate(e.target.value)}
          className="w-full bg-transparent text-xs font-semibold text-zinc-800 focus:outline-none"
        />
      </div>

      {/* Summary KPI Card */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-sm flex items-center justify-between">
        <div>
          <span className="text-[11px] font-semibold text-zinc-400 uppercase tracking-wider block mb-0.5">
            Total Omzet
          </span>
          <p className="text-xl font-black text-zinc-900 tracking-tight">
            {formatRupiah(totalRevenue)}
          </p>
        </div>
        <div className="text-right">
          <span className="text-[11px] font-semibold text-zinc-400 uppercase tracking-wider block mb-0.5">
            Transaksi
          </span>
          <p className="text-xl font-black text-[#be1a1a] tracking-tight">
            {orders.length} <span className="text-xs font-medium text-zinc-500">Cup</span>
          </p>
        </div>
      </div>

      {/* Orders List */}
      {loading ? (
        <div className="flex flex-col items-center justify-center h-48 text-zinc-400 gap-2">
          <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
          <span className="text-xs">Memuat riwayat transaksi...</span>
        </div>
      ) : orders.length === 0 ? (
        <div className="bg-white rounded-2xl border border-zinc-200/80 p-8 text-center">
          <ShoppingBag className="w-8 h-8 text-zinc-300 mx-auto mb-2" />
          <p className="text-sm font-semibold text-zinc-700">Belum ada pesanan pada tanggal ini</p>
          <p className="text-xs text-zinc-400 mt-1">Gunakan pemilih tanggal di atas untuk melihat tanggal lain</p>
        </div>
      ) : (
        <div className="space-y-2.5">
          {orders.map(order => (
            <div key={order.id} className="bg-white rounded-2xl border border-zinc-200/80 shadow-xs overflow-hidden">
              <button
                onClick={() => setExpandedOrder(
                  expandedOrder === order.id ? null : order.id
                )}
                className="w-full p-4 flex items-center justify-between text-left hover:bg-zinc-50/50 transition-colors"
              >
                <div>
                  <div className="flex items-center gap-2">
                    <p className="text-xs font-bold text-zinc-900 font-mono">
                      {order.order_number}
                    </p>
                    <span className="text-[10px] uppercase font-bold text-zinc-500 bg-zinc-100 px-2 py-0.5 rounded-full">
                      {order.payment_method}
                    </span>
                  </div>
                  <div className="flex items-center gap-3 mt-1.5 text-[11px] text-zinc-400">
                    <span className="flex items-center gap-1">
                      <Clock className="w-3 h-3" />
                      {formatTime(order.created_at)}
                    </span>
                    {order.latitude && (
                      <span className="flex items-center gap-1 text-emerald-600 font-medium">
                        <MapPin className="w-3 h-3" />
                        GPS Terverifikasi
                      </span>
                    )}
                  </div>
                </div>

                <div className="flex items-center gap-2">
                  <span className="font-black text-sm text-zinc-900">
                    {formatRupiah(order.total_amount)}
                  </span>
                  <ChevronRight className={`w-4 h-4 text-zinc-400 transition-transform duration-200 ${
                    expandedOrder === order.id ? 'rotate-90' : ''
                  }`} />
                </div>
              </button>

              {expandedOrder === order.id && (
                <div className="border-t border-zinc-100 p-4 bg-zinc-50/80 space-y-2">
                  <span className="text-[10px] font-bold text-zinc-400 uppercase tracking-wider block mb-1">
                    Detail Item:
                  </span>
                  {order.order_items?.map(item => (
                    <div key={item.id} className="flex justify-between text-xs text-zinc-700">
                      <span>
                        {item.product?.name || 'Item'} × {item.quantity}
                      </span>
                      <span className="font-semibold text-zinc-900">
                        {formatRupiah(item.subtotal)}
                      </span>
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
