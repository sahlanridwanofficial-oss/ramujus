'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { useGeolocation } from '@/hooks/useGeolocation'
import { formatRupiah, generateOrderNumber } from '@/lib/format'
import { PAYMENT_METHODS } from '@/lib/constants'
import {
  Minus, Plus, ShoppingCart, MapPin, CheckCircle2,
  Loader2, Banknote, QrCode, ArrowRightLeft, X, ArrowLeft,
  Receipt, Sparkles
} from 'lucide-react'
import type { Product, CartItem, Shift } from '@/types/database'
import Link from 'next/link'

const paymentIcons = {
  Banknote,
  QrCode,
  ArrowRightLeft,
}

export default function OrderPage() {
  const { user } = useAuth()
  const { latitude, longitude, accuracy, getPosition, loading: gpsLoading } = useGeolocation()
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
  const supabase = createClient()

  useEffect(() => {
    if (user) {
      loadData()
      getPosition()
    }
  }, [user])

  async function loadData() {
    const fallbackProducts: Product[] = [
      { id: '1', name: 'Green Paradise', description: 'Bayam segar, pisang, mangga, madu alami', image_url: null, price: 18000, category: 'smoothie', is_available: true, sort_order: 1, created_at: '' },
      { id: '2', name: 'Berry Blast', description: 'Strawberry, blueberry, yoghurt, madu murni', image_url: null, price: 20000, category: 'smoothie', is_available: true, sort_order: 2, created_at: '' },
      { id: '3', name: 'Tropical Sunset', description: 'Mangga harum manis, nanas, jeruk peras segar', image_url: null, price: 18000, category: 'smoothie', is_available: true, sort_order: 3, created_at: '' },
      { id: '4', name: 'Choco Banana', description: 'Pisang cavendish, coklat artisan, almond milk', image_url: null, price: 20000, category: 'smoothie', is_available: true, sort_order: 4, created_at: '' },
      { id: '5', name: 'Dragon Fruit Bliss', description: 'Buah naga merah segar, pisang, perasan lemon', image_url: null, price: 22000, category: 'smoothie', is_available: true, sort_order: 5, created_at: '' },
      { id: '6', name: 'Avocado Cream', description: 'Alpukat mentega murni, susu segar, gula aren', image_url: null, price: 22000, category: 'smoothie', is_available: true, sort_order: 6, created_at: '' },
      { id: '7', name: 'Extra Granola', description: 'Topping granola renyah panggang madu', image_url: null, price: 5000, category: 'topping', is_available: true, sort_order: 20, created_at: '' },
      { id: '8', name: 'Extra Chia Seeds', description: 'Superfood biji chia kaya serat & omega', image_url: null, price: 5000, category: 'topping', is_available: true, sort_order: 21, created_at: '' },
      { id: '9', name: 'Extra Madu Murni', description: 'Suntikan madu bunga liar 100% alami', image_url: null, price: 3000, category: 'addon', is_available: true, sort_order: 30, created_at: '' },
    ]

    try {
      // Get active shift
      const { data: shift } = await supabase
        .from('shifts')
        .select('*')
        .eq('driver_id', user!.id)
        .eq('status', 'active')
        .maybeSingle()

      if (shift) {
        setActiveShift(shift)
      } else if (user?.id === 'demo-driver-id') {
        setActiveShift({
          id: 'demo-shift-id',
          driver_id: 'demo-driver-id',
          start_time: new Date().toISOString(),
          end_time: null,
          start_lat: -6.2088,
          start_lng: 106.8456,
          end_lat: null,
          end_lng: null,
          status: 'active',
          notes: null,
          created_at: new Date().toISOString()
        })
      }

      // Get products
      const { data: prods } = await supabase
        .from('products')
        .select('*')
        .eq('is_available', true)
        .order('sort_order')

      if (prods && prods.length > 0) {
        setProducts(prods)
      } else {
        setProducts(fallbackProducts)
      }
    } catch {
      setProducts(fallbackProducts)
    } finally {
      setLoading(false)
    }
  }

  function addToCart(product: Product) {
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
    getPosition()

    const newOrderNumber = generateOrderNumber()

    if (user.id === 'demo-driver-id') {
      setTimeout(() => {
        setLastOrderAmount(totalAmount)
        setOrderNumber(newOrderNumber)
        setSuccess(true)
        setCart([])
        setSubmitting(false)
      }, 500)
      return
    }

    try {
      const { data: order, error: orderError } = await supabase
        .from('orders')
        .insert({
          shift_id: activeShift.id,
          driver_id: user.id,
          order_number: newOrderNumber,
          latitude,
          longitude,
          total_amount: totalAmount,
          payment_method: paymentMethod,
        })
        .select()
        .single()

      if (orderError || !order) {
        setSubmitting(false)
        return
      }

      const items = cart.map(item => ({
        order_id: order.id,
        product_id: item.product.id,
        quantity: item.quantity,
        unit_price: item.product.price,
        subtotal: item.product.price * item.quantity,
      }))

      await supabase.from('order_items').insert(items)

      if (latitude && longitude) {
        await supabase.from('location_logs').insert({
          driver_id: user.id,
          shift_id: activeShift.id,
          latitude,
          longitude,
          accuracy,
        })
      }

      setLastOrderAmount(totalAmount)
      setOrderNumber(newOrderNumber)
      setSuccess(true)
      setCart([])
    } finally {
      setSubmitting(false)
    }
  }

  // Success Confirmation Screen
  if (success) {
    return (
      <div className="min-h-[75vh] flex flex-col items-center justify-center p-6 text-center">
        <div className="w-full max-w-sm bg-white rounded-3xl border border-zinc-200/80 p-7 shadow-sm">
          <div className="w-16 h-16 bg-red-50 text-[#be1a1a] rounded-full flex items-center justify-center mx-auto mb-4">
            <CheckCircle2 strokeWidth={2.2} className="w-8 h-8" />
          </div>

          <h2 className="text-xl font-bold text-zinc-900 tracking-tight">
            Pesanan Berhasil Disimpan!
          </h2>
          <p className="text-xs font-mono font-bold text-zinc-500 mt-1 bg-zinc-100 py-1 px-3 rounded-md inline-block">
            {orderNumber}
          </p>

          <div className="my-5 py-4 border-y border-zinc-100 text-left space-y-2 text-xs">
            <div className="flex justify-between text-zinc-500">
              <span>Metode Bayar:</span>
              <span className="font-semibold text-zinc-800 uppercase">{paymentMethod}</span>
            </div>
            <div className="flex justify-between text-zinc-500">
              <span>Total Nilai:</span>
              <span className="font-bold text-zinc-900 text-sm">{formatRupiah(lastOrderAmount)}</span>
            </div>
            <div className="flex justify-between text-zinc-500">
              <span>Koordinat GPS:</span>
              <span className="font-mono text-zinc-700">
                {latitude ? `${latitude.toFixed(4)}, ${longitude?.toFixed(4)}` : 'Tersimpan'}
              </span>
            </div>
          </div>

          <div className="flex flex-col gap-2">
            <button
              onClick={() => { setSuccess(false); getPosition() }}
              className="w-full bg-[#be1a1a] hover:bg-[#a61515] text-white py-3 rounded-xl font-semibold text-sm transition-colors shadow-sm"
            >
              + Input Pesanan Berikutnya
            </button>
            <Link
              href="/driver/history"
              className="w-full bg-zinc-100 hover:bg-zinc-200 text-zinc-700 py-2.5 rounded-xl font-semibold text-xs transition-colors"
            >
              Lihat Riwayat Penjualan
            </Link>
          </div>
        </div>
      </div>
    )
  }

  if (!activeShift && !loading) {
    return (
      <div className="flex flex-col items-center justify-center min-h-[60vh] p-6 text-center">
        <div className="w-12 h-12 rounded-full bg-amber-50 text-amber-600 flex items-center justify-center mb-3">
          <MapPin className="w-6 h-6" />
        </div>
        <h2 className="text-base font-bold text-zinc-900">Shift Belum Aktif</h2>
        <p className="text-xs text-zinc-500 mt-1 max-w-xs mb-5">
          Anda wajib memulai shift gerobak terlebih dahulu agar lokasi penjualan tercatat secara akurat.
        </p>
        <Link
          href="/driver/dashboard"
          className="bg-[#be1a1a] text-white px-5 py-2.5 rounded-xl font-semibold text-xs shadow-sm"
        >
          Kembali ke Beranda Shift
        </Link>
      </div>
    )
  }

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-64 gap-2 text-zinc-400">
        <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
        <span className="text-xs">Memuat katalog menu ramu...</span>
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
      {/* Header Bar */}
      <div className="p-4 bg-white border-b border-zinc-200/80 sticky top-14 z-30">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <Link
              href="/driver/dashboard"
              className="w-8 h-8 rounded-lg bg-zinc-100 flex items-center justify-center text-zinc-600 hover:bg-zinc-200 transition-colors"
            >
              <ArrowLeft className="w-4 h-4" />
            </Link>
            <div>
              <h1 className="text-base font-bold text-zinc-900 leading-tight">Input Pesanan</h1>
              <div className="flex items-center gap-1.5 text-[11px] text-zinc-500">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-500" />
                <span>Gerobak GPS Terkunci</span>
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

        {/* Category Pills Filter */}
        <div className="flex gap-1.5 mt-3 overflow-x-auto pb-1 scrollbar-none">
          {categories.map(cat => (
            <button
              key={cat.key}
              onClick={() => setActiveCategory(cat.key)}
              className={`px-3 py-1.5 rounded-full text-xs font-semibold whitespace-nowrap transition-all ${
                activeCategory === cat.key
                  ? 'bg-zinc-900 text-white shadow-sm'
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
        {filteredProducts.map(product => {
          const qty = getCartQty(product.id)
          return (
            <div
              key={product.id}
              className={`bg-white rounded-2xl border p-4 transition-all ${
                qty > 0
                  ? 'border-[#be1a1a] ring-1 ring-[#be1a1a]/20 shadow-sm'
                  : 'border-zinc-200/80 shadow-xs'
              }`}
            >
              <div className="flex items-start justify-between gap-3">
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <h3 className="font-bold text-sm text-zinc-900 truncate">
                      {product.name}
                    </h3>
                    <span className="text-[10px] uppercase font-bold text-zinc-400 bg-zinc-100 px-1.5 py-0.5 rounded">
                      {product.category}
                    </span>
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
                      className="flex items-center gap-1 bg-zinc-900 hover:bg-zinc-800 text-white text-xs font-semibold px-3 py-2 rounded-xl transition-all shadow-sm active:scale-95"
                    >
                      <Plus className="w-3.5 h-3.5" />
                      <span>Tambah</span>
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
                        className="w-8 h-8 rounded-lg bg-[#be1a1a] text-white flex items-center justify-center shadow-xs hover:bg-[#a61515] active:scale-90 transition-all"
                      >
                        <Plus className="w-3.5 h-3.5" />
                      </button>
                    </div>
                  )}
                </div>
              </div>
            </div>
          )
        })}
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
                {PAYMENT_METHODS.map(method => {
                  const Icon = paymentIcons[method.icon as keyof typeof paymentIcons] || Banknote
                  const isSelected = paymentMethod === method.value
                  return (
                    <button
                      key={method.value}
                      type="button"
                      onClick={() => setPaymentMethod(method.value)}
                      className={`flex items-center justify-center gap-1.5 py-2 px-2 rounded-xl text-xs font-bold border transition-all ${
                        isSelected
                          ? 'border-[#be1a1a] bg-red-50 text-[#be1a1a] shadow-xs'
                          : 'border-zinc-200 bg-white text-zinc-600 hover:bg-zinc-50'
                      }`}
                    >
                      <Icon className="w-3.5 h-3.5" />
                      <span>{method.label}</span>
                    </button>
                  )
                })}
              </div>
            </div>

            {/* Confirmation CTA Button */}
            <button
              onClick={submitOrder}
              disabled={submitting}
              className="w-full bg-[#be1a1a] hover:bg-[#a61515] active:scale-[0.99] text-white rounded-xl py-3.5 px-4 font-bold flex items-center justify-between transition-all shadow-md shadow-red-900/20 disabled:opacity-50"
            >
              <div className="flex items-center gap-2">
                {submitting ? (
                  <Loader2 className="w-4 h-4 animate-spin" />
                ) : (
                  <ShoppingCart className="w-4 h-4" />
                )}
                <span>Simpan Pesanan ({totalItems})</span>
              </div>
              <span className="text-base font-black tracking-tight">
                {formatRupiah(totalAmount)}
              </span>
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
