-- =====================================================================
-- PROVODKA V9 — prod tayyorlik tuzatmalari
-- ---------------------------------------------------------------------
-- Bu fayl ADDITIVE: hech narsa o'chirilmaydi, imzo o'zgarmaydi.
-- `create or replace` faqat funksiya TANASINI yangilaydi.
-- Bir necha marta RUN qilish xavfsiz (idempotent).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) perm_pages() — sahifa kalitlari ro'yxatiga 'yuklar' va 'standart'
-- ---------------------------------------------------------------------
-- MUAMMO: klientdagi perms.js 14 ta sahifani biladi
--   (kassa, jurnal, professional, hisobot, balans, cashflow, qarzdor,
--    filial, valyuta, konvert, sozlama, provodka, yuklar, standart),
-- serverdagi perm_pages() esa faqat 12 tasini — 'yuklar' va 'standart' yo'q.
--
-- Natijasi (ikkita, ikkisi ham yomon):
--   a) admin_set_provodka_perms() allowed_pages'ni
--      `where x = any(perm_pages())` bilan suzadi → adminning "Yuklar"/
--      "Standart xarajatlar" ruxsati JIMGINA tashlab yuboriladi. Keyin
--      klient permPageOk('yuklar') = false → foydalanuvchi "Ruxsat yo'q"
--      ekranini ko'radi va bu sahifani unga BERISH IMKONI YO'Q.
--   b) "hammasi belgilangan = cheklanmagan" qisqartmasi
--      (array_length(v_pages) = array_length(perm_pages())) noto'g'ri
--      son bilan solishtiradi: admin 14 tasini belgilasa, 2 tasi suzilib
--      12 qoladi → 12 = 12 → cheklov butunlay olib tashlanadi.
--
-- ESLATMA: 'hodim' ataylab ro'yxatda YO'Q — hodim sahifasi perm bilan
-- to'silmaydi (navigatsiyasi ham yo'q), himoyasi op_kassa_ids filtri va
-- entry_line guard triggeri. perms.js'dagi PAGES ham 'hodim'siz.
create or replace function perm_pages()
returns text[]
language sql
immutable
as $$
  select array['kassa','jurnal','professional','hisobot','balans','cashflow',
               'qarzdor','filial','valyuta','konvert','sozlama','provodka',
               'yuklar','standart']::text[];
$$;

revoke all on function perm_pages() from public, anon;
grant execute on function perm_pages() to authenticated, service_role;


-- ---------------------------------------------------------------------
-- TEKSHIRUV (RUN qilgandan keyin ko'rib chiqing)
-- ---------------------------------------------------------------------
-- 14 ta kalit chiqishi kerak, ichida yuklar va standart bo'lishi shart:
select array_length(perm_pages(), 1) as sahifa_soni,
       'yuklar'   = any(perm_pages()) as yuklar_bor,
       'standart' = any(perm_pages()) as standart_bor;

-- Hozir kimgadir cheklov yozilgan bo'lsa — ular avvalgi (12 ta) ro'yxat
-- bilan saqlangan. Yuklar/Standart kerak bo'lganlarga ruxsatni
-- admin-dev.html orqali QAYTA yozish kerak (bu SQL eski qatorlarga tegmaydi):
select u.user_id, p.full_name, u.allowed_pages
  from user_perms u
  left join profiles p on p.id = u.user_id
 where array_length(u.allowed_pages, 1) > 0
 order by p.full_name;
