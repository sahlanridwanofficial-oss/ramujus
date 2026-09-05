# RAMUJUS 🥤

Sistem web aplikasi profesional untuk manajemen penjualan smoothies berbasis armada gerobak listrik.

## 🚀 Fitur Utama

- **Driver App (Mobile-First PWA)**:
  - Pelacakan Shift (Mulai & Akhiri Shift)
  - Input Pesanan Cepat dengan **Auto-GPS Tracking & Timestamp Server**
  - Kalkulasi Otomatis Produk (Smoothies, Topping, Add-on)
  - Pembayaran Cash, QRIS, & Transfer
  - Rekapitulasi Riwayat Transaksi Harian

- **Admin Dashboard (Desktop & Tablet)**:
  - Real-time Omzet, Pesanan, & Mitra Aktif
  - Peta Persebaran Penjualan Gerobak (Leaflet Maps)
  - Analitik Tren & Produk Terlaris
  - Manajemen Katalog Menu & Ketersediaan Stok
  - Manajemen Kinerja Driver
  - Laporan Keuangan & Export CSV

## 🛠️ Tech Stack

- **Framework**: Next.js 14 (App Router) + TypeScript
- **Styling**: Tailwind CSS
- **Database & Auth**: Supabase (PostgreSQL + Real-time)
- **Maps**: Leaflet + React-Leaflet
- **Deployment**: Vercel

## 💻 Cara Menjalankan

1. Install dependensi:
   ```bash
   npm install
   ```

2. Konfigurasi Environment:
   Salin `.env.local` dan isi kredensial Supabase Anda:
   ```env
   NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
   NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key
   ```

3. Jalankan server lokal:
   ```bash
   npm run dev
   ```
   Buka `http://localhost:3000` di browser Anda.
