-- =====================================================================
-- DIAG_JURNAL_V2_BAZA.sql — 42P13 sababini aniqlash + tezkor yechim
-- ---------------------------------------------------------------------
-- Xato: cannot change return type of existing function
--       HINT: Use DROP FUNCTION jurnal_v2_baza(date,date,uuid[],uuid[],text[],text) first.
--
-- PROVODKA_IJROCHI.sql da bu drop ALLAQACHON bor (3.0 bo'limi, 435-qator)
-- va u create'dan (465) OLDIN turadi. Demak drop bajarilmagan.
-- Quyidagi ikki so'rov nega bajarilmaganini ko'rsatadi.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) Bazada NECHTA jurnal_v2_baza bor va imzosi qanday?
--    Kutilgan: 1 ta qator, argumentlar aynan
--    "p_from date, p_to date, p_accounts uuid[], p_moddalar uuid[],
--     p_turlar text[], p_q text"
--
--    ⚠️ AGAR SXEMA `public` BO'LMASA — IJROCHI dagi `drop ... public.…`
--       boshqa obyektni izlayapti va shuning uchun hech narsa qilmayapti.
--    ⚠️ AGAR 2 QATOR chiqsa — overload bor, drop faqat bittasini oladi.
-- ---------------------------------------------------------------------
select n.nspname                              as sxema,
       p.proname                              as nom,
       pg_get_function_arguments(p.oid)       as argumentlar,
       pg_get_function_result(p.oid)          as natija
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where p.proname = 'jurnal_v2_baza'
 order by n.nspname;


-- ---------------------------------------------------------------------
-- 2) Natijada `ijrochi_raw` ustuni BORmi?
--    true  -> IJROCHI allaqachon qisman qo'llangan, drop kerak emas edi
--    false -> eski (14 ustunli) versiya turibdi, drop ishlamagan
-- ---------------------------------------------------------------------
select pg_get_function_result(p.oid) like '%ijrochi_raw%' as ijrochi_raw_bor
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'jurnal_v2_baza';


-- =====================================================================
-- 3) TEZKOR YECHIM — shu 4 qatorni ALOHIDA RUN qiling,
--    keyin PROVODKA_IJROCHI.sql ni BUTUNLIGICHA qaytadan RUN qiling.
--
--    🔴 `cascade` ATAYLAB YO'Q: u bog'liq obyektlarni ham o'chirib
--       yuborardi. Bu funksiyalar boshqa hech narsaga bog'lanmagan,
--       shuning uchun oddiy drop yetadi.
--
--    ⚠️ Shu daqiqadan `jurnal-dev.html` vaqtincha eski `jurnal()` ga
--       tushadi (`v2Off` zaxirasi) — sahifa bo'sh qolmaydi. IJROCHI
--       RUN bo'lgach o'zi tiklanadi.
-- =====================================================================
drop function if exists public.jurnal_v2_baza(date, date, uuid[], uuid[], text[], text);
drop function if exists public.jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int);
drop function if exists public.jurnal_v2_count(date, date, uuid[], uuid[], text[], text);
drop function if exists public.jurnal_dash(date, date, uuid[], uuid[], text[], text);

-- Tasdiq: uchalasi ham `true` (ya'ni endi bazada yo'q) bo'lishi kerak
select to_regprocedure('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)') is null as baza_ochirildi,
       to_regprocedure('public.jurnal_v2(date,date,uuid[],uuid[],text[],text,int,int)')      is null as v2_ochirildi,
       to_regprocedure('public.jurnal_dash(date,date,uuid[],uuid[],text[],text)')            is null as dash_ochirildi;
