-- =====================================================================
--  DIAG_TRANSFER_4_YANGI_SHAKL.sql   (2026-09-09)
--  Aros YANGI JSON shakli bo'yicha 19 ta transferning HAQIQIY summasi.
-- ---------------------------------------------------------------------
--  🟢 FAQAT O'QIYDI.  🔴 n8n POSTGRES da RUN QILING (Provodkada EMAS).
--
--  ## AROS SHAKLI O'ZGARDI (1445 namunasidan aniqlandi)
--  ESKI (kodimiz shuni o'qiydi -> endi 0 qaytaradi):
--      items[].document.seller_cash | seller_click | seller_payme | seller_dollar
--      items[].confirmed_cash | confirmed_click | confirmed_payme | confirmed_dollar
--  YANGI:
--      items[].document.amounts[] = {label_code, currency, amount, confirmed_amount}
--          label_code: cash_balance | click_balance | dollar_balance | terminal
--      items[].confirmed_total          -- tayyor jami (UZS + USD*kurs)
--      items[].document.currency_rate   -- O'ZGARMAGAN (shuning uchun
--                                          faqat kurs to'g'ri kelayotgan edi)
--
--  🔴 `payme` YO'Q, o'rniga `terminal`. Provodkada `payme` tur-hisobi bor,
--     `terminal` yo'q. 3-SO'ROV terminalda pul bor-yo'qligini tekshiradi —
--     Provodka tomonini shunga qarab moslaymiz.
--
--  🔴 BITTA transferda BIR NECHTA item bo'lishi mumkin (1445 da 2 ta:
--     «7-sentabr kassa» va «8-sentabr kassa») va HAR item o'z
--     `currency_rate` iga ega (11900 va 11850). Shuning uchun dollar
--     so'mga HAR ITEM o'z kursi bilan aylantiriladi — bitta umumiy kurs
--     (eski koddagi `max(...)`) noto'g'ri bo'lardi.
-- =====================================================================


-- #####################################################################
--  1-SO'ROV ⭐ — 19 ta transferning HAQIQIY summasi (yangi shakl)
-- #####################################################################
-- ⬇⬇⬇
with a as (
  select t.id,
         t.status,
         t.sender_title,
         t.receiver_title,
         t.received_at,
         (i->'document'->>'currency_rate')::numeric as kurs,
         am->>'label_code'                          as tur,
         coalesce((am->>'confirmed_amount')::numeric,
                  (am->>'amount')::numeric, 0)      as summa
    from cachier_transfers t,
         jsonb_array_elements(t.items) i,
         jsonb_array_elements(i->'document'->'amounts') am
   where t.id in (1428,1431,1435,1437,1438,1439,1440,1444,1445,1446,1447,1448,
                  1434,1436,1441,1442,1443,1449,1450,1393)
)
select id, status, sender_title, receiver_title, received_at,
       sum(summa) filter (where tur = 'cash_balance')          as naqd,
       sum(summa) filter (where tur = 'click_balance')         as click,
       sum(summa) filter (where tur = 'terminal')              as terminal,
       sum(summa) filter (where tur = 'dollar_balance')        as dollar_usd,
       -- dollar HAR ITEM o'z kursi bilan so'mga aylantiriladi
       round(sum(summa * kurs) filter (where tur = 'dollar_balance')) as dollar_som,
       round(sum(summa) filter (where tur in ('cash_balance','click_balance','terminal'))
           + coalesce(sum(summa * kurs) filter (where tur = 'dollar_balance'), 0)) as jami_som
  from a
 group by id, status, sender_title, receiver_title, received_at
 order by id;
-- ⬆⬆⬆


-- #####################################################################
--  2-SO'ROV ⭐⭐ — JAMI YO'QOLGAN PUL (faqat qabul qilingan 12 ta)
--  Hodim aytgan farq shu raqam bilan solishtiriladi.
-- #####################################################################
-- ⬇⬇⬇
with a as (
  select t.id,
         (i->'document'->>'currency_rate')::numeric as kurs,
         am->>'label_code'                          as tur,
         coalesce((am->>'confirmed_amount')::numeric,
                  (am->>'amount')::numeric, 0)      as summa
    from cachier_transfers t,
         jsonb_array_elements(t.items) i,
         jsonb_array_elements(i->'document'->'amounts') am
   where t.id in (1428,1431,1435,1437,1438,1439,1440,1444,1445,1446,1447,1448)
)
select count(distinct id)                                       as transfer_soni,
       round(sum(summa) filter (where tur in ('cash_balance','click_balance','terminal'))
           + coalesce(sum(summa * kurs) filter (where tur = 'dollar_balance'), 0)) as jami_som,
       sum(summa) filter (where tur = 'dollar_balance')          as jami_usd
  from a;
-- ⬆⬆⬆


-- #####################################################################
--  3-SO'ROV — `terminal` da umuman pul bo'lganmi? (payme o'rnini bosganmi)
--  Provodkada `payme` tur-hisobi bor, `terminal` yo'q. Agar terminal
--  HAR DOIM 0 bo'lsa — muammo yo'q. 0 dan katta bo'lsa, uni Provodkada
--  qaysi hisobga yozishni hal qilish kerak.
-- ⬇⬇⬇
select am->>'label_code'                    as tur,
       count(*)                              as nechta_qator,
       count(*) filter (where coalesce((am->>'confirmed_amount')::numeric,0) > 0) as nolmas,
       round(sum(coalesce((am->>'confirmed_amount')::numeric,0))) as jami
  from cachier_transfers t,
       jsonb_array_elements(t.items) i,
       jsonb_array_elements(i->'document'->'amounts') am
 where t.received_at > now() - interval '60 days'
 group by 1
 order by 1;
-- ⬆⬆⬆


-- #####################################################################
--  4-SO'ROV — buzilish AYNAN qachon boshlangan
--  Eski shakl (seller_cash) qaysi kungacha ishlagan, yangi shakl
--  (amounts[]) qaysi kundan boshlangan.
-- ⬇⬇⬇
select date(t.received_at) as kun,
       count(*)                                                              as transfer,
       count(*) filter (where i->'document' ? 'amounts')                     as yangi_shakl,
       count(*) filter (where i->'document' ? 'seller_cash')                 as eski_shakl
  from cachier_transfers t,
       jsonb_array_elements(t.items) i
 where t.received_at > now() - interval '30 days'
 group by 1
 order by 1 desc;
-- ⬆⬆⬆
