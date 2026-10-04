-- ============================================================================
--  PROVODKA_HODIM_FILIAL_OVERRIDE_2.sql — 2026-10-04 — ovqat ro'yxati YOZUVCHINING O'Z filiallari bo'yicha
--  Asilbek: «Fayozbekni Buxoro eski sumga override qildim, lekin ovqat yozguncha Buxoro hodimlari chiqmayapti».
--  Sabab: ovqat_mening_staff(p_filial_nom) faqat KASSA subtitle'idagi bo'lim nomi bo'yicha ishlardi (kassa eski
--  filial nomini saqlaydi) — override hodimning O'ZIGA tegishli, kassaga emas.
--  Endi: chaqiruvchi aros_staff'ga bog'langan hodim bo'lsa → uning EFFEKTIV filiallari (hodim_filiallari — override
--  birinchi) bo'yicha a'zo hodimlar (hodim_filial_azo). Bog'lanmagan (buxgalter/admin) yoki filialsiz hodim → eski nom
--  mantiqi. Imzo o'zgarmagan. Old shart: PROVODKA_HODIM_FILIAL_OVERRIDE.sql. Asilbek RUN qiladi.
-- ============================================================================
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
revoke all on function ovqat_mening_staff(text) from public, anon;
grant execute on function ovqat_mening_staff(text) to authenticated;
notify pgrst, 'reload schema';

-- TEKSHIRUV (Fayozbek misoli): hodimning effektiv filiallari va shu filiallarning a'zolari soni
select s.staff_id, s.toliq_nom, hodim_filial_nomlar(s.staff_id) as filiallar,
       (select count(*) from aros_staff s2 where s2.is_active
          and exists (select 1 from unnest(hodim_filiallari(s.staff_id)) f where hodim_filial_azo(s2.staff_id, f))) as azo_hodimlar
  from aros_staff s
 where s.staff_id in (select staff_id from hodim_filial_override);
