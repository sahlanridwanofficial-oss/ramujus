import Link from 'next/link'
import Logo from '@/components/ui/Logo'
import {
  BookOpen, Check, X, AlertTriangle, Eye, Blend, Sparkles, ArrowRight,
} from 'lucide-react'
import {
  CHAPTERS, PALETTE, CONTRAST_PAIRS, TYPE_ROLES, TAGLINE, TAGLINE_CONTRACT,
  MENU_NAMES, PRICE_TIERS, DRIVER_LINES, BRAND_LAWS, ROADMAP,
  HANDBOOK_EDITION, HANDBOOK_UPDATED,
} from '@/lib/brandHandbook'

export const metadata = {
  title: 'Brand Handbook — RAMU',
  description: 'Buku pegangan merek RAMU: identitas, suara, harga, dan aturan yang tidak dinegosiasikan.',
}

/* ── Blok bangunan halaman ──────────────────────────────────────────────── */

function Section({
  id, num, title, sub, children,
}: {
  id: string; num: string; title: string; sub: string; children: React.ReactNode
}) {
  return (
    <section id={id} className="scroll-mt-32 lg:scroll-mt-24 border-t border-zinc-200/80 pt-10 first:border-t-0 first:pt-0">
      <div className="flex items-baseline gap-3">
        <span className="text-[11px] font-bold text-brand tabular-nums pt-1 shrink-0">{num}</span>
        <h2 className="text-2xl lg:text-3xl font-bold tracking-tight text-zinc-900">{title}</h2>
      </div>
      <p className="mt-2 mb-7 text-sm text-zinc-500 max-w-2xl leading-relaxed">{sub}</p>
      <div className="space-y-4">{children}</div>
    </section>
  )
}

function H3({ children }: { children: React.ReactNode }) {
  return <h3 className="text-sm font-bold text-zinc-900 pt-3">{children}</h3>
}

function Prose({ children }: { children: React.ReactNode }) {
  return <p className="text-sm text-zinc-600 leading-relaxed max-w-2xl">{children}</p>
}

function Quote({ children }: { children: React.ReactNode }) {
  return (
    <blockquote className="border-l-[3px] border-brand pl-5 py-1 my-2">
      <p className="text-lg lg:text-xl font-bold tracking-tight text-zinc-900 leading-snug max-w-lg">
        {children}
      </p>
    </blockquote>
  )
}

function Callout({ children }: { children: React.ReactNode }) {
  return (
    <div className="border-l-[3px] border-brand bg-brand-soft rounded-r-xl px-5 py-4">
      <div className="text-sm text-zinc-700 leading-relaxed space-y-2">{children}</div>
    </div>
  )
}

function Panel({
  label, title, children, accent,
}: {
  label?: string; title: string; children: React.ReactNode; accent?: 'warn' | 'ok'
}) {
  const edge =
    accent === 'warn' ? 'border-l-[3px] border-l-amber-500'
    : accent === 'ok' ? 'border-l-[3px] border-l-emerald-600'
    : ''
  return (
    <div className={`bg-white rounded-2xl border border-zinc-200/80 shadow-card p-5 ${edge}`}>
      {label && (
        <span className="block text-[10px] font-bold uppercase tracking-wider text-zinc-400 mb-2">
          {label}
        </span>
      )}
      <h4 className="text-sm font-bold text-zinc-900 mb-1.5">{title}</h4>
      <p className="text-xs text-zinc-500 leading-relaxed">{children}</p>
    </div>
  )
}

function TableWrap({ children }: { children: React.ReactNode }) {
  return (
    <div className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-x-auto">
      <table className="w-full text-sm min-w-[520px]">{children}</table>
    </div>
  )
}

function Th({ children }: { children: React.ReactNode }) {
  return (
    <th className="text-left px-4 py-2.5 text-[10px] font-bold uppercase tracking-wider text-zinc-400 bg-zinc-50/80 whitespace-nowrap">
      {children}
    </th>
  )
}

function Td({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-3 align-top text-zinc-600 ${className}`}>{children}</td>
}

function DoDont({
  doTitle, doItems, noTitle, noItems,
}: {
  doTitle: string; doItems: string[]; noTitle: string; noItems: string[]
}) {
  return (
    <div className="grid gap-4 sm:grid-cols-2">
      {[
        { title: doTitle, items: doItems, ok: true },
        { title: noTitle, items: noItems, ok: false },
      ].map(({ title, items, ok }) => (
        <div key={title} className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
          <div className={`px-4 py-2 text-[10px] font-bold uppercase tracking-wider text-white ${ok ? 'bg-emerald-600' : 'bg-brand'}`}>
            {title}
          </div>
          <ul className="p-4 space-y-2.5">
            {items.map(item => (
              <li key={item} className="flex gap-2.5 text-xs text-zinc-600 leading-relaxed">
                {ok
                  ? <Check strokeWidth={2.5} className="w-3.5 h-3.5 text-emerald-600 shrink-0 mt-0.5" />
                  : <X strokeWidth={2.5} className="w-3.5 h-3.5 text-brand shrink-0 mt-0.5" />}
                <span>{item}</span>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </div>
  )
}

function Band({ n, law, note }: { n: string; law: string; note: string }) {
  return (
    <div className="bg-brand rounded-3xl px-6 py-8 lg:px-10 lg:py-10">
      <span className="text-[10px] font-bold uppercase tracking-wider text-white/60">{n}</span>
      <p className="mt-3 text-xl lg:text-3xl font-bold tracking-tight text-white leading-tight max-w-xl">
        {law}
      </p>
      <p className="mt-3 text-sm text-white/80 leading-relaxed max-w-xl">{note}</p>
    </div>
  )
}

/* Papan gerobak — dirender dengan warna cetak sebenarnya, bukan token tema. */
function CartSign({ inverted }: { inverted?: boolean }) {
  const bg = inverted ? '#BE1A1A' : '#FFFFFF'
  const mark = inverted ? '#FFFFFF' : '#BE1A1A'
  const cat = inverted ? '#FFFFFF' : '#1B1210'
  const tag = inverted ? 'rgba(255,255,255,.8)' : '#7A625C'
  return (
    <div
      className="rounded-2xl border border-zinc-200/80 px-6 py-8 text-center flex flex-col items-center justify-center min-h-[220px]"
      style={{ background: bg }}
    >
      <div className="text-4xl lg:text-5xl font-bold tracking-tighter leading-none" style={{ color: mark }}>
        ramu.
      </div>
      <div className="mt-3 text-[11px] font-bold tracking-[0.15em]" style={{ color: cat }}>
        SMOOTHIES &amp; JUS
      </div>
      <div className="mt-1.5 text-xs italic" style={{ color: tag }}>
        {TAGLINE}
      </div>
      <div
        className="mt-4 text-xs font-bold tabular-nums px-3.5 py-1.5 rounded-full"
        style={{ background: inverted ? '#FFFFFF' : '#BE1A1A', color: inverted ? '#BE1A1A' : '#FFFFFF' }}
      >
        mulai Rp13.000
      </div>
    </div>
  )
}

const STATUS_STYLE = {
  aman: { label: 'Aman', cls: 'bg-emerald-50 text-emerald-700 border-emerald-200' },
  pantau: { label: 'Pantau', cls: 'bg-amber-50 text-amber-700 border-amber-200' },
  ganti: { label: 'Wajib ganti', cls: 'bg-red-50 text-brand border-brand-border' },
} as const

/* ── Halaman ────────────────────────────────────────────────────────────── */

export default function HandbookPage() {
  return (
    <div className="pb-16">
      {/* Sampul */}
      <div className="mb-6">
        <div className="flex items-center gap-2 text-[10px] font-bold uppercase tracking-wider text-zinc-400">
          <BookOpen strokeWidth={2} className="w-3.5 h-3.5" />
          Brand Handbook · {HANDBOOK_EDITION}
        </div>
        <div className="mt-4 mb-3">
          <Logo height={56} />
        </div>
        <p className="text-sm text-zinc-500 max-w-md leading-relaxed">
          Satu-satunya sumber untuk cara RAMU terlihat, berbicara, dan bersikap.
          Kalau ada yang bertentangan dengan halaman ini, halaman ini yang benar.
        </p>
        <div className="mt-5 flex flex-wrap gap-x-6 gap-y-1.5 text-[11px] text-zinc-400 tabular-nums">
          <span>Kategori <b className="text-zinc-700">Jus &amp; Smoothies</b></span>
          <span>Kanal <b className="text-zinc-700">Gerobak keliling</b></span>
          <span>Warna <b className="text-zinc-700">#BE1A1A</b></span>
          <span>Diperbarui <b className="text-zinc-700">{HANDBOOK_UPDATED}</b></span>
        </div>
      </div>

      {/* Navigasi bab */}
      <nav
        aria-label="Daftar bab"
        className="sticky top-14 lg:top-0 z-20 -mx-4 lg:-mx-7 px-4 lg:px-7 py-2.5 mb-8 bg-canvas/90 backdrop-blur-sm border-y border-zinc-200/80"
      >
        <div className="flex gap-1.5 overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
          {CHAPTERS.map(({ id, num, title }) => (
            <Link
              key={id}
              href={`#${id}`}
              className="shrink-0 px-3 py-1.5 rounded-full text-[11px] font-semibold text-zinc-500 hover:text-brand hover:bg-red-50 transition-colors whitespace-nowrap"
            >
              <span className="text-zinc-300 mr-1.5 tabular-nums">{num}</span>
              {title}
            </Link>
          ))}
        </div>
      </nav>

      <div className="space-y-12">

        {/* 01 · INTI */}
        <Section
          id="inti" num="01" title="Inti"
          sub="Kalau seluruh buku ini hilang dan cuma satu bagian yang boleh disimpan, simpan bagian ini."
        >
          <Quote>RAMU menjual racikan buah — bukan buah, bukan minuman.</Quote>
          <Prose>
            Gerobak lain menjual <em>bahan</em>: jus alpukat, jus mangga, jus jeruk. Satu buah, satu
            gelas, tidak ada keahlian yang diklaim dan tidak ada yang bisa dilindungi.
          </Prose>
          <Prose>
            RAMU menjual <em>kombinasi</em>. Kombinasi tidak bisa ditiru dari luar gerobak, tidak bisa
            dibandingkan harganya satu lawan satu, dan memberi orang alasan untuk kembali mencoba yang
            lain. Di situlah seluruh merek ini berdiri.
          </Prose>

          <H3>Tiga fakta yang menopang semuanya</H3>
          <div className="grid gap-4 sm:grid-cols-3">
            <Panel label="Fakta 01" title="Teksturnya setara mal">
              Kental, es menyatu, bukan es serut mengambang. Ini yang memisahkan RAMU dari gerobak jus,
              dan ini tidak boleh turun.
            </Panel>
            <Panel label="Fakta 02" title="Harganya Rp13.000">
              Sepertiga harga mal untuk kualitas yang sama. Ini bukan kelemahan yang disembunyikan —
              ini alasan orang berhenti pertama kali.
            </Panel>
            <Panel label="Fakta 03" title="Yang coba, kembali">
              Pembelian ulang keesokan hari adalah bukti terkuat di bisnis minuman. Artinya hambatan
              RAMU bukan produk — tapi jangkauan.
            </Panel>
          </div>

          <H3>Musuh</H3>
          <Prose>
            Setiap merek butuh musuh yang jelas. Musuh RAMU bukan kafe dan bukan merek besar. Musuhnya
            adalah <strong className="text-zinc-900">gerobak jus yang isinya sirup, gula, dan es batu</strong> —
            dan kecurigaan yang ditinggalkannya di kepala orang: <em>&ldquo;paling juga air doang.&rdquo;</em>
          </Prose>
          <Prose>
            Setiap keputusan merek di buku ini punya satu tugas: mematahkan kecurigaan itu sebelum
            orang sempat mengucapkannya.
          </Prose>

          <DoDont
            doTitle="RAMU adalah"
            doItems={[
              'Merek jalanan yang produknya kelas mal',
              'Peracik — punya resep, punya rekomendasi',
              'Berani, cepat, hangat, tanpa basa-basi',
              'Bukti yang terlihat: buah diblender di depan pembeli',
            ]}
            noTitle="RAMU bukan"
            noItems={[
              'Merek spa, detoks, atau diet',
              'Merek kesehatan yang menakut-nakuti',
              'Merek murah yang bersaing dengan turun harga',
              'Jamu, herbal, atau obat tradisional',
            ]}
          />
        </Section>

        <Band
          n="Hukum pertama"
          law="Merah adalah pilihan, bukan kecelakaan."
          note="Seluruh kategori wellness memakai hijau. RAMU tidak. Konsekuensinya dijelaskan di bab berikutnya, dan konsekuensi itu wajib diikuti."
        />

        {/* 02 · POSISI */}
        <Section
          id="posisi" num="02" title="Posisi"
          sub="Ambisi RAMU adalah pasar wellness drink. Tapi RAMU berwarna merah — dan itu mengubah definisi 'wellness' yang boleh dipakai."
        >
          <Prose>
            Merek kesehatan di seluruh dunia memakai hijau, putih, dan warna tanah. Merah dipakai untuk
            selera makan, energi, dan kecepatan. Secara buku teks, merah adalah warna yang
            &ldquo;salah&rdquo; untuk wellness. Tapi merah punya dua hal yang tidak dimiliki hijau, dan
            keduanya kebetulan persis yang RAMU butuhkan:
          </Prose>
          <div className="grid gap-4 sm:grid-cols-2">
            <Panel label="Alasan 01" title="Terlihat dari jauh">
              Gerobak bergerak dan hanya punya beberapa detik di mata orang yang lewat. Merah adalah
              warna dengan jarak baca terjauh. Hijau di pinggir jalan hilang ditelan pepohonan dan spanduk.
            </Panel>
            <Panel label="Alasan 02" title="Sendirian di rak">
              Kalau semua pesaing hijau, merah otomatis diingat. Menjadi satu-satunya lebih berharga
              daripada menjadi yang paling benar.
            </Panel>
          </div>

          <Callout>
            <p>
              <strong className="text-brand">Konsekuensinya wajib:</strong> karena RAMU merah, wellness
              versi RAMU adalah <strong>tenaga dan segar</strong> — bukan detoks, bersih, tenang, atau
              langsing. Setiap kali RAMU bicara seperti merek hijau, warnanya akan berteriak berlawanan
              dengan kata-katanya, dan orang akan merasa ada yang tidak beres tanpa tahu kenapa.
            </p>
          </Callout>

          <TableWrap>
            <thead><tr><Th>Sumbu</Th><Th>Wellness hijau</Th><Th>Wellness RAMU</Th></tr></thead>
            <tbody className="divide-y divide-zinc-100">
              {[
                ['Janji', 'Membersihkan tubuh', 'Menyalakan hari'],
                ['Waktu pakai', 'Pagi, puasa, program', 'Siang panas, capek, haus'],
                ['Nada', 'Tenang, lembut, klinis', 'Berani, cepat, hangat'],
                ['Bukti', 'Label & klaim gizi', 'Buah diblender di depan mata'],
                ['Kata kunci', 'detoks, organik, bersih', 'segar, asli, nendang, kental'],
                ['Musuh', 'Gula', 'Sirup & es batu'],
              ].map(([a, b, c]) => (
                <tr key={a}>
                  <Td className="font-semibold text-zinc-900 whitespace-nowrap">{a}</Td>
                  <Td>{b}</Td>
                  <Td className="text-brand font-medium">{c}</Td>
                </tr>
              ))}
            </tbody>
          </TableWrap>

          <H3>Kalimat posisi</H3>
          <Quote>
            Untuk orang yang haus di jalan dan curiga jus gerobak cuma air gula — RAMU adalah racikan
            buah asli sekental smoothies mal, di harga yang bisa dibeli tiap hari.
          </Quote>
          <p className="text-xs text-zinc-400 leading-relaxed max-w-2xl">
            Kalimat ini tidak untuk dicetak di mana pun. Ini alat ukur internal: setiap ide baru dibaca
            ulang di sini, dan kalau tidak muat, ide itu bukan RAMU.
          </p>
        </Section>

        {/* 03 · LOGO */}
        <Section
          id="logo" num="03" title="Logo"
          sub="Wordmark ramu. — huruf kecil, geometris membulat, dengan titik."
        >
          <div className="grid gap-4 sm:grid-cols-3">
            <Panel label="Huruf kecil" title="Selalu ramu., tidak pernah RAMU.">
              Huruf kecil membuat merek yang berani ini tetap ramah. Kapital hanya boleh di teks papan
              yang dibuat dari huruf biasa, bukan dari file logo.
            </Panel>
            <Panel label="Titiknya" title="Titik itu bagian dari logo">
              Bukan tanda baca. Titik berarti selesai, yakin, tidak perlu dijelaskan lagi. Menghapusnya
              menghapus separuh sikap merek.
            </Panel>
            <Panel label="Satu versi" title="Tidak ada versi alternatif">
              Tidak ada versi ulang tahun atau musiman. Merek semuda ini tidak punya cukup ingatan orang
              untuk dibagi dua.
            </Panel>
          </div>

          <H3>Ukuran &amp; ruang kosong</H3>
          <TableWrap>
            <thead><tr><Th>Aturan</Th><Th>Nilai</Th><Th>Alasan</Th></tr></thead>
            <tbody className="divide-y divide-zinc-100">
              {[
                ['Ruang kosong minimum', '= tinggi huruf "a"', 'Di segala sisi. Tidak ada teks, garis, atau foto yang masuk.'],
                ['Ukuran minimum layar', '24 px tinggi', 'Di bawah itu titiknya hilang.'],
                ['Ukuran minimum cetak', '15 mm lebar', 'Untuk stiker cup dan struk.'],
                ['Di papan gerobak', '≥ 1/3 tinggi papan', 'Nama harus menang dari segalanya.'],
              ].map(([a, b, c]) => (
                <tr key={a}>
                  <Td className="font-semibold text-zinc-900">{a}</Td>
                  <Td className="tabular-nums whitespace-nowrap">{b}</Td>
                  <Td>{c}</Td>
                </tr>
              ))}
            </tbody>
          </TableWrap>

          <DoDont
            doTitle="Latar yang boleh"
            doItems={[
              'Merah #BE1A1A di atas putih',
              'Putih di atas merah #BE1A1A',
              'Merah di atas krem #FAF6F3',
              'Putih di atas foto gelap yang tenang',
            ]}
            noTitle="Jangan pernah"
            noItems={[
              'Merah di atas hitam — kontrasnya 3:1, tidak terbaca',
              'Diberi bayangan, gradasi, outline, atau efek timbul',
              'Dimiringkan, diregangkan, atau diubah jarak hurufnya',
              'Diketik ulang dengan font lain — selalu pakai file logo asli',
              'Diganti warnanya untuk mengikuti kemasan atau musim',
            ]}
          />
        </Section>

        {/* 04 · WARNA */}
        <Section
          id="warna" num="04" title="Warna"
          sub="Satu warna merek. Sisanya netral. Warna kedua datang dari buahnya sendiri."
        >
          <div className="grid gap-4 grid-cols-2 lg:grid-cols-3">
            {PALETTE.map(sw => (
              <div key={sw.hex} className="bg-white rounded-2xl border border-zinc-200/80 shadow-card overflow-hidden">
                <div
                  className={`h-20 flex items-end p-3 ${sw.needsBorder ? 'border-b border-zinc-200/80' : ''}`}
                  style={{ background: sw.hex }}
                >
                  <span className="text-[11px] font-bold tabular-nums" style={{ color: sw.on }}>
                    {sw.hex}
                  </span>
                </div>
                <div className="p-3.5">
                  <div className="text-xs font-bold text-zinc-900">{sw.name}</div>
                  <p className="mt-1 text-[11px] text-zinc-500 leading-relaxed">{sw.use}</p>
                </div>
              </div>
            ))}
          </div>

          <Callout>
            <p>
              <strong className="text-brand">Aturan warna kedua: buahnya yang jadi warna kedua.</strong>{' '}
              RAMU tidak punya warna pendukung — tidak ada hijau, oranye, atau kuning merek. Kuning
              datang dari mangga, merah muda dari semangka, ungu dari naga. Itu sebabnya foto buah dan
              cup asli wajib jadi elemen visual utama, dan itu sebabnya palet ini boleh sesederhana ini.
              Menambah warna merek kedua akan merusak aturan ini secara permanen.
            </p>
          </Callout>

          <H3>Pasangan yang aman dibaca</H3>
          <TableWrap>
            <thead><tr><Th>Teks</Th><Th>Latar</Th><Th>Rasio</Th><Th>Boleh dipakai untuk</Th></tr></thead>
            <tbody className="divide-y divide-zinc-100">
              {CONTRAST_PAIRS.map(p => (
                <tr key={`${p.text}-${p.bg}`} className={p.forbidden ? 'bg-red-50/50' : ''}>
                  <Td className="tabular-nums font-medium">{p.text}</Td>
                  <Td className="tabular-nums font-medium">{p.bg}</Td>
                  <Td className="tabular-nums whitespace-nowrap">{p.ratio}</Td>
                  <Td className={p.forbidden ? 'text-brand font-semibold' : ''}>{p.verdict}</Td>
                </tr>
              ))}
            </tbody>
          </TableWrap>

          <H3>Warna fungsi — khusus aplikasi admin &amp; driver</H3>
          <Prose>
            Warna ini bukan warna merek. Dipakai hanya untuk status di dalam sistem, tidak pernah di
            kemasan, papan, atau materi promosi.
          </Prose>
          <div className="grid gap-4 sm:grid-cols-3">
            {[
              { c: '#1F7A4C', n: 'Aman', d: 'Stok cukup, audit cocok, shift beres.' },
              { c: '#9A6407', n: 'Awas', d: 'Stok menipis, antrean offline menua, audit belum dikunci.' },
              { c: '#B3261E', n: 'Bahaya', d: 'Stok habis, angka audit mustahil, pesanan ditolak.' },
            ].map(({ c, n, d }) => (
              <div
                key={n}
                className="bg-white rounded-2xl border border-zinc-200/80 shadow-card p-5"
                style={{ borderLeft: `3px solid ${c}` }}
              >
                <h4 className="text-sm font-bold" style={{ color: c }}>{n} · {c}</h4>
                <p className="mt-1 text-xs text-zinc-500 leading-relaxed">{d}</p>
              </div>
            ))}
          </div>
          <p className="text-xs text-zinc-400 leading-relaxed max-w-2xl">
            Bahaya sengaja dibedakan dari Merah RAMU. Kalau warna merek dipakai untuk error, orang akan
            belajar bahwa merah artinya masalah — dan itu racun untuk merek yang seluruh identitasnya merah.
          </p>
        </Section>

        {/* 05 · HURUF */}
        <Section
          id="huruf" num="05" title="Huruf"
          sub="Tiga huruf, tiga tugas. Semuanya gratis di Google Fonts, supaya siapa pun yang mengerjakan RAMU bisa langsung pakai tanpa lisensi."
        >
          <div className="grid gap-4 sm:grid-cols-3">
            <Panel label="Judul" title="Baloo 2 · bobot 800">
              Judul, papan gerobak, nama racikan. Bentuknya membulat dan tebal — satu keluarga rasa
              dengan wordmark.
            </Panel>
            <Panel label="Teks" title="Plus Jakarta Sans · 400 / 600 / 800">
              Semua teks yang dibaca: menu, aplikasi, kemasan, media sosial. Dibuat untuk kota Jakarta,
              terbaca bersih di ukuran kecil.
            </Panel>
            <Panel label="Angka" title="JetBrains Mono · 400 / 700">
              Harga, jumlah, jam, kode. Angkanya selebar sama sehingga kolom di struk dan dashboard
              selalu lurus.
            </Panel>
          </div>

          <TableWrap>
            <thead><tr><Th>Peran</Th><Th>Huruf</Th><Th>Ukuran</Th><Th>Catatan</Th></tr></thead>
            <tbody className="divide-y divide-zinc-100">
              {TYPE_ROLES.map(t => (
                <tr key={t.role}>
                  <Td className="font-semibold text-zinc-900">{t.role}</Td>
                  <Td className="whitespace-nowrap">{t.font}</Td>
                  <Td className="tabular-nums whitespace-nowrap">{t.size}</Td>
                  <Td>{t.note}</Td>
                </tr>
              ))}
            </tbody>
          </TableWrap>

          <DoDont
            doTitle="Lakukan"
            doItems={[
              'Harga selalu ditulis penuh di struk: Rp13.000',
              'Baloo 2 hanya untuk judul dan nama racikan',
              'Satu ukuran naik minimal 25% dari ukuran di bawahnya',
            ]}
            noTitle="Hindari"
            noItems={[
              'Baloo 2 untuk paragraf — jadi berat dan lelah dibaca',
              'Menambah huruf keempat "biar variasi"',
              '13K atau 13rb di struk resmi — hanya boleh di papan',
              'Teks miring pada nama racikan',
            ]}
          />
        </Section>

        <Band
          n="Hukum kedua"
          law="Tagline itu hutang, bukan hiasan."
          note="Begitu 'Jagonya' tertulis di gerobak, pembeli menagihnya. Bab berikut adalah daftar tagihannya."
        />

        {/* 06 · TAGLINE */}
        <Section
          id="tagline" num="06" title="Tagline"
          sub="Jagonya Racikan Buah. Tidak diubah, tidak diterjemahkan, tidak dipendekkan."
        >
          <Quote>{TAGLINE}</Quote>
          <Prose>
            Tagline ini bekerja karena tiga hal: ia menutup jus <em>dan</em> smoothies sekaligus, ia
            benar secara fakta (RAMU memang menjual kombinasi, bukan buah tunggal), dan ia mengunci ke
            nama — <strong className="text-zinc-900">ramu → racikan</strong>. Nama dan tagline saling
            menopang. Itu jarang, dan itu tidak boleh dibongkar.
          </Prose>
          <Prose>
            Tagline bukan alat untuk menarik pembeli pertama; harga dan tekstur yang melakukan itu.{' '}
            <strong className="text-zinc-900">Tagline bekerja di pembelian kesepuluh</strong> — ia yang
            membuat orang menganggap RAMU sebagai tempat, bukan sekadar minuman yang kebetulan lewat.
          </Prose>

          <H3>Kontrak yang terbentuk otomatis</H3>
          <Prose>
            Menulis &ldquo;Jagonya&rdquo; berarti menandatangani ini. Kalau salah satu baris tidak
            terpenuhi, tagline berubah dari aset jadi bahan tertawaan.
          </Prose>
          <TableWrap>
            <thead><tr><Th>Yang RAMU janjikan</Th><Th>Yang pembeli harapkan</Th><Th>Bukti yang wajib ada</Th></tr></thead>
            <tbody className="divide-y divide-zinc-100">
              {TAGLINE_CONTRACT.map((row, i) => (
                <tr key={i}>
                  <Td className="font-bold text-zinc-900 whitespace-nowrap">{row.promise}</Td>
                  <Td className="italic">{row.expectation}</Td>
                  <Td className="text-zinc-700">{row.proof}</Td>
                </tr>
              ))}
            </tbody>
          </TableWrap>

          <DoDont
            doTitle="Tempatnya"
            doItems={[
              'Papan gerobak, di bawah kategori, ukuran paling kecil',
              'Stiker cup, satu baris',
              'Bio media sosial',
              'Spanduk dan seragam',
            ]}
            noTitle="Jangan"
            noItems={[
              'Jangan ganti — sekali diganti, ingatan orang mulai dari nol',
              'Jangan pendekkan jadi "Jagonya Racikan"',
              'Jangan lebih besar dari nama merek',
              'Jangan tempel di setiap sudut sampai jadi bising',
            ]}
          />
        </Section>

        {/* 07 · SUARA */}
        <Section
          id="suara" num="07" title="Suara"
          sub="RAMU bicara seperti orang yang jago masak — santai, yakin, tidak pernah menggurui."
        >
          <div className="grid gap-4 sm:grid-cols-2">
            <Panel label="Nada" title="Santai tapi yakin">
              Bahasa sehari-hari, kalimat pendek. Tidak formal, tidak kaku, tapi juga tidak berlebihan
              bercanda di hal penting seperti harga dan kebersihan.
            </Panel>
            <Panel label="Sapaan" title='"Kamu", bukan "Anda"'>
              Satu sapaan untuk semua kanal. &ldquo;Anda&rdquo; membuat gerobak terdengar seperti bank.
              Konsisten lebih penting daripada pilihannya sendiri.
            </Panel>
          </div>

          <DoDont
            doTitle="Suara RAMU"
            doItems={[
              '"Buah asli, diblender di depan kamu."',
              '"Baru pertama? Ambil yang ini dulu."',
              '"Kental. Bukan es batu doang."',
              '"Hari ini mangga lagi bagus-bagusnya."',
            ]}
            noTitle="Bukan suara RAMU"
            noItems={[
              '"Solusi kesehatan keluarga Anda."',
              '"Kaya akan antioksidan dan vitamin C."',
              '"Detox alami untuk tubuh ideal."',
              '"Nikmati sensasi kesegaran yang tiada tara."',
            ]}
          />

          <Callout>
            <p>
              <strong className="text-brand">Larangan keras — klaim kesehatan.</strong> RAMU tidak boleh
              menulis atau mengucapkan klaim seperti <em>menyembuhkan, menurunkan berat badan, detoks,
              meningkatkan imun, mengobati</em>. Alasannya dua: klaim kesehatan pada produk pangan diatur
              ketat di Indonesia dan bisa berujung masalah hukum saat merek membesar, dan klaim seperti
              itu adalah suara merek hijau — bertabrakan langsung dengan warna dan sikap RAMU.{' '}
              <strong>Cukup katakan apa yang ada di dalam gelas.</strong>
            </p>
          </Callout>

          <H3>Contoh nyata: keterangan stevia</H3>
          <Prose>
            Menu saat ini menulis <em>&ldquo;Pemanis alami dari daun stevia. 0 kalori, cocok untuk diet
            &amp; bebas gula.&rdquo;</em> Dua hal salah sekaligus.
          </Prose>
          <TableWrap>
            <thead><tr><Th>Masalah</Th><Th>Kenapa salah</Th></tr></thead>
            <tbody className="divide-y divide-zinc-100">
              <tr>
                <Td className="font-bold text-zinc-900 whitespace-nowrap">&ldquo;bebas gula&rdquo;</Td>
                <Td>
                  Yang nol kalori adalah stevianya, bukan minumannya. Minuman RAMU tetap mengandung gula
                  alami dari pisang, mangga, susu, dan salted caramel. Ini janji yang tidak sampai.
                </Td>
              </tr>
              <tr>
                <Td className="font-bold text-zinc-900 whitespace-nowrap">&ldquo;cocok untuk diet&rdquo;</Td>
                <Td>Klaim kesehatan — persis yang dilarang di atas.</Td>
              </tr>
            </tbody>
          </TableWrap>
          <Callout>
            <p>
              <strong className="text-brand">Perbaikannya:</strong> &ldquo;Stevia +2K — pemanis dari daun
              stevia, tanpa gula tambahan.&rdquo; Jujur, tetap menjual, dan tidak menjanjikan apa pun
              yang tidak bisa dibuktikan.
            </p>
          </Callout>
        </Section>

        {/* 08 · NAMA MENU */}
        <Section
          id="menu" num="08" title="Nama Menu"
          sub="Nama racikan RAMU bukan lelucon acak. Nama itu adalah resepnya sendiri — dan sistem itu yang harus dijaga."
        >
          <Prose>
            Setiap nama racikan RAMU adalah{' '}
            <strong className="text-zinc-900">akronim dari bahannya</strong>. Pembeli tertawa dulu karena
            kata itu terdengar familiar, lalu menghafal isinya tanpa sadar. Satu kata mengerjakan dua
            tugas sekaligus.
          </Prose>

          <TableWrap>
            <thead><tr><Th>Nama</Th><Th>Kepanjangan</Th><Th>Isi</Th><Th>Status</Th></tr></thead>
            <tbody className="divide-y divide-zinc-100">
              {MENU_NAMES.map(m => {
                const s = STATUS_STYLE[m.status]
                return (
                  <tr key={m.name}>
                    <Td className="font-bold text-zinc-900 whitespace-nowrap">{m.name}</Td>
                    <Td>
                      {m.expansion}
                      {m.note && <span className="block mt-1 text-xs text-zinc-400 leading-relaxed">{m.note}</span>}
                    </Td>
                    <Td className="whitespace-nowrap">{m.contents}</Td>
                    <Td>
                      <span className={`inline-block px-2 py-0.5 rounded-full border text-[10px] font-bold uppercase tracking-wide whitespace-nowrap ${s.cls}`}>
                        {s.label}
                      </span>
                    </Td>
                  </tr>
                )
              })}
            </tbody>
          </TableWrap>

          <Quote>Nama yang mengajarkan resepnya sendiri tidak perlu dijelaskan dua kali.</Quote>

          <H3>Satu nama yang wajib diganti: MPASI</H3>
          <Prose>Alasannya bukan soal merek — soal keselamatan pembeli.</Prose>
          <Prose>
            <strong className="text-zinc-900">MPASI</strong> adalah istilah baku untuk Makanan Pendamping
            ASI, makanan bayi 6–12 bulan. Ini bukan plesetan seperti BNN atau KPK; ini istilah aslinya,
            dipakai persis seperti itu oleh orang tua dan tenaga kesehatan. Racikan ini berisi{' '}
            <strong className="text-zinc-900">UHT milk</strong>, sementara susu sapi tidak dianjurkan
            sebagai minuman untuk bayi di bawah satu tahun.
          </Prose>
          <Prose>
            Nama lain kalau salah dipahami hanya memancing tawa. Nama ini bisa membuat orang tua salah
            memberi. Bedanya: BNN dan KPK jelas plesetan, sedangkan MPASI justru <em>terlalu tepat</em> artinya.
          </Prose>

          <Callout>
            <p><strong className="text-brand">Penggantinya, dengan sistem yang sama:</strong></p>
            <p className="text-lg font-bold text-brand tracking-tight">
              PAMAN — <span className="font-extrabold">PI</span>sang <span className="font-extrabold">MA</span>ngga <span className="font-extrabold">N</span>yusu
            </p>
            <p>
              Akronimnya tetap resep, &ldquo;Nyusu&rdquo;-nya konsisten dengan BNN, dan artinya hangat
              serta tidak mungkin disalahpahami. Cadangan: <strong>SAMPAN</strong> (Susu Mangga Pisang).
              Ganti sekarang selagi cetakan masih sedikit.
            </p>
          </Callout>

          <H3>Aturan penamaan racikan baru</H3>
          <ol className="rounded-2xl border border-zinc-200/80 overflow-hidden shadow-card divide-y divide-zinc-100">
            {[
              ['Akronimnya harus jadi daftar bahan', 'Ini sistem RAMU. Nama yang tidak mengajarkan isinya memutus pola yang sudah dikenal pelanggan.'],
              ['Kata akronimnya harus sudah dikenal orang', 'Kekuatan sistem ini datang dari kata familiar yang dipakai di tempat tak terduga.'],
              ['Sebutkan tanpa mengeja', 'Kalau pembeli harus mengeja namanya ke driver, nama itu gagal.'],
              ['Bisa diucapkan ibu-ibu tanpa canggung', 'Saringan paling praktis. Kalau seseorang malu menyebutkannya, ia akan menunjuk — dan merek kehilangan namanya.'],
              ['Jangan pakai istilah kesehatan atau makanan bayi', 'Pelajaran dari MPASI. Istilah yang artinya terlalu tepat lebih berbahaya daripada plesetan.'],
              ['Jangan pakai kata bermuatan agama', 'Tidak ada keuntungan yang sebanding dengan risikonya.'],
              ['Satu racikan wajib jadi "pintu masuk"', 'Selalu direkomendasikan untuk pembeli pertama. Saat ini perannya dipegang PASCA.'],
            ].map(([title, detail], i) => (
              <li key={title} className="flex gap-4 px-5 py-4 bg-white">
                <span className="text-[11px] font-bold text-brand tabular-nums pt-0.5 w-6 shrink-0">
                  {String(i + 1).padStart(2, '0')}
                </span>
                <div>
                  <b className="block text-sm font-bold text-zinc-900">{title}</b>
                  <span className="text-xs text-zinc-500 leading-relaxed">{detail}</span>
                </div>
              </li>
            ))}
          </ol>

          <Callout>
            <p>
              <strong className="text-brand">Empat dari lima racikan memakai pisang.</strong> Enak dan
              murah, tapi dua akibatnya nyata: tagline menjanjikan variasi <em>buah</em>, dan satu hari
              pisang mahal atau habis akan mematikan 80% menu sekaligus.{' '}
              <strong>Racikan berikutnya wajib tanpa pisang.</strong>
            </p>
          </Callout>
        </Section>

        {/* 09 · HARGA */}
        <Section
          id="harga" num="09" title="Harga"
          sub="Harga bukan angka administratif. Harga adalah pernyataan tentang seberapa berharga produk ini — dan pembeli membacanya begitu."
        >
          <H3>Masalah harga coret</H3>
          <Prose>
            Coretan <strong className="text-zinc-900">15K → 13K</strong> sudah bekerja: pembeli percaya
            harga sebenarnya 15K dan mereka sedang beruntung.{' '}
            <strong className="text-zinc-900">Jangkar harganya sudah terpasang.</strong> Yang salah cuma
            satu — jangkar itu tidak pernah ditagih.
          </Prose>
          <Prose>
            Promo tanpa tanggal berakhir bukan promo, itu harga. Dalam tiga bulan pembeli lupa 15K pernah
            ada, RAMU permanen jadi &ldquo;gerobak 13 ribu&rdquo;, dan menaikkan harga nanti akan terasa
            seperti memahalkan — padahal cuma kembali ke harga sendiri.
          </Prose>

          <Callout>
            <p>
              <strong className="text-brand">Aturan: setiap harga coret wajib punya tanggal berakhir yang
              tercetak.</strong> Satu baris di atas menu, bukan per item:
            </p>
            <p className="text-lg font-bold text-brand tracking-tight">HARGA PERKENALAN — sampai [tanggal]</p>
            <p>Sekarang coretannya jujur <em>dan</em> jadi alasan orang membeli sekarang, bukan nanti.</p>
          </Callout>

          <H3>Tangga harga mengikuti biaya bahan</H3>
          <Prose>
            Harga yang berbeda tanpa alasan yang terlihat membuat orang merasa dikadali. Harga yang
            berbeda karena <strong className="text-zinc-900">isinya memang berbeda</strong> diterima tanpa
            perlu dibela. Stroberi, selai kacang, dan kokoa murni adalah bahan yang pembeli sendiri tahu mahal.
          </Prose>
          <TableWrap>
            <thead><tr><Th>Tingkat</Th><Th>Racikan</Th><Th>Alasan</Th></tr></thead>
            <tbody className="divide-y divide-zinc-100">
              {PRICE_TIERS.map(t => (
                <tr key={t.price}>
                  <Td className="font-bold text-zinc-900 tabular-nums whitespace-nowrap">{t.price}</Td>
                  <Td className="font-medium text-zinc-700 whitespace-nowrap">{t.items}</Td>
                  <Td>{t.reason}</Td>
                </tr>
              ))}
            </tbody>
          </TableWrap>
          <Prose>
            15K bukan angka baru — sudah tercetak di menu sebagai harga coret. Jadi ini bukan kenaikan
            harga, ini berakhirnya promo untuk dua racikan. Nol penjelasan yang dibutuhkan.
          </Prose>

          <div className="grid gap-4 sm:grid-cols-3">
            <Panel label="Efek 01" title='13K jadi terasa "tengah"'>
              Saat semua 13K, 13K adalah harga tertinggi. Begitu ada tingkat 15K, 13K berubah jadi pilihan
              yang masuk akal — dan sebagian orang justru mengambil yang 15K.
            </Panel>
            <Panel label="Efek 02" title="Menu terlihat dipikirkan">
              Menu bertingkat membaca sebagai keputusan. Menu yang semua harganya sama membaca sebagai
              belum dihitung.
            </Panel>
            <Panel label="Batas" title="Maksimal 3 harga">
              Lebih dari itu driver salah sebut, uang kembalian jadi repot, dan pembeli berpikir terlalu
              lama di depan gerobak.
            </Panel>
          </div>

          <Callout>
            <p>
              <strong className="text-brand">Wajib dihitung dulu: modal bahan per racikan.</strong> Margin
              Rp5.000/cup itu rata-rata, bukan angka per menu. Sangat mungkin PASUTRI hanya untung
              Rp3.000 karena stroberi mahal, sementara PASCA untung Rp7.000 — artinya karamel sedang
              menomboki stroberi tanpa ada yang tahu. Hitung satu kali, di satu lembar kertas. Setelah
              itu tangga harga bukan tebakan, tapi keputusan.
            </p>
          </Callout>
        </Section>

        {/* 10 · GEROBAK */}
        <Section
          id="gerobak" num="10" title="Gerobak"
          sub="Gerobak adalah papan reklame RAMU. Ia hanya punya dua detik dan sepuluh meter."
        >
          <H3>Urutan wajib pada papan</H3>
          <Prose>
            Empat baris, ukurannya menurun. Urutan ini tidak boleh diacak, karena urutan inilah cara
            orang membacanya: <strong className="text-zinc-900">siapa → jual apa → berapa → kenapa.</strong>
          </Prose>

          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <CartSign />
              <p className="mt-2 text-[11px] text-zinc-400 text-center">
                Versi utama — merah di atas putih. Paling menyala di bawah matahari.
              </p>
            </div>
            <div>
              <CartSign inverted />
              <p className="mt-2 text-[11px] text-zinc-400 text-center">
                Versi bidang penuh — untuk sisi gerobak dan spanduk.
              </p>
            </div>
          </div>

          <TableWrap>
            <thead><tr><Th>Baris</Th><Th>Isi</Th><Th>Tugasnya</Th></tr></thead>
            <tbody className="divide-y divide-zinc-100">
              {[
                ['1 · terbesar', 'ramu.', 'Yang harus diingat'],
                ['2', 'SMOOTHIES & JUS', 'Supaya tidak dikira jamu atau herbal'],
                ['3', 'mulai Rp13.000', 'Menahan orang yang mengira smoothies pasti mahal'],
                ['4 · terkecil', TAGLINE, 'Untuk yang sudah berhenti di depan gerobak'],
              ].map(([a, b, c]) => (
                <tr key={a}>
                  <Td className="tabular-nums whitespace-nowrap text-zinc-400">{a}</Td>
                  <Td className="font-semibold text-zinc-900">{b}</Td>
                  <Td>{c}</Td>
                </tr>
              ))}
            </tbody>
          </TableWrap>

          <Callout>
            <p>
              <strong className="text-brand">Kenapa &ldquo;SMOOTHIES &amp; JUS&rdquo; tidak boleh
              hilang:</strong> kata &ldquo;RAMU&rdquo; sendirian di Indonesia terdengar seperti ramuan,
              jamu, atau herbal. Baris kedua itu satu-satunya yang mencegah salah paham dari seberang
              jalan. Baris ini baru boleh dibuang kalau RAMU sudah menjual lebih dari jus dan smoothies —
              bukan sekadar setelah RAMU terkenal.
            </p>
          </Callout>

          <H3>Uji sepuluh meter</H3>
          <Prose>
            Sebelum papan apa pun dicetak, berdiri sepuluh meter dari desainnya. Kalau nama dan kategori
            tidak terbaca dalam dua detik, papannya salah — bukan matanya.
          </Prose>

          <H3>Yang harus terlihat di gerobak, selain papan</H3>
          <div className="grid gap-4 sm:grid-cols-3">
            {[
              { Icon: Sparkles, t: 'Buah asli', d: 'Diletakkan terlihat, bukan disembunyikan di kotak. Buah adalah iklan yang tidak perlu dibayar dan bukti yang tidak bisa dibantah.' },
              { Icon: Blend, t: 'Blender menghadap pembeli', d: 'Melihat proses adalah keunggulan gerobak yang tidak dimiliki mal. Jangan membelakangi pembeli saat meracik.' },
              { Icon: Eye, t: 'Gerobak bersih & kering', d: 'Untuk minuman buah, kebersihan bukan nilai tambah — kebersihan adalah syarat. Satu genangan lengket menghapus semua isi buku ini.' },
            ].map(({ Icon, t, d }) => (
              <div key={t} className="bg-white rounded-2xl border border-zinc-200/80 shadow-card p-5">
                <Icon strokeWidth={1.75} className="w-4 h-4 text-brand mb-2.5" />
                <h4 className="text-sm font-bold text-zinc-900 mb-1.5">{t}</h4>
                <p className="text-xs text-zinc-500 leading-relaxed">{d}</p>
              </div>
            ))}
          </div>
        </Section>

        {/* 11 · DRIVER */}
        <Section
          id="driver" num="11" title="Driver"
          sub="Pelanggan tidak pernah bertemu pemilik, logo, atau buku ini. Mereka bertemu driver. Driver adalah merek."
        >
          <Prose>
            Tagline &ldquo;Jagonya&rdquo; diuji di satu momen, dan momen itu selalu sama:{' '}
            <strong className="text-zinc-900">&ldquo;Mas, yang enak apa?&rdquo;</strong>
          </Prose>
          <Prose>
            Kalau jawabannya <em>&ldquo;terserah, Mas&rdquo;</em>, tagline mati di detik itu — dan tidak
            ada spanduk, warna, atau font yang bisa menyelamatkannya. Ini satu-satunya bagian merek yang
            tidak bisa diperbaiki dengan desain.
          </Prose>

          <H3>Tiga kalimat wajib hafal</H3>
          <div className="space-y-3">
            {DRIVER_LINES.map((d, i) => (
              <div key={d.line} className="bg-white rounded-2xl border border-zinc-200/80 shadow-card p-5 flex gap-4">
                <span className="text-[11px] font-bold text-brand tabular-nums pt-1 shrink-0">
                  {String(i + 1).padStart(2, '0')}
                </span>
                <div>
                  <p className="text-sm font-bold text-zinc-900 leading-snug">{d.line}</p>
                  <p className="mt-1 text-xs text-zinc-500 leading-relaxed">{d.why}</p>
                </div>
              </div>
            ))}
          </div>

          <DoDont
            doTitle="Wajib"
            doItems={[
              'Kaus RAMU bersih, warna merah atau putih',
              'Tangan bersih, kuku pendek, wadah tertutup',
              'Menyapa lebih dulu, tidak menunggu ditanya',
              'Harga diucapkan penuh: "tiga belas ribu"',
            ]}
            noTitle="Merusak merek"
            noItems={[
              'Bermain HP saat ada orang mendekat',
              'Menawar-nawar harga sendiri',
              'Mengubah takaran supaya "irit"',
              'Menjanjikan khasiat kesehatan',
            ]}
          />

          <Callout>
            <p>
              <strong className="text-brand">Konsistensi rasa adalah bagian dari merek, bukan bagian dari
              dapur.</strong> &ldquo;Jago&rdquo; berarti rasa hari ini sama dengan rasa besok. Takaran
              harus diukur, bukan dikira-kira. Satu gelas yang lebih encer dari biasanya lebih merusak
              daripada satu hari tidak berjualan.
            </p>
          </Callout>
        </Section>

        <Band
          n="Hukum ketiga"
          law="Merek mati saat harapan lebih besar dari bukti."
          note="Bukan karena janjinya jelek. Hari ini bukti RAMU lebih besar dari janjinya — itu posisi yang benar, dan itu yang harus dijaga selama sepuluh tahun."
        />

        {/* 12 · HUKUM */}
        <Section
          id="hukum" num="12" title="Hukum"
          sub="Dua belas hal yang tidak dinegosiasikan, siapa pun yang meminta, sebesar apa pun tawarannya."
        >
          <ol className="rounded-2xl border border-zinc-200/80 overflow-hidden shadow-card divide-y divide-zinc-100">
            {BRAND_LAWS.map((law, i) => (
              <li key={law.title} className="flex gap-4 px-5 py-4 bg-white">
                <span className="text-[11px] font-bold text-brand tabular-nums pt-0.5 w-6 shrink-0">
                  {String(i + 1).padStart(2, '0')}
                </span>
                <div>
                  <b className="block text-sm font-bold text-zinc-900">{law.title}</b>
                  <span className="text-xs text-zinc-500 leading-relaxed">{law.detail}</span>
                </div>
              </li>
            ))}
          </ol>
        </Section>

        {/* 13 · PETA */}
        <Section
          id="peta" num="13" title="Peta 10 Tahun"
          sub="Merek dibangun berlapis. Melompati satu lapis membuat lapis di atasnya runtuh."
        >
          <div className="divide-y divide-zinc-200/80 border-y border-zinc-200/80">
            {ROADMAP.map(p => (
              <div key={p.when} className="py-5 grid gap-4 sm:grid-cols-[120px_1fr]">
                <div className="text-[11px] font-bold uppercase tracking-wide text-brand pt-1">
                  {p.when}
                </div>
                <div>
                  <h4 className="text-base font-bold text-zinc-900 tracking-tight mb-1.5">{p.title}</h4>
                  <p className="text-sm text-zinc-600 leading-relaxed">{p.body}</p>
                  {p.todo && (
                    <p className="mt-2 text-sm text-zinc-700 leading-relaxed">
                      <strong className="text-zinc-900">Yang wajib dibereskan sekarang, selagi murah:</strong>{' '}
                      {p.todo}
                    </p>
                  )}
                  <p className="mt-3 pt-2.5 border-t border-dashed border-zinc-200 text-[11px] text-zinc-400 tabular-nums">
                    {p.kpi}
                  </p>
                </div>
              </div>
            ))}
          </div>

          <Callout>
            <p>
              <strong className="text-brand">Yang paling sering menghancurkan merek muda:</strong>{' '}
              mengganti-ganti identitas karena bosan. Pemilik melihat logonya setiap hari dan bosan di
              bulan ketiga; pelanggan baru melihatnya empat kali setahun dan baru mulai mengenal di tahun
              kedua. <strong>Kebosanan pemilik bukan alasan yang sah untuk mengubah apa pun di buku ini.</strong>
            </p>
          </Callout>
        </Section>
      </div>

      {/* Tindak lanjut yang langsung bisa dikerjakan */}
      <div className="mt-12 bg-white rounded-2xl border border-brand-border shadow-card p-6">
        <div className="flex items-center gap-2 mb-4">
          <AlertTriangle strokeWidth={2} className="w-4 h-4 text-brand" />
          <h3 className="text-sm font-bold text-zinc-900">Yang harus dikerjakan minggu ini</h3>
        </div>
        <ul className="space-y-2.5">
          {[
            ['Ganti MPASI jadi PAMAN', 'Di menu cetak, papan gerobak, dan halaman Menu Produk.'],
            ['Betulkan keterangan stevia', '"Pemanis dari daun stevia, tanpa gula tambahan." Buang "bebas gula" dan "cocok untuk diet".'],
            ['Pasang tanggal berakhir pada harga coret', 'Satu baris di atas menu: "Harga perkenalan — sampai [tanggal]".'],
            ['Hitung modal bahan per racikan', 'Satu lembar kertas. Ini yang menentukan tangga harga 10K / 13K / 15K.'],
          ].map(([t, d]) => (
            <li key={t} className="flex gap-3">
              <ArrowRight strokeWidth={2.5} className="w-3.5 h-3.5 text-brand shrink-0 mt-1" />
              <div>
                <b className="text-sm font-semibold text-zinc-900">{t}</b>
                <span className="block text-xs text-zinc-500 leading-relaxed">{d}</span>
              </div>
            </li>
          ))}
        </ul>
        <Link
          href="/admin/products"
          className="mt-5 inline-flex items-center gap-2 px-4 py-2 rounded-xl bg-brand text-white text-xs font-semibold hover:bg-brand-dark transition-colors"
        >
          Buka Menu Produk
          <ArrowRight strokeWidth={2.5} className="w-3.5 h-3.5" />
        </Link>
      </div>

      <p className="mt-8 text-[11px] text-zinc-400">
        Brand Handbook · {HANDBOOK_EDITION} · diperbarui {HANDBOOK_UPDATED} · revisi berikutnya di akhir Fase 2
      </p>
    </div>
  )
}
