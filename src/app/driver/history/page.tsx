'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { formatRupiah, formatTime } from '@/lib/format'
import { ShoppingBag, MapPin, Clock, Loader2, ChevronRight, Calendar, Pencil } from 'lucide-react'
import { isCupCategory } from '@/lib/constants'
import type { Order, OrderItem, Product } from '@/types/database'
import { jakartaToday, jakartaDayRange } from '@/lib/date'
import EditPesanan from '@/components/driver/EditPesanan'

interface OrderWithItems extends Order {
  order_items: (OrderItem & { product: Product | null })[]
}

export default function HistoryPage() {
  const { user } = useAuth()
  const [orders, setOrders] = useState<OrderWithItems[]>([])
  const [loading, setLoading] = useState(true)
  const [selectedDate, setSelectedDate] = useState(
    jakartaToday()
  )
  const [expandedOrder, setExpandedOrder] = useState<string | null>(null)
  const [editingOrder, setEditingOrder] = useState<string | null>(null)
  const [products, setProducts] = useState<Product[]>([])
  const supabase = createClient()


  useEffect(() => {
    if (user) loadOrders()
  }, [user, selectedDate])

  useEffect(() => {
    supabase
      .from('products')
      .select('*')
      .eq('is_available', true)
      .order('sort_order')
      .then(({ data }) => { if (data) setProducts(data as Product[]) })
  }, [])  // eslint-disable-line react-hooks/exhaustive-deps

  async function loadOrders() {
    if (!user) return
    setLoading(true)

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
        .gte('created_at', jakartaDayRange(selectedDate).start)
        .lt('created_at', jakartaDayRange(selectedDate).endExclusive)
        .order('created_at', { ascending: false })

      if (data) setOrders(data as OrderWithItems[])
    } finally {
      setLoading(false)
    }
  }

  const totalRevenue = orders.reduce((sum, o) => sum + o.total_amount, 0)

  // Cup dihitung dari item pesanan yang memang sudah ikut termuat di layar
  // ini, memakai aturan yang sama dengan server: hanya kategori smoothie.
  // Sebelumnya jumlah transaksi yang dilabeli "Cup", sehingga satu nota
  // berisi tiga cup terhitung satu.
  const totalCups = orders.reduce(
    (sum, o) =>
      sum +
      (o.order_items ?? []).reduce(
        (n, item) => n + (isCupCategory(item.product?.category) ? item.quantity : 0),
        0
      ),
    0
  )

  return (
    <div className="p-4 space-y-4">
      {/* Header */}
      <div>
        <h1 className="font-extrabold text-xl text-zinc-900 tracking-tight">Riwayat Penjualan</h1>
        <p className="text-xs text-zinc-500 mt-0.5">Daftar transaksi penjualan unit gerobak</p>
      </div>

      {/* Date Filter Input */}
      <div className="bg-white border border-zinc-200/80 rounded-2xl p-2.5 flex items-center gap-2.5 shadow-card">
        <Calendar className="w-4 h-4 text-zinc-400 ml-1 shrink-0" />
        <input
          type="date"
          value={selectedDate}
          onChange={e => setSelectedDate(e.target.value)}
          className="w-full bg-transparent text-xs font-semibold text-zinc-800 focus:outline-none"
        />
      </div>

      {/* Summary KPI Card */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-card flex items-center justify-between">
        <div>
          <span className="text-[11px] font-semibold text-zinc-400 uppercase tracking-wider block mb-0.5">
            Total Omzet
          </span>
          <p className="text-xl font-extrabold text-zinc-900 tracking-tight">
            {formatRupiah(totalRevenue)}
          </p>
        </div>
        <div className="text-right">
          <span className="text-[11px] font-semibold text-zinc-400 uppercase tracking-wider block mb-0.5">
            Cup Terjual
          </span>
          <p className="text-xl font-extrabold text-brand tracking-tight">
            {totalCups} <span className="text-xs font-medium text-zinc-500">cup</span>
          </p>
          <span className="text-[11px] text-zinc-400">{orders.length} transaksi</span>
        </div>
      </div>

      {/* Orders List */}
      {loading ? (
        <div className="flex flex-col items-center justify-center h-48 text-zinc-400 gap-2">
          <Loader2 className="w-6 h-6 animate-spin text-brand" />
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
            <div key={order.id} className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
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
                  <span className="font-extrabold text-sm text-zinc-900">
                    {formatRupiah(order.total_amount)}
                  </span>
                  <ChevronRight className={`w-4 h-4 text-zinc-400 transition-transform duration-200 ${
                    expandedOrder === order.id ? 'rotate-90' : ''
                  }`} />
                </div>
              </button>

              {expandedOrder === order.id && editingOrder !== order.id && (
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

                  {/* Tanggal tidak lagi membatasi. Salah ketik sering baru
                      ketahuan keesokan harinya, dan yang menjaga angka adalah
                      kunci rekonsiliasi — bukan pergantian tanggal. Kalau
                      harinya sudah dikunci, server yang menolak dan pesannya
                      muncul di layar ini. */}
                  <button
                    type="button"
                    onClick={() => setEditingOrder(order.id)}
                    className="mt-2 inline-flex items-center gap-1.5 text-[11px] font-bold text-brand hover:underline"
                  >
                    <Pencil strokeWidth={2.5} className="w-3 h-3" />
                    Salah input? Perbaiki
                  </button>
                </div>
              )}

              {editingOrder === order.id && (
                <EditPesanan
                  orderId={order.id}
                  awal={(order.order_items ?? []).map(i => ({
                    product_id: i.product_id,
                    quantity: i.quantity,
                  }))}
                  produk={products}
                  onSelesai={() => { setEditingOrder(null); loadOrders() }}
                  onBatalEdit={() => setEditingOrder(null)}
                />
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
