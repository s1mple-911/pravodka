-- =====================================================================
--  ⚠️⚠️  SUPABASE SQL EDITOR — QANDAY RUN QILINADI (avval SHUNI o'qing)
-- ---------------------------------------------------------------------
--   1) Har bo'lak ⬇⬇⬇ va ⬆⬆⬆ belgilari orasida. AYNAN o'sha oraliqni
--      belgilab RUN qiling. Tartib bilan: 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7.
--
--   2) 🔴 BUTUN FAYLNI BIRDANIGA RUN QILISH TAVSIYA ETILMAYDI: 5- va
--      6-BO'LIM nomuvofiqlikda `raise exception` qiladi, va editor butun
--      skriptni bitta tranzaksiyada yuborsa 1–4-BO'LIMlar ham QAYTIB
--      KETADI (funksiyalar yaratilmay qoladi). Bo'lak-bo'lak RUN qilsangiz
--      — o'rnatish o'rnida qoladi, faqat sinov qizil beradi.
--
--   3) Bo'lak diapazonlari:
--        0-BO'LIM — old shart tekshiruvi (HECH NARSA YOZMAYDI, faqat select)
--        1-BO'LIM — ai_ctx_perm() + ai_ctx_has_page() — ichki ruxsat yadrosi
--        2-BO'LIM — ai_ctx_kassa()      — kassa qoldiqlari
--        3-BO'LIM — ai_ctx_qarzdor()    — debitor / kreditor
--        4-BO'LIM — ai_ctx_transfer()   — davr ichidagi transferlar
--        5-BO'LIM — STATIK TEKSHIRUV (do bloki, nomuvofiqlikda exception)
--        6-BO'LIM — 🔴 TIRIK SIZISH SINOVI (cheklangan user vs admin)
--        7-BO'LIM — notify pgrst (PostgREST sxema keshini yangilash)
--        8-BO'LIM — ROLLBACK (izohda, qo'lda ishlatiladi)
--        9-BO'LIM — EDGE FUNCTION UCHUN SHARTNOMA (faqat izoh)
--
--   4) 🔴 SQL ni ASILBEK o'zi RUN qiladi. Agent bajarmaydi.
--
--   5) Fayl kimning nomidan RUN qilinsa, funksiyalar EGASI ham o'sha rol
--      bo'ladi (SECURITY DEFINER shu roldan ishlaydi). Supabase SQL
--      Editor'da bu `postgres` — u `user_perms` / `accounts` / `entry` ni
--      o'qiy oladi va RLS'ni chetlab o'tadi, ya'ni filtrlash TO'LIQ shu
--      fayldagi mantiqqa bog'liq. Boshqa roldan RUN QILMANG.
-- =====================================================================

-- =====================================================================
--  PROVODKA_AI_KONTEKST.sql
--  AI agentga Provodka ma'lumoti — XAVFSIZ RPC qatlami (4-bosqich, 4-ish)
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  #####  NIMA QILADI  #################################################
--
--  BRIEF_PROVODKA_AI_4.md 4-band: AI "Yunusobod kassada qancha pul bor?"
--  degan savolga javob bersin — LEKIN faqat foydalanuvchi ko'ra oladigan
--  kassalar bo'yicha. Bu fayl Edge Function uchun 3 ta o'qish RPC beradi:
--
--     ai_ctx_kassa()                    -> kassa qoldiqlari (ruxsatdagilar)
--     ai_ctx_qarzdor()                  -> debitor 4010 / kreditor 6010
--     ai_ctx_transfer(p_from, p_to)     -> davr ichidagi transferlar
--
--  #####  🔴 NEGA MIJOZ FILTRI YETARLI EMAS  ###########################
--
--  Hozirgi tizimda kassa ro'yxati MIJOZDA filtrlanadi (perms.js ->
--  permFilterView). `v_kassa_card` ning o'zi esa `security_invoker` view
--  bo'lsa ham har `authenticated` uchun HAMMA kassani beradi — RLS bilan
--  kassa darajasida cheklanmagan. Ya'ni Edge Function o'sha view'ni
--  to'g'ridan o'qib Claude'ga bersa — BOSHQA FILIALNING PULI SIZADI.
--  Shuning uchun filtr SERVERDA, aynan shu funksiyalar ichida.
--
--  #####  🔴 5 TA QAT'IY QOIDA (hammasiga tegishli)  ###################
--
--   1) FOYDALANUVCHI ID ARGUMENTI YO'Q. Kim so'rayotgani faqat
--      `auth.uid()` dan olinadi. (TaskFix'dagi `can_see_project` saboqi:
--      parametrli funksiya PostgREST `/rpc/...` orqali begona id bilan
--      chaqirilardi va o'zganing ma'lumotini berardi.)
--
--   2) `auth.uid()` NULL (service_role, n8n, SQL editor) -> BO'SH natija,
--      "hammasi" EMAS. Bu funksiyalar AI uchun; ular hech qachon
--      cheklanmagan ko'rinish bermasin. ⚠️ Diqqat: mavjud
--      `perm_check_accounts()` / `perm_has_page()` teskari ishlaydi
--      (uid null -> true), chunki ular n8n sinxronini o'tkazishi kerak.
--      Bu yerda o'sha naqsh ATAYLAB TAKRORLANMAYDI.
--
--   3) Ruxsat: is_admin() -> hammasi; aks holda user_perms.kassa_scope
--      = 'all' -> hammasi; = 'list' -> faqat `view_kassa_ids`.
--      user_perms QATORI YO'Q -> `my_perms()` bilan bir xil, ya'ni
--      kassa_scope='all' (PROVODKA_PAGES_EMPTY.sql 3-BO'LIM: qatorsiz
--      userga allowed_pages [] lekin kassa_scope 'all' qaytadi).
--      Ya'ni "qatorsiz user hamma KASSANI ko'radi, lekin hech qanday
--      SAHIFAGA ruxsati yo'q" — farq shu, quyida ham aynan shunday.
--
--   ⚠️ `view_kassa_ids` ISHLATILADI, `op_kassa_ids` EMAS.
--      Brief 4-bandda "op_kassa_ids" deb yozilgan, lekin semantika bo'yicha:
--         op_*   = AMALIYOT qilish (pul yozish) huquqi
--         view_* = KO'RISH huquqi
--      AI faqat O'QIYDI, hech narsa yozmaydi -> to'g'ri kalit `view_kassa_ids`.
--      Qo'shimcha: `admin_set_provodka_perms()` `op ⊆ view` ni majburlaydi,
--      ya'ni view kengroq to'plam — op bilan filtrlash foydalanuvchidan
--      O'ZI KO'RA OLADIGAN kassani yashirib qo'yardi (UI ko'rsatadi, AI
--      "bilmayman" deydi — ziddiyat).
--
--   4) BOLA-HISOBLAR (valyuta 56xx/57xx va pul turi naqd/click/payme)
--      ruxsatni PARENT kassadan oladi — `perm_op_key()` / `kassa_root()`
--      bilan AYNAN bir xil qoida (parent_id + (currency <> 'UZS' YOKI
--      pul_turi is not null)). Mijozdagi `keyOf()` ham shunday. Aks holda
--      AI mijoz yashirgan hisobni ko'rsatib qo'yardi.
--
--   5) Har RPC qator sonini CHEKLAYDI (kassa 60, qarzdor 20, transfer 50)
--      — AI kontekstiga butun baza tushmasin (token narxi + sekinlik).
--
--  #####  🔴 PUL HARAKATI YO'Q  ########################################
--
--  Uchala RPC ham FAQAT SELECT. `entry` / `entry_line` ga bitta qator ham
--  yozilmaydi: balans, P&L, cashflow raqamlari O'ZGARMAYDI. Dt=Kt triggeri
--  va `trg_perm_guard_entry_line` guardi bu yerda ishtirok etmaydi.
--
--  #####  ADDITIVE  ####################################################
--
--  Mavjud jadval / ustun / view / funksiya / policy / trigger
--  O'ZGARTIRILMAYDI. Faqat YANGI funksiyalar:
--     ai_ctx_perm()                 (ichki — ruxsat yadrosi)
--     ai_ctx_has_page(text)         (ichki — fail-CLOSED sahifa tekshiruvi)
--     ai_ctx_kassa()
--     ai_ctx_qarzdor()
--     ai_ctx_transfer(date, date)
--  `perm_pages()`, `my_perms()`, `perm_op_key()`, `v_kassa_card` —
--  TEGILMAYDI. Idempotent: hammasi `create or replace`, qayta RUN xavfsiz.
--
--  TALAB (0-BO'LIM tekshiradi):
--     PROVODKA_PERMS.sql        — user_perms, perm_op_key, is_admin
--     PROVODKA_VALYUTA.sql      — v_kassa_card (tur bolalari bilan)
--     PROVODKA_PAGES_EMPTY.sql  — perm_has_page (bo'lmasa ham ishlaydi)
-- =====================================================================


-- #####################################################################
--  0-BO'LIM — OLD SHART TEKSHIRUVI.  HECH NARSA YOZMAYDI.
-- #####################################################################
--  ⚠️ Funksiyalar ATAYLAB CHAQIRILMAYDI (faqat mavjudligi tekshiriladi):
--     bazada bo'lmasa `case` shoxi baribir rejalashtiriladi va butun
--     select "function does not exist" bilan yiqilardi.

-- ⬇⬇⬇  0-BO'LIM  ⬇⬇⬇
select 'user_perms jadvali' as tekshiruv,
       case when to_regclass('public.user_perms') is not null
            then '✅ BOR — ruxsat shu yerdan oqiladi'
            else '❌ YO''Q — avval PROVODKA_PERMS.sql ni RUN qiling' end as natija
union all
select 'is_admin()',
       case when to_regprocedure('public.is_admin()') is not null
            then '✅ BOR — admin hech qachon cheklanmaydi'
            else '❌ YO''Q — bu fayl uni chaqiradi, RUN qilinmaydi' end
union all
select 'perm_op_key(uuid)',
       case when to_regprocedure('public.perm_op_key(uuid)') is not null
            then '✅ BOR — bola-hisob ruxsati parentdan olinadi'
            else '❌ YO''Q — avval PROVODKA_PERMS.sql ni RUN qiling' end
union all
select 'kassa_root(uuid)',
       case when to_regprocedure('public.kassa_root(uuid)') is not null
            then '✅ BOR — perm_op_key odatda shunga delegat qiladi'
            else '⚠️ YO''Q — muhim emas: bu fayl faqat perm_op_key ni chaqiradi' end
union all
-- 🔴 perm_op_key ning VERSIYASI: eski versiya faqat `currency <> UZS` ni
--    biladi, pul turi bolalarini (naqd/click/payme) esa MUSTAQIL hisob deb
--    qaraydi. Bu bizda FAIL-CLOSED: bunday bola `view_kassa_ids` da
--    bo'lmagani uchun transferlarda "ruxsat yoq" deb YASHIRINADI — ya'ni
--    hech narsa sizmaydi, faqat ortiqcha yashiriladi. Baribir yangilash
--    tavsiya etiladi (PROVODKA_PERM_TUR_FIX.sql).
select 'perm_op_key pul_turi ni biladimi',
       case when to_regprocedure('public.perm_op_key(uuid)') is null
            then '❌ perm_op_key YO''Q'
            when exists (select 1 from pg_proc
                          where oid = to_regprocedure('public.perm_op_key(uuid)')::oid
                            and (prosrc like '%pul_turi%' or prosrc like '%kassa_root%'))
            then '✅ HA — tur bolalari parent kassadan meros oladi'
            else '⚠️ YO''Q (eski versiya) — tur bolalari transferda yashirinadi (fail-closed, sizish yoq). PROVODKA_PERM_TUR_FIX.sql ni RUN qiling' end
union all
select 'v_kassa_card',
       case when to_regclass('public.v_kassa_card') is not null
            then '✅ BOR — ai_ctx_kassa() shundan oqiydi'
            else '❌ YO''Q — avval PROVODKA_VALYUTA.sql / KASSA2.sql ni RUN qiling' end
union all
select 'perm_has_page(text)',
       case when to_regprocedure('public.perm_has_page(text)') is not null
            then '✅ BOR — ai_ctx_has_page ikkinchi qavat sifatida chaqiradi'
            else '⚠️ YO''Q — bu fayl baribir ishlaydi: sahifa tekshiruvi user_perms.allowed_pages dan fail-CLOSED oqiladi' end
union all
select 'entry / entry_line / accounts',
       case when to_regclass('public.entry') is not null
             and to_regclass('public.entry_line') is not null
             and to_regclass('public.accounts') is not null
            then '✅ BOR — qarzdor va transfer shulardan hisoblanadi'
            else '❌ YO''Q — bu Provodka bazasi emasmi?' end
union all
select 'auth.uid()',
       case when to_regprocedure('auth.uid()') is not null
            then '✅ BOR — butun xavfsizlik shunga tayanadi'
            else '❌ YO''Q — bu Supabase bazasi emasmi?' end;

-- 0.2 Bu fayl ilgari RUN qilinganmi (yangi o'rnatishda hammasi "yo'q")
select 'ai_ctx_perm()'              as obyekt,
       case when to_regprocedure('public.ai_ctx_perm()') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end as holat
union all
select 'ai_ctx_has_page(text)',
       case when to_regprocedure('public.ai_ctx_has_page(text)') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end
union all
select 'ai_ctx_kassa()',
       case when to_regprocedure('public.ai_ctx_kassa()') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end
union all
select 'ai_ctx_qarzdor()',
       case when to_regprocedure('public.ai_ctx_qarzdor()') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end
union all
select 'ai_ctx_transfer(date,date)',
       case when to_regprocedure('public.ai_ctx_transfer(date,date)') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end;

-- 0.3 Sinov uchun material bormi (6-BO'LIM shularga tayanadi)
select 'admin foydalanuvchi' as tekshiruv,
       (select count(*) from profiles where role = 'admin')::text as soni,
       case when (select count(*) from profiles where role = 'admin') > 0
            then '✅ tirik sinov ishlaydi' else '⚠️ 6-BOLIM otkazib yuboriladi' end as natija
union all
select 'admin BO''LMAGAN foydalanuvchi',
       (select count(*) from profiles where coalesce(role,'user') <> 'admin')::text,
       case when (select count(*) from profiles where coalesce(role,'user') <> 'admin') > 0
            then '✅ tirik sinov ishlaydi' else '⚠️ 6-BOLIM otkazib yuboriladi' end
union all
select 'kassa (v_kassa_card, konteynersiz)',
       (select count(*)::text from v_kassa_card
         where coalesce(kassa_turi,'') <> 'xarajat_guruh'),
       case when (select count(*) from v_kassa_card
                   where coalesce(kassa_turi,'') <> 'xarajat_guruh') >= 2
            then '✅ kamida 2 ta kerak edi' else '⚠️ 6-BOLIM otkazib yuboriladi' end;
-- ⬆⬆⬆  0-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  1-BO'LIM — RUXSAT YADROSI (ichki yordamchilar)
-- #####################################################################
--  Uchala RPC ham ruxsatni AYNAN shu ikki funksiyadan oladi — mantiq
--  uch joyga ko'chirilmaydi (vaqt o'tib bir-biridan ajralib ketmasin).
--
--  🔴 IKKALASI HAM `authenticated` UCHUN YOPIQ. Ular faqat SECURITY
--     DEFINER RPC'lar ICHIDAN chaqiriladi — u yerda current_user egasi
--     bo'ladi va EXECUTE tekshiruvi egadan o'tadi. Ya'ni tashqi hujum
--     yuzasi kengaymaydi (PostgREST orqali chaqirib bo'lmaydi).

-- ⬇⬇⬇  1-BO'LIM: SHU QATORDAN 1-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇

-- 1.1 ai_ctx_perm — "men qaysi kassalarni KO'RA olaman"
--     rejim: 'yoq'   -> auth.uid() null (service_role/n8n/SQL editor) yoki umuman kirmagan
--            'admin' -> cheklov yo'q
--            'all'   -> kassa_scope='all' YOKI user_perms qatori yo'q (my_perms semantikasi)
--            'list'  -> faqat kassa_ids (= view_kassa_ids)
create or replace function ai_ctx_perm(out rejim text, out kassa_ids uuid[])
language plpgsql
stable
security definer
set search_path = public
as $ai_perm$
declare
  v_uid uuid;
  p     user_perms%rowtype;
begin
  -- Fail-CLOSED sukut: keyingi har bir `return` uni ataylab kengaytiradi.
  rejim     := 'yoq';
  kassa_ids := '{}'::uuid[];

  v_uid := auth.uid();
  if v_uid is null then
    return;                          -- 2-QOIDA: service_role -> bo'sh, "hammasi" EMAS
  end if;

  if is_admin() then
    rejim := 'admin';
    return;
  end if;

  select * into p from user_perms where user_id = v_uid;

  -- Qatori yo'q = my_perms() bilan bir xil: kassa_scope 'all'.
  -- (Sahifa ruxsati esa aksincha — ai_ctx_has_page da fail-CLOSED.)
  if not found then
    rejim := 'all';
    return;
  end if;

  if p.kassa_scope is distinct from 'list' then
    rejim := 'all';
    return;
  end if;

  rejim     := 'list';
  kassa_ids := coalesce(p.view_kassa_ids, '{}'::uuid[]);   -- bo'sh ro'yxat = hech narsa
end
$ai_perm$;

revoke all on function ai_ctx_perm() from public, anon, authenticated;

comment on function ai_ctx_perm() is
  'AI kontekst RPClari uchun ichki ruxsat yadrosi. rejim: yoq|admin|all|list, '
  'list uchun kassa_ids = user_perms.view_kassa_ids (op_ EMAS — AI faqat oqiydi). '
  'auth.uid() null bolsa yoq (bosh natija).';


-- 1.2 ai_ctx_has_page — sahifa ruxsati, FAIL-CLOSED
--     ⚠️ Mavjud `perm_has_page()` FAIL-OPEN: `auth.uid()` null bo'lsa yoki
--        kalit `perm_pages()` da bo'lmasa TRUE qaytaradi. AI uchun bu
--        yaramaydi — shuning uchun bu yerda avval O'Z tekshiruvimiz
--        (qatorsiz user -> false), keyin `perm_has_page()` bo'lsa u ham
--        rozi bo'lishi kerak (AND). AND faqat QATTIQROQ qila oladi.
create or replace function ai_ctx_has_page(p_key text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $ai_page$
declare
  v_uid   uuid;
  v_pages text[];
  v_ok    boolean;
begin
  v_uid := auth.uid();
  if v_uid is null then return false; end if;     -- 2-QOIDA
  if is_admin()     then return true;  end if;

  select allowed_pages into v_pages from user_perms where user_id = v_uid;
  if not found then return false; end if;         -- qatorsiz = sahifa ruxsati YO'Q
  if not (p_key = any(coalesce(v_pages, '{}'::text[]))) then return false; end if;

  -- Ikkinchi qavat (bo'lsa): perm_has_page ham rozi bo'lsin.
  -- ⚠️ Dinamik chaqiruv — funksiya yo'q bazada bu fayl baribir ishlasin.
  if to_regprocedure('public.perm_has_page(text)') is not null then
    execute 'select public.perm_has_page($1)' into v_ok using p_key;
    return coalesce(v_ok, false);
  end if;

  return true;
end
$ai_page$;

revoke all on function ai_ctx_has_page(text) from public, anon, authenticated;

comment on function ai_ctx_has_page(text) is
  'AI kontekst uchun sahifa ruxsati. FAIL-CLOSED (auth yoq / qator yoq -> false), '
  'perm_has_page() bilan AND. Faqat SECURITY DEFINER RPClar ichidan chaqiriladi.';
-- ⬆⬆⬆  1-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  2-BO'LIM — ai_ctx_kassa() — KASSA QOLDIQLARI
-- #####################################################################
--  Manba: `v_kassa_card` — kartalar uchun tayyor ko'rinish. Uning har
--  qatori ALLAQACHON parent kassa: valyuta bolalari (56xx USD…) va pul
--  turi bolalari (naqd/click/payme) alohida qator bo'lib chiqmaydi, ular
--  `jami` ichiga yig'ilgan. Ya'ni "bola-hisob alohida sizib chiqishi"
--  bu yerda strukturaviy jihatdan MUMKIN EMAS; `perm_op_key()` filtri
--  esa buni yana bir marta kafolatlaydi (parent qator uchun u o'z id'sini
--  qaytaradi, ya'ni filtr view_kassa_ids bilan to'g'ridan solishtiriladi).
--
--  `kassa_turi='xarajat_guruh'` (5400 konteyner) CHIQARIB TASHLANADI:
--  u karta emas, guruh sarlavhasi — unga pul yozilmaydi va AI uni
--  "kassa" deb o'qib chalkashtirardi. Hodim kassalari (5401+) esa
--  o'z qatorlari bilan qoladi.
--
--  Tartib: `jami desc` (eng katta pul tepada). Limit 60 — kesilsa
--  javobda `kesildi: true` bo'ladi, AI "hammasi shu" deb yolg'on
--  aytmasin.

-- ⬇⬇⬇  2-BO'LIM: SHU QATORDAN 2-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function ai_ctx_kassa()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ai_kassa$
declare
  v_limit constant int := 60;
  v_rejim text;
  v_ids   uuid[];
  v_rows  jsonb;
  v_n     int;
  v_jami  numeric;
begin
  -- 1-qavat: o'z qorovuli (2-QOIDA). 5-BO'LIM aynan shu qatorni qidiradi.
  if auth.uid() is null then
    return jsonb_build_object(
      'ok',    false,
      'sabab', 'Avtorizatsiya yoq: bu RPC foydalanuvchi JWT si bilan chaqirilishi kerak (service_role bilan EMAS)',
      'ruxsat', 'yoq', 'kassa_soni', 0, 'kassalar', '[]'::jsonb);
  end if;

  -- 2-qavat: yagona ruxsat yadrosi
  select rejim, kassa_ids into v_rejim, v_ids from ai_ctx_perm();
  if v_rejim = 'yoq' then
    return jsonb_build_object(
      'ok',    false,
      'sabab', 'Avtorizatsiya yoq',
      'ruxsat', 'yoq', 'kassa_soni', 0, 'kassalar', '[]'::jsonb);
  end if;

  /* 🔴 3-qavat: SAHIFA QOROVULI (Asilbek qarori 2026-08-14).
     Avval faqat kassa darajasidagi filtr bor edi. Natijada `allowed_pages`
     da faqat 'ai' bo'lgan va `kassa_scope='all'` (YANGI userlarda DEFAULT)
     foydalanuvchi `kassa.html` ni ocholmasa ham (UI "Ruxsat yo'q"), AI orqali
     HAMMA filial qoldig'ini olardi. Endi UI bilan izchil. */
  if not ai_ctx_has_page('kassa') then
    return jsonb_build_object(
      'ok',    false,
      'sabab', 'Kassa sahifasi ruxsatingizda yoq',
      'ruxsat', 'yoq', 'kassa_soni', 0, 'kassalar', '[]'::jsonb);
  end if;

  with k as (
    select c.code,
           c.name,
           coalesce(c.kassa_turi, '-')   as kassa_turi,
           round(coalesce(c.uzs,  0))    as uzs,      -- so'mdagi qoldiq (parent hisob)
           round(coalesce(c.usd,  0), 2) as usd,      -- dollar miqdori (USD bolasi)
           round(coalesce(c.jami, 0))    as jami      -- o'zi + valyuta + tur bolalari
      from v_kassa_card c
     where coalesce(c.kassa_turi, '') <> 'xarajat_guruh'
       -- 🔴 SIZISH QOROVULI: cheklangan userga faqat view_kassa_ids
       and (v_rejim <> 'list' or perm_op_key(c.id) = any(v_ids))
     order by coalesce(c.jami, 0) desc, c.code
     limit v_limit
  )
  select coalesce(jsonb_agg(to_jsonb(k) order by k.jami desc, k.code), '[]'::jsonb),
         count(*),
         coalesce(sum(k.jami), 0)
    into v_rows, v_n, v_jami
    from k;

  return jsonb_build_object(
    'ok',          true,
    'ruxsat',      v_rejim,
    'sana',        to_char(now() at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI'),
    'kassa_soni',  v_n,
    'kesildi',     v_n >= v_limit,
    'jami_uzs',    v_jami,
    'izoh',        'Faqat foydalanuvchi KORA OLADIGAN kassalar. jami = som qoldigi + valyuta bolalari + naqd/click/payme bolalari. usd — dollar miqdori (jami ichida som ekvivalenti bilan turadi).',
    'kassalar',    v_rows);
end
$ai_kassa$;

revoke all on function ai_ctx_kassa() from public, anon;
grant execute on function ai_ctx_kassa() to authenticated;

comment on function ai_ctx_kassa() is
  'AI kontekst: kassa qoldiqlari, FAQAT foydalanuvchi kora oladigan kassalar '
  '(user_perms.view_kassa_ids, bola-hisoblar parentdan meros). Limit 60, jami desc. '
  'auth.uid() null -> bosh natija.';
-- ⬆⬆⬆  2-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  3-BO'LIM — ai_ctx_qarzdor() — DEBITOR (4010) / KREDITOR (6010)
-- #####################################################################
--  ⚠️ Bu KASSA ruxsatiga bog'liq emas — qarzdorlik kassa emas, hisob
--     qoldig'i. Shuning uchun qorovul boshqa: `allowed_pages` ichida
--     'qarzdor' bormi (`ai_ctx_has_page`). Tamoyil bir xil: AI sahifa
--     ruxsati yo'q ma'lumotni bermasin.
--
--  Hisoblash `entry_line` dan, `status='posted' and is_deleted=false`
--  (CLAUDE.md: balans faqat shu yozuvlardan). `code like '4010%'` —
--  kelajakda sub-hisoblar (4010.1 …) ochilsa ular ham qamrab olinsin.
--
--  Belgilar: debitor = Dt − Kt (bizga qarzdor), kreditor = Kt − Dt
--  (biz qarzdormiz). IKKALASI HAM MUSBAT ko'rinadi — `qarzdor.html`
--  dagi ikki karta bilan bir xil o'qiladi.
--
--  "Eng katta 20 qator" = summasi bo'yicha eng yirik 20 ta SATR
--  (kim bilan ekani `description` da — Provodka'da qarzdor uchun
--  alohida kontragent jadvali yo'q).

-- ⬇⬇⬇  3-BO'LIM: SHU QATORDAN 3-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function ai_ctx_qarzdor()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ai_qarz$
declare
  v_limit constant int := 20;
  v_deb   numeric;
  v_kre   numeric;
  v_rows  jsonb;
  v_n     int;
begin
  if auth.uid() is null then
    return jsonb_build_object(
      'ok',    false,
      'sabab', 'Avtorizatsiya yoq: bu RPC foydalanuvchi JWT si bilan chaqirilishi kerak (service_role bilan EMAS)',
      'ruxsat', false, 'debitor_4010', null, 'kreditor_6010', null,
      'qator_soni', 0, 'qatorlar', '[]'::jsonb);
  end if;

  -- 🔴 SAHIFA QOROVULI (fail-closed)
  if not ai_ctx_has_page('qarzdor') then
    return jsonb_build_object(
      'ok',    false,
      'sabab', 'Qarzdorlar sahifasi ruxsatingizda yoq',
      'ruxsat', false, 'debitor_4010', null, 'kreditor_6010', null,
      'qator_soni', 0, 'qatorlar', '[]'::jsonb);
  end if;

  select round(coalesce(sum(l.debit - l.credit) filter (where a.code like '4010%'), 0)),
         round(coalesce(sum(l.credit - l.debit) filter (where a.code like '6010%'), 0))
    into v_deb, v_kre
    from entry_line l
    join entry    e on e.id = l.entry_id
    join accounts a on a.id = l.account_id
   where e.status = 'posted'
     and e.is_deleted = false
     and (a.code like '4010%' or a.code like '6010%');

  with q as (
    select e.entry_date                                            as sana,
           a.code                                                  as kod,
           a.name                                                  as hisob,
           case when a.code like '4010%' then 'debitor' else 'kreditor' end as tomon,
           case when l.debit > 0 then 'Dt' else 'Kt' end           as yonalish,
           round(greatest(l.debit, l.credit))                      as summa,
           left(coalesce(e.description, ''), 120)                  as izoh
      from entry_line l
      join entry    e on e.id = l.entry_id
      join accounts a on a.id = l.account_id
     where e.status = 'posted'
       and e.is_deleted = false
       and (a.code like '4010%' or a.code like '6010%')
       and greatest(l.debit, l.credit) > 0
     order by greatest(l.debit, l.credit) desc, e.entry_date desc
     limit v_limit
  )
  select coalesce(jsonb_agg(to_jsonb(q) order by q.summa desc), '[]'::jsonb), count(*)
    into v_rows, v_n
    from q;

  return jsonb_build_object(
    'ok',           true,
    'ruxsat',       true,
    'sana',         to_char(now() at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI'),
    'debitor_4010', v_deb,
    'kreditor_6010', v_kre,
    'qator_soni',   v_n,
    'kesildi',      v_n >= v_limit,
    'izoh',         'Daftar qoldigi: 4010 bizga qarzdor, 6010 biz qarzdormiz — ikkalasi ham musbat. Faqat posted va ochirilmagan yozuvlardan. Qatorlar — summasi boyicha eng yirik 20 ta satr.',
    'qatorlar',     v_rows);
end
$ai_qarz$;

revoke all on function ai_ctx_qarzdor() from public, anon;
grant execute on function ai_ctx_qarzdor() to authenticated;

comment on function ai_ctx_qarzdor() is
  'AI kontekst: debitor (4010) / kreditor (6010) jamlanma + eng katta 20 satr. '
  'Qorovul — allowed_pages ichida qarzdor (fail-closed). auth.uid() null -> bosh natija.';
-- ⬆⬆⬆  3-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  4-BO'LIM — ai_ctx_transfer(p_from, p_to) — KASSALARARO HARAKAT
-- #####################################################################
--  Transfer ta'rifi CLAUDE.md dagi jurnal tasnifi bilan bir xil:
--  Dt `section='pul'` VA Kt `section='pul'` (kod prefiksi bilan EMAS).
--
--  ⚠️ FAQAT AYNAN 2 SATRLI yozuvlar. Sabab: ko'p satrli professional
--     yozuvda "kimdan -> kimga" juftligi aniq emas, dekart ko'paytma
--     chiqadi va AI ga soxta juftliklar ketardi. Bu ataylab qilingan
--     cheklov, javobda `izoh` da ochiq yozilgan.
--
--  🔴 RUXSAT — "kamida bir tomon meniki, ikkinchi tomon YASHIRIN":
--     • ikkala tomon ham ruxsatdan tashqarida -> qator UMUMAN chiqmaydi;
--     • bir tomon meniki -> qator chiqadi, LEKIN begona tomonning
--       kodi/nomi 'ruxsat yoq' bilan almashtiriladi va `izoh` ham
--       o'chiriladi (izohda odatda "Sergeli -> Toshkent" deb kassa nomi
--       turadi — busiz nom aynan o'sha yerdan sizardi);
--     • ikkalasi ham meniki -> to'liq ko'rinadi.
--     Summa ko'rinadi, chunki u MENING kassamdan chiqqan/kirgan pul —
--     uni bilishga haqim bor; sir bo'lgani — narigi tomonning kimligi.
--
--  Sana oralig'i MAJBURIY cheklanadi: eng ko'pi 92 kun. Oshsa xato
--  BERILMAYDI — `p_from` qisqartiriladi va javobda
--  `davr.qisqartirildi = true` bo'ladi (AI noto'g'ri davr haqida
--  yolg'on xulosa chiqarmasin). Argument berilmasa: oxirgi 30 kun.

-- ⬇⬇⬇  4-BO'LIM: SHU QATORDAN 4-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function ai_ctx_transfer(p_from date default null,
                                           p_to   date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ai_tr$
declare
  v_limit   constant int := 50;
  v_max_kun constant int := 92;
  v_rejim text;
  v_ids   uuid[];
  v_from  date;
  v_to    date;
  v_tmp   date;
  v_qisqa boolean := false;
  v_rows  jsonb;
  v_n     int;
  v_jami  numeric;
begin
  if auth.uid() is null then
    return jsonb_build_object(
      'ok',    false,
      'sabab', 'Avtorizatsiya yoq: bu RPC foydalanuvchi JWT si bilan chaqirilishi kerak (service_role bilan EMAS)',
      'ruxsat', 'yoq', 'soni', 0, 'transferlar', '[]'::jsonb);
  end if;

  select rejim, kassa_ids into v_rejim, v_ids from ai_ctx_perm();
  if v_rejim = 'yoq' then
    return jsonb_build_object(
      'ok',    false,
      'sabab', 'Avtorizatsiya yoq',
      'ruxsat', 'yoq', 'soni', 0, 'transferlar', '[]'::jsonb);
  end if;

  /* 🔴 SAHIFA QOROVULI (Asilbek qarori 2026-08-14) — `ai_ctx_kassa` dagi
     bilan bir xil sabab. Transferlar jurnalda ko'rinadi, shuning uchun
     kalit — 'jurnal'. */
  if not ai_ctx_has_page('jurnal') then
    return jsonb_build_object(
      'ok',    false,
      'sabab', 'Jurnal sahifasi ruxsatingizda yoq',
      'ruxsat', 'yoq', 'soni', 0, 'transferlar', '[]'::jsonb);
  end if;

  -- --- Davr: Toshkent kuni bo'yicha (CLAUDE.md: UZB UTC+5) ---
  v_to   := coalesce(p_to, (now() at time zone 'Asia/Tashkent')::date);
  v_from := coalesce(p_from, v_to - 30);

  if v_from > v_to then                       -- teskari berilgan -> almashtiramiz
    v_tmp := v_from; v_from := v_to; v_to := v_tmp;
  end if;

  if (v_to - v_from) > v_max_kun then         -- 🔴 majburiy cheklov
    v_from  := v_to - v_max_kun;
    v_qisqa := true;
  end if;

  with e2 as (
    -- Aynan 2 satrli posted yozuvlar (Dt/Kt juftligi bir ma'noli)
    select l.entry_id
      from entry_line l
      join entry e on e.id = l.entry_id
     where e.status = 'posted'
       and e.is_deleted = false
       and e.entry_date between v_from and v_to
     group by l.entry_id
    having count(*) = 2
  ),
  t as (
    select e.entry_date                          as sana,
           kt.id   as kt_id, kt.code as kt_kod, kt.name as kt_nom,
           dt.id   as dt_id, dt.code as dt_kod, dt.name as dt_nom,
           round(ld.debit)                       as summa,
           left(coalesce(e.description, ''), 120) as izoh
      from e2
      join entry      e  on e.id = e2.entry_id
      join entry_line ld on ld.entry_id = e.id and ld.debit  > 0
      join entry_line lk on lk.entry_id = e.id and lk.credit > 0
      join accounts   dt on dt.id = ld.account_id
      join accounts   kt on kt.id = lk.account_id
     where dt.section = 'pul'
       and kt.section = 'pul'
       and dt.id <> kt.id
       /* 🔴 KONVERT TRANSFER EMAS: 5011 (UZS) -> 5611 (USD) bitta kassaning
          ichidagi valyuta almashinuvi. Ikkala tomon ham `section='pul'`
          bo'lgani uchun u ham "transfer" bo'lib chiqardi va "bu oy qancha
          transfer" javobini shishirardi. Ildiz (parent) bir xil bo'lsa —
          bu kassalararo harakat emas. `perm_op_key` ayni shu ildizni beradi. */
       and perm_op_key(dt.id) <> perm_op_key(kt.id)
  ),
  f as (
    -- 🔴 SIZISH QOROVULI: har tomon alohida tekshiriladi (bola-hisob -> parent)
    select t.*,
           (v_rejim <> 'list' or perm_op_key(t.kt_id) = any(v_ids)) as kt_ok,
           (v_rejim <> 'list' or perm_op_key(t.dt_id) = any(v_ids)) as dt_ok
      from t
  ),
  r as (
    select sana,
           case when kt_ok then kt_kod else null         end as kimdan_kod,
           case when kt_ok then kt_nom else 'ruxsat yoq' end as kimdan,
           case when dt_ok then dt_kod else null         end as kimga_kod,
           case when dt_ok then dt_nom else 'ruxsat yoq' end as kimga,
           summa,
           -- izohda kassa nomi turadi — bir tomon yashirin bo'lsa izoh ham yashiriladi
           case when kt_ok and dt_ok then izoh else null end as izoh
      from f
     where kt_ok or dt_ok
     order by sana desc, summa desc
     limit v_limit
  )
  select coalesce(jsonb_agg(to_jsonb(r) order by r.sana desc, r.summa desc), '[]'::jsonb),
         count(*),
         coalesce(sum(r.summa), 0)
    into v_rows, v_n, v_jami
    from r;

  return jsonb_build_object(
    'ok',     true,
    'ruxsat', v_rejim,
    'davr',   jsonb_build_object('from', v_from, 'to', v_to,
                                 'kunlar', (v_to - v_from),
                                 'maks_kun', v_max_kun,
                                 'qisqartirildi', v_qisqa),
    'soni',   v_n,
    'kesildi', v_n >= v_limit,
    'jami',   v_jami,
    'izoh',   'Kassalararo harakat (Dt pul / Kt pul), faqat 2 satrli posted yozuvlar. '
              || 'Ruxsatdan tashqari tomon "ruxsat yoq" deb yashiriladi; ikkala tomon ham begona bolsa qator umuman chiqmaydi.',
    'transferlar', v_rows);
end
$ai_tr$;

revoke all on function ai_ctx_transfer(date, date) from public, anon;
grant execute on function ai_ctx_transfer(date, date) to authenticated;

comment on function ai_ctx_transfer(date, date) is
  'AI kontekst: davr ichidagi kassalararo transferlar (maks 92 kun, limit 50). '
  'Faqat ruxsatdagi kassa ishtirok etgan qatorlar; begona tomon yashiriladi. '
  'auth.uid() null -> bosh natija.';
-- ⬆⬆⬆  4-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  5-BO'LIM — STATIK TEKSHIRUV.  HECH NARSA YOZMAYDI.
-- #####################################################################
--  🔴 Nomuvofiqlik JIMGINA O'TMAYDI — `raise exception` bilan to'xtaydi.
--  Har RPC uchun tekshiriladi:
--     1) mavjud;
--     2) SECURITY DEFINER;
--     3) STABLE (yozmaydigan funksiya);
--     4) `set search_path = public` (definer funksiyada MAJBURIY);
--     5) `anon` da EXECUTE yo'q, `authenticated` da BOR;
--     6) tanasida `auth.uid()` bor (kim so'rayotgani faqat shundan);
--     7) FOYDALANUVCHI ID ARGUMENTI YO'Q (uuid argument yoki
--        user/uid nomli argument bo'lmasin);
--     8) tanasida `insert|update|delete` yo'q (faqat o'qish).

-- ⬇⬇⬇  5-BO'LIM: SHU QATORDAN 5-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
do $tekshir$
declare
  v_sig   text;
  v_oid   oid;
  v_def   boolean;
  v_vol   char;
  v_cfg   text[];
  v_src   text;
  v_args  text;
  v_body  text;
begin
  -- 5.0 Ichki yordamchilar
  foreach v_sig in array array['public.ai_ctx_perm()', 'public.ai_ctx_has_page(text)'] loop
    if to_regprocedure(v_sig) is null then
      raise exception 'Ichki yordamchi YARATILMADI: % — 1-BOLIMni RUN qiling', v_sig;
    end if;
    select prosecdef into v_def from pg_proc where oid = to_regprocedure(v_sig)::oid;
    if not v_def then
      raise exception '% SECURITY DEFINER emas — user_perms ni oqiy olmaydi', v_sig;
    end if;
    if exists (select 1 from pg_roles where rolname = 'anon')
       and has_function_privilege('anon', to_regprocedure(v_sig)::oid, 'execute') then
      raise exception '% anon uchun ochiq qolgan', v_sig;
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated')
       and has_function_privilege('authenticated', to_regprocedure(v_sig)::oid, 'execute') then
      raise exception '% authenticated uchun ochiq — u faqat DEFINER RPClar ichidan chaqirilishi kerak', v_sig;
    end if;
  end loop;

  -- 5.1 Uchala RPC
  foreach v_sig in array array['public.ai_ctx_kassa()',
                               'public.ai_ctx_qarzdor()',
                               'public.ai_ctx_transfer(date,date)'] loop
    v_oid := to_regprocedure(v_sig)::oid;
    if v_oid is null then
      raise exception 'RPC YARATILMADI: % — 2/3/4-BOLIMni RUN qiling', v_sig;
    end if;

    select p.prosecdef, p.provolatile, p.proconfig, p.prosrc
      into v_def, v_vol, v_cfg, v_src
      from pg_proc p where p.oid = v_oid;

    v_args := lower(pg_get_function_arguments(v_oid));
    v_body := lower(v_src);

    -- (2) SECURITY DEFINER
    if not v_def then
      raise exception '% SECURITY DEFINER emas — RLS/huquq mantigi ishlamaydi', v_sig;
    end if;

    -- (3) STABLE
    if v_vol <> 's' then
      raise exception '% STABLE emas (volatile=%) — u faqat oqishi kerak', v_sig, v_vol;
    end if;

    -- (4) search_path
    if v_cfg is null or not ('search_path=public' = any(v_cfg)) then
      raise exception '% da "set search_path = public" yoq — DEFINER funksiyada MAJBURIY', v_sig;
    end if;

    -- (5) huquqlar
    if exists (select 1 from pg_roles where rolname = 'anon')
       and has_function_privilege('anon', v_oid, 'execute') then
      raise exception '% anon uchun OCHIQ qolgan — REVOKE ishlamagan!', v_sig;
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated')
       and not has_function_privilege('authenticated', v_oid, 'execute') then
      raise exception '% authenticated uchun YOPIQ — Edge Function chaqira olmaydi', v_sig;
    end if;

    -- (6) auth.uid() tanada
    if position('auth.uid()' in v_body) = 0 then
      raise exception '% tanasida auth.uid() YOQ — kim sorayotgani qayerdan bilinadi?', v_sig;
    end if;

    -- (7) foydalanuvchi id argumenti bo'lmasin
    if position('uuid' in v_args) > 0 then
      raise exception '% da uuid argument bor (%) — begona id bilan chaqirish yoli ochiladi (can_see_project saboqi)',
        v_sig, v_args;
    end if;
    if v_args ~ '(user|uid|_id)' then
      raise exception '% argument nomi shubhali (%) — foydalanuvchi id argumenti TAQIQ', v_sig, v_args;
    end if;

    -- (8) yozmasin
    if v_body ~ '(^|[^a-z_])(insert|update|delete)[[:space:]]+(into|from|[a-z_]+[[:space:]]+set)' then
      raise exception '% tanasida YOZUV amali bor — bu RPClar faqat select bolishi kerak', v_sig;
    end if;
  end loop;

  -- 5.2 view_kassa_ids ishlatilyaptimi (op_kassa_ids EMAS)
  select lower(prosrc) into v_body
    from pg_proc where oid = to_regprocedure('public.ai_ctx_perm()')::oid;
  if position('view_kassa_ids' in v_body) = 0 then
    raise exception 'ai_ctx_perm view_kassa_ids ni oqimayapti — ruxsat notogri manbadan olinyapti';
  end if;
  if position('op_kassa_ids' in v_body) > 0 then
    raise exception 'ai_ctx_perm op_kassa_ids ni ishlatyapti — AI faqat OQIYDI, kalit view_kassa_ids bolishi kerak';
  end if;

  -- 5.3 Bola-hisob qoidasi (perm_op_key orqali) uchala joyda ham bormi
  foreach v_sig in array array['public.ai_ctx_kassa()', 'public.ai_ctx_transfer(date,date)'] loop
    select lower(prosrc) into v_body from pg_proc where oid = to_regprocedure(v_sig)::oid;
    if position('perm_op_key' in v_body) = 0 then
      raise exception '% ichida perm_op_key() yoq — valyuta/pul turi bola-hisoblari ruxsatdan chetda qolardi', v_sig;
    end if;
  end loop;

  /* 5.4 SAHIFA QOROVULI uchala RPC da ham bormi (Asilbek qarori 2026-08-14).
     Avval faqat `ai_ctx_qarzdor` da bor edi: `allowed_pages={'ai'}` +
     `kassa_scope='all'` (default) foydalanuvchi UI da yopiq sahifaning
     ma'lumotini AI orqali olardi. Kalit RPC ga mos bo'lishi ham tekshiriladi. */
  foreach v_sig in array array['public.ai_ctx_kassa()', 'public.ai_ctx_qarzdor()',
                               'public.ai_ctx_transfer(date,date)'] loop
    select lower(prosrc) into v_body from pg_proc where oid = to_regprocedure(v_sig)::oid;
    if position('ai_ctx_has_page' in v_body) = 0 then
      raise exception '% ichida ai_ctx_has_page() yoq — sahifa ruxsati tekshirilmayapti', v_sig;
    end if;
  end loop;
  select lower(prosrc) into v_body from pg_proc where oid = to_regprocedure('public.ai_ctx_kassa()')::oid;
  if position('ai_ctx_has_page(''kassa'')' in v_body) = 0 then
    raise exception 'ai_ctx_kassa notogri sahifa kalitini tekshiryapti (kassa bolishi kerak)';
  end if;
  select lower(prosrc) into v_body from pg_proc where oid = to_regprocedure('public.ai_ctx_transfer(date,date)')::oid;
  if position('ai_ctx_has_page(''jurnal'')' in v_body) = 0 then
    raise exception 'ai_ctx_transfer notogri sahifa kalitini tekshiryapti (jurnal bolishi kerak)';
  end if;

  raise notice '✅ STATIK TEKSHIRUV OK — 3 RPC + 2 yordamchi: definer, stable, search_path, anon yopiq, auth.uid() bor, uuid argument yoq, yozuv yoq, sahifa qorovuli uchalasida.';
end
$tekshir$;

-- 5.4 Ko'z bilan ko'rish uchun (yozmaydi)
select p.proname                                   as funksiya,
       pg_get_function_arguments(p.oid)            as argumentlar,
       case when p.prosecdef then '✅ definer' else '❌ invoker' end as xavfsizlik,
       case when p.provolatile = 's' then '✅ stable' else '❌ ' || p.provolatile end as turg_unlik,
       case when exists (select 1 from pg_roles where rolname='anon')
                 and has_function_privilege('anon', p.oid, 'execute')
            then '❌ anon OCHIQ' else '✅ anon yopiq' end as anon,
       case when exists (select 1 from pg_roles where rolname='authenticated')
                 and has_function_privilege('authenticated', p.oid, 'execute')
            then 'authenticated: execute' else 'authenticated: yopiq' end as jwt_roli
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('ai_ctx_perm','ai_ctx_has_page','ai_ctx_kassa','ai_ctx_qarzdor','ai_ctx_transfer')
 order by p.proname;
-- ⬆⬆⬆  5-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  6-BO'LIM — 🔴 TIRIK SIZISH SINOVI (cheklangan user vs admin)
-- #####################################################################
--  Statik tekshiruv "qorovul BOR" deydi, bu bo'lim esa "qorovul ISHLAYDI"
--  deb ISBOTLAYDI. Ikki xil `auth.uid()` ostida (cheklangan user va
--  admin) quyidagilar sinaladi:
--
--     A) auth.uid() null            -> uchala RPC ham BO'SH (ok=false)
--     B) cheklangan user (scope='list', ATIGI BITTA kassa):
--          • ai_ctx_kassa() AYNAN 1 kassa qaytaradi va u — ruxsatdagisi
--          • taqiqlangan kassaning KODI ham, NOMI ham javobda YO'Q
--          • taqiqlangan kassaning BOLA-HISOBI (valyuta / pul turi)
--            ham ko'rinmaydi
--          • jami_uzs faqat o'sha bitta kassaning jamisiga TENG
--            (begona pul yig'indiga ham qo'shilmagan)
--          • ai_ctx_transfer() da taqiqlangan kassa kodi/nomi chiqmaydi
--          • ai_ctx_qarzdor(): 'qarzdor' sahifasi yo'q -> ok=false;
--            berilgach -> ok=true
--     C) admin: hech narsa cheklanmaydi (ikkala kassa ham ko'rinadi)
--
--  ⚠️ SINOV `entry` / `entry_line` GA TEGMAYDI — bitta ham pul yozuvi
--     yaratilmaydi/o'zgartirilmaydi. Yagona yozuv — sinov userining
--     `user_perms` qatori, u sinov oxirida AYNAN eski holiga qaytariladi
--     (avval nusxa olinadi). Xato bo'lsa ichki blok qaytadi va qator
--     baribir o'z holida qoladi.
--
--  ⚠️ AGAR `set role authenticated` ga ruxsat bo'lmasa, admin/oddiy user
--     yoki 2 ta kassa topilmasa — sinov O'TKAZIB YUBORILADI
--     (`raise notice`), o'rnatish buzilmaydi. U holda 6.2 dagi QO'LDA
--     tekshirishni ishlating.

-- ⬇⬇⬇  6-BO'LIM: SHU QATORDAN 6-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
do $sinov$
declare
  v_admin   uuid;
  v_user    uuid;
  v_k1      uuid;  v_k1_kod text;  v_k1_nom text;  v_k1_jami numeric;
  v_k2      uuid;  v_k2_kod text;  v_k2_nom text;
  v_bola    text;
  v_saved   user_perms%rowtype;
  v_had     boolean := false;
  v_js      jsonb;
  v_n       int;
  v_xato    text[] := array[]::text[];
  v_rolok   boolean := true;
begin
  -- --- 6.0 Rol almashtira olamizmi ---
  begin
    execute 'set local role authenticated';
    execute 'reset role';
  exception when others then
    v_rolok := false;
  end;

  if not v_rolok then
    raise notice '⚠️ TIRIK SINOV OTKAZIB YUBORILDI: authenticated roliga otib bolmadi.';
    raise notice '   6.2 dagi QOLDA tekshirishni ishlating.';
    return;
  end if;

  -- --- 6.0b Ishtirokchilar ---
  select p.id into v_admin
    from profiles p join auth.users u on u.id = p.id
   where p.role = 'admin'
   order by p.id limit 1;

  select p.id into v_user
    from profiles p join auth.users u on u.id = p.id
   where coalesce(p.role, 'user') <> 'admin'
   order by p.id limit 1;

  select id, code, name, coalesce(jami, 0)
    into v_k1, v_k1_kod, v_k1_nom, v_k1_jami
    from v_kassa_card
   where coalesce(kassa_turi, '') <> 'xarajat_guruh'
   order by coalesce(jami, 0) desc, code limit 1;

  select id, code, name into v_k2, v_k2_kod, v_k2_nom
    from v_kassa_card
   where coalesce(kassa_turi, '') <> 'xarajat_guruh'
     and id is distinct from v_k1
   order by coalesce(jami, 0) desc, code limit 1;

  if v_admin is null or v_user is null or v_k1 is null or v_k2 is null then
    raise notice '⚠️ TIRIK SINOV OTKAZIB YUBORILDI: admin, admin bolmagan user va 2 ta kassa kerak.';
    raise notice '   6.2 dagi QOLDA tekshirishni ishlating.';
    return;
  end if;

  -- Taqiqlangan kassaning bola-hisobi (valyuta yoki pul turi) — bo'lmasa null
  select a.code into v_bola
    from accounts a
   where a.parent_id = v_k2
     and coalesce(a.is_active, true)
     and (coalesce(a.currency, 'UZS') <> 'UZS' or a.pul_turi is not null)
   order by a.code limit 1;

  -- =================== A) auth.uid() NULL ===================
  -- (faqat editor sessiyasida claims umuman bo'lmasa mazmunli)
  if auth.uid() is null then
    v_js := ai_ctx_kassa();
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || 'auth.uid() NULL da ai_ctx_kassa() malumot berdi (service_role tesigi!)';
    end if;
    v_js := ai_ctx_qarzdor();
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || 'auth.uid() NULL da ai_ctx_qarzdor() malumot berdi';
    end if;
    v_js := ai_ctx_transfer(current_date - 30, current_date);
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || 'auth.uid() NULL da ai_ctx_transfer() malumot berdi';
    end if;
  else
    raise notice 'INFO: sessiyada auth.uid() bor — "service_role bosh natija" qadami otkazildi.';
  end if;

  -- =================== B) CHEKLANGAN USER ===================
  -- Eski ruxsat qatoridan NUSXA (oxirida aynan shu qaytariladi)
  select * into v_saved from user_perms where user_id = v_user;
  v_had := found;

  begin
    -- Vaqtincha cheklov: FAQAT v_k1 kassasi ko'rinadi, sahifa ruxsati YO'Q
    insert into user_perms (user_id, allowed_pages, kassa_scope, view_kassa_ids, op_kassa_ids)
    values (v_user, '{}'::text[], 'list', array[v_k1], '{}'::uuid[])
    on conflict (user_id) do update
       set allowed_pages  = excluded.allowed_pages,
           kassa_scope    = excluded.kassa_scope,
           view_kassa_ids = excluded.view_kassa_ids,
           op_kassa_ids   = excluded.op_kassa_ids;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';

    -- B1) ai_ctx_kassa — AYNAN bitta kassa
    v_js := ai_ctx_kassa();

    if not coalesce((v_js ->> 'ok')::boolean, false) then
      v_xato := v_xato || ('Cheklangan user ai_ctx_kassa() dan ok=false oldi: ' || coalesce(v_js ->> 'sabab', '?'));
    end if;
    if (v_js ->> 'ruxsat') is distinct from 'list' then
      v_xato := v_xato || ('ruxsat rejimi list emas: ' || coalesce(v_js ->> 'ruxsat', 'null'));
    end if;

    v_n := jsonb_array_length(coalesce(v_js -> 'kassalar', '[]'::jsonb));
    if v_n <> 1 then
      v_xato := v_xato || ('🔴 ai_ctx_kassa() ' || v_n || ' ta kassa qaytardi, AYNAN 1 kutilgandi');
    end if;

    if v_n >= 1 and (v_js -> 'kassalar' -> 0 ->> 'code') is distinct from v_k1_kod then
      v_xato := v_xato || ('Notogri kassa qaytdi: ' || coalesce(v_js -> 'kassalar' -> 0 ->> 'code', 'null')
                           || ', kutilgan ' || v_k1_kod);
    end if;

    -- B2) Taqiqlangan kassa KODI hech qaysi elementda bo'lmasin
    select count(*) into v_n
      from jsonb_array_elements(coalesce(v_js -> 'kassalar', '[]'::jsonb)) x
     where x ->> 'code' = v_k2_kod;
    if v_n <> 0 then
      v_xato := v_xato || ('🔴 SIZISH: taqiqlangan kassa ' || v_k2_kod || ' ai_ctx_kassa() da chiqdi');
    end if;

    -- B3) Taqiqlangan kassa NOMI xom matnda ham bo'lmasin
    --     (nomlar bir-birining ichida bo'lsa bu tekshiruv o'tkazib yuboriladi)
    if position(v_k2_nom in v_k1_nom) = 0 and position(v_k2_nom in v_js::text) > 0 then
      v_xato := v_xato || ('🔴 SIZISH: taqiqlangan kassa nomi javob matnida bor: ' || v_k2_nom);
    end if;

    -- B4) Taqiqlangan kassaning BOLA-HISOBI ham sizmasin
    if v_bola is not null and position(v_bola in v_js::text) > 0 then
      v_xato := v_xato || ('🔴 SIZISH: begona bola-hisob ' || v_bola || ' javobda bor');
    end if;

    -- B5) Yig'indi ham begona puldan toza bo'lsin
    if round(coalesce((v_js ->> 'jami_uzs')::numeric, -1)) is distinct from round(v_k1_jami) then
      v_xato := v_xato || ('🔴 jami_uzs begona pulni ham qoshgan: '
                           || coalesce(v_js ->> 'jami_uzs', 'null') || ' vs ' || round(v_k1_jami)::text);
    end if;

    -- B6) Transferlarda begona tomon yashirinsin
    v_js := ai_ctx_transfer(current_date - 92, current_date);
    if not coalesce((v_js ->> 'ok')::boolean, false) then
      v_xato := v_xato || 'Cheklangan user ai_ctx_transfer() dan ok=false oldi';
    end if;

    select count(*) into v_n
      from jsonb_array_elements(coalesce(v_js -> 'transferlar', '[]'::jsonb)) x
     where x ->> 'kimdan_kod' = v_k2_kod or x ->> 'kimga_kod' = v_k2_kod;
    if v_n <> 0 then
      v_xato := v_xato || ('🔴 SIZISH: transferlarda taqiqlangan kassa kodi ' || v_k2_kod || ' chiqdi');
    end if;

    if position(v_k2_nom in v_k1_nom) = 0 and position(v_k2_nom in v_js::text) > 0 then
      v_xato := v_xato || ('🔴 SIZISH: transferlarda taqiqlangan kassa nomi chiqdi: ' || v_k2_nom);
    end if;

    raise notice 'INFO: sinov davrida cheklangan userga % ta transfer korindi (0 bolsa sinov "bosh" — sizish yoq, lekin isbot ham zaif)',
      coalesce((v_js ->> 'soni')::int, 0);

    -- B7) Qarzdor: sahifa ruxsati YO'Q -> bo'sh
    v_js := ai_ctx_qarzdor();
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || '🔴 SIZISH: qarzdor sahifasi ruxsatida yoq, lekin ai_ctx_qarzdor() malumot berdi';
    end if;
    if (v_js ->> 'debitor_4010') is not null then
      v_xato := v_xato || '🔴 SIZISH: ruxsatsiz holatda debitor_4010 raqami qaytdi';
    end if;

    -- B8) Sahifa berilsa -> ochiladi (fail-closed haddan tashqari qattiq emasligi)
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);

    update user_perms set allowed_pages = array['qarzdor']::text[] where user_id = v_user;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';

    v_js := ai_ctx_qarzdor();
    if not coalesce((v_js ->> 'ok')::boolean, false) then
      v_xato := v_xato || ('qarzdor sahifasi berilgach ham ai_ctx_qarzdor() yopiq qoldi: '
                           || coalesce(v_js ->> 'sabab', '?'));
    end if;

    -- =================== C) ADMIN ===================
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';

    v_js := ai_ctx_kassa();
    if (v_js ->> 'ruxsat') is distinct from 'admin' then
      v_xato := v_xato || ('Admin rejimi admin emas: ' || coalesce(v_js ->> 'ruxsat', 'null'));
    end if;

    select count(*) into v_n
      from jsonb_array_elements(coalesce(v_js -> 'kassalar', '[]'::jsonb)) x
     where x ->> 'code' in (v_k1_kod, v_k2_kod);
    if v_n <> 2 then
      v_xato := v_xato || ('Admin ikkala kassani kormadi (topildi ' || v_n || ' / 2) — filtr admin uchun ham ishlab ketgan');
    end if;

    -- =================== TOZALASH ===================
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);

    delete from user_perms where user_id = v_user;
    if v_had then
      insert into user_perms select (v_saved).*;      -- AYNAN eski qator
    end if;

  exception when others then
    -- Ichki blok = subtranzaksiya: xato bo'lsa user_perms o'zgarishlari
    -- ham, `set local role` ham QAYTADI. Qo'shimcha tozalash SHART EMAS.
    v_xato := v_xato || ('SINOV XATOSI (ozgarishlar qaytarildi): ' || sqlerrm || ' [' || sqlstate || ']');
  end;

  -- =================== HUKM ===================
  if array_length(v_xato, 1) is not null then
    raise exception '🔴 SIZISH SINOVI YIQILDI: %', array_to_string(v_xato, ' | ');
  end if;

  raise notice '✅ TIRIK SIZISH SINOVI OK — cheklangan user FAQAT oz kassasini kordi;';
  raise notice '   begona kassa kodi/nomi/bola-hisobi va yigindisi sizmadi; admin cheklanmadi;';
  raise notice '   qarzdor sahifa qorovuli ishladi; user_perms qatori eski holiga qaytarildi.';
end
$sinov$;

-- 6.1 Sinovdan keyin ruxsat jadvali toza qolganini ko'rish (yozmaydi)
select user_id, kassa_scope,
       coalesce(array_length(view_kassa_ids, 1), 0) as view_kassa_soni,
       coalesce(array_length(allowed_pages, 1), 0)  as sahifa_soni,
       updated_at
  from user_perms
 order by updated_at desc
 limit 10;
-- ⬆⬆⬆  6-BO'LIM shu yerda tugadi  ⬆⬆⬆

-- ---------------------------------------------------------------------
--  6.2 — QO'LDA TEKSHIRISH (agar 6-BO'LIM o'tkazib yuborilgan bo'lsa)
-- ---------------------------------------------------------------------
--  Sabab: Supabase SQL Editor ba'zi loyihalarda `set role authenticated`
--  ga ruxsat bermasligi mumkin.
--
--  Eng ishonchli qo'lda usul — ILOVADAN: cheklangan (kassa_scope='list')
--  foydalanuvchi bilan kiring va brauzer konsolida:
--
--     await sb.rpc('ai_ctx_kassa')          // faqat oz kassalari
--     await sb.rpc('ai_ctx_qarzdor')        // sahifa ruxsatiga qarab
--     await sb.rpc('ai_ctx_transfer', { p_from: '2026-07-01', p_to: '2026-08-14' })
--
--  Natijadagi `kassalar` ro'yxatini `kassa.html` da ko'rinadigan kartalar
--  bilan solishtiring — AYNAN bir xil bo'lishi shart (ko'p ham, kam ham
--  emas). Har javobda `{ data, error }` — `error` ni tekshiring.
--
--  SQL bilan (id larni qo'yib, ALOHIDA ishga tushiring):
--
--  begin;
--    set local request.jwt.claims = '{"sub":"<CHEKLANGAN-USER-UUID>","role":"authenticated"}';
--    set local role authenticated;
--    select jsonb_pretty(ai_ctx_kassa());
--    select jsonb_pretty(ai_ctx_transfer(current_date - 30, current_date));
--  rollback;
--
--  ⚠️ Oxirida ROLLBACK.


-- #####################################################################
--  7-BO'LIM — PostgREST sxema keshini yangilash
-- #####################################################################
--  Busiz yangi RPC'lar klientdan/EF dan "function not found" (PGRST202)
--  beradi.

-- ⬇⬇⬇  7-BO'LIM  ⬇⬇⬇
notify pgrst, 'reload schema';
-- ⬆⬆⬆  7-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  8-BO'LIM — ROLLBACK (kerak bo'lsa, QO'LDA)
-- #####################################################################
--  Ataylab izohda turibdi — tasodifan RUN bo'lmasin.
--  ⚠️ Bu fayl BOSHQA HECH NARSAGA tegmagani uchun rollback ham hech
--     qanday mavjud funksiyani/view'ni qaytarmaydi: faqat 5 ta yangi
--     funksiya o'chadi. Ma'lumot yo'qolmaydi (birorta jadval yaratilmagan).
--  ⚠️ Tartib: avval RPC'lar, keyin ular chaqiradigan yordamchilar.
--  ⚠️ Rollback'dan keyin Edge Function ning DB tool'lari ishlamay qoladi
--     (AI faqat suhbat rejimida qoladi) — avval EF ni orqaga qaytaring.
--
-- drop function if exists ai_ctx_transfer(date, date);
-- drop function if exists ai_ctx_qarzdor();
-- drop function if exists ai_ctx_kassa();
-- drop function if exists ai_ctx_has_page(text);
-- drop function if exists ai_ctx_perm();
-- notify pgrst, 'reload schema';


-- #####################################################################
--  9-BO'LIM — EDGE FUNCTION UCHUN SHARTNOMA  (faqat izoh, RUN qilinmaydi)
-- #####################################################################
--
--  🔴🔴  ENG MUHIM QOIDA  🔴🔴
--  EF bu RPC'larni FOYDALANUVCHI JWT SI BILAN chaqirsin —
--  SERVICE_ROLE BILAN EMAS. service_role da `auth.uid()` NULL bo'ladi va:
--     • javob BO'SH keladi (`ok:false`, `sabab:'Avtorizatsiya yoq...'`),
--       ya'ni AI "ma'lumot yo'q" deb javob beradi — bu XATO emas,
--       ATAYLAB qilingan (2-QOIDA);
--     • agar kelajakda kimdir bu qorovulni "tuzatib" service_role ga
--       ochsa — butun ruxsat mantiqi CHETLAB O'TILADI va boshqa
--       filialning puli AI orqali sizadi.
--  Mavjud naqsh (CLAUDE.md, `ai-chat` EF): anon key + foydalanuvchining
--  `Authorization` headeri bilan klient quriladi. AYNAN o'sha klientdan
--  `sb.rpc(...)` qiling.
--
--  ---------------------------------------------------------------
--  1) ai_ctx_kassa()  — argumentsiz
--  ---------------------------------------------------------------
--     sb.rpc('ai_ctx_kassa')
--
--     -> jsonb OBYEKT (massiv emas):
--        {
--          "ok": true,
--          "ruxsat": "admin" | "all" | "list",
--          "sana": "2026-08-14 17:20",              // Asia/Tashkent
--          "kassa_soni": 12,
--          "kesildi": false,                        // true = 60 tadan ko'p bor edi
--          "jami_uzs": 812345678,
--          "izoh": "...",
--          "kassalar": [
--            { "code":"5011", "name":"Toshkent Kassa", "kassa_turi":"markaziy",
--              "uzs": 120000000, "usd": 4500.00, "jami": 178000000 }, ...
--          ]
--        }
--     Xato/ruxsatsiz holat: { "ok": false, "sabab": "...", "kassalar": [] }
--
--     ⚠️ `usd` — DOLLAR MIQDORI (so'm emas). `jami` esa so'mda va uning
--        ichida dollar so'm ekvivalenti bilan turadi. AI ga shu farqni
--        system prompt'da ayting, aks holda u ikkalasini qo'shib yuboradi.
--     ⚠️ `kesildi: true` bo'lsa AI "hammasi shu" demasin.
--
--  ---------------------------------------------------------------
--  2) ai_ctx_qarzdor()  — argumentsiz
--  ---------------------------------------------------------------
--     sb.rpc('ai_ctx_qarzdor')
--
--     -> { "ok": true, "ruxsat": true, "sana": "...",
--          "debitor_4010": 45000000,      // bizga qarzdor (musbat)
--          "kreditor_6010": 12000000,     // biz qarzdormiz (musbat)
--          "qator_soni": 20, "kesildi": true, "izoh": "...",
--          "qatorlar": [ { "sana":"2026-07-30", "kod":"4010",
--                          "hisob":"Xaridorlar qarzi", "tomon":"debitor",
--                          "yonalish":"Dt", "summa": 9500000,
--                          "izoh":"..." }, ... ] }
--
--     Sahifa ruxsati yo'q bo'lsa:
--        { "ok": false, "sabab":"Qarzdorlar sahifasi ruxsatingizda yoq",
--          "debitor_4010": null, "kreditor_6010": null, "qatorlar": [] }
--     -> AI shu holatda raqam O'YLAB TOPMASIN, "ruxsatingiz yo'q" desin.
--
--  ---------------------------------------------------------------
--  3) ai_ctx_transfer(p_from date, p_to date)
--  ---------------------------------------------------------------
--     sb.rpc('ai_ctx_transfer', { p_from: '2026-07-01', p_to: '2026-08-14' })
--     Ikkala argument ham ixtiyoriy (default: oxirgi 30 kun).
--     🔴 Argumentlar FAQAT sana — foydalanuvchi id argumenti YO'Q va
--        hech qachon qo'shilmasin.
--
--     -> { "ok": true, "ruxsat": "list",
--          "davr": { "from":"2026-05-15", "to":"2026-08-14",
--                    "kunlar": 91, "maks_kun": 92, "qisqartirildi": true },
--          "soni": 50, "kesildi": true, "jami": 640000000, "izoh": "...",
--          "transferlar": [
--            { "sana":"2026-08-12", "kimdan_kod":"5211", "kimdan":"Izza Showroom",
--              "kimga_kod":"5011", "kimga":"Toshkent Kassa",
--              "summa": 25000000, "izoh":"..." },
--            { "sana":"2026-08-11", "kimdan_kod":null, "kimdan":"ruxsat yoq",
--              "kimga_kod":"5011", "kimga":"Toshkent Kassa",
--              "summa": 8000000, "izoh":null }
--          ] }
--
--     ⚠️ `"kimdan":"ruxsat yoq"` = o'sha tomon foydalanuvchi ruxsatidan
--        tashqarida. AI uni TAXMIN QILMASIN ("Sergeli bo'lsa kerak" —
--        TAQIQ), shunchaki "ruxsatingizdan tashqaridagi kassa" desin.
--     ⚠️ `davr.qisqartirildi: true` bo'lsa AI javobda haqiqiy davrni
--        aytsin (foydalanuvchi so'ragan davrni emas).
--
--  ---------------------------------------------------------------
--  UMUMIY (EF tomonida)
--  ---------------------------------------------------------------
--   • `sb.rpc()` `{ data, error }` qaytaradi va THROW QILMAYDI —
--     `error` DOIM tekshirilsin (CLAUDE.md 6-qoida). Xatoni jimgina
--     yutib "ma'lumot yo'q" deb Claude'ga bermang: AI raqamni o'ylab
--     topib qo'yishi mumkin. Tool natijasida xato ochiq yozilsin.
--   • Bu RPC'lar tool (function calling) uchun mo'ljallangan: AI
--     kerak bo'lgandagina chaqirsin, har savolda butun baza kontekstga
--     yuborilmasin (BRIEF 4-band: "tool/function calling afzal").
--   • Tool tavsifida (Claude tool description) AYTILSIN: "natija
--     foydalanuvchi ruxsatiga qarab CHEKLANGAN bo'lishi mumkin;
--     ko'rinmagan kassa haqida taxmin qilma".
--   • Hech bir RPC yozmaydi — `ai-chat` EF ning "Provodka jadvaliga
--     yozmaydi" invarianti buzilmaydi.
--   • Yangi kontekst RPC qo'shilsa: nomi `ai_ctx_` bilan boshlansin,
--     ruxsatni `ai_ctx_perm()` / `ai_ctx_has_page()` dan olsin, va
--     5-BO'LIM ro'yxatiga qo'shilsin (statik tekshiruv uni ham qamrasin).
-- #####################################################################
