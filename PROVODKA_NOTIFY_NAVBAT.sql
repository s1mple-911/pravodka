-- =====================================================================
-- PROVODKA_NOTIFY_NAVBAT.sql — yuborilmagan Telegram navbatini yopish
-- ---------------------------------------------------------------------
-- HOLAT (2026-08-26): `hodim_notify` da 110 qator "navbatda"
--   (eng eski 2026-08-25 13:43, eng yangi 2026-08-26 12:29).
--
-- 🔴 DIAGNOSTIKA XULOSASI — navbat TO'G'RI ishlayapti, JO'NATUVCHI ishlamayapti.
--    Dalil: 110 tasining HAMMASI 'navbatda', ya'ni
--      · `last_error` BO'SH  -> n8n `hodim_notify_fail` ni HECH QACHON chaqirmagan;
--      · `attempts` < 30     -> `hodim_notify_pending` ham chaqirilmagan.
--    `hodim_notify_pending` HAR chaqirilganda `attempts = attempts + 1` qiladi
--    (PROVODKA_HODIM_NOTIFY.sql:520). Agar n8n 2 kun har daqiqada ishlaganida
--    `attempts` mingdan oshib, qatorlar 'olgan' bo'lib qolardi. Ular hamon 0 da
--    -> RPC BIR MARTA HAM chaqirilmagan. DB tomoni sog'lom.
--    Jo'natuvchi — n8n workflow "Aros Provodka - Hodim Notify" (CuIA9H5oW4VrtnJv).
--    (Edge Function EMAS: repoda faqat `ai-chat` bor.)
--
-- QAROR (Asilbek, 2026-08-26): eski xabarlar YOPILADI, faqat tuzatilgandan
-- KEYINGI xabarlar yuboriladi.
--
-- 🔴🔴 TARTIB — BUZMANG:
--    1) AVVAL shu fayl (navbat yopiladi)
--    2) KEYIN n8n kredensiali ulanadi
--    Teskarisi bo'lsa: kredensial ulangan zahoti n8n 50/daqiqa tezlikda
--    2 kunlik 110 xabarni hodimlarga yog'dirib yuboradi.
--
-- ⚠️ Bu fayl faqat XABAR navbatiga tegadi. Pul, provodka, qoldiq — TEGILMAYDI.
-- ⚠️ Qatorlar O'CHIRILMAYDI (tarix qoladi) — "yuborilmadi, yopildi" deb belgilanadi.
-- =====================================================================


-- ############ 1-QADAM — yopishdan OLDIN: nima turibdi ############
-- ⚠️ Supabase editori ko'p statementli skriptda FAQAT OXIRGI natijani ko'rsatadi.
--    Bu so'rovni SICHQONCHA BILAN BELGILAB, alohida RUN qiling.
with navbat as (
  select n.id, n.created_at, n.hodisa, n.delta, n.kassa_id
    from hodim_notify n
   where n.sent_at is null
),
adm as (select count(*) as soni from hodim_notify_admin where is_active)
select (select count(*) from navbat)                                      as navbatda,
       (select count(distinct kassa_id) from navbat)                      as nechta_kassa,
       (select soni from adm)                                             as faol_admin,
       -- har qator: hodimning o'ziga + har adminga bittadan
       (select count(*) from navbat) * (1 + (select soni from adm))        as yopilmasa_shuncha_xabar_ketardi,
       (select min(created_at) + interval '5 hours' from navbat)::timestamp as eng_eski_uzb,
       (select max(created_at) + interval '5 hours' from navbat)::timestamp as eng_yangi_uzb;


-- ############ 2-QADAM — NAVBATNI YOPISH  ⚠️ YOZADI ############
-- Hozir navbatda turgan HAMMA qator yopiladi. Bundan keyin yozilgan xabarlar
-- (yangi kirim/chiqim/transfer) navbatga odatdagidek tushadi va n8n tuzatilgach
-- ular yuboriladi.
--
-- 🔴 `sent_at` qo'yiladi (RPC boshqa olmaydi), `last_error` ga SABAB yoziladi.
--    Shuning uchun DIAG_BOT 4-so'rovida ular 'yopilgan' bo'lib ko'rinadi,
--    'yuborildi' EMAS — soxta statistika bo'lmaydi.
-- 🔴 `hodim_notify_sent()` RPC ISHLATILMADI: u `last_error = null` qiladi,
--    ya'ni yuborilmagan xabarlarni "yuborildi" deb ko'rsatib qo'yardi.
update hodim_notify
   set sent_at    = now(),
       last_error = 'navbat yopildi 2026-08-26: jonatuvchi (n8n) ishlamagan, eski xabar yuborilmadi'
 where sent_at is null;


-- ############ 3-QADAM — TASDIQLASH ############
select case
         when n.sent_at is not null and n.last_error is null then 'yuborildi'
         when n.sent_at is not null                          then 'yopilgan'
         when n.attempts >= 30                               then 'olgan'
         when n.last_error is not null                       then 'xato'
         else 'navbatda'
       end                              as holat,
       count(*)                         as soni,
       max(n.attempts)                  as eng_kop_urinish,
       (max(n.created_at) + interval '5 hours')::timestamp as eng_yangi_uzb
  from hodim_notify n
 group by 1
 order by 1;
--
-- Kutilgan: 'navbatda' = 0 (yoki shu daqiqada yozilgan bir-ikkita yangi qator),
--           'yopilgan' = 110. Shundan keyin n8n kredensialini ulang.


-- ---------------------------------------------------------------------
-- 4-QADAM — n8n TUZATILGANDAN KEYIN (1-2 daqiqa o'tib) 3-QADAMNI QAYTA RUN QILING
-- ---------------------------------------------------------------------
-- TALQIN:
--   `eng_kop_urinish` hamon 0 va yangi qatorlar 'navbatda' bo'lib to'planyapti
--       -> n8n HAMON RPC ni chaqirmayapti (kredensial ulanmagan / workflow
--          ishga tushmayapti). Bu YAGONA ishonchli dalil: attempts ko'tarilishi.
--   'xato' paydo bo'ldi -> RPC chaqirilyapti ✅, Telegram rad etyapti:
--       "bot was blocked by the user"  -> hodim botga /start bosmagan
--       "chat not found"               -> telegram_id noto'g'ri
--       "qabul qiluvchi topilmadi"     -> accounts.taskfix_user_id bo'sh
--                                         (DIAG_BOT 6-so'rov) yoki admin ro'yxati bo'sh
--   'yuborildi' paydo bo'ldi -> BOT ISHLAYAPTI ✅
--
-- 🔴 ESLATMA: navbat jimgina to'planishi — aynan shu hodisaning takrori.
--    Haftada bir marta DIAG_BOT 4-so'rovini RUN qilib turing; 'navbatda' soni
--    o'nlab bo'lib o'sib borsa jo'natuvchi yana uzilgan degani.


-- ---------------------------------------------------------------------
-- KERAK BO'LMAGAN VARIANT (yozib qo'yildi) — hammasini YUBORISH
-- ---------------------------------------------------------------------
-- Bu fayl RUN qilinmasa, n8n tuzalgach navbat o'z-o'zidan bo'shaydi va
-- 2 kunlik xabarlar birdan ketadi. Asilbek buni ATAYLAB rad etdi.
--
-- Agar `attempts >= 30` bo'lib qotib qolgan qatorlar paydo bo'lsa (n8n bir necha
-- marta yiqilsa) — hisoblagichni tiklash:
-- update hodim_notify set attempts = 0
--  where sent_at is null and attempts >= 30;
