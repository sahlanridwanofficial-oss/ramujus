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
| 4 | Petak di bawah 50 m dijepit — hasil petak 5 m dan 0 m identik dengan petak 50 m, baris demi baris |
| 5 | Dua gerobak dengan cup per **hari** yang sama terbaca sangat berbeda pada cup per **jam** — inilah yang memisahkan lokasi bagus dari jam kerja panjang |
| 6 | Jam kerja dijumlahkan per gerobak, bukan jam dinding: dua gerobak yang jalan bersamaan 5 dan 2 jam menghasilkan 7 jam-gerobak |
| 7 | Hari dengan satu pesanan (rentang nol) dijepit ke 1 jam, bukan pembagian dengan nol |
| 8 | Matriks hari × jam memisahkan hari yang berbeda, tidak menumpuknya jadi satu angka |
| 9 | Kelima fungsi tertutup untuk non-admin |
