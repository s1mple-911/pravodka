-- =====================================================================
-- DIAG_SOROV_CHEGARA.sql — "Pul so'rash" modali doim "yetarli" deyapti
-- ---------------------------------------------------------------------
-- HODISA (2026-08-26):
--   Holat 1 — 36 kassasi bor hodim BO'SH (0 so'mli) kassani tanlab so'ramoqchi
--             bo'lsa ham "yetarli pul bor" yo'riqnomasi chiqadi.
--   Holat 2 — 1 kassasi bor, "500 dan kam" puli bor hodimda ham "yetarli".
--
-- IKKI ALOHIDA SABAB BOR:
--   (1) KLIENT — `srvBalKam()` HAMMA kassa yig'indisini olardi, tanlangan
--       kassani emas. `hodim-dev.html` da TUZATILDI (endi faqat tanlangan
--       kassa). Bu Holat 1 ni yopadi. SQL kerak emas.
--   (2) CHEGARA QIYMATI — quyidagi so'rovlar shuni tekshiradi. Holat 2
--       ehtimol shundan: chegara 500 (SO'M) bo'lib turgan bo'lsa,
--       500 so'm ~ 4 tsent, ya'ni HECH KIMDA undan kam bo'lmaydi va
--       top-up shoxi amalda HECH QACHON ochilmaydi.
--
-- ⚠️ 1–3 so'rovlar faqat O'QIYDI. 4-so'rov YOZADI — u ataylab izohda,
--    qiymatni ko'rib chiqib, ongli ravishda RUN qiling.
-- =====================================================================


-- ############ 1-SO'ROV — hozirgi chegara nima ############
select coalesce(c.val, '(qator YO''Q -> funksiya 500 qaytaradi)') as saqlangan_qiymat,
       sorov_topup_chegara()                                     as funksiya_qaytargani,
       c.updated_by,
       (c.updated_at + interval '5 hours')::timestamp             as ozgartirilgan_uzb
  from (select 1) x
  left join provodka_config c on c.key = 'sorov_topup_chegara';
--
-- QANDAY O'QISH:
--   funksiya_qaytargani = 500          -> chegara 500 SO'M. Amalda top-up
--                                         HECH QACHON ochilmaydi (hamma hodimda
--                                         500 so'mdan ko'p bor). Holat 2 shundan.
--                                         Mo'ljal 500 000 bo'lsa -> 4-so'rov.
--   funksiya_qaytargani = 0            -> top-up ATAYLAB o'chirilgan
--                                         (0 dan kam bo'lolmaydi -> doim yo'riqnoma).
--   funksiya_qaytargani = 500000       -> qiymat to'g'ri; Holat 2 boshqa sababdan
--                                         (2-so'rovga o'ting).
--   XATO: function does not exist      -> PROVODKA_SOROV_TOPUP.sql RUN qilinmagan.
--                                         Klient ZAXIRA 500 ni ishlatadi — natija bir xil.


-- ############ 2-SO'ROV — hodimning HAQIQIY kassa qoldig'i ############
-- Shikoyat qilgan hodimning kassasi qaysi chegaradan qaysi tomonda ekanini
-- ko'rsatadi. Ildiz kassa + `parent_id` bo'yicha bolalari (Naqd/Click/Payme/valyuta).
--
-- ⚠️ IKKI FARQ — klient bundan KO'PROQ qo'shadi, ya'ni bu so'rov KAM ko'rsatishi mumkin:
--    (1) klient REKURSIV yuradi (`subChildren` -> nevaralar ham: "Naqd · USD");
--    (2) klient NOM orqali bog'langan eski hisoblarni ham qo'shadi (`parent_id` BO'SH,
--        masalan `5351 "Ism · Naqd"` -> ildiz `5405`).
--    Shuning uchun pastda ILDIZ kassa kodini yozing (bola kodini emas). Ildizni bilmasangiz
--    avval shuni RUN qiling:
--      select id, code, name, subtitle, parent_id, kassa_turi from accounts
--       where kassa_turi = 'xarajat' and name ilike '%ISM%' order by code;
--
-- 🔴 `5405` o'rniga tekshirilayotgan ILDIZ kassaning kodini qo'ying.
-- with oila as (
--   select a.id as ildiz, a.code, a.name, a.subtitle,
--          (select sum(b.uzs)
--             from v_hisob_bal b
--            where b.account_id = a.id
--               or b.account_id in (select ch.id from accounts ch where ch.parent_id = a.id)
--          ) as jami
--     from accounts a
--    where a.code = '5405'
-- )
-- select o.code, o.name, o.subtitle,
--        o.jami                                as kassa_jami_som,
--        sorov_topup_chegara()                 as chegara,
--        case
--          -- 🔴 NULL = qoldiq YO'Q (birorta satr yozilmagan). Klient bu holatda ham
--          --    TOP-UP ochadi ("sizda pul bor" deb yolg'on aytmaslik qoidasi),
--          --    shuning uchun bu shox `else` ga tushib qolmasligi SHART.
--          when o.jami is null                        then 'TOP-UP (qoldiq noma''lum)'
--          when o.jami < sorov_topup_chegara()        then 'TOP-UP chiqishi kerak'
--          else 'yo''riqnoma chiqadi'
--        end                                   as kutilgan_natija
--   from oila o;


-- ############ 3-SO'ROV — hodim nechta kassa KO'RADI ############
-- Holat 1 ning tasdig'i: `kassa_scope='all'` bo'lgan (yoki umuman qatori yo'q)
-- hodim HAMMA hodim kassasini ko'radi — eski klient kodi ularning HAMMASINI
-- qo'shib "yetarli" derdi. Qatori yo'q bo'lsa DEFAULT = 'all'.
-- 🔴 user_id ni 1-so'rovdagi/`profiles` dagi qiymat bilan almashtiring.
-- select p.user_id,
--        p.kassa_scope,
--        coalesce(array_length(p.op_kassa_ids, 1), 0)   as op_kassa_soni,
--        coalesce(array_length(p.view_kassa_ids, 1), 0) as view_kassa_soni
--   from user_perms p
--  where p.user_id = 'BU_YERGA_USER_ID';
--
-- select count(*) as jami_hodim_kassasi
--   from accounts
--  where kassa_turi = 'xarajat' and coalesce(is_active, true);
-- `kassa_scope='all'` + jami_hodim_kassasi = 36 -> Holat 1 aynan shu.


-- ############ 4-SO'ROV — CHEGARANI O'ZGARTIRISH  ⚠️ YOZADI ############
-- 🔴 `set_sorov_topup_chegara()` SQL EDITORIDAN ISHLAMAYDI: editorda so'rov
--    `postgres` roli bilan JWT'siz ketadi -> auth.uid() null -> is_admin()
--    false -> 42501 (PROVODKA_SOROV_TOPUP.sql 1.3 dagi ogohlantirish).
--    Shuning uchun editorda TO'G'RIDAN-TO'G'RI provodka_config ga yoziladi.
--
-- 🔴 Qiymat SO'MDA. 500 000 so'm uchun 500000 yozing (500 EMAS).
--    0 = top-up butunlay o'chadi (faqat yo'riqnoma).
--    Deploy KERAK EMAS — klient uni har ochilishda bazadan o'qiydi.
--
-- insert into provodka_config(key, val, updated_by, updated_at)
-- values ('sorov_topup_chegara', '500000', 'asilbek (sql editor)', now())
-- on conflict (key) do update
--   set val = excluded.val, updated_by = excluded.updated_by,
--       updated_at = excluded.updated_at;
--
-- Keyin 1-so'rovni qayta RUN qilib tasdiqlang va brauzerda sahifani yangilang.
