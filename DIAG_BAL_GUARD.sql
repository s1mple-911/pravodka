-- =====================================================================
-- DIAG_BAL_GUARD.sql — "Kassada yetarli mablag' yo'q" xatosi qayerdan?
-- ---------------------------------------------------------------------
-- 🔴 Faqat O'QIYDI.
--
-- Xato matni REPODA YO'Q — ya'ni obyekt to'g'ridan bazada yaratilgan.
-- Eng ehtimolli manba: `entry_line` ustidagi `trg_bal_guard_entry_line`
-- (u diagnostikada ko'rindi, lekin kodi repoda saqlanmagan).
--
-- MUAMMO: so'rovlar tizimi xarajatni `status='pending'` bilan yozadi —
-- u BALANSGA TA'SIR QILMAYDI (hamma hisob `status='posted'` filtrlaydi).
-- Lekin balans qorovuli buni bilmasa, kassani manfiyga tushiradigan
-- satrni to'sadi va so'rov umuman yaratilmaydi.
--
-- Quyidagi natijalarni Fable'ga yuboring — aniq tuzatma yoziladi.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) `entry_line` va `entry` ustidagi HAMMA trigger va ular chaqiradigan
--    funksiya. Xato matnini qaysi funksiya berayotganini shundan ko'ramiz.
-- ---------------------------------------------------------------------
select t.tgname                                   as trigger_nomi,
       t.tgrelid::regclass                        as jadval,
       p.proname                                  as funksiya,
       t.tgenabled                                as holat,
       (p.prosrc ilike '%mablag%')                as xato_matni_shu_yerda
  from pg_trigger t
  join pg_proc p on p.oid = t.tgfoid
 where not t.tgisinternal
   and t.tgrelid in ('entry'::regclass, 'entry_line'::regclass)
 order by t.tgrelid::regclass::text, t.tgname;


-- ---------------------------------------------------------------------
-- 2) 🔴 ASOSIY — o'sha funksiyaning TO'LIQ kodi.
--    (1-so'rovda `xato_matni_shu_yerda = true` chiqqan funksiya nomini
--     quyiga qo'ying; odatda 'bal_guard_entry_line')
-- ---------------------------------------------------------------------
select p.proname,
       pg_get_functiondef(p.oid) as toliq_kod
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.prosrc ilike '%mablag%'
 order by p.proname;


-- ---------------------------------------------------------------------
-- 3) Qorovul `status` ni hisobga oladimi? (tez javob)
--    false chiqsa — u pending yozuvni ham to'sadi, tuzatish kerak.
-- ---------------------------------------------------------------------
select p.proname,
       (p.prosrc ilike '%posted%')  as status_filtri_bor,
       (p.prosrc ilike '%pending%') as pending_istisnosi_bor
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.prosrc ilike '%mablag%';
