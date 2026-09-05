'use client'

import { useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { Eye, EyeOff, Loader2, ArrowRight } from 'lucide-react'

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

    if (email.toLowerCase() === 'admin@ramujus.com') {
      handleDemoLogin('admin')
      return
    }
    if (email.toLowerCase() === 'driver@ramujus.com') {
      handleDemoLogin('driver')
      return
    }

    try {
      const { error: authError } = await supabase.auth.signInWithPassword({
        email,
        password,
      })

      if (authError) {
        setError('Email atau password salah. Atau gunakan akun Demo di bawah.')
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
      setError('Belum terhubung ke Supabase. Gunakan tombol Uji Coba Demo di bawah.')
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="min-h-screen bg-[#FDFDFD] flex flex-col items-center justify-center p-4 sm:p-8">
      <div className="w-full max-w-[400px]">
        {/* Brand Header */}
        <div className="mb-10 text-center">
          <div className="inline-flex items-center justify-center w-12 h-12 bg-primary mb-6">
            <span className="text-white font-black text-xl tracking-tighter">RJ</span>
          </div>
          <h1 className="text-3xl font-black tracking-tight text-gray-900">
            RAMU<span className="text-primary">JUS</span>
          </h1>
          <p className="text-sm text-gray-500 mt-2 font-medium tracking-wide uppercase">
            System OS
          </p>
        </div>

        {/* Demo Mode Notice */}
        <div className="bg-white border border-gray-100 shadow-[0_8px_30px_rgb(0,0,0,0.04)] p-1 mb-8">
          <div className="bg-gray-50 px-4 py-3 border border-gray-100 text-center flex flex-col gap-3">
            <span className="text-[10px] font-bold text-gray-400 uppercase tracking-widest">
              Demo Access
            </span>
            <div className="grid grid-cols-2 gap-2">
              <button
                type="button"
                onClick={() => handleDemoLogin('driver')}
                className="bg-white hover:bg-gray-50 border border-gray-200 text-gray-700 py-2.5 px-3 text-xs font-semibold transition-all flex items-center justify-center gap-1.5 shadow-sm"
              >
                Driver App
              </button>
              <button
                type="button"
                onClick={() => handleDemoLogin('admin')}
                className="bg-primary hover:bg-primary/90 border border-primary text-white py-2.5 px-3 text-xs font-semibold transition-all flex items-center justify-center gap-1.5 shadow-sm shadow-primary/20"
              >
                Admin Panel
              </button>
            </div>
          </div>
        </div>

        {/* Main Form */}
        <form onSubmit={handleLogin} className="space-y-6">
          <div className="space-y-1">
            <label className="text-[11px] font-bold text-gray-400 uppercase tracking-wider">Email Address</label>
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="Enter your email"
              required
              className="w-full px-0 py-3 bg-transparent border-b-2 border-gray-200 text-sm focus:outline-none focus:border-primary transition-colors placeholder:text-gray-300 font-medium rounded-none"
            />
          </div>

          <div className="space-y-1">
            <label className="text-[11px] font-bold text-gray-400 uppercase tracking-wider">Password</label>
            <div className="relative">
              <input
                type={showPassword ? 'text' : 'password'}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="••••••••"
                required
                className="w-full px-0 py-3 bg-transparent border-b-2 border-gray-200 text-sm focus:outline-none focus:border-primary transition-colors placeholder:text-gray-300 font-medium rounded-none pr-10"
              />
              <button
                type="button"
                onClick={() => setShowPassword(!showPassword)}
                className="absolute right-0 top-1/2 -translate-y-1/2 text-gray-300 hover:text-gray-500 transition-colors"
              >
                {showPassword ? <EyeOff strokeWidth={1.5} className="w-4 h-4" /> : <Eye strokeWidth={1.5} className="w-4 h-4" />}
              </button>
            </div>
          </div>

          {error && (
            <div className="text-primary text-xs font-medium py-2">
              {error}
            </div>
          )}

          <button
            type="submit"
            disabled={loading}
            className="w-full bg-gray-900 hover:bg-black text-white font-semibold py-4 px-4 transition-colors disabled:opacity-50 flex items-center justify-between group shadow-[0_8px_30px_rgb(0,0,0,0.12)]"
          >
            <span className="text-sm tracking-wide">
              {loading ? 'Authenticating...' : 'Sign In'}
            </span>
            {loading ? (
              <Loader2 className="w-4 h-4 animate-spin" />
            ) : (
              <ArrowRight strokeWidth={1.5} className="w-4 h-4 opacity-50 group-hover:opacity-100 group-hover:translate-x-1 transition-all" />
            )}
          </button>
        </form>

        <div className="mt-12 text-center">
          <p className="text-[10px] font-bold text-gray-300 uppercase tracking-widest">
            RAMUJUS OS v1.0
          </p>
        </div>
      </div>
    </div>
  )
}
