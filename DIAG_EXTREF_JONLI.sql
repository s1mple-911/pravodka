-- =====================================================================
-- DIAG_EXTREF_JONLI.sql — server tomonda `ext_ref` yozmaydigan yo'llar
-- ---------------------------------------------------------------------
-- KLIENT tomoni TUZATILDI (dev fayllarda): hodim, provodka, professional —
-- hammasi endi bir martalik `ext_ref` yuboradi.
--
-- SERVERDA ikki yo'l hamon `ext_ref = null` yozadi (ya'ni ikki marta bosilsa
-- pul ikki marta chiqadi):
--   1) `kassa.html` -> `convert_start_v2` -> `do_convert_v2(..., p_ext => null)`
--      (koridor ICHIDAGI, darrov bajariladigan konvert. `convert_approve`
--       orqali o'tgani `'conv:'||id` oladi, ya'ni himoyalangan.)
--   2) `kassa.html` -> `tur_convert(...)` — insert ustunlari ro'yxatida
--      `ext_ref` UMUMAN yo'q, funksiyada `p_ext_ref` argumenti ham yo'q.
--
-- 🔴 NEGA TUZATISH SQL'i HOZIR YOZILMADI: bu funksiyalar bir NECHTA .sql
--    faylda qayta e'lon qilingan (`create or replace`), va bazada qaysi
--    versiya turganini repodan bilib bo'lmaydi. Noto'g'ri versiya ustiga
--    yozilsa boshqa xususiyat JIMGINA yo'qoladi.
--    Shuning uchun avval JONLI tanani chiqaramiz — tuzatish aynan shuning
--    ustiga yoziladi.
--
-- ⚠️ Hech narsa o'zgarmaydi — faqat O'QIYDI.
-- =====================================================================


-- ############ 1-SO'ROV — jonli funksiya tanalari ############
-- Natijadagi `tana` ustunini TO'LIQ nusxalab yuboring (uchala qatorni ham).
-- Tuzatish shu matn asosida yoziladi: imzo (argument nomi/turi/tartibi)
-- O'ZGARMAYDI, faqat ichida ext_ref hosil qilinadi.
select p.proname                          as funksiya,
       pg_get_function_identity_arguments(p.oid) as imzo,
       pg_get_functiondef(p.oid)          as tana
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('convert_start_v2', 'do_convert_v2', 'tur_convert')
 order by p.proname, imzo;


-- ############ 2-SO'ROV — `provodka_yoz` bazada BORMI ############
-- 🔴 null qaytsa: `provodka.html` va `professional.html` ning HAR saqlashi
--    jimgina zaxira yo'lga (`saveEski`) tushadi. Dev'da u endi ext_ref
--    yozadi, lekin PROD hali eski — promote'gacha himoyasiz.
-- select to_regprocedure('public.provodka_yoz(jsonb)')            as provodka_yoz,
--        to_regprocedure('public.xarajat_saqlash_taqsim(jsonb)')  as taqsim,
--        to_regprocedure('public.xarajat_qayta_urinish(text)')    as qayta_urinish;


-- ############ 3-SO'ROV — `xarajat_saqlash_taqsim` ext_ref ni QABUL QILADIMI ############
-- 🔴 Bu funksiya 5 ta faylda e'lon qilingan; eski versiyalari `p_data.ext_ref`
--    ni JIMGINA e'tiborsiz qoldiradi (xato bermaydi). Ya'ni klient token
--    yuborsa ham himoya ishlamasligi mumkin.
--    Tana ichida `ext_ref` so'zi bo'lishi SHART.
-- select p.proname,
--        (pg_get_functiondef(p.oid) like '%ext_ref%') as ext_ref_qollab_quvvatlaydi
--   from pg_proc p
--   join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public' and p.proname = 'xarajat_saqlash_taqsim';


-- ############ 4-SO'ROV — unikal indeks o'rnidami ############
-- Busiz ext_ref shunchaki matn: takror hech narsa bilan to'silmaydi.
-- select i.relname as indeks, x.indisunique as unikalmi,
--        pg_get_indexdef(x.indexrelid) as tarif
--   from pg_index x
--   join pg_class t on t.oid = x.indrelid
--   join pg_class i on i.oid = x.indexrelid
--  where t.relname = 'entry'
--  order by x.indisunique desc, i.relname;
-- `entry_ext_ref_uniq` + unikalmi = true bo'lishi SHART.


-- ############ 5-SO'ROV — BUGUN hali ham ext_ref siz yozilyaptimi ############
-- Klient tuzatishi promote qilingandan KEYIN bu ro'yxat faqat
-- `aros_auto` (n8n sinxroni — u ataylab delta mexanizmi bilan himoyalangan)
-- va konvert yo'llari bilan qolishi kerak.
-- select e.source,
--        count(*)                                            as tokensiz_soni,
--        min((e.created_at + interval '5 hours')::timestamp)  as eng_eski_uzb,
--        max((e.created_at + interval '5 hours')::timestamp)  as eng_yangi_uzb,
--        (array_agg(e.description order by e.created_at desc))[1:3] as izoh_namunalari
--   from entry e
--  where e.ext_ref is null
--    and e.created_at > now() - interval '7 days'
--  group by e.source
--  order by tokensiz_soni desc;
--
-- Izoh namunalaridan yo'lni ajratish:
--   "Konvert: … -> … · kurs …"   -> convert_start_v2   (1-so'rovdagi tuzatish)
--   "Tur o'tkazish: X → Y"       -> tur_convert        (1-so'rovdagi tuzatish)
--   "Aros sync …"                -> n8n, delta bilan himoyalangan (tegilmaydi)
--   boshqa / bo'sh               -> klient yo'li: promote qilinganmi tekshiring
