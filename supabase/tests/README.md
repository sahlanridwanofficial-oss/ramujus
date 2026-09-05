# Uji migrasi database

Menjalankan `schema.sql` + seluruh migrasi di Postgres lokal, lalu memeriksa
aturan keamanan, alur pembuatan pesanan, pelacakan armada, penguncian audit
kas, dan perilaku pada skala 100 gerobak. Tidak menyentuh proyek Supabase milik siapa pun.

`00_supabase_stub.sql` menyediakan tiruan minimal dari hal-hal yang disediakan
Supabase (`auth.users`, `auth.uid()`, role `authenticated`, publikasi
realtime), supaya skema yang sama bisa dijalankan di Postgres polos.
`auth.uid()` versi tiruan membaca GUC sesi `test.uid`, sehingga tes dapat
berpura-pura menjadi driver atau admin tertentu.

## Menjalankan

Butuh Postgres 14+ yang sedang berjalan. Setiap berkas uji memerlukan basis
data yang bersih.

```bash
createdb ramujus_test
psql -d ramujus_test -v ON_ERROR_STOP=1 -f supabase/tests/00_supabase_stub.sql
psql -d ramujus_test -v ON_ERROR_STOP=1 -f supabase/schema.sql
psql -d ramujus_test -v ON_ERROR_STOP=1 -f supabase/migrations/0001_security_hardening.sql
psql -d ramujus_test -v ON_ERROR_STOP=1 -f supabase/migrations/0002_live_fleet_tracking.sql
psql -d ramujus_test -v ON_ERROR_STOP=1 -f supabase/migrations/0003_offline_orders_and_cash_lock.sql
psql -d ramujus_test -v ON_ERROR_STOP=1 -f supabase/migrations/0004_customer_profile.sql

# lalu salah satu berkas uji, masing-masing pada basis data yang baru
psql -d ramujus_test -v ON_ERROR_STOP=1 -f supabase/tests/01_security_and_orders.sql
```

Setiap tes berhenti dengan error bila perilakunya salah, jadi keluaran yang
berakhir dengan exit code 0 berarti semuanya lolos.

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
| 4 | Waktu yang tidak masuk akal dikoreksi ke sekarang (anti sisip mundur) |
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
