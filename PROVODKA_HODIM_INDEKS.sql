-- =====================================================================
-- PROVODKA_HODIM_INDEKS.sql
-- Qoldiq/oylik jami so'rovlari uchun indekslar
-- =====================================================================
-- ⚠️⚠️ MUHIM: QATORLARNI BITTA-BITTADAN RUN QIL ⚠️⚠️
--
-- `create index concurrently` TRANZAKSIYA ICHIDA ishlamaydi, Supabase SQL Editor
-- esa butun skriptni bitta tranzaksiyada bajaradi. Ya'ni bu faylni to'liq
-- belgilab RUN qilsang xato beradi:
--     ERROR: CREATE INDEX CONCURRENTLY cannot run inside a transaction block
--
-- TO'G'RI USUL: pastdagi har bir `create index ...` qatorini ALOHIDA belgilab
-- (yoki nusxalab), alohida RUN qil. Uchta qadam, har biri bir necha soniya.
--
-- Nega CONCURRENTLY? Prod'da foydalanuvchilar ishlab turibdi. Oddiy `create index`
-- jadvalni qulflaydi va o'sha vaqtda hech kim xarajat yoza olmaydi. CONCURRENTLY
-- sekinroq quriladi, lekin hech kimni bloklamaydi.
--
-- Bu fayl ixtiyoriy: indekssiz ham hamma narsa ishlaydi, faqat sekinroq.
-- =====================================================================


-- ── 1-QADAM (alohida RUN) ──────────────────────────────────────────────
-- entry_line.account_id — har qoldiq so'rovining asosiy filtri.
create index concurrently if not exists idx_entry_line_account
  on entry_line(account_id);


-- ── 2-QADAM (alohida RUN) ──────────────────────────────────────────────
-- entry: posted + o'chirilmagan — qoldiqning yagona sharti (qisman indeks).
create index concurrently if not exists idx_entry_posted
  on entry(status) where is_deleted = false;


-- ── 3-QADAM (alohida RUN) ──────────────────────────────────────────────
-- Oylik jami sana oralig'i bo'yicha skanerlaydi.
create index concurrently if not exists idx_entry_date
  on entry(entry_date);


-- =====================================================================
-- TEKSHIRUV (buni butunlay RUN qilsa bo'ladi)
-- =====================================================================
-- Uchala indeks bormi va SOG'MI (indisvalid = true bo'lishi shart):
--
-- select i.indexrelid::regclass as indeks, i.indisvalid as sogmi
--   from pg_index i
--  where i.indexrelid::regclass::text in
--        ('idx_entry_line_account','idx_entry_posted','idx_entry_date');
--
-- Agar biror indeks `sogmi = false` bo'lsa (CONCURRENTLY yarim uzilgan) —
-- uni o'chirib qayta RUN qil:
--   drop index concurrently if exists <indeks_nomi>;
