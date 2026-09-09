-- =====================================================================
--  DIAG_TRANSFER_6_AVGUST_TOGRI.sql   (2026-09-09)
--  🟢 FAQAT O'QIYDI.  ✅ SUPABASE (Provodka) da RUN QILING.
--
--  🔴 DIAG_TRANSFER_5 NOTO'G'RI EDI — u faqat `aros_tr:` naqshini
--     qidirardi. Aslida IKKI naqsh bor:
--        aros_tr:<id>:<tur>       — oddiy sinxron yozuvi
--        aros_tr_fix:<id>:<tur>   — tuzatish/tiklash skriptlari
--                                   (PROVODKA_TRANSFER_TUZATISH.sql,
--                                    PROVODKA_TRANSFER_TIKLASH_0812.sql)
--     Shuning uchun «88 yozilmagan» raqami SHISHIRILGAN: tuzatilganlari
--     ham yozilmagan bo'lib chiqqan.
-- =====================================================================


-- ⬇⬇⬇  1) TO'G'RI QISQA JAVOB — ikkala naqsh hisobga olingan
select count(*)                                              as jami_drop_qatori,
       count(*) filter (where sync_bor)                      as sync_yozgan,
       count(*) filter (where fix_bor and not sync_bor)      as tuzatish_yozgan,
       count(*) filter (where not sync_bor and not fix_bor)  as haqiqatan_yozilmagan,
       min(received_at) filter (where not sync_bor and not fix_bor) as eng_eski,
       max(received_at) filter (where not sync_bor and not fix_bor) as eng_yangi
  from (
    select d.tr_id, d.received_at,
           exists (select 1 from entry e
                    where e.ext_ref like 'aros_tr:' || d.tr_id || ':%'
                      and e.is_deleted = false) as sync_bor,
           exists (select 1 from entry e
                    where e.ext_ref like 'aros_tr_fix:' || d.tr_id || ':%'
                      and e.is_deleted = false) as fix_bor
      from aros_transfer_dropped d
     where d.hal_qilindi = false
  ) x;
-- ⬆⬆⬆
--  `haqiqatan_yozilmagan = 0`  -> avgust backlogi TO'LIQ yopilgan.
--  `> 0`                        -> 2-so'rov ro'yxatini bering.


-- ⬇⬇⬇  2) HAQIQATAN yozilmaganlar ro'yxati
select d.tr_id,
       d.received_at,
       d.payload ->> 'kimdan' as kimdan,
       d.payload ->> 'kimga'  as kimga
  from aros_transfer_dropped d
 where d.hal_qilindi = false
   and not exists (select 1 from entry e
                    where e.ext_ref like 'aros_tr:' || d.tr_id || ':%'
                      and e.is_deleted = false)
   and not exists (select 1 from entry e
                    where e.ext_ref like 'aros_tr_fix:' || d.tr_id || ':%'
                      and e.is_deleted = false)
 order by d.received_at;
-- ⬆⬆⬆


-- ⬇⬇⬇  3) NAZORAT: shu davrda 9010 (savdo tushumi) ga qancha
--        «to'g'irlash» yozuvi tushgan. PROVODKA_TRANSFER_TUZATISH.sql
--        aynan `Dt markaziy tur child / Kt 9010` yozadi.
--        Bu — avgust backlogining bir qismi ALLAQACHON boshqa yo'l bilan
--        yopilganini ko'rsatadi.
select date(e.entry_date) as kun,
       count(*)           as yozuv,
       sum(l.debit)       as jami_debit
  from entry e
  join entry_line l on l.entry_id = e.id and l.debit > 0
 where e.ext_ref like 'aros_tr_fix:%'
   and e.is_deleted = false
 group by 1
 order by 1;
-- ⬆⬆⬆
