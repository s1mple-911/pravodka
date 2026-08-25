-- =====================================================================
-- PROVODKA_STATUS_PENDING.sql — entry.status CHECK ga 'pending' qo'shish
-- ---------------------------------------------------------------------
-- MUAMMO (jonli): so'rov yuborilganda
--   code 23514: new row for relation "entry" violates check constraint
--   "entry_status_check"
-- Sabab: `sorov_yarat` xarajatni `status='pending'` bilan yozadi, mavjud
-- CHECK esa uni ruxsat etmaydi.
--
-- 🔴 MAVJUD QIYMATLAR TAXMIN QILINMAYDI. Ular constraint ta'rifidan VA
--    jadvaldagi haqiqiy qiymatlardan o'qib olinadi, so'ng ustiga 'pending'
--    qo'shiladi. Ya'ni birorta mavjud qiymat yo'qolmaydi.
--
-- ⚠️ `alter table ... add constraint ... check` mavjud qatorlarni TEKSHIRADI
--    (jadval skani) va shu vaqtda ACCESS EXCLUSIVE lock oladi. `entry` katta
--    emas, lekin baribir tinch daqiqada RUN qiling.
--
-- Bo'limlarni BITTALAB RUN qiling.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — HOZIRGI HOLAT (faqat ko'radi)                       ##
-- #####################################################################

-- 0.1 Constraint ta'rifi — nima ruxsat etilgan?
select c.conname,
       pg_get_constraintdef(c.oid) as tarif,
       c.convalidated              as tasdiqlangan
  from pg_constraint c
 where c.conrelid = 'entry'::regclass
   and c.contype = 'c'
 order by c.conname;

-- 0.2 Jadvalda haqiqatan qanday qiymatlar bor?
select status, count(*) as soni
  from entry
 group by status
 order by count(*) desc;

-- 0.3 'pending' allaqachon ruxsat etilganmi? (true bo'lsa hech narsa kerak emas)
select exists (
  select 1 from pg_constraint c
   where c.conrelid = 'entry'::regclass
     and c.contype = 'c'
     and c.conname = 'entry_status_check'
     and pg_get_constraintdef(c.oid) like '%pending%'
) as pending_allaqachon_bor;


-- #####################################################################
-- ##  1-BO'LIM — TUZATISH (bir martalik yordamchi funksiya)          ##
-- #####################################################################
-- Nega funksiya: mavjud qiymatlarni DINAMIK o'qib, yangi CHECK ni
-- shundan quramiz. Anonim `do` bloki ISHLATILMAYDI (Supabase editorida
-- 42P01 beradi — CLAUDE.md). Funksiya esa muammosiz ishlaydi.
--
-- 🔴 FAIL-CLOSED: constraint ta'rifini o'qib bo'lmasa yoki u kutilmagan
--    shaklda bo'lsa — funksiya XATO beradi va HECH NARSA o'zgartirmaydi.
--    Ko'r-ko'rona qayta yozish mavjud qiymatni yo'qotib qo'yardi.
-- ---------------------------------------------------------------------

create or replace function entry_status_pending_qosh()
returns text
language plpgsql
set search_path = public
as $fn$
declare
  v_def   text;
  v_qiy   text[] := '{}';
  v_jad   text[];
  v_yangi text[];
  v_list  text;
begin
  -- 1) Constraint ta'rifi
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conrelid = 'entry'::regclass
     and c.contype  = 'c'
     and c.conname  = 'entry_status_check';

  if v_def is null then
    raise exception 'entry_status_check topilmadi — qo''lda tekshiring'
      using errcode = '42704';
  end if;

  -- 2) Ta'rifdagi matn literallarini ajratib olamiz ('posted', 'draft' ...)
  select coalesce(array_agg(distinct m[1] order by m[1]), '{}')
    into v_qiy
    from regexp_matches(v_def, '''([^'']+)''', 'g') as m;

  if coalesce(array_length(v_qiy, 1), 0) = 0 then
    raise exception 'Constraint shakli kutilmagan (% ) — qo''lda tuzating', v_def
      using errcode = '22000';
  end if;

  -- 3) Jadvaldagi HAQIQIY qiymatlar (constraint NOT VALID bo'lsa ham
  --    ular yo'qolmasin)
  select coalesce(array_agg(distinct e.status), '{}')
    into v_jad
    from entry e
   where e.status is not null;

  -- 4) Birlashma + 'pending'
  select coalesce(array_agg(distinct x order by x), '{}')
    into v_yangi
    from unnest(v_qiy || v_jad || array['pending']) as x;

  -- 5) Yangi CHECK
  select string_agg(quote_literal(x), ', ' order by x) into v_list
    from unnest(v_yangi) as x;

  execute format(
    'alter table entry drop constraint entry_status_check, '
    'add constraint entry_status_check check (status in (%s))', v_list);

  return 'ESKI: ' || v_def || '  |  YANGI ruxsat: ' || v_list;
end $fn$;

revoke all on function entry_status_pending_qosh() from public, anon, authenticated;

comment on function entry_status_pending_qosh() is
  'BIR MARTALIK: entry_status_check ga pending qoshadi, mavjud qiymatlarni saqlab. Ishlatilgach drop qilinadi.';


-- ---------------------------------------------------------------------
-- 1.2 BAJARISH — natija ESKI va YANGI ruxsatni ko'rsatadi.
--     🔴 Natijani saqlab qo'ying (rollback uchun kerak bo'lishi mumkin).
-- ---------------------------------------------------------------------
select entry_status_pending_qosh() as natija;


-- #####################################################################
-- ##  2-BO'LIM — TASDIQ                                              ##
-- #####################################################################

-- 2.1 Yangi ta'rif — 'pending' ichida bo'lsin, eskilari ham qolsin
select pg_get_constraintdef(c.oid) as yangi_tarif
  from pg_constraint c
 where c.conrelid = 'entry'::regclass
   and c.contype = 'c'
   and c.conname = 'entry_status_check';

-- 2.2 Mavjud qatorlarning hammasi hamon to'g'rimi (0 qator chiqishi kerak)
select status, count(*) as buzilgan
  from entry e
 where not exists (
         select 1 from pg_constraint c
          where c.conrelid = 'entry'::regclass
            and c.conname = 'entry_status_check'
            and pg_get_constraintdef(c.oid) like '%' || quote_literal(e.status) || '%')
 group by status;

-- 2.3 Yordamchi funksiyani olib tashlash (ishi tugadi)
drop function if exists entry_status_pending_qosh();


-- #####################################################################
-- ##  3-BO'LIM — ROLLBACK (kerak bo'lsa)                             ##
-- #####################################################################
-- 1.2 natijasidagi "ESKI:" qismini o'qing va shu shaklda qaytaring:
--
--   alter table entry drop constraint entry_status_check,
--     add constraint entry_status_check check (status in ('posted', ...));
--
-- 🔴 Qaytarishdan OLDIN pending yozuvlar qolmaganiga ishonch hosil qiling:
--   select count(*) from entry where status = 'pending';
-- Aks holda `add constraint` mavjud qatorlar tufayli yiqiladi.
