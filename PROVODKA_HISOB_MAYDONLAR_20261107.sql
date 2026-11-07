-- =====================================================================
-- PROVODKA_HISOB_MAYDONLAR_20261107.sql  (2026-11-07, faqat dev, RUN kutilmoqda)
-- Hisob maydonlari (balans bo'limi / Cashflow moddasi / faoliyat turi / qulf),
-- yozuv turi (entry_type), Aros hodisa id'si (source_id) va KUZATUV REJIMI.
-- ---------------------------------------------------------------------
-- ## ASOSIY QOIDA (Asilbek): kassalar, jurnal va ESKI YOZUVLAR O'ZGARMAYDI.
--   * Hammasi ADDITIVE: yangi ustunlar default'li (null / false / 'oddiy'),
--     hech bir mavjud trigger yoki RPC xulqi o'zgarmaydi.
--   * Mavjud ob'ektlardan FAQAT BITTASI qayta yoziladi: provodka_yoz(jsonb)
--     (imzo bir xil, tana PROVODKA_YOZUV_ATOMIK.sql dan AYNAN, faqat 2 ta
--     ixtiyoriy maydon qo'shildi: entry_type, source_id).
--   * Kuzatuv triggeri HECH QACHON exception tashlamaydi va yozuvni RAD
--     ETMAYDI — faqat provodka_kuzatuv jadvaliga log yozadi.
--   * `do` bloki YO'Q (Supabase SQL editor).
--
-- ## RUN TARTIBI (butun fayl yuqoridan pastga, bir marta; qayta RUN xavfsiz)
--   0  tekshiruv (o'qish)
--   1  accounts ustunlari + CHECK
--   2  accounts BACKFILL (faqat null ustunlarga yoziladi)
--   3  entry.entry_type, entry.source_id, indeks
--   4  entry_type DEFAULT triggeri (yangi yozuvlar uchun)
--   5  entry_turi(uuid) + v_entry_turi
--   6  entry_type BACKFILL (bitta UPDATE)
--   7  provodka_yoz(jsonb) — entry_type / source_id qabul qiladi
--   8  kuzatuv: jadval + trigger + hisobot RPC
--   9  RUN dan keyingi tekshiruv + backfill'da null qolganlar ro'yxati
--  10  ROLLBACK
--
-- ## entry.source_id — HOZIR HECH KIM YOZMAYDI
-- Aros hodisa id'si uchun joy ajratildi (kelajakda sinxron workflow'lar
-- (source='aros_auto', source_id='<aros id>') yozadi). Qisman UNIQUE indeks
-- (source, source_id) takror hodisani to'sadi. Hozir barcha qatorlarda null,
-- shuning uchun indeks hech narsani cheklamaydi.
--
-- ## entry_type qanday belgilanadi
--   * Yangi yozuv: provodka_yoz(p_data -> 'entry_type') berilsa shu, aks holda
--     BEFORE INSERT triggeri (4-bo'lim) belgilardan aniqlaydi: source='aros_auto'
--     -> aros_sync, source='qarz' -> qarz, ext_ref 'kursfarq:%' -> qayta_baholash,
--     ext_ref 'convxy:%' yoki izoh 'Konvert: %' -> konvert, izoh
--     'Boshlang''ich qoldiq%' -> boshlangich_qoldiq. Qolgani 'oddiy'.
--   * Konvert sahifasi (konvert-dev.html) provodka_yoz ISHLATMAYDI — u server
--     RPC'lari (convert_start_v3 / convert_valyuta_v4 -> do_convert_v2) orqali
--     yozadi, ular entry'ni to'g'ridan insert qiladi. Shuning uchun konvert
--     belgisi klientdan emas, shu trigger orqali (RPC tanalari TEGILMAGAN).
--   * 'ichki_otkazma' (faqat pul hisoblari orasida) satrlarga bog'liq, shuning
--     uchun saqlanmaydi — entry_turi()/v_entry_turi satrlardan hosila
--     hisoblaydi (Cashflow B shundan o'qiydi).
-- =====================================================================


-- #####################################################################
-- ##  0 — TEKSHIRUV (o'qish)                                         ##
-- #####################################################################
select table_name, column_name, data_type
  from information_schema.columns
 where table_schema = 'public'
   and ((table_name = 'accounts' and column_name in ('code','name','type','section','currency','is_active'))
     or (table_name = 'entry' and column_name in ('source','ext_ref','description','is_deleted','yuk_ids','yuk_kutilmoqda')))
 order by table_name, column_name;
-- Kutilgan: accounts 6 ta, entry 6 ta. Kam bo'lsa 3/7/8-bo'limlarni RUN QILMANG.

select to_regprocedure('public.provodka_yoz(jsonb)') as provodka_yoz_bor,
       to_regprocedure('public.is_admin()')          as is_admin_bor;


-- #####################################################################
-- ##  1 — accounts yangi ustunlari                                   ##
-- #####################################################################
-- balans_bolimi : Balans sahifasi bo'limi
-- cf_modda      : Cashflow moddasi
-- faoliyat_turi : Cashflow faoliyat turi
-- is_locked     : qulflangan hisobga YANGI yozuv taqiqlanadi (HOZIRCHA RAD ETILMAYDI —
--                 faqat provodka_kuzatuv logiga yoziladi)
-- is_cash QO'SHILMAYDI: pul hisobi = section='pul'. currency allaqachon bor.
-- Inline CHECK: eski qatorlar null bo'lgani uchun o'tadi; ustun bor bo'lsa
-- bo'lim butunlay o'tkazib yuboriladi (qayta RUN xavfsiz).
alter table accounts add column if not exists balans_bolimi text
  constraint accounts_balans_bolimi_chk check (balans_bolimi in
    ('joriy_aktiv','uzoq_aktiv','joriy_majburiyat','uzoq_majburiyat','kapital','daromad','xarajat'));
alter table accounts add column if not exists cf_modda text
  constraint accounts_cf_modda_chk check (cf_modda in
    ('mijoz_tushum','boshqa_tushum','mijoz_qaytarish','yetkazuvchi_tolov','ish_haqi','ijara','xayriya',
     'boshqa_operatsion','soliq','asosiy_vosita','qarz_berildi','qarz_olindi','qarz_qaytarildi','egasi','ichki'));
alter table accounts add column if not exists faoliyat_turi text
  constraint accounts_faoliyat_turi_chk check (faoliyat_turi in ('operatsion','investitsiya','moliyaviy'));
alter table accounts add column if not exists is_locked boolean not null default false;

comment on column accounts.balans_bolimi is 'Balans bo''limi: joriy_aktiv|uzoq_aktiv|joriy_majburiyat|uzoq_majburiyat|kapital|daromad|xarajat. null = belgilanmagan (kuzatuv logiga tushadi).';
comment on column accounts.cf_modda      is 'Cashflow moddasi (mijoz_tushum, yetkazuvchi_tolov, ish_haqi, ijara, xayriya, soliq, asosiy_vosita, qarz_*, egasi, ichki, ...). null = belgilanmagan.';
comment on column accounts.faoliyat_turi is 'Cashflow faoliyat turi: operatsion|investitsiya|moliyaviy.';
comment on column accounts.is_locked     is 'true = hisobga yangi yozuv taqiqlanadi. HOZIRCHA faqat kuzatuv logi (provodka_kuzatuv), rad etilmaydi.';


-- #####################################################################
-- ##  2 — accounts BACKFILL (faqat hali null ustunlarga; qo'lda          ##
-- ##      qo'yilganni ESKI qiymatga QAYTARMAYDI)                       ##
-- #####################################################################
-- 2.1  balans_bolimi
--   type kapital/daromad/xarajat bo'lsa shu; pul (section='pul') -> joriy_aktiv;
--   4xxx debitorlar, 29xx / section='tovar' tovar -> joriy_aktiv; 6xxx -> joriy_majburiyat;
--   8xxx -> kapital. Boshqasi (1xxx, 2xxx tovardan boshqa, 3xxx, 7xxx...) ANIQ EMAS -> null.
update accounts a
   set balans_bolimi = case
         when a.type in ('kapital','daromad','xarajat') then a.type
         when a.section = 'pul'                          then 'joriy_aktiv'
         when a.code like '4%'                           then 'joriy_aktiv'
         when a.code like '29%' or a.section = 'tovar'   then 'joriy_aktiv'
         when a.code like '6%'                           then 'joriy_majburiyat'
         when a.code like '8%'                           then 'kapital'
       end
 where a.balans_bolimi is null
   and (a.type in ('kapital','daromad','xarajat') or a.section = 'pul' or a.section = 'tovar'
        or a.code like '4%' or a.code like '29%' or a.code like '6%' or a.code like '8%');

-- 2.2  cf_modda + faoliyat_turi (faqat ANIQ holatlar)
update accounts set cf_modda = 'ichki'
 where cf_modda is null and section = 'pul';                          -- kassalar: ichki harakat

update accounts set cf_modda = 'yetkazuvchi_tolov', faoliyat_turi = coalesce(faoliyat_turi, 'operatsion')
 where cf_modda is null and code in ('9110', '6010');
update accounts set cf_modda = 'mijoz_tushum', faoliyat_turi = coalesce(faoliyat_turi, 'operatsion')
 where cf_modda is null and code in ('4010', '9010');
update accounts set cf_modda = 'qarz_berildi', faoliyat_turi = coalesce(faoliyat_turi, 'investitsiya')
 where cf_modda is null and code = '4720';
update accounts set cf_modda = 'qarz_olindi', faoliyat_turi = coalesce(faoliyat_turi, 'moliyaviy')
 where cf_modda is null and code = '6820';

-- nomidan taxmin (faqat xarajat moddalari)
update accounts set cf_modda = 'ish_haqi', faoliyat_turi = coalesce(faoliyat_turi, 'operatsion')
 where cf_modda is null and type = 'xarajat'
   and name ~* '(ish\s*haqi|ishhaqi|oylik|maosh|zarplat)';
update accounts set cf_modda = 'ijara', faoliyat_turi = coalesce(faoliyat_turi, 'operatsion')
 where cf_modda is null and type = 'xarajat' and name ~* 'ijara';
update accounts set cf_modda = 'xayriya', faoliyat_turi = coalesce(faoliyat_turi, 'operatsion')
 where cf_modda is null and type = 'xarajat' and name ~* '(xayriya|ehson|zakot|sadaqa)';
update accounts set cf_modda = 'soliq', faoliyat_turi = coalesce(faoliyat_turi, 'operatsion')
 where cf_modda is null and type = 'xarajat' and name ~* 'soliq' and name !~* 'soliqsiz';


-- #####################################################################
-- ##  3 — entry.entry_type, entry.source_id                          ##
-- #####################################################################
alter table entry add column if not exists entry_type text not null default 'oddiy'
  constraint entry_entry_type_chk check (entry_type in
    ('oddiy','ichki_otkazma','konvert','qayta_baholash','tuzatish','boshlangich_qoldiq','aros_sync','qarz','ehson'));
alter table entry add column if not exists source_id text;

create unique index if not exists entry_source_sid_uniq
  on entry (source, source_id)
  where source_id is not null and is_deleted = false;

comment on column entry.entry_type is 'Yozuv turi: oddiy|ichki_otkazma|konvert|qayta_baholash|tuzatish|boshlangich_qoldiq|aros_sync|qarz|ehson. Satrlardan hosila: entry_turi(id) / v_entry_turi.';
comment on column entry.source_id  is 'Tashqi hodisa id (Aros). HOZIR HECH KIM YOZMAYDI. (source, source_id) qisman unique.';


-- #####################################################################
-- ##  4 — entry_type DEFAULT triggeri (yangi yozuvlar)               ##
-- #####################################################################
-- Faqat entry_type hali 'oddiy' bo'lsa va belgi aniq bo'lsa o'zgartiradi.
-- Boshqa hech narsaga tegmaydi, exception tashlamaydi.
create or replace function trg_entry_turi_default_fn()
returns trigger
language plpgsql
set search_path = public
as $t$
begin
  if new.entry_type is distinct from 'oddiy' then return new; end if;
  new.entry_type := case
    when new.source = 'aros_auto'                         then 'aros_sync'
    when new.source = 'qarz'                              then 'qarz'
    when coalesce(new.ext_ref, '') like 'kursfarq:%'      then 'qayta_baholash'
    when coalesce(new.ext_ref, '') like 'convxy:%'
      or coalesce(new.description, '') like 'Konvert: %'  then 'konvert'
    when coalesce(new.description, '') like 'Boshlang''ich qoldiq%' then 'boshlangich_qoldiq'
    else 'oddiy' end;
  return new;
end $t$;

drop trigger if exists trg_entry_turi_default on entry;
create trigger trg_entry_turi_default
  before insert on entry
  for each row execute function trg_entry_turi_default_fn();


-- #####################################################################
-- ##  5 — v_entry_turi + entry_turi(uuid)                            ##
-- #####################################################################
-- hosila_turi: saqlangan tur 'oddiy' dan boshqa bo'lsa SHU; 'oddiy' bo'lsa
-- belgilar va satrlardan hosila (4-bo'lim qoidalari + "barcha satrlari pul
-- hisoblari" -> ichki_otkazma). Cashflow B shu ustundan o'qiydi.
create or replace view v_entry_turi as
select e.id         as entry_id,
       e.entry_type as entry_type,
       case
         when e.entry_type <> 'oddiy'                            then e.entry_type
         when e.source = 'aros_auto'                             then 'aros_sync'
         when e.source = 'qarz'                                  then 'qarz'
         when coalesce(e.ext_ref, '') like 'kursfarq:%'          then 'qayta_baholash'
         when coalesce(e.ext_ref, '') like 'convxy:%'
           or coalesce(e.description, '') like 'Konvert: %'      then 'konvert'
         when coalesce(e.description, '') like 'Boshlang''ich qoldiq%' then 'boshlangich_qoldiq'
         when x.n >= 2 and x.n = x.np                            then 'ichki_otkazma'
         else 'oddiy' end as hosila_turi
  from entry e
  left join lateral (
    select count(*)                                  as n,
           count(*) filter (where a.section = 'pul') as np
      from entry_line l
      join accounts a on a.id = l.account_id
     where l.entry_id = e.id
  ) x on true;

create or replace function entry_turi(p_entry uuid)
returns text
language sql
stable
set search_path = public
as $f$
  select v.hosila_turi from v_entry_turi v where v.entry_id = p_entry;
$f$;

grant select on v_entry_turi to authenticated;
revoke all on function entry_turi(uuid) from public, anon;
grant execute on function entry_turi(uuid) to authenticated;


-- #####################################################################
-- ##  6 — entry_type BACKFILL (bitta UPDATE, idempotent)             ##
-- #####################################################################
-- Faqat entry_type='oddiy' qatorlar va faqat turi aniq bo'lganlar. Boshqa
-- ustunlarga tegilmaydi. Ehson yozuvlari ('ehson') belgilanmaydi — ularning
-- aniq belgisi ma'lum emas, 'oddiy' / 'ichki_otkazma' bo'lib qoladi.
update entry e
   set entry_type = v.hosila_turi
  from v_entry_turi v
 where v.entry_id = e.id
   and e.entry_type = 'oddiy'
   and v.hosila_turi <> 'oddiy';


-- #####################################################################
-- ##  7 — provodka_yoz(jsonb): entry_type + source_id (ixtiyoriy)    ##
-- #####################################################################
-- Imzo, qaytishi, huquqlar, xatolar — PROVODKA_YOZUV_ATOMIK.sql bilan AYNAN bir xil.
-- Farq faqat: p_data ->> 'entry_type' (sukut 'oddiy') va p_data ->> 'source_id'.
-- entry_type ro'yxatda bo'lmasa 22000 (CHECK 23514 dan tushunarliroq).
create or replace function provodka_yoz(p_data jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $fn$
declare
  v_lines jsonb := p_data -> 'lines';
  v_yuk   jsonb := p_data -> 'yuk_taqsim';
  v_ext   text  := nullif(trim(p_data ->> 'ext_ref'), '');
  v_etype text  := coalesce(nullif(trim(p_data ->> 'entry_type'), ''), 'oddiy');
  v_sid   text  := nullif(trim(p_data ->> 'source_id'), '');
  v_n     int;
  v_bad   int;
  v_dt    numeric;
  v_kt    numeric;
  v_entry uuid;
  v_yn    int := 0;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bo''lishi kerak' using errcode = '22000';
  end if;

  if v_etype not in ('oddiy','ichki_otkazma','konvert','qayta_baholash','tuzatish',
                     'boshlangich_qoldiq','aros_sync','qarz','ehson') then
    raise exception 'entry_type noto''g''ri: %', v_etype using errcode = '22000';
  end if;

  if v_lines is null or jsonb_typeof(v_lines) <> 'array' then
    raise exception 'Yozuv satrlari (lines) berilmadi' using errcode = '22000';
  end if;
  v_n := jsonb_array_length(v_lines);
  if v_n < 2 then
    raise exception 'Yozuvda kamida 2 ta satr bo''lishi kerak (Dt va Kt)' using errcode = '22000';
  end if;

  select count(*) into v_bad
    from jsonb_array_elements(v_lines) as x
   where coalesce(jsonb_typeof(x -> 'debit'), 'null')     not in ('number', 'null')
      or coalesce(jsonb_typeof(x -> 'credit'), 'null')    not in ('number', 'null')
      or coalesce(jsonb_typeof(x -> 'fc_amount'), 'null') not in ('number', 'null');
  if v_bad > 0 then
    raise exception 'debit / credit / fc_amount raqam bo''lishi kerak' using errcode = '22000';
  end if;

  select count(*) into v_bad
    from jsonb_array_elements(v_lines) as x
   where nullif(x ->> 'account_id', '') is null
      or (x ->> 'account_id') !~ '^[0-9a-fA-F-]{36}$';
  if v_bad > 0 then
    raise exception 'Har satrda hisob (account_id) bo''lishi kerak' using errcode = '22000';
  end if;

  select count(*) into v_bad
    from jsonb_array_elements(v_lines) as x
   where coalesce((x ->> 'debit')::numeric, 0)  < 0
      or coalesce((x ->> 'credit')::numeric, 0) < 0;
  if v_bad > 0 then
    raise exception 'Summa manfiy bo''lishi mumkin emas' using errcode = '22000';
  end if;

  select count(*) into v_bad
    from jsonb_array_elements(v_lines) as x
   where (coalesce((x ->> 'debit')::numeric, 0)  > 0
      and coalesce((x ->> 'credit')::numeric, 0) > 0)
      or (coalesce((x ->> 'debit')::numeric, 0)  = 0
     and  coalesce((x ->> 'credit')::numeric, 0) = 0);
  if v_bad > 0 then
    raise exception 'Har satrda Dt yoki Kt dan faqat bittasi musbat bo''lishi kerak' using errcode = '22000';
  end if;

  select coalesce(sum((x ->> 'debit')::numeric), 0),
         coalesce(sum((x ->> 'credit')::numeric), 0)
    into v_dt, v_kt
    from jsonb_array_elements(v_lines) as x;
  if v_dt <= 0 then
    raise exception 'Yozuv summasi noldan katta bo''lishi kerak' using errcode = '22000';
  end if;
  if v_dt <> v_kt then
    raise exception 'Dt va Kt teng emas: Dt=% Kt=%', v_dt, v_kt using errcode = '22000';
  end if;

  if v_yuk is not null and jsonb_typeof(v_yuk) = 'array' and jsonb_array_length(v_yuk) > 0 then
    select count(*) into v_bad
      from jsonb_array_elements(v_yuk) as x
     where coalesce(jsonb_typeof(x -> 'yuk_id'), 'null')    <> 'number'
        or coalesce(jsonb_typeof(x -> 'summa_uzs'), 'null') <> 'number';
    if v_bad > 0 then
      raise exception 'yuk_taqsim: yuk_id va summa_uzs raqam bo''lishi kerak' using errcode = '22000';
    end if;
  end if;

  insert into entry (entry_date, description, source, status,
                     filial_ids, davr_start, davr_end, kommunal_turi,
                     fc_rate, yuk_ids, yuk_kutilmoqda, ext_ref,
                     entry_type, source_id)
  values (
    nullif(p_data ->> 'entry_date', '')::date,
    nullif(p_data ->> 'description', ''),
    coalesce(nullif(p_data ->> 'source', ''), 'manual'),
    coalesce(nullif(p_data ->> 'status', ''), 'posted'),
    case when jsonb_typeof(p_data -> 'filial_ids') = 'array'
         then coalesce((select array_agg(t.val::uuid)
                          from jsonb_array_elements_text(p_data -> 'filial_ids') as t(val)),
                       '{}'::uuid[])
         else '{}'::uuid[] end,
    nullif(p_data ->> 'davr_start', '')::date,
    nullif(p_data ->> 'davr_end', '')::date,
    nullif(p_data ->> 'kommunal_turi', ''),
    nullif(p_data ->> 'fc_rate', '')::numeric,
    case when jsonb_typeof(p_data -> 'yuk_ids') = 'array'
         then coalesce((select array_agg(t.val::integer)
                          from jsonb_array_elements_text(p_data -> 'yuk_ids') as t(val)),
                       '{}'::integer[])
         else '{}'::integer[] end,
    coalesce(nullif(p_data ->> 'yuk_kutilmoqda', '')::boolean, false),
    v_ext,
    v_etype,
    v_sid
  )
  returning id into v_entry;

  insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
  select v_entry,
         (t.x ->> 'account_id')::uuid,
         coalesce((t.x ->> 'debit')::numeric, 0),
         coalesce((t.x ->> 'credit')::numeric, 0),
         nullif(t.x ->> 'fc_amount', '')::numeric
    from jsonb_array_elements(v_lines) with ordinality as t(x, ord)
   order by t.ord;

  if v_yuk is not null and jsonb_typeof(v_yuk) = 'array' and jsonb_array_length(v_yuk) > 0 then
    insert into entry_yuk (entry_id, yuk_id, summa_uzs)
    select v_entry,
           (x ->> 'yuk_id')::integer,
           (x ->> 'summa_uzs')::numeric
      from jsonb_array_elements(v_yuk) as x
     where (x ->> 'summa_uzs')::numeric > 0;
    get diagnostics v_yn = row_count;
  end if;

  return jsonb_build_object('ok', true,
                            'entry_id', v_entry,
                            'satr', v_n,
                            'yuk', v_yn);

exception
  when unique_violation then
    if v_ext is null then
      raise;
    end if;
    raise exception 'Bu xarajat allaqachon saqlangan (takroriy yuborish tosildi)'
      using errcode = '23505';
end $fn$;

revoke all on function provodka_yoz(jsonb) from public, anon;
grant execute on function provodka_yoz(jsonb) to authenticated;

comment on function provodka_yoz(jsonb) is
  'Provodkani ATOMIK yozadi: entry + entry_line (+ entry_yuk) bitta tranzaksiyada. '
  'security INVOKER — RLS va entry_line triggerlari (perm guard, limit guard, notify) '
  'bugungidek ishlaydi. Rad etilsa hech narsa yozilmaydi (yetim sarlavha tug''ilmaydi). '
  'ext_ref berilsa takror yuborish 23505 bilan to''siladi. lock_timeout = 5s. '
  'Ixtiyoriy: entry_type (sukut oddiy), source_id.';


-- #####################################################################
-- ##  8 — KUZATUV REJIMI (faqat log, HECH QACHON rad etmaydi)        ##
-- #####################################################################
create table if not exists provodka_kuzatuv (
  id         bigserial primary key,
  entry_id   uuid,                 -- ataylab FK YO'Q: log hech qachon yozuvga xalaqit bermasin
  qoida      text not null,
  xabar      text,
  created_at timestamptz not null default now()
);
create unique index if not exists provodka_kuzatuv_entry_qoida_uniq on provodka_kuzatuv (entry_id, qoida);
create index if not exists provodka_kuzatuv_created_idx on provodka_kuzatuv (created_at desc);

alter table provodka_kuzatuv enable row level security;
revoke all on provodka_kuzatuv from public, anon, authenticated;
-- policy YO'Q: o'qish faqat provodka_kuzatuv_hisobot() (admin) orqali.

-- Qoidalar (qoida kodi -> ma'nosi):
--   is_locked_hisob     qulflangan hisobga yozuv
--   kassa_kassa_tur     faqat pul hisoblaridan iborat yozuv, turi ichki_otkazma/konvert/aros_sync emas
--   yuk_boglanmagan     9110 satri bor, lekin yuk_ids ham, yuk_kutilmoqda ham yo'q
--   balans_bolimi_yoq   balans_bolimi belgilanmagan hisobga yozuv
--   qarz_hisob_togri    6010 / 4010 ga to'g'ridan yozuv (qarz daftari yo'q)
-- CONSTRAINT trigger DEFERRABLE INITIALLY DEFERRED: COMMIT paytida ishlaydi,
-- ya'ni yozuvning BARCHA satrlari ko'rinadi (kassa<->kassa qoidasi uchun kerak).
-- Butun tana begin ... exception when others then null — log yozilmasa ham
-- yozuv saqlanadi. SECURITY DEFINER: RLS log yozishga xalaqit bermasin.
create or replace function trg_provodka_kuzatuv_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $t$
declare
  a  record;
  e  record;
  n  int;
  np int;
begin
  begin
    select code, name, section, is_locked, balans_bolimi into a from accounts where id = new.account_id;
    if not found then return null; end if;
    select source, entry_type, yuk_ids, yuk_kutilmoqda into e from entry where id = new.entry_id;
    if not found then return null; end if;

    if coalesce(a.is_locked, false) then
      insert into provodka_kuzatuv (entry_id, qoida, xabar)
      values (new.entry_id, 'is_locked_hisob', 'Qulflangan hisobga yozuv: ' || a.code || ' ' || coalesce(a.name, ''))
      on conflict do nothing;
    end if;

    if a.balans_bolimi is null then
      insert into provodka_kuzatuv (entry_id, qoida, xabar)
      values (new.entry_id, 'balans_bolimi_yoq', 'Balans bo''limi yo''q hisob: ' || a.code || ' ' || coalesce(a.name, ''))
      on conflict do nothing;
    end if;

    if a.code in ('6010', '4010') then
      insert into provodka_kuzatuv (entry_id, qoida, xabar)
      values (new.entry_id, 'qarz_hisob_togri', 'To''g''ridan-to''g''ri yozuv: ' || a.code || ' ' || coalesce(a.name, ''))
      on conflict do nothing;
    end if;

    if a.code = '9110' and coalesce(array_length(e.yuk_ids, 1), 0) = 0 and not coalesce(e.yuk_kutilmoqda, false) then
      insert into provodka_kuzatuv (entry_id, qoida, xabar)
      values (new.entry_id, 'yuk_boglanmagan', '9110 satri: yuk_ids ham, yuk_kutilmoqda ham yo''q')
      on conflict do nothing;
    end if;

    if a.section = 'pul' and coalesce(e.entry_type, 'oddiy') not in ('ichki_otkazma', 'konvert', 'aros_sync') then
      select count(*), count(*) filter (where x.section = 'pul')
        into n, np
        from entry_line l join accounts x on x.id = l.account_id
       where l.entry_id = new.entry_id;
      if n >= 2 and n = np then
        insert into provodka_kuzatuv (entry_id, qoida, xabar)
        values (new.entry_id, 'kassa_kassa_tur',
                'Kassa<->kassa yozuv, turi: ' || coalesce(e.entry_type, 'oddiy'))
        on conflict do nothing;
      end if;
    end if;
  exception when others then
    null;
  end;
  return null;
end $t$;

drop trigger if exists trg_provodka_kuzatuv on entry_line;
create constraint trigger trg_provodka_kuzatuv
  after insert on entry_line
  deferrable initially deferred
  for each row execute function trg_provodka_kuzatuv_fn();

-- Hisobot (faqat admin): qoida bo'yicha sanoq + oxirgi 50.
create or replace function provodka_kuzatuv_hisobot(p_kun int default 7)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $f$
declare
  v_kun int := least(greatest(coalesce(p_kun, 7), 1), 365);
  v_from timestamptz;
begin
  if not coalesce(is_admin(), false) then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  v_from := now() - make_interval(days => v_kun);
  return jsonb_build_object(
    'ok', true,
    'kun', v_kun,
    'sanoq', coalesce((
      select jsonb_agg(jsonb_build_object('qoida', t.qoida, 'soni', t.soni) order by t.soni desc, t.qoida)
        from (select qoida, count(*) as soni from provodka_kuzatuv where created_at >= v_from group by qoida) t
    ), '[]'::jsonb),
    'oxirgi', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'entry_id', t.entry_id, 'qoida', t.qoida, 'xabar', t.xabar,
               'created_at', t.created_at, 'entry_date', t.entry_date, 'description', t.description)
             order by t.created_at desc, t.id desc)
        from (select k.id, k.entry_id, k.qoida, k.xabar, k.created_at, e.entry_date, e.description
                from provodka_kuzatuv k left join entry e on e.id = k.entry_id
               where k.created_at >= v_from
               order by k.created_at desc, k.id desc
               limit 50) t
    ), '[]'::jsonb)
  );
end $f$;

revoke all on function provodka_kuzatuv_hisobot(int) from public, anon;
grant execute on function provodka_kuzatuv_hisobot(int) to authenticated;


-- #####################################################################
-- ##  9 — RUN dan KEYIN tekshiruv                                    ##
-- #####################################################################
-- 9.1  yozuv turlari taqsimoti (eski yozuvlar: faqat entry_type ustuni o'zgargan)
select entry_type, count(*) from entry group by 1 order by 2 desc;

-- 9.2  hisob maydonlari qamrovi
select count(*) as jami,
       count(balans_bolimi) as balans_bolimi_bor,
       count(cf_modda)      as cf_modda_bor,
       count(faoliyat_turi) as faoliyat_turi_bor
  from accounts;

-- 9.3  backfill'da balans_bolimi NULL qolgan hisoblar (qo'lda belgilash kerak)
select code, name, type, section
  from accounts
 where balans_bolimi is null
 order by code;

-- 9.4  cf_modda NULL qolgan NOPUL hisoblar (pul hisoblari 'ichki', ularga kerak emas)
select code, name, type, balans_bolimi
  from accounts
 where cf_modda is null and coalesce(section, '') <> 'pul'
 order by code;

-- 9.5  trigger/funksiya/view bormi (kutilgan: 4 qator, hammasi 1)
select 'trg_entry_turi_default' as obyekt, count(*) from pg_trigger where tgname = 'trg_entry_turi_default'
union all select 'trg_provodka_kuzatuv', count(*) from pg_trigger where tgname = 'trg_provodka_kuzatuv'
union all select 'v_entry_turi', count(*) from pg_views where viewname = 'v_entry_turi'
union all select 'provodka_kuzatuv_hisobot', count(*) from pg_proc where proname = 'provodka_kuzatuv_hisobot';

-- 9.6  provodka_yoz hamon INVOKER (kutilgan: false)
select prosecdef as security_definer from pg_proc where proname = 'provodka_yoz';

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  10 — ROLLBACK (qo'lda; eski sahifalar baribir ishlaydi)        ##
-- #####################################################################
--   drop trigger if exists trg_provodka_kuzatuv on entry_line;
--   drop trigger if exists trg_entry_turi_default on entry;
--   drop function if exists provodka_kuzatuv_hisobot(int);
--   drop function if exists trg_provodka_kuzatuv_fn();
--   drop function if exists trg_entry_turi_default_fn();
--   drop function if exists entry_turi(uuid);
--   drop view if exists v_entry_turi;
--   drop table if exists provodka_kuzatuv;
--   provodka_yoz: PROVODKA_YOZUV_ATOMIK.sql 1-bo'limini qayta RUN qiling.
--   (ustunlar — accounts.balans_bolimi/cf_modda/faoliyat_turi/is_locked,
--    entry.entry_type/source_id — zararsiz, qoldirish mumkin)
