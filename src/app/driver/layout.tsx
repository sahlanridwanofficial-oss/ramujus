'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useAuth } from '@/hooks/useAuth'
import Logo from '@/components/ui/Logo'
import { LayoutGrid, PlusCircle, History, User, LogOut } from 'lucide-react'

const navItems = [
  { href: '/driver/dashboard', icon: LayoutGrid, label: 'Beranda' },
  { href: '/driver/order', icon: PlusCircle, label: 'Pesanan' },
  { href: '/driver/history', icon: History, label: 'Riwayat' },
  { href: '/driver/profile', icon: User, label: 'Profil' },
]

export default function DriverLayout({ children }: { children: React.ReactNode }) {
  const pathname = usePathname()
  const { user, signOut } = useAuth()

  return (
    <div className="min-h-screen bg-[#FAF9F6] flex flex-col antialiased text-zinc-900">
      {/* Top Header */}
      <header className="bg-white/95 backdrop-blur border-b border-zinc-200/80 sticky top-0 z-40">
        <div className="flex items-center justify-between px-4 h-14 max-w-lg mx-auto w-full">
          <Link href="/driver/dashboard" className="flex items-center hover:opacity-95 transition-opacity">
            <Logo height={26} />
          </Link>

          <div className="flex items-center gap-2.5">
            <div className="flex items-center gap-1.5 bg-zinc-100/80 px-2.5 py-1 rounded-full text-xs font-medium text-zinc-700">
              <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse" />
              <span className="max-w-[110px] truncate">{user?.full_name?.split(' ')[0] || 'Driver'}</span>
            </div>
            <button
              onClick={signOut}
              title="Keluar"
              className="w-8 h-8 flex items-center justify-center text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100 rounded-lg transition-colors"
            >
              <LogOut strokeWidth={1.75} className="w-4 h-4" />
            </button>
          </div>
        </div>
      </header>

      {/* Main Content Area */}
      <main className="flex-1 pb-24 max-w-lg mx-auto w-full">
        {children}
      </main>

      {/* Modern Bottom Floating Navigation Bar */}
      <nav className="fixed bottom-0 left-0 right-0 bg-white/95 backdrop-blur border-t border-zinc-200/80 z-50 pb-safe">
        <div className="flex items-center justify-around h-16 max-w-lg mx-auto px-2">
          {navItems.map(({ href, icon: Icon, label }) => {
            const isActive = pathname === href
            return (
              <Link
                key={href}
                href={href}
                className={`relative flex flex-col items-center justify-center flex-1 py-1 transition-all ${
                  isActive
                    ? 'text-[#be1a1a]'
                    : 'text-zinc-400 hover:text-zinc-600'
                }`}
              >
                <div className="relative">
                  <Icon
                    strokeWidth={isActive ? 2.2 : 1.75}
                    className={`w-5 h-5 transition-transform duration-200 ${isActive ? 'scale-110' : ''}`}
                  />
                  {isActive && (
                    <span className="absolute -top-1 -right-1 w-1.5 h-1.5 rounded-full bg-[#be1a1a]" />
                  )}
                </div>
                <span className={`text-[10px] mt-1 tracking-tight ${isActive ? 'font-bold' : 'font-medium'}`}>
                  {label}
                </span>
              </Link>
            )
          })}
        </div>
      </nav>
    </div>
  )
}
