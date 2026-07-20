# Aros Provodka

Ikki tomonlama buxgalteriya (double-entry) web-app. Aros Market'ning ichki pul-hisobi.
Aros'dan **faqat o'qiydi**, hech qachon yozmaydi.

## Stack

- Frontend: statik HTML fayllar, GitHub Pages. Build yo'q, framework yo'q.
- Backend: Supabase (`kxzerccdpcltmzrxutlo.supabase.co`) — PostgreSQL + Auth + RLS.
- Aros bilan bog'lanish: n8n webhooklar (`n8n.arosmarket.com`), Aros API `api.aros.uz`.
- Til: interfeys o'zbekcha (lotin). Kod izohlari ham o'zbekcha.

## Kutubxonalar — `vendor/` (repoda, CDN emas)

Tezlik uchun hamma tashqi resurs repoga ko'chirilgan — GitHub Pages'dan bitta domendan
keladi (DNS/TLS yo'q, brauzer keshlaydi). CDN (`jsdelivr`/`unpkg`/Google Fonts) **ishlatilmaydi**.

- `vendor/supabase-2.110.6.js` — Supabase UMD (bitta fayl). Global: `window.supabase.createClient(url,key)`.
  **`import ... +esm` YO'Q.** Versiya yangilansa fayl nomini o'zgartir (kesh) va 12 faylda `<script src>`ni yangila.
- `vendor/lucide-1.24.0.js` — Lucide UMD. Global: `window.lucide.createIcons()` (avvalgidek `icons()`).
- `vendor/inter.woff2` — Inter variable font (100–900). `@font-face` har faylning `<style>` boshida.

Head tartibi (hamma faylda): `<link rel=icon>` → supabase `preconnect` → 10-11 ta `prefetch`
(qolgan sahifalar) → `<script src="vendor/lucide...defer">` → `<script src="vendor/supabase...defer">` → `<style>`.
Vendor skriptlar `defer`, module skript ham defer (implicit) — shuning uchun module ishga tushganda
`window.supabase`/`window.lucide` tayyor bo'ladi. **Endi har faylda aniq 3 ta `</script>`**
(lucide + supabase + module) — avvalgi 2 emas. 3 dan farq bo'lsa fayl buzilgan.

### Tezlik naqshlari (hamma faylda bir xil)

- **Auth gate darrov:** `boot()` `localStorage`'da `sb-kxzerccdpcltmzrxutlo-auth-token` borligini
  **sinxron** tekshiradi → bo'lsa app'ni DARROV ko'rsatadi (`enterApp`, `appShown` guard bilan bir marta),
  sessiyani fonda `getSession()` bilan tekshiradi; yaroqsiz bo'lsa `signOut()`+`reload()`. Ekran miltillamaydi.
- **stale-while-revalidate:** module boshida `swrGet(n,maxAge=300000)`/`swrSet(n,v)` yordamchilari
  (`sessionStorage`, kalit `prov-swr:<sahifa>:<n>`, 5 daqiqa TTL). Sahifaning **asosiy o'qishi** shu bilan
  o'ralgan: kesh bo'lsa DARROV ko'rsatiladi (skeleton emas — haqiqiy raqam), fonda yangi olinadi, jimgina
  almashtiriladi; kesh bo'lmasa "Yuklanmoqda…" placeholder; xato bo'lsa mavjud keshni saqlaydi.
  **Yozuvdan keyin (add/edit/delete/sync/import) asosiy o'qish `fresh` rejimda** — keshdan bermaydi,
  yangi olib `swrSet` qiladi. Kalitga filtr/davr parametrlari kiradi (masalan `pnl:{from,to}`).
- **Parallel init:** `init()` dagi mustaqil `await`lar `Promise.all([...])`ga yig'ilgan (loadRole + hisoblar + asosiy o'qish).
- **`boot();` chaqiruvi modulning ENG OXIRIDA turishi shart** (12 faylning hammasida). Sababi:
  keshli holatda `boot()` → `enterApp()` → `init()` → `loadKassalar()` → `renderKassalar(cached)`
  zanjiri **birinchi `await`gacha butunlay sinxron** ishlaydi. `boot()` yuqorida chaqirilsa, pastdagi
  `const`/`let`lar hali initsializatsiya bo'lmagan bo'ladi → TDZ: *"Cannot access 'X' before
  initialization"* → sahifa bo'sh qoladi. Yangi top-level chaqiruv qo'shma; qo'shsang — oxiriga.

## Fayllar

| Fayl | Vazifa |
|------|--------|
| `jurnal.html` | Jurnal: sana/hisob/tur/qidiruv filtri + tahrir/o'chirish (`jurnal()`) |
| `provodka.html` | Kiritish: Kirim / Chiqim / Transfer + jurnal — **navigatsiyadan yashirilgan** |
| `professional.html` | Qo'lda ko'p satrli Dt/Kt yozuv |
| `kassa.html` | Hamma kassa qoldig'i guruh-guruh + **Konvert** tugmasi |
| `hisobot.html` | P&L zinapoyasi (`pnl()`), xarajat taqsimoti, aylanma-saldo |
| `balans.html` | Balans sanaga: Aktiv \| Passiv+Kapital (`balans()`) |
| `cashflow.html` | Pul oqimi davrga: boshi/oxiri + Kirim/Chiqim (`cashflow()`, `pul_qoldiq()`) |
| `qarzdor.html` | Debitor (4010) / kreditor (6010) |
| `filial.html` | Filiallarda turgan jonli pul |
| `valyuta.html` | Valyuta kurslari (juftlik: from → to) |
| `konvert.html` | Konvert so'rovlari: pending + tarix, admin tasdiqlaydi/rad etadi |
| `sozlama.html` | Hisob rejasi boshqaruvi |

Har fayl mustaqil: o'z login gate'i, sidebar/bnav navigatsiyasi, Supabase klienti bor.
Dizayn tizimi hamma faylda takrorlanadi (CSS o'zgaruvchilari bir xil).

Navigatsiya 12 faylda ham bir xil bo'lishi shart: **sidebar 11 ta**, **bnav 6 ta + "Ko'proq"**,
**sheet 5 ta**. Faqat `active` klassi farq qiladi.

**`provodka.html` navigatsiyada yo'q** — fayl turibdi va ishlaydi, faqat unga hech qayerdan
havola yo'q (to'g'ridan-to'g'ri URL bilan ochiladi). O'zida ham `active` element yo'q — normal.
Uni qaytarganda: sidebar+bnav'ga "Kiritish" (`circle-plus`) qo'shiladi va sanoq 12/7 bo'ladi.
Sidebar/bnav'dagi 1-o'rin hozir "Jurnal" (`scroll-text`).

**Sidebar `min-width:900px` da ko'rinadi — mobil'da u umuman yo'q.** Shuning uchun bnav'ga
sig'magan sahifalar (Professional, Kassa, Valyuta, Konvert, Sozlamalar) `#moreModal` sheet'iga tushadi
("Ko'proq" tugmasi, `openMore()`/`closeMore()`). Bnav'dan sahifa olib tashlansa, u sheet'ga
qo'shilishi **shart** — aks holda telefonda umuman ochilmaydi. Joriy sahifa sheet ichida
bo'lsa, "Ko'proq" o'zi `active` bo'ladi.

Sheet CSS'i ataylab `.mmodal`/`.msheet` deb nomlangan — `provodka.html`/`valyuta.html`dagi
mavjud `.modal`/`.sheet` bilan to'qnashmasligi uchun.

## Baza modeli

- `accounts` — hisob rejasi. `code`, `name`, `type` (aktiv/passiv/kapital/daromad/xarajat).
  - `5xxx` = pul hisoblari (kassalar). `52xx` = filial kassalari.
  - `filial_ref` — Aros cachier id (filiallar uchun). Bu hisoblar `provodka.html`/`hisobot.html`
    chiplarida ko'rinmaydi (u yerda faqat markaziy) — `kassa.html`da "Filial kassalari" guruhida chiqadi.
  - `aros_title` — markaziy kassalar Aros nomiga bog'langan ('Toshkent Kassa', 'Qashqadaryo Kassa').
  - Muhim kodlar: `4010` xaridorlar qarzi, `6010` yetkazib beruvchilar, `5011` Toshkent markaziy kassa,
    `9010` savdo tushumi, `8000` — `provodka.html`da kirim manbasi sifatida tanlanadi.
  - Yangi kod `sozlama.html`da avtomatik beriladi: kassa `50xx` (5011dan), xarajat `94xx` (9421dan),
    daromad `90xx` (9011dan) — diapazondagi eng kattasi + 1.
  - Klientda kassa = `type==='aktiv' && code.startsWith('5')` (`isKassa()`) — filial kassalari ham kiradi,
    shuning uchun ular dropdownda ko'rinadi. Chiplar esa `v_kassa_card`dan keladi.
- `entry` — provodka sarlavhasi. `is_deleted` (soft-delete), `edited_at`/`edited_by_name`, `ext_ref` (unique — takrorlanishni to'sadi).
- `entry_line` — satrlar. **Cheklov:** `debit`/`credit` manfiy bo'lolmaydi; bir satrda faqat bittasi > 0.
- `currency_rate` — `from_code` → `to_code` juftligi, `rate`, `rate_at`.
- `entry_history` — tahrir/o'chirishdan oldingi nusxa.
- `profiles` — rol (`admin` / `user`).
- `sync_state` — `transfers_from` (avtomatik sinxron qayerdan boshlangani).
- `filial_snapshot` — **bitta qator**, `id=1`. `data` jsonb (`{rows, rate}`), `total`, `synced_by_name`,
  `synced_at`. `filial.html` shu yerdan o'qiydi va "Yangilash"da upsert qiladi.

Viewlar: `v_hisob_qoldiq`, `v_kassa_qoldiq` (filiallarni chiqarib tashlaydi),
`v_current_rate` (har juftlik uchun eng oxirgisi), `v_aylanma_saldo`,
`v_pul_hisoblar` (`{id, code, name, is_filial}` — kassa filtri uchun; markaziy = 5011/5012/5110, filial = 52xx).

`v_kassa_card` — **kartalar uchun**: har kassa BITTA qator, dollar juftligi ichiga yig'ilgan.
`id, code, name, kassa_turi, parent_id, uzs, usd, usd_uzs, jami (= uzs + usd_uzs), has_usd, usd_account_id`.
Kartada katta raqam = `jami`; taqsimot satri (`uzs` so'm · `usd` $) faqat `usd > 0` bo'lsa chiqadi.
Tanlash (dropdown/konvert) uchun **`v_kassa_toliq`** kerak — u har hisobni alohida qator qilib beradi.

### `kassa_turi='xarajat_guruh'` — hodim xarajat kassalari

`5400 "Hodim xarajat kassalari"` — **konteyner hisob**, unga to'g'ridan pul yozilmaydi.
Ostidagi hodim kassalari: kod `5401+`, `parent_id` = 5400, `kassa_turi='xarajat'`,
`name` = hodim ismi, `subtitle` = "Filial · Lavozim", `taskfix_user_id`. Ularni TaskFix RPC orqali yaratadi.
Eski filial-xarajat kassalar (53xx, 56xx) `is_active=false`.

Klient qoidalari (hamma faylda bir xil):
- `kassa.html` — `xarajat_guruh` qatori **karta emas, guruh sarlavhasi**; ostiga `parent_id` shu guruhga
  qaragan bolalar `.klist`/`.krow` ro'yxati (nom + kulrang `subtitle`) bo'lib chiziladi. Guruhning o'z
  summasi umumiy `jami`ga qo'shilmaydi (bolalari alohida sanaladi).
- **Konteyner hech qayerda tanlanmaydi:** `isKassa()` (`provodka.html`, `jurnal.html`),
  `professional.html` account yuklashi, `cashflow.html` kassa filtri, `kassa.html` konvert —
  hammasi `kassa_turi!=='xarajat_guruh'` bilan filtrlaydi. Hodim kassalari (5401+) esa **ko'rinadi**.
- **`renderKassalar()` `try/catch` ichida** va noma'lum `kassa_turi` "Boshqa" guruhiga tushadi —
  yangi tur qo'shilganda sahifa hech qachon butunlay bo'sh qolmasligi kerak.
- `v_kassa_card`/`v_kassa_toliq`da `parent_id` **ikki ma'noli**: dollar juftligi ham, guruh a'zoligi ham.
  Dollar juftligini izlagan SQL/JS `currency='USD'` shartini ham qo'yishi shart — aks holda 5400'ning
  62 ta bolasi bitta-qator subquery'ni portlatadi va **butun view xato beradi** (kassa sahifasi bo'shab qoladi).

### Ko'p-valyuta (v2)

Naqsh: **parent UZS kassa + har valyuta uchun bola-hisob** (`parent_id`, `currency`).
Qaysi valyutada bola bo'lsa — o'sha ko'rinadi, yo'g'i ko'rinmaydi.

- `v_hisob_bal(account_id, uzs, fc)` — umumiy qoldiq yordamchisi (posted + o'chirilmagan).
  `fc` = hisobning **o'z** valyutasidagi qoldiq (`fc_amount` yig'indisi; bitta hisob = bitta valyuta).
- `v_kassa_valyutalar(parent_id, account_id, code, name, currency, uzs, fc_qoldiq)` — parentning
  barcha valyuta bolalari. `uzs` — **tarixiy kursdagi** so'm ekvivalenti, joriy kursga qayta ko'paytirilmaydi.
- `v_kassa_card` — `usd`/`usd_uzs`/`has_usd`/`usd_account_id` **faqat USD bolasidan** (eski UI sinmasin),
  `jami` esa parentning o'zi + **hamma** valyuta bolalari. Yangi: `valyuta_soni`.
- `create_valyuta_child(p_parent uuid, p_currency text)` → uuid. Admin, idempotent, SECURITY DEFINER.
  Kod `valyuta_kod_blok` jadvalidan: USD=56xx, CNY=57xx, keyingilari 58/59. Bloklar tugasa xato beradi.
- `v_valyuta_royxat` — tanlash uchun valyuta kodlari (`accounts` + `currency_rate` + bloklardan).

`v_hisob_royxat` — `jurnal.html`dagi hisob filtri (optgroup). Guruhlash tartibi muhim,
**birinchi moslik yutadi**: `kassa_turi` ('markaziy'|'filial'|'xarajat') → `section='tovar'` (Omborlar)
→ `type` ('daromad'|'xarajat') → Boshqa. `kassa_turi='xarajat'` (Xarajat **kassalar**) va
`type='xarajat'` (Xarajat **moddasi**) — ikki xil guruh, birinchisi oldin tekshiriladi.

RPC: `sync_filial_balances(jsonb)`, `sync_received_transfers(jsonb)`, `acc_balance(uuid)`.

Jurnal RPC'lari (`jurnal.html`):
- `jurnal(p_from date, p_to date, p_account uuid default null, p_accounts uuid[] default null,
  p_limit int default 100, p_offset int default 0)` → **jsonb massiv**. Har element: `{id, entry_date,
  description, source, is_deleted, deleted_by_name, deleted_at, edited_at, edited_by_name, created_at, lines:[...]}`.
  `lines` element: `{id, account_id, code, name, section, currency, debit, credit, fc_amount}`.
  **`lines` ichida Dt birinchi keladi.**
- `jurnal_count(p_from, p_to, p_account uuid default null, p_accounts uuid[] default null)` → int.
  Sahifalash uchun jami son (`p_limit`/`p_offset`siz).
- **`p_account` (bitta hisob) va `p_accounts` (hisoblar massivi — filial filtri uchun).** Klientda:
  hisob tanlansa `p_account` ustun bo'ladi, aks holda tanlangan filialning barcha `account_id`lari
  (`v_filial_hisob`) `p_accounts` sifatida ketadi. `p_limit`/`p_offset` **nomlangan argument** —
  pozitsiyaga tayanma (massiv parametri o'rtaga qo'shildi).
- **Tur va qidiruv filtri klientda** — server faqat sana + hisob(lar) bo'yicha filtrlaydi. Shuning uchun
  ular faqat **yuklangan** qatorlarga ta'sir qiladi; `jurnal_count` esa serverdagi to'liq sonni beradi.
  Sanoq satri shuni ochiq yozadi ("N ta ko'rsatilmoqda · yuklangan M / jami K").

Hisobot RPC'lari (`sb.rpc()` orqali, SECURITY INVOKER — anon o'qiy olmaydi):
- `balans(p_date)` → `bolim` ('AKTIV'|'PASSIV'|'KAPITAL'), `section`, `code`, `name`, `amount`.
  AKTIV = debit−kredit (amortizatsiya **manfiy** — kontr-aktiv). PASSIV/KAPITAL = kredit−debit, musbat.
  `8710 Yigilgan sof foyda` — sintetik qator. sum(AKTIV) = sum(PASSIV)+sum(KAPITAL) matematik kafolat.
- `pnl(p_from,p_to)` → `bolim` ('TUSHUM'|'TANNARX'|'OPERATSION'|'SOLIQ'|'BOSHQA'), `section`, `code`, `name`, `amount`.
  **Xarajatlar musbat keladi.** **Subtotal qaytarmaydi** — faqat barg qatorlar, zinapoya klientda yig'iladi:
  Yalpi = TUSHUM−TANNARX; Operatsion foyda = Yalpi−OPERATSION; Sof = Operatsion foyda−SOLIQ−BOSHQA.
- `cashflow(p_from, p_to, p_account uuid default null)` → `yonalish` ('KIRIM'|'CHIQIM'), `section`,
  `code`, `name`, `amount`. **Ikkalasi ham musbat.**
- `pul_qoldiq(p_date, p_account uuid default null)` → numeric. Davr boshi = `pul_qoldiq(p_from − 1 kun)`,
  `p_from` emas. Tekshiruv: `pul_qoldiq(p_to) − pul_qoldiq(p_from−1)` = sum(KIRIM) − sum(CHIQIM).
  **`p_account` uchala chaqiruvga ham bir xil berilishi shart**, aks holda tekshiruv mos kelmaydi.

Konvert RPC'lari (tugma + modal `kassa.html`da — `openConv()`/`convSave()`):
- `aros_usd_rate()` → **oddiy numeric** (koridor emas). Koridor frontendda: `lo=rate*0.98`, `hi=rate*1.02`.
  **null bo'lishi mumkin** (Valyuta bo'limida "Aros'dan" import qilinmagan bo'lsa) — UI shuni ko'tarishi kerak.
- `convert_start(p_from, p_to, p_amount, p_rate, p_note)` → json:
  `{ok:true, status:'done'}` — bajarildi; `{ok:false, status:'pending', request_id, aros_rate, lo, hi}` — tasdiq
  kutilmoqda, **pul harakat qilmagan**; `{ok:false, error}` — xato. Kurs koridordan chiqsa UI **bloklamaydi**,
  faqat sariq qiladi — qarorni server qabul qiladi.
- `convert_approve(p_id)`, `convert_reject(p_id, p_note)` — faqat admin.

`convert_request`: `id, from_account, to_account, amount (so'm), rate (1$ necha so'm), fc_amount (dollar),
aros_rate (so'rov paytidagi — farq foizi shundan), status, note, requested_by_name, requested_at,
decided_by_name, decided_at, entry_id`.

`v_kassa_toliq`: `id, code, name, currency, kassa_turi, parent_id, uzs, usd`.
- `uzs` — daftar qoldig'i so'mda. Dollar kassasi uchun ham shu maydon so'm ekvivalenti, lekin **tarixiy
  kursda** (sotib olingan paytdagi), joriy kursda emas — kursga qayta ko'paytirma.
- `usd` — dollar miqdori, so'm kassalarida `null`. `parent_id` — dollar kassasini so'm kassasiga bog'laydi.
- **Filial asosiy kassasi Aros bilan sinxronlanadi — undan konvert qilib bo'lmaydi** (`kassa_turi<>'filial'`).

`p_account` semantikasi (ikki xil, ikkalasi ham to'g'ri):
- **null = hamma kassalar** → kassalararo transfer chiqib ketadi (ichki harakat, net=0).
- **bitta kassa** → markazga jo'natilgan pul o'sha kassa uchun CHIQIM bo'lib ko'rinadi. Bu **xato emas**:
  pul shu kassadan chiqqan. `cashflow.html` izohi shunga qarab o'zgaradi (`setNote()`).

## Qat'iy qoidalar

- **Dt = Kt** har doim. Trigger `check_entry_balanced` teng bo'lmasa saqlatmaydi.
- **Hech narsa o'chirilmaydi.** O'chirish = `is_deleted=true`, jurnalda usti chizilib qoladi + kim o'chirgani.
  Eski nusxa `entry_history`ga tushadi.
- **Tahrir/o'chirish faqat admin.** RLS darajasida ham himoyalangan.
- **Balans hisobi** faqat `status='posted' AND is_deleted=false` yozuvlardan.
- **Vaqt zonasi:** UZB (UTC+5). `new Date(Date.now()+5*3600*1000)`.
- **Pul formati:** probel bilan ajratiladi (`12 100`), `font-variant-numeric: tabular-nums`.
- **Yozuv tranzaksiyada emas.** Tartib: `entry` insert → `entry_line`lar insert → satrlar xato bersa
  `entry` qo'lda `delete` qilinadi. Saqlash kodini o'zgartirganda shu kompensatsiya `delete`ni yo'qotma —
  aks holda yetim sarlavha qolib ketadi.
- **Tahrir faqat 2 satrli yozuvga.** Qalam tugmasi `entry_line.length===2` bo'lsagina chiqadi.
  `professional.html`dagi ko'p satrli yozuvni o'chirish mumkin, tahrirlash mumkin emas.
  `jurnal.html`da yana bitta shart bor: **kamida bir tomon pul bo'lsin** (`isPul(dt)||isPul(kt)`).
  Tahrir modali faqat Kirim/Chiqim/Transfer shaklini biladi — 4-holatni (ombor → tannarx) u
  ifodalay olmaydi va saqlansa yozuvni kassa yozuviga aylantirib yuboradi. Shuning uchun
  neytral yozuvda faqat 🗑 chiqadi.

### Jurnal tasnifi — 4 holat

Yozuv turi **`section='pul'`** bo'yicha aniqlanadi, **kod prefiksi (`5xxx`) bilan EMAS**
(`jurnal.html` → `klass()`). Kod prefiksi eski usul — yangi kodda ishlatma.

| Dt | Kt | Tur | Ko'rinish | Ishora |
|----|----|-----|-----------|--------|
| pul | pul | Transfer | ko'k ⇄ | yo'q |
| pul | pul emas | Kirim | yashil ↙ | `+` |
| pul emas | pul | Chiqim | qizil ↗ | `−` |
| pul emas | pul emas | Neytral | kulrang → | yo'q |

Neytral sarlavha = `<Kt nomi> → <Dt nomi>` (masalan "Chilonzor ombori → Tovar tannarxi").
Transfer sarlavhasi ham shu shaklda. **Ikkitadan ko'p satrli** yozuv (Professional'dan) — satrlari
ro'yxat qilib ko'rsatiladi, ishorasiz, "Boshqa" turiga kiradi.

## Avtomatik sinxron (n8n)

`Aros Provodka - Auto Sync` (`7MSHrXnz9cGAFBTh`), har 30 daqiqada:
1. Qabul qilingan transferlar → `Dt markaziy kassa / Kt filial kassa`.
   Summa = `items[].confirmed_total` yig'indisi (**reja emas** — `total_amount` ustuni rejani saqlaydi).
2. Filial balansi o'sgan bo'lsa → `Dt filial kassa / Kt savdo tushumi`.
   **Kamayish e'tiborsiz qoldiriladi** — u transfer bilan yoziladi, ikki marta tushmasin.

Boshqa workflowlar: `aros-filial-live` + `aros-currencies` (`lco21f7pUcKPpNVU`),
`aros-currency-rates` (`VDezk7eRnwktu2AX`), `aros-dollar-rate` (`7VyISbPe0ZJqIH0Z`).

## n8n bilan ishlash

- `update_workflow` **har doim** qo'lda ulangan kreditlarni uzadi. "Postgres account 3" o'zi qayta ulanadi,
  HTTP kreditlar (Aros Basic Auth, Supabase API) — yo'q. Update qilishdan oldin ogohlantir.
- Yangi endpoint = **alohida kichik workflow**. Katta ishlab turgan workflowlarni qayta qurma.
- `jsCode` ichida arrow function ishlatma — `function` sintaksisi.
- SDK: `workflow('id','Nom')`, `node({type, version, config:{name, parameters, position}})`, `.add(x).to(y)`.
  `.join()` kabi metodlar taqiqlangan — matnni to'g'ridan-to'g'ri yoz.

## Aros API tuzilishi (o'rganilgan)

- `billing/cachiers/` — ro'yxat. `warehouse` bor = filial, yo'q = markaziy kassa.
- `billing/cachiers/{id}/` — `balances[]`: `cash_balance`, `click_balance`, `payme_balance`, `dollar_balance`.
  **Balanslar filiallar uchun ham qaytadi** (Bugalter Sync ularni olmaydi, faqat kassalar uchun oladi).
- `currencies/` — faqat valyutalar lug'ati (`name`, `is_main`). **Kurs yo'q.**
- `currency-rates/` — kurslar: `base_currency.name`, `target_currency.name`, `rate`, `created_datetime`.
- n8n PG: `cachier_transfers` (`sender_title`, `receiver_title`, `receiver_id` **NULL**, `items` jsonb),
  `cachiers` (`title`, `warehouse_name`, `warehouse_id`, `is_kassa`, `responsible`).
  Vaqtlar naive, Toshkent vaqtida saqlanadi.

## Ish uslubi

- HTML tahrir qilganda **butun faylni qayta yozma** — kerakli joyini o'zgartir.
- `<script type="module">` ichida `onclick`dan chaqiriladigan funksiya **`window.`ga yozilishi shart** —
  modulda top-level funksiya global bo'lmaydi.
- `innerHTML` bilan qayta chizgandan keyin `icons()` (`lucide.createIcons()`) chaqir,
  aks holda `<i data-lucide>` ikonkalari yo'qoladi.
- Tuzilishni buzmaslik uchun: o'zgartirgandan keyin `<div>` balansini tekshir.
- **JS sintaksisini `node --check` bilan tekshir** (Node o'rnatilgan), brauzer/Edge bilan emas.
  Module skriptni ajratib ol va tekshir:
  ```sh
  sed -n '/<script type="module">/,/<\/script>/p' fayl.html | sed '1d;$d' > /tmp/x.mjs
  node --check /tmp/x.mjs
  ```
  **Diqqat:** bu `sed` faqat BIRINCHI `</script>` gacha o'qiydi — undan keyingi buzilgan qismni
  ko'rmaydi. Shuning uchun `</script>` sonini ham tekshir: **har faylda aniq 3 ta**
  (`vendor/lucide` + `vendor/supabase` + module). 3 dan farq bo'lsa fayl buzilgan.
- **Skript bilan ommaviy tahrir qilganda `str.replace(re, string)` ISHLATMA — `replace(re, () => string)`
  ishlat.** String almashtirishda `$'` "moslikdan keyingi hamma narsa", `$&` "moslikning o'zi",
  `$1` guruh degani. Kodimizda `+' $':money(...)` bor — ya'ni `$'` — va u jimgina faylning butun
  qolgan qismini shablon o'rtasiga qistiradi. `node --check` buni sezmaydi (yuqoridagi sabab).
- Dizaynni bir faylda o'zgartirsang, qolgan 6 tasiga ham tushir (aks holda ular ajralib qoladi).
- SQL DDL'ni Asilbek o'zi RUN qiladi — SQL yozib ber, o'zing bajarma.
