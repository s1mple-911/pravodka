# PROVODKA — AI 5-bosqich: to'liq moliyaviy tahlil (hisobot + chart + Excel)

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). EF `ai-chat` (Sonnet 5, streaming, web_search, 3 RPC tool: kassa_qoldiq/transferlar/qarzdorlar). Dev-first. 🔴 Eski buzilmasin. SQL additive. Push Asilbek.

## Maqsad
AI to'liq moliyaviy tahlilchi bo'lsin — user jurnalда bitta-bitta ko'rmasдан, AI orqали hamma hisobotни olsin. Xarajat/kirim/qoldiq tahlili + chart + Excel. 🔴 Har user PERMISSION bo'yicha cheklangan.

## 1. Yangi analitika tool'lari (RPC)
Mavjud 3 tool (kassa_qoldiq, transferlar, qarzdorlar) ustiga yangi RPC tool'lar — hammasi permission bilan (op_kassa_ids + sahifa ruxsati, 4-bosqichdagi qorovul naqshi):
- **xarajat_hisobot** — chiqim/xarajat: xodim kesimida, kategoriya (hisob) kesimida, filial kesimida, davr (sana oralig'i). "Eng ko'p qaysi xodim xarajat qilyapti" — shu.
- **kirim_hisobot** — kirim: manba, filial, davr kesimida.
- **cashflow_hisobot** — kirim vs chiqim (pul oqimi), davr bo'yicha, filial bo'yicha.
- **balans_qoldiq** — hisob qoldiqlari (aktiv/passiv, kassa/bank/qarz), sana holatiga.
- **jurnal_qidiruv** — jurnal yozuvlari (Dt/Kt, summa, izoh, sana) — filtrlangan (davr, hisob, filial, summa oralig'i).
- ⚠️ CC mavjud hisobot sahifalarини (hisobot-dev.html, cashflow, balans, professional) O'QISIN — o'shandagi SQL/mantiqni RPC'ga aylantirsin (bir xil natija, ikki haqiqat bo'lmasin). Xarajat = chiqim hisoblari (5xxx?), CC aniqlasin.
- 🔴 XAVFSIZLIK: har RPC user permission bilan (ko'ra oladigan kassa/filial + sahifa ruxsati). Boshqa filial/kassa xarajati SIZMASIN. Static guard (4-bosqich kabi).

## 2. Chart chatда (pie/bar/line)
- AI hisobot berganда — chatда VIZUAL chart chizsin (pie, bar, line — ma'lumotga qarab).
- Masalan "eng ko'p xarajat qilgan xodim" → **pie chart** (xodimlar ulushi) + raqamlar.
- Texnik: AI javobда chart ma'lumotini strukturali bersin (JSON), mijoz uni chart kutubxonasi (Chart.js yoki SVG) bilan chizsin. Yoki AI SVG/Chart.js kodi bersin.
- CC eng toza yo'l: AI javobda maxsus blok (masalan ```chart {...json...}```) → mijoz parse qilib chizadi. Chart turi (pie/bar/line) AI tanlaydi.
- Chart chиroyли (Aros yashil palitra, Apple).

## 3. Excel/CSV yuklab olish
- Hisobot → Excel (yoki CSV) yuklab olish tugmasi.
- AI hisobot berganда — "📥 Excel yuklab olish" tugma. Bosilса — o'sha ma'lumot .xlsx (yoki .csv) bo'lib yuklanadi.
- Texnik: mijozда SheetJS (xlsx) yoki CSV generatsiya. AI structured ma'lumot beradi → mijoz Excel qiladi.
- Excel toza: ustunlar (xodim, summa, sana...), jami qatori.

## 4. To'liq ma'lumot (permission bilan)
- AI hamma Provodka ma'lumotига kira olsin (xarajat, kirim, qoldiq, jurnal, transfer, qarzdor) — LEKIN har user o'z permission'i bo'yicha.
- 🔴 XAVFSIZLIK (eng muhim): user faqat o'zi ko'ra oladigan kassa/filial/sahifa ma'lumotини olsin. Boshqasи SIZMASIN (kod, nom, summa — hech biri). 4-bosqichdagi maskalash + guard naqshi hamma yangi RPC'да.
- Permission: mavjud op_kassa_ids + sahifa ruxsati (kassa/jurnal/hisobot/qarzdor). Har RPC o'z sahifа ruxsatини tekshirsin.

## Tartib
1 (analitika RPC'lar — xarajat birinchi, mavjud hisobot mantiqidan) → 2 (chart chatда) → 3 (Excel) → 4 (to'liq + permission tekshiruv).
Fable oqimi: coder (RPC'lar mavjud hisobotdan, chart blok, Excel, permission guard), designer (chart chиroyли pie/bar, Excel tugma, hisobot ko'rinishi — Apple), tester (🔴 XAVFSIZLIK ENG MUHIM: har RPC permission sizmasin — xarajat/kirim/qoldiq/jurnal, boshqa filial ko'rinmasin, injection). 🔴 Eski buzilmasin. Dev-first. SQL additive (men RUN, bo'limlab). EF deploy. Push men. To'liq hisobot.
Katta bosqich — bosqichma-bosqich (xarajat → chart → excel → to'liq).
