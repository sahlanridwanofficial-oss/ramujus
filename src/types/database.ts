// ============================================
// Database Types for RAMUJUS
// ============================================

export type Role = 'admin' | 'driver'
export type ShiftStatus = 'active' | 'completed' | 'cancelled'
export type PaymentMethod = 'cash' | 'qris' | 'transfer'
export type ProductCategory = 'smoothie' | 'topping' | 'addon'
export type UserStatus = 'active' | 'inactive'

// ============================================
// Database Row Types
// ============================================

export interface Profile {
  id: string
  full_name: string
  phone: string | null
  avatar_url: string | null
  role: Role
  status: UserStatus
  home_base_lat: number | null
  home_base_lng: number | null
  created_at: string
  updated_at: string
}

export interface Product {
  id: string
  name: string
  description: string | null
  image_url: string | null
  price: number
  category: ProductCategory
  is_available: boolean
  sort_order: number
  created_at: string
}

export interface Shift {
  id: string
  driver_id: string
  start_time: string
  end_time: string | null
  start_lat: number | null
  start_lng: number | null
  end_lat: number | null
  end_lng: number | null
  status: ShiftStatus
  notes: string | null
  created_at: string
}

export interface Order {
  id: string
  shift_id: string
  driver_id: string
  order_number: string
  latitude: number | null
  longitude: number | null
  address: string | null
  total_amount: number
  payment_method: PaymentMethod
  customer_notes: string | null
  created_at: string
}

export interface OrderItem {
  id: string
  order_id: string
  product_id: string
  quantity: number
  unit_price: number
  subtotal: number
}

export interface LocationLog {
  id: string
  driver_id: string
  shift_id: string
  latitude: number
  longitude: number
  accuracy: number | null
  recorded_at: string
}

// ============================================
// Joined / Extended Types
// ============================================

export interface OrderWithItems extends Order {
  order_items: (OrderItem & { product: Product })[]
}

export interface ShiftWithOrders extends Shift {
  orders: Order[]
  driver: Profile
}

export interface OrderItemWithProduct extends OrderItem {
  product: Product
}

// ============================================
// Form / Input Types
// ============================================

export interface CreateOrderInput {
  shift_id: string
  driver_id: string
  latitude: number | null
  longitude: number | null
  address: string | null
  payment_method: PaymentMethod
  customer_notes?: string
  items: {
    product_id: string
    quantity: number
    unit_price: number
  }[]
}

export interface CreateProductInput {
  name: string
  description?: string
  image_url?: string
  price: number
  category: ProductCategory
  is_available?: boolean
  sort_order?: number
}

export interface UpdateProductInput extends Partial<CreateProductInput> {
  id: string
}

// ============================================
// Analytics Types
// ============================================

export interface DailySummary {
  date: string
  total_orders: number
  total_revenue: number
  avg_order_value: number
}

export interface ProductSummary {
  product_id: string
  product_name: string
  total_qty: number
  total_revenue: number
}

export interface DriverSummary {
  driver_id: string
  driver_name: string
  total_orders: number
  total_revenue: number
}

export interface LocationPoint {
  latitude: number
  longitude: number
  order_count: number
  total_revenue: number
}

// ============================================
// Cart Types (Client-side)
// ============================================

export interface CartItem {
  product: Product
  quantity: number
}
