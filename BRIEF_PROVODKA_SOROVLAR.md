# PROVODKA — So'rovlar tizimi (70% to'siq O'CHIRILADI) + jurnal/kassa UI

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first. 🔴 Eski buzilmasin (so'rovlardan tashqari). Pul — fail-closed, permission. SQL additive (+ eski o'chirish). Push Asilbek. Prod: tasdiqlagach.

## 0. ESKI 70% TO'SIQ + QARZ YOPISH — BUTUNLAY O'CHIRILSIN 🔴
- Oldingi ish (xarajat to'sig'i 70%, qarz yopish, to'lanmagan status) — SHU MAVZUGA taalluqli HAMMA narsa o'chirilsin.
- 🔴 SQL + UI + hamma joydan (izsiz):
  - 70% to'siq (kirim/transfer blok) — o'chir.
  - Qarz yopish funksiyalari — o'chir.
  - To'lanmagan status/qizil (agar shu mexanizmga tegishli) — o'chir.
  - Bog'liq RPC/funksiya/ustun/UI — hammasi.
- ⚠️ CC oldingi PROVODKA_XARAJAT_TOSIQ.sql / XARAJAT_QARZ.sql / bog'liq UI ni ko'rib, toza o'chirsin (yangi drop SQL + UI olib tashlash).
- ⚠️ Ehtiyot: faqat 70%/qarz mexanizmi — boshqa xarajat/jurnal/ijrochi TEGILMASIN. CC aniq ajratsin.

## 1. YANGI — So'rovlar sahifasi + pul so'rash
### Hodim tomoni (pul so'rash):
- Hodim xarajat yozayotib, O'Z pulidan (balansidan) KO'P summa yozsa → "Pul so'rash" tugma paydo bo'lsin.
- Tugma bosilsa → modal:
  - **Kimdan so'rash** — tanlanadi (ro'yxatdan: kim pul beradi).
  - 🔴 BALANS KO'RINMASIN (hodim o'z/boshqa balansni ko'rmaydi).
  - **Qancha so'rash** — summa yozadi.
  - **Izoh** — yozadi.
  - Saqlaydi.
- Saqlangach:
  - O'sha xarajat yoziladi — 🔴 PENDING status bilan, jurnalga tushadi (pending).
  - So'rov → "So'rovlar" sahifasiga tushadi (so'ralgan odamga + admin).

### So'rovlar sahifasi (tasdiqlash):
- 🔴 Har kim O'ZIGA kelgan so'rovni ko'radi (kimdan so'ralган bo'lsa). + ADMIN hammasini ko'radi.
- So'rovni ochib → tasdiqlaydi (pul jo'natadi).
- 🔴 QISMAN + TO'LIQ (moslashuvchan): 500k so'ralgan bo'lsa → so'ralган odam 400k jo'nata oladi (qisman) yoki 500k (to'liq) yoki rad.
- Jo'natilgach:
  - So'ragan hodim balansi ko'payadi (jo'natilган summa).
  - 🔴 O'sha zahoti pending xarajatga pul kesib olinadi (pending → oddiy, pul bog'lanadi).
  - Qisman bo'lsa: qolган qism qanday? CC eng toza (masalan qolган pending qoladi yoki yopiladi — CC mantiq).

## Oqim (misol)
1. Hodim qo'lida 100k, 500k xarajat yozdi → o'z pulidan ko'p → "Pul so'rash" tugma.
2. Kimdan so'rash (X), 400k so'radi (yetishmagan qism), izoh, saqlash.
3. Xarajat pending (jurnalда pending), so'rov → So'rovlar (X + admin).
4. X so'rovni ko'radi → 400k (to'liq) yoki 300k (qisman) jo'natadi.
5. Hodim balansi +jo'natilган → pending xarajatga pul kesiladi → oddiy xarajat.

## 🔴 XAVFSIZLIK / edge case
- Balans SIZMASIN (so'rash modalида hodim balans ko'rmaydi).
- So'rov permission: faqat so'ralган odam + admin ko'radi (fail-closed, RLS).
- Edge case (CC ko'rsin): qisman jo'natish + qolган pending, so'rov rad etilsa xarajat nima bo'ladi, ikki marta tasdiqlash (idempotent), o'ziga o'zi so'rash, manfiy/nol summa, so'ralган odam yo'q bo'lsa.
- Pul harakati double-entry to'g'ri (jo'natish → hodim balans, pending yopilish → provodka).

## 2. JURNAL UI — Boshlang'ich + Tugash miqdor
- Jurnal davr xulosasiga: **Boshlang'ich miqdor** va **Tugash miqdor** qo'shilsin (kirim/chiqim kabi ko'rinsin).
- **Boshlang'ich miqdor** = tanlangan davr BOSHIDA qo'lda nech pul bor edi.
- **Tugash miqdor** = tanlangan davr OXIRIDA nech pul bilan tugadi (qo'lda nech pul).
- 🔴 Kirim/chiqim ham to'g'ri ishlasin (boshlang'ich + kirim − chiqim = tugash — balans mantiqi).
- Aros mahsulot tarixi uslubi (boshlang'ich → harakat → tugash).

## 3. KASSA sahifasida SEARCH
- Kassa sahifasida qidiruv (search) qo'shilsin.
- Kassa/element bo'yicha tez topish.

## DB (additive + o'chirish)
- 70%/qarz: eski RPC/funksiya/ustun drop (CC aniqlaydi).
- So'rovlar: `sorovlar` (id, sorovchi_id, kimdan_id, summa, izoh, status[pending/qisman/tasdiq/rad], jonatilган_summa, xarajat_entry_id, sana).
- Pending xarajat: entry'da pending status (yoki bog'lash).
- Jurnal boshlang'ich/tugash: davr boshi/oxiri qoldiq hisobi (kassa balans).
- CC eng toza sxema. RLS, permission (fail-closed).

## Fable oqimi
coder (70% o'chirish, so'rovlar tizimi + pending + qisman, jurnal boshlang'ich/tugash, kassa search), designer (pul so'rash modal — balanssiz, so'rovlar sahifasi, jurnal boshlang'ich/tugash, kassa search — Apple), tester (🔴 70% toza o'chdi boshqa buzilmadi, so'rov balans sizmaydi, qisman jo'natish, pending yopilish, permission fail-closed, edge case, jurnal boshlang'ich/tugash to'g'ri). 🔴 Eski buzilmasin. Dev-first. SQL additive (men RUN). Push men. Prod: men tasdiqlagач.

## Tartib
1. 🔴 Eski 70% to'siq + qarz — BUTUNLAY o'chir (toza).
2. So'rovlar tizimi (pul so'rash modal + pending + so'rovlar sahifasi + qisman/to'liq).
3. Jurnal boshlang'ich/tugash miqdor.
4. Kassa search.
🔴 Avval eski o'chirish (toza), keyin yangi so'rovlar. Edge case puxta.
