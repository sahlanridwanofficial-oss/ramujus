'use client'

import { useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import Logo from '@/components/ui/Logo'
import { Eye, EyeOff, Loader2, ArrowRight, ShieldCheck, Bike } from 'lucide-react'

export default function LoginPage() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [showPassword, setShowPassword] = useState(false)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const supabase = createClient()

  const handleDemoLogin = (role: 'driver' | 'admin') => {
    document.cookie = `ramujus_role=${role}; path=/; max-age=86400`
    window.location.href = role === 'admin' ? '/admin/dashboard' : '/driver/dashboard'
  }

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault()
    setLoading(true)
    setError('')

    if (email.toLowerCase() === 'admin@ramujus.com' || email.toLowerCase() === 'admin@ramu.id') {
      handleDemoLogin('admin')
      return
    }
    if (email.toLowerCase() === 'driver@ramujus.com' || email.toLowerCase() === 'driver@ramu.id') {
      handleDemoLogin('driver')
      return
    }

    try {
      const { error: authError } = await supabase.auth.signInWithPassword({
        email,
        password,
      })

      if (authError) {
        setError('Email atau kata sandi tidak sesuai. Silakan coba lagi atau gunakan akses Demo.')
        return
      }

      const { data: { user } } = await supabase.auth.getUser()
      if (user) {
        const { data: profile } = await supabase
          .from('profiles')
          .select('role')
          .eq('id', user.id)
          .single()

        window.location.href = profile?.role === 'admin'
          ? '/admin/dashboard'
          : '/driver/dashboard'
      }
    } catch {
      setError('Sistem belum terhubung ke Supabase. Silakan gunakan akses Demo instan di bawah.')
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

        {/* Quick Demo Access Pills */}
        <div className="bg-white border border-zinc-200/80 rounded-2xl p-4 shadow-sm mb-6">
          <div className="flex items-center justify-between mb-3 px-1">
            <span className="text-[11px] font-semibold tracking-wider text-zinc-400 uppercase">
              Akses Cepat Demo
            </span>
            <span className="text-[10px] font-medium text-emerald-600 bg-emerald-50 px-2 py-0.5 rounded-full">
              Instan
            </span>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <button
              type="button"
              onClick={() => handleDemoLogin('driver')}
              className="flex items-center justify-center gap-2 bg-zinc-50 hover:bg-zinc-100/80 border border-zinc-200 text-zinc-800 py-2.5 px-3 rounded-xl text-xs font-semibold transition-all group"
            >
              <Bike className="w-4 h-4 text-zinc-600 group-hover:text-[#be1a1a] transition-colors" />
              <span>Mitra Driver</span>
            </button>
            <button
              type="button"
              onClick={() => handleDemoLogin('admin')}
              className="flex items-center justify-center gap-2 bg-[#be1a1a] hover:bg-[#a61515] text-white py-2.5 px-3 rounded-xl text-xs font-semibold transition-all shadow-sm shadow-red-900/20"
            >
              <ShieldCheck className="w-4 h-4" />
              <span>Admin Panel</span>
            </button>
          </div>
        </div>

        {/* Main Card Form */}
        <div className="bg-white border border-zinc-200/80 rounded-2xl p-6 sm:p-7 shadow-sm">
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
