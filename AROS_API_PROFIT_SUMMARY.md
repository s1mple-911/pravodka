# Aros API — `profit-summary` (foyda + ombor qoldig'i) — 2026-10-17

Aros bergan YANGI hisobot endpointi. Metabase «Profit report» (card `c89e54d0…`) 2026-10-03 dan to'xtagach va «materialreport total»
(card `4f729857…`) o'rniga Aylanma sahifasi shundan oladi. Aros'dan **faqat o'qiydi**.

## ✅ 2026-10-22: to'g'ri parametr `warehouse` (`warehouse_id` EMAS)

Asilbek: `?start_date=2026-10-16&end_date=2026-10-16&warehouse=61` — shu bilan filial kesimi ishlaydi. Yoqish (V2 skript, tayyor rejim):
`N8N_AYLANMA_PROFIT_API_V2.sh --wh-param warehouse` → Publish → «Qolda ishga tushirish» (BACKFILL yoqiq bo'lsa 03.10 dan har kun per-filial ham
to'ladi, ≈19 kun × 34 ombor ≈ 650 so'rov, bir martalik) → keyin `--backfill-off` → Publish. Himoya qoladi: ombor javobi umumiy bilan aynan teng bo'lsa
rad etiladi (`profit_ogoh`). Quyidagi 2026-10-17 bo'limi tarix uchun.

## 🔴 `warehouse_id` prod'da ISHLAMAYDI (2026-10-17 tekshirildi) — SUMMARY-ONLY (eskirgan, nom xato edi)

Prod'da `&warehouse_id=<id>` e'tiborga olinmaydi: 69 ta so'rovning (umumiy + har ombor) HAMMASI bir xil umumiy javob qaytardi
(`total_stock_value` 2 636 886.84, `total_broken_value` 10 138.26, `total_profit` 5 647.09 — 16.10 uchun). V1 workflow shuning uchun tovar/brak/foyda
per-filialni 33-35 marta ko'paytirib yozdi (tozalash: `PROVODKA_AYLANMA_PROFIT_API_TOZALASH.sql`). V2 (`N8N_AYLANMA_PROFIT_API_V2.sh`) faqat umumiy
(warehouse_id siz) javobdan foydalanadi: [1] = `total_stock_value`, [5] = `total_broken_value`, foyda = JAMI. Kuniga 5 so'rov (kecha + oldingi 4 kun).
To'g'ri parametr nomi Aros'dan so'ralgan; aytilsa `--wh-param <nom>` bilan yoqiladi (javob umumiydan farq qilmasa avtomat rad etiladi).
Quyidagi «Provodka'da qayerda ishlatiladi» va so'rov soni bandlari V1 uchun yozilgan edi — V2 da per-ombor qismlari o'chiq.

## Endpoint

```
GET https://api.aros.uz/api/admin/v2/report/profit-summary/?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD[&warehouse=<id>]
```
- Prod'da oddiy host `api.aros.uz` (Aros staging'da ko'rsatgan; prod'da ishlashi **hali curl bilan tasdiqlanmagan** — pastdagi tekshiruv).
- Auth: boshqa Aros so'rovlari bilan bir xil HTTP Basic (n8n kredit `ArosBasicAuth2`). Kredit repoda YO'Q.
- `start_date`, `end_date` — kun (Toshkent kuni), ikkalasi ham kiradi; bir kun = `start_date = end_date`.
- `warehouse` — ixtiyoriy (2026-10-22 gacha hujjatda `warehouse_id` deb yozilgan edi — u e'tiborga olinmaydi). **Yo'q** → butun kompaniya (summary); **bor** → shu ombor kesimi.

## Javob (hammasi USD)

```json
{"total_sold_quantity": 96689, "total_return_quantity": 2998, "total_income_price": 339332.54, "total_selling_price": 396055.21,
 "total_cashback_price": 1079.31, "total_profit": 56722.67, "total_stock_value": 2164958.0, "total_broken_value": 22336.84}
```
| Maydon | Ma'no | Sanaga bog'liq? |
|--------|-------|-----------------|
| `total_sold_quantity` | sotilgan dona | ha (start..end) |
| `total_return_quantity` | qaytarilgan dona | ha |
| `total_income_price` | kirim (tannarx) narxi, $ | ha |
| `total_selling_price` | sotuv narxi, $ | ha |
| `total_cashback_price` | keshbek orqali to'lov, $ | ha |
| `total_profit` | foyda, $ | ha |
| `total_stock_value` | tovar qoldig'i qiymati, $ | **YO'Q — hozirgi holat** |
| `total_broken_value` | brak qoldig'i qiymati, $ | **YO'Q — hozirgi holat** |

🔴 `total_stock_value` / `total_broken_value` **sanaga qaramaydi** — har doim JORIY qoldiq. Shuning uchun u «kechagi» qoldiq emas,
so'rov yuborilgan paytdagi (08:00) qoldiq; tarixiy kunni backfill qilganda faqat birinchi 6 maydon ma'noli.
Ombor `is_broken` bo'lsa qiymat qaysi maydonda (stock yoki broken) kelishi **tasdiqlanmagan** — workflow ikkalasini ham saqlaydi va
brak ombor uchun kattasini oladi (pastga qara).

## Provodka'da qayerda ishlatiladi

n8n «Aros Provodka - Aylanma Snapshot» (`o3BZP8uYatGkRu8b`), patch: `N8N_AYLANMA_PROFIT_API.sh`; SQL: `PROVODKA_AYLANMA_PROFIT_API.sql`.
1. **`Profit Prep` → `Get Profit WH`** (har kuni 08:00): kecha uchun har ombor (`warehouse_id=<id>`, `Get Warehouses` ro'yxatidan) + bitta umumiy
   (warehouse_id siz). Bitta javob ikki ishga: (a) **[T1] tovar / [T5] brak** — `omborlar[].usd` (oddiy ombor: `total_stock_value`;
   `is_broken` ombor: `max(stock, broken)`; ikkalasi alohida `usd_stock`/`usd_broken` ham yuboriladi) → RPC `sync_aylanma_snapshot`;
   (b) **kecha foyda** per filial + JAMI → `aylanma_foyda`.
2. **Tekshiruv**: Σ per-ombor `total_stock_value` (oddiy) vs umumiy `total_stock_value`; Σ brak ombor vs umumiy `total_broken_value`; Σ foyda vs umumiy
   `total_profit` — farq >1% (va >$1) bo'lsa `payload.profit_ogoh[]` → `aylanma_snapshot.xatolar` → sahifada sariq banner.
3. **`Foyda URL` → `Get Profit Foyda` → `Foyda Payload` → `sync_aylanma_foyda`**: kechadan oldingi 4 kun umumiy (JAMI) qayta yoziladi (Aros keyin
   to'g'rilasa yangilanadi) + vaqtinchalik **BACKFILL** (`Foyda URL` ichidagi `BACKFILL_FROM`, 2026-10-03 dan kechagacha har kun JAMI + har filial).
4. `aylanma_foyda(sana, filial, …, manba='aros_api', warehouse_id)`: `filial` = ombor `name_uz` (yo'q bo'lsa `name`), `JAMI` = umumiy javob.
   Aylanma sahifasi hisobotda faqat `JAMI` ni so'mga o'giradi, modalda filiallar ro'yxatini nom bo'yicha ko'rsatadi — nom bo'yicha boshqa bog'liqlik YO'Q.
5. So'rov soni: kuniga ≈ N ombor (68) + 1 umumiy + 4 oldingi kun = **≈73** profit-summary (+ avvalgi ≈9 Aros so'rov). BACKFILL yoqilganda bir martalik
   ≈ 13 kun × (1 + ~33 filial) ≈ 440 ta.

## Ochiq savollar (curl bilan tekshiriladi)

```bash
# 1) endpoint prod'da bormi (butun kompaniya, bir kun)
curl -s -u LOGIN:PAROL "https://api.aros.uz/api/admin/v2/report/profit-summary/?start_date=2026-10-16&end_date=2026-10-16"
# 2) BRAK ombor javobi: qiymat qaysi maydonda? (BRAK_OMBOR_ID — products/warehouses ro'yxatida is_broken=true bo'lgan istalgan ombor id)
curl -s -u LOGIN:PAROL "https://api.aros.uz/api/admin/v2/report/profit-summary/?start_date=2026-10-16&end_date=2026-10-16&warehouse_id=BRAK_OMBOR_ID"
```
Tasdiqlanadigan narsalar: (a) 8 maydon kelishi; (b) brak omborda qiymat `total_stock_value` yoki `total_broken_value` da (workflow ikkalasini ko'radi, lekin
ikkalasi ham to'lgan bo'lsa kattasini oladi); (c) `total_stock_value` tannarx (kirim narxi) ekani — eski Metabase «Oxirgi summa» bilan jami farqi (09-08: ≈ $2.31 mln) kichik bo'lishi kerak;
(d) 404/xato javob matni (workflow `detail`/`error`/`message` ni o'qiydi).
