# Aros qarzdorlar (mijoz qarzlari) — «Bizdan qarzdor» bo'limiga Aros manbasi (2026-09-07)

Asilbek talabi: `qarzdor-dev.html` → «Bizdan qarzdor» segmentida **qo'lda berilgan qarzlar** (mavjud `qarz` tizimi)
bilan birga **Aros'dan keladigan mijoz qarzlari** ham tursin: jami qarz, muddati o'tgani, kunlar bo'yicha, filial,
hamyon holati — «barcha ma'lumot». API'larni Fable tahlil qildi (n8n proxy orqali HAQIQIY javoblardan).

## 1. Aros API tahlili (2026-09-07, real javoblar)

Hammasi `https://api.aros.uz/api/admin/…`, Basic Auth (kredit faqat n8n'da: «ArosBasicAuth2»).

### 1.1 `v3/report/debtors-list/?report_date=YYYY-MM-DD&page=N&page_size=M` — ASOSIY MANBA
- 2459 mijoz (`count`), `page_size=1000` ISHLAYDI (3 sahifa yetadi), `ordering=-debt_45_plus` ishlaydi,
  `search=Rajaboy` ishlaydi (ism/familya), **`warehouse_id=` ISHLAMAYDI** (count o'zgarmaydi — filial filtri
  klientda/DB'da). Sukut tartib: `total_debt` kamayish. Mavjud bo'lmagan sahifa → **404**.
- Har qator:
  ```
  user_id, first_name, last_name, username (telefon +998…), role (business_partner|master|customer),
  warehouse_id, warehouse_name, wallet_status (free|blocked), wallet_balance, cashback_balance,
  total_debt, balance, clean_debt, debt_1_10, debt_11_20, debt_21_30, debt_31_45, debt_45_plus, total_outdated_debts
  ```
- **Formulalar (tekshirildi):** `total_debt = clean_debt + total_outdated_debts`;
  `total_outdated_debts = debt_1_10 + debt_11_20 + debt_21_30 + debt_31_45 + debt_45_plus`;
  `balance = wallet_balance + cashback_balance − total_debt` (musbat = mijozda ortiqcha pul).
  `clean_debt` = muddati HALI kelmagan qarz. Bucketlar = muddati o'tgan qarz, kechikish kunlari bo'yicha.
- `summary` (butun ro'yxat uchun, filtr bilan ham): `total_wallet_balance, total_cashback_balance, total_debt,
  clean_debt, debt_1_10 … debt_45_plus, total_outdated_debts, total_balance`. 2026-09-07: jami qarz **5.44 mlrd**,
  muddati o'tgan **470.8 mln** (45+ kun: 162.4 mln), 2459 mijozning ~1/3 da qarz 0.
- Birinchi 1000 ta: rol business_partner 401 · master 595 · customer 4; wallet blocked 163; muddati o'tgan 125.
- 23 filial (warehouse_name) — Qarshi Asosiy ombor 160, Malika 120, O'rikzor C8 117, Samarqand Samsung 114 …

### 1.2 `wallet/v2/orders/{user_id}?page=1&page_size=200` — mijozning buyurtmalari (qarz TAFSILOTI)
- Bitta mijoz (10691) 116 buyurtma, `page_size=200` hammasini beradi. **Server filtri YO'Q** (`payment_status=`,
  `status=` e'tiborsiz). Qator: `id, status (completed), warehouse{id,name}, payment{original_amount, total_amount,
  deadline, status (unpaid|paid|late_paid), paid_date}, created_datetime`.
- **`unpaid` buyurtmalar `total_amount` yig'indisi = debtors-list `total_debt`** (86 169 000 = 86 169 000 ✓).
  `original_amount ≠ total_amount` (31/116) — chegirma/tuzatish; qarz `total_amount` bo'yicha.
- `deadline − created` odatda 25 kun (= `debt_allowed_days`), ba'zida 7/13/20/22/24. `late_paid` — muddatdan
  keyin to'langan (to'liq tarix uchun).
- 2459 mijoz × ~100 buyurtma = sinxronga OG'IR → **faqat mijoz kartasi ochilganda** (2-bosqich, himoyalangan proxy).

### 1.3 `wallet/v2/users/{user_id}/` — hamyon kartasi
- `wallet{balance, status, debt_limit (130 000 000), debt_allowed_days (25)}, cashback_balance, total_unpaid_amount`.
  Ro'yxatda YO'Q narsa: **`debt_limit`, `debt_allowed_days`** — limitga nisbatan foiz ko'rsatish uchun; 2-bosqichda
  karta ochilganda olinadi (2459 ta alohida so'rov sinxronga kirmaydi).

### 1.4 `products/warehouses/?module=debts&page_size=100&is_broken=false` — filiallar lug'ati
- 33 ta: `id, name/name_uz/name_ru/name_en, is_active, is_office, region{…}, parent_warehouse, broken_warehouse`.
  Filtr uchun ro'yxat; lekin debtors-list'da `warehouse_name` allaqachon bor → **1-bosqichda sinxron qilinmaydi**,
  filial filtri DB'dagi `distinct warehouse_id, warehouse_nom` dan.

### 1.5 Proxy (o'qish uchun) — `Aros Provodka - Yuk Detail API` (`yZkGLRDs1ujk8EFo`)
`?path=<admin dan keyingi yo'l>` qo'shildi (2026-09-07, UI'da qo'lda): `wallet/v2/users/10691/` kabi.
🔴 **Workflow NOFAOL qolsin** — `path` bilan u Aros admin API'ga OCHIQ proxy; faol qilinsa hamma narsa o'qiladi.
Faqat MCP `execute_workflow` (manual) bilan ishlatiladi. Mijozga ochiq endpoint 2-bosqichda ALOHIDA, JWT tekshiruvli.

## 2. Qarorlar (Fable, Asilbek «o'zing tahlil qil» dedi)

1. **Manba — faqat debtors-list** (30 daqiqada bir, 3 sahifa × 1000, ~12 s). Buyurtmalar/hamyon kartasi — on-demand.
2. **Pul harakati YO'Q, `entry`ga TEGILMAYDI** — bu registr (yolda/bojxona naqshi). 4010 daftar qoldig'i alohida qoladi.
3. **Aros qarzdor ≠ Provodka `qarzdor`** — jadval alohida (`aros_qarzdor`), qo'shilmaydi. Birlashtirish faqat
   ko'rinishda: umumiy dashboard (Provodka qolgan + Aros total_debt; Provodka kechikkan + Aros outdated).
4. Ruxsat: `qarz_page_ok()` (admin yoki `qarzdor` sahifasi) — mavjud qarz tizimi bilan bir xil, kassa doirasi YO'Q
   (mijoz qarzi kompaniya darajasida; eski #tab-kontr ham shunday).
5. Ro'yxatda yo'q bo'lib qolgan mijoz — `faol=false` (o'chirilmaydi). Sweep FAQAT to'liq payloadda: rows >= 100 VA rows = Aros `count` (bitta sahifa 404/timeout bersa sweep yo'q — tester 2026-09-07). 3 sahifa qat'iy: mijoz 3000 dan oshsa `ogoh` «rows != count» chiqadi, sahifa soni oshiriladi.
6. Kechikish kunlari Aros bucketlaridan; «eng katta bucket» = holat rangi (1–10 sariq, 11–30 to'q sariq, 31+ qizil).

## 3. SQL — `PROVODKA_AROS_QARZDOR.sql` (additive, idempotent, `$fn$` teglar, izohda dollar-qavs YO'Q)

### 3.1 `aros_qarzdor`
```
user_id int PK · ism text · familya text · telefon text · rol text · warehouse_id int · warehouse_nom text
wallet_status text · wallet_balance numeric(18,2) · cashback_balance numeric(18,2)
total_debt numeric(18,2) · balance numeric(18,2) · clean_debt numeric(18,2)
debt_1_10 · debt_11_20 · debt_21_30 · debt_31_45 · debt_45_plus · total_outdated numeric(18,2)
report_date date · faol boolean default true · synced_at timestamptz · created_at timestamptz default now()
```
Indekslar: `(total_debt desc)`, `(total_outdated desc)`, `(warehouse_id)`, `lower(ism||' '||familya)` trigram
shart emas — `ilike` yetadi (2.5k qator).
RLS: select `qarz_page_ok()`; insert/update/delete policy YO'Q (faqat RPC, service_role).

### 3.2 `aros_qarzdor_sync` — bitta qator (`id=1`)
`summary jsonb` (API `summary` xomligicha), `soni int`, `report_date date`, `synced_at timestamptz`, `davomiylik_ms int`,
`ogoh text[]`. RLS select `qarz_page_ok()`.

### 3.3 `sync_aros_qarzdor(p_data jsonb)` → jsonb — **service_role ONLY** (authenticated/anon revoke)
Kirish: `{report_date, summary:{…}, rows:[{user_id, first_name, last_name, username, role, warehouse_id,
warehouse_name, wallet_status, wallet_balance, cashback_balance, total_debt, balance, clean_debt, debt_1_10,
debt_11_20, debt_21_30, debt_31_45, debt_45_plus, total_outdated_debts}], davomiylik_ms}`.
- `rows` bo'yicha upsert (`on conflict (user_id) do update` hamma ustun + `faol=true`, `synced_at=now()`).
- `jsonb_array_length(rows) >= 100` bo'lsagina: payloadda yo'q `faol=true` qatorlar → `faol=false`. Aks holda
  `ogoh` ga «chala payload, sweep qilinmadi».
- `aros_qarzdor_sync` upsert. Qaytadi `{ok:true, yozildi, yangilandi, nofaol, ogoh:[]}`.
- 🔴 `user_id` null/son emas → qator tashlanadi (ogoh hisoblagichi), butun sync yiqilmaydi.

### 3.4 `aros_qarzdor_royxat(p jsonb default '{}')` → jsonb — authenticated, `qarz_page_ok()` tekshiradi (aks holda 42501)
`p`: `{q, warehouse_id, holat ('hammasi'|'qarzdor'|'muddati_otgan'|'toza'|'blok'|'45plus'), sort
('total_debt'|'total_outdated'|'debt_45_plus'|'balance'|'ism'), dir ('desc'|'asc'), limit (≤500, sukut 100), offset}`.
- `q` → `ism/familya/telefon ilike`; `holat`: qarzdor = `total_debt>0`; muddati_otgan = `total_outdated>0`;
  toza = `total_debt>0 and total_outdated=0`; blok = `wallet_status='blocked'`; 45plus = `debt_45_plus>0`.
  Faqat `faol=true`.
- Qaytadi `{rows:[…hamma ustun + kechikish_daraja ('yoq'|'1_10'|'11_20'|'21_30'|'31_45'|'45_plus' — eng katta nolmas
  bucket)], jami (filtrdan keyingi soni), jami_summa:{total_debt, total_outdated}, filiallar:[{warehouse_id,
  warehouse_nom, soni}] (filtrsiz, faol), synced_at, report_date}`.

### 3.5 `aros_qarzdor_dash()` → jsonb — authenticated, `qarz_page_ok()`
`{summary (sync jadvalidan), soni_jami, soni_qarzdor (total_debt>0), soni_muddati_otgan, soni_blok, synced_at,
report_date, eskirgan (synced_at < now()−2 soat)}`. Jadval bo'sh → `{summary:null, …0}` (banner uchun).

### 3.6 `qarz_umumiy_dash()` → jsonb — Provodka + Aros birlashma (UI yuqori kartalar)
`{provodka:{jami_qolgan, jami_kechikkan} (qarz_dash() dan), aros:{total_debt, total_outdated, soni_qarzdor,
synced_at}, jami:{qarz, muddati_otgan}}`. `qarz_dash` yo'q bazada — provodka qismi null.

## 4. n8n — `Aros Provodka - Aros Qarzdor Sync` (`i91Kfmp7Orm55leW`, `N8N_AROS_QARZDOR_SYNC.js`, ALOHIDA workflow — yaratildi 2026-09-07, kredit+Publish Asilbek)
Schedule 30 daq + Manual → **Sana** (Code: `report_date` = bugun Toshkent) → **Sahifalar** (Code: 3 item `page=1..3`) →
**Get Debtors** (HTTP GET `…/v3/report/debtors-list/?report_date=&page=&page_size=1000`, Aros Basic Auth,
timeout 60 s, 🔴 **batching `batchSize: 3, batchInterval: 1500`** — «Items per Batch = 1» n8n'da ABADIY osiladi
(2026-09-07 saboqi, CLAUDE.md), `onError: continueRegularOutput` — 404 (sahifa yo'q) oqimni to'xtatmasin) →
**Yig'** (Code: `results` larni bitta massivga, `summary` 1-sahifadan, `count` bilan solishtirib `ogoh`) →
**sync_aros_qarzdor** (HTTP POST `rest/v1/rpc/sync_aros_qarzdor`, Supabase API service_role).
Kreditlar (Aros Basic Auth, Supabase API) — Asilbek. SDK: `const`, template string, `newCredential`, jsCode'da
arrow YO'Q, `function` sintaksisi.

## 5. UI — `qarzdor-dev.html` «Bizdan qarzdor» (faqat dev)
1. **Umumiy strip** (segment ostida, sub-tablardan oldin, `qarz_umumiy_dash`): Jami qarz (Provodka + Aros) ·
   Muddati o'tgan (ikkalasi) · Aros mijozlar (qarzdor soni) · «Aros: 12:40 da yangilangan» (eskirgan → sariq).
   Har kartada kichik taqsimot satri «Provodka X · Aros Y».
2. **Yangi sub-tab «Aros mijozlar»** (`data-tab="aros"`, badge = muddati o'tgan soni; `localStorage qz-tab` mos):
   - Filtr paneli: qidiruv (ism/telefon, 250 ms debounce), filial select (`filiallar`), holat chiplari: Hammasi ·
     Qarzdor · Muddati o'tgan · 45+ kun · Bloklangan; saralash select.
   - Dash (5 karta): Jami qarz · Muddati o'tmagan · Muddati o'tgan · 45+ kun · Hamyon/keshbek jami (summary'dan).
     Ostida **kechikish taqsimoti** (5 bucket stacked bar, `dataviz` uslubi, palitradan).
   - Jadval (desktop ≥1301px, 🔴 raqam KESILMASIN — `.main max-width:none`, tor ekranda karta):
     Mijoz (ism familya, ostida telefon · rol) · Filial · Jami qarz · Muddati o'tmagan · **Muddati o'tgan**
     (summa + 5 bucket mini-bar, title'da har bucket) · Hamyon (balance, blocked → qizil chip) · Balans.
     Sahifalash «Yana 100 ta». Qator bosilsa → **modal karta**: hamma raqam, bucket jadvali, `tel:` havola,
     (2-bosqich: buyurtmalar ro'yxati + debt_limit). Excel (mavjud `loadXlsx` naqshi, filtr bo'yicha hammasi ≤5000).
   - RPC yo'q bazada (42883/PGRST202) → tab ichida banner «SQL RUN qilinmagan», sahifa buzilmaydi.
3. Mavjud «Kutilayotgan / Qarz berish / Tilxatlar» va `#tab-kontr` — TEGILMAYDI.

## 6. Bosqichlar
1. **SQL + n8n** (coder → tester) — jadval, RPC'lar, workflow SDK; Asilbek RUN + kredit + Publish.
2. **UI** (coder + designer → tester) — strip + «Aros mijozlar» tab + modal + Excel.
3. **Buyurtmalar drill-down** (keyin): JWT tekshiruvli n8n webhook (`auth/v1/user` + `qarz_page_ok`), mijoz
   kartasida unpaid buyurtmalar (deadline, kechikish kuni), `debt_limit` foizi.
4. CLAUDE.md bo'limi + memory.

## 7. Ochiq savollar (Asilbek) — sukut bilan qurildi
- Kechikkan qarz uchun Telegram eslatma kerakmi? (sukut: yo'q, 3-bosqichdan keyin).
- Provodka `qarz` va Aros qarzdorni BITTA ro'yxatda aralashtirishmi? (sukut: alohida tab + umumiy strip —
  ular boshqa-boshqa obyekt: hodim/shaxsga berilgan pul vs mijozning tovar qarzi).
