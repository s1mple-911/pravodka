-- ============================================================
-- Rasmda: 5 filial × 249 000 = 1 245 000 so'm, soat ~17:59 (UZB)
-- Savol: o'sha yozuvlar bazaga TUSHDIMI yoki umuman yozilmadimi?
-- Faqat O'QIYDI. So'rovlarni BITTALAB RUN qiling.
-- ============================================================

-- ############ 1-SO'ROV — bugungi 249 000 lik yozuvlar ############
select e.id,
       e.entry_date,
       (e.created_at + interval '5 hours')::timestamp as vaqt_uzb,
       e.description,
       e.is_deleted,
       l.debit,
       (select a.name from accounts a where a.id = l.account_id) as modda,
       (select array_agg(a2.name)
          from entry_line l2 join accounts a2 on a2.id = l2.account_id
         where l2.entry_id = e.id and l2.credit > 0)              as kt_hisoblar,
       e.filial_ids
  from entry e
  join entry_line l on l.entry_id = e.id and l.debit > 0
 where e.created_at > now() - interval '6 hours'
   and l.debit = 249000
 order by e.created_at;
-- 5 qator chiqsa → SAQLANGAN (klient javobni ololmagan, xolos).
-- 10 qator → ikki marta bosilgan, ortiqchasini o'chirish kerak.
-- 0 qator → umuman yozilmagan, qayta kiritish kerak.


-- ############ 2-SO'ROV — oxirgi 6 soatdagi HAMMA yozuv (umumiy ko'rinish) ############
-- select e.id,
--        (e.created_at + interval '5 hours')::timestamp as vaqt_uzb,
--        e.description, e.source, e.is_deleted,
--        (select sum(l.debit) from entry_line l where l.entry_id = e.id) as summa,
--        (select count(*)     from entry_line l where l.entry_id = e.id) as satr
--   from entry e
--  where e.created_at > now() - interval '6 hours'
--  order by e.created_at desc
--  limit 100;


-- ############ 3-SO'ROV — takror yozuv bormi ############
-- select e.entry_date, e.description, l.debit,
--        count(*) as nechta,
--        array_agg(e.id order by e.created_at) as entry_idlar,
--        min((e.created_at + interval '5 hours')::timestamp) as birinchi,
--        max((e.created_at + interval '5 hours')::timestamp) as oxirgi
--   from entry e
--   join entry_line l on l.entry_id = e.id and l.debit > 0
--  where e.created_at > now() - interval '6 hours'
--    and e.is_deleted = false
--  group by e.entry_date, e.description, l.debit
-- having count(*) > 1
--  order by max(e.created_at) desc;
-- Takror chiqsa: ortiqchasini jurnal.html dan SOFT-DELETE (SQL delete EMAS).
