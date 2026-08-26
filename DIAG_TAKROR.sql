-- ============================================================
-- DIAG_TAKROR.sql  —  2026-08-26
-- HODISA: 2026-08-25, ikki bir xil yozuv: 5351 -> 9423 (Oziq-ovqat), 747 000 so'm.
--   #7  "MAJLISDAN KIYIN O'TIRISH"            (Asilbek 26.08 da o'chirgan)
--   #8  "TOSHKENT RESTARANDA MAJLISDAN KIYIN O'TIRISH"
-- SAVOL: tizim ikki marta urdimi (avtomat takror) yoki hodim qo'lda ikki marta
--        kiritdimi? `ext_ref` (takror himoyasi) ishladimi?
--
-- Faqat O'QIYDI — hech narsani o'zgartirmaydi. So'rovlarni BITTALAB RUN qiling.
-- ============================================================


-- ############ 1-SO'ROV — ikki yozuvning TO'LIQ pasporti ############
-- Bu asosiy so'rov. Javob shu yerdan chiqadi.
select e.id,
       e.entry_date,
       (e.created_at + interval '5 hours')::timestamp        as yozilgan_uzb,
       e.ext_ref,
       case
         when e.ext_ref is null                then 'YOQ (himoyasiz yol)'
         when e.ext_ref like 'hodim:%'         then 'hodim.html'
         when e.ext_ref like 'tk-%'            then 'provodka / professional (zaxira token)'
         when e.ext_ref ~ '^[0-9a-fA-F-]{36}$' then 'provodka / professional (uuid token)'
         else 'boshqa: ' || left(e.ext_ref, 24)
       end                                                   as qaysi_yol,
       e.source,
       e.status,
       ijrochi_nomi(to_jsonb(e) ->> 'created_by')            as kim_yozdi,
       (to_jsonb(e) ->> 'created_by')                        as kim_yozdi_xom,
       e.description,
       e.is_deleted,
       e.deleted_by_name,
       (e.deleted_at + interval '5 hours')::timestamp        as ochirilgan_uzb,
       e.edited_by_name,
       e.filial_ids,
       (select count(*)      from entry_line l where l.entry_id = e.id) as satr_soni,
       (select sum(l.debit)  from entry_line l where l.entry_id = e.id) as summa
  from entry e
 where e.entry_date = date '2026-08-25'
   and exists (select 1 from entry_line l join accounts a on a.id = l.account_id
                where l.entry_id = e.id and a.code in ('9423','5351'))
 order by e.created_at;
--
-- QANDAY O'QISH KERAK (ikki qatorni yonma-yon solishtiring):
--
--   A) ext_ref IKKALASIDA HAM BOR va BIR XIL
--      -> bo'lishi MUMKIN EMAS: `entry_ext_ref_uniq` unikal indeksi ikkinchisini
--         yozdirmasdi. Shunday chiqsa — indeks yo'q (4-so'rovni RUN qiling).
--
--   B) ext_ref IKKALASIDA HAM BOR, lekin BOSHQA-BOSHQA   <-- eng kutilgan natija
--      -> takror himoyasi ISHLADI, lekin bu holatda u ISHLASHI SHART EMAS EDI.
--         Token forma MAZMUNIGA bog'langan (summa/modda/kassa/filial), va
--         birinchi saqlash MUVAFFAQIYATLI tugagach token bo'shatiladi —
--         keyingi saqlash YANGI token oladi. Ya'ni ikkinchi yozuv "yangi
--         xarajat" deb qabul qilingan. Izoh matni ham boshqa ("TOSHKENT
--         RESTARANDA" qo'shilgan) — demak forma QAYTA to'ldirilgan.
--         >>> `yozilgan_uzb` farqiga qarang (2-so'rov aniq soniyani beradi):
--             farq < 5 soniya    -> ikki marta bosilgan (double-click)
--             farq 10s .. 5 daq  -> "saqlanmadi" deb o'ylab qaytadan kiritgan
--             farq > 5 daqiqa    -> alohida ikki kiritish (qo'l xatosi)
--
--   C) ext_ref BITTASIDA YO'Q (null)
--      -> o'sha yozuv himoyasiz yo'ldan kelgan (eski zaxira `saveEski`, n8n
--         sinxron yoki `provodka_yoz` RPC topilmagan holat). Qaysi yo'l —
--         `source` va `kim_yozdi` ustunlaridan ko'rinadi.
--
--   D) IKKALASIDA HAM YO'Q -> ikkalasi ham himoyasiz yo'ldan. 5-so'rovni RUN qiling.


-- ############ 2-SO'ROV — ikki yozuv orasidagi ANIQ farq ############
-- select
--   min((e.created_at + interval '5 hours')::timestamp) as birinchi_uzb,
--   max((e.created_at + interval '5 hours')::timestamp) as ikkinchi_uzb,
--   extract(epoch from (max(e.created_at) - min(e.created_at)))::int as farq_soniya,
--   count(*)                                            as nechta,
--   count(distinct e.ext_ref)                           as har_xil_token,
--   count(*) filter (where e.ext_ref is null)           as tokensiz,
--   count(distinct (to_jsonb(e) ->> 'created_by'))      as nechta_odam,
--   array_agg(e.description order by e.created_at)      as izohlar
-- from entry e
-- where e.entry_date = date '2026-08-25'
--   and exists (select 1 from entry_line l join accounts a on a.id = l.account_id
--                where l.entry_id = e.id and a.code = '9423' and l.debit = 747000);
--
-- farq_soniya < 5   -> ikki marta bosish. FON BLOK aynan shuni to'sadi.
-- farq_soniya > 60  -> qo'lda qayta kiritish. Fon blok YORDAM BERMAYDI —
--                      "yaqinda ayni shunday xarajat yozilgan" ogohlantirishi kerak.


-- ############ 3-SO'ROV — satrlar (pul qayerdan qayerga ketgan) ############
-- select e.id,
--        (e.created_at + interval '5 hours')::timestamp as yozilgan_uzb,
--        a.code, a.name, l.debit, l.credit, l.fc_amount
--   from entry e
--   join entry_line l on l.entry_id = e.id
--   join accounts a   on a.id = l.account_id
--  where e.entry_date = date '2026-08-25'
--    and exists (select 1 from entry_line l2 join accounts a2 on a2.id = l2.account_id
--                 where l2.entry_id = e.id and a2.code = '9423' and l2.debit = 747000)
--  order by e.created_at, l.debit desc;


-- ############ 4-SO'ROV — takror himoyasi umuman O'RNATILGANMI ############
-- select i.relname as indeks, x.indisunique as unikalmi,
--        pg_get_indexdef(x.indexrelid) as tarif
--   from pg_index x
--   join pg_class t on t.oid = x.indrelid
--   join pg_class i on i.oid = x.indexrelid
--  where t.relname = 'entry'
--  order by x.indisunique desc, i.relname;
-- `entry_ext_ref_uniq` + unikalmi = true bo'lishi SHART.
-- Bo'lmasa: PROVODKA_EXT_REF.sql RUN qilinmagan -> takror himoyasi UMUMAN YO'Q.


-- ############ 5-SO'ROV — ext_ref siz yozuvlar ulushi (himoyasiz yo'llar) ############
-- select date_trunc('day', e.created_at + interval '5 hours')::date as kun,
--        count(*)                                        as jami,
--        count(*) filter (where e.ext_ref is null)       as tokensiz,
--        round(100.0 * count(*) filter (where e.ext_ref is null) / count(*), 1) as tokensiz_foiz,
--        array_agg(distinct e.source)                    as manbalar
--   from entry e
--  where e.created_at > now() - interval '14 days'
--  group by 1 order by 1 desc;
-- `source='manual'` bo'lgan tokensiz yozuvlar ko'p bo'lsa -> qaysidir sahifa
-- himoyasiz zaxira yo'ldan yozyapti, buni alohida tuzatish kerak.


-- ############ 6-SO'ROV — BUTUN BAZADA yana qancha shunday takror bor ############
-- Bir kunda AYNI Dt+Kt+summa juftligi 2+ marta (faqat o'chirilmaganlari).
-- select t.entry_date, t.dt, t.kt, t.summa,
--        count(*)                                            as nechta,
--        array_agg(t.id order by t.created_at)               as entry_idlar,
--        array_agg((t.created_at + interval '5 hours')::time order by t.created_at) as vaqtlar,
--        array_agg(coalesce(t.ext_ref, 'YOQ') order by t.created_at)                as tokenlar,
--        extract(epoch from (max(t.created_at) - min(t.created_at)))::int           as farq_soniya
--   from (
--     select e.id, e.entry_date, e.created_at, e.ext_ref,
--            (select a.code from entry_line l join accounts a on a.id = l.account_id
--              where l.entry_id = e.id and l.debit  > 0 order by a.code limit 1) as dt,
--            (select a.code from entry_line l join accounts a on a.id = l.account_id
--              where l.entry_id = e.id and l.credit > 0 order by a.code limit 1) as kt,
--            (select sum(l.debit) from entry_line l where l.entry_id = e.id)     as summa
--       from entry e
--      where e.is_deleted = false
--        and e.status = 'posted'
--        and e.source = 'manual'
--        and e.created_at > now() - interval '60 days'
--   ) t
--  group by t.entry_date, t.dt, t.kt, t.summa
-- having count(*) > 1
--  order by t.entry_date desc, farq_soniya asc;
--
-- farq_soniya bo'yicha tasnif:
--   < 5      -> double-click (fon blok yopadi)
--   5..300   -> "saqlanmadi" deb qayta kiritish (ogohlantirish kerak)
--   > 300    -> haqiqiy ikki xarajat bo'lishi ham mumkin — ko'z bilan tekshiring
--
-- 🔴 Chiqqan takrorlarni SQL bilan O'CHIRMANG — jurnal.html dan soft-delete qiling
--    (`is_deleted=true`, kim o'chirgani yozilib qoladi).


-- ############ 7-SO'ROV — o'sha hodimning o'sha kundagi hamma yozuvi ############
-- 1-so'rovdagi `kim_yozdi_xom` qiymatini pastga qo'ying.
-- select e.id, e.entry_date,
--        (e.created_at + interval '5 hours')::timestamp as yozilgan_uzb,
--        e.ext_ref, e.description, e.is_deleted,
--        (select sum(l.debit) from entry_line l where l.entry_id = e.id) as summa
--   from entry e
--  where (to_jsonb(e) ->> 'created_by') = 'BU_YERGA_kim_yozdi_xom'
--    and e.created_at >= timestamp '2026-08-25 00:00' - interval '5 hours'
--    and e.created_at <  timestamp '2026-08-26 00:00' - interval '5 hours'
--  order by e.created_at;
-- Ketma-ket yozuvlar orasidagi vaqtdan hodimning ish ritmi ko'rinadi: boshqa
-- yozuvlar ham 1-2 daqiqada ketma-ket bo'lsa -> qo'lda ishlagan, tizim urmagan.
