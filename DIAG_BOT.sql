-- =====================================================================
-- DIAG_BOT.sql — Telegram bot (hodim kassa xabari) ISHLAYAPTIMI?
-- ---------------------------------------------------------------------
-- n8n tomoni TEKSHIRILDI va JONLI:
--   workflow "Aros Provodka - Hodim Notify" (CuIA9H5oW4VrtnJv)
--   active = true, nashr etilgan versiya = joriy versiya, HAR DAQIQA ishlaydi.
--   Zanjir: rpc/hodim_notify_pending -> Aros users.telegram_id -> Telegram
--           -> rpc/hodim_notify_sent (yoki hodim_notify_fail).
--
-- Demak nosozlik (agar bor bo'lsa) DB tomonida. Quyidagi so'rovlar
-- zanjirning QAYSI bo'g'ini uzilganini aniq ko'rsatadi.
--
-- ⚠️ Hech narsa o'zgarmaydi — faqat O'QIYDI.
-- ⚠️ Supabase editori faqat OXIRGI so'rov natijasini ko'rsatadi —
--    BITTALAB RUN qiling va natijasini yuboring.
--
-- 🔴 TUZATILDI (2026-08-26): eski 4- va 5-so'rovlar MAVJUD BO'LMAGAN ustunlarga
--    murojaat qilardi (`holat`, `kassa_nom`, `summa`, `taskfix_user_id`, `urinish`,
--    `xato`) va `ERROR: 42703: column "holat" does not exist` berardi.
--    `hodim_notify` da HOLAT USTUNI YO'Q — holat uch ustundan kelib chiqadi:
--      sent_at is null  + last_error is null            -> navbatda (yangi)
--      sent_at is null  + last_error is not null        -> urinilgan, xato (yana uriniladi)
--      sent_at is null  + attempts >= 30                -> O'LGAN (RPC boshqa bermaydi)
--      sent_at not null + last_error is null            -> YUBORILDI ✅
--      sent_at not null + last_error is not null        -> yopilgan (yozuv o'chirilgan/posted emas)
--    Haqiqiy ustunlar: id, entry_id, line_ref, kassa_id, acc_id, delta, fc,
--    dt_yon, hodisa, qoldiq_oldin, qoldiq_keyin, created_at, sent_at,
--    attempts, last_error   (PROVODKA_HODIM_NOTIFY.sql, 55–71-qatorlar).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0) USTUNLAR — avval SXEMANI ko'ring (boshqa so'rovlar shunga tayanadi).
--    Bu so'rov birinchi RUN qilinsin: ustun nomi o'zgargan bo'lsa
--    quyidagilarni ham moslash kerak (yana taxmin qilinmasin).
-- ---------------------------------------------------------------------
-- select column_name, data_type, is_nullable
--   from information_schema.columns
--  where table_schema = 'public' and table_name = 'hodim_notify'
--  order by ordinal_position;


-- ---------------------------------------------------------------------
-- 1) PROVODKA_HODIM_NOTIFY.sql UMUMAN RUN QILINGANMI?
--    Kutilgan: 2 qator (hodim_notify, hodim_notify_admin).
--    BO'SH chiqsa -> SQL RUN qilinmagan, bot hech qachon xabar
--    yubormagan. Yechim: o'sha faylni RUN qilish (boshqa hech narsa
--    kerak emas, n8n allaqachon tayyor turibdi).
-- ---------------------------------------------------------------------
-- select table_name
--   from information_schema.tables
--  where table_schema = 'public'
--    and table_name in ('hodim_notify', 'hodim_notify_admin')
--  order by table_name;


-- ---------------------------------------------------------------------
-- 2) TRIGGERLAR o'rnidami (xabarni navbatga QO'YADIGAN qism)?
--    Kutilgan: 2 qator, `yoqilgan` = 'O' (origin) bo'lsin.
--    Yo'q bo'lsa -> pul harakati bo'ladi, lekin navbatga hech narsa
--    tushmaydi (jimgina).
-- ---------------------------------------------------------------------
-- select t.tgname, t.tgrelid::regclass as jadval, t.tgenabled as yoqilgan
--   from pg_trigger t
--  where t.tgname in ('trg_hodim_notify_entry_line', 'trg_hodim_notify_entry')
--  order by t.tgname;


-- ---------------------------------------------------------------------
-- 3) RPC lar bormi va n8n ularni CHAQIRA OLADIMI?
--    n8n Supabase kredensiali bilan keladi (odatda service_role).
--    `service_role_ok` false bo'lsa n8n 403 oladi va navbat hech qachon
--    bo'shamaydi.
-- ---------------------------------------------------------------------
-- select p.proname                                                  as funksiya,
--        has_function_privilege('service_role', p.oid, 'execute')   as service_role_ok,
--        has_function_privilege('authenticated', p.oid, 'execute')  as authenticated_ok,
--        has_function_privilege('anon', p.oid, 'execute')           as anon_BULMASIN
--   from pg_proc p
--   join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public'
--    and p.proname in ('hodim_notify_pending', 'hodim_notify_sent', 'hodim_notify_fail')
--  order by p.proname;


-- ---------------------------------------------------------------------
-- 4) NAVBAT HOLATI — eng ma'lumotli so'rov.  🔴 TUZATILDI
--    Holat ustuni yo'q — u sent_at / last_error / attempts dan hisoblanadi.
--
--    Talqin:
--      * jami = 0                 -> triggerlar hech narsa yozmagan (1-2 bandga qara)
--      * hammasi 'navbatda'       -> n8n navbatni o'qiy olmayapti (3-band: grant/kredensial)
--                                    YOKI hammasi 30 soniyadan yangi (7-bandga qara)
--      * 'xato' bor               -> Telegram rad etyapti (5-bandda sabab matni)
--      * 'olgan' bor              -> 30 marta urinilgan, RPC endi bermaydi (5-band)
--      * 'yuborildi' bor          -> BOT ISHLAYAPTI ✅
--      * 'yopilgan' ko'p          -> yozuvlar o'chirilgan/posted emas (xato emas)
-- ---------------------------------------------------------------------
select case
         when n.sent_at is not null and n.last_error is null then 'yuborildi'
         when n.sent_at is not null                          then 'yopilgan'
         when n.attempts >= 30                               then 'olgan'
         when n.last_error is not null                       then 'xato'
         else 'navbatda'
       end                                                     as holat,
       count(*)                                                as soni,
       (min(n.created_at) + interval '5 hours')::timestamp     as eng_eski_uzb,
       (max(n.created_at) + interval '5 hours')::timestamp     as eng_yangi_uzb
  from hodim_notify n
 group by 1
 order by 1;


-- ---------------------------------------------------------------------
-- 5) OXIRGI 20 QATOR + XATO MATNI (nega yuborilmadi).  🔴 TUZATILDI
--    Xato matni `last_error` ustunida (eski so'rovda `xato` deb yozilgan edi).
--    Eng ko'p uchraydigani:
--      "Forbidden: bot was blocked by the user"  -> hodim botga /start bosmagan
--      "chat not found"                          -> telegram_id noto'g'ri
--      "yozuv o'chirilgan yoki posted emas"      -> tozalash (xato EMAS)
-- ---------------------------------------------------------------------
-- select n.id,
--        case
--          when n.sent_at is not null and n.last_error is null then 'yuborildi'
--          when n.sent_at is not null                          then 'yopilgan'
--          when n.attempts >= 30                               then 'olgan'
--          when n.last_error is not null                       then 'xato'
--          else 'navbatda'
--        end                                                as holat,
--        n.hodisa,                                           -- null | 'tahrir' | 'ochirildi'
--        n.delta                                             as summa_som,   -- ishorali
--        n.fc                                                as summa_valyuta,
--        n.dt_yon,
--        a.code || ' ' || a.name                             as kassa,
--        (to_jsonb(a) ->> 'taskfix_user_id')                  as taskfix_user_id,   -- ustun yo'q bo'lsa ham yiqilmaydi
--        n.attempts                                          as urinish,
--        n.last_error                                        as xato,
--        (n.created_at + interval '5 hours')::timestamp      as yaratilgan_uzb,
--        (n.sent_at    + interval '5 hours')::timestamp      as yopilgan_uzb,
--        n.entry_id
--   from hodim_notify n
--   left join accounts a on a.id = n.kassa_id
--  order by n.id desc
--  limit 20;


-- ---------------------------------------------------------------------
-- 6) QABUL QILUVCHI BORMI?
--    (a) hodim kassalarida `taskfix_user_id` to'lganmi — busiz n8n
--        hodimni Aros `users.telegram_id` ga bog'lay olmaydi;
--    (b) admin telegram ro'yxati bo'shmi — bo'sh bo'lsa xabar FAQAT
--        hodimning o'ziga boradi (xato emas, lekin bilib qo'ying).
-- ---------------------------------------------------------------------
-- select count(*)                                              as hodim_kassa_jami,
--        count(*) filter (where (to_jsonb(a) ->> 'taskfix_user_id') is not null) as taskfix_id_bor,
--        count(*) filter (where (to_jsonb(a) ->> 'taskfix_user_id') is null)     as taskfix_id_BOSH
--   from accounts a
--  where a.kassa_turi = 'xarajat' and coalesce(a.is_active, true);

-- select count(*) as admin_telegram_soni from hodim_notify_admin;


-- ---------------------------------------------------------------------
-- 7) NEGA NAVBATDAN OLINMAYAPTI — `hodim_notify_pending` qorovullari.
--    RPC qator berishi uchun UCHALA shart bajarilishi kerak:
--      sent_at is null · attempts < 30 · created_at < now() - 30 soniya
--    Bu so'rov qaysi shart to'sib turganini ko'rsatadi.
--    `hozir_olinadi` = 0, lekin `navbatda` > 0 bo'lsa — sabab shu ustunlarda.
-- ---------------------------------------------------------------------
-- select count(*) filter (where n.sent_at is null)                        as navbatda,
--        count(*) filter (where n.sent_at is null and n.attempts >= 30)   as olgan_30_urinish,
--        count(*) filter (where n.sent_at is null
--                           and n.created_at >= now() - interval '30 seconds') as juda_yangi,
--        count(*) filter (where n.sent_at is null
--                           and n.attempts < 30
--                           and n.created_at < now() - interval '30 seconds') as hozir_olinadi
--   from hodim_notify n;


-- ---------------------------------------------------------------------
-- 8) YETIM QATORLAR — navbatda turibdi, lekin yozuvi o'chirilgan/posted emas.
--    Bular `hodim_notify_pending` ning (a) tozalash bloki tomonidan
--    yopilishi kerak. Ko'p bo'lsa demak RPC umuman chaqirilmayapti.
-- ---------------------------------------------------------------------
-- select count(*) as yetim_navbatda
--   from hodim_notify n
--   join entry e on e.id = n.entry_id
--  where n.sent_at is null
--    and coalesce(n.hodisa, '') <> 'ochirildi'
--    and (e.is_deleted or e.status is distinct from 'posted');
