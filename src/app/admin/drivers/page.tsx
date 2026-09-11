'use client'

import { useState, useEffect, useCallback } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { jakartaToday, shiftDate, daysInRange, formatCalendarDate } from '@/lib/date'
import { describeRpcError, isMissingFunction } from '@/lib/rpc'
import {
  Loader2, Users, TrendingUp, ShoppingBag, UserPlus,
  X, CheckCircle2, AlertCircle, PackageCheck, Eye, EyeOff,
  CalendarDays, TriangleAlert
} from 'lucide-react'
import type { Profile } from '@/types/database'

interface DriverWithStats extends Profile {
  orders: number
  /** null = server versi lama tidak dapat memberi angka cup. */
  cups: number | null
  items: number
  revenue: number
  active_days: number
  has_active_shift: boolean
}

/** Baris agregat dari RPC admin_driver_stats_range(). */
interface DriverStatsRow {
  driver_id: string
  orders: number
  cups: number
  items: number
  revenue: number
  active_days: number
  last_order_at: string | null
  has_active_shift: boolean
}

/** Bentuk lama, dipakai bila migrasi 0009 belum dijalankan. */
interface LegacyStatsRow {
  driver_id: string
  total_orders: number
  total_revenue: number
  has_active_shift: boolean
}

const PRESETS = [
  { key: '7d', label: '7 Hari', days: 7 },
  { key: '30d', label: '30 Hari', days: 30 },
  { key: '90d', label: '90 Hari', days: 90 },
] as const

export default function DriversPage() {
  const [drivers, setDrivers] = useState<DriverWithStats[]>([])
  const [loading, setLoading] = useState(true)
  const [isModalOpen, setIsModalOpen] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [showPassword, setShowPassword] = useState(false)
  const [formError, setFormError] = useState('')
  const [formSuccess, setFormSuccess] = useState('')
  // Kegagalan memuat statistik dulu tampil sebagai nol, sama saja dengan
  // "mitra ini belum menjual apa pun".
  const [loadError, setLoadError] = useState<string | null>(null)
  const [statusError, setStatusError] = useState<string | null>(null)

  const [preset, setPreset] = useState<string>('30d')
  const [dateFrom, setDateFrom] = useState(() => shiftDate(jakartaToday(), -29))
  const [dateTo, setDateTo] = useState(() => jakartaToday())

  // Form State
  const [fullName, setFullName] = useState('')
  const [phone, setPhone] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')

  const [supabase] = useState(() => createClient())

  const loadDrivers = useCallback(async () => {
    setLoading(true)
    setLoadError(null)

    const from = dateFrom <= dateTo ? dateFrom : dateTo
    const to = dateFrom <= dateTo ? dateTo : dateFrom

    try {
      // Versi lama menjalankan 1 + 2N query dan menarik SELURUH riwayat
      // pesanan tiap driver hanya untuk dijumlahkan di browser. Pada 100
      // mitra itu 201 query dan puluhan ribu baris per pembukaan halaman.
      // Sekarang dua query tetap, dengan agregasi dikerjakan database.
      const [profileRes, statsRes] = await Promise.all([
        supabase
          .from('profiles')
          .select('*')
          .eq('role', 'driver')
          .order('created_at', { ascending: false }),
        supabase.rpc('admin_driver_stats_range', { p_from: from, p_to: to }),
      ])

      if (profileRes.error) {
        setDrivers([])
        setLoadError(`Gagal memuat daftar mitra: ${profileRes.error.message}`)
        return
      }

      const profiles = (profileRes.data ?? []) as Profile[]
      const byId = new Map<string, Omit<DriverWithStats, keyof Profile>>()

      if (statsRes.error && isMissingFunction(statsRes.error)) {
        // Database belum menjalankan migrasi 0009: pakai fungsi lama, yang
        // tidak mengenal cup maupun rentang tanggal. Angkanya tetap
        // ditampilkan, tetapi apa adanya — total sepanjang masa.
        const legacy = await supabase.rpc('admin_driver_stats')
        for (const row of (legacy.data ?? []) as LegacyStatsRow[]) {
          byId.set(row.driver_id, {
            orders: row.total_orders ?? 0,
            cups: null,
            items: 0,
            revenue: Number(row.total_revenue ?? 0),
            active_days: 0,
            has_active_shift: row.has_active_shift ?? false,
          })
        }
        setLoadError(
          'Server belum mengenal statistik per rentang tanggal, jadi angka di bawah adalah total sepanjang masa dan belum memisahkan cup dari transaksi. Jalankan supabase/migrations/0009_shared_cup_definition.sql di SQL Editor Supabase.'
        )
      } else if (statsRes.error) {
        setLoadError(describeRpcError(statsRes.error, 'admin_driver_stats_range'))
      } else {
        for (const row of (statsRes.data ?? []) as DriverStatsRow[]) {
          byId.set(row.driver_id, {
            orders: row.orders ?? 0,
            cups: row.cups ?? 0,
            items: row.items ?? 0,
            revenue: Number(row.revenue ?? 0),
            active_days: row.active_days ?? 0,
            has_active_shift: row.has_active_shift ?? false,
          })
        }
      }

      setDrivers(
        profiles.map(driver => ({
          ...driver,
          orders: 0,
          cups: 0,
          items: 0,
          revenue: 0,
          active_days: 0,
          has_active_shift: false,
          ...byId.get(driver.id),
        }))
      )
    } catch (err) {
      setDrivers([])
      setLoadError(
        'Tidak dapat menghubungi server. ' +
        (err instanceof Error ? err.message : 'Periksa koneksi lalu coba lagi.')
      )
    } finally {
      setLoading(false)
    }
  }, [supabase, dateFrom, dateTo])

  useEffect(() => { loadDrivers() }, [loadDrivers])

  function applyPreset(key: string, days: number) {
    setPreset(key)
    setDateFrom(shiftDate(jakartaToday(), -(days - 1)))
    setDateTo(jakartaToday())
  }

  async function toggleStatus(driver: DriverWithStats) {
    const nextStatus = driver.status === 'active' ? 'inactive' : 'active'
    setStatusError(null)
    setDrivers(prev => prev.map(d => d.id === driver.id ? { ...d, status: nextStatus } : d))

    const { error } = await supabase
      .from('profiles')
      .update({ status: nextStatus })
      .eq('id', driver.id)

    // Menonaktifkan mitra kini benar-benar memutus aksesnya, jadi
    // penyimpanan yang gagal tidak boleh lagi tampil sebagai berhasil:
    // tampilan dikembalikan ke keadaan sebenarnya dan sebabnya dikatakan.
    if (error) {
      setDrivers(prev => prev.map(d => d.id === driver.id ? { ...d, status: driver.status } : d))
      setStatusError(
        `Gagal mengubah status ${driver.full_name}. Perubahan tidak tersimpan — ${error.message}`
      )
    }
  }

  async function handleCreateDriver(e: React.FormEvent) {
    e.preventDefault()
    setFormError('')
    setFormSuccess('')
    setSubmitting(true)

    try {
      const res = await fetch('/api/admin/drivers', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          full_name: fullName,
          phone,
          email,
          password
        })
      })

      const data = await res.json()

      if (!res.ok) {
        setFormError(data.error || 'Gagal mendaftarkan driver baru.')
        setSubmitting(false)
        return
      }

      setFormSuccess('Mitra driver berhasil didaftarkan!')
      setFullName('')
      setPhone('')
      setEmail('')
      setPassword('')
      
      // Reload drivers
      await loadDrivers()

      setTimeout(() => {
        setIsModalOpen(false)
        setFormSuccess('')
      }, 1200)
    } catch {
      setFormError('Koneksi terputus saat menghubungi server.')
    } finally {
      setSubmitting(false)
    }
  }

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-64 gap-2 text-zinc-400">
        <Loader2 className="w-6 h-6 animate-spin text-brand" />
        <span className="text-xs">Memuat data armada mitra...</span>
      </div>
    )
  }

  return (
    <div className="space-y-5">
      {/* Header with Title & Add Driver CTA */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 pb-2 border-b border-zinc-200/70">
        <div>
          <h1 className="text-2xl font-extrabold text-zinc-900 tracking-tight">Armada Mitra Driver</h1>
          <p className="text-xs text-zinc-500 mt-0.5">
            Kinerja per mitra pada {formatCalendarDate(dateFrom, true)} – {formatCalendarDate(dateTo, true)} ({daysInRange(dateFrom, dateTo)} hari).
          </p>
        </div>

        <button
          onClick={() => {
            setFormError('')
            setFormSuccess('')
            setIsModalOpen(true)
          }}
          className="flex items-center justify-center gap-2 bg-brand hover:bg-[#a61515] active:scale-[0.98] text-white px-4 py-2.5 rounded-xl font-bold text-xs transition-all shadow-sm shadow-red-900/15"
        >
          <UserPlus strokeWidth={2.2} className="w-4 h-4" />
          <span>Tambah Mitra Driver</span>
        </button>
      </div>

      {/* Pemilih rentang tanggal — kinerja mitra kini bisa dinilai per periode,
          bukan hanya sebagai total sepanjang masa */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 p-3.5 shadow-card flex flex-col lg:flex-row lg:items-end gap-3">
        <div className="flex items-center gap-2 text-zinc-500 shrink-0">
          <CalendarDays className="w-4 h-4" />
          <span className="text-xs font-bold uppercase tracking-wider">Periode</span>
        </div>
        <div className="flex flex-wrap items-end gap-3 flex-1">
          <div className="flex bg-zinc-100 rounded-xl p-1">
            {PRESETS.map(p => (
              <button
                key={p.key}
                onClick={() => applyPreset(p.key, p.days)}
                className={`px-3 py-1.5 rounded-lg text-xs font-bold transition-all ${
                  preset === p.key ? 'bg-zinc-900 text-white shadow-card' : 'text-zinc-500 hover:text-zinc-900'
                }`}
              >
                {p.label}
              </button>
            ))}
          </div>
          <label className="flex flex-col gap-1">
            <span className="text-[11px] font-semibold text-zinc-500">Dari</span>
            <input
              type="date"
              value={dateFrom}
              max={dateTo}
              onChange={e => { setPreset('custom'); setDateFrom(e.target.value) }}
              className="border border-zinc-200 rounded-lg px-2.5 py-1.5 text-xs font-semibold text-zinc-800 focus:outline-none focus:ring-2 focus:ring-brand/20"
            />
          </label>
          <label className="flex flex-col gap-1">
            <span className="text-[11px] font-semibold text-zinc-500">Sampai</span>
            <input
              type="date"
              value={dateTo}
              min={dateFrom}
              max={jakartaToday()}
              onChange={e => { setPreset('custom'); setDateTo(e.target.value) }}
              className="border border-zinc-200 rounded-lg px-2.5 py-1.5 text-xs font-semibold text-zinc-800 focus:outline-none focus:ring-2 focus:ring-brand/20"
            />
          </label>
        </div>
      </div>

      {loadError && (
        <div role="alert" className="flex items-start gap-3 p-3.5 bg-amber-50 border border-amber-300 rounded-2xl">
          <TriangleAlert className="w-5 h-5 text-amber-600 shrink-0 mt-px" />
          <p className="text-[11px] text-amber-900 font-semibold leading-relaxed">{loadError}</p>
        </div>
      )}

      {statusError && (
        <div role="alert" className="flex items-start gap-3 p-3.5 bg-red-50 border border-red-300 rounded-2xl">
          <AlertCircle className="w-5 h-5 text-brand shrink-0 mt-px" />
          <p className="text-[11px] text-brand font-semibold leading-relaxed">{statusError}</p>
        </div>
      )}

      {/* Empty State */}
      {drivers.length === 0 ? (
        <div className="bg-white rounded-2xl border border-zinc-200/80 p-12 text-center max-w-md mx-auto my-8 space-y-4">
          <div className="w-14 h-14 rounded-2xl bg-red-50 text-brand flex items-center justify-center mx-auto">
            <Users className="w-7 h-7" />
          </div>
          <div>
            <h3 className="font-bold text-zinc-900 text-base">Belum Ada Mitra Driver</h3>
            <p className="text-xs text-zinc-500 mt-1">
              Daftarkan personel driver pertama Anda untuk mulai mengoperasikan gerobak keliling ramu.
            </p>
          </div>
          <button
            onClick={() => setIsModalOpen(true)}
            className="inline-flex items-center gap-2 bg-brand hover:bg-[#a61515] text-white px-4 py-2.5 rounded-xl font-bold text-xs transition-colors"
          >
            <UserPlus className="w-4 h-4" />
            <span>Tambah Mitra Driver Pertama</span>
          </button>
        </div>
      ) : (
        /* Driver Grid */
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {drivers.map(driver => (
            <div key={driver.id} className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-card space-y-4">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div className="w-11 h-11 bg-zinc-900 text-white rounded-xl flex items-center justify-center font-bold text-sm">
                    {driver.full_name.charAt(0)}
                  </div>
                  <div>
                    <div className="flex items-center gap-2">
                      <p className="text-sm font-bold text-zinc-900">{driver.full_name}</p>
                      {driver.has_active_shift ? (
                        <span className="inline-flex items-center gap-1 text-[10px] bg-red-50 text-brand border border-red-100 px-2 py-0.5 rounded-full font-bold">
                          <span className="w-1.5 h-1.5 rounded-full bg-brand animate-pulse" />
                          Online
                        </span>
                      ) : (
                        <span className="inline-flex items-center text-[10px] bg-zinc-100 text-zinc-400 px-2 py-0.5 rounded-full font-medium">
                          Off-shift
                        </span>
                      )}
                    </div>
                    <p className="text-xs text-zinc-400 font-mono mt-0.5">{driver.phone || '08xx-xxxx-xxxx'}</p>
                  </div>
                </div>

                <button
                  onClick={() => toggleStatus(driver)}
                  className={`px-3 py-1.5 rounded-xl text-xs font-bold transition-all ${
                    driver.status === 'active'
                      ? 'bg-emerald-50 text-emerald-700 hover:bg-emerald-100'
                      : 'bg-zinc-100 text-zinc-500 hover:bg-zinc-200'
                  }`}
                >
                  {driver.status === 'active' ? 'Aktif' : 'Nonaktif'}
                </button>
              </div>

              {/* Driver Stats — cup dan transaksi adalah dua angka berbeda.
                  Sebelumnya jumlah transaksi ditampilkan dengan satuan "Cup",
                  jadi satu nota berisi tiga cup terhitung satu. */}
              <div className="grid grid-cols-2 gap-2 pt-2 border-t border-zinc-100">
                <div className="bg-zinc-50/80 rounded-xl p-3 border border-zinc-100">
                  <div className="flex items-center gap-1.5 text-[11px] font-semibold text-zinc-400 mb-1">
                    <ShoppingBag className="w-3.5 h-3.5" />
                    <span>Cup Terjual</span>
                  </div>
                  {driver.cups === null ? (
                    <p className="text-base font-extrabold text-zinc-400">—</p>
                  ) : (
                    <p className="text-base font-extrabold text-zinc-900">
                      {driver.cups} <span className="text-xs font-medium text-zinc-500">cup</span>
                    </p>
                  )}
                  <p className="text-[10px] text-zinc-400 font-medium mt-0.5">
                    {driver.orders} transaksi
                    {driver.active_days > 0 && ` · ${driver.active_days} hari aktif`}
                  </p>
                </div>

                <div className="bg-zinc-50/80 rounded-xl p-3 border border-zinc-100">
                  <div className="flex items-center gap-1.5 text-[11px] font-semibold text-zinc-400 mb-1">
                    <TrendingUp className="w-3.5 h-3.5" />
                    <span>Omzet</span>
                  </div>
                  <p className="text-base font-extrabold text-brand">{formatRupiah(driver.revenue)}</p>
                  <p className="text-[10px] text-zinc-400 font-medium mt-0.5">
                    {driver.orders > 0
                      ? `${formatRupiah(Math.round(driver.revenue / driver.orders))}/nota`
                      : 'Belum ada penjualan'}
                  </p>
                </div>
              </div>

              {/* Action Quick Links */}
              <div className="pt-2 flex items-center justify-end gap-2">
                <Link
                  href={`/admin/inventory?driverId=${driver.id}`}
                  className="flex items-center gap-1.5 text-xs font-bold text-zinc-700 hover:text-brand bg-zinc-50 hover:bg-red-50/70 border border-zinc-200/80 hover:border-red-200 px-3 py-2 rounded-xl transition-all"
                >
                  <PackageCheck className="w-3.5 h-3.5" />
                  <span>Atur Stok Gerobak</span>
                </Link>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Modal Dialog: Tambah Mitra Driver */}
      {isModalOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/50 backdrop-blur-xs">
          <div className="bg-white rounded-2xl border border-zinc-200 shadow-2xl max-w-md w-full p-6 space-y-5 animate-in fade-in zoom-in-95 duration-150">
            <div className="flex items-center justify-between pb-3 border-b border-zinc-100">
              <div className="flex items-center gap-2.5">
                <div className="w-9 h-9 rounded-xl bg-red-50 text-brand flex items-center justify-center">
                  <UserPlus className="w-5 h-5" />
                </div>
                <div>
                  <h3 className="font-bold text-zinc-900 text-sm">Daftarkan Mitra Driver</h3>
                  <p className="text-[11px] text-zinc-400">Buat akun personel untuk mengoperasikan gerobak</p>
                </div>
              </div>
              <button
                onClick={() => setIsModalOpen(false)}
                className="w-8 h-8 rounded-lg flex items-center justify-center text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100 transition-colors"
              >
                <X className="w-4 h-4" />
              </button>
            </div>

            {formError && (
              <div className="p-3 bg-red-50 border border-red-200 rounded-xl flex items-center gap-2 text-xs text-brand">
                <AlertCircle className="w-4 h-4 shrink-0" />
                <span>{formError}</span>
              </div>
            )}

            {formSuccess && (
              <div className="p-3 bg-emerald-50 border border-emerald-200 rounded-xl flex items-center gap-2 text-xs text-emerald-800">
                <CheckCircle2 className="w-4 h-4 shrink-0 text-emerald-600" />
                <span>{formSuccess}</span>
              </div>
            )}

            <form onSubmit={handleCreateDriver} className="space-y-3.5">
              <div>
                <label className="block text-xs font-bold text-zinc-700 mb-1">Nama Lengkap Driver</label>
                <input
                  type="text"
                  required
                  placeholder="Contoh: Budi Santoso"
                  value={fullName}
                  onChange={(e) => setFullName(e.target.value)}
                  className="w-full px-3.5 py-2.5 rounded-xl border border-zinc-200 text-xs focus:outline-none focus:border-brand focus:ring-2 focus:ring-red-100 transition-all font-medium"
                />
              </div>

              <div>
                <label className="block text-xs font-bold text-zinc-700 mb-1">Nomor WhatsApp / HP</label>
                <input
                  type="tel"
                  placeholder="Contoh: 08123456789"
                  value={phone}
                  onChange={(e) => setPhone(e.target.value)}
                  className="w-full px-3.5 py-2.5 rounded-xl border border-zinc-200 text-xs focus:outline-none focus:border-brand focus:ring-2 focus:ring-red-100 transition-all font-mono"
                />
              </div>

              <div>
                <label className="block text-xs font-bold text-zinc-700 mb-1">Email Login Driver</label>
                <input
                  type="email"
                  required
                  placeholder="Contoh: budi@ramujus.com"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="w-full px-3.5 py-2.5 rounded-xl border border-zinc-200 text-xs focus:outline-none focus:border-brand focus:ring-2 focus:ring-red-100 transition-all font-medium"
                />
              </div>

              <div>
                <label className="block text-xs font-bold text-zinc-700 mb-1">Kata Sandi Akun</label>
                <div className="relative">
                  <input
                    type={showPassword ? 'text' : 'password'}
                    required
                    minLength={6}
                    placeholder="Minimal 6 karakter"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    className="w-full px-3.5 py-2.5 pr-10 rounded-xl border border-zinc-200 text-xs focus:outline-none focus:border-brand focus:ring-2 focus:ring-red-100 transition-all font-mono"
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword(!showPassword)}
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-zinc-400 hover:text-zinc-600"
                  >
                    {showPassword ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                  </button>
                </div>
                <span className="text-[10px] text-zinc-400 mt-1 block">
                  Berikan email dan kata sandi ini kepada mitra driver untuk masuk ke aplikasi.
                </span>
              </div>

              <div className="pt-3 flex items-center justify-end gap-2 border-t border-zinc-100">
                <button
                  type="button"
                  onClick={() => setIsModalOpen(false)}
                  className="px-4 py-2 rounded-xl text-xs font-semibold text-zinc-600 hover:bg-zinc-100 transition-colors"
                >
                  Batal
                </button>
                <button
                  type="submit"
                  disabled={submitting}
                  className="flex items-center gap-2 bg-brand hover:bg-[#a61515] text-white px-5 py-2 rounded-xl text-xs font-bold transition-all shadow-sm shadow-red-900/15 disabled:opacity-50"
                >
                  {submitting ? (
                    <>
                      <Loader2 className="w-3.5 h-3.5 animate-spin" />
                      <span>Menyimpan...</span>
                    </>
                  ) : (
                    <span>Daftarkan Mitra</span>
                  )}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  )
}
