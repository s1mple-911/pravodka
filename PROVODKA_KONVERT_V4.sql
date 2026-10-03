-- ============================================================================
--  PROVODKA_KONVERT_V4.sql — 2026-10-03 — KONVERT: alohida sahifa ruxsati + VALYUTA → VALYUTA (ustama bilan)
--  Asilbek: (1) «konvert faqat kassa sahifasi ichida — boshqa odamga konvert qil desam kassaga dostup berishga
--  to'g'ri kelyapti» → `konvert` sahifasi ruxsati konvert qilish huquqini ham beradi (perm_can_convert).
--  (2) «o'zimda turgan pulni aylantirish — dollar kassamdan yuan kassamga, ustama bilan (foizda yoki oddiy)» →
--  convert_valyuta_v4: ikki valyuta hisobi orasida to'g'ridan konvert (so'mga sotib, qayta sotib olish SHART EMAS).
--  Ustama (komissiya) — alohida yozuv: Dt «Konvert ustama» XARAJAT moddasi / Kt beruvchi valyuta hisobi. Shunda
--  valyuta qoldig'i haqiqiy miqdorga tushadi, ustama P&L da xarajat bo'lib ko'rinadi (Kurs farqi moddasi bilan bir xil g'oya).
--  So'm baholash: ikkala satr BIR XIL so'm qiymatda (V) — p_uzs berilsa o'sha, bo'lmasa p_amount × conv_baza_kurs(berilayotgan valyuta).
--  Eski imzolar (convert_start_v2/v3, do_convert_v2) TEGILMAGAN. Additive. Asilbek RUN qiladi.
-- ============================================================================

-- 1) Konvert ruxsati: konvert sahifasi ham yetarli
create or replace function perm_can_convert()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare p user_perms;
begin
  if auth.uid() is null then return true; end if;
  if is_admin() then return true; end if;
  select * into p from user_perms where user_id = auth.uid();
  if not found then return true; end if;
  if 'kassa' = any(coalesce(p.allowed_pages, '{}'::text[])) then return true; end if;
  -- 🔴 2026-10-03: konvert sahifasi ruxsati = konvert qilish huquqi (kassa sahifasiz)
  if 'konvert' = any(coalesce(p.allowed_pages, '{}'::text[])) then return true; end if;
  return p.can_convert;
end $fn$;
revoke all on function perm_can_convert() from public, anon;
grant execute on function perm_can_convert() to authenticated, service_role;
comment on function perm_can_convert() is
  'Konvert ruxsati: admin OR kassa sahifasi OR konvert sahifasi (2026-10-03) OR can_convert.';

-- 2) «Konvert ustama» xarajat moddasi (idempotent, 94xx avtokod — Konvert kurs farqi bilan bir xil naqsh)
do $do$
declare v_id uuid; v_next int;
begin
  select id into v_id from accounts where name = 'Konvert ustama' and type = 'xarajat' limit 1;
  if v_id is null then
    select coalesce(max(a.code::int), 9420) + 1 into v_next from accounts a where a.code ~ '^94[0-9]+$';
    insert into accounts(code, name, type, section, is_active)
    values (v_next::text, 'Konvert ustama', 'xarajat', 'operatsion', true) returning id into v_id;
    raise notice 'Konvert ustama moddasi OCHILDI: kod % (id=%)', v_next, v_id;
  else
    raise notice 'Konvert ustama moddasi bor (id=%)', v_id;
  end if;
end
$do$;

create or replace function conv_ustama_hisob_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $fn$
  select id from accounts where name = 'Konvert ustama' and type = 'xarajat' and is_active order by created_at asc limit 1;
$fn$;
revoke all on function conv_ustama_hisob_id() from public, anon;

-- 3) VALYUTA → VALYUTA konvert
--   p_from, p_to     — ikkala hisob ham valyuta (currency <> 'UZS'), bir xil hisob emas
--   p_amount         — beriladigan miqdor (p_from valyutasida), p_to_amount — olinadigan miqdor (p_to valyutasida)
--   p_ustama         — ustama, p_from valyutasida (oddiy summa), p_ustama_foiz — ustama % (p_amount dan); ikkalasi ham bo'lishi mumkin
--   p_uzs            — so'm ekvivalenti (ixtiyoriy; bo'lmasa conv_baza_kurs(berilayotgan valyuta) × p_amount)
create or replace function convert_valyuta_v4(p_from uuid, p_to uuid, p_amount numeric, p_to_amount numeric,
                                              p_ustama numeric default null, p_ustama_foiz numeric default null,
                                              p_uzs numeric default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  f accounts%rowtype; t accounts%rowtype;
  v_who text; v_ruxsat boolean;
  v_fcur text; v_tcur text;
  v_uzs numeric; v_kurs numeric; v_cross numeric;
  v_ust_fc numeric := 0; v_ust_uzs numeric := 0;
  v_bal numeric; v_entry uuid; v_ust_entry uuid; v_modda uuid; v_req uuid;
  v_desc text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'Avtorizatsiya kerak'); end if;
  if to_regprocedure('public.perm_can_convert()') is not null then
    execute 'select perm_can_convert()' into v_ruxsat;
    if not coalesce(v_ruxsat, true) then return jsonb_build_object('ok', false, 'error', 'Konvert ruxsati yoq'); end if;
  end if;
  select coalesce(full_name, 'foydalanuvchi') into v_who from profiles where id = auth.uid();

  if p_amount is null or p_amount <= 0 then return jsonb_build_object('ok', false, 'error', 'Beriladigan summa notogri'); end if;
  if p_to_amount is null or p_to_amount <= 0 then return jsonb_build_object('ok', false, 'error', 'Olinadigan summa notogri'); end if;
  if p_from = p_to then return jsonb_build_object('ok', false, 'error', 'Bir hisobning ozida konvert bolmaydi'); end if;

  select * into f from accounts where id = p_from;
  select * into t from accounts where id = p_to;
  if f.id is null or t.id is null then return jsonb_build_object('ok', false, 'error', 'Hisob topilmadi'); end if;
  if not f.is_active or not t.is_active then return jsonb_build_object('ok', false, 'error', 'Hisob faol emas'); end if;
  v_fcur := coalesce(f.currency, 'UZS'); v_tcur := coalesce(t.currency, 'UZS');
  if v_fcur = 'UZS' or v_tcur = 'UZS' then
    return jsonb_build_object('ok', false, 'error', 'Bu funksiya faqat valyuta → valyuta uchun. Som bilan konvert — sotib olish/sotish.');
  end if;
  if f.kassa_turi = 'filial' or t.kassa_turi = 'filial' or f.kassa_turi = 'xarajat_guruh' or t.kassa_turi = 'xarajat_guruh' then
    return jsonb_build_object('ok', false, 'error', 'Bu hisobda konvert qilib bolmaydi');
  end if;

  -- ustama
  if p_ustama is not null and p_ustama < 0 then return jsonb_build_object('ok', false, 'error', 'Ustama manfiy bolmaydi'); end if;
  if p_ustama_foiz is not null and (p_ustama_foiz < 0 or p_ustama_foiz > 50) then
    return jsonb_build_object('ok', false, 'error', 'Ustama foizi 0..50 oraligida bolsin');
  end if;
  v_ust_fc := coalesce(p_ustama, 0) + case when coalesce(p_ustama_foiz, 0) > 0 then round(p_amount * p_ustama_foiz / 100, 2) else 0 end;

  -- so'm baholash
  if p_uzs is not null and p_uzs > 0 then
    v_uzs := round(p_uzs, 0);
    v_kurs := round(p_uzs / p_amount, 4);
  else
    v_kurs := conv_baza_kurs(v_fcur);
    if v_kurs is null then
      return jsonb_build_object('ok', false, 'error', v_fcur || ' uchun kurs tarixi yoq — som ekvivalentini (p_uzs) kiriting');
    end if;
    v_uzs := round(p_amount * v_kurs, 0);
  end if;
  v_ust_uzs := round(v_ust_fc * v_kurs, 0);
  v_cross := round(p_to_amount / p_amount, 6);   -- 1 birlik berilayotgan valyuta = necha birlik olinayotgan

  -- balans: beruvchi valyuta hisobida miqdor + ustama bo'lishi kerak
  v_bal := acc_fc_balance(p_from);
  if v_bal < p_amount + v_ust_fc then
    return jsonb_build_object('ok', false, 'error', 'Kassada yetarli ' || v_fcur || ' yoq', 'qoldiq', v_bal, 'kerak', p_amount + v_ust_fc);
  end if;

  -- 1-yozuv: konvert (ikkala satr bir xil so'm qiymatda, fc o'z valyutasida)
  v_desc := 'Konvert: ' || f.name || ' -> ' || t.name
            || ' · ' || trim(to_char(p_amount, 'FM999999999990.00')) || ' ' || v_fcur
            || ' → ' || trim(to_char(p_to_amount, 'FM999999999990.00')) || ' ' || v_tcur
            || ' · kurs ' || trim(to_char(v_cross, 'FM999999990.000000'))
            || coalesce(' · ' || nullif(btrim(p_note), ''), '');
  insert into entry(entry_date, description, source, status, fc_rate, ext_ref, created_by)
  values (current_date, v_desc, 'manual', 'posted', v_cross, 'convxy:' || gen_random_uuid()::text, v_who)
  returning id into v_entry;
  insert into entry_line(entry_id, account_id, debit, credit, fc_amount) values (v_entry, p_to,   v_uzs, 0, p_to_amount);
  insert into entry_line(entry_id, account_id, debit, credit, fc_amount) values (v_entry, p_from, 0, v_uzs, p_amount);

  -- 2-yozuv: ustama — xarajat (Dt Konvert ustama / Kt beruvchi valyuta hisobi)
  if v_ust_fc > 0 then
    v_modda := conv_ustama_hisob_id();
    if v_modda is null then raise exception '"Konvert ustama" moddasi topilmadi — PROVODKA_KONVERT_V4.sql 2-band RUN qilinsin.'; end if;
    insert into entry(entry_date, description, source, status, fc_rate, ext_ref, created_by)
    values (current_date,
            'Konvert ustama: ' || trim(to_char(v_ust_fc, 'FM999999999990.00')) || ' ' || v_fcur
              || case when coalesce(p_ustama_foiz, 0) > 0 then ' (' || trim(to_char(p_ustama_foiz, 'FM990.99')) || '%)' else '' end
              || ' · ' || f.name || ' -> ' || t.name,
            'manual', 'posted', v_kurs, 'convust:' || v_entry::text, v_who)
    returning id into v_ust_entry;
    insert into entry_line(entry_id, account_id, debit, credit, fc_amount) values (v_ust_entry, v_modda, v_ust_uzs, 0, null);
    insert into entry_line(entry_id, account_id, debit, credit, fc_amount) values (v_ust_entry, p_from, 0, v_ust_uzs, v_ust_fc);
  end if;

  -- tarix uchun convert_request (konvert sahifasidagi ro'yxatda ko'rinsin)
  insert into convert_request(from_account, to_account, amount, rate, fc_amount, aros_rate, status, note,
                              requested_by_name, decided_by_name, decided_at, entry_id, farq)
  values (p_from, p_to, v_uzs, v_cross, p_amount, null, 'done',
          coalesce(nullif(btrim(p_note), ''), '') || ' [valyuta→valyuta ' || v_fcur || '→' || v_tcur
            || case when v_ust_fc > 0 then ', ustama ' || trim(to_char(v_ust_fc, 'FM999999999990.00')) || ' ' || v_fcur else '' end || ']',
          v_who, v_who, now(), v_entry, case when v_ust_uzs > 0 then v_ust_uzs else null end)
  returning id into v_req;

  return jsonb_build_object('ok', true, 'status', 'done', 'entry_id', v_entry, 'ustama_entry_id', v_ust_entry,
    'request_id', v_req, 'from_cur', v_fcur, 'to_cur', v_tcur, 'amount', p_amount, 'to_amount', p_to_amount,
    'cross_rate', v_cross, 'uzs', v_uzs, 'kurs_uzs', v_kurs, 'ustama_fc', v_ust_fc, 'ustama_uzs', v_ust_uzs);
end
$fn$;
revoke all on function convert_valyuta_v4(uuid, uuid, numeric, numeric, numeric, numeric, numeric, text) from public, anon;
grant execute on function convert_valyuta_v4(uuid, uuid, numeric, numeric, numeric, numeric, numeric, text) to authenticated;
comment on function convert_valyuta_v4(uuid, uuid, numeric, numeric, numeric, numeric, numeric, text) is
  'Valyuta → valyuta konvert (USD→CNY va h.k.), ustama alohida xarajat yozuvi (Konvert ustama). convert_start_v3 tegilmagan.';

-- 4) konvert sahifasi uchun valyuta hisoblari ro'yxati (ruxsat doirasida ko'rinadi — RLS/perm_op_key klientda)
create or replace view v_konvert_valyuta_hisoblar as
  select a.id, a.code, a.name, a.currency, a.parent_id, kassa_root(a.id) as root_id,
         r.name as kassa_nomi, a.kassa_turi
    from accounts a
    left join accounts r on r.id = kassa_root(a.id)
   where a.is_active and coalesce(a.currency, 'UZS') <> 'UZS'
     and coalesce(a.kassa_turi, '') not in ('filial', 'xarajat_guruh');
grant select on v_konvert_valyuta_hisoblar to authenticated;

notify pgrst, 'reload schema';

-- tekshiruv
select code, name from accounts where name in ('Konvert ustama', 'Konvert kurs farqi') order by code;
select kassa_nomi, name, currency from v_konvert_valyuta_hisoblar order by kassa_nomi, currency;
