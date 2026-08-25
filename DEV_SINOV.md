# DEV SINOV — prodga chiqishdan oldin (majburiy)

Bu ro'yxat **dev fayllarda** (`*-dev.html`), **haqiqiy Supabase bazasida** bajariladi.
Dev va prod bitta bazadan foydalanadi — ya'ni sinovda yozilgan yozuvlar **haqiqiy**.
Shuning uchun har sinov yozuvi izohiga `SINOV` deb yozing va oxirida ro'yxat bo'yicha
o'chirib chiqing (soft-delete).

**Old shart:** `PROVODKA_BACKUP.sql` RUN qilingan va 2-BO'LIM tasdiqi hamma ustunda `true`.

---

## 0. SQL RUN tartibi

| # | Fayl | Izoh |
|---|------|------|
| 1 | `PROVODKA_BACKUP.sql` | zaxira + tasdiq |
| 2 | `PROVODKA_EXT_REF.sql` | 1.2 prefiks indeksi · 2-BO'LIM · 3-BO'LIM · 4-BO'LIM |
| 3 | `PROVODKA_JURNAL_V2.sql` | (allaqachon RUN qilingan — qayta shart emas) |
| 4 | `PROVODKA_IJROCHI.sql` | 🔴 JURNAL_V2 dan KEYIN (uning funksiyalarini qayta yozadi) |
| 5 | `PROVODKA_XARAJAT_TOSIQ.sql` | 🔴 kam trafik vaqtida |
| 6 | `PROVODKA_XARAJAT_QARZ.sql` | 🔴 TOSIQ dan keyin (u yaratgan `hodim_qarz_hisob` ga tayanadi) |
| 7 | `PROVODKA_HODIM_TARIX_QARZ.sql` | 🔴 ENG OXIRIDA — hodim tarixi/oylik jamisi qarz satrini ham sanaydi |

Har fayldan keyin uning "Tekshiruv" bo'limi hamma ustunda `true` qaytarsin.
Bittasi `false` bo'lsa — **keyingisiga o'tmang**.

🔴 **Har fayl butun holda bitta tranzaksiya**: biror operator xato bersa hammasi
orqaga qaytadi va funksiyalar yaratilmaydi. "Xato chiqdi, lekin bir qismi o'tgandir"
degan holat YO'Q.

---

## 1. XARAJAT TO'SIG'I (70%) — eng xavfli, eng puxta

**Nima qiladi:** hodim tashlangan pulning 70% ini xarajatga yozmagan bo'lsa,
o'sha hodim kassasiga **YANGI PUL KIRMAYDI**.

**Sinov uchun kerak:** bitta sinov hodim kassasi (`5401+`), unda kirim bor va
xarajat kam bo'lsin (foiz 70 dan past). Holatni ko'rish:
```sql
select * from hodim_tosiq_holat('<kassa-uuid>');
```

| # | Nima qilinadi | Kutilgan natija |
|---|---------------|-----------------|
| 1.1 | Foizi **70 dan past** hodimga kassa/bugalter pul beradi (Dt hodim kassa) | 🔴 **BLOKLANADI**, xabar: *"Bu hodim tashlangan pulning 70%'ini xarajatga yozmagan (hozir NN%). Avval xarajat yozilsin."* |
| 1.2 | O'sha hodim `hodim-dev.html` dan **xarajat yozadi** | ✅ **O'TADI** — 🔴 bu eng muhim tekshiruv. Bloklangan hodim xarajat yoza olmasa to'siqdan chiqish yo'li yo'q, tizim qulflanib qoladi |
| 1.3 | Xarajat yozgach foizi 70 dan oshadi → yana pul beriladi | ✅ **O'TADI** |
| 1.4 | Bloklangan hodim kassasidan **boshqa kassaga pul o'tkazish** | 🔴 **BLOKLANADI** (chetlab o'tish yo'li yopiq) |
| 1.5 | Bloklangan hodim kassasi **ichida** ko'chirish (naqd → Click) | ✅ **O'TADI** (ichki harakat, yangi pul emas) |
| 1.6 | **Yangi** hodim (hali umuman pul berilmagan) ga birinchi pul | ✅ **O'TADI** — aks holda 0/0 = 0% bo'lib tug'ilishidayoq qulflanardi |
| 1.7 | **Admin** o'zi pul berishga urinadi | 🔴 **BLOKLANADI** — sizning qaroringiz: "Hech kim chetlab o'tolmaydi". Guard'da `is_admin()` istisnosi YO'Q |
| 1.8 | n8n avtosinxron (`aros_auto`) 30 daqiqada ishlaydi | ✅ **TO'XTAMAYDI** (`auth.uid()` null → guard o'tkazadi). Kutib ko'ring yoki `sync_state` ni tekshiring |
| 1.9 | Oddiy filial/markaziy kassa yozuvlari (hodim kassasi emas) | ✅ Hech qanday o'zgarish yo'q |
| 1.10 | Admin to'siqni o'chiradi: `select set_hodim_tosiq_foiz(0);` | ✅ Hamma narsa avvalgidek. Keyin `select set_hodim_tosiq_foiz(70);` bilan qaytaring |

### 🔴 1.11 — QAYTARISH MASHQI (majburiy, prodga chiqishdan oldin)

Bir marta **ataylab** bajarib ko'ring:
```sql
drop trigger if exists trg_hodim_tosiq_entry_line on entry_line;
```
Pul oqimi darrov tiklanishi kerak (1.1 yana o'tadi). Keyin qaytaring:
`PROVODKA_XARAJAT_TOSIQ.sql` ning trigger yaratish qatorini qayta RUN qiling.

Sabab: prodda bugalter "pul kirita olmayapman" desa, sizda **10 soniyalik** yechim
bo'lishi kerak va u ishlashiga oldindan ishonch hosil qilingan bo'lishi kerak.

### To'lanmagan xarajat (qarz 6721) — Variant 2

🔴 **Bu bo'lim `PROVODKA_XARAJAT_QARZ.sql` RUN qilinmaguncha ishlamaydi.** Undan oldin
"To'lanmagan" ro'yxati **doim bo'sh** bo'ladi va bu XATO EMAS — qarz yozuvlari
hali yaratilmaydi.

| # | Nima | Kutilgan |
|---|------|----------|
| 1.12 | Hodim **qo'lidagi puldan ORTIQ** xarajat yozadi (masalan qoldiq 200 000, xarajat 500 000) | ✅ Saqlanadi. Tugma bloklanmaydi, ogohlantirish: "ortig'i qarzga yoziladi" |
| 1.13 | O'sha yozuvni jurnalda oching | **3 satr**: Dt modda 500 000 / Kt kassa 200 000 / Kt 6721 **300 000**. Dt = Kt ✅ |
| 1.14 | `select * from v_hodim_tolanmagan;` | Shu yozuv chiqadi, `ochiq_summa` = 300 000 |
| 1.15 | Hodim sahifasi + jurnal | "To'lanmagan" rozetkasi ko'rinadi |
| 1.16 | 🔴 **VALYUTA** kassasidan qoldiqdan ortiq xarajat | **Rad etiladi** (valyutada qarz yo'q) — klient ham bloklaydi, server ham |
| 1.17 | 🔴 **Oddiy** (hodim emas) kassadan qoldiqdan ortiq | **Bloklanadi** — eski xatti-harakat, o'zgarmagan |
| 1.18 | **Taqsimot** (bir necha filial) qo'ldagidan ortiq | Yozuvlar bo'ylab ketma-ket: birinchilari naqd, oxirgilari qarz |
| 1.19 | Bugalter `hodim_kirim_yop(...)` bilan qarzni yopadi | Qarz kamayadi, `v_hodim_balans` mos, rozetka "yopilgan" holatga o'tadi |
| 1.20 | Bloklangan hodimga **qarzini yopish** uchun pul | ✅ O'TADI (bu qo'shimcha pul emas) |
| 1.21 | 🔴 **REGRESSIYA** — oddiy xarajat (qo'lda puli yetarli) | **2 satr**, avvalgidek. Qarz satri paydo BO'LMASIN |
| 1.22 | 🔴 **REGRESSIYA** — filial/markaziy kassadan xarajat | Hech qanday o'zgarish yo'q, qarz mantiqi umuman ishlamaydi |
| 1.23 | 🔴 Qoldiq **0** bo'lgan hodim yana xarajat yozadi | Yozuv **2 satr** (Dt modda / Kt 6721, kassa satri YO'Q). 🔴 Shu yozuv hodim sahifasidagi **tarixda** va **"Bu oy sarflandi"** jamisida KO'RINISHI shart |
| 1.24 | Qisman qarz (qoldiq 200k, xarajat 500k) | "Bu oy" jamisiga **500 000** qo'shiladi (200k emas). Tarixdagi summa ham 500 000 |
| 1.25 | 🔴 Eski tur hisobi (`5351 "... · Naqd"`, `parent_id` bo'sh) tanlansa | Qarz yo'li **o'chadi**, `over` bloki **qat'iy** qoladi. "ortig'i qarzga yoziladi" xabari CHIQMASIN |
| 1.26 | Taqsimotda qarz paydo bo'lsa | Qoldiq **kassadan chiqqan qism** bo'yicha kamayadi (manfiy ko'rinmasin) + qarz haqida banner |

---

## 2. IJROCHI (kim yozdi)

| # | Nima | Kutilgan |
|---|------|----------|
| 2.1 | Yangi yozuv kiriting (`hodim-dev` yoki `provodka-dev`) | `PROVODKA_IJROCHI.sql` 0-BO'LIM diagnostikasi: `uuid_shaklida` **+1**, `bosh` **o'zgarmagan** |
| 2.2 | `jurnal-dev.html` ni oching | Yangi yozuvda ijrochi ismi ko'rinadi |
| 2.3 | Eski yozuvlar (49/50) | Ijrochi chipi **umuman chizilmaydi** — jurnal buzilgandek ko'rinmasin |
| 2.4 | Ijrochi filtridan "Noma'lum" ni tanlang | Eski yozuvlar chiqadi, ularda punktir chip paydo bo'ladi |
| 2.5 | `aros_sync` yozuvlari | Ko'k `bot` chipi, matn "Aros sinxron" |
| 2.6 | Ijrochi filtri + davr o'zgartirish | Ro'yxat davrga qarab qayta yuklanadi, sonlar to'g'ri |
| 2.7 | Filtr tanlanganda dashboard | 🔴 Dashboard ham **shu ijrochiga** bo'ysunadi (tur filtridan farqli) |
| 2.8 | **Cheklangan** foydalanuvchi bilan kiring | Ijrochi ro'yxatida faqat o'zi ko'radigan yozuvlarning mualliflari. Butun kompaniya xodimlari ro'yxati **chiqmasin** |
| 2.9 | `full_name` bo'sh foydalanuvchi | Admin — to'liq email; oddiy foydalanuvchi — faqat `@` gacha |
| 2.10 | `hisobot-dev.html` → "To'liq ro'yxat" | Ijrochi ko'rinadi (bu yerda "Noma'lum" ham ko'rsatiladi — audit) |
| 2.11 | n8n avtosinxron yozuvi | `created_by` = `aros_sync`, trigger uni **o'zgartirmagan** |

---

## 3. FILIAL MAJBURIY

| # | Nima | Kutilgan |
|---|------|----------|
| 3.1 | `sozlama-dev.html` → xarajat moddasiga "Filial" bayrog'ini yoqing | Saqlanadi |
| 3.2 | `hodim-dev.html` da shu moddani tanlang, filialsiz saqlang | 🔴 **BLOKLANADI** (ogohlantirish emas) |
| 3.3 | `professional-dev.html` **Oddiy** rejim | 🔴 **BLOKLANADI** |
| 3.4 | `professional-dev.html` **Kengaytirilgan** (ko'p satrli) rejim | 🔴 **BLOKLANADI** — filial butun yozuv darajasida |
| 3.5 | Bayroq **o'chirilgan** modda | ✅ Filialsiz saqlanadi (eski xatti-harakat) |
| 3.6 | Foydalanuvchiga filial biriktirilmagan | Sabab aniq yozilgan xabar; "ro'yxat yuklanmadi" bilan chalkashmasin |

---

## 4. TAKROR HIMOYASI (ext_ref) — insident tuzatmasi

| # | Nima | Kutilgan |
|---|------|----------|
| 4.1 | Oddiy xarajat saqlash | ✅ Avvalgidek ishlaydi |
| 4.2 | Taqsimot (bir necha filial) | ✅ Avvalgidek |
| 4.3 | **Tarmoqni uzib** saqlang (DevTools → Offline), keyin yoqing va "Qayta urinish" | Yozuv **BITTA** bo'lishi kerak. Jurnalda tekshiring |
| 4.4 | Saqlash paytida sahifani F5 qiling, keyin qayta oching | Banner: oldingi urinish holati. **Avtomatik qayta yozilmaydi** |
| 4.5 | Timeout bo'lgach formani **o'zgartirib** (boshqa summa) saqlang | Yangi xarajat **normal saqlanadi** (eski kalitga yopishib qolmaydi) |
| 4.6 | 4.3 dan keyin `select count(*) from entry where ext_ref like 'hodim:%';` | Har token uchun kutilgan sondan ortiq emas |
| 4.7 | 🔴 Qarzli xarajatda (1.12) tarmoqni uzib qayta urinish | Yozuv **bitta**, qarz summasi **ikki barobar bo'lmasin** |

---

## 5. REGRESSIYA (eski buzilmaganini tasdiqlash)

Har sahifani oching, asosiy amalni bir marta bajaring:

- `index-dev` — login/dashboard, kartalar to'g'ri
- `jurnal-dev` — ro'yxat, filtrlar, tahrir, o'chirish, Excel
- `kassa-dev` — qoldiqlar, konvert
- `hisobot-dev` — P&L, xarajat taqsimoti
- `balans-dev` — Aktiv = Passiv + Kapital
- `cashflow-dev` — davr boshi/oxiri tekshiruvi
- `professional-dev` — ikkala rejim
- `hodim-dev` — xarajat + taqsimot
- `konvert-dev`, `qarzdor-dev`, `filial-dev`, `valyuta-dev`, `sozlama-dev`, `ai-dev`

🔴 **Ikkita foydalanuvchi bilan sinang:** admin va cheklangan hodim.
Ruxsat xatolari faqat cheklangan foydalanuvchida ko'rinadi.

---

## 6. YAKUN

1. `PROVODKA_BACKUP.sql` **3-BO'LIM** ni RUN qiling — sinov nima yozganini ko'ring.
2. Sinov yozuvlarini Provodka'ning o'zida o'chiring (soft-delete).
3. Hammasi ✅ bo'lsa: `bash promote.sh` → tekshiring → push.
4. Prodda birinchi soat: hodimlardan "saqlanmadi / pul kirmayapti" xabari bo'lsa
   darrov 1.11 dagi `drop trigger` ni bajaring, keyin sabab qidiring.
