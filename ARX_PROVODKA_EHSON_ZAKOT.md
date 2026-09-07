# Ehson jamg'armasi — 3 child jamg'arma + pul turlari (ZAKOT uchun) — 2026-09-07

🔴 **Asilbek: «bu faqat zakot uchun bo'ladi — esingdan chiqarma».** Zakot hisobi alohida yuritiladi; tuzilma:
`Ehson jamg'armasi` (ildiz modda/konteyner) → child jamg'arma kassalari (**Ehson soliq · Ehson asosiy · Zakot**, dinamik —
Asilbek yana qo'sha oladi) → har birida oddiy kassalardagidek **pul turi** bolalari (naqd · dollar · karta · click, dinamik).

Asilbek talabi (2026-09-07): Professional'da pul terganda «Ehson jamg'armasi» tanlansa 3 kichik kassa chiqadi → biri tanlanadi →
uning bolalari (naqd va h.k.) chiqadi → tanlanadi. Pul faqat CHIQIB ketadi, **kompaniya balansida umuman ko'rinmaydi**
(mavjud izolyatsiya: Dt xarajat moddasi — foyda/kapital kamayadi, jamg'arma qoldig'i `ehson_*` da). Ehson berishda ham avval
qaysi jamg'arma kassa → qaysi pul turidan chiqishi tanlanadi. Kassa qo'shish dinamik (admin UI).

## 0. Mavjud tizim (tekshirilgan, `PROVODKA_EHSON.sql`)
- `ehson_kassa(id, nom, izoh, is_active, xarajat_account_id)` — har jamg'arma kassasi O'Z xarajat moddasiga (94xx,
  `accounts.ehson_kassa_id = kassa.id`) ega; `_ehson_xarajat_modda(p_kassa)` moddani yaratadi/bog'laydi. v1: bitta seed
  «Ehson jamg'armasi».
- `_ehson_kirim_sync(entry)` (DEFERRED trigger): har `ehson_kassa` moddasi bo'yicha `Dt − Kt` summa > 0 → `ehson_kirim`
  (`pul_kassa_id` = Kt pul qatori, `ext_ref='entry:<id>:<kassa>'`). Bu naqsh child kassalar uchun ham AYNAN ishlaydi —
  har child o'z moddasi bilan. **Trigger mantiqi o'zgarmaydi**, faqat `pul_turi`/`valyuta`/`fc_summa` qo'shiladi.
- `ehson_ber(p)` — `kassa_id` ixtiyoriy (bitta faol bo'lsa o'zi), qoldiq `v_ehson_kassa.qoldiq` bo'yicha, advisory lock.
- `ehson_dash()` → `kassalar:[{id,nom,is_active,kirim,berildi,qoldiq}]`, `moddalar:[{kassa_id,id,code,name}]`.
- Klient: `professional-dev` accounts ro'yxatidan ehson moddalari `permFlagOk('ehson_kirim')` yo'q userga yashirinadi;
  `ehson-dev` Berish tabida `#ehbKassaSel` faqat faol kassa > 1 bo'lsa chiqadi; Kirim tabi `renderKirimKassa`.

## 1. Qarorlar (Fable)
1. **Har child jamg'arma = `ehson_kassa` qatori** (`parent_id` → ildiz). Ildiz «Ehson jamg'armasi» **konteyner** bo'lib
   qoladi: yangi kirim/berish unga YOZILMAYDI (`is_container=true`), eski yozuvlari tarixda qoladi. Har child o'z 94xx
   moddasini `_ehson_xarajat_modda` bilan oladi (nom: «Ehson jamg'armasi · Zakot»). Trigger o'zgarmaydi.
2. **Pul turi — `ehson_pul_turi(kassa_id, kod, nom, valyuta, is_active, tartib)`** jadvali (dinamik, admin). Seed har
   child uchun: naqd (UZS) · dollar (USD) · karta (UZS) · click (UZS).
3. **Kirimda pul turi `entry` ustunida** (`entry.ehson_pul_turi text`, additive): Professional kaskadida tanlanadi;
   trigger `ehson_kirim.pul_turi` ga ko'chiradi. Tanlanmagan bo'lsa (eski yo'l, hodim-dev) Kt kassadan **taxmin**:
   `accounts.currency='USD'` → dollar; `accounts.pul_turi` click/payme → click; aks holda naqd — child kassada shunday
   kod bo'lsagina, bo'lmasa null (`pul_turi` null = «belgilanmagan», UI'da ko'rsatiladi).
4. **Valyuta**: `ehson_kirim.summa` — so'm (avvalgidek, Dt modda summasi); qo'shimcha `valyuta text`, `fc_summa numeric`
   (Kt pul qatori `fc_amount`, USD bo'lsa). Dollar pul turi qoldig'i USD'da (`fc_summa`) VA so'mda ko'rsatiladi.
   `ehson_berish` ham `pul_turi`, `valyuta`, `fc_summa` (berishda dollar tanlansa summa USD'da kiritiladi, so'm ekv.
   `conv_baza_kurs('USD')` bilan; kurs yo'q → rad). Qoldiq tekshiruvi pul turi kesimida (dollar → USD, boshqa → so'm).
5. **Kompaniya balansiga ta'sir YO'Q** — eski naqsh: Dt xarajat / Kt kassa. Zakot ham xarajat (`type='xarajat'`).
6. Ruxsat: kirim — `ehson_kirim_ok()` (bayroq/admin) o'zgarmaydi; kaskad ma'lumoti (`ehson_kassa_daraxt()`) —
   authenticated + (`ehson_kirim` bayrog'i YOKI `ehson` sahifasi YOKI admin), fail-closed; kassa/pul turi boshqaruvi — admin.

## 2. SQL — `PROVODKA_EHSON_ZAKOT.sql` (additive, idempotent, `$fn$` teglar, izohda ikki dollar YO'Q; old shart:
`ehson_kassa`, `_ehson_xarajat_modda(uuid)`, `_ehson_kirim_sync(uuid)`, `ehson_ber(jsonb)`, `ehson_dash()` mavjud)
2.1 `ehson_kassa`: `add column if not exists parent_id uuid references ehson_kassa(id)`, `is_container boolean default false`,
    `tartib int default 0`. Seed (idempotent, nom bo'yicha): ildiz mavjud «Ehson jamg'armasi» → `is_container=true`;
    3 child (`Ehson soliq`, `Ehson asosiy`, `Zakot`) `parent_id=ildiz`, har biriga `_ehson_xarajat_modda(id)` (modda nomi
    «Ehson jamg'armasi · <nom>» — `_ehson_xarajat_modda` nomni `k.nom` dan oladi; kerak bo'lsa `_ehson_xarajat_modda` ni
    `create or replace` (imzo saqlanadi) qilib parent nomini prefiks qil).
2.2 `ehson_pul_turi(id uuid pk, kassa_id uuid not null references ehson_kassa, kod text not null check (kod ~ '^[a-z_]{2,20}$'),
    nom text not null, valyuta text not null default 'UZS', is_active boolean default true, tartib int default 0,
    unique (kassa_id, kod))`. RLS select `ehson_page_ok() or ehson_kirim_ok()`. Seed 4 tur × 3 child.
2.3 `ehson_kirim`: `add column if not exists pul_turi text, valyuta text, fc_summa numeric`; `ehson_berish`: shu uchtasi;
    `entry`: `add column if not exists ehson_pul_turi text` (comment: Professional kaskadi; trigger o'qiydi).
2.4 `_ehson_kirim_sync(p_entry)` **qayta e'lon** (imzo bir xil, tana PROVODKA_EHSON.sql 12.6 + pul_turi): `pul_turi :=
    coalesce(v_e.ehson_pul_turi, <taxmin Kt kassadan>)`, faqat `ehson_pul_turi` jadvalida shu kassa uchun faol kod bo'lsa;
    `valyuta`/`fc_summa` Kt pul qatoridan (`accounts.currency`, `entry_line.fc_amount`). Konteyner kassaga (is_container)
    yozuv kelsa — avvalgidek yoziladi (eski modda), `ogoh` yo'q.
2.5 `v_ehson_kassa_pul` view: `(kassa_id, pul_turi, valyuta, kirim, berildi, qoldiq, fc_kirim, fc_berildi, fc_qoldiq)`;
    `v_ehson_kassa` saqlanadi (jami). `ehson_kassa_daraxt()` → jsonb `{ildiz:{id,nom}, kassalar:[{id,nom,izoh,is_active,tartib,
    modda:{id,code,name}, pul_turlari:[{id,kod,nom,valyuta,is_active,tartib,qoldiq,fc_qoldiq}], qoldiq}]}` — Professional
    kaskadi va Ehson uchun BITTA manba.
2.6 `ehson_ber(p)` **qayta e'lon**: `p.pul_turi` (majburiy agar kassada faol pul turi bo'lsa → `pul_turi_kerak`), dollar →
    `p.fc_summa` (USD) + so'm ekv. kurs bilan (`conv_baza_kurs('USD')` mavjud bo'lsa, `to_regprocedure` YO'Q — pg_proc bilan
    tekshir; yo'q → `kurs_yoq`); qoldiq `v_ehson_kassa_pul` bo'yicha (dollar → fc, boshqa → so'm) → `qoldiq_yetmadi`;
    konteyner kassaga berish → `kassa_konteyner`. Eski chaqiruv (pul_turi'siz, kassada pul turi yo'q) avvalgidek ishlaydi.
2.7 `ehson_dash()` **qayta e'lon**: `kassalar` elementiga `parent_id, is_container, tartib, pul_turlari:[{kod,nom,valyuta,qoldiq,
    fc_qoldiq}]` qo'shiladi (eski kalitlar saqlanadi). `ehson_kirim_royxat`/`ehson_berish_royxat` qatorlariga `pul_turi,
    valyuta, fc_summa, kassa_nom` (qayta e'lon, imzo bir xil).
2.8 Admin RPC (`_ehson_is_admin()`): `ehson_kassa_saqla(p jsonb)` → `{id?, nom, izoh, is_active, tartib}` (yangi → child,
    parent=ildiz, modda `_ehson_xarajat_modda`, sukut 4 pul turi seed; takror nom → `takror`; deaktiv faqat qoldiq 0 bo'lsa →
    `qoldiq_bor`); `ehson_pul_turi_saqla(p jsonb)` → `{id?, kassa_id, kod, nom, valyuta, is_active, tartib}` (deaktiv qoldiq 0
    bo'lsa). `ehson_tarix` ga yoziladi.
2.9 `trg_ehson_kirim_guard` o'zgarmaydi (child moddalarda `ehson_kassa_id` bor → guard avtomat). Yakuniy tekshiruv bloki
    (pg_proc bilan, `to_regprocedure` EMAS).

## 3. Professional (`professional-dev.html`) — kaskad
- Modda tanlash modalida (`#moddaModal`/`moddaList`, adv: `#accModal`/`accGroups`) ehson moddalari **alohida guruh
  «Ehson jamg'armasi»** (ildiz nomi) ostida: child kassalar ro'yxati (`ehson_kassa_daraxt()`, swr 5 daq; RPC yo'q → eski xatti-
  harakat). Child tanlansa → 2-qadam: pul turi chiplari (naqd/dollar/karta/click, qoldiq bilan) → tanlangach modda =
  child moddasi, `ehsonPulTuri=kod`. Konteyner (ildiz) moddasi tanlanmaydi (ro'yxatda yo'q).
- Saqlashda `entry.ehson_pul_turi` (4 yo'l: `doSaveSimple`, `doSavePending`, `confirmTaqsim`, `doSaveAdv` — adv'da Dt satr
  moddasi ehson child bo'lsa). 🔴 `ehson_pul_turi` payloadga faqat qiymat bo'lsa qo'shiladi (ustun yo'q bazada 42703 bo'lmasin).
  Dollar tanlansa Kt kassa USD bo'lishi tekshiriladi (klient ogohlantirish, bloklamaydi — server taxmin qiladi).
- Tanlangan ko'rinish: «Ehson jamg'armasi › Zakot › Naqd» chip. `permFlagOk('ehson_kirim')` yo'q → guruh ko'rinmaydi (hozirgidek).

## 4. Ehson (`ehson-dev.html`)
- **Kirim tabi**: jamg'arma kartasi → ildiz + child kartalar (har birida pul turi qatorlari: naqd/dollar(USD + so'm)/karta/click
  qoldiq); tarix qatorida `kassa_nom · pul_turi`.
- **Berish tabi**: `#ehbKassaSel` → faqat child (konteyner yo'q) + har birida pul turi select (`#ehbPulSel`, qoldiq bilan);
  dollar → summa USD'da (label o'zgaradi, so'm ekv. ko'rsatiladi); `ehson_ber` ga `kassa_id, pul_turi, fc_summa`. Xato kodlari:
  `pul_turi_kerak`, `kurs_yoq`, `kassa_konteyner`.
- **Bosh/Bu oy/Tarix**: kassa + pul turi filtri; stat kartalar child kesimida.
- **Admin «Jamg'arma kassalari»** (Kirim tabi ichida karta yoki Bosh'da): child qo'shish/tahrir/deaktiv, har childda pul turi
  qo'shish/tahrir/deaktiv (`ehson_kassa_saqla`, `ehson_pul_turi_saqla`), inline forma, tasdiq `confirm()` YO'Q.
- RPC/ustun yo'q bazada → eski ko'rinish, banner.

## 5. Bosqichlar
1. SQL (coder → tester) — Asilbek RUN. 2. Professional kaskad (coder → tester). 3. Ehson UI (coder + designer → tester).
4. CLAUDE.md + memory. Hodim-dev TEGILMAYDI (ehson moddalari u yerda bayroqsiz yashirin; bayroqli user hodim'dan yozsa
   pul turi Kt kassadan taxmin qilinadi).

## 6. Savollar (Asilbek) — sukut bilan qurildi
- Dollar pul turida summa USD'da yuritiladi (so'm ekv. kurs bilan) — sukut HA.
- Ildiz «Ehson jamg'armasi» ga endi yangi kirim yozilmaydi (faqat childlar) — sukut HA; eski yozuvlar tarixda qoladi.
- Zakot uchun alohida hisobot/limit (nisob, 2.5%) — hozircha YO'Q, keyingi bosqich.
