-- ============================================================================
--  PROVODKA_HODIM_FILIAL_OVERRIDE.sql — 2026-10-04 — Hodim ↔ Filial OVERRIDE (qo'lda almashtirish / olib tashlash / ko'p filial)
--  Asilbek: «hodimlar staffdan import bo'lgani bo'yicha tushyapti — override kerak: filialini almashtirish yoki
--  butunlay o'chirib tashlash, multiselect; override hamma joyda o'zgarsin; staffdan qayta import qilganda override'dan
--  boshqalari o'zgaradi».
--
--  MODEL
--   * hodim_filial_override(staff_id PK, filial_ids uuid[]) — qator BOR = a'zolik AYNAN shu ro'yxat (Aros ignor);
--     bo'sh massiv = FILIALSIZ (hech qaysi filial). Qator YO'Q = eski qoida (Aros branch_id/branches[] +
--     staff_branch_map + staff_filial_qolda). aros_staff_sync() bu jadvalga TEGMAYDI → qayta import override'ni buzmaydi.
--   * YAGONA predikat: hodim_filial_azo(staff_id, filial). Shu fayl undan foydalanish uchun QAYTA E'LON qiladi:
--     hodim_filialda (→ filial_begona_userlar / filial_hodim_sarf / mening_filiallarim / limit_guard / standart_holat
--     avtomat), standart_filial_moddalar, standart_filial_limit_sarf (tana PROVODKA_LIMIT_FILIAL_SARF_3.sql dan
--     VERBATIM, faqat predikat), standart_hodim_limitlar (PROVODKA_STANDART_HODIM_FIX.sql dan VERBATIM, predikat +
--     filial_nom). Imzo/returns o'zgarmagan.
--   * Admin RPC (sozlama-dev «Hodim → Filial»): hodim_filial_royxat / hodim_filial_set / hodim_filial_clear;
--     ruxsat hodim_filial_page_ok() = admin YOKI perm_has_page('sozlama') (hodim_tg_page_ok bilan bir xil).
--   * hodim-dev ovqat ro'yxati: ovqat_mening_staff(p_filial_nom) → int[] (klient tomondagi branches[] filtri o'rniga).
--  Tegilmagan: standart_branch_takliflar / standart_filial_moddalar.branchlar.hodim_soni (bular AROS BO'LIMI bo'yicha
--  sanoq — filial a'zoligi emas, bog'lash UI uchun). Asilbek RUN qiladi. Idempotent.
-- ============================================================================

-- ######## 1) JADVAL ########
create table if not exists hodim_filial_override (
  staff_id   int         primary key references aros_staff(staff_id) on delete cascade,
  filial_ids uuid[]      not null default '{}'::uuid[],
  izoh       text,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
comment on table hodim_filial_override is
  'Hodim filial a''zoligini QO''LDA belgilash. Qator bor = a''zolik AYNAN filial_ids (Aros ignor); bo''sh massiv = filialsiz. '
  'Qator yo''q = Aros (branch_id/branches + staff_branch_map) + staff_filial_qolda. aros_staff_sync() TEGMAYDI.';
alter table hodim_filial_override enable row level security;
drop policy if exists hodim_filial_override_sel on hodim_filial_override;
create policy hodim_filial_override_sel on hodim_filial_override for select to authenticated using (true);
revoke all on hodim_filial_override from public, anon;
grant select on hodim_filial_override to authenticated;
-- yozish faqat RPC (security definer) orqali — insert/update/delete policy YO'Q.

-- ######## 2) RUXSAT ########
create or replace function hodim_filial_page_ok()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then return false; end if;
  if is_admin() then return true; end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'perm_has_page') then
    return perm_has_page('sozlama');
  end if;
  return false;
end
$fn$;
revoke all on function hodim_filial_page_ok() from public, anon;
grant execute on function hodim_filial_page_ok() to authenticated;

-- ######## 3) YADRO ########
-- Aros + qolda bo'yicha hodimning filiallari (override HISOBGA OLINMAYDI — xom manba, UI «Aros» ustuni uchun)
create or replace function hodim_filial_aros(p_staff int)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce((
    select array_agg(distinct a.id)
      from accounts a
     where a.kassa_turi = 'filial' and a.parent_id is null and coalesce(a.is_active, true)
       and (
         exists (
           select 1 from staff_branch_map m
             join aros_staff s on s.staff_id = p_staff
            where (m.filial_id = a.id or m.provodka_filial = a.name)
              and (
                s.branch_id = m.branch_id
                or exists (select 1 from jsonb_array_elements(coalesce(s.branches, '[]'::jsonb)) b
                            where (b ->> 'id') ~ '^\d+$' and (b ->> 'id')::int = m.branch_id)
              )
         )
         or exists (select 1 from staff_filial_qolda q where q.staff_id = p_staff and q.filial_id = a.id)
       )
  ), '{}'::uuid[]);
$fn$;
revoke all on function hodim_filial_aros(int) from public, anon;
grant execute on function hodim_filial_aros(int) to authenticated;

-- Effektiv filiallar: override bo'lsa o'sha (bo'sh = filialsiz), aks holda Aros+qolda
create or replace function hodim_filiallari(p_staff int)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(
    (select o.filial_ids from hodim_filial_override o where o.staff_id = p_staff),
    hodim_filial_aros(p_staff)
  );
$fn$;
revoke all on function hodim_filiallari(int) from public, anon;
grant execute on function hodim_filiallari(int) to authenticated;

-- 🔴 YAGONA PREDIKAT: hodim shu filialning a'zosimi
create or replace function hodim_filial_azo(p_staff int, p_filial uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_ov   uuid[];
  v_nom  text;
begin
  if p_staff is null or p_filial is null then return false; end if;
  select filial_ids into v_ov from hodim_filial_override where staff_id = p_staff;
  if found then
    return p_filial = any(v_ov);                       -- override: AYNAN ro'yxat (bo'sh = hech qaysi)
  end if;
  select name into v_nom from accounts where id = p_filial;
  return exists (
    select 1 from aros_staff s
     where s.staff_id = p_staff
       and (
         exists (
           select 1 from staff_branch_map m
            where (m.filial_id = p_filial or m.provodka_filial = v_nom)
              and (
                s.branch_id = m.branch_id
                or exists (select 1 from jsonb_array_elements(coalesce(s.branches, '[]'::jsonb)) b
                            where (b ->> 'id') ~ '^\d+$' and (b ->> 'id')::int = m.branch_id)
              )
         )
         or exists (select 1 from staff_filial_qolda q where q.staff_id = s.staff_id and q.filial_id = p_filial)
       )
  );
end
$fn$;
revoke all on function hodim_filial_azo(int, uuid) from public, anon;
grant execute on function hodim_filial_azo(int, uuid) to authenticated;

-- Ko'rinish uchun: filial nomlari «A, B» (bo'sh = '')
create or replace function hodim_filial_nomlar(p_staff int)
returns text
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce((select string_agg(a.name, ', ' order by a.name)
                     from accounts a where a.id = any(hodim_filiallari(p_staff))), '');
$fn$;
revoke all on function hodim_filial_nomlar(int) from public, anon;
grant execute on function hodim_filial_nomlar(int) to authenticated;

-- ######## 4) hodim_filialda(uid, filial) — imzo saqlanadi, tana YADROga delegat ########
--    (filial_begona_userlar / filial_hodim_sarf / mening_filiallarim / limit_guard_entry_line / standart_holat shundan)
create or replace function hodim_filialda(p_uid uuid, p_filial uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_staff int;
begin
  if p_uid is null or p_filial is null then return false; end if;
  select staff_id into v_staff from aros_staff where user_id = p_uid limit 1;
  if v_staff is null then return false; end if;
  return hodim_filial_azo(v_staff, p_filial);
end
$fn$;
revoke all on function hodim_filialda(uuid, uuid) from public, anon;
grant execute on function hodim_filialda(uuid, uuid) to authenticated;

-- ######## 5) standart_* — tanalar VERBATIM, faqat a'zolik predikati ########

create or replace function standart_filial_moddalar(p_filial uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_begona    text[];   -- 🔴 2026-10-02: shu filialga a'zo bo'lmagan hodimlar (user_id matn)
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

  v_begona := filial_begona_userlar(v_filial_id);   -- 🔴 2026-10-02
  select coalesce(array_agg(m.branch_id), '{}'::int[]) into v_bids
    from staff_branch_map m
   where m.filial_id = v_filial_id or m.provodka_filial = v_filial_nom;

  return (
    with staff_in as (
      select s.staff_id,
             coalesce(nullif(btrim(s.toliq_nom), ''),
                      btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))) as nom,
             s.lavozim, s.user_id
        from aros_staff s
       where s.is_active
         -- 🔴 2026-10-04 (OVERRIDE): a'zolik YAGONA manbadan — hodim_filial_azo() (override > Aros+qolda)
         and hodim_filial_azo(s.staff_id, v_filial_id)
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
                        and not coalesce(am.ovqat_modda, false)
      union all
      -- 🔴 OVQAT moddasi: limit rbac_role_modda da EMAS — rbac_role_ovqat da
      -- (rol × obed/zavtrak/kechki). Rol limiti = turlar yig'indisi; bittasi
      -- cheksiz bo'lsa cheksiz.
      select sr.staff_id, si.nom, am.id as modda_id,
             case when bool_or(ro.limit_uzs is null) then null else sum(ro.limit_uzs) end
        from staff_role sr
        join staff_in si on si.staff_id = sr.staff_id
        join rbac_role_ovqat ro on ro.role_id = sr.role_id
        cross join (select a.id from accounts a
                     where coalesce(a.ovqat_modda, false) and a.type = 'xarajat'
                       and coalesce(a.is_active, true)) am
       group by sr.staff_id, si.nom, am.id, sr.role_id
      union all
      select sa.staff_id, si.nom, a.id as modda_id, null::numeric as limit_uzs
        from staff_admin sa
        join staff_in si on si.staff_id = sa.staff_id
        cross join accounts a
       where a.type = 'xarajat' and coalesce(a.is_active, true)
    ),
    -- Har hodimning shu moddaga EFFEKTIV limiti: rollari ichidan MAX, bittasi cheksiz → cheksiz
    hodim_lim as (
      select z.staff_id, z.modda_id,
             bool_or(z.limit_uzs is null) as cheksiz,
             max(z.limit_uzs)             as lim
        from modda_z z
       group by z.staff_id, z.modda_id
    ),
    -- Shu oyda FILIAL bo'yicha sarf (entry.filial_ids; posted+pending) — standart_holat bilan bir manba
    modda_sarf as (
      select h.modda_id,
             coalesce((select sum(el.debit)
                         from entry e
                         join entry_line el on el.entry_id = e.id and el.account_id = h.modda_id and el.debit > 0
                        where e.is_deleted = false and e.status in ('posted', 'pending')
                          and date_trunc('month', e.entry_date)
                              = date_trunc('month', (now() at time zone 'Asia/Tashkent')::date)
                          and v_filial_id = any(e.filial_ids)
                          and not (coalesce(to_jsonb(e) ->> 'created_by', '') = any(v_begona))), 0) as sarf_uzs   -- 🔴 2026-10-02
        from (select distinct modda_id from modda_z) h
    ),
    modda_agg as (
      select z.modda_id,
             count(distinct z.staff_id)::int as hodim_soni,
             to_jsonb(array_agg(distinct z.nom order by z.nom)) as hodimlar,
             min(z.limit_uzs) filter (where z.limit_uzs is not null) as rol_limit_min,
             max(z.limit_uzs) filter (where z.limit_uzs is not null) as rol_limit_max,
             bool_or(z.limit_uzs is null) as cheksiz_bor,
             -- JAMI = filial hodimlari effektiv limitlari yig'indisi (Asilbek: «jami necha pul ruxsat berilgan»)
             (select sum(hl.lim) filter (where not hl.cheksiz) from hodim_lim hl where hl.modda_id = z.modda_id) as rol_limit_jami,
             (select ms.sarf_uzs from modda_sarf ms where ms.modda_id = z.modda_id) as sarf_uzs
        from modda_z z
       group by z.modda_id
    ),
    -- Filialga bog'langan Aros bo'limlar (filial_id VA provodka_filial ikkalasidan
    -- ham — v_bids bilan bir xil manba), UI'da "Bo'limlar: X (N hodim)" uchun.
    branch_in as (
      select m.branch_id, m.branch_nomi
        from staff_branch_map m
       where m.filial_id = v_filial_id or m.provodka_filial = v_filial_nom
    )
    select jsonb_build_object(
      'filial', jsonb_build_object('id', v_filial_id, 'name', v_filial_nom),
      'bog_yoq', (array_length(v_bids, 1) is null),
      'branchlar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'branch_id',   bi.branch_id,
                 'branch_nomi', bi.branch_nomi,
                 'hodim_soni',  (
                   select count(*) from aros_staff s2
                    where s2.is_active
                      and (s2.branch_id = bi.branch_id
                           or exists (
                             select 1 from jsonb_array_elements(coalesce(s2.branches, '[]'::jsonb)) b2
                              where (b2 ->> 'id') ~ '^\d+$' and (b2 ->> 'id')::int = bi.branch_id
                           ))
                 )
               ) order by bi.branch_nomi)
          from branch_in bi
      ), '[]'::jsonb),
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
                 'modda_id',             ma.modda_id,
                 'code',                 a.code,
                 'name',                 a.name,
                 'hodim_soni',           ma.hodim_soni,
                 'hodimlar',             ma.hodimlar,
                 'rol_limit_min',        ma.rol_limit_min,
                 'rol_limit_max',        ma.rol_limit_max,
                 'rol_limit_jami',       ma.rol_limit_jami,
                 'sarf_uzs',             ma.sarf_uzs,
                 'cheksiz_bor',          ma.cheksiz_bor,
                 'filial_limit_uzs',     case when sx.id is null then null
                                              when coalesce(sx.valyuta, 'UZS') = 'UZS' then coalesce(sx.limit_uzs, sx.limit_val)
                                              else standart_limit_uzs(sx.limit_val, sx.valyuta) end,
                 'filial_limit_val',     sx.limit_val,
                 'filial_limit_valyuta', coalesce(sx.valyuta, 'UZS')
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

create or replace function standart_filial_limit_sarf(p_filial uuid,
                                                      p_oy date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_begona    text[];   -- 🔴 2026-10-02
  v_page_ok    boolean := false;
  v_filial_id  uuid;
  v_filial_nom text;
  v_bids       int[];
  v_oy         date;
begin
  if auth.uid() is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  -- Ruxsat: standart_filial_moddalar bilan AYNAN bir xil qoida.
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

  v_oy := date_trunc('month', coalesce(p_oy, (now() at time zone 'Asia/Tashkent')::date))::date;

  select id, name into v_filial_id, v_filial_nom
    from accounts
   where id = p_filial
     and kassa_turi = 'filial'
     and parent_id is null
     and coalesce(is_active, true);
  if v_filial_id is null then
    raise exception 'Filial topilmadi: %', p_filial using errcode = '22023';
  end if;
  v_begona := filial_begona_userlar(v_filial_id);   -- 🔴 2026-10-02

  select coalesce(array_agg(m.branch_id), '{}'::int[]) into v_bids
    from staff_branch_map m
   where m.filial_id = v_filial_id or m.provodka_filial = v_filial_nom;

  return (
    with staff_in as (
      select s.staff_id,
             coalesce(nullif(btrim(s.toliq_nom), ''),
                      btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))) as nom,
             s.lavozim, s.user_id
        from aros_staff s
       where s.is_active
         -- 🔴 2026-10-04 (OVERRIDE): a'zolik YAGONA manbadan — hodim_filial_azo() (override > Aros+qolda)
         and hodim_filial_azo(s.staff_id, v_filial_id)
    ),
    staff_admin as (
      select si.staff_id
        from staff_in si
        join profiles p on p.id = si.user_id
       where si.user_id is not null and p.role = 'admin'
    ),
    staff_role as (
      select si.staff_id, r.id as role_id
        from staff_in si
        join rbac_user_role ur on ur.user_id = si.user_id
        join rbac_role r on r.id = ur.role_id and r.is_active
       where si.user_id is not null
         and not exists (select 1 from staff_admin sa where sa.staff_id = si.staff_id)
      union all
      select si.staff_id, r.id
        from staff_in si
        join rbac_staff_role sr on sr.staff_id = si.staff_id
        join rbac_role r on r.id = sr.role_id and r.is_active
       where si.user_id is null
    ),
    -- 🔴 HODIMNING O'Z KASSASI (5400 ostidagi 54xx, kassa_turi='xarajat') —
    -- filial kassasi EMAS. Bog'lanish nom bo'yicha: kassa nomi = hodim ismi
    -- (TaskFix shunday ochadi). Nomlar normallashtiriladi (registr + probel +
    -- tinish belgisi olib tashlanadi); bir nechta mos kassa bo'lsa yig'iladi.
    hodim_kassa as (
      select si.staff_id, sum(coalesce(k.jami, 0)) as kassa_uzs
        from staff_in si
        join accounts a
          on a.kassa_turi = 'xarajat'
         and coalesce(a.is_active, true)
         and nullif(lower(regexp_replace(a.name,  '[^[:alnum:]]', '', 'g')), '')
           = nullif(lower(regexp_replace(si.nom, '[^[:alnum:]]', '', 'g')), '')
        left join v_kassa_card k on k.id = a.id
       group by si.staff_id
    ),
    -- Ovqat moddasi (accounts.ovqat_modda) ALOHIDA: limiti rbac_role_ovqat da
    -- (obed/zavtrak/kechki), yeyilgani entry_ovqat da — pastdagi ov_* CTE'lar.
    ov_modda as (
      select a.id from accounts a
       where coalesce(a.ovqat_modda, false) and a.type = 'xarajat' and coalesce(a.is_active, true)
    ),
    -- Hodim × modda (ovqat moddasidan tashqari): rol orqali + admin (hamma modda, cheksiz).
    hm_raw as (
      select sr.staff_id, am.id as modda_id, rm.limit_uzs
        from staff_role sr
        join rbac_role_modda rm on rm.role_id = sr.role_id
        join accounts am on am.id = rm.account_id
                        and am.type = 'xarajat'
                        and coalesce(am.is_active, true)
                        and not coalesce(am.ovqat_modda, false)
      union all
      select sa.staff_id, a.id, null::numeric
        from staff_admin sa
        cross join accounts a
       where a.type = 'xarajat' and coalesce(a.is_active, true)
         and not coalesce(a.ovqat_modda, false)
    ),
    hm as (
      select r.staff_id, r.modda_id,
             bool_or(r.limit_uzs is null)                                  as cheksiz,
             max(r.limit_uzs)                                              as limit_uzs
        from hm_raw r
       group by r.staff_id, r.modda_id
    ),
    -- Hodim satridagi sarf: o'zi yozgani (entry.created_by).
    sarf as (
      select h.staff_id, h.modda_id,
             coalesce((
               select sum(el.debit)
                 from entry_line el
                 join entry e on e.id = el.entry_id
                where el.account_id = h.modda_id
                  and el.debit > 0
                  and e.is_deleted = false
                  and e.status in ('posted', 'pending')
                  and date_trunc('month', e.entry_date) = v_oy
                  and (to_jsonb(e) ->> 'created_by') = si.user_id::text
             ), 0) as sarf_uzs
        from hm h
        join staff_in si on si.staff_id = h.staff_id
       where si.user_id is not null
    ),
    hm_full as (
      select h.staff_id, si.nom, si.lavozim, (si.user_id is not null) as bog_langan,
             h.modda_id, null::text as tur, h.cheksiz, h.limit_uzs,
             coalesce(s.sarf_uzs, 0)  as sarf_uzs,
             coalesce(hk.kassa_uzs, 0) as kassa_uzs
        from hm h
        join staff_in si on si.staff_id = h.staff_id
        left join sarf s        on s.staff_id  = h.staff_id and s.modda_id = h.modda_id
        left join hodim_kassa hk on hk.staff_id = h.staff_id
    ),
    -- 🔴 OVQAT: hodim × tur limiti — rbac_limit_ovqat_staff bilan AYNAN bir xil
    -- manba (user_id bog'langan → rbac_user_role, aks holda rbac_staff_role);
    -- rollar ichidan MAX, bittasi cheksiz bo'lsa cheksiz. Tur rolda yo'q → satr yo'q.
    ov_lim as (
      select si.staff_id, t.tur,
             bool_or(ro.limit_uzs is null) as cheksiz,
             max(ro.limit_uzs)             as limit_uzs
        from staff_in si
        cross join unnest(array['obed', 'zavtrak', 'kechki']) as t(tur)
        join lateral (
          select ro.role_id, ro.limit_uzs
            from rbac_user_role ur
            join rbac_role r on r.id = ur.role_id and r.is_active
            join rbac_role_ovqat ro on ro.role_id = ur.role_id and ro.tur = t.tur
           where si.user_id is not null and ur.user_id = si.user_id
          union all
          select ro.role_id, ro.limit_uzs
            from rbac_staff_role sr
            join rbac_role r on r.id = sr.role_id and r.is_active
            join rbac_role_ovqat ro on ro.role_id = sr.role_id and ro.tur = t.tur
           where si.user_id is null and sr.staff_id = si.staff_id
        ) ro on true
       group by si.staff_id, t.tur
    ),
    -- Yeyilgani: entry_ovqat (yeyuvchi hodim bo'yicha, kim yozganidan qat'i nazar).
    ov_full as (
      select si.staff_id, si.nom, si.lavozim, (si.user_id is not null) as bog_langan,
             am.id as modda_id, ol.tur, ol.cheksiz,
             case when ol.cheksiz then null else ol.limit_uzs end as limit_uzs,
             rbac_ovqat_ishlatildi(si.staff_id, ol.tur, v_oy)      as sarf_uzs,
             coalesce(hk.kassa_uzs, 0)                              as kassa_uzs
        from ov_lim ol
        join staff_in si on si.staff_id = ol.staff_id
        cross join ov_modda am
        left join hodim_kassa hk on hk.staff_id = si.staff_id
    ),
    all_full as (
      select * from hm_full
      union all
      select * from ov_full
    ),
    -- Modda bo'yicha jami sarf: filial kesimi (kim yozganidan qat'i nazar).
    sarf_filial as (
      select h.modda_id,
             coalesce((
               select sum(el.debit)
                 from entry e
                 join entry_line el on el.entry_id = e.id
                                   and el.account_id = h.modda_id
                                   and el.debit > 0
                where e.is_deleted = false
                  and e.status in ('posted', 'pending')
                  and date_trunc('month', e.entry_date) = v_oy
                  and v_filial_id = any(e.filial_ids)
                  and not (coalesce(to_jsonb(e) ->> 'created_by', '') = any(v_begona))   -- 🔴 2026-10-02
             ), 0) as sarf_uzs
        from (select distinct modda_id from all_full) h
    ),
    modda_agg as (
      select f.modda_id,
             count(*)::int                                                  as hodim_soni,
             bool_or(f.cheksiz)                                             as cheksiz_bor,
             sum(f.limit_uzs) filter (where not f.cheksiz)                  as limit_jami,
             max(sf.sarf_uzs)                                               as sarf_jami,
             jsonb_agg(jsonb_build_object(
               'staff_id',   f.staff_id,
               'nom',        f.nom,
               'lavozim',    f.lavozim,
               'tur',        f.tur,
               'bog_langan', f.bog_langan,
               'cheksiz',    f.cheksiz,
               'limit_uzs',  f.limit_uzs,
               'sarf_uzs',   f.sarf_uzs,
               'kassa_uzs',  f.kassa_uzs,
               'qoldi_uzs',  case when f.cheksiz or f.limit_uzs is null then null
                                  else greatest(0, f.limit_uzs - f.sarf_uzs) end
             ) order by f.nom, f.tur)                                       as hodimlar
        from all_full f
        join sarf_filial sf on sf.modda_id = f.modda_id
       group by f.modda_id
    )
    select jsonb_build_object(
      'ok',     true,
      'oy',     to_char(v_oy, 'YYYY-MM'),
      'filial', jsonb_build_object('id', v_filial_id, 'name', v_filial_nom),
      -- Filial hodimlarining O'Z kassalaridagi jonli pul (filial kassasi emas).
      'kassa_qoldiq_uzs', (select coalesce(sum(hk.kassa_uzs), 0) from hodim_kassa hk),
      'jami', jsonb_build_object(
        'limit_uzs', (select coalesce(sum(ma.limit_jami), 0) from modda_agg ma),
        'sarf_uzs',  (select coalesce(sum(ma.sarf_jami), 0)  from modda_agg ma),
        'qoldi_uzs', (select greatest(0, coalesce(sum(ma.limit_jami), 0) - coalesce(sum(ma.sarf_jami), 0))
                        from modda_agg ma)
      ),
      'moddalar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'modda_id',    ma.modda_id,
                 'code',        a.code,
                 'name',        a.name,
                 'hodim_soni',  ma.hodim_soni,
                 'cheksiz_bor', ma.cheksiz_bor,
                 'limit_uzs',   ma.limit_jami,
                 'sarf_uzs',    ma.sarf_jami,
                 'qoldi_uzs',   case when ma.limit_jami is null then null
                                     else greatest(0, ma.limit_jami - ma.sarf_jami) end,
                 'foiz',        case when coalesce(ma.limit_jami, 0) > 0
                                     then least(999, round(ma.sarf_jami / ma.limit_jami * 100))
                                     else null end,
                 'hodimlar',    ma.hodimlar
               ) order by (ma.limit_jami is null), coalesce(ma.sarf_jami, 0) desc, a.code)
          from modda_agg ma
          join accounts a on a.id = ma.modda_id
      ), '[]'::jsonb)
    )
  );
end
$fn$;

revoke all on function standart_filial_limit_sarf(uuid, date) from public, anon;
grant execute on function standart_filial_limit_sarf(uuid, date) to authenticated;

create or replace function standart_hodim_limitlar(p_filial uuid default null, p_oy date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_oy         date;
  v_filial_id  uuid;
  v_filial_nom text;
  v_bids       int[];
begin
  if not standart_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  v_oy := date_trunc('month', coalesce(p_oy, (now() at time zone 'Asia/Tashkent')::date))::date;

  if p_filial is not null then
    select id, name into v_filial_id, v_filial_nom
      from accounts
     where id = p_filial
       and kassa_turi = 'filial'
       and parent_id is null
       and coalesce(is_active, true);
    if v_filial_id is null then
      raise exception 'Filial topilmadi: %', p_filial using errcode = '22023';
    end if;
    select coalesce(array_agg(m.branch_id), '{}'::int[]) into v_bids
      from staff_branch_map m
     where m.filial_id = v_filial_id or m.provodka_filial = v_filial_nom;
  end if;

  return (
    with staff_in as (
      select s.staff_id,
             coalesce(nullif(btrim(s.toliq_nom), ''),
                      btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))) as nom,
             s.lavozim, s.user_id, s.branch_id, s.branch_nomi
        from aros_staff s
       where s.is_active
         -- 🔴 2026-10-04 (OVERRIDE): a'zolik YAGONA manbadan — hodim_filial_azo() (override > Aros+qolda)
         and (v_filial_id is null or hodim_filial_azo(s.staff_id, v_filial_id))
    ),
    staff_admin as (
      select si.staff_id
        from staff_in si
        join profiles p on p.id = si.user_id
       where si.user_id is not null and p.role = 'admin'
    ),
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
    staff_eff as (
      select staff_id from staff_role
      union
      select staff_id from staff_admin
    ),
    -- 🔴 YANGI (MASALA #6): filial_nom endi staff_filial_qolda dan ham
    -- fallback qiladi (branch mapping'i bo'lmagan hodim uchun).
    -- 🔴 2026-10-04 (OVERRIDE): filial_nom endi hodim_filial_nomlar() dan (override bo'lsa o'sha,
    --    aks holda Aros+qolda); hech biri yo'q bo'lsa Aros bo'lim nomi (eski fallback).
    staff_filial as (
      select si.staff_id, coalesce(nullif(hodim_filial_nomlar(si.staff_id), ''), si.branch_nomi) as filial_nom
        from staff_in si
    ),
    hodim_meta as (
      select si.staff_id, si.nom, si.lavozim,
             case when exists (select 1 from staff_admin sa where sa.staff_id = si.staff_id)
                  then '["Admin"]'::jsonb
                  else coalesce((select jsonb_agg(distinct sr.role_nom order by sr.role_nom)
                                   from staff_role sr where sr.staff_id = si.staff_id), '[]'::jsonb)
             end as rollar
        from staff_in si
       -- 🔴 2026-09-25 (Asilbek: «Gulnoza chiqmayapti»): ROLSIZ hodim ham ro'yxatda — rollar [] ,
       --    qatorlari bo'sh; UI «rol yo'q» belgisini ko'rsatadi. Avval faqat rolli/admin chiqardi.
    ),
    -- 🔴 YANGI (MASALA #4, PROVODKA_STANDART_LIMIT_V2.sql): rbac_staff_limit
    -- override'ining valyuta-aware (jonli so'm ekvivalenti) versiyasi, bir marta
    -- hisoblanadi — modda_eff/ov_eff/ov_umumiy shundan o'qiydi.
    staff_limit_eff as (
      select staff_id, kalit, limit_val, coalesce(valyuta, 'UZS') as valyuta,
             case when limit_uzs is null and limit_val is null then null
                  when coalesce(valyuta, 'UZS') = 'UZS' then coalesce(limit_uzs, limit_val)
                  else standart_limit_uzs(limit_val, valyuta) end as eff_uzs
        from rbac_staff_limit
    ),
    -- MODDA (xarajat, ovqat_modda EMAS) yig'ma manbasi: rol orqali + admin shox (hamma, cheksiz).
    modda_z as (
      select sr.staff_id, am.id as modda_id, am.code, am.name, rm.limit_uzs
        from staff_role sr
        join rbac_role_modda rm on rm.role_id = sr.role_id
        join accounts am on am.id = rm.account_id and am.type = 'xarajat'
                        and coalesce(am.is_active, true) and not coalesce(am.ovqat_modda, false)
      union all
      select sa.staff_id, a.id, a.code, a.name, null::numeric
        from staff_admin sa
        cross join accounts a
       where a.type = 'xarajat' and coalesce(a.is_active, true) and not coalesce(a.ovqat_modda, false)
    ),
    modda_rol as (
      select z.staff_id, z.modda_id, min(z.code) as code, min(z.name) as name,
             bool_or(z.limit_uzs is null) as rol_cheksiz,
             max(z.limit_uzs)             as rol_lim
        from modda_z z
       group by z.staff_id, z.modda_id
    ),
    modda_eff as (
      select mr.staff_id, mr.modda_id, mr.code, mr.name, mr.rol_cheksiz, mr.rol_lim,
             sle.limit_val               as override_val,
             coalesce(sle.valyuta,'UZS') as override_cur,
             sle.eff_uzs                 as override_lim,
             (sle.staff_id is not null)  as has_override,
             case when sle.staff_id is not null then sle.eff_uzs
                  when mr.rol_cheksiz then null else mr.rol_lim end as eff_lim
        from modda_rol mr
        left join staff_limit_eff sle
          on sle.staff_id = mr.staff_id and sle.kalit = 'modda:' || mr.modda_id::text
    ),
    modda_qator as (
      select me.staff_id, me.code,
             jsonb_build_object(
               'kalit',               'modda:' || me.modda_id::text,
               'turi',                'modda',
               'account_id',          me.modda_id,
               'code',                me.code,
               'name',                me.name,
               'tur',                 null,
               'rol_limit',           case when me.rol_cheksiz then null else me.rol_lim end,
               'hodim_limit',         me.override_lim,
               'hodim_limit_val',     me.override_val,
               'hodim_limit_valyuta', me.override_cur,
               'effektiv_limit',      me.eff_lim,
               'sarf',                coalesce(msf.sarf, 0),
               'qoldi',               case when me.eff_lim is null then null else me.eff_lim - coalesce(msf.sarf, 0) end,
               'override',            me.has_override
             ) as qator
        from modda_eff me
        left join staff_in si on si.staff_id = me.staff_id
        left join lateral (
          select case when si.user_id is not null
                      then rbac_modda_ishlatildi(si.user_id, me.modda_id, v_oy)
                      else 0 end as sarf
        ) msf on true
    ),
    -- OVQAT: 3 tur (rol orqali ruxsat etilgan yoki admin shox — hamma tur, cheksiz).
    ov_modda as (
      select id, code, name from accounts
       where coalesce(ovqat_modda, false) and type = 'xarajat' and coalesce(is_active, true)
    ),
    ov_z as (
      select sr.staff_id, ro.tur, ro.limit_uzs
        from staff_role sr
        join rbac_role_ovqat ro on ro.role_id = sr.role_id
      union all
      select sa.staff_id, t.tur, null::numeric
        from staff_admin sa
        cross join unnest(array['obed', 'zavtrak', 'kechki']) as t(tur)
    ),
    ov_rol as (
      select z.staff_id, z.tur,
             bool_or(z.limit_uzs is null) as rol_cheksiz,
             max(z.limit_uzs)             as rol_lim
        from ov_z z
       group by z.staff_id, z.tur
    ),
    ov_umumiy as (
      select staff_id, limit_val, valyuta, eff_uzs as limit_uzs
        from staff_limit_eff where kalit = 'ovqat:umumiy'
    ),
    ov_eff as (
      select orr.staff_id, orr.tur, orr.rol_cheksiz, orr.rol_lim,
             sle.limit_val               as override_val,
             coalesce(sle.valyuta,'UZS') as override_cur,
             sle.eff_uzs                 as override_lim,
             (sle.staff_id is not null)  as has_override,
             (u.staff_id is not null)    as umumiy_on,
             case when u.staff_id is not null then null
                  when sle.staff_id is not null then sle.eff_uzs
                  when orr.rol_cheksiz then null else orr.rol_lim end as eff_lim,
             rbac_ovqat_ishlatildi(orr.staff_id, orr.tur, v_oy) as sarf
        from ov_rol orr
        left join staff_limit_eff sle on sle.staff_id = orr.staff_id and sle.kalit = 'ovqat:' || orr.tur
        left join ov_umumiy u on u.staff_id = orr.staff_id
    ),
    ov_qator as (
      select oe.staff_id, oe.tur,
             jsonb_build_object(
               'kalit',               'ovqat:' || oe.tur,
               'turi',                'ovqat',
               'account_id',          ov.id,
               'code',                ov.code,
               'name',                ov.name,
               'tur',                 oe.tur,
               'rol_limit',           case when oe.rol_cheksiz then null else oe.rol_lim end,
               'hodim_limit',         oe.override_lim,
               'hodim_limit_val',     oe.override_val,
               'hodim_limit_valyuta', oe.override_cur,
               'effektiv_limit',      oe.eff_lim,
               'sarf',                oe.sarf,
               'qoldi',               case when oe.eff_lim is null then null else oe.eff_lim - oe.sarf end,
               'override',            oe.has_override,
               'umumiy_rejim',        oe.umumiy_on
             ) as qator
        from ov_eff oe
        cross join ov_modda ov
    ),
    modda_agg as (
      select staff_id, jsonb_agg(qator order by code) as arr
        from modda_qator
       group by staff_id
    ),
    ov_agg as (
      select staff_id,
             jsonb_agg(qator order by case tur when 'obed' then 1 when 'zavtrak' then 2 when 'kechki' then 3 else 4 end) as arr
        from ov_qator
       group by staff_id
    ),
    umumiy_agg as (
      select hm.staff_id,
             jsonb_build_object(
               'bor',       (u.staff_id is not null),
               'limit',     u.limit_uzs,
               'limit_val', u.limit_val,
               'valyuta',   coalesce(u.valyuta, 'UZS'),
               'sarf',      coalesce(s.sarf, 0),
               'qoldi',     case when u.staff_id is null or u.limit_uzs is null then null
                                 else u.limit_uzs - coalesce(s.sarf, 0) end
             ) as obj
        from hodim_meta hm
        left join ov_umumiy u on u.staff_id = hm.staff_id
        left join lateral (
          select coalesce(sum(rbac_ovqat_ishlatildi(hm.staff_id, t.tur, v_oy)), 0) as sarf
            from unnest(array['obed', 'zavtrak', 'kechki']) as t(tur)
        ) s on true
    )
    select jsonb_build_object(
      'ok', true,
      'oy', to_char(v_oy, 'YYYY-MM'),
      'hodimlar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'staff_id',     hm.staff_id,
                 'toliq_nom',    hm.nom,
                 'lavozim',      hm.lavozim,
                 'filial_nom',   sf.filial_nom,
                 'rollar',       hm.rollar,
                 'qatorlar',     coalesce(ma.arr, '[]'::jsonb) || coalesce(oa.arr, '[]'::jsonb),
                 'ovqat_umumiy', ua.obj
               ) order by hm.nom)
          from hodim_meta hm
          join staff_filial sf on sf.staff_id = hm.staff_id
          left join modda_agg  ma on ma.staff_id = hm.staff_id
          left join ov_agg     oa on oa.staff_id = hm.staff_id
          left join umumiy_agg ua on ua.staff_id = hm.staff_id
      ), '[]'::jsonb)
    )
  );
end
$fn$;

revoke all on function standart_hodim_limitlar(uuid, date) from public, anon;
grant execute on function standart_hodim_limitlar(uuid, date) to authenticated;

-- ######## 6) ADMIN RPC — sozlama-dev «Hodim → Filial» ########
create or replace function hodim_filial_royxat()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not hodim_filial_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  return jsonb_build_object(
    'ok', true,
    'filiallar', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.name)
        from accounts a
       where a.kassa_turi = 'filial' and a.parent_id is null and coalesce(a.is_active, true)
    ), '[]'::jsonb),
    'hodimlar', coalesce((
      select jsonb_agg(jsonb_build_object(
               'staff_id',    s.staff_id,
               'nom',         coalesce(nullif(btrim(s.toliq_nom), ''), btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))),
               'lavozim',     s.lavozim,
               'is_active',   s.is_active,
               'user_id',     s.user_id,
               'branch_nomi', s.branch_nomi,
               'aros',        (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.name), '[]'::jsonb)
                                 from accounts a where a.id = any(hodim_filial_aros(s.staff_id))),
               'override',    (select jsonb_build_object('filial_ids', to_jsonb(o.filial_ids), 'izoh', o.izoh, 'updated_at', o.updated_at)
                                 from hodim_filial_override o where o.staff_id = s.staff_id),
               'joriy',       (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.name), '[]'::jsonb)
                                 from accounts a where a.id = any(hodim_filiallari(s.staff_id)))
             ) order by s.is_active desc, coalesce(nullif(btrim(s.toliq_nom), ''), s.ism))
        from aros_staff s
       where s.is_active
    ), '[]'::jsonb)
  );
end
$fn$;
revoke all on function hodim_filial_royxat() from public, anon;
grant execute on function hodim_filial_royxat() to authenticated;

create or replace function hodim_filial_set(p_staff int, p_filial_ids uuid[], p_izoh text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_ids uuid[];
  v_bad int;
begin
  if not hodim_filial_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Ruxsat yoq');
  end if;
  if p_staff is null or not exists (select 1 from aros_staff where staff_id = p_staff) then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi', 'error', 'Hodim topilmadi');
  end if;
  -- dublikatsiz, null'siz; har id FAOL filial (parent) bo'lsin
  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_ids
    from unnest(coalesce(p_filial_ids, '{}'::uuid[])) x where x is not null;
  select count(*) into v_bad
    from unnest(v_ids) x
   where not exists (select 1 from accounts a where a.id = x and a.kassa_turi = 'filial'
                        and a.parent_id is null and coalesce(a.is_active, true));
  if v_bad > 0 then
    return jsonb_build_object('ok', false, 'kod', 'filial_notogri', 'error', 'Filial topilmadi yoki nofaol');
  end if;
  insert into hodim_filial_override(staff_id, filial_ids, izoh, updated_at, updated_by)
  values (p_staff, v_ids, nullif(btrim(coalesce(p_izoh, '')), ''), now(), auth.uid())
  on conflict (staff_id) do update
     set filial_ids = excluded.filial_ids, izoh = excluded.izoh, updated_at = now(), updated_by = auth.uid();
  return jsonb_build_object('ok', true, 'staff_id', p_staff, 'filial_ids', to_jsonb(v_ids));
end
$fn$;
revoke all on function hodim_filial_set(int, uuid[], text) from public, anon;
grant execute on function hodim_filial_set(int, uuid[], text) to authenticated;

create or replace function hodim_filial_clear(p_staff int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not hodim_filial_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Ruxsat yoq');
  end if;
  delete from hodim_filial_override where staff_id = p_staff;
  return jsonb_build_object('ok', true, 'staff_id', p_staff);
end
$fn$;
revoke all on function hodim_filial_clear(int) from public, anon;
grant execute on function hodim_filial_clear(int) to authenticated;

-- ######## 7) hodim-dev ovqat ro'yxati — kassa subtitle'idagi filial NOMI bo'yicha a'zo hodimlar ########
--    p_filial_nom = hodim xarajat kassasi subtitle'ining 1-qismi (= staff_branch_map.provodka_filial, Aros bo'lim nomi).
--    Filial id'lari: shu nomli bo'limlar bog'langan filial_id'lar + nomi aynan shunday filial kassasi.
create or replace function ovqat_mening_staff(p_filial_nom text)
returns int[]
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_nom  text := nullif(btrim(coalesce(p_filial_nom, '')), '');
  v_fids uuid[];
  v_bids int[];
begin
  if auth.uid() is null or v_nom is null then return '{}'::int[]; end if;
  select coalesce(array_agg(distinct m.branch_id), '{}'::int[]) into v_bids
    from staff_branch_map m where m.provodka_filial = v_nom;
  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_fids
    from (
      select m.filial_id as x from staff_branch_map m where m.provodka_filial = v_nom and m.filial_id is not null
      union
      select a.id from accounts a where a.kassa_turi = 'filial' and a.parent_id is null and a.name = v_nom
    ) t;
  return coalesce((
    select array_agg(s.staff_id)
      from aros_staff s
     where s.is_active
       and (
         -- override bor → faqat uning ro'yxati bo'yicha
         exists (select 1 from hodim_filial_override o where o.staff_id = s.staff_id and o.filial_ids && v_fids)
         or (
           not exists (select 1 from hodim_filial_override o where o.staff_id = s.staff_id)
           and (
             s.branch_id = any(v_bids)
             or exists (select 1 from jsonb_array_elements(coalesce(s.branches, '[]'::jsonb)) b
                         where (b ->> 'id') ~ '^\d+$' and (b ->> 'id')::int = any(v_bids))
             or exists (select 1 from staff_filial_qolda q where q.staff_id = s.staff_id and q.filial_id = any(v_fids))
           )
         )
       )
  ), '{}'::int[]);
end
$fn$;
revoke all on function ovqat_mening_staff(text) from public, anon;
grant execute on function ovqat_mening_staff(text) to authenticated;

notify pgrst, 'reload schema';

-- ######## 8) TEKSHIRUV ########
select (select count(*) from aros_staff where is_active) as faol_hodim,
       (select count(*) from hodim_filial_override) as override_soni,
       (select count(*) from aros_staff s where s.is_active and cardinality(hodim_filiallari(s.staff_id)) = 0) as filialsiz_hodim;
