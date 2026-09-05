'use client'

import { useState, useEffect, Suspense } from 'react'
import { useSearchParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import {
  PackageCheck, Sun, Moon, Loader2, Users, Calendar,
  CheckCircle2, AlertCircle, Save, RotateCcw,
  Check, ArrowRight, ShieldCheck
} from 'lucide-react'
import type { Profile, Product, DriverDailyAllocation, DriverAllocationItem } from '@/types/database'
import { isCupCategory } from '@/lib/constants'

interface ProductAllocItem {
  product: Product
  initial_quantity: number
  sold_quantity: number
  physical_remaining: number
  waste_quantity: number
}

function InventoryContent() {
  const searchParams = useSearchParams()
  const initialDriverId = searchParams.get('driverId') || ''

  const [activeTab, setActiveTab] = useState<'morning' | 'night'>('morning')
  const [drivers, setDrivers] = useState<Profile[]>([])
  const [selectedDriverId, setSelectedDriverId] = useState<string>(initialDriverId)
  const [selectedDate, setSelectedDate] = useState<string>(new Date().toISOString().slice(0, 10))
  const [products, setProducts] = useState<Product[]>([])

  const [allocItems, setAllocItems] = useState<{ [productId: string]: ProductAllocItem }>({})
  const [currentAllocation, setCurrentAllocation] = useState<DriverDailyAllocation | null>(null)
  
  // Financial Reconciliation State
  const [ordersSummary, setOrdersSummary] = useState({
    total_sales: 0,
    cash_sales: 0,
    qris_sales: 0,
    order_count: 0
  })
  const [cashSettledInput, setCashSettledInput] = useState<number>(0)
  const [auditNotes, setAuditNotes] = useState<string>('')

  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [alertMessage, setAlertMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null)

  const supabase = createClient()

  // Load drivers & products on mount
  useEffect(() => {
    async function loadInitial() {
      try {
        const [driversRes, productsRes] = await Promise.all([
          supabase.from('profiles').select('*').eq('role', 'driver').order('full_name'),
          supabase.from('products').select('*').eq('is_available', true).order('sort_order')
        ])

        if (driversRes.data) {
          setDrivers(driversRes.data)
          if (!selectedDriverId && driversRes.data.length > 0) {
            setSelectedDriverId(driversRes.data[0].id)
          }
        }

        if (productsRes.data) {
          setProducts(productsRes.data)
        }
      } catch {
        // handle silently
      } finally {
        setLoading(false)
      }
    }

    loadInitial()
  }, [])

  // Load allocation data whenever selected driver or date changes
  useEffect(() => {
    if (selectedDriverId && selectedDate && products.length > 0) {
      loadAllocationForDriver(selectedDriverId, selectedDate)
    }
  }, [selectedDriverId, selectedDate, products])

  async function loadAllocationForDriver(driverId: string, date: string) {
    setLoading(true)
    setAlertMessage(null)

    try {
      // 1. Fetch existing allocation header
      const { data: allocation } = await supabase
        .from('driver_daily_allocations')
        .select('*')
        .eq('driver_id', driverId)
        .eq('date', date)
        .maybeSingle()

      setCurrentAllocation(allocation || null)
      setCashSettledInput(allocation?.cash_settled || 0)
      setAuditNotes(allocation?.notes || '')

      // 2. Fetch existing allocation items if any
      let existingItems: DriverAllocationItem[] = []
      if (allocation) {
        const { data: items } = await supabase
          .from('driver_allocation_items')
          .select('*')
          .eq('allocation_id', allocation.id)

        if (items) existingItems = items
      }

      // 3. Fetch real POS orders for this driver on this date
      const startOfDay = `${date}T00:00:00`
      const endOfDay = `${date}T23:59:59`
      const { data: orders } = await supabase
        .from('orders')
        .select('id, total_amount, payment_method, order_items(product_id, quantity)')
        .eq('driver_id', driverId)
        .gte('created_at', startOfDay)
        .lte('created_at', endOfDay)

      // Calculate sold quantity per product from actual orders
      const realSoldByProduct: { [productId: string]: number } = {}
      let totalSales = 0
      let cashSales = 0
      let qrisSales = 0

      if (orders) {
        orders.forEach(order => {
          totalSales += order.total_amount || 0
          if (order.payment_method === 'cash') cashSales += order.total_amount || 0
          if (order.payment_method === 'qris') qrisSales += order.total_amount || 0

          if (order.order_items) {
            order.order_items.forEach((item: { product_id: string; quantity: number }) => {
              realSoldByProduct[item.product_id] = (realSoldByProduct[item.product_id] || 0) + item.quantity
            })
          }
        })
      }

      setOrdersSummary({
        total_sales: totalSales,
        cash_sales: cashSales,
        qris_sales: qrisSales,
        order_count: orders?.length || 0
      })

      // If cash settled hasn't been set yet, default to cashSales
      if (!allocation || allocation.cash_settled === 0) {
        setCashSettledInput(cashSales)
      }

      // 4. Construct items map
      const itemsMap: { [productId: string]: ProductAllocItem } = {}
      products.forEach(p => {
        const found = existingItems.find(i => i.product_id === p.id)
        const soldQty = realSoldByProduct[p.id] || found?.sold_quantity || 0
        const initQty = found?.initial_quantity || 0
        const expectedRem = Math.max(0, initQty - soldQty)

        itemsMap[p.id] = {
          product: p,
          initial_quantity: initQty,
          sold_quantity: soldQty,
          physical_remaining: found?.physical_remaining !== null && found?.physical_remaining !== undefined
            ? found.physical_remaining
            : expectedRem,
          waste_quantity: found?.waste_quantity || 0,
        }
      })

      setAllocItems(itemsMap)
    } catch {
      // fallback
    } finally {
      setLoading(false)
    }
  }

  // Quick adjust morning initial quantity
  function adjustInitialQty(productId: string, delta: number) {
    setAllocItems(prev => {
      const current = prev[productId]
      if (!current) return prev
      const newQty = Math.max(0, current.initial_quantity + delta)
      const expectedRem = Math.max(0, newQty - current.sold_quantity)
      return {
        ...prev,
        [productId]: {
          ...current,
          initial_quantity: newQty,
          physical_remaining: expectedRem
        }
      }
    })
  }

  function setInitialQtyDirect(productId: string, val: number) {
    setAllocItems(prev => {
      const current = prev[productId]
      if (!current) return prev
      const newQty = Math.max(0, isNaN(val) ? 0 : val)
      const expectedRem = Math.max(0, newQty - current.sold_quantity)
      return {
        ...prev,
        [productId]: {
          ...current,
          initial_quantity: newQty,
          physical_remaining: expectedRem
        }
      }
    })
  }

  function setPhysicalRemaining(productId: string, val: number) {
    setAllocItems(prev => {
      const current = prev[productId]
      if (!current) return prev
      return {
        ...prev,
        [productId]: {
          ...current,
          physical_remaining: Math.max(0, isNaN(val) ? 0 : val)
        }
      }
    })
  }

  function setWasteQty(productId: string, val: number) {
    setAllocItems(prev => {
      const current = prev[productId]
      if (!current) return prev
      return {
        ...prev,
        [productId]: {
          ...current,
          waste_quantity: Math.max(0, isNaN(val) ? 0 : val)
        }
      }
    })
  }

  // Save Morning Allocation
  async function handleSaveMorningAllocation() {
    if (!selectedDriverId || !selectedDate) return
    setSaving(true)
    setAlertMessage(null)

    try {
      // 1. Create or get allocation header
      let allocId = currentAllocation?.id

      if (!allocId) {
        const { data: newAlloc, error: allocErr } = await supabase
          .from('driver_daily_allocations')
          .insert({
            driver_id: selectedDriverId,
            date: selectedDate,
            status: 'allocated'
          })
          .select()
          .single()

        if (allocErr || !newAlloc) {
          throw new Error(allocErr?.message || 'Gagal membuat alokasi harian.')
        }
        allocId = newAlloc.id
        setCurrentAllocation(newAlloc)
      }

      // 2. Upsert allocation items.
      //    sold_quantity sengaja TIDAK dikirim: kolom itu dikelola server
      //    lewat create_order() setiap kali driver menjual. Mengirimnya dari
      //    sini akan menimpa penjualan yang masuk setelah halaman dibuka.
      const itemsToUpsert = Object.values(allocItems).map(item => ({
        allocation_id: allocId,
        product_id: item.product.id,
        initial_quantity: item.initial_quantity,
        physical_remaining: item.physical_remaining,
        waste_quantity: item.waste_quantity
      }))

      for (const item of itemsToUpsert) {
        await supabase
          .from('driver_allocation_items')
          .upsert(item, { onConflict: 'allocation_id,product_id' })
      }

      setAlertMessage({
        type: 'success',
        text: 'Alokasi muatan gerobak pagi berhasil disimpan. Mitra driver dapat melihat stok di aplikasinya.'
      })
      await loadAllocationForDriver(selectedDriverId, selectedDate)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'Gagal menyimpan alokasi.'
      setAlertMessage({ type: 'error', text: msg })
    } finally {
      setSaving(false)
    }
  }

  // Save Evening Reconciliation Audit
  async function handleSaveEveningAudit(lockAudit: boolean = false) {
    if (!selectedDriverId || !selectedDate) return
    setSaving(true)
    setAlertMessage(null)

    try {
      let allocId = currentAllocation?.id

      // Angka disimpan lebih dulu selagi alokasi masih terbuka. Penguncian
      // dilakukan terpisah di akhir lewat lock_reconciliation(), karena
      // setelah terkunci database menolak perubahan apa pun — termasuk yang
      // datang dari layar ini.
      if (!allocId) {
        const { data: newAlloc, error: insertError } = await supabase
          .from('driver_daily_allocations')
          .insert({
            driver_id: selectedDriverId,
            date: selectedDate,
            status: 'active',
            total_cash_collected: ordersSummary.cash_sales,
            total_qris_collected: ordersSummary.qris_sales,
            cash_settled: cashSettledInput,
            notes: auditNotes
          })
          .select()
          .single()

        if (insertError || !newAlloc) {
          throw new Error(insertError?.message || 'Gagal membuat data audit.')
        }
        allocId = newAlloc.id
      } else {
        const { error: updateError } = await supabase
          .from('driver_daily_allocations')
          .update({
            status: currentAllocation?.status === 'allocated' ? 'active' : (currentAllocation?.status || 'active'),
            total_cash_collected: ordersSummary.cash_sales,
            total_qris_collected: ordersSummary.qris_sales,
            cash_settled: cashSettledInput,
            notes: auditNotes,
            updated_at: new Date().toISOString()
          })
          .eq('id', allocId)

        if (updateError) {
          throw new Error(
            updateError.message.includes('RECONCILIATION_LOCKED')
              ? 'Rekonsiliasi hari ini sudah dikunci dan tidak dapat diubah. Buka kunci lebih dulu bila perlu koreksi.'
              : updateError.message
          )
        }
      }

      // Upsert items with physical remaining and waste
      if (allocId) {
        // sold_quantity tidak ikut dikirim — lihat catatan di
        // handleSaveAllocation. Angka penjualan hari itu milik server.
        const itemsToUpsert = Object.values(allocItems).map(item => ({
          allocation_id: allocId,
          product_id: item.product.id,
          initial_quantity: item.initial_quantity,
          physical_remaining: item.physical_remaining,
          waste_quantity: item.waste_quantity
        }))

        for (const item of itemsToUpsert) {
          await supabase
            .from('driver_allocation_items')
            .upsert(item, { onConflict: 'allocation_id,product_id' })
        }
      }

      if (lockAudit && allocId) {
        // Mengunci lewat RPC agar penanggung jawab dan angka kas saat
        // penguncian tercatat di jejak audit, bukan sekadar mengubah label.
        const { error: lockError } = await supabase.rpc('lock_reconciliation', {
          p_allocation_id: allocId,
          p_note: auditNotes || null,
        })

        if (lockError) {
          throw new Error(
            lockError.message.includes('ALLOCATION_NOT_FOUND_OR_ALREADY_LOCKED')
              ? 'Rekonsiliasi ini sudah terkunci sebelumnya.'
              : 'Gagal mengunci rekonsiliasi. Angka audit sudah tersimpan, silakan coba kunci lagi.'
          )
        }
      }

      setAlertMessage({
        type: 'success',
        text: lockAudit
          ? 'Rekonsiliasi malam berhasil dikunci. Angka hari ini sudah final dan tidak dapat diubah.'
          : 'Data audit stok dan penerimaan kas berhasil disimpan.'
      })
      await loadAllocationForDriver(selectedDriverId, selectedDate)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'Gagal memproses audit.'
      setAlertMessage({ type: 'error', text: msg })
    } finally {
      setSaving(false)
    }
  }

  // Computations
  //
  // Cup dan pelengkap dihitung terpisah. Sebelumnya semua kategori
  // dijumlahkan jadi satu, sehingga menambah satu topping atau add-on ikut
  // menaikkan angka "Total Muatan Cup" — padahal keduanya bukan cup.
  const allocValues = Object.values(allocItems)
  const cupItems = allocValues.filter(i => isCupCategory(i.product.category))
  const addonItems = allocValues.filter(i => !isCupCategory(i.product.category))

  const sumField = (
    items: ProductAllocItem[],
    field: 'initial_quantity' | 'sold_quantity' | 'physical_remaining' | 'waste_quantity'
  ) => items.reduce((sum, i) => sum + i[field], 0)

  // Selisih = Bawa - (Terjual + Sisa Fisik + Rusak)
  const sumVariance = (items: ProductAllocItem[]) =>
    items.reduce(
      (sum, i) => sum + (i.initial_quantity - (i.sold_quantity + i.physical_remaining + i.waste_quantity)),
      0
    )

  const totalInitialCups = sumField(cupItems, 'initial_quantity')
  const totalSoldCups = sumField(cupItems, 'sold_quantity')
  const cupVariance = sumVariance(cupItems)

  const totalInitialAddons = sumField(addonItems, 'initial_quantity')
  const totalSoldAddons = sumField(addonItems, 'sold_quantity')
  const addonVariance = sumVariance(addonItems)

  // Pelengkap hanya ditampilkan bila memang ada yang dimuat atau terjual,
  // supaya tampilan gerobak yang hanya membawa smoothie tetap ringkas.
  const hasAddonActivity = addonItems.some(
    i => i.initial_quantity > 0 || i.sold_quantity > 0 || i.physical_remaining > 0 || i.waste_quantity > 0
  )

  const cashVariance = cashSettledInput - ordersSummary.cash_sales

  // Setelah dikunci, database menolak perubahan apa pun pada alokasi ini.
  // Tombolnya ikut dimatikan agar admin tidak mengira suntingannya tersimpan.
  const isReconciled = currentAllocation?.status === 'reconciled'

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 pb-3 border-b border-zinc-200/70">
        <div>
          <h1 className="text-2xl font-black text-zinc-900 tracking-tight">Manajemen Stok Gerobak</h1>
          <p className="text-xs text-zinc-500 mt-0.5">
            Alokasi muatan cup pagi hari dan audit rekonsiliasi sisa fisik & kas di malam hari.
          </p>
        </div>

        {/* Status Indicator */}
        <div className="flex items-center gap-2">
          {currentAllocation?.status === 'reconciled' ? (
            <span className="inline-flex items-center gap-1.5 text-xs bg-emerald-50 text-emerald-800 border border-emerald-200 px-3 py-1 rounded-full font-bold">
              <CheckCircle2 className="w-3.5 h-3.5 text-emerald-600" />
              Selesai Diaudit & Ditutup
            </span>
          ) : currentAllocation?.status === 'active' ? (
            <span className="inline-flex items-center gap-1.5 text-xs bg-red-50 text-[#be1a1a] border border-red-100 px-3 py-1 rounded-full font-bold">
              <span className="w-2 h-2 rounded-full bg-[#be1a1a] animate-pulse" />
              Operasional Aktif di Jalan
            </span>
          ) : currentAllocation ? (
            <span className="inline-flex items-center gap-1.5 text-xs bg-amber-50 text-amber-800 border border-amber-200 px-3 py-1 rounded-full font-bold">
              Muatan Pagi Siap Berangkat
            </span>
          ) : (
            <span className="inline-flex items-center text-xs bg-zinc-100 text-zinc-500 px-3 py-1 rounded-full font-medium">
              Belum Ada Alokasi
            </span>
          )}
        </div>
      </div>

      {/* Control Bar: Driver & Date Filter */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-xs grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
        <div>
          <label className="block text-[11px] font-bold text-zinc-400 uppercase tracking-wider mb-1">
            Pilih Mitra Driver
          </label>
          <div className="relative">
            <select
              value={selectedDriverId}
              onChange={(e) => setSelectedDriverId(e.target.value)}
              className="w-full bg-zinc-50 border border-zinc-200 rounded-xl px-3.5 py-2.5 text-xs font-bold text-zinc-800 focus:outline-hidden focus:border-[#be1a1a] transition-all"
            >
              {drivers.length === 0 ? (
                <option value="">Tidak ada driver aktif</option>
              ) : (
                drivers.map(d => (
                  <option key={d.id} value={d.id}>
                    {d.full_name} ({d.phone || 'No phone'})
                  </option>
                ))
              )}
            </select>
          </div>
        </div>

        <div>
          <label className="block text-[11px] font-bold text-zinc-400 uppercase tracking-wider mb-1">
            Tanggal Operasional
          </label>
          <div className="relative">
            <input
              type="date"
              value={selectedDate}
              onChange={(e) => setSelectedDate(e.target.value)}
              className="w-full bg-zinc-50 border border-zinc-200 rounded-xl px-3.5 py-2.5 text-xs font-bold text-zinc-800 focus:outline-hidden focus:border-[#be1a1a] transition-all font-mono"
            />
          </div>
        </div>

        <div className="sm:col-span-2 lg:col-span-1 flex flex-col justify-end">
          {/* Workflow Tabs Toggle */}
          <div className="grid grid-cols-2 gap-1 p-1 bg-zinc-100 rounded-xl">
            <button
              onClick={() => setActiveTab('morning')}
              className={`flex items-center justify-center gap-1.5 py-2 rounded-lg text-xs font-bold transition-all ${
                activeTab === 'morning'
                  ? 'bg-white text-zinc-900 shadow-xs'
                  : 'text-zinc-500 hover:text-zinc-800'
              }`}
            >
              <Sun className="w-3.5 h-3.5 text-amber-600" />
              <span>1. Alokasi Pagi</span>
            </button>
            <button
              onClick={() => setActiveTab('night')}
              className={`flex items-center justify-center gap-1.5 py-2 rounded-lg text-xs font-bold transition-all ${
                activeTab === 'night'
                  ? 'bg-white text-[#be1a1a] shadow-xs'
                  : 'text-zinc-500 hover:text-zinc-800'
              }`}
            >
              <Moon className="w-3.5 h-3.5 text-indigo-600" />
              <span>2. Audit Malam</span>
            </button>
          </div>
        </div>
      </div>

      {/* Alert Notification */}
      {alertMessage && (
        <div
          className={`p-4 rounded-xl border flex items-center gap-3 text-xs font-medium animate-in fade-in ${
            alertMessage.type === 'success'
              ? 'bg-emerald-50 border-emerald-200 text-emerald-800'
              : 'bg-red-50 border-red-200 text-[#be1a1a]'
          }`}
        >
          {alertMessage.type === 'success' ? (
            <CheckCircle2 className="w-4 h-4 shrink-0 text-emerald-600" />
          ) : (
            <AlertCircle className="w-4 h-4 shrink-0 text-[#be1a1a]" />
          )}
          <span>{alertMessage.text}</span>
        </div>
      )}

      {/* Main Content Area */}
      {loading ? (
        <div className="flex flex-col items-center justify-center h-64 gap-2 text-zinc-400">
          <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
          <span className="text-xs">Memuat alokasi gerobak...</span>
        </div>
      ) : (
        <>
          {/* ============================================================== */}
          {/* TAB 1: ALOKASI PAGI (STOCK DISPATCH) */}
          {/* ============================================================== */}
          {activeTab === 'morning' && (
            <div className="space-y-4">
              {/* Morning Summary Banner */}
              <div className="bg-gradient-to-r from-red-50/80 via-white to-zinc-50 rounded-2xl border border-red-100 p-4.5 flex flex-col sm:flex-row items-start sm:items-center justify-between gap-3 shadow-xs">
                <div className="flex items-center gap-3">
                  <div className="w-10 h-10 rounded-xl bg-[#be1a1a] text-white flex items-center justify-center shrink-0">
                    <Sun className="w-5 h-5" />
                  </div>
                  <div>
                    <h3 className="font-bold text-zinc-900 text-sm">Muatan Gerobak Pagi Hari</h3>
                    <p className="text-xs text-zinc-500">
                      Tentukan jumlah cup/item yang dibawa driver sebelum memulai shift keliling.
                    </p>
                  </div>
                </div>

                <div className="flex items-center gap-4 bg-white px-4 py-2 rounded-xl border border-zinc-200/80">
                  <div>
                    <span className="text-[10px] uppercase font-bold text-zinc-400 block">Total Muatan</span>
                    <span className="text-lg font-black text-[#be1a1a]">{totalInitialCups} Cup</span>
                    {hasAddonActivity && (
                      <span className="text-[10px] text-zinc-500 font-semibold block leading-tight">
                        + {totalInitialAddons} topping/add-on
                      </span>
                    )}
                  </div>
                  <button
                    onClick={handleSaveMorningAllocation}
                    disabled={saving}
                    className="flex items-center gap-2 bg-[#be1a1a] hover:bg-[#a61515] text-white px-4 py-2 rounded-xl text-xs font-bold transition-all shadow-sm shadow-red-900/15 disabled:opacity-50"
                  >
                    {saving ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Save className="w-3.5 h-3.5" />}
                    <span>Simpan Muatan</span>
                  </button>
                </div>
              </div>

              {/* Product Allocation Cards Grid */}
              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3.5">
                {products.map(p => {
                  const item = allocItems[p.id] || { initial_quantity: 0, sold_quantity: 0 }
                  return (
                    <div
                      key={p.id}
                      className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-xs flex flex-col justify-between space-y-3"
                    >
                      <div className="flex items-start justify-between gap-2">
                        <div>
                          <span className="text-[10px] font-bold uppercase tracking-wider text-zinc-400 bg-zinc-100 px-2 py-0.5 rounded-full">
                            {p.category}
                          </span>
                          <h4 className="font-black text-zinc-900 text-sm mt-1">{p.name}</h4>
                          <p className="text-xs font-mono text-[#be1a1a] font-semibold">{formatRupiah(p.price)}</p>
                        </div>
                        <div className="text-right">
                          <span className="text-[11px] text-zinc-400 block">Bawa Pagi</span>
                          <span className="text-xl font-black text-zinc-900">{item.initial_quantity}</span>
                        </div>
                      </div>

                      {/* Quick Adjust Buttons */}
                      <div className="space-y-2 pt-2 border-t border-zinc-100">
                        <div className="flex items-center gap-1.5">
                          <input
                            type="number"
                            min={0}
                            value={item.initial_quantity}
                            onChange={(e) => setInitialQtyDirect(p.id, parseInt(e.target.value))}
                            className="w-20 bg-zinc-50 border border-zinc-200 rounded-lg px-2.5 py-1.5 text-center text-xs font-bold text-zinc-900 focus:outline-hidden focus:border-[#be1a1a]"
                          />
                          <button
                            type="button"
                            onClick={() => adjustInitialQty(p.id, 5)}
                            className="flex-1 bg-zinc-50 hover:bg-zinc-100 text-zinc-700 border border-zinc-200 rounded-lg py-1.5 text-xs font-bold transition-colors"
                          >
                            +5
                          </button>
                          <button
                            type="button"
                            onClick={() => adjustInitialQty(p.id, 10)}
                            className="flex-1 bg-zinc-50 hover:bg-zinc-100 text-zinc-700 border border-zinc-200 rounded-lg py-1.5 text-xs font-bold transition-colors"
                          >
                            +10
                          </button>
                          <button
                            type="button"
                            onClick={() => adjustInitialQty(p.id, 25)}
                            className="flex-1 bg-zinc-50 hover:bg-zinc-100 text-zinc-700 border border-zinc-200 rounded-lg py-1.5 text-xs font-bold transition-colors"
                          >
                            +25
                          </button>
                          <button
                            type="button"
                            onClick={() => setInitialQtyDirect(p.id, 0)}
                            title="Reset 0"
                            className="w-7 h-7 flex items-center justify-center text-zinc-400 hover:text-red-600 rounded-lg hover:bg-red-50 transition-colors text-xs"
                          >
                            <RotateCcw className="w-3 h-3" />
                          </button>
                        </div>
                      </div>
                    </div>
                  )
                })}
              </div>
            </div>
          )}

          {/* ============================================================== */}
          {/* TAB 2: REKONSILIASI MALAM (EVENING AUDIT & CASH SETTLEMENT) */}
          {/* ============================================================== */}
          {activeTab === 'night' && (
            <div className="space-y-5">
              {/* Financial & Order KPI Banner */}
              <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                <div className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-xs">
                  <span className="text-[11px] font-bold text-zinc-400 uppercase tracking-wider block mb-1">
                    Total Penjualan POS
                  </span>
                  <p className="text-xl font-black text-zinc-900 tracking-tight">
                    {formatRupiah(ordersSummary.total_sales)}
                  </p>
                  <span className="text-[10px] text-zinc-400 mt-0.5 block">{ordersSummary.order_count} transaksi</span>
                </div>

                <div className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-xs">
                  <span className="text-[11px] font-bold text-zinc-400 uppercase tracking-wider block mb-1">
                    Penerimaan Tunai (Cash)
                  </span>
                  <p className="text-xl font-black text-emerald-700 tracking-tight">
                    {formatRupiah(ordersSummary.cash_sales)}
                  </p>
                  <span className="text-[10px] text-zinc-400 mt-0.5 block">Harus disetor driver</span>
                </div>

                <div className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-xs">
                  <span className="text-[11px] font-bold text-zinc-400 uppercase tracking-wider block mb-1">
                    Penerimaan QRIS
                  </span>
                  <p className="text-xl font-black text-[#be1a1a] tracking-tight">
                    {formatRupiah(ordersSummary.qris_sales)}
                  </p>
                  <span className="text-[10px] text-zinc-400 mt-0.5 block">Langsung masuk rekening</span>
                </div>

                <div className="bg-white rounded-2xl border border-zinc-200/80 p-4 shadow-xs">
                  <span className="text-[11px] font-bold text-zinc-400 uppercase tracking-wider block mb-1">
                    Status Selisih Fisik
                  </span>
                  <p className={`text-xl font-black tracking-tight ${cupVariance === 0 ? 'text-emerald-600' : 'text-[#be1a1a]'}`}>
                    {cupVariance === 0 ? '0 Cup (Cocok)' : `${cupVariance > 0 ? '+' : ''}${cupVariance} Cup`}
                  </p>
                  {hasAddonActivity && (
                    <p className={`text-xs font-bold ${addonVariance === 0 ? 'text-emerald-600' : 'text-[#be1a1a]'}`}>
                      {addonVariance === 0
                        ? '0 topping/add-on (Cocok)'
                        : `${addonVariance > 0 ? '+' : ''}${addonVariance} topping/add-on`}
                    </p>
                  )}
                  <span className="text-[10px] text-zinc-400 mt-0.5 block">Bawa vs (Jual + Sisa + Rusak)</span>
                </div>
              </div>

              {/* Evening Product Audit Table */}
              <div className="bg-white rounded-2xl border border-zinc-200/80 shadow-xs overflow-hidden">
                <div className="p-4 border-b border-zinc-100 flex flex-col sm:flex-row sm:items-center justify-between gap-2 bg-zinc-50/50">
                  <div>
                    <h3 className="font-bold text-zinc-900 text-sm">Audit Stok Fisik Gerobak Malam</h3>
                    <p className="text-xs text-zinc-500">
                      Hitung sisa cup fisik di gerobak saat kembali ke base dan catat jika ada cup yang rusak.
                    </p>
                  </div>
                  <div className="text-xs text-zinc-500 font-mono">
                    <div>
                      Total Cup Bawa: <span className="font-bold text-zinc-900">{totalInitialCups}</span> | Terjual:{' '}
                      <span className="font-bold text-zinc-900">{totalSoldCups}</span>
                    </div>
                    {hasAddonActivity && (
                      <div className="text-[11px]">
                        Topping/Add-on Bawa: <span className="font-bold text-zinc-900">{totalInitialAddons}</span> |
                        Terjual: <span className="font-bold text-zinc-900">{totalSoldAddons}</span>
                      </div>
                    )}
                  </div>
                </div>

                <div className="overflow-x-auto">
                  <table className="w-full text-left text-xs">
                    <thead className="bg-zinc-100/60 text-zinc-500 font-bold border-b border-zinc-200/70 uppercase text-[10px] tracking-wider">
                      <tr>
                        <th className="py-3 px-4">Menu Produk</th>
                        <th className="py-3 px-3 text-center">1. Bawa Pagi</th>
                        <th className="py-3 px-3 text-center">2. Terjual POS</th>
                        <th className="py-3 px-3 text-center">Estimasi Sisa</th>
                        <th className="py-3 px-3 text-center bg-blue-50/60 text-blue-900">3. Sisa Fisik Gerobak</th>
                        <th className="py-3 px-3 text-center bg-amber-50/60 text-amber-900">4. Rusak / Waste</th>
                        <th className="py-3 px-4 text-center">Selisih</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-zinc-100">
                      {products.map(p => {
                        const item = allocItems[p.id] || {
                          initial_quantity: 0,
                          sold_quantity: 0,
                          physical_remaining: 0,
                          waste_quantity: 0
                        }
                        const expectedRemaining = Math.max(0, item.initial_quantity - item.sold_quantity)
                        // Variance = Initial - (Sold + Physical Remaining + Waste)
                        const variance = item.initial_quantity - (item.sold_quantity + item.physical_remaining + item.waste_quantity)

                        return (
                          <tr key={p.id} className="hover:bg-zinc-50/60 transition-colors">
                            <td className="py-3 px-4 font-bold text-zinc-900">
                              <div>{p.name}</div>
                              <span className="text-[10px] font-normal text-zinc-400">{formatRupiah(p.price)}</span>
                            </td>
                            <td className="py-3 px-3 text-center font-mono font-bold text-zinc-700">
                              {item.initial_quantity}
                            </td>
                            <td className="py-3 px-3 text-center font-mono font-bold text-[#be1a1a]">
                              {item.sold_quantity}
                            </td>
                            <td className="py-3 px-3 text-center font-mono text-zinc-500">
                              {expectedRemaining}
                            </td>
                            <td className="py-2.5 px-3 text-center bg-blue-50/30">
                              <input
                                type="number"
                                min={0}
                                value={item.physical_remaining}
                                onChange={(e) => setPhysicalRemaining(p.id, parseInt(e.target.value))}
                                className="w-16 mx-auto bg-white border border-blue-200 rounded-lg py-1 px-2 text-center text-xs font-bold text-blue-900 focus:outline-hidden focus:ring-2 focus:ring-blue-100"
                              />
                            </td>
                            <td className="py-2.5 px-3 text-center bg-amber-50/30">
                              <input
                                type="number"
                                min={0}
                                value={item.waste_quantity}
                                onChange={(e) => setWasteQty(p.id, parseInt(e.target.value))}
                                className="w-16 mx-auto bg-white border border-amber-200 rounded-lg py-1 px-2 text-center text-xs font-bold text-amber-900 focus:outline-hidden focus:ring-2 focus:ring-amber-100"
                              />
                            </td>
                            <td className="py-3 px-4 text-center">
                              {variance === 0 ? (
                                <span className="inline-flex items-center gap-1 text-[11px] font-bold text-emerald-700 bg-emerald-50 px-2 py-0.5 rounded-md">
                                  <Check className="w-3 h-3" /> Cocok
                                </span>
                              ) : (
                                <span className="inline-flex items-center gap-1 text-[11px] font-bold text-red-700 bg-red-50 px-2 py-0.5 rounded-md font-mono">
                                  {variance > 0 ? `+${variance}` : variance} Cup
                                </span>
                              )}
                            </td>
                          </tr>
                        )
                      })}
                    </tbody>
                  </table>
                </div>
              </div>

              {/* Cash Reconciliation & Closing Action */}
              <div className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-xs space-y-4">
                <h3 className="font-bold text-zinc-900 text-sm pb-2 border-b border-zinc-100">
                  Pencocokan Setoran Tunai & Penyelesaian Audit
                </h3>

                <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                  <div>
                    <label className="block text-xs font-bold text-zinc-700 mb-1">
                      Uang Tunai Fisik Diterima dari Driver
                    </label>
                    <div className="relative">
                      <span className="absolute left-3.5 top-1/2 -translate-y-1/2 text-xs font-bold text-zinc-400">
                        Rp
                      </span>
                      <input
                        type="number"
                        min={0}
                        value={cashSettledInput}
                        onChange={(e) => setCashSettledInput(parseInt(e.target.value) || 0)}
                        className="w-full pl-10 pr-3.5 py-2.5 rounded-xl border border-zinc-200 text-xs font-bold text-zinc-900 focus:outline-hidden focus:border-[#be1a1a] font-mono"
                      />
                    </div>
                    <div className="mt-1 text-[11px]">
                      {cashVariance === 0 ? (
                        <span className="text-emerald-600 font-bold">✓ Setoran tunai pas sesuai sistem</span>
                      ) : cashVariance < 0 ? (
                        <span className="text-[#be1a1a] font-bold">
                          Kurang setor: {formatRupiah(Math.abs(cashVariance))}
                        </span>
                      ) : (
                        <span className="text-emerald-700 font-bold">
                          Lebih setor: {formatRupiah(cashVariance)}
                        </span>
                      )}
                    </div>
                  </div>

                  <div className="md:col-span-2">
                    <label className="block text-xs font-bold text-zinc-700 mb-1">Catatan Audit Malam (Opsional)</label>
                    <input
                      type="text"
                      placeholder="Contoh: 1 cup mangga bocor di jalan, sisa kondisi dingin dan aman"
                      value={auditNotes}
                      onChange={(e) => setAuditNotes(e.target.value)}
                      className="w-full px-3.5 py-2.5 rounded-xl border border-zinc-200 text-xs text-zinc-800 focus:outline-hidden focus:border-[#be1a1a]"
                    />
                  </div>
                </div>

                <div className="pt-3 border-t border-zinc-100 flex flex-col sm:flex-row items-center justify-between gap-3">
                  <p className="text-xs text-zinc-400">
                    {isReconciled
                      ? 'Audit hari ini sudah dikunci. Database menolak perubahan angka kas maupun stok.'
                      : 'Kunci audit setelah memastikan hitungan fisik dan setoran uang tunai telah cocok. Setelah dikunci, angkanya final.'}
                  </p>

                  <div className="flex items-center gap-2 w-full sm:w-auto">
                    <button
                      type="button"
                      onClick={() => handleSaveEveningAudit(false)}
                      disabled={saving || isReconciled}
                      className="flex-1 sm:flex-none px-4 py-2.5 rounded-xl border border-zinc-200 text-xs font-bold text-zinc-700 hover:bg-zinc-50 transition-colors disabled:opacity-40 disabled:hover:bg-transparent"
                    >
                      Simpan Draft Audit
                    </button>
                    <button
                      type="button"
                      onClick={() => handleSaveEveningAudit(true)}
                      disabled={saving || isReconciled}
                      className="flex-1 sm:flex-none flex items-center justify-center gap-2 bg-[#be1a1a] hover:bg-[#a61515] text-white px-5 py-2.5 rounded-xl text-xs font-bold transition-all shadow-sm shadow-red-900/15 disabled:opacity-40"
                    >
                      {saving ? (
                        <Loader2 className="w-3.5 h-3.5 animate-spin" />
                      ) : (
                        <ShieldCheck className="w-4 h-4" />
                      )}
                      <span>{isReconciled ? 'Sudah Dikunci' : 'Kunci & Selesaikan Audit'}</span>
                    </button>
                  </div>
                </div>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  )
}

export default function InventoryPage() {
  return (
    <Suspense
      fallback={
        <div className="flex flex-col items-center justify-center h-64 gap-2 text-zinc-400">
          <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
          <span className="text-xs">Memuat modul stok gerobak...</span>
        </div>
      }
    >
      <InventoryContent />
    </Suspense>
  )
}
