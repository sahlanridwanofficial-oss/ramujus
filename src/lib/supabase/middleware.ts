import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'

/** Rute yang boleh diakses tanpa sesi. */
const PUBLIC_PATHS = ['/login', '/register', '/auth/callback']

/**
 * Penolakan untuk rute API dikirim sebagai JSON, bukan pengalihan.
 *
 * Pengalihan pada permintaan POST diubah browser menjadi GET ke halaman
 * masuk, lalu mengembalikan HTML dengan status 200 — pemanggilnya membaca
 * itu sebagai keberhasilan. Rute API harus menjawab dengan kode statusnya
 * sendiri supaya kegagalan otorisasi terlihat sebagai kegagalan.
 */
function denyApi(status: number, message: string) {
  return NextResponse.json({ error: message }, { status })
}

export async function updateSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request })

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll()
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value)
          )
          supabaseResponse = NextResponse.next({ request })
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options)
          )
        },
      },
    }
  )

  const {
    data: { user },
  } = await supabase.auth.getUser()

  const pathname = request.nextUrl.pathname
  const isApiRoute = pathname.startsWith('/api')
  const isPublicPath = PUBLIC_PATHS.some(path => pathname.startsWith(path))

  if (!user && !isPublicPath) {
    if (isApiRoute) return denyApi(401, 'Anda harus masuk terlebih dahulu.')
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    return NextResponse.redirect(url)
  }

  // Role-based route protection. Profil dibaca sekali saja per request —
  // sebelumnya query yang sama dijalankan dua kali pada halaman login.
  if (user) {
    const { data: profile } = await supabase
      .from('profiles')
      .select('role, status')
      .eq('id', user.id)
      .single()

    const homePath = profile?.role === 'admin' ? '/admin/dashboard' : '/driver/dashboard'

    // Akun yang dinonaktifkan admin diperlakukan seperti tidak berhak sama
    // sekali. Diperiksa sebelum aturan peran, supaya tidak ada halaman
    // operasional yang sempat terbuka. Halaman masuk sengaja dibiarkan
    // lewat: di sanalah alasannya dijelaskan, dan tanpa pengecualian ini
    // pengalihannya berputar tanpa henti.
    //
    // Sesi tanpa baris profil ditangani di cabang yang sama. Sebelumnya
    // keadaan itu jatuh ke aturan peran di bawah, yang melempar akun ke
    // /driver/dashboard lalu ke /admin/dashboard bergantian — berputar
    // tanpa henti dan tidak mungkin dilaporkan penggunanya.
    const accountIssue = !profile
      ? 'tanpa-profil'
      : profile.status !== 'active'
      ? 'nonaktif'
      : null

    if (accountIssue) {
      if (isApiRoute) {
        return denyApi(403, accountIssue === 'nonaktif'
          ? 'Akun Anda sedang dinonaktifkan.'
          : 'Akun Anda belum memiliki profil.')
      }
      if (pathname !== '/login') {
        const url = request.nextUrl.clone()
        url.pathname = '/login'
        url.search = ''
        url.searchParams.set('akun', accountIssue)
        return NextResponse.redirect(url)
      }
      return supabaseResponse
    }

    // Sudah masuk tapi membuka halaman login → lempar ke dashboard-nya.
    if (pathname === '/login') {
      const url = request.nextUrl.clone()
      url.pathname = homePath
      url.search = ''
      return NextResponse.redirect(url)
    }

    // /api/admin adalah rute admin, sama seperti /admin. Sebelumnya hanya
    // awalan '/admin' yang dijaga, sehingga endpoint di bawah /api/admin
    // terbuka untuk setiap akun yang sudah masuk — termasuk driver.
    const isAdminRoute = pathname.startsWith('/admin') || pathname.startsWith('/api/admin')
    const isDriverRoute = pathname.startsWith('/driver')

    if (isAdminRoute && profile?.role !== 'admin') {
      if (isApiRoute) return denyApi(403, 'Hanya admin yang boleh mengakses ini.')
      const url = request.nextUrl.clone()
      url.pathname = '/driver/dashboard'
      return NextResponse.redirect(url)
    }

    if (isDriverRoute && profile?.role !== 'driver') {
      const url = request.nextUrl.clone()
      url.pathname = '/admin/dashboard'
      return NextResponse.redirect(url)
    }

    // Root path redirect
    if (pathname === '/') {
      const url = request.nextUrl.clone()
      url.pathname = homePath
      return NextResponse.redirect(url)
    }
  }

  return supabaseResponse
}
