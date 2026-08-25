-- =====================================================================
-- DIAG_MAYDON_RASM.sql — rasm nega ko'rinmayapti?
-- 🔴 Faqat O'QIYDI.
--
-- GUMON: formadagi ko'rinish LOKAL blob (objectURL) — u yuklash
-- muvaffaqiyatli bo'lmasa ham ko'rinaveradi. Storage policy'lari esa
-- endigina yaratildi (birinchi urinish 42601 bilan yiqilgan edi).
-- Ya'ni rasm brauzerda ko'ringan, lekin bucketga TUSHMAGAN va
-- `rasm_url` bazaga YOZILMAGAN bo'lishi mumkin.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) Elementlarda rasm_url bormi?
--    `rasm_url` null chiqsa -> yuklash yoki tahrir RPC si ishlamagan.
-- ---------------------------------------------------------------------
select el.id, el.nom, el.qiymat, el.rasm_url, el.is_active, el.tartib,
       m.nom as maydon_nom
  from xarajat_royxat_element el
  join xarajat_maydon m on m.id = el.maydon_id
 order by m.nom, el.tartib, el.nom;


-- ---------------------------------------------------------------------
-- 2) Bucketda fayl bormi?
--    Bo'sh chiqsa -> yuklash RLS tufayli rad etilgan (policy yo'q edi).
-- ---------------------------------------------------------------------
select o.name, o.bucket_id, o.owner, o.created_at,
       (o.metadata ->> 'size') as bayt
  from storage.objects o
 where o.bucket_id = 'xarajat-maydon'
 order by o.created_at desc;


-- ---------------------------------------------------------------------
-- 3) Storage policy'lari o'rnidami (4 qator kutiladi)?
-- ---------------------------------------------------------------------
select policyname, cmd, roles
  from pg_policies
 where schemaname = 'storage' and tablename = 'objects'
   and policyname like 'xm%'
 order by policyname;


-- ---------------------------------------------------------------------
-- 4) Bucket public mi (rasm signed URL siz ko'rinishi uchun shart)?
-- ---------------------------------------------------------------------
select id, name, public from storage.buckets where id = 'xarajat-maydon';
