-- =====================================================================
-- PROVODKA V8 — 8 ta ish uchun SQL (bosqichlar izoh bilan ajratilgan)
-- ---------------------------------------------------------------------
-- Tartib (brief): 2 (bug) → 5 (hisob type) → 3 (limit reset) → 4 (suv) →
--                 6 (konvert izoh — SQLsiz) → 7 (koridor sozlama) →
--                 1 (hisobot) → 8 (qarzdorlar).
--
-- QOIDA (bitta DB, prod ishlab turibdi): SQL ADDITIVE.
--   * add column if not exists / create table if not exists
--   * yangi funksiya/view yoki `create or replace` ESKI IMZONI SAQLAB
--   * ustun/funksiya O'CHIRISH yoki imzo (argument/tur) O'ZGARTIRISH — TAQIQ
--   * yangi RPC: SECURITY DEFINER + set search_path=public + REVOKE public,anon
--   * entry.created_by = TEXT (ism) — profiles bilan JOIN QILINMAYDI
--
-- Asilbek qo'lda RUN qiladi. Har bosqichni alohida ham ishga tushirsa bo'ladi.
-- =====================================================================


-- #####################################################################
-- ##  2-BOSQICH — BUG: professional'da "Ijara" (9411) saqlanmaydi     ##
-- #####################################################################
-- SQL O'ZGARTIRISH YO'Q — bu bosqich faqat DIAGNOSTIKA.
--
-- Sabab (frontendda topildi va tuzatildi): 9411 moddasida
-- accounts.davr_majburiy = true. professional-dev.html'da davr uchun ikkita
-- native <input type="date"> yonma-yon (flex:1; min-width:0) turardi —
-- mobil ekranda ular qisilib, native kalendar tugmasi kesilib qolardi:
-- sana TANLAB BO'LMASDI → davrOk() hech qachon true bo'lmasdi →
-- "Saqlash" abadiy disabled. 9412 (Ish haqi)da davr_majburiy=false
-- bo'lgani uchun u ishlardi — farq aynan shu bayroqda.
--
-- Tuzatish (frontend, professional-dev.html):
--   * davr uchun hodim-dev.html'dagi ikki oylik O'Z kalendarimiz;
--   * "Shu oy / O'tgan oy / Keyingi oy / Tozalash" tez tugmalari;
--   * Saqlash tugmasi ostida "nega yopiq" izohi (jim disabled qolmaydi).
--
-- Quyidagi SELECT bilan tasdiqlang (hech narsani o'zgartirmaydi):
--   select code, name, type, section,
--          chek_majburiy, izoh_majburiy, davr_majburiy, is_active
--     from accounts
--    where code in ('9411','9412','9413')
--    order by code;
--
-- Kutilgan: 9411 → davr_majburiy = true, 9412 → false.
-- Agar 9411'da davr_majburiy = false chiqsa, sabab boshqa bayroqda
-- (izoh_majburiy) yoki standart_xarajat limitida — quyidagi so'rov ko'rsatadi:
--   select fa.name as filial, ma.code, ma.name, s.limit_uzs
--     from standart_xarajat s
--     join accounts fa on fa.id = s.filial_id
--     join accounts ma on ma.id = s.modda_id
--    where ma.code = '9411';

do $$
declare v_davr boolean; v_izoh boolean;
begin
  select davr_majburiy, izoh_majburiy into v_davr, v_izoh
    from accounts where code = '9411' limit 1;
  if not found then
    raise notice '2-BOSQICH: 9411 hisobi topilmadi (kod boshqacha bo''lishi mumkin).';
  else
    raise notice '2-BOSQICH DIAGNOSTIKA: 9411 davr_majburiy=%, izoh_majburiy=%', v_davr, v_izoh;
  end if;
  raise notice '2-BOSQICH OK: SQL o''zgarishi yo''q — tuzatish frontendda (professional-dev.html).';
end $$;
