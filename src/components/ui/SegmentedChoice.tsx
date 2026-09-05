'use client'

import type { LucideIcon } from 'lucide-react'

export interface ChoiceOption<T extends string> {
  value: T
  label: string
  icon?: LucideIcon
}

interface SegmentedChoiceProps<T extends string> {
  label: string
  hint?: string
  options: ChoiceOption<T>[]
  value: T | null
  onChange: (value: T | null) => void
}

/**
 * Deretan pilihan satu-ketuk yang bisa dibatalkan.
 *
 * Dipakai driver sambil menyerahkan minuman, jadi target sentuhnya dibuat
 * besar dan pilihannya bisa dilepas dengan menekan ulang — bukan lewat
 * tombol "hapus" terpisah. Tidak ada pilihan yang wajib: driver yang sedang
 * melayani antrean panjang harus bisa melewatinya tanpa hambatan.
 */
export default function SegmentedChoice<T extends string>({
  label, hint, options, value, onChange,
}: SegmentedChoiceProps<T>) {
  return (
    <div>
      <div className="flex items-baseline justify-between mb-1.5">
        <span className="text-[11px] font-semibold text-zinc-500">{label}</span>
        {hint && <span className="text-[10px] text-zinc-400">{hint}</span>}
      </div>

      <div className="flex flex-wrap gap-1.5">
        {options.map(option => {
          const Icon = option.icon
          const active = value === option.value
          return (
            <button
              key={option.value}
              type="button"
              aria-pressed={active}
              // Menekan pilihan yang sama membatalkannya — driver yang salah
              // tekan tidak perlu mencari cara lain untuk mengosongkannya.
              onClick={() => onChange(active ? null : option.value)}
              className={`flex items-center gap-1.5 px-3 py-2 rounded-xl text-xs font-semibold transition-all active:scale-[0.97] ${
                active
                  ? 'bg-zinc-900 text-white shadow-card'
                  : 'bg-white text-zinc-600 border border-zinc-200 hover:border-zinc-300 hover:text-zinc-900'
              }`}
            >
              {Icon && <Icon className="w-3.5 h-3.5" strokeWidth={2} />}
              <span>{option.label}</span>
            </button>
          )
        })}
      </div>
    </div>
  )
}
