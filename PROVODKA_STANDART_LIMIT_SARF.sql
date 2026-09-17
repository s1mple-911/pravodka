-- ============================================================================
--  PROVODKA_STANDART_LIMIT_SARF.sql — 2026-09-17 (Asilbek)
--
--  Ovqatlanish / oxrana kabi moddalarda limit FILIALGA emas, ROL orqali HAR
--  HODIMGA berilgan (masalan Qarshi main store hodimlarida «1talikovqat» roli,
--  obed uchun 120 000 — ya'ni shu hodim bir oyda faqat 120 000 ishlata oladi).
--  Bu funksiya filial kesimida shuni ko'rsatadi: har hodimning limiti, sarfi,
--  qoldig'i va O'Z kassasidagi pul (filial kassasi EMAS).
--
--  Faqat O'QISH. Ustun/trigger/RLS/mavjud funksiya o'zgarmaydi (additive).
--
--  Manbalar: rbac_role_modda.limit_uzs (rol × modda oylik limit, null = cheksiz),
--  🔴 OVQAT moddasi uchun rbac_role_ovqat.limit_uzs (rol × obed/zavtrak/kechki) +
--  entry_ovqat (yeyuvchi hodim bo'yicha) — rbac_limit_ovqat_staff /
--  rbac_ovqat_ishlatildi bilan bir xil mantiq; standart_filial_moddalar()
--  (filial ↔ hodim ↔ modda — staff CTE'lari AYNAN o'sha yerdan ko'chirildi),
--  v_kassa_card (hodim xarajat kassasi qoldig'i).
--
--  Qoidalar: hodimda bir necha rol bo'lsa eng KATTA limit; bittasi cheksiz
--  bo'lsa cheksiz. Provodkaga kirmaydigan hodim ham hisobda (rbac_staff_role).
--  Sarf: filial bo'yicha (entry.filial_ids) — bitta hodim hamkasblari uchun
--  birga yozadi; hodim satridagi sarf esa o'zi yozgani (entry.created_by).
-- ============================================================================

create or replace function standart_filial_limit_sarf(p_filial uuid,
                                                      p_oy date default null)
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
         and (
           s.branch_id = any(v_bids)
           or exists (
             select 1 from jsonb_array_elements(coalesce(s.branches, '[]'::jsonb)) b
              where (b ->> 'id') ~ '^\d+$' and (b ->> 'id')::int = any(v_bids)
           )
         )
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

comment on function standart_filial_limit_sarf(uuid, date) is
  'Filial hodimlariga ROL orqali berilgan xarajat limitlari: har hodimning oylik '
  'limiti (rollari ichidan eng kattasi), sarfi, qoldigi va O''Z xarajat kassasidagi '
  'pul (filial kassasi emas). Modda jami sarfi filial boyicha (entry.filial_ids). '
  'Faqat oqish.';

-- ---------------------------------------------------------------------------
-- TEKSHIRUV (RUN natijasida ko'rinadi)
-- ---------------------------------------------------------------------------
select 'standart_filial_limit_sarf' as funksiya,
       case when to_regprocedure('public.standart_filial_limit_sarf(uuid,date)') is not null
            then '✅ yaratildi' else '❌ yaratilmadi' end as holat;
