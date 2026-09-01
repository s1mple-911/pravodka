-- =====================================================================
--  PROVODKA_KONVERT_FILTR.sql — Jurnal: KONVERT filtr chipi + kurs farqi
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  NIMA QILADI
--  -----------
--  1) `jurnal_v2_baza()` `p_turlar` massivida YANGI TOKEN `'konvert'` ni
--     tushunadi: faqat valyuta konvert yozuvlari qaytadi (bitta kassa ichida
--     UZS <-> chet valyuta almashinuvi — `convert_start_v2`/`convert_start_v3`
--     yozuvlari, eski konvertlar ham, ular ham chet valyutali satr bilan
--     yozilgan). Belgi: yozuv tasnifi `'transfer'` (ikkala tomon ham pul)
--     VA kamida bitta satri chet valyutada (`fc_amount > 0`).
--     `'konvert'` boshqa tur kalitlari bilan BIRGA ishlaydi (AND), xuddi
--     `'pul'`/`'savdosiz'` kabi (PROVODKA_JURNAL_PUL.sql / PROVODKA_KONVERT_V3.sql
--     bilan bir xil naqsh). `'pul'`/`'savdosiz'` mantig'i O'ZGARTIRILMAYDI —
--     tana shu ikkisini saqlagan holda faqat `'konvert'` bilan kengaytiriladi.
--  2) `jurnal_konvert_filtr_ok()` — YANGI, klient uchun "SQL RUN qilinganmi"
--     belgisi (`jurnal_pul_filtr_ok()`/`jurnal_savdosiz_ok()` naqshi).
--  3) `jurnal_v2()` — javobdagi har yozuvga YANGI kalit `ext_ref` qo'shiladi
--     (`entry.ext_ref`, subquery orqali — `jurnal_v2_baza()` uni qaytarmaydi).
--     `convert_start_v3` kurs farqini alohida yozuv sifatida `ext_ref =
--     'convfarq:' || <konvert yozuvi id>` bilan yozadi (PROVODKA_KONVERT_V3.sql,
--     Asilbek tomonidan RUN qilingan) — klient shu kalit orqali konvert
--     yozuviga tegishli farq yozuvini topadi va "xarajat/foyda" ko'rsatadi.
--     Eski klientlar (kalitni bilmaydigan kod) sinmaydi — jsonb'ga qo'shimcha
--     kalit qo'shilishi ADDITIVE.
--
--  SQL ADDITIVE: `jurnal_v2_baza`/`jurnal_v2` imzosi va `returns` shakli
--  O'ZGARMAYDI — faqat `create or replace`, DROP YO'Q.
--
--  OLD SHART: PROVODKA_KONVERT_V3.sql RUN qilingan bo'lsin (0-bo'lim
--  tekshiradi: `jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)` va
--  `jurnal_savdosiz_ok()` mavjudligi) — aks holda bu fayl eski, 'savdosiz'
--  tokenisiz semantikani qaytarib qo'yardi.
-- =====================================================================


-- #####################################################################
-- ##  0. OLD SHART                                                    ##
-- #####################################################################
do $do$
begin
  if to_regprocedure('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)') is null
     or to_regprocedure('public.jurnal_savdosiz_ok()') is null then
    raise exception
      'Old shart yoq: PROVODKA_KONVERT_V3.sql avval RUN qilingan bolishi kerak '
      '(jurnal_v2_baza(date,date,uuid[],uuid[],text[],text) va jurnal_savdosiz_ok() '
      'topilmadi). Bu faylni RUN qilish hozircha bekor qilindi.'
      using errcode = '55000';
  end if;
end
$do$;


-- #####################################################################
-- ##  1. jurnal_v2_baza() — 'konvert' tokeni                          ##
-- #####################################################################
-- Manba: PROVODKA_JURNAL_PUL.sql ('pul' tokeni) + PROVODKA_KONVERT_V3.sql
-- ('savdosiz' tokeni, mantig'i quyida saqlangan holda qayta yozilgan — u fayl
-- repoda .sql sifatida yo'q, Asilbek tomonidan to'g'ridan RUN qilingan).
-- YANGI qism faqat: v_konvert e'lon qilinishi, tur ro'yxatidan olib
-- tashlanishi va oxirgi where'dagi qo'shimcha shart.
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
  v_pul      boolean := (p_turlar is not null and 'pul' = any(p_turlar));
  v_savdosiz boolean := (p_turlar is not null and 'savdosiz' = any(p_turlar));
  -- 🔴 YANGI (PROVODKA_KONVERT_FILTR.sql): faqat valyuta konvert yozuvlari.
  v_konvert  boolean := (p_turlar is not null and 'konvert' = any(p_turlar));
  v_turlar   text[]  := p_turlar;
begin
  -- ⚠️ TUZOQ — bo'sh massiv MA'NOSI bu funksiyada BIR XIL EMAS:
  --   p_moddalar = '{}' → "filtr yo'q";  p_accounts / p_turlar = '{}' → HECH NARSA.
  if p_moddalar is null or array_length(p_moddalar, 1) is null then
    v_moddalar := null;
  else
    v_moddalar := p_moddalar;
  end if;

  -- 'pul'/'savdosiz'/'konvert' tokenlari tur ro'yxatidan OLIB TASHLANADI —
  -- ular `tt` bilan taqqoslanmaydi, alohida AND filtrlari (pastda, oxirgi where).
  if v_pul or v_savdosiz or v_konvert then
    if v_pul      then v_turlar := array_remove(v_turlar, 'pul'); end if;
    if v_savdosiz then v_turlar := array_remove(v_turlar, 'savdosiz'); end if;
    if v_konvert  then v_turlar := array_remove(v_turlar, 'konvert'); end if;
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
       -- 'pul' tokeni — kamida bitta satri pul hisobi bo'lsin. Chala yozuv
       -- (satr yo'q) ISTISNO — u tovar emas, diagnostika.
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
   where (v_turlar is null or t.tt = any(v_turlar))
     -- 'savdosiz' — aros_auto yozuvlardan faqat transfer qoladi (qabul qilingan
     -- transferlar), avtomatik savdo tushumi yozuvlari (Dt filial / Kt savdo
     -- tushumi) chiqib ketadi. coalesce — e_source null bo'lsa ham to'g'ri.
     and (not v_savdosiz or coalesce(t.e_source, '') <> 'aros_auto' or t.tt = 'transfer')
     -- 🔴 YANGI: 'konvert' — faqat valyuta sotib olish/sotish yozuvlari.
     and (not v_konvert or (t.tt = 'transfer' and exists (
           select 1 from entry_line el join accounts ak on ak.id = el.account_id
            where el.entry_id = t.e_id
              and coalesce(ak.currency, 'UZS') <> 'UZS'
              and coalesce(el.fc_amount, 0) > 0)));
end $fn$;

revoke all on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text) from public, anon, authenticated;

comment on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text) is
  'ICHKI: jurnal v2 uchun filtrlangan yozuvlar + tur tasnifi + ijrochi_raw. Ruxsat shu yerda. '
  'Sana filtri created_at (Asia/Tashkent) boyicha (PROVODKA_JURNAL_KIRITILGAN.sql). '
  '''pul'' tokeni (PROVODKA_JURNAL_PUL.sql): faqat pul satri bor yozuvlar. '
  '''savdosiz'' tokeni (PROVODKA_KONVERT_V3.sql): aros_auto yozuvlardan faqat transfer qoladi. '
  '🔴 ''konvert'' tokeni (PROVODKA_KONVERT_FILTR.sql): faqat valyuta konvert yozuvlari '
  '(transfer tasnifli va kamida bitta satri chet valyutada). Tokenlar yoq bolsa eskidek.';


-- #####################################################################
-- ##  2. jurnal_konvert_filtr_ok() — klient uchun "SQL RUN qilingan" belgisi ##
-- #####################################################################
create or replace function jurnal_konvert_filtr_ok()
returns boolean
language sql
stable
as $fn$ select true $fn$;

revoke all on function jurnal_konvert_filtr_ok() from public, anon;
grant execute on function jurnal_konvert_filtr_ok() to authenticated;

comment on function jurnal_konvert_filtr_ok() is
  'jurnal-dev.html: jurnal_v2_baza ''konvert'' tokenini tushunadimi (PGRST202 bolsa yoq). Hech narsa oqimaydi.';


-- #####################################################################
-- ##  3. jurnal_v2() — javobga ext_ref kaliti qo'shiladi               ##
-- #####################################################################
-- Manba: PROVODKA_JURNAL_KIRITILGAN.sql (~249-328 qatorlar), tana VERBATIM
-- ko'chirildi. YAGONA farq — ICHKI qavat select ro'yxatiga BITTA subquery
-- ustuni qo'shildi: `ext_ref` (jurnal_v2_baza uni qaytarmaydi, shuning uchun
-- `entry` jadvalidan alohida olinadi). Imzo/`returns jsonb` O'ZGARMAYDI —
-- faqat `create or replace`, DROP YO'Q.
create or replace function jurnal_v2(
  p_from     date,
  p_to       date,
  p_accounts uuid[] default null,
  p_moddalar uuid[] default null,
  p_turlar   text[] default null,
  p_q        text   default null,
  p_limit    int    default 100,
  p_offset   int    default 0,
  p_ijrochi  text   default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_out jsonb;
  v_ij  text := nullif(btrim(coalesce(p_ijrochi, '')), '');
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  -- 🔴 SAHIFA QOROVULI: kassa ruxsati YETARLI EMAS (kassa_scope sukuti 'all').
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc, r.id desc), '[]'::jsonb)
    into v_out
    from (
      -- TASHQI qavat: ism FAQAT shu yerda — LIMIT/OFFSET allaqachon qo'llangan,
      -- ya'ni `ijrochi_nomi()` ko'pi bilan `p_limit` marta chaqiriladi.
      select p.*,
             ijrochi_nomi(p.ijrochi_raw) as ijrochi
        from (
          -- ICHKI qavat: filtr + tartib + sahifalash. Faqat XOM kalit.
          select b.id, b.entry_date, b.description, b.source,
                 b.is_deleted, b.deleted_by_name, b.deleted_at,
                 b.edited_at, b.edited_by_name, b.created_at,
                 b.ijrochi_raw,
                 -- 🔴 YANGI (PROVODKA_KONVERT_FILTR.sql): kurs farq yozuvini
                 -- ('convfarq:'||<konvert entry id>) qidirish uchun. Qo'shimcha
                 -- kalit — eski klientlar sinmaydi.
                 (select e2.ext_ref from entry e2 where e2.id = b.id) as ext_ref,
                 (select coalesce(jsonb_agg(jsonb_build_object(
                           'id',         l.id,
                           'account_id', l.account_id,
                           'code',       a.code,
                           'name',       a.name,
                           'section',    a.section,
                           'currency',   a.currency,
                           'debit',      l.debit,
                           'credit',     l.credit,
                           'fc_amount',  l.fc_amount) order by l.debit desc), '[]'::jsonb)
                    from entry_line l join accounts a on a.id = l.account_id
                   where l.entry_id = b.id) as lines
            from jurnal_v2_baza(p_from, p_to, p_accounts, p_moddalar, p_turlar, p_q) b
            -- 🔴 IJROCHI FILTRI — xom qiymat bo'yicha aniq moslik, '(bosh)' sentinel
           where v_ij is null
              or (v_ij = '(bosh)' and b.ijrochi_raw is null)
              or b.ijrochi_raw = v_ij
           order by b.created_at desc, b.id desc
           limit  greatest(coalesce(p_limit, 100), 1)
           offset greatest(coalesce(p_offset, 0), 0)
        ) p
    ) r;

  return v_out;
end $fn$;

revoke all on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text) from public, anon;
grant execute on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text) to authenticated;

comment on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text) is
  'Jurnal v2 royxati: sana + hisob + xarajat moddasi + tur + qidiruv + IJROCHI (hammasi AND, serverda). '
  'Javob shakli eski jurnal() bilan bir xil + ijrochi/ijrochi_raw/ext_ref kalitlari; lines har doim toliq (Dt birinchi). '
  'p_ijrochi — XOM created_by boyicha aniq moslik (ismga emas), ''(bosh)'' = created_by yoq yozuvlar. '
  '🔴 ext_ref (PROVODKA_KONVERT_FILTR.sql): entry.ext_ref, konvert kurs farq yozuvini '
  '(''convfarq:''||<id>) topish uchun. TEZLIK: ijrochi_nomi() LIMIT/OFFSET dan KEYIN chaqiriladi. '
  'Sahifa qorovuli: jurnal_page_ok(''jurnal'').';


-- =====================================================================
-- PostgREST sxemasini yangilash (busiz yangi funksiya 404/PGRST202 beradi)
-- =====================================================================

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  4. TEKSHIRUV — FAQAT KATALOG SO'ROVLARI                        ##
-- #####################################################################
-- 🔴 JONLI RPC CHAQIRUVI YO'Q (jurnal_v2/jurnal_qoldiq ichida jurnal_page_ok
--    bor — SQL editorda auth.uid() null bo'lgani uchun 42501 beradi va butun
--    fayl orqaga qaytadi). Jonli sinov — brauzerda.
-- ---------------------------------------------------------------------

-- 4.1 jurnal_v2_baza — o'rnidami, overload bittami
select to_regprocedure('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)') is not null
         as jurnal_v2_baza_ok,
       (select count(*)::int from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname = 'jurnal_v2_baza') = 1
         as jurnal_v2_baza_overload_bittami;

-- 4.2 jurnal_v2 (9-argumentli) — o'rnidami, overload bittami
select to_regprocedure('public.jurnal_v2(date,date,uuid[],uuid[],text[],text,int,int,text)') is not null
         as jurnal_v2_ok,
       (select count(*)::int from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname = 'jurnal_v2') = 1
         as jurnal_v2_overload_bittami;

-- 4.3 jurnal_konvert_filtr_ok — o'rnidami
select to_regprocedure('public.jurnal_konvert_filtr_ok()') is not null
         as jurnal_konvert_filtr_ok_bor;

-- 4.4 🔴 jurnal_v2_count / jurnal_dash / jurnal_ijrochilar / jurnal_qoldiq
--     TEGILMAGANMI (bu fayl ularni na drop qiladi, na replace — ular
--     jurnal_v2_baza orqali AVTOMAT yangi semantikaga o'tadi)
select to_regprocedure('public.jurnal_v2_count(date,date,uuid[],uuid[],text[],text,text)') is not null
         as jurnal_v2_count_joyida,
       to_regprocedure('public.jurnal_dash(date,date,uuid[],uuid[],text[],text,text)') is not null
         as jurnal_dash_joyida,
       to_regprocedure('public.jurnal_ijrochilar(date,date)') is not null
         as jurnal_ijrochilar_joyida,
       to_regprocedure('public.jurnal_qoldiq(date,date,uuid[])') is not null
         as jurnal_qoldiq_joyida;

-- 4.5 (ixtiyoriy, o'qish uchun — jonli emas, izoh sifatida qoldirilgan)
-- select tur, count(*) from jurnal_v2_baza(current_date - 30, current_date, null, null, array['konvert'], null) group by 1;


-- #####################################################################
-- ##  ROLLBACK (qo'lda, kerak bo'lsa)                                 ##
-- #####################################################################
-- 1) jurnal_v2_baza / jurnal_v2 — PROVODKA_KONVERT_V3.sql (yoki undan oldingi
--    PROVODKA_JURNAL_PUL.sql, agar 'savdosiz' ham kerak bo'lmasa) qayta RUN
--    qilinsa tana 'konvert' tokenisiz/ext_ref'siz qaytadi (imzo bir xil).
-- drop function if exists jurnal_konvert_filtr_ok();
