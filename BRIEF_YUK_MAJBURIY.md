# PROVODKA — "Tovar tannarxi" xarajatida yuk tanlash majburiy + summa nazorati

Kontekst: professional-dev.html'da 9110 "Tovar tannarxi" tanlanganda "Qaysi yuk uchun?" modali ochiladi (multiselect). Hozir "Yuksiz saqlash" bilan yuk tanlamasdan ham saqlash mumkin, va xarajat summasi tanlangan yuklar summasidan katta bo'lsa ham saqlanadi. Ikkalasi ham tuzatilishi kerak.

---

## 1. Yuk tanlash MAJBURIY
- **"Yuksiz saqlash" tugmasi olib tashlansin.**
- 9110 "Tovar tannarxi" tanlanganda modal ochiladi va **kamida bitta yuk tanlanmasa yopilmaydi**. Modalni yopish uchun: yuk tanlash, yoki modda tanlovini bekor qilish ("Bekor" → modда tanlovi tozalanadi/oldingi holatga qaytadi).
- Yuk tanlanmagan holatda asosiy formadagi **Saqlash disabled** + izoh: "Tovar tannarxi uchun yuk tanlanishi shart".
- Bu faqat 9110 uchun. Boshqa moddalar oldingidek (yuksiz saqlanadi).

## 2. Summa nazorati — xarajat tanlangan yuklardan OSHMASIN
- **Qoida**: `xarajat_summasi (UZS) <= tanlangan_yuklar_jami (UZS)`.
- Oshsa → **Saqlash disabled** + qizil xabar: "Xarajat summasi tanlangan yuklardan {farq} ga ko'p. Yana yuk tanlang yoki summani kamaytiring."
- Kam bo'lsa — RUXSAT (qisman to'lov normal). Modalda ko'rinsin: "Qoldi: X so'm" (kulrang, xato emas).
- Modal ichidagi hozirgi "Xarajat summasi / Tanlangan yuklar / Farq" bloki qolsin, faqat farq **manfiy** (xarajat ko'p) bo'lganda qizil + saqlash to'siladi.

## 3. VALYUTA — hammasi UZS'ga o'girib solishtiriladi
Bu eng nozik qism. Ikki tomonda ham valyuta har xil bo'lishi mumkin:
- **Yuk narxi**: UZS / USD / CHY / AED (Aros API `currency.name`)
- **Xarajat summasi**: tanlangan kassa valyutasida (UZS yoki USD/AED — professional'da valyuta tugmalari bor)

Qil:
- Har ikkalasini **UZS ekvivalentiga** o'gir, keyin solishtir. Hech qachon xom sonlarni taqqoslama (500 USD ≠ 500 UZS).
- Kurs manbai: mavjud `conv_baza_kurs(p_cur text)` funksiyasi (1 birlik valyuta necha so'm) — USD uchun `aros_usd_rate()`, boshqalari uchun `currency_rate` jadvalidagi oxirgi kurs. Yangi kurs mantiqini yozma, shuni ishlat.
- ⚠️ **Valyuta kodi nomuvofiqligi**: Aros "CHY" deb qaytaradi, `currency_rate`da ehtimol "CNY". Tekshir va moslashtir (map: CHY→CNY). AED ham borligini tekshir.
- **Kurs topilmasa** (masalan AED kursi kiritilmagan): o'sha yukni tanlashga ruxsat berma yoki aniq xabar ko'rsat — "AED kursi kiritilmagan. Valyuta bo'limida qo'shing." Jimgina 0 deb hisoblama (bu noto'g'ri "to'langan" beradi).
- Modalda har yuk yonida asl valyutadagi narx **va** UZS ekvivalenti ko'rinsin (masalan `1 373.79 USD ≈ 17 250 000 so'm`), jami esa UZS'da.
- Kurs qaysi sanadagi: joriy (oxirgi kurs) — sodda va tushunarli. Izohda ayt.

## 4. Aniqlik (foydalanuvchi ko'radigan matnlar)
- Jami: "Tanlangan yuklar: 36 112 117 so'm (2 ta)"
- Xarajat: "Xarajat summasi: 11 111 so'm"
- Yetsa: "Qoldi: 36 101 006 so'm" (kulrang)
- Oshsa: "Xarajat yuklardan 5 000 000 so'm ko'p — saqlash mumkin emas" (qizil)
- Valyutali yuk: `500.00 USD ≈ 6 300 000 so'm (kurs 12 600)`

## Texnik
- Faqat `professional-dev.html` (va agar `hodim-dev.html`da ham 9110 ishlatilsa — o'sha ham).
- Server tomonda ham tekshirish shart emas (bu biznes qoida, buxgalteriya emas) — lekin xohlasang `yuk_ids` bo'sh bo'lgan 9110 yozuvini rad etuvchi tekshiruv qo'shsa bo'ladi; qo'shsang alohida SQL faylga.
- `boot()` modul oxirida; node --check; Aros brend ranglari.


---

# QO'SHIMCHA: QISMAN TO'LOV (bu qism yuqoridagi 2-3 bandlarni ALMASHTIRADI)

Yuk bo'lib-bo'lib to'lanishi mumkin. Hozirgi `yuk_ids INT[]` faqat "qaysi yuk" ni saqlaydi, "qancha to'langan" ni emas — shuning uchun qisman to'lov ko'rinmaydi va bir yukni ikki marta to'liq "to'langan" qilib bo'ladi.

## A. DB (PROVODKA_YUK_QISMAN.sql — additive)
```sql
create table if not exists entry_yuk (
  entry_id  uuid not null references entry(id) on delete cascade,
  yuk_id    integer not null,
  summa_uzs numeric not null check (summa_uzs > 0),
  primary key (entry_id, yuk_id)
);
create index if not exists entry_yuk_yuk_idx on entry_yuk(yuk_id);
```
- `entry.yuk_ids` ustuni **qoladi** (eski yozuvlar uchun) — lekin yangi yozuvlar `entry_yuk` ga yoziladi. Ikkalasini birga to'ldir (yuk_ids = tanlangan idlar) — eski kod sinmaydi.
- RLS: entry bilan bir xil ko'rish qoidasi (yoki entry orqali). Anon yopiq.

**RPC** `yuk_tolov_holati(p_ids integer[], p_narx jsonb)` — yoki soddaroq `yuk_tolangan_summa(p_ids integer[])`:
qaytaradi `[{yuk_id, tolangan_uzs, entrylar: [{entry_id, entry_date, summa_uzs}]}]`
(faqat `is_deleted=false` va `status='posted'` entrylar hisobga olinadi).
Yuk narxi Aros'dan keladi (n8n), shuning uchun **foiz frontendда hisoblanadi**: `tolangan_uzs / narx_uzs`.

## B. Holatlar
| Foiz | Holat | Rang |
|---|---|---|
| 0% | To'lanmagan | qizil/kulrang |
| 1–99% | **Qisman (X%)** | sariq |
| >=100% | To'langan | yashil |

- Yuklar sahifasidagi filtr: Hammasi / To'lanmagan / **Qisman** / To'langan.
- Har yuk qatorida: `To'langan: 25 000 000 / 30 000 000 (83%) · Qoldi: 5 000 000` + qaysi xarajatlar (sana, summa) ro'yxati.

## C. Modalda taqsimlash (2-bandni almashtiradi)
- Har yuk yonida ko'rsat: asl narx (valyutada) · UZS ekvivalenti · **allaqachon to'langan** · **qoldi**.
- Tanlanganda har yukka **summa maydoni** chiqadi (UZS).
  - Bitta yuk tanlansa → butun xarajat summasi avtomatik o'shanga.
  - Bir nechta tanlansa → **qolgan qarzi bo'yicha proporsional** avtomatik taqsimlanadi, foydalanuvchi qo'lda o'zgartira oladi.
- **Qat'iy tekshiruvlar (Saqlash disabled bo'ladi):**
  1. Taqsimlangan jami **=** xarajat summasi (UZS). Farq bo'lsa: "Taqsimlanmagan qoldi: X" yoki "Ortiqcha taqsimlandi: X".
  2. Har yuk uchun yozilgan summa **<= o'sha yukning qolgan qarzi**. Oshsa: "#2709 uchun faqat 5 000 000 so'm qoldi".
  3. Kamida bitta yuk tanlangan (1-band).
- Ya'ni endi cheklov **qolgan qarz** bo'yicha, umumiy narx bo'yicha emas — bir yukni ikki marta to'liq to'lash imkonsiz.

## D. Saqlash
- entry yaratilgach: har tanlangan yuk uchun `entry_yuk` ga qator (entry_id, yuk_id, summa_uzs).
- Xatolikda entry kompensatsion o'chirilsin (mavjud naqsh).
- Jurnalda teg: `📦 #2709 (3 510 000) · #2708 (7 601 006)` — har yuk yonida shu yozuvdan tushgan summa.

## E. Eski yozuvlar
`entry_yuk` bo'sh, lekin `yuk_ids` to'la bo'lgan eski yozuvlar bo'lsa — ularni migratsiya qilma (summani bilib bo'lmaydi). Holat hisoblashda ular hisobga olinmaydi; agar shunday yozuv bo'lsa jurnalda oddiy `📦 #id` tegi qolaversin.
