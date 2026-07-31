-- =====================================================================
--  PROVODKA — PUL TURI (naqd / Click / Payme) kassa ostida bola-hisob
-- ---------------------------------------------------------------------
--  MODEL (tanlangan yo'l):
--    Tur = kassaning bola-hisobi. Bu valyuta bolalari bilan AYNAN bir xil
--    naqsh, faqat currency='UZS' va yangi `pul_turi` ustuni bilan farqlanadi.
--
--      5011 Toshkent Kassa            (parent, currency=UZS, pul_turi=NULL)
--       ├ 51xx  · Naqd                (currency=UZS, pul_turi='naqd')
--       ├ 51xx  · Click               (currency=UZS, pul_turi='click')
--       ├ 51xx  · Payme               (currency=UZS, pul_turi='payme')
--       └ 56xx  · USD                 (currency=USD, pul_turi=NULL)  ← mavjud
--
--  Nega shunday:
--    • Qoldiq entry_line'dan keladi (v_hisob_bal) — CLAUDE.md'dagi asosiy
--      qoida buzilmaydi, "ikkinchi haqiqat" paydo bo'lmaydi.
--    • Yechish = oddiy entry (Dt xarajat / Kt tur-bolasi). Yangi yozuv yo'li
--      qo'shilmaydi, ya'ni entry_line guard triggeri avtomat qamrab oladi.
--    • Konvert = bola→bola transferi, mavjud mantiq.
--    • Jurnalda hisob nomi turni allaqachon aytadi — alohida teg ustuni shart emas.
--
--  BU FAYL ADDITIVE:
--    • yangi ustun `add column if not exists`
--    • yangi jadval/view/funksiya
--    • MAVJUD funksiyalar `create or replace` — IMZO O'ZGARMAYDI
--    • v_kassa_card DROP+CREATE (PROVODKA_KASSA2.sql'da ham shunday qilingan;
--      ustunlar nomi/ma'nosi saqlanadi, oxiriga yangilari qo'shiladi)
--  Bir necha marta RUN qilish xavfsiz (idempotent).
--
--  ⚠️ v_kassa_toliq ta'rifi repoda yo'q — u QAYTA YOZILMAYDI. Uning ustiga
--     yangi `v_kassa_tanlov` view qo'yiladi (6-bo'lim).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. accounts.pul_turi
-- ---------------------------------------------------------------------
alter table accounts add column if not exists pul_turi text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'accounts_pul_turi_chk') then
    alter table accounts add constraint accounts_pul_turi_chk
      check (pul_turi is null or pul_turi in ('naqd','click','payme'));
  end if;
end $$;

-- Bitta kassada bir tur ikki marta bo'lmasin (faol hisoblar orasida)
create unique index if not exists accounts_parent_turi_uniq
  on accounts(parent_id, pul_turi) where pul_turi is not null and is_active;

comment on column accounts.pul_turi is
  'Pul turi bola-hisobi: naqd|click|payme. NULL = oddiy kassa yoki valyuta bolasi.';


-- ---------------------------------------------------------------------
-- 2. Kod bloklari — tur bolalariga kod berish
-- ---------------------------------------------------------------------
-- Kod 4 belgili: 2 belgili prefiks + 2 raqam (create_valyuta_child bilan bir xil).
-- Band prefikslar: 50 kassa, 52 filial, 54 hodim, 56 USD, 57 CNY, 58/59 valyutaga zaxira.
-- Turlar uchun: 55 (asosiy), to'lsa 53, keyin 51. Blok to'lsa keyingisiga o'tadi.
create table if not exists pul_turi_kod_blok (
  nav    int primary key,               -- tartib: kichigi avval ishlatiladi
  prefix text not null unique check (prefix ~ '^5[0-9]$')
);
insert into pul_turi_kod_blok(nav, prefix) values (1,'55'), (2,'53'), (3,'51')
on conflict (nav) do nothing;

comment on table pul_turi_kod_blok is
  'Pul turi bola-hisoblariga kod beriladigan prefikslar (nav tartibida). Valyuta bloklariga tegmaydi.';


-- ---------------------------------------------------------------------
-- 3. create_pul_turi_child — kassaga tur bola-hisobi ochadi
-- ---------------------------------------------------------------------
-- create_valyuta_child bilan bir xil xulq: admin, idempotent, SECURITY DEFINER.
create or replace function create_pul_turi_child(p_parent uuid, p_turi text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role   text;
  v_parent accounts%rowtype;
  v_turi   text := lower(btrim(coalesce(p_turi, '')));
  v_lbl    text;
  v_prefix text;
  v_next   int;
  v_code   text;
  v_id     uuid;
begin
  select role into v_role from profiles where id = auth.uid();
  if v_role is distinct from 'admin' then
    raise exception 'Faqat admin tur hisobi ocha oladi';
  end if;

  if v_turi not in ('naqd','click','payme') then
    raise exception 'Pul turi noto''g''ri: % (naqd|click|payme)', p_turi;
  end if;
  v_lbl := case v_turi when 'naqd' then 'Naqd' when 'click' then 'Click' else 'Payme' end;

  select * into v_parent from accounts where id = p_parent;
  if not found then
    raise exception 'Kassa topilmadi: %', p_parent;
  end if;
  if v_parent.section is distinct from 'pul' or coalesce(v_parent.currency,'UZS') <> 'UZS' then
    raise exception 'Tur hisobi faqat so''m kassasiga qo''shiladi (%)', v_parent.code;
  end if;
  if not v_parent.is_active then
    raise exception 'Kassa faol emas: %', v_parent.code;
  end if;
  -- Konteyner guruh (5400) — unga to'g'ridan pul yozilmaydi
  if v_parent.kassa_turi = 'xarajat_guruh' then
    raise exception 'Guruh hisobiga tur qo''shib bo''lmaydi (%)', v_parent.code;
  end if;
  -- Bola-hisobning o'zi ota bo'lolmaydi (ikki qavat bo'lmasin)
  if v_parent.parent_id is not null then
    raise exception 'Bola-hisobga tur qo''shib bo''lmaydi (%)', v_parent.code;
  end if;

  -- idempotent
  select id into v_id
    from accounts
   where parent_id = p_parent and pul_turi = v_turi and is_active = true
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  -- Bo'sh joyi bor birinchi blok (nav tartibida). Blokdagi eng katta kod + 1;
  -- faol bo'lmagan eski hisoblar ham hisobga olinadi (kod unique).
  select b.prefix, coalesce(mx.n, 0) + 1
    into v_prefix, v_next
    from pul_turi_kod_blok b
    left join lateral (
      select max(substring(a.code from 3 for 2)::int) as n
        from accounts a
       where a.code ~ ('^' || b.prefix || '[0-9]{2}$')
    ) mx on true
   where coalesce(mx.n, 0) + 1 <= 99
   order by b.nav
   limit 1;

  if v_prefix is null then
    raise exception 'Tur kod bloklari to''ldi (55/53/51). pul_turi_kod_blok''ga yangi prefiks qo''shing.';
  end if;
  v_code := v_prefix || lpad(v_next::text, 2, '0');

  insert into accounts(code, name, type, section, currency, parent_id,
                       kassa_turi, is_active, subtitle, pul_turi)
  values (v_code,
          v_parent.name || ' · ' || v_lbl,
          'aktiv', 'pul', 'UZS', p_parent,
          v_parent.kassa_turi, true, v_parent.subtitle, v_turi)
  returning id into v_id;

  return v_id;
end $$;

revoke all on function create_pul_turi_child(uuid, text) from public, anon;
grant execute on function create_pul_turi_child(uuid, text) to authenticated;

comment on function create_pul_turi_child(uuid, text) is
  'Kassaga pul turi (naqd|click|payme) bola-hisobini ochadi. Admin, idempotent.';


-- ---------------------------------------------------------------------
-- 4. v_kassa_turlar — parentning tur bolalari (v_kassa_valyutalar naqshida)
-- ---------------------------------------------------------------------
drop view if exists v_kassa_turlar;
create view v_kassa_turlar as
select
  c.parent_id,
  c.id                        as account_id,
  c.code,
  c.name,
  c.pul_turi,
  coalesce(b.uzs, 0::numeric) as qoldiq
from accounts c
left join v_hisob_bal b on b.account_id = c.id
where c.section = 'pul'::text
  and c.is_active = true
  and c.parent_id is not null
  and c.pul_turi is not null;

alter view v_kassa_turlar set (security_invoker = on);
revoke all on v_kassa_turlar from public, anon;
grant select on v_kassa_turlar to authenticated;

comment on view v_kassa_turlar is
  'Kassaning pul turi satrlari (naqd/click/payme). qoldiq — so''mda, entry_line''dan.';


-- ---------------------------------------------------------------------
-- 5. v_kassa_card — tur bolalari KARTA BO'LIB CHIQMAYDI, lekin jamiga kiradi
-- ---------------------------------------------------------------------
-- ⚠️ NEGA QAYTA YOZILYAPTI (ikki sabab, ikkalasi ham majburiy):
--   a) Eski WHERE `p.currency='UZS' and section='pul' and is_active` — tur
--      bolalari ham shu shartga tushadi, ya'ni HAR BIRI alohida karta bo'lib
--      chiqib ketardi. Endi `p.pul_turi is null` qo'shildi.
--   b) Eski `jami` = parent + v_kassa_valyutalar (u `currency <> 'UZS'` bilan
--      filtrlaydi) — tur bolalari UZS bo'lgani uchun jamiga KIRMAY qolardi,
--      ya'ni naqd/Click'dagi pul kassa jamisida ko'rinmasdi. Endi qo'shildi.
-- Eski ustunlar nomi va ma'nosi o'zgarmadi; yangilari OXIRIGA qo'shildi.
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
  coalesce(bp.uzs, 0::numeric)
    + coalesce(ch.uzs_jami, 0::numeric)
    + coalesce(tr.turi_jami, 0::numeric)                  as jami,            -- o'zi + valyuta bolalari + TUR bolalari
  u.id is not null                                        as has_usd,
  u.id                                                    as usd_account_id,
  p.subtitle,
  coalesce(ch.valyuta_soni, 0)                            as valyuta_soni,
  -- yangi ustunlar (oxirida — eski klient ularni ko'rmasa ham ishlayveradi)
  coalesce(tr.naqd,  0::numeric)                          as naqd,
  coalesce(tr.click, 0::numeric)                          as click,
  coalesce(tr.payme, 0::numeric)                          as payme,
  coalesce(tr.turi_soni, 0)                               as turi_soni
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
left join lateral (
  select sum(t.qoldiq)                                              as turi_jami,
         count(*)                                                   as turi_soni,
         sum(t.qoldiq) filter (where t.pul_turi = 'naqd')           as naqd,
         sum(t.qoldiq) filter (where t.pul_turi = 'click')          as click,
         sum(t.qoldiq) filter (where t.pul_turi = 'payme')          as payme
  from v_kassa_turlar t
  where t.parent_id = p.id
) tr on true
where p.section = 'pul'::text
  and p.currency = 'UZS'::text
  and p.is_active = true
  and p.pul_turi is null;          -- ← tur bolalari alohida karta bo'lmaydi

alter view v_kassa_card set (security_invoker = on);
revoke all on v_kassa_card from public, anon;
grant select on v_kassa_card to authenticated;

comment on view v_kassa_card is
  'Kassa kartalari. usd/usd_uzs/has_usd/usd_account_id — FAQAT USD bolasidan (eski UI uchun). '
  'jami — parent + BARCHA valyuta bolalari + BARCHA tur bolalari. '
  'naqd/click/payme — tur bolalarining qoldig''i; tur bolalari alohida karta bo''lib chiqmaydi.';


-- ---------------------------------------------------------------------
-- 6. v_kassa_tanlov — tanlash ro'yxatlari uchun (v_kassa_toliq + pul_turi)
-- ---------------------------------------------------------------------
-- v_kassa_toliq ta'rifi repoda yo'q, shuning uchun UNGA TEGILMAYDI.
-- Uning ustiga qo'shimcha ustunli view qo'yamiz — klient shundan o'qiydi va
-- tur bolalarini (konvert dropdowni kabi joylarda) filtrlay oladi.
create or replace view v_kassa_tanlov as
select t.*, a.pul_turi
from v_kassa_toliq t
join accounts a on a.id = t.id;

alter view v_kassa_tanlov set (security_invoker = on);
revoke all on v_kassa_tanlov from public, anon;
grant select on v_kassa_tanlov to authenticated;

comment on view v_kassa_tanlov is
  'v_kassa_toliq + pul_turi. Tanlash ro''yxatlari shundan o''qiydi (tur bolalarini ajratish uchun).';


-- ---------------------------------------------------------------------
-- 7.0 kassa_root — "bu hisob qaysi KASSAGA tegishli"
-- ---------------------------------------------------------------------
-- Bitta ta'rif, ikki joyda ishlatiladi (perm_op_key va convert_start_v2) —
-- mantiq ikkiga bo'linib, vaqt o'tib bir-biridan ajralib ketmasin.
--
-- ⚠️ parent_id UCH ma'noli: (1) valyuta bolasi, (2) pul turi bolasi,
--    (3) hodim kassasining 5400 konteyner guruhga a'zoligi.
--    (3) bola-hisob EMAS — hodim kassasi mustaqil kassa, o'z id'sini qaytaradi.
create or replace function kassa_root(p_id uuid)
returns uuid
language sql
stable
as $$
  select case
           when a.parent_id is not null
                and (coalesce(a.currency,'UZS') <> 'UZS' or a.pul_turi is not null)
             then a.parent_id
           else a.id
         end
    from accounts a where a.id = p_id;
$$;

revoke all on function kassa_root(uuid) from public, anon;
grant execute on function kassa_root(uuid) to authenticated, service_role;

comment on function kassa_root(uuid) is
  'Hisob qaysi kassaga tegishli: valyuta/tur bolasi -> parent, aks holda o''zi. '
  'Hodim kassasi (parent=5400) o''z id''sini qaytaradi — u bola-hisob emas.';


-- ---------------------------------------------------------------------
-- 7. perm_op_key — TUR BOLALARI HAM RUXSATNI PARENTDAN OLADI
-- ---------------------------------------------------------------------
-- ⚠️ Bu tuzatmasiz tur bolalari ishlamaydi. Eski shart faqat
--    `currency <> 'UZS'` edi; tur bolalari esa UZS. Ular "hodim kassasi"
--    shoxiga tushib, o'z id'si bilan tekshirilardi — ya'ni parent kassaga
--    ruxsati bor foydalanuvchi uning naqd/Click hisobida ishlay olmasdi
--    (entry_line guard triggeri 42501 berardi).
-- parent_id ikki ma'noli (valyuta juftligi + guruh a'zoligi + tur bolasi),
-- shuning uchun shart aniq yozilgan: hodim kassasi (parent=5400, UZS,
-- pul_turi IS NULL) avvalgidek O'Z id'sini ishlatadi.
create or replace function perm_op_key(p_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select kassa_root(p_id);
$$;

revoke all on function perm_op_key(uuid) from public, anon;
grant execute on function perm_op_key(uuid) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- 8. v_filial_turi_hisob — n8n auto-sync uchun qidiruv jadvali
-- ---------------------------------------------------------------------
-- n8n (Aros Provodka - Auto Sync) filial balansini TUR bo'yicha yozadigan
-- bo'lsa, unga "shu filialning shu turdagi hisobi qaysi" kerak bo'ladi.
-- Aros cachier id = accounts.filial_ref.
create or replace view v_filial_turi_hisob as
select
  p.filial_ref,
  p.id        as kassa_id,
  p.code      as kassa_code,
  p.name      as kassa_name,
  t.pul_turi,
  t.account_id,
  t.code      as turi_code,
  t.qoldiq
from accounts p
join v_kassa_turlar t on t.parent_id = p.id
where p.kassa_turi = 'filial'
  and p.filial_ref is not null
  and p.is_active = true;

alter view v_filial_turi_hisob set (security_invoker = on);
revoke all on v_filial_turi_hisob from public, anon;
grant select on v_filial_turi_hisob to authenticated, service_role;

comment on view v_filial_turi_hisob is
  'n8n uchun: filial_ref + pul_turi -> account_id. Auto-sync tur bo''yicha yozishi uchun.';



-- ---------------------------------------------------------------------
-- 9. convert_start_v2 — TUR BOLASIDAN ham konvert qilish mumkin
-- ---------------------------------------------------------------------
-- IMZO O'ZGARMAYDI. Tana PROVODKA_KASSA2.sql'dagidan KO'CHIRILGAN,
-- faqat IKKI tekshiruv qatori almashtirilgan (boshqa hech nima):
--
--   eski:  if t.parent_id is distinct from f.id then      (sotib olish)
--   yangi: if kassa_root(p_to) is distinct from kassa_root(p_from) then
--
--   eski:  if f.parent_id is distinct from t.id then      (sotish)
--   yangi: if kassa_root(p_from) is distinct from kassa_root(p_to) then
--
-- SABAB: pul endi kassaning naqd/Click/Payme bolasida turadi. Eski shart
-- "valyuta hisobi AYNAN shu hisobning bolasi bo'lsin" degani edi — naqd
-- bolasidan dollar sotib olganda USD hisobining parenti kassa (5011), naqd
-- bolasi (55xx) emas, shuning uchun rad etilardi. Endi ikkala tomon AYNI
-- KASSAGA tegishli bo'lsa yetarli.
--
-- Xavfsizlik o'zgarmadi: filial/guruh taqiqlari, konvert ruxsati, qoldiq
-- tekshiruvi, koridor va pending mantiqi — hammasi joyida.
-- Eski convert_start(...) imzosi ham shu funksiyaga delegat bo'lib qolaveradi.

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
  v_ruxsat boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'Avtorizatsiya kerak');
  end if;

  -- Konvert ruxsati (PROVODKA_PERMS.sql). Ruxsat tizimi hali o'rnatilmagan
  -- bo'lsa — funksiya yo'q, chaqirilmaydi va hamma konvert qila oladi (eski holat).
  -- to_regprocedure orqali: ikki SQL fayl bir-birining tartibiga bog'lanib qolmaydi.
  if to_regprocedure('public.perm_can_convert()') is not null then
    execute 'select perm_can_convert()' into v_ruxsat;
    if not coalesce(v_ruxsat, true) then
      return jsonb_build_object('ok', false, 'error', 'Konvert ruxsati yoq');
    end if;
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
    -- TUR BOLALARI: pul naqd/Click/Payme bolasidan ham chiqishi mumkin, shuning uchun
    -- "aynan shu hisobning bolasi" emas, "AYNI KASSAGA tegishli" deb tekshiriladi.
    if kassa_root(p_to) is distinct from kassa_root(p_from) then
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
    -- Sotishda ham: so'm ayni kassaning istalgan so'm hisobiga (parent yoki tur bolasi) tushadi
    if kassa_root(p_from) is distinct from kassa_root(p_to) then
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

-- =====================================================================
--  TEKSHIRUV (RUN qilgandan keyin)
-- =====================================================================

-- 8.1 Ustun va cheklov o'rnatildimi
select column_name, data_type
  from information_schema.columns
 where table_name = 'accounts' and column_name = 'pul_turi';

-- 8.2 v_kassa_card ustunlari (naqd/click/payme/turi_soni oxirida turishi kerak)
select column_name, ordinal_position
  from information_schema.columns
 where table_name = 'v_kassa_card'
 order by ordinal_position;

-- 8.3 Hozircha tur bolasi yo'q — kartalar avvalgidek ko'rinishi kerak.
--     jami o'zgarmaganiga ishonch: naqd/click/payme hammasi 0 bo'lishi kerak.
select code, name, uzs, jami, naqd, click, payme, turi_soni
  from v_kassa_card
 order by code;

-- 8.4 perm_op_key: valyuta bolasi -> parent, hodim kassasi -> o'zi
select a.code, a.name, a.currency, a.pul_turi,
       (a.id = perm_op_key(a.id)) as ozi_bilan
  from accounts a
 where a.section = 'pul' and a.is_active
 order by a.code;

-- 8.5 Tur hisobi ochish (MISOL — kerakli kassa id bilan almashtiring):
-- select create_pul_turi_child('<kassa-uuid>', 'naqd');
-- select create_pul_turi_child('<kassa-uuid>', 'click');
-- select create_pul_turi_child('<kassa-uuid>', 'payme');

-- 8.6 Konvert: tur bolasidan valyuta sotib olish endi o'tadi.
--     kassa_root ikki tomonda bir xil qiymat berishi kerak:
select a.code, a.name, a.pul_turi, a.currency,
       (select r.code from accounts r where r.id = kassa_root(a.id)) as ildiz_kassa
  from accounts a
 where a.section = 'pul' and a.is_active
 order by ildiz_kassa, a.code;
