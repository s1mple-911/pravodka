-- ============================================================================
--  PROVODKA_JURNAL_FILIAL_FILTR.sql — 2026-10-27 — Jurnal FILIAL filtri: TEG (entry.filial_ids) bo'yicha ham
--  ----------------------------------------------------------------------------
--  Asilbek: «filtrga Yunusobod oshxonani qo'yib qarasam yozuv chiqmayapti». Yozuv Kt = hodim kartasi (5392),
--  Dt = Xo'jalik mollari, Maqsad tegi = «Yunusobod oshxona» (entry.filial_ids). Jurnal filial filtri esa FAQAT
--  hisob bo'yicha ishlardi (p_accounts = filial kassasi oilasi) — teg hisobga olinmasdi (Aros filiallarida ham).
--  Yechim: jurnal_v2_baza p_turlar'da YANGI `filial:<uuid>` TOKEN(lar)ini tushunadi ('pul'/'texnik' naqshi):
--     yozuv  (p_accounts satri bor)  YOKI  (entry.filial_ids && token id'lari)  → chiqadi.
--  jurnal_dash ham shu tokenlarni o'tkazadi (xulosa/kartalar ham teg bo'yicha). jurnal_v2 / jurnal_v2_count
--  p_turlar'ni bazaga o'zgarishsiz uzatadi (PROVODKA_JURNAL_SABAB.sql) — tegilmaydi.
--  Tanalar PROVODKA_JURNAL_TEXNIK.sql (2026-10-06, ENG OXIRGI versiya) dan AYNAN ko'chirildi + filial tokeni.
--  Probe: jurnal_filial_filtr_ok(). ADDITIVE (create or replace, imzo o'zgarmagan). Asilbek RUN qiladi.
--  Dollar-quote: faqat NOMLI teglar.
-- ============================================================================

-- 0) OLD SHART: TEXNIK versiyasi bazada turibdi (aks holda bu fayl eski xususiyatni yo'qotmaydi — tanasi to'liq,
--    lekin probe'lar mosligi uchun ogohlantiramiz)
do $jf_pre$
begin
  if to_regprocedure('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text,uuid[],integer[])') is null then
    raise exception 'OLD SHART: jurnal_v2_baza(…,uuid[],integer[]) imzosi yo''q — avval PROVODKA_JURNAL_SABAB.sql va PROVODKA_JURNAL_TEXNIK.sql RUN qiling';
  end if;
  perform 1 from information_schema.columns where table_name = 'entry' and column_name = 'filial_ids';
  if not found then
    raise exception 'OLD SHART: entry.filial_ids ustuni yo''q (PROVODKA_V6.sql)';
  end if;
end
$jf_pre$;

-- ---------------------------------------------------------------------------
-- 1) jurnal_v2_baza — TEXNIK + `filial:<uuid>` tokenlari
-- ---------------------------------------------------------------------------
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
as $jf_baza$
declare
  v_perm       uuid[] := perm_view_pul_ids();   -- null = cheklovsiz, '{}' = hech narsa
  v_moddalar   uuid[];
  v_q          text;
  v_pul        boolean := (p_turlar is not null and 'pul' = any(p_turlar));
  v_savdosiz   boolean := (p_turlar is not null and 'savdosiz' = any(p_turlar));
  v_konvert    boolean := (p_turlar is not null and 'konvert' = any(p_turlar));
  v_texnik     boolean := (p_turlar is not null and 'texnik' = any(p_turlar));   -- 2026-10-06: avto kurs farqi KO'RSATILSIN
  v_turlar     text[]  := p_turlar;
  -- 2026-10-27: `filial:<uuid>` tokenlari — filial TEGI (entry.filial_ids) bo'yicha ham filtr
  v_filial     uuid[];
  v_tok        text;
  v_tok_olindi boolean := false;   -- biror token olib tashlandimi (faqat shunda bo'sh ro'yxat = "filtr yo'q")
  v_elementlar uuid[];
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

  if coalesce(array_length(p_elementlar, 1), 0) = 0 then
    v_elementlar := null;
  else
    v_elementlar := p_elementlar;
  end if;

  if coalesce(array_length(p_sabablar, 1), 0) = 0 then
    v_sabablar := null;
  else
    v_sabablar := p_sabablar;
    select coalesce(array_agg(a.id), '{}'::uuid[]) into v_tan_ids
      from accounts a where a.code in ('9110', '9110-1');
  end if;

  -- 2026-10-27: filial tokenlarini ajratib olamiz (va tur ro'yxatidan olib tashlaymiz)
  if p_turlar is not null then
    foreach v_tok in array p_turlar loop
      if v_tok like 'filial:%' then
        begin
          v_filial := array_append(v_filial, substr(v_tok, 8)::uuid);
        exception when others then
          null;   -- yaroqsiz uuid — e'tiborsiz
        end;
        v_turlar := array_remove(v_turlar, v_tok); v_tok_olindi := true;
      end if;
    end loop;
  end if;

  -- 'pul'/'savdosiz'/'konvert'/'texnik' tokenlari tur ro'yxatidan OLIB TASHLANADI —
  -- ular `tt` bilan taqqoslanmaydi, alohida AND filtrlari (pastda, oxirgi where).
  -- ⚠️ p_turlar = '{}' (tokensiz) → HECH NARSA (asl xatti-harakat): faqat token olingan bo'lsa bo'sh = "filtr yo'q".
  if v_pul      then v_turlar := array_remove(v_turlar, 'pul');      v_tok_olindi := true; end if;
  if v_texnik   then v_turlar := array_remove(v_turlar, 'texnik');   v_tok_olindi := true; end if;
  if v_savdosiz then v_turlar := array_remove(v_turlar, 'savdosiz'); v_tok_olindi := true; end if;
  if v_konvert  then v_turlar := array_remove(v_turlar, 'konvert');  v_tok_olindi := true; end if;
  if v_tok_olindi and array_length(v_turlar, 1) is null then
    v_turlar := null;
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
       -- is_deleted filtri ATAYLAB YO'Q (jurnal o'chirilganini ham ko'rsatadi)
       -- SANA -> KIRITILGAN VAQT (PROVODKA_JURNAL_KIRITILGAN.sql) — o'zgarmagan.
       and en.created_at >= (p_from::timestamp at time zone 'Asia/Tashkent')
       and en.created_at <  ((p_to + 1)::timestamp at time zone 'Asia/Tashkent')
       -- 2026-10-27: hisob bo'yicha YOKI filial TEGI bo'yicha (filial:<id> tokenlari)
       and (p_accounts is null
            or exists (
                 select 1 from entry_line el
                  where el.entry_id = en.id and el.account_id = any(p_accounts))
            or (v_filial is not null and en.filial_ids is not null and en.filial_ids && v_filial))
       and (v_moddalar is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(v_moddalar)
                and el.debit > 0))
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
       -- RUXSAT (server tomonda, klient filtridan MUSTAQIL)
       and (v_perm is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(v_perm)))
       and (v_q is null or en.description ilike v_q escape '\')
       -- TEXNIK yozuvlar (ext_ref 'kursfarq:%') sukut bo'yicha YASHIRIN; 'texnik' tokeni bo'lsa chiqadi.
       and (v_texnik or coalesce(en.ext_ref, '') not like 'kursfarq:%')
       -- 'pul' tokeni — kamida bitta satri pul hisobi bo'lsin. Chala yozuv (satr yo'q) ISTISNO.
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
     and (not v_savdosiz or coalesce(t.e_source, '') <> 'aros_auto' or t.tt = 'transfer')
     and (not v_konvert or (t.tt = 'transfer' and exists (
           select 1 from entry_line el join accounts ak on ak.id = el.account_id
            where el.entry_id = t.e_id
              and coalesce(ak.currency, 'UZS') <> 'UZS'
              and coalesce(el.fc_amount, 0) > 0)));
end
$jf_baza$;

-- ---------------------------------------------------------------------------
-- 2) jurnal_dash — TEXNIK + filial tokenlari o'tkaziladi (tur filtri avvalgidek e'tiborga olinmaydi)
-- ---------------------------------------------------------------------------
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
as $jf_dash$
declare
  v_out  jsonb;
  v_ij   text := nullif(btrim(coalesce(p_ijrochi, '')), '');
  v_tok  text[];
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  -- p_turlar ATAYLAB null (dashboard davr xulosasi) — FAQAT 'texnik' va 'filial:<id>' tokenlari o'tkaziladi
  if p_turlar is not null then
    select array_agg(x) into v_tok
      from unnest(p_turlar) x
     where x = 'texnik' or x like 'filial:%';
  end if;

  with b as materialized (
    select * from jurnal_v2_baza(p_from, p_to, p_accounts, p_moddalar, v_tok, p_q, p_elementlar, p_sabablar) z
     where v_ij is null
        or (v_ij = '(bosh)' and z.ijrochi_raw is null)
        or z.ijrochi_raw = v_ij
  ),
  bs as (select * from b
          where coalesce(b.is_deleted, false) = false
            and not (b.begona and b.n_lines > 2)),
  j as (
    select count(*)::int as soni, coalesce(sum(bs.summa), 0)::numeric as summa from bs
  ),
  ch as (
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
end
$jf_dash$;

-- ---------------------------------------------------------------------------
-- 3) Probe — klient `filial:` tokenini faqat server tushunsa yuboradi
-- ---------------------------------------------------------------------------
create or replace function jurnal_filial_filtr_ok()
returns boolean
language sql
stable
security definer
set search_path = public
as $jf_ok$
  select position('filial:' in pg_get_functiondef('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text,uuid[],integer[])'::regprocedure)) > 0;
$jf_ok$;
revoke all on function jurnal_filial_filtr_ok() from public, anon;
grant execute on function jurnal_filial_filtr_ok() to authenticated;

-- entry.filial_ids && … uchun GIN indeks (bo'lmasa seq scan — hajm kichik, lekin arzon)
create index if not exists entry_filial_ids_gin on entry using gin (filial_ids);

notify pgrst, 'reload schema';

-- 4) Tekshiruv
select jurnal_filial_filtr_ok() as filial_token_bor,
       position('texnik' in pg_get_functiondef('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text,uuid[],integer[])'::regprocedure)) > 0 as texnik_saqlandi;
