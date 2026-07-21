-- =====================================================================
-- PROVODKA — HODIM V5
-- ---------------------------------------------------------------------
-- hodim_oz_tarix(p_from, p_to) — hodim O'Z xarajat tarixi (davr bo'yicha):
--   { kategoriya:[{code,name,jami}], royxat:[{entry_id,entry_date,created_at,
--     kassa_id,modda_code,modda_name,summa,izoh}] }
--
-- Har authenticated FAQAT o'z kassalari bo'yicha ko'radi. Kassa to'plamini
-- auth.uid() ning user_perms.op_kassa_ids'idan (list scope) yoki — cheklovsiz/
-- admin bo'lsa — barcha hodim (xarajat) kassalaridan aniqlaydi.
--
-- SECURITY DEFINER, REVOKE anon. Idempotent. Asilbek RUN qiladi.
-- entry insert yo'li o'zgarmaydi.
-- =====================================================================

create or replace function hodim_oz_tarix(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p     user_perms;
  v_ids uuid[];
  v_kat jsonb;
  v_roy jsonb;
begin
  -- caller kassalari
  select * into p from user_perms where user_id = auth.uid();
  if found and p.kassa_scope = 'list' then
    -- op kassalari (perm key = hodim kassasining o'z id'si; valyuta bolasi bo'lmaydi)
    select array_agg(a.id) into v_ids
      from accounts a
     where a.type = 'aktiv' and a.code like '5%'
       and a.kassa_turi <> 'xarajat_guruh'
       and perm_op_key(a.id) = any(p.op_kassa_ids);
  else
    -- cheklovsiz / admin: barcha hodim (xarajat) kassalari
    select array_agg(a.id) into v_ids
      from accounts a
     where a.kassa_turi = 'xarajat';
  end if;

  if v_ids is null or array_length(v_ids, 1) is null then
    return jsonb_build_object('kategoriya', '[]'::jsonb, 'royxat', '[]'::jsonb);
  end if;

  -- Kategoriya: shu kassalardan chiqqan (Kt=kassa) xarajat modda (Dt) bo'yicha jami
  select coalesce(jsonb_agg(to_jsonb(x) order by x.jami desc), '[]'::jsonb) into v_kat
  from (
    select ma.code, ma.name, sum(dl.debit)::numeric as jami
      from entry e
      join entry_line kl on kl.entry_id = e.id and kl.credit > 0 and kl.account_id = any(v_ids)
      join entry_line dl on dl.entry_id = e.id and dl.debit > 0
      join accounts ma on ma.id = dl.account_id and ma.type = 'xarajat'
     where e.status = 'posted' and e.is_deleted = false
       and e.entry_date >= p_from and e.entry_date <= p_to
     group by ma.code, ma.name
    having sum(dl.debit) > 0
  ) x;

  -- Ro'yxat: har xarajat yozuvi (eng yangi 200 ta)
  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v_roy
  from (
    select e.id as entry_id, e.entry_date, e.created_at,
           kl.account_id as kassa_id,
           ma.code as modda_code, ma.name as modda_name,
           dl.debit::numeric as summa,
           e.description as izoh
      from entry e
      join entry_line kl on kl.entry_id = e.id and kl.credit > 0 and kl.account_id = any(v_ids)
      join entry_line dl on dl.entry_id = e.id and dl.debit > 0
      join accounts ma on ma.id = dl.account_id and ma.type = 'xarajat'
     where e.status = 'posted' and e.is_deleted = false
       and e.entry_date >= p_from and e.entry_date <= p_to
     order by e.created_at desc
     limit 200
  ) r;

  return jsonb_build_object('kategoriya', v_kat, 'royxat', v_roy);
end $$;

revoke all on function hodim_oz_tarix(date, date) from public, anon;
grant execute on function hodim_oz_tarix(date, date) to authenticated;

comment on function hodim_oz_tarix(date, date) is
  'Hodim o''z xarajat tarixi (kategoriya + ro''yxat) — auth.uid() ning o''z kassalari bo''yicha.';
