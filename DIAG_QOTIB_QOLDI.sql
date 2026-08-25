-- ============================================================
-- SHOSHILINCH DIAGNOSTIKA — "Saqlanmoqda…" qotib qolgan holat
-- ⚠️ Supabase editori faqat OXIRGI so'rov natijasini ko'rsatadi —
--    so'rovlarni BITTALAB (birini belgilab RUN) bajaring.
--    Hammasi faqat O'QIYDI, hech narsa o'zgartirmaydi.
-- ============================================================

-- ############ 1-SO'ROV — ENG MUHIMI: kim kimni bloklayapti ############
select w.pid                  as kutayotgan_pid,
       now() - w.query_start  as kutmoqda,
       w.wait_event_type,
       w.wait_event,
       left(w.query, 100)     as kutayotgan_sorov,
       b.pid                  as BLOKLAGAN_PID,
       b.state                as bloklagan_holati,
       now() - b.xact_start   as bloklagan_tranzaksiya_yoshi,
       now() - b.state_change as shu_holatda,
       left(b.query, 200)     as bloklagan_sorov
  from pg_stat_activity w
  join lateral unnest(pg_blocking_pids(w.pid)) as bp(pid) on true
  join pg_stat_activity b on b.pid = bp.pid;
-- BO'SH chiqsa → qulf muammosi YO'Q, 2-so'rovga o'ting.


-- ############ 2-SO'ROV — uzoq ishlayotgan / ochiq qolgan sessiyalar ############
-- select pid, usename, application_name, state,
--        now() - query_start  as sorov_davomiyligi,
--        now() - xact_start   as tranzaksiya_yoshi,
--        now() - state_change as shu_holatda,
--        wait_event_type, wait_event,
--        left(query, 200) as sorov
--   from pg_stat_activity
--  where datname = current_database()
--    and pid <> pg_backend_pid()
--    and (state <> 'idle' or xact_start is not null)
--  order by coalesce(xact_start, query_start);
-- 🔴 "idle in transaction" + tranzaksiya_yoshi katta = AYBDOR shu.


-- ############ 3-SO'ROV — entry / entry_line ustidagi qulflar ############
-- select c.relname, l.locktype, l.mode, l.granted, l.pid,
--        left(a.query, 120) as sorov
--   from pg_locks l
--   join pg_class c on c.oid = l.relation
--   left join pg_stat_activity a on a.pid = l.pid
--  where c.relname in ('entry','entry_line','accounts')
--  order by l.granted, c.relname;
-- granted=false qatorlar = kutayotganlar.


-- ############ TUZATISH ############
-- 1-so'rovda BLOKLAGAN_PID chiqsa va uning holati 'idle in transaction' bo'lsa
-- (ya'ni hech narsa qilmayapti, faqat tranzaksiyani ushlab turibdi):
--
--     select pg_terminate_backend(<BLOKLAGAN_PID>);
--
-- 🔴 Kutayotgan emas, BLOKLAGAN pid ni uzing.
-- ⚠️ Bloklagan sessiya haqiqiy ish qilayotgan bo'lsa (uzoq migratsiya,
--    index qurilishi) — uzmang, tugashini kuting.


-- ############ QULF OCHILGACH — TAKROR YOZUV BORMI ############
-- Kutib turgan so'rovlar birdaniga bajariladi: hodim 3 marta bosgan bo'lsa
-- 3 ta yozuv tushishi mumkin. Shuni tekshiring:
-- select e.entry_date, e.description, l.debit,
--        count(*) as nechta,
--        array_agg(e.id order by e.created_at) as entry_idlar,
--        min(e.created_at) as birinchi, max(e.created_at) as oxirgi
--   from entry e
--   join entry_line l on l.entry_id = e.id and l.debit > 0
--  where e.created_at > now() - interval '4 hours'
--    and e.is_deleted = false
--  group by e.entry_date, e.description, l.debit
-- having count(*) > 1
--  order by max(e.created_at) desc;
-- Takror chiqsa: ortiqchasini jurnal.html dan SOFT-DELETE qiling (SQL delete EMAS).
