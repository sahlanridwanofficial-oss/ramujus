'use client'

import { useAuth } from '@/hooks/useAuth'
import { Loader2, User, Phone, Mail, Shield } from 'lucide-react'

export default function ProfilePage() {
  const { user, loading, signOut } = useAuth()

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 className="w-6 h-6 animate-spin text-primary" />
      </div>
    )
  }

  return (
    <div className="p-4 space-y-4">
      <h1 className="font-bold text-gray-900 text-lg">Profil</h1>

      <div className="bg-white rounded-2xl border p-6 text-center">
        <div className="w-16 h-16 bg-primary/10 rounded-full flex items-center justify-center mx-auto mb-3">
          <User className="w-8 h-8 text-primary" />
        </div>
        <h2 className="text-lg font-bold text-gray-900">{user?.full_name}</h2>
        <span className="inline-block mt-1 px-3 py-0.5 bg-primary/10 text-primary rounded-full text-xs font-medium capitalize">
          {user?.role}
        </span>
      </div>

      <div className="bg-white rounded-2xl border divide-y">
        <div className="px-4 py-3.5 flex items-center gap-3">
          <div className="w-9 h-9 bg-blue-50 rounded-lg flex items-center justify-center">
            <Phone className="w-4 h-4 text-blue-600" />
          </div>
          <div>
            <p className="text-xs text-muted-foreground">Telepon</p>
            <p className="text-sm font-medium text-gray-900">{user?.phone || '-'}</p>
          </div>
        </div>
        <div className="px-4 py-3.5 flex items-center gap-3">
          <div className="w-9 h-9 bg-emerald-50 rounded-lg flex items-center justify-center">
            <Shield className="w-4 h-4 text-emerald-600" />
          </div>
          <div>
            <p className="text-xs text-muted-foreground">Status</p>
            <p className="text-sm font-medium text-green-600 capitalize">{user?.status}</p>
          </div>
        </div>
      </div>

      <button
        onClick={signOut}
        className="w-full bg-red-50 text-red-600 font-medium py-3 rounded-xl hover:bg-red-100 transition-colors"
      >
        Keluar
      </button>
    </div>
  )
}
