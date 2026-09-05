'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import {
  Loader2, Plus, Package, ToggleLeft, ToggleRight,
  Pencil, X, Check, Filter
} from 'lucide-react'
import type { Product, ProductCategory } from '@/types/database'
import { PRODUCT_CATEGORIES } from '@/lib/constants'

export default function ProductsPage() {
  const [products, setProducts] = useState<Product[]>([])
  const [loading, setLoading] = useState(true)
  const [showForm, setShowForm] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [activeCategory, setActiveCategory] = useState<string>('all')
  const [form, setForm] = useState<{
    name: string
    description: string
    price: string
    category: ProductCategory
  }>({
    name: '', description: '', price: '', category: 'smoothie'
  })
  const [saving, setSaving] = useState(false)
  const supabase = createClient()

  useEffect(() => { loadProducts() }, [])

  async function loadProducts() {
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
      const { data } = await supabase
        .from('products')
        .select('*')
        .order('sort_order')

      if (data && data.length > 0) {
        setProducts(data)
      } else {
        setProducts(fallbackProducts)
      }
    } catch {
      setProducts(fallbackProducts)
    } finally {
      setLoading(false)
    }
  }

  async function toggleAvailability(product: Product) {
    const updated = !product.is_available
    setProducts(prev => prev.map(p => p.id === product.id ? { ...p, is_available: updated } : p))

    try {
      await supabase
        .from('products')
        .update({ is_available: updated })
        .eq('id', product.id)
    } catch {
      // ignore
    }
  }

  async function saveProduct() {
    if (!form.name || !form.price) return
    setSaving(true)

    const productData = {
      name: form.name,
      description: form.description || null,
      price: parseInt(form.price),
      category: form.category,
    }

    try {
      if (editingId) {
        await supabase.from('products').update(productData).eq('id', editingId)
      } else {
        await supabase.from('products').insert({
          ...productData,
          sort_order: products.length + 1,
        })
      }
    } catch {
      // optimistic update for demo
      if (editingId) {
        setProducts(prev => prev.map(p => p.id === editingId ? { ...p, ...productData, image_url: null, is_available: true, sort_order: p.sort_order, created_at: '' } : p))
      } else {
        setProducts(prev => [...prev, { id: 'temp-' + Date.now(), ...productData, image_url: null, is_available: true, sort_order: prev.length + 1, created_at: '' }])
      }
    }

    setForm({ name: '', description: '', price: '', category: 'smoothie' })
    setShowForm(false)
    setEditingId(null)
    setSaving(false)
    loadProducts()
  }

  function startEdit(product: Product) {
    setForm({
      name: product.name,
      description: product.description || '',
      price: product.price.toString(),
      category: product.category,
    })
    setEditingId(product.id)
    setShowForm(true)
  }

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-64 gap-2 text-zinc-400">
        <Loader2 className="w-6 h-6 animate-spin text-[#be1a1a]" />
        <span className="text-xs">Memuat katalog produk ramu...</span>
      </div>
    )
  }

  const filteredProducts = activeCategory === 'all'
    ? products
    : products.filter(p => p.category === activeCategory)

  return (
    <div className="space-y-5">
      {/* Header & New Action */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-black text-zinc-900 tracking-tight">Katalog Menu & Produk</h1>
          <p className="text-xs text-zinc-500 mt-0.5">Kelola ketersediaan stok rasa, topping, dan harga per cup</p>
        </div>
        <button
          onClick={() => {
            setForm({ name: '', description: '', price: '', category: 'smoothie' })
            setEditingId(null)
            setShowForm(!showForm)
          }}
          className="inline-flex items-center justify-center gap-2 bg-[#be1a1a] hover:bg-[#a61515] text-white px-4 py-2.5 rounded-xl text-xs font-bold transition-all shadow-xs"
        >
          {showForm ? <X className="w-4 h-4" /> : <Plus className="w-4 h-4" />}
          <span>{showForm ? 'Batal' : 'Tambah Menu Baru'}</span>
        </button>
      </div>

      {/* Form Drawer / Card */}
      {showForm && (
        <div className="bg-white rounded-2xl border border-zinc-200/80 p-5 shadow-sm space-y-4">
          <div className="flex items-center justify-between border-b border-zinc-100 pb-3">
            <h3 className="font-bold text-sm text-zinc-900">
              {editingId ? 'Edit Rincian Menu' : 'Tambah Menu Baru ramu.'}
            </h3>
            <button onClick={() => setShowForm(false)} className="text-zinc-400 hover:text-zinc-600">
              <X className="w-4 h-4" />
            </button>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label className="block text-[11px] font-bold text-zinc-500 uppercase tracking-wider mb-1">
                Nama Menu
              </label>
              <input
                type="text"
                placeholder="Contoh: Mango Berry Blitz"
                value={form.name}
                onChange={e => setForm(f => ({ ...f, name: e.target.value }))}
                className="w-full px-3.5 py-2.5 bg-zinc-50 border border-zinc-200 rounded-xl text-xs font-semibold focus:outline-none focus:ring-2 focus:ring-[#be1a1a]/20 focus:border-[#be1a1a]"
              />
            </div>

            <div>
              <label className="block text-[11px] font-bold text-zinc-500 uppercase tracking-wider mb-1">
                Kategori
              </label>
              <select
                value={form.category}
                onChange={e => setForm(f => ({ ...f, category: e.target.value as ProductCategory }))}
                className="w-full px-3.5 py-2.5 bg-zinc-50 border border-zinc-200 rounded-xl text-xs font-semibold focus:outline-none focus:ring-2 focus:ring-[#be1a1a]/20 focus:border-[#be1a1a]"
              >
                {PRODUCT_CATEGORIES.map(c => (
                  <option key={c.value} value={c.value}>{c.label}</option>
                ))}
              </select>
            </div>

            <div>
              <label className="block text-[11px] font-bold text-zinc-500 uppercase tracking-wider mb-1">
                Harga Jual (Rp)
              </label>
              <input
                type="number"
                placeholder="20000"
                value={form.price}
                onChange={e => setForm(f => ({ ...f, price: e.target.value }))}
                className="w-full px-3.5 py-2.5 bg-zinc-50 border border-zinc-200 rounded-xl text-xs font-semibold focus:outline-none focus:ring-2 focus:ring-[#be1a1a]/20 focus:border-[#be1a1a]"
              />
            </div>

            <div>
              <label className="block text-[11px] font-bold text-zinc-500 uppercase tracking-wider mb-1">
                Deskripsi Bahan
              </label>
              <input
                type="text"
                placeholder="Komposisi buah segar, madu..."
                value={form.description}
                onChange={e => setForm(f => ({ ...f, description: e.target.value }))}
                className="w-full px-3.5 py-2.5 bg-zinc-50 border border-zinc-200 rounded-xl text-xs font-semibold focus:outline-none focus:ring-2 focus:ring-[#be1a1a]/20 focus:border-[#be1a1a]"
              />
            </div>
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <button
              onClick={() => setShowForm(false)}
              className="px-4 py-2 text-xs font-semibold text-zinc-600 hover:bg-zinc-100 rounded-xl"
            >
              Batal
            </button>
            <button
              onClick={saveProduct}
              disabled={saving || !form.name || !form.price}
              className="inline-flex items-center gap-1.5 bg-[#be1a1a] hover:bg-[#a61515] text-white px-5 py-2 rounded-xl text-xs font-bold transition-all disabled:opacity-50"
            >
              {saving ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Check className="w-3.5 h-3.5" />}
              <span>Simpan Menu</span>
            </button>
          </div>
        </div>
      )}

      {/* Category Tabs */}
      <div className="flex gap-1.5 overflow-x-auto pb-1">
        <button
          onClick={() => setActiveCategory('all')}
          className={`px-3.5 py-1.5 rounded-full text-xs font-bold transition-all ${
            activeCategory === 'all'
              ? 'bg-zinc-900 text-white shadow-xs'
              : 'bg-white border border-zinc-200/80 text-zinc-600 hover:bg-zinc-50'
          }`}
        >
          Semua ({products.length})
        </button>
        {PRODUCT_CATEGORIES.map(cat => (
          <button
            key={cat.value}
            onClick={() => setActiveCategory(cat.value)}
            className={`px-3.5 py-1.5 rounded-full text-xs font-bold transition-all ${
              activeCategory === cat.value
                ? 'bg-zinc-900 text-white shadow-xs'
                : 'bg-white border border-zinc-200/80 text-zinc-600 hover:bg-zinc-50'
            }`}
          >
            {cat.label} ({products.filter(p => p.category === cat.value).length})
          </button>
        ))}
      </div>

      {/* Product Items Table / Cards */}
      <div className="bg-white rounded-2xl border border-zinc-200/80 shadow-xs divide-y divide-zinc-100 overflow-hidden">
        {filteredProducts.map(product => (
          <div key={product.id} className="px-6 py-4 flex items-center justify-between hover:bg-zinc-50/50 transition-colors">
            <div className="flex items-center gap-3">
              <div className={`w-10 h-10 rounded-xl flex items-center justify-center shrink-0 ${
                product.is_available ? 'bg-red-50 text-[#be1a1a]' : 'bg-zinc-100 text-zinc-400'
              }`}>
                <Package strokeWidth={1.75} className="w-5 h-5" />
              </div>
              <div>
                <div className="flex items-center gap-2">
                  <p className={`text-xs font-bold ${
                    product.is_available ? 'text-zinc-900' : 'text-zinc-400 line-through'
                  }`}>
                    {product.name}
                  </p>
                  <span className="text-[9px] uppercase font-bold text-zinc-400 bg-zinc-100 px-1.5 py-0.5 rounded">
                    {product.category}
                  </span>
                </div>
                {product.description && (
                  <p className="text-[11px] text-zinc-400 mt-0.5 line-clamp-1">{product.description}</p>
                )}
                <p className="text-xs font-black text-[#be1a1a] mt-1">
                  {formatRupiah(product.price)}
                </p>
              </div>
            </div>

            <div className="flex items-center gap-3">
              <button
                onClick={() => startEdit(product)}
                title="Edit Produk"
                className="w-8 h-8 rounded-lg flex items-center justify-center text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100 transition-colors"
              >
                <Pencil className="w-4 h-4" />
              </button>
              <button
                onClick={() => toggleAvailability(product)}
                title={product.is_available ? 'Nonaktifkan stok' : 'Aktifkan stok'}
                className="transition-transform active:scale-95"
              >
                {product.is_available ? (
                  <div className="flex items-center gap-1.5 text-[#be1a1a]">
                    <span className="text-[11px] font-bold hidden sm:inline">Tersedia</span>
                    <ToggleRight className="w-7 h-7" />
                  </div>
                ) : (
                  <div className="flex items-center gap-1.5 text-zinc-400">
                    <span className="text-[11px] font-semibold hidden sm:inline">Habis</span>
                    <ToggleLeft className="w-7 h-7" />
                  </div>
                )}
              </button>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
