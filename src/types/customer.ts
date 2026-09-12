import { Baby, GraduationCap, User, UserRound, MessageSquareQuote, BookOpenText, type LucideIcon } from 'lucide-react'

/** Satu opsi pilihan persona: nilai, label tampil, dan ikon opsional. */
export interface ChoiceOption<T extends string> {
  value: T
  label: string
  icon?: LucideIcon
}

/**
 * Profil pembeli — perkiraan driver, bukan data identitas.
 *
 * Tidak ada nama, nomor telepon, atau apa pun yang menunjuk ke orang
 * tertentu. Hanya kelompok kasar, cukup untuk melihat pola: siapa yang
 * membeli, jam berapa, dan rasa apa.
 */
export type CustomerGender = 'male' | 'female'
export type CustomerAgeRange = 'kid' | 'teen' | 'young_adult' | 'adult' | 'senior'
/**
 * Cara pembeli memesan — pengganti `customer_type` yang lama.
 *
 * Yang lama menanyakan "orang ini pernah beli?", dan itu soal INGATAN:
 * driver tidak hafal wajah, jadi hampir semuanya tercatat "baru" dan
 * angkanya tidak pernah berarti apa-apa.
 *
 * Yang ini menanyakan apa yang terjadi di depan mata sekarang, dan driver
 * selalu bisa menjawabnya jujur. Orang yang menyebut nama menu tanpa
 * melihat daftar berarti namanya sudah keluar dari gerobak — entah ia
 * pernah beli, entah ada yang bercerita kepadanya.
 */
export type CaraPesan = 'sebut' | 'lihat'

export const GENDER_OPTIONS: ChoiceOption<CustomerGender>[] = [
  { value: 'male', label: 'Cowok', icon: User },
  { value: 'female', label: 'Cewek', icon: UserRound },
]

// Lima kelompok saja. Lebih banyak dari itu membuat driver ragu memilih,
// dan keraguan di depan pembeli lebih mahal daripada data yang lebih halus.
export const AGE_OPTIONS: ChoiceOption<CustomerAgeRange>[] = [
  { value: 'kid', label: 'Anak', icon: Baby },
  { value: 'teen', label: 'Remaja', icon: GraduationCap },
  { value: 'young_adult', label: '20-35' },
  { value: 'adult', label: '36-50' },
  { value: 'senior', label: '50+' },
]

export const CARA_PESAN_OPTIONS: ChoiceOption<CaraPesan>[] = [
  { value: 'sebut', label: 'Sebut menu', icon: MessageSquareQuote },
  { value: 'lihat', label: 'Lihat menu', icon: BookOpenText },
]

/** Label siap tampil untuk laporan admin. */
export const GENDER_LABEL: Record<string, string> = {
  male: 'Cowok',
  female: 'Cewek',
  unknown: 'Tidak dicatat',
}

export const AGE_LABEL: Record<string, string> = {
  kid: 'Anak',
  teen: 'Remaja',
  young_adult: '20-35 th',
  adult: '36-50 th',
  senior: '50+ th',
  unknown: 'Tidak dicatat',
}

export const CARA_PESAN_LABEL: Record<string, string> = {
  sebut: 'Sebut menu tanpa lihat',
  lihat: 'Lihat menu dulu',
  unknown: 'Tidak dicatat',
}

export const SEGMENT_ORDER: Record<string, string[]> = {
  gender: ['male', 'female', 'unknown'],
  age: ['kid', 'teen', 'young_adult', 'adult', 'senior', 'unknown'],
  cara_pesan: ['sebut', 'lihat', 'unknown'],
}
