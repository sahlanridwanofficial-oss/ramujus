'use client'

import { useState } from 'react'
import { UserRound, ChevronDown, Check, type LucideIcon } from 'lucide-react'
import {
  GENDER_OPTIONS, AGE_OPTIONS, CUSTOMER_TYPE_OPTIONS,
  GENDER_LABEL, AGE_LABEL, TYPE_LABEL,
  type CustomerGender, type CustomerAgeRange, type CustomerType,
} from '@/types/customer'

interface CustomerPersonaProps {
  gender: CustomerGender | null
  age: CustomerAgeRange | null
  type: CustomerType | null
  onGender: (v: CustomerGender | null) => void
  onAge: (v: CustomerAgeRange | null) => void
  onType: (v: CustomerType | null) => void
}

/**
 * Pencatatan pembeli untuk driver di lapangan.
 *
 * Dirancang ulang agar jelas dan cepat: tombol besar (mudah ditekan dengan
 * ibu jari sambil memegang minuman), satu kata per pilihan, dan tertutup
 * secara bawaan dengan ajakan yang tegas bahwa bagian ini boleh dilewati.
 * Semua opsional; menekan pilihan yang sama membatalkannya.
 */
export default function CustomerPersona({
  gender, age, type, onGender, onAge, onType,
}: CustomerPersonaProps) {
  const [open, setOpen] = useState(false)
  const filled = [gender, age, type].filter(Boolean).length

  // Ringkasan singkat untuk ditampilkan saat tertutup tapi sudah terisi.
  const summary = [
    gender ? GENDER_LABEL[gender] : null,
    age ? AGE_LABEL[age] : null,
    type ? TYPE_LABEL[type] : null,
  ].filter(Boolean).join(' · ')

  return (
    <div className="border-t border-zinc-100 pt-3">
      <button
        type="button"
        onClick={() => setOpen(v => !v)}
        className="w-full flex items-center gap-3 text-left"
      >
        <span className={`w-9 h-9 shrink-0 rounded-xl flex items-center justify-center ${
          filled > 0 ? 'bg-brand text-white' : 'bg-zinc-100 text-zinc-500'
        }`}>
          {filled > 0 ? <Check className="w-4 h-4" strokeWidth={3} /> : <UserRound className="w-4 h-4" />}
        </span>
        <span className="flex-1 min-w-0">
          <span className="block text-xs font-bold text-zinc-800">
            {filled > 0 ? 'Data pembeli tercatat' : 'Catat data pembeli?'}
          </span>
          <span className="block text-[11px] text-zinc-400 truncate">
            {filled > 0 ? summary : 'Boleh dilewati kalau sedang ramai'}
          </span>
        </span>
        <ChevronDown className={`w-4 h-4 text-zinc-400 shrink-0 transition-transform ${open ? 'rotate-180' : ''}`} />
      </button>

      {open && (
        <div className="mt-3 space-y-4 animate-in fade-in slide-in-from-top-1 duration-200">
          <p className="text-[11px] text-zinc-400 leading-relaxed">
            Cukup perkiraan dari penampilan. Isi seperlunya, atau lewati semua.
          </p>

          <PersonaGroup title="Jenis kelamin" columns={2}>
            {GENDER_OPTIONS.map(o => (
              <PersonaButton
                key={o.value}
                icon={o.icon}
                label={o.label}
                active={gender === o.value}
                onClick={() => onGender(gender === o.value ? null : o.value)}
              />
            ))}
          </PersonaGroup>

          <PersonaGroup title="Perkiraan umur" columns={3}>
            {AGE_OPTIONS.map(o => (
              <PersonaButton
                key={o.value}
                icon={o.icon}
                label={o.label}
                active={age === o.value}
                onClick={() => onAge(age === o.value ? null : o.value)}
              />
            ))}
          </PersonaGroup>

          <PersonaGroup title="Tipe pembeli" columns={2}>
            {CUSTOMER_TYPE_OPTIONS.map(o => (
              <PersonaButton
                key={o.value}
                icon={o.icon}
                label={o.label}
                active={type === o.value}
                onClick={() => onType(type === o.value ? null : o.value)}
              />
            ))}
          </PersonaGroup>

          {filled > 0 && (
            <button
              type="button"
              onClick={() => { onGender(null); onAge(null); onType(null) }}
              className="text-[11px] font-semibold text-zinc-400 hover:text-[#be1a1a] transition-colors"
            >
              Kosongkan semua
            </button>
          )}
        </div>
      )}
    </div>
  )
}

function PersonaGroup({
  title, columns, children,
}: { title: string; columns: 2 | 3; children: React.ReactNode }) {
  return (
    <div>
      <span className="block text-[11px] font-bold text-zinc-500 mb-1.5">{title}</span>
      <div className={`grid gap-2 ${columns === 2 ? 'grid-cols-2' : 'grid-cols-3'}`}>
        {children}
      </div>
    </div>
  )
}

function PersonaButton({
  icon: Icon, label, active, onClick,
}: {
  icon?: LucideIcon
  label: string
  active: boolean
  onClick: () => void
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={`flex flex-col items-center justify-center gap-1 min-h-[58px] rounded-xl border-2 transition-all active:scale-[0.97] ${
        active
          ? 'bg-brand border-brand text-white shadow-card'
          : 'bg-white border-zinc-200 text-zinc-700 hover:border-zinc-300'
      }`}
    >
      {Icon && <Icon className="w-5 h-5" strokeWidth={2} />}
      <span className="text-sm font-bold leading-none">{label}</span>
    </button>
  )
}
