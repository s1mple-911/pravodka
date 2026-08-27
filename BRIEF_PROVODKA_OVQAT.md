# PROVODKA — Ovqat xarajati nazorati (obed/zavtrak + hodim ro'yxati + limit)

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first. 🔴 Eski buzilmasin. Pul — fail-closed. SQL additive. Push Asilbek. Prod: tasdiqlagach. ⚠️ Edge case KO'P — CC puxta o'ylasin.

## Muammo
Kompaniya ovqat beradi: obed = 30,000, zavtrak = 7,000 (har kishiga). Hodimlar boshqa xarajatni ovqat deb yozyapti yoki 30k dan ko'p yozyapti — nazorat yo'q. 20+ filial, bir kishi 3-4 kishi uchun yozishi mumkin.

## Yechim — hodim ro'yxati + counter + limit

### 1. Ovqat xarajat turi (obed/zavtrak)
- Maxsus xarajat turi: "Ovqat" (yoki obed/zavtrak alohida).
- Narxlar: obed = 30,000, zavtrak = 7,000 (har kishiga). 🔴 provodka_config'da (oson o'zgartirish).

### 2. Oqim (ovqat yozish)
1. Hodim summa yozadi (avvalgidek).
2. Ovqat turi tanlanadi → hodimlar ro'yxati ochiladi.
3. 🔴 Ro'yxat: **aros-staff**dan hodimlar, KASSA ULANGAN FILIAL bo'yicha sort.
   - Masalan: Samarqand kassa ulangan → Samarqand filial hodimlari ko'rinadi.
   - Multiselect (bir necha hodim tanlanadi).
4. Har hodim uchun: obed yoki zavtrak tanlanadi (obed=30k, zavtrak=7k).
5. 🔴 Har hodim belgilanганда → TEPADA COUNTER qo'shilib boradi (per obed 30k / zavtrak 7k).
   - Masalan: 4 kishi obed → counter 120,000.
6. Yozgan summa vs counter (kishi × narx):
   - 🔴 Mos kelmasa (yozgan summa > counter) → OGOHLANTIRISH (oshib ketdi).

### 3. Hodim ro'yxati — aros-staff
- 🔴 aros-staff'dan hodimlar ro'yxati (barcha hodimlar).
- Kassa ulangan filial bo'yicha SORT/FILTER — o'sha filial hodimlari.
- ⚠️ aros-staff ulanishi: CC topsin (n8n endpoint yoki DB yoki API). Manba noma'lum bo'lsa Asilbekdan so'rasin.

### 4. 🔴 Takror himoyasi — bir kishi kuniga 1 obed + 1 zavtrak
- 🔴 Bir hodim kuniga FAQAT 1 marta obed VA 1 marta zavtrak yozilishi mumkin.
- Ya'ni: agar Ali bugun obed olgan bo'lsa → yana obed yozib bo'lmaydi (o'sha kun).
- Zavtrak alohida (1 marta).
- Takror urinilsa → OGOHLANTIRISH/BLOK ("Ali bugun obed olgan").
- ⚠️ Bu MUHIM edge case — hodimlar 30k dan ko'p yozishning oldini oladi (bir kishiga 1 marta).

## ⚠️ EDGE CASE (CC PUXTA O'YLASIN)
- Bir kishi 3-4 kishi uchun yozadi (bitta yozuvda ko'p hodim) — counter kishi soni bo'yicha.
- Bir kishi kuniga 1 obed + 1 zavtrak (takror yo'q).
- Yozgan summa counter dan oshsa — ogohlantirish.
- Hodim boshqa filial hodimini tanlasa (kassa ulangan filial emas) — cheklansin yoki ogohlantirish.
- Yarim kun (faqat zavtrak yoki faqat obed).
- Ovqat bekor qilinsa/o'chirilsa — takror hisobi to'g'ri (o'sha kun yana yozish mumkin).
- CC yana edge case topsa — aytsin.

## DB (additive)
- Ovqat narxlari: provodka_config (obed=30000, zavtrak=7000).
- Ovqat yozuvi: entry + hodim ro'yxati (entry_ovqat: entry_id, hodim_id, tur[obed/zavtrak], narx).
- Takror himoyasi: bir hodim + kun + tur unique (kuniga 1 obed, 1 zavtrak).
- aros-staff: CC ulanishni topsin.
- CC eng toza sxema. RLS, permission.

## ⚠️ MUHIM — CC AVVAL MANTIQ
- Edge case ko'p — CC AVVAL to'liq mantiq/oqim taklif qilsin (kod yozmasdan), Asilbek ko'radi, keyin quradi.
- aros-staff ulanishi (hodim ro'yxati) — CC topsin/aniqlasin.

## Fable oqimi
coder (ovqat turi, hodim ro'yxati aros-staff filial sort, counter, takror himoyasi kuniga 1, summa nazorati), designer (ovqat modal, multiselect hodim, counter — Apple), tester (🔴 counter to'g'ri, takror himoyasi kuniga 1 obed/zavtrak, summa oshsa ogoh, filial sort, edge case, fail-closed). 🔴 Eski buzilmasin. Dev-first. SQL additive (men RUN). Push men.

## Tartib
1. 🔴 CC AVVAL to'liq mantiq/oqim + edge case (kod yozmasdan) → Asilbek ko'radi.
2. Ovqat turi + narx (config).
3. Hodim ro'yxati (aros-staff, filial sort, multiselect).
4. Counter (obed/zavtrak × kishi).
5. Takror himoyasi (kuniga 1 obed + 1 zavtrak).
6. Summa nazorati (oshsa ogoh).
