# Uji migrasi database

Menjalankan `schema.sql` + seluruh migrasi di Postgres lokal, lalu memeriksa
aturan keamanan dan alur pembuatan pesanan. Tidak menyentuh proyek Supabase
milik siapa pun.

`00_supabase_stub.sql` menyediakan tiruan minimal dari hal-hal yang disediakan
Supabase (`auth.users`, `auth.uid()`, role `authenticated`, publikasi
realtime), supaya skema yang sama bisa dijalankan di Postgres polos.
`auth.uid()` versi tiruan membaca GUC sesi `test.uid`, sehingga tes dapat
berpura-pura menjadi driver atau admin tertentu.

## Menjalankan

Butuh Postgres 14+ yang sedang berjalan.

```bash
createdb ramujus_test
psql -d ramujus_test -v ON_ERROR_STOP=1 -f supabase/tests/00_supabase_stub.sql
psql -d ramujus_test -v ON_ERROR_STOP=1 -f supabase/schema.sql
psql -d ramujus_test -v ON_ERROR_STOP=1 -f supabase/migrations/0001_security_hardening.sql
psql -d ramujus_test -v ON_ERROR_STOP=1 -f supabase/tests/01_security_and_orders.sql
```

Setiap tes berhenti dengan error bila perilakunya salah, jadi keluaran yang
berakhir tanpa `ERROR` berarti semuanya lolos.

## Yang diperiksa

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
