-- ============================================================
-- DIAGNOSTIKA: bitta hodim kassasining TO'LIQ harakati
-- Faqat SELECT — hech narsani o'zgartirmaydi. Xavfsiz.
-- Kassa kodini o'zgartirish: pastdagi '5389' ni almashtiring.
-- ============================================================

-- 1) Yakuniy qoldiq (kassa kartasi shu raqamni ko'rsatadi)
--    parent + hamma bola-hisoblar (naqd/click/payme/valyuta)
select a.code, a.name,
       sum(l.debit)          as jami_kirim,
       sum(l.credit)         as jami_chiqim,
       sum(l.debit-l.credit) as qoldiq,
       count(*)              as satr_soni
from entry_line l
join entry e    on e.id = l.entry_id
join accounts a on a.id = l.account_id
where (a.code = '5389'
       or a.parent_id = (select id from accounts where code = '5389'))
  and e.status = 'posted' and e.is_deleted = false
group by a.code, a.name
order by a.code;

-- 2) HAR BIR harakat — sana cheklovisiz, tur filtri yo'q, o'chirilganlari ham
--    `qoldiq` ustuni yig'ilib boradi: qaysi qatorda raqam sizning hisobingizdan
--    ajralib ketganini shu ustundan ko'rasiz.
select e.entry_date,
       a.code, a.name,
       l.debit, l.credit,
       case when e.is_deleted then 'O''CHIRILGAN'
            when e.status <> 'posted' then upper(e.status)
            else '' end                       as holat,
       e.source, e.description,
       sum(case when e.status = 'posted' and e.is_deleted = false
                then l.debit - l.credit else 0 end)
         over (order by e.entry_date, e.created_at, l.id
               rows between unbounded preceding and current row) as qoldiq,
       e.id as entry_id
from entry_line l
join entry e    on e.id = l.entry_id
join accounts a on a.id = l.account_id
where a.code = '5389'
   or a.parent_id = (select id from accounts where code = '5389')
order by e.entry_date, e.created_at, l.id;
