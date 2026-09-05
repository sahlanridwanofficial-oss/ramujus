import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'

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

  // Public routes that don't require auth
  const publicPaths = ['/login', '/register', '/auth/callback']
  const isPublicPath = publicPaths.some(path =>
    request.nextUrl.pathname.startsWith(path)
  )

  // If not authenticated and not on public path, redirect to login
  if (!user && !isPublicPath) {
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    return NextResponse.redirect(url)
  }

  // Role-based route protection. Profil dibaca sekali saja per request —
  // sebelumnya query yang sama dijalankan dua kali pada halaman login.
  if (user) {
    const { data: profile } = await supabase
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single()

    const homePath = profile?.role === 'admin' ? '/admin/dashboard' : '/driver/dashboard'

    // Sudah masuk tapi membuka halaman login → lempar ke dashboard-nya.
    if (request.nextUrl.pathname === '/login') {
      const url = request.nextUrl.clone()
      url.pathname = homePath
      return NextResponse.redirect(url)
    }

    const isAdminRoute = request.nextUrl.pathname.startsWith('/admin')
    const isDriverRoute = request.nextUrl.pathname.startsWith('/driver')

    if (isAdminRoute && profile?.role !== 'admin') {
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
    if (request.nextUrl.pathname === '/') {
      const url = request.nextUrl.clone()
      url.pathname = homePath
      return NextResponse.redirect(url)
    }
  }

  return supabaseResponse
}
