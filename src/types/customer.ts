import { Baby, GraduationCap, User, UserRound, Sparkles, Repeat } from 'lucide-react'
import type { ChoiceOption } from '@/components/ui/SegmentedChoice'

/**
 * Profil pembeli — perkiraan driver, bukan data identitas.
 *
 * Tidak ada nama, nomor telepon, atau apa pun yang menunjuk ke orang
 * tertentu. Hanya kelompok kasar, cukup untuk melihat pola: siapa yang
 * membeli, jam berapa, dan rasa apa.
 */
export type CustomerGender = 'male' | 'female'
export type CustomerAgeRange = 'kid' | 'teen' | 'young_adult' | 'adult' | 'senior'
export type CustomerType = 'new' | 'returning'

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

export const CUSTOMER_TYPE_OPTIONS: ChoiceOption<CustomerType>[] = [
  { value: 'new', label: 'Baru', icon: Sparkles },
  { value: 'returning', label: 'Langganan', icon: Repeat },
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

export const TYPE_LABEL: Record<string, string> = {
  new: 'Pelanggan baru',
  returning: 'Langganan',
  unknown: 'Tidak dicatat',
}

export const SEGMENT_ORDER: Record<string, string[]> = {
  gender: ['male', 'female', 'unknown'],
  age: ['kid', 'teen', 'young_adult', 'adult', 'senior', 'unknown'],
  type: ['new', 'returning', 'unknown'],
}
