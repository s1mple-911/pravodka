-- ============================================================================
--  PROVODKA_JURNAL_SABAB.sql — 2026-09-15 (Asilbek)
--  «Jurnalda Tovar tannarxi tanlansa yonidan tag filtri chiqmayapti.»
--
--  Sabab: Tovar tannarxining «taglari» (Yo'l puli / Bojxona / Abusaxiy …)
--  maxsus maydon EMAS — ular to'lovning o'zida, `entry.yuk_sabab_id` da
--  (PROVODKA_YUK_BOGLANMAGAN_V2.sql). PROVODKA_JURNAL_MAYDON.sql faqat
--  maxsus maydon elementlarini (entry_maydon) filtrlardi.
--
--  Yechim: to'rtala jurnal RPC siga OXIRGI argument `p_sabablar integer[]
--  default null`. Tag filtri endi IKKI xil tagning BIRLASHMASI (YOKI):
--  maxsus maydon elementi YOKI tovar tannarxi to'lov turi. 0 = sababsiz
--  «📦 Tovar narxi» (faqat 9110/9110-1 Dt satri bor yozuvlar).
--
--  Tanalar PROVODKA_JURNAL_MAYDON.sql dan (jonli versiya) AYNAN ko'chirilgan —
--  skript bilan, har almashtirish soni tekshirilib (gen_sabab_sql.py).
--  🔴 Keyingi safar jurnal_v2* o'zgartirilsa ENG OXIRGI versiya SHU faylda.
--  Eski chaqiruvlar (prod jurnal.html, p_sabablar'siz) sukut null bilan
--  O'ZGARISHSIZ ishlaydi. Ikki marta RUN qilinsa ham xato bermaydi.
--  Old shart: PROVODKA_JURNAL_MAYDON.sql va PROVODKA_YUK_BOGLANMAGAN_V2.sql.
-- ============================================================================

do $chk$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'entry'
                    and column_name = 'yuk_sabab_id') then
    raise exception 'Avval PROVODKA_YUK_BOGLANMAGAN_V2.sql ni RUN qiling (entry.yuk_sabab_id yoq)';
  end if;
  if to_regprocedure('public.jurnal_maydon_filtr_ok()') is null then
    raise exception 'Avval PROVODKA_JURNAL_MAYDON.sql ni RUN qiling';
  end if;
end
$chk$;


-- #####################################################################
-- ##  1. jurnal_v2_baza() — YANGI: p_elementlar (OXIRGI parametr)     ##
-- #####################################################################
-- Manba: PROVODKA_KONVERT_FILTR.sql (eng oxirgi, 'pul'/'savdosiz'/'konvert'
-- tokenlari + ext_ref manbai shu yerdan). Tana VERBATIM ko'chirildi, YAGONA
-- qo'shimcha: `v_elementlar` e'loni + hisoblanishi va "e" CTE ichida BITTA
-- yangi `and (...)` shartqator (pastda belgilangan).
--
-- 🔴 DROP shu CREATE bilan AJRALMAS: imzo (yangi parametr) o'zgargani uchun
--    yolg'iz `create or replace` PostgREST'da eski+yangi overload'ni
--    ikkalasini ham qoldirib "could not choose the best candidate" berishi
--    mumkin. Faylni bo'lib RUN qilsangiz ham bu ikki qator BIRGA ketadi.
drop function if exists public.jurnal_v2_baza(date, date, uuid[], uuid[], text[], text, uuid[]);
create or replace function jurnal_v2_baza(
  p_from       date,
  p_to         date,
  p_accounts   uuid[],
  p_moddalar   uuid[],
  p_turlar     text[],
  p_q          text,
  p_elementlar uuid[] default null,
  p_sabablar   integer[] default null)
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
  v_perm       uuid[] := perm_view_pul_ids();   -- null = cheklovsiz, '{}' = hech narsa
  v_moddalar   uuid[];
  v_q          text;
  v_pul        boolean := (p_turlar is not null and 'pul' = any(p_turlar));
  v_savdosiz   boolean := (p_turlar is not null and 'savdosiz' = any(p_turlar));
  v_konvert    boolean := (p_turlar is not null and 'konvert' = any(p_turlar));
  v_turlar     text[]  := p_turlar;
  -- 🔴 YANGI (PROVODKA_JURNAL_MAYDON.sql): maxsus maydon (tag) elementi
  --    bo'yicha filtr. Bo'sh massiv = "filtr yo'q" (p_moddalar naqshi bilan
  --    bir xil — CLAUDE.md TUZOQ izohi: bo'sh massiv har argumentda BOSHQA
  --    ma'noda bo'lishi mumkin, shu sabab har doim aniq hisoblanadi).
  v_elementlar uuid[];
  -- 🔴 YANGI (PROVODKA_JURNAL_SABAB.sql): tovar tannarxi to'lov turi (yuk_tannarx_sabab.id;
  --    0 = sababsiz «Tovar narxi») va 9110/9110-1 hisob id lari.
  v_sabablar   integer[];
  v_tan_ids    uuid[] := '{}'::uuid[];
begin
  -- ⚠️ TUZOQ — bo'sh massiv MA'NOSI bu funksiyada BIR XIL EMAS:
  --   p_moddalar = '{}' → "filtr yo'q";  p_accounts / p_turlar = '{}' → HECH NARSA.
  if p_moddalar is null or array_length(p_moddalar, 1) is null then
    v_moddalar := null;
  else
    v_moddalar := p_moddalar;
  end if;

  -- p_elementlar = '{}' / null -> "filtr yo'q" (xatti-harakat AYNAN eskidek).
  if coalesce(array_length(p_elementlar, 1), 0) = 0 then
    v_elementlar := null;
  else
    v_elementlar := p_elementlar;
  end if;

  -- p_sabablar = '{}' / null -> "filtr yo'q". 0 = «Tovar narxi» (sababsiz to'lov).
  if coalesce(array_length(p_sabablar, 1), 0) = 0 then
    v_sabablar := null;
  else
    v_sabablar := p_sabablar;
    select coalesce(array_agg(a.id), '{}'::uuid[]) into v_tan_ids
      from accounts a where a.code in ('9110', '9110-1');
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
       -- 🔴 YANGI (PROVODKA_JURNAL_MAYDON.sql): maxsus maydon TAG filtri —
       --    kamida bitta entry_maydon qatori shu elementlardan biriga ega
       --    bo'lsin. `entry_maydon_element_idx` (element_id) indeksi ishlaydi.
       -- 🔴 PROVODKA_JURNAL_SABAB.sql: TAG = ikki xil tag BIRLASHMASI (YOKI):
       --    (a) maxsus maydon elementi (entry_maydon), YOKI
       --    (b) tovar tannarxi to'lov turi — entry.yuk_sabab_id (0 = sababsiz
       --        «Tovar narxi»); faqat 9110/9110-1 Dt satri bor yozuvlar.
       and ((v_elementlar is null and v_sabablar is null)
            or (v_elementlar is not null and exists (
                  select 1 from entry_maydon em
                   where em.entry_id = en.id and em.element_id = any(v_elementlar)))
            or (v_sabablar is not null
                and coalesce(en.yuk_sabab_id, 0) = any(v_sabablar)
                and exists (
                  select 1 from entry_line el
                   where el.entry_id = en.id and el.account_id = any(v_tan_ids)
                     and el.debit > 0)))
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
     -- 'konvert' — faqat valyuta sotib olish/sotish yozuvlari.
     and (not v_konvert or (t.tt = 'transfer' and exists (
           select 1 from entry_line el join accounts ak on ak.id = el.account_id
            where el.entry_id = t.e_id
              and coalesce(ak.currency, 'UZS') <> 'UZS'
              and coalesce(el.fc_amount, 0) > 0)));
end $fn$;

revoke all on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text, uuid[], integer[]) from public, anon, authenticated;

comment on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text, uuid[], integer[]) is
  'ICHKI: jurnal v2 uchun filtrlangan yozuvlar + tur tasnifi + ijrochi_raw. Ruxsat shu yerda. '
  'Sana filtri created_at (Asia/Tashkent) boyicha. ''pul''/''savdosiz''/''konvert'' tokenlari '
  'oldingidek. 🔴 p_elementlar (PROVODKA_JURNAL_MAYDON.sql, OXIRGI parametr, default null): '
  'xarajat maydon TAG filtri — bosh/null bolsa oz''garmaydi, aks holda kamida bitta entry_maydon '
  'qatori element_id = any(p_elementlar) bolgan yozuvlar qaytadi.';


-- #####################################################################
-- ##  2. jurnal_v2() — YANGI: p_elementlar (OXIRGI parametr)          ##
-- #####################################################################
-- Manba: PROVODKA_KONVERT_FILTR.sql (eng oxirgi, ext_ref kaliti shu yerdan).
-- Tana VERBATIM ko'chirildi, YAGONA farq: yangi parametr + jurnal_v2_baza
-- chaqiruviga 7-argument sifatida uzatilishi (pastda belgilangan).
drop function if exists public.jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text, uuid[]);
create or replace function jurnal_v2(
  p_from       date,
  p_to         date,
  p_accounts   uuid[] default null,
  p_moddalar   uuid[] default null,
  p_turlar     text[] default null,
  p_q          text   default null,
  p_limit      int    default 100,
  p_offset     int    default 0,
  p_ijrochi    text   default null,
  p_elementlar uuid[] default null,
  p_sabablar   integer[] default null)
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
                 -- kurs farq yozuvini ('convfarq:'||<konvert entry id>) qidirish
                 -- uchun. Qo'shimcha kalit — eski klientlar sinmaydi.
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
            -- 🔴 YANGI (PROVODKA_JURNAL_MAYDON.sql): p_elementlar 7-argument
            --    sifatida jurnal_v2_baza ga uzatiladi.
            from jurnal_v2_baza(p_from, p_to, p_accounts, p_moddalar, p_turlar, p_q, p_elementlar, p_sabablar) b
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

revoke all on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text, uuid[], integer[]) from public, anon;
grant execute on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text, uuid[], integer[]) to authenticated;

comment on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text, uuid[], integer[]) is
  'Jurnal v2 royxati: sana + hisob + xarajat moddasi + tur + qidiruv + IJROCHI (hammasi AND, serverda). '
  'Javob shakli eski jurnal() bilan bir xil + ijrochi/ijrochi_raw/ext_ref kalitlari; lines har doim toliq (Dt birinchi). '
  'p_ijrochi — XOM created_by boyicha aniq moslik (ismga emas), ''(bosh)'' = created_by yoq yozuvlar. '
  '🔴 p_elementlar (PROVODKA_JURNAL_MAYDON.sql, OXIRGI parametr, default null): xarajat maydon TAG '
  'filtri — jurnal_v2_baza ga shundayligicha uzatiladi. '
  'TEZLIK: ijrochi_nomi() LIMIT/OFFSET dan KEYIN chaqiriladi (kopi bilan p_limit marta). '
  'Sahifa qorovuli: jurnal_page_ok(''jurnal''). Tartib: created_at desc, id desc.';


-- #####################################################################
-- ##  3. jurnal_v2_count() — YANGI: p_elementlar (OXIRGI parametr)    ##
-- #####################################################################
-- Manba: PROVODKA_IJROCHI.sql (bu funksiya undan keyin qayta yozilmagan).
drop function if exists public.jurnal_v2_count(date, date, uuid[], uuid[], text[], text, text, uuid[]);
create or replace function jurnal_v2_count(
  p_from       date,
  p_to         date,
  p_accounts   uuid[] default null,
  p_moddalar   uuid[] default null,
  p_turlar     text[] default null,
  p_q          text   default null,
  p_ijrochi    text   default null,
  p_elementlar uuid[] default null,
  p_sabablar   integer[] default null)
returns int
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_n  int;
  v_ij text := nullif(btrim(coalesce(p_ijrochi, '')), '');
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  -- 🔴 SAHIFA QOROVULI: kassa ruxsati YETARLI EMAS (kassa_scope sukuti 'all').
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  -- 🔴 YANGI (PROVODKA_JURNAL_MAYDON.sql): p_elementlar 7-argument sifatida
  --    jurnal_v2_baza ga uzatiladi — filtr ro'yxat bilan AYNAN bir xil bolsin.
  select count(*)::int into v_n
    from jurnal_v2_baza(p_from, p_to, p_accounts, p_moddalar, p_turlar, p_q, p_elementlar, p_sabablar) b
   where v_ij is null
      or (v_ij = '(bosh)' and b.ijrochi_raw is null)
      or b.ijrochi_raw = v_ij;

  return coalesce(v_n, 0);
end $fn$;

revoke all on function jurnal_v2_count(date, date, uuid[], uuid[], text[], text, text, uuid[], integer[]) from public, anon;
grant execute on function jurnal_v2_count(date, date, uuid[], uuid[], text[], text, text, uuid[], integer[]) to authenticated;

comment on function jurnal_v2_count(date, date, uuid[], uuid[], text[], text, text, uuid[], integer[]) is
  'Jurnal v2: filtrga tushgan yozuvlar soni (sahifalash uchun). Filtr/ruxsat royxat bilan bir xil '
  '(p_ijrochi va 🔴 p_elementlar — PROVODKA_JURNAL_MAYDON.sql, OXIRGI parametr, default null — ham), '
  'sahifa qorovuli ham (42501). '
  'TEZLIK: javobda ism yoq — ijrochi_nomi() UMUMAN chaqirilmaydi (filtr xom kalitga tayanadi).';


-- #####################################################################
-- ##  4. jurnal_dash() — YANGI: p_elementlar (OXIRGI parametr)        ##
-- #####################################################################
-- Manba: PROVODKA_IJROCHI.sql (bu funksiya undan keyin qayta yozilmagan).
drop function if exists public.jurnal_dash(date, date, uuid[], uuid[], text[], text, text, uuid[]);
create or replace function jurnal_dash(
  p_from       date,
  p_to         date,
  p_accounts   uuid[] default null,
  p_moddalar   uuid[] default null,
  p_turlar     text[] default null,
  p_q          text   default null,
  p_ijrochi    text   default null,
  p_elementlar uuid[] default null,
  p_sabablar   integer[] default null)
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

  with b as materialized (
    -- 🔴 p_turlar ATAYLAB null (dashboard davr xulosasi — asl fayldagi qaror).
    --    p_ijrochi va p_elementlar esa QO'LLANADI (o'sha izoh + YANGI tag filtri).
    select * from jurnal_v2_baza(p_from, p_to, p_accounts, p_moddalar, null, p_q, p_elementlar, p_sabablar) z
     where v_ij is null
        or (v_ij = '(bosh)' and z.ijrochi_raw is null)
        or z.ijrochi_raw = v_ij
  ),
  -- 🔴 AGREGAT MANBASI — FAIL-CLOSED, IKKI chetlash (asl fayldagidek):
  --   1) o'chirilgan yozuv;  2) aralash ko'p satrli (begona and n_lines > 2).
  bs as (select * from b
          where coalesce(b.is_deleted, false) = false
            and not (b.begona and b.n_lines > 2)),
  j as (
    select count(*)::int as soni, coalesce(sum(bs.summa), 0)::numeric as summa from bs
  ),
  ch as (     -- chetlanganlar (bitta yozuv ikkala sababga tushsa faqat `ochirilgan` da)
    select (count(*) filter (where coalesce(b.is_deleted, false) = false
                               and b.begona and b.n_lines > 2))::int as soni,
           (count(*) filter (where coalesce(b.is_deleted, false)))::int as ochirilgan
      from b
  ),
  t as (
    select bs.tur, count(*)::int as soni, coalesce(sum(bs.summa), 0)::numeric as summa
      from bs group by bs.tur
  ),
  x as (
    select a.id as account_id, a.code, a.name,
           coalesce(sum(l.debit), 0)::numeric   as summa,
           count(distinct l.entry_id)::int      as soni
      from bs
      join entry_line l on l.entry_id = bs.id and l.debit > 0
      join accounts   a on a.id = l.account_id
     where a.type = 'xarajat'
     group by a.id, a.code, a.name
    having coalesce(sum(l.debit), 0) > 0
  )
  select jsonb_build_object(
           'jami',       (select to_jsonb(j) from j),
           'turlar',     (select coalesce(jsonb_agg(to_jsonb(t) order by t.summa desc, t.tur), '[]'::jsonb) from t),
           'xarajat',    (select coalesce(jsonb_agg(to_jsonb(x) order by x.summa desc, x.code), '[]'::jsonb) from x),
           'chetlangan', (select to_jsonb(ch) from ch)
         )
    into v_out;

  return coalesce(v_out, jsonb_build_object(
    'jami',       jsonb_build_object('soni', 0, 'summa', 0),
    'turlar',     '[]'::jsonb,
    'xarajat',    '[]'::jsonb,
    'chetlangan', jsonb_build_object('soni', 0, 'ochirilgan', 0)));
end $fn$;

revoke all on function jurnal_dash(date, date, uuid[], uuid[], text[], text, text, uuid[], integer[]) from public, anon;
grant execute on function jurnal_dash(date, date, uuid[], uuid[], text[], text, text, uuid[], integer[]) to authenticated;

comment on function jurnal_dash(date, date, uuid[], uuid[], text[], text, text, uuid[], integer[]) is
  'Jurnal v2 dashboard (DAVR XULOSASI): jami + tur kesimi (hamma tur) + xarajat moddalari kesimi + chetlangan. '
  'Sahifa qorovuli: jurnal_page_ok(''jurnal''). '
  '🔴 p_turlar IMZODA QOLADI, lekin ETIBORGA OLINMAYDI (tur — royxat korinishi, xulosa filtri emas). '
  'p_ijrochi va 🔴 p_elementlar (PROVODKA_JURNAL_MAYDON.sql, OXIRGI parametr, default null) — QOLLANADI. '
  'AGREGAT FAIL-CLOSED: ochirilgan va aralash kop satrli yozuv jamiga KIRMAYDI, royxatda korinadi. '
  'TEZLIK: javobda ism yoq — ijrochi_nomi() UMUMAN chaqirilmaydi (filtr xom kalitga tayanadi).';


-- #####################################################################
-- ##  5. jurnal_sabab_filtr_ok() — klient uchun "SQL RUN qilingan" belgisi
-- #####################################################################
create or replace function jurnal_sabab_filtr_ok()
returns boolean
language sql
stable
as $fn$ select true $fn$;

revoke all on function jurnal_sabab_filtr_ok() from public, anon;
grant execute on function jurnal_sabab_filtr_ok() to authenticated;

comment on function jurnal_sabab_filtr_ok() is
  'jurnal-dev.html: jurnal_v2/jurnal_v2_count/jurnal_dash p_sabablar (tovar tannarxi tolov turi TAG filtri) '
  'argumentini tushunadimi (PGRST202 bolsa yoq — argument yuborilmaydi).';

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  DIAG — faqat katalog so'rovlari                                  ##
-- #####################################################################
do $diag$
declare
  v_baza  text;
  v_v2    text;
  v_count text;
  v_dash  text;
  v_n     int;
begin
  select oidvectortypes(p.proargtypes) into v_baza
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'jurnal_v2_baza';
  select oidvectortypes(p.proargtypes) into v_v2
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'jurnal_v2';
  select oidvectortypes(p.proargtypes) into v_count
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'jurnal_v2_count';
  select oidvectortypes(p.proargtypes) into v_dash
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'jurnal_dash';

  raise notice 'jurnal_v2_baza : %', coalesce(v_baza, '(topilmadi)');
  raise notice 'jurnal_v2      : %', coalesce(v_v2, '(topilmadi)');
  raise notice 'jurnal_v2_count: %', coalesce(v_count, '(topilmadi)');
  raise notice 'jurnal_dash    : %', coalesce(v_dash, '(topilmadi)');

  if v_baza  is distinct from 'date, date, uuid[], uuid[], text[], text, uuid[], integer[]'
  or v_v2    is distinct from 'date, date, uuid[], uuid[], text[], text, integer, integer, text, uuid[], integer[]'
  or v_count is distinct from 'date, date, uuid[], uuid[], text[], text, text, uuid[], integer[]'
  or v_dash  is distinct from 'date, date, uuid[], uuid[], text[], text, text, uuid[], integer[]' then
    raise exception 'YAKUNIY TEKSHIRUV: jurnal funksiyalarining imzosi kutilganday emas';
  end if;

  select count(*)::int into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('jurnal_v2_baza', 'jurnal_v2', 'jurnal_v2_count', 'jurnal_dash');
  if v_n <> 4 then
    raise exception 'YAKUNIY TEKSHIRUV: overload qolib ketgan (% ta funksiya, kutilgan 4)', v_n;
  end if;
  raise notice 'HAMMASI JOYIDA';
end
$diag$;
