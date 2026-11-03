-- ============================================================================
--  PROVODKA_YUK_QOLDA_OCHIRISH_20261103.sql — 2026-11-03
--  Qo'lda (boshlang'ich) kiritilgan 23 ta yetkazuvchi qarz hujjatini O'CHIRISH
--  (yuk_qolda id 9000001…9000023 — Aros'da bunday hujjat/id yo'q, Asilbek qarori 03.11.2026:
--   qarz faqat Aros hujjatlaridan (n8n aros-provodka-yuklar) hisoblanadi).
--
--  Nima qiladi (bitta tranzaksiya):
--   0) Zaxira jadvali yuk_qolda_ochirish_20261103_zaxira (jsonb) — qaytarish uchun.
--   1) Himoya: faol to'lov (entry_yuk + entry.is_deleted=false) yoki yuk_yopiq bog'langan bo'lsa — TO'XTAYDI.
--      (03.11 tekshiruv: entry_yuk 0, yuk_yopiq 0, yuk_tannarx 0 — xavfsiz.)
--   2) yuk_tolov_grafik (20 qator), yuk_grafik_guruh_yuk (9 qator), yuk_deadline (21 qator) — o'chiriladi.
--      Faqat shu hujjatlardan iborat bo'lib qolgan grafik guruhlari (yuk_grafik_guruh) ham o'chiriladi;
--      Aros yuklari qolgan guruh tegilmaydi (faqat qo'lda hujjat bog'i yechiladi).
--   3) yuk_qolda: is_deleted=true, deleted_at=now() (jismonan o'chirilmaydi — yuk_qolda_ochir() naqshi).
--  Natija: sahifalar (qarzdor «Biz qarzdor», yuklar, 5 kunlik) yuk_qolda_royxat() orqali ularni ko'rmaydi.
--  Asilbek RUN qiladi (Supabase SQL editor). Takror RUN xavfsiz (is_deleted=false bo'lganlargina).
-- ============================================================================

begin;

-- 0) zaxira
create table if not exists yuk_qolda_ochirish_20261103_zaxira (
  jadval   text        not null,
  yuk_id   integer     not null,
  qator    jsonb       not null,
  saqlandi timestamptz not null default now()
);
insert into yuk_qolda_ochirish_20261103_zaxira (jadval, yuk_id, qator)
select 'yuk_qolda', q.id, to_jsonb(q) from yuk_qolda q
 where q.id between 9000001 and 9000023 and not q.is_deleted;
insert into yuk_qolda_ochirish_20261103_zaxira (jadval, yuk_id, qator)
select 'yuk_tolov_grafik', g.yuk_id, to_jsonb(g) from yuk_tolov_grafik g
 where g.yuk_id between 9000001 and 9000023
    or g.guruh_id in (select gy.guruh_id from yuk_grafik_guruh_yuk gy where gy.yuk_id between 9000001 and 9000023);
insert into yuk_qolda_ochirish_20261103_zaxira (jadval, yuk_id, qator)
select 'yuk_grafik_guruh_yuk', gy.yuk_id, to_jsonb(gy) from yuk_grafik_guruh_yuk gy
 where gy.yuk_id between 9000001 and 9000023;
insert into yuk_qolda_ochirish_20261103_zaxira (jadval, yuk_id, qator)
select 'yuk_grafik_guruh', 0, to_jsonb(g) from yuk_grafik_guruh g
 where exists (select 1 from yuk_grafik_guruh_yuk gy where gy.guruh_id = g.id and gy.yuk_id between 9000001 and 9000023);
insert into yuk_qolda_ochirish_20261103_zaxira (jadval, yuk_id, qator)
select 'yuk_deadline', d.yuk_id, to_jsonb(d) from yuk_deadline d
 where d.yuk_id between 9000001 and 9000023;

-- 1) himoya + 2) bog'lanishlar + 3) soft delete
do $ochir$
declare
  v_tolov int;
  v_yopiq int;
  v_grafik int;
  v_guruh_yuk int;
  v_guruh int;
  v_deadline int;
  v_qolda int;
begin
  select count(*) into v_tolov
    from entry_yuk ey join entry e on e.id = ey.entry_id
   where ey.yuk_id between 9000001 and 9000023 and e.is_deleted = false;
  if v_tolov > 0 then
    raise exception 'TO''XTADI: % ta faol to''lov (entry_yuk) shu hujjatlarga bog''langan — avval to''lovlar yechilsin', v_tolov;
  end if;
  select count(*) into v_yopiq from yuk_yopiq where yuk_id between 9000001 and 9000023 and not is_deleted;
  if v_yopiq > 0 then
    raise exception 'TO''XTADI: % ta yuk_yopiq qatori bog''langan', v_yopiq;
  end if;

  delete from yuk_tolov_grafik where yuk_id between 9000001 and 9000023;
  get diagnostics v_grafik = row_count;

  delete from yuk_grafik_guruh_yuk where yuk_id between 9000001 and 9000023;
  get diagnostics v_guruh_yuk = row_count;

  -- bo'shab qolgan guruhlar (faqat qo'lda hujjatlardan iborat edi) — grafigi bilan
  delete from yuk_tolov_grafik g
   where g.guruh_id is not null
     and not exists (select 1 from yuk_grafik_guruh_yuk gy where gy.guruh_id = g.guruh_id);
  delete from yuk_grafik_guruh g
   where not exists (select 1 from yuk_grafik_guruh_yuk gy where gy.guruh_id = g.id);
  get diagnostics v_guruh = row_count;

  delete from yuk_deadline where yuk_id between 9000001 and 9000023;
  get diagnostics v_deadline = row_count;

  update yuk_qolda
     set is_deleted = true, deleted_at = now(), deleted_by = auth.uid()
   where id between 9000001 and 9000023 and not is_deleted;
  get diagnostics v_qolda = row_count;

  raise notice 'O''chirildi: yuk_qolda % · grafik % · guruh_yuk % · bo''sh guruh % · deadline %',
    v_qolda, v_grafik, v_guruh_yuk, v_guruh, v_deadline;
end
$ochir$;

commit;

-- Tekshirish:
-- select id, yetkazuvchi, narx, valyuta, is_deleted, deleted_at from yuk_qolda order by id;
-- select jadval, count(*) from yuk_qolda_ochirish_20261103_zaxira group by 1;

-- QAYTARISH (kerak bo'lsa, alohida RUN):
-- begin;
-- update yuk_qolda set is_deleted = false, deleted_at = null, deleted_by = null
--  where id between 9000001 and 9000023;
-- insert into yuk_grafik_guruh select (jsonb_populate_record(null::yuk_grafik_guruh, qator)).*
--   from yuk_qolda_ochirish_20261103_zaxira where jadval = 'yuk_grafik_guruh'
--   on conflict (id) do nothing;
-- insert into yuk_grafik_guruh_yuk select (jsonb_populate_record(null::yuk_grafik_guruh_yuk, qator)).*
--   from yuk_qolda_ochirish_20261103_zaxira where jadval = 'yuk_grafik_guruh_yuk'
--   on conflict do nothing;
-- insert into yuk_tolov_grafik select (jsonb_populate_record(null::yuk_tolov_grafik, qator)).*
--   from yuk_qolda_ochirish_20261103_zaxira where jadval = 'yuk_tolov_grafik'
--   on conflict (id) do nothing;
-- insert into yuk_deadline select (jsonb_populate_record(null::yuk_deadline, qator)).*
--   from yuk_qolda_ochirish_20261103_zaxira where jadval = 'yuk_deadline'
--   on conflict do nothing;
-- commit;
