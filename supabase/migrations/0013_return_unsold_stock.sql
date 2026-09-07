-- ============================================================
-- 0013 — Cup sisa kembali ke stok pusat saat audit malam
--
-- Jalankan di Supabase SQL Editor SETELAH 0012. Aman dijalankan berulang.
--
-- Masalah: muat gerobak pagi mengurangi products.stock_quantity sebesar
-- jumlah yang dibawa, tetapi audit malam tidak pernah mengembalikan apa pun.
-- lock_reconciliation() hanya mengubah status dan menulis jejak audit;
-- physical_remaining disimpan lalu hanya dipakai menghitung selisih di
-- layar. Akibatnya stok pusat melayang turun setiap hari sebesar cup yang
-- kembali ke base: muat 50, laku 42, kembali 8 — stok pusat tetap berkurang
-- 50, dan delapan cup itu ada secara fisik tetapi hilang dari angka sistem.
--
-- Pengembalian TIDAK dibuat otomatis penuh. Cup yang sudah keluar seharian
-- belum tentu layak dijual lagi; memasukkan semuanya kembali ke stok justru
-- membuat angkanya salah ke arah sebaliknya. Yang ditambahkan di sini adalah
-- keputusan eksplisit sekali per malam:
--
--     dibawa = terjual + sisa fisik + rusak + selisih
--     sisa fisik = kembali ke stok + tidak dikembalikan
--
-- returned_quantity adalah bagian sisa fisik yang diseal ulang dan kembali
-- ke stok pusat. Sisanya tetap tercatat sebagai sisa yang tidak kembali,
-- sehingga keduanya terlihat, bukan salah satu disembunyikan.
--
-- Penerapannya menempel pada penguncian rekonsiliasi supaya stok hanya
-- bergerak saat angka malam itu sudah final — dan dibalik saat kunci dibuka,
-- supaya membuka lalu mengunci ulang tidak pernah menghitung ganda.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Kolom baru
-- ------------------------------------------------------------
ALTER TABLE public.driver_allocation_items
  ADD COLUMN IF NOT EXISTS returned_quantity INTEGER NOT NULL DEFAULT 0;

DO $$
BEGIN
  ALTER TABLE public.driver_allocation_items
    ADD CONSTRAINT allocation_items_returned_nonneg CHECK (returned_quantity >= 0);
EXCEPTION WHEN duplicate_object THEN NULL;
END;
$$;

-- Penanda bahwa pengembalian untuk alokasi ini sudah diterapkan ke stok.
-- Inilah yang membuat penerapannya idempoten: sekali diterapkan, penguncian
-- berikutnya tidak menambah apa pun sampai kuncinya dibuka.
ALTER TABLE public.driver_daily_allocations
  ADD COLUMN IF NOT EXISTS stock_returned_at TIMESTAMPTZ;

-- ------------------------------------------------------------
-- 2. Penguncian rekonsiliasi sekaligus mengembalikan cup ke stok
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lock_reconciliation(
  p_allocation_id UUID,
  p_note          TEXT DEFAULT NULL
)
RETURNS public.driver_daily_allocations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_alloc            public.driver_daily_allocations;
  v_already_returned BOOLEAN;
  v_item             RECORD;
  v_prod             public.products;
  v_total_returned   INTEGER := 0;
BEGIN
  IF public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'ADMIN_ONLY' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_alloc
    FROM public.driver_daily_allocations
   WHERE id = p_allocation_id
   FOR UPDATE;

  IF NOT FOUND OR v_alloc.status = 'reconciled' THEN
    RAISE EXCEPTION 'ALLOCATION_NOT_FOUND_OR_ALREADY_LOCKED' USING ERRCODE = '22023';
  END IF;

  v_already_returned := v_alloc.stock_returned_at IS NOT NULL;

  -- Yang dikembalikan tidak boleh melebihi yang benar-benar ada di tangan.
  -- Diperiksa sebelum apa pun ditulis, supaya penolakan tidak meninggalkan
  -- stok yang sudah terlanjur bergerak.
  FOR v_item IN
    SELECT ai.returned_quantity, ai.physical_remaining, p.name
      FROM public.driver_allocation_items ai
      JOIN public.products p ON p.id = ai.product_id
     WHERE ai.allocation_id = p_allocation_id
       AND ai.returned_quantity > COALESCE(ai.physical_remaining, 0)
  LOOP
    RAISE EXCEPTION 'RETURN_EXCEEDS_REMAINING:%', v_item.name USING ERRCODE = '22023';
  END LOOP;

  UPDATE public.driver_daily_allocations
     SET status            = 'reconciled',
         reconciled_at     = NOW(),
         reconciled_by     = auth.uid(),
         notes             = COALESCE(p_note, notes),
         stock_returned_at = COALESCE(stock_returned_at, NOW())
   WHERE id = p_allocation_id
  RETURNING * INTO v_alloc;

  INSERT INTO public.allocation_audit_log (allocation_id, action, actor_id, cash_settled, cash_expected, note)
  VALUES (v_alloc.id, 'reconciled', auth.uid(), v_alloc.cash_settled, v_alloc.total_cash_collected, p_note);

  -- Pengembalian hanya diterapkan sekali. Bila alokasi ini pernah dikunci
  -- lalu dibuka, pembukaannya sudah membalik stok dan menghapus penandanya,
  -- jadi penguncian ini menerapkannya lagi dari awal.
  IF NOT v_already_returned THEN
    FOR v_item IN
      SELECT ai.product_id, ai.returned_quantity
        FROM public.driver_allocation_items ai
       WHERE ai.allocation_id = p_allocation_id
         AND ai.returned_quantity > 0
    LOOP
      UPDATE public.products
         SET stock_quantity = stock_quantity + v_item.returned_quantity
       WHERE id = v_item.product_id
      RETURNING * INTO v_prod;

      INSERT INTO public.stock_movements
        (product_id, delta, balance_after, reason, note, reference_id, actor_id)
      VALUES (v_item.product_id, v_item.returned_quantity, v_prod.stock_quantity,
              'allocation_return',
              'Sisa gerobak kembali ' || v_alloc.date, v_alloc.id, auth.uid());

      v_total_returned := v_total_returned + v_item.returned_quantity;
    END LOOP;
  END IF;

  RETURN v_alloc;
END;
$$;

REVOKE ALL ON FUNCTION public.lock_reconciliation(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lock_reconciliation(UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 3. Membuka kunci membalik pengembalian
--
-- Pembalikan diletakkan di trigger, bukan di sebuah RPC, karena membuka
-- kunci dilakukan lewat UPDATE biasa atas kolom status — dari aplikasi
-- maupun dari SQL Editor. Menaruhnya di sini membuat satu aturan berlaku
-- untuk semua jalur: selama penandanya ada, stok yang dikembalikan ikut
-- dibatalkan, sehingga membuka lalu mengunci ulang tidak pernah menghitung
-- cup yang sama dua kali.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_reconciled_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_item RECORD;
  v_prod public.products;
BEGIN
  IF OLD.status <> 'reconciled' THEN
    RETURN NEW;
  END IF;

  -- Satu-satunya perubahan yang diizinkan atas alokasi terkunci adalah
  -- membukanya kembali, dan hanya admin yang boleh.
  IF NEW.status = 'active' THEN
    IF auth.uid() IS NOT NULL
       AND public.get_user_role(auth.uid()) IS DISTINCT FROM 'admin' THEN
      RAISE EXCEPTION 'RECONCILIATION_UNLOCK_FORBIDDEN' USING ERRCODE = '42501';
    END IF;

    IF OLD.stock_returned_at IS NOT NULL THEN
      FOR v_item IN
        SELECT ai.product_id, ai.returned_quantity, p.name, p.stock_quantity
          FROM public.driver_allocation_items ai
          JOIN public.products p ON p.id = ai.product_id
         WHERE ai.allocation_id = OLD.id
           AND ai.returned_quantity > 0
         FOR UPDATE OF p
      LOOP
        -- Cup yang tadi dikembalikan bisa saja sudah dimuat ke gerobak lain
        -- pagi ini. Katakan apa adanya alih-alih memaksa stok jadi negatif.
        IF v_item.stock_quantity < v_item.returned_quantity THEN
          RAISE EXCEPTION 'UNLOCK_STOCK_UNAVAILABLE:%', v_item.name USING ERRCODE = '22023';
        END IF;

        UPDATE public.products
           SET stock_quantity = stock_quantity - v_item.returned_quantity
         WHERE id = v_item.product_id
        RETURNING * INTO v_prod;

        INSERT INTO public.stock_movements
          (product_id, delta, balance_after, reason, note, reference_id, actor_id)
        VALUES (v_item.product_id, -v_item.returned_quantity, v_prod.stock_quantity,
                'adjustment',
                'Pembatalan pengembalian sisa gerobak ' || OLD.date, OLD.id, auth.uid());
      END LOOP;

      NEW.stock_returned_at := NULL;
    END IF;

    INSERT INTO public.allocation_audit_log (allocation_id, action, actor_id, cash_settled, cash_expected)
    VALUES (OLD.id, 'unlocked', auth.uid(), OLD.cash_settled, OLD.total_cash_collected);

    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'RECONCILIATION_LOCKED' USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS allocations_reconciled_guard ON public.driver_daily_allocations;
CREATE TRIGGER allocations_reconciled_guard
  BEFORE UPDATE ON public.driver_daily_allocations
  FOR EACH ROW EXECUTE FUNCTION public.guard_reconciled_allocation();

-- ------------------------------------------------------------
-- 4. Ikhtisar stok memisahkan yang benar-benar ada di base
--
-- Sebelum ini "stok pusat" diam-diam berarti "stok pusat dikurangi seluruh
-- cup yang pernah dibawa ke gerobak dan belum pernah dikembalikan". Kolom
-- baru membuat cup yang menunggu keputusan pengembalian terlihat sebagai
-- angka tersendiri, bukan lenyap begitu saja.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_pending_returns()
RETURNS TABLE (
  product_id   UUID,
  name         TEXT,
  category     TEXT,
  pending_cups INTEGER,
  carts        INTEGER
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT p.id,
         p.name,
         p.category,
         COALESCE(sum(ai.physical_remaining - ai.returned_quantity), 0)::INTEGER,
         count(DISTINCT ai.allocation_id)::INTEGER
    FROM public.driver_allocation_items ai
    JOIN public.driver_daily_allocations a ON a.id = ai.allocation_id
    JOIN public.products p                ON p.id = ai.product_id
   WHERE a.status <> 'reconciled'
     AND COALESCE(ai.physical_remaining, 0) - ai.returned_quantity > 0
     AND public.get_user_role(auth.uid()) = 'admin'
   GROUP BY p.id, p.name, p.category
  HAVING COALESCE(sum(ai.physical_remaining - ai.returned_quantity), 0) > 0
   ORDER BY 4 DESC;
$$;

REVOKE ALL ON FUNCTION public.admin_pending_returns() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_pending_returns() TO authenticated;

NOTIFY pgrst, 'reload schema';
