-- ============================================================================
--  PROVODKA_AYLANMA_HISOBOT_3.sql — 2026-10-08 — «Bo'lishi kerak» UZLUKSIZ (kumulyativ) hisob
--  Asilbek: «bo'lishi kerak doimiy o'sib/kamayib ketaveradi: bugun kerak 900, jami 850 → raznitsa 50; bugun foyda 50 →
--  ertaga kerak 950; jami 900 bo'lsa yana raznitsa 50». Eski mantiq har kuni HAQIQIY jamidan qayta boshlardi
--  (kerak = kechagi jami + foyda − xarajat) — kechagi farq ertaga «unutilardi».
--
--  YANGI: kerak(kun) = boshlang'ich kun boshidagi HAQIQIY jami + Σ(boshlanish..kun) (foyda_uzs − xarajat_uzs).
--  raznitsa(kun) = jami(kun) − kerak(kun) (yig'ilib boradi); kun_farq = raznitsa − kechagi raznitsa (shu kunning O'ZIDA
--  paydo bo'lgan farq). Boshlang'ich kun: provodka_config 'aylanma_hisobot_boshlanish' (admin qo'yadi), bo'lmasa foyda
--  (JAMI) va kun-boshi snapshot ikkalasi bor ENG BIRINCHI kun. Foyda yo'q kun → 0 deb olinadi, `foyda_yoq=true` belgisi.
--  Eski kunlik qiymat `kerak_kun` sifatida saqlanadi (ma'lumot). Imzo/kalitlar saqlangan, qo'shimcha kalitlar qo'shildi.
--  Asilbek RUN qiladi. 🔴 aylanma_hisobot ning ENG OXIRGI versiyasi SHU faylda (avval PROVODKA_AYLANMA_HISOBOT_FIX.sql).
-- ============================================================================

-- 1) Boshlang'ich kun
create or replace function aylanma_hisobot_boshlanish()
returns date
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(
    (select nullif(btrim(val), '')::date from provodka_config where key = 'aylanma_hisobot_boshlanish'),
    (select min(f.sana) from aylanma_foyda f
      where f.filial = 'JAMI' and f.foyda_usd is not null
        and exists (select 1 from aylanma_snapshot s where s.sana = f.sana and s.jami_uzs is not null))
  );
$fn$;
revoke all on function aylanma_hisobot_boshlanish() from public, anon;
grant execute on function aylanma_hisobot_boshlanish() to authenticated;

create or replace function aylanma_hisobot_boshlanish_set(p_sana date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not is_admin() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  if p_sana is null then
    delete from provodka_config where key = 'aylanma_hisobot_boshlanish';
  else
    if not exists (select 1 from aylanma_snapshot where sana = p_sana and jami_uzs is not null) then
      return jsonb_build_object('ok', false, 'kod', 'snapshot_yoq', 'error', 'Bu kun uchun kun-boshi snapshot yoq');
    end if;
    insert into provodka_config(key, val, updated_by, updated_at)
    values ('aylanma_hisobot_boshlanish', p_sana::text, auth.uid()::text, now())
    on conflict (key) do update set val = excluded.val, updated_by = excluded.updated_by, updated_at = now();
  end if;
  return jsonb_build_object('ok', true, 'boshlanish', aylanma_hisobot_boshlanish());
end
$fn$;
revoke all on function aylanma_hisobot_boshlanish_set(date) from public, anon;
grant execute on function aylanma_hisobot_boshlanish_set(date) to authenticated;

-- 2) Hisobot — kumulyativ
create or replace function aylanma_hisobot(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_rows  jsonb;
  v_bosh  date;
  v_bosh_jami numeric;
begin
  if not aylanma_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then
    return jsonb_build_object('ok', false, 'error', 'p_from/p_to notogri (max 400 kun)');
  end if;
  v_bosh := aylanma_hisobot_boshlanish();
  if v_bosh is not null then
    select s.jami_uzs into v_bosh_jami from aylanma_snapshot s
     where s.sana = v_bosh and s.jami_uzs is not null
     order by (s.rejim = 'cron') desc, s.hisoblangan_at desc limit 1;
  end if;

  with snap as (
    select distinct on (sana) sana, rejim, hisoblangan_at, kurs_usd, jami_uzs, jami_usd, toliq
      from aylanma_snapshot
     where sana between least(coalesce(v_bosh, p_from), p_from) and p_to + 1
     order by sana, (rejim = 'cron') desc, hisoblangan_at desc
  ),
  kunlar as (
    select d::date as kun from generate_series(least(coalesce(v_bosh, p_from), p_from), p_to, interval '1 day') d
  ),
  foyda as (
    select sana, max(foyda_usd) filter (where filial = 'JAMI') as jami_usd,
           count(*) filter (where filial <> 'JAMI') as filial_soni
      from aylanma_foyda where sana between least(coalesce(v_bosh, p_from), p_from) and p_to group by sana
  ),
  q as (
    select k.kun,
           s1.jami_uzs  as jami_oldin,
           s2.jami_uzs  as jami,
           s2.rejim, s2.hisoblangan_at, s2.toliq,
           coalesce(s2.kurs_usd, s1.kurs_usd) as kurs,
           f.jami_usd as foyda_usd, f.filial_soni,
           case when f.jami_usd is not null and coalesce(s2.kurs_usd, s1.kurs_usd) is not null
                then round(f.jami_usd * coalesce(s2.kurs_usd, s1.kurs_usd), 0) end as foyda_uzs,
           aylanma_kun_xarajat(k.kun) as xarajat_uzs
      from kunlar k
      left join snap  s1 on s1.sana = k.kun
      left join snap  s2 on s2.sana = k.kun + 1
      left join foyda f  on f.sana  = k.kun
  ),
  c as (
    select q.*,
           -- 🔴 KUMULYATIV: boshlang'ich kun boshidagi haqiqiy jami + Σ(foyda − xarajat), boshlanishdan shu kungacha
           case when v_bosh is not null and q.kun >= v_bosh and v_bosh_jami is not null
                then v_bosh_jami + sum(case when q.kun >= v_bosh then coalesce(q.foyda_uzs, 0) - coalesce(q.xarajat_uzs, 0) else 0 end)
                                   over (order by q.kun rows between unbounded preceding and current row)
           end as kerak,
           -- eski kunlik qiymat (ma'lumot uchun)
           case when q.jami_oldin is not null and q.foyda_uzs is not null then q.jami_oldin + q.foyda_uzs - q.xarajat_uzs end as kerak_kun
      from q
     where v_bosh is null or q.kun >= v_bosh or q.kun >= p_from
  ),
  r as (
    select c.*,
           case when c.jami is not null and c.kerak is not null then c.jami - c.kerak end as raznitsa
      from c
  ),
  r2 as (
    select r.*,
           r.raznitsa - lag(r.raznitsa) over (order by r.kun) as kun_farq
      from r
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'kun', kun, 'jami_oldin', jami_oldin, 'jami', jami, 'rejim', rejim, 'hisoblangan_at', hisoblangan_at,
           'toliq', toliq, 'kurs', kurs, 'foyda_usd', foyda_usd, 'foyda_uzs', foyda_uzs, 'filial_soni', filial_soni,
           'foyda_yoq', (foyda_usd is null),
           'xarajat_uzs', xarajat_uzs,
           'kerak', kerak, 'kerak_kun', kerak_kun,
           'raznitsa', raznitsa, 'kun_farq', kun_farq
         ) order by kun desc), '[]'::jsonb)
    into v_rows
    from r2
   where kun between p_from and p_to;

  return jsonb_build_object('ok', true, 'rows', v_rows, 'p_from', p_from, 'p_to', p_to,
                            'boshlanish', v_bosh, 'boshlanish_jami', v_bosh_jami);
end
$fn$;
revoke all on function aylanma_hisobot(date, date) from public, anon;
grant execute on function aylanma_hisobot(date, date) to authenticated;
notify pgrst, 'reload schema';

-- TEKSHIRUV
select aylanma_hisobot_boshlanish() as boshlanish;
select * from jsonb_to_recordset((aylanma_hisobot(current_date - 7, current_date))->'rows')
  as t(kun date, kerak numeric, jami numeric, raznitsa numeric, kun_farq numeric, foyda_uzs numeric, xarajat_uzs numeric, foyda_yoq boolean)
 order by kun desc;
