# PROVODKA — Jurnal V2 (davr filter + dashboard + xarajat kontrol)

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first (-dev.html → promote.sh). 🔴 Eski buzilmasin. UI/UX Apple. SQL additive. Push Asilbek. Prod: tasdiqlagach. Pul bilan — 🔴 fail-closed, permission.

## 1. Jurnal — davr (kalendar) filter (Aros uslubi)
Aros Market mahsulot tarixi kabi: hamma narsa TANLANGAN DAVR bilan ishlaydi.
- Jurnal tepasида DAVR tanlash (kalendar — sana oralig'i: dan-gacha).
- Davr tanlanса → pastdagi HAMMA jurnal o'sha davr bo'yicha filterlanadi.
- 🔴 Davr TANLANMASA → default BUGUNGI kun chiqib tursin.
- Pul bilan (summa, kirim/chiqim) — davr bo'yicha.
- (Aros uslubi: boshlang'ich → davr harakati → oxirgi. CC mos qilsin, lekin asosiy: davr filter.)

## 2. Jurnalда dashboard (xarajat breakdown + filter)
- Jurnal sahifasида dashboard (hodim.html dagi kabi, o'ng tarafда yoki tepада).
- **Bugun / Bu hafta / Bu oy** — bu ham KALENDAR (davr) bilan ishlasin.
- 🔴 Xarajat breakdown: "nimaga qancha rasxod ketgan" (xarajat turi bo'yicha — masalan ijara, oylik, tovar...).
- Bosilганда → o'sha xarajat turи bo'yicha pastdagi jurnal (provodkalar) FILTERLANSIN.
- CC eng mos dashboard qilsin (xarajat turi breakdown + bosilsa filter + davr).
- Chart (pie/bar — xarajat ulushi) foydali.

## 3. Jurnalда xarajat turi filter
- Jurnal xarajat turi (kategoriya) bo'yicha filter.
- Dropdown yoki chip — xarajat turini tanlab, o'shanи ko'rsatsin.

## 4. Har filterda SEARCH
- Har filter (xarajat turi, hodim, filial...) da qidiruv qo'sh.
- Ko'p variant bo'lsa — search bilan tez topish.

## 5. Sozlamalar → xarajatlar: filial qo'shish
- Hozir sozlamalар xarajatlarда: sana, izoh, check, inbox bор.
- 🔴 Bu yerga FILIAL ham qo'sh (xarajat qaysi filial uchun).
- Filial — mavjud filial ro'yxatidan (Provodka kassa/filial tizimi).

## 6. Xarajat yozmaslik muammosi — CC TAKLIF BERSIN 🔴
Muammo: hodimlar xarajat YOZMAYAPTI (pulni ishlatib yuboryapti), bugalter ham krim qilib tashlayapti. Tizim tarafdan nazorat kerak.
- 🔴 CC bir necha VARIANT taklif qilsin (Asilbek tanlaydi):
  - Variant misollar (CC kengaytirsin):
    - **Majburiy yozuv**: pul chiqim (kassadan) → xarajat izohi majburiy (izohsiz chiqim bo'lmasin).
    - **Balans nomuvofiqlik**: kassa balansi kamaysa-yu xarajat yozilmasa → ogohlantirish/flag.
    - **Kunlik hisobot**: har hodim/kassa uchun "yozilmagan xarajat" hisoboti (bugalter ko'radi).
    - **Limit**: xarajat yozilmasa — keyingi amal bloklanadi yoki ogohlantiradi.
    - **Taqqoslash**: kirim (bugalter) vs xarajat (hodim) — farq bo'lsa flag.
- CC har variantning ijobiy/salbiy tomonini yozsin, Asilbek tanlaydi.
- ⚠️ Bu MUHIM — pul nazorati. CC o'ylab, aniq variantlar bersin (buxgalteriya mantiqiga mos).

## DB (additive)
- Davr filter: mavjud entry/entry_line sanasidan (kalendar).
- Dashboard breakdown: xarajat turi (hisob) bo'yicha SUM.
- Filial: xarajat/entry'ga filial bog'lash (agar yo'q bo'lsa).
- Xarajat kontrol (6): CC variantiga qarab (flag, majburiy, hisobot).
- CC eng toza sxema. RLS, permission (pul — fail-closed).

## Fable oqimi
coder (davr filter, dashboard breakdown, xarajat turi filter, search, filial, xarajat kontrol variant), designer (jurnal Aros uslubi, dashboard — Apple, chart), tester (🔴 davr filter to'g'ri, dashboard permission sizmaydi, filial, pul fail-closed). 🔴 Eski jurnal buzilmasin. Dev-first (-dev.html). SQL additive (men RUN). Push men. Prod: men tasdiqlagach.
⚠️ 6-band: CC AVVAL variantlar taklif qilsin (kod yozmasdan) → Asilbek tanlaydi → keyin quradi.

## Tartib
1. Davr filter (Aros uslubi) — asosiy.
2. Dashboard (breakdown + filter + davr).
3. Xarajat turi filter + search.
4. Filial (sozlamalar).
5. 🔴 Xarajat kontrol — CC variantlar → Asilbek tanlaydi → quradi.
