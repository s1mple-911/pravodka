# PROVODKA balans — kassa va ombor bitta qatorda

## Nima kerak
Hozir balansda "Pul mablag'lari" ro'yxati alohida, "Tovarlar" ro'yxati alohida — bir filialning puli va tovari ekranning ikki joyida.

Kerak: **har filial bitta qatorda** — kassa summasi va o'sha filial omborining summasi yonma-yon.

Masalan:
```
FILIAL                        PUL            TOVAR          JAMI
Farg'ona                47 770 890     243 210 000    290 980 890
Karshi Bahor            98 540 899     362 456 710    460 997 609
```

## DB (tayyor)
`accounts.linked_kassa_id` ustuni qo'shildi — ombor qaysi kassaga juft ekanini ko'rsatadi (1:1).
```sql
select k.code, k.name, o.code as ombor_kod, o.name as ombor
from accounts k
left join accounts o on o.section='tovar' and o.is_active and o.linked_kassa_id = k.id
where k.kassa_turi='filial' and k.is_active and k.currency='UZS';
```
Qoldiqlar mavjud view/hisob mantiqidan olinadi (v_hisob_bal yoki balans hozir nima ishlatsa — o'zgartirma, faqat ko'rsatishni qayta joylashtir).

## Ish
`balans-dev.html`da (dev fayl tuzilmasi bo'yicha):

1. **Filial jadvali** — har qatorda: filial nomi · kassa qoldig'i · ombor qoldig'i · jami. Kamayish tartibida (jami bo'yicha) yoki nom bo'yicha — o'zing tanla, izohla.
2. **Juftsiz elementlar alohida:**
   - Markaziy kassalar (5011 Toshkent, 5012 Qashqadaryo, 5110 Bank, 5510 Click/Payme) — ombori yo'q, alohida blok "Markaziy kassalar"
   - Juftsiz omborlar (2913 Qarshi Bahor aksessuar, 2925 Xitoy, 2943 Ko'kdala) — alohida blok "Boshqa omborlar"
   - Hodim xarajat kassalari (54xx) — alohida yoki mavjud joyida
   - Valyuta bola-hisoblari (56xx/57xx/58xx) — hozirgidek parent ostida
3. **Jamilar to'g'ri qolsin** — "Jami aktiv" o'zgarmasligi shart (25 463 553 782 kabi). Qayta joylashtirish faqat ko'rinish, hisob emas.
4. **Mobil**: keng jadval telefonda sig'maydi — mobilda har filial karta ko'rinishida (nom tepada, pul/tovar/jami ostida) yoki gorizontal scroll. Aros brend ranglari.
5. Nol qoldiqli filiallarni ko'rsatish/yashirish — kichik toggle ("Nollarni ko'rsatish"), default yashirin.

## Qoidalar
- Faqat `balans-dev.html` — prod faylga tegilmaydi.
- Hisob-kitob mantig'i o'zgarmaydi, faqat guruhlash/ko'rsatish.
- `boot()` modul oxirida; node --check; </script> soni saqlansin.
