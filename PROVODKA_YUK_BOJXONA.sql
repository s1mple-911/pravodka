-- =====================================================================
--  PROVODKA_YUK_BOJXONA.sql
--  Aros yuk BOJXONA limiti — yuk_tannarx_qosh() ustiga qo'yiladigan chegara
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  #####  NIMA UCHUN  ###################################################
--
--  Yukka (`yuk_tannarx`, PROVODKA_YUK_TANNARX.sql) qoshiladigan qoshimcha
--  tannarx (yol puli, bojxona, valyuta farqi...) hech narsa bilan
--  cheklanmagan edi. Endi Aros'dagi haqiqiy bojxona (+ yol foizi) summasi
--  bir chegara boladi: shu yukka jami qoshilgan tannarx o''sha chegaradan
--  OSHOLMAYDI. Manba — Aros product-income detail API (n8n «Aros Provodka
--  - Yuk Bojxona Sync», N8N_YUK_BOJXONA_SYNC.js), har 30 daqiqada.
--
--  #####  🔴 PUL HARAKATI YOQ (avvalgi fayl bilan bir xil qaror)  #######
--
--  Bu fayl ham `entry`/`entry_line` ga hech narsa yozmaydi — faqat
--  REGISTR (`aros_yuk_bojxona`) va shu registrni tekshiradigan LIMIT
--  qatlami. Balans/PnL/cashflow raqamlari O'ZGARMAYDI.
--
--  #####  ADDITIVE  ####################################################
--
--  Yangi: jadval `aros_yuk_bojxona`; funksiya `yuk_bojxona_korish_ok`,
--  `_yuk_bojxona_fare_uzs` (ICHKI), `sync_yuk_bojxona`, `yuk_bojxona_jami`.
--  Yagona qayta e'lon qilinadigan mavjud funksiya — `yuk_tannarx_qosh`
--  (PROVODKA_YUK_TANNARX.sql 5-BOLIM): IMZO AYNAN SAQLANADI
--  (`p_data jsonb, p_sabab_id int, p_izoh text default null,
--   p_kalit text default null`), tanasi BAYT-MA-BAYT o'sha versiyadan
--  olingan (bu — yagona joyda e'lon qilingan versiya, boshqa faylda
--  takrori yoq), orasiga faqat LIMIT TEKSHIRUVI (1.5-BOSQICH) qoshildi.
--
--  #####  FAYL TARKIBI  ##################################################
--     0-BOLIM  — old shart tekshiruvi (faqat select)
--     1-BOLIM  — yuk_bojxona_korish_ok() — RLS qorovuli
--     2-BOLIM  — jadval aros_yuk_bojxona (+ indeks + RLS)
--     3-BOLIM  — _yuk_bojxona_fare_uzs() — ICHKI, valyutadan somga
--     4-BOLIM  — sync_yuk_bojxona(p_data) — service_role ONLY
--     5-BOLIM  — yuk_bojxona_jami(p_ids) — authenticated
--     6-BOLIM  — yuk_tannarx_qosh() QAYTA E'LON — limit qoshildi
--     7-BOLIM  — TEKSHIRUVLAR (faqat select)
--     8-BOLIM  — notify pgrst (PostgREST sxema keshini yangilash)
--     9-BOLIM  — ROLLBACK (izohda, qolda ishlatiladi)
--
--  TALAB (0-BOLIM tekshiradi): PROVODKA_YUK_TANNARX.sql (yuk_tannarx,
--  yuk_tannarx_sabab, yuk_tannarx_ruxsat, yuk_tannarx_qosh) avval RUN
--  qilingan bolishi SHART — bu fayl ustiga quriladi.
--
--  ⚠️ TARTIB: 2-BOLIM (jadval) 6-BOLIMdan (funksiya, %ROWTYPE ishlatadi)
--     OLDIN turishi SHART — aks holda `create or replace function`
--     "relation aros_yuk_bojxona does not exist" bilan yiqiladi
--     (yuk_tannarx_sabab bilan bir xil naqsh — asl faylda ham shunday).
-- =====================================================================


-- #####################################################################
--  0-BOLIM — OLD SHART TEKSHIRUVI. HECH NARSA YOZMAYDI.
-- #####################################################################

select 'yuk_tannarx jadvali' as tekshiruv,
       case when to_regclass('public.yuk_tannarx') is not null
            then '✅ OK' else '❌ YOQ — avval PROVODKA_YUK_TANNARX.sql ni RUN qiling' end as natija
union all
select 'yuk_tannarx_sabab jadvali',
       case when to_regclass('public.yuk_tannarx_sabab') is not null
            then '✅ OK' else '❌ YOQ — avval PROVODKA_YUK_TANNARX.sql ni RUN qiling' end
union all
select 'yuk_tannarx_ruxsat()',
       case when to_regprocedure('public.yuk_tannarx_ruxsat()') is not null
            then '✅ OK' else '❌ YOQ — avval PROVODKA_YUK_TANNARX.sql ni RUN qiling' end
union all
select 'yuk_tannarx_qosh(jsonb,int,text,text) — eski versiya',
       case when to_regprocedure('public.yuk_tannarx_qosh(jsonb,int,text,text)') is not null
            then '✅ OK — 6-BOLIM shu ustiga yozadi'
            else '❌ YOQ — avval PROVODKA_YUK_TANNARX.sql ni RUN qiling' end
union all
select 'is_admin()',
       case when to_regprocedure('public.is_admin()') is not null
            then '✅ OK' else '❌ YOQ — ruxsat tizimi asosiy migratsiyasi kerak' end
union all
select 'conv_baza_kurs(text) (ixtiyoriy)',
       case when to_regprocedure('public.conv_baza_kurs(text)') is not null
            then '✅ BOR — yol foizi (valyutada) somga aylantiriladi'
            else '⚠️ YOQ — yol foizi limitga qoshilmaydi (faqat bojxona hisobga olinadi)' end
union all
select 'sorov_page_ok(text) (ixtiyoriy)',
       case when to_regprocedure('public.sorov_page_ok(text)') is not null
            then '✅ BOR — jurnal/yuklar sahifasi ham korish huquqi beradi'
            else '⚠️ YOQ — faqat tannarx sahifasi ruxsati/admin korishi mumkin' end;

-- 0.2 Bu fayl ilgari RUN qilinganmi
select 'aros_yuk_bojxona' as obyekt,
       case when to_regclass('public.aros_yuk_bojxona') is not null
            then 'allaqachon bor' else 'yoq (yangi yaratiladi)' end as holat;


-- #####################################################################
--  1-BOLIM — yuk_bojxona_korish_ok() — RLS uchun qorovul
-- #####################################################################
--  admin YOKI tannarx sahifasi ruxsati (yuk_tannarx_ruxsat — service_role
--  uchun ham true qaytaradi) YOKI jurnal/yuklar sahifasi ruxsati
--  (sorov_page_ok — qarz_page_ok bilan bir xil naqsh: u authenticated'dan
--  revoke qilingan, RLS USING ichida to'gridan chaqirib bolmaydi, shuning
--  uchun shu ALOHIDA qobiq authenticated'ga ochiladi).

-- ⬇⬇⬇  1-BOLIM: SHU QATORDAN 1-BOLIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function yuk_bojxona_korish_ok()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v boolean;
begin
  if coalesce(yuk_tannarx_ruxsat(), false) then
    return true;
  end if;

  if is_admin() then
    return true;
  end if;

  if to_regprocedure('public.sorov_page_ok(text)') is not null then
    execute 'select sorov_page_ok($1)' into v using 'jurnal';
    if coalesce(v, false) then
      return true;
    end if;
    execute 'select sorov_page_ok($1)' into v using 'yuklar';
    if coalesce(v, false) then
      return true;
    end if;
  end if;

  return false;
end
$fn$;

revoke all on function yuk_bojxona_korish_ok() from public, anon;
grant execute on function yuk_bojxona_korish_ok() to authenticated, service_role;

comment on function yuk_bojxona_korish_ok() is
  'RLS qorovuli (aros_yuk_bojxona): admin YOKI tannarx sahifasi ruxsati YOKI jurnal/yuklar sahifasi ruxsati.';
-- ⬆⬆⬆  1-BOLIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  2-BOLIM — jadval aros_yuk_bojxona
-- #####################################################################
--  `yuk_id` — Aros product-income id (PROVODKA_YUK_TANNARX.sql dagi
--  yuk_tannarx.yuk_id bilan bir xil manoda). n8n har 30 daqiqada
--  upsert qiladi (`sync_yuk_bojxona`, 4-BOLIM).

-- ⬇⬇⬇  2-BOLIM: SHU QATORDAN 2-BOLIM oxirigacha BELGILANG  ⬇⬇⬇
create table if not exists aros_yuk_bojxona (
  yuk_id          integer     primary key,
  currency        text,
  document_price  numeric,
  qty_jami        integer,
  items_n         integer,
  bojxona_uzs     numeric     not null default 0,
  fare_cur        numeric     not null default 0,
  fare_percent    numeric,
  doc_custom_uzs  numeric,
  rejim           text        check (rejim in ('item', 'doc', 'yoq')),
  status          text,
  delivery_status text,
  post_at         timestamptz,
  synced_at       timestamptz not null default now(),
  created_at      timestamptz not null default now()
);

comment on table aros_yuk_bojxona is
  'Aros yukining bojxona (+ yol foizi) limiti — n8n «Aros Provodka - Yuk Bojxona Sync» '
  'har 30 daqiqada sync_yuk_bojxona() orqali toldiradi. yuk_tannarx_qosh() shu limitdan '
  'oshirib yozishni tosadi. PUL HARAKATI YOQ — faqat registr.';
comment on column aros_yuk_bojxona.bojxona_uzs is
  'Somda. product_income_items dan yigilgan: Σ custom_clearance_uzs * quantity (yoki doc rejimida doc_custom_uzs * qty_jami).';
comment on column aros_yuk_bojxona.fare_cur is
  'Yol foizi, HUJJAT VALYUTASIDA (Σ (price_after_fare_percent - income_price) * quantity). Somga aylantirish 3-BOLIMda.';
comment on column aros_yuk_bojxona.rejim is
  'item = har tovar alohida bojxonasi bor, doc = hujjat darajasidagi custom_clearance_uzs zaxira sifatida ishlatilgan, yoq = malumot topilmadi (limit yoq).';

create index if not exists aros_yuk_bojxona_status_idx  on aros_yuk_bojxona(status);
create index if not exists aros_yuk_bojxona_synced_idx  on aros_yuk_bojxona(synced_at);

alter table aros_yuk_bojxona enable row level security;

drop policy if exists aros_yuk_bojxona_sel on aros_yuk_bojxona;
create policy aros_yuk_bojxona_sel on aros_yuk_bojxona
  for select to authenticated
  using (yuk_bojxona_korish_ok());

revoke all on aros_yuk_bojxona from public, anon;
grant select on aros_yuk_bojxona to authenticated;
-- ⬆⬆⬆  2-BOLIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  3-BOLIM — _yuk_bojxona_fare_uzs() — ICHKI, valyutadan somga
-- #####################################################################
--  Yol foizi (`fare_cur`, hujjat valyutasida) ni somga aylantiradi.
--  `conv_baza_kurs(text)` yoq yoki kurs topilmasa — 0 qaytadi (yol foizi
--  limitga qoshilmaydi, faqat bojxona hisobga olinadi — fail-safe).
--  ⚠️ Hozirgi kurs ishlatiladi (tarixiy emas) — bu registr/limit uchun
--  yetarli aniqlik, buxgalteriya yozuviga tegishli emas.

-- ⬇⬇⬇  3-BOLIM: SHU QATORDAN 3-BOLIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function _yuk_bojxona_fare_uzs(p_currency text, p_fare_cur numeric)
returns numeric
language plpgsql
stable
set search_path = public
as $fn$
declare
  v_rate numeric;
begin
  if p_fare_cur is null or p_fare_cur = 0 then
    return 0;
  end if;
  if p_currency is null or to_regprocedure('public.conv_baza_kurs(text)') is null then
    return 0;
  end if;

  begin
    execute 'select conv_baza_kurs($1)' into v_rate using p_currency;
  exception when others then
    v_rate := null;
  end;

  if v_rate is null then
    return 0;
  end if;

  return round(p_fare_cur * v_rate, 2);
end
$fn$;

revoke all on function _yuk_bojxona_fare_uzs(text, numeric) from public, anon, authenticated;

comment on function _yuk_bojxona_fare_uzs(text, numeric) is
  'ICHKI: yol foizini (hujjat valyutasida) somga aylantiradi (conv_baza_kurs). Kurs topilmasa 0.';
-- ⬆⬆⬆  3-BOLIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  4-BOLIM — sync_yuk_bojxona(p_data) — service_role ONLY
-- #####################################################################
--  IMZO: sync_yuk_bojxona(p_data jsonb) returns jsonb
--  Naqsh — PROVODKA_YOLDA.sql `sync_transfer_yolda` bilan AYNAN bir xil:
--  auth.uid() null va JWT role='service_role' tekshiruvi, advisory lock,
--  har element ALOHIDA exception blokida (bittasi yiqilsa qolganlari
--  yoziladi, sabab `ogoh` da).
--
--  p_data = {"yuklar":[{"yuk_id":2794,"currency":"CHY","document_price":5015,
--            "qty_jami":9,"items_n":9,"bojxona_uzs":600000,"fare_cur":0,
--            "fare_percent":0,"doc_custom_uzs":null,"rejim":"item",
--            "status":"posted","delivery_status":"accepted",
--            "post_at":"2026-09-04T15:32:54+05:00"}, ...]}
--  (yoki tog'ridan massiv — {transferlar} bilan bir xil moslashuvchanlik).
--
--  QAYTISHI: {ok:true, yozildi:N, yangilandi:M, ogoh:[...]}

-- ⬇⬇⬇  4-BOLIM: SHU QATORDAN 4-BOLIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function sync_yuk_bojxona(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_role       text;
  v_list       jsonb;
  v_el         jsonb;

  v_yuk        integer;
  v_currency   text;
  v_doc_price  numeric;
  v_qty        integer;
  v_items_n    integer;
  v_bojxona    numeric;
  v_fare_cur   numeric;
  v_fare_pct   numeric;
  v_doc_custom numeric;
  v_rejim      text;
  v_status     text;
  v_delivery   text;
  v_post_txt   text;
  v_post_at    timestamptz;

  v_was_insert boolean;
  n_yozildi    int := 0;
  n_yangilandi int := 0;
  v_ogoh       jsonb := '[]'::jsonb;
begin
  -- ---- service_role ONLY (sync_transfer_yolda bilan bir xil naqsh) ----
  if auth.uid() is not null then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is not null and v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('sync_yuk_bojxona'));

  if p_data is null then
    return jsonb_build_object('ok', false, 'error', 'p_data bosh');
  end if;

  if jsonb_typeof(p_data) = 'object' and p_data ? 'yuklar' then
    v_list := p_data -> 'yuklar';
  else
    v_list := p_data;
  end if;

  if jsonb_typeof(v_list) is distinct from 'array' then
    return jsonb_build_object('ok', false,
      'error', 'JSON massiv kutilgan edi (yoki {yuklar:[...]}), keldi: '
               || coalesce(jsonb_typeof(v_list), 'null'));
  end if;

  for v_el in select * from jsonb_array_elements(v_list)
  loop
    begin
      v_yuk := nullif(v_el ->> 'yuk_id', '')::integer;
      if v_yuk is null then
        v_ogoh := v_ogoh || jsonb_build_object('yuk_id', null, 'sabab', 'yuk_id yoq');
        continue;
      end if;

      v_currency   := nullif(btrim(coalesce(v_el ->> 'currency', '')), '');
      v_doc_price  := nullif(v_el ->> 'document_price', '')::numeric;
      v_qty        := nullif(v_el ->> 'qty_jami', '')::integer;
      v_items_n    := nullif(v_el ->> 'items_n', '')::integer;
      v_bojxona    := coalesce(nullif(v_el ->> 'bojxona_uzs', '')::numeric, 0);
      v_fare_cur   := coalesce(nullif(v_el ->> 'fare_cur', '')::numeric, 0);
      v_fare_pct   := nullif(v_el ->> 'fare_percent', '')::numeric;
      v_doc_custom := nullif(v_el ->> 'doc_custom_uzs', '')::numeric;

      v_rejim := nullif(btrim(coalesce(v_el ->> 'rejim', '')), '');
      if v_rejim is null or v_rejim not in ('item', 'doc') then
        v_rejim := 'yoq';
      end if;

      v_status   := nullif(btrim(coalesce(v_el ->> 'status', '')), '');
      v_delivery := nullif(btrim(coalesce(v_el ->> 'delivery_status', '')), '');
      v_post_txt := nullif(btrim(coalesce(v_el ->> 'post_at', '')), '');
      v_post_at  := case when v_post_txt is not null then v_post_txt::timestamptz else null end;

      insert into aros_yuk_bojxona(
        yuk_id, currency, document_price, qty_jami, items_n, bojxona_uzs, fare_cur,
        fare_percent, doc_custom_uzs, rejim, status, delivery_status, post_at, synced_at)
      values (
        v_yuk, v_currency, v_doc_price, v_qty, v_items_n, v_bojxona, v_fare_cur,
        v_fare_pct, v_doc_custom, v_rejim, v_status, v_delivery, v_post_at, now())
      on conflict (yuk_id) do update
         set currency        = excluded.currency,
             document_price  = excluded.document_price,
             qty_jami        = excluded.qty_jami,
             items_n         = excluded.items_n,
             bojxona_uzs     = excluded.bojxona_uzs,
             fare_cur        = excluded.fare_cur,
             fare_percent    = excluded.fare_percent,
             doc_custom_uzs  = excluded.doc_custom_uzs,
             rejim           = excluded.rejim,
             status          = excluded.status,
             delivery_status = excluded.delivery_status,
             post_at         = excluded.post_at,
             synced_at       = now()
      returning (xmax = 0) into v_was_insert;

      if v_was_insert then
        n_yozildi := n_yozildi + 1;
      else
        n_yangilandi := n_yangilandi + 1;
      end if;

    exception when others then
      v_ogoh := v_ogoh || jsonb_build_object('yuk_id', v_yuk, 'sabab', sqlerrm);
      continue;
    end;
  end loop;

  return jsonb_build_object('ok', true, 'yozildi', n_yozildi,
    'yangilandi', n_yangilandi, 'ogoh', v_ogoh);
end
$fn$;

revoke all on function sync_yuk_bojxona(jsonb) from public, anon, authenticated;
grant execute on function sync_yuk_bojxona(jsonb) to service_role;

comment on function sync_yuk_bojxona(jsonb) is
  'service_role ONLY (n8n «Aros Provodka - Yuk Bojxona Sync»). aros_yuk_bojxona ni upsert qiladi. '
  'PUL HARAKATI YOQ. yuk_tannarx_qosh() shu jadvaldagi limitni tekshiradi.';
-- ⬆⬆⬆  4-BOLIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  5-BOLIM — yuk_bojxona_jami(p_ids) — authenticated
-- #####################################################################
--  IMZO: yuk_bojxona_jami(p_ids integer[]) returns jsonb
--  Faqat jadvalda BOR id'lar kalit boladi (yolq id — kalit bolmaydi).
--  Ruxsat: admin YOKI tannarx sahifasi ruxsati. auth.uid() null
--  (service_role) — o'tadi (yuk_tannarx_ruxsat shunday). Aks holda
--  ruxsat yoq bo'lsa bosh obyekt {} (fail-closed).
--
--  QAYTISHI: {"<yuk_id>": {bojxona_uzs, fare_uzs, limit_uzs, qoshilgan_uzs,
--             qoldi_uzs, rejim, currency, synced_at}, ...}

-- ⬇⬇⬇  5-BOLIM: SHU QATORDAN 5-BOLIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function yuk_bojxona_jami(p_ids integer[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is not null
     and not (coalesce(yuk_tannarx_ruxsat(), false) or coalesce(is_admin(), false)) then
    return '{}'::jsonb;
  end if;

  return coalesce(
    (select jsonb_object_agg(b.yuk_id::text, jsonb_build_object(
               'bojxona_uzs',   coalesce(b.bojxona_uzs, 0),
               'fare_uzs',      _yuk_bojxona_fare_uzs(b.currency, b.fare_cur),
               'limit_uzs',     coalesce(b.bojxona_uzs, 0) + _yuk_bojxona_fare_uzs(b.currency, b.fare_cur),
               'qoshilgan_uzs', coalesce((select sum(t.summa_uzs) from yuk_tannarx t
                                            where t.yuk_id = b.yuk_id and not t.is_deleted), 0),
               'qoldi_uzs',     (coalesce(b.bojxona_uzs, 0) + _yuk_bojxona_fare_uzs(b.currency, b.fare_cur))
                                  - coalesce((select sum(t.summa_uzs) from yuk_tannarx t
                                               where t.yuk_id = b.yuk_id and not t.is_deleted), 0),
               'rejim',         b.rejim,
               'currency',      b.currency,
               'synced_at',     b.synced_at))
       from aros_yuk_bojxona b
      where b.yuk_id = any(coalesce(p_ids, '{}'::integer[]))
    ), '{}'::jsonb);
end
$fn$;

revoke all on function yuk_bojxona_jami(integer[]) from public, anon;
grant execute on function yuk_bojxona_jami(integer[]) to authenticated;

comment on function yuk_bojxona_jami(integer[]) is
  'Har yuk uchun Aros bojxona limiti (som) + qoshilgan/qoldi. Faqat jadvalda bor yuk_id lar kalit boladi. '
  'Ruxsat yoq bolsa (auth.uid() bor, lekin tannarx/admin emas) bosh obyekt {} (fail-closed).';
-- ⬆⬆⬆  5-BOLIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  6-BOLIM — yuk_tannarx_qosh() QAYTA E'LON — Aros BOJXONA LIMITI
-- #####################################################################
--  IMZO O'ZGARMAGAN: yuk_tannarx_qosh(p_data jsonb, p_sabab_id int,
--                     p_izoh text default null, p_kalit text default null)
--                     returns jsonb
--  Tanasi BAYT-MA-BAYT PROVODKA_YUK_TANNARX.sql 5-BOLIM dan (yagona
--  mavjud versiya). Yagona qoshilgan qism — 1-BOSQICH (tekshirish/
--  birlashtirish) bilan 2-BOSQICH (yozish) orasidagi "1.5-BOSQICH".
--
--  Limit = aros_yuk_bojxona.bojxona_uzs + fare_uzs (valyutadan somga
--  _yuk_bojxona_fare_uzs bilan aylantirilgan). Shu limitdan
--  (mavjud qoshilgan + shu chaqiruvdagi summa) OSHSA — BUTUN chaqiruv
--  {ok:false, kod:'limit', ...} bilan qaytadi, HECH NARSA YOZILMAYDI
--  (tekshiruv insertlardan OLDIN, hamma element uchun bir martada).
--
--  aros_yuk_bojxona jadvali yoq (bu fayl RUN qilinmagan) yoki shu yuk
--  uchun qator yoq bolsa — LIMIT YOQ (eski xatti-harakat saqlanadi),
--  faqat ogohlantirishga "Aros bojxona malumoti hali sinxron bolmagan"
--  qoshiladi.

-- ⬇⬇⬇  6-BOLIM: SHU QATORDAN 6-BOLIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function yuk_tannarx_qosh(p_data jsonb, p_sabab_id int,
                                            p_izoh text default null,
                                            p_kalit text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_who    text;
  v_uid    uuid := auth.uid();
  v_kalit  text;
  v_sabab  yuk_tannarx_sabab;
  el       jsonb;
  v_yuk    integer;
  v_sum    numeric;
  v_izoh   text;
  v_xato   text;
  v_id     bigint;
  v_ok     int   := 0;
  v_skip   int   := 0;
  v_dup    int   := 0;
  v_rows   jsonb := '[]'::jsonb;
  v_warn   jsonb := '[]'::jsonb;
  v_map    jsonb := '{}'::jsonb;
  v_key    text;
  v_val    jsonb;
  v_n      int;
  -- ---- Aros bojxona limiti uchun (6-BOLIM, PROVODKA_YUK_BOJXONA.sql) ----
  v_bar_jadval boolean;
  v_boj        aros_yuk_bojxona%rowtype;
  v_limit_uzs  numeric;
  v_qoshilgan  numeric;
  v_yangi_jami numeric;
begin
  if not yuk_tannarx_ruxsat() then
    return jsonb_build_object('ok', false, 'error', 'Tannarx kiritish ruxsati yoq');
  end if;

  if p_data is null or jsonb_typeof(p_data) <> 'array' then
    return jsonb_build_object('ok', false, 'error',
      'p_data massiv bolishi kerak: [{"yuk_id":1204,"summa":5000000}]');
  end if;

  v_n := jsonb_array_length(p_data);
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'Birorta yuk tanlanmagan');
  end if;
  if v_n > 500 then
    return jsonb_build_object('ok', false, 'error',
      'Bir marta eng kopi 500 ta yuk. Hozir: ' || v_n);
  end if;

  select * into v_sabab from yuk_tannarx_sabab where id = p_sabab_id;
  if v_sabab.id is null then
    return jsonb_build_object('ok', false, 'error', 'Sabab topilmadi');
  end if;
  if not v_sabab.is_active then
    return jsonb_build_object('ok', false, 'error',
      'Bu sabab passiv qilingan: ' || v_sabab.nom);
  end if;

  -- ===== IDEMPOTENTLIK: shu kalit bilan allaqachon yozilganmi =====
  v_kalit := nullif(btrim(coalesce(p_kalit, '')), '');
  if v_kalit is not null then
    if length(v_kalit) > 80 then
      return jsonb_build_object('ok', false, 'error', 'p_kalit juda uzun (80 belgigacha)');
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
             'yuk_id', t.yuk_id, 'id', t.id, 'summa_uzs', t.summa_uzs)
             order by t.id), '[]'::jsonb)
      into v_rows
      from yuk_tannarx t
     where t.kalit = v_kalit and not t.is_deleted;

    if jsonb_array_length(v_rows) > 0 then
      return jsonb_build_object(
        'ok',              true,
        'takror',          true,
        'qoshildi',        0,
        'otkazildi',       0,
        'birlashtirildi',  0,
        'sabab',           v_sabab.nom,
        'qatorlar',        v_rows,
        'ogohlantirishlar',
          jsonb_build_array('Bu saqlash allaqachon bajarilgan — qayta yozilmadi'));
    end if;
    v_rows := '[]'::jsonb;
  end if;

  select coalesce(full_name, 'foydalanuvchi') into v_who
    from profiles where id = v_uid;
  v_who := coalesce(v_who, 'tizim');

  -- ===== 1-BOSQICH: tekshirish + bir xil yuk_id larni birlashtirish =====
  for el in select value from jsonb_array_elements(p_data) loop
    v_yuk  := null;
    v_sum  := null;
    v_xato := null;

    -- Cast xatolari butun sorovni yiqitmasin. Har maydon ALOHIDA tekshiriladi,
    -- aks holda buzuq `summa` yuzasidan "yuk_id notogri" deb yozilardi.
    begin
      v_yuk := nullif(el ->> 'yuk_id', '')::integer;
    exception when others then
      v_xato := 'yuk_id';
    end;
    begin
      v_sum := nullif(el ->> 'summa', '')::numeric;
    exception when others then
      v_xato := coalesce(v_xato || ' va summa', 'summa');
    end;

    v_izoh := nullif(btrim(coalesce(el ->> 'izoh', p_izoh, '')), '');

    if v_xato is not null then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('notogri qiymat (' || v_xato || '): '
                                   || coalesce(el::text, 'null'));
      continue;
    end if;

    if v_yuk is null then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('yuk_id yoq: ' || coalesce(el::text, 'null'));
      continue;
    end if;

    if v_sum is null or v_sum <= 0 then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('yuk ' || v_yuk || ': summa 0 yoki manfiy — otkazildi');
      continue;
    end if;

    -- Yaxlitlash TEKSHIRUVDAN OLDIN (jadvalda check summa_uzs > 0)
    v_sum := round(v_sum, 2);
    if v_sum <= 0 then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('yuk ' || v_yuk
                                   || ': summa yaxlitlangach 0 boldi — otkazildi');
      continue;
    end if;

    v_key := v_yuk::text;
    if v_map ? v_key then
      v_dup  := v_dup + 1;
      v_sum  := v_sum + coalesce((v_map -> v_key ->> 'summa')::numeric, 0);
      v_izoh := coalesce(nullif(v_map -> v_key ->> 'izoh', ''), v_izoh);
    end if;
    v_map := v_map || jsonb_build_object(v_key,
               jsonb_build_object('summa', v_sum, 'izoh', v_izoh));
  end loop;

  if v_dup > 0 then
    v_warn := v_warn || to_jsonb(v_dup
      || ' ta element bir xil yuk uchun kelgan — summalari qoshib birlashtirildi');
  end if;

  -- ===== 1.5-BOSQICH: Aros BOJXONA LIMITI (PROVODKA_YUK_BOJXONA.sql) =====
  -- Insertlardan OLDIN HAMMA elementni tekshiramiz — birortasi limitdan
  -- oshsa BUTUN chaqiruv rad etiladi, hech narsa yozilmaydi.
  v_bar_jadval := (to_regclass('public.aros_yuk_bojxona') is not null);
  if v_bar_jadval then
    -- Poyga himoyasi (tester 2026-09-06): ikki parallel chaqiruv bir yukka bir vaqtda kelsa
    -- ikkalasi ham "limit ichida" deb o'tib ketmasin — tekshiruv + yozish bitta qulf ostida.
    perform pg_advisory_xact_lock(hashtext('yuk_tannarx_qosh_limit'));
    for v_key, v_val in select key, value from jsonb_each(v_map) order by key::integer loop
      v_yuk := v_key::integer;
      v_sum := (v_val ->> 'summa')::numeric;

      select * into v_boj from aros_yuk_bojxona where yuk_id = v_yuk;
      if v_boj.yuk_id is null then
        v_warn := v_warn || to_jsonb('Yuk #' || v_yuk
          || ': Aros bojxona malumoti hali sinxron bolmagan');
        continue;
      end if;

      v_limit_uzs := coalesce(v_boj.bojxona_uzs, 0)
                   + _yuk_bojxona_fare_uzs(v_boj.currency, v_boj.fare_cur);

      if v_limit_uzs <= 0 then
        continue;                     -- limit malum emas / nol — tekshiruv otkazib yuboriladi
      end if;

      select coalesce(sum(t.summa_uzs), 0) into v_qoshilgan
        from yuk_tannarx t
       where t.yuk_id = v_yuk and not t.is_deleted;

      v_yangi_jami := v_qoshilgan + v_sum;

      if v_yangi_jami > v_limit_uzs then
        return jsonb_build_object(
          'ok', false,
          'kod', 'limit',
          'error', 'Yuk #' || v_yuk || ': Aros bojxona '
            || replace(to_char(v_limit_uzs, 'FM999G999G999G999'), ',', ' ')
            || ', qoshilgan ' || replace(to_char(v_qoshilgan, 'FM999G999G999G999'), ',', ' ')
            || ', yana ' || replace(to_char(v_sum, 'FM999G999G999G999'), ',', ' ')
            || ' qoshib bolmaydi (qoldi '
            || replace(to_char(greatest(v_limit_uzs - v_qoshilgan, 0), 'FM999G999G999G999'), ',', ' ')
            || ')',
          'yuk_id', v_yuk,
          'limit_uzs', v_limit_uzs,
          'qoshilgan_uzs', v_qoshilgan,
          'qoldi_uzs', greatest(v_limit_uzs - v_qoshilgan, 0));
      end if;
    end loop;
  end if;

  -- ===== 2-BOSQICH: yozish =====
  for v_key, v_val in select key, value from jsonb_each(v_map) order by key::integer loop
    v_yuk  := v_key::integer;
    v_sum  := (v_val ->> 'summa')::numeric;
    v_izoh := nullif(v_val ->> 'izoh', '');
    v_id   := null;

    -- Poyga holati (ikki sorov bir vaqtda, bir xil kalit): unique indeks
    -- tosadi, `do nothing` uni jimgina otkazadi va v_id null qoladi.
    insert into yuk_tannarx (yuk_id, sabab_id, summa_uzs, izoh, kalit,
                             created_by, created_by_name)
    values (v_yuk, v_sabab.id, v_sum, v_izoh, v_kalit, v_uid, v_who)
    on conflict (kalit, yuk_id) where kalit is not null and not is_deleted
    do nothing
    returning id into v_id;

    if v_id is null then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('yuk ' || v_yuk
                                   || ': shu kalit bilan allaqachon yozilgan — otkazildi');
      continue;
    end if;

    v_ok   := v_ok + 1;
    v_rows := v_rows || jsonb_build_object('yuk_id', v_yuk, 'id', v_id,
                                           'summa_uzs', v_sum);
  end loop;

  return jsonb_build_object(
    'ok',              true,
    'takror',          false,
    'qoshildi',        v_ok,
    'otkazildi',       v_skip,
    'birlashtirildi',  v_dup,
    'sabab',           v_sabab.nom,
    'qatorlar',        v_rows,
    'ogohlantirishlar', v_warn);
end
$fn$;

revoke all on function yuk_tannarx_qosh(jsonb, int, text, text) from public, anon;
grant execute on function yuk_tannarx_qosh(jsonb, int, text, text) to authenticated;

comment on function yuk_tannarx_qosh(jsonb, int, text, text) is
  'Bir nechta yukka birdan tannarx qoshadi. PUL HARAKATI YOQ. '
  'p_data=[{yuk_id,summa}], p_kalit — idempotentlik kaliti. '
  'Aros bojxona limitidan oshsa {ok:false, kod:''limit''} — hech narsa yozilmaydi.';
-- ⬆⬆⬆  6-BOLIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  7-BOLIM — TEKSHIRUVLAR. HECH BIRI YOZMAYDI.
-- #####################################################################

-- ---------------------------------------------------------------------
-- 7.1 Jadval va funksiyalar joyidami
-- ---------------------------------------------------------------------
select 'aros_yuk_bojxona jadvali' as tekshiruv,
       case when to_regclass('public.aros_yuk_bojxona') is not null
            then '✅ OK' else '❌ YARATILMADI' end as natija
union all
select 'yuk_bojxona_korish_ok()',
       case when to_regprocedure('public.yuk_bojxona_korish_ok()') is not null
            then '✅ OK' else '❌ YARATILMADI' end
union all
select '_yuk_bojxona_fare_uzs(text,numeric)',
       case when to_regprocedure('public._yuk_bojxona_fare_uzs(text,numeric)') is not null
            then '✅ OK' else '❌ YARATILMADI' end
union all
select 'sync_yuk_bojxona(jsonb)',
       case when to_regprocedure('public.sync_yuk_bojxona(jsonb)') is not null
            then '✅ OK' else '❌ YARATILMADI' end
union all
select 'yuk_bojxona_jami(integer[])',
       case when to_regprocedure('public.yuk_bojxona_jami(integer[])') is not null
            then '✅ OK' else '❌ YARATILMADI' end
union all
select 'yuk_tannarx_qosh(jsonb,int,text,text) qayta elon',
       case when to_regprocedure('public.yuk_tannarx_qosh(jsonb,int,text,text)') is not null
            then '✅ OK' else '❌ YARATILMADI' end;

-- ---------------------------------------------------------------------
-- 7.2 yuk_tannarx_qosh tanasida limit tekshiruvi bormi (pg_get_functiondef)
-- ---------------------------------------------------------------------
select 'yuk_tannarx_qosh limitni biladimi' as tekshiruv,
       case when pg_get_functiondef('public.yuk_tannarx_qosh(jsonb,int,text,text)'::regprocedure)
                 like '%aros_yuk_bojxona%'
            then '✅ OK — limit tekshiruvi qoshilgan'
            else '❌ YOQ — 6-BOLIM notogri RUN bolgan (eski tana qolgan)' end as natija;

-- ---------------------------------------------------------------------
-- 7.3 Ruxsatlar (kim nimani chaqira oladi)
-- ---------------------------------------------------------------------
select 'authenticated: sync_yuk_bojxona' as tekshiruv,
       case when has_function_privilege('authenticated', 'public.sync_yuk_bojxona(jsonb)', 'execute')
            then '❌ XATO — authenticated bu RPCni CHAQIRA OLMASLIGI kerak edi'
            else '✅ OK — yopiq' end as natija
union all
select 'service_role: sync_yuk_bojxona',
       case when has_function_privilege('service_role', 'public.sync_yuk_bojxona(jsonb)', 'execute')
            then '✅ OK' else '❌ YOQ' end
union all
select 'authenticated: yuk_bojxona_jami',
       case when has_function_privilege('authenticated', 'public.yuk_bojxona_jami(integer[])', 'execute')
            then '✅ OK' else '❌ YOQ' end
union all
select 'authenticated: aros_yuk_bojxona select',
       case when has_table_privilege('authenticated', 'public.aros_yuk_bojxona', 'select')
            then '✅ OK (RLS qorovul bilan filtrlanadi)' else '❌ YOQ' end;

-- ---------------------------------------------------------------------
-- 7.4 RLS yoqilgan va YOZISH policy'si YOQ (faqat RPC yozadi)
-- ---------------------------------------------------------------------
select c.relname as jadval,
       c.relrowsecurity as rls_yoqilgan,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as policy_soni,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname
           and p.cmd <> 'SELECT') as yozish_policy,
       case when c.relrowsecurity
             and (select count(*) from pg_policies p
                   where p.schemaname = 'public' and p.tablename = c.relname
                     and p.cmd <> 'SELECT') = 0
            then '✅ OK' else '❌ TEKSHIRING' end as natija
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relname = 'aros_yuk_bojxona';

-- ---------------------------------------------------------------------
-- 7.5 Smoke test — bosh royxatda jami RPC (yozmaydi)
--     Kutilgan natija: bosh obyekt {}
-- ---------------------------------------------------------------------
select jsonb_pretty(yuk_bojxona_jami('{}'::integer[])) as bosh_royxat;

-- ---------------------------------------------------------------------
-- 7.6 Jonli holat — sinxron bolgan yuklar (yozgandan keyin qarash uchun)
-- ---------------------------------------------------------------------
select yuk_id, currency, bojxona_uzs, fare_cur, fare_percent, rejim,
       status, delivery_status, synced_at
  from aros_yuk_bojxona
 order by synced_at desc
 limit 50;

-- ---------------------------------------------------------------------
-- 7.7 🔴 PUL HARAKATI YOQLIGI — bu fayl balansga tegmaganini tasdiqlaydi.
--     Farq 0 bolishi shart (ornatishdan oldin ham 0 edi).
-- ---------------------------------------------------------------------
select 'Balans tengligi' as tekshiruv,
       sum(case when bolim = 'AKTIV' then amount else 0 end)
     - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end) as farq,
       case when abs(sum(case when bolim = 'AKTIV' then amount else 0 end)
                   - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end)) <= 0.01
            then '✅ OK — bojxona limiti qatlami pulga tegmaydi'
            else '❌ TEKSHIRING (sababi bu fayl EMAS — u entry yozmaydi)' end as natija
  from balans(current_date);


-- #####################################################################
--  8-BOLIM — PostgREST sxema keshini yangilash
-- #####################################################################
--  Busiz yangi RPC'lar klientdan "function not found" (PGRST202) beradi.

-- ⬇⬇⬇  8-BOLIM  ⬇⬇⬇
notify pgrst, 'reload schema';
-- ⬆⬆⬆  8-BOLIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  9-BOLIM — ROLLBACK (kerak bolsa, QOLDA)
-- #####################################################################
--  Ataylab izohda turibdi — tasodifan RUN bolmasin.
--
--  ⚠️ yuk_tannarx_qosh ni qaytarish uchun PROVODKA_YUK_TANNARX.sql dagi
--     5-BOLIMni QAYTA RUN qiling (limit tekshiruvisiz eski tana).
--  ⚠️ Jadvalni tashlashdan oldin `select count(*) from aros_yuk_bojxona`
--     qiling: qatorlar bolsa, ular ham ketadi.

-- 9.1 Nima yoqoladi (bu select xavfsiz)
-- select (select count(*) from aros_yuk_bojxona) as bojxona_qatorlar;

-- 9.2 Funksiyalarni olib tashlash
-- drop function if exists yuk_bojxona_jami(integer[]);
-- drop function if exists sync_yuk_bojxona(jsonb);
-- drop function if exists _yuk_bojxona_fare_uzs(text, numeric);
-- drop function if exists yuk_bojxona_korish_ok();

-- 9.3 Jadvalni olib tashlash (MALUMOT YOQOLADI)
-- drop table if exists aros_yuk_bojxona;

-- 9.4 notify pgrst, 'reload schema';
