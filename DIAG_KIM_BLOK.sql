-- =====================================================================
-- DIAG_KIM_BLOK.sql — to'siq kimni bloklayapti va yetimlarni kim yozgan?
-- 🔴 Faqat O'QIYDI. Bittalab RUN qiling.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) YETIMLARNI KIM YOZGAN (bugungilar)
--    created_by = a99afc40-7b9d-446b-b3b7-42fb061cb61e
-- ---------------------------------------------------------------------
select p.id,
       (to_jsonb(p) ->> 'full_name')  as ism,
       (to_jsonb(p) ->> 'role')       as rol,
       (select u.email from auth.users u where u.id = p.id) as email
  from profiles p
 where p.id = 'a99afc40-7b9d-446b-b3b7-42fb061cb61e'::uuid;


-- ---------------------------------------------------------------------
-- 2) 🔴 HOZIR KIM BLOKLANGAN — to'siq qaysi hodimlarga pul kiritishni
--    to'sayotganini ko'rsatadi. `blok = true` bo'lganlar bugalterga
--    "xato" berayotgan kassalar.
-- ---------------------------------------------------------------------
select b.kassa_id,
       b.kassa_nom,
       b.subtitle,
       b.jami_kirim,
       b.jami_xarajat,
       case when b.jami_kirim > 0
            then round(b.jami_xarajat / b.jami_kirim * 100, 1)
            else null end                          as foiz,
       hodim_tosiq_foiz()                          as kerak_foiz,
       (hodim_tosiq_blok(b.kassa_id) is not null)  as bloklangan
  from v_hodim_balans b
 order by bloklangan desc nulls last, foiz nulls first;


-- ---------------------------------------------------------------------
-- 3) Yetim urinishlar vaqtida qaysi kassalarga pul berilayotgan edi?
--    (o'sha daqiqalarda MUVAFFAQIYATLI o'tgan transferlarning Dt tomoni)
-- ---------------------------------------------------------------------
select a.code, a.name, a.kassa_turi,
       (hodim_tosiq_blok(coalesce(hodim_kassa_ildiz(a.id), a.id)) is not null) as bloklangan,
       count(*) as urinish
  from entry e
  join entry_line l on l.entry_id = e.id and l.debit > 0
  join accounts a   on a.id = l.account_id
 where e.created_at::date = (now() at time zone 'Asia/Tashkent')::date
   and a.section = 'pul'
 group by a.code, a.name, a.kassa_turi, 4
 order by urinish desc
 limit 20;


-- =====================================================================
-- 4) 🔴 TEZKOR YECHIM — bugalter darrov ishlashi kerak bo'lsa.
--
--    Ikki variant. BIRINCHISI tavsiya etiladi (DDL yo'q, qaytarish oson):
--
--    (a) To'siqni butunlay o'chirish (admin sifatida):
--          select set_hodim_tosiq_foiz(0);
--        Qaytarish:  select set_hodim_tosiq_foiz(70);
--
--    (b) Trigger'ni olib tashlash (qattiqroq chora):
--          drop trigger if exists trg_hodim_tosiq_entry_line on entry_line;
--        Qaytarish: PROVODKA_XARAJAT_TOSIQ.sql ning trigger blokini qayta RUN.
--
--    ⚠️ (a) yetarli: foiz 0 bo'lsa `hodim_tosiq_guard` birinchi shartda
--       `return new` qiladi — hech narsa to'silmaydi.
-- =====================================================================
