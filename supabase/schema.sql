-- ============================================
-- RAMUJUS Database Schema
-- Run this in Supabase SQL Editor
-- ============================================

-- 1. Profiles table (extends auth.users)
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  full_name TEXT NOT NULL,
  phone TEXT,
  avatar_url TEXT,
  role TEXT NOT NULL DEFAULT 'driver' CHECK (role IN ('admin', 'driver')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  home_base_lat DOUBLE PRECISION,
  home_base_lng DOUBLE PRECISION,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Auto-create profile on user signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, phone, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email),
    NEW.raw_user_meta_data->>'phone',
    COALESCE(NEW.raw_user_meta_data->>'role', 'driver')
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- 2. Products table
CREATE TABLE IF NOT EXISTS public.products (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  image_url TEXT,
  price INTEGER NOT NULL CHECK (price >= 0),
  category TEXT NOT NULL DEFAULT 'smoothie' CHECK (category IN ('smoothie', 'topping', 'addon')),
  is_available BOOLEAN NOT NULL DEFAULT true,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3. Shifts table
CREATE TABLE IF NOT EXISTS public.shifts (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  driver_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
  start_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  end_time TIMESTAMPTZ,
  start_lat DOUBLE PRECISION,
  start_lng DOUBLE PRECISION,
  end_lat DOUBLE PRECISION,
  end_lng DOUBLE PRECISION,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed', 'cancelled')),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 4. Orders table
CREATE TABLE IF NOT EXISTS public.orders (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  shift_id UUID REFERENCES public.shifts(id) ON DELETE CASCADE NOT NULL,
  driver_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
  order_number TEXT NOT NULL UNIQUE,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  address TEXT,
  total_amount INTEGER NOT NULL DEFAULT 0,
  payment_method TEXT NOT NULL DEFAULT 'cash' CHECK (payment_method IN ('cash', 'qris', 'transfer')),
  customer_notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 5. Order Items table
CREATE TABLE IF NOT EXISTS public.order_items (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  order_id UUID REFERENCES public.orders(id) ON DELETE CASCADE NOT NULL,
  product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  unit_price INTEGER NOT NULL CHECK (unit_price >= 0),
  subtotal INTEGER NOT NULL CHECK (subtotal >= 0)
);

-- 6. Location Logs table
CREATE TABLE IF NOT EXISTS public.location_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  driver_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
  shift_id UUID REFERENCES public.shifts(id) ON DELETE CASCADE NOT NULL,
  latitude DOUBLE PRECISION NOT NULL,
  longitude DOUBLE PRECISION NOT NULL,
  accuracy DOUBLE PRECISION,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================
-- Indexes for performance
-- ============================================
CREATE INDEX IF NOT EXISTS idx_shifts_driver_id ON public.shifts(driver_id);
CREATE INDEX IF NOT EXISTS idx_shifts_status ON public.shifts(status);
CREATE INDEX IF NOT EXISTS idx_orders_shift_id ON public.orders(shift_id);
CREATE INDEX IF NOT EXISTS idx_orders_driver_id ON public.orders(driver_id);
CREATE INDEX IF NOT EXISTS idx_orders_created_at ON public.orders(created_at);
CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON public.order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_location_logs_shift_id ON public.location_logs(shift_id);
CREATE INDEX IF NOT EXISTS idx_location_logs_driver_id ON public.location_logs(driver_id);

-- ============================================
-- Row Level Security (RLS)
-- ============================================
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.location_logs ENABLE ROW LEVEL SECURITY;

-- Helper function to check role
CREATE OR REPLACE FUNCTION public.get_user_role(user_id UUID)
RETURNS TEXT AS $$
  SELECT role FROM public.profiles WHERE id = user_id;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- PROFILES policies
CREATE POLICY "Admin can view all profiles" ON public.profiles
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'admin');
CREATE POLICY "Users can view own profile" ON public.profiles
  FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON public.profiles
  FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Admin can update any profile" ON public.profiles
  FOR UPDATE USING (public.get_user_role(auth.uid()) = 'admin');

-- PRODUCTS policies (everyone can read, admin can write)
CREATE POLICY "Everyone can view products" ON public.products
  FOR SELECT USING (true);
CREATE POLICY "Admin can insert products" ON public.products
  FOR INSERT WITH CHECK (public.get_user_role(auth.uid()) = 'admin');
CREATE POLICY "Admin can update products" ON public.products
  FOR UPDATE USING (public.get_user_role(auth.uid()) = 'admin');
CREATE POLICY "Admin can delete products" ON public.products
  FOR DELETE USING (public.get_user_role(auth.uid()) = 'admin');

-- SHIFTS policies
CREATE POLICY "Admin can view all shifts" ON public.shifts
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'admin');
CREATE POLICY "Drivers can view own shifts" ON public.shifts
  FOR SELECT USING (auth.uid() = driver_id);
CREATE POLICY "Drivers can create own shifts" ON public.shifts
  FOR INSERT WITH CHECK (auth.uid() = driver_id);
CREATE POLICY "Drivers can update own shifts" ON public.shifts
  FOR UPDATE USING (auth.uid() = driver_id);

-- ORDERS policies
CREATE POLICY "Admin can view all orders" ON public.orders
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'admin');
CREATE POLICY "Drivers can view own orders" ON public.orders
  FOR SELECT USING (auth.uid() = driver_id);
CREATE POLICY "Drivers can create own orders" ON public.orders
  FOR INSERT WITH CHECK (auth.uid() = driver_id);
CREATE POLICY "Drivers can update own orders" ON public.orders
  FOR UPDATE USING (auth.uid() = driver_id);

-- ORDER_ITEMS policies
CREATE POLICY "Admin can view all order items" ON public.order_items
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.orders WHERE orders.id = order_items.order_id
            AND public.get_user_role(auth.uid()) = 'admin')
  );
CREATE POLICY "Drivers can view own order items" ON public.order_items
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.orders WHERE orders.id = order_items.order_id
            AND orders.driver_id = auth.uid())
  );
CREATE POLICY "Drivers can insert own order items" ON public.order_items
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM public.orders WHERE orders.id = order_items.order_id
            AND orders.driver_id = auth.uid())
  );

-- LOCATION_LOGS policies
CREATE POLICY "Admin can view all location logs" ON public.location_logs
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'admin');
CREATE POLICY "Drivers can view own location logs" ON public.location_logs
  FOR SELECT USING (auth.uid() = driver_id);
CREATE POLICY "Drivers can insert own location logs" ON public.location_logs
  FOR INSERT WITH CHECK (auth.uid() = driver_id);

-- ============================================
-- Enable Realtime
-- ============================================
ALTER PUBLICATION supabase_realtime ADD TABLE public.orders;
ALTER PUBLICATION supabase_realtime ADD TABLE public.shifts;
ALTER PUBLICATION supabase_realtime ADD TABLE public.location_logs;

-- ============================================
-- Seed Data: Sample Products
-- ============================================
INSERT INTO public.products (name, description, price, category, is_available, sort_order) VALUES
  ('Green Paradise', 'Bayam, pisang, mangga, madu', 18000, 'smoothie', true, 1),
  ('Berry Blast', 'Strawberry, blueberry, yoghurt, madu', 20000, 'smoothie', true, 2),
  ('Tropical Sunset', 'Mangga, nanas, jeruk, passion fruit', 18000, 'smoothie', true, 3),
  ('Choco Banana', 'Pisang, coklat, susu almond, madu', 20000, 'smoothie', true, 4),
  ('Dragon Fruit Bliss', 'Buah naga, pisang, susu, madu', 22000, 'smoothie', true, 5),
  ('Avocado Dream', 'Alpukat, susu, gula aren, es', 22000, 'smoothie', true, 6),
  ('Matcha Latte', 'Matcha, susu, madu, es', 25000, 'smoothie', true, 7),
  ('Peanut Power', 'Pisang, selai kacang, susu, oat', 23000, 'smoothie', true, 8),
  ('Extra Granola', 'Topping granola crunchy', 5000, 'topping', true, 20),
  ('Extra Chia Seeds', 'Topping chia seeds', 5000, 'topping', true, 21),
  ('Extra Madu', 'Tambahan madu', 3000, 'addon', true, 30),
  ('Upsize', 'Upgrade ukuran ke Large', 5000, 'addon', true, 31)
ON CONFLICT DO NOTHING;
