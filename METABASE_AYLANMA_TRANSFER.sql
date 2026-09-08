-- =====================================================================
--  METABASE_AYLANMA_TRANSFER.sql — Metabase (Aros DB, database 2) uchun
--  YANGI public karta: ochiq tovar transferlari TANNARXDA (2026-09-08)
-- ---------------------------------------------------------------------
--  Muammo: Aros API `v2/transfers` dagi `document_price` = transferitem.price
--  × qty — bu SOTUV/hujjat narxi, tannarx EMAS (52565: 7000 × 5 = 35 000,
--  buyurtma sotuv narxi 25 000). «Sof aylanma kapital» ko'chirishni
--  TANNARXDA sanashi kerak (Asilbek qarori).
--
--  Bu SQL — «materialreport total» (karta 62, 4f729857-…) bilan bir xil
--  jadvallar: back_office_transfer / back_office_transferitem /
--  back_office_productincomeitem (average_price — kirim narxi, USD).
--  Har bir on_way / created transfer uchun: tannarx (USD) va hujjat narxi.
--
--  Asilbek: Metabase → New → SQL query → Database «Aros» → quyidagini
--  qo'yib saqlang → «Public link» yoqing → karta UUID'ini bering.
--  n8n «Aylanma Snapshot» ga «Get MB Transfers» node qo'shiladi va
--  transferlar[].tannarx_uzs = tannarx_usd × kurs bilan to'ldiriladi
--  (RPC coalesce(tannarx_uzs, price_uzs)). Parametr YO'Q — statik.
--
--  ⚠️ Ustun nomlari n8n'da AYNAN shu bilan o'qiladi: transfer_id, status,
--     from_warehouse_id, to_warehouse_id, qty, tannarx_usd, hujjat_narx,
--     variant_yoq (tannarxi topilmagan variantlar soni).
-- =====================================================================

WITH last_price AS (
    -- har variant uchun ENG OXIRGI kirim narxi (materialreport `ending_avg_price` bilan bir xil)
    SELECT DISTINCT ON (pii.product_variant_id)
        pii.product_variant_id,
        pii.average_price::NUMERIC AS average_price
    FROM back_office_productincomeitem pii
    JOIN back_office_productincome pi ON pi.id = pii.product_income_id
    WHERE pii.is_active = TRUE AND pi.is_active = TRUE
      AND pi.post_at IS NOT NULL
    ORDER BY pii.product_variant_id, pi.post_at DESC
),
ochiq AS (
    SELECT t.id, t.status, t.from_warehouse_id, t.to_warehouse_id,
           t.created_datetime, t.sent_at
    FROM back_office_transfer t
    WHERE t.is_active = TRUE
      AND t.status IN ('on_way', 'created')
)
SELECT
    o.id                                                          AS transfer_id,
    o.status                                                      AS status,
    o.from_warehouse_id                                           AS from_warehouse_id,
    o.to_warehouse_id                                             AS to_warehouse_id,
    SUM(ti.quantity)                                              AS qty,
    ROUND(SUM(ti.quantity * COALESCE(lp.average_price, 0)), 2)    AS tannarx_usd,
    ROUND(SUM(ti.quantity * ti.price::NUMERIC), 2)                AS hujjat_narx,
    COUNT(*) FILTER (WHERE lp.average_price IS NULL)              AS variant_yoq,
    o.created_datetime                                            AS created_datetime,
    o.sent_at                                                     AS sent_at
FROM ochiq o
JOIN back_office_transferitem ti ON ti.transfer_id = o.id
LEFT JOIN last_price lp ON lp.product_variant_id = ti.product_variant_id
GROUP BY o.id, o.status, o.from_warehouse_id, o.to_warehouse_id, o.created_datetime, o.sent_at
ORDER BY o.id DESC;
