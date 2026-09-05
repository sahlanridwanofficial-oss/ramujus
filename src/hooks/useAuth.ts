'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import type { Profile } from '@/types/database'

export function useAuth() {
  const [user, setUser] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)
  const supabase = createClient()

  useEffect(() => {
    async function getUser() {
      // Check demo cookie
      const match = document.cookie.match(/(^|;)\s*ramujus_role\s*=\s*([^;]+)/)
      const demoRole = match ? match[2] : null

      if (demoRole === 'admin' || demoRole === 'driver') {
        setUser({
          id: demoRole === 'admin' ? 'demo-admin-id' : 'demo-driver-id',
          full_name: demoRole === 'admin' ? 'Admin RAMUJUS' : 'Mitra Driver Gerobak 01',
          phone: '0812-3456-7890',
          avatar_url: null,
          role: demoRole,
          status: 'active',
          home_base_lat: -6.2088,
          home_base_lng: 106.8456,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        })
        setLoading(false)
        return
      }

      try {
        const { data: { user: authUser } } = await supabase.auth.getUser()
        if (authUser) {
          const { data: profile } = await supabase
            .from('profiles')
            .select('*')
            .eq('id', authUser.id)
            .single()
          setUser(profile)
        }
      } catch {
        setUser(null)
      } finally {
        setLoading(false)
      }
    }

    getUser()

    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      async (event, session) => {
        if (event === 'SIGNED_IN' && session?.user) {
          const { data: profile } = await supabase
            .from('profiles')
            .select('*')
            .eq('id', session.user.id)
            .single()
          setUser(profile)
        } else if (event === 'SIGNED_OUT') {
          setUser(null)
        }
      }
    )

    return () => subscription.unsubscribe()
  }, [])

  const signOut = async () => {
    document.cookie = 'ramujus_role=; path=/; max-age=0'
    try {
      await supabase.auth.signOut()
    } catch {
      // ignore
    }
    setUser(null)
    window.location.href = '/login'
  }

  return { user, loading, signOut }
}
