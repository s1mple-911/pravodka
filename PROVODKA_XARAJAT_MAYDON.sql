-- =====================================================================
-- PROVODKA — XARAJAT TURIGA MAXSUS MAYDONLAR (UNIVERSAL konstruktor)
-- ---------------------------------------------------------------------
-- BRIEF: BRIEF_PROVODKA_XARAJAT_MAYDON.md (1-3 bandlar + "DB (additive)").
--
-- NIMA UCHUN:
--   Har xarajat moddasiga (accounts.type='xarajat') "maxsus maydon"
--   biriktirish tizimi. Xarajat yozilayotganda o'sha modda tanlansa —
--   maydon(lar) chiqadi, to'ldiriladi va qiymat jurnal/hisobotda ko'rinadi.
--
-- 🔴 UNIVERSAL — MASHINA UCHUN ALOHIDA KOD YO'Q.
--   Bu faylning HECH BIR jadvalida/ustunida/funksiyasida "mashina",
--   "benzin", "gaz", "DAMAS", "Tracker", "davlat raqami" degan tushuncha
--   YO'Q. Mashina — shunchaki `maydon_turi='royxat'` bo'lgan maydonning
--   BIRINCHI misoli va u faqat 9-BO'LIMdagi (ATAYLAB izohga olingan) SEED
--   ma'lumotida uchraydi. Ertaga "Obyekt", "Ta'minotchi", "Xona raqami"
--   maydoni SHU KODNI O'ZGARTIRMASDAN, faqat sozlamadan qo'shiladi.
--   Tekshirish oson: fayldagi kod qismida (SEED dan tashqari) mashinaga oid
--   birorta matn yo'q — pastdagi TEKSHIRUV 6-bandi buni katalogdan sanaydi.
--
-- =====================================================================
-- SXEMA — NEGA AYNAN SHUNDAY (4 jadval)
-- ---------------------------------------------------------------------
--   xarajat_maydon         — maydon TA'RIFI (nom, turi, majburiymi, tartib,
--                            options). Moddaga bog'lanmagan.
--   xarajat_maydon_modda   — TA'RIF ↔ XARAJAT MODDASI biriktirish (N:M).
--   xarajat_royxat_element — "ro'yxatdan tanlash" variantlari (nom, qiymat,
--                            rasm_url) — ta'rifga tegishli.
--   entry_maydon           — YOZUVDAGI QIYMAT (entry_id, maydon_id,
--                            element_id | qiymat_matn).
--
-- 🔴 NEGA N:M (brief'dagi "maydon.modda_id" dan farqi — ONGLI qaror):
--   Brief 2-bandida IKKI modda bor: "Moshina Gaz" va "Moshina Benzin",
--   ikkalasiga ham AYNAN BIR XIL mashina ro'yxati kerak. `modda_id` maydon
--   ta'rifining ichida bo'lsa, DAMAS/Tracker IKKI marta kiritilardi va
--   uchinchi mashina qo'shilganda admin uni ikki joyga yozishi kerak
--   bo'lardi (vaqt o'tib ro'yxatlar bir-biridan farq qilib ketardi —
--   hisobotda "DAMAS" ikkita boshqa-boshqa element bo'lib chiqardi).
--   Endi ro'yxat BITTA, biriktirish esa arzon qator.
--   `required` (majburiylik) biriktirishda ham bor: bitta maydon bir
--   moddada majburiy, boshqasida ixtiyoriy bo'lishi mumkin
--   (amaldagi qiymat = coalesce(biriktirish.required, tarif.required)).
--
-- 🔴 NEGA `entry_maydon` ALOHIDA JADVAL (entry.jsonb ustuni EMAS):
--   1) FILTR/HISOBOT: "qaysi yozuvlarda DAMAS tanlangan", "har mashinaga
--      qancha ketdi" — oddiy JOIN + indeks bilan. jsonb da bu har safar
--      to'liq skan bo'lardi.
--   2) YAXLITLIK: `element_id` — haqiqiy FK. Element nomi o'zgarsa
--      (raqam almashsa) ESKI YOZUVLAR ham to'g'ri ko'rinadi, chunki yozuvda
--      nom emas, ID turadi. jsonb'da nom nusxa bo'lib qotib qolardi.
--   3) RUXSAT: RLS QATOR darajasida ishlaydi (pastdagi policy'lar).
--      `entry` ning ustuni bo'lsa, uni o'qish/yozish huquqi `entry` ning
--      o'ziga yopishib qolardi va begona yozuvga metadata yozishni
--      to'sib bo'lmasdi.
--   4) ADDITIVE: `entry` jadvali UMUMAN TEGILMAYDI (bitta ustun ham
--      qo'shilmaydi) — prod frontendga ta'sir nol.
--
-- MAYDON TURLARI (`maydon_turi`):
--   'royxat'   — oldindan tayyorlangan variantlar: nom + qiymat + RASM.
--                Variantlar `xarajat_royxat_element` jadvalida.
--                Qiymat: `element_id`. 🔴 Mashina shu turdan.
--   'dropdown' — yengil ro'yxat: faqat matn variantlar, alohida jadval
--                YO'Q — `options->'variantlar'` (jsonb massiv) ichida.
--                Qiymat: `qiymat_matn` (variantlardan biri bo'lishi shart).
--   'matn'     — erkin matn (<= 1000 belgi).
--   'raqam'    — son (options->>'min' / 'max' bo'lsa tekshiriladi).
--   'sana'     — sana (YYYY-MM-DD).
--   Yangi tur qo'shish: CHECK ro'yxatiga + `entry_maydon_yoz` ichidagi
--   `case` ga bitta shox. Boshqa hech qayerga tegilmaydi.
--
-- =====================================================================
-- ADDITIVE KAFOLATI
-- ---------------------------------------------------------------------
--   * Mavjud BIRORTA jadval/ustun/funksiya/view O'ZGARTIRILMAYDI.
--     `entry`, `entry_line`, `accounts`, `user_perms` — tegilmagan.
--   * `jurnal_v2` / `jurnal_v2_count` / `jurnal_dash` / `jurnal()` —
--     TEGILMAGAN (endigina RUN qilingan, imzosi barqaror qolishi kerak).
--     Jurnal maydon qiymatlarini ALOHIDA yengil chaqiruv bilan oladi
--     (`v_entry_maydon` yoki `entry_maydonlar(uuid[])` — `refreshCheks`/
--     `refreshTlm`/`refreshMeta` naqshi).
--   * Hamma obyekt YANGI, ya'ni bu faylda IMZO O'ZGARISHI YO'Q va shuning
--     uchun `drop function` ham yo'q. ⚠️ Kelajakda imzo o'zgarsa —
--     `drop function ...` AYNAN o'sha `create` ning BEVOSITA USTIDA
--     tursin (42P13). Diqqat: `xm_entry_yoz_ok()` va `xm_maydon_entry_mos()`
--     ga RLS policy'lari BOG'LANGAN — ularni drop qilishdan oldin
--     policy'lar o'chirilishi kerak (ROLLBACK bo'limiga qara).
--   * `do $` bloki YO'Q (Supabase editorida 42P01 beradi).
--   * Faylda RPC ni JONLI chaqiradigan operator YO'Q — butun fayl BITTA
--     tranzaksiya, editorda `auth.uid()` null bo'lgani uchun har qanday
--     qorovulli chaqiruv 42501 berib BUTUN faylni orqaga qaytarardi
--     (PROVODKA_JURNAL_V2.sql shundan yiqilgan edi). Tekshiruv — faqat
--     KATALOG so'rovlari.
--   * Idempotent: bir necha marta RUN qilish xavfsiz.
--
-- RUN TARTIBI (Asilbek, Supabase SQL editor):
--   0) Old shart (bazada bo'lishi kerak — 0-BO'LIM buni ko'rsatadi):
--        PROVODKA_PERMS.sql  → is_admin(), user_perms, perm_check_accounts()
--        PROVODKA_V8.sql     → perm_view_pul_ids()   (1-BOSQICH bo'limi)
--        PROVODKA_PAGES_EMPTY.sql → perm_has_page()  — SHART EMAS (dinamik)
--   1) Shu faylni BUTUNLIGICHA nusxalab RUN qiling (bo'lib emas).
--   2) Oxiridagi TEKSHIRUV natijalari kutilgan qiymatni bersin.
--   3) Rasm kerak bo'lsa — 8-BO'LIM (Storage bucket) ni bajaring.
--   4) 🔴 SEED (9-BO'LIM) — 2-BOSQICH. U ATAYLAB izohda. Universal tizim
--      ishlayotganiga ishonch hosil qilgach, o'sha blokni izohdan chiqarib
--      ALOHIDA RUN qiling.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART DIAGNOSTIKASI (faqat ko'rish)              ##
-- #####################################################################
-- Hamma ustun `true` bo'lishi kerak (perm_has_page dan tashqari — u
-- ixtiyoriy, false bo'lsa ham fayl to'liq ishlaydi).

select to_regprocedure('public.is_admin()')                  is not null as is_admin_bor,
       to_regprocedure('public.perm_check_accounts(uuid[])')  is not null as perm_check_accounts_bor,
       to_regprocedure('public.perm_view_pul_ids()')          is not null as perm_view_pul_ids_bor,
       to_regclass('public.user_perms')                       is not null as user_perms_bor,
       to_regclass('public.entry')                            is not null as entry_bor,
       to_regclass('public.entry_line')                       is not null as entry_line_bor,
       to_regprocedure('public.gen_random_uuid()')            is not null as gen_random_uuid_bor,
       to_regprocedure('public.perm_has_page(text)')          is not null as perm_has_page_ixtiyoriy;

-- Nechta xarajat moddasi bor (maydon biriktiriladigan hisoblar)
select count(*)::int as xarajat_moddalari
  from accounts where type = 'xarajat';


-- #####################################################################
-- ##  1-BO'LIM — JADVALLAR                                            ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 1.1 xarajat_maydon — maydon TA'RIFI
-- ---------------------------------------------------------------------
create table if not exists xarajat_maydon (
  id          uuid        primary key default gen_random_uuid(),
  nom         text        not null,
  maydon_turi text        not null default 'royxat',
  required    boolean     not null default false,   -- sukut (biriktirishda ustidan yozish mumkin)
  tartib      int         not null default 0,
  options     jsonb       not null default '{}'::jsonb,
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now()
);

-- CHECK'lar alohida (jadval `if not exists` bilan yaratilgani uchun —
-- eski bazada jadval bor bo'lsa cheklov baribir qo'shilsin).
alter table xarajat_maydon
  drop constraint if exists xarajat_maydon_turi_chk;
alter table xarajat_maydon
  add constraint xarajat_maydon_turi_chk
  check (maydon_turi in ('royxat','dropdown','matn','raqam','sana'));

alter table xarajat_maydon
  drop constraint if exists xarajat_maydon_nom_chk;
alter table xarajat_maydon
  add constraint xarajat_maydon_nom_chk
  check (btrim(coalesce(nom,'')) <> '' and char_length(nom) <= 120);

alter table xarajat_maydon
  drop constraint if exists xarajat_maydon_options_chk;
alter table xarajat_maydon
  add constraint xarajat_maydon_options_chk
  check (jsonb_typeof(options) = 'object');

-- Bir xil nomli IKKI FAOL maydon bo'lmasin (ta'rif umumiy — nom o'ziga xos).
-- Partial: o'chirilgan (is_active=false) nom qayta ishlatilishi mumkin.
create unique index if not exists xarajat_maydon_nom_uq
  on xarajat_maydon (lower(btrim(nom))) where is_active;

comment on table xarajat_maydon is
  'Xarajat moddasiga biriktiriladigan MAXSUS MAYDON tarifi (universal konstruktor). '
  'Moddaga bogliq EMAS — bogliqlik xarajat_maydon_modda jadvalida (N:M). '
  'Yozish faqat admin RPC orqali (RLSda yozish policysi YOQ).';
comment on column xarajat_maydon.maydon_turi is
  'royxat (rasmli variantlar, xarajat_royxat_element) | dropdown (options->variantlar) | matn | raqam | sana.';
comment on column xarajat_maydon.options is
  'Turga qarab: dropdown -> {"variantlar":["A","B"]}; raqam -> {"min":0,"max":100}; '
  'ixtiyoriy UI kalitlari: {"placeholder":"...","yordam":"..."}. Har doim jsonb OBYEKT.';
comment on column xarajat_maydon.required is
  'Sukut majburiylik. Amaldagi qiymat = coalesce(xarajat_maydon_modda.required, shu ustun).';

-- ---------------------------------------------------------------------
-- 1.2 xarajat_maydon_modda — ta'rif ↔ xarajat moddasi (N:M)
-- ---------------------------------------------------------------------
create table if not exists xarajat_maydon_modda (
  maydon_id  uuid        not null references xarajat_maydon(id) on delete cascade,
  modda_id   uuid        not null references accounts(id)       on delete cascade,
  required   boolean,                                  -- null = tarifdagi qiymat
  created_at timestamptz not null default now(),
  primary key (maydon_id, modda_id)
);

create index if not exists xarajat_maydon_modda_modda_idx
  on xarajat_maydon_modda (modda_id);

comment on table xarajat_maydon_modda is
  'Maydon tarifi qaysi xarajat moddalariga biriktirilgan (N:M). '
  'Biriktirishni olib tashlash = qatorni ochirish; YOZILGAN QIYMATLAR (entry_maydon) TEGILMAYDI.';
comment on column xarajat_maydon_modda.required is
  'Shu moddada majburiylikni ustidan yozish. null = xarajat_maydon.required.';

-- ---------------------------------------------------------------------
-- 1.3 xarajat_royxat_element — "ro'yxatdan tanlash" variantlari
-- ---------------------------------------------------------------------
-- 🔴 Bu jadval MASHINA jadvali EMAS — u har qanday "ro'yxat" maydonining
--    variantlari (mashina / obyekt / ta'minotchi / stanok …).
--    `nom` — ko'rinadigan nom, `qiymat` — qo'shimcha belgi (mashinada
--    davlat raqami, obyektda kod …), `rasm_url` — IXTIYORIY.
create table if not exists xarajat_royxat_element (
  id         uuid        primary key default gen_random_uuid(),
  maydon_id  uuid        not null references xarajat_maydon(id) on delete cascade,
  nom        text        not null,
  qiymat     text,
  rasm_url   text,
  tartib     int         not null default 0,
  is_active  boolean     not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now()
);

alter table xarajat_royxat_element
  drop constraint if exists xarajat_element_nom_chk;
alter table xarajat_royxat_element
  add constraint xarajat_element_nom_chk
  check (btrim(coalesce(nom,'')) <> '' and char_length(nom) <= 120
         and (qiymat is null or char_length(qiymat) <= 120));

-- 🔴 XAVFSIZLIK: rasm_url klientda <img src> ga tushadi. Faqat ikki shakl:
--    (a) to'liq https havola  (Storage getPublicUrl natijasi)
--    (b) bucket ichidagi nisbiy yo'l: "maydon_id/element_id.jpg"
--    'javascript:' / 'data:' / 'http:' — CHEKLOV BILAN RAD ETILADI.
alter table xarajat_royxat_element
  drop constraint if exists xarajat_element_rasm_chk;
alter table xarajat_royxat_element
  add constraint xarajat_element_rasm_chk
  check (rasm_url is null
         or (char_length(rasm_url) <= 1000
             and (rasm_url ~ '^https://[^[:space:]]+$'
                  or rasm_url ~ '^[A-Za-z0-9._/-]+$')));

create index if not exists xarajat_element_maydon_idx
  on xarajat_royxat_element (maydon_id);

create unique index if not exists xarajat_element_nom_uq
  on xarajat_royxat_element (maydon_id, lower(btrim(nom)), lower(btrim(coalesce(qiymat,''))))
  where is_active;

comment on table xarajat_royxat_element is
  'maydon_turi=royxat uchun variantlar: nom + qiymat (masalan qoshimcha belgi) + IXTIYORIY rasm. '
  'Rasm bolmasa klient nom + qiymat korsatadi. Yozish faqat admin RPC orqali.';
comment on column xarajat_royxat_element.rasm_url is
  'Toliq https havola (Storage getPublicUrl) YOKI bucket ichidagi nisbiy yol "maydon_id/element_id.jpg". '
  'Bucket: xarajat-maydon (8-BOLIM). Bosh bolsa nom + qiymat korsatiladi.';

-- ---------------------------------------------------------------------
-- 1.4 entry_maydon — YOZUVDAGI QIYMAT
-- ---------------------------------------------------------------------
create table if not exists entry_maydon (
  entry_id    uuid        not null references entry(id)                 on delete cascade,
  maydon_id   uuid        not null references xarajat_maydon(id)        on delete restrict,
  element_id  uuid                 references xarajat_royxat_element(id) on delete restrict,
  qiymat_matn text,
  created_at  timestamptz not null default now(),
  created_by  uuid        default auth.uid(),
  primary key (entry_id, maydon_id)
);

-- Bo'sh qiymat saqlanmaydi: yo element, yo matn bo'lishi SHART.
alter table entry_maydon
  drop constraint if exists entry_maydon_qiymat_chk;
alter table entry_maydon
  add constraint entry_maydon_qiymat_chk
  check (element_id is not null
         or nullif(btrim(coalesce(qiymat_matn,'')), '') is not null);

alter table entry_maydon
  drop constraint if exists entry_maydon_matn_chk;
alter table entry_maydon
  add constraint entry_maydon_matn_chk
  check (qiymat_matn is null or char_length(qiymat_matn) <= 1000);

-- Hisobot/filtr uchun: "qaysi yozuvlarda shu element tanlangan"
create index if not exists entry_maydon_maydon_idx  on entry_maydon (maydon_id);
create index if not exists entry_maydon_element_idx on entry_maydon (element_id) where element_id is not null;

comment on table entry_maydon is
  'Provodka yozuvidagi maxsus maydon QIYMATI. royxat/dropdown -> element_id, qolgan turlar -> qiymat_matn. '
  'jsonb EMAS: filtr/hisobot JOIN bilan ishlasin va element_id haqiqiy FK bolsin (element nomi ozgarsa '
  'eski yozuvlar ham togri korinadi). ochirish = qatorni delete (yozuv metadatasi, pul emas).';
comment on column entry_maydon.element_id is
  'maydon_turi=royxat uchun tanlangan variant. Element keyin ochirilsa ham (is_active=false) korinish saqlanadi.';


-- #####################################################################
-- ##  2-BO'LIM — ICHKI QOROVULLAR (RLS va RPC lar shularga tayanadi)  ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 2.1 xm_page_ok(text) — SAHIFA QOROVULI (ICHKI)
-- ---------------------------------------------------------------------
-- `jurnal_page_ok()` ning AYNAN nusxasi (u esa `ai_ctx_has_page()` dan).
-- 🔴 Nega to'g'ridan `jurnal_page_ok()` chaqirilmadi: u boshqa faylda
--    (PROVODKA_JURNAL_V2.sql) va nomi "jurnal" ga bog'langan; bu fayl
--    o'zi mustaqil RUN bo'lishi kerak (bog'liqlik nol qoidasi).
-- Fail-closed:
--    auth.uid() null       -> false  (service_role/anon/SQL editor)
--    is_admin()            -> true
--    user_perms qatori yo'q-> false
--    allowed_pages da yo'q -> false
--    + perm_has_page() bo'lsa u ham rozi bo'lsin (IKKI tekshiruv AND).
-- ⚠️ `perm_has_page()` YOLG'IZ ishlatilmaydi: uning tanasida "kalit
--    perm_pages() da yo'q bo'lsa true" (fail-OPEN) shoxi bor.
create or replace function xm_page_ok(p_key text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid;
  v_pages text[];
  v_ok    boolean;
begin
  v_uid := auth.uid();
  if v_uid is null then return false; end if;
  if is_admin()     then return true;  end if;

  select allowed_pages into v_pages from user_perms where user_id = v_uid;
  if not found then return false; end if;
  if not (p_key = any(coalesce(v_pages, '{}'::text[]))) then return false; end if;

  if to_regprocedure('public.perm_has_page(text)') is not null then
    execute 'select public.perm_has_page($1)' into v_ok using p_key;
    return coalesce(v_ok, false);
  end if;

  return true;
end $fn$;

revoke all on function xm_page_ok(text) from public, anon, authenticated;

comment on function xm_page_ok(text) is
  'ICHKI: xarajat maydon RPClari uchun sahifa qorovuli (jurnal_page_ok naqshi, fail-closed). '
  'Faqat DEFINER funksiyalar ichidan chaqiriladi.';

-- ---------------------------------------------------------------------
-- 2.2 xm_admin_talab() — sozlama YOZUVI uchun qorovul (ICHKI)
-- ---------------------------------------------------------------------
-- Konstruktorni (maydon/element) FAQAT ADMIN o'zgartiradi.
-- Ikki qavat: is_admin() VA `sozlama` sahifasi ruxsati.
-- ⚠️ Hozir ikkinchi qavat ortiqchadek (xm_page_ok admin uchun darrov true
--    qaytaradi), lekin u ATAYLAB turibdi: agar ertaga "admin bo'lmagan
--    sozlamachi" paydo bo'lsa, qoida shu yerda bitta joyda o'zgaradi.
create or replace function xm_admin_talab()
returns void
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not is_admin() then
    raise exception 'Maxsus maydonlarni faqat admin sozlaydi' using errcode = '42501';
  end if;
  if not xm_page_ok('sozlama') then
    raise exception 'Sozlamalar sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;
end $fn$;

revoke all on function xm_admin_talab() from public, anon, authenticated;

comment on function xm_admin_talab() is
  'ICHKI: maxsus maydon konstruktorini ozgartirish qorovuli — is_admin() VA sozlama sahifasi ruxsati (42501).';

-- ---------------------------------------------------------------------
-- 2.3 xm_entry_yoz_ok(uuid) — YOZUVGA metadata yozish mumkinmi
-- ---------------------------------------------------------------------
-- 🔴 ENG MUHIM QOROVUL. `entry_maydon` — `entry` ga bog'liq metadata,
--    ya'ni `entry_line` ustidagi PUL GUARDI (trg_perm_guard_entry_line)
--    unga UMUMAN TEGMAYDI. Busiz har foydalanuvchi BEGONA yozuvga
--    "mashina: DAMAS" deb yozib qo'ya olardi (buxgalteriya metadatasini
--    soxtalashtirish).
--
-- FAIL-CLOSED, tartib muhim:
--   1) p_entry null / auth.uid() null            -> false
--   2) yozuv topilmadi                            -> false
--   3) yozuv O'CHIRILGAN (is_deleted)             -> false
--   4) is_admin()                                 -> true
--   5) BEGONA MUALLIF (created_by uuid va != men) -> false
--   6) PUL GUARDI: yozuvdagi hamma hisobda amaliyot ruxsati bo'lsin
--      (`perm_check_accounts` — entry_line triggeri bilan AYNAN bir xil
--      funksiya, ya'ni ikki joyda ikki xil qoida bo'lib qolmaydi)
--   7) satrsiz yozuv (hali entry_line yozilmagan) -> false
--
-- ⚠️ 5-BAND USTUN TURIGA BOG'LANMAYDI: `entry.created_by` repoda ba'zan
--    uuid, ba'zan matn ('aros_sync', 'tovar_sync') — PROVODKA_IJROCHI.sql
--    dagi `to_jsonb(e)->>'created_by'` naqshi ishlatiladi. Matn belgili
--    (sinxron yaratgan) yozuvda muallif tekshiruvi o'tkazib yuboriladi va
--    qaror 6-bandga (pul guardi) qoladi — u yozuvlarni odam yozmagan,
--    lekin ular foydalanuvchining O'Z kassasida bo'lishi mumkin.
--
-- 🔴 `entry_line` HALI YOZILMAGAN bo'lsa false qaytadi — ya'ni klient
--    tartibi MAJBURIY: entry -> entry_line -> entry_maydon.
create or replace function xm_entry_yoz_ok(p_entry uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_del boolean;
  v_raw text;
  v_ids uuid[];
begin
  if p_entry is null or v_uid is null then return false; end if;

  select coalesce(e.is_deleted, false), nullif(btrim(coalesce(to_jsonb(e) ->> 'created_by', '')), '')
    into v_del, v_raw
    from entry e where e.id = p_entry;
  if not found then return false; end if;
  if v_del     then return false; end if;

  if is_admin() then return true; end if;

  if v_raw is not null and v_raw ~ '^[0-9a-fA-F-]{36}$' then
    begin
      if v_raw::uuid is distinct from v_uid then return false; end if;
    exception when others then
      null;   -- buzuq uuid: qaror pul guardiga qoladi (22P02 bilan yiqilmaymiz)
    end;
  end if;

  select coalesce(array_agg(distinct l.account_id), '{}'::uuid[]) into v_ids
    from entry_line l where l.entry_id = p_entry;
  if array_length(v_ids, 1) is null then return false; end if;   -- satrsiz -> fail-closed

  return coalesce(perm_check_accounts(v_ids), false);
end $fn$;

revoke all on function xm_entry_yoz_ok(uuid) from public, anon;
-- 🔴 GRANT SHART: bu funksiya RLS POLICY ichida chaqiriladi, policy esa
--    chaqiruvchi (authenticated) huquqi bilan bajariladi. Sizadigan narsa
--    yo'q — javob faqat "MEN shu yozuvga yoza olamanmi" (o'z ruxsatim).
grant execute on function xm_entry_yoz_ok(uuid) to authenticated;

comment on function xm_entry_yoz_ok(uuid) is
  'Yozuvga maxsus maydon qiymatini yozish mumkinmi (fail-closed): ochirilmagan + (admin | muallif) + '
  'entry_line hisoblarida amaliyot ruxsati (perm_check_accounts — pul guardi bilan bir xil qoida). '
  'entry_maydon RLS policylari shunga tayanadi.';

-- ---------------------------------------------------------------------
-- 2.4 xm_maydon_entry_mos(uuid, uuid) — maydon shu yozuvga tegishlimi
-- ---------------------------------------------------------------------
-- Maydon qiymati FAQAT o'sha maydon biriktirilgan xarajat moddasiga
-- DEBET yozilgan yozuvga qo'yiladi. Ya'ni "Mashina" maydonini ijara
-- yozuviga yopishtirib bo'lmaydi — hisobot kesimlari chalkashmaydi.
-- Fail-closed: biriktirish olib tashlangan bo'lsa false.
create or replace function xm_maydon_entry_mos(p_entry uuid, p_maydon uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1
      from entry_line l
      join xarajat_maydon_modda mm on mm.modda_id = l.account_id
     where l.entry_id = p_entry
       and l.debit > 0
       and mm.maydon_id = p_maydon);
$fn$;

revoke all on function xm_maydon_entry_mos(uuid, uuid) from public, anon;
grant execute on function xm_maydon_entry_mos(uuid, uuid) to authenticated;   -- RLS policy ichida

comment on function xm_maydon_entry_mos(uuid, uuid) is
  'Maydon shu yozuvga mosmi: yozuvda maydon biriktirilgan xarajat moddasiga DEBET satri bormi (fail-closed).';

-- ---------------------------------------------------------------------
-- 2.5 xm_majburiy_yoq(uuid) — to'ldirilmagan MAJBURIY maydonlar nomi
-- ---------------------------------------------------------------------
-- `entry_maydon_yoz()` oxirida chaqiriladi. Bo'sh (null) = hammasi joyida.
-- ⚠️ DEFINER: `entry_line` ni ruxsatdan qat'i nazar o'qishi kerak, aks
--    holda cheklangan userda "majburiy maydon yo'q" degan SOXTA xato
--    chiqardi.
create or replace function xm_majburiy_yoq(p_entry uuid)
returns text
language sql
stable
security definer
set search_path = public
as $fn$
  select string_agg(m.nom, ', ' order by m.tartib, m.nom)
    from xarajat_maydon m
    join xarajat_maydon_modda mm on mm.maydon_id = m.id
   where m.is_active
     and coalesce(mm.required, m.required)
     and exists (select 1 from entry_line l
                  where l.entry_id = p_entry and l.account_id = mm.modda_id and l.debit > 0)
     and not exists (select 1 from entry_maydon em
                      where em.entry_id = p_entry and em.maydon_id = m.id);
$fn$;

revoke all on function xm_majburiy_yoq(uuid) from public, anon;
grant execute on function xm_majburiy_yoq(uuid) to authenticated;

comment on function xm_majburiy_yoq(uuid) is
  'Shu yozuv uchun toldirilmagan MAJBURIY maydon nomlari (vergul bilan) yoki null. '
  'Amaldagi majburiylik = coalesce(biriktirish.required, tarif.required).';


-- #####################################################################
-- ##  3-BO'LIM — RLS + POLICY                                         ##
-- #####################################################################
-- QOIDALAR (qisqacha):
--   KATALOG (xarajat_maydon, xarajat_maydon_modda, xarajat_royxat_element)
--     o'qish : authenticated — hammaga (bu maydon NOMLARI va variantlar
--              ro'yxati; pul emas, xarajat formasi ularsiz chizilmaydi).
--     yozish : POLICY UMUMAN YO'Q -> PostgREST orqali insert/update/delete
--              MUMKIN EMAS. Yagona yo'l — 4-BO'LIMdagi admin RPC lari
--              (`user_perms` dagi AYNAN shu naqsh).
--   QIYMAT (entry_maydon)
--     o'qish : jurnal ko'rinishi bilan bir xil qoida — `perm_view_pul_ids()`
--              null bo'lsa cheklovsiz, aks holda yozuvda ruxsat etilgan pul
--              hisobi qatnashgan bo'lsin (jurnal_v2_baza qoidasi).
--     yozish : `xm_entry_yoz_ok()` + maydon faol + element mos + modda mos.
-- ⚠️ TEZLIK: o'qish policy'sida `perm_view_pul_ids()` ATAYLAB
--    `(select ...)` ichida — CLAUDE.md dagi `(SELECT auth.uid())` naqshi.
--    Shunda u InitPlan bo'lib SO'ROVGA BIR MARTA hisoblanadi, har qatorga
--    emas (100 yozuvli jurnalda sezilarli farq).

alter table xarajat_maydon         enable row level security;
alter table xarajat_maydon_modda   enable row level security;
alter table xarajat_royxat_element enable row level security;
alter table entry_maydon           enable row level security;

-- --- katalog: faqat O'QISH policy'si ---
drop policy if exists xarajat_maydon_sel on xarajat_maydon;
create policy xarajat_maydon_sel on xarajat_maydon
  for select to authenticated using (true);

drop policy if exists xarajat_maydon_modda_sel on xarajat_maydon_modda;
create policy xarajat_maydon_modda_sel on xarajat_maydon_modda
  for select to authenticated using (true);

drop policy if exists xarajat_element_sel on xarajat_royxat_element;
create policy xarajat_element_sel on xarajat_royxat_element
  for select to authenticated using (true);

-- --- qiymat: 4 policy ---
drop policy if exists entry_maydon_sel on entry_maydon;
create policy entry_maydon_sel on entry_maydon
  for select to authenticated
  using (
    (select perm_view_pul_ids()) is null
    or exists (
      select 1 from entry_line l
       where l.entry_id = entry_maydon.entry_id
         and l.account_id = any((select perm_view_pul_ids())))
  );

drop policy if exists entry_maydon_ins on entry_maydon;
create policy entry_maydon_ins on entry_maydon
  for insert to authenticated
  with check (
    xm_entry_yoz_ok(entry_maydon.entry_id)
    and xm_maydon_entry_mos(entry_maydon.entry_id, entry_maydon.maydon_id)
    and exists (select 1 from xarajat_maydon m
                 where m.id = entry_maydon.maydon_id and m.is_active)
    and (entry_maydon.element_id is null
         or exists (select 1 from xarajat_royxat_element el
                     where el.id = entry_maydon.element_id
                       and el.maydon_id = entry_maydon.maydon_id
                       and el.is_active))
  );

drop policy if exists entry_maydon_upd on entry_maydon;
create policy entry_maydon_upd on entry_maydon
  for update to authenticated
  using (xm_entry_yoz_ok(entry_maydon.entry_id))
  with check (
    xm_entry_yoz_ok(entry_maydon.entry_id)
    and xm_maydon_entry_mos(entry_maydon.entry_id, entry_maydon.maydon_id)
    and exists (select 1 from xarajat_maydon m
                 where m.id = entry_maydon.maydon_id and m.is_active)
    and (entry_maydon.element_id is null
         or exists (select 1 from xarajat_royxat_element el
                     where el.id = entry_maydon.element_id
                       and el.maydon_id = entry_maydon.maydon_id
                       and el.is_active))
  );

drop policy if exists entry_maydon_del on entry_maydon;
create policy entry_maydon_del on entry_maydon
  for delete to authenticated
  using (xm_entry_yoz_ok(entry_maydon.entry_id));

-- --- GRANT (policy'ning o'zi yetarli emas — jadval huquqi ham kerak) ---
revoke all on xarajat_maydon         from public, anon;
revoke all on xarajat_maydon_modda   from public, anon;
revoke all on xarajat_royxat_element from public, anon;
revoke all on entry_maydon           from public, anon;

grant select on xarajat_maydon         to authenticated;
grant select on xarajat_maydon_modda   to authenticated;
grant select on xarajat_royxat_element to authenticated;
grant select, insert, update, delete on entry_maydon to authenticated;


-- #####################################################################
-- ##  4-BO'LIM — SOZLAMA RPC LARI (KONSTRUKTOR, faqat admin)          ##
-- #####################################################################
-- Hammasi: security definer + set search_path + xm_admin_talab() + revoke.
-- 🔴 Universal: birorta funksiya "mashina" haqida hech narsa bilmaydi.

-- ---------------------------------------------------------------------
-- 4.1 xarajat_maydon_yarat — yangi maydon ta'rifi (+ ixtiyoriy biriktirish)
-- ---------------------------------------------------------------------
create or replace function xarajat_maydon_yarat(
  p_nom      text,
  p_turi     text    default 'royxat',
  p_required boolean default false,
  p_tartib   int     default 0,
  p_options  jsonb   default '{}'::jsonb,
  p_moddalar uuid[]  default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_id  uuid;
  v_nom text := nullif(btrim(coalesce(p_nom, '')), '');
  v_bad int;
begin
  perform xm_admin_talab();

  if v_nom is null then
    raise exception 'Maydon nomi kerak' using errcode = '22000';
  end if;
  if p_turi is null or p_turi not in ('royxat','dropdown','matn','raqam','sana') then
    raise exception 'Nomalum maydon turi: %', coalesce(p_turi, '(bosh)') using errcode = '22000';
  end if;
  if p_options is not null and jsonb_typeof(p_options) <> 'object' then
    raise exception 'options jsonb OBYEKT bolishi kerak' using errcode = '22000';
  end if;

  -- Biriktiriladigan hisoblar HAQIQATAN xarajat moddasi bo'lsin
  if p_moddalar is not null and array_length(p_moddalar, 1) is not null then
    select count(*)::int into v_bad
      from unnest(p_moddalar) as x(id)
     where not exists (select 1 from accounts a where a.id = x.id and a.type = 'xarajat');
    if v_bad > 0 then
      raise exception '% ta hisob xarajat moddasi emas', v_bad using errcode = '22000';
    end if;
  end if;

  begin
    insert into xarajat_maydon(nom, maydon_turi, required, tartib, options, created_by)
    values (v_nom, p_turi, coalesce(p_required, false), coalesce(p_tartib, 0),
            coalesce(p_options, '{}'::jsonb), auth.uid())
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Bu nomli maydon allaqachon bor: %', v_nom using errcode = '23505';
  end;

  if p_moddalar is not null then
    insert into xarajat_maydon_modda(maydon_id, modda_id)
    select v_id, x.id from unnest(p_moddalar) as x(id)
    on conflict (maydon_id, modda_id) do nothing;
  end if;

  return v_id;
end $fn$;

revoke all on function xarajat_maydon_yarat(text, text, boolean, int, jsonb, uuid[]) from public, anon;
grant execute on function xarajat_maydon_yarat(text, text, boolean, int, jsonb, uuid[]) to authenticated;

comment on function xarajat_maydon_yarat(text, text, boolean, int, jsonb, uuid[]) is
  'Admin: yangi maxsus maydon tarifi (+ ixtiyoriy p_moddalar biriktirish). Qaytishi — maydon id. '
  'Turlar: royxat|dropdown|matn|raqam|sana.';

-- ---------------------------------------------------------------------
-- 4.2 xarajat_maydon_tahrir — nom / majburiylik / tartib / options
-- ---------------------------------------------------------------------
-- 🔴 `maydon_turi` ATAYLAB O'ZGARTIRILMAYDI: qiymatlar allaqachon
--    yozilgan bo'lishi mumkin (element_id yoki matn) va tur almashsa eski
--    qiymatlar ma'nosini yo'qotardi. Kerak bo'lsa: eskisini o'chirib
--    (soft) yangisini yaratish — tarix buzilmaydi.
-- null argument = TEGILMAYDI.
create or replace function xarajat_maydon_tahrir(
  p_id       uuid,
  p_nom      text    default null,
  p_required boolean default null,
  p_tartib   int     default null,
  p_options  jsonb   default null)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare v_nom text := nullif(btrim(coalesce(p_nom, '')), '');
begin
  perform xm_admin_talab();

  if p_id is null then
    raise exception 'Maydon tanlanmadi' using errcode = '22000';
  end if;
  if p_nom is not null and v_nom is null then
    raise exception 'Maydon nomi bosh bololmaydi' using errcode = '22000';
  end if;
  if p_options is not null and jsonb_typeof(p_options) <> 'object' then
    raise exception 'options jsonb OBYEKT bolishi kerak' using errcode = '22000';
  end if;

  begin
    update xarajat_maydon
       set nom        = coalesce(v_nom, nom),
           required   = coalesce(p_required, required),
           tartib     = coalesce(p_tartib, tartib),
           options    = coalesce(p_options, options),
           updated_at = now()
     where id = p_id;
  exception when unique_violation then
    raise exception 'Bu nomli maydon allaqachon bor: %', v_nom using errcode = '23505';
  end;

  if not found then
    raise exception 'Maydon topilmadi' using errcode = '22000';
  end if;
end $fn$;

revoke all on function xarajat_maydon_tahrir(uuid, text, boolean, int, jsonb) from public, anon;
grant execute on function xarajat_maydon_tahrir(uuid, text, boolean, int, jsonb) to authenticated;

comment on function xarajat_maydon_tahrir(uuid, text, boolean, int, jsonb) is
  'Admin: maydon tarifini tahrirlash (null argument = tegilmaydi). maydon_turi ATAYLAB ozgarmaydi — '
  'yozilgan qiymatlar manosini yoqotmasin.';

-- ---------------------------------------------------------------------
-- 4.3 xarajat_maydon_ochir — SOFT (o'chirish/tiklash)
-- ---------------------------------------------------------------------
-- 🔴 Hech narsa fizik o'chirilmaydi (CLAUDE.md: "Hech narsa o'chirilmaydi").
--    Yozilgan qiymatlar (entry_maydon) TEGILMAYDI — jurnalda ko'rinaveradi.
create or replace function xarajat_maydon_ochir(p_id uuid, p_ochirilsin boolean default true)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  perform xm_admin_talab();
  if p_id is null then
    raise exception 'Maydon tanlanmadi' using errcode = '22000';
  end if;

  update xarajat_maydon
     set is_active = not coalesce(p_ochirilsin, true), updated_at = now()
   where id = p_id;

  if not found then
    raise exception 'Maydon topilmadi' using errcode = '22000';
  end if;
end $fn$;

revoke all on function xarajat_maydon_ochir(uuid, boolean) from public, anon;
grant execute on function xarajat_maydon_ochir(uuid, boolean) to authenticated;

comment on function xarajat_maydon_ochir(uuid, boolean) is
  'Admin: maydonni SOFT ochirish (is_active=false) yoki tiklash (p_ochirilsin=false). '
  'Yozilgan qiymatlar (entry_maydon) tegilmaydi.';

-- ---------------------------------------------------------------------
-- 4.4 xarajat_maydon_biriktir — maydon <-> xarajat moddasi
-- ---------------------------------------------------------------------
create or replace function xarajat_maydon_biriktir(
  p_maydon   uuid,
  p_modda    uuid,
  p_on       boolean default true,
  p_required boolean default null)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare v_type text;
begin
  perform xm_admin_talab();

  if p_maydon is null or p_modda is null then
    raise exception 'Maydon yoki xarajat moddasi tanlanmadi' using errcode = '22000';
  end if;
  if not exists (select 1 from xarajat_maydon where id = p_maydon) then
    raise exception 'Maydon topilmadi' using errcode = '22000';
  end if;

  select a.type into v_type from accounts a where a.id = p_modda;
  if v_type is distinct from 'xarajat' then
    raise exception 'Tanlangan hisob xarajat moddasi emas' using errcode = '22000';
  end if;

  if coalesce(p_on, true) then
    insert into xarajat_maydon_modda(maydon_id, modda_id, required)
    values (p_maydon, p_modda, p_required)
    on conflict (maydon_id, modda_id) do update set required = excluded.required;
  else
    -- 🔴 Biriktirish olib tashlansa YOZILGAN QIYMATLAR O'CHIRILMAYDI —
    --    ular tarix (jurnalda ko'rinishi kerak).
    delete from xarajat_maydon_modda where maydon_id = p_maydon and modda_id = p_modda;
  end if;
end $fn$;

revoke all on function xarajat_maydon_biriktir(uuid, uuid, boolean, boolean) from public, anon;
grant execute on function xarajat_maydon_biriktir(uuid, uuid, boolean, boolean) to authenticated;

comment on function xarajat_maydon_biriktir(uuid, uuid, boolean, boolean) is
  'Admin: maydonni xarajat moddasiga biriktiradi (p_on=false — biriktirishni oladi). '
  'p_required — shu moddadagi majburiylik (null = tarifdagi qiymat). Yozilgan qiymatlar tegilmaydi.';

-- ---------------------------------------------------------------------
-- 4.5 xarajat_element_yarat — "ro'yxat" maydoniga variant
-- ---------------------------------------------------------------------
create or replace function xarajat_element_yarat(
  p_maydon   uuid,
  p_nom      text,
  p_qiymat   text default null,
  p_rasm_url text default null,
  p_tartib   int  default 0)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_id   uuid;
  v_turi text;
  v_nom  text := nullif(btrim(coalesce(p_nom, '')), '');
begin
  perform xm_admin_talab();

  if v_nom is null then
    raise exception 'Element nomi kerak' using errcode = '22000';
  end if;

  select maydon_turi into v_turi from xarajat_maydon where id = p_maydon;
  if v_turi is null then
    raise exception 'Maydon topilmadi' using errcode = '22000';
  end if;
  if v_turi <> 'royxat' then
    raise exception 'Elementlar faqat "royxat" turidagi maydonga qoshiladi (bu maydon: %)', v_turi
      using errcode = '22000';
  end if;

  begin
    insert into xarajat_royxat_element(maydon_id, nom, qiymat, rasm_url, tartib, created_by)
    values (p_maydon, v_nom,
            nullif(btrim(coalesce(p_qiymat, '')), ''),
            nullif(btrim(coalesce(p_rasm_url, '')), ''),
            coalesce(p_tartib, 0), auth.uid())
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Bu element allaqachon bor: %', v_nom using errcode = '23505';
  end;

  return v_id;
end $fn$;

revoke all on function xarajat_element_yarat(uuid, text, text, text, int) from public, anon;
grant execute on function xarajat_element_yarat(uuid, text, text, text, int) to authenticated;

comment on function xarajat_element_yarat(uuid, text, text, text, int) is
  'Admin: royxat maydoniga variant qoshadi (nom + ixtiyoriy qiymat + ixtiyoriy rasm_url). Qaytishi — element id. '
  'Rasm odatda element YARATILGACH yuklanadi va xarajat_element_tahrir bilan yoziladi.';

-- ---------------------------------------------------------------------
-- 4.6 xarajat_element_tahrir
-- ---------------------------------------------------------------------
-- ⚠️ KELISHUV: null = TEGILMAYDI, bo'sh matn ('') = TOZALASH.
--    (`p_qiymat` va `p_rasm_url` uchun. `p_nom` bo'sh bo'lolmaydi.)
create or replace function xarajat_element_tahrir(
  p_id       uuid,
  p_nom      text default null,
  p_qiymat   text default null,
  p_rasm_url text default null,
  p_tartib   int  default null)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare v_nom text := nullif(btrim(coalesce(p_nom, '')), '');
begin
  perform xm_admin_talab();

  if p_id is null then
    raise exception 'Element tanlanmadi' using errcode = '22000';
  end if;
  if p_nom is not null and v_nom is null then
    raise exception 'Element nomi bosh bololmaydi' using errcode = '22000';
  end if;

  begin
    update xarajat_royxat_element
       set nom        = coalesce(v_nom, nom),
           qiymat     = case when p_qiymat   is null then qiymat
                             else nullif(btrim(p_qiymat), '') end,
           rasm_url   = case when p_rasm_url is null then rasm_url
                             else nullif(btrim(p_rasm_url), '') end,
           tartib     = coalesce(p_tartib, tartib),
           updated_at = now()
     where id = p_id;
  exception when unique_violation then
    raise exception 'Bu element allaqachon bor: %', v_nom using errcode = '23505';
  end;

  if not found then
    raise exception 'Element topilmadi' using errcode = '22000';
  end if;
end $fn$;

revoke all on function xarajat_element_tahrir(uuid, text, text, text, int) from public, anon;
grant execute on function xarajat_element_tahrir(uuid, text, text, text, int) to authenticated;

comment on function xarajat_element_tahrir(uuid, text, text, text, int) is
  'Admin: element tahriri. null = tegilmaydi, BOSH MATN ('''') = tozalash (qiymat/rasm_url uchun).';

-- ---------------------------------------------------------------------
-- 4.7 xarajat_element_ochir — SOFT (o'chirish/tiklash)
-- ---------------------------------------------------------------------
-- O'chirilgan element yangi yozuvda TANLANMAYDI, lekin ESKI yozuvlarda
-- ko'rinishda qoladi (FK saqlanadi) — tarix buzilmaydi.
create or replace function xarajat_element_ochir(p_id uuid, p_ochirilsin boolean default true)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  perform xm_admin_talab();
  if p_id is null then
    raise exception 'Element tanlanmadi' using errcode = '22000';
  end if;

  update xarajat_royxat_element
     set is_active = not coalesce(p_ochirilsin, true), updated_at = now()
   where id = p_id;

  if not found then
    raise exception 'Element topilmadi' using errcode = '22000';
  end if;
end $fn$;

revoke all on function xarajat_element_ochir(uuid, boolean) from public, anon;
grant execute on function xarajat_element_ochir(uuid, boolean) to authenticated;

comment on function xarajat_element_ochir(uuid, boolean) is
  'Admin: elementni SOFT ochirish (is_active=false) yoki tiklash. Eski yozuvlarda korinish saqlanadi.';


-- #####################################################################
-- ##  5-BO'LIM — O'QISH RPC LARI                                      ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 5.1 xarajat_maydonlar(p_modda) — XARAJAT FORMASI uchun (BITTA chaqiruv)
-- ---------------------------------------------------------------------
-- Javob:
--   [ { "id":uuid, "nom":text, "maydon_turi":text, "required":bool,
--       "tartib":int, "options":jsonb,
--       "elementlar":[ {"id":uuid,"nom":text,"qiymat":text,
--                       "rasm_url":text,"tartib":int}, ... ] } ]
--   Maydon yo'q bo'lsa: []  (klient hech narsa chizmaydi — eski xatti-harakat)
--
-- 🔴 SECURITY INVOKER (definer EMAS, ataylab): jadval RLS'i o'zi filtrlaydi,
--    ya'ni ruxsat qoidasi BITTA joyda (policy) qoladi.
-- 🔴 SAHIFA QOROVULI YO'Q — ataylab: bu forma `hodim-dev.html` da
--    ishlatiladi, `hodim` esa `allowed_pages` ro'yxatiga UMUMAN kirmaydi
--    (CLAUDE.md: "hodim.html hech qachon cheklanmaydi"). Qorovul qo'yilsa
--    xarajat yozadigan 80% foydalanuvchida maydonlar chiqmay qolardi.
--    Sizadigan narsa: maydon nomlari + variantlar ro'yxati (pul emas).
create or replace function xarajat_maydonlar(p_modda uuid)
returns jsonb
language sql
stable
set search_path = public
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',          m.id,
           'nom',         m.nom,
           'maydon_turi', m.maydon_turi,
           'required',    coalesce(mm.required, m.required),
           'tartib',      m.tartib,
           'options',     m.options,
           'elementlar',  (select coalesce(jsonb_agg(jsonb_build_object(
                                    'id',       el.id,
                                    'nom',      el.nom,
                                    'qiymat',   el.qiymat,
                                    'rasm_url', el.rasm_url,
                                    'tartib',   el.tartib)
                                  order by el.tartib, el.nom), '[]'::jsonb)
                             from xarajat_royxat_element el
                            where el.maydon_id = m.id and el.is_active))
         order by m.tartib, m.nom), '[]'::jsonb)
    from xarajat_maydon m
    join xarajat_maydon_modda mm on mm.maydon_id = m.id
   where mm.modda_id = p_modda
     and m.is_active;
$fn$;

revoke all on function xarajat_maydonlar(uuid) from public, anon;
grant execute on function xarajat_maydonlar(uuid) to authenticated;

comment on function xarajat_maydonlar(uuid) is
  'Xarajat formasi uchun: shu moddaga biriktirilgan FAOL maydonlar + royxat elementlari (bitta chaqiruv, jsonb). '
  'required = coalesce(biriktirish.required, tarif.required). Maydon yoq bolsa [].';

-- ---------------------------------------------------------------------
-- 5.2 xarajat_maydon_sozlama(p_faqat_faol) — KONSTRUKTOR ro'yxati
-- ---------------------------------------------------------------------
-- Sozlamalar sahifasi uchun: hamma maydon + biriktirilgan moddalar +
-- elementlar (o'chirilganlari ham) + ishlatilgan yozuvlar soni.
-- Qorovul: xm_page_ok('sozlama') — o'qish uchun admin SHART EMAS
-- (yozish esa har doim admin — xm_admin_talab).
create or replace function xarajat_maydon_sozlama(p_faqat_faol boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_out jsonb;
begin
  if not xm_page_ok('sozlama') then
    raise exception 'Sozlamalar sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',          m.id,
           'nom',         m.nom,
           'maydon_turi', m.maydon_turi,
           'required',    m.required,
           'tartib',      m.tartib,
           'options',     m.options,
           'is_active',   m.is_active,
           'ishlatilgan', (select count(*)::int from entry_maydon em where em.maydon_id = m.id),
           'moddalar',    (select coalesce(jsonb_agg(jsonb_build_object(
                                    'modda_id', a.id,
                                    'code',     a.code,
                                    'name',     a.name,
                                    'required', coalesce(mm.required, m.required))
                                  order by a.code), '[]'::jsonb)
                             from xarajat_maydon_modda mm
                             join accounts a on a.id = mm.modda_id
                            where mm.maydon_id = m.id),
           'elementlar',  (select coalesce(jsonb_agg(jsonb_build_object(
                                    'id',        el.id,
                                    'nom',       el.nom,
                                    'qiymat',    el.qiymat,
                                    'rasm_url',  el.rasm_url,
                                    'tartib',    el.tartib,
                                    'is_active', el.is_active)
                                  order by el.tartib, el.nom), '[]'::jsonb)
                             from xarajat_royxat_element el
                            where el.maydon_id = m.id
                              and (not coalesce(p_faqat_faol, false) or el.is_active)))
         order by m.tartib, m.nom), '[]'::jsonb)
    into v_out
    from xarajat_maydon m
   where not coalesce(p_faqat_faol, false) or m.is_active;

  return coalesce(v_out, '[]'::jsonb);
end $fn$;

revoke all on function xarajat_maydon_sozlama(boolean) from public, anon;
grant execute on function xarajat_maydon_sozlama(boolean) to authenticated;

comment on function xarajat_maydon_sozlama(boolean) is
  'Sozlamalar: hamma maxsus maydon + biriktirilgan moddalar + elementlar + ishlatilgan yozuvlar soni. '
  'p_faqat_faol=true — ochirilganlarini korsatmaydi. Sahifa qorovuli: xm_page_ok(''sozlama'') (42501).';


-- #####################################################################
-- ##  6-BO'LIM — QIYMAT YOZISH: entry_maydon_yoz()                    ##
-- #####################################################################
-- Kirish:
--   p_entry     — yozuv id (entry_line ALLAQACHON yozilgan bo'lishi shart)
--   p_qiymatlar — jsonb MASSIV:
--       [ {"maydon_id":uuid, "element_id":uuid},          -- royxat
--         {"maydon_id":uuid, "qiymat":"..."} ,            -- dropdown/matn/raqam/sana
--         {"maydon_id":uuid} ]                            -- BO'SH = qiymatni O'CHIRISH
-- Javob: {"ok":true, "entry_id":uuid, "yozildi":int, "ochirildi":int}
--
-- 🔴 SECURITY INVOKER (definer EMAS) — ATAYLAB: yozuv RLS policy'laridan
--    O'TADI, ya'ni qorovul chetlab o'tilmaydi. Bu yerdagi tekshiruvlar
--    (tur/majburiylik/variant) — QO'SHIMCHA qatlam va odam tilidagi xato
--    matni uchun; ular bo'lmasa ham RLS begona yozuvni to'sadi.
-- 🔴 MAJBURIYLIK TRIGGER BILAN MAJBURLANMAYDI (ongli qaror): qiymat
--    yozuvdan KEYIN yoziladi (entry insert paytida hali yo'q), shuning
--    uchun `entry` ustidagi trigger har provodkani yiqitardi. Majburiylik
--    shu RPC da + UI da tekshiriladi.
create or replace function entry_maydon_yoz(p_entry uuid, p_qiymatlar jsonb)
returns jsonb
language plpgsql
set search_path = public
as $fn$
declare
  r        jsonb;
  v_mid    uuid;
  v_eid    uuid;
  v_raw    text;
  v_re     text;
  v_q      text;
  v_turi   text;
  v_nom    text;
  v_opt    jsonb;
  v_min    numeric;
  v_max    numeric;
  v_num    numeric;
  v_dat    date;
  v_yoz    int := 0;
  v_och    int := 0;
  v_yoq    text;
begin
  if p_entry is null then
    raise exception 'Yozuv tanlanmadi' using errcode = '22000';
  end if;
  if p_qiymatlar is null or jsonb_typeof(p_qiymatlar) <> 'array' then
    raise exception 'p_qiymatlar jsonb MASSIV bolishi kerak' using errcode = '22000';
  end if;

  -- 🔴 QOROVUL (odam tilidagi xato uchun; RLS baribir ikkinchi qavat)
  if not xm_entry_yoz_ok(p_entry) then
    raise exception 'Bu yozuvga maxsus maydon qiymatini yozish huquqingiz yo''q'
      using errcode = '42501';
  end if;

  -- ⚠️ `from jsonb_array_elements(...)` shaklida (select ro'yxatida SRF emas) —
  --    eski uslub qo'llab-quvvatlanadi, lekin bu shakl aniq va barqaror.
  for r in select t.value from jsonb_array_elements(p_qiymatlar) as t(value) loop
    v_raw := nullif(btrim(coalesce(r ->> 'maydon_id', '')), '');
    v_re  := nullif(btrim(coalesce(r ->> 'element_id', '')), '');
    v_q   := nullif(btrim(coalesce(r ->> 'qiymat', '')), '');

    -- 🔴 uuid SHAKLI avval tekshiriladi, keyin cast — buzuq qiymat 22P02
    --    bilan yiqilmasin, o'zbekcha xato chiqsin (ijrochi_nomi naqshi).
    if v_raw is null or v_raw !~ '^[0-9a-fA-F-]{36}$' then
      raise exception 'maydon_id berilmadi yoki notogri' using errcode = '22000';
    end if;
    if v_re is not null and v_re !~ '^[0-9a-fA-F-]{36}$' then
      raise exception 'element_id notogri' using errcode = '22000';
    end if;
    v_mid := v_raw::uuid;
    v_eid := v_re::uuid;

    select m.maydon_turi, m.nom, m.options into v_turi, v_nom, v_opt
      from xarajat_maydon m where m.id = v_mid and m.is_active;
    if v_turi is null then
      raise exception 'Maydon topilmadi yoki ochirilgan' using errcode = '22000';
    end if;

    if not xm_maydon_entry_mos(p_entry, v_mid) then
      raise exception '"%" maydoni bu xarajat moddasiga biriktirilmagan', v_nom
        using errcode = '22000';
    end if;

    -- BO'SH kelgan qiymat = O'CHIRISH
    if v_eid is null and v_q is null then
      delete from entry_maydon where entry_id = p_entry and maydon_id = v_mid;
      if found then v_och := v_och + 1; end if;
      continue;
    end if;

    -- Turga qarab tekshiruv. 🔴 Yangi tur qo'shilsa — SHU case ga bitta shox.
    case v_turi
      when 'royxat' then
        if v_eid is null then
          raise exception '"%" uchun royxatdan variant tanlang', v_nom using errcode = '22000';
        end if;
        if not exists (select 1 from xarajat_royxat_element el
                        where el.id = v_eid and el.maydon_id = v_mid and el.is_active) then
          raise exception '"%" uchun tanlangan variant notogri yoki ochirilgan', v_nom
            using errcode = '22000';
        end if;
        v_q := null;                      -- normallashtirish: qiymat element_id da

      when 'dropdown' then
        v_eid := null;
        if v_q is null then
          raise exception '"%" uchun qiymat tanlang', v_nom using errcode = '22000';
        end if;
        if jsonb_typeof(coalesce(v_opt -> 'variantlar', 'null'::jsonb)) = 'array'
           and jsonb_array_length(v_opt -> 'variantlar') > 0
           and not exists (select 1 from jsonb_array_elements_text(v_opt -> 'variantlar') as t(x)
                            where btrim(t.x) = v_q) then
          raise exception '"%" uchun notogri variant: %', v_nom, v_q using errcode = '22000';
        end if;

      when 'raqam' then
        v_eid := null;
        begin
          v_num := replace(v_q, ' ', '')::numeric;
        exception when others then
          raise exception '"%" son bolishi kerak: %', v_nom, v_q using errcode = '22000';
        end;
        -- ⚠️ options ADMIN yozadigan erkin jsonb — ichida "min":"abc" bo'lib
        --    qolsa cast 22P02 berib butun saqlashni yiqitardi. Buzuq chegara
        --    JIM o'tkazib yuboriladi (chegara yo'q deb hisoblanadi).
        begin
          v_min := nullif(v_opt ->> 'min', '')::numeric;
          v_max := nullif(v_opt ->> 'max', '')::numeric;
        exception when others then
          v_min := null; v_max := null;
        end;
        if v_min is not null and v_num < v_min then
          raise exception '"%" % dan kichik bololmaydi', v_nom, v_min using errcode = '22000';
        end if;
        if v_max is not null and v_num > v_max then
          raise exception '"%" % dan katta bololmaydi', v_nom, v_max using errcode = '22000';
        end if;
        v_q := v_num::text;

      when 'sana' then
        v_eid := null;
        begin
          v_dat := v_q::date;
        exception when others then
          raise exception '"%" sana bolishi kerak (YYYY-MM-DD): %', v_nom, v_q using errcode = '22000';
        end;
        v_q := v_dat::text;

      else   -- 'matn'
        v_eid := null;
        if char_length(v_q) > 1000 then
          raise exception '"%" juda uzun (1000 belgidan kop)', v_nom using errcode = '22000';
        end if;
    end case;

    insert into entry_maydon(entry_id, maydon_id, element_id, qiymat_matn)
    values (p_entry, v_mid, v_eid, v_q)
    on conflict (entry_id, maydon_id) do update
       set element_id  = excluded.element_id,
           qiymat_matn = excluded.qiymat_matn;

    v_yoz := v_yoz + 1;
  end loop;

  -- 🔴 MAJBURIY maydonlar to'ldirilganmi (fail-closed, oxirida — chunki
  --    ular shu chaqiruv ichida to'lgan bo'lishi mumkin).
  v_yoq := xm_majburiy_yoq(p_entry);
  if v_yoq is not null then
    raise exception 'Majburiy maydon toldirilmadi: %', v_yoq using errcode = '22000';
  end if;

  return jsonb_build_object('ok', true, 'entry_id', p_entry,
                            'yozildi', v_yoz, 'ochirildi', v_och);
end $fn$;

revoke all on function entry_maydon_yoz(uuid, jsonb) from public, anon;
grant execute on function entry_maydon_yoz(uuid, jsonb) to authenticated;

comment on function entry_maydon_yoz(uuid, jsonb) is
  'Yozuvga maxsus maydon qiymatlarini yozadi (upsert). p_qiymatlar: [{maydon_id, element_id|qiymat}]; '
  'bosh qiymat = ochirish. SECURITY INVOKER — entry_maydon RLS policylaridan otadi (qorovul chetlanmaydi). '
  'Turga qarab tekshiradi + majburiy maydonlarni talab qiladi (42501 = ruxsat yoq, 22000 = notogri malumot).';


-- #####################################################################
-- ##  7-BO'LIM — JURNAL / HISOBOT KO'RINISHI                          ##
-- #####################################################################
-- 🔴 `jurnal_v2` TEGILMAYDI (imzosi barqaror qolsin). Klient maydon
--    qiymatlarini ALOHIDA yengil chaqiruv bilan oladi — `refreshCheks` /
--    `refreshTlm` / `refreshMeta` naqshi (id ro'yxati -> map).

-- ---------------------------------------------------------------------
-- 7.1 v_entry_maydon — `.in('entry_id', ids)` uchun (refreshMeta naqshi)
-- ---------------------------------------------------------------------
-- 🔴 security_invoker = on -> `entry_maydon` RLS'i o'zi ishlaydi
--    (cheklangan user begona yozuv metadatasini KO'RMAYDI).
-- `korinish` — TAYYOR ko'rsatiladigan matn (universal, turdan qat'i nazar):
--    element bo'lsa "nom qiymat" (masalan "DAMAS 01O244RB"), aks holda matn.
--    Klient shuni chizadi; rasm bo'lsa `rasm_url` bilan kichik surat.
drop view if exists v_entry_maydon;
create view v_entry_maydon
with (security_invoker = on)
as
select em.entry_id,
       em.maydon_id,
       m.nom          as maydon_nom,
       m.maydon_turi,
       m.tartib,
       em.element_id,
       el.nom         as element_nom,
       el.qiymat      as element_qiymat,
       el.rasm_url,
       em.qiymat_matn,
       coalesce(
         nullif(btrim(coalesce(el.nom, '') ||
                      coalesce(' ' || nullif(btrim(coalesce(el.qiymat, '')), ''), '')), ''),
         nullif(btrim(coalesce(em.qiymat_matn, '')), '')
       )              as korinish,
       em.created_at
  from entry_maydon em
  join xarajat_maydon m            on m.id  = em.maydon_id
  left join xarajat_royxat_element el on el.id = em.element_id;

revoke all on v_entry_maydon from public, anon;
grant select on v_entry_maydon to authenticated;

comment on view v_entry_maydon is
  'Yozuvlarning maxsus maydon qiymatlari (korinish matni bilan). security_invoker — entry_maydon RLSi ishlaydi. '
  'Klient: sb.from(''v_entry_maydon'').select(''*'').in(''entry_id'', ids) — refreshMeta naqshi.';

-- ---------------------------------------------------------------------
-- 7.2 entry_maydonlar(uuid[]) — BITTA chaqiruvda map
-- ---------------------------------------------------------------------
-- Javob: { "<entry_id>": [ {maydon_id, nom, maydon_turi, tartib,
--                           element_id, element_nom, element_qiymat,
--                           rasm_url, qiymat_matn, korinish}, ... ], ... }
-- Qiymati yo'q yozuv javobda UMUMAN bo'lmaydi (klientda `map[id] || []`).
-- 🔴 SECURITY INVOKER — RLS filtrlaydi (fail-closed, jurnal bilan bir xil).
create or replace function entry_maydonlar(p_entries uuid[])
returns jsonb
language plpgsql
stable
set search_path = public
as $fn$
declare v_out jsonb;
begin
  if p_entries is null or array_length(p_entries, 1) is null then
    return '{}'::jsonb;
  end if;
  if array_length(p_entries, 1) > 1000 then
    raise exception 'Bir chaqiruvda 1000 tadan kop yozuv soralmaydi' using errcode = '22000';
  end if;

  select coalesce(jsonb_object_agg(t.eid, t.arr), '{}'::jsonb) into v_out
    from (
      select v.entry_id::text as eid,
             jsonb_agg(jsonb_build_object(
               'maydon_id',      v.maydon_id,
               'nom',            v.maydon_nom,
               'maydon_turi',    v.maydon_turi,
               'tartib',         v.tartib,
               'element_id',     v.element_id,
               'element_nom',    v.element_nom,
               'element_qiymat', v.element_qiymat,
               'rasm_url',       v.rasm_url,
               'qiymat_matn',    v.qiymat_matn,
               'korinish',       v.korinish)
             order by v.tartib, v.maydon_nom) as arr
        from v_entry_maydon v
       where v.entry_id = any(p_entries)
       group by v.entry_id
    ) t;

  return coalesce(v_out, '{}'::jsonb);
end $fn$;

revoke all on function entry_maydonlar(uuid[]) from public, anon;
grant execute on function entry_maydonlar(uuid[]) to authenticated;

comment on function entry_maydonlar(uuid[]) is
  'Jurnal/hisobot uchun: yozuv idlari boyicha maxsus maydon qiymatlari MAPi (entry_id -> massiv). '
  'jurnal_v2 TEGILMAGAN — bu alohida yengil chaqiruv (refreshCheks naqshi). Ruxsat: entry_maydon RLSi (invoker).';


-- #####################################################################
-- ##  8-BO'LIM — RASM (Supabase Storage) — QO'LDA BAJARILADI          ##
-- #####################################################################
-- RASM IXTIYORIY: `rasm_url` bo'sh bo'lsa klient nom + qiymat ko'rsatadi
-- ("DAMAS 01O244RB"). Rasm faqat bezak.
--
-- 🔴 BUCKET: `xarajat-maydon`  (YANGI, PUBLIC)
--    Yo'l qoidasi:  <maydon_id>/<element_id>.jpg
--    Yuklash tartibi (sozlama sahifasi):
--      1) xarajat_element_yarat(...) -> element_id olinadi
--      2) sb.storage.from('xarajat-maydon')
--           .upload(`${maydonId}/${elementId}.jpg`, blob,
--                   {contentType:'image/jpeg', upsert:true})
--      3) const {data} = sb.storage.from('xarajat-maydon')
--                          .getPublicUrl(`${maydonId}/${elementId}.jpg`)
--      4) xarajat_element_tahrir(p_id => elementId, p_rasm_url => data.publicUrl)
--    (Rasmni olib tashlash: p_rasm_url => '' — bo'sh matn = tozalash.)
--
-- ⚠️ NEGA MAVJUD `xarajat-cheklari` BUCKETI ISHLATILMADI (uch sabab):
--   1) YO'L QOIDASI MOS EMAS. U yerda yo'l `<kassa_id>/<entry_id>.jpg` —
--      ya'ni fayl KASSA va YOZUVGA bog'langan. Katalog rasmi esa hech
--      qanday kassaga/yozuvga tegishli emas (u ro'yxat elementiniki);
--      uni o'sha bucketga qo'yish jurnaldagi `refreshCheks()` ni
--      chalg'itardi — u `list(kassa_id)` qilib fayl nomini `entry_id` deb
--      o'qiydi va begona faylni "chek bor" deb ko'rsatib qo'yardi.
--   2) MAXFIYLIK DARAJASI BOSHQA. Chek — MAXFIY: `createSignedUrl(...,300)`
--      bilan, ruxsat bo'yicha ochiladi. Mashina surati esa xarajat
--      formasini ochgan HAR foydalanuvchiga darrov kerak; signed URL bo'lsa
--      har element uchun har ochilishda alohida so'rov ketardi (10 element =
--      10 so'rov, forma sekinlashardi).
--   3) YOZISH HUQUQI BOSHQA. Chekni HODIM yozadi (o'z kassasiga), katalog
--      rasmini esa FAQAT ADMIN. Bitta bucketda bu ikki qoidani ajratib
--      bo'lmasdi.
--
-- 🔴 QUYIDAGI BLOK ATAYLAB IZOHDA (storage DDL xato bersa BUTUN fayl
--    orqaga qaytardi). Bucketni Dashboard -> Storage -> New bucket
--    (`xarajat-maydon`, Public = ON) bilan yarating; policy'lar kerak
--    bo'lsa shu blokni ALOHIDA RUN qiling:
--
-- insert into storage.buckets (id, name, public)
-- values ('xarajat-maydon', 'xarajat-maydon', true)
-- on conflict (id) do update set public = true;
--
-- drop policy if exists "xm rasm oqish" on storage.objects;
-- create policy "xm rasm oqish" on storage.objects
--   for select to public using (bucket_id = 'xarajat-maydon');
--
-- drop policy if exists "xm rasm yozish" on storage.objects;
-- create policy "xm rasm yozish" on storage.objects
--   for insert to authenticated
--   with check (bucket_id = 'xarajat-maydon' and public.is_admin());
--
-- drop policy if exists "xm rasm yangilash" on storage.objects;
-- create policy "xm rasm yangilash" on storage.objects
--   for update to authenticated
--   using (bucket_id = 'xarajat-maydon' and public.is_admin())
--   with check (bucket_id = 'xarajat-maydon' and public.is_admin());
--
-- drop policy if exists "xm rasm ochirish" on storage.objects;
-- create policy "xm rasm ochirish" on storage.objects
--   for delete to authenticated
--   using (bucket_id = 'xarajat-maydon' and public.is_admin());


-- =====================================================================
-- PostgREST sxemasini yangilash (busiz yangi RPC/jadval 404 beradi)
-- =====================================================================

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  TEKSHIRUV — FAQAT KATALOG SO'ROVLARI (jonli chaqiruv YO'Q)      ##
-- #####################################################################

-- 1) Jadvallar va view o'rnidami (hammasi true)
select to_regclass('public.xarajat_maydon')         is not null as t_maydon,
       to_regclass('public.xarajat_maydon_modda')   is not null as t_biriktirish,
       to_regclass('public.xarajat_royxat_element') is not null as t_element,
       to_regclass('public.entry_maydon')           is not null as t_qiymat,
       to_regclass('public.v_entry_maydon')         is not null as v_korinish;

-- 2) RLS yoqilganmi (to'rtalasi ham true)
select c.relname, c.relrowsecurity as rls_yoqilgan
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relname in ('xarajat_maydon','xarajat_maydon_modda','xarajat_royxat_element','entry_maydon')
 order by c.relname;

-- 3) 🔴 KATALOGDA YOZISH POLICY'SI BO'LMASIN (0), qiymatda 4 ta bo'lsin
select (select count(*)::int from pg_policies
         where schemaname = 'public'
           and tablename in ('xarajat_maydon','xarajat_maydon_modda','xarajat_royxat_element')
           and cmd <> 'SELECT')                                   as katalog_yozish_policy_0_BULSIN,
       (select count(*)::int from pg_policies
         where schemaname = 'public' and tablename = 'entry_maydon') as qiymat_policy_4_BULSIN,
       (select count(*)::int from pg_policies
         where schemaname = 'public' and tablename = 'entry_maydon'
           -- ⚠️ INSERT policy'da `qual` NULL bo'ladi (faqat with_check bor) —
           --    ikkalasi ham coalesce bilan o'ralmasa `null || text` = null bo'lib
           --    qator sanalmay qolardi.
           and coalesce(qual, '') || coalesce(with_check, '') like '%xm_entry_yoz_ok%')
         as qorovulli_policy_3_BULSIN;

-- 4) Funksiyalar o'rnidami (hammasi true)
select to_regprocedure('public.xm_page_ok(text)')                                        is not null as f_page_ok,
       to_regprocedure('public.xm_admin_talab()')                                        is not null as f_admin_talab,
       to_regprocedure('public.xm_entry_yoz_ok(uuid)')                                   is not null as f_yoz_ok,
       to_regprocedure('public.xm_maydon_entry_mos(uuid,uuid)')                          is not null as f_mos,
       to_regprocedure('public.xm_majburiy_yoq(uuid)')                                   is not null as f_majburiy,
       to_regprocedure('public.xarajat_maydon_yarat(text,text,boolean,int,jsonb,uuid[])') is not null as f_yarat,
       to_regprocedure('public.xarajat_maydon_tahrir(uuid,text,boolean,int,jsonb)')       is not null as f_tahrir,
       to_regprocedure('public.xarajat_maydon_ochir(uuid,boolean)')                       is not null as f_ochir,
       to_regprocedure('public.xarajat_maydon_biriktir(uuid,uuid,boolean,boolean)')       is not null as f_biriktir,
       to_regprocedure('public.xarajat_element_yarat(uuid,text,text,text,int)')           is not null as f_el_yarat,
       to_regprocedure('public.xarajat_element_tahrir(uuid,text,text,text,int)')          is not null as f_el_tahrir,
       to_regprocedure('public.xarajat_element_ochir(uuid,boolean)')                      is not null as f_el_ochir,
       to_regprocedure('public.xarajat_maydonlar(uuid)')                                  is not null as f_forma,
       to_regprocedure('public.xarajat_maydon_sozlama(boolean)')                          is not null as f_sozlama,
       to_regprocedure('public.entry_maydon_yoz(uuid,jsonb)')                             is not null as f_yoz,
       to_regprocedure('public.entry_maydonlar(uuid[])')                                  is not null as f_map;

-- 5) HUQUQLAR — ichki funksiyalar yopiq, ochiqlari ochiq, anon HECH QAYERDA
select has_function_privilege('authenticated','public.xm_page_ok(text)','execute')        as ichki_page_ok_YOPIQ_BULSIN,
       has_function_privilege('authenticated','public.xm_admin_talab()','execute')        as ichki_admin_talab_YOPIQ_BULSIN,
       has_function_privilege('authenticated','public.xm_entry_yoz_ok(uuid)','execute')   as policy_fn_OCHIQ_BULSIN,
       has_function_privilege('anon','public.xarajat_maydonlar(uuid)','execute')          as anon_forma_YOPIQ_BULSIN,
       has_function_privilege('authenticated','public.xarajat_maydonlar(uuid)','execute') as forma_ochiq,
       has_function_privilege('authenticated','public.entry_maydon_yoz(uuid,jsonb)','execute') as yozish_ochiq,
       has_table_privilege('anon','public.entry_maydon','select')                         as anon_qiymat_YOPIQ_BULSIN,
       has_table_privilege('authenticated','public.entry_maydon','insert')                as qiymat_insert_ochiq,
       has_table_privilege('authenticated','public.xarajat_maydon','insert')              as katalog_insert_YOPIQ_BULSIN;

-- 6) 🔴 UNIVERSALLIK ISBOTI: kod ichida (SEED dan tashqari) mashinaga oid
--    matn BO'LMASIN — nol qaytishi kerak.
select count(*)::int as mashina_hardcode_0_BULSIN
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('xm_page_ok','xm_admin_talab','xm_entry_yoz_ok','xm_maydon_entry_mos',
                     'xm_majburiy_yoq','xarajat_maydon_yarat','xarajat_maydon_tahrir',
                     'xarajat_maydon_ochir','xarajat_maydon_biriktir','xarajat_element_yarat',
                     'xarajat_element_tahrir','xarajat_element_ochir','xarajat_maydonlar',
                     'xarajat_maydon_sozlama','entry_maydon_yoz','entry_maydonlar')
   and (p.prosrc ~* 'mashina|moshina|benzin|damas|tracker|davlat raqam');

-- 7) SECURITY: qaysi funksiya definer, qaysi invoker (ko'rish uchun)
--    Kutilgan: entry_maydon_yoz / xarajat_maydonlar / entry_maydonlar -> INVOKER
--    (RLS ishlasin), qolganlari -> DEFINER.
select p.proname, p.prosecdef as definer
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and (p.proname like 'xarajat\_%' or p.proname like 'xm\_%' or p.proname like 'entry\_maydon%')
 order by p.proname;

-- 8) View security_invoker yoqilganmi (true bo'lsin)
select coalesce((select 'security_invoker=on' = any(c.reloptions)
                   from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relname = 'v_entry_maydon'), false)
       as view_invoker_ok;

-- 9) Hozircha ma'lumot yo'qligini ko'rish (SEED dan oldin hammasi 0)
select (select count(*)::int from xarajat_maydon)         as maydonlar,
       (select count(*)::int from xarajat_maydon_modda)   as biriktirishlar,
       (select count(*)::int from xarajat_royxat_element) as elementlar,
       (select count(*)::int from entry_maydon)           as qiymatlar;


-- #####################################################################
-- ##  9-BO'LIM — SEED (2-BOSQICH) — 🔴 ATAYLAB IZOHDA                 ##
-- #####################################################################
-- Bu blok 1-BOSQICH bilan BIRGA RUN QILINMAYDI. Avval universal tizim
-- tekshiriladi (sozlamada maydon yaratish, formada chiqishi, jurnalda
-- ko'rinishi), SHUNDAN KEYIN Asilbek quyidagini izohdan chiqarib ALOHIDA
-- RUN qiladi.
--
-- 🔴 NEGA IZOHDA:
--   1) BU MA'LUMOT, KOD EMAS. Fayldagi mantiq "mashina" ni bilmaydi —
--      mashina shu yerda, faqat qatorlar ko'rinishida. Aynan shu ajratish
--      universallikning isboti (TEKSHIRUV 6-bandi).
--   2) Seed YANGI XARAJAT MODDASI (accounts) yaratadi — ya'ni hisob
--      rejasiga aralashadi. Bunday qadam Asilbekning ongli tasdig'i bilan,
--      alohida bajarilishi kerak.
--   3) Nomlar/raqamlar o'zgarishi mumkin (yangi mashina qo'shilishi,
--      raqam almashishi) — ular kodga emas, ma'lumotga tegishli.
--
-- ⚠️ SEED RPC LARNI CHAQIRMAYDI, TO'G'RIDAN INSERT QILADI. Sabab: SQL
--    editorda `auth.uid()` NULL, ya'ni `xm_admin_talab()` -> `is_admin()`
--    false -> hamma admin RPC 42501 berardi va blok yiqilardi.
--    To'g'ridan insert `postgres` roli bilan ketadi (RLS chetlab o'tiladi) —
--    bu YAGONA to'g'ri yo'l.
-- ⚠️ Idempotent: qayta RUN qilinsa dublikat yaratmaydi.
--
-- ---------------------------------------------------------------------
-- 9.1 Ikki xarajat moddasi: "Moshina Gaz" va "Moshina Benzin"
--     (sozlama-dev.html bilan bir xil qoida: type='xarajat',
--      section='operatsion', kod 94xx — mavjud eng kattasi + 1, 9421 dan)
-- ---------------------------------------------------------------------
-- insert into accounts (code, name, type, section)
-- select (select coalesce(max(a.code::int), 9420) + 1
--           from accounts a where a.code ~ '^94[0-9][0-9]$')::text,
--        'Moshina Gaz', 'xarajat', 'operatsion'
--  where not exists (select 1 from accounts
--                     where lower(btrim(name)) = 'moshina gaz' and type = 'xarajat');
--
-- insert into accounts (code, name, type, section)
-- select (select coalesce(max(a.code::int), 9420) + 1
--           from accounts a where a.code ~ '^94[0-9][0-9]$')::text,
--        'Moshina Benzin', 'xarajat', 'operatsion'
--  where not exists (select 1 from accounts
--                     where lower(btrim(name)) = 'moshina benzin' and type = 'xarajat');
--
-- ---------------------------------------------------------------------
-- 9.2 "Mashina" maydoni (BITTA ta'rif, royxat turi, MAJBURIY)
-- ---------------------------------------------------------------------
-- insert into xarajat_maydon (nom, maydon_turi, required, tartib, options)
-- select 'Mashina', 'royxat', true, 10, '{}'::jsonb
--  where not exists (select 1 from xarajat_maydon
--                     where lower(btrim(nom)) = 'mashina' and is_active);
--
-- ---------------------------------------------------------------------
-- 9.3 Biriktirish: bitta maydon — IKKI modda (N:M ning butun ma'nosi)
-- ---------------------------------------------------------------------
-- insert into xarajat_maydon_modda (maydon_id, modda_id)
-- select m.id, a.id
--   from xarajat_maydon m
--   join accounts a on a.type = 'xarajat'
--                  and lower(btrim(a.name)) in ('moshina gaz', 'moshina benzin')
--  where lower(btrim(m.nom)) = 'mashina' and m.is_active
-- on conflict (maydon_id, modda_id) do nothing;
--
-- ---------------------------------------------------------------------
-- 9.4 Ro'yxat elementlari — rasm YO'Q (ixtiyoriy; keyin sozlamadan yuklanadi)
-- ---------------------------------------------------------------------
-- insert into xarajat_royxat_element (maydon_id, nom, qiymat, tartib)
-- select m.id, v.nom, v.qiymat, v.tartib
--   from xarajat_maydon m
--   cross join (values ('DAMAS',   '01O244RB', 1),
--                      ('Tracker', '01W182OC', 2)) as v(nom, qiymat, tartib)
--  where lower(btrim(m.nom)) = 'mashina' and m.is_active
--    and not exists (select 1 from xarajat_royxat_element el
--                     where el.maydon_id = m.id
--                       and lower(btrim(el.nom)) = lower(btrim(v.nom))
--                       and el.is_active);
--
-- notify pgrst, 'reload schema';
--
-- -- SEED TEKSHIRUVI (RUN'dan keyin): 1 maydon, 2 biriktirish, 2 element
-- select (select count(*)::int from xarajat_maydon where lower(btrim(nom))='mashina' and is_active) as maydon_1,
--        (select count(*)::int from xarajat_maydon_modda mm
--           join xarajat_maydon m on m.id = mm.maydon_id
--          where lower(btrim(m.nom))='mashina')                                                     as biriktirish_2,
--        (select count(*)::int from xarajat_royxat_element el
--           join xarajat_maydon m on m.id = el.maydon_id
--          where lower(btrim(m.nom))='mashina' and el.is_active)                                    as element_2,
--        (select count(*)::int from accounts
--          where type='xarajat' and lower(btrim(name)) in ('moshina gaz','moshina benzin'))         as modda_2;


-- #####################################################################
-- ##  KLIENT KONTRAKTI (keyingi bosqich — HTML)                       ##
-- #####################################################################
-- 🔴 HAR CHAQIRUVDA `{ data, error }` — error DOIM tekshiriladi.
--    42501 = ruxsat yo'q · 22000 = noto'g'ri ma'lumot (matni o'zbekcha,
--    to'g'ridan ko'rsatilsa bo'ladi) · PGRST202/42P01 = SQL RUN qilinmagan
--    (bu holatda sahifa AVVALGIDEK ishlashi kerak — `tlmOff`/`v2Off` naqshi:
--     maydon bloki chizilmaydi, xarajat baribir saqlanadi).
--
-- 1) SOZLAMA (sozlama-dev.html, admin):
--      sb.rpc('xarajat_maydon_sozlama', {p_faqat_faol:false})
--      sb.rpc('xarajat_maydon_yarat',   {p_nom, p_turi, p_required, p_tartib, p_options, p_moddalar})
--      sb.rpc('xarajat_maydon_tahrir',  {p_id, p_nom, p_required, p_tartib, p_options})
--      sb.rpc('xarajat_maydon_ochir',   {p_id, p_ochirilsin:true})
--      sb.rpc('xarajat_maydon_biriktir',{p_maydon, p_modda, p_on, p_required})
--      sb.rpc('xarajat_element_yarat',  {p_maydon, p_nom, p_qiymat, p_rasm_url, p_tartib})
--      sb.rpc('xarajat_element_tahrir', {p_id, p_nom, p_qiymat, p_rasm_url, p_tartib})
--      sb.rpc('xarajat_element_ochir',  {p_id, p_ochirilsin:true})
--
-- 2) XARAJAT FORMASI (hodim-dev.html / professional-dev.html / standart-dev.html):
--      modda tanlanganda:  sb.rpc('xarajat_maydonlar', {p_modda: moddaId})
--      -> [] bo'lsa hech narsa chizilmaydi (eski xatti-harakat AYNAN saqlanadi).
--      `required:true` maydon to'ldirilmaguncha "Saqlash" yopiq
--      (chek/izoh/davr majburiyligi bilan BIR XIL naqsh).
--
-- 3) SAQLASH — 🔴 TARTIB MAJBURIY:
--      entry -> entry_line (yoki hodim_xarajat_yoz RPC) -> SO'NGRA
--      sb.rpc('entry_maydon_yoz', {p_entry: entryId, p_qiymatlar: [...]})
--    Sabab: qorovul yozuv SATRLARIGA qaraydi (qaysi modda debet bo'lgan +
--    pul ruxsati). Satrlar hali yo'q bo'lsa 42501 qaytadi.
--    ⚠️ Chek yuklash naqshi kabi FONDA qilinsa — xato bo'lsa foydalanuvchiga
--    ayting ("Xarajat saqlandi, lekin mashina yozilmadi"), yozuvni
--    o'chirmang (pul harakati allaqachon to'g'ri).
--
-- 4) JURNAL / HISOBOT:
--      sb.from('v_entry_maydon').select('*').in('entry_id', ids)     (refreshMeta naqshi)
--      yoki  sb.rpc('entry_maydonlar', {p_entries: ids})             (bitta chaqiruv, map)
--    Chizish: `korinish` matni + `rasm_url` bo'lsa kichik surat.
--    🔴 Rasm bo'lmasa — nom + qiymat ("DAMAS 01O244RB"). Bu qoida
--       SERVERDA hisoblangan (`korinish`), klient takrorlamasin.


-- #####################################################################
-- ##  ROLLBACK (kerak bo'lsa — bitta-bitta, AYNAN shu tartibda)       ##
-- #####################################################################
-- 🔴 TARTIB MUHIM: policy'lar funksiyalarga BOG'LANGAN — avval policy,
--    keyin funksiya. Aks holda "cannot drop function ... other objects
--    depend on it" xatosi chiqadi.
--
-- 1) Policy'lar:
--    drop policy if exists entry_maydon_sel on entry_maydon;
--    drop policy if exists entry_maydon_ins on entry_maydon;
--    drop policy if exists entry_maydon_upd on entry_maydon;
--    drop policy if exists entry_maydon_del on entry_maydon;
--    drop policy if exists xarajat_maydon_sel on xarajat_maydon;
--    drop policy if exists xarajat_maydon_modda_sel on xarajat_maydon_modda;
--    drop policy if exists xarajat_element_sel on xarajat_royxat_element;
--
-- 2) View + RPC lar:
--    drop view     if exists public.v_entry_maydon;
--    drop function if exists public.entry_maydonlar(uuid[]);
--    drop function if exists public.entry_maydon_yoz(uuid, jsonb);
--    drop function if exists public.xarajat_maydon_sozlama(boolean);
--    drop function if exists public.xarajat_maydonlar(uuid);
--    drop function if exists public.xarajat_element_ochir(uuid, boolean);
--    drop function if exists public.xarajat_element_tahrir(uuid, text, text, text, int);
--    drop function if exists public.xarajat_element_yarat(uuid, text, text, text, int);
--    drop function if exists public.xarajat_maydon_biriktir(uuid, uuid, boolean, boolean);
--    drop function if exists public.xarajat_maydon_ochir(uuid, boolean);
--    drop function if exists public.xarajat_maydon_tahrir(uuid, text, boolean, int, jsonb);
--    drop function if exists public.xarajat_maydon_yarat(text, text, boolean, int, jsonb, uuid[]);
--
-- 3) Qorovullar:
--    drop function if exists public.xm_majburiy_yoq(uuid);
--    drop function if exists public.xm_maydon_entry_mos(uuid, uuid);
--    drop function if exists public.xm_entry_yoz_ok(uuid);
--    drop function if exists public.xm_admin_talab();
--    drop function if exists public.xm_page_ok(text);
--
-- 4) 🔴 JADVALLAR — FAQAT ma'lumot kerak bo'lmasa (qiymatlar YO'QOLADI):
--    drop table if exists public.entry_maydon;
--    drop table if exists public.xarajat_royxat_element;
--    drop table if exists public.xarajat_maydon_modda;
--    drop table if exists public.xarajat_maydon;
--
-- 5) notify pgrst, 'reload schema';
--
-- 🔴 ROLLBACK `entry` / `entry_line` / `accounts` GA UMUMAN TEGMAYDI —
--    bu fayl ularga bitta ustun ham qo'shmagan. Seed RUN qilingan bo'lsa
--    "Moshina Gaz"/"Moshina Benzin" moddalari QOLADI (hisob rejasi —
--    o'chirilmaydi, kerak bo'lsa sozlamadan is_active=false qilinadi).
-- #####################################################################
