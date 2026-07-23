# PROVODKA — "Yuklar" bo'limi (Aros product-incomes) + xarajatga bog'lash

## Maqsad
Aros'dagi tovar kirimlari (yuklar) Provodka'da ko'rinsin, va "Tovar tannarxi" xarajati yozilganda qaysi yuk(lar) uchun to'langani belgilansin. Shunda har yuk **to'langan / to'lanmagan** holatini ko'rsatadi.

---

## Ma'lumot manbai
Aros API: `GET /api/admin/v3/product-incomes/?date_from=...&date_to=...&page=1&page_size=...`

Javob (qisqartirilgan):
```json
{ "count": 54, "next": "...", "results": [
  { "id": 2707,
    "created_datetime": "2026-07-22T10:35:15+05:00",
    "warehouse": { "id": 4, "name": "Asosiy ombor" },
    "provider": { "id": 24, "name": "Sklad Toshkent (Sardor)", "phone_number": "1230" },
    "document_price": "1373.79",
    "currency": { "id": 1, "name": "USD" },
    "status": "posted",
    "delivery_status": "accepted",
    "post_at": "2026-07-22T10:35:26+05:00" }
]}
```
Diqqat: valyuta har xil (USD / UZS / AED / CHY), `post_at` null bo'lishi mumkin (status='created').

**Frontend Aros API'ga TO'G'RIDAN bormaydi** (CORS + auth). n8n proxy endpoint bo'ladi:
```
GET https://n8n.arosmarket.com/webhook/aros-provodka-yuklar?date_from=YYYY-MM-DD&date_to=YYYY-MM-DD
→ { ok: true, yuklar: [ {id, sana, ombor, ombor_id, yetkazuvchi, narx, valyuta, status, delivery_status, post_at} ] }
```
Bu endpointni Asilbek n8n'da tayyorlaydi. Frontend faqat shuni chaqiradi. Endpoint hali tayyor bo'lmasa — chiroyli "yuklanmoqda / ulanmagan" holati ko'rsatilsin, sahifa yiqilmasin.

---

## 1. DB (PROVODKA_YUKLAR.sql)
```sql
alter table entry add column if not exists yuk_ids integer[] not null default '{}';
create index if not exists entry_yuk_ids_idx on entry using gin (yuk_ids);
```
- `yuk_ids` = Aros product-income `id` lari (bir xarajat bir necha yukni qoplashi mumkin — multiselect).
- **To'lov statusi alohida saqlanmaydi** — hisoblanadi: yuk id biror o'chirilmagan, posted entry'ning `yuk_ids` ichida bo'lsa → **to'langan**.
- RPC: `yuk_tolov_holati(p_ids integer[])` → `[{yuk_id, tolangan bool, entry_id, entry_date, summa}]` — SECURITY DEFINER, REVOKE anon, authenticated'ga grant. Frontend yuklar ro'yxatini olgach shu RPC bilan statuslarni to'ldiradi.

## 2. Yangi sahifa: `yuklar-dev.html`
- Nav'ga "Yuklar" qo'shilsin (perms `allowed_pages` ro'yxatiga `'yuklar'` kaliti ham qo'shilsin — perms.js PAGES + SQL `perm_pages()` + admin-dev checkbox; SQL o'zgarishini faylga yoz, Asilbek RUN qiladi).
- Default: **oxirgi 30 kun** (date_from = bugun−30, date_to = bugun). Davr o'zgartirish (sana oralig'i) bo'lsin.
- Ustunlar: **ID · Sana · Ombor · Yetkazib beruvchi · Narx · Status · Yetkazish holati · Nashr vaqti · To'lov statusi**
  - Narx: `document_price` + valyuta (masalan "1 373.79 USD")
  - Status: posted / created — o'zbekcha yorliq (Nashr qilingan / Yaratilgan)
  - Yetkazish: accepted / on_way → Qabul qilingan / Yo'lda
  - To'lov: **To'langan** (yashil) / **To'lanmagan** (kulrang yoki qizil) — `yuk_tolov_holati` dan
- To'langan qatorda: qaysi xarajat yozuvi (sana + summa) ko'rsatilsin, bosilsa jurnaldagi yozuvga o'tsin.
- Filtr: to'lov statusi bo'yicha (Hammasi / To'langan / To'lanmagan), ombor bo'yicha.
- Mobil: karta ko'rinishi.

## 3. `professional-dev.html` — "Tovar tannarxi" tanlanganda modal
- Modda **9110 "Tovar tannarxi"** tanlangan zahoti modal ochilsin: "Qaysi yuk uchun?"
- Modalda yuklar ro'yxati (oxirgi 30 kun, default **to'lanmaganlar** yuqorida yoki faqat to'lanmaganlar — filtr bilan): **ID · Sana · Ombor · Yetkazib beruvchi · Narx · Status**
- **Multiselect** — bir necha yuk tanlash mumkin.
- Tanlangач modal yopiladi, formada tanlanganlar chip sifatida ko'rinadi (o'chirish mumkin).
- Saqlashда `entry.yuk_ids` ga yoziladi.
- Yuk tanlash majburiymi? — **ixtiyoriy** (tanlanmasa ham saqlanadi), lekin modal avtomatik ochilib eslatadi.
- `hodim-dev.html` da 9110 odatda ishlatilmaydi — hozircha tegilmaydi (agar u yerda ham 9110 bo'lsa, xuddi shu modal ishlasin — o'zing qara, izohla).

## 4. `jurnal-dev.html` — yuk ko'rinsin
- `yuk_ids` bo'sh bo'lmagan yozuvda teg: 📦 "Yuk #2707, #2705" (filial/davr teglari yonida).
- Bosilsa — o'sha yuklarning qisqa ma'lumoti (ombor, yetkazuvchi, narx) modalda.

---

## Qoidalar
- Faqat `-dev.html` fayllar; prod fayllarga tegilmaydi.
- SQL additive (`add column if not exists`, yangi RPC) — bitta DB, prod ishlab turibdi.
- `boot()` modul oxirida; node --check; Aros brend ranglari.
- n8n endpoint javob bermasa yiqilmasin — aniq xabar + "Qaytadan urinish".

## Tartib
1 (DB) → 2 (yuklar sahifasi) → 3 (professional modal) → 4 (jurnal tegi). Har bosqich commit; push Asilbekda.
