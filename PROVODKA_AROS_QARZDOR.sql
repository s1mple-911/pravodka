-- =====================================================================
--  PROVODKA_AROS_QARZDOR.sql — Aros mijoz qarzlari (debtors-list) REGISTRI
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--  Brief: ARX_PROVODKA_AROS_QARZDOR.md (1..4-BO'LIM, 2026-09-07).
--
--  #####  NIMA UCHUN  ####################################################
--
--  `qarzdor-dev.html` "Bizdan qarzdor" segmentida hozir faqat QO'LDA
--  berilgan qarzlar (mavjud `qarz` tizimi, PROVODKA_QARZ.sql) bor. Endi
--  yoniga Aros'dagi MIJOZ qarzlari (tovar sotib olib to'lamagan pul)
--  qo'shiladi — manba `v3/report/debtors-list` (n8n orqali, 30 daqiqada).
--
--  #####  🔴 PUL HARAKATI YO'Q  ###########################################
--
--  Bu fayl `entry`/`entry_line`ga hech narsa yozmaydi — faqat REGISTR
--  (`aros_qarzdor`) + o'qish RPC'lari. 4010 daftar qoldig'i (Provodka
--  o'zining "Xaridorlar qarzi" hisobi) bilan ARALASHTIRILMAYDI — bu ikki
--  MUSTAQIL manba, birlashtirish faqat KO'RINISHDA (`qarz_umumiy_dash`).
--
--  #####  FAYL TARKIBI  ###################################################
--     0-BO'LIM — old shart tekshiruvi (faqat select/raise)
--     1-BO'LIM — jadval `aros_qarzdor` (+ indeks + RLS)
--     2-BO'LIM — jadval `aros_qarzdor_sync` (bitta qator, id=1) (+ RLS)
--     3-BO'LIM — `sync_aros_qarzdor(p_data)` — service_role ONLY (n8n)
--     4-BO'LIM — `aros_qarzdor_royxat(p)` — authenticated (jadval/filtr)
--     5-BO'LIM — `aros_qarzdor_dash()` — authenticated (Aros mijozlar tabi)
--     6-BO'LIM — `qarz_umumiy_dash()` — authenticated (Provodka + Aros)
--     7-BO'LIM — PostgREST sxema keshini yangilash
--     8-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/raise) — o'z-o'zini tekshiradi
--
--  #####  ADDITIVE KAFOLATI  ##############################################
--   * Hech narsa drop qilinmaydi, hech qanday mavjud jadval/ustun/funksiya
--     imzosi o'zgartirilmaydi. Hammasi YANGI, `aros_qarzdor`/`qarz_umumiy_`
--     prefiksi bilan. `qarz_dash()` FAQAT chaqiriladi (to_regprocedure
--     bilan tekshirib) — tanasi tegilmaydi.
--   * Idempotent: `create table if not exists`, `create or replace
--     function`, `drop policy if exists` + `create policy`, CHECK
--     constraint `if not exists (select ... from pg_constraint ...)`.
--   * Anonim `do` bloki YO'Q — har `do` bloki nomlangan teg bilan. Har
--     funksiya tanasi ham nomlangan teg bilan. Izohlarda ketma-ket dollar
--     belgi YOZILMAGAN (soxta blok xavfi — CLAUDE.md).
--
--  #####  RUXSAT  ##########################################################
--  Mavjud `qarz_page_ok()` (PROVODKA_QARZ.sql) qayta ishlatiladi — admin
--  YOKI `qarzdor` sahifasi ruxsati, kassa doirasi YO'Q (mijoz qarzi
--  kompaniya darajasida, eski #tab-kontr bilan bir xil qoida).
--
--  #####  TALAB (0-BO'LIM tekshiradi)  #####################################
--     qarz_page_ok()   — PROVODKA_QARZ.sql
--
--  🔴 SQL'ni ASILBEK o'zi RUN qiladi. Agent bajarmaydi.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI                                 ##
-- #####################################################################

do $qd_pre$
begin
  -- pg_proc orqali (to_regprocedure Supabase editorida 2026-09-07 da null berdi,
  -- funksiya bazada BOR edi — RPC true qaytargan).
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'qarz_page_ok'
                    and p.pronargs = 0) then
    raise exception 'qarz_page_ok() yoq — avval PROVODKA_QARZ.sql ni bajaring';
  end if;
end
$qd_pre$;


-- #####################################################################
-- ##  1-BO'LIM — jadval aros_qarzdor (+ indeks + RLS)                 ##
-- #####################################################################
-- Har qator — bitta Aros mijozi (debtors-list.user_id). `faol=false` —
-- so'nggi sinxronda ro'yxatda ko'rinmay qolgan (mijoz emas, o'chirilmaydi).

create table if not exists aros_qarzdor (
  user_id            int         primary key,
  ism                text        not null default '',
  familya            text        not null default '',
  telefon            text,
  rol                text,
  warehouse_id       int,
  warehouse_nom      text,
  wallet_status      text,
  wallet_balance     numeric(18,2) not null default 0,
  cashback_balance   numeric(18,2) not null default 0,
  total_debt         numeric(18,2) not null default 0,
  balance            numeric(18,2) not null default 0,
  clean_debt         numeric(18,2) not null default 0,
  debt_1_10          numeric(18,2) not null default 0,
  debt_11_20         numeric(18,2) not null default 0,
  debt_21_30         numeric(18,2) not null default 0,
  debt_31_45         numeric(18,2) not null default 0,
  debt_45_plus       numeric(18,2) not null default 0,
  total_outdated     numeric(18,2) not null default 0,
  -- Dashboard keshidan (n8n PG cache_debtors — Aros ga QAYTA sorov YOQ, 2026-09-07 Asilbek):
  debt_limit         numeric(18,2),
  debt_allowed_days  int,
  most_outdated_deadline date,
  -- cache_debtors da most_outdated_deadline SANA EMAS, KUN (eng eski kechikish, MOD) - 2026-09-07
  --    birinchi sinxronda 411 muddati otgan mijoz "invalid input syntax for type date" bilan tashlandi.
  most_outdated_kun  int,
  report_date        date,
  faol               boolean     not null default true,
  synced_at          timestamptz,
  created_at         timestamptz not null default now()
);

-- Additive: jadval avvalroq yaratilgan bazada ham ustunlar paydo bolsin.
alter table aros_qarzdor add column if not exists debt_limit             numeric(18,2);
alter table aros_qarzdor add column if not exists debt_allowed_days      int;
alter table aros_qarzdor add column if not exists most_outdated_deadline date;
alter table aros_qarzdor add column if not exists most_outdated_kun      int;

comment on table aros_qarzdor is
  'Aros mijoz qarzlari REGISTRI (v3/report/debtors-list, n8n "Aros Provodka - '
  'Aros Qarzdor Sync" har 30 daqiqada). PUL HARAKATI YO''Q — entry/entry_line ga '
  'hech narsa yozilmaydi. Provodka `qarzdor`/`qarz` jadvallaridan MUSTAQIL. '
  'faol=false — so''nggi sinxronda ro''yxatda ko''rinmay qolgan (o''chirilmaydi).';

create index if not exists idx_aros_qarzdor_total_debt     on aros_qarzdor (total_debt desc);
create index if not exists idx_aros_qarzdor_total_outdated on aros_qarzdor (total_outdated desc);
create index if not exists idx_aros_qarzdor_warehouse      on aros_qarzdor (warehouse_id);

alter table aros_qarzdor enable row level security;
revoke all on table aros_qarzdor from public, anon;
grant select on table aros_qarzdor to authenticated;

drop policy if exists aros_qarzdor_select on aros_qarzdor;
create policy aros_qarzdor_select on aros_qarzdor
  for select to authenticated
  using (qarz_page_ok());


-- #####################################################################
-- ##  2-BO'LIM — jadval aros_qarzdor_sync (bitta qator, id=1) + RLS   ##
-- #####################################################################

create table if not exists aros_qarzdor_sync (
  id             int         primary key default 1,
  summary        jsonb,
  soni           int,
  report_date    date,
  synced_at      timestamptz,
  davomiylik_ms  int,
  ogoh           text[]
);

do $qd_sync_ck$
begin
  if not exists (select 1 from pg_constraint where conname = 'aros_qarzdor_sync_id_ck') then
    alter table aros_qarzdor_sync
      add constraint aros_qarzdor_sync_id_ck check (id = 1);
  end if;
end
$qd_sync_ck$;

comment on table aros_qarzdor_sync is
  'Bitta qator (id=1) — Aros mijoz qarzlari sinxronining oxirgi holati: Aros '
  '"summary" xomligicha, qatorlar soni, hisobot sanasi, davomiyligi, ogohlantirishlar.';

alter table aros_qarzdor_sync enable row level security;
revoke all on table aros_qarzdor_sync from public, anon;
grant select on table aros_qarzdor_sync to authenticated;

drop policy if exists aros_qarzdor_sync_select on aros_qarzdor_sync;
create policy aros_qarzdor_sync_select on aros_qarzdor_sync
  for select to authenticated
  using (qarz_page_ok());


-- #####################################################################
-- ##  3-BO'LIM — sync_aros_qarzdor(p_data) — service_role ONLY (n8n)  ##
-- #####################################################################
-- Kirish: {report_date, summary:{...}, davomiylik_ms, ogoh:[...] (ixtiyoriy,
-- n8n darajasida hisoblangan ogohlantirishlar), rows:[{user_id, first_name,
-- last_name, username, role, warehouse_id, warehouse_name, wallet_status,
-- wallet_balance, cashback_balance, total_debt, balance, clean_debt,
-- debt_1_10, debt_11_20, debt_21_30, debt_31_45, debt_45_plus,
-- total_outdated_debts}]}.
-- 🔴 `rows` >= 100 bo'lsagina sweep (faol=true -> false payloadda yo'q
-- qatorlar uchun) — chala/bo'sh payload sweep QILMAYDI (YOLDA naqshi).
-- 🔴 Yaroqsiz/yo'q user_id -> qator TASHLANADI, butun sync yiqilmaydi.

create or replace function sync_aros_qarzdor(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $qd_sync$
declare
  v_role            text;
  v_rows            jsonb;
  v_el              jsonb;
  v_report_date     date;
  v_summary         jsonb;
  v_davomiylik      int;
  v_n8n_ogoh        jsonb;
  v_count           int;

  v_uid_txt         text;
  v_uid             int;
  v_ism             text;
  v_familya         text;
  v_telefon         text;
  v_rol             text;
  v_wh_id           int;
  v_wh_nom          text;
  v_wallet_status   text;
  v_wallet_balance  numeric;
  v_cashback        numeric;
  v_total_debt      numeric;
  v_balance         numeric;
  v_clean_debt      numeric;
  v_d1              numeric;
  v_d2              numeric;
  v_d3              numeric;
  v_d4              numeric;
  v_d5              numeric;
  v_outdated        numeric;
  v_limit           numeric;
  v_dad             int;
  v_mod             date;
  v_mod_txt         text;
  v_kun             int;

  v_ids_korilgan    int[] := '{}';
  n_yozildi         int := 0;
  n_yangilandi      int := 0;
  n_nofaol          int := 0;
  n_tashlandi       int := 0;
  v_was_insert      boolean;
  v_ogoh            text[] := '{}';
begin
  -- ---- service_role ONLY (admin_set_provodka_perms/sync_transfer_yolda bilan bir xil naqsh) ----
  if auth.uid() is not null then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is not null and v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('sync_aros_qarzdor'));

  if p_data is null or jsonb_typeof(p_data) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'error', 'p_data object kutilgan edi ({rows:[...], ...})');
  end if;

  v_rows := p_data -> 'rows';
  if jsonb_typeof(v_rows) is distinct from 'array' then
    return jsonb_build_object('ok', false,
      'error', 'rows massiv kutilgan edi, keldi: ' || coalesce(jsonb_typeof(v_rows), 'null'));
  end if;

  v_report_date := nullif(p_data ->> 'report_date', '')::date;
  v_summary     := p_data -> 'summary';
  v_davomiylik  := nullif(p_data ->> 'davomiylik_ms', '')::int;
  v_n8n_ogoh    := p_data -> 'ogoh';

  if jsonb_typeof(v_n8n_ogoh) = 'array' then
    select array_agg(x) into v_ogoh from jsonb_array_elements_text(v_n8n_ogoh) x;
    v_ogoh := coalesce(v_ogoh, '{}');
  end if;

  for v_el in select * from jsonb_array_elements(v_rows)
  loop
    begin
      v_uid_txt := nullif(btrim(coalesce(v_el ->> 'user_id', '')), '');
      if v_uid_txt is null or v_uid_txt !~ '^[0-9]+$' then
        n_tashlandi := n_tashlandi + 1;
        v_ogoh := array_append(v_ogoh, 'user_id yoq/notogri: ' || coalesce(v_el ->> 'user_id', 'null'));
        continue;
      end if;
      v_uid := v_uid_txt::int;
      v_ids_korilgan := array_append(v_ids_korilgan, v_uid);

      v_ism            := nullif(btrim(coalesce(v_el ->> 'first_name', '')), '');
      v_familya        := nullif(btrim(coalesce(v_el ->> 'last_name', '')), '');
      v_telefon        := nullif(btrim(coalesce(v_el ->> 'username', '')), '');
      v_rol            := nullif(btrim(coalesce(v_el ->> 'role', '')), '');
      v_wh_id          := nullif(v_el ->> 'warehouse_id', '')::int;
      v_wh_nom         := nullif(btrim(coalesce(v_el ->> 'warehouse_name', '')), '');
      v_wallet_status  := nullif(btrim(coalesce(v_el ->> 'wallet_status', '')), '');
      v_wallet_balance := nullif(v_el ->> 'wallet_balance', '')::numeric;
      v_cashback       := nullif(v_el ->> 'cashback_balance', '')::numeric;
      v_total_debt     := nullif(v_el ->> 'total_debt', '')::numeric;
      v_balance        := nullif(v_el ->> 'balance', '')::numeric;
      v_clean_debt     := nullif(v_el ->> 'clean_debt', '')::numeric;
      v_d1             := nullif(v_el ->> 'debt_1_10', '')::numeric;
      v_d2             := nullif(v_el ->> 'debt_11_20', '')::numeric;
      v_d3             := nullif(v_el ->> 'debt_21_30', '')::numeric;
      v_d4             := nullif(v_el ->> 'debt_31_45', '')::numeric;
      v_d5             := nullif(v_el ->> 'debt_45_plus', '')::numeric;
      v_outdated       := nullif(v_el ->> 'total_outdated_debts', '')::numeric;
      -- n8n "Birlashtir" dashboard keshidan (cache_debtors) qoshadi; yoq bolsa null -> eski qiymat qoladi
      v_limit          := nullif(v_el ->> 'debt_limit', '')::numeric;
      v_dad            := nullif(v_el ->> 'debt_allowed_days', '')::int;
      -- most_outdated_deadline: dashboard keshida KUN soni ("7", "155"), ehtimol sana ham kelishi mumkin
      v_mod_txt := nullif(btrim(coalesce(v_el ->> 'most_outdated_deadline', '')), '');
      v_mod := null; v_kun := null;
      if v_mod_txt ~ '^[0-9]+$' then
        v_kun := v_mod_txt::int;
      elsif v_mod_txt ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then
        v_mod := left(v_mod_txt, 10)::date;
      end if;
      if v_kun is null then
        v_kun := nullif(v_el ->> 'most_outdated_kun', '')::int;
      end if;

      insert into aros_qarzdor (
        user_id, ism, familya, telefon, rol, warehouse_id, warehouse_nom,
        wallet_status, wallet_balance, cashback_balance,
        total_debt, balance, clean_debt,
        debt_1_10, debt_11_20, debt_21_30, debt_31_45, debt_45_plus, total_outdated,
        debt_limit, debt_allowed_days, most_outdated_deadline, most_outdated_kun,
        report_date, faol, synced_at)
      values (
        v_uid, coalesce(v_ism, ''), coalesce(v_familya, ''), v_telefon, v_rol, v_wh_id, v_wh_nom,
        v_wallet_status, coalesce(v_wallet_balance, 0), coalesce(v_cashback, 0),
        coalesce(v_total_debt, 0), coalesce(v_balance, 0), coalesce(v_clean_debt, 0),
        coalesce(v_d1, 0), coalesce(v_d2, 0), coalesce(v_d3, 0), coalesce(v_d4, 0), coalesce(v_d5, 0),
        coalesce(v_outdated, 0), v_limit, v_dad, v_mod, v_kun, v_report_date, true, now())
      on conflict (user_id) do update
         set ism              = excluded.ism,
             familya          = excluded.familya,
             telefon          = excluded.telefon,
             rol              = excluded.rol,
             warehouse_id     = excluded.warehouse_id,
             warehouse_nom    = excluded.warehouse_nom,
             wallet_status    = excluded.wallet_status,
             wallet_balance   = excluded.wallet_balance,
             cashback_balance = excluded.cashback_balance,
             total_debt       = excluded.total_debt,
             balance          = excluded.balance,
             clean_debt       = excluded.clean_debt,
             debt_1_10        = excluded.debt_1_10,
             debt_11_20       = excluded.debt_11_20,
             debt_21_30       = excluded.debt_21_30,
             debt_31_45       = excluded.debt_31_45,
             debt_45_plus     = excluded.debt_45_plus,
             total_outdated   = excluded.total_outdated,
             debt_limit       = coalesce(excluded.debt_limit, aros_qarzdor.debt_limit),
             debt_allowed_days = coalesce(excluded.debt_allowed_days, aros_qarzdor.debt_allowed_days),
             most_outdated_deadline = coalesce(excluded.most_outdated_deadline, aros_qarzdor.most_outdated_deadline),
             most_outdated_kun = coalesce(excluded.most_outdated_kun, aros_qarzdor.most_outdated_kun),
             report_date      = excluded.report_date,
             faol             = true,
             synced_at        = now()
      returning (xmax = 0) into v_was_insert;

      if v_was_insert then
        n_yozildi := n_yozildi + 1;
      else
        n_yangilandi := n_yangilandi + 1;
      end if;

    exception when others then
      n_tashlandi := n_tashlandi + 1;
      v_ogoh := array_append(v_ogoh, 'qator xatosi (user_id=' || coalesce(v_uid_txt, '?') || '): ' || sqlerrm);
      continue;
    end;
  end loop;

  -- Payloadda ko'rinmay qolgan qatorlar -> faol=false. 🔴 FAQAT to'liq payloadda:
  -- rows>=100 VA n8n bergan Aros `count` bilan AYNAN teng bo'lsa (tester 2026-09-07:
  -- 3 sahifadan bittasi 404/timeout bersa 2000 qator ham ">=100" edi va yo'q sahifadagi
  -- ~459-1459 haqiqiy qarzdor nofaol bo'lib qolardi). `count` kelmasa sweep YO'Q.
  v_count := nullif(p_data ->> 'count', '')::int;
  if v_count is not null and jsonb_array_length(v_rows) >= 100
     and jsonb_array_length(v_rows) = v_count then
    update aros_qarzdor
       set faol = false
     where faol = true
       and not (user_id = any(v_ids_korilgan));
    get diagnostics n_nofaol = row_count;
  else
    n_nofaol := 0;
    v_ogoh := array_append(v_ogoh, 'chala payload (rows=' || jsonb_array_length(v_rows)
      || ', count=' || coalesce(v_count::text, 'yoq') || '), sweep qilinmadi');
  end if;

  insert into aros_qarzdor_sync (id, summary, soni, report_date, synced_at, davomiylik_ms, ogoh)
  values (1, v_summary, jsonb_array_length(v_rows), v_report_date, now(), v_davomiylik, v_ogoh)
  on conflict (id) do update
     set summary       = excluded.summary,
         soni          = excluded.soni,
         report_date   = excluded.report_date,
         synced_at     = excluded.synced_at,
         davomiylik_ms = excluded.davomiylik_ms,
         ogoh          = excluded.ogoh;

  return jsonb_build_object(
    'ok', true,
    'yozildi', n_yozildi,
    'yangilandi', n_yangilandi,
    'nofaol', n_nofaol,
    'tashlandi', n_tashlandi,
    'ogoh', to_jsonb(v_ogoh));
end
$qd_sync$;

revoke all on function sync_aros_qarzdor(jsonb) from public, anon, authenticated;
grant execute on function sync_aros_qarzdor(jsonb) to service_role;

comment on function sync_aros_qarzdor(jsonb) is
  'service_role ONLY (n8n "Aros Provodka - Aros Qarzdor Sync"). aros_qarzdor va '
  'aros_qarzdor_sync ni upsert qiladi. PUL HARAKATI YO''Q. rows>=100 bo''lsagina '
  'payloadda yo''q qolgan qatorlar faol=false qilinadi (chala payload sweep qilmaydi). '
  'Yaroqsiz user_id -> qator tashlanadi, butun sync yiqilmaydi.';


-- #####################################################################
-- ##  4-BO'LIM — aros_qarzdor_royxat(p) — authenticated               ##
-- #####################################################################
-- p: {q, warehouse_id, holat ('hammasi'|'qarzdor'|'muddati_otgan'|'toza'|
-- 'blok'|'45plus'), sort ('total_debt'|'total_outdated'|'debt_45_plus'|
-- 'balance'|'ism'), dir ('desc'|'asc'), limit (<=500, sukut 100), offset}.
-- 🔴 sort/dir FAQAT whitelist qiymatlardan (noma'lum -> sukutga tushadi),
-- ORDER BY ichida dinamik SQL YO'Q — faqat CASE bilan tanlangan ustun.

create or replace function aros_qarzdor_royxat(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $qd_royxat$
declare
  v_p           jsonb := coalesce(p, '{}'::jsonb);
  v_q           text;
  v_wh          int;
  v_holat       text;
  v_sort        text;
  v_dir         text;
  v_limit       int;
  v_offset      int;
  v_rows        jsonb;
  v_jami        int;
  v_jami_debt   numeric;
  v_jami_out    numeric;
  v_filiallar   jsonb;
  v_synced      timestamptz;
  v_report_date date;
begin
  if not qarz_page_ok() then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  v_q     := nullif(btrim(coalesce(v_p ->> 'q', '')), '');
  v_wh    := nullif(v_p ->> 'warehouse_id', '')::int;
  v_holat := coalesce(nullif(v_p ->> 'holat', ''), 'hammasi');
  if v_holat not in ('hammasi', 'qarzdor', 'muddati_otgan', 'toza', 'blok', '45plus') then
    v_holat := 'hammasi';
  end if;
  v_sort := coalesce(nullif(v_p ->> 'sort', ''), 'total_debt');
  if v_sort not in ('total_debt', 'total_outdated', 'debt_45_plus', 'balance', 'ism') then
    v_sort := 'total_debt';
  end if;
  v_dir := lower(coalesce(nullif(v_p ->> 'dir', ''), 'desc'));
  if v_dir not in ('asc', 'desc') then
    v_dir := 'desc';
  end if;
  v_limit  := greatest(1, least(coalesce(nullif(v_p ->> 'limit', '')::int, 100), 500));
  v_offset := greatest(0, coalesce(nullif(v_p ->> 'offset', '')::int, 0));

  select count(*), coalesce(sum(a.total_debt), 0), coalesce(sum(a.total_outdated), 0)
    into v_jami, v_jami_debt, v_jami_out
    from aros_qarzdor a
   where a.faol = true
     and (v_q is null or a.ism ilike '%' || v_q || '%' or a.familya ilike '%' || v_q || '%'
                       or coalesce(a.telefon, '') ilike '%' || v_q || '%')
     and (v_wh is null or a.warehouse_id = v_wh)
     and (
       v_holat = 'hammasi'
       or (v_holat = 'qarzdor'       and a.total_debt > 0)
       or (v_holat = 'muddati_otgan' and a.total_outdated > 0)
       or (v_holat = 'toza'          and a.total_debt > 0 and a.total_outdated = 0)
       or (v_holat = 'blok'          and a.wallet_status = 'blocked')
       or (v_holat = '45plus'        and a.debt_45_plus > 0)
     );

  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', b.user_id, 'ism', b.ism, 'familya', b.familya, 'telefon', b.telefon,
           'rol', b.rol, 'warehouse_id', b.warehouse_id, 'warehouse_nom', b.warehouse_nom,
           'wallet_status', b.wallet_status, 'wallet_balance', b.wallet_balance,
           'cashback_balance', b.cashback_balance,
           'total_debt', b.total_debt, 'balance', b.balance, 'clean_debt', b.clean_debt,
           'debt_1_10', b.debt_1_10, 'debt_11_20', b.debt_11_20, 'debt_21_30', b.debt_21_30,
           'debt_31_45', b.debt_31_45, 'debt_45_plus', b.debt_45_plus, 'total_outdated', b.total_outdated,
           'debt_limit', b.debt_limit, 'debt_allowed_days', b.debt_allowed_days,
           'most_outdated_deadline', b.most_outdated_deadline, 'most_outdated_kun', b.most_outdated_kun,
           'kechikish_daraja',
             case when b.debt_45_plus > 0 then '45_plus'
                  when b.debt_31_45  > 0 then '31_45'
                  when b.debt_21_30  > 0 then '21_30'
                  when b.debt_11_20  > 0 then '11_20'
                  when b.debt_1_10   > 0 then '1_10'
                  else 'yoq' end,
           'report_date', b.report_date, 'synced_at', b.synced_at)),
         '[]'::jsonb)
    into v_rows
    from (
      select a.*
        from aros_qarzdor a
       where a.faol = true
         and (v_q is null or a.ism ilike '%' || v_q || '%' or a.familya ilike '%' || v_q || '%'
                           or coalesce(a.telefon, '') ilike '%' || v_q || '%')
         and (v_wh is null or a.warehouse_id = v_wh)
         and (
           v_holat = 'hammasi'
           or (v_holat = 'qarzdor'       and a.total_debt > 0)
           or (v_holat = 'muddati_otgan' and a.total_outdated > 0)
           or (v_holat = 'toza'          and a.total_debt > 0 and a.total_outdated = 0)
           or (v_holat = 'blok'          and a.wallet_status = 'blocked')
           or (v_holat = '45plus'        and a.debt_45_plus > 0)
         )
       order by
         case when v_sort <> 'ism' and v_dir = 'asc' then
           case v_sort
             when 'total_debt'     then a.total_debt
             when 'total_outdated' then a.total_outdated
             when 'debt_45_plus'   then a.debt_45_plus
             when 'balance'        then a.balance
           end
         end asc nulls last,
         case when v_sort <> 'ism' and v_dir = 'desc' then
           case v_sort
             when 'total_debt'     then a.total_debt
             when 'total_outdated' then a.total_outdated
             when 'debt_45_plus'   then a.debt_45_plus
             when 'balance'        then a.balance
           end
         end desc nulls last,
         case when v_sort = 'ism' and v_dir = 'asc'
           then lower(coalesce(a.familya, '') || ' ' || coalesce(a.ism, '')) end asc nulls last,
         case when v_sort = 'ism' and v_dir = 'desc'
           then lower(coalesce(a.familya, '') || ' ' || coalesce(a.ism, '')) end desc nulls last,
         a.total_debt desc
       limit v_limit offset v_offset
    ) b;

  select coalesce(jsonb_agg(jsonb_build_object(
           'warehouse_id', f.warehouse_id, 'warehouse_nom', f.warehouse_nom, 'soni', f.soni)
           order by f.warehouse_nom), '[]'::jsonb)
    into v_filiallar
    from (
      select a.warehouse_id, a.warehouse_nom, count(*) as soni
        from aros_qarzdor a
       where a.faol = true and a.warehouse_id is not null
       group by a.warehouse_id, a.warehouse_nom
    ) f;

  select s.synced_at, s.report_date into v_synced, v_report_date
    from aros_qarzdor_sync s where s.id = 1;

  return jsonb_build_object(
    'rows', v_rows,
    'jami', coalesce(v_jami, 0),
    'jami_summa', jsonb_build_object('total_debt', coalesce(v_jami_debt, 0), 'total_outdated', coalesce(v_jami_out, 0)),
    'filiallar', v_filiallar,
    'synced_at', v_synced,
    'report_date', v_report_date);
end
$qd_royxat$;

revoke all on function aros_qarzdor_royxat(jsonb) from public, anon;
grant execute on function aros_qarzdor_royxat(jsonb) to authenticated;

comment on function aros_qarzdor_royxat(jsonb) is
  'Aros mijoz qarzlari jadvali: qidiruv/filial/holat filtri, whitelist saralash, '
  'sahifalash. Faqat faol=true. jami/jami_summa — FILTRDAN keyin, filiallar — filtrsiz.';


-- #####################################################################
-- ##  5-BO'LIM — aros_qarzdor_dash() — authenticated                  ##
-- #####################################################################

create or replace function aros_qarzdor_dash()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $qd_dash$
declare
  v_summary            jsonb;
  v_synced             timestamptz;
  v_report_date        date;
  v_soni_jami          int;
  v_soni_qarzdor       int;
  v_soni_muddati_otgan int;
  v_soni_blok          int;
begin
  if not qarz_page_ok() then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  select s.summary, s.synced_at, s.report_date
    into v_summary, v_synced, v_report_date
    from aros_qarzdor_sync s where s.id = 1;

  select count(*),
         count(*) filter (where a.total_debt > 0),
         count(*) filter (where a.total_outdated > 0),
         count(*) filter (where a.wallet_status = 'blocked')
    into v_soni_jami, v_soni_qarzdor, v_soni_muddati_otgan, v_soni_blok
    from aros_qarzdor a
   where a.faol = true;

  return jsonb_build_object(
    'summary', v_summary,
    'soni_jami', coalesce(v_soni_jami, 0),
    'soni_qarzdor', coalesce(v_soni_qarzdor, 0),
    'soni_muddati_otgan', coalesce(v_soni_muddati_otgan, 0),
    'soni_blok', coalesce(v_soni_blok, 0),
    'synced_at', v_synced,
    'report_date', v_report_date,
    'eskirgan', (v_synced is null or v_synced < now() - interval '2 hours'));
end
$qd_dash$;

revoke all on function aros_qarzdor_dash() from public, anon;
grant execute on function aros_qarzdor_dash() to authenticated;

comment on function aros_qarzdor_dash() is
  'Aros mijoz qarzlari dashboard: Aros summary xomligicha + hisoblangan sonlar. '
  'Jadval bo''sh bo''lsa summary null, sonlar 0 (banner uchun).';


-- #####################################################################
-- ##  6-BO'LIM — qarz_umumiy_dash() — authenticated                   ##
-- #####################################################################
-- Provodka (qarz_dash, mavjud bo'lsa) + Aros (aros_qarzdor_dash) birlashmasi.
-- 🔴 qarz_dash() yo'q bazada bo'lsa — 'provodka' null (jami hisobda 0 deb olinadi).

create or replace function qarz_umumiy_dash()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $qd_umumiy$
declare
  v_provodka jsonb;
  v_qd       jsonb;
  v_aros     jsonb;
begin
  if not qarz_page_ok() then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  v_provodka := null;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'qarz_dash' and p.pronargs = 0) then
    begin
      execute 'select qarz_dash()' into v_provodka;
    exception when others then
      v_provodka := null;
    end;
  end if;

  v_qd := aros_qarzdor_dash();
  v_aros := jsonb_build_object(
    'total_debt',     coalesce((v_qd -> 'summary' ->> 'total_debt')::numeric, 0),
    'total_outdated', coalesce((v_qd -> 'summary' ->> 'total_outdated_debts')::numeric, 0),
    'soni_qarzdor',   coalesce((v_qd ->> 'soni_qarzdor')::int, 0),
    'synced_at',      v_qd ->> 'synced_at');

  return jsonb_build_object(
    'provodka', v_provodka,
    'aros', v_aros,
    'jami', jsonb_build_object(
      'qarz',           coalesce((v_provodka ->> 'jami_qolgan')::numeric, 0) + coalesce((v_aros ->> 'total_debt')::numeric, 0),
      'muddati_otgan',  coalesce((v_provodka ->> 'jami_kechikkan')::numeric, 0) + coalesce((v_aros ->> 'total_outdated')::numeric, 0)
    ));
end
$qd_umumiy$;

revoke all on function qarz_umumiy_dash() from public, anon;
grant execute on function qarz_umumiy_dash() to authenticated;

comment on function qarz_umumiy_dash() is
  'UI yuqori strip uchun: Provodka qarz tizimi (qarz_dash, mavjud bo''lsa) + Aros '
  'mijoz qarzlari (aros_qarzdor_dash) birlashmasi. qarz_dash yo''q bazada -> provodka null.';


-- #####################################################################
-- ##  7-BO'LIM — PostgREST sxema keshini yangilash                    ##
-- #####################################################################

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  8-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/raise)                ##
-- #####################################################################

do $qd_final$
declare
  v_ok boolean;
begin
  if to_regclass('public.aros_qarzdor') is null then
    raise exception 'YAKUNIY TEKSHIRUV: aros_qarzdor jadvali yaralmadi';
  end if;
  if to_regclass('public.aros_qarzdor_sync') is null then
    raise exception 'YAKUNIY TEKSHIRUV: aros_qarzdor_sync jadvali yaralmadi';
  end if;

  -- pg_proc orqali (to_regprocedure Supabase editorida ishonchsiz — 0-BOLIM izohi)
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('sync_aros_qarzdor', 'aros_qarzdor_royxat', 'aros_qarzdor_dash', 'qarz_umumiy_dash')) < 4 then
    raise exception 'YAKUNIY TEKSHIRUV: 4 ta RPC dan birortasi yaralmadi (sync_aros_qarzdor, aros_qarzdor_royxat, aros_qarzdor_dash, qarz_umumiy_dash)';
  end if;

  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'aros_qarzdor'
                    and policyname = 'aros_qarzdor_select') then
    raise exception 'YAKUNIY TEKSHIRUV: aros_qarzdor_select policy yoq';
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'aros_qarzdor_sync'
                    and policyname = 'aros_qarzdor_sync_select') then
    raise exception 'YAKUNIY TEKSHIRUV: aros_qarzdor_sync_select policy yoq';
  end if;

  select has_function_privilege('service_role', 'public.sync_aros_qarzdor(jsonb)', 'execute') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: service_role uchun sync_aros_qarzdor(jsonb) EXECUTE yoq';
  end if;

  select has_function_privilege('authenticated', 'public.sync_aros_qarzdor(jsonb)', 'execute') into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated sync_aros_qarzdor(jsonb) ni chaqira olmasligi kerak edi';
  end if;

  select has_function_privilege('authenticated', 'public.aros_qarzdor_royxat(jsonb)', 'execute') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun aros_qarzdor_royxat(jsonb) EXECUTE yoq';
  end if;

  select has_function_privilege('authenticated', 'public.aros_qarzdor_dash()', 'execute') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun aros_qarzdor_dash() EXECUTE yoq';
  end if;

  select has_function_privilege('authenticated', 'public.qarz_umumiy_dash()', 'execute') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun qarz_umumiy_dash() EXECUTE yoq';
  end if;

  raise notice 'PROVODKA_AROS_QARZDOR.sql: hammasi joyida';
end
$qd_final$;
