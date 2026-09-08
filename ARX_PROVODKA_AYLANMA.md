# Sof aylanma kapital (Чистый оборотный капитал) — arxitektura (2026-09-08, TASDIQLANGAN, kod hali yo'q)

Savol: **«Butun biznesda hozir qancha pul bor?»** — har kuni **08:00** (Toshkent) bir marta hisoblanadi, tarixda
saqlanadi, grafikda «har kun qanday ketyapmiz» ko'rinadi. Yangi sahifa **`aylanma-dev.html`**, ruxsat kaliti
**`aylanma`**, nom «Sof aylanma kapital» (qisqa SAK). Pul harakati YO'Q — `entry`/`entry_line` ga tegilmaydi, faqat
REGISTR (`aros_qarzdor`/`aros_transfer_yolda` naqshi).

Asilbek qarorlari (2026-09-08): tovar/brak **tannarxda** (Metabase `average_price`) · transfer `created` **qo'shiladi**
(Aros yaratilganda qoldiqdan ayiradi) · ochiq buyurtma **sotuv narxida** · qarzlar **Qarz sahifasidagi raqamlar bilan
bir xil** · pul = faqat **pul kassalar + filial kassalar + yo'ldagi pul**, hodim xarajat kassalari KIRMAYDI · har kun
**alohida** snapshot + grafik · yo'ldagi pul — pastdagi 6.6 qarori.

## 1. Formula

```
SAK = [A] Pul: markaziy + filial kassalar (v_kassa_card, kassa_turi IN ('markaziy','filial'))
    + [B] Yo'ldagi pul (aros_transfer_yolda status='sent')                        — QO'SHILADI (6.6)
    + [1] Tovar omborlarda, tannarx (Metabase «Oxirgi summa», is_broken=false)
    + [5] Brak omborlardagi tovar, tannarx (Metabase, is_broken=true)
    + [3a] Yo'ldagi yuklar (product-incomes status='posted' AND delivery_status='on_way')
    + [3b] Ko'chirish yo'lda (v2/transfers status='on_way')
    + [4] Ko'chirish yaratilgan (v2/transfers status='created')
    + [6] Ochiq buyurtmalar, SOTUV narxida (orders status ∈ created/send/sent)
    + [2a] Bizdan qarzdor = qarz_umumiy_dash() (Provodka qarz + Aros mijozlar)
    − [2b] Biz qarzdormiz = Qarz sahifasi «Biz qarzdor»: Σ yuk (narx × kurs − to'langan), 365 kun
```

Har bo'lim **so'm + dollar** saqlanadi, asosiy ko'rinish so'mda. Kurs snapshot paytida `aros_usd_rate()`
(null → `conv_baza_kurs('USD')`) muhrlanadi — keyin kurs o'zgarsa tarix o'zgarmaydi. Boshqa valyuta (CHY…) —
`yuk_kurslar` (Qarz sahifasi bilan bir xil).

## 2. Manbalar — «Aros'ga takror so'rov yo'q» qoidasi bilan (kuniga ≈8 Aros so'rov)

| # | Bo'lim | Manba | So'rov/kun | Izoh |
|---|--------|-------|-----------|------|
| 1, 5 | Tovar + brak | **Metabase public card `4f729857-…`** («materialreport total», id 62). Tekshirildi (2026-09-08): `"Oxirgi summa" = ending qty × back_office_productincomeitem.average_price` — **kirim (tannarx) narxi, USD**, sotuv narxi EMAS. Param `warehouse_filter` (id, massiv qabul qiladi), `start_date`/`end_date`. Natija **ombor nomi bo'yicha** qatorlar → hamma omborni BITTA so'rovda olsa bo'ladi. | Metabase 1–2, Aros 1 (`products/warehouses/?page_size=500` — `is_broken`, `broken_warehouse`, `parent_warehouse`, `is_active`) | Cache Builder faqat plan-filiallarni oladi; bizga hamma ombor. Karta qatori `name_uz` bilan keladi → ro'yxat bilan nom orqali juftlanadi (id bo'lmagani uchun 0-bosqichda nom dublikati tekshiriladi; bo'lsa har ombor alohida so'rov). Kartada «Transfer yolda summa» ham bor — [3b] bilan solishtirish uchun saqlanadi, jamiga QO'SHILMAYDI. Zaxira: Metabase yiqilsa `cache_filial.ombor_summa_usd` (plan-filiallar) + `manba='cache'` bayrog'i. |
| 3a, 2b | Yo'ldagi yuklar + Biz qarzdormiz | Aros **`v3/product-incomes/?date_from=<−365 kun>&date_to=bugun&page_size=500`** (Qarz sahifasi `aros-provodka-yuklar` bilan bir xil ro'yxat) | 2–3 (sahifalar) | [2b] = Qarz sahifasi formulasi AYNAN: `status='posted'`, `narx × yuk_kurslar(valyuta) − yuk_tolangan_summa(id)`, `max(0, …)`, kurs yo'q → qator `kurs_yoq` bayrog'i bilan (0 deb sanalmaydi, banner). [3a] = shu ro'yxatdan `delivery_status='on_way'` → `narx × kurs` (+ `aros_yuk_bojxona.bojxona_uzs` bo'lsa). Bojxona Sync oynasi tegilmaydi. |
| 3b, 4 | Ko'chirish | Aros **`/api/admin/v2/transfers?status=on_way`** va **`status=created`**, `page_size=1000`, `ordering=-id`, **`warehouse`siz** (global) → `document_price`, `from_warehouse{id}`, `to_warehouse{id}`, `created_datetime`, `sent_at` | 2 | `document_price` valyutasi — 0-bosqichda tasdiq (dashboard so'mda chizadi). Brak omborga ketayotgan transfer alohida satr (`to.is_broken`). |
| 6 | Ochiq buyurtmalar | Aros **`/api/admin/orders/?status=<s>&created_datetime_after=<−90 kun>&page_size=1000`**, s ∈ created, send (Cache Builder `Get Sent` naqshi) | 2–3 | `total_amount` — sotuv narxi (qaror). `received` (mijoz oldi, hali to'lamagan) OLINMAYDI — u `aros_qarzdor.total_debt` da, [2a] bilan ikki marta bo'lardi. |
| 2a | Bizdan qarzdor | Provodka **`qarz_umumiy_dash()`** (mavjud RPC: Provodka `qarz` faol qoldig'i + `aros_qarzdor` Σ `total_debt`) + 4010 daftar qoldig'i (`v_hisob_qoldiq`) alohida satr | 0 | Qarz sahifasi strip'i bilan bir xil raqam. |
| A | Pul | `v_kassa_card`: `kassa_turi IN ('markaziy','filial')`, Σ `jami` (parent + valyuta bolalari) | 0 | `xarajat`/`xarajat_guruh` (5400, 5401+) KIRMAYDI (qaror). Filial kassa Provodka'da Aros balansiga har 30 daq tenglashtiriladi (`sync_filial_balans`). |
| B | Yo'ldagi pul | `aros_transfer_yolda` `status='sent'`: `s_cash+s_click+s_payme` + `s_usd × kurs` | 0 | 6.6 ga qara. |

Metabase Aros API rate-limitiga kirmaydi. Aros so'rovlari: warehouses 1 + product-incomes 2–3 + transfers 2 + orders 2–3.

## 3. Snapshot oqimi — n8n «Aros Provodka - Aylanma Snapshot» (yangi kichik workflow)

Cron **`0 3 * * *` UTC = 08:00 Toshkent** (n8n server UTC). Qadamlar (hammasi `neverError`, har manba alohida
`ok|xato`):
1. `products/warehouses/` → ombor ro'yxati.
2. Metabase karta (hamma id, `end_date=bugun`, `start_date=−30 kun`) → ombor nomi → `{usd, soni}`.
3. `product-incomes` 365 kun → yuklar (id, narx, valyuta, status, delivery_status, ombor).
4. `v2/transfers` on_way + created; `orders` created + send.
5. `POST rpc/sync_aylanma_snapshot` (**service_role**, Supabase API krediti — Asilbek ulaydi):
   `{sana, rejim:'cron'|'qolda', kurs_usd?, omborlar:[…], yuklar:[…], transferlar:[…], buyurtmalar:[…], manba_holati:{…}}`.
   Provodka qismini (A, B, 2a, 2b to'lovlar/kurslar) **RPC o'zi** hisoblaydi.
6. Xato → Telegram adminlarga (Qarz Notify naqshi): «Aylanma snapshot 08:00: <manba> yiqildi».

Qo'lda: admin «Hozir hisoblash» → webhook `aros-provodka-aylanma-run?uid=` (Perms API naqshida `my_perms` admin
tekshiruvi) → `rejim='qolda'`. **08:00 qatori o'zgarmaydi** — qo'lda hisob ALOHIDA qator (`id` PK, `sana`, `rejim`,
`hisoblangan_at`); grafik va «kechaga nisbatan» faqat `cron` qatorlarini oladi; cron qatorini qayta yozish faqat
o'sha kun cron bo'lmagan bo'lsa (`unique (sana) where rejim='cron'`).

## 4. SQL — `PROVODKA_AYLANMA.sql` (ADDITIVE, Asilbek RUN qiladi)

```
aylanma_snapshot  id uuid PK · sana date · rejim ('cron'|'qolda') · hisoblangan_at · kurs_usd
                  jami_uzs · jami_usd · toliq boolean (hamma manba ok)
                  bolimlar jsonb {A,B,T1,T5,Y3a,K3b,K4,B6,Q2a,Q2b : {uzs,usd,soni}}
                  manba_holati jsonb {warehouses,metabase,incomes,transfers,orders,provodka : 'ok'|'xato'|'cache'}
                  xatolar text[]
                  unique index (sana) where rejim='cron'
aylanma_qator     snapshot_id → aylanma_snapshot · bolim · ref text · nom · usd · uzs · soni · meta jsonb
                  ref = warehouse_id / yuk_id / transfer_id / order_id / hisob kodi
```
- `sync_aylanma_snapshot(p_data jsonb)` — service_role ONLY (`sync_aros_qarzdor` naqshi). Manba `xato` → o'sha bo'lim
  **null** (0 EMAS), `toliq=false`, jami baribir hisoblanadi (null = 0 deb) lekin UI «to'liq emas» banner.
- `aylanma_kun(p_sana date default null)` → snapshot + qatorlar + oldingi cron kun bilan farq;
  `aylanma_trend(p_from, p_to)` → kunlik jami + bo'limlar (grafik, faqat cron);
  `aylanma_qatorlar(p_id, p_bolim)` → drill-down.
- Ruxsat `aylanma_page_ok()` = admin OR `perm_has_page('aylanma')` (pg_proc, fail-closed); RLS select shu, yozish
  policy yo'q. Kassa doirasi bu sahifada QO'LLANMAYDI (butun kompaniya raqami) — sahifa faqat rahbariyatga beriladi.
- `perm_pages()` **20-kalit `aylanma`** = `perms-dev.js` PAGES = `index-dev.html` CARDS = `promote.sh` PAGES;
  admin-dev `PVS_PAGES` `{key:'aylanma', label:'Sof aylanma kapital'}` — Asilbek (TaskFix repo).

## 5. UI — `aylanma-dev.html` (designer)

- Sarlavha: katta raqam **SAK so'mda** (ostida $ va kurs), sana ‹ › (kalendar), «kechaga nisbatan ±X (±Y%)»,
  «08:00 · cron» / «14:32 · qo'lda» belgisi, `toliq=false` → sariq banner (qaysi manba).
- **Zinapoya (waterfall)**: A → B → 1 → 5 → 3a → 3b → 4 → 6 → 2a → −2b → SAK. Qator bosilsa drill-down (ombor / yuk /
  transfer / buyurtma / qarzdor) + Excel (lazy xlsx).
- **Grafik**: 30/90/365 kun inline SVG (ai-dev chart naqshi, Chart.js yo'q) — SAK chizig'i + bo'limlar stacked,
  tooltip kun. Mobil: kartalar.
- Admin: «Hozir hisoblash». Nav: 15+ dev faylda sidebar (Ehson'dan keyin) + sheet + prefetch.

## 6. Ikki marta sanash — qarorlar

1. **Transfer `created`** — Aros yaratilganda qoldiqdan ayiradi (Asilbek) → Metabase qoldiqda yo'q → [4] qo'shiladi ✅.
2. **Transfer `on_way`** — Metabase kartada `Transfer yolda summa` qabul qiluvchi omborga alohida ustun, «Oxirgi
   summa» ichida EMAS (SQL tekshirildi: `ending_stock` faqat `productquantityhistory`) → [3b] qo'shiladi ✅.
3. **Ochiq buyurtma** `created` — tovar hali omborda (qoldiqdan `reason='order'` ayrilganmi — 0-bosqichda tekshiriladi;
   ayrilsa qo'shiladi, ayrilmasa faqat ko'rsatiladi). `send` — omborda yo'q, mijoz qarzi hali yo'q → qo'shiladi.
   `received` — `aros_qarzdor` da → OLINMAYDI.
4. **Yo'ldagi yuk** `on_way` — Metabase `income_sum` faqat `post_at` bo'yicha, lekin `ending_stock` qty tarixi qabul
   qilinmagan yukni ko'rmaydi → [3a] qo'shiladi ✅. `posted` + `accepted` yuk omborda → [1] ichida, [3a] ga kirmaydi.
5. **6010 daftar** — [2b] uchun ISHLATILMAYDI (Tovar Sync unga soxta qarz yozadi); Qarz sahifasi formulasi (yuk
   hujjatlari − to'lov) ishlatiladi. 4010/6010 daftar raqamlari drill-down'da ma'lumot sifatida.
6. **Yo'ldagi pul [B] — QO'SHILADI.** Tekshirildi: faol Balans Sync (`sync_filial_balans`, 5TB7ekGcBlU5qVZ0) filial
   kassasini Aros balansiga har 30 daq **tenglashtiradi** (kamayish ham yoziladi: Dt 9010 / Kt filial), markaziy kassaga
   esa Transfer Sync v2 faqat `received` da yozadi → `sent` va `received` orasida pul Provodka'da HECH QAYSI kassada
   yo'q. Demak [A] + [B] ikki marta emas. (Eski Auto Sync 7MSHrXnz9cGAFBTh «kamayish e'tiborsiz» — NOFAOL.)
   Nazorat: snapshot `manba_holati.provodka` ga oxirgi `sync_filial_balans` vaqtini yozadi — 2 soatdan eski bo'lsa banner.
7. **Tovar Sync** Provodka `section='tovar'` hisoblariga ham ombor qiymati yozadi — SAK Metabase'dan to'g'ridan oladi,
   Provodka tovar hisoblarini ISHLATMAYDI (soatlik, faqat plan-filiallar). Balans sahifasi bilan farq normal.

## 7. Bosqichlar

0. **Sinov ✅ (2026-09-08, `Yuk Detail API` proxy `?path=` + Metabase public API bilan, haqiqiy javoblar):**
   - `products/warehouses/?module=warehouse&page_size=500` → **68** ombor (33 oddiy + 35 brak) bitta so'rovda, `is_broken`
     va `broken_warehouse{id}` maydonlari (brak = `broken_warehouse`, Cache Builder'dagi «id+1» taxmini kerak emas).
     ⚠️ «Xitoy» (31) va «Brak Xitoy» (32) ikkalasi `is_broken=true` — Aros shunday belgilagan; snapshot'da T5 ga tushadi.
   - Metabase karta **hamma 68 id bitta so'rovda, 12 s, 64 qator** (4 ombor tarixsiz → `usd=null`), nomlari unikal, brak
     omborlar qatori bor (18 tasida qiymat). Jami ≈ **$2.31 mln**. «Oxirgi summa» = `ending qty × average_price`
     (`back_office_productincomeitem`) — kirim narxi = TANNARX. «Transfer yolda summa» so'mda, `transferitem.price` dan.
   - `v2/transfers?status=on_way|created` global ishlaydi: **222 + 60**. 🔴 `document_price` = `transfer_items[].price ×
     qty` (52565: 7000 × 5 = 35 000 so'm; shu buyurtma sotuv narxi 25 000) — bu TANNARX EMAS. v1 da `price_uzs` bilan
     saqlanadi, `tannarx_uzs` maydoni bo'sh; Asilbek Metabase'da transfer tannarx kartasini ochsa (SQL: `transferitem`
     × oxirgi `average_price`) n8n uni to'ldiradi, RPC `coalesce(tannarx_uzs, price_uzs)`. 🔴 **229/282 transfer buyurtma
     uchun tizim yasagan** (`comment` «… 463750 ID raqamli buyurtma …», detail `order`) → `order_id` ajratiladi, ochiq
     buyurtma bilan ikki marta sanalmaydi (B6 sotuv narxida, transfer `hisobga=false`).
   - `orders/?status=created|send` server filtri ishlaydi (100/100 mos), `total_price` sotuv narxi, `warehouse{id}`.
     Tarixda 131 315 buyurtma — 90 kunlik oyna shart.
   - `v3/product-incomes` 365 kun: **1230** hujjat (3 sahifa × 500), statuslar posted/created/canceled, `delivery_status`
     on_way faqat 2 ta (biri canceled). Valyutalar USD/UZS/CHY/AED.
1. SQL `PROVODKA_AYLANMA.sql` (coder) + n8n workflow `Aros Provodka - Aylanma Snapshot` (`N8N_AYLANMA_SNAPSHOT.js`,
   validate OK, 14 node; kreditsiz yaratildi) + tester.
2. `aylanma-dev.html` (coder → designer → tester), nav 15+ faylga, index CARDS, perms-dev PAGES, promote PAGES.
3. Telegram ogohlantirish + «Hozir hisoblash» webhook.
