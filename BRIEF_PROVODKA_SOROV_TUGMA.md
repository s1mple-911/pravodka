# PROVODKA — "Pul so'rash" tugma FIX (doim ko'rinadi + 2 holat)

Repo: pravodka. hodim-dev.html. Dev-first. 🔴 Eski buzilmasin. Pul — fail-closed. Push Asilbek. Prod: tasdiqlagach.

## Muammo (hozir)
"Pul so'rash" tugma faqat balans yozgan summadan kam bo'lganda ko'rinadi. Asilbek: tugma DOIM ko'rinsin (enable), user hohlagan payti so'rasin.

## Fix — tugma doim enable + 2 holat
- 🔴 "Pul so'rash" tugma DOIM ko'rinadi/enable (balansdan kam yozish sharti OLIB TASHLANADI tugma uchun).
- Eski logika (balansdan kam yozsa avtomat) ham ISHLAYDI — lekin tugma qo'shimcha, doim bosiladi.
- Tugma bosilganda — balansga qarab 2 xil:

### Holat A: balans < 500 (kam)
- 🔴 Oddiy TOP-UP: pul so'raladi → tasdiqlansa balansga QO'SHILADI, hech narsa yechilmaydi (xarajatga bog'lanmaydi).
- Ya'ni sof balans to'ldirish (top-up) — pending xarajat YO'Q, faqat balans ko'payadi.
- Modal: kimdan, qancha, izoh → so'rov → tasdiqlansa balans +.
- (Bu oddiy so'rovdan farqi: xarajatga bog'lanmaydi, sof balans top-up.)

### Holat B: balans ≥ 500 (yetarli)
- 🔴 Tugma bosilsa → YO'RIQNOMA (step-by-step), so'rov YUBORILMAYDI.
- Xabar: "Sizda hozir 500+ so'm bor. Siz faqat qarzga yozsangiz bo'ladi."
- Step-by-step: qarzga qanday yozish, qanday so'rash — hammasi tushuntiriladi (aniq qadamlar).
- Ya'ni balans yetarli bo'lsa — pul so'ramaydi, balki qarzga yozishni o'rgatadi.

## 500 chegara
- 🔴 500 so'm — chegara (balans < 500 → top-up; ≥ 500 → yo'riqnoma).
- (Agar keyin o'zgarsa oson: konstanta qilib qo'y.)

## UI
- Tugma doim ko'rinadi (enable).
- Bosilганda balans tekshiriladi:
  - < 500 → top-up modal (kimdan, qancha, izoh).
  - ≥ 500 → yo'riqnoma modal (step-by-step, so'rov yo'q).
- Balans KO'RINMASIN (oldingi qoida — modal ichida balans ko'rsatilmaydi). Faqat yo'riqnomada "500+ bor" degan umumiy xabar (aniq raqam emas? yoki CC — asilbek: "500 dan ko'p bor" desa bo'ladi).

## ⚠️ Muhim
- Top-up (< 500): balansga qo'shiladi, xarajatga bog'lanmaydi (sof top-up). CC buxgalteriya to'g'ri qilsin (top-up qanday provodka).
- Yo'riqnoma (≥ 500): faqat matn/step, hech narsa yozilmaydi.
- Fail-closed: pul harakati faqat tasdiqlangach.

## Fable oqimi
coder (tugma doim enable, balans < 500 top-up, ≥ 500 yo'riqnoma, 500 konstanta), designer (top-up modal, yo'riqnoma step-by-step — Apple), tester (🔴 tugma doim, < 500 top-up balansga qo'shiladi, ≥ 500 yo'riqnoma so'rov yo'q, balans sizmaydi, fail-closed). 🔴 Eski so'rov buzilmasin. Dev-first. Push men.

## Tartib
1. Tugma doim enable.
2. Balans < 500 → top-up (balansga qo'shiladi).
3. Balans ≥ 500 → yo'riqnoma (step-by-step, so'rov yo'q).
