'use client'

interface LogoProps {
  className?: string
  height?: number
  alt?: string
}

export default function Logo({ className = '', height = 32, alt = 'ramu.' }: LogoProps) {
  // Official ramu. logo ratio is ~3.71:1
  return (
    <div className={`inline-flex items-center select-none ${className}`}>
      <img
        src="/logo.png"
        alt={alt}
        className="object-contain block transition-transform duration-200"
        style={{ height: `${height}px`, width: 'auto' }}
        loading="eager"
      />
    </div>
  )
}
