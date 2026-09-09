-- =====================================================================
--  DIAG_TRANSFER_5_AVGUST.sql   (2026-09-09)
--  🟢 FAQAT O'QIYDI.  ✅ SUPABASE (Provodka) da RUN QILING.
--
--  SAVOL: 2026-08-08…08-12 kunlari sinxron tashlab yuborgan ~50 ta
--  transferning puli yozilganmi?
--  Nega muhim: ular n8n ning 14 kunlik oynasidan chiqib ketgan
--  (`oxirgi_at` = 2026-08-26 da urinish to'xtagan) — sinxron ularga
--  BOSHQA HECH QACHON qaytmaydi. Yozilmagan bo'lsa, pul abadiy yo'q.
-- =====================================================================

-- ⬇⬇⬇  QISQA JAVOB — avval shuni RUN qiling
select count(*) filter (where not yb) as yozilmagan,
       count(*) filter (where yb)     as yozilgan,
       min(received_at) filter (where not yb) as eng_eski_yozilmagan,
       max(received_at) filter (where not yb) as eng_yangi_yozilmagan
  from (
    select d.received_at,
           exists (select 1 from entry e
                    where e.ext_ref like 'aros_tr:' || d.tr_id || ':%'
                      and e.is_deleted = false) as yb
      from aros_transfer_dropped d
     where d.hal_qilindi = false
  ) x;
-- ⬆⬆⬆
--  «yozilmagan = 0»  -> avgust backlogi TIKLANGAN, xavotir yo'q.
--  «yozilmagan > 0»  -> o'sha transferlar puli HALI HAM yo'q -> pastdagi
--                       so'rov ro'yxatini bering, tiklash skriptini yozaman.


-- ⬇⬇⬇  TO'LIQ RO'YXAT (yuqorida yozilmagan > 0 chiqsa)
select d.tr_id,
       d.received_at,
       d.payload ->> 'kimdan' as kimdan,
       d.payload ->> 'kimga'  as kimga,
       exists (select 1 from entry e
                where e.ext_ref like 'aros_tr:' || d.tr_id || ':%'
                  and e.is_deleted = false) as yozuv_bor
  from aros_transfer_dropped d
 where d.hal_qilindi = false
 order by (exists (select 1 from entry e
                    where e.ext_ref like 'aros_tr:' || d.tr_id || ':%'
                      and e.is_deleted = false)),
          d.received_at;
-- ⬆⬆⬆
