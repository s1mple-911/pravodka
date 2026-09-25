-- ============================================================================
--  PROVODKA_STANDART_HODIM_FIX2.sql — 2026-09-25 — hodim ↔ user bog'lash, Ta'minot Xitoy hodimlari
--  1) Gulnoza Ergasheva (staff 244) ↔ auth user 97827481-… (Rollar sahifasida «saydullo» roli SHU userga
--     berilgan, hodim yozuvi bog'lanmagani uchun hodim tabi rolini/sarfini ko'rmasdi) — rbac_staff_link_set.
--  2) Ta'minot Xitoy: G'iyos Ergashev (67) + O'ral Ro'ziyev (27). Boshqa hech kim (Zulfiya tushib qolgan —
--     u staff_branch_map orqali Izza Zapchast → «Ta'minot» nom moslashuvi bilan kirgan; qolda ro'yxatiga kirmaydi).
--  3) Avto-bog'lash: user_id bo'sh hodimlar profiles.full_name bilan AYNAN (normallashtirilgan) mos kelsa bog'lanadi
--     (bitta nomzod bo'lsagina) — kelajakda «rol berildi, lekin hodim ko'rmayapti» takrorlanmasin.
--  Old shart: PROVODKA_STANDART_LIMIT_V2.sql va PROVODKA_STANDART_HODIM_FIX.sql RUN bo'lgan.
-- ============================================================================

-- 1) Gulnoza (SQL editor'da auth.uid() yo'q → RPC «Faqat admin» deydi; to'g'ridan update — RPC bilan bir xil natija)
update aros_staff set user_id = '97827481-9236-41fc-8859-bcad0c93c960'::uuid where staff_id = 244;

-- 2) Ta'minot Xitoy — faqat shu ikkisi
delete from staff_filial_qolda
 where filial_id = (select id from accounts where lower(name) = lower('Ta''minot Xitoy') and section = 'pul' and parent_id is null limit 1)
   and staff_id not in (67, 27);
insert into staff_filial_qolda (staff_id, filial_id, updated_by)
select s.staff_id, a.id, auth.uid()
  from (values (67), (27)) as s(staff_id)
  cross join (select id from accounts where lower(name) = lower('Ta''minot Xitoy') and section = 'pul' and parent_id is null limit 1) a
on conflict (staff_id) do update set filial_id = excluded.filial_id, updated_at = now(), updated_by = excluded.updated_by;

-- Ta'minot Xitoy'ga nom moslashuvi (staff_branch_map.provodka_filial ILIKE) orqali begona bo'lim kirmasin:
-- filial_id bo'yicha AYNAN bog'langan bo'limgina sanaladi. (Zulfiya holati.)
update staff_branch_map m
   set filial_id = null
 where m.filial_id = (select id from accounts where lower(name) = lower('Ta''minot Xitoy') and section = 'pul' and parent_id is null limit 1)
   and m.manba = 'avto';

-- 3) avto-bog'lash (bitta aniq nomzod bo'lsa)
do $link$
declare r record; n int := 0;
begin
  for r in
    select s.staff_id, s.toliq_nom, p.id as user_id, p.full_name
      from aros_staff s
      join profiles p on standart_norm(p.full_name) = standart_norm(coalesce(nullif(btrim(s.toliq_nom), ''), btrim(coalesce(s.ism,'')||' '||coalesce(s.familiya,''))))
     where s.user_id is null and s.is_active and p.role <> 'admin'
       and (select count(*) from profiles p2 where standart_norm(p2.full_name) = standart_norm(p.full_name)) = 1
       and not exists (select 1 from aros_staff s2 where s2.user_id = p.id)
  loop
    update aros_staff set user_id = r.user_id where staff_id = r.staff_id;   -- RPC admin talab qiladi (SQL editor'da uid yo'q)
    n := n + 1;
    raise notice 'bog''landi: % (staff %) <-> % (%)', r.toliq_nom, r.staff_id, r.full_name, r.user_id;
  end loop;
  raise notice 'AVTO-BOG''LASH: % hodim', n;
end
$link$;

-- tekshiruv
select s.staff_id, s.toliq_nom, s.user_id is not null as boglangan,
       (select string_agg(r.nom, ', ') from rbac_user_role ur join rbac_role r on r.id = ur.role_id where ur.user_id = s.user_id) as user_rollar,
       (select string_agg(r.nom, ', ') from rbac_staff_role sr join rbac_role r on r.id = sr.role_id where sr.staff_id = s.staff_id) as staff_rollar
  from aros_staff s where s.staff_id in (244, 67, 27) order by s.staff_id;
select q.staff_id, s.toliq_nom, a.name as filial from staff_filial_qolda q
  join aros_staff s on s.staff_id = q.staff_id join accounts a on a.id = q.filial_id order by a.name, s.toliq_nom;
