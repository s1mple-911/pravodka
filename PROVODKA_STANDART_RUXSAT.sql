-- =====================================================================
-- PROVODKA — STANDART XARAJATLAR: ruxsat + avtomatik bo'lim bog'lash
-- (2026-09-09, Asilbek)
-- ---------------------------------------------------------------------
-- ## MUAMMO 1 — «faqat admin limit qo'yadi / faqat admin filialni bog'laydi»
--   Standart sahifasi O'QISH tomonida ruxsat kengroq:
--       standart_filial_moddalar / standart_branch_takliflar
--         -> admin YOKI perm_has_page('standart')
--   YOZISH tomonida esa qat'iy `is_admin()` qolib ketgan:
--       standart_limit_set     -> «Faqat admin limit qo'ya oladi»
--       standart_limit_delete  -> «Faqat admin o'chira oladi»
--       standart_branch_bogla  -> «Faqat admin bo'limlarni bog'laydi»
--   Natija: sahifaga ruxsati bor odam hamma narsani KO'RADI, lekin
--   birortasini o'zgartira olmaydi.
--
--   YECHIM: uchalasi ham `standart_page_ok()` ga o'tadi — o'qish bilan
--   AYNI qoida. Sahifa ruxsatining o'zi allaqachon admin tomonidan
--   beriladi (`user_perms.allowed_pages`), ya'ni nazorat yo'qolmaydi.
--
-- ## MUAMMO 2 — bo'limlarni qo'lda birma-bir bog'lash
--   Har filial uchun modal ochib, taklifni belgilab, saqlash kerak edi.
--   YANGI: `standart_branch_avto_bogla()` — HAMMA filial uchun taklifni
--   (ball >= 3, `standart_branch_takliflar` bilan AYNI mezon) bir zarbda
--   qo'llaydi.
--   🔴 Faqat HALI BOG'LANMAGAN bo'limlar (`filial_id is null`) bog'lanadi —
--      qo'lda qilingan bog'lanish HECH QACHON ustidan yozilmaydi.
--   🔴 Bir bo'lim ikki filialga ball>=3 bersa — eng katta balli olinadi;
--      ball TENG bo'lsa hech biriga bog'lanmaydi («ikki xil» deb qaytadi),
--      chunki taxmin qilish noto'g'ri bog'lanishdan yomonroq.
--   Taklif YO'Q bo'limlar ochiq (bog'lanmagan) qoladi — Asilbek shunday
--   so'radi; bog'langanini ham modaldan tahrirlash mumkin.
--
-- ## QOIDALAR (CLAUDE.md)
--   * ADDITIVE: imzolar o'zgarmaydi (`standart_limit_set`,
--     `standart_limit_delete`, `standart_branch_bogla`). Bittasi YANGI.
--   * anonim `do` bloki YO'Q; funksiya tanasi nomlangan dollar-teg bilan.
--     (Eski `standart_limit_*` PROVODKA_V7.sql da anonim dollar-teg bilan
--      edi — bu yerda nomlangan tegga o'tkazildi, tana mantiqi bir xil.)
--   * idempotent: qayta RUN xavfsiz.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART (faqat select/exception)                   ##
-- #####################################################################

do $std_ruxsat_pre$
begin
  if to_regprocedure('public.standart_limit_set(uuid,uuid,numeric)') is null then
    raise exception 'standart_limit_set(...) yoq — avval PROVODKA_V7.sql ni bajaring';
  end if;
  if to_regprocedure('public.standart_limit_delete(uuid)') is null then
    raise exception 'standart_limit_delete(uuid) yoq — avval PROVODKA_V7.sql ni bajaring';
  end if;
  if to_regprocedure('public.standart_branch_bogla(uuid,int[])') is null then
    raise exception 'standart_branch_bogla(uuid,int[]) yoq — avval PROVODKA_STANDART_ROL.sql ni bajaring';
  end if;
  if to_regprocedure('public.standart_ball(text,text)') is null then
    raise exception 'standart_ball(text,text) yoq — avval PROVODKA_STANDART_ROL.sql ni bajaring';
  end if;
  if to_regclass('public.staff_branch_map') is null then
    raise exception 'staff_branch_map yoq';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_name = 'staff_branch_map' and column_name = 'filial_id') then
    raise exception 'staff_branch_map.filial_id yoq — avval PROVODKA_STANDART_ROL.sql ni bajaring';
  end if;
end
$std_ruxsat_pre$;


-- #####################################################################
-- ##  1-BO'LIM — standart_page_ok() — YAGONA ruxsat qoidasi           ##
-- #####################################################################
-- `standart_filial_moddalar` / `standart_branch_takliflar` ichidagi
-- tekshiruvning AYNAN o'zi, endi bitta joyda. `perm_has_page` bazada
-- bo'lmasligi mumkin (PROVODKA_PERMS.sql run qilinmagan) — o'shanda
-- FAIL-CLOSED: faqat admin.

create or replace function standart_page_ok()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    return false;                       -- service_role/cron bu RPClarni chaqirmaydi
  end if;
  if is_admin() then
    return true;
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'perm_has_page'
  ) then
    return perm_has_page('standart');
  end if;
  return false;                         -- fail-closed
end $fn$;

revoke all on function standart_page_ok() from public, anon;
grant execute on function standart_page_ok() to authenticated;

comment on function standart_page_ok() is
  'Standart xarajatlar sahifasiga yozish huquqi: admin YOKI perm_has_page(''standart''). '
  'perm_has_page yoq bazada fail-closed (faqat admin). O''qish RPClaridagi tekshiruv bilan AYNI.';


-- #####################################################################
-- ##  2-BO'LIM — standart_limit_set / standart_limit_delete           ##
-- #####################################################################
-- 🔴 PROVODKA_V7.sql (539-576) dagi tananing nusxasi. Farq: `is_admin()`
--    o'rniga `standart_page_ok()`, va anonim dollar-teg o'rniga nomlangan.

create or replace function standart_limit_set(p_filial uuid, p_modda uuid, p_limit numeric)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare v_id uuid; v_by text;
begin
  if not standart_page_ok() then
    raise exception 'Standart xarajatlar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;
  if p_filial is null or p_modda is null then raise exception 'Filial/modda tanlanmadi' using errcode = '22000'; end if;
  if p_limit is null or p_limit <= 0 then raise exception 'Limit musbat bo''lishi kerak' using errcode = '22000'; end if;
  select coalesce(full_name, '') into v_by from profiles where id = auth.uid();
  insert into standart_xarajat (filial_id, modda_id, limit_uzs, updated_by)
  values (p_filial, p_modda, p_limit, v_by)
  on conflict (filial_id, modda_id) do update
    set limit_uzs = excluded.limit_uzs, updated_by = excluded.updated_by
  returning id into v_id;
  return v_id;
end $fn$;

revoke all on function standart_limit_set(uuid, uuid, numeric) from public, anon;
grant execute on function standart_limit_set(uuid, uuid, numeric) to authenticated;

comment on function standart_limit_set(uuid, uuid, numeric) is
  'Limit qo''yish/yangilash. YANGI (2026-09-09): admin ONLY emas — standart_page_ok() '
  '(admin YOKI perm_has_page(''standart'')), o''qish RPClari bilan bir xil.';


create or replace function standart_limit_delete(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not standart_page_ok() then
    raise exception 'Standart xarajatlar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;
  delete from standart_xarajat where id = p_id;
end $fn$;

revoke all on function standart_limit_delete(uuid) from public, anon;
grant execute on function standart_limit_delete(uuid) to authenticated;

comment on function standart_limit_delete(uuid) is
  'Limitni o''chirish. YANGI (2026-09-09): standart_page_ok() (admin ONLY emas).';


-- #####################################################################
-- ##  3-BO'LIM — standart_branch_bogla — ruxsat kengaytirildi         ##
-- #####################################################################
-- 🔴 PROVODKA_STANDART_ROL.sql (569-613) dagi tananing VERBATIM nusxasi.
--    Yagona farq: `is_admin()` -> `standart_page_ok()`.

create or replace function standart_branch_bogla(p_filial uuid, p_branch_ids int[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_filial_id uuid;
  v_ids       int[];
  v_n         int;
begin
  if not standart_page_ok() then
    raise exception 'Standart xarajatlar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;
  if p_filial is null then
    raise exception 'Filial tanlanmadi' using errcode = '22000';
  end if;

  select id into v_filial_id
    from accounts
   where id = p_filial
     and kassa_turi = 'filial'
     and parent_id is null
     and coalesce(is_active, true);
  if v_filial_id is null then
    raise exception 'Filial topilmadi: %', p_filial using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct x), '{}') into v_ids
    from unnest(coalesce(p_branch_ids, '{}'::int[])) x;

  update staff_branch_map
     set filial_id = v_filial_id, updated_at = now(), updated_by = auth.uid()::text
   where branch_id = any(v_ids)
     and filial_id is distinct from v_filial_id;

  update staff_branch_map
     set filial_id = null, updated_at = now(), updated_by = auth.uid()::text
   where filial_id = v_filial_id
     and not (branch_id = any(v_ids));

  select count(*) into v_n from staff_branch_map where filial_id = v_filial_id;
  return jsonb_build_object('ok', true, 'soni', v_n);
end
$fn$;

revoke all on function standart_branch_bogla(uuid, int[]) from public, anon;
grant execute on function standart_branch_bogla(uuid, int[]) to authenticated;

comment on function standart_branch_bogla(uuid, int[]) is
  'staff_branch_map.filial_id ni yozadi — p_branch_ids p_filial ga bog''lanadi, ro''yxatda '
  'yo''q bo''limlar ajratiladi (filial_id=null). YANGI (2026-09-09): standart_page_ok() (admin ONLY emas).';


-- #####################################################################
-- ##  4-BO'LIM — standart_branch_avto_bogla() — YANGI                 ##
-- #####################################################################
-- HAMMA filial uchun taklifni bir zarbda qo'llaydi.
--   * Mezon `standart_branch_takliflar` bilan AYNI: `standart_ball >= 3`.
--   * FAQAT `filial_id is null` bo'limlar — qo'lda qilingan bog'lanish
--     hech qachon ustidan yozilmaydi.
--   * Bir bo'lim ikki filialga ball>=3 bersa: eng katta ball yutadi;
--     TENG bo'lsa bog'lanmaydi va `chalkash[]` ga tushadi (odam hal qiladi).
-- Qaytishi: {ok, soni, bogландi[...], chalkash[...]}

create or replace function standart_branch_avto_bogla()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_out jsonb;
begin
  if not standart_page_ok() then
    raise exception 'Standart xarajatlar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;

  -- 🔴 Temp jadval ATAYLAB ishlatilmaydi (mavjud naqsh) — hammasi CTE.
  --    `yoz` — ma'lumot o'zgartiruvchi CTE; u BIR MARTA bajariladi, lekin
  --    natijasiga ikki marta murojaat qilinadi (soni + ro'yxat).
  with kandidat as (
    select m.branch_id, m.branch_nomi, a.id as filial_id, a.name as filial_nom,
           standart_ball(m.branch_nomi, a.name) as ball
      from staff_branch_map m
      cross join accounts a
     where m.filial_id is null
       and a.kassa_turi = 'filial'
       and a.parent_id is null
       and coalesce(a.is_active, true)
       and standart_ball(m.branch_nomi, a.name) >= 3
  ),
  eng as (
    select k.*, max(k.ball) over (partition by k.branch_id) as mx from kandidat k
  ),
  top as (
    select * from eng where ball = mx
  ),
  -- Eng yuqori ball YAGONA filialga tegishli -> bog'lanadi.
  tanho as (
    select t.* from top t
     where t.branch_id in (select branch_id from top group by branch_id having count(*) = 1)
  ),
  -- Ball TENG bo'lgan bir nechta filial -> odam hal qilsin, tegilmaydi.
  chalk as (
    select t.branch_id, min(t.branch_nomi) as branch_nomi, min(t.ball) as ball,
           jsonb_agg(t.filial_nom order by t.filial_nom) as nomlar
      from top t
     where t.branch_id in (select branch_id from top group by branch_id having count(*) > 1)
     group by t.branch_id
  ),
  yoz as (
    update staff_branch_map m
       set filial_id = t.filial_id, updated_at = now(), updated_by = auth.uid()::text
      from tanho t
     where m.branch_id = t.branch_id
       and m.filial_id is null
    returning m.branch_id, t.branch_nomi, t.filial_id, t.filial_nom, t.ball
  )
  select jsonb_build_object(
           'ok', true,
           'soni', (select count(*) from yoz),
           'boglandi', (select coalesce(jsonb_agg(jsonb_build_object(
                          'branch_id', y.branch_id, 'branch_nomi', y.branch_nomi,
                          'filial_id', y.filial_id, 'filial_nom', y.filial_nom, 'ball', y.ball)
                          order by y.filial_nom, y.branch_nomi), '[]'::jsonb) from yoz y),
           'chalkash', (select coalesce(jsonb_agg(jsonb_build_object(
                          'branch_id', c.branch_id, 'branch_nomi', c.branch_nomi,
                          'ball', c.ball, 'filiallar', c.nomlar)
                          order by c.branch_nomi), '[]'::jsonb) from chalk c))
    into v_out;

  return v_out;
end $fn$;

revoke all on function standart_branch_avto_bogla() from public, anon;
grant execute on function standart_branch_avto_bogla() to authenticated;

comment on function standart_branch_avto_bogla() is
  'HAMMA filial uchun taklifni (standart_ball >= 3) bir zarbda qo''llaydi. FAQAT bog''lanmagan '
  '(filial_id is null) bo''limlar — qo''lda bog''langani tegilmaydi. Ball teng bo''lgan ikki '
  'xil filial -> chalkash[] ga tushadi, bog''lanmaydi. Ruxsat: standart_page_ok().';


-- #####################################################################
-- ##  PostgREST sxema keshi                                           ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  5-BO'LIM — TEKSHIRUV (faqat select)                             ##
-- #####################################################################

select to_regprocedure('public.standart_page_ok()')                is not null as fn_page_ok,
       to_regprocedure('public.standart_branch_avto_bogla()')      is not null as fn_avto,
       to_regprocedure('public.standart_limit_set(uuid,uuid,numeric)') is not null as fn_limit_set,
       to_regprocedure('public.standart_branch_bogla(uuid,int[])') is not null as fn_bogla;

-- Avtomatik bog'lash NIMA qilishini OLDINDAN ko'rish (hech narsa yozmaydi):
select m.branch_id, m.branch_nomi, a.name as filial_nom,
       standart_ball(m.branch_nomi, a.name) as ball
  from staff_branch_map m
  cross join accounts a
 where m.filial_id is null
   and a.kassa_turi = 'filial' and a.parent_id is null and coalesce(a.is_active, true)
   and standart_ball(m.branch_nomi, a.name) >= 3
 order by a.name, m.branch_nomi;

-- Hozirgi bog'lanish holati
select coalesce(a.name, '— bog''lanmagan —') as filial, count(*) as bolim_soni
  from staff_branch_map m
  left join accounts a on a.id = m.filial_id
 group by a.name
 order by (a.name is null) desc, a.name;
