-- ============================================================================
--  PROVODKA_TRANSFER_1502_TUZATISH.sql — 2026-09-16 (Asilbek)
--  Transfer #1502 (Navoiy → Toshkent Kassa) — Toshkentga tushmay qolgan pul.
--
--  ######################  NIMA BO'LGAN  ####################################
--  Aros'da 1502 ichida 4 ta kunlik hujjat bor va JONLI Aros'da hammasi
--  tasdiqlangan (16.09 da API'dan o'qib tekshirildi):
--      #3001 (08.09)  naqd 2 268 000 + click   540 000
--      #3016 (09.09)  naqd 3 150 000 + click 2 574 000
--      #3039 (10.09)  naqd 4 989 000 + click 1 726 000
--      #3060 (11.09)  naqd 7 755 000 + click   776 000
--      JAMI:          naqd 18 162 000 + click 5 616 000 = 23 778 000
--
--  Provodkada esa FAQAT bittasi bor: aros_tr:1502:cash = 2 268 000.
--
--  SABAB (bizning tomonda): «Bugalter Sync» Aros'dan transferlarni faqat
--  `status=sent` bilan o'qiydi. 1502 «received» bo'lgach bizning nusxa
--  (n8n cachier_transfers) MUZLAB qolgan — kassir keyinroq qabul qilgan
--  #3016/#3039/#3060 bizga umuman yetib kelmagan. Transfer Sync v2 esa
--  o'sha muzlagan nusxadan o'qigan.
--
--  ######################  NEGA Kt 9010, Kt NAVOIY EMAS  ####################
--  Tekshirildi (16.09):
--      Aros    Navoiy kassa:  naqd 14 719 000 · click 2 811 000
--      Provodka Navoiy kassa: naqd     67 990 · click   540 000
--  Ya'ni Provodkadagi Navoiy Aros'dan ANCHA PAST — filialning savdosi
--  Provodkaga to'liq tushmagan. Demak yetishmayotgan 21.5 mln Provodkada
--  Navoiyda TURIBDI degani EMAS. Agar Kt Navoiy qilsak, Navoiy MANFIY
--  (−15.8 mln) bo'lib ketadi va Aros'dan yana uzoqlashadi.
--  Shuning uchun eski, sinovdan o'tgan qolip ishlatiladi
--  (PROVODKA_TRANSFER_TUZATISH.sql):
--        Dt <markaziy kassa tur child>  /  Kt 9010 Savdo tushumi
--  Filial tomoniga UMUMAN TEGILMAYDI.
--  🔴 Navoiyning Aros bilan tenglashmagani ALOHIDA muammo (Balans Sync) —
--     bu skript uni tuzatmaydi va yomonlashtirmaydi ham.
--
--  ######################  KALITLAR (ikki xil, ataylab)  ####################
--   • click → 'aros_tr_fix:1502:click'
--       Chunki sinxron kaliti 'aros_tr:1502:click' YO'Q. Nusxa yangilangach
--       sinxron clickni QAYTA yozib yuborishi mumkin edi — sync funksiyasi
--       aynan shu fix-kalitni ko'rib O'TKAZIB YUBORADI (ikki marta yozilmaydi).
--   • naqd → 'aros_tr_qosh:1502:naqd'  (yangi oila: «qo'shimcha»)
--       Chunki 'aros_tr:1502:cash' BOR (2 268 000) va trg_aros_tr_fix_guard
--       shu sabab 'aros_tr_fix:1502:naqd' ni RAD etadi. Sinxron esa naqdni
--       baribir qayta yozmaydi — 'aros_tr:1502:cash' mavjudligi yetarli.
--
--  Ikki marta RUN qilinsa xato bermaydi — yozilganini qayta yozmaydi
--  (summa har safar «kerak − yozilgan» qilib hisoblanadi).
--  Orqaga qaytarish: jurnaldan shu ikki yozuvni soft-delete qilish.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0) OLDINGI HOLAT
-- ---------------------------------------------------------------------------
select e.entry_date, e.ext_ref, e.description, a.code, a.name, el.debit, el.credit
  from entry e
  join entry_line el on el.entry_id = e.id
  join accounts a    on a.id = el.account_id
 where e.ext_ref in ('aros_tr:1502:cash', 'aros_tr:1502:click',
                     'aros_tr_fix:1502:click', 'aros_tr_qosh:1502:naqd')
 order by e.entry_date, e.ext_ref, el.debit desc nulls last;

do $tr1502$
declare
  -- Aros'dagi TASDIQLANGAN jami (jonli API'dan, 2026-09-16)
  c_naqd   constant numeric := 18162000;
  c_click  constant numeric := 5616000;
  c_sana   constant date    := date '2026-09-15';   -- received_at (Toshkent)

  v_dt_naqd  uuid;
  v_dt_click uuid;
  v_9010     uuid;
  v_bor      numeric;
  v_kerak    numeric;
  v_entry    uuid;
  v_n        int := 0;
begin
  -- 1) Hisoblar (kod bo'yicha, nomi ham tekshiriladi)
  select id into v_dt_naqd  from accounts where code = '5511' and is_active;
  select id into v_dt_click from accounts where code = '5512' and is_active;
  select id into v_9010     from accounts where code = '9010' and is_active;
  if v_dt_naqd is null or v_dt_click is null or v_9010 is null then
    raise exception 'Hisob topilmadi: 5511 / 5512 / 9010 (biri yo''q yoki faol emas)';
  end if;
  if not exists (select 1 from accounts where id = v_dt_naqd  and name ilike '%toshkent%naqd%')
     or not exists (select 1 from accounts where id = v_dt_click and name ilike '%toshkent%click%') then
    raise exception 'Hisob kodlari mos kelmadi — 5511/5512 Toshkent kassa naqd/click bo''lishi kerak';
  end if;

  -- ---------------------------------------------------------------------
  -- 2) NAQD:  kerak = 18 162 000 − allaqachon yozilgani
  -- ---------------------------------------------------------------------
  select coalesce(sum(el.debit), 0) into v_bor
    from entry e
    join entry_line el on el.entry_id = e.id and el.account_id = v_dt_naqd
   where e.is_deleted = false
     and e.ext_ref in ('aros_tr:1502:cash', 'aros_tr_fix:1502:naqd', 'aros_tr_qosh:1502:naqd');
  v_kerak := c_naqd - v_bor;
  raise notice 'NAQD: Aros % / Provodkada % / yozilishi kerak %', c_naqd, v_bor, v_kerak;

  if v_kerak > 0.005 then
    insert into entry(entry_date, description, source, status, created_by, ext_ref)
    values (c_sana,
            'To''g''irlash: Aros transfer #1502 · Navoiy kassa -> Toshkent kassa · Naqd '
            || '(#3016/#3039/#3060 hujjatlari kechroq tasdiqlangan, sinxron ularni ko''rmagan)',
            'aros_auto', 'posted', 'transfer_fix', 'aros_tr_qosh:1502:naqd')
    returning id into v_entry;
    insert into entry_line(entry_id, account_id, debit, credit) values (v_entry, v_dt_naqd, v_kerak, 0);
    insert into entry_line(entry_id, account_id, debit, credit) values (v_entry, v_9010, 0, v_kerak);
    v_n := v_n + 1;
    raise notice '  -> yozildi: Dt 5511 / Kt 9010 = %', v_kerak;
  else
    raise notice '  -> yozilmadi (allaqachon to''liq)';
  end if;

  -- ---------------------------------------------------------------------
  -- 3) CLICK: kerak = 5 616 000 − allaqachon yozilgani
  -- ---------------------------------------------------------------------
  select coalesce(sum(el.debit), 0) into v_bor
    from entry e
    join entry_line el on el.entry_id = e.id and el.account_id = v_dt_click
   where e.is_deleted = false
     and e.ext_ref in ('aros_tr:1502:click', 'aros_tr_fix:1502:click', 'aros_tr_qosh:1502:click');
  v_kerak := c_click - v_bor;
  raise notice 'CLICK: Aros % / Provodkada % / yozilishi kerak %', c_click, v_bor, v_kerak;

  if v_kerak > 0.005 then
    insert into entry(entry_date, description, source, status, created_by, ext_ref)
    values (c_sana,
            'To''g''irlash: Aros transfer #1502 · Navoiy kassa -> Toshkent kassa · Click '
            || '(sinxron bu turni umuman yozmagan — nusxa muzlab qolgan)',
            'aros_auto', 'posted', 'transfer_fix', 'aros_tr_fix:1502:click')
    returning id into v_entry;
    insert into entry_line(entry_id, account_id, debit, credit) values (v_entry, v_dt_click, v_kerak, 0);
    insert into entry_line(entry_id, account_id, debit, credit) values (v_entry, v_9010, 0, v_kerak);
    v_n := v_n + 1;
    raise notice '  -> yozildi: Dt 5512 / Kt 9010 = %', v_kerak;
  else
    raise notice '  -> yozilmadi (allaqachon to''liq)';
  end if;

  raise notice 'TAYYOR — % ta yangi yozuv', v_n;
end
$tr1502$;

-- ---------------------------------------------------------------------------
-- 4) YANGI HOLAT — 1502 bo'yicha hammasi (jami 23 778 000 bo'lishi kerak)
-- ---------------------------------------------------------------------------
select e.entry_date, e.ext_ref, a.code, a.name, el.debit, el.credit
  from entry e
  join entry_line el on el.entry_id = e.id
  join accounts a    on a.id = el.account_id
 where e.is_deleted = false
   and (e.ext_ref like 'aros_tr:1502:%'
     or e.ext_ref like 'aros_tr_fix:1502:%'
     or e.ext_ref like 'aros_tr_qosh:1502:%')
 order by e.entry_date, e.ext_ref, el.debit desc nulls last;

select 'Toshkentga 1502 dan tushgan jami' as nima,
       sum(el.debit) as summa,
       23778000      as kutilgan
  from entry e
  join entry_line el on el.entry_id = e.id
  join accounts a    on a.id = el.account_id and a.code in ('5511', '5512')
 where e.is_deleted = false
   and (e.ext_ref like 'aros_tr:1502:%'
     or e.ext_ref like 'aros_tr_fix:1502:%'
     or e.ext_ref like 'aros_tr_qosh:1502:%');
