-- =====================================================================
--  DIAG_TRANSFER_3_NOL_IDLAR.sql   (2026-09-09)
--  Summasi 0 bo'lib kelgan ANIQ transfer ID lari + haqiqiy summani
--  Aros tomonidan olish.
-- ---------------------------------------------------------------------
--  🟢 FAQAT O'QIYDI.
--
--  ## SUMMASI 0 BO'LGAN TRANSFERLAR — 19 ta
--  (Asilbek: «bugun 0 lik transfer qabul qilmagan» — demak hammasi xato)
--
--  A) QABUL QILINGAN (received), Provodkada YOZUV YO'Q — 12 ta:
--     Toshkent Kassa    : 1437 1439 1440 1444 1445 1448
--     Qashqadaryo Kassa : 1428 1431 1435 1438 1446 1447
--
--  B) YO'LDA (sent, hali qabul qilinmagan), summasi 0 — 7 ta:
--     Toshkent Kassa    : 1434 1436 1441 1442 1443 1449 1450
--     (1393 — Qashqadaryo, 60 104 000 so'm — SUMMASI BOR, sog'lom)
--
--  🔴 1393 (2026-09-04) summasi BOR, 1434 (2026-09-08) dan boshlab 0.
--     Ya'ni buzilish 09-04 va 09-08 oralig'ida boshlangan.
-- =====================================================================


-- #####################################################################
--  1-SO'ROV ⭐ — n8n POSTGRES da (Aros nusxasi), Provodkada EMAS
--  Shu 19 ta transferning HAQIQIY summasi qaysi kalitda yotganini
--  topadi: document ichidagi hamma kalit + qiymati.
--  Pul kalitini ko'rsangiz (masalan 12 500 000 kabi son) — nomi shu.
-- #####################################################################
-- ⬇⬇⬇
select t.id,
       k.key                       as kalit,
       left(k.value #>> '{}', 30)  as qiymat
  from cachier_transfers t,
       jsonb_array_elements(t.items) i,
       jsonb_each(i->'document') k
 where t.id in (1428,1431,1435,1437,1438,1439,1440,1444,1445,1446,1447,1448,
                1434,1436,1441,1442,1443,1449,1450)
   and k.value #>> '{}' ~ '^[0-9]+(\.[0-9]+)?$'
   and (k.value #>> '{}')::numeric > 0
 order by t.id, k.key;
-- ⬆⬆⬆

-- ⬇⬇⬇  Xuddi shu, lekin ITEM darajasida (confirmed_* shu yerda edi)
select t.id,
       k.key                       as kalit,
       left(k.value #>> '{}', 30)  as qiymat
  from cachier_transfers t,
       jsonb_array_elements(t.items) i,
       jsonb_each(i) k
 where t.id in (1428,1431,1435,1437,1438,1439,1440,1444,1445,1446,1447,1448,
                1434,1436,1441,1442,1443,1449,1450)
   and jsonb_typeof(k.value) <> 'object'
   and k.value #>> '{}' ~ '^[0-9]+(\.[0-9]+)?$'
   and (k.value #>> '{}')::numeric > 0
 order by t.id, k.key;
-- ⬆⬆⬆


-- #####################################################################
--  2-SO'ROV — n8n POSTGRES da. TAQQOSLASH: sog'lom (1393) vs buzuq (1448)
--  Eng tez yo'l: ikki JSON ni yonma-yon ko'rib, qaysi kalit yo'qolganini
--  darrov ko'rasiz.
-- #####################################################################
-- ⬇⬇⬇
select t.id, t.status, t.sender_title, t.receiver_title,
       jsonb_pretty(t.items) as items
  from cachier_transfers t
 where t.id in (1393, 1448)
 order by t.id;
-- ⬆⬆⬆


-- #####################################################################
--  3-SO'ROV — PROVODKA da. Shu 19 ta uchun hozir nima yozilgan
--  (bo'sh chiqsa — hech biri yozilmagan, kutilgani shu)
-- #####################################################################
-- ⬇⬇⬇
select y.transfer_id, y.status, y.sender_title, y.receiver_title,
       y.received_at, y.sent_at,
       coalesce(y.c_cash,0)+coalesce(y.c_click,0)+coalesce(y.c_payme,0) as provodkada_som,
       exists (select 1 from entry e
                where e.ext_ref like 'aros_tr:' || y.transfer_id || ':%'
                  and e.is_deleted = false) as yozuv_bor
  from aros_transfer_yolda y
 where y.transfer_id in ('1428','1431','1435','1437','1438','1439','1440','1444',
                         '1445','1446','1447','1448','1434','1436','1441','1442',
                         '1443','1449','1450','1393')
 order by y.transfer_id::int;
-- ⬆⬆⬆
