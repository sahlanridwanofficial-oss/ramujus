import type { Metadata, Viewport } from "next"
import "./globals.css"

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
      <body className="font-sans antialiased bg-[#FAF9F6] text-zinc-900">
        {children}
      </body>
    </html>
  )
}

