-- =====================================================================
--  PROVODKA_SYNC_ROLLBACK.sql — noto'g'ri aros_auto yozuvlarini o'chirish
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  🔴 AVVAL O'QING — YOZUVLARNI KIM YOZGANI ANIQLANDI
--
--  Pul ombor hisoblariga (2911, warehouse_id=1) tushgan, kassa child'lariga
--  emas. Sababi sync_filial_balans RPC EMAS. Tekshirildi:
--     • RPC ichida account_id FAQAT bitta joyda, faqat v_filial_sync_mapping'dan
--       olinadi; accounts'ga to'g'ridan murojaat faqat 9010 ni topish uchun.
--     • "Aros Provodka - Auto Sync" (7MSHrXnz9cGAFBTh) — O'CHIRILGAN (active=false).
--
--  ✅ HAQIQIY SABAB: n8n workflow **"Aros Provodka - Tovar Sync"**
--     (DkIxfOW2kLs0tpIe) — HALI FAOL, HAR SOATDA ishlaydi.
--     U cache_filial'dan ombor qoldig'ini olib `sync_tovar_balances` RPC'siga
--     yuboradi; kalit sifatida **warehouse_id** ishlatadi (shuning uchun
--     warehouse_id=1 bo'lgan 2911 ga tushgan). U ham delta sync:
--     "o'sish = tovar kirimi, kamayish = COGS".
--     Wipe'dan keyin daftarda ombor 0, Aros'da esa haqiqiy tovar bor edi —
--     shuning uchun butun ombor qoldig'ini bitta kirim qilib yozib qo'ygan.
--
--  ⚠️⚠️ SHUNING UCHUN: AVVAL n8n'da "Aros Provodka - Tovar Sync" ni
--        O'CHIRING (deactivate), KEYIN bu skriptni RUN qiling.
--        Aks holda yozuvlar bir soat ichida QAYTA paydo bo'ladi.
--
--  Eslatma: bu yozuvlar "buzuq" emas — workflow o'z vazifasini bajargan.
--  Faqat wipe'dan keyingi holatda ombor boshlang'ich qoldig'i "tovar kirimi"
--  bo'lib yozilgan. Ombor ham xuddi kassa kabi boshlang'ich qoldiq sifatida
--  (Kt boshlang'ich kapital) kiritilishi kerak — buni keyingi bosqichda hal
--  qilamiz. Hozir shunchaki tozalaymiz.
--
--  ATOMIK: bitta tranzaksiya. Sanoq mos kelmasa hech narsa o'chmaydi.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. NIMA O'CHADI — avval shuni o'qing
-- ---------------------------------------------------------------------

-- 0.1 aros_auto yozuvlari KIM tomonidan yozilgani bo'yicha
--     (sync_filial_balans 'aros_sync' deb yozadi — boshqasi Tovar Sync)
select coalesce(e.created_by, '(bo''sh)') as kim,
       count(distinct e.id)              as yozuvlar,
       min(e.entry_date)                 as birinchi,
       max(e.entry_date)                 as oxirgi,
       sum(l.debit)                      as jami_debit
  from entry e
  join entry_line l on l.entry_id = e.id
 where e.source = 'aros_auto' and e.is_deleted = false
 group by coalesce(e.created_by, '(bo''sh)')
 order by yozuvlar desc;

-- 0.2 Qaysi hisoblarga tushgan (ombor'lar shu yerda ko'rinadi)
select a.code, a.name, a.section, a.type,
       a.warehouse_id, a.filial_ref,
       a.parent_id is null as mustaqil,
       count(*)            as satrlar,
       sum(l.debit)        as debit,
       sum(l.credit)       as kredit
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a   on a.id = l.account_id
 where e.source = 'aros_auto' and e.is_deleted = false
 group by a.code, a.name, a.section, a.type, a.warehouse_id, a.filial_ref, a.parent_id
 order by a.code;

-- 0.3 Jami sanoq (kutilgani: 54)
select count(*) as aros_auto_yozuvlar
  from entry
 where source = 'aros_auto' and is_deleted = false;


-- ---------------------------------------------------------------------
-- 1. O'CHIRISH
-- ---------------------------------------------------------------------
do $rb$
declare
  -- ⚙️ SOZLAMALAR
  --   p_kutilgan_soni : xavfsizlik. Shuncha yozuv bo'lishi kutiladi; mos
  --                     kelmasa HECH NARSA o'chmaydi (kimdir/nimadir yana
  --                     yozgan bo'lsa ko'r-ko'rona o'chirib yubormaylik).
  --                     0 qo'ysangiz tekshiruv o'chadi.
  --   p_faqat_kassadan_tashqari : true bo'lsa FAQAT kassa tur child'i
  --                     BO'LMAGAN hisoblarga tegadigan yozuvlar o'chadi
  --                     (ya'ni ombor'lar). false = hamma aros_auto yozuvi.
  p_kutilgan_soni           int     := 54;
  p_faqat_kassadan_tashqari boolean := false;

  v_ids     uuid[];
  v_soni    int;
  v_jami    int;
  v_satr    int;
begin
  select count(*) into v_jami
    from entry where source = 'aros_auto' and is_deleted = false;

  if p_kutilgan_soni > 0 and v_jami <> p_kutilgan_soni then
    raise exception 'TO''XTADI: aros_auto yozuvlari % ta, kutilgani % ta. '
                    'Oradan vaqt o''tib yana yozilganmi? "Tovar Sync" o''chirilganmi? '
                    'Sanoqni tekshirib p_kutilgan_soni ni to''g''rilang (yoki 0 qiling).',
                    v_jami, p_kutilgan_soni;
  end if;

  -- O'chiriladigan entry id'lari
  if p_faqat_kassadan_tashqari then
    select array_agg(distinct e.id) into v_ids
      from entry e
      join entry_line l on l.entry_id = e.id
     where e.source = 'aros_auto' and e.is_deleted = false
       and exists (
             select 1 from accounts a
              where a.id = l.account_id
                and not (a.section = 'pul' and a.parent_id is not null
                         and (a.pul_turi in ('naqd','click','payme') or a.currency = 'USD'))
                and a.code <> '9010'
           );
  else
    select array_agg(e.id) into v_ids
      from entry e
     where e.source = 'aros_auto' and e.is_deleted = false;
  end if;

  v_soni := coalesce(array_length(v_ids, 1), 0);
  if v_soni = 0 then
    raise notice 'O''chiriladigan yozuv topilmadi — hech narsa qilinmadi.';
    return;
  end if;

  -- Bog'liq jadvallar avval (FK cascade bo'lmasa xato bermasin)
  if to_regclass('public.entry_yuk') is not null then
    delete from entry_yuk where entry_id = any(v_ids);
  end if;
  if to_regclass('public.entry_history') is not null then
    delete from entry_history where entry_id = any(v_ids);
  end if;

  delete from entry_line where entry_id = any(v_ids);
  get diagnostics v_satr = row_count;

  delete from entry where id = any(v_ids);

  raise notice '--- O''CHIRILDI: % ta yozuv, % ta satr', v_soni, v_satr;
  raise notice 'ESLATMA: "Aros Provodka - Tovar Sync" faol qolgan bo''lsa, '
               'ombor yozuvlari BIR SOAT ichida qayta paydo bo''ladi.';
end
$rb$;


-- ---------------------------------------------------------------------
-- 2. TEKSHIRUV
-- ---------------------------------------------------------------------

-- 2.1 aros_auto yozuvlari qoldimi (0 bo'lishi kerak)
select count(*) as qolgan_aros_auto
  from entry where source = 'aros_auto' and is_deleted = false;

-- 2.2 Ombor hisoblari 0 ga qaytdimi
select a.code, a.name, a.section,
       coalesce(sum(l.debit - l.credit), 0) as qoldiq
  from accounts a
  left join entry_line l on l.account_id = a.id
  left join entry e on e.id = l.entry_id and e.status = 'posted' and e.is_deleted = false
 where a.code in ('2911') or a.section = 'tovar'
 group by a.code, a.name, a.section
 order by a.code;

-- 2.3 Kassa qoldiqlari (sync hali to'g'ri yozmagan bo'lsa 0)
select code, name, kassa_turi, naqd, click, payme, usd, jami
  from v_kassa_card
 where kassa_turi = 'filial'
 order by code
 limit 20;

-- 2.4 Balans tenglikda qoldimi (eng muhim)
select sum(case when bolim = 'AKTIV'   then amount else 0 end) as aktiv,
       sum(case when bolim = 'PASSIV'  then amount else 0 end) as passiv,
       sum(case when bolim = 'KAPITAL' then amount else 0 end) as kapital,
       sum(case when bolim = 'AKTIV'   then amount else 0 end)
     - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end) as farq
  from balans(current_date);
-- farq = 0 bo'lishi SHART.

-- 2.5 Umuman qancha yozuv qoldi (wipe'dan keyingi holat)
select count(*) as jami_entry,
       count(*) filter (where source = 'manual')    as manual,
       count(*) filter (where source = 'aros_auto') as aros_auto
  from entry where is_deleted = false;
