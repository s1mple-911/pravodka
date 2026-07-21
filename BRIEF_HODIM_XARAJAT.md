# PROVODKA hodim.html — mobil xarajat yozish (yangi sahifa)

Maqsad: oddiy hodim telefonda o'z xarajatini tez, chiroyli yozadi. FAQAT xarajat (pul chiqadi). Professional/jurnal/hisobot yo'q — bitta oson ekran. Bu Provodka'ning YANGI 13-sahifasi (hodim.html), mavjud auth (login/parol) bilan.

Qat'iy: node --check; boot() modul oxirida; mavjud auth/supabase klientini qayta ishlat (boshqa sahifalardagidek); server guard (entry_line trigger) avtomat ishlaydi — insert yo'lini o'zgartirma.

## Kirish / Auth
- Mavjud Provodka login (email yoki login + parol) — boshqa sahifalar qanday kirsa shunday. Alohida auth qurma.
- Kirgach: `my_perms()` yuklanadi (PERMS). Hodim odatda cheklangan user (op_kassa_ids = o'z xarajat kassa(lar)i).

## Kassa tanlash
- Hodimga biriktirilgan AMALIYOT kassalari (`op_kassa_ids`; scope='all' bo'lsa hamma xarajat kassalari — lekin hodim odatda 'list') chip/karta ko'rinishida.
- Bitta bo'lsa — default tanlangan (selected), o'zgartirishga hojat yo'q.
- Bir nechta bo'lsa — bosib tanlaydi. 5400 guruh chiqmaydi.
- Hech biri yo'q → "Sizga kassa biriktirilmagan, administratorga murojaat qiling".

## Forma (mobil-first, juda sodda)
Tepada: kassa nomi + qoldig'i (ixtiyoriy, agar oson bo'lsa — "Sizda: 1 200 000 so'm").
Keyin:
1. **Summa** — katta, asosiy input (raqam klaviatura, avtomatik fokus). Minglik ajratib ko'rsat (1 000 000).
2. **Modda** — FAQAT xarajat moddalari (type='xarajat' + aktiv/boshqa kapital xarajatlar; daromad KO'RSATILMAYDI). Katta bosiladigan tugmalar/ro'yxat (dropdown emas — mobil uchun chip yoki katta list). Eng ko'p ishlatiladigan (masalan 9412 Ish haqi, 9411 Ijara, 9414 Transport, 9416 Aloqa, 9419 Boshqa) tepada.
3. **Izoh** — ixtiyoriy, bitta qator.
4. **Saqlash** — katta yashil tugma, pastda sticky (barmoq yetadigan joyda).

## Yozuv (avtomatik)
- Har doim pul chiqadi: **Dt = tanlangan xarajat modda / Kt = hodim kassasi**.
- Insert: entry + 2 entry_line (source='manual', status='posted', created_by=hodim ismi), professional.html'dagi oddiy rejim mantig'ini QAYTA ISHLAT — faqat UI mobil.
- Xatoda odam tilida toast (42501 → "Bu kassaga yozish huquqingiz yo'q").

## UX / dizayn (muhim — chiroyli bo'lsin)
- Mobil-first: to'liq ekran, katta shriftlar, barmoq uchun katta tugmalar (min 44px).
- Saqlashдан keyin: yashil ✓ animatsiya + "Saqlandi" toast + forma tozalanadi (summa 0, modda tanlanmagan), kassa tanlovi qoladi → ketma-ket yozish oson.
- Pastда (ixtiyoriy, oson bo'lsa): "Bugungi xarajatlarim" — shu hodim bugun yozgan oxirgi 5-10 yozuv (modda + summa + vaqt), o'chirish tugmasisiz (faqat ko'rish). Bu ishonch beradi. Server: entry_line'дан o'z kassаси bo'yicha bugungi. Agar RLS ruxsat bermаса — keyinга qoldir, izoh yoz.
- Dark/light — mavjud tema o'zgaruvchиларини ishlat.
- Telegram WebApp: agar Telegram ichida ochilса `tg.expand()` (boshqа sahifаларdagidek), lekin auth login/parol.

## Nav
- Bu sahifа oddiy hodimга — 12 sahifали sidebar KERAK EMAS. Minimal: faqat sarlavha + (kerak bo'lsa) chiqish tugmаси. Hodim boshqа sahifаларni ko'rmайди (allowed_pages cheklovi baribir ishlайди, lekin bu sahifада umuman menu ko'rsатма).
- allowed_pages'ga 'hodim' kalitini qo'shish kerakми — agar perm tизими sahifани shu bo'yicha to'сса, admin-dev'да ham 'hodim' checkbox kerak bo'lади. Hozирча: agar hodim.html'ни perms bilan to'смаса ham bo'лади (login bo'lgan har kим kirадi, lekin faqat o'z kassаси ko'ринади). Sen hал qил va izoh qoldир.

## Sinov
- Hodim login → o'z kassаси (bitta bo'lsa default) → summa 50000 → modda "Transport" → Saqlash → jurnalда Dt=9414, Kt=hodim_kassa; toast ✓.
- Ruxsatsiz kassа umuman ko'ринмайди; DevTools orqали boshqа kassа yuborilса server rad (42501).
- Mobil ko'ринишда (DevTools responsive yoki haqiqий telefon) chиройли, tugmalar barmоққа qulай.

Har bosqич commit; push foydаlanuvchида. Oxирида: yangi fayl + sinov natijаси + (agar qo'shилган bo'lса) admin-dev'га 'hodim' sahifа kaliti haqида eslатма.
