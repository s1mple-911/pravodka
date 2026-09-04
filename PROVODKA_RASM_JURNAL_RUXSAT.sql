-- =====================================================================
-- PROVODKA_RASM_JURNAL_RUXSAT.sql  (2026-09-05)
-- Jurnaldagi «AI chek» / «Tablo» fayli va AI xulosasi tafsiloti FAQAT adminga
-- (va yozuv egasiga) ochiq edi — jurnal ruxsati bor boshqa userlar faylni bosganda
-- «Fayl topilmadi» / bo'sh tafsilot ko'rardi. Sabab: `rasm_tahlil` va `mashina_km`
-- RLS + `rasm-tahlil` bucket policy — «auth.uid() = user_id or is_admin()».
-- (Oddiy chek `xarajat-cheklari` bucket'i hammaga ochiq — shuning uchun faqat
-- AI fayl «yo'qolgan» edi.)
-- Asilbek QO'LDA RUN qiladi. ADDITIVE: policy'lar o'sha NOM bilan qayta yaratiladi
-- (drop + create), ikkita yangi yordamchi funksiya. Jadval/ustun o'zgarmaydi.
--
-- YANGI QOIDA — «jurnal ruxsati yetarli» (CLAUDE.md, AI xulosasi ustuni 2026-08-31):
--   ko'rish = o'zi  OR  admin  OR  ( jurnal sahifasi ruxsati  AND  yozuv kassasi
--   ko'rish doirasida (kassa_scope='list' bo'lsa view_kassa_ids, perm_op_key orqali) ).
-- Kassa doirasi shart — cheklangan user jurnalda ko'rmaydigan yozuvning rasmini
-- to'g'ridan URL bilan ham ololmasin (jurnal filtri klientda, bu server qatlami).
-- `sorov_page_ok` authenticated'dan yopiq — shuning uchun security definer qobiq
-- (qarz_page_ok naqshi). perm_op_key yo'q bazada — fail-closed (faqat o'zi/admin).
-- Izohda dollar-qavs yozilmaydi. Tanalar nomlangan teg bilan.
-- =====================================================================

-- 1) Yozuvni ko'rish ruxsati (jurnal sahifasi + kassa doirasi)
create or replace function jurnal_entry_korish_ok(p_entry uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_p   user_perms%rowtype;
begin
  if v_uid is null or p_entry is null then return false; end if;
  if is_admin() then return true; end if;
  if not sorov_page_ok('jurnal') then return false; end if;
  select * into v_p from user_perms where user_id = v_uid;
  if not found or coalesce(v_p.kassa_scope, 'all') <> 'list' then return true; end if;
  if to_regprocedure('public.perm_op_key(uuid)') is null then return false; end if;
  return exists (
    select 1 from entry_line l
     where l.entry_id = p_entry
       and perm_op_key(l.account_id) = any(coalesce(v_p.view_kassa_ids, '{}'::uuid[]))
  );
end
$fn$;

revoke all on function jurnal_entry_korish_ok(uuid) from public, anon;
grant execute on function jurnal_entry_korish_ok(uuid) to authenticated;

comment on function jurnal_entry_korish_ok(uuid) is
  'RLS qorovuli: admin YOKI (jurnal sahifasi ruxsati VA yozuv kassasi view doirasida). Fayl/AI tafsilot uchun.';

-- 2) AI tahlil qatorini ko'rish — unga bog'langan (chek yoki spidometr) yozuv ko'rinsa
create or replace function jurnal_rasm_ok(p_rt uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  e     record;
begin
  if v_uid is null or p_rt is null then return false; end if;
  if is_admin() then return true; end if;
  if exists (select 1 from rasm_tahlil r where r.id = p_rt and r.user_id = v_uid) then return true; end if;
  if not sorov_page_ok('jurnal') then return false; end if;
  for e in
    select id from entry
     where rasm_tahlil_id = p_rt or spidometr_tahlil_id = p_rt
  loop
    if jurnal_entry_korish_ok(e.id) then return true; end if;
  end loop;
  return false;
end
$fn$;

revoke all on function jurnal_rasm_ok(uuid) from public, anon;
grant execute on function jurnal_rasm_ok(uuid) to authenticated;

comment on function jurnal_rasm_ok(uuid) is
  'rasm_tahlil qatori / rasm-tahlil fayli ko''rish: egasi, admin yoki shu tahlil bog''langan yozuvni jurnalda ko''ra oladigan user.';

-- 3) rasm_tahlil — o'zi / admin / jurnal (yozuv orqali)
drop policy if exists rasm_tahlil_sel on rasm_tahlil;
create policy rasm_tahlil_sel on rasm_tahlil
  for select to authenticated
  using ((select auth.uid()) = user_id or is_admin() or jurnal_rasm_ok(id));

-- 4) mashina_km — o'zi / admin / yozuv jurnalda ko'rinsa
drop policy if exists mashina_km_sel on mashina_km;
create policy mashina_km_sel on mashina_km
  for select to authenticated
  using ((select auth.uid()) = user_id or is_admin() or jurnal_entry_korish_ok(entry_id));

-- 5) rasm-tahlil bucket — fayl yo'li <user_id>/<rasm_tahlil_id>.jpg
drop policy if exists "rasm_tahlil_bucket_select" on storage.objects;
create policy "rasm_tahlil_bucket_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'rasm-tahlil'
    and (
      is_admin()
      or (
        (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
        and ((storage.foldername(name))[1])::uuid = (select auth.uid())
      )
      or (
        regexp_replace(storage.filename(name), '\.[A-Za-z0-9]+$', '') ~ '^[0-9a-fA-F-]{36}$'
        and jurnal_rasm_ok((regexp_replace(storage.filename(name), '\.[A-Za-z0-9]+$', ''))::uuid)
      )
    )
  );

-- Tekshiruv (ixtiyoriy): jurnal ruxsati bor, admin bo'lmagan user sessiyasida
--   select id from rasm_tahlil limit 5;   -- endi begona (lekin jurnalda ko'rinadigan) qatorlar ham keladi
