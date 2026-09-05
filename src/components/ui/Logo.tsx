'use client'

import Image from 'next/image'

interface LogoProps {
  className?: string
  height?: number
  alt?: string
  priority?: boolean
}

export default function Logo({
  className = '',
  height = 32,
  alt = 'ramu.',
  priority = true,
}: LogoProps) {
  // Official ramu. logo ratio is ~3.71:1 (1024 / 276)
  const width = Math.round(height * 3.71)

  return (
    <div className={`inline-flex items-center select-none ${className}`}>
      <Image
        src="/logo.png"
        alt={alt}
        width={width}
        height={height}
        priority={priority}
        className="object-contain block transition-transform duration-200"
        style={{ height: `${height}px`, width: 'auto' }}
      />
    </div>
  )
}
