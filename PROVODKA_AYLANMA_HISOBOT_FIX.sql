-- ============================================================================
--  PROVODKA_AYLANMA_HISOBOT_FIX.sql — 2026-10-03 — aylanma_hisobot: «missing FROM-clause entry for table "f"»
--  Sabab: q CTE'da foyda (f) JOIN'i tushib qolgan edi. Faqat shu funksiya qayta e'lon qilinadi (tanasi
--  PROVODKA_AYLANMA_HISOBOT.sql 5-band bilan bir xil + `left join foyda f on f.sana = k.kun`). Asilbek RUN qiladi.
-- ============================================================================
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
  with snap as (
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
      left join foyda f  on f.sana  = k.kun            -- 🔴 FIX: tushib qolgan JOIN
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
notify pgrst, 'reload schema';

select * from jsonb_to_recordset((aylanma_hisobot(current_date - 7, current_date))->'rows')
  as t(kun date, jami_oldin numeric, jami numeric, foyda_usd numeric, foyda_uzs numeric, xarajat_uzs numeric, kerak numeric, raznitsa numeric)
 order by kun desc;
