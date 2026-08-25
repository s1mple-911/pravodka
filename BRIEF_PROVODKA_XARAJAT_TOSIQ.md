# PROVODKA — Xarajat to'sig'i (70% qoida + to'lanmagan xarajat)

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first. 🔴 Eski buzilmasin. Pul — fail-closed, permission. SQL additive. Push Asilbek. Prod: tasdiqlagach.

## Muammo
Hodimlar xarajat yozmayapti (pulni ishlatib yuboryapti), bugalter kirim qilib tashlayapti — nazoratsiz.

## Yechim — 70% to'sig'i + to'lanmagan xarajat konsepti

### 1. Balans hisobi (har hodim)
- Har hodim uchun: **jami kirim** (unga tashlangan pul) va **jami yozilgan xarajat**.
- **Xarajat foizi** = (yozilgan xarajat / jami kirim) × 100.

### 2. 70% TO'SIG'I (kirim + transfer bloklash)
- 🔴 Hodim oldin tashlangan pulning **70%'ini xarajatga yozmagan bo'lsa** → unga:
  - **Kirim qilib bo'lmaydi** (bugalter kirim qilolmaydi).
  - **Transfer qilib bo'lmaydi** (hodim transfer qilolmaydi).
  - Error message: "Bu hodim tashlangan pulning 70%'ini xarajatga yozmagan. Avval xarajat yozilsin."
- Ya'ni: yozilgan xarajat < 70% × jami kirim → BLOK.
- 70% yoki undan ko'p yozsa → kirim/transfer ochiladi.

### 3. TO'LANMAGAN XARAJAT (qo'lidagi pul yetmasa)
🔴 Muhim mexanizm — hodim qo'lidagi puldan KO'P xarajat yozishi mumkin:
- Hodim xarajat yozmoqchi, lekin qo'lidagi pul (balans) yetmasa — u baribir kattaroq xarajat yoza oladi.
- Ya'ni balansidan ko'p summa yozib "Saqlash" bosadi.
- Bu xarajat → 🔴 **QIZIL rang** bilan, **"To'lanmagan" status** bilan ko'rinadi (hamma joyda).
- Ya'ni: hodim 100k qo'lida, 150k xarajat yozdi → 50k "to'lanmagan" (qizil, to'lanmagan status).

### 4. Bugalter kirim/transfer → to'lanmagan yopiladi
- Bugalter o'sha hodimga pul kirim (yoki transfer) qiladi.
- 🔴 O'sha moment: hodim balansi (xarajat summasida) ko'payadi → o'sha zahoti pul ayriladi (to'lanmagan xarajatga bog'lanadi).
- **To'lanmagan status o'chiriladi** → oddiy xarajatdek bo'lib qoladi (kichik qizil belgi bilan — tarix uchun).
- Ya'ni: to'lanmagan 50k bor edi → bugalter 50k+ kirim qildi → 50k avtomat yopiladi → to'lanmagan ketadi (kichik qizil belgi qoladi: "avval to'lanmagan edi").

## Oqim (misol)
1. Hodimga 1,000,000 tashlangan.
2. Hodim 500,000 xarajat yozdi (50% < 70%) → 🔴 kirim/transfer BLOK.
3. Hodim yana 200,000 yozdi (700,000 = 70%) → blok ochildi.
4. Hodim qo'lida 300,000, lekin 400,000 xarajat yozdi → 100,000 "to'lanmagan" (qizil).
5. Bugalter 100,000 kirim qildi → to'lanmagan yopildi → kichik qizil belgi (tarix).

## UI
- **To'siq**: kirim/transfer urinilса → error (uz, aniq: 70% yozilmagan).
- **To'lanmagan xarajat**: qizil rang + "To'lanmagan" status (jurnal, hodim ko'rinishi, hamma joyda).
- **Yopilgach**: kichik qizil belgi (oddiy xarajat + "avval to'lanmagan" izoh).
- Hodim ko'rinishida: balans, xarajat foizi (70% chizig'i), to'lanmagan summa.

## DB (additive)
- Xarajat foizi: hodim entry/kirim va xarajat entry'dan hisoblanadi (yoki hodim balans view).
- To'lanmagan: xarajat entry'ga `tolanmagan boolean` yoki `tolanmagan_summa` (qo'lidagidan ortiq qism).
- Kirim/transfer to'sig'i: RPC/tekshiruv (kirim yozishdan oldin 70% tekshir).
- Yopilish: bugalter kirim → to'lanmagan avtomat yopiladi (FIFO yoki bog'lash).
- CC eng toza sxema. 🔴 Fail-closed (pul). RLS, permission.

## ⚠️ MUHIM — buxgalteriya to'g'riligi
- Bu double-entry'ga mos bo'lsin (to'lanmagan = qarz/kutilayotgan hisob?).
- CC buxgalteriya mantiqini to'g'ri qilsin (to'lanmagan xarajat qanday hisobda turadi — masalan hodim qarzi 6xxx yoki maxsus).
- Kirim yopganda — provodka to'g'ri (Dt xarajat / Kt hodim balans).
- CC izohlab bersin (buxgalteriya oqimi).

## Fable oqimi
coder (70% hisob + to'siq RPC, to'lanmagan xarajat, bugalter kirim→yopilish, buxgalteriya provodka), designer (to'siq error, to'lanmagan qizil status, hodim balans UI — Apple), tester (🔴 70% to'g'ri hisob, to'siq ishlaydi kirim/transfer, to'lanmagan qizil, yopilish avtomat, fail-closed, RLS, buxgalteriya balans to'g'ri). 🔴 Eski buzilmasin. Dev-first. SQL additive (men RUN). Push men. Prod: men tasdiqlagach.
⚠️ CC AVVAL buxgalteriya mantiqini (to'lanmagan qanday hisobda) taklif qilsin, keyin qursin.

## Tartib
1. Balans + 70% hisob (har hodim).
2. To'siq (kirim/transfer blok, 70% yozilmagan).
3. To'lanmagan xarajat (qo'lidan ortiq, qizil status).
4. Bugalter kirim → to'lanmagan avtomat yopilish.
5. UI (to'siq error, qizil status, hodim balans).
