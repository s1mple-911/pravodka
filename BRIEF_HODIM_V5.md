# PROVODKA hodim.html V5 — o'z tarixi + "Yangi tur" olib tashlash

Kontekst: hodim.html ishlayapti (chek, tez summa, oy jami, dropdown search, 500k+ alert). entry insert yo'li o'zgarmaydi; guard trigger mavjud; boot() modul oxirida; node --check; perms.

## 1. "➕ Yangi tur qo'shish" — hodim.html'dan OLIB TASHLA
- Hodim endi yangi xarajat turi qo'sha OLMAYDI — tartibsizlik oldini olish uchun.
- hodim.html'dagi "➕ Yangi tur qo'shish" tugmasi + modal + add_xarajat_turi chaqiruvi olib tashlansin (yoki yashirilsin).
- add_xarajat_turi RPC DB'da qolsin (o'chirma) — sozlama.html (admin) uni ishlatadi. Faqat hodim.html'dan UI olib tashlanadi.
- Xarajat turlarini FAQAT admin sozlama.html "Xarajat" tabида qo'shadi (bu allaqachon bor — tekshir, ishlaydimi).

## 1b. Tezkor summa tugmalari — hodim.html'dan OLIB TASHLA
- [10 000] [50 000] [100 000] [+100k] tugmalari kerak emas — olib tashlansin.
- Foydalanuvchi summani to'g'ridan klaviaturadan kiritadi. Summa input o'zi qoladi (raqam klaviatura, minglik ajratish) — faqat tez-tugma qatori olib tashlanadi.

## 2. Hodim o'z tarixini ko'rsin (oy / kategoriya)
Hozir faqat "Bugungi xarajatlarim". Kengaytir:
- **Davr tanlash**: Bugun / Bu hafta / Bu oy (yoki oy tanlagich). Sodda tugmalar (chip).
- **Ro'yxat**: tanlangan davrда o'z kassа(лар)идан chиққан xarajатлар — modда, summа, sana/vaqt, chek 📎 (bosса ochилади), izoh.
- **Kategoriya xulоsаси**: tanlangan davrда kategoriya bo'yича jamи — "Transport: 300k, Ovqат: 150k..." kamayиш tartибида, progress-bar bilan (hodim o'zи qаyerга ko'п sarflаganини ko'ради). CEO hisobот sahifаsidagi kategoriya komponentига o'xшаш, lekin FAQAT o'z kassаси.
- Manba: o'z kassаси (op_kassa_ids yoki scope). Yangи RPC yoki mavjud hodim_kategoriya_hisobot'ни kassа filtri bilan qayta ishlаt (lekin u admin-only — hodim uchun alohида yoki perms yumshаt). Tavsiya: `hodim_oz_tarix(p_from, p_to)` — auth.uid()нинг o'z kassалари bo'yича, har authenticated o'zиникini ko'ради (SECURITY DEFINER, o'z kassасини perms/op'дан aniqлайди). Kategoriya + ro'yxат qaytарsin.
- Bu hodим uchun eng foydали — o'z sarfини nazorат qилади.

## SQL (kerак bo'лса)
Hodim o'z tarixи uchun RPC → PROVODKA_HODIM_V5.sql (idempotent, security_invoker, REVOKE anon). O'z kassасини perm helper (perm_op_key yoki view_kassa)дан ol. Asilbek RUN qилади.

## Tartиб
1 (Yangi tur olib tashlash) + 1b (tezkor summa olib tashlash) → 2 (o'z tarixи). Commit har bosqич; push Asilbekда. Oxирида: fayllar + SQL + sinov (hodim davр almashtириб tarixини ko'ради; "Yangi tur" yo'q; admin sozlамада hali qo'shа oladi).
