-- DIAG: Qarshi + ovqatlanish — limit nega to'lgan? (faqat o'qish)

-- 1) Qarshi filiallari
select id, code, name
  from accounts
 where kassa_turi = 'filial' and parent_id is null and coalesce(is_active, true)
   and name ilike '%arshi%'
 order by name;

-- 2) Shu oyda ovqat moddasiga QARSHI nomiga yozilgan xarajatlar (sarfning o'zi)
select e.entry_date,
       e.status,
       el.debit,
       a.code || ' ' || a.name                       as modda,
       coalesce(p.full_name, to_jsonb(e) ->> 'created_by') as kim,
       left(coalesce(e.description, ''), 60)         as izoh
  from entry e
  join entry_line el on el.entry_id = e.id and el.debit > 0
  join accounts a on a.id = el.account_id
                 and a.type = 'xarajat'
                 and a.name ilike '%ovqat%'
  left join profiles p on p.id::text = (to_jsonb(e) ->> 'created_by')
 where e.is_deleted = false
   and e.status in ('posted', 'pending')
   and date_trunc('month', e.entry_date) = date_trunc('month', (now() at time zone 'Asia/Tashkent')::date)
   and exists (select 1 from accounts f
                where f.id = any(e.filial_ids) and f.name ilike '%arshi%')
 order by e.entry_date desc;

-- 3) Jami sarf (yuqoridagi qatorlarning yig'indisi)
select coalesce(sum(el.debit), 0) as sarf_jami
  from entry e
  join entry_line el on el.entry_id = e.id and el.debit > 0
  join accounts a on a.id = el.account_id and a.type = 'xarajat' and a.name ilike '%ovqat%'
 where e.is_deleted = false
   and e.status in ('posted', 'pending')
   and date_trunc('month', e.entry_date) = date_trunc('month', (now() at time zone 'Asia/Tashkent')::date)
   and exists (select 1 from accounts f where f.id = any(e.filial_ids) and f.name ilike '%arshi%');

-- 4) Ovqat moddasiga rollar orqali berilgan limitlar (null = cheksiz)
select r.nom as rol, a.code || ' ' || a.name as modda, rm.limit_uzs
  from rbac_role r
  join rbac_role_modda rm on rm.role_id = r.id
  join accounts a on a.id = rm.account_id and a.name ilike '%ovqat%'
 where r.is_active
 order by rm.limit_uzs nulls first;

-- 5) Filial darajasidagi limit (standart_xarajat) — bo'lsa u override qiladi
select f.name as filial, a.code || ' ' || a.name as modda, sx.limit_uzs
  from standart_xarajat sx
  join accounts f on f.id = sx.filial_id
  join accounts a on a.id = sx.modda_id
 where f.name ilike '%arshi%' and a.name ilike '%ovqat%';
