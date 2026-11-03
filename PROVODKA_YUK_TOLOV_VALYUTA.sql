-- ============================================================================
--  PROVODKA_YUK_TOLOV_VALYUTA.sql — 2026-11-03 — YUK TO'LOVI VALYUTADA SAQLANADI
--
--  Muammo (Asilbek, 03.11): 130-Do'kon #2969 441 USD — 14.10 da 11 850 kursda 5 225 850 so'm
--  TO'LIQ to'langan. Sahifa qoldiqni «narx × BUGUNGI kurs (12 000) − to'langan so'm» deb
--  hisoblaydi → $5.51 «qisman 99%» soxta qarz chiqadi. Qoida: to'lov paytida valyutada
--  to'liq to'langan hujjat keyin kurs o'zgargani uchun QAYTA OCHILMAYDI.
--
--  Yechim (additive, pul harakati YO'Q, entry/entry_line tegilmaydi):
--   1) entry_yuk ga 3 ustun: summa_fc (yuk valyutasidagi to'lov), kurs (to'lov kuni), valyuta.
--   2) _yuk_kurs_sanada(cur, sana) — currency_rate dan shu sanadagi (yoki oldingi) kurs.
--   3) yuk_tolangan_fc(p_rows) — yuk_tolangan_summa bilan bir xil + tolangan_fc (yuk valyutasida):
--        UZS yuk → so'm; summa_fc bor → summa_fc; kurs bor → summa_uzs/kurs;
--        eski qatorlar → summa_uzs / to'lov kunidagi kurs (currency_rate). Kurs topilmasa null
--        (klient eski so'm formulasiga tushadi). yuk_yopiq (pulsiz yopiq) — created_at kuni kursi.
--   4) entry_yuk_valyuta_yoz(p_ext_ref, p_rows) — Professional saqlashdan KEYIN fonda
--        summa_fc/kurs/valyuta yozadi (entry_yuk_sabab_yoz naqshi: egalik, 30 daqiqa, bir marta).
--  yuk_tolangan_summa O'ZGARMAYDI (5 kunlik/jurnal/yuklar avvalgidek). Asilbek RUN qiladi. Takror RUN xavfsiz.
-- ============================================================================

-- ---------------------------------------------------------------- 1) ustunlar
alter table entry_yuk add column if not exists summa_fc numeric;
alter table entry_yuk add column if not exists kurs     numeric;
alter table entry_yuk add column if not exists valyuta  text;
comment on column entry_yuk.summa_fc is 'To''lov YUK valyutasida (to''lov paytidagi miqdor) — qoldiq shundan, kursga qaytmaydi. ENG OXIRGI: PROVODKA_YUK_TOLOV_VALYUTA.sql';
comment on column entry_yuk.kurs     is 'To''lov kunida ishlatilgan kurs (1 birlik = so''m).';
comment on column entry_yuk.valyuta  is 'summa_fc valyutasi (Aros yuk valyutasi, masalan USD/CHY/AED).';

-- ---------------------------------------------------------------- 2) kurs sanada
-- CHY (Aros kodi) va CNY — bitta yuan (yuk_kurslar bilan bir xil).
create or replace function _yuk_val_norm(p_cur text)
returns text
language sql
immutable
as $fn$
  select case upper(coalesce(nullif(btrim(p_cur), ''), 'UZS')) when 'CHY' then 'CNY' else upper(coalesce(nullif(btrim(p_cur), ''), 'UZS')) end;
$fn$;

create or replace function _yuk_kurs_sanada(p_cur text, p_sana date)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v    numeric;
  v_n  text := _yuk_val_norm(p_cur);
begin
  if v_n = 'UZS' then return 1; end if;
  if p_sana is null then return conv_baza_kurs(p_cur); end if;

  select rate into v from currency_rate
   where _yuk_val_norm(from_code) = v_n and upper(to_code) = 'UZS' and rate > 0
     and rate_at::date <= p_sana
   order by rate_at desc, created_at desc limit 1;
  if v is not null then return v; end if;

  select 1 / rate into v from currency_rate
   where upper(from_code) = 'UZS' and _yuk_val_norm(to_code) = v_n and rate > 0
     and rate_at::date <= p_sana
   order by rate_at desc, created_at desc limit 1;
  if v is not null then return v; end if;

  -- sanadan oldin kurs yo'q — birinchi mavjud kurs (eng yaqini), bo'lmasa bugungi baza kursi
  select rate into v from currency_rate
   where _yuk_val_norm(from_code) = v_n and upper(to_code) = 'UZS' and rate > 0
   order by rate_at asc, created_at asc limit 1;
  if v is not null then return v; end if;

  return conv_baza_kurs(p_cur);
end
$fn$;
revoke all on function _yuk_kurs_sanada(text, date) from public, anon;
grant execute on function _yuk_kurs_sanada(text, date) to authenticated;

-- ---------------------------------------------------------------- 3) yuk_tolangan_fc
-- p_rows: [{id, valyuta}] — valyuta Aros yuk valyutasi (klient biladi, bazada yuk jadvali yo'q).
create or replace function yuk_tolangan_fc(p_rows jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  with r as (
    select distinct (x ->> 'id')::integer as yuk_id,
           _yuk_val_norm(x ->> 'valyuta') as val
      from jsonb_array_elements(case when jsonb_typeof(p_rows) = 'array' then p_rows else '[]'::jsonb end) x
     where (x ->> 'id') ~ '^[0-9]+$'
  ),
  u as (
    select ey.yuk_id, e.id as entry_id, e.entry_date, ey.summa_uzs, false as yopiq, null::text as sabab,
           ey.summa_fc, ey.kurs, _yuk_val_norm(ey.valyuta) as ey_val
      from entry_yuk ey
      join entry e on e.id = ey.entry_id
     where e.status = 'posted' and e.is_deleted = false
       and ey.yuk_id in (select yuk_id from r)
    union all
    select yq.yuk_id, null::uuid, yq.created_at::date, yq.summa_uzs, true, yq.sabab,
           null::numeric, null::numeric, null::text
      from yuk_yopiq yq
     where not yq.is_deleted and yq.yuk_id in (select yuk_id from r)
  ),
  c as (
    select u.*, r.val,
           case
             when r.val = 'UZS' then u.summa_uzs
             when u.summa_fc is not null and u.ey_val = r.val then u.summa_fc
             when u.kurs is not null and u.kurs > 0 and u.ey_val = r.val then u.summa_uzs / u.kurs
             else u.summa_uzs / nullif(_yuk_kurs_sanada(r.val, u.entry_date), 0)
           end as fc
      from u join r on r.yuk_id = u.yuk_id
  ),
  g as (
    select c.yuk_id, c.val,
           sum(c.summa_uzs)::numeric as tot,
           case when bool_and(c.fc is not null) then round(sum(c.fc)::numeric, 4) end as tot_fc,
           jsonb_agg(jsonb_build_object(
             'entry_id',   c.entry_id,
             'entry_date', c.entry_date,
             'summa_uzs',  c.summa_uzs,
             'summa_fc',   case when c.fc is null then null else round(c.fc::numeric, 4) end,
             'yopiq',      c.yopiq,
             'sabab',      c.sabab) order by c.entry_date) as entrylar
      from c
     group by c.yuk_id, c.val
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'yuk_id',       g.yuk_id,
           'valyuta',      g.val,
           'tolangan_uzs', g.tot,
           'tolangan_fc',  g.tot_fc,
           'entrylar',     g.entrylar) order by g.yuk_id), '[]'::jsonb)
    from g;
$fn$;
revoke all on function yuk_tolangan_fc(jsonb) from public, anon;
grant execute on function yuk_tolangan_fc(jsonb) to authenticated;
comment on function yuk_tolangan_fc(jsonb) is
  'yuk_tolangan_summa + tolangan_fc (yuk valyutasida, to''lov paytidagi miqdor/kurs). '
  'p_rows [{id, valyuta}]. Qoldiq = narx − tolangan_fc → kurs o''zgarsa yopiq hujjat qayta ochilmaydi. '
  'ENG OXIRGI: PROVODKA_YUK_TOLOV_VALYUTA.sql';

-- ---------------------------------------------------------------- 4) entry_yuk_valyuta_yoz
-- p_rows: [{yuk_id, summa_fc, kurs, valyuta}] — faqat summa_fc hali null qatorlarga (bir marta).
create or replace function entry_yuk_valyuta_yoz(p_ext_ref text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid            uuid := auth.uid();
  v_ext            text := nullif(btrim(coalesce(p_ext_ref, '')), '');
  v_id             uuid;
  v_created_at     timestamptz;
  v_created_by_raw text;
  v_owner          uuid;
  v_n              integer := 0;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if v_ext is null then
    return jsonb_build_object('ok', false, 'kod', 'ext_ref_kerak');
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('ok', false, 'kod', 'qator_yoq');
  end if;

  select e.id, e.created_at, (to_jsonb(e) ->> 'created_by')
    into v_id, v_created_at, v_created_by_raw
    from entry e
   where e.ext_ref = v_ext
   limit 1;
  if v_id is null then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi');
  end if;
  v_owner := case when v_created_by_raw ~ '^[0-9a-fA-F-]{36}$' then v_created_by_raw::uuid end;
  if v_owner is distinct from v_uid and not is_admin() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat_yoq');
  end if;
  if v_created_at is null or v_created_at < now() - interval '30 minutes' then
    return jsonb_build_object('ok', false, 'kod', 'muddat_tugagan');
  end if;

  update entry_yuk ey
     set summa_fc = x.fc,
         kurs     = x.kurs,
         valyuta  = x.val
    from (
      select (r ->> 'yuk_id')::integer                    as yuk_id,
             nullif(r ->> 'summa_fc', '')::numeric        as fc,
             nullif(r ->> 'kurs', '')::numeric            as kurs,
             _yuk_val_norm(r ->> 'valyuta')               as val
        from jsonb_array_elements(p_rows) r
       where (r ->> 'yuk_id') ~ '^[0-9]+$'
    ) x
   where ey.entry_id = v_id and ey.yuk_id = x.yuk_id
     and ey.summa_fc is null
     and x.fc is not null and x.fc > 0;
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'yozildi', v_n);
end
$fn$;
revoke all on function entry_yuk_valyuta_yoz(text, jsonb) from public, anon;
grant execute on function entry_yuk_valyuta_yoz(text, jsonb) to authenticated;
comment on function entry_yuk_valyuta_yoz(text, jsonb) is
  'Professional yuk to''lovi saqlangach fonda entry_yuk.summa_fc/kurs/valyuta yozadi '
  '(egalik created_by=auth.uid() yoki admin, 30 daqiqa, summa_fc null bo''lgan qatorlargagina).';

-- Tekshirish (130-Do'kon #2969 441 USD, 14.10 da 5 225 850 so'm):
-- select yuk_tolangan_fc('[{"id":2969,"valyuta":"USD"},{"id":2892,"valyuta":"USD"},{"id":2844,"valyuta":"USD"}]'::jsonb);
-- kutilgan: tolangan_fc ≈ 437–441 (currency_rate dagi o'sha kun kursi bo'yicha); yangi to'lovlarda aynan 441.
