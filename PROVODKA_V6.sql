-- =====================================================================
-- PROVODKA — V6
-- ---------------------------------------------------------------------
-- Xarajatga QO'SHIMCHA metadata: filial(lar) + davr oralig'i.
--   entry.filial_ids UUID[]  — tanlangan filial kassalari (multiselect).
--   entry.davr_start/davr_end DATE — sana oralig'i (ixtiyoriy).
--   MUHIM: bu FAQAT metadata. Pul faqat tanlangan kassadan yechiladi;
--   entry_line O'ZGARMAYDI (2 satr: Dt modda / Kt kassa). Buxgalteriya emas.
--
-- accounts moddasiga 2 bayroq (chek_majburiy naqshi):
--   izoh_majburiy, davr_majburiy — xarajat moddasi uchun majburiylik.
--
-- set_modda_flag(p_account, p_flag, p_bool) — 'chek'|'izoh'|'davr' bir
-- umumiy admin RPC (eski set_chek_majburiy ham qoladi — buzilmasin).
--
-- Idempotent. Asilbek qo'lda RUN qiladi. REVOKE anon. Xatoda RAISE EXCEPTION.
-- entry insert yo'li o'zgarmaydi (faqat 3 ustun qo'shiladi).
-- =====================================================================


-- =====================================================================
-- 1-BO'LIM — entry qo'shimcha ustunlar (metadata)
-- ---------------------------------------------------------------------
-- filial_ids: accounts (kassa_turi='filial') id'lari massivi. Default bo'sh.
-- davr_start/end: xarajat qaysi davrga tegishli (kalendar majburiy bo'lsa).
-- =====================================================================

alter table entry
  add column if not exists filial_ids uuid[] not null default '{}',
  add column if not exists davr_start date,
  add column if not exists davr_end date;

comment on column entry.filial_ids is
  'Xarajat qaysi filial(lar)ga tegishli — FAQAT metadata, pul harakatiga ta''sir qilmaydi.';
comment on column entry.davr_start is
  'Xarajat davri boshi (ixtiyoriy; modda.davr_majburiy=true bo''lsa to''ldiriladi).';
comment on column entry.davr_end is
  'Xarajat davri oxiri (ixtiyoriy; modda.davr_majburiy=true bo''lsa to''ldiriladi).';


-- =====================================================================
-- 2-BO'LIM — accounts majburiylik bayroqlari
-- ---------------------------------------------------------------------
-- izoh_majburiy: hodim yozuvida izoh (description) bo'sh bo'lmasligi shart.
-- davr_majburiy: davr_start/end to'ldirilishi shart.
-- Default false — mavjud moddalar o'zgarmaydi.
-- =====================================================================

alter table accounts
  add column if not exists izoh_majburiy boolean not null default false,
  add column if not exists davr_majburiy boolean not null default false;

comment on column accounts.izoh_majburiy is
  'Xarajat moddasi: hodim yozuvida izoh majburiymi (hodim.html tekshiradi).';
comment on column accounts.davr_majburiy is
  'Xarajat moddasi: davr (start–end) sanasi majburiymi (hodim.html tekshiradi).';


-- =====================================================================
-- 3-BO'LIM — set_modda_flag() — umumiy admin RPC
-- ---------------------------------------------------------------------
-- p_flag ∈ {'chek','izoh','davr'} → mos ustunni yangilaydi. Boshqa flag
-- rad etiladi (injection'ga yo'l yo'q — ustun nomi whitelist'dan).
-- Admin only, SECURITY DEFINER (RLS'siz update). REVOKE anon.
-- =====================================================================

-- DIQQAT: dinamik `execute format(... %I ...)` ISHLATILMAYDI — static 3 ta UPDATE.
-- Xabarlar ataylab SODDA (apostrof/`%` yo'q) — dashboard paste'i buzmasin.
create or replace function set_modda_flag(p_account uuid, p_flag text, p_bool boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Faqat admin' using errcode = '42501';
  end if;
  if p_flag = 'chek' then
    update accounts set chek_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'izoh' then
    update accounts set izoh_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'davr' then
    update accounts set davr_majburiy = coalesce(p_bool, false) where id = p_account;
  else
    raise exception 'Nomalum bayroq';
  end if;
end $$;

revoke all on function set_modda_flag(uuid, text, boolean) from public, anon;
grant execute on function set_modda_flag(uuid, text, boolean) to authenticated;

comment on function set_modda_flag(uuid, text, boolean) is
  'Admin: xarajat moddasi bayrogi (chek|izoh|davr) yoqadi yoki ochiradi.';


-- =====================================================================
-- 4-BO'LIM — filial kassalari tanlovi (frontend multiselect uchun)
-- ---------------------------------------------------------------------
-- Faqat filial kassalari (kassa_turi='filial'), faol. id, code, name.
-- DIQQAT: nom `v_filial_tanlov` — mavjud `v_filial_royxat` (warehouse_id/filial,
-- jurnal.html filiali) BILAN CHALKASHMASIN. Bu accounts.id qaytaradi (filial_ids uchun).
-- SECURITY INVOKER (oddiy o'qish; accounts allaqachon authenticated'ga ochiq).
-- =====================================================================

create or replace view v_filial_tanlov
with (security_invoker = on) as
  select id, code, name, subtitle
    from accounts
   where kassa_turi = 'filial'
     and coalesce(is_active, true) = true
   order by name, code;

comment on view v_filial_tanlov is
  'Xarajat metadata uchun filial kassalari ro''yxati (hodim.html multiselect; accounts.id).';
