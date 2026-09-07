#!/usr/bin/env bash
#
# Menjalankan seluruh berkas uji database, masing-masing pada basis data yang
# baru dibuat.
#
# Setiap berkas uji menyemai datanya sendiri dan berasumsi tabelnya kosong,
# jadi berbagi satu basis data akan membuat hasilnya bergantung pada urutan.
# Skrip ini yang menegakkan aturan itu — sebelumnya hanya tertulis di README
# dan dikerjakan manual, sehingga mudah terlewat.
#
# Dipakai sama persis oleh CI dan oleh siapa pun di mesinnya sendiri:
#
#   supabase/tests/run.sh              # semua berkas uji
#   supabase/tests/run.sh 06 09        # hanya yang nomornya disebut
#
# Koneksi diambil dari variabel lingkungan psql yang biasa (PGHOST, PGPORT,
# PGUSER, PGPASSWORD). Butuh psql dan hak membuat basis data.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tests_dir="$repo_root/supabase/tests"
db_prefix="${RAMUJUS_TEST_DB_PREFIX:-ramujus_test}"

# Berkas yang dipasang sebelum setiap berkas uji, berurutan.
setup_files=("$tests_dir/00_supabase_stub.sql" "$repo_root/supabase/schema.sql")
while IFS= read -r migration; do
  setup_files+=("$migration")
done < <(find "$repo_root/supabase/migrations" -name '*.sql' | sort)

# Berkas uji: yang diminta di argumen, atau semuanya.
if [ "$#" -gt 0 ]; then
  test_files=()
  for prefix in "$@"; do
    match=$(find "$tests_dir" -maxdepth 1 -name "${prefix}_*.sql" | sort)
    if [ -z "$match" ]; then
      echo "Tidak ada berkas uji dengan awalan '${prefix}'." >&2
      exit 2
    fi
    while IFS= read -r f; do test_files+=("$f"); done <<< "$match"
  done
else
  test_files=()
  while IFS= read -r f; do
    test_files+=("$f")
  done < <(find "$tests_dir" -maxdepth 1 -name '[0-9][0-9]_*.sql' ! -name '00_*' | sort)
fi

echo "Memasang: schema.sql + $(( ${#setup_files[@]} - 2 )) migrasi"
echo "Menjalankan ${#test_files[@]} berkas uji"
echo

failed=()

for test_file in "${test_files[@]}"; do
  name="$(basename "$test_file" .sql)"
  db="${db_prefix}_${name%%_*}"
  log="$(mktemp)"

  printf '%-34s' "$name"

  dropdb --if-exists "$db" >/dev/null 2>&1 || true
  createdb "$db"

  ok=true
  for setup in "${setup_files[@]}"; do
    if ! psql -q -d "$db" -v ON_ERROR_STOP=1 -f "$setup" >>"$log" 2>&1; then
      ok=false
      echo "GAGAL DIPASANG ($(basename "$setup"))"
      break
    fi
  done

  if $ok; then
    if psql -q -d "$db" -v ON_ERROR_STOP=1 -f "$test_file" >>"$log" 2>&1; then
      echo "LULUS"
    else
      ok=false
      echo "GAGAL"
    fi
  fi

  if ! $ok; then
    failed+=("$name")
    echo "---------- keluaran $name ----------"
    tail -n 40 "$log"
    echo "------------------------------------"
  fi

  rm -f "$log"
  dropdb --if-exists "$db" >/dev/null 2>&1 || true
done

echo
if [ "${#failed[@]}" -gt 0 ]; then
  echo "GAGAL: ${failed[*]}"
  exit 1
fi

echo "Seluruh ${#test_files[@]} berkas uji lulus."
