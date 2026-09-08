-- =====================================================================
--  PROVODKA_AYLANMA.sql — «Sof aylanma kapital» (SAK) kunlik snapshot REGISTRI
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--  Brief: ARX_PROVODKA_AYLANMA.md (1..4 va 6-BO'LIM, 2026-09-08).
--
--  #####  MAQSAD  #########################################################
--
--  «Butun biznesda hozir qancha pul bor?» — har kuni 08:00 (Toshkent) n8n
--  bitta marta hisoblaydi, tarixda saqlanadi, grafikda ko'rinadi (yangi
--  sahifa `aylanma-dev.html`, ruxsat kaliti `aylanma`).
--
--  #####  🔴 PUL HARAKATI YO'Q  ###########################################
--
--  Bu fayl `entry`/`entry_line`ga hech narsa yozmaydi — faqat REGISTR
--  (`aylanma_snapshot` + `aylanma_qator`) + o'qish RPC'lari. Mavjud
--  hisobot/registr manbalari (v_kassa_card, aros_transfer_yolda, qarz,
--  v_qarz_holat, aros_qarzdor_sync, yuk_kurslar/yuk_tolangan_summa,
--  v_hisob_qoldiq) FAQAT O'QILADI/CHAQIRILADI — tanalari qayta yozilmaydi.
--
--  #####  FORMULA (bolimlar jsonb kalitlari)  #############################
--     SAK = A + B + T1 + T5 + Y3a + K3b + K4 + B6 + Q2a − Q2b
--     A    Pul (markaziy + filial kassalar, v_kassa_card)
--     B    Yo'ldagi pul (aros_transfer_yolda status='sent')
--     T1   Tovar omborlarda, tannarx (Metabase, is_broken=false)
--     T5   Brak tovar omborlarda, tannarx (Metabase, is_broken=true)
--     Y3a  Yo'ldagi yuklar (product-incomes posted + delivery on_way)
--     K3b  Ko'chirish yo'lda (v2/transfers on_way)
--     K4   Ko'chirish yaratilgan (v2/transfers created)
--     B6   Ochiq buyurtmalar, sotuv narxida
--     Q2a  Bizdan qarzdor (qarz_umumiy_dash: Provodka qarz + Aros mijozlar)
--     Q2b  Biz qarzdormiz (Qarz sahifasi formulasi: yuk narxi×kurs − to'langan)
--     D    Daftar 4010/6010 — QO'SHIMCHA MA'LUMOT, jamiga KIRMAYDI (hisobga=false)
--
--  #####  FAYL TARKIBI  ###################################################
--     0-BO'LIM — old shart tekshiruvi (faqat select/raise)
--     1-BO'LIM — `perm_pages()` qayta e'lon — 20-kalit `aylanma`
--     2-BO'LIM — `aylanma_page_ok()` (+ ichki `_aylanma_is_admin()`)
--     3-BO'LIM — jadvallar `aylanma_snapshot` + `aylanma_qator` (+ RLS)
--     4-BO'LIM — `sync_aylanma_snapshot(p_data)` — service_role ONLY (n8n)
--     5-BO'LIM — o'qish RPC'lari: `aylanma_kun`, `aylanma_trend`,
--                `aylanma_royxat`, `aylanma_qatorlar` — authenticated
--     6-BO'LIM — PostgREST sxema keshini yangilash
--     7-BO'LIM — DIAG / YAKUNIY TEKSHIRUV (faqat select/raise)
--
--  #####  ADDITIVE KAFOLATI  ##############################################
--   * Hech narsa drop qilinmaydi, hech qanday mavjud jadval/ustun/funksiya
--     imzosi o'zgartirilmaydi. Hammasi YANGI, `aylanma_` prefiksi bilan
--     (+ bitta ICHKI yordamchi `_aylanma_is_admin`).
--   * `v_kassa_card`, `aros_transfer_yolda`, `qarz`, `v_qarz_holat`,
--     `aros_qarzdor_sync`, `yuk_kurslar(text[])`, `yuk_tolangan_summa(integer[])`,
--     `v_hisob_qoldiq`, `aros_usd_rate()`, `conv_baza_kurs(text)`,
--     `aros_yuk_bojxona` — FAQAT CHAQIRILADI/O'QILADI (pg_proc/to_regclass
--     bilan mavjudligi tekshirilib), tanalari tegilmaydi. Birortasi yo'q
--     bazada bo'lsa o'sha BO'LIM `null` qaytaradi, sync o'zi yiqilmaydi
--     (fail-soft — pastdagi 4-BO'LIM izohiga qara).
--   * 🔴 `qarz_umumiy_dash()`/`qarz_dash()`/`aros_qarzdor_dash()` ATAYLAB
--     chaqirilmaydi — ular `auth.uid()`ga tayangan (service_role/cron uchun
--     mo'ljallanmagan, `qarz_dash()` null uid'da "Avtorizatsiya kerak" bilan
--     RAISE qiladi). Q2a bo'limi (4-BO'LIM) bir xil formulani to'g'ridan
--     `qarz`/`v_qarz_holat`/`aros_qarzdor_sync`dan takrorlaydi.
--   * Idempotent: `create table if not exists`, `create or replace
--     function`, `drop policy if exists` + `create policy`.
--   * Anonim `do` bloki YO'Q — har `do` bloki nomlangan teg bilan. Har
--     funksiya tanasi ham nomlangan teg bilan. Izohlarda ketma-ket dollar
--     belgi YOZILMAGAN (soxta blok xavfi — CLAUDE.md).
--
--  #####  RUXSAT  ##########################################################
--  `aylanma_page_ok()` = admin (profiles.role='admin', is_admin() bo'lsa
--  o'shandan) YOKI `perm_has_page('aylanma')` (pg_proc bilan tekshirib,
--  yo'q bo'lsa false — fail-closed). Kassa doirasi QO'LLANMAYDI — butun
--  kompaniya raqami, faqat rahbariyatga beriladi.
--
--  #####  TALAB (0-BO'LIM tekshiradi)  #####################################
--     profiles         — asosiy migratsiya (admin fallback uchun)
--
--  🔴 SQL'ni ASILBEK o'zi RUN qiladi. Agent bajarmaydi.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI                                 ##
-- #####################################################################

do $ayl_pre$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'profiles jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
end
$ayl_pre$;


-- #####################################################################
-- ##  1-BO'LIM — perm_pages() qayta e'lon — 20-kalit `aylanma`         ##
-- #####################################################################
-- 🔴 Imzo/til/immutable saqlanadi. Eski 19 kalit tegilmaydi, `aylanma`
-- OXIRIGA qo'shiladi. `perms-dev.js` PAGES = `index-dev.html` CARDS =
-- `promote.sh` PAGES = admin-dev `PVS_PAGES` bilan bir xil bo'lishi shart
-- (busiz `admin_set_provodka_perms` bu kalitni jimgina tashlaydi).

create or replace function perm_pages()
returns text[]
language sql
immutable
as $perm_pages$
  select array['kassa','jurnal','professional','hisobot','balans','cashflow',
               'qarzdor','filial','valyuta','konvert','sozlama','provodka',
               'yuklar','standart','tannarx','ai','sorovlar','ehson','ehson_kirim',
               'aylanma']::text[];
$perm_pages$;

revoke all on function perm_pages() from public, anon;
grant execute on function perm_pages() to authenticated, service_role;

comment on function perm_pages() is
  'Provodka ruxsat kalitlari (20 ta: 19 sahifa/bayroq + aylanma). perms.js PAGES+FLAGS va '
  'admin-dev PVS_PAGES bilan bir xil. hodim.html bu ro''yxatga KIRMAYDI — hech qachon cheklanmaydi.';


-- #####################################################################
-- ##  2-BO'LIM — aylanma_page_ok() (+ ichki _aylanma_is_admin())       ##
-- #####################################################################
-- 🔴 `_ehson_is_admin()` naqshi (PROVODKA_EHSON.sql): modul MUSTAQIL —
-- `is_admin()` mavjud bo'lsa o'shandan, bo'lmasa `profiles.role='admin'`
-- bilan ICHKI qobiq quriladi. Boshqa hech qanday RPC to'g'ridan
-- `is_admin()` ni CHAQIRMAYDI.

-- 2.0 _aylanma_fn_bor(p_nom, p_args) — ICHKI: funksiya mavjudligi tekshiruvi.
-- 🔴 `to_regprocedure` EMAS — Supabase editorida null berishi mumkin
-- (PROVODKA_AROS_QARZDOR.sql 0-BO'LIM izohi). `pg_proc join pg_namespace`
-- naqshi, `p_args` = `oidvectortypes(proargtypes)` natijasi — FAQAT TURLAR,
-- vergul+probel bilan (masalan 'text', 'text[]', 'jsonb, boolean',
-- argumentsiz bo'lsa ''). 🔴 `pg_get_function_identity_arguments` EMAS —
-- u parametr NOMLARINI ham qaytaradi ('p_key text') va tekshiruv har doim
-- false bo'lardi (tester 2026-09-08 topilmasi).
create or replace function _aylanma_fn_bor(p_nom text, p_args text default '')
returns boolean
language sql
stable
as $fn$
  select exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = p_nom
       and oidvectortypes(p.proargtypes) = coalesce(p_args, '')
  );
$fn$;

revoke all on function _aylanma_fn_bor(text, text) from public, anon, authenticated;

comment on function _aylanma_fn_bor(text, text) is
  'ICHKI: funksiya mavjudligini pg_proc/pg_namespace orqali tekshiradi (to_regprocedure '
  'ishonchsiz). p_args = oidvectortypes(proargtypes) natijasi — faqat turlar.';

do $ayl_is_admin_setup$
declare
  v_admin_expr text;
begin
  if _aylanma_fn_bor('is_admin', '') then
    v_admin_expr := 'is_admin()';
  else
    v_admin_expr := $x$coalesce((select role = 'admin' from profiles where id = auth.uid()), false)$x$;
  end if;

  execute format($ddl$
    create or replace function _aylanma_is_admin()
    returns boolean
    language sql
    stable
    security definer
    set search_path = public
    as $fn$
      select %s;
    $fn$;
  $ddl$, v_admin_expr);
end
$ayl_is_admin_setup$;

revoke all on function _aylanma_is_admin() from public, anon, authenticated;

comment on function _aylanma_is_admin() is
  'ICHKI: admin tekshiruvi (is_admin() mavjud bo''lsa o''shandan, aks holda profiles.role=''admin'').';

create or replace function aylanma_page_ok()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $ayl_ok$
declare
  v_uid      uuid;
  v_has_perm boolean;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return false;                       -- fail-CLOSED: n8n/SQL editor bu yo'ldan kirmaydi
  end if;

  if _aylanma_is_admin() then
    return true;
  end if;

  v_has_perm := false;
  if _aylanma_fn_bor('perm_has_page', 'text') then
    begin
      execute 'select perm_has_page($1)' into v_has_perm using 'aylanma';
    exception when others then
      v_has_perm := false;
    end;
  end if;

  return coalesce(v_has_perm, false);
end
$ayl_ok$;

revoke all on function aylanma_page_ok() from public, anon;
grant execute on function aylanma_page_ok() to authenticated;

comment on function aylanma_page_ok() is
  'RLS/RPC qorovuli: admin YOKI perm_has_page(''aylanma'') (pg_proc bilan tekshirib, yoq bolsa false). '
  'Kassa doirasi YOQ — butun kompaniya raqami. auth.uid() null -> false (fail-closed).';


-- #####################################################################
-- ##  3-BO'LIM — jadvallar aylanma_snapshot + aylanma_qator (+ RLS)   ##
-- #####################################################################

create table if not exists aylanma_snapshot (
  id              uuid        primary key default gen_random_uuid(),
  sana            date        not null,
  rejim           text        not null check (rejim in ('cron', 'qolda')),
  hisoblangan_at  timestamptz not null default now(),
  kurs_usd        numeric,
  jami_uzs        numeric,
  jami_usd        numeric,
  toliq           boolean     not null default true,
  bolimlar        jsonb       not null default '{}'::jsonb,
  manba_holati    jsonb       default '{}'::jsonb,
  xatolar         text[]      default '{}'::text[],
  created_at      timestamptz not null default now()
);

-- Bir kunda faqat BITTA cron qator (qayta hisoblansa eskisi o'chirilib
-- qayta yoziladi — 4-BO'LIM). 'qolda' cheklanmaydi — har bosishda yangi qator.
create unique index if not exists idx_aylanma_snapshot_cron_sana
  on aylanma_snapshot (sana) where rejim = 'cron';
create index if not exists idx_aylanma_snapshot_sana on aylanma_snapshot (sana);

comment on table aylanma_snapshot is
  '«Sof aylanma kapital» kunlik snapshot (bosh yozuv). PUL HARAKATI YO''Q — faqat registr. '
  'bolimlar = {A,B,T1,T5,Y3a,K3b,K4,B6,Q2a,Q2b,D : {uzs,usd,soni} | null}. '
  'toliq=false — kamida bitta FORMULAGA kiruvchi bo''lim manba xatosi tufayli null (D bundan mustasno).';

alter table aylanma_snapshot enable row level security;
revoke all on table aylanma_snapshot from public, anon;
grant select on table aylanma_snapshot to authenticated;

drop policy if exists aylanma_snapshot_select on aylanma_snapshot;
create policy aylanma_snapshot_select on aylanma_snapshot
  for select to authenticated
  using (aylanma_page_ok());


create table if not exists aylanma_qator (
  id           bigserial   primary key,
  snapshot_id  uuid        not null references aylanma_snapshot(id) on delete cascade,
  bolim        text        not null,
  ref          text        not null,
  nom          text,
  usd          numeric,
  uzs          numeric,
  soni         numeric,
  hisobga      boolean     not null default true,
  meta         jsonb       default '{}'::jsonb,
  created_at   timestamptz not null default now()
);

create index if not exists idx_aylanma_qator_snap_bolim on aylanma_qator (snapshot_id, bolim);

comment on table aylanma_qator is
  'aylanma_snapshot ning drill-down qatorlari (har ombor/yuk/transfer/buyurtma/kassa bitta qator). '
  'ref = warehouse_id / yuk_id / transfer_id / order_id / hisob kodi. hisobga=false — jamiga '
  'kirmagan (masalan D bo''lim yoki B6 bilan ikki marta sanalmasin deb chetlatilgan K3b/K4 qatori).';

alter table aylanma_qator enable row level security;
revoke all on table aylanma_qator from public, anon;
grant select on table aylanma_qator to authenticated;

drop policy if exists aylanma_qator_select on aylanma_qator;
create policy aylanma_qator_select on aylanma_qator
  for select to authenticated
  using (aylanma_page_ok());


-- #####################################################################
-- ##  4-BO'LIM — sync_aylanma_snapshot(p_data) — service_role ONLY    ##
-- #####################################################################
-- Kirish (n8n «Aros Provodka - Aylanma Snapshot»):
--   { sana:'YYYY-MM-DD', rejim:'cron'|'qolda',
--     manba:{warehouses,metabase,incomes,transfers,orders:'ok'|'xato'},
--     omborlar:[{id,nom,is_broken,is_active,usd,soni,tr_yolda_uzs}],
--     yuklar:[{id,narx,valyuta,status,delivery_status,ombor_id,ombor,yetkazuvchi,sana}],
--     transferlar:[{id,status,from_id,from_nom,to_id,to_nom,to_brak,price_uzs,
--                   tannarx_uzs,order_id,created,sent}],
--     buyurtmalar:[{id,status,warehouse_id,warehouse,total_uzs,user_id,created}] }
--
-- 🔴 A, B, Q2a, D — Aros'ga TEGISHLI EMAS (mavjud Provodka manbalaridan
-- server o'zi hisoblaydi, payloadsiz ham ishlaydi). T1/T5/Y3a/K3b/K4/B6/Q2b —
-- payloaddagi ro'yxatlardan. Har BO'LIM alohida begin/exception — bittasi
-- yiqilsa qolganlari yoziladi (fail-soft), sabab xatolar[] ga (qisqartirilgan
-- sqlerrm), o'sha bo'lim bolimlar'da null, toliq=false (D bundan mustasno —
-- jamiga kirmaydi).

create or replace function sync_aylanma_snapshot(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $ayl_sync$
declare
  v_role         text;
  v_sana         date;
  v_rejim        text;
  v_manba        jsonb;
  v_omborlar     jsonb;
  v_yuklar       jsonb;
  v_transferlar  jsonb;
  v_buyurtmalar  jsonb;
  v_order_ids    int[];
  v_yuk_ids      int[];
  v_curs         text[];
  v_kurs_map     jsonb;
  v_kurs_usd     numeric;
  v_paid         jsonb;
  v_paid_map     jsonb;
  v_boj          numeric;
  v_row_val      numeric;
  v_tolangan     numeric;
  v_hisobga      boolean;
  v_q2b_missing  jsonb;
  v_curkey       text;
  v_curcnt       numeric;

  v_toliq        boolean := true;
  v_xatolar      text[] := '{}';
  v_bolimlar     jsonb := '{}'::jsonb;
  v_qatorlar     jsonb := '[]'::jsonb;
  v_snapshot_id  uuid;
  v_jami_uzs     numeric;
  v_jami_usd     numeric;

  -- umumiy loop/scratch o'zgaruvchilari (bo'limlar KETMA-KET, parallel emas)
  v_el   jsonb;
  v_ref  text;
  v_nom  text;
  v_num  numeric;
  v_num2 numeric;
  v_bool boolean;
  v_txt  text;
  v_meta jsonb;

  -- har bo'lim uchun alohida jamlovchilar
  v_a_uzs   numeric; v_a_usd   numeric; v_a_soni   int; v_a_rows   jsonb;
  v_bola_uzs numeric; v_bola_usd numeric; v_bola_n int; v_farq numeric;   -- A: Aros'ga tenglashtirilgan bolalar
  v_b_uzs   numeric; v_b_usd   numeric; v_b_soni   int; v_b_rows   jsonb;
  v_t1_uzs  numeric;                    v_t1_soni  int; v_t1_rows  jsonb;
  v_t5_uzs  numeric;                    v_t5_soni  int; v_t5_rows  jsonb;
  v_y3a_uzs numeric;                    v_y3a_soni int; v_y3a_rows jsonb;
  v_k3b_uzs numeric;                    v_k3b_soni int; v_k3b_rows jsonb;
  v_k4_uzs  numeric;                    v_k4_soni  int; v_k4_rows  jsonb;
  v_b6_uzs  numeric;                    v_b6_soni  int; v_b6_rows  jsonb;
  v_q2a_uzs numeric;                                     v_q2a_rows jsonb;
  v_q2b_uzs numeric;                    v_q2b_soni int; v_q2b_rows jsonb;
  v_d_rows  jsonb;
begin
  -- ---- service_role ONLY (sync_transfer_yolda/sync_aros_qarzdor bilan bir xil naqsh) ----
  if auth.uid() is not null then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is not null and v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('sync_aylanma_snapshot'));

  -- ---- kirish validatsiyasi ----
  if p_data is null or jsonb_typeof(p_data) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'error', 'p_data object kutilgan edi');
  end if;

  begin
    v_sana := nullif(p_data ->> 'sana', '')::date;
  exception when others then
    v_sana := null;
  end;
  if v_sana is null then
    return jsonb_build_object('ok', false, 'error', 'sana (YYYY-MM-DD) kerak/notogri formatda');
  end if;

  v_rejim := lower(btrim(coalesce(p_data ->> 'rejim', '')));
  if v_rejim not in ('cron', 'qolda') then
    return jsonb_build_object('ok', false, 'error', 'rejim ''cron'' yoki ''qolda'' bolishi kerak');
  end if;

  v_manba := coalesce(p_data -> 'manba', '{}'::jsonb);
  if jsonb_typeof(v_manba) is distinct from 'object' then v_manba := '{}'::jsonb; end if;

  v_omborlar := p_data -> 'omborlar';
  if jsonb_typeof(v_omborlar) is distinct from 'array' then v_omborlar := '[]'::jsonb; end if;
  v_yuklar := p_data -> 'yuklar';
  if jsonb_typeof(v_yuklar) is distinct from 'array' then v_yuklar := '[]'::jsonb; end if;
  v_transferlar := p_data -> 'transferlar';
  if jsonb_typeof(v_transferlar) is distinct from 'array' then v_transferlar := '[]'::jsonb; end if;
  v_buyurtmalar := p_data -> 'buyurtmalar';
  if jsonb_typeof(v_buyurtmalar) is distinct from 'array' then v_buyurtmalar := '[]'::jsonb; end if;

  -- K3b/K4 uchun: order_id B6 (buyurtmalar) ichida bormi — ikki marta sanalmasin
  v_order_ids := '{}';
  begin
    select coalesce(array_agg((x ->> 'id')::int), '{}')
      into v_order_ids
      from jsonb_array_elements(v_buyurtmalar) x
     where nullif(x ->> 'id', '') ~ '^[0-9]+$';
  exception when others then
    v_order_ids := '{}';
  end;

  -- ---- kurs_usd (bir marta, hamma USD hisob shundan) ----
  v_kurs_usd := null;
  begin
    if _aylanma_fn_bor('aros_usd_rate', '') then
      execute 'select aros_usd_rate()' into v_kurs_usd;
    end if;
  exception when others then
    v_kurs_usd := null;
  end;
  if v_kurs_usd is null then
    begin
      if _aylanma_fn_bor('conv_baza_kurs', 'text') then
        execute 'select conv_baza_kurs($1)' into v_kurs_usd using 'USD';
      end if;
    exception when others then
      v_kurs_usd := null;
    end;
  end if;
  if v_kurs_usd is null then
    -- 🔴 USD ga bog'liq bo'limlar (A.usd/B/T1/T5) so'mga to'liq o'tolmaydi -> toliq=false.
    v_toliq := false;
    v_xatolar := array_append(v_xatolar,
      'USD kursi topilmadi (aros_usd_rate/conv_baza_kurs) — USD qiymatlar hisobga olinmadi');
  end if;

  -- =====================================================================
  -- [A] Pul (markaziy + filial kassalar) — v_kassa_card
  -- =====================================================================
  begin
    v_a_rows := '[]'::jsonb; v_a_uzs := 0; v_a_usd := 0; v_a_soni := 0;

    -- 🔴 2026-09-08 (Asilbek): kassa hech qachon MANFIY bo'lolmaydi — Aros balansi
    -- haqiqat. Balans Sync har soat naqd/click/payme/USD BOLALARINI Aros'ga
    -- tenglashtiradi; parent hisobning O'Z qoldig'i esa eski yozuvlardan manfiy
    -- qolib ketgan (5213 −75 mln). Shuning uchun A = BOLALAR yig'indisi (= Aros,
    -- ≤1 soat), parent farqi (karta jami − bolalar) alohida qator, hisobga=false.
    -- Bolasi yo'q kassa (Aros'ga bog'lanmagan) — eskicha karta jami.
    for v_ref, v_nom, v_num, v_num2, v_bola_uzs, v_bola_usd, v_bola_n in
      select k.code, k.name, coalesce(k.jami, 0)::numeric, coalesce(k.usd, 0)::numeric,
             coalesce(b.uzs, 0)::numeric, coalesce(b.usd, 0)::numeric, coalesce(b.n, 0)::int
        from v_kassa_card k
        left join lateral (
          select sum(hb.uzs) as uzs,
                 sum(case when c.currency = 'USD' then hb.fc else 0 end) as usd,
                 count(*) as n
            from accounts c
            join v_hisob_bal hb on hb.account_id = c.id
           where c.parent_id = k.id
             and coalesce(c.is_active, true)
        ) b on true
       where k.kassa_turi in ('markaziy', 'filial')
         and coalesce((to_jsonb(k) ->> 'is_active')::boolean, true)   -- nofaol kassa yo'q (kassa-dev filtri); ustun bo'lmasa true
    loop
      if v_bola_n > 0 then
        v_farq := v_num - v_bola_uzs;          -- parent o'z qoldig'i (daftar farqi)
        v_num  := v_bola_uzs;
        v_num2 := v_bola_usd;
      else
        v_farq := 0;
      end if;
      v_a_uzs  := v_a_uzs + v_num;
      v_a_usd  := v_a_usd + v_num2;
      v_a_soni := v_a_soni + 1;
      v_a_rows := v_a_rows || jsonb_build_object(
        'bolim', 'A', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', v_num2,
        'soni', null, 'hisobga', true,
        'meta', jsonb_build_object('manba', case when v_bola_n > 0 then 'aros_bolalar' else 'karta' end,
                                   'manfiy', v_num < 0));
      if v_num < 0 then
        v_xatolar := array_append(v_xatolar, 'A: ' || v_nom || ' manfiy (' || round(v_num) || ')');
      end if;
      if abs(coalesce(v_farq, 0)) >= 1 then
        v_a_rows := v_a_rows || jsonb_build_object(
          'bolim', 'A', 'ref', v_ref || ':farq', 'nom', v_nom || ' — daftar farqi', 'uzs', v_farq, 'usd', null,
          'soni', null, 'hisobga', false, 'meta', jsonb_build_object('daftar_farqi', true));
      end if;
    end loop;

    v_bolimlar := v_bolimlar || jsonb_build_object('A',
      jsonb_build_object('uzs', v_a_uzs, 'usd', v_a_usd, 'soni', v_a_soni));
    v_qatorlar := v_qatorlar || v_a_rows;
  exception when others then
    v_a_uzs := null; v_a_usd := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('A', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'A: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [B] Yo'ldagi pul — aros_transfer_yolda status='sent'
  -- =====================================================================
  begin
    v_b_rows := '[]'::jsonb; v_b_uzs := 0; v_b_usd := 0; v_b_soni := 0;

    if to_regclass('public.aros_transfer_yolda') is not null then
      for v_ref, v_nom, v_num, v_num2, v_meta in
        select t.transfer_id,
               coalesce(t.sender_title, '?') || ' -> ' || coalesce(t.receiver_title, '?'),
               coalesce(t.s_cash, 0) + coalesce(t.s_click, 0) + coalesce(t.s_payme, 0)
                 + coalesce(t.s_usd, 0) * coalesce(v_kurs_usd, 0),
               coalesce(t.s_usd, 0),
               case when v_kurs_usd is null and coalesce(t.s_usd, 0) <> 0
                    then jsonb_build_object('kurs_yoq', true) else '{}'::jsonb end
          from aros_transfer_yolda t
         where t.status = 'sent'
      loop
        v_b_uzs  := v_b_uzs + v_num;
        v_b_usd  := v_b_usd + v_num2;
        v_b_soni := v_b_soni + 1;
        v_b_rows := v_b_rows || jsonb_build_object(
          'bolim', 'B', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', v_num2,
          'soni', null, 'hisobga', true, 'meta', v_meta);
      end loop;
    end if;

    v_bolimlar := v_bolimlar || jsonb_build_object('B',
      jsonb_build_object('uzs', v_b_uzs, 'usd', v_b_usd, 'soni', v_b_soni));
    v_qatorlar := v_qatorlar || v_b_rows;
  exception when others then
    v_b_uzs := null; v_b_usd := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('B', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'B: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [T1]/[T5] Tovar + brak omborlarda (Metabase tannarx, payload orqali)
  -- =====================================================================
  begin
    v_t1_rows := '[]'::jsonb; v_t1_uzs := 0; v_t1_soni := 0;
    v_t5_rows := '[]'::jsonb; v_t5_uzs := 0; v_t5_soni := 0;

    if coalesce(v_manba ->> 'metabase', '') = 'xato' or coalesce(v_manba ->> 'warehouses', '') = 'xato' then
      v_t1_uzs := null; v_t5_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('T1', null, 'T5', null);
      v_toliq := false;
      if coalesce(v_manba ->> 'metabase', '') = 'xato' then
        v_xatolar := array_append(v_xatolar, 'T1/T5: manba.metabase=xato — otkazib yuborildi');
      end if;
      if coalesce(v_manba ->> 'warehouses', '') = 'xato' then
        v_xatolar := array_append(v_xatolar, 'T1/T5: manba.warehouses=xato — otkazib yuborildi');
      end if;
    else
      for v_el in select * from jsonb_array_elements(v_omborlar) loop
        v_ref  := coalesce(v_el ->> 'id', '');
        v_nom  := coalesce(v_el ->> 'nom', '');
        v_bool := coalesce((v_el ->> 'is_broken')::boolean, false);
        v_num  := nullif(v_el ->> 'usd', '')::numeric;      -- ombor tannarxi (USD)

        if v_num is null then
          v_num2 := 0;
          v_meta := jsonb_build_object('yoq', true);
        elsif v_kurs_usd is null then
          v_num2 := 0;
          v_meta := jsonb_build_object('kurs_yoq', true);
        else
          v_num2 := round(v_num * v_kurs_usd, 2);
          v_meta := '{}'::jsonb;
        end if;

        if nullif(v_el ->> 'tr_yolda_uzs', '') is not null then
          v_meta := v_meta || jsonb_build_object('tr_yolda_uzs', (v_el ->> 'tr_yolda_uzs')::numeric);
        end if;

        if v_bool then
          v_t5_uzs  := v_t5_uzs + v_num2;
          v_t5_soni := v_t5_soni + 1;
          v_t5_rows := v_t5_rows || jsonb_build_object(
            'bolim', 'T5', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num2, 'usd', v_num,
            'soni', null, 'hisobga', true, 'meta', v_meta);
        else
          v_t1_uzs  := v_t1_uzs + v_num2;
          v_t1_soni := v_t1_soni + 1;
          v_t1_rows := v_t1_rows || jsonb_build_object(
            'bolim', 'T1', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num2, 'usd', v_num,
            'soni', null, 'hisobga', true, 'meta', v_meta);
        end if;
      end loop;

      v_bolimlar := v_bolimlar || jsonb_build_object(
        'T1', jsonb_build_object('uzs', v_t1_uzs, 'usd', null, 'soni', v_t1_soni),
        'T5', jsonb_build_object('uzs', v_t5_uzs, 'usd', null, 'soni', v_t5_soni));
      v_qatorlar := v_qatorlar || v_t1_rows || v_t5_rows;
    end if;
  exception when others then
    v_t1_uzs := null; v_t5_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('T1', null, 'T5', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'T1/T5: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [Y3a] Yo'ldagi yuklar — status=posted, delivery_status=on_way
  -- =====================================================================
  begin
    v_y3a_rows := '[]'::jsonb; v_y3a_uzs := 0; v_y3a_soni := 0;

    if coalesce(v_manba ->> 'incomes', '') = 'xato' then
      v_y3a_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('Y3a', null);
      v_toliq := false;
      v_xatolar := array_append(v_xatolar, 'Y3a: manba.incomes=xato — otkazib yuborildi');
    else
      select coalesce(array_agg(distinct upper(btrim(x ->> 'valyuta'))), '{}')
        into v_curs
        from jsonb_array_elements(v_yuklar) x
       where nullif(btrim(coalesce(x ->> 'valyuta', '')), '') is not null;

      v_kurs_map := '{}'::jsonb;
      if coalesce(array_length(v_curs, 1), 0) > 0
         and _aylanma_fn_bor('yuk_kurslar', 'text[]') then
        begin
          v_kurs_map := yuk_kurslar(v_curs);
        exception when others then
          v_kurs_map := '{}'::jsonb;
        end;
      end if;
      if v_kurs_usd is not null then
        v_kurs_map := v_kurs_map || jsonb_build_object('USD', v_kurs_usd);
      end if;

      for v_el in
        select * from jsonb_array_elements(v_yuklar) x
         where x ->> 'status' = 'posted' and x ->> 'delivery_status' = 'on_way'
      loop
        v_ref := coalesce(v_el ->> 'id', '');
        v_nom := coalesce(v_el ->> 'ombor', '')
          || case when nullif(v_el ->> 'yetkazuvchi', '') is not null
                  then ' · ' || (v_el ->> 'yetkazuvchi') else '' end;
        v_txt  := upper(btrim(coalesce(v_el ->> 'valyuta', '')));
        v_num  := nullif(v_kurs_map ->> v_txt, '')::numeric;
        v_num2 := coalesce(nullif(v_el ->> 'narx', '')::numeric, 0);

        if v_num is null then
          v_row_val := 0;
          v_meta := jsonb_build_object('kurs_yoq', true, 'valyuta', v_txt);
          v_xatolar := array_append(v_xatolar,
            'Y3a: yuk ' || coalesce(v_ref, '?') || ' kursi topilmadi (' || coalesce(v_txt, '?') || ')');
        else
          v_row_val := round(v_num2 * v_num, 2);
          v_meta := '{}'::jsonb;
        end if;

        -- bojxona (aros_yuk_bojxona) — mavjud bo'lsa qo'shiladi
        v_boj := 0;
        if to_regclass('public.aros_yuk_bojxona') is not null and v_ref ~ '^[0-9]+$' then
          begin
            select coalesce(bojxona_uzs, 0) into v_boj from aros_yuk_bojxona where yuk_id = v_ref::int;
          exception when others then
            v_boj := 0;
          end;
        end if;
        v_row_val := coalesce(v_row_val, 0) + coalesce(v_boj, 0);

        v_y3a_uzs  := v_y3a_uzs + v_row_val;
        v_y3a_soni := v_y3a_soni + 1;
        v_y3a_rows := v_y3a_rows || jsonb_build_object(
          'bolim', 'Y3a', 'ref', v_ref, 'nom', v_nom, 'uzs', v_row_val, 'usd', null,
          'soni', null, 'hisobga', true, 'meta', v_meta);
      end loop;

      v_bolimlar := v_bolimlar || jsonb_build_object('Y3a',
        jsonb_build_object('uzs', v_y3a_uzs, 'usd', null, 'soni', v_y3a_soni));
      v_qatorlar := v_qatorlar || v_y3a_rows;
    end if;
  exception when others then
    v_y3a_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('Y3a', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'Y3a: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [K3b]/[K4] Ko'chirish yo'lda (on_way) / yaratilgan (created)
  -- =====================================================================
  begin
    v_k3b_rows := '[]'::jsonb; v_k3b_uzs := 0; v_k3b_soni := 0;
    v_k4_rows  := '[]'::jsonb; v_k4_uzs  := 0; v_k4_soni  := 0;

    if coalesce(v_manba ->> 'transfers', '') = 'xato' then
      v_k3b_uzs := null; v_k4_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('K3b', null, 'K4', null);
      v_toliq := false;
      v_xatolar := array_append(v_xatolar, 'K3b/K4: manba.transfers=xato — otkazib yuborildi');
    else
      for v_el in select * from jsonb_array_elements(v_transferlar) loop
        v_ref  := coalesce(v_el ->> 'id', '');
        v_nom  := coalesce(v_el ->> 'from_nom', '?') || ' -> ' || coalesce(v_el ->> 'to_nom', '?');
        v_num  := coalesce(nullif(v_el ->> 'tannarx_uzs', '')::numeric,
                            nullif(v_el ->> 'price_uzs', '')::numeric, 0);
        v_txt  := v_el ->> 'status';
        v_bool := coalesce((v_el ->> 'to_brak')::boolean, false);
        v_num2 := nullif(v_el ->> 'order_id', '')::numeric;

        v_meta := '{}'::jsonb;
        if v_bool then v_meta := v_meta || jsonb_build_object('to_brak', true); end if;

        v_hisobga := true;
        if v_num2 is not null and v_num2::int = any(v_order_ids) then
          v_hisobga := false;              -- B6 (ochiq buyurtma) ichida — ikki marta sanalmasin
          v_meta := v_meta || jsonb_build_object('order_qoshildi', true);
        end if;

        if v_txt = 'on_way' then
          v_k3b_soni := v_k3b_soni + 1;
          if v_hisobga then v_k3b_uzs := v_k3b_uzs + v_num; end if;
          v_k3b_rows := v_k3b_rows || jsonb_build_object(
            'bolim', 'K3b', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', null,
            'soni', null, 'hisobga', v_hisobga, 'meta', v_meta);
        elsif v_txt = 'created' then
          v_k4_soni := v_k4_soni + 1;
          if v_hisobga then v_k4_uzs := v_k4_uzs + v_num; end if;
          v_k4_rows := v_k4_rows || jsonb_build_object(
            'bolim', 'K4', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', null,
            'soni', null, 'hisobga', v_hisobga, 'meta', v_meta);
        end if;
      end loop;

      v_bolimlar := v_bolimlar || jsonb_build_object(
        'K3b', jsonb_build_object('uzs', v_k3b_uzs, 'usd', null, 'soni', v_k3b_soni),
        'K4',  jsonb_build_object('uzs', v_k4_uzs,  'usd', null, 'soni', v_k4_soni));
      v_qatorlar := v_qatorlar || v_k3b_rows || v_k4_rows;
    end if;
  exception when others then
    v_k3b_uzs := null; v_k4_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('K3b', null, 'K4', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'K3b/K4: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [B6] Ochiq buyurtmalar — sotuv narxida (total_uzs)
  -- =====================================================================
  begin
    v_b6_rows := '[]'::jsonb; v_b6_uzs := 0; v_b6_soni := 0;

    if coalesce(v_manba ->> 'orders', '') = 'xato' then
      v_b6_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('B6', null);
      v_toliq := false;
      v_xatolar := array_append(v_xatolar, 'B6: manba.orders=xato — otkazib yuborildi');
    else
      for v_el in select * from jsonb_array_elements(v_buyurtmalar) loop
        v_ref := coalesce(v_el ->> 'id', '');
        v_nom := coalesce(v_el ->> 'warehouse', '');
        v_num := coalesce(nullif(v_el ->> 'total_uzs', '')::numeric, 0);

        v_b6_uzs  := v_b6_uzs + v_num;
        v_b6_soni := v_b6_soni + 1;
        v_b6_rows := v_b6_rows || jsonb_build_object(
          'bolim', 'B6', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', null,
          'soni', null, 'hisobga', true, 'meta', jsonb_build_object('status', v_el ->> 'status'));
      end loop;

      v_bolimlar := v_bolimlar || jsonb_build_object('B6',
        jsonb_build_object('uzs', v_b6_uzs, 'usd', null, 'soni', v_b6_soni));
      v_qatorlar := v_qatorlar || v_b6_rows;
    end if;
  exception when others then
    v_b6_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('B6', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'B6: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [Q2a] Bizdan qarzdor — Provodka qarz + Aros mijozlar
  -- ---------------------------------------------------------------------
  -- 🔴 `qarz_umumiy_dash()`/`qarz_dash()`/`aros_qarzdor_dash()` CHAQIRILMAYDI —
  -- ularning ICHIDA `qarz_dash()` `auth.uid() is null` bo'lsa "Avtorizatsiya
  -- kerak" bilan RAISE qiladi va `sorov_page_ok()` (qarz_page_ok orqali)
  -- ATAYLAB fail-closed (auth.uid() null -> false) — bu funksiyalar
  -- service_role/cron kontekstidan UMUMAN chaqirilishga mo'ljallanmagan
  -- (PROVODKA_SOROVLAR.sql/PROVODKA_QARZ.sql tanasi tegilmaydi). Shuning
  -- uchun bir xil raqam FORMULASI to'g'ridan jadval/view'dan takrorlanadi:
  --   Provodka = qarz_dash() dagi "jami_qolgan"  = sum(v_qarz_holat.qolgan) faol qarzlar
  --   Aros     = qarz_umumiy_dash() dagi "aros.total_debt" = aros_qarzdor_sync.summary->>'total_debt'
  --              (aros_qarzdor qatorlari YIG'INDISI EMAS — n8n bergan xom Aros summary).
  -- =====================================================================
  begin
    v_q2a_rows := '[]'::jsonb; v_q2a_uzs := 0;
    v_num := 0; v_num2 := 0;

    if to_regclass('public.qarz') is not null and to_regclass('public.v_qarz_holat') is not null then
      select coalesce(sum(h.qolgan), 0) into v_num
        from qarz q
        join v_qarz_holat h on h.qarz_id = q.id
       where q.status = 'faol';
    end if;

    if to_regclass('public.aros_qarzdor_sync') is not null then
      select coalesce((s.summary ->> 'total_debt')::numeric, 0) into v_num2
        from aros_qarzdor_sync s where s.id = 1;
    end if;

    v_q2a_uzs := coalesce(v_num, 0) + coalesce(v_num2, 0);

    v_q2a_rows := v_q2a_rows
      || jsonb_build_object('bolim', 'Q2a', 'ref', 'provodka', 'nom', 'Provodka qarz (bizdan qarzdor)',
           'uzs', v_num, 'usd', null, 'soni', null, 'hisobga', true, 'meta', '{}'::jsonb)
      || jsonb_build_object('bolim', 'Q2a', 'ref', 'aros', 'nom', 'Aros mijozlar qarzi',
           'uzs', v_num2, 'usd', null, 'soni', null, 'hisobga', true, 'meta', '{}'::jsonb);

    v_bolimlar := v_bolimlar || jsonb_build_object('Q2a',
      jsonb_build_object('uzs', v_q2a_uzs, 'usd', null, 'soni', 2));
    v_qatorlar := v_qatorlar || v_q2a_rows;
  exception when others then
    v_q2a_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('Q2a', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'Q2a: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [Q2b] Biz qarzdormiz — Qarz sahifasi formulasi: yuk status=posted,
  --       narx × kurs − yuk_tolangan_summa, max(0, …)
  -- =====================================================================
  begin
    v_q2b_rows := '[]'::jsonb; v_q2b_uzs := 0; v_q2b_soni := 0;

    if coalesce(v_manba ->> 'incomes', '') = 'xato' then
      v_q2b_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('Q2b', null);
      v_toliq := false;
      v_xatolar := array_append(v_xatolar, 'Q2b: manba.incomes=xato — otkazib yuborildi');
    else
      select coalesce(array_agg((x ->> 'id')::int), '{}')
        into v_yuk_ids
        from jsonb_array_elements(v_yuklar) x
       where x ->> 'status' = 'posted' and (x ->> 'id') ~ '^[0-9]+$';

      v_paid := '[]'::jsonb;
      if coalesce(array_length(v_yuk_ids, 1), 0) > 0
         and _aylanma_fn_bor('yuk_tolangan_summa', 'integer[]') then
        begin
          v_paid := yuk_tolangan_summa(v_yuk_ids);
        exception when others then
          v_paid := '[]'::jsonb;
        end;
      end if;
      v_paid_map := '{}'::jsonb;
      for v_el in select * from jsonb_array_elements(v_paid) loop
        v_paid_map := v_paid_map || jsonb_build_object(v_el ->> 'yuk_id', v_el ->> 'tolangan_uzs');
      end loop;

      select coalesce(array_agg(distinct upper(btrim(x ->> 'valyuta'))), '{}')
        into v_curs
        from jsonb_array_elements(v_yuklar) x
       where x ->> 'status' = 'posted'
         and nullif(btrim(coalesce(x ->> 'valyuta', '')), '') is not null;

      v_kurs_map := '{}'::jsonb;
      if coalesce(array_length(v_curs, 1), 0) > 0
         and _aylanma_fn_bor('yuk_kurslar', 'text[]') then
        begin
          v_kurs_map := yuk_kurslar(v_curs);
        exception when others then
          v_kurs_map := '{}'::jsonb;
        end;
      end if;
      if v_kurs_usd is not null then
        v_kurs_map := v_kurs_map || jsonb_build_object('USD', v_kurs_usd);
      end if;

      -- 🔴 kurs yo'q yuk — qator DOIM qo'shiladi (uzs=null, hisobga=true, meta.kurs_yoq) —
      -- yashirin nol emas (ARX 2-BO'LIM / qarzdor-dev qoidasi). Faqat TO'LIQ TO'LANGAN
      -- (qoldiq=0, kurs BOR) yuklar qatordan tashlab yuboriladi — bu ataylab.
      v_q2b_missing := '{}'::jsonb;
      for v_el in select * from jsonb_array_elements(v_yuklar) x where x ->> 'status' = 'posted' loop
        v_ref  := coalesce(v_el ->> 'id', '');
        v_txt  := upper(btrim(coalesce(v_el ->> 'valyuta', '')));
        v_num  := nullif(v_kurs_map ->> v_txt, '')::numeric;
        v_num2 := coalesce(nullif(v_el ->> 'narx', '')::numeric, 0);
        v_tolangan := coalesce(nullif(v_paid_map ->> v_ref, '')::numeric, 0);
        v_nom := coalesce(v_el ->> 'yetkazuvchi', '')
          || case when nullif(v_el ->> 'ombor', '') is not null then ' · ' || (v_el ->> 'ombor') else '' end;

        if v_num is null then
          v_q2b_soni := v_q2b_soni + 1;
          v_q2b_rows := v_q2b_rows || jsonb_build_object(
            'bolim', 'Q2b', 'ref', v_ref, 'nom', v_nom, 'uzs', null, 'usd', null,
            'soni', null, 'hisobga', true, 'meta', jsonb_build_object('kurs_yoq', true, 'valyuta', v_txt));
          v_q2b_missing := v_q2b_missing
            || jsonb_build_object(v_txt, coalesce((v_q2b_missing ->> v_txt)::int, 0) + 1);
        else
          v_row_val := greatest(0, round(v_num2 * v_num, 2) - v_tolangan);
          if v_row_val > 0 then
            v_q2b_uzs  := v_q2b_uzs + v_row_val;
            v_q2b_soni := v_q2b_soni + 1;
            v_q2b_rows := v_q2b_rows || jsonb_build_object(
              'bolim', 'Q2b', 'ref', v_ref, 'nom', v_nom, 'uzs', v_row_val, 'usd', null,
              'soni', null, 'hisobga', true, 'meta', '{}'::jsonb);
          end if;
          -- qoldiq = 0 (to'liq to'langan) -> qatorga qo'shilmaydi (ataylab)
        end if;
      end loop;

      if v_q2b_missing <> '{}'::jsonb then
        v_toliq := false;
        for v_curkey, v_curcnt in select key, value::numeric from jsonb_each_text(v_q2b_missing) loop
          v_xatolar := array_append(v_xatolar,
            'Q2b: ' || coalesce(v_curkey, '?') || ' kursi yo''q (' || v_curcnt::int || ' yuk)');
        end loop;
      end if;

      v_bolimlar := v_bolimlar || jsonb_build_object('Q2b',
        jsonb_build_object('uzs', v_q2b_uzs, 'usd', null, 'soni', v_q2b_soni));
      v_qatorlar := v_qatorlar || v_q2b_rows;
    end if;
  exception when others then
    v_q2b_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('Q2b', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'Q2b: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [D] Daftar 4010/6010 — QO'SHIMCHA MA'LUMOT, jamiga KIRMAYDI
  -- =====================================================================
  begin
    v_d_rows := '[]'::jsonb;

    if to_regclass('public.v_hisob_qoldiq') is not null then
      for v_ref, v_nom, v_num in
        select h.code, h.code || ' daftar qoldigi', coalesce(h.qoldiq, 0)::numeric
          from v_hisob_qoldiq h
         where h.code in ('4010', '6010')
      loop
        v_d_rows := v_d_rows || jsonb_build_object(
          'bolim', 'D', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', null,
          'soni', null, 'hisobga', false, 'meta', '{}'::jsonb);
      end loop;
    end if;

    v_bolimlar := v_bolimlar || jsonb_build_object('D',
      jsonb_build_object('uzs', null, 'usd', null, 'soni', jsonb_array_length(v_d_rows)));
    v_qatorlar := v_qatorlar || v_d_rows;
  exception when others then
    -- D jamiga kirmaydi — toliq bu sabab bilan false qilinmaydi, faqat qayd etiladi.
    v_bolimlar := v_bolimlar || jsonb_build_object('D', null);
    v_xatolar := array_append(v_xatolar, 'D: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- JAMI: SAK = A+B+T1+T5+Y3a+K3b+K4+B6+Q2a − Q2b  (null = 0)
  -- =====================================================================
  v_jami_uzs := coalesce(v_a_uzs, 0) + coalesce(v_b_uzs, 0) + coalesce(v_t1_uzs, 0)
    + coalesce(v_t5_uzs, 0) + coalesce(v_y3a_uzs, 0) + coalesce(v_k3b_uzs, 0)
    + coalesce(v_k4_uzs, 0) + coalesce(v_b6_uzs, 0) + coalesce(v_q2a_uzs, 0)
    - coalesce(v_q2b_uzs, 0);
  -- USD: jami va usd'si bo'sh bo'limlar so'mdan kurs bilan (2026-09-08 tuzatish —
  -- avval jami_usd faqat A+B yig'indisi edi: 11,98 mlrd so'mga $199 ming chiqardi).
  if coalesce(v_kurs_usd, 0) > 0 then
    v_jami_usd := round(v_jami_uzs / v_kurs_usd, 2);
    for v_ref, v_el in select key, value from jsonb_each(v_bolimlar) loop
      if v_el is not null and jsonb_typeof(v_el) = 'object'
         and (v_el ->> 'usd') is null and (v_el ->> 'uzs') is not null then
        v_bolimlar := jsonb_set(v_bolimlar, array[v_ref, 'usd'],
                        to_jsonb(round((v_el ->> 'uzs')::numeric / v_kurs_usd, 2)));
      end if;
    end loop;
  else
    v_jami_usd := null;
  end if;

  -- ---- yozish: 'cron' — o'sha kunning eski cron qatori bo'lsa o'chirilib
  -- qayta yoziladi (cascade qatorlarni ham olib tashlaydi). 'qolda' — har
  -- doim yangi qator. ----
  if v_rejim = 'cron' then
    delete from aylanma_snapshot where sana = v_sana and rejim = 'cron';
  end if;

  insert into aylanma_snapshot (
    sana, rejim, hisoblangan_at, kurs_usd, jami_uzs, jami_usd, toliq, bolimlar, manba_holati, xatolar)
  values (
    v_sana, v_rejim, now(), v_kurs_usd, v_jami_uzs, v_jami_usd, v_toliq, v_bolimlar, v_manba, v_xatolar)
  returning id into v_snapshot_id;

  if jsonb_array_length(v_qatorlar) > 0 then
    insert into aylanma_qator (snapshot_id, bolim, ref, nom, usd, uzs, soni, hisobga, meta)
    select v_snapshot_id,
           q ->> 'bolim', q ->> 'ref', q ->> 'nom',
           nullif(q ->> 'usd', '')::numeric, nullif(q ->> 'uzs', '')::numeric,
           nullif(q ->> 'soni', '')::numeric, coalesce((q ->> 'hisobga')::boolean, true),
           coalesce(q -> 'meta', '{}'::jsonb)
      from jsonb_array_elements(v_qatorlar) q;
  end if;

  return jsonb_build_object(
    'ok', true, 'id', v_snapshot_id, 'sana', v_sana, 'rejim', v_rejim,
    'jami_uzs', v_jami_uzs, 'jami_usd', v_jami_usd, 'toliq', v_toliq,
    'bolimlar', v_bolimlar, 'xatolar', to_jsonb(v_xatolar));
end
$ayl_sync$;

revoke all on function sync_aylanma_snapshot(jsonb) from public, anon, authenticated;
grant execute on function sync_aylanma_snapshot(jsonb) to service_role;

comment on function sync_aylanma_snapshot(jsonb) is
  'service_role ONLY (n8n «Aros Provodka - Aylanma Snapshot»). Har bo''lim ALOHIDA exception '
  'blokida — bittasi yiqilsa qolganlari yoziladi (D bundan mustasno, jamiga kirmaydi). '
  'rejim=cron: o''sha kun eski qatori o''chirilib qayta yoziladi. PUL HARAKATI YO''Q.';


-- #####################################################################
-- ##  5-BO'LIM — o'qish RPC'lari — authenticated (aylanma_page_ok())  ##
-- #####################################################################
-- 🔴 Ruxsat yo'q bo'lsa `raise exception` EMAS — `{ok:false, kod:'ruxsat'}`
-- (task talabi: UI bu kodni banner uchun ishlatadi).

-- 5.1 aylanma_kun(p_sana, p_id) — bitta kunlik snapshot + qatorlar + oldingi cron
create or replace function aylanma_kun(p_sana date default null, p_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ayl_kun$
declare
  v_snap     aylanma_snapshot%rowtype;
  v_sana     date;
  v_qatorlar jsonb;
  v_oldingi  jsonb;
begin
  if not aylanma_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  if p_id is not null then
    select * into v_snap from aylanma_snapshot where id = p_id;
  else
    v_sana := coalesce(p_sana, (now() at time zone 'Asia/Tashkent')::date);
    -- Tartib: o'sha kun cron → o'sha kunning ENG OXIRGI qo'lda snapshoti →
    -- oldingi kunlarning eng oxirgisi (cron ustun, bo'lmasa qo'lda).
    -- (2026-09-08: faqat cron izlanardi — qo'lda ishga tushirilgan birinchi
    -- snapshot sahifada «ma'lumot yo'q» bo'lib ko'rinardi.)
    select * into v_snap from aylanma_snapshot
     where sana = v_sana
     order by (rejim = 'cron') desc, hisoblangan_at desc
     limit 1;
    if not found then
      select * into v_snap from aylanma_snapshot
       where sana < v_sana
       order by sana desc, (rejim = 'cron') desc, hisoblangan_at desc
       limit 1;
    end if;
  end if;

  if not found then
    return jsonb_build_object('ok', true, 'snapshot', null, 'qatorlar', '[]'::jsonb, 'oldingi', null);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'bolim', q.bolim, 'ref', q.ref, 'nom', q.nom,
           'usd', q.usd, 'uzs', q.uzs, 'soni', q.soni, 'hisobga', q.hisobga, 'meta', q.meta)
           order by q.bolim, q.uzs desc nulls last), '[]'::jsonb)
    into v_qatorlar
    from aylanma_qator q
   where q.snapshot_id = v_snap.id;

  select jsonb_build_object('id', o.id, 'sana', o.sana, 'jami_uzs', o.jami_uzs, 'bolimlar', o.bolimlar)
    into v_oldingi
    from aylanma_snapshot o
   where o.rejim = 'cron' and o.sana < v_snap.sana
   order by o.sana desc
   limit 1;

  return jsonb_build_object(
    'ok', true,
    'snapshot', jsonb_build_object(
      'id', v_snap.id, 'sana', v_snap.sana, 'rejim', v_snap.rejim,
      'hisoblangan_at', v_snap.hisoblangan_at, 'kurs_usd', v_snap.kurs_usd,
      'jami_uzs', v_snap.jami_uzs, 'jami_usd', v_snap.jami_usd, 'toliq', v_snap.toliq,
      'bolimlar', v_snap.bolimlar, 'manba_holati', v_snap.manba_holati,
      'xatolar', to_jsonb(v_snap.xatolar)),
    'qatorlar', v_qatorlar,
    'oldingi', v_oldingi);
end
$ayl_kun$;

revoke all on function aylanma_kun(date, uuid) from public, anon;
grant execute on function aylanma_kun(date, uuid) to authenticated;

comment on function aylanma_kun(date, uuid) is
  'Bitta kunlik SAK snapshot (p_id bo''lsa aniq shu qator, aks holda p_sana — sukut bugun — '
  'uchun cron qator, bo''lmasa undan oldingi eng oxirgi cron) + qatorlar + oldingi cron kun.';


-- 5.2 aylanma_trend(p_from, p_to) — grafik uchun kunlik jami (faqat cron, <=400 kun)
create or replace function aylanma_trend(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ayl_trend$
declare
  v_from date := p_from;
  v_to   date := p_to;
  v_tmp  date;
  v_rows jsonb;
begin
  if not aylanma_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  if v_from is null or v_to is null then
    return jsonb_build_object('ok', false, 'error', 'p_from/p_to kerak');
  end if;
  if v_to < v_from then
    v_tmp := v_from; v_from := v_to; v_to := v_tmp;    -- swap (chegara noto'g'ri kelsa)
  end if;
  if (v_to - v_from) > 400 then
    v_from := v_to - 400;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'sana', s.sana, 'jami_uzs', s.jami_uzs, 'jami_usd', s.jami_usd,
           'kurs_usd', s.kurs_usd, 'toliq', s.toliq, 'bolimlar', s.bolimlar)
           order by s.sana), '[]'::jsonb)
    into v_rows
    from aylanma_snapshot s
   where s.rejim = 'cron' and s.sana between v_from and v_to;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end
$ayl_trend$;

revoke all on function aylanma_trend(date, date) from public, anon;
grant execute on function aylanma_trend(date, date) to authenticated;

comment on function aylanma_trend(date, date) is
  'Grafik uchun: p_from..p_to oralig''ida FAQAT rejim=cron kunlik jami/bo''limlar (<=400 kun).';


-- 5.3 aylanma_royxat(p_sana) — shu kundagi hamma snapshot (cron + qolda), qisqa
create or replace function aylanma_royxat(p_sana date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ayl_royxat$
declare
  v_rows jsonb;
begin
  if not aylanma_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  if p_sana is null then
    return jsonb_build_object('ok', false, 'error', 'p_sana kerak');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'rejim', s.rejim, 'hisoblangan_at', s.hisoblangan_at,
           'jami_uzs', s.jami_uzs, 'jami_usd', s.jami_usd, 'toliq', s.toliq)
           order by s.hisoblangan_at desc nulls last, s.created_at desc), '[]'::jsonb)
    into v_rows
    from aylanma_snapshot s
   where s.sana = p_sana;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end
$ayl_royxat$;

revoke all on function aylanma_royxat(date) from public, anon;
grant execute on function aylanma_royxat(date) to authenticated;

comment on function aylanma_royxat(date) is
  'Berilgan sanadagi HAMMA snapshot (cron + qolda), qisqa shakl — tanlov ro''yxati uchun.';


-- 5.4 aylanma_qatorlar(p_id, p_bolim) — drill-down
create or replace function aylanma_qatorlar(p_id uuid, p_bolim text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ayl_qatorlar$
declare
  v_rows jsonb;
begin
  if not aylanma_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  if p_id is null then
    return jsonb_build_object('ok', false, 'error', 'p_id kerak');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'bolim', q.bolim, 'ref', q.ref, 'nom', q.nom,
           'usd', q.usd, 'uzs', q.uzs, 'soni', q.soni, 'hisobga', q.hisobga, 'meta', q.meta)
           order by q.uzs desc nulls last), '[]'::jsonb)
    into v_rows
    from aylanma_qator q
   where q.snapshot_id = p_id
     and (p_bolim is null or q.bolim = p_bolim);

  return jsonb_build_object('ok', true, 'rows', v_rows);
end
$ayl_qatorlar$;

revoke all on function aylanma_qatorlar(uuid, text) from public, anon;
grant execute on function aylanma_qatorlar(uuid, text) to authenticated;

comment on function aylanma_qatorlar(uuid, text) is
  'Bitta snapshot ichida bitta bo''lim (yoki hammasi, p_bolim null) uchun drill-down qatorlar.';


-- #####################################################################
-- ##  6-BO'LIM — PostgREST sxema keshini yangilash                    ##
-- #####################################################################

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  7-BO'LIM — DIAG / YAKUNIY TEKSHIRUV (faqat select/raise)         ##
-- #####################################################################

do $ayl_final$
declare
  v_ok boolean;
begin
  if to_regclass('public.aylanma_snapshot') is null then
    raise exception 'YAKUNIY TEKSHIRUV: aylanma_snapshot jadvali yaralmadi';
  end if;
  if to_regclass('public.aylanma_qator') is null then
    raise exception 'YAKUNIY TEKSHIRUV: aylanma_qator jadvali yaralmadi';
  end if;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('_aylanma_fn_bor', '_aylanma_is_admin', 'aylanma_page_ok',
                             'sync_aylanma_snapshot', 'aylanma_kun',
                             'aylanma_trend', 'aylanma_royxat', 'aylanma_qatorlar')) < 8 then
    raise exception 'YAKUNIY TEKSHIRUV: aylanma RPC lardan birortasi yaralmadi';
  end if;

  if not ('aylanma' = any(perm_pages())) then
    raise exception 'YAKUNIY TEKSHIRUV: perm_pages() da aylanma kaliti yoq';
  end if;

  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'aylanma_snapshot'
                    and policyname = 'aylanma_snapshot_select') then
    raise exception 'YAKUNIY TEKSHIRUV: aylanma_snapshot_select policy yoq';
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'aylanma_qator'
                    and policyname = 'aylanma_qator_select') then
    raise exception 'YAKUNIY TEKSHIRUV: aylanma_qator_select policy yoq';
  end if;

  select has_function_privilege('service_role', 'public.sync_aylanma_snapshot(jsonb)', 'execute') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: service_role uchun sync_aylanma_snapshot(jsonb) EXECUTE yoq';
  end if;

  select has_function_privilege('authenticated', 'public.sync_aylanma_snapshot(jsonb)', 'execute') into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated sync_aylanma_snapshot(jsonb) ni chaqira olmasligi kerak edi';
  end if;

  select has_function_privilege('authenticated', 'public.aylanma_kun(date,uuid)', 'execute') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun aylanma_kun(date,uuid) EXECUTE yoq';
  end if;

  raise notice 'PROVODKA_AYLANMA.sql: hammasi joyida';
end
$ayl_final$;

-- ---- DIAG (informatsion, faqat manual tekshiruv uchun — RUN natijasini
-- Asilbek "Results" panelida ko'radi, xato bermaydi) ----
select count(*) as jami_snapshot,
       count(*) filter (where rejim = 'cron')  as cron_soni,
       count(*) filter (where rejim = 'qolda') as qolda_soni
  from aylanma_snapshot;

select id, sana, jami_uzs, jami_usd, kurs_usd, toliq, hisoblangan_at
  from aylanma_snapshot
 where rejim = 'cron'
 order by sana desc
 limit 1;
