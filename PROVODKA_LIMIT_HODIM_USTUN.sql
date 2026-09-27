-- ============================================================================
--  PROVODKA_LIMIT_HODIM_USTUN.sql — 2026-09-27 — HODIM limiti bo'lsa FILIAL limiti tekshirilmaydi
--  Asilbek: «limit tanlangan filialdan yechyapti, yozayotgan hodimdan emas». Gulnoza: rolda «Yo'l harajati»
--  1 000 000 (qoldi 572 500), Malika filialida shu modda limiti 14 500 qolgan — filial limiti bloklardi.
--  Qoida: yozuvchi (auth.uid → aros_staff/rbac_user_role) shu moddaga O'Z limitiga ega bo'lsa (rolda modda bor
--  yoki rbac_staff_limit override), sarf FAQAT hodim limitidan yechiladi; filial limiti (standart_xarajat) unga
--  qo'llanmaydi. O'z limiti yo'q hodim (rolsiz) uchun filial limiti avvalgidek ishlaydi.
--  limit_guard_entry_line tanasi PROVODKA_STANDART_LIMIT_V2.sql dan VERBATIM + boshida 1 tekshiruv.
--  Asilbek RUN qiladi.
-- ============================================================================

-- 1) yordamchi: yozuvchida shu moddaga o'z limiti (rol yoki override) bormi
create or replace function rbac_hodim_limit_bor(p_uid uuid, p_account uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_staff int;
begin
  if p_uid is null or p_account is null then return false; end if;
  if exists (
    select 1 from rbac_user_role ur
      join rbac_role r on r.id = ur.role_id and r.is_active
      join rbac_role_modda rm on rm.role_id = ur.role_id and rm.account_id = p_account
     where ur.user_id = p_uid
  ) then return true; end if;
  select staff_id into v_staff from aros_staff where user_id = p_uid limit 1;
  if v_staff is not null then
    if exists (select 1 from rbac_staff_role sr
                 join rbac_role r on r.id = sr.role_id and r.is_active
                 join rbac_role_modda rm on rm.role_id = sr.role_id and rm.account_id = p_account
                where sr.staff_id = v_staff) then return true; end if;
    if to_regclass('public.rbac_staff_limit') is not null and exists (
         select 1 from rbac_staff_limit where staff_id = v_staff and kalit = 'modda:' || p_account::text
       ) then return true; end if;
  end if;
  return false;
end
$fn$;
revoke all on function rbac_hodim_limit_bor(uuid, uuid) from public, anon;
grant execute on function rbac_hodim_limit_bor(uuid, uuid) to authenticated;

-- 2) filial limiti guardi — hodim limiti bo'lsa o'tkazib yuboradi
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
         and f = any(e.filial_ids);
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
comment on function limit_guard_entry_line() is
  'standart_xarajat filial+modda oylik limiti. YANGI (2026-09-27, PROVODKA_LIMIT_HODIM_USTUN.sql): yozuvchida '
  'shu moddaga O''Z limiti (rol/override) bo''lsa filial limiti QO''LLANMAYDI — sarf hodim limitidan yechiladi.';

notify pgrst, 'reload schema';

-- tekshiruv: Gulnoza uchun Yo'l harajati moddasida o'z limiti bormi (true kutiladi)
select rbac_hodim_limit_bor('97827481-9236-41fc-8859-bcad0c93c960'::uuid, a.id) as gulnoza_oz_limiti, a.code, a.name
  from accounts a where a.code = '9414';
