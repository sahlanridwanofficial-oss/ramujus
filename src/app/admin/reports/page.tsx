'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah, formatDate, formatTime } from '@/lib/format'
import {
  Loader2, Download, FileText, Calendar, ShoppingBag, TrendingUp
} from 'lucide-react'

interface ReportOrder {
  id: string
  order_number: string
  total_amount: number
  payment_method: string
  created_at: string
  driver: { full_name: string }[] | null
}

export default function ReportsPage() {
  const [orders, setOrders] = useState<ReportOrder[]>([])
  const [loading, setLoading] = useState(true)
  const [dateFrom, setDateFrom] = useState(
    new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10)
  )
  const [dateTo, setDateTo] = useState(
    new Date().toISOString().slice(0, 10)
  )
  const supabase = createClient()

  useEffect(() => { loadOrders() }, [dateFrom, dateTo])

  async function loadOrders() {
    setLoading(true)
    const { data } = await supabase
      .from('orders')
      .select(`
        id, order_number, total_amount, payment_method, created_at,
        driver:profiles!orders_driver_id_fkey (full_name)
      `)
      .gte('created_at', `${dateFrom}T00:00:00`)
      .lte('created_at', `${dateTo}T23:59:59`)
      .order('created_at', { ascending: false })

    if (data) setOrders(data as ReportOrder[])
    setLoading(false)
  }

  function exportCSV() {
    const headers = ['No', 'Order Number', 'Tanggal', 'Waktu', 'Driver', 'Total', 'Pembayaran']
    const rows = orders.map((o, i) => [
      i + 1,
      o.order_number,
      formatDate(o.created_at),
      formatTime(o.created_at),
      Array.isArray(o.driver) ? o.driver[0]?.full_name || '-' : (o.driver as any)?.full_name || '-',
      o.total_amount,
      o.payment_method,
    ])

    const csv = [headers, ...rows].map(r => r.join(',')).join('\n')
    const blob = new Blob([csv], { type: 'text/csv' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `ramujus-laporan-${dateFrom}-${dateTo}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  const totalRevenue = orders.reduce((s, o) => s + o.total_amount, 0)
  const cashOrders = orders.filter(o => o.payment_method === 'cash')
  const qrisOrders = orders.filter(o => o.payment_method === 'qris')
  const transferOrders = orders.filter(o => o.payment_method === 'transfer')

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-bold text-gray-900">Laporan</h1>
          <p className="text-sm text-muted-foreground">Export & ringkasan penjualan</p>
        </div>
        <button
          onClick={exportCSV}
          disabled={orders.length === 0}
          className="flex items-center gap-1.5 bg-primary text-white px-4 py-2 rounded-xl text-sm font-medium hover:bg-primary/90 disabled:opacity-50"
        >
          <Download className="w-4 h-4" />
          Export CSV
        </button>
      </div>

      {/* Date Filter */}
      <div className="bg-white rounded-2xl border p-4 flex items-center gap-3">
        <Calendar className="w-4 h-4 text-muted-foreground shrink-0" />
        <input
          type="date"
          value={dateFrom}
          onChange={e => setDateFrom(e.target.value)}
          className="flex-1 bg-gray-50 border rounded-xl px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary/20"
        />
        <span className="text-sm text-muted-foreground">—</span>
        <input
          type="date"
          value={dateTo}
          onChange={e => setDateTo(e.target.value)}
          className="flex-1 bg-gray-50 border rounded-xl px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary/20"
        />
      </div>

      {/* Summary */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <div className="bg-white rounded-2xl border p-4">
          <ShoppingBag className="w-5 h-5 text-blue-600 mb-1" />
          <p className="text-lg font-bold">{orders.length}</p>
          <p className="text-xs text-muted-foreground">Total Pesanan</p>
        </div>
        <div className="bg-white rounded-2xl border p-4">
          <TrendingUp className="w-5 h-5 text-emerald-600 mb-1" />
          <p className="text-lg font-bold">{formatRupiah(totalRevenue)}</p>
          <p className="text-xs text-muted-foreground">Total Omzet</p>
        </div>
        <div className="bg-white rounded-2xl border p-4">
          <p className="text-lg font-bold">{formatRupiah(cashOrders.reduce((s, o) => s + o.total_amount, 0))}</p>
          <p className="text-xs text-muted-foreground">Cash ({cashOrders.length})</p>
        </div>
        <div className="bg-white rounded-2xl border p-4">
          <p className="text-lg font-bold">{formatRupiah(qrisOrders.reduce((s, o) => s + o.total_amount, 0))}</p>
          <p className="text-xs text-muted-foreground">QRIS ({qrisOrders.length})</p>
        </div>
      </div>

      {/* Orders Table */}
      <div className="bg-white rounded-2xl border overflow-hidden">
        <div className="px-5 py-4 border-b">
          <h2 className="font-semibold text-gray-900 flex items-center gap-2">
            <FileText className="w-4 h-4" />
            Detail Pesanan
          </h2>
        </div>

        {loading ? (
          <div className="flex items-center justify-center py-12">
            <Loader2 className="w-5 h-5 animate-spin text-primary" />
          </div>
        ) : orders.length === 0 ? (
          <div className="text-center py-12 text-sm text-muted-foreground">
            Tidak ada data untuk periode ini
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-gray-50">
                <tr>
                  <th className="text-left px-5 py-3 font-medium text-gray-600">Order</th>
                  <th className="text-left px-5 py-3 font-medium text-gray-600">Tanggal</th>
                  <th className="text-left px-5 py-3 font-medium text-gray-600">Driver</th>
                  <th className="text-left px-5 py-3 font-medium text-gray-600">Bayar</th>
                  <th className="text-right px-5 py-3 font-medium text-gray-600">Total</th>
                </tr>
              </thead>
              <tbody className="divide-y">
                {orders.map(order => (
                  <tr key={order.id} className="hover:bg-gray-50">
                    <td className="px-5 py-3 font-medium text-gray-900">{order.order_number}</td>
                    <td className="px-5 py-3 text-muted-foreground">
                      {formatDate(order.created_at)}
                      <br />
                      <span className="text-xs">{formatTime(order.created_at)}</span>
                    </td>
                    <td className="px-5 py-3">{Array.isArray(order.driver) ? order.driver[0]?.full_name || '-' : (order.driver as any)?.full_name || '-'}</td>
                    <td className="px-5 py-3">
                      <span className="capitalize bg-gray-100 px-2 py-0.5 rounded-full text-xs font-medium">
                        {order.payment_method}
                      </span>
                    </td>
                    <td className="px-5 py-3 text-right font-bold">{formatRupiah(order.total_amount)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}
