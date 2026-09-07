-- =====================================================================
-- PROVODKA_STANDART_ROL.sql
-- Asilbek talabi (2026-09-07): "Standart xarajatlar" sahifasida filial
-- tanlanganda FAQAT shu filial hodimlariga (rol orqali) ochilgan xarajat
-- moddalari ko'rinsin (buxgalter aralashtiryapti — "har qanday modda"
-- ko'rinishi chalkashtiradi). Rolda limit qo'yilgan bo'lsa ko'rinadi;
-- filial limiti (standart_xarajat) qo'yilgan bo'lsa rol (oylik) limitini
-- OVERRIDE qiladi — filial limiti amal qiladi, rol limiti tekshirilmaydi.
-- ---------------------------------------------------------------------
-- ## RUN TARTIBI (Asilbek) — bo'limlarni tartib bilan
--   0-BO'LIM — old shart tekshiruvi (faqat select, pg_proc/pg_class orqali —
--              to_regprocedure ISHLATILMAYDI, bu faylda ataylab)
--   1-BO'LIM — standart_filial_moddalar(uuid) — filial hodimlari + ularning
--              rollaridagi moddalar (yig'ma)
--   2-BO'LIM — rbac_limit_entry_line() qayta e'lon (imzo/trigger bir xil,
--              eski tana TO'LIQ saqlangan) + filial limiti override shoxi
--   3-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)
--
-- ## OLD SHART (bazada bo'lishi kerak)
--   PROVODKA_OVQAT.sql        -> aros_staff, staff_branch_map
--   PROVODKA_RBAC.sql         -> rbac_role, rbac_role_modda, rbac_user_role, is_admin()
--   PROVODKA_RBAC_STAFF.sql   -> rbac_staff_role
--   PROVODKA_RBAC_LINK.sql    -> aros_staff.user_id, rbac_staff_ovqat(int) naqshi
--                                 (rol manbai shu funksiyaning mantig'ini takrorlaydi)
--   PROVODKA_RBAC_LIMIT.sql   -> rbac_role_modda.limit_uzs, rbac_limit_entry_line(),
--                                 trg_rbac_limit_entry_line
--   PROVODKA_V7.sql           -> standart_xarajat, standart_holat, limit_guard_entry_line
--                                 (4-BOSQICH), perm_pages() ichida 'standart', entry.filial_ids
--   PROVODKA_FILIAL_TANLOV_FIX.sql (yoki oldingi) -> v_filial_tanlov
--   PROVODKA_PAGES_EMPTY.sql  -> perm_has_page(text) (ixtiyoriy — bo'lmasa
--                                 faqat admin ko'radi, fail-closed)
--
-- ## QOIDALAR (CLAUDE.md, buzilmadi)
--   * anonim `do` bloki YO'Q — har `do` bloki NOMLANGAN teg bilan.
--   * har funksiya tanasi NOMLANGAN dollar-teg (masalan "fn") bilan o'raladi.
--   * izohda dollar-qavs (ikkita "$" yonma-yon) YO'Q.
--   * hammasi additive: eski jadval/ustun/funksiya imzosi buzilmaydi.
--   * idempotent: qayta RUN qilish xavfsiz.
--   * `to_regprocedure` bu faylda ISHLATILMAYDI — funksiya bor-yo'qligi
--     `pg_proc`/`pg_namespace` orqali to'g'ridan tekshiriladi (jadval/view
--     uchun `to_regclass` — bu taqiqlanmagan, ishlatiladi).
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (faqat select)                 ##
-- #####################################################################

do $standart_rol_pre$
begin
  if to_regclass('public.aros_staff') is null then
    raise exception 'aros_staff jadvali yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;
  if to_regclass('public.staff_branch_map') is null then
    raise exception 'staff_branch_map jadvali yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_role') is null then
    raise exception 'rbac_role jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_role_modda') is null then
    raise exception 'rbac_role_modda jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'rbac_role_modda' and column_name = 'limit_uzs'
  ) then
    raise exception 'rbac_role_modda.limit_uzs ustuni yoq — avval PROVODKA_RBAC_LIMIT.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_staff_role') is null then
    raise exception 'rbac_staff_role jadvali yoq — avval PROVODKA_RBAC_STAFF.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_user_role') is null then
    raise exception 'rbac_user_role jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regclass('public.profiles') is null then
    raise exception 'profiles jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'aros_staff' and column_name = 'user_id'
  ) then
    raise exception 'aros_staff.user_id ustuni yoq — avval PROVODKA_RBAC_LINK.sql ni bajaring';
  end if;
  if to_regclass('public.standart_xarajat') is null then
    raise exception 'standart_xarajat jadvali yoq — avval PROVODKA_V7.sql (4-BOSQICH) ni bajaring';
  end if;
  if to_regclass('public.v_filial_tanlov') is null then
    raise exception 'v_filial_tanlov view yoq — avval filial tanlov SQL faylini bajaring';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'entry' and column_name = 'filial_ids'
  ) then
    raise exception 'entry.filial_ids ustuni yoq — RBAC_LIMIT override shoxi unga tayanadi';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'is_admin'
  ) then
    raise exception 'is_admin() funksiyasi yoq';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'rbac_limit_entry_line'
  ) then
    raise exception 'rbac_limit_entry_line() yoq — avval PROVODKA_RBAC_LIMIT.sql ni bajaring';
  end if;
  if not exists (
    select 1 from pg_trigger where tgname = 'trg_rbac_limit_entry_line'
  ) then
    raise exception 'trg_rbac_limit_entry_line trigger yoq — avval PROVODKA_RBAC_LIMIT.sql ni bajaring';
  end if;
  if not exists (
    select 1 from pg_trigger where tgname = 'trg_limit_guard_entry_line'
  ) then
    raise exception 'trg_limit_guard_entry_line trigger yoq — avval PROVODKA_V7.sql (4-BOSQICH) ni bajaring';
  end if;
end
$standart_rol_pre$;


-- #####################################################################
-- ##  1-BO'LIM — standart_filial_moddalar(uuid)                      ##
-- ---------------------------------------------------------------------
-- Filialning FAOL hodimlari (aros_staff.branch_id YOKI branches[] massivi
-- staff_branch_map.provodka_filial orqali shu filialga mos bo'lsa) + har
-- hodimning EFFEKTIV rollari + rollardagi (rbac_role_modda) xarajat
-- moddalari yig'ma. Rol manbai — rbac_staff_ovqat(int) (PROVODKA_RBAC_LINK.sql
-- 124-161) bilan AYNAN bir xil qoida: aros_staff.user_id bog'langan bo'lsa
-- manba o'sha USERNING rbac_user_role rollari (bog'langan user admin bo'lsa —
-- HAMMA faol xarajat moddasi, cheksiz, rol nomi "Admin"); bog'lanmagan bo'lsa
-- eskisidek rbac_staff_role. Ruxsat: admin YOKI 'standart' sahifasi ruxsati
-- (perm_has_page — bo'lmasa fail-closed).
-- #####################################################################

create or replace function standart_filial_moddalar(p_filial uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_page_ok    boolean := false;
  v_filial_id  uuid;
  v_filial_nom text;
  v_bids       int[];
begin
  if auth.uid() is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  if is_admin() then
    v_page_ok := true;
  elsif exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'perm_has_page'
  ) then
    v_page_ok := perm_has_page('standart');
  end if;
  if not v_page_ok then
    raise exception 'Standart xarajatlar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;

  if p_filial is null then
    raise exception 'Filial tanlanmadi' using errcode = '22000';
  end if;

  select id, name into v_filial_id, v_filial_nom
    from accounts
   where id = p_filial
     and kassa_turi = 'filial'
     and parent_id is null
     and coalesce(is_active, true);
  if v_filial_id is null then
    raise exception 'Filial topilmadi: %', p_filial using errcode = '22023';
  end if;

  -- Aros branch_id'lar — staff_branch_map.provodka_filial ↔ filial NOMI
  -- (hodim-dev.html ovqatMeningBranchIds() bilan AYNAN bir xil naqsh).
  select coalesce(array_agg(m.branch_id), '{}'::int[]) into v_bids
    from staff_branch_map m
   where m.provodka_filial = v_filial_nom;

  return (
    with staff_in as (
      select s.staff_id,
             coalesce(nullif(btrim(s.toliq_nom), ''),
                      btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))) as nom,
             s.lavozim, s.user_id
        from aros_staff s
       where s.is_active
         and (
           s.branch_id = any(v_bids)
           or exists (
             select 1 from jsonb_array_elements(coalesce(s.branches, '[]'::jsonb)) b
              where (b ->> 'id') ~ '^\d+$' and (b ->> 'id')::int = any(v_bids)
           )
         )
    ),
    -- Bog'langan (user_id bor) VA o'sha user admin -> alohida shox (rbac_staff_ovqat
    -- bilan bir xil: profiles.role='admin'). Profiles qatori yo'q -> admin EMAS.
    staff_admin as (
      select si.staff_id
        from staff_in si
        join profiles p on p.id = si.user_id
       where si.user_id is not null and p.role = 'admin'
    ),
    -- Effektiv rollar: admin-bog'langan hodim bu yerda YO'Q (alohida qatnaydi).
    staff_role as (
      select si.staff_id, r.id as role_id, r.nom as role_nom
        from staff_in si
        join rbac_user_role ur on ur.user_id = si.user_id
        join rbac_role r on r.id = ur.role_id and r.is_active
       where si.user_id is not null
         and not exists (select 1 from staff_admin sa where sa.staff_id = si.staff_id)
      union all
      select si.staff_id, r.id, r.nom
        from staff_in si
        join rbac_staff_role sr on sr.staff_id = si.staff_id
        join rbac_role r on r.id = sr.role_id and r.is_active
       where si.user_id is null
    ),
    hodim_rollar as (
      select si.staff_id, si.nom, si.lavozim,
             case when exists (select 1 from staff_admin sa where sa.staff_id = si.staff_id)
                  then '["Admin"]'::jsonb
                  else coalesce((
                    select jsonb_agg(distinct sr.role_nom order by sr.role_nom)
                      from staff_role sr where sr.staff_id = si.staff_id
                  ), '[]'::jsonb)
             end as rollar
        from staff_in si
    ),
    -- Modda yig'ma manbasi: oddiy rol orqali (faqat xarajat/faol modda) +
    -- admin-bog'langan hodim uchun HAMMA faol xarajat modda (cheksiz).
    modda_z as (
      select sr.staff_id, si.nom, am.id as modda_id, rm.limit_uzs
        from staff_role sr
        join staff_in si on si.staff_id = sr.staff_id
        join rbac_role_modda rm on rm.role_id = sr.role_id
        join accounts am on am.id = rm.account_id and am.type = 'xarajat' and coalesce(am.is_active, true)
      union all
      select sa.staff_id, si.nom, a.id as modda_id, null::numeric as limit_uzs
        from staff_admin sa
        join staff_in si on si.staff_id = sa.staff_id
        cross join accounts a
       where a.type = 'xarajat' and coalesce(a.is_active, true)
    ),
    modda_agg as (
      select z.modda_id,
             count(distinct z.staff_id)::int as hodim_soni,
             to_jsonb(array_agg(distinct z.nom order by z.nom)) as hodimlar,
             min(z.limit_uzs) filter (where z.limit_uzs is not null) as rol_limit_min,
             max(z.limit_uzs) filter (where z.limit_uzs is not null) as rol_limit_max,
             bool_or(z.limit_uzs is null) as cheksiz_bor
        from modda_z z
       group by z.modda_id
    )
    select jsonb_build_object(
      'filial', jsonb_build_object('id', v_filial_id, 'name', v_filial_nom),
      'hodimlar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'staff_id',  hr.staff_id,
                 'toliq_nom', hr.nom,
                 'lavozim',   hr.lavozim,
                 'rollar',    hr.rollar
               ) order by hr.nom)
          from hodim_rollar hr
      ), '[]'::jsonb),
      'moddalar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'modda_id',         ma.modda_id,
                 'code',             a.code,
                 'name',             a.name,
                 'hodim_soni',       ma.hodim_soni,
                 'hodimlar',         ma.hodimlar,
                 'rol_limit_min',    ma.rol_limit_min,
                 'rol_limit_max',    ma.rol_limit_max,
                 'cheksiz_bor',      ma.cheksiz_bor,
                 'filial_limit_uzs', sx.limit_uzs
               ) order by a.code)
          from modda_agg ma
          join accounts a on a.id = ma.modda_id
          left join standart_xarajat sx on sx.filial_id = v_filial_id and sx.modda_id = ma.modda_id
      ), '[]'::jsonb)
    )
  );
end
$fn$;

revoke all on function standart_filial_moddalar(uuid) from public, anon;
grant execute on function standart_filial_moddalar(uuid) to authenticated;

comment on function standart_filial_moddalar(uuid) is
  'Standart xarajatlar UI: shu filial (accounts.id, kassa_turi=filial) hodimlari (staff_branch_map '
  'orqali) + ularning EFFEKTIV rollaridagi xarajat moddalari (yig''ma, rol limit min/max/cheksiz_bor). '
  'Rol manbai rbac_staff_ovqat(int) bilan bir xil (bog''langan user rollari, admin bo''lsa hamma modda) — '
  'PROVODKA_RBAC_LINK.sql. Har modda uchun filial_limit_uzs (standart_xarajat, bor bo''lsa override). '
  'Admin yoki ''standart'' sahifa ruxsati kerak.';


-- #####################################################################
-- ##  2-BO'LIM — rbac_limit_entry_line(): FILIAL LIMITI OVERRIDE     ##
-- ---------------------------------------------------------------------
-- PROVODKA_RBAC_LIMIT.sql dagi ENG OXIRGI tananing VERBATIM nusxasi +
-- BITTA qo'shimcha shox: entry.filial_ids ichidagi biror filial uchun
-- standart_xarajat da (filial, shu modda) qatori bo'lsa — rol (oylik)
-- limiti TEKSHIRILMAYDI (return new), o'rniga filialning o'z limiti
-- (trg_limit_guard_entry_line, PROVODKA_V7.sql, ALOHIDA trigger, baribir
-- ishlaydi) amal qiladi. Imzo/trigger o'zgarmaydi.
-- #####################################################################

create or replace function rbac_limit_entry_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_type    text;
  v_date    date;
  v_status  text;
  v_deleted boolean;
  v_raw     text;
  v_ega     uuid;
  v_lim     numeric;
  v_used    numeric;
  v_lbl     text;
  v_fids    uuid[];
begin
  if coalesce(new.debit, 0) <= 0 then
    return new;
  end if;

  select a.type into v_type from accounts a where a.id = new.account_id;
  if v_type is distinct from 'xarajat' then
    return new;
  end if;

  if auth.uid() is null then
    return new;                                     -- service_role (n8n)
  end if;
  if is_admin() then
    return new;
  end if;

  select e.entry_date, coalesce(e.status, 'posted'), coalesce(e.is_deleted, false),
         (to_jsonb(e) ->> 'created_by'), e.filial_ids
    into v_date, v_status, v_deleted, v_raw, v_fids
    from entry e where e.id = new.entry_id;
  if not found then
    return new;
  end if;
  if v_deleted or v_status not in ('posted', 'pending') then
    return new;
  end if;

  -- Asilbek 2026-09-07: filial limiti rol limitini override qiladi.
  -- entry.filial_ids ichidagi biror filial uchun standart_xarajat da (shu
  -- filial, shu modda) qatori bo'lsa — rol oylik limiti bu yerda
  -- TEKSHIRILMAYDI, filialning o'z limiti (trg_limit_guard_entry_line,
  -- PROVODKA_V7.sql — ALOHIDA AFTER trigger, shu insertda baribir ishlaydi)
  -- amal qiladi. standart_xarajat jadvali yo'q (SQL run tartibi buzilgan)
  -- bo'lsa bu shox jimgina o'tkazib yuboriladi (fail bo'lmaydi).
  if v_fids is not null and array_length(v_fids, 1) is not null
     and to_regclass('public.standart_xarajat') is not null then
    if exists (
      select 1 from standart_xarajat sx
       where sx.modda_id = new.account_id and sx.filial_id = any(v_fids)
    ) then
      return new;
    end if;
  end if;

  -- Egasi: entry.created_by (matn/uuid shaklida bo'lishi mumkin,
  -- PROVODKA_IJROCHI.sql naqshi). Bosh bo'lsa -> auth.uid(). uuid shaklida
  -- EMAS (masalan 'aros_sync') bo'lsa -> bu guard sukut qiladi (fail-open
  -- EMAS — egasi shunchaki nomalum, boshqa guardlar baribir amal qiladi).
  v_raw := nullif(btrim(coalesce(v_raw, '')), '');
  if v_raw is null then
    v_ega := auth.uid();
  elsif v_raw ~ '^[0-9a-fA-F-]{36}$' then
    v_ega := v_raw::uuid;
  else
    return new;
  end if;

  -- ONGLI QAROR (Asilbek, 2026-08-29): "Ruxsat sorovi" (PROVODKA_RUXSAT_SOROV.sql)
  -- orqali yozilgan xarajatda modda hodimning OZ rolida YOQ (aynan shu sabab
  -- sorov yozilgan) -> rbac_limit_modda null -> oylik limit TEKSHIRILMAYDI.
  -- Bu bug emas: u yerda limit orniga tasdiqlovchi odamning qarori turadi
  -- (har sorov alohida, summa/modda tasdiqlovchi koradi). Ozgartirilmasin.
  v_lim := rbac_limit_modda(v_ega, new.account_id);
  if v_lim is null then
    return new;                                      -- limit qoyilmagan yoki cheksiz
  end if;

  -- AFTER INSERT — yangi satr yigindiga ALLAQACHON kirgan (rbac_modda_ishlatildi
  -- ichida shu satr ham hisoblanadi).
  v_used := rbac_modda_ishlatildi(v_ega, new.account_id, v_date);
  if v_used > v_lim then
    select coalesce(a.code || ' ' || a.name, new.account_id::text) into v_lbl
      from accounts a where a.id = new.account_id;
    raise exception 'Oylik limit oshdi: "%" — limit %, shu oyda ishlatildi % (shu bilan)',
      v_lbl, round(v_lim), round(v_used)
      using errcode = '42501';
  end if;

  return new;
end
$fn$;

revoke all on function rbac_limit_entry_line() from public, anon;

-- Trigger e'lonini qayta ishlatish shart emas (funksiya nomi/imzosi o'zgarmadi,
-- trigger allaqachon shu funksiyaga ishora qiladi) — baribir idempotent qayta
-- yaratamiz, DDL tartibi buzilmasin.
drop trigger if exists trg_rbac_limit_entry_line on entry_line;
create trigger trg_rbac_limit_entry_line
  after insert on entry_line
  for each row execute function rbac_limit_entry_line();

comment on function rbac_limit_entry_line() is
  'rbac_role_modda.limit_uzs boyicha OYLIK limitni majburlaydi (egasi entry.created_by). '
  'service_role (n8n) va admin otadi. YANGI (2026-09-07, PROVODKA_STANDART_ROL.sql): '
  'entry.filial_ids da standart_xarajat (filial, shu modda) qatori bo''lsa bu shox '
  'o''tkazib yuboriladi — filial limiti rol limitini override qiladi.';

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  3-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)            ##
-- #####################################################################

do $standart_rol_check$
declare
  v_src text;
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'standart_filial_moddalar'
  ) then
    raise exception 'standart_filial_moddalar(uuid) yaratilmadi';
  end if;

  if not has_function_privilege('authenticated', 'public.standart_filial_moddalar(uuid)', 'execute') then
    raise exception 'standart_filial_moddalar(uuid) authenticated uchun yopiq';
  end if;
  if has_function_privilege('anon', 'public.standart_filial_moddalar(uuid)', 'execute') then
    raise exception 'standart_filial_moddalar(uuid) anon uchun ochiq qolgan';
  end if;

  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rbac_limit_entry_line' limit 1;
  if v_src is null or position('standart_xarajat' in v_src) = 0 then
    raise exception 'rbac_limit_entry_line() ichida filial limiti override shoxi yoq — yangilanmadi';
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'trg_rbac_limit_entry_line') then
    raise exception 'trg_rbac_limit_entry_line trigger yoq';
  end if;

  raise notice 'STANDART_ROL tayyor: standart_filial_moddalar(uuid) + rbac_limit_entry_line override.';
end
$standart_rol_check$;
