# Uji migrasi database

Menjalankan `schema.sql` + seluruh migrasi di Postgres lokal, lalu memeriksa
aturan keamanan, alur pembuatan pesanan, pelacakan armada, penguncian audit
kas, dan perilaku pada skala 100 gerobak. Tidak menyentuh proyek Supabase milik siapa pun.

## Menjalankan

Butuh Postgres 14+ yang sedang berjalan, `psql`, dan hak membuat basis data.
Setiap berkas uji menyemai datanya sendiri dan berasumsi tabelnya kosong,
jadi masing-masing memerlukan basis data yang baru.

```bash
supabase/tests/run.sh          # seluruh berkas uji, satu basis data baru per berkas
supabase/tests/run.sh 06 09    # hanya nomor yang disebut
```

Koneksi diambil dari variabel lingkungan psql yang biasa (`PGHOST`, `PGPORT`,
`PGUSER`, `PGPASSWORD`). Skrip yang sama dijalankan CI pada setiap pull
request, jadi kegagalan di CI dapat direproduksi persis di mesin sendiri.

Skrip itu memasang, berurutan: `00_supabase_stub.sql`, `schema.sql`, lalu
seluruh berkas di `supabase/migrations/` menurut nomornya. `00_supabase_stub.sql`
menyediakan tiruan minimal dari hal-hal yang disediakan Supabase (`auth.users`,
`auth.uid()`, role `authenticated`, publikasi realtime), supaya skema yang sama
bisa dijalankan di Postgres polos. `auth.uid()` versi tiruan membaca GUC sesi
`test.uid`, sehingga tes dapat berpura-pura menjadi driver atau admin tertentu.

Setiap tes berhenti dengan error bila perilakunya salah; skrip keluar dengan
kode bukan-nol bila ada satu saja yang gagal.

## 01 — Keamanan & pesanan

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Pendaftaran mandiri tidak bisa menentukan peran sendiri — `role` selalu `driver` walau metadata meminta `admin` |
| 2 | Driver tidak bisa menaikkan dirinya jadi admin (`FORBIDDEN_ROLE_CHANGE`) |
| 3 | Driver tetap boleh mengubah datanya sendiri yang wajar (nama) |
| 4 | Driver tidak bisa mengubah angka muatan gerobaknya sendiri |
| 5 | `create_order` menolak shift yang tidak aktif |
| 6 | Satu driver tidak bisa punya dua shift aktif |
| 7 | Pesanan normal: total dihitung server dari tabel `products`, item tersimpan, stok berkurang, lokasi tercatat |
| 8 | Stok tidak cukup ditolak **dan** tidak meninggalkan pesanan separuh (rollback) |
| 9 | Driver tidak bisa memakai shift milik driver lain |

## 02 — Pelacakan armada

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Posisi ditolak bila driver tidak sedang shift |
| 2 | Koordinat di luar rentang bumi ditolak |
| 3 | Kiriman pertama membuat baris posisi dan satu baris histori |
| 4 | 21 kiriman beruntun tetap menghasilkan 1 baris posisi dan 1 baris histori — pembatasan histori bekerja |
| 5 | Histori bertambah setelah ambang interval terlewati |
| 6 | Driver tidak bisa memalsukan posisi lewat tabel langsung (tidak ada policy UPDATE) |
| 7 | Driver hanya melihat posisinya sendiri |
| 8 | `fleet_overview` kosong untuk non-admin |
| 9 | Admin melihat seluruh armada dalam satu query |
| 10 | `admin_driver_stats` menggantikan pola 1 + 2N query |
| 11 | `prune_location_logs` menghapus histori lama |
| 12 | Kueri posisi memakai index scan, bukan pemindaian penuh |

## 03 — Skala 100 gerobak

Menyemai armada nyata lalu mengukur kueri yang dipakai halaman admin:
100 driver, 45.000 pesanan, 90.000 item pesanan, 42.000 baris histori GPS.

Memastikan `fleet_overview`, `admin_driver_stats`, `admin_sales_daily` dan
`admin_top_products` masing-masing tetap satu kali jalan, dan bahwa peta
sebaran transaksi serta riwayat GPS per driver memakai indeks, bukan
pemindaian tabel penuh.

## 04 — Pesanan offline & penguncian kas

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Enam percobaan kirim dengan kunci idempotensi sama menghasilkan **satu** pesanan, stok terpotong sekali |
| 2 | Kunci berbeda tetap membuat pesanan baru |
| 3 | Waktu transaksi asli dipertahankan untuk pesanan dari antrean |
| 4a | Waktu di masa depan dikoreksi ke sekarang (anti sisip maju) |
| 4b | Waktu yang lebih tua dari dua hari **ditolak** (`ORDER_TOO_OLD`), tidak digeser ke hari pengiriman |
| 5 | Driver tidak boleh mengunci rekonsiliasi (`ADMIN_ONLY`) |
| 6 | Admin dapat mengunci, penanggung jawab tercatat |
| 7 | Angka kas tidak dapat diubah setelah dikunci (`RECONCILIATION_LOCKED`) |
| 8 | Angka stok juga terkunci |
| 9 | Admin dapat membuka kunci, dan pembukaannya tercatat di jejak audit |
| 10 | Setelah dibuka, angka bisa dikoreksi lagi |
| 11 | `admin_daily_summary` menjawab dalam satu query |
| 12 | Driver tidak mendapat ringkasan admin |

## 05 — Profil pembeli

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Profil pembeli tersimpan bersama pesanan |
| 2 | Profil boleh dikosongkan seluruhnya |
| 3 | Nilai profil ngawur diabaikan, **penjualan tetap tersimpan** |
| — | Seluruh berkas ini memakai argumen bernama sejak 0024. Sebelumnya posisional, dan ketika `create_order` bertambah satu parameter, nilai `'sebut'` diam-diam mendarat di parameter yang salah — tesnya tetap "lulus" karena hanya mencetak hasil, tidak memeriksanya |
| 4 | Constraint database menolak nilai di luar daftar |
| 5 | Laporan sebaran, jam ramai per usia, dan produk favorit per segmen |
| 6 | Transaksi tanpa profil terlihat jelas sebagai `unknown`, bukan disembunyikan |
| 7 | Driver tidak dapat membaca laporan pembeli |

## 06 — Metrik cup vs transaksi

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | 3 transaksi berisi 9 cup + 2 topping → `admin_daily_summary` melaporkan 3 transaksi & **9 cup** (topping tidak dihitung) |
| 2 | `admin_sales_daily` mengembalikan cup per hari yang benar |
| 3 | `fleet_overview` mengembalikan `cups_today` per gerobak |
| 4 | `admin_report_summary` menghitung cup, omzet, dan rincian pembayaran atas seluruh rentang |
| 5 | `order_cup_count` menghitung cup satu pesanan multi-item |
| 6 | Driver tidak dapat membaca ringkasan maupun laporan (nol baris) |

## 07 — Inventori stok produk

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Restock menaikkan stok dan mencatat pergerakan |
| 2 | Muat gerobak mengurangi stok pusat |
| 3 | Menyimpan alokasi yang sama lagi tidak menggeser stok (idempoten) |
| 4 | Menaikkan muatan mengurangi stok sebesar selisihnya saja |
| 5 | Menurunkan muatan mengembalikan stok, tercatat sebagai `allocation_return` |
| 6 | Muat melebihi stok pusat ditolak (`INSUFFICIENT_STOCK`) |
| 7 | Stock opname menyetel angka absolut dan mencatat selisih |
| 8 | Ikhtisar stok memberi status `out`/`low`/`ok` yang benar |
| 9 | Hitungan menipis/habis untuk lencana dashboard |
| 10 | Driver ditolak restock, muat gerobak, ikhtisar, dan riwayat pergerakan |

## 08 — Analitik per hari/tanggal

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | `admin_daily_summary` melaporkan cup **dan** item hari ini sebagai dua angka berbeda |
| 2 | `admin_sales_range` memberi satu baris per tanggal kalender WIB; hari tanpa transaksi tetap muncul sebagai baris nol |
| 3 | Transaksi 23:30 dan 00:30 WIB jatuh pada tanggal WIB yang benar, bukan tanggal UTC |
| 4 | Rentang dengan dari/sampai tertukar dirapikan, bukan mengembalikan kosong |
| 5 | `admin_sales_hourly` selalu 24 baris dan menaruh transaksi pada jam WIB yang benar |
| 6 | `admin_top_products_range` mengikuti rentang tanggal terpilih dan membawa kategori produk |
| 7 | `admin_sales_daily(N)` kini berarti N tanggal kalender WIB, bukan jendela N×24 jam |
| 8 | `admin_report_summary` menghitung cup, item, omzet, dan rincian pembayaran atas seluruh rentang |
| 9 | Produk yang salah kategori terbaca sebagai selisih cup vs item, bukan sebagai data yang hilang |
| 10 | Driver tidak mendapat satu pun baris dari fungsi analitik admin |

## 09 — Status akun berlaku

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Akun aktif membuka shift dan menjual seperti biasa (garis dasar) |
| 2 | Admin dapat menonaktifkan driver; `get_user_status` membacanya |
| 3 | Driver nonaktif **tidak** dapat membuka shift baru — ditolak policy RLS |
| 4 | Driver nonaktif tetap dapat menutup shift lamanya, jadi tidak ada shift menggantung |
| 5 | Shift yang telanjur aktif tidak menolong: `create_order` menolak dengan `ACCOUNT_INACTIVE`, tanpa pesanan separuh dan tanpa stok terpotong |
| 6 | Driver tidak dapat mengaktifkan dirinya sendiri kembali (`FORBIDDEN_STATUS_CHANGE`) |
| 7 | Setelah diaktifkan admin, penjualan tercatat lagi dan stok terpotong benar |
| 8 | Aturan ini tidak ikut mengunci akun admin |

## 10 — Satu definisi cup untuk driver dan admin

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Menjual **tanpa** muatan gerobak yang dicatat admin: `driver_daily_summary` tetap melaporkan cup yang benar — keadaan yang dulu membuat driver melihat 0 |
| 2 | Jumlah cup seluruh driver sama persis dengan cup di `admin_daily_summary` |
| 3 | Driver hanya melihat angkanya sendiri, bukan angka armada |
| 4 | Driver tanpa penjualan mendapat satu baris berisi nol, bukan tabel kosong |
| 5 | `admin_driver_stats_range` memberi cup, item, omzet, dan hari aktif per mitra |
| 6 | Mitra tanpa penjualan tetap muncul sebagai baris nol |
| 7 | Rentang tanggal benar-benar mempersempit, dan dari/sampai tertukar dirapikan |
| 8 | Total per mitra sama dengan total per tanggal di `admin_sales_range` |
| 9 | Driver tidak dapat membaca statistik mitra lain (nol baris) |

## 11 — Predikat tanggal ber-indeks & retensi

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | `wib_day_start` memberi tepat 24 jam per hari WIB, batas atas eksklusif |
| 2 | Rentang 7 hari atas 5.000 pesanan dijawab lewat indeks — rencana kueri diperiksa, bukan diasumsikan |
| 3 | Bentuk predikat lama memang `Seq Scan` pada data yang sama, jadi perbedaannya nyata |
| 4 | Angkanya tidak bergeser: fungsi cocok dengan hitungan langsung |
| 5 | Transaksi 23:59:30 dan 00:00:30 WIB tetap jatuh di harinya masing-masing |
| 6 | `prune_location_logs_job` menghapus histori tua dan menyisakan yang masih berlaku |
| 7 | Migrasi retensi tidak gagal walau pg_cron tidak tersedia |
| 8 | Driver tidak dapat memangkas histori GPS armada |

## 12 — Sisa cup kembali ke stok pusat

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Muat gerobak tetap mengurangi stok pusat seperti sebelumnya |
| 2 | Mengunci audit **tanpa mengisi apa pun** mengembalikan seluruh sisa fisik ke stok, tercatat sebagai `allocation_return` |
| 3 | Cup rusak (`waste_quantity`) tidak ikut kembali |
| 4 | Membuka kunci membalik pengembalian dan mencatat pembatalannya |
| 5 | Buka lalu kunci ulang menghitung **sekali**, bukan dua kali |
| 6 | Penguncian kedua ditolak dan tidak menyentuh stok |
| 7 | Menurunkan angka pengembalian melebihi sisa fisik ditolak (`RETURN_EXCEEDS_REMAINING`); stok tidak bergerak dan alokasi tidak terkunci |
| 8 | Membuka kunci ditolak bila cup-nya sudah dimuat ke gerobak lain (`UNLOCK_STOCK_UNAVAILABLE`); kunci tetap utuh, stok tidak dipaksa negatif |
| 9 | Tanpa sisa fisik, tidak ada pergerakan stok kosong yang tercatat |
| 10 | Driver tidak dapat mengunci maupun mengubah angka pengembalian |
| 11 | `admin_pending_returns` menampilkan cup yang belum masuk hitungan stok; tertutup untuk driver |

## 13 — Angka audit tidak bisa berbohong

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Angka mustahil (terjual + sisa + rusak melebihi yang dibawa) **ditolak**, dan alokasinya tidak ikut terkunci |
| 2 | Setelah angkanya dibetulkan, penguncian berjalan dan sisa cup kembali ke stok |
| 3 | Penjualan setelah hari itu dikunci ditolak (`DAY_RECONCILED`); tidak ada pesanan siluman dan stok tidak bergerak |
| 4 | Setelah kunci dibuka, penjualan diterima lagi dan memotong muatan seperti biasa |
| 5 | Penguncian menyegarkan angka terjual dari transaksi — yang dibekukan kebenaran saat penguncian, bukan angka layar yang basi |
| 6 | Selisih ke arah kehilangan tetap boleh dikunci; itu kejadian nyata yang perlu tercatat |
| 7 | Penguncian yang ditolak tidak menyisakan perubahan apa pun |

## 14 — Analitik menu

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Menu yang **tidak laku sama sekali** tetap muncul, lengkap dengan berapa yang dibawa |
| 2 | "Tidak laku" dapat dibedakan dari "tidak pernah dibawa" — dua angka terpisah |
| 3 | Kontribusi omzet per menu dalam persen, dan seluruhnya berjumlah 100 |
| 4 | Pembanding periode sebelumnya sama panjang dan tidak tumpang tindih dengan rentang terpilih |
| 5 | Menu yang baru laku terbaca nol di periode lalu, bukan disembunyikan |
| 6 | `days_sold` menghitung hari kalender, bukan jumlah transaksi |
| 7 | Seluruh produk ikut terdaftar, termasuk yang tidak pernah tersentuh |
| 8 | Driver tidak dapat membaca analitik menu |

## 15 — Analitik operasional (jam & lokasi)

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Jam yang totalnya dua kali lebih besar **bukan** jam yang lebih ramai bila hari aktifnya juga dua kali lebih banyak — setelah dinormalkan keduanya identik |
| 2 | Pembagi (`days_active`) ikut dikembalikan, sehingga angka bagus dari satu hari tidak bisa menyamar sebagai pola |
| 3 | Koordinat berjarak ~55 m menyatu jadi satu titik mangkal; yang berjarak ~3 km terpisah |
| 3b | Titik yang dilaporkan adalah **rata-rata koordinat asli**, bukan pusat petak — bug 0018, yang pada produksi meleset sampai 139 m dari tempat gerobak benar-benar berjualan |
| 3c | `spread_meters` bernilai 0 untuk kelompok yang memang satu titik, sehingga titik mangkal bisa dibedakan dari ruas yang dilewati |
| 4 | Petak di bawah 50 m dijepit — hasil petak 5 m dan 0 m identik dengan petak 50 m, baris demi baris |
| 5 | Dua gerobak dengan cup per **hari** yang sama terbaca sangat berbeda pada cup per **jam** — inilah yang memisahkan lokasi bagus dari jam kerja panjang |
| 6 | Jam kerja dijumlahkan per gerobak, bukan jam dinding: dua gerobak yang jalan bersamaan 5 dan 2 jam menghasilkan 7 jam-gerobak |
| 7 | Hari dengan satu pesanan (rentang nol) dijepit ke 1 jam, bukan pembagian dengan nol |
| 8 | Matriks hari × jam memisahkan hari yang berbeda, tidak menumpuknya jadi satu angka |
| 9 | Kelima fungsi tertutup untuk non-admin |

## 16 — Fungsi admin tertutup untuk anon

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Nol fungsi `admin_*` dan `fleet_overview` yang bisa dipanggil peran `anon` |
| 2 | Pencabutan tidak kebablasan — seluruh fungsi itu tetap bisa dipanggil `authenticated`, sehingga dashboard tidak ikut mati |
| 3 | `driver_daily_summary` tidak ikut tercabut; pola nama di 0017 sengaja tidak menyentuh fungsi driver |
| 4 | Kelima fungsi baru dari 0016 ikut tertutup, bukan terlewat |
| 5 | Lapis kedua tetap ada: driver yang **sudah login** pun ditolak gerbang peran di dalam fungsi, bukan hanya oleh izin |

### Tambahan 0019 — cup per jam per lokasi

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 4b | Laju dihitung dari cup **terukur** dibagi jam **terukur** — bukan cup total dibagi jam terukur, yang akan membuat titik dengan banyak kunjungan satu-pesanan terlihat jauh lebih ramai dari kenyataannya |
| 4c | Titik yang hanya pernah menghasilkan satu pesanan mengembalikan **NULL**, bukan nol dan bukan tebakan. Cup-nya tetap dilaporkan penuh; yang tidak diketahui hanya lajunya |
| 4d | Dua pesanan berjarak detik tidak meledakkan laju. Pada data produksi kasus ini menghasilkan 959 cup/jam dan akan menarik keputusan sewa ke tempat yang salah — sekarang kunjungan wajib terentang minimal 15 menit untuk ikut dihitung, dan tidak ada laju yang boleh melampaui batas fisik penyajian |

## 17 — Lama mangkal direkam (0020, 0021, 0022)

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Mulai mangkal membuka satu catatan dan menautkannya ke shift yang aktif |
| 2 | Mangkal baru menutup yang lama otomatis — driver yang lupa menekan "pindah" tetap menghasilkan data benar |
| 3 | Ketukan yang dikirim ulang (sinyal putus) tidak menggandakan catatan; kunci idempotensi menahannya |
| 4 | Menekan "pindah" dua kali aman, tidak melempar galat |
| 5 | Klien tidak bisa menulis langsung ke tabel — aturan "satu mangkal terbuka" tidak bisa dilewati dari aplikasi |
| 6 | **Inti:** mangkal 10:00–11:00 dengan tiga pesanan dicatat beruntun pukul 11:00:00/11/22 menghasilkan **3,0 cup/jam**, bukan ~491 dari rentang 22 detik. Pesanan yang mendarat sesudah mangkal ditutup tetap terhitung lewat kelonggaran catat-belakangan |
| 6b | Kelonggaran itu **30 menit**, bukan 15 (0021). Mangkal 16:00–21:00: pesanan yang tercatat 21:17 ikut terhitung, yang 21:45 tidak. Dengan jendela 15 menit lama, kasus ini kehilangan 3 dari 5 cup — persis kejadian produksi 12 Sep 2026 |
| 7 | Tanpa catatan mangkal, perkiraan dari rentang pesanan tetap jalan dan ditandai `perkiraan` — tidak pernah menyamar sebagai `tercatat` |
| 8 | Driver tidak bisa membaca mangkal driver lain |
| 9 | Sapuan 0022 hanya menyentuh yang **lupa** ditutup, dan menutupnya di jam pulang rutin 21:30 — bukan tengah malam, bukan penjualan terakhir. Baris yang sudah ditutup driver tidak tersentuh sama sekali |
| 10 | Mangkal yang ditutup sapuan memakai jam kerja penuh (10:00–21:30 = 11,5 jam → 0,35 cup/jam). Menjaga dua cara gagal: batas 6 jam lama (0,67, melambung 91%) dan penutupan di penjualan terakhir (4,0, melambung 11 kali) |
| 11 | Mangkal yang masih berjalan hari ini tidak ikut tersapu — driver yang masih kerja tidak terpotong |

## 18 — Booth event keluar dari analitik lokasi (0023)

Booth event — kampus, bazar, pasar malam — adalah audiens tertawan yang tidak
berulang. Angkanya nyata, tapi tempatnya tidak bisa disewa. Kalau ikut masuk
analitik lokasi, ia tampil sebagai titik terbaik yang pernah terukur dan
menarik keputusan sewa ke tempat yang tidak ada.

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Mangkal bertanda `is_event` hilang sepenuhnya dari `admin_location_clusters` — 60 cup / 4 jam di kampus tidak muncul, yang tersisa hanya titik jalanan 4 cup / 4 jam = 1,0 cup/jam |
| 2 | **Uangnya tidak hilang:** 64 cup dan Rp832.000 tetap utuh di omset. Yang dibuang hanya anggapan bahwa tempat itu bisa disewa |
| 3 | **Tes yang membuktikan tes 1 punya gigi:** penandanya dilepas sebentar, dan kampus langsung merebut peta dengan 15,0 cup/jam — 3,4 kali ambang sewa ruko 4,4 |
| 4 | Penanda hanya bisa dipasang admin; driver ditolak |

Dua lubang ditutup sekaligus, karena menandai mangkalnya saja tidak cukup:
pesanan di booth tetap membentuk petaknya sendiri lewat jalur perkiraan.
Penyaringnya ada di dua tempat — mangkal event tidak jadi jam terukur, dan
pesanan di dalam jendela mangkal event tidak masuk petak sama sekali.

## 19 — "Sebut menu tanpa lihat" (0024)

`customer_type` menanyakan hal yang salah: "orang ini pernah beli?" adalah soal
**ingatan**, dan driver tidak hafal wajah. Hasilnya 55 dari 64 transaksi tercatat
`new` dan hanya 2 `returning` — angka itu mengukur daya ingat driver, bukan
tingkat beli-ulang RAMU. Angka "17% jadi langganan" sempat dikutip berkali-kali
dalam analisis sebelum ketahuan tidak pernah ada di basis data.

Penggantinya menanyakan apa yang terjadi di depan mata sekarang, dan itu selalu
bisa dijawab jujur: pembeli menyebut nama menu, atau membaca daftar dulu.

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | `sebut` dan `lihat` tersimpan apa adanya |
| 2 | Nilai di luar daftar dibuang, **penjualannya tetap tersimpan** — satu ketukan salah tidak boleh menghilangkan uang yang nyata |
| 3 | Constraint database ikut menolak, bukan hanya fungsinya |
| 4 | Pesanan tanpa `cara_pesan` tetap diterima — kolom pengamatan tidak pernah jadi syarat jualan |
| 4b | **Aplikasi versi lama yang masih mengirim `p_customer_type` tetap bisa mencatat penjualan.** PWA tersimpan di ponsel driver; kalau tanda tangan fungsinya tidak cocok, PostgREST menolak SETIAP penjualan sampai ponselnya memuat ulang |
| 4c | Kolom `customer_type` benar-benar hilang, bukan sekadar disembunyikan dari layar |
| 5 | Hanya ada **satu** `create_order` — menambah parameter lewat `CREATE OR REPLACE` diam-diam membuat fungsi kedua, dan PostgREST tidak bisa memilih di antara dua yang bernama sama |
| 6 | Laporan membuka penyebutnya: 1 sebut dari 2 yang tercatat = **50%**, bukan 20% dari 5 total. Yang belum dicatat tidak ikut jadi penyebut, supaya angkanya tidak turun hanya karena driver sedang ramai |
| 7 | Driver tidak mendapat satu pun baris laporan admin |

Tes 05 ikut diubah ke argumen bernama. Sebelumnya posisional, dan ketika
`create_order` bertambah satu parameter, nilai `'sebut'` diam-diam mendarat di
parameter yang salah — tesnya tetap "lulus" karena hanya mencetak hasilnya,
tidak memeriksanya. Sekarang diperiksa.

## 20 — Perbaiki pesanan yang salah ketik (0025, 0026)

Sampai 0025 pesanan yang sudah tersimpan tidak bisa diubah sama sekali, jadi
salah ketik menetap selamanya dan angka keputusan ikut salah. Minggu 13 Sep
2026 menunjukkan kenapa itu mendesak: 33 cup tercatat dalam rentang satu menit
saat event kampus, keadaan di mana salah ketik bukan kemungkinan melainkan
kepastian.

Yang dibuka adalah kemampuan **memperbaiki**, bukan kemampuan menghapus jejak.

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Salah ketik 9 dibetulkan jadi 4, dan **lima cup kembali ke alokasi** — bukan hilang jadi selisih setoran |
| 2 | Menukar menu, bukan hanya jumlah: stok kedua produk ikut benar |
| 3 | Edit melebihi muatan ditolak **dan pesanan lamanya utuh** — total, item, dan stok persis seperti sebelum percobaan. Tanpa ini, edit gagal meninggalkan pesanan kosong dengan stok sudah dikembalikan |
| 4 | Batal menghapus pesanan dan mengembalikan cup-nya ke muatan |
| 5 | Jejak edit dan batal tersimpan, dan **potret sebelumnya tetap ada setelah pesanannya dihapus** |
| 6 | Driver tidak bisa mengubah atau membatalkan pesanan driver lain |
| 7 | Pesanan hari kemarin **tetap bisa diperbaiki** selama harinya belum direkonsiliasi (0026), dan perbaikannya tetap berjejak. 0025 menolaknya dengan penjaga yang keliru: yang menandai "angka sudah dipakai" adalah rekonsiliasi, bukan pergantian tanggal — dan batas tanggal justru membuat salah ketik yang baru ketahuan besok mustahil diperbaiki |
| 8 | Setelah hari itu direkonsiliasi, edit dan batal dua-duanya terkunci. Sejak 0026 mencabut batas tanggal, **inilah satu-satunya penjaga waktu yang tersisa** |
| 9 | **Jejak tidak bisa dihapus dari aplikasi.** Tanpa ini, selisih kas apa pun bisa dirapikan belakangan dengan menurunkan satu angka penjualan lalu menghapus catatannya |

Pembatalan menghapus barisnya, bukan menandainya. Menandai berarti dua puluh
lebih fungsi analitik harus ingat menyaring baris itu; satu yang lupa
menghasilkan angka yang berbeda diam-diam dari angka di sebelahnya. Jejaknya
disimpan penuh di `order_audit_log`, jadi yang hilang hanya barisnya, bukan
kejadiannya.

## 21 — Penandaan event dipasang driver di lapangan (0027)

0023 membuat booth event bisa dikeluarkan dari analitik lokasi, dan penyaringnya
bekerja. Tapi penandanya hanya bisa dipasang admin, **sesudah kejadian, dan hanya
bila ada yang ingat memberitahu**. Kalau tidak ada yang cerita, booth event
menyelinap ke peta sebagai titik terbaik yang pernah terukur — tanpa satu pun
tanda bahwa ada yang keliru.

Kesalahan yang diam adalah yang paling mahal di sini, karena yang dibelokkan
adalah keputusan sewa. Yang tahu sebuah tempat itu booth event atau titik biasa
adalah orang yang berdiri di sana, jadi penandaannya dipindahkan ke sana.

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Mangkal biasa tetap bukan event |
| 2 | Booth event ditandai sejak ketukan pertama — bukan koreksi belakangan |
| 3 | Salah tekan bisa dibalik **tanpa menutup mangkalnya**. Menutup lalu membuka ulang akan memotong lama mangkal, dan lama mangkal itulah penyebut cup per jam |
| 4 | `driver_current_stop` melaporkan penandanya, sehingga salah tekan terlihat oleh drivernya sendiri |
| 5 | Aplikasi versi lama (4 argumen, tersimpan di ponsel sebagai PWA) tetap bisa membuka mangkal, dan hasilnya bukan event |
| 6 | Hanya ada **satu** `driver_start_stop` — menambah parameter lewat `CREATE OR REPLACE` diam-diam membuat fungsi kedua |
| 7 | 40 cup booth event benar-benar hilang dari peta; yang tersisa hanya 2 cup jalanan |
| 8 | **Admin bisa melihat apa yang dikeluarkan, bukan mempercayainya.** `admin_mangkal_event` melaporkan persis 40 cup / Rp520.000 yang keluar dari peta, beserta jam dan titiknya |
| 9 | Driver tidak bisa membaca daftar itu |

Tes 8 yang paling penting dari sudut pandang kepercayaan: penyaring yang bekerja
diam-diam tidak bisa dipercaya, karena tidak ada yang tahu kalau ia salah.

## 22 — Setiap hari jualan punya awal dan akhir (0028)

Dari data produksi 7–14 September 2026: **Rp677.000 dari Rp1.644.000 — 41% —
tidak pernah diakui masuk.** Empat dari delapan hari. Dua di antaranya (10 dan
11 September) tidak punya baris alokasi sama sekali, padahal 22 cup terjual.

Semuanya satu sebab. `create_order` menulis pesanan, lalu melewati seluruh
pemotongan stok dalam diam ketika alokasinya tidak ada:

```
IF v_alloc_id IS NOT NULL THEN        -- tidak ada alokasi     -> lewat
  SELECT ... INTO v_remaining ...
  IF FOUND THEN                       -- produk tak di alokasi -> lewat
```

Pesanannya tersimpan lengkap. Yang hilang pembandingnya: berapa yang dibawa
pagi itu. Tanpa pembanding, selisih setoran mustahil dihitung — bukan karena
selisihnya nol, melainkan karena pertanyaannya tidak pernah bisa diajukan.

**Jalan yang kelihatannya benar — menolak penjualan pada hari yang belum
dialokasikan — justru memperburuk.** Driver bukan pihak yang lalai, dan
menolak pesanannya tidak membatalkan penjualan: pembeli sudah berdiri di depan
gerobak dan tetap dilayani. Yang batal hanya pencatatannya. Aturan itu akan
mengubah 22 cup yang tercatat-tapi-tak-berpasangan menjadi 22 cup yang tidak
ada sama sekali.

Karena itu aturannya dibalik: penjualan **tidak pernah** ditolak, dan sebagai
gantinya tidak ada lagi jalan keluar yang sunyi. Hari selalu punya baris,
produk selalu punya baris, dan yang tidak tercatat muncul sebagai muatan 0
dengan terjual 6 — angka janggal yang menuntut jawaban, bukan celah yang tak
meninggalkan bekas.

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Hari tanpa alokasi: penjualan **tetap masuk**, barisnya dibuat, ditandai `dibuat_otomatis`, muatan tetap 0 (tidak dikarang) |
| 2 | Produk di luar alokasi dapat barisnya sendiri — lubang `IF FOUND` tertutup |
| 3 | Admin mencatat muatan di tengah hari **tanpa menimpa** cup yang sudah telanjur terjual (kejadian 12 September: alokasi 13:05 menyusul penjualan 12:17), dan cup ke-7 dari muatan 5 dicatat, bukan ditolak |
| 4 | Hari yang muatannya tak pernah dicatat **tidak bisa dikunci**, dan sebabnya menyebut jalan keluarnya (`MUATAN_BELUM_DICATAT`), bukan `AUDIT_NUMBERS_IMPOSSIBLE` yang benar tapi buntu |
| 5 | `admin_akui_muatan_dari_penjualan` menaikkan muatan ke angka terjual, **memotong stok pusat** sebesar selisihnya, meninggalkan jejak, dan sesudahnya hari bisa dikunci |
| 6 | `DAY_RECONCILED` masih menjaga hari yang angkanya sudah final |
| 7 | `admin_hari_perlu_perhatian` menagih hari lalu yang menggantung, dan **tidak** menagih hari yang sedang berjalan — daftar yang berisik tiap hari akan berhenti dibaca |
| 8 | Dua fungsi baru ditolak dengan sebab untuk selain admin, bukan dijawab daftar kosong |

Tes 8 menutup pola yang berulang di proyek ini: daftar kosong dari pertanyaan
yang tidak pernah diizinkan terbaca sebagai "tidak ada hari yang menggantung" —
kebohongan yang persis sama bentuknya dengan dashboard yang dulu menampilkan
"0 cup" padahal driver sudah jualan.

**Dua tes lama ikut berubah, dan perubahannya disengaja.** `01` tes 8 dulu
menuntut penolakan saat stok tidak cukup; sekarang ia menuntut pencatatan
beserta selisih yang kelihatan — jaminan keduanya (pesanan gagal tidak
meninggalkan separuh dirinya) tetap diuji lewat item kedua yang tidak sah.
`10` dulu berprasyarat "nol baris alokasi"; prasyaratnya kini berbentuk lain
dengan isi yang sama: barisnya lahir dari penjualan, dan tidak satu cup pun
muatan pernah tercatat.

## 23 — Belanja bahan masuk stok, harganya punya riwayat (0029)

Margin RAMU selama ini satu angka yang diketik tangan: `MARGIN_PER_CUP = 5000`.
Dari angka itu turun titik impas 20 cup/hari, ambang gerobak 2,0 cup/jam, dan
ambang ruko 4,4 cup/jam — tiga angka yang dipakai memutuskan apakah sebuah
titik layak disewa. Dua di antaranya bahkan memakai asumsi margin yang
**berbeda** (Rp5.000 dan Rp6.500) untuk menilai titik yang sama di peta yang
sama.

**Satuannya berat daging, bukan berat beli.** Rancangan pertama menyimpan harga
per gram buah utuh lalu membaginya dengan rendemen (pisang ±65%, nanas ±50%).
Itu dibatalkan: rendemen adalah tebakan yang dipasang sekali lalu dipakai
berbulan-bulan, padahal ia bergerak mengikuti ukuran buah, musim, dan supplier.

Yang dipakai sekarang: buah dikupas, dagingnya ditimbang, dan angka itu yang
masuk. **Rendemen tidak pernah ada sebagai kolom** — ia terukur sendiri pada
setiap belanja. Penimbangan itu juga bukan kerja tambahan: freezer berisi
daging, jadi hitung stok nanti menimbang daging juga.

`jumlah_beli` tetap dicatat (boleh kosong) dan tidak pernah dipakai menghitung
biaya. Gunanya satu: memisahkan dua sebab kenaikan yang obatnya berbeda —
harga pasar naik, atau buahnya makin jelek.

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Rp20.000 untuk 1 kg yang menghasilkan 650 g daging tercatat **Rp30,77/gram**, bukan Rp20 — dan rendemen 0,65 terukur sendiri, tidak dimasukkan siapa pun |
| 2 | Belanja kedua menggeser rata-rata secara **tertimbang** (Rp33,86), bukan rata-rata polos dari dua harga (Rp33,13) — belanja 1 kg dan 10 kg tidak boleh berbobot sama |
| 3 | Rupiah per kilo **persis sama**, daging turun 650 → 520 g: biaya naik Rp30,77 → Rp38,46. Sebabnya buah, bukan harga — dan keduanya terbaca terpisah |
| 4 | Koreksi menambah baris, tidak mengubah baris lama; angkanya kembali benar |
| 5 | `UPDATE` dan `DELETE` pada `belanja` ditahan RLS. Riwayat yang bisa berubah surut tidak bisa dipakai memutuskan apa pun |
| 6 | Tiga angka mustahil ditolak dengan sebabnya: daging lebih berat dari buah utuh, nota bertanggal besok, baris yang tidak mengubah apa pun |
| 7 | Biaya bahan per cup = belanja ÷ cup, apa adanya, koreksi ikut terhitung |
| 8 | **Kelengkapan dilaporkan sebagai fakta, bukan ditebak ambang.** Minggu yang ada penjualannya tapi tidak ada notanya ditandai; angkanya tetap terbaca, tidak disembunyikan |
| 9 | Driver tidak bisa membaca harga bahan — lewat fungsi maupun tabel langsung |
| 10 | Bahan yang belum pernah dibeli: harga `NULL` (bukan `0`), stok 0, barisnya tetap muncul supaya layar tahu ia perlu diisi |

Tes 8 yang paling mudah salah dirancang. Godaannya memasang ambang: "kalau
biaya per cup di bawah Rp sekian, berarti notanya belum lengkap" — yaitu
mengganti satu angka karangan dengan angka karangan lain. Yang dilaporkan di
sini fakta yang bisa diperiksa: berapa minggu punya catatan belanja, dari
berapa minggu yang ada penjualannya. Pembandingnya penjualan, bukan kalender,
karena minggu gerobak libur memang tidak perlu ada notanya.

Tes 3 yang paling berharga di lapangan: supplier Rp18.000/kg dengan daging
550 g lebih **mahal** daripada Rp20.000/kg dengan daging 650 g — Rp32,7 lawan
Rp30,8 per gram. Notanya berkata sebaliknya.

## 24 — Takaran per menu, dan HPP yang dihitung darinya (0030)

0029 memasang harga bahan yang terukur dari nota. Berkas ini memakainya untuk
menjawab pertanyaan yang sejak awal tidak pernah bisa dijawab: **menu mana yang
tipis, dan kalau biayanya naik, naik karena bahan apa.**

Takarannya per satu cup, dalam satuan pakai — untuk buah, berat **daging**,
sejalan dengan 0029. Tidak ada satu pun titik konversi di seluruh rantai: nota
masuk sebagai gram daging, resep memakai gram daging, stok berkurang dalam gram
daging.

**Takaran berversi.** Kunci utamanya `(product_id, berlaku_dari, bahan_id)`.
Resep yang berubah jadi versi baru bertanggal, bukan menimpa yang lama —
supaya HPP Oktober tetap dihitung dengan resep yang berlaku di Oktober.

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Takaran tersimpan sebagai satu versi utuh |
| 2 | **Belum ada satu pun harga → HPP `NULL`, margin `NULL`, bukan untung penuh.** Nama ketiga bahan yang kurang ikut dikembalikan supaya layar bisa menyebutnya |
| 3 | Dua dari tiga bahan sudah berharga tetap **tidak cukup** — satu yang kurang membatalkan seluruh angkanya |
| 4 | Lengkap: HPP dan margin benar, dan **rinciannya berjumlah persis sama dengan HPP** — kalau tidak, pemecahan "naik karena bahan apa" menunjuk angka yang salah |
| 5 | Rincian mengurutkan bahan termahal lebih dulu |
| 6 | **Resep diubah hari ini tidak menggeser HPP kemarin.** Inti kenapa takaran berversi |
| 7 | Versi bertanggal lebih tua ditolak (`VERSI_MUNDUR`) — HPP bulan yang sudah dilaporkan tidak bisa ditulis ulang |
| 8 | Menu tanpa takaran sama sekali: `NULL`, dan barisnya **tetap muncul** supaya layar tahu ia perlu diisi |
| 9 | Dua dasar harga memberi angka berbeda dan tidak tertukar — `terakhir` untuk keputusan harga jual, `rata` untuk laporan |
| 10 | `takaran` tidak punya kebijakan RLS untuk INSERT/UPDATE/DELETE; perubahan hanya lewat `admin_simpan_takaran` |
| 11 | Driver tidak bisa membaca HPP maupun resep |

Tes 2, 3, dan 8 menjaga aturan yang sama dari tiga arah, dan aturan itu yang
paling gampang dilanggar: **bahan tanpa harga membuat HPP `NULL`, bukan nol.**
Kalau ketiadaan harga dibaca sebagai nol, menu yang datanya paling tidak
lengkap justru tampil paling untung — pola yang persis sama dengan dasbor yang
dulu menampilkan "0 cup" padahal driver sudah jualan.

Catatan untuk berkas uji lain: sejak 0030 ke-15 bahan RAMU disemai oleh
migrasi, jadi berkas uji **tidak boleh menyemai bahan dengan ID karangan** —
carilah lewat nama, sama seperti yang dilakukan layar admin. `23` sudah
disesuaikan.

## 25 — Biaya per cup dari takaran, bukan belanja dibagi cup (0031)

Lahir dari angka yang ngawur di layar pada 15 September 2026, hari pertama nota
belanja dipakai sungguhan:

```
Belanja 30 hari   Rp1.988.374
Cup terjual              133
---------------------------------
"Biaya per cup"   Rp14.951   <- lebih mahal dari harga jualnya
```

Sebabnya satu belanja kemasan **1.000 cup** yang akan terpakai tujuh puluh hari
ke depan, dibagi dengan cup yang terjual seminggu. Rumus "belanja dibagi cup"
hanya benar kalau tinggi stok di awal dan di akhir rentang kira-kira sama —
syarat yang jauh dari terpenuhi pada gerobak yang baru pertama kali belanja
borongan. Itulah pekerjaan hitung stok bulanan.

Yang **bisa** dihitung sekarang, dan sudah benar sejak 0029 memasang harga dan
0030 memasang takaran: biaya menurut resep.

```
biaya = SUM( cup terjual tiap menu  ×  HPP menu itu pada hari cup itu terjual )
```

Angka ini tidak memuat susut, tumpah, dan kelebihan tuang, jadi ia selalu lebih
murah daripada kenyataan. Perbedaannya justru gunanya: begitu hitung stok ada,
**selisih antara keduanya adalah bocor.**

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | `admin_belanja_ringkas` melaporkan rupiah belanja apa adanya dan **tidak membaginya dengan apa pun**; bagian kemasan disebut terpisah karena itu yang paling sering dibeli borongan |
| 2 | Biaya per cup = takaran × harga, cocok dengan hitungan tangan, berikut marginnya |
| 3 | Topping tidak ikut dihitung sebagai cup — ia tidak punya takaran dan tidak akan pernah punya; ikut dihitung, ia membuat laporan tampak tidak lengkap selamanya |
| 4 | **Pembaginya cup yang TERNILAI, bukan seluruh cup.** Membagi biaya 4 cup dengan 7 cup melaporkan biaya yang terlalu murah — arah kesalahan yang paling berbahaya, karena margin tampak lebih bagus |
| 5 | Cup dinilai dengan harga saat ia terjual, bukan harga hari ini. Kalau tidak, laporan bulan lalu berubah tiap kali ada belanja baru |
| 6 | Rentang tanpa penjualan: satu baris berisi nol dan `NULL`, dan **tidak** ditandai lengkap |
| 7 | Kedua fungsi tertutup untuk driver |

Tes 4 dan 5 menjaga dua arah kesalahan yang berlawanan tapi berakar sama:
angka yang tidak diketahui tidak boleh diam-diam diisi — tidak dengan nol
(tes 4), tidak pula dengan harga hari ini (tes 5).

Migrasi **0032** menambahkan tiga uji lagi ke berkas yang sama. Sebabnya
keadaan nyata pada hari nota pertama dipakai: seluruh penjualan 7–14 September,
seluruh nota 15 September — tidak ada satu hari pun yang beririsan, sehingga
laporannya berbunyi "0 dari 133 cup ternilai".

0030 sudah menyemai takaran berlaku sejak hari jualan pertama dengan alasan
"resep ini memang yang dipakai sejak awal". Memperlakukan harga berbeda — resep
boleh dimundurkan, harga tidak — bukan kehati-hatian melainkan
ketidakkonsistenan yang hasilnya layar kosong.

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 8 | Cup yang terjual sebelum nota pertama dinilai dengan harga paling awal yang diketahui, **dan ditandai `harga_perkiraan`** — dipakai diam-diam, layar akan menyebutnya angka terukur |
| 9 | Rentang yang notanya sudah ada **tidak** ditandai perkiraan |
| 10 | Batasnya: bahan yang **belum pernah** dibeli tetap tidak punya harga. Yang dimundurkan adalah bukti yang ada; ketiadaan bukti tetap ketiadaan |

## 26 — Koreksi nota jadi satu tindakan (0033)

Lahir dari keluhan pemakai pada nota pertama yang salah ketik: *"fitur
koreksinya bikin bingung, jadi ada angka yang double, yang lama masih ada."*

```
Mangga  15 Sep   360 g   Rp20.000     <- salah
Mangga  15 Sep   500 g   Rp20.000     <- benar
Mangga  15 Sep  -360 g  -Rp20.000     <- pembatal
```

Nettonya 500 g, dan itu benar. Tapi yang terbaca adalah angka dobel dengan yang
lama masih nangkring di situ. **Buku besar yang jujur tapi tidak terbaca sama
saja dengan tidak jujur** — yang membacanya berhenti mempercayainya.

Dua sebabnya, dan keduanya diperbaiki:

**Pasangannya tidak pernah tercatat.** Baris pembatal tidak menunjuk baris mana
yang dibatalkannya, jadi layar hanya bisa menebak dari kesamaan angka — dan
tebakan itu salah begitu ada dua nota kembar pada hari yang sama.

**Koreksi membutuhkan dua langkah.** Membatalkan lalu mengetik ulang adalah dua
kali menekan simpan untuk satu peristiwa yang di kepala pemakainya cuma "saya
salah ketik". Di antara keduanya angkanya sempat salah, dan bila langkah kedua
terlupa, yang tertinggal adalah stok hilang tanpa penggantinya.

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Satu tekan menulis dua baris — pembatal dan penggantinya — dan nettonya 500 g, bukan 860 g |
| 2 | Riwayat menyebut tiga keadaan terpisah: `berlaku`, `dibatalkan`, `pembatal` — layar bisa melipat yang terakhir |
| 3 | **Dua nota kembar pada hari yang sama: tepat satu ditandai dibatalkan.** Penebak dari kesamaan angka akan menandai dua-duanya |
| 4 | Pembatalan murni tidak mengarang pengganti |
| 5 | Satu nota tidak bisa dibatalkan dua kali — dua pembatal akan mengurangi stok dua kali dari satu peristiwa |
| 6 | Baris pembatal tidak bisa dibatalkan lagi |
| 7 | Pembatal memakai **tanggal aslinya**; harga pada hari asal ikut terkoreksi |
| 8 | Angka mustahil tetap ditolak, dan penolakannya **tidak meninggalkan pembatal yatim** |
| 9 | Tertutup untuk driver |

Tes 3 yang paling menentukan bentuk rancangannya: tanpa `membatalkan_id`,
satu-satunya cara memasangkan pembatal dengan aslinya adalah menebak dari angka
yang sama — dan tebakan itu pasti salah pada kasus yang paling wajar terjadi.

Tes 8 menjaga hal yang mudah terlewat: `admin_perbaiki_belanja` menulis dua
baris, dan kegagalan di baris kedua tidak boleh meninggalkan baris pertama
sendirian. Satu pembatal tanpa pengganti adalah stok yang hilang tanpa sebab.

## 27 — Nota salah bisa dihapus; yang dibatalkan berhenti menyetir harga (0034)

Dari satu keluhan yang sama: *"kalau tidak dihapus, itu masuk ke perhitungan."*

**Bug yang ditemukan sambil memeriksanya.** `harga_bahan_pada()` dan
`admin_bahan_ringkas()` memilih harga terakhir dengan satu-satunya saringan
`jumlah > 0` — dan baris yang sudah dibatalkan lolos saringan itu. Batalkan
nota terbaru tanpa menggantinya, dan harga bahan itu **tetap** diambil dari
nota yang barusan dinyatakan salah. Belum menggigit di produksi hanya karena
kebetulan nota terbaru tiap bahan kebetulan yang masih berlaku.

**Hapus = pindah ke arsip, bukan lenyap.** Menghapus baris begitu saja membuat
riwayat harga bisa berubah surut — persis yang dijaga 0029 sejak awal. Jadi
menghapus berarti memindahkan ke `belanja_terhapus`, lengkap dengan siapa,
kapan, dan alasannya. Layar jadi bersih, buktinya tidak hilang.

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | **Nota yang dibatalkan tidak boleh jadi harga terakhir** — harganya jatuh kembali ke nota yang masih berlaku, bukan bertahan di angka yang sudah dinyatakan salah |
| 2 | Menghapus memindahkan ke arsip, lengkap dengan penghapus dan alasannya |
| 3 | Yang dihapus benar-benar hilang dari perhitungan, bukan cuma dari pandangan |
| 4 | Pasangan pembatalan dihapus **bersama** — nota tanpa pembatalnya meninggalkan baris negatif yatim yang benar-benar masuk perhitungan |
| 5 | Dari arah pembatal pun pasangannya ikut — menghapus pembatal sendirian akan menghidupkan kembali angka yang salah |
| 6 | Arsip tidak bisa dikosongkan maupun diubah dari aplikasi; tanpa itu "hapus" jadi benar-benar melenyapkan |
| 7 | Tertutup untuk driver, lewat fungsi maupun tabel |

Tes 4 dan 5 menjaga kejadian nyata: nota Mangga di produksi sempat punya satu
baris pembatal yang terlepas dari pasangannya, dan baris yatim itu membuat
netto rupiahnya jadi **nol** — bahannya seolah gratis.

## 28 — Ekonomi terukur menggantikan margin yang diketik (0035)

Sejak awal proyek, satu angka menyetir setiap vonis uang: `MARGIN_PER_CUP =
5000`. Dari situ turun titik impas 20 cup/hari, ambang gerobak 2,0 cup/jam,
dan ambang ruko 4,4 cup/jam — tiga angka yang dipakai memutuskan apakah sebuah
titik layak disewa. Dua di antaranya bahkan memakai asumsi margin yang
**berbeda** (Rp5.000 dan Rp6.500) untuk menilai titik yang sama di peta yang
sama.

Resep ujinya sengaja dua bahan saja supaya setiap angka bisa dihitung tangan:
Pisang 100 g @ Rp30/g + Cup 1 @ Rp600 = HPP Rp3.600, jual Rp10.000, laba
Rp6.400 per cup.

| Tes | Perilaku yang dijamin |
|-----|----------------------|
| 1 | Belum ada cup ternilai -> semuanya **NULL, bukan nol**; "impas 0 cup/hari" terdengar seperti fakta padahal artinya "belum tahu" |
| 2 | Laba per cup, laba kotor, dan laba bersih cocok dengan hitungan tangan |
| 3 | **Titik impas turun** karena marginnya naik — inti seluruh berkas ini |
| 4 | Ambang gerobak dan ruko berasal dari **margin yang sama**; yang membedakan cuma biaya tetap dan jam buka |
| 5 | Biaya tetap mengikuti **hari jualan**, bukan panjang kalender rentangnya |
| 6 | Parameter diubah di satu tempat, seluruh vonis ikut bergeser |
| 7 | `parameter_ekonomi` tetap satu baris: tidak bisa ditambah maupun dihapus |
| 8 | Tertutup untuk driver, lewat fungsi maupun tabel |

Tes 5 menjaga kesalahan yang mudah dibuat: menagih biaya tetap pada hari
gerobak libur membuat laba bersih tampak lebih buruk daripada kenyataannya.
Rentang 30 hari dengan jualan satu hari harus menagih biaya tetap satu hari.

Tes 4 membandingkan rasio ruko:gerobak dengan toleransi 0,02 — kedua ambang
dibulatkan ke dua desimal lebih dulu, jadi membandingkannya dengan rasio tak
bulat akan selalu meleset sedikit.
