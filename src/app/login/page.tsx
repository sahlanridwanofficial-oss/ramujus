'use client'

import { Suspense, useEffect, useState } from 'react'
import { useSearchParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import Logo from '@/components/ui/Logo'
import { Eye, EyeOff, Loader2, ArrowRight, Ban } from 'lucide-react'

/** Alasan sebuah sesi ditolak middleware, dan penjelasannya untuk pengguna. */
const ACCOUNT_NOTICE: Record<string, { title: string; body: string }> = {
  nonaktif: {
    title: 'Akun dinonaktifkan',
    body: 'Akun Anda sedang dinonaktifkan oleh admin, jadi tidak dapat membuka shift maupun mencatat penjualan. Hubungi admin pangkalan untuk mengaktifkannya kembali.',
  },
  'tanpa-profil': {
    title: 'Akun belum lengkap',
    body: 'Akun Anda ada, tetapi belum memiliki profil di sistem, jadi belum bisa dipakai. Hubungi admin pangkalan untuk melengkapinya.',
  },
}

function LoginForm() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [showPassword, setShowPassword] = useState(false)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState<{ title: string; body: string } | null>(null)
  const searchParams = useSearchParams()
  const supabase = createClient()

  // Middleware melempar sesi yang ditolak ke sini dengan ?akun=<alasan>.
  // Sesinya ditutup supaya orang itu tidak terus dipantulkan bolak-balik
  // tanpa penjelasan setiap kali membuka aplikasi.
  useEffect(() => {
    const reason = searchParams.get('akun')
    if (!reason || !ACCOUNT_NOTICE[reason]) return
    setNotice(ACCOUNT_NOTICE[reason])
    supabase.auth.signOut().catch(() => {})
  }, [searchParams, supabase])

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault()
    setLoading(true)
    setError('')

    try {
      const { error: authError } = await supabase.auth.signInWithPassword({
        email,
        password,
      })

      if (authError) {
        setError('Email atau kata sandi tidak sesuai. Silakan periksa kembali.')
        return
      }

      const { data: { user } } = await supabase.auth.getUser()
      if (!user) {
        setError('Sesi gagal dibuat. Silakan coba masuk lagi.')
        return
      }

      const { data: profile, error: profileError } = await supabase
        .from('profiles')
        .select('role, status')
        .eq('id', user.id)
        .single()

      if (profileError || !profile) {
        setError('Akun Anda belum memiliki profil aktif. Hubungi admin.')
        return
      }

      // Ditolak di sini, bukan dibiarkan masuk lalu dipantulkan middleware:
      // driver berhak tahu sebabnya di layar tempat ia menekan "Masuk".
      if (profile.status !== 'active') {
        await supabase.auth.signOut().catch(() => {})
        setNotice(ACCOUNT_NOTICE.nonaktif)
        setError('')
        return
      }

      window.location.href = profile.role === 'admin'
        ? '/admin/dashboard'
        : '/driver/dashboard'
    } catch {
      setError('Tidak dapat terhubung ke server. Periksa koneksi Anda lalu coba lagi.')
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="min-h-screen bg-[#FBFBFB] flex flex-col items-center justify-center p-4 sm:p-6 text-zinc-900">
      <div className="w-full max-w-[420px]">
        {/* Brand Header with Official Logo */}
        <div className="mb-8 text-center flex flex-col items-center">
          <Logo height={44} className="mb-4 drop-shadow-sm" />
          <h1 className="text-xl font-bold tracking-tight text-zinc-900">
            Sistem Operasional Penjualan
          </h1>
          <p className="text-xs text-zinc-500 mt-1">
            Masuk ke akun Mitra Driver atau Panel Administrasi
          </p>
        </div>

        {/* Akun dinonaktifkan admin — dijelaskan di luar kotak error biasa,
            karena ini bukan salah ketik yang bisa diperbaiki sendiri. */}
        {notice && (
          <div
            role="alert"
            className="mb-4 p-4 bg-amber-50 border border-amber-300 rounded-2xl flex items-start gap-3"
          >
            <Ban strokeWidth={2} className="w-5 h-5 text-amber-600 shrink-0 mt-px" />
            <div>
              <p className="text-xs font-bold text-amber-900">{notice.title}</p>
              <p className="text-[11px] text-amber-800/90 mt-0.5 leading-relaxed">
                {notice.body}
              </p>
            </div>
          </div>
        )}

        {/* Main Card Form */}
        <div className="bg-white border border-zinc-200/80 rounded-2xl p-6 sm:p-7 shadow-card">
          <form onSubmit={handleLogin} className="space-y-4">
            <div>
              <label className="block text-xs font-semibold text-zinc-700 mb-1.5">
                Email
              </label>
              <input
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="nama@ramu.id"
                required
                className="w-full px-3.5 py-2.5 bg-zinc-50/50 border border-zinc-200 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-[#be1a1a]/20 focus:border-[#be1a1a] focus:bg-white transition-all text-zinc-900 placeholder:text-zinc-400"
              />
            </div>

            <div>
              <div className="flex items-center justify-between mb-1.5">
                <label className="block text-xs font-semibold text-zinc-700">
                  Kata Sandi
                </label>
              </div>
              <div className="relative">
                <input
                  type={showPassword ? 'text' : 'password'}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••"
                  required
                  className="w-full px-3.5 py-2.5 bg-zinc-50/50 border border-zinc-200 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-[#be1a1a]/20 focus:border-[#be1a1a] focus:bg-white transition-all text-zinc-900 placeholder:text-zinc-400 pr-10"
                />
                <button
                  type="button"
                  onClick={() => setShowPassword(!showPassword)}
                  className="absolute right-3 top-1/2 -translate-y-1/2 text-zinc-400 hover:text-zinc-600 transition-colors p-1"
                >
                  {showPassword ? (
                    <EyeOff strokeWidth={1.75} className="w-4 h-4" />
                  ) : (
                    <Eye strokeWidth={1.75} className="w-4 h-4" />
                  )}
                </button>
              </div>
            </div>

            {error && (
              <div className="p-3 bg-red-50 border border-red-100 rounded-xl text-xs text-[#be1a1a] font-medium leading-relaxed">
                {error}
              </div>
            )}

            <button
              type="submit"
              disabled={loading}
              className="w-full bg-[#be1a1a] hover:bg-[#a61515] active:scale-[0.99] text-white font-semibold py-3 px-4 rounded-xl transition-all disabled:opacity-50 flex items-center justify-center gap-2 shadow-sm shadow-red-900/20 mt-2"
            >
              {loading ? (
                <>
                  <Loader2 className="w-4 h-4 animate-spin" />
                  <span>Memverifikasi...</span>
                </>
              ) : (
                <>
                  <span>Masuk ke Akun</span>
                  <ArrowRight strokeWidth={2} className="w-4 h-4" />
                </>
              )}
            </button>
          </form>
        </div>

        {/* Footer */}
        <div className="mt-8 text-center">
          <p className="text-[11px] text-zinc-400 font-medium">
            &copy; 2026 ramu. All rights reserved.
          </p>
        </div>
      </div>
    </div>
  )
}

// useSearchParams membutuhkan batas Suspense agar halaman ini tetap dapat
// dirender statis saat build.
export default function LoginPage() {
  return (
    <Suspense
      fallback={
        <div className="min-h-screen bg-[#FBFBFB] flex items-center justify-center">
          <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
        </div>
      }
    >
      <LoginForm />
    </Suspense>
  )
}
