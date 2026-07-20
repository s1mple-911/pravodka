-- =====================================================================
-- PROVODKA_KASSA2.sql
-- Hodim kassalari to'laqonli + Transfer + Konvert ko'p-valyuta (v2)
-- Foydalanuvchi QO'LDA ishga tushiradi. Idempotent — qayta-qayta run qilsa bo'ladi.
--
-- Qoidalar (BRIEF_PROVODKA_KASSA2.md):
--   * har yangi view  -> security_invoker = on
--   * har yangi funksiya -> REVOKE ... FROM PUBLIC, anon; faqat kerakli rolga GRANT
--   * xato holat -> RAISE EXCEPTION (jimgina o'tkazib yuborma)
--   * upsert_hodim_kassa() — TaskFix EF ishlatadi, service_role only. TEGILMAYDI.
--
-- MUHIM: bu fayl mavjud view'ni QAYTA YARATADI. Run qilishdan oldin eski
-- ta'rifni saqlab qo'ying:
--   select pg_get_viewdef('v_pul_hisoblar'::regclass, true);
-- =====================================================================


-- =====================================================================
-- 0-BOSQICH — Hodim kassalari hamma tanlagichda
-- ---------------------------------------------------------------------
-- provodka.html / professional.html / jurnal.html to'g'ridan `accounts`
-- jadvalidan o'qiydi — 54xx u yerda allaqachon bor, SQL kerak emas.
-- Faqat cashflow.html `v_pul_hisoblar` view'iga bog'langan, u esa kodni
-- qattiq yozib qo'ygan (5011/5012/5110 = markaziy, 52xx = filial), shuning
-- uchun 54xx unga tushmaydi. Endi view `kassa_turi` bo'yicha ishlaydi.
-- =====================================================================

-- 0.1 Kerakli ustunlar bormi — bo'lmasa to'xta (jimgina noto'g'ri view yasamaslik uchun)
do $$
declare
  m text;
begin
  select string_agg(c, ', ')
    into m
    from unnest(array['subtitle','kassa_turi','is_active','currency','parent_id','type','code','name']) as c
   where not exists (
     select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'accounts' and column_name = c
   );
  if m is not null then
    raise exception 'accounts jadvalida ustun(lar) yo''q: %. Avval migratsiyani bajaring.', m;
  end if;
end $$;

-- 0.2 v_pul_hisoblar — kassa tanlagichlari uchun (cashflow.html)
--     Ustunlar o'zgargani uchun CREATE OR REPLACE emas, DROP + CREATE kerak.
--     is_filial eski klient uchun qoladi (sindirma), yoniga kassa_turi/subtitle qo'shildi.
drop view if exists v_pul_hisoblar;
create view v_pul_hisoblar as
select
  a.id,
  a.code,
  a.name,
  a.subtitle,
  a.kassa_turi,
  a.parent_id,
  coalesce(a.currency, 'UZS')       as currency,
  (a.kassa_turi = 'filial')         as is_filial
from accounts a
where a.is_active
  and a.type = 'aktiv'
  and a.code like '5%'
  -- 5400 "Hodim xarajat kassalari" — konteyner, unga to'g'ridan pul yozilmaydi
  and coalesce(a.kassa_turi, '') <> 'xarajat_guruh';

alter view v_pul_hisoblar set (security_invoker = on);
revoke all on v_pul_hisoblar from public, anon;
grant select on v_pul_hisoblar to authenticated;

comment on view v_pul_hisoblar is
  'Pul hisoblari tanlagichi (cashflow.html). kassa_turi bo''yicha: markaziy/filial/xarajat. '
  'xarajat = hodim kassalari (54xx, parent 5400). Guruh qatorining o''zi chiqmaydi.';

-- 0.3 Tekshiruv: hodim kassalari view'ga tushdimi, guruh tushmadimi
do $$
declare
  n_guruh int;
begin
  select count(*) into n_guruh
    from v_pul_hisoblar where kassa_turi = 'xarajat_guruh';
  if n_guruh > 0 then
    raise exception 'v_pul_hisoblar ichida xarajat_guruh qatori bor — filtr ishlamadi';
  end if;
  raise notice 'v_pul_hisoblar: % ta hodim kassasi, % ta markaziy, % ta filial',
    (select count(*) from v_pul_hisoblar where kassa_turi = 'xarajat'),
    (select count(*) from v_pul_hisoblar where kassa_turi = 'markaziy'),
    (select count(*) from v_pul_hisoblar where kassa_turi = 'filial');
end $$;

-- 0-BOSQICH TUGADI ----------------------------------------------------


-- =====================================================================
-- 1-BOSQICH — Valyuta umumiy (USD'ga qotib qolmaslik)
-- ---------------------------------------------------------------------
-- Qoida: qaysi valyutada bola-hisob bo'lsa — o'sha ko'rinadi.
-- ESKI SEMANTIKA SAQLANADI: usd / usd_uzs / has_usd / usd_account_id
-- ustunlari FAQAT USD bolasidan keladi (eski UI sinmasin).
-- YANGI: `jami` endi parentning O'ZI + BARCHA valyuta bolalarining so'm
-- ekvivalenti (tarixiy kursda — qayta hisoblanmaydi).
--
-- ⚠️ DROP + CREATE: v_kassa_card (ustun qo'shildi).
-- =====================================================================

-- 1.1 Umumiy qoldiq yordamchisi — bal CTE endi bitta joyda
--     `fc` = shu hisobning O'Z valyutasidagi qoldiq (fc_amount valyutaga
--     bog'lanmagan, lekin bitta hisob = bitta valyuta bo'lgani uchun to'g'ri).
create or replace view v_hisob_bal as
select
  l.account_id,
  sum(l.debit - l.credit) as uzs,
  sum(case when l.debit > 0::numeric then coalesce(l.fc_amount, 0::numeric)
           else - coalesce(l.fc_amount, 0::numeric) end) as fc
from entry_line l
join entry e on e.id = l.entry_id
where e.status = 'posted'::text and e.is_deleted = false
group by l.account_id;

alter view v_hisob_bal set (security_invoker = on);
revoke all on v_hisob_bal from public, anon;
grant select on v_hisob_bal to authenticated;

comment on view v_hisob_bal is
  'Hisob qoldiqlari (posted, o''chirilmagan). uzs = debit-credit so''mda; '
  'fc = shu hisobning o''z valyutasidagi qoldiq (fc_amount yig''indisi).';

-- 1.2 v_kassa_valyutalar — parentning BARCHA valyuta bolalari
drop view if exists v_kassa_valyutalar;
create view v_kassa_valyutalar as
select
  c.parent_id,
  c.id                          as account_id,
  c.code,
  c.name,
  c.currency,
  coalesce(b.uzs, 0::numeric)   as uzs,        -- so'm ekvivalenti, TARIXIY kursda
  coalesce(b.fc, 0::numeric)    as fc_qoldiq   -- valyutaning o'zida
from accounts c
left join v_hisob_bal b on b.account_id = c.id
where c.section = 'pul'::text
  and c.is_active = true
  and c.parent_id is not null
  and c.currency is distinct from 'UZS'::text;

alter view v_kassa_valyutalar set (security_invoker = on);
revoke all on v_kassa_valyutalar from public, anon;
grant select on v_kassa_valyutalar to authenticated;

comment on view v_kassa_valyutalar is
  'Kassa kartasining valyuta satrlari. Har parent uchun 0..N qator (USD, CNY, ...). '
  'uzs — tarixiy kursdagi so''m ekvivalenti, joriy kursga qayta ko''paytirilmaydi.';

-- 1.3 v_kassa_card — eski ustunlar o'z semantikasida, `jami` kengaytirildi
--     ⚠️ DROP + CREATE
drop view if exists v_kassa_card;
create view v_kassa_card as
select
  p.id,
  p.code,
  p.name,
  p.kassa_turi,
  p.parent_id,
  coalesce(bp.uzs, 0::numeric)                            as uzs,
  coalesce(bu.fc,  0::numeric)                            as usd,             -- FAQAT USD bolasi
  coalesce(bu.uzs, 0::numeric)                            as usd_uzs,         -- FAQAT USD bolasi
  coalesce(bp.uzs, 0::numeric) + coalesce(ch.uzs_jami, 0::numeric) as jami,   -- o'zi + HAMMA valyuta bolalari
  u.id is not null                                        as has_usd,
  u.id                                                    as usd_account_id,
  p.subtitle,
  coalesce(ch.valyuta_soni, 0)                            as valyuta_soni     -- nechta valyuta bolasi bor
from accounts p
left join v_hisob_bal bp on bp.account_id = p.id
left join accounts u
       on u.parent_id = p.id and u.currency = 'USD'::text and u.is_active = true
left join v_hisob_bal bu on bu.account_id = u.id
left join lateral (
  select sum(v.uzs) as uzs_jami, count(*) as valyuta_soni
  from v_kassa_valyutalar v
  where v.parent_id = p.id
) ch on true
where p.section = 'pul'::text
  and p.currency = 'UZS'::text
  and p.is_active = true;

alter view v_kassa_card set (security_invoker = on);
revoke all on v_kassa_card from public, anon;
grant select on v_kassa_card to authenticated;

comment on view v_kassa_card is
  'Kassa kartalari. usd/usd_uzs/has_usd/usd_account_id — FAQAT USD bolasidan (eski UI uchun). '
  'jami — parentning o''zi + BARCHA valyuta bolalarining so''m ekvivalenti.';

-- 1.4 Valyuta kod bloklari — yangi valyuta hisobiga kod berish uchun
--     USD = 56xx (band). Yangilari 57xx dan boshlab.
create table if not exists valyuta_kod_blok (
  currency text primary key,
  prefix   text not null unique check (prefix ~ '^5[0-9]$')
);
insert into valyuta_kod_blok(currency, prefix) values ('USD','56'), ('CNY','57')
on conflict (currency) do nothing;

alter table valyuta_kod_blok enable row level security;
drop policy if exists valyuta_kod_blok_read on valyuta_kod_blok;
create policy valyuta_kod_blok_read on valyuta_kod_blok for select to authenticated using (true);
revoke all on valyuta_kod_blok from public, anon;
grant select on valyuta_kod_blok to authenticated;

-- 1.5 create_valyuta_child — kassaga valyuta bola-hisobi ochadi (idempotent)
create or replace function create_valyuta_child(p_parent uuid, p_currency text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role     text;
  v_parent   accounts%rowtype;
  v_cur      text := upper(btrim(coalesce(p_currency, '')));
  v_prefix   text;
  v_code     text;
  v_next     int;
  v_id       uuid;
begin
  -- auth: faqat admin
  select role into v_role from profiles where id = auth.uid();
  if v_role is distinct from 'admin' then
    raise exception 'Faqat admin valyuta hisobi ocha oladi';
  end if;

  if v_cur = '' or v_cur = 'UZS' then
    raise exception 'Valyuta noto''g''ri: %', p_currency;
  end if;

  select * into v_parent from accounts where id = p_parent;
  if not found then
    raise exception 'Kassa topilmadi: %', p_parent;
  end if;
  if v_parent.section is distinct from 'pul' or coalesce(v_parent.currency,'UZS') <> 'UZS' then
    raise exception 'Valyuta hisobi faqat so''m kassasiga qo''shiladi (%)', v_parent.code;
  end if;
  if not v_parent.is_active then
    raise exception 'Kassa faol emas: %', v_parent.code;
  end if;
  -- konteyner guruhga (5400) bola-valyuta ochilmaydi
  if v_parent.kassa_turi = 'xarajat_guruh' then
    raise exception 'Guruh hisobiga valyuta qo''shib bo''lmaydi (%)', v_parent.code;
  end if;

  -- idempotent: allaqachon bor bo'lsa o'shani qaytar
  select id into v_id
    from accounts
   where parent_id = p_parent and currency = v_cur and is_active = true
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  -- kod bloki: yo'q bo'lsa 57..59 dan bo'sh birini ol
  select prefix into v_prefix from valyuta_kod_blok where currency = v_cur;
  if v_prefix is null then
    select p into v_prefix
      from unnest(array['57','58','59']) as p
     where not exists (select 1 from valyuta_kod_blok b where b.prefix = p)
     limit 1;
    if v_prefix is null then
      raise exception 'Bo''sh kod bloki qolmadi (57–59 band). Kod sxemasini kengaytiring.';
    end if;
    insert into valyuta_kod_blok(currency, prefix) values (v_cur, v_prefix);
  end if;

  -- blok ichida keyingi raqam
  select coalesce(max(substring(code from 3 for 2)::int), 0) + 1 into v_next
    from accounts
   where code ~ ('^' || v_prefix || '[0-9]{2}$');
  if v_next > 99 then
    raise exception 'Kod bloki % to''ldi', v_prefix;
  end if;
  v_code := v_prefix || lpad(v_next::text, 2, '0');

  insert into accounts(code, name, type, section, currency, parent_id, kassa_turi, is_active, subtitle)
  values (v_code,
          v_parent.name || ' · ' || v_cur,
          'aktiv', 'pul', v_cur, p_parent, v_parent.kassa_turi, true, v_parent.subtitle)
  returning id into v_id;

  return v_id;
end $$;

revoke all on function create_valyuta_child(uuid, text) from public, anon;
grant execute on function create_valyuta_child(uuid, text) to authenticated;

comment on function create_valyuta_child(uuid, text) is
  'Kassaga valyuta bola-hisobi ochadi (admin, idempotent). Kod: valyuta_kod_blok prefiksi + ketma-ket raqam.';

-- 1.6 v_valyuta_royxat — tanlash uchun mavjud valyutalar
drop view if exists v_valyuta_royxat;
create view v_valyuta_royxat as
select distinct c.currency
from (
  select currency from accounts where currency is not null
  union select from_code from currency_rate
  union select to_code   from currency_rate
  union select currency  from valyuta_kod_blok
) c(currency)
where c.currency is distinct from 'UZS' and c.currency is not null;

alter view v_valyuta_royxat set (security_invoker = on);
revoke all on v_valyuta_royxat from public, anon;
grant select on v_valyuta_royxat to authenticated;

-- 1.7 Tekshiruv
do $$
begin
  perform 1 from v_kassa_card limit 1;
  raise notice 'v_kassa_card: % ta kassa, % tasida valyuta bolasi bor',
    (select count(*) from v_kassa_card),
    (select count(*) from v_kassa_card where valyuta_soni > 0);
  raise notice 'v_kassa_valyutalar: % ta valyuta satri (% xil valyuta)',
    (select count(*) from v_kassa_valyutalar),
    (select count(distinct currency) from v_kassa_valyutalar);
end $$;

-- 1-BOSQICH TUGADI ----------------------------------------------------


-- =====================================================================
-- 2-BOSQICH — Konvert: "Sotib olish" / "Sotish", juftlik-umumiy
-- ---------------------------------------------------------------------
-- Tasdiq oqimi O'ZGARMAYDI: koridor ichida → darrov, tashqarida → pending
-- → convert_approve/convert_reject. Eski imzolar saqlanadi:
--   convert_start(uuid,uuid,numeric,numeric,text)              -> v2'ga delegat
--   do_convert(uuid,uuid,numeric,numeric,numeric,text,text,text) -> v2'ga delegat
-- Eski pending so'rovlar approve bo'laveradi (imzo ham, semantika ham bir xil).
-- convert_request'ga ustun QO'SHILMAYDI — yo'nalish from/to currency'dan tiklanadi.
--
-- ⚠️ CREATE OR REPLACE (DROP emas) — mavjud GRANT'lar saqlanadi.
-- =====================================================================

-- 2.1 Koridor foizi — bitta joyda. Tarixan 2% edi, endi 5%.
create or replace function conv_koridor_foiz()
returns numeric language sql immutable as $$ select 5.0::numeric $$;

revoke all on function conv_koridor_foiz() from public, anon;
grant execute on function conv_koridor_foiz() to authenticated;

comment on function conv_koridor_foiz() is
  'Konvert kursi koridori, foizda. Bu yagona manba — UI ham shundan o''qiydi.';

-- 2.2 acc_fc_balance — hisobning O'Z valyutasidagi qoldig'i (sotishda kerak)
--     bal CTE mantig'i: debit>0 → +fc, aks holda −fc. Faqat posted + o'chirilmagan.
create or replace function acc_fc_balance(p_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(case when l.debit > 0 then coalesce(l.fc_amount, 0)
                           else - coalesce(l.fc_amount, 0) end), 0)
  from entry_line l
  join entry e on e.id = l.entry_id
  where l.account_id = p_id and e.status = 'posted' and e.is_deleted = false;
$$;

-- Ichki funksiya — to'g'ridan chaqirilmaydi (SECURITY DEFINER egasi orqali ishlaydi)
revoke all on function acc_fc_balance(uuid) from public, anon;

-- 2.3 do_convert_v2 — fc_amount HAR DOIM valyuta-hisob satriga
--     (u Dt bo'ladimi — sotib olish, Kt bo'ladimi — sotish, farqi yo'q).
--     v_kassa_card/v_hisob_bal (debit>0 ? +fc : −fc) buni to'g'ri hisoblaydi.
create or replace function do_convert_v2(p_from uuid, p_to uuid, p_amount_uzs numeric,
                                         p_rate numeric, p_fc numeric, p_who text,
                                         p_note text, p_ext text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_entry uuid; v_fn text; v_tn text; v_fcur text; v_tcur text;
begin
  select name, coalesce(currency,'UZS') into v_fn, v_fcur from accounts where id = p_from;
  select name, coalesce(currency,'UZS') into v_tn, v_tcur from accounts where id = p_to;
  if v_fn is null or v_tn is null then
    raise exception 'Konvert: hisob topilmadi';
  end if;

  insert into entry(entry_date, description, source, status, fc_rate, ext_ref, created_by)
  values (current_date,
          'Konvert: ' || v_fn || ' -> ' || v_tn
            || ' · kurs ' || p_rate::text || coalesce(' · ' || p_note, ''),
          'manual', 'posted', p_rate, p_ext, p_who)
  returning id into v_entry;

  -- Dt: qabul qiluvchi
  insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
  values (v_entry, p_to, p_amount_uzs, 0,
          case when v_tcur <> 'UZS' then p_fc else null end);
  -- Kt: beruvchi
  insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
  values (v_entry, p_from, 0, p_amount_uzs,
          case when v_fcur <> 'UZS' then p_fc else null end);

  return v_entry;
end $$;

revoke all on function do_convert_v2(uuid,uuid,numeric,numeric,numeric,text,text,text) from public, anon;

-- 2.3b Eski do_convert — imzo saqlanadi, ichi v2'ga delegat.
--      CREATE OR REPLACE bo'lgani uchun mavjud GRANT'lar tegilmaydi.
create or replace function do_convert(p_from uuid, p_to uuid, p_amount numeric, p_rate numeric,
                                      p_fc numeric, p_who text, p_note text, p_ext text)
returns uuid
language sql
security definer
set search_path = public
as $$
  select do_convert_v2(p_from, p_to, p_amount, p_rate, p_fc, p_who, p_note, p_ext);
$$;

-- 2.4 conv_baza_kurs — juftlik uchun tayanch kurs (1 birlik valyuta necha so'm)
--     USD → aros_usd_rate(); bo'lmasa/boshqa valyuta → currency_rate'dagi oxirgisi;
--     teskari yo'nalish (UZS→X) bo'lsa 1/rate. Hech biri yo'q → null (koridorsiz).
create or replace function conv_baza_kurs(p_cur text)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare v numeric;
begin
  if p_cur = 'USD' then
    v := aros_usd_rate();
    if v is not null then return v; end if;
  end if;
  select rate into v from currency_rate
   where from_code = p_cur and to_code = 'UZS'
   order by rate_at desc, created_at desc limit 1;
  if v is not null then return v; end if;
  select case when rate > 0 then 1 / rate end into v from currency_rate
   where from_code = 'UZS' and to_code = p_cur
   order by rate_at desc, created_at desc limit 1;
  return v;
end $$;

revoke all on function conv_baza_kurs(text) from public, anon;
grant execute on function conv_baza_kurs(text) to authenticated;  -- UI koridorni ko'rsatadi

-- 2.5 convert_start_v2 — yo'nalish from/to valyutasidan aniqlanadi
--     UZS → X : SOTIB OLISH, p_amount so'mda,     fc = round(p_amount / p_rate, 2)
--     X → UZS : SOTISH,      p_amount valyutada,  so'm = round(p_amount * p_rate, 2)
--     p_rate HAR DOIM: 1 birlik valyuta necha so'm.
create or replace function convert_start_v2(p_from uuid, p_to uuid, p_amount numeric,
                                            p_rate numeric, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_who text; v_foiz numeric; v_baza numeric; v_lo numeric; v_hi numeric;
  v_uzs numeric; v_fc numeric; v_cur text; v_yon text;
  v_bal numeric; v_entry uuid; v_req uuid;
  f accounts%rowtype; t accounts%rowtype;
  v_fcur text; v_tcur text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'Avtorizatsiya kerak');
  end if;
  select coalesce(full_name, 'foydalanuvchi') into v_who from profiles where id = auth.uid();

  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('ok', false, 'error', 'Summa notogri');
  end if;
  if p_rate is null or p_rate <= 0 then
    return jsonb_build_object('ok', false, 'error', 'Kurs notogri');
  end if;

  select * into f from accounts where id = p_from;
  select * into t from accounts where id = p_to;
  if f.id is null or t.id is null then
    return jsonb_build_object('ok', false, 'error', 'Hisob topilmadi');
  end if;
  if p_from = p_to then
    return jsonb_build_object('ok', false, 'error', 'Bir hisobning ozida konvert bolmaydi');
  end if;
  if not f.is_active or not t.is_active then
    return jsonb_build_object('ok', false, 'error', 'Hisob faol emas');
  end if;

  -- Filial asosiy kassasi Aros bilan sinxronlanadi — ikkala tomonda ham taqiq
  if f.kassa_turi = 'filial' or t.kassa_turi = 'filial' then
    return jsonb_build_object('ok', false,
      'error', 'Filial asosiy kassasida konvert qilib bolmaydi (Aros bilan sinxronlanadi). Xarajat kassasidan foydalaning.');
  end if;
  -- 5400 konteyner — unga to'g'ridan pul yozilmaydi
  if f.kassa_turi = 'xarajat_guruh' or t.kassa_turi = 'xarajat_guruh' then
    return jsonb_build_object('ok', false, 'error', 'Guruh hisobida konvert qilib bolmaydi');
  end if;

  v_fcur := coalesce(f.currency, 'UZS');
  v_tcur := coalesce(t.currency, 'UZS');

  if v_fcur = 'UZS' and v_tcur = 'UZS' then
    return jsonb_build_object('ok', false, 'error', 'Ikkala hisob ham somda — bu transfer, konvert emas');
  elsif v_fcur <> 'UZS' and v_tcur <> 'UZS' then
    return jsonb_build_object('ok', false, 'error', 'Avval somga soting, keyin ikkinchi valyutani soting');
  elsif v_fcur = 'UZS' then
    -- SOTIB OLISH: so'm kassasidan uning valyuta bolasiga
    v_yon := 'sotib_olish'; v_cur := v_tcur;
    if t.parent_id is distinct from f.id then
      return jsonb_build_object('ok', false, 'error', 'Valyuta hisobi shu kassaga tegishli emas');
    end if;
    v_uzs := p_amount;
    v_fc  := round(p_amount / p_rate, 2);
    v_bal := acc_balance(p_from);
    if v_bal < v_uzs then
      return jsonb_build_object('ok', false, 'error', 'Kassada yetarli pul yoq', 'qoldiq', v_bal);
    end if;
  else
    -- SOTISH: valyuta bolasidan o'z so'm kassasiga
    v_yon := 'sotish'; v_cur := v_fcur;
    if f.parent_id is distinct from t.id then
      return jsonb_build_object('ok', false, 'error', 'Valyuta hisobi shu kassaga tegishli emas');
    end if;
    v_fc  := p_amount;
    v_uzs := round(p_amount * p_rate, 2);
    v_bal := acc_fc_balance(p_from);
    if v_bal < v_fc then
      return jsonb_build_object('ok', false,
        'error', 'Kassada yetarli ' || v_cur || ' yoq', 'qoldiq', v_bal);
    end if;
  end if;

  v_foiz := conv_koridor_foiz();
  v_baza := conv_baza_kurs(v_cur);

  -- Kurs tarixi bo'lmasa koridor yo'q — qarorni admin qabul qiladi
  if v_baza is null then
    insert into convert_request(from_account, to_account, amount, rate, fc_amount,
                                aros_rate, note, requested_by_name)
    values (p_from, p_to, v_uzs, p_rate, v_fc, null, p_note, v_who)
    returning id into v_req;
    return jsonb_build_object('ok', false, 'status', 'pending', 'request_id', v_req,
      'yonalish', v_yon, 'currency', v_cur, 'fc_amount', v_fc, 'amount', v_uzs,
      'aros_rate', null, 'lo', null, 'hi', null, 'foiz', v_foiz,
      'error', 'Bu juftlik uchun kurs tarixi yoq — admin tasdigi kerak');
  end if;

  v_lo := round(v_baza * (1 - v_foiz / 100), 4);
  v_hi := round(v_baza * (1 + v_foiz / 100), 4);

  if p_rate >= v_lo and p_rate <= v_hi then
    v_entry := do_convert_v2(p_from, p_to, v_uzs, p_rate, v_fc, v_who, p_note, null);
    return jsonb_build_object('ok', true, 'status', 'done',
      'entry_id', v_entry, 'yonalish', v_yon, 'currency', v_cur,
      'fc_amount', v_fc, 'amount', v_uzs,
      'aros_rate', v_baza, 'lo', v_lo, 'hi', v_hi, 'foiz', v_foiz);
  end if;

  insert into convert_request(from_account, to_account, amount, rate, fc_amount,
                              aros_rate, note, requested_by_name)
  values (p_from, p_to, v_uzs, p_rate, v_fc, v_baza, p_note, v_who)
  returning id into v_req;

  return jsonb_build_object('ok', false, 'status', 'pending', 'request_id', v_req,
    'yonalish', v_yon, 'currency', v_cur, 'fc_amount', v_fc, 'amount', v_uzs,
    'aros_rate', v_baza, 'lo', v_lo, 'hi', v_hi, 'foiz', v_foiz,
    'error', 'Kurs tayanch kursdan ' || trim(to_char(v_foiz, 'FM990.99'))
             || '% dan kop farq qilyapti. Admin tasdigi kerak.');
end $$;

revoke all on function convert_start_v2(uuid,uuid,numeric,numeric,text) from public, anon;
grant execute on function convert_start_v2(uuid,uuid,numeric,numeric,text) to authenticated;

-- 2.5b Eski convert_start — imzo saqlanadi, ichi v2'ga delegat.
--      UZS→USD chegarasi olib tashlandi (v2 umumiy hal qiladi).
create or replace function convert_start(p_from uuid, p_to uuid, p_amount numeric,
                                         p_rate numeric, p_note text default null)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select convert_start_v2(p_from, p_to, p_amount, p_rate, p_note);
$$;

-- 2.6 convert_approve — yo'nalishga qarab balans tekshiruvi + do_convert_v2.
--     Koridor QAYTA TEKSHIRILMAYDI (mavjud xatti-harakat, ataylab).
create or replace function convert_approve(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r convert_request; v_entry uuid; v_who text; v_bal numeric; v_fcur text;
begin
  if not is_admin() then
    return jsonb_build_object('ok', false, 'error', 'Faqat admin tasdiqlay oladi');
  end if;
  select coalesce(full_name, 'admin') into v_who from profiles where id = auth.uid();

  select * into r from convert_request where id = p_id;
  if r.id is null then return jsonb_build_object('ok', false, 'error', 'Sorov topilmadi'); end if;
  if r.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'Sorov allaqachon hal qilingan: ' || r.status);
  end if;

  select coalesce(currency, 'UZS') into v_fcur from accounts where id = r.from_account;

  if v_fcur = 'UZS' then
    -- sotib olish: so'm qoldig'i
    v_bal := acc_balance(r.from_account);
    if v_bal < r.amount then
      return jsonb_build_object('ok', false, 'error', 'Kassada yetarli pul yoq', 'qoldiq', v_bal);
    end if;
  else
    -- sotish: valyuta qoldig'i
    v_bal := acc_fc_balance(r.from_account);
    if v_bal < r.fc_amount then
      return jsonb_build_object('ok', false,
        'error', 'Kassada yetarli ' || v_fcur || ' yoq', 'qoldiq', v_bal);
    end if;
  end if;

  v_entry := do_convert_v2(r.from_account, r.to_account, r.amount, r.rate, r.fc_amount,
                           r.requested_by_name, coalesce(r.note,'') || ' (admin: ' || v_who || ')',
                           'conv:' || r.id::text);

  update convert_request
  set status = 'approved', decided_by_name = v_who, decided_at = now(), entry_id = v_entry
  where id = p_id;

  return jsonb_build_object('ok', true, 'status', 'approved', 'entry_id', v_entry);
end $$;

-- convert_reject o'zgarmaydi — yo'nalishga bog'liq emas.

-- 2.7 Tekshiruv
do $$
declare v_n int;
begin
  -- imzolar joyidami (eski klient va eski pending so'rovlar uchun)
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname, pg_get_function_identity_arguments(p.oid)) in (
       ('convert_start',  'p_from uuid, p_to uuid, p_amount numeric, p_rate numeric, p_note text'),
       ('do_convert',     'p_from uuid, p_to uuid, p_amount numeric, p_rate numeric, p_fc numeric, p_who text, p_note text, p_ext text')
     );
  if v_n <> 2 then
    raise exception 'Eski imzolar buzildi (topildi: %). Eski pending sorovlar approve bolmay qoladi.', v_n;
  end if;
  raise notice 'Konvert: koridor +/- % foiz, USD tayanch kurs: %',
    conv_koridor_foiz(), coalesce(conv_baza_kurs('USD')::text, 'yoq');
end $$;

-- 2-BOSQICH TUGADI ----------------------------------------------------
