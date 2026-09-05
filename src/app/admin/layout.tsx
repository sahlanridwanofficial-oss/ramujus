'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useAuth } from '@/hooks/useAuth'
import Logo from '@/components/ui/Logo'
import {
  LayoutGrid, BarChart3, Map, Package, Users,
  FileText, LogOut, Menu, X, ShieldCheck, PackageCheck
} from 'lucide-react'
import { useState } from 'react'

const navItems = [
  { href: '/admin/dashboard', icon: LayoutGrid, label: 'Dashboard' },
  { href: '/admin/analytics', icon: BarChart3, label: 'Analitik' },
  { href: '/admin/inventory', icon: PackageCheck, label: 'Stok Gerobak' },
  { href: '/admin/map', icon: Map, label: 'Peta Lokasi' },
  { href: '/admin/products', icon: Package, label: 'Menu Produk' },
  { href: '/admin/drivers', icon: Users, label: 'Mitra Driver' },
  { href: '/admin/reports', icon: FileText, label: 'Laporan Penjualan' },
]

export default function AdminLayout({ children }: { children: React.ReactNode }) {
  const pathname = usePathname()
  const { user, signOut } = useAuth()
  const [sidebarOpen, setSidebarOpen] = useState(false)

  return (
    <div className="min-h-screen bg-[#FAF9F6] flex text-zinc-900 antialiased">
      {/* Sidebar - Desktop */}
      <aside className="hidden lg:flex lg:flex-col lg:w-60 bg-white border-r border-zinc-200/80 fixed inset-y-0 z-40">
        <div className="flex items-center px-6 h-16 border-b border-zinc-200/80">
          <Link href="/admin/dashboard" className="flex items-center">
            <Logo height={28} />
          </Link>
        </div>

        <nav className="flex-1 px-3 py-4 space-y-1 overflow-y-auto">
          <div className="px-3 pb-2">
            <span className="text-[10px] font-bold uppercase tracking-wider text-zinc-400">
              Navigasi Utama
            </span>
          </div>
          {navItems.map(({ href, icon: Icon, label }) => {
            const isActive = pathname === href
            return (
              <Link
                key={href}
                href={href}
                className={`flex items-center gap-3 px-3 py-2.5 rounded-xl text-xs font-semibold transition-all ${
                  isActive
                    ? 'bg-red-50 text-[#be1a1a] shadow-xs'
                    : 'text-zinc-600 hover:bg-zinc-100/70 hover:text-zinc-900'
                }`}
              >
                <Icon strokeWidth={isActive ? 2.2 : 1.75} className="w-4 h-4" />
                <span>{label}</span>
              </Link>
            )
          })}
        </nav>

        {/* User Profile Info at Bottom */}
        <div className="p-3 border-t border-zinc-200/80">
          <div className="flex items-center gap-2.5 px-3 py-2 bg-zinc-50 rounded-xl border border-zinc-100 mb-2">
            <div className="w-8 h-8 rounded-lg bg-[#be1a1a] text-white flex items-center justify-center font-bold text-xs shrink-0">
              {user?.full_name?.charAt(0) || 'A'}
            </div>
            <div className="flex-1 min-w-0">
              <p className="text-xs font-bold text-zinc-900 truncate leading-tight">{user?.full_name}</p>
              <div className="flex items-center gap-1 mt-0.5">
                <ShieldCheck className="w-3 h-3 text-[#be1a1a]" />
                <span className="text-[10px] text-zinc-400 font-medium">Administrator</span>
              </div>
            </div>
          </div>
          <button
            onClick={signOut}
            className="flex items-center justify-center gap-2 px-3 py-2 text-xs font-semibold text-zinc-600 hover:text-[#be1a1a] hover:bg-red-50 rounded-xl w-full transition-colors"
          >
            <LogOut strokeWidth={1.75} className="w-4 h-4" />
            <span>Keluar Akun</span>
          </button>
        </div>
      </aside>

      {/* Mobile Sidebar Overlay */}
      {sidebarOpen && (
        <div className="fixed inset-0 z-50 lg:hidden">
          <div className="fixed inset-0 bg-black/40 backdrop-blur-xs" onClick={() => setSidebarOpen(false)} />
          <aside className="fixed inset-y-0 left-0 w-64 bg-white z-50 shadow-2xl flex flex-col">
            <div className="flex items-center justify-between px-5 h-16 border-b border-zinc-200/80">
              <Logo height={26} />
              <button
                onClick={() => setSidebarOpen(false)}
                className="w-8 h-8 rounded-lg flex items-center justify-center text-zinc-400 hover:text-zinc-600 hover:bg-zinc-100"
              >
                <X strokeWidth={2} className="w-4 h-4" />
              </button>
            </div>
            <nav className="p-3 space-y-1 flex-1 overflow-y-auto">
              {navItems.map(({ href, icon: Icon, label }) => {
                const isActive = pathname === href
                return (
                  <Link
                    key={href}
                    href={href}
                    onClick={() => setSidebarOpen(false)}
                    className={`flex items-center gap-3 px-3 py-2.5 rounded-xl text-xs font-semibold transition-all ${
                      isActive
                        ? 'bg-red-50 text-[#be1a1a]'
                        : 'text-zinc-600 hover:bg-zinc-50'
                    }`}
                  >
                    <Icon strokeWidth={isActive ? 2.2 : 1.75} className="w-4 h-4" />
                    <span>{label}</span>
                  </Link>
                )
              })}
            </nav>
            <div className="p-4 border-t border-zinc-200">
              <button
                onClick={signOut}
                className="flex items-center justify-center gap-2 px-3 py-2.5 text-xs font-semibold text-red-600 bg-red-50 rounded-xl w-full"
              >
                <LogOut strokeWidth={1.75} className="w-4 h-4" />
                <span>Keluar Akun</span>
              </button>
            </div>
          </aside>
        </div>
      )}

      {/* Main Content Area */}
      <div className="flex-1 lg:ml-60 flex flex-col min-w-0">
        {/* Mobile Header */}
        <header className="lg:hidden bg-white border-b border-zinc-200/80 sticky top-0 z-30">
          <div className="flex items-center justify-between px-4 h-14">
            <button
              onClick={() => setSidebarOpen(true)}
              className="w-9 h-9 flex items-center justify-center text-zinc-600 hover:bg-zinc-100 rounded-lg transition-colors"
            >
              <Menu strokeWidth={2} className="w-5 h-5" />
            </button>
            <Logo height={24} />
            <div className="w-9" />
          </div>
        </header>

        <main className="p-4 lg:p-7 max-w-7xl w-full mx-auto">
          {children}
        </main>
      </div>
    </div>
  )
}
