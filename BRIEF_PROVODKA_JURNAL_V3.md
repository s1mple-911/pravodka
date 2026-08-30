# PROVODKA — Jurnal qayta qurish (qatorlar, ustunlar, AI xulosasi)

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first. 🔴 Eski buzilmasin. SQL additive. Push Asilbek. Prod: tasdiqlagach.
⚠️ AVVAL: production AI muammosi hal bo'lsin (rasm-detect EF), keyin jurnal.

## 0. Spidometr + chek (yangi, oldin)
- 🔴 Benzin/gaz moddasida: CHEK (summa) HAM, TABLO (km) HAM tekshiriladi.
- Ikkalasi AI (rasm-detect), ikkalasi MAJBURIY (chek + tablo yuklash shart).
- Ya'ni: benzin xarajati → 2 rasm (chek + tablo) → 2 AI (summa + km) → ikkalasi shart.

## 1. Jurnal qatorlarini bo'lish 🔴
- Hozir: ko'p narsa BIR qatorda (siqilgan, o'qish qiyin).
- 🔴 Qatorlarni bo'lamiz — har ustun alohida (toza, o'qiladigan).

## 2. Jurnal ustunlari (yangi tartib) 🔴
Har qator ustunlari:
1. **id**
2. **sana** (yozilgan sana)
3. **qaysi sana uchun rasxod** (xarajat davri/sanasi)
4. **qayerdan chiqadi** (kassa/hisob — debit manba)
5. **qayerga kiradi** (kassa/hisob — kredit)
6. **ijrochi kim** (created_by)
7. **valyuta** (qaysi valyuta chiqyapti — UZS/USD)
8. **summa**
9. **maqsad** (🔴 user tanlagan maqsad — modda/xarajat turi yoki maxsus maqsad maydoni)
10. **izoh**
11. **AI xulosasi** (🔴 pastda batafsil)
12. **file** (rasm/chek)

## 3. Dokonda tovar o'zgarishi — jurnalda YO'Q 🔴
- 🔴 Dokonda tovar kamaygani/ko'paygani jurnalda KERAK EMAS.
- Ya'ni: tovar harakati (inventar) jurnalda ko'rsatilmasin — faqat pul (xarajat/kirim/transfer).
- Filter yoki chiqarib tashlash (tovar entry'lari).

## 4. AI xulosasi ustuni 🔴
- Agar xarajatga AI qo'shilgan bo'lsa (ai_tekshir/spidometr_ai) → AI xulosasi shu ustunda.
- Ko'rsatiladi:
  - AI xulosasi (shubhali mi, yo'q mi)
  - Cheklar rasmi (chek + tablo)
  - AI tekshirgan narsalar (summa, sana, km)
  - Hammasi shu yerda (bitta joyda — AI natijasi + rasm + xulosа).
- Admin ko'radi (shubhali, AI o'qigan vs user yozgan).

## DB / mantiq
- Jurnal qayta render (ustunlar, qatorlar bo'lingan).
- Tovar entry'lari filter (jurnalda yo'q).
- AI xulosasi (rasm_tahlil + shubhali) → jurnal ustuni.
- Maqsad — user tanlagan (modda yoki maqsad maydoni — CC aniqlasin).
- CC eng toza. Fail-closed (admin AI ko'radi).

## ⚠️ MUHIM
- 🔴 AVVAL production AI (rasm-detect EF) hal bo'lsin.
- 🔴 Spidometr + chek ikkalasi majburiy (benzin/gaz).
- 🔴 Tovar o'zgarishi jurnalda YO'Q.
- 🔴 AI xulosasi ustuni — shubhali + rasm + AI natija (bir joyda).
- Qatorlar bo'lingan (toza), ustunlar yangi tartib.

## Fable oqimi
coder (spidometr+chek majburiy, jurnal ustunlar/qatorlar, tovar filter, AI xulosasi ustuni), designer (jurnal toza qatorlar, AI xulosasi — Apple), tester (chek+tablo majburiy, ustunlar to'g'ri, tovar yo'q, AI xulosasi shubhali+rasm). Push men.

## Tartib
1. 🔴 Production AI hal (rasm-detect EF deploy/CORS).
2. Spidometr + chek (ikkalasi majburiy).
3. Jurnal ustunlar (yangi tartib, qatorlar bo'lingan).
4. Tovar o'zgarishi filter (jurnalda yo'q).
5. AI xulosasi ustuni (shubhali + rasm + AI natija).
