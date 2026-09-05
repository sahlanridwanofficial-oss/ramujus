-- Tiruan minimal lingkungan Supabase agar schema.sql + migrasi bisa
-- dijalankan di Postgres polos untuk pengujian. Bukan bagian aplikasi.

CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT,
  raw_user_meta_data JSONB DEFAULT '{}'::jsonb
);

-- auth.uid() Supabase membaca klaim JWT; di sini dibaca dari GUC sesi
-- sehingga tes dapat berpura-pura menjadi pengguna tertentu.
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS UUID
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('test.uid', true), '')::uuid;
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END;
$$;

-- Di Supabase asli, role authenticated dapat memanggil auth.uid().
-- Tanpa hibah ini, tes akan gagal karena "permission denied for schema auth"
-- dan keliru terbaca sebagai penolakan oleh guard aplikasi.
GRANT USAGE ON SCHEMA auth TO authenticated, anon;
GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated, anon;
