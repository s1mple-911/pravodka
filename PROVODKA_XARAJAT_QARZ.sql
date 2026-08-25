-- =====================================================================
-- PROVODKA_XARAJAT_QARZ.sql
-- "To'lanmagan xarajat" (qarz hisobi 6721+) ni ASOSIY oqimga ulash
-- ---------------------------------------------------------------------
-- ## MUAMMO (tasdiqlangan)
-- `hodim_tolanmagan_bir()` va `v_hodim_tolanmagan` to'lanmagan xarajatni
-- QARZ HISOBI (6721+) yozuvlaridan o'qiydi:
--     Kt 6721 satri bor yozuv  =  to'lanmagan xarajat.
-- Bunday satrni esa FAQAT `hodim_xarajat_yoz(jsonb)` yozadi.
--
-- Lekin `hodim-dev.html` xarajatni butunlay boshqa yo'l bilan yozadi:
--   • ODDIY yo'l (1 filial)   -> to'g'ridan `entry` + `entry_line` insert
--                                (klientda, `ext_ref` tokeni bilan);
--   • TAQSIMOT yo'li (2+ filial) -> `xarajat_saqlash_taqsim(jsonb)` RPC.
-- Ikkalasi ham qarz satrini YARATMAYDI -> Asilbek tanlagan "Variant 2 —
-- qarz hisobi" asosiy oqimda UMUMAN ishlamaydi, "To'lanmagan" ro'yxati
-- doim BO'SH bo'ladi va hodim kassasi MANFIYGA tushib ketaveradi.
--
-- ## NEGA YECHIM SERVER TOMONDA
-- Klientni to'g'ridan `hodim_xarajat_yoz()` ga o'tkazib bo'lmaydi, chunki u
-- `ext_ref` qabul qilmaydi — bu 2026-08-24 dagi PROD INSIDENT tuzatmasini
-- (bir martalik token bilan takror-himoya, `PROVODKA_EXT_REF.sql`) buzardi.
-- Shuning uchun SERVER moslashadi:
--
--   ISH 1 — `hodim_xarajat_yoz(jsonb)` ixtiyoriy `ext_ref` kalitini qabul
--           qiladi (IMZO O'ZGARMAYDI: jsonb). Endi klientni unga o'tkazish
--           MUMKIN — takror-himoya saqlanadi. (Klient ishi ALOHIDA bosqich,
--           bu faylda HTML tegilmaydi.)
--   ISH 2 — `xarajat_saqlash_taqsim(jsonb)` ga AYNAN o'sha qarz mantiqi
--           qo'shiladi: hodim kassasida qo'ldagi puldan ortig'i 6721 ga
--           tushadi. Ya'ni 2+ filialli xarajat BUGUNDAN "to'lanmagan"
--           ro'yxatiga tushadi — klientga tegmasdan.
--
-- ## QOIDALAR (buzilmadi)
--   * FAQAT ADDITIVE: `drop` yo'q, IMZO o'zgarmaydi, ustun o'chirilmaydi.
--     Ikkala RPC ni ham PROD `hodim.html` chaqiradi.
--   * `ext_ref` berilmasa VA kassa hodim kassasi bo'lmasa — natija
--     AVVALGIDEK (6-BO'LIMda satrma-satr solishtirilgan).
--   * anonim `do` bloki YO'Q (Supabase SQL editorida 42P01).
--   * Faylda RPC ni JONLI chaqiradigan operator YO'Q — faqat KATALOG va
--     jadval so'rovlari. (`PROVODKA_JURNAL_V2.sql` bugun aynan shundan
--     rollback bo'ldi: editorda `auth.uid()` null.)
--   * `security definer` + `set search_path = public` + grantlar AYNAN
--     eskisidek qayta beriladi.
--
-- ## RUN TARTIBI (Asilbek)
-- 🔴 Bu fayl IKKALA funksiyani ham `create or replace` bilan ustiga yozadi,
--    shuning uchun u ZANJIRNING OXIRIDA turishi SHART:
--
--      1) PROVODKA_HODIM_VALYUTA.sql     (xarajat_saqlash_taqsim — asosi)
--      2) PROVODKA_EXT_REF.sql           (unique indeks + ext_ref tokeni)
--      3) PROVODKA_XARAJAT_TOSIQ.sql     (6720/6721, qarz, to'siq trigger)
--      4) PROVODKA_XARAJAT_QARZ.sql      <-- SHU FAYL, oxirgi
--
--    Agar 2) yoki 3) shu fayldan KEYIN qayta RUN qilinsa — ular eski
--    versiyani tiklaydi va bu faylning ishi YO'QOLADI. U holda shu faylni
--    yana RUN qiling (idempotent, `create or replace`).
--
-- Bo'limlarni BITTALAB belgilab RUN qiling (Supabase editori faqat OXIRGI
-- natijani ko'rsatadi):
--    0-BO'LIM — OLD SHART tekshiruvi (faqat select, hech narsa o'zgarmaydi)
--    1-BO'LIM — hodim_xarajat_yoz  (create or replace)
--    2-BO'LIM — xarajat_saqlash_taqsim (create or replace)
--    3-BO'LIM — notify pgrst
--    4-BO'LIM — MOS KELISH TEKSHIRUVI (faqat katalog select)
--    5..8     — faqat izoh (SQL yo'q): to'siq tahlili, nima o'zgarmadi,
--               rollback, klient kontrakti.
--
-- ## OLD SHARTLAR
--   * `entry.ext_ref` ustuni + `entry_ext_ref_uniq` unique indeks
--                                                (PROVODKA_EXT_REF.sql)
--   * `hodim_kassa_ildiz(uuid)`, `hodim_qarz_hisob(uuid)`, 6720 konteyner
--                                                (PROVODKA_XARAJAT_TOSIQ.sql)
--   🔴 3) RUN QILINMAGAN bo'lsa ham bu fayl PRODNI SINDIRMAYDI: 2-BO'LIMdagi
--      qarz mantiqi `to_regprocedure(...) is not null` qorovuli ichida —
--      funksiyalar yo'q bo'lsa shox umuman ISHGA TUSHMAYDI va taqsimot
--      avvalgidek (qarzsiz) yozadi. Bu `convert_start_v2` dagi naqsh:
--      ikki SQL fayl bir-birining RUN tartibiga bog'lanmaydi.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (hech narsa o'zgarmaydi)       ##
-- #####################################################################
-- Har `select` ni ALOHIDA belgilab RUN qiling.

-- ---------------------------------------------------------------------
-- 0.1  Kerakli obyektlar o'rnidami?
--      `f_ildiz` / `f_qarz_hisob` / `a_6720` false chiqsa — 2-BO'LIMdagi
--      qarz mantiqi ISHGA TUSHMAYDI (qorovul uni o'chirib qo'yadi, xato
--      bermaydi). Avval PROVODKA_XARAJAT_TOSIQ.sql ni RUN qiling.
--      `i_ext_ref` false chiqsa — takror-himoya YO'Q (PROVODKA_EXT_REF.sql
--      1-BO'LIM).
-- ---------------------------------------------------------------------
select to_regprocedure('public.hodim_kassa_ildiz(uuid)')        is not null as f_ildiz,
       to_regprocedure('public.hodim_qarz_hisob(uuid)')         is not null as f_qarz_hisob,
       to_regprocedure('public.hodim_qarz_hisob_topish(uuid)')  is not null as f_qarz_topish,
       to_regprocedure('public.hodim_tolanmagan_bir(uuid)')     is not null as f_tolanmagan,
       to_regprocedure('public.hodim_xarajat_yoz(jsonb)')       is not null as f_xarajat_yoz,
       to_regprocedure('public.xarajat_saqlash_taqsim(jsonb)')  is not null as f_taqsim,
       exists (select 1 from accounts where code = '6720')                  as a_6720,
       exists (select 1 from pg_class where relname = 'entry_ext_ref_uniq') as i_ext_ref;


-- ---------------------------------------------------------------------
-- 0.2  Overload bormi? (PostgREST PGRST203 xavfi)
--      Kutilgan: 2 qator, ikkalasida ham `overload_soni = 1`,
--      `imzolar = 'jsonb'`.
-- ---------------------------------------------------------------------
select p.proname,
       count(*)                                                              as overload_soni,
       string_agg(pg_get_function_identity_arguments(p.oid), ' | ')           as imzolar
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('hodim_xarajat_yoz', 'xarajat_saqlash_taqsim')
 group by p.proname
 order by p.proname;


-- ---------------------------------------------------------------------
-- 0.3  Hozircha qarz satri (Kt 6721+) YOZILGANMI?
--      Muammo tasdig'i: bu son 0 bo'lishi kutiladi — ya'ni "To'lanmagan"
--      ro'yxati bo'sh. Shu fayldan KEYIN qoldiqdan ortiq xarajat yozilsa
--      son o'sa boshlaydi.
--      (Jadval so'rovi, RPC chaqiruvi EMAS.)
-- ---------------------------------------------------------------------
select count(*)                                       as qarz_satrlari,
       count(distinct l.entry_id)                     as qarz_yozuvlari,
       coalesce(sum(l.credit), 0) - coalesce(sum(l.debit), 0) as qarz_qoldiq_jami
  from entry_line l
  join entry e   on e.id = l.entry_id
  join accounts q on q.id = l.account_id
  join accounts g on g.id = q.parent_id and g.code = '6720'
 where e.status = 'posted' and e.is_deleted = false;


-- #####################################################################
-- ##  1-BO'LIM — ISH 1: hodim_xarajat_yoz(jsonb) + ext_ref           ##
-- #####################################################################
-- 🔴 IMZO O'ZGARMAYDI: hodim_xarajat_yoz(jsonb). Argument QO'SHILMAYDI —
--    faqat YANGI KALIT (`p_data.ext_ref`). Kalit berilmasa xatti-harakat
--    AYNAN eskisidek (entry.ext_ref = null).
--
-- NIMA QO'SHILDI (uchtasi, boshqa hech narsa):
--   1) `v_ext` — `p_data->>'ext_ref'`, 8..120 belgi tekshiruvi
--      (`xarajat_saqlash_taqsim` dagi AYNAN o'sha shart va o'sha matn).
--   2) `entry` insertiga `ext_ref` ustuni qo'shildi.
--   3) `exception when unique_violation` — takror kelsa 23505 va
--      "Bu xarajat allaqachon saqlangan (takroriy yuborish tosildi)".
--      Kod ham, matn ham `xarajat_saqlash_taqsim` bilan BIR XIL, ya'ni
--      klientning `isDup(e)` shoxi ikkala yo'lda ham bir xil ishlaydi.
--   +) `lock_timeout = 5s` — taqsimot RPC'si bilan bir xil (baza band
--      bo'lsa "Saqlanmoqda…" abadiy aylanmasin, 55P03 bilan qaytsin).
--
-- 🔴 TOKEN SHAKLI — SUFFIKSSIZ (`<token>`, `<token>:1` EMAS).
--    Sabab: bu RPC BITTA entry yozadi, ya'ni indeks kerak emas; va klient
--    ODDIY yo'lda hozir aynan yalang'och tokenni yozadi
--    (`entryPayload.ext_ref = token`). Shunda klient bu RPC ga o'tganda
--    token semantikasi O'ZGARMAYDI. `xarajat_qayta_urinish` ikkala shaklni
--    ham topadi: `e.ext_ref = v_tok  or  e.ext_ref like '<tok>:%'`.
--
-- ⚠️ `exception` bloki plpgsql'da subtranzaksiya (savepoint) ochadi. Xato
--    BO'LMAGANDA hech narsa o'zgarmaydi; boshqa har qanday xato esa
--    o'zgartirilmasdan yuqoriga uzatiladi (`raise;`).
-- ⚠️ NEGA CONSTRAINT NOMI TEKSHIRILADI: bu funksiya `hodim_qarz_hisob()`
--    ni ham chaqiradi, u esa `accounts_hodim_kassa_id_uniq` ga tushishi
--    mumkin (ikki hodim bir vaqtda birinchi qarzini yozsa). O'sha xatoni
--    "allaqachon saqlangan" deb tarjima qilsak — pul YOZILMAGAN holda
--    klientga "saqlandi" deb ko'rsatilardi (jim yo'qotish, dublikatdan
--    yomonroq). Shuning uchun faqat `ext_ref` ga tegishli 23505 tarjima
--    qilinadi, qolgani AYNAN o'z holicha qaytadi.
-- ---------------------------------------------------------------------
create or replace function hodim_xarajat_yoz(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_kassa  uuid := coalesce(nullif(p_data->>'kassa_account','')::uuid,
                            nullif(p_data->>'kassa_id','')::uuid);
  v_modda  uuid := coalesce(nullif(p_data->>'dt_account','')::uuid,
                            nullif(p_data->>'modda_id','')::uuid);
  v_summa  numeric := nullif(p_data->>'summa','')::numeric;
  v_cur    text    := coalesce(nullif(p_data->>'kassa_currency',''), 'UZS');
  v_kurs   numeric := nullif(p_data->>'kassa_kurs','')::numeric;
  -- YANGI: takrorga qarshi token (ixtiyoriy). null -> eski xatti-harakat.
  v_ext    text    := nullif(trim(p_data->>'ext_ref'), '');
  v_root   uuid;
  v_qoldiq numeric;
  v_kqism  numeric;
  v_qqism  numeric;
  v_qarz   uuid;
  v_fc     numeric;
  v_entry  uuid;
  v_filial uuid[];
  v_yuk    int[];
  v_mtype  text;
  -- YANGI: 23505 ni ANIQ tasniflash uchun (yuqoridagi izoh)
  v_con    text;
  v_det    text;
begin
  -- 🔴 lock_timeout — xarajat_saqlash_taqsim dagi bilan BIR XIL (5s).
  --    `set local` semantikasi: funksiyada `set search_path` bandi borligi
  --    uchun PostgreSQL chiqishda GUC ni avtomat tiklaydi.
  --    `statement_timeout` ATAYLAB tegilmaydi (joriy so'rovga ta'sir qilmaydi).
  perform set_config('lock_timeout', '5s', true);

  if v_kassa is null or v_modda is null then
    raise exception 'Kassa yoki xarajat moddasi berilmadi' using errcode = '22000';
  end if;
  if v_summa is null or v_summa <= 0 then
    raise exception 'Summa musbat bolishi kerak' using errcode = '22000';
  end if;
  if v_kurs is not null and v_kurs <= 0 then
    raise exception 'Kurs musbat bolishi kerak' using errcode = '22000';
  end if;
  -- YANGI: token shakli (xarajat_saqlash_taqsim dagi AYNAN o'sha shart).
  -- Juda qisqa token prefiks qidiruvida begona yozuvlarni qamrab olardi.
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bo''lishi kerak' using errcode = '22000';
  end if;

  v_root := hodim_kassa_ildiz(v_kassa);
  if v_root is null then
    raise exception 'Bu hodim kassasi emas — hodim_xarajat_yoz faqat hodim kassalari uchun'
      using errcode = '22000';
  end if;

  select a.type into v_mtype from accounts a where a.id = v_modda;
  if v_mtype is distinct from 'xarajat' then
    raise exception 'Tanlangan hisob xarajat moddasi emas' using errcode = '22000';
  end if;

  -- filial_ids / yuk_ids — jsonb massivdan (massiv bo'lmasa bo'sh)
  select coalesce(array_agg(t.x::uuid), '{}'::uuid[]) into v_filial
    from jsonb_array_elements_text(
           case when jsonb_typeof(p_data->'filial_ids') = 'array'
                then p_data->'filial_ids' else '[]'::jsonb end) as t(x)
   where nullif(btrim(t.x), '') is not null;

  select coalesce(array_agg(t.x::int), '{}'::int[]) into v_yuk
    from jsonb_array_elements_text(
           case when jsonb_typeof(p_data->'yuk_ids') = 'array'
                then p_data->'yuk_ids' else '[]'::jsonb end) as t(x)
   where nullif(btrim(t.x), '') is not null;

  -- 🔴 QOLDIQ SERVERDA O'QILADI (v_hisob_bal bilan bir xil mantiq)
  select coalesce(sum(l.debit - l.credit), 0) into v_qoldiq
    from entry_line l
    join entry e on e.id = l.entry_id
   where l.account_id = v_kassa
     and e.status = 'posted' and e.is_deleted = false;

  v_qoldiq := greatest(coalesce(v_qoldiq, 0), 0);   -- manfiy qoldiqni 0 deb olamiz
  v_kqism  := least(v_summa, v_qoldiq);
  v_qqism  := v_summa - v_kqism;

  if v_qqism > 0 and v_cur <> 'UZS' then
    raise exception 'Valyuta kassasida qoldiqdan ortiq xarajat yozilmaydi (qoldiq: %)', v_qoldiq
      using errcode = '22000',
            hint = 'Avval so''mga konvert qiling yoki summani kamaytiring.';
  end if;

  if v_qqism > 0 then
    v_qarz := hodim_qarz_hisob(v_root);             -- idempotent lazy-create
  end if;

  -- fc FAQAT valyuta kassasi satriga (klient bilan bir xil mantiq)
  if v_cur <> 'UZS' then
    v_fc := case when v_kurs is not null then round(v_kqism / v_kurs, 2) else v_kqism end;
  end if;

  insert into entry (entry_date, description, source, status, filial_ids,
                     davr_start, davr_end, kommunal_turi, fc_rate, yuk_ids,
                     ext_ref)
  values (coalesce(nullif(p_data->>'entry_date','')::date,
                   nullif(p_data->>'sana','')::date,
                   (now() at time zone 'Asia/Tashkent')::date),
          coalesce(nullif(p_data->>'description',''), nullif(p_data->>'izoh','')),
          coalesce(nullif(p_data->>'source',''), 'manual'),
          coalesce(nullif(p_data->>'status',''), 'posted'),
          v_filial,
          nullif(p_data->>'davr_start','')::date,
          nullif(p_data->>'davr_end','')::date,
          nullif(p_data->>'kommunal_turi',''),
          case when v_cur <> 'UZS' then v_kurs end,
          v_yuk,
          -- YANGI: token berilmasa null (eski xatti-harakat AYNAN saqlanadi)
          v_ext)
  returning id into v_entry;

  -- Uchala satr BITTA insert bilan (xarajat_saqlash_taqsim naqshi).
  -- Nol satrlar `where` bilan tushib qoladi — entry_line cheklovi bir satrda
  -- faqat bittasi > 0 bo'lishini talab qiladi.
  insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
  select v_entry, x.acc, x.dt, x.kt, x.fc
    from (values (v_modda, v_summa,    0::numeric, null::numeric),
                 (v_kassa, 0::numeric, v_kqism,    v_fc),
                 (v_qarz,  0::numeric, v_qqism,    null::numeric)
         ) as x(acc, dt, kt, fc)
   where x.acc is not null and (x.dt > 0 or x.kt > 0);

  return jsonb_build_object(
    'ok',               true,
    'entry_id',         v_entry,
    'kassa_summa',      v_kqism,
    'tolanmagan_summa', v_qqism,
    'qarz_hisob_id',    v_qarz);

exception
  -- 🔴 Takror. Kod 23505 — klient aynan shu kod bo'yicha qaror qiladi
  --    (`isDup(e)`), matn esa xarajat_saqlash_taqsim dagi bilan BIR XIL.
  --    Funksiya tranzaksiya bo'lgani uchun bu yerga yetganda BU URINISHDAN
  --    hech narsa yozilmagan — yarim holat YO'Q.
  when unique_violation then
    if v_ext is null then
      raise;                                   -- bizning to'siq emas
    end if;
    get stacked diagnostics v_con = constraint_name,
                            v_det = pg_exception_detail;
    -- Faqat `entry.ext_ref` unique'i tarjima qilinadi. Boshqa 23505
    -- (masalan accounts_hodim_kassa_id_uniq poygasi) AYNAN o'z holicha
    -- ketadi — aks holda pul yozilmagan holda "saqlandi" deyilardi.
    if coalesce(v_con, '') not ilike '%ext_ref%'
       and coalesce(v_det, '') not ilike '%ext_ref%' then
      raise;
    end if;
    raise exception 'Bu xarajat allaqachon saqlangan (takroriy yuborish tosildi)'
      using errcode = '23505';
end $$;

-- Grantlar AYNAN PROVODKA_XARAJAT_TOSIQ.sql dagidek qayta beriladi
-- (`create or replace` egalik/ruxsatni saqlaydi, lekin biz aniq yozamiz).
revoke all on function hodim_xarajat_yoz(jsonb) from public, anon;
grant execute on function hodim_xarajat_yoz(jsonb) to authenticated;

comment on function hodim_xarajat_yoz(jsonb) is
  'Hodim xarajati (atomik). Qoldiq yetmasa kassa MANFIYGA TUSHMAYDI — yetmagan qism qarz hisobiga '
  '(6721+) yoziladi. Qoldiqni server o''zi o''qiydi (poyga bo''lmasin). '
  'ext_ref berilsa entry.ext_ref ga YALANG''OCH token yoziladi — takror yuborish 23505 bilan tosiladi. '
  'lock_timeout = 5s. Qaytishi: {entry_id, kassa_summa, tolanmagan_summa, qarz_hisob_id}.';


-- #####################################################################
-- ##  2-BO'LIM — ISH 2: xarajat_saqlash_taqsim(jsonb) + QARZ mantiqi ##
-- #####################################################################
-- 🔴 IMZO O'ZGARMAYDI: xarajat_saqlash_taqsim(jsonb).
--    PROD `hodim.html` ham, `hodim-dev.html` ham AYNI chaqiruvni qiladi:
--      sb.rpc('xarajat_saqlash_taqsim', { p_data })
--    `ext_ref` mantiqi PROVODKA_EXT_REF.sql dan AYNAN ko'chirilgan.
--
-- YANGI: hodim kassasidan chiqadigan xarajatda qo'ldagi puldan ORTIG'I
--        qarz hisobiga (6721+) tushadi — `hodim_xarajat_yoz` bilan BIR XIL
--        qoida. Har yozuv:
--            Dt modda   summa
--            Kt kassa   kqism      (qo'ldagi puldan)
--            Kt 6721    qqism      (to'lanmagan)   <- faqat qqism > 0 bo'lsa
--        Dt = Kt har doim (summa = kqism + qqism) — `check_entry_balanced`
--        DEFERRED trigger COMMIT paytida baribir tekshiradi.
--
-- ── QACHON QARZ MANTIQI ISHLAYDI (uch shart ham bajarilsa) ───────────
--   (1) `hodim_kassa_ildiz(kt_account)` NOT NULL — ya'ni pul CHIQADIGAN
--       hisob hodim kassasi (yoki uning naqd/click/payme/USD bolasi).
--       🔴 Filial va markaziy kassa yozuvlari BU YERGA UMUMAN TUSHMAYDI —
--          ular uchun hech narsa o'zgarmaydi.
--   (2) `dt_account` turi = 'xarajat'. Aks holda (transfer, tovar, kapital…)
--       "qarz" tushunchasi ma'nosiz — eski xatti-harakat qoladi.
--   (3) `hodim_kassa_ildiz` VA `hodim_qarz_hisob` bazada MAVJUD
--       (PROVODKA_XARAJAT_TOSIQ.sql RUN qilingan). Yo'q bo'lsa shox
--       umuman ishga tushmaydi — plpgsql `if` ichidagi chaqiruvni faqat
--       bajarilganda kompilyatsiya qiladi, ya'ni "function does not exist"
--       xatosi CHIQMAYDI. Bu `convert_start_v2` dagi qorovul naqshi.
--
-- ── QOLDIQ NEGA `kt_account` DAN O'QILADI ─────────────────────────────
--   `hodim_xarajat_yoz` qoldiqni `kassa_account` dan o'qiydi. Taqsimotda
--   pul CHIQADIGAN tomon — Kt. Klient ikkalasini ham AYNI hisob qilib
--   yuboradi (`openTaqsim(amt, modda.id, kassa.id, …)` -> dt=modda,
--   kt=kassa=kassa_account), shuning uchun natija bir xil; lekin manba
--   sifatida Kt olinadi — pul qayerdan chiqsa, qoldiq o'sha yerdan.
--   Qoldiq `v_hisob_bal` bilan bir xil: posted + o'chirilmagan, manfiy
--   bo'lsa 0 deb olinadi.
--
-- ── KETMA-KET KAMAYISH (bir necha filial = bir necha yozuv) ───────────
--   Qoldiq BIR MARTA o'qiladi va yozuvlar bo'ylab IZCHIL kamayadi:
--   birinchi yozuv(lar) qo'ldagi pulni yeydi, qolganlari qarzga tushadi.
--   Misol: qo'lda 300 000, taqsimot 200 000 + 200 000 + 100 000 ->
--     1-yozuv: Kt kassa 200 000
--     2-yozuv: Kt kassa 100 000 · Kt 6721 100 000
--     3-yozuv: Kt 6721 100 000   (kassa satri UMUMAN yozilmaydi — `where`
--                                 filtri nol satrni tashlaydi)
--   Jami qarz = 200 000, kassa qoldig'i 0 (manfiy emas).
--
-- ── VALYUTA ──────────────────────────────────────────────────────────
--   `hodim_xarajat_yoz` bilan bir xil: valyuta kassasida (USD/CNY)
--   qoldiqdan ORTIQ xarajat YOZILMAYDI (fc_amount ni ikki satrga bo'lish
--   tarixiy kurs bilan chalkashlik tug'diradi). Tekshiruv sikldan OLDIN —
--   ya'ni birorta yozuv yozilmasdan aniq xato qaytadi.
--   Shu sabab: valyuta kassasida `v_qqism` HAR DOIM 0, ya'ni mavjud
--   fc/`kassa_kurs` taqsimot mantiqiga UMUMAN tegilmagan.
--
-- ── TO'SIQ TRIGGERI BILAN URISHMASLIK ────────────────────────────────
--   Batafsil tahlil 5-BO'LIMda. Qisqasi: Kt 6721 satri hodim kassa
--   oilasiga KIRMAYDI (`hodim_kassa_ildiz(6721)` = NULL) va `section`
--   'pul' emas -> `hodim_tosiq_guard` uni BIRINCHI `return new` da
--   chiqarib yuboradi; qolgan ikki satr esa avvalgidek.
-- ---------------------------------------------------------------------
create or replace function xarajat_saqlash_taqsim(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  it       jsonb;
  v_entry  uuid;
  v_ids    uuid[] := '{}';
  v_dt     uuid := nullif(p_data->>'dt_account','')::uuid;
  v_kt     uuid := nullif(p_data->>'kt_account','')::uuid;
  v_kassa  uuid := nullif(p_data->>'kassa_account','')::uuid;
  v_cur    text := nullif(p_data->>'kassa_currency','');
  -- 1 birlik valyuta necha so'm. null → eski xatti-harakat (fc = summa).
  v_kurs   numeric := nullif(p_data->>'kassa_kurs','')::numeric;
  -- Takrorga qarshi token (ixtiyoriy). null → eski xatti-harakat.
  v_ext    text := nullif(trim(p_data->>'ext_ref'), '');
  v_summa  numeric;
  v_filial uuid;
  v_fc     numeric;
  v_fc_dt  numeric;
  v_fc_kt  numeric;
  -- fc yaxlitlash siljishini yo'qotish uchun: jami valyuta miqdori va sarflangani.
  v_jami   numeric := 0;
  v_fc_bar numeric;
  v_fc_qol numeric;
  v_n      int;
  v_i      int := 0;
  -- ── YANGI (qarz mantiqi) ────────────────────────────────────────────
  v_root   uuid;            -- Kt hodim kassasining ildizi (null = qarz mantiqi O'CHIQ)
  v_mtype  text;            -- Dt hisob turi ('xarajat' bo'lishi shart)
  v_qol    numeric;         -- qo'ldagi pul QOLDIG'I (yozuvlar bo'ylab kamayadi)
  v_qol0   numeric;         -- boshlang'ich qoldiq (faqat xato matni uchun)
  v_kqism  numeric;         -- shu yozuvda kassadan chiqadigan qism
  v_qqism  numeric;         -- shu yozuvda qarzga tushadigan qism
  v_qarz   uuid;            -- 6721+ qarz hisobi (kerak bo'lganda lazy-create)
  v_jtot   numeric;         -- taqsimot jami (valyuta tekshiruvi uchun)
  v_fcqol  numeric;         -- Kt hisobning O'Z valyutasidagi qoldig'i (🟡-A)
  v_ksum   numeric := 0;    -- JAMI: kassadan chiqqan qism (klient optimistik qoldig'i uchun)
  v_qsum   numeric := 0;    -- JAMI: qarzga (6721+) yozilgan qism
  v_con    text;
  v_det    text;
begin
  -- 🔴 lock_timeout — "Saqlanmoqda…" abadiy aylanmasin (5s, 55P03).
  --    `statement_timeout` ATAYLAB o'zgartirilmaydi (joriy so'rovga ta'sir
  --    qilmaydi). Batafsil izoh: PROVODKA_EXT_REF.sql 2-BO'LIM.
  perform set_config('lock_timeout', '5s', true);

  if v_dt is null or v_kt is null then
    raise exception 'dt/kt hisob berilmadi' using errcode = '22000';
  end if;
  if p_data->'taqsim' is null or jsonb_typeof(p_data->'taqsim') <> 'array'
     or jsonb_array_length(p_data->'taqsim') = 0 then
    raise exception 'Taqsimot bo''sh' using errcode = '22000';
  end if;
  if v_kurs is not null and v_kurs <= 0 then
    raise exception 'Kurs musbat bo''lishi kerak' using errcode = '22000';
  end if;
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bo''lishi kerak' using errcode = '22000';
  end if;

  -- ── YANGI: qarz mantiqi yoqiladimi? ─────────────────────────────────
  -- 🔴 Qorovul: funksiyalar bazada bo'lmasa (PROVODKA_XARAJAT_TOSIQ.sql
  --    RUN qilinmagan) shox umuman ishga tushmaydi va RPC avvalgidek
  --    ishlaydi. `if` ichidagi chaqiruvlar faqat shu yerga kirilganda
  --    kompilyatsiya qilinadi.
  if to_regprocedure('public.hodim_kassa_ildiz(uuid)') is not null
     and to_regprocedure('public.hodim_qarz_hisob(uuid)') is not null then
    -- `execute` — PROVODKA_VALYUTA.sql (convert_start_v2 / perm_can_convert)
    -- dagi AYNAN o'sha naqsh: funksiya nomi ishga tushish paytida ham
    -- bog'lanmaydi, ya'ni yo'q funksiya hech qanday holatda xato bermaydi.
    execute 'select hodim_kassa_ildiz($1)' into v_root using v_kt;   -- null = hodim kassasi emas
    if v_root is not null then
      select a.type into v_mtype from accounts a where a.id = v_dt;
      if v_mtype is distinct from 'xarajat' then
        v_root := null;                          -- xarajat emas -> eski yo'l
      end if;
    end if;
    if v_root is not null then
      -- Qoldiq: v_hisob_bal bilan bir xil (posted + o'chirilmagan).
      select coalesce(sum(l.debit - l.credit), 0) into v_qol
        from entry_line l
        join entry e on e.id = l.entry_id
       where l.account_id = v_kt
         and e.status = 'posted' and e.is_deleted = false;
      v_qol  := greatest(coalesce(v_qol, 0), 0);  -- manfiy qoldiqni 0 deb olamiz
      v_qol0 := v_qol;

      -- Valyuta kassasi: qoldiqdan ortiq xarajat UMUMAN yozilmaydi
      -- (hodim_xarajat_yoz bilan bir xil qoida). Sikldan OLDIN tekshiramiz,
      -- ya'ni birorta yozuv yozilmasdan aniq xato qaytadi.
      --
      -- 🔴 TAQQOSLASH HISOBNING O'Z VALYUTASIDA — klient bilan AYNI ASOS.
      --    So'm daftar qoldig'i (v_qol) TARIXIY kursda saqlanadi (v_kassa_toliq izohi:
      --    "joriy kursga qayta ko'paytirma"). Joriy kurs tarixiydan yuqori bo'lsa
      --    ulushlarning SO'M jamisi qoldiqdan oshib ketardi va xarajat RAD ETILARDI —
      --    hodim qo'lida valyuta YETARLI bo'lsa ham. Klient esa `c.fc > curBal`
      --    (valyuta MIQDORI) bilan o'lchaydi va "oshmadi" deydi: ikkisi ajralib,
      --    foydalanuvchi saqlab, server rad etardi (yomon UX, yolg'on tugma).
      --    Endi ikkalasi ham valyuta miqdorini solishtiradi.
      -- ⚠️ Kurs berilmasa (kassa_kurs yo'q) fc = summa — eski xatti-harakat, tekshiruv YO'Q.
      if coalesce(v_cur, 'UZS') <> 'UZS' and v_kurs is not null then
        -- v_hisob_bal.fc bilan bir xil: debit > 0 ? +fc : -fc
        select coalesce(sum(case when l.debit > 0 then l.fc_amount else -l.fc_amount end), 0)
          into v_fcqol
          from entry_line l
          join entry e on e.id = l.entry_id
         where l.account_id = v_kt
           and e.status = 'posted' and e.is_deleted = false;
        v_fcqol := greatest(coalesce(v_fcqol, 0), 0);   -- manfiy qoldiqni 0 deb olamiz
        select coalesce(sum((x->>'summa')::numeric), 0) into v_jtot
          from jsonb_array_elements(p_data->'taqsim') as x;
        if round(v_jtot / v_kurs, 2) > v_fcqol then
          raise exception 'Valyuta kassasida qoldiqdan ortiq xarajat yozilmaydi (qoldiq: % %)',
                          v_fcqol, v_cur
            using errcode = '22000',
                  hint = 'Avval so''mga konvert qiling yoki summani kamaytiring.';
        end if;
      end if;
    end if;
  end if;

  -- Valyuta jamisi BIR MARTA hisoblanadi (ulushlar yig'indisidan), keyin ulushlarga
  -- taqsimlanadi — shunda sum(fc) = round(jami/kurs, 2) aniq mos keladi.
  v_n := jsonb_array_length(p_data->'taqsim');
  if v_kurs is not null then
    select coalesce(sum((x->>'summa')::numeric), 0) into v_jami
      from jsonb_array_elements(p_data->'taqsim') as x;
    v_fc_bar := round(v_jami / v_kurs, 2);
    v_fc_qol := v_fc_bar;
  end if;

  for it in select * from jsonb_array_elements(p_data->'taqsim') loop
    v_i := v_i + 1;
    v_summa  := (it->>'summa')::numeric;
    v_filial := nullif(it->>'filial_id','')::uuid;
    if v_summa is null or v_summa <= 0 then
      raise exception 'Har filial summasi musbat bo''lishi kerak' using errcode = '22000';
    end if;

    -- ── YANGI: bo'linish (qo'ldagi pul -> kassa, ortig'i -> qarz) ──────
    -- Qarz mantiqi o'chiq bo'lsa v_kqism = v_summa, v_qqism = 0, ya'ni
    -- satrlar AYNAN eskisidek (Dt modda / Kt kassa).
    if v_root is null then
      v_kqism := v_summa;
      v_qqism := 0;
    else
      v_kqism := least(v_summa, v_qol);
      v_qqism := v_summa - v_kqism;
      v_qol   := v_qol - v_kqism;               -- keyingi yozuvga qoldiq
      if v_qqism > 0 and v_qarz is null then
        -- idempotent lazy-create (`execute` — yuqoridagi qorovul izohi)
        execute 'select hodim_qarz_hisob($1)' into v_qarz using v_root;
      end if;
    end if;
    -- Javobda qaytadi: klient optimistik qoldiqni FAQAT kassadan chiqqan qism bo'yicha
    -- kamaytirsin va qarz tug'ilgan bo'lsa foydalanuvchiga ANIQ aytsin.
    v_ksum := v_ksum + v_kqism;
    v_qsum := v_qsum + v_qqism;

    insert into entry (entry_date, description, source, status, filial_ids,
                       davr_start, davr_end, kommunal_turi, fc_rate, ext_ref)
    values (
      nullif(p_data->>'entry_date','')::date,
      nullif(p_data->>'description',''),
      coalesce(nullif(p_data->>'source',''), 'manual'),
      coalesce(nullif(p_data->>'status',''), 'posted'),
      case when v_filial is null then '{}'::uuid[] else array[v_filial] end,
      nullif(p_data->>'davr_start','')::date,
      nullif(p_data->>'davr_end','')::date,
      nullif(p_data->>'kommunal_turi',''),
      case when v_cur is not null and v_cur <> 'UZS' then v_kurs end,
      -- Token berilmasa null (eski xatti-harakat AYNAN saqlanadi).
      -- 🔴 Shakl `<token>:<i>` — MAVJUD kontrakt, o'zgarmaydi.
      case when v_ext is null then null else v_ext || ':' || v_i::text end
    )
    returning id into v_entry;

    -- fc_amount faqat valyuta kassasi satriga (client bilan bir xil mantiq).
    -- Kurs berilgan bo'lsa so'm ulushi valyutaga aylantiriladi; OXIRGI ulushga
    -- taqsimlanmay qolgan qoldiq beriladi — sum(fc) = round(jami/kurs, 2).
    -- ⚠️ TEGILMAGAN: valyuta kassasida v_qqism har doim 0 (yuqorida
    --    tekshirilgan), ya'ni fc butun ulushga to'g'ri keladi.
    if v_kurs is null then
      v_fc := v_summa;                                   -- eski xatti-harakat
    elsif v_i = v_n then
      v_fc := v_fc_qol;
    else
      v_fc := round(v_fc_bar * v_summa / nullif(v_jami, 0), 2);
      v_fc_qol := v_fc_qol - v_fc;
    end if;
    v_fc_dt := case when v_cur is not null and v_cur <> 'UZS' and v_kassa = v_dt then v_fc else null end;
    v_fc_kt := case when v_cur is not null and v_cur <> 'UZS' and v_kassa = v_kt then v_fc else null end;

    -- Satrlar BITTA insert bilan. Nol satrlar `where` bilan tushib qoladi —
    -- entry_line cheklovi bir satrda faqat bittasi > 0 bo'lishini talab qiladi.
    -- Tartib eskisidek: Dt birinchi, keyin Kt kassa, oxirida Kt qarz.
    insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
    select v_entry, x.acc, x.dt, x.kt, x.fc
      from (values (v_dt,   v_summa,    0::numeric, v_fc_dt),
                   (v_kt,   0::numeric, v_kqism,    v_fc_kt),
                   (v_qarz, 0::numeric, v_qqism,    null::numeric)
           ) as x(acc, dt, kt, fc)
     where x.acc is not null and (x.dt > 0 or x.kt > 0);

    v_ids := v_ids || v_entry;
  end loop;

  -- 🔴 ADDITIVE: `ok` / `count` / `entry_ids` AYNAN o'z joyida — eski klient (PROD
  --    hodim.html) javobning qolgan kalitlarini e'tiborsiz qoldiradi. Yangi kalitlar
  --    hodim_xarajat_yoz javobi bilan BIR XIL nomlanadi (klientda bitta naqsh).
  return jsonb_build_object('ok', true,
                            'count', coalesce(array_length(v_ids, 1), 0),
                            'entry_ids', to_jsonb(v_ids),
                            'kassa_summa', v_ksum,
                            'tolanmagan_summa', v_qsum,
                            'qarz_hisob_id', v_qarz);

exception
  -- 🔴 Takror. Xato KODI o'zgarmaydi (23505) — klient aynan shu kod bo'yicha
  --    "allaqachon saqlangan" deb qaror qiladi. Funksiya tranzaksiya bo'lgani
  --    uchun bu yerga yetganda BU URINISHDAN hech narsa yozilmagan.
  when unique_violation then
    if v_ext is null then
      raise;                                   -- bizning to'siq EMAS
    end if;
    get stacked diagnostics v_con = constraint_name,
                            v_det = pg_exception_detail;
    -- ⚠️ YANGI ehtiyot: endi bu funksiya `hodim_qarz_hisob()` ni ham
    --    chaqiradi (u `accounts_hodim_kassa_id_uniq` ga tushishi mumkin —
    --    ikki xarajat bir vaqtda birinchi qarzni ochsa). O'sha xatoni
    --    "allaqachon saqlangan" deb tarjima qilsak, pul YOZILMAGAN holda
    --    klient "saqlandi" deb ko'rsatardi. Shuning uchun faqat
    --    `entry.ext_ref` unique'i tarjima qilinadi.
    if coalesce(v_con, '') not ilike '%ext_ref%'
       and coalesce(v_det, '') not ilike '%ext_ref%' then
      raise;
    end if;
    raise exception 'Bu xarajat allaqachon saqlangan (takroriy yuborish tosildi)'
      using errcode = '23505';
end $$;

-- Grantlar AYNAN PROVODKA_EXT_REF.sql dagidek qayta beriladi.
revoke all on function xarajat_saqlash_taqsim(jsonb) from public, anon;
grant execute on function xarajat_saqlash_taqsim(jsonb) to authenticated;

comment on function xarajat_saqlash_taqsim(jsonb) is
  'Filial bo''yicha alohida provodka: har filialga bitta entry (atomik). perm guard har satrga ishlaydi. '
  'kassa_kurs berilsa valyuta kassasida fc = summa/kurs (aks holda fc = summa — eski xatti-harakat). '
  'ext_ref berilsa har entry ga <token>:<indeks> yoziladi — takror yuborish 23505 bilan tosiladi. '
  'YANGI: kt_account HODIM kassasi va dt_account xarajat moddasi bo''lsa, qo''ldagi puldan ortig''i '
  'qarz hisobiga (6721+) yoziladi — kassa manfiyga tushmaydi. Qoldiq yozuvlar bo''ylab ketma-ket kamayadi. '
  'Javobga kassa_summa / tolanmagan_summa / qarz_hisob_id qo''shildi (additive). '
  'lock_timeout = 5s.';


-- #####################################################################
-- ##  2B-BO'LIM — IMKONIYAT BELGISI (klient uchun)  🔴 MUHIM         ##
-- #####################################################################
-- MUAMMO: `PROVODKA_XARAJAT_TOSIQ.sql` RUN qilingan, lekin BU FAYL hali
-- RUN qilinmagan bo'lsa — `hodim_xarajat_yoz()` MAVJUD, ya'ni klient uni
-- ishlatishi mumkin deb o'ylaydi. Lekin ESKI versiya `p_data.ext_ref` ni
-- JIMGINA e'tiborsiz qoldiradi (noma'lum kalit) → `entry.ext_ref` null
-- bo'lib yoziladi → TAKROR HIMOYASI YO'QOLADI va 2026-08-24 dagi
-- insident (bir xil xarajat ikki marta) qaytadi.
--
-- Klient buni funksiya BORLIGIDAN farqlay olmaydi. Shuning uchun bu fayl
-- ALOHIDA belgi qo'yadi: klient shu belgini ko'rmaguncha `hodim_xarajat_yoz`
-- ga O'TMAYDI va eski (ext_ref ishlaydigan) to'g'ridan-insert yo'lida qoladi.
--
-- ⚠️ Versiya raqami: kelajakda xarajat yozish kontrakti o'zgarsa OSHIRILADI
--    va klient `>= 2` shartini mos yangilaydi. Kamaytirilmaydi.
-- ---------------------------------------------------------------------
create or replace function xarajat_qarz_versiya()
returns int
language sql
immutable
set search_path = public
as $$ select 2 $$;

revoke all on function xarajat_qarz_versiya() from public, anon;
grant execute on function xarajat_qarz_versiya() to authenticated, service_role;

comment on function xarajat_qarz_versiya() is
  'Klient uchun imkoniyat belgisi: 2 = hodim_xarajat_yoz() ext_ref ni qabul qiladi VA '
  'xarajat_saqlash_taqsim() qarz (6721) mantiqiga ega. Funksiya YOQ bolsa klient '
  'eski togridan-insert yoliga tushadi (takror himoyasi saqlanadi).';


-- #####################################################################
-- ##  3-BO'LIM — PostgREST sxema keshi                               ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  4-BO'LIM — MOS KELISH TEKSHIRUVI (faqat KATALOG so'rovlari)    ##
-- #####################################################################

-- 4.0 🔴 IMKONIYAT BELGISI o'rnidami (klient shunga qarab yo'l tanlaydi)
select to_regprocedure('public.xarajat_qarz_versiya()') is not null as belgi_bor,
       has_function_privilege('authenticated',
         'public.xarajat_qarz_versiya()', 'execute')            as belgi_ochiq;
-- 🔴 Bu bo'limda RPC ni JONLI chaqiradigan operator YO'Q — hammasi
--    `pg_proc` / `pg_class` / `accounts` so'rovlari. Sabab: Supabase SQL
--    editorida `auth.uid()` NULL bo'ladi va jonli chaqiruv yolg'on natija
--    (yoki xato) beradi — `PROVODKA_JURNAL_V2.sql` bugun aynan shundan
--    rollback bo'ldi.
-- Har `select` ni ALOHIDA belgilab RUN qiling.

-- ---------------------------------------------------------------------
-- 4.1  🔴 IMZO O'ZGARMADIMI? Har nomdan AYNAN 1 ta overload bo'lishi SHART
--      (aks holda PostgREST PGRST203 beradi va PROD `hodim.html` sinadi).
--      Kutilgan: 2 qator; `overload_soni = 1`; `imzolar = 'jsonb'`.
-- ---------------------------------------------------------------------
select p.proname,
       count(*)                                                    as overload_soni,
       string_agg(pg_get_function_identity_arguments(p.oid), ' | ') as imzolar,
       bool_and(p.prosecdef)                                        as security_definer,
       bool_and('search_path=public' = any(coalesce(p.proconfig, '{}'))) as search_path_ok
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('hodim_xarajat_yoz', 'xarajat_saqlash_taqsim')
 group by p.proname
 order by p.proname;


-- ---------------------------------------------------------------------
-- 4.2  `prosrc` bo'yicha: ikkalasida ham `ext_ref` VA qarz hisobiga
--      murojaat bormi? Beshala ustun ham `true` bo'lishi kerak.
--        ext_ref_bor   — token qabul qilinadi
--        entry_ext_ref — `entry` insertiga ext_ref yoziladi
--        qarz_hisob_bor— hodim_qarz_hisob() chaqiriladi (lazy-create)
--        ildiz_bor     — hodim_kassa_ildiz() bilan hodim kassasi aniqlanadi
--        dup_23505     — takror uchun 23505 tarjimasi bor
-- ---------------------------------------------------------------------
select p.proname,
       p.prosrc ilike '%ext_ref%'                      as ext_ref_bor,
       (p.prosrc ilike '%ext_ref)%' or p.prosrc ilike '%,%ext_ref%')
                                                       as entry_ext_ref,
       p.prosrc ilike '%hodim_qarz_hisob(%'            as qarz_hisob_bor,
       p.prosrc ilike '%hodim_kassa_ildiz(%'           as ildiz_bor,
       p.prosrc ilike '%23505%'                        as dup_23505
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('hodim_xarajat_yoz', 'xarajat_saqlash_taqsim')
 order by p.proname;


-- ---------------------------------------------------------------------
-- 4.3  Qarz zanjiri o'rnidami? (hammasi true bo'lsin)
--      `f_qarz_hisob` false bo'lsa — 2-BO'LIMdagi qorovul qarz mantiqini
--      JIMGINA o'chirib qo'yadi (prod sinmaydi, lekin "To'lanmagan"
--      ro'yxati bo'sh qolaveradi). U holda PROVODKA_XARAJAT_TOSIQ.sql.
-- ---------------------------------------------------------------------
select to_regprocedure('public.hodim_qarz_hisob(uuid)')        is not null as f_qarz_hisob,
       to_regprocedure('public.hodim_kassa_ildiz(uuid)')       is not null as f_ildiz,
       to_regprocedure('public.hodim_qarz_hisob_topish(uuid)') is not null as f_qarz_topish,
       to_regprocedure('public.hodim_tolanmagan_bir(uuid)')    is not null as f_tolanmagan_bir,
       to_regclass('public.v_hodim_tolanmagan')                is not null as v_tolanmagan,
       exists (select 1 from accounts where code = '6720')                 as a_6720_konteyner;


-- ---------------------------------------------------------------------
-- 4.4  Grantlar buzilmadimi?
--      Kutilgan: anon = false, authenticated = true.
--      (`hodim_xarajat_yoz` va `xarajat_saqlash_taqsim` service_role ga
--       ATAYLAB berilmagan — eski holat shunday edi, o'zgartirilmadi.)
-- ---------------------------------------------------------------------
select p.proname, r.rolname,
       has_function_privilege(r.rolname, p.oid, 'execute') as execute_bor
  from pg_proc p
  cross join (values ('anon'), ('authenticated'), ('service_role')) as r(rolname)
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('hodim_xarajat_yoz', 'xarajat_saqlash_taqsim')
 order by p.proname, r.rolname;


-- ---------------------------------------------------------------------
-- 4.5  Triggerlar joyidami? (bu fayl ularga TEGMAYDI — regressiya nazorati)
-- ---------------------------------------------------------------------
select t.tgname,
       t.tgenabled = 'O' as yoqilgan
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
 where c.relname = 'entry_line'
   and not t.tgisinternal
 order by t.tgname;


-- ---------------------------------------------------------------------
-- 4.6  Qarz hisoblari (6721+) ro'yxati — jadval so'rovi, RPC EMAS.
--      Birinchi RUN'da BO'SH chiqishi normal: qarz hisobi faqat birinchi
--      "qoldiqdan ortiq" xarajat yozilganda ochiladi (lazy-create).
-- ---------------------------------------------------------------------
select q.code, q.name, q.subtitle, q.type, q.is_active,
       k.code as hodim_kassa_kod, k.name as hodim_kassa_nom
  from accounts q
  left join accounts k on k.id = q.hodim_kassa_id
 where q.parent_id = (select id from accounts where code = '6720')
 order by q.code;


-- ---------------------------------------------------------------------
-- 4.7  🔴 TO'SIQ TRIGGERI BILAN URISHMASLIK SHARTI — ma'lumot tekshiruvi.
--      Qarz satri (Kt 6721) `hodim_tosiq_guard` uchun "kirim" bo'lib
--      ko'rinmasligi kerak. Tahlil 5-BO'LIMda; bu yerda uning IKKI
--      MA'LUMOT sharti tekshiriladi:
--        tosiq_xavfsiz = true  -> hammasi joyida.
--      (Jadval so'rovi, RPC chaqiruvi EMAS.)
-- ---------------------------------------------------------------------
select a.code, a.name, a.type, a.section, a.kassa_turi,
       coalesce(a.section, '') <> 'pul'    as section_pul_emas,
       a.kassa_turi is null                as kassa_turi_bosh,
       (coalesce(a.section, '') <> 'pul' and a.kassa_turi is null) as tosiq_xavfsiz
  from accounts a
 where a.code = '6720' or a.parent_id = (select id from accounts where code = '6720')
 order by a.code;


-- #####################################################################
-- ##  5-BO'LIM — 🔴 TO'SIQ TRIGGERI BILAN URISHUV TAHLILI (izoh)     ##
-- #####################################################################
-- Eng katta xavf: yangi Kt 6721 satri `hodim_tosiq_guard` triggeriga
-- "kirim" bo'lib ko'rinib qolishi. Tekshirildi — ko'rinmaydi.
--
-- `hodim_tosiq_guard()` (PROVODKA_XARAJAT_TOSIQ.sql 5-BO'LIM) tartibi:
--
--   0) auth.uid() null            -> return new
--   1) tosiq_foiz <= 0            -> return new
--   2) v_sec  := accounts.section (new.account_id)
--      v_root := hodim_kassa_ildiz(new.account_id)
--   3) 🔴 TEZ CHIQISH:
--        if v_root is null and v_sec is distinct from 'pul' -> return new
--   4) (a) KIRIM:      v_root is not null AND new.debit  > 0
--      (b1) KREDIT:    v_root is not null AND new.credit > 0
--      (b2) PUL DEBET: v_sec = 'pul'      AND new.debit  > 0
--
-- YANGI SATR: account = 6721, credit = qqism > 0, debit = 0.
--   * `hodim_kassa_ildiz(6721)` = NULL. Funksiya `kassa_turi='xarajat'`
--     VA otasi `kassa_turi='xarajat_guruh'` bo'lishini talab qiladi;
--     6721 ning otasi 6720, uning `kassa_turi` esa ATAYLAB NULL
--     (PROVODKA_XARAJAT_TOSIQ.sql 1.3 izohi) -> v_root NULL.
--   * 6720/6721 `section` — 6010 (yetkazib beruvchilar) dan nusxa, ya'ni
--     'pul' EMAS -> v_sec <> 'pul'.
--   => 3-qadamda `return new`. (a)/(b1)/(b2) shoxlariga UMUMAN yetmaydi.
--
--   ⚠️ Ehtiyot uchun ikkinchi qatlam: agar kimdir 6720 ga `section='pul'`
--      yozib qo'ysa ham satr o'tadi — (a) va (b1) `v_root is not null`
--      talab qiladi (NULL), (b2) esa `new.debit > 0` talab qiladi
--      (bizniki KREDIT). Ya'ni bitta noto'g'ri ma'lumot ham to'siqni
--      yolg'on ishlatib yubormaydi.
--
-- QOLGAN IKKI SATR:
--   * Dt modda (type='xarajat', section<>'pul', v_root NULL) -> 3-qadamda chiqadi.
--   * Kt hodim kassa (v_root NOT NULL, credit>0) -> (b1) ishlaydi: "yozuvda
--     TASHQI pul Dt bormi?". Yozuvdagi yagona Dt — xarajat moddasi
--     (`section <> 'pul'`), qarz satri esa KREDIT. Demak shart bajarilmaydi,
--     blok YO'Q. Ya'ni XARAJAT YOZISH avvalgidek HECH QACHON to'silmaydi
--     (bu to'siqning asosiy invarianti: aks holda hodim 70% ga chiqolmay
--     abadiy qulflanardi).
--
-- BOSHQA UCH TRIGGER (`entry_line`):
--   * `trg_perm_guard_entry_line` -> `perm_check_accounts()` faqat
--     `type='aktiv' AND code like '5%'` hisoblarni to'sadi. 6721 passiv,
--     kodi 6xxx -> ta'sir YO'Q (cheklangan user ham qarz satrini yoza oladi,
--     bu to'g'ri: pul harakati hamon hodim kassasi satrida to'silgan).
--   * `trg_limit_guard_entry_line` -> birinchi qatori `if new.debit <= 0
--     then return new`. Qarz satri KREDIT -> ta'sir YO'Q. Dt modda satri
--     esa o'zgarmagan (debit = to'liq summa), ya'ni oylik limit hisobi
--     AYNAN eskisidek ishlaydi.
--   * `trg_hodim_notify_entry_line` -> `hodim_kassa_root(6721)` NULL ->
--     `return null`, xabar yuborilmaydi.
--     ⚠️ TAN OLINGAN NUANS: telegram xabarida faqat KASSADAN chiqqan qism
--     (kqism) ko'rinadi, qarz qismi ko'rinmaydi. Bu `hodim_xarajat_yoz`
--     ning MAVJUD xatti-harakati bilan bir xil — o'zgartirilmadi (xabar
--     matnini o'zgartirish alohida ish).
--
-- `check_entry_balanced` — DEFERRED constraint trigger, COMMIT paytida
-- ishlaydi. Dt = summa, Kt = kqism + qqism = summa -> teng. Bir statementda
-- 3 satr insert qilish unga xalaqit bermaydi (bugungi 2 satrli insert ham
-- shunday ishlab turibdi).
--
-- ⚠️ JURNAL TAHRIRI: 3 satrli yozuvni `jurnal.html` TAHRIRLAY OLMAYDI
--    (qalam tugmasi `entry_line.length === 2` bo'lgandagina chiqadi) —
--    faqat 🗑 o'chirish. Bu `hodim_xarajat_yoz` uchun ALLAQACHON shunday
--    edi, endi taqsimot yo'liga ham tegishli. Ataylab: qarzli yozuvni
--    2 satrli shaklga "tuzatish" qarz qoldig'ini buzardi.
--
-- ⚠️ `xarajat_qayta_urinish` BUZILMAYDI: u "to'liq" ni
--    `satr >= 2 AND sum(debit) = sum(credit) AND sum(debit) > 0` bilan
--    aniqlaydi. 3 satrli qarzli yozuv ham, 2 satrli (kqism = 0) yozuv ham
--    shu shartga to'g'ri keladi.


-- #####################################################################
-- ##  6-BO'LIM — NIMA O'ZGARMADI (regressiya ro'yxati)               ##
-- #####################################################################
--  * IMZOLAR: `hodim_xarajat_yoz(jsonb)`, `xarajat_saqlash_taqsim(jsonb)`
--    — o'sha-o'sha. Argument QO'SHILMADI, overload YARATILMADI.
--  * `ext_ref` BERILMASA: `entry.ext_ref = null` — PROD `hodim.html` ning
--    bugungi xatti-harakati bayt-ma-bayt o'sha.
--  * KASSA HODIM KASSASI BO'LMASA (filial / markaziy / ombor…):
--    `v_root = null` -> `v_kqism = v_summa`, `v_qqism = 0` -> `values`
--    ro'yxatining 3-qatori `where` bilan tushib qoladi -> AYNAN eski ikki
--    satr (Dt v_dt / Kt v_kt), o'sha tartibda, o'sha fc qiymatlari bilan.
--  * `dt_account` xarajat moddasi BO'LMASA — qarz mantiqi o'chadi
--    (transfer/ombor yozuvlari tegilmaydi).
--  * `kassa_kurs` / fc taqsimoti mantiqi — SATRMA-SATR nusxa, tegilmagan.
--    Valyuta kassasida `v_qqism` har doim 0, ya'ni fc butun ulushga
--    to'g'ri keladi (eskisidek).
--  * `filial_ids`, `davr_*`, `kommunal_turi`, `fc_rate`, `yuk_ids` —
--    tegilmagan.
--  * Qaytish shakllari tegilmagan:
--      taqsim -> {ok, count, entry_ids} + ADDITIVE {kassa_summa, tolanmagan_summa,
--                qarz_hisob_id} (mavjud uch kalit o'z joyida — eski klient sinmaydi)
--      xarajat_yoz -> {ok, entry_id, kassa_summa, tolanmagan_summa, qarz_hisob_id}
--  * Hech qanday jadval/ustun/trigger/view O'CHIRILMADI, qayta
--    nomlanmadi yoki UPDATE qilinmadi. Bu fayl mavjud `entry`/`entry_line`
--    ma'lumotiga UMUMAN tegmaydi.
--  * `hodim_tosiq_guard`, `perm_guard_entry_line`, `limit_guard_entry_line`,
--    `hodim_notify_line_fn` — bittasiga ham tegilmadi.
--
--  ── XATTI-HARAKAT ATAYLAB O'ZGARGAN YAGONA JOY ──────────────────────
--  Hodim kassasidan 2+ filialga taqsimlangan XARAJAT endi kassani
--  MANFIYGA tushirmaydi: qo'ldagi puldan ortig'i 6721 ga yoziladi va
--  `v_hodim_tolanmagan` da "To'lanmagan" bo'lib ko'rinadi.
--  Bu — shu faylning MAQSADI.


-- #####################################################################
-- ##  7-BO'LIM — ROLLBACK                                            ##
-- #####################################################################
--  🔴 `drop` QILMANG — ikkala funksiyani ham PROD chaqiradi. Orqaga
--     qaytarish = ESKI versiyani qayta RUN qilish (ikkalasi ham
--     `create or replace`, imzo bir xil):
--
--   (A) FAQAT qarz mantiqini olib tashlash (ext_ref saqlanadi):
--         PROVODKA_EXT_REF.sql -> 2-BO'LIM (xarajat_saqlash_taqsim)
--       Natija: taqsimot avvalgidek yozadi, kassa yana manfiyga tushadi,
--       "To'lanmagan" ro'yxati yana bo'sh bo'ladi. `hodim_xarajat_yoz`
--       shu faylning versiyasida qolaveradi (zararsiz).
--
--   (B) FAQAT `hodim_xarajat_yoz` ni orqaga qaytarish:
--         PROVODKA_XARAJAT_TOSIQ.sql -> 6-BO'LIM
--       ⚠️ Shundan keyin u `ext_ref` ni JIMGINA e'tiborsiz qoldiradi —
--       agar klient allaqachon shu RPC ga o'tgan bo'lsa, TAKROR-HIMOYA
--       yo'qoladi. Avval klientni qaytaring.
--
--   (C) IKKALASINI ham: (A) + (B).
--
--  Har rollbackdan keyin:  notify pgrst, 'reload schema';
--  Yozilib bo'lgan qarz satrlari (Kt 6721) rollbackda YO'QOLMAYDI va
--  yo'qotilmasligi ham kerak — ular haqiqiy majburiyat. Ularni
--  `hodim_kirim_yop()` (bugalter pul berganda) yopadi.


-- #####################################################################
-- ##  8-BO'LIM — KLIENT UCHUN (keyingi bosqich, bu faylda SQL yo'q)  ##
-- #####################################################################
--  Bu fayldan keyin klient TEGMASDAN ham ishlaydi:
--    * TAQSIMOT yo'li (2+ filial) — qarz mantiqi DARROV ishlaydi,
--      `hodim-dev.html` da hech narsa o'zgartirilmaydi.
--    * ODDIY yo'l (1 filial) — hamon to'g'ridan insert qiladi, ya'ni
--      qarz YOZILMAYDI. Uni yopish uchun klient `sb.rpc('hodim_xarajat_yoz',
--      {p_data})` ga o'tishi kerak; endi bu MUMKIN, chunki:
--         p_data.ext_ref = tok;            // AYNI token, suffikssiz
--         // 23505 -> isDup(e) -> xarHolat(tok) -> avvalgi oqim
--         // qaytish: {entry_id, kassa_summa, tolanmagan_summa, qarz_hisob_id}
--      `tolanmagan_summa > 0` bo'lsa UI qizil "To'lanmagan" ko'rsatishi
--      kerak (optimistik qoldiqni ham `kassa_summa` ga qarab kamaytirish
--      lozim — butun `amt` ga emas, aks holda qoldiq manfiy ko'rinadi).
--  🔴 Bu ish ALOHIDA bosqich va ALOHIDA test talab qiladi — shu faylda
--     HTML ga tegilmagan.


-- #####################################################################
-- ##  YAKUN — PostgREST sxema keshi (takroriy, zararsiz)             ##
-- #####################################################################
-- 3-BO'LIMdagi bilan bir xil. Bo'limlar bittalab RUN qilinganda oxirgi
-- qadam ham keshni yangilab qo'ysin (idempotent, hech narsa yozmaydi).
notify pgrst, 'reload schema';
-- =====================================================================
