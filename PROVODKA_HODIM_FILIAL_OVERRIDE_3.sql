-- ============================================================================
--  PROVODKA_HODIM_FILIAL_OVERRIDE_3.sql — 2026-10-04 — ovqat_mening_staff_v2: SABAB bilan javob + kassa nomi orqali zaxira
--  Asilbek: «Fayoz bilan hodim-dev da edim, baribir chiqmayapti» (server test: 147 → Buxoro Eski Sum kassa, 4 a'zo).
--  Ehtimoliy sabab: Fayozning auth hisobi aros_staff.user_id ga BOG'LANMAGAN → _2 dagi 1-yo'l ishlamaydi, 2-yo'l (kassa
--  subtitle nomi) bo'sh → '{}' — klient «Kassangizga filial biriktirilmagan» deydi, sabab ko'rinmaydi.
--  v2: (1) user_id → staff; (2) YO'Q bo'lsa tanlangan hodim KASSASI nomi = aros_staff.toliq_nom (normallashtirilgan, YAGONA
--  moslik) → staff; (3) nom yo'li. Javob jsonb: {ids, manba:'user'|'kassa'|'nom'|'yoq', staff_id, staff_nom, filiallar, sabab}.
--  Eski ovqat_mening_staff(text) TEGILMAGAN. Asilbek RUN qiladi.
-- ============================================================================
create or replace function _ovqat_nom_norm(p text)
returns text
language sql
immutable
as $fn$
  select regexp_replace(lower(translate(coalesce(p, ''), 'ʼ''’`‘', '     ')), '\s+', ' ', 'g');
$fn$;
revoke all on function _ovqat_nom_norm(text) from public, anon, authenticated;

create or replace function ovqat_mening_staff_v2(p_filial_nom text default null, p_kassa_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_nom     text := nullif(btrim(coalesce(p_filial_nom, '')), '');
  v_staff   int;
  v_manba   text := 'yoq';
  v_my      uuid[];
  v_ids     int[];
  v_kassa_nom text;
  v_cnt     int;
begin
  if auth.uid() is null then
    return jsonb_build_object('ids', '[]'::jsonb, 'manba', 'yoq', 'sabab', 'auth');
  end if;

  -- 1) user_id → staff
  select staff_id into v_staff from aros_staff where user_id = auth.uid() limit 1;
  if v_staff is not null then v_manba := 'user'; end if;

  -- 2) kassa nomi → staff (yagona moslik bo'lsagina)
  if v_staff is null and p_kassa_id is not null then
    select a.name into v_kassa_nom from accounts a where a.id = p_kassa_id;
    if v_kassa_nom is null then
      -- pul turi bola-hisobi bo'lishi mumkin — ildizini ol
      select p.name into v_kassa_nom from accounts c join accounts p on p.id = c.parent_id where c.id = p_kassa_id;
    end if;
    if v_kassa_nom is not null then
      select count(*), min(s.staff_id) into v_cnt, v_staff
        from aros_staff s
       where s.is_active and _ovqat_nom_norm(s.toliq_nom) = _ovqat_nom_norm(v_kassa_nom);
      if v_cnt = 1 then v_manba := 'kassa'; else v_staff := null; end if;
    end if;
  end if;

  if v_staff is not null then
    v_my := coalesce(hodim_filiallari(v_staff), '{}'::uuid[]);
    if cardinality(v_my) > 0 then
      select coalesce(array_agg(s.staff_id), '{}'::int[]) into v_ids
        from aros_staff s
       where s.is_active
         and exists (select 1 from unnest(v_my) f where hodim_filial_azo(s.staff_id, f));
      return jsonb_build_object(
        'ids', to_jsonb(v_ids), 'manba', v_manba, 'staff_id', v_staff,
        'staff_nom', (select toliq_nom from aros_staff where staff_id = v_staff),
        'filiallar', (select coalesce(jsonb_agg(a.name order by a.name), '[]'::jsonb) from accounts a where a.id = any(v_my)),
        'sabab', case when cardinality(v_ids) = 0 then 'filialda_hodim_yoq' else null end);
    end if;
    -- hodim topildi, lekin filialsiz
    return jsonb_build_object('ids', '[]'::jsonb, 'manba', v_manba, 'staff_id', v_staff,
      'staff_nom', (select toliq_nom from aros_staff where staff_id = v_staff),
      'filiallar', '[]'::jsonb, 'sabab', 'hodim_filialsiz');
  end if;

  -- 3) nom yo'li (eski) — buxgalter/admin yoki bog'lanmagan user
  v_ids := ovqat_mening_staff(v_nom);
  return jsonb_build_object('ids', to_jsonb(coalesce(v_ids, '{}'::int[])), 'manba', 'nom', 'filial_nom', v_nom,
    'sabab', case when v_nom is null then 'kassa_filialsiz'
                  when cardinality(coalesce(v_ids, '{}'::int[])) = 0 then 'nom_topilmadi' end);
end
$fn$;
revoke all on function ovqat_mening_staff_v2(text, uuid) from public, anon;
grant execute on function ovqat_mening_staff_v2(text, uuid) to authenticated;
notify pgrst, 'reload schema';

-- TEKSHIRUV: override'li hodimlar auth hisobiga bog'langanmi (user_id) — null bo'lsa 1-yo'l ishlamaydi
select s.staff_id, s.toliq_nom, s.user_id is not null as auth_boglangan, hodim_filial_nomlar(s.staff_id) as filiallar,
       (select count(*) from accounts a where a.kassa_turi = 'xarajat' and _ovqat_nom_norm(a.name) = _ovqat_nom_norm(s.toliq_nom)) as nomdosh_kassa
  from aros_staff s
 where s.staff_id in (select staff_id from hodim_filial_override);
