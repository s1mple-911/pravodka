-- ============================================================================
--  PROVODKA_KURS_FARQI_TOZALASH.sql — 2026-09-21 — valyuta bola-hisobida DOLLAR 0, SO'M qoldiq ≠ 0
--  Hodisa: G'iyos · USD (5669) — $1 226 019 kirdi (12 000/11 950/11 900/11 850 kurslarida),
--  19.09 da hammasi 11 850 da chiqarildi → dollar 0, lekin so'm ekvivalenti 94 425 650 qoldi.
--  Bu kurs farqi: Dt «Konvert kurs farqi» (conv_farq_hisob_id) / Kt valyuta hisobi, fc_amount 0.
--  1-BO'LIM: faqat SELECT — shunday hisoblar ro'yxati. 2-BO'LIM: BARCHASINI yopadi (kalit bilan, takror xavfsiz).
--  Asilbek RUN qiladi (SQL editor — auth.uid() null, guardlar o'tadi).
-- ============================================================================

-- ---------------------------------------------------------------- 1-BO'LIM: ro'yxat
select c.code, c.name, k.code as kassa, round(b.uzs) as som_qoldiq, b.fc as valyuta_qoldiq,
       (select count(*) from entry_line el where el.account_id = c.id) as satrlar
  from accounts c
  join accounts k on k.id = c.parent_id
  join v_hisob_bal b on b.account_id = c.id
 where c.is_active and c.section = 'pul' and c.currency <> 'UZS'
   and abs(coalesce(b.fc, 0)) < 0.01 and abs(coalesce(b.uzs, 0)) >= 1
 order by abs(b.uzs) desc;

-- ---------------------------------------------------------------- 2-BO'LIM: yopish
do $kf$
declare
  r        record;
  v_farq   uuid;
  v_entry  uuid;
  v_n      int := 0;
begin
  execute 'select public.conv_farq_hisob_id()' into v_farq;
  if v_farq is null then
    raise exception 'conv_farq_hisob_id() null — «Konvert kurs farqi» moddasi topilmadi';
  end if;
  for r in
    select c.id, c.code, c.name, round(b.uzs, 2) as uzs
      from accounts c
      join v_hisob_bal b on b.account_id = c.id
     where c.is_active and c.section = 'pul' and c.currency <> 'UZS'
       and abs(coalesce(b.fc, 0)) < 0.01 and abs(coalesce(b.uzs, 0)) >= 1
  loop
    if exists (select 1 from entry where ext_ref = 'kursfarq:' || r.id::text and is_deleted = false) then
      continue;
    end if;
    insert into entry (entry_date, description, source, status, ext_ref)
      values ((now() at time zone 'Asia/Tashkent')::date,
              'Kurs farqi tozalash (Asilbek 21.09.2026): ' || r.code || ' ' || r.name || ' (valyuta 0, so''m qoldiq ' || r.uzs::text || ')',
              'manual', 'posted', 'kursfarq:' || r.id::text)
      returning id into v_entry;
    if r.uzs > 0 then
      -- so'm ortiqcha qolgan → xarajat (kurs farqi zarari): Dt farq / Kt valyuta hisobi
      insert into entry_line (entry_id, account_id, debit, credit, fc_amount) values (v_entry, v_farq, r.uzs, 0, null);
      insert into entry_line (entry_id, account_id, debit, credit, fc_amount) values (v_entry, r.id, 0, r.uzs, 0);
    else
      -- so'm manfiy qolgan → kurs farqi foydasi: Dt valyuta hisobi / Kt farq
      insert into entry_line (entry_id, account_id, debit, credit, fc_amount) values (v_entry, r.id, -r.uzs, 0, 0);
      insert into entry_line (entry_id, account_id, debit, credit, fc_amount) values (v_entry, v_farq, 0, -r.uzs, null);
    end if;
    v_n := v_n + 1;
    raise notice 'kurs farqi: % % → % so''m (entry %)', r.code, r.name, r.uzs, v_entry;
  end loop;
  raise notice 'KURS FARQI TOZALASH: % hisob yopildi', v_n;
end
$kf$;

-- natija: endi ro'yxat bo'sh bo'lishi kerak
select c.code, c.name, round(b.uzs) as som_qoldiq, b.fc
  from accounts c join v_hisob_bal b on b.account_id = c.id
 where c.is_active and c.section = 'pul' and c.currency <> 'UZS'
   and abs(coalesce(b.fc, 0)) < 0.01 and abs(coalesce(b.uzs, 0)) >= 1;
