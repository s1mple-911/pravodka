-- =====================================================================
--  PROVODKA_JURNAL_QOLDIQ.sql — Jurnal davr xulosasi: BOSHLANG'ICH + TUGASH
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--  Brief:   BRIEF_PROVODKA_SOROVLAR.md, 2-band ("JURNAL UI — Boshlang'ich
--           + Tugash miqdor") + .sorov-ui.md 3-bo'lim (zinapoya satri).
--
--  NIMA QO'SHILADI (bitta yangi RPC, boshqa hech narsa):
--     jurnal_qoldiq(p_from date, p_to date, p_accounts uuid[] default null)
--       -> jsonb { boshlangich, tugash, kirim, chiqim, transfer,
--                  transfer_net, boshqa_pul, chetlangan_pul,
--                  farq, mos, sabab, qamrov, kassa_soni }
--
--  🔴 jurnal_dash() GA UMUMAN TEGILMAYDI. U endigina RUN qilingan
--     (PROVODKA_IJROCHI.sql) va barqaror bo'lishi kerak: imzosi ham, tanasi
--     ham, javob kalitlari ham o'zgarmaydi. Zinapoya uchun ALOHIDA RPC.
--     Klient ikkalasini Promise.all bilan yonma-yon chaqiradi va javoblarni
--     o'zida qo'shadi.
--
--  🔴 HISOB MANTIQI QAYTA YOZILMAYDI — O'RALADI:
--       qoldiq  -> pul_qoldiq_kassa()   (PROVODKA_CASHFLOW_FIX.sql)
--       oqim    -> jurnal_v2_baza()     (PROVODKA_IJROCHI.sql, jurnal_dash
--                                        AYNAN shundan o'qiydi)
--     Sabab: nusxa ko'chirilsa cashflow-dev.html va jurnal-dev.html bir xil
--     davr uchun BOSHQA-BOSHQA raqam ko'rsatardi. Bu xato AI hisobotlarida
--     bir marta bo'lgan (CLAUDE.md, 5-bosqich) — takrorlanmasin.
--
--  🔴 DAVR BOSHI = p_from − 1 KUN (p_from EMAS).
--     cashflow-dev.html:405 dagi `pul_qoldiq_kassa(prevDay(d1), acc)` bilan
--     AYNAN bir xil qoida. p_from berilsa o'sha kunning yozuvlari ikki marta
--     (boshlang'ichda ham, kirimda ham) hisoblanardi.
--
--  🔴 PENDING YOZUVLAR HISOBGA KIRMAYDI — TASDIQLANDI, ikkala tomonda ham:
--       pul_qoldiq_kassa()  ->  `e.status = 'posted'`  (CASHFLOW_FIX 154-q.)
--       jurnal_v2_baza()    ->  `en.status = 'posted'` (IJROCHI 536-q.)
--     Ya'ni So'rovlar tizimi yaratadigan pending xarajat na qoldiqqa, na
--     kirim/chiqimga ta'sir qiladi. Tasdiqlangach (posted) ikkovi ham
--     birdaniga ko'radi — tenglama buzilmaydi.
--
--  SQL ADDITIVE: yangi funksiya, mavjud hech narsa o'chirilmaydi/almashmaydi.
--  Prod frontend bu funksiyani chaqirmaydi — u faqat jurnal-dev.html da.
-- =====================================================================


-- #####################################################################
-- ##  0. OLD SHARTLAR — RUN QILISHDAN OLDIN                          ##
-- #####################################################################
-- Hamma ustun `true` bo'lishi SHART. Birortasi `false` bo'lsa avval o'sha
-- faylni RUN qiling, aks holda jurnal_qoldiq() brauzerda 42883 beradi
-- (funksiya YARATILADI — plpgsql tanasi yaratishda tekshirilmaydi).
select to_regprocedure('public.pul_qoldiq_kassa(date,uuid)') is not null
         as pul_qoldiq_kassa_bor,          -- PROVODKA_CASHFLOW_FIX.sql
       to_regprocedure('public.kassa_oila(uuid)') is not null
         as kassa_oila_bor,                -- PROVODKA_CASHFLOW_FIX.sql
       to_regprocedure('public.perm_op_key(uuid)') is not null
         as perm_op_key_bor,               -- PROVODKA_PERM_TUR_FIX.sql
       to_regprocedure('public.perm_view_pul_ids()') is not null
         as perm_view_pul_ids_bor,         -- PROVODKA_V8.sql
       to_regprocedure('public.jurnal_page_ok(text)') is not null
         as jurnal_page_ok_bor,            -- PROVODKA_JURNAL_V2.sql
       to_regprocedure('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)') is not null
         as jurnal_v2_baza_bor;            -- PROVODKA_IJROCHI.sql


-- #####################################################################
-- ##  1. jurnal_qoldiq() — davr boshi/oxiri qoldig'i + tenglama       ##
-- #####################################################################
-- QAMROV (scope) — uch bosqichda quriladi:
--
--   1) TANLOV     v_scope  = pul hisoblari, p_accounts bilan kesishtirilgan.
--                 "Pul hisobi" ta'rifi — `section = 'pul'`, KOD PREFIKSI
--                 BILAN EMAS (CLAUDE.md: kod prefiksi eski usul). AYNAN shu
--                 ta'rif jurnal_v2_baza ning tur tasnifida ishlatiladi
--                 (dt_sec/kt_sec = 'pul'), ya'ni tenglamaning ikkala tomoni
--                 "pul" so'zini bir xil tushunadi.
--                 `kassa_turi = 'xarajat_guruh'` (5400 konteyner) chiqarib
--                 tashlanadi — unga hech qachon pul yozilmaydi.
--
--   2) RUXSAT     perm_view_pul_ids() bilan kesishtiriladi (null = cheklovsiz).
--                 🔴 BU MAJBURIY: funksiya SECURITY DEFINER, ichidan
--                 chaqiriladigan pul_qoldiq_kassa() esa SECURITY INVOKER —
--                 DEFINER ichida u EGA huquqi bilan ishlaydi va RLS ni
--                 chetlab o'tadi. Ya'ni ruxsat SHU YERDA majburlanmasa,
--                 cheklangan foydalanuvchi begona kassaning qoldig'ini
--                 ko'rib qolardi. Klient p_accounts ni o'zgartirsa ham
--                 foyda bermaydi — kesishma serverda.
--
--   3) OILA       Har tanlangan hisobning ILDIZI perm_op_key() bilan
--                 topiladi (valyuta/pul turi bolasi -> parent, hodim
--                 kassasi -> o'zi), ildizlar DISTINCT qilinadi va har biri
--                 uchun pul_qoldiq_kassa() BIR MARTA chaqiriladi.
--                 🔴 DISTINCT ildiz — ikki marta sanashning oldini oladi:
--                 pul_qoldiq_kassa(root) allaqachon butun oilani yig'adi,
--                 shuning uchun p_accounts ichida parent ham, bolasi ham
--                 bo'lsa qoldiq ikki barobar chiqib ketardi.
--                 Oilalar o'zaro kesishmaydi (har bola bitta parentga
--                 tegishli) — demak ildizlar bo'yicha yig'indi to'g'ri.
--
--   4) HAMMASI    p_accounts null VA ruxsat cheklovsiz bo'lsa —
--                 pul_qoldiq_kassa(p_date, null) ga DELEGAT (u o'z navbatida
--                 eski pul_qoldiq(p_date, null) ga tushadi). Bu cashflow
--                 sahifasining "Hamma kassalar" holati bilan AYNAN bitta
--                 yo'l: bir xil davr uchun ikkala sahifa bir xil raqamni
--                 ko'rsatadi. Ildizlar bo'yicha aylanma ham qilinmaydi
--                 (80+ kassa = 160 ta so'rov).
--
-- TENGLAMA (server tekshiradi, klient TAXMIN QILMAYDI):
--       boshlangich + kirim − chiqim + transfer_net = tugash
--   kirim/chiqim/transfer — jurnal_dash BILAN AYNAN BITTA MANBADAN:
--   jurnal_v2_baza(...) + o'sha fail-closed chetlashlar (o'chirilgan yozuv;
--   aralash = begona and n_lines > 2) + o'sha guruhlash
--   (kirim = kirim+tushum, chiqim = chiqim+xarajat).
--   Farqi 1 so'mdan katta bo'lsa `mos = false` qaytadi va klient zinapoyani
--   UMUMAN chizmaydi (.sorov-ui.md 3.3-c: ko'rinadigan, lekin qo'shilmaydigan
--   tenglama — eng yomon variant).
--
-- ⚠️ TENGLAMA QACHON CHIQMAYDI (mos = false) — to'liq ro'yxat:
--
--   A) KO'P SATRLI (n_lines > 2) YOZUV PULGA TEGSA.  professional-dev.html
--      yozadigan yozuv `tur = 'boshqa'` ga tushadi, ya'ni na Kirim, na
--      Chiqim kartasiga kiradi — lekin kassa qoldig'ini O'ZGARTIRADI.
--      Bu ENG KO'P UCHRAYDIGAN sabab. Javobdagi `boshqa_pul` aynan shu
--      summani beradi (net, ya'ni musbat = pul kirgan).
--      🔴 Bu KAMCHILIK EMAS, QAROR: 'boshqa' ni Kirim/Chiqimga qo'shib
--      yuborish kartalar bilan zid raqam berardi (kartada 8 mln, zinapoyada
--      9 mln) — ikkinchi hisob yozilmaydi.
--
--   B) ARALASH YOZUV CHETLANGANDA.  jurnal_dash agregatlari fail-closed:
--      begona kassa satri bor ko'p satrli yozuv jamiga kirmaydi. Uning pul
--      satri esa qoldiqda bor. Javobdagi `chetlangan_pul`.
--
--   C) MODDA / QIDIRUV / IJROCHI FILTRI YOQILGANDA.  Bu RPC ning imzosida
--      p_moddalar / p_q / p_ijrochi YO'Q (ataylab — qoldiq filtrga
--      bo'ysunmaydi, u kassaning haqiqiy holati). Klient esa kartalarda
--      FILTRLANGAN kirim/chiqimni ko'rsatadi. Shuning uchun jurnal-dev.html
--      bu filtrlar yoqilgan bo'lsa RPC ni UMUMAN CHAQIRMAYDI va zinapoyani
--      yashiradi — server javobi bilan ekrandagi raqam hech qachon
--      yonma-yon zid turmaydi.
--
--   D) HISOB FILTRIDA PUL BO'LMAGAN HISOB TANLANGANDA (jurnaldagi "Hisob"
--      tanlagichi xarajat moddasini ham beradi, masalan 9421). U holda
--      v_scope bo'sh qoladi -> mos = false, sabab = 'qamrovda pul hisobi
--      yoq'. Fail-closed: "0 so'm qoldiq" kabi yolg'on raqam CHIQMAYDI.
--
--   E) NOFAOL (is_active = false) BOLA-HISOB.  pul_qoldiq_kassa oilani
--      yig'ganda `c.is_active` shartini qo'yadi, entry_line esa nofaol
--      hisobning eski satrlarini ham saqlaydi. Eski 53xx/56xx xarajat
--      kassalari shu holatga tushishi mumkin.
--
--   F) KASSALARARO TRANSFER, kassa/filial filtri bilan.  Bu SABAB EMAS —
--      u `transfer_net` bilan TO'G'RI hisoblanadi (oila ichidagi tur
--      o'tkazishi net 0 beradi, tashqariga jo'natilgani manfiy). Filtrsiz
--      holatda transfer_net = 0 chiqadi. Klient transfer_net nolga teng
--      bo'lmasa zinapoyaga 5-segment ("Transfer") qo'shadi.
--
--   G) HISOB TA'RIFI TAFOVUTI.  `section = 'pul'` (bu fayl va tur tasnifi)
--      va `type = 'aktiv' and code like '5%'` (perm_view_pul_ids) — ikki xil
--      ta'rif. Amalda ular bir xil to'plamni beradi; farq bo'lsa 3-bo'limdagi
--      "tafovut" so'rovi ko'rsatadi.
--
-- ⚠️ TEZLIK: har ildiz uchun pul_qoldiq_kassa() IKKI marta (boshi + oxiri)
--    chaqiriladi. Amalda ildiz soni 1–6 (filial yoki hodim filtri). Ro'yxat
--    150 dan oshsa funksiya hisoblamaydi (`sabab = 'qamrov juda keng'`) —
--    jurnal sahifasi sekinlashib qolmasin.
-- ---------------------------------------------------------------------

create or replace function jurnal_qoldiq(
  p_from     date,
  p_to       date,
  p_accounts uuid[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  c_eps    constant numeric := 1;      -- 1 so'm — yaxlitlash bardoshi
  c_max    constant int     := 150;    -- ildizlar chegarasi (tezlik qorovuli)
  v_perm   uuid[];
  v_scope  uuid[];
  v_roots  uuid[];
  v_fam    uuid[];
  v_hammasi boolean := false;
  v_open   numeric := 0;
  v_close  numeric := 0;
  v_kirim  numeric := 0;
  v_chiqim numeric := 0;
  v_tr     numeric := 0;
  v_trnet  numeric := 0;
  v_boshqa numeric := 0;
  v_chet   numeric := 0;
  v_farq   numeric := 0;
  v_mos    boolean := false;
  v_sabab  text    := null;
  v_n      int     := 0;
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;

  -- 🔴 SAHIFA QOROVULI — uchala jurnal RPC si bilan AYNAN bir xil naqsh.
  --    Kassa ruxsati YETARLI EMAS (kassa_scope sukuti 'all').
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  -- Old shart: PROVODKA_CASHFLOW_FIX.sql RUN qilinmagan bo'lsa jimgina
  -- "mos emas" qaytariladi (klient zinapoyani chizmaydi, jurnal ishlayveradi).
  -- Xato ko'tarilmaydi — dashboard va ro'yxat bu RPC ga bog'liq emas.
  if to_regprocedure('public.pul_qoldiq_kassa(date,uuid)') is null then
    return jsonb_build_object('mos', false, 'sabab', 'pul_qoldiq_kassa yoq',
                              'kassa_soni', 0);
  end if;

  v_perm := perm_view_pul_ids();               -- null = cheklovsiz (admin)

  -- 1–2) Tanlov + ruxsat kesishmasi
  select array_agg(a.id) into v_scope
    from accounts a
   where a.section = 'pul'
     and a.kassa_turi is distinct from 'xarajat_guruh'
     and (p_accounts is null or a.id = any(p_accounts))
     and (v_perm     is null or a.id = any(v_perm));

  if v_scope is null or array_length(v_scope, 1) is null then
    return jsonb_build_object('mos', false, 'sabab', 'qamrovda pul hisobi yoq',
                              'kassa_soni', 0);
  end if;

  v_hammasi := (p_accounts is null and v_perm is null);

  if v_hammasi then
    -- 4) HAMMASI: cashflow sahifasining "Hamma kassalar" yo'li bilan AYNAN bir xil.
    v_fam   := v_scope;
    v_open  := coalesce(pul_qoldiq_kassa(p_from - 1, null), 0);
    v_close := coalesce(pul_qoldiq_kassa(p_to,       null), 0);
  else
    -- 3) OILA: ildizlar (DISTINCT) -> har biriga pul_qoldiq_kassa()
    select array_agg(distinct perm_op_key(u.id)) into v_roots
      from unnest(v_scope) u(id);

    if v_roots is null or array_length(v_roots, 1) is null then
      return jsonb_build_object('mos', false, 'sabab', 'ildiz topilmadi',
                                'kassa_soni', 0);
    end if;

    v_n := array_length(v_roots, 1);
    if v_n > c_max then
      return jsonb_build_object('mos', false, 'sabab', 'qamrov juda keng',
                                'kassa_soni', v_n);
    end if;

    -- Butun oila (parent + tur/valyuta bolalari) — transfer_net va
    -- diagnostika satrlarini shu ro'yxat bo'yicha o'lchaymiz.
    select array_agg(distinct f.id) into v_fam
      from unnest(v_roots) r(id), unnest(kassa_oila(r.id)) f(id);

    select coalesce(sum(pul_qoldiq_kassa(p_from - 1, r.id)), 0) into v_open
      from unnest(v_roots) r(id);
    select coalesce(sum(pul_qoldiq_kassa(p_to,       r.id)), 0) into v_close
      from unnest(v_roots) r(id);
  end if;

  if v_fam is null or array_length(v_fam, 1) is null then
    v_fam := v_scope;
  end if;

  -- OQIM — jurnal_dash BILAN BITTA MANBA.
  -- 🔴 p_accounts AYNAN o'zgartirilmasdan uzatiladi (oila kengaytmasi
  --    EMAS): jurnal_dash ham shu qiymat bilan chaqiriladi, ya'ni yozuv
  --    to'plami ikkalasida bir xil bo'ladi.
  -- 🔴 p_moddalar / p_turlar / p_q — null. p_turlar jurnal_dash da ham
  --    e'tiborga olinmaydi; moddalar/qidiruv esa bu RPC imzosida yo'q
  --    (yuqoridagi C bandi).
  with b as materialized (
    select * from jurnal_v2_baza(p_from, p_to, p_accounts, null, null, null) z
  ),
  bs as (
    -- AYNAN jurnal_dash dagi ikki chetlash (fail-closed agregat)
    select * from b
     where coalesce(b.is_deleted, false) = false
       and not (b.begona and b.n_lines > 2)
  ),
  t as (
    select coalesce(sum(bs.summa) filter (where bs.tur in ('kirim', 'tushum')),   0)::numeric as kirim,
           coalesce(sum(bs.summa) filter (where bs.tur in ('chiqim', 'xarajat')), 0)::numeric as chiqim,
           coalesce(sum(bs.summa) filter (where bs.tur = 'transfer'),             0)::numeric as tr
      from bs
  ),
  trn as (
    -- Transferning QAMROVGA net ta'siri: oila ichidagi ko'chirish 0 beradi,
    -- tashqariga jo'natilgani manfiy, tashqaridan kelgani musbat.
    select coalesce(sum(l.debit - l.credit), 0)::numeric as net
      from bs
      join entry_line l on l.entry_id = bs.id
     where bs.tur = 'transfer'
       and l.account_id = any(v_fam)
  ),
  bq as (
    -- Diagnostika (A bandi): ko'p satrli / neytral yozuvlarning pulga ta'siri
    select coalesce(sum(l.debit - l.credit), 0)::numeric as net
      from bs
      join entry_line l on l.entry_id = bs.id
     where bs.tur = 'boshqa'
       and l.account_id = any(v_fam)
  ),
  ch as (
    -- Diagnostika (B bandi): agregatdan chetlangan aralash yozuvlar
    select coalesce(sum(l.debit - l.credit), 0)::numeric as net
      from b
      join entry_line l on l.entry_id = b.id
     where coalesce(b.is_deleted, false) = false
       and b.begona and b.n_lines > 2
       and l.account_id = any(v_fam)
  )
  select t.kirim, t.chiqim, t.tr, trn.net, bq.net, ch.net
    into v_kirim, v_chiqim, v_tr, v_trnet, v_boshqa, v_chet
    from t, trn, bq, ch;

  v_kirim  := coalesce(v_kirim, 0);
  v_chiqim := coalesce(v_chiqim, 0);
  v_tr     := coalesce(v_tr, 0);
  v_trnet  := coalesce(v_trnet, 0);
  v_boshqa := coalesce(v_boshqa, 0);
  v_chet   := coalesce(v_chet, 0);

  v_farq := (v_open + v_kirim - v_chiqim + v_trnet) - v_close;
  v_mos  := abs(v_farq) < c_eps;

  if not v_mos then
    v_sabab := 'tenglama chiqmadi';
    if abs(v_boshqa) >= c_eps then
      v_sabab := v_sabab || ' · kop satrli/neytral yozuv pulga tegdi';
    end if;
    if abs(v_chet) >= c_eps then
      v_sabab := v_sabab || ' · aralash yozuv chetlangan';
    end if;
  end if;

  return jsonb_build_object(
    'boshlangich',    round(v_open),
    'tugash',         round(v_close),
    'kirim',          round(v_kirim),
    'chiqim',         round(v_chiqim),
    'transfer',       round(v_tr),
    'transfer_net',   round(v_trnet),
    'boshqa_pul',     round(v_boshqa),
    'chetlangan_pul', round(v_chet),
    'farq',           round(v_farq),
    'mos',            v_mos,
    'sabab',          v_sabab,
    'qamrov',         case when v_hammasi then 'hammasi' else 'tanlangan' end,
    'kassa_soni',     coalesce(array_length(v_roots, 1), array_length(v_scope, 1), 0));
end $fn$;

revoke all on function jurnal_qoldiq(date, date, uuid[]) from public, anon;
grant execute on function jurnal_qoldiq(date, date, uuid[]) to authenticated;

comment on function jurnal_qoldiq(date, date, uuid[]) is
  'Jurnal davr xulosasi uchun BOSHLANGICH (p_from − 1 kun) va TUGASH (p_to) pul qoldigi. '
  'Qoldiq — pul_qoldiq_kassa() ni ORAYDI (cashflow-dev.html bilan bitta manba, qayta yozilmagan); '
  'kirim/chiqim/transfer — jurnal_v2_baza() dan, jurnal_dash bilan AYNAN bitta manba va bitta fail-closed qoida. '
  'Ildizlar perm_op_key() bilan DISTINCT qilinadi — oila ikki marta sanalmaydi. '
  'Ruxsat perm_view_pul_ids() bilan SHU YERDA majburlanadi (DEFINER ichida INVOKER RLS ni chetlab otadi). '
  'Sahifa qorovuli: jurnal_page_ok(''jurnal''). Pending yozuvlar ikkala tomonda ham HISOBGA KIRMAYDI (status=''posted''). '
  'Tenglama: boshlangich + kirim − chiqim + transfer_net = tugash. Chiqmasa mos=false + farq + sabab qaytadi '
  'va klient zinapoyani UMUMAN chizmaydi (fail-closed). jurnal_dash() ga TEGILMAGAN.';


-- =====================================================================
-- PostgREST sxemasini yangilash (busiz yangi RPC 404/PGRST202 beradi)
-- =====================================================================

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  2. TEKSHIRUV — FAQAT KATALOG SO'ROVLARI                        ##
-- #####################################################################
-- 🔴 JONLI RPC CHAQIRUVI YO'Q: SQL editorda `auth.uid()` null → sahifa
--    qorovuli 42501 beradi va butun fayl (bitta tranzaksiya) orqaga
--    qaytib, funksiya umuman yaratilmasdi. Jonli sinov — brauzerda.
-- ---------------------------------------------------------------------

-- 2.1 Funksiya o'rnidami va imzosi to'g'rimi (ikkalasi ham true)
select to_regprocedure('public.jurnal_qoldiq(date,date,uuid[])') is not null
         as jurnal_qoldiq_ok,
       (select count(*)::int from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname = 'jurnal_qoldiq') = 1
         as overload_bittami;

-- 2.2 🔴 jurnal_dash() TEGILMAGANMI — hamma ustun true bo'lishi SHART.
--     (Bu fayl uni na drop qiladi, na replace — tekshiruv ataylab qat'iy.)
select to_regprocedure('public.jurnal_dash(date,date,uuid[],uuid[],text[],text,text)') is not null
         as dash_yangi_imzo_joyida,
       to_regprocedure('public.jurnal_dash(date,date,uuid[],uuid[],text[],text)') is null
         as dash_eski_imzo_yoq,
       (select count(*)::int from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname = 'jurnal_dash') = 1
         as dash_overload_bittami,
       (select p.prosrc not like '%jurnal_qoldiq%' from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname = 'jurnal_dash')
         as dash_tanasi_tegilmagan;

-- 2.3 Bog'liq obyektlar hamon joyidami (hammasi true).
--     🔴 Bular bo'lmasa BU FAYL BARIBIR MUVAFFAQIYATLI RUN BO'LADI
--     (plpgsql tanasi yaratishda tekshirilmaydi), lekin brauzerda RPC
--     42883 bilan yiqiladi va zinapoya jimgina chiqmay qoladi.
select to_regprocedure('public.pul_qoldiq_kassa(date,uuid)') is not null as pul_qoldiq_kassa_bor,
       to_regprocedure('public.kassa_oila(uuid)')            is not null as kassa_oila_bor,
       to_regprocedure('public.perm_op_key(uuid)')           is not null as perm_op_key_bor,
       to_regprocedure('public.perm_view_pul_ids()')         is not null as perm_view_bor,
       to_regprocedure('public.jurnal_page_ok(text)')        is not null as qorovul_bor,
       to_regprocedure('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)') is not null as baza_bor;

-- 2.4 Huquqlar: anon YOPIQ, authenticated OCHIQ
select has_function_privilege('anon',
         'public.jurnal_qoldiq(date,date,uuid[])', 'execute') as anon_YOPIQ_BULSIN,
       has_function_privilege('authenticated',
         'public.jurnal_qoldiq(date,date,uuid[])', 'execute') as authenticated_OCHIQ;

-- 2.5 Sahifa qorovuli va pending filtri tanada bormi (ikkalasi true)
select p.prosrc like '%jurnal_page_ok(''jurnal'')%' as qorovul_tanada,
       p.prosrc like '%perm_view_pul_ids()%'        as ruxsat_tanada,
       p.prosrc like '%pul_qoldiq_kassa%'           as qoldiq_oralgan,
       p.prosrc like '%jurnal_v2_baza%'             as oqim_oralgan,
       p.provolatile = 's'                          as stable_mi,
       p.prosecdef                                  as definer_mi
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.proname = 'jurnal_qoldiq';

-- 2.6 🔴 PENDING TASDIQI — o'ralgan ikki funksiya HAMON 'posted' filtrlaydimi.
--     Ikkala ustun ham true bo'lishi SHART. False bo'lsa tenglama pending
--     yozuvlar tufayli bir tomonlama siljiydi (qoldiqda bor, oqimda yo'q).
select (select p.prosrc like '%status = ''posted''%' from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.proname = 'pul_qoldiq_kassa')
         as qoldiq_posted_filtri,
       (select p.prosrc like '%status = ''posted''%' from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.proname = 'jurnal_v2_baza')
         as oqim_posted_filtri;

-- 2.7 "Pul hisobi" ta'riflari tafovuti (G bandi).
--     BO'SH natija = ikki ta'rif bir xil to'plamni beradi (kutilgan holat).
--     Qator chiqsa — o'sha hisoblar tenglamada farq yaratishi mumkin.
select a.code, a.name, a.type, a.section, a.kassa_turi, a.is_active,
       (coalesce(a.section, '') = 'pul')                     as sectionda_pul,
       (a.type = 'aktiv' and a.code like '5%')               as kodda_pul
  from accounts a
 where (coalesce(a.section, '') = 'pul') <> (a.type = 'aktiv' and a.code like '5%')
   and coalesce(a.kassa_turi, '') <> 'xarajat_guruh'
 order by a.code;

-- 2.8 ⭐ ZINAPOYA QANCHALIK TEZ-TEZ YASHIRINADI (A bandi o'lchovi).
--     Ko'p satrli (n > 2) yozuvlar oyma-oy: `pulga_tekkan` ustuni 0 bo'lgan
--     oylarda zinapoya ko'rinadi, 0 dan katta oylarda mos=false bo'lib
--     yashirinishi mumkin. Bu — qaror uchun raqam, xato emas.
with x as (
  select e.id, date_trunc('month', e.entry_date)::date as oy,
         (select count(*) from entry_line l where l.entry_id = e.id) as n,
         exists (select 1 from entry_line l join accounts a on a.id = l.account_id
                  where l.entry_id = e.id and a.section = 'pul') as pulga_tegdi
    from entry e
   where e.status = 'posted' and e.is_deleted = false
     and e.entry_date >= (current_date - 180)
)
select x.oy,
       count(*) filter (where x.n > 2)                        as kop_satrli,
       count(*) filter (where x.n > 2 and x.pulga_tegdi)      as pulga_tekkan,
       count(*)                                               as jami_yozuv
  from x
 group by x.oy
 order by x.oy desc;

-- 2.9 Ildiz sonining amaldagi kattaligi (tezlik qorovuli 150 yetarlimi).
--     `ildiz_soni` — filtrsiz holatda oila ildizlari soni. 150 dan kichik
--     bo'lsa hamma qamrov hisoblanadi. (Filtrsiz holat baribir DELEGAT
--     yo'lidan ketadi — bu son faqat cheklangan foydalanuvchilar uchun.)
select count(distinct perm_op_key(a.id))::int as ildiz_soni
  from accounts a
 where a.section = 'pul'
   and a.kassa_turi is distinct from 'xarajat_guruh';


-- #####################################################################
-- ##  3. ROLLBACK — faqat shu fayl qo'shgan narsani olib tashlaydi    ##
-- #####################################################################
-- Xavfsiz: bu fayl BOSHQA hech qanday obyektni o'zgartirmagan, shuning
-- uchun rollback bitta drop dan iborat. Undan keyin jurnal-dev.html
-- zinapoyani jimgina chizmay qo'yadi (PGRST202 -> fail-closed), dashboard
-- va ro'yxat esa avvalgidek ishlayveradi.
--
--   drop function if exists public.jurnal_qoldiq(date, date, uuid[]);
--   notify pgrst, 'reload schema';
--
-- 🔴 jurnal_dash / jurnal_v2_baza / pul_qoldiq_kassa GA TEGMANG — ular
--    boshqa fayllarga tegishli va prod sahifalar ularga bog'liq.
