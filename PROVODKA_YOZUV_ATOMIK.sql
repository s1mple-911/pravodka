-- =====================================================================
-- PROVODKA_YOZUV_ATOMIK.sql
-- Yozuvni ATOMIK qilish: provodka_yoz(jsonb) RPC
-- ---------------------------------------------------------------------
-- ## MUAMMO (jonli, 13 kundan beri)
-- `provodka.html` va `professional.html` yozuvni IKKI QADAMDA yozadi:
--
--     1) insert into entry       ->  commit
--     2) insert into entry_line  ->  commit
--
-- 2-qadam rad etilsa (perm guard 42501, limit guard, Dt<>Kt, RLS) klient
-- kompensatsiya qilib `entry` ni o'chirmoqchi bo'ladi. LEKIN `entry`
-- o'chirish RLS bo'yicha FAQAT ADMIN ga ochiq: oddiy foydalanuvchida
-- `delete` xato ham bermaydi, 0 qator o'chiradi va bazada YETIM SARLAVHA
-- qoladi (`entry` bor, `entry_line` yo'q).
--
-- Yetim sarlavha pul harakatini buzmaydi (balans faqat `entry_line` dan
-- yig'iladi), lekin jurnalda bo'sh yozuv bo'lib turadi, hisobotlarni
-- chalkashtiradi va "saqlandimi yoki yo'qmi" degan savolni tug'diradi.
-- Bazada shunday 13 ta yozuv bor.
--
-- ## SHU FAYL NIMA QILADI
-- YANGI RPC `provodka_yoz(p_data jsonb)` — sarlavha + satrlar + (ixtiyoriy)
-- yuk taqsimotini BITTA funksiya tanasida yozadi. Funksiya tanasi = bitta
-- tranzaksiya: har qanday rad etish BUTUN yozuvni orqaga qaytaradi.
-- Yetim tug'ilmaydi, kompensatsiya `delete` umuman kerak emas.
--
-- ## 🔴 SECURITY INVOKER (definer EMAS) — ATAYLAB
-- `entry_line` ustidagi to'siqlar bugungidek ishlashi SHART:
--   * `trg_perm_guard_entry_line`   (before insert, for each row)  — 42501
--   * `trg_limit_guard_entry_line`  (after insert,  for each row)
--   * `trg_hodim_notify_entry_line` (after insert,  for each row)
--   * `check_entry_balanced`        (DEFERRED constraint trigger)
--   * `entry` va `entry_line` RLS siyosatlari
-- Triggerlar definer'da ham ishlaydi, RLS esa FAQAT invoker'da. Definer
-- qilinsa pul qorovuli zaiflashardi — shuning uchun invoker.
-- Yon ta'siri: funksiya foydalanuvchi huquqi bilan ishlaydi, ya'ni
-- bugungi klient insertlari nimaga ruxsat etilgan bo'lsa, RPC ham
-- AYNAN o'shanga ruxsat etiladi. Yangi teshik ochilmaydi.
--
-- ## 🔴 XATO MATNI YUTILMAYDI
-- `exception when others` YO'Q. Trigger/RLS xatosi klientga O'Z KODI va
-- O'Z MATNI bilan boradi (42501 "Ruxsat yoq: … kassasida amaliyot qilish
-- huquqingiz yoq" va h.k.) — `permErr()` uni o'zbekcha ko'rsatadi.
-- Yagona ushlanadigan holat: `unique_violation` (ext_ref takrori), u ham
-- AYNI 23505 kodi bilan qayta ko'tariladi.
--
-- ## QOIDALAR
--   * ADDITIVE: hech qanday ustun/funksiya/trigger o'zgartirilmaydi yoki
--     o'chirilmaydi. Faqat BITTA yangi funksiya qo'shiladi.
--   * Eski ikki qadamli yo'l bazada hamon ishlaydi — klientdagi zaxira
--     (RPC yo'q bo'lsa) shunga tayanadi, ya'ni bu faylni RUN qilishdan
--     oldin ham sahifalar buzilmaydi.
--   * Faylda JONLI RPC chaqiruvi YO'Q. Faqat katalog tekshiruvlari.
--   * `do` bloki YO'Q (Supabase SQL editorida ishlamaydi).
--
-- ## RUN TARTIBI
--     0-BO'LIM  — TEKSHIRUV (o'qish, hech narsa o'zgarmaydi)
--     1-BO'LIM  — provodka_yoz(jsonb)  (create or replace)
--     2-BO'LIM  — huquqlar + izoh
--     3-BO'LIM  — RUN dan KEYIN katalog tekshiruvi
--     4-BO'LIM  — ROLLBACK
--     5-BO'LIM  — KLIENT KONTRAKTI (o'qish uchun)
--
-- Old shart: `entry.ext_ref` ustidagi UNIQUE indeks (PROVODKA_EXT_REF.sql
-- 1.1). Indeks bo'lmasa RPC baribir ishlaydi, faqat takror himoyasi
-- bo'lmaydi (0.3 tekshiruvi buni ko'rsatadi).
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — TEKSHIRUV (RUN dan OLDIN)                           ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 0.1  `entry` ustunlari — RPC AYNAN shu ro'yxatga yozadi.
--      Kutilgan: entry_date, description, source, status, filial_ids,
--      davr_start, davr_end, kommunal_turi, fc_rate, yuk_ids,
--      yuk_kutilmoqda, ext_ref — hammasi bor.
--      🔴 Biror ustun YO'Q bo'lsa 1-BO'LIM ni RUN QILMANG: funksiya
--      yaratilmaydi (42703) va sabab shu ro'yxatda ko'rinadi.
--      ESLATMA: `warehouse_id` `entry` da YO'Q (u `accounts` ustuni) —
--      shuning uchun RPC uni qabul qilmaydi.
-- ---------------------------------------------------------------------
select column_name, data_type, is_nullable, column_default
  from information_schema.columns
 where table_schema = 'public' and table_name = 'entry'
   and column_name in ('entry_date','description','source','status','filial_ids',
                       'davr_start','davr_end','kommunal_turi','fc_rate',
                       'yuk_ids','yuk_kutilmoqda','ext_ref','created_by')
 order by column_name;

-- ---------------------------------------------------------------------
-- 0.2  `entry_yuk` jadvali bormi (qisman to'lov taqsimoti).
--      ⚠️ plpgsql tanasi FAQAT sintaksis bo'yicha tekshiriladi — jadval nomi
--      yaratish paytida tekshirilmaydi. Ya'ni jadval bo'lmasa funksiya
--      MUAMMOSIZ yaratiladi, lekin `yuk_taqsim` berilgan birinchi yozuvda
--      42P01 bilan yiqiladi (yozuv saqlanmaydi — atomik).
--      Kutilgan: entry_yuk. null chiqsa avval PROVODKA_YUK_QISMAN.sql RUN qilinsin.
-- ---------------------------------------------------------------------
select to_regclass('public.entry_yuk') as entry_yuk_jadval;

-- ---------------------------------------------------------------------
-- 0.3  `ext_ref` UNIQUE indeksi (takror himoyasining YAGONA to'sig'i).
--      Kutilgan: entry_ext_ref_uniq bor.
--      Yo'q bo'lsa: PROVODKA_EXT_REF.sql 1.1 ni RUN qiling.
-- ---------------------------------------------------------------------
select indexname, indexdef
  from pg_indexes
 where schemaname = 'public' and tablename = 'entry'
   and indexdef ilike '%ext_ref%'
 order by indexname;

-- ---------------------------------------------------------------------
-- 0.4  `entry_line` ustidagi to'siqlar — RPC ulardan O'TISHI shart
--      (invoker bo'lgani uchun bugungidek ishlaydi).
--      Kutilgan: trg_perm_guard_entry_line, trg_limit_guard_entry_line,
--      trg_hodim_notify_entry_line va DEFERRED check_entry_balanced.
-- ---------------------------------------------------------------------
select t.tgname,
       t.tgenabled,
       t.tgdeferrable,
       t.tginitdeferred,
       p.proname as funksiya
  from pg_trigger t
  join pg_class  c on c.oid = t.tgrelid
  join pg_proc   p on p.oid = t.tgfoid
 where c.relname = 'entry_line' and not t.tgisinternal
 order by t.tgname;

-- ---------------------------------------------------------------------
-- 0.5  Bugungi YETIM sarlavhalar (satrsiz entry) — RPC dan keyin bu son
--      ORTMASLIGI kerak. Mavjud 13 tasi bu fayl bilan TOZALANMAYDI
--      (tozalash alohida ish — DIAG_YETIM.sql / DIAG_YETIM_DETAL.sql).
-- ---------------------------------------------------------------------
select count(*) as yetim_sarlavha
  from entry e
 where not exists (select 1 from entry_line l where l.entry_id = e.id);

-- ---------------------------------------------------------------------
-- 0.6  Funksiya allaqachon bormi (qayta RUN qilinayotgan bo'lsa).
--      Kutilgan (birinchi RUN): null.
-- ---------------------------------------------------------------------
select to_regprocedure('public.provodka_yoz(jsonb)') as provodka_yoz_bor;


-- #####################################################################
-- ##  1-BO'LIM — provodka_yoz(p_data jsonb)                          ##
-- #####################################################################
-- ## KIRITMA (jsonb)
--   Sarlavha (HAMMASI IXTIYORIY, berilmasa null / ustun sukuti):
--     entry_date      date    'YYYY-MM-DD'
--     description     text
--     source          text    sukut 'manual'
--     status          text    sukut 'posted'
--     filial_ids      uuid[]  massiv, sukut bo'sh massiv
--     davr_start      date
--     davr_end        date
--     kommunal_turi   text
--     fc_rate         numeric
--     yuk_ids         int[]   massiv, sukut bo'sh massiv
--     yuk_kutilmoqda  bool    sukut false
--     ext_ref         text    takror himoyasi tokeni (8..120 belgi)
--
--   Satrlar (MAJBURIY):
--     lines: [{account_id uuid, debit numeric, credit numeric,
--              fc_amount numeric|null}, ...]     -- kamida 2 ta
--
--   Yuk taqsimoti (IXTIYORIY, entry_yuk):
--     yuk_taqsim: [{yuk_id int, summa_uzs numeric}, ...]
--
-- ## QAYTISHI (jsonb)
--     {"ok": true, "entry_id": "<uuid>", "satr": <int>, "yuk": <int>}
--
-- ## XATOLAR (kod bilan)
--     22000  — validatsiya (o'zbekcha matn, klientga shundayligicha boradi)
--     23505  — ext_ref takrori: 'Bu xarajat allaqachon saqlangan
--              (takroriy yuborish tosildi)'  (matn va kod
--              `xarajat_saqlash_taqsim` bilan AYNAN bir xil — klientdagi
--              `isDup` ikkala yo'lda bir xil ishlashi uchun)
--     42501  — perm guard / RLS (trigger matni O'ZGARTIRILMASDAN chiqadi)
--     55P03  — lock_timeout (baza band, 5 soniya)
--     boshqasi — trigger/constraint xatosi, AYNAN o'z holicha.
--
-- ## 🔴 NEGA `entry_line` BITTA `insert ... select` BILAN
-- Bugungi klient ikkala satrni BITTA insert statementida yozadi.
-- Triggerlar `for each row` bo'lgani uchun natija bir xil, lekin
-- statement sonini o'zgartirmaslik eng xavfsiz yo'l: kelajakda
-- statement-level trigger qo'shilsa ham xatti-harakat farq qilmaydi.
-- ---------------------------------------------------------------------
create or replace function provodka_yoz(p_data jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $fn$
declare
  v_lines jsonb := p_data -> 'lines';
  v_yuk   jsonb := p_data -> 'yuk_taqsim';
  v_ext   text  := nullif(trim(p_data ->> 'ext_ref'), '');
  v_n     int;
  v_bad   int;
  v_dt    numeric;
  v_kt    numeric;
  v_entry uuid;
  v_yn    int := 0;
begin
  -- 🔴 lock_timeout — "Saqlanmoqda…" abadiy aylanmasin. Baza band bo'lsa
  --    5 soniyada 55P03 bilan ANIQ xato qaytadi.
  --    `set local` (uchinchi argument true) faqat shu tranzaksiyaga tegishli;
  --    funksiyada `set search_path` bandi borligi uchun chiqishda GUC lar
  --    avtomat tiklanadi, sessiyaga sizmaydi.
  --    ⚠️ `statement_timeout` ATAYLAB tegilmaydi: u statement boshlanganda
  --    o'rnatiladi, funksiya ichida o'zgartirish joriy so'rovga ta'sir qilmaydi.
  perform set_config('lock_timeout', '5s', true);

  -- ---- 1. Token shakli ----------------------------------------------
  -- Juda qisqa token boshqa yozuvlarga tegib ketishi mumkin edi
  -- (`xarajat_qayta_urinish` prefiks bo'yicha qidiradi), shuning uchun
  -- uzunlik chegaralanadi. Xato bo'lsa JIM QOLMAYMIZ.
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bo''lishi kerak' using errcode = '22000';
  end if;

  -- ---- 2. Satrlar bormi ---------------------------------------------
  if v_lines is null or jsonb_typeof(v_lines) <> 'array' then
    raise exception 'Yozuv satrlari (lines) berilmadi' using errcode = '22000';
  end if;
  v_n := jsonb_array_length(v_lines);
  if v_n < 2 then
    raise exception 'Yozuvda kamida 2 ta satr bo''lishi kerak (Dt va Kt)' using errcode = '22000';
  end if;

  -- ---- 3. Satr maydonlarining TURI ----------------------------------
  -- Cast xatosi (22P02) o'rniga tushunarli o'zbekcha xato bo'lsin:
  -- avval turni tekshiramiz, keyingi bandlarda cast xavfsiz bo'ladi.
  select count(*) into v_bad
    from jsonb_array_elements(v_lines) as x
   where coalesce(jsonb_typeof(x -> 'debit'), 'null')     not in ('number', 'null')
      or coalesce(jsonb_typeof(x -> 'credit'), 'null')    not in ('number', 'null')
      or coalesce(jsonb_typeof(x -> 'fc_amount'), 'null') not in ('number', 'null');
  if v_bad > 0 then
    raise exception 'debit / credit / fc_amount raqam bo''lishi kerak' using errcode = '22000';
  end if;

  select count(*) into v_bad
    from jsonb_array_elements(v_lines) as x
   where nullif(x ->> 'account_id', '') is null
      or (x ->> 'account_id') !~ '^[0-9a-fA-F-]{36}$';
  if v_bad > 0 then
    raise exception 'Har satrda hisob (account_id) bo''lishi kerak' using errcode = '22000';
  end if;

  -- ---- 4. Manfiy yo'q -----------------------------------------------
  select count(*) into v_bad
    from jsonb_array_elements(v_lines) as x
   where coalesce((x ->> 'debit')::numeric, 0)  < 0
      or coalesce((x ->> 'credit')::numeric, 0) < 0;
  if v_bad > 0 then
    raise exception 'Summa manfiy bo''lishi mumkin emas' using errcode = '22000';
  end if;

  -- ---- 5. Bir satrda faqat BITTASI musbat ---------------------------
  select count(*) into v_bad
    from jsonb_array_elements(v_lines) as x
   where (coalesce((x ->> 'debit')::numeric, 0)  > 0
      and coalesce((x ->> 'credit')::numeric, 0) > 0)
      or (coalesce((x ->> 'debit')::numeric, 0)  = 0
     and  coalesce((x ->> 'credit')::numeric, 0) = 0);
  if v_bad > 0 then
    raise exception 'Har satrda Dt yoki Kt dan faqat bittasi musbat bo''lishi kerak' using errcode = '22000';
  end if;

  -- ---- 6. Dt = Kt ----------------------------------------------------
  -- `check_entry_balanced` DEFERRED (COMMIT paytida ishlaydi) va uning
  -- xatosi tushunarsiz bo'ladi — shuning uchun o'zimiz oldindan tekshiramiz.
  select coalesce(sum((x ->> 'debit')::numeric), 0),
         coalesce(sum((x ->> 'credit')::numeric), 0)
    into v_dt, v_kt
    from jsonb_array_elements(v_lines) as x;
  if v_dt <= 0 then
    raise exception 'Yozuv summasi noldan katta bo''lishi kerak' using errcode = '22000';
  end if;
  if v_dt <> v_kt then
    raise exception 'Dt va Kt teng emas: Dt=% Kt=%', v_dt, v_kt using errcode = '22000';
  end if;

  -- ---- 7. Yuk taqsimoti turi (agar berilgan bo'lsa) ------------------
  if v_yuk is not null and jsonb_typeof(v_yuk) = 'array' and jsonb_array_length(v_yuk) > 0 then
    select count(*) into v_bad
      from jsonb_array_elements(v_yuk) as x
     where coalesce(jsonb_typeof(x -> 'yuk_id'), 'null')    <> 'number'
        or coalesce(jsonb_typeof(x -> 'summa_uzs'), 'null') <> 'number';
    if v_bad > 0 then
      raise exception 'yuk_taqsim: yuk_id va summa_uzs raqam bo''lishi kerak' using errcode = '22000';
    end if;
  end if;

  -- ---- 8. Sarlavha ---------------------------------------------------
  -- `created_by` ATAYLAB berilmaydi: uni `trg_entry_ijrochi` (BEFORE INSERT)
  -- `auth.uid()` dan o'zi to'ldiradi (PROVODKA_IJROCHI.sql).
  insert into entry (entry_date, description, source, status,
                     filial_ids, davr_start, davr_end, kommunal_turi,
                     fc_rate, yuk_ids, yuk_kutilmoqda, ext_ref)
  values (
    nullif(p_data ->> 'entry_date', '')::date,
    nullif(p_data ->> 'description', ''),
    coalesce(nullif(p_data ->> 'source', ''), 'manual'),
    coalesce(nullif(p_data ->> 'status', ''), 'posted'),
    case when jsonb_typeof(p_data -> 'filial_ids') = 'array'
         then coalesce((select array_agg(t.val::uuid)
                          from jsonb_array_elements_text(p_data -> 'filial_ids') as t(val)),
                       '{}'::uuid[])
         else '{}'::uuid[] end,
    nullif(p_data ->> 'davr_start', '')::date,
    nullif(p_data ->> 'davr_end', '')::date,
    nullif(p_data ->> 'kommunal_turi', ''),
    nullif(p_data ->> 'fc_rate', '')::numeric,
    case when jsonb_typeof(p_data -> 'yuk_ids') = 'array'
         then coalesce((select array_agg(t.val::integer)
                          from jsonb_array_elements_text(p_data -> 'yuk_ids') as t(val)),
                       '{}'::integer[])
         else '{}'::integer[] end,
    coalesce(nullif(p_data ->> 'yuk_kutilmoqda', '')::boolean, false),
    v_ext
  )
  returning id into v_entry;

  -- ---- 9. Satrlar (BITTA statement, kelgan tartibda) -----------------
  -- fc_amount FAQAT berilgan satrga yoziladi (valyuta hisobi satri);
  -- berilmasa null qoladi — bugungi klient mantiqi bilan bir xil.
  insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
  select v_entry,
         (t.x ->> 'account_id')::uuid,
         coalesce((t.x ->> 'debit')::numeric, 0),
         coalesce((t.x ->> 'credit')::numeric, 0),
         nullif(t.x ->> 'fc_amount', '')::numeric
    from jsonb_array_elements(v_lines) with ordinality as t(x, ord)
   order by t.ord;

  -- ---- 10. Yuk taqsimoti (entry_yuk) ---------------------------------
  -- Bugungi klientdagi filtr bilan bir xil: summa 0 bo'lgan qator yozilmaydi
  -- (jadvalda `check (summa_uzs > 0)` bor).
  if v_yuk is not null and jsonb_typeof(v_yuk) = 'array' and jsonb_array_length(v_yuk) > 0 then
    insert into entry_yuk (entry_id, yuk_id, summa_uzs)
    select v_entry,
           (x ->> 'yuk_id')::integer,
           (x ->> 'summa_uzs')::numeric
      from jsonb_array_elements(v_yuk) as x
     where (x ->> 'summa_uzs')::numeric > 0;
    get diagnostics v_yn = row_count;
  end if;

  return jsonb_build_object('ok', true,
                            'entry_id', v_entry,
                            'satr', v_n,
                            'yuk', v_yn);

-- 🔴 FAQAT `unique_violation` ushlanadi. `when others` ATAYLAB YO'Q:
--    trigger/RLS xatosi (42501 va h.k.) klientga O'Z KODI va O'Z MATNI
--    bilan yetib borishi SHART — aks holda bugalter nima qilishni bilmaydi.
exception
  when unique_violation then
    -- Token yuborilmagan bo'lsa bu bizning to'siq EMAS (boshqa unique
    -- cheklov buzilgan) — xatoni AYNAN o'zgartirmasdan qaytaramiz.
    if v_ext is null then
      raise;
    end if;
    -- Funksiya tranzaksiya bo'lgani uchun bu yerga yetganda BU URINISHDAN
    -- hech narsa yozilmagan. Ya'ni "23505 = allaqachon saqlangan" xulosasi
    -- bu yo'lda ISHONCHLI (eski ikki qadamli yo'lda u xato edi — o'sha yerda
    -- 23505 yetim sarlavha ustiga ham tushishi mumkin edi).
    raise exception 'Bu xarajat allaqachon saqlangan (takroriy yuborish tosildi)'
      using errcode = '23505';
end $fn$;


-- #####################################################################
-- ##  2-BO'LIM — huquqlar + izoh                                     ##
-- #####################################################################
revoke all on function provodka_yoz(jsonb) from public, anon;
grant execute on function provodka_yoz(jsonb) to authenticated;

comment on function provodka_yoz(jsonb) is
  'Provodkani ATOMIK yozadi: entry + entry_line (+ entry_yuk) bitta tranzaksiyada. '
  'security INVOKER — RLS va entry_line triggerlari (perm guard, limit guard, notify) '
  'bugungidek ishlaydi. Rad etilsa hech narsa yozilmaydi (yetim sarlavha tug''ilmaydi). '
  'ext_ref berilsa takror yuborish 23505 bilan to''siladi. lock_timeout = 5s.';


-- #####################################################################
-- ##  3-BO'LIM — RUN dan KEYIN tekshiruv                             ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 3.1  Funksiya bormi, INVOKER mi, search_path o'rnatilganmi.
--      Kutilgan: bor=true, security_definer=false,
--                proconfig = {search_path=public}
--      🔴 security_definer = true chiqsa — YO'L QO'YILMAYDI, rollback qiling.
-- ---------------------------------------------------------------------
select p.proname,
       pg_get_function_identity_arguments(p.oid) as argumentlar,
       p.prosecdef                               as security_definer,
       p.proconfig,
       l.lanname                                 as til,
       pg_get_function_result(p.oid)             as qaytishi
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_language  l on l.oid = p.prolang
 where n.nspname = 'public' and p.proname = 'provodka_yoz';

-- ---------------------------------------------------------------------
-- 3.2  Huquqlar. Kutilgan: authenticated=EXECUTE bor, anon=YO'Q,
--      PUBLIC=YO'Q.
-- ---------------------------------------------------------------------
select r.rolname,
       has_function_privilege(r.rolname, 'public.provodka_yoz(jsonb)', 'EXECUTE') as execute_bor
  from pg_roles r
 where r.rolname in ('anon', 'authenticated', 'service_role')
 order by r.rolname;

-- ---------------------------------------------------------------------
-- 3.3  Yetim sarlavhalar soni — 0.5 dagi bilan BIR XIL bo'lishi kerak
--      (bu fayl eskilarini tozalamaydi, faqat yangisini tug'dirmaydi).
-- ---------------------------------------------------------------------
select count(*) as yetim_sarlavha
  from entry e
 where not exists (select 1 from entry_line l where l.entry_id = e.id);

-- ---------------------------------------------------------------------
-- 3.4  🔴 QO'LDA SINOV (Asilbek, brauzerda — SQL editorda EMAS)
--      SQL editorda `auth.uid()` null bo'lgani uchun perm guard boshqacha
--      yo'l tutadi va sinov haqiqatni ko'rsatmaydi. Shuning uchun bu yerda
--      JONLI RPC chaqiruvi ATAYLAB YOZILMAGAN.
--
--      Brauzerda tekshiriladigan holatlar:
--        1) provodka-dev.html — kirim / chiqim / transfer saqlansin.
--        2) professional-dev.html — oddiy rejim, kengaytirilgan rejim,
--           yo'ldagi tovar (9110-1), yuk taqsimoti bilan.
--        3) Ruxsati yo'q kassa tanlangan holat: 42501 xatosi ko'rinsin VA
--           3.3 dagi son ORTMASIN (yetim qolmasin) — eng muhim sinov.
--        4) Dt<>Kt (kengaytirilgan rejimda) — klient o'zi to'sadi, lekin
--           server ham "Dt va Kt teng emas" deb rad etishi kerak.
-- ---------------------------------------------------------------------


-- #####################################################################
-- ##  4-BO'LIM — ROLLBACK                                            ##
-- #####################################################################
-- Funksiyani olib tashlash. Klient buni O'ZI ko'taradi: RPC topilmasa
-- (PGRST202 / 42883) eski ikki qadamli yo'lga qaytadi, ya'ni sahifalar
-- ishlayveradi (yetim muammosi ham qaytadi).
-- ⚠️ Boshqa hech narsa qaytarilmaydi — bu fayl faqat qo'shgan.
--
--   drop function if exists provodka_yoz(jsonb);
--
-- PostgREST sxema keshi: Supabase o'zi yangilaydi, kerak bo'lsa
--   notify pgrst, 'reload schema';
-- ---------------------------------------------------------------------


-- #####################################################################
-- ##  5-BO'LIM — KLIENT KONTRAKTI (provodka-dev / professional-dev)  ##
-- #####################################################################
-- Chaqiruv:
--     const {data, error} = await sb.rpc('provodka_yoz', { p_data });
--
-- p_data misoli (provodka-dev.html, chiqim):
--     {
--       entry_date: '2026-08-25',
--       description: 'Kanselyariya',
--       source: 'manual',
--       status: 'posted',
--       ext_ref: '<uuid>',
--       lines: [
--         { account_id: '<modda uuid>', debit: 120000, credit: 0 },
--         { account_id: '<kassa uuid>', debit: 0, credit: 120000 }
--       ]
--     }
--
-- Javob tahlili (klientda AYNAN shu tartib):
--   1) error.code === 'PGRST202' | '42883'  -> RPC yo'q (bu fayl hali RUN
--      qilinmagan) -> ESKI ikki qadamli yo'l (zaxira).
--   2) error.code === '23505'               -> allaqachon saqlangan
--      (atomik bo'lgani uchun bu xulosa ishonchli) -> muvaffaqiyat kabi.
--   3) error                                 -> permErr(error) bilan ko'rsat.
--   4) data.entry_id                         -> chek/fayl biriktirish uchun.
--
-- 🔴 RPC yo'lida kompensatsiya `delete` QILINMAYDI — atomik.
-- 🔴 ext_ref: har saqlashda bir martalik `crypto.randomUUID()`. Timeout
--    bo'lsa AYNI token saqlanadi va qayta bosilganda o'sha token ketadi —
--    server ikkinchi nusxani 23505 bilan to'sadi.
-- =====================================================================
