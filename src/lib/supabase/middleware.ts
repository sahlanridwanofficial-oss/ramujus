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

  const demoRole = request.cookies.get('ramujus_role')?.value

  // Public routes that don't require auth
  const publicPaths = ['/login', '/register', '/auth/callback']
  const isPublicPath = publicPaths.some(path =>
    request.nextUrl.pathname.startsWith(path)
  )

  // Demo mode bypass
  if (demoRole) {
    const isAdminRoute = request.nextUrl.pathname.startsWith('/admin')
    const isDriverRoute = request.nextUrl.pathname.startsWith('/driver')

    if (request.nextUrl.pathname === '/login' || request.nextUrl.pathname === '/') {
      const url = request.nextUrl.clone()
      url.pathname = demoRole === 'admin' ? '/admin/dashboard' : '/driver/dashboard'
      return NextResponse.redirect(url)
    }

    if (isAdminRoute && demoRole !== 'admin') {
      const url = request.nextUrl.clone()
      url.pathname = '/driver/dashboard'
      return NextResponse.redirect(url)
    }

    if (isDriverRoute && demoRole !== 'driver') {
      const url = request.nextUrl.clone()
      url.pathname = '/admin/dashboard'
      return NextResponse.redirect(url)
    }

    return supabaseResponse
  }

  // If not authenticated and not on public path, redirect to login
  if (!user && !isPublicPath) {
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    return NextResponse.redirect(url)
  }

  // If authenticated and on login page, redirect to appropriate dashboard
  if (user && request.nextUrl.pathname === '/login') {
    const { data: profile } = await supabase
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single()

    const url = request.nextUrl.clone()
    url.pathname = profile?.role === 'admin' ? '/admin/dashboard' : '/driver/dashboard'
    return NextResponse.redirect(url)
  }

  // Role-based route protection
  if (user) {
    const { data: profile } = await supabase
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single()

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
      url.pathname = profile?.role === 'admin' ? '/admin/dashboard' : '/driver/dashboard'
      return NextResponse.redirect(url)
    }
  }

  return supabaseResponse
}
