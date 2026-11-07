-- =====================================================================
-- PROVODKA_BALANS_B_CASHFLOW_B_20261107.sql  (2026-11-07, faqat dev, RUN kutilmoqda)
-- Balans B (boshqaruv balansi) + Balans sog'ligi + Cashflow B (IAS 7, to'g'ridan-to'g'ri usul).
-- ---------------------------------------------------------------------
-- ## ASOSIY QOIDA (Asilbek): eski Balans/Cashflow, jurnal, kassalar, eski yozuvlar O'ZGARMAYDI.
--   * Hammasi ADDITIVE: faqat YANGI funksiyalar. balans(), cashflow(), cashflow_kassa(),
--     pul_qoldiq*() ga TEGILMAYDI. Hech qanday jadval/ustun/trigger yaratilmaydi, yozuv YOZILMAYDI.
--   * Idempotent (create or replace). Anonim DO bloki YO'Q. Funksiya tanalari NOMLI teg bilan.
--   * Sahifalar (balans-dev.html / cashflow-dev.html) B rejimida shu RPC'larni chaqiradi;
--     RPC yo'q bo'lsa «SQL RUN kutilmoqda» banneri chiqadi, A rejimi ishlayveradi.
--
-- ## RUN TARTIBI
--   1) PROVODKA_HISOB_MAYDONLAR_20261107.sql   (A1: balans_bolimi / cf_modda / entry_type / v_entry_turi / provodka_kuzatuv)
--   2) PROVODKA_YUK_YOLDA_QARZ_20261107.sql    (yuk_yolda_jami)
--   3) SHU FAYL                                (A1/A2 RUN bo'lmasa ham yiqilmaydi: yetishmagan ustun/funksiya
--                                               dinamik aniqlanadi, tegishli qator «manba yo'q» bo'ladi)
--   Shu fayl A1'dan KEYIN RUN qilinsa to'liq aniq ishlaydi; oldin RUN qilinsa ham xavfsiz, A1 RUN bo'lgach
--   qayta RUN qilish SHART EMAS (funksiyalar har chaqiruvda ustun mavjudligini tekshiradi).
--
-- ## BALANS B — qaysi qator qayerdan (sana = p_sana)
--   DAFTAR (entry_date <= sana, posted, o'chirilmagan; tarixiy aniq):
--     pul (section=pul, hodim kassalarisiz) · hodim_pul (5400 konteyner avlodlari) · tovar (section=tovar, 29xx)
--     berilgan_qarz (4710/4720) · boshqa_aktiv · uzoq_aktiv (balans_bolimi=uzoq_aktiv, yo'q bo'lsa section bo'yicha)
--     olingan_qarz (6820) · ish_soliq (soliq_majb/oylik_majb) · uzoq_majb · boshqa_majb
--   AROS / REGISTR (tarixiy emas — «joriy» tegi):
--     yolda_pul   = aros_transfer_yolda status=sent (Aylanma B formulasi). Tarixiy sana + snapshot bor bo'lsa snapshot B.
--     mijoz_qarz  = Aros mijozlar qarzi (total_debt, Aylanma Q2a manbasi, hamyon AYIRILMAGAN). 4010 daftari izohda;
--                   Aros manbasi yo'q bo'lsa 4010 daftari ishlatiladi (ikkalasi QO'SHILMAYDI — ikki marta sanalmasin).
--     mijoz_avans = Aros mijoz hamyoni (total_wallet_balance) — Q2a ayiriladigan qismi majburiyat sifatida.
--     yetk_qarz   = Q2b: aros_yuk_snapshot (posted, 365 kun) narx x kurs - yuk_tolangan_fc (Qarz sahifasi formulasi,
--                   valyutali yukda 1.5 foizgacha qoldiq = kurs farqi, yopiq). 6010 daftari izohda.
--     yolda_yuk / kelmagan_qarz = yuk_yolda_jami().jami_uzs (nashr qilinmagan on_way yuklar; aktiv = majburiyat).
--     yolda_yuk_posted = Y3a (posted + on_way, Q2b ichida qarz sifatida bor) · ochiq_buyurtma = B6 (sotuv narxida)
--     kochirish = K3b + K4 · brak = T5   — faqat aylanma_snapshot (n8n); snapshot yo'q bo'lsa «manba yo'q».
--   Snapshot qoidasi: sana uchun aniq snapshot bor bo'lsa SHU (manba=snapshot); yo'q bo'lsa eng oxirgisi/jonli
--   (manba=joriy, sahifada «joriy» tegi). Bugun/kelajak sana uchun jonli manba (manba=jonli).
--   KAPITAL = Aktiv - Majburiyat (hisoblangan: daftar to'liq emas, Aros/registr qatorlari daftarda yo'q).
--
-- ## CASHFLOW B — pul = section='pul' hisoblar; faqat posted va o'chirilmagan yozuvlar.
--   Yozuv turi (entry_type, bo'lmasa v_entry_turi bilan bir xil qoida bilan hosila):
--     ichki_otkazma / konvert  -> pul oqimi EMAS (sof ta'siri 'ichki_kassa' qatorida: hamma kassada 0)
--     qayta_baholash           -> 'Kurs ta'siri'
--   Qolgan yozuvlarda har QARSHI satr (pul hisobi bo'lmagan) cf_modda bo'yicha (yo'q bo'lsa kod/nom/tur bo'yicha) tasniflanadi.
--   Tekshiruv: boshi + sof o'zgarish + kurs = oxiri (±1 so'm).
-- =====================================================================


-- #####################################################################
-- ##  0 — yordamchilar (ichki; _bb_ / _cfb_ prefiksi)                 ##
-- #####################################################################

create or replace function _bb_col(p_tbl text, p_col text)
returns boolean
language sql
stable
as $bb_col$
  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = p_tbl and column_name = p_col);
$bb_col$;

create or replace function _bb_fn(p_nom text, p_args text default '')
returns boolean
language sql
stable
as $bb_fn$
  select exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = p_nom
       and oidvectortypes(p.proargtypes) = coalesce(p_args, ''));
$bb_fn$;

create or replace function _bb_fmt(p_n numeric)
returns text
language sql
immutable
as $bb_fmt$
  select case when p_n is null then '—'
              else replace(to_char(round(p_n), 'FM999,999,999,999,999,999'), ',', ' ') end;
$bb_fmt$;

-- Qator qadoqlovchi: _bb_val natijasini jsonb massivga yig'ish uchun.
create or replace function _bb_r(p_kod text, p_summa numeric, p_manba text, p_izoh text default null)
returns jsonb
language sql
immutable
as $bb_r$
  select jsonb_build_object('kod', p_kod, 'summa', p_summa, 'manba', p_manba, 'izoh', p_izoh);
$bb_r$;

-- Snapshot bolimidan qiymat: aniq snapshot -> 'snapshot'; bo'lmasa eng oxirgisi -> 'joriy'; yo'q -> 'yoq'.
create or replace function _bb_pick(p_ex jsonb, p_la jsonb, p_key text)
returns jsonb
language sql
immutable
as $bb_pick$
  select case
    when jsonb_typeof(p_ex -> p_key) = 'object' then jsonb_build_object('v', p_ex -> p_key -> 'uzs', 'm', 'snapshot')
    when jsonb_typeof(p_la -> p_key) = 'object' then jsonb_build_object('v', p_la -> p_key -> 'uzs', 'm', 'joriy')
    else jsonb_build_object('v', null, 'm', 'yoq') end;
$bb_pick$;

-- Ruxsat qorovuli (SECURITY DEFINER ichida): auth.uid() null = SQL editor / service_role;
-- aks holda sahifa ruxsati 'balans' (perm_has_page, admin ham o'tadi) VA kassa doirasi 'all'.
-- Doirasi cheklangan foydalanuvchi butun kompaniya balansini ko'rmasin.
create or replace function _bb_ok()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $bb_ok$
declare
  v_uid  uuid;
  v_ok   boolean := false;
  v_list boolean := false;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return true;
  end if;
  if _bb_fn('perm_has_page', 'text') then
    execute 'select perm_has_page($1)' into v_ok using 'balans';
  elsif _bb_fn('is_admin', '') then
    execute 'select is_admin()' into v_ok;
  end if;
  if not coalesce(v_ok, false) then
    return false;
  end if;
  if to_regclass('public.user_perms') is not null then
    execute 'select exists (select 1 from user_perms where user_id = $1 and kassa_scope = ''list'')'
      into v_list using v_uid;
    if coalesce(v_list, false) then
      return false;
    end if;
  end if;
  return true;
end
$bb_ok$;

revoke all on function _bb_ok() from public, anon, authenticated;


-- #####################################################################
-- ##  1 — _bb_hisob(): hisoblar + hosila ustunlar (SECURITY INVOKER)  ##
-- #####################################################################
-- bolim: balans_bolimi (bor va to'ldirilgan bo'lsa), aks holda section/type'dan hosila.
-- hodim: 5400 konteyner (kassa_turi=xarajat_guruh) + uning barcha avlodlari.
-- bolim_raw: faqat balans_bolimi ustunining o'zi (null soni uchun).
create or replace function _bb_hisob()
returns table(id uuid, code text, name text, type text, section text, parent_id uuid, currency text,
              kassa_turi text, is_active boolean, bolim_raw text, bolim text, cf_modda text, hodim boolean)
language plpgsql
stable
set search_path = public
as $bb_hisob$
declare
  v_bb text;
  v_cf text;
begin
  v_bb := case when _bb_col('accounts', 'balans_bolimi') then 'a.balans_bolimi' else 'null::text' end;
  v_cf := case when _bb_col('accounts', 'cf_modda')      then 'a.cf_modda'      else 'null::text' end;
  return query execute format($q$
    with recursive kont as (
      select k.id from accounts k where k.code = '5400' or k.kassa_turi = 'xarajat_guruh'
    ),
    hod as (
      select a.id from accounts a where a.parent_id in (select id from kont)
      union all
      select a.id from accounts a join hod h on a.parent_id = h.id
    )
    select a.id,
           a.code::text,
           a.name::text,
           a.type::text,
           a.section::text,
           a.parent_id,
           coalesce(a.currency, 'UZS')::text,
           a.kassa_turi::text,
           coalesce(a.is_active, true),
           %1$s::text,
           coalesce(nullif(%1$s::text, ''),
             case
               when a.type in ('daromad', 'xarajat', 'kapital') then a.type::text
               else case a.section
                      when 'pul' then 'joriy_aktiv'
                      when 'tovar' then 'joriy_aktiv'
                      when 'debitor' then 'joriy_aktiv'
                      when 'boshqa_aktiv' then 'joriy_aktiv'
                      when 'asosiy_vosita' then 'uzoq_aktiv'
                      when 'amortizatsiya' then 'uzoq_aktiv'
                      when 'kreditor' then 'joriy_majburiyat'
                      when 'soliq_majb' then 'joriy_majburiyat'
                      when 'oylik_majb' then 'joriy_majburiyat'
                      when 'qarz' then 'joriy_majburiyat'
                      when 'boshqa_passiv' then 'joriy_majburiyat'
                      when 'kapital' then 'kapital'
                      else case a.type
                             when 'aktiv' then 'joriy_aktiv'
                             when 'passiv' then 'joriy_majburiyat'
                             else null end
                    end
             end)::text,
           %2$s::text,
           (a.id in (select id from hod) or a.id in (select id from kont))
      from accounts a
  $q$, v_bb, v_cf);
end
$bb_hisob$;

revoke all on function _bb_hisob() from public, anon;
grant execute on function _bb_hisob() to authenticated;


-- Hisob bo'yicha daftar saldo (Dt - Kt) sanagacha. SECURITY INVOKER (RLS saqlanadi).
create or replace function _bb_saldo(p_sana date)
returns table(account_id uuid, b numeric)
language sql
stable
set search_path = public
as $bb_saldo$
  select l.account_id, sum(l.debit - l.credit)
    from entry_line l
    join entry e on e.id = l.entry_id
   where e.status = 'posted' and e.is_deleted = false and e.entry_date <= p_sana
   group by l.account_id;
$bb_saldo$;

revoke all on function _bb_saldo(date) from public, anon;
grant execute on function _bb_saldo(date) to authenticated;


-- #####################################################################
-- ##  2 — _bb_val(p_sana): Balans B qiymatlari (kod, summa, manba, izoh) ##
-- #####################################################################
-- manba: daftar | jonli | snapshot | joriy | kiritilmagan | yoq
--   joriy        = tarixiy sana uchun tarixiy manba yo'q, hozirgi qiymat ishlatildi
--   kiritilmagan = bunday hisob daftarda umuman ochilmagan (summa 0)
--   yoq          = manba (RPC/jadval/snapshot) bazada yo'q yoki xato (summa null)
-- 'x_' bilan boshlanuvchi kodlar — sog'lik tekshiruvi uchun qo'shimcha, qator emas.
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

  -- ---------- Q2b: yetkazuvchilarga qarz ----------
  v_q2b := null; v_q2b_m := 'yoq'; v_q2b_i := null;
  v_use_ex := (not v_jonli) and jsonb_typeof(v_ex -> 'Q2b') = 'object';
  if v_use_ex then
    v_q2b := (v_ex -> 'Q2b' ->> 'uzs')::numeric; v_q2b_m := 'snapshot'; v_q2b_i := 'Snapshot ' || v_ex_sana::text;
  elsif to_regclass('public.aros_yuk_snapshot') is not null and _bb_fn('yuk_kurslar', 'text[]')
        and (_bb_fn('yuk_tolangan_fc', 'jsonb') or _bb_fn('yuk_tolangan_summa', 'integer[]')) then
    select coalesce(jsonb_agg(jsonb_build_object('id', s.yuk_id,
                      'valyuta', upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS')))), '[]'::jsonb),
           coalesce(array_agg(distinct upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS'))), '{}')
      into v_rows, v_curs
      from aros_yuk_snapshot s
     where s.mavjud = true and s.status = 'posted' and s.sana >= v_bugun - 365;

    execute 'select yuk_kurslar($1)' into v_kmap using v_curs;
    if _bb_fn('yuk_tolangan_fc', 'jsonb') then
      execute 'select yuk_tolangan_fc($1)' into v_paid using v_rows;
    else
      execute 'select yuk_tolangan_summa(array(select (x ->> ''id'')::integer from jsonb_array_elements($1) x))'
        into v_paid using v_rows;
    end if;

    with y as (
      select s.yuk_id,
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
      select y.cur, y.narx, k.kurs, p.tfc, coalesce(p.tuzs, 0) as tuzs
        from y left join p on p.yuk_id = y.yuk_id left join k on k.cur = y.cur
    ),
    w as (
      select q.*,
             case when q.cur = 'UZS' then q.narx - q.tuzs
                  else q.narx - coalesce(q.tfc, q.tuzs / nullif(q.kurs, 0), 0) end as qol_fc
        from q
    )
    select coalesce(sum(case when w.kurs is null then 0
                             when w.cur <> 'UZS' and w.qol_fc <= w.narx * 0.015 then 0
                             else greatest(0, w.qol_fc) * w.kurs end), 0),
           count(*) filter (where w.kurs is null and w.narx > 0)
      into v_q2b, v_kyoq
      from w;
    v_q2b_m := case when v_jonli then 'jonli' else 'joriy' end;
    v_q2b_i := 'Daftar 6010: ' || _bb_fmt(r.d6010)
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
  v_out := v_out || _bb_r('ochiq_buyurtma', (v_pk ->> 'v')::numeric, v_pk ->> 'm', 'Sotuv narxida');
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
-- ##  3 — balans_b(p_sana, p_solishtir)                               ##
-- #####################################################################
-- Qatorlar: bolim AKTIV | MAJBURIYAT | KAPITAL, guruh joriy | uzoq | jami.
-- summa / solishtir null = manba yo'q («—»). teglar: Aros | joriy | sotuv narxida |
-- kiritilmagan | hisoblangan | manba yo'q.  hisoblar = jurnalga o'tish uchun hisob kodlari (vergul bilan).
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
      (15,  'AKTIV',      'joriy', 'ochiq_buyurtma',   'Ochiq buyurtmalar',                'sotuv narxida', null),
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
      from base where b = 'AKTIV'
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

revoke all on function balans_b(date, date) from public, anon;
grant execute on function balans_b(date, date) to authenticated;

comment on function balans_b(date, date) is
  'Balans B (boshqaruv balansi): qatorlar p_sana va p_solishtir uchun. Daftar qatorlari tarixiy aniq, Aros/registr qatorlari '
  'snapshot (bo''lsa) yoki joriy (manba=joriy). Kapital = Aktiv - Majburiyat (hisoblangan). Ruxsat: balans sahifasi, kassa doirasi hamma.';


-- #####################################################################
-- ##  4 — balans_soglik(): tekshiruvlar ro'yxati                       ##
-- #####################################################################
-- {kod, daraja (ok|ogoh|xato), sarlavha, matn, summa}
create or replace function balans_soglik()
returns table(kod text, daraja text, sarlavha text, matn text, summa numeric)
language plpgsql
stable
security definer
set search_path = public
as $bb_soglik$
declare
  v_bugun date := (now() at time zone 'Asia/Tashkent')::date;
  v_v     jsonb;
  v_d     numeric;
  v_a     numeric;
  v_b     numeric;
  v_n     int;
  v_txt   text;
  v_tol   numeric;
  v_acc   record;
  v_t1    numeric;
  v_t1m   text;
  v_d29   numeric;
begin
  if not _bb_ok() then
    raise exception 'Ruxsat yo''q (balans sahifasi, kassa doirasi: hamma)' using errcode = '42501';
  end if;

  select jsonb_object_agg(x.kod, jsonb_build_object('s', x.summa, 'm', x.manba)) into v_v from _bb_val(v_bugun) x;

  -- (1) Dt = Kt
  select coalesce(sum(l.debit - l.credit), 0) into v_d
    from entry_line l join entry e on e.id = l.entry_id
   where e.status = 'posted' and e.is_deleted = false;
  kod := 'dt_kt'; sarlavha := 'Aktiv = Majburiyat + Kapital (Dt = Kt)'; summa := round(v_d, 2);
  if abs(v_d) < 1 then
    daraja := 'ok';
    matn := 'Daftardagi barcha yozuvlar muvozanatda (Dt = Kt). Balans B da Kapital hisoblangan (Aktiv − Majburiyat), '
            || 'chunki Aros / registr qatorlari daftarda yo''q — shu sababli daftar tengligi aynan shu yerda tekshiriladi.';
  else
    daraja := 'xato';
    matn := 'Daftarda Dt va Kt farqi ' || _bb_fmt(v_d) || ' so''m — nomutanosib yozuv bor. Kapital hisobi ishonchsiz.';
  end if;
  return next;

  -- (2) vaqtinchalik hisob (kod 8900, bo'lmasa nomida «vaqtinchalik»)
  kod := 'vaqtinchalik'; sarlavha := 'Vaqtinchalik hisob (Tovar kirimi)';
  select count(*), coalesce(sum(s.b), 0), string_agg(h.code || ' ' || h.name, ', ')
    into v_n, v_d, v_txt
    from _bb_hisob() h
    left join _bb_saldo(v_bugun) s on s.account_id = h.id
   where h.code = '8900' or h.name ilike '%vaqtinchalik%';
  summa := round(coalesce(v_d, 0), 2);
  if v_n = 0 then
    daraja := 'ok'; matn := 'Vaqtinchalik hisob (8900) topilmadi.'; summa := 0;
  elsif abs(v_d) < 1 then
    daraja := 'ok'; matn := v_txt || ': qoldiq 0.';
  else
    daraja := 'ogoh';
    matn := v_txt || ': qoldiq ' || _bb_fmt(v_d) || ' so''m. Tovar kirimi hali haqiqiy hisobga o''tkazilmagan — '
            || 'Kapitalga ta''sir qiladi (Balans B bu hisobni majburiyatga qo''shmaydi).';
  end if;
  return next;

  -- (3a) 6010 daftar vs Qarz sahifasi (Q2b)
  kod := 'qarz_6010'; sarlavha := 'Yetkazuvchi qarzi: 6010 daftari ↔ Qarz sahifasi';
  v_a := (v_v -> 'x_d6010' ->> 's')::numeric; v_b := (v_v -> 'x_q2b' ->> 's')::numeric;
  if v_b is null then
    daraja := 'ogoh'; summa := null;
    matn := 'Qarz sahifasi formulasi hisoblanmadi (aros_yuk_snapshot / yuk_kurslar / yuk_tolangan_fc yo''q yoki snapshot yo''q). Daftar 6010: ' || _bb_fmt(v_a) || '.';
  else
    summa := round(v_a - v_b);
    v_tol := greatest(1000000, 0.02 * greatest(abs(v_a), abs(v_b)));
    daraja := case when abs(v_a - v_b) > v_tol then 'ogoh' else 'ok' end;
    matn := 'Daftar 6010: ' || _bb_fmt(v_a) || ' · Qarz sahifasi: ' || _bb_fmt(v_b) || ' · farq ' || _bb_fmt(v_a - v_b)
            || ' so''m. Balans B Qarz sahifasi qiymatini ishlatadi.';
  end if;
  return next;

  -- (3b) 4010 daftar vs Aros qarzdor
  kod := 'qarz_4010'; sarlavha := 'Mijozlar qarzi: 4010 daftari ↔ Aros qarzdor';
  v_a := (v_v -> 'x_d4010' ->> 's')::numeric; v_b := (v_v -> 'x_aros_qarz' ->> 's')::numeric;
  if v_b is null then
    daraja := 'ogoh'; summa := null;
    matn := 'Aros qarzdor manbasi yo''q (aros_qarzdor_sync / aros_qarzdor). Daftar 4010: ' || _bb_fmt(v_a) || '.';
  else
    summa := round(v_a - v_b);
    v_tol := greatest(1000000, 0.02 * greatest(abs(v_a), abs(v_b)));
    daraja := case when abs(v_a - v_b) > v_tol then 'ogoh' else 'ok' end;
    matn := 'Daftar 4010: ' || _bb_fmt(v_a) || ' · Aros qarzdor: ' || _bb_fmt(v_b) || ' · farq ' || _bb_fmt(v_a - v_b)
            || ' so''m. Balans B Aros qiymatini ishlatadi (ikkalasi qo''shilmaydi).';
  end if;
  return next;

  -- (4) manfiy qoldiqli kassalar
  kod := 'manfiy_kassa'; sarlavha := 'Manfiy qoldiqli kassalar';
  select count(*), coalesce(sum(t.b), 0),
         string_agg(t.code || ' ' || t.name || ' (' || _bb_fmt(t.b) || ')', ', ' order by t.b)
    into v_n, v_d, v_txt
    from (
      select h.code, h.name, s.b
        from _bb_saldo(v_bugun) s
        join _bb_hisob() h on h.id = s.account_id
       where h.section = 'pul' and coalesce(h.kassa_turi, '') <> 'xarajat_guruh' and s.b < -1
       order by s.b limit 8
    ) t;
  select count(*), coalesce(sum(s.b), 0) into v_n, v_d
    from _bb_saldo(v_bugun) s join _bb_hisob() h on h.id = s.account_id
   where h.section = 'pul' and coalesce(h.kassa_turi, '') <> 'xarajat_guruh' and s.b < -1;
  summa := round(v_d, 2);
  if v_n = 0 then
    daraja := 'ok'; matn := 'Manfiy qoldiqli kassa yo''q.';
  else
    daraja := 'ogoh';
    matn := v_n || ' ta kassa manfiy (jami ' || _bb_fmt(v_d) || '): ' || coalesce(v_txt, '') || case when v_n > 8 then ' va boshqalar' else '' end;
  end if;
  return next;

  -- (5) yalpi marja: oxirgi 3 oy, 9010 tushum vs 9110 / 9110-1 tannarx
  kod := 'marja'; sarlavha := 'Yalpi marja (9010 tushum ↔ 9110 tannarx)';
  select string_agg(t.oy || ' (' || round(100 * (t.rev - coalesce(t.cost, 0)) / t.rev) || '%)', ', ' order by t.oy), count(*)
    into v_txt, v_n
    from (
      select to_char(date_trunc('month', e.entry_date), 'YYYY-MM') as oy,
             sum(l.credit - l.debit) filter (where a.code = '9010') as rev,
             sum(l.debit - l.credit) filter (where a.code in ('9110', '9110-1')) as cost
        from entry_line l
        join entry e on e.id = l.entry_id
        join accounts a on a.id = l.account_id
       where e.status = 'posted' and e.is_deleted = false
         and a.code in ('9010', '9110', '9110-1')
         and e.entry_date >= date_trunc('month', v_bugun)::date - interval '2 months'
       group by 1
    ) t
   where t.rev > 0 and (t.rev - coalesce(t.cost, 0)) / t.rev >= 0.9;
  summa := v_n;
  if coalesce(v_n, 0) = 0 then
    daraja := 'ok'; matn := 'Oxirgi 3 oyda yalpi marja me''yorda (90 foizdan past yoki tushum yo''q).'; summa := 0;
  else
    daraja := 'ogoh';
    matn := 'Yalpi marja 90 foizdan yuqori — sotuvga tannarx yozilmayapti: ' || v_txt;
  end if;
  return next;

  -- (6) 29xx tovar hisoblari ↔ Aros ombor (aylanma T1)
  kod := 'tovar_aros'; sarlavha := 'Tovar: 29xx daftari ↔ Aros ombor (Aylanma T1)';
  v_d29 := (v_v -> 'x_t1' ->> 's')::numeric;
  select coalesce(sum(s.b), 0) into v_d
    from _bb_saldo(v_bugun) s join _bb_hisob() h on h.id = s.account_id where h.section = 'tovar';
  v_t1 := v_d29; v_t1m := v_v -> 'x_t1' ->> 'm';
  if v_t1 is null then
    daraja := 'ogoh'; summa := null;
    matn := 'Aros ombor qiymati (aylanma_snapshot T1) yo''q — solishtirib bo''lmadi. Daftar 29xx: ' || _bb_fmt(v_d) || '.';
  else
    summa := round(v_d - v_t1);
    daraja := case when abs(v_d - v_t1) > 0.005 * greatest(abs(v_d), abs(v_t1), 1) then 'ogoh' else 'ok' end;
    matn := 'Daftar 29xx: ' || _bb_fmt(v_d) || ' · Aros ombor (snapshot): ' || _bb_fmt(v_t1) || ' · farq ' || _bb_fmt(v_d - v_t1)
            || ' so''m (chegara 0.5 foiz).';
  end if;
  return next;

  -- (7) uzoq muddatli aktivlar
  kod := 'uzoq_aktiv'; sarlavha := 'Uzoq muddatli aktivlar';
  select count(*), coalesce(sum(s.b), 0) into v_n, v_d
    from _bb_hisob() h left join _bb_saldo(v_bugun) s on s.account_id = h.id
   where h.bolim = 'uzoq_aktiv';
  summa := round(v_d, 2);
  if v_n = 0 or abs(v_d) < 1 then
    daraja := 'ogoh';
    matn := 'Asosiy vositalar / nomoddiy aktivlar daftarga kiritilmagan — Aktiv va Kapital past ko''rinadi.';
  else
    daraja := 'ok'; matn := v_n || ' ta hisob, jami ' || _bb_fmt(v_d) || ' so''m.';
  end if;
  return next;

  -- (8) balans_bolimi belgilanmagan hisoblar
  kod := 'bolim_null'; sarlavha := 'Balans bo''limi belgilanmagan hisoblar';
  if not _bb_col('accounts', 'balans_bolimi') then
    daraja := 'ogoh'; summa := null;
    matn := 'accounts.balans_bolimi ustuni yo''q — PROVODKA_HISOB_MAYDONLAR_20261107.sql RUN qilinmagan. Bo''lim section / tur bo''yicha taxmin qilinmoqda.';
  else
    select count(*), string_agg(t.code, ', ' order by t.code) into v_n, v_txt
      from (select h.code from _bb_hisob() h where h.bolim_raw is null and h.is_active order by h.code limit 12) t;
    select count(*) into v_n from _bb_hisob() h where h.bolim_raw is null and h.is_active;
    summa := v_n;
    if v_n = 0 then daraja := 'ok'; matn := 'Hamma faol hisobga bo''lim belgilangan.';
    else daraja := 'ogoh'; matn := v_n || ' ta faol hisobda balans_bolimi bo''sh (taxminiy bo''lim ishlatiladi). Masalan: ' || coalesce(v_txt, '') || '.'; end if;
  end if;
  return next;

  -- (9) provodka_kuzatuv — so'nggi 7 kun
  if to_regclass('public.provodka_kuzatuv') is not null then
    kod := 'kuzatuv'; sarlavha := 'Kuzatuv logi (so''nggi 7 kun)';
    select count(*), string_agg(t.qoida || ' ' || t.n, ', ' order by t.n desc)
      into v_n, v_txt
      from (select k.qoida, count(*) as n from provodka_kuzatuv k
             where k.created_at >= now() - interval '7 days' group by k.qoida) t;
    select count(*) into v_n from provodka_kuzatuv k where k.created_at >= now() - interval '7 days';
    summa := v_n;
    if v_n = 0 then daraja := 'ok'; matn := 'So''nggi 7 kunda kuzatuv qoidasi buzilmagan.';
    else daraja := 'ogoh'; matn := v_n || ' ta belgi: ' || coalesce(v_txt, '') || '.'; end if;
    return next;
  end if;

  return;
end
$bb_soglik$;

revoke all on function balans_soglik() from public, anon;
grant execute on function balans_soglik() to authenticated;

comment on function balans_soglik() is
  'Balans sog''ligi: {kod, daraja ok|ogoh|xato, sarlavha, matn, summa}. 9 ta tekshiruv (Dt=Kt, vaqtinchalik hisob, Qarz moduli moslik, '
  'manfiy kassa, yalpi marja, 29xx vs Aros, uzoq aktiv, balans_bolimi null, kuzatuv).';


-- #####################################################################
-- ##  5 — Cashflow B                                                  ##
-- #####################################################################

-- Qarshi satr -> Cashflow moddasi kodi. cf_modda bo'lsa o'sha, bo'lmasa kod / nom / tur bo'yicha.
-- p_kt = qarshi satr Kreditda (pul kirdi). Pul hisobi (kassa filtri tashqarisidagi) -> ichki_kassa.
create or replace function _cfb_kod(p_code text, p_name text, p_type text, p_section text, p_modda text, p_kt boolean)
returns text
language sql
immutable
as $cfb_kod$
  select case
    when p_section = 'pul' then 'ichki_kassa'
    when p_modda = 'ichki' then 'ichki_kassa'
    when p_modda = 'mijoz_tushum' then case when p_kt then 'mijoz_tushum' else 'mijoz_qaytarish' end
    when p_modda = 'qarz_berildi' then case when p_kt then 'qarz_qaytdi' else 'qarz_berildi' end
    when p_modda = 'qarz_olindi'  then case when p_kt then 'qarz_olindi' else 'qarz_qaytarildi' end
    when p_modda in ('boshqa_tushum', 'mijoz_qaytarish', 'yetkazuvchi_tolov', 'ish_haqi', 'ijara', 'xayriya',
                     'boshqa_operatsion', 'soliq', 'asosiy_vosita', 'qarz_qaytarildi', 'egasi') then p_modda
    when p_code in ('9010', '4010') then case when p_kt then 'mijoz_tushum' else 'mijoz_qaytarish' end
    when p_code in ('9110', '9110-1', '6010') then 'yetkazuvchi_tolov'
    when p_code in ('4710', '4720') then case when p_kt then 'qarz_qaytdi' else 'qarz_berildi' end
    when p_code ~ '^6820' then case when p_kt then 'qarz_olindi' else 'qarz_qaytarildi' end
    when p_code ~ '^944' then 'xayriya'
    when p_name ~* '(ish\s*haqi|ishhaqi|oylik|maosh|zarplat)' then 'ish_haqi'
    when p_name ~* 'ijara' then 'ijara'
    when p_name ~* '(xayriya|ehson|zakot|sadaqa)' then 'xayriya'
    when p_name ~* 'soliq' and p_name !~* 'soliqsiz' then 'soliq'
    when p_section = 'asosiy_vosita' then 'asosiy_vosita'
    when p_type = 'kapital' then 'egasi'
    when p_type = 'xarajat' then 'boshqa_operatsion'
    when p_type = 'daromad' then 'boshqa_tushum'
    when p_section = 'tovar' then 'yetkazuvchi_tolov'
    else case when p_kt then 'boshqa_tushum' else 'boshqa_operatsion' end
  end;
$cfb_kod$;

revoke all on function _cfb_kod(text, text, text, text, text, boolean) from public, anon;
grant execute on function _cfb_kod(text, text, text, text, text, boolean) to authenticated;


-- Bir davr uchun yig'indilar: kod -> (summa, soni, belgisiz). SECURITY INVOKER (RLS saqlanadi).
-- Maxsus kodlar: boshi, oxiri, kurs, ichki_kassa. Qolganlari _cfb_kod natijalari.
create or replace function _cfb_davr(p_from date, p_to date, p_kassa uuid default null)
returns table(kod text, summa numeric, soni int, belgisiz int)
language plpgsql
stable
set search_path = public
as $cfb_davr$
declare
  v_p    uuid[];
  v_root uuid;
  v_et   text;
begin
  if p_kassa is null then
    select array_agg(h.id) into v_p from _bb_hisob() h where h.section = 'pul';
  else
    select case when a.parent_id is not null
                     and (coalesce(a.currency, 'UZS') <> 'UZS' or a.pul_turi is not null)
                then a.parent_id else a.id end
      into v_root from accounts a where a.id = p_kassa;
    select array_agg(x.id) into v_p
      from (
        select v_root as id
        union
        select c.id from accounts c
         where c.parent_id = v_root and coalesce(c.is_active, true)
           and (coalesce(c.currency, 'UZS') <> 'UZS' or c.pul_turi is not null)
      ) x
     where x.id is not null;
  end if;
  v_p := coalesce(v_p, '{}');

  v_et := case when _bb_col('entry', 'entry_type') then 'e.entry_type' else '''oddiy''' end;

  return query execute format($q$
    with ent as (
      select e.id, %1$s::text as et, e.source, coalesce(e.ext_ref, '') as ext_ref, coalesce(e.description, '') as descr
        from entry e
       where e.status = 'posted' and e.is_deleted = false
         and e.entry_date between $2 and $3
         and exists (select 1 from entry_line l where l.entry_id = e.id and l.account_id = any($1))
    ),
    tur as (
      select ent.id,
             case
               when ent.et <> 'oddiy'                               then ent.et
               when ent.source = 'aros_auto'                        then 'aros_sync'
               when ent.source = 'qarz'                             then 'qarz'
               when ent.ext_ref like 'kursfarq:%%'                   then 'qayta_baholash'
               when ent.ext_ref like 'convxy:%%' or ent.descr like 'Konvert: %%' then 'konvert'
               when ent.descr like 'Boshlang''ich qoldiq%%'          then 'boshlangich_qoldiq'
               when x.n >= 2 and x.n = x.np                         then 'ichki_otkazma'
               else 'oddiy' end as tur
        from ent
        left join lateral (
          select count(*) as n, count(*) filter (where a.section = 'pul') as np
            from entry_line l join accounts a on a.id = l.account_id
           where l.entry_id = ent.id) x on true
    ),
    pl as (   -- pul satrlari sof ta'siri, yozuv bo'yicha
      select t.id, t.tur, sum(l.debit - l.credit) as net
        from tur t join entry_line l on l.entry_id = t.id and l.account_id = any($1)
       group by t.id, t.tur
    ),
    fl as (   -- oddiy yozuvlarning qarshi satrlari
      select _cfb_kod(h.code, h.name, h.type, h.section, h.cf_modda, l.credit > 0) as kod,
             l.credit - l.debit as amt,
             l.entry_id,
             (h.cf_modda is null and h.section <> 'pul') as belgisiz
        from tur t
        join entry_line l on l.entry_id = t.id and not (l.account_id = any($1))
        join _bb_hisob() h on h.id = l.account_id
       where t.tur not in ('ichki_otkazma', 'konvert', 'qayta_baholash')
    )
    ,
    u as (
    select 'ichki_kassa'::text as kod, sum(net) as summa, count(*)::int as soni, 0 as belgisiz from pl where tur in ('ichki_otkazma', 'konvert')
    union all
    select 'kurs', sum(net), count(*)::int, 0 from pl where tur = 'qayta_baholash'
    union all
    select fl.kod, sum(fl.amt), count(distinct fl.entry_id)::int, count(*) filter (where fl.belgisiz)::int
      from fl group by fl.kod
    union all
    select 'boshi', coalesce(sum(l.debit - l.credit), 0), 0, 0
      from entry_line l join entry e on e.id = l.entry_id
     where l.account_id = any($1) and e.status = 'posted' and e.is_deleted = false and e.entry_date <= $2 - 1
    union all
    select 'oxiri', coalesce(sum(l.debit - l.credit), 0), 0, 0
      from entry_line l join entry e on e.id = l.entry_id
     where l.account_id = any($1) and e.status = 'posted' and e.is_deleted = false and e.entry_date <= $3
    )
    select u.kod, sum(u.summa)::numeric, sum(u.soni)::int, sum(u.belgisiz)::int from u group by u.kod
  $q$, v_et)
  using v_p, p_from, p_to;
end
$cfb_davr$;

revoke all on function _cfb_davr(date, date, uuid) from public, anon;
grant execute on function _cfb_davr(date, date, uuid) to authenticated;


-- cashflow_b(p_from, p_to, p_kassa): qatorlar (joriy davr + oldingi bir xil uzunlikdagi davr).
create or replace function cashflow_b(p_from date, p_to date, p_kassa uuid default null)
returns table(ord int, guruh text, kod text, nom text, summa numeric, oldingi numeric,
              teglar text[], izoh text, soni int)
language plpgsql
stable
set search_path = public
as $cashflow_b$
declare
  v_len  int;
  v_pf   date;
  v_pt   date;
begin
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'Davr noto''g''ri: p_from <= p_to bo''lishi kerak' using errcode = '22000';
  end if;
  v_len := (p_to - p_from) + 1;
  v_pt  := p_from - 1;
  v_pf  := p_from - v_len;

  return query
  with a as (select * from _cfb_davr(p_from, p_to, p_kassa)),
       b as (select * from _cfb_davr(v_pf, v_pt, p_kassa)),
  meta(o, g, k, n, teg) as (
    values
      (10,  'OPERATSION',   'mijoz_tushum',      'Mijozlardan tushum',            null),
      (11,  'OPERATSION',   'boshqa_tushum',     'Boshqa tushumlar',              'tekshirish kerak'),
      (12,  'OPERATSION',   'mijoz_qaytarish',   'Mijozlarga qaytarilgan',        null),
      (13,  'OPERATSION',   'yetkazuvchi_tolov', 'Yetkazuvchilarga to''lov',      null),
      (14,  'OPERATSION',   'ish_haqi',          'Ish haqi',                      null),
      (15,  'OPERATSION',   'ijara',             'Ijara',                         null),
      (16,  'OPERATSION',   'xayriya',           'Xayriya',                       null),
      (17,  'OPERATSION',   'boshqa_operatsion', 'Boshqa operatsion',             null),
      (18,  'OPERATSION',   'soliq',             'Soliq',                         null),
      (30,  'INVESTITSIYA', 'asosiy_vosita',     'Asosiy vositalar',              null),
      (31,  'INVESTITSIYA', 'qarz_berildi',      'Berilgan qarzlar',              null),
      (32,  'INVESTITSIYA', 'qarz_qaytdi',       'Berilgan qarzlar qaytdi',       null),
      (50,  'MOLIYAVIY',    'qarz_olindi',       'Olingan qarzlar',               null),
      (51,  'MOLIYAVIY',    'qarz_qaytarildi',   'Olingan qarzlar qaytarildi',    null),
      (52,  'MOLIYAVIY',    'egasi',             'Egasiga to''lovlar / egasidan', null)
  ),
  rows as (
    select m.o, m.g, m.k, m.n,
           coalesce(a.summa, 0) as s1, coalesce(b.summa, 0) as s2,
           array_remove(array[m.teg], null) as tg,
           case when coalesce(a.belgisiz, 0) > 0
                then a.belgisiz || ' ta satr: hisobda cf_modda belgilanmagan (kod / nom / tur bo''yicha taxmin)'
           end as iz,
           coalesce(a.soni, 0) as sn
      from meta m
      left join a on a.kod = m.k
      left join b on b.kod = m.k
  ),
  jami as (
    select 19 as o, 'OPERATSION' as g, 'jami_operatsion' as k, 'Operatsion faoliyatdan sof pul oqimi' as n,
           sum(s1) as s1, sum(s2) as s2 from rows where g = 'OPERATSION'
    union all
    select 33, 'INVESTITSIYA', 'jami_investitsiya', 'Investitsion faoliyatdan sof pul oqimi',
           sum(s1), sum(s2) from rows where g = 'INVESTITSIYA'
    union all
    select 53, 'MOLIYAVIY', 'jami_moliyaviy', 'Moliyaviy faoliyatdan sof pul oqimi',
           sum(s1), sum(s2) from rows where g = 'MOLIYAVIY'
  ),
  ich as (
    select 60 as o, 'ICHKI' as g, 'ichki_kassa' as k,
           case when p_kassa is null then 'Ichki o''tkazma va konvert (sof)' else 'Boshqa kassalar bilan o''tkazma va konvert (sof)' end as n,
           coalesce((select a.summa from a where a.kod = 'ichki_kassa'), 0) as s1,
           coalesce((select b.summa from b where b.kod = 'ichki_kassa'), 0) as s2
  ),
  sof as (
    select 70 as o, 'JAMI' as g, 'sof_ozgarish' as k, 'Sof o''zgarish' as n,
           (select sum(s1) from jami) + (select s1 from ich) as s1,
           (select sum(s2) from jami) + (select s2 from ich) as s2
  ),
  kz as (
    select 71 as o, 'JAMI' as g, 'kurs' as k, 'Kurs ta''siri' as n,
           coalesce((select a.summa from a where a.kod = 'kurs'), 0) as s1,
           coalesce((select b.summa from b where b.kod = 'kurs'), 0) as s2
  ),
  bo as (
    select 1 as o, 'BOSHI' as g, 'boshi' as k, 'Davr boshi pul qoldig''i' as n,
           coalesce((select a.summa from a where a.kod = 'boshi'), 0) as s1,
           coalesce((select b.summa from b where b.kod = 'boshi'), 0) as s2
  ),
  ox as (
    select 72 as o, 'JAMI' as g, 'oxiri' as k, 'Davr oxiri pul qoldig''i' as n,
           coalesce((select a.summa from a where a.kod = 'oxiri'), 0) as s1,
           coalesce((select b.summa from b where b.kod = 'oxiri'), 0) as s2
  ),
  tk as (
    select 73 as o, 'JAMI' as g, 'tekshiruv' as k, 'Tekshiruv: boshi + oqim + kurs − oxiri' as n,
           (select s1 from bo) + (select s1 from sof) + (select s1 from kz) - (select s1 from ox) as s1,
           (select s2 from bo) + (select s2 from sof) + (select s2 from kz) - (select s2 from ox) as s2
  ),
  fcf as (
    select 80 as o, 'KPI' as g, 'fcf' as k, 'Erkin pul oqimi (FCF = operatsion + asosiy vositalar)' as n,
           (select s1 from jami where k = 'jami_operatsion') + coalesce((select s1 from rows where k = 'asosiy_vosita'), 0) as s1,
           (select s2 from jami where k = 'jami_operatsion') + coalesce((select s2 from rows where k = 'asosiy_vosita'), 0) as s2
  )
  select x.o::int, x.g, x.k, x.n, round(x.s1, 2), round(x.s2, 2), x.tg, x.iz, x.sn::int
    from (
      select rows.o, rows.g, rows.k, rows.n, rows.s1, rows.s2, rows.tg, rows.iz, rows.sn from rows
      union all select jami.o, jami.g, jami.k, jami.n, jami.s1, jami.s2, array[]::text[], null::text, 0 from jami
      union all select ich.o, ich.g, ich.k, ich.n, ich.s1, ich.s2, array[]::text[],
                       case when p_kassa is null then 'Hamma kassalar bo''yicha odatda 0; konvert ustamasi / farqi bo''lsa shu yerda ko''rinadi (kassalar orasidagi harakat pul oqimi emas)'
                            else 'Tanlangan kassa va boshqa kassalar orasidagi harakat (shu kassa uchun kirim / chiqim)' end,
                       coalesce((select a.soni from a where a.kod = 'ichki_kassa'), 0) from ich
      union all select sof.o, sof.g, sof.k, sof.n, sof.s1, sof.s2, array[]::text[], null::text, 0 from sof
      union all select kz.o, kz.g, kz.k, kz.n, kz.s1, kz.s2, array[]::text[], 'Qayta baholash yozuvlari (valyuta qoldig''i kursi o''zgarishi)',
                       coalesce((select a.soni from a where a.kod = 'kurs'), 0) from kz
      union all select bo.o, bo.g, bo.k, bo.n, bo.s1, bo.s2, array[]::text[], null::text, 0 from bo
      union all select ox.o, ox.g, ox.k, ox.n, ox.s1, ox.s2, array[]::text[], null::text, 0 from ox
      union all select tk.o, tk.g, tk.k, tk.n, tk.s1, tk.s2, array[]::text[], '±1 so''mgacha mos kelishi kerak', 0 from tk
      union all select fcf.o, fcf.g, fcf.k, fcf.n, fcf.s1, fcf.s2, array[]::text[], null::text, 0 from fcf
    ) x
   order by x.o;
end
$cashflow_b$;

revoke all on function cashflow_b(date, date, uuid) from public, anon;
grant execute on function cashflow_b(date, date, uuid) to authenticated;

comment on function cashflow_b(date, date, uuid) is
  'Cashflow B (IAS 7, to''g''ridan-to''g''ri): pul = section=pul; ichki_otkazma / konvert pul oqimi emas; qayta_baholash = kurs ta''siri. '
  'oldingi = bir xil uzunlikdagi oldingi davr. SECURITY INVOKER (RLS saqlanadi). p_kassa null = hamma kassalar.';


-- #####################################################################
-- ##  6 — PostgREST sxema keshi                                       ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  7 — TEKSHIRUV (RUN dan keyin, qo'lda)                           ##
-- #####################################################################
-- 7.1 Balans B qatorlari (bugun, oy boshi bilan solishtirish)
--   select ord, bolim, guruh, kod, nom, round(summa) summa, round(solishtir) solishtir, manba, teglar
--     from balans_b(current_date, date_trunc('month', current_date)::date) order by ord;
-- 7.2 Sog'liq
--   select kod, daraja, sarlavha, matn from balans_soglik();
-- 7.3 Cashflow B (shu oy) + tekshiruv qatori: tekshiruv summa ±1 bo'lishi kerak
--   select ord, guruh, kod, nom, summa, oldingi from cashflow_b(date_trunc('month', current_date)::date, current_date, null) order by ord;
-- 7.4 Eski cashflow bilan taqqoslash: oxiri = pul_qoldiq(p_to), boshi = pul_qoldiq(p_from - 1)
--   select pul_qoldiq(current_date, null), pul_qoldiq(date_trunc('month', current_date)::date - 1, null);

-- ROLLBACK (kerak bo'lsa; hech narsaga tegmaydi, faqat yangi funksiyalar):
--   drop function if exists cashflow_b(date, date, uuid);
--   drop function if exists _cfb_davr(date, date, uuid);
--   drop function if exists _cfb_kod(text, text, text, text, text, boolean);
--   drop function if exists balans_soglik();
--   drop function if exists balans_b(date, date);
--   drop function if exists _bb_val(date);
--   drop function if exists _bb_saldo(date);
--   drop function if exists _bb_hisob();
--   drop function if exists _bb_ok();
--   drop function if exists _bb_pick(jsonb, jsonb, text);
--   drop function if exists _bb_r(text, numeric, text, text);
--   drop function if exists _bb_fmt(numeric);
--   drop function if exists _bb_fn(text, text);
--   drop function if exists _bb_col(text, text);
