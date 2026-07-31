# PROVODKA — kassa/valyuta modelini qayta qurish (bitta kassa + tur child'lar)

Kontekst: hozir har valyuta ALOHIDA kassa (5011 Toshkent, 5632 Toshkent $, 5802 AED, 5901 CHY — 4 alohida). Yangi model: BITTA "Toshkent kassa" + ichida child-hisoblar (naqd/click/payme/dollar + konvert bilan qo'shiladigan valyutalar).

⚠️ MUHIM: wipe baribir bo'ladi (hamma yozuv o'chadi), shuning uchun eski valyuta kassalarni bemalol qayta qurish mumkin — qoldiq ko'chirish shart emas. TARTIB: avval wipe (yozuv 0), keyin struktura qayta quriladi, keyin Aros sync boshlang'ich qoldiqni tur bo'yicha yozadi.

Faqat -dev.html + SQL. entry.created_by TEXT. boot() oxirida. node --check. Provodka project (kxzerccdpcltmzrxutlo) — TaskFix EMAS.

---

## Model (yangi)
- **Kassa** (masalan 5011 "Toshkent kassa") = konteyner/parent.
- **Child-hisoblar** = pul turlari:
  - Aros breakdown'dan: naqd, click, payme, dollar (cash/click/payme/dollar_usd)
  - Konvert orqali qo'shiladigan: AED, CHY, boshqa valyuta (foydalanuvchi konvert qilsa yangi child paydo bo'ladi)
- Kassa jami = hamma child qoldig'i yig'indisi (UZS ekvivalentida, valyutalar kurs bilan).
- Har child'ning o'z qoldig'i (double-entry, entry_line'dan).

## 1. Eski valyuta kassalarni birlashtirish
Hozirgi alohida valyuta kassalar (code'да $ yoki · AED/CHY bор, `ildiz_kassa` parentга ishora qiladi):
- 5632 Toshkent $ → 5011 ning USD child'i
- 5802 Toshkent AED → 5011 ning AED child'i
- 5901 Toshkent CHY → 5011 ning CHY child'i
- 5633 Qashqadaryo $ → 5012 USD child, 5801 Buxoro AED → 5215 AED child
- CC hammasini `ildiz_kassa` (yoki mavjud parent bog'lanish) bo'yicha aniqlab, child-hisob sifatida qayta belgilasin: `pul_turi` = valyuta ('dollar'/'aed'/'chy'), parent = ildiz kassa.
- ⚠️ Wipe'dan KEYIN: eski kassalarda yozuv qolmaydi (0), shuning uchun ularni o'chirish/qayta belgilash xavfsiz. Agar butunlay o'chirib yangi child yaratish osonroq bo'lsa — o'chir (wipe'dan keyin bog'liq yozuv yo'q). Aros ranglar, brend.

## 2. Har kassaga standart turlar (naqd/click/payme/dollar)
Har kassa (filial + markaziy) uchun Aros breakdown turlari child sifatida ochilsin:
- naqd, click, payme, dollar — `create_pul_turi_child` yoki to'g'ridan insert.
- SEED SQL — HAMMA kassaga avtomat (loop/insert-select), qo'lda bittalab emas. Idempotent.
- dollar child = mavjud valyuta kassa bilan BIR XIL bo'lsin (ikki marta bo'lmasin) — 1-band bilan muvofiq. Ya'ni "dollar" turi = o'sha kassaning USD child'i.
- Qaysi kassaga qaysi tur: hammasiga 4 tur (naqd/click/payme/dollar), yoki Aros javobida o'sha filialда bor turlar. CC eng sodda to'g'ri yo'lni tanlab izohlasin.

## 3. Konvert orqali yangi valyuta qo'shish
- Konvertда: foydalanuvchi kassaga YANGI valyuta qo'sha olsin (masalan AED yo'q edi, konvert qilib AED oldi → AED child avtomat yaratiladi).
- `create_pul_turi_child` yoki `create_valyuta_child` konvert oqimida chaqirilsin (agar child yo'q bo'lsa yaratsin, keyin to'ldirsin).
- Konvert: manba tur ↓, yangi valyuta child ↑. Izoh/koridor matni yo'q (oldingi brief).

## 4. n8n Aros Sync — tur bo'yicha boshlang'ich qoldiq
Wipe'dan keyin Aros breakdown'ni tur bo'yicha yozish:
- Aros filial balansи: cash → naqd child, click → click child, payme → payme child, dollar → dollar child.
- Har biri: Dt <filial kassa ning tegishli tur child'i> / Kt 9010 (boshlang'ich qoldiq, savdo tushumi EMAS).
- `v_filial_turi_hisob` (filial_ref + pul_turi → account_id) buni beradi — CC tayyorlagan.
- Bu n8n o'zgarishi — men (Claude) qilaman, CC v_filial_turi_hisob to'g'ri ekanini tasdiqlasin va menga account mapping'ni bersin.

## 5. Frontend (barcha sahifa)
- **filial**: har filial ostида bor turlar chip (naqd/click/payme/dollar/valyuta), nol chiqmaydi.
- **kassa**: har kassa jami + tur breakdown.
- **professional**: kassa tanlanganda turlar segment (naqd/click/payme/dollar + konvert valyutalari), qaysidan yechish tanlanadi, o'sha tur+jami kamayadi.
- **jurnal**: qaysi turdan ketgani teg bilan.
- Hammasi mavjud v_kassa_turlar/v_kassa_tanlov/v_kassa_card bilan (CC qsurgan) — 1-2 band struktura tayyor bo'lgach ishlaydi.

## Tartib (MUHIM — wipe bilan bog'liq)
1. Avval oldingi ishlar push + test (summa 000, koridor, filial breakdown ko'rinishi)
2. **WIPE** (PROVODKA_WIPE.sql — Provodka project!) → hamma yozuv 0
3. **Struktura qayta qurish** (1-2 band SQL: eski valyuta kassa birlashtirish + turlar seed)
4. **n8n Sync tur bo'yicha** (men qilaman) → boshlang'ich qoldiq tur child'larga
5. Sinov: professional turlar, konvert yangi valyuta, jurnal teg

SQL: `PROVODKA_KASSA_MODEL.sql` (struktura), wipe alohida. Push men qilaman.
Har qadam alohida — struktura o'zgarishi katta, ehtiyot. Har SQL RUN'дан oldин project nomini (Provodka!) tekshir.
