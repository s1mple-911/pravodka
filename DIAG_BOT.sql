-- =====================================================================
-- DIAG_BOT.sql — Telegram bot (hodim kassa xabari) ISHLAYAPTIMI?
-- ---------------------------------------------------------------------
-- n8n tomoni TEKSHIRILDI va JONLI:
--   workflow "Aros Provodka - Hodim Notify" (CuIA9H5oW4VrtnJv)
--   active = true, nashr etilgan versiya = joriy versiya, HAR DAQIQA ishlaydi.
--   Zanjir: rpc/hodim_notify_pending -> Aros users.telegram_id -> Telegram
--           -> rpc/hodim_notify_sent (yoki hodim_notify_fail).
--
-- Demak nosozlik (agar bor bo'lsa) DB tomonida. Quyidagi 6 so'rov
-- zanjirning QAYSI bo'g'ini uzilganini aniq ko'rsatadi.
--
-- ⚠️ Hech narsa o'zgarmaydi — faqat O'QIYDI.
-- ⚠️ Supabase editori faqat OXIRGI so'rov natijasini ko'rsatadi —
--    BITTALAB RUN qiling va natijasini yuboring.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) PROVODKA_HODIM_NOTIFY.sql UMUMAN RUN QILINGANMI?
--    Kutilgan: 2 qator (hodim_notify, hodim_notify_admin).
--    BO'SH chiqsa -> SQL RUN qilinmagan, bot hech qachon xabar
--    yubormagan. Yechim: o'sha faylni RUN qilish (boshqa hech narsa
--    kerak emas, n8n allaqachon tayyor turibdi).
-- ---------------------------------------------------------------------
select table_name
  from information_schema.tables
 where table_schema = 'public'
   and table_name in ('hodim_notify', 'hodim_notify_admin')
 order by table_name;


-- ---------------------------------------------------------------------
-- 2) TRIGGERLAR o'rnidami (xabarni navbatga QO'YADIGAN qism)?
--    Kutilgan: 2 qator.
--    Yo'q bo'lsa -> pul harakati bo'ladi, lekin navbatga hech narsa
--    tushmaydi (jimgina). Bu 1-band bilan birga tekshiriladi.
-- ---------------------------------------------------------------------
select t.tgname, t.tgrelid::regclass as jadval, t.tgenabled as yoqilgan
  from pg_trigger t
 where t.tgname in ('trg_hodim_notify_entry_line', 'trg_hodim_notify_entry')
 order by t.tgname;


-- ---------------------------------------------------------------------
-- 3) RPC lar bormi va n8n ularni CHAQIRA OLADIMI?
--    n8n Supabase kredensiali bilan keladi (odatda service_role).
--    `service_role_ok` false bo'lsa n8n 403 oladi va navbat hech qachon
--    bo'shamaydi.
-- ---------------------------------------------------------------------
select p.proname                                                        as funksiya,
       has_function_privilege('service_role', p.oid, 'execute')         as service_role_ok,
       has_function_privilege('authenticated', p.oid, 'execute')        as authenticated_ok,
       has_function_privilege('anon', p.oid, 'execute')                 as anon_BULMASIN
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('hodim_notify_pending', 'hodim_notify_sent', 'hodim_notify_fail')
 order by p.proname;


-- ---------------------------------------------------------------------
-- 4) NAVBAT HOLATI — eng ma'lumotli so'rov.
--    holat: 'pending' = yuborilmagan · 'sent' = yuborilgan · 'fail' = xato.
--
--    Talqin:
--      * jami = 0            -> triggerlar hech narsa yozmagan (1-2 bandga qara)
--      * hammasi 'pending'   -> n8n navbatni o'qiy olmayapti (3-band: grant/kredensial)
--      * 'fail' bor          -> Telegram rad etyapti (5-bandda sabab matni)
--      * 'sent' bor          -> BOT ISHLAYAPTI ✅
-- ---------------------------------------------------------------------
select holat, count(*) as soni, min(created_at) as eng_eski, max(created_at) as eng_yangi
  from hodim_notify
 group by holat
 order by holat;


-- ---------------------------------------------------------------------
-- 5) OXIRGI 20 QATOR + XATO MATNI (nega yuborilmadi).
--    `xato` ustunida odatda Telegram javobi turadi. Eng ko'p uchraydigani:
--    "Forbidden: bot was blocked by the user" yoki "chat not found"
--    -> hodim botga /start bosmagan yoki telegram_id noto'g'ri.
-- ---------------------------------------------------------------------
select id, holat, hodisa, kassa_nom, summa, taskfix_user_id,
       urinish, xato, created_at
  from hodim_notify
 order by id desc
 limit 20;


-- ---------------------------------------------------------------------
-- 6) QABUL QILUVCHI BORMI?
--    (a) hodim kassalarida `taskfix_user_id` to'lganmi — busiz n8n
--        hodimni Aros `users.telegram_id` ga bog'lay olmaydi;
--    (b) admin telegram ro'yxati bo'shmi — bo'sh bo'lsa xabar FAQAT
--        hodimning o'ziga boradi (xato emas, lekin bilib qo'ying).
-- ---------------------------------------------------------------------
select count(*)                                              as hodim_kassa_jami,
       count(*) filter (where taskfix_user_id is not null)    as taskfix_id_bor,
       count(*) filter (where taskfix_user_id is null)        as taskfix_id_BOSH
  from accounts
 where kassa_turi = 'xarajat' and coalesce(is_active, true);

select count(*) as admin_telegram_soni from hodim_notify_admin;
