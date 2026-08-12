# PROVODKA — hodim-dev + admin-dev KASSA/TUR fix (CRITIC)

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first (-dev.html → promote.sh). 🔴 Pul harakati — EHTIYOT. SQL additive. Push Asilbek. 🔴 Eski buzilmasin.

## MUAMMO (critic)
hodim-dev.html va admin-dev.html da kassa NOTO'G'RI ko'rsatilyapti:
- Bitta kassada 3 tur (naqd/click/dollar) bo'lsa — 3 ta ALOHIDA KASSA qilib ko'rsatyapti (masalan Abrorxo'ja → 3 kassa). NOTO'G'RI.
- Kerak: BITTA kassa tanlanadi → keyin ICHIDAN tur tanlanadi (naqd/click/payme/dollar) — **professional.html'dagi AYNAN logika**.

## 1. Kassa/tur tanlash — professional kabi
- Avval **kassa** tanlanadi (bitta — Abrorxo'ja, tur alohida EMAS).
- Keyin o'sha kassa ICHIDAN **tur** tanlanadi (naqd/click/payme/dollar).
- ⚠️ CC professional.html'dagi kassa+tur tanlash logikasini KO'RIB, o'shani hodim-dev va admin-dev ga ko'chirsin (aynan). Professional to'g'ri ishlaydi — namuna o'sha.
- hodim-dev VA admin-dev — ikkovida ham. Hozir ikkovi kassani turlarга bo'lib yuboryapti.

## 2. hodim-dev: dollar ko'rinmayapti
- hodim-dev da userning DOLLAR turi ko'rinmayapti — faqat naqd va payme ko'rindi. Dollar (USD) ham ko'rinsin.
- ⚠️ Sabab ehtimol: tur filtri (code.startsWith yoки currency) dollarni tashlab yuboryapti. CC tekshirsin — hamma tur (naqd/click/payme/USD) ko'rinsin.

## 3. Jami pul → tur tanlanadi
- Kassa tanlanguncha — userning **jami puli** ko'rinsin (umumiy).
- Tur tanlangач — aynan o'sha tur (masalan dollar tanlansa dollar qoldig'i).
- Ya'ni: kassa+tur tanlanmagunча jami; tanlanгач o'sha tur.

## 4. Xarajat yozish — som yoki dollar
- Tur tanlangач (masalan dollar) → xarajat (rasxod) yoziladi.
- **Valyuta tanlash**: xarajatni **som**da yoки **dollar**da yozish mumkin.
  - Dollar turida, som yozsa → **kurs bilan** dollar kamayadi (som/kurs = dollar miqdori kamayadi).
  - Dollar yozsa → to'g'ridan dollar kamayadi.
- Jurnalда **aniq** yozilsin: qaysi kassa, qaysi tur, qancha (som yoki dollar), kurs (agar konvert bo'lsa). Double-entry to'g'ri.
- ⚠️ Bu Provodkaga yoziladi — Dt xarajat / Kt kassa.tur. Dollar bo'lsa fc_amount (valyuta miqdori) to'g'ri yozilsin (som ekvivalent emas).

## Amalga oshirish
- coder — avval professional.html kassa+tur logikasini O'QISIN (namuna). Keyin hodim-dev va admin-dev ga ko'chir. Dollar ko'rinishi (tur filtri) tuzat. Xarajat som/dollar konvert.
- tester — kassa bitta ko'rinadimi (3 ga bo'linmaydimi), dollar ko'rinadimi, xarajat som→dollar kurs to'g'rimi, jurnal aniq yoziladimi, double-entry Dt=Kt, pul ikki marta emas.
- 🔴 PUL HARAKATI — tester ALOHIDA diqqat: som→dollar konvert to'g'ri (kurs), fc_amount to'g'ri, jurnal aniq.

## Tartib
1 (kassa/tur professional kabi — ikkovida) → 2 (dollar ko'rinsin) → 3 (jami→tur) → 4 (xarajat som/dollar kurs).
Fable oqimi: coder (professional o'qi + ko'chir), tester (kassa bitta, dollar, konvert, jurnal, double-entry). 🔴 Eski buzilmasin, pul ehtiyot. Dev-first. SQL additive (men RUN). Push men. Menga to'liq hisobot: nima tuzatildi, jurnal namunasi, test.
