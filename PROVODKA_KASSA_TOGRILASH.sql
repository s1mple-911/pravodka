-- =====================================================================
--  ⚠️⚠️  SUPABASE SQL EDITOR — QANDAY RUN QILINADI (avval SHUNI o'qing)
-- ---------------------------------------------------------------------
--   1) Bu faylda anonim blok (`do ...`) UMUMAN YO'Q. Dollar-quote belgisi
--      (ikki dollar yonma-yon) FAQAT 2.0 dagi ikki funksiya tanasining
--      boshi va oxirida — izohlarda umuman yo'q, ichma-ich ham yo'q.
--      Sabab: Supabase SQL Editor anonim blokni bo'lib yuborardi va
--      PL/pgSQL o'zgaruvchisini jadval deb izlardi
--      (`ERROR: 42P01: relation "v_..." does not exist`) — to'rt marta.
--      `create or replace function ... as` esa muammosiz ishlaydi.
--      Shuning uchun butun mantiq funksiyaga qadoqlangan, chaqiruv esa
--      oddiy `select`.
--
--   2) Tartib:
--        0-BOSQICH  — preflight (hech narsa yozmaydi)
--        1-BOSQICH  — reja jadvali + PREVIEW (hech narsa yozmaydi)
--        2.0        — funksiyalar (DDL, pul yozmaydi)
--        2.1        — MAJBURIY DRY-RUN (bajaradi va ORQAGA QAYTARADI)
--        2.2        — 🔴 YOZISH (haqiqiy pul)
--        3-BOSQICH  — yozgandan keyingi tekshiruvlar (a…e)
--        ROLLBACK   — izohda, qo'lda
--      BUTUN FAYLNI BIRDANIGA RUN QILMANG — 2.2 haqiqiy pul yozadi.
--
--   3) Har bo'lak ⬇⬇⬇ va ⬆⬆⬆ belgilari orasida — AYNAN o'sha oraliqni
--      belgilab RUN qiling. Bitta `select` = bitta tranzaksiya: funksiya
--      ichida xato chiqsa Postgres HAMMASINI orqaga qaytaradi (yarim
--      yozilgan holat bo'lmaydi).
--
--   4) 🔴 YOZISHDAN OLDIN n8n `Aros Provodka - Auto Sync` (7MSHrXnz9cGAFBTh)
--      ni VAQTINCHA DEACTIVATE QILING, 3-BOSQICH tugagach qayta yoqing.
--      Sabab: skript kassa qoldig'ini O'QIB farqni hisoblaydi — sinxron
--      shu oraliqda ishlab qolsa "absolyut" satr boshqa songa tayanadi.
-- =====================================================================

-- =====================================================================
--  PROVODKA_KASSA_TOGRILASH.sql
--  Ikki markaziy kassaning qoldig'ini haqiqiy holatga keltirish
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  #####  NIMA BO'LGAN  ################################################
--
--  Transfer sinxroni summani `items[].document.seller_*` (sotuvchining
--  REJASI) dan olardi, to'g'risi esa `items[].confirmed_*` (qabulda
--  TASDIQLANGAN). 3 ta transferda farq chiqqan va daftar buzilgan.
--  Bu fayl sinxronni tuzatmaydi (u alohida) — faqat DAFTARNI haqiqiy
--  holatga keltiradi.
--
--  #####  NIMA TO'G'RILANADI  ##########################################
--
--   Kassa                     Nima          Qanday
--   ------------------------- ------------- --------------------------
--   Toshkent   5011 · Naqd    446 755 000   ABSOLYUT (aynan shu son)
--   Toshkent   5011 · USD     -100 USD      NISBIY  (100 $ ayiriladi)
--   Qashqadaryo 5012 · Naqd   +10 000 so'm  NISBIY  (10 000 qo'shiladi)
--
--   🔴 Payme va Click hisoblariga UMUMAN TEGILMAYDI (3-BOSQICH (e)
--      buni tekshiradi va satr topilsa ❌ beradi).
--
--  ⚠️ HOZIRGI QOLDIQNI SKRIPTNING O'ZI O'QIYDI (`v_hisob_bal`) va farqni
--     o'sha paytda hisoblaydi — raqam qattiq yozilmagan. Ya'ni qachon RUN
--     qilinsa ham natija to'g'ri bo'ladi.
--
--  #####  YOZUV SHAKLI  ################################################
--
--   Qarshi tomon — `boshlangich_kapital_id()` (odatda 8720, type='kapital').
--   Bu tushum ham, xarajat ham EMAS: AKTIV va KAPITAL birga o'zgaradi,
--   P&L'ga umuman tegilmaydi (9010 ga yozilsa o'sha kunning foydasi
--   soxta o'sardi).
--
--   Yo'nalish farq belgisidan:
--     farq > 0 (qoldiq OSHADI)    ->  Dt <kassa bola-hisobi> / Kt 87xx
--     farq < 0 (qoldiq KAMAYADI)  ->  Dt 87xx / Kt <kassa bola-hisobi>
--   `debit`/`credit` HECH QACHON manfiy emas (baza cheklovi) — summa
--   har doim abs(farq), belgi esa tomonni tanlaydi.
--
--   USD hisobi uchun: `debit`/`credit` SO'MDA (100 × kurs),
--   `fc_amount` = 100 (dollar miqdori, valyuta satriga), `entry.fc_rate` = kurs.
--   Kurs manbasi — `conv_baza_kurs('USD')` (USD uchun `aros_usd_rate()`,
--   bo'lmasa `currency_rate`dagi oxirgisi). Kurs topilmasa skript ANIQ
--   XATO beradi va HECH NARSA yozilmaydi (butun tranzaksiya qaytadi).
--
--   description = 'Kassa to''g''rilash — <kassa> · <tur> (<±summa>)'
--   entry_date  = bugun, Toshkent vaqti (now() at time zone 'Asia/Tashkent').
--
--  #####  NEGA IKKI MARTA YOZILMAYDI  ##################################
--   1. `ext_ref = 'kassa_fix:2026-08-13:<kassa_code>:<tur>'` — UNIQUE.
--      Skript ikkinchi marta RUN qilinsa o'sha satrni O'TKAZIB YUBORADI
--      (funksiya ichida ochiq tekshiruv + bazada unique to'siq).
--   2. "Absolyut" satr baribir qoldiqni O'QIB farq hisoblaydi — ikkinchi
--      RUN'da farq 0 bo'lardi va yozuv yaratilmasdi.
--   3. Farq 0 bo'lgan HAR QANDAY satr uchun yozuv UMUMAN yaratilmaydi
--      (nol summali yozuv ham qolmaydi).
--   4. 1.3 PREVIEW yozishdan oldin har satr uchun qarorni ko'rsatadi.
--   5. 2.1 DRY-RUN — haqiqiy mashq: hammasi yoziladi, tekshiriladi va
--      ORQAGA QAYTARILADI (bazada iz yo'q).
--
--  TALAB: PROVODKA_KAPITAL.sql (boshlangich_kapital_id),
--         PROVODKA_KASSA2.sql (v_hisob_bal, conv_baza_kurs).
--
--  ADDITIVE: mavjud jadval/ustun/funksiya/view O'ZGARTIRILMAYDI.
--  Yangi: `kassa_togrilash_reja` va `kassa_togrilash_log` jadvallari
--  (SHU skriptning o'z jadvallari) + `kassa_togrilash_ish()` va
--  `kassa_togrilash(boolean)` funksiyalari.
-- =====================================================================


-- #####################################################################
--  0-BOSQICH — PREFLIGHT.  HECH NARSA YOZMAYDI.
-- #####################################################################

-- ---------------------------------------------------------------------
-- 0.1 Hisoblar topildimi va hozirgi qoldiqlar qanday
-- ---------------------------------------------------------------------
--  `natija` ustunida uchala qator ham ✅ OK bo'lishi SHART.
--  `qoldiq_uzs` — hisobning so'mdagi qoldig'i (USD satrida bu TARIXIY
--  kursdagi so'm ekvivalenti, joriy kursga ko'paytirilmaydi).
--  `qoldiq_fc`  — hisobning o'z valyutasidagi qoldig'i (USD uchun DOLLAR).
--  Shartlar 1.3 PREVIEW va 2.0 funksiyasi bilan AYNAN bir xil.
--
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
with reja(kassa_code, tur, lbl) as (
  values ('5011', 'naqd', 'Toshkent · Naqd'),
         ('5011', 'usd',  'Toshkent · USD'),
         ('5012', 'naqd', 'Qashqadaryo · Naqd')
)
select r.kassa_code,
       r.lbl                                  as nima,
       coalesce(k.name, '—')                  as kassa_nom,
       ks.n                                   as mos_kassa_soni,
       cs.n                                   as mos_hisob_soni,
       coalesce(c.code, '—')                  as hisob_kod,
       coalesce(c.name, '—')                  as hisob_nom,
       coalesce(b.uzs, 0)                     as qoldiq_uzs,
       coalesce(b.fc,  0)                     as qoldiq_fc,
       case when coalesce(ks.n, 0) <> 1
              then '❌ KASSA TOPILMADI (aniq 1 ta kerak)'
            when coalesce(cs.n, 0) <> 1
              then '❌ BOLA-HISOB TOPILMADI (aniq 1 ta kerak) — SKRIPT HISOB OCHMAYDI'
            else '✅ OK' end                   as natija
  from reja r
  left join lateral (
    select count(*) as n
      from accounts a
     where a.code = r.kassa_code and a.section = 'pul' and a.is_active
       and a.pul_turi is null and coalesce(a.currency, 'UZS') = 'UZS'
  ) ks on true
  left join lateral (
    select a.id, a.name
      from accounts a
     where a.code = r.kassa_code and a.section = 'pul' and a.is_active
       and a.pul_turi is null and coalesce(a.currency, 'UZS') = 'UZS'
     order by a.code limit 1
  ) k on true
  left join lateral (
    select count(*) as n
      from accounts x
     where x.parent_id = k.id and x.is_active
       and (case when r.tur = 'usd' then coalesce(x.currency, 'UZS') = 'USD'
                 else x.pul_turi = 'naqd' and coalesce(x.currency, 'UZS') = 'UZS' end)
  ) cs on true
  left join lateral (
    select x.id, x.code, x.name
      from accounts x
     where x.parent_id = k.id and x.is_active
       and (case when r.tur = 'usd' then coalesce(x.currency, 'UZS') = 'USD'
                 else x.pul_turi = 'naqd' and coalesce(x.currency, 'UZS') = 'UZS' end)
     order by x.code limit 1
  ) c on true
  left join v_hisob_bal b on b.account_id = c.id
 order by r.kassa_code, r.tur;
-- ⬆⬆⬆  0.1 shu yerda tugadi  ⬆⬆⬆

--  ⚠️ USD satri haqida: `qoldiq_fc` — `entry_line.fc_amount` yig'indisi
--     (`v_hisob_bal.fc`). Agar eski USD yozuvlarida `fc_amount` to'ldirilmagan
--     bo'lsa, bu son haqiqiy dollar miqdoridan kam ko'rinadi. Bu SKRIPTGA
--     TA'SIR QILMAYDI: USD satri NISBIY (−100), ya'ni "hozirgidan 100 kam"
--     degani va yozuv summasi qoldiqqa bog'liq emas. `qoldiq_fc` faqat
--     ma'lumot uchun. (Naqd satrlar `qoldiq_uzs` ga tayanadi — u har doim
--     to'liq.)

-- ---------------------------------------------------------------------
-- 0.2 USD kursi bormi (USD satri uchun MAJBURIY)
-- ---------------------------------------------------------------------
--  `natija` ✅ OK bo'lmasa — USD satri yozilmaydi va skript butun
--  tranzaksiyani orqaga qaytaradi (naqd satrlari ham yozilmaydi).
--  Tuzatish: Valyuta bo'limida kursni Aros dan import qiling yoki
--  `currency_rate` ga USD -> UZS kursini qo'shing.
select k.usd                                as usd_kurs,
       round(100 * coalesce(k.usd, 0), 2)   as yuz_dollar_somda,
       case when coalesce(k.usd, 0) <= 0
              then '❌ KURS YO''Q — USD satri yozilmaydi'
            else '✅ OK' end                as natija
  from (select conv_baza_kurs('USD') as usd) k;

-- ---------------------------------------------------------------------
-- 0.3 Bu to'g'rilash allaqachon yozilganmi (BO'SH natija = yozilmagan)
-- ---------------------------------------------------------------------
select e.ext_ref, e.entry_date, e.description, e.is_deleted, e.fc_rate,
       (select sum(l.debit) from entry_line l where l.entry_id = e.id) as summa_uzs
  from entry e
 where e.ext_ref like 'kassa_fix:%'
 order by e.ext_ref;

-- ---------------------------------------------------------------------
-- 0.4 Qarshi tomon — boshlang'ich kapital hisobi
-- ---------------------------------------------------------------------
select a.id   as kapital_id,
       a.code as kapital_kod,
       a.name as kapital_nom,
       a.type as turi,
       case when a.id is null then '❌ TOPILMADI — PROVODKA_KAPITAL.sql RUN qilinganmi?'
            when a.type <> 'kapital' then '❌ TYPE kapital EMAS'
            else '✅ OK' end as natija
  from (select boshlangich_kapital_id() as id) x
  left join accounts a on a.id = x.id;


-- #####################################################################
--  1-BOSQICH — REJA JADVALI + PREVIEW.  PUL YOZMAYDI.
-- #####################################################################

-- ---------------------------------------------------------------------
-- 1.1 + 1.2  JADVALLAR va REJA
-- ---------------------------------------------------------------------
-- `kassa_togrilash_reja` — SHU SKRIPTNING O'Z jadvali. Frontend, view, RPC
-- yoki boshqa .sql fayl unga murojaat qilmaydi, shuning uchun drop+create
-- ADDITIVE qoidasini buzmaydi.
-- `kassa_togrilash_log` — yozilgan to'g'rilashlar tarixi (oldin/maqsad/keyin).
-- U `if not exists` bilan yaratiladi va HECH QACHON drop qilinmaydi —
-- 3-BOSQICH tekshiruvlari aynan shundan "maqsad" ni oladi.
--
--  rejim = 'absolut' -> qiymat = MAQSAD qoldiq (naqd: so'm, usd: DOLLAR)
--  rejim = 'nisbiy'  -> qiymat = QO'SHILADIGAN farq (manfiy = ayiriladi)
--  tur   = 'naqd' | 'usd'
--  Qatorni o'chirmang — kerak bo'lmasa faol = false qiling:
--     update kassa_togrilash_reja set faol = false where kassa_code = '5012';
--
-- ⬇⬇⬇  1.1 + 1.2: SHU QATORDAN 1.2 oxiridagi `;` GACHA BELGILANG  ⬇⬇⬇
drop table if exists kassa_togrilash_reja;

create table kassa_togrilash_reja (
  kassa_code text    not null,
  tur        text    not null check (tur in ('naqd', 'usd')),
  rejim      text    not null check (rejim in ('absolut', 'nisbiy')),
  qiymat     numeric not null,
  izoh       text,
  faol       boolean not null default true,
  primary key (kassa_code, tur)
);

comment on table kassa_togrilash_reja is
  'Kassa qoldig''ini to''g''rilash rejasi (PROVODKA_KASSA_TOGRILASH.sql). '
  'rejim=absolut -> qiymat MAQSAD qoldiq; rejim=nisbiy -> qiymat qo''shiladigan farq. '
  'tur=usd bo''lsa qiymat DOLLARDA, aks holda so''mda.';

revoke all on kassa_togrilash_reja from public, anon;
alter table kassa_togrilash_reja enable row level security;

create table if not exists kassa_togrilash_log (
  id          bigserial primary key,
  batch       text        not null,
  kassa_code  text        not null,
  tur         text        not null,
  hisob_id    uuid,
  hisob_code  text,
  rejim       text,
  oldin       numeric,
  maqsad      numeric,
  farq        numeric,
  yonalish    text,
  kurs        numeric,
  summa_uzs   numeric,
  keyin       numeric,
  entry_id    uuid,
  ext_ref     text,
  yozilgan_at timestamptz not null default clock_timestamp()
);

comment on table kassa_togrilash_log is
  'PROVODKA_KASSA_TOGRILASH.sql yozgan to''g''rilashlar tarixi. '
  'oldin/maqsad/keyin — o''sha satrning birligida (naqd: so''m, usd: dollar). '
  'DRY-RUN da bu yerga yozilgani ham orqaga qaytadi.';

revoke all on kassa_togrilash_log from public, anon;
alter table kassa_togrilash_log enable row level security;

-- ⚙️⚙️ RAQAMLAR — FAQAT SHU BLOKNI TAHRIRLANG
insert into kassa_togrilash_reja (kassa_code, tur, rejim, qiymat, izoh) values
  ('5011', 'naqd', 'absolut', 446755000,
   'Toshkent Kassa naqd — qoldiq AYNAN shu songa keltiriladi'),
  ('5011', 'usd',  'nisbiy',       -100,
   'Toshkent Kassa USD — hozirgidan 100 dollar KAM bo''lsin'),
  ('5012', 'naqd', 'nisbiy',      10000,
   'Qashqadaryo Kassa naqd — hozirgidan 10 000 so''m KO''P bo''lsin');
-- ⬆⬆⬆  1.1 + 1.2 shu yerda tugadi (3 qator)  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 1.3 ⭐ PREVIEW — ASILBEK SHUNI TEKSHIRSIN.  HECH NARSA YOZMAYDI.
-- ---------------------------------------------------------------------
--  Ustunlar:
--    birlik            — hozirgi/maqsad/farq QAYSI birlikda (so'm yoki USD)
--    hozirgi           — hisobning HOZIRGI qoldig'i (usd satrida DOLLARDA)
--    maqsad            — yozuvdan keyin qanday bo'lishi kerak
--    farq              — maqsad − hozirgi (yozuv summasi shu, belgi tomonni tanlaydi)
--    summa_uzs         — entry_line ga tushadigan SO'M summasi (usd: abs(farq) × kurs)
--    fc_amount         — valyuta satriga tushadigan DOLLAR miqdori (naqd: —)
--    hisob_qoldiq_uzs  — shu hisobning so'mdagi qoldig'i (usd satrida TARIXIY kursda)
--    yonalish          — Dt / Kt qanday yoziladi
--    avval_yozilgan    — ✔ bo'lsa 2.2 uni o'tkazib yuboradi
--
--  🔴 ⛔ belgisi bo'lgan bitta qator bo'lsa ham — 2.2 NI RUN QILMANG.
--  ⚠️ USD satrida "⛔ KURSI YO'Q" chiqsa NAQD satrlari ham yozilmaydi:
--     kurs xatosi butun tranzaksiyani orqaga qaytaradi (ataylab).
--  ⚠️ "⏭ farq 0" — o'sha tur uchun yozuv UMUMAN yaratilmaydi (bu normal holat).
--
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
with d as (
  select r.kassa_code, r.tur, r.rejim, r.qiymat, r.izoh, r.faol,
         case when r.tur = 'usd' then 'USD' else 'Naqd' end as lbl,
         k.id   as kassa_id,
         k.name as kassa_nom,
         ks.n   as kassa_soni,
         c.code as hisob_kod,
         cs.n   as hisob_soni,
         coalesce(b.uzs, 0) as bal_uzs,
         coalesce(b.fc,  0) as bal_fc,
         exists (select 1 from entry e
                  where e.ext_ref = 'kassa_fix:2026-08-13:' || r.kassa_code || ':' || r.tur) as bor
    from kassa_togrilash_reja r
    left join lateral (
      select count(*) as n from accounts a
       where a.code = r.kassa_code and a.section = 'pul' and a.is_active
         and a.pul_turi is null and coalesce(a.currency, 'UZS') = 'UZS'
    ) ks on true
    left join lateral (
      select a.id, a.name from accounts a
       where a.code = r.kassa_code and a.section = 'pul' and a.is_active
         and a.pul_turi is null and coalesce(a.currency, 'UZS') = 'UZS'
       order by a.code limit 1
    ) k on true
    left join lateral (
      select count(*) as n from accounts x
       where x.parent_id = k.id and x.is_active
         and (case when r.tur = 'usd' then coalesce(x.currency, 'UZS') = 'USD'
                   else x.pul_turi = 'naqd' and coalesce(x.currency, 'UZS') = 'UZS' end)
    ) cs on true
    left join lateral (
      select x.id, x.code from accounts x
       where x.parent_id = k.id and x.is_active
         and (case when r.tur = 'usd' then coalesce(x.currency, 'UZS') = 'USD'
                   else x.pul_turi = 'naqd' and coalesce(x.currency, 'UZS') = 'UZS' end)
       order by x.code limit 1
    ) c on true
    left join v_hisob_bal b on b.account_id = c.id
),
p as (
  select d.*,
         case when d.tur = 'usd' then d.bal_fc else d.bal_uzs end as hozirgi,
         case when d.rejim = 'absolut' then d.qiymat
              else (case when d.tur = 'usd' then d.bal_fc else d.bal_uzs end) + d.qiymat
         end as maqsad,
         conv_baza_kurs('USD') as kurs_usd,
         (select a.code from accounts a where a.id = boshlangich_kapital_id()) as kap_kod
    from d
),
q as (
  select p.*, round(p.maqsad - p.hozirgi, 2) as farq from p
)
select q.kassa_code,
       coalesce(q.kassa_nom, '—')                          as kassa,
       q.lbl                                               as tur,
       q.rejim,
       coalesce(q.hisob_kod, '❌ yo''q')                    as hisob,
       case when q.tur = 'usd' then 'USD' else 'so''m' end as birlik,
       q.hozirgi,
       q.maqsad,
       q.farq,
       case when q.tur = 'usd' then round(abs(q.farq) * q.kurs_usd, 2)
            else abs(q.farq) end                           as summa_uzs,
       case when q.tur = 'usd' then abs(q.farq) end        as fc_amount,
       case when q.tur = 'usd' then q.kurs_usd end         as kurs,
       q.bal_uzs                                           as hisob_qoldiq_uzs,
       case when q.farq > 0
              then 'Dt ' || coalesce(q.hisob_kod, '?') || ' / Kt ' || coalesce(q.kap_kod, '?')
            when q.farq < 0
              then 'Dt ' || coalesce(q.kap_kod, '?') || ' / Kt ' || coalesce(q.hisob_kod, '?')
            else '—' end                                   as yonalish,
       case when q.bor then '✔' else '—' end               as avval_yozilgan,
       case
         when not q.faol
           then '⏭ faol emas — o''tkaziladi'
         when coalesce(q.kassa_soni, 0) <> 1
           then '⛔ KASSA TOPILMADI (' || coalesce(q.kassa_soni, 0)::text || ' ta mos hisob)'
         when coalesce(q.hisob_soni, 0) <> 1
           then '⛔ BOLA-HISOB TOPILMADI (' || coalesce(q.hisob_soni, 0)::text || ' ta) — skript hisob OCHMAYDI'
         when q.kap_kod is null
           then '⛔ BOSHLANG''ICH KAPITAL HISOBI YO''Q'
         when q.bor
           then '⏭ allaqachon yozilgan (ext_ref bor) — o''tkaziladi'
         when q.farq = 0
           then '⏭ farq 0 — yozuv UMUMAN yaratilmaydi'
         when q.tur = 'usd' and coalesce(q.kurs_usd, 0) <= 0
           then '⛔ USD KURSI YO''Q — hech narsa yozilmaydi'
         else '✅ YOZILADI'
       end                                                 as qaror,
       q.izoh
  from q
 order by q.kassa_code, q.tur;
-- ⬆⬆⬆  1.3 PREVIEW shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--
--   ⛔⛔  FAQAT PREVIEW TEKSHIRILGANDAN KEYIN DAVOM ETING  ⛔⛔
--
--   Quyidagi 2.2 haqiqiy pul yozadi. Hammasi BITTA tranzaksiya:
--   biror joyda xato bo'lsa HAMMASI orqaga qaytadi.
--
-- #####################################################################

-- ---------------------------------------------------------------------
-- 2.0 FUNKSIYALAR.  PUL YOZMAYDI — faqat funksiyani yaratadi.
-- ---------------------------------------------------------------------
--  Ikkita funksiya:
--    kassa_togrilash_ish()                   -> jsonb  (butun mantiq)
--    kassa_togrilash(p_dry_run boolean=true) -> jsonb  (chaqiruvchi)
--
--  kassa_togrilash(true)  — ichki blokda hamma yozuv HAQIQATAN bajariladi,
--       o'zini tekshiruvlar ishlaydi, so'ng blok o'zini ORQAGA QAYTARADI:
--       bazada iz qolmaydi. Javobda "dry_run": true. Ya'ni bu "sanoq" emas —
--       2.2 ning aynan mashqi.
--  kassa_togrilash(false) — 🔴 haqiqiy yozuv.
--
--  Har satr NOTICE bo'lib chiqadi (Supabase natija panelidagi "Messages"),
--  yakuniy hisobot esa jsonb.
--
-- ⬇⬇⬇  2.0: SHU QATORDAN pastdagi oxirgi `comment on function
--      kassa_togrilash...;` QATORIGACHA BELGILANG  ⬇⬇⬇
create or replace function kassa_togrilash_ish()
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  -- ⚙️ Yozuv belgisi. ext_ref = '<batch>:<kassa_code>:<tur>' -> takroriy RUN
  --    pulni ikki marta yozmaydi. ROLLBACK ham shu belgi bo'yicha.
  v_batch  text := 'kassa_fix:2026-08-13';
  -- ⚙️ Yozuv sanasi. UZB vaqti (Supabase UTC'da yuradi — current_date emas).
  p_sana   date := (now() at time zone 'Asia/Tashkent')::date;
  -- entry.source: 'manual' — bazada cheklov bo'lsa ham ruxsat etilgan qiymat.
  v_source text := 'manual';

  v_kapital  uuid;
  v_kap_code text;
  v_kurs     numeric;

  r        record;
  v_soni   int;
  v_kassa  uuid;
  v_knom   text;
  v_acc    uuid;
  v_acode  text;
  v_lbl    text;

  v_oldin  numeric;
  v_maqsad numeric;
  v_farq   numeric;
  v_uzs    numeric;
  v_fc     numeric;
  v_keyin  numeric;
  v_yon    text;
  v_entry  uuid;
  v_ext    text;
  v_dt     numeric;
  v_kt     numeric;
  v_xato   int;
  v_bfarq  numeric;

  n_reja   int := 0;
  n_yoz    int := 0;
  n_otkaz  int := 0;
  n_nol    int := 0;
  v_jami   numeric := 0;
  v_detal  jsonb := '[]'::jsonb;
begin
  -- ---- Qarshi tomon: boshlang'ich kapital -----------------------------
  v_kapital := boshlangich_kapital_id();
  if v_kapital is null then
    raise exception 'Boshlang''ich kapital hisobi topilmadi — PROVODKA_KAPITAL.sql RUN qilinganmi?'
      using hint = 'accounts da type=kapital va name=Boshlangich kapital bo''lgan faol hisob bo''lishi kerak.';
  end if;
  select code into v_kap_code from accounts where id = v_kapital;

  -- ---- USD kursi (faqat usd satri uchun kerak, quyida tekshiriladi) ----
  v_kurs := conv_baza_kurs('USD');

  select count(*) into n_reja from kassa_togrilash_reja where faol;
  if n_reja = 0 then
    raise exception 'TO''XTADI: kassa_togrilash_reja da birorta faol qator yo''q — 1-BOSQICH RUN qilinganmi?';
  end if;

  raise notice 'Kapital hisob: % (%) | sana: % | belgi: % | USD kurs: %',
    v_kap_code, v_kapital, p_sana, v_batch, coalesce(v_kurs, 0);

  -- ---- Har reja qatori uchun ------------------------------------------
  for r in
    select kassa_code, tur, rejim, qiymat
      from kassa_togrilash_reja
     where faol
     order by kassa_code, tur
  loop
    v_lbl := case when r.tur = 'usd' then 'USD' else 'Naqd' end;

    -- (1) Kassa. Shartlar 0.1 va 1.3 PREVIEW bilan AYNAN bir xil.
    select count(*) into v_soni
      from accounts a
     where a.code = r.kassa_code and a.section = 'pul' and a.is_active
       and a.pul_turi is null and coalesce(a.currency, 'UZS') = 'UZS';

    if v_soni <> 1 then
      -- ⚠️ raise format satri BITTA literal bo'lishi SHART. Uzun matn -> USING HINT.
      raise exception 'Kassa % — % ta mos hisob topildi (aniq 1 ta kerak). HAMMASI BEKOR QILINDI.',
        r.kassa_code, v_soni
        using hint = 'Talab: section=pul, is_active, pul_turi is null, currency=UZS. 0.1 preflight natijasini tekshiring.';
    end if;

    select a.id, a.name into v_kassa, v_knom
      from accounts a
     where a.code = r.kassa_code and a.section = 'pul' and a.is_active
       and a.pul_turi is null and coalesce(a.currency, 'UZS') = 'UZS'
     order by a.code limit 1;

    -- (2) Bola-hisob. 🔴 SKRIPT HISOB OCHMAYDI — bu to'g'rilash skripti.
    select count(*) into v_soni
      from accounts x
     where x.parent_id = v_kassa and x.is_active
       and (case when r.tur = 'usd' then coalesce(x.currency, 'UZS') = 'USD'
                 else x.pul_turi = 'naqd' and coalesce(x.currency, 'UZS') = 'UZS' end);

    if v_soni <> 1 then
      raise exception 'Kassa % ("%") — "%" bola-hisobi % ta topildi (aniq 1 ta kerak). HAMMASI BEKOR QILINDI.',
        r.kassa_code, coalesce(v_knom, '?'), v_lbl, v_soni
        using hint = 'Bu TOGRILASH skripti — hisob OCHMAYDI. Hisobni sozlamalardan oching yoki reja qatorini faol=false qiling.';
    end if;

    select x.id, x.code into v_acc, v_acode
      from accounts x
     where x.parent_id = v_kassa and x.is_active
       and (case when r.tur = 'usd' then coalesce(x.currency, 'UZS') = 'USD'
                 else x.pul_turi = 'naqd' and coalesce(x.currency, 'UZS') = 'UZS' end)
     order by x.code limit 1;

    -- (3) Takroriy RUN himoyasi
    v_ext := v_batch || ':' || r.kassa_code || ':' || r.tur;
    if exists (select 1 from entry where ext_ref = v_ext) then
      n_otkaz := n_otkaz + 1;
      raise notice '  o''tkazildi  % · % — avval yozilgan (%)', r.kassa_code, v_lbl, v_ext;
      continue;
    end if;

    -- (4) HOZIRGI qoldiq — mavjud yordamchi v_hisob_bal dan.
    --     usd -> fc (DOLLAR miqdori), naqd -> uzs (so'm).
    if r.tur = 'usd' then
      select b.fc  into v_oldin from v_hisob_bal b where b.account_id = v_acc;
    else
      select b.uzs into v_oldin from v_hisob_bal b where b.account_id = v_acc;
    end if;
    v_oldin := coalesce(v_oldin, 0);

    -- (5) Maqsad va farq
    v_maqsad := case when r.rejim = 'absolut' then r.qiymat else v_oldin + r.qiymat end;
    v_farq   := round(v_maqsad - v_oldin, 2);

    if v_farq = 0 then
      n_nol := n_nol + 1;
      raise notice '  farq 0  % · % — yozuv YARATILMADI (qoldiq allaqachon %)',
        r.kassa_code, v_lbl, v_maqsad;
      continue;
    end if;

    -- (6) So'm summasi va fc_amount
    if r.tur = 'usd' then
      if coalesce(v_kurs, 0) <= 0 then
        raise exception 'USD kursi topilmadi — HECH NARSA YOZILMADI (% · %).', r.kassa_code, v_lbl
          using hint = 'conv_baza_kurs(USD) null qaytardi. Valyuta bolimida kursni Aros dan import qiling yoki currency_rate ga USD -> UZS kursini qoshing, song qayta RUN qiling.';
      end if;
      v_fc  := abs(v_farq);
      v_uzs := round(abs(v_farq) * v_kurs, 2);
    else
      v_fc  := null;
      v_uzs := abs(v_farq);
    end if;

    if v_uzs <= 0 then
      raise exception 'So''m summasi % bo''lib chiqdi (% · %) — hammasi bekor qilindi.',
        v_uzs, r.kassa_code, v_lbl;
    end if;

    v_yon := case when v_farq > 0 then 'Dt ' || v_acode || ' / Kt ' || v_kap_code
                  else 'Dt ' || v_kap_code || ' / Kt ' || v_acode end;

    -- (7) Yozuv sarlavhasi. description "Kassa to'g'rilash" bilan BOSHLANADI.
    insert into entry(entry_date, description, source, status, created_by, ext_ref, fc_rate)
    values (p_sana,
            'Kassa to''g''rilash — ' || coalesce(v_knom, r.kassa_code) || ' · ' || v_lbl
              || ' (' || case when v_farq > 0 then '+' else '-' end
              || abs(v_farq)::text || ' '
              || case when r.tur = 'usd' then 'USD' else 'so''m' end || ')',
            v_source, 'posted', 'kassa_togrilash', v_ext,
            case when r.tur = 'usd' then v_kurs end)
    returning id into v_entry;

    -- (8) Satrlar. debit/credit HECH QACHON manfiy emas — belgi tomonni tanlaydi.
    --     fc_amount FAQAT valyuta hisobi satriga (v_hisob_bal ishorani
    --     debit>0 bo'yicha oladi, shuning uchun abs qiymat yetadi).
    insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
    values (v_entry, v_acc,
            case when v_farq > 0 then v_uzs else 0 end,
            case when v_farq < 0 then v_uzs else 0 end,
            v_fc);

    insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
    values (v_entry, v_kapital,
            case when v_farq < 0 then v_uzs else 0 end,
            case when v_farq > 0 then v_uzs else 0 end,
            null);

    -- check_entry_balanced DEFERRED — u COMMIT paytida ishlaydi va o'sha
    -- yerdagi xato tushunarsiz bo'ladi (dry-run da esa umuman ishlamaydi),
    -- shuning uchun o'zimiz darrov tekshiramiz.
    select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
      into v_dt, v_kt from entry_line where entry_id = v_entry;
    if v_dt <> v_kt then
      raise exception 'Yozuv muvozanatda emas: Dt=% Kt=% (% · %)', v_dt, v_kt, r.kassa_code, v_lbl;
    end if;

    -- (a) TEKSHIRUV: yangi qoldiq AYNAN maqsadga tengmi
    if r.tur = 'usd' then
      select b.fc  into v_keyin from v_hisob_bal b where b.account_id = v_acc;
    else
      select b.uzs into v_keyin from v_hisob_bal b where b.account_id = v_acc;
    end if;
    v_keyin := coalesce(v_keyin, 0);

    if round(v_keyin, 2) <> round(v_maqsad, 2) then
      raise exception 'TEKSHIRUV XATO (% · %): qoldiq % bo''ldi, % kutilgan edi — hammasi bekor qilindi.',
        r.kassa_code, v_lbl, v_keyin, v_maqsad;
    end if;

    insert into kassa_togrilash_log(batch, kassa_code, tur, hisob_id, hisob_code,
                                    rejim, oldin, maqsad, farq, yonalish, kurs,
                                    summa_uzs, keyin, entry_id, ext_ref)
    values (v_batch, r.kassa_code, r.tur, v_acc, v_acode,
            r.rejim, v_oldin, v_maqsad, v_farq, v_yon,
            case when r.tur = 'usd' then v_kurs end,
            v_uzs, v_keyin, v_entry, v_ext);

    v_detal := v_detal || jsonb_build_array(jsonb_build_object(
      'kassa',     r.kassa_code,
      'kassa_nom', v_knom,
      'tur',       r.tur,
      'hisob',     v_acode,
      'rejim',     r.rejim,
      'birlik',    case when r.tur = 'usd' then 'USD' else 'UZS' end,
      'oldin',     v_oldin,
      'maqsad',    v_maqsad,
      'farq',      v_farq,
      'yonalish',  v_yon,
      'summa_uzs', v_uzs,
      'fc_amount', v_fc,
      'kurs',      case when r.tur = 'usd' then v_kurs end,
      'ext_ref',   v_ext));

    n_yoz  := n_yoz + 1;
    v_jami := v_jami + v_uzs;
    raise notice '  yozildi  % · %  %  |  oldin % -> keyin %  (so''m %)',
      r.kassa_code, v_lbl, v_yon, v_oldin, v_keyin, v_uzs;
  end loop;

  -- ---- O'Z-O'ZINI TEKSHIRISH ------------------------------------------
  -- Bu yerdan chiqadigan har qanday xato BUTUN skriptni orqaga qaytaradi.

  -- (b) Har yozuvda aniq 2 satr va Dt = Kt
  select count(*) into v_xato
    from entry e
    join lateral (
      select count(*) as n, coalesce(sum(l.debit), 0) as dt,
             coalesce(sum(l.credit), 0) as kt
        from entry_line l where l.entry_id = e.id
    ) s on true
   where e.ext_ref like v_batch || ':%'
     and e.is_deleted = false
     and (s.n <> 2 or s.dt <> s.kt);

  if v_xato > 0 then
    raise exception 'TEKSHIRUV XATO: % ta yozuv noto''g''ri tuzilgan (satr soni yoki Dt<>Kt)', v_xato;
  end if;

  -- (c) P&L'ga tegmadimi — daromad/xarajat satri bo'lmasligi SHART
  select count(*) into v_xato
    from entry e
    join entry_line l on l.entry_id = e.id
    join accounts a   on a.id = l.account_id
   where e.ext_ref like v_batch || ':%'
     and e.is_deleted = false
     and a.type in ('daromad', 'xarajat');

  if v_xato > 0 then
    raise exception 'TEKSHIRUV XATO: % ta satr daromad/xarajat hisobiga tushib qolgan (P&L shishadi)', v_xato;
  end if;

  -- (d) Payme/Click hisoblariga TEGILMADIMI
  select count(*) into v_xato
    from entry e
    join entry_line l on l.entry_id = e.id
    join accounts a   on a.id = l.account_id
   where e.ext_ref like v_batch || ':%'
     and e.is_deleted = false
     and coalesce(a.pul_turi, '') in ('click', 'payme');

  if v_xato > 0 then
    raise exception 'TEKSHIRUV XATO: % ta satr click/payme hisobiga tushib qolgan — hammasi bekor qilindi.', v_xato;
  end if;

  -- (e) Balans tenglikda qoldimi (AKTIV = PASSIV + KAPITAL)
  select coalesce(sum(case when bolim = 'AKTIV' then amount else 0 end)
                - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end), 0)
    into v_bfarq
    from balans(p_sana);

  if abs(v_bfarq) > 0.01 then
    raise exception 'TEKSHIRUV XATO: balans tenglikda emas, farq = % — hammasi bekor qilindi.', v_bfarq;
  end if;

  raise notice '--- ✅ TUGADI: % yozuv | % o''tkazildi | % farqsiz | jami % so''m | balans farqi %',
    n_yoz, n_otkaz, n_nol, v_jami, v_bfarq;

  return jsonb_build_object(
    'ok',            true,
    'yozildi',       n_yoz,
    'otkazildi',     n_otkaz,
    'farqsiz',       n_nol,
    'reja_qator',    n_reja,
    'jami_som',      v_jami,
    'kapital_hisob', v_kap_code,
    'usd_kurs',      v_kurs,
    'sana',          p_sana,
    'belgi',         v_batch,
    'balans_farqi',  v_bfarq,
    'satrlar',       v_detal);
end
$$;

-- ---------------------------------------------------------------------
-- 2.0.b Chaqiruvchi — DRY-RUN shu yerda hal qilinadi
-- ---------------------------------------------------------------------
-- Ichki `begin ... exception ... end` = SUBTRANZAKSIYA: ichida yozilgan
-- hamma narsa xato ushlanganda bekor bo'ladi. Dry-run uchun ataylab
-- 'DRYRN' kodli xato ko'tariladi va o'sha yerda ushlanadi -> hamma yozuv
-- orqaga qaytadi, natija esa DETAIL orqali qo'ldan-qo'lga o'tadi.
-- Boshqa har qanday xato (kurs yo'q, hisob topilmadi, tekshiruv, Dt<>Kt)
-- USHLANMAYDI — u yuqoriga chiqadi va butun tranzaksiyani qaytaradi.
create or replace function kassa_togrilash(p_dry_run boolean default true)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_natija jsonb;
  v_detail text;
begin
  begin
    v_natija := kassa_togrilash_ish() || jsonb_build_object('dry_run', p_dry_run);

    if p_dry_run then
      raise exception using errcode = 'DRYRN',
        message = 'DRY-RUN — hech narsa yozilmadi',
        detail  = v_natija::text;
    end if;

    v_natija := v_natija || jsonb_build_object(
      'izoh', 'YOZILDI — haqiqiy pul. 3-BOSQICH tekshiruvlarini RUN qiling.');
  exception when sqlstate 'DRYRN' then
    get stacked diagnostics v_detail = pg_exception_detail;
    v_natija := (v_detail::jsonb) || jsonb_build_object(
      'izoh', 'DRY-RUN: hammasi bajarildi va ORQAGA QAYTARILDI — bazada iz yo''q');
  end;

  return v_natija;
end
$$;

revoke all on function kassa_togrilash_ish() from public, anon;
revoke all on function kassa_togrilash(boolean) from public, anon;

comment on function kassa_togrilash_ish() is
  'Kassa qoldig''ini rejaga (kassa_togrilash_reja) keltiradi: Dt/Kt kassa bola-hisobi '
  'va boshlang''ich kapital. To''g''ridan chaqirmang — kassa_togrilash() orqali. '
  'PROVODKA_KASSA_TOGRILASH.sql.';

comment on function kassa_togrilash(boolean) is
  'kassa_togrilash_ish() chaqiruvchisi. p_dry_run=true -> hammasi bajariladi va '
  'orqaga qaytariladi (bazada iz yo''q), false -> haqiqiy yozuv. '
  'Idempotent: ext_ref = kassa_fix:2026-08-13:<kassa_code>:<tur>.';
-- ⬆⬆⬆  2.0 SHU QATORGACHA BELGILANG (funksiyalar tayyor)  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.1 ⭐ MAJBURIY DRY-RUN — PUL YOZMAYDI (argument: true)
-- ---------------------------------------------------------------------
--  Nima bo'ladi: yozuvlar HAQIQATAN yoziladi, 5 ta tekshiruv (Dt=Kt,
--  qoldiq=maqsad, P&L, payme/click, balans) ishlaydi — so'ng HAMMASI
--  orqaga qaytariladi. Bazada iz qolmaydi.
--
--  Natijani o'qing:
--    • "dry_run": true      — ha, hech narsa yozilmadi
--    • "yozildi"            — 2.2 da nechta yozuv paydo bo'ladi
--    • "farqsiz"            — farq 0 bo'lgani uchun yozuv yaratilmagan satrlar
--    • "otkazildi"          — ext_ref allaqachon bor (takroriy RUN)
--    • "jami_som"           — 1.3 PREVIEW dagi summa_uzs yig'indisi bilan MOS kelsin
--    • "satrlar"            — har satr: oldin -> maqsad, farq, yonalish, kurs
--    • "balans_farqi": 0    — balans tenglikda qoladi
--  Xato chiqsa (masalan "USD kursi topilmadi") — 2.2 NI RUN QILMANG.
--
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG (DRY-RUN — YOZMAYDI)  ⬇⬇⬇
select jsonb_pretty(kassa_togrilash(true)) as dry_run_natija;
-- ⬆⬆⬆  2.1 DRY-RUN shu yerda tugadi  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.2 🔴🔴🔴 YOZISH — HAQIQIY PUL (argument: false)
-- ---------------------------------------------------------------------
--  Shartlar (hammasi bajarilsin):
--    • 0.1 / 0.2 / 0.4 hammasi ✅ OK
--    • 1.3 PREVIEW da ⛔ YO'Q
--    • 2.0 funksiyalar yaratilgan
--    • 2.1 DRY-RUN natijasi to'g'ri (yozildi / jami_som kutilgandek,
--      balans_farqi = 0)
--    • n8n `Aros Provodka - Auto Sync` (7MSHrXnz9cGAFBTh) DEACTIVATE
--
--  Bitta `select` = bitta tranzaksiya. Funksiya ichida xato chiqsa
--  — YOZILGAN HAMMA NARSA ORQAGA QAYTADI.
--
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG (YOZADI!)  ⬇⬇⬇
select jsonb_pretty(kassa_togrilash(false)) as yozish_natijasi;
-- ⬆⬆⬆  2.2 YOZISH shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  3-BOSQICH — TEKSHIRUVLAR (yozgandan KEYIN).  HECH BIRI YOZMAYDI.
-- #####################################################################
--  Har tekshiruvni ALOHIDA belgilab RUN qiling. `natija` ustuniga qarang:
--  hammasi ✅ OK bo'lsa ish tugadi. Bittasi ham
--  "❌ MUAMMO — ROLLBACK qiling" bo'lsa -> pastdagi ROLLBACK bo'limi.

-- ---------------------------------------------------------------------
-- ⚠️ (a) YANGI QOLDIQ MAQSADGA TENGMI
--    `maqsad` — yozuv paytida hisoblangan (kassa_togrilash_log dan),
--    `hozirgi` — HOZIRGI jonli qoldiq. Ikkalasi teng bo'lishi kerak.
--    Farq bo'lsa: yozuvdan KEYIN o'sha hisobga boshqa harakat tushgan
--    (sinxron?) — jurnalni tekshiring, bu majburiy rollback emas.
-- ---------------------------------------------------------------------
with oxirgi as (
  select distinct on (kassa_code, tur) *
    from kassa_togrilash_log
   order by kassa_code, tur, id desc
)
select o.kassa_code,
       o.tur,
       o.hisob_code,
       case when o.tur = 'usd' then 'USD' else 'so''m' end as birlik,
       o.oldin,
       o.farq,
       o.maqsad,
       case when o.tur = 'usd' then coalesce(b.fc, 0) else coalesce(b.uzs, 0) end as hozirgi,
       o.yonalish,
       o.summa_uzs,
       case when round(case when o.tur = 'usd' then coalesce(b.fc, 0)
                            else coalesce(b.uzs, 0) end, 2) = round(o.maqsad, 2)
            then '✅ OK' else '❌ MUAMMO — tekshiring' end as natija
  from oxirgi o
  left join v_hisob_bal b on b.account_id = o.hisob_id
 order by o.kassa_code, o.tur;

-- ---------------------------------------------------------------------
-- ⚠️ (b) HAR YOZUVDA Dt = Kt va aniq 2 satr
-- ---------------------------------------------------------------------
select 'Har yozuvda Dt = Kt (2 satr)' as tekshiruv,
       count(*)                       as muvozanatsiz_yozuv,
       case when count(*) = 0 then '✅ OK'
            else '❌ MUAMMO — ROLLBACK qiling' end as natija
  from (select e.id
          from entry e
          join entry_line l on l.entry_id = e.id
         where e.ext_ref like 'kassa_fix:%' and e.is_deleted = false
         group by e.id
        having sum(l.debit) <> sum(l.credit) or count(*) <> 2) x;

-- ---------------------------------------------------------------------
-- ⚠️ (c) BALANS TENGLIKDA (AKTIV = PASSIV + KAPITAL)
-- ---------------------------------------------------------------------
select 'Balans tengligi' as tekshiruv,
       b.farq,
       case when abs(b.farq) <= 0.01 then '✅ OK'
            else '❌ MUAMMO — ROLLBACK qiling' end as natija
  from (select coalesce(sum(case when bolim = 'AKTIV' then amount else 0 end)
                      - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end), 0) as farq
          from balans((now() at time zone 'Asia/Tashkent')::date)) b;

-- ---------------------------------------------------------------------
-- ⚠️ (d) P&L GA TUSHMADIMI — daromad/xarajat satri 0 bo'lishi SHART
-- ---------------------------------------------------------------------
select 'P&L ga tegmadi (daromad/xarajat satri)' as tekshiruv,
       count(*) filter (where a.type in ('daromad', 'xarajat')) as pnl_satr,
       count(*)                                                 as jami_satr,
       case when count(*) filter (where a.type in ('daromad', 'xarajat')) = 0
            then '✅ OK' else '❌ MUAMMO — ROLLBACK qiling' end  as natija,
       'Qarshi tomon kapital bo''lgani uchun hech qanday P&L satri bo''lmasligi kerak' as izoh
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a   on a.id = l.account_id
 where e.ext_ref like 'kassa_fix:%' and e.is_deleted = false;

-- ---------------------------------------------------------------------
-- ⚠️ (e) PAYME / CLICK TEGILMAGANMI
--    e1: to'g'rilash yozuvlarida click/payme satri bormi (0 bo'lishi SHART)
-- ---------------------------------------------------------------------
select 'Payme/Click tegilmadi' as tekshiruv,
       count(*) filter (where coalesce(a.pul_turi, '') in ('click', 'payme')) as tegilgan_satr,
       count(*)                                                              as jami_satr,
       case when count(*) filter (where coalesce(a.pul_turi, '') in ('click', 'payme')) = 0
            then '✅ OK' else '❌ MUAMMO — ROLLBACK qiling' end               as natija
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a   on a.id = l.account_id
 where e.ext_ref like 'kassa_fix:%' and e.is_deleted = false;

--    e2: ko'z bilan — 5011 / 5012 ning HAMMA bola-hisoblari qoldig'i.
--        Payme va Click satrlari to'g'rilashdan OLDINGI qiymatda turishi kerak.
select k.code as kassa, k.name as kassa_nom,
       c.code as hisob, c.name as hisob_nom,
       coalesce(c.pul_turi, c.currency) as tur,
       coalesce(b.uzs, 0) as qoldiq_uzs,
       coalesce(b.fc,  0) as qoldiq_fc,
       case when coalesce(c.pul_turi, '') in ('click', 'payme')
            then 'TEGILMASLIGI KERAK' else 'to''g''rilangan yoki neytral' end as holat
  from accounts k
  join accounts c on c.parent_id = k.id and c.is_active
  left join v_hisob_bal b on b.account_id = c.id
 where k.code in ('5011', '5012')
 order by k.code, c.code;

-- ---------------------------------------------------------------------
-- (f) Yozilgan to'g'rilashlar — satrma-satr ko'rinishi
-- ---------------------------------------------------------------------
select e.ext_ref, e.entry_date, e.description, e.fc_rate,
       a.code, a.name, l.debit, l.credit, l.fc_amount
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a   on a.id = l.account_id
 where e.ext_ref like 'kassa_fix:%' and e.is_deleted = false
 order by e.ext_ref, l.debit desc;

-- ---------------------------------------------------------------------
-- (g) Log jadvali — oldin / maqsad / keyin tarixi
-- ---------------------------------------------------------------------
select id, batch, kassa_code, tur, hisob_code, rejim,
       oldin, farq, maqsad, keyin, yonalish, kurs, summa_uzs, ext_ref, yozilgan_at
  from kassa_togrilash_log
 order by id;

-- ---------------------------------------------------------------------
-- (h) 🔴 n8n `Aros Provodka - Auto Sync` (7MSHrXnz9cGAFBTh) ni
--     QAYTA ACTIVATE QILISHNI UNUTMANG.
-- ---------------------------------------------------------------------


-- #####################################################################
--  ROLLBACK — 3-BOSQICHDA ❌ chiqsa yoki summa noto'g'ri bo'lsa
-- #####################################################################
--  To'g'rilash oddiy yozuv: soft-delete yetadi (hech narsa o'chirilmaydi,
--  jurnalda usti chizilgan holda qoladi, qoldiq oldingi holatiga qaytadi).
--  Faqat `kassa_fix:` belgili yozuvlarga tegadi — boshqa hech narsaga yo'q.

-- ---------------------------------------------------------------------
-- R.1 AVVAL KO'RING — nima qaytariladi (bu select xavfsiz, yozmaydi)
-- ---------------------------------------------------------------------
select e.id, e.ext_ref, e.entry_date, e.description,
       (select sum(l.debit) from entry_line l where l.entry_id = e.id) as summa_uzs
  from entry e
 where e.ext_ref like 'kassa_fix:%' and e.is_deleted = false
 order by e.ext_ref;

-- ---------------------------------------------------------------------
-- R.2 ROLLBACK — quyidagi 5 qatorning boshidagi `-- ` ni olib tashlang
--     va BELGILAB RUN qiling. Tasodifan RUN bo'lmasin uchun izohda turibdi.
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  ROLLBACK — izohni olib tashlagach shu oraliqni belgilang  ⬇⬇⬇
-- update entry
--    set is_deleted = true,
--        deleted_at = now(),
--        deleted_by_name = 'rollback: kassa togrilash'
--  where ext_ref like 'kassa_fix:%'
--    and is_deleted = false;
-- ⬆⬆⬆  ROLLBACK shu yerda tugadi  ⬆⬆⬆

-- ---------------------------------------------------------------------
-- R.3 Rollbackdan keyin: balans farqi yana 0 bo'lsin, R.1 bo'sh chiqsin.
-- ---------------------------------------------------------------------
-- select coalesce(sum(case when bolim = 'AKTIV' then amount else 0 end)
--               - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end), 0) as farq
--   from balans((now() at time zone 'Asia/Tashkent')::date);

-- ⚠️ QAYTA YOZISH: ext_ref unique to'sig'i o'chirilgan yozuvni HAM ko'radi,
--    shuning uchun skript "avval yozilgan" deb o'tkazib yuboradi. Qayta
--    yozish uchun avval ext_ref ni bo'shatish SHART:
--
--    update entry set ext_ref = ext_ref || ':bekor:' || id::text
--     where ext_ref like 'kassa_fix:%' and is_deleted;
--
--    So'ng 1.3 PREVIEW -> 2.1 DRY-RUN -> 2.2 YOZISH. 2.0 funksiyalari joyida turadi.
--    ⚠️ "absolyut" satr qoldiqni qaytadan o'qiydi — rollbackdan keyin u
--       eski (to'g'rilanmagan) qoldiqni ko'radi va farqni yangidan hisoblaydi.
--
-- BITTA satrni qaytarish (masalan faqat Toshkent USD):
--    update entry set is_deleted = true, deleted_at = now(),
--                     deleted_by_name = 'rollback: kassa togrilash'
--     where ext_ref = 'kassa_fix:2026-08-13:5011:usd';
