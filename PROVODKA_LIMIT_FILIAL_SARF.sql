-- ============================================================================
--  PROVODKA_LIMIT_FILIAL_SARF.sql — 2026-09-28 — FILIAL limiti sarfi FAQAT o'z limiti YO'Q hodimlardan
--  Asilbek: «oldin Gulnoza Malika uchun yozgan bo'lsa u Malika limitidan kamaygan — noto'g'ri. Faqat
--  Malikadagi hodimlarnikini hisoblash kerak, oldingilarni ham to'g'rilab qo'yish kerak».
--  Yechim — MA'LUMOT O'ZGARMAYDI, FORMULA o'zgaradi: filial+modda limitining «sarflandi»si endi faqat
--  yozuvchisi (entry.created_by) shu moddaga O'Z limitiga (rol/override) ega BO'LMAGAN yozuvlardan yig'iladi.
--  O'z limiti bor hodim (Gulnoza) yozgan HAMMA yozuv — o'tmishdagilar ham — filial hisobidan chiqadi
--  (u hodimning o'z limitidan yechiladi, rbac_limit_entry_line). created_by bo'sh/yaroqsiz → filialga sanaladi.
--  To'rt joy bir xil qoidaga o'tdi: standart_holat (hodim/professional ogohlantirishi, standart sahifasi),
--  standart_filial_moddalar, standart_filial_limit_sarf (standart sahifasi), limit_guard_entry_line (server).
--  Tanalar PROVODKA_STANDART_LIMIT_V2.sql / PROVODKA_LIMIT_HODIM_USTUN.sql dan VERBATIM + bittadan shart.
--  Old shart: PROVODKA_LIMIT_HODIM_USTUN.sql RUN bo'lgan (rbac_hodim_limit_bor). Asilbek RUN qiladi.
-- ============================================================================

-- 1) yordamchi: bu yozuv FILIAL limitiga sanaladimi
create or replace function filial_sarf_hisobga(p_created_by text, p_account uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_raw text := nullif(btrim(coalesce(p_created_by, '')), '');
begin
  if v_raw is null or v_raw !~ '^[0-9a-fA-F-]{36}$' then return true; end if;   -- yozuvchi noma'lum → filialga
  return not rbac_hodim_limit_bor(v_raw::uuid, p_account);
end
$fn$;
revoke all on function filial_sarf_hisobga(text, uuid) from public, anon;
grant execute on function filial_sarf_hisobga(text, uuid) to authenticated;

-- 2) standart_holat — filial limiti holati (hodim/professional/standart)
create or replace function standart_holat(p_oy date)
returns table(
  id uuid, filial_id uuid, filial_code text, filial_name text,
  modda_id uuid, modda_code text, modda_name text,
  limit_uzs numeric, sarflandi numeric, qoldi numeric
)
language sql
stable
security definer
set search_path = public
as $fn$
  with oy as (
    select date_trunc('month', p_oy)::date as f,
           (date_trunc('month', p_oy) + interval '1 month - 1 day')::date as t
  ),
  lim as (
    select s.id, s.filial_id, s.modda_id,
           case when coalesce(s.valyuta, 'UZS') = 'UZS' then coalesce(s.limit_uzs, s.limit_val)
                else standart_limit_uzs(s.limit_val, s.valyuta) end as limit_uzs
      from standart_xarajat s
  )
  select l.id, l.filial_id, fa.code, fa.name,
         l.modda_id, ma.code, ma.name,
         l.limit_uzs,
         coalesce(sp.sarflandi, 0)                 as sarflandi,
         l.limit_uzs - coalesce(sp.sarflandi, 0)   as qoldi
    from lim l
    join accounts fa on fa.id = l.filial_id
    join accounts ma on ma.id = l.modda_id
    cross join oy
    left join lateral (
      select sum(el.debit) as sarflandi
        from entry e
        join entry_line el on el.entry_id = e.id and el.account_id = l.modda_id and el.debit > 0
       where e.status = 'posted' and e.is_deleted = false
         and e.entry_date >= oy.f and e.entry_date <= oy.t
         and l.filial_id = any(e.filial_ids)
                  and filial_sarf_hisobga(to_jsonb(e) ->> 'created_by', l.modda_id)   -- 🔴 2026-09-28
    ) sp on true
   order by fa.name, ma.name;
$fn$;

revoke all on function standart_holat(date) from public, anon;
grant execute on function standart_holat(date) to authenticated;

-- 3) standart_filial_moddalar — standart sahifasi «Hodimlarga ochiq moddalar»
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
           -- 🔴 YANGI (MASALA #6, PROVODKA_STANDART_LIMIT_V2.sql): qo'lda biriktirilgan
           --    (Aros filiali yo'q) hodim ham shu filialga tegishli hisoblanadi.
           or exists (
             select 1 from staff_filial_qolda q
              where q.staff_id = s.staff_id and q.filial_id = v_filial_id
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
                          and filial_sarf_hisobga(to_jsonb(e) ->> 'created_by', h.modda_id)), 0) as sarf_uzs   -- 🔴 2026-09-28
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

-- 4) standart_filial_limit_sarf — standart sahifasi hodim limitlari (sarf_filial)
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
           -- 🔴 YANGI (MASALA #6, PROVODKA_STANDART_LIMIT_V2.sql).
           or exists (
             select 1 from staff_filial_qolda q
              where q.staff_id = s.staff_id and q.filial_id = v_filial_id
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
                  and filial_sarf_hisobga(to_jsonb(e) ->> 'created_by', h.modda_id)   -- 🔴 2026-09-28
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

-- 5) limit_guard_entry_line — server qorovuli (v_spent ham shu qoida bilan)
create or replace function limit_guard_entry_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_fids      uuid[];
  v_date      date;
  v_deleted   boolean;
  v_status    text;
  v_raw       text;
  v_ega       uuid;
  f           uuid;
  v_limit     numeric;
  v_limit_val numeric;
  v_limit_cur text;
  v_spent     numeric;
  v_f         date;
  v_t         date;
  v_fname     text;
  v_mname     text;
begin
  if new.debit is null or new.debit <= 0 then return new; end if;
  if auth.uid() is null then return new; end if;   -- avtomat sinxron (n8n) o'tadi

  select filial_ids, entry_date, is_deleted, status, (to_jsonb(entry) ->> 'created_by')
    into v_fids, v_date, v_deleted, v_status, v_raw
    from entry where id = new.entry_id;
  if not found then return new; end if;
  if v_deleted or coalesce(v_status, 'posted') <> 'posted' then return new; end if;
  if v_fids is null or array_length(v_fids, 1) is null then return new; end if;

  -- 🔴 2026-09-27: yozuvchining O'Z limiti bo'lsa filial limiti qo'llanmaydi (rbac_limit_entry_line tekshiradi)
  v_raw := nullif(btrim(coalesce(v_raw, '')), '');
  v_ega := case when v_raw ~ '^[0-9a-fA-F-]{36}$' then v_raw::uuid else auth.uid() end;
  if rbac_hodim_limit_bor(v_ega, new.account_id) then return new; end if;

  v_f := date_trunc('month', v_date)::date;
  v_t := (date_trunc('month', v_date) + interval '1 month - 1 day')::date;

  foreach f in array v_fids loop
    v_limit := null; v_limit_val := null; v_limit_cur := null;
    select limit_uzs, limit_val, valyuta into v_limit, v_limit_val, v_limit_cur
      from standart_xarajat where filial_id = f and modda_id = new.account_id;
    if found then
      if coalesce(v_limit_cur, 'UZS') <> 'UZS' then
        v_limit := standart_limit_uzs(v_limit_val, v_limit_cur);
      else
        v_limit := coalesce(v_limit, v_limit_val);
      end if;
    end if;
    if v_limit is not null then
      select coalesce(sum(el.debit), 0) into v_spent
        from entry e
        join entry_line el on el.entry_id = e.id and el.account_id = new.account_id and el.debit > 0
       where e.status = 'posted' and e.is_deleted = false
         and e.entry_date >= v_f and e.entry_date <= v_t
         and f = any(e.filial_ids)
         and filial_sarf_hisobga(to_jsonb(e) ->> 'created_by', new.account_id);   -- 🔴 2026-09-28
      if v_spent > v_limit then
        select name into v_fname from accounts where id = f;
        select name into v_mname from accounts where id = new.account_id;
        raise exception 'Limit oshib ketdi: "%" filialida "%" uchun oylik limit % so''m, bu oy jami % so''m bo''ladi',
          coalesce(v_fname, '?'), coalesce(v_mname, '?'), v_limit, v_spent
          using errcode = 'P0001';
      end if;
    end if;
  end loop;
  return new;
end
$fn$;

revoke all on function limit_guard_entry_line() from public, anon;

notify pgrst, 'reload schema';

-- tekshiruv: joriy oyda filial limitlari — sarflandi endi o'z limiti bor hodimlarsiz
select filial_name, modda_name, limit_uzs, sarflandi, qoldi
  from standart_holat(current_date) order by filial_name, modda_name;
