# PROVODKA — Ism-familiya tizimi + hodim-dev dizayn audit

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first (-dev.html → promote.sh). SQL additive. 🔴 Eski buzilmasin. Ertaga prodga chiqadi. Push Asilbek.

## 1. ISM-FAMILIYA TIZIMI
Hozir hamma joyda GMAIL ko'rinyapti — ism-familiya kerak.
- **admin-dev.html sozlamalar**: access berishдан oldin, har hodim uchun ism-familiya kiritадиган input. Admin kiritади.
- **DB**: profiles yoки users jadvалига ism-familiya ustun (additive — masalan full_name). CC mavjud jadval nomini ko'рсin.
- **Hamma joyда gmail o'rniga ism-familiya**:
  - Jurnal — ism-familiya
  - Hisobot (bron kun hisobot + boshqалар) — ism-familiya
  - hodim-dev.html tepаsи — hozir gmail, ism-familiya bo'lsін
  - Boshqа gmail ko'ринadigan joylар
- **Fallback**: ism-familiya bo'sh → gmail (eski buzилмаsін).
- coder mavjud jadval + gmail ishlатилган joylарни topsін, keyin ustun + almashtir. tester ko'ринади mi + fallback + eski buzилмади.

## 2. hodim-dev.html — DIZAYN AUDIT + TUZATISH (designer)
Ertaga prodga chиqади — hodim-dev.html UI/UX sifatini tekshир va yaxshилаsин.
- **designer** — hodim-dev.html ni to'liq ko'риб chиqsін: UI/UX yaxshими, kamchiliklar nima? Apple darajа bo'lsін.
- Tekshир: tipografiya (shrift ierarxiя), rang (Aros yashil #1ea83a izchил), spacing (4/8px grid), ikonка (Lucide izchил), responsive (1024/1280/1366 + mobil), :focus-visible, holatlar (bo'sh/to'la/xato/yuklanmoqда), tugma/karta ko'риниши.
- Kamchilikларни top, keyin **tuzat** (chиroyли, professional, sotувга tayyor).
- ism-familiya (1-ish) hodim-dev tepаsига qo'shилganда — u ham chиroyли ko'ринsін.
- coder designer o'zgаришларини amalга oshirsін (agar HTML/mantiq kerak bo'lса). tester: eski funksiя buzилмади, responsive to'g'ри.

## Tartib
1 (ism-familiya: DB + admin input + hamma joy + fallback) → 2 (hodim-dev designer audit + tuzatish).
Fable oqimи: coder (rekon + kod), designer (hodim-dev UI + admin input), tester (fallback, eski buzилмади, responsive). Menга to'liq hisobot: nima qилинди, dizayn kamchiliklar + tuzatишлар, test, qaysi commit, qanday sinаsh. 🔴 Eski buzилмаsін. Dev-first. SQL additive (men RUN). Push men. Ertaga prod — sifat muhим.
