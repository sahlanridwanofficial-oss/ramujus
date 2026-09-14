'use client'

/**
 * Belanja bahan — sekaligus pemasukan stok.
 *
 * Tidak ada layar "catat belanja" lalu layar "input stok" terpisah. Satu
 * nota yang dimasukkan di sini menambah stok bahan dan menggeser harga
 * rata-ratanya sekaligus, karena keduanya memang satu kejadian.
 *
 * Yang diketik untuk buah adalah BERAT DAGING setelah dikupas, bukan
 * berat beli. Dengan begitu rendemen tidak pernah jadi angka yang harus
 * ditebak — ia terukur sendiri tiap belanja, dan buah jelek minggu ini
 * langsung muncul sebagai harga per gram yang naik.
 *
 * Berat beli ikut diminta tapi boleh kosong. Gunanya satu: memisahkan
 * "harga pasar naik" dari "buahnya makin jelek" — dua sebab yang obatnya
 * berbeda, dan yang tanpa angka ini terlihat sama persis.
 */

import { useCallback, useEffect, useMemo, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { jakartaToday } from '@/lib/date'
import { describeRpcError, firstRow } from '@/lib/rpc'
import { MARGIN_PER_CUP } from '@/lib/constants'
import HppMenu from '@/components/admin/HppMenu'
import {
  Receipt, Loader2, TriangleAlert, Plus, TrendingUp, TrendingDown,
  Info, Scale, Undo2,
} from 'lucide-react'

interface BahanRow {
  bahan_id: string
  nama: string
  satuan: string
  aktif: boolean
  harga_terakhir: number | null
  tanggal_terakhir: string | null
  rendemen_terakhir: number | null
  harga_rata: number | null
  stok_masuk_total: number | null
  nilai_masuk_total: number | null
  jumlah_belanja: number
}

interface BelanjaRow {
  id: string
  tanggal: string
  bahan_id: string
  nama: string
  satuan: string
  jumlah: number
  jumlah_beli: number | null
  total_rupiah: number
  harga_satuan: number | null
  rendemen: number | null
  catatan: string | null
  /** 'berlaku' | 'dibatalkan' | 'pembatal' */
  keadaan: string
  membatalkan_id: string | null
}

/** Biaya menurut takaran x harga — angka yang sudah sah hari ini juga. */
interface TakaranBiayaRow {
  cup: number
  cup_ternilai: number
  biaya_total: number | null
  biaya_per_cup: number | null
  omzet: number
  margin_per_cup: number | null
  lengkap: boolean
  harga_perkiraan: boolean
  nota_pertama: string | null
}

/**
 * Belanja pada rentang, TIDAK dibagi cup.
 *
 * Pembagian itu cuma sah kalau tinggi stok di awal dan akhir rentang
 * kira-kira sama. Satu belanja kemasan 1.000 cup melanggarnya telak.
 */
interface BelanjaRingkasRow {
  rupiah: number
  rupiah_kemasan: number
  jumlah_nota: number
  bahan_terisi: number
  bahan_total: number
}

const SATUAN = ['gram', 'ml', 'pcs'] as const

function num(v: unknown): number {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

function rupiahPerSatuan(v: number | null): string {
  if (v == null) return '—'
  return `Rp${v.toLocaleString('id-ID', { maximumFractionDigits: 2 })}`
}

function persen(v: number | null): string {
  if (v == null) return '—'
  return `${(v * 100).toFixed(0)}%`
}

function tanggalPendek(iso: string | null): string {
  if (!iso) return '—'
  const [y, m, d] = iso.split('-').map(Number)
  const bulan = ['Jan','Feb','Mar','Apr','Mei','Jun','Jul','Agu','Sep','Okt','Nov','Des']
  return `${d} ${bulan[m - 1]} ${String(y).slice(2)}`
}

export default function BelanjaBahanPage() {
  const [supabase] = useState(() => createClient())
  const [bahan, setBahan] = useState<BahanRow[]>([])
  const [riwayat, setRiwayat] = useState<BelanjaRow[]>([])
  const [takaran, setTakaran] = useState<TakaranBiayaRow | null>(null)
  const [belanja, setBelanja] = useState<BelanjaRingkasRow | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [pesan, setPesan] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // Rentang biaya per cup: 30 hari terakhir.
  const rentang = useMemo(() => {
    const sampai = jakartaToday()
    const d = new Date(`${sampai}T00:00:00`)
    d.setDate(d.getDate() - 29)
    return { dari: d.toISOString().slice(0, 10), sampai }
  }, [])

  // Formulir nota
  const [fBahan, setFBahan] = useState('')
  const [fTanggal, setFTanggal] = useState(jakartaToday())
  const [fRupiah, setFRupiah] = useState('')
  const [fDaging, setFDaging] = useState('')
  const [fBeli, setFBeli] = useState('')
  const [fCatatan, setFCatatan] = useState('')
  // Nota yang sedang dikoreksi. Bukan untuk diubah — untuk dibatalkan
  // dengan baris berlawanan, lalu diketik ulang yang benar.
  const [koreksiDari, setKoreksiDari] = useState<BelanjaRow | null>(null)

  // Formulir bahan baru
  const [bukaBahanBaru, setBukaBahanBaru] = useState(false)
  const [nBahan, setNBahan] = useState('')
  const [nSatuan, setNSatuan] = useState<typeof SATUAN[number]>('gram')

  const muat = useCallback(async () => {
    const [rb, rr, rt, rl] = await Promise.all([
      supabase.rpc('admin_bahan_ringkas'),
      supabase.rpc('admin_riwayat_belanja', { p_dari: rentang.dari, p_sampai: rentang.sampai }),
      supabase.rpc('admin_biaya_per_cup_takaran', { p_dari: rentang.dari, p_sampai: rentang.sampai }),
      supabase.rpc('admin_belanja_ringkas', { p_dari: rentang.dari, p_sampai: rentang.sampai }),
    ])

    if (rb.error) {
      setError(describeRpcError(rb.error, 'admin_bahan_ringkas'))
    } else {
      setError(null)
      setBahan((rb.data ?? []) as BahanRow[])
    }
    if (!rr.error) setRiwayat((rr.data ?? []) as BelanjaRow[])
    if (!rt.error) setTakaran(firstRow<TakaranBiayaRow>(rt.data))
    if (!rl.error) setBelanja(firstRow<BelanjaRingkasRow>(rl.data))
    setLoading(false)
  }, [supabase, rentang])

  useEffect(() => { muat() }, [muat])

  const bahanTerpilih = bahan.find(b => b.bahan_id === fBahan)

  // Harga nota ini, dihitung langsung saat mengetik. Angka inilah yang
  // sebenarnya masuk sistem, jadi ia ditampilkan sebelum disimpan — kalau
  // salah ketik, salahnya kelihatan di sini, bukan sebulan kemudian.
  const pratinjau = useMemo(() => {
    const r = Number(fRupiah)
    const d = Number(fDaging)
    const b = Number(fBeli)
    if (!Number.isFinite(r) || !Number.isFinite(d) || d <= 0 || r <= 0) return null
    const hargaBaru = r / d
    const rend = Number.isFinite(b) && b > 0 ? d / b : null
    const lama = bahanTerpilih?.harga_terakhir ?? null
    return {
      harga: hargaBaru,
      rendemen: rend,
      selisih: lama != null ? (hargaBaru - lama) / lama : null,
    }
  }, [fRupiah, fDaging, fBeli, bahanTerpilih])

  /**
   * Memperbaiki nota — satu tindakan, bukan dua.
   *
   * Formulirnya diisi angka ASLINYA supaya yang diketik pemakai adalah
   * angka yang BENAR, bukan kebalikan dari yang salah. Versi pertama
   * mengisi formulir dengan nilai negatif dan menyuruh menyimpan dua
   * kali; hasilnya tiga baris yang tampak dobel, dan pemakainya bingung
   * mana yang berlaku.
   *
   * Di balik layar tetap dua baris — pembatal yang menunjuk aslinya,
   * lalu penggantinya — karena buku besar belanja tetap hanya-tambah.
   */
  function mulaiKoreksi(r: BelanjaRow) {
    setKoreksiDari(r)
    setFBahan(r.bahan_id)
    setFTanggal(r.tanggal)
    setFDaging(String(num(r.jumlah)))
    setFRupiah(String(num(r.total_rupiah)))
    setFBeli(r.jumlah_beli != null ? String(num(r.jumlah_beli)) : '')
    setFCatatan(r.catatan ?? '')
    setPesan(null)
    setError(null)
    document.getElementById('form-nota')?.scrollIntoView({ behavior: 'smooth', block: 'center' })
  }

  /** Nota yang memang tidak pernah terjadi — dibatalkan tanpa pengganti. */
  async function batalkanSaja() {
    if (!koreksiDari) return
    if (!window.confirm(
      `Batalkan nota ${koreksiDari.nama} ${tanggalPendek(koreksiDari.tanggal)} tanpa pengganti?`
    )) return
    setBusy(true)
    const { error: err } = await supabase.rpc('admin_perbaiki_belanja', {
      p_belanja_id: koreksiDari.id,
    })
    if (err) setError(describeRpcError(err, 'admin_perbaiki_belanja'))
    else {
      setError(null)
      setPesan(`Nota ${koreksiDari.nama} dibatalkan.`)
      batalKoreksi()
      await muat()
    }
    setBusy(false)
  }

  function batalKoreksi() {
    setKoreksiDari(null)
    setFDaging(''); setFRupiah(''); setFBeli(''); setFCatatan('')
  }

  async function simpanNota(e: React.FormEvent) {
    e.preventDefault()
    if (!fBahan) return
    setBusy(true)
    setPesan(null)

    const { error: err } = koreksiDari
      ? await supabase.rpc('admin_perbaiki_belanja', {
          p_belanja_id: koreksiDari.id,
          p_jumlah: Number(fDaging),
          p_total_rupiah: Number(fRupiah),
          p_jumlah_beli: fBeli ? Number(fBeli) : null,
          p_catatan: fCatatan || null,
        })
      : await supabase.rpc('admin_catat_belanja', {
          p_bahan_id: fBahan,
          p_tanggal: fTanggal,
          p_jumlah: Number(fDaging),
          p_total_rupiah: Number(fRupiah),
          p_jumlah_beli: fBeli ? Number(fBeli) : null,
          p_catatan: fCatatan || null,
        })

    if (err) {
      const m = err.message ?? ''
      setError(
        m.includes('DAGING_LEBIH_BERAT_DARI_BELI')
          ? 'Berat daging lebih besar daripada berat beli. Salah satu angkanya tertukar.'
        : m.includes('TANGGAL_DI_MASA_DEPAN')
          ? 'Tanggal notanya di masa depan.'
        : describeRpcError(err, 'admin_catat_belanja')
      )
    } else {
      setError(null)
      // Setelah pembatalan, bahan dan tanggalnya sengaja DIBIARKAN terisi:
      // yang hampir selalu dilakukan berikutnya adalah mengetik ulang nota
      // yang benar untuk bahan dan hari yang sama.
      setPesan(koreksiDari
        ? `Nota ${koreksiDari.nama} diperbaiki. Yang lama ditandai dibatalkan, angkanya sudah pakai yang baru.`
        : 'Nota tersimpan — stok dan harga rata-ratanya sudah ikut bergerak.')
      setKoreksiDari(null)
      setFRupiah(''); setFDaging(''); setFBeli(''); setFCatatan('')
      await muat()
    }
    setBusy(false)
  }

  async function simpanBahan(e: React.FormEvent) {
    e.preventDefault()
    if (!nBahan.trim()) return
    setBusy(true)
    const { error: err } = await supabase
      .from('bahan')
      .insert({ nama: nBahan.trim(), satuan: nSatuan })
    if (err) setError(describeRpcError(err, 'bahan'))
    else {
      setError(null)
      setNBahan('')
      setBukaBahanBaru(false)
      await muat()
    }
    setBusy(false)
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20 text-zinc-400">
        <Loader2 className="w-5 h-5 animate-spin" />
      </div>
    )
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-extrabold text-zinc-900 tracking-tight">Belanja Bahan</h1>
        <p className="text-xs text-zinc-500 mt-0.5">
          Nota masuk ke sini, stok bahan bertambah, harga rata-ratanya bergerak — satu tindakan.
        </p>
      </div>

      {error && (
        <div className="flex items-start gap-3 p-3.5 bg-amber-50 border border-amber-300 rounded-2xl">
          <TriangleAlert className="w-5 h-5 text-amber-600 shrink-0 mt-px" />
          <p className="text-xs text-amber-900 leading-relaxed">{error}</p>
        </div>
      )}

      {/* ── Biaya bahan per cup ───────────────────────────────────

          Sampai 0031 panel ini membagi TOTAL BELANJA dengan cup terjual.
          Pada 15 September 2026 hasilnya Rp14.951 per cup — lebih mahal
          daripada harga jualnya — karena satu belanja kemasan 1.000 cup
          yang akan terpakai tujuh puluh hari dibagi cup yang terjual
          seminggu.

          Rumus itu hanya benar kalau tinggi stok di awal dan akhir
          rentang kira-kira sama, dan itulah pekerjaan hitung stok
          bulanan. Yang ditampilkan sekarang: biaya menurut takaran kali
          harga bahan — angka yang sudah benar hari ini juga. */}
      {takaran && (
        <section className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
          <div className="px-5 py-3.5 border-b border-zinc-100 flex items-center gap-2">
            <Receipt strokeWidth={2} className="w-4 h-4 text-brand" />
            <h2 className="text-sm font-bold text-zinc-900">Biaya Bahan per Cup — 30 Hari Terakhir</h2>
          </div>

          <div className="px-5 py-5 flex flex-wrap items-end gap-x-10 gap-y-4">
            <div>
              <p className="text-[11px] font-mono uppercase tracking-wider text-zinc-400">
                Dari takaran &times; harga
              </p>
              <p className="text-4xl font-extrabold text-zinc-900 tabular-nums leading-none mt-1.5">
                {takaran.biaya_per_cup != null
                  ? formatRupiah(Math.round(num(takaran.biaya_per_cup))) : '—'}
              </p>
              <p className="text-[11px] text-zinc-500 mt-1.5 tabular-nums">
                {takaran.cup_ternilai} dari {takaran.cup} cup ternilai
              </p>
            </div>
            <div>
              <p className="text-[11px] font-mono uppercase tracking-wider text-zinc-400">Margin per cup</p>
              <p className="text-4xl font-extrabold text-zinc-900 tabular-nums leading-none mt-1.5">
                {takaran.margin_per_cup != null
                  ? formatRupiah(Math.round(num(takaran.margin_per_cup))) : '—'}
              </p>
              <p className="text-[11px] text-zinc-500 mt-1.5">
                tebakan di kode: {formatRupiah(MARGIN_PER_CUP)}
              </p>
            </div>
          </div>

          <div className="px-5 py-3.5 border-t border-zinc-100 flex flex-col gap-2.5">
            {takaran.harga_perkiraan && (
              <p className="text-[11px] text-amber-800 leading-relaxed flex items-start gap-2">
                <Info strokeWidth={2} className="w-3.5 h-3.5 shrink-0 mt-px" />
                <span>
                  <b>Sebagian perkiraan.</b> Ada cup yang terjual sebelum nota pertama dicatat
                  ({tanggalPendek(takaran.nota_pertama)}), jadi dinilai dengan harga bahan paling
                  awal yang diketahui. Angkanya akan jadi terukur penuh begitu penjualan dan nota
                  berjalan berdampingan.
                </span>
              </p>
            )}
            <p className="text-[11px] text-zinc-500 leading-relaxed">
              <b className="text-zinc-900">Ini biaya menurut resep</b>, dinilai dengan harga bahan
              yang berlaku pada hari cupnya terjual. Belum termasuk buah busuk, tumpah, dan
              kelebihan tuang &mdash; jadi kenyataannya selalu sedikit lebih mahal. Selisih itu baru
              bisa dilihat setelah isi freezer mulai dihitung bulanan.
            </p>

            {belanja && num(belanja.rupiah) > 0 && (
              <p className="text-[11px] text-zinc-400 leading-relaxed border-t border-zinc-100 pt-2.5">
                Belanja 30 hari terakhir <b className="text-zinc-600">{formatRupiah(num(belanja.rupiah))}</b>
                {num(belanja.rupiah_kemasan) > 0 && (
                  <> &mdash; {formatRupiah(num(belanja.rupiah_kemasan))} di antaranya kemasan</>
                )}.{' '}
                <b className="text-zinc-600">Sengaja tidak dibagi cup:</b> sebagian besar masih jadi
                stok yang belum terpakai, dan membaginya sekarang menghasilkan angka yang jauh lebih
                mahal daripada harga jualnya.
              </p>
            )}

            {takaran.cup > 0 && !takaran.lengkap && (
              <p className="text-[11px] text-amber-800 leading-relaxed flex items-start gap-2">
                <Info strokeWidth={2} className="w-3.5 h-3.5 shrink-0 mt-px" />
                <span>
                  {takaran.cup - takaran.cup_ternilai} cup belum bisa dinilai &mdash; takarannya
                  belum lengkap, atau bahannya belum punya harga pada hari cup itu terjual. Biaya di
                  atas dibagi {takaran.cup_ternilai} cup yang ternilai saja, bukan seluruhnya.
                </span>
              </p>
            )}
          </div>
        </section>
      )}

      {/*
        HPP per menu ditaruh di atas formulir nota, bukan di bawah:
        pertanyaan yang dibawa orang ke layar ini adalah "menu mana yang
        tipis", dan mencatat nota adalah cara menjawabnya — bukan
        sebaliknya.
      */}
      <HppMenu />

      <div className="grid grid-cols-1 lg:grid-cols-5 gap-6">
        {/* ── Formulir nota ───────────────────────────────────── */}
        <section id="form-nota" className="lg:col-span-2 bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden h-fit">
          <div className="px-5 py-3.5 border-b border-zinc-100">
            <h2 className="text-sm font-bold text-zinc-900">
              {koreksiDari ? 'Perbaiki Nota' : 'Catat Nota'}
            </h2>
          </div>

          {koreksiDari && (
            <div className="px-5 py-3 bg-brand-soft border-b border-brand-border flex items-start gap-2.5">
              <Undo2 strokeWidth={2} className="w-4 h-4 text-brand shrink-0 mt-px" />
              <div className="flex-1 min-w-0">
                <p className="text-[11px] text-zinc-800 leading-relaxed">
                  Memperbaiki <b>{koreksiDari.nama}</b> {tanggalPendek(koreksiDari.tanggal)} —
                  tercatat {num(koreksiDari.jumlah).toLocaleString('id-ID')} {koreksiDari.satuan} ·{' '}
                  {formatRupiah(num(koreksiDari.total_rupiah))}.{' '}
                  <b>Ketik angka yang benar</b>, lalu simpan sekali.
                </p>
                <p className="text-[10px] text-zinc-500 leading-relaxed mt-1">
                  Nota lama tidak dihapus — ia ditandai dibatalkan dan dicoret di riwayat, supaya
                  riwayat harganya tetap utuh. Tanggal dan bahannya ikut yang lama.
                </p>
                <div className="flex items-center gap-3 mt-1.5">
                  <button
                    type="button"
                    onClick={batalKoreksi}
                    className="text-[10px] font-bold text-zinc-500 hover:text-zinc-800"
                  >
                    Jangan jadi
                  </button>
                  <button
                    type="button"
                    onClick={batalkanSaja}
                    disabled={busy}
                    className="text-[10px] font-bold text-zinc-500 hover:text-brand disabled:opacity-60"
                  >
                    Batalkan saja, tanpa pengganti
                  </button>
                </div>
              </div>
            </div>
          )}

          <form onSubmit={simpanNota} className="px-5 py-4 flex flex-col gap-3.5">
            <div>
              <label htmlFor="f-bahan" className="block text-[11px] font-bold text-zinc-600 mb-1.5">
                Bahan
              </label>
              <select
                id="f-bahan"
                value={fBahan}
                onChange={e => setFBahan(e.target.value)}
                required
                className="w-full px-3 py-2 rounded-lg border border-zinc-200 text-sm bg-white focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20"
              >
                <option value="">Pilih bahan…</option>
                {bahan.filter(b => b.aktif).map(b => (
                  <option key={b.bahan_id} value={b.bahan_id}>{b.nama} ({b.satuan})</option>
                ))}
              </select>
            </div>

            <div className="grid grid-cols-2 gap-3">
              <div>
                <label htmlFor="f-tanggal" className="block text-[11px] font-bold text-zinc-600 mb-1.5">
                  Tanggal nota
                </label>
                <input
                  id="f-tanggal" type="date" value={fTanggal} required
                  max={jakartaToday()}
                  onChange={e => setFTanggal(e.target.value)}
                  className="w-full px-3 py-2 rounded-lg border border-zinc-200 text-sm focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20"
                />
              </div>
              <div>
                <label htmlFor="f-rupiah" className="block text-[11px] font-bold text-zinc-600 mb-1.5">
                  Dibayar (Rp)
                </label>
                <input
                  id="f-rupiah" type="number" inputMode="numeric" value={fRupiah} required
                  onChange={e => setFRupiah(e.target.value)}
                  placeholder="20000"
                  className="w-full px-3 py-2 rounded-lg border border-zinc-200 text-sm tabular-nums focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20"
                />
              </div>
            </div>

            <div className="grid grid-cols-2 gap-3">
              <div>
                <label htmlFor="f-daging" className="block text-[11px] font-bold text-zinc-600 mb-1.5">
                  Yang masuk stok
                  {bahanTerpilih && <span className="text-zinc-400"> ({bahanTerpilih.satuan})</span>}
                </label>
                <input
                  id="f-daging" type="number" inputMode="decimal" value={fDaging} required
                  onChange={e => setFDaging(e.target.value)}
                  placeholder="650"
                  className="w-full px-3 py-2 rounded-lg border border-zinc-200 text-sm tabular-nums focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20"
                />
                <p className="text-[10px] text-zinc-400 mt-1 leading-snug">
                  Buah: berat <b>setelah dikupas</b>.
                </p>
              </div>
              <div>
                <label htmlFor="f-beli" className="block text-[11px] font-bold text-zinc-600 mb-1.5">
                  Berat beli <span className="font-normal text-zinc-400">— opsional</span>
                </label>
                <input
                  id="f-beli" type="number" inputMode="decimal" value={fBeli}
                  onChange={e => setFBeli(e.target.value)}
                  placeholder="1000"
                  className="w-full px-3 py-2 rounded-lg border border-zinc-200 text-sm tabular-nums focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20"
                />
                <p className="text-[10px] text-zinc-400 mt-1 leading-snug">
                  Sebelum dikupas. Buat lihat kualitas buah.
                </p>
              </div>
            </div>

            <div>
              <label htmlFor="f-catatan" className="block text-[11px] font-bold text-zinc-600 mb-1.5">
                Catatan <span className="font-normal text-zinc-400">— opsional</span>
              </label>
              <input
                id="f-catatan" type="text" value={fCatatan}
                onChange={e => setFCatatan(e.target.value)}
                placeholder="supplier baru, buahnya kecil-kecil"
                className="w-full px-3 py-2 rounded-lg border border-zinc-200 text-sm focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20"
              />
            </div>

            {/* Angka yang sebenarnya masuk sistem, kelihatan sebelum disimpan. */}
            {pratinjau && bahanTerpilih && (
              <div className="rounded-lg bg-zinc-50 border border-zinc-200/70 px-3.5 py-3">
                <p className="text-[10px] font-mono uppercase tracking-wider text-zinc-400 mb-1.5">
                  Yang tercatat
                </p>
                <p className="text-sm font-bold text-zinc-900 tabular-nums">
                  {rupiahPerSatuan(pratinjau.harga)}
                  <span className="font-medium text-zinc-500"> / {bahanTerpilih.satuan}</span>
                  {pratinjau.rendemen != null && (
                    <span className="font-medium text-zinc-500">
                      {' '}· daging {persen(pratinjau.rendemen)}
                    </span>
                  )}
                </p>
                {pratinjau.selisih != null && Math.abs(pratinjau.selisih) >= 0.005 && (
                  <p className={`text-[11px] font-semibold mt-1 flex items-center gap-1 ${
                    pratinjau.selisih > 0 ? 'text-brand' : 'text-emerald-700'}`}>
                    {pratinjau.selisih > 0
                      ? <TrendingUp strokeWidth={2.5} className="w-3.5 h-3.5" />
                      : <TrendingDown strokeWidth={2.5} className="w-3.5 h-3.5" />}
                    {pratinjau.selisih > 0 ? 'Naik' : 'Turun'}{' '}
                    {Math.abs(pratinjau.selisih * 100).toFixed(1)}% dari nota terakhir
                  </p>
                )}
              </div>
            )}

            {pesan && (
              <p className="text-[11px] font-semibold text-emerald-700">{pesan}</p>
            )}

            <button
              type="submit"
              disabled={busy || !fBahan}
              className="w-full py-2.5 rounded-lg text-xs font-bold bg-brand text-white hover:bg-brand-dark disabled:opacity-60 transition-colors flex items-center justify-center gap-1.5"
            >
              {busy ? <Loader2 className="w-4 h-4 animate-spin" />
                    : koreksiDari ? 'Simpan perbaikan' : 'Simpan nota'}
            </button>

            <p className="text-[10px] text-zinc-400 leading-relaxed border-t border-zinc-100 pt-3">
              Nota tidak pernah ditimpa. <b className="text-zinc-500">Perbaiki</b> di daftar riwayat
              menandai yang lama sebagai dibatalkan dan menulis penggantinya — dua baris di buku
              besar, satu tekan di layar, dan riwayat harganya tidak pernah berubah surut.
            </p>
          </form>
        </section>

        {/* ── Daftar bahan ────────────────────────────────────── */}
        <section className="lg:col-span-3 bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden h-fit">
          <div className="px-5 py-3.5 border-b border-zinc-100 flex items-center justify-between gap-3">
            <h2 className="text-sm font-bold text-zinc-900">Bahan &amp; Harganya</h2>
            <button
              type="button"
              onClick={() => setBukaBahanBaru(v => !v)}
              className="inline-flex items-center gap-1 text-[11px] font-bold text-brand hover:underline"
            >
              <Plus strokeWidth={2.5} className="w-3.5 h-3.5" /> Bahan baru
            </button>
          </div>

          {bukaBahanBaru && (
            <form onSubmit={simpanBahan} className="px-5 py-3.5 bg-zinc-50 border-b border-zinc-100 flex flex-wrap gap-2 items-end">
              <div className="flex-1 min-w-[140px]">
                <label htmlFor="n-bahan" className="block text-[11px] font-bold text-zinc-600 mb-1.5">Nama</label>
                <input
                  id="n-bahan" type="text" value={nBahan} required
                  onChange={e => setNBahan(e.target.value)}
                  placeholder="Nanas"
                  className="w-full px-3 py-2 rounded-lg border border-zinc-200 text-sm focus:border-brand focus:outline-none"
                />
              </div>
              <div>
                <label htmlFor="n-satuan" className="block text-[11px] font-bold text-zinc-600 mb-1.5">Satuan pakai</label>
                <select
                  id="n-satuan" value={nSatuan}
                  onChange={e => setNSatuan(e.target.value as typeof SATUAN[number])}
                  className="px-3 py-2 rounded-lg border border-zinc-200 text-sm bg-white focus:border-brand focus:outline-none"
                >
                  {SATUAN.map(s => <option key={s} value={s}>{s}</option>)}
                </select>
              </div>
              <button
                type="submit" disabled={busy}
                className="px-4 py-2 rounded-lg text-xs font-bold bg-brand text-white hover:bg-brand-dark disabled:opacity-60 transition-colors"
              >
                Tambah
              </button>
            </form>
          )}

          {bahan.length === 0 ? (
            <div className="px-5 py-8 text-center">
              <Scale strokeWidth={1.5} className="w-7 h-7 text-zinc-300 mx-auto" />
              <p className="text-xs font-bold text-zinc-700 mt-2.5">Belum ada bahan</p>
              <p className="text-[11px] text-zinc-500 mt-1 max-w-sm mx-auto leading-relaxed">
                Mulai dari yang paling sering dibeli — pisang, susu, kemasan. Sekitar 12 baris
                sudah cukup untuk menutup seluruh menu.
              </p>
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm min-w-[520px]">
                <thead>
                  <tr className="border-b border-zinc-100">
                    <th className="text-left px-5 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Bahan</th>
                    <th className="text-right px-3 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Terakhir</th>
                    <th className="text-right px-3 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Rata 30h</th>
                    <th className="text-right px-3 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Daging</th>
                    <th className="text-right px-5 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Masuk stok</th>
                  </tr>
                </thead>
                <tbody>
                  {bahan.map(b => (
                    <tr key={b.bahan_id} className="border-b border-zinc-50 last:border-0">
                      <td className="px-5 py-2.5">
                        <span className="font-semibold text-zinc-900">{b.nama}</span>
                        <span className="text-[11px] text-zinc-400"> /{b.satuan}</span>
                        {b.jumlah_belanja === 0 && (
                          <span className="block text-[10px] text-amber-700 font-semibold">belum pernah dibeli</span>
                        )}
                      </td>
                      <td className="text-right px-3 py-2.5 tabular-nums">
                        <span className="font-bold text-zinc-900">{rupiahPerSatuan(b.harga_terakhir)}</span>
                        <span className="block text-[10px] text-zinc-400">{tanggalPendek(b.tanggal_terakhir)}</span>
                      </td>
                      <td className="text-right px-3 py-2.5 tabular-nums text-zinc-600">
                        {rupiahPerSatuan(b.harga_rata)}
                      </td>
                      <td className="text-right px-3 py-2.5 tabular-nums text-zinc-600">
                        {persen(b.rendemen_terakhir)}
                      </td>
                      <td className="text-right px-5 py-2.5 tabular-nums text-zinc-600">
                        {num(b.stok_masuk_total).toLocaleString('id-ID')} {b.satuan}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          <div className="px-5 py-3.5 border-t border-zinc-100">
            <p className="text-[11px] text-zinc-500 leading-relaxed">
              <b className="text-zinc-900">Terakhir</b> dipakai untuk memutuskan harga jual — tiap
              cup yang terjual hari ini harus diganti besok di harga hari ini.{' '}
              <b className="text-zinc-900">Rata 30h</b> untuk melihat bulan yang sudah lewat.{' '}
              <b className="text-zinc-900">Daging</b> turun sementara rupiah per kilo tetap berarti
              buahnya yang makin jelek, bukan harganya yang naik.
            </p>
          </div>
        </section>
      </div>

      {/* ── Riwayat ─────────────────────────────────────────── */}
      {riwayat.length > 0 && (
        <section className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
          <div className="px-5 py-3.5 border-b border-zinc-100">
            <h2 className="text-sm font-bold text-zinc-900">Riwayat Nota — 30 Hari Terakhir</h2>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-sm min-w-[640px]">
              <thead>
                <tr className="border-b border-zinc-100">
                  <th className="text-left px-5 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Tanggal</th>
                  <th className="text-left px-3 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Bahan</th>
                  <th className="text-right px-3 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Masuk</th>
                  <th className="text-right px-3 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Dibayar</th>
                  <th className="text-right px-3 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Per satuan</th>
                  <th className="text-right px-3 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal">Daging</th>
                  <th className="text-right px-5 py-2.5 text-[10px] font-mono uppercase tracking-wider text-zinc-400 font-normal"></th>
                </tr>
              </thead>
              <tbody>
                {/* Baris pembatal DILIPAT. Ia mekanismenya, bukan peristiwanya
                    — dan menampilkannya berjajar dengan aslinya persis yang
                    bikin angkanya tampak dobel. Yang dibatalkan tetap
                    ditampilkan, dicoret, supaya jejaknya tidak hilang. */}
                {riwayat.filter(r => r.keadaan !== 'pembatal').map(r => (
                  <tr
                    key={r.id}
                    className={`border-b border-zinc-50 last:border-0 ${
                      r.keadaan === 'dibatalkan' ? 'text-zinc-300' : ''}`}
                  >
                    <td className={`px-5 py-2.5 tabular-nums whitespace-nowrap ${
                      r.keadaan === 'dibatalkan' ? 'text-zinc-300' : 'text-zinc-600'}`}>
                      {tanggalPendek(r.tanggal)}
                      {r.keadaan === 'dibatalkan' && (
                        <span className="block text-[10px] font-bold text-zinc-400">dibatalkan</span>
                      )}
                    </td>
                    <td className="px-3 py-2.5">
                      <span className={`font-semibold ${
                        r.keadaan === 'dibatalkan'
                          ? 'text-zinc-300 line-through' : 'text-zinc-900'}`}>
                        {r.nama}
                      </span>
                      {r.catatan && <span className="block text-[10px] text-zinc-400">{r.catatan}</span>}
                    </td>
                    <td className={`text-right px-3 py-2.5 tabular-nums ${
                      r.keadaan === 'dibatalkan' ? 'text-zinc-300 line-through' : 'text-zinc-600'}`}>
                      {num(r.jumlah).toLocaleString('id-ID')} {r.satuan}
                    </td>
                    <td className={`text-right px-3 py-2.5 tabular-nums ${
                      r.keadaan === 'dibatalkan' ? 'text-zinc-300 line-through' : 'text-zinc-600'}`}>
                      {formatRupiah(num(r.total_rupiah))}
                    </td>
                    <td className={`text-right px-3 py-2.5 tabular-nums font-semibold ${
                      r.keadaan === 'dibatalkan' ? 'text-zinc-300 line-through' : 'text-zinc-900'}`}>
                      {rupiahPerSatuan(r.harga_satuan)}
                    </td>
                    <td className={`text-right px-3 py-2.5 tabular-nums ${
                      r.keadaan === 'dibatalkan' ? 'text-zinc-300' : 'text-zinc-600'}`}>
                      {persen(r.rendemen)}
                    </td>
                    <td className="text-right px-5 py-2.5">
                      {/* Yang sudah dibatalkan tidak bisa dibatalkan lagi —
                          dua pembatal untuk satu nota akan mengurangi stok
                          dua kali dari satu peristiwa. */}
                      {r.keadaan === 'berlaku' && (
                        <button
                          type="button"
                          onClick={() => mulaiKoreksi(r)}
                          className="inline-flex items-center gap-1 text-[10px] font-bold text-zinc-400 hover:text-brand transition-colors whitespace-nowrap"
                        >
                          <Undo2 strokeWidth={2.5} className="w-3 h-3" />
                          Perbaiki
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </div>
  )
}
