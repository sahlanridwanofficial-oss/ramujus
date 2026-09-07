import { updateSession } from '@/lib/supabase/middleware'
import { type NextRequest } from 'next/server'

export async function middleware(request: NextRequest) {
  return await updateSession(request)
}

/**
 * Setiap permintaan yang lolos matcher ini membayar satu panggilan
 * auth.getUser() ke Supabase plus satu query profil. Jadi berkas yang tidak
 * punya urusan dengan peran sama sekali dikeluarkan di sini, bukan
 * dipulangkan setelah dua perjalanan ke server.
 *
 * Selain aset yang sudah dikecualikan sejak awal, daftar ini menambahkan
 * berkas PWA — service worker, runtime workbox, dan manifest — yang diminta
 * browser pada hampir setiap pembukaan aplikasi driver.
 *
 * Peran dan status sengaja TIDAK dipindahkan ke klaim JWT meski itu akan
 * menghapus query profilnya: token hanya disegarkan berkala, sehingga
 * menonaktifkan mitra baru berlaku di layar setelah token kedaluwarsa.
 * Penjagaan di database (policy shifts dan create_order sejak 0008) memang
 * langsung berlaku, tetapi membiarkan halaman operasional tetap terbuka
 * sampai satu jam ke depan bukan perilaku yang pantas untuk sebuah tombol
 * bernama "Nonaktif". Satu query per navigasi adalah harga yang dibayar
 * supaya penonaktifan berlaku seketika.
 */
export const config = {
  matcher: [
    '/((?!_next/static|_next/image|favicon.ico|icons|manifest\\.json|sw\\.js|workbox-.*\\.js|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|woff|woff2)$).*)',
  ],
}
