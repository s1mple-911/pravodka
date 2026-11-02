-- =====================================================================
-- PROVODKA_AYLANMA_TAFSILOT_YUK.sql — 2026-11-02
-- Aylanma kunlik hisobot → «Fakt»/kun bosilganda (aylanma_hisobot_tafsilot) har filial yonida:
--   * tovar_usd / tovar_uzs      — OMBORDAGI tovar (snapshot T1 qatori, Aros profit-summary tannarx)
--   * yolda_uzs (+ yuk/ko'chirish ajratilgan) — YO'LDA kelayotgan: Y3a (posted+on_way yuklar, ombor bo'yicha)
--                                  + K3b (ko'chirish on_way, qabul qiluvchi ombor bo'yicha, hisobga=true)
-- Asilbek (2026-11-02): «fakt bosilganda har bir filial oldidan qancha yuki borligi ham yozilsin —
-- ombordagi yuk + yo'ldagi yukni alohida ko'rsatish».
--
-- MANBA: Fakt = ertasi kun snapshot (p_sana+1, cron ustun; bo'lmasa o'sha kunniki) — `aylanma_hisobot` bilan BIR XIL
-- juftlash. Javobga `yuk_snapshot_sana`/`yuk_snapshot_id`/`yuk_jami` qo'shiladi. Filial ↔ ombor: aylanma_foyda.warehouse_id
-- = T1.ref (Aros ombor id); Y3a/K3b qatorlarida id yo'q — ombor NOMI bo'yicha (Y3a nom = «Ombor · yetkazuvchi»,
-- K3b nom = «From -> To»; nomlar bitta manbadan — Aros warehouse name_uz/name — 01.11 snapshotida 21/21 mos).
-- Snapshot/qator yo'q bo'lsa maydonlar null (0 emas) — «—» ko'rinadi.
--
-- ADDITIVE: imzo o'zgarmagan (`aylanma_hisobot_tafsilot(date)`), eski kalitlar (foyda[].*, xarajat, xarajat_royxat,
-- xarajat_jami, kurs) aynan saqlanadi — prod `aylanma.html` ham shu funksiyani chaqiradi, unga yangi kalitlar zarar qilmaydi.
-- 🔴 Tana PROVODKA_PUL_USTI.sql dagi versiyadan verbatim + yuk bloki. ENG OXIRGI versiya endi SHU faylda.
-- Qayta RUN xavfsiz. Dollar-teg: $fn$ (izohda yonma-yon belgi yo'q).
-- =====================================================================

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
  v_snap_id uuid; v_snap_sana date;
  v_yuk_jami jsonb := null;
begin
  if not aylanma_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  select kurs_usd into v_kurs from aylanma_snapshot
   where sana in (p_sana + 1, p_sana) and kurs_usd is not null
   order by (sana = p_sana + 1) desc, (rejim = 'cron') desc, hisoblangan_at desc limit 1;

  -- 2026-11-02: Fakt snapshoti (ertasi kun; bo'lmasa o'sha kun) — filial tovar / yo'ldagi yuk shu yerdan
  select id, sana into v_snap_id, v_snap_sana from aylanma_snapshot
   where sana in (p_sana + 1, p_sana)
   order by (sana = p_sana + 1) desc, (rejim = 'cron') desc, hisoblangan_at desc limit 1;

  with f as (
    select f.filial, f.sotilgan, f.qaytarilgan, f.kirim_usd, f.sotuv_usd, f.keshbek_usd, f.foyda_usd,
           (to_jsonb(f) ->> 'warehouse_id')::int as wid          -- ustun yo'q bazada null
      from aylanma_foyda f where f.sana = p_sana
  ),
  t1 as (   -- ombordagi tovar: id bo'yicha, bo'lmasa nom bo'yicha
    select q.ref, q.nom, q.usd, q.uzs from aylanma_qator q
     where v_snap_id is not null and q.snapshot_id = v_snap_id and q.bolim = 'T1'
  ),
  fm as (   -- filial ↔ ombor (id ustun, nom zaxira)
    select f.*, coalesce(t_id.nom, t_nom.nom, f.filial) as ombor_nom,
           coalesce(t_id.usd, t_nom.usd) as tovar_usd, coalesce(t_id.uzs, t_nom.uzs) as tovar_uzs,
           (t_id.ref is not null or t_nom.ref is not null) as tovar_bor
      from f
      left join lateral (select * from t1 where f.wid is not null and t1.ref = f.wid::text limit 1) t_id on true
      left join lateral (select * from t1 where t_id.ref is null and lower(btrim(t1.nom)) = lower(btrim(f.filial)) limit 1) t_nom on true
  ),
  y3 as (   -- yo'ldagi yuklar (Y3a): nom = «Ombor · yetkazuvchi»
    select lower(btrim(split_part(q.nom, ' · ', 1))) as ombor, sum(coalesce(q.uzs, 0)) as uzs, count(*) as soni
      from aylanma_qator q
     where v_snap_id is not null and q.snapshot_id = v_snap_id and q.bolim = 'Y3a' and q.hisobga
     group by 1
  ),
  k3 as (   -- ko'chirish yo'lda (K3b): nom = «From -> To», qabul qiluvchi bo'yicha
    select lower(btrim(split_part(q.nom, ' -> ', 2))) as ombor, sum(coalesce(q.uzs, 0)) as uzs, count(*) as soni
      from aylanma_qator q
     where v_snap_id is not null and q.snapshot_id = v_snap_id and q.bolim = 'K3b' and q.hisobga
       and position(' -> ' in coalesce(q.nom, '')) > 0
     group by 1
  ),
  r as (
    select fm.*, y3.uzs as yuk_uzs, y3.soni as yuk_soni, k3.uzs as koch_uzs, k3.soni as koch_soni
      from fm
      left join y3 on y3.ombor = lower(btrim(fm.ombor_nom))
      left join k3 on k3.ombor = lower(btrim(fm.ombor_nom))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'filial', filial, 'sotilgan', sotilgan, 'qaytarilgan', qaytarilgan, 'kirim_usd', kirim_usd,
           'sotuv_usd', sotuv_usd, 'keshbek_usd', keshbek_usd, 'foyda_usd', foyda_usd,
           'foyda_uzs', case when v_kurs is not null then round(foyda_usd * v_kurs, 0) end,
           'warehouse_id', wid,
           'tovar_usd', case when filial = 'JAMI' then (select sum(tovar_usd) from r where filial <> 'JAMI' and tovar_bor)
                             when tovar_bor then tovar_usd end,
           'tovar_uzs', case when filial = 'JAMI' then (select sum(tovar_uzs) from r where filial <> 'JAMI' and tovar_bor)
                             when tovar_bor then tovar_uzs end,
           'yolda_uzs', case when v_snap_id is null then null
                             when filial = 'JAMI' then (select sum(coalesce(yuk_uzs, 0) + coalesce(koch_uzs, 0)) from r where filial <> 'JAMI')
                             else coalesce(yuk_uzs, 0) + coalesce(koch_uzs, 0) end,
           'yolda_yuk_uzs', case when v_snap_id is null then null
                                 when filial = 'JAMI' then (select sum(coalesce(yuk_uzs, 0)) from r where filial <> 'JAMI')
                                 else coalesce(yuk_uzs, 0) end,
           'yolda_yuk_soni', case when v_snap_id is null then null
                                  when filial = 'JAMI' then (select sum(coalesce(yuk_soni, 0)) from r where filial <> 'JAMI')
                                  else coalesce(yuk_soni, 0) end,
           'yolda_kochirish_uzs', case when v_snap_id is null then null
                                       when filial = 'JAMI' then (select sum(coalesce(koch_uzs, 0)) from r where filial <> 'JAMI')
                                       else coalesce(koch_uzs, 0) end,
           'yolda_kochirish_soni', case when v_snap_id is null then null
                                        when filial = 'JAMI' then (select sum(coalesce(koch_soni, 0)) from r where filial <> 'JAMI')
                                        else coalesce(koch_soni, 0) end
         ) order by (filial = 'JAMI'), foyda_usd desc), '[]'::jsonb)
    into v_foyda
    from r;

  -- snapshot bo'limlari jami (markaziy omborlar bilan) — UI izohi uchun
  if v_snap_id is not null then
    select jsonb_build_object(
             'T1',  (select jsonb_build_object('usd', sum(usd), 'uzs', sum(uzs), 'soni', count(*)) from aylanma_qator where snapshot_id = v_snap_id and bolim = 'T1'),
             'Y3a', (select jsonb_build_object('uzs', sum(uzs), 'soni', count(*)) from aylanma_qator where snapshot_id = v_snap_id and bolim = 'Y3a' and hisobga),
             'K3b', (select jsonb_build_object('uzs', sum(uzs), 'soni', count(*)) from aylanma_qator where snapshot_id = v_snap_id and bolim = 'K3b' and hisobga))
      into v_yuk_jami;
  end if;

  -- modda/kassa bo'yicha jami (avvalgidek)
  select coalesce(jsonb_agg(jsonb_build_object('modda', modda, 'kassa', kassa, 'summa', summa, 'soni', soni) order by summa desc), '[]'::jsonb)
    into v_xarajat
    from (
      select ma.name as modda, ka.name as kassa, sum(dt.debit) as summa, count(distinct e.id) as soni
        from entry e
        join entry_line dt on dt.entry_id = e.id and dt.debit > 0
        join accounts ma on ma.id = dt.account_id and ma.type = 'xarajat'
                        and ma.id is distinct from conv_farq_hisob_id()   -- 🔴 2026-10-06: texnik kurs farqi chiqarildi
        join lateral (select kt.account_id from entry_line kt
                       where kt.entry_id = e.id and kt.credit > 0
                         and kt.account_id = any(aylanma_asosiy_hisoblar()) limit 1) k on true
        join accounts ka on ka.id = k.account_id
       where e.entry_date = p_sana and e.status = 'posted' and e.is_deleted = false
       group by ma.name, ka.name
    ) x;

  -- har bir xarajat yozuvi
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
                        and ma.id is distinct from conv_farq_hisob_id()   -- 🔴 2026-10-06: texnik kurs farqi chiqarildi
        join lateral (select kt.account_id from entry_line kt
                       where kt.entry_id = e.id and kt.credit > 0
                         and kt.account_id = any(aylanma_asosiy_hisoblar()) limit 1) k on true
        join accounts ka on ka.id = k.account_id
       where e.entry_date = p_sana and e.status = 'posted' and e.is_deleted = false
    ) r;

  return jsonb_build_object('ok', true, 'sana', p_sana, 'kurs', v_kurs, 'foyda', v_foyda, 'xarajat', v_xarajat,
                            'xarajat_royxat', v_royxat, 'xarajat_jami', aylanma_kun_xarajat(p_sana),
                            'yuk_snapshot_sana', v_snap_sana, 'yuk_snapshot_id', v_snap_id, 'yuk_jami', v_yuk_jami);
end
$fn$;
revoke all on function aylanma_hisobot_tafsilot(date) from public, anon;
grant execute on function aylanma_hisobot_tafsilot(date) to authenticated;

notify pgrst, 'reload schema';

-- TEKSHIRUV (RUN'dan keyin): kechagi kun uchun filial tovar/yo'lda to'lganmi
select (x ->> 'filial') as filial, (x ->> 'tovar_usd') as tovar_usd, (x ->> 'yolda_uzs') as yolda_uzs,
       (x ->> 'yolda_yuk_soni') as yuk_soni, (x ->> 'yolda_kochirish_soni') as kochirish_soni
  from jsonb_array_elements(aylanma_hisobot_tafsilot(current_date - 1) -> 'foyda') x
 limit 25;
