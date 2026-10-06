-- ============================================================================
--  PROVODKA_JURNAL_TEXNIK.sql — 2026-10-06 — Jurnal: TEXNIK (avto kurs farqi / tozalash) yozuvlar serverda ham yashirin
--  Asilbek: «yozuvlar ko'rinmay qoldi, lekin datalar filtrlarda/xulosada hali ham bor». Klient yashirgani bilan jurnal_dash
--  (Davr xulosasi, Nimaga qancha, Ulush, xarajat turi ro'yxati «Davrda harakati bor») va jurnal_v2_count serverdan kelardi.
--  Yechim: jurnal_v2_baza da yangi `'texnik'` TOKENI ('pul'/'savdosiz'/'konvert' naqshi): tokensiz ext_ref 'kursfarq:%'
--  yozuvlar CHIQMAYDI (ro'yxat, sanoq, dashboard, Excel — hammasi bitta manba); token bo'lsa chiqadi («Texnik yozuvlar»
--  belgisi). jurnal_dash p_turlar dan faqat 'texnik' tokenini o'tkazadi (tur filtri avvalgidek e'tiborga olinmaydi).
--  Qo'lda kiritilgan konvert farqi (convfarq:, «Pul usti») TEXNIK EMAS — chiqaveradi. Imzolar o'zgarmagan (jurnal_v2 /
--  jurnal_v2_count baza orqali avtomat). Probe: jurnal_texnik_filtr_ok(). Asilbek RUN qiladi.
--  🔴 jurnal_v2_baza / jurnal_dash ning ENG OXIRGI versiyasi endi SHU faylda (avval PROVODKA_JURNAL_SABAB.sql).
-- ============================================================================
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
  v_texnik     boolean := (p_turlar is not null and 'texnik' = any(p_turlar));   -- 🔴 2026-10-06: avto kurs farqi KO'RSATILSIN
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
  if v_pul or v_savdosiz or v_konvert or v_texnik then
    if v_pul      then v_turlar := array_remove(v_turlar, 'pul'); end if;
    if v_texnik   then v_turlar := array_remove(v_turlar, 'texnik'); end if;
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
       -- 🔴 2026-10-06 (Asilbek): TEXNIK yozuvlar — avtomat kurs farqi / tozalash (ext_ref 'kursfarq:%') — sukut
       --    bo'yicha YASHIRIN (ro'yxat, sanoq, dashboard, Excel); 'texnik' tokeni bo'lsa chiqadi.
       and (v_texnik or coalesce(en.ext_ref, '') not like 'kursfarq:%')
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
    -- 🔴 2026-10-06: FAQAT 'texnik' tokeni o'tkaziladi (tur filtri emas) — avto kurs farqi xulosaga ham kirmasin
    select * from jurnal_v2_baza(p_from, p_to, p_accounts, p_moddalar,
                                 case when p_turlar is not null and 'texnik' = any(p_turlar) then array['texnik']::text[] else null end,
                                 p_q, p_elementlar, p_sabablar) z
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

create or replace function jurnal_texnik_filtr_ok()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select position('texnik' in pg_get_functiondef('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text,uuid[],integer[])'::regprocedure)) > 0;
$fn$;
revoke all on function jurnal_texnik_filtr_ok() from public, anon;
grant execute on function jurnal_texnik_filtr_ok() to authenticated;

notify pgrst, 'reload schema';

select jurnal_texnik_filtr_ok() as texnik_token_bor,
       (select count(*) from entry where ext_ref like 'kursfarq:%' and is_deleted = false) as texnik_yozuvlar;
