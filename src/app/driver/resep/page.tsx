'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { formatRupiah } from '@/lib/format'
import { BookOpen, Loader2, AlertCircle, ChevronDown } from 'lucide-react'
import { describeRpcError } from '@/lib/rpc'

/** Satu baris mentah dari driver_resep(): satu bahan pada satu menu. */
interface BarisResep {
  product_id: string
  menu: string
  harga: number
  berlaku_dari: string
  bahan: string
  satuan: string
  jumlah: number
}

interface Resep {
  product_id: string
  menu: string
  harga: number
  berlaku_dari: string
  bahan: { nama: string; satuan: string; jumlah: number }[]
}

/**
 * Nama menu tersimpan sebagai "KPK - Kacang Pisang Kokoa". Bagian sebelum
 * tanda hubung dipakai sebagai judul besar, sisanya sebagai keterangan.
 * Nama tanpa tanda hubung tetap tampil utuh, bukan jadi kosong.
 */
function pecahNama(nama: string): { kode: string; panjang: string | null } {
  const potong = nama.indexOf(' - ')
  if (potong < 0) return { kode: nama.trim(), panjang: null }
  return {
    kode: nama.slice(0, potong).trim(),
    panjang: nama.slice(potong + 3).trim() || null,
  }
}

/** 135 bukan "135.00", tetapi 0,5 tetap "0,5". */
function angka(n: number): string {
  return Number.isInteger(n) ? String(n) : n.toFixed(1).replace('.', ',')
}

export default function ResepPage() {
  const { user } = useAuth()
  const [resep, setResep] = useState<Resep[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [dibuka, setDibuka] = useState<string | null>(null)
  const supabase = createClient()

  useEffect(() => {
    if (user) muat()
  }, [user]) // eslint-disable-line react-hooks/exhaustive-deps

  async function muat() {
    setLoading(true)
    setError(null)

    const { data, error: err } = await supabase.rpc('driver_resep')

    if (err) {
      // Gagal dibiarkan terlihat. Daftar kosong yang diam akan terbaca
      // sebagai "memang belum ada resepnya", padahal pertanyaannya tidak
      // pernah terjawab.
      setError(describeRpcError(err, 'driver_resep'))
      setResep([])
      setLoading(false)
      return
    }

    const baris = (data ?? []) as BarisResep[]
    const peta = new Map<string, Resep>()

    for (const b of baris) {
      let r = peta.get(b.product_id)
      if (!r) {
        r = {
          product_id: b.product_id,
          menu: b.menu,
          harga: b.harga,
          berlaku_dari: b.berlaku_dari,
          bahan: [],
        }
        peta.set(b.product_id, r)
      }
      // Urutan dari server dipertahankan: bahan terbanyak di atas,
      // kemasan yang selalu satuan jatuh ke bawah dengan sendirinya.
      r.bahan.push({ nama: b.bahan, satuan: b.satuan, jumlah: Number(b.jumlah) })
    }

    const daftar = Array.from(peta.values())
    setResep(daftar)
    // Menu pertama langsung terbuka supaya layar tidak menyambut dengan
    // daftar tertutup yang belum memberi apa-apa.
    setDibuka((sebelumnya) => sebelumnya ?? daftar[0]?.product_id ?? null)
    setLoading(false)
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center py-24">
        <Loader2 className="w-6 h-6 animate-spin text-zinc-300" />
      </div>
    )
  }

  return (
    <div className="px-4 py-5 space-y-4">
      <div className="flex items-start gap-3">
        <div className="w-9 h-9 rounded-xl bg-brand/10 flex items-center justify-center shrink-0">
          <BookOpen strokeWidth={1.75} className="w-4.5 h-4.5 text-brand" />
        </div>
        <div className="min-w-0">
          <h1 className="text-lg font-bold tracking-tight leading-tight">Resep</h1>
          <p className="text-xs text-zinc-500 leading-snug mt-0.5">
            Takaran per satu cup. Kalau yang dituang berbeda dari daftar ini,
            kasih tahu admin — jangan diam-diam disesuaikan.
          </p>
        </div>
      </div>

      {error && (
        <div className="flex items-start gap-2.5 bg-red-50 border border-red-200 rounded-xl px-3.5 py-3">
          <AlertCircle strokeWidth={1.75} className="w-4 h-4 text-red-500 shrink-0 mt-0.5" />
          <p className="text-xs text-red-700 leading-relaxed">{error}</p>
        </div>
      )}

      {!error && resep.length === 0 && (
        <div className="text-center py-16 px-6">
          <p className="text-sm text-zinc-500">Belum ada resep yang tercatat.</p>
          <p className="text-xs text-zinc-400 mt-1.5 leading-relaxed">
            Admin mengisinya dari menu Bahan.
          </p>
        </div>
      )}

      <div className="space-y-2.5">
        {resep.map((r) => {
          const { kode, panjang } = pecahNama(r.menu)
          const terbuka = dibuka === r.product_id

          return (
            <div
              key={r.product_id}
              className="bg-white border border-zinc-200/80 rounded-2xl overflow-hidden"
            >
              <button
                onClick={() => setDibuka(terbuka ? null : r.product_id)}
                className="w-full flex items-center gap-3 px-4 py-3.5 text-left hover:bg-zinc-50/80 transition-colors"
              >
                <div className="min-w-0 flex-1">
                  <div className="flex items-baseline gap-2">
                    <span className="font-bold tracking-tight">{kode}</span>
                    <span className="text-xs font-medium text-zinc-400 tabular-nums">
                      {formatRupiah(r.harga)}
                    </span>
                  </div>
                  {panjang && (
                    <p className="text-xs text-zinc-500 truncate mt-0.5">{panjang}</p>
                  )}
                </div>
                <ChevronDown
                  strokeWidth={2}
                  className={`w-4 h-4 text-zinc-300 shrink-0 transition-transform duration-200 ${
                    terbuka ? 'rotate-180' : ''
                  }`}
                />
              </button>

              {terbuka && (
                <div className="px-4 pb-4 pt-0.5 border-t border-zinc-100">
                  <ul className="divide-y divide-zinc-100">
                    {r.bahan.map((b) => (
                      <li
                        key={b.nama}
                        className="flex items-baseline justify-between gap-4 py-2"
                      >
                        <span className="text-sm text-zinc-700">{b.nama}</span>
                        <span className="text-sm font-semibold tabular-nums whitespace-nowrap">
                          {angka(b.jumlah)}
                          <span className="text-zinc-400 font-medium ml-1">{b.satuan}</span>
                        </span>
                      </li>
                    ))}
                  </ul>
                </div>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
