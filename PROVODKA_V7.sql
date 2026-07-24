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


-- #####################################################################
-- ##  1-BOSQICH — "Tovar tannarxi (yo'ldagi)" (kod 9110-1)           ##
-- #####################################################################
-- Naqdga tovar olinganda hujjat (Aros product-income) keyin keladi.
-- Shu holat: Dt 9110-1 (yo'ldagi) / Kt kassa, entry.yuk_kutilmoqda=true.
-- Hujjat kelgach yuk_boglash() Dt hisobini 9110-1 -> 9110 ga almashtiradi.
--
-- Kod matn: accounts.code TEXT -- '9110-1' muammosiz. (Agar raqam bo'lganda:
-- alternativa '9111' yoki 'section' bilan ajratish bo'lardi; lekin TEXT.)

-- 1.1 entry.yuk_kutilmoqda ustuni + qisman indeks
alter table entry add column if not exists yuk_kutilmoqda boolean not null default false;
create index if not exists entry_yuk_kutil_idx on entry(yuk_kutilmoqda) where yuk_kutilmoqda;
comment on column entry.yuk_kutilmoqda is
  'Yo''ldagi tovar: hujjat (Aros yuk) hali kelmadi. yuk_boglash() bog''lagach false bo''ladi.';

-- 1.2 9110-1 hisobi — idempotent, atributlar 9110'dan ko'chiriladi (type/section izchil)
do $$
declare v_type text; v_section text;
begin
  if not exists (select 1 from accounts where code = '9110-1') then
    select type, section into v_type, v_section from accounts where code = '9110' limit 1;
    insert into accounts (code, name, type, section, is_active)
    values ('9110-1', 'Tovar tannarxi (yo''ldagi)',
            coalesce(v_type, 'xarajat'), coalesce(v_section, 'operatsion'), true);
    raise notice '1-BOSQICH: 9110-1 hisobi yaratildi.';
  else
    raise notice '1-BOSQICH: 9110-1 allaqachon bor — o''tkazildi.';
  end if;
end $$;

-- 1.3 yuk_boglash(p_entry, p_yuk_id, p_summa) — yo'ldagi to'lovni Aros yukiga bog'lash
-- ---------------------------------------------------------------------
-- Server tekshiradi: entry bor + o'chirilmagan + yuk_kutilmoqda=true, 9110-1 satri
-- bor, summa musbat va <= yozuv summasi. (Yukning qolgan qarzi UZS'da n8n/Aros
-- narxidan hisoblanadi — narx DB'da yo'q; shuning uchun "qolgan qarz" cheklovi
-- UI tomonda majburlanadi, bu yerda faqat yozuv summasi cheklovi.)
-- entry_yuk ga qator; Dt 9110-1 -> 9110; yuk_kutilmoqda=false; yuk_ids ga qo'shiladi;
-- tahrir izi (edited_at/by + entry_history).
create or replace function yuk_boglash(p_entry uuid, p_yuk_id integer, p_summa numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted   boolean;
  v_kutil     boolean;
  v_entry_sum numeric;
  v_9110      uuid;
  v_9110_1    uuid;
  v_line_id   uuid;
  v_name      text;
  v_snap      jsonb;
begin
  if p_yuk_id is null then raise exception 'Yuk tanlanmadi' using errcode = '22000'; end if;
  if p_summa is null or p_summa <= 0 then
    raise exception 'Summa musbat bo''lishi kerak' using errcode = '22000';
  end if;

  -- 1) entry holati
  select is_deleted, coalesce(yuk_kutilmoqda, false)
    into v_deleted, v_kutil
    from entry where id = p_entry;
  if not found then raise exception 'Yozuv topilmadi' using errcode = '22000'; end if;
  if v_deleted then raise exception 'O''chirilgan yozuvni bog''lab bo''lmaydi' using errcode = '22000'; end if;
  if not v_kutil then
    raise exception 'Bu yozuv hujjat kutmayapti (allaqachon bog''langan yoki oddiy yozuv)'
      using errcode = '22000';
  end if;

  select id into v_9110_1 from accounts where code = '9110-1' limit 1;
  select id into v_9110   from accounts where code = '9110'   limit 1;
  if v_9110 is null then
    raise exception '9110 "Tovar tannarxi" hisobi topilmadi' using errcode = '22000';
  end if;

  -- yozuv summasi (Dt yig'indisi) va 9110-1 satri
  select coalesce(sum(debit), 0) into v_entry_sum from entry_line where entry_id = p_entry;
  if p_summa > v_entry_sum then
    raise exception 'Summa yozuv summasidan oshib ketdi (max % so''m)', v_entry_sum
      using errcode = '22000';
  end if;

  select id into v_line_id from entry_line
   where entry_id = p_entry and account_id = v_9110_1 and debit > 0
   limit 1;
  if v_line_id is null then
    raise exception 'Bu yozuvda "yo''ldagi tovar" (9110-1) satri yo''q' using errcode = '22000';
  end if;

  -- 2) tahrir izi uchun eski holat
  select to_jsonb(e) into v_snap from entry e where e.id = p_entry;
  select coalesce(full_name, '') into v_name from profiles where id = auth.uid();

  -- 3) entry_yuk (bir yukka takror bog'lansa summa qo'shiladi)
  insert into entry_yuk (entry_id, yuk_id, summa_uzs)
  values (p_entry, p_yuk_id, p_summa)
  on conflict (entry_id, yuk_id) do update
    set summa_uzs = entry_yuk.summa_uzs + excluded.summa_uzs;

  -- 4) Dt satrini 9110-1 -> 9110 (perm guard 9110 pul hisobi emas -> o'tadi)
  update entry_line set account_id = v_9110 where id = v_line_id;

  -- 5) yuk_kutilmoqda=false + yuk_ids ga qo'sh + tahrir izi
  update entry
     set yuk_kutilmoqda = false,
         yuk_ids = case when p_yuk_id = any(coalesce(yuk_ids, '{}'))
                        then yuk_ids else coalesce(yuk_ids, '{}') || p_yuk_id end,
         edited_at = now(),
         edited_by_name = v_name
   where id = p_entry;

  -- 6) entry_history (mavjud naqsh) — "Yukka bog'landi"
  insert into entry_history (entry_id, action, snapshot, changed_by_name)
  values (p_entry, 'edit',
          jsonb_build_object('note', 'Yukka bog''landi: #' || p_yuk_id,
                             'summa_uzs', p_summa, 'old', v_snap),
          v_name);

  return jsonb_build_object('ok', true, 'entry_id', p_entry,
                            'yuk_id', p_yuk_id, 'summa', p_summa);
end $$;

revoke all on function yuk_boglash(uuid, integer, numeric) from public, anon;
grant execute on function yuk_boglash(uuid, integer, numeric) to authenticated;

comment on function yuk_boglash(uuid, integer, numeric) is
  'Yo''ldagi to''lovni (9110-1, yuk_kutilmoqda) Aros yukiga bog''laydi: entry_yuk + Dt 9110-1->9110 + yuk_ids.';

-- 1.4 yuk_kutayotgan() — bog'lanmagan (yo'ldagi) to'lovlar ro'yxati
-- ---------------------------------------------------------------------
-- yuklar-dev.html "Bog'lanmagan to'lovlar" tabi + jurnal wait tegi uchun.
create or replace function yuk_kutayotgan()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb)
  from (
    select e.id as entry_id, e.entry_date, e.created_at, e.description as izoh,
           (select coalesce(sum(el.debit), 0) from entry_line el where el.entry_id = e.id) as summa,
           ka.id as kassa_id, ka.code as kassa_code, ka.name as kassa_name, ka.subtitle as kassa_subtitle,
           coalesce(pr.full_name, '') as kim
      from entry e
      left join lateral (
        select el.account_id from entry_line el
          join accounts a on a.id = el.account_id
         where el.entry_id = e.id and el.credit > 0 and a.section = 'pul'
         limit 1
      ) kl on true
      left join accounts ka on ka.id = kl.account_id
      left join profiles pr on pr.id = e.created_by
     where e.yuk_kutilmoqda = true and e.is_deleted = false and e.status = 'posted'
  ) r;
$$;

revoke all on function yuk_kutayotgan() from public, anon;
grant execute on function yuk_kutayotgan() to authenticated;

comment on function yuk_kutayotgan() is
  'Bog''lanmagan (yo''ldagi) to''lovlar: yuk_kutilmoqda=true entrylar (sana/summa/kassa/izoh/kim).';

notify pgrst, 'reload schema';

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='entry' and column_name='yuk_kutilmoqda') then
    raise exception '1-BOSQICH: entry.yuk_kutilmoqda ustuni yo''q';
  end if;
  if not exists (select 1 from accounts where code = '9110-1') then
    raise exception '1-BOSQICH: 9110-1 hisobi yo''q';
  end if;
  if to_regprocedure('public.yuk_boglash(uuid,integer,numeric)') is null then
    raise exception '1-BOSQICH: yuk_boglash yaratilmadi';
  end if;
  if to_regprocedure('public.yuk_kutayotgan()') is null then
    raise exception '1-BOSQICH: yuk_kutayotgan yaratilmadi';
  end if;
  raise notice '1-BOSQICH OK: yo''ldagi tovar (9110-1) DB tayyor.';
end $$;
