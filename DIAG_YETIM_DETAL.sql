-- =====================================================================
-- DIAG_YETIM_DETAL.sql — yetim sarlavhalarning BOR BO'LGAN hamma detali
-- ---------------------------------------------------------------------
-- 🔴 TOZALASH YO'Q. Bu fayl faqat O'QIYDI.
--
-- ⚠️ HALOL OGOHLANTIRISH: yo'qolgan ma'lumot (qaysi hisob, qancha summa)
--    `entry_line` da bo'lishi kerak edi — u BAZAGA YETIB BORMAGAN.
--    Ya'ni summa va hisoblarni TIKLAB BO'LMAYDI: ular faqat o'sha
--    lahzada brauzerda bo'lgan. Quyida sarlavhada saqlangan HAMMA
--    narsa chiqariladi — bundan ortig'i mavjud emas.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) TO'LIQ QATOR — hamma ustun, hech narsa yashirilmagan.
--    `to_jsonb(e)` bilan: kelajakda ustun qo'shilsa ham o'zi chiqadi.
-- ---------------------------------------------------------------------
select e.id,
       e.created_at,
       jsonb_pretty(to_jsonb(e)) as toliq_qator
  from entry e
 where not exists (select 1 from entry_line l where l.entry_id = e.id)
   and coalesce(e.is_deleted, false) = false
 order by e.created_at desc;


-- ---------------------------------------------------------------------
-- 2) MANBA BARMOQ IZI — qaysi sahifadan kelgan?
--    provodka.html:542  -> filial_ids '{}' VA ext_ref null VA
--                          davr/kommunal/fc_rate BO'SH (u ularni yubormaydi)
--    hodim.html:1475    -> filial_ids to'lgan BO'LISHI mumkin, davr/kommunal bo'lishi mumkin
--    professional.html  -> odatda ko'p satrli, description to'lgan
-- ---------------------------------------------------------------------
select e.id, e.created_at,
       coalesce(array_length(e.filial_ids, 1), 0)      as filial_soni,
       (e.ext_ref is not null)                          as tokenli,
       (to_jsonb(e) ->> 'davr_start')                   as davr_start,
       (to_jsonb(e) ->> 'kommunal_turi')                as kommunal,
       (to_jsonb(e) ->> 'fc_rate')                      as fc_rate,
       (e.description is not null)                      as izoh_bor,
       case
         when coalesce(array_length(e.filial_ids,1),0) = 0
          and e.ext_ref is null
          and (to_jsonb(e) ->> 'davr_start') is null
          and (to_jsonb(e) ->> 'kommunal_turi') is null
          and (to_jsonb(e) ->> 'fc_rate') is null      then 'provodka.html (ehtimol)'
         when e.ext_ref is not null                     then 'hodim-dev.html (tokenli)'
         else 'aniqlanmadi'
       end                                              as manba_taxmin
  from entry e
 where not exists (select 1 from entry_line l where l.entry_id = e.id)
   and coalesce(e.is_deleted, false) = false
 order by e.created_at desc;


-- ---------------------------------------------------------------------
-- 3) O'SHA DAQIQADA MUVAFFAQIYATLI nima yozilgan?
--    Yetim yozuvdan oldingi/keyingi 10 daqiqadagi TO'LIQ yozuvlar —
--    foydalanuvchi nima qilmoqchi bo'lganini shundan taxmin qilish mumkin
--    (masalan keyin qo'lda qayta kiritган bo'lsa — o'sha yozuv shu yerda).
-- ---------------------------------------------------------------------
select y.id                                   as yetim_id,
       y.created_at                           as yetim_vaqt,
       t.id                                   as toliq_id,
       t.created_at                           as toliq_vaqt,
       t.description                          as toliq_izoh,
       (select sum(l.debit) from entry_line l where l.entry_id = t.id) as toliq_summa,
       (select string_agg(a.code || ' ' || a.name, ' / ' order by l.debit desc)
          from entry_line l join accounts a on a.id = l.account_id
         where l.entry_id = t.id)              as toliq_hisoblar
  from entry y
  join entry t
    on t.id <> y.id
   and exists (select 1 from entry_line l where l.entry_id = t.id)
   and t.created_at between y.created_at - interval '10 minutes'
                        and y.created_at + interval '10 minutes'
 where not exists (select 1 from entry_line l where l.entry_id = y.id)
   and coalesce(y.is_deleted, false) = false
 order by y.created_at desc, t.created_at;


-- ---------------------------------------------------------------------
-- 4) entry_history da iz bormi (tahrir/o'chirish nusxasi)?
--    Odatda BO'SH chiqadi — bu yozuvlar tahrirlanmagan. Tekshiramiz.
-- ---------------------------------------------------------------------
select h.*
  from entry_history h
 where h.entry_id in (
         select e.id from entry e
          where not exists (select 1 from entry_line l where l.entry_id = e.id)
            and coalesce(e.is_deleted, false) = false)
 order by h.id desc;


-- ---------------------------------------------------------------------
-- 5) Telegram navbatida iz bormi?
--    `trg_hodim_notify_entry_line` satrga bog'langan — satr yo'q, demak
--    xabar ham yo'q. Baribir tekshiramiz (jadval bo'lmasa xato beradi —
--    u holda PROVODKA_HODIM_NOTIFY.sql RUN qilinmagan degani).
-- ---------------------------------------------------------------------
select n.*
  from hodim_notify n
 where n.entry_id in (
         select e.id from entry e
          where not exists (select 1 from entry_line l where l.entry_id = e.id)
            and coalesce(e.is_deleted, false) = false)
 order by n.id desc;
