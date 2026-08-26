-- =====================================================================
-- DIAG_NOTIFY_TRIGGER.sql — "transfer qildim, xabar kelmadi"
-- ---------------------------------------------------------------------
-- YANGI MA'LUMOT (2026-08-26): workflow qo'lda ishga tushirilganda
-- `Xabar Bormi` (IF) FALSE qaytaryapti.
--
-- 🔴 BU MUHIM: `Navbat` node MUVAFFAQIYATLI javob qaytargan (aks holda
--    bajarilish o'sha yerda XATO bilan to'xtardi — unda `onError` yo'q).
--    Ya'ni **Supabase kredensiali ISHLAYAPTI**, RPC chaqirilyapti va
--    `items: []` qaytyapti. Muammo kredensialda EMAS.
--
-- Uch ehtimol qoldi — quyidagi so'rovlar qaysi biri ekanini aniqlaydi:
--
--  (1) 🔴 KASSA HODIM KASSASI EMAS.
--      Trigger `hodim_kassa_root(account_id)` ni chaqiradi va u NULL
--      qaytarsa **hech qanday navbat qatori yozilmaydi** (jimgina).
--      NULL qaytadi, agar hisobning ildizi `kassa_turi <> 'xarajat'`,
--      ya'ni markaziy (5011...), filial (52xx) yoki boshqa kassa bo'lsa.
--      Bu xususiyat ATAYLAB faqat HODIM xarajat kassalari (5400 ostidagi
--      5401+) uchun. Markaziy kassangizga transfer qilsangiz xabar
--      YOZILMAYDI ham, YUBORILMAYDI ham.
--
--  (2) 30 SONIYALIK KECHIKISH.
--      `hodim_notify_pending` shartlaridan biri:
--         created_at < now() - interval '30 seconds'
--      Transfer qilib DARROV workflow'ni qo'lda RUN qilsangiz qator
--      "juda yangi" bo'lib tanlanmaydi -> items bo'sh -> IF false.
--      30 soniya kutib qayta RUN qiling.
--
--  (3) NAVBAT ALLAQACHON YOPILGAN.
--      `PROVODKA_NOTIFY_NAVBAT.sql` RUN qilingan bo'lsa 110 qator
--      yopilgan va navbat BO'SH — bunda `items: []` TO'G'RI javob.
--
-- ⚠️ Hech narsa o'zgarmaydi — faqat O'QIYDI.
-- ⚠️ Supabase editori faqat OXIRGI natijani ko'rsatadi — BITTALAB RUN qiling.
-- =====================================================================


-- ############ 1-SO'ROV — ENG MUHIMI: oxirgi 1 soatdagi yozuvlar ############
-- Har satr uchun: hisob hodim kassasimi va navbatga qator tushdimi.
-- Siz qilgan transfer shu ro'yxatda bo'lishi kerak.
select (e.created_at + interval '5 hours')::timestamp        as yozilgan_uzb,
       e.description,
       e.status,
       e.is_deleted,
       a.code,
       a.name,
       a.kassa_turi,
       a.pul_turi,
       coalesce(a.currency, 'UZS')                           as valyuta,
       l.debit,
       l.credit,
       hodim_kassa_root(l.account_id)                        as hodim_ildiz,
       case when hodim_kassa_root(l.account_id) is null
            then 'HODIM KASSASI EMAS -> xabar UMUMAN yozilmaydi'
            else 'hodim kassasi -> xabar yozilishi kerak'
       end                                                   as tahlil,
       (select count(*) from hodim_notify n where n.entry_id = e.id) as navbat_qatori,
       e.id                                                  as entry_id
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts   a on a.id = l.account_id
 where e.created_at > now() - interval '60 minutes'
 order by e.created_at desc, l.debit desc;
--
-- QANDAY O'QISH:
--   `tahlil` = "HODIM KASSASI EMAS"  -> (1)-ehtimol. Xabar tizimi FAQAT hodim
--        xarajat kassalari uchun. Sizning kassangiz markaziy/filial bo'lsa
--        bu XATO EMAS — shunday mo'ljallangan. Sinash uchun HODIM kassasiga
--        (5400 ostidagi 5401+, `kassa_turi='xarajat'`) transfer qiling.
--   `tahlil` = "hodim kassasi" LEKIN `navbat_qatori` = 0
--        -> trigger ishlamayapti. 3-so'rovga o'ting.
--   `navbat_qatori` >= 1 -> trigger ISHLADI ✅, muammo faqat jo'natishda.


-- ############ 2-SO'ROV — navbatning HOZIRGI holati ############
-- select case
--          when n.sent_at is not null and n.last_error is null then 'yuborildi'
--          when n.sent_at is not null                          then 'yopilgan'
--          when n.attempts >= 30                               then 'olgan'
--          when n.last_error is not null                       then 'xato'
--          else 'navbatda'
--        end                                                   as holat,
--        count(*)                                              as soni,
--        max(n.attempts)                                       as eng_kop_urinish,
--        (max(n.created_at) + interval '5 hours')::timestamp    as eng_yangi_uzb
--   from hodim_notify n
--  group by 1 order by 1;
--
--   'yopilgan' = 110 chiqsa -> PROVODKA_NOTIFY_NAVBAT.sql RUN qilingan,
--        navbat bo'sh, `items: []` TO'G'RI javob ((3)-ehtimol).
--   'navbatda' = 110 chiqsa -> navbat hamon to'la, LEKIN RPC bo'sh qaytaryapti
--        -> 4-so'rovga o'ting (qorovullardan qaysi biri to'syapti).
--   `eng_kop_urinish` > 0 -> n8n RPC ni CHAQIRGAN ✅ (kredensial ishlaydi).


-- ############ 3-SO'ROV — triggerlar joyidami ############
-- select t.tgname                                   as trigger_nomi,
--        t.tgrelid::regclass                        as jadval,
--        case t.tgenabled when 'O' then 'yoqilgan'
--                         when 'D' then 'O''CHIRILGAN'
--                         else t.tgenabled::text end as holat
--   from pg_trigger t
--  where t.tgname in ('trg_hodim_notify_entry_line', 'trg_hodim_notify_entry')
--  order by t.tgname;
-- Ikkalasi ham 'yoqilgan' bo'lishi SHART. Yo'q bo'lsa PROVODKA_HODIM_NOTIFY.sql
-- RUN qilinmagan yoki trigger o'chirilgan.


-- ############ 4-SO'ROV — navbatda bor, lekin RPC bermayapti ############
-- `hodim_notify_pending` qatorni berishi uchun BESH shart ham bajarilishi kerak.
-- Bu so'rov qaysi biri to'sib turganini ko'rsatadi.
-- select count(*) filter (where n.sent_at is null)                     as navbatda,
--        count(*) filter (where n.sent_at is null
--                           and n.attempts >= 30)                      as tosildi_30_urinish,
--        count(*) filter (where n.sent_at is null
--                           and n.created_at >= now() - interval '30 seconds')
--                                                                      as tosildi_juda_yangi,
--        count(*) filter (where n.sent_at is null
--                           and e.status <> 'posted')                   as tosildi_posted_emas,
--        count(*) filter (where n.sent_at is null
--                           and e.is_deleted
--                           and coalesce(n.hodisa,'') <> 'ochirildi')   as tosildi_ochirilgan,
--        count(*) filter (where n.sent_at is null
--                           and n.attempts < 30
--                           and n.created_at < now() - interval '30 seconds'
--                           and e.status = 'posted'
--                           and (e.is_deleted = false or n.hodisa = 'ochirildi'))
--                                                                      as HOZIR_OLINADI
--   from hodim_notify n
--   join entry e on e.id = n.entry_id;
--
-- `HOZIR_OLINADI` > 0 bo'lsa-yu n8n bo'sh olsa -> RPC boshqa loyihaga/bazaga
-- ketyapti (kredensial URL'ini tekshiring) yoki `p_limit` noto'g'ri.
-- `HOZIR_OLINADI` = 0 -> yuqoridagi `tosildi_*` ustunlaridan qaysi biri > 0,
-- sabab o'sha.


-- ############ 5-SO'ROV — hodim kassalari ro'yxati (sinov uchun) ############
-- Xabar tizimi FAQAT shu kassalar uchun ishlaydi. Sinashda shulardan birini tanlang.
-- select a.code, a.name, a.subtitle,
--        (to_jsonb(a) ->> 'taskfix_user_id')  as taskfix_user_id,
--        case when (to_jsonb(a) ->> 'taskfix_user_id') is null
--             then 'TELEGRAM ID TOPILMAYDI -> xabar faqat adminlarga ketadi'
--             else 'ok' end                   as ogoh
--   from accounts a
--  where a.kassa_turi = 'xarajat'
--    and coalesce(a.is_active, true)
--  order by a.code;
