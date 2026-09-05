'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { useGeolocation } from '@/hooks/useGeolocation'
import { formatRupiah } from '@/lib/format'
import { PAYMENT_METHODS } from '@/lib/constants'
import {
  Minus, Plus, ShoppingCart, MapPin, CheckCircle2,
  Loader2, Banknote, QrCode, ArrowRightLeft, X, ArrowLeft,
  Receipt, PackageCheck, AlertCircle, CloudOff
} from 'lucide-react'
import type { Product, CartItem, Shift } from '@/types/database'
import { enqueueOrder, newClientOrderId, isPermanentFailure } from '@/lib/offlineQueue'
import { useOrderQueue } from '@/hooks/useOrderQueue'
import Link from 'next/link'

const paymentIcons = {
  Banknote,
  QrCode,
  ArrowRightLeft,
}

interface StockQuota {
  id: string
  initial: number
  sold: number
  remaining: number
}

// create_order() melempar kode error yang stabil; terjemahkan ke bahasa
// yang bisa ditindaklanjuti driver di lapangan.
function describeOrderError(message?: string): string {
  if (!message) return 'Pesanan gagal disimpan. Silakan coba lagi.'
  if (message.includes('INSUFFICIENT_STOCK')) {
    const product = message.split('INSUFFICIENT_STOCK:')[1]?.trim()
    return product
      ? `Stok gerobak untuk ${product} tidak mencukupi. Muat ulang halaman untuk melihat sisa terbaru.`
      : 'Stok gerobak tidak mencukupi untuk pesanan ini.'
  }
  if (message.includes('SHIFT_NOT_ACTIVE')) {
    return 'Shift Anda sudah tidak aktif. Mulai shift lagi sebelum membuat pesanan.'
  }
  if (message.includes('PRODUCT_UNAVAILABLE')) {
    return 'Ada produk di keranjang yang sudah dinonaktifkan admin. Hapus produk itu lalu coba lagi.'
  }
  if (message.includes('AUTH_REQUIRED')) {
    return 'Sesi Anda berakhir. Silakan masuk kembali.'
  }
  if (message.includes('EMPTY_CART')) {
    return 'Keranjang masih kosong.'
  }
  return 'Pesanan gagal disimpan. Silakan coba lagi.'
}

export default function OrderPage() {
  const { user } = useAuth()
  const { getPosition } = useGeolocation()
  const [products, setProducts] = useState<Product[]>([])
  const [activeCategory, setActiveCategory] = useState<string>('all')
  const [cart, setCart] = useState<CartItem[]>([])
  const [paymentMethod, setPaymentMethod] = useState<string>('cash')
  const [activeShift, setActiveShift] = useState<Shift | null>(null)
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [success, setSuccess] = useState(false)
  const [orderNumber, setOrderNumber] = useState('')
  const [lastOrderAmount, setLastOrderAmount] = useState(0)

  // Cart Stock Tracking
  const [stockMap, setStockMap] = useState<{ [productId: string]: StockQuota }>({})
  const [hasAllocation, setHasAllocation] = useState(false)
  const [stockWarning, setStockWarning] = useState<string | null>(null)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [queuedOffline, setQueuedOffline] = useState(false)
  const queue = useOrderQueue()

  const supabase = createClient()

  useEffect(() => {
    if (user) {
      loadData()
      getPosition()
    }
  }, [user])

  async function loadData() {
    try {
      // 1. Get active shift
      const { data: shift } = await supabase
        .from('shifts')
        .select('*')
        .eq('driver_id', user!.id)
        .eq('status', 'active')
        .maybeSingle()

      if (shift) {
        setActiveShift(shift)
      }

      // 2. Get products
      const { data: prods } = await supabase
        .from('products')
        .select('*')
        .eq('is_available', true)
        .order('sort_order')

      if (prods) {
        setProducts(prods)
      }

      // 3. Get today's allocation stock for this driver
      const today = new Date().toISOString().slice(0, 10)
      const { data: alloc } = await supabase
        .from('driver_daily_allocations')
        .select(`
          id,
          driver_allocation_items (
            id,
            product_id,
            initial_quantity,
            sold_quantity
          )
        `)
        .eq('driver_id', user!.id)
        .eq('date', today)
        .maybeSingle()

      if (alloc && alloc.driver_allocation_items && alloc.driver_allocation_items.length > 0) {
        const quotaMap: { [productId: string]: StockQuota } = {}
        const rawItems = alloc.driver_allocation_items as Array<{
          id: string
          product_id: string
          initial_quantity: number | null
          sold_quantity: number | null
        }>

        rawItems.forEach((item) => {
          const init = item.initial_quantity || 0
          const sold = item.sold_quantity || 0
          quotaMap[item.product_id] = {
            id: item.id,
            initial: init,
            sold,
            remaining: Math.max(0, init - sold)
          }
        })
        setStockMap(quotaMap)
        setHasAllocation(true)
      }
    } catch {
      setProducts([])
    } finally {
      setLoading(false)
    }
  }

  function addToCart(product: Product) {
    const quota = stockMap[product.id]
    const currentQty = getCartQty(product.id)

    // Check against cart stock allocation if allocation exists
    if (hasAllocation && quota) {
      if (quota.remaining <= currentQty) {
        setStockWarning(`Stok gerobak untuk ${product.name} sudah mencapai batas (${quota.remaining} cup tersedia).`)
        setTimeout(() => setStockWarning(null), 3000)
        return
      }
    }

    setStockWarning(null)
    setCart(prev => {
      const existing = prev.find(item => item.product.id === product.id)
      if (existing) {
        return prev.map(item =>
          item.product.id === product.id
            ? { ...item, quantity: item.quantity + 1 }
            : item
        )
      }
      return [...prev, { product, quantity: 1 }]
    })
  }

  function removeFromCart(productId: string) {
    setStockWarning(null)
    setCart(prev => {
      const existing = prev.find(item => item.product.id === productId)
      if (existing && existing.quantity > 1) {
        return prev.map(item =>
          item.product.id === productId
            ? { ...item, quantity: item.quantity - 1 }
            : item
        )
      }
      return prev.filter(item => item.product.id !== productId)
    })
  }

  function getCartQty(productId: string): number {
    return cart.find(item => item.product.id === productId)?.quantity || 0
  }

  const totalAmount = cart.reduce(
    (sum, item) => sum + item.product.price * item.quantity, 0
  )

  const totalItems = cart.reduce((sum, item) => sum + item.quantity, 0)

  async function submitOrder() {
    if (!activeShift || !user || cart.length === 0) return
    setSubmitting(true)
    setSubmitError(null)
    setQueuedOffline(false)

    // Kunci idempotensi dibuat sekali per pesanan. Kalau pengiriman gagal
    // dan pesanan masuk antrean, percobaan berikutnya memakai kunci yang
    // sama — server mengembalikan pesanan yang sudah ada alih-alih
    // membuat yang kedua dan memotong stok dua kali.
    const clientOrderId = newClientOrderId()
    const placedAt = new Date().toISOString()
    const items = cart.map(item => ({
      product_id: item.product.id,
      quantity: item.quantity,
    }))

    try {
      // Lokasi diambil lebih dulu dan ditunggu. Versi lama memanggil
      // getPosition() tanpa await lalu langsung menyimpan `latitude`/
      // `longitude` dari render sebelumnya, sehingga koordinat pesanan
      // adalah posisi lama — atau null pada pesanan pertama.
      const coords = await getPosition()

      // Seluruh penulisan (orders, order_items, kuota stok, log lokasi)
      // dijalankan dalam satu transaksi di database. Harga dan total
      // dihitung ulang di server dari tabel products.
      const { data, error: rpcError } = await supabase.rpc('create_order', {
        p_shift_id: activeShift.id,
        p_items: items,
        p_payment_method: paymentMethod,
        p_latitude: coords.latitude,
        p_longitude: coords.longitude,
        p_accuracy: coords.accuracy,
        p_client_order_id: clientOrderId,
        p_created_at: placedAt,
      })

      // PostgREST mengembalikan fungsi bertipe komposit sebagai objek
      // tunggal, tetapi dapat pula berupa array satu elemen tergantung versi.
      const order = (Array.isArray(data) ? data[0] : data) as
        | { order_number: string; total_amount: number }
        | null
        | undefined

      if (rpcError) {
        // Penolakan aturan bisnis tidak akan membaik dengan mencoba lagi,
        // jadi jangan diantre — tunjukkan sebabnya sekarang.
        if (isPermanentFailure(rpcError.message)) {
          setSubmitError(describeOrderError(rpcError.message))
          return
        }
        queueOrder(clientOrderId, placedAt, items, coords)
        return
      }

      if (!order) {
        queueOrder(clientOrderId, placedAt, items, coords)
        return
      }

      setLastOrderAmount(order.total_amount)
      setOrderNumber(order.order_number)
      setSuccess(true)
      setCart([])
      // Muat ulang kuota dari server, bukan menghitungnya di klien.
      await loadData()
    } catch {
      // Jaringan putus di tengah jalan: simpan, jangan buang penjualannya.
      queueOrder(clientOrderId, placedAt, items, {
        latitude: null, longitude: null, accuracy: null,
      })
    } finally {
      setSubmitting(false)
    }
  }

  function queueOrder(
    clientOrderId: string,
    placedAt: string,
    items: { product_id: string; quantity: number }[],
    coords: { latitude: number | null; longitude: number | null; accuracy: number | null }
  ) {
    if (!activeShift) return

    enqueueOrder({
      client_order_id: clientOrderId,
      shift_id: activeShift.id,
      items,
      payment_method: paymentMethod,
      latitude: coords.latitude,
      longitude: coords.longitude,
      accuracy: coords.accuracy,
      created_at: placedAt,
      total_estimate: totalAmount,
      attempts: 0,
    })

    // Kurangi kuota lokal supaya driver tidak menjual melebihi muatan
    // gerobak selama antrean belum terkirim.
    setStockMap(prev => {
      const next = { ...prev }
      for (const item of items) {
        const quota = next[item.product_id]
        if (quota) {
          const sold = quota.sold + item.quantity
          next[item.product_id] = {
            ...quota,
            sold,
            remaining: Math.max(0, quota.initial - sold),
          }
        }
      }
      return next
    })

    setLastOrderAmount(totalAmount)
    setOrderNumber('Menunggu sinyal')
    setQueuedOffline(true)
    setSuccess(true)
    setCart([])
    queue.refresh()
  }

  // Success Confirmation Screen
  if (success) {
    return (
      <div className="min-h-[75vh] flex flex-col items-center justify-center p-6 text-center">
        {/* Layar ini harus jujur membedakan pesanan yang sudah ada di server
            dari yang masih menunggu sinyal — driver menutup kas berdasarkan
            apa yang ia lihat di sini. */}
        <div
          className={`w-16 h-16 rounded-full flex items-center justify-center mb-4 border shadow-sm animate-in zoom-in-50 duration-300 ${
            queuedOffline
              ? 'bg-amber-50 text-amber-600 border-amber-200'
              : 'bg-emerald-50 text-emerald-600 border-emerald-100'
          }`}
        >
          {queuedOffline
            ? <CloudOff strokeWidth={2.5} className="w-8 h-8" />
            : <CheckCircle2 strokeWidth={2.5} className="w-8 h-8" />}
        </div>

        <span
          className={`text-[11px] font-bold uppercase tracking-wider px-2.5 py-1 rounded-full border mb-2 ${
            queuedOffline
              ? 'text-amber-700 bg-amber-50 border-amber-200/60'
              : 'text-emerald-600 bg-emerald-50 border-emerald-200/60'
          }`}
        >
          {queuedOffline ? 'Tersimpan di Perangkat' : 'Pesanan Berhasil Disimpan'}
        </span>

        <h2 className="text-2xl font-black text-zinc-900 tracking-tight">
          {orderNumber}
        </h2>

        <p className="text-xl font-bold text-[#be1a1a] mt-1 font-mono">
          {formatRupiah(lastOrderAmount)}
        </p>

        <p className="text-xs text-zinc-500 mt-2 max-w-xs leading-relaxed">
          {queuedOffline
            ? `Sinyal sedang tidak tersedia. Pesanan ini tersimpan di ponsel Anda dan akan terkirim otomatis begitu sinyal kembali. Jangan hapus aplikasi sebelum terkirim — ${queue.pending.length} pesanan menunggu.`
            : 'Transaksi dan stok gerobak telah tercatat secara realtime ke server pusat.'}
        </p>

        <div className="flex flex-col gap-2.5 w-full max-w-xs mt-8">
          <button
            onClick={() => {
              setSuccess(false)
              setOrderNumber('')
              setQueuedOffline(false)
            }}
            className="flex items-center justify-center gap-2 bg-[#be1a1a] hover:bg-[#a61515] active:scale-[0.98] text-white py-3 px-4 rounded-xl text-xs font-bold transition-all shadow-md shadow-red-900/15"
          >
            <Plus strokeWidth={2.5} className="w-4 h-4" />
            <span>Buat Pesanan Baru Lagi</span>
          </button>

          <Link
            href="/driver/dashboard"
            className="flex items-center justify-center gap-2 bg-zinc-100 hover:bg-zinc-200 active:scale-[0.98] text-zinc-700 py-3 px-4 rounded-xl text-xs font-semibold transition-all border border-zinc-200/60"
          >
            <span>Kembali ke Beranda</span>
          </Link>
        </div>
      </div>
    )
  }

  // Not in Active Shift Warning
  if (!activeShift && !loading) {
    return (
      <div className="min-h-[70vh] flex flex-col items-center justify-center p-6 text-center">
        <div className="w-14 h-14 rounded-2xl bg-amber-50 text-amber-600 flex items-center justify-center mb-4 border border-amber-200/60">
          <Receipt strokeWidth={2} className="w-7 h-7" />
        </div>
        <h2 className="text-lg font-bold text-zinc-900">Shift Belum Aktif</h2>
        <p className="text-xs text-zinc-500 mt-1 max-w-xs leading-relaxed">
          Anda harus memulai shift operasional terlebih dahulu di Beranda agar koordinat GPS gerobak dapat dikunci.
        </p>
        <Link
          href="/driver/dashboard"
          className="mt-6 bg-[#be1a1a] hover:bg-[#a61515] text-white px-5 py-2.5 rounded-xl text-xs font-bold transition-all shadow-sm shadow-red-900/15 inline-flex items-center gap-2"
        >
          <ArrowLeft className="w-4 h-4" />
          <span>Buka Beranda & Mulai Shift</span>
        </Link>
      </div>
    )
  }

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-72 gap-2 text-zinc-400">
        <Loader2 className="w-7 h-7 animate-spin text-[#be1a1a]" />
        <span className="text-xs">Memuat katalog menu & stok gerobak...</span>
      </div>
    )
  }

  const categories = [
    { key: 'all', label: 'Semua Menu' },
    { key: 'smoothie', label: 'Smoothies' },
    { key: 'topping', label: 'Topping' },
    { key: 'addon', label: 'Add-on' },
  ]

  const filteredProducts = activeCategory === 'all'
    ? products
    : products.filter(p => p.category === activeCategory)

  return (
    <div className="pb-36">
      {/* Sticky Header with Cart Counter */}
      <div className="sticky top-14 bg-white/95 backdrop-blur border-b border-zinc-200/80 px-4 py-3 z-30 shadow-2xs">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2.5">
            <Link
              href="/driver/dashboard"
              className="w-8 h-8 rounded-lg flex items-center justify-center text-zinc-500 hover:text-zinc-800 hover:bg-zinc-100 transition-colors"
            >
              <ArrowLeft className="w-4 h-4" />
            </Link>
            <div>
              <h1 className="text-base font-bold text-zinc-900 leading-tight">Kasir Pesanan</h1>
              <div className="flex items-center gap-1.5 text-[11px] text-zinc-500">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-500" />
                <span>GPS Cart Terkunci</span>
              </div>
            </div>
          </div>

          {cart.length > 0 && (
            <div className="text-right">
              <span className="text-[10px] text-zinc-400 font-medium block uppercase">Total Sementara</span>
              <span className="text-sm font-bold text-[#be1a1a]">{formatRupiah(totalAmount)}</span>
            </div>
          )}
        </div>

        {/* Warning alert if stock limit reached */}
        {stockWarning && (
          <div className="mt-2.5 p-2 bg-red-50 border border-red-200 rounded-xl flex items-center gap-2 text-[11px] text-[#be1a1a] font-medium animate-in fade-in">
            <AlertCircle className="w-3.5 h-3.5 shrink-0" />
            <span>{stockWarning}</span>
          </div>
        )}

        {/* Kegagalan penyimpanan pesanan — dulu gagal tanpa pesan apa pun */}
        {submitError && (
          <div
            role="alert"
            className="mt-2.5 p-2.5 bg-red-50 border border-red-300 rounded-xl flex items-start gap-2 text-[11px] text-[#be1a1a] font-semibold animate-in fade-in"
          >
            <AlertCircle className="w-3.5 h-3.5 shrink-0 mt-px" />
            <span className="leading-relaxed">{submitError}</span>
          </div>
        )}

        {/* Category Pills Filter */}
        <div className="flex gap-1.5 mt-3 overflow-x-auto pb-1 scrollbar-none">
          {categories.map(cat => (
            <button
              key={cat.key}
              onClick={() => setActiveCategory(cat.key)}
              className={`px-3 py-1.5 rounded-full text-xs font-semibold whitespace-nowrap transition-all ${
                activeCategory === cat.key
                  ? 'bg-zinc-900 text-white shadow-xs'
                  : 'bg-zinc-100 text-zinc-600 hover:bg-zinc-200/70'
              }`}
            >
              {cat.label}
            </button>
          ))}
        </div>
      </div>

      {/* Product List Grid */}
      <div className="p-4 space-y-3">
        {filteredProducts.length === 0 ? (
          <div className="bg-white rounded-2xl border border-zinc-200/80 p-10 text-center shadow-xs">
            <p className="text-xs font-bold text-zinc-700">Katalog Menu Belum Tersedia</p>
            <p className="text-[11px] text-zinc-400 mt-1 max-w-xs mx-auto">
              Belum ada produk aktif yang terdaftar di database. Silakan input menu produk melalui Panel Admin.
            </p>
          </div>
        ) : (
          filteredProducts.map(product => {
            const qty = getCartQty(product.id)
            const quota = stockMap[product.id]
            const isTracked = hasAllocation && quota !== undefined
            const remainingQuota = quota ? quota.remaining : 999
            const isOutOfStock = isTracked && remainingQuota <= 0

            return (
              <div
                key={product.id}
                className={`bg-white rounded-2xl border p-4 transition-all ${
                  qty > 0
                    ? 'border-[#be1a1a] ring-1 ring-[#be1a1a]/20 shadow-xs'
                    : 'border-zinc-200/80 shadow-xs'
                }`}
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <h3 className="font-bold text-sm text-zinc-900 truncate">
                        {product.name}
                      </h3>
                      <span className="text-[10px] uppercase font-bold text-zinc-400 bg-zinc-100 px-1.5 py-0.5 rounded">
                        {product.category}
                      </span>

                      {/* Stock Allocation Badge */}
                      {isTracked && (
                        <span
                          className={`text-[10px] font-bold px-2 py-0.5 rounded-full ${
                            remainingQuota > 5
                              ? 'bg-emerald-50 text-emerald-700 border border-emerald-200'
                              : remainingQuota > 0
                              ? 'bg-amber-50 text-amber-800 border border-amber-200'
                              : 'bg-red-50 text-[#be1a1a] border border-red-200'
                          }`}
                        >
                          {remainingQuota > 0 ? `Sisa di Cart: ${remainingQuota}` : 'Habis di Gerobak'}
                        </span>
                      )}
                    </div>

                    {product.description && (
                      <p className="text-xs text-zinc-500 mt-1 line-clamp-2 leading-relaxed">
                        {product.description}
                      </p>
                    )}
                    <p className="text-sm font-black text-[#be1a1a] mt-2">
                      {formatRupiah(product.price)}
                    </p>
                  </div>

                  {/* Quantity Controls */}
                  <div className="shrink-0 pt-1">
                    {qty === 0 ? (
                      <button
                        onClick={() => addToCart(product)}
                        disabled={isOutOfStock}
                        className={`flex items-center gap-1 text-xs font-semibold px-3 py-2 rounded-xl transition-all shadow-xs active:scale-95 ${
                          isOutOfStock
                            ? 'bg-zinc-100 text-zinc-400 cursor-not-allowed'
                            : 'bg-zinc-900 hover:bg-zinc-800 text-white'
                        }`}
                      >
                        <Plus className="w-3.5 h-3.5" />
                        <span>{isOutOfStock ? 'Habis' : 'Tambah'}</span>
                      </button>
                    ) : (
                      <div className="flex items-center gap-2 bg-zinc-100 p-1 rounded-xl border border-zinc-200/60">
                        <button
                          onClick={() => removeFromCart(product.id)}
                          className="w-8 h-8 rounded-lg bg-white shadow-xs flex items-center justify-center text-zinc-700 hover:bg-zinc-50 active:scale-90 transition-all"
                        >
                          {qty === 1 ? <X className="w-3.5 h-3.5 text-red-600" /> : <Minus className="w-3.5 h-3.5" />}
                        </button>
                        <span className="w-6 text-center font-bold text-sm text-zinc-900">{qty}</span>
                        <button
                          onClick={() => addToCart(product)}
                          disabled={isTracked && qty >= remainingQuota}
                          className={`w-8 h-8 rounded-lg text-white flex items-center justify-center shadow-xs transition-all ${
                            isTracked && qty >= remainingQuota
                              ? 'bg-zinc-300 cursor-not-allowed'
                              : 'bg-[#be1a1a] hover:bg-[#a61515] active:scale-90'
                          }`}
                        >
                          <Plus className="w-3.5 h-3.5" />
                        </button>
                      </div>
                    )}
                  </div>
                </div>
              </div>
            )
          })
        )}
      </div>

      {/* Sticky Bottom Cart Summary & Checkout */}
      {cart.length > 0 && (
        <div className="fixed bottom-16 left-0 right-0 bg-white/95 backdrop-blur border-t border-zinc-200/80 p-4 z-40 shadow-lg">
          <div className="max-w-lg mx-auto space-y-3">
            {/* Payment Method Selector */}
            <div>
              <div className="flex items-center justify-between mb-2">
                <span className="text-[11px] font-bold text-zinc-500 uppercase tracking-wider">
                  Pilih Pembayaran
                </span>
                <span className="text-xs font-medium text-zinc-500">
                  {totalItems} item dipilih
                </span>
              </div>
              <div className="grid grid-cols-3 gap-2">
                {PAYMENT_METHODS.map(pm => {
                  const Icon = paymentIcons[pm.icon as keyof typeof paymentIcons] || Banknote
                  const isSelected = paymentMethod === pm.value
                  return (
                    <button
                      key={pm.value}
                      type="button"
                      onClick={() => setPaymentMethod(pm.value)}
                      className={`flex items-center justify-center gap-1.5 p-2 rounded-xl text-xs font-bold border transition-all ${
                        isSelected
                          ? 'border-[#be1a1a] bg-red-50 text-[#be1a1a] shadow-xs'
                          : 'border-zinc-200 bg-zinc-50 text-zinc-700 hover:bg-zinc-100'
                      }`}
                    >
                      <Icon className="w-3.5 h-3.5" />
                      <span>{pm.label}</span>
                    </button>
                  )
                })}
              </div>
            </div>

            {/* Submit Order Button */}
            <button
              onClick={submitOrder}
              disabled={submitting}
              className="w-full flex items-center justify-between bg-[#be1a1a] hover:bg-[#a61515] active:scale-[0.99] text-white p-3.5 px-5 rounded-xl font-bold text-xs transition-all shadow-md shadow-red-900/15 disabled:opacity-50"
            >
              <div className="flex items-center gap-2">
                {submitting ? (
                  <Loader2 className="w-4 h-4 animate-spin" />
                ) : (
                  <ShoppingCart className="w-4 h-4" />
                )}
                <span>{submitting ? 'Memproses Pesanan...' : 'Simpan Transaksi'}</span>
              </div>
              <span className="text-sm font-black font-mono">{formatRupiah(totalAmount)}</span>
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
