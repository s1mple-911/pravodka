-- =====================================================================
--  PROVODKA_BALANS_B_TUZATISH_20261107.sql
--  Balans B tuzatishlari (Asilbek, 2026-11-07 kechki tekshiruv: «hamma tuzatishni qil»)
-- =====================================================================
--  1) YETKAZUVCHILARGA QARZ — Qarz sahifasi bilan BIR XIL formula.
--     Eski _bb_val/balans_b_detal: faqat posted yuklar, 365 kun, narx − to'langan, 1.5% (10 $ chegarasiz),
--     tannarx (yuk_tannarx) va boshlang'ich qarz hujjatlari (yuk_qolda: BEST/haseb/Azizaka) YO'Q edi →
--     Ace balansda ¥3 998 668, Qarz sahifasida ¥4 285 826 (nashr qilingan qismi).
--     Yangi yetk_qarz_hisob(p_sana) — bitta manba: posted (aros_yuk_snapshot.mavjud) + yuk_qolda;
--     jami = round(narx × kurs) + tannarx; to'langan = tolangan_fc × kurs (valyutada) yoki so'm;
--     qoldiq < min(max(1, jami × 1.5%), 10 $) → 0 (UZS da 1 so'm). qarzdor-dev.html qoldiqUzs() bilan aynan.
--     _bb_val va balans_b_detal shu funksiyadan o'qiydi (snapshot/tarixiy sana mantiqi o'zgarmagan).
--  2) OCHIQ BUYURTMALAR — guruh 'malumot': ko'rsatiladi, lekin Jami aktiv / Kapitalga KIRMAYDI
--     (tovar hali omborda — «Tovar zaxiralari» ichida; sotuv narxida qo'shish ikki marta sanash edi).
--  Hammasi additive (create or replace, yangi funksiya); daftar/kassa/jurnalga tegilmaydi.
--  Izohlarda ketma-ket dollar belgi yozilmagan.
-- =====================================================================

do $bbt_pre$
begin
  if to_regprocedure('_bb_val(date)') is null or to_regprocedure('balans_b_detal(text,date)') is null then
    raise exception 'Balans B yoq — avval PROVODKA_BALANS_B_CASHFLOW_B_20261107.sql va PROVODKA_BALANS_B_DETAL_20261107.sql';
  end if;
  if to_regclass('public.aros_yuk_snapshot') is null or to_regclass('public.yuk_qolda') is null
     or to_regclass('public.yuk_tannarx') is null then
    raise exception 'aros_yuk_snapshot / yuk_qolda / yuk_tannarx jadvali yoq';
  end if;
  if to_regprocedure('yuk_tolangan_fc(jsonb)') is null or to_regprocedure('yuk_kurslar(text[])') is null then
    raise exception 'yuk_tolangan_fc / yuk_kurslar RPC yoq (PROVODKA_YUK_TOLOV_VALYUTA.sql)';
  end if;
end
$bbt_pre$;


-- #####################################################################
-- ##  1 — yetk_qarz_hisob(p_sana): Qarz sahifasi formulasi, hujjat kesimida ##
-- #####################################################################

create or replace function yetk_qarz_hisob(p_sana date default null)
returns table(yuk_id integer, yetk text, cur text, narx numeric, kurs numeric, tannarx_uzs numeric,
              tolangan_uzs numeric, jami_uzs numeric, qoldiq_uzs numeric, qoldiq_fc numeric,
              qolda boolean, sana date)
language plpgsql
stable
security definer
set search_path = public
as $bbt_yetk$
declare
  v_rows  jsonb := '[]'::jsonb;
  v_curs  text[] := '{}';
  v_kmap  jsonb := '{}'::jsonb;
  v_paid  jsonb := '[]'::jsonb;
  v_usd   numeric;
  v_cap   numeric;
begin
  -- hujjatlar: nashr qilingan Aros yuklari + boshlang'ich (qo'lda) qarz hujjatlari
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'valyuta', t.cur)), '[]'::jsonb),
         coalesce(array_agg(distinct t.cur), '{}')
    into v_rows, v_curs
    from (
      select s.yuk_id as id, upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS')) as cur
        from aros_yuk_snapshot s where s.mavjud = true and s.status = 'posted'
      union all
      select q.id, upper(coalesce(nullif(btrim(q.valyuta), ''), 'UZS'))
        from yuk_qolda q where not q.is_deleted
    ) t;
  if cardinality(v_curs) > 0 then
    v_kmap := coalesce(yuk_kurslar(v_curs), '{}'::jsonb);
  end if;
  v_paid := coalesce(yuk_tolangan_fc(v_rows), '[]'::jsonb);
  begin
    execute 'select conv_baza_kurs($1)' into v_usd using 'USD';
  exception when others then v_usd := null;
  end;
  v_cap := case when v_usd > 0 then v_usd * 10 else 120000 end;   -- qarzdor-dev kursFarqiCapUzs()

  return query
  with y as (
    select s.yuk_id as id, coalesce(nullif(btrim(s.yetkazuvchi), ''), '—') as yetk,
           upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS')) as cur, coalesce(s.narx, 0)::numeric as narx,
           false as qolda, s.sana::date as sana
      from aros_yuk_snapshot s where s.mavjud = true and s.status = 'posted'
    union all
    select q.id, coalesce(nullif(btrim(q.yetkazuvchi), ''), '—'),
           upper(coalesce(nullif(btrim(q.valyuta), ''), 'UZS')), coalesce(q.narx, 0)::numeric, true, q.sana
      from yuk_qolda q where not q.is_deleted
  ),
  p as (
    select (x ->> 'yuk_id')::integer as id,
           nullif(x ->> 'tolangan_fc', '')::numeric as tfc,
           coalesce(nullif(x ->> 'tolangan_uzs', '')::numeric, 0) as tuzs
      from jsonb_array_elements(v_paid) x
  ),
  k as (
    select kv.key as cur, nullif(kv.value, '')::numeric as kurs from jsonb_each_text(v_kmap) kv
  ),
  t as (
    select yt.yuk_id as id, sum(yt.summa_uzs)::numeric as tan from yuk_tannarx yt where not yt.is_deleted group by yt.yuk_id
  ),
  w as (
    select y.*, case when y.cur = 'UZS' then 1::numeric else k.kurs end as k2,
           coalesce(t.tan, 0) as tan, p.tfc, coalesce(p.tuzs, 0) as tuzs
      from y left join k on k.cur = y.cur left join t on t.id = y.id left join p on p.id = y.id
  ),
  z as (
    select w.*,
           case when w.k2 is null then null else round(w.narx * w.k2) + w.tan end as jami,
           case when w.k2 is null then null
                when w.cur <> 'UZS' and w.tfc is not null then w.tfc * w.k2
                else w.tuzs end as tol
      from w
  ),
  f as (
    select z.*, (z.jami - z.tol) as q,
           case when z.cur = 'UZS' then 1::numeric else least(greatest(1, z.jami * 0.015), v_cap) end as lim
      from z
  )
  select f.id, f.yetk, f.cur, f.narx, f.k2, f.tan, f.tol, f.jami,
         case when f.jami is null then null when f.q < f.lim then 0 else f.q end,
         case when f.jami is null or coalesce(f.k2, 0) = 0 then null when f.q < f.lim then 0 else f.q / f.k2 end,
         f.qolda, f.sana
    from f;
end
$bbt_yetk$;

revoke all on function yetk_qarz_hisob(date) from public, anon;
grant execute on function yetk_qarz_hisob(date) to authenticated;
comment on function yetk_qarz_hisob(date) is
  'Yetkazuvchi qarzi hujjat kesimida — qarzdor-dev.html qoldiqUzs() bilan AYNAN bir formula. '
  'Balans B (_bb_val) va balans_b_detal shu funksiyadan oqiydi (2026-11-07).';


-- #####################################################################
-- ##  2 — _bb_val: Q2b yetk_qarz_hisob dan; ochiq_buyurtma izohi        ##
-- #####################################################################

create or replace function _bb_val(p_sana date)
returns table(kod text, summa numeric, manba text, izoh text)
language plpgsql
stable
security definer
set search_path = public
as $bb_val$
declare
  v_bugun  date := (now() at time zone 'Asia/Tashkent')::date;
  v_jonli  boolean;
  v_out    jsonb := '[]'::jsonb;
  v_kurs   numeric;
  r        record;
  -- snapshot
  v_ex_id  uuid;  v_ex_sana date;  v_ex jsonb;
  v_la_id  uuid;  v_la_sana date;  v_la jsonb;
  v_pk     jsonb;
  v_n      numeric;
  v_n2     numeric;
  v_m      text;
  v_i      text;
  v_use_ex boolean;
  v_has_q  boolean;
  -- Aros qarzdor
  v_aros   numeric;  v_ham numeric;  v_aros_m text;
  -- Q2b
  v_q2b    numeric;  v_q2b_m text;  v_q2b_i text;
  v_rows   jsonb;    v_paid jsonb;  v_kmap jsonb;  v_curs text[];
  v_kyoq   int;
  -- yo'ldagi yuk
  v_yy     jsonb;
  v_yolda_yuk numeric;
  v_yolda_m   text;
begin
  if not _bb_ok() then
    raise exception 'Ruxsat yo''q (balans sahifasi, kassa doirasi: hamma)' using errcode = '42501';
  end if;
  if p_sana is null then p_sana := v_bugun; end if;
  v_jonli := p_sana >= v_bugun;

  -- ---------- kurs (USD) ----------
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

  -- ---------- snapshot'lar ----------
  v_ex := null; v_la := null;
  if to_regclass('public.aylanma_snapshot') is not null then
    select s.id, s.sana, s.bolimlar into v_ex_id, v_ex_sana, v_ex
      from aylanma_snapshot s where s.sana = p_sana order by s.hisoblangan_at desc limit 1;
    select s.id, s.sana, s.bolimlar into v_la_id, v_la_sana, v_la
      from aylanma_snapshot s order by s.sana desc, s.hisoblangan_at desc limit 1;
  end if;

  -- ---------- DAFTAR (tarixiy aniq) ----------
  select
    coalesce(sum(s.b) filter (where h.section = 'pul' and not h.hodim), 0)                                   as pul,
    coalesce(sum(s.b) filter (where h.section = 'pul' and h.hodim), 0)                                       as hodim_pul,
    coalesce(sum(s.b) filter (where h.section = 'tovar'), 0)                                                 as tovar,
    coalesce(sum(s.b) filter (where h.code = '4010'), 0)                                                     as d4010,
    coalesce(sum(s.b) filter (where h.code ~ '^47[0-9][0-9]$'), 0)                                           as qarz47,
    coalesce(sum(s.b) filter (where h.bolim = 'uzoq_aktiv'), 0)                                              as uzoq_aktiv,
    count(distinct h.id) filter (where h.bolim = 'uzoq_aktiv')                                               as uzoq_n,
    coalesce(sum(s.b) filter (where h.bolim = 'joriy_aktiv' and h.section not in ('pul', 'tovar')
                                and h.code <> '4010' and h.code !~ '^47[0-9][0-9]$'), 0)                      as boshqa_aktiv,
    coalesce(sum(-s.b) filter (where h.code ~ '^6820'), 0)                                                   as olingan,
    coalesce(sum(-s.b) filter (where h.code = '6010'), 0)                                                    as d6010,
    coalesce(sum(-s.b) filter (where h.bolim = 'joriy_majburiyat'
                                and h.section in ('soliq_majb', 'oylik_majb')), 0)                            as ish_soliq,
    count(distinct h.id) filter (where h.bolim = 'joriy_majburiyat'
                                and h.section in ('soliq_majb', 'oylik_majb'))                                as ish_soliq_n,
    coalesce(sum(-s.b) filter (where h.bolim = 'uzoq_majburiyat'), 0)                                        as uzoq_majb,
    count(distinct h.id) filter (where h.bolim = 'uzoq_majburiyat')                                          as uzoq_majb_n,
    coalesce(sum(-s.b) filter (where h.bolim = 'joriy_majburiyat' and h.code <> '6010' and h.code !~ '^6820'
                                and h.section not in ('soliq_majb', 'oylik_majb')
                                and h.code <> '8900' and h.name not ilike '%vaqtinchalik%'), 0)               as boshqa_majb
    into r
    from _bb_saldo(p_sana) s
    join _bb_hisob() h on h.id = s.account_id;

  v_out := v_out
    || _bb_r('pul', r.pul, 'daftar', 'Hodim kassalarisiz (alohida qator)')
    || _bb_r('hodim_pul', r.hodim_pul, 'daftar', '5400 konteyner ostidagi hodim kassalari')
    || _bb_r('tovar', r.tovar, 'daftar', null)
    || _bb_r('berilgan_qarz', r.qarz47, 'daftar', '4710 / 4720 (Qarz sahifasi, Q2a provodka qismi)')
    || _bb_r('boshqa_aktiv', r.boshqa_aktiv, 'daftar', null)
    || _bb_r('olingan_qarz', r.olingan, 'daftar', '6820')
    || _bb_r('boshqa_majb', r.boshqa_majb, 'daftar', '6010 va 6820 dan boshqa majburiyat hisoblari')
    || _bb_r('x_d4010', r.d4010, 'daftar', null)
    || _bb_r('x_d6010', r.d6010, 'daftar', null)
    || _bb_r('uzoq_aktiv', case when r.uzoq_n = 0 then 0 else r.uzoq_aktiv end,
             case when r.uzoq_n = 0 then 'kiritilmagan' else 'daftar' end,
             case when r.uzoq_n = 0 then 'balans_bolimi=uzoq_aktiv hisobi yo''q' else null end)
    || _bb_r('ish_soliq', case when r.ish_soliq_n = 0 then 0 else r.ish_soliq end,
             case when r.ish_soliq_n = 0 then 'kiritilmagan' else 'daftar' end,
             case when r.ish_soliq_n = 0 then 'soliq / oylik majburiyat hisobi yo''q' else null end)
    || _bb_r('uzoq_majb', case when r.uzoq_majb_n = 0 then 0 else r.uzoq_majb end,
             case when r.uzoq_majb_n = 0 then 'kiritilmagan' else 'daftar' end,
             case when r.uzoq_majb_n = 0 then 'balans_bolimi=uzoq_majburiyat hisobi yo''q' else null end);

  -- ---------- B: yo'ldagi pul ----------
  v_n := null; v_m := 'yoq'; v_i := null;
  v_use_ex := (not v_jonli) and jsonb_typeof(v_ex -> 'B') = 'object';
  if v_use_ex then
    v_n := (v_ex -> 'B' ->> 'uzs')::numeric; v_m := 'snapshot'; v_i := 'Snapshot ' || v_ex_sana::text;
  elsif to_regclass('public.aros_transfer_yolda') is not null then
    select coalesce(sum(coalesce(t.s_cash, 0) + coalesce(t.s_click, 0) + coalesce(t.s_payme, 0)
                        + coalesce(t.s_usd, 0) * coalesce(v_kurs, 0)), 0),
           coalesce(sum(coalesce(t.s_usd, 0)) filter (where coalesce(t.s_usd, 0) <> 0), 0)
      into v_n, v_n2
      from aros_transfer_yolda t where t.status = 'sent';
    v_m := case when v_jonli then 'jonli' else 'joriy' end;
    if v_kurs is null and coalesce(v_n2, 0) <> 0 then
      v_i := 'USD kursi topilmadi — dollar qismi hisobga olinmadi';
    end if;
  end if;
  v_out := v_out || _bb_r('yolda_pul', v_n, v_m, v_i);

  -- ---------- Aros qarzdor (Q2a) ----------
  v_aros := null; v_ham := null; v_aros_m := 'yoq';
  v_has_q := false;
  if (not v_jonli) and v_ex_id is not null and to_regclass('public.aylanma_qator') is not null then
    if jsonb_typeof(v_ex -> 'Q2a') = 'object' then
      select exists (select 1 from aylanma_qator q where q.snapshot_id = v_ex_id and q.bolim = 'Q2a' and q.ref = 'aros')
        into v_has_q;
    end if;
  end if;
  if v_has_q then
    select q.uzs into v_aros from aylanma_qator q where q.snapshot_id = v_ex_id and q.bolim = 'Q2a' and q.ref = 'aros' limit 1;
    select -q.uzs into v_ham  from aylanma_qator q where q.snapshot_id = v_ex_id and q.bolim = 'Q2a' and q.ref = 'aros_hamyon' limit 1;
    v_ham := coalesce(v_ham, 0);
    v_aros_m := 'snapshot';
  else
    if to_regclass('public.aros_qarzdor_sync') is not null then
      select (s.summary ->> 'total_debt')::numeric, (s.summary ->> 'total_wallet_balance')::numeric
        into v_aros, v_ham
        from aros_qarzdor_sync s where s.id = 1;
      if v_aros is not null then v_ham := coalesce(v_ham, 0); end if;
    end if;
    if v_aros is null and to_regclass('public.aros_qarzdor') is not null then
      select coalesce(sum(a.total_debt), 0), coalesce(sum(a.wallet_balance), 0)
        into v_aros, v_ham
        from aros_qarzdor a
       where coalesce((to_jsonb(a) ->> 'faol')::boolean, true);
    end if;
    if v_aros is not null then
      v_aros_m := case when v_jonli then 'jonli' else 'joriy' end;
    end if;
  end if;
  v_out := v_out || _bb_r('x_aros_qarz', v_aros, v_aros_m, null);
  if v_aros is not null then
    v_out := v_out
      || _bb_r('mijoz_qarz', v_aros, v_aros_m, 'Daftar 4010: ' || _bb_fmt(r.d4010) || ' (qo''shilmaydi — Aros manbasi ishlatildi)')
      || _bb_r('mijoz_avans', v_ham, v_aros_m, 'Aros mijozlar hamyoni (bizga oldindan berilgan pul)');
  else
    v_out := v_out
      || _bb_r('mijoz_qarz', r.d4010, 'daftar', 'Aros manbasi yo''q — faqat daftar 4010')
      || _bb_r('mijoz_avans', null, 'yoq', 'Aros hamyon manbasi yo''q');
  end if;

  -- ---------- Q2b: yetkazuvchilarga qarz (2026-11-07: Qarz sahifasi bilan BIR XIL — yetk_qarz_hisob) ----------
  v_q2b := null; v_q2b_m := 'yoq'; v_q2b_i := null;
  v_use_ex := (not v_jonli) and jsonb_typeof(v_ex -> 'Q2b') = 'object';
  if v_use_ex then
    v_q2b := (v_ex -> 'Q2b' ->> 'uzs')::numeric; v_q2b_m := 'snapshot'; v_q2b_i := 'Snapshot ' || v_ex_sana::text;
  elsif to_regprocedure('yetk_qarz_hisob(date)') is not null then
    select coalesce(sum(h.qoldiq_uzs), 0), count(*) filter (where h.qoldiq_uzs is null and h.narx > 0)
      into v_q2b, v_kyoq
      from yetk_qarz_hisob(v_bugun) h;
    v_q2b_m := case when v_jonli then 'jonli' else 'joriy' end;
    v_q2b_i := 'Qarz sahifasi bilan bir xil: nashr qilingan yuklar + boshlang''ich qarz hujjatlari; '
               || 'narx × kurs + tannarx − to''langan (1.5% / 10 $ qoidasi). Daftar 6010: ' || _bb_fmt(r.d6010)
               || case when coalesce(v_kyoq, 0) > 0 then '; ' || v_kyoq || ' ta yukda kurs yo''q — hisobga olinmadi' else '' end;
  elsif jsonb_typeof(v_la -> 'Q2b') = 'object' then
    v_q2b := (v_la -> 'Q2b' ->> 'uzs')::numeric; v_q2b_m := 'joriy'; v_q2b_i := 'Snapshot ' || v_la_sana::text;
  end if;
  v_out := v_out
    || _bb_r('yetk_qarz', v_q2b, v_q2b_m, coalesce(v_q2b_i, 'Daftar 6010: ' || _bb_fmt(r.d6010)))
    || _bb_r('x_q2b', v_q2b, v_q2b_m, null);

  -- ---------- yo'ldagi yuk (yuk_yolda_jami) ----------
  v_yolda_yuk := null; v_yolda_m := 'yoq';
  if _bb_fn('yuk_yolda_jami', '') then
    begin
      execute 'select yuk_yolda_jami()' into v_yy;
      if coalesce((v_yy ->> 'ok')::boolean, false) then
        v_yolda_yuk := (v_yy ->> 'jami_uzs')::numeric;
        v_yolda_m := case when v_jonli then 'jonli' else 'joriy' end;
      end if;
    exception when others then
      v_yolda_yuk := null; v_yolda_m := 'yoq';
    end;
  end if;
  v_out := v_out
    || _bb_r('yolda_yuk', v_yolda_yuk, v_yolda_m,
             case when v_yolda_yuk is null then 'yuk_yolda_jami() bazada yo''q yoki ruxsat yo''q'
                  else (v_yy ->> 'soni') || ' ta yuk' end)
    || _bb_r('kelmagan_qarz', v_yolda_yuk, v_yolda_m, 'Aktivdagi «Yo''ldagi yuk» bilan teng');

  -- ---------- n8n snapshot qatorlari ----------
  v_pk := _bb_pick(v_ex, v_la, 'Y3a');
  v_out := v_out || _bb_r('yolda_yuk_posted', (v_pk ->> 'v')::numeric, v_pk ->> 'm',
                          'Nashr qilingan, yo''lda (Q2b ichida qarz sifatida bor)');
  v_pk := _bb_pick(v_ex, v_la, 'B6');
  v_out := v_out || _bb_r('ochiq_buyurtma', (v_pk ->> 'v')::numeric, v_pk ->> 'm',
                          'Sotuv narxida — MA''LUMOT, jamiga kirmaydi (tovar hali omborda, «Tovar zaxiralari» ichida)');
  v_pk := _bb_pick(v_ex, v_la, 'T5');
  v_out := v_out || _bb_r('brak', (v_pk ->> 'v')::numeric, v_pk ->> 'm', 'Tannarxda');

  v_n := null; v_m := 'yoq';
  v_pk := _bb_pick(v_ex, v_la, 'K3b');
  v_n := (v_pk ->> 'v')::numeric; v_m := v_pk ->> 'm';
  v_pk := _bb_pick(v_ex, v_la, 'K4');
  if (v_pk ->> 'v') is not null then
    v_n := coalesce(v_n, 0) + (v_pk ->> 'v')::numeric;
    if v_m = 'yoq' or (v_pk ->> 'm') = 'joriy' then v_m := v_pk ->> 'm'; end if;
  end if;
  v_out := v_out || _bb_r('kochirish', v_n, v_m, 'Yo''lda (K3b) + yaratilgan (K4) ko''chirish');

  v_pk := _bb_pick(v_ex, v_la, 'T1');
  v_out := v_out || _bb_r('x_t1', (v_pk ->> 'v')::numeric, v_pk ->> 'm', null);

  return query
    select x ->> 'kod', nullif(x ->> 'summa', '')::numeric, x ->> 'manba', x ->> 'izoh'
      from jsonb_array_elements(v_out) x;
end
$bb_val$;

revoke all on function _bb_val(date) from public, anon, authenticated;


-- #####################################################################
-- ##  3 — balans_b: ochiq_buyurtma guruh 'malumot' (jamiga kirmaydi)   ##
-- #####################################################################

create or replace function balans_b(p_sana date default null, p_solishtir date default null)
returns table(ord int, bolim text, guruh text, kod text, nom text, summa numeric, solishtir numeric,
              manba text, solishtir_manba text, teglar text[], izoh text, hisoblar text)
language plpgsql
stable
security definer
set search_path = public
as $bb_balans$
declare
  v_sana date := coalesce(p_sana, (now() at time zone 'Asia/Tashkent')::date);
begin
  if not _bb_ok() then
    raise exception 'Ruxsat yo''q (balans sahifasi, kassa doirasi: hamma)' using errcode = '42501';
  end if;

  return query
  with meta(o, b, g, k, n, teg, hs) as (
    values
      (10,  'AKTIV',      'joriy', 'pul',              'Pul mablag''lari',                 null,            null),
      (11,  'AKTIV',      'joriy', 'yolda_pul',        'Yo''ldagi pul',                    'Aros',          null),
      (12,  'AKTIV',      'joriy', 'mijoz_qarz',       'Mijozlar qarzi',                   'Aros',          '4010'),
      (13,  'AKTIV',      'joriy', 'hodim_pul',        'Hodimlar hisobidagi pul',          null,            '5400'),
      (14,  'AKTIV',      'joriy', 'berilgan_qarz',    'Berilgan qarzlar',                 null,            '4710,4720'),
      (15,  'AKTIV',      'malumot', 'ochiq_buyurtma', 'Ochiq buyurtmalar',                'sotuv narxida', null),
      (16,  'AKTIV',      'joriy', 'tovar',            'Tovar zaxiralari',                 null,            null),
      (17,  'AKTIV',      'joriy', 'kochirish',        'Ko''chirishdagi tovar',            'Aros',          null),
      (18,  'AKTIV',      'joriy', 'yolda_yuk',        'Yo''ldagi yuk',                    'Aros',          null),
      (19,  'AKTIV',      'joriy', 'yolda_yuk_posted', 'Yo''ldagi yuk (nashr qilingan)',   'Aros',          null),
      (20,  'AKTIV',      'joriy', 'brak',             'Brak',                             'Aros',          null),
      (21,  'AKTIV',      'joriy', 'boshqa_aktiv',     'Boshqa aktivlar',                  null,            null),
      (30,  'AKTIV',      'uzoq',  'uzoq_aktiv',       'Asosiy vositalar / nomoddiy',      null,            null),
      (110, 'MAJBURIYAT', 'joriy', 'yetk_qarz',        'Yetkazuvchilarga qarz',            'Aros',          '6010'),
      (111, 'MAJBURIYAT', 'joriy', 'kelmagan_qarz',    'Kelmagan yukdan qarz',             'Aros',          null),
      (112, 'MAJBURIYAT', 'joriy', 'mijoz_avans',      'Mijozlardan avans',                'Aros',          null),
      (113, 'MAJBURIYAT', 'joriy', 'olingan_qarz',     'Olingan qarzlar',                  null,            '6820'),
      (114, 'MAJBURIYAT', 'joriy', 'ish_soliq',        'Ish haqi va soliq',                null,            null),
      (115, 'MAJBURIYAT', 'joriy', 'boshqa_majb',      'Boshqa majburiyatlar',             null,            null),
      (130, 'MAJBURIYAT', 'uzoq',  'uzoq_majb',        'Uzoq muddatli majburiyatlar',      null,            null)
  ),
  a as (select * from _bb_val(v_sana)),
  c as (select * from _bb_val(p_solishtir) where p_solishtir is not null),
  base as (
    select m.o, m.b, m.g, m.k, m.n,
           a.summa as s1, c.summa as s2, a.manba as m1, c.manba as m2,
           array_remove(array[
             m.teg,
             case when a.manba = 'joriy' then 'joriy' end,
             case when a.manba = 'kiritilmagan' then 'kiritilmagan' end,
             case when a.manba = 'yoq' then 'manba yo''q' end], null) as tg,
           a.izoh as iz, m.hs
      from meta m
      left join a on a.kod = m.k
      left join c on c.kod = m.k
  ),
  tot as (
    select 40 as o, 'AKTIV' as b, 'jami' as g, 'jami_aktiv' as k, 'Jami aktiv' as n,
           sum(s1) as s1, case when p_solishtir is null then null else sum(s2) end as s2
      from base where b = 'AKTIV' and g <> 'malumot'
    union all
    select 140, 'MAJBURIYAT', 'jami', 'jami_majburiyat', 'Jami majburiyat',
           sum(s1), case when p_solishtir is null then null else sum(s2) end
      from base where b = 'MAJBURIYAT'
  ),
  cap as (
    select 200 as o, 'KAPITAL' as b, 'jami' as g, 'kapital' as k, 'Kapital (Aktiv − Majburiyat)' as n,
           (select s1 from tot where k = 'jami_aktiv') - (select s1 from tot where k = 'jami_majburiyat') as s1,
           case when p_solishtir is null then null
                else (select s2 from tot where k = 'jami_aktiv') - (select s2 from tot where k = 'jami_majburiyat') end as s2
  )
  select x.o::int, x.b, x.g, x.k, x.n, x.s1, x.s2, x.m1, x.m2, x.tg, x.iz, x.hs
    from (
      select base.o, base.b, base.g, base.k, base.n, base.s1, base.s2, base.m1, base.m2, base.tg, base.iz, base.hs from base
      union all
      select tot.o, tot.b, tot.g, tot.k, tot.n, tot.s1, tot.s2, null::text, null::text, array[]::text[], null::text, null::text from tot
      union all
      select cap.o, cap.b, cap.g, cap.k, cap.n, cap.s1, cap.s2, null::text, null::text, array['hisoblangan']::text[],
             'Daftar to''liq emas (Aros / registr qatorlari daftarda yo''q) — kapital aktiv va majburiyat farqidan hisoblanadi', null::text from cap
    ) x
   order by x.o;
end
$bb_balans$;

-- grantlar o'zgarmagan (PROVODKA_BALANS_B_CASHFLOW_B_20261107.sql)


-- #####################################################################
-- ##  4 — balans_b_detal: yetk_qarz tafsiloti yetk_qarz_hisob dan      ##
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
    elsif to_regprocedure('yetk_qarz_hisob(date)') is not null then
      -- 2026-11-07: Qarz sahifasi bilan BIR XIL formula (yetk_qarz_hisob): nashr qilingan yuklar + boshlang'ich
      -- qarz hujjatlari (yuk_qolda), narx × kurs + tannarx − to'langan, 1.5% / 10 $ qoidasi, 365 kun chegarasi YO'Q.
      v_man := 'Qarz sahifasi bilan bir xil: nashr qilingan yuklar + boshlang''ich qarz hujjatlari; narx × kurs + tannarx − to''langan (1.5% / 10 $); yetkazuvchi kesimida';
      with c as (
        select h.yetk, h.cur,
               sum(coalesce(h.qoldiq_uzs, 0)) as uzs,
               sum(coalesce(h.qoldiq_fc, 0))  as qfc,
               count(*) filter (where h.qoldiq_uzs > 0)                      as soni,
               count(*) filter (where h.qoldiq_uzs is null and h.narx > 0)   as kyoq,
               count(*) filter (where h.qolda and h.qoldiq_uzs > 0)          as qolda_n
          from yetk_qarz_hisob(v_bugun) h
         group by h.yetk, h.cur
      ),
      g as (
        select yetk, sum(uzs) as uzs, sum(soni) as soni, sum(kyoq) as kyoq, sum(qolda_n) as qolda_n,
               string_agg(cur || ' ' || _bb_fmt(qfc), ' · ' order by cur) filter (where qfc > 0) as valyutalar,
               count(*) filter (where qfc > 0) as nval,
               max(cur) filter (where qfc > 0) as bir_val,
               sum(qfc) filter (where qfc > 0) as bir_fc
          from c group by yetk
      )
      select coalesce(jsonb_agg(_bbd_row(g.yetk, g.soni || ' ta hujjat', g.uzs,
                        case when g.nval = 1 then g.bir_fc end, case when g.nval = 1 then g.bir_val end,
                        nullif(concat_ws(' · ', case when g.nval > 1 then g.valyutalar end,
                                         case when g.qolda_n > 0 then g.qolda_n || ' ta boshlang''ich qarz hujjati' end,
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

-- grantlar o'zgarmagan (PROVODKA_BALANS_B_DETAL_20261107.sql)


-- #####################################################################
-- ##  5 — sxema keshi + tekshiruv                                      ##
-- #####################################################################

notify pgrst, 'reload schema';

do $bbt_check$
declare v_src text; v_n int;
begin
  select pg_get_functiondef('_bb_val(date)'::regprocedure) into v_src;
  if position('yetk_qarz_hisob' in v_src) = 0 then raise exception '_bb_val yangilanmadi'; end if;
  select pg_get_functiondef('balans_b_detal(text,date)'::regprocedure) into v_src;
  if position('yetk_qarz_hisob' in v_src) = 0 then raise exception 'balans_b_detal yangilanmadi'; end if;
  select pg_get_functiondef('balans_b(date,date)'::regprocedure) into v_src;
  if position('malumot' in v_src) = 0 then raise exception 'balans_b yangilanmadi'; end if;
  select count(*) into v_n from yetk_qarz_hisob(null);
  raise notice 'OK: yetk_qarz_hisob % hujjat; _bb_val, balans_b, balans_b_detal yangilandi', v_n;
end
$bbt_check$;

select h.yetk, count(*) filter (where h.qoldiq_uzs > 0) as hujjat, round(sum(coalesce(h.qoldiq_uzs, 0))) as qoldiq_uzs,
       round(sum(coalesce(h.qoldiq_fc, 0)), 2) as qoldiq_fc, max(h.cur) as cur
  from yetk_qarz_hisob(null) h
 group by h.yetk having sum(coalesce(h.qoldiq_uzs, 0)) > 0
 order by 3 desc limit 15;
