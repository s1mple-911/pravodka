-- =====================================================================
--  PROVODKA_TRANSFER_DIAG.sql — transfer sync "tushib qolgan" transferlar
--  DIAGNOSTIKASI
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).
--
--  🟢 BU FAYL FAQAT O'QIYDI. Hech narsa yozmaydi, o'zgartirmaydi,
--     o'chirmaydi. Bitta ham insert/update/delete/create yo'q.
--     Pul harakati YO'Q — xotirjam RUN qiling.
--
--  ⚠️ HAR SO'ROVNI ALOHIDA RUN QILING. Supabase SQL editorida
--     so'rov matnini SICHQONCHA bilan belgilab (select) "Run" bosing.
--     Hammasini birdan RUN qilsangiz faqat oxirgi natija ko'rinadi.
--
--  Tartib: 1 -> 2 -> 4 -> 3 -> 5 -> 6 -> 7 -> 8 (Aros tomoni).
--  Eng qimmatlisi — 4-BO'LIM (id teshiklari): Aros'siz ham qaysi
--  transfer tushib qolganini ko'rsatadi.
--
--  Fon (nega tushib qolishi mumkin — PROVODKA_TRANSFER.sql):
--    • cutoff = daftar Aros bilan OXIRGI marta tenglashtirilgan payt
--      (aros_sync_state.last_balans_at yoki oxirgi delta yozuvi).
--      received_at <= cutoff bo'lgan transfer YOZILMAYDI (861-qator).
--      Cutoff har 30 daqiqada oldinga suriladi -> kech kelgan/kech
--      "received" bo'lgan transfer abadiy tushib qoladi.
--    • kassa nomi topilmasa (aros_kassa_topish -> ok:false) transfer
--      o'tkazib yuboriladi — IZ FAQAT RPC javobida, bazada QOLMAYDI.
--    • status <> 'received' bo'lsa o'tkaziladi; keyin 'received'
--      bo'lganda cutoff undan oldinda bo'lsa — abadiy tushadi.
-- =====================================================================



-- #####################################################################
--  1-BO'LIM — SYNC HOLATI: cutoff qayerda turibdi
-- #####################################################################

-- ---------------------------------------------------------------------
-- 1.1  Cutoff (eng muhim raqam)
--      Nimani ko'rsatadi: transfer sync AYNAN shu funksiyadan cutoff
--      oladi. "cutoff" dan OLDINGI (yoki teng) received_at li transfer
--      hech qachon yozilmaydi.
--      MUAMMO belgisi: "cutoff" bugungi/kechagi sana bo'lsa — undan
--      oldingi hamma tushib qolgan transfer ABADIY tushib qolgan
--      (o'z-o'zidan tiklanmaydi). "cutoff" null bo'lsa — RPC umuman
--      hech narsa yozmaydi (ok:false).
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select jsonb_pretty(aros_transfer_cutoff());
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 1.2  aros_sync_state — muhr jadvali (bitta qator, id=1)
--      last_balans_at  = cutoff manbai
--      last_transfer_at= transfer sync oxirgi marta qachon ishlagani
--      MUAMMO belgisi: last_transfer_at last_balans_at dan ANCHA orqada
--      bo'lsa -> transfer node ishlamayapti, balans esa ishlayapti
--      (ya'ni cutoff oldinga ketyapti, transferlar esa yozilmayapti —
--      eng yomon kombinatsiya).
--      last_transfer_at bir necha soat eski bo'lsa -> workflow o'chgan.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select id,
       last_balans_at   at time zone 'Asia/Tashkent' as balans_muhri_tosh,
       last_transfer_at at time zone 'Asia/Tashkent' as transfer_muhri_tosh,
       round(extract(epoch from (now() - last_balans_at))   / 60) as balans_necha_daqiqa_oldin,
       round(extract(epoch from (now() - last_transfer_at)) / 60) as transfer_necha_daqiqa_oldin
  from aros_sync_state
 where id = 1;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 1.3  sync_state.transfers_from — ESKI mexanizm qiymati
--      Nimani ko'rsatadi: eski (o'chirilgan) sync_received_transfers
--      qoldig'i. Hozirgi kod uni ISHLATMAYDI — faqat ma'lumot uchun.
--      MUAMMO belgisi: yo'q. Agar jadval yo'q bo'lsa xato beradi —
--      normal, keyingisiga o'ting.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select * from sync_state;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 1.4  Delta (balans) sync qachon-qachon yozgan — oxirgi 20 ta
--      Nimani ko'rsatadi: cutoff shu ro'yxatning eng oxirgisidan (yoki
--      1.2 dagi muhrdan) olinadi.
--      MUAMMO belgisi: har 30 daqiqada yozuv bor, ya'ni cutoff
--      to'xtovsiz oldinga ketyapti — transfer bir sikl kechiksa yo'qoladi.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select created_at at time zone 'Asia/Tashkent' as yozilgan_tosh,
       entry_date, description
  from entry
 where source = 'aros_auto' and created_by = 'aros_sync'
 order by created_at desc
 limit 20;
-- ⬆⬆⬆



-- #####################################################################
--  2-BO'LIM — TRANSFER YOZUVLARI: umumiy manzara
-- #####################################################################

-- ---------------------------------------------------------------------
-- 2.1  Jami soni, eng eski / eng yangi sana
--      Nimani ko'rsatadi: sync umuman qancha yozgan.
--      MUAMMO belgisi: "oxirgi_sana" bugundan bir necha kun orqada
--      bo'lsa — sync to'xtagan yoki cutoff hammasini to'sayapti.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select count(*)                                   as jami_yozuv,
       count(*) filter (where is_deleted)         as ochirilgan,
       count(distinct split_part(ext_ref, ':', 2)) as transfer_soni,
       min(entry_date)                            as eng_eski_sana,
       max(entry_date)                            as oxirgi_sana,
       max(created_at) at time zone 'Asia/Tashkent' as oxirgi_yozilgan_tosh
  from entry
 where ext_ref like 'aros_tr:%';
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.2  Oxirgi 30 kun — kunlik taqsimot (tur bo'yicha)
--      Nimani ko'rsatadi: har kuni nechta transfer yozuvi, qaysi turda.
--      MUAMMO belgisi: bir kun umuman yo'q yoki keskin kam bo'lsa;
--      naqd bor, click yo'q kabi bir tomonlama holat.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select e.entry_date,
       count(*)                                                     as yozuvlar,
       count(*) filter (where split_part(e.ext_ref, ':', 3) = 'cash')       as naqd,
       count(*) filter (where split_part(e.ext_ref, ':', 3) = 'click')      as click,
       count(*) filter (where split_part(e.ext_ref, ':', 3) = 'payme')      as payme,
       count(*) filter (where split_part(e.ext_ref, ':', 3) = 'dollar_usd') as usd,
       sum(l.debit)                                                  as jami_uzs
  from entry e
  join entry_line l on l.entry_id = e.id and l.debit > 0
 where e.ext_ref like 'aros_tr:%'
   and e.entry_date >= (now() at time zone 'Asia/Tashkent')::date - 30
 group by e.entry_date
 order by e.entry_date desc;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.3  ⭐ FILIAL bo'yicha: qaysi kassadan transfer KELMAGAN
--      Nimani ko'rsatadi: har faol filial kassasi uchun nechta transfer
--      yozuvi bor va oxirgisi qachon.
--      MUAMMO belgisi: pul jo'natishi aniq bo'lgan filialda
--      "transfer_yozuvlari = 0" yoki "oxirgi_sana" ancha eski ->
--      aros_kassa_topish o'sha filial NOMINI topa olmayapti
--      (aros_title / name mos emas). Bu jimgina tushish sababi.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select k.code, k.name, k.kassa_turi, k.filial_ref, k.aros_title,
       count(distinct e.id)                                   as transfer_yozuvlari,
       count(distinct e.id) filter (where l.credit > 0)       as jonatgan,
       count(distinct e.id) filter (where l.debit  > 0)       as qabul_qilgan,
       max(e.entry_date)                                      as oxirgi_sana,
       case when count(e.id) = 0
            then '⬅️ HECH QACHON transfer yozilmagan — nom bog''lanishini tekshiring'
            else '' end                                       as belgi
  from accounts k
  left join accounts c on c.parent_id = k.id and c.section = 'pul'
  left join entry_line l on l.account_id = c.id
  left join entry e on e.id = l.entry_id and e.ext_ref like 'aros_tr:%'
 where k.section = 'pul' and k.is_active and k.parent_id is null
   and coalesce(k.kassa_turi, '') in ('filial', 'markaziy')
 group by k.code, k.name, k.kassa_turi, k.filial_ref, k.aros_title
 order by count(distinct e.id), k.code;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.4  Nomi bog'lanmagan kassalar (aros_kassa_topish uchun xavf)
--      Nimani ko'rsatadi: aros_title bo'sh bo'lgan yoki nomi
--      normallashtirilganda BOSHQA kassa bilan bir xil chiqadigan
--      kassalar.
--      MUAMMO belgisi: "nechta_bir_xil > 1" — aros_kassa_topish
--      ATAYLAB null qaytaradi (ikki moslik) va transfer tushadi.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select a.code, a.name, a.kassa_turi, a.filial_ref, a.aros_title,
       aros_nom_norm(coalesce(a.aros_title, a.name)) as normal_shakl,
       count(*) over (partition by aros_nom_norm(coalesce(a.aros_title, a.name))) as nechta_bir_xil,
       case when a.aros_title is null then '⚠️ aros_title bo''sh (faqat name bilan topiladi)' else '' end as belgi
  from accounts a
 where a.section = 'pul' and a.is_active and a.parent_id is null
   and coalesce(a.currency, 'UZS') = 'UZS'
   and coalesce(a.kassa_turi, '') <> 'xarajat_guruh'
 order by nechta_bir_xil desc, a.code;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.5  Tur child'lari to'liqmi (Dt/Kt topilmasa transfer tushadi)
--      Nimani ko'rsatadi: har kassada naqd/click/payme/USD bola-hisobi
--      bormi. aros_tur_hisob() shulardan birini topa olmasa o'sha TUR
--      yozilmaydi (transferning bir qismi tushadi).
--      MUAMMO belgisi: turlar ro'yxatida naqd/click/payme dan biri yo'q.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select k.code, k.name, k.kassa_turi,
       string_agg(coalesce(c.pul_turi, c.currency), ', ' order by coalesce(c.pul_turi, c.currency)) as turlar,
       count(c.id) as child_soni,
       case when count(c.id) < 3 then '⬅️ TUR YETISHMAYDI' else '' end as belgi
  from accounts k
  left join accounts c on c.parent_id = k.id and c.is_active and c.section = 'pul'
                      and (c.pul_turi in ('naqd','click','payme') or c.currency = 'USD')
 where k.section = 'pul' and k.is_active and k.parent_id is null
   and coalesce(k.kassa_turi, '') in ('filial','markaziy')
 group by k.code, k.name, k.kassa_turi
 order by count(c.id), k.code;
-- ⬆⬆⬆



-- #####################################################################
--  3-BO'LIM — SANA TESHIKLARI (oxirgi 60 kun)
-- #####################################################################

-- ---------------------------------------------------------------------
-- 3.1  Har kunda nechta transfer yozilgan; 0 bo'lgan kunlar belgilangan
--      Nimani ko'rsatadi: qaysi kunlar umuman transfersiz o'tgan.
--      MUAMMO belgisi: ish kuni bo'lib 0 chiqsa (yakshanba/bayram
--      bo'lmasa) — o'sha kuni sync ishlamagan yoki hammasini cutoff
--      to'sgan. Ketma-ket bir necha 0 kun — workflow o'chgan davr.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select d::date                                as kun,
       to_char(d, 'Dy')                       as hafta_kuni,
       coalesce(x.yozuvlar, 0)                as yozuvlar,
       coalesce(x.transferlar, 0)             as har_xil_transfer,
       coalesce(x.jami_uzs, 0)                as jami_uzs,
       case when coalesce(x.yozuvlar, 0) = 0 then '⬅️ 0 — TEKSHIRING' else '' end as belgi
  from generate_series((now() at time zone 'Asia/Tashkent')::date - 59,
                       (now() at time zone 'Asia/Tashkent')::date,
                       interval '1 day') d
  left join (
        select e.entry_date,
               count(*)                                    as yozuvlar,
               count(distinct split_part(e.ext_ref, ':', 2)) as transferlar,
               sum(l.debit)                                as jami_uzs
          from entry e
          join entry_line l on l.entry_id = e.id and l.debit > 0
         where e.ext_ref like 'aros_tr:%'
         group by e.entry_date
       ) x on x.entry_date = d::date
 order by d desc;
-- ⬆⬆⬆



-- #####################################################################
--  4-BO'LIM — ⭐⭐ ID TESHIKLARI (eng qimmatli so'rov)
-- #####################################################################
--  ext_ref = 'aros_tr:<Aros transfer id>:<tur>'. Id lar Aros'da ketma-ket
--  o'sadi. Demak yozilgan id lar orasidagi bo'shliq = Provodka ko'rmagan
--  transferlar. Aros'ga kirmasdan "qaysilari tushgan"ni shu ko'rsatadi.
--
--  ⚠️ Har teshik xato degani EMAS: o'sha id boshqa kassalar orasidagi
--     transfer, canceled, yoki hali received bo'lmagan bo'lishi mumkin.
--     Shuning uchun teshiklar 8-BO'LIMdagi Aros so'rovi bilan
--     solishtiriladi. Lekin KATTA/KO'P teshik — aniq muammo belgisi.

-- ---------------------------------------------------------------------
-- 4.1  Teshiklar RO'YXATI (oraliq shaklida, ixcham)
--      Nimani ko'rsatadi: yozilgan id lar orasidagi har bo'shliq:
--      qaysi id dan qaysi id gacha, nechta id yo'q, atrofdagi sanalar.
--      MUAMMO belgisi: "yoq_id_soni" katta bo'lgan qatorlar; ayniqsa
--      "oldingi_sana" va "keyingi_sana" bir necha kun farq qilsa
--      (= o'sha davrda sync uzilgan).
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
with tr as (
  select (split_part(ext_ref, ':', 2))::bigint as tr_id,
         min(entry_date)                       as sana
    from entry
   where ext_ref ~ '^aros_tr:[0-9]+:'
   group by 1
),
seq as (
  select tr_id, sana,
         lead(tr_id) over (order by tr_id) as keyingi_id,
         lead(sana)  over (order by tr_id) as keyingi_sana
    from tr
)
select tr_id                    as oldingi_yozilgan_id,
       sana                     as oldingi_sana,
       tr_id + 1                as yoq_id_boshi,
       keyingi_id - 1           as yoq_id_oxiri,
       keyingi_id - tr_id - 1   as yoq_id_soni,
       keyingi_id               as keyingi_yozilgan_id,
       keyingi_sana             as keyingi_sana,
       keyingi_sana - sana      as kun_farqi
  from seq
 where keyingi_id - tr_id > 1
 order by tr_id desc;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 4.2  Teshikdagi HAR BIR id (bittalab, oxirgi 500 tasi)
--      Nimani ko'rsatadi: yo'q id larning aniq ro'yxati + o'sha id uchun
--      TO'G'IRLASH yozuvi ('aros_tr_fix:') bormi.
--      MUAMMO belgisi: "tuzatish_bormi = yo'q" bo'lgan id lar — ular
--      hech qayerda hisobga olinmagan. Shu ro'yxatni Aros bilan
--      solishtiring (8-BO'LIM).
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
with tr as (
  select distinct (split_part(ext_ref, ':', 2))::bigint as tr_id
    from entry
   where ext_ref ~ '^aros_tr:[0-9]+:'
),
chegara as (select min(tr_id) as eng_kichik, max(tr_id) as eng_katta from tr),
hamma as (
  select generate_series(chegara.eng_kichik, chegara.eng_katta) as tr_id
    from chegara
)
select h.tr_id as yoq_transfer_id,
       case when exists (select 1 from entry
                          where ext_ref like 'aros_tr_fix:' || h.tr_id || ':%')
            then 'ha (aros_tr_fix)' else 'yo''q' end as tuzatish_bormi
  from hamma h
  left join tr on tr.tr_id = h.tr_id
 where tr.tr_id is null
 order by h.tr_id desc
 limit 500;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 4.3  Teshiklar statistikasi (bitta qator — umumiy og'irlik)
--      Nimani ko'rsatadi: eng kichik/eng katta id, oralig'idagi jami id,
--      yozilgan id, tushib qolgan id soni va foizi.
--      MUAMMO belgisi: "tushgan_foiz" bir necha foizdan katta bo'lsa.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
with tr as (
  select distinct (split_part(ext_ref, ':', 2))::bigint as tr_id
    from entry
   where ext_ref ~ '^aros_tr:[0-9]+:'
)
select min(tr_id)                                       as eng_kichik_id,
       max(tr_id)                                       as eng_katta_id,
       max(tr_id) - min(tr_id) + 1                      as oraliqdagi_jami_id,
       count(*)                                         as yozilgan_id,
       max(tr_id) - min(tr_id) + 1 - count(*)           as tushgan_id,
       round(100.0 * (max(tr_id) - min(tr_id) + 1 - count(*))
             / nullif(max(tr_id) - min(tr_id) + 1, 0), 1) as tushgan_foiz
  from tr;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 4.4  Yozilgan transferlarning TUR to'liqligi
--      Nimani ko'rsatadi: har transfer id uchun qaysi turlar yozilgan.
--      MUAMMO belgisi: bitta id da faqat 'cash' bo'lib, Aros'da click
--      ham bo'lgan bo'lsa — transferning YARMI tushgan (bu holat
--      4.1/4.2 da KO'RINMAYDI, chunki id yozilgan hisoblanadi).
--      Aros bilan solishtirish uchun 8-BO'LIMga qarang.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select (split_part(e.ext_ref, ':', 2))::bigint as tr_id,
       min(e.entry_date)                       as sana,
       string_agg(split_part(e.ext_ref, ':', 3), ', ' order by split_part(e.ext_ref, ':', 3)) as turlar,
       count(*)                                as tur_soni,
       sum(l.debit)                            as jami_uzs
  from entry e
  join entry_line l on l.entry_id = e.id and l.debit > 0
 where e.ext_ref ~ '^aros_tr:[0-9]+:'
   and e.entry_date >= (now() at time zone 'Asia/Tashkent')::date - 60
 group by 1
 order by 1 desc
 limit 300;
-- ⬆⬆⬆



-- #####################################################################
--  5-BO'LIM — YARIM YOZILGAN / BUZILGAN YOZUVLAR
-- #####################################################################

-- ---------------------------------------------------------------------
-- 5.1  Satr soni 2 emas yoki Dt <> Kt bo'lgan transfer yozuvlari
--      Nimani ko'rsatadi: yozuv boshlanib, satrlari to'liq tushmagan
--      holat (yetim sarlavha yoki bir satrli yozuv).
--      MUAMMO belgisi: BO'SH chiqishi SHART. Bitta qator chiqsa ham —
--      ma'lumot buzilgan, darhol xabar bering.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select e.id, e.entry_date, e.ext_ref, e.description, e.is_deleted,
       count(l.id)                as satr_soni,
       coalesce(sum(l.debit), 0)  as jami_dt,
       coalesce(sum(l.credit), 0) as jami_kt
  from entry e
  left join entry_line l on l.entry_id = e.id
 where e.ext_ref like 'aros_tr:%'
 group by e.id, e.entry_date, e.ext_ref, e.description, e.is_deleted
having count(l.id) <> 2
    or coalesce(sum(l.debit), 0) <> coalesce(sum(l.credit), 0)
 order by e.entry_date desc;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 5.2  Transfer yozuvida 9010 (savdo tushumi) bormi
--      Nimani ko'rsatadi: transfer yozuvi hech qachon 9010 ga tegmasligi
--      kerak (u ikki kassa orasidagi harakat).
--      MUAMMO belgisi: BO'SH chiqishi SHART. Qator chiqsa — transfer
--      "tushum" bo'lib yozilgan, ya'ni pul ikki marta sanalgan bo'lishi
--      mumkin.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select e.ext_ref, e.entry_date, a.code, a.name, l.debit, l.credit
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a   on a.id = l.account_id
 where e.ext_ref like 'aros_tr:%'
   and a.code = '9010'
 order by e.entry_date desc;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 5.3  Takrorlangan ext_ref (ikki marta yozilgan pul)
--      Nimani ko'rsatadi: bitta transfer+tur ikki marta yozilganmi.
--      MUAMMO belgisi: BO'SH chiqishi SHART (ext_ref UNIQUE). Qator
--      chiqsa — unique indeks yo'q va PUL IKKI MARTA yozilgan.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select ext_ref, count(*) as nechta
  from entry
 where ext_ref like 'aros_tr%'
 group by ext_ref
having count(*) > 1;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 5.4  ext_ref UNIQUE indeksi joyidami
--      Nimani ko'rsatadi: takrorlanmaslikning poydevori bor-yo'qligi.
--      MUAMMO belgisi: BO'SH chiqsa — unique indeks YO'Q, ikki marta
--      yozilish ehtimoli bor.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select i.indexname, i.indexdef
  from pg_indexes i
 where i.schemaname = 'public' and i.tablename = 'entry'
   and i.indexdef ilike '%ext_ref%';
-- ⬆⬆⬆



-- #####################################################################
--  6-BO'LIM — O'CHIRILGAN TRANSFERLAR (sync qayta yozmaydi)
-- #####################################################################

-- ---------------------------------------------------------------------
-- 6.1  is_deleted = true bo'lgan 'aros_tr:' yozuvlar
--      Nimani ko'rsatadi: kimdir qo'lda o'chirgan transfer yozuvlari.
--      ⚠️ ext_ref BAND qolgani uchun sync ularni QAYTA YOZMAYDI
--      (ataylab: admin o'chirganini tiriltirmaslik uchun). Ya'ni bu
--      transferlar "tushib qolgan" bo'lib ko'rinadi, aslida o'chirilgan.
--      MUAMMO belgisi: kutilmagan o'chirishlar bo'lsa — kim va qachon
--      o'chirgani ko'rinadi.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select e.ext_ref, e.entry_date, e.description,
       e.deleted_by_name, e.deleted_at at time zone 'Asia/Tashkent' as ochirilgan_tosh
  from entry e
 where e.ext_ref like 'aros_tr%'
   and e.is_deleted = true
 order by e.deleted_at desc nulls last;
-- ⬆⬆⬆



-- #####################################################################
--  7-BO'LIM — CUTOFF QANCHA TRANSFERNI TO'SGANINI CHAMALASH
-- #####################################################################

-- ---------------------------------------------------------------------
-- 7.1  Yozilgan transferlar cutoff'ga nisbatan qayerda
--      Nimani ko'rsatadi: oxirgi yozilgan transfer sanasi va hozirgi
--      cutoff. Ikkalasi orasidagi farq = "hozir kelsa to'silib qoladigan"
--      oyna.
--      MUAMMO belgisi: cutoff oxirgi yozuvdan ancha oldinda bo'lsa
--      (soatlar/kunlar) — o'sha oynadagi hamma transfer to'silgan.
-- ⚠️ ALOHIDA belgilab RUN qiling
-- ⬇⬇⬇
select (select nullif(aros_transfer_cutoff() ->> 'cutoff', '')::timestamptz
          at time zone 'Asia/Tashkent')                              as cutoff_tosh,
       (select max(created_at) at time zone 'Asia/Tashkent'
          from entry where ext_ref like 'aros_tr:%')                 as oxirgi_transfer_yozuvi_tosh,
       (select max(created_at) at time zone 'Asia/Tashkent'
          from entry where source = 'aros_auto' and created_by = 'aros_sync') as oxirgi_delta_yozuvi_tosh,
       (now() at time zone 'Asia/Tashkent')                          as hozir_tosh;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 7.2  ⚙️ SOZLANADI: aniq id/sana ro'yxati cutoff'dan o'tadimi
--      Nimani ko'rsatadi: shubhali transferlarni (Aros'dan olingan
--      id + received_at) shu VALUES ichiga qo'ying — qaysisi to'silishi
--      ko'rinadi.
--      MUAMMO belgisi: "TO'SILADI" chiqqan qatorlar — ular qayta
--      sync qilinsa ham YOZILMAYDI (qo'lda tuzatish kerak).
-- ⚠️ ALOHIDA belgilab RUN qiling (avval VALUES ni to'ldiring)
-- ⬇⬇⬇
with cut as (select nullif(aros_transfer_cutoff() ->> 'cutoff', '')::timestamptz as c),
     tr(id, received_at) as (values
       ('1044', '2026-08-11T10:00:00+05'::timestamptz),
       ('1046', '2026-08-12T09:00:00+05'::timestamptz)
     )
select tr.id,
       tr.received_at at time zone 'Asia/Tashkent' as received_tosh,
       cut.c          at time zone 'Asia/Tashkent' as cutoff_tosh,
       case when cut.c is null           then '⚠️ cutoff yo''q — RPC umuman yozmaydi'
            when tr.received_at <= cut.c then '🛡️ TO''SILADI (cutoff undan keyin)'
            else                              '✍️ YOZILADI'
       end as natija,
       case when exists (select 1 from entry where ext_ref like 'aros_tr:' || tr.id || ':%')
            then 'ha' else 'yo''q' end as provodkada_bormi
  from tr, cut
 order by tr.id;
-- ⬆⬆⬆



-- #####################################################################
--  8-BO'LIM — ⚠️⚠️ BU SO'ROVLAR **AROS** BAZASIDA RUN QILINADI
-- #####################################################################
--  ❗ Supabase'da EMAS. n8n -> Postgres node (Aros PG, "Postgres
--     account 3") yoki Aros bazasiga to'g'ridan ulanib bajariladi.
--     Jadval: cachier_transfers (CLAUDE.md — n8n PG bo'limi).
--     Vaqtlar Aros'da NAIVE (zonasiz) va Toshkent vaqtida saqlanadi.
--
--  Maqsad: Aros'dagi received transferlar ro'yxatini olib, yuqoridagi
--  4.1/4.2 dagi "yo'q id" lar bilan solishtirish. Ustun nomlari ataylab
--  Provodka natijasiga mos qilingan (tr_id, jami_uzs).

-- ---------------------------------------------------------------------
-- 8.1  [AROS BAZASI] Ustun nomlarini tekshirish (avval SHUNI)
--      Nimani ko'rsatadi: cachier_transfers da qaysi ustunlar bor.
--      MUAMMO belgisi: 8.2 dagi nomlar (status/received_at/items) mos
--      kelmasa — 8.2 ni shu ro'yxatga qarab tuzating.
-- ⚠️ ALOHIDA belgilab RUN qiling — AROS BAZASIDA
-- ⬇⬇⬇
select column_name, data_type
  from information_schema.columns
 where table_name = 'cachier_transfers'
 order by ordinal_position;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 8.2  [AROS BAZASI] Oxirgi 60 kunda RECEIVED transferlar
--      Nimani ko'rsatadi: id, qabul vaqti, jo'natuvchi, qabul qiluvchi,
--      items[] dagi confirmed_total yig'indisi.
--      MUAMMO belgisi: bu ro'yxatdagi id Provodka 4.2 dagi "yo'q id"
--      ro'yxatida ham bo'lsa — AYNAN O'SHA transfer tushib qolgan.
--      Shuningdek "jami_uzs = 0 yoki null" qatorlar: Provodka ularni
--      baribir yozmaydi (summa 0 -> o'tkazib yuboriladi).
-- ⚠️ ALOHIDA belgilab RUN qiling — AROS BAZASIDA
-- ⬇⬇⬇
select t.id                                   as tr_id,
       t.status,
       t.received_at,
       t.sender_title,
       t.receiver_title,
       (select coalesce(sum((i ->> 'confirmed_total')::numeric), 0)
          from jsonb_array_elements(t.items) i)  as jami_uzs,
       jsonb_array_length(t.items)             as item_soni
  from cachier_transfers t
 where t.status = 'received'
   and t.received_at >= now() - interval '60 days'
 order by t.id desc;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 8.3  [AROS BAZASI] SENT holatda qotib qolganlar
--      Nimani ko'rsatadi: jo'natilgan, lekin hali received bo'lmagan
--      transferlar. Provodka ularni ATAYLAB yozmaydi.
--      MUAMMO belgisi: eski sanadagi (bir necha kunlik) 'sent' qatorlar —
--      ular keyin received bo'lsa, cutoff allaqachon oldinda bo'ladi va
--      ABADIY tushib qoladi (asosiy shubha shu).
-- ⚠️ ALOHIDA belgilab RUN qiling — AROS BAZASIDA
-- ⬇⬇⬇
select t.id as tr_id, t.status, t.sent_at, t.received_at,
       t.sender_title, t.receiver_title,
       (select coalesce(sum((i ->> 'confirmed_total')::numeric), 0)
          from jsonb_array_elements(t.items) i) as jami_uzs
  from cachier_transfers t
 where t.status <> 'received'
   and coalesce(t.sent_at, t.received_at) >= now() - interval '60 days'
 order by t.id desc;
-- ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 8.4  [AROS BAZASI] received_at bilan yozuv vaqti orasidagi kechikish
--      Nimani ko'rsatadi: transfer received bo'lgan payt bilan qatorning
--      o'zgargan payti orasidagi farq (agar updated/modified ustuni bo'lsa
--      8.1 ga qarab nomini almashtiring).
--      MUAMMO belgisi: kechikish 30 daqiqadan katta bo'lsa — transfer
--      sync uni ko'rgunicha cutoff oldinga ketadi va u tushib qoladi.
-- ⚠️ ALOHIDA belgilab RUN qiling — AROS BAZASIDA (ustun nomini tekshiring)
-- ⬇⬇⬇
select t.id as tr_id, t.status, t.sent_at, t.received_at,
       t.received_at - t.sent_at as sent_dan_received_gacha
  from cachier_transfers t
 where t.status = 'received'
   and t.received_at >= now() - interval '30 days'
 order by (t.received_at - t.sent_at) desc nulls last
 limit 100;
-- ⬆⬆⬆


-- =====================================================================
--  XULOSA UCHUN NIMA KERAK (menga yuboring):
--    1.1  cutoff json
--    1.2  muhr jadvali
--    2.1  jami soni
--    2.3  filial bo'yicha (0 chiqqanlar)
--    4.1  id teshiklari (oraliqlar)
--    4.3  teshik statistikasi
--    8.2  Aros received ro'yxati (yoki hech bo'lmasa id lari)
--  Shu 7 ta natija bilan qaysi transfer, nega tushganini aniq aytib
--  bo'ladi.
-- =====================================================================
