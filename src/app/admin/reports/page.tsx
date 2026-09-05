'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah, formatDate, formatTime } from '@/lib/format'
import {
  Loader2, Download, FileText, Calendar, ShoppingBag, TrendingUp, TriangleAlert
} from 'lucide-react'

// Batas baris satu tampilan laporan. Rentang yang lebih besar dipersempit
// tanggalnya, bukan ditarik sekaligus ke browser.
const REPORT_ROW_LIMIT = 1000

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
  const [truncated, setTruncated] = useState(false)
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

    try {
      // Laporan adalah daftar transaksi, jadi tetap per baris — tapi harus
      // berbatas. Pada 100 gerobak, rentang satu bulan tanpa batas berarti
      // ratusan ribu baris ditarik ke browser sekaligus.
      const { data } = await supabase
        .from('orders')
        .select(`
          id, order_number, total_amount, payment_method, created_at,
          driver:profiles!orders_driver_id_fkey (full_name)
        `)
        .gte('created_at', `${dateFrom}T00:00:00`)
        .lte('created_at', `${dateTo}T23:59:59`)
        .order('created_at', { ascending: false })
        .limit(REPORT_ROW_LIMIT)

      const rows = (data ?? []) as ReportOrder[]
      setOrders(rows)
      setTruncated(rows.length >= REPORT_ROW_LIMIT)
    } catch {
      setOrders([])
      setTruncated(false)
    } finally {
      setLoading(false)
    }
  }

  function exportCSV() {
    const headers = ['No', 'Nomor Order', 'Tanggal', 'Waktu', 'Mitra Driver', 'Total', 'Metode Pembayaran']
    const rows = orders.map((o, i) => [
      i + 1,
      o.order_number,
      formatDate(o.created_at),
      formatTime(o.created_at),
      Array.isArray(o.driver) ? o.driver[0]?.full_name || '-' : (o.driver as unknown as { full_name: string } | null)?.full_name || '-',
      o.total_amount,
      o.payment_method,
    ])

    const csv = [headers, ...rows].map(r => r.join(',')).join('\n')
    const blob = new Blob([csv], { type: 'text/csv' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `ramu-laporan-${dateFrom}-${dateTo}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  const totalRevenue = orders.reduce((s, o) => s + o.total_amount, 0)
  const cashOrders = orders.filter(o => o.payment_method === 'cash')
  const qrisOrders = orders.filter(o => o.payment_method === 'qris')

  return (
    <div className="space-y-5">
      {truncated && (
        <div
          role="alert"
          className="p-3 bg-amber-50 border border-amber-300 rounded-xl flex items-start gap-2 text-xs text-amber-900 font-semibold"
        >
          <TriangleAlert className="w-4 h-4 shrink-0 mt-px" />
          <span className="leading-relaxed">
            Menampilkan {REPORT_ROW_LIMIT.toLocaleString('id-ID')} transaksi terbaru pada rentang ini.
            Persempit tanggalnya agar laporan dan ekspor CSV mencakup seluruh data.
          </span>
        </div>
      )}

      {/* Title & Export Button */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-black text-zinc-900 tracking-tight">Laporan Keuangan</h1>
          <p className="text-xs text-zinc-500 mt-0.5">Rekapitulasi transaksi penjualan & ekspor data Excel/CSV</p>
        </div>
        <button
          onClick={exportCSV}
          disabled={orders.length === 0}
          className="inline-flex items-center justify-center gap-2 bg-[#be1a1a] hover:bg-[#a61515] text-white px-4 py-2.5 rounded-xl text-xs font-bold transition-all shadow-xs disabled:opacity-50"
        >
          <Download className="w-4 h-4" />
          <span>Ekspor Format CSV</span>
        </button>
      </div>

      {/* Date Range Picker */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 p-4 flex flex-col sm:flex-row items-center gap-3 shadow-xs">
        <div className="flex items-center gap-2 text-xs font-bold text-zinc-400 uppercase tracking-wider shrink-0">
          <Calendar className="w-4 h-4" />
          <span>Rentang Tanggal:</span>
        </div>
        <div className="flex items-center gap-2 w-full sm:w-auto">
          <input
            type="date"
            value={dateFrom}
            onChange={e => setDateFrom(e.target.value)}
            className="bg-zinc-50 border border-zinc-200 rounded-xl px-3 py-2 text-xs font-semibold text-zinc-800 focus:outline-none focus:ring-2 focus:ring-[#be1a1a]/20"
          />
          <span className="text-xs text-zinc-400 font-bold">s/d</span>
          <input
            type="date"
            value={dateTo}
            onChange={e => setDateTo(e.target.value)}
            className="bg-zinc-50 border border-zinc-200 rounded-xl px-3 py-2 text-xs font-semibold text-zinc-800 focus:outline-none focus:ring-2 focus:ring-[#be1a1a]/20"
          />
        </div>
      </div>

      {/* Financial Summary */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <div className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-xs">
          <div className="flex items-center justify-between mb-3">
            <span className="text-xs font-bold text-zinc-400 uppercase tracking-wider">Volume Transaksi</span>
            <div className="w-8 h-8 rounded-xl bg-zinc-100 text-zinc-800 flex items-center justify-center">
              <ShoppingBag strokeWidth={2} className="w-4 h-4" />
            </div>
          </div>
          <p className="text-2xl font-black text-zinc-900 tracking-tight">{orders.length} Cup</p>
          <span className="text-[11px] text-zinc-400 mt-1 block">Pesanan tercatat</span>
        </div>

        <div className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-xs">
          <div className="flex items-center justify-between mb-3">
            <span className="text-xs font-bold text-zinc-400 uppercase tracking-wider">Total Pendapatan</span>
            <div className="w-8 h-8 rounded-xl bg-red-50 text-[#be1a1a] flex items-center justify-center">
              <TrendingUp strokeWidth={2} className="w-4 h-4" />
            </div>
          </div>
          <p className="text-2xl font-black text-zinc-900 tracking-tight">{formatRupiah(totalRevenue)}</p>
          <span className="text-[11px] text-zinc-400 mt-1 block">Semua kanal pembayaran</span>
        </div>

        <div className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-xs">
          <span className="text-xs font-bold text-zinc-400 uppercase tracking-wider block mb-3">Penerimaan QRIS</span>
          <p className="text-xl font-black text-zinc-900 tracking-tight">
            {formatRupiah(qrisOrders.reduce((s, o) => s + o.total_amount, 0))}
          </p>
          <span className="text-[11px] text-zinc-400 mt-1 block">{qrisOrders.length} transaksi non-tunai</span>
        </div>

        <div className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-xs">
          <span className="text-xs font-bold text-zinc-400 uppercase tracking-wider block mb-3">Penerimaan Tunai</span>
          <p className="text-xl font-black text-zinc-900 tracking-tight">
            {formatRupiah(cashOrders.reduce((s, o) => s + o.total_amount, 0))}
          </p>
          <span className="text-[11px] text-zinc-400 mt-1 block">{cashOrders.length} transaksi fisik</span>
        </div>
      </div>

      {/* Orders Table */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 shadow-xs overflow-hidden">
        <div className="px-6 py-4 border-b border-zinc-100 flex items-center gap-2">
          <FileText className="w-4 h-4 text-zinc-400" />
          <h2 className="font-bold text-sm text-zinc-900">Rincian Nota Transaksi Penjualan</h2>
        </div>

        {loading ? (
          <div className="flex flex-col items-center justify-center py-16 gap-2 text-zinc-400">
            <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
            <span className="text-xs">Menyiapkan laporan tabel...</span>
          </div>
        ) : orders.length === 0 ? (
          <div className="text-center py-16 text-xs text-zinc-400">
            Tidak ada transaksi pada rentang tanggal yang dipilih
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead className="bg-zinc-50 border-b border-zinc-100">
                <tr>
                  <th className="text-left px-6 py-3.5 font-bold text-zinc-500 uppercase tracking-wider">No. Order</th>
                  <th className="text-left px-6 py-3.5 font-bold text-zinc-500 uppercase tracking-wider">Waktu Transaksi</th>
                  <th className="text-left px-6 py-3.5 font-bold text-zinc-500 uppercase tracking-wider">Mitra Gerobak</th>
                  <th className="text-left px-6 py-3.5 font-bold text-zinc-500 uppercase tracking-wider">Metode</th>
                  <th className="text-right px-6 py-3.5 font-bold text-zinc-500 uppercase tracking-wider">Total Nilai</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-100">
                {orders.map(order => {
                  const driverName = Array.isArray(order.driver)
                    ? order.driver[0]?.full_name || 'Mitra'
                    : (order.driver as unknown as { full_name: string } | null)?.full_name || 'Mitra'

                  return (
                    <tr key={order.id} className="hover:bg-zinc-50/60 transition-colors">
                      <td className="px-6 py-3.5 font-bold font-mono text-zinc-900">{order.order_number}</td>
                      <td className="px-6 py-3.5 text-zinc-500">
                        {formatDate(order.created_at)}
                        <span className="text-[10px] text-zinc-400 block">{formatTime(order.created_at)} WIB</span>
                      </td>
                      <td className="px-6 py-3.5 font-medium text-zinc-800">{driverName}</td>
                      <td className="px-6 py-3.5">
                        <span className="uppercase font-bold text-[10px] bg-zinc-100 px-2 py-0.5 rounded text-zinc-600">
                          {order.payment_method}
                        </span>
                      </td>
                      <td className="px-6 py-3.5 text-right font-black text-zinc-900">{formatRupiah(order.total_amount)}</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}
