-- =====================================================================
--  PROVODKA_WIPE.sql  —  ⚠️ TEST TARIXINI TOZALASH (QAYTARIB BO'LMAYDI)
-- ---------------------------------------------------------------------
--  Vazifasi: prodga toza start. BARCHA tranzaksiya yozuvlari o'chadi,
--  kassalar avtomat 0 ga qaytadi (double-entry: qoldiq entry_line'dan
--  hisoblanadi, alohida "qoldiq" ustuni yo'q).
--
--  O'CHADI (faqat tranzaksiya yozuvlari):
--    entry, entry_line, entry_yuk, entry_history, convert_request
--    → boshlang'ich qoldiq yozuvlari ham entry, ular ham ketadi
--    → konvert yozuvlari ham entry, ular ham ketadi
--    → standart_xarajat "sarflangani" entry'dan hisoblanadi → avtomat 0
--
--  QOLADI (tuzilma va sozlamalar):
--    accounts (kassalar/moddalar, filial_ref, linked_kassa_id, parent_id),
--    user_perms (ruxsatlar), standart_xarajat (LIMITLAR o'zi),
--    provodka_config, profiles, currency_rate (kurslar),
--    valyuta_kod_blok, filial_snapshot, sync_state
--
--  BIR MARTA ishlatiladi, prodga chiqish OLDIDAN, hamma test tugagach.
-- =====================================================================
--
--  ⚠️⚠️  RUN QILISHDAN OLDIN — 3 QADAM  ⚠️⚠️
--
--  1) n8n "Aros Provodka - Auto Sync" (7MSHrXnz9cGAFBTh) ni O'CHIRING
--     (deactivate). Har 30 daqiqada ishlaydi — wipe paytida tushib qolsa
--     yarim tozalangan holat ustiga yozadi.
--
--  2) SUPABASE BACKUP oling (Database → Backups → yoki pg_dump).
--     Bu skript tranzaksiya ichida, lekin COMMIT bo'lgach qaytarib
--     bo'lmaydi. Backup — yagona orqaga yo'l.
--
--  3) WIPE'DAN KEYIN Auto Sync'ni qaytarganda NIMA BO'LADI — biling:
--
--     a) Qabul qilingan transferlar: sync `sync_state.transfers_from`
--        dan keyingi transferlarni oladi. Bu skript sync_state'ga
--        TEGMAYDI → o'chirilgan eski transferlar QAYTA KELMAYDI.
--        (Agar qaytishini xohlasangiz — quyidagi 5-BO'LIMdagi izohli
--        `update sync_state` ni ochib, sanani orqaga suring. Diqqat:
--        entry.ext_ref unique edi, endi bo'sh — takror to'sig'i yo'q.)
--
--     b) ⚠️ FILIAL BALANSLARI — DIQQAT. Sync mantiqi: "Aros'dagi filial
--        balansi daftardagidan oshgan bo'lsa → Dt filial kassa /
--        Kt 9010 savdo tushumi". Wipe'dan keyin daftarda 0, Aros'da esa
--        haqiqiy pul (hozir ~24 filialda pul bor). Ya'ni keyingi sync
--        butun filial pulini BITTA KATTA "savdo tushumi" yozuvi qilib
--        kiritadi — o'sha kunning P&L'i shuncha shishadi.
--
--        Bu tushum emas, boshlang'ich qoldiq. Ikki yo'l bor, BIRINI
--        tanlash Asilbekda:
--          • Roziман: sync o'zi yozib qo'yadi, keyin o'sha bitta yozuvni
--            jurnalda tahrirlab Kt'ni 9010 → kapital/boshlang'ich
--            hisobiga o'zgartirasiz.
--          • Roziman emasman: sync'ni yoqishdan oldin filial
--            boshlang'ich qoldiqlarini qo'lda kiritasiz
--            (Dt filial kassa / Kt boshlang'ich kapital), shundan keyin
--            sync farq ko'rmaydi va tushum yozmaydi.
--
--  ---------------------------------------------------------------------
--  MUQOBIL: faqat qo'lda kiritilgan test yozuvlarini o'chirish
--  (aros_auto yozuvlar qolsin). Asilbek "hammasi" dedi, shuning uchun
--  standart holat — HAMMASI. Faqat manual kerak bo'lsa: 3-BO'LIMdagi
--  `p_faqat_manual` ni true qiling.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1-BO'LIM. OLDINGI HOLAT — o'chirishdan oldin ko'rib chiqing
-- ---------------------------------------------------------------------
-- Buni ALOHIDA ishga tushiring (pastdagi DO blokidan oldin), natijani
-- o'qing, keyin davom eting.

select 'entry'           as jadval, count(*) as qatorlar from entry
union all select 'entry_line',      count(*) from entry_line
union all select 'entry (manual)',  count(*) from entry where source = 'manual'
union all select 'entry (aros_auto)', count(*) from entry
            where source is distinct from 'manual';

-- Kassa qoldiqlari (wipe'dan keyin hammasi 0 bo'lishi kerak):
select code, name, jami
  from v_kassa_card
 where jami <> 0
 order by jami desc;


-- ---------------------------------------------------------------------
-- 2-BO'LIM. TOZALASH
-- ---------------------------------------------------------------------
-- Bitta tranzaksiya. Oxirida tekshiruv: biror narsa qolsa RAISE bo'ladi
-- va HAMMASI orqaga qaytadi (rollback) — yarim tozalangan holat bo'lmaydi.

do $wipe$
declare
  -- ⚙️ SOZLAMA: true bo'lsa faqat source='manual' yozuvlar o'chadi.
  --    false (standart) = hamma yozuv, aros_auto ham.
  p_faqat_manual boolean := false;

  v_entry_oldin   bigint;
  v_line_oldin    bigint;
  v_entry_qoldi   bigint;
  v_line_qoldi    bigint;
  v_kassa_qoldi   bigint;
begin
  select count(*) into v_entry_oldin from entry;
  select count(*) into v_line_oldin  from entry_line;

  raise notice '--- WIPE boshlandi. entry=% , entry_line=% , faqat_manual=%',
    v_entry_oldin, v_line_oldin, p_faqat_manual;

  -- ---- 2.1 Bog'liq jadvallar (entry'dan oldin) ----------------------
  -- Har biri "bor bo'lsa" tekshiriladi: bu skript boshqa muhitda ham
  -- (jadval yo'q bo'lsa) xato bermasin.

  -- entry_yuk: entry_id FK'si `on delete cascade` — lekin aniq o'chiramiz
  if to_regclass('public.entry_yuk') is not null then
    if p_faqat_manual then
      delete from entry_yuk ey using entry e
       where e.id = ey.entry_id and e.source = 'manual';
    else
      delete from entry_yuk;
    end if;
    raise notice 'entry_yuk tozalandi';
  end if;

  -- entry_history: tahrir/o'chirish tarixi. Yozuvlar ketsa tarixi ham ketadi.
  if to_regclass('public.entry_history') is not null then
    if p_faqat_manual then
      delete from entry_history h using entry e
       where e.id = h.entry_id and e.source = 'manual';
    else
      delete from entry_history;
    end if;
    raise notice 'entry_history tozalandi';
  end if;

  -- convert_request: konvert so'rovlari (pending + tarix). Test so'rovlari,
  -- ketishi kerak. entry_id ustuni entry'ga ishora qiladi — entry'dan
  -- OLDIN o'chirilishi shart (FK cascade bo'lmasa xato beradi).
  if to_regclass('public.convert_request') is not null then
    if p_faqat_manual then
      delete from convert_request cr
       where cr.entry_id is null
          or exists (select 1 from entry e
                      where e.id = cr.entry_id and e.source = 'manual');
    else
      delete from convert_request;
    end if;
    raise notice 'convert_request tozalandi';
  end if;

  -- ---- 2.2 entry_line + entry ---------------------------------------
  -- entry_line BITTA statement bilan o'chiriladi. Sababi: Dt=Kt balans
  -- triggeri AFTER ROW bo'lsa, u statement oxirida ishlaydi — o'shanda
  -- satrlar allaqachon yo'q (0 = 0, balans buzilmadi). Satrlarni bo'lib
  -- o'chirsa, oraliq holatda Dt <> Kt bo'lib trigger to'sishi mumkin.
  if p_faqat_manual then
    delete from entry_line el using entry e
     where e.id = el.entry_id and e.source = 'manual';
    delete from entry where source = 'manual';
  else
    delete from entry_line;
    delete from entry;
  end if;

  raise notice 'entry + entry_line tozalandi';

  -- ---- 2.3 TEKSHIRUV -------------------------------------------------
  select count(*) into v_entry_qoldi from entry
   where p_faqat_manual = false or source = 'manual';
  select count(*) into v_line_qoldi from entry_line;

  if v_entry_qoldi <> 0 then
    raise exception 'WIPE TO''XTADI: entry''da hali % qator qoldi — hech narsa o''chmadi (rollback)', v_entry_qoldi;
  end if;

  if p_faqat_manual = false and v_line_qoldi <> 0 then
    raise exception 'WIPE TO''XTADI: entry_line''da hali % qator qoldi — hech narsa o''chmadi (rollback)', v_line_qoldi;
  end if;

  -- Kassa qoldiqlari: hamma yozuv ketgan bo'lsa 0 bo'lishi SHART.
  if p_faqat_manual = false and to_regclass('public.v_kassa_card') is not null then
    select count(*) into v_kassa_qoldi from v_kassa_card where coalesce(jami,0) <> 0;
    if v_kassa_qoldi <> 0 then
      raise exception 'WIPE TO''XTADI: % kassada qoldiq 0 emas — hech narsa o''chmadi (rollback)', v_kassa_qoldi;
    end if;
    raise notice 'TEKSHIRUV: hamma kassa qoldig''i 0 ✓';
  end if;

  raise notice '--- WIPE TUGADI. Oldin entry=% , endi entry=% ✓', v_entry_oldin, v_entry_qoldi;
end
$wipe$;


-- ---------------------------------------------------------------------
-- 3-BO'LIM. WIPE'DAN KEYIN TEKSHIRUV (ko'z bilan ko'rish uchun)
-- ---------------------------------------------------------------------
select 'entry'      as jadval, count(*) as qoldi from entry
union all select 'entry_line',       count(*) from entry_line
union all select 'entry_yuk',        count(*) from entry_yuk
union all select 'convert_request',  count(*) from convert_request;

-- Hammasi 0 bo'lishi kerak. Kassalar:
select count(*) as nol_bolmagan_kassa
  from v_kassa_card
 where coalesce(jami,0) <> 0;

-- QOLGANI joyida turibdimi (bularning soni 0 BO'LMASLIGI kerak):
select 'accounts'         as jadval, count(*) as qoldi from accounts
union all select 'user_perms',        count(*) from user_perms
union all select 'standart_xarajat',  count(*) from standart_xarajat
union all select 'currency_rate',     count(*) from currency_rate
union all select 'profiles',          count(*) from profiles;

-- Standart xarajat: limitlar joyida, sarflangani 0 bo'lishi kerak
-- (sarflangani entry'dan hisoblanadi). standart_holat(p_oy date) — sana oladi:
select filial_name, modda_name, limit_uzs, sarflandi, qoldi
  from standart_holat(date_trunc('month', current_date)::date);


-- ---------------------------------------------------------------------
-- 4-BO'LIM. FRONTEND
-- ---------------------------------------------------------------------
-- Sahifalar sessionStorage'da kesh saqlaydi (prov-swr:*), 5 daqiqa TTL.
-- Wipe'dan keyin brauzerda eski raqamlar ko'rinishi mumkin — bu xato emas,
-- 5 daqiqada o'zi almashadi. Darrov ko'rish uchun: Ctrl+Shift+R (hard reload)
-- yoki chiqib-kirish (logout permClear() qiladi).


-- ---------------------------------------------------------------------
-- 5-BO'LIM. IXTIYORIY — sync'ni orqaga surish
-- ---------------------------------------------------------------------
-- FAQAT aros_auto transferlar QAYTA kelishini xohlasangiz oching.
-- Standart holatda TEGMANG: o'chirilgani o'chirilgan qolsin.
--
-- update sync_state set transfers_from = '2026-01-01T00:00:00Z' where true;
--
-- Diqqat: entry.ext_ref unique to'sig'i takrorlanishni to'sadi, lekin
-- yozuvlar o'chirilgani uchun endi bo'sh — sync o'sha transferlarni
-- yangidan yozadi.
