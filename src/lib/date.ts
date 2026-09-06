/**
 * Tanggal dan rentang hari dalam zona waktu operasional: WIB (Asia/Jakarta).
 *
 * Seluruh fungsi database (create_order, ringkasan admin, laporan) sudah
 * menghitung "hari ini" dan tanggal alokasi dengan `AT TIME ZONE
 * 'Asia/Jakarta'`. Sebelumnya sisi klien memakai tanggal UTC lewat
 * `new Date().toISOString().slice(0,10)`, yang batas harinya jatuh pukul
 * 07:00 WIB — tujuh jam meleset dari server. Akibatnya angka "hari ini" di
 * dashboard admin (server, WIB) tidak cocok dengan dashboard driver (UTC),
 * dan alokasi muatan yang dicari driver bisa berbeda tanggal dari yang
 * dipotong server untuk penjualan larut malam.
 *
 * Modul ini menjadi satu-satunya sumber tanggal di sisi klien, supaya admin,
 * driver, dan database memakai kalender yang sama.
 */

const JAKARTA_TZ = 'Asia/Jakarta'
const JAKARTA_OFFSET = '+07:00' // WIB tidak mengenal daylight saving.

// en-CA memformat sebagai YYYY-MM-DD, cocok untuk kolom DATE dan input tanggal.
const dateFormatter = new Intl.DateTimeFormat('en-CA', {
  timeZone: JAKARTA_TZ,
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
})

/** Tanggal kalender hari ini menurut WIB, sebagai 'YYYY-MM-DD'. */
export function jakartaToday(): string {
  return dateFormatter.format(new Date())
}

/** Menggeser 'YYYY-MM-DD' sejumlah hari kalender, hasil tetap 'YYYY-MM-DD'. */
export function shiftDate(dateStr: string, days: number): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  const shifted = new Date(Date.UTC(y, m - 1, d) + days * 86_400_000)
  const yy = shifted.getUTCFullYear()
  const mm = String(shifted.getUTCMonth() + 1).padStart(2, '0')
  const dd = String(shifted.getUTCDate()).padStart(2, '0')
  return `${yy}-${mm}-${dd}`
}

/**
 * Rentang satu hari kalender WIB sebagai timestamptz, setengah terbuka:
 * `[start, endExclusive)`.
 *
 * Offset +07:00 disertakan supaya perbandingan `created_at` (timestamptz)
 * benar-benar mengikuti batas tengah malam WIB, bukan tengah malam server.
 * Batas atas eksklusif menghindari celah 1 detik dari pola lama
 * `...T23:59:59`, yang melewatkan transaksi pada detik terakhir.
 */
export function jakartaDayRange(dateStr: string): { start: string; endExclusive: string } {
  return {
    start: `${dateStr}T00:00:00${JAKARTA_OFFSET}`,
    endExclusive: `${shiftDate(dateStr, 1)}T00:00:00${JAKARTA_OFFSET}`,
  }
}
