-- =====================================================================
-- DIAG_YETIM.sql — 🔴 SHOSHILINCH: satrsiz ("yetim") entry sarlavhalari
-- ---------------------------------------------------------------------
-- Simptom: jurnalda Dt/Kt "—", summa 0, maqsad neytral "→", ijrochi ismi bor.
-- Sabab (gipoteza): `entry` yozilgan, `entry_line` YOZILMAGAN.
--   Provodka'da yozuv tranzaksiyada emas (CLAUDE.md):
--     1) insert entry  -> commit
--     2) insert entry_line -> commit
--   2-qadam rad etilsa klient kompensatsiya `delete` qiladi, LEKIN
--   `entry` o'chirish faqat ADMIN uchun ochiq (RLS) -> hodimda jimgina
--   0 qator o'chadi va sarlavha qolib ketadi.
--
-- 🔴 PUL YO'QOLMAGAN: satr yo'q = balansga TA'SIR QILMAYDI. Balans faqat
--    `entry_line` dan yig'iladi. Ya'ni hisobotlar TO'G'RI, faqat jurnal
--    axlat bilan to'lgan va hodim "saqlanmadi" holatiga tushgan.
--
-- ⚠️ Hech narsa o'zgarmaydi — faqat O'QIYDI. Bittalab RUN qiling.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) TASDIQ: nechta yetim sarlavha bor va qachondan boshlangan?
--    Bu gipotezani TASDIQLAYDI yoki RAD ETADI.
-- ---------------------------------------------------------------------
select count(*)                                   as yetim_jami,
       min(e.created_at)                          as birinchisi,
       max(e.created_at)                          as oxirgisi,
       count(*) filter (where e.created_at::date = (now() at time zone 'Asia/Tashkent')::date) as bugun
  from entry e
 where not exists (select 1 from entry_line l where l.entry_id = e.id)
   and coalesce(e.is_deleted, false) = false;


-- ---------------------------------------------------------------------
-- 2) KIM va QACHON — muallif va vaqt bo'yicha guruh.
--    `ext_ref` ustuni takror-himoya tokenini ko'rsatadi: `hodim:` bilan
--    boshlansa — hodim sahifasidan, null bo'lsa — boshqa yo'ldan.
-- ---------------------------------------------------------------------
select ijrochi_nomi(to_jsonb(e) ->> 'created_by')            as ijrochi,
       date_trunc('hour', e.created_at)                      as soat,
       count(*)                                              as soni,
       count(*) filter (where e.ext_ref is not null)         as tokenli,
       min(e.description)                                    as misol_izoh
  from entry e
 where not exists (select 1 from entry_line l where l.entry_id = e.id)
   and coalesce(e.is_deleted, false) = false
 group by 1, 2
 order by 2 desc, 3 desc
 limit 30;


-- ---------------------------------------------------------------------
-- 3) OXIRGI 20 TASI — batafsil (nima yozmoqchi bo'lgan).
-- ---------------------------------------------------------------------
select e.id, e.entry_date, e.description, e.source, e.status,
       e.ext_ref, e.filial_ids,
       ijrochi_nomi(to_jsonb(e) ->> 'created_by') as ijrochi,
       e.created_at
  from entry e
 where not exists (select 1 from entry_line l where l.entry_id = e.id)
   and coalesce(e.is_deleted, false) = false
 order by e.created_at desc
 limit 20;


-- ---------------------------------------------------------------------
-- 4) 🔴 SABAB: qaysi trigger `entry_line` ni to'sayotgan bo'lishi mumkin?
--    Bugun qaysi qorovullar YOQILGAN — shuni ko'ramiz.
--    tgenabled: 'O' = yoqilgan, 'D' = o'chirilgan.
-- ---------------------------------------------------------------------
select t.tgname, t.tgrelid::regclass as jadval, t.tgenabled as holat
  from pg_trigger t
 where not t.tgisinternal
   and t.tgrelid in ('entry'::regclass, 'entry_line'::regclass)
 order by t.tgrelid::regclass::text, t.tgname;


-- ---------------------------------------------------------------------
-- 5) To'siq YOQILGANMI va foizi qancha?
--    (funksiya yo'q bo'lsa xato beradi — demak TOSIQ.sql RUN qilinmagan)
-- ---------------------------------------------------------------------
select hodim_tosiq_foiz() as tosiq_foiz;


-- =====================================================================
-- 6) TOZALASH — 🔴 FAQAT 1-BAND TASDIQLAGANDAN KEYIN, ADMIN sifatida.
--
--    Yetim sarlavha PUL yozuvi EMAS (satri yo'q), shuning uchun uni
--    o'chirish balansga TA'SIR QILMAYDI. Baribir ehtiyot bo'lamiz:
--    `is_deleted = true` (soft-delete) qilamiz, jismonan o'chirmaymiz —
--    CLAUDE.md: "Hech narsa o'chirilmaydi".
--
--    ⚠️ AVVAL 1-3 bandlarni RUN qilib menga natijasini yuboring.
--       Sabab aniqlanmasdan tozalash — belgini o'chirish, kasallikni emas.
--
--   update entry e
--      set is_deleted = true,
--          deleted_at = now(),
--          deleted_by_name = 'tizim: yetim sarlavha (satrsiz)'
--    where not exists (select 1 from entry_line l where l.entry_id = e.id)
--      and coalesce(e.is_deleted, false) = false;
--
--    Tozalagandan keyin qayta sanang (1-band) — 0 bo'lishi kerak.
-- =====================================================================
