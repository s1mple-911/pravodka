-- =====================================================================
--  PROVODKA_FILIAL_TANLOV_FIX.sql — filial tanlagichida har tur alohida
--  chiqib qolgani (professional/hodim/standart)
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  MUAMMO (ko'ringan holat):
--     "Filial" tanlagichida bitta filial BESH marta chiqadi:
--        Izza · Izza · Naqd · Izza · Click · Izza · Payme · Izza · USD
--
--  SABAB (ikkita to'g'ri qaror qo'shilib xato bergan):
--     1. v_filial_tanlov (PROVODKA_V6.sql) filialni `kassa_turi='filial'`
--        bo'yicha oladi.
--     2. PROVODKA_VALYUTA_SEED.sql tur/valyuta bolasini ochganda parentning
--        `kassa_turi` sini MEROS qiladi (r.kassa_turi) — bu boshqa joylarda
--        (kassa kartasi guruhlash, v_filial_sync_mapping) kerak.
--     Natijada bolalar ham `kassa_turi='filial'` bo'lib, tanlagichga tushdi.
--
--  YECHIM: view'ga `parent_id is null` sharti. Ya'ni "kassaning O'ZI,
--     bola-hisob emas" — v_filial_sync_mapping va SEED da ishlatilgan
--     ayni shart. Ustunlar o'zgarmaydi (id, code, name, subtitle),
--     shuning uchun `create or replace` xavfsiz: klientlarda hech narsa
--     sinmaydi, faqat ortiqcha qatorlar yo'qoladi.
--
--  ⚠️ Bu view'ni TO'RTTA sahifa o'qiydi — shuning uchun tuzatish shu yerda,
--     klientda emas (bir joyda tuzatilsa to'rttasi ham tuzaladi):
--        professional.html  — xarajat yozuviga filial tegi (filial_ids)
--        hodim.html         — ikki joyda
--        standart.html      — standart xarajat filiali
--     Prod ham, dev ham AYNI view'ni o'qiydi (Supabase bitta) — ya'ni bu
--     prod'dagi ayni xatoni ham darrov tuzatadi.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. AVVAL: hozir nechta ortiqcha qator bor
-- ---------------------------------------------------------------------
-- `bola` = true bo'lgan qatorlar tanlagichda ortiqcha ko'rinayotganlari.
select a.code, a.name, a.pul_turi, a.currency,
       (a.parent_id is not null) as bola,
       p.code as parent_kod
  from accounts a
  left join accounts p on p.id = a.parent_id
 where a.kassa_turi = 'filial'
   and coalesce(a.is_active, true)
 order by coalesce(p.code, a.code), a.parent_id nulls first, a.code;

-- Sanoq: nechtasi haqiqiy filial, nechtasi bola
select count(*) filter (where parent_id is null)     as haqiqiy_filial,
       count(*) filter (where parent_id is not null) as ortiqcha_bola
  from accounts
 where kassa_turi = 'filial' and coalesce(is_active, true);


-- ---------------------------------------------------------------------
-- 1. TUZATISH — ustunlar o'zgarmaydi, faqat qatorlar filtrlanadi
-- ---------------------------------------------------------------------
create or replace view v_filial_tanlov
with (security_invoker = on) as
  select id, code, name, subtitle
    from accounts
   where kassa_turi = 'filial'
     and coalesce(is_active, true) = true
     -- ⬇️ YAGONA O'ZGARISH: kassaning O'ZI, tur/valyuta bola-hisobi emas.
     --    Bolalar parentning kassa_turi='filial' qiymatini meros qiladi
     --    (PROVODKA_VALYUTA_SEED.sql) — shuning uchun kassa_turi yetarli emas.
     and parent_id is null
   order by name, code;

comment on view v_filial_tanlov is
  'Xarajat metadata uchun filial kassalari ro''yxati (professional/hodim/standart; accounts.id). '
  'Faqat kassaning o''zi — tur (naqd/click/payme) va valyuta bola-hisoblari CHIQMAYDI.';


-- ---------------------------------------------------------------------
-- 2. TEKSHIRUV
-- ---------------------------------------------------------------------
-- Har filial ENDI bitta qator bo'lishi kerak — bu so'rov BO'SH chiqsin.
select name, count(*) as nechta
  from v_filial_tanlov
 group by name
having count(*) > 1;

-- Ro'yxatning o'zi (professional/hodim/standart aynan shuni ko'radi)
select * from v_filial_tanlov;


-- ---------------------------------------------------------------------
-- 3. ESKI YOZUVLAR — bola-hisob id'si bilan teglanganlari (ixtiyoriy)
-- ---------------------------------------------------------------------
-- Tanlagich buzuq bo'lgan davrda kimdir "Izza · Click" ni tanlagan bo'lishi
-- mumkin. U holda entry.filial_ids ichida BOLA hisobning id'si turadi va
-- tuzatishdan keyin jurnalda teg NOMSIZ qoladi (klient nom topa olmaydi).
--
-- 3.1 Avval KO'RING — nechta yozuv shunday teglangan
select e.id, e.entry_date, e.description, e.filial_ids,
       array_agg(a.code || ' ' || a.name) as bola_hisoblar
  from entry e
  join accounts a on a.id = any(e.filial_ids)
 where e.is_deleted = false
   and a.parent_id is not null
 group by e.id, e.entry_date, e.description, e.filial_ids
 order by e.entry_date desc;

-- 3.2 Bo'sh chiqmasa — bola id'sini PARENT id'siga almashtirish.
--     Takror bo'lsa yig'iladi (distinct). Yozuvning o'zi va summalari
--     TEGILMAYDI — faqat filial tegi to'g'rilanadi.
--     ⚠️ Avval 3.1 ni ko'ring, keyin izohni oching.
-- update entry e
--    set filial_ids = sub.yangi
--   from (
--     select e2.id,
--            (select array_agg(distinct coalesce(a.parent_id, a.id))
--               from accounts a where a.id = any(e2.filial_ids)) as yangi
--       from entry e2
--      where e2.is_deleted = false
--        and exists (select 1 from accounts a
--                     where a.id = any(e2.filial_ids) and a.parent_id is not null)
--   ) sub
--  where e.id = sub.id;
