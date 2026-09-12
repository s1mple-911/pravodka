-- =====================================================================
--  PROVODKA_HODIM_TELEGRAM.sql — Hodim xarajat kassalarini Telegram
--  foydalanuvchisiga (Aros users) bog'lash UI + registr + avtomatik taklif
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).
--  Muammo: hodim xarajat kassasida (5400 guruh ostidagi 54xx,
--  kassa_turi='xarajat') harakat bo'lsa n8n «Aros Provodka - Hodim
--  Notify» ikkalasiga (hodim + adminlar) Telegram xabar yuboradi.
--  Hodim `accounts.taskfix_user_id` orqali topiladi. Bu maydonni
--  to'ldiradigan UI umuman yo'q edi — masalan `xarajat_kassa_yarat`
--  (kassa-dev "Kassa qo'shish") ataylab bo'sh qoldiradi. Bo'sh bo'lsa
--  xabar FAQAT adminlarga ketadi.
--
--  #####  YECHIM  #########################################################
--  1) `aros_tg_user` — Aros PG `users` jadvalining registri (n8n har soat,
--     N8N_TG_USER_SYNC.js). Maxfiy ustunlar (password_hash/telegram_id/...)
--     KO'CHIRILMAYDI — bog'lash `users.id` (matn) orqali, n8n o'zi
--     `telegram_id`ga aylantiradi (N8N_HODIM_NOTIFY.js `byKey`).
--  2) `hodim_tg_royxat()` — sozlama-dev.html uchun: hamma hodim kassasi +
--     holati + bog'lanmaganlar uchun ism/telefon o'xshashligiga qarab
--     taklif ro'yxati.
--  3) `hodim_tg_bogla()` — bitta kassani qo'lda bog'lash/uzish.
--  4) `hodim_tg_avto_bogla()` — aniq (ball=3, yagona nomzod) hamma
--     kassani bir zarbda bog'laydi, chalkash holatlarni qo'lga qaytaradi.
--
--  #####  🔴 PUL HARAKATI YO'Q  ############################################
--  Bu fayl `entry`/`entry_line`ga hech narsa yozmaydi — faqat
--  `accounts.taskfix_user_id` (matn maydon, mavjud ustun) ni yangilaydi.
--
--  #####  FAYL TARKIBI  ####################################################
--     0-BO'LIM  — old shart tekshiruvi (faqat select/raise)
--     1-BO'LIM  — accounts.taskfix_user_id ustuni (additive, allaqachon
--                 bor bo'lishi mumkin — no-op)
--     2-BO'LIM  — jadval aros_tg_user (+ indeks + RLS)
--     3-BO'LIM  — ICHKI yordamchilar: nom/telefon solishtirish
--                 (authenticated'ga GRANT qilinmaydi)
--     4-BO'LIM  — hodim_tg_page_ok() — yagona ruxsat qoidasi
--     5-BO'LIM  — sync_aros_tg_user(p_rows) — service_role ONLY (n8n)
--     6-BO'LIM  — hodim_tg_royxat() — sozlama-dev.html ro'yxat + taklif
--     7-BO'LIM  — hodim_tg_bogla(p_kassa, p_user_id) — bog'lash/uzish
--     8-BO'LIM  — hodim_tg_avto_bogla() — aniq nomzodlarni bir zarbda bog'laydi
--     9-BO'LIM  — PostgREST sxema keshini yangilash
--    10-BO'LIM  — YAKUNIY TEKSHIRUV (faqat select/raise)
--
--  #####  ADDITIVE KAFOLATI  ###############################################
--   * Hech narsa drop qilinmaydi, mavjud ustun/funksiya imzosi
--     o'zgartirilmaydi. Hammasi YANGI, `aros_tg_user`/`hodim_tg_`/`sync_
--     aros_tg_user` prefiksi bilan.
--   * Idempotent: `create table if not exists`, `create or replace
--     function`, `drop policy if exists` + `create policy`.
--   * Anonim `do` bloki YO'Q — har `do` bloki nomlangan teg bilan. Har
--     funksiya tanasi ham nomlangan teg bilan. Izohlarda ketma-ket dollar
--     belgi YOZILMAGAN (soxta blok xavfi — CLAUDE.md).
--
--  #####  RUXSAT  ###########################################################
--  O'qish/yozish (RPC): admin YOKI `perm_has_page('sozlama')`
--  (`hodim_tg_page_ok()`, yagona qoida). `perm_has_page` bazada bo'lmasa
--  FAIL-CLOSED (faqat admin) — `standart_page_ok()` naqshi bilan bir xil.
--  `sync_aros_tg_user` — service_role ONLY (n8n webhook).
--
--  #####  TALAB (0-BO'LIM tekshiradi)  ######################################
--     accounts, aros_staff, is_admin()   — mavjud bazada
--
--  🔴 SQL'ni ASILBEK o'zi RUN qiladi. Agent bajarmaydi.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (faqat select/raise)            ##
-- #####################################################################

do $htg_pre$
begin
  if to_regclass('public.accounts') is null then
    raise exception 'accounts jadvali yoq';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'accounts'
                    and column_name = 'kassa_turi') then
    raise exception 'accounts.kassa_turi ustuni yoq';
  end if;
  if to_regclass('public.aros_staff') is null then
    raise exception 'aros_staff jadvali yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'is_admin') then
    raise exception 'is_admin() funksiyasi yoq';
  end if;
end
$htg_pre$;


-- #####################################################################
-- ##  1-BO'LIM — accounts.taskfix_user_id ustuni (additive)          ##
-- #####################################################################
-- Ustun PROVODKA_XARAJAT_TOSIQ.sql da allaqachon qo'shilgan (matn) —
-- bu qator shu ustunga tayanadigan yagona fayl bo'lmasligi uchun
-- idempotent takror (bor bo'lsa no-op).

alter table accounts add column if not exists taskfix_user_id text;

comment on column accounts.taskfix_user_id is
  'Hodim xarajat kassasi (54xx) qaysi Aros userga (users.id, matn) tegishli — '
  'n8n "Aros Provodka - Hodim Notify" shu orqali Telegram xabar yuboradi. '
  'Bo''sh bo''lsa xabar faqat adminlarga ketadi. hodim_tg_bogla() orqali to''ldiriladi.';


-- #####################################################################
-- ##  2-BO'LIM — jadval aros_tg_user (+ indeks + RLS)                 ##
-- #####################################################################
-- Aros PG `users` jadvalining REGISTRI (n8n "Aros Provodka - Telegram
-- User Sync", har soat). 🔴 Maxfiy ustunlar (password_hash, reset_code,
-- reset_expires, telegram_id) HECH QACHON bu yerga ko'chirilmaydi —
-- bog'lash users.id (matn) orqali, n8n o'zi telegram_id ga aylantiradi.

create table if not exists aros_tg_user (
  user_id         text        primary key,
  ism             text        not null default '',
  lavozim         text,
  warehouse_name  text,
  telefon         text,
  worker_id       text,
  status          text,
  faol            boolean     not null default true,
  synced_at       timestamptz,
  created_at      timestamptz not null default now()
);

comment on table aros_tg_user is
  'Aros PG users jadvalining REGISTRI (n8n har soat, N8N_TG_USER_SYNC.js). '
  'Maxfiy ustunlar (password_hash/telegram_id/reset_*) YO''Q. user_id = Aros '
  'users.id (matn) — accounts.taskfix_user_id shu bilan bog''lanadi. '
  'faol=false — so''nggi sinxronda ro''yxatda ko''rinmay qolgan (o''chirilmaydi).';

create index if not exists idx_aros_tg_user_ism on aros_tg_user (ism);

alter table aros_tg_user enable row level security;
revoke all on table aros_tg_user from public, anon;
grant select on table aros_tg_user to authenticated;


-- #####################################################################
-- ##  3-BO'LIM — ICHKI yordamchilar: nom/telefon solishtirish        ##
-- ---------------------------------------------------------------------
-- Kassa nomi (hodim ismi) va Aros foydalanuvchi ismini solishtirish.
-- standart_branch_takliflar (PROVODKA_STANDART_ROL.sql) dagi g'oyaning
-- o'zi (norm + translit), lekin ODAM ISMI uchun MOSLASHTIRILGAN:
--   * standart_norm "kassa" so'zini olib tashlaydi (filial nomlari uchun
--     mo'ljallangan) — odam ismida keraksiz, shuning uchun bu yerda
--     alohida yordamchi.
--   * standart_ball CONTAINMENT (bir-birining ichida) bo'lsa ham 3 (to'liq)
--     beradi — ism uchun bu xavfli (masalan "Sardor" va "Sardorbek" —
--     ikkalasi ham >=4 harf, containment true, lekin BOSHQA odam bo'lishi
--     mumkin). Shuning uchun bu yerda 3 = FAQAT to'liq (normalize qilingandan
--     keyin) teng, 2 = so'zlar TO'PLAMI teng (tartib farq qilishi mumkin —
--     "Familiya Ism" vs "Ism Familiya").
-- authenticated'ga GRANT QILINMAYDI (rbac_limit_modda/standart_norm naqshi)
-- — faqat pastdagi SECURITY DEFINER RPC'lar ichidan chaqiriladi.
-- #####################################################################

-- 3.1 Kirill (o'zbek) -> lotin transliteratsiya + pastki registr.
--     Faqat harf almashtirish, bo'shliq/tinish belgilari TEGILMAYDI —
--     so'zlarga bo'lish (3.3) shundan keyin qilinadi. Apostrof (ғ/ў ning
--     lotin yozilishidagi "g'"/"o'" qismi) ATAYLAB tashlanadi — keyingi
--     bosqich (hodim_tg_norm/hodim_tg_words) apostrofni baribir olib
--     tashlaydi, shuning uchun oddiy "g"/"o" yetarli (chiroyli "g'" yasab,
--     keyin uni yana yo'qotishning ma'nosi yo'q). Massiv-halqa (nested
--     replace o'rniga) — 30+ ta harf almashtirish ketma-ket yozilganda
--     bittasi tushib qolish xavfi yuqori edi (2026-09-12 tuzatish).
create or replace function hodim_tg_translit(p_text text)
returns text
language plpgsql
immutable
as $fn$
declare
  v_pairs text[][] := array[
    ['ё','yo'],['ж','j'],['ц','ts'],['ч','ch'],['ш','sh'],['щ','sh'],['ъ',''],
    ['ы','i'],['э','e'],['ю','yu'],['я','ya'],['қ','q'],['ғ','g'],['ҳ','h'],['ў','o'],
    ['а','a'],['б','b'],['в','v'],['г','g'],['д','d'],['е','e'],['з','z'],['и','i'],
    ['й','y'],['к','k'],['л','l'],['м','m'],['н','n'],['о','o'],['п','p'],['р','r'],
    ['с','s'],['т','t'],['у','u'],['ф','f'],['х','x']
  ];
  v_out text := lower(coalesce(p_text, ''));
  i int;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    v_out := replace(v_out, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  return v_out;
end
$fn$;

revoke all on function hodim_tg_translit(text) from public, anon, authenticated;

comment on function hodim_tg_translit(text) is
  'ICHKI: kirill (o''zbek) harflarni lotinga o''giradi + pastki registr. '
  'Bo''shliq/tinish belgilari tegilmaydi (so''zga bo''lish keyingi bosqichda).';

-- 3.2 To'liq-teng solishtirish uchun: bo'shliq/tinish/apostrof HAM olib
--     tashlanadi (harf-raqamdan boshqa hammasi).
create or replace function hodim_tg_norm(p_text text)
returns text
language sql
immutable
as $fn$
  select regexp_replace(hodim_tg_translit(p_text), '[^a-z0-9]', '', 'g');
$fn$;

revoke all on function hodim_tg_norm(text) from public, anon, authenticated;

comment on function hodim_tg_norm(text) is
  'ICHKI: hodim_tg_translit() + harf-raqamdan boshqa hamma belgi olib tashlanadi '
  '(bo''shliq/apostrof/tinish). To''liq-teng solishtirish uchun (ball=3).';

-- 3.3 So'zlar to'plami — tartibga qaramaydigan solishtirish uchun (ball=2).
create or replace function hodim_tg_words(p_text text)
returns text[]
language sql
immutable
as $fn$
  select coalesce(array_agg(distinct w order by w) filter (where w <> ''), '{}')
    from (
      select regexp_replace(x, '[^a-z0-9]', '', 'g') as w
        from unnest(regexp_split_to_array(btrim(hodim_tg_translit(p_text)), '\s+')) x
    ) t;
$fn$;

revoke all on function hodim_tg_words(text) from public, anon, authenticated;

comment on function hodim_tg_words(text) is
  'ICHKI: hodim_tg_translit() dan keyin so''zlarga bo''linadi, har so''z '
  'normallashtiriladi, natija TARTIBLANGAN to''plam (distinct+order) — '
  '"Familiya Ism" va "Ism Familiya" bir xil massiv beradi.';

-- 3.4 Ball: 3 = to'liq teng, 2 = so'zlar to'plami teng, 0 = mos kelmadi.
--     🔴 CONTAINMENT YO'Q (standart_ball dan farqi) — odam ismi uchun
--     "bir-birining ichida" xavfli (yolg'on to'liq moslik).
create or replace function hodim_tg_ball(p_a text, p_b text)
returns int
language plpgsql
immutable
as $fn$
declare
  v_na text := hodim_tg_norm(p_a);
  v_nb text := hodim_tg_norm(p_b);
begin
  if v_na = '' or v_nb = '' then
    return 0;
  end if;
  if v_na = v_nb then
    return 3;
  end if;
  if hodim_tg_words(p_a) = hodim_tg_words(p_b) then
    return 2;
  end if;
  return 0;
end
$fn$;

revoke all on function hodim_tg_ball(text, text) from public, anon, authenticated;

comment on function hodim_tg_ball(text, text) is
  'ICHKI: ism/kassa nomi ball (0/2/3) — hodim_tg_norm/hodim_tg_words asosida. '
  '3 = to''liq teng, 2 = so''zlar to''plami teng (tartib farqi bilan), 0 = mos kelmadi.';

-- 3.5 Telefon solishtirish: faqat raqamlar, oxirgi 9 xonasi (O'zbekiston
--     kod +998 farqi bo'lsa ham mos keladi).
create or replace function hodim_tg_tel_norm(p_tel text)
returns text
language sql
immutable
as $fn$
  select case when length(regexp_replace(coalesce(p_tel, ''), '[^0-9]', '', 'g')) >= 9
              then right(regexp_replace(coalesce(p_tel, ''), '[^0-9]', '', 'g'), 9)
              else null end;
$fn$;

revoke all on function hodim_tg_tel_norm(text) from public, anon, authenticated;

comment on function hodim_tg_tel_norm(text) is
  'ICHKI: telefonni faqat raqamlarga qisqartiradi, oxirgi 9 xona (9 xonadan '
  'kam bo''lsa NULL — mos kelmagan deb hisoblanadi, taxminiy solishtirish yo''q).';

create or replace function hodim_tg_tel_match(p_a text, p_b text)
returns boolean
language sql
immutable
as $fn$
  select hodim_tg_tel_norm(p_a) is not null
     and hodim_tg_tel_norm(p_a) = hodim_tg_tel_norm(p_b);
$fn$;

revoke all on function hodim_tg_tel_match(text, text) from public, anon, authenticated;

comment on function hodim_tg_tel_match(text, text) is
  'ICHKI: ikki telefon (oxirgi 9 xona) bir xilmi. Ikkalasi ham bo''sh/qisqa bo''lsa false.';


-- #####################################################################
-- ##  4-BO'LIM — hodim_tg_page_ok() — yagona ruxsat qoidasi           ##
-- #####################################################################
-- standart_page_ok() (PROVODKA_STANDART_RUXSAT.sql) bilan AYNI naqsh:
-- admin YOKI perm_has_page('sozlama'). perm_has_page bazada yo'q bo'lsa
-- FAIL-CLOSED (faqat admin).

create or replace function hodim_tg_page_ok()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    return false;
  end if;
  if is_admin() then
    return true;
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'perm_has_page') then
    return perm_has_page('sozlama');
  end if;
  return false;
end
$fn$;

revoke all on function hodim_tg_page_ok() from public, anon;
grant execute on function hodim_tg_page_ok() to authenticated;

comment on function hodim_tg_page_ok() is
  'Hodim -> Telegram bog''lash sahifasi ruxsati: admin YOKI perm_has_page(''sozlama''). '
  'perm_has_page yoq bazada fail-closed (faqat admin). aros_tg_user select policy''si ham shundan.';

drop policy if exists aros_tg_user_select on aros_tg_user;
create policy aros_tg_user_select on aros_tg_user
  for select to authenticated
  using (hodim_tg_page_ok());


-- #####################################################################
-- ##  5-BO'LIM — sync_aros_tg_user(p_rows) — service_role ONLY (n8n)  ##
-- #####################################################################
-- Kirish: {p_rows: [{user_id, ism, lavozim, warehouse_name, telefon,
-- worker_id, status}, ...]} — Aros PG users jadvalidan (maxfiy ustunlar
-- YO'Q). 🔴 rows >= 50 bo'lsagina sweep (payloadda yo'q qolganlar
-- faol=false) — chala/bo'sh payload sweep QILMAYDI (aros_qarzdor naqshi,
-- bu yerda esa n8n bitta so'rovda HAMMA userni yuboradi — sahifalash yo'q).

create or replace function sync_aros_tg_user(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_role       text;
  v_el         jsonb;
  v_uid        text;
  v_ism        text;
  v_lavozim    text;
  v_wh         text;
  v_tel        text;
  v_worker     text;
  v_status     text;
  v_ids        text[] := '{}';
  n_yozildi    int := 0;
  n_yangilandi int := 0;
  n_tashlandi  int := 0;
  n_nofaol     int := 0;
  v_was_insert boolean;
begin
  if auth.uid() is not null then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;
  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is not null and v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('sync_aros_tg_user'));

  if p_rows is null or jsonb_typeof(p_rows) is distinct from 'array' then
    return jsonb_build_object('ok', false, 'error', 'p_rows massiv kutilgan edi');
  end if;

  for v_el in select * from jsonb_array_elements(p_rows)
  loop
    begin
      v_uid := nullif(btrim(coalesce(v_el ->> 'user_id', '')), '');
      if v_uid is null then
        n_tashlandi := n_tashlandi + 1;
        continue;
      end if;
      v_ids := array_append(v_ids, v_uid);

      v_ism     := coalesce(nullif(btrim(coalesce(v_el ->> 'ism', '')), ''), '');
      v_lavozim := nullif(btrim(coalesce(v_el ->> 'lavozim', '')), '');
      v_wh      := nullif(btrim(coalesce(v_el ->> 'warehouse_name', '')), '');
      v_tel     := nullif(btrim(coalesce(v_el ->> 'telefon', '')), '');
      v_worker  := nullif(btrim(coalesce(v_el ->> 'worker_id', '')), '');
      v_status  := nullif(btrim(coalesce(v_el ->> 'status', '')), '');

      insert into aros_tg_user (user_id, ism, lavozim, warehouse_name, telefon, worker_id, status, faol, synced_at)
      values (v_uid, v_ism, v_lavozim, v_wh, v_tel, v_worker, v_status, true, now())
      on conflict (user_id) do update
         set ism            = excluded.ism,
             lavozim         = excluded.lavozim,
             warehouse_name  = excluded.warehouse_name,
             telefon         = excluded.telefon,
             worker_id       = excluded.worker_id,
             status          = excluded.status,
             faol            = true,
             synced_at       = now()
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

  -- Payloadda ko'rinmay qolganlar -> faol=false. FAQAT to'liq payloadda
  -- (>=50 qator) — chala/bo'sh payload hammani nofaol qilib yubormasin.
  if jsonb_array_length(p_rows) >= 50 then
    update aros_tg_user
       set faol = false
     where faol = true
       and not (user_id = any(v_ids));
    get diagnostics n_nofaol = row_count;
  end if;

  return jsonb_build_object(
    'ok', true,
    'yozildi', n_yozildi,
    'yangilandi', n_yangilandi,
    'nofaol', n_nofaol,
    'tashlandi', n_tashlandi);
end
$fn$;

revoke all on function sync_aros_tg_user(jsonb) from public, anon, authenticated;
grant execute on function sync_aros_tg_user(jsonb) to service_role;

comment on function sync_aros_tg_user(jsonb) is
  'service_role ONLY (n8n "Aros Provodka - Telegram User Sync"). aros_tg_user ni upsert '
  'qiladi. Maxfiy ustunlar (password_hash/telegram_id/reset_*) qabul qilinmaydi/saqlanmaydi. '
  'rows>=50 bo''lsagina payloadda yo''q qolganlar faol=false qilinadi.';


-- #####################################################################
-- ##  6-BO'LIM — hodim_tg_royxat() — sozlama-dev.html                 ##
-- #####################################################################
-- Kassa = accounts da kassa_turi='xarajat' (54xx, otasi kassa_turi=
-- 'xarajat_guruh'), pul_turi IS NULL, currency='UZS' (bola-hisoblar —
-- pul turi/valyuta — CHIQMAYDI, PROVODKA_TURLAR_AVTO.sql 282-qator naqshi).
-- Taklif — FAQAT bog'lanmagan (holat<>'boglangan') kassalar uchun, ball>=2
-- bo'lgan juftliklar. Telefon/worker_id bonusi — aros_staff orqali KO'PRIK
-- (kassa nomi <-> aros_staff.toliq_nom TO'LIQ teng bo'lsagina ishonchli
-- hisoblanadi): agar ism ball=2 bo'lsa-yu, shu ko'prikdagi hodimning
-- worker_id/telefoni nomzod bilan mos kelsa — ball 2 dan 3 ga ko'tariladi.
-- Ball 0 (mos kelmagan) hech qachon ko'tarilmaydi ("unga tayanib qolma").

create or replace function hodim_tg_royxat()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not hodim_tg_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  return (
    with kassalar_raw as (
      select a.id, a.code, a.name, a.subtitle, a.taskfix_user_id
        from accounts a
        join accounts g on g.id = a.parent_id and g.kassa_turi = 'xarajat_guruh'
       where a.kassa_turi = 'xarajat'
         and a.pul_turi is null
         and coalesce(a.currency, 'UZS') = 'UZS'
         and coalesce(a.is_active, true)
    ),
    kassalar_link as (
      select k.*,
             t.ism as bogl_ism, t.lavozim as bogl_lavozim,
             case
               when k.taskfix_user_id is null or btrim(k.taskfix_user_id) = '' then 'yoq'
               when t.user_id is not null then 'boglangan'
               else 'topilmadi'
             end as holat
        from kassalar_raw k
        left join aros_tg_user t
          on t.user_id = k.taskfix_user_id and t.faol
    ),
    users_faol as (
      select t.user_id, t.ism, t.lavozim, t.warehouse_name, t.telefon, t.worker_id
        from aros_tg_user t
       where t.faol
    ),
    staff_bridge as (
      -- Kassa nomi <-> aros_staff.toliq_nom TO'LIQ teng (ball=3) bo'lsagina
      -- ko'prik ishonchli hisoblanadi (fuzzy ko'prik xato bog'lanish xavfi
      -- keltiradi — Telegram xabari begona odamga ketishi mumkin).
      select k.id as kassa_id, s.staff_id, s.telefon as staff_tel
        from kassalar_link k
        join aros_staff s on s.is_active and hodim_tg_norm(s.toliq_nom) = hodim_tg_norm(k.name)
       where k.holat <> 'boglangan'
    ),
    taklif_raw as (
      select k.id as kassa_id, u.user_id,
             case
               when hodim_tg_ball(k.name, u.ism) = 3 then 3
               when hodim_tg_ball(k.name, u.ism) = 2
                    and exists (
                      select 1 from staff_bridge b
                       where b.kassa_id = k.id
                         and (b.staff_id::text = u.worker_id or hodim_tg_tel_match(b.staff_tel, u.telefon))
                    ) then 3
               else hodim_tg_ball(k.name, u.ism)
             end as ball
        from kassalar_link k
        cross join users_faol u
       where k.holat <> 'boglangan'
    )
    select jsonb_build_object(
      'ok', true,
      'kassalar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', kl.id, 'code', kl.code, 'name', kl.name, 'subtitle', kl.subtitle,
                 'taskfix_user_id', kl.taskfix_user_id,
                 'bogl_ism', kl.bogl_ism, 'bogl_lavozim', kl.bogl_lavozim, 'holat', kl.holat)
               order by kl.code)
        from kassalar_link kl), '[]'::jsonb),
      'users', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'user_id', u.user_id, 'ism', u.ism, 'lavozim', u.lavozim,
                 'warehouse_name', u.warehouse_name, 'telefon', u.telefon)
               order by u.ism)
        from users_faol u), '[]'::jsonb),
      'taklif', coalesce((
        select jsonb_agg(jsonb_build_object('kassa_id', tr.kassa_id, 'user_id', tr.user_id, 'ball', tr.ball)
               order by tr.kassa_id, tr.ball desc)
        from taklif_raw tr where tr.ball >= 2), '[]'::jsonb)
    )
  );
end
$fn$;

revoke all on function hodim_tg_royxat() from public, anon;
grant execute on function hodim_tg_royxat() to authenticated;

comment on function hodim_tg_royxat() is
  'sozlama-dev.html: hamma hodim xarajat kassasi (54xx) + bog''lanish holati + '
  'bog''lanmaganlar uchun ball>=2 taklif ro''yxati. Ruxsat: hodim_tg_page_ok() '
  '(aks holda {ok:false,kod:ruxsat}).';


-- #####################################################################
-- ##  7-BO'LIM — hodim_tg_bogla(p_kassa, p_user_id)                    ##
-- #####################################################################
-- p_user_id NULL -> uzadi. Aks holda p_user_id aros_tg_user da FAOL
-- bo'lishi shart. Faqat kassa_turi='xarajat' kassaga. entry/entry_line
-- ga TEGMAYDI.

create or replace function hodim_tg_bogla(p_kassa uuid, p_user_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_kassa accounts%rowtype;
  v_uid   text := nullif(btrim(coalesce(p_user_id, '')), '');
begin
  if not hodim_tg_page_ok() then
    raise exception 'Sozlamalar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;
  if p_kassa is null then
    raise exception 'Kassa tanlanmadi' using errcode = '22000';
  end if;

  select * into v_kassa from accounts where id = p_kassa and kassa_turi = 'xarajat';
  if not found then
    raise exception 'Hodim xarajat kassasi topilmadi (kassa_turi=xarajat bo''lishi shart)'
      using errcode = '22023';
  end if;

  if v_uid is null then
    update accounts set taskfix_user_id = null where id = p_kassa;
    return jsonb_build_object('ok', true, 'kassa_id', p_kassa, 'user_id', null);
  end if;

  if not exists (select 1 from aros_tg_user where user_id = v_uid and faol) then
    raise exception 'Bu foydalanuvchi Telegram ro''yxatida topilmadi yoki nofaol'
      using errcode = '22023';
  end if;

  update accounts set taskfix_user_id = v_uid where id = p_kassa;
  return jsonb_build_object('ok', true, 'kassa_id', p_kassa, 'user_id', v_uid);
end
$fn$;

revoke all on function hodim_tg_bogla(uuid, text) from public, anon;
grant execute on function hodim_tg_bogla(uuid, text) to authenticated;

comment on function hodim_tg_bogla(uuid, text) is
  'Bitta hodim xarajat kassasini Aros userga (aros_tg_user, faol) bog''laydi. '
  'p_user_id NULL -> uzadi. Faqat kassa_turi=xarajat. entry/entry_line ga tegmaydi. '
  'Ruxsat: hodim_tg_page_ok().';


-- #####################################################################
-- ##  8-BO'LIM — hodim_tg_avto_bogla()                                 ##
-- ---------------------------------------------------------------------
-- Hamma bog'lanmagan kassaga taklifni qo'llaydi FAQAT ball=3 va BIR XIL
-- ball bilan YAGONA nomzod bo'lsa. Ikki nomzod teng bo'lsa bog'lamaydi,
-- `chalkash[]` da qaytaradi. Bog'langan kassaga HECH QACHON ustidan
-- yozmaydi (unbound CTE faqat holat<>'boglangan' oladi).

create or replace function hodim_tg_avto_bogla()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_out jsonb;
begin
  if not hodim_tg_page_ok() then
    raise exception 'Sozlamalar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('hodim_tg_avto_bogla'));

  with unbound as (
    select a.id as kassa_id, a.name, a.code,
           (a.taskfix_user_id is not null
            and exists (select 1 from aros_tg_user t where t.user_id = a.taskfix_user_id and t.faol)
           ) as boglangan
      from accounts a
      join accounts g on g.id = a.parent_id and g.kassa_turi = 'xarajat_guruh'
     where a.kassa_turi = 'xarajat'
       and a.pul_turi is null
       and coalesce(a.currency, 'UZS') = 'UZS'
       and coalesce(a.is_active, true)
  ),
  unbound_only as (
    select kassa_id, name, code from unbound where not boglangan
  ),
  users_faol as (
    select t.user_id, t.ism, t.telefon, t.worker_id from aros_tg_user t where t.faol
  ),
  staff_bridge as (
    select u.kassa_id, s.staff_id, s.telefon as staff_tel
      from unbound_only u
      join aros_staff s on s.is_active and hodim_tg_norm(s.toliq_nom) = hodim_tg_norm(u.name)
  ),
  kandidat as (
    select u.kassa_id, u.name as kassa_nom, uf.user_id, uf.ism,
           case
             when hodim_tg_ball(u.name, uf.ism) = 3 then 3
             when hodim_tg_ball(u.name, uf.ism) = 2
                  and exists (
                    select 1 from staff_bridge b
                     where b.kassa_id = u.kassa_id
                       and (b.staff_id::text = uf.worker_id or hodim_tg_tel_match(b.staff_tel, uf.telefon))
                  ) then 3
             else hodim_tg_ball(u.name, uf.ism)
           end as ball
      from unbound_only u
      cross join users_faol uf
  ),
  top3 as (
    select * from kandidat where ball = 3
  ),
  per_kassa as (
    select kassa_id, min(kassa_nom) as kassa_nom, count(*) as n,
           array_agg(user_id order by user_id) as uids,
           jsonb_agg(jsonb_build_object('user_id', user_id, 'ism', ism) order by ism) as nomzodlar
      from top3
     group by kassa_id
  ),
  tanho as (
    select p.kassa_id, p.uids[1] as user_id from per_kassa p where p.n = 1
  ),
  chalk as (
    select p.kassa_id, p.kassa_nom, p.nomzodlar from per_kassa p where p.n > 1
  ),
  yoz as (
    update accounts a
       set taskfix_user_id = t.user_id
      from tanho t
     where a.id = t.kassa_id
    returning a.id as kassa_id, a.code, a.name, t.user_id
  )
  select jsonb_build_object(
           'ok', true,
           'boglandi', (select count(*) from yoz),
           'chalkash', coalesce((select jsonb_agg(jsonb_build_object(
                          'kassa_id', c.kassa_id, 'kassa_nom', c.kassa_nom, 'nomzodlar', c.nomzodlar)
                          order by c.kassa_nom) from chalk c), '[]'::jsonb),
           'topilmadi', (select count(*) from unbound_only)
                        - (select count(*) from yoz)
                        - (select count(*) from chalk))
    into v_out;

  return v_out;
end
$fn$;

revoke all on function hodim_tg_avto_bogla() from public, anon;
grant execute on function hodim_tg_avto_bogla() to authenticated;

comment on function hodim_tg_avto_bogla() is
  'Hamma bog''lanmagan hodim xarajat kassasiga taklifni (ball=3, yagona nomzod) '
  'bir zarbda qo''llaydi. Bog''langan kassaga HECH QACHON ustidan yozmaydi. Ikki '
  'nomzod teng ball bilan kelsa chalkash[] ga tushadi (bog''lanmaydi). Ruxsat: '
  'hodim_tg_page_ok().';


-- #####################################################################
-- ##  9-BO'LIM — PostgREST sxema keshini yangilash                    ##
-- #####################################################################

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  10-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/raise)               ##
-- #####################################################################

do $htg_final$
declare
  v_ok boolean;
begin
  if to_regclass('public.aros_tg_user') is null then
    raise exception 'YAKUNIY TEKSHIRUV: aros_tg_user jadvali yaralmadi';
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'accounts'
                    and column_name = 'taskfix_user_id') then
    raise exception 'YAKUNIY TEKSHIRUV: accounts.taskfix_user_id ustuni yoq';
  end if;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('hodim_tg_page_ok', 'sync_aros_tg_user', 'hodim_tg_royxat',
                             'hodim_tg_bogla', 'hodim_tg_avto_bogla',
                             'hodim_tg_norm', 'hodim_tg_words', 'hodim_tg_ball',
                             'hodim_tg_tel_norm', 'hodim_tg_tel_match', 'hodim_tg_translit')) < 11 then
    raise exception 'YAKUNIY TEKSHIRUV: kerakli funksiyalardan birortasi yaralmadi';
  end if;

  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'aros_tg_user'
                    and policyname = 'aros_tg_user_select') then
    raise exception 'YAKUNIY TEKSHIRUV: aros_tg_user_select policy yoq';
  end if;

  select has_function_privilege('service_role', 'public.sync_aros_tg_user(jsonb)', 'execute') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: service_role uchun sync_aros_tg_user(jsonb) EXECUTE yoq';
  end if;

  select has_function_privilege('authenticated', 'public.sync_aros_tg_user(jsonb)', 'execute') into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated sync_aros_tg_user(jsonb) ni chaqira olmasligi kerak edi';
  end if;

  select has_function_privilege('authenticated', 'public.hodim_tg_royxat()', 'execute') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun hodim_tg_royxat() EXECUTE yoq';
  end if;

  select has_function_privilege('authenticated', 'public.hodim_tg_bogla(uuid, text)', 'execute') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun hodim_tg_bogla(uuid,text) EXECUTE yoq';
  end if;

  select has_function_privilege('authenticated', 'public.hodim_tg_avto_bogla()', 'execute') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun hodim_tg_avto_bogla() EXECUTE yoq';
  end if;

  select has_function_privilege('authenticated', 'public.hodim_tg_norm(text)', 'execute') into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: hodim_tg_norm(text) authenticated uchun ochiq qolgan (ICHKI bolishi kerak)';
  end if;

  raise notice 'PROVODKA_HODIM_TELEGRAM.sql: hammasi joyida.';
end
$htg_final$;


-- #####################################################################
-- ##  DIAGNOSTIKA — nechta hodim kassasi bo'sh (izoh, RUN shart emas)  ##
-- #####################################################################
-- select
--   count(*) as jami_kassa,
--   count(*) filter (where a.taskfix_user_id is null or btrim(a.taskfix_user_id) = '') as bosh_taskfix_user_id,
--   count(*) filter (
--     where a.taskfix_user_id is not null and btrim(a.taskfix_user_id) <> ''
--       and not exists (select 1 from aros_tg_user t where t.user_id = a.taskfix_user_id and t.faol)
--   ) as taskfix_user_id_topilmadi
-- from accounts a
-- join accounts g on g.id = a.parent_id and g.kassa_turi = 'xarajat_guruh'
-- where a.kassa_turi = 'xarajat' and a.pul_turi is null
--   and coalesce(a.currency, 'UZS') = 'UZS' and coalesce(a.is_active, true);
