# Bog'lanmagan (yo'ldagi) to'lovlar v2 — xizmat turi + ko'p tanlab bog'lash (2026-09-08, Asilbek)

Asilbek: «hujjat yaratilmagan yuk uchun bog'lanmagan to'lov yozish bor edi; endi "Tovar tannarxi" deb yozganda bog'lanmagan
tanlansa tovar tannarxiga qo'shiladigan xizmatlarni ham (yo'l puli, bojxona — Tannarx qo'shishdagidek) tanlash imkoni kerak;
u Bog'lanmagan ro'yxatiga status va izoh bilan tushadi; u yerdan bir nechtasini tanlab bittada qaysidir hujjatga bog'lash;
bog'langach shu pullar to'landi bo'ladi, hujjat narxi ko'p bo'lsa — qisman».

Mavjud oqim (Explore 2026-09-08): `professional-dev.html` 9110 → `openYukSave` → «Hujjat hali yo'q» ekrani (`yukPendScreen`,
faqat simple rejim, izoh majburiy) → `doSavePending` → Dt **9110-1** / Kt kassa, `entry.yuk_kutilmoqda=true`, `entry_yuk` yo'q.
`yuklar-dev.html` «Bog'lanmagan» tabi → `yuk_kutayotgan()` (PROVODKA_V7.sql 264) → «Yukka bog'lash» (`#linkModal`, BITTA
to'lov → BITTA yuk, summa ≤ entry va ≤ yuk qoldig'i) → `yuk_boglash(p_entry, p_yuk_id, p_summa)` (V7 170): `entry_yuk` upsert,
9110-1 → 9110, `yuk_kutilmoqda=false`, `yuk_ids` += id, `entry_history`. To'langan = `yuk_tolangan_summa` (`entry_yuk` Σ),
jami tannarx = Aros narx + Σ `yuk_tannarx` (sabablar `yuk_tannarx_sabab`: Yo'l puli 🚚, Valyuta farqi 💱, Bojxona 🛃,
Abusaxiy 📋, Boshqa ➕), qisman = 0<pct<100 (`paidCellHtml`).

## Qarorlar / taxminlar
1. **Xizmat turi = `yuk_tannarx_sabab`** (yangi jadval yo'q). `entry.yuk_sabab_id int null references yuk_tannarx_sabab(id)`
   (additive). null = tovar narxi (hujjat) uchun to'lov.
2. **Bog'langanda**: sabab null → faqat `entry_yuk` (to'landi). Sabab bor → `entry_yuk` **VA** `yuk_tannarx` qatori (sabab, summa,
   izoh, `kalit='entry:'+entry_id` — idempotent, `yuk_tannarx_qosh` ichki mantiqi bilan, bojxona limiti ham) — xizmat yuk
   tannarxini oshiradi va to'lov o'sha xizmatni yopadi. Qoldiq = jami − to'langan avtomat to'g'ri chiqadi. ⚠️ Asilbek tasdiqi
   kutilmoqda (aks holda sabab faqat belgi bo'lib qoladi, `yuk_tannarx` yozilmaydi — bitta bayroq bilan o'chiriladi).
3. **Ko'p tanlash**: har tanlangan to'lov TO'LIQ summasi bilan bitta yukka. Tovar to'lovlari Σ ≤ yuk qoldig'i (klient + server —
   server narxni bilmaydi, faqat `p_qoldiq_uzs` klientdan kelgan qiymat bilan tekshiradi, V7 izohi naqshi); xizmat to'lovlari
   qoldiqdan tashqari (o'zi tannarx qo'shadi). Bitta tranzaksiya — bittasi yiqilsa hammasi bekor.
4. Eski `yuk_boglash` (bitta, qisman summa) va `yuk_kutayotgan()` imzosi/tanasi TEGILMAYDI; yangi `yuk_kutayotgan_v2()` (jsonb,
   + sabab, ikonka, status, ext_ref) va `yuk_boglash_koplik(p_entries uuid[], p_yuk_id int, p_qoldiq_uzs numeric default null)`.
5. `provodka_yoz` TEGILMAYDI — sabab saqlashdan KEYIN `entry_yuk_sabab_yoz(p_ext_ref, p_sabab_id)` (`entry_jadval_yoz` naqshi:
   egalik `created_by`, 30 daqiqa, `yuk_kutilmoqda=true` bo'lsa, bir marta). RPC yo'q bazada → sabab jim tashlanadi, to'lov saqlanadi.
6. `hodim-dev` tegilmaydi (u yerda yuk modali yo'q — alohida masala). Jurnal ⏳ teg modali eskicha (bitta).

## Fayllar
- `PROVODKA_YUK_BOGLANMAGAN_V2.sql` — ustun, `entry_yuk_sabab_yoz`, `yuk_kutayotgan_v2`, `yuk_boglash_koplik`, DIAG.
- `professional-dev.html` — `yukPendScreen` da «Xizmat turi» select (sabablar `yuk_tannarx_sabab` faol, birinchi «Tovar narxi
  (hujjat)»), `doSavePending` dan keyin `entry_yuk_sabab_yoz`.
- `yuklar-dev.html` — Bog'lanmagan tab: ☐ har qator + hammasi, sabab chip (ikonka+nom), status («Kutilmoqda» + sana), izoh, kim;
  «Tanlanganlarni bog'lash (N · Σ)» → `#linkModal` ko'p rejimi (yuk tanlash, summa = Σ, tovar/xizmat ajratib ko'rsatiladi,
  qoldiq tekshiruvi faqat tovar qismi) → `yuk_boglash_koplik`; muvaffaqiyat → `loadPending` + `loadYuklar('fresh')`.
  Bitta qator «Yukka bog'lash» (qisman) eskicha qoladi.
