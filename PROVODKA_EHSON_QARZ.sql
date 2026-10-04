-- ============================================================================
--  PROVODKA_EHSON_QARZ.sql — 2026-10-04 — Ehson ichida QARZ bo'limi (jamg'armadan qarz berish / qaytarish)
--  Asilbek: «ehson bo'limiga ham qarz berish imkoni bo'lsin — u ehson emas, QARZ; u pul hech qayerda hisoblanmaydi,
--  faqat ehson ichida qarz bo'limi; deadline yoki oyma-oy; pul faqat ehson kassalardan chiqadi; ehson ruxsati bor odam
--  bemalol qarz bersa bo'ladi».
--
--  MODEL (kompaniya buxgalteriyasiga — entry/entry_line/accounts — TEGILMAYDI; pul ehson jamg'armasida allaqachon
--  kompaniyadan chiqib ketgan):
--   * ehson_qarz        — qarz: jamg'arma (ehson_kassa child) + pul turi, qarzdor (ehson_oila YOKI erkin shaxs),
--                         muddat: bir_martalik (tugash = deadline) | oylik (boshlanish + oylar_soni, oylik_summa),
--                         holat faol → yopildi (to'liq to'langach) | bekor (to'lov yo'q bo'lsa, admin/yaratgan).
--   * ehson_qarz_jadval — to'lov grafigi (n, sana, summa, tolangan) — QARZ VALYUTASI birligida (USD bo'lsa dollar).
--   * ehson_qarz_tolov  — qaytarilgan pul (jamg'armaga qaytadi), FIFO grafikka taqsimlanadi.
--   * v_ehson_kassa_pul / v_ehson_kassa — QOLDIQ = kirim − berildi − qarz_berildi + qarz_qaytdi (ustunlar OXIRIGA
--     qo'shildi, eski ustunlar o'zgarmagan → ehson_dash/ehson_ber/ehson_kassa_daraxt avtomat to'g'ri qoldiq oladi).
--   * Ruxsat: ehson_page_ok() (Ehson sahifasi) — bekor faqat admin yoki yaratgan.
--   * Valyuta: pul turi USD bo'lsa summa dollarda (fc_summa), so'm ekvivalenti conv_baza_kurs('USD') bilan — ehson_ber
--     bilan AYNAN bir xil. Grafik/to'lov/qoldi hisobi qarz valyutasi birligida (asosiy = USD ? fc_summa : summa).
--  Additive, idempotent. Asilbek RUN qiladi. Old shart: PROVODKA_EHSON.sql + PROVODKA_EHSON_ZAKOT.sql.
-- ============================================================================

-- ######## 0) OLD SHART ########
do $ehq_pre$
begin
  if to_regclass('public.ehson_kassa') is null then raise exception 'ehson_kassa yoq — avval PROVODKA_EHSON.sql'; end if;
  if to_regclass('public.ehson_pul_turi') is null then raise exception 'ehson_pul_turi yoq — avval PROVODKA_EHSON_ZAKOT.sql'; end if;
  if to_regprocedure('public.ehson_page_ok()') is null then raise exception 'ehson_page_ok() yoq'; end if;
  if to_regprocedure('public._ehson_tarix_yoz(text,uuid,text,jsonb)') is null then raise exception '_ehson_tarix_yoz yoq'; end if;
end
$ehq_pre$;

-- ######## 1) JADVALLAR ########
create table if not exists ehson_qarz (
  id             uuid        primary key default gen_random_uuid(),
  kassa_id       uuid        not null references ehson_kassa(id),
  pul_turi       text,
  valyuta        text        not null default 'UZS',
  summa          numeric     not null check (summa > 0),          -- so'm ekvivalenti (har doim)
  fc_summa       numeric     check (fc_summa is null or fc_summa > 0),   -- valyuta miqdori (USD bo'lsa)
  qarzdor_turi   text        not null check (qarzdor_turi in ('oila','shaxs')),
  oila_id        uuid        references ehson_oila(id),
  ism            text,
  telefon        text,
  muddat_turi    text        not null check (muddat_turi in ('bir_martalik','oylik')),
  boshlanish     date,                                            -- oylik: birinchi to'lov sanasi
  tugash         date        not null,                            -- bir_martalik: deadline; oylik: oxirgi to'lov sanasi
  oylar_soni     int         check (oylar_soni is null or oylar_soni > 0),
  oylik_summa    numeric     check (oylik_summa is null or oylik_summa > 0),   -- qarz valyutasi birligida
  sana           date        not null default ((now() at time zone 'Asia/Tashkent')::date),
  izoh           text        not null check (length(btrim(izoh)) >= 3),
  holat          text        not null default 'faol' check (holat in ('faol','yopildi','bekor')),
  ext_ref        text        unique,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  yopilgan_at    timestamptz,
  bekor_sabab    text,
  bekor_by       uuid,
  bekor_at       timestamptz,
  constraint ehson_qarz_qarzdor_ck check (
    (qarzdor_turi = 'oila'  and oila_id is not null) or
    (qarzdor_turi = 'shaxs' and length(btrim(coalesce(ism, ''))) >= 2)
  ),
  constraint ehson_qarz_muddat_ck check (
    (muddat_turi = 'bir_martalik' and oylar_soni is null) or
    (muddat_turi = 'oylik' and boshlanish is not null and oylar_soni > 0 and oylik_summa > 0)
  )
);
comment on table ehson_qarz is
  'Ehson jamg''armasidan berilgan QARZ (ehson emas). Pul kompaniya buxgalteriyasida hisoblanmaydi — faqat ehson qoldig''idan '
  'ayriladi (v_ehson_kassa_pul.qarz_berildi) va qaytarilsa qaytib qo''shiladi (qarz_qaytdi). Grafik/qoldi qarz valyutasi birligida.';
create index if not exists ehson_qarz_kassa_idx on ehson_qarz (kassa_id);
create index if not exists ehson_qarz_holat_idx on ehson_qarz (holat);
create index if not exists ehson_qarz_oila_idx  on ehson_qarz (oila_id);

create table if not exists ehson_qarz_jadval (
  id        uuid    primary key default gen_random_uuid(),
  qarz_id   uuid    not null references ehson_qarz(id) on delete cascade,
  n         int     not null check (n > 0),
  sana      date    not null,
  summa     numeric not null check (summa > 0),
  tolangan  numeric not null default 0 check (tolangan >= 0 and tolangan <= summa),
  unique (qarz_id, n)
);
create index if not exists ehson_qarz_jadval_qarz_idx on ehson_qarz_jadval (qarz_id);
create index if not exists ehson_qarz_jadval_sana_idx on ehson_qarz_jadval (sana);

create table if not exists ehson_qarz_tolov (
  id          uuid        primary key default gen_random_uuid(),
  qarz_id     uuid        not null references ehson_qarz(id),
  kassa_id    uuid        not null references ehson_kassa(id),
  pul_turi    text,
  valyuta     text        not null default 'UZS',
  summa       numeric     not null check (summa > 0),              -- so'm ekvivalenti
  fc_summa    numeric     check (fc_summa is null or fc_summa > 0),
  sana        date        not null default ((now() at time zone 'Asia/Tashkent')::date),
  izoh        text,
  ext_ref     text        unique,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  is_deleted  boolean     not null default false
);
create index if not exists ehson_qarz_tolov_qarz_idx on ehson_qarz_tolov (qarz_id);

-- RLS — ehson jadvallari naqshi: faqat select (ehson_page_ok), yozish faqat RPC
do $ehq_rls$
declare t text;
begin
  foreach t in array array['ehson_qarz','ehson_qarz_jadval','ehson_qarz_tolov'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from public, anon', t);
    execute format('grant select on table %I to authenticated', t);
    execute format('drop policy if exists %I on %I', t || '_select', t);
    execute format('create policy %I on %I for select to authenticated using (ehson_page_ok())', t || '_select', t);
  end loop;
end
$ehq_rls$;

-- ehson_tarix.obyekt check'iga 'qarz','qarz_tolov' qo'shish (constraint nomi avto — pg_constraint dan topiladi)
do $ehq_tarix$
declare v_name text; v_def text;
begin
  select conname, pg_get_constraintdef(oid) into v_name, v_def
    from pg_constraint
   where conrelid = 'public.ehson_tarix'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%obyekt%'
   limit 1;
  if v_name is not null and v_def not like '%qarz_tolov%' then
    execute format('alter table ehson_tarix drop constraint %I', v_name);
    execute 'alter table ehson_tarix add constraint ehson_tarix_obyekt_check check (obyekt in (''oila'',''azo'',''berish'',''kirim'',''reja'',''kassa'',''qarz'',''qarz_tolov''))';
  end if;
end
$ehq_tarix$;

-- ######## 2) YORDAMCHI ########
-- oy qo'shish, oy oxiriga clamp (31.01 + 1 oy = 28/29.02) — PROVODKA_QARZ.sql qarz_oy_qosh bilan bir xil, mustaqil nusxa
create or replace function _ehson_oy_qosh(p_date date, p_n int)
returns date
language sql
immutable
as $fn$
  select least(
    (date_trunc('month', p_date) + make_interval(months => p_n))::date + (extract(day from p_date)::int - 1),
    (date_trunc('month', p_date) + make_interval(months => p_n + 1))::date - 1
  );
$fn$;
revoke all on function _ehson_oy_qosh(date, int) from public, anon, authenticated;

-- ######## 3) QOLDIQ VIEW'LARI — qarz chiqimi/qaytimi (ustunlar OXIRIGA qo'shildi) ########
create or replace view v_ehson_kassa_pul as
select
  x.kassa_id,
  x.pul_turi,
  x.valyuta,
  sum(x.kirim)                                                              as kirim,
  sum(x.berildi)                                                            as berildi,
  sum(x.kirim) - sum(x.berildi) - sum(x.qarz_berildi) + sum(x.qarz_qaytdi)  as qoldiq,
  sum(x.fc_kirim)                                                           as fc_kirim,
  sum(x.fc_berildi)                                                         as fc_berildi,
  sum(x.fc_kirim) - sum(x.fc_berildi) - sum(x.fc_qarz_berildi) + sum(x.fc_qarz_qaytdi) as fc_qoldiq,
  sum(x.qarz_berildi)                                                       as qarz_berildi,
  sum(x.qarz_qaytdi)                                                        as qarz_qaytdi,
  sum(x.fc_qarz_berildi)                                                    as fc_qarz_berildi,
  sum(x.fc_qarz_qaytdi)                                                     as fc_qarz_qaytdi
from (
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS') as valyuta,
         summa as kirim, 0::numeric as berildi, 0::numeric as qarz_berildi, 0::numeric as qarz_qaytdi,
         coalesce(fc_summa, 0) as fc_kirim, 0::numeric as fc_berildi, 0::numeric as fc_qarz_berildi, 0::numeric as fc_qarz_qaytdi
    from ehson_kirim where is_deleted = false
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, summa, 0, 0,
         0, coalesce(fc_summa, 0), 0, 0
    from ehson_berish where holat = 'berildi'
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, summa, 0,
         0, 0, coalesce(fc_summa, 0), 0
    from ehson_qarz where holat in ('faol', 'yopildi')
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, 0, summa,
         0, 0, 0, coalesce(fc_summa, 0)
    from ehson_qarz_tolov where is_deleted = false
) x
group by x.kassa_id, x.pul_turi, x.valyuta;
alter view v_ehson_kassa_pul set (security_invoker = on);
revoke all on v_ehson_kassa_pul from public, anon;
grant select on v_ehson_kassa_pul to authenticated;
comment on view v_ehson_kassa_pul is
  'Har jamg''arma + pul turi kesimida kirim/berildi/qoldiq (so''m) va fc_* (dollar). 2026-10-04: qoldiq = kirim − berildi − '
  'qarz_berildi + qarz_qaytdi (ehson_qarz faol/yopildi, ehson_qarz_tolov). pul_turi null = eski yozuvlar.';

create or replace view v_ehson_kassa as
select k.id, k.nom, k.is_active,
  coalesce(ki.summa, 0) as kirim,
  coalesce(be.summa, 0) as berildi,
  coalesce(ki.summa, 0) - coalesce(be.summa, 0) - coalesce(qb.summa, 0) + coalesce(qq.summa, 0) as qoldiq,
  coalesce(qb.summa, 0) as qarz_berildi,
  coalesce(qq.summa, 0) as qarz_qaytdi
from ehson_kassa k
left join lateral (select sum(summa) as summa from ehson_kirim       where kassa_id = k.id and is_deleted = false) ki on true
left join lateral (select sum(summa) as summa from ehson_berish      where kassa_id = k.id and holat = 'berildi') be on true
left join lateral (select sum(summa) as summa from ehson_qarz        where kassa_id = k.id and holat in ('faol','yopildi')) qb on true
left join lateral (select sum(summa) as summa from ehson_qarz_tolov  where kassa_id = k.id and is_deleted = false) qq on true;
alter view v_ehson_kassa set (security_invoker = on);
revoke all on v_ehson_kassa from public, anon;
grant select on v_ehson_kassa to authenticated;

-- ######## 4) QATOR SERIALIZATORI (ichki) ########
--  asosiy/tolandi/qoldi/oylik_summa/kechikkan_summa — QARZ VALYUTASI birligida; summa — so'm ekvivalenti.
create or replace function _ehson_qarz_qator(q ehson_qarz)
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  with t as (
    select coalesce(sum(case when q.valyuta = 'USD' then coalesce(t.fc_summa, 0) else t.summa end), 0) as tolandi
      from ehson_qarz_tolov t where t.qarz_id = q.id and t.is_deleted = false
  ),
  j as (
    select min(j.sana) filter (where j.tolangan < j.summa) as keyingi_sana,
           coalesce(sum(j.summa - j.tolangan) filter (where j.tolangan < j.summa
                                                     and j.sana < (now() at time zone 'Asia/Tashkent')::date), 0) as kechikkan_summa
      from ehson_qarz_jadval j where j.qarz_id = q.id
  ),
  a as (
    select case when q.valyuta = 'USD' then coalesce(q.fc_summa, 0) else q.summa end as asosiy
  )
  select jsonb_build_object(
    'id',            q.id,
    'qarzdor_turi',  q.qarzdor_turi,
    'qarzdor_nom',   case when q.qarzdor_turi = 'oila' then (select o.fio from ehson_oila o where o.id = q.oila_id) else q.ism end,
    'oila_id',       q.oila_id,
    'oila_kod',      (select o.oila_kod from ehson_oila o where o.id = q.oila_id),
    'telefon',       q.telefon,
    'kassa_id',      q.kassa_id,
    'kassa_nom',     (select k.nom from ehson_kassa k where k.id = q.kassa_id),
    'pul_turi',      q.pul_turi,
    'pul_turi_nom',  (select pt.nom from ehson_pul_turi pt where pt.kassa_id = q.kassa_id and pt.kod = q.pul_turi),
    'valyuta',       q.valyuta,
    'summa',         q.summa,
    'fc_summa',      q.fc_summa,
    'asosiy',        a.asosiy,
    'tolandi',       t.tolandi,
    'qoldi',         greatest(a.asosiy - t.tolandi, 0),
    'muddat_turi',   q.muddat_turi,
    'boshlanish',    q.boshlanish,
    'tugash',        q.tugash,
    'oylar_soni',    q.oylar_soni,
    'oylik_summa',   q.oylik_summa,
    'keyingi_sana',  case when q.holat = 'faol' then j.keyingi_sana end,
    'kechikkan_kun', case when q.holat = 'faol' and j.keyingi_sana < (now() at time zone 'Asia/Tashkent')::date
                          then ((now() at time zone 'Asia/Tashkent')::date - j.keyingi_sana) else 0 end,
    'kechikkan_summa', case when q.holat = 'faol' then j.kechikkan_summa else 0 end,
    'holat',         q.holat,
    'izoh',          q.izoh,
    'sana',          q.sana,
    'kim',           (select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = q.created_by),
    'created_at',    q.created_at,
    'yopilgan_at',   q.yopilgan_at,
    'bekor_sabab',   q.bekor_sabab,
    'created_by',    q.created_by
  )
  from t, j, a;
$fn$;
revoke all on function _ehson_qarz_qator(ehson_qarz) from public, anon, authenticated;

-- ######## 5) QARZ BERISH ########
create or replace function ehson_qarz_ber(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid        uuid    := auth.uid();
  v_kassa      uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_summa      numeric := nullif(p->>'summa', '')::numeric;
  v_fc_p       numeric := nullif(p->>'fc_summa', '')::numeric;
  v_pul_turi_p text    := nullif(p->>'pul_turi', '');
  v_sana       date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_qt         text    := nullif(p->>'qarzdor_turi', '');
  v_oila       uuid    := nullif(p->>'oila_id', '')::uuid;
  v_ism        text    := nullif(btrim(coalesce(p->>'ism', '')), '');
  v_tel        text    := nullif(btrim(coalesce(p->>'telefon', '')), '');
  v_mt         text    := nullif(p->>'muddat_turi', '');
  v_tugash     date    := nullif(p->>'tugash', '')::date;
  v_bosh       date    := nullif(p->>'boshlanish', '')::date;
  v_oylar      int     := nullif(p->>'oylar_soni', '')::int;
  v_izoh       text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_ext        text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  v_kassa_r    ehson_kassa;
  v_pt         ehson_pul_turi;
  v_pt_cnt     int;
  v_kurs       numeric;
  v_qoldiq     numeric;
  v_qoldiq_fc  numeric;
  v_valyuta    text := 'UZS';
  v_asosiy     numeric;
  v_oylik      numeric;
  v_used       numeric := 0;
  v_row        numeric;
  v_i          int;
  v_id         uuid;
  v_exist      uuid;
  v_cnt        int;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Avtorizatsiya kerak'); end if;
  if not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Ehson sahifasi ruxsatingizda yoq'); end if;

  if v_ext is not null then
    select id into v_exist from ehson_qarz where ext_ref = v_ext;
    if found then return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist); end if;
  end if;

  -- qarzdor
  if v_qt = 'oila' then
    if v_oila is null then return jsonb_build_object('ok', false, 'kod', 'qarzdor_kerak'); end if;
    if not exists (select 1 from ehson_oila o where o.id = v_oila) then
      return jsonb_build_object('ok', false, 'kod', 'oila_topilmadi');
    end if;
    v_ism := null;
  elsif v_qt = 'shaxs' then
    if v_ism is null or length(v_ism) < 2 then return jsonb_build_object('ok', false, 'kod', 'qarzdor_kerak'); end if;
    v_oila := null;
  else
    return jsonb_build_object('ok', false, 'kod', 'qarzdor_kerak');
  end if;

  if v_izoh is null or length(v_izoh) < 3 then return jsonb_build_object('ok', false, 'kod', 'izoh_kerak'); end if;

  -- muddat
  if v_mt = 'bir_martalik' then
    if v_tugash is null or v_tugash < v_sana then return jsonb_build_object('ok', false, 'kod', 'muddat_notogri'); end if;
    v_bosh := null; v_oylar := null;
  elsif v_mt = 'oylik' then
    if v_bosh is null or v_oylar is null or v_oylar < 1 or v_oylar > 120 then
      return jsonb_build_object('ok', false, 'kod', 'muddat_notogri');
    end if;
    v_tugash := _ehson_oy_qosh(v_bosh, v_oylar - 1);
  else
    return jsonb_build_object('ok', false, 'kod', 'muddat_notogri');
  end if;

  -- kassa (ehson_ber bilan bir xil)
  if v_kassa is null then
    select count(*) into v_cnt from ehson_kassa where is_active and not is_container;
    if v_cnt = 1 then
      select id into v_kassa from ehson_kassa where is_active and not is_container;
    else
      return jsonb_build_object('ok', false, 'kod', 'kassa_tanlanmagan');
    end if;
  end if;
  select * into v_kassa_r from ehson_kassa where id = v_kassa and is_active;
  if not found then return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi'); end if;
  if v_kassa_r.is_container then return jsonb_build_object('ok', false, 'kod', 'kassa_konteyner'); end if;

  -- pul turi + valyuta/kurs (ehson_ber bilan bir xil)
  select count(*) into v_pt_cnt from ehson_pul_turi where kassa_id = v_kassa and is_active;
  if v_pt_cnt > 0 then
    if v_pul_turi_p is null then return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak'); end if;
    select * into v_pt from ehson_pul_turi where kassa_id = v_kassa and kod = v_pul_turi_p and is_active;
    if not found then return jsonb_build_object('ok', false, 'kod', 'pul_turi_topilmadi'); end if;
    v_valyuta := coalesce(v_pt.valyuta, 'UZS');
    if v_valyuta = 'USD' then
      if v_fc_p is null or v_fc_p <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
      v_kurs := null;
      if exists (select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
                  where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs' and oidvectortypes(pr.proargtypes) = 'text') then
        execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
      end if;
      if v_kurs is null or v_kurs <= 0 then return jsonb_build_object('ok', false, 'kod', 'kurs_yoq'); end if;
      v_summa := round(v_fc_p * v_kurs);
    else
      v_fc_p := null;
      if v_summa is null or v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    end if;
  else
    v_pul_turi_p := null; v_fc_p := null;
    if v_summa is null or v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
  end if;

  -- qoldiq (view endi qarzni ham hisobga oladi)
  perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || v_kassa::text));
  if v_pt.id is not null then
    select qoldiq, fc_qoldiq into v_qoldiq, v_qoldiq_fc from v_ehson_kassa_pul where kassa_id = v_kassa and pul_turi = v_pt.kod;
    if v_valyuta = 'USD' then
      if coalesce(v_qoldiq_fc, 0) < v_fc_p then return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi'); end if;
    else
      if coalesce(v_qoldiq, 0) < v_summa then return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi'); end if;
    end if;
  else
    select qoldiq into v_qoldiq from v_ehson_kassa where id = v_kassa;
    if coalesce(v_qoldiq, 0) < v_summa then return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi'); end if;
  end if;

  -- asosiy (qarz valyutasi birligi) va oylik
  v_asosiy := case when v_valyuta = 'USD' then v_fc_p else v_summa end;
  if v_mt = 'oylik' then
    v_oylik := case when v_valyuta = 'USD' then round(v_asosiy / v_oylar, 2) else floor(v_asosiy / v_oylar) end;
    if v_oylik <= 0 then return jsonb_build_object('ok', false, 'kod', 'muddat_notogri'); end if;
  end if;

  insert into ehson_qarz (kassa_id, pul_turi, valyuta, summa, fc_summa, qarzdor_turi, oila_id, ism, telefon,
                          muddat_turi, boshlanish, tugash, oylar_soni, oylik_summa, sana, izoh, holat, ext_ref, created_by)
  values (v_kassa, v_pul_turi_p, v_valyuta, v_summa, v_fc_p, v_qt, v_oila, v_ism, v_tel,
          v_mt, v_bosh, v_tugash, v_oylar, v_oylik, v_sana, v_izoh, 'faol', v_ext, v_uid)
  returning id into v_id;

  -- grafik
  if v_mt = 'bir_martalik' then
    insert into ehson_qarz_jadval (qarz_id, n, sana, summa) values (v_id, 1, v_tugash, v_asosiy);
  else
    for v_i in 1..v_oylar loop
      if v_i < v_oylar then v_row := v_oylik; v_used := v_used + v_row;
      else v_row := v_asosiy - v_used; end if;   -- oxirgi oy qoldiqni oladi
      insert into ehson_qarz_jadval (qarz_id, n, sana, summa) values (v_id, v_i, _ehson_oy_qosh(v_bosh, v_i - 1), v_row);
    end loop;
  end if;

  perform _ehson_tarix_yoz('qarz', v_id, 'yaratildi',
    jsonb_build_object('kassa_id', v_kassa, 'pul_turi', v_pul_turi_p, 'summa', v_summa, 'fc_summa', v_fc_p,
                       'valyuta', v_valyuta, 'qarzdor_turi', v_qt, 'oila_id', v_oila, 'ism', v_ism,
                       'muddat_turi', v_mt, 'tugash', v_tugash, 'oylar_soni', v_oylar));
  return jsonb_build_object('ok', true, 'id', v_id);
exception
  when unique_violation then
    select id into v_exist from ehson_qarz where ext_ref = v_ext;
    return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;
revoke all on function ehson_qarz_ber(jsonb) from public, anon;
grant execute on function ehson_qarz_ber(jsonb) to authenticated;

-- ######## 6) TO'LOV QABUL QILISH (jamg'armaga qaytadi, FIFO) ########
create or replace function ehson_qarz_tolov(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid    := auth.uid();
  v_qid     uuid    := nullif(p->>'qarz_id', '')::uuid;
  v_kassa   uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_pt_p    text    := nullif(p->>'pul_turi', '');
  v_summa   numeric := nullif(p->>'summa', '')::numeric;
  v_fc_p    numeric := nullif(p->>'fc_summa', '')::numeric;
  v_sana    date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_izoh    text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_ext     text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  q         ehson_qarz;
  v_pt      ehson_pul_turi;
  v_pt_cnt  int;
  v_pt_val  text;
  v_kurs    numeric;
  v_birlik  numeric;
  v_qoldi   numeric;
  v_rem     numeric;
  v_alloc   numeric;
  jr        record;
  v_id      uuid;
  v_exist   uuid;
  v_all     boolean;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Avtorizatsiya kerak'); end if;
  if not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Ehson sahifasi ruxsatingizda yoq'); end if;
  if v_ext is not null then
    select id into v_exist from ehson_qarz_tolov where ext_ref = v_ext;
    if found then return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist); end if;
  end if;

  select * into q from ehson_qarz where id = v_qid for update;
  if not found then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if q.holat <> 'faol' then return jsonb_build_object('ok', false, 'kod', 'holat'); end if;

  v_kassa := coalesce(v_kassa, q.kassa_id);
  if not exists (select 1 from ehson_kassa where id = v_kassa and is_active and not is_container) then
    return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi');
  end if;
  v_pt_p := coalesce(v_pt_p, case when v_kassa = q.kassa_id then q.pul_turi end);

  select count(*) into v_pt_cnt from ehson_pul_turi where kassa_id = v_kassa and is_active;
  if v_pt_cnt > 0 then
    if v_pt_p is null then return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak'); end if;
    select * into v_pt from ehson_pul_turi where kassa_id = v_kassa and kod = v_pt_p and is_active;
    if not found then return jsonb_build_object('ok', false, 'kod', 'pul_turi_topilmadi'); end if;
    v_pt_val := coalesce(v_pt.valyuta, 'UZS');
  else
    v_pt_p := null; v_pt_val := 'UZS';
  end if;
  if v_pt_val <> q.valyuta then return jsonb_build_object('ok', false, 'kod', 'valyuta_mos_emas'); end if;

  if q.valyuta = 'USD' then
    if v_fc_p is null or v_fc_p <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    v_kurs := null;
    if exists (select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
                where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs' and oidvectortypes(pr.proargtypes) = 'text') then
      execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
    end if;
    if v_kurs is null or v_kurs <= 0 then return jsonb_build_object('ok', false, 'kod', 'kurs_yoq'); end if;
    v_summa := round(v_fc_p * v_kurs);
    v_birlik := v_fc_p;
  else
    v_fc_p := null;
    if v_summa is null or v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    v_birlik := v_summa;
  end if;

  select coalesce(sum(j.summa - j.tolangan), 0) into v_qoldi from ehson_qarz_jadval j where j.qarz_id = q.id;
  if v_birlik > v_qoldi + 0.009 then
    return jsonb_build_object('ok', false, 'kod', 'kop', 'qoldi', v_qoldi);
  end if;

  insert into ehson_qarz_tolov (qarz_id, kassa_id, pul_turi, valyuta, summa, fc_summa, sana, izoh, ext_ref, created_by)
  values (q.id, v_kassa, v_pt_p, q.valyuta, v_summa, v_fc_p, v_sana, v_izoh, v_ext, v_uid)
  returning id into v_id;

  -- FIFO — eng eski to'lanmagan qatordan
  v_rem := v_birlik;
  for jr in select * from ehson_qarz_jadval where qarz_id = q.id and tolangan < summa order by n for update loop
    exit when v_rem <= 0;
    v_alloc := least(v_rem, jr.summa - jr.tolangan);
    update ehson_qarz_jadval set tolangan = tolangan + v_alloc where id = jr.id;
    v_rem := v_rem - v_alloc;
  end loop;

  select not exists (select 1 from ehson_qarz_jadval where qarz_id = q.id and tolangan < summa) into v_all;
  if v_all then
    update ehson_qarz set holat = 'yopildi', yopilgan_at = now() where id = q.id;
  end if;

  perform _ehson_tarix_yoz('qarz_tolov', v_id, 'tolov',
    jsonb_build_object('qarz_id', q.id, 'kassa_id', v_kassa, 'pul_turi', v_pt_p, 'summa', v_summa, 'fc_summa', v_fc_p, 'yopildi', v_all));
  return jsonb_build_object('ok', true, 'id', v_id, 'holat', case when v_all then 'yopildi' else 'faol' end,
                            'qoldi', greatest(v_qoldi - v_birlik, 0));
exception
  when unique_violation then
    select id into v_exist from ehson_qarz_tolov where ext_ref = v_ext;
    return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;
revoke all on function ehson_qarz_tolov(jsonb) from public, anon;
grant execute on function ehson_qarz_tolov(jsonb) to authenticated;

-- ######## 7) BEKOR (to'lov yo'q bo'lsa; admin yoki yaratgan) ########
create or replace function ehson_qarz_bekor(p_id uuid, p_sabab text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  q ehson_qarz;
  v_sabab text := nullif(btrim(coalesce(p_sabab, '')), '');
begin
  if v_uid is null or not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  if v_sabab is null or length(v_sabab) < 3 then return jsonb_build_object('ok', false, 'kod', 'sabab_kerak'); end if;
  select * into q from ehson_qarz where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if q.holat <> 'faol' then return jsonb_build_object('ok', false, 'kod', 'holat'); end if;
  if not (_ehson_is_admin() or q.created_by = v_uid) then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  if exists (select 1 from ehson_qarz_tolov where qarz_id = q.id and is_deleted = false) then
    return jsonb_build_object('ok', false, 'kod', 'tolov_bor');
  end if;
  update ehson_qarz set holat = 'bekor', bekor_sabab = v_sabab, bekor_by = v_uid, bekor_at = now() where id = q.id;
  perform _ehson_tarix_yoz('qarz', q.id, 'bekor', jsonb_build_object('sabab', v_sabab));
  return jsonb_build_object('ok', true, 'id', q.id);
end
$fn$;
revoke all on function ehson_qarz_bekor(uuid, text) from public, anon;
grant execute on function ehson_qarz_bekor(uuid, text) to authenticated;

-- ######## 8) RO'YXAT + STAT ########
create or replace function ehson_qarz_royxat(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_holat  text := nullif(p->>'holat', '');
  v_q      text := nullif(btrim(coalesce(p->>'q', '')), '');
  v_kassa  uuid := nullif(p->>'kassa_id', '')::uuid;
  v_limit  int  := least(greatest(coalesce(nullif(p->>'limit', '')::int, 50), 1), 500);
  v_offset int  := greatest(coalesce(nullif(p->>'offset', '')::int, 0), 0);
  v_today  date := (now() at time zone 'Asia/Tashkent')::date;
  v_rows   jsonb; v_jami int; v_stat jsonb;
begin
  if auth.uid() is null or not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;

  with base as (
    select q.*,
           (select min(j.sana) from ehson_qarz_jadval j where j.qarz_id = q.id and j.tolangan < j.summa) as keyingi_sana,
           case when q.qarzdor_turi = 'oila' then (select o.fio || ' ' || coalesce(o.oila_kod, '') from ehson_oila o where o.id = q.oila_id)
                else coalesce(q.ism, '') || ' ' || coalesce(q.telefon, '') end as qidiruv
      from ehson_qarz q
     where (v_kassa is null or q.kassa_id = v_kassa)
  ),
  f as (
    select b.* from base b
     where (v_holat is null
            or (v_holat = 'kechikkan' and b.holat = 'faol' and b.keyingi_sana < v_today)
            or (v_holat <> 'kechikkan' and b.holat = v_holat))
       and (v_q is null or b.qidiruv ilike '%' || v_q || '%' or b.izoh ilike '%' || v_q || '%')
  )
  select coalesce((
           -- 🔴 _ehson_qarz_qator(q.*) — jadvalning O'Z qatori (f/x da qo'shimcha ustun bor, row type mos kelmaydi)
           select jsonb_agg(_ehson_qarz_qator(q.*) order by
                    (x.holat = 'faol') desc,
                    (x.holat = 'faol' and x.keyingi_sana < v_today) desc,
                    x.keyingi_sana asc nulls last,
                    x.created_at desc)
             from (select f.id, f.holat, f.keyingi_sana, f.created_at
                     from f
                    order by (f.holat = 'faol') desc, (f.holat = 'faol' and f.keyingi_sana < v_today) desc,
                             f.keyingi_sana asc nulls last, f.created_at desc
                    limit v_limit offset v_offset) x
             join ehson_qarz q on q.id = x.id
         ), '[]'::jsonb),
         (select count(*) from f)
    into v_rows, v_jami;

  -- stat — kassa filtri bo'yicha, holat/qidiruvdan qat'i nazar
  select jsonb_build_object(
           'faol_soni',      count(*) filter (where b.holat = 'faol'),
           'kechikkan_soni', count(*) filter (where b.holat = 'faol' and b.keyingi_sana < v_today),
           'yopildi_soni',   count(*) filter (where b.holat = 'yopildi'),
           'ochiq_uzs',      coalesce(sum(case when b.holat = 'faol' and b.valyuta <> 'USD'
                                               then b.summa - coalesce((select sum(t.summa) from ehson_qarz_tolov t where t.qarz_id = b.id and not t.is_deleted), 0) end), 0),
           'ochiq_usd',      coalesce(sum(case when b.holat = 'faol' and b.valyuta = 'USD'
                                               then coalesce(b.fc_summa, 0) - coalesce((select sum(coalesce(t.fc_summa, 0)) from ehson_qarz_tolov t where t.qarz_id = b.id and not t.is_deleted), 0) end), 0)
         )
    into v_stat
    from (select q.*, (select min(j.sana) from ehson_qarz_jadval j where j.qarz_id = q.id and j.tolangan < j.summa) as keyingi_sana
            from ehson_qarz q where (v_kassa is null or q.kassa_id = v_kassa)) b;

  return jsonb_build_object('ok', true, 'rows', v_rows, 'jami', v_jami, 'stat', v_stat);
end
$fn$;
revoke all on function ehson_qarz_royxat(jsonb) from public, anon;
grant execute on function ehson_qarz_royxat(jsonb) to authenticated;

-- ######## 9) KARTA ########
create or replace function ehson_qarz_kart(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  q ehson_qarz;
  v_today date := (now() at time zone 'Asia/Tashkent')::date;
begin
  if auth.uid() is null or not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  select * into q from ehson_qarz where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  return jsonb_build_object(
    'ok', true,
    'qarz', _ehson_qarz_qator(q),
    'jadval', coalesce((
      select jsonb_agg(jsonb_build_object(
               'n', j.n, 'sana', j.sana, 'summa', j.summa, 'tolangan', j.tolangan,
               'holat', case when j.tolangan >= j.summa then 'tolandi'
                             when j.tolangan > 0 and j.sana < v_today and q.holat = 'faol' then 'kechikkan'
                             when j.tolangan > 0 then 'qisman'
                             when j.sana < v_today and q.holat = 'faol' then 'kechikkan'
                             else 'kutilmoqda' end) order by j.n)
        from ehson_qarz_jadval j where j.qarz_id = q.id), '[]'::jsonb),
    'tolovlar', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'sana', t.sana, 'summa', t.summa, 'fc_summa', t.fc_summa, 'valyuta', t.valyuta,
               'kassa_nom', (select k.nom from ehson_kassa k where k.id = t.kassa_id), 'pul_turi', t.pul_turi,
               'izoh', t.izoh, 'created_at', t.created_at,
               'kim', (select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = t.created_by)
             ) order by t.sana desc, t.created_at desc)
        from ehson_qarz_tolov t where t.qarz_id = q.id and t.is_deleted = false), '[]'::jsonb),
    'tarix', coalesce((
      select jsonb_agg(jsonb_build_object('hodisa', h.hodisa, 'data', h.data, 'vaqt', h.vaqt,
               'kim_nom', (select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = h.kim)) order by h.vaqt desc)
        from ehson_tarix h
       where (h.obyekt = 'qarz' and h.obyekt_id = q.id)
          or (h.obyekt = 'qarz_tolov' and (h.data ->> 'qarz_id') = q.id::text)), '[]'::jsonb)
  );
end
$fn$;
revoke all on function ehson_qarz_kart(uuid) from public, anon;
grant execute on function ehson_qarz_kart(uuid) to authenticated;

notify pgrst, 'reload schema';

-- ######## 10) TEKSHIRUV ########
select (select count(*) from ehson_qarz) as qarz_soni,
       (select count(*) from v_ehson_kassa) as kassa_soni,
       (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_name = 'v_ehson_kassa_pul') as pul_view_ustunlar;
