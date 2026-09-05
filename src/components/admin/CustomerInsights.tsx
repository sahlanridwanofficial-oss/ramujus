'use client'

import { useEffect, useMemo, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import { Loader2, Info } from 'lucide-react'
import { GENDER_LABEL, AGE_LABEL, TYPE_LABEL, SEGMENT_ORDER } from '@/types/customer'

interface InsightRow {
  dimension: string
  bucket: string
  orders: number
  revenue: number
}

interface HourlyRow {
  hour: number
  age_range: string
  orders: number
}

const DIMENSION_TITLE: Record<string, string> = {
  gender: 'Jenis Kelamin',
  age: 'Kelompok Usia',
  type: 'Pelanggan Baru vs Langganan',
}

const LABELS: Record<string, Record<string, string>> = {
  gender: GENDER_LABEL,
  age: AGE_LABEL,
  type: TYPE_LABEL,
}

/** Warna netral berjenjang; segmen "tidak dicatat" sengaja paling pudar. */
function barColor(bucket: string, index: number): string {
  if (bucket === 'unknown') return 'bg-zinc-200'
  return ['bg-brand', 'bg-brand/75', 'bg-brand/55', 'bg-brand/40', 'bg-brand/25'][index % 5]
}

export default function CustomerInsights({ days }: { days: number }) {
  const [rows, setRows] = useState<InsightRow[]>([])
  const [hourly, setHourly] = useState<HourlyRow[]>([])
  const [loading, setLoading] = useState(true)
  const [supabase] = useState(() => createClient())

  useEffect(() => {
    let cancelled = false
    setLoading(true)

    async function load() {
      const [{ data: insights }, { data: byHour }] = await Promise.all([
        supabase.rpc('admin_customer_insights', { p_days: days }),
        supabase.rpc('admin_customer_hourly', { p_days: days }),
      ])
      if (cancelled) return
      setRows(((insights ?? []) as InsightRow[]).map(r => ({ ...r, revenue: Number(r.revenue) })))
      setHourly((byHour ?? []) as HourlyRow[])
      setLoading(false)
    }

    void load()
    return () => { cancelled = true }
  }, [supabase, days])

  const grouped = useMemo(() => {
    const out: Record<string, InsightRow[]> = {}
    for (const dim of ['gender', 'age', 'type']) {
      const order = SEGMENT_ORDER[dim] ?? []
      out[dim] = rows
        .filter(r => r.dimension === dim)
        .sort((a, b) => order.indexOf(a.bucket) - order.indexOf(b.bucket))
    }
    return out
  }, [rows])

  const totalOrders = useMemo(
    () => grouped.gender?.reduce((s, r) => s + r.orders, 0) ?? 0,
    [grouped]
  )

  // Jam tersibuk per kelompok usia — dasar menentukan gerobak mangkal di
  // jam berapa. Segmen "tidak dicatat" dikeluarkan agar tidak menutupi pola.
  const peakByAge = useMemo(() => {
    const best: Record<string, { hour: number; orders: number }> = {}
    for (const row of hourly) {
      if (row.age_range === 'unknown') continue
      if (!best[row.age_range] || row.orders > best[row.age_range].orders) {
        best[row.age_range] = { hour: row.hour, orders: row.orders }
      }
    }
    return Object.entries(best).sort((a, b) => b[1].orders - a[1].orders)
  }, [hourly])

  const recorded = totalOrders - (grouped.gender?.find(r => r.bucket === 'unknown')?.orders ?? 0)
  const coverage = totalOrders > 0 ? Math.round((recorded / totalOrders) * 100) : 0

  if (loading) {
    return (
      <div className="bg-white rounded-2xl border border-zinc-200/80 p-8 shadow-card flex flex-col items-center gap-2 text-zinc-400">
        <Loader2 className="w-5 h-5 animate-spin text-brand" />
        <span className="text-xs">Memuat profil pembeli...</span>
      </div>
    )
  }

  if (totalOrders === 0) {
    return (
      <div className="bg-white rounded-2xl border border-zinc-200/80 p-8 shadow-card text-center">
        <p className="text-sm font-semibold text-zinc-700">Belum ada transaksi pada rentang ini</p>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
        <div>
          <h2 className="text-sm font-bold text-zinc-900">Profil Pembeli</h2>
          <p className="text-xs text-zinc-500 mt-0.5">
            Perkiraan yang dicatat driver saat transaksi — bukan data identitas.
          </p>
        </div>
        <span
          className={`inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full text-[11px] font-bold ${
            coverage >= 60
              ? 'bg-emerald-50 text-emerald-700 border border-emerald-200'
              : 'bg-amber-50 text-amber-700 border border-amber-200'
          }`}
        >
          <Info className="w-3.5 h-3.5" />
          {coverage}% transaksi tercatat profilnya
        </span>
      </div>

      {coverage < 60 && (
        <p className="text-[11px] text-amber-800/80 bg-amber-50/70 border border-amber-200/70 rounded-xl px-3 py-2 leading-relaxed">
          Sebagian besar transaksi belum dicatat profilnya, jadi persentase di bawah
          belum mewakili seluruh pembeli. Angkanya jadi lebih dapat dipercaya begitu
          pencatatan lebih rutin.
        </p>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-3.5">
        {['gender', 'age', 'type'].map(dim => {
          const list = grouped[dim] ?? []
          const max = Math.max(...list.map(r => r.orders), 1)
          return (
            <div key={dim} className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-card">
              <h3 className="text-xs font-bold text-zinc-900 mb-3">{DIMENSION_TITLE[dim]}</h3>
              <div className="space-y-2.5">
                {list.map((row, i) => (
                  <div key={row.bucket}>
                    <div className="flex items-baseline justify-between mb-1">
                      <span className={`text-[11px] font-semibold ${row.bucket === 'unknown' ? 'text-zinc-400' : 'text-zinc-700'}`}>
                        {LABELS[dim]?.[row.bucket] ?? row.bucket}
                      </span>
                      <span className="text-[11px] font-bold text-zinc-900 tabular-nums">
                        {row.orders}
                        <span className="font-medium text-zinc-400">
                          {' '}({Math.round((row.orders / totalOrders) * 100)}%)
                        </span>
                      </span>
                    </div>
                    <div className="h-1.5 bg-zinc-100 rounded-full overflow-hidden">
                      <div
                        className={`h-full rounded-full ${barColor(row.bucket, i)}`}
                        style={{ width: `${(row.orders / max) * 100}%` }}
                      />
                    </div>
                    <span className="text-[10px] text-zinc-400 mt-0.5 block">
                      {formatRupiah(row.revenue)}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          )
        })}
      </div>

      {peakByAge.length > 0 && (
        <div className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-card">
          <h3 className="text-xs font-bold text-zinc-900 mb-1">Jam Ramai per Kelompok Usia</h3>
          <p className="text-[11px] text-zinc-500 mb-3">
            Dasar menentukan gerobak mangkal di jam berapa.
          </p>
          <div className="flex flex-wrap gap-2">
            {peakByAge.map(([age, peak]) => (
              <div
                key={age}
                className="flex items-baseline gap-2 bg-zinc-50 border border-zinc-200/70 rounded-xl px-3 py-2"
              >
                <span className="text-[11px] font-semibold text-zinc-600">{AGE_LABEL[age] ?? age}</span>
                <span className="text-sm font-black text-brand tabular-nums">
                  {String(peak.hour).padStart(2, '0')}.00
                </span>
                <span className="text-[10px] text-zinc-400">{peak.orders} pesanan</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}
