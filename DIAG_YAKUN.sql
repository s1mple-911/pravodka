-- =====================================================================
-- DIAG_YAKUN.sql — RUN'lardan keyingi YAKUNIY HOLAT tasdiqi
-- ---------------------------------------------------------------------
-- 🔴 Faqat O'QIYDI. Bittalab RUN qiling.
--
-- Nima uchun kerak: bir necha fayl AYNI obyektni yozadi
--   * `perm_guard_entry_line` -> PROVODKA_PERMS.sql VA PROVODKA_SOROVLAR.sql
--   * `perm_pages()`          -> 8 ta fayl
-- Eski fayl KEYIN RUN qilinsa yangi mantiq JIMGINA yo'qoladi (xato bermaydi).
-- Quyidagi so'rovlar shuni ushlaydi.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) 70% TO'SIQ + QARZ — TOZA O'CHDIMI?
--    Hamma ustun `true` bo'lishi kerak.
-- ---------------------------------------------------------------------
select not exists (select 1 from pg_trigger
                    where tgname = 'trg_hodim_tosiq_entry_line')          as tosiq_trigger_yoq,
       to_regprocedure('public.hodim_tosiq_guard()')            is null   as guard_yoq,
       to_regprocedure('public.hodim_tosiq_foiz()')             is null   as foiz_yoq,
       to_regprocedure('public.hodim_kirim_yop(uuid,numeric,uuid,text)') is null as kirim_yop_yoq,
       to_regprocedure('public.hodim_qarz_hisob(uuid)')         is null   as qarz_hisob_yoq,
       to_regprocedure('public.hodim_kassa_ildiz(uuid)')        is null   as kassa_ildiz_yoq,
       to_regclass('public.v_hodim_balans')                     is null   as balans_view_yoq,
       to_regclass('public.v_hodim_tolanmagan')                 is null   as tolanmagan_view_yoq;


-- ---------------------------------------------------------------------
-- 2) 🔴 PROD FUNKSIYALARI JOYIDAMI? (bularni prod hodim.html chaqiradi)
--    Hamma ustun `true`.
-- ---------------------------------------------------------------------
select to_regprocedure('public.xarajat_saqlash_taqsim(jsonb)')            is not null as taqsim_bor,
       to_regprocedure('public.hodim_oz_tarix(date,date)')                is not null as oz_tarix_bor,
       to_regprocedure('public.hodim_oy_jami(uuid,date,date)')            is not null as oy_jami_bor,
       to_regprocedure('public.hodim_oy_jami_kop(uuid[],date,date)')      is not null as oy_jami_kop_bor,
       to_regprocedure('public.xarajat_qayta_urinish(text)')              is not null as qayta_urinish_bor,
       -- qarz mantiqi ULARDAN chiqib ketganmi (prosrc da qarz izi qolmasin)
       (select p.prosrc !~* 'qarz|6721' from pg_proc p
         where p.proname = 'xarajat_saqlash_taqsim'
           and p.pronamespace = 'public'::regnamespace)                    as taqsim_qarzsiz,
       (select p.prosrc !~* 'hodim_qarz' from pg_proc p
         where p.proname = 'hodim_oz_tarix'
           and p.pronamespace = 'public'::regnamespace)                    as tarix_qarzsiz;


-- ---------------------------------------------------------------------
-- 3) SO'ROVLAR TIZIMI O'RNIDAMI?
-- ---------------------------------------------------------------------
select to_regclass('public.sorovlar')                              is not null as jadval_bor,
       to_regprocedure('public.sorov_kimdan()')                    is not null as kimdan_bor,
       to_regprocedure('public.sorov_royxat(text,boolean)')         is not null as royxat_bor,
       to_regprocedure('public.sorov_menikilar()')                  is not null as menikilar_bor,
       to_regprocedure('public.sorov_xarajat_bekor(uuid)')          is not null as bekor_bor,
       (select count(*) from pg_policies
         where tablename = 'sorovlar')                                        as policy_soni,
       -- 🔴 yozish policy'si BO'LMASLIGI kerak (faqat RPC yozadi)
       not exists (select 1 from pg_policies
                    where tablename = 'sorovlar' and cmd <> 'SELECT')         as yozish_policy_yoq;


-- ---------------------------------------------------------------------
-- 4) 🔴 ENG MUHIM — GUARD ISTISNOSI VA UNING VAQT CHEGARASI JOYIDAMI?
--    `PROVODKA_PERMS.sql` keyin RUN qilinsa bu jimgina yo'qoladi va
--    tasdiqlash 42501 bilan ishlamay qoladi (yoki teshik ochiladi).
--    Uchala ustun ham `true` bo'lishi SHART.
-- ---------------------------------------------------------------------
select (p.prosrc like '%sorovlar%')                as istisno_bor,
       (p.prosrc like '%decided_at = now()%')      as vaqt_chegarasi_bor,
       (p.prosrc like '%jonatilgan_summa%')        as summa_chegarasi_bor
  from pg_proc p
 where p.proname = 'perm_guard_entry_line'
   and p.pronamespace = 'public'::regnamespace;


-- ---------------------------------------------------------------------
-- 5) `perm_pages()` da `sorovlar` kaliti bormi?
--    Yo'q bo'lsa: eski fayllardan biri KEYIN RUN qilingan.
--    Tuzatish — PROVODKA_SOROVLAR.sql ning 1-BO'LIMINI qayta RUN qilish.
-- ---------------------------------------------------------------------
select 'sorovlar' = any(perm_pages()) as sorovlar_kaliti_bor,
       array_length(perm_pages(), 1)  as kalit_soni;


-- ---------------------------------------------------------------------
-- 6) "KIMDAN SO'RASH" ro'yxatiga kim tushadi?
--    🔴 BO'SH chiqsa — hech kimdan pul so'rab bo'lmaydi.
--    Shart: kassa_scope='list' + o'z UZS ildiz kassasi + 'sorovlar' sahifasi.
--    Bo'sh bo'lsa admin-dev'dan o'sha odamlarga ruxsat berilishi kerak.
-- ---------------------------------------------------------------------
select up.user_id,
       (select coalesce(nullif(to_jsonb(pr) ->> 'full_name', ''), up.user_id::text)
          from profiles pr where pr.id = up.user_id)                as ism,
       up.kassa_scope,
       ('sorovlar' = any(coalesce(up.allowed_pages, '{}')))         as sorovlar_sahifasi,
       coalesce(array_length(up.op_kassa_ids, 1), 0)                as op_kassa_soni
  from user_perms up
 order by sorovlar_sahifasi desc, ism;


-- ---------------------------------------------------------------------
-- 7) 6720 / 6721 hisoblari qanday holatda qoldi?
-- ---------------------------------------------------------------------
select a.code, a.name, a.is_active,
       (select count(*) from entry_line l where l.account_id = a.id) as satr_soni
  from accounts a
 where a.code like '672%'
 order by a.code;


-- ---------------------------------------------------------------------
-- 8) Yetim sarlavhalar (satrsiz entry) — hali qancha?
--    Bugungi 13 tasi hamon turibdi (ataylab o'chirmadik).
-- ---------------------------------------------------------------------
select count(*)          as yetim_jami,
       max(e.created_at) as oxirgisi
  from entry e
 where not exists (select 1 from entry_line l where l.entry_id = e.id)
   and coalesce(e.is_deleted, false) = false;
