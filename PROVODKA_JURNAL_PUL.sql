-- =====================================================================
--  PROVODKA_JURNAL_PUL.sql — Jurnal: TOVAR HARAKATI KO'RINMAYDI
--  (faqat PUL yozuvlari: kirim / chiqim / transfer / professional-pul)
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--  Brief: BRIEF_PROVODKA_JURNAL_V3.md, 3-band (2026-08-30, Asilbek qarori):
--    "Dokonda tovar kamaygani/ko'paygani jurnalda KERAK EMAS — faqat pul."
--
--  NIMA QILADI
--  -----------
--  `jurnal_v2_baza()` `p_turlar` massivida YANGI TOKEN `'pul'` ni tushunadi:
--    * `'pul'` bo'lsa — faqat KAMIDA BITTA satri pul hisobi (accounts.section
--      = 'pul') bo'lgan yozuvlar qaytadi. Ombor → tannarx, 6010 → ombor kabi
--      "tovar" yozuvlari (ikkala tomoni pul emas) CHIQIB KETADI.
--    * `'pul'` qolgan tur kalitlari bilan BIRGA ishlaydi (AND):
--        ['pul']                       → hamma pul yozuvlari
--        ['chiqim','xarajat','pul']    → faqat pul chiqimlari (avvalgidek)
--        ['boshqa','pul']              → professional ko'p satrli PUL yozuvlari
--                                        (tovar ko'p satrlisi emas)
--    * `'pul'` YO'Q bo'lsa — xatti-harakat AYNAN eskidek (prod `jurnal.html`
--      buni yubormaydi → unga TA'SIR YO'Q, garchi baza bitta bo'lsa ham).
--    * 🔴 CHALA yozuv (satri umuman yo'q, n_lines=0) 'pul' bilan ham KO'RINADI —
--      u tovar emas, saqlash yarim qolgan diagnostika; admin ko'rib tozalashi
--      kerak (jurnal-dev.html `CHALA_NOM`).
--  `jurnal_v2`, `jurnal_v2_count`, `jurnal_dash`, `jurnal_ijrochilar` —
--  hammasi `jurnal_v2_baza` orqali AVTOMAT shu filtrni oladi (ularga
--  tegilmaydi). Dashboard (xarajat breakdown) ham tovar yozuvlarisiz.
--
--  `jurnal_pul_filtr_ok()` — YANGI, klient uchun "SQL RUN qilinganmi" belgisi
--  (jurnal_ijrochilar naqshi). Busiz klient `'pul'` yuborsa ESKI bazada
--  `t.tt = any(['pul'])` hech narsaga mos kelmay jurnal BO'SH chiqardi —
--  klient shu funksiyani bir marta chaqiradi, yo'q bo'lsa (PGRST202/42883)
--  token yuborilmaydi.
--
--  SQL ADDITIVE: `jurnal_v2_baza` imzosi VA `returns table(...)` shakli
--  O'ZGARMAYDI (PROVODKA_JURNAL_KIRITILGAN.sql dagi bilan bir xil) → faqat
--  `create or replace`, DROP YO'Q. Tana VERBATIM ko'chirildi, farq faqat
--  `declare` dagi 2 o'zgaruvchi va OXIRGI `where` qatori (sharh bilan
--  belgilangan).
--
--  OLD SHART: PROVODKA_JURNAL_KIRITILGAN.sql RUN qilingan bo'lsin (0-bo'lim
--  tekshiradi) — aks holda bu fayl eski `entry_date` semantikasini qaytarib
--  qo'yardi.
-- =====================================================================


-- #####################################################################
-- ##  0. OLD SHART                                                    ##
-- #####################################################################
-- Anonim do bloki: jurnal_v2_baza ning ijrochi_raw qaytaradigan (15 ustunli)
-- versiyasi bormi. Yo'q bo'lsa to'xtaymiz.
do $do$
begin
  if to_regprocedure('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)') is null then
    raise exception 'Old shart yoq: PROVODKA_IJROCHI.sql + PROVODKA_JURNAL_KIRITILGAN.sql avval RUN qilinsin.'
      using errcode = '55000';
  end if;
  if not exists (
    select 1 from information_schema.routines r
     where r.routine_schema = 'public' and r.routine_name = 'jurnal_v2_baza'
       and position('ijrochi_raw' in coalesce(pg_get_function_result(
             ('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)')::regprocedure), '')) > 0
  ) then
    raise exception 'Old shart yoq: jurnal_v2_baza ijrochi_raw ustunini qaytarmaydi — PROVODKA_IJROCHI.sql RUN qilinsin.'
      using errcode = '55000';
  end if;
end
$do$;


-- #####################################################################
-- ##  1. jurnal_v2_baza() — 'pul' tokeni                              ##
-- #####################################################################
create or replace function jurnal_v2_baza(
  p_from     date,
  p_to       date,
  p_accounts uuid[],
  p_moddalar uuid[],
  p_turlar   text[],
  p_q        text)
returns table(
  id uuid, entry_date date, created_at timestamptz, description text,
  source text, is_deleted boolean, deleted_by_name text, deleted_at timestamptz,
  edited_at timestamptz, edited_by_name text,
  n_lines int, summa numeric, tur text,
  begona boolean,
  ijrochi_raw text
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_perm     uuid[] := perm_view_pul_ids();   -- null = cheklovsiz, '{}' = hech narsa
  v_moddalar uuid[];
  v_q        text;
  -- 🔴 YANGI (2026-08-30): 'pul' tokeni — faqat pul satri bor yozuvlar.
  v_pul      boolean := (p_turlar is not null and 'pul' = any(p_turlar));
  v_turlar   text[]  := p_turlar;
begin
  -- ⚠️ TUZOQ — bo'sh massiv MA'NOSI bu funksiyada BIR XIL EMAS:
  --   p_moddalar = '{}' → "filtr yo'q";  p_accounts / p_turlar = '{}' → HECH NARSA.
  if p_moddalar is null or array_length(p_moddalar, 1) is null then
    v_moddalar := null;
  else
    v_moddalar := p_moddalar;
  end if;

  -- 'pul' tokeni tur ro'yxatidan OLIB TASHLANADI; faqat 'pul' bo'lsa tur filtri
  -- yo'q (null) — ['pul'] = "hamma pul yozuvlari", ['pul'] ≠ "hech narsa".
  if v_pul then
    v_turlar := array_remove(v_turlar, 'pul');
    if array_length(v_turlar, 1) is null then
      v_turlar := null;
    end if;
  end if;

  -- Qidiruv: LIKE metabelgilari tozalanadi.
  if p_q is null or btrim(p_q) = '' then
    v_q := null;
  else
    v_q := '%' || replace(replace(replace(btrim(p_q), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  return query
  with e as (
    select en.id                as e_id,
           en.entry_date        as e_date,
           en.created_at        as e_created,
           en.description       as e_desc,
           en.source            as e_source,
           en.is_deleted        as e_del,
           en.deleted_by_name   as e_delby,
           en.deleted_at        as e_delat,
           en.edited_at         as e_edat,
           en.edited_by_name    as e_edby,
           nullif(btrim(coalesce(to_jsonb(en) ->> 'created_by', '')), '') as e_by,
           (v_perm is not null and exists (
              select 1 from entry_line el join accounts ab on ab.id = el.account_id
               where el.entry_id = en.id
                 and ab.type = 'aktiv' and ab.code like '5%'
                 and ab.kassa_turi is distinct from 'xarajat_guruh'
                 and not (el.account_id = any(v_perm)))) as e_begona
      from entry en
     where en.status = 'posted'
       -- 🔴 is_deleted filtri ATAYLAB YO'Q (jurnal o'chirilganini ham ko'rsatadi)
       -- 🔴 SANA -> KIRITILGAN VAQT (PROVODKA_JURNAL_KIRITILGAN.sql) — o'zgarmagan.
       and en.created_at >= (p_from::timestamp at time zone 'Asia/Tashkent')
       and en.created_at <  ((p_to + 1)::timestamp at time zone 'Asia/Tashkent')
       and (p_accounts is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(p_accounts)))
       and (v_moddalar is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(v_moddalar)
                and el.debit > 0))
       -- 🔴 RUXSAT (server tomonda, klient filtridan MUSTAQIL)
       and (v_perm is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(v_perm)))
       and (v_q is null or en.description ilike v_q escape '\')
       -- 🔴 YANGI: 'pul' tokeni — kamida bitta satri pul hisobi bo'lsin.
       --    Chala yozuv (satr yo'q) ISTISNO — u tovar emas, diagnostika.
       and (not v_pul
            or exists (
                 select 1 from entry_line el join accounts ap on ap.id = el.account_id
                  where el.entry_id = en.id and ap.section = 'pul')
            or not exists (select 1 from entry_line el where el.entry_id = en.id))
  ),
  c as (
    select e.*,
           (select count(*)::int from entry_line l where l.entry_id = e.e_id) as n,
           (select coalesce(sum(l.debit), 0)::numeric from entry_line l where l.entry_id = e.e_id) as s,
           d.sec as dt_sec, d.typ as dt_type,
           k.sec as kt_sec, k.typ as kt_type
      from e
      left join lateral (
        select a.section as sec, a.type as typ
          from entry_line l join accounts a on a.id = l.account_id
         where l.entry_id = e.e_id and l.debit > 0
         order by l.debit desc limit 1) d on true
      left join lateral (
        select a.section as sec, a.type as typ
          from entry_line l join accounts a on a.id = l.account_id
         where l.entry_id = e.e_id and l.credit > 0
         order by l.credit desc limit 1) k on true
  ),
  t as (
    select c.*,
           case
             when c.n > 2                                    then 'boshqa'
             when c.dt_sec = 'pul' and c.kt_sec = 'pul'      then 'transfer'
             when c.dt_sec = 'pul' and c.kt_type = 'daromad' then 'tushum'
             when c.dt_sec = 'pul'                           then 'kirim'
             when c.kt_sec = 'pul' and c.dt_type = 'xarajat' then 'xarajat'
             when c.kt_sec = 'pul'                           then 'chiqim'
             else 'boshqa'
           end as tt
      from c
  )
  select t.e_id::uuid, t.e_date::date, t.e_created::timestamptz, t.e_desc::text,
         t.e_source::text, t.e_del::boolean, t.e_delby::text, t.e_delat::timestamptz,
         t.e_edat::timestamptz, t.e_edby::text,
         t.n::int, t.s::numeric, t.tt::text, t.e_begona::boolean,
         t.e_by::text
    from t
   -- 🔴 YANGI: p_turlar emas, 'pul' siz v_turlar bilan taqqoslanadi.
   where v_turlar is null or t.tt = any(v_turlar);
end $fn$;

revoke all on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text) from public, anon, authenticated;

comment on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text) is
  'ICHKI: jurnal v2 uchun filtrlangan yozuvlar + tur tasnifi + ijrochi_raw. Ruxsat shu yerda. '
  'Sana filtri created_at (Asia/Tashkent) boyicha (PROVODKA_JURNAL_KIRITILGAN.sql). '
  '🔴 2026-08-30 (PROVODKA_JURNAL_PUL.sql): p_turlar ichida ''pul'' tokeni bolsa faqat pul satri '
  'bor yozuvlar (tovar harakati chiqib ketadi), chala yozuv istisno; token yoq bolsa eskidek.';


-- #####################################################################
-- ##  2. jurnal_pul_filtr_ok() — klient uchun "SQL RUN qilingan" belgisi ##
-- #####################################################################
create or replace function jurnal_pul_filtr_ok()
returns boolean
language sql
stable
as $fn$ select true $fn$;

revoke all on function jurnal_pul_filtr_ok() from public, anon;
grant execute on function jurnal_pul_filtr_ok() to authenticated;

comment on function jurnal_pul_filtr_ok() is
  'jurnal-dev.html: jurnal_v2_baza ''pul'' tokenini tushunadimi (PGRST202 bolsa yoq). Hech narsa oqimaydi.';


-- #####################################################################
-- ##  3. TEKSHIRUV (ixtiyoriy, o'qish uchun)                          ##
-- #####################################################################
-- select count(*) from jurnal_v2_baza(current_date - 30, current_date, null, null, null, null);          -- hammasi
-- select count(*) from jurnal_v2_baza(current_date - 30, current_date, null, null, array['pul'], null);  -- faqat pul (kamroq yoki teng)
-- select tur, count(*) from jurnal_v2_baza(current_date - 30, current_date, null, null, array['pul'], null) group by 1;


-- #####################################################################
-- ##  ROLLBACK (qo'lda, kerak bo'lsa)                                 ##
-- #####################################################################
-- PROVODKA_JURNAL_KIRITILGAN.sql 1-bo'limini qayta RUN qiling (tana 'pul'
-- tokensiz qaytadi, imzo bir xil — drop shart emas) va:
-- drop function if exists jurnal_pul_filtr_ok();
