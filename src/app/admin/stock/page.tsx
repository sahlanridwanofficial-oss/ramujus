'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import {
  Loader2, Boxes, Plus, ClipboardCheck, TriangleAlert, PackageX,
  Search, History, X, ArrowUp, ArrowDown,
} from 'lucide-react'
import type { StockOverviewRow, StockMovement } from '@/types/database'

type StatusFilter = 'all' | 'low' | 'out'

const STATUS_BADGE: Record<StockOverviewRow['status'], { label: string; cls: string }> = {
  ok: { label: 'Aman', cls: 'text-emerald-700 bg-emerald-50 border-emerald-200' },
  low: { label: 'Menipis', cls: 'text-amber-700 bg-amber-50 border-amber-200' },
  out: { label: 'Habis', cls: 'text-[#be1a1a] bg-red-50 border-red-200' },
}

const REASON_LABEL: Record<StockMovement['reason'], string> = {
  restock: 'Stok masuk',
  opname: 'Opname',
  allocation: 'Muat gerobak',
  allocation_return: 'Kembali dari gerobak',
  adjustment: 'Koreksi',
}

export default function StockPage() {
  const [rows, setRows] = useState<StockOverviewRow[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<StatusFilter>('all')

  // Panel aksi (restock / opname) untuk satu produk
  const [active, setActive] = useState<StockOverviewRow | null>(null)
  const [mode, setMode] = useState<'restock' | 'opname'>('restock')
  const [amount, setAmount] = useState('')
  const [note, setNote] = useState('')
  const [saving, setSaving] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)

  // Riwayat pergerakan
  const [historyFor, setHistoryFor] = useState<StockOverviewRow | null>(null)
  const [history, setHistory] = useState<StockMovement[]>([])
  const [historyLoading, setHistoryLoading] = useState(false)

  const [supabase] = useState(() => createClient())

  const load = useCallback(async () => {
    const { data, error: rpcError } = await supabase.rpc('admin_stock_overview')
    if (rpcError) {
      setError('Gagal memuat data stok. Coba muat ulang.')
    } else {
      setRows((data ?? []) as StockOverviewRow[])
      setError(null)
    }
    setLoading(false)
  }, [supabase])

  useEffect(() => { void load() }, [load])

  const counts = useMemo(() => ({
    out: rows.filter(r => r.status === 'out').length,
    low: rows.filter(r => r.status === 'low').length,
    totalCups: rows.reduce((s, r) => s + r.stock_quantity, 0),
  }), [rows])

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase()
    return rows
      .filter(r => (filter === 'all' ? true : r.status === filter))
      .filter(r => (q ? r.name.toLowerCase().includes(q) : true))
  }, [rows, query, filter])

  function openAction(row: StockOverviewRow, m: 'restock' | 'opname') {
    setActive(row)
    setMode(m)
    setAmount(m === 'opname' ? String(row.stock_quantity) : '')
    setNote('')
    setActionError(null)
  }

  async function submitAction() {
    if (!active) return
    const n = parseInt(amount, 10)
    if (isNaN(n) || (mode === 'restock' && n <= 0) || (mode === 'opname' && n < 0)) {
      setActionError('Masukkan jumlah yang benar.')
      return
    }
    setSaving(true)
    setActionError(null)

    const { error: rpcError } = mode === 'restock'
      ? await supabase.rpc('adjust_product_stock', {
          p_product_id: active.product_id, p_delta: n, p_reason: 'restock', p_note: note || null,
        })
      : await supabase.rpc('set_product_stock', {
          p_product_id: active.product_id, p_new_qty: n, p_note: note || null,
        })

    setSaving(false)
    if (rpcError) {
      setActionError('Gagal menyimpan. Coba lagi.')
      return
    }
    setActive(null)
    await load()
  }

  async function openHistory(row: StockOverviewRow) {
    setHistoryFor(row)
    setHistoryLoading(true)
    const { data } = await supabase
      .from('stock_movements')
      .select('*')
      .eq('product_id', row.product_id)
      .order('created_at', { ascending: false })
      .limit(30)
    setHistory((data ?? []) as StockMovement[])
    setHistoryLoading(false)
  }

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-72 gap-2 text-zinc-400">
        <Loader2 className="w-7 h-7 animate-spin text-brand" />
        <span className="text-xs">Memuat data inventori...</span>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-black text-zinc-900 tracking-tight">Inventori Stok Produk</h1>
          <p className="text-xs text-zinc-500 mt-0.5">
            Stok cup tersegel per produk di base. Muat gerobak otomatis mengurangi stok ini.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {counts.out > 0 && (
            <span className="inline-flex items-center gap-1.5 bg-red-50 border border-red-200 px-3 py-1.5 rounded-full text-xs font-bold text-[#be1a1a]">
              <PackageX className="w-3.5 h-3.5" />{counts.out} habis
            </span>
          )}
          {counts.low > 0 && (
            <span className="inline-flex items-center gap-1.5 bg-amber-50 border border-amber-200 px-3 py-1.5 rounded-full text-xs font-bold text-amber-700">
              <TriangleAlert className="w-3.5 h-3.5" />{counts.low} menipis
            </span>
          )}
          <span className="inline-flex items-center gap-1.5 bg-white border border-zinc-200/80 px-3 py-1.5 rounded-full text-xs font-semibold text-zinc-600">
            <Boxes className="w-3.5 h-3.5 text-zinc-400" />{counts.totalCups.toLocaleString('id-ID')} cup total
          </span>
        </div>
      </div>

      {error && (
        <div role="alert" className="p-3 bg-red-50 border border-red-300 rounded-xl flex items-center gap-2 text-xs text-[#be1a1a] font-semibold">
          <TriangleAlert className="w-4 h-4 shrink-0" />{error}
        </div>
      )}

      {/* Filter & cari */}
      <div className="flex flex-col sm:flex-row gap-2">
        <div className="relative flex-1">
          <Search className="w-3.5 h-3.5 text-zinc-400 absolute left-3 top-1/2 -translate-y-1/2" />
          <input
            value={query}
            onChange={e => setQuery(e.target.value)}
            placeholder="Cari produk..."
            className="w-full bg-white border border-zinc-200 rounded-xl pl-9 pr-3 py-2.5 text-xs focus:outline-none focus:border-brand"
          />
        </div>
        <div className="flex bg-white border border-zinc-200/80 rounded-xl p-1">
          {(['all', 'low', 'out'] as const).map(f => (
            <button
              key={f}
              onClick={() => setFilter(f)}
              className={`px-3 py-1.5 rounded-lg text-xs font-bold transition-all ${
                filter === f ? 'bg-zinc-900 text-white' : 'text-zinc-500 hover:text-zinc-900'
              }`}
            >
              {f === 'all' ? 'Semua' : f === 'low' ? 'Menipis' : 'Habis'}
            </button>
          ))}
        </div>
      </div>

      {/* Daftar produk */}
      <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
        {visible.length === 0 && (
          <p className="col-span-full text-center text-xs text-zinc-400 py-8">Tidak ada produk yang cocok.</p>
        )}
        {visible.map(row => {
          const badge = STATUS_BADGE[row.status]
          return (
            <div key={row.product_id} className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-card">
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <h3 className="font-bold text-zinc-900 text-sm truncate">{row.name}</h3>
                  <p className="text-[11px] text-zinc-400 mt-0.5">
                    {formatRupiah(row.price)} · {row.category}
                    {!row.is_available && <span className="text-amber-600 font-semibold"> · nonaktif</span>}
                  </p>
                </div>
                <span className={`text-[10px] font-bold px-2 py-0.5 rounded-full border shrink-0 ${badge.cls}`}>
                  {badge.label}
                </span>
              </div>

              <div className="flex items-end justify-between mt-3">
                <div>
                  <span className="text-[10px] text-zinc-400 uppercase font-bold tracking-wider block">Stok saat ini</span>
                  <span className="text-2xl font-black text-zinc-900 tracking-tight">{row.stock_quantity}</span>
                  <span className="text-xs text-zinc-500 font-medium"> cup</span>
                </div>
                <div className="text-right text-[11px] text-zinc-400">
                  <div>Dimuat hari ini: <span className="font-bold text-zinc-700">{row.allocated_today}</span></div>
                  {row.low_stock_threshold > 0 && (
                    <div>Batas menipis: {row.low_stock_threshold}</div>
                  )}
                </div>
              </div>

              <div className="flex items-center gap-1.5 mt-3 pt-3 border-t border-zinc-100">
                <button
                  onClick={() => openAction(row, 'restock')}
                  className="flex-1 inline-flex items-center justify-center gap-1.5 bg-brand hover:bg-brand-dark text-white py-2 rounded-lg text-xs font-bold transition-colors"
                >
                  <Plus className="w-3.5 h-3.5" />Tambah Stok
                </button>
                <button
                  onClick={() => openAction(row, 'opname')}
                  className="flex-1 inline-flex items-center justify-center gap-1.5 bg-zinc-50 hover:bg-zinc-100 border border-zinc-200 text-zinc-700 py-2 rounded-lg text-xs font-bold transition-colors"
                >
                  <ClipboardCheck className="w-3.5 h-3.5" />Opname
                </button>
                <button
                  onClick={() => openHistory(row)}
                  title="Riwayat pergerakan"
                  className="w-9 h-9 shrink-0 inline-flex items-center justify-center bg-zinc-50 hover:bg-zinc-100 border border-zinc-200 text-zinc-500 rounded-lg transition-colors"
                >
                  <History className="w-3.5 h-3.5" />
                </button>
              </div>
            </div>
          )
        })}
      </div>

      {/* Modal aksi */}
      {active && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-end sm:items-center justify-center p-4" onClick={() => setActive(null)}>
          <div className="bg-white rounded-2xl w-full max-w-sm p-5 shadow-lifted" onClick={e => e.stopPropagation()}>
            <div className="flex items-center justify-between mb-1">
              <h3 className="font-bold text-zinc-900 text-sm">
                {mode === 'restock' ? 'Tambah Stok' : 'Stock Opname'} — {active.name}
              </h3>
              <button onClick={() => setActive(null)} className="text-zinc-400 hover:text-zinc-600"><X className="w-4 h-4" /></button>
            </div>
            <p className="text-[11px] text-zinc-500 mb-3">
              {mode === 'restock'
                ? `Jumlah cup baru yang ditambahkan. Stok sekarang ${active.stock_quantity}.`
                : `Setel stok ke hasil hitung fisik. Stok tercatat sekarang ${active.stock_quantity}.`}
            </p>

            <label className="block text-[11px] font-bold text-zinc-500 uppercase tracking-wider mb-1">
              {mode === 'restock' ? 'Jumlah ditambahkan' : 'Stok fisik sebenarnya'}
            </label>
            <input
              type="number"
              min={mode === 'restock' ? 1 : 0}
              value={amount}
              onChange={e => setAmount(e.target.value)}
              autoFocus
              className="w-full px-3.5 py-2.5 bg-zinc-50 border border-zinc-200 rounded-xl text-sm font-bold focus:outline-none focus:border-brand"
            />

            <label className="block text-[11px] font-bold text-zinc-500 uppercase tracking-wider mb-1 mt-3">Catatan (opsional)</label>
            <input
              value={note}
              onChange={e => setNote(e.target.value)}
              placeholder={mode === 'restock' ? 'Contoh: produksi pagi batch 1' : 'Contoh: koreksi hitung fisik'}
              className="w-full px-3.5 py-2.5 bg-zinc-50 border border-zinc-200 rounded-xl text-xs focus:outline-none focus:border-brand"
            />

            {mode === 'opname' && amount !== '' && !isNaN(parseInt(amount, 10)) && (
              <p className="text-[11px] text-zinc-500 mt-2">
                Selisih: <span className={`font-bold ${parseInt(amount, 10) - active.stock_quantity < 0 ? 'text-[#be1a1a]' : 'text-emerald-700'}`}>
                  {parseInt(amount, 10) - active.stock_quantity > 0 ? '+' : ''}{parseInt(amount, 10) - active.stock_quantity} cup
                </span>
              </p>
            )}

            {actionError && <p className="text-[11px] text-[#be1a1a] font-semibold mt-2">{actionError}</p>}

            <button
              onClick={submitAction}
              disabled={saving}
              className="w-full mt-4 bg-brand hover:bg-brand-dark text-white py-2.5 rounded-xl text-xs font-bold transition-colors disabled:opacity-50 inline-flex items-center justify-center gap-2"
            >
              {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : null}
              Simpan
            </button>
          </div>
        </div>
      )}

      {/* Modal riwayat */}
      {historyFor && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-end sm:items-center justify-center p-4" onClick={() => setHistoryFor(null)}>
          <div className="bg-white rounded-2xl w-full max-w-md p-5 shadow-lifted max-h-[70vh] flex flex-col" onClick={e => e.stopPropagation()}>
            <div className="flex items-center justify-between mb-3">
              <h3 className="font-bold text-zinc-900 text-sm">Riwayat Stok — {historyFor.name}</h3>
              <button onClick={() => setHistoryFor(null)} className="text-zinc-400 hover:text-zinc-600"><X className="w-4 h-4" /></button>
            </div>
            {historyLoading ? (
              <div className="flex justify-center py-8"><Loader2 className="w-5 h-5 animate-spin text-brand" /></div>
            ) : history.length === 0 ? (
              <p className="text-xs text-zinc-400 text-center py-8">Belum ada pergerakan stok.</p>
            ) : (
              <div className="overflow-y-auto divide-y divide-zinc-100">
                {history.map(m => (
                  <div key={m.id} className="flex items-center justify-between py-2.5 gap-3">
                    <div className="min-w-0">
                      <div className="flex items-center gap-1.5">
                        {m.delta >= 0
                          ? <ArrowUp className="w-3 h-3 text-emerald-600 shrink-0" />
                          : <ArrowDown className="w-3 h-3 text-[#be1a1a] shrink-0" />}
                        <span className="text-xs font-semibold text-zinc-800">{REASON_LABEL[m.reason]}</span>
                      </div>
                      {m.note && <p className="text-[10px] text-zinc-400 truncate mt-0.5 pl-4">{m.note}</p>}
                      <p className="text-[10px] text-zinc-400 pl-4">
                        {new Date(m.created_at).toLocaleString('id-ID', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                      </p>
                    </div>
                    <div className="text-right shrink-0">
                      <span className={`text-sm font-black ${m.delta >= 0 ? 'text-emerald-700' : 'text-[#be1a1a]'}`}>
                        {m.delta > 0 ? '+' : ''}{m.delta}
                      </span>
                      <p className="text-[10px] text-zinc-400">sisa {m.balance_after}</p>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
