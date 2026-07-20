# PROVODKA — Hodim kassalari to'laqonli + Transfer qaytarish + Konvert ko'p-valyuta (v2)

## Mavjud tizim faktlari (o'qi, taxmin qilma)

- **Kirim/Chiqim (provodka.html)** = tezkor 2-qatorli kiritish: kirim/chiqim/**transfer**. U **nav'dan yashirilgan** (Jurnal o'rniga keldi), fayl joyida, to'g'ridan URL bilan ishlaydi. **Transfer mantiqi shu yerda bor** — qayta yozma, qayta ishlat.
- **Konvert oqimi**: `convert_start(p_from,p_to,p_amount,p_rate,p_note)` → koridor ichida bo'lsa `do_convert` darrov bajaradi (`{ok:true,status:'done'}`), tashqarida → `convert_request` pending (`{ok:false,status:'pending',request_id,aros_rate,lo,hi}`) → admin `convert_approve(p_id)` / `convert_reject(p_id,p_note)`. **Bu tasdiq oqimi saqlanadi.**
- **Koridor**: `aros_usd_rate()` (oddiy numeric) atrofida lo/hi server hisoblaydi. Tarixan **±2%**; foydalanuvchi **±5%** dedi — koridorni bitta konstanta/sozlamaga chiqar va **5%** qil (server tomonda; klient faqat sariq ogohlantiradi, bloklamaydi).
- **Kurslar**: `currency_rate(from_code,to_code,rate,rate_date,rate_at,source)` — allaqachon juftlik-umumiy. `v_current_rate` bor. USD kursi Aros'dan import qilinadi (valyuta.html → "Aros'dan"). Boshqa juftliklar uchun manba yo'q — qo'lda kiritiladi.
- **Valyuta juftlik naqshi**: parent UZS hisob + bola valyuta hisobi (`parent_id`). `v_kassa_toliq: id,code,name,currency,kassa_turi,parent_id,uzs,usd` — `uzs` dollar kassada ham so'm ekvivalenti (**tarixiy kursda**, joriy emas — qayta hisoblamaysan). `v_kassa_card`da endi `subtitle` ham bor.
- **QAT'IY QOIDA**: filial **asosiy** kassasida (kassa_turi='filial') konvert QILIB BO'LMAYDI — u Aros bilan sinxron. Transfer mumkin.
- **entry**: soft-delete (usti chizilgan + kim/qachon), `entry_history`, admin-only tahrir. `fc_rate`/`fc_amount` valyuta yozuvlari uchun.
- **Xavfsizlik qoidalari** (buzma): har yangi view → `security_invoker=on`; har yangi funksiya → `REVOKE ... FROM PUBLIC, anon` va faqat kerakli rolga GRANT; SECURITY DEFINER'da auth tekshiruvi.
- **Hodim kassalari**: 54xx, parent=5400 (`kassa_turi='xarajat_guruh'`), `subtitle`="Filial · Lavozim", `taskfix_user_id` — TaskFix EF avtomatik yaratadi (`upsert_hodim_kassa` — service_role only, TEGMA).
- `boot();` har modulning eng oxirida (CLAUDE.md).

---







## 0. Hodim kassalari hamma tanlagichda
hodim uchun ochilgan kassalar ham oddiy kassalardek bolsin professionlada ham hamma joyda chiqssin harajat sectionida , bu kassalarni ham standart kodlash kerak qolganlari keabi  , filiallar urtasida transfger qilguncha ham bu kassalar ham chqishi kerak boladi

## 1. Valyuta — umumiy (USD'ga qotib qolma)
Qoida: **qaysi valyutada bola-hisob bo'lsa — o'sha ko'rinadi**, yo'q valyuta ko'rinmaydi.
- `v_kassa_card`dagi USD-only JOIN o'rniga: parentning BARCHA valyuta bolalari. Tavsiya: yangi view `v_kassa_valyutalar(parent_id, account_id, currency, uzs, fc_qoldiq)` — karta shu ro'yxatdan har valyutaga qator chizadi (USD, CNY, ...). `usd`/`has_usd` ustunlari eski kod uchun qoladi (sindirma).
- **"Valyuta qo'shish"** (admin, kassa kartasida): tanlangan valyutada bola-hisob ochadi. Kod: USD=56xx naqshi band; yangi valyutalar uchun 57xx (CNY) va keyingilari — `create_valyuta_child(p_parent uuid, p_currency text)` RPC yoz (idempotent, kod ketma-ket, REVOKE anon).
- Hodim kassasiga ham xuddi shu tugma (bolasi hodim kassasining o'zi ostida).
- fc yozuvlar mavjud `fc_rate/fc_amount` bilan — mexanizmni o'zgartirma, valyuta hisobning `currency`sidan aniqlanadi.

## 2. Konvert — "Sotib olish" / "Sotish" + valyuta tanlash
konvert.html (yoki mavjud konvert modal) ikki rejim:
- **Sotib olish**: UZS kassa → shu kassaning X-valyuta bolasi (X tanlanadi: mavjud valyuta bolalari + "yangi valyuta qo'shish" → 4-band RPC)
- **Sotish**: X-valyuta bolasi → parent UZS kassa (teskari yo'nalish — `do_convert`/`convert_start`ni yo'nalish parametri bilan umumlashtir yoki `convert_start_v2(p_from,p_to,p_amount_uzs yoki p_fc,...)` — imzoni o'zing loyihala, eski chaqiruvlar sinmasin)
- Kurs koridori juftlikka bog'lansin: USD uchun `aros_usd_rate()`; boshqa juftlikda `v_current_rate`dagi oxirgi kurs asos, u ham bo'lmasa koridorsiz (server qaroriga — pending'ga tushirish ma'qul). Koridor ±5% (0-banddagi konstanta).
- Filial asosiy kassasi tanlagichlarda chiqmaydi (mavjud qoida).
- Tasdiq oqimi (pending/approve/reject) va konvert so'rovlari ro'yxati o'zgarishsiz ishlashda qolsin — faqat USD'ga qotib qolgan joylarini juftlik-umumiy qil.

## 3. Hisobotlar
balans/aylanma/cashflow/kassa jami: yangi valyutalar `uzs` (tarixiy so'm ekvivalenti) orqali jamiga kiradi — USD qanday bo'lsa shunday. Yiqilmasin, banner naqshi ishlashda qolsin.

## SQL
Hamma DB o'zgarish `PROVODKA_KASSA2.sql`ga (idempotent, xato→RAISE EXCEPTION, view'larga security_invoker, funksiyalarga REVOKE/GRANT). Foydalanuvchi qo'lda ishga tushiradi.

## Tartib
0 → 1 → 2 → 3  Har bosqich commit (push foydalanuvchida). Oxirida: fayllar ro'yxati + foydalanuvchi qadamlari + sinov senariylari (jumladan: hodim kassaga transfer → xarajat yozish → konvert sotib olish/sotish CNY bilan).
