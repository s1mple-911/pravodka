# Aros Provodka
# FABLE — Orkestrator qoidalari (CLAUDE.md ga qo'shiladi)

<!-- Bu blokni har reponing CLAUDE.md fayliga qo'shing (yuqoriga). CC (main agent) = Fable. -->

## SEN — FABLE (loyiha boshqaruvchi / orkestrator)

Sen Fable'san — bosh agent, loyiha boshqaruvchi. Asilbek senga task beradi. Sen O'YLAYSAN, ishni bo'laklarga bo'lasan, mos subagentlarga topshirasan, natijalarni yig'asan va Asilbekka HISOBOT berasan.

### Subagentlaring (~/.claude/agents/)
- **coder** — aniq kod yozadi (JS/SQL, TaskFix/Provodka qoidalari, {error}, RLS, double-entry). Kod yozish, bug tuzatish, refactor.
- **designer** — UI/UX (Apple darajа, chiroyli, minimalist). Vizual, CSS, komponent ko'rinishi.
- **tester** — QA (syntax, mantiq, chekka holat, xavfsizlik, regression). Har o'zgarishni test.

### Ish oqimi (har task uchun)
1. **O'yla + rejalashtir**: taskni tushun, bo'laklarga bo'l. Qaysi bo'lak coder'niki, qaysi designer'niki, qaysi tester'niki — aniqla.
2. **Kontekst yig'** (kerak bo'lsa): avval mavjud kodni ko'r (o'zing yoki coder orqali) — pattern, field, mavjud funksiya. Taxmin qilma.
3. **Topshir** (ketma-ket yoki parallel):
   - Kod kerak → **coder**
   - UI/dizayn → **designer**
   - Yozilgach → **tester** (test)
   - Murakkab: coder yozadi → designer chiroyli qiladi → tester test qiladi.
4. **Yig' + tekshir**: subagent natijalarini ko'rib chiq. Tester ❌ topsa → coder'ga qaytar (tuzat). Sifat past bo'lsa → qayta topshir.
5. **HISOBOT** Asilbekka: qisqa, aniq:
   - Nima qilindi (har bo'lak)
   - Qaysi agent nima qildi
   - Test natijasi (✅/❌)
   - Push kerak (qaysi commit) — Asilbek push qiladi (GitHub Desktop)
   - Ochiq savol / qaror kerak bo'lsa

### Qoidalar
- 🔴 Eski funksiyalar buzilmasin — har o'zgarishdan keyin tester regression tekshirsin.
- Katta ishni BOSQICHMA-BOSQICH — bir vaqtda bir bo'lak, tugagach keyingisi. Har bosqich alohida commit.
- Push QILMA — Asilbek qiladi. Sen commit xabarini tavsiya qil.
- SQL DDL — Asilbek RUN qiladi. Sen additive .sql yoz.
- Kichik/oddiy fix — subagent SHART EMAS, o'zing (Fable) qil. Overhead bo'lmasin. Subagent — katta/ajratilgan ish uchun.
- Subagent boshqa subagent chaqira olmaydi — faqat sen (Fable) chaqirasan.
- Ikkilanганда — Asilbekdan so'ra (bitta savol), taxmin qilma.

### Qachon subagent, qachon o'zing
- **Subagent**: yangi feature (DB+backend+UI+test), katta refactor, ajratilgan ish, UI dizayn.
- **O'zing (Fable)**: bitta qatorli fix, tez tekshiruv, savolga javob, kichik tahrir.

### Hisobot uslubi
Asilbek o'zbekcha, qisqa, aniq javob kutadi. Uzun tafsilot emas — nima bo'ldi, test qanday, keyingi qadam. Emoji minimal.
Ikki tomonlama buxgalteriya (double-entry) web-app. Aros Market'ning ichki pul-hisobi.
Aros'dan **faqat o'qiydi**, hech qachon yozmaydi.

## ⛔ DEV / PROD ish tartibi (MAJBURIY — hamma ishdan ustun)

Provodka **haqiqiy foydalanuvchilarda** ishlab turibdi. Shuning uchun:

1. **Yangi ish FAQAT `-dev.html` fayllarda.** Prod `.html` fayllarga (masalan `hodim.html`)
   **TEGILMAYDI**. Har prod fayl uchun dev nusxa bor (`hodim-dev.html`, `kassa-dev.html`, …, 15 ta).
   Dev fayl ichidagi **har** navigatsiya/sidebar/redirect/prefetch boshqa **dev** faylga ketadi
   (`jurnal-dev.html`); prod dev'ga, dev prod'ga aralashmaydi — eng ko'p xato qilinadigan joy.
   `vendor/*` **ikkalasi uchun bitta** (nusxalanmaydi). `perms.js` ham shunday edi, lekin
   ruxsat semantikasi o'zgargani uchun **`perms-dev.js` ochildi** — dev fayllar o'shanga
   havola qiladi (pastda "Foydalanuvchi ruxsatlari" bo'limiga qara).
2. **dev → prod ko'chirish faqat `promote.sh`** bilan (qo'lda emas): `bash promote.sh` (hammasi)
   yoki `bash promote.sh hodim kassa` (tanlab). U dev'ni prod'ga nusxalaydi va `-dev.html`
   havolalarini `.html` ga qaytaradi. `perl` ishlatadi — CRLF/LF qator oxirlarini saqlaydi.
   Ko'chirishdan oldin ogohlantir; Asilbek o'zi RUN qiladi.
3. **Supabase BITTA — dev va prod bir xil DB.** Shuning uchun **SQL faqat ADDITIVE**:
   `add column if not exists`, yangi funksiya/view, `create or replace` **eski imzoni saqlab**.
   **Ustun/funksiya o'chirish yoki imzo (argument/tur) o'zgartirish — TAQIQ**: prod frontendni
   sindiradi. Tozalash alohida bosqichda, dev prod'ga chiqqach. SQL'ni baribir Asilbek RUN qiladi.

## Stack

- Frontend: statik HTML fayllar, GitHub Pages. Build yo'q, framework yo'q.
- Backend: Supabase (`kxzerccdpcltmzrxutlo.supabase.co`) — PostgreSQL + Auth + RLS.
- Aros bilan bog'lanish: n8n webhooklar (`n8n.arosmarket.com`), Aros API `api.aros.uz`.
- Til: interfeys o'zbekcha (lotin). Kod izohlari ham o'zbekcha.

## Kutubxonalar — `vendor/` (repoda, CDN emas)

Tezlik uchun hamma tashqi resurs repoga ko'chirilgan — GitHub Pages'dan bitta domendan
keladi (DNS/TLS yo'q, brauzer keshlaydi). CDN (`jsdelivr`/`unpkg`/Google Fonts) **ishlatilmaydi**.

- `vendor/supabase-2.110.6.js` — Supabase UMD (bitta fayl). Global: `window.supabase.createClient(url,key)`.
  **`import ... +esm` YO'Q.** Versiya yangilansa fayl nomini o'zgartir (kesh) va 30 faylda (15 dev + 15 prod) `<script src>`ni yangila.
- `vendor/lucide-1.24.0.js` — Lucide UMD. Global: `window.lucide.createIcons()` (avvalgidek `icons()`).
- `vendor/inter.woff2` — Inter variable font (100–900). `@font-face` har faylning `<style>` boshida.

Head tartibi (hamma faylda): `<link rel=icon>` → supabase `preconnect` → 10-11 ta `prefetch`
(qolgan sahifalar) → `<script src="vendor/lucide...defer">` → `<script src="vendor/supabase...defer">`
→ `<script src="perms.js" defer>` (dev fayllarda **`perms-dev.js`**)
→ `<script src="ai-widget.js" defer>` (dev fayllarda **`ai-widget-dev.js`**) → `<style>`.
Vendor skriptlar `defer`, module skript ham defer (implicit) — shuning uchun module ishga tushganda
`window.supabase`/`window.lucide`/`window.perm*` tayyor bo'ladi.
**Skript soni (2026-08-14 dan): 15 navigatsiyali DEV faylda aniq 5 ta `</script>`**
(lucide + supabase + perms + **ai-widget** + module). Istisnolar: `ai-dev.html` va
`hodim-dev.html` da widget YO'Q → **4 ta**. **`index-dev.html` da ham 5 ta, lekin BOSHQA
tarkib**: lucide + supabase + perms + **inline sinxron skript** + module (widget yo'q,
navigatsiya yo'q). Prod fayllar promote'gacha **4 ta**.
Kutilgandan farq bo'lsa fayl buzilgan.

**`ai-widget.js` / `ai-widget-dev.js`** (2026-08-14) — ikkinchi umumiy klient fayli: har sahifadagi
floating AI tugmasi. Tugma **faqat** `PERMS.is_admin` yoki `allowed_pages ∋ 'ai'` bo'lganda chiziladi
(sukut YASHIRIN — `perms.js` ning "yuklanmaguncha ochiq" semantikasi bu yerda **takrorlanmaydi**);
ruxsat kech kelsa 400ms×20 poll bilan paydo bo'ladi. Panel ichida **`ai-dev.html?embed=1` iframe** —
🔴 chat mantiqi (EF, tarix, manbalar, fayl) BITTA joyda qoladi; ikkinchi chat implementatsiyasi
yozilsa "namoz moduli ikki marta" falokati takrorlanardi. Prefiks `.aiw-*`, z-index: tugma 60 ·
overlay 145 · panel 150 (sahifaning o'z modali 200 baribir ustun). `promote.sh` endi **ikkita**
umumiy faylni ko'chiradi (`perms-dev.js`, `ai-widget-dev.js`).

`perms.js` (prod) / `perms-dev.js` (dev) — repodagi yagona **umumiy** klient fayli (vendor emas,
o'zimizniki). Ruxsat tizimi xavfsizlikka tegishli, shuning uchun u 15 marta ko'chirilmaydi:
bitta joyda tuzatiladi. Ikki nusxa vaqtinchalik — `promote.sh` dev'ni prod ustiga yozadi.

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
| `index.html` | **Kirish yuzi**: login + dashboard (ruxsatli bo'limlar). `pravodka.com` ildizi |
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
| `ai.html` | AI yordamchi chat (hozircha faqat `ai-dev.html` — 1-bosqich, API yo'q) |

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

### `index.html` — login + dashboard hub (2026-08-18)

`pravodka.com` ildizi. Avval `index.html` umuman yo'q edi (404) va har sahifa o'z login
gate'ini ko'rsatardi. Endi kirish **bitta yuzdan** boshlanadi.

- **Ikki ekran, bitta fayl**: `#gate` (login) va `#dash` (dashboard). Ikkalasi ham CSS'da
  `display:none`; `boot()` qaysi birini ochishini hal qiladi (sessiyali user login ekranini
  ko'rmaydi). 🔴 `<head>` dagi **inline sinxron skript** `<html>` ga `has-sess`/`no-sess`
  klassini va mavzuni (`prov-theme`) qo'yadi — module yiqilsa (vendor 404) ildiz **oq ekran**
  qolmasin va dark user oq kadr ko'rmasin. `.no-sess #gate{display:flex}` / `.has-sess #dash{display:block}`
  faqat BIRINCHI kadr uchun; module keyin `style.display` bilan aniq holatni qo'yadi.
- **Navigatsiya YO'Q** (sidebar/bnav/sheet), **ai-widget ham yo'q** — u hub, sahifa emas.
- 🔴 **Yangi sahifa qo'shilsa u endi UCH joyga yoziladi**: `perm_pages()` (SQL) = `perms-dev.js`
  dagi `PAGES` = `index-dev.html` dagi `CARDS`. Birortasida yo'q bo'lsa sahifa jimgina
  ko'rinmay qoladi (dashboard'da karta chiqmaydi yoki ruxsat kaliti tashlab yuboriladi).
  Ataylab farqlar: `provodka` kartasi YO'Q (u navigatsiyadan yashirilgan), `hodim` esa
  `PAGES` da yo'q bo'lsa ham dashboard'da HAR DOIM birinchi karta.
- **Kartalar faqat `permLoad()` javobidan keyin** chiziladi (aks holda "yuklanmaguncha ochiq"
  semantikasi tufayli bir zumga HAMMA karta ko'rinardi); `showLogin()`/`enterApp()` `#cards` ni
  "Yuklanmoqda…" ga qaytaradi — tabda user almashganda eski ro'yxat qolib ketmasin.

🔴 **LOGIN POYGASI — 2026-08-18 dagi prod bug (uch qavatli tuzatish).** Yangi foydalanuvchi
kirganda dashboard'da HAMMA bo'lim ko'rinardi, F5 dan keyin to'g'rilanardi. Sabab: supabase-js
`Authorization` sarlavhasini **asinxron** `SIGNED_IN` hodisasida yangilaydi — `signInWithPassword`
qaytishi bilan darrov yuborilgan `my_perms()` hali **anon kalit** bilan ketardi (`auth.uid()` null),
xato qaytardi va `perms.js` da `loaded=false` qolib ketardi → "yuklanmaguncha ochiq" qoidasi
bo'yicha hamma sahifa ochiq ko'rinardi. Tuzatish (uchalasi ham saqlansin):
1. `perms.js` `fetchFresh()` — xato/bo'sh javobda **qayta urinish** (250/600/1200 ms). Bu 15 sahifaga
   ham tegishli: ularda ham birinchi login'dan keyin sidebar hamma havolani ko'rsatardi.
2. `index.html` `renderCards()` — **fail-CLOSED**: `permLoaded()` false bo'lsa karta CHIZILMAYDI
   ("Yuklanmoqda…", urinishlar tugagach "Qayta urinish"). Nav uchun "ochiq" to'g'ri, dashboard
   uchun teskari — u ro'yxatning o'zi.
3. `index.html` login muvaffaqiyatli bo'lsa **`location.reload()`** (avval `enterApp()` edi) — bu
   foydalanuvchi qo'lda bosadigan F5 ning o'zi, poygani butunlay yo'q qiladi. Token reload'dan
   oldin localStorage'da bo'ladi, `has-sess` inline klassi tufayli login ekrani miltillamaydi.
`window.permLoaded()` — shu ish bilan qo'shilgan yangi eksport (sahifalar uni ishlatishi shart emas).
- **Logout/login `swrClear()` qiladi** (`prov-swr:` sessionStorage keshi) — yangi foydalanuvchi
  eskisining raqamlarini ko'rmasin. `permClear()` bilan birga, ikkalasi ham majburiy.

**GUARD — `perms-dev.js` da, 15 sahifaga tegilmagan** (busiz 15 faylni tahrirlash kerak bo'lardi):
- `loginGuard()` — sessiya tokeni (`sb-…-auth-token`) YO'Q bo'lsa `index{suf}` ga `location.replace`.
  Index sahifasining o'zida ishlamaydi (sikl). localStorage bloklangan (Safari private) → **redirect yo'q**,
  sahifaning eski gate'i ishlayveradi. Bu QO'SHIMCHA qatlam: "token bor, lekin muddati o'tgan"
  holatni hamon har sahifaning o'z `boot()` i ushlaydi — eski auth olib tashlanmagan.
- `gate()` da sahifa yopiq bo'lsa endi "Ruxsat yo'q" ekrani o'rniga **dashboard**ga yuboriladi.
  🔴 `!hasProvodka()` shoxi (bosh sahifada `hodim` ga redirect, boshqa sahifada `denyScreen()`)
  va `loaded===false` → hech narsa to'silmaydi qoidasi **TEGILMAGAN**.
- `page()` da ildiz `/` endi `jurnal` emas, **`index`** qaytaradi. `index` `PAGES` da YO'Q — hub
  ruxsat bilan cheklanmaydi (u o'zi ruxsatli bo'limlarni chizadi).

**CNAME + promote:**
- Repo ildizidagi `CNAME` (`pravodka.com`, LF, BOM yo'q) — GitHub Pages custom domeni shundan o'qiladi.
  `promote.sh` unga **hech qachon tegmaydi** (sahifa emas), lekin har promote'da borligini tekshirib
  ogohlantiradi. 🔴 DNS tayyor bo'lmasa CNAME qo'shish `*.github.io` ni domenga 301 qiladi va
  jonli userlarni uzadi — avval DNS, keyin push.
- `promote.sh` `PAGES` ga `index` qo'shilgan. 🔴 `perms-dev.js → perms.js` **argumentdan qat'i nazar**
  ko'chadi, ya'ni har qanday promote prod'ga login guardni olib chiqadi — shuning uchun skript
  `index.html` yo'q bo'lsa `index` ni targets'ga **o'zi qo'shadi** (ikkalasi ham yo'q bo'lsa `exit 1`).
  Commit ham birga: `perms.js` va `index.html` **bitta commitda** ketmasa prod mavjud bo'lmagan
  sahifaga yo'naltiradi.

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

### Konvert v2 — Sotib olish / Sotish

- `convert_start_v2(p_from, p_to, p_amount, p_rate, p_note)` — **yo'nalish `from`/`to` valyutasidan**:
  `UZS→X` sotib olish (`p_amount` **so'mda**), `X→UZS` sotish (`p_amount` **valyutada**).
  `p_rate` har doim *1 birlik valyuta necha so'm*. `X→Y` rad etiladi ("avval so'mga soting").
  Qaytishi eskisidek + `yonalish`, `currency`, `amount`, `foiz`.
- `do_convert_v2(...)` — `fc_amount` **har doim valyuta-hisob satriga** (Dt yoki Kt — farqi yo'q).
  `v_hisob_bal` (`debit>0 ? +fc : −fc`) buni to'g'ri hisoblaydi.
- **Eski `convert_start` va `do_convert` imzolari saqlanadi** — ichi v2'ga delegat. Buzma:
  eski pending so'rovlar `convert_approve` orqali shu imzo bilan bajariladi.
- `conv_koridor_foiz()` → **5** (avval 2% edi). Koridorning yagona manbasi — UI ham shundan o'qiydi.
- `conv_baza_kurs(p_cur)` — USD uchun `aros_usd_rate()`, boshqasi `currency_rate`dagi oxirgisi
  (teskari juftlik bo'lsa `1/rate`). **null bo'lishi mumkin** → koridor yo'q, to'g'ridan pending.
- `acc_fc_balance(p_id)` — valyuta qoldig'i. Sotishda va sotish approve'ida tekshiriladi.
- `convert_approve` koridorni **qayta tekshirmaydi** (ataylab, eski xatti-harakat).
- `convert_request`ga ustun qo'shilmagan — yo'nalish `from`/`to` hisob valyutasidan tiklanadi
  (`konvert.html` → `yonalish()`).

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

## Foydalanuvchi ruxsatlari (rol tizimi) — `PROVODKA_PERMS.sql` + `perms.js`

Har foydalanuvchiga alohida: qaysi kassalarni **ko'radi**, qaysilarida **amaliyot** qiladi,
**konvert** ruxsati bormi, qaysi **sahifalar** ochiq. Sozlash Provodka'da emas —
`admin-dev.html` → n8n webhook → `admin_set_provodka_perms()`.

`user_perms(user_id, allowed_pages text[], kassa_scope, view_kassa_ids uuid[], op_kassa_ids uuid[],
can_convert, filial_scope, filial_ids uuid[], updated_at, updated_by)`. `kassa_scope='all'`
= hamma kassa. **Admin** — hech qachon cheklanmaydi.
RLS: o'qish o'zi yoki admin; **yozish policy'si umuman yo'q** — faqat RPC (service_role) yozadi.

**⚠️ `allowed_pages` semantikasi TESKARI aylandi** (`PROVODKA_PAGES_EMPTY.sql`, 2026-08-11):
**bo'sh ro'yxat = HECH QAYSI sahifa ochiq emas** (avval "hammasi ochiq" edi). Sabab: userlarning
~80% i faqat `hodim.html` ni ishlatadi, eski qoidada esa "hech qaysi sahifa" degan holat yo'q edi.
`hodim.html` bu ro'yxatga **kirmaydi** va hech qachon cheklanmaydi — `perm_pages()` ichida
`hodim` kaliti yo'q, `permGate()` ham ro'yxatdan tashqari kalitni erkin o'tkazadi.
Migratsiya **ataylab qilinmadi** (Laziz qarori): eski userlar avtomatik yopildi, ruxsat
admin-dev'dan qo'lda beriladi. Rollback — `PROVODKA_PAGES_EMPTY.sql` 8-bo'limida.

- `perm_pages()` → **14 ta** kalit (12 emas): oldingi 12 + `yuklar`, `standart`.
  `perms.js` dagi `PAGES` bilan **aynan** bir xil bo'lishi shart, aks holda
  `admin_set_provodka_perms` o'sha kalitni "noma'lum" deb jimgina tashlab yuboradi.
- `my_perms()` → jsonb, `authenticated` uchun. Qatorsiz userga `allowed_pages: []`
  (= ruxsat yo'q) qaytadi, qolgan cheklovlar ochiq (`kassa_scope='all'`, `can_convert=true`).
  Qo'shimcha bayroqlar: `is_admin`, **`has_provodka`** (= admin yoki ro'yxat bo'sh emas).
- `perm_has_page(text)` — server tomonda sahifa tekshiruvi. **Hozircha hech qayerda
  chaqirilmaydi** (sahifa ruxsati UI masalasi; pul guardi alohida va u tegilmagan).
- `admin_set_provodka_perms(p_data jsonb)` — **service_role ONLY** (n8n). `op ⊆ view` majburlaydi,
  noma'lum sahifa kalitini tashlaydi, `role='admin'` userga cheklov yozmaydi (qatorini o'chiradi).
  Bo'sh `allowed_pages` **shundayligicha** saqlanadi — eski "hammasi belgilangan → bo'sh saqla"
  bloki olib tashlandi (yangi semantikada u aynan teskari natija berardi). Payload kontrakti
  o'zgarmadi — n8n tomonda hech narsa qilinmaydi.
- `perm_check_accounts(uuid[])`, `perm_can_convert()`, `perm_op_key(uuid)`.

**SERVER GUARD — `entry_line` ustidagi trigger `trg_perm_guard_entry_line`.** Provodka yozuvlari
RPC orqali emas, klientdan to'g'ridan `entry`+`entry_line` insert bilan yoziladi — shuning uchun
yagona ishonchli to'siq shu trigger: kirim/chiqim/transfer/professional/tahrir/konvert — hammasi
bir joyda. `auth.uid()` null (service_role, n8n sinxroni) va admin o'tadi. **UI yashirish
hech qachon yetarli emas — yangi yozuv yo'li qo'shsang trigger uni avtomat qamrab oladi, buzma.**

Konvert ruxsati `convert_start_v2` ichida: `to_regprocedure('perm_can_convert()')` bo'lsa chaqiradi.
Shu naqsh tufayli ikki SQL fayl bir-birining ishga tushirilish **tartibiga bog'lanmaydi**.

**`perm_op_key`** — valyuta bola-hisobi (56xx USD…) ruxsatni **parent kassadan** oladi; hodim
kassalari esa o'z id'si bilan. Ikkalasini ajratuvchi shart: `currency <> 'UZS'`
(`parent_id` ikki ma'noli — yuqoridagi ogohlantirishga qara).

**`v_filial_tanlov`** — xarajat metadata uchun filial ro'yxati (`hodim`, `professional`,
`standart` — hammasi `select('*')` qiladi, shakl `id, code, name, subtitle`). **Har filial
BITTA qator.** `create_pul_turi_child()` bola-hisobga parentning `kassa_turi`'sini
**nusxalaydi**, shuning uchun "Izza Showroom · Naqd/Click/Payme" hisoblari ham
`kassa_turi='filial'` bo'lib ro'yxatga tushib qolardi — hodim bitta filialni uch marta
ko'rardi. Filtr: `pul_turi is null and currency='UZS'`. **Nom bo'yicha DISTINCT qilma** —
to'lov turi nomda emas, `pul_turi` ustunida. `filial_ids` kontrakti buzilmaydi: admin
filialning hamma kassa id'sini yozadi, `permFilterFilials` esa faqat parent id'ni tekshiradi.

Klient (`perms.js` prod / **`perms-dev.js` dev**, hamma sahifada bir xil): `permGate()`
(nav yashirish + "Ruxsat yo'q" ekrani, faqat `main` ichini almashtiradi — nav joyida qoladi),
`permLoad(sb)` (kesh-birinchi, fonda yangilanadi), `permViewOk/permOpOk/permFilterView/permFilterOp`,
`permConvert()`, `permHasProvodka()`, `permErr(e)` (42501 xatosini odam tiliga o'giradi), `permClear()`.
`enterApp()` **async**: keshdan gate → `await permLoad` → qayta gate → `init()`.
`permClear()` login va logoutda **majburiy** — `sessionStorage` reload'dan keyin ham qoladi,
aks holda yangi foydalanuvchi eskisining ruxsatlari bilan ochiladi.

**`perms-dev.js` — semantika o'zgargani uchun ochilgan yagona dev nusxa.** 15 dev fayl unga
havola qiladi, 15 prod fayl esa eski `perms.js` ga — ikkalasi bitta baza bilan yonma-yon ishlaydi
(`my_perms()` javobi bir xil, farq faqat "bo'sh" ni o'qishda). `promote.sh` uni `perms.js`
ustiga ko'chiradi va **o'sha daqiqada prod ham teskari semantikaga o'tadi** — tanlab bo'lmaydi.
Fayl ichida birorta `NAME-dev.html` matni yo'q: havola qo'shimchasi `suf()` bilan joriy fayl
nomidan olinadi (`-dev.html` yoki `.html`), shuning uchun dev va prod nusxasi **bayt-ma-bayt bir xil**.

Uchta nozik joy (buzma):
- **Sahifa kaliti `-dev` siz.** `page()` `.html` dan tashqari `-dev` ni ham kesadi, aks holda
  dev nusxaning kaliti `kassa-dev` bo'lib qolardi va cheklangan user butun dev muhitidan quvilardi.
- **Yuklanmaguncha ochiq.** `loaded=false` (RPC hali kelmagan yoki xato bergan) holatda hech narsa
  to'silmaydi — bir martalik tarmoq nosozligi userni sahifadan quvib chiqarmasin. Pul harakati
  baribir server guard bilan to'silgan.
- **`has_provodka=false` → `hodim.html` ga redirect**, lekin faqat **bosh sahifada** (`jurnal`).
  Boshqa sahifaga to'g'ridan URL bilan kirsa — "Ruxsat yo'q" ekrani + "Xarajat kiritish" tugmasi.
  80% user redirect tufayli bu ekranni umuman ko'rmaydi.

## AI yordamchi (`ai-dev.html` + EF `ai-chat`) — 1–2-BOSQICH (2026-08-13)

`BRIEF_PROVODKA_AGENT.md`. Provodka ichidagi AI chat. **Claude API ULANDI** (2-bosqich).
Qolgani: 3 — web_search bilan real-time qonunchilik, 4 — Provodka DB konteksti (permission bo'yicha).

### 2-bosqich — Edge Function `supabase/functions/ai-chat/index.ts` (Provodka'dagi BIRINCHI EF)
- Deno + `npm:@anthropic-ai/sdk` + `npm:@supabase/supabase-js@2.110.6` (vendor bilan bir xil versiya).
  Model **`claude-sonnet-5`** (Asilbek qarori; env `AI_MODEL` bilan almashadi, kod sukuti ham shu).
  `max_tokens 6000` — ⚠️ Sonnet 5 tokenizeri bir xil matnga ~30% ko'proq token beradi, 4000 da
  javob kesilardi (`max_tokens` chegara, xarajat emas). `thinking:disabled` + `effort:medium`
  (chat uchun narx/kechikish), stream YO'Q.
  ⚠️ **3-bosqich uchun eslatma**: Sonnet 5 `thinking:disabled` da **asboblarni kamroq chaqiradi** —
  web_search qo'shilganda `thinking` ni adaptive qilish yoki `effort` ni ko'tarish kerak bo'ladi,
  aks holda model qidirmasdan xotiradan javob berib qo'yishi mumkin.
  🔴 `temperature`/`top_p`/`top_k`/`budget_tokens` **ISHLATILMAYDI** — yangi modellarda 400 beradi.
- 🔴 **API kalit faqat Supabase secret'da** (`ANTHROPIC_API_KEY`), mijozda Anthropic URL/kalit yo'q.
- 🔴 **RUXSAT — IKKI tekshiruv AND bilan**: `perm_has_page('ai')` **VA** `my_perms()`
  (`is_admin` yoki `allowed_pages ∋ 'ai'`). Sabab: `perm_has_page` tanasida
  `if not (p_key = any(perm_pages())) then return true` bor — ya'ni `PROVODKA_AI_AGENT.sql`
  RUN qilinmagan bazada u **hammaga true** qaytaradi (fail-OPEN). `my_perms` fail-closed →
  AND teshikni yopadi. **Bittasini olib tashlash = ruxsat tizimini ochib qo'yish.**
- 🔴 **service_role kaliti ISHLATILMAYDI** — u bilan `auth.uid()` null bo'lib `perm_has_page`
  hammaga true berardi. Klient anon key + foydalanuvchi `Authorization` headeri bilan quriladi.
- Klientdagi "yuklanmaguncha ochiq" (`perms.js` `loaded=false`) semantikasi EF da **TAKRORLANMAYDI**:
  har qanday RPC xatosi → 403. U UI qulayligi, bu avtorizatsiya.
- Kiritma: faqat `{messages:[{role:'user'|'assistant', content:<string>}]}`. Mijozdan kelgan
  `system`/`model`/`max_tokens`/`tools`/`thinking` **e'tiborsiz** (narx/model boshqarib bo'lmasin).
  ≤20 xabar, ≤4000 belgi, ≤20000 jami; birinchi va oxirgi xabar `user`. Foydalanuvchi matni
  system prompt bilan **konkatenatsiya qilinmaydi**. EF hech qanday Provodka jadvalini o'qimaydi
  (`.from(` yo'q) — 2-bosqichda sizadigan ma'lumot yo'q.
- Tezlik chegarasi: user_id bo'yicha 60s/8 so'rov, **isolate xotirasida** (best-effort, qat'iy
  kafolat emas — DB-lik cheklov keyingi bosqichda). CORS `*` emas, allowlist (`AI_ALLOWED_ORIGINS`).
- ⚠️ Anthropic SDK `timeout` **har urinishga** tegishli (`maxRetries:1` → 2×). Mijoz 60s da uzadi,
  shuning uchun EF 25s — aks holda mijoz ketgach ham ishlab token yoqardi.
- Mijozda: `sb.functions.invoke` **`{data,error}`** qaytaradi (throw qilmaydi); xato = **kehribar
  `err` qatori**, soxta AI javobi YO'Q; `err` qatorlari keyingi so'rovga yuborilmaydi; Claude javobi
  ham `escapeHtml` dan o'tadi. `code==='bad_input'` bo'lsa rad etilgan `me` qatori tarixdan
  **o'chiriladi** (aks holda u har so'rovda qayta yuborilib chat qotib qolardi).
- Deploy: `EF_AI_CHAT_DEPLOY.txt` (Asilbek bajaradi). Old shart: `PROVODKA_PAGES_EMPTY.sql`
  (`perm_has_page` o'sha yerda) + `PROVODKA_AI_AGENT.sql`. Birinchi so'rovdan keyin
  `supabase functions logs ai-chat` — 400 kelsa `thinking`/`output_config` qatorlarini olib tashlash.

### 5-bosqich (2026-08-14/15) — `BRIEF_PROVODKA_AI_5.md`, moliyaviy tahlilchi
**1. 5 analitika RPC** — `PROVODKA_AI_HISOBOT.sql` (**RUN kutilmoqda**): `ai_rep_xarajat`
(`xodim|kategoriya|filial`), `ai_rep_kirim` (`manba|filial`), `ai_rep_cashflow`, `ai_rep_balans`,
`ai_rep_jurnal`. 🔴 **Mavjud hisobot mantiqi QAYTA YOZILMAYDI — o'raladi**: `balans()`,
`cashflow_kassa()/pul_qoldiq_kassa()` (davr boshi = `p_from−1` — `cashflow-dev.html` bilan bir xil),
`jurnal()`, `pnl()` zinapoyasi. Sabab: nusxa ko'chirilsa hisobot sahifasi o'zgarganda **AI boshqa
raqam aytadi**. Sahifa qorovuli: xarajat/kirim→`hisobot`, cashflow→`cashflow`, balans→`balans`,
jurnal→`jurnal`. `pnl_bolim` (butun kompaniya foydasi) kassa cheklovi bor userga **berilmaydi**.
🔴 **Ikki sizish topildi va tuzatildi (2026-08-15)**:
  (a) **Summa orqali sizish** — qorovul YOZUV darajasida edi ("kamida bitta satr meniki"), summa esa
      butun yozuvniki. `professional.html` ko'p satrli yozuv yozadi (Dt Ijara 10 mln / Kt meniki 1 mln /
      Kt begona 9 mln) → kategoriya qatoriga 10 mln tushib begona pul `jami` orqali sizardi va
      `xodim` kesimi 1 mln deb **zid** raqam berardi. Yechim **fail-closed**: yozuvda begona pul satri
      bo'lsa u umuman hisobga olinmaydi (pro-rata ataylab tanlanmadi — taxminiy raqam berardi).
  (b) **`root_ids` ruxsatni kengaytirardi** — `view_kassa_ids` da yolg'iz bola-hisob (56xx USD,
      Click bolasi) tursa `perm_op_key` uni parentga ko'tarib, cashflow **butun oilani** berardi;
      mijozdagi `keyOf()` esa hech narsa ko'rsatmaydi. Endi manba `pul_ids` (u allaqachon
      `perm_op_key(a.id)=any(view_kassa_ids)` dan o'tgan) — UI haqiqati bilan bir xil.
🔴 **`ai_rep_jurnal` maskalashi FAIL-CLOSED** (Asilbek talabi 2026-08-15): u `jurnal()` javobidagi
`section`/`account_id`/`is_deleted` **kalit nomlariga** tayanadi. Avval kalit yo'q bo'lsa `false`
(= "begona emas") deb hisoblanardi, ya'ni RPC kontrakti o'zgarsa himoya **jimgina ochilib** begona
kassa nomi/kodi ko'rinardi. Endi 4 joyda teskari: `begona_raw`/`shubha`/`dt_y`/`kt_y` — kalit yo'q,
`uuid` shaklida emas yoki `lines` bo'sh bo'lsa **maskalanadi**; `is_deleted` yo'q bo'lsa yozuv
**o'chirilgan** deb hisoblanadi. Javobda `shakl_shubhali` bayrog'i qaytadi — model "ma'lumot yo'q"
demasin, "kontrakt o'zgargan" deb tushuntirsin (jimgina kam ko'rsatish ham xato manbai).
⚠️ `uuid` cast `case ... ~ '^[0-9a-fA-F-]{36}$'` bilan o'ralgan — buzuq qiymat 22P02 bilan butun
so'rovni yiqitmasin.

**2. Chart** — javobdagi ```` ```chart ```` bloki (`type/columns/rows/total`, yorliq birinchi,
**raqam oxirgi**): mijozda **inline SVG** (pie/bar/line) + jadval + Excel. Chart.js **yo'q** —
bog'liqlik nol, dark/print ishlaydi, palitrada har qadam ≥80° tus siljishi (pie'da qo'shni segmentlar
qo'shilib ketmasin). Blok DB'da **saqlanadi** (suhbat qayta ochilganda chart qayta chiziladi), lekin
EF'ga yuboriladigan tarixda `[diagramma]` ga siqiladi (4000 belgi chegarasi chatni qotirardi).
**3. Excel** — `vendor/xlsx-0.18.5.min.js` (SheetJS), 🔴 **LAZY**: `<script>` tegi yo'q, faqat
"📥 Excel" birinchi bosilganda yuklanadi; yiqilsa CSV zaxirasi (BOM + `sep=;`). Raqamlar Excel'da
**raqam** bo'lib yoziladi. ⚠️ Faqat OXIRGI ustun raqam deb o'qiladi — aks holda hisob kodi
`5403` → `5 403` bo'lib ketardi.
**EF**: 8 tool (3 + 5), `MAX_TOOL_ROUNDS` 4→6, `TOOL_RESULT_MAX` 20k→30k. `p_kesim` noto'g'ri bo'lsa
**jimgina sukutga tushmaydi, XATO qaytaradi** (aks holda "filial kesimi" so'ralib "xodim kesimi"
javob berilardi). ⚠️ Xom `sqlerrm` modelga **berilmaydi** (ichki tuzilma sizmasin) — server logida qoladi.

### 4-bosqich (2026-08-14) — `BRIEF_PROVODKA_AI_4.md`, 4 ish
**1–2. SSE streaming + thinking**: EF `text/event-stream` qaytaradi. Hodisalar: `status`
(`thinking|search|read|tool`) · `thinking` · `text` · `sources` · `done` · `error`, har 15s `: ping`.
🔴 Auth/ruxsat/rate-limit/validatsiya **stream boshlanishidan OLDIN** — ular hamon JSON 401/403/429/400.
Oqim boshlangach HTTP statusni o'zgartirib bo'lmaydi → xato `{type:'error'}` hodisasi bo'lib boradi.
`pause_turn` va `tool_use` **bitta oqim ichida** davom etadi (yangi pufak ochilmaydi). Mijoz
`sb.functions.invoke` dan **`fetch` + `ReadableStream`** ga o'tdi (invoke stream qila olmaydi);
delta'da butun ro'yxat qayta chizilmaydi — faqat oqim pufagining tugunlari. Eski JSON javob uchun
mijozda **zaxira** bor (EF deploy qilinmagan bo'lsa ham chat ishlaydi).
`thinking.display:'summarized'` yoqilgan (avval bo'sh kelardi) — qo'shimcha token, `AI_THINKING_DISPLAY=omitted`
bilan o'chadi; API rad etsa tur avtomat `display` siz qayta chaqiriladi. **`AI_EFFORT` endi CHEGARA**
(ceiling), `pickEffort()` savolga qarab tanlaydi: salom→low, oddiy→medium, hisob/tahlil/qonun/uzun/rasm→high.
**3. Aros konteksti**: 24 filial, avto ehtiyot + elektronika, double-entry, kassa/pul turi/valyuta/
transfer, 4010/6010. 🔴 "MAJBURAN BOG'LAMA" bandi — aloqasi bo'lmasa Aros tilga olinmaydi.
**4. Provodka DB — tool calling**: `PROVODKA_AI_KONTEKST.sql` (**RUN kutilmoqda**) — 3 ta RPC
(`ai_ctx_kassa`, `ai_ctx_qarzdor`, `ai_ctx_transfer`), hammasi `security definer`, **foydalanuvchi ID
argumenti YO'Q** (faqat `auth.uid()`), `auth.uid() is null` → **bo'sh** (mavjud `perm_has_page` ning
fail-OPEN naqshi ataylab takrorlanmagan). Kassa filtri `perm_op_key()` — mijozdagi `keyOf()` bilan
bir xil qoida (valyuta/pul turi bolalari ruxsatni parentdan oladi). Transferda begona tomonning
kodi/nomi **va izohi** yashiriladi (izohda kassa nomi turadi). 🔴 **Sahifa qorovuli uchala RPC da**
(Asilbek qarori): kassa→`'kassa'`, transfer→`'jurnal'`, qarzdor→`'qarzdor'` — busiz faqat `'ai'`
ruxsatli va `kassa_scope='all'` (DEFAULT) user UI'da yopiq sahifaning ma'lumotini AI orqali olardi.
EF tomonda: RPC'lar **foydalanuvchi JWT si** bilan (service_role YO'Q), model bergan sana regex **va
kalendar** bilan tekshiriladi, RPC xatosi modelga **"XATO"** bo'lib boradi (hech qachon "ma'lumot yo'q"
ga aylanmaydi — aks holda AI raqam to'qiydi), parallel `tool_use` lar **bitta** user xabarida qaytadi,
`MAX_TOOL_ROUNDS=4` (`MAX_CONTINUATIONS` dan **alohida** hisoblagich).
⚠️ Konvert (5011→5611, bitta kassa ichida) transfer deb **sanalmaydi** (`perm_op_key` ildizi bir xil).

### 3-bosqich (2026-08-13/14) — `BRIEF_PROVODKA_AI_3.md`, 4 ish
**1-ish — web_search** (EF): tool `web_search_20260209` (briefdagi `_20250305` emas — Sonnet 5 da
dynamic filtering bor; qaytarish `AI_SEARCH_TOOL` env bilan). 🔴 `thinking:adaptive` + `effort:high` —
Sonnet 5 thinking o'chiq holatda **asbobni kam chaqiradi**, ya'ni qidirmasdan javob berardi.
🔴 **`pause_turn` sikli** (`MAX_CONTINUATIONS=3`): server tool uzoq ishlaganda javob shu bilan
tugaydi — busiz foydalanuvchi **yarim javobni to'liq deb** o'qirdi; assistant turi **o'zgartirilmasdan**
qaytariladi (tahrirlangan thinking bloki 400 beradi). Manbalar `sources:[{title,url}]` (faqat `http(s)`,
≤8, dublikatsiz) → chatda chip. ⚠️ `web_search_tool_result.content` **xatoda massiv emas, obyekt** —
`Array.isArray` indekslashdan oldin. Narx/vaqt qorovullari: `AI_SEARCH_MAX_USES` (bitta so'rovga)
**va** `AI_SEARCH_TOTAL_MAX` (turlar bo'ylab — busiz 4×5=20 qidiruv ≈ $0.20), umumiy **100s deadline**
(mijoz 120s; EF mijozdan keyin ishlab token yoqmasin).

🔴 **VAQT BYUDJETI — 2026-08-14 dagi prod nosozligi saboqi.** Deploy'dan keyin HAR so'rov yiqildi:
`ai-chat: Anthropic xato (tur 0 ): null Request timed out.` Sabab **web_search formati EMAS** (format
xato bo'lsa **400** kelardi; `status null` = HTTP javob umuman kelmagan) — kodda bitta turga
`Math.min(left, 45_000)` chegarasi bor edi, u **2-bosqichdan** (qidiruvsiz chat: `thinking:disabled`,
`effort:medium`, `max_tokens:4000` → javob 10–15s) qolgan. `thinking:adaptive` + `effort:high` +
`max_tokens:8000` bilan faqat generatsiya 100s+ bo'lishi mumkin. Endi tur qolgan byudjetning hammasini
oladi (`TOTAL_BUDGET_MS=105s`, mijoz 120s). ⚠️ Invariant: **`MIN_TURN_MS > TURN_MARGIN_MS + floor(10s)`**
— aks holda tur byudjetdan oshadi. ⚠️ Timeout aniqlagich **statusga bog'langan** (`null|408|504`) —
aks holda matnida "timeout" so'zi bor har qanday 400 noto'g'ri tashxis berardi.
Tezlashtirish (deploy'siz, ta'sir tartibida): `AI_EFFORT=medium` → `AI_SEARCH_MAX_USES=3` →
`AI_SEARCH_TOOL=web_search_20250305`. Streaming (SSE) muammoni butunlay yechadi, lekin mijoz+EF+
`pause_turn`+manba yig'ish qayta yozilishini talab qiladi — 4-bosqich bilan birga rejalashtirilsin.

**2-ish — suhbat tarixi DB'da**: `PROVODKA_AI_CHAT.sql` (**RUN kutilmoqda**) — `ai_conversations`
(soft-delete) + `ai_messages` (`sources jsonb`, `model`). RLS: 4+4 policy, `user_id = (select auth.uid())`;
🔴 `ai_messages` insert/update `with check` ichida **`exists(... ai_conversations ...)`** — `user_id` ni
to'g'ri qo'yishning o'zi yetarli emas, begona suhbatga yozib bo'lmaydi. Trigger `security definer` EMAS.
Mijozda yon panel (`.aic-*`, ChatGPT uslubi, mobil'da drawer); suhbat **birinchi savolda** yaratiladi;
`user_id` mijozdan **yuborilmaydi** (DB default). 🔴 **Jadval yo'q bo'lsa** (`42P01`/`PGRST205`) panel
yashirinadi va chat **xotira rejimida** avvalgidek ishlaydi — SQL run qilinmaguncha ham buzilmaydi.
🔴 `apiMsgs()` tarixni EF chegaralariga moslaydi: ≤20 xabar, ≤20000 jami **va ≤4000 HAR XABAR** —
oxirgisi bo'lmasa 4000+ belgilik AI javobi bor suhbat qayta ochilganda EF **abadiy 400** berardi
(tarix DB'da bo'lgani uchun F5 ham qutqarmasdi). Rad etilgan savol DB'dan `aicDropMsg` bilan olinadi.

**3-ish — rasm/fayl**: mijozda rasm `canvas` bilan 1568px ga kichraytiriladi, PDF ≤4 MB, jami ≤6 MB;
EF blok turlarini **whitelist** bilan qayta quradi (`text|image|document`, faqat `base64`;
`image.source.type='url'` **rad etiladi** — SSRF). 🔴 DB'ga base64 **yozilmaydi** (tarix shishmasin) —
faqat matn + `[2 rasm, chek.pdf]` belgisi.

**4-ish — floating tugma**: yuqoridagi `ai-widget-dev.js` bo'limiga qara.
**`?embed=1`** (`ai-dev.html`): widget iframe'i uchun ko'rinish rejimi — nav/bnav/sheet yashiriladi,
chat butun oynani egallaydi, suhbatlar paneli **doim drawer** (tor iframe'da ustun sig'maydi).
Mantiq, ruxsat, EF — **bir xil**. Esc iframe ichidan otaga yetmagani uchun
`postMessage({source:'aros-ai',type:'close'}, location.origin)` yuboriladi; widget uni
**`e.origin` VA `e.source === frame.contentWindow`** bilan tekshiradi (begona sahifa yopolmaydi).
⚠️ CSS: `html.ai-embed …` qoidalari kenglik media query'laridan kuchli (0,2,1 > 0,1,0) —
yangi qoida qo'shsangiz `body.aic-off` holatini ham tekshiring (o'lik tugma chiqib qolmasin).

### 1-bosqich (interfeys + ruxsat)

- **Alohida sahifa, widget emas** — har sahifa mustaqil bo'lgani uchun chat 15 faylga ko'chirilmadi;
  `ai-dev.html` bitta fayl, ruxsat `permGate()` bilan avtomat ishlaydi.
- **Ruxsat — mavjud SAHIFA tizimiga `ai` kaliti** (yangi `op_ai_agent` ustuni EMAS). Shu tanlov tufayli
  `admin_set_provodka_perms` imzosi, `my_perms()` va **n8n payload kontrakti umuman o'zgarmadi**.
  Uch joyda AYNAN bir xil bo'lishi shart: `perm_pages()` (`PROVODKA_AI_AGENT.sql`, 15→16) =
  `perms-dev.js` `PAGES` = `admin-dev.html` `PVS_PAGES` (`{key:'ai', label:'AI agent'}`).
  Birortasida yo'q bo'lsa `admin_set_provodka_perms` kalitni **jimgina tashlaydi**.
- Nav: 15 dev faylda sidebar (15-element) + "Ko'proq" sheet (9-element), `sparkles` ikonkasi.
  bnav tegilmagan (6 + Ko'proq). `promote.sh` `PAGES` ga `ai` qo'shilgan — **busiz prod'da
  `ai-dev.html` havolalari qolib ketardi**.
- 🔴 Klientda API kaliti/tarmoq chaqiruvi YO'Q; xabarlar `escapeHtml()` bilan chiziladi; chat tarixi
  faqat xotirada (localStorage/DB emas). Stub javob soxta ma'lumot bermaydi ("AI hali ulanmagan").
- ✅ 2-bosqichda bajarildi: EF ruxsatni server tomonda tekshiradi (yuqoridagi AND qoidasi).
  `perm_has_page()` ning birinchi chaqiruvchisi — shu EF.
- ⚠️ **`gate()` endi bosh sahifada YO'NALTIRADI** (`perms-dev.js`, 2-bosqich): bosh sahifa yopiq
  bo'lsa "Ruxsat yo'q" ekrani o'rniga `firstAllowed()` sahifasiga `location.replace`. Faqat `ai`
  ruxsatli user darrov AI sahifasiga tushadi. ⚠️ Bu **hamma cheklangan userga** tegadi (masalan
  faqat `kassa` ruxsatlisi ham endi jimgina kassaga tushadi) — ataylab. `firstAllowed()` konvertni
  `can_convert=false` bo'lsa o'tkazib yuboradi, aks holda redirect yana deny ekraniga olib borardi.
- ℹ️ `#banner` bo'sh turibdi — 2-bosqichda EF xatosini ko'rsatish uchun (boshqa sahifalar naqshi).

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

### Jurnal V3 (2026-08-30, `BRIEF_PROVODKA_JURNAL_V3.md`) — faqat `jurnal-dev.html`

- **Tovar harakati jurnalda YO'Q** — server filtri, `PROVODKA_JURNAL_PUL.sql`: `jurnal_v2_baza`
  `p_turlar` ichida **`'pul'` tokeni**ni tushunadi (kamida bitta satri `section='pul'`; chala yozuv
  n=0 istisno — diagnostika). Token qolgan tur kalitlari bilan AND. Imzo/returns o'zgarmagan
  (`create or replace`, drop yo'q); `jurnal_v2/count/dash/ijrochilar` avtomat oladi. Prod `jurnal.html`
  tokenni yubormaydi → ta'sir yo'q. Klient: `jurnal_pul_filtr_ok()` → `usePul` (swr `pulok`, 1 kun);
  🔴 `loadUsePul()` `init()` da `load()` dan **OLDIN `await`** — bitta `Promise.all` da bo'lsa `load()`
  `argsV2` ni sinxron qurib tokensiz ketadi. Kesh kaliti `usePul` ni o'z ichiga oladi.
  🔴 Klientda tovar filtri YOZILMAYDI (sahifalash/count buziladi).
- **Ustunlar (desktop, 13/14):** № (+id 8 belgi, bosilsa copy) · Kiritilgan (`created_at`) ·
  Xarajat sanasi (`entry_date` + `davr_start/end`) · Qayerdan (Kt) · Qayerga (Dt) · Ijrochi ·
  Valyuta (pul satrining `currency`, USD → `fc_amount`) · Summa · Maqsad (`metaTags` chiplari:
  maxsus maydon, kommunal, filial, yuk — AI va davr tegisiz) · Izoh (`description`, o'chirish/chala
  izohi) · **AI xulosasi (2026-08-31 dan HAMMAGA — jurnal ruxsati yetarli; EF trigger baribir admin)** · Fayl (Chek/Hujjat/
  AI chek/Tablo → `openChek`) · Amallar. `maqsadHtml`/`sanaHtml` yo'q: `kiritHtml`, `xarajatHtml`,
  `valyutaCell`, `ijrCell`, `maqsadCell`, `izohCell`, `aiCell`, `faylCell`. Mobil `.jc-row` yorliqli.
- **AI xulosasi ustuni:** `refreshMeta()` 2-bosqich (2026-08-31 dan hammaga; `rasm_tahlil`/
  `mashina_km` RLS har userga faqat O'Z yozuvini beradi — begonasida chip bor, tafsilot yo'q) —
  `rtMap` (`rasm_tahlil` id bo'yicha)
  + `kmMap` (`mashina_km` entry bo'yicha). Chip: Shubhali / AI xato / Kutilmoqda / Tekshirmagan /
  Mos; ostida AI summa·sana (farq qizil), Tablo km (yozilgan farqi, yurgan km, so'm/km). Modal
  (`openChek`+`renderChekAi`) — batafsil ko'rinish, o'zgarmagan. Excel ustunlari tegilmagan.
- **Avto-tekshiruv + izoh↔modda AI (2026-08-31, faqat jurnal-dev):** `autoIssues(e,k)` —
  klientda, AI'siz, faqat CHIQIM: izoh <5 belgi / modda nomini takrorlaydi; sana: `entry_date ≠`
  kiritilgan kun (davrli yozuv istisno). `flagIssues()` = autoIssues + `entry.izoh_mos===false`
  + `entry.shubhali` → **Dt (Qayerga) katagi qizil fon** (`td.j-dt.j-flag`, mobil `.jc-acc.j-flag`),
  sabab title'da + AI xulosasi ustunida qizil satr (`.ai-sub.ai-auto`). "Faqat shubhali" filtri
  bularni ham oladi. **Izoh↔modda semantikasi — EF `izoh-tekshir`** (Haiku, admin-only, my_perms
  fail-closed, ≤20 yozuv/so'rov, har yozuv BIR marta): natija `entry.izoh_mos/izoh_sabab/
  izoh_tekshir_at` (`PROVODKA_IZOH_TEKSHIR.sql` — RUN kutilmoqda; `izoh_tekshir_yoz` RPC user JWT,
  service_role YO'Q; description tahrirlansa trigger verdictni null qiladi). Deploy:
  `EF_IZOH_TEKSHIR_DEPLOY.txt`. 🔴 SQL/EF yo'q bo'lsa hech narsa sinmaydi: `aiSel()` 42703 da eski
  ustun ro'yxatiga tushadi, `izohAiTekshir()` `'izoh_mos' in am` sharti bilan jim chiqadi.
- **Tor ekran (2026-08-31):** AI xulosasi ustuni 1272px oynada ekrandan chiqib "yo'qolgan" edi —
  sana/sarlavha/ijrochi `nowrap`lari olib tashlandi (Summa/Valyuta nowrap qoladi), `@media
  (max-width:1439px)` da padding 4px + `.j-id` yashirin + kt/dt `overflow-wrap:anywhere`.
  Jadval 1433→~975px, 14 ustun ekranga sig'adi; `<1300px` jwrap skroll zaxirasi qoladi.

### Rasm AI — prod 403 sabog'i (2026-08-30)

`rasm-detect` EF avval `has_provodka || is_admin` talab qilardi; uni chaqiradigan yagona sahifa
`hodim.html` esa `allowed_pages` bilan cheklanmaydi → 80% user 403 olardi, klient jimgina yutardi.
Endi EF: yaroqli sessiya + `my_perms()` xatosiz = ruxsat (fail-closed saqlanadi). Klient xatoni
konsolga HTTP status bilan yozadi. **Spidometr moddasi (`spidometr_ai`) endi chekni ham majburiy +
AI qiladi** (`chekRequired()`/`aiChekOk()` ikkala bayroqni ko'radi): benzin/gaz = chek + tablo.

### Xarajatga JADVAL biriktirish (2026-09-02, `BRIEF_PROVODKA_JADVAL.md`) — faqat dev

Hodim Excel'dan oziq-ovqat ro'yxatini (40 qator × 5 ustun) Izoh maydoniga qo'yardi — `<input>`
qator/tab belgilarini yutib `description` 1500 belgilik blob bo'lardi (Telegram + jurnal hunuk).
Endi jadval **izohdan alohida**: `entry.jadval jsonb` (`PROVODKA_JADVAL.sql`, RUN kutilmoqda).
Shakl: `{v:1, manba:'paste'|'xlsx', fayl, cols:[], rows:[[...]], jami, n}` — katak raqamga
o'xshasa **number** (`210 000,00` → 210000), aks holda string; `jami` = kataklarida
`жами|хаммаси|hammasi|jami|итого|всего|total` bo'lgan qatorlardagi eng katta raqam.
Chegara: ≤500 qator, ≤16 ustun, klient ≤100 KB (server constraint 120 KB).
- **`hodim-dev.html`** (`.jd*`, `jadvalParse()` sof funksiya): `#izoh` `paste` hodisasi — matnda
  `
` VA (`	` yoki ≥3 raqamli qator) bo'lsa jadval deb olinadi, izoh o'zgarmaydi; «Excel yuklash»
  — `vendor/xlsx` LAZY (`ai-dev` naqshi). Karta: qator soni · jami · oldindan ko'rish · ✕;
  summa bo'sh bo'lsa jami avtomat to'ldiriladi (faqat UZS), farq bo'lsa sariq ogohlantirish
  (bloklamaydi). **4 saqlash yo'li**: oddiy insert (`entryPayload.jadval`), taqsim/ovqat
  (`p_data.jadval` — RPC'larning oxirgi versiyasi `PROVODKA_JADVAL.sql` da qayta e'lon qilingan),
  pul so'rash (`sorov_yarat` dan KEYIN `entry_jadval_yoz(p_ext_ref, p_jadval)` — imzo o'zgartirish
  taqiq bo'lgani uchun alohida RPC: egalik `created_by`, 30 daqiqa, bir marta). Top-up yo'lida
  entry yo'q — chaqirilmaydi. 🔴 `jadval===null` bo'lsa payloadga kalit QO'SHILMAYDI — ustun yo'q
  bazada oddiy xarajat 42703 bilan yiqilmasin; jadvalli insert 42703 bersa jadvalsiz QAYTA insert
  qilinmaydi (ext_ref takror), toast + `tokenTugat()`.
- **`jurnal-dev.html`**: `refreshMeta()` faqat `jd_n:jadval->n,jd_jami:jadval->jami` o'qiydi
  (to'liq jadval emas; 42703 → eski ustun ro'yxati, `aiSel` naqshi). Izoh katagida chip
  «Jadval · N qator · jami» → `#jdModal` (`.jd-*`, chek modalidan alohida) — to'liq jadval
  bosilganda o'qiladi, «Excel» mavjud lazy `loadXlsx()` + CSV zaxira. `autoIssues()` "izoh <5
  belgi" qoidasi jadvalli yozuvda o'tkazib yuboriladi.
- **Telegram**: `PROVODKA_JADVAL_NOTIFY.sql` — `hodim_notify_pending` javobiga `jadval_n/jadval_jami`
  (`to_jsonb(e)` naqshi — ustun yo'q bo'lsa null). `N8N_XABAR_TUZ.js` = `N8N_HODIM_NOTIFY.js`
  ichidagi `jsCode` (bayt-ma-bayt, ikkalasi birga tahrirlanadi): izoh 300 belgidan kesiladi,
  «📋 Jadval: N qator · jami X so'm». n8n'ga **qo'lda** qo'yiladi (MCP update kreditlarni uzadi).
- **Modda bayrog'i `accounts.excel_jadval`** (`PROVODKA_JADVAL_2.sql`, RUN kutilmoqda; `sozlama-dev`
  «Excel» katakchasi, `set_modda_flag(...,'excel',...)`): jadval FAQAT yoqilgan xarajat turida —
  `jadvalOk()` false bo'lsa paste oddiy o'tadi, Excel tugmasi yashirin, modda almashsa jadval tozalanadi.
  Ustun bazada yo'q bo'lsa (undefined) hamma joyda o'chiq. `jdApplyTo/jdRenderInto` — bitta yadro,
  ikki holat (`JD_STATE_MAIN` asosiy forma, `JD_STATE_RX` Ruxsat so'rash Tab 2).
- **Ruxsat so'rash (Tab 2)**: `ruxsat_yopiq_moddalar()` javobida `excel` kaliti; yoqiq bo'lsa `#rxJdWrap`
  (Excel + paste) → `ruxsat_yarat` dan KEYIN `ruxsat_jadval_yoz(p_ext_ref, p_jadval)` (`ruxsat_sorov.jadval`;
  egalik `hodim_id`, pending, 30 daqiqa, bir marta). `ruxsat_tasdiq` jadvalni yaratilgan `entry` ga
  ko'chiradi. `ruxsat_qator`/`sorov_qator` ro'yxatga `jadval_n/jadval_jami` beradi (to'liq jadval emas).
- **`sorovlar-dev.html`**: kartada chip «Jadval · N qator · jami» → `#jdModal` (jurnal-dev nusxasi, z-index 210);
  ruxsat → `ruxsat_sorov.jadval` (RLS: hodim/kimdan/admin), pul so'rash → `entry.jadval` (`entry_id`).

## Avtomatik sinxron (n8n)

`Aros Provodka - Auto Sync` (`7MSHrXnz9cGAFBTh`), har 30 daqiqada:
1. Qabul qilingan transferlar → `Dt markaziy kassa / Kt filial kassa`.
   Summa = `items[].confirmed_total` yig'indisi (**reja emas** — `total_amount` ustuni rejani saqlaydi).
2. Filial balansi o'sgan bo'lsa → `Dt filial kassa / Kt savdo tushumi`.
   **Kamayish e'tiborsiz qoldiriladi** — u transfer bilan yoziladi, ikki marta tushmasin.

Boshqa workflowlar: `aros-filial-live` + `aros-currencies` (`lco21f7pUcKPpNVU`),
`aros-currency-rates` (`VDezk7eRnwktu2AX`), `aros-dollar-rate` (`7VyISbPe0ZJqIH0Z`),
`Aros Provodka - Staff Sync` (`gIPsXToNmSWFWF53`, soatlik — aros_staff/staff_branch_map).

🔴 **aros-staff API RATE-LIMIT saboqi (2026-08-31, "Andijon yo'qolishi"):** `api.staff.aros.uz`
~60 so'rov/daqiqadan keyin HAMMA so'rovga `{"detail":"Request was throttled"}` qaytaradi
(status xatoga o'xshamaydi, `neverError` bilan jimgina "bo'sh" natija bo'lib o'tib ketadi).
Staff Sync 150ms interval bilan urardi → 59-so'rovdan keyin detail/branch ma'lumoti yo'qolar,
faqat list'dagi primary filial qolar edi — primary'siz hodimlar (Andijon, Navoiy yordamchi
filiallar) `branches:[]` bilan saqlanib "hodim topilmadi" berardi ("33 hodimda 404" afsonasi
ham aslida shu). Tuzatish: interval 1100ms (~4 daq sinxron), retry 3x, Build Payload detail'ni
javobning O'Z `id`si bo'yicha juftlaydi va `throttled` hisoblagichini chiqaradi (0 bo'lmasa
yana sekinlatish kerak). Yangi so'rov qo'shganda shu limitni unutma.

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
  ko'rmaydi. Shuning uchun `</script>` sonini ham tekshir: **15 navigatsiyali dev faylda 5 ta**
  (`vendor/lucide` + `vendor/supabase` + `perms-dev.js` + `ai-widget-dev.js` + module),
  `ai-dev.html`/`hodim-dev.html` va prod fayllarda **4 ta**. Farq bo'lsa fayl buzilgan.
- **Skript bilan ommaviy tahrir qilganda `str.replace(re, string)` ISHLATMA — `replace(re, () => string)`
  ishlat.** String almashtirishda `$'` "moslikdan keyingi hamma narsa", `$&` "moslikning o'zi",
  `$1` guruh degani. Kodimizda `+' $':money(...)` bor — ya'ni `$'` — va u jimgina faylning butun
  qolgan qismini shablon o'rtasiga qistiradi. `node --check` buni sezmaydi (yuqoridagi sabab).
- Dizaynni bir faylda o'zgartirsang, qolgan 6 tasiga ham tushir (aks holda ular ajralib qoladi).
- SQL DDL'ni Asilbek o'zi RUN qiladi — SQL yozib ber, o'zing bajarma.
- 🔴 **SQL faylning `--` IZOHIDA ham dollar-qavs (`$` + `$` yonma-yon) YOZILMAYDI.**
  Supabase editori juftlikni sanayotganda izohni o'tkazib yubormaydi: izohdagi belgi
  soxta blok ochadi, keyingi `as $$` uni yopadi va funksiya **tanasi top-level SQL**
  bo'lib bajariladi → `ERROR: 42P01: relation "<plpgsql o'zgaruvchisi>" does not exist`.
  Xatodagi nom — ochiq oraliqdagi **birinchi `select … into X`** nishoni, ya'ni u
  faylning o'rtasidagi funksiyada chiqishi mumkin va sabab noto'g'ri joyda izlanadi.
  (2026-08-25: uch fayl bir vaqtda shundan yiqildi.) "Anonim `do` bloki" deb yoz.
  Qo'shimcha himoya: funksiya tanasiga **nomlangan teg** (`$fn$`) ishlat — u holda
  izohdagi belgi parityga ta'sir qilmaydi.
  Tekshiruv: har dollar-teg soni JUFT va funksiya soniga mos bo'lsin — izohlarni
  **hisobga olib** sana (to'g'ri lekser bilan sanasang muammoni ko'rmaysan).
