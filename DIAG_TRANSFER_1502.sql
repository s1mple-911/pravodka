-- ============================================================================
--  DIAG_TRANSFER_1502.sql — 2026-09-16 (Asilbek)
--  FAQAT O'QISH. Hech narsa yozmaydi, o'chirmaydi, o'zgartirmaydi.
--
--  MUAMMO (Aros tomonidan tasdiqlangan, jonli API dan o'qildi):
--    Transfer 1502  Navoiy -> Toshkent Kassa,  4 ta kunlik hujjat:
--      #3001 (08.09)  naqd 2 268 000 + click   540 000
--      #3016 (09.09)  naqd 3 150 000 + click 2 574 000
--      #3039 (10.09)  naqd 4 989 000 + click 1 726 000
--      #3060 (11.09)  naqd 7 755 000 + click   776 000
--    JONLI AROS'da hammasi TASDIQLANGAN: naqd 18 162 000 + click 5 616 000
--                                        = 23 778 000
--    Bizdagi nusxada (n8n cachier_transfers) esa faqat #3001 ning naqdi
--    2 268 000 tasdiqlangan ko'rinadi — qolgani 0.
--    Sabab: «Bugalter Sync» Aros'dan FAQAT `status=sent` transferlarni
--    o'qiydi. 1502 «received» bo'lgandan keyin biz uni BOSHQA hech qachon
--    qayta o'qimadik; kassir keyinroq qolgan 3 kunlikni ham qabul qilgan,
--    bu esa bizga yetib kelmagan.
--
--  Shuning uchun tuzatish yozishdan OLDIN Provodkada nima borligini aniq
--  bilish kerak. Quyidagi 4 so'rov natijasini menga yuboring.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) 1502 uchun YOZILGAN provodkalar (bor-yo'qligi va summasi)
-- ----------------------------------------------------------------------------
select e.id,
       e.entry_date,
       e.ext_ref,
       e.source,
       e.is_deleted,
       e.description,
       sum(el.debit)  as dt_jami,
       sum(el.credit) as kt_jami
  from entry e
  join entry_line el on el.entry_id = e.id
 where e.ext_ref like 'aros_tr:1502:%'
    or e.ext_ref like 'aros_tr_fix:1502:%'
 group by e.id, e.entry_date, e.ext_ref, e.source, e.is_deleted, e.description
 order by e.id;

-- ----------------------------------------------------------------------------
-- 2) O'sha yozuvlarning SATRLARI — qaysi hisobga tushgan
-- ----------------------------------------------------------------------------
select e.ext_ref, a.code, a.name, a.kassa_turi, a.pul_turi,
       el.debit, el.credit
  from entry e
  join entry_line el on el.entry_id = e.id
  join accounts a    on a.id = el.account_id
 where e.ext_ref like 'aros_tr:1502:%'
    or e.ext_ref like 'aros_tr_fix:1502:%'
 order by e.id, el.debit desc nulls last;

-- ----------------------------------------------------------------------------
-- 3) NAVOIY tomonida 08–16.09 oralig'ida nima yozilgan
--    (transferning filial tomoni qanday yopilganini ko'ramiz: to'g'ri
--     transfermi yoki delta sync «savdo minus» qilib yozganmi)
-- ----------------------------------------------------------------------------
select e.id, e.entry_date, e.source, coalesce(e.ext_ref,'—') as ext_ref,
       left(e.description, 70) as izoh,
       string_agg(a.code || ' ' || a.name ||
                  case when coalesce(el.debit,0) > 0
                       then ' [Dt ' || el.debit || ']'
                       else ' [Kt ' || el.credit || ']' end, '  |  '
                  order by el.debit desc nulls last) as satrlar
  from entry e
  join entry_line el on el.entry_id = e.id
  join accounts a    on a.id = el.account_id
 where e.entry_date between date '2026-09-08' and date '2026-09-16'
   and e.is_deleted = false
   and exists (select 1
                 from entry_line l2
                 join accounts a2 on a2.id = l2.account_id
                where l2.entry_id = e.id
                  and a2.name ilike '%navoiy%')
 group by e.id, e.entry_date, e.source, e.ext_ref, e.description
 order by e.id;

-- ----------------------------------------------------------------------------
-- 4) Hozirgi qoldiqlar: Toshkent Kassa va Navoiy (pul turlari bilan)
-- ----------------------------------------------------------------------------
select a.code, a.name, coalesce(a.pul_turi, a.currency) as tur,
       a.kassa_turi,
       (select coalesce(sum(el.debit) - sum(el.credit), 0)
          from entry_line el
          join entry e2 on e2.id = el.entry_id
         where el.account_id = a.id
           and e2.is_deleted = false
           and e2.status = 'posted') as qoldiq
  from accounts a
 where a.is_active
   and (a.name ilike '%toshkent%kassa%' or a.name ilike '%navoiy%')
 order by a.name, a.code;
