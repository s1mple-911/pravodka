-- =====================================================================
--  DIAG_TRANSFER_TUSHIB_QOLGAN.sql   (2026-09-09, SHOSHILINCH)
--  «Toshkent kassada pul ko'p, Provodkada kam» — qaysi transfer
--  tushib qolgan?
-- ---------------------------------------------------------------------
--  🟢 BU FAYL FAQAT O'QIYDI. Bitta ham insert/update/delete YO'Q.
--     Pul harakati YO'Q — xotirjam RUN qiling.
--
--  ⚠️ HAR SO'ROVNI ALOHIDA belgilab RUN qiling (⬇⬇⬇ … ⬆⬆⬆),
--     aks holda faqat oxirgi natija ko'rinadi.
--
--  ## G'OYA
--  Provodkada Aros transferlarining NUSXASI bor: `aros_transfer_yolda`
--  (n8n «Aros Provodka - Yolda Sync», har 5 daqiqa, `cachier_transfers`
--  dan). Pul yozuvi esa `entry.ext_ref = 'aros_tr:<transfer_id>:<tur>'`.
--  Demak: nusxada `received` bo'lgan-u, `entry` da yo'q transfer =
--  AYNAN TUSHIB QOLGAN PUL. 1-SO'ROV shuni beradi.
--
--  ## NEGA TUSHIB QOLADI (PROVODKA_TRANSFER_CUTOFF_FIX.sql)
--  `sync_transfer_balans` har transferni `cutoff` bilan taqqoslaydi va
--  `received_at <= cutoff` bo'lsa JIMGINA tashlab yuboradi. Eski
--  `aros_transfer_cutoff()` esa cutoff'ni SINXRONNING O'Z yozuvlaridan
--  olardi — ya'ni har siklda o'zi oldinga surilardi. Bir sikl kechikkan
--  transfer keyingi siklda ham «eski» bo'lib qolardi va ABADIY tushardi.
--  2026-08-12 da shu sabab 9 ta transfer (352 835 000 so'm) yo'qolgan.
--  CUTOFF_FIX buni «qo'lda qo'yiladigan POL» bilan hal qiladi — lekin
--  POL QO'YILMAGAN bo'lsa eski xatti-harakat DAVOM ETADI. 3-SO'ROV shuni
--  tekshiradi.
--
--  ## BUGUNGI KONTEKST
--  Aros adminkasida yangilanish chiqqan. Agar API maydon nomlari
--  o'zgargan bo'lsa `c_cash/c_click/c_payme/c_usd` NULL bo'lib keladi
--  va summa 0 yoziladi — 5-SO'ROV shuni ko'rsatadi.
-- =====================================================================


-- #####################################################################
--  1-SO'ROV ⭐ ENG MUHIM — QABUL QILINGAN, LEKIN YOZILMAGAN TRANSFERLAR
-- #####################################################################
--  Nimani ko'rsatadi: Aros «received» degan, Provodkada esa pul yozuvi
--  YO'Q transferlar + yo'qolgan summa.
--  Natija BO'SH bo'lsa — transfer tomoni toza, muammo boshqa joyda
--  (7-SO'ROVga o'ting).
-- ⬇⬇⬇
select y.transfer_id,
       y.sender_title    as kimdan,
       y.receiver_title  as kimga,
       y.received_at,
       coalesce(y.c_cash,0)  as naqd,
       coalesce(y.c_click,0) as click,
       coalesce(y.c_payme,0) as payme,
       coalesce(y.c_usd,0)   as dollar,
       coalesce(y.c_cash,0)+coalesce(y.c_click,0)+coalesce(y.c_payme,0) as jami_som,
       y.dollar_rate,
       y.responsible
  from aros_transfer_yolda y
 where y.status = 'received'
   and not exists (
     select 1 from entry e
      where e.ext_ref like 'aros_tr:' || y.transfer_id || ':%'
        and e.is_deleted = false)
 order by y.received_at desc nulls last;
-- ⬆⬆⬆


-- #####################################################################
--  2-SO'ROV — YO'QOLGAN JAMI SUMMA (1-so'rovning yig'indisi)
-- #####################################################################
--  Nimani ko'rsatadi: «qancha pul yozilmagan» — bitta raqam.
--  Hodim aytgan farq shu raqamga yaqin bo'lsa — sabab TOPILDI.
-- ⬇⬇⬇
select count(*)                                                         as tushib_qolgan_soni,
       sum(coalesce(y.c_cash,0)+coalesce(y.c_click,0)+coalesce(y.c_payme,0)) as jami_som,
       sum(coalesce(y.c_usd,0))                                         as jami_usd,
       min(y.received_at)                                               as eng_eski,
       max(y.received_at)                                               as eng_yangi
  from aros_transfer_yolda y
 where y.status = 'received'
   and not exists (
     select 1 from entry e
      where e.ext_ref like 'aros_tr:' || y.transfer_id || ':%'
        and e.is_deleted = false);
-- ⬆⬆⬆


-- #####################################################################
--  3-SO'ROV — CUTOFF: ildiz sabab hali tirikmi?
-- #####################################################################
--  Nimani ko'rsatadi:
--    fix_ornatilgan=false  -> PROVODKA_TRANSFER_CUTOFF_FIX.sql RUN
--                             QILINMAGAN, eski (harakatlanuvchi) cutoff
--                             ishlayapti -> transferlar tushib qolaveradi.
--    pol_qoyilgan=false    -> fix o'rnatilgan, lekin POL qo'yilmagan ->
--                             xatti-harakat HALI HAM eski.
--    cutoff bugungi/kechagi sana -> undan oldingi hamma tushib qolgan
--                             transfer ABADIY tushib qolgan (o'zi tiklanmaydi).
--  🔴 AVVAL 3a ni RUN qiling. `fix_ornatilgan=false` chiqsa 3b ni RUN
--     QILMANG — u xato beradi (jadval yo'q), va javob allaqachon ma'lum:
--     ildiz sabab tirik.
--
--  3a — fix o'rnatilganmi (bu so'rov HAR DOIM ishlaydi)
-- ⬇⬇⬇
select to_regclass('public.aros_transfer_wm')      is not null as fix_ornatilgan,
       to_regclass('public.aros_transfer_dropped') is not null as log_bor,
       aros_transfer_cutoff()                      as cutoff_hozir;
-- ⬆⬆⬆

--  3b — POL qo'yilganmi (FAQAT fix_ornatilgan=true bo'lsa)
--     🔴 `pol_qoyilgan=false` -> jadval bor, lekin POL bo'sh: cutoff hamon
--        ESKI (harakatlanuvchi) mantiq bilan hisoblanadi, ya'ni muammo tirik.
-- ⬇⬇⬇
select (select count(*) > 0 from aros_transfer_wm where wm_at is not null) as pol_qoyilgan,
       (select max(wm_at) from aros_transfer_wm)                           as pol_vaqti,
       (select izoh from aros_transfer_wm where id = 1)                    as pol_izoh;
-- ⬆⬆⬆


-- #####################################################################
--  4-SO'ROV — TASHLANGAN TRANSFERLAR LOGI (fix o'rnatilgan bo'lsa)
-- #####################################################################
--  Nimani ko'rsatadi: sinxron qaysi transferni, NEGA tashlaganini.
--  `aros_transfer_dropped` faqat CUTOFF_FIX bilan paydo bo'ladi.
-- ⬇⬇⬇
select * from aros_transfer_dropped order by oxirgi_at desc nulls last limit 50;
-- ⬆⬆⬆


-- #####################################################################
--  5-SO'ROV — AROS YANGILANISHI SINXRONNI BUZDIMI?
-- #####################################################################
--  Nimani ko'rsatadi: bugun/kecha kelgan `received` transferlarda
--  tasdiqlangan summalar (`c_*`) NULL yoki 0 bo'lsa — Aros API javob
--  shakli o'zgargan (adminka yangilanishi), n8n eski maydon nomlarini
--  o'qiyapti. O'shanda summa 0 yozilib, pul YO'QOLADI.
--  `synced_at` eski bo'lsa — Yolda Sync umuman ishlamayapti.
-- ⬇⬇⬇
select date_trunc('day', y.received_at) as kun,
       count(*)                                                      as soni,
       count(*) filter (where y.c_cash is null and y.c_click is null
                          and y.c_payme is null and y.c_usd is null)  as c_null_soni,
       count(*) filter (where coalesce(y.c_cash,0)+coalesce(y.c_click,0)
                            +coalesce(y.c_payme,0)+coalesce(y.c_usd,0) = 0) as nol_summa,
       max(y.synced_at)                                              as oxirgi_sinxron
  from aros_transfer_yolda y
 where y.status = 'received'
   and y.received_at > now() - interval '7 days'
 group by 1
 order by 1 desc;
-- ⬆⬆⬆


-- #####################################################################
--  6-SO'ROV — TOSHKENT KASSA: bugungi harakat
-- #####################################################################
--  Nimani ko'rsatadi: 5011 (va uning tur bolalari) bo'yicha bugun
--  yozilgan HAR kirim/chiqim. Hodim aytgan summani shu ro'yxat bilan
--  solishtiring — qaysi tushum yo'qligini ko'rasiz.
-- ⬇⬇⬇
select e.entry_date,
       e.created_at,
       a.code, a.name                                   as hisob,
       l.debit                                          as kirim,
       l.credit                                         as chiqim,
       e.description,
       e.ext_ref,
       e.source
  from entry_line l
  join entry e   on e.id = l.entry_id
  join accounts a on a.id = l.account_id
 where e.is_deleted = false
   and e.status = 'posted'
   and (a.code = '5011' or a.parent_id = (select id from accounts where code = '5011'))
   and e.entry_date >= (now() at time zone 'Asia/Tashkent')::date - 2
 order by e.created_at desc;
-- ⬆⬆⬆


-- #####################################################################
--  7-SO'ROV — TOSHKENT KASSA daftar qoldig'i (tur bo'yicha)
-- #####################################################################
--  Nimani ko'rsatadi: Provodka AYNAN qancha ko'rsatyapti. Hodim aytgan
--  raqam bilan farqni shu yerdan oling.
-- ⬇⬇⬇
select a.code, a.name, coalesce(a.currency,'UZS') as valyuta,
       b.uzs as qoldiq_som, b.fc as qoldiq_valyuta
  from accounts a
  left join v_hisob_bal b on b.account_id = a.id
 where a.code = '5011' or a.parent_id = (select id from accounts where code = '5011')
 order by a.code;
-- ⬆⬆⬆


-- #####################################################################
--  8-SO'ROV — YO'LDA TURGAN PUL (jo'natilgan, qabul qilinmagan)
-- #####################################################################
--  Nimani ko'rsatadi: filial jo'natgan, lekin markaziy kassa Aros'da
--  «qabul qildim» bosmagan pul. Bu pul HALI Provodkada yozilmaydi —
--  bu XATO EMAS, lekin hodim qo'lidagi pul ko'p bo'lishining sababi
--  bo'lishi MUMKIN (fizik keldi, Aros'da tasdiqlanmagan).
-- ⬇⬇⬇
select y.transfer_id, y.sender_title, y.receiver_title, y.sent_at,
       coalesce(y.s_cash,0)+coalesce(y.s_click,0)+coalesce(y.s_payme,0) as jonatilgan_som,
       coalesce(y.s_usd,0) as jonatilgan_usd,
       round(extract(epoch from (now() - y.sent_at))/3600) as necha_soat
  from aros_transfer_yolda y
 where y.status = 'sent'
 order by y.sent_at;
-- ⬆⬆⬆


-- #####################################################################
--  XULOSA — natijani qanday o'qish
-- #####################################################################
--   • 2-SO'ROV summasi ≈ hodim aytgan farq  -> sabab TOPILDI: tushib
--     qolgan transferlar. Tiklash uchun PROVODKA_TRANSFER_TIKLASH_0812.sql
--     naqshi bor (2026-08-12 da 9 ta transfer shunday tiklangan) —
--     menga 1-SO'ROV natijasini yuboring, aynan shu transferlar uchun
--     tiklash skriptini yozaman.
--   • 3-SO'ROVda fix_ornatilgan=false yoki pol_qoyilgan=false -> ildiz
--     sabab HALI TIRIK: tiklasak ham yana tushadi. Avval CUTOFF_FIX.
--   • 5-SO'ROVda c_null_soni > 0 yoki nol_summa > 0 -> Aros API shakli
--     o'zgargan, n8n «Yolda Sync» va «Transfer Sync» yangilanishi kerak.
--   • 8-SO'ROVda uzoq turgan `sent` bor -> pul fizik kelgan, Aros'da
--     tasdiqlanmagan: markaziy kassa Aros'da «qabul qildim» bosishi kerak,
--     shundan keyin sinxron o'zi yozadi.
