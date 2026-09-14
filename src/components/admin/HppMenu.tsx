'use client'

/**
 * HPP per menu, dihitung dari takaran dikali harga bahan.
 *
 * Satu aturan menjaga seluruh panel ini: bahan yang belum punya harga
 * membuat HPP menu itu KOSONG, bukan nol. Kalau ketiadaan harga dibaca
 * sebagai nol, menu yang datanya paling tidak lengkap justru tampil
 * paling untung — pola yang sama persis dengan dasbor yang dulu
 * menampilkan "0 cup" padahal driver sudah jualan.
 *
 * Urutannya margin tertipis di atas, bukan menu terlaris. Yang perlu
 * dilihat lebih dulu adalah yang paling dekat rugi.
 */

import { Fragment, useCallback, useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { describeRpcError } from '@/lib/rpc'
import { Calculator, Loader2, ChevronDown, ChevronRight, TriangleAlert } from 'lucide-react'

interface HppRow {
  product_id: string
  nama: string
  harga_jual: number
  hpp: number | null
  margin: number | null
  margin_persen: number | null
  versi_takaran: string | null
  bahan_dipakai: number
  bahan_tanpa_harga: string[] | null
  lengkap: boolean
}

interface RincianRow {
  bahan_id: string
  nama: string
  satuan: string
  jumlah: number
  harga: number | null
  biaya: number | null
  porsi: number | null
}

type Dasar = 'terakhir' | 'rata'

function num(v: unknown): number {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

export default function HppMenu() {
  const [supabase] = useState(() => createClient())
  const [rows, setRows] = useState<HppRow[]>([])
  const [dasar, setDasar] = useState<Dasar>('terakhir')
  const [buka, setBuka] = useState<string | null>(null)
  const [rincian, setRincian] = useState<RincianRow[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const muat = useCallback(async () => {
    const { data, error: err } = await supabase.rpc('admin_hpp_menu', { p_dasar: dasar })
    if (err) {
      setError(describeRpcError(err, 'admin_hpp_menu'))
      setRows([])
    } else {
      setError(null)
      const list = (data ?? []) as HppRow[]
      // Margin tertipis di atas; yang belum bisa dihitung ditaruh terakhir
      // supaya tidak menyamar sebagai menu paling tipis.
      list.sort((a, b) => {
        if (a.margin == null && b.margin == null) return 0
        if (a.margin == null) return 1
        if (b.margin == null) return -1
        return num(a.margin) - num(b.margin)
      })
      setRows(list)
    }
    setLoading(false)
  }, [supabase, dasar])

  useEffect(() => { muat() }, [muat])

  async function bukaRincian(id: string) {
    if (buka === id) { setBuka(null); return }
    setBuka(id)
    setRincian([])
    const { data } = await supabase.rpc('admin_hpp_rincian', {
      p_product_id: id, p_dasar: dasar,
    })
    setRincian((data ?? []) as RincianRow[])
  }

  if (loading) return null

  if (error) {
    return (
      <div className="flex items-start gap-3 p-3.5 bg-amber-50 border border-amber-300 rounded-2xl">
        <TriangleAlert className="w-5 h-5 text-amber-600 shrink-0 mt-px" />
        <p className="text-xs text-amber-900 leading-relaxed">{error}</p>
      </div>
    )
  }
  if (rows.length === 0) return null

  const belumLengkap = rows.filter(r => !r.lengkap).length

  return (
    <section className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
      <div className="px-5 py-3.5 border-b border-zinc-100 flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Calculator strokeWidth={2} className="w-4 h-4 text-brand" />
          <h2 className="text-sm font-bold text-zinc-900">HPP &amp; Margin per Menu</h2>
        </div>
        <div className="flex items-center gap-1 bg-zinc-100 rounded-lg p-0.5">
          {(['terakhir', 'rata'] as Dasar[]).map(d => (
            <button
              key={d}
              type="button"
              onClick={() => setDasar(d)}
              className={`px-2.5 py-1 rounded-md text-[11px] font-bold transition-colors ${
                dasar === d ? 'bg-white text-zinc-900 shadow-sm' : 'text-zinc-500 hover:text-zinc-700'
              }`}
            >
              {d === 'terakhir' ? 'Harga terakhir' : 'Rata 30 hari'}
            </button>
          ))}
        </div>
      </div>

      <div className="overflow-x-auto">
        <table className="w-full text-sm min-w-[520px]">
          <thead>
            <tr className="border-b border-zinc-100">
              <th className="text-left px-5 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Menu</th>
              <th className="text-right px-3 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Jual</th>
              <th className="text-right px-3 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">HPP</th>
              <th className="text-right px-3 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Margin</th>
              <th className="text-right px-5 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">%</th>
            </tr>
          </thead>
          <tbody>
            {rows.map(r => (
              <Fragment key={r.product_id}>
                <tr
                  onClick={() => r.lengkap && bukaRincian(r.product_id)}
                  className={`border-b border-zinc-50 last:border-0 ${
                    r.lengkap ? 'cursor-pointer hover:bg-zinc-50/70' : ''}`}
                >
                  <td className="px-5 py-2.5">
                    <span className="inline-flex items-center gap-1.5">
                      {r.lengkap && (buka === r.product_id
                        ? <ChevronDown strokeWidth={2.5} className="w-3.5 h-3.5 text-zinc-400" />
                        : <ChevronRight strokeWidth={2.5} className="w-3.5 h-3.5 text-zinc-300" />)}
                      <span className="font-semibold text-zinc-900">{r.nama}</span>
                    </span>
                    {!r.lengkap && (
                      <span className="block text-[10px] text-amber-700 font-semibold mt-0.5 pl-5">
                        {r.bahan_dipakai === 0
                          ? 'Belum ada takarannya'
                          : `Belum ada harga: ${(r.bahan_tanpa_harga ?? []).join(', ')}`}
                      </span>
                    )}
                  </td>
                  <td className="text-right px-3 py-2.5 tabular-nums text-zinc-600">
                    {formatRupiah(r.harga_jual)}
                  </td>
                  <td className="text-right px-3 py-2.5 tabular-nums text-zinc-600">
                    {r.hpp != null ? formatRupiah(Math.round(num(r.hpp))) : '—'}
                  </td>
                  <td className="text-right px-3 py-2.5 tabular-nums font-bold text-zinc-900">
                    {r.margin != null ? formatRupiah(Math.round(num(r.margin))) : '—'}
                  </td>
                  <td className={`text-right px-5 py-2.5 tabular-nums font-semibold ${
                    r.margin_persen == null ? 'text-zinc-400'
                      : num(r.margin_persen) < 30 ? 'text-brand' : 'text-zinc-600'}`}>
                    {r.margin_persen != null ? `${num(r.margin_persen).toFixed(0)}%` : '—'}
                  </td>
                </tr>

                {buka === r.product_id && (
                  <tr>
                    <td colSpan={5} className="px-5 py-0 bg-zinc-50/70">
                      <div className="py-3">
                        <p className="text-[10px] font-mono uppercase tracking-wider text-zinc-400 mb-2">
                          Rincian per cup
                        </p>
                        {rincian.length === 0 ? (
                          <Loader2 className="w-4 h-4 animate-spin text-zinc-400" />
                        ) : (
                          <div className="flex flex-col gap-1">
                            {rincian.map(b => (
                              <div key={b.bahan_id} className="flex items-center gap-3 text-[12px]">
                                <span className="w-28 shrink-0 font-semibold text-zinc-700">{b.nama}</span>
                                <span className="w-20 shrink-0 tabular-nums text-zinc-500">
                                  {num(b.jumlah).toLocaleString('id-ID')} {b.satuan}
                                </span>
                                {/* Batang porsi: yang paling menentukan biaya
                                    kelihatan tanpa harus membandingkan angka. */}
                                <span className="flex-1 h-1.5 bg-zinc-200 rounded-full overflow-hidden min-w-[40px]">
                                  <span
                                    className="block h-full bg-brand rounded-full"
                                    style={{ width: `${Math.max(num(b.porsi), 1)}%` }}
                                  />
                                </span>
                                <span className="w-16 shrink-0 text-right tabular-nums font-semibold text-zinc-900">
                                  {b.biaya != null ? formatRupiah(Math.round(num(b.biaya))) : '—'}
                                </span>
                                <span className="w-10 shrink-0 text-right tabular-nums text-zinc-400">
                                  {b.porsi != null ? `${num(b.porsi).toFixed(0)}%` : ''}
                                </span>
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
          </tbody>
        </table>
      </div>

      <div className="px-5 py-3.5 border-t border-zinc-100">
        {belumLengkap > 0 ? (
          <p className="text-[11px] text-amber-800 leading-relaxed">
            <b>{belumLengkap} menu belum bisa dihitung.</b> Bahan yang belum punya harga membuat
            HPP menu itu kosong, bukan nol — kalau dibaca nol, menu yang datanya paling tidak
            lengkap justru tampil paling untung. Catat notanya, angkanya muncul sendiri.
          </p>
        ) : (
          <p className="text-[11px] text-zinc-500 leading-relaxed">
            Diurutkan margin tertipis di atas — yang perlu dilihat lebih dulu adalah yang paling
            dekat rugi, bukan yang paling laku. <b className="text-zinc-900">Harga terakhir</b> untuk
            memutuskan harga jual, <b className="text-zinc-900">rata 30 hari</b> untuk melihat bulan
            yang sudah lewat. Ketuk satu baris untuk melihat bahan mana yang paling menentukan.
          </p>
        )}
      </div>
    </section>
  )
}
