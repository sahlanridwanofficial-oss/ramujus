import type { Metadata, Viewport } from "next"
import { Plus_Jakarta_Sans, Baloo_2 } from "next/font/google"
import "./globals.css"

/**
 * Huruf merek, sesuai Bab 05 Brand Handbook.
 *
 * Sebelumnya aplikasi memakai `font-sans` bawaan sistem — artinya tampil
 * beda di setiap perangkat, dan tidak satu pun di antaranya adalah huruf
 * RAMU. Dimuat lewat next/font supaya berkasnya ikut dilayani dari domain
 * sendiri: tidak ada permintaan ke server font pihak ketiga, dan tidak ada
 * kedipan teks saat huruf selesai diunduh — dua hal yang langsung terasa
 * di HP driver dengan sinyal seadanya.
 */

const jakarta = Plus_Jakarta_Sans({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700", "800"],
  variable: "--font-jakarta",
  display: "swap",
})

/** Hanya untuk judul dan angka besar. Terlalu berat untuk teks panjang. */
const baloo = Baloo_2({
  subsets: ["latin"],
  weight: ["600", "700", "800"],
  variable: "--font-baloo",
  display: "swap",
})

export const metadata: Metadata = {
  title: "ramu. — Smoothie Sales System",
  description: "Sistem operasional penjualan smoothies ramu.",
  manifest: "/manifest.json",
  icons: {
    icon: "/logo.png",
    apple: "/icon-192.png",
  },
  appleWebApp: {
    capable: true,
    statusBarStyle: "default",
    title: "ramu.",
  },
}

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  userScalable: false,
  themeColor: "#be1a1a",
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html lang="id" className={`${jakarta.variable} ${baloo.variable}`}>
      <body className="font-sans antialiased bg-canvas text-zinc-900">
        {children}
      </body>
    </html>
  )
}
