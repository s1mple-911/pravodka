# PROVODKA — Xarajat turiga maxsus maydonlar (universal) + mashina

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first. 🔴 Eski buzilmasin. UI/UX Apple. SQL additive. Push Asilbek. Prod: tasdiqlagach. Pul — fail-closed, permission.

## Konsept — UNIVERSAL (mashina alohida EMAS)
Har xarajat turiga MAXSUS MAYDONLAR biriktirish tizimi (HR dynamic konstruktori kabi). Mashina — shu tizimning BIRINCHI qo'llanishi, alohida kod emas.
- 🔴 Sozlamalarda: har xarajat turiga maxsus maydon(lar) qo'shish/o'chirish/sozlash.
- Xarajat yozganda: shu tur tanlansa → maxsus maydonlar chiqadi (to'ldiriladi).
- Saqlangach: maxsus maydon qiymati jurnal + hisobotda ko'rinadi.
- ⚠️ Keyin oson kengaytiriladigan: yangi xarajat turiga yangi maydon (obyekt, ta'minotchi, va h.k.) — kod o'zgarmasdan, sozlamadan.

## 1. Maxsus maydon konstruktori (sozlamalar)
- Sozlamalar → xarajat turlari → har turga "maxsus maydon qo'shish".
- Har maydon: nom, tur, majburiymi, tartib.
- 🔴 Maydon turlari (CC keraklini qo'shsin):
  - **Ro'yxatdan tanlash** (eng muhim — mashina uchun): oldindan tayyorlangan variantlar ro'yxati (rasm + matn). Masalan mashina ro'yxati.
  - Matn, raqam, sana, dropdown (oddiy) — CC kengaytirsin.
- Ro'yxat elementlari: har element nom + qiymat (masalan raqam) + rasm (ixtiyoriy).

## 2. Mashina — birinchi qo'llanish
- Xarajat turi: "Moshina Gaz" va "Moshina Benzin" (yangi turlar qo'shiladi).
- Bu turlarga → maxsus maydon: "Mashina" (ro'yxatdan tanlash).
- Mashina ro'yxati (misol boshlang'ich):
  - DAMAS — raqam 01O244RB — rasm (ixtiyoriy)
  - Tracker — raqam 01W182OC — rasm (ixtiyoriy)
- 🔴 Rasm IXTIYORIY — bo'lmasa nom + raqam ko'rinadi.
- Xarajat yozganda "Moshina Gaz/Benzin" tanlansa → mashina tanlash (DAMAS/Tracker) chiqadi → biri tanlanadi.

## 3. Jurnal + hisobotda ko'rinish
- 🔴 Saqlangach: mashina (rusum + raqam) jurnalda ko'rinsin (masalan "DAMAS 01O244RB").
- Hisobotda ham mashina ko'rinsin.
- Rasm bo'lsa — kichik rasm (ixtiyoriy), bo'lmasa nom+raqam.
- (Universal: boshqa maxsus maydon ham shunday — jurnal/hisobotda qiymat ko'rinadi.)

## DB (additive)
- Maxsus maydon: `xarajat_maydon` (tur_id/hisob, nom, maydon_turi, required, tartib, options jsonb).
- Ro'yxat elementlari (mashina): `xarajat_royxat` (maydon_id, nom, qiymat, rasm_url) — yoki options jsonb ichida.
- Xarajat qiymati: entry/entry_line'ga maxsus maydon qiymati (jsonb yoki alohida `entry_maydon` (entry_id, maydon_id, qiymat)).
- Rasm → Supabase Storage (ixtiyoriy).
- CC eng toza sxema — universal (mashina hardcode emas). RLS, permission.

## ⚠️ Optimal shablon
- 🔴 Mashinaga ALOHIDA kod yozilmasin — universal maydon tizimi. Mashina = ro'yxatdan tanlash maydonining bir misoli.
- Keyin boshqa xarajat turiga boshqa maydon (obyekt, ta'minotchi) — o'sha tizimdan, kod o'zgarmasdan.
- HR dynamic konstruktori naqshiga o'xshash (agar mos bo'lsa CC undan foydalanadi).

## Fable oqimi
coder (universal maxsus maydon: konstruktor + xarajat formaga + jurnal/hisobot ko'rinish + mashina misol), designer (maydon konstruktor, mashina tanlash rasm bilan, jurnal/hisobot — Apple), tester (🔴 universal maydon to'g'ri, mashina tanlanadi, jurnal/hisobotda ko'rinadi, rasm ixtiyoriy, eski xarajat buzilmagan, fail-closed). 🔴 Eski buzilmasin. Dev-first. SQL additive (men RUN). Push men. Prod: men tasdiqlagach.

## Tartib
1. Universal maxsus maydon tizimi (konstruktor + DB).
2. Mashina misol (Gaz/Benzin tur + mashina ro'yxati DAMAS/Tracker).
3. Xarajat formaga (tur tanlansa maydon chiqadi).
4. Jurnal + hisobotda ko'rinish (mashina rusum+raqam).
🔴 Universal — mashina alohida kod emas. Keyin oson kengaytiriladi.

---

# QO'SHIMCHA — hodim.html amallar tarixi + Telegram bot tekshiruv

## 4. hodim.html — kassa amallar tarixi (davr bilan)
- hodim.html'да "Bugun / Bu hafta / Bu oy" bosilsa → o'sha hodim kassasiga taalluqli AMALLAR ko'rinsin.
- 🔴 HAMMA amal: kirim, chiqim/xarajat, transfer — hodim kassasiga tegishli har qanday harakat.
- Davr filter (bugun/hafta/oy) — CC eng qulay qilsin (jurnal V2 davr uslubi kabi).
- Har amal: sana, tur (kirim/chiqim/transfer), summa, izoh, (ijrochi).
- Hodim o'z kassasi harakatini ko'radi (o'ziniki — permission bilan, boshqa hodim sizmaydi).
- ⚠️ Fail-closed: hodim faqat O'Z kassasi amallarini ko'rsin (permission).

## 5. Telegram bot — kirim/transfer xabari tekshiruv
- Hodim kassasiga pul kirim yoki transfer bo'lsa → Telegram bot xabar yuborardi (ulanган edi).
- 🔴 CC tekshirsin: bot HOZIR ishlayaptimi (kirim/transfer bo'lganda xabar ketadimi).
- Ishlamasa → tuzatsin (bot ulanishi, webhook, xabar oqimi).
- ⚠️ Bot manbasi: agar n8n yoki Edge Function bo'lsa — CC topib tekshirsin. Manba repoda bo'lmasa — Asilbekдан so'rasin.
- Kirim/transfer → hodimga Telegram xabar (kassangizga X so'm kirim bo'ldi, va h.k.).

## Tartib (qo'shimcha)
- 4 (hodim.html amallar) — universal maydondan keyin yoki alohida.
- 5 (bot tekshiruv) — CC tekshirsin, holatini aytsin, kerak bo'lsa tuzatsin.
