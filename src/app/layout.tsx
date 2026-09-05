import type { Metadata, Viewport } from "next"
import localFont from "next/font/local"
import "./globals.css"

const geistSans = localFont({
  src: "./fonts/GeistVF.woff",
  variable: "--font-geist-sans",
  weight: "100 900",
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
    <html lang="id">
      <body className={`${geistSans.className} antialiased bg-[#FAF9F6] text-zinc-900`}>
        {children}
      </body>
    </html>
  )
}
