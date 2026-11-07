-- =====================================================================
-- PROVODKA_BALANS_B_DETAL_20261107.sql  (2026-11-07, faqat dev, RUN kutilmoqda)
-- Balans B / C: har bir qator TARKIBI (drill-down) — balans_b_detal(p_kod, p_sana).
-- ---------------------------------------------------------------------
-- ## QOIDA: ADDITIVE va IDEMPOTENT. Faqat YANGI funksiyalar (_bbd_* va balans_b_detal).
--   Jadval / ustun / trigger YO'Q, yozuv YOZILMAYDI. balans_b(), _bb_val() va boshqalarga TEGILMAYDI.
--   Oldin RUN qilingan bo'lishi SHART: PROVODKA_BALANS_B_CASHFLOW_B_20261107.sql (_bb_* yordamchilar, balans_b).
--   Ixtiyoriy manbalar (yo'q bo'lsa tegishli qator bo'sh qoladi, funksiya yiqilmaydi):
--   aylanma_snapshot / aylanma_qator, aros_transfer_yolda, aros_qarzdor, aros_yuk_snapshot, qarz_ob / qarz_ob_tolov,
--   yuk_yolda_jami, yetkazuvchi_avans_royxat.
--
-- ## balans_b_detal(p_kod text, p_sana date default null) -> jsonb
--   {ok, kod, sarlavha, sana, manba (matn), manba_tur (daftar|jonli|snapshot|joriy|kiritilmagan|yoq),
--    jami (balans_b qator summasi AYNAN), qator_summa (qatorlar yig'indisi), ustunlar:[{k,t}],
--    qatorlar:[{nom, qism, summa_uzs, fc, valyuta, izoh, havola}],
--    qoshimcha:[{sarlavha, izoh, jami, qatorlar:[...]}]  (ma'lumot uchun, jamiga KIRMAYDI),
--    ogoh:[text]}
--   p_kod = balans_b qator kodi (pul, yolda_pul, mijoz_qarz, hodim_pul, berilgan_qarz, ochiq_buyurtma, tovar, kochirish,
--           yolda_yuk, yolda_yuk_posted, brak, boshqa_aktiv, uzoq_aktiv, yetk_qarz, kelmagan_qarz, mijoz_avans,
--           olingan_qarz, ish_soliq, boshqa_majb, uzoq_majb, kapital, jami_aktiv, jami_majburiyat).
--   Ruxsat balans_b bilan BIR XIL (_bb_ok: sahifa 'balans' + kassa doirasi hamma); ruxsat yo'q = xato 42501.
--   jami = balans_b(p_sana, null) ning shu qatori; qatorlar yig'indisi unga teng bo'lmasa ogoh da «farq X».
--   Daftar qatorlari entry_date <= p_sana (tarixiy aniq); Aros / registr qatorlari joriy (manba=joriy, ogohda aytiladi).
-- =====================================================================


-- #####################################################################
-- ##  0 — ichki yordamchilar                                          ##
-- #####################################################################

-- Bitta tafsilot qatori.
create or replace function _bbd_row(p_nom text, p_qism text, p_summa numeric, p_fc numeric default null,
                                    p_val text default null, p_izoh text default null, p_havola text default null)
returns jsonb
language sql
immutable
as $bbd_row$
  select jsonb_build_object('nom', p_nom, 'qism', p_qism, 'summa_uzs', p_summa, 'fc', p_fc,
                            'valyuta', p_val, 'izoh', p_izoh, 'havola', p_havola);
$bbd_row$;

-- Juda uzun ro'yxat: eng kattalari + «boshqa N ta» (yig'indi saqlanadi).
create or replace function _bbd_cap(p_rows jsonb, p_cap int default 1500)
returns jsonb
language sql
immutable
as $bbd_cap$
  with e as (
    select x, coalesce((x ->> 'summa_uzs')::numeric, 0) as s,
           row_number() over (order by abs(coalesce((x ->> 'summa_uzs')::numeric, 0)) desc, x ->> 'nom') as rn
      from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
  )
  select case when (select count(*) from e) <= p_cap then coalesce((select jsonb_agg(x order by rn) from e), '[]'::jsonb)
         else (select jsonb_agg(x order by rn) from e where rn <= p_cap)
              || jsonb_build_array(jsonb_build_object('nom', 'Qolgan ' || ((select count(*) from e) - p_cap) || ' ta qator',
                     'qism', null, 'summa_uzs', (select sum(s) from e where rn > p_cap), 'fc', null, 'valyuta', null,
                     'izoh', 'Ro''yxat qisqartirildi (eng katta ' || p_cap || ' ta ko''rsatilgan)', 'havola', null))
         end;
$bbd_cap$;

-- Valyutali hisoblar: fc qoldiq (Dt tomonda +fc, Kt tomonda -fc), sanagacha.
create or replace function _bbd_fc(p_sana date)
returns table(account_id uuid, fc numeric)
language sql
stable
set search_path = public
as $bbd_fc$
  select l.account_id,
         sum(case when l.debit > 0 then coalesce(l.fc_amount, 0) else -coalesce(l.fc_amount, 0) end)
    from entry_line l
    join entry e on e.id = l.entry_id
    join accounts a on a.id = l.account_id
   where e.status = 'posted' and e.is_deleted = false and e.entry_date <= p_sana
     and coalesce(a.currency, 'UZS') <> 'UZS'
   group by l.account_id;
$bbd_fc$;

revoke all on function _bbd_fc(date) from public, anon;
grant execute on function _bbd_fc(date) to authenticated;


-- Daftar hisoblari bo'yicha qatorlar. Filtrlar _bb_val dagi agregatlar bilan AYNAN bir xil.
-- Maxsus kodlar (qo'shimcha bo'limlar uchun): d4010, d6010, kapital_h.
create or replace function _bbd_daftar(p_sana date, p_kod text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bbd_daftar$
declare
  v_neg boolean := p_kod in ('olingan_qarz', 'ish_soliq', 'uzoq_majb', 'boshqa_majb', 'd6010', 'kapital_h');
  v_out jsonb;
begin
  select coalesce(jsonb_agg(_bbd_row(
           x.name, x.code, x.summa, x.fc, case when x.fc is not null then x.cur end,
           nullif(concat_ws(' · ',
             case when x.pname is not null then 'ota hisob: ' || x.pname end,
             case when x.pul_turi is not null then x.pul_turi end,
             case when x.lk_name is not null then 'filial kassa: ' || x.lk_name end,
             case when x.filial_ref is not null then 'filial: ' || x.filial_ref end), ''),
           'jurnal-dev.html?hisob=' || x.code || '&gacha=' || p_sana::text)
         order by abs(x.summa) desc, x.code), '[]'::jsonb)
    into v_out
    from (
      select h.code, h.name, coalesce(h.currency, 'UZS') as cur,
             (case when v_neg then -s.b else s.b end) as summa,
             case when coalesce(h.currency, 'UZS') <> 'UZS'
                  then (case when v_neg then -f.fc else f.fc end) end as fc,
             pa.name as pname,
             nullif(to_jsonb(a) ->> 'pul_turi', '') as pul_turi,
             lk.name as lk_name,
             nullif(to_jsonb(a) ->> 'filial_ref', '') as filial_ref
        from _bb_saldo(p_sana) s
        join _bb_hisob() h on h.id = s.account_id
        join accounts a on a.id = h.id
        left join accounts pa on pa.id = h.parent_id
        left join accounts lk on lk.id::text = to_jsonb(a) ->> 'linked_kassa_id'
        left join _bbd_fc(p_sana) f on f.account_id = h.id
       where abs(s.b) >= 0.005
         and (   (p_kod = 'pul'          and h.section = 'pul' and not h.hodim)
              or (p_kod = 'tovar'        and h.section = 'tovar')
              or (p_kod = 'berilgan_qarz' and h.code ~ '^47[0-9][0-9]$')
              or (p_kod = 'boshqa_aktiv' and h.bolim = 'joriy_aktiv' and h.section not in ('pul', 'tovar')
                                         and h.code <> '4010' and h.code !~ '^47[0-9][0-9]$')
              or (p_kod = 'uzoq_aktiv'   and h.bolim = 'uzoq_aktiv')
              or (p_kod = 'olingan_qarz' and h.code ~ '^6820')
              or (p_kod = 'ish_soliq'    and h.bolim = 'joriy_majburiyat' and h.section in ('soliq_majb', 'oylik_majb'))
              or (p_kod = 'uzoq_majb'    and h.bolim = 'uzoq_majburiyat')
              or (p_kod = 'boshqa_majb'  and h.bolim = 'joriy_majburiyat' and h.code <> '6010' and h.code !~ '^6820'
                                         and h.section not in ('soliq_majb', 'oylik_majb')
                                         and h.code <> '8900' and h.name not ilike '%vaqtinchalik%')
              or (p_kod = 'd4010'        and h.code = '4010')
              or (p_kod = 'd6010'        and h.code = '6010')
              or (p_kod = 'kapital_h'    and (h.type = 'kapital' or h.code = '8900'))
             )
    ) x;
  return v_out;
end
$bbd_daftar$;

revoke all on function _bbd_daftar(date, text) from public, anon, authenticated;


-- Hodim kassalari: 5400 konteynerning bevosita bolalari (har biri avlodlari bilan) bo'yicha yig'indi.
create or replace function _bbd_hodim(p_sana date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bbd_hodim$
declare
  v_out jsonb;
begin
  with recursive kont as (
    select k.id from accounts k where k.code = '5400' or k.kassa_turi = 'xarajat_guruh'
  ),
  tree as (
    select a.id, a.id as root from accounts a where a.parent_id in (select id from kont)
    union all
    select a.id, t.root from accounts a join tree t on a.parent_id = t.id
  ),
  hs as (
    select coalesce(t.root, h.id) as root, coalesce(h.currency, 'UZS') as cur, s.b, f.fc
      from _bb_saldo(p_sana) s
      join _bb_hisob() h on h.id = s.account_id
      left join tree t on t.id = h.id
      left join _bbd_fc(p_sana) f on f.account_id = h.id
     where h.section = 'pul' and h.hodim
  ),
  g as (
    select root, sum(b) as summa,
           sum(fc) filter (where cur = 'USD') as usd,
           string_agg(cur || ' ' || _bb_fmt(fc), ' · ' order by cur)
             filter (where cur <> 'UZS' and cur <> 'USD' and coalesce(fc, 0) <> 0) as boshqa_val
      from hs group by root
  )
  select coalesce(jsonb_agg(_bbd_row(
           r.name || case when r.id in (select id from kont) then ' (konteyner)' else '' end,
           coalesce(nullif(to_jsonb(r) ->> 'subtitle', ''), r.code),
           g.summa,
           case when coalesce(g.usd, 0) <> 0 then g.usd end,
           case when coalesce(g.usd, 0) <> 0 then 'USD' end,
           nullif(concat_ws(' · ', r.code, g.boshqa_val,
                            case when coalesce(r.is_active, true) = false then 'nofaol kassa' end), ''),
           'jurnal-dev.html?hisob=' || r.code || '&gacha=' || p_sana::text)
         order by abs(g.summa) desc, r.code), '[]'::jsonb)
    into v_out
    from g
    join accounts r on r.id = g.root
   where abs(g.summa) >= 0.005 or coalesce(g.usd, 0) <> 0;
  return v_out;
end
$bbd_hodim$;

revoke all on function _bbd_hodim(date) from public, anon, authenticated;


-- Aylanma snapshot qatorlari (n8n): {rows, manba (snapshot|joriy|yoq), sana, yashirin}.
-- Snapshot tanlash _bb_pick bilan bir xil: sana uchun aniq snapshot (kalit bor bo'lsa) -> 'snapshot',
-- aks holda eng oxirgi snapshot (kalit bor bo'lsa) -> 'joriy'. hisobga=false qatorlar jamiga kirmagan: chiqarilmaydi, soni 'yashirin'.
create or replace function _bbd_snap(p_sana date, p_key text, p_qism text default null, p_ref text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bbd_snap$
declare
  v_id   uuid;
  v_sana date;
  v_b    jsonb;
  v_m    text := 'yoq';
  v_rows jsonb := '[]'::jsonb;
  v_yash int := 0;
begin
  if to_regclass('public.aylanma_snapshot') is null or to_regclass('public.aylanma_qator') is null then
    return jsonb_build_object('rows', v_rows, 'manba', 'yoq', 'sana', null, 'yashirin', 0);
  end if;

  select s.id, s.sana, s.bolimlar into v_id, v_sana, v_b
    from aylanma_snapshot s where s.sana = p_sana order by s.hisoblangan_at desc limit 1;
  if v_id is not null and jsonb_typeof(v_b -> p_key) = 'object' then
    v_m := 'snapshot';
  else
    select s.id, s.sana, s.bolimlar into v_id, v_sana, v_b
      from aylanma_snapshot s order by s.sana desc, s.hisoblangan_at desc limit 1;
    if v_id is not null and jsonb_typeof(v_b -> p_key) = 'object' then v_m := 'joriy'; else v_id := null; end if;
  end if;

  if v_id is null then
    return jsonb_build_object('rows', v_rows, 'manba', 'yoq', 'sana', null, 'yashirin', 0);
  end if;

  select coalesce(jsonb_agg(_bbd_row(
           coalesce(nullif(btrim(q.nom), ''), q.ref),
           coalesce(p_qism, nullif(q.meta ->> 'kod', ''), q.ref),
           q.uzs,
           q.usd,
           case when q.usd is not null then 'USD' end,
           nullif(concat_ws(' · ',
             case when q.meta ->> 'kurs_yoq' = 'true' then 'kurs topilmadi' || coalesce(' (' || (q.meta ->> 'valyuta') || ')', '') end,
             case when q.meta ->> 'yoq' = 'true' then 'ma''lumot yo''q' end,
             case when q.meta ->> 'to_brak' = 'true' then 'brak omborga' end,
             case when nullif(q.meta ->> 'status', '') is not null then q.meta ->> 'status' end,
             case when nullif(q.meta ->> 'tr_yolda_uzs', '') is not null
                  then 'yo''lda: ' || _bb_fmt((q.meta ->> 'tr_yolda_uzs')::numeric) end), ''),
           null) order by q.uzs desc nulls last), '[]'::jsonb),
         0
    into v_rows, v_yash
    from aylanma_qator q
   where q.snapshot_id = v_id and q.bolim = p_key and q.hisobga is not false
     and (p_ref is null or q.ref = p_ref);

  -- hisobga=false sanog'i alohida (yuqoridagi filtr ularni chiqarib tashlagan)
  select count(*) into v_yash from aylanma_qator q
   where q.snapshot_id = v_id and q.bolim = p_key and q.hisobga = false;

  return jsonb_build_object('rows', v_rows, 'manba', v_m, 'sana', v_sana, 'yashirin', v_yash);
end
$bbd_snap$;

revoke all on function _bbd_snap(date, text, text, text) from public, anon, authenticated;


-- Qarz oldi-berdi: faol qarzlar (kontragent, qoldiq so'mda). p_yon = 'berdik' | 'oldik'.
-- Qoldiq = asosiy - to'langan (qarz valyutasida); so'mga qarz berilgan kurs bo'yicha proporsional (summa / fc_summa).
create or replace function _bbd_qarz_ob(p_yon text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bbd_qo$
declare
  v_out jsonb := '[]'::jsonb;
begin
  if to_regclass('public.qarz_ob') is null or to_regclass('public.qarz_ob_tolov') is null then
    return v_out;
  end if;
  select coalesce(jsonb_agg(_bbd_row(
           z.kontragent,
           coalesce('tugash ' || to_char(z.tugash, 'DD.MM.YYYY'), null),
           z.qoldi_uzs,
           case when z.valyuta <> 'UZS' then z.qoldi end,
           case when z.valyuta <> 'UZS' then z.valyuta end,
           nullif(concat_ws(' · ', z.izoh, case when z.eski_qarz then 'eski qarz (boshlang''ich qoldiq)' end), ''),
           null) order by z.qoldi_uzs desc, z.kontragent), '[]'::jsonb)
    into v_out
    from (
      select q.kontragent, q.tugash, q.valyuta, q.eski_qarz, q.izoh,
             greatest(y.asosiy - y.tolandi, 0) as qoldi,
             case when q.valyuta = 'UZS' then greatest(y.asosiy - y.tolandi, 0)
                  else greatest(y.asosiy - y.tolandi, 0) * q.summa / nullif(q.fc_summa, 0) end as qoldi_uzs
        from qarz_ob q
        cross join lateral (
          select case when q.valyuta <> 'UZS' then coalesce(q.fc_summa, 0) else q.summa end as asosiy,
                 coalesce((select sum(case when q.valyuta <> 'UZS' then coalesce(t.fc_summa, 0) else t.summa end)
                             from qarz_ob_tolov t where t.qarz_id = q.id and t.is_deleted = false), 0) as tolandi
        ) y
       where q.yonalish = p_yon and q.holat = 'faol'
    ) z
   where z.qoldi_uzs is not null and z.qoldi_uzs > 0;
  return v_out;
end
$bbd_qo$;

revoke all on function _bbd_qarz_ob(text) from public, anon, authenticated;


-- Qatorlar yig'indisi.
create or replace function _bbd_sum(p_rows jsonb)
returns numeric
language sql
immutable
as $bbd_sum$
  select coalesce(sum(nullif(x ->> 'summa_uzs', '')::numeric), 0) from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x;
$bbd_sum$;


-- #####################################################################
-- ##  1 — balans_b_detal(p_kod, p_sana)                               ##
-- #####################################################################
create or replace function balans_b_detal(p_kod text, p_sana date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bbd_main$
declare
  v_bugun  date := (now() at time zone 'Asia/Tashkent')::date;
  v_sana   date := coalesce(p_sana, (now() at time zone 'Asia/Tashkent')::date);
  v_tarix  boolean;
  b        record;
  v_nom    text;
  v_jami   numeric;
  v_mt     text;           -- manba turi (balans_b.manba)
  v_biz    text;           -- balans_b.izoh
  v_man    text := '';     -- inson o'qiydigan manba matni
  v_rows   jsonb := '[]'::jsonb;
  v_qosh   jsonb := '[]'::jsonb;
  v_ogoh   jsonb := '[]'::jsonb;
  v_nomt   text := 'Nomi';
  v_qismt  text := 'Kod';
  v_sum    numeric;
  v_kurs   numeric;
  v_sn     jsonb;
  v_sn2    jsonb;
  v_x      jsonb;
  v_t      numeric;
  v_n      int;
  v_ok     boolean;
  -- Q2b
  v_rowsj  jsonb;  v_paid jsonb;  v_kmap jsonb;  v_curs text[];
  -- yo'ldagi yuk
  v_kyoq   int;
begin
  if not _bb_ok() then
    raise exception 'Ruxsat yo''q (balans sahifasi, kassa doirasi: hamma)' using errcode = '42501';
  end if;
  if p_kod is null or btrim(p_kod) = '' then
    return jsonb_build_object('ok', false, 'kod', 'kod_kerak');
  end if;
  v_tarix := v_sana < v_bugun;

  -- ---- jami: balans_b qatori AYNAN (bir xil manba / formula) ----
  select x.kod, x.nom, x.summa, x.manba, x.izoh into b
    from balans_b(v_sana, null) x where x.kod = p_kod;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'nomalum', 'error', 'Noma''lum qator kodi: ' || p_kod);
  end if;
  v_nom := b.nom; v_jami := b.summa; v_mt := b.manba; v_biz := b.izoh;

  -- USD kursi (yo'ldagi pul uchun, _bb_val bilan bir xil tartib)
  v_kurs := null;
  begin
    if _bb_fn('aros_usd_rate', '') then execute 'select aros_usd_rate()' into v_kurs; end if;
  exception when others then v_kurs := null;
  end;
  if v_kurs is null then
    begin
      if _bb_fn('conv_baza_kurs', 'text') then execute 'select conv_baza_kurs($1)' into v_kurs using 'USD'; end if;
    exception when others then v_kurs := null;
    end;
  end if;

  -- =========================== qatorlar ===========================
  if p_kod = 'pul' then
    v_nomt := 'Kassa'; v_qismt := 'Kod';
    v_man := 'Daftar: pul hisoblari (section=pul), hodim kassalarisiz — kassa, tur (naqd / click / payme) va valyuta bolalari bilan';
    v_rows := _bbd_daftar(v_sana, 'pul');

  elsif p_kod = 'hodim_pul' then
    v_nomt := 'Hodim kassasi'; v_qismt := 'Filial · lavozim';
    v_man := 'Daftar: 5400 konteyner ostidagi hodim kassalari (har biri valyuta / tur bolalari bilan)';
    v_rows := _bbd_hodim(v_sana);

  elsif p_kod = 'tovar' then
    v_nomt := 'Ombor (hisob)'; v_qismt := 'Kod';
    v_man := 'Daftar: tovar hisoblari (29xx, section=tovar) — ombor / filial';
    v_rows := _bbd_daftar(v_sana, 'tovar');
    v_sn := _bbd_snap(v_sana, 'T1');
    if jsonb_array_length(v_sn -> 'rows') > 0 then
      v_qosh := v_qosh || jsonb_build_array(jsonb_build_object(
        'sarlavha', 'Aros ombori kesimida (T1, tannarx)',
        'izoh', 'Aylanma snapshot ' || coalesce(v_sn ->> 'sana', '?') || ' — daftar bilan solishtirish uchun, jamiga kirmaydi',
        'jami', _bbd_sum(v_sn -> 'rows'), 'qatorlar', v_sn -> 'rows'));
    end if;

  elsif p_kod = 'berilgan_qarz' or p_kod = 'olingan_qarz' then
    v_nomt := 'Kontragent'; v_qismt := 'Muddat';
    v_x := _bbd_qarz_ob(case when p_kod = 'berilgan_qarz' then 'berdik' else 'oldik' end);
    v_sn := _bbd_daftar(v_sana, p_kod);
    if jsonb_array_length(v_x) > 0 and v_tarix then
      -- tarixiy sana: faol qarzlar ro'yxati joriy qoldiq, shuning uchun daftar hisoblari asosiy, ro'yxat qo'shimcha
      v_man := 'Daftar: ' || case when p_kod = 'berilgan_qarz' then '4710 / 4720' else '6820' end
               || ' hisoblari (' || to_char(v_sana, 'DD.MM.YYYY') || ' holatiga)';
      v_nomt := 'Hisob'; v_rows := v_sn;
      v_qosh := v_qosh || jsonb_build_array(jsonb_build_object(
        'sarlavha', 'Qarz oldi-berdi: faol qarzlar (JORIY qoldiq)',
        'izoh', 'Kontragentlar bo''yicha hozirgi qoldiq — tarixiy sana jamiga kirmaydi',
        'jami', _bbd_sum(v_x), 'qatorlar', v_x));
    elsif jsonb_array_length(v_x) > 0 then
      v_man := 'Qarz oldi-berdi: faol qarzlar (kontragent, qoldiq) + daftar bilan farq';
      v_rows := v_x;
      v_t := coalesce(v_jami, _bbd_sum(v_sn)) - _bbd_sum(v_x);
      if abs(v_t) >= 1 then
        v_rows := v_rows || jsonb_build_array(_bbd_row(
          'Qarz oldi-berdi ro''yxatiga kirmagan qoldiq', null, v_t, null, null,
          'Daftar hisobi ' || case when p_kod = 'berilgan_qarz' then '4710 / 4720' else '6820' end || ' va faol qarzlar yig''indisi farqi', null));
      end if;
      v_qosh := v_qosh || jsonb_build_array(jsonb_build_object(
        'sarlavha', 'Daftar hisoblari', 'izoh', 'Jurnal bo''yicha qoldiq (balans qatori shu bilan hisoblanadi)',
        'jami', _bbd_sum(v_sn), 'qatorlar', v_sn));
    else
      v_man := 'Daftar: ' || case when p_kod = 'berilgan_qarz' then '4710 / 4720' else '6820' end
               || ' hisoblari (qarz oldi-berdi ro''yxatida faol qarz topilmadi)';
      v_nomt := 'Hisob'; v_rows := v_sn;
    end if;

  elsif p_kod = 'boshqa_aktiv' or p_kod = 'uzoq_aktiv' or p_kod = 'ish_soliq' or p_kod = 'uzoq_majb' or p_kod = 'boshqa_majb' then
    v_nomt := 'Hisob'; v_qismt := 'Kod';
    v_man := 'Daftar: ' || case p_kod
      when 'boshqa_aktiv' then 'joriy aktiv hisoblari (pul, tovar, 4010 va 47xx dan boshqa)'
      when 'uzoq_aktiv'   then 'balans_bolimi = uzoq_aktiv hisoblari (yo''q bo''lsa asosiy vosita / amortizatsiya)'
      when 'ish_soliq'    then 'soliq va oylik (ish haqi) majburiyat hisoblari'
      when 'uzoq_majb'    then 'balans_bolimi = uzoq_majburiyat hisoblari'
      else '6010 va 6820 dan boshqa joriy majburiyat hisoblari' end;
    v_rows := _bbd_daftar(v_sana, p_kod);

  elsif p_kod = 'yolda_pul' then
    v_nomt := 'Kimdan → kimga'; v_qismt := 'Jo''natilgan sana';
    if v_mt = 'snapshot' then
      v_sn := _bbd_snap(v_sana, 'B');
      v_man := 'Aylanma snapshot ' || coalesce(v_sn ->> 'sana', '?') || ' (B): yo''ldagi transferlar';
      v_rows := v_sn -> 'rows';
    elsif to_regclass('public.aros_transfer_yolda') is not null then
      v_man := 'Aros transfer registri (aros_transfer_yolda, status=sent): yo''ldagi transferlar';
      select coalesce(jsonb_agg(_bbd_row(
               coalesce(t.sender_title, '?') || ' → ' || coalesce(t.receiver_title, '?'),
               to_char(t.sent_at at time zone 'Asia/Tashkent', 'DD.MM.YYYY HH24:MI'),
               coalesce(t.s_cash, 0) + coalesce(t.s_click, 0) + coalesce(t.s_payme, 0) + coalesce(t.s_usd, 0) * coalesce(v_kurs, 0),
               case when coalesce(t.s_usd, 0) <> 0 then t.s_usd end,
               case when coalesce(t.s_usd, 0) <> 0 then 'USD' end,
               nullif(concat_ws(' · ',
                 case when coalesce(t.s_cash, 0) <> 0 then 'naqd ' || _bb_fmt(t.s_cash) end,
                 case when coalesce(t.s_click, 0) <> 0 then 'click ' || _bb_fmt(t.s_click) end,
                 case when coalesce(t.s_payme, 0) <> 0 then 'payme ' || _bb_fmt(t.s_payme) end,
                 case when coalesce(t.s_usd, 0) <> 0 then '$' || _bb_fmt(t.s_usd) end,
                 case when nullif(t.responsible, '') is not null then 'mas''ul: ' || t.responsible end), ''),
               null) order by (coalesce(t.s_cash, 0) + coalesce(t.s_click, 0) + coalesce(t.s_payme, 0)
                               + coalesce(t.s_usd, 0) * coalesce(v_kurs, 0)) desc), '[]'::jsonb)
        into v_rows
        from aros_transfer_yolda t where t.status = 'sent';
      if v_kurs is null then
        v_ogoh := v_ogoh || to_jsonb('USD kursi topilmadi — dollar qismi so''mga o''tkazilmagan.'::text);
      end if;
    end if;

  elsif p_kod = 'mijoz_qarz' then
    v_nomt := 'Mijoz'; v_qismt := 'Filial';
    v_sn2 := _bbd_daftar(v_sana, 'd4010');
    if v_mt = 'snapshot' then
      v_sn := _bbd_snap(v_sana, 'Q2a', null, 'aros');
      v_man := 'Aylanma snapshot ' || coalesce(v_sn ->> 'sana', '?') || ' (Q2a): Aros mijozlar qarzi — snapshotda mijoz kesimi saqlanmaydi';
      v_rows := v_sn -> 'rows';
    elsif v_mt in ('jonli', 'joriy') and to_regclass('public.aros_qarzdor') is not null then
      v_man := 'Aros qarzdorlar (aros_qarzdor, faol): mijozlar qarzi — hamyon AYIRILMAGAN';
      select coalesce(jsonb_agg(_bbd_row(
               coalesce(nullif(btrim(coalesce(a.ism, '') || ' ' || coalesce(a.familya, '')), ''), 'Mijoz #' || a.user_id),
               a.warehouse_nom,
               a.total_debt, null, null,
               nullif(concat_ws(' · ',
                 case when nullif(a.telefon, '') is not null then a.telefon end,
                 case when coalesce(a.wallet_balance, 0) > 0 then 'hamyon ' || _bb_fmt(a.wallet_balance) end,
                 case when coalesce(a.total_outdated, 0) > 0 then 'muddati o''tgan ' || _bb_fmt(a.total_outdated) end), ''),
               null) order by a.total_debt desc), '[]'::jsonb)
        into v_rows
        from aros_qarzdor a
       where coalesce((to_jsonb(a) ->> 'faol')::boolean, true) and coalesce(a.total_debt, 0) <> 0;
    else
      v_man := 'Daftar 4010 (Aros manbasi yo''q)';
      v_nomt := 'Hisob'; v_rows := v_sn2;
    end if;
    if v_mt <> 'daftar' then
      v_qosh := v_qosh || jsonb_build_array(jsonb_build_object(
        'sarlavha', 'Daftar 4010 (jamiga QO''SHILMAGAN)',
        'izoh', 'Provodka daftaridagi mijoz qarzi hisobi — Aros manbasi bilan ikki marta sanalmasligi uchun jamiga kirmaydi',
        'jami', _bbd_sum(v_sn2), 'qatorlar', v_sn2));
    end if;

  elsif p_kod = 'mijoz_avans' then
    v_nomt := 'Mijoz'; v_qismt := 'Filial';
    if v_mt = 'snapshot' then
      v_sn := _bbd_snap(v_sana, 'Q2a', null, 'aros_hamyon');
      v_man := 'Aylanma snapshot ' || coalesce(v_sn ->> 'sana', '?') || ' (Q2a hamyon): mijoz kesimi saqlanmaydi';
      select coalesce(jsonb_agg(jsonb_set(x, '{summa_uzs}', to_jsonb(-(x ->> 'summa_uzs')::numeric))), '[]'::jsonb)
        into v_rows from jsonb_array_elements(v_sn -> 'rows') x
       where (x ->> 'summa_uzs') is not null;
    elsif v_mt in ('jonli', 'joriy') and to_regclass('public.aros_qarzdor') is not null then
      v_man := 'Aros mijozlar hamyoni (aros_qarzdor.wallet_balance, faol): bizga oldindan berilgan pul';
      select coalesce(jsonb_agg(_bbd_row(
               coalesce(nullif(btrim(coalesce(a.ism, '') || ' ' || coalesce(a.familya, '')), ''), 'Mijoz #' || a.user_id),
               a.warehouse_nom, a.wallet_balance, null, null,
               nullif(concat_ws(' · ', case when nullif(a.telefon, '') is not null then a.telefon end,
                                 case when coalesce(a.total_debt, 0) > 0 then 'qarzi ' || _bb_fmt(a.total_debt) end), ''),
               null) order by a.wallet_balance desc), '[]'::jsonb)
        into v_rows
        from aros_qarzdor a
       where coalesce((to_jsonb(a) ->> 'faol')::boolean, true) and coalesce(a.wallet_balance, 0) <> 0;
    end if;

  elsif p_kod = 'yetk_qarz' then
    v_nomt := 'Yetkazuvchi'; v_qismt := 'Yuklar';
    if v_mt = 'snapshot' then
      v_sn := _bbd_snap(v_sana, 'Q2b');
      v_man := 'Aylanma snapshot ' || coalesce(v_sn ->> 'sana', '?') || ' (Q2b): yetkazuvchi kesimi (yuk qatorlaridan)';
      select coalesce(jsonb_agg(_bbd_row(g.yetk, g.soni::text || ' ta yuk', g.s, null, null,
                                        case when g.kyoq > 0 then g.kyoq || ' ta yukda kurs topilmadi' end, null)
                                order by g.s desc nulls last), '[]'::jsonb)
        into v_rows
        from (select coalesce(nullif(btrim(split_part(x ->> 'nom', ' · ', 1)), ''), '—') as yetk,
                     count(*) as soni, sum(nullif(x ->> 'summa_uzs', '')::numeric) as s,
                     count(*) filter (where (x ->> 'summa_uzs') is null) as kyoq
                from jsonb_array_elements(v_sn -> 'rows') x group by 1) g;
    elsif to_regclass('public.aros_yuk_snapshot') is not null and _bb_fn('yuk_kurslar', 'text[]')
          and (_bb_fn('yuk_tolangan_fc', 'jsonb') or _bb_fn('yuk_tolangan_summa', 'integer[]')) then
      v_man := 'Qarz sahifasi formulasi: nashr qilingan (posted) yuklar, 365 kun: narx × kurs − to''langan; yetkazuvchi kesimida';
      select coalesce(jsonb_agg(jsonb_build_object('id', s.yuk_id,
                        'valyuta', upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS')))), '[]'::jsonb),
             coalesce(array_agg(distinct upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS'))), '{}')
        into v_rowsj, v_curs
        from aros_yuk_snapshot s
       where s.mavjud = true and s.status = 'posted' and s.sana >= v_bugun - 365;
      execute 'select yuk_kurslar($1)' into v_kmap using v_curs;
      if _bb_fn('yuk_tolangan_fc', 'jsonb') then
        execute 'select yuk_tolangan_fc($1)' into v_paid using v_rowsj;
      else
        execute 'select yuk_tolangan_summa(array(select (x ->> ''id'')::integer from jsonb_array_elements($1) x))'
          into v_paid using v_rowsj;
      end if;
      with y as (
        select s.yuk_id,
               coalesce(nullif(btrim(s.yetkazuvchi), ''), '—') as yetk,
               upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS')) as cur,
               coalesce(s.narx, 0) as narx
          from aros_yuk_snapshot s
         where s.mavjud = true and s.status = 'posted' and s.sana >= v_bugun - 365
      ),
      p as (
        select (x ->> 'yuk_id')::integer as yuk_id,
               nullif(x ->> 'tolangan_fc', '')::numeric as tfc,
               coalesce(nullif(x ->> 'tolangan_uzs', '')::numeric, 0) as tuzs
          from jsonb_array_elements(coalesce(v_paid, '[]'::jsonb)) x
      ),
      k as (
        select kv.key as cur, nullif(kv.value, '')::numeric as kurs
          from jsonb_each_text(coalesce(v_kmap, '{}'::jsonb)) kv
      ),
      q as (
        select y.yuk_id, y.yetk, y.cur, y.narx, k.kurs, p.tfc, coalesce(p.tuzs, 0) as tuzs
          from y left join p on p.yuk_id = y.yuk_id left join k on k.cur = y.cur
      ),
      w as (
        select q.*,
               case when q.cur = 'UZS' then q.narx - q.tuzs
                    else q.narx - coalesce(q.tfc, q.tuzs / nullif(q.kurs, 0), 0) end as qol_fc
          from q
      ),
      z as (
        select w.*,
               case when w.kurs is null then 0
                    when w.cur <> 'UZS' and w.qol_fc <= w.narx * 0.015 then 0
                    else greatest(0, w.qol_fc) * w.kurs end as uzs,
               case when w.kurs is null then 0
                    when w.cur <> 'UZS' and w.qol_fc <= w.narx * 0.015 then 0
                    else greatest(0, w.qol_fc) end as qfc
          from w
      ),
      c as (
        select yetk, cur, sum(uzs) as uzs, sum(qfc) as qfc,
               count(*) filter (where uzs > 0) as soni,
               count(*) filter (where kurs is null and narx > 0) as kyoq
          from z group by yetk, cur
      ),
      g as (
        select yetk, sum(uzs) as uzs, sum(soni) as soni, sum(kyoq) as kyoq,
               string_agg(cur || ' ' || _bb_fmt(qfc), ' · ' order by cur) filter (where qfc > 0) as valyutalar,
               count(*) filter (where qfc > 0) as nval,
               max(cur) filter (where qfc > 0) as bir_val,
               sum(qfc) filter (where qfc > 0) as bir_fc
          from c group by yetk
      )
      select coalesce(jsonb_agg(_bbd_row(g.yetk, g.soni || ' ta yuk', g.uzs,
                        case when g.nval = 1 then g.bir_fc end, case when g.nval = 1 then g.bir_val end,
                        nullif(concat_ws(' · ', case when g.nval > 1 then g.valyutalar end,
                                         case when g.kyoq > 0 then g.kyoq || ' ta yukda kurs yo''q — hisobga olinmadi' end), ''),
                        null) order by g.uzs desc, g.yetk), '[]'::jsonb)
        into v_rows
        from g where g.uzs > 0 or g.kyoq > 0;
    else
      v_sn := _bbd_snap(v_sana, 'Q2b');
      v_man := 'Aylanma snapshot ' || coalesce(v_sn ->> 'sana', '?') || ' (Q2b) — jonli manba bazada yo''q';
      v_rows := v_sn -> 'rows';
    end if;
    v_sn2 := _bbd_daftar(v_sana, 'd6010');
    v_qosh := v_qosh || jsonb_build_array(jsonb_build_object(
      'sarlavha', 'Daftar 6010 (jamiga QO''SHILMAGAN)',
      'izoh', 'Provodka daftaridagi yetkazuvchilar hisobi — Qarz sahifasi formulasi ishlatiladi, ikki marta sanalmaydi',
      'jami', _bbd_sum(v_sn2), 'qatorlar', v_sn2));
    if _bb_fn('yetkazuvchi_avans_royxat', '') then
      begin
        execute 'select yetkazuvchi_avans_royxat()' into v_x;
        if coalesce((v_x ->> 'ok')::boolean, false) then
          select coalesce(jsonb_agg(_bbd_row(g.yetk, g.soni || ' ta to''lov', g.s, null, null, null, null) order by g.s desc), '[]'::jsonb)
            into v_sn
            from (select coalesce(nullif(btrim(r ->> 'yetkazuvchi'), ''), '—') as yetk, count(*) as soni,
                         sum(coalesce(nullif(r ->> 'summa_uzs', '')::numeric, 0)) as s
                    from jsonb_array_elements(coalesce(v_x -> 'rows', '[]'::jsonb)) r group by 1) g;
          if jsonb_array_length(v_sn) > 0 then
            v_qosh := v_qosh || jsonb_build_array(jsonb_build_object(
              'sarlavha', 'Yetkazuvchi avanslari (jamiga KIRMAGAN)',
              'izoh', 'Yukka bog''lanmagan tovar to''lovlari — Qarz sahifasida yetkazuvchi qarzidan ayiriladi, Balans B formulasida alohida hisoblanmagan',
              'jami', _bbd_sum(v_sn), 'qatorlar', v_sn));
          end if;
        end if;
      exception when others then null;   -- avans ro'yxati ma'lumot uchun: ruxsat / xato bo'lsa qo'shimcha bo'lim qo'shilmaydi
      end;
    end if;

  elsif p_kod = 'yolda_yuk' or p_kod = 'kelmagan_qarz' then
    v_nomt := 'Yetkazuvchi'; v_qismt := 'Yuk';
    if to_regclass('public.aros_yuk_snapshot') is not null and _bb_col('aros_yuk_snapshot', 'delivery_status')
       and _bb_fn('yuk_yolda_jami', '') then
      v_man := 'Yo''ldagi yuklar (yuk_yolda_jami manbasi): status posted / canceled emas, delivery_status = on_way; narx × joriy kurs';
      with cur as (
        select distinct upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS')) as cur
          from aros_yuk_snapshot s
         where s.mavjud = true and coalesce(s.status, '') <> 'posted' and coalesce(s.status, '') <> 'canceled'
           and s.delivery_status = 'on_way'
      ),
      kk as (
        select c.cur,
               _bbd_kurs(c.cur) as kurs
          from cur c
      )
      select coalesce(jsonb_agg(_bbd_row(
               coalesce(nullif(btrim(s.yetkazuvchi), ''), '—'),
               '#' || s.yuk_id,
               case when kk.kurs is not null then round(coalesce(s.narx, 0) * kk.kurs) end,
               coalesce(s.narx, 0),
               case when upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS')) <> 'UZS'
                    then upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS')) end,
               nullif(concat_ws(' · ', nullif(s.ombor, ''), to_char(s.sana, 'DD.MM.YYYY'),
                                case when kk.kurs is null then 'kurs topilmadi — hisobga olinmadi' end,
                                case when s.sana < v_bugun - 90 then '90 kundan eski (sinxron yangilamaydi)' end), ''),
               null) order by round(coalesce(s.narx, 0) * coalesce(kk.kurs, 0)) desc, s.yuk_id), '[]'::jsonb)
        into v_rows
        from aros_yuk_snapshot s
        left join kk on kk.cur = upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS'))
       where s.mavjud = true and coalesce(s.status, '') <> 'posted' and coalesce(s.status, '') <> 'canceled'
         and s.delivery_status = 'on_way';
    end if;
    if v_rows <> '[]'::jsonb then
      -- yetkazuvchi kesimi qo'shimcha bo'lim sifatida (yuk_yolda_jami().by_yetk bilan bir xil guruhlash)
      select coalesce(jsonb_agg(_bbd_row(g.yetk, g.soni || ' ta yuk', g.s, null, null, null, null) order by g.s desc nulls last), '[]'::jsonb)
        into v_sn
        from (select coalesce(nullif(x ->> 'nom', ''), '—') as yetk, count(*) as soni,
                     sum(coalesce(nullif(x ->> 'summa_uzs', '')::numeric, 0)) as s
                from jsonb_array_elements(v_rows) x group by 1) g;
      v_qosh := v_qosh || jsonb_build_array(jsonb_build_object(
        'sarlavha', 'Yetkazuvchi kesimida', 'izoh', 'Shu yuklarning yetkazuvchi bo''yicha yig''indisi (jamiga kirmaydi, takror)',
        'jami', _bbd_sum(v_sn), 'qatorlar', v_sn));
    end if;

  elsif p_kod = 'yolda_yuk_posted' then
    v_nomt := 'Yetkazuvchi · ombor'; v_qismt := 'Yuk';
    v_sn := _bbd_snap(v_sana, 'Y3a');
    v_man := 'Aylanma snapshot ' || coalesce(v_sn ->> 'sana', '?') || ' (Y3a): nashr qilingan, yo''lda yuklar';
    v_rows := v_sn -> 'rows';
    if v_sn ->> 'manba' = 'yoq' then v_ogoh := v_ogoh || to_jsonb('Aylanma snapshot (n8n) topilmadi.'::text); end if;

  elsif p_kod = 'ochiq_buyurtma' then
    v_nomt := 'Buyurtma'; v_qismt := 'ID';
    v_sn := _bbd_snap(v_sana, 'B6');
    v_man := 'Aylanma snapshot ' || coalesce(v_sn ->> 'sana', '?') || ' (B6): ochiq buyurtmalar, SOTUV narxida';
    v_rows := v_sn -> 'rows';
    if v_sn ->> 'manba' = 'yoq' then v_ogoh := v_ogoh || to_jsonb('Aylanma snapshot (n8n) topilmadi.'::text); end if;

  elsif p_kod = 'brak' then
    v_nomt := 'Ombor'; v_qismt := 'Ombor ID';
    v_sn := _bbd_snap(v_sana, 'T5');
    v_man := 'Aylanma snapshot ' || coalesce(v_sn ->> 'sana', '?') || ' (T5): brak omborlari, tannarxda (USD × kurs)';
    v_rows := v_sn -> 'rows';
    if v_sn ->> 'manba' = 'yoq' then v_ogoh := v_ogoh || to_jsonb('Aylanma snapshot (n8n) topilmadi.'::text); end if;

  elsif p_kod = 'kochirish' then
    v_nomt := 'Kimdan → kimga'; v_qismt := 'Holat';
    v_sn := _bbd_snap(v_sana, 'K3b', 'yo''lda (K3b)');
    v_sn2 := _bbd_snap(v_sana, 'K4', 'yaratilgan (K4)');
    v_man := 'Aylanma snapshot (K3b yo''lda + K4 yaratilgan ko''chirishlar)';
    v_rows := (v_sn -> 'rows') || (v_sn2 -> 'rows');
    if (v_sn ->> 'yashirin')::int + (v_sn2 ->> 'yashirin')::int > 0 then
      v_ogoh := v_ogoh || to_jsonb(((v_sn ->> 'yashirin')::int + (v_sn2 ->> 'yashirin')::int)::text
        || ' ta ko''chirish ochiq buyurtma (B6) ichida hisoblangan — bu yerda ko''rsatilmaydi.');
    end if;
    if v_sn ->> 'manba' = 'yoq' and v_sn2 ->> 'manba' = 'yoq' then
      v_ogoh := v_ogoh || to_jsonb('Aylanma snapshot (n8n) topilmadi.'::text);
    end if;

  elsif p_kod = 'kapital' or p_kod = 'jami_aktiv' or p_kod = 'jami_majburiyat' then
    v_nomt := 'Modda'; v_qismt := 'Bo''lim';
    v_man := case p_kod when 'kapital' then 'Hisoblangan: Aktiv − Majburiyat (balans_b qatorlari)'
                        when 'jami_aktiv' then 'Aktiv qatorlari yig''indisi (balans_b)'
                        else 'Majburiyat qatorlari yig''indisi (balans_b)' end;
    select coalesce(jsonb_agg(_bbd_row(x.nom, x.bolim || case when x.guruh = 'uzoq' then ' · uzoq muddatli' else '' end,
                      case when x.bolim = 'MAJBURIYAT' and p_kod = 'kapital' then -coalesce(x.summa, 0) else coalesce(x.summa, 0) end,
                      null, null,
                      nullif(concat_ws(' · ', case when x.bolim = 'MAJBURIYAT' and p_kod = 'kapital' then 'ayiriladi' end,
                                       case when x.summa is null then 'manba yo''q' end,
                                       case when x.manba = 'joriy' then 'joriy qiymat' end), ''),
                      null) order by x.ord), '[]'::jsonb)
      into v_rows
      from balans_b(v_sana, null) x
     where x.guruh <> 'jami'
       and (   (p_kod = 'kapital' and x.bolim in ('AKTIV', 'MAJBURIYAT'))
            or (p_kod = 'jami_aktiv' and x.bolim = 'AKTIV')
            or (p_kod = 'jami_majburiyat' and x.bolim = 'MAJBURIYAT'));
    if p_kod = 'kapital' then
      v_sn := _bbd_daftar(v_sana, 'kapital_h');
      v_qosh := v_qosh || jsonb_build_array(jsonb_build_object(
        'sarlavha', 'Daftar kapital hisoblari (8000 / 8710 / 8720 / 8900 ...)',
        'izoh', 'Faqat ma''lumot uchun: daftar to''liq emas (Aros / registr qatorlari daftarda yo''q), shuning uchun Kapital hisoblanadi, bu yig''indi bilan teng bo''lmasligi mumkin. 8900 vaqtinchalik hisob.',
        'jami', _bbd_sum(v_sn), 'qatorlar', v_sn));
    end if;

  else
    return jsonb_build_object('ok', false, 'kod', 'nomalum', 'error', 'Bu qator uchun tafsilot yo''q: ' || p_kod);
  end if;

  -- =========================== yakun ===========================
  v_rows := _bbd_cap(coalesce(v_rows, '[]'::jsonb), 1500);
  v_sum := _bbd_sum(v_rows);

  if v_jami is null then
    v_ogoh := v_ogoh || to_jsonb('Bu qator uchun manba bazada yo''q (balans_b da «—»).'::text);
  elsif abs(v_jami - v_sum) >= 1 then
    v_ogoh := v_ogoh || to_jsonb('Qatorlar yig''indisi ' || _bb_fmt(v_sum) || ', balansdagi qator ' || _bb_fmt(v_jami)
                                 || ' — farq ' || _bb_fmt(v_jami - v_sum) || ' so''m.');
  end if;
  if v_mt = 'joriy' and v_tarix and p_kod not in ('kapital', 'jami_aktiv', 'jami_majburiyat') then
    v_ogoh := v_ogoh || to_jsonb('Bu qator uchun tarixiy manba yo''q: ' || to_char(v_sana, 'DD.MM.YYYY')
                                 || ' sanasi uchun JORIY (hozirgi) qiymat ko''rsatilgan.'::text);
  end if;
  if v_mt = 'kiritilmagan' then
    v_ogoh := v_ogoh || to_jsonb('Bunday hisob daftarda ochilmagan (0).'::text);
  end if;
  if v_biz is not null and p_kod in ('mijoz_qarz') then
    v_ogoh := v_ogoh || to_jsonb(v_biz);
  end if;

  return jsonb_build_object(
    'ok', true, 'kod', p_kod, 'sarlavha', v_nom, 'sana', v_sana,
    'manba', v_man, 'manba_tur', v_mt,
    'jami', v_jami, 'qator_summa', v_sum,
    'ustunlar', jsonb_build_array(
      jsonb_build_object('k', 'nom', 't', v_nomt),
      jsonb_build_object('k', 'qism', 't', v_qismt),
      jsonb_build_object('k', 'summa_uzs', 't', 'So''m'),
      jsonb_build_object('k', 'fc', 't', 'Valyutada'),
      jsonb_build_object('k', 'izoh', 't', 'Izoh')),
    'qatorlar', v_rows,
    'qoshimcha', v_qosh,
    'ogoh', v_ogoh);
end
$bbd_main$;

revoke all on function balans_b_detal(text, date) from public, anon;
grant execute on function balans_b_detal(text, date) to authenticated;

comment on function balans_b_detal(text, date) is
  'Balans B / C qator tarkibi (drill-down): {ok, kod, sarlavha, manba, manba_tur, jami, qator_summa, ustunlar, qatorlar[], qoshimcha[], ogoh[]}. '
  'jami = balans_b(p_sana) qatori AYNAN; farq bo''lsa ogohda. Ruxsat balans_b bilan bir xil (_bb_ok).';


-- yo'ldagi yuk kursi: yuk_yolda_jami bilan bir xil (CHY = CNY; kurs yo'q yoki <= 0 = null)
create or replace function _bbd_kurs(p_cur text)
returns numeric
language plpgsql
stable
set search_path = public
as $bbd_kurs$
declare
  v_r numeric;
begin
  if upper(p_cur) = 'UZS' then return 1; end if;
  if not _bb_fn('conv_baza_kurs', 'text') then return null; end if;
  begin
    execute 'select conv_baza_kurs($1)' into v_r using case upper(p_cur) when 'CHY' then 'CNY' else upper(p_cur) end;
  exception when others then v_r := null;
  end;
  if v_r is not null and v_r <= 0 then v_r := null; end if;
  return v_r;
end
$bbd_kurs$;

revoke all on function _bbd_kurs(text) from public, anon, authenticated;

notify pgrst, 'reload schema';

-- ROLLBACK (faqat yangi funksiyalar):
--   drop function if exists balans_b_detal(text, date);
--   drop function if exists _bbd_kurs(text);
--   drop function if exists _bbd_sum(jsonb);
--   drop function if exists _bbd_qarz_ob(text);
--   drop function if exists _bbd_snap(date, text, text, text);
--   drop function if exists _bbd_hodim(date);
--   drop function if exists _bbd_daftar(date, text);
--   drop function if exists _bbd_fc(date);
--   drop function if exists _bbd_cap(jsonb, int);
--   drop function if exists _bbd_row(text, text, numeric, numeric, text, text, text);
