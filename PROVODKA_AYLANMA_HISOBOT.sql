-- ============================================================================
--  PROVODKA_AYLANMA_HISOBOT.sql — 2026-10-03 — Aylanma sahifasi: KUNLIK HISOBOT (Jami · Bo'lishi kerak · Raznitsa · Foyda · Xarajat)
--  Asilbek: «aylanma kapitalda diagramma tagidan shunaqa report qilishimiz kerak: foyda hisobotini ham olamiz
--  (total; bosganda qaysi filial qancha), xarajatlarda esa faqat ASOSIY kassadan chiqqan pullar».
--  Manbalar:
--    • Jami — aylanma_snapshot (kunning cron qatori, bo'lmasa oxirgi qolda) — mavjud.
--    • Foyda — Metabase «Profit report — filiallar bo'yicha» ($), YANGI jadval aylanma_foyda (filial + JAMI qatorlari).
--      Brauzerdan Metabase chaqirib bo'lmaydi (CORS yo'q) → ma'lumot n8n (sync_aylanma_foyda, service_role) orqali
--      kuniga bir yoziladi; tarix PROVODKA_AYLANMA_FOYDA_DATA.sql bilan to'ldiriladi. So'mga snapshot kursi bilan o'tkaziladi.
--    • Xarajat — entry: Kt tomoni ASOSIY kassa (accounts.asosiy yoki ota-hisobi asosiy — valyuta/pul turi bolalari
--      otaga ergashadi), Dt tomoni type='xarajat' modda; posted, o'chirilmagan; summa = Dt xarajat satrlari (so'm).
--      Transfer/konvert/qarz chiqimlari XARAJAT EMAS — kirmaydi.
--  Formula (kun D = snapshot kuni, 08:00 holati ≈ D−1 kun oxiri):
--    bo'lishi_kerak(D) = jami(D−1 snapshot) + foyda(D−1) − xarajat(D−1);  raznitsa = jami(D) − bo'lishi_kerak.
--    Hisobotda qator «kun» = D−1 (biznes kuni), «jami» = ertasi ertalabki snapshot. Oldingi snapshot yo'q bo'lsa qator chiqmaydi.
--  Ruxsat: aylanma_page_ok(). Pul harakati YO'Q. Additive. Asilbek RUN qiladi.
-- ============================================================================

-- 1) kunlik foyda jadvali
create table if not exists aylanma_foyda (
  sana        date    not null,
  filial      text    not null,                 -- Metabase «Filial» nomi; 'JAMI' — jami qatori
  sotilgan    int,
  qaytarilgan int,
  kirim_usd   numeric,
  sotuv_usd   numeric,
  keshbek_usd numeric,
  foyda_usd   numeric not null default 0,
  manba       text    not null default 'metabase',
  updated_at  timestamptz not null default now(),
  primary key (sana, filial)
);
create index if not exists idx_aylanma_foyda_sana on aylanma_foyda (sana);
comment on table aylanma_foyda is
  'Metabase «Profit report — filiallar bo''yicha» kunlik nusxasi ($). filial=''JAMI'' — kun jami. '
  'Yozish: sync_aylanma_foyda (service_role, n8n) yoki PROVODKA_AYLANMA_FOYDA_DATA.sql. O''qish: aylanma_hisobot*.';
alter table aylanma_foyda enable row level security;
drop policy if exists aylanma_foyda_sel on aylanma_foyda;
create policy aylanma_foyda_sel on aylanma_foyda for select to authenticated using (aylanma_page_ok());

-- 2) n8n uchun upsert: p_data = {"rows":[{"sana":"2026-10-02","filial":"Malika","sotilgan":243,"qaytarilgan":31,
--    "kirim_usd":..,"sotuv_usd":..,"keshbek_usd":..,"foyda_usd":..}, ...]}  (JAMI qatori ham yuboriladi)
create or replace function sync_aylanma_foyda(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_n int := 0;
begin
  if auth.role() is distinct from 'service_role' and auth.uid() is not null and not is_admin() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Faqat service_role/admin');
  end if;
  insert into aylanma_foyda (sana, filial, sotilgan, qaytarilgan, kirim_usd, sotuv_usd, keshbek_usd, foyda_usd, manba, updated_at)
  select (r->>'sana')::date, r->>'filial', nullif(r->>'sotilgan','')::int, nullif(r->>'qaytarilgan','')::int,
         nullif(r->>'kirim_usd','')::numeric, nullif(r->>'sotuv_usd','')::numeric, nullif(r->>'keshbek_usd','')::numeric,
         coalesce(nullif(r->>'foyda_usd','')::numeric, 0), coalesce(r->>'manba', 'metabase'), now()
    from jsonb_array_elements(coalesce(p_data->'rows', '[]'::jsonb)) r
   where r->>'sana' is not null and nullif(btrim(r->>'filial'), '') is not null
  on conflict (sana, filial) do update set
    sotilgan = excluded.sotilgan, qaytarilgan = excluded.qaytarilgan, kirim_usd = excluded.kirim_usd,
    sotuv_usd = excluded.sotuv_usd, keshbek_usd = excluded.keshbek_usd, foyda_usd = excluded.foyda_usd,
    manba = excluded.manba, updated_at = now();
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'yozildi', v_n);
end
$fn$;
revoke all on function sync_aylanma_foyda(jsonb) from public, anon, authenticated;
grant execute on function sync_aylanma_foyda(jsonb) to service_role;

-- 3) asosiy kassa hisoblari (ota + bolalar) — yordamchi
create or replace function aylanma_asosiy_hisoblar()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $fn$
  with recursive r as (
    select id from accounts where coalesce(asosiy, false)
    union
    select a.id from accounts a join r on a.parent_id = r.id
  )
  select coalesce(array_agg(id), '{}'::uuid[]) from r;
$fn$;
revoke all on function aylanma_asosiy_hisoblar() from public, anon;
grant execute on function aylanma_asosiy_hisoblar() to authenticated;

-- 4) bir kun xarajati: asosiy kassadan chiqqan, Dt = xarajat moddasi (so'm)
create or replace function aylanma_kun_xarajat(p_sana date)
returns numeric
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(sum(dt.debit), 0)
    from entry e
    join entry_line dt on dt.entry_id = e.id and dt.debit > 0
    join accounts ma on ma.id = dt.account_id and ma.type = 'xarajat'
   where e.entry_date = p_sana and e.status = 'posted' and e.is_deleted = false
     and exists (select 1 from entry_line kt
                  where kt.entry_id = e.id and kt.credit > 0
                    and kt.account_id = any(aylanma_asosiy_hisoblar()));
$fn$;
revoke all on function aylanma_kun_xarajat(date) from public, anon;
grant execute on function aylanma_kun_xarajat(date) to authenticated;

-- 5) HISOBOT: kunlar bo'yicha qatorlar (kun = biznes kuni)
create or replace function aylanma_hisobot(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_rows jsonb;
begin
  if not aylanma_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then
    return jsonb_build_object('ok', false, 'error', 'p_from/p_to notogri (max 400 kun)');
  end if;
  with snap as (   -- kun uchun BITTA snapshot: cron ustun, bo'lmasa oxirgi qolda (aylanma_kun bilan bir xil)
    select distinct on (sana) sana, rejim, hisoblangan_at, kurs_usd, jami_uzs, jami_usd, toliq
      from aylanma_snapshot
     where sana between p_from and p_to + 1
     order by sana, (rejim = 'cron') desc, hisoblangan_at desc
  ),
  kunlar as (
    select d::date as kun from generate_series(p_from, p_to, interval '1 day') d
  ),
  foyda as (
    select sana, max(foyda_usd) filter (where filial = 'JAMI') as jami_usd,
           count(*) filter (where filial <> 'JAMI') as filial_soni
      from aylanma_foyda where sana between p_from and p_to group by sana
  ),
  q as (
    select k.kun,
           s1.jami_uzs  as jami_oldin,            -- kun ertalabki snapshot (= oldingi kun oxiri)
           s2.jami_uzs  as jami,                  -- ertasi ertalabki snapshot (= shu kun oxiri)
           s2.rejim, s2.hisoblangan_at, s2.toliq,
           coalesce(s2.kurs_usd, s1.kurs_usd) as kurs,
           f.jami_usd as foyda_usd, f.filial_soni,
           case when f.jami_usd is not null and coalesce(s2.kurs_usd, s1.kurs_usd) is not null
                then round(f.jami_usd * coalesce(s2.kurs_usd, s1.kurs_usd), 0) end as foyda_uzs,
           aylanma_kun_xarajat(k.kun) as xarajat_uzs
      from kunlar k
      left join snap s1 on s1.sana = k.kun
      left join snap s2 on s2.sana = k.kun + 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'kun', kun, 'jami_oldin', jami_oldin, 'jami', jami, 'rejim', rejim, 'hisoblangan_at', hisoblangan_at,
           'toliq', toliq, 'kurs', kurs, 'foyda_usd', foyda_usd, 'foyda_uzs', foyda_uzs, 'filial_soni', filial_soni,
           'xarajat_uzs', xarajat_uzs,
           'kerak', case when jami_oldin is not null and foyda_uzs is not null then jami_oldin + foyda_uzs - xarajat_uzs end,
           'raznitsa', case when jami is not null and jami_oldin is not null and foyda_uzs is not null
                            then jami - (jami_oldin + foyda_uzs - xarajat_uzs) end
         ) order by kun desc), '[]'::jsonb)
    into v_rows
    from q;
  return jsonb_build_object('ok', true, 'rows', v_rows, 'p_from', p_from, 'p_to', p_to);
end
$fn$;
revoke all on function aylanma_hisobot(date, date) from public, anon;
grant execute on function aylanma_hisobot(date, date) to authenticated;

-- 6) TAFSILOT: bir kun — foyda filial bo'yicha + xarajat modda/kassa bo'yicha
create or replace function aylanma_hisobot_tafsilot(p_sana date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_kurs numeric;
  v_foyda jsonb; v_xarajat jsonb;
begin
  if not aylanma_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  select kurs_usd into v_kurs from aylanma_snapshot
   where sana in (p_sana + 1, p_sana) and kurs_usd is not null
   order by (sana = p_sana + 1) desc, (rejim = 'cron') desc, hisoblangan_at desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object(
           'filial', filial, 'sotilgan', sotilgan, 'qaytarilgan', qaytarilgan, 'kirim_usd', kirim_usd,
           'sotuv_usd', sotuv_usd, 'keshbek_usd', keshbek_usd, 'foyda_usd', foyda_usd,
           'foyda_uzs', case when v_kurs is not null then round(foyda_usd * v_kurs, 0) end
         ) order by (filial = 'JAMI'), foyda_usd desc), '[]'::jsonb)
    into v_foyda
    from aylanma_foyda where sana = p_sana;
  select coalesce(jsonb_agg(jsonb_build_object(
           'modda', modda, 'kassa', kassa, 'summa', summa, 'soni', soni
         ) order by summa desc), '[]'::jsonb)
    into v_xarajat
    from (
      select ma.name as modda, ka.name as kassa, sum(dt.debit) as summa, count(distinct e.id) as soni
        from entry e
        join entry_line dt on dt.entry_id = e.id and dt.debit > 0
        join accounts ma on ma.id = dt.account_id and ma.type = 'xarajat'
        join lateral (select kt.account_id from entry_line kt
                       where kt.entry_id = e.id and kt.credit > 0
                         and kt.account_id = any(aylanma_asosiy_hisoblar()) limit 1) k on true
        join accounts ka on ka.id = k.account_id
       where e.entry_date = p_sana and e.status = 'posted' and e.is_deleted = false
       group by ma.name, ka.name
    ) x;
  return jsonb_build_object('ok', true, 'sana', p_sana, 'kurs', v_kurs, 'foyda', v_foyda, 'xarajat', v_xarajat,
                            'xarajat_jami', aylanma_kun_xarajat(p_sana));
end
$fn$;
revoke all on function aylanma_hisobot_tafsilot(date) from public, anon;
grant execute on function aylanma_hisobot_tafsilot(date) to authenticated;

notify pgrst, 'reload schema';

-- tekshiruv
select count(*) as asosiy_hisoblar from unnest(aylanma_asosiy_hisoblar());
select * from jsonb_to_recordset((aylanma_hisobot(current_date - 7, current_date))->'rows')
  as t(kun date, jami_oldin numeric, jami numeric, foyda_usd numeric, foyda_uzs numeric, xarajat_uzs numeric, kerak numeric, raznitsa numeric)
 order by kun desc;
