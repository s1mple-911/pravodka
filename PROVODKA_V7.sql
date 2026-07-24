-- =====================================================================
-- PROVODKA V7 — 6 ta ish uchun SQL (bosqichlar izoh bilan ajratilgan)
-- ---------------------------------------------------------------------
-- Tartib (brief): 3 (bug) → 1 (yo'ldagi tovar) → 5 (kommunal) →
--                 2 (filial taqsimoti) → 6 (jurnal — SQLsiz) → 4 (limitlar).
--
-- QOIDA (bitta DB, prod ishlab turibdi): SQL ADDITIVE.
--   * add column if not exists / create table if not exists
--   * yangi funksiya/view yoki `create or replace` ESKI IMZONI SAQLAB
--   * ustun/funksiya O'CHIRISH yoki imzo (argument/tur) O'ZGARTIRISH — TAQIQ
--   * yangi RPC: SECURITY DEFINER + set search_path=public + REVOKE public,anon
--
-- Asilbek qo'lda RUN qiladi. Har bosqichni alohida ham ishga tushirsa bo'ladi.
-- =====================================================================


-- #####################################################################
-- ##  3-BOSQICH — BUG: hodim_oz_tarix(p_from, p_to) topilmadi         ##
-- #####################################################################
-- Frontend (hodim-dev.html) chaqiruvi:
--     sb.rpc('hodim_oz_tarix', {p_from, p_to})
-- Xato:
--     Could not find the function public.hodim_oz_tarix(p_from, p_to)
--     in the schema cache
-- Sabab: PROVODKA_HODIM_V5.sql DB'da RUN qilinmagan (funksiya yo'q).
-- Frontend imzoga (p_from date, p_to date) TO'LIQ mos — o'zgartirish shart emas,
-- faqat funksiyani yaratish kerak. Quyida diagnostika + funksiya (V5 nusxasi).
--
-- ---------------------------------------------------------------------
-- 3.0 DIAGNOSTIKA — funksiya bor-yo'qligini aniqlash (avval shuni ishga tushiring)
-- ---------------------------------------------------------------------
--   select p.oid::regprocedure
--     from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.proname = 'hodim_oz_tarix';
--
--   * 0 qator qaytsa  → funksiya YO'Q → quyidagi create ishga tushiriladi.
--   * hodim_oz_tarix(date, date) qaytsa → imzo TO'G'RI, frontend ham mos →
--     odatda "schema cache" eskirgan: `notify pgrst, 'reload schema';` yoki
--     Supabase → API → "Reload schema" bosiladi.
--   * boshqa imzo qaytsa (masalan (text, text)) → quyidagi create baribir
--     (date,date) variantini qo'shadi; frontend (date) yuboradi, mos keladi.
-- ---------------------------------------------------------------------

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

-- PostgREST schema cache'ni yangilash (funksiya darrov ko'rinsin)
notify pgrst, 'reload schema';

do $$
begin
  if to_regprocedure('public.hodim_oz_tarix(date,date)') is null then
    raise exception '3-BOSQICH: hodim_oz_tarix(date,date) yaratilmadi';
  end if;
  raise notice '3-BOSQICH OK: hodim_oz_tarix(date,date) tayyor.';
end $$;
