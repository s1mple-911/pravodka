-- =====================================================================
-- PROVODKA — RBAC (rol-asoslangan ruxsat) — BRIEF_PROVODKA_RBAC.md
-- ---------------------------------------------------------------------
-- Maqsad: admin ROL yaratadi (masalan "Sotuvchi", "Bugalter"), rolga
-- AMALLAR (sahifalar), XARAJAT MODDALARI va OVQAT turlarini biriktiradi,
-- keyin hodimga bitta yoki bir nechta rol beradi. Hodim faqat rolidagi
-- narsani ko'radi/yozadi — SERVER darajasida (UI emas).
--
-- 🔴 ESKI `user_perms` / `perm_pages()` / `my_perms()` / `perm_has_page()` /
--    `perm_guard_entry_line()` (PUL cheklovi — kassa ko'rish/amaliyot)
--    BUZILMAYDI. Bu fayl ULARGA QO'SHILADI:
--   * `my_perms()` / `perm_has_page()` — imzo bir xil, ichiga ROL manbai
--     QO'SHILADI (sahifa ruxsati endi ikki manbadan: eski `allowed_pages`
--     VA rol amallari — union, pastga qara).
--   * XARAJAT MODDASI cheklovi — YANGI, ALOHIDA trigger
--     (`trg_rbac_guard_entry_line`) — mavjud `trg_perm_guard_entry_line`
--     (pul/kassa) ga TEGILMAYDI, ikkalasi bir vaqtda ishlaydi.
--   * OVQAT tur cheklovi — `rbac_ovqat_ok(text)` FUNKSIYA sifatida tayyor,
--     lekin `xarajat_saqlash_ovqat()` ICHIGA CHAQIRUV bu faylda QO'SHILMAYDI
--     (u fayl alohida — `PROVODKA_OVQAT_KECHKI.sql` — bilan qayta yoziladi;
--     chaqiruvni Fable keyingi bosqichda qo'shadi). Bu yerda faqat funksiya.
--
-- Qoidalar (mavjud fayllar bilan bir xil naqsh):
--   * idempotent (create or replace / if not exists / drop-create trigger)
--   * xato -> RAISE EXCEPTION (jimgina yutilmaydi)
--   * har SECURITY DEFINER funksiyada `set search_path = public`
--   * RLS: select — o'zi ((select auth.uid())) yoki is_admin(); YOZISH
--     POLICY YO'Q (faqat SECURITY DEFINER RPC yozadi, xuddi user_perms kabi)
--   * REVOKE anon; admin doim cheklanmagan; noma'lum kalit -> XATO (rad, jimgina tashlanmaydi)
--   * tezlik: `(select auth.uid())` InitPlan naqshi, indekslar, bitta UNION so'rov (`rbac_my`)
--
-- PROVODKA_PERMS.sql + PROVODKA_PAGES_EMPTY.sql + PROVODKA_FILIAL_PERM.sql
-- + PROVODKA_SOROVLAR.sql dan KEYIN ishga tushiriladi. Asilbek qo'lda RUN qiladi.
-- =====================================================================


-- =====================================================================
-- 0-BO'LIM — Old shartlar
-- =====================================================================

do $rbac_pre$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'profiles jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regclass('public.accounts') is null then
    raise exception 'accounts jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regclass('public.entry_line') is null then
    raise exception 'entry_line jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regclass('public.user_perms') is null then
    raise exception 'user_perms jadvali yoq — avval PROVODKA_PERMS.sql ni bajaring';
  end if;
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'is_admin() funksiyasi yoq — RBAC unga tayanadi';
  end if;
  if to_regprocedure('public.perm_pages()') is null then
    raise exception 'perm_pages() funksiyasi yoq — avval PROVODKA_PERMS.sql / PAGES_EMPTY ni bajaring';
  end if;
  if to_regprocedure('public.my_perms()') is null then
    raise exception 'my_perms() funksiyasi yoq — avval PROVODKA_PAGES_EMPTY.sql / FILIAL_PERM ni bajaring';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.entry_line'::regclass
                    and tgname  = 'trg_perm_guard_entry_line') then
    raise exception 'trg_perm_guard_entry_line yoq — pul guardi orin almashgan bolishi mumkin, avval tekshiring';
  end if;
end
$rbac_pre$;


-- =====================================================================
-- 1-BO'LIM — Jadvallar
-- =====================================================================

-- 1.1 Rollar
create table if not exists rbac_role (
  id          uuid primary key default gen_random_uuid(),
  nom         text        not null,
  izoh        text,
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);

-- Unique nom — katta/kichik harf va bo'sh joylardan qat'i nazar
create unique index if not exists rbac_role_nom_uq on rbac_role (lower(btrim(nom)));

comment on table rbac_role is
  'RBAC rollar (masalan "Sotuvchi", "Bugalter"). Yozish faqat rbac_role_save()/rbac_role_delete() orqali (admin).';

-- 1.2 Rolga biriktirilgan amallar (sahifalar) — perm_pages() ∪ {'hodim'}
create table if not exists rbac_role_amal (
  role_id  uuid not null references rbac_role(id) on delete cascade,
  amal     text not null,
  primary key (role_id, amal)
);

comment on table rbac_role_amal is
  'Rolga biriktirilgan amal (sahifa) kalitlari. amal ∈ perm_pages() ∪ {''hodim''} — '
  'CHECK trigger emas (perm_pages() dinamik), tekshiruv rbac_role_save() ichida.';

-- 1.3 Rolga biriktirilgan xarajat moddalari (accounts.type='xarajat')
create table if not exists rbac_role_modda (
  role_id    uuid not null references rbac_role(id) on delete cascade,
  account_id uuid not null references accounts(id),
  primary key (role_id, account_id)
);

create index if not exists rbac_role_modda_account_idx on rbac_role_modda (account_id);

comment on table rbac_role_modda is
  'Rolga biriktirilgan xarajat moddalari (Dt hisoblar). rbac_modda_ok() shundan tekshiradi.';

-- 1.4 Rolga biriktirilgan ovqat turlari
create table if not exists rbac_role_ovqat (
  role_id  uuid not null references rbac_role(id) on delete cascade,
  tur      text not null check (tur in ('obed','zavtrak','kechki')),
  primary key (role_id, tur)
);

comment on table rbac_role_ovqat is
  'Rolga biriktirilgan ovqat turlari (obed/zavtrak/kechki). rbac_ovqat_ok() shundan tekshiradi.';

-- 1.5 Foydalanuvchi <-> rol (KO'P ROL bir userga)
create table if not exists rbac_user_role (
  user_id     uuid not null,
  role_id     uuid not null references rbac_role(id) on delete cascade,
  created_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (user_id, role_id)
);

create index if not exists rbac_user_role_role_idx on rbac_user_role (role_id);

comment on table rbac_user_role is
  'Foydalanuvchiga biriktirilgan rollar. Bir user bir nechta rolga ega bo''lishi mumkin (union effektiv ruxsat).';


-- =====================================================================
-- 2-BO'LIM — RLS
-- ---------------------------------------------------------------------
-- Har jadval: select — o'zi (rol unga biriktirilgan bo'lsa) yoki admin.
-- Yozish policy YO'Q — faqat quyidagi SECURITY DEFINER RPC'lar yozadi.
-- =====================================================================

alter table rbac_role       enable row level security;
alter table rbac_role_amal  enable row level security;
alter table rbac_role_modda enable row level security;
alter table rbac_role_ovqat enable row level security;
alter table rbac_user_role  enable row level security;

drop policy if exists rbac_role_read on rbac_role;
create policy rbac_role_read on rbac_role
  for select to authenticated
  using (
    is_admin()
    or exists (
      select 1 from rbac_user_role ur
       where ur.role_id = rbac_role.id
         and ur.user_id = (select auth.uid())
    )
  );

drop policy if exists rbac_role_amal_read on rbac_role_amal;
create policy rbac_role_amal_read on rbac_role_amal
  for select to authenticated
  using (
    is_admin()
    or exists (
      select 1 from rbac_user_role ur
       where ur.role_id = rbac_role_amal.role_id
         and ur.user_id = (select auth.uid())
    )
  );

drop policy if exists rbac_role_modda_read on rbac_role_modda;
create policy rbac_role_modda_read on rbac_role_modda
  for select to authenticated
  using (
    is_admin()
    or exists (
      select 1 from rbac_user_role ur
       where ur.role_id = rbac_role_modda.role_id
         and ur.user_id = (select auth.uid())
    )
  );

drop policy if exists rbac_role_ovqat_read on rbac_role_ovqat;
create policy rbac_role_ovqat_read on rbac_role_ovqat
  for select to authenticated
  using (
    is_admin()
    or exists (
      select 1 from rbac_user_role ur
       where ur.role_id = rbac_role_ovqat.role_id
         and ur.user_id = (select auth.uid())
    )
  );

drop policy if exists rbac_user_role_read on rbac_user_role;
create policy rbac_user_role_read on rbac_user_role
  for select to authenticated
  using (user_id = (select auth.uid()) or is_admin());

revoke all on rbac_role, rbac_role_amal, rbac_role_modda, rbac_role_ovqat, rbac_user_role
  from public, anon;
grant select on rbac_role, rbac_role_amal, rbac_role_modda, rbac_role_ovqat, rbac_user_role
  to authenticated;


-- =====================================================================
-- 3-BO'LIM — rbac_my(uuid) — effektiv ruxsat, BITTA so'rov (UNION)
-- ---------------------------------------------------------------------
-- ICHKI yordamchi: authenticated'ga to'g'ridan GRANT qilinmaydi (faqat
-- rbac_my_perms() va my_perms()/perm_has_page() ichidan chaqiriladi —
-- ular SECURITY DEFINER bo'lgani uchun egasi nomidan bajariladi, alohida
-- GRANT talab qilinmaydi). `auth.uid()` bu yerda ISHLATILMAYDI — parametr
-- chaqiruvchi tomonidan beriladi (bitta InitPlan, ko'p marta hisoblanmaydi).
-- =====================================================================

create or replace function rbac_my(p_uid uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $rbac_my$
  with ur as (
    select r.id, r.nom
      from rbac_user_role u
      join rbac_role r on r.id = u.role_id and r.is_active
     where u.user_id = p_uid
  ),
  amal as (
    select distinct ra.amal
      from rbac_role_amal ra
      join ur on ur.id = ra.role_id
  ),
  modda as (
    select distinct rm.account_id
      from rbac_role_modda rm
      join ur on ur.id = rm.role_id
  ),
  ovqat as (
    select distinct ro.tur
      from rbac_role_ovqat ro
      join ur on ur.id = ro.role_id
  )
  select jsonb_build_object(
    'roles',    coalesce((select jsonb_agg(jsonb_build_object('id', ur.id, 'nom', ur.nom)) from ur), '[]'::jsonb),
    'amallar',  coalesce((select jsonb_agg(amal.amal) from amal), '[]'::jsonb),
    'moddalar', coalesce((select jsonb_agg(modda.account_id) from modda), '[]'::jsonb),
    'ovqat',    coalesce((select jsonb_agg(ovqat.tur) from ovqat), '[]'::jsonb),
    'has_role', exists(select 1 from ur)
  );
$rbac_my$;

revoke all on function rbac_my(uuid) from public, anon, authenticated;

comment on function rbac_my(uuid) is
  'ICHKI: p_uid foydalanuvchining effektiv rol-ruxsati (roles/amallar/moddalar/ovqat, UNION). '
  'Bitta CTE so''rov — tezlik uchun. Faqat boshqa SECURITY DEFINER funksiyalar chaqiradi.';


create or replace function rbac_my_perms()
returns jsonb
language sql
stable
security definer
set search_path = public
as $rbac_my_perms$
  select rbac_my((select auth.uid()));
$rbac_my_perms$;

revoke all on function rbac_my_perms() from public, anon;
grant execute on function rbac_my_perms() to authenticated;

comment on function rbac_my_perms() is
  'authenticated uchun: ozining rol-ruxsati (rbac_my). Klient debug/kelajak UI uchun.';


-- =====================================================================
-- 4-BO'LIM — rbac_modda_ok / rbac_ovqat_ok
-- =====================================================================

create or replace function rbac_modda_ok(p_account uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $rbac_modda_ok$
begin
  if auth.uid() is null then return true; end if;      -- service_role (n8n)
  if is_admin() then return true; end if;

  return exists (
    select 1
      from rbac_user_role ur
      join rbac_role r on r.id = ur.role_id and r.is_active
      join rbac_role_modda m on m.role_id = ur.role_id
     where ur.user_id = (select auth.uid())
       and m.account_id = p_account
  );
end
$rbac_modda_ok$;

revoke all on function rbac_modda_ok(uuid) from public, anon;
grant execute on function rbac_modda_ok(uuid) to authenticated, service_role;

comment on function rbac_modda_ok(uuid) is
  'Foydalanuvchi (o''z rollari orqali) shu xarajat moddasiga yoza oladimi. Rolsiz user -> FALSE (fail-closed).';


create or replace function rbac_ovqat_ok(p_tur text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $rbac_ovqat_ok$
begin
  if auth.uid() is null then return true; end if;      -- service_role (n8n)
  if is_admin() then return true; end if;

  return exists (
    select 1
      from rbac_user_role ur
      join rbac_role r on r.id = ur.role_id and r.is_active
      join rbac_role_ovqat o on o.role_id = ur.role_id
     where ur.user_id = (select auth.uid())
       and o.tur = p_tur
  );
end
$rbac_ovqat_ok$;

revoke all on function rbac_ovqat_ok(text) from public, anon;
grant execute on function rbac_ovqat_ok(text) to authenticated, service_role;

comment on function rbac_ovqat_ok(text) is
  'Foydalanuvchi (o''z rollari orqali) shu ovqat turini (obed/zavtrak/kechki) yoza oladimi. '
  'HOZIRCHA hech qayerda chaqirilmaydi — xarajat_saqlash_ovqat() ichiga chaqiruvni Fable keyingi '
  'bosqichda qo''shadi (PROVODKA_OVQAT_KECHKI.sql bilan birga). Rolsiz user -> FALSE.';


-- =====================================================================
-- 5-BO'LIM — SERVER GUARD — xarajat moddasi (YANGI, alohida trigger)
-- ---------------------------------------------------------------------
-- Mavjud `trg_perm_guard_entry_line` (PUL/kassa cheklovi) ga TEGILMAYDI.
-- Bu YANGI trigger faqat DEBIT > 0 VA hisob accounts.type='xarajat'
-- bo'lgan satrlarni tekshiradi (tovar/pul/daromad satrlariga tegmaydi —
-- regression yo'q). Ikkala trigger BIR VAQTDA ishlaydi, ikkalasi ham
-- o'tishi kerak.
--
-- Bu yo'l orqali yozadigan HAMMA joy avtomatik qamraladi: hodim klient
-- insert, professional.html, sorov_tasdiq, xarajat_saqlash_ovqat(),
-- taqsim RPC, jurnal tahriri — barchasi entry_line ga INSERT qiladi.
-- =====================================================================

create or replace function rbac_guard_entry_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $rbac_guard$
declare
  v_type text;
  v_lbl  text;
begin
  if coalesce(new.debit, 0) <= 0 then
    return new;
  end if;

  select a.type, coalesce(a.code || ' ' || a.name, new.account_id::text)
    into v_type, v_lbl
    from accounts a where a.id = new.account_id;

  if v_type is distinct from 'xarajat' then
    return new;
  end if;

  if rbac_modda_ok(new.account_id) then
    return new;
  end if;

  raise exception 'Ruxsat yoq: "%" xarajat moddasi rolingizda yoq', v_lbl
    using errcode = '42501';
end
$rbac_guard$;

revoke all on function rbac_guard_entry_line() from public, anon;

drop trigger if exists trg_rbac_guard_entry_line on entry_line;
create trigger trg_rbac_guard_entry_line
  before insert or update of account_id on entry_line
  for each row execute function rbac_guard_entry_line();

comment on function rbac_guard_entry_line() is
  'YANGI (trg_perm_guard_entry_line dan ALOHIDA): rbac_role_modda boyicha xarajat moddasini tosadi. '
  'service_role (n8n) va admin otadi. Faqat debit>0 va type=xarajat satrlarga tegadi.';


-- =====================================================================
-- 6-BO'LIM — my_perms() — rol manbai qo'shiladi (imzo bir xil)
-- ---------------------------------------------------------------------
-- Baza — PROVODKA_PAGES_EMPTY.sql / PROVODKA_FILIAL_PERM.sql dagi ENG
-- OXIRGI tana (auth/admin/not-found/normal shoxlari VERBATIM saqlanadi).
-- Qo'shilgani: roles / amallar / moddalar / ovqat / has_role.
--
-- 🔴 SEMANTIKA (Asilbek qarori, migratsiya bilan mos):
--   allowed_pages = eski user_perms.allowed_pages ∪ rol amallari (UNION,
--   HAR IKKALASI HAM) — rol biriktirilgandan keyin ham shaxsiy (eski)
--   sahifa ruxsati YO'QOLMAYDI. has_provodka shu union'ga qarab hisoblanadi.
--   Rolsiz user -> faqat eski allowed_pages (avvalgidek, o'zgarish yo'q).
-- 🔴 Admin: amallar = perm_pages()+hodim (hammasi), moddalar = NULL
--   (= "hammasi", cheklovsiz — klient buni maxsus tekshirsin: null bo'lsa
--   moddalar ro'yxati bilan filtrlamasin), ovqat = 3 turi ham.
-- =====================================================================

create or replace function my_perms()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $my_perms$
declare
  p            user_perms;
  v_admin      boolean;
  v_has        boolean;
  v_rbac       jsonb;
  v_has_role   boolean;
  v_role_amal  text[];
  v_allowed    text[];
begin
  if auth.uid() is null then
    raise exception 'Avtorizatsiya kerak';
  end if;

  v_admin := is_admin();

  -- Admin har doim to'liq huquqli — user_perms/rbac qatori bo'lsa ham e'tiborga olinmaydi.
  if v_admin then
    return jsonb_build_object(
      'user_id',        auth.uid(),
      'allowed_pages',  '[]'::jsonb,
      'kassa_scope',    'all',
      'view_kassa_ids', '[]'::jsonb,
      'op_kassa_ids',   '[]'::jsonb,
      'can_convert',    true,
      'filial_scope',   'all',
      'filial_ids',     '[]'::jsonb,
      'is_admin',       true,
      'has_provodka',   true,
      'roles',          '[]'::jsonb,
      'amallar',        to_jsonb(perm_pages() || array['hodim']),
      'moddalar',       null,
      'ovqat',          to_jsonb(array['obed','zavtrak','kechki']),
      'has_role',       true);
  end if;

  v_rbac     := rbac_my(auth.uid());
  v_has_role := coalesce((v_rbac ->> 'has_role')::boolean, false);

  select coalesce(array_agg(x), '{}') into v_role_amal
    from jsonb_array_elements_text(coalesce(v_rbac -> 'amallar', '[]'::jsonb)) x;

  select * into p from user_perms where user_id = auth.uid();

  -- Qatori yo'q: sahifa ruxsati faqat rol manbaidan (agar rol bo'lsa).
  if not found then
    v_allowed := case when v_has_role then v_role_amal else '{}'::text[] end;
    v_has := coalesce(array_length(v_allowed, 1), 0) > 0;
    return jsonb_build_object(
      'user_id',        auth.uid(),
      'allowed_pages',  to_jsonb(v_allowed),
      'kassa_scope',    'all',
      'view_kassa_ids', '[]'::jsonb,
      'op_kassa_ids',   '[]'::jsonb,
      'can_convert',    true,
      'filial_scope',   'all',
      'filial_ids',     '[]'::jsonb,
      'is_admin',       false,
      'has_provodka',   v_has,
      'roles',          coalesce(v_rbac -> 'roles', '[]'::jsonb),
      'amallar',        coalesce(v_rbac -> 'amallar', '[]'::jsonb),
      'moddalar',       coalesce(v_rbac -> 'moddalar', '[]'::jsonb),
      'ovqat',          coalesce(v_rbac -> 'ovqat', '[]'::jsonb),
      'has_role',       v_has_role);
  end if;

  -- UNION: eski shaxsiy ruxsat + rol amallari (rol bo'lsa)
  select coalesce(array_agg(distinct x), '{}') into v_allowed
    from unnest(p.allowed_pages || case when v_has_role then v_role_amal else '{}'::text[] end) x;

  v_has := coalesce(array_length(v_allowed, 1), 0) > 0;

  return jsonb_build_object(
    'user_id',        p.user_id,
    'allowed_pages',  to_jsonb(v_allowed),
    'kassa_scope',    p.kassa_scope,
    'view_kassa_ids', to_jsonb(p.view_kassa_ids),
    'op_kassa_ids',   to_jsonb(p.op_kassa_ids),
    'can_convert',    p.can_convert,
    'filial_scope',   p.filial_scope,
    'filial_ids',     to_jsonb(p.filial_ids),
    'is_admin',       false,
    'has_provodka',   v_has,
    'roles',          coalesce(v_rbac -> 'roles', '[]'::jsonb),
    'amallar',        coalesce(v_rbac -> 'amallar', '[]'::jsonb),
    'moddalar',       coalesce(v_rbac -> 'moddalar', '[]'::jsonb),
    'ovqat',          coalesce(v_rbac -> 'ovqat', '[]'::jsonb),
    'has_role',       v_has_role);
end
$my_perms$;

revoke all on function my_perms() from public, anon;
grant execute on function my_perms() to authenticated;


-- =====================================================================
-- 7-BO'LIM — perm_has_page() — rol manbai qo'shiladi (imzo bir xil)
-- =====================================================================

create or replace function perm_has_page(p_key text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $perm_has_page$
declare
  p           user_perms;
  v_rbac      jsonb;
  v_role_amal text[];
begin
  if auth.uid() is null then return true; end if;      -- service_role (n8n)
  if is_admin() then return true; end if;
  -- Ro'yxatga kirmaydigan sahifa (masalan 'hodim') hech qachon cheklanmaydi
  if not (p_key = any(perm_pages())) then return true; end if;

  v_rbac := rbac_my(auth.uid());
  select coalesce(array_agg(x), '{}') into v_role_amal
    from jsonb_array_elements_text(coalesce(v_rbac -> 'amallar', '[]'::jsonb)) x;

  select * into p from user_perms where user_id = auth.uid();
  if not found then
    return p_key = any(v_role_amal);
  end if;

  return (p_key = any(p.allowed_pages)) or (p_key = any(v_role_amal));
end
$perm_has_page$;

revoke all on function perm_has_page(text) from public, anon;
grant execute on function perm_has_page(text) to authenticated, service_role;


-- =====================================================================
-- 8-BO'LIM — Admin RPC'lar (rol boshqaruvi)
-- =====================================================================

-- 8.1 rbac_royxat() — rollar + tanlov ro'yxatlari (UI uchun)
create or replace function rbac_royxat()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $rbac_royxat$
begin
  if not is_admin() then
    raise exception 'Faqat admin rol ro''yxatini ko''ra oladi' using errcode = '42501';
  end if;

  return (
    with rr as (
      select r.id, r.nom, r.izoh, r.is_active,
        coalesce((select jsonb_agg(ra.amal order by ra.amal)
                    from rbac_role_amal ra where ra.role_id = r.id), '[]'::jsonb) as amallar,
        coalesce((select jsonb_agg(rm.account_id)
                    from rbac_role_modda rm where rm.role_id = r.id), '[]'::jsonb) as moddalar,
        coalesce((select jsonb_agg(ro.tur order by ro.tur)
                    from rbac_role_ovqat ro where ro.role_id = r.id), '[]'::jsonb) as ovqat,
        (select count(*) from rbac_user_role ur where ur.role_id = r.id)::int as user_soni
        from rbac_role r
    )
    select jsonb_build_object(
      'rollar', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', id, 'nom', nom, 'izoh', izoh, 'is_active', is_active,
          'amallar', amallar, 'moddalar', moddalar, 'ovqat', ovqat, 'user_soni', user_soni)
          order by nom)
        from rr), '[]'::jsonb),
      'amal_royxati', to_jsonb(perm_pages() || array['hodim']),
      'moddalar', coalesce((
        select jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name) order by a.code)
          from accounts a
         where a.type = 'xarajat' and coalesce(a.is_active, true)), '[]'::jsonb)
    )
  );
end
$rbac_royxat$;

revoke all on function rbac_royxat() from public, anon;
grant execute on function rbac_royxat() to authenticated;


-- 8.2 rbac_role_save(jsonb) — rol yaratish/tahrirlash (bolalarni to'liq almashtiradi)
create or replace function rbac_role_save(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $rbac_role_save$
declare
  v_id       uuid;
  v_nom      text;
  v_izoh     text;
  v_active   boolean;
  v_amallar  text[];
  v_moddalar uuid[];
  v_ovqat    text[];
  v_bad      int;
  v_dup      uuid;
begin
  if not is_admin() then
    raise exception 'Faqat admin rol yarata/tahrirlay oladi' using errcode = '42501';
  end if;

  v_id   := nullif(p_data ->> 'id', '')::uuid;
  v_nom  := nullif(btrim(p_data ->> 'nom'), '');
  v_izoh := nullif(p_data ->> 'izoh', '');
  v_active := coalesce((p_data ->> 'is_active')::boolean, true);

  if v_nom is null then
    raise exception 'Rol nomi kerak' using errcode = '22000';
  end if;

  select id into v_dup from rbac_role
   where lower(btrim(nom)) = lower(v_nom) and id is distinct from v_id;
  if v_dup is not null then
    raise exception 'Bu nomda rol allaqachon bor: %', v_nom using errcode = '23505';
  end if;

  select coalesce(array_agg(distinct x), '{}') into v_amallar
    from jsonb_array_elements_text(coalesce(p_data -> 'amallar', '[]'::jsonb)) x;
  select count(*) into v_bad from unnest(v_amallar) x
   where not (x = any(perm_pages()) or x = 'hodim');
  if v_bad > 0 then
    raise exception 'Noma''lum amal kaliti(lar) bor (perm_pages() yoki hodim bo''lishi kerak)'
      using errcode = '22000';
  end if;

  select coalesce(array_agg(distinct x::uuid), '{}') into v_moddalar
    from jsonb_array_elements_text(coalesce(p_data -> 'moddalar', '[]'::jsonb)) x;
  select count(*) into v_bad from unnest(v_moddalar) x
   where not exists (select 1 from accounts a where a.id = x and a.type = 'xarajat');
  if v_bad > 0 then
    raise exception 'Noma''lum xarajat moddasi id bor' using errcode = '22000';
  end if;

  select coalesce(array_agg(distinct x), '{}') into v_ovqat
    from jsonb_array_elements_text(coalesce(p_data -> 'ovqat', '[]'::jsonb)) x;
  select count(*) into v_bad from unnest(v_ovqat) x
   where x not in ('obed','zavtrak','kechki');
  if v_bad > 0 then
    raise exception 'Noma''lum ovqat turi bor (obed|zavtrak|kechki kerak)' using errcode = '22000';
  end if;

  if v_id is null then
    insert into rbac_role (nom, izoh, is_active, updated_by)
    values (v_nom, v_izoh, v_active, auth.uid())
    returning id into v_id;
  else
    update rbac_role
       set nom = v_nom, izoh = v_izoh, is_active = v_active,
           updated_at = now(), updated_by = auth.uid()
     where id = v_id;
    if not found then
      raise exception 'Rol topilmadi: %', v_id using errcode = '22023';
    end if;
  end if;

  delete from rbac_role_amal where role_id = v_id;
  insert into rbac_role_amal (role_id, amal)
    select v_id, x from unnest(v_amallar) x;

  delete from rbac_role_modda where role_id = v_id;
  insert into rbac_role_modda (role_id, account_id)
    select v_id, x from unnest(v_moddalar) x;

  delete from rbac_role_ovqat where role_id = v_id;
  insert into rbac_role_ovqat (role_id, tur)
    select v_id, x from unnest(v_ovqat) x;

  return jsonb_build_object('id', v_id);
end
$rbac_role_save$;

revoke all on function rbac_role_save(jsonb) from public, anon;
grant execute on function rbac_role_save(jsonb) to authenticated;


-- 8.3 rbac_role_delete(uuid) — biriktirilgan user bo'lsa RAD
create or replace function rbac_role_delete(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $rbac_role_delete$
declare v_n int;
begin
  if not is_admin() then
    raise exception 'Faqat admin rol o''chira oladi' using errcode = '42501';
  end if;

  select count(*) into v_n from rbac_user_role where role_id = p_id;
  if v_n > 0 then
    raise exception 'Bu rolga % ta foydalanuvchi biriktirilgan — avval ularni boshqa rolga o''tkazing', v_n
      using errcode = '23503';
  end if;

  delete from rbac_role where id = p_id;
  if not found then
    raise exception 'Rol topilmadi: %', p_id using errcode = '22023';
  end if;
end
$rbac_role_delete$;

revoke all on function rbac_role_delete(uuid) from public, anon;
grant execute on function rbac_role_delete(uuid) to authenticated;


-- 8.4 rbac_user_set(uuid, uuid[]) — userning rollarini to'liq almashtiradi
create or replace function rbac_user_set(p_user uuid, p_roles uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $rbac_user_set$
declare
  v_role  text;
  v_bad   int;
  v_roles uuid[];
begin
  if not is_admin() then
    raise exception 'Faqat admin rol beradi' using errcode = '42501';
  end if;

  select role into v_role from profiles where id = p_user;
  if v_role is null then
    raise exception 'Foydalanuvchi topilmadi: %', p_user using errcode = '22023';
  end if;

  -- Admin userga rol yozilmaydi (u doim to'liq huquqli)
  if v_role = 'admin' then
    delete from rbac_user_role where user_id = p_user;
    return jsonb_build_object('ok', true, 'skipped', 'admin',
      'note', 'Admin doim toliq huquqli — rol saqlanmadi');
  end if;

  select coalesce(array_agg(distinct x), '{}') into v_roles
    from unnest(coalesce(p_roles, '{}'::uuid[])) x;

  select count(*) into v_bad from unnest(v_roles) x
   where not exists (select 1 from rbac_role r where r.id = x);
  if v_bad > 0 then
    raise exception 'Noma''lum rol id bor' using errcode = '22023';
  end if;

  delete from rbac_user_role where user_id = p_user;
  insert into rbac_user_role (user_id, role_id, updated_by)
    select p_user, x, auth.uid() from unnest(v_roles) x;

  return jsonb_build_object('ok', true, 'user_id', p_user, 'roles', to_jsonb(v_roles));
end
$rbac_user_set$;

revoke all on function rbac_user_set(uuid, uuid[]) from public, anon;
grant execute on function rbac_user_set(uuid, uuid[]) to authenticated;


-- 8.5 rbac_users() — profiles + har userning rollari (admin ro'yxati uchun)
create or replace function rbac_users()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $rbac_users$
begin
  if not is_admin() then
    raise exception 'Faqat admin foydalanuvchi ro''yxatini ko''ra oladi' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',        pr.id,
      'full_name', coalesce(to_jsonb(pr) ->> 'full_name', ''),
      'role',      pr.role,
      'roles',     coalesce((
        select jsonb_agg(jsonb_build_object('id', r.id, 'nom', r.nom) order by r.nom)
          from rbac_user_role ur
          join rbac_role r on r.id = ur.role_id
         where ur.user_id = pr.id), '[]'::jsonb)
    ) order by coalesce(to_jsonb(pr) ->> 'full_name', pr.id::text))
    from profiles pr
  ), '[]'::jsonb);
end
$rbac_users$;

revoke all on function rbac_users() from public, anon;
grant execute on function rbac_users() to authenticated;


-- =====================================================================
-- 9-BO'LIM — Migratsiya (bir martalik, idempotent)
-- ---------------------------------------------------------------------
-- "Standart hodim" roli — RUN paytida mavjud non-admin userlar uchun,
-- hozirgi imkoniyat (barcha faol xarajat moddasi + barcha ovqat turi)
-- saqlansin. Rol nomi allaqachon bo'lsa BUTUN blok o'tkazib yuboriladi —
-- ikkinchi RUN'da qayta biriktirmaydi, YANGI userlar rolsiz qoladi
-- (Asilbek qarori — admin keyin rbac_user_set() bilan qo'lda beradi).
--
-- allowed_pages'ni yo'qotmaslik uchun (rol faqat 'hodim' beradi) my_perms()
-- 6-BO'LIMda UNION qiladi — eski qo'shimcha sahifa ruxsati bor userlar
-- (masalan bittasiga 'sozlama' berilgan bo'lsa) rol qo'shilgach ham
-- o'sha ruxsatni yo'qotmaydi.
-- =====================================================================

do $rbac_migrate$
declare
  v_std_role uuid;
  v_uid      uuid;
  v_n        int := 0;
begin
  select id into v_std_role from rbac_role where lower(btrim(nom)) = lower('Standart hodim');

  if v_std_role is not null then
    raise notice 'Standart hodim roli allaqachon bor (id=%) — migratsiya otkazib yuborildi', v_std_role;
    return;
  end if;

  insert into rbac_role (nom, izoh, is_active)
  values ('Standart hodim',
          'RUN paytidagi userlar uchun avtomat — hozirgi imkoniyat saqlansin',
          true)
  returning id into v_std_role;

  insert into rbac_role_amal (role_id, amal) values (v_std_role, 'hodim');

  insert into rbac_role_modda (role_id, account_id)
    select v_std_role, a.id from accounts a
     where a.type = 'xarajat' and coalesce(a.is_active, true);

  insert into rbac_role_ovqat (role_id, tur)
    select v_std_role, t from unnest(array['obed','zavtrak','kechki']) t;

  for v_uid in
    select pr.id from profiles pr
     where pr.role is distinct from 'admin'
       and not exists (select 1 from rbac_user_role ur where ur.user_id = pr.id)
  loop
    insert into rbac_user_role (user_id, role_id) values (v_uid, v_std_role)
    on conflict do nothing;
    v_n := v_n + 1;
  end loop;

  raise notice 'Standart hodim roli yaratildi (id=%), % ta foydalanuvchiga biriktirildi', v_std_role, v_n;
end
$rbac_migrate$;


-- =====================================================================
-- 9.5-BO'LIM — user_perms_read policy: InitPlan naqshi (tezlik)
-- ---------------------------------------------------------------------
-- PROVODKA_PERMS.sql:78-80 dagi eski policy `user_id = auth.uid()` — yalang'och
-- chaqiruv har QATOR uchun qayta hisoblanadi. `(select auth.uid())` bir marta
-- (InitPlan). Semantika AYNAN bir xil: o'zi yoki admin. Additive: drop+create.
-- =====================================================================
drop policy if exists user_perms_read on user_perms;
create policy user_perms_read on user_perms
  for select to authenticated
  using (user_id = (select auth.uid()) or is_admin());

-- =====================================================================
-- 10-BO'LIM — Tekshiruv (katalog, jonli chaqiruv YO'Q)
-- =====================================================================

do $rbac_check$
declare
  v_n int;
begin
  -- 10.1 Jadvallar
  if to_regclass('public.rbac_role') is null then
    raise exception 'rbac_role jadvali yaratilmadi';
  end if;
  if to_regclass('public.rbac_role_amal') is null then
    raise exception 'rbac_role_amal jadvali yaratilmadi';
  end if;
  if to_regclass('public.rbac_role_modda') is null then
    raise exception 'rbac_role_modda jadvali yaratilmadi';
  end if;
  if to_regclass('public.rbac_role_ovqat') is null then
    raise exception 'rbac_role_ovqat jadvali yaratilmadi';
  end if;
  if to_regclass('public.rbac_user_role') is null then
    raise exception 'rbac_user_role jadvali yaratilmadi';
  end if;

  -- 10.2 RLS yoqilganmi + yozish policy YO'Qmi
  if exists (
    select 1 from unnest(array['rbac_role','rbac_role_amal','rbac_role_modda',
                                'rbac_role_ovqat','rbac_user_role']) t(tbl)
     where not (select relrowsecurity from pg_class where oid = ('public.'||t.tbl)::regclass)
  ) then
    raise exception 'RBAC jadvallaridan birida RLS yoqilmagan';
  end if;

  select count(*) into v_n from pg_policies
   where schemaname = 'public'
     and tablename in ('rbac_role','rbac_role_amal','rbac_role_modda','rbac_role_ovqat','rbac_user_role')
     and cmd <> 'SELECT';
  if v_n > 0 then
    raise exception 'RBAC jadvallarida yozish policy''si bor (% ta) — bo''lmasligi kerak', v_n;
  end if;

  -- 10.3 Funksiyalar (imzo bo'yicha)
  if to_regprocedure('public.rbac_my(uuid)') is null then
    raise exception 'rbac_my(uuid) yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_my_perms()') is null then
    raise exception 'rbac_my_perms() yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_modda_ok(uuid)') is null then
    raise exception 'rbac_modda_ok(uuid) yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_ovqat_ok(text)') is null then
    raise exception 'rbac_ovqat_ok(text) yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_royxat()') is null then
    raise exception 'rbac_royxat() yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_role_save(jsonb)') is null then
    raise exception 'rbac_role_save(jsonb) yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_role_delete(uuid)') is null then
    raise exception 'rbac_role_delete(uuid) yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_user_set(uuid, uuid[])') is null then
    raise exception 'rbac_user_set(uuid, uuid[]) yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_users()') is null then
    raise exception 'rbac_users() yaratilmadi';
  end if;

  -- 10.4 Trigger o'z joyidami (yangi, eskisidan alohida)
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.entry_line'::regclass
                    and tgname  = 'trg_rbac_guard_entry_line') then
    raise exception 'trg_rbac_guard_entry_line o''rnatilmadi';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.entry_line'::regclass
                    and tgname  = 'trg_perm_guard_entry_line') then
    raise exception 'trg_perm_guard_entry_line (eski, pul) yo''qolib qolgan — regressiya!';
  end if;

  -- 10.5 my_perms() / perm_has_page() yangi kalitlarni bilishimi
  if position('has_role' in (select prosrc from pg_proc where proname = 'my_perms' limit 1)) = 0 then
    raise exception 'my_perms() ichida has_role yo''q — yangilanmadi';
  end if;
  if position('rbac_my' in (select prosrc from pg_proc where proname = 'perm_has_page' limit 1)) = 0 then
    raise exception 'perm_has_page() ichida rbac_my chaqiruvi yo''q — yangilanmadi';
  end if;

  -- 10.6 Admin RPC'lar authenticated'ga to'g'ri ochiqmi (tekshiruv ICHIDA)
  if not has_function_privilege('authenticated', 'public.rbac_role_save(jsonb)', 'execute') then
    raise exception 'rbac_role_save(jsonb) authenticated uchun yopiq — admin UI ishlamaydi';
  end if;
  if has_function_privilege('anon', 'public.rbac_role_save(jsonb)', 'execute') then
    raise exception 'rbac_role_save(jsonb) anon uchun ochiq qolgan';
  end if;
  if has_function_privilege('anon', 'public.rbac_my_perms()', 'execute') then
    raise exception 'rbac_my_perms() anon uchun ochiq qolgan';
  end if;

  raise notice 'RBAC tayyor. Rollar: % ta, foydalanuvchi-rol bogʻlanishi: % ta',
    (select count(*) from rbac_role), (select count(*) from rbac_user_role);
end
$rbac_check$;
