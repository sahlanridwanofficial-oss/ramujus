import { NextResponse } from 'next/server'
import { createClient } from '@supabase/supabase-js'

export async function POST(request: Request) {
  try {
    const { full_name, phone, email, password } = await request.json()

    if (!full_name || !email || !password) {
      return NextResponse.json(
        { error: 'Nama lengkap, email, dan kata sandi wajib diisi.' },
        { status: 400 }
      )
    }

    if (password.length < 6) {
      return NextResponse.json(
        { error: 'Kata sandi minimal 6 karakter.' },
        { status: 400 }
      )
    }

    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
    const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY
    const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

    // 1. If service role key is available, create user directly via Admin API
    if (supabaseUrl && serviceRoleKey) {
      const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
        auth: { autoRefreshToken: false, persistSession: false }
      })

      const { data: authData, error: authError } = await supabaseAdmin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: {
          full_name,
          phone,
          role: 'driver'
        }
      })

      if (authError) {
        return NextResponse.json({ error: authError.message }, { status: 400 })
      }

      if (authData?.user) {
        // Upsert profile to ensure record exists
        await supabaseAdmin.from('profiles').upsert({
          id: authData.user.id,
          full_name,
          phone: phone || null,
          role: 'driver',
          status: 'active',
          updated_at: new Date().toISOString()
        })

        return NextResponse.json({
          success: true,
          message: 'Mitra driver berhasil didaftarkan.',
          user: {
            id: authData.user.id,
            full_name,
            phone,
            email
          }
        })
      }
    }

    // 2. Fallback: using anon client signUp.
    //    Peran TIDAK dikirim lewat metadata — trigger handle_new_user
    //    selalu menetapkan 'driver', karena metadata dapat dipalsukan
    //    oleh siapa pun yang memegang anon key.
    if (supabaseUrl && anonKey) {
      const supabase = createClient(supabaseUrl, anonKey)
      const { data: authData, error: authError } = await supabase.auth.signUp({
        email,
        password,
        options: {
          data: { full_name, phone }
        }
      })

      if (authError) {
        return NextResponse.json({ error: authError.message }, { status: 400 })
      }

      return NextResponse.json({
        success: true,
        message: 'Mitra driver berhasil didaftarkan. Driver perlu memverifikasi email sebelum dapat masuk.',
        user: authData?.user
      })
    }

    // 3. Tanpa kredensial Supabase tidak ada yang bisa disimpan.
    //    Versi lama mengembalikan "berhasil (Demo Mode)" di sini, sehingga
    //    admin mengira driver sudah terdaftar padahal tidak ada apa pun
    //    yang tertulis ke database.
    return NextResponse.json(
      { error: 'Server belum dikonfigurasi untuk terhubung ke Supabase. Hubungi pengelola sistem.' },
      { status: 503 }
    )
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Terjadi kesalahan sistem.'
    return NextResponse.json({ error: message }, { status: 500 })
  }
}
