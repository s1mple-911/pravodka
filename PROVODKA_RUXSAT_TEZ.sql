-- =====================================================================
-- PROVODKA_RUXSAT_TEZ.sql  (2026-09-03)
-- «Ruxsat so'rash» modali — yopiq xarajat turlari ro'yxati SEKIN yuklanardi
-- (hodimlar: «ko'p vaqt ketyapti / Qayta urinish chiqyapti»).
-- Asilbek QO'LDA RUN qiladi. ADDITIVE: `create or replace` eski imzo bilan
-- (ruxsat_yopiq_moddalar() -> jsonb), qaytish shakli o'zgarmagan. Idempotent.
--
-- SABAB: eski tana har xarajat moddasi uchun ALOHIDA rbac_modda_ok(a.id)
-- chaqirardi (plpgsql, security definer, ichida is_admin() + join) — N modda
-- = N×2 so'rov. Endi BITTA to'plamli so'rov: foydalanuvchining rollari orqali
-- ruxsatli moddalar to'plami `not exists` bilan bir marta hisoblanadi.
-- Semantika AYNAN rbac_modda_ok bilan bir xil (auth.uid() bor, admin emas
-- holat uchun): rolsiz user → hamma modda yopiq (fail-closed, o'zgarmagan).
-- Admin → bo'sh massiv (o'zgarmagan). 9110-1 istisnosi saqlangan.
-- Qo'shimcha: rbac_role_modda(role_id, account_id) indeksi (additive).
-- ⚠️ Izohda dollar-qavs yozilmaydi (CLAUDE.md). Tana nomlangan teg bilan.
-- =====================================================================

create index if not exists rbac_role_modda_role_account_idx
  on rbac_role_modda (role_id, account_id);

create or replace function ruxsat_yopiq_moddalar()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  -- Adminga hech narsa yopiq emas — royxat bosh (eski xulq).
  if is_admin() then
    return '[]'::jsonb;
  end if;

  -- Bitta to'plamli so'rov: rbac_modda_ok(a.id) ning inline shakli.
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name)
                             order by a.code), '[]'::jsonb)
    into v_out
    from accounts a
   where a.type = 'xarajat'
     and coalesce(a.is_active, true)
     and a.code <> '9110-1'
     and not exists (
       select 1
         from rbac_user_role ur
         join rbac_role r on r.id = ur.role_id and r.is_active
         join rbac_role_modda m on m.role_id = ur.role_id and m.account_id = a.id
        where ur.user_id = v_uid
     );

  return v_out;
end $fn$;

revoke all on function ruxsat_yopiq_moddalar() from public, anon;
grant execute on function ruxsat_yopiq_moddalar() to authenticated;

comment on function ruxsat_yopiq_moddalar() is
  'Chaqiruvchi uchun YOPIQ xarajat moddalari royxati (rollar orqali ruxsati yoqlar). '
  'Admin -> bosh massiv. 2026-09-03: bitta toplamli sorov (avval har modda uchun rbac_modda_ok).';

-- Tekshiruv (ixtiyoriy, hodim sessiyasida): select ruxsat_yopiq_moddalar();
-- Vaqt: Supabase SQL editorida `explain analyze select ruxsat_yopiq_moddalar();`
