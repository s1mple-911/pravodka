-- =====================================================================
-- PROVODKA_BAL_GUARD_PENDING.sql — balans qorovuli PENDING yozuvni
-- e'tiborsiz qoldirsin
-- ---------------------------------------------------------------------
-- MUAMMO (jonli): "Pul so'rash" bosilganda
--   P0001: Kassada yetarli mablag yoq. Qoldiq: 1 som (5401 ... kassasi)
--
-- Sabab: `sorov_yarat` xarajatni `status='pending'` bilan yozadi.
-- `bal_guard_entry_line` esa `entry.status` ni umuman ko'rmaydi va
-- kassani manfiyga tushiradigan kredit satrini to'sadi. Holbuki
-- so'rovlar tizimining butun maqsadi — hodim QOPLAY OLMAYDIGAN
-- xarajatni yozib, keyin pul so'rash.
--
-- 🔴 NEGA PENDING NI O'TKAZISH XAVFSIZ:
--    pending yozuv HECH QANDAY balansga kirmaydi — `acc_balance`,
--    `v_hisob_bal`, `hodim_qoldiqlar`, `jurnal_v2_baza`, `pul_qoldiq_kassa`
--    hammasi `status='posted'` filtrlaydi. Ya'ni pending satr kassani
--    manfiyga tushira OLMAYDI. Tasdiqlanganda yozuv `posted` ga o'tadi,
--    lekin o'sha paytda pul allaqachon kelgan bo'ladi va
--    `sorov_tasdiq` ning o'zi `sorov_kassa_bal(kassa) >= v_xar` ni
--    tekshiradi (PROVODKA_SOROVLAR.sql, 8.6-band).
--
-- ⚠️ MAVJUD MANTIQ O'ZGARMAYDI: `auth.uid()` istisnosi, `credit<=0`
--    erta chiqishi, `kassa_turi in ('xarajat','markaziy')` qamrovi,
--    `acc_balance` manbasi, xato matni va kodi (P0001) — HAMMASI AYNAN
--    o'sha. Qo'shilgani — bitta `if`.
--
-- Bo'limlarni bittalab RUN qiling.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — HOZIRGI HOLAT (faqat ko'radi)                       ##
-- #####################################################################

-- 0.1 Qorovul hozir pending ni ko'radimi? (ikkalasi ham false bo'lishi kutiladi)
select p.proname,
       (p.prosrc ilike '%pending%') as pending_istisnosi_bor,
       p.prosecdef                  as security_definer
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname = 'bal_guard_entry_line';

-- 0.2 Trigger o'z joyidami
select t.tgname, t.tgrelid::regclass as jadval, t.tgenabled as holat
  from pg_trigger t
 where t.tgname = 'trg_bal_guard_entry_line';

-- 0.3 Hozir nechta pending yozuv bor (so'rov yuborilgan bo'lsa > 0)
select count(*) as pending_yozuv from entry where status = 'pending';


-- #####################################################################
-- ##  1-BO'LIM — TUZATISH                                            ##
-- #####################################################################
-- Bazadan olingan asl kod + BITTA yangi `if`. Trigger qayta yaratilmaydi
-- (u ayni funksiyaga bog'langan, `create or replace` yetarli).
-- ---------------------------------------------------------------------

create or replace function public.bal_guard_entry_line()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_turi text;
  v_bal  numeric;
  v_lbl  text;
  v_st   text;
begin
  -- service_role / n8n avtomatik sinxron (auth.uid() yo'q) — tekshirmaymiz.
  -- (Aros sinxroni filial kassalarga yozadi; markaziy kirim ham bloklanmasin.)
  if auth.uid() is null then
    return new;
  end if;

  -- faqat pul chiqishi (kredit) tekshiriladi; kirim (debit) erkin
  if new.credit is null or new.credit <= 0 then
    return new;
  end if;

  select a.kassa_turi, coalesce(a.code || ' ' || a.name, new.account_id::text)
    into v_turi, v_lbl
    from accounts a
   where a.id = new.account_id;

  -- pul kassasi emas yoki qamrovga kirmaydi -> tekshirmaymiz
  if v_turi is null or v_turi not in ('xarajat', 'markaziy') then
    return new;
  end if;

  -- 🔴 YANGI: PENDING yozuv balansga TA'SIR QILMAYDI (hamma qoldiq
  --    hisobi `status='posted'` filtrlaydi), demak kassani manfiyga
  --    tushira olmaydi. So'rovlar tizimi aynan shunday yozuv yozadi:
  --    hodim qoplay olmaydigan xarajat -> pending -> pul so'raladi.
  --    Yozuv `posted` ga faqat `sorov_tasdiq` orqali o'tadi, u esa
  --    o'zi qoldiqni tekshiradi (PROVODKA_SOROVLAR.sql 8.6).
  --    Bu tekshiruv ATAYLAB shu yerda — qamrovdan tashqari satrlar
  --    (kirim, boshqa kassa turlari) unga umuman yetib kelmaydi,
  --    ya'ni oddiy yozuv yo'liga qo'shimcha so'rov qo'shilmaydi.
  select e.status into v_st from entry e where e.id = new.entry_id;
  if v_st = 'pending' then
    return new;
  end if;

  -- qoldiq = acc_balance(kassa). UI ham shu manbadan ko'rsatadi (server=UI mos).
  v_bal := coalesce(acc_balance(new.account_id), 0);

  if new.credit > v_bal then
    raise exception 'Kassada yetarli mablag yoq. Qoldiq: % som (% kassasi)',
      to_char(round(v_bal), 'FM999999999990'), v_lbl
      using errcode = 'P0001';
  end if;

  return new;
end $fn$;

comment on function public.bal_guard_entry_line() is
  'entry_line qorovuli: kassadan qoldiqdan ortiq pul chiqmasin. '
  'PENDING yozuv (sorovlar tizimi) tekshirilmaydi — u balansga kirmaydi.';


-- #####################################################################
-- ##  2-BO'LIM — TASDIQ                                              ##
-- #####################################################################

-- 2.1 Istisno o'rnidami va eski mantiq saqlanganmi (hammasi true)
select (p.prosrc ilike '%pending%')                as pending_istisnosi_bor,
       (p.prosrc ilike '%auth.uid() is null%')     as sync_istisnosi_saqlangan,
       (p.prosrc ilike '%acc_balance%')            as manba_saqlangan,
       (p.prosrc ilike '%xarajat%')                as qamrov_saqlangan,
       (p.prosrc ilike '%P0001%')                  as xato_kodi_saqlangan,
       p.prosecdef                                 as definer_saqlangan
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname = 'bal_guard_entry_line';

-- 2.2 Trigger hamon shu funksiyaga bog'langanmi (1 qator, 'O' = yoqilgan)
select t.tgname, p.proname, t.tgenabled
  from pg_trigger t join pg_proc p on p.oid = t.tgfoid
 where t.tgname = 'trg_bal_guard_entry_line';


-- #####################################################################
-- ##  3-BO'LIM — QO'LDA SINOV (brauzerda)                            ##
-- #####################################################################
-- 1) hodim-dev.html -> qoldiqdan KO'P summa -> "Pul so'rash" -> saqlash
--    KUTILGAN: so'rov yaratiladi, P0001 CHIQMAYDI.
-- 2) hodim-dev.html -> qoldiqdan KO'P summa -> oddiy "Saqlash"
--    KUTILGAN: tugma o'chiq (klient bloki) — o'zgarmagan.
-- 3) provodka-dev.html -> markaziy kassadan qoldiqdan ortiq chiqim
--    KUTILGAN: P0001 CHIQADI (qorovul avvalgidek ishlaydi).
-- 4) Aros avtosinxron (30 daqiqa)
--    KUTILGAN: to'xtamaydi (auth.uid() null istisnosi).


-- #####################################################################
-- ##  4-BO'LIM — QOLDIQ XAVF (hujjatlashtirilgan, hozir yopilmagan)  ##
-- #####################################################################
-- ⚠️ `bal_guard_entry_line` `entry_line` ustida turadi. Yozuv `pending`
--    holatda yozilib, KEYIN `entry.status` `posted` ga o'zgartirilsa
--    qorovul QAYTA ishlamaydi (chunki `entry_line` o'zgarmaydi).
--
--    Amalda bu yo'l YOPIQ:
--      * `entry` ni tahrirlash faqat ADMIN uchun ochiq (CLAUDE.md, RLS);
--      * `sorov_tasdiq` `posted` ga o'tkazishdan oldin
--        `sorov_kassa_bal(kassa) >= v_xar` ni tekshiradi.
--
--    Ya'ni bu xavf faqat "admin qo'lda `update entry set status='posted'`
--    qildi" holatida bor. Kerak bo'lsa keyingi bosqichda `entry` ustiga
--    BEFORE UPDATE qorovuli qo'shiladi (pending -> posted o'tishida
--    kredit satrlarini qayta tekshiradi). Hozir ATAYLAB qo'shilmadi:
--    yangi qorovul yangi to'siq demakdir va u ham UI bilan birga
--    sinovdan o'tishi kerak.


-- #####################################################################
-- ##  5-BO'LIM — ROLLBACK                                            ##
-- #####################################################################
-- Yuqoridagi funksiyadan `v_st` e'lonini va yangi `if` blokini olib
-- tashlab qayta RUN qiling — qolgani asl kod bilan aynan bir xil.
-- ⚠️ Qaytarishdan OLDIN pending yozuvlar yo'qligiga ishonch hosil qiling:
--   select count(*) from entry where status = 'pending';
