'use client'

/**
 * Perbaiki atau batalkan pesanan yang salah ketik.
 *
 * Kebutuhannya datang dari lapangan: Minggu 13 Sep 2026, 33 cup tercatat
 * dalam rentang satu menit saat event kampus. Mengetik secepat itu sambil
 * melayani antrean membuat salah ketik jadi kepastian, bukan kemungkinan —
 * dan sampai sekarang salah ketik itu menetap selamanya.
 *
 * Dua hal sengaja tidak dibuat mudah:
 *
 *   1. Membatalkan meminta alasan. Satu ketukan, bukan mengetik, jadi
 *      tidak melambatkan — tetapi memaksa pembatalannya punya sebab yang
 *      tercatat.
 *   2. Menyimpan meminta konfirmasi bila jumlahnya berubah banyak. Yang
 *      dijaga bukan kesalahan driver, melainkan jarinya sendiri: papan
 *      angka di ponsel mudah tergeser saat gerobak ramai.
 *
 * Pemeriksaan sebenarnya ada di server — milik siapa pesanannya, hari
 * ini atau bukan, sudah direkonsiliasi atau belum, dan cukup tidaknya
 * muatan gerobak. Layar ini hanya membuatnya enak dipakai.
 */

import { useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { Loader2, Minus, Plus, TriangleAlert, X, Check } from 'lucide-react'
import type { Product } from '@/types/database'

export interface BarisEdit {
  product_id: string
  quantity: number
}

interface EditPesananProps {
  orderId: string
  awal: BarisEdit[]
  produk: Product[]
  onSelesai: () => void
  onBatalEdit: () => void
}

const ALASAN_BATAL = ['Dobel input', 'Pesanan batal', 'Salah menu'] as const

/** Pesan server diterjemahkan ke kalimat yang bisa ditindaklanjuti driver. */
function pesanGalat(raw: string): string {
  if (raw.startsWith('INSUFFICIENT_STOCK:')) {
    return `Muatan ${raw.split(':')[1]} tidak cukup untuk jumlah itu.`
  }
  switch (raw) {
    case 'ORDER_NOT_TODAY':
      return 'Pesanan hari sebelumnya tidak bisa diubah. Hubungi admin.'
    case 'DAY_RECONCILED':
      return 'Hari ini sudah dikunci admin. Minta admin membuka kuncinya dulu.'
    case 'FORBIDDEN':
      return 'Pesanan ini bukan milik akun ini.'
    case 'ORDER_NOT_FOUND':
      return 'Pesanan sudah tidak ada — mungkin baru saja dibatalkan.'
    case 'PRODUCT_UNAVAILABLE':
      return 'Ada menu yang sedang tidak tersedia.'
    case 'ITEMS_EMPTY':
      return 'Pesanan tidak boleh kosong. Pakai tombol Batalkan.'
    case 'INVALID_QUANTITY':
      return 'Jumlah harus lebih dari nol.'
    default:
      return raw
  }
}

export default function EditPesanan({
  orderId, awal, produk, onSelesai, onBatalEdit,
}: EditPesananProps) {
  const [baris, setBaris] = useState<Record<string, number>>(() => {
    const awalnya: Record<string, number> = {}
    for (const b of awal) awalnya[b.product_id] = b.quantity
    return awalnya
  })
  const [sibuk, setSibuk] = useState(false)
  const [galat, setGalat] = useState<string | null>(null)
  const [modeBatal, setModeBatal] = useState(false)
  const [supabase] = useState(() => createClient())

  const totalAwal = awal.reduce((n, b) => n + b.quantity, 0)
  const totalBaru = Object.values(baris).reduce((n, q) => n + q, 0)

  const rupiah = Object.entries(baris).reduce((n, [id, q]) => {
    const p = produk.find(x => x.id === id)
    return n + (p ? p.price * q : 0)
  }, 0)

  function ubah(productId: string, delta: number) {
    setGalat(null)
    setBaris(prev => {
      const next = { ...prev }
      const q = (next[productId] ?? 0) + delta
      if (q <= 0) delete next[productId]
      else next[productId] = q
      return next
    })
  }

  async function simpan() {
    if (totalBaru === 0) {
      setGalat('Pesanan tidak boleh kosong. Pakai tombol Batalkan.')
      return
    }
    // Perubahan besar hampir selalu jari yang tergeser, bukan maksud.
    if (Math.abs(totalBaru - totalAwal) >= 5 &&
        !window.confirm(`Ubah dari ${totalAwal} cup jadi ${totalBaru} cup?`)) {
      return
    }

    setSibuk(true)
    setGalat(null)
    const { error } = await supabase.rpc('driver_edit_order', {
      p_order_id: orderId,
      p_items: Object.entries(baris).map(([product_id, quantity]) => ({ product_id, quantity })),
    })
    setSibuk(false)

    if (error) setGalat(pesanGalat(error.message))
    else onSelesai()
  }

  async function batalkan(alasan: string) {
    setSibuk(true)
    setGalat(null)
    const { error } = await supabase.rpc('driver_batal_order', {
      p_order_id: orderId,
      p_alasan: alasan,
    })
    setSibuk(false)

    if (error) setGalat(pesanGalat(error.message))
    else onSelesai()
  }

  if (modeBatal) {
    return (
      <div className="border-t border-zinc-100 p-4 bg-amber-50/60 space-y-3">
        <p className="text-xs font-bold text-zinc-900">
          Batalkan pesanan ini? Kenapa?
        </p>
        <p className="text-[11px] text-zinc-500 leading-relaxed">
          Cup-nya kembali ke muatan gerobak. Pembatalan tercatat, jadi angka
          setoran tetap cocok.
        </p>
        <div className="grid grid-cols-1 gap-2">
          {ALASAN_BATAL.map(a => (
            <button
              key={a}
              type="button"
              disabled={sibuk}
              onClick={() => batalkan(a)}
              className="w-full py-2.5 px-3 rounded-lg bg-white border border-zinc-200 text-xs font-bold text-zinc-800 hover:border-brand hover:text-brand transition-colors disabled:opacity-50 text-left"
            >
              {a}
            </button>
          ))}
        </div>
        {galat && (
          <p className="flex items-start gap-2 text-[11px] text-amber-700 leading-relaxed">
            <TriangleAlert strokeWidth={2} className="w-3.5 h-3.5 shrink-0 mt-px" />
            {galat}
          </p>
        )}
        <button
          type="button"
          onClick={() => { setModeBatal(false); setGalat(null) }}
          disabled={sibuk}
          className="text-[11px] font-semibold text-zinc-400 hover:text-zinc-700 transition-colors"
        >
          Jangan jadi
        </button>
      </div>
    )
  }

  return (
    <div className="border-t border-zinc-100 p-4 bg-zinc-50/80 space-y-3">
      <div className="flex items-baseline justify-between">
        <span className="text-[10px] font-bold text-zinc-400 uppercase tracking-wider">
          Perbaiki jumlah
        </span>
        <span className="text-[11px] font-bold text-zinc-900 tabular-nums">
          {totalBaru} cup · {formatRupiah(rupiah)}
        </span>
      </div>

      <div className="space-y-1.5">
        {produk.map(p => {
          const q = baris[p.id] ?? 0
          return (
            <div
              key={p.id}
              className={`flex items-center gap-2 rounded-lg px-2.5 py-2 ${
                q > 0 ? 'bg-white border border-zinc-200' : 'bg-transparent'
              }`}
            >
              <span className={`flex-1 min-w-0 truncate text-xs ${
                q > 0 ? 'font-bold text-zinc-900' : 'text-zinc-500'
              }`}>
                {p.name}
              </span>
              <button
                type="button"
                aria-label={`Kurangi ${p.name}`}
                disabled={sibuk || q === 0}
                onClick={() => ubah(p.id, -1)}
                className="w-8 h-8 shrink-0 rounded-lg bg-white border border-zinc-200 flex items-center justify-center text-zinc-600 disabled:opacity-30 active:scale-95 transition-transform"
              >
                <Minus strokeWidth={3} className="w-3.5 h-3.5" />
              </button>
              <span className="w-6 text-center text-xs font-bold text-zinc-900 tabular-nums">
                {q}
              </span>
              <button
                type="button"
                aria-label={`Tambah ${p.name}`}
                disabled={sibuk}
                onClick={() => ubah(p.id, 1)}
                className="w-8 h-8 shrink-0 rounded-lg bg-brand text-white flex items-center justify-center disabled:opacity-40 active:scale-95 transition-transform"
              >
                <Plus strokeWidth={3} className="w-3.5 h-3.5" />
              </button>
            </div>
          )
        })}
      </div>

      {galat && (
        <p className="flex items-start gap-2 text-[11px] text-amber-700 leading-relaxed">
          <TriangleAlert strokeWidth={2} className="w-3.5 h-3.5 shrink-0 mt-px" />
          {galat}
        </p>
      )}

      <div className="flex items-center gap-2 pt-1">
        <button
          type="button"
          onClick={simpan}
          disabled={sibuk}
          className="flex-1 py-2.5 rounded-lg bg-brand text-white text-xs font-bold flex items-center justify-center gap-1.5 hover:bg-brand-dark disabled:opacity-50 transition-colors"
        >
          {sibuk ? <Loader2 className="w-4 h-4 animate-spin" />
                 : <><Check strokeWidth={3} className="w-3.5 h-3.5" /> Simpan</>}
        </button>
        <button
          type="button"
          onClick={onBatalEdit}
          disabled={sibuk}
          className="px-3 py-2.5 rounded-lg bg-white border border-zinc-200 text-xs font-bold text-zinc-600 disabled:opacity-50"
        >
          <X strokeWidth={3} className="w-3.5 h-3.5" />
        </button>
      </div>

      <button
        type="button"
        onClick={() => { setModeBatal(true); setGalat(null) }}
        disabled={sibuk}
        className="text-[11px] font-semibold text-zinc-400 hover:text-brand transition-colors disabled:opacity-50"
      >
        Batalkan pesanan ini
      </button>
    </div>
  )
}
