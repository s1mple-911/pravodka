# PROVODKA — valyuta/tur bo'yicha kassa (filial + kassa + professional + jurnal + konvert)

ERTAGA prodga chiqadi. Katta ish — 4 qismga bo'lingan, oson→murakkab. Faqat -dev.html; SQL additive alohida; entry.created_by TEXT; {error} doim; boot() oxirida; node --check.

## Asosiy model (tushunish)
- Filial puli AROS'dan keladi (n8n javob: cash, click, payme, dollar_usd, dollar_in_uzs, total). Bu Aros balansi — Provodka entry emas.
- Konvert/yechish PROVODKA ichida bo'ladi (entry). Ya'ni: boshlang'ich = Aros balansi, undan keyingi harakat = Provodka entry (kirim/chiqim/konvert).
- Filialning JORIY qoldig'i (tur bo'yicha) = Aros boshlang'ich + Provodka entry harakati. CC bu ikkovni birlashtirish mantiqini aniqlab, izohlab bersin (agar hozir faqat Aros ko'rsatilsa — Provodka harakatini ustiga qo'shish kerak).

---

## 1. KONVERT koridor MATNINI olib tashlash (OSON — avval, tez g'alaba)
Konvert modalида hali "Tayanch: 12 100 · ruxsat 12 015 – 12 185 (±0.7%)" degan MATN ko'rinadi. Bu ruxsat etilган kurs oralig'i (koridor) — foydalanuvchiga KO'RSATILMASIN (V8'да so'ralган edi, hali bor — demak to'liq olib tashlanмаган yoки push bo'lмаган).
- konvert-dev.html (va kassa-dev konvert modalида): "Tayanch: X · ruxsat A–B (±N%)" matnи oddiy foydalanuvchига ko'ринмаsин. 
- Kurs kiritish, validatsiya (koridordан chиqsа pending) — HAMMASI QOLADI, faqат oraliq MATNи yashirиladi. Foydalanuvchи chegарани oldindan ko'рмаsин.
- Admin uchun ko'ринса qoldirса bo'ladi (ixtiyoriy), lekin oddiy foydalanuvчига umuман chиqмаsин.
- ⚠️ Bu izoh (comment) EMAS — ekranда ko'ринадиган koridor matnи. Uni topиб yashир.

## 2. Filialда faqat BOR turlar ko'rinsin (OSON)
filial-dev.html: hozir faqat Dollar chiqyapti (rasmда). n8n breakdown to'liq keladi (cash/click/payme/dollar). 
- Har filial ostida FAQAT nol bo'lmagan turlar chip bo'lib chiqsin: 💵 Naqd · 💳 Click · 📱 Payme · 💲 Dollar.
- Rasmда faqat Dollar ko'rinyapti — demak cash/click/payme yo ulanmagan yo 0. CC tekshir: n8n javobida cash/click/payme keladimi (Asilbek "hammasi keladi" dedi). Kelsa-yu ko'rinmаса — frontend ularni tashlab yuboryapti (syncNow snapshot). Tuzat: hammasini snapshot'ga ol, nol bo'lmaganini ko'rsat.
- Agar n8n haqiqatan faqat dollar yuborsa — CC aytadi, men n8n endpointni Aros API breakdown bilan yangilayman.

## 3. Kassa (kassa.html) — tur bo'yicha qoldiq (OSON-O'RTA)
Filialdagi tur breakdown kassa sahifasiga ham chiqsin: har kassa "shuncha naqd, shuncha click, shuncha dollar" ko'rsatsin.
- kassa-dev.html: har filial/kassa kartochkasida jami + tur bo'linishi (filial-dev bilan bir xil chip).
- Manba: filial uchun Aros breakdown; markaziy kassalar uchun Provodka qoldig'i (mavjud).
- Bu asosan ko'rsatish — hisobga tegmaydi.

## 4. Professional — tur tanlash + tur bo'yicha yechish (MURAKKAB — asosiy ish)
professional-dev.html: kassa tanlanganda uning TURLARI chiqsin, foydalanuvchi qaysi turdan pul chiqishini tanlasin.
- Kassa tanlanganda: mavjud turlar ro'yxati (naqd/click/payme/dollar + konvert bilan qo'shilgan valyutalar). FAQAT bor (>0) turlar.
- Foydalanuvchi turni tanlaydi (masalan "Click") + summa. 
- **Yechilganda o'sha turdan VA jamidан kamaysin** — masalan Click'dan 500k chiqsa, Click qoldig'i −500k, jami −500k.
- Bu Provodka entry sifatida yoziladi: qaysi kassa + qaysi tur + summa. Tur ma'lumoti entry'да saqlansin (yangi ustun kerak bo'lsa: entry_line yoki entry'ga `pul_turi text` — naqd/click/payme/dollar/valyuta kodi).
- Guard: tanlangan turda qoldiq yetarli bo'lsin (Click'да 300k bor, 500k yechib bo'lmaydi) — UI + iloji bo'lsa server.
- Kassa qoldig'i (tur bo'yicha) = Aros boshlang'ich(tur) + Provodka entry harakati(tur). CC bu hisobни aniqlab qursin.

DB (additive):
```sql
-- pul turi: entry_line yoki entry darajasida
alter table entry add column if not exists pul_turi text;  -- 'naqd'|'click'|'payme'|'dollar'|valyuta kodi
-- yoki entry_line' da, agar tur satr darajasида kerak bo'lsa
```
RPC/view: kassa uchun tur bo'yicha joriy qoldiq (Aros breakdown + entry harakati). CC eng toza yo'lni tanlab qursin.

## 5. Konvert — tur bo'yicha (MURAKKAB, 4 bilan birga)
Konvert = bir turdan boshqasига (masalan Naqd → Dollar sotib olish).
- Konvert qilinganда: manba tur kamaysin, maqsad tur (valyuta) ko'paysin. O'sha kassaда yangi valyuta paydo bo'ladi.
- Keyin professional'da o'sha kassa tanlanса — yangi valyuta ham turlar ичida chiqsin (4-ish bilan bog'liq).
- Izoh shart emas (1-ish).

## 6. Jurnal — qaysi turdan ketganini ko'rsatish
jurnal-dev.html: har yozuvда pul qaysi turdan chиққанини teg bilan ko'rsat.
- Masalan: "💳 Click'dan" / "💵 Naqd'dan" / "💲 Dollar'dan" — entry.pul_turi'дан.
- Kt (chiqadi) yonида tur ko'rinsin.

---

## Tartib
1 (izoh olib tashla — tez) → 2 (filial turlar) → 3 (kassa turlar) → 4 (professional tur tanlash+yechish — asosiy) → 5 (konvert) → 6 (jurnal teg).
SQL → `PROVODKA_VALYUTA.sql`. Har qism alohida commit. Push men qilaman. n8n breakdown yetmasa — ayt, men yangilayman.

⚠️ Bu wipe'дан OLDIN bo'lсин (dev'да sinash uchun ma'lumot kerak). Wipe eng oxirida.
