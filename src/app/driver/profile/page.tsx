'use client'

import { useAuth } from '@/hooks/useAuth'
import { Loader2, User, Phone, Shield, LogOut, CheckCircle2, Bike } from 'lucide-react'

export default function ProfilePage() {
  const { user, loading, signOut } = useAuth()

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-64 gap-2 text-zinc-400">
        <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
        <span className="text-xs">Memuat profil...</span>
      </div>
    )
  }

  return (
    <div className="p-4 space-y-4">
      <div>
        <h1 className="font-black text-xl text-zinc-900 tracking-tight">Profil Pengguna</h1>
        <p className="text-xs text-zinc-500 mt-0.5">Informasi akun operasional mitra</p>
      </div>

      {/* Driver Card Header */}
      <div className="bg-white rounded-3xl border border-zinc-200/80 p-6 text-center shadow-sm">
        <div className="w-16 h-16 bg-zinc-900 text-white rounded-2xl flex items-center justify-center mx-auto mb-3 text-lg font-black shadow-sm">
          {user?.full_name?.charAt(0) || 'M'}
        </div>
        <h2 className="text-base font-bold text-zinc-900">{user?.full_name}</h2>
        <div className="flex items-center justify-center gap-2 mt-1">
          <span className="inline-flex items-center gap-1 px-2.5 py-0.5 bg-red-50 text-[#be1a1a] border border-red-100 rounded-full text-[11px] font-bold uppercase tracking-wider">
            <Bike className="w-3 h-3" />
            Mitra {user?.role || 'Driver'}
          </span>
          <span className="inline-flex items-center gap-1 px-2.5 py-0.5 bg-emerald-50 text-emerald-700 border border-emerald-100 rounded-full text-[11px] font-medium">
            <CheckCircle2 className="w-3 h-3 text-emerald-600" />
            {user?.status === 'active' ? 'Aktif' : 'Terdaftar'}
          </span>
        </div>
      </div>

      {/* Account Details */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 divide-y divide-zinc-100 shadow-sm">
        <div className="px-4 py-3.5 flex items-center gap-3">
          <div className="w-8 h-8 bg-zinc-100 rounded-xl flex items-center justify-center text-zinc-600">
            <User className="w-4 h-4" />
          </div>
          <div className="flex-1">
            <span className="text-[10px] font-bold text-zinc-400 uppercase tracking-wider block">ID Mitra</span>
            <p className="text-xs font-mono font-semibold text-zinc-800">{user?.id?.slice(0, 16)}...</p>
          </div>
        </div>

        <div className="px-4 py-3.5 flex items-center gap-3">
          <div className="w-8 h-8 bg-zinc-100 rounded-xl flex items-center justify-center text-zinc-600">
            <Phone className="w-4 h-4" />
          </div>
          <div className="flex-1">
            <span className="text-[10px] font-bold text-zinc-400 uppercase tracking-wider block">Nomor Telepon</span>
            <p className="text-xs font-semibold text-zinc-800">{user?.phone || '0812-3456-7890'}</p>
          </div>
        </div>

        <div className="px-4 py-3.5 flex items-center gap-3">
          <div className="w-8 h-8 bg-zinc-100 rounded-xl flex items-center justify-center text-zinc-600">
            <Shield className="w-4 h-4" />
          </div>
          <div className="flex-1">
            <span className="text-[10px] font-bold text-zinc-400 uppercase tracking-wider block">Tipe Hak Akses</span>
            <p className="text-xs font-semibold text-zinc-800">POS Cart Mobile System</p>
          </div>
        </div>
      </div>

      {/* Logout Button */}
      <button
        onClick={signOut}
        className="w-full flex items-center justify-center gap-2 bg-white hover:bg-red-50 text-[#be1a1a] border border-red-200 font-semibold py-3 rounded-xl transition-all shadow-xs text-xs"
      >
        <LogOut className="w-4 h-4" />
        <span>Keluar dari Akun</span>
      </button>
    </div>
  )
}
