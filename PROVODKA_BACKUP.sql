-- =====================================================================
-- PROVODKA_BACKUP.sql — SQL RUN dan OLDINGI zaxira nusxa
-- ---------------------------------------------------------------------
-- Qachon: ijrochi + xarajat to'siq + jurnal v2 SQL'larini RUN qilishdan
-- OLDIN, KAM TRAFIK vaqtida (kechqurun / tushlik).
--
-- Nima qiladi: `entry`, `entry_line` va `accounts` ning NUSXASINI yangi
-- jadvallarga oladi. Mavjud jadvallarga TEGMAYDI — bu sof qo'shimcha.
--
-- 🔴 BU SUPABASE'NING O'Z ZAXIRASINI ALMASHTIRMAYDI. Supabase kunlik
--    backup va (Pro'da) PITR qiladi — ular butun bazani tiklaydi.
--    Bu fayl esa TEZKOR, nuqtali solishtirish uchun: "to'siq trigger'i
--    noto'g'ri ishladi, bugungi yozuvlarni solishtiray" degan holat.
--
-- ⚠️ Nusxa jadvalda INDEKS, CHEKLOV, TRIGGER, RLS POLICY bo'lmaydi —
--    u faqat ma'lumot. Bu ataylab: nusxa hech qachon ishchi jadval
--    bo'lib qolib ketmasin.
--
-- Sana qo'shimchasi: 20260825. Boshqa kunda olsangiz almashtiring
-- (fayl bo'ylab 3 ta jadval nomida uchraydi).
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — HAJMNI KO'RISH (nusxa qancha joy oladi)             ##
-- #####################################################################
select 'entry'       as jadval, count(*) as qatorlar,
       pg_size_pretty(pg_total_relation_size('entry'))      as hajmi
  from entry
union all
select 'entry_line', count(*), pg_size_pretty(pg_total_relation_size('entry_line'))
  from entry_line
union all
select 'accounts',   count(*), pg_size_pretty(pg_total_relation_size('accounts'))
  from accounts;


-- #####################################################################
-- ##  1-BO'LIM — NUSXA OLISH                                         ##
-- #####################################################################
-- ⚠️ `if not exists` — qayta RUN qilinsa MAVJUD nusxa QAYTA YOZILMAYDI
--    (birinchi nusxa saqlanadi). Ikkinchi nusxa kerak bo'lsa sanani
--    o'zgartiring.

create table if not exists entry_backup_20260825      as select * from entry;
create table if not exists entry_line_backup_20260825 as select * from entry_line;
create table if not exists accounts_backup_20260825   as select * from accounts;

-- Nusxalarni hech kim o'qimasin: RLS yoqilgan, birorta policy YO'Q
-- = faqat service_role va jadval egasi ko'radi.
alter table entry_backup_20260825      enable row level security;
alter table entry_line_backup_20260825 enable row level security;
alter table accounts_backup_20260825   enable row level security;

comment on table entry_backup_20260825      is 'ZAXIRA 2026-08-25 (ijrochi+tosiq SQL dan oldin). Ishchi jadval EMAS.';
comment on table entry_line_backup_20260825 is 'ZAXIRA 2026-08-25 (ijrochi+tosiq SQL dan oldin). Ishchi jadval EMAS.';
comment on table accounts_backup_20260825   is 'ZAXIRA 2026-08-25 (ijrochi+tosiq SQL dan oldin). Ishchi jadval EMAS.';


-- #####################################################################
-- ##  2-BO'LIM — TASDIQ (hamma ustun `true` / sonlar TENG bo'lsin)   ##
-- #####################################################################
select (select count(*) from entry)                      as entry_jonli,
       (select count(*) from entry_backup_20260825)      as entry_zaxira,
       (select count(*) from entry) = (select count(*) from entry_backup_20260825)           as entry_mos,
       (select count(*) from entry_line)                 as line_jonli,
       (select count(*) from entry_line_backup_20260825) as line_zaxira,
       (select count(*) from entry_line) = (select count(*) from entry_line_backup_20260825) as line_mos,
       (select count(*) from accounts) = (select count(*) from accounts_backup_20260825)     as accounts_mos;

-- Pul jihatdan tasdiq: umumiy Dt va Kt yig'indisi bir xilmi
select (select coalesce(sum(debit),0)  from entry_line)                 as dt_jonli,
       (select coalesce(sum(debit),0)  from entry_line_backup_20260825) as dt_zaxira,
       (select coalesce(sum(credit),0) from entry_line)                 as kt_jonli,
       (select coalesce(sum(credit),0) from entry_line_backup_20260825) as kt_zaxira;


-- #####################################################################
-- ##  3-BO'LIM — SOLISHTIRISH (SQL RUN va DEV SINOVDAN KEYIN)        ##
-- #####################################################################
-- Zaxiradan keyin PAYDO BO'LGAN yozuvlar (sinov nima yozdi):
select e.id, e.entry_date, e.description, e.source, e.status,
       (to_jsonb(e) ->> 'created_by') as ijrochi_xom, e.ext_ref, e.created_at
  from entry e
 where not exists (select 1 from entry_backup_20260825 b where b.id = e.id)
 order by e.created_at desc;

-- Zaxiradan keyin YO'QOLGAN yoki O'CHIRILGAN yozuvlar:
select b.id, b.entry_date, b.description,
       (e.id is null)                                                  as jonlida_yoq,
       coalesce(e.is_deleted, false) <> coalesce(b.is_deleted, false)   as ochirish_ozgardi
  from entry_backup_20260825 b
  left join entry e on e.id = b.id
 where e.id is null
    or coalesce(e.is_deleted, false) <> coalesce(b.is_deleted, false)
 order by b.entry_date desc;

-- Satr darajasida summa o'zgarganmi (bo'sh chiqishi KUTILADI):
select l.entry_id, l.id, l.debit, l.credit,
       b.debit as eski_debit, b.credit as eski_credit
  from entry_line l
  join entry_line_backup_20260825 b on b.id = l.id
 where l.debit <> b.debit or l.credit <> b.credit;


-- #####################################################################
-- ##  4-BO'LIM — QAYTARISH (🔴 AVTOMATIK SKRIPT ATAYLAB YO'Q)        ##
-- #####################################################################
-- 🔴 Bu yerda tayyor `restore` skripti YO'Q va bu ONGLI QAROR.
--
--    Sabab: yozuvlar `entry_line` triggerlariga (ruxsat qorovuli, to'siq,
--    limit, notify) va tashqi kalitlarga bog'langan. Ko'r-ko'rona
--    `delete + insert` sinovdan KEYIN yozilgan HAQIQIY yozuvlarni ham
--    o'chirib yuboradi va `entry_history` ni buzadi.
--
--    To'g'ri yo'l — NUQTALI qaytarish:
--      1. 3-BO'LIM bilan aynan nima o'zgarganini ko'ring (ro'yxat qisqa).
--      2. Ortiqcha yozuvni Provodka'ning O'ZIDA o'chiring (soft-delete —
--         jurnalda izi qoladi; CLAUDE.md: "Hech narsa o'chirilmaydi").
--      3. Faqat falokatda (ko'p yozuv buzilgan) Supabase panelidan
--         to'liq backup / PITR bilan tiklang — bu fayl bilan emas.
--
-- 🔴 XARAJAT TO'SIG'I NOTO'G'RI ISHLASA QAYTARISH KERAK EMAS:
--    u yozuvni TO'SADI (yozilmaydi), ya'ni ma'lumot BUZILMAYDI.
--    Yechim — to'siqni o'chirish, pul oqimi darrov tiklanadi:
--
--      drop trigger if exists trg_hodim_tosiq_entry_line on entry_line;
--
--    (PROVODKA_XARAJAT_TOSIQ.sql ROLLBACK bo'limiga qarang.)
--    Sababni keyin tinch o'rganamiz.


-- #####################################################################
-- ##  5-BO'LIM — TOZALASH (prod barqaror bo'lgach, 1-2 hafta keyin)  ##
-- #####################################################################
--   drop table if exists entry_line_backup_20260825;
--   drop table if exists entry_backup_20260825;
--   drop table if exists accounts_backup_20260825;
--
-- Shoshilmang — bu jadvallar joy egallashdan boshqa zarar qilmaydi.
