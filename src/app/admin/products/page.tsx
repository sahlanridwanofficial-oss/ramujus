'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { formatRupiah } from '@/lib/format'
import {
  Loader2, Plus, Package, ToggleLeft, ToggleRight,
  Pencil, X, Check
} from 'lucide-react'
import type { Product } from '@/types/database'
import { PRODUCT_CATEGORIES } from '@/lib/constants'

export default function ProductsPage() {
  const [products, setProducts] = useState<Product[]>([])
  const [loading, setLoading] = useState(true)
  const [showForm, setShowForm] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [form, setForm] = useState({
    name: '', description: '', price: '', category: 'smoothie'
  })
  const [saving, setSaving] = useState(false)
  const supabase = createClient()

  useEffect(() => { loadProducts() }, [])

  async function loadProducts() {
    const { data } = await supabase
      .from('products')
      .select('*')
      .order('sort_order')
    if (data) setProducts(data)
    setLoading(false)
  }

  async function toggleAvailability(product: Product) {
    await supabase
      .from('products')
      .update({ is_available: !product.is_available })
      .eq('id', product.id)
    loadProducts()
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

    if (editingId) {
      await supabase.from('products').update(productData).eq('id', editingId)
    } else {
      await supabase.from('products').insert({
        ...productData,
        sort_order: products.length + 1,
      })
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
      <div className="flex items-center justify-center h-64">
        <Loader2 className="w-6 h-6 animate-spin text-primary" />
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-bold text-gray-900">Produk</h1>
          <p className="text-sm text-muted-foreground">{products.length} produk</p>
        </div>
        <button
          onClick={() => {
            setForm({ name: '', description: '', price: '', category: 'smoothie' })
            setEditingId(null)
            setShowForm(!showForm)
          }}
          className="flex items-center gap-1.5 bg-primary text-white px-4 py-2 rounded-xl text-sm font-medium hover:bg-primary/90 transition-colors"
        >
          {showForm ? <X className="w-4 h-4" /> : <Plus className="w-4 h-4" />}
          {showForm ? 'Batal' : 'Tambah'}
        </button>
      </div>

      {/* Add/Edit Form */}
      {showForm && (
        <div className="bg-white rounded-2xl border p-5 space-y-3">
          <h3 className="font-semibold text-gray-900">
            {editingId ? 'Edit Produk' : 'Tambah Produk'}
          </h3>
          <input
            type="text"
            placeholder="Nama produk"
            value={form.name}
            onChange={e => setForm(f => ({ ...f, name: e.target.value }))}
            className="w-full px-3.5 py-2.5 bg-gray-50 border rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-primary/20"
          />
          <input
            type="text"
            placeholder="Deskripsi (opsional)"
            value={form.description}
            onChange={e => setForm(f => ({ ...f, description: e.target.value }))}
            className="w-full px-3.5 py-2.5 bg-gray-50 border rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-primary/20"
          />
          <div className="grid grid-cols-2 gap-3">
            <input
              type="number"
              placeholder="Harga (Rp)"
              value={form.price}
              onChange={e => setForm(f => ({ ...f, price: e.target.value }))}
              className="w-full px-3.5 py-2.5 bg-gray-50 border rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-primary/20"
            />
            <select
              value={form.category}
              onChange={e => setForm(f => ({ ...f, category: e.target.value }))}
              className="w-full px-3.5 py-2.5 bg-gray-50 border rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-primary/20"
            >
              {PRODUCT_CATEGORIES.map(c => (
                <option key={c.value} value={c.value}>{c.label}</option>
              ))}
            </select>
          </div>
          <button
            onClick={saveProduct}
            disabled={saving || !form.name || !form.price}
            className="flex items-center gap-1.5 bg-primary text-white px-5 py-2.5 rounded-xl text-sm font-medium disabled:opacity-50"
          >
            {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <Check className="w-4 h-4" />}
            Simpan
          </button>
        </div>
      )}

      {/* Product List */}
      <div className="bg-white rounded-2xl border divide-y">
        {products.map(product => (
          <div key={product.id} className="px-5 py-3.5 flex items-center justify-between">
            <div className="flex items-center gap-3">
              <div className={`w-9 h-9 rounded-lg flex items-center justify-center ${
                product.is_available ? 'bg-green-50' : 'bg-gray-100'
              }`}>
                <Package className={`w-4 h-4 ${
                  product.is_available ? 'text-green-600' : 'text-gray-400'
                }`} />
              </div>
              <div>
                <p className={`text-sm font-medium ${
                  product.is_available ? 'text-gray-900' : 'text-gray-400'
                }`}>
                  {product.name}
                </p>
                <p className="text-xs text-muted-foreground">
                  {formatRupiah(product.price)} • {product.category}
                </p>
              </div>
            </div>
            <div className="flex items-center gap-2">
              <button
                onClick={() => startEdit(product)}
                className="w-8 h-8 rounded-lg flex items-center justify-center text-gray-400 hover:bg-gray-50 hover:text-gray-600"
              >
                <Pencil className="w-3.5 h-3.5" />
              </button>
              <button
                onClick={() => toggleAvailability(product)}
                className="text-gray-400 hover:text-gray-600"
              >
                {product.is_available ? (
                  <ToggleRight className="w-7 h-7 text-green-600" />
                ) : (
                  <ToggleLeft className="w-7 h-7" />
                )}
              </button>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
