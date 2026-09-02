-- =====================================================================
-- PROVODKA_QARZ.sql — Qarz (kredit) boshqaruvi, 1-BOSQICH (faqat SQL)
-- ---------------------------------------------------------------------
-- Brief: ARX_PROVODKA_QARZ.md (11a QARORLAR, 2026-09-02, Asilbek TASDIQLADI).
-- Bu fayl FAQAT SQL. Klient tomoni (qarzdor-dev.html tablari) keyingi
-- bosqichda. Kechirish (9480 / qarz_kechir) YOQ. Foiz mantiqi YOQ
-- (foiz_yillik ustuni faqat 0 bolib turadi, hisoblanmaydi).
--
-- ## RUN TARTIBI (Asilbek) — butun faylni birdaniga RUN qilish MUMKIN.
--   0-BOLIM   — old shart tekshiruvi (faqat select/raise)
--   1-BOLIM   — hisoblar: 4700 konteyner, 4710 (ichki), 4720 (tashqi)
--   2-BOLIM   — tilxat_shablon jadvali + sukut shablon (seed)
--   3-BOLIM   — qarzdor jadvali + RLS
--   4-BOLIM   — qarz jadvali + RLS
--   5-BOLIM   — qarz_jadval (tolov grafigi) + RLS
--   6-BOLIM   — qarz_tolov (qaytarish) + RLS
--   7-BOLIM   — qarz_tarix (audit) + RLS
--   8-BOLIM   — qarz_notify (Telegram navbati) + RLS
--   9-BOLIM   — storage bucket `qarz-tilxat` + qarz_rasm_ok(uuid)
--  10-BOLIM   — viewlar: v_qarz_holat, v_qarz_shu_oy, v_qarzdor_jami
--  11-BOLIM   — ICHKI yordamchilar (qarz_debtor_account, qarz_muddat_matni,
--               qarz_qator, qarz_notify_qoy)
--  12-BOLIM   — qarzdor_yarat / qarzdor_royxat
--  13-BOLIM   — qarz_yarat
--  14-BOLIM   — qarz_tilxat_yuklandi
--  15-BOLIM   — qarz_faollashtir  (PUL HARAKATI)
--  16-BOLIM   — qarz_tolov        (PUL HARAKATI)
--  17-BOLIM   — qarz_jadval_qayta (admin)
--  18-BOLIM   — qarz_bekor
--  19-BOLIM   — qarz_royxat / qarz_kart / qarz_dash
--  20-BOLIM   — tilxat_shablon_saqla (admin)
--  21-BOLIM   — qarz_notify_pending / qarz_notify_belgila / qarz_eslatma_navbat
--               (service_role ONLY — n8n)
--  22-BOLIM   — PostgREST sxema keshi
--  23-BOLIM   — YAKUNIY TEKSHIRUV (faqat select)
--
-- ## OLD SHART (bazada bolishi kerak)
--   accounts / entry / entry_line          -> asosiy migratsiya
--   is_admin()                             -> asosiy migratsiya
--   PROVODKA_PERMS.sql    -> perm_check_accounts(uuid[]), perm_op_key(uuid),
--                            trg_perm_guard_entry_line (entry_line ustida)
--   PROVODKA_SOROVLAR.sql -> sorov_kassa_bal(uuid), sorov_page_ok(text),
--                            sorov_ism(uuid,uuid)
--   PROVODKA_OVQAT.sql    -> aros_staff (ichki qarzdor manbasi)
--   `qarzdor` sahifa kaliti perm_pages() royxatida ALLAQACHON bor —
--   yangi sahifa kaliti QOSHILMAYDI (perms-dev.js/index-dev/promote.sh TEGILMAYDI).
--
-- ## ADDITIVE KAFOLATI
--   * Hech narsa drop QILINMAYDI, hech qanday eski ustun/funksiya imzosi
--     ozgarmaydi. Hammasi YANGI jadval/funksiya/hisob.
--   * accounts (4700/4710/4720) — `insert ... where not exists` bilan
--     idempotent, mavjud hisoblarga tegilmaydi.
--   * `qarz_tolov` NOMI table VA function uchun ikkalasida ham ishlatiladi
--     (ARX/brief talabi) — Postgres'da xavfsiz: jadval (pg_class) va
--     funksiya (pg_proc) alohida nom fazosida, INSERT INTO / SELECT FROM
--     doim relatsiyani, chaqiruv qavs bilan doim funksiyani anglatadi.
--   * Pul harakati FAQAT `qarz_faollashtir` va `qarz_tolov` (funksiya)
--     ICHIDA — ikkalasi ham user JWT bilan (service_role EMAS), shuning
--     uchun `trg_perm_guard_entry_line` avtomat ishlaydi (kassa_id har doim
--     `accounts.code like '5%'` — guard predikatiga tushadi, 4710/4720 esa
--     kod `4%` bolgani uchun guard ularga TEGMAYDI, xuddi 6720/6721 kabi).
--   * Anonim `do` bloki YOQ — har `do` bloki NOMLANGAN teg bilan
--     (qarz_pre, qarz_check nomli teglar). Har funksiya tanasi nomlangan
--     "fn" tegi bilan oraladi. Izohlarda dollar belgi ikkitalab yonma-yon
--     YOZILMAGAN (soxta blok xavfi — CLAUDE.md).
--
-- ## FAIL-CLOSED QOIDALARI (buzilmasin)
--   * Tashqi qarz rasmsiz FAOL/YOPILDI bololmaydi (qarz_tilxat_ck).
--   * status='faol'/'yopildi' -> entry_id NOT NULL (qarz_faol_entry_ck).
--   * Kassa qoldigi yetmasa (`sorov_kassa_bal`) — faollashtirilmaydi.
--   * `qarz_notify` — HECH QACHON pul harakatini tosmaydi (fail-open,
--     `qarz_notify_qoy` ichida `exception when others -> raise warning`).
--   * `qarz_notify`da RLS bor, lekin POLICY YOQ — faqat service_role va
--     SECURITY DEFINER funksiyalar yozadi/oqiydi (hodim_notify naqshi).
-- =====================================================================


-- #####################################################################
-- ##  0-BOLIM — OLD SHART TEKSHIRUVI (faqat select/raise)            ##
-- #####################################################################

do $qarz_pre$
begin
  if to_regclass('public.accounts') is null then
    raise exception 'accounts jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regclass('public.entry') is null or to_regclass('public.entry_line') is null then
    raise exception 'entry/entry_line jadvallari yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regclass('public.aros_staff') is null then
    raise exception 'aros_staff jadvali yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'is_admin() funksiyasi yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regprocedure('public.perm_check_accounts(uuid[])') is null then
    raise exception 'perm_check_accounts(uuid[]) yoq — avval PROVODKA_PERMS.sql ni bajaring';
  end if;
  if to_regprocedure('public.perm_op_key(uuid)') is null then
    raise exception 'perm_op_key(uuid) yoq — avval PROVODKA_PERMS.sql ni bajaring';
  end if;
  if to_regprocedure('public.sorov_kassa_bal(uuid)') is null then
    raise exception 'sorov_kassa_bal(uuid) yoq — avval PROVODKA_SOROVLAR.sql ni bajaring';
  end if;
  if to_regprocedure('public.sorov_page_ok(text)') is null then
    raise exception 'sorov_page_ok(text) yoq — avval PROVODKA_SOROVLAR.sql ni bajaring';
  end if;
  if to_regprocedure('public.sorov_ism(uuid,uuid)') is null then
    raise exception 'sorov_ism(uuid,uuid) yoq — avval PROVODKA_SOROVLAR.sql ni bajaring';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.entry_line'::regclass
                    and tgname  = 'trg_perm_guard_entry_line') then
    raise exception 'trg_perm_guard_entry_line yoq — pul guardi topilmadi, avval tekshiring';
  end if;
end
$qarz_pre$;


-- #####################################################################
-- ##  qarz_page_ok() — RLS uchun sahifa qorovuli (barcha qarz jadvallari ##
-- ##  ostidagi SELECT policylar shuni chaqiradi, pastda 2..7-BOLIM)     ##
-- #####################################################################
-- 🔴 `sorov_page_ok(text)` `public.sorov_page_ok(text)` ICHKI deb
--    belgilangan va `authenticated` uchun REVOKE qilingan (PROVODKA_SOROVLAR.sql,
--    "Faqat DEFINER funksiyalar ichidan"). RLS USING ifodasi esa SO'ROVCHI
--    ROLI (`authenticated`) nomidan bajariladi — SECURITY DEFINER funksiya
--    ekanligi buni o'zgartirmaydi, chaqiruvchiga baribir EXECUTE kerak.
--    Shuning uchun boshqa faylning grantiga tegmasdan, shu faylda ALOHIDA
--    definer-qobiq yaratildi va FAQAT shu qobiq authenticated'ga ochiladi.
create or replace function qarz_page_ok()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select is_admin() or sorov_page_ok('qarzdor');
$fn$;

revoke all on function qarz_page_ok() from public, anon;
grant execute on function qarz_page_ok() to authenticated;

comment on function qarz_page_ok() is
  'RLS qorovuli: admin YOKI qarzdor sahifasi ruxsati. authenticated uchun OCHIQ '
  '(sorov_page_ok ozi yopiq — shu qobiq orqali chaqiriladi).';


-- #####################################################################
-- ##  1-BOLIM — Hisoblar: 4700 konteyner + 4710 (ichki) + 4720 (tashqi) ##
-- #####################################################################
-- 🔴 5xxx kodlar ISHLATILMAYDI (klientda isKassa() = code.startsWith('5')).
--    47xx tanlangan: 4010 (Xaridorlar qarzi) yoniga, lekin undan alohida.
--    `kassa_turi` ATAYLAB NULL — bular pul hisobi EMAS, oddiy AKTIV hisob.
--    `section` — 4010 hisobidan NUSXA (yoq bolsa 6010, u ham yoq bolsa
--    aktiv hisoblarda eng kop uchraydigan section) — balans() guruhlashi
--    yetim bolim tugdirmasin.
-- #####################################################################

insert into accounts (code, name, type, section, currency, is_active)
select '4700',
       'Berilgan qarzlar',
       'aktiv',
       coalesce(
         (select a.section from accounts a where a.code = '4010' limit 1),
         (select a.section from accounts a where a.code = '6010' limit 1),
         (select a.section from accounts a
           where a.type = 'aktiv' and a.section is not null
           group by a.section order by count(*) desc, a.section limit 1)
       ),
       'UZS',
       true
 where not exists (select 1 from accounts where code = '4700');

comment on column accounts.parent_id is
  'Valyuta juftligi YOKI guruh a''zoligi (masalan 4700 -> 4710/4720). Ikki manoli, currency bilan ajratiladi.';

insert into accounts (code, name, type, section, currency, parent_id, is_active)
select '4710',
       'Xodimlarga berilgan qarzlar',
       'aktiv',
       (select section from accounts where code = '4700'),
       'UZS',
       (select id from accounts where code = '4700'),
       true
 where not exists (select 1 from accounts where code = '4710')
   and exists (select 1 from accounts where code = '4700');

insert into accounts (code, name, type, section, currency, parent_id, is_active)
select '4720',
       'Boshqa shaxslarga berilgan qarzlar',
       'aktiv',
       (select section from accounts where code = '4700'),
       'UZS',
       (select id from accounts where code = '4700'),
       true
 where not exists (select 1 from accounts where code = '4720')
   and exists (select 1 from accounts where code = '4700');


-- #####################################################################
-- ##  2-BOLIM — tilxat_shablon jadvali + sukut shablon (seed)         ##
-- #####################################################################
-- `qarz` (4-BOLIM) shu jadvalga FK bilan boglanadi — shuning uchun
-- qarzdan OLDIN yaratiladi.
-- #####################################################################

create table if not exists tilxat_shablon (
  id          uuid primary key default gen_random_uuid(),
  nom         text        not null,
  matn        text        not null,
  is_default  boolean     not null default false,
  is_active   boolean     not null default true,
  created_by  uuid,
  updated_at  timestamptz not null default now()
);

comment on table tilxat_shablon is
  'Tashqi qarz uchun tilxat matn shabloni. Joy-tutuvchilar: {ism} {familya} {summa} '
  '{summa_soz} {valyuta} {sana} {muddat} {oylik_summa} {oylar_soni} {tugash} {kompaniya}. '
  'Yozish faqat tilxat_shablon_saqla() orqali (admin).';

-- Faqat BITTA sukut shablon bolishi mumkin.
create unique index if not exists tilxat_shablon_default_uniq
  on tilxat_shablon (is_default) where is_default = true;

alter table tilxat_shablon enable row level security;

revoke all on table tilxat_shablon from public, anon;
grant select on table tilxat_shablon to authenticated;

drop policy if exists tilxat_shablon_select on tilxat_shablon;
create policy tilxat_shablon_select on tilxat_shablon
  for select to authenticated
  using (qarz_page_ok());

-- Sukut shablon — faylning birinchi RUN'ida BIR MARTA seed qilinadi.
-- Keyingi RUN'larda jadval BOSH BOLMAGANI uchun qayta qoshilmaydi (admin
-- tahrirlagan/ozgartirgan bolsa ham TEGILMAYDI).
insert into tilxat_shablon (nom, matn, is_default, is_active)
select 'Standart tilxat',
$tilxat$TILXAT

Men, {ism} {familya}, {sana} kuni {kompaniya} tashkilotidan {summa} ({summa_soz}) {valyuta} miqdorida qarz oldim.

Qaytarish shakli: {muddat}.
Muddat: {oylar_soni} oy, har oyda {oylik_summa} {valyuta} dan.
Qarzni {tugash} sanasigacha toliq qaytarishga majburiyat olaman.

Tilxat ikki nusxada tuzildi: biri menda, biri {kompaniya} tashkilotida saqlanadi.

Imzo: _______________          Sana: {sana}$tilxat$,
       true,
       true
where not exists (select 1 from tilxat_shablon);


-- #####################################################################
-- ##  3-BOLIM — qarzdor jadvali + RLS                                ##
-- #####################################################################
-- Ichki qarzdor `aros_staff`dan BIR MARTA nusxalanadi (ism/familya —
-- hodim keyin ochirilsa ham tarix qolsin). Tashqi — qolda kiritiladi.
-- #####################################################################

create table if not exists qarzdor (
  id          uuid        primary key default gen_random_uuid(),
  tur         text        not null check (tur in ('ichki','tashqi')),
  staff_id    int         references aros_staff(staff_id),
  ism         text        not null,
  familya     text        not null,
  telefon     text,
  izoh        text,
  is_active   boolean     not null default true,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  constraint qarzdor_tur_staff_ck check (
    (tur = 'ichki'  and staff_id is not null) or
    (tur = 'tashqi' and staff_id is null)
  )
);

comment on table qarzdor is
  'Qarzdor (ichki = aros_staff hodimi, tashqi = qoldda kiritilgan odam). '
  'Bitta odamning bir nechta qarzi bolishi mumkin (1:N — qarz.qarzdor_id).';

-- Bitta hodimga BITTA qarzdor qatori.
create unique index if not exists qarzdor_staff_uniq
  on qarzdor (staff_id) where staff_id is not null;
create index if not exists qarzdor_tur_idx on qarzdor (tur);

alter table qarzdor enable row level security;

-- 🔴 RLS select PERMISSIV (ARX 7-bolim qarori): sahifa tekshiruvi
--    RPC ICHIDA (sorov_page_ok('qarzdor')), aros_staff naqshi bilan bir xil.
revoke all on table qarzdor from public, anon;
grant select on table qarzdor to authenticated;

drop policy if exists qarzdor_select on qarzdor;
create policy qarzdor_select on qarzdor
  for select to authenticated
  using (qarz_page_ok());


-- #####################################################################
-- ##  4-BOLIM — qarz jadvali (bitta shartnoma) + RLS                 ##
-- #####################################################################

create table if not exists qarz (
  id                 uuid        primary key default gen_random_uuid(),
  qarzdor_id         uuid        not null references qarzdor(id),
  kassa_id           uuid        not null references accounts(id),
  summa              numeric     not null check (summa > 0),
  currency           text        not null default 'UZS' check (currency = 'UZS'),
  muddat_turi        text        not null check (muddat_turi in ('oylik','bir_martalik')),
  oylik_summa        numeric,
  oylar_soni         int,
  boshlanish         date        not null,
  tugash             date        not null,
  foiz_yillik        numeric     not null default 0 check (foiz_yillik >= 0),
  status             text        not null default 'tilxat_kutilmoqda'
                         check (status in ('tilxat_kutilmoqda','faol','yopildi','bekor')),
  tilxat_kerak       boolean     not null default false,
  tilxat_shablon_id  uuid        references tilxat_shablon(id) on delete set null,
  tilxat_matn        text,
  tilxat_rasm_path   text,
  entry_id           uuid        references entry(id),
  izoh               text,
  ext_ref            text        unique,
  created_by         uuid,
  created_at         timestamptz not null default now(),
  faol_at            timestamptz,
  yopilgan_at        timestamptz,
  -- 🔴 oylik + oylik_summa NULL = "individual" grafik (qarz_jadval_qayta
  --    qatorlarni har xil summaga qayta tuzganda) — oylar_soni baribir
  --    (qolgan tolanmagan qatorlar soni) TALAB qilinadi.
  constraint qarz_muddat_ck check (
    (muddat_turi = 'oylik'
       and oylar_soni is not null and oylar_soni > 0
       and (oylik_summa is null or oylik_summa > 0))
    or
    (muddat_turi = 'bir_martalik' and oylik_summa is null and oylar_soni is null)
  ),
  -- 🔴 faol entry_id siz bololmaydi (pul harakatsiz "faol" TAQIQ).
  constraint qarz_faol_entry_ck check (status not in ('faol','yopildi') or entry_id is not null),
  -- 🔴 tashqi qarz (tilxat_kerak) rasmsiz faol/yopildi bololmaydi.
  constraint qarz_tilxat_ck check (
    not (tilxat_kerak and status in ('faol','yopildi')) or tilxat_rasm_path is not null
  )
);

comment on table qarz is
  'Bitta qarz (shartnoma). entry_id FAQAT status=faol/yopildi da toladi (pul harakati '
  'FAQAT qarz_faollashtir() da). foiz_yillik hozircha 0 (1-bosqichda foiz hisoblanmaydi).';

create index if not exists qarz_qarzdor_idx on qarz (qarzdor_id);
create index if not exists qarz_kassa_idx   on qarz (kassa_id);
create index if not exists qarz_status_idx  on qarz (status);
create index if not exists qarz_created_idx on qarz (created_at desc);

alter table qarz enable row level security;

revoke all on table qarz from public, anon;
grant select on table qarz to authenticated;

drop policy if exists qarz_select on qarz;
create policy qarz_select on qarz
  for select to authenticated
  using (qarz_page_ok());


-- #####################################################################
-- ##  5-BOLIM — qarz_jadval (tolov grafigi) + RLS                    ##
-- #####################################################################

create table if not exists qarz_jadval (
  id       uuid    primary key default gen_random_uuid(),
  qarz_id  uuid    not null references qarz(id) on delete cascade,
  n        int     not null check (n > 0),
  sana     date    not null,
  summa    numeric not null check (summa > 0),
  tolangan numeric not null default 0 check (tolangan >= 0 and tolangan <= summa),
  unique (qarz_id, n)
);

comment on table qarz_jadval is
  'Tolov grafigi qatori. Bir martalik = 1 qator; oylik = N qator, OXIRGI qator qoldiqni '
  'oladi (masalan 500000x6=3000000, summa 3100000 bolsa oxirgisi 600000).';

create index if not exists qarz_jadval_qarz_idx on qarz_jadval (qarz_id);
create index if not exists qarz_jadval_sana_idx on qarz_jadval (sana);

alter table qarz_jadval enable row level security;

revoke all on table qarz_jadval from public, anon;
grant select on table qarz_jadval to authenticated;

drop policy if exists qarz_jadval_select on qarz_jadval;
create policy qarz_jadval_select on qarz_jadval
  for select to authenticated
  using (qarz_page_ok());


-- #####################################################################
-- ##  6-BOLIM — qarz_tolov (qaytarish) + RLS                         ##
-- #####################################################################
-- 🔴 Bu jadval NOMI keyinroq (16-BOLIM) `qarz_tolov(...)` FUNKSIYASI
--    bilan bir xil — Postgres'da xavfsiz (yuqoridagi izoh).
-- #####################################################################

create table if not exists qarz_tolov (
  id          uuid        primary key default gen_random_uuid(),
  qarz_id     uuid        not null references qarz(id),
  kassa_id    uuid        not null references accounts(id),
  summa       numeric     not null check (summa > 0),
  sana        date        not null default ((now() at time zone 'Asia/Tashkent')::date),
  izoh        text,
  entry_id    uuid        references entry(id),
  ext_ref     text        unique,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  is_deleted  boolean     not null default false
);

comment on table qarz_tolov is
  'Qarz qaytarish (qisman/toliq). Taqsimot FIFO — eng eski tolanmagan qarz_jadval '
  'qatoridan boshlab yopadi. entry: Dt kassa (kirim) / Kt 4710-4720 (qarz kamayadi).';

create index if not exists qarz_tolov_qarz_idx on qarz_tolov (qarz_id);

alter table qarz_tolov enable row level security;

revoke all on table qarz_tolov from public, anon;
grant select on table qarz_tolov to authenticated;

drop policy if exists qarz_tolov_select on qarz_tolov;
create policy qarz_tolov_select on qarz_tolov
  for select to authenticated
  using (qarz_page_ok());


-- #####################################################################
-- ##  7-BOLIM — qarz_tarix (audit, append-only) + RLS                ##
-- #####################################################################

create table if not exists qarz_tarix (
  id       bigserial   primary key,
  qarz_id  uuid        not null references qarz(id) on delete cascade,
  hodisa   text        not null check (hodisa in
              ('yaratildi','tilxat_yuklandi','faollashdi','tolov','yopildi','jadval_qayta','bekor')),
  data     jsonb       not null default '{}'::jsonb,
  kim      uuid,
  vaqt     timestamptz not null default now()
);

comment on table qarz_tarix is
  'Audit (append-only) — har RPC bir hodisa qatori qoshadi. Hech qachon tahrirlanmaydi/ochirilmaydi.';

create index if not exists qarz_tarix_qarz_idx on qarz_tarix (qarz_id, vaqt desc);

alter table qarz_tarix enable row level security;

revoke all on table qarz_tarix from public, anon;
grant select on table qarz_tarix to authenticated;

drop policy if exists qarz_tarix_select on qarz_tarix;
create policy qarz_tarix_select on qarz_tarix
  for select to authenticated
  using (qarz_page_ok());


-- #####################################################################
-- ##  8-BOLIM — qarz_notify (Telegram navbati, OUTBOX) + RLS         ##
-- #####################################################################
-- hodim_notify naqshi (PROVODKA_HODIM_NOTIFY.sql): trigger emas, RPC
-- ozi OUTBOX'ga yozadi; n8n har necha daqiqada oqib yuboradi.
-- Adminlar royxati YANGI jadval EMAS — MAVJUD `hodim_notify_admin` qayta
-- ishlatiladi (11a qarori).
-- `qarz_id` NULL bolishi mumkin — 'eslatma' hodisasi kunlik YIGMA qator
-- (bitta qatorda bir nechta qarz haqida malumot, data ichida).
-- #####################################################################

create table if not exists qarz_notify (
  id          bigserial   primary key,
  qarz_id     uuid        references qarz(id) on delete cascade,
  tolov_id    uuid        references qarz_tolov(id) on delete set null,
  hodisa      text        not null check (hodisa in
                 ('draft_yaratildi','tilxat_yuklandi','berildi','tolov','yopildi','bekor','eslatma')),
  data        jsonb       not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,
  attempts    int         not null default 0,
  last_error  text
);

comment on table qarz_notify is
  'Telegram xabar navbati (OUTBOX). n8n "Aros Provodka - Qarz Notify" workflow '
  'qarz_notify_pending() bilan oqiydi, qarz_notify_belgila() bilan belgilaydi. '
  'hodim_notify jadvaliga TEGILMAGAN — alohida navbat.';

create index if not exists qarz_notify_pending_idx on qarz_notify (id) where sent_at is null;
create index if not exists qarz_notify_qarz_idx    on qarz_notify (qarz_id);

alter table qarz_notify enable row level security;

-- 🔴 POLICY UMUMAN YOQ (hodim_notify naqshi) — faqat service_role va
--    SECURITY DEFINER funksiyalar (jadval egasi sifatida) yozadi/oqiydi.
--    `force row level security` ATAYLAB QOYILMAGAN.
revoke all on table qarz_notify from public, anon, authenticated;


-- #####################################################################
-- ##  9-BOLIM — storage bucket `qarz-tilxat` + qarz_rasm_ok(uuid)    ##
-- #####################################################################
-- Naqsh: xarajat-cheklari (PROVODKA_HODIM_V3.sql). Yol: <qarz_id>/tilxat.jpg.
-- select — authenticated; insert/update — faqat qarz.created_by yoki admin.
-- #####################################################################

insert into storage.buckets (id, name, public)
values ('qarz-tilxat', 'qarz-tilxat', false)
on conflict (id) do nothing;

create or replace function qarz_rasm_ok(p_qarz uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1 from qarz q
     where q.id = p_qarz
       and (q.created_by = auth.uid() or is_admin())
  );
$fn$;

revoke all on function qarz_rasm_ok(uuid) from public, anon;
grant execute on function qarz_rasm_ok(uuid) to authenticated;

comment on function qarz_rasm_ok(uuid) is
  'Storage RLS uchun: shu qarz tilxatini FAQAT yaratuvchisi yoki admin yuklay/yangilay oladi.';

drop policy if exists "qarz_tilxat_select" on storage.objects;
create policy "qarz_tilxat_select" on storage.objects
  for select to authenticated
  using (bucket_id = 'qarz-tilxat');

drop policy if exists "qarz_tilxat_insert" on storage.objects;
create policy "qarz_tilxat_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'qarz-tilxat'
    and qarz_rasm_ok( nullif((storage.foldername(name))[1], '')::uuid )
  );

drop policy if exists "qarz_tilxat_update" on storage.objects;
create policy "qarz_tilxat_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'qarz-tilxat'
    and qarz_rasm_ok( nullif((storage.foldername(name))[1], '')::uuid )
  )
  with check (
    bucket_id = 'qarz-tilxat'
    and qarz_rasm_ok( nullif((storage.foldername(name))[1], '')::uuid )
  );


-- #####################################################################
-- ##  10-BOLIM — Viewlar: v_qarz_holat, v_qarz_shu_oy, v_qarzdor_jami ##
-- #####################################################################

create or replace view v_qarz_holat as
select
  q.id                       as qarz_id,
  q.summa                    as berilgan,
  coalesce(t.tolangan, 0)    as tolangan,
  q.summa - coalesce(t.tolangan, 0) as qolgan,
  coalesce(k.kechikkan_summa, 0)    as kechikkan_summa,
  coalesce(k.kechikkan_kunlar, 0)   as kechikkan_kunlar,
  n.sana                     as keyingi_tolov_sana,
  n.qolgan_row               as keyingi_tolov_summa
from qarz q
left join lateral (
  select sum(jr.tolangan) as tolangan
    from qarz_jadval jr where jr.qarz_id = q.id
) t on true
left join lateral (
  select sum(jr.summa - jr.tolangan)                                 as kechikkan_summa,
         max((now() at time zone 'Asia/Tashkent')::date - jr.sana)   as kechikkan_kunlar
    from qarz_jadval jr
   where jr.qarz_id = q.id
     and jr.sana < (now() at time zone 'Asia/Tashkent')::date
     and jr.tolangan < jr.summa
) k on true
left join lateral (
  select jr.sana, (jr.summa - jr.tolangan) as qolgan_row
    from qarz_jadval jr
   where jr.qarz_id = q.id and jr.tolangan < jr.summa
   order by jr.sana
   limit 1
) n on true;

comment on view v_qarz_holat is
  'Har qarz uchun: berilgan/tolangan/qolgan, kechikkan summa/kun, keyingi tolov sana/summa.';

grant select on v_qarz_holat to authenticated;

create or replace view v_qarz_shu_oy as
select
  jr.id                             as jadval_id,
  jr.qarz_id,
  jr.n,
  jr.sana,
  jr.summa,
  jr.tolangan,
  (jr.summa - jr.tolangan)          as qolgan_row,
  case when jr.sana < (now() at time zone 'Asia/Tashkent')::date then 'kechikkan'
       else 'kutilmoqda' end        as holat,
  q.qarzdor_id,
  q.kassa_id,
  q.muddat_turi,
  q.currency,
  qd.tur                            as qarzdor_tur,
  qd.ism                            as qarzdor_ism,
  qd.familya                        as qarzdor_familya,
  a.code                            as kassa_kod,
  a.name                            as kassa_nom
from qarz_jadval jr
join qarz q      on q.id  = jr.qarz_id
join qarzdor qd  on qd.id = q.qarzdor_id
join accounts a  on a.id  = q.kassa_id
where q.status = 'faol'
  and jr.tolangan < jr.summa
  and date_trunc('month', jr.sana) = date_trunc('month', (now() at time zone 'Asia/Tashkent')::date);

comment on view v_qarz_shu_oy is
  'Shu oy ichida muddati keladigan (yoki allaqachon kechikkan) tolanmagan jadval qatorlari. '
  'muddat_turi bilan filtrlab "Shu oy oylik tolov" royxati ham shundan olinadi.';

grant select on v_qarz_shu_oy to authenticated;

create or replace view v_qarzdor_jami as
select
  qd.id                                                        as qarzdor_id,
  qd.tur, qd.ism, qd.familya, qd.telefon, qd.is_active,
  count(q.id) filter (where q.status <> 'bekor')                as qarz_soni,
  count(q.id) filter (where q.status = 'faol')                  as faol_soni,
  coalesce(sum(h.qolgan) filter (where q.status = 'faol'), 0)   as jami_qolgan,
  coalesce(bool_or(h.kechikkan_summa > 0) filter (where q.status = 'faol'), false) as kechikkan_bor
from qarzdor qd
left join qarz q          on q.qarzdor_id = qd.id
left join v_qarz_holat h  on h.qarz_id    = q.id
group by qd.id, qd.tur, qd.ism, qd.familya, qd.telefon, qd.is_active;

comment on view v_qarzdor_jami is
  'Qarzdor kesimi: nechta qarz (faol/jami), jami qolgan, kechikkan bormi.';

grant select on v_qarzdor_jami to authenticated;


-- #####################################################################
-- ##  11-BOLIM — ICHKI yordamchilar                                  ##
-- #####################################################################

-- 11.1 qarz_oy_qosh(date, int) — p_date dan p_n oy keyingi sana, OY OXIRINI
--      CLAMP qiladi. 🔴 make_interval(months=>n) ozi buni QILMAYDI:
--      31.01 + 1 oy = 03.03 (Postgres Fevralning 31/29-kuni yoqligini
--      "tashib" mart oyiga otkazadi). Naqsh: avval maqsad oyning 1-kuniga
--      p_n oy qoshiladi, songra ASL kun raqami qoshiladi, keyin natija
--      "maqsad oy oxiri" bilan LEAST() qilinadi — oshib ketsa oxirgi kunga
--      qisqaradi. Test (qolda tekshirilgan): 31.01 + {1,2,3,4,5} oy ->
--      28.02, 31.03, 30.04, 31.05, 30.06; 15.01 + {1,2} oy -> 15.02, 15.03.
create or replace function qarz_oy_qosh(p_date date, p_n int)
returns date
language sql
immutable
as $fn$
  select least(
    (date_trunc('month', p_date) + make_interval(months => p_n))::date
      + (extract(day from p_date)::int - 1),
    (date_trunc('month', p_date) + make_interval(months => p_n + 1))::date - 1
  );
$fn$;

revoke all on function qarz_oy_qosh(date, int) from public, anon, authenticated;

comment on function qarz_oy_qosh(date, int) is
  'ICHKI: p_date dan p_n oy keyin, oy oxiri CLAMP qilingan sana (31.01+1oy=28/29.02, '
  'make_interval kabi 03.03 EMAS). Tolov grafigi generatsiyasida ISHLATILISHI SHART.';

-- 11.2 qarz_debtor_account(text) — qarzdor turi boyicha 4710/4720 id.
create or replace function qarz_debtor_account(p_tur text)
returns uuid
language sql
stable
security definer
set search_path = public
as $fn$
  select id from accounts
   where code = case when p_tur = 'ichki' then '4710' when p_tur = 'tashqi' then '4720' end
   limit 1;
$fn$;

revoke all on function qarz_debtor_account(text) from public, anon, authenticated;

comment on function qarz_debtor_account(text) is
  'ICHKI: qarzdor turi (ichki/tashqi) boyicha 4710/4720 hisob id. Topilmasa NULL.';

-- 11.3 qarz_muddat_matni(...) — inson ogib oladigan muddat matni.
--      Pul formati probel bilan (CLAUDE.md), locale'ga bogliq emas
--      (vergul togridan-togri patternda — G emas).
--      🔴 p_turi='oylik' VA p_oylik_summa NULL — qarz_jadval_qayta dan
--      keyingi "individual" grafik (qatorlar teng emas) — alohida matn.
create or replace function qarz_muddat_matni(
  p_turi text, p_oylik_summa numeric, p_oylar_soni int, p_boshlanish date, p_tugash date)
returns text
language sql
stable
as $fn$
  select case
    when p_turi = 'oylik' and p_oylik_summa is not null then
      p_oylar_soni::text || ' oy · har oy ' ||
      replace(trim(to_char(p_oylik_summa, '999,999,999,999,999')), ',', ' ') ||
      ' som · ' || to_char(p_tugash, 'DD.MM.YYYY') || ' gacha'
    when p_turi = 'oylik' and p_oylik_summa is null then
      'Individual grafik · ' || coalesce(p_oylar_soni, 0)::text || ' tolov (' ||
      to_char(p_boshlanish, 'DD.MM.YYYY') || ' - ' || to_char(p_tugash, 'DD.MM.YYYY') || ')'
    else
      'Bir martalik · ' || to_char(p_tugash, 'DD.MM.YYYY') || ' gacha'
  end;
$fn$;

-- 🔴 security definer SHART EMAS (faqat matn quradi, jadval oqimaydi) —
--    lekin fayl konventsiyasi boyicha ICHKI funksiya sifatida yopiladi.
revoke all on function qarz_muddat_matni(text, numeric, int, date, date) from public, anon;

comment on function qarz_muddat_matni(text, numeric, int, date, date) is
  'ICHKI: muddat izohi (jurnal tavsifi, tilxat, notify uchun). Sof matn, tarjima yoq. '
  'oylik + oylik_summa=null -> "Individual grafik" (qarz_jadval_qayta dan keyin).';

-- 11.4 qarz_qator(qarz) — bitta qarz qatorining toliq jsonb shakli.
--      🔴 YAGONA joy: qarz_royxat va qarz_kart shuni ishlatadi — ikkala
--      chiqish HECH QACHON bir-biridan ajrab ketmaydi (ruxsat_qator naqshi).
create or replace function qarz_qator(q qarz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_qd qarzdor;
  v_ka accounts;
  v_h  v_qarz_holat;
begin
  select * into v_qd from qarzdor where id = q.qarzdor_id;
  select * into v_ka from accounts where id = q.kassa_id;
  select * into v_h  from v_qarz_holat where qarz_id = q.id;

  return jsonb_build_object(
    'id',                  q.id,
    'qarzdor_id',          q.qarzdor_id,
    'qarzdor_tur',         v_qd.tur,
    'qarzdor_ism',         v_qd.ism,
    'qarzdor_familya',     v_qd.familya,
    'qarzdor_telefon',     v_qd.telefon,
    'kassa_id',            q.kassa_id,
    'kassa_kod',           v_ka.code,
    'kassa_nom',           v_ka.name,
    'summa',               q.summa,
    'currency',            q.currency,
    'muddat_turi',         q.muddat_turi,
    'oylik_summa',         q.oylik_summa,
    'oylar_soni',          q.oylar_soni,
    'boshlanish',          q.boshlanish,
    'tugash',              q.tugash,
    'muddat_matni',        qarz_muddat_matni(q.muddat_turi, q.oylik_summa, q.oylar_soni, q.boshlanish, q.tugash),
    'foiz_yillik',         q.foiz_yillik,
    'status',              q.status,
    'tilxat_kerak',        q.tilxat_kerak,
    'tilxat_shablon_id',   q.tilxat_shablon_id,
    'tilxat_matn',         q.tilxat_matn,
    'tilxat_rasm_path',    q.tilxat_rasm_path,
    'izoh',                q.izoh,
    'entry_id',            q.entry_id,
    'created_by',          q.created_by,
    'created_at',          q.created_at,
    'faol_at',             q.faol_at,
    'yopilgan_at',         q.yopilgan_at,
    'tolangan',            coalesce(v_h.tolangan, 0),
    'qolgan',              coalesce(v_h.qolgan, q.summa),
    'kechikkan_summa',     coalesce(v_h.kechikkan_summa, 0),
    'kechikkan_kunlar',    coalesce(v_h.kechikkan_kunlar, 0),
    'keyingi_tolov_sana',  v_h.keyingi_tolov_sana,
    'keyingi_tolov_summa', v_h.keyingi_tolov_summa
  );
end $fn$;

revoke all on function qarz_qator(qarz) from public, anon, authenticated;

comment on function qarz_qator(qarz) is
  'ICHKI: bitta qarz qatorining toliq jsonb shakli. qarz_royxat/qarz_kart shuni ishlatadi.';

-- 11.5 qarz_notify_qoy(...) — OUTBOX'ga bitta hodisa qoyadi.
--      🔴 FAIL-OPEN (hodim_notify naqshi): pul harakatini HECH QACHON tosmaydi.
--      p_tolov_id berilsa tolov summasi/kassasi AVTOMAT qoshiladi (qarz_tolov +
--      accounts dan). p_extra — ixtiyoriy qoshimcha malumot (masalan qarz_bekor
--      dagi sabab) — v_data ustiga `||` bilan MERGE qilinadi (extra ustunlik qiladi).
create or replace function qarz_notify_qoy(p_qarz_id uuid, p_tolov_id uuid, p_hodisa text,
                                            p_extra jsonb default null)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  q      qarz;
  qd     qarzdor;
  ka     accounts;
  h      v_qarz_holat;
  t      qarz_tolov;
  v_data jsonb;
  v_kim  uuid := auth.uid();
begin
  if p_qarz_id is null then
    return;
  end if;

  select * into q from qarz where id = p_qarz_id;
  if not found then
    return;
  end if;
  select * into qd from qarzdor where id = q.qarzdor_id;
  select * into ka from accounts where id = q.kassa_id;
  select * into h  from v_qarz_holat where qarz_id = q.id;

  v_data := jsonb_build_object(
    'qarzdor_ism',     qd.ism,
    'qarzdor_familya', qd.familya,
    'qarzdor_tur',     qd.tur,
    'kassa_kod',       ka.code,
    'kassa_nom',       ka.name,
    'summa',           q.summa,
    'currency',        q.currency,
    'muddat_matni',    qarz_muddat_matni(q.muddat_turi, q.oylik_summa, q.oylar_soni, q.boshlanish, q.tugash),
    'qolgan',          coalesce(h.qolgan, q.summa),
    'kim_id',          v_kim,
    'kim_nom',         sorov_ism(v_kim, null)
  );

  if p_tolov_id is not null then
    select * into t from qarz_tolov where id = p_tolov_id;
    if found then
      v_data := v_data || jsonb_build_object(
        'tolov_summa',     t.summa,
        'tolov_kassa_nom', (select a2.name from accounts a2 where a2.id = t.kassa_id)
      );
    end if;
  end if;

  v_data := v_data || coalesce(p_extra, '{}'::jsonb);

  insert into qarz_notify (qarz_id, tolov_id, hodisa, data)
  values (p_qarz_id, p_tolov_id, p_hodisa, v_data);
exception when others then
  raise warning 'qarz_notify_qoy xato (qarz=%, hodisa=%): %', p_qarz_id, p_hodisa, sqlerrm;
end $fn$;

revoke all on function qarz_notify_qoy(uuid, uuid, text, jsonb) from public, anon, authenticated;

comment on function qarz_notify_qoy(uuid, uuid, text, jsonb) is
  'ICHKI: qarz_notify OUTBOX yozuvi. Xato bolsa faqat WARNING — pul harakatini tosmaydi. '
  'p_tolov_id -> tolov_summa/tolov_kassa_nom avtomat. p_extra -> qoshimcha malumot (masalan bekor sababi).';


-- #####################################################################
-- ##  12-BOLIM — qarzdor_yarat / qarzdor_royxat                      ##
-- #####################################################################

create or replace function qarzdor_yarat(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid := auth.uid();
  v_tur     text := nullif(p->>'tur', '');
  v_staff   int  := nullif(p->>'staff_id', '')::int;
  v_ism     text := nullif(btrim(coalesce(p->>'ism', '')), '');
  v_familya text := nullif(btrim(coalesce(p->>'familya', '')), '');
  v_telefon text := nullif(btrim(coalesce(p->>'telefon', '')), '');
  v_izoh    text := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_staff_r aros_staff;
  v_id      uuid;
  v_ogoh    text := null;
  v_mavjud  int;
  v_ex_id   uuid;
  v_ex_active boolean;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('qarzdor') then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;
  if v_tur is null or v_tur not in ('ichki','tashqi') then
    raise exception 'Qarzdor turi notogri (ichki yoki tashqi)' using errcode = '22000';
  end if;

  if v_tur = 'ichki' then
    if v_staff is null then
      raise exception 'Hodim tanlanmagan' using errcode = '22000';
    end if;
    select * into v_staff_r from aros_staff where staff_id = v_staff;
    if not found then
      raise exception 'Hodim topilmadi' using errcode = '22000';
    end if;
    -- 🔴 IDEMPOTENT (Asilbek qarori): bu hodim allaqachon qarzdor bolsa
    --    XATO EMAS — mavjud id qaytadi (mavjud:true). Nofaol bolsa qayta
    --    faollashtiriladi (qolda ochirilgan bolishi mumkin edi).
    select id, is_active into v_ex_id, v_ex_active from qarzdor where staff_id = v_staff;
    if found then
      if not v_ex_active then
        update qarzdor set is_active = true where id = v_ex_id;
      end if;
      return jsonb_build_object('ok', true, 'id', v_ex_id, 'mavjud', true, 'ogohlantirish', null);
    end if;

    insert into qarzdor (tur, staff_id, ism, familya, telefon, izoh, created_by)
    values ('ichki', v_staff,
            coalesce(v_staff_r.ism, ''), coalesce(v_staff_r.familiya, ''),
            coalesce(v_telefon, v_staff_r.telefon), v_izoh, v_uid)
    returning id into v_id;

    return jsonb_build_object('ok', true, 'id', v_id, 'mavjud', false, 'ogohlantirish', null);
  end if;

  -- Tashqi
  if v_ism is null or v_familya is null then
    raise exception 'Ism va familya majburiy' using errcode = '22000';
  end if;

  select count(*) into v_mavjud
    from qarzdor
   where tur = 'tashqi'
     and lower(btrim(ism)) = lower(v_ism)
     and lower(btrim(familya)) = lower(v_familya);

  if v_mavjud > 0 then
    v_ogoh := 'Diqqat: shu ism-familya bilan allaqachon ' || v_mavjud::text || ' ta qarzdor bor';
  end if;

  insert into qarzdor (tur, staff_id, ism, familya, telefon, izoh, created_by)
  values ('tashqi', null, v_ism, v_familya, v_telefon, v_izoh, v_uid)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'ogohlantirish', v_ogoh);

exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'kod', 'takror');
end $fn$;

revoke all on function qarzdor_yarat(jsonb) from public, anon;
grant execute on function qarzdor_yarat(jsonb) to authenticated;

comment on function qarzdor_yarat(jsonb) is
  'Qarzdor yaratadi (ichki=aros_staff dan nusxa, unique staff_id; tashqi=qolda, '
  'bir xil ism-familya bloklanmaydi — ogohlantirish qaytaradi). Ichki IDEMPOTENT: '
  'staff_id mavjud bolsa xato emas, mavjud id + mavjud=true (nofaol bolsa qayta faollashadi).';


create or replace function qarzdor_royxat(p_q text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_q   text := nullif(btrim(coalesce(p_q, '')), '');
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('qarzdor') then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            j.qarzdor_id,
           'tur',           j.tur,
           'ism',           j.ism,
           'familya',       j.familya,
           'telefon',       j.telefon,
           'is_active',     j.is_active,
           'qarz_soni',     j.qarz_soni,
           'faol_soni',     j.faol_soni,
           'jami_qolgan',   j.jami_qolgan,
           'kechikkan_bor', j.kechikkan_bor
         ) order by j.jami_qolgan desc, j.familya, j.ism), '[]'::jsonb)
    into v_out
    from v_qarzdor_jami j
   where v_q is null
      or j.ism ilike '%'||v_q||'%'
      or j.familya ilike '%'||v_q||'%'
      or coalesce(j.telefon, '') ilike '%'||v_q||'%';

  return v_out;
end $fn$;

revoke all on function qarzdor_royxat(text) from public, anon;
grant execute on function qarzdor_royxat(text) to authenticated;

comment on function qarzdor_royxat(text) is
  'Qarzdorlar royxati (v_qarzdor_jami dan) — ism/familya/telefon boyicha qidiruv.';


-- #####################################################################
-- ##  13-BOLIM — qarz_yarat(jsonb)                                   ##
-- #####################################################################
-- Ichki -> darrov qarz_faollashtir() ICHKARIDA chaqiriladi (muvaffaqiyatsiz
-- bolsa BUTUN yaratish rollback boladi — qarz qatori qolib ketmaydi).
-- Tashqi -> tilxat_kutilmoqda holatida qoladi (draft, pul harakat qilmaydi).
-- #####################################################################

create or replace function qarz_yarat(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid         uuid := auth.uid();
  v_id          uuid := gen_random_uuid();
  v_qarzdor_id  uuid := nullif(p->>'qarzdor_id', '')::uuid;
  v_kassa_id    uuid := nullif(p->>'kassa_id', '')::uuid;
  v_summa       numeric := nullif(p->>'summa', '')::numeric;
  v_muddat      text := nullif(p->>'muddat_turi', '');
  v_oylik_summa numeric := nullif(p->>'oylik_summa', '')::numeric;
  v_oylar_soni  int := nullif(p->>'oylar_soni', '')::int;
  v_boshlanish  date := coalesce(nullif(p->>'boshlanish', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_tugash      date;
  v_izoh        text := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_shablon     uuid := nullif(p->>'tilxat_shablon_id', '')::uuid;
  v_tmatn       text := nullif(p->>'tilxat_matn', '');
  v_ext_client  text := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  v_ext         text;
  v_qd          qarzdor;
  v_ka          accounts;
  v_tilxat_kerak boolean;
  v_res         jsonb;
  v_mavjud_id   uuid;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('qarzdor') then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  -- 🔴 ext_ref — mijoz bersa (takror bosish/timeout himoyasi uchun) O'SHANI
  --    ishlatamiz, bermasa serverning ozi generatsiya qiladi (avvalgidek).
  if v_ext_client is not null and (length(v_ext_client) < 6 or length(v_ext_client) > 200) then
    raise exception 'ext_ref 6..200 belgi bolishi kerak' using errcode = '22000';
  end if;
  v_ext := coalesce(v_ext_client, 'qarz:' || v_id::text);

  -- Qarzdor
  if v_qarzdor_id is null then
    raise exception 'Qarzdor tanlanmagan' using errcode = '22000';
  end if;
  select * into v_qd from qarzdor where id = v_qarzdor_id;
  if not found or not v_qd.is_active then
    raise exception 'Qarzdor topilmadi yoki faol emas' using errcode = '22000';
  end if;

  -- Summa
  if v_summa is null or v_summa <= 0 then
    raise exception 'Summa musbat bolishi kerak' using errcode = '22000';
  end if;
  if v_summa > 100000000000 then
    raise exception 'Summa juda katta — tekshirib qayta yozing' using errcode = '22000';
  end if;

  -- Muddat
  if v_muddat is null or v_muddat not in ('oylik','bir_martalik') then
    raise exception 'Muddat turi notogri (oylik yoki bir_martalik)' using errcode = '22000';
  end if;
  if v_muddat = 'oylik' then
    if v_oylik_summa is null or v_oylik_summa <= 0 or v_oylar_soni is null or v_oylar_soni <= 0 then
      raise exception 'Oylik summa va oylar soni togri kiritilishi kerak' using errcode = '22000';
    end if;
    if v_oylar_soni > 120 then
      raise exception 'Oylar soni 120 dan oshmasin' using errcode = '22000';
    end if;
    if v_oylik_summa * (v_oylar_soni - 1) >= v_summa then
      raise exception 'Oylik summa va oylar soni umumiy summadan katta chiqmoqda' using errcode = '22000';
    end if;
    v_tugash := qarz_oy_qosh(v_boshlanish, v_oylar_soni - 1);
  else
    v_oylik_summa := null;
    v_oylar_soni  := null;
    v_tugash := v_boshlanish;
  end if;

  -- Kassa (sorov_yarat naqshi bilan bir xil qoida)
  if v_kassa_id is null then
    raise exception 'Kassa tanlanmagan' using errcode = '22000';
  end if;
  select * into v_ka from accounts where id = v_kassa_id;
  if not found or v_ka.is_active is distinct from true then
    raise exception 'Kassa topilmadi yoki faol emas' using errcode = '22000';
  end if;
  if v_ka.type <> 'aktiv' or v_ka.code not like '5%'
     or v_ka.kassa_turi is not distinct from 'xarajat_guruh' then
    raise exception 'Bu hisob kassa emas' using errcode = '22000';
  end if;
  if coalesce(v_ka.currency, 'UZS') <> 'UZS' then
    raise exception 'Qarz faqat som kassasidan beriladi' using errcode = '22000';
  end if;
  if not perm_check_accounts(array[v_kassa_id]) then
    raise exception 'Ruxsat yoq: bu kassada amaliyot qilish huquqingiz yoq' using errcode = '42501';
  end if;

  v_tilxat_kerak := (v_qd.tur = 'tashqi');

  insert into qarz (id, qarzdor_id, kassa_id, summa, currency, muddat_turi,
                     oylik_summa, oylar_soni, boshlanish, tugash, foiz_yillik, status,
                     tilxat_kerak, tilxat_shablon_id, tilxat_matn, izoh, ext_ref, created_by)
  values (v_id, v_qarzdor_id, v_kassa_id, v_summa, 'UZS', v_muddat,
          v_oylik_summa, v_oylar_soni, v_boshlanish, v_tugash, 0, 'tilxat_kutilmoqda',
          v_tilxat_kerak, v_shablon, v_tmatn, v_izoh, v_ext, v_uid);

  insert into qarz_tarix (qarz_id, hodisa, data, kim)
  values (v_id, 'yaratildi',
          jsonb_build_object('tur', v_qd.tur, 'summa', v_summa, 'kassa_id', v_kassa_id), v_uid);

  if v_qd.tur = 'ichki' then
    v_res := qarz_faollashtir(v_id);
    if not coalesce((v_res->>'ok')::boolean, false) then
      raise exception 'Qarz faollashtirilmadi: %', coalesce(v_res->>'kod', 'nomalum xato')
        using errcode = '22000';
    end if;
    return jsonb_build_object('ok', true, 'id', v_id, 'status', 'faol',
                               'entry_id', v_res->>'entry_id');
  end if;

  perform qarz_notify_qoy(v_id, null, 'draft_yaratildi');

  return jsonb_build_object('ok', true, 'id', v_id, 'status', 'tilxat_kutilmoqda');

exception
  -- 🔴 Takror bosish/timeout: xuddi shu ext_ref (mijoz bergan yoki server
  --    generatsiya qilgan) bilan mavjud qatorni topib id sini qaytaramiz —
  --    ikkinchi qarz yozilmaydi, klient mavjudini kartasiga otkazadi.
  when unique_violation then
    select id into v_mavjud_id from qarz where ext_ref = v_ext;
    return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_mavjud_id);
end $fn$;

revoke all on function qarz_yarat(jsonb) from public, anon;
grant execute on function qarz_yarat(jsonb) to authenticated;

comment on function qarz_yarat(jsonb) is
  'Qarz yaratadi. Ichki qarzdor -> darrov faollashtiriladi (pul chiqadi, xato bolsa hech '
  'narsa saqlanmaydi). Tashqi -> tilxat_kutilmoqda (draft, pul harakat qilmaydi). '
  'p->>ext_ref ixtiyoriy (takror bosish himoyasi) — takror kelsa kod=takror + mavjud id qaytadi.';


-- #####################################################################
-- ##  14-BOLIM — qarz_tilxat_yuklandi(uuid, text)                    ##
-- #####################################################################

create or replace function qarz_tilxat_yuklandi(p_id uuid, p_path text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid      uuid := auth.uid();
  q          qarz;
  v_path     text := nullif(btrim(coalesce(p_path, '')), '');
  v_expected text;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('qarzdor') then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  select * into q from qarz where id = p_id for update;
  if not found then
    raise exception 'Qarz topilmadi' using errcode = '22000';
  end if;
  if q.status <> 'tilxat_kutilmoqda' then
    return jsonb_build_object('ok', false, 'kod', 'holat_notogri', 'status', q.status);
  end if;
  if q.created_by is distinct from v_uid and not is_admin() then
    raise exception 'Faqat draftni ochgan odam yoki admin tilxat yuklaydi' using errcode = '42501';
  end if;

  v_expected := p_id::text || '/tilxat.jpg';
  if v_path is null or v_path <> v_expected then
    raise exception 'Fayl yoli notogri (kutilgan: %)', v_expected using errcode = '22000';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'qarz-tilxat' and name = v_path) then
    raise exception 'Fayl hali bucketga yuklanmagan' using errcode = '22000';
  end if;

  update qarz set tilxat_rasm_path = v_path where id = p_id;

  insert into qarz_tarix (qarz_id, hodisa, data, kim)
  values (p_id, 'tilxat_yuklandi', jsonb_build_object('path', v_path), v_uid);

  perform qarz_notify_qoy(p_id, null, 'tilxat_yuklandi');

  return jsonb_build_object('ok', true);
end $fn$;

revoke all on function qarz_tilxat_yuklandi(uuid, text) from public, anon;
grant execute on function qarz_tilxat_yuklandi(uuid, text) to authenticated;

comment on function qarz_tilxat_yuklandi(uuid, text) is
  'Tilxat rasmi bucketga yuklangach yolni qarz.tilxat_rasm_path ga yozadi. '
  'Yol qatiy shaklda tekshiriladi: <qarz_id>/tilxat.jpg, VA bucketda obyekt mavjudligi.';


-- #####################################################################
-- ##  15-BOLIM — qarz_faollashtir(uuid)  🔴 PUL HARAKATI              ##
-- #####################################################################

create or replace function qarz_faollashtir(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid := auth.uid();
  q         qarz;
  v_qd      qarzdor;
  v_ka      accounts;
  v_debtor  uuid;
  v_entry   uuid;
  v_n       int;
  v_i       int;
  v_sana    date;
  v_row_sum numeric;
  v_used    numeric := 0;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('qarzdor') then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  select * into q from qarz where id = p_id for update;
  if not found then
    raise exception 'Qarz topilmadi' using errcode = '22000';
  end if;

  -- Idempotent — ikki marta faollashtirish
  if q.status <> 'tilxat_kutilmoqda' then
    return jsonb_build_object('ok', false, 'kod', 'already_active', 'status', q.status);
  end if;

  select * into v_qd from qarzdor where id = q.qarzdor_id;

  select * into v_ka from accounts where id = q.kassa_id;
  if not found or v_ka.is_active is distinct from true then
    return jsonb_build_object('ok', false, 'kod', 'hisob_yoq');
  end if;
  if not perm_check_accounts(array[q.kassa_id]) then
    raise exception 'Ruxsat yoq: bu kassada amaliyot qilish huquqingiz yoq' using errcode = '42501';
  end if;

  -- Qoldiq yetadimi
  if sorov_kassa_bal(q.kassa_id) < q.summa then
    return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi');
  end if;

  -- Tilxat (faqat tashqi)
  if q.tilxat_kerak then
    if q.tilxat_rasm_path is null then
      return jsonb_build_object('ok', false, 'kod', 'tilxat_yoq');
    end if;
    if not exists (
      select 1 from storage.objects
       where bucket_id = 'qarz-tilxat' and name = q.tilxat_rasm_path
    ) then
      return jsonb_build_object('ok', false, 'kod', 'tilxat_fayl_yoq');
    end if;
  end if;

  v_debtor := qarz_debtor_account(v_qd.tur);
  if v_debtor is null then
    raise exception 'Qarz hisobi (4710/4720) topilmadi — avval ushbu faylning 1-bolimini RUN qiling'
      using errcode = '22000';
  end if;

  insert into entry (entry_date, description, source, status, ext_ref, created_by, filial_ids)
  values ((now() at time zone 'Asia/Tashkent')::date,
          'Qarz berildi: ' || v_qd.ism || ' ' || v_qd.familya || ' · ' ||
            qarz_muddat_matni(q.muddat_turi, q.oylik_summa, q.oylar_soni, q.boshlanish, q.tugash),
          'qarz',
          'posted',
          q.ext_ref,
          v_uid,
          '{}'::uuid[])
  returning id into v_entry;

  insert into entry_line (entry_id, account_id, debit, credit)
  values (v_entry, v_debtor,   q.summa, 0),
         (v_entry, q.kassa_id, 0,       q.summa);

  update qarz set status = 'faol', entry_id = v_entry, faol_at = now() where id = q.id;

  -- Tolov jadvali generatsiyasi
  if q.muddat_turi = 'bir_martalik' then
    insert into qarz_jadval (qarz_id, n, sana, summa) values (q.id, 1, q.boshlanish, q.summa);
  else
    v_n := q.oylar_soni;
    for v_i in 1..v_n loop
      v_sana := qarz_oy_qosh(q.boshlanish, v_i - 1);
      if v_i < v_n then
        v_row_sum := q.oylik_summa;
        v_used := v_used + v_row_sum;
      else
        v_row_sum := q.summa - v_used;
      end if;
      insert into qarz_jadval (qarz_id, n, sana, summa) values (q.id, v_i, v_sana, v_row_sum);
    end loop;
  end if;

  insert into qarz_tarix (qarz_id, hodisa, data, kim)
  values (q.id, 'faollashdi', jsonb_build_object('entry_id', v_entry), v_uid);

  perform qarz_notify_qoy(q.id, null, 'berildi');

  return jsonb_build_object('ok', true, 'status', 'faol', 'entry_id', v_entry);

exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'kod', 'takror');
end $fn$;

revoke all on function qarz_faollashtir(uuid) from public, anon;
grant execute on function qarz_faollashtir(uuid) to authenticated;

comment on function qarz_faollashtir(uuid) is
  'Draft qarzni faollashtiradi: Dt 4710/4720 (qarzdor turi boyicha) / Kt kassa, darrov posted. '
  'Qoldiq/tilxat tekshiruvi shu yerda. Idempotent (for update + status + ext_ref unique).';


-- #####################################################################
-- ##  16-BOLIM — qarz_tolov(...)  🔴 PUL HARAKATI                    ##
-- #####################################################################

create or replace function qarz_tolov(p_qarz uuid, p_kassa uuid, p_summa numeric,
                                       p_sana date default null, p_izoh text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid      uuid := auth.uid();
  q          qarz;
  v_qd       qarzdor;
  v_ka       accounts;
  v_debtor   uuid;
  v_entry    uuid;
  v_tolov_id uuid := gen_random_uuid();
  v_sana     date := coalesce(p_sana, (now() at time zone 'Asia/Tashkent')::date);
  v_izoh     text := nullif(btrim(coalesce(p_izoh, '')), '');
  v_qolgan   numeric;
  v_remaining numeric;
  v_alloc    numeric;
  jr         record;
  v_holat    text;
  v_all_paid boolean;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('qarzdor') then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;
  if p_summa is null or p_summa <= 0 then
    raise exception 'Summa musbat bolishi kerak' using errcode = '22000';
  end if;

  select * into q from qarz where id = p_qarz for update;
  if not found then
    raise exception 'Qarz topilmadi' using errcode = '22000';
  end if;
  if q.status <> 'faol' then
    return jsonb_build_object('ok', false, 'kod', 'faol_emas', 'status', q.status);
  end if;

  select * into v_ka from accounts where id = p_kassa;
  if not found or v_ka.is_active is distinct from true then
    raise exception 'Kassa topilmadi yoki faol emas' using errcode = '22000';
  end if;
  if v_ka.type <> 'aktiv' or v_ka.code not like '5%'
     or v_ka.kassa_turi is not distinct from 'xarajat_guruh' then
    raise exception 'Bu hisob kassa emas' using errcode = '22000';
  end if;
  if not perm_check_accounts(array[p_kassa]) then
    raise exception 'Ruxsat yoq: bu kassada amaliyot qilish huquqingiz yoq' using errcode = '42501';
  end if;

  select (q.summa - coalesce(sum(jr2.tolangan), 0)) into v_qolgan
    from qarz_jadval jr2 where jr2.qarz_id = q.id;
  v_qolgan := coalesce(v_qolgan, q.summa);

  if p_summa > v_qolgan then
    return jsonb_build_object('ok', false, 'kod', 'ortiqcha', 'qolgan', v_qolgan);
  end if;

  select * into v_qd from qarzdor where id = q.qarzdor_id;
  v_debtor := qarz_debtor_account(v_qd.tur);
  if v_debtor is null then
    raise exception 'Qarz hisobi (4710/4720) topilmadi' using errcode = '22000';
  end if;

  insert into entry (entry_date, description, source, status, ext_ref, created_by, filial_ids)
  values (v_sana,
          'Qarz qaytarildi: ' || v_qd.ism || ' ' || v_qd.familya,
          'qarz',
          'posted',
          'qarz_tolov:' || v_tolov_id::text,
          v_uid,
          '{}'::uuid[])
  returning id into v_entry;

  insert into entry_line (entry_id, account_id, debit, credit)
  values (v_entry, p_kassa,  p_summa, 0),
         (v_entry, v_debtor, 0,       p_summa);

  insert into qarz_tolov (id, qarz_id, kassa_id, summa, sana, izoh, entry_id, ext_ref, created_by)
  values (v_tolov_id, q.id, p_kassa, p_summa, v_sana, v_izoh, v_entry,
          'qarz_tolov:' || v_tolov_id::text, v_uid);

  -- FIFO taqsimot — eng eski tolanmagan qatordan boshlab
  v_remaining := p_summa;
  for jr in
    select * from qarz_jadval
     where qarz_id = q.id and tolangan < summa
     order by n
     for update
  loop
    exit when v_remaining <= 0;
    v_alloc := least(v_remaining, jr.summa - jr.tolangan);
    update qarz_jadval set tolangan = tolangan + v_alloc where id = jr.id;
    v_remaining := v_remaining - v_alloc;
  end loop;

  select not exists (
    select 1 from qarz_jadval where qarz_id = q.id and tolangan < summa
  ) into v_all_paid;

  if v_all_paid then
    update qarz set status = 'yopildi', yopilgan_at = now() where id = q.id;
    v_holat := 'yopildi';
  else
    v_holat := 'faol';
  end if;

  insert into qarz_tarix (qarz_id, hodisa, data, kim)
  values (q.id, 'tolov',
          jsonb_build_object('tolov_id', v_tolov_id, 'summa', p_summa, 'qolgan_keyin', v_qolgan - p_summa),
          v_uid);

  if v_holat = 'yopildi' then
    insert into qarz_tarix (qarz_id, hodisa, data, kim)
    values (q.id, 'yopildi', jsonb_build_object('tolov_id', v_tolov_id), v_uid);
  end if;

  perform qarz_notify_qoy(q.id, v_tolov_id, 'tolov');
  if v_holat = 'yopildi' then
    perform qarz_notify_qoy(q.id, v_tolov_id, 'yopildi');
  end if;

  return jsonb_build_object('ok', true, 'tolov_id', v_tolov_id,
                             'qolgan_keyin', v_qolgan - p_summa, 'status', v_holat);

exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'kod', 'takror');
end $fn$;

revoke all on function qarz_tolov(uuid, uuid, numeric, date, text) from public, anon;
grant execute on function qarz_tolov(uuid, uuid, numeric, date, text) to authenticated;

comment on function qarz_tolov(uuid, uuid, numeric, date, text) is
  'Qarz qaytarish: Dt kassa (kirim) / Kt 4710-4720 (qarz kamayadi), darrov posted. '
  'FIFO taqsimot qarz_jadval ga. Oxirgi som -> qarz.status=yopildi avtomat.';


-- #####################################################################
-- ##  17-BOLIM — qarz_jadval_qayta(uuid, jsonb) — admin              ##
-- #####################################################################
-- Faqat TOLIQ tolanmagan qatorlar (tolangan=0) almashtiriladi. Qisman
-- tolangan qator bolsa — fail-closed, operatsiya rad etiladi (aniqlik
-- yoqolmasin uchun). Yangi jadval yigindisi joriy QOLGAN summaga TENG
-- bolishi shart.
-- #####################################################################

create or replace function qarz_jadval_qayta(p_id uuid, p_jadval jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid := auth.uid();
  q         qarz;
  v_qolgan  numeric;
  it        jsonb;
  v_sum     numeric := 0;
  v_next_n  int;
  v_sana    date;
  v_summa   numeric;
  v_old     jsonb;
  v_new     jsonb := '[]'::jsonb;
  v_unpaid_n int;
  v_uniform_summa numeric;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not is_admin() then
    raise exception 'Faqat admin grafikni qayta tuza oladi' using errcode = '42501';
  end if;

  select * into q from qarz where id = p_id for update;
  if not found then
    raise exception 'Qarz topilmadi' using errcode = '22000';
  end if;
  if q.status <> 'faol' then
    raise exception 'Faqat faol qarz grafigi qayta tuziladi' using errcode = '22000';
  end if;

  if exists (
    select 1 from qarz_jadval where qarz_id = p_id and tolangan > 0 and tolangan < summa
  ) then
    raise exception 'Qisman tolangan qator bor — avval uni toliq yoping, keyin qayta tuzing'
      using errcode = '22000';
  end if;

  if p_jadval is null or jsonb_typeof(p_jadval) <> 'array' or jsonb_array_length(p_jadval) < 1 then
    raise exception 'Yangi jadval bosh bolmasin' using errcode = '22000';
  end if;

  for it in select * from jsonb_array_elements(p_jadval) loop
    v_sana  := nullif(it->>'sana', '')::date;
    v_summa := nullif(it->>'summa', '')::numeric;
    if v_sana is null or v_summa is null or v_summa <= 0 then
      raise exception 'Jadval qatorida sana/summa notogri' using errcode = '22000';
    end if;
    v_sum := v_sum + v_summa;
  end loop;

  select (q.summa - coalesce(sum(jr.tolangan), 0)) into v_qolgan
    from qarz_jadval jr where jr.qarz_id = p_id;
  v_qolgan := coalesce(v_qolgan, q.summa);

  if abs(v_sum - v_qolgan) > 0.01 then
    raise exception 'Yangi jadval yigindisi (%) qolgan summaga (%) teng emas', v_sum, v_qolgan
      using errcode = '22000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('n', n, 'sana', sana, 'summa', summa)), '[]'::jsonb)
    into v_old
    from qarz_jadval where qarz_id = p_id and tolangan = 0;

  delete from qarz_jadval where qarz_id = p_id and tolangan = 0;

  select coalesce(max(n), 0) into v_next_n from qarz_jadval where qarz_id = p_id;

  for it in select * from jsonb_array_elements(p_jadval) as elem order by (elem->>'sana')::date loop
    v_next_n := v_next_n + 1;
    insert into qarz_jadval (qarz_id, n, sana, summa)
    values (p_id, v_next_n, (it->>'sana')::date, (it->>'summa')::numeric);
    v_new := v_new || jsonb_build_object('n', v_next_n, 'sana', it->>'sana', 'summa', it->>'summa');
  end loop;

  -- 🔴 Qayta tuzilgan grafik "individual" boladi: oylar_soni = QOLGAN
  --    (tolanmagan) qatorlar soni, oylik_summa esa faqat HAMMA yangi qator
  --    bir xil summada bolsa saqlanadi (aks holda NULL — qarz_muddat_matni
  --    buni "Individual grafik" deb korsatadi).
  v_unpaid_n := jsonb_array_length(p_jadval);

  select case when count(distinct (elem->>'summa')::numeric) = 1
              then min((elem->>'summa')::numeric)
              else null end
    into v_uniform_summa
    from jsonb_array_elements(p_jadval) as elem;

  update qarz
     set tugash      = (select max(sana) from qarz_jadval where qarz_id = p_id),
         oylar_soni  = v_unpaid_n,
         oylik_summa = v_uniform_summa
   where id = p_id;

  insert into qarz_tarix (qarz_id, hodisa, data, kim)
  values (p_id, 'jadval_qayta', jsonb_build_object('eski', v_old, 'yangi', v_new), v_uid);

  return jsonb_build_object('ok', true, 'qolgan', v_qolgan);
end $fn$;

revoke all on function qarz_jadval_qayta(uuid, jsonb) from public, anon;
grant execute on function qarz_jadval_qayta(uuid, jsonb) to authenticated;

comment on function qarz_jadval_qayta(uuid, jsonb) is
  'Admin: faol qarz grafigini qayta tuzadi. Faqat tolangan=0 qatorlar almashadi, '
  'yigindi joriy qolgan summaga teng bolishi SHART (fail-closed). Muvaffaqiyatda '
  'qarz.oylar_soni=qolgan qator soni, oylik_summa=hammasi teng bolsagina o''sha qiymat, aks holda null.';


-- #####################################################################
-- ##  18-BOLIM — qarz_bekor(uuid, text)                              ##
-- #####################################################################

create or replace function qarz_bekor(p_id uuid, p_sabab text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid  uuid := auth.uid();
  q      qarz;
  v_sabab text := nullif(btrim(coalesce(p_sabab, '')), '');
begin
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('qarzdor') then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;
  if v_sabab is null or length(v_sabab) < 3 then
    raise exception 'Bekor qilish sababi majburiy (kamida 3 belgi)' using errcode = '22000';
  end if;

  select * into q from qarz where id = p_id for update;
  if not found then
    raise exception 'Qarz topilmadi' using errcode = '22000';
  end if;

  -- faol -> bekor TAQIQ (pul allaqachon chiqqan) — faqat draft bekor qilinadi.
  if q.status <> 'tilxat_kutilmoqda' then
    return jsonb_build_object('ok', false, 'kod', 'faol_bolgan', 'status', q.status);
  end if;

  if q.created_by is distinct from v_uid and not is_admin() then
    raise exception 'Faqat draftni ochgan odam yoki admin bekor qila oladi' using errcode = '42501';
  end if;

  update qarz set status = 'bekor' where id = p_id;

  insert into qarz_tarix (qarz_id, hodisa, data, kim)
  values (p_id, 'bekor', jsonb_build_object('sabab', v_sabab), v_uid);

  perform qarz_notify_qoy(p_id, null, 'bekor', jsonb_build_object('sabab', v_sabab));

  return jsonb_build_object('ok', true, 'status', 'bekor');
end $fn$;

revoke all on function qarz_bekor(uuid, text) from public, anon;
grant execute on function qarz_bekor(uuid, text) to authenticated;

comment on function qarz_bekor(uuid, text) is
  'Faqat draft (tilxat_kutilmoqda) bekor qilinadi — faol qarz TAQIQ (pul allaqachon chiqqan).';


-- #####################################################################
-- ##  19-BOLIM — qarz_royxat / qarz_kart / qarz_dash                 ##
-- #####################################################################

create or replace function qarz_royxat(p_holat text default null, p_qarzdor uuid default null,
                                        p_q text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_h   text := nullif(btrim(coalesce(p_holat, '')), '');
  v_q   text := nullif(btrim(coalesce(p_q, '')), '');
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('qarzdor') then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;
  if v_h is not null and v_h not in ('all','tilxat_kutilmoqda','faol','yopildi','bekor') then
    raise exception 'Notanish holat: %', v_h using errcode = '22000';
  end if;

  select coalesce(jsonb_agg(x.j order by x.sana desc), '[]'::jsonb)
    into v_out
    from (
      select qarz_qator(q) as j, q.created_at as sana
        from qarz q
        join qarzdor qd on qd.id = q.qarzdor_id
       where (v_h is null or v_h = 'all' or q.status = v_h)
         and (p_qarzdor is null or q.qarzdor_id = p_qarzdor)
         and (v_q is null
              or qd.ism ilike '%'||v_q||'%'
              or qd.familya ilike '%'||v_q||'%'
              or coalesce(qd.telefon, '') ilike '%'||v_q||'%'
              or coalesce(q.izoh, '') ilike '%'||v_q||'%')
       order by q.created_at desc
       limit 500
    ) x;

  return v_out;
end $fn$;

revoke all on function qarz_royxat(text, uuid, text) from public, anon;
grant execute on function qarz_royxat(text, uuid, text) to authenticated;

comment on function qarz_royxat(text, uuid, text) is
  'Qarzlar royxati (qarz_qator shakli). Filtr: holat, qarzdor, matn qidiruv. Eng yangi 500 ta.';


create or replace function qarz_kart(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid       uuid := auth.uid();
  q           qarz;
  v_jadval    jsonb;
  v_tolovlar  jsonb;
  v_tarix     jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('qarzdor') then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  select * into q from qarz where id = p_id;
  if not found then
    raise exception 'Qarz topilmadi' using errcode = '22000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', jr.id, 'n', jr.n, 'sana', jr.sana, 'summa', jr.summa,
           'tolangan', jr.tolangan, 'qolgan', jr.summa - jr.tolangan,
           'status', case
             when jr.tolangan >= jr.summa then 'tolandi'
             when jr.sana < (now() at time zone 'Asia/Tashkent')::date and jr.tolangan < jr.summa then 'kechikkan'
             when jr.tolangan > 0 then 'qisman'
             else 'kutilmoqda' end
         ) order by jr.n), '[]'::jsonb)
    into v_jadval
    from qarz_jadval jr where jr.qarz_id = p_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'kassa_id', t.kassa_id, 'kassa_nom', a.name, 'summa', t.summa,
           'sana', t.sana, 'izoh', t.izoh, 'entry_id', t.entry_id,
           'created_by', t.created_by, 'created_by_nom', sorov_ism(t.created_by, null),
           'created_at', t.created_at, 'is_deleted', t.is_deleted
         ) order by t.sana desc, t.created_at desc), '[]'::jsonb)
    into v_tolovlar
    from qarz_tolov t
    join accounts a on a.id = t.kassa_id
   where t.qarz_id = p_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', h.id, 'hodisa', h.hodisa, 'data', h.data,
           'kim', h.kim, 'kim_nom', sorov_ism(h.kim, null), 'vaqt', h.vaqt
         ) order by h.vaqt desc), '[]'::jsonb)
    into v_tarix
    from qarz_tarix h where h.qarz_id = p_id;

  return jsonb_build_object(
    'qarz',       qarz_qator(q),
    'jadval',     v_jadval,
    'tolovlar',   v_tolovlar,
    'tarix',      v_tarix,
    'tilxat_path', q.tilxat_rasm_path
  );
end $fn$;

revoke all on function qarz_kart(uuid) from public, anon;
grant execute on function qarz_kart(uuid) to authenticated;

comment on function qarz_kart(uuid) is
  'Bitta qarz toliq: qarz (qarz_qator shakli) + jadval + tolovlar + tarix + tilxat_path.';


create or replace function qarz_dash()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid             uuid := auth.uid();
  v_jami_berilgan   numeric;
  v_jami_qolgan     numeric;
  v_jami_kechikkan  numeric;
  v_muddat_soni     int;
  v_muddat_summa    numeric;
  v_oylik_soni      int;
  v_oylik_summa     numeric;
  v_tilxat_soni     int;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('qarzdor') then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  select coalesce(sum(q.summa), 0), coalesce(sum(h.qolgan), 0), coalesce(sum(h.kechikkan_summa), 0)
    into v_jami_berilgan, v_jami_qolgan, v_jami_kechikkan
    from qarz q
    join v_qarz_holat h on h.qarz_id = q.id
   where q.status = 'faol';

  select count(*), coalesce(sum(s.qolgan_row), 0)
    into v_muddat_soni, v_muddat_summa
    from v_qarz_shu_oy s;

  select count(*), coalesce(sum(s.qolgan_row), 0)
    into v_oylik_soni, v_oylik_summa
    from v_qarz_shu_oy s where s.muddat_turi = 'oylik';

  select count(*) into v_tilxat_soni from qarz where status = 'tilxat_kutilmoqda';

  return jsonb_build_object(
    'jami_berilgan',         coalesce(v_jami_berilgan, 0),
    'jami_qolgan',           coalesce(v_jami_qolgan, 0),
    'jami_kechikkan',        coalesce(v_jami_kechikkan, 0),
    'shu_oy_muddat_soni',    coalesce(v_muddat_soni, 0),
    'shu_oy_muddat_summa',   coalesce(v_muddat_summa, 0),
    'shu_oy_oylik_soni',     coalesce(v_oylik_soni, 0),
    'shu_oy_oylik_summa',    coalesce(v_oylik_summa, 0),
    'tilxat_kutilmoqda_soni', coalesce(v_tilxat_soni, 0)
  );
end $fn$;

revoke all on function qarz_dash() from public, anon;
grant execute on function qarz_dash() to authenticated;

comment on function qarz_dash() is
  'Dashboard raqamlari: jami berilgan/qolgan/kechikkan, shu oy muddati/oylik, tilxat kutilmoqda soni.';


-- #####################################################################
-- ##  20-BOLIM — tilxat_shablon_saqla(jsonb) — admin                 ##
-- #####################################################################

create or replace function tilxat_shablon_saqla(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid := auth.uid();
  v_id      uuid := nullif(p->>'id', '')::uuid;
  v_nom     text := nullif(btrim(coalesce(p->>'nom', '')), '');
  v_matn    text := nullif(p->>'matn', '');
  v_default boolean := coalesce((p->>'is_default')::boolean, false);
  v_active  boolean := coalesce((p->>'is_active')::boolean, true);
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not is_admin() then
    raise exception 'Faqat admin tilxat shablonini ozgartira oladi' using errcode = '42501';
  end if;
  if v_nom is null or length(v_nom) < 2 then
    raise exception 'Shablon nomi majburiy' using errcode = '22000';
  end if;
  if v_matn is null or length(btrim(v_matn)) < 10 then
    raise exception 'Shablon matni juda qisqa' using errcode = '22000';
  end if;

  if v_default then
    update tilxat_shablon
       set is_default = false
     where is_default = true
       and id <> coalesce(v_id, '00000000-0000-0000-0000-000000000000'::uuid);
  end if;

  if v_id is null then
    insert into tilxat_shablon (nom, matn, is_default, is_active, created_by)
    values (v_nom, v_matn, v_default, v_active, v_uid)
    returning id into v_id;
  else
    update tilxat_shablon
       set nom = v_nom, matn = v_matn, is_default = v_default, is_active = v_active, updated_at = now()
     where id = v_id;
    if not found then
      raise exception 'Shablon topilmadi' using errcode = '22000';
    end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end $fn$;

revoke all on function tilxat_shablon_saqla(jsonb) from public, anon;
grant execute on function tilxat_shablon_saqla(jsonb) to authenticated;

comment on function tilxat_shablon_saqla(jsonb) is
  'Admin: tilxat shablon yaratadi/tahrirlaydi. id berilmasa yangi, berilsa yangilaydi. '
  'is_default=true bolsa avvalgi sukut shablon avtomat false boladi.';


-- #####################################################################
-- ##  21-BOLIM — qarz_notify_pending / belgila / eslatma_navbat      ##
-- ##  (service_role ONLY — n8n "Aros Provodka - Qarz Notify")        ##
-- #####################################################################

create or replace function qarz_notify_pending(p_limit int default 50)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_ids   bigint[] := '{}';
  v_items jsonb;
  v_admin jsonb;
  r       record;
begin
  for r in
    select id from qarz_notify
     where sent_at is null and attempts < 30
     order by id
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update skip locked
  loop
    v_ids := array_append(v_ids, r.id);
  end loop;

  if to_regclass('public.hodim_notify_admin') is not null then
    select coalesce(jsonb_agg(jsonb_build_object('telegram_id', telegram_id, 'ism', coalesce(ism, ''))), '[]'::jsonb)
      into v_admin
      from hodim_notify_admin where is_active;
  else
    v_admin := '[]'::jsonb;
  end if;

  if array_length(v_ids, 1) is null then
    return jsonb_build_object('items', '[]'::jsonb, 'adminlar', v_admin);
  end if;

  update qarz_notify set attempts = attempts + 1 where id = any(v_ids);

  select coalesce(jsonb_agg(
           jsonb_build_object('id', n.id, 'hodisa', n.hodisa, 'qarz_id', n.qarz_id,
                               'tolov_id', n.tolov_id,
                               'vaqt', to_char(n.created_at + interval '5 hours', 'DD.MM.YYYY HH24:MI'))
           || coalesce(n.data, '{}'::jsonb)
           order by n.id), '[]'::jsonb)
    into v_items
    from qarz_notify n
   where n.id = any(v_ids);

  return jsonb_build_object('items', v_items, 'adminlar', v_admin);
end $fn$;

revoke all on function qarz_notify_pending(int) from public, anon, authenticated;
grant execute on function qarz_notify_pending(int) to service_role;

comment on function qarz_notify_pending(int) is
  'n8n uchun: yuborilmagan qarz-hodisa xabarlari + hodim_notify_admin (mavjud jadval) royxati. '
  'Chaqirilganda attempts oshadi.';


create or replace function qarz_notify_belgila(p_ids bigint[], p_err text default null)
returns void
language sql
security definer
set search_path = public
as $fn$
  update qarz_notify
     set sent_at    = case when p_err is null then now() else sent_at end,
         last_error = p_err
   where id = any(p_ids);
$fn$;

revoke all on function qarz_notify_belgila(bigint[], text) from public, anon, authenticated;
grant execute on function qarz_notify_belgila(bigint[], text) to service_role;

comment on function qarz_notify_belgila(bigint[], text) is
  'n8n uchun: muvaffaqiyatli yuborilgan qatorlarni sent_at bilan belgilaydi (p_err null bolsa).';


create or replace function qarz_eslatma_navbat()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_bugun date := (now() at time zone 'Asia/Tashkent')::date;
  v_items jsonb;
  v_n     int;
begin
  if exists (
    select 1 from qarz_notify
     where hodisa = 'eslatma'
       and (created_at at time zone 'Asia/Tashkent')::date = v_bugun
  ) then
    return jsonb_build_object('ok', true, 'kod', 'already_queued');
  end if;

  select jsonb_agg(jsonb_build_object(
           'qarz_id',         s.qarz_id,
           'qarzdor_ism',     s.qarzdor_ism,
           'qarzdor_familya', s.qarzdor_familya,
           'qarzdor_tur',     s.qarzdor_tur,
           'kassa_kod',       s.kassa_kod,
           'kassa_nom',       s.kassa_nom,
           'sana',            s.sana,
           'summa',           s.qolgan_row,
           'holat',           s.holat
         ) order by s.sana),
         count(*)
    into v_items, v_n
    from v_qarz_shu_oy s
   where s.sana <= v_bugun;

  if coalesce(v_n, 0) = 0 then
    return jsonb_build_object('ok', true, 'kod', 'bosh');
  end if;

  insert into qarz_notify (qarz_id, hodisa, data)
  values (null, 'eslatma', jsonb_build_object('items', v_items, 'soni', v_n));

  return jsonb_build_object('ok', true, 'soni', v_n);
end $fn$;

revoke all on function qarz_eslatma_navbat() from public, anon, authenticated;
grant execute on function qarz_eslatma_navbat() to service_role;

comment on function qarz_eslatma_navbat() is
  'n8n kunlik cron: bugun muddati kelgan + kechikkan qatorlarni bitta yigma qarz_notify '
  'qatoriga (hodisa=eslatma) qoyadi. Kuniga BIR marta (bugungi eslatma qatori bormi tekshiradi).';


-- #####################################################################
-- ##  22-BOLIM — PostgREST sxema keshi                               ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  23-BOLIM — YAKUNIY TEKSHIRUV (faqat select)                    ##
-- #####################################################################

do $qarz_check$
declare
  v_n int;
begin
  -- 23.1 Hisoblar
  if not exists (select 1 from accounts where code = '4700') then
    raise exception '4700 hisobi yaratilmadi';
  end if;
  if not exists (select 1 from accounts where code = '4710') then
    raise exception '4710 hisobi yaratilmadi';
  end if;
  if not exists (select 1 from accounts where code = '4720') then
    raise exception '4720 hisobi yaratilmadi';
  end if;

  -- 23.2 Jadvallar
  if to_regclass('public.tilxat_shablon') is null then raise exception 'tilxat_shablon yaratilmadi'; end if;
  if to_regclass('public.qarzdor')        is null then raise exception 'qarzdor yaratilmadi'; end if;
  if to_regclass('public.qarz')           is null then raise exception 'qarz yaratilmadi'; end if;
  if to_regclass('public.qarz_jadval')    is null then raise exception 'qarz_jadval yaratilmadi'; end if;
  if to_regclass('public.qarz_tolov')     is null then raise exception 'qarz_tolov (jadval) yaratilmadi'; end if;
  if to_regclass('public.qarz_tarix')     is null then raise exception 'qarz_tarix yaratilmadi'; end if;
  if to_regclass('public.qarz_notify')    is null then raise exception 'qarz_notify yaratilmadi'; end if;

  -- 23.3 Sukut tilxat shablon
  if not exists (select 1 from tilxat_shablon where is_default = true) then
    raise exception 'Sukut tilxat shabloni topilmadi';
  end if;

  -- 23.4 RLS yoqilgan (har jadval alohida)
  if not (select relrowsecurity from pg_class where oid = 'public.qarzdor'::regclass) then
    raise exception 'qarzdor da RLS yoqilmagan';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.qarz'::regclass) then
    raise exception 'qarz da RLS yoqilmagan';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.qarz_jadval'::regclass) then
    raise exception 'qarz_jadval da RLS yoqilmagan';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.qarz_tolov'::regclass) then
    raise exception 'qarz_tolov (jadval) da RLS yoqilmagan';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.qarz_tarix'::regclass) then
    raise exception 'qarz_tarix da RLS yoqilmagan';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.qarz_notify'::regclass) then
    raise exception 'qarz_notify da RLS yoqilmagan';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.tilxat_shablon'::regclass) then
    raise exception 'tilxat_shablon da RLS yoqilmagan';
  end if;

  -- 23.5 qarz_notify da yozish policysi (umuman policy) YOQ
  select count(*) into v_n from pg_policies
   where schemaname = 'public' and tablename = 'qarz_notify';
  if v_n > 0 then
    raise exception 'qarz_notify da policy bor (% ta) — bolmasligi kerak', v_n;
  end if;

  -- 23.6 Funksiyalar (imzo boyicha)
  if to_regprocedure('public.qarz_page_ok()')                               is null then raise exception 'qarz_page_ok() yaratilmadi'; end if;
  if to_regprocedure('public.qarz_oy_qosh(date, int)')                      is null then raise exception 'qarz_oy_qosh(date,int) yaratilmadi'; end if;
  if to_regprocedure('public.qarzdor_yarat(jsonb)')                         is null then raise exception 'qarzdor_yarat(jsonb) yaratilmadi'; end if;
  if to_regprocedure('public.qarzdor_royxat(text)')                        is null then raise exception 'qarzdor_royxat(text) yaratilmadi'; end if;
  if to_regprocedure('public.qarz_yarat(jsonb)')                            is null then raise exception 'qarz_yarat(jsonb) yaratilmadi'; end if;
  if to_regprocedure('public.qarz_tilxat_yuklandi(uuid, text)')             is null then raise exception 'qarz_tilxat_yuklandi(uuid,text) yaratilmadi'; end if;
  if to_regprocedure('public.qarz_faollashtir(uuid)')                       is null then raise exception 'qarz_faollashtir(uuid) yaratilmadi'; end if;
  if to_regprocedure('public.qarz_tolov(uuid, uuid, numeric, date, text)')  is null then raise exception 'qarz_tolov(...) funksiyasi yaratilmadi'; end if;
  if to_regprocedure('public.qarz_jadval_qayta(uuid, jsonb)')               is null then raise exception 'qarz_jadval_qayta(uuid,jsonb) yaratilmadi'; end if;
  if to_regprocedure('public.qarz_bekor(uuid, text)')                       is null then raise exception 'qarz_bekor(uuid,text) yaratilmadi'; end if;
  if to_regprocedure('public.qarz_royxat(text, uuid, text)')                is null then raise exception 'qarz_royxat(text,uuid,text) yaratilmadi'; end if;
  if to_regprocedure('public.qarz_kart(uuid)')                              is null then raise exception 'qarz_kart(uuid) yaratilmadi'; end if;
  if to_regprocedure('public.qarz_dash()')                                  is null then raise exception 'qarz_dash() yaratilmadi'; end if;
  if to_regprocedure('public.tilxat_shablon_saqla(jsonb)')                  is null then raise exception 'tilxat_shablon_saqla(jsonb) yaratilmadi'; end if;
  if to_regprocedure('public.qarz_notify_pending(int)')                     is null then raise exception 'qarz_notify_pending(int) yaratilmadi'; end if;
  if to_regprocedure('public.qarz_notify_belgila(bigint[], text)')          is null then raise exception 'qarz_notify_belgila(bigint[],text) yaratilmadi'; end if;
  if to_regprocedure('public.qarz_eslatma_navbat()')                        is null then raise exception 'qarz_eslatma_navbat() yaratilmadi'; end if;

  -- 23.7 GRANT/REVOKE tekshiruvi (namuna)
  if not has_function_privilege('authenticated', 'public.qarz_page_ok()', 'execute') then
    raise exception 'qarz_page_ok() authenticated uchun yopiq — RLS SELECT hammaga 42501 berardi';
  end if;
  if not has_function_privilege('authenticated', 'public.qarz_yarat(jsonb)', 'execute') then
    raise exception 'qarz_yarat(jsonb) authenticated uchun yopiq — UI ishlamaydi';
  end if;
  if has_function_privilege('anon', 'public.qarz_yarat(jsonb)', 'execute') then
    raise exception 'qarz_yarat(jsonb) anon uchun ochiq qolgan';
  end if;
  if has_function_privilege('authenticated', 'public.qarz_notify_pending(int)', 'execute') then
    raise exception 'qarz_notify_pending(int) authenticated uchun ochiq qolgan (service_role ONLY bolishi kerak)';
  end if;
  if not has_function_privilege('service_role', 'public.qarz_notify_pending(int)', 'execute') then
    raise exception 'qarz_notify_pending(int) service_role uchun yopiq';
  end if;

  -- 23.8 Bucket
  if not exists (select 1 from storage.buckets where id = 'qarz-tilxat') then
    raise exception 'qarz-tilxat bucket yaratilmadi';
  end if;

  raise notice 'PROVODKA_QARZ.sql tayyor. Jami qarzdor: % ta, jami qarz: % ta',
    (select count(*) from qarzdor), (select count(*) from qarz);
end
$qarz_check$;
