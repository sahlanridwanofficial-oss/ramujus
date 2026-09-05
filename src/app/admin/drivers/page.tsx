'use client'

import { useState, useEffect } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import {
  Loader2, Users, TrendingUp, ShoppingBag, UserPlus,
  X, CheckCircle2, AlertCircle, PackageCheck, Eye, EyeOff
} from 'lucide-react'
import type { Profile } from '@/types/database'

interface DriverWithStats extends Profile {
  total_orders: number
  total_revenue: number
  has_active_shift: boolean
}

/** Baris agregat dari RPC admin_driver_stats(). */
interface DriverStatsRow {
  driver_id: string
  total_orders: number
  total_revenue: number
  orders_today: number
  revenue_today: number
  has_active_shift: boolean
  last_order_at: string | null
}

export default function DriversPage() {
  const [drivers, setDrivers] = useState<DriverWithStats[]>([])
  const [loading, setLoading] = useState(true)
  const [isModalOpen, setIsModalOpen] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [showPassword, setShowPassword] = useState(false)
  const [formError, setFormError] = useState('')
  const [formSuccess, setFormSuccess] = useState('')

  // Form State
  const [fullName, setFullName] = useState('')
  const [phone, setPhone] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')

  const supabase = createClient()

  useEffect(() => {
    loadDrivers()
  }, [])

  async function loadDrivers() {
    try {
      // Versi lama menjalankan 1 + 2N query dan menarik SELURUH riwayat
      // pesanan tiap driver hanya untuk dijumlahkan di browser. Pada 100
      // mitra itu 201 query dan puluhan ribu baris per pembukaan halaman.
      // Sekarang dua query tetap, dengan agregasi dikerjakan database.
      const [{ data: profiles }, { data: stats }] = await Promise.all([
        supabase
          .from('profiles')
          .select('*')
          .eq('role', 'driver')
          .order('created_at', { ascending: false }),
        supabase.rpc('admin_driver_stats'),
      ])

      if (!profiles || profiles.length === 0) {
        setDrivers([])
        return
      }

      const statsById = new Map(
        ((stats ?? []) as DriverStatsRow[]).map(row => [row.driver_id, row])
      )

      setDrivers(
        profiles.map(driver => {
          const stat = statsById.get(driver.id)
          return {
            ...driver,
            total_orders: stat?.total_orders ?? 0,
            total_revenue: stat?.total_revenue ?? 0,
            has_active_shift: stat?.has_active_shift ?? false,
          }
        })
      )
    } catch {
      setDrivers([])
    } finally {
      setLoading(false)
    }
  }

  async function toggleStatus(driver: DriverWithStats) {
    const nextStatus = driver.status === 'active' ? 'inactive' : 'active'
    setDrivers(prev => prev.map(d => d.id === driver.id ? { ...d, status: nextStatus } : d))

    try {
      await supabase
        .from('profiles')
        .update({ status: nextStatus })
        .eq('id', driver.id)
    } catch {
      // optimistic update
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
        <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
        <span className="text-xs">Memuat data armada mitra...</span>
      </div>
    )
  }

  return (
    <div className="space-y-5">
      {/* Header with Title & Add Driver CTA */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 pb-2 border-b border-zinc-200/70">
        <div>
          <h1 className="text-2xl font-black text-zinc-900 tracking-tight">Armada Mitra Driver</h1>
          <p className="text-xs text-zinc-500 mt-0.5">Daftar personel operator gerobak keliling ramu.</p>
        </div>

        <button
          onClick={() => {
            setFormError('')
            setFormSuccess('')
            setIsModalOpen(true)
          }}
          className="flex items-center justify-center gap-2 bg-[#be1a1a] hover:bg-[#a61515] active:scale-[0.98] text-white px-4 py-2.5 rounded-xl font-bold text-xs transition-all shadow-sm shadow-red-900/15"
        >
          <UserPlus strokeWidth={2.2} className="w-4 h-4" />
          <span>Tambah Mitra Driver</span>
        </button>
      </div>

      {/* Empty State */}
      {drivers.length === 0 ? (
        <div className="bg-white rounded-2xl border border-zinc-200/80 p-12 text-center max-w-md mx-auto my-8 space-y-4">
          <div className="w-14 h-14 rounded-2xl bg-red-50 text-[#be1a1a] flex items-center justify-center mx-auto">
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
            className="inline-flex items-center gap-2 bg-[#be1a1a] hover:bg-[#a61515] text-white px-4 py-2.5 rounded-xl font-bold text-xs transition-colors"
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
                        <span className="inline-flex items-center gap-1 text-[10px] bg-red-50 text-[#be1a1a] border border-red-100 px-2 py-0.5 rounded-full font-bold">
                          <span className="w-1.5 h-1.5 rounded-full bg-[#be1a1a] animate-pulse" />
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

              {/* Driver Stats */}
              <div className="grid grid-cols-2 gap-2 pt-2 border-t border-zinc-100">
                <div className="bg-zinc-50/80 rounded-xl p-3 border border-zinc-100">
                  <div className="flex items-center gap-1.5 text-[11px] font-semibold text-zinc-400 mb-1">
                    <ShoppingBag className="w-3.5 h-3.5" />
                    <span>Total Transaksi</span>
                  </div>
                  <p className="text-base font-black text-zinc-900">{driver.total_orders} Cup</p>
                </div>

                <div className="bg-zinc-50/80 rounded-xl p-3 border border-zinc-100">
                  <div className="flex items-center gap-1.5 text-[11px] font-semibold text-zinc-400 mb-1">
                    <TrendingUp className="w-3.5 h-3.5" />
                    <span>Total Omzet</span>
                  </div>
                  <p className="text-base font-black text-[#be1a1a]">{formatRupiah(driver.total_revenue)}</p>
                </div>
              </div>

              {/* Action Quick Links */}
              <div className="pt-2 flex items-center justify-end gap-2">
                <Link
                  href={`/admin/inventory?driverId=${driver.id}`}
                  className="flex items-center gap-1.5 text-xs font-bold text-zinc-700 hover:text-[#be1a1a] bg-zinc-50 hover:bg-red-50/70 border border-zinc-200/80 hover:border-red-200 px-3 py-2 rounded-xl transition-all"
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
                <div className="w-9 h-9 rounded-xl bg-red-50 text-[#be1a1a] flex items-center justify-center">
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
              <div className="p-3 bg-red-50 border border-red-200 rounded-xl flex items-center gap-2 text-xs text-[#be1a1a]">
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
                  className="w-full px-3.5 py-2.5 rounded-xl border border-zinc-200 text-xs focus:outline-none focus:border-[#be1a1a] focus:ring-2 focus:ring-red-100 transition-all font-medium"
                />
              </div>

              <div>
                <label className="block text-xs font-bold text-zinc-700 mb-1">Nomor WhatsApp / HP</label>
                <input
                  type="tel"
                  placeholder="Contoh: 08123456789"
                  value={phone}
                  onChange={(e) => setPhone(e.target.value)}
                  className="w-full px-3.5 py-2.5 rounded-xl border border-zinc-200 text-xs focus:outline-none focus:border-[#be1a1a] focus:ring-2 focus:ring-red-100 transition-all font-mono"
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
                  className="w-full px-3.5 py-2.5 rounded-xl border border-zinc-200 text-xs focus:outline-none focus:border-[#be1a1a] focus:ring-2 focus:ring-red-100 transition-all font-medium"
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
                    className="w-full px-3.5 py-2.5 pr-10 rounded-xl border border-zinc-200 text-xs focus:outline-none focus:border-[#be1a1a] focus:ring-2 focus:ring-red-100 transition-all font-mono"
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
                  className="flex items-center gap-2 bg-[#be1a1a] hover:bg-[#a61515] text-white px-5 py-2 rounded-xl text-xs font-bold transition-all shadow-sm shadow-red-900/15 disabled:opacity-50"
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
