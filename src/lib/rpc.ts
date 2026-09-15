/**
 * Membaca hasil RPC Supabase dengan jujur.
 *
 * supabase-js TIDAK melempar exception saat panggilan RPC gagal — ia
 * mengembalikan `{ data: null, error }`. Halaman admin dulu mengabaikan
 * `error` dan langsung memakai `data ?? 0`, jadi database yang menolak
 * (fungsi belum ada karena migrasi belum dijalankan, peran bukan admin,
 * cache skema PostgREST masih versi lama) tampil di layar sebagai angka
 * "0" yang meyakinkan. Itulah sebabnya dashboard bisa menunjukkan 0 cup
 * padahal driver sudah menjual: bukan datanya kosong, melainkan
 * pertanyaannya tidak pernah terjawab.
 *
 * Modul ini mengubah kegagalan diam itu menjadi pesan yang bisa
 * ditindaklanjuti.
 */

export interface RpcErrorLike {
  message?: string
  code?: string
  details?: string | null
  hint?: string | null
}

/** Migrasi terbaru yang harus dijalankan agar seluruh angka admin lengkap. */
export const LATEST_MIGRATION = 'supabase/migrations/0036_takaran_air_dan_susu.sql'

/**
 * Benar bila fungsi yang dipanggil tidak dikenal database — hampir selalu
 * berarti berkas migrasi belum dijalankan di proyek Supabase yang dipakai.
 */
export function isMissingFunction(error: RpcErrorLike | null | undefined): boolean {
  if (!error) return false
  // PGRST202: PostgREST tidak menemukan fungsi pada cache skemanya.
  // 42883:    Postgres — function does not exist.
  if (error.code === 'PGRST202' || error.code === '42883') return true
  return /could not find the function|does not exist/i.test(error.message ?? '')
}

/** Pesan berbahasa Indonesia yang menyebut langkah perbaikannya. */
export function describeRpcError(
  error: RpcErrorLike | null | undefined,
  fnName: string
): string {
  if (!error) return ''
  if (isMissingFunction(error)) {
    return `Fungsi database "${fnName}" belum ada. Jalankan ${LATEST_MIGRATION} di SQL Editor Supabase, lalu muat ulang halaman ini.`
  }
  if (error.code === '42501' || /permission denied/i.test(error.message ?? '')) {
    return `Akun ini tidak diizinkan membaca "${fnName}". Pastikan profilnya berperan admin.`
  }
  return `Gagal membaca "${fnName}" dari server: ${error.message ?? 'penyebab tidak diketahui'}.`
}

/**
 * PostgREST mengembalikan fungsi RETURNS TABLE sebagai larik baris, tetapi
 * fungsi berbaris tunggal dapat pula datang sebagai objek. Satu titik
 * normalisasi supaya setiap pemanggil tidak menuliskan ulang tebakan itu.
 */
export function firstRow<T>(data: unknown): T | null {
  if (data == null) return null
  if (Array.isArray(data)) return (data.length > 0 ? (data[0] as T) : null)
  return data as T
}
