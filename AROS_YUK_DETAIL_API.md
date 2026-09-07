# Aros product-income DETAIL API — bojxona (2026-09-06, haqiqiy javobdan)

`GET https://api.aros.uz/api/admin/v3/product-incomes/{id}/` (Basic Auth — faqat n8n'da).
Ro'yxat API'sida (`product-incomes/?date_from…`) bojxona YO'Q — faqat detail'da.

Proxy (o'qish uchun): n8n `Aros Provodka - Yuk Detail API` (`yZkGLRDs1ujk8EFo`, `N8N_YUK_DETAIL_API.js`)
`GET https://n8n.arosmarket.com/webhook/aros-provodka-yuk-detail?id=2794` → `{ok:true, detail:{…xom Aros javobi…}}`.

## Javob (2794, qisqartirilgan)
```json
{ "id": 2794, "document_price": "5015.0000", "currency": {"id":3,"name":"CHY"}, "currency_rate": 67,
  "status": "posted", "delivery_status": "accepted", "post_at": "2026-09-04T15:32:54+05:00",
  "custom_clearance_uzs": null, "fare_percent": null,            // HUJJAT darajasi
  "extra_charge_b2c": null, "extra_charge_b2b": null, "extra_charge_b2m": null,
  "product_income_items": [
    { "id": 88115, "product_variant": 7231, "quantity": 2,
      "income_price": "165.0000", "total_income_price": "330.0000",
      "custom_clearance_uzs": "30000.00",                 // BIR DONA uchun bojxona, SO'MDA
      "price_after_customs_clearance_uzs": "181.8200",    // VALYUTADA (nomi adashtiradi): income + custom/kurs
      "fare_percent": "0.0000", "price_after_fare_percent": "165.0000",
      "price_b2c": "500000.0000", "price_b2b": "440000.0000", "price_b2m": "470000.0000",
      "last_income_data": {"price":165,"currency":"CHY","currency_rate":7.07} },
    … 9 ta qator ] }
```

## Ikki rejim
1. **Hujjat darajasida** — `custom_clearance_uzs` / `fare_percent` hujjatda to'ldirilgan (hamma tovarga bir xil).
2. **Har tovar alohida** — hujjatda null, qatorlarda har xil (2794 shunday: 30000 / 5000 / 10000).

Har ikkisida ham tovar qatorlari YAKUNIY qiymatni ko'rsatadi → **jami har doim qatorlardan yig'iladi**:
- `bojxona_uzs = Σ custom_clearance_uzs × quantity` — 2794 uchun **600 000 so'm** (2×30000 + 5000 + 10×30000 + 5000 + 10000 + 3×30000 + 2×30000 + 2×30000 + 10000).
- `fare_cur = Σ (price_after_fare_percent − income_price) × quantity` — valyutada; so'mga `conv_baza_kurs(currency)` bilan.
- Zaxira: qatorlarda hammasi null/0, hujjatda `custom_clearance_uzs` bo'lsa → doc_custom × Σ quantity (bir dona deb).

⚠️ `currency_rate: 67` (hujjat) ishonchsiz — CHY kursi ~1783 so'm (181.82−165=16.82 CHY = 30000 so'm). So'm qiymatlar faqat `custom_clearance_uzs` dan olinadi. `last_income_data.currency_rate 7.07` — CHY/USD.

## Provodka'da (`PROVODKA_YUK_BOJXONA.sql`, `N8N_YUK_BOJXONA_SYNC.js`)
`aros_yuk_bojxona` jadvali (n8n har 30 daq, 30 kunlik oyna, detail batch 5/2500ms — rate-limit; batch 1 n8n bug tufayli osiladi),
`yuk_bojxona_jami(p_ids)`, `yuk_tannarx_qosh` limit: qo'shilgan + yangi > bojxona + fare → `{ok:false, kod:'limit'}`.
