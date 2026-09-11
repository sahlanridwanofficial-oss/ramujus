import type { Config } from "tailwindcss"

const config: Config = {
  content: [
    "./src/pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/components/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      fontFamily: {
        // Teks yang dibaca. Dimuat di layout.tsx lewat next/font.
        sans: ["var(--font-jakarta)", "ui-sans-serif", "system-ui", "sans-serif"],
        // Judul dan angka besar saja — lihat Bab 05 Brand Handbook.
        display: ["var(--font-baloo)", "var(--font-jakarta)", "sans-serif"],
      },
      colors: {
        // Warna merek jadi token agar berhenti ditulis sebagai #be1a1a
        // literal di puluhan tempat — satu sumber kebenaran.
        brand: {
          DEFAULT: "#be1a1a",
          dark: "#a61515",
          soft: "#fef2f2",
          border: "#fecaca",
        },
        // Latar aplikasi. Krem hangat, bukan abu-abu netral: netral yang
        // dicondongkan ke merah membuat brand-nya terasa menyatu, bukan
        // ditempel di atas kertas dingin.
        canvas: "#FAF8F6",
        border: "hsl(var(--border))",
        input: "hsl(var(--input))",
        ring: "hsl(var(--ring))",
        background: "hsl(var(--background))",
        foreground: "hsl(var(--foreground))",
        primary: {
          DEFAULT: "hsl(var(--primary))",
          foreground: "hsl(var(--primary-foreground))",
        },
        secondary: {
          DEFAULT: "hsl(var(--secondary))",
          foreground: "hsl(var(--secondary-foreground))",
        },
        destructive: {
          DEFAULT: "hsl(var(--destructive))",
          foreground: "hsl(var(--destructive-foreground))",
        },
        muted: {
          DEFAULT: "hsl(var(--muted))",
          foreground: "hsl(var(--muted-foreground))",
        },
        accent: {
          DEFAULT: "hsl(var(--accent))",
          foreground: "hsl(var(--accent-foreground))",
        },
        popover: {
          DEFAULT: "hsl(var(--popover))",
          foreground: "hsl(var(--popover-foreground))",
        },
        card: {
          DEFAULT: "hsl(var(--card))",
          foreground: "hsl(var(--card-foreground))",
        },
      },
      borderRadius: {
        // Tangga sudut yang naik beraturan.
        //
        // Sebelumnya `rounded-lg` (dari --radius) dan `rounded-xl` (bawaan
        // Tailwind) sama-sama 0.75rem — dua nama untuk satu nilai. Itu yang
        // membuat kode memakai lima ukuran sudut secara acak: penulisnya
        // tidak bisa melihat bedanya, jadi memilihnya asal.
        //
        // Sekarang setiap langkah benar-benar berbeda, dan perannya jelas:
        // sm/md untuk lencana, lg untuk tombol & kolom isian, xl untuk
        // kartu, 2xl untuk panel besar.
        sm: "0.375rem",   //  6px — lencana kecil
        md: "0.5rem",     //  8px
        lg: "0.625rem",   // 10px — tombol, input
        xl: "0.875rem",   // 14px — kartu
        "2xl": "1.125rem",// 18px — panel, bagian besar
        "3xl": "1.5rem",  // 24px — jarang; hanya blok penuh lebar
      },
      boxShadow: {
        // Bayangan lembut berlapis dua: memberi kedalaman tanpa garis
        // gelap yang membuat antarmuka terasa berat.
        card: "0 1px 2px rgba(24,24,27,0.04), 0 1px 3px rgba(24,24,27,0.06)",
        "card-hover": "0 2px 4px rgba(24,24,27,0.05), 0 4px 12px rgba(24,24,27,0.08)",
        lifted: "0 4px 8px rgba(24,24,27,0.04), 0 12px 28px rgba(24,24,27,0.10)",
      },
      spacing: {
        "4.5": "1.125rem",
      },
    },
  },
  plugins: [],
}
export default config
