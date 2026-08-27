-- =====================================================================
-- PROVODKA_OVQAT.sql
-- OVQAT XARAJATI NAZORATI — hodim ro'yxati (aros_staff) + obed/zavtrak
-- counter + kuniga-1-marta himoyasi + tahrirlanmaydigan yozuv.
-- ---------------------------------------------------------------------
-- Brief: BRIEF_PROVODKA_OVQAT.md. Bu fayl FAQAT SQL, v1 — oddiy yo'l
-- (taqsim/so'rov emas). Klient (hodim-dev.html va h.k.) boshqa ishda.
--
-- ## RUN TARTIBI (Asilbek) — BO'LIMLARNI TARTIB BILAN, BITTALAB
--   0-BO'LIM   — old shart tekshiruvi (faqat select)
--   0.5-BO'LIM — ovqat_kiritgan(text) — ijrochi_nomi() ga xavfsiz qobiq
--   1-BO'LIM — aros_staff jadvali + aros_staff_sync(jsonb)     (n8n yozadi)
--   2-BO'LIM — nom_norm(text) + staff_branch_map (+ set/royxat)
--   3-BO'LIM — provodka_config narxlari + ovqat_narxlar/set_ovqat_narx
--   4-BO'LIM — accounts.ovqat_modda + set_modda_flag('ovqat')
--   5-BO'LIM — entry_ovqat jadvali + is_deleted ko'zgu trigger
--   6-BO'LIM — ovqat_bugun(date, int[])                       (oldindan tekshiruv)
--   7-BO'LIM — xarajat_saqlash_ovqat(jsonb)                    (ASOSIY YOZISH RPC)
--   8-BO'LIM — entry_line ustidagi ikki qo'shimcha trigger:
--                (a) aylanib o'tish to'sig'i (DEFERRED constraint trigger)
--                (b) tahrir taqiqi (BEFORE UPDATE)
--   9-BO'LIM — v_ovqat_hisobot view
--  10-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)
--
-- ## OLD SHART (bazada bo'lishi kerak)
--   PROVODKA_TOSIQ_OCHIR.sql  -> xarajat_saqlash_taqsim (naqsh manbai)
--   PROVODKA_EXT_REF.sql      -> entry.ext_ref, entry_ext_ref_uniq indeksi
--   PROVODKA_JURNAL_V2.sql    -> set_modda_flag(uuid,text,boolean) eng oxirgi versiya
--   PROVODKA_V8.sql           -> provodka_config jadvali
--   PROVODKA_PERMS.sql        -> is_admin(), perm_guard_entry_line, user_perms
--   PROVODKA_IJROCHI.sql      -> ijrochi_nomi(text)             (SHART EMAS — 0.5-BO'LIMdagi
--                                ovqat_kiritgan() qobig'i orqali chaqiriladi, bo'lmasa null qaytadi)
--
-- ## n8n `aros_staff_sync` PAYLOAD KONTRAKTI (o'zgarmaydi, service_role)
--   p_rows = jsonb massiv, har element:
--     { staff_id:int, ism:text, familiya:text, toliq_nom:text, lavozim:text,
--       telefon:text, photo_url:text, branch_id:int, branch_nomi:text,
--       branches:[{id,name,is_primary}], is_active:bool, work_type:text,
--       updated_at: timestamptz-ISO }
--   Javob: {upsert:int, deactivated:int}.
--   🔴 Deaktivatsiya HIMOYASI: payload 50 tadan kam elementga ega bo'lsa
--      "yo'q" bo'lgan hodimlar `is_active=false` QILINMAYDI — yarim/xato
--      javob bilan hammani o'chirib yubormasin.
--
-- ## QOIDALAR (CLAUDE.md, buzilmadi)
--   * anonim `do` bloki YO'Q.
--   * har funksiya tanasi NOMLANGAN dollar-teg (fn) bilan o'raladi
--     (izohdagi dollar-qavs paritetiga bog'liq bo'lmasin).
--   * faylda RPC ni JONLI chaqiradigan operator YO'Q — faqat katalog/jadval
--     so'rovlari (SQL editorda auth.uid() null, natija chalg'itadi).
--   * hammasi additive: eski jadval/ustun/funksiya imzosi buzilmaydi.
--   * idempotent: qayta RUN qilish xavfsiz.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (faqat select)                 ##
-- #####################################################################

select to_regprocedure('public.xarajat_saqlash_taqsim(jsonb)')       is not null as taqsim_bor,
       to_regprocedure('public.xarajat_qayta_urinish(text)')          is not null as qayta_urinish_bor,
       to_regprocedure('public.set_modda_flag(uuid,text,boolean)')    is not null as set_modda_flag_bor,
       to_regprocedure('public.is_admin()')                           is not null as is_admin_bor,
       to_regclass('public.provodka_config')                          is not null as provodka_config_bor,
       to_regclass('public.entry')                                    is not null as entry_bor,
       to_regprocedure('public.ijrochi_nomi(text)')                   is not null as ijrochi_nomi_bor;


-- #####################################################################
-- ##  0.5-BO'LIM — ovqat_kiritgan(text): ijrochi_nomi() ga XAVFSIZ    ##
-- ##  QOBIQ (PROVODKA_IJROCHI.sql SHART EMAS)                        ##
-- #####################################################################
-- 🔴 NEGA KERAK: `ovqat_bugun()` va `v_ovqat_hisobot` — LANGUAGE SQL
--    funksiya / VIEW. Ular CREATE vaqtida so'rovni to'liq PARSE qiladi
--    (plpgsql'dan farqli — u faqat birinchi CHAQIRUVDA kompilyatsiya
--    qiladi). Agar ular ichida to'g'ridan `ijrochi_nomi(...)` chaqirilsa
--    va PROVODKA_IJROCHI.sql hali RUN qilinmagan bo'lsa, CREATE FUNCTION /
--    CREATE VIEW o'zi 42883 (function does not exist) bilan yiqiladi —
--    `to_regprocedure` GUARD FOYDA BERMAYDI, chunki u PLPGSQL ichida
--    ishlaydi, LANGUAGE SQL query-planida emas.
-- YECHIM: bu qobiq PLPGSQL (opaq — CREATE vaqtida ICHKI SQL semantik
--    tekshirilmaydi, faqat birinchi chaqiruvda). `ovqat_kiritgan` doim
--    mavjud (shu faylda yaratiladi), shuning uchun uni chaqiruvchi
--    LANGUAGE SQL obyektlar (ovqat_bugun, v_ovqat_hisobot) CREATE
--    vaqtida hech qachon 42883 bermaydi — ijrochi_nomi() borligi FAQAT
--    ishga tushirish vaqtida (RUNTIME) tekshiriladi.
create or replace function ovqat_kiritgan(p_raw text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_name text;
begin
  if to_regprocedure('public.ijrochi_nomi(text)') is null then
    return null;
  end if;
  begin
    execute 'select public.ijrochi_nomi($1)' into v_name using p_raw;
  exception when others then
    v_name := null;                      -- ijrochi_nomi xato bersa jim (ism yo'q)
  end;
  return v_name;
end $fn$;

revoke all on function ovqat_kiritgan(text) from public, anon;
grant execute on function ovqat_kiritgan(text) to authenticated;

comment on function ovqat_kiritgan(text) is
  'ijrochi_nomi(text) ga xavfsiz qobiq (PROVODKA_IJROCHI.sql SHART EMAS). PLPGSQL — LANGUAGE SQL '
  'obyektlar (ovqat_bugun, v_ovqat_hisobot) CREATE vaqtida ijrochi_nomi yo''qligidan 42883 bermasin.';


-- #####################################################################
-- ##  1-BO'LIM — aros_staff (n8n katalogi) + aros_staff_sync(jsonb)  ##
-- #####################################################################

create table if not exists aros_staff (
  staff_id    int         primary key,
  ism         text,
  familiya    text,
  toliq_nom   text,
  lavozim     text,
  telefon     text,
  photo_url   text,
  branch_id   int,
  branch_nomi text,
  branches    jsonb        not null default '[]'::jsonb,
  is_active   boolean      not null default true,
  work_type   text,
  updated_at  timestamptz,
  synced_at   timestamptz  not null default now()
);

comment on table aros_staff is
  'Aros hodimlari katalogi (n8n sinxron qiladi). Yozish faqat aros_staff_sync() orqali (service_role).';

create index if not exists aros_staff_branch_idx  on aros_staff (branch_id);
create index if not exists aros_staff_active_idx  on aros_staff (is_active);

alter table aros_staff enable row level security;

drop policy if exists aros_staff_sel on aros_staff;
create policy aros_staff_sel on aros_staff
  for select to authenticated using (true);

-- 🔴 insert/update/delete policy YO'Q — faqat aros_staff_sync() (security
--    definer, table owner sifatida) yozadi.
revoke all on aros_staff from public, anon;
grant select on aros_staff to authenticated;


-- ---------------------------------------------------------------------
-- 1.1 aros_staff_sync(jsonb) — service_role ONLY (n8n webhook)
-- ---------------------------------------------------------------------
create or replace function aros_staff_sync(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_role        text;
  it            jsonb;
  r             record;
  v_ids         int[] := '{}';
  v_upsert      int := 0;
  v_deact       int := 0;
  v_skipped     int := 0;
  v_staff_id    int;
  v_branch_id   int;
  v_match       text;
begin
  -- service_role ONLY (admin_set_provodka_perms bilan bir xil naqsh).
  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows massiv bo''lishi kerak' using errcode = '22000';
  end if;

  -- 🔴 Buzuq staff_id/branch_id butun payloadni yiqitmasin: raqam
  --    shaklida bo'lmasa qator o'tkazib yuboriladi (v_skipped ga sanaladi).
  for it in select * from jsonb_array_elements(p_rows) loop
    if not (coalesce(it->>'staff_id', '') ~ '^\d+$') then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    v_staff_id := (it->>'staff_id')::int;

    if coalesce(it->>'branch_id', '') ~ '^\d+$' then
      v_branch_id := (it->>'branch_id')::int;
    else
      v_branch_id := null;               -- bo'sh yoki buzuq -> filialsiz saqlanadi
    end if;

    insert into aros_staff (staff_id, ism, familiya, toliq_nom, lavozim, telefon,
                             photo_url, branch_id, branch_nomi, branches,
                             is_active, work_type, updated_at, synced_at)
    values (
      v_staff_id,
      nullif(it->>'ism', ''),
      nullif(it->>'familiya', ''),
      nullif(it->>'toliq_nom', ''),
      nullif(it->>'lavozim', ''),
      nullif(it->>'telefon', ''),
      nullif(it->>'photo_url', ''),
      v_branch_id,
      nullif(it->>'branch_nomi', ''),
      coalesce(it->'branches', '[]'::jsonb),
      coalesce((nullif(it->>'is_active',''))::boolean, true),
      nullif(it->>'work_type', ''),
      coalesce(nullif(it->>'updated_at', '')::timestamptz, now())
    )
    on conflict (staff_id) do update
       set ism         = excluded.ism,
           familiya    = excluded.familiya,
           toliq_nom   = excluded.toliq_nom,
           lavozim     = excluded.lavozim,
           telefon     = excluded.telefon,
           photo_url   = excluded.photo_url,
           branch_id   = excluded.branch_id,
           branch_nomi = excluded.branch_nomi,
           branches    = excluded.branches,
           is_active   = excluded.is_active,
           work_type   = excluded.work_type,
           updated_at  = excluded.updated_at,
           synced_at   = now();

    v_upsert := v_upsert + 1;
    v_ids := v_ids || v_staff_id;
  end loop;

  -- 🔴 Deaktivatsiya HIMOYASI: yarim/xato payload (< 50 element) hammani
  --    o'chirib yubormasin.
  if coalesce(array_length(v_ids, 1), 0) >= 50 then
    update aros_staff
       set is_active = false, updated_at = now()
     where staff_id <> all(v_ids) and is_active = true;
    get diagnostics v_deact = row_count;
  end if;

  -- Filial mapping avto-to'ldirish (2-BO'LIM). `manba='qolda'` qatorlarga
  -- tegilmaydi (staff_branch_map upsert shartida). Bir branch_id ikki xil
  -- branch_nomi bilan kelsa (kamdan-kam) — oxirgisi g'alaba qiladi, bu
  -- zararsiz (idempotent, keyingi sinxronda tuzaladi).
  if to_regclass('public.staff_branch_map') is not null
     and to_regprocedure('public.nom_norm(text)') is not null then
    for r in
      select (x->>'branch_id')::int as bid, nullif(x->>'branch_nomi', '') as bnom
        from jsonb_array_elements(p_rows) as x
       where coalesce(x->>'branch_id', '') ~ '^\d+$'
       group by (x->>'branch_id')::int, nullif(x->>'branch_nomi', '')
    loop
      select split_part(a.subtitle, ' · ', 1) into v_match
        from accounts a
       where a.kassa_turi = 'xarajat'
         and coalesce(a.is_active, true)
         and nom_norm(split_part(a.subtitle, ' · ', 1)) = nom_norm(r.bnom)
       order by a.name
       limit 1;

      insert into staff_branch_map (branch_id, branch_nomi, provodka_filial, manba, updated_at)
      values (r.bid, r.bnom, v_match, 'avto', now())
      on conflict (branch_id) do update
         set branch_nomi     = excluded.branch_nomi,
             provodka_filial = excluded.provodka_filial,
             updated_at      = now()
       where staff_branch_map.manba = 'avto';
    end loop;
  end if;

  return jsonb_build_object('upsert', v_upsert, 'deactivated', v_deact, 'skipped', v_skipped);
end $fn$;

revoke all on function aros_staff_sync(jsonb) from public, anon, authenticated;
grant execute on function aros_staff_sync(jsonb) to service_role;

comment on function aros_staff_sync(jsonb) is
  'n8n webhook (service_role ONLY): aros_staff upsert + (payload >= 50 bo''lsa) yo''q qolganlarni deaktivatsiya. '
  'staff_id/branch_id raqam shaklida bo''lmasa qator o''tkazib yuboriladi (skipped). '
  'Har sinxronda staff_branch_map ni avto to''ldiradi (manba=avto qatorlarga).';


-- #####################################################################
-- ##  2-BO'LIM — nom_norm(text) + staff_branch_map                   ##
-- #####################################################################
-- Filial nomlarini solishtirish uchun normalizatsiya: `aros_nom_norm()`
-- (PROVODKA_TRANSFER.sql) ga BOG'LANMAYDI — u probel/kirillni olib
-- tashlamaydi va bu yerda kerakli "showroom" sinonimlari / "kassa" so'zini
-- olib tashlash yo'q. Mustaqil funksiya — bog'liqlik nol.
-- ---------------------------------------------------------------------
-- 🔴 plpgsql + ketma-ket qadamlar ATAYLAB tanlandi (chuqur ichma-ich SQL
--    ifodasi qavs balansini tekshirishni qiyinlashtiradi va xato joyini
--    yashiradi — CLAUDE.md "har o'zgartirgandan keyin balansni tekshir").
create or replace function nom_norm(p_text text)
returns text
language plpgsql
immutable
as $fn$
declare
  v text;
begin
  v := lower(coalesce(p_text, ''));

  -- 0) turli kotirovka belgilari -> oddiy lotin apostrof
  v := regexp_replace(v, '[''’`´]', '''', 'g');

  -- 1) kirill digraflari (bitta-harfli translate()dan OLDIN, aks holda
  --    masalan 'ш' alohida 's'+'h' bo'lib ketmasin)
  v := regexp_replace(v, 'ё', 'yo', 'g');
  v := regexp_replace(v, 'ж', 'zh', 'g');
  v := regexp_replace(v, 'х', 'x', 'g');
  v := regexp_replace(v, 'ц', 'ts', 'g');
  v := regexp_replace(v, 'ч', 'ch', 'g');
  v := regexp_replace(v, 'ш', 'sh', 'g');
  v := regexp_replace(v, 'щ', 'sch', 'g');
  v := regexp_replace(v, 'ю', 'yu', 'g');
  v := regexp_replace(v, 'я', 'ya', 'g');

  -- 2) qolgan bitta-harfli kirill -> lotin (asosiy jadval).
  --    'ъ'/'ь' (yumshoq/qattiq belgi) 'to' da yo'q -> translate() ularni
  --    OLIB TASHLAYDI (pozitsiyasi 'to' uzunligidan oshib ketgan harflar
  --    o'chiriladi — shuning uchun ular 'from' oxirida turibdi).
  v := translate(v, 'абвгдезийклмнопрстуфыэъь', 'abvgdeziyklmnoprstufye');

  -- 3) showroom sinonimlari bittaga birlashtiriladi
  v := regexp_replace(v, 'shourum|shourom|shou room', 'showroom', 'gi');

  -- 4) "kassa" so'zini (butun so'z sifatida) olib tashlash
  v := regexp_replace(v, '\ykassa\y', '', 'gi');

  -- 5) ko'p probelni bittaga siqish + old/orqa probel
  v := regexp_replace(v, '\s+', ' ', 'g');
  v := btrim(v);

  return nullif(v, '');
end $fn$;

revoke all on function nom_norm(text) from public, anon;
grant execute on function nom_norm(text) to authenticated, service_role;

comment on function nom_norm(text) is
  'Filial/branch nomini solishtirish uchun normallashtiradi: pastki registr, probel siqish, '
  'kirill->lotin (asosiy jadval), showroom sinonimlari, "kassa" so''zi olib tashlanadi.';


create table if not exists staff_branch_map (
  branch_id       int         primary key,
  branch_nomi     text,
  provodka_filial text,
  manba           text        not null default 'avto' check (manba in ('avto','qolda')),
  updated_at      timestamptz not null default now(),
  updated_by      text
);

comment on table staff_branch_map is
  'aros_staff.branch_id -> Provodka filial nomi (accounts.subtitle dagi filial qismi, AYNAN). '
  'manba=avto -> aros_staff_sync avtomatik to''ldiradi; manba=qolda -> admin qo''lda belgilagan, sinxron tegmaydi.';

alter table staff_branch_map enable row level security;

drop policy if exists staff_branch_map_sel on staff_branch_map;
create policy staff_branch_map_sel on staff_branch_map
  for select to authenticated using (true);

revoke all on staff_branch_map from public, anon;
grant select on staff_branch_map to authenticated;


-- ---------------------------------------------------------------------
-- 2.1 staff_branch_map_set(branch_id, filial) — ADMIN only
--     p_filial = null -> avto holatga qaytarish (qayta hisoblanadi).
-- ---------------------------------------------------------------------
create or replace function staff_branch_map_set(p_branch_id int, p_filial text)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_bnom  text;
  v_match text;
begin
  if not is_admin() then
    raise exception 'Faqat admin filial moslashtirishini o''zgartira oladi' using errcode = '42501';
  end if;
  if p_branch_id is null then
    raise exception 'branch_id kerak' using errcode = '22000';
  end if;

  select branch_nomi into v_bnom from staff_branch_map where branch_id = p_branch_id;
  if v_bnom is null then
    select branch_nomi into v_bnom from aros_staff where branch_id = p_branch_id limit 1;
  end if;

  if nullif(btrim(coalesce(p_filial, '')), '') is null then
    select split_part(a.subtitle, ' · ', 1) into v_match
      from accounts a
     where a.kassa_turi = 'xarajat'
       and coalesce(a.is_active, true)
       and nom_norm(split_part(a.subtitle, ' · ', 1)) = nom_norm(v_bnom)
     order by a.name
     limit 1;

    insert into staff_branch_map (branch_id, branch_nomi, provodka_filial, manba, updated_at, updated_by)
    values (p_branch_id, v_bnom, v_match, 'avto', now(), auth.uid()::text)
    on conflict (branch_id) do update
       set provodka_filial = excluded.provodka_filial,
           manba           = 'avto',
           branch_nomi     = coalesce(staff_branch_map.branch_nomi, excluded.branch_nomi),
           updated_at      = now(),
           updated_by      = excluded.updated_by;
  else
    insert into staff_branch_map (branch_id, branch_nomi, provodka_filial, manba, updated_at, updated_by)
    values (p_branch_id, v_bnom, btrim(p_filial), 'qolda', now(), auth.uid()::text)
    on conflict (branch_id) do update
       set provodka_filial = excluded.provodka_filial,
           manba           = 'qolda',
           branch_nomi     = coalesce(staff_branch_map.branch_nomi, excluded.branch_nomi),
           updated_at      = now(),
           updated_by      = excluded.updated_by;
  end if;
end $fn$;

revoke all on function staff_branch_map_set(int, text) from public, anon;
grant execute on function staff_branch_map_set(int, text) to authenticated;

comment on function staff_branch_map_set(int, text) is
  'Admin: branch_id -> Provodka filial nomini qo''lda belgilaydi (manba=qolda). p_filial null -> avto holatga qaytaradi.';


-- ---------------------------------------------------------------------
-- 2.2 staff_branch_map_royxat() — sozlama UI uchun (joriy + tavsiya)
-- ---------------------------------------------------------------------
create or replace function staff_branch_map_royxat()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.branch_nomi nulls last), '[]'::jsonb)
  from (
    select m.branch_id,
           m.branch_nomi,
           m.provodka_filial as mos_filial,
           m.manba,
           (select split_part(a.subtitle, ' · ', 1)
              from accounts a
             where a.kassa_turi = 'xarajat'
               and coalesce(a.is_active, true)
               and nom_norm(split_part(a.subtitle, ' · ', 1)) = nom_norm(m.branch_nomi)
             order by a.name
             limit 1) as tavsiya
      from staff_branch_map m
  ) x;
$fn$;

revoke all on function staff_branch_map_royxat() from public, anon;
grant execute on function staff_branch_map_royxat() to authenticated;

comment on function staff_branch_map_royxat() is
  'Sozlama UI: har branch uchun joriy moslama (mos_filial) va avto tavsiya (tavsiya, qayta hisoblangan).';


-- #####################################################################
-- ##  3-BO'LIM — provodka_config narxlari + getter/setter            ##
-- #####################################################################

insert into provodka_config (key, val)
values ('ovqat_obed_narx', '30000')
on conflict (key) do nothing;

insert into provodka_config (key, val)
values ('ovqat_zavtrak_narx', '7000')
on conflict (key) do nothing;


create or replace function ovqat_narxlar()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select jsonb_build_object(
    'obed',    coalesce((select nullif(val, '')::numeric from provodka_config where key = 'ovqat_obed_narx'), 30000),
    'zavtrak', coalesce((select nullif(val, '')::numeric from provodka_config where key = 'ovqat_zavtrak_narx'), 7000)
  );
$fn$;

revoke all on function ovqat_narxlar() from public, anon;
grant execute on function ovqat_narxlar() to authenticated;

comment on function ovqat_narxlar() is
  'Ovqat narxlari (obed/zavtrak), provodka_config dan. Topilmasa 30000/7000 (sukut).';


create or replace function set_ovqat_narx(p_tur text, p_narx numeric)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare v_key text;
begin
  if not is_admin() then
    raise exception 'Faqat admin ovqat narxini o''zgartira oladi' using errcode = '42501';
  end if;
  if p_narx is null or p_narx <= 0 then
    raise exception 'Narx musbat bo''lishi kerak' using errcode = '22000';
  end if;
  if p_tur = 'obed' then
    v_key := 'ovqat_obed_narx';
  elsif p_tur = 'zavtrak' then
    v_key := 'ovqat_zavtrak_narx';
  else
    raise exception 'Nomalum tur (obed|zavtrak kerak)' using errcode = '22000';
  end if;

  insert into provodka_config (key, val, updated_by, updated_at)
  values (v_key, p_narx::text, coalesce(auth.uid()::text, 'admin'), now())
  on conflict (key) do update
     set val = excluded.val, updated_by = excluded.updated_by, updated_at = now();
end $fn$;

revoke all on function set_ovqat_narx(text, numeric) from public, anon;
grant execute on function set_ovqat_narx(text, numeric) to authenticated;

comment on function set_ovqat_narx(text, numeric) is
  'Admin: obed/zavtrak narxini o''zgartiradi (provodka_config).';


-- #####################################################################
-- ##  4-BO'LIM — accounts.ovqat_modda + set_modda_flag('ovqat')      ##
-- #####################################################################

alter table accounts
  add column if not exists ovqat_modda boolean not null default false;

comment on column accounts.ovqat_modda is
  'Xarajat moddasi: ovqat (obed/zavtrak) moddasimi. true bo''lsa entry_line ga faqat '
  'xarajat_saqlash_ovqat() orqali (hodim ro''yxati bilan) yozish mumkin — 8-BO''LIM to''sig''i.';

-- 🔴 IMZO O'ZGARMAYDI (uuid, text, boolean) — PROVODKA_JURNAL_V2.sql dagi
--    eng oxirgi versiya + 'ovqat' shoxi qo'shildi. Eski 4 shox AYNAN saqlandi.
create or replace function set_modda_flag(p_account uuid, p_flag text, p_bool boolean)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not is_admin() then
    raise exception 'Faqat admin' using errcode = '42501';
  end if;
  if p_flag = 'chek' then
    update accounts set chek_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'izoh' then
    update accounts set izoh_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'davr' then
    update accounts set davr_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'filial' then
    update accounts set filial_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'ovqat' then
    update accounts set ovqat_modda = coalesce(p_bool, false) where id = p_account;
  else
    raise exception 'Nomalum bayroq';
  end if;
end $fn$;

revoke all on function set_modda_flag(uuid, text, boolean) from public, anon;
grant execute on function set_modda_flag(uuid, text, boolean) to authenticated;

comment on function set_modda_flag(uuid, text, boolean) is
  'Admin: xarajat moddasi bayrogi (chek|izoh|davr|filial|ovqat) yoqadi yoki ochiradi.';


-- #####################################################################
-- ##  5-BO'LIM — entry_ovqat + is_deleted ko'zgu trigger             ##
-- #####################################################################

create table if not exists entry_ovqat (
  id         uuid        primary key default gen_random_uuid(),
  entry_id   uuid        not null references entry(id) on delete cascade,
  staff_id   int         not null references aros_staff(staff_id),
  staff_nom  text        not null,
  tur        text        not null check (tur in ('obed', 'zavtrak')),
  narx       numeric     not null check (narx > 0),
  kun        date        not null,
  is_deleted boolean     not null default false,
  created_at timestamptz not null default now()
);

comment on table entry_ovqat is
  'Ovqat (obed/zavtrak) yozuvining hodim satrlari. Yozish faqat xarajat_saqlash_ovqat() orqali. '
  'is_deleted entry.is_deleted bilan ko''zgu qilinadi (trg_entry_ovqat_mirror).';

-- 🔴 Takror himoyasi: bir hodim + kun + tur — kuniga FAQAT bir marta
--    (o'chirilmagan qatorlar orasida).
create unique index if not exists entry_ovqat_uniq
  on entry_ovqat (staff_id, kun, tur)
  where not is_deleted;

create index if not exists entry_ovqat_entry_idx on entry_ovqat (entry_id);

alter table entry_ovqat enable row level security;

drop policy if exists entry_ovqat_sel on entry_ovqat;
create policy entry_ovqat_sel on entry_ovqat
  for select to authenticated using (true);

-- 🔴 insert/update/delete policy YO'Q — faqat xarajat_saqlash_ovqat() /
--    trg_entry_ovqat_mirror (ikkalasi ham security definer, table owner).
revoke all on entry_ovqat from public, anon;
grant select on entry_ovqat to authenticated;


-- ---------------------------------------------------------------------
-- 5.1 entry.is_deleted -> entry_ovqat.is_deleted ko'zgu
-- ---------------------------------------------------------------------
create or replace function entry_ovqat_mirror()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if new.is_deleted is distinct from old.is_deleted then
    if new.is_deleted then
      update entry_ovqat set is_deleted = true
       where entry_id = new.id and not is_deleted;
    else
      begin
        update entry_ovqat set is_deleted = false
         where entry_id = new.id and is_deleted;
      exception when unique_violation then
        raise exception 'Ovqat yozuvini tiklab bo''lmadi — shu kun/tur uchun boshqa yozuv allaqachon mavjud'
          using errcode = '23505';
      end;
    end if;
  end if;
  return new;
end $fn$;

revoke all on function entry_ovqat_mirror() from public, anon;

drop trigger if exists trg_entry_ovqat_mirror on entry;
create trigger trg_entry_ovqat_mirror
  after update of is_deleted on entry
  for each row execute function entry_ovqat_mirror();

comment on function entry_ovqat_mirror() is
  'entry.is_deleted o''zgarsa mos entry_ovqat qatorlarini ko''zguday takrorlaydi (kun bo''shashi/band bo''lishi).';


-- #####################################################################
-- ##  6-BO'LIM — ovqat_bugun(kun, staff[]) — oldindan tekshiruv      ##
-- #####################################################################

create or replace function ovqat_bugun(p_kun date, p_staff int[] default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.soat), '[]'::jsonb)
  from (
    select eo.staff_id,
           eo.tur,
           to_char(eo.created_at at time zone 'Asia/Tashkent', 'HH24:MI') as soat,
           ovqat_kiritgan((to_jsonb(e) ->> 'created_by')) as kiritgan,
           eo.entry_id
      from entry_ovqat eo
      join entry e on e.id = eo.entry_id
     where eo.kun = p_kun
       and not eo.is_deleted
       and e.status = 'posted'
       and e.is_deleted = false
       and (p_staff is null or eo.staff_id = any(p_staff))
  ) x;
$fn$;

revoke all on function ovqat_bugun(date, int[]) from public, anon;
grant execute on function ovqat_bugun(date, int[]) to authenticated;

comment on function ovqat_bugun(date, int[]) is
  'Shu kun uchun kim obed/zavtrak olgani (oldindan tekshiruv uchun UI chaqiradi). p_staff null -> hammasi.';


-- #####################################################################
-- ##  7-BO'LIM — xarajat_saqlash_ovqat(jsonb)  ASOSIY YOZISH RPC     ##
-- #####################################################################
-- p_data: { dt_account uuid (ovqat_modda=true modda), kt_account uuid (kassa,
--           currency UZS), summa numeric, description text, ext_ref text,
--           filial_ids uuid[], davr_start date, davr_end date, entry_date date,
--           kun date (sukut - bugun Toshkent),
--           royxat: [{staff_id int, tur 'obed'|'zavtrak'}, ...] }
--
-- Tekshiruvlar (hammasi FAIL-CLOSED, aniq xabar + errcode):
--   * dt_account.ovqat_modda = true bo'lishi SHART.
--   * kt_account currency = UZS (coalesce) bo'lishi SHART (v1 valyuta yo'q).
--   * royxat bo'sh emas; har element staff mavjud + is_active.
--   * bitta so'rov ichida bir hodim bir turda ikki marta bo'lsa -> xato.
--   * narx KLIENTDAN OLINMAYDI — provodka_config'dan (ovqat_narxlar()).
--   * Σ narx AYNAN summa ga teng bo'lishi SHART (kam ham, ko'p ham xato).
--   * shu kun/staff/tur allaqachon yozilgan bo'lsa -> aniq xabar (ism + soat + kim).
--   * ext_ref (bo'lsa) takror -> 23505, "allaqachon saqlangan".
-- Yozish ATOMIK: entry + 2 entry_line (Dt modda / Kt kassa) + entry_ovqat
-- qatorlari — funksiya BITTA implicit tranzaksiya (plpgsql exception bloki
-- butun tanani o'raydi), xato bo'lsa HECH NARSA yozilmaydi.
-- ---------------------------------------------------------------------
create or replace function xarajat_saqlash_ovqat(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_dt         uuid := nullif(p_data->>'dt_account', '')::uuid;
  v_kt         uuid := nullif(p_data->>'kt_account', '')::uuid;
  v_summa      numeric := nullif(p_data->>'summa', '')::numeric;
  v_ext        text := nullif(trim(p_data->>'ext_ref'), '');
  v_kun        date := coalesce(nullif(p_data->>'kun', '')::date,
                                 (now() at time zone 'Asia/Tashkent')::date);
  v_entry_date date := coalesce(nullif(p_data->>'entry_date', '')::date, v_kun);

  v_dt_ovqat   boolean;
  v_kt_cur     text;

  it           jsonb;
  v_n          int;
  v_i          int := 0;
  v_staff      int;
  v_tur        text;
  v_narx_obed    numeric;
  v_narx_zavtrak numeric;
  v_narx       numeric;
  v_royxat_summa numeric := 0;

  v_seen_keys  text[] := '{}';
  v_key        text;

  v_staff_ids  int[]    := '{}';
  v_turs       text[]   := '{}';
  v_narxs      numeric[]:= '{}';
  v_snoms      text[]   := '{}';
  v_name_seen  int[]    := '{}';
  v_names      text[]   := '{}';

  v_snom       text;
  v_active     boolean;
  v_cnt_obed   int := 0;
  v_cnt_zavtrak int := 0;

  v_dup_soat   text;
  v_dup_kim    text;
  v_dup_entry  uuid;

  v_entry      uuid;
  v_con        text;
  v_det        text;
  j            int;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_dt is null or v_kt is null then
    raise exception 'Modda (Dt) va kassa (Kt) tanlanishi shart' using errcode = '22000';
  end if;
  if v_summa is null or v_summa <= 0 then
    raise exception 'Summa musbat bo''lishi kerak' using errcode = '22000';
  end if;
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bo''lishi kerak' using errcode = '22000';
  end if;
  if p_data->'royxat' is null or jsonb_typeof(p_data->'royxat') <> 'array'
     or jsonb_array_length(p_data->'royxat') = 0 then
    raise exception 'Hodim ro''yxati bo''sh' using errcode = '22000';
  end if;

  select ovqat_modda into v_dt_ovqat from accounts where id = v_dt;
  if not coalesce(v_dt_ovqat, false) then
    raise exception 'Tanlangan modda ovqat moddasi emas (admin uni Sozlamada belgilashi kerak)'
      using errcode = '22000';
  end if;

  select coalesce(currency, 'UZS') into v_kt_cur from accounts where id = v_kt;
  if v_kt_cur is null then
    raise exception 'Kassa topilmadi' using errcode = '22000';
  end if;
  if v_kt_cur <> 'UZS' then
    raise exception 'Ovqat faqat so''m kassasidan yoziladi (valyuta kassasi v1 da qo''llab-quvvatlanmaydi)'
      using errcode = '22000';
  end if;

  select obed, zavtrak into v_narx_obed, v_narx_zavtrak
    from jsonb_to_record(ovqat_narxlar()) as t(obed numeric, zavtrak numeric);

  v_n := jsonb_array_length(p_data->'royxat');

  -- ---- 1-O'TISH: FAQAT TEKSHIRUV (hech narsa yozilmaydi) --------------
  for j in 0 .. v_n - 1 loop
    v_i := v_i + 1;
    it := p_data->'royxat'->j;
    v_staff := nullif(it->>'staff_id', '')::int;
    v_tur   := nullif(it->>'tur', '');

    if v_staff is null then
      raise exception 'Ro''yxatdagi %-satrda staff_id ko''rsatilmagan', v_i using errcode = '22000';
    end if;
    if v_tur is null or v_tur not in ('obed', 'zavtrak') then
      raise exception 'Ro''yxatdagi %-satrda tur noto''g''ri (obed|zavtrak kerak)', v_i using errcode = '22000';
    end if;

    v_key := v_staff::text || ':' || v_tur;
    if v_key = any(v_seen_keys) then
      select coalesce(nullif(btrim(toliq_nom), ''), btrim(coalesce(ism, '') || ' ' || coalesce(familiya, '')))
        into v_snom from aros_staff where staff_id = v_staff;
      raise exception '% uchun % ro''yxatda ikki marta ko''rsatilgan', coalesce(nullif(v_snom, ''), v_staff::text), v_tur
        using errcode = '22000';
    end if;
    v_seen_keys := v_seen_keys || v_key;

    select coalesce(nullif(btrim(toliq_nom), ''), btrim(coalesce(ism, '') || ' ' || coalesce(familiya, ''))),
           is_active
      into v_snom, v_active
      from aros_staff
     where staff_id = v_staff;

    if v_snom is null then
      raise exception 'Xodim topilmadi (staff_id=%)', v_staff using errcode = '22000';
    end if;
    if not coalesce(v_active, false) then
      raise exception '% faol emas, ovqat yozib bo''lmaydi', v_snom using errcode = '22000';
    end if;

    -- Bazada shu kun/staff/tur allaqachon bormi?
    select to_char(eo.created_at at time zone 'Asia/Tashkent', 'HH24:MI'),
           ovqat_kiritgan((to_jsonb(e) ->> 'created_by')),
           eo.entry_id
      into v_dup_soat, v_dup_kim, v_dup_entry
      from entry_ovqat eo
      join entry e on e.id = eo.entry_id
     where eo.staff_id = v_staff and eo.kun = v_kun and eo.tur = v_tur and not eo.is_deleted
     limit 1;

    if v_dup_entry is not null then
      raise exception '% bugun % olgan (%, %)', v_snom, v_tur, coalesce(v_dup_soat, '?'), coalesce(v_dup_kim, 'Noma''lum')
        using errcode = 'P0001';
    end if;

    v_narx := case v_tur when 'obed' then v_narx_obed else v_narx_zavtrak end;
    v_royxat_summa := v_royxat_summa + v_narx;

    v_staff_ids := v_staff_ids || v_staff;
    v_turs      := v_turs || v_tur;
    v_narxs     := v_narxs || v_narx;
    v_snoms     := v_snoms || v_snom;

    if v_tur = 'obed' then v_cnt_obed := v_cnt_obed + 1; else v_cnt_zavtrak := v_cnt_zavtrak + 1; end if;
    if not (v_staff = any(v_name_seen)) then
      v_name_seen := v_name_seen || v_staff;
      v_names := v_names || v_snom;
    end if;
  end loop;

  -- 🔴 Summa AYNAN mos bo'lishi shart (kam ham, ko'p ham xato).
  if v_royxat_summa <> v_summa then
    raise exception 'Summa ro''yxatga mos emas: ro''yxat %, yozilgan %', v_royxat_summa::text, v_summa::text
      using errcode = 'P0001';
  end if;

  -- ---- 2-O'TISH: YOZISH ------------------------------------------------
  -- 🔴 status/source KLIENTDAN OLINMAYDI (fail-closed — tester topilmasi):
  --    status='draft' kelsa pul yozilmay entry_ovqat unique slot abadiy
  --    band bo'lib qolardi (ovqat_bugun'da jim yo'qolgan slot). Shuning
  --    uchun ikkalasi ham QATTIQ literal: har doim 'posted' / 'manual'.
  -- 🔴 `created_by` INSERT ro'yxatida YO'Q — `xarajat_saqlash_taqsim`
  --    (PROVODKA_TOSIQ_OCHIR.sql) bilan AYNAN bir xil naqsh: ustun turi
  --    (`entry.created_by`) bazada noma'lum (PROVODKA_IJROCHI.sql:12-35),
  --    `auth.uid()` (uuid) ni to'g'ridan yozish text ustunda cast xatosi
  --    berishi mumkin. `trg_entry_ijrochi` (BEFORE INSERT, PROVODKA_IJROCHI.sql)
  --    `created_by is null` bo'lganda `jsonb_populate_record` bilan (turga
  --    bog'liq bo'lmagan usulda) avtomat to'ldiradi.
  insert into entry (entry_date, description, source, status, filial_ids,
                     davr_start, davr_end, ext_ref)
  values (
    v_entry_date,
    coalesce(nullif(p_data->>'description', ''),
             'Ovqat: ' || v_cnt_obed || ' obed, ' || v_cnt_zavtrak || ' zavtrak — ' || array_to_string(v_names, ', ')),
    'manual',
    'posted',
    case when jsonb_typeof(p_data->'filial_ids') = 'array'
         then coalesce((select array_agg(t.val::uuid) from jsonb_array_elements_text(p_data->'filial_ids') as t(val)),
                       '{}'::uuid[])
         else '{}'::uuid[] end,
    nullif(p_data->>'davr_start', '')::date,
    nullif(p_data->>'davr_end', '')::date,
    v_ext
  )
  returning id into v_entry;

  insert into entry_line (entry_id, account_id, debit, credit)
  values (v_entry, v_dt, v_summa, 0),
         (v_entry, v_kt, 0, v_summa);

  for v_i in 1 .. v_n loop
    insert into entry_ovqat (entry_id, staff_id, staff_nom, tur, narx, kun)
    values (v_entry, v_staff_ids[v_i], v_snoms[v_i], v_turs[v_i], v_narxs[v_i], v_kun);
  end loop;

  return jsonb_build_object('entry_id', v_entry, 'summa', v_royxat_summa, 'royxat_soni', v_n);

exception
  when unique_violation then
    get stacked diagnostics v_con = constraint_name, v_det = pg_exception_detail;
    if coalesce(v_con, '') ilike '%entry_ovqat%' or coalesce(v_det, '') ilike '%entry_ovqat%' then
      raise exception 'Shu kun uchun bu hodimga bu ovqat turi boshqa foydalanuvchi tomonidan bir vaqtda yozildi — sahifani yangilang'
        using errcode = 'P0001';
    end if;
    if v_ext is null then
      raise;                                   -- bizning to'siq emas
    end if;
    if coalesce(v_con, '') not ilike '%ext_ref%' and coalesce(v_det, '') not ilike '%ext_ref%' then
      raise;
    end if;
    raise exception 'Bu xarajat allaqachon saqlangan (takroriy yuborish to''sildi)'
      using errcode = '23505';
end $fn$;

revoke all on function xarajat_saqlash_ovqat(jsonb) from public, anon;
grant execute on function xarajat_saqlash_ovqat(jsonb) to authenticated;

comment on function xarajat_saqlash_ovqat(jsonb) is
  'Ovqat (obed/zavtrak) xarajatini hodim ro''yxati bilan atomik yozadi. Narx serverdan (ovqat_narxlar()), '
  'summa ro''yxatga AYNAN teng bo''lishi shart, kuniga bir hodim/tur bir marta. Tahrirlash taqiq (8-BO''LIM).';


-- #####################################################################
-- ##  8-BO'LIM — entry_line: aylanib o'tish to'sig'i + tahrir taqiqi  ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 8.1 ovqat_line_guard() — DEFERRED constraint trigger.
--     Ovqat moddasiga (ovqat_modda=true) yozilgan Dt qatorlari yig'indisi
--     entry_ovqat.narx yig'indisiga (shu entry, o'chirilmagan) TENG
--     bo'lishi shart — aks holda entry_line to'g'ridan-to'g'ri (professional/
--     provodka/jurnal tahriri) yozilgan, xarajat_saqlash_ovqat() dan emas.
--     DEFERRED bo'lgani uchun tekshiruv COMMIT paytida: xarajat_saqlash_ovqat()
--     ichida entry_line insert entry_ovqat insertdan OLDIN bo'lsa ham
--     muammo yo'q — ikkalasi ham commit vaqtida allaqachon bor.
--     n8n/service_role HAM to'siladi (auth.uid() bo'yicha bo'shashtirilmaydi) —
--     avtomat sinxron ovqat moddasiga umuman yozmasligi kerak.
-- ---------------------------------------------------------------------
create or replace function ovqat_line_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_debit_sum numeric;
  v_narx_sum  numeric;
begin
  if not exists (
    select 1 from entry_line el
      join accounts a on a.id = el.account_id
     where el.entry_id = new.entry_id and a.ovqat_modda = true
  ) then
    return new;
  end if;

  select coalesce(sum(el.debit), 0) into v_debit_sum
    from entry_line el
    join accounts a on a.id = el.account_id
   where el.entry_id = new.entry_id and a.ovqat_modda = true;

  select coalesce(sum(eo.narx), 0) into v_narx_sum
    from entry_ovqat eo
   where eo.entry_id = new.entry_id and not eo.is_deleted;

  if v_debit_sum <> v_narx_sum then
    raise exception 'Ovqat moddasiga faqat hodim ro''yxati bilan yozish mumkin (Xarajat sahifasi)'
      using errcode = 'P0001';
  end if;
  return new;
end $fn$;

revoke all on function ovqat_line_guard() from public, anon;

drop trigger if exists trg_ovqat_line_guard on entry_line;
create constraint trigger trg_ovqat_line_guard
  after insert or update on entry_line
  deferrable initially deferred
  for each row execute function ovqat_line_guard();

comment on function ovqat_line_guard() is
  'DEFERRED: ovqat_modda hisobiga yozilgan Dt yig''indisi entry_ovqat.narx yig''indisiga teng bo''lishi shart. '
  'To''g''ridan-to''g''ri (xarajat_saqlash_ovqat() dan tashqari) yozishni to''sadi.';


-- ---------------------------------------------------------------------
-- 8.2 entry_ovqat_edit_guard() — ovqat yozuvining entry_line'ini
--     TAHRIRLASH taqiq (admin ham). O'chirish (entry.is_deleted) erkin —
--     u 5.1 dagi ko'zgu bilan boshqariladi. entry.description/entry_date
--     tahriri BU TRIGGERGA TEGISHLI EMAS (entry ustida, entry_line emas).
-- ---------------------------------------------------------------------
create or replace function entry_ovqat_edit_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if (new.debit is distinct from old.debit)
     or (new.credit is distinct from old.credit)
     or (new.account_id is distinct from old.account_id) then
    if exists (select 1 from entry_ovqat where entry_id = old.entry_id and not is_deleted) then
      raise exception 'Ovqat yozuvi tahrirlanmaydi — o''chirib qayta yozing' using errcode = '42501';
    end if;
  end if;
  return new;
end $fn$;

revoke all on function entry_ovqat_edit_guard() from public, anon;

drop trigger if exists trg_entry_ovqat_edit_guard on entry_line;
create trigger trg_entry_ovqat_edit_guard
  before update on entry_line
  for each row execute function entry_ovqat_edit_guard();

comment on function entry_ovqat_edit_guard() is
  'Ovqat yozuvi (entry_ovqat bor) entry_line ini debit/credit/account_id bo''yicha tahrirlashni to''sadi. Admin ham.';


-- #####################################################################
-- ##  9-BO'LIM — v_ovqat_hisobot                                     ##
-- #####################################################################

create or replace view v_ovqat_hisobot
with (security_invoker = on) as
  select eo.id,
         eo.staff_id,
         eo.staff_nom,
         eo.tur,
         eo.narx,
         eo.kun,
         e.id as entry_id,
         e.description,
         ovqat_kiritgan((to_jsonb(e) ->> 'created_by')) as kiritgan,
         eo.created_at
    from entry_ovqat eo
    join entry e on e.id = eo.entry_id
   where not eo.is_deleted
     and e.status = 'posted'
     and e.is_deleted = false;

comment on view v_ovqat_hisobot is
  'Ovqat hisoboti: hodim x kun x tur, kim yozgani, summa (posted, o''chirilmagan). Keyingi bosqich UI uchun.';

revoke all on v_ovqat_hisobot from public, anon;
grant select on v_ovqat_hisobot to authenticated;


-- #####################################################################
-- ##  10-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)           ##
-- #####################################################################

-- 1) Jadval/ustunlar bormi
select to_regclass('public.aros_staff')          is not null as aros_staff_ok,
       to_regclass('public.staff_branch_map')    is not null as staff_branch_map_ok,
       to_regclass('public.entry_ovqat')         is not null as entry_ovqat_ok,
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'accounts'
                  and column_name = 'ovqat_modda')                          as ovqat_modda_ok,
       exists (select 1 from pg_indexes
                where schemaname = 'public' and tablename = 'entry_ovqat'
                  and indexname = 'entry_ovqat_uniq')                       as entry_ovqat_uniq_ok;

-- 2) Funksiyalar bormi
select to_regprocedure('public.ovqat_kiritgan(text)')                        is not null as ovqat_kiritgan_ok,
       to_regprocedure('public.nom_norm(text)')                              is not null as nom_norm_ok,
       to_regprocedure('public.aros_staff_sync(jsonb)')                      is not null as aros_staff_sync_ok,
       to_regprocedure('public.staff_branch_map_set(int,text)')              is not null as staff_branch_map_set_ok,
       to_regprocedure('public.staff_branch_map_royxat()')                   is not null as staff_branch_map_royxat_ok,
       to_regprocedure('public.ovqat_narxlar()')                             is not null as ovqat_narxlar_ok,
       to_regprocedure('public.set_ovqat_narx(text,numeric)')                is not null as set_ovqat_narx_ok,
       to_regprocedure('public.set_modda_flag(uuid,text,boolean)')           is not null as set_modda_flag_ok,
       to_regprocedure('public.ovqat_bugun(date,int[])')                     is not null as ovqat_bugun_ok,
       to_regprocedure('public.xarajat_saqlash_ovqat(jsonb)')                is not null as xarajat_saqlash_ovqat_ok,
       to_regprocedure('public.ovqat_line_guard()')                         is not null as ovqat_line_guard_ok,
       to_regprocedure('public.entry_ovqat_edit_guard()')                    is not null as entry_ovqat_edit_guard_ok,
       to_regprocedure('public.entry_ovqat_mirror()')                        is not null as entry_ovqat_mirror_ok,
       to_regclass('public.v_ovqat_hisobot')                                 is not null as v_ovqat_hisobot_ok;

-- 3) Triggerlar bormi (aynan nomi bilan)
select exists (select 1 from pg_trigger where tgname = 'trg_entry_ovqat_mirror')      as trg_mirror_ok,
       exists (select 1 from pg_trigger where tgname = 'trg_ovqat_line_guard')        as trg_line_guard_ok,
       exists (select 1 from pg_trigger where tgname = 'trg_entry_ovqat_edit_guard')  as trg_edit_guard_ok,
       -- eski server guard TEGILMAGAN
       exists (select 1 from pg_trigger where tgname = 'trg_perm_guard_entry_line')   as eski_perm_guard_saqlandi;

-- 4) Grant/ruxsat sanity (authenticated ICHKI RPC larga CHAQIRA OLMASLIGI kerak -> false)
select has_function_privilege('authenticated', 'public.aros_staff_sync(jsonb)', 'execute')  as staff_sync_authenticated_BULMASIN,
       has_function_privilege('service_role', 'public.aros_staff_sync(jsonb)', 'execute')   as staff_sync_service_role_ochiq,
       has_function_privilege('authenticated', 'public.xarajat_saqlash_ovqat(jsonb)', 'execute') as ovqat_yoz_ochiq,
       has_function_privilege('authenticated', 'public.ovqat_bugun(date,int[])', 'execute')      as ovqat_bugun_ochiq;

-- 5) Config qatorlari borligini tekshirish
select key, val from provodka_config where key in ('ovqat_obed_narx', 'ovqat_zavtrak_narx');

-- Sxema keshi — busiz yangi RPC 404 beradi.
notify pgrst, 'reload schema';
