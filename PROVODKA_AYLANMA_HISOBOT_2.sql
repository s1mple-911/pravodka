-- ============================================================================
--  PROVODKA_AYLANMA_HISOBOT_2.sql — 2026-10-03 — Kunlik hisobot tafsiloti: xarajatlar RO'YXATI (har yozuv)
--  Asilbek: «Xarajatni bossam o'sha kungi barcha xarajatlar, foydani bossam o'sha kungi foydalar» — katak bo'yicha tafsilot.
--  aylanma_hisobot_tafsilot(p_sana) qayta e'lon: avvalgi kalitlar saqlanadi (foyda, xarajat (modda/kassa jami), xarajat_jami, kurs)
--  + YANGI `xarajat_royxat` — kunning har bir xarajat yozuvi: vaqt, kassa, modda, summa, izoh, ijrochi, filial(lar).
--  Faqat ASOSIY kassadan chiqqanlar (aylanma_kun_xarajat bilan bir xil shart). Old shart: PROVODKA_AYLANMA_HISOBOT.sql. Asilbek RUN qiladi.
-- ============================================================================
create or replace function aylanma_hisobot_tafsilot(p_sana date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_kurs numeric;
  v_foyda jsonb; v_xarajat jsonb; v_royxat jsonb;
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

  -- modda/kassa bo'yicha jami (avvalgidek)
  select coalesce(jsonb_agg(jsonb_build_object('modda', modda, 'kassa', kassa, 'summa', summa, 'soni', soni) order by summa desc), '[]'::jsonb)
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

  -- YANGI: har bir xarajat yozuvi
  select coalesce(jsonb_agg(jsonb_build_object(
           'entry_id', entry_id, 'vaqt', vaqt, 'kassa', kassa, 'modda', modda, 'summa', summa,
           'izoh', izoh, 'ijrochi', ijrochi, 'filial', filial
         ) order by vaqt desc), '[]'::jsonb)
    into v_royxat
    from (
      select e.id as entry_id, e.created_at as vaqt, ka.name as kassa, ma.name as modda, dt.debit as summa,
             e.description as izoh,
             coalesce((to_jsonb(e) ->> 'created_by_name'),
                      (select p.full_name from profiles p where p.id::text = (to_jsonb(e) ->> 'created_by') limit 1)) as ijrochi,
             (select string_agg(fa.name, ', ') from accounts fa where fa.id = any(coalesce(e.filial_ids, '{}'::uuid[]))) as filial
        from entry e
        join entry_line dt on dt.entry_id = e.id and dt.debit > 0
        join accounts ma on ma.id = dt.account_id and ma.type = 'xarajat'
        join lateral (select kt.account_id from entry_line kt
                       where kt.entry_id = e.id and kt.credit > 0
                         and kt.account_id = any(aylanma_asosiy_hisoblar()) limit 1) k on true
        join accounts ka on ka.id = k.account_id
       where e.entry_date = p_sana and e.status = 'posted' and e.is_deleted = false
    ) r;

  return jsonb_build_object('ok', true, 'sana', p_sana, 'kurs', v_kurs, 'foyda', v_foyda, 'xarajat', v_xarajat,
                            'xarajat_royxat', v_royxat, 'xarajat_jami', aylanma_kun_xarajat(p_sana));
end
$fn$;
revoke all on function aylanma_hisobot_tafsilot(date) from public, anon;
grant execute on function aylanma_hisobot_tafsilot(date) to authenticated;
notify pgrst, 'reload schema';

select jsonb_array_length((aylanma_hisobot_tafsilot(current_date - 1))->'xarajat_royxat') as kecha_xarajat_yozuvlari,
       (aylanma_hisobot_tafsilot(current_date - 1))->>'xarajat_jami' as kecha_xarajat_jami;
