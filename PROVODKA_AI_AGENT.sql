-- =====================================================================
--  ⚠️⚠️  SUPABASE SQL EDITOR — QANDAY RUN QILINADI (avval SHUNI o'qing)
-- ---------------------------------------------------------------------
--   1) Har bo'lak ⬇⬇⬇ va ⬆⬆⬆ belgilari orasida. AYNAN o'sha oraliqni
--      belgilab RUN qiling. Tartib bilan: 0 → 1 → 2 → 3.
--      Butun faylni birdaniga RUN qilsa ham bo'ladi — bu fayl PUL
--      HARAKATI QILMAYDI va jadval yaratmaydi.
--
--   2) 2-BO'LIM da anonim `do` bloki bor. U ATAYLAB NOMLANGAN
--      dollar-quote bilan yozilgan (tekshir tegi bilan), chunki nomsiz
--      variantni Supabase SQL Editor ko'rib blokni ikkiga bo'lib
--      yuborardi. Shu sababdan IZOHLARDA dollar belgisi umuman yo'q —
--      bu faylga izoh qo'shsangiz ham dollar yozmang.
--
--   3) Bo'lak diapazonlari:
--        0-BO'LIM — old shart tekshiruvi (HECH NARSA YOZMAYDI)
--        1-BO'LIM — perm_pages() ga 'ai' kaliti qo'shiladi (15 → 16)
--        2-BO'LIM — TEKSHIRUV (do bloki, nomuvofiqlikda raise exception)
--        3-BO'LIM — notify pgrst (PostgREST sxema keshini yangilash)
--        4-BO'LIM — ROLLBACK (izohda, qo'lda ishlatiladi)
--
--   4) 🔴 SQL ni ASILBEK o'zi RUN qiladi. Agent bajarmaydi.
-- =====================================================================

-- =====================================================================
--  PROVODKA_AI_AGENT.sql
--  AI yordamchi sahifasi — 1-BOSQICH (faqat sahifa ruxsati)
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  #####  NIMA QILADI  #################################################
--
--  `ai-dev.html` — Provodka ichidagi AI chat sahifasi. Bu fayl unga
--  ruxsat kalitini beradi: `perm_pages()` ro'yxatiga 'ai' qo'shiladi,
--  shundan keyin admin `admin-dev.html` orqali har foydalanuvchiga
--  sahifani alohida ochishi/yopishi mumkin bo'ladi.
--
--  #####  1-BOSQICHDA BOSHQA HECH NARSA YO'Q  ##########################
--
--  Yangi jadval YO'Q, yangi RPC YO'Q, Claude API YO'Q. Chat tarixi
--  klientda faqat XOTIRADA turadi (sahifa yangilansa o'chadi).
--  2-bosqichda Edge Function (Claude API proxy, kalit server tomonda)
--  va — agar kerak bo'lsa — chat tarixi jadvali RLS bilan qo'shiladi.
--  Shu sababli bu faylda `entry` / `entry_line` ga hech qanday aloqa
--  yo'q: balans, P&L, cashflow raqamlari O'ZGARMAYDI.
--
--  #####  ADDITIVE  ####################################################
--
--  Yagona o'zgarish — `perm_pages()`: `create or replace`, imzo
--  O'ZGARMAYDI (`perm_pages() returns text[]`), eski 15 kalit AYNAN
--  o'sha TARTIBDA qoladi, oxiriga 'ai' qo'shiladi. Hech bir kalit olib
--  tashlanmaydi, hech qanday ustun/funksiya o'chirilmaydi.
--
--  🔴 KLIENT TOMONI — BUSIZ ISHLAMAYDI:
--     (a) `perms-dev.js` (va promote'dan keyin `perms.js`) dagi `PAGES`
--         massiviga 'ai' qo'shilsin — aynan shu ro'yxat bo'lsin;
--     (b) `admin-dev.html` dagi `PVS_PAGES` ro'yxatiga ham 'ai'
--         qo'shilsin (admin checkbox'i shundan chiqadi).
--     Aks holda `admin_set_provodka_perms` 'ai' kalitini "noma'lum" deb
--     JIMGINA tashlab yuboradi va admin sahifani hech kimga bera olmaydi.
--
--  ⚠️ TARTIB OGOHLANTIRISHI: `PROVODKA_PERMS.sql` yoki
--     `PROVODKA_PAGES_EMPTY.sql` yoki `PROVODKA_YUK_TANNARX.sql` (3-BO'LIM)
--     KEYIN RUN qilinsa ular `perm_pages()` ni eski ro'yxatga qaytaradi
--     va 'ai' YO'QOLADI. O'shanda bu faylning 1-BO'LIMini QAYTA RUN qiling
--     (2-BO'LIM tekshiruvi buni darrov aytadi).
--
--  ⚠️ 'ai' kaliti klientdagi sahifa kaliti bilan bir xil: `perms-dev.js`
--     `page()` funksiyasi fayl nomidan `.html` va `-dev` qo'shimchasini
--     kesadi, ya'ni `ai-dev.html` → 'ai' (`ai-dev` EMAS).
--
--  TALAB: PROVODKA_PERMS.sql (perm_pages, user_perms) RUN qilingan bo'lsin.
-- =====================================================================


-- #####################################################################
--  0-BO'LIM — OLD SHART TEKSHIRUVI.  HECH NARSA YOZMAYDI.
-- #####################################################################

-- ⬇⬇⬇  0-BO'LIM  ⬇⬇⬇
-- 0.1 Ruxsat tizimi o'rnatilganmi
select 'perm_pages()' as tekshiruv,
       case when to_regprocedure('public.perm_pages()') is not null
            then '✅ BOR — 1-BO''LIM unga ai qo''shadi'
            else '❌ YO''Q — avval PROVODKA_PERMS.sql ni RUN qiling' end as natija
union all
select 'user_perms jadvali',
       case when to_regclass('public.user_perms') is not null
            then '✅ BOR'
            else '❌ YO''Q — avval PROVODKA_PERMS.sql ni RUN qiling' end
union all
select 'my_perms()',
       case when to_regprocedure('public.my_perms()') is not null
            then '✅ BOR — klient shundan o''qiydi'
            else '⚠️ YO''Q — perms-dev.js hamma sahifani ochiq deb ishlaydi' end
union all
select 'admin_set_provodka_perms(jsonb)',
       case when to_regprocedure('public.admin_set_provodka_perms(jsonb)') is not null
            then '✅ BOR — admin-dev shu orqali yozadi'
            else '⚠️ YO''Q — admin panelidan ruxsat berib bo''lmaydi' end;

-- 0.2 Hozirgi holat: nechta kalit bor va 'ai' allaqachon qo'shilganmi
select coalesce(array_length(perm_pages(), 1), 0) as hozirgi_kalit_soni,
       ('ai' = any(perm_pages()))                 as ai_bormi,
       array_to_string(perm_pages(), ', ')        as royxat;
-- ⬆⬆⬆  0-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  1-BO'LIM — perm_pages() ga 'ai' (15 → 16 kalit)
-- #####################################################################
--  ADDITIVE: eski 15 kalit AYNAN o'sha tartibda qoladi, oxiriga 'ai'
--  qo'shiladi. Imzo o'zgarmaydi — mavjud chaqiruvchilar (perm_has_page,
--  admin_set_provodka_perms, yuk_tannarx_ruxsat) buzilmaydi.
--
--  'hodim' bu ro'yxatda YO'Q va bo'lmasligi kerak (cheklanmaydigan sahifa).
--
--  ⚠️ 0.1 da `perm_pages()` YO'Q chiqqan bo'lsa — bu bo'limni RUN qilish
--     `create or replace` bilan funksiyani noldan yaratadi, lekin ruxsat
--     tizimining qolgan qismi (user_perms, my_perms) bo'lmasa ma'nosi
--     bo'lmaydi. Avval PROVODKA_PERMS.sql ni RUN qiling.

-- ⬇⬇⬇  1-BO'LIM: SHU QATORDAN 1-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function perm_pages()
returns text[]
language sql
immutable
as $perm_pages$
  select array['kassa','jurnal','professional','hisobot','balans','cashflow',
               'qarzdor','filial','valyuta','konvert','sozlama','provodka',
               'yuklar','standart','tannarx','ai']::text[];
$perm_pages$;

revoke all on function perm_pages() from public, anon;
grant execute on function perm_pages() to authenticated, service_role;

comment on function perm_pages() is
  'Provodka sahifa kalitlari (16 ta). perms.js dagi PAGES va admin-dev PVS_PAGES bilan bir xil. '
  'hodim.html bu royxatga KIRMAYDI — u hech qachon cheklanmaydi.';
-- ⬆⬆⬆  1-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  2-BO'LIM — TEKSHIRUV.  HECH NARSA YOZMAYDI.
-- #####################################################################
--  🔴 Nomuvofiqlik JIMGINA O'TMAYDI — `raise exception` bilan to'xtaydi.
--  Uchta shart tekshiriladi:
--     1) kalit soni AYNAN 16;
--     2) eski 15 kalitning HAMMASI joyida (biri ham tushib qolmagan);
--     3) 'ai' ro'yxatda bor.
--
--  ⚠️ Dollar-quote NOMLANGAN (tekshir tegi bilan) — nomsiz variantni
--     Supabase SQL Editor bo'lib yuborardi.

-- ⬇⬇⬇  2-BO'LIM: SHU QATORDAN 2-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
do $tekshir$
declare
  v_pages  text[] := perm_pages();
  v_eski   text[] := array['kassa','jurnal','professional','hisobot','balans','cashflow',
                           'qarzdor','filial','valyuta','konvert','sozlama','provodka',
                           'yuklar','standart','tannarx'];
  v_n      int    := coalesce(array_length(perm_pages(), 1), 0);
  v_yoq    text[];
  k        text;
begin
  -- 2.1 Eski kalitlardan yo'qolgani bormi
  v_yoq := array[]::text[];
  foreach k in array v_eski loop
    if not (k = any(v_pages)) then
      v_yoq := v_yoq || k;
    end if;
  end loop;

  if array_length(v_yoq, 1) is not null then
    raise exception
      'perm_pages() dan ESKI KALIT(LAR) YOQOLDI: %. 1-BOLIM royxatini tekshiring (additive bolishi shart).',
      array_to_string(v_yoq, ', ');
  end if;

  -- 2.2 'ai' qo'shildimi
  if not ('ai' = any(v_pages)) then
    raise exception
      'perm_pages() da ai kaliti YOQ — 1-BOLIM RUN qilinmagan yoki keyin eski nusxa ustiga yozilgan.';
  end if;

  -- 2.3 Soni aynan 16 mi (dublikat yoki ortiqcha kalit bo'lmasin)
  if v_n <> 16 then
    raise exception
      'perm_pages() da % ta kalit bor, 16 kutilgandi. Joriy royxat: %',
      v_n, array_to_string(v_pages, ', ');
  end if;

  raise notice '✅ perm_pages() OK — 16 kalit, ai joyida: %', array_to_string(v_pages, ', ');
end
$tekshir$;

-- 2.4 Ko'z bilan ko'rish uchun (yozmaydi)
select 'perm_pages kalitlari' as tekshiruv,
       array_length(perm_pages(), 1) as kalit_soni,
       ('ai' = any(perm_pages()))    as ai_bor,
       case when array_length(perm_pages(), 1) = 16
                 and 'ai'       = any(perm_pages())
                 and 'tannarx'  = any(perm_pages())
                 and 'standart' = any(perm_pages())
                 and 'yuklar'   = any(perm_pages())
            then '✅ OK'
            else '❌ TEKSHIRING — 1-BO''LIMni QAYTA RUN qiling' end as natija;

select unnest(perm_pages()) as sahifa_kaliti;
-- ⬆⬆⬆  2-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  3-BO'LIM — PostgREST sxema keshini yangilash
-- #####################################################################
--  Busiz o'zgargan funksiya klientdan eski holida ko'rinishi mumkin.

-- ⬇⬇⬇  3-BO'LIM  ⬇⬇⬇
notify pgrst, 'reload schema';
-- ⬆⬆⬆  3-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  4-BO'LIM — ROLLBACK (kerak bo'lsa, QO'LDA)
-- #####################################################################
--  Ataylab izohda turibdi — tasodifan RUN bo'lmasin.
--
--  ⚠️ Faqat klient tomoni ham qaytarilgan bo'lsa ishlating:
--     `perms-dev.js` PAGES va `admin-dev.html` PVS_PAGES dan 'ai'
--     olib tashlangan bo'lsin. Aks holda admin panelida ko'rinadigan
--     checkbox jimgina ishlamay qoladi.
--  ⚠️ Ro'yxatdan 'ai' olinsa, ilgari berilgan `user_perms.allowed_pages`
--     ichidagi 'ai' qiymati o'chmaydi — u shunchaki e'tiborsiz qoladi
--     (`perm_has_page` ro'yxatga kirmaydigan kalitni cheklanmagan deb
--     hisoblaydi). Ma'lumot yo'qolmaydi.

-- 4.1 Kim uchun ai ochilgan (bu select xavfsiz)
-- select user_id, allowed_pages
--   from user_perms
--  where 'ai' = any(allowed_pages);

-- 4.2 perm_pages() ni 15 kalitga qaytarish
-- create or replace function perm_pages()
-- returns text[]
-- language sql
-- immutable
-- as 'select array[''kassa'',''jurnal'',''professional'',''hisobot'',''balans'',''cashflow'',
--                  ''qarzdor'',''filial'',''valyuta'',''konvert'',''sozlama'',''provodka'',
--                  ''yuklar'',''standart'',''tannarx'']::text[]';

-- 4.3 notify pgrst, 'reload schema';
