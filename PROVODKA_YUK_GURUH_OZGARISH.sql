-- =====================================================================
--  PROVODKA_YUK_GURUH_OZGARISH.sql — GURUH GRAFIGI + AROS O'ZGARISH KUZATUVI
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  #####  MAQSAD — 1-QISM (GURUH GRAFIGI)  ###################################
--  Asilbek qarori (2026-09-14): bir yetkazib beruvchidan bir nechta yuk
--  (hujjat) kelsa, ularga BITTA to'lov grafigi qo'yiladi — to'lovlar
--  guruhdagi HAMMA yukdan yig'ilib, guruh muddatlariga eng eskisidan
--  boshlab (FIFO) yopiladi. Guruh faqat BIR XIL valyutadagi yuklardan;
--  yuk faqat BITTA grafikda bo'ladi (guruhga qo'shilganda eski YAKKA
--  grafigi o'chadi). 🔴 "Bir xil yetkazib beruvchi" shartini SQL
--  TEKSHIRA OLMAYDI — Provodka bazasida yuk yetkazib beruvchisi umuman
--  saqlanmaydi (yakka `yuk_deadline` bilan bir xil cheklov, PROVODKA_
--  5KUNLIK.sql'dagi izoh). Bu — klient tomonining mas'uliyati; guruh
--  darajasida saqlangan `yetkazuvchi` faqat KO'RSATISH matni.
--
--  #####  MAQSAD — 2-QISM (AROS O'ZGARISH KUZATUVI)  #########################
--  «Shu id'li yuk uchun provodka yozdim, keyin Aros adminkadan butunlay
--  o'chirildi yoki puli kamaytirildi — buni ko'rsatish kerak» (Asilbek).
--  n8n har sinxronda joriy oyna (oxirgi N kun) yuklarini yuboradi,
--  `sync_aros_yuk_snapshot` avvalgi suratlar bilan solishtiradi va
--  narx/valyuta/mavjudlik o'zgarishini `aros_yuk_ozgarish` jurnaliga
--  yozadi (Provodka ma'lumoti bo'lsa "muhim" bayrog'i bilan).
--
--  #####  FAYL TARKIBI  #######################################################
--     0-BO'LIM  — old shart tekshiruvi (1-qism)
--     1-BO'LIM  — yuk_grafik_guruh jadvali (+ RLS)
--     2-BO'LIM  — yuk_grafik_guruh_yuk jadvali (+ RLS, yuk_id UNIQUE)
--     3-BO'LIM  — yuk_tolov_grafik.guruh_id ustuni (+ indeks)
--     4-BO'LIM  — _yuk_grafik_taqsim QAYTA E'LON — guruh-aware FIFO
--     5-BO'LIM  — yuk_grafik_guruh_maqsad(p_yuklar)
--     6-BO'LIM  — yuk_grafik_guruh_saqla(...)
--     7-BO'LIM  — yuk_grafik_royxat QAYTA E'LON — guruh maydonlari
--     8-BO'LIM  — beshkunlik_qarz_detal_v3 QAYTA E'LON — guruh maydonlari
--     9-BO'LIM  — PostgREST sxema keshini yangilash (1-qism)
--    10-BO'LIM  — YAKUNIY TEKSHIRUV (1-qism, faqat select/raise)
--    11-BO'LIM  — old shart tekshiruvi (2-qism)
--    12-BO'LIM  — aros_yuk_snapshot jadvali (+ RLS)
--    13-BO'LIM  — aros_yuk_ozgarish jadvali (+ RLS)
--    14-BO'LIM  — ICHKI yordamchilar: _ays_muhim / _ays_izoh / _ays_ochiq_bor
--    15-BO'LIM  — sync_aros_yuk_snapshot(p_data) — service_role ONLY
--    16-BO'LIM  — aros_yuk_ozgarish_royxat(...)
--    17-BO'LIM  — aros_yuk_ozgarish_korildi(p_ids)
--    18-BO'LIM  — PostgREST sxema keshini yangilash (2-qism)
--    19-BO'LIM  — YAKUNIY TEKSHIRUV (2-qism, faqat select/raise)
--
--  #####  ADDITIVE KAFOLATI  ##################################################
--   * Hech narsa drop qilinmaydi. `yuk_tolov_grafik`ga faqat YANGI ustun
--     (`guruh_id`, nullable) qo'shiladi — mavjud yakka grafiklar butunlay
--     tegilmagan qoladi (guruh_id null bo'lib qoladi, eski xatti-harakat
--     saqlanadi). `_yuk_grafik_taqsim`/`yuk_grafik_royxat` OUT ustunlari
--     faqat OXIRIGA qo'shiladi (Postgres CREATE OR REPLACE FUNCTION
--     mavjud OUT ustunlarni saqlab, yangilarini oxiriga qo'shishga
--     ruxsat beradi — eski pozitsion o'quvchilar buzilmaydi).
--     `beshkunlik_qarz_v3` bu faylda UMUMAN QAYTA E'LON QILINMAYDI —
--     u ichida `_yuk_grafik_taqsim`ni faqat NOM bilan chaqiradi, shuning
--     uchun guruh-aware FIFO'dan avtomatik foyda ko'radi (pastda
--     10-BO'LIMda misol bilan tasdiqlangan).
--   * Idempotent: `create table if not exists`, `create or replace
--     function`, `drop policy if exists` + `create policy`, `alter table
--     add column if not exists`, `create index/unique index if not exists`,
--     `drop trigger if exists` + `create trigger`.
--   * Anonim `do` bloki YO'Q — har `do` bloki nomlangan teg bilan, har
--     funksiya tanasi ham nomlangan teg bilan. Izohlarda ketma-ket
--     dollar belgi YOZILMAGAN (soxta blok xavfi — CLAUDE.md).
--
--  #####  RUXSAT  #############################################################
--  1-qism (guruh): o'qish/yozish — `yuk_tolov_grafik` bilan AYNAN bir xil
--  qoida (o'qish: beshkunlik|yuklar sahifasi; yozish: beshkunlik_edit|yuklar).
--  2-qism (Aros o'zgarish): o'qish — `yuklar` YOKI `beshkunlik` sahifasi;
--  `korildi` belgilash — `yuklar` sahifasi; sync — FAQAT service_role (n8n).
--  🔴 Supabase yangi jadvalga `authenticated`ga ALL huquqni avtomatik
--  beradi — shuning uchun har yangi jadvalda darrov `revoke all ... from
--  public, anon, authenticated` + kerakli `grant select`.
--
--  #####  TALAB (0/11-BO'LIM tekshiradi)  #####################################
--     yuk_tolov_grafik, _yuk_grafik_maqsad_calc, yuk_grafik_saqla,
--     yuk_grafik_royxat                      — PROVODKA_5KUNLIK_GRAFIK.sql
--     yuk_deadline, entry_yuk, perm_has_page(text), conv_baza_kurs(text)
--     yuk_tannarx, yuk_tannarx_jami(integer[])  — PROVODKA_YUK_TANNARX.sql
--     gen_random_uuid()                      — PG13+ da o'rnatilgan (pg_catalog)
--
--  🔴 SQL'ni ASILBEK o'zi RUN qiladi. Agent bajarmaydi.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (1-QISM)                        ##
-- #####################################################################

do $yg2_pre$
begin
  if to_regclass('public.yuk_tolov_grafik') is null then
    raise exception 'yuk_tolov_grafik jadvali yoq — avval PROVODKA_5KUNLIK_GRAFIK.sql ni bajaring';
  end if;
  if to_regclass('public.yuk_deadline') is null then
    raise exception 'yuk_deadline jadvali yoq — avval PROVODKA_5KUNLIK.sql ni bajaring';
  end if;
  if to_regclass('public.entry_yuk') is null then
    raise exception 'entry_yuk jadvali yoq — avval PROVODKA_YUK_QISMAN.sql ni bajaring';
  end if;
  if to_regprocedure('public._yuk_grafik_maqsad_calc(integer,numeric,text)') is null then
    raise exception '_yuk_grafik_maqsad_calc(integer,numeric,text) yoq — avval PROVODKA_5KUNLIK_GRAFIK.sql ni bajaring';
  end if;
  if to_regprocedure('public.perm_has_page(text)') is null then
    raise exception 'perm_has_page(text) yoq — avval PROVODKA_PAGES_EMPTY.sql ni bajaring';
  end if;
  if to_regprocedure('public.conv_baza_kurs(text)') is null then
    raise exception 'conv_baza_kurs(text) yoq — avval valyuta migratsiyasini bajaring';
  end if;
  -- 🔴 gen_random_uuid() PG13+ da O'RNATILGAN (pg_catalog), public'da EMAS —
  --    shuning uchun 'public.gen_random_uuid()' tekshiruvi yolg'on xato berardi.
  --    Eng ishonchlisi — funksiyani chaqirib ko'rish (search_path bo'yicha topiladi).
  begin
    perform gen_random_uuid();
  exception when others then
    raise exception 'gen_random_uuid() ishlamadi (%) — PG13+ da o''rnatilgan, eski versiyada pgcrypto kerak', sqlerrm;
  end;
end
$yg2_pre$;


-- #####################################################################
-- ##  1-BO'LIM — yuk_grafik_guruh                                     ##
-- #####################################################################
-- Guruh — bir yetkazib beruvchidan bir nechta yukka bitta to'lov grafigi.
-- `yetkazuvchi` FAQAT ko'rsatish matni (Provodkada tekshirilmaydi — yuqoridagi
-- fayl izohi). `valyuta` — guruhdagi HAMMA yuk bir xil bo'lishi shart (server
-- tekshiradi, 6-BO'LIM). `izoh` — butun guruh bo'yicha kelishuv matni
-- (yakka yuk_deadline.izoh bilan bir xil ma'no).

create table if not exists yuk_grafik_guruh (
  id          uuid        primary key default gen_random_uuid(),
  nom         text,
  yetkazuvchi text,
  valyuta     text        not null default 'UZS',
  izoh        text,
  updated_by  uuid,
  updated_at  timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

comment on table yuk_grafik_guruh is
  'Bir yetkazib beruvchidan bir nechta yukka BITTA to''lov grafigi (Asilbek qarori, '
  '2026-09-14). yetkazuvchi — faqat ko''rsatish matni, server tekshirmaydi (Provodkada '
  'yuk yetkazib beruvchisi saqlanmaydi). valyuta — a''zolarning HAMMASI bir xil bo''lishi '
  'shart (yuk_grafik_guruh_saqla tekshiradi). izoh — butun guruh bo''yicha kelishuv matni.';

alter table yuk_grafik_guruh enable row level security;
-- 🔴 Supabase yangi jadvalga authenticated'ga ALL huquqni avtomatik beradi —
--    shuning uchun authenticated'dan HAM olib tashlanadi, keyin faqat SELECT
--    qaytariladi (yozish faqat yuk_grafik_guruh_saqla RPC orqali).
revoke all on table yuk_grafik_guruh from public, anon, authenticated;
grant select on table yuk_grafik_guruh to authenticated;

drop policy if exists yuk_grafik_guruh_sel on yuk_grafik_guruh;
create policy yuk_grafik_guruh_sel on yuk_grafik_guruh
  for select to authenticated
  using (perm_has_page('beshkunlik') or perm_has_page('yuklar'));

-- 🔴 To'g'ridan insert/update/delete policy YO'Q — faqat yuk_grafik_guruh_saqla()
-- (SECURITY DEFINER) yozadi, RLS'ni funksiya egasi sifatida chetlab o'tadi.

drop trigger if exists trg_yuk_grafik_guruh_touch on yuk_grafik_guruh;
create trigger trg_yuk_grafik_guruh_touch
  before insert or update on yuk_grafik_guruh
  for each row execute function _beshkunlik_touch();


-- #####################################################################
-- ##  2-BO'LIM — yuk_grafik_guruh_yuk                                 ##
-- #####################################################################
-- Guruh a'zoligi. `narx`/`valyuta` — shu a'zoning yuk hujjat narxining
-- SURATI (yuk_grafik_guruh_saqla har saqlashda qayta yozadi, yakka
-- yuk_tolov_grafik/yuk_deadline naqshi bilan bir xil). UNIQUE(yuk_id) —
-- "yuk faqat BITTA grafikda" qoidasini BAZA DARAJASIDA kafolatlaydi
-- (RPC ichidagi tekshiruv — 6-BO'LIM — buning USTIGA, xavfsizlik zaxirasi).

create table if not exists yuk_grafik_guruh_yuk (
  guruh_id uuid    not null references yuk_grafik_guruh(id) on delete cascade,
  yuk_id   integer not null,
  narx     numeric,
  valyuta  text,
  primary key (guruh_id, yuk_id)
);

create unique index if not exists yuk_grafik_guruh_yuk_yuk_uniq on yuk_grafik_guruh_yuk(yuk_id);

comment on table yuk_grafik_guruh_yuk is
  'Guruh a''zoligi (bitta yuk — bitta guruh, UNIQUE(yuk_id)). narx/valyuta — '
  'a''zoning yuk hujjat narxining SURATI, yuk_grafik_guruh_saqla har saqlashda qayta yozadi.';

alter table yuk_grafik_guruh_yuk enable row level security;
revoke all on table yuk_grafik_guruh_yuk from public, anon, authenticated;
grant select on table yuk_grafik_guruh_yuk to authenticated;

drop policy if exists yuk_grafik_guruh_yuk_sel on yuk_grafik_guruh_yuk;
create policy yuk_grafik_guruh_yuk_sel on yuk_grafik_guruh_yuk
  for select to authenticated
  using (perm_has_page('beshkunlik') or perm_has_page('yuklar'));

-- 🔴 To'g'ridan insert/update/delete policy YO'Q — faqat yuk_grafik_guruh_saqla().


-- #####################################################################
-- ##  3-BO'LIM — yuk_tolov_grafik.guruh_id                            ##
-- #####################################################################
-- null = yakka yuk grafigi (eski xatti-harakat, tegilmagan). Guruh qatori —
-- bitta jismoniy qator (bir muddat), lekin uning `yuk_id`si guruhning
-- VAKIL a'zosi (eng kichik yuk_id, yuk_grafik_guruh_saqla tanlaydi) —
-- to'lovlar barcha a'zolardan FIFO yig'iladi (4-BO'LIM), shuning uchun
-- bitta qator IKKI MARTA sanalmaydi (yuk_tolov_grafik'da bitta jismoniy
-- qator — beshkunlik_qarz_v3 shu qatorlarni id bo'yicha sanaydi).

alter table yuk_tolov_grafik add column if not exists guruh_id uuid references yuk_grafik_guruh(id) on delete set null;

create index if not exists yuk_tolov_grafik_guruh_idx on yuk_tolov_grafik(guruh_id);

comment on column yuk_tolov_grafik.guruh_id is
  'null = yakka yuk grafigi (eski). Bo''lmasa — guruh qatori: yuk_id guruhning '
  'VAKIL a''zosi (eng kichik), to''lovlar HAMMA a''zodan FIFO yig''iladi.';


-- #####################################################################
-- ##  4-BO'LIM — _yuk_grafik_taqsim QAYTA E'LON — guruh-aware FIFO    ##
-- #####################################################################
-- Imzo bir xil (p_yuk_ids integer[]). Mantiq yakka qatorlar uchun
-- O'ZGARMAGAN. Guruh qatori uchun: (a) shu guruhning HAMMA grafik qatori
-- BITTA kumulyativ zanjirda (partition kaliti guruh_id, yuk_id emas);
-- (b) to'lovlar shu guruhning HAMMA a'zosidan (entry_yuk.yuk_id — guruh
-- a'zosi bo'lgan HAR QANDAY id) BITTA kumulyativ zanjirda. Natijada
-- yuqoridagi (3-BO'LIM) FIFO formula O'ZGARMAYDI — faqat "kalit" guruh
-- uchun yuk_id o'rniga guruh_id.
--
-- p_yuk_ids berilganda: guruh qatori kiradi agar VAKIL yuk_id ro'yxatda
-- bo'lsa YOKI guruhning ISTALGAN a'zosi ro'yxatda bo'lsa (bitta a'zoning
-- id'si bilan so'ralganda ham butun guruh qatori qaytadi — u yakka
-- ko'rinishda ko'rsatiladigan "shu yukning grafigi").
--
-- Yangi OUT ustunlar OXIRIGA qo'shilgan (guruh_id, guruh_yuklar) — eski
-- pozitsion o'quvchilar (agar bo'lsa) buzilmaydi, PostgreSQL CREATE OR
-- REPLACE bu holatda return type o'zgarishini FAQAT oxiriga qo'shishga
-- ruxsat beradi.

create or replace function _yuk_grafik_taqsim(p_yuk_ids integer[])
returns table (
  id             bigint,
  yuk_id         integer,
  sana           date,
  summa          numeric,
  valyuta        text,
  izoh           text,
  summa_uzs      numeric,
  tolangan_uzs   numeric,
  qoldiq_uzs     numeric,
  kech           boolean,
  tolov_sanalari date[],
  guruh_id       uuid,
  guruh_yuklar   integer[]
)
language sql
stable
security definer
set search_path = public
as $yg2_taqsim$
  with filtered as (
    select t.*
      from yuk_tolov_grafik t
     where p_yuk_ids is null
        or t.yuk_id = any(p_yuk_ids)
        or (t.guruh_id is not null and exists (
              select 1 from yuk_grafik_guruh_yuk gy
               where gy.guruh_id = t.guruh_id and gy.yuk_id = any(p_yuk_ids)))
  ),
  gmembers as (
    select gy.guruh_id, array_agg(gy.yuk_id order by gy.yuk_id) as yuklar
      from yuk_grafik_guruh_yuk gy
     where gy.guruh_id in (select distinct guruh_id from filtered where guruh_id is not null)
     group by gy.guruh_id
  ),
  g as (
    select f.id, f.yuk_id, f.sana, f.summa, f.valyuta, f.izoh, f.guruh_id,
           gm.yuklar as guruh_yuklar,
           coalesce('g:' || f.guruh_id::text, 'y:' || f.yuk_id::text) as agg_key,
           round(f.summa * case when upper(coalesce(f.valyuta, 'UZS')) = 'UZS' then 1::numeric
                                 else coalesce(conv_baza_kurs(f.valyuta), 0::numeric) end) as summa_uzs
      from filtered f
      left join gmembers gm on gm.guruh_id = f.guruh_id
  ),
  gc as (
    select g.*,
           sum(g.summa_uzs) over (partition by g.agg_key order by g.sana, g.id) as cum_to,
           sum(g.summa_uzs) over (partition by g.agg_key order by g.sana, g.id) - g.summa_uzs as cum_from
      from g
  ),
  pay_scope as (
    -- Toʻlov doirasi: yakka yuk_id o'zi, YOKI filtrlangan guruh(lar)ning HAMMA
    -- a'zosi (FIFO guruh bo'yicha — filtrdan tashqari a'zo bo'lsa ham hisobga olinadi).
    select distinct yuk_id from (
      select f.yuk_id from filtered f where f.guruh_id is null
      union
      select gy.yuk_id from yuk_grafik_guruh_yuk gy
       where gy.guruh_id in (select distinct guruh_id from filtered where guruh_id is not null)
    ) s
  ),
  p as (
    select ey.entry_id, ey.yuk_id, e.entry_date, ey.summa_uzs,
           coalesce('g:' || gy.guruh_id::text, 'y:' || ey.yuk_id::text) as agg_key
      from entry_yuk ey
      join entry e on e.id = ey.entry_id
      left join yuk_grafik_guruh_yuk gy on gy.yuk_id = ey.yuk_id
     where e.status = 'posted' and e.is_deleted = false
       and ey.yuk_id in (select yuk_id from pay_scope)
  ),
  pc as (
    select p.*,
           sum(p.summa_uzs) over (partition by p.agg_key order by p.entry_date, p.entry_id) as cum_to,
           sum(p.summa_uzs) over (partition by p.agg_key order by p.entry_date, p.entry_id) - p.summa_uzs as cum_from
      from p
  ),
  ov as (
    select gc.id as grafik_id, pc.entry_date as entry_date,
           greatest(0, least(gc.cum_to, pc.cum_to) - greatest(gc.cum_from, pc.cum_from)) as ov
      from gc
      join pc on pc.agg_key = gc.agg_key
     where least(gc.cum_to, pc.cum_to) > greatest(gc.cum_from, pc.cum_from)
  )
  select gc.id, gc.yuk_id, gc.sana, gc.summa, gc.valyuta, gc.izoh, gc.summa_uzs,
         coalesce(sum(ov.ov), 0)                                        as tolangan_uzs,
         gc.summa_uzs - coalesce(sum(ov.ov), 0)                         as qoldiq_uzs,
         coalesce(bool_or(ov.entry_date > gc.sana), false)              as kech,
         coalesce(array_agg(distinct ov.entry_date order by ov.entry_date)
                    filter (where ov.entry_date is not null), '{}'::date[]) as tolov_sanalari,
         gc.guruh_id, coalesce(gc.guruh_yuklar, '{}'::integer[])
    from gc
    left join ov on ov.grafik_id = gc.id
   group by gc.id, gc.yuk_id, gc.sana, gc.summa, gc.valyuta, gc.izoh, gc.summa_uzs, gc.guruh_id, gc.guruh_yuklar
   order by gc.yuk_id, gc.sana, gc.id;
$yg2_taqsim$;

revoke all on function _yuk_grafik_taqsim(integer[]) from public, anon, authenticated;

comment on function _yuk_grafik_taqsim(integer[]) is
  'ICHKI: har yuk_tolov_grafik qatori uchun FIFO taqsimlangan tolov, GURUH-AWARE '
  '(2026-09-14): guruh qatorlari uchun kumulyativ zanjir guruh_id boyicha (yuk_id '
  'emas), tolovlar guruhning HAMMA azosidan yigiladi. Yakka qatorlar ozgarmagan. '
  'guruh_id/guruh_yuklar OUT ustunlari OXIRIGA qoshilgan (eski oquvchilar buzilmaydi).';


-- #####################################################################
-- ##  5-BO'LIM — yuk_grafik_guruh_maqsad(p_yuklar)                    ##
-- #####################################################################
-- p_yuklar = [{yuk_id, narx, valyuta}]. Har yuk uchun mavjud "butun tannarx"
-- mantiqi (_yuk_grafik_maqsad_calc — narx + (tannarx+bojxona)/kurs), jami =
-- yig'indi. Valyutalar xilma-xil bo'lsa {ok:false, kod:'valyuta_xilma_xil'}.

create or replace function yuk_grafik_guruh_maqsad(p_yuklar jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ygg_maqsad$
declare
  v_el        jsonb;
  v_yuk_id    integer;
  v_narx      numeric;
  v_valyuta   text;
  v_first_val text;
  v_calc      jsonb;
  v_jami      numeric := 0;
  v_out       jsonb := '[]'::jsonb;
begin
  if not coalesce(perm_has_page('beshkunlik') or perm_has_page('yuklar'), false) then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  if p_yuklar is null or jsonb_typeof(p_yuklar) <> 'array' or jsonb_array_length(p_yuklar) = 0 then
    return jsonb_build_object('ok', false, 'kod', 'yuklar_bosh');
  end if;

  for v_el in select * from jsonb_array_elements(p_yuklar) loop
    v_valyuta := upper(coalesce(v_el ->> 'valyuta', 'UZS'));
    if v_first_val is null then
      v_first_val := v_valyuta;
    elsif v_valyuta <> v_first_val then
      return jsonb_build_object('ok', false, 'kod', 'valyuta_xilma_xil');
    end if;
  end loop;

  for v_el in select * from jsonb_array_elements(p_yuklar) loop
    v_yuk_id  := nullif(v_el ->> 'yuk_id', '')::integer;
    v_narx    := nullif(v_el ->> 'narx', '')::numeric;
    v_valyuta := upper(coalesce(v_el ->> 'valyuta', 'UZS'));
    if v_yuk_id is null then
      return jsonb_build_object('ok', false, 'kod', 'yuk_id');
    end if;
    v_calc := _yuk_grafik_maqsad_calc(v_yuk_id, v_narx, v_valyuta);
    if not coalesce((v_calc ->> 'ok')::boolean, false) then
      return coalesce(v_calc, jsonb_build_object('ok', false, 'kod', 'kurs_yoq'));
    end if;
    v_jami := v_jami + (v_calc ->> 'maqsad')::numeric;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'yuk_id', v_yuk_id, 'narx', v_narx,
      'tannarx_uzs', (v_calc ->> 'tannarx_uzs')::numeric,
      'bojxona_uzs', (v_calc ->> 'bojxona_uzs')::numeric,
      'maqsad', (v_calc ->> 'maqsad')::numeric));
  end loop;

  return jsonb_build_object(
    'ok', true, 'maqsad', v_jami, 'valyuta', v_first_val,
    'yuklar', v_out, 'kurs', (v_calc ->> 'kurs')::numeric);
end
$ygg_maqsad$;

revoke all on function yuk_grafik_guruh_maqsad(jsonb) from public, anon;
grant execute on function yuk_grafik_guruh_maqsad(jsonb) to authenticated;

comment on function yuk_grafik_guruh_maqsad(jsonb) is
  'Guruh "butun tannarx" (maqsad): p_yuklar=[{yuk_id,narx,valyuta}] -> {ok, maqsad, '
  'valyuta, yuklar:[{yuk_id,narx,tannarx_uzs,bojxona_uzs,maqsad}], kurs}. Valyutalar '
  'xilma-xil bolsa {ok:false,kod:''valyuta_xilma_xil''}. Ruxsat: perm_has_page('
  '''beshkunlik'') or perm_has_page(''yuklar'').';


-- #####################################################################
-- ##  6-BO'LIM — yuk_grafik_guruh_saqla(...)                          ##
-- #####################################################################
-- p_guruh_id null -> yangi guruh. p_yuklar=[{yuk_id,narx,valyuta}] — guruh
-- a'zolari TO'LIQ shu ro'yxat bilan almashtiriladi (kamida 2 ta, bir xil
-- valyuta, boshqa guruhda turgan a'zo bo'lsa rad). p_rows=[{sana,summa,izoh}]
-- — guruh grafigi TO'LIQ almashtiriladi (|jami-maqsad|<=1). p_rows bo'sh ->
-- guruh butunlay o'chiriladi (a'zolar bo'shaydi, deadline tozalanadi).
-- Har a'zo uchun yuk_deadline upsert (eski "Muddat" mantiqi/loadMuddatsizSummary
-- ishlashi uchun) — deadline = guruh grafigining eng erta sanasi, narx/valyuta
-- o'sha a'zoniki. Guruhdan chiqarilgan (eski a'zo, yangi ro'yxatda yo'q) — deadline
-- tozalanadi (guruhsiz osilib qolmasin).

create or replace function yuk_grafik_guruh_saqla(
  p_guruh_id    uuid,
  p_yuklar      jsonb,
  p_rows        jsonb,
  p_kelishuv    text default null,
  p_yetkazuvchi text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $ygg_saqla$
declare
  v_yuklar       jsonb;
  v_el           jsonb;
  v_yuk_id       integer;
  v_narx         numeric;
  v_valyuta      text;
  v_first_val    text;
  v_ids          integer[] := '{}';
  v_ids_sorted   integer[];
  v_distinct_n   int;
  v_n_yuk        int := 0;
  v_guruh_id     uuid;
  v_removed_ids  integer[] := '{}';
  v_rows         jsonb;
  v_row          jsonb;
  v_sana         date;
  v_summa        numeric;
  v_izoh         text;
  v_jami         numeric := 0;
  v_n_row        int := 0;
  v_calc         jsonb;
  v_maqsad       numeric := 0;
  v_farq         numeric;
  v_min_sana     date;
  v_rep_yuk_id   integer;
  v_conflict_yuk integer;
begin
  if not coalesce(perm_has_page('beshkunlik_edit') or perm_has_page('yuklar'), false) then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  v_yuklar := coalesce(p_yuklar, '[]'::jsonb);
  if jsonb_typeof(v_yuklar) <> 'array' then
    return jsonb_build_object('ok', false, 'kod', 'yuklar_shakli');
  end if;

  for v_el in select * from jsonb_array_elements(v_yuklar) loop
    v_yuk_id := nullif(v_el ->> 'yuk_id', '')::integer;
    if v_yuk_id is null then
      return jsonb_build_object('ok', false, 'kod', 'yuk_id');
    end if;
    v_valyuta := upper(coalesce(v_el ->> 'valyuta', 'UZS'));
    if v_first_val is null then
      v_first_val := v_valyuta;
    elsif v_valyuta <> v_first_val then
      return jsonb_build_object('ok', false, 'kod', 'valyuta_xilma_xil');
    end if;
    v_ids := array_append(v_ids, v_yuk_id);
    v_n_yuk := v_n_yuk + 1;
  end loop;

  if v_n_yuk < 2 then
    return jsonb_build_object('ok', false, 'kod', 'kam_yuk');
  end if;

  select count(distinct u) into v_distinct_n from unnest(v_ids) u;
  if v_distinct_n <> v_n_yuk then
    return jsonb_build_object('ok', false, 'kod', 'takror_yuk');
  end if;

  select array_agg(u order by u) into v_ids_sorted from unnest(v_ids) u;
  perform pg_advisory_xact_lock(hashtext('yuk_grafik_guruh_yuk:' || array_to_string(v_ids_sorted, ',')));

  if p_guruh_id is not null and not exists (select 1 from yuk_grafik_guruh where id = p_guruh_id) then
    return jsonb_build_object('ok', false, 'kod', 'guruh_topilmadi');
  end if;

  -- boshqa guruhda turgan a'zo bormi? (o'zining guruhi bo'lsa muammo emas)
  select gy.yuk_id into v_conflict_yuk
    from yuk_grafik_guruh_yuk gy
   where gy.yuk_id = any(v_ids)
     and (p_guruh_id is null or gy.guruh_id <> p_guruh_id)
   limit 1;
  if v_conflict_yuk is not null then
    return jsonb_build_object('ok', false, 'kod', 'boshqa_guruhda', 'yuk_id', v_conflict_yuk);
  end if;

  v_rows := coalesce(p_rows, '[]'::jsonb);
  if jsonb_typeof(v_rows) <> 'array' then
    return jsonb_build_object('ok', false, 'kod', 'rows_shakli');
  end if;

  for v_row in select * from jsonb_array_elements(v_rows) loop
    v_sana := null; v_summa := null;
    begin v_sana := (v_row ->> 'sana')::date; exception when others then v_sana := null; end;
    begin v_summa := (v_row ->> 'summa')::numeric; exception when others then v_summa := null; end;
    if v_sana is null or v_summa is null or v_summa <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'qator_notogri');
    end if;
    v_jami := v_jami + v_summa;
    v_n_row := v_n_row + 1;
  end loop;

  if v_n_row > 0 then
    for v_el in select * from jsonb_array_elements(v_yuklar) loop
      v_yuk_id := (v_el ->> 'yuk_id')::integer;
      v_narx   := nullif(v_el ->> 'narx', '')::numeric;
      v_calc := _yuk_grafik_maqsad_calc(v_yuk_id, v_narx, v_first_val);
      if not coalesce((v_calc ->> 'ok')::boolean, false) then
        return coalesce(v_calc, jsonb_build_object('ok', false, 'kod', 'kurs_yoq'));
      end if;
      v_maqsad := v_maqsad + (v_calc ->> 'maqsad')::numeric;
    end loop;
    v_farq := v_jami - v_maqsad;
    if abs(v_farq) > 1 then
      return jsonb_build_object('ok', false, 'kod', 'summa_mos_emas', 'jami', v_jami, 'maqsad', v_maqsad, 'farq', v_farq);
    end if;
  end if;

  -- ⬇⬇⬇  Tekshiruvlar tugadi — endi yozish boshlanadi  ⬇⬇⬇

  if p_guruh_id is null then
    insert into yuk_grafik_guruh (yetkazuvchi, valyuta, izoh)
      values (p_yetkazuvchi, v_first_val, p_kelishuv)
      returning id into v_guruh_id;
  else
    v_guruh_id := p_guruh_id;
    update yuk_grafik_guruh
       set yetkazuvchi = coalesce(p_yetkazuvchi, yetkazuvchi),
           valyuta     = v_first_val,
           izoh        = case when p_kelishuv is not null then p_kelishuv else izoh end
     where id = v_guruh_id;
  end if;

  select coalesce(array_agg(gy.yuk_id), '{}') into v_removed_ids
    from yuk_grafik_guruh_yuk gy
   where gy.guruh_id = v_guruh_id and not (gy.yuk_id = any(v_ids));

  -- yuk guruhga qo'shilganda uning eski YAKKA grafigi o'chadi
  delete from yuk_tolov_grafik where yuk_id = any(v_ids) and guruh_id is null;

  delete from yuk_grafik_guruh_yuk where guruh_id = v_guruh_id;
  for v_el in select * from jsonb_array_elements(v_yuklar) loop
    v_yuk_id := (v_el ->> 'yuk_id')::integer;
    v_narx   := nullif(v_el ->> 'narx', '')::numeric;
    insert into yuk_grafik_guruh_yuk (guruh_id, yuk_id, narx, valyuta)
      values (v_guruh_id, v_yuk_id, v_narx, v_first_val);
  end loop;

  delete from yuk_tolov_grafik where guruh_id = v_guruh_id;

  if v_n_row = 0 then
    update yuk_deadline
       set deadline = null,
           izoh = case when p_kelishuv is not null then p_kelishuv else izoh end
     where yuk_id = any(v_ids);
    delete from yuk_grafik_guruh where id = v_guruh_id;   -- cascade: guruh_yuk ham ketadi
    return jsonb_build_object('ok', true, 'guruh_id', null, 'jami', 0);
  end if;

  select min(u) into v_rep_yuk_id from unnest(v_ids) u;

  v_min_sana := null;
  for v_row in select * from jsonb_array_elements(v_rows) loop
    v_sana  := (v_row ->> 'sana')::date;
    v_summa := (v_row ->> 'summa')::numeric;
    v_izoh  := v_row ->> 'izoh';
    insert into yuk_tolov_grafik (yuk_id, sana, summa, valyuta, izoh, guruh_id)
      values (v_rep_yuk_id, v_sana, v_summa, v_first_val, v_izoh, v_guruh_id);
    if v_min_sana is null or v_sana < v_min_sana then
      v_min_sana := v_sana;
    end if;
  end loop;

  for v_el in select * from jsonb_array_elements(v_yuklar) loop
    v_yuk_id := (v_el ->> 'yuk_id')::integer;
    v_narx   := nullif(v_el ->> 'narx', '')::numeric;
    insert into yuk_deadline (yuk_id, deadline, narx, valyuta, izoh)
      values (v_yuk_id, v_min_sana, v_narx, v_first_val, p_kelishuv)
    on conflict (yuk_id) do update
       set deadline = excluded.deadline,
           narx     = excluded.narx,
           valyuta  = excluded.valyuta,
           izoh     = case when p_kelishuv is not null then excluded.izoh else yuk_deadline.izoh end;
  end loop;

  if array_length(v_removed_ids, 1) is not null then
    update yuk_deadline set deadline = null where yuk_id = any(v_removed_ids);
  end if;

  return jsonb_build_object('ok', true, 'guruh_id', v_guruh_id, 'jami', v_jami,
                             'maqsad', v_maqsad, 'n', v_n_row, 'yuklar', v_n_yuk);
end
$ygg_saqla$;

revoke all on function yuk_grafik_guruh_saqla(uuid, jsonb, jsonb, text, text) from public, anon;
grant execute on function yuk_grafik_guruh_saqla(uuid, jsonb, jsonb, text, text) to authenticated;

comment on function yuk_grafik_guruh_saqla(uuid, jsonb, jsonb, text, text) is
  'Guruh grafigini yaratadi/yangilaydi. p_guruh_id null -> yangi guruh. p_yuklar '
  '[{yuk_id,narx,valyuta}] a''zolarni TOLIQ almashtiradi (>=2, bir xil valyuta, boshqa '
  'guruhda turgan azo bolsa {ok:false,kod:''boshqa_guruhda''}). p_rows [{sana,summa,izoh}] '
  'grafikni TOLIQ almashtiradi (|jami-maqsad|<=1). p_rows bosh -> guruh ochiriladi '
  '(azolar boshaydi, deadline tozalanadi). Ruxsat: perm_has_page(''beshkunlik_edit'') '
  'or perm_has_page(''yuklar'').';


-- #####################################################################
-- ##  7-BO'LIM — yuk_grafik_royxat QAYTA E'LON — guruh maydonlari     ##
-- #####################################################################
-- Imzo bir xil (p_yuk_ids integer[] default null). Javobga guruh_id/
-- guruh_yuklar (_yuk_grafik_taqsim'dan) va yetkazuvchi (yuk_grafik_guruh'dan)
-- qo'shilgan — yakka qatorlar uchun uchtasi ham null/bo'sh.

create or replace function yuk_grafik_royxat(p_yuk_ids integer[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $yg2_royxat$
begin
  if not coalesce(perm_has_page('beshkunlik') or perm_has_page('yuklar'), false) then
    return jsonb_build_object('ok', false, 'rows', '[]'::jsonb);
  end if;

  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id, 'yuk_id', t.yuk_id, 'sana', t.sana, 'summa', t.summa, 'valyuta', t.valyuta,
             'izoh', t.izoh, 'summa_uzs', t.summa_uzs, 'tolangan_uzs', t.tolangan_uzs,
             'qoldiq_uzs', t.qoldiq_uzs, 'kech', t.kech, 'tolov_sanalari', t.tolov_sanalari,
             'guruh_id', t.guruh_id, 'guruh_yuklar', t.guruh_yuklar, 'yetkazuvchi', g.yetkazuvchi,
             'holat', case when t.qoldiq_uzs <= 0.5 then 'tolangan'
                           when t.tolangan_uzs > 0.5 then 'qisman'
                           else 'tolanmagan' end)
           order by t.yuk_id, t.sana, t.id)
      from _yuk_grafik_taqsim(p_yuk_ids) t
      left join yuk_grafik_guruh g on g.id = t.guruh_id
  ), '[]'::jsonb));
end
$yg2_royxat$;

revoke all on function yuk_grafik_royxat(integer[]) from public, anon;
grant execute on function yuk_grafik_royxat(integer[]) to authenticated;

comment on function yuk_grafik_royxat(integer[]) is
  'Grafik qatorlari (p_yuk_ids null -> hammasi) — {ok, rows:[{id,yuk_id,sana,summa,'
  'valyuta,izoh,summa_uzs,tolangan_uzs,qoldiq_uzs,kech,tolov_sanalari,guruh_id,'
  'guruh_yuklar,yetkazuvchi,holat}]}. guruh_id/guruh_yuklar/yetkazuvchi — yakka '
  'qatorlar uchun null/bosh. Ruxsat: perm_has_page(''beshkunlik'') or perm_has_page(''yuklar'').';


-- #####################################################################
-- ##  8-BO'LIM — beshkunlik_qarz_detal_v3 QAYTA E'LON — guruh maydoni ##
-- #####################################################################
-- Imzo bir xil (p_sana date). 🔴 beshkunlik_qarz_v3 (kunlik agregat) bu
-- faylda QAYTA E'LON QILINMAYDI — u kunlik yig'indi bo'lib, bitta kunga
-- bir nechta TURLI guruh tushishi mumkin (bitta guruh_id chiqarish
-- ma'nosiz bo'lardi); u _yuk_grafik_taqsim'ni nomi bilan chaqiradi,
-- shuning uchun guruh-aware FIFO'dan (4-BO'LIM) AVTOMATIK foyda ko'radi —
-- raqamlar to'g'ri, faqat guruh detali chiqarilmaydi. Guruh detali —
-- shu funksiyada (bitta kun, qator darajasida — mantiqan to'g'ri joy).

create or replace function beshkunlik_qarz_detal_v3(p_sana date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bk_qarz_detal_v3b$
declare
  v_ids integer[];
begin
  if not coalesce(perm_has_page('beshkunlik'), false) then
    return '[]'::jsonb;
  end if;
  if p_sana is null then
    return '[]'::jsonb;
  end if;

  select coalesce(array_agg(distinct yuk_id), '{}'::integer[])
    into v_ids
    from yuk_tolov_grafik
   where sana = p_sana;

  if array_length(v_ids, 1) is null then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'grafik_id', t.id, 'yuk_id', t.yuk_id, 'izoh', t.izoh, 'summa', t.summa,
             'valyuta', t.valyuta, 'summa_uzs', t.summa_uzs, 'tolangan_uzs', t.tolangan_uzs,
             'qoldiq_uzs', t.qoldiq_uzs,
             'holat', case when t.qoldiq_uzs <= 0.5 then 'tolangan'
                           when t.tolangan_uzs > 0.5 then 'qisman'
                           else 'tolanmagan' end,
             'kech', t.kech, 'tolov_sanalari', t.tolov_sanalari,
             'guruh_id', t.guruh_id, 'guruh_yuklar', t.guruh_yuklar, 'yetkazuvchi', g.yetkazuvchi,
             'kelishuv', coalesce(g.izoh, yd.izoh))
           order by t.yuk_id)
      from _yuk_grafik_taqsim(v_ids) t
      left join yuk_deadline yd on yd.yuk_id = t.yuk_id
      left join yuk_grafik_guruh g on g.id = t.guruh_id
     where t.sana = p_sana
  ), '[]'::jsonb);
end
$bk_qarz_detal_v3b$;

revoke all on function beshkunlik_qarz_detal_v3(date) from public, anon;
grant execute on function beshkunlik_qarz_detal_v3(date) to authenticated;

comment on function beshkunlik_qarz_detal_v3(date) is
  '5 kunlik Qarzmiz katagi hover (bitta kun, profilsiz): [{grafik_id, yuk_id, izoh, summa, '
  'valyuta, summa_uzs, tolangan_uzs, qoldiq_uzs, holat, kech, tolov_sanalari, guruh_id, '
  'guruh_yuklar, yetkazuvchi, kelishuv}]. kelishuv — guruh bolsa yuk_grafik_guruh.izoh, '
  'aks holda yuk_deadline.izoh. Ruxsat: perm_has_page(''beshkunlik'').';


-- #####################################################################
-- ##  9-BO'LIM — PostgREST sxema keshini yangilash (1-QISM)           ##
-- #####################################################################

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  10-BO'LIM — YAKUNIY TEKSHIRUV (1-QISM, faqat select/raise)      ##
-- #####################################################################
-- 🔴 FIFO GURUH MISOLI (qo'lda hisoblangan, klient agenti shu bo'yicha kod
-- yozadi): guruh = yuk A (600 birlik) + yuk B (400 birlik), grafik 12-sen
-- 700 birlik, 20-sen 300 birlik; tolovlar: A ga 10-sen 500 birlik, B ga
-- 15-sen 400 birlik. Kutilgan natija:
--   12-sen: tolangan 700 (500 10-sendan + 200 15-sendan), kech=true
--           (15-sen > 12-sen).
--   20-sen: tolangan 200 (15-sendagi 400 dan qolgan 200 qismi), qoldiq 100.
-- (4-BO'LIMdagi kumulyativ oraliq kesishmasi formulasi bilan qo'lda
-- tekshirilgan — bitta grafik guruh_id boyicha zanjir, tolovlar ham
-- guruhning ikkala azosidan BITTA zanjirda yig'ilgani uchun to'g'ri chiqadi.)

do $yg2_final$
declare
  v_ok boolean;
begin
  if to_regclass('public.yuk_grafik_guruh') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_grafik_guruh jadvali yaralmadi';
  end if;
  if to_regclass('public.yuk_grafik_guruh_yuk') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_grafik_guruh_yuk jadvali yaralmadi';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'yuk_tolov_grafik' and column_name = 'guruh_id'
  ) then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_tolov_grafik.guruh_id ustuni yaralmadi';
  end if;
  if not exists (select 1 from pg_indexes
                  where schemaname='public' and tablename='yuk_grafik_guruh_yuk'
                    and indexname='yuk_grafik_guruh_yuk_yuk_uniq') then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_grafik_guruh_yuk_yuk_uniq (UNIQUE yuk_id) yaralmadi';
  end if;

  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='yuk_grafik_guruh' and policyname='yuk_grafik_guruh_sel') then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_grafik_guruh_sel policy yoq';
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='yuk_grafik_guruh_yuk' and policyname='yuk_grafik_guruh_yuk_sel') then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_grafik_guruh_yuk_sel policy yoq';
  end if;

  select has_table_privilege('authenticated', 'public.yuk_grafik_guruh', 'select') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun yuk_grafik_guruh SELECT yoq';
  end if;
  select has_table_privilege('authenticated', 'public.yuk_grafik_guruh', 'insert') into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated yuk_grafik_guruhga togridan yoza olmasligi kerak edi';
  end if;
  select has_table_privilege('anon', 'public.yuk_grafik_guruh', 'select') into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: anon yuk_grafik_guruhni oqiy olmasligi kerak edi';
  end if;
  select has_table_privilege('authenticated', 'public.yuk_grafik_guruh_yuk', 'select') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun yuk_grafik_guruh_yuk SELECT yoq';
  end if;

  if to_regprocedure('public._yuk_grafik_taqsim(integer[])') is null then
    raise exception 'YAKUNIY TEKSHIRUV: _yuk_grafik_taqsim(integer[]) yoq';
  end if;
  if to_regprocedure('public.yuk_grafik_guruh_maqsad(jsonb)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_grafik_guruh_maqsad(jsonb) yaralmadi';
  end if;
  if to_regprocedure('public.yuk_grafik_guruh_saqla(uuid,jsonb,jsonb,text,text)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_grafik_guruh_saqla(uuid,jsonb,jsonb,text,text) yaralmadi';
  end if;
  if to_regprocedure('public.yuk_grafik_royxat(integer[])') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_grafik_royxat(integer[]) yoq';
  end if;
  if to_regprocedure('public.beshkunlik_qarz_detal_v3(date)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_qarz_detal_v3(date) yoq';
  end if;

  raise notice 'PROVODKA_YUK_GURUH_OZGARISH.sql (1-qism): hammasi joyida (guruh grafigi)';
end
$yg2_final$;


-- #####################################################################
-- ##  11-BO'LIM — OLD SHART TEKSHIRUVI (2-QISM)                       ##
-- #####################################################################

do $ays_pre$
begin
  if to_regclass('public.entry_yuk') is null then
    raise exception 'entry_yuk jadvali yoq — avval PROVODKA_YUK_QISMAN.sql ni bajaring';
  end if;
  if to_regclass('public.yuk_tannarx') is null then
    raise exception 'yuk_tannarx jadvali yoq — avval PROVODKA_YUK_TANNARX.sql ni bajaring';
  end if;
  if to_regclass('public.yuk_tolov_grafik') is null then
    raise exception 'yuk_tolov_grafik jadvali yoq — avval PROVODKA_5KUNLIK_GRAFIK.sql ni bajaring';
  end if;
  if to_regclass('public.yuk_deadline') is null then
    raise exception 'yuk_deadline jadvali yoq — avval PROVODKA_5KUNLIK.sql ni bajaring';
  end if;
  if to_regprocedure('public.perm_has_page(text)') is null then
    raise exception 'perm_has_page(text) yoq — avval PROVODKA_PAGES_EMPTY.sql ni bajaring';
  end if;
end
$ays_pre$;


-- #####################################################################
-- ##  12-BO'LIM — aros_yuk_snapshot                                   ##
-- #####################################################################
-- Har Aros yuk uchun OXIRGI ko'rilgan surat (n8n sync oynasi ichida).
-- `mavjud=false` — oxirgi sinxronda oynada ko'rinmay qoldi (o'chirilgan/
-- ko'chib ketgan). Faqat sync_aros_yuk_snapshot yozadi.

create table if not exists aros_yuk_snapshot (
  yuk_id            integer     primary key,
  narx              numeric,
  valyuta           text,
  status            text,
  ombor             text,
  yetkazuvchi       text,
  sana              date,
  mavjud            boolean     not null default true,
  birinchi_korilgan timestamptz not null default now(),
  oxirgi_korilgan   timestamptz not null default now()
);

create index if not exists aros_yuk_snapshot_sana_idx on aros_yuk_snapshot(sana);

comment on table aros_yuk_snapshot is
  'Har Aros yuk (product-income) uchun OXIRGI korilgan surat — sync_aros_yuk_snapshot '
  '(n8n) yozadi. mavjud=false — oxirgi sinxron oynasida payloadda topilmadi.';

alter table aros_yuk_snapshot enable row level security;
revoke all on table aros_yuk_snapshot from public, anon, authenticated;
grant select on table aros_yuk_snapshot to authenticated;

drop policy if exists aros_yuk_snapshot_sel on aros_yuk_snapshot;
create policy aros_yuk_snapshot_sel on aros_yuk_snapshot
  for select to authenticated
  using (perm_has_page('yuklar') or perm_has_page('beshkunlik'));


-- #####################################################################
-- ##  13-BO'LIM — aros_yuk_ozgarish                                   ##
-- #####################################################################
-- Har sezilgan o'zgarish — bitta jurnal qatori. `muhim` — shu yukda
-- Provodka ma'lumoti (tolov/tannarx/grafik/deadline/guruh) bor bo'lsa true
-- (14-BO'LIM). `korildi` — foydalanuvchi "ko'rdim" deb belgilagan (17-BO'LIM).

create table if not exists aros_yuk_ozgarish (
  id          bigserial   primary key,
  yuk_id      integer     not null,
  tur         text        not null check (tur in ('ochirildi','qaytdi','narx_kamaydi','narx_oshdi','valyuta')),
  eski_narx   numeric,
  yangi_narx  numeric,
  valyuta     text,
  muhim       boolean     not null default false,
  izoh        text,
  sezildi_at  timestamptz not null default now(),
  korildi     boolean     not null default false,
  korgan      uuid,
  korildi_at  timestamptz
);

create index if not exists aros_yuk_ozgarish_yuk_idx    on aros_yuk_ozgarish(yuk_id);
create index if not exists aros_yuk_ozgarish_ochiq_idx   on aros_yuk_ozgarish(korildi, muhim, sezildi_at desc);

comment on table aros_yuk_ozgarish is
  'Aros yuk (product-income) ozgarish jurnali (ochirildi/qaytdi/narx/valyuta) — '
  'sync_aros_yuk_snapshot (n8n) yozadi. muhim — shu yukda Provodka malumoti bor '
  '(tolov/tannarx/grafik/deadline/guruh). korildi — foydalanuvchi belgilagan.';

alter table aros_yuk_ozgarish enable row level security;
revoke all on table aros_yuk_ozgarish from public, anon, authenticated;
grant select on table aros_yuk_ozgarish to authenticated;

drop policy if exists aros_yuk_ozgarish_sel on aros_yuk_ozgarish;
create policy aros_yuk_ozgarish_sel on aros_yuk_ozgarish
  for select to authenticated
  using (perm_has_page('yuklar') or perm_has_page('beshkunlik'));

-- 🔴 To'g'ridan insert/update/delete policy YO'Q — insert faqat sync_aros_yuk_snapshot
-- (service_role), korildi belgisi faqat aros_yuk_ozgarish_korildi (17-BOLIM).


-- #####################################################################
-- ##  14-BO'LIM — ICHKI: _ays_muhim / _ays_izoh / _ays_ochiq_bor      ##
-- #####################################################################

create or replace function _ays_muhim(p_yuk_id integer)
returns boolean
language sql
stable
security definer
set search_path = public
as $ays_muhim$
  select exists (select 1 from entry_yuk where yuk_id = p_yuk_id)
      or exists (select 1 from yuk_tannarx where yuk_id = p_yuk_id and not is_deleted)
      or exists (select 1 from yuk_tolov_grafik where yuk_id = p_yuk_id)
      or exists (select 1 from yuk_deadline where yuk_id = p_yuk_id and deadline is not null)
      or exists (select 1 from yuk_grafik_guruh_yuk where yuk_id = p_yuk_id);
$ays_muhim$;

revoke all on function _ays_muhim(integer) from public, anon, authenticated;

comment on function _ays_muhim(integer) is
  'ICHKI: shu yukda Provodka malumoti bormi (tolov/tannarx/grafik/deadline/guruh). '
  'Ruxsat tekshirmaydi — chaqiruvchi (sync_aros_yuk_snapshot) ozi tekshiradi.';


create or replace function _ays_izoh(p_yuk_id integer)
returns text
language plpgsql
stable
security definer
set search_path = public
as $ays_izoh$
declare
  v_tolov   numeric;
  v_tannarx numeric;
  v_grafik  int;
  v_parts   text[] := '{}';
begin
  select coalesce(sum(ey.summa_uzs), 0) into v_tolov
    from entry_yuk ey
    join entry e on e.id = ey.entry_id
   where ey.yuk_id = p_yuk_id and e.status = 'posted' and e.is_deleted = false;

  select coalesce(sum(t.summa_uzs), 0) into v_tannarx
    from yuk_tannarx t
   where t.yuk_id = p_yuk_id and not t.is_deleted;

  select count(*) into v_grafik
    from yuk_tolov_grafik
   where yuk_id = p_yuk_id;

  if v_tolov > 0 then
    v_parts := array_append(v_parts,
      'to''lov ' || replace(to_char(round(v_tolov), 'FM999,999,999,999,999'), ',', ' ') || ' so''m');
  end if;
  if v_tannarx > 0 then
    v_parts := array_append(v_parts,
      'tannarx ' || replace(to_char(round(v_tannarx), 'FM999,999,999,999,999'), ',', ' ') || ' so''m');
  end if;
  if v_grafik > 0 then
    v_parts := array_append(v_parts, v_grafik || ' ta grafik to''lov');
  end if;

  if array_length(v_parts, 1) is null then
    return 'Provodkada malumot yoq.';
  end if;
  return 'Provodkada: ' || array_to_string(v_parts, ', ') || '.';
end
$ays_izoh$;

revoke all on function _ays_izoh(integer) from public, anon, authenticated;

comment on function _ays_izoh(integer) is
  'ICHKI: shu yuk uchun Provodka malumoti matni (tolov/tannarx/grafik soni), '
  'aros_yuk_ozgarish.izoh ga qoshiladigan qism. Malumot yoq bolsa "Provodkada malumot yoq.".';


create or replace function _ays_ochiq_bor(p_yuk_id integer, p_tur text, p_eski numeric, p_yangi numeric, p_valyuta text)
returns boolean
language sql
stable
security definer
set search_path = public
as $ays_ochiq$
  select exists (
    select 1 from aros_yuk_ozgarish o
     where o.yuk_id = p_yuk_id and o.tur = p_tur and o.korildi = false
       and o.eski_narx is not distinct from p_eski
       and o.yangi_narx is not distinct from p_yangi
       and o.valyuta   is not distinct from p_valyuta
  );
$ays_ochiq$;

revoke all on function _ays_ochiq_bor(integer, text, numeric, numeric, text) from public, anon, authenticated;

comment on function _ays_ochiq_bor(integer, text, numeric, numeric, text) is
  'ICHKI: shu yuk/tur/qiymatlar bilan hali korilmagan (korildi=false) ochiq hodisa '
  'bormi — sync_aros_yuk_snapshot takror hodisa yozmasligi uchun.';


-- #####################################################################
-- ##  15-BO'LIM — sync_aros_yuk_snapshot(p_data) — service_role ONLY  ##
-- #####################################################################
-- p_data = {oyna_from, oyna_to, yuklar:[{id,narx,valyuta,status,ombor,
-- yetkazuvchi,sana}]}. 🔴 yuklar bosh yoki 10 tadan kam bolsa — HECH NARSA
-- YOZILMAYDI (bosh {ok:false,kod:'payload_kichik'}, Transfer Sync sabogi:
-- jimgina 0 yoq). Oynadan tashqaridagi eski yuklarga TEGILMAYDI (sweep
-- faqat oyna_from/oyna_to berilgan va oyna ICHIDA sana=true bolgan avval
-- korilgan yuklar orasida). Yaroqsiz qator -> tashlanadi, butun sync
-- yiqilmaydi.

create or replace function sync_aros_yuk_snapshot(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $ays_sync$
declare
  v_role         text;
  v_yuklar       jsonb;
  v_el           jsonb;
  v_oyna_from    date;
  v_oyna_to      date;
  v_id           integer;
  v_narx         numeric;
  v_valyuta      text;
  v_status       text;
  v_ombor        text;
  v_yetkazuvchi  text;
  v_sana         date;
  v_old          aros_yuk_snapshot;
  v_stale        aros_yuk_snapshot;
  v_muhim        boolean;
  v_izoh         text;
  v_tur          text;
  v_was_insert   boolean;
  v_ids_korilgan integer[] := '{}';
  n_yozildi      int := 0;
  n_yangilandi   int := 0;
  n_yangi_hodisa int := 0;
  n_ochirildi    int := 0;
  n_tashlandi    int := 0;
begin
  -- ---- service_role ONLY (sync_aros_qarzdor bilan bir xil naqsh) ----
  if auth.uid() is not null then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;
  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is not null and v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('sync_aros_yuk_snapshot'));

  if p_data is null or jsonb_typeof(p_data) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'kod', 'payload_shakli');
  end if;

  v_yuklar := p_data -> 'yuklar';
  if jsonb_typeof(v_yuklar) is distinct from 'array' or jsonb_array_length(v_yuklar) < 10 then
    return jsonb_build_object('ok', false, 'kod', 'payload_kichik');
  end if;

  v_oyna_from := nullif(p_data ->> 'oyna_from', '')::date;
  v_oyna_to   := nullif(p_data ->> 'oyna_to', '')::date;

  for v_el in select * from jsonb_array_elements(v_yuklar)
  loop
    begin
      v_id := nullif(v_el ->> 'id', '')::integer;
      if v_id is null then
        n_tashlandi := n_tashlandi + 1;
        continue;
      end if;
      v_ids_korilgan := array_append(v_ids_korilgan, v_id);

      v_narx        := nullif(v_el ->> 'narx', '')::numeric;
      v_valyuta     := upper(nullif(btrim(coalesce(v_el ->> 'valyuta', '')), ''));
      v_status      := nullif(btrim(coalesce(v_el ->> 'status', '')), '');
      v_ombor       := nullif(btrim(coalesce(v_el ->> 'ombor', '')), '');
      v_yetkazuvchi := nullif(btrim(coalesce(v_el ->> 'yetkazuvchi', '')), '');
      v_sana        := nullif(v_el ->> 'sana', '')::date;

      select * into v_old from aros_yuk_snapshot where yuk_id = v_id;
      v_muhim := _ays_muhim(v_id);

      if v_old.yuk_id is not null and v_old.mavjud = false then
        if not _ays_ochiq_bor(v_id, 'qaytdi', v_old.narx, v_narx, v_valyuta) then
          v_izoh := 'Aros''da qayta paydo boldi (avval yoqolgan/ochirilgan edi). ' || _ays_izoh(v_id);
          insert into aros_yuk_ozgarish (yuk_id, tur, eski_narx, yangi_narx, valyuta, muhim, izoh)
            values (v_id, 'qaytdi', v_old.narx, v_narx, v_valyuta, v_muhim, v_izoh);
          n_yangi_hodisa := n_yangi_hodisa + 1;
        end if;
      end if;

      if v_old.yuk_id is not null and v_narx is not null and v_old.narx is not null
         and v_narx is distinct from v_old.narx then
        v_tur := case when v_narx < v_old.narx then 'narx_kamaydi' else 'narx_oshdi' end;
        if not _ays_ochiq_bor(v_id, v_tur, v_old.narx, v_narx, v_valyuta) then
          v_izoh := (case when v_tur = 'narx_kamaydi' then 'Aros''da narx kamaydi' else 'Aros''da narx oshdi' end)
                    || ' (' || coalesce(v_old.narx::text, '?') || ' -> ' || coalesce(v_narx::text, '?') || '). '
                    || _ays_izoh(v_id);
          insert into aros_yuk_ozgarish (yuk_id, tur, eski_narx, yangi_narx, valyuta, muhim, izoh)
            values (v_id, v_tur, v_old.narx, v_narx, v_valyuta, v_muhim, v_izoh);
          n_yangi_hodisa := n_yangi_hodisa + 1;
        end if;
      end if;

      if v_old.yuk_id is not null and v_valyuta is not null and v_old.valyuta is not null
         and v_valyuta is distinct from v_old.valyuta then
        if not _ays_ochiq_bor(v_id, 'valyuta', null, null, v_valyuta) then
          v_izoh := 'Aros''da valyuta ozgardi (' || v_old.valyuta || ' -> ' || v_valyuta || '). ' || _ays_izoh(v_id);
          insert into aros_yuk_ozgarish (yuk_id, tur, eski_narx, yangi_narx, valyuta, muhim, izoh)
            values (v_id, 'valyuta', null, null, v_valyuta, v_muhim, v_izoh);
          n_yangi_hodisa := n_yangi_hodisa + 1;
        end if;
      end if;

      insert into aros_yuk_snapshot (yuk_id, narx, valyuta, status, ombor, yetkazuvchi, sana,
                                      mavjud, birinchi_korilgan, oxirgi_korilgan)
      values (v_id, v_narx, v_valyuta, v_status, v_ombor, v_yetkazuvchi, v_sana, true, now(), now())
      on conflict (yuk_id) do update
         set narx            = excluded.narx,
             valyuta         = excluded.valyuta,
             status          = excluded.status,
             ombor           = excluded.ombor,
             yetkazuvchi     = excluded.yetkazuvchi,
             sana            = excluded.sana,
             mavjud          = true,
             oxirgi_korilgan = now()
      returning (xmax = 0) into v_was_insert;

      if v_was_insert then
        n_yozildi := n_yozildi + 1;
      else
        n_yangilandi := n_yangilandi + 1;
      end if;

    exception when others then
      n_tashlandi := n_tashlandi + 1;
      continue;
    end;
  end loop;

  -- Oynada, avval korilgan, lekin bu payloadda YOQ yuklar -> mavjud=false + ochirildi.
  -- Faqat oyna_from/oyna_to IKKALASI berilganda (bilmasak sweep qilinmaydi).
  if v_oyna_from is not null and v_oyna_to is not null then
    for v_stale in
      select s.* from aros_yuk_snapshot s
       where s.mavjud = true
         and s.sana between v_oyna_from and v_oyna_to
         and not (s.yuk_id = any(v_ids_korilgan))
    loop
      v_muhim := _ays_muhim(v_stale.yuk_id);
      if not _ays_ochiq_bor(v_stale.yuk_id, 'ochirildi', v_stale.narx, null, v_stale.valyuta) then
        v_izoh := 'Aros''da ochirilgan (butunlay yoqolgan). ' || _ays_izoh(v_stale.yuk_id);
        insert into aros_yuk_ozgarish (yuk_id, tur, eski_narx, yangi_narx, valyuta, muhim, izoh)
          values (v_stale.yuk_id, 'ochirildi', v_stale.narx, null, v_stale.valyuta, v_muhim, v_izoh);
        n_yangi_hodisa := n_yangi_hodisa + 1;
      end if;
      update aros_yuk_snapshot set mavjud = false, oxirgi_korilgan = now() where yuk_id = v_stale.yuk_id;
      n_ochirildi := n_ochirildi + 1;
    end loop;
  end if;

  return jsonb_build_object(
    'ok', true,
    'korildi', coalesce(array_length(v_ids_korilgan, 1), 0),
    'yangi_hodisa', n_yangi_hodisa,
    'ochirildi', n_ochirildi,
    'yozildi', n_yozildi,
    'yangilandi', n_yangilandi,
    'tashlandi', n_tashlandi);
end
$ays_sync$;

revoke all on function sync_aros_yuk_snapshot(jsonb) from public, anon, authenticated;
grant execute on function sync_aros_yuk_snapshot(jsonb) to service_role;

comment on function sync_aros_yuk_snapshot(jsonb) is
  'service_role ONLY (n8n). p_data={oyna_from,oyna_to,yuklar:[{id,narx,valyuta,status,'
  'ombor,yetkazuvchi,sana}]}. yuklar<10 -> {ok:false,kod:''payload_kichik''} (hech narsa '
  'yozilmaydi). Narx/valyuta ozgarishi va oyna ichida yoqolgan yuklar (ochirildi) '
  'aros_yuk_ozgarish ga yoziladi (muhim bayrogi bilan). Takror ochiq hodisa yozilmaydi.';


-- #####################################################################
-- ##  16-BO'LIM — aros_yuk_ozgarish_royxat(...)                       ##
-- #####################################################################

create or replace function aros_yuk_ozgarish_royxat(p_faqat_ochiq boolean default true, p_limit int default 200)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ayo_royxat$
declare
  v_limit int := greatest(1, least(coalesce(p_limit, 200), 1000));
  v_rows  jsonb;
  v_soni  int;
  v_muhim int;
begin
  if not coalesce(perm_has_page('yuklar') or perm_has_page('beshkunlik'), false) then
    return jsonb_build_object('ok', false, 'rows', '[]'::jsonb, 'soni', 0, 'muhim_soni', 0);
  end if;

  select count(*), count(*) filter (where o.muhim)
    into v_soni, v_muhim
    from aros_yuk_ozgarish o
   where (not p_faqat_ochiq or o.korildi = false);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'yuk_id', b.yuk_id, 'tur', b.tur, 'eski_narx', b.eski_narx,
           'yangi_narx', b.yangi_narx, 'valyuta', b.valyuta, 'muhim', b.muhim,
           'izoh', b.izoh, 'sezildi_at', b.sezildi_at, 'korildi', b.korildi,
           'tolangan_uzs', b.tolangan_uzs, 'tannarx_uzs', b.tannarx_uzs, 'grafik_n', b.grafik_n)
           order by b.muhim desc, b.sezildi_at desc), '[]'::jsonb)
    into v_rows
    from (
      select o.*,
             coalesce((select sum(ey.summa_uzs) from entry_yuk ey join entry e on e.id = ey.entry_id
                        where ey.yuk_id = o.yuk_id and e.status = 'posted' and e.is_deleted = false), 0) as tolangan_uzs,
             coalesce((select sum(t.summa_uzs) from yuk_tannarx t
                        where t.yuk_id = o.yuk_id and not t.is_deleted), 0) as tannarx_uzs,
             coalesce((select count(*) from yuk_tolov_grafik g where g.yuk_id = o.yuk_id), 0) as grafik_n
        from aros_yuk_ozgarish o
       where (not p_faqat_ochiq or o.korildi = false)
       order by o.muhim desc, o.sezildi_at desc
       limit v_limit
    ) b;

  return jsonb_build_object('ok', true, 'rows', v_rows, 'soni', coalesce(v_soni, 0), 'muhim_soni', coalesce(v_muhim, 0));
end
$ayo_royxat$;

revoke all on function aros_yuk_ozgarish_royxat(boolean, int) from public, anon;
grant execute on function aros_yuk_ozgarish_royxat(boolean, int) to authenticated;

comment on function aros_yuk_ozgarish_royxat(boolean, int) is
  'Aros yuk ozgarish jurnali royxati (p_faqat_ochiq=true -> korildi=false gina): '
  '{ok, rows:[{id,yuk_id,tur,eski_narx,yangi_narx,valyuta,muhim,izoh,sezildi_at,korildi,'
  'tolangan_uzs,tannarx_uzs,grafik_n}], soni, muhim_soni}. Ruxsat: perm_has_page(''yuklar'') '
  'or perm_has_page(''beshkunlik'').';


-- #####################################################################
-- ##  17-BO'LIM — aros_yuk_ozgarish_korildi(p_ids)                    ##
-- #####################################################################

create or replace function aros_yuk_ozgarish_korildi(p_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $ayo_korildi$
declare
  v_n int;
begin
  if not coalesce(perm_has_page('yuklar'), false) then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  if p_ids is null or array_length(p_ids, 1) is null then
    return jsonb_build_object('ok', false, 'kod', 'ids_yoq');
  end if;

  update aros_yuk_ozgarish
     set korildi = true, korgan = auth.uid(), korildi_at = now()
   where id = any(p_ids) and korildi = false;
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'yangilandi', v_n);
end
$ayo_korildi$;

revoke all on function aros_yuk_ozgarish_korildi(bigint[]) from public, anon;
grant execute on function aros_yuk_ozgarish_korildi(bigint[]) to authenticated;

comment on function aros_yuk_ozgarish_korildi(bigint[]) is
  'aros_yuk_ozgarish qatorlarini korildi=true qiladi (kim/qachon). Ruxsat: '
  'perm_has_page(''yuklar'').';


-- #####################################################################
-- ##  18-BO'LIM — PostgREST sxema keshini yangilash (2-QISM)          ##
-- #####################################################################

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  19-BO'LIM — YAKUNIY TEKSHIRUV (2-QISM, faqat select/raise)      ##
-- #####################################################################

do $ays_final$
declare
  v_ok boolean;
begin
  if to_regclass('public.aros_yuk_snapshot') is null then
    raise exception 'YAKUNIY TEKSHIRUV: aros_yuk_snapshot jadvali yaralmadi';
  end if;
  if to_regclass('public.aros_yuk_ozgarish') is null then
    raise exception 'YAKUNIY TEKSHIRUV: aros_yuk_ozgarish jadvali yaralmadi';
  end if;

  if not exists (select 1 from pg_constraint where conname = 'aros_yuk_ozgarish_tur_check') then
    -- Postgres avtomatik nomi turlicha bolishi mumkin — shuning uchun check bor-yoqligini
    -- pg_get_constraintdef orqali qidiramiz (aniq nomga tayanmaymiz).
    if not exists (
      select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
       where t.relname = 'aros_yuk_ozgarish' and c.contype = 'c'
         and pg_get_constraintdef(c.oid) like '%tur = any%'
    ) then
      raise exception 'YAKUNIY TEKSHIRUV: aros_yuk_ozgarish.tur CHECK constraint topilmadi';
    end if;
  end if;

  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='aros_yuk_snapshot' and policyname='aros_yuk_snapshot_sel') then
    raise exception 'YAKUNIY TEKSHIRUV: aros_yuk_snapshot_sel policy yoq';
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='aros_yuk_ozgarish' and policyname='aros_yuk_ozgarish_sel') then
    raise exception 'YAKUNIY TEKSHIRUV: aros_yuk_ozgarish_sel policy yoq';
  end if;

  select has_table_privilege('authenticated', 'public.aros_yuk_snapshot', 'select') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun aros_yuk_snapshot SELECT yoq';
  end if;
  select has_table_privilege('authenticated', 'public.aros_yuk_snapshot', 'insert') into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated aros_yuk_snapshotga togridan yoza olmasligi kerak edi';
  end if;
  select has_table_privilege('anon', 'public.aros_yuk_ozgarish', 'select') into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: anon aros_yuk_ozgarishni oqiy olmasligi kerak edi';
  end if;

  select has_function_privilege('service_role', 'public.sync_aros_yuk_snapshot(jsonb)', 'execute') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: service_role uchun sync_aros_yuk_snapshot(jsonb) EXECUTE yoq';
  end if;
  select has_function_privilege('authenticated', 'public.sync_aros_yuk_snapshot(jsonb)', 'execute') into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated sync_aros_yuk_snapshot(jsonb) ni chaqira olmasligi kerak edi';
  end if;

  if to_regprocedure('public.aros_yuk_ozgarish_royxat(boolean,int)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: aros_yuk_ozgarish_royxat(boolean,int) yaralmadi';
  end if;
  if to_regprocedure('public.aros_yuk_ozgarish_korildi(bigint[])') is null then
    raise exception 'YAKUNIY TEKSHIRUV: aros_yuk_ozgarish_korildi(bigint[]) yaralmadi';
  end if;

  raise notice 'PROVODKA_YUK_GURUH_OZGARISH.sql (2-qism): hammasi joyida (Aros ozgarish kuzatuvi)';
end
$ays_final$;

-- #####################################################################
-- ##  20-BO'LIM — yuk_grafik_saqla: guruh a'zosiga yakka grafik TAQIQ  ##
-- #####################################################################
-- PROVODKA_5KUNLIK_GRAFIK.sql dagi funksiya tanasi SO'ZMA-SO'Z, faqat guruh
-- qorovuli qo'shilgan (imzo o'zgarmagan). Klient `kod:'guruhda'` ni ko'rsa
-- foydalanuvchini guruh muharririga yo'naltiradi.

create or replace function yuk_grafik_saqla(
  p_yuk_id    integer,
  p_narx      numeric,
  p_valyuta   text,
  p_rows      jsonb,
  p_kelishuv  text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $yg_saqla$
declare
  v_calc     jsonb;
  v_maqsad   numeric;
  v_rows     jsonb;
  v_row      jsonb;
  v_sana     date;
  v_summa    numeric;
  v_izoh     text;
  v_jami     numeric := 0;
  v_n        int := 0;
  v_farq     numeric;
  v_min_sana date;
  v_valyuta  text := upper(coalesce(p_valyuta, 'UZS'));
begin
  if not coalesce(perm_has_page('beshkunlik_edit') or perm_has_page('yuklar'), false) then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  if p_yuk_id is null then
    return jsonb_build_object('ok', false, 'kod', 'yuk_id');
  end if;

  perform pg_advisory_xact_lock(hashtext('yuk_grafik:' || p_yuk_id::text));

  -- 🔴 2026-09-14: yuk GURUH grafigida bo'lsa, yakka grafik yozib bo'lmaydi —
  --    aks holda bitta yukda ikkita grafik (guruh + yakka) paydo bo'lib,
  --    Qarzmiz ikki marta sanalardi. Guruhni yuk_grafik_guruh_saqla tahrirlaydi.
  if exists (select 1 from yuk_grafik_guruh_yuk g where g.yuk_id = p_yuk_id) then
    return jsonb_build_object('ok', false, 'kod', 'guruhda',
             'guruh_id', (select g.guruh_id from yuk_grafik_guruh_yuk g where g.yuk_id = p_yuk_id));
  end if;

  v_rows := coalesce(p_rows, '[]'::jsonb);
  if jsonb_typeof(v_rows) <> 'array' then
    return jsonb_build_object('ok', false, 'kod', 'rows_shakli');
  end if;

  if jsonb_array_length(v_rows) = 0 then
    delete from yuk_tolov_grafik where yuk_id = p_yuk_id;
    update yuk_deadline set deadline = null,
                             izoh = case when p_kelishuv is not null then p_kelishuv else izoh end
     where yuk_id = p_yuk_id;
    return jsonb_build_object('ok', true, 'jami', 0);
  end if;

  for v_row in select * from jsonb_array_elements(v_rows) loop
    v_sana := null; v_summa := null;
    begin v_sana := (v_row ->> 'sana')::date; exception when others then v_sana := null; end;
    begin v_summa := (v_row ->> 'summa')::numeric; exception when others then v_summa := null; end;
    if v_sana is null or v_summa is null or v_summa <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'qator_notogri');
    end if;
    v_jami := v_jami + v_summa;
    v_n := v_n + 1;
  end loop;

  v_calc := _yuk_grafik_maqsad_calc(p_yuk_id, p_narx, p_valyuta);
  if not coalesce((v_calc ->> 'ok')::boolean, false) then
    return coalesce(v_calc, jsonb_build_object('ok', false, 'kod', 'kurs_yoq'));
  end if;
  v_maqsad := (v_calc ->> 'maqsad')::numeric;
  v_farq := v_jami - v_maqsad;
  if abs(v_farq) > 1 then
    return jsonb_build_object('ok', false, 'kod', 'summa_mos_emas', 'jami', v_jami, 'maqsad', v_maqsad, 'farq', v_farq);
  end if;

  delete from yuk_tolov_grafik where yuk_id = p_yuk_id;
  v_min_sana := null;
  for v_row in select * from jsonb_array_elements(v_rows) loop
    v_sana  := (v_row ->> 'sana')::date;
    v_summa := (v_row ->> 'summa')::numeric;
    v_izoh  := v_row ->> 'izoh';
    insert into yuk_tolov_grafik (yuk_id, sana, summa, valyuta, izoh)
      values (p_yuk_id, v_sana, v_summa, v_valyuta, v_izoh);
    if v_min_sana is null or v_sana < v_min_sana then
      v_min_sana := v_sana;
    end if;
  end loop;

  insert into yuk_deadline (yuk_id, deadline, narx, valyuta, izoh)
    values (p_yuk_id, v_min_sana, p_narx, v_valyuta, p_kelishuv)
  on conflict (yuk_id) do update
    set deadline = excluded.deadline,
        narx     = excluded.narx,
        valyuta  = excluded.valyuta,
        izoh     = case when p_kelishuv is not null then excluded.izoh else yuk_deadline.izoh end;

  return jsonb_build_object('ok', true, 'jami', v_jami, 'maqsad', v_maqsad, 'n', v_n);
end
$yg_saqla$;

revoke all on function yuk_grafik_saqla(integer, numeric, text, jsonb, text) from public, anon;
grant execute on function yuk_grafik_saqla(integer, numeric, text, jsonb, text) to authenticated;

notify pgrst, 'reload schema';
