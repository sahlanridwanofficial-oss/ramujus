'use client'

/**
 * Hari jualan yang belum ditutup.
 *
 * Pagar di create_order (migrasi 0028) menahan kejadian baru: sejak itu
 * tidak ada lagi penjualan yang lolos tanpa meninggalkan baris alokasi.
 * Tapi pagar tidak menagih apa pun — ia diam, dan yang diam tidak pernah
 * dikerjakan. Pada 7–14 September 2026, empat dari delapan hari berakhir
 * tanpa setoran dicocokkan; Rp677.000 dari Rp1.644.000 tidak pernah diakui
 * masuk. Tidak satu pun layar memberi tahu.
 *
 * Panel ini yang membuat tagihan itu kelihatan, dan sengaja ditaruh di
 * dasbor — layar yang memang dibuka tiap hari — bukan di halaman laporan
 * yang harus dicari.
 *
 * Hari yang sedang berjalan tidak pernah masuk daftar. Hari yang belum
 * selesai memang belum ditutup, dan menagihnya membuat panel ini menyala
 * tiap hari lalu berhenti dibaca.
 */

import { useCallback, useEffect, useState } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { describeRpcError } from '@/lib/rpc'
import { CalendarX2, Loader2, ArrowUpRight, TriangleAlert, Check } from 'lucide-react'

interface HariRow {
  allocation_id: string
  hari: string
  driver_id: string
  driver_name: string
  cup: number
  omzet: number
  umur_hari: number
  muatan_dicatat: boolean
  cup_di_luar_muatan: number
}

function tanggalPendek(iso: string): string {
  // Tanggal dari Postgres sudah berupa tanggal WIB (date, tanpa zona). Diurai
  // sebagai angka, bukan lewat Date(), supaya tidak digeser zona peramban.
  const [y, m, d] = iso.split('-').map(Number)
  const bulan = ['Jan','Feb','Mar','Apr','Mei','Jun','Jul','Agu','Sep','Okt','Nov','Des']
  return `${d} ${bulan[m - 1]} ${y}`
}

function umurnya(hari: number): string {
  if (hari <= 1) return 'kemarin'
  return `${hari} hari lalu`
}

export default function HariPerluPerhatian() {
  const [rows, setRows] = useState<HariRow[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [supabase] = useState(() => createClient())

  const muat = useCallback(async () => {
    const { data, error: err } = await supabase.rpc('admin_hari_perlu_perhatian')
    if (err) {
      // Fungsi belum ada berarti 0028 belum dijalankan. Dikatakan, bukan
      // ditampilkan sebagai daftar kosong — daftar kosong di panel ini
      // terbaca sebagai "semua hari sudah ditutup", justru kebalikan dari
      // keadaan yang sebenarnya.
      setError(describeRpcError(err, 'admin_hari_perlu_perhatian'))
      setRows([])
    } else {
      setError(null)
      setRows((data ?? []) as HariRow[])
    }
    setLoading(false)
  }, [supabase])

  useEffect(() => { muat() }, [muat])

  async function akuiMuatan(row: HariRow) {
    const ok = window.confirm(
      `Akui ${row.cup_di_luar_muatan} cup sebagai muatan ${tanggalPendek(row.hari)}?\n\n` +
      'Cup yang terjual diakui sebagai cup yang dibawa, dan stok pusat ' +
      'dipotong sebesar itu. Ini yang dilakukan kalau muatan aslinya sudah ' +
      'tidak diingat — bukan tebakan, tapi batas bawah yang pasti.'
    )
    if (!ok) return

    setBusyId(row.allocation_id)
    const { error: err } = await supabase.rpc('admin_akui_muatan_dari_penjualan', {
      p_allocation_id: row.allocation_id,
    })
    if (err) setError(describeRpcError(err, 'admin_akui_muatan_dari_penjualan'))
    else await muat()
    setBusyId(null)
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

  // Tidak ada yang menggantung: panel menghilang sepenuhnya, bukan tampil
  // sebagai kartu hijau "semua beres". Layar yang memuji dirinya sendiri
  // tiap hari mengajari mata untuk melewatinya.
  if (rows.length === 0) return null

  const totalOmzet = rows.reduce((t, r) => t + Number(r.omzet ?? 0), 0)
  const totalCup = rows.reduce((t, r) => t + Number(r.cup ?? 0), 0)

  return (
    <section className="bg-white rounded-2xl border border-brand-border shadow-card overflow-hidden">
      <div className="px-5 py-3.5 bg-brand-soft border-b border-brand-border flex items-start gap-3">
        <CalendarX2 strokeWidth={2} className="w-5 h-5 text-brand shrink-0 mt-px" />
        <div className="flex-1 min-w-0">
          <h2 className="text-xs font-bold text-zinc-900">
            {rows.length} hari jualan belum ditutup
          </h2>
          <p className="text-[11px] text-zinc-600 mt-0.5">
            {totalCup} cup · <b className="text-brand">{formatRupiah(totalOmzet)}</b>{' '}
            belum pernah dicocokkan dengan setoran
          </p>
        </div>
      </div>

      <div className="divide-y divide-zinc-100">
        {rows.map(row => (
          <div key={row.allocation_id} className="px-5 py-3.5">
            <div className="flex items-start gap-3">
              <div className="flex-1 min-w-0">
                <p className="text-xs font-bold text-zinc-900">
                  {tanggalPendek(row.hari)}
                  <span className="font-medium text-zinc-400"> · {umurnya(row.umur_hari)}</span>
                </p>
                <p className="text-[11px] text-zinc-500 tabular-nums mt-0.5">
                  {row.driver_name} · {row.cup} cup · {formatRupiah(row.omzet)}
                </p>

                {!row.muatan_dicatat && (
                  <p className="text-[11px] text-brand font-semibold mt-1.5 leading-relaxed">
                    Muatan hari itu tidak pernah dicatat
                    {row.cup_di_luar_muatan > 0
                      && ` — ${row.cup_di_luar_muatan} cup terjual di luar muatan`}.
                    Hari ini tidak bisa ditutup sebelum muatannya diakui.
                  </p>
                )}
                {row.muatan_dicatat && row.cup_di_luar_muatan > 0 && (
                  <p className="text-[11px] text-amber-700 font-semibold mt-1.5 leading-relaxed">
                    {row.cup_di_luar_muatan} cup terjual melebihi muatan yang tercatat.
                  </p>
                )}
              </div>

              <Link
                href={`/admin/inventory?driverId=${row.driver_id}&date=${row.hari}&tab=night`}
                className="shrink-0 inline-flex items-center gap-1 px-3 py-2 rounded-lg text-[11px] font-bold bg-white text-brand border border-brand-border hover:bg-red-50 transition-colors"
              >
                Tutup hari
                <ArrowUpRight strokeWidth={2.5} className="w-3.5 h-3.5" />
              </Link>
            </div>

            {row.cup_di_luar_muatan > 0 && (
              <button
                type="button"
                onClick={() => akuiMuatan(row)}
                disabled={busyId === row.allocation_id}
                className="mt-2.5 inline-flex items-center gap-1.5 text-[11px] font-semibold text-zinc-500 hover:text-brand transition-colors disabled:opacity-60"
              >
                {busyId === row.allocation_id
                  ? <Loader2 className="w-3.5 h-3.5 animate-spin" />
                  : <Check strokeWidth={2.5} className="w-3.5 h-3.5" />}
                Akui {row.cup_di_luar_muatan} cup itu sebagai muatan
              </button>
            )}
          </div>
        ))}
      </div>

      <div className="px-5 py-3.5 border-t border-zinc-100">
        <p className="text-[11px] text-zinc-500 leading-relaxed">
          Penjualannya sendiri lengkap — cup, menu, jam, lokasi, semua tercatat.
          Yang belum ada cuma pengakuan bahwa uangnya sampai. Selama hari-hari ini
          menggantung, <b className="text-zinc-900">selisih setoran tidak bisa
          dihitung</b> — bukan karena selisihnya nol, tapi karena pembandingnya
          belum pernah dikunci.
        </p>
      </div>
    </section>
  )
}
