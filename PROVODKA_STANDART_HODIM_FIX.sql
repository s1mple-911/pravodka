-- ============================================================================
--  PROVODKA_STANDART_HODIM_FIX.sql — 2026-09-25
--  1) standart_hodim_limitlar: ROLSIZ hodimlar ham chiqadi (Gulnoza Ergasheva — rbac_staff_role yo'q edi).
--     Tana PROVODKA_STANDART_LIMIT_V2.sql dan VERBATIM, faqat hodim_meta dagi `where … staff_eff` olib tashlandi.
--  2) «Ta'minot Xitoy» ga hodim bog'lash — staff_id bilan QATTIQ (nom moslashuvi ishlamadi):
--     G'iyos Ergashev = 67. «Ural Ruziyev» bazada yo'q; «Uktam Ruziyev» = 39 — Asilbek tasdiqlasa 2-qatorni oching.
--  Asilbek RUN qiladi.
-- ============================================================================

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
         and (
           v_filial_id is null
           or s.branch_id = any(v_bids)
           or exists (
             select 1 from jsonb_array_elements(coalesce(s.branches, '[]'::jsonb)) b
              where (b ->> 'id') ~ '^\d+$' and (b ->> 'id')::int = any(v_bids)
           )
           -- 🔴 YANGI (MASALA #6, PROVODKA_STANDART_LIMIT_V2.sql).
           or (v_filial_id is not null and exists (
             select 1 from staff_filial_qolda q
              where q.staff_id = s.staff_id and q.filial_id = v_filial_id
           ))
         )
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
    staff_filial as (
      select si.staff_id, coalesce(fa.name, fq.name, si.branch_nomi) as filial_nom
        from staff_in si
        left join staff_branch_map m on m.branch_id = si.branch_id
        left join accounts fa on fa.id = m.filial_id
        left join staff_filial_qolda q on q.staff_id = si.staff_id
        left join accounts fq on fq.id = q.filial_id
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

-- ---------------------------------------------------------------- 2) Ta'minot Xitoy hodimlari
insert into staff_filial_qolda (staff_id, filial_id, updated_by)
select s.staff_id, a.id, auth.uid()
  from (values (67)                     -- G'iyos Ergashev
        -- , (39)                       -- Uktam Ruziyev — «Ural» shu bo'lsa izohni oching
       ) as s(staff_id)
  cross join (select id from accounts where lower(name) = lower('Ta''minot Xitoy') and section = 'pul' and parent_id is null limit 1) a
on conflict (staff_id) do update set filial_id = excluded.filial_id, updated_at = now(), updated_by = excluded.updated_by;

select q.staff_id, s.toliq_nom, a.name as filial
  from staff_filial_qolda q join aros_staff s on s.staff_id = q.staff_id join accounts a on a.id = q.filial_id
 order by s.toliq_nom;
