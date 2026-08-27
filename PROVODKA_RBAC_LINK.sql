-- =====================================================================
-- PROVODKA_RBAC_LINK.sql
-- HODIM <-> USER bog'lash. Muammo: admin rolni Provodka USER'iga beradi
-- ("Ozodbek Abduhamidov", rbac_user_role), ovqat ro'yxati esa aros-staff
-- HODIM'iga qaraydi ("Ozodbek Abduhomidov", staff 134, rbac_staff_role) —
-- ikki alohida yozuv, ism bir-biriga o'xshasa ham bog'lanmagan. Yechim:
-- aros_staff.user_id — hodim shu auth userga bog'lansa, ovqat ruxsati
-- ENDI o'sha USERNING rollaridan (rbac_user_role) olinadi, staff-rol
-- (rbac_staff_role) e'tiborsiz qoladi. Bog'lanmagan hodim — eskisidek
-- (rbac_staff_role, o'zgarish yo'q).
-- ---------------------------------------------------------------------
-- ## RUN TARTIBI (Asilbek) — bo'limlarni tartib bilan
--   0-BO'LIM — old shart tekshiruvi (faqat select)
--   1-BO'LIM — aros_staff.user_id + unique index
--   2-BO'LIM — rbac_staff_ovqat(int) — create or replace (imzo bir xil),
--              bog'langan bo'lsa user manbai, aks holda eskisidek
--   3-BO'LIM — ovqat_ruxsatlar(int[]) — create or replace, BITTA manba
--              (rbac_staff_ovqat chaqiradi — o'z so'rovi olib tashlandi)
--   4-BO'LIM — rbac_staff_royxat() — create or replace (imzo bir xil):
--              user_id/user_nom/taklif_user_id + top-level "users"
--   5-BO'LIM — rbac_staff_link_set(int, uuid) — admin-only bog'lash
--   6-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)
--
-- ## OLD SHART (bazada bo'lishi kerak)
--   PROVODKA_RBAC.sql         -> rbac_role, rbac_user_role, rbac_role_ovqat
--   PROVODKA_RBAC_STAFF.sql   -> rbac_staff_role, rbac_staff_ovqat(int),
--                                 ovqat_ruxsatlar(int[]), rbac_staff_royxat(),
--                                 rbac_staff_set(int,uuid[])
--   PROVODKA_OVQAT.sql        -> aros_staff, nom_norm(text)
--   PROVODKA_ISM.sql          -> profiles.full_name (IXTIYORIY — bo'lmasa
--                                 user_nom/taklif_user_id null qaytadi,
--                                 xato bermaydi, to_jsonb(pr) himoyasi bilan)
--
-- ## QOIDALAR (CLAUDE.md, buzilmadi)
--   * anonim `do` bloki YO'Q — har `do` bloki NOMLANGAN teg bilan.
--   * har funksiya tanasi NOMLANGAN dollar-teg (`fn`) bilan o'raladi.
--   * izohda dollar-qavs ($+$) YO'Q.
--   * hammasi additive: eski jadval/ustun/funksiya imzosi buzilmaydi
--     (rbac_staff_ovqat(int), ovqat_ruxsatlar(int[]), rbac_staff_royxat()
--     — uchalasi ham signature bo'yicha AYNAN saqlandi, faqat tana o'zgardi).
--   * idempotent: qayta RUN qilish xavfsiz.
--   * aros_staff_sync() ga TEGILMAYDI — uning upsert/update set ro'yxatida
--     user_id yo'q (0-BO'LIMda tekshiriladi), shuning uchun n8n sinxroni
--     admin qo'lda qo'ygan bog'lanishni hech qachon qayta yozib yubormaydi.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (faqat select)                 ##
-- #####################################################################

do $rbac_link_pre$
begin
  if to_regclass('public.aros_staff') is null then
    raise exception 'aros_staff jadvali yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;
  if to_regclass('public.profiles') is null then
    raise exception 'profiles jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regclass('public.rbac_role') is null then
    raise exception 'rbac_role jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_user_role') is null then
    raise exception 'rbac_user_role jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_staff_role') is null then
    raise exception 'rbac_staff_role jadvali yoq — avval PROVODKA_RBAC_STAFF.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_staff_ovqat(int)') is null then
    raise exception 'rbac_staff_ovqat(int) yoq — avval PROVODKA_RBAC_STAFF.sql ni bajaring';
  end if;
  if to_regprocedure('public.ovqat_ruxsatlar(int[])') is null then
    raise exception 'ovqat_ruxsatlar(int[]) yoq — avval PROVODKA_RBAC_STAFF.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_staff_royxat()') is null then
    raise exception 'rbac_staff_royxat() yoq — avval PROVODKA_RBAC_STAFF.sql ni bajaring';
  end if;
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'is_admin() funksiyasi yoq — RBAC_LINK unga tayanadi';
  end if;
  if to_regprocedure('public.nom_norm(text)') is null then
    raise exception 'nom_norm(text) funksiyasi yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;

  -- 🔴 aros_staff_sync() user_id ustuniga tegmasligi shart (SET ro'yxatida
  --    yo'q) — busiz n8n sinxroni admin bog'lagan hodim-user aloqasini
  --    har 30 daqiqada qayta yozib, tozalab yuborardi.
  if to_regprocedure('public.aros_staff_sync(jsonb)') is not null
     and position('user_id' in (select prosrc from pg_proc where proname = 'aros_staff_sync' limit 1)) > 0 then
    raise exception 'aros_staff_sync() ichida "user_id" so''zi topildi — bog''lanishni buzmasligini qo''lda tekshiring';
  end if;
end
$rbac_link_pre$;


-- #####################################################################
-- ##  1-BO'LIM — aros_staff.user_id + unique index                   ##
-- #####################################################################

alter table aros_staff
  add column if not exists user_id uuid references auth.users(id) on delete set null;

comment on column aros_staff.user_id is
  'Bog''langan Provodka auth useri (bo''lsa). Bitta user — bitta hodim (aros_staff_user_uniq). '
  'Bog''langanda ovqat ruxsati (rbac_staff_ovqat) rbac_staff_role EMAS, o''sha userning rbac_user_role '
  'rollaridan olinadi — admin userga rol berganda hodim ham avtomat o''sha huquqqa ega bo''ladi. '
  'Yozish faqat rbac_staff_link_set() orqali (admin). aros_staff_sync() bu ustunga TEGMAYDI.';

create unique index if not exists aros_staff_user_uniq
  on aros_staff (user_id)
  where user_id is not null;


-- #####################################################################
-- ##  2-BO'LIM — rbac_staff_ovqat(int) — create or replace           ##
-- ##  (imzo bir xil: int -> text[])                                  ##
-- #####################################################################
-- 🔴 Bog'langan hodim (user_id bor): manba USERNING rollari
--    (rbac_user_role ⋈ rbac_role_ovqat, UNION). Admin user (profiles.role
--    ='admin') bog'langan bo'lsa -> 3 turi ham (uy ishlarida cheklanmaydi,
--    boshqa har joyda admin ham shunday). Bog'lanmagan hodim — eskisidek
--    (rbac_staff_role, PROVODKA_RBAC_STAFF.sql bilan bir xil). Rol yo'q ->
--    {} (fail-closed) — ikkala shoxda ham.
create or replace function rbac_staff_ovqat(p_staff int)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_user_id  uuid;
  v_is_admin boolean;
  v_turlar   text[];
begin
  select user_id into v_user_id from aros_staff where staff_id = p_staff;

  if v_user_id is not null then
    select (role = 'admin') into v_is_admin from profiles where id = v_user_id;
    if coalesce(v_is_admin, false) then
      return array['obed', 'zavtrak', 'kechki'];
    end if;

    select coalesce(array_agg(distinct ro.tur), '{}'::text[]) into v_turlar
      from rbac_user_role ur
      join rbac_role r on r.id = ur.role_id and r.is_active
      join rbac_role_ovqat ro on ro.role_id = ur.role_id
     where ur.user_id = v_user_id;

    return v_turlar;
  end if;

  select coalesce(array_agg(distinct ro.tur), '{}'::text[]) into v_turlar
    from rbac_staff_role sr
    join rbac_role r on r.id = sr.role_id and r.is_active
    join rbac_role_ovqat ro on ro.role_id = sr.role_id
   where sr.staff_id = p_staff;

  return v_turlar;
end
$fn$;

revoke all on function rbac_staff_ovqat(int) from public, anon;
grant execute on function rbac_staff_ovqat(int) to authenticated, service_role;

comment on function rbac_staff_ovqat(int) is
  'Hodimning (aros_staff.staff_id) o''zi ruxsatli ovqat turlari. Bog''langan bo''lsa (user_id) '
  'manba rbac_user_role (auth user rollari, admin -> 3 turi); bog''lanmagan bo''lsa rbac_staff_role '
  '(PROVODKA_RBAC_STAFF.sql, eskisidek). Rol yo''q -> {} (fail-closed).';


-- #####################################################################
-- ##  3-BO'LIM — ovqat_ruxsatlar(int[]) — BITTA manba                ##
-- #####################################################################
-- 🔴 Avval o'zining group-by so'rovi bor edi (rbac_staff_role to'g'ridan
--    o'qir edi) — endi rbac_staff_ovqat(staff_id) ni har hodim uchun
--    chaqiradi, ya'ni bog'lanish mantiqi BITTA joyda (2-BO'LIM). Imzo va
--    javob shakli ({ "<staff_id>": [...] }) o'zgarmadi.
create or replace function ovqat_ruxsatlar(p_staff int[] default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(jsonb_object_agg(s.staff_id::text, to_jsonb(rbac_staff_ovqat(s.staff_id))), '{}'::jsonb)
    from aros_staff s
   where s.is_active
     and (p_staff is null or s.staff_id = any(p_staff));
$fn$;

revoke all on function ovqat_ruxsatlar(int[]) from public, anon;
grant execute on function ovqat_ruxsatlar(int[]) to authenticated;

comment on function ovqat_ruxsatlar(int[]) is
  'Klient uchun: hodimlarning ruxsatli ovqat turlari, BITTA manba — rbac_staff_ovqat(staff_id) '
  '(bog''langan userniki yoki hodim roli, 2-BO''LIM). p_staff null -> hamma faol hodim.';


-- #####################################################################
-- ##  4-BO'LIM — rbac_staff_royxat() — create or replace (imzo bir xil) ##
-- #####################################################################
-- 🔴 PROVODKA_RBAC_STAFF.sql 4.1 dagi tana asosida — eski maydonlar
--    VERBATIM saqlanadi (staff_id, toliq_nom, lavozim, branch_nomi,
--    rollar, va tashqi "rollar" ro'yxati). Qo'shilgani:
--      * har hodimga: user_id, user_nom (profiles.full_name, bog'liq bo'lsa),
--        taklif_user_id (bog'lanmagan bo'lsa: nom_norm(toliq_nom) =
--        nom_norm(full_name) bo'lgan YAGONA, hali hech kimga bog'lanmagan
--        user bo'lsa — bir nechta mos kelsa taklif YO'Q, aniqlik yo'q).
--      * top-level "users": profiles ro'yxati (id, full_name, role) —
--        admin UI'da tanlov (dropdown) uchun.
--    profiles.full_name PROVODKA_ISM.sql bilan qo'shiladi — SHART EMAS,
--    to_jsonb(pr)->>'full_name' orqali xavfsiz o'qiladi (ustun yo'q bo'lsa
--    ham CREATE vaqtida xato bermaydi, faqat qiymat null bo'ladi).
create or replace function rbac_staff_royxat()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not is_admin() then
    raise exception 'Faqat admin hodim-rol ro''yxatini ko''ra oladi' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'hodimlar', coalesce((
      select jsonb_agg(jsonb_build_object(
          'staff_id',       s.staff_id,
          'toliq_nom',      coalesce(nullif(btrim(s.toliq_nom), ''),
                                      btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))),
          'lavozim',        s.lavozim,
          'branch_nomi',    s.branch_nomi,
          'rollar',         coalesce((
            select jsonb_agg(jsonb_build_object('id', r.id, 'nom', r.nom) order by r.nom)
              from rbac_staff_role sr
              join rbac_role r on r.id = sr.role_id
             where sr.staff_id = s.staff_id), '[]'::jsonb),
          'user_id',        s.user_id,
          'user_nom',       case when s.user_id is not null then (
                               select to_jsonb(pr) ->> 'full_name' from profiles pr where pr.id = s.user_id
                             ) end,
          'taklif_user_id', case when s.user_id is null then (
                               select pr.id from profiles pr
                                where nom_norm(to_jsonb(pr) ->> 'full_name') = nom_norm(
                                        coalesce(nullif(btrim(s.toliq_nom), ''),
                                                 btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))))
                                  and nom_norm(to_jsonb(pr) ->> 'full_name') is not null
                                  and not exists (select 1 from aros_staff s2 where s2.user_id = pr.id)
                                having count(*) = 1
                                group by pr.id
                             ) end
        ) order by coalesce(nullif(btrim(s.toliq_nom), ''), s.staff_id::text))
      from aros_staff s
     where s.is_active), '[]'::jsonb),
    'rollar', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id',    r.id,
          'nom',   r.nom,
          'ovqat', coalesce((select jsonb_agg(ro.tur order by ro.tur)
                                from rbac_role_ovqat ro where ro.role_id = r.id), '[]'::jsonb)
        ) order by r.nom)
      from rbac_role r
     where r.is_active), '[]'::jsonb),
    'users', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id',        pr.id,
          'full_name', coalesce(to_jsonb(pr) ->> 'full_name', ''),
          'role',      pr.role
        ) order by coalesce(to_jsonb(pr) ->> 'full_name', pr.id::text))
      from profiles pr), '[]'::jsonb)
  );
end
$fn$;

revoke all on function rbac_staff_royxat() from public, anon;
grant execute on function rbac_staff_royxat() to authenticated;

comment on function rbac_staff_royxat() is
  'Admin: faol aros_staff hodimlari (rollari + user_id/user_nom/taklif_user_id bilan), '
  'tanlash uchun faol rollar ro''yxati va profiles foydalanuvchilar ro''yxati (users, bog''lash uchun).';


-- #####################################################################
-- ##  5-BO'LIM — rbac_staff_link_set(int, uuid) — admin-only bog'lash ##
-- #####################################################################

create or replace function rbac_staff_link_set(p_staff int, p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_snom       text;
  v_other_id   int;
  v_other_snom text;
begin
  if not is_admin() then
    raise exception 'Faqat admin hodim-user bog''lanishini o''zgartira oladi' using errcode = '42501';
  end if;

  select coalesce(nullif(btrim(toliq_nom), ''), btrim(coalesce(ism, '') || ' ' || coalesce(familiya, '')))
    into v_snom
    from aros_staff where staff_id = p_staff;
  if v_snom is null then
    raise exception 'Hodim topilmadi: %', p_staff using errcode = '22023';
  end if;

  if p_user is null then
    update aros_staff set user_id = null where staff_id = p_staff;
    return jsonb_build_object('ok', true, 'staff_id', p_staff, 'user_id', null);
  end if;

  if not exists (select 1 from profiles where id = p_user) then
    raise exception 'Foydalanuvchi topilmadi: %', p_user using errcode = '22023';
  end if;

  select s.staff_id,
         coalesce(nullif(btrim(s.toliq_nom), ''), btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, '')))
    into v_other_id, v_other_snom
    from aros_staff s
   where s.user_id = p_user and s.staff_id <> p_staff;

  if v_other_id is not null then
    raise exception 'Bu akkaunt allaqachon boshqa hodimga bog''langan: % (staff_id=%)', v_other_snom, v_other_id
      using errcode = '23505';
  end if;

  update aros_staff set user_id = p_user where staff_id = p_staff;

  return jsonb_build_object('ok', true, 'staff_id', p_staff, 'user_id', p_user);
end
$fn$;

revoke all on function rbac_staff_link_set(int, uuid) from public, anon;
grant execute on function rbac_staff_link_set(int, uuid) to authenticated;

comment on function rbac_staff_link_set(int, uuid) is
  'Admin: hodim (aros_staff.staff_id) ni auth userga bog''laydi. p_user null -> bog''lanishni o''chiradi. '
  'Boshqa hodimga bog''langan userni qayta bog''lashga urinsa aniq xabar bilan rad etadi (unique index).';


-- #####################################################################
-- ##  6-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)             ##
-- #####################################################################

do $rbac_link_check$
declare
  v_n int;
begin
  -- 1) Ustun + unique index
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'aros_staff' and column_name = 'user_id'
  ) then
    raise exception 'aros_staff.user_id ustuni yaratilmadi';
  end if;

  if not exists (
    select 1 from pg_indexes
     where schemaname = 'public' and tablename = 'aros_staff' and indexname = 'aros_staff_user_uniq'
  ) then
    raise exception 'aros_staff_user_uniq indeksi yaratilmadi';
  end if;

  -- 2) Funksiyalar (imzo bo'yicha, eskisi bilan bir xil)
  if to_regprocedure('public.rbac_staff_ovqat(int)') is null then
    raise exception 'rbac_staff_ovqat(int) yo''qolib qolgan';
  end if;
  if to_regprocedure('public.ovqat_ruxsatlar(int[])') is null then
    raise exception 'ovqat_ruxsatlar(int[]) yo''qolib qolgan';
  end if;
  if to_regprocedure('public.rbac_staff_royxat()') is null then
    raise exception 'rbac_staff_royxat() yo''qolib qolgan';
  end if;
  if to_regprocedure('public.rbac_staff_link_set(int, uuid)') is null then
    raise exception 'rbac_staff_link_set(int, uuid) yaratilmadi';
  end if;

  -- 3) Yangi mantiq joylashganini tekshirish (tana ichida kalit so'z bormi)
  if position('user_id' in (select prosrc from pg_proc where proname = 'rbac_staff_ovqat' limit 1)) = 0 then
    raise exception 'rbac_staff_ovqat() ichida user_id shoxi yo''q — yangilanmadi';
  end if;
  if position('rbac_staff_ovqat' in (select prosrc from pg_proc where proname = 'ovqat_ruxsatlar' limit 1)) = 0 then
    raise exception 'ovqat_ruxsatlar() endi rbac_staff_ovqat ni chaqirmayapti — bitta manba buzildi';
  end if;
  if position('taklif_user_id' in (select prosrc from pg_proc where proname = 'rbac_staff_royxat' limit 1)) = 0 then
    raise exception 'rbac_staff_royxat() ichida taklif_user_id yo''q — yangilanmadi';
  end if;

  -- 4) Grant sanity
  if not has_function_privilege('authenticated', 'public.rbac_staff_link_set(int, uuid)', 'execute') then
    raise exception 'rbac_staff_link_set(int, uuid) authenticated uchun yopiq — admin UI ishlamaydi';
  end if;
  if has_function_privilege('anon', 'public.rbac_staff_link_set(int, uuid)', 'execute') then
    raise exception 'rbac_staff_link_set(int, uuid) anon uchun ochiq qolgan';
  end if;
  if has_function_privilege('anon', 'public.rbac_staff_ovqat(int)', 'execute') then
    raise exception 'rbac_staff_ovqat(int) anon uchun ochiq qolgan';
  end if;

  select count(*) into v_n from aros_staff where user_id is not null;
  raise notice 'RBAC_LINK tayyor. Hozircha bog''langan hodim: % ta', v_n;
end
$rbac_link_check$;

-- Sxema keshi — busiz yangi RPC 404 beradi.
notify pgrst, 'reload schema';
