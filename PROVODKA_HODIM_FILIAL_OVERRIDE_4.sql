-- ============================================================================
--  PROVODKA_HODIM_FILIAL_OVERRIDE_4.sql — 2026-10-04 — Hodimni BUTUNLAY O'CHIRISH (override) + login hisobini bog'lash (UI)
--  Asilbek: «har doim SQL bilan bog'laymizmi? override'da hodimni butunlay o'chirib tashlash imkoni kerak — barcha joydan
--  uchadi, faqat tarix eslanib qoladi».
--   * hodim_filial_override.ochirilgan — TRUE bo'lsa hodim HECH QAYSI filialga a'zo emas (hodim_filial_azo=false,
--     hodim_filiallari='{}') va ro'yxatlarda ko'rinmaydi: standart_hodim_limitlar, rbac_staff_royxat, ovqat_mening_staff
--     (nom yo'li), hodim-dev/qarzdor-dev klient ro'yxatlari (hodim_ochirilganlar()). aros_staff qatori, entry/entry_ovqat
--     yozuvlari, ehson/qarz tarixi TEGILMAYDI. Staff Sync override jadvaliga tegmaydi → qayta tirilmaydi.
--   * hodim_filial_login_bogla(staff, user) — aros_staff.user_id ni «Hodim → Filial» kartasidan bog'lash (ruxsat
--     hodim_filial_page_ok, rbac_staff_link_set admin-only edi); hodim_filial_royxat() loginlar ro'yxati + login_ism beradi.
--  Additive, idempotent. Old shart: PROVODKA_HODIM_FILIAL_OVERRIDE.sql (+_2, _3). Asilbek RUN qiladi.
-- ============================================================================
alter table hodim_filial_override add column if not exists ochirilgan boolean not null default false;
alter table hodim_filial_override add column if not exists ochirilgan_at timestamptz;
alter table hodim_filial_override add column if not exists ochirilgan_izoh text;
alter table hodim_filial_override add column if not exists ochirilgan_by uuid;

create or replace function hodim_ochirilgan(p_staff int)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce((select o.ochirilgan from hodim_filial_override o where o.staff_id = p_staff), false);
$fn$;
revoke all on function hodim_ochirilgan(int) from public, anon;
grant execute on function hodim_ochirilgan(int) to authenticated;

create or replace function hodim_ochirilganlar()
returns int[]
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce((select array_agg(staff_id) from hodim_filial_override where ochirilgan), '{}'::int[])
   where auth.uid() is not null;
$fn$;
revoke all on function hodim_ochirilganlar() from public, anon;
grant execute on function hodim_ochirilganlar() to authenticated;

-- hodim_filiallari / hodim_filial_azo — o'chirilgan hodim hech qayerga a'zo emas
create or replace function hodim_filiallari(p_staff int)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $fn$
  select case when hodim_ochirilgan(p_staff) then '{}'::uuid[]
              else coalesce((select o.filial_ids from hodim_filial_override o where o.staff_id = p_staff),
                            hodim_filial_aros(p_staff)) end;
$fn$;

create or replace function hodim_filial_azo(p_staff int, p_filial uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_ov   uuid[];
  v_och  boolean;
  v_nom  text;
begin
  if p_staff is null or p_filial is null then return false; end if;
  select filial_ids, ochirilgan into v_ov, v_och from hodim_filial_override where staff_id = p_staff;
  if found then
    if v_och then return false; end if;                 -- 🔴 o'chirilgan hodim
    return p_filial = any(v_ov);
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

-- ######## O'CHIRISH / TIKLASH ########
create or replace function hodim_filial_ochir(p_staff int, p_ochir boolean, p_izoh text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not hodim_filial_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Ruxsat yoq'); end if;
  if p_staff is null or not exists (select 1 from aros_staff where staff_id = p_staff) then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi', 'error', 'Hodim topilmadi');
  end if;
  insert into hodim_filial_override(staff_id, filial_ids, ochirilgan, ochirilgan_at, ochirilgan_izoh, ochirilgan_by, updated_at, updated_by)
  values (p_staff, '{}'::uuid[], coalesce(p_ochir, true),
          case when coalesce(p_ochir, true) then now() end, nullif(btrim(coalesce(p_izoh, '')), ''),
          case when coalesce(p_ochir, true) then auth.uid() end, now(), auth.uid())
  on conflict (staff_id) do update
     set ochirilgan      = excluded.ochirilgan,
         ochirilgan_at   = case when excluded.ochirilgan then now() else null end,
         ochirilgan_izoh = case when excluded.ochirilgan then excluded.ochirilgan_izoh else null end,
         ochirilgan_by   = case when excluded.ochirilgan then auth.uid() else null end,
         updated_at = now(), updated_by = auth.uid();
  -- TIKLASH: filial_ids bo'sh va aros'da filiali bo'lsa override qatorini olib tashlaymiz (Aros holatiga qaytadi)
  if not coalesce(p_ochir, true) then
    delete from hodim_filial_override
     where staff_id = p_staff and cardinality(filial_ids) = 0 and cardinality(hodim_filial_aros(p_staff)) > 0;
  end if;
  return jsonb_build_object('ok', true, 'staff_id', p_staff, 'ochirilgan', coalesce(p_ochir, true));
end
$fn$;
revoke all on function hodim_filial_ochir(int, boolean, text) from public, anon;
grant execute on function hodim_filial_ochir(int, boolean, text) to authenticated;

-- ######## LOGIN BOG'LASH (aros_staff.user_id) ########
create or replace function hodim_filial_login_bogla(p_staff int, p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not hodim_filial_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Ruxsat yoq'); end if;
  if p_staff is null or not exists (select 1 from aros_staff where staff_id = p_staff) then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi', 'error', 'Hodim topilmadi');
  end if;
  if p_user is null then
    update aros_staff set user_id = null where staff_id = p_staff;
    return jsonb_build_object('ok', true, 'staff_id', p_staff, 'user_id', null);
  end if;
  if not exists (select 1 from profiles where id = p_user) then
    return jsonb_build_object('ok', false, 'kod', 'login_topilmadi', 'error', 'Login hisobi topilmadi');
  end if;
  update aros_staff set user_id = null where user_id = p_user and staff_id <> p_staff;   -- boshqa hodimdan ko'chadi
  update aros_staff set user_id = p_user where staff_id = p_staff;
  return jsonb_build_object('ok', true, 'staff_id', p_staff, 'user_id', p_user);
end
$fn$;
revoke all on function hodim_filial_login_bogla(int, uuid) from public, anon;
grant execute on function hodim_filial_login_bogla(int, uuid) to authenticated;

-- ######## RO'YXAT — ochirilgan + login + loginlar ########
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
    'loginlar', coalesce((
      select jsonb_agg(jsonb_build_object('id', pr.id, 'nom', coalesce(nullif(btrim(to_jsonb(pr) ->> 'full_name'), ''), pr.id::text))
                       order by coalesce(nullif(btrim(to_jsonb(pr) ->> 'full_name'), ''), pr.id::text))
        from profiles pr
    ), '[]'::jsonb),
    'hodimlar', coalesce((
      select jsonb_agg(jsonb_build_object(
               'staff_id',    s.staff_id,
               'nom',         coalesce(nullif(btrim(s.toliq_nom), ''), btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))),
               'lavozim',     s.lavozim,
               'is_active',   s.is_active,
               'user_id',     s.user_id,
               'login_id',    s.user_id,
               'login_ism',   (select nullif(btrim(to_jsonb(pr) ->> 'full_name'), '') from profiles pr where pr.id = s.user_id),
               'branch_nomi', s.branch_nomi,
               'aros',        (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.name), '[]'::jsonb)
                                 from accounts a where a.id = any(hodim_filial_aros(s.staff_id))),
               'override',    (select case when o.ochirilgan then null
                                           else jsonb_build_object('filial_ids', to_jsonb(o.filial_ids), 'izoh', o.izoh, 'updated_at', o.updated_at) end
                                 from hodim_filial_override o where o.staff_id = s.staff_id),
               'ochirilgan',  hodim_ochirilgan(s.staff_id),
               'ochirilgan_at',   (select o.ochirilgan_at from hodim_filial_override o where o.staff_id = s.staff_id),
               'ochirilgan_izoh', (select o.ochirilgan_izoh from hodim_filial_override o where o.staff_id = s.staff_id),
               'joriy',       (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.name), '[]'::jsonb)
                                 from accounts a where a.id = any(hodim_filiallari(s.staff_id)))
             ) order by hodim_ochirilgan(s.staff_id), s.is_active desc, coalesce(nullif(btrim(s.toliq_nom), ''), s.ism))
        from aros_staff s
       where s.is_active
    ), '[]'::jsonb)
  );
end
$fn$;

-- ######## RO'YXATLARDAN CHIQARISH — tanalar VERBATIM, faqat `where s.is_active` filtri ########
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
         and not hodim_ochirilgan(s.staff_id)   -- 🔴 2026-10-04: o'chirilgan hodim ro'yxatda YO'Q
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
                               -- YAGONA moslik bo'lsagina taklif (2+ bir xil ism → null, admin o'zi tanlaydi)
                               -- uuid uchun min() yo'q — array_agg birinchi elementi
                               select case when count(*) = 1 then (array_agg(pr.id))[1] end
                                 from profiles pr
                                where nom_norm(to_jsonb(pr) ->> 'full_name') = nom_norm(
                                        coalesce(nullif(btrim(s.toliq_nom), ''),
                                                 btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))))
                                  and nom_norm(to_jsonb(pr) ->> 'full_name') is not null
                                  and not exists (select 1 from aros_staff s2 where s2.user_id = pr.id)
                             ) end
        ) order by coalesce(nullif(btrim(s.toliq_nom), ''), s.staff_id::text))
      from aros_staff s
     where s.is_active
       and not hodim_ochirilgan(s.staff_id)), '[]'::jsonb),   -- 🔴 2026-10-04: o'chirilgan hodim rollar ro'yxatida YO'Q
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

create or replace function ovqat_mening_staff(p_filial_nom text)
returns int[]
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_nom   text := nullif(btrim(coalesce(p_filial_nom, '')), '');
  v_staff int;
  v_my    uuid[];
  v_fids  uuid[];
  v_bids  int[];
begin
  if auth.uid() is null then return '{}'::int[]; end if;

  -- 1) Yozuvchi — hodim: o'z filiallari (override > Aros) bo'yicha
  select staff_id into v_staff from aros_staff where user_id = auth.uid() limit 1;
  if v_staff is not null then
    v_my := hodim_filiallari(v_staff);
    if cardinality(coalesce(v_my, '{}'::uuid[])) > 0 then
      return coalesce((
        select array_agg(s.staff_id)
          from aros_staff s
         where s.is_active
           and exists (select 1 from unnest(v_my) f where hodim_filial_azo(s.staff_id, f))
      ), '{}'::int[]);
    end if;
    -- filialsiz hodim → nom bo'yicha davom etadi
  end if;

  -- 2) Eski yo'l: kassa subtitle'idagi bo'lim nomi bo'yicha
  if v_nom is null then return '{}'::int[]; end if;
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
       and not hodim_ochirilgan(s.staff_id)
       and (
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

notify pgrst, 'reload schema';

select (select count(*) from hodim_filial_override where ochirilgan) as ochirilgan_hodimlar,
       (select count(*) from aros_staff where user_id is not null) as login_boglangan;
