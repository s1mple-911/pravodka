-- =====================================================================
--  PROVODKA_YOLDA_TERMINAL.sql — «Yo'ldagi pul» registriga TERMINAL turi
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  #####  MUAMMO  ########################################################
--
--  PROVODKA_YOLDA.sql (2026-09-06) `aros_transfer_yolda` registrini faqat
--  cash/click/payme/usd bilan yaratdi. Aros 2026-09-09 da items[] shaklini
--  o'zgartirdi: endi to'lov turlari `document.amounts[]` massivida, va
--  `payme` o'rniga **`terminal`** kelmoqda (CLAUDE.md "AROS items[] SHAKLI
--  O'ZGARDI"). n8n «Yolda Sync» hozircha eski maydonlarni o'qigani uchun
--  10 ta yo'lda transfer (cash/dollar/terminal) kassa sahifasida 0 ko'rinadi.
--
--  #####  YECHIM  ########################################################
--
--  Registr jadvaliga `s_terminal`/`c_terminal` ustuni QO'SHILADI (mavjud
--  ustunlarga tegilmaydi). `sync_transfer_yolda`/`yolda_royxat`/`yolda_farq`
--  **create or replace** — imzo va RETURNS ANIQ SAQLANADI, tanasi
--  PROVODKA_YOLDA.sql dagi oxirgi versiyadan olinib faqat terminal
--  o'qish/yig'ish/chiqarish qismlari qo'shiladi. Eski n8n payloadda
--  `terminal` kaliti bo'lmasa 0/null deb olinadi — eski oqim buzilmaydi.
--
--  #####  FAYL TARKIBI  ##################################################
--     0-BO'LIM — old shart tekshiruvi (PROVODKA_YOLDA.sql RUN qilinganmi)
--     1-BO'LIM — `aros_transfer_yolda` ga s_terminal/c_terminal ustuni
--     2-BO'LIM — `sync_transfer_yolda(p_data)` — terminal o'qish qo'shildi
--     3-BO'LIM — `yolda_royxat()` — terminal jamiga/javobga qo'shildi
--     4-BO'LIM — `yolda_farq(p_ids)` — terminal javobga qo'shildi
--     5-BO'LIM — PostgREST sxema keshini yangilash
--     6-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/raise)
--
--  #####  ADDITIVE KAFOLATI  #############################################
--   * Hech narsa drop qilinmaydi. Ustun — faqat qo'shiladi (`add column
--     if not exists`). Funksiyalarning IMZOSI VA RETURNS turi o'zgarmaydi —
--     faqat `create or replace` bilan tanasi kengaytiriladi.
--   * Ruxsat/maskalash mantiqiga (yolda_korish_ok, RLS policy) TEGILMAYDI.
--   * Anonim `do` bloki YO'Q — har `do` bloki nomlangan teg bilan. Funksiya
--     tanasi ham nomlangan teg bilan. Izohlarda ketma-ket dollar belgi
--     yozilmagan (soxta blok xavfi — CLAUDE.md).
--
--  #####  TALAB (0-BO'LIM tekshiradi)  ###################################
--     aros_transfer_yolda, sync_transfer_yolda(jsonb),
--     yolda_royxat(), yolda_farq(text[])   — PROVODKA_YOLDA.sql
--
--  🔴 SQL'ni ASILBEK o'zi RUN qiladi. Agent bajarmaydi.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI                                 ##
-- #####################################################################

do $yolda_tr_pre$
begin
  if to_regclass('public.aros_transfer_yolda') is null then
    raise exception 'aros_transfer_yolda jadvali yoq — avval PROVODKA_YOLDA.sql ni bajaring';
  end if;
  if to_regprocedure('public.sync_transfer_yolda(jsonb)') is null then
    raise exception 'sync_transfer_yolda(jsonb) yoq — avval PROVODKA_YOLDA.sql ni bajaring';
  end if;
  if to_regprocedure('public.yolda_royxat()') is null then
    raise exception 'yolda_royxat() yoq — avval PROVODKA_YOLDA.sql ni bajaring';
  end if;
  if to_regprocedure('public.yolda_farq(text[])') is null then
    raise exception 'yolda_farq(text[]) yoq — avval PROVODKA_YOLDA.sql ni bajaring';
  end if;
end
$yolda_tr_pre$;


-- #####################################################################
-- ##  1-BO'LIM — aros_transfer_yolda: s_terminal / c_terminal          ##
-- #####################################################################
-- s_terminal — s_cash/s_click/s_payme bilan bir xil naqsh (not null default 0).
-- c_terminal — c_cash/c_click/c_payme bilan bir xil naqsh (null, received'gacha).

alter table aros_transfer_yolda
  add column if not exists s_terminal numeric not null default 0;
alter table aros_transfer_yolda
  add column if not exists c_terminal numeric;


-- #####################################################################
-- ##  2-BO'LIM — sync_transfer_yolda(p_data) — terminal o'qish         ##
-- #####################################################################
-- Diff PROVODKA_YOLDA.sql ga nisbatan: v_s_terminal/v_c_terminal e'lon
-- qilinadi, seller/confirmed obyektidan 'terminal' kaliti o'qiladi (yo'q
-- bo'lsa 0/null), insert/update ustunlar ro'yxatiga qo'shiladi. Boshqa
-- hech narsa o'zgarmagan (service_role tekshiruvi, advisory lock, sweep).

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
  v_s_terminal      numeric;
  v_s_usd           numeric;
  v_c_cash          numeric;
  v_c_click         numeric;
  v_c_payme         numeric;
  v_c_terminal      numeric;
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

      v_seller     := coalesce(v_el -> 'seller', '{}'::jsonb);
      v_s_cash     := coalesce((v_seller ->> 'cash')::numeric, 0);
      v_s_click    := coalesce((v_seller ->> 'click')::numeric, 0);
      v_s_payme    := coalesce((v_seller ->> 'payme')::numeric, 0);
      -- 🔴 terminal (2026-09-12): eski n8n payloadda kalit yo'q bo'lsa 0 — eski oqim buzilmaydi.
      v_s_terminal := coalesce((v_seller ->> 'terminal')::numeric, 0);
      v_s_usd      := coalesce((v_seller ->> 'dollar_usd')::numeric, 0);

      if v_status = 'received'
         and jsonb_typeof(v_el -> 'confirmed') = 'object' then
        v_confirmed  := v_el -> 'confirmed';
        v_c_cash     := coalesce((v_confirmed ->> 'cash')::numeric, 0);
        v_c_click    := coalesce((v_confirmed ->> 'click')::numeric, 0);
        v_c_payme    := coalesce((v_confirmed ->> 'payme')::numeric, 0);
        v_c_terminal := coalesce((v_confirmed ->> 'terminal')::numeric, 0);
        v_c_usd      := coalesce((v_confirmed ->> 'dollar_usd')::numeric, 0);
      else
        v_c_cash     := null;
        v_c_click    := null;
        v_c_payme    := null;
        v_c_terminal := null;
        v_c_usd      := null;
      end if;

      v_rate := nullif(v_el ->> 'dollar_rate', '')::numeric;
      v_resp := nullif(btrim(coalesce(v_el ->> 'responsible', '')), '');

      insert into aros_transfer_yolda(
        transfer_id, status, sender_id, receiver_id, sender_title, receiver_title,
        sent_at, received_at, s_cash, s_click, s_payme, s_terminal, s_usd,
        c_cash, c_click, c_payme, c_terminal, c_usd, dollar_rate, responsible, synced_at)
      values (
        v_id, v_status,
        case when coalesce((v_sender_acc   ->> 'ok')::boolean, false) then (v_sender_acc   ->> 'id')::uuid else null end,
        case when coalesce((v_receiver_acc ->> 'ok')::boolean, false) then (v_receiver_acc ->> 'id')::uuid else null end,
        v_sender_title, v_receiver_title, v_sent_at, v_received_at,
        v_s_cash, v_s_click, v_s_payme, v_s_terminal, v_s_usd,
        v_c_cash, v_c_click, v_c_payme, v_c_terminal, v_c_usd, v_rate, v_resp, now())
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
             s_terminal     = excluded.s_terminal,
             s_usd          = excluded.s_usd,
             c_cash         = excluded.c_cash,
             c_click        = excluded.c_click,
             c_payme        = excluded.c_payme,
             c_terminal     = excluded.c_terminal,
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

comment on function sync_transfer_yolda(jsonb) is
  'service_role ONLY (n8n «Aros Provodka - Yolda Sync»). aros_transfer_yolda ni upsert qiladi. '
  'PUL HARAKATI YO''Q — entry/entry_line ga tegilmaydi. Payloadda yo''q qolgan avvalgi '
  '''sent'' qatorlar ''nomalum'' ga o''tkaziladi. terminal (2026-09-12): seller/confirmed '
  'obyektida ''terminal'' kaliti bo''lmasa 0/null.';


-- #####################################################################
-- ##  3-BO'LIM — yolda_royxat() — terminal jamiga/javobga qo'shildi    ##
-- #####################################################################
-- Diff PROVODKA_YOLDA.sql ga nisbatan: base/base2 CTE'larga t.s_terminal
-- (va base2 ga t.c_terminal) qo'shildi, jami_uzs/farq_uzs formulasiga
-- s_terminal/c_terminal qo'shildi, javob JSON'ga 'terminal' (rows) va
-- 's_terminal'/'c_terminal' (qabul) kalitlari qo'shildi. Qolgani o'zgarmagan.

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
           t.sent_at, t.s_cash, t.s_click, t.s_payme, t.s_terminal, t.s_usd, t.dollar_rate,
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
           coalesce(s_cash,0) + coalesce(s_click,0) + coalesce(s_payme,0) + coalesce(s_terminal,0)
             + coalesce(s_usd,0) * coalesce(dollar_rate, v_baza_rate, 0) as jami_uzs
      from base b
     where coalesce(send_ok, false) or coalesce(recv_ok, false)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'transfer_id', v.transfer_id, 'sender_id', v.sender_id, 'receiver_id', v.receiver_id,
           'sender_nom', v.sender_nom, 'receiver_nom', v.receiver_nom, 'sent_at', v.sent_at,
           'cash', v.s_cash, 'click', v.s_click, 'payme', v.s_payme, 'terminal', v.s_terminal, 'usd', v.s_usd,
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
           t.s_cash, t.s_click, t.s_payme, t.s_terminal, t.s_usd,
           t.c_cash, t.c_click, t.c_payme, t.c_terminal, t.c_usd, t.dollar_rate,
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
           ( (coalesce(c_cash,0) + coalesce(c_click,0) + coalesce(c_payme,0) + coalesce(c_terminal,0)
                + coalesce(c_usd,0) * coalesce(dollar_rate, v_baza_rate, 0))
           - (coalesce(s_cash,0) + coalesce(s_click,0) + coalesce(s_payme,0) + coalesce(s_terminal,0)
                + coalesce(s_usd,0) * coalesce(dollar_rate, v_baza_rate, 0)) ) as farq_uzs
      from base2 b
     where coalesce(send_ok, false) or coalesce(recv_ok, false)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'transfer_id', v.transfer_id, 'sender_id', v.sender_id, 'receiver_id', v.receiver_id,
           'sender_nom', v.sender_nom, 'receiver_nom', v.receiver_nom,
           'sent_at', v.sent_at, 'received_at', v.received_at,
           's_cash', v.s_cash, 's_click', v.s_click, 's_payme', v.s_payme, 's_terminal', v.s_terminal, 's_usd', v.s_usd,
           'c_cash', v.c_cash, 'c_click', v.c_click, 'c_payme', v.c_payme, 'c_terminal', v.c_terminal, 'c_usd', v.c_usd,
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

comment on function yolda_royxat() is
  'Yo''ldagi (status=sent) va yaqinda qabul qilingan (48 soat) transferlar — '
  'ruxsat doirasida (yolda_korish_ok bilan bir xil qoida). Begona tomon nomi '
  '''Boshqa kassa'' bilan maskalanadi. Pul harakati yo''q — faqat SELECT. '
  'terminal (2026-09-12): jami_uzs/farq_uzs hisobiga qo''shildi.';


-- #####################################################################
-- ##  4-BO'LIM — yolda_farq(p_ids) — terminal javobga qo'shildi        ##
-- #####################################################################
-- Diff PROVODKA_YOLDA.sql ga nisbatan: jsonb_build_object ga
-- 's_terminal'/'c_terminal' kalitlari qo'shildi. Qolgani o'zgarmagan.

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
           's_cash', t.s_cash, 's_click', t.s_click, 's_payme', t.s_payme, 's_terminal', t.s_terminal, 's_usd', t.s_usd,
           'c_cash', t.c_cash, 'c_click', t.c_click, 'c_payme', t.c_payme, 'c_terminal', t.c_terminal, 'c_usd', t.c_usd,
           'dollar_rate', t.dollar_rate)
           order by t.sent_at desc nulls last), '[]'::jsonb)
    from aros_transfer_yolda t
   where auth.uid() is not null
     and t.transfer_id = any((coalesce(p_ids, '{}'::text[]))[1:500])
     and yolda_korish_ok(t.sender_id, t.receiver_id);
$yolda_farq$;

comment on function yolda_farq(text[]) is
  'Jurnal uchun: berilgan transfer_id lar (<=500) bo''yicha sotuvchi/tasdiqlangan xom sonlar. '
  'Faqat yolda_korish_ok o''tgan qatorlar; ism/kod qaytarmaydi. auth.uid() null -> bo''sh. '
  'terminal (2026-09-12): javobga s_terminal/c_terminal qo''shildi.';


-- #####################################################################
-- ##  5-BO'LIM — PostgREST sxema keshini yangilash                    ##
-- #####################################################################

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  6-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/raise)                ##
-- #####################################################################

do $yolda_tr_final$
declare
  v_ok boolean;
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'aros_transfer_yolda' and column_name = 's_terminal'
  ) then
    raise exception 'YAKUNIY TEKSHIRUV: s_terminal ustuni yaralmadi';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'aros_transfer_yolda' and column_name = 'c_terminal'
  ) then
    raise exception 'YAKUNIY TEKSHIRUV: c_terminal ustuni yaralmadi';
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

  select has_function_privilege('authenticated', 'public.yolda_royxat()', 'execute')
    into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun yolda_royxat() EXECUTE yoq';
  end if;

  select has_function_privilege('authenticated', 'public.yolda_farq(text[])', 'execute')
    into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun yolda_farq(text[]) EXECUTE yoq';
  end if;

  raise notice 'PROVODKA_YOLDA_TERMINAL.sql: hammasi joyida';
end
$yolda_tr_final$;
