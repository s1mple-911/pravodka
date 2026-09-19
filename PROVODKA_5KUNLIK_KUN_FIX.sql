-- ============================================================================
--  PROVODKA_5KUNLIK_KUN_FIX.sql — 2026-09-19
--  5 kunlik: kun muhrlash (beshkunlik_kun upsert) HAR SAFAR yiqilardi:
--    «beshkunlik_kun muhrlash xato: record "new" has no field "updated_at"»
--  Sabab: trg_beshkunlik_kun_touch (_beshkunlik_touch) updated_at/updated_by yozadi, lekin
--  beshkunlik_kun jadvalida bu ustunlar YO'Q (PROVODKA_5KUNLIK.sql da ochilmagan) → hech bir kun
--  muhrlanmagan (kurs_uzs/frozen_at yozilmagan), Fakt doim jonli qolgan. Additive tuzatish.
-- ============================================================================
alter table beshkunlik_kun add column if not exists updated_at timestamptz not null default now();
alter table beshkunlik_kun add column if not exists updated_by uuid;

select count(*) as muhrlangan_kunlar, max(frozen_at) as oxirgi from beshkunlik_kun where frozen_at is not null;
