# PROVODKA — sozlama filter + chek majburiyligi + hodim qulayliklar (chek/tez summa/oy jami)

Kontekst: hodim.html (mobil xarajat) + sozlama.html + jurnal ishlayapti. entry insert yo'li o'zgarmaydi; server guard trigger (perm + qoldiq) mavjud; boot() modul oxirida; node --check; perms hisobga olinadi. Xavfsizlik: yangi view security_invoker=on, funksiya REVOKE anon.

## 1. sozlama.html — tab ro'yxatni filtrlasin
Hozir tab (Kassa/Xarajat/Daromad) faqat qo'shish formasini almashtiradi, ro'yxatni emas.
- **Kassa** tab → ro'yxatда faqat section='pul' (kassalar), 5400 guruh chiqmaydi. Sarlavha "KASSALAR".
- **Xarajat** tab → faqat type='xarajat' moddalar. Sarlavha "XARAJATLAR". (add_xarajat_turi bilan qo'shilganlar ham shu yerda ko'rinsin — tahrir/toggle bilan, admin nazorati.)
- **Daromad** tab → faqat type='daromad'. Sarlavha "DAROMADLAR".
- Tahrir (✏️) va toggle (aktiv/nofaol) har turda ishlashda qolsin.

## 2. Xarajat turiga "chek majburiy" checkbox (sozlama.html + DB)
- accounts jadvaliga ustun: `chek_majburiy BOOLEAN NOT NULL DEFAULT false` (faqat xarajat moddalari uchun ma'noli, lekin ustun umumiy).
- sozlama.html "Xarajat" ro'yxatида har modда yonида checkbox "Chek majburiy" — bosilса darrov saqlanadi (kichик RPC yoki update). RPC: `set_chek_majburiy(p_account uuid, p_majburiy boolean)` — SECURITY DEFINER, admin only (sozlamani admin boshqaradi), REVOKE anon.
- add_xarajat_turi ham chek_majburiy default false bilan yaratsin.

## 3. hodim.html — chek rasmi biriktirish
- Chek saqlash: Provodka Supabase Storage, PRIVATE bucket `xarajat-cheklari`. Yo'l: `{kassa_id}/{entry_id}.jpg`. Signed URL bilan ko'rinadi.
  - Bucket + RLS SQL: yozish authenticated (o'z kassа yo'liga), o'qish authenticated (yoki admin). employee-photos naqshini (TaskFix) qayta ishlat — Asilbek shu naqshni biladi.
- Forma: modда tanlangач, agar o'ша moddaning chek_majburiy=true bo'lса — "📷 Chek surati" MAJBURIY (rasmsiz Saqlash disabled + "Bu xarajat uchun chek shart"). false bo'лса — ixtiyoriy ("📷 Chek (ixtiyoriy)").
- Rasm: telefon kamerаси (`<input type=file accept=image/* capture=environment>`). Canvas bilan siqиш (~1200px, JPEG 0.8). Preview ko'rsат, o'chиriш imkoni.
- Saqlаш tartиби: entry+entry_line yozилгач (entry_id olингач) → rasmни `{kassa_id}/{entry_id}.jpg` ga upload. Upload xato bo'лса — yozув qолсин, lekin toast ogohlantирsin ("Xarajat saqlandi, lekin chek yuklanmadi").
  - ext_ref yoki entry.description'га chek borлигини belgилаб qo'й (yoki alohида jadval xarajat_chek(entry_id, path) — o'zинг hал qил, oддийrog'и: entry_id = fayl nomi, borлигини storage'дан tekshир).
- Jurnalда/hodim "Bugungi"да chek borлар 📎 belgи bilan; bosилса signed URL ochилади.

## 4. hodim.html — tez summa tugmалари
- Summа input tepаси/pastида: [10 000] [50 000] [100 000] [+100k] tugmалар. Bosилса summаga qo'shади yoki o'rnатади (tavsiya: o'rnатади, "+100k" qo'shади). Mobил uchun katta tugmалар.

## 5. hodim.html — bu oy jami sarflangan
- Tepада (kassа qoldig'и yonида yoki ostида): "Bu oy: X so'm sarflandingiz" — shu hodim kassаси(лар)идан joriy oyда chиққан jamи (Kt yig'indи, type='xarajat').
- Manba: entry_line + entry (joriy oy, o'z kassаси). View yoki to'g'ридан so'rov. Xarajат saqlangач yangилansin.

## SQL
Yangи: chek_majburiy ustun, set_chek_majburiy() RPC, xarajat-cheklari bucket + RLS, (kerак bo'лса) oy-jamи view. → PROVODKA_HODIM_V3.sql (idempotent, RAISE xatода, security_invoker, REVOKE anon). Asilbek RUN qilади.

## Tartиб
1 (sozlama filter — mustaqил, tez) → 2 (chek checkbox) → 3 (chek rasm) → 4 (tez summа) → 5 (oy jamи). Har bosqич commit; push Asilbekда. Oxирида: fayllar + SQL + storage bucket qadamи + sinov.
