/**
 * Isi Brand Handbook RAMU.
 *
 * Dipisah dari komponen halaman karena bagian-bagian ini adalah keputusan
 * merek yang akan ditinjau ulang tiap fase — bukan markup. Menaruhnya sebagai
 * data membuat perubahan merek jadi satu baris di berkas ini, bukan berburu
 * teks di tengah JSX.
 *
 * Prosa yang hanya muncul sekali tetap ditulis langsung di halaman; yang
 * dikumpulkan di sini adalah yang berulang, dibandingkan, atau ditagih:
 * palet, kontras, tangga harga, kontrak tagline, dan hukum merek.
 */

export const HANDBOOK_EDITION = 'Edisi 2'

/** Tanggal isi terakhir diubah. Ditampilkan agar tidak ada yang memakai versi basi. */
export const HANDBOOK_UPDATED = '10 September 2026'

export interface Chapter {
  id: string
  num: string
  title: string
}

export const CHAPTERS: Chapter[] = [
  { id: 'inti', num: '01', title: 'Inti' },
  { id: 'posisi', num: '02', title: 'Posisi' },
  { id: 'logo', num: '03', title: 'Logo' },
  { id: 'warna', num: '04', title: 'Warna' },
  { id: 'huruf', num: '05', title: 'Huruf' },
  { id: 'tagline', num: '06', title: 'Tagline' },
  { id: 'suara', num: '07', title: 'Suara' },
  { id: 'menu', num: '08', title: 'Nama Menu' },
  { id: 'harga', num: '09', title: 'Harga' },
  { id: 'gerobak', num: '10', title: 'Gerobak' },
  { id: 'driver', num: '11', title: 'Driver' },
  { id: 'hukum', num: '12', title: 'Hukum' },
  { id: 'peta', num: '13', title: 'Peta 10 Tahun' },
]

// ── 04 · Warna ───────────────────────────────────────────────────────────────

export interface Swatch {
  hex: string
  name: string
  use: string
  /** Warna teks yang terbaca di atas hex ini. */
  on: string
  /** Sebagian warna terang butuh garis supaya kotaknya terlihat di latar putih. */
  needsBorder?: boolean
}

export const PALETTE: Swatch[] = [
  {
    hex: '#BE1A1A',
    name: 'Merah RAMU',
    use: 'Warna merek. Logo, papan, tombol utama, aksen. Target 20–30% permukaan.',
    on: '#FFFFFF',
  },
  {
    hex: '#7E1010',
    name: 'Merah Dalam',
    use: 'Hanya untuk kedalaman: tombol ditekan, garis di dalam bidang merah.',
    on: '#FFFFFF',
  },
  {
    hex: '#1B1210',
    name: 'Hitam Hangat',
    use: 'Semua teks isi. Bukan hitam murni — condong ke merah supaya menyatu.',
    on: '#FFFFFF',
  },
  {
    hex: '#FAF6F3',
    name: 'Krem Kertas',
    use: 'Latar untuk apa pun yang dibaca lama: menu, dokumen, aplikasi.',
    on: '#1B1210',
    needsBorder: true,
  },
  {
    hex: '#FFFFFF',
    name: 'Putih',
    use: 'Cup, kemasan, papan gerobak. Membuat merah paling menyala di bawah matahari.',
    on: '#1B1210',
    needsBorder: true,
  },
  {
    hex: '#7A625C',
    name: 'Cokelat Redup',
    use: 'Teks sekunder dan label. Netral yang dicondongkan ke merah, bukan abu-abu pabrik.',
    on: '#FFFFFF',
  },
]

export interface ContrastPair {
  text: string
  bg: string
  ratio: string
  verdict: string
  /** true = pasangan terlarang, ditandai merah di tabel. */
  forbidden?: boolean
}

export const CONTRAST_PAIRS: ContrastPair[] = [
  { text: '#BE1A1A', bg: '#FFFFFF', ratio: '6,2 : 1', verdict: 'Semua ukuran teks' },
  { text: '#FFFFFF', bg: '#BE1A1A', ratio: '6,2 : 1', verdict: 'Semua ukuran teks' },
  { text: '#BE1A1A', bg: '#FAF6F3', ratio: '5,9 : 1', verdict: 'Semua ukuran teks' },
  { text: '#1B1210', bg: '#FAF6F3', ratio: '17,2 : 1', verdict: 'Teks isi panjang' },
  { text: '#BE1A1A', bg: '#1B1210', ratio: '3,0 : 1', verdict: 'Tidak pernah — gagal terbaca', forbidden: true },
]

// ── 05 · Huruf ───────────────────────────────────────────────────────────────

export interface TypeRole {
  role: string
  font: string
  size: string
  note: string
}

export const TYPE_ROLES: TypeRole[] = [
  { role: 'Papan gerobak — nama', font: 'Baloo 2 800', size: 'sebesar mungkin', note: 'Harus terbaca dari 10 meter' },
  { role: 'Papan gerobak — kategori', font: 'Plus Jakarta 800', size: '1/5 tinggi nama', note: 'Huruf besar, jarak +0,15em' },
  { role: 'Judul dokumen', font: 'Baloo 2 800', size: '28–52 px', note: 'Jarak huruf −0,02em' },
  { role: 'Teks isi', font: 'Plus Jakarta 400', size: '16–17 px', note: 'Tinggi baris 1,7 · lebar maks 65 karakter' },
  { role: 'Label kecil', font: 'Plus Jakarta 800', size: '11–12 px', note: 'Huruf besar, jarak +0,14em' },
  { role: 'Harga & angka', font: 'JetBrains Mono 700', size: 'ikut konteks', note: 'Selalu tabular-nums' },
]

// ── 06 · Tagline ─────────────────────────────────────────────────────────────

export const TAGLINE = 'Jagonya Racikan Buah'

export interface ContractRow {
  promise: string
  expectation: string
  proof: string
}

/**
 * Kontrak yang otomatis terbentuk begitu tagline dipasang. Kalau satu baris
 * tidak terpenuhi, tagline berubah dari aset jadi bahan tertawaan.
 */
export const TAGLINE_CONTRACT: ContractRow[] = [
  { promise: 'Jago', expectation: '"Yang jual pasti ngerti"', proof: 'Driver bisa merekomendasikan tanpa berpikir' },
  { promise: 'Racikan', expectation: '"Ada yang nggak ada di tempat lain"', proof: 'Menu berisi kombinasi, bukan buah tunggal' },
  { promise: 'Racikan', expectation: '"Pilihannya pasti banyak"', proof: 'Minimal 5 racikan sekarang, 8 saat Fase 2' },
  { promise: 'Racikan', expectation: '"Rasanya sudah dipikirkan"', proof: 'Takaran tetap — rasa hari ini = rasa besok' },
  { promise: 'Buah', expectation: '"Ini buah beneran"', proof: 'Buah terlihat, diblender di depan pembeli' },
]

// ── 08 · Nama Menu ───────────────────────────────────────────────────────────

export interface MenuName {
  name: string
  /** Kepanjangan akronim; huruf yang membentuk akronim ditulis kapital. */
  expansion: string
  contents: string
  status: 'aman' | 'pantau' | 'ganti'
  note?: string
}

/**
 * Sistem penamaan RAMU: akronimnya adalah daftar bahannya sendiri. Pembeli
 * tertawa dulu karena katanya familiar, lalu hafal isinya tanpa sadar.
 */
export const MENU_NAMES: MenuName[] = [
  {
    name: 'PASCA',
    expansion: 'PIsang SAlted CAramel',
    contents: 'Pisang + salted caramel',
    status: 'aman',
    note: 'Pintu masuk — selalu direkomendasikan untuk pembeli pertama.',
  },
  {
    name: 'BNN',
    expansion: 'Buah Nanas Nyusu',
    contents: 'Nanas + UHT milk',
    status: 'pantau',
    note: 'Nama lembaga negara aktif. Aman selama RAMU kecil; ditinjau ulang di Fase 3.',
  },
  {
    name: 'KPK',
    expansion: 'Kacang Pisang Kokoa',
    contents: 'Pisang + selai kacang + kokoa',
    status: 'pantau',
    note: 'Sama seperti BNN. Pembelaannya kuat: kepanjangannya benar-benar daftar bahan.',
  },
  {
    name: 'PASUTRI',
    expansion: 'Pisang ASli SUka STRoberI',
    contents: 'Pisang + stroberi',
    status: 'aman',
  },
  {
    name: 'MPASI',
    expansion: 'Mangga Pisang Asli SusU',
    contents: 'Mangga + pisang + UHT milk',
    status: 'ganti',
    note: 'Ganti jadi PAMAN (PIsang MAngga Nyusu). MPASI adalah istilah baku makanan bayi 6–12 bulan, sedangkan racikan ini berisi susu sapi yang tidak dianjurkan untuk bayi di bawah 1 tahun.',
  },
]

// ── 09 · Harga ───────────────────────────────────────────────────────────────

export interface PriceTier {
  price: string
  items: string
  reason: string
}

/** Tangga harga mengikuti biaya bahan, bukan tebakan. */
export const PRICE_TIERS: PriceTier[] = [
  { price: '10K', items: 'PASCA', reason: 'Pintu masuk. Bahan termurah, sengaja dijadikan pembelian pertama.' },
  { price: '13K', items: 'BNN, PAMAN', reason: 'Bahan sedang: nanas, mangga, UHT milk.' },
  { price: '15K', items: 'KPK, PASUTRI', reason: 'Bahan mahal: selai kacang, kokoa murni, stroberi.' },
]

// ── 11 · Driver ──────────────────────────────────────────────────────────────

export interface DriverLine {
  line: string
  why: string
}

/**
 * Tagline "Jagonya" diuji di satu momen: "Mas, yang enak apa?". Kalau
 * jawabannya "terserah", tagline mati di detik itu.
 */
export const DRIVER_LINES: DriverLine[] = [
  {
    line: '"Kalau baru pertama, ambil PASCA dulu. Paling aman, semua suka."',
    why: 'Menghilangkan keraguan pembeli baru.',
  },
  {
    line: '"Kalau mau yang seger banget, BNN."',
    why: 'Untuk pembeli yang kepanasan — kebutuhan paling umum di jalan.',
  },
  {
    line: '"Ini bukan sirup, buahnya diblender langsung. Lihat aja."',
    why: 'Diucapkan sambil meracik. Ini kalimat yang membunuh musuh merek.',
  },
]

// ── 12 · Hukum ───────────────────────────────────────────────────────────────

export interface BrandLaw {
  title: string
  detail: string
}

export const BRAND_LAWS: BrandLaw[] = [
  {
    title: 'Satu nama: RAMU',
    detail: '"RAMUJUS" hanya nama sistem internal. Tidak pernah muncul di cup, struk, seragam, spanduk, atau layar yang dilihat pembeli.',
  },
  {
    title: 'Satu warna merek: #BE1A1A',
    detail: 'Tidak ada warna merek kedua. Warna kedua datang dari buahnya.',
  },
  {
    title: 'Satu tagline: Jagonya Racikan Buah',
    detail: 'Tidak diganti, tidak dipendekkan, tidak dimodifikasi per kampanye.',
  },
  {
    title: 'Tekstur tidak pernah turun',
    detail: 'Kental adalah alasan RAMU boleh menyebut dirinya smoothies. Kalau kental hilang, hapus kata smoothies dari papan pada hari yang sama.',
  },
  {
    title: 'Tidak ada sirup sebagai pengganti buah',
    detail: 'Menghemat di sini menghemat ratusan ribu dan membunuh satu-satunya hal yang membedakan RAMU.',
  },
  {
    title: 'Tidak ada klaim kesehatan',
    detail: 'Tidak menyembuhkan, tidak melangsingkan, tidak mendetoks. Cukup sebutkan isi gelasnya.',
  },
  {
    title: 'Takaran diukur, tidak dikira-kira',
    detail: 'Rasa yang berubah-ubah adalah kebohongan pelan-pelan terhadap kata "jago".',
  },
  {
    title: 'Tidak bersaing dengan menurunkan harga',
    detail: 'Margin Rp5.000 per cup tidak punya ruang untuk perang harga. Bersaing dengan rasa dan racikan.',
  },
  {
    title: 'Setiap harga coret punya tanggal berakhir',
    detail: 'Promo tanpa tanggal bukan promo — itu harga, dan RAMU kehilangan kemampuan naik harga selamanya.',
  },
  {
    title: 'Nama racikan harus mengajarkan resepnya',
    detail: 'Akronim = daftar bahan. Itu sistem RAMU, bukan kebetulan.',
  },
  {
    title: 'Driver selalu bisa merekomendasikan',
    detail: '"Terserah, Mas" adalah pelanggaran merek, bukan sekadar pelayanan yang kurang.',
  },
  {
    title: 'Buah selalu terlihat, blender selalu menghadap pembeli',
    detail: 'Bukti visual adalah keunggulan permanen gerobak atas mal. Jangan pernah menutupinya.',
  },
]

// ── 13 · Peta 10 Tahun ───────────────────────────────────────────────────────

export interface Phase {
  when: string
  title: string
  body: string
  /** Hal konkret yang harus selesai di fase ini; boleh kosong. */
  todo?: string
  kpi: string
}

export const ROADMAP: Phase[] = [
  {
    when: 'Fase 1 · Bulan 1–3',
    title: 'Buktikan satu gerobak',
    body: 'Berhenti mengutak-atik merek. Identitas sudah cukup untuk fase ini. Seluruh tenaga ke jangkauan: rute, jam ramai, dan cicipan gratis untuk memperbanyak orang yang mencoba pertama kali.',
    todo: 'Ganti MPASI jadi PAMAN · betulkan keterangan stevia · pasang tanggal berakhir pada harga coret · hitung modal bahan per racikan.',
    kpi: 'Target 25–30 cup/hari · titik impas 17–20 cup/hari · margin Rp5.000/cup',
  },
  {
    when: 'Fase 2 · Bulan 4–9',
    title: 'Buktikan gerobak bisa digandakan',
    body: 'Gerobak kedua bukan untuk menambah untung — untuk menguji apakah hasil gerobak pertama datang dari sistem atau dari satu orang yang kebetulan rajin. Siapkan modal menutup ±Rp2,5 juta/bulan selama gerobak kedua masih di bawah titik impas.',
    kpi: 'Yang diuji: apakah gerobak 2 mencapai 20 cup/hari tanpa pemilik ikut turun',
  },
  {
    when: 'Fase 3 · Tahun 1–2',
    title: 'Rapikan menu sebelum terlalu besar',
    body: 'Tambah racikan tanpa pisang sampai menu mencapai 8. Tinjau ulang BNN dan KPK: selama RAMU kecil keduanya aman, tapi keputusan mempertahankan atau mengganti harus diambil sadar di sini — mengganti nama saat punya 3 gerobak nyaris tanpa biaya; saat punya 30 gerobak, biayanya seluruh cetakan dan seluruh ingatan pelanggan.',
    kpi: 'Siap lanjut saat ada 1 racikan yang pelanggan sebut namanya tanpa melihat menu',
  },
  {
    when: 'Fase 4 · Tahun 2–4',
    title: 'Toko pertama',
    body: 'Toko bukan untuk jualan lebih banyak — untuk memberi RAMU alamat tetap yang bisa dicari orang. Papan toko memakai susunan di Bab 10, dengan "SMOOTHIES & JUS" tetap terpasang.',
    kpi: 'Syarat: armada gerobak sudah untung tanpa disubsidi toko',
  },
  {
    when: 'Fase 5 · Tahun 4–10',
    title: 'Masuk kategori wellness drink',
    body: 'Baru di sini RAMU boleh menyebut dirinya merek wellness — dengan definisi merah dari Bab 02: tenaga dan segar, bukan detoks. Kemasan botol, kanal ritel, dan waralaba semuanya bergantung pada satu hal yang dibangun sejak Fase 1: rasa yang tidak pernah berubah.',
    kpi: 'Fondasinya: takaran terukur sejak hari pertama — tanpa itu, tidak ada yang bisa diskalakan',
  },
]
