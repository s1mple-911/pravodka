-- =====================================================================
-- PROVODKA — AYLANMA: profit-summary V1 xatosini TOZALASH (2026-10-17)
-- ---------------------------------------------------------------------
-- Sabab: Aros prod'da `warehouse_id` parametrini E'TIBORGA OLMAYDI — V1 workflow har ombor so'rovida ham UMUMIY javob oldi (exec 1376230):
--   * aylanma_foyda ga har filial uchun umumiy qiymat nusxasi yozildi (manba='aros_api', filial<>'JAMI') — NOTO'G'RI;
--   * 2026-10-17 snapshotida tovar 33 x 2.6M, brak 35 x 2.6M USD (SAK ~2.1 trln so'm) — NOTO'G'RI.
-- Bu fayl: (a) noto'g'ri filial nusxalarini o'chiradi (JAMI qatorlari TO'G'RI — qoladi); (b) 2026-10-17 snapshotini o'chiradi
-- (workflow V2 dan keyin «Qo'lda ishga tushirish» toza yozadi). Faqat shu ikkita aniq filtr; boshqa kun/manbaga tegilmaydi.
-- Idempotent. ASILBEK RUN QILADI (workflow V2 patch'idan OLDIN yoki keyin — farqi yo'q, lekin qo'lda run'dan OLDIN).
-- =====================================================================

-- Old ko'rinish (nima o'chadi)
select 'aylanma_foyda (aros_api, filial<>JAMI)' as nima, count(*) as soni
  from aylanma_foyda where manba = 'aros_api' and filial <> 'JAMI'
union all
select 'aylanma_snapshot 2026-10-17', count(*) from aylanma_snapshot where sana = date '2026-10-17';

-- (a) noto'g'ri per-filial nusxalar
delete from aylanma_foyda where manba = 'aros_api' and filial <> 'JAMI';

-- (b) 2026-10-17 snapshoti (cron ham, qolda ham). Bolalar qatorlari aniq o'chiriladi (cascade'ga tayanmasdan).
delete from aylanma_qator where snapshot_id in (select id from aylanma_snapshot where sana = date '2026-10-17');
delete from aylanma_snapshot where sana = date '2026-10-17';

-- (c) NATIJA
-- 1) JAMI foyda qatorlari (03.10 — 16.10; hammasi bo'lishi kerak)
select sana, foyda_usd, sotilgan, manba
  from aylanma_foyda
 where filial = 'JAMI' and sana between date '2026-10-03' and date '2026-10-16'
 order by sana;
-- 2) foydasiz kun qolmadimi (BO'SH chiqsin)
select d::date as foydasiz_kun
  from generate_series(date '2026-10-03', date '2026-10-16', interval '1 day') d
 where not exists (select 1 from aylanma_foyda f where f.sana = d::date and f.filial = 'JAMI');
-- 3) 17.10 da snapshot qolmagan (soni 0 bo'lsin)
select count(*) as snapshot_17_10 from aylanma_snapshot where sana = date '2026-10-17';
select count(*) as yetim_qator_17_10 from aylanma_qator q where not exists (select 1 from aylanma_snapshot s where s.id = q.snapshot_id);
