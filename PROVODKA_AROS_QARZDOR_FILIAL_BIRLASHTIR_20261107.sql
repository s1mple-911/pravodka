-- =====================================================================
--  PROVODKA_AROS_QARZDOR_FILIAL_BIRLASHTIR_20261107.sql
--  Aros mijoz qarzlari — bir mijozning bir nechta FILIAL qatorini yig'ish
-- =====================================================================
--  MUAMMO (2026-11-07, Balans B «Mijozlar qarzi» paneli ogohlantirdi):
--    aros_qarzdor qatorlari yig'indisi 6 860 490 560, Aros summary.total_debt
--    7 843 220 760 — farq 982 730 200 so'm. Sabab: v3/report/debtors-list bir
--    mijozni HAR filial uchun alohida qator beradi (07.11 sinxron: 2827 qator,
--    2728 mijoz; 92 mijoz 2-4 filialda, 99 ortiqcha qator). aros_qarzdor.user_id
--    PK bo'lgani uchun eski sync_aros_qarzdor oxirgi qatorni qoldirar, oldingi
--    filiallardagi qarz yo'qolardi (aynan 982 730 200).
--
--  YECHIM (hammasi ADDITIVE, eski daftar/kassa/jurnalga tegmaydi):
--    1-BO'LIM  aros_qarzdor.filial_soni int, filial_qarz jsonb (taqsimot)
--    2-BO'LIM  aros_qarzdor_num(text) — xavfsiz numeric (xato -> null)
--    3-BO'LIM  sync_aros_qarzdor(p_data) — create or replace: payload mijoz
--              bo'yicha YIG'ILADI (qarz ustunlari qo'shiladi, hamyon/keshbek
--              max, asosiy filial = eng katta qarzli, filial_qarz saqlanadi);
--              sweep/soni xom qator soni bilan ishlaydi (eski mantiq).
--    4-BO'LIM  aros_qarzdor_royxat(p) — create or replace: filial filtri
--              filial_qarz ni ham qamraydi, rows da filial_soni/filial_qarz,
--              filiallar lug'ati har qarzdor filialda sanaydi.
--    5-BO'LIM  PostgREST sxema keshi + tekshiruv.
--
--  Natija n8n «Aros Provodka - Aros Qarzdor Sync» (har 30 daqiqa) keyingi
--  ishlashida paydo bo'ladi — n8n'ga tegilmaydi, payload o'sha-o'sha.
--  Idempotent: add column if not exists, create or replace. Anonim do bloki
--  yo'q. Izohlarda ketma-ket dollar belgi yozilmagan.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART                                            ##
-- #####################################################################

do $aqf_pre$
begin
  if to_regclass('public.aros_qarzdor') is null then
    raise exception 'aros_qarzdor yoq — avval PROVODKA_AROS_QARZDOR.sql ni bajaring';
  end if;
  if to_regprocedure('qarz_page_ok()') is null then
    raise exception 'qarz_page_ok() yoq — avval PROVODKA_QARZ.sql ni bajaring';
  end if;
end
$aqf_pre$;


-- #####################################################################
-- ##  1-BO'LIM — yangi ustunlar                                       ##
-- #####################################################################

alter table aros_qarzdor add column if not exists filial_soni int;
alter table aros_qarzdor add column if not exists filial_qarz jsonb;

comment on column aros_qarzdor.filial_soni is
  'Aros debtors-list da shu mijoz nechta filial qatorida kelgan (2026-11-07). 1 = bitta filial.';
comment on column aros_qarzdor.filial_qarz is
  'Filial bo''yicha taqsimot: [{warehouse_id, warehouse_nom, total_debt, total_outdated}] — '
  'qarz bo''yicha kamayib. total_debt ustuni shularning YIG''INDISI.';


-- #####################################################################
-- ##  2-BO'LIM — aros_qarzdor_num(text) — xavfsiz numeric              ##
-- #####################################################################

create or replace function aros_qarzdor_num(p text)
returns numeric
language plpgsql
immutable
as $aqf_num$
begin
  if p is null or btrim(p) = '' then
    return null;
  end if;
  return btrim(p)::numeric;
exception when others then
  return null;
end
$aqf_num$;

comment on function aros_qarzdor_num(text) is
  'Matnni numeric ga xavfsiz aylantiradi (xato/bo''sh -> null). sync_aros_qarzdor yig''ish uchun.';


-- ##  3-BO'LIM — sync_aros_qarzdor(p_data) — service_role ONLY (n8n)  ##
-- ##  (create or replace — filial qatorlari mijozga yig'iladi)        ##
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
  v_raw_soni        int;
  v_filial_soni     int;
  v_filial_qarz     jsonb;

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

  -- ---- 🔴 FILIAL BO'YICHA TAKROR QATORLARNI MIJOZGA YIG'ISH (2026-11-07) ----
  -- Aros debtors-list bir mijozni HAR filial uchun alohida qator beradi (07.11: 2827 qator,
  -- 2728 mijoz; 92 mijoz 2-4 filialda). user_id PK bo'lgani uchun eski upsert oxirgi
  -- qatorni qoldirib 982 730 200 so'm qarzni yo'qotardi (summary.total_debt bilan farq).
  -- Endi: qarz ustunlari QO'SHILADI, hamyon/keshbek (mijoz darajasida, har qatorda bir xil)
  -- max, asosiy filial = eng katta qarzli, filial_qarz = taqsimot (jsonb massiv).
  v_raw_soni := jsonb_array_length(v_rows);
  select coalesce(jsonb_agg(g.obj), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
        'user_id',          e.uid,
        'first_name',       (array_agg(e.el ->> 'first_name'     order by e.debt desc nulls last))[1],
        'last_name',        (array_agg(e.el ->> 'last_name'      order by e.debt desc nulls last))[1],
        'username',         (array_agg(e.el ->> 'username'       order by e.debt desc nulls last))[1],
        'role',             (array_agg(e.el ->> 'role'           order by e.debt desc nulls last))[1],
        'warehouse_id',     (array_agg(e.el ->> 'warehouse_id'   order by e.debt desc nulls last))[1],
        'warehouse_name',   (array_agg(e.el ->> 'warehouse_name' order by e.debt desc nulls last))[1],
        'wallet_status',    case when bool_or(e.el ->> 'wallet_status' = 'blocked') then 'blocked'
                                 else (array_agg(e.el ->> 'wallet_status' order by e.debt desc nulls last))[1] end,
        'wallet_balance',   max(aros_qarzdor_num(e.el ->> 'wallet_balance')),
        'cashback_balance', max(aros_qarzdor_num(e.el ->> 'cashback_balance')),
        'total_debt',       sum(e.debt),
        'balance',          case when count(*) = 1 then max(aros_qarzdor_num(e.el ->> 'balance'))
                                 else coalesce(max(aros_qarzdor_num(e.el ->> 'wallet_balance')), 0)
                                    + coalesce(max(aros_qarzdor_num(e.el ->> 'cashback_balance')), 0)
                                    - coalesce(sum(e.debt), 0) end,
        'clean_debt',       sum(aros_qarzdor_num(e.el ->> 'clean_debt')),
        'debt_1_10',        sum(aros_qarzdor_num(e.el ->> 'debt_1_10')),
        'debt_11_20',       sum(aros_qarzdor_num(e.el ->> 'debt_11_20')),
        'debt_21_30',       sum(aros_qarzdor_num(e.el ->> 'debt_21_30')),
        'debt_31_45',       sum(aros_qarzdor_num(e.el ->> 'debt_31_45')),
        'debt_45_plus',     sum(aros_qarzdor_num(e.el ->> 'debt_45_plus')),
        'total_outdated_debts', sum(aros_qarzdor_num(e.el ->> 'total_outdated_debts')),
        'debt_limit',       max(aros_qarzdor_num(e.el ->> 'debt_limit')),
        'debt_allowed_days', max(aros_qarzdor_num(e.el ->> 'debt_allowed_days')),
        'most_outdated_deadline', (array_agg(e.el ->> 'most_outdated_deadline'
                                     order by aros_qarzdor_num(e.el ->> 'most_outdated_deadline') desc nulls last))[1],
        'most_outdated_kun', max(aros_qarzdor_num(e.el ->> 'most_outdated_kun')),
        'filial_soni',      count(*),
        'filial_qarz',      jsonb_agg(jsonb_build_object(
                              'warehouse_id',   aros_qarzdor_num(e.el ->> 'warehouse_id'),
                              'warehouse_nom',  e.el ->> 'warehouse_name',
                              'total_debt',     coalesce(e.debt, 0),
                              'total_outdated', coalesce(aros_qarzdor_num(e.el ->> 'total_outdated_debts'), 0))
                            order by e.debt desc nulls last)
      ) as obj
      from (
        select x.el,
               nullif(btrim(coalesce(x.el ->> 'user_id', '')), '') as uid,
               aros_qarzdor_num(x.el ->> 'total_debt')             as debt,
               x.rn
          from jsonb_array_elements(v_rows) with ordinality as x(el, rn)
      ) e
      -- yaroqsiz user_id'li qatorlar YIG'ILMAYDI (har biri alohida qoladi -> pastda tashlanadi)
      group by e.uid, case when e.uid ~ '^[0-9]+$' then 0 else e.rn end
    ) g;

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
      v_wh_id          := nullif(v_el ->> 'warehouse_id', '')::numeric::int;
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
      v_dad            := nullif(v_el ->> 'debt_allowed_days', '')::numeric::int;
      -- most_outdated_deadline: dashboard keshida KUN soni ("7", "155"), ehtimol sana ham kelishi mumkin
      v_mod_txt := nullif(btrim(coalesce(v_el ->> 'most_outdated_deadline', '')), '');
      v_mod := null; v_kun := null;
      if v_mod_txt ~ '^[0-9]+$' then
        v_kun := v_mod_txt::int;
      elsif v_mod_txt ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then
        v_mod := left(v_mod_txt, 10)::date;
      end if;
      if v_kun is null then
        v_kun := nullif(v_el ->> 'most_outdated_kun', '')::numeric::int;
      end if;
      v_filial_soni := coalesce(nullif(v_el ->> 'filial_soni', '')::int, 1);
      v_filial_qarz := case when jsonb_typeof(v_el -> 'filial_qarz') = 'array' then v_el -> 'filial_qarz' else null end;

      insert into aros_qarzdor (
        user_id, ism, familya, telefon, rol, warehouse_id, warehouse_nom,
        wallet_status, wallet_balance, cashback_balance,
        total_debt, balance, clean_debt,
        debt_1_10, debt_11_20, debt_21_30, debt_31_45, debt_45_plus, total_outdated,
        debt_limit, debt_allowed_days, most_outdated_deadline, most_outdated_kun,
        filial_soni, filial_qarz,
        report_date, faol, synced_at)
      values (
        v_uid, coalesce(v_ism, ''), coalesce(v_familya, ''), v_telefon, v_rol, v_wh_id, v_wh_nom,
        v_wallet_status, coalesce(v_wallet_balance, 0), coalesce(v_cashback, 0),
        coalesce(v_total_debt, 0), coalesce(v_balance, 0), coalesce(v_clean_debt, 0),
        coalesce(v_d1, 0), coalesce(v_d2, 0), coalesce(v_d3, 0), coalesce(v_d4, 0), coalesce(v_d5, 0),
        coalesce(v_outdated, 0), v_limit, v_dad, v_mod, v_kun,
        v_filial_soni, v_filial_qarz, v_report_date, true, now())
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
             filial_soni      = excluded.filial_soni,
             filial_qarz      = excluded.filial_qarz,
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
  -- 🔴 v_raw_soni = Aros bergan XOM qatorlar soni (yig'ishdan oldin) — count bilan shu solishtiriladi
  if v_count is not null and v_raw_soni >= 100
     and v_raw_soni = v_count then
    update aros_qarzdor
       set faol = false
     where faol = true
       and not (user_id = any(v_ids_korilgan));
    get diagnostics n_nofaol = row_count;
  else
    n_nofaol := 0;
    v_ogoh := array_append(v_ogoh, 'chala payload (rows=' || v_raw_soni
      || ', count=' || coalesce(v_count::text, 'yoq') || '), sweep qilinmadi');
  end if;

  insert into aros_qarzdor_sync (id, summary, soni, report_date, synced_at, davomiylik_ms, ogoh)
  values (1, v_summary, v_raw_soni, v_report_date, now(), v_davomiylik, v_ogoh)
  on conflict (id) do update
     set summary       = excluded.summary,
         soni          = excluded.soni,
         report_date   = excluded.report_date,
         synced_at     = excluded.synced_at,
         davomiylik_ms = excluded.davomiylik_ms,
         ogoh          = excluded.ogoh;

  return jsonb_build_object(
    'ok', true,
    'xom_qator', v_raw_soni,
    'mijoz', jsonb_array_length(v_rows),
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
  'Yaroqsiz user_id -> qator tashlanadi, butun sync yiqilmaydi. 2026-11-07: bir mijozning '
  'bir nechta filial qatori MIJOZGA YIGILADI (qarz qoshiladi, filial_qarz taqsimot).';




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
     and (v_wh is null or a.warehouse_id = v_wh
          or exists (select 1 from jsonb_array_elements(
                       case when jsonb_typeof(a.filial_qarz) = 'array' then a.filial_qarz else '[]'::jsonb end) fq
                      where aros_qarzdor_num(fq ->> 'warehouse_id') = v_wh))
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
           'filial_soni', coalesce(b.filial_soni, 1), 'filial_qarz', b.filial_qarz,
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
         and (v_wh is null or a.warehouse_id = v_wh
              or exists (select 1 from jsonb_array_elements(
                           case when jsonb_typeof(a.filial_qarz) = 'array' then a.filial_qarz else '[]'::jsonb end) fq
                          where aros_qarzdor_num(fq ->> 'warehouse_id') = v_wh))
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
      -- 2026-11-07: filial_qarz bo'lsa mijoz HAR qarzdor filialida sanaladi (bitta mijoz bir nechta filialda)
      select u.warehouse_id, max(u.warehouse_nom) as warehouse_nom, count(distinct u.user_id) as soni
        from (
          select a.user_id,
                 coalesce(aros_qarzdor_num(fq ->> 'warehouse_id')::int, a.warehouse_id) as warehouse_id,
                 coalesce(fq ->> 'warehouse_nom', a.warehouse_nom)                      as warehouse_nom
            from aros_qarzdor a
            left join lateral jsonb_array_elements(
                   case when jsonb_typeof(a.filial_qarz) = 'array' then a.filial_qarz else '[]'::jsonb end) fq on true
           where a.faol = true
        ) u
       where u.warehouse_id is not null
       group by u.warehouse_id
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
  'sahifalash. Faqat faol=true. jami/jami_summa — FILTRDAN keyin, filiallar — filtrsiz. '
  '2026-11-07: filial filtri filial_qarz taqsimotini ham qamraydi; rows da filial_soni/filial_qarz.';



-- #####################################################################
-- ##  5-BO'LIM — PostgREST sxema keshi + tekshiruv                     ##
-- #####################################################################

notify pgrst, 'reload schema';

do $aqf_check$
declare
  v_src text;
begin
  if to_regprocedure('aros_qarzdor_num(text)') is null then
    raise exception 'aros_qarzdor_num yaratilmadi';
  end if;
  select pg_get_functiondef('sync_aros_qarzdor(jsonb)'::regprocedure) into v_src;
  if position('filial_qarz' in v_src) = 0 or position('v_raw_soni' in v_src) = 0 then
    raise exception 'sync_aros_qarzdor yangilanmadi';
  end if;
  select pg_get_functiondef('aros_qarzdor_royxat(jsonb)'::regprocedure) into v_src;
  if position('filial_qarz' in v_src) = 0 then
    raise exception 'aros_qarzdor_royxat yangilanmadi';
  end if;
  if aros_qarzdor_num('12.5') <> 12.5 or aros_qarzdor_num('abc') is not null then
    raise exception 'aros_qarzdor_num notogri ishlayapti';
  end if;
  raise notice 'OK: filial_soni/filial_qarz, aros_qarzdor_num, sync_aros_qarzdor va aros_qarzdor_royxat yangilandi. Keyingi n8n sinxron (30 daqiqa) dan keyin qatorlar yigindisi summary.total_debt ga teng boladi.';
end
$aqf_check$;

select
  (select count(*) from aros_qarzdor a where a.faol)                               as faol_soni,
  (select coalesce(sum(a.total_debt), 0) from aros_qarzdor a where a.faol)          as jadval_total_debt,
  (select nullif(s.summary ->> 'total_debt', '')::numeric from aros_qarzdor_sync s where s.id = 1) as summary_total_debt,
  (select s.synced_at from aros_qarzdor_sync s where s.id = 1)                       as synced_at;
