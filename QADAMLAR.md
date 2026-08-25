# QADAMLAR — Asilbek uchun bosqichma-bosqich ro'yxat

Holat: 2026-08-25. Har qadam bajarilgach ✅ qo'ying.

🔴 **Umumiy qoida:** SQL dev va prod uchun **bitta baza**. Ya'ni SQL RUN qilingan
zahoti prodga ham ta'sir qiladi. HTML esa faqat `promote.sh` dan keyin chiqadi.
Shuning uchun **pul oqimiga tegadigan SQL** faqat UI tayyor bo'lganda RUN qilinadi.

---

## A. HOZIR BAJARILADI — 70% to'siq + qarzni o'chirish

Fayl: **`PROVODKA_TOSIQ_OCHIR.sql`** (tayyor). Bo'limlarni **bittalab** RUN qiling.

| # | Nima | Kutilgan natija |
|---|------|-----------------|
| A1 | **0.1 – 0.4** bandlari | Faqat o'qiydi. 🔴 **0.4** natijasini Fable'ga yuboring |
| A2 | **1-BO'LIM** (2 qator) | Trigger o'chadi → 70% to'sig'i **butunlay ishlamay qoladi** |
| A3 | **2-BO'LIM** | Prod funksiyalari tiklanadi (`xarajat_saqlash_taqsim`, `hodim_oz_tarix`, `hodim_oy_jami*`) |
| A4 | **3-BO'LIM** | 18 obyekt drop (trigger, RPC, view, config kaliti) |
| A5 | **4-BO'LIM** | 🔴 **FAQAT 0.4 `BOSH` desa.** `YOZUV BOR` desa — TO'XTANG, Fable'ga ayting |
| A6 | **6-BO'LIM** | Yakuniy tekshiruv — hamma ustun `true` bo'lsin |

⚠️ A5 dagi `accounts.hodim_kassa_id` ustunini o'chirish — **yagona qaytarib
bo'lmaydigan** qadam. Faylda shunday belgilangan.

**Klient tomoni allaqachon tayyor:** 5 dev fayldan to'siq/qarz/to'lanmagan UI si
olib tashlangan (`hodim`, `kassa`, `jurnal`, `provodka`, `professional`).
Qoldiq murojaat — hamma faylda **0**. `provodka-dev.html` va `kassa-dev.html`
to'siqdan oldingi commit bilan **bayt-ma-bayt teng**.

---

## B. KEYIN — So'rovlar tizimi

| # | Nima | Holat |
|---|------|-------|
| B1 | `PROVODKA_SOROVLAR.sql` **0.2 / 0.3 / 0.4** (faqat o'qiydi) | tayyor |
| B2 | 0.2 — `entry.status` da cheklovchi CHECK bormi | natijani Fable'ga |
| B3 | 0.3 — `posted` filtri auditi | `FILTR YOQ` chiqsa Fable'ga |
| B4 | 0.4 — "kimdan so'rash" nomzodlari | **bo'sh chiqsa** ruxsat sozlash kerak |
| B5 | Qolgan bo'limlarni RUN | 🔴 **faqat klient tayyor bo'lgach** |
| B6 | Klient: `sorovlar-dev.html` sahifasi + nav/ruxsat ro'yxati | ✅ tayyor |
| B7 | Klient: `hodim-dev.html` "Pul so'rash" modali | ⏳ ishlanmoqda |
| B8 | 🔴 **`admin-dev.html` → `PVS_PAGES` ga `sorovlar` qo'shish** | ⚠️ **SIZ** — boshqa repoda |

🔴 **B8 — bu repoda bajarib bo'lmaydi.** `admin-dev.html` **TaskFix repozitoriyasida**,
shu repoda emas. Unga `PVS_PAGES` ga `{key:'sorovlar', label:"So'rovlar"}` qo'shilmasa
admin hech kimga `sorovlar` sahifa ruxsatini **bera olmaydi** va sahifa hech kimda
ko'rinmaydi. `perm_pages()` (SQL) va `perms-dev.js` da u allaqachon bor.

🔴 **B4 muhim:** nomzod bo'lish uchun odamda `kassa_scope='list'` + o'z UZS
kassasi + `sorovlar` sahifa ruxsati bo'lishi kerak. **Admin va `all` scope
userlar ro'yxatga tushmaydi** (ularga kassa biriktirilmagan). Bugalter ro'yxatda
ko'rinishi kerak bo'lsa — `admin-dev.html` dan unga kassa + sahifa berilsin.

---

## C. KEYINGI BOSQICHLAR (hali boshlanmagan)

| # | Nima |
|---|------|
| C1 | Jurnal: Boshlang'ich + Tugash miqdor (SQL + UI) |
| C2 | Kassa sahifasida qidiruv (faqat UI) |
| C3 | Universal xarajat maydonlari — `PROVODKA_XARAJAT_MAYDON.sql` tayyor, klient qolgan |
| C4 | Hodim amallar tarixi — `PROVODKA_HODIM_AMALLAR.sql` tayyor, klient tayyor |

---

## D. OCHIQ MASALALAR — qaror kutilmoqda

| # | Masala | Kimdan |
|---|--------|--------|
| D1 | 6721 da qarz yozuvlari bo'lsa: qoldiramizmi yoki provodka bilan yopamizmi? | Asilbek |
| D2 | So'rovni **admin** boshqa odam nomidan tasdiqlay oladimi? (hozir: **yo'q**, fail-closed) | Asilbek |
| D3 | 13 ta yetim sarlavha (`entry` bor, `entry_line` yo'q) — jurnalda "Chala yozuv" deb belgilash | Fable qiladi |
| D4 | `provodka.html` / `professional.html` yozuvni **atomik** qilish (yetim sarlavha ildizi) | Fable qiladi |
| D5 | Telegram bot — `DIAG_BOT.sql` natijasi | Asilbek RUN qiladi |
| D6 | Yetim sarlavhalarni nima rad etgani (xato matni) | Asilbek/hodim |

---

## E. PROD'GA CHIQARISH (hammasi tayyor bo'lgach)

1. `DEV_SINOV.md` bo'yicha to'liq sinov — **admin va cheklangan hodim** bilan.
2. `bash promote.sh` (yoki tanlab: `bash promote.sh hodim jurnal ...`).
3. Prod fayllarni tekshirish.
4. Commit + push (siz qilasiz).

🔴 `promote.sh` `perms-dev.js` ni **argumentdan qat'i nazar** prodga ko'chiradi.
