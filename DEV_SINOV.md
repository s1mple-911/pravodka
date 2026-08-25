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

Har fayldan keyin uning "Tekshiruv" bo'limi hamma ustunda `true` qaytarsin.
Bittasi `false` bo'lsa — **keyingisiga o'tmang**.

🔴 **Har fayl butun holda bitta tranzaksiya**: biror operator xato bersa hammasi
orqaga qaytadi va funksiyalar yaratilmaydi. "Xato chiqdi, lekin bir qismi o'tgandir"
degan holat YO'Q.

---

## 1. ~~XARAJAT TO'SIG'I (70%)~~ — 🔴 BEKOR QILINDI (2026-08-25)

Asilbek qarori: 70% to'siq va qarz (6721) mexanizmi **butunlay olib tashlanadi**.
O'rniga **so'rovlar tizimi** keladi (`BRIEF_PROVODKA_SOROVLAR.md`): hodim o'z
pulidan ko'p yozsa — to'silmaydi, **pul so'raydi**.

**Sabab (2026-08-25 prod hodisasi):** to'siq prodga UI'siz chiqdi (SQL dev va prod
uchun bitta baza). Bugalter hodimlarga pul bera olmadi, tushunarsiz xato ko'rdi va
9 marta qayta urindi — har urinish `entry` sarlavhasini qoldirib ketdi
(`entry_line` rad etilgan, kompensatsiya `delete` esa RLS tufayli jimgina
0 qator o'chirgan). Pul yo'qolmadi, lekin jurnal axlat bilan to'ldi.

**Saboq (yangi ish uchun ham amal qiladi):**
1. 🔴 Pul oqimini to'sadigan server qorovuli **UI bilan BIRGA** chiqarilsin —
   aks holda foydalanuvchi nima qilishni bilmaydi va qayta-qayta uradi.
2. 🔴 Yozuv **ATOMIK** bo'lsin (bitta RPC). Ikki qadamli yozuvda ikkinchisi rad
   etilsa birinchisi axlat bo'lib qoladi.
3. 🔴 Rad etish xabari **odam tilida** bo'lsin va `permErr()` uni yutmasin.

Bu bo'limning sinov bandlari endi bajarilmaydi. O'chirish to'g'ri ketganini
tekshirish — `PROVODKA_TOSIQ_OCHIR.sql` ning o'z tekshiruv bo'limida.

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
