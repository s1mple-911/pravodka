-- =====================================================================
--  PROVODKA_YOLDA.sql — «Yo'ldagi pul» (transit) REGISTRI
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  #####  MUAMMO  ########################################################
--
--  Filial markaziy kassaga pul jo'natadi (`cachier_transfers`, status
--  `sent`), markaziy kassa «qabul qildi» bosgach `received` bo'ladi va
--  SHUNDAN KEYINGINA Provodka'ga yozuv tushadi (`sync_transfer_balans`,
--  PROVODKA_TRANSFER.sql — bu faylda TEGILMAYDI). Yo'lda turgan pul hech
--  qayerda ko'rinmaydi. Qabulda summa o'zgarishi mumkin (sotuvchi sanagan
--  summa vs qabulda tasdiqlangan summa).
--
--  #####  YECHIM  ########################################################
--
--  PUL HARAKATI YO'Q — alohida REGISTR jadvali (`aros_transfer_yolda`),
--  n8n har 5 daqiqada to'ldiradi («Aros Provodka - Yolda Sync», alohida
--  workflow — N8N_YOLDA_SYNC.js), UI o'qiydi. Buxgalteriya yozuvlariga
--  (`entry` / `entry_line`) BITTA QATOR HAM YOZILMAYDI.
--
--  #####  FAYL TARKIBI  ##################################################
--     0-BO'LIM — old shart tekshiruvi (raise exception)
--     1-BO'LIM — jadval `aros_transfer_yolda` (+ CHECK + indeks)
--     2-BO'LIM — `yolda_korish_ok(sender,receiver)` + RLS (select-only)
--     3-BO'LIM — `sync_transfer_yolda(p_data)` — service_role ONLY
--     4-BO'LIM — `yolda_royxat()` — authenticated (kartalar uchun)
--     5-BO'LIM — `yolda_farq(p_ids)` — authenticated (jurnal uchun)
--     6-BO'LIM — PostgREST sxema keshini yangilash
--     7-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/raise)
--
--  #####  ADDITIVE KAFOLATI  #############################################
--   * Hech narsa drop qilinmaydi, hech qanday mavjud jadval/ustun/funksiya
--     imzosi o'zgartirilmaydi. Hammasi YANGI, `yolda_`/`aros_transfer_yolda`
--     prefiksi bilan (bitta ICHKI yordamchi `_yolda_ts`).
--   * `aros_kassa_topish(ref, nom)` (PROVODKA_TRANSFER.sql) faqat CHAQIRILADI
--     — tanasi o'zgartirilmaydi.
--   * Idempotent: `create table if not exists`, `create or replace function`,
--     `drop policy if exists` + `create policy`, CHECK constraint
--     `if not exists (select ... from pg_constraint ...)`.
--   * Anonim `do` bloki YO'Q — har `do` bloki nomlangan teg bilan. Funksiya
--     tanasi ham nomlangan teg bilan. Izohlarda ketma-ket dollar belgi
--     yozilmagan (soxta blok xavfi — CLAUDE.md).
--
--  #####  TALAB (0-BO'LIM tekshiradi)  ###################################
--     accounts, user_perms, profiles      — asosiy migratsiya
--     is_admin()                          — mavjud
--     perm_op_key(uuid)                   — PROVODKA_PERMS.sql
--     aros_kassa_topish(text,text)        — PROVODKA_TRANSFER.sql
--
--  🔴 SQL'ni ASILBEK o'zi RUN qiladi. Agent bajarmaydi.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI                                 ##
-- #####################################################################

do $yolda_pre$
begin
  if to_regclass('public.accounts') is null then
    raise exception 'accounts jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regclass('public.user_perms') is null then
    raise exception 'user_perms jadvali yoq — avval PROVODKA_PERMS.sql ni bajaring';
  end if;
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'is_admin() funksiyasi yoq — ruxsat tizimi unga tayanadi';
  end if;
  if to_regprocedure('public.perm_op_key(uuid)') is null then
    raise exception 'perm_op_key(uuid) yoq — avval PROVODKA_PERMS.sql ni bajaring';
  end if;
  if to_regprocedure('public.aros_kassa_topish(text,text)') is null then
    raise exception 'aros_kassa_topish(text,text) yoq — avval PROVODKA_TRANSFER.sql ni bajaring';
  end if;
end
$yolda_pre$;


-- #####################################################################
-- ##  1-BO'LIM — JADVAL: aros_transfer_yolda                          ##
-- #####################################################################
-- Har qator — bitta Aros transferi (cachier_transfers.id, matn sifatida
-- saqlanadi — Aros tomonda son, lekin bu yerda formatni cheklamaymiz).
-- `status`: sent (yo'lda) | received (qabul qilindi) | canceled | nomalum
-- (payloadda ko'rinishdan qolgan, avval `sent` bo'lgan qator).

create table if not exists aros_transfer_yolda (
  transfer_id     text        primary key,
  status          text        not null default 'nomalum',
  sender_id       uuid        references accounts(id),
  receiver_id     uuid        references accounts(id),
  sender_title    text,
  receiver_title  text,
  sent_at         timestamptz,
  received_at     timestamptz,
  -- sotuvchi (reja, sana kelish paytida sanalgan)
  s_cash          numeric     not null default 0,
  s_click         numeric     not null default 0,
  s_payme         numeric     not null default 0,
  s_usd           numeric     not null default 0,
  -- tasdiqlangan (fakt) — faqat status='received' bo'lganda to'ladi
  c_cash          numeric,
  c_click         numeric,
  c_payme         numeric,
  c_usd           numeric,
  dollar_rate     numeric,
  responsible     text,
  synced_at       timestamptz not null default now(),
  created_at      timestamptz not null default now()
);

do $yolda_chk$
begin
  if not exists (select 1 from pg_constraint where conname = 'aros_transfer_yolda_status_chk') then
    alter table aros_transfer_yolda
      add constraint aros_transfer_yolda_status_chk
      check (status in ('sent','received','canceled','nomalum'));
  end if;
end
$yolda_chk$;

create index if not exists idx_yolda_status  on aros_transfer_yolda(status);
create index if not exists idx_yolda_sent_at on aros_transfer_yolda(sent_at);

comment on table aros_transfer_yolda is
  '«Yo''ldagi pul» registri: Aros cachier-transferlar (sent/received/canceled). '
  'PUL HARAKATI EMAS — entry/entry_line ga hech narsa yozilmaydi, faqat UI uchun ko''rinish. '
  'n8n «Aros Provodka - Yolda Sync» har 5 daqiqada sync_transfer_yolda() orqali to''ldiradi.';

alter table aros_transfer_yolda enable row level security;
revoke all on table aros_transfer_yolda from public, anon;
grant select on table aros_transfer_yolda to authenticated;


-- #####################################################################
-- ##  2-BO'LIM — yolda_korish_ok() + RLS (select-only)                ##
-- #####################################################################
-- Yozish policy'si YO'Q — faqat sync_transfer_yolda() (service_role,
-- security definer) yozadi.

create or replace function yolda_korish_ok(p_sender uuid, p_receiver uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $yolda_ok$
declare
  v_uid uuid;
  p     user_perms%rowtype;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return false;                       -- fail-CLOSED: n8n/SQL editor bu yo'ldan kirmaydi
  end if;

  if is_admin() then
    return true;
  end if;

  select * into p from user_perms where user_id = v_uid;

  if not found then
    -- qatorsiz foydalanuvchi: allowed_pages bo'sh (my_perms bilan bir xil semantika)
    -- -> sahifa ruxsati YO'Q -> fail-CLOSED
    return false;
  end if;

  if not ( 'kassa'  = any(coalesce(p.allowed_pages, '{}'::text[]))
        or 'jurnal' = any(coalesce(p.allowed_pages, '{}'::text[])) ) then
    return false;
  end if;

  if p.kassa_scope is distinct from 'list' then
    return true;                        -- kassa_scope = 'all'
  end if;

  return (p_sender   is not null and perm_op_key(p_sender)   = any(coalesce(p.view_kassa_ids, '{}'::uuid[])))
      or (p_receiver is not null and perm_op_key(p_receiver) = any(coalesce(p.view_kassa_ids, '{}'::uuid[])));
end
$yolda_ok$;

revoke all on function yolda_korish_ok(uuid, uuid) from public, anon;
grant execute on function yolda_korish_ok(uuid, uuid) to authenticated;

comment on function yolda_korish_ok(uuid, uuid) is
  'RLS/RPC qorovuli: admin YOKI (kassa/jurnal sahifa ruxsati VA kassa doirasi — '
  'kassa_scope=all yoki sender/receiver perm_op_key view_kassa_ids ichida). '
  'auth.uid() null yoki user_perms qatori yo''q bo''lsa false (fail-closed).';

drop policy if exists aros_transfer_yolda_select on aros_transfer_yolda;
create policy aros_transfer_yolda_select on aros_transfer_yolda
  for select to authenticated
  using (yolda_korish_ok(sender_id, receiver_id));


-- #####################################################################
-- ##  3-BO'LIM — sync_transfer_yolda(p_data) — service_role ONLY      ##
-- #####################################################################

-- 3.1 ICHKI yordamchi: vaqtni Toshkent zonasiga moslash
-- (PROVODKA_TRANSFER.sql 4.3-bandi bilan bir xil naqsh — Aros vaqtni
-- zonasiz/naive Toshkent vaqtida yuborishi mumkin).
create or replace function _yolda_ts(p_txt text)
returns timestamptz
language plpgsql
stable
as $yolda_ts$
declare
  v_txt text;
  v_out timestamptz;
begin
  v_txt := nullif(btrim(coalesce(p_txt, '')), '');
  if v_txt is null then
    return null;
  end if;

  if v_txt ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    v_txt := v_txt || 'T00:00:00+05';
  elsif v_txt !~ '([Zz]|[+-][0-9]{2}:[0-9]{2}|[+-][0-9]{4}|:[0-9]{2}(\.[0-9]+)?[+-][0-9]{2})$' then
    v_txt := v_txt || '+05';
  end if;

  begin
    v_out := v_txt::timestamptz;
  exception when others then
    v_out := null;
  end;

  return v_out;
end
$yolda_ts$;

revoke all on function _yolda_ts(text) from public, anon, authenticated;

comment on function _yolda_ts(text) is
  'ICHKI: Aros vaqtini (zonasiz kelsa Toshkent +05 deb) timestamptz ga o''giradi. '
  'Buzuq matn -> null (sync_transfer_yolda butun elementni yiqitmasin).';

-- 3.2 asosiy sync RPC
create or replace function sync_transfer_yolda(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $yolda_sync$
declare
  v_role            text;
  v_list            jsonb;
  v_el              jsonb;

  v_id              text;
  v_status          text;
  v_sender_ref      text;
  v_receiver_ref    text;
  v_sender_title    text;
  v_receiver_title  text;
  v_sent_at         timestamptz;
  v_received_at     timestamptz;

  v_seller          jsonb;
  v_confirmed       jsonb;
  v_s_cash          numeric;
  v_s_click         numeric;
  v_s_payme         numeric;
  v_s_usd           numeric;
  v_c_cash          numeric;
  v_c_click         numeric;
  v_c_payme         numeric;
  v_c_usd           numeric;
  v_rate            numeric;
  v_resp            text;

  v_sender_acc      jsonb;
  v_receiver_acc    jsonb;
  v_was_insert      boolean;

  v_ids_korilgan    text[] := '{}';
  n_yozildi         int := 0;
  n_yangilandi      int := 0;
  n_nomalum         int := 0;
  v_ogoh            jsonb := '[]'::jsonb;
begin
  -- ---- service_role ONLY (admin_set_provodka_perms bilan bir xil naqsh) ----
  if auth.uid() is not null then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is not null and v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('sync_transfer_yolda'));

  if p_data is null then
    return jsonb_build_object('ok', false, 'error', 'p_data bo''sh');
  end if;

  if jsonb_typeof(p_data) = 'object' and p_data ? 'transferlar' then
    v_list := p_data -> 'transferlar';
  elsif jsonb_typeof(p_data) = 'object' and p_data ? 'transfers' then
    v_list := p_data -> 'transfers';
  else
    v_list := p_data;
  end if;

  if jsonb_typeof(v_list) is distinct from 'array' then
    return jsonb_build_object('ok', false,
      'error', 'JSON massiv kutilgan edi (yoki {transferlar:[...]}), keldi: '
               || coalesce(jsonb_typeof(v_list), 'null'));
  end if;

  for v_el in select * from jsonb_array_elements(v_list)
  loop
    begin
      v_id := nullif(btrim(coalesce(v_el ->> 'id', v_el ->> 'transfer_id', '')), '');
      if v_id is null then
        v_ogoh := v_ogoh || jsonb_build_object('transfer', null, 'sabab', 'id yoq');
        continue;
      end if;

      v_ids_korilgan := v_ids_korilgan || v_id;

      v_status := lower(btrim(coalesce(nullif(v_el ->> 'status', ''), 'nomalum')));
      if v_status not in ('sent', 'received', 'canceled') then
        v_status := 'nomalum';
      end if;

      v_sender_title   := nullif(btrim(coalesce(v_el ->> 'sender_title', '')), '');
      v_receiver_title := nullif(btrim(coalesce(v_el ->> 'receiver_title', '')), '');
      v_sender_ref     := nullif(btrim(coalesce(v_el ->> 'sender_ref', '')), '');
      v_receiver_ref   := nullif(btrim(coalesce(v_el ->> 'receiver_ref', '')), '');

      v_sent_at     := _yolda_ts(v_el ->> 'sent_at');
      v_received_at := _yolda_ts(v_el ->> 'received_at');

      v_sender_acc   := aros_kassa_topish(v_sender_ref,   v_sender_title);
      v_receiver_acc := aros_kassa_topish(v_receiver_ref, v_receiver_title);

      v_seller  := coalesce(v_el -> 'seller', '{}'::jsonb);
      v_s_cash  := coalesce((v_seller ->> 'cash')::numeric, 0);
      v_s_click := coalesce((v_seller ->> 'click')::numeric, 0);
      v_s_payme := coalesce((v_seller ->> 'payme')::numeric, 0);
      v_s_usd   := coalesce((v_seller ->> 'dollar_usd')::numeric, 0);

      if v_status = 'received'
         and jsonb_typeof(v_el -> 'confirmed') = 'object' then
        v_confirmed := v_el -> 'confirmed';
        v_c_cash  := coalesce((v_confirmed ->> 'cash')::numeric, 0);
        v_c_click := coalesce((v_confirmed ->> 'click')::numeric, 0);
        v_c_payme := coalesce((v_confirmed ->> 'payme')::numeric, 0);
        v_c_usd   := coalesce((v_confirmed ->> 'dollar_usd')::numeric, 0);
      else
        v_c_cash  := null;
        v_c_click := null;
        v_c_payme := null;
        v_c_usd   := null;
      end if;

      v_rate := nullif(v_el ->> 'dollar_rate', '')::numeric;
      v_resp := nullif(btrim(coalesce(v_el ->> 'responsible', '')), '');

      insert into aros_transfer_yolda(
        transfer_id, status, sender_id, receiver_id, sender_title, receiver_title,
        sent_at, received_at, s_cash, s_click, s_payme, s_usd,
        c_cash, c_click, c_payme, c_usd, dollar_rate, responsible, synced_at)
      values (
        v_id, v_status,
        case when coalesce((v_sender_acc   ->> 'ok')::boolean, false) then (v_sender_acc   ->> 'id')::uuid else null end,
        case when coalesce((v_receiver_acc ->> 'ok')::boolean, false) then (v_receiver_acc ->> 'id')::uuid else null end,
        v_sender_title, v_receiver_title, v_sent_at, v_received_at,
        v_s_cash, v_s_click, v_s_payme, v_s_usd,
        v_c_cash, v_c_click, v_c_payme, v_c_usd, v_rate, v_resp, now())
      on conflict (transfer_id) do update
         set status         = excluded.status,
             sender_id      = excluded.sender_id,
             receiver_id    = excluded.receiver_id,
             sender_title   = excluded.sender_title,
             receiver_title = excluded.receiver_title,
             sent_at        = excluded.sent_at,
             received_at    = excluded.received_at,
             s_cash         = excluded.s_cash,
             s_click        = excluded.s_click,
             s_payme        = excluded.s_payme,
             s_usd          = excluded.s_usd,
             c_cash         = excluded.c_cash,
             c_click        = excluded.c_click,
             c_payme        = excluded.c_payme,
             c_usd          = excluded.c_usd,
             dollar_rate    = excluded.dollar_rate,
             responsible    = excluded.responsible,
             synced_at      = now()
      returning (xmax = 0) into v_was_insert;

      if v_was_insert then
        n_yozildi := n_yozildi + 1;
      else
        n_yangilandi := n_yangilandi + 1;
      end if;

      if not coalesce((v_sender_acc ->> 'ok')::boolean, false) then
        v_ogoh := v_ogoh || jsonb_build_object(
          'transfer', v_id, 'tomon', 'sender', 'sabab', v_sender_acc ->> 'sabab');
      end if;
      if not coalesce((v_receiver_acc ->> 'ok')::boolean, false) then
        v_ogoh := v_ogoh || jsonb_build_object(
          'transfer', v_id, 'tomon', 'receiver', 'sabab', v_receiver_acc ->> 'sabab');
      end if;

    exception when others then
      v_ogoh := v_ogoh || jsonb_build_object('transfer', v_id, 'sabab', sqlerrm);
      continue;
    end;
  end loop;

  -- Payloadda ko'rinmay qolgan «sent» qatorlar -> 'nomalum'
  -- (n8n hamma sent'ni har safar yuboradi — yo'qolgani endi yo'lda emas).
  -- 🔴 Bo'sh payload (n8n PG so'rovi vaqtincha 0 qator qaytarsa) sweep QILMAYDI —
  -- aks holda hamma yo'ldagi qator bir zumda 'nomalum' bo'lib "yo'lda pul yo'q"
  -- deb ko'rinardi (tester 2026-09-06). Haqiqiy bo'sh holat: sent yo'q bo'lsa
  -- ham received (14 kun) qatorlari keladi; ikkalasi ham 0 = shubhali, tegilmaydi.
  if coalesce(array_length(v_ids_korilgan, 1), 0) > 0 then
    update aros_transfer_yolda
       set status = 'nomalum', synced_at = now()
     where status = 'sent'
       and not (transfer_id = any(v_ids_korilgan));
    get diagnostics n_nomalum = row_count;
  else
    n_nomalum := 0;
    v_ogoh := v_ogoh || jsonb_build_object('sabab', 'payload bosh — sent sweep otkazib yuborildi');
  end if;

  return jsonb_build_object(
    'ok', true,
    'yozildi', n_yozildi,
    'yangilandi', n_yangilandi,
    'nomalum', n_nomalum,
    'ogoh', v_ogoh);
end
$yolda_sync$;

revoke all on function sync_transfer_yolda(jsonb) from public, anon, authenticated;
grant execute on function sync_transfer_yolda(jsonb) to service_role;

comment on function sync_transfer_yolda(jsonb) is
  'service_role ONLY (n8n «Aros Provodka - Yolda Sync»). aros_transfer_yolda ni upsert qiladi. '
  'PUL HARAKATI YO''Q — entry/entry_line ga tegilmaydi. Payloadda yo''q qolgan avvalgi '
  '''sent'' qatorlar ''nomalum'' ga o''tkaziladi.';


-- #####################################################################
-- ##  4-BO'LIM — yolda_royxat() — authenticated (kartalar uchun)      ##
-- #####################################################################

create or replace function yolda_royxat()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $yolda_royxat$
declare
  v_uid       uuid;
  p           user_perms%rowtype;
  v_rejim     text;         -- 'admin' | 'all' | 'list' | 'yoq'
  v_ids       uuid[] := '{}';
  v_baza_rate numeric;
  v_sent      jsonb;
  v_jami      numeric;
  v_soni      int;
  v_qabul     jsonb;
  v_synced    timestamptz;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('rows', '[]'::jsonb, 'jami_uzs', 0, 'soni', 0,
                              'qabul', '[]'::jsonb, 'synced_at', null);
  end if;

  if is_admin() then
    v_rejim := 'admin';
  else
    select * into p from user_perms where user_id = v_uid;
    -- 🔴 SAHIFA RUXSATI (tester 2026-09-06): yolda_korish_ok() bilan BIR XIL qoida —
    -- qatorsiz user yoki allowed_pages da na 'kassa' na 'jurnal' bo'lmasa -> 'yoq'
    -- (fail-closed). Aks holda kassa_scope='all' (DEFAULT) bo'lgan har qanday
    -- authenticated user butun kompaniya transferlarini RPC orqali olardi.
    if not found
       or not ( 'kassa'  = any(coalesce(p.allowed_pages, '{}'::text[]))
             or 'jurnal' = any(coalesce(p.allowed_pages, '{}'::text[])) ) then
      v_rejim := 'yoq';
    elsif p.kassa_scope is distinct from 'list' then
      v_rejim := 'all';
    else
      v_rejim := 'list';
      v_ids   := coalesce(p.view_kassa_ids, '{}'::uuid[]);
    end if;
  end if;

  if v_rejim = 'yoq' then
    return jsonb_build_object('rows', '[]'::jsonb, 'jami_uzs', 0, 'soni', 0,
                              'qabul', '[]'::jsonb, 'synced_at', null);
  end if;

  if to_regprocedure('public.conv_baza_kurs(text)') is not null then
    begin
      execute 'select conv_baza_kurs($1)' into v_baza_rate using 'USD';
    exception when others then
      v_baza_rate := null;
    end;
  end if;

  -- ---- «Yo'lda» (status = sent) ----
  with base as (
    select t.transfer_id, t.sender_id, t.receiver_id,
           coalesce(sa.name, t.sender_title)     as sender_nom_raw,
           coalesce(ra.name, t.receiver_title)   as receiver_nom_raw,
           t.sent_at, t.s_cash, t.s_click, t.s_payme, t.s_usd, t.dollar_rate,
           (v_rejim in ('admin','all') or perm_op_key(t.sender_id)   = any(v_ids)) as send_ok,
           (v_rejim in ('admin','all') or perm_op_key(t.receiver_id) = any(v_ids)) as recv_ok
      from aros_transfer_yolda t
      left join accounts sa on sa.id = t.sender_id
      left join accounts ra on ra.id = t.receiver_id
     where t.status = 'sent'
  ),
  vis as (
    select b.*,
           case when send_ok then sender_nom_raw   else 'Boshqa kassa' end as sender_nom,
           case when recv_ok then receiver_nom_raw else 'Boshqa kassa' end as receiver_nom,
           coalesce(s_cash,0) + coalesce(s_click,0) + coalesce(s_payme,0)
             + coalesce(s_usd,0) * coalesce(dollar_rate, v_baza_rate, 0) as jami_uzs
      from base b
     where coalesce(send_ok, false) or coalesce(recv_ok, false)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'transfer_id', v.transfer_id, 'sender_id', v.sender_id, 'receiver_id', v.receiver_id,
           'sender_nom', v.sender_nom, 'receiver_nom', v.receiver_nom, 'sent_at', v.sent_at,
           'cash', v.s_cash, 'click', v.s_click, 'payme', v.s_payme, 'usd', v.s_usd,
           'dollar_rate', v.dollar_rate, 'jami_uzs', v.jami_uzs)
           order by v.sent_at desc), '[]'::jsonb),
         coalesce(sum(v.jami_uzs), 0),
         count(*)
    into v_sent, v_jami, v_soni
    from vis v;

  -- ---- Yaqinda qabul qilingan (status = received, so'nggi 48 soat) ----
  with base2 as (
    select t.transfer_id, t.sender_id, t.receiver_id,
           coalesce(sa.name, t.sender_title)     as sender_nom_raw,
           coalesce(ra.name, t.receiver_title)   as receiver_nom_raw,
           t.sent_at, t.received_at,
           t.s_cash, t.s_click, t.s_payme, t.s_usd,
           t.c_cash, t.c_click, t.c_payme, t.c_usd, t.dollar_rate,
           (v_rejim in ('admin','all') or perm_op_key(t.sender_id)   = any(v_ids)) as send_ok,
           (v_rejim in ('admin','all') or perm_op_key(t.receiver_id) = any(v_ids)) as recv_ok
      from aros_transfer_yolda t
      left join accounts sa on sa.id = t.sender_id
      left join accounts ra on ra.id = t.receiver_id
     where t.status = 'received'
       and t.received_at >= now() - interval '48 hours'
  ),
  vis2 as (
    select b.*,
           case when send_ok then sender_nom_raw   else 'Boshqa kassa' end as sender_nom,
           case when recv_ok then receiver_nom_raw else 'Boshqa kassa' end as receiver_nom,
           ( (coalesce(c_cash,0) + coalesce(c_click,0) + coalesce(c_payme,0)
                + coalesce(c_usd,0) * coalesce(dollar_rate, v_baza_rate, 0))
           - (coalesce(s_cash,0) + coalesce(s_click,0) + coalesce(s_payme,0)
                + coalesce(s_usd,0) * coalesce(dollar_rate, v_baza_rate, 0)) ) as farq_uzs
      from base2 b
     where coalesce(send_ok, false) or coalesce(recv_ok, false)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'transfer_id', v.transfer_id, 'sender_id', v.sender_id, 'receiver_id', v.receiver_id,
           'sender_nom', v.sender_nom, 'receiver_nom', v.receiver_nom,
           'sent_at', v.sent_at, 'received_at', v.received_at,
           's_cash', v.s_cash, 's_click', v.s_click, 's_payme', v.s_payme, 's_usd', v.s_usd,
           'c_cash', v.c_cash, 'c_click', v.c_click, 'c_payme', v.c_payme, 'c_usd', v.c_usd,
           'farq_uzs', v.farq_uzs)
           order by v.received_at desc), '[]'::jsonb)
    into v_qabul
    from vis2 v;

  select max(synced_at) into v_synced from aros_transfer_yolda;

  return jsonb_build_object(
    'rows', v_sent, 'jami_uzs', coalesce(v_jami, 0), 'soni', coalesce(v_soni, 0),
    'qabul', v_qabul, 'synced_at', v_synced);
end
$yolda_royxat$;

revoke all on function yolda_royxat() from public, anon;
grant execute on function yolda_royxat() to authenticated;

comment on function yolda_royxat() is
  'Yo''ldagi (status=sent) va yaqinda qabul qilingan (48 soat) transferlar — '
  'ruxsat doirasida (yolda_korish_ok bilan bir xil qoida). Begona tomon nomi '
  '''Boshqa kassa'' bilan maskalanadi. Pul harakati yo''q — faqat SELECT.';


-- #####################################################################
-- ##  5-BO'LIM — yolda_farq(p_ids) — authenticated (jurnal uchun)     ##
-- #####################################################################
-- Ism/kod qaytarmaydi (jurnalda hisob nomi allaqachon bor) — faqat sotuvchi
-- vs tasdiqlangan summalarni solishtirish uchun xom sonlar.

create or replace function yolda_farq(p_ids text[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $yolda_farq$
  select coalesce(jsonb_agg(jsonb_build_object(
           'transfer_id', t.transfer_id, 'status', t.status,
           'sent_at', t.sent_at, 'received_at', t.received_at,
           's_cash', t.s_cash, 's_click', t.s_click, 's_payme', t.s_payme, 's_usd', t.s_usd,
           'c_cash', t.c_cash, 'c_click', t.c_click, 'c_payme', t.c_payme, 'c_usd', t.c_usd,
           'dollar_rate', t.dollar_rate)
           order by t.sent_at desc nulls last), '[]'::jsonb)
    from aros_transfer_yolda t
   where auth.uid() is not null
     and t.transfer_id = any((coalesce(p_ids, '{}'::text[]))[1:500])
     and yolda_korish_ok(t.sender_id, t.receiver_id);
$yolda_farq$;

revoke all on function yolda_farq(text[]) from public, anon;
grant execute on function yolda_farq(text[]) to authenticated;

comment on function yolda_farq(text[]) is
  'Jurnal uchun: berilgan transfer_id lar (<=500) bo''yicha sotuvchi/tasdiqlangan xom sonlar. '
  'Faqat yolda_korish_ok o''tgan qatorlar; ism/kod qaytarmaydi. auth.uid() null -> bo''sh.';


-- #####################################################################
-- ##  6-BO'LIM — PostgREST sxema keshini yangilash                    ##
-- #####################################################################

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  7-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/raise)                ##
-- #####################################################################

do $yolda_final$
declare
  v_ok boolean;
begin
  if to_regclass('public.aros_transfer_yolda') is null then
    raise exception 'YAKUNIY TEKSHIRUV: aros_transfer_yolda jadvali yaralmadi';
  end if;

  if to_regprocedure('public.yolda_korish_ok(uuid,uuid)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yolda_korish_ok(uuid,uuid) yoq';
  end if;
  if to_regprocedure('public.sync_transfer_yolda(jsonb)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: sync_transfer_yolda(jsonb) yoq';
  end if;
  if to_regprocedure('public.yolda_royxat()') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yolda_royxat() yoq';
  end if;
  if to_regprocedure('public.yolda_farq(text[])') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yolda_farq(text[]) yoq';
  end if;

  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'aros_transfer_yolda'
                    and policyname = 'aros_transfer_yolda_select') then
    raise exception 'YAKUNIY TEKSHIRUV: aros_transfer_yolda_select policy yoq';
  end if;

  select has_function_privilege('authenticated', 'public.yolda_royxat()', 'execute')
    into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun yolda_royxat() EXECUTE yoq';
  end if;

  select has_function_privilege('service_role', 'public.sync_transfer_yolda(jsonb)', 'execute')
    into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: service_role uchun sync_transfer_yolda(jsonb) EXECUTE yoq';
  end if;

  select has_function_privilege('authenticated', 'public.sync_transfer_yolda(jsonb)', 'execute')
    into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated sync_transfer_yolda(jsonb) ni chaqira olmasligi kerak edi';
  end if;

  raise notice 'PROVODKA_YOLDA.sql: hammasi joyida';
end
$yolda_final$;
