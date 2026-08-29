# PROVODKA — "Pul so'rash" → 2 tab: Pul so'rash + Ruxsat so'rash

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first. 🔴 Eski buzilmasin. Pul — fail-closed. SQL additive. Push Asilbek. Prod: tasdiqlagach. 🔴 RBAC bilan bog'liq.

## Umumiy
hodim-dev "Pul so'rash" tugmasi → modal → TEPADA 2 TAB:
- Tab 1: "Pul so'rash" (MAVJUD logika — o'z holicha)
- Tab 2: "Ruxsat so'rash" (YANGI — bloklangan xarajat turi uchun ruxsat)

## Tab 1 — Pul so'rash (MAVJUD, tekshirish)
- 🔴 Hozirgi pul so'rash logikasi O'Z HOLICHA turadi (o'zgartirmang).
- 500,000 dan kam bo'lsa top-up ochiladi (mavjud).
- 🔴 TEKSHIR: to'g'ri ishlayaptimi? 500 chegara, top-up, so'rov — hammasi ishlaydimi. Buzuq bo'lsa tuzat.

## Tab 2 — Ruxsat so'rash (YANGI) 🔴
### Maqsad
Hodim uchun YOPIQ (RBAC rolda yo'q) xarajat turini yozish uchun RUXSAT so'raydi. Ruxsat berilsa — o'sha xarajat uchun hodim hisobidan yechiladi (TRANSFER YO'Q, pul TUSHMAYDI).

### Oqim
1. Tab 2 "Ruxsat so'rash" → forma (pul so'rash kabi, lekin farqli).
2. Summa yozadi.
3. Xarajat turi tanlaydi:
   - 🔴 Ro'yxat = bu userga YOPIQ (RBAC rolida YO'Q) xarajat turlari.
   - Ya'ni: rolда bor turlar EMAS — faqat YOPIQ (ruxsat kerak) turlar.
   - Ro'yxatdan tanlaydi.
4. (Ixtiyoriy: izoh — nima uchun).
5. "So'rov yuborish" → so'rov ketadi (kimdan — pul so'rash kabi yoki admin).

### 🔴 Farq — pul so'rashdan
- Pul so'rash: tasdiqlansa → hodim hisobiga PUL TUSHADI (transfer, balans +).
- Ruxsat so'rash: tasdiqlansa → PUL TUSHMAYDI, TRANSFER YO'Q.
  - Faqat: o'sha yopiq xarajat turi uchun RUXSAT beriladi.
  - Ruxsat berilsa → hodim o'sha xarajatni yoza oladi → hodim HISOBIDAN yechiladi (o'z balansidan, transfer yo'q).

### Mantiq (aniq)
- Ruxsat so'rash = "menga X xarajat turini yozishga ruxsat bering, summasi Y".
- Tasdiqlovchi (admin/rahbar) ko'radi → ruxsat beradi yoki rad.
- Ruxsat berilsa:
  - 🔴 O'sha xarajat (summa Y, tur X) hodim hisobidan yoziladi (Dt xarajat / Kt hodim kassa).
  - Pul TUSHMAYDI (hodimga), TRANSFER YO'Q.
  - Ya'ni: bir martalik ruxsat — o'sha yopiq turga, o'sha summa.
- ⚠️ CC aniqlasin: ruxsat berilgach xarajat AVTOMAT yoziladimi (tasdiqda) yoki hodim keyin yozadimi (ruxsat ochiladi)?

## 🔴 RBAC bilan bog'liq
- Yopiq xarajat turlari = RBAC rolда YO'Q turlar (hozir rol berayapmiz — o'sha yopiq turlar).
- Ya'ni: rbac_role_modda'da rolда yo'q xarajat hisoblari = ruxsat so'rash ro'yxati.
- trg_rbac_guard_entry_line — rolда yo'q xarajat → 42501. Ruxsat berilса → shu turga bir martalik ruxsat (guard'ni chetlab o'tadi — FAQAT ruxsat berilgan).
- 🔴 Xavfsizlik: ruxsatsiz yopiq xarajat → 42501 (server). Ruxsat berilса → o'sha bitta xarajat o'tadi (ext_ref/token bilan bog'langan, bir marta).

## 🔴 Xavfsizlik (fail-closed)
- Ruxsat so'rash — server tekshiradi (RPC).
- Ruxsat berilgan xarajat = ruxsat so'rovi bilan bog'langan (summa, tur — spoof yo'q).
- Bir ruxsat = bir xarajat (takror yo'q — ext_ref/token).
- Ruxsatsiz → 42501 (rbac guard).
- Tasdiqlovchi ruxsat berish huquqiga ega bo'lsin (admin/rahbar).

## DB (additive)
- ruxsat_sorov (id, hodim_id, xarajat_hisob_id, summa, izoh, status[kutilmoqda/tasdiq/rad], tasdiqlovchi, sana).
- Tasdiq → xarajat (Dt xarajat / Kt hodim kassa) — transfer YO'Q, pul TUSHMAYDI.
- rbac guard: ruxsat berilgan tur → bir martalik o'tadi (ext_ref).
- CC eng toza sxema. Fail-closed.

## ⚠️ MUHIM
- 🔴 Tab 2 ruxsat = FAQAT yopiq (RBAC rolда yo'q) turlar.
- 🔴 Ruxsat berilса → PUL TUSHMAYDI, TRANSFER YO'Q — faqat o'sha xarajat hodim hisobidan.
- 🔴 Tab 1 (pul so'rash) — mavjud, tekshir (500 logika ishlaydimi).
- 🔴 RBAC guard bilan mos (ruxsatsiz 42501, ruxsat berilса bir marta o'tadi).
- CC AVVAL mantiq (ruxsat → xarajat qanday, avtomat mi) tasdiqласin.

## Fable oqimi
coder (2 tab, ruxsat so'rash yopiq turlar, tasdiq → xarajat transfersiz, RBAC guard mos), designer (modal 2 tab, ruxsat forma — Apple), tester (🔴 yopiq turlar ro'yxati, ruxsat berilса pul tushmaydi transfer yo'q, ruxsatsiz 42501, tab 1 pul so'rash ishlaydi, fail-closed). Push men.

## Tartib
1. Tab 1 (pul so'rash) tekshir (500 logika).
2. Tab 2 (ruxsat so'rash) — yopiq turlar, summa, so'rov.
3. Tasdiq → xarajat (transfersiz, pul tushmaydi).
4. RBAC guard mos (ruxsat bir marta).
5. Fail-closed (server).
