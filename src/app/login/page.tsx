'use client'

import { useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { Leaf, Eye, EyeOff, Loader2 } from 'lucide-react'

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

    // Check for demo shortcut accounts
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

      // Get role and redirect
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
    <div className="min-h-screen bg-gradient-to-br from-green-50 via-white to-emerald-50 flex items-center justify-center p-4">
      <div className="w-full max-w-sm">
        {/* Logo */}
        <div className="text-center mb-6">
          <div className="inline-flex items-center justify-center w-16 h-16 bg-primary rounded-2xl mb-3 shadow-lg shadow-green-200">
            <Leaf className="w-8 h-8 text-white" />
          </div>
          <h1 className="text-2xl font-bold text-gray-900">RAMUJUS</h1>
          <p className="text-sm text-muted-foreground mt-0.5">Smoothie Sales System</p>
        </div>

        {/* Quick Demo Login Cards */}
        <div className="bg-white rounded-2xl shadow-sm border p-4 mb-4">
          <p className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-2.5 text-center">
            ⚡ Akses Cepat Uji Coba (Demo)
          </p>
          <div className="grid grid-cols-2 gap-2">
            <button
              type="button"
              onClick={() => handleDemoLogin('driver')}
              className="bg-emerald-50 hover:bg-emerald-100 border border-emerald-200 text-emerald-700 py-2 px-3 rounded-xl text-xs font-semibold transition-all text-center"
            >
              🛵 Masuk Driver
            </button>
            <button
              type="button"
              onClick={() => handleDemoLogin('admin')}
              className="bg-slate-50 hover:bg-slate-100 border border-slate-200 text-slate-700 py-2 px-3 rounded-xl text-xs font-semibold transition-all text-center"
            >
              📊 Masuk Admin
            </button>
          </div>
        </div>

        {/* Form */}
        <form onSubmit={handleLogin} className="bg-white rounded-2xl shadow-sm border p-6 space-y-4">
          <div>
            <label className="text-sm font-medium text-gray-700 block mb-1.5">Email</label>
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="driver@ramujus.com"
              required
              className="w-full px-3.5 py-2.5 bg-gray-50 border border-gray-200 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary transition-colors"
            />
          </div>

          <div>
            <label className="text-sm font-medium text-gray-700 block mb-1.5">Password</label>
            <div className="relative">
              <input
                type={showPassword ? 'text' : 'password'}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="••••••••"
                required
                className="w-full px-3.5 py-2.5 bg-gray-50 border border-gray-200 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary transition-colors pr-10"
              />
              <button
                type="button"
                onClick={() => setShowPassword(!showPassword)}
                className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 hover:text-gray-600"
              >
                {showPassword ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
              </button>
            </div>
          </div>

          {error && (
            <div className="bg-red-50 text-red-600 text-xs px-3.5 py-2.5 rounded-xl">
              {error}
            </div>
          )}

          <button
            type="submit"
            disabled={loading}
            className="w-full bg-primary hover:bg-primary/90 text-white font-medium py-2.5 px-4 rounded-xl transition-colors disabled:opacity-50 flex items-center justify-center gap-2"
          >
            {loading ? (
              <>
                <Loader2 className="w-4 h-4 animate-spin" />
                Masuk...
              </>
            ) : (
              'Masuk Akun'
            )}
          </button>
        </form>

        <p className="text-center text-xs text-muted-foreground mt-6">
          &copy; 2026 RAMUJUS. All rights reserved.
        </p>
      </div>
    </div>
  )
}
