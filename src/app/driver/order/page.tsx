'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { useGeolocation } from '@/hooks/useGeolocation'
import { formatRupiah, generateOrderNumber } from '@/lib/format'
import { PAYMENT_METHODS } from '@/lib/constants'
import {
  Minus, Plus, ShoppingCart, MapPin, CheckCircle,
  Loader2, Banknote, QrCode, ArrowRightLeft, X, ArrowLeft
} from 'lucide-react'
import type { Product, CartItem, Shift } from '@/types/database'
import Link from 'next/link'

const paymentIcons = { Banknote, QrCode, ArrowRightLeft }

export default function OrderPage() {
  const { user } = useAuth()
  const { latitude, longitude, accuracy, getPosition, loading: gpsLoading } = useGeolocation()
  const [products, setProducts] = useState<Product[]>([])
  const [cart, setCart] = useState<CartItem[]>([])
  const [paymentMethod, setPaymentMethod] = useState<string>('cash')
  const [activeShift, setActiveShift] = useState<Shift | null>(null)
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [success, setSuccess] = useState(false)
  const [orderNumber, setOrderNumber] = useState('')
  const supabase = createClient()

  useEffect(() => {
    if (user) {
      loadData()
      getPosition()
    }
  }, [user])

  async function loadData() {
    const fallbackProducts: Product[] = [
      { id: '1', name: 'Green Paradise', description: 'Bayam, pisang, mangga, madu', image_url: null, price: 18000, category: 'smoothie', is_available: true, sort_order: 1, created_at: '' },
      { id: '2', name: 'Berry Blast', description: 'Strawberry, blueberry, yoghurt, madu', image_url: null, price: 20000, category: 'smoothie', is_available: true, sort_order: 2, created_at: '' },
      { id: '3', name: 'Tropical Sunset', description: 'Mangga, nanas, jeruk, passion fruit', image_url: null, price: 18000, category: 'smoothie', is_available: true, sort_order: 3, created_at: '' },
      { id: '4', name: 'Choco Banana', description: 'Pisang, coklat, susu almond, madu', image_url: null, price: 20000, category: 'smoothie', is_available: true, sort_order: 4, created_at: '' },
      { id: '5', name: 'Dragon Fruit Bliss', description: 'Buah naga, pisang, susu, madu', image_url: null, price: 22000, category: 'smoothie', is_available: true, sort_order: 5, created_at: '' },
      { id: '6', name: 'Avocado Dream', description: 'Alpukat, susu kental, gula aren, es', image_url: null, price: 22000, category: 'smoothie', is_available: true, sort_order: 6, created_at: '' },
      { id: '7', name: 'Extra Granola', description: 'Topping granola crunchy gurih', image_url: null, price: 5000, category: 'topping', is_available: true, sort_order: 20, created_at: '' },
      { id: '8', name: 'Extra Chia Seeds', description: 'Topping biji chia kaya serat', image_url: null, price: 5000, category: 'topping', is_available: true, sort_order: 21, created_at: '' },
      { id: '9', name: 'Extra Madu Murni', description: 'Tambahan madu alam segar', image_url: null, price: 3000, category: 'addon', is_available: true, sort_order: 30, created_at: '' },
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

      // Get available products
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

    // Get fresh GPS
    getPosition()

    const newOrderNumber = generateOrderNumber()

    // Demo mode shortcut
    if (user.id === 'demo-driver-id') {
      setTimeout(() => {
        setOrderNumber(newOrderNumber)
        setSuccess(true)
        setCart([])
        setSubmitting(false)
      }, 600)
      return
    }

    // Create order
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

    // Create order items
    const items = cart.map(item => ({
      order_id: order.id,
      product_id: item.product.id,
      quantity: item.quantity,
      unit_price: item.product.price,
      subtotal: item.product.price * item.quantity,
    }))

    await supabase.from('order_items').insert(items)

    // Log location
    if (latitude && longitude) {
      await supabase.from('location_logs').insert({
        driver_id: user.id,
        shift_id: activeShift.id,
        latitude,
        longitude,
        accuracy,
      })
    }

    setOrderNumber(newOrderNumber)
    setSuccess(true)
    setCart([])
    setSubmitting(false)
  }

  // Success screen
  if (success) {
    return (
      <div className="flex flex-col items-center justify-center min-h-[70vh] p-6 text-center">
        <div className="w-16 h-16 bg-red-50 rounded-full flex items-center justify-center mb-4">
          <CheckCircle className="w-8 h-8 text-red-600" />
        </div>
        <h2 className="text-xl font-bold text-gray-900 mb-1">Pesanan Tersimpan!</h2>
        <p className="text-sm text-muted-foreground mb-1">{orderNumber}</p>
        <p className="text-xs text-muted-foreground mb-6">
          {latitude && `📍 ${latitude.toFixed(4)}, ${longitude?.toFixed(4)}`}
        </p>
        <div className="flex gap-3">
          <button
            onClick={() => { setSuccess(false); getPosition() }}
            className="bg-primary text-white px-6 py-2.5 rounded-xl font-medium text-sm"
          >
            Pesanan Baru
          </button>
          <Link
            href="/driver/history"
            className="bg-gray-100 text-gray-700 px-6 py-2.5 rounded-xl font-medium text-sm"
          >
            Lihat Riwayat
          </Link>
        </div>
      </div>
    )
  }

  if (!activeShift && !loading) {
    return (
      <div className="flex flex-col items-center justify-center min-h-[70vh] p-6 text-center">
        <p className="text-muted-foreground mb-3">Shift belum dimulai</p>
        <Link href="/driver/dashboard" className="text-primary font-medium text-sm">
          ← Kembali ke Dashboard
        </Link>
      </div>
    )
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 className="w-6 h-6 animate-spin text-primary" />
      </div>
    )
  }

  // Group products by category
  const smoothies = products.filter(p => p.category === 'smoothie')
  const toppings = products.filter(p => p.category === 'topping')
  const addons = products.filter(p => p.category === 'addon')

  return (
    <div className="pb-32">
      {/* Header */}
      <div className="p-4 flex items-center gap-3">
        <Link href="/driver/dashboard" className="text-gray-400 hover:text-gray-600">
          <ArrowLeft className="w-5 h-5" />
        </Link>
        <div>
          <h1 className="font-bold text-gray-900">Pesanan Baru</h1>
          <div className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <MapPin className="w-3 h-3" />
            {gpsLoading ? 'Mencari lokasi...' : latitude ? (
              <span className="text-red-600">GPS Aktif</span>
            ) : (
              <span className="text-amber-600">GPS belum aktif</span>
            )}
          </div>
        </div>
      </div>

      {/* Product Sections */}
      <div className="px-4 space-y-5">
        {/* Smoothies */}
        <div>
          <h2 className="text-sm font-semibold text-gray-500 uppercase tracking-wide mb-3">
            🥤 Smoothies
          </h2>
          <div className="grid grid-cols-2 gap-2.5">
            {smoothies.map(product => {
              const qty = getCartQty(product.id)
              return (
                <div
                  key={product.id}
                  className={`bg-white rounded-xl border p-3 transition-all ${
                    qty > 0 ? 'border-primary ring-1 ring-primary/20' : ''
                  }`}
                >
                  <div className="mb-2">
                    <h3 className="font-medium text-sm text-gray-900 leading-tight">
                      {product.name}
                    </h3>
                    {product.description && (
                      <p className="text-[11px] text-muted-foreground mt-0.5 line-clamp-2">
                        {product.description}
                      </p>
                    )}
                  </div>
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-bold text-primary">
                      {formatRupiah(product.price)}
                    </span>
                    {qty === 0 ? (
                      <button
                        onClick={() => addToCart(product)}
                        className="w-7 h-7 bg-primary/10 rounded-lg flex items-center justify-center text-primary hover:bg-primary/20 transition-colors"
                      >
                        <Plus className="w-4 h-4" />
                      </button>
                    ) : (
                      <div className="flex items-center gap-1.5">
                        <button
                          onClick={() => removeFromCart(product.id)}
                          className="w-7 h-7 bg-gray-100 rounded-lg flex items-center justify-center text-gray-600 hover:bg-gray-200"
                        >
                          {qty === 1 ? <X className="w-3.5 h-3.5" /> : <Minus className="w-3.5 h-3.5" />}
                        </button>
                        <span className="w-6 text-center text-sm font-bold">{qty}</span>
                        <button
                          onClick={() => addToCart(product)}
                          className="w-7 h-7 bg-primary rounded-lg flex items-center justify-center text-white hover:bg-primary/90"
                        >
                          <Plus className="w-3.5 h-3.5" />
                        </button>
                      </div>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        </div>

        {/* Toppings */}
        {toppings.length > 0 && (
          <div>
            <h2 className="text-sm font-semibold text-gray-500 uppercase tracking-wide mb-3">
              🧁 Toppings
            </h2>
            <div className="space-y-2">
              {toppings.map(product => {
                const qty = getCartQty(product.id)
                return (
                  <div key={product.id} className={`bg-white rounded-xl border p-3 flex items-center justify-between ${qty > 0 ? 'border-primary ring-1 ring-primary/20' : ''}`}>
                    <div>
                      <h3 className="font-medium text-sm text-gray-900">{product.name}</h3>
                      <span className="text-xs text-primary font-semibold">{formatRupiah(product.price)}</span>
                    </div>
                    {qty === 0 ? (
                      <button onClick={() => addToCart(product)} className="w-7 h-7 bg-primary/10 rounded-lg flex items-center justify-center text-primary">
                        <Plus className="w-4 h-4" />
                      </button>
                    ) : (
                      <div className="flex items-center gap-1.5">
                        <button onClick={() => removeFromCart(product.id)} className="w-7 h-7 bg-gray-100 rounded-lg flex items-center justify-center text-gray-600">
                          {qty === 1 ? <X className="w-3.5 h-3.5" /> : <Minus className="w-3.5 h-3.5" />}
                        </button>
                        <span className="w-6 text-center text-sm font-bold">{qty}</span>
                        <button onClick={() => addToCart(product)} className="w-7 h-7 bg-primary rounded-lg flex items-center justify-center text-white">
                          <Plus className="w-3.5 h-3.5" />
                        </button>
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
          </div>
        )}

        {/* Add-ons */}
        {addons.length > 0 && (
          <div>
            <h2 className="text-sm font-semibold text-gray-500 uppercase tracking-wide mb-3">
              ✨ Add-on
            </h2>
            <div className="space-y-2">
              {addons.map(product => {
                const qty = getCartQty(product.id)
                return (
                  <div key={product.id} className={`bg-white rounded-xl border p-3 flex items-center justify-between ${qty > 0 ? 'border-primary ring-1 ring-primary/20' : ''}`}>
                    <div>
                      <h3 className="font-medium text-sm text-gray-900">{product.name}</h3>
                      <span className="text-xs text-primary font-semibold">{formatRupiah(product.price)}</span>
                    </div>
                    {qty === 0 ? (
                      <button onClick={() => addToCart(product)} className="w-7 h-7 bg-primary/10 rounded-lg flex items-center justify-center text-primary">
                        <Plus className="w-4 h-4" />
                      </button>
                    ) : (
                      <div className="flex items-center gap-1.5">
                        <button onClick={() => removeFromCart(product.id)} className="w-7 h-7 bg-gray-100 rounded-lg flex items-center justify-center text-gray-600">
                          {qty === 1 ? <X className="w-3.5 h-3.5" /> : <Minus className="w-3.5 h-3.5" />}
                        </button>
                        <span className="w-6 text-center text-sm font-bold">{qty}</span>
                        <button onClick={() => addToCart(product)} className="w-7 h-7 bg-primary rounded-lg flex items-center justify-center text-white">
                          <Plus className="w-3.5 h-3.5" />
                        </button>
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
          </div>
        )}

        {/* Payment Method */}
        {cart.length > 0 && (
          <div>
            <h2 className="text-sm font-semibold text-gray-500 uppercase tracking-wide mb-3">
              💳 Metode Bayar
            </h2>
            <div className="flex gap-2">
              {PAYMENT_METHODS.map(method => {
                const Icon = paymentIcons[method.icon as keyof typeof paymentIcons]
                return (
                  <button
                    key={method.value}
                    onClick={() => setPaymentMethod(method.value)}
                    className={`flex-1 flex flex-col items-center gap-1.5 py-3 rounded-xl border text-sm font-medium transition-all ${
                      paymentMethod === method.value
                        ? 'border-primary bg-primary/5 text-primary'
                        : 'border-gray-200 bg-white text-gray-600'
                    }`}
                  >
                    <Icon className="w-5 h-5" />
                    {method.label}
                  </button>
                )
              })}
            </div>
          </div>
        )}
      </div>

      {/* Bottom Bar */}
      {cart.length > 0 && (
        <div className="fixed bottom-16 left-0 right-0 bg-white border-t p-4 z-40">
          <button
            onClick={submitOrder}
            disabled={submitting}
            className="w-full bg-primary text-white rounded-xl py-3 font-medium flex items-center justify-center gap-2 hover:bg-primary/90 transition-colors shadow-sm disabled:opacity-50"
          >
            {submitting ? (
              <Loader2 className="w-4 h-4 animate-spin" />
            ) : (
              <ShoppingCart className="w-4 h-4" />
            )}
            <span>Konfirmasi ({totalItems} item)</span>
            <span className="ml-1 font-bold">{formatRupiah(totalAmount)}</span>
          </button>
        </div>
      )}
    </div>
  )
}
