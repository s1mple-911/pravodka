# PROVODKA V9 — tarixni tozalash + summa 000 + filial kassa breakdown + prod tayyorlik

Kontekst: Provodka ERTAGA prodga chiqadi. entry insert yo'li o'zgarmaydi; double-entry (entry/entry_line, qoldiq entry_line'dan hisoblanadi). boot() oxirida; node --check; perms; guard trigger.
Qoidalar: faqat `-dev.html`; SQL additive/ehtiyot alohida faylga; `entry.created_by` TEXT; `{error}` doim; Aros brend ranglari.

---

## 1. Barcha test tarixini tozalash (mutlaqo toza start)
Prodga chiqishдан oldин hamma test yozuvi o'chsin — kassalar 0 ga qaytsin (boshlang'ich qoldiq ham).
- Double-entry: qoldiq entry_line'dan hisoblanadi → hamma entry+entry_line o'chsa, kassalar avtomат 0.
- SQL (`PROVODKA_WIPE.sql`) — EHTIYOT, faqat Asilbek RUN qiladi, bir marta:
  - `entry`, `entry_line` (barcha yozuvlar), `entry_yuk`, `entry_history` (bo'lsa), boshlang'ich qoldiq yozuvlari — hammasi.
  - Bog'liq: `standart_xarajat` sarflangani entry'dan hisoblanadi → entry o'chsa 0 (jadval o'zi qolsin, limitlar qolsin). `conv_*` konvert yozuvlari ham entry bo'lsa o'chadi.
  - ⚠️ O'CHIRMA: accounts (kassalar/moddalar tuzilmasi), user_perms, standart_xarajat limitlari, provodka_config, filial_ref/linked_kassa_id, sozlamalar. Faqat TRANZAKSIYA yozuvlari (entry va bog'liqlari).
  - Tranzaksiya ichida; oxirida tekshiruv: `select count(*) from entry` = 0, va bir necha kassa qoldig'i = 0 (RAISE agar qolsa).
  - ⚠️ Aros sync (n8n) qayta yozuv qo'shmasin — wipe'dan keyin n8n Auto Sync ishga tushsa, filial/transfer yozuvlarini qayta yaratishi mumkin. Buni hisobga ol: wipe FAQAT manual (source='manual') yozuvlarni o'chirsinmi yoki hammasinimi? Asilbek "hammasi" dedi — lekin aros_auto yozuvlar sync bilan qaytadi. Izohда ayt: agar aros_auto ham o'chsa, keyingi sync ularni qayta tortadi (bu normal). Faqat manual test yozuvlar butunlay ketadi.
- Frontend: wipe'dan keyin hamma sahifa bo'sh holatда to'g'ri ko'rinsin (0 yozuv → "yozuv yo'q", yiqilmasin).

## 2. Summa inputга avtomat "000" (minglik)
Summa kiritishда — odam katta raqam yozadi, oxiridagi 000 zerikarli. Kerak:
- Summa maydoniga yozganда, avtomат oxiriga `000` qo'shilsin (ya'ni "15" yozsa → "15 000", "150" → "150 000").
- LEKIN foydalanuvchi o'zi tahrirlаsa (000 ni o'chirsa yoki boshqa raqam yozsa) — o'zi hal qilsin, majburlама.
- Aniq mexanizm: input bo'sh bo'lsa yoki yangi yozа boshlаsa — 3 ta 0 default turadi, kursor 0'lardan oldинда. Odam raqам tersa, 0'lар oxirида qolади. Yoки: yozилган raqамга ×1000 tugмаси/avtomat. Eng qulay UX'ни tanla (senior).
  - Muqobil (soddaроq va aniq): yozилган raqамni minglик ajratгich bilan ko'рсат (15000 → "15 000"), va "×1000" yoki "+000" tugмаси yonида — bir bosishда 000 qo'shади. Foydalanuvchи 15 yozиб tugмани bosса 15000 bo'ladi.
- Bu hamma summa inputга (professional, hodim, konvert, transfer) — izchil.
- Muhim: saqlaganда haqiqий raqам ketsin (bo'sh joysиz). Faqат ko'ринiш minglик bilan.
- ⚠️ 000 avtomат qo'shилса, odam 500 so'm yozмоqчи bo'lса muammо — shuning uchun MAJBURLAMA, faqат qulaylик (tugма yoки oson tahrirlanadigan default). Asilbek "men uzim edit qilsam bolsin" dedi — ya'ni 000 ni olib tashlаsа bo'ladi.

## 3. Filial kassa breakdown (sum/dollar/click/payme)
Filiallar sahifaсида hozir filial puli faqат BITTA qiymatда (jami so'mда). Kerак: filial tagida/ostида barcha bo'linish — **naqd (sum), dollar, click, payme** va Aros API'da nima kelsa.
- Ma'lumот: n8n'да ALLAQACHON keladi (Asilbek tasdiqladi), faqат frontend ko'рсатмаяпti. n8n javобida filial balanslari breakdown bor (masalan `cash_balance`, `click_balance`, `payme_balance`, `dollar_balance`).
- CC: filial ma'lumот keladiган endpoint javобини tekshir (n8n `aros-cache-*` yoki bugalter endpoint) — breakdown maydonlarини top.
- Filiallar sahifаsида (`filial-dev.html` yoki tegishli): har filial kartоchkаsида/detalида jami so'м + ostида bo'linish:
  - 💵 Naqd: X · 💳 Click: Y · 📱 Payme: Z · 💲 Dollar: $W (agar bor)
  - Chиройли, ixcham (chip yoки kichик qatorlар). Bo'sh (0) bo'lганlarни ko'рсатмасa ham bo'ladi yoки kulrang.
- Agar n8n javобida breakdown yo'q bo'lса — CC aytadi, men n8n endpointни yangилайман (Aros API'дан breakdown olиб).

## 4. PROD TAYYORLIK — audit (ertaga chiqadi)
Provodka prodga chiqishдан oldин CC tekshirsin va ro'yxat bersin:
- **Bo'sh holatlar**: wipe'дан keyin (0 yozuv) hamma sahifа yiqilмаsин — jurnal, balans, hisobot, qarzdor, cashflow bo'sh massivда `.map`/`[0]` xato bermasин.
- **Xatolar ko'rinsин**: har saqlash/o'chириш `{error}` tekshiradими; "Saqlandi" faqат rostdan; xom Postgres xato o'rniga tushunarli o'zbekcha.
- **Perms**: cheklangan user faqат ruxsat berilган kassa/sahifани ko'ради; server guard (entry_line trigger) ishlаyapti.
- **Dev/prod**: `-dev.html` fayllarда ishlaндi — prodga chiqishда promote (dev→prod) to'g'ри bo'lsин. Qaysи fayllar tayyor, qaysи yo'q — ro'yxат.
- **Mobil**: asosий oqimlar (hodim xarajat, professional, kassa) telefonда ishlaydiми.
- **n8n endpointlar**: Provodka ishlatadigan hamma webhook (perms, yuklar, xarajat-alert) Active va credential biriktирилган.
- **Xavfsizlik**: frontendда service_role kalit yo'q (anon only); RLS/perm guard yozuvni himoyalayди.
- Natijada: kritik (ertagacha) / muhim / keyinga ro'yxati. Kritiklarни darrov tuzat.

## Tartib
2 (summa 000 — kichik) → 3 (filial breakdown) → 4 (audit) → 1 (wipe — ENG OXIRIDA, hammasi tayyor bo'lgach, chunki bu qaytarib bo'lmaydi). Wipe'ни faqat prodga chiqish oldidan, hamma test tugagach.
SQL: `PROVODKA_WIPE.sql` (alohida, ehtiyot). Push Asilbekда.
