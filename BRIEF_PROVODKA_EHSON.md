# BRIEF — Ehson (xayriya) bo'limi — MUSTAQIL (Asilbek, 2026-09-03)

Arxitektura: `ARX_PROVODKA_EHSON.md`. Namuna Excel: `Ehson_oilalar_jadvali_togrilangan.xlsx`.

## ENG MUHIM — mustaqil, izolyatsiya
- Ehson bo'limi TO'LIQ MUSTAQIL. Har amal shu yerda qoladi — hech qayerda yozilmaydi.
- Ehson puli KASSADA ko'rinmaydi, KOMPANIYA PULI emas, KAPITALGA qo'shilmaydi.
- JURNALDA YO'Q, HISOBOTDA YO'Q, balans/cashflow'da YO'Q.
- Alohida «Ehson kassasi» — faqat ehson bo'limida.
- Double-entry'dan ALOHIDA — o'z jadvallari (entry/entry_line'ga TEGMAYDI). Eng izolyatsiya qilingan yechim.

## 1. Ehson kassasi
Alohida jamg'arma; kirim (xayriya to'plandi); oilalarga chiqim shu kassadan; hech qayerda ko'rinmaydi.

## 2. Oilalar (Excel import + kengaytirish)
Oila: ID, F.I.Sh., telefon, manzil, tavsiya, oilaviy/uy-joy holati, daromad, muhtojlik sababi/darajasi, yordam turi/miqdori,
kiritilgan/tekshirilgan sana, tekshirgan, izoh. A'zolar: qarindoshlik, F.I.Sh., tug'ilgan sana (yosh AVTOMAT), sog'liq,
ish/o'qish, kasb/sinf, daromad, qaramog'ida, izoh. Excel import (OILA-001, 6 a'zo namuna) + kengaytirish.

## 3. Ehson berish
Oila → pul (kassadan chiqim). Izoh MAJBURIY. Muddat: 1 martalik yoki oyma-oy (reja vs fakt).

## 4. Tarix — har berish: oila, sana, tur, miqdor, tavsif, holat, mas'ul, keyingi ko'rib chiqish.
## 5. Oylik reja — bu oy kimga qancha kerak edi / qancha berildi; muddat kelganlar.
## 6. CC to'liq ijod — professional xayriya tizimi: oila kartasi, kassa balansi, statistika, filter/qidiruv, design.

## Tartib
1. Arxitektura → Asilbek. 2. Kassa. 3. Oilalar + a'zolar (Excel). 4. Berish. 5. Oylik reja. 6. Tarix + statistika + design.
Oqim: coder → designer → tester (IZOLYATSIYA: jurnal/hisobot/balansda yo'q). Push Asilbek.
