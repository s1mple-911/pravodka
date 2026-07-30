# PROVODKA — summa avtomat 000 (tugma emas) + dev→prod promote

## 1. Summa avtomat "000" — TUGMA EMAS, AVTOMATIK
Oldingi tushunish noto'g'ri edi (+000 tugma qo'shildi). To'g'ri talab:
- Foydalanuvchi summa maydoniga **birinchi marta raqam yozsa** — oxiriga **avtomat 000 qo'shilsin**. Masalan "15" yozsa → "15 000" (avtomat), "150" → "150 000".
- **Keyin foydalanuvchi o'zi tahrirlаy olsin** — 000 ni o'chirsa, boshqa raqam qo'shsa, hammasi mumkin. Majburlама yo'q.
- Ya'ni: 000 — aqlли DEFAULT, majburiy emas. Odam 15 yozadi, avtomat 15 000 bo'ladi, lekin xohlаsa 15 500 yoki 15 ga o'zgartira oladi.

Mexanizm (senior UX — o'zing eng tabiiy variantni tanla):
- Variant A: maydonга birinchi raqam kiritilганда, agar foydalanuvchi hali 000 qo'shмаган bo'lса, avtomat 3 ta 0 qo'shiladi, kursor 0'lardan OLDINGА qo'yiladi — odam qo'shимча raqам tersа 0'lар surилади, xohlаsа 0'larни o'chиради.
- Variant B: maydondan chiqganда (blur) yoки yozишни to'xtатганда — agar raqam kiritилган-u 000 bilan tugамаsа, avtomat ×1000 (15 → 15000). Lekin foydalanuvchi qайta kириб tahrirlаsa — tegilmaydi.
- Eng tabiiysи A (yozаётганда darrov ko'rinadi). Lekin 500 so'м kabi kichик summа yozмоqчи odam 0'larни o'chira olсин — buни oson qил.

- **500 so'm holati**: odam 000 ни o'chиriб 500 yozа olсин — bloklama. Bu majburiy emas, shuning uchun har doim tahrirlanadi.
- Saqlаганда haqiqий raqам (bo'sh joysиz) ketsин; ko'риniш minglик ajratгич bilan.
- Oldин qo'shилган **+000 TUGMASINI OLIB TASHLA** — u kerak emas edi. Uning o'rniga avtomat mexanizm.
- Hamma summa inputга (professional oddiy+kengaytirilган, hodim, konvert "sotib olish", transfer, standart limit, yuk bog'lash) — izchil. Konvert "sotish" (kasrli valyuta) va tor dinamik satrlar — oldingidek istisno (u yerда avtomat 000 ma'nosiz).

Sinov: professional summа maydonига "15" yoz → "15 000" avtomat. Keyin "5" qo'sh → "15 0005" emas, mantiqан to'g'ри (15 500 yoki foydalanuvchi tahrири). 000 ni o'chir → "15" qoladi (500 so'm holати ishlaydi).

## 2. Barcha -dev fayllarni prodga chiqarish (promote)
Wipe'дан oldин hamma tayyor ish prodga chiqsin.
- `promote.sh` ni ishga tushir (dev→prod ko'chiradi): har `X-dev.html` → `X.html` ga, ичидаги `-dev.html` havolalar `.html` ga qайtarilади.
- CC oldин aytган: promote.sh'да `standart` va `yuklar` yo'q edi, tuzатилди (15 prod fayl). Buni tasdiqla.
- Promote'дан keyин tekshir: har prod fayl (kassa, jurnal, professional, hodim, hisobot, balans, cashflow, qarzdor, filial, valyuta, konvert, sozlama, provodka, yuklar, standart) — ичida `-dev.html` havola QOLMAganини, va dev'даги barcha yangилик (summа 000, filial breakdown, V7/V8 ishlar) prodда borлигини.
- ⚠️ Prod fayllar mijozlар ishlатади — promote'дан keyин bir marta har prod sahifани ochиб, yiqилмаsлигини ko'р (yoки CC quruq sinov: node --check, havola tekshiruvи).

## Tartib
1 (summа avtomат 000 — tugma olib tashlа) → 2 (promote dev→prod). Push men qиламan. Keyин Asilbek wipe RUN qиладi (Provodka project'да!).

Qoidalar: `{error}`; boot() oxirida; node --check; Aros ranglар; summа saqlаганда haqiqий raqам.
