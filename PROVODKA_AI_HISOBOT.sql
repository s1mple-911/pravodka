-- =====================================================================
--  ⚠️⚠️  SUPABASE SQL EDITOR — QANDAY RUN QILINADI (avval SHUNI o'qing)
-- ---------------------------------------------------------------------
--   1) Har bo'lak ⬇⬇⬇ va ⬆⬆⬆ belgilari orasida. AYNAN o'sha oraliqni
--      belgilab RUN qiling. Tartib bilan: 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7
--      → 8 → 9.
--
--   2) 🔴 BUTUN FAYLNI BIRDANIGA RUN QILISH TAVSIYA ETILMAYDI: 7- va
--      8-BO'LIM nomuvofiqlikda `raise exception` qiladi, va editor butun
--      skriptni bitta tranzaksiyada yuborsa 1–6-BO'LIMlar ham QAYTIB
--      KETADI (funksiyalar yaratilmay qoladi). Bo'lak-bo'lak RUN qilsangiz
--      — o'rnatish o'rnida qoladi, faqat sinov qizil beradi.
--
--   3) Bo'lak diapazonlari:
--        0-BO'LIM — old shart tekshiruvi (HECH NARSA YOZMAYDI, faqat select)
--        1-BO'LIM — ichki yordamchilar (ai_rep_yoq / davr / scope /
--                   filial_scope / top) — hammasi `authenticated` uchun YOPIQ
--        2-BO'LIM — ai_rep_xarajat(from, to, kesim)
--        3-BO'LIM — ai_rep_kirim(from, to, kesim)
--        4-BO'LIM — ai_rep_cashflow(from, to)
--        5-BO'LIM — ai_rep_balans(sana)
--        6-BO'LIM — ai_rep_jurnal(from, to, qidiruv, min, max)
--        7-BO'LIM — STATIK TEKSHIRUV (do bloki, nomuvofiqlikda exception)
--        8-BO'LIM — 🔴 TIRIK SIZISH SINOVI (cheklangan user vs admin)
--        9-BO'LIM — notify pgrst (PostgREST sxema keshini yangilash)
--       10-BO'LIM — ROLLBACK (izohda, qo'lda ishlatiladi)
--       11-BO'LIM — EDGE FUNCTION UCHUN SHARTNOMA (faqat izoh)
--
--   4) 🔴 SQL ni ASILBEK o'zi RUN qiladi. Agent bajarmaydi.
--
--   5) 🔴 OLD SHART: `PROVODKA_AI_KONTEKST.sql` ALLAQACHON RUN QILINGAN
--      bo'lishi kerak — bu fayl uning `ai_ctx_perm()` va
--      `ai_ctx_has_page()` yadrosiga TAYANADI va o'sha ikki funksiyani
--      QAYTA YOZMAYDI. 0-BO'LIM buni birinchi bo'lib tekshiradi.
--
--   6) Fayl kimning nomidan RUN qilinsa, funksiyalar EGASI ham o'sha rol
--      bo'ladi (SECURITY DEFINER shu roldan ishlaydi). Supabase SQL
--      Editor'da bu `postgres`. Boshqa roldan RUN QILMANG.
-- =====================================================================

-- =====================================================================
--  PROVODKA_AI_HISOBOT.sql
--  AI uchun ANALITIKA RPC qatlami (5-bosqich, 1-ish) — FAQAT SQL
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  #####  NIMA QILADI  #################################################
--
--  BRIEF_PROVODKA_AI_5.md 1-band: AI to'liq moliyaviy tahlilchi bo'lsin —
--  xarajat / kirim / pul oqimi / balans / jurnal, chart va Excel uchun
--  tayyor shaklda. Edge Function uchun 5 ta o'qish RPC:
--
--     ai_rep_xarajat(p_from, p_to, p_kesim)   -- xodim | kategoriya | filial
--     ai_rep_kirim(p_from, p_to, p_kesim)     -- manba | filial
--     ai_rep_cashflow(p_from, p_to)           -- kirim vs chiqim + qoldiq
--     ai_rep_balans(p_sana)                   -- aktiv / passiv / kapital
--     ai_rep_jurnal(p_from, p_to, p_qidiruv, p_min, p_max)
--
--  #####  🔴 IKKI HAQIQAT BO'LMASIN — MAVJUD RPC O'RALADI  #############
--
--  Brief: "mavjud hisobot mantiqini RPC'ga aylantirsin (bir xil natija,
--  ikki haqiqat bo'lmasin)". Shuning uchun bu fayl mavjud hisobot
--  mantiqini QAYTA YOZMAYDI, uni O'RAYDI (wrap):
--
--     ai_rep_balans   -> balans(p_date)                (balans-dev.html)
--     ai_rep_cashflow -> cashflow_kassa(from,to,kassa) (cashflow-dev.html)
--                        pul_qoldiq_kassa(date,kassa)  (o'sha sahifa)
--     ai_rep_jurnal   -> jurnal(from,to,...)           (jurnal-dev.html)
--     ai_rep_xarajat  -> pnl(from,to)                  (hisobot-dev.html
--                        P&L zinapoyasi — `pnl_bolim` bloki)
--
--  Sabab: `pnl` / `balans` / `cashflow` mantiqi murakkab (zinapoya,
--  kontr-aktiv amortizatsiya, `p_account` semantikasi, oila ichidagi
--  ko'chirishni chiqarib tashlash). Nusxa ko'chirilsa ertaga hisobot
--  sahifasi o'zgarganda AI BOSHQA raqam aytardi. ⚠️ Ustiga, `pnl` /
--  `balans` / `cashflow` / `pul_qoldiq` / `jurnal` manbasi REPODA YO'Q
--  (to'g'ridan bazada yaratilgan) — ularni "qayta yozish" degani aslida
--  ko'r-ko'rona qayta ixtiro qilish bo'lardi.
--
--  #####  QAYERDA YANGI SO'ROV YOZILGAN (va nega)  #####################
--
--  Mavjud RPC BO'LMAGAN yagona kesim — xarajat/kirimning xodim /
--  kategoriya / filial / manba taqsimoti. Ular uchun so'rov shu faylda,
--  LEKIN mantiq mavjud sahifalardan HARFMA-HARF ko'chirilgan:
--
--    kesim 'kategoriya' = hodim_kategoriya_hisobot(from,to)
--        (PROVODKA_HODIM_V4.sql 3.1; hisobot-dev.html "CEO" bloki):
--        accounts.type='xarajat', sum(entry_line.debit),
--        having sum(debit) > 0, kamayish tartibida.
--    kesim 'xodim'      = hodim_kassa_hisobot(from,to)
--        (PROVODKA_HODIM_V4.sql 3.2): Kt tomoni section='pul' bo'lgan
--        satrlar, yozuvda type='xarajat' Dt satri bo'lishi sharti bilan.
--    kesim 'filial'     = standart_holat(p_oy) naqshi
--        (PROVODKA_V7.sql 4.1): `s.filial_id = any(e.filial_ids)` —
--        filial xarajatda METADATA (entry.filial_ids), kassa emas.
--    kirim 'manba'      = yuqoridagi 'xodim' ning KO'ZGUSI: Dt pul,
--        Kt pul EMAS -> Kt hisob (9010 savdo tushumi, 8000 ...).
--        Tasnif `section='pul'` bo'yicha (CLAUDE.md "Jurnal tasnifi —
--        4 holat"), kod prefiksi bilan EMAS.
--    kirim 'filial'     = pul KIRGAN kassa. ⚠️ Provodka'da KIRIM uchun
--        alohida filial metadatasi YO'Q (`entry.filial_ids` V6 da faqat
--        XARAJAT uchun kiritilgan) — shuning uchun kirimda "filial" =
--        pulni qabul qilgan kassa. Javobda `kassa_turi` ustuni bor,
--        markaziy/filial/xarajat kassasi ajratiladi.
--
--  Har uchala so'rovda shart AYNAN sahifalardagidek:
--     e.status = 'posted' and e.is_deleted = false
--  (CLAUDE.md: "Balans hisobi faqat posted AND is_deleted=false").
--
--  ⚠️ IKKI XIL XARAJAT YIG'INDISI BAZADA ALLAQACHON BOR:
--     hodim_kategoriya_hisobot -> sum(debit)            (CEO bloki)
--     hisobot-dev.html P&L taqsimoti -> sum(debit-credit) (netto)
--  Yangi haqiqat O'YLAB TOPILMADI: `summa` = sum(debit) (CEO bloki bilan
--  bir xil, chart/Excel shu bilan chiziladi), `netto` esa qo'shimcha
--  ustun bo'lib yonida turadi. Farq bo'lsa — storno/tuzatish satri bor.
--
--  #####  🔴 XAVFSIZLIK — 4-BOSQICH NAQSHI AYNAN TAKRORLANADI  #########
--
--   1) FOYDALANUVCHI ID ARGUMENTI YO'Q. Kim so'rayotgani faqat
--      `auth.uid()` dan (TaskFix `can_see_project` saboqi).
--   2) `auth.uid()` NULL (service_role, n8n, SQL editor) -> BO'SH natija
--      (`ok:false`), "hammasi" EMAS.
--   3) IKKI QOROVUL: `ai_ctx_perm()` yadrosi (kassa ruxsati) VA
--      `ai_ctx_has_page()` (sahifa ruxsati, fail-CLOSED):
--         ai_rep_xarajat  -> 'hisobot'
--         ai_rep_kirim    -> 'hisobot'
--         ai_rep_cashflow -> 'cashflow'
--         ai_rep_balans   -> 'balans'
--         ai_rep_jurnal   -> 'jurnal'
--   4) Kassa/pul kesimida `perm_op_key()` bilan `view_kassa_ids` filtri —
--      mijozdagi `keyOf()` bilan AYNAN bir xil qoida (valyuta 56xx/57xx va
--      pul turi naqd/click/payme bolalari ruxsatni PARENT kassadan oladi).
--   5) MASKALASH: ruxsatdan tashqari kassaning kodi, nomi VA IZOHI
--      chiqmaydi (izohda odatda kassa nomi turadi — 4-bosqichdagi
--      transfer maskalash naqshi).
--   6) Yig'indiga (`jami`) begona pul QO'SHILMAYDI — raqamdan begona
--      kassaning mavjudligini bilib bo'lmaydi.
--   7) `p_qidiruv` — model/foydalanuvchi matni: `%` va `_` escape
--      qilinadi (naqsh portlashi yo'q), uzunligi 60 belgiga kesiladi.
--   8) `p_kesim` — faqat ruxsat etilgan qiymatlar; aks holda ok:false.
--
--  🔴🔴 `ai_rep_balans` (va `ai_rep_xarajat` ichidagi `pnl_bolim`) —
--  BUTUN KOMPANIYA hisoboti, ularda kassa kesimi YO'Q va shuning uchun
--  KASSA FILTRI HAM YO'Q: u yerda SAHIFA RUXSATI YAGONA QOROVUL. Bu
--  ataylab, UI bilan izchil: `balans-dev.html` / `hisobot-dev.html` P&L
--  zinapoyasi ham sahifa ruxsati bilan ochiladi va butun kompaniya
--  raqamini ko'rsatadi (u yerda `balans(p_date)` / `pnl(p_from,p_to)`
--  hech qanday kassa filtri qabul qilmaydi). Ya'ni "balansni ko'ra
--  oladigan odam hamma hisob qoldig'ini ko'radi" — bu YANGI teshik EMAS,
--  mavjud mahsulot qarori. Kimdir buni cheklamoqchi bo'lsa — avval
--  `balans.html` ni cheklashi kerak, keyin bu RPC ni.
--  ⚠️ Aynan shu sababli `pnl_bolim` bloki KASSA CHEKLOVI BOR userga
--  BERILMAYDI (null) — aks holda `list` rejimdagi user kassa filtri
--  ostidagi qatorlar yonida butun kompaniya foydasini ko'rib, 6-qoidani
--  buzardi.
--
--  #####  🔴 PUL HARAKATI YO'Q  ########################################
--
--  Beshala RPC ham FAQAT SELECT. `entry` / `entry_line` ga bitta qator
--  ham yozilmaydi: balans, P&L, cashflow raqamlari O'ZGARMAYDI.
--
--  #####  ADDITIVE  ####################################################
--
--  Mavjud jadval / ustun / view / funksiya / policy / trigger
--  O'ZGARTIRILMAYDI. `ai_ctx_perm`, `ai_ctx_has_page`, `ai_ctx_kassa`,
--  `ai_ctx_qarzdor`, `ai_ctx_transfer`, `pnl`, `balans`, `cashflow`,
--  `pul_qoldiq`, `jurnal`, `cashflow_kassa`, `pul_qoldiq_kassa`,
--  `hodim_*`, `hisobot_*` — TEGILMAYDI. Faqat YANGI funksiyalar:
--     ai_rep_yoq(text)                (ichki — bo'sh javob shakli)
--     ai_rep_davr(date, date)         (ichki — davr normallashtirish)
--     ai_rep_scope()                  (ichki — kassa ruxsati)
--     ai_rep_filial_scope()           (ichki — filial ruxsati)
--     ai_rep_top(jsonb, int)          (ichki — top-N + Boshqalar + ulush)
--     ai_rep_xarajat(date, date, text)
--     ai_rep_kirim(date, date, text)
--     ai_rep_cashflow(date, date)
--     ai_rep_balans(date)
--     ai_rep_jurnal(date, date, text, numeric, numeric)
--  Idempotent: hammasi `create or replace`, qayta RUN xavfsiz.
-- =====================================================================


-- #####################################################################
--  0-BO'LIM — OLD SHART TEKSHIRUVI.  HECH NARSA YOZMAYDI.
-- #####################################################################
--  ⚠️ Funksiyalar ATAYLAB CHAQIRILMAYDI (faqat mavjudligi tekshiriladi):
--     bazada bo'lmasa `case` shoxi baribir rejalashtiriladi va butun
--     select "function does not exist" bilan yiqilardi.

-- ⬇⬇⬇  0-BO'LIM  ⬇⬇⬇
-- 0.1 🔴 ENG MUHIM: bu fayl PROVODKA_AI_KONTEKST.sql ustiga quriladi
select 'ai_ctx_perm()  [PROVODKA_AI_KONTEKST.sql]' as tekshiruv,
       case when to_regprocedure('public.ai_ctx_perm()') is not null
            then '✅ BOR — kassa ruxsati shundan olinadi'
            else '❌ YO''Q — 🔴 AVVAL PROVODKA_AI_KONTEKST.sql ni RUN QILING. Bu fayl unga TAYANADI va uni qayta yozmaydi.' end as natija
union all
select 'ai_ctx_has_page(text)  [PROVODKA_AI_KONTEKST.sql]',
       case when to_regprocedure('public.ai_ctx_has_page(text)') is not null
            then '✅ BOR — sahifa qorovuli (fail-closed) shundan'
            else '❌ YO''Q — 🔴 AVVAL PROVODKA_AI_KONTEKST.sql ni RUN QILING' end
union all
select 'perm_op_key(uuid)  [PROVODKA_PERMS.sql]',
       case when to_regprocedure('public.perm_op_key(uuid)') is not null
            then '✅ BOR — bola-hisob ruxsati parentdan olinadi'
            else '❌ YO''Q — avval PROVODKA_PERMS.sql ni RUN qiling' end
union all
select 'is_admin()',
       case when to_regprocedure('public.is_admin()') is not null
            then '✅ BOR' else '❌ YO''Q — PROVODKA_PERMS.sql' end
union all
select 'user_perms jadvali',
       case when to_regclass('public.user_perms') is not null
            then '✅ BOR' else '❌ YO''Q — PROVODKA_PERMS.sql' end;

-- 0.2 O'RALADIGAN mavjud hisobot RPC'lari (busiz wrapper ishlamaydi)
select 'balans(date)  [balans-dev.html]' as tekshiruv,
       case when to_regprocedure('public.balans(date)') is not null
            then '✅ BOR — ai_rep_balans() shuni oraydi'
            else '❌ YO''Q — ai_rep_balans() ishlamaydi' end as natija
union all
select 'cashflow_kassa(date,date,uuid)  [cashflow-dev.html]',
       case when to_regprocedure('public.cashflow_kassa(date,date,uuid)') is not null
            then '✅ BOR — ai_rep_cashflow() shuni oraydi (p_kassa null bolsa cashflow() ga delegat qiladi)'
            else '❌ YO''Q — avval PROVODKA_CASHFLOW_FIX.sql ni RUN qiling' end
union all
select 'pul_qoldiq_kassa(date,uuid)  [cashflow-dev.html]',
       case when to_regprocedure('public.pul_qoldiq_kassa(date,uuid)') is not null
            then '✅ BOR — davr boshi/oxiri qoldigi shundan'
            else '❌ YO''Q — avval PROVODKA_CASHFLOW_FIX.sql ni RUN qiling' end
union all
select 'jurnal(date,date,uuid,uuid[],int,int)  [jurnal-dev.html]',
       case when to_regprocedure('public.jurnal(date,date,uuid,uuid[],int,int)') is not null
            then '✅ BOR — ai_rep_jurnal() shuni oraydi'
            else '❌ YO''Q — ai_rep_jurnal() ishlamaydi' end
union all
select 'pnl(date,date)  [hisobot-dev.html]',
       case when to_regprocedure('public.pnl(date,date)') is not null
            then '✅ BOR — ai_rep_xarajat() dagi pnl_bolim bloki shuni oraydi'
            else '⚠️ YO''Q — ai_rep_xarajat() baribir ishlaydi, faqat pnl_bolim null qaytadi' end
union all
select 'cashflow(date,date,uuid) / pul_qoldiq(date,uuid)',
       case when to_regprocedure('public.cashflow(date,date,uuid)') is not null
             and to_regprocedure('public.pul_qoldiq(date,uuid)') is not null
            then '✅ BOR — cashflow_kassa/pul_qoldiq_kassa ular ustiga qurilgan'
            else '⚠️ Tekshiring — _kassa variantlari shularga delegat qiladi' end;

-- 0.3 Manba jadvallar / ustunlar (yangi so'rovlar shularga tayanadi)
select 'entry / entry_line / accounts' as tekshiruv,
       case when to_regclass('public.entry') is not null
             and to_regclass('public.entry_line') is not null
             and to_regclass('public.accounts') is not null
            then '✅ BOR' else '❌ YO''Q — bu Provodka bazasi emasmi?' end as natija
union all
select 'entry.filial_ids ustuni  [V6 xarajat metadata]',
       case when exists (select 1 from information_schema.columns
                          where table_schema='public' and table_name='entry' and column_name='filial_ids')
            then '✅ BOR — ai_rep_xarajat(kesim=filial) shundan hisoblaydi'
            else '⚠️ YO''Q — kesim=filial ok:false qaytaradi (sababi bilan), qolgan kesimlar ishlayveradi' end
union all
select 'accounts.subtitle / kassa_turi / pul_turi / section',
       case when (select count(*) from information_schema.columns
                   where table_schema='public' and table_name='accounts'
                     and column_name in ('subtitle','kassa_turi','pul_turi','section')) = 4
            then '✅ BOR' else '❌ YO''Q — PROVODKA_V6 / PROVODKA_VALYUTA ni RUN qiling' end
union all
select 'user_perms.filial_scope / filial_ids  [PROVODKA_FILIAL_PERM.sql]',
       case when exists (select 1 from information_schema.columns
                          where table_schema='public' and table_name='user_perms' and column_name='filial_scope')
            then '✅ BOR — filial kesimida ruxsat filtri ishlaydi'
            else '⚠️ YO''Q — filial cheklovi qollanmaydi (mijozda ham shunday: permFilterFilials scope=all deb ishlaydi)' end
union all
select 'v_kassa_card',
       case when to_regclass('public.v_kassa_card') is not null
            then '✅ BOR — 8-BOLIM (tirik sinov) shundan kassa oladi'
            else '⚠️ YO''Q — 8-BOLIM otkazib yuboriladi' end;

-- 0.4 Bu fayl ilgari RUN qilinganmi (yangi o'rnatishda hammasi "yo'q")
select 'ai_rep_yoq(text)' as obyekt,
       case when to_regprocedure('public.ai_rep_yoq(text)') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end as holat
union all
select 'ai_rep_davr(date,date)',
       case when to_regprocedure('public.ai_rep_davr(date,date)') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end
union all
select 'ai_rep_scope()',
       case when to_regprocedure('public.ai_rep_scope()') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end
union all
select 'ai_rep_filial_scope()',
       case when to_regprocedure('public.ai_rep_filial_scope()') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end
union all
select 'ai_rep_top(jsonb,int)',
       case when to_regprocedure('public.ai_rep_top(jsonb,int)') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end
union all
select 'ai_rep_xarajat(date,date,text)',
       case when to_regprocedure('public.ai_rep_xarajat(date,date,text)') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end
union all
select 'ai_rep_kirim(date,date,text)',
       case when to_regprocedure('public.ai_rep_kirim(date,date,text)') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end
union all
select 'ai_rep_cashflow(date,date)',
       case when to_regprocedure('public.ai_rep_cashflow(date,date)') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end
union all
select 'ai_rep_balans(date)',
       case when to_regprocedure('public.ai_rep_balans(date)') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end
union all
select 'ai_rep_jurnal(date,date,text,numeric,numeric)',
       case when to_regprocedure('public.ai_rep_jurnal(date,date,text,numeric,numeric)') is not null
            then 'allaqachon bor (qayta yoziladi)' else 'yo''q (yangi)' end;

-- 0.5 Sinov uchun material bormi (8-BO'LIM shularga tayanadi)
select 'admin foydalanuvchi' as tekshiruv,
       (select count(*) from profiles where role = 'admin')::text as soni,
       case when (select count(*) from profiles where role = 'admin') > 0
            then '✅ tirik sinov ishlaydi' else '⚠️ 8-BOLIM otkazib yuboriladi' end as natija
union all
select 'admin BO''LMAGAN foydalanuvchi',
       (select count(*) from profiles where coalesce(role,'user') <> 'admin')::text,
       case when (select count(*) from profiles where coalesce(role,'user') <> 'admin') > 0
            then '✅ tirik sinov ishlaydi' else '⚠️ 8-BOLIM otkazib yuboriladi' end
union all
select 'kassa (v_kassa_card, konteynersiz)',
       coalesce((select count(*)::text from v_kassa_card
                  where coalesce(kassa_turi,'') <> 'xarajat_guruh'), '0'),
       case when coalesce((select count(*) from v_kassa_card
                            where coalesce(kassa_turi,'') <> 'xarajat_guruh'), 0) >= 2
            then '✅ kamida 2 ta kerak edi' else '⚠️ 8-BOLIM otkazib yuboriladi' end;
-- ⬆⬆⬆  0-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  1-BO'LIM — ICHKI YORDAMCHILAR
-- #####################################################################
--  🔴 HAMMASI `anon` VA `authenticated` UCHUN YOPIQ. Ular faqat SECURITY
--     DEFINER RPC'lar ICHIDAN chaqiriladi — u yerda current_user egasi
--     bo'ladi va EXECUTE tekshiruvi egadan o'tadi. Ya'ni tashqi hujum
--     yuzasi kengaymaydi (PostgREST orqali chaqirib bo'lmaydi).
--
--  Ruxsat mantiqi BESH joyga ko'chirilmaydi — yagona manba `ai_rep_scope()`,
--  u esa `ai_ctx_perm()` ustiga quriladi (4-bosqich yadrosi qayta
--  yozilmaydi).

-- ⬇⬇⬇  1-BO'LIM: SHU QATORDAN 1-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇

-- 1.1 ai_rep_yoq — "ruxsat yo'q / bo'sh" javobining YAGONA shakli
--     ⚠️ Bo'sh javobda ham `columns`/`rows` BOR (bo'sh massiv) — EF va
--        mijoz shaklga tayanadi, `undefined` bo'lib qolmasin.
create or replace function ai_rep_yoq(p_sabab text)
returns jsonb
language sql
stable
set search_path = public
as $ai_yoq$
  select jsonb_build_object(
    'ok',        false,
    'sabab',     coalesce(p_sabab, 'Ruxsat yoq'),
    'ruxsat',    'yoq',
    'qamrov',    'yoq',
    'soni',      0,
    'jami',      null,
    'kesildi',   false,
    'columns',   '[]'::jsonb,
    'rows',      '[]'::jsonb,
    'qatorlar',  '[]'::jsonb);
$ai_yoq$;

revoke all on function ai_rep_yoq(text) from public, anon, authenticated;

comment on function ai_rep_yoq(text) is
  'ICHKI: AI hisobot RPClari uchun bosh/ruxsatsiz javobning yagona shakli (ok=false, columns/rows bosh).';


-- 1.2 ai_rep_davr — davrni normallashtirish (Toshkent kuni + maks 400 kun)
--     Sukut: p_to yo'q -> BUGUN (Asia/Tashkent), p_from yo'q -> OY BOSHI.
--     Teskari berilsa almashtiriladi. 400 kundan uzun bo'lsa XATO
--     BERILMAYDI — `d_from` qisqartiriladi va `qisqa=true` bo'ladi
--     (AI noto'g'ri davr haqida yolg'on xulosa chiqarmasin).
create or replace function ai_rep_davr(p_from date default null,
                                       p_to   date default null,
                                       out d_from date, out d_to date,
                                       out qisqa boolean, out maks_kun int)
language plpgsql
stable
set search_path = public
as $ai_davr$
declare
  v_tmp date;
begin
  maks_kun := 400;
  qisqa    := false;

  d_to   := coalesce(p_to, (now() at time zone 'Asia/Tashkent')::date);
  d_from := coalesce(p_from, date_trunc('month', d_to)::date);

  if d_from > d_to then
    v_tmp := d_from; d_from := d_to; d_to := v_tmp;
  end if;

  if (d_to - d_from) > maks_kun then
    d_from := d_to - maks_kun;
    qisqa  := true;
  end if;
end
$ai_davr$;

revoke all on function ai_rep_davr(date, date) from public, anon, authenticated;

comment on function ai_rep_davr(date, date) is
  'ICHKI: davr normallashtirish — sukut oy boshi..bugun (Asia/Tashkent), maks 400 kun (oshsa qisqartiriladi).';


-- 1.3 ai_rep_scope — "men qaysi pul hisoblarini KO'RA olaman"
--     🔴 Yadro qayta yozilmaydi: `ai_ctx_perm()` chaqiriladi.
--        rejim: yoq | admin | all | list  (4-bosqich semantikasi)
--     chek     = true  -> kassa cheklovi BOR (rejim 'list' yoki 'yoq')
--     pul_ids  = ko'rinadigan HAMMA pul hisobi (bola-hisoblar bilan)
--     root_ids = ko'rinadigan ILDIZ kassalar (cashflow_kassa uchun)
--     ⚠️ `chek=false` bo'lsa ikkovi ham NULL = "cheklov yo'q" (bo'sh
--        massiv "hech narsa" degani — ikkisi ARALASHTIRILMASIN).
create or replace function ai_rep_scope(out rejim text, out chek boolean,
                                        out pul_ids uuid[], out root_ids uuid[])
language plpgsql
stable
security definer
set search_path = public
as $ai_scope$
declare
  v_rejim text;
  v_ids   uuid[];
begin
  -- Fail-CLOSED sukut
  rejim    := 'yoq';
  chek     := true;
  pul_ids  := '{}'::uuid[];
  root_ids := '{}'::uuid[];

  if auth.uid() is null then
    return;
  end if;

  select p.rejim, p.kassa_ids into v_rejim, v_ids from ai_ctx_perm() p;
  rejim := coalesce(v_rejim, 'yoq');

  if rejim = 'yoq' then
    return;                              -- bo'sh, "hammasi" EMAS
  end if;

  if rejim <> 'list' then                -- admin | all -> cheklov yo'q
    chek     := false;
    pul_ids  := null;
    root_ids := null;
    return;
  end if;

  /* 🔴 SIZISH QOROVULINING MANBAI. `perm_view_pul_ids()` (PROVODKA_V8.sql)
     bilan bir xil qoida, ikki farq bilan:
       (a) u `auth.uid() is null` da NULL (= cheklovsiz) qaytaradi —
           fail-OPEN; bu yerda u holat yuqorida allaqachon 'yoq' bo'lib
           to'silgan (fail-CLOSED);
       (b) hisob tanlash sharti `section='pul'` (CLAUDE.md tasnifi),
           `code like '5%'` emas — kod prefiksi eski usul.
     Bola-hisoblar (56xx USD, naqd/click/payme) `perm_op_key()` orqali
     PARENT kassadan meros oladi — mijozdagi `keyOf()` bilan bir xil. */
  select coalesce(array_agg(a.id), '{}'::uuid[]) into pul_ids
    from accounts a
   where a.section = 'pul'
     and coalesce(a.kassa_turi, '') <> 'xarajat_guruh'
     and perm_op_key(a.id) = any(v_ids);

  /* Ildiz kassalar (cashflow_kassa oilani o'zi yig'adi).
     🔴 2026-08-15 TUZATISH — RUXSAT KENGAYISHI.
        Avval bu ro'yxat `v_ids` (xom `view_kassa_ids`) dan olinardi:
            where a.id = any(v_ids)   →  perm_op_key(a.id)
        Ya'ni ro'yxatda YOLG'IZ BOLA-hisob (masalan 5611 USD yoki Click bolasi)
        tursa, `perm_op_key` uni PARENT ga ko'tarib, `cashflow_kassa(parent)`
        BUTUN OILANING (parent UZS kassasi ham) kirim/chiqimini va qoldig'ini
        berardi. Mijozdagi `keyOf()`/`viewOk()` esa bunday holatda hech narsa
        ko'rsatmaydi — ya'ni AI UI dan KENGROQ ko'rardi.
        Endi manba `pul_ids`: u allaqachon `perm_op_key(a.id) = any(v_ids)`
        qoidasidan o'tgan, ya'ni yolg'iz bola holatida bo'sh bo'ladi va
        cashflow ham hech narsa bermaydi. `distinct` oilani ikki marta
        sanamaslik uchun qoladi. */
  select coalesce(array_agg(distinct perm_op_key(a.id)), '{}'::uuid[]) into root_ids
    from accounts a
   where a.id = any(pul_ids);

  chek := true;
end
$ai_scope$;

revoke all on function ai_rep_scope() from public, anon, authenticated;

comment on function ai_rep_scope() is
  'ICHKI: AI hisobot RPClari uchun kassa ruxsati. ai_ctx_perm() ustiga qurilgan; '
  'chek=false -> pul_ids/root_ids NULL (cheklovsiz), chek=true -> faqat view_kassa_ids oilasi.';


-- 1.4 ai_rep_filial_scope — xarajat FILIAL metadatasi bo'yicha ruxsat
--     Mijozdagi `permFilterFilials()` (perms.js) bilan bir xil qoida:
--     admin yoki filial_scope <> 'list' -> cheklov yo'q; aks holda
--     faqat `filial_ids`.
--     ⚠️ Ustun yo'q bo'lsa (PROVODKA_FILIAL_PERM.sql RUN qilinmagan)
--        cheklov QO'LLANMAYDI — mijozda ham shunday (`filial_scope`
--        kelmasa `permFilterFilials` hammasini o'tkazadi). Shuning uchun
--        o'qish DINAMIK: ustun yo'q bazada bu funksiya yiqilmasin.
create or replace function ai_rep_filial_scope(out chek boolean, out ids uuid[])
language plpgsql
stable
security definer
set search_path = public
as $ai_fsc$
declare
  v_uid   uuid;
  v_scope text;
  v_ids   uuid[];
begin
  chek := true;
  ids  := '{}'::uuid[];

  v_uid := auth.uid();
  if v_uid is null then
    return;                              -- fail-CLOSED
  end if;

  if is_admin() then
    chek := false; ids := null; return;
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'user_perms'
                    and column_name = 'filial_scope') then
    chek := false; ids := null; return;  -- ustun yo'q: mijoz bilan bir xil
  end if;

  execute 'select filial_scope, coalesce(filial_ids, ''{}''::uuid[]) from user_perms where user_id = $1'
    into v_scope, v_ids using v_uid;

  -- Qator yo'q (v_scope null) = my_perms() semantikasi: filial_scope 'all'
  if v_scope is distinct from 'list' then
    chek := false; ids := null; return;
  end if;

  chek := true;
  ids  := coalesce(v_ids, '{}'::uuid[]);
end
$ai_fsc$;

revoke all on function ai_rep_filial_scope() from public, anon, authenticated;

comment on function ai_rep_filial_scope() is
  'ICHKI: xarajat filial metadatasi (entry.filial_ids) uchun ruxsat — permFilterFilials() bilan bir xil qoida.';


-- 1.5 ai_rep_top — kesim qatorlarini CHART/EXCEL shakliga keltirish
--     Kirish: `p_all` = [{kod, nom, summa, ...}] (summa bo'yicha KAMAYISH
--     tartibida saralangan), `p_limit` = ko'rsatiladigan qator soni.
--     Chiqish: { soni, kesildi, jami, qatorlar, rows }
--
--     🔴 KESILGAN QATORLAR YO'QOLMAYDI: limitdan oshgani BITTA
--        "Boshqalar (N ta)" qatoriga yig'iladi. Shu tufayli
--        sum(rows) = jami — pie chart va Excel "Jami" qatori bir-biriga
--        mos keladi (aks holda AI 100% bo'lmagan doiraviy diagramma
--        chizib, farqni "yo'qolgan pul" deb izohlab qo'yardi).
--     ⚠️ `jami` — FAQAT ko'rinadigan qatorlar yig'indisi (begona kassa
--        puli chaqiruvchi so'rovda allaqachon chiqarib tashlangan).
create or replace function ai_rep_top(p_all jsonb, p_limit int default 40)
returns jsonb
language plpgsql
stable
set search_path = public
as $ai_top$
declare
  /* 🔴 `coalesce` YETARLI EMAS: jsonb 'null' (JSON null) SQL NULL EMAS —
     coalesce uni o'tkazib yuboradi va `jsonb_array_elements` "cannot extract
     elements from a scalar" (22023) bilan yiqiladi. Shuning uchun TUR
     tekshiriladi (2026-08-15 nosozligi). */
  v_all    jsonb := case when jsonb_typeof(p_all) = 'array' then p_all else '[]'::jsonb end;
  v_lim    int   := greatest(coalesce(p_limit, 40), 1);
  v_n      int;
  v_jami   numeric;
  v_qat    jsonb;
  v_rows   jsonb;
  v_qoldiq numeric;
  v_qsoni  int;
begin
  select count(*)::int, coalesce(sum((z.el ->> 'summa')::numeric), 0)
    into v_n, v_jami
    from jsonb_array_elements(v_all) as z(el);

  -- Top-N + har qatorga ulush foizi (pie chart uchun tayyor)
  select coalesce(jsonb_agg(
           jsonb_set(t.el, '{ulush}',
             to_jsonb(case when v_jami > 0
                           then round((t.el ->> 'summa')::numeric * 100 / v_jami, 1)
                           else 0::numeric end))
           order by t.ord), '[]'::jsonb)
    into v_qat
    from (select z.el, z.ord
            from jsonb_array_elements(v_all) with ordinality as z(el, ord)
           order by z.ord
           limit v_lim) t;

  if v_n > v_lim then
    select coalesce(sum((z.el ->> 'summa')::numeric), 0), count(*)::int
      into v_qoldiq, v_qsoni
      from jsonb_array_elements(v_all) with ordinality as z(el, ord)
     where z.ord > v_lim;

    v_qat := v_qat || jsonb_build_array(jsonb_build_object(
               'kod',   null,
               'nom',   'Boshqalar (' || v_qsoni::text || ' ta)',
               'summa', v_qoldiq,
               'ulush', case when v_jami > 0 then round(v_qoldiq * 100 / v_jami, 1)
                             else 0::numeric end));
  end if;

  -- rows: [yorliq, kod, raqam] — yorliq BIRINCHI, raqam OXIRGI ustun
  select coalesce(jsonb_agg(
           jsonb_build_array(z.el ->> 'nom', z.el ->> 'kod', (z.el ->> 'summa')::numeric)
           order by z.ord), '[]'::jsonb)
    into v_rows
    from jsonb_array_elements(v_qat) with ordinality as z(el, ord);

  return jsonb_build_object(
    'soni',     v_n,
    'kesildi',  v_n > v_lim,
    'jami',     v_jami,
    'qatorlar', v_qat,
    'rows',     v_rows);
end
$ai_top$;

revoke all on function ai_rep_top(jsonb, int) from public, anon, authenticated;

comment on function ai_rep_top(jsonb, int) is
  'ICHKI: kesim qatorlarini top-N + "Boshqalar (N ta)" + ulush foizi bilan chart/Excel shakliga keltiradi.';
-- ⬆⬆⬆  1-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  2-BO'LIM — ai_rep_xarajat(p_from, p_to, p_kesim) — XARAJAT / CHIQIM
-- #####################################################################
--  Sahifa qorovuli: 'hisobot'.  Kesimlar: xodim | kategoriya | filial.
--
--  MANBA MANTIQI (mavjud sahifalardan HARFMA-HARF):
--    'kategoriya' = hodim_kategoriya_hisobot()  (PROVODKA_HODIM_V4.sql 3.1)
--         accounts.type='xarajat' bo'yicha sum(entry_line.debit),
--         having sum(debit) > 0. `netto` (debit - credit) qo'shimcha
--         ustun sifatida yonida turadi (hisobot-dev.html P&L taqsimoti
--         aynan netto hisoblaydi — ikkalasi ochiq ko'rsatiladi).
--    'xodim'      = hodim_kassa_hisobot()       (PROVODKA_HODIM_V4.sql 3.2)
--         Kt tomoni section='pul' bo'lgan satrlar; yozuvda type='xarajat'
--         Dt satri bo'lishi SHART. Nomi "xodim" bo'lsa ham qatorda
--         markaziy/filial kassalar ham chiqadi — `kassa_turi` ustuni
--         ('xarajat' = hodim kassasi) bilan ajratiladi. Bu ATAYLAB:
--         mavjud CEO bloki ham aynan shunday ishlaydi, filtrlab tashlansa
--         jami kompaniya xarajatidan kam bo'lib qolardi.
--    'filial'     = standart_holat() naqshi     (PROVODKA_V7.sql 4.1)
--         `filial_id = any(entry.filial_ids)` — filial xarajatda
--         METADATA, kassa EMAS. `filial_ids` bo'sh yozuvlar
--         "Filial belgilanmagan" qatoriga yig'iladi (jimgina yo'qolmasin).
--         ⚠️ Bitta yozuvda BIR NECHTA filial bo'lsa summa har biriga
--         to'liq yoziladi (standart_holat ham shunday) — shuning uchun
--         bu kesimda `jami` boshqa kesimlardan katta bo'lishi mumkin.
--         `taqsimlangan: true` bayrog'i AI ga shuni aytadi.
--
--  🔴 RUXSAT — ikki qavat:
--     (a) sahifa: ai_ctx_has_page('hisobot');
--     (b) kassa: rejim 'list' bo'lsa faqat `view_kassa_ids` oilasidan
--         chiqqan pul ishtirok etgan yozuvlar sanaladi. 'xodim' kesimida
--         filtr QATORNING O'ZIGA (begona kassa qatori umuman chiqmaydi —
--         maskalash ham kerak emas), qolgan ikkisida YOZUVGA (Kt tomonida
--         ko'rinadigan kassa bo'lishi sharti) qo'yiladi.
--     ⚠️ Cheklangan user uchun natija admin ko'rgan raqamning QISM
--        to'plami bo'ladi — bu xato emas, `qamrov` maydonida ochiq
--        yozilgan. Cheklovsiz (admin/all) userda esa natija mavjud
--        sahifadagi CEO bloki bilan AYNAN bir xil.
--
--  `pnl_bolim` — hisobot-dev.html P&L zinapoyasi (`pnl()` o'raladi):
--     yalpi = TUSHUM - TANNARX; operatsion foyda = yalpi - OPERATSION;
--     sof = operatsion foyda - SOLIQ - BOSHQA  (renderLadder bilan bir xil).
--     🔴 FAQAT kesim='kategoriya' VA kassa cheklovi YO'Q bo'lganda
--        beriladi: P&L butun kompaniya raqami, uni kassa filtrlangan
--        qatorlar yoniga qo'yish 6-qoidani (begona pul yig'indiga
--        qo'shilmasin) buzardi. Aks holda `pnl_bolim: null` +
--        `pnl_sabab`.

-- ⬇⬇⬇  2-BO'LIM: SHU QATORDAN 2-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function ai_rep_xarajat(p_from  date default null,
                                          p_to    date default null,
                                          p_kesim text default 'xodim')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ai_xar$
declare
  v_limit constant int := 40;
  v_kesim text;
  v_rejim text;
  v_chek  boolean;
  v_ids   uuid[];
  v_roots uuid[];
  v_fchek boolean;
  v_fids  uuid[];
  v_from  date;
  v_to    date;
  v_qisqa boolean;
  v_maks  int;
  v_all   jsonb := '[]'::jsonb;
  v_top   jsonb;
  v_cols  jsonb;
  v_izoh  text;
  v_hasfil boolean;
  v_pnl    jsonb := null;
  v_pnl_sb text  := null;
  v_t   numeric; v_tn  numeric; v_op numeric; v_sol numeric; v_bos numeric;
  v_yal numeric; v_opf numeric; v_sof numeric;
begin
  -- 1-qavat: o'z qorovuli (auth.uid() null -> bo'sh, "hammasi" EMAS)
  if auth.uid() is null then
    return ai_rep_yoq('Avtorizatsiya yoq: bu RPC foydalanuvchi JWT si bilan chaqirilishi kerak (service_role bilan EMAS)');
  end if;

  -- 2-qavat: yagona ruxsat yadrosi (ai_ctx_perm ustida)
  select s.rejim, s.chek, s.pul_ids, s.root_ids
    into v_rejim, v_chek, v_ids, v_roots
    from ai_rep_scope() s;
  if v_rejim = 'yoq' then
    return ai_rep_yoq('Avtorizatsiya yoq');
  end if;

  -- 3-qavat: SAHIFA QOROVULI (fail-closed)
  if not ai_ctx_has_page('hisobot') then
    return ai_rep_yoq('Hisobot sahifasi ruxsatingizda yoq');
  end if;

  -- Kesim: faqat ruxsat etilgan qiymatlar
  v_kesim := lower(btrim(coalesce(p_kesim, 'xodim')));
  if v_kesim not in ('xodim', 'kategoriya', 'filial') then
    return ai_rep_yoq('Notogri kesim: ruxsat etilgan qiymatlar — xodim | kategoriya | filial');
  end if;

  select d.d_from, d.d_to, d.qisqa, d.maks_kun
    into v_from, v_to, v_qisqa, v_maks
    from ai_rep_davr(p_from, p_to) d;

  -- ------------------------------------------------------------------
  if v_kesim = 'kategoriya' then
    v_cols := jsonb_build_array('Xarajat moddasi', 'Kod', 'Summa');
    v_izoh := 'Xarajat moddalari (accounts.type=xarajat) boyicha davr jami. '
              || 'summa = sum(debit) — hisobot sahifasidagi CEO bloki (hodim_kategoriya_hisobot) bilan bir xil; '
              || 'netto = debit - credit (P&L taqsimoti shunday hisoblaydi). Faqat posted va ochirilmagan yozuvlar.';

    select coalesce(jsonb_agg(jsonb_build_object(
             'kod', x.kod, 'nom', x.nom, 'summa', x.summa, 'netto', x.netto)
             order by x.summa desc, x.kod), '[]'::jsonb)
      into v_all
      from (
        select a.code                                   as kod,
               a.name                                   as nom,
               round(sum(el.debit))::numeric            as summa,
               round(sum(el.debit - el.credit))::numeric as netto
          from entry_line el
          join entry    e on e.id = el.entry_id
          join accounts a on a.id = el.account_id
         where a.type = 'xarajat'
           and e.status = 'posted'
           and e.is_deleted = false
           and e.entry_date >= v_from
           and e.entry_date <= v_to
           -- 🔴 SIZISH QOROVULI: cheklangan userga faqat o'z kassasidan chiqqan pul
           and (not v_chek or exists (
                 select 1
                   from entry_line kl
                   join accounts   ka on ka.id = kl.account_id
                  where kl.entry_id = e.id
                    and kl.credit > 0
                    and ka.section = 'pul'
                    and kl.account_id = any(v_ids)))
           /* 🔴 2026-08-15 TUZATISH — SUMMA ORQALI SIZISH.
              Yuqoridagi qorovul YOZUV darajasida ("kamida bitta satr meniki"),
              summa esa butun yozuvniki. `professional.html` ko'p satrli yozuv
              yozadi: Dt Ijara 10 mln / Kt mening kassam 1 mln / Kt begona 9 mln
              → "Ijara" qatoriga 10 mln tushardi va 9 mln begona pul `jami`
              orqali sizardi (ustiga `xodim` kesimi 1 mln deb ZID raqam berardi).
              Yechim FAIL-CLOSED: yozuvda BEGONA pul satri bo'lsa u umuman
              hisobga olinmaydi. Ulushga bo'lish (pro-rata) ataylab tanlanmadi —
              u kam ko'rsatish o'rniga TAXMINIY raqam berardi. */
           and (not v_chek or not exists (
                 select 1
                   from entry_line kb
                   join accounts   kba on kba.id = kb.account_id
                  where kb.entry_id = e.id
                    and kb.credit > 0
                    and kba.section = 'pul'
                    and kb.account_id <> all(v_ids)))
         group by a.code, a.name
        having sum(el.debit) > 0
      ) x;

  -- ------------------------------------------------------------------
  elsif v_kesim = 'xodim' then
    v_cols := jsonb_build_array('Kassa / hodim', 'Kod', 'Summa');
    v_izoh := 'Qaysi kassadan (hodim / filial / markaziy) qancha xarajat qilingan. '
              || 'Kt tomoni pul, yozuvda xarajat moddasi (Dt) bor — hisobot sahifasidagi hodim_kassa_hisobot bilan bir xil. '
              || 'kassa_turi=xarajat — hodim kassasi. Faqat posted va ochirilmagan yozuvlar.';

    select coalesce(jsonb_agg(jsonb_build_object(
             'kod', x.kod, 'nom', x.nom, 'subtitle', x.sub,
             'kassa_turi', x.turi, 'summa', x.summa)
             order by x.summa desc, x.kod), '[]'::jsonb)
      into v_all
      from (
        select ka.code                        as kod,
               ka.name                        as nom,
               ka.subtitle                    as sub,
               coalesce(ka.kassa_turi, '-')   as turi,
               round(sum(kl.credit))::numeric as summa
          from entry_line kl
          join entry    e  on e.id = kl.entry_id
          join accounts ka on ka.id = kl.account_id and ka.section = 'pul'
         where kl.credit > 0
           and e.status = 'posted'
           and e.is_deleted = false
           and e.entry_date >= v_from
           and e.entry_date <= v_to
           -- 🔴 SIZISH QOROVULI: begona kassa QATORI umuman chiqmaydi
           and (not v_chek or kl.account_id = any(v_ids))
           and exists (
                 select 1
                   from entry_line dl
                   join accounts   da on da.id = dl.account_id
                  where dl.entry_id = e.id and dl.debit > 0 and da.type = 'xarajat')
         group by ka.code, ka.name, ka.subtitle, ka.kassa_turi
        having sum(kl.credit) > 0
      ) x;

  -- ------------------------------------------------------------------
  else   -- v_kesim = 'filial'
    select exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'entry'
                      and column_name = 'filial_ids')
      into v_hasfil;
    if not v_hasfil then
      return ai_rep_yoq('entry.filial_ids ustuni bazada yoq — xarajatning filial kesimi hisoblanmaydi (xodim yoki kategoriya kesimini ishlating)');
    end if;

    select f.chek, f.ids into v_fchek, v_fids from ai_rep_filial_scope() f;

    v_cols := jsonb_build_array('Filial', 'Kod', 'Summa');
    v_izoh := 'Xarajat filial METADATASI (entry.filial_ids) boyicha — standart_holat() bilan bir xil qoida. '
              || 'Bitta yozuv bir nechta filialga tegishli bolsa summa har biriga toliq yoziladi, '
              || 'shuning uchun bu kesimdagi jami boshqa kesimlardan katta bolishi mumkin. '
              || 'Filial belgilanmagan yozuvlar alohida qatorda.';

    select coalesce(jsonb_agg(jsonb_build_object(
             'kod', x.kod, 'nom', x.nom, 'summa', x.summa)
             order by x.summa desc, x.nom), '[]'::jsonb)
      into v_all
      from (
        select fa.code                                   as kod,
               coalesce(fa.name, 'Filial belgilanmagan')  as nom,
               round(sum(b.summa))::numeric              as summa
          from (
            select e.id,
                   e.filial_ids,
                   (select coalesce(sum(dl.debit), 0)
                      from entry_line dl
                      join accounts   da on da.id = dl.account_id
                     where dl.entry_id = e.id and dl.debit > 0 and da.type = 'xarajat') as summa
              from entry e
             where e.status = 'posted'
               and e.is_deleted = false
               and e.entry_date >= v_from
               and e.entry_date <= v_to
               -- 🔴 SIZISH QOROVULI (kassa darajasi)
               and (not v_chek or exists (
                     select 1
                       from entry_line kl
                       join accounts   ka on ka.id = kl.account_id
                      where kl.entry_id = e.id
                        and kl.credit > 0
                        and ka.section = 'pul'
                        and kl.account_id = any(v_ids)))
               -- 🔴 2026-08-15: begona pul satri bo'lgan yozuv umuman olinmaydi
               --    (yuqoridagi kategoriya kesimidagi bilan bir xil sabab)
               and (not v_chek or not exists (
                     select 1
                       from entry_line kb
                       join accounts   kba on kba.id = kb.account_id
                      where kb.entry_id = e.id
                        and kb.credit > 0
                        and kba.section = 'pul'
                        and kb.account_id <> all(v_ids)))
          ) b
          left join lateral unnest(coalesce(b.filial_ids, '{}'::uuid[])) as u(fid) on true
          left join accounts fa on fa.id = u.fid
         where b.summa > 0
           -- 🔴 FILIAL RUXSATI (permFilterFilials bilan bir xil).
           --    "Belgilanmagan" qatori (fid is null) qoladi: u aniq
           --    filial emas, kassa qorovulidan allaqachon otgan.
           and (not v_fchek or u.fid is null or u.fid = any(v_fids))
         group by fa.code, fa.name
      ) x;
  end if;

  -- ------------------------------------------------------------------
  -- Chart/Excel shakli (top-N + "Boshqalar" + ulush foizi)
  v_top := ai_rep_top(v_all, v_limit);

  -- P&L zinapoyasi — faqat kategoriya kesimi VA kassa cheklovi yo'q holat
  if v_kesim = 'kategoriya' and not v_chek then
    begin
      select coalesce(sum(p.amount) filter (where p.bolim = 'TUSHUM'),     0),
             coalesce(sum(p.amount) filter (where p.bolim = 'TANNARX'),    0),
             coalesce(sum(p.amount) filter (where p.bolim = 'OPERATSION'), 0),
             coalesce(sum(p.amount) filter (where p.bolim = 'SOLIQ'),      0),
             coalesce(sum(p.amount) filter (where p.bolim = 'BOSHQA'),     0)
        into v_t, v_tn, v_op, v_sol, v_bos
        from pnl(v_from, v_to) p;

      v_yal := v_t   - v_tn;
      v_opf := v_yal - v_op;
      v_sof := v_opf - v_sol - v_bos;

      v_pnl := jsonb_build_object(
        'columns', jsonb_build_array('Korsatkich', 'Summa'),
        'rows',    jsonb_build_array(
                     jsonb_build_array('Tushum',             round(v_t)),
                     jsonb_build_array('Tannarx',            round(v_tn)),
                     jsonb_build_array('Yalpi foyda',        round(v_yal)),
                     jsonb_build_array('Operatsion xarajat', round(v_op)),
                     jsonb_build_array('Operatsion foyda',   round(v_opf)),
                     jsonb_build_array('Boshqa',             round(v_bos)),
                     jsonb_build_array('Soliq',              round(v_sol)),
                     jsonb_build_array('Sof foyda',          round(v_sof))),
        'tushum',           round(v_t),
        'tannarx',          round(v_tn),
        'yalpi_foyda',      round(v_yal),
        'operatsion',       round(v_op),
        'operatsion_foyda', round(v_opf),
        'boshqa',           round(v_bos),
        'soliq',            round(v_sol),
        'sof_foyda',        round(v_sof),
        'izoh', 'pnl() RPC si oralgan — hisobot sahifasidagi P&L zinapoyasi bilan AYNAN bir xil (butun kompaniya).');
    exception when others then
      /* pnl() yo'q / xato berdi -> hisobot buzilmaydi.
         🔴 2026-08-15: `sqlerrm` XOM matni OLIB TASHLANDI. U modelga boradi,
            model esa uni foydalanuvchiga aytishi mumkin edi (masalan
            "permission denied for function pnl" — ichki tuzilma sizadi).
            EF ning boshqa yo'llarida xom Postgres matni ataylab to'silgan
            (`dbToolErrMsg`), bu yerda teshik qolgan edi.
            To'liq sabab RUN qiluvchi uchun serverda qoladi. */
      v_pnl    := null;
      v_pnl_sb := 'pnl() chaqirilmadi (server logiga qaralsin)';
      raise warning 'ai_rep_xarajat: pnl() xatosi: % [%]', sqlerrm, sqlstate;
    end;
  elsif v_kesim = 'kategoriya' then
    v_pnl_sb := 'Kassa cheklovi bor — P&L (butun kompaniya) korsatilmaydi';
  else
    v_pnl_sb := 'P&L faqat kategoriya kesimida beriladi';
  end if;

  return jsonb_build_object(
    'ok',       true,
    'ruxsat',   v_rejim,
    'qamrov',   case when v_chek then 'faqat ruxsatdagi kassalar' else 'hamma kassalar' end,
    'kesim',    v_kesim,
    'davr',     jsonb_build_object('from', v_from, 'to', v_to,
                                   'kunlar', (v_to - v_from),
                                   'maks_kun', v_maks,
                                   'qisqartirildi', v_qisqa),
    'soni',     v_top -> 'soni',
    'kesildi',  v_top -> 'kesildi',
    'jami',     v_top -> 'jami',
    'columns',  v_cols,
    'rows',     coalesce(v_top -> 'rows', '[]'::jsonb),
    'qatorlar', coalesce(v_top -> 'qatorlar', '[]'::jsonb),
    'taqsimlangan', (v_kesim = 'filial'),
    'filial_cheklangan', case when v_kesim = 'filial' then coalesce(v_fchek, false) else null end,
    'pnl_bolim', v_pnl,
    'pnl_sabab', v_pnl_sb,
    'izoh',     v_izoh);
end
$ai_xar$;

revoke all on function ai_rep_xarajat(date, date, text) from public, anon;
grant execute on function ai_rep_xarajat(date, date, text) to authenticated;

comment on function ai_rep_xarajat(date, date, text) is
  'AI hisobot: xarajat/chiqim kesimi (xodim | kategoriya | filial). Sahifa qorovuli hisobot, '
  'kassa filtri view_kassa_ids (perm_op_key). Mantiq hodim_kassa_hisobot / hodim_kategoriya_hisobot / '
  'standart_holat bilan bir xil. auth.uid() null -> bosh natija.';
-- ⬆⬆⬆  2-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  3-BO'LIM — ai_rep_kirim(p_from, p_to, p_kesim) — KIRIM
-- #####################################################################
--  Sahifa qorovuli: 'hisobot'.  Kesimlar: manba | filial.
--
--  KIRIM TA'RIFI — CLAUDE.md "Jurnal tasnifi — 4 holat" bilan bir xil:
--     Dt pul  va Kt pul EMAS  ->  KIRIM
--  Ya'ni tasnif `section='pul'` bo'yicha, kod prefiksi (5xxx) bilan EMAS.
--  Shu ta'rif tufayli KASSALARARO TRANSFER kirim deb sanalmaydi (Kt ham
--  pul) — `provodka.html` dagi `dir='kirim'` mantiqi ham aynan shunday
--  (Dt = kassa, Kt = "nimadan").
--
--    'manba'  -> Kt hisob (9010 savdo tushumi, 8000 ...). Bu 2-BO'LIMdagi
--                'xodim' kesimining KO'ZGUSI: u yerda Kt pul + Dt xarajat,
--                bu yerda Dt pul + Kt pul emas.
--    'filial' -> pul KIRGAN kassa. ⚠️ Provodka'da kirim uchun alohida
--                filial metadatasi YO'Q (`entry.filial_ids` faqat xarajat
--                uchun) — shuning uchun "filial" = qabul qilgan kassa.
--                Markaziy kassa ham qatorda turadi; `kassa_turi` ustuni
--                ('filial' | 'markaziy' | 'xarajat') bilan ajratiladi.
--                Filtrlab tashlanmadi: aks holda `jami` kompaniya
--                kirimidan kam bo'lib, AI "pul yo'qoldi" deb o'ylardi.
--
--  🔴 RUXSAT: sahifa ('hisobot') + kassa filtri. Ikkala kesimda ham filtr
--     PUL TOMONIGA qo'yiladi — ya'ni cheklangan user faqat O'Z kassasiga
--     tushgan pulni ko'radi, begona kassa qatori umuman chiqmaydi
--     (maskalash kerak emas: qator yo'q).

-- ⬇⬇⬇  3-BO'LIM: SHU QATORDAN 3-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function ai_rep_kirim(p_from  date default null,
                                        p_to    date default null,
                                        p_kesim text default 'manba')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ai_kir$
declare
  v_limit constant int := 40;
  v_kesim text;
  v_rejim text;
  v_chek  boolean;
  v_ids   uuid[];
  v_roots uuid[];
  v_from  date;
  v_to    date;
  v_qisqa boolean;
  v_maks  int;
  v_all   jsonb := '[]'::jsonb;
  v_top   jsonb;
  v_cols  jsonb;
  v_izoh  text;
begin
  if auth.uid() is null then
    return ai_rep_yoq('Avtorizatsiya yoq: bu RPC foydalanuvchi JWT si bilan chaqirilishi kerak (service_role bilan EMAS)');
  end if;

  select s.rejim, s.chek, s.pul_ids, s.root_ids
    into v_rejim, v_chek, v_ids, v_roots
    from ai_rep_scope() s;
  if v_rejim = 'yoq' then
    return ai_rep_yoq('Avtorizatsiya yoq');
  end if;

  -- 🔴 SAHIFA QOROVULI (fail-closed)
  if not ai_ctx_has_page('hisobot') then
    return ai_rep_yoq('Hisobot sahifasi ruxsatingizda yoq');
  end if;

  v_kesim := lower(btrim(coalesce(p_kesim, 'manba')));
  if v_kesim not in ('manba', 'filial') then
    return ai_rep_yoq('Notogri kesim: ruxsat etilgan qiymatlar — manba | filial');
  end if;

  select d.d_from, d.d_to, d.qisqa, d.maks_kun
    into v_from, v_to, v_qisqa, v_maks
    from ai_rep_davr(p_from, p_to) d;

  -- ------------------------------------------------------------------
  if v_kesim = 'manba' then
    v_cols := jsonb_build_array('Manba', 'Kod', 'Summa');
    v_izoh := 'Kirim manbasi (Kt hisob) boyicha davr jami. Kirim = Dt pul va Kt pul EMAS '
              || '(CLAUDE.md jurnal tasnifi) — kassalararo transfer bu yerga KIRMAYDI. '
              || 'Faqat posted va ochirilmagan yozuvlar.';

    select coalesce(jsonb_agg(jsonb_build_object(
             'kod', x.kod, 'nom', x.nom, 'tur', x.tur, 'summa', x.summa)
             order by x.summa desc, x.kod), '[]'::jsonb)
      into v_all
      from (
        select ka.code                        as kod,
               ka.name                        as nom,
               coalesce(ka.type, '-')         as tur,
               round(sum(kl.credit))::numeric as summa
          from entry_line kl
          join entry    e  on e.id = kl.entry_id
          join accounts ka on ka.id = kl.account_id
         where kl.credit > 0
           and ka.section is distinct from 'pul'     -- Kt pul EMAS (transfer chiqib ketadi)
           and e.status = 'posted'
           and e.is_deleted = false
           and e.entry_date >= v_from
           and e.entry_date <= v_to
           -- 🔴 SIZISH QOROVULI: pul TUSHGAN kassa ruxsatda bolishi shart
           and exists (
                 select 1
                   from entry_line dl
                   join accounts   da on da.id = dl.account_id
                  where dl.entry_id = e.id
                    and dl.debit > 0
                    and da.section = 'pul'
                    and (not v_chek or dl.account_id = any(v_ids)))
           /* 🔴 2026-08-15: kirim tomonida ham xuddi shu sizish — pul bir necha
              kassaga bo'lib tushgan bo'lsa (Dt meniki 1 mln / Dt begona 9 mln),
              manba qatoriga 10 mln tushardi. Begona kassaga tushgan yozuv
              butunlay chiqarib tashlanadi (fail-closed). */
           and (not v_chek or not exists (
                 select 1
                   from entry_line db
                   join accounts   dba on dba.id = db.account_id
                  where db.entry_id = e.id
                    and db.debit > 0
                    and dba.section = 'pul'
                    and db.account_id <> all(v_ids)))
         group by ka.code, ka.name, ka.type
        having sum(kl.credit) > 0
      ) x;

  -- ------------------------------------------------------------------
  else   -- v_kesim = 'filial'
    v_cols := jsonb_build_array('Kassa / filial', 'Kod', 'Summa');
    v_izoh := 'Pul KIRGAN kassa boyicha davr jami. Provodka da kirim uchun alohida filial '
              || 'metadatasi yoq (entry.filial_ids faqat xarajatda), shuning uchun filial = qabul qilgan kassa. '
              || 'kassa_turi ustuni: filial | markaziy | xarajat. Kassalararo transfer kirmaydi.';

    select coalesce(jsonb_agg(jsonb_build_object(
             'kod', x.kod, 'nom', x.nom, 'subtitle', x.sub,
             'kassa_turi', x.turi, 'summa', x.summa)
             order by x.summa desc, x.kod), '[]'::jsonb)
      into v_all
      from (
        select da.code                        as kod,
               da.name                        as nom,
               da.subtitle                    as sub,
               coalesce(da.kassa_turi, '-')   as turi,
               round(sum(dl.debit))::numeric  as summa
          from entry_line dl
          join entry    e  on e.id = dl.entry_id
          join accounts da on da.id = dl.account_id and da.section = 'pul'
         where dl.debit > 0
           and e.status = 'posted'
           and e.is_deleted = false
           and e.entry_date >= v_from
           and e.entry_date <= v_to
           -- 🔴 SIZISH QOROVULI: begona kassa QATORI umuman chiqmaydi
           and (not v_chek or dl.account_id = any(v_ids))
           -- Kt tomonida pul BO'LMAGAN hisob bo'lsin (transfer emas)
           and exists (
                 select 1
                   from entry_line kl
                   join accounts   ka on ka.id = kl.account_id
                  where kl.entry_id = e.id
                    and kl.credit > 0
                    and ka.section is distinct from 'pul')
         group by da.code, da.name, da.subtitle, da.kassa_turi
        having sum(dl.debit) > 0
      ) x;
  end if;

  v_top := ai_rep_top(v_all, v_limit);

  return jsonb_build_object(
    'ok',       true,
    'ruxsat',   v_rejim,
    'qamrov',   case when v_chek then 'faqat ruxsatdagi kassalar' else 'hamma kassalar' end,
    'kesim',    v_kesim,
    'davr',     jsonb_build_object('from', v_from, 'to', v_to,
                                   'kunlar', (v_to - v_from),
                                   'maks_kun', v_maks,
                                   'qisqartirildi', v_qisqa),
    'soni',     v_top -> 'soni',
    'kesildi',  v_top -> 'kesildi',
    'jami',     v_top -> 'jami',
    'columns',  v_cols,
    'rows',     coalesce(v_top -> 'rows', '[]'::jsonb),
    'qatorlar', coalesce(v_top -> 'qatorlar', '[]'::jsonb),
    'izoh',     v_izoh);
end
$ai_kir$;

revoke all on function ai_rep_kirim(date, date, text) from public, anon;
grant execute on function ai_rep_kirim(date, date, text) to authenticated;

comment on function ai_rep_kirim(date, date, text) is
  'AI hisobot: kirim kesimi (manba | filial). Kirim = Dt pul, Kt pul emas (jurnal tasnifi). '
  'Sahifa qorovuli hisobot, kassa filtri view_kassa_ids (perm_op_key). auth.uid() null -> bosh natija.';
-- ⬆⬆⬆  3-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  4-BO'LIM — ai_rep_cashflow(p_from, p_to) — PUL OQIMI
-- #####################################################################
--  Sahifa qorovuli: 'cashflow'.
--
--  🔴 MANTIQ QAYTA YOZILMAGAN — `cashflow-dev.html` ning AYNAN o'zi:
--       kirim/chiqim   -> cashflow_kassa(p_from, p_to, p_kassa)
--       davr boshi     -> pul_qoldiq_kassa(p_from - 1 kun, p_kassa)
--       davr oxiri     -> pul_qoldiq_kassa(p_to, p_kassa)
--       tekshiruv      -> (oxiri - boshi) = (kirim - chiqim)
--     ⚠️ Davr boshi "Dan" sanasidan BIR KUN OLDINGI qoldiq — sahifadagi
--        `prevDay(d1)` bilan bir xil. `p_from` ning o'zi olinsa o'sha
--        kundagi harakat ikki marta sanalardi.
--
--  🔴 KASSA QAMROVI (yagona joyda, `unnest` orqali):
--     • cheklov YO'Q (admin / kassa_scope='all') -> `p_kassa = null`, ya'ni
--       sahifadagi "Hamma kassalar" bilan AYNAN bir xil (kassalararo
--       transfer ichki harakat sifatida chiqib ketadi, net=0);
--     • cheklov BOR (kassa_scope='list') -> har RUXSATDAGI ILDIZ kassa
--       uchun alohida chaqirib yig'iladi (sahifada foydalanuvchi bitta
--       kassani tanlaganda ham shu yo'l ishlaydi).
--       ⚠️ Bunda MENING ikkita kassam orasidagi transfer birida KIRIM,
--          ikkinchisida CHIQIM bo'lib ko'rinadi. Bu xato EMAS va tekshiruv
--          tenglamasini BUZMAYDI (har oila uchun ham oqim, ham qoldiq
--          alohida to'g'ri). Javobdagi `izoh` buni ochiq aytadi.
--     Ikki shox bitta so'rovda: `unnest(coalesce(root_ids, array[null]))`
--     — cheklovsiz holatda massiv [null] bo'ladi va `cashflow_kassa` o'zi
--     eski `cashflow(..., null)` ga delegat qiladi.
--
--  🔴 MASKALASH: `cashflow_kassa` QARSHI tomon hisobini qaytaradi. Cheklangan
--     userda qarshi tomon BEGONA KASSA bo'lishi mumkin (markazga jo'natilgan
--     pul) — uning kodi va nomi chiqmaydi, hamma bunday qator BITTA
--     "Ruxsatdan tashqari kassa" qatoriga yig'iladi. Summa ko'rinadi: u
--     MENING kassamdan chiqqan/kirgan pul, uni bilishga haqim bor; sir
--     bo'lgani — narigi tomonning kimligi (ai_ctx_transfer bilan bir xil
--     tamoyil).

-- ⬇⬇⬇  4-BO'LIM: SHU QATORDAN 4-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function ai_rep_cashflow(p_from date default null,
                                           p_to   date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ai_cf$
declare
  v_limit constant int := 30;
  v_rejim text;
  v_chek  boolean;
  v_ids   uuid[];
  v_roots uuid[];
  v_from  date;
  v_to    date;
  v_qisqa boolean;
  v_maks  int;
  v_kirim   numeric := 0;
  v_chiqim  numeric := 0;
  v_boshi   numeric := 0;
  v_oxiri   numeric := 0;
  v_ozg     numeric := 0;
  v_farq    numeric := 0;
  v_kir_all jsonb := '[]'::jsonb;
  v_chi_all jsonb := '[]'::jsonb;
  v_kir_top jsonb;
  v_chi_top jsonb;
  v_acc     uuid[];
begin
  if auth.uid() is null then
    return ai_rep_yoq('Avtorizatsiya yoq: bu RPC foydalanuvchi JWT si bilan chaqirilishi kerak (service_role bilan EMAS)');
  end if;

  select s.rejim, s.chek, s.pul_ids, s.root_ids
    into v_rejim, v_chek, v_ids, v_roots
    from ai_rep_scope() s;
  if v_rejim = 'yoq' then
    return ai_rep_yoq('Avtorizatsiya yoq');
  end if;

  -- 🔴 SAHIFA QOROVULI (fail-closed)
  if not ai_ctx_has_page('cashflow') then
    return ai_rep_yoq('Pul oqimi (cashflow) sahifasi ruxsatingizda yoq');
  end if;

  select d.d_from, d.d_to, d.qisqa, d.maks_kun
    into v_from, v_to, v_qisqa, v_maks
    from ai_rep_davr(p_from, p_to) d;

  -- Chaqiriladigan kassalar: cheklovsizda [null] (= hamma kassalar)
  v_acc := coalesce(v_roots, array[null]::uuid[]);

  -- Cheklangan, lekin bitta ham ruxsatdagi kassa yo'q -> hammasi nol
  if v_chek and coalesce(array_length(v_acc, 1), 0) = 0 then
    v_acc := '{}'::uuid[];
  end if;

  -- --- Oqim (KIRIM / CHIQIM) — maskalash bilan ---
  with raw as (
    select t.yonalish, t.section, t.code, t.name, t.amount
      from unnest(v_acc) as u(acc)
      cross join lateral cashflow_kassa(v_from, v_to, u.acc) as t
  ),
  m as (
    select r.yonalish,
           -- 🔴 begona KASSA (pul hisobi, ruxsatda yo'q) -> yashiriladi
           coalesce(v_chek and coalesce(ac.section, '') = 'pul'
                    and not (ac.id = any(v_ids)), false) as yashir,
           r.section, r.code, r.name, r.amount
      from raw r
      -- ⚠️ `cashflow_kassa` faqat KOD qaytaradi (id emas) — hisobni kod
      --    bo'yicha topamiz. `limit 1`: kod takrorlansa ham qator
      --    ko'paymasin (dekart ko'paytma bo'lib summa ikkilanardi).
      left join lateral (
        select a2.id, a2.section from accounts a2 where a2.code = r.code limit 1
      ) ac on true
  ),
  g as (
    select m.yonalish,
           case when m.yashir then null         else m.code    end as kod,
           case when m.yashir then 'ruxsat yoq' else m.name    end as nom,
           case when m.yashir then null         else m.section end as bolim,
           round(sum(m.amount))::numeric                          as summa
      from m
     group by 1, 2, 3, 4
    having round(sum(m.amount)) <> 0
  )
  select
    coalesce(sum(g.summa) filter (where g.yonalish = 'KIRIM'),  0),
    coalesce(sum(g.summa) filter (where g.yonalish = 'CHIQIM'), 0),
    coalesce(jsonb_agg(jsonb_build_object('kod', g.kod, 'nom', g.nom,
                                          'bolim', g.bolim, 'summa', g.summa)
             order by g.summa desc) filter (where g.yonalish = 'KIRIM'), '[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('kod', g.kod, 'nom', g.nom,
                                          'bolim', g.bolim, 'summa', g.summa)
             order by g.summa desc) filter (where g.yonalish = 'CHIQIM'), '[]'::jsonb)
    into v_kirim, v_chiqim, v_kir_all, v_chi_all
    from g;

  -- --- Qoldiqlar (sahifadagi bilan bir xil: boshi = from - 1 kun) ---
  select coalesce(sum(pul_qoldiq_kassa(v_from - 1, u.acc)), 0)
    into v_boshi from unnest(v_acc) as u(acc);
  select coalesce(sum(pul_qoldiq_kassa(v_to, u.acc)), 0)
    into v_oxiri from unnest(v_acc) as u(acc);

  v_boshi := round(v_boshi);
  v_oxiri := round(v_oxiri);
  v_ozg   := v_kirim - v_chiqim;
  v_farq  := round(v_oxiri - v_boshi) - round(v_ozg);

  v_kir_top := ai_rep_top(v_kir_all, v_limit);
  v_chi_top := ai_rep_top(v_chi_all, v_limit);

  return jsonb_build_object(
    'ok',      true,
    'ruxsat',  v_rejim,
    'qamrov',  case when v_chek then 'faqat ruxsatdagi kassalar' else 'hamma kassalar' end,
    'davr',    jsonb_build_object('from', v_from, 'to', v_to,
                                  'kunlar', (v_to - v_from),
                                  'maks_kun', v_maks,
                                  'qisqartirildi', v_qisqa),
    'boshi',   v_boshi,
    'kirim',   v_kirim,
    'chiqim',  v_chiqim,
    'ozgarish', v_ozg,
    'oxiri',   v_oxiri,
    'tekshiruv', jsonb_build_object(
                   'farq', v_farq,
                   'ok',   (v_farq = 0),
                   'izoh', 'davr oxiri - davr boshi = kirim - chiqim (cashflow-dev.html dagi tekshiruv)'),
    -- 🔴 CHART/EXCEL uchun asosiy jadval
    'columns', jsonb_build_array('Korsatkich', 'Summa'),
    'rows',    jsonb_build_array(
                 jsonb_build_array('Davr boshi', v_boshi),
                 jsonb_build_array('Kirim',      v_kirim),
                 jsonb_build_array('Chiqim',     v_chiqim),
                 jsonb_build_array('Davr oxiri', v_oxiri)),
    'kirim_taqsimot', jsonb_build_object(
        'columns',  jsonb_build_array('Modda', 'Kod', 'Summa'),
        'rows',     coalesce(v_kir_top -> 'rows', '[]'::jsonb),
        'qatorlar', coalesce(v_kir_top -> 'qatorlar', '[]'::jsonb),
        'soni',     v_kir_top -> 'soni',
        'kesildi',  v_kir_top -> 'kesildi'),
    'chiqim_taqsimot', jsonb_build_object(
        'columns',  jsonb_build_array('Modda', 'Kod', 'Summa'),
        'rows',     coalesce(v_chi_top -> 'rows', '[]'::jsonb),
        'qatorlar', coalesce(v_chi_top -> 'qatorlar', '[]'::jsonb),
        'soni',     v_chi_top -> 'soni',
        'kesildi',  v_chi_top -> 'kesildi'),
    'izoh',    'Manba: cashflow_kassa() va pul_qoldiq_kassa() — cashflow sahifasining AYNAN oz RPClari. '
               || case when v_chek
                       then 'Faqat ruxsatdagi kassalar; ruxsatdan tashqari kassa nomi "ruxsat yoq" deb yashirilgan. '
                            || 'Diqqat: ikkita ruxsatdagi kassa orasidagi transfer birida kirim, ikkinchisida chiqim bolib korinadi.'
                       else 'Hamma kassalar boyicha; kassalararo transfer ichki harakat sifatida chiqib ketadi (net=0).' end);
end
$ai_cf$;

revoke all on function ai_rep_cashflow(date, date) from public, anon;
grant execute on function ai_rep_cashflow(date, date) to authenticated;

comment on function ai_rep_cashflow(date, date) is
  'AI hisobot: pul oqimi (kirim vs chiqim + davr boshi/oxiri qoldigi). cashflow_kassa() va '
  'pul_qoldiq_kassa() oraladi — cashflow sahifasi bilan bir xil. Sahifa qorovuli cashflow, '
  'kassa filtri view_kassa_ids. auth.uid() null -> bosh natija.';
-- ⬆⬆⬆  4-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  5-BO'LIM — ai_rep_balans(p_sana) — BALANS (aktiv / passiv / kapital)
-- #####################################################################
--  Sahifa qorovuli: 'balans'.
--
--  🔴 MANTIQ QAYTA YOZILMAGAN — `balans(p_date)` RPC si o'raladi
--     (`balans-dev.html` ning yagona manbasi). Yig'ish ham o'sha
--     sahifadagidek: AKTIV = bolim='AKTIV' yig'indisi (amortizatsiya
--     kontr-aktiv, MANFIY qator bo'lib turadi va shundayligicha
--     qo'shiladi), PASSIV tomoni = PASSIV + KAPITAL. `8710 Yigilgan sof
--     foyda` — `balans()` ichidagi sintetik qator, bu yerda hech narsa
--     qo'shilmaydi.
--
--  🔴🔴 KASSA FILTRI YO'Q — VA BU ATAYLAB.
--     `balans(p_date)` butun kompaniya hisoboti va hech qanday kassa
--     argumentini qabul qilmaydi; `balans.html` ham SAHIFA RUXSATI bilan
--     ochiladi va hamma hisob qoldig'ini ko'rsatadi. Ya'ni bu yerda
--     yagona qorovul — `ai_ctx_has_page('balans')`. Bu YANGI teshik EMAS:
--     UI da qanday bo'lsa, AI da ham shunday. Kimdir buni cheklamoqchi
--     bo'lsa — avval `balans.html` ni cheklashi kerak (mahsulot qarori),
--     keyin bu RPC ni. ⚠️ Shu sababli 8-BO'LIMdagi tirik sinov
--     `ai_rep_balans` javobida "begona kassa nomi yo'q" deb TEKSHIRMAYDI
--     — u yerda kassa nomlari BO'LISHI KERAK.

-- ⬇⬇⬇  5-BO'LIM: SHU QATORDAN 5-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function ai_rep_balans(p_sana date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ai_bal$
declare
  v_limit constant int := 80;
  v_rejim text;
  v_chek  boolean;
  v_ids   uuid[];
  v_roots uuid[];
  v_sana  date;
  v_aktiv   numeric := 0;
  v_passiv  numeric := 0;
  v_kapital numeric := 0;
  v_farq    numeric := 0;
  v_n       int     := 0;
  v_qat     jsonb   := '[]'::jsonb;
  v_rows    jsonb   := '[]'::jsonb;
  v_akt_t   jsonb   := '[]'::jsonb;
  v_pas_t   jsonb   := '[]'::jsonb;
  v_raw     jsonb   := '[]'::jsonb;
begin
  if auth.uid() is null then
    return ai_rep_yoq('Avtorizatsiya yoq: bu RPC foydalanuvchi JWT si bilan chaqirilishi kerak (service_role bilan EMAS)');
  end if;

  select s.rejim, s.chek, s.pul_ids, s.root_ids
    into v_rejim, v_chek, v_ids, v_roots
    from ai_rep_scope() s;
  if v_rejim = 'yoq' then
    return ai_rep_yoq('Avtorizatsiya yoq');
  end if;

  -- 🔴 SAHIFA QOROVULI — bu yerda YAGONA qorovul (yuqoridagi izohga qara)
  if not ai_ctx_has_page('balans') then
    return ai_rep_yoq('Balans sahifasi ruxsatingizda yoq');
  end if;

  v_sana := coalesce(p_sana, (now() at time zone 'Asia/Tashkent')::date);

  /* 🔴 MAVJUD RPC BIR MARTA chaqiriladi va natija jsonb ga olinadi.
     Busiz quyidagi to'rt hisob `balans(v_sana)` ni TO'RT MARTA ishga
     tushirardi — bir xil javob uchun to'rt barobar ish (va nazariy
     jihatdan to'rt xil natija, agar oradan yozuv kelib qolsa). */
  select coalesce(jsonb_agg(jsonb_build_object(
           'bolim',   b.bolim,
           'section', coalesce(b.section, 'boshqa'),
           'kod',     b.code,
           'nom',     b.name,
           'summa',   round(b.amount)::numeric)), '[]'::jsonb)
    into v_raw
    from balans(v_sana) b;

  -- Jami ko'rsatkichlar — HAMMA qatordan (kesilganidan emas)
  select coalesce(sum((z.el ->> 'summa')::numeric) filter (where z.el ->> 'bolim' = 'AKTIV'),   0),
         coalesce(sum((z.el ->> 'summa')::numeric) filter (where z.el ->> 'bolim' = 'PASSIV'),  0),
         coalesce(sum((z.el ->> 'summa')::numeric) filter (where z.el ->> 'bolim' = 'KAPITAL'), 0),
         count(*)::int
    into v_aktiv, v_passiv, v_kapital, v_n
    from jsonb_array_elements(v_raw) as z(el);

  v_aktiv   := round(v_aktiv);
  v_passiv  := round(v_passiv);
  v_kapital := round(v_kapital);
  v_farq    := v_aktiv - (v_passiv + v_kapital);

  -- Bo'lim (section) bo'yicha taqsimot — chart uchun
  select coalesce(jsonb_agg(jsonb_build_array(x.section, x.summa)
                            order by x.summa desc), '[]'::jsonb)
    into v_akt_t
    from (select z.el ->> 'section'                          as section,
                 sum((z.el ->> 'summa')::numeric)            as summa
            from jsonb_array_elements(v_raw) as z(el)
           where z.el ->> 'bolim' = 'AKTIV'
           group by z.el ->> 'section') x;

  select coalesce(jsonb_agg(jsonb_build_array(x.section, x.summa)
                            order by x.summa desc), '[]'::jsonb)
    into v_pas_t
    from (select (z.el ->> 'bolim') || ' / ' || (z.el ->> 'section') as section,
                 sum((z.el ->> 'summa')::numeric)                    as summa
            from jsonb_array_elements(v_raw) as z(el)
           where z.el ->> 'bolim' in ('PASSIV', 'KAPITAL')
           group by 1) x;

  -- Eng yirik qatorlar (modul bo'yicha) — AI ga tafsilot
  select coalesce(jsonb_agg(x.el order by x.tartib), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_array(x.el ->> 'nom', x.el ->> 'kod',
                                              (x.el ->> 'summa')::numeric)
                            order by x.tartib), '[]'::jsonb)
    into v_qat, v_rows
    from (
      select z.el,
             row_number() over (order by abs((z.el ->> 'summa')::numeric) desc,
                                         z.el ->> 'kod') as tartib
        from jsonb_array_elements(v_raw) as z(el)
       where (z.el ->> 'summa')::numeric <> 0
       order by abs((z.el ->> 'summa')::numeric) desc, z.el ->> 'kod'
       limit v_limit
    ) x;

  return jsonb_build_object(
    'ok',       true,
    'ruxsat',   v_rejim,
    'qamrov',   'butun kompaniya (balans kassa boyicha bolinmaydi)',
    'sana',     v_sana,
    'aktiv',    v_aktiv,
    'passiv',   v_passiv,
    'kapital',  v_kapital,
    'passiv_kapital', (v_passiv + v_kapital),
    'farq',     v_farq,
    'muvozanat', (v_farq = 0),
    'qator_soni', v_n,
    'kesildi',  (v_n > v_limit),
    -- 🔴 CHART/EXCEL uchun asosiy jadval
    'columns',  jsonb_build_array('Bolim', 'Summa'),
    'rows',     jsonb_build_array(
                  jsonb_build_array('AKTIV',   v_aktiv),
                  jsonb_build_array('PASSIV',  v_passiv),
                  jsonb_build_array('KAPITAL', v_kapital)),
    'aktiv_taqsimot',  jsonb_build_object('columns', jsonb_build_array('Bolim', 'Summa'),
                                          'rows',    v_akt_t),
    'passiv_taqsimot', jsonb_build_object('columns', jsonb_build_array('Bolim', 'Summa'),
                                          'rows',    v_pas_t),
    'qatorlar', v_qat,
    'qatorlar_columns', jsonb_build_array('Hisob', 'Kod', 'Summa'),
    'qatorlar_rows',    v_rows,
    'izoh',     'Manba: balans(p_date) RPC si — balans sahifasining AYNAN oz manbasi. '
                || 'AKTIV = debit-kredit (amortizatsiya kontr-aktiv, manfiy qator), PASSIV/KAPITAL = kredit-debit. '
                || 'sum(AKTIV) = sum(PASSIV)+sum(KAPITAL) matematik kafolat: farq 0 bolmasa bazada nomuvofiqlik bor. '
                || 'Balans butun kompaniya boyicha — kassa kesimi yoq, qorovul faqat sahifa ruxsati (UI da ham shunday).');
end
$ai_bal$;

revoke all on function ai_rep_balans(date) from public, anon;
grant execute on function ai_rep_balans(date) to authenticated;

comment on function ai_rep_balans(date) is
  'AI hisobot: balans sanaga (aktiv / passiv / kapital). balans(p_date) oraladi. '
  'Qorovul faqat sahifa ruxsati (balans) — hisobot butun kompaniya boyicha, kassa kesimi yoq. '
  'auth.uid() null -> bosh natija.';
-- ⬆⬆⬆  5-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  6-BO'LIM — ai_rep_jurnal(p_from, p_to, p_qidiruv, p_min, p_max)
-- #####################################################################
--  Sahifa qorovuli: 'jurnal'.
--
--  🔴 MANTIQ QAYTA YOZILMAGAN — `jurnal(...)` RPC si o'raladi
--     (`jurnal-dev.html` ning yagona manbasi). Chaqiruv NOMLANGAN
--     argumentlar bilan (CLAUDE.md: massiv parametri o'rtaga qo'shilgan,
--     pozitsiyaga tayanma):
--        jurnal(p_from => ..., p_to => ..., p_accounts => ...,
--               p_limit => ..., p_offset => 0)
--
--  🔴 RUXSAT (ikki qavat):
--     (a) sahifa: ai_ctx_has_page('jurnal');
--     (b) kassa: cheklangan userga `p_accounts` = ko'rinadigan pul
--         hisoblari -> yozuv umuman qaytmaydi, agar unda mening kassam
--         ishtirok etmagan bo'lsa. Ruxsatdagi kassa YO'Q bo'lsa (bo'sh
--         ro'yxat) `jurnal()` UMUMAN CHAQIRILMAYDI va bo'sh javob
--         qaytadi — bo'sh massivni `jurnal()` "filtr yo'q" deb talqin
--         qilib butun jurnalni berib yuborishi mumkin edi (uning tanasi
--         repoda yo'q, taxmin qilinmaydi: FAIL-CLOSED).
--
--  🔴 MASKALASH: qaytgan yozuvda qarshi tomon begona kassa bo'lishi
--     mumkin (transfer). Uning kodi/nomi 'ruxsat yoq' bilan almashadi VA
--     `izoh` butunlay olib tashlanadi — izohda odatda "Sergeli -> Toshkent"
--     deb kassa nomi turadi (ai_ctx_transfer bilan bir xil qoida).
--
--  ⚠️ O'CHIRILGAN yozuvlar (`is_deleted=true`) CHIQARIB TASHLANADI:
--     jurnal sahifasi ularni usti chizilgan holda ko'rsatadi, hisobot esa
--     hisobot (CLAUDE.md: balans faqat posted + o'chirilmagan).
--
--  ⚠️ QIDIRUV/SUMMA FILTRI — `jurnal()` dan keyin qo'llanadi (u faqat
--     sana + hisob bo'yicha filtrlaydi). Shuning uchun avval JRN_SCAN=500
--     ta eng yangi yozuv olinadi, keyin filtr, keyin 50 ta qaytadi.
--     Bu `jurnal-dev.html` bilan bir xil xatti-harakat (u ham tur/qidiruvni
--     MIJOZDA, faqat yuklangan qatorlarga qo'llaydi). Skan chegarasiga
--     yetilsa `toliq_emas: true` bo'ladi — AI "boshqa yo'q" deb yolg'on
--     aytmasin.
--
--  ⚠️ `p_qidiruv` — model/foydalanuvchi matni: `\`, `%`, `_` escape
--     qilinadi (`escape` bilan), uzunlik 60 belgiga kesiladi. SQL
--     injection yo'q (parametrli), lekin naqsh portlashi ham bo'lmasin.

-- ⬇⬇⬇  6-BO'LIM: SHU QATORDAN 6-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function ai_rep_jurnal(p_from    date    default null,
                                         p_to      date    default null,
                                         p_qidiruv text    default null,
                                         p_min     numeric default null,
                                         p_max     numeric default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ai_jrn$
declare
  v_limit constant int := 50;
  v_scan  constant int := 500;
  v_rejim text;
  v_chek  boolean;
  v_ids   uuid[];
  v_roots uuid[];
  v_from  date;
  v_to    date;
  v_qisqa boolean;
  v_maks  int;
  v_q     text;
  v_pat   text := null;
  v_qkes  boolean := false;
  v_min   numeric;
  v_max   numeric;
  v_tmp   numeric;
  v_raw   jsonb;
  v_olin  int := 0;
  v_qat   jsonb := '[]'::jsonb;
  v_rows  jsonb := '[]'::jsonb;
  v_n     int := 0;
  v_jami  numeric := 0;
begin
  if auth.uid() is null then
    return ai_rep_yoq('Avtorizatsiya yoq: bu RPC foydalanuvchi JWT si bilan chaqirilishi kerak (service_role bilan EMAS)');
  end if;

  select s.rejim, s.chek, s.pul_ids, s.root_ids
    into v_rejim, v_chek, v_ids, v_roots
    from ai_rep_scope() s;
  if v_rejim = 'yoq' then
    return ai_rep_yoq('Avtorizatsiya yoq');
  end if;

  -- 🔴 SAHIFA QOROVULI (fail-closed)
  if not ai_ctx_has_page('jurnal') then
    return ai_rep_yoq('Jurnal sahifasi ruxsatingizda yoq');
  end if;

  select d.d_from, d.d_to, d.qisqa, d.maks_kun
    into v_from, v_to, v_qisqa, v_maks
    from ai_rep_davr(p_from, p_to) d;

  -- Qidiruv naqshi: escape + uzunlik chegarasi
  v_q := nullif(btrim(coalesce(p_qidiruv, '')), '');
  if v_q is not null then
    if length(v_q) > 60 then
      v_q    := left(v_q, 60);
      v_qkes := true;
    end if;
    v_pat := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  -- Summa oralig'i (teskari berilsa almashtiriladi)
  v_min := p_min;
  v_max := p_max;
  if v_min is not null and v_max is not null and v_min > v_max then
    v_tmp := v_min; v_min := v_max; v_max := v_tmp;
  end if;

  -- 🔴 FAIL-CLOSED: cheklangan, lekin ruxsatdagi kassa yo'q -> jurnal()
  --    UMUMAN chaqirilmaydi (bo'sh massiv "filtrsiz" deb talqin qilinmasin)
  if v_chek and coalesce(array_length(v_ids, 1), 0) = 0 then
    return jsonb_build_object(
      'ok', true, 'ruxsat', v_rejim, 'qamrov', 'faqat ruxsatdagi kassalar',
      'davr', jsonb_build_object('from', v_from, 'to', v_to,
                                 'kunlar', (v_to - v_from),
                                 'maks_kun', v_maks, 'qisqartirildi', v_qisqa),
      'soni', 0, 'jami', 0, 'kesildi', false, 'toliq_emas', false,
      'columns', jsonb_build_array('Sana', 'Izoh', 'Dt', 'Kt', 'Summa'),
      'rows', '[]'::jsonb, 'qatorlar', '[]'::jsonb,
      'izoh', 'Ruxsatingizda birorta kassa yoq — jurnal yozuvlari korsatilmaydi.');
  end if;

  -- 🔴 MAVJUD RPC O'RALADI (qayta yozilmaydi)
  select jurnal(p_from     => v_from,
                p_to       => v_to,
                p_accounts => v_ids,
                p_limit    => v_scan,
                p_offset   => 0)
    into v_raw;

  /* 🔴 TUR TEKSHIRUVI (2026-08-15): `jurnal()` massiv qaytaradi, lekin
     kontrakt o'zgarsa (obyekt/skalyar/JSON null) `coalesce` uni ushlamaydi va
     `jsonb_array_length` 22023 bilan yiqilardi. Fail-closed: bo'sh ro'yxat. */
  v_raw  := case when jsonb_typeof(v_raw) = 'array' then v_raw else '[]'::jsonb end;
  v_olin := jsonb_array_length(v_raw);

  with j as (
    select (z.el ->> 'entry_date')::date                     as sana,
           coalesce(z.el ->> 'description', '')              as izoh,
           /* 🔴 FAIL-CLOSED (2026-08-15): kalit yo'q bo'lsa "o'chirilgan" deb
              hisoblanadi. Avval `false` edi — `jurnal()` kontrakti o'zgarib
              `is_deleted` nomi almashsa soft-delete qilingan yozuvlar jimgina
              chiqib ketardi. Endi teskarisi: shubha bo'lsa KO'RSATMAYMIZ. */
           coalesce((z.el ->> 'is_deleted')::boolean, true)  as ochirilgan,
           -- 🔴 tur tekshiruvi: `lines` JSON null bo'lsa coalesce ushlamaydi
           case when jsonb_typeof(z.el -> 'lines') = 'array'
                then z.el -> 'lines' else '[]'::jsonb end    as lines
      from jsonb_array_elements(v_raw) as z(el)
  ),
  x as (
    select j.sana, j.izoh, j.lines,
           (select coalesce(sum((l ->> 'debit')::numeric), 0)
              from jsonb_array_elements(j.lines) as l)                    as summa,
           (select count(*)::int from jsonb_array_elements(j.lines) as l) as n_lines,
           (select l from jsonb_array_elements(j.lines) as l
             order by (l ->> 'debit')::numeric desc nulls last limit 1)   as dt,
           (select l from jsonb_array_elements(j.lines) as l
             order by (l ->> 'credit')::numeric desc nulls last limit 1)  as kt,
           /* 🔴 SHAKL QOROVULI (fail-closed, 2026-08-15).
              Maskalash `jurnal()` javobidagi `section` va `account_id`
              kalitlariga tayanadi. Ular yo'q/nomi o'zgargan bo'lsa avvalgi
              kod `false` (= begona emas) deb hisoblab, BEGONA KASSA NOMINI
              OCHIQ ko'rsatardi — ya'ni RPC kontrakti o'zgarganda himoya
              JIMGINA ochilardi. Endi: shubha bo'lsa MASKALANADI.
              Satr yo'q (bo'sh `lines`) — ham shubhali (tekshirib bo'lmaydi). */
           (select coalesce(bool_or(l ->> 'account_id' is null
                                 or l ->> 'section'    is null
                                 or l ->> 'account_id' !~ '^[0-9a-fA-F-]{36}$'), true)
              from jsonb_array_elements(j.lines) as l)                    as shubha,
           -- yozuvda MENGA ochiq bo'lmagan pul satri bormi
           coalesce((select bool_or(coalesce(l ->> 'section', '') = 'pul'
                                    and not (case
                                      when l ->> 'account_id' ~ '^[0-9a-fA-F-]{36}$'
                                      then (l ->> 'account_id')::uuid = any(v_ids)
                                      else false end))
                       from jsonb_array_elements(j.lines) as l), true)    as begona_raw
      from j
     where not j.ochirilgan
  ),
  f as (
    select x.*,
           -- shakl shubhali bo'lsa ham maskalanadi (kalit o'zgarsa himoya ochilmasin)
           case when v_chek then coalesce(x.begona_raw or x.shubha, true) else false end as begona,
           x.shubha as shakl_shubha
      from x
     where (v_pat is null
            or x.izoh ilike v_pat escape '\'
            or exists (select 1 from jsonb_array_elements(x.lines) as l
                        where coalesce(l ->> 'name', '') ilike v_pat escape '\'
                           or coalesce(l ->> 'code', '') ilike v_pat escape '\'))
       and (v_min is null or x.summa >= v_min)
       and (v_max is null or x.summa <= v_max)
  ),
  r as (
    select f.sana,
           round(f.summa)::numeric as summa,
           f.n_lines,
           f.begona,
           /* 🔴 Bu yerda ham FAIL-CLOSED (2026-08-15): `account_id` yo'q bo'lsa
              `NULL::uuid = any(...)` → NULL → `not NULL` → NULL, va
              `case when NULL then ... else kod end` KODNI KO'RSATARDI.
              Endi shakl shubhali bo'lsa → `true` (maskalanadi). */
           (v_chek and coalesce(
              case when f.dt ->> 'account_id' ~ '^[0-9a-fA-F-]{36}$'
                    and f.dt ->> 'section' is not null
                   then (f.dt ->> 'section') = 'pul'
                        and not ((f.dt ->> 'account_id')::uuid = any(v_ids))
                   else true end, true))                        as dt_y,
           (v_chek and coalesce(
              case when f.kt ->> 'account_id' ~ '^[0-9a-fA-F-]{36}$'
                    and f.kt ->> 'section' is not null
                   then (f.kt ->> 'section') = 'pul'
                        and not ((f.kt ->> 'account_id')::uuid = any(v_ids))
                   else true end, true))                        as kt_y,
           f.dt, f.kt, f.izoh, f.shakl_shubha
      from f
  ),
  q as (
    select r.sana,
           case when r.dt_y then null         else r.dt ->> 'code' end as dt_kod,
           case when r.dt_y then 'ruxsat yoq' else r.dt ->> 'name' end as dt_nom,
           case when r.kt_y then null         else r.kt ->> 'code' end as kt_kod,
           case when r.kt_y then 'ruxsat yoq' else r.kt ->> 'name' end as kt_nom,
           r.summa,
           -- izohda kassa nomi turadi: bir tomon yashirin bo'lsa izoh ham yashiriladi
           case when r.begona then null else left(r.izoh, 160) end as izoh,
           case when r.n_lines > 2                                          then 'boshqa'
                when coalesce(r.dt ->> 'section', '') = 'pul'
                 and coalesce(r.kt ->> 'section', '') = 'pul'               then 'transfer'
                when coalesce(r.dt ->> 'section', '') = 'pul'               then 'kirim'
                when coalesce(r.kt ->> 'section', '') = 'pul'               then 'chiqim'
                else 'neytral' end as tur,
           r.begona as maskalangan,
           /* Shakl qorovuli ishlaganini modelga ochiq aytamiz: "ma'lumot yo'q"
              deb emas, "kontrakt o'zgargan, shuning uchun yashirildi" deb
              tushuntirsin (jimgina kam ko'rsatish ham xato manbai). */
           r.shakl_shubha as shakl_shubhali
      from r
     order by r.sana desc, r.summa desc
     limit v_limit
  )
  select coalesce(jsonb_agg(to_jsonb(q) order by q.sana desc, q.summa desc), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_array(
                    to_char(q.sana, 'YYYY-MM-DD'),
                    coalesce(q.izoh, ''),
                    btrim(coalesce(q.dt_kod, '') || ' ' || coalesce(q.dt_nom, '')),
                    btrim(coalesce(q.kt_kod, '') || ' ' || coalesce(q.kt_nom, '')),
                    q.summa)
                  order by q.sana desc, q.summa desc), '[]'::jsonb),
         count(*)::int,
         coalesce(sum(q.summa), 0)
    into v_qat, v_rows, v_n, v_jami
    from q;

  return jsonb_build_object(
    'ok',      true,
    'ruxsat',  v_rejim,
    'qamrov',  case when v_chek then 'faqat ruxsatdagi kassalar' else 'hamma kassalar' end,
    'davr',    jsonb_build_object('from', v_from, 'to', v_to,
                                  'kunlar', (v_to - v_from),
                                  'maks_kun', v_maks,
                                  'qisqartirildi', v_qisqa),
    'filtr',   jsonb_build_object('qidiruv', v_q, 'qidiruv_kesildi', v_qkes,
                                  'min', v_min, 'max', v_max),
    'skan',    jsonb_build_object('olingan', v_olin, 'chegara', v_scan),
    'soni',    v_n,
    'jami',    v_jami,
    'kesildi', (v_n >= v_limit),
    'toliq_emas', (v_olin >= v_scan),
    -- 🔴 CHART/EXCEL uchun jadval
    'columns', jsonb_build_array('Sana', 'Izoh', 'Dt', 'Kt', 'Summa'),
    'rows',    v_rows,
    'qatorlar', v_qat,
    'izoh',    'Manba: jurnal() RPC si oralgan (jurnal sahifasining ayni manbasi). Ochirilgan yozuvlar chiqarilgan. '
               || 'tur — jurnal tasnifi (transfer | kirim | chiqim | neytral | boshqa), section=pul boyicha. '
               || case when v_chek
                       then 'Ruxsatdan tashqari kassa "ruxsat yoq" deb yashirilgan va bunday yozuvning izohi berilmaydi. '
                       else '' end
               || case when v_olin >= v_scan
                       then 'DIQQAT: skan chegarasiga yetildi — davr ichida boshqa yozuvlar ham bor, hammasi emas.'
                       else '' end);
end
$ai_jrn$;

revoke all on function ai_rep_jurnal(date, date, text, numeric, numeric) from public, anon;
grant execute on function ai_rep_jurnal(date, date, text, numeric, numeric) to authenticated;

comment on function ai_rep_jurnal(date, date, text, numeric, numeric) is
  'AI hisobot: jurnal yozuvlari (maks 50). jurnal() RPC si oraladi; qidiruv/summa filtri keyin qollanadi. '
  'Sahifa qorovuli jurnal, kassa filtri view_kassa_ids, begona tomon maskalanadi. auth.uid() null -> bosh natija.';
-- ⬆⬆⬆  6-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  7-BO'LIM — STATIK TEKSHIRUV.  HECH NARSA YOZMAYDI.
-- #####################################################################
--  🔴 Nomuvofiqlik JIMGINA O'TMAYDI — `raise exception` bilan to'xtaydi.
--  Har RPC uchun tekshiriladi:
--     1) mavjud;                       5) `anon` da EXECUTE yo'q,
--     2) SECURITY DEFINER;                `authenticated` da BOR;
--     3) STABLE (yozmaydigan);         6) tanasida `auth.uid()` bor;
--     4) `set search_path = public`;   7) FOYDALANUVCHI ID ARGUMENTI YO'Q;
--     8) tanasida insert/update/delete yo'q (faqat o'qish);
--     9) `ai_ctx_has_page(...)` chaqiruvi bor VA KALITI TO'G'RI;
--    10) kassa kesimi bor RPC'larda `ai_rep_scope()` chaqiruvi bor
--        (balans — ataylab ISTISNO, izohi 5-BO'LIMda);
--    11) 🔴 MAVJUD RPC HAQIQATAN O'RALGANMI (ikki haqiqat bo'lmasin):
--        ai_rep_balans -> balans(...), ai_rep_cashflow -> cashflow_kassa()
--        va pul_qoldiq_kassa(), ai_rep_jurnal -> jurnal(p_from ...).

-- ⬇⬇⬇  7-BO'LIM: SHU QATORDAN 7-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
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
  v_pair  text[];
begin
  -- 7.0 OLD SHART: 4-bosqich yadrosi joyidami
  foreach v_sig in array array['public.ai_ctx_perm()', 'public.ai_ctx_has_page(text)'] loop
    if to_regprocedure(v_sig) is null then
      raise exception '% YOQ — 🔴 AVVAL PROVODKA_AI_KONTEKST.sql ni RUN QILING (bu fayl unga tayanadi)', v_sig;
    end if;
  end loop;

  -- 7.1 Ichki yordamchilar: mavjud + tashqi rollarga YOPIQ
  foreach v_sig in array array['public.ai_rep_yoq(text)', 'public.ai_rep_davr(date,date)',
                               'public.ai_rep_scope()', 'public.ai_rep_filial_scope()',
                               'public.ai_rep_top(jsonb,int)'] loop
    if to_regprocedure(v_sig) is null then
      raise exception 'Ichki yordamchi YARATILMADI: % — 1-BOLIMni RUN qiling', v_sig;
    end if;
    if exists (select 1 from pg_roles where rolname = 'anon')
       and has_function_privilege('anon', to_regprocedure(v_sig)::oid, 'execute') then
      raise exception '% anon uchun ochiq qolgan', v_sig;
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated')
       and has_function_privilege('authenticated', to_regprocedure(v_sig)::oid, 'execute') then
      raise exception '% authenticated uchun ochiq — u faqat DEFINER RPClar ichidan chaqirilishi kerak', v_sig;
    end if;
    select p.provolatile into v_vol from pg_proc p where p.oid = to_regprocedure(v_sig)::oid;
    if v_vol not in ('s', 'i') then
      raise exception '% STABLE/IMMUTABLE emas (volatile=%) — u faqat oqishi kerak', v_sig, v_vol;
    end if;
  end loop;

  -- Ruxsat o'qiydigan ikki yordamchi SECURITY DEFINER bo'lishi SHART
  foreach v_sig in array array['public.ai_rep_scope()', 'public.ai_rep_filial_scope()'] loop
    select p.prosecdef into v_def from pg_proc p where p.oid = to_regprocedure(v_sig)::oid;
    if not v_def then
      raise exception '% SECURITY DEFINER emas — user_perms ni oqiy olmaydi', v_sig;
    end if;
  end loop;

  -- 7.2 Beshala ochiq RPC
  foreach v_sig in array array['public.ai_rep_xarajat(date,date,text)',
                               'public.ai_rep_kirim(date,date,text)',
                               'public.ai_rep_cashflow(date,date)',
                               'public.ai_rep_balans(date)',
                               'public.ai_rep_jurnal(date,date,text,numeric,numeric)'] loop
    v_oid := to_regprocedure(v_sig)::oid;
    if v_oid is null then
      raise exception 'RPC YARATILMADI: % — 2/3/4/5/6-BOLIMni RUN qiling', v_sig;
    end if;

    select p.prosecdef, p.provolatile, p.proconfig, p.prosrc
      into v_def, v_vol, v_cfg, v_src
      from pg_proc p where p.oid = v_oid;

    v_args := lower(pg_get_function_arguments(v_oid));
    v_body := lower(v_src);

    if not v_def then
      raise exception '% SECURITY DEFINER emas — ruxsat mantigi ishlamaydi', v_sig;
    end if;
    if v_vol <> 's' then
      raise exception '% STABLE emas (volatile=%) — u faqat oqishi kerak', v_sig, v_vol;
    end if;
    if v_cfg is null or not ('search_path=public' = any(v_cfg)) then
      raise exception '% da "set search_path = public" yoq — DEFINER funksiyada MAJBURIY', v_sig;
    end if;
    if exists (select 1 from pg_roles where rolname = 'anon')
       and has_function_privilege('anon', v_oid, 'execute') then
      raise exception '% anon uchun OCHIQ qolgan — REVOKE ishlamagan!', v_sig;
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated')
       and not has_function_privilege('authenticated', v_oid, 'execute') then
      raise exception '% authenticated uchun YOPIQ — Edge Function chaqira olmaydi', v_sig;
    end if;
    if position('auth.uid()' in v_body) = 0 then
      raise exception '% tanasida auth.uid() YOQ — kim sorayotgani qayerdan bilinadi?', v_sig;
    end if;

    -- FOYDALANUVCHI ID ARGUMENTI TAQIQ (can_see_project saboqi)
    if position('uuid' in v_args) > 0 then
      raise exception '% da uuid argument bor (%) — begona id bilan chaqirish yoli ochiladi', v_sig, v_args;
    end if;
    if v_args ~ '(user|uid|_id)' then
      raise exception '% argument nomi shubhali (%) — foydalanuvchi id argumenti TAQIQ', v_sig, v_args;
    end if;

    -- Faqat o'qish
    if v_body ~ '(^|[^a-z_])(insert|update|delete)[[:space:]]+(into|from|[a-z_]+[[:space:]]+set)' then
      raise exception '% tanasida YOZUV amali bor — bu RPClar faqat select bolishi kerak', v_sig;
    end if;

    -- Sahifa qorovuli har birida bo'lsin
    if position('ai_ctx_has_page' in v_body) = 0 then
      raise exception '% ichida ai_ctx_has_page() yoq — sahifa ruxsati tekshirilmayapti', v_sig;
    end if;
  end loop;

  -- 7.3 Sahifa KALITI to'g'rimi (noto'g'ri kalit = boshqa sahifaning ruxsati)
  foreach v_pair slice 1 in array array[
      ['public.ai_rep_xarajat(date,date,text)',                'hisobot'],
      ['public.ai_rep_kirim(date,date,text)',                  'hisobot'],
      ['public.ai_rep_cashflow(date,date)',                    'cashflow'],
      ['public.ai_rep_balans(date)',                           'balans'],
      ['public.ai_rep_jurnal(date,date,text,numeric,numeric)', 'jurnal']] loop
    select lower(prosrc) into v_body from pg_proc where oid = to_regprocedure(v_pair[1])::oid;
    if position('ai_ctx_has_page(''' || v_pair[2] || ''')' in v_body) = 0 then
      raise exception '% notogri sahifa kalitini tekshiryapti — % bolishi kerak', v_pair[1], v_pair[2];
    end if;
  end loop;

  -- 7.4 Kassa qorovuli: ai_rep_scope() (balans ATAYLAB istisno)
  foreach v_sig in array array['public.ai_rep_xarajat(date,date,text)',
                               'public.ai_rep_kirim(date,date,text)',
                               'public.ai_rep_cashflow(date,date)',
                               'public.ai_rep_jurnal(date,date,text,numeric,numeric)'] loop
    select lower(prosrc) into v_body from pg_proc where oid = to_regprocedure(v_sig)::oid;
    if position('ai_rep_scope' in v_body) = 0 then
      raise exception '% ichida ai_rep_scope() yoq — kassa ruxsati tekshirilmayapti', v_sig;
    end if;
  end loop;

  -- Yadro qayta yozilmaganini tasdiqlash: ruxsat ai_ctx_perm dan olinadi
  select lower(prosrc) into v_body from pg_proc where oid = to_regprocedure('public.ai_rep_scope()')::oid;
  if position('ai_ctx_perm' in v_body) = 0 then
    raise exception 'ai_rep_scope ai_ctx_perm() ni chaqirmayapti — ruxsat yadrosi ikkiga bolinib ketgan';
  end if;
  if position('perm_op_key' in v_body) = 0 then
    raise exception 'ai_rep_scope ichida perm_op_key() yoq — valyuta/pul turi bola-hisoblari ruxsatdan chetda qolardi';
  end if;
  if position('op_kassa_ids' in v_body) > 0 then
    raise exception 'ai_rep_scope op_kassa_ids ni ishlatyapti — AI faqat OQIYDI, kalit view_kassa_ids bolishi kerak';
  end if;

  -- 7.5 🔴 MAVJUD RPC HAQIQATAN O'RALGANMI (ikki haqiqat bo'lmasin)
  select lower(prosrc) into v_body from pg_proc where oid = to_regprocedure('public.ai_rep_balans(date)')::oid;
  if position('from balans(' in v_body) = 0 then
    raise exception 'ai_rep_balans balans() RPC sini oramayapti — mantiq nusxa kochirilgan bolsa IKKI HAQIQAT paydo boladi';
  end if;

  select lower(prosrc) into v_body from pg_proc where oid = to_regprocedure('public.ai_rep_cashflow(date,date)')::oid;
  if position('cashflow_kassa(' in v_body) = 0 or position('pul_qoldiq_kassa(' in v_body) = 0 then
    raise exception 'ai_rep_cashflow cashflow_kassa()/pul_qoldiq_kassa() ni oramayapti — cashflow sahifasi bilan raqam farq qilib ketardi';
  end if;

  select lower(prosrc) into v_body from pg_proc where oid = to_regprocedure('public.ai_rep_jurnal(date,date,text,numeric,numeric)')::oid;
  if position('jurnal(p_from' in v_body) = 0 then
    raise exception 'ai_rep_jurnal jurnal() RPC sini oramayapti (nomlangan argument bilan chaqirilishi kerak)';
  end if;

  -- 7.6 Chart/Excel shartnomasi: har RPC columns va rows qaytarishi shart
  foreach v_sig in array array['public.ai_rep_xarajat(date,date,text)',
                               'public.ai_rep_kirim(date,date,text)',
                               'public.ai_rep_cashflow(date,date)',
                               'public.ai_rep_balans(date)',
                               'public.ai_rep_jurnal(date,date,text,numeric,numeric)'] loop
    select lower(prosrc) into v_body from pg_proc where oid = to_regprocedure(v_sig)::oid;
    if position('''columns''' in v_body) = 0 or position('''rows''' in v_body) = 0 then
      raise exception '% javobida columns/rows yoq — mijoz chart va Excel ni aynan shu shakldan quradi', v_sig;
    end if;
  end loop;

  raise notice '✅ STATIK TEKSHIRUV OK — 5 RPC + 5 yordamchi: definer, stable, search_path, anon yopiq,';
  raise notice '   auth.uid() bor, uuid argument yoq, yozuv yoq, sahifa kaliti togri, ai_rep_scope bor,';
  raise notice '   mavjud RPClar (balans / cashflow_kassa / pul_qoldiq_kassa / jurnal) ORALGAN, columns+rows bor.';
end
$tekshir$;

-- 7.7 Ko'z bilan ko'rish uchun (yozmaydi)
select p.proname                                   as funksiya,
       pg_get_function_arguments(p.oid)            as argumentlar,
       case when p.prosecdef then '✅ definer' else '❌ invoker' end as xavfsizlik,
       case when p.provolatile = 's' then '✅ stable' else '❌ ' || p.provolatile::text end as turg_unlik,
       case when exists (select 1 from pg_roles where rolname='anon')
                 and has_function_privilege('anon', p.oid, 'execute')
            then '❌ anon OCHIQ' else '✅ anon yopiq' end as anon,
       case when exists (select 1 from pg_roles where rolname='authenticated')
                 and has_function_privilege('authenticated', p.oid, 'execute')
            then 'authenticated: execute' else 'authenticated: yopiq' end as jwt_roli
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('ai_rep_yoq','ai_rep_davr','ai_rep_scope','ai_rep_filial_scope','ai_rep_top',
                     'ai_rep_xarajat','ai_rep_kirim','ai_rep_cashflow','ai_rep_balans','ai_rep_jurnal')
 order by p.proname;
-- ⬆⬆⬆  7-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  8-BO'LIM — 🔴 TIRIK SIZISH SINOVI (cheklangan user vs admin)
-- #####################################################################
--  7-BO'LIM "qorovul BOR" deydi, bu bo'lim esa "qorovul ISHLAYDI" deb
--  ISBOTLAYDI. Ikki xil `auth.uid()` ostida sinaladi:
--
--     A) auth.uid() null      -> beshala RPC ham BO'SH (ok=false)
--     B0) cheklangan user, allowed_pages = {} (SAHIFA YO'Q)
--         -> beshala RPC ham ok=false va rows bo'sh  (SAHIFA QOROVULI)
--     B1) o'sha user + sahifalar berildi (hisobot / cashflow / balans /
--         jurnal), kassa_scope='list' va ATIGI BITTA kassa
--         -> xarajat / kirim / cashflow / jurnal ochiladi, LEKIN
--            taqiqlangan kassaning KODI ham, NOMI ham javobda YO'Q
--         -> noto'g'ri `p_kesim` -> ok=false
--         -> 400 kundan uzun davr -> davr.qisqartirildi = true
--         -> `p_qidiruv` da `%` va `_` -> naqsh portlamaydi (ok=true)
--     C) admin -> hech narsa cheklanmaydi (ruxsat='admin', qamrov='hamma')
--
--  🔴🔴 O'TGAN SAFARGI IKKI XATODAN QOCHILDI:
--   (a) SINOV FIXTURE'i SAHIFA RUXSATINI BERADI. Avval sahifasiz holat
--       sinalib qorovul ishlashi isbotlanadi (B0), KEYIN sahifalar
--       berilib kassa filtri sinaladi (B1). Busiz beshala RPC to'g'ri
--       ravishda ok=false qaytarardi va sinov o'zini aldab "sizish yo'q"
--       deb baqirardi (yoki aksincha, "ochilmadi" deb yiqilardi).
--   (b) `v_xato := v_xato || 'matn'` DEB YOZILMAYDI: `text[] || unknown`
--       Postgres'da "malformed array literal" beradi va sinovni qulatib
--       haqiqiy sababni yashiradi. Har doim `|| 'matn'::text` yoki
--       `|| ('a' || b)` shaklida.
--
--  ⚠️ `ai_rep_balans` da "begona kassa nomi yo'qmi" TEKSHIRILMAYDI —
--     balans butun kompaniya hisoboti va u yerda hamma hisob nomi
--     BO'LISHI KERAK (5-BO'LIM izohiga qara). Uni sizish deb belgilash
--     sinovni yolg'on qizil qilardi.
--
--  ⚠️ SINOV `entry` / `entry_line` GA TEGMAYDI — bitta ham pul yozuvi
--     yaratilmaydi/o'zgartirilmaydi. Yagona yozuv — sinov userining
--     `user_perms` qatori, u sinov oxirida AYNAN eski holiga qaytariladi.
--     Xato bo'lsa ichki blok (subtranzaksiya) qaytadi.
--
--  ⚠️ AGAR `set role authenticated` ga ruxsat bo'lmasa yoki admin/oddiy
--     user/2 ta kassa topilmasa — sinov O'TKAZIB YUBORILADI (`raise
--     notice`), o'rnatish buzilmaydi. U holda 8.2 dagi QO'LDA tekshirish.

-- ⬇⬇⬇  8-BO'LIM: SHU QATORDAN 8-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
do $sinov$
declare
  v_admin uuid;
  v_user  uuid;
  v_k1    uuid; v_k1_kod text; v_k1_nom text;
  v_k2    uuid; v_k2_kod text; v_k2_nom text;
  v_saved user_perms%rowtype;
  v_had   boolean := false;
  v_js    jsonb;
  v_n     int;
  v_rolok boolean := true;
  v_xato  text[] := array[]::text[];
begin
  -- --- 8.0 Rol almashtira olamizmi ---
  begin
    execute 'set local role authenticated';
    execute 'reset role';
  exception when others then
    v_rolok := false;
  end;

  if not v_rolok then
    raise notice '⚠️ TIRIK SINOV OTKAZIB YUBORILDI: authenticated roliga otib bolmadi.';
    raise notice '   8.2 dagi QOLDA tekshirishni ishlating.';
    return;
  end if;

  -- --- 8.0b Ishtirokchilar ---
  select p.id into v_admin
    from profiles p join auth.users u on u.id = p.id
   where p.role = 'admin'
   order by p.id limit 1;

  select p.id into v_user
    from profiles p join auth.users u on u.id = p.id
   where coalesce(p.role, 'user') <> 'admin'
   order by p.id limit 1;

  select id, code, name into v_k1, v_k1_kod, v_k1_nom
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
    raise notice '   8.2 dagi QOLDA tekshirishni ishlating.';
    return;
  end if;

  -- =================== A) auth.uid() NULL ===================
  if auth.uid() is null then
    v_js := ai_rep_xarajat(current_date - 30, current_date, 'xodim');
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_xarajat qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || 'auth.uid() NULL da ai_rep_xarajat() malumot berdi (service_role tesigi!)'::text;
    end if;
    v_js := ai_rep_kirim(current_date - 30, current_date, 'manba');
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_kirim qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || 'auth.uid() NULL da ai_rep_kirim() malumot berdi'::text;
    end if;
    v_js := ai_rep_cashflow(current_date - 30, current_date);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_cashflow qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || 'auth.uid() NULL da ai_rep_cashflow() malumot berdi'::text;
    end if;
    v_js := ai_rep_balans(current_date);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_balans qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || 'auth.uid() NULL da ai_rep_balans() malumot berdi'::text;
    end if;
    v_js := ai_rep_jurnal(current_date - 30, current_date, null::text, null::numeric, null::numeric);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_jurnal qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || 'auth.uid() NULL da ai_rep_jurnal() malumot berdi'::text;
    end if;
  else
    raise notice 'INFO: sessiyada auth.uid() bor — "service_role bosh natija" qadami otkazildi.';
  end if;

  -- =================== B) CHEKLANGAN USER ===================
  select * into v_saved from user_perms where user_id = v_user;
  v_had := found;

  begin
    -- Vaqtincha cheklov: FAQAT v_k1 kassasi ko'rinadi, SAHIFA RUXSATI YO'Q
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

    -- ---------- B0) SAHIFA QOROVULI: hammasi YOPIQ bo'lsin ----------
    v_js := ai_rep_xarajat(current_date - 30, current_date, 'xodim');
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_xarajat qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || '🔴 SIZISH: hisobot sahifasi ruxsatda yoq, lekin ai_rep_xarajat() malumot berdi'::text;
    end if;
    if jsonb_array_length(coalesce(v_js -> 'rows', '[]'::jsonb)) <> 0 then
      v_xato := v_xato || '🔴 SIZISH: sahifa ruxsatisiz ai_rep_xarajat() qator qaytardi'::text;
    end if;

    v_js := ai_rep_kirim(current_date - 30, current_date, 'manba');
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_kirim qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || '🔴 SIZISH: hisobot sahifasi ruxsatda yoq, lekin ai_rep_kirim() malumot berdi'::text;
    end if;

    v_js := ai_rep_cashflow(current_date - 30, current_date);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_cashflow qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || '🔴 SIZISH: cashflow sahifasi ruxsatda yoq, lekin ai_rep_cashflow() malumot berdi'::text;
    end if;
    if (v_js ->> 'kirim') is not null or (v_js ->> 'oxiri') is not null then
      v_xato := v_xato || '🔴 SIZISH: ruxsatsiz holatda cashflow raqami (kirim/oxiri) qaytdi'::text;
    end if;

    v_js := ai_rep_balans(current_date);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_balans qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || '🔴 SIZISH: balans sahifasi ruxsatda yoq, lekin ai_rep_balans() malumot berdi'::text;
    end if;
    if (v_js ->> 'aktiv') is not null then
      v_xato := v_xato || '🔴 SIZISH: ruxsatsiz holatda balans aktiv raqami qaytdi'::text;
    end if;

    v_js := ai_rep_jurnal(current_date - 30, current_date, null::text, null::numeric, null::numeric);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_jurnal qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || '🔴 SIZISH: jurnal sahifasi ruxsatda yoq, lekin ai_rep_jurnal() malumot berdi'::text;
    end if;

    -- ---------- Endi SAHIFALARNI beramiz: kassa filtri sinaladi ----------
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    update user_perms
       set allowed_pages = array['hisobot','cashflow','balans','jurnal']::text[]
     where user_id = v_user;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';

    -- ---------- B1) ai_rep_xarajat (xodim) ----------
    v_js := ai_rep_xarajat(current_date - 92, current_date, 'xodim');
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_xarajat qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;

    if not coalesce((v_js ->> 'ok')::boolean, false) then
      v_xato := v_xato || ('Sahifa berilgach ham ai_rep_xarajat() yopiq qoldi: '
                           || coalesce(v_js ->> 'sabab', '?'));
    end if;
    if (v_js ->> 'ruxsat') is distinct from 'list' then
      v_xato := v_xato || ('ai_rep_xarajat ruxsat rejimi list emas: ' || coalesce(v_js ->> 'ruxsat', 'null'));
    end if;
    if (v_js ->> 'qamrov') is distinct from 'faqat ruxsatdagi kassalar' then
      v_xato := v_xato || ('ai_rep_xarajat qamrov notogri: ' || coalesce(v_js ->> 'qamrov', 'null'));
    end if;

    select count(*) into v_n
      from jsonb_array_elements(case when jsonb_typeof(v_js -> 'qatorlar') = 'array' then v_js -> 'qatorlar' else '[]'::jsonb end) x
     where x ->> 'kod' = v_k2_kod;
    if v_n <> 0 then
      v_xato := v_xato || ('🔴 SIZISH: taqiqlangan kassa ' || v_k2_kod || ' ai_rep_xarajat(xodim) da chiqdi');
    end if;
    if position(v_k2_nom in v_k1_nom) = 0 and position(v_k2_nom in v_js::text) > 0 then
      v_xato := v_xato || ('🔴 SIZISH: ai_rep_xarajat(xodim) javobida taqiqlangan kassa nomi bor: ' || v_k2_nom);
    end if;
    raise notice 'INFO: cheklangan user xarajat(xodim) da % ta qator kordi (0 bolsa sinov "bosh" — sizish yoq, lekin isbot zaif)',
      coalesce((v_js ->> 'soni')::int, 0);

    -- ---------- B2) kategoriya kesimi: P&L bloki BERILMASIN ----------
    v_js := ai_rep_xarajat(current_date - 92, current_date, 'kategoriya');
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_xarajat qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if (v_js -> 'pnl_bolim') is not null and jsonb_typeof(v_js -> 'pnl_bolim') <> 'null' then
      v_xato := v_xato || '🔴 SIZISH: kassa cheklovi bor userga butun kompaniya P&L bloki berildi'::text;
    end if;
    if position(v_k2_nom in v_k1_nom) = 0 and position(v_k2_nom in v_js::text) > 0 then
      v_xato := v_xato || ('🔴 SIZISH: ai_rep_xarajat(kategoriya) da taqiqlangan kassa nomi bor: ' || v_k2_nom);
    end if;

    -- ---------- B3) noto'g'ri kesim ----------
    v_js := ai_rep_xarajat(current_date - 30, current_date, 'bunday_kesim_yoq');
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_xarajat qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if coalesce((v_js ->> 'ok')::boolean, true) then
      v_xato := v_xato || 'Notogri p_kesim qabul qilindi — faqat xodim|kategoriya|filial bolishi kerak'::text;
    end if;

    -- ---------- B4) ai_rep_kirim ----------
    v_js := ai_rep_kirim(current_date - 92, current_date, 'filial');
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_kirim qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if not coalesce((v_js ->> 'ok')::boolean, false) then
      v_xato := v_xato || ('Sahifa berilgach ham ai_rep_kirim() yopiq qoldi: '
                           || coalesce(v_js ->> 'sabab', '?'));
    end if;
    select count(*) into v_n
      from jsonb_array_elements(case when jsonb_typeof(v_js -> 'qatorlar') = 'array' then v_js -> 'qatorlar' else '[]'::jsonb end) x
     where x ->> 'kod' = v_k2_kod;
    if v_n <> 0 then
      v_xato := v_xato || ('🔴 SIZISH: taqiqlangan kassa ' || v_k2_kod || ' ai_rep_kirim(filial) da chiqdi');
    end if;
    if position(v_k2_nom in v_k1_nom) = 0 and position(v_k2_nom in v_js::text) > 0 then
      v_xato := v_xato || ('🔴 SIZISH: ai_rep_kirim javobida taqiqlangan kassa nomi bor: ' || v_k2_nom);
    end if;

    -- ---------- B5) ai_rep_cashflow ----------
    v_js := ai_rep_cashflow(current_date - 92, current_date);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_cashflow qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if not coalesce((v_js ->> 'ok')::boolean, false) then
      v_xato := v_xato || ('Sahifa berilgach ham ai_rep_cashflow() yopiq qoldi: '
                           || coalesce(v_js ->> 'sabab', '?'));
    end if;
    if (v_js ->> 'qamrov') is distinct from 'faqat ruxsatdagi kassalar' then
      v_xato := v_xato || ('ai_rep_cashflow qamrov notogri: ' || coalesce(v_js ->> 'qamrov', 'null'));
    end if;
    select count(*) into v_n
      from jsonb_array_elements(case when jsonb_typeof(v_js -> 'kirim_taqsimot' -> 'qatorlar') = 'array' then v_js -> 'kirim_taqsimot' -> 'qatorlar' else '[]'::jsonb end) x
     where x ->> 'kod' = v_k2_kod;
    select v_n + count(*) into v_n
      from jsonb_array_elements(case when jsonb_typeof(v_js -> 'chiqim_taqsimot' -> 'qatorlar') = 'array' then v_js -> 'chiqim_taqsimot' -> 'qatorlar' else '[]'::jsonb end) x
     where x ->> 'kod' = v_k2_kod;
    if v_n <> 0 then
      v_xato := v_xato || ('🔴 SIZISH: taqiqlangan kassa kodi ' || v_k2_kod || ' cashflow taqsimotida chiqdi');
    end if;
    if position(v_k2_nom in v_k1_nom) = 0 and position(v_k2_nom in v_js::text) > 0 then
      v_xato := v_xato || ('🔴 SIZISH: ai_rep_cashflow javobida taqiqlangan kassa nomi bor: ' || v_k2_nom);
    end if;
    raise notice 'INFO: cheklangan user cashflow: kirim=% chiqim=% (tekshiruv farqi %)',
      coalesce(v_js ->> 'kirim', '0'), coalesce(v_js ->> 'chiqim', '0'),
      coalesce(v_js -> 'tekshiruv' ->> 'farq', '?');

    -- ---------- B6) ai_rep_jurnal (maskalash + qidiruv naqshi) ----------
    v_js := ai_rep_jurnal(current_date - 92, current_date, null::text, null::numeric, null::numeric);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_jurnal qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if not coalesce((v_js ->> 'ok')::boolean, false) then
      v_xato := v_xato || ('Sahifa berilgach ham ai_rep_jurnal() yopiq qoldi: '
                           || coalesce(v_js ->> 'sabab', '?'));
    end if;
    select count(*) into v_n
      from jsonb_array_elements(case when jsonb_typeof(v_js -> 'qatorlar') = 'array' then v_js -> 'qatorlar' else '[]'::jsonb end) x
     where x ->> 'dt_kod' = v_k2_kod or x ->> 'kt_kod' = v_k2_kod;
    if v_n <> 0 then
      v_xato := v_xato || ('🔴 SIZISH: jurnalda taqiqlangan kassa kodi ' || v_k2_kod || ' chiqdi');
    end if;
    if position(v_k2_nom in v_k1_nom) = 0 and position(v_k2_nom in v_js::text) > 0 then
      v_xato := v_xato || ('🔴 SIZISH: jurnalda taqiqlangan kassa nomi chiqdi: ' || v_k2_nom);
    end if;
    raise notice 'INFO: cheklangan user jurnalda % ta yozuv kordi', coalesce((v_js ->> 'soni')::int, 0);

    -- Qidiruv naqshi portlamasin (% va _ escape qilingan)
    v_js := ai_rep_jurnal(current_date - 30, current_date, '%_%'::text, null::numeric, null::numeric);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_jurnal qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if not coalesce((v_js ->> 'ok')::boolean, false) then
      v_xato := v_xato || ('Qidiruv naqshi (% va _) RPC ni yiqitdi: ' || coalesce(v_js ->> 'sabab', '?'));
    end if;

    -- ---------- B7) 400 kundan uzun davr QISQARTIRILSIN ----------
    v_js := ai_rep_xarajat(current_date - 900, current_date, 'xodim');
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_xarajat qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if not coalesce((v_js -> 'davr' ->> 'qisqartirildi')::boolean, false) then
      v_xato := v_xato || '900 kunlik davr qisqartirilmadi (maks 400 kun cheklovi ishlamadi)'::text;
    end if;
    if (v_js -> 'davr' ->> 'from')::date <> current_date - 400 then
      v_xato := v_xato || ('Qisqartirilgan davr boshi notogri: ' || coalesce(v_js -> 'davr' ->> 'from', 'null'));
    end if;

    -- ---------- B8) balans: SAHIFA berilgach OCHILADI ----------
    --  ⚠️ Bu yerda "begona kassa nomi yoq" DEB TEKSHIRILMAYDI — balans
    --     butun kompaniya hisoboti (5-BO'LIM izohi).
    v_js := ai_rep_balans(current_date);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_balans qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if not coalesce((v_js ->> 'ok')::boolean, false) then
      v_xato := v_xato || ('Balans sahifasi berilgach ham ai_rep_balans() yopiq qoldi: '
                           || coalesce(v_js ->> 'sabab', '?'));
    end if;
    if (v_js ->> 'farq') is not null and round((v_js ->> 'farq')::numeric) <> 0 then
      raise notice '⚠️ INFO: balans muvozanati buzilgan (farq %) — bu RPC xatosi emas, bazadagi holat',
        (v_js ->> 'farq');
    end if;

    -- =================== C) ADMIN ===================
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';

    v_js := ai_rep_xarajat(current_date - 92, current_date, 'xodim');
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_xarajat qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if (v_js ->> 'ruxsat') is distinct from 'admin' then
      v_xato := v_xato || ('Admin rejimi admin emas: ' || coalesce(v_js ->> 'ruxsat', 'null'));
    end if;
    if (v_js ->> 'qamrov') is distinct from 'hamma kassalar' then
      v_xato := v_xato || ('Admin uchun qamrov cheklangan bolib qoldi: ' || coalesce(v_js ->> 'qamrov', 'null'));
    end if;

    v_js := ai_rep_cashflow(current_date - 92, current_date);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_cashflow qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if not coalesce((v_js ->> 'ok')::boolean, false) then
      v_xato := v_xato || ('Admin ai_rep_cashflow() dan ok=false oldi: ' || coalesce(v_js ->> 'sabab', '?'));
    end if;
    if not coalesce((v_js -> 'tekshiruv' ->> 'ok')::boolean, false) then
      raise notice '⚠️ INFO: admin cashflow tekshiruvi mos kelmadi (farq %) — cashflow-dev.html da ham shu farq chiqadimi, tekshiring',
        coalesce(v_js -> 'tekshiruv' ->> 'farq', '?');
    end if;

    v_js := ai_rep_balans(current_date);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_balans qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if not coalesce((v_js ->> 'ok')::boolean, false) then
      v_xato := v_xato || ('Admin ai_rep_balans() dan ok=false oldi: ' || coalesce(v_js ->> 'sabab', '?'));
    end if;

    v_js := ai_rep_jurnal(current_date - 92, current_date, null::text, null::numeric, null::numeric);
    if v_js ? 'qatorlar' and jsonb_typeof(v_js -> 'qatorlar') <> 'array' then
      v_xato := v_xato || ('SHAKL: ai_rep_jurnal qatorlar massiv emas (' || coalesce(jsonb_typeof(v_js -> 'qatorlar'), 'yoq') || ')');
    end if;
    if not coalesce((v_js ->> 'ok')::boolean, false) then
      v_xato := v_xato || ('Admin ai_rep_jurnal() dan ok=false oldi: ' || coalesce(v_js ->> 'sabab', '?'));
    end if;
    if (v_js ->> 'qamrov') is distinct from 'hamma kassalar' then
      v_xato := v_xato || ('Admin jurnal qamrovi cheklangan: ' || coalesce(v_js ->> 'qamrov', 'null'));
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

  raise notice '✅ TIRIK SIZISH SINOVI OK:';
  raise notice '   • sahifa ruxsati yoq -> beshala RPC ham bosh (ok=false);';
  raise notice '   • sahifa berilgach kassa filtri ishladi — begona kassa kodi/nomi xarajat, kirim,';
  raise notice '     cashflow va jurnalda chiqmadi; P&L bloki cheklangan userga berilmadi;';
  raise notice '   • notogri kesim rad etildi, 900 kunlik davr 400 ga qisqardi, qidiruv naqshi portlamadi;';
  raise notice '   • admin cheklanmadi; user_perms qatori eski holiga qaytarildi.';
end
$sinov$;

-- 8.1 Sinovdan keyin ruxsat jadvali toza qolganini ko'rish (yozmaydi)
select user_id, kassa_scope,
       coalesce(array_length(view_kassa_ids, 1), 0) as view_kassa_soni,
       coalesce(array_length(allowed_pages, 1), 0)  as sahifa_soni,
       updated_at
  from user_perms
 order by updated_at desc
 limit 10;
-- ⬆⬆⬆  8-BO'LIM shu yerda tugadi  ⬆⬆⬆

-- ---------------------------------------------------------------------
--  8.2 — QO'LDA TEKSHIRISH (agar 8-BO'LIM o'tkazib yuborilgan bo'lsa)
-- ---------------------------------------------------------------------
--  Sabab: Supabase SQL Editor ba'zi loyihalarda `set role authenticated`
--  ga ruxsat bermasligi mumkin.
--
--  Eng ishonchli qo'lda usul — ILOVADAN: cheklangan (kassa_scope='list')
--  foydalanuvchi bilan kiring va brauzer konsolida:
--
--     await sb.rpc('ai_rep_xarajat', { p_from:'2026-07-01', p_to:'2026-08-14', p_kesim:'xodim' })
--     await sb.rpc('ai_rep_kirim',   { p_from:'2026-07-01', p_to:'2026-08-14', p_kesim:'manba' })
--     await sb.rpc('ai_rep_cashflow',{ p_from:'2026-07-01', p_to:'2026-08-14' })
--     await sb.rpc('ai_rep_balans',  { p_sana:'2026-08-14' })
--     await sb.rpc('ai_rep_jurnal',  { p_from:'2026-07-01', p_to:'2026-08-14' })
--
--  Solishtirish (AYNAN bir xil raqam chiqishi SHART):
--     ai_rep_cashflow  <->  cashflow.html (o'sha davr, "Hamma kassalar")
--     ai_rep_balans    <->  balans.html   (o'sha sana)
--     ai_rep_xarajat(kategoriya) <-> hisobot.html CEO bloki (admin bilan)
--  Har javobda `{ data, error }` — `error` ni tekshiring.
--
--  SQL bilan (id larni qo'yib, ALOHIDA ishga tushiring):
--
--  begin;
--    set local request.jwt.claims = '{"sub":"<CHEKLANGAN-USER-UUID>","role":"authenticated"}';
--    set local role authenticated;
--    select jsonb_pretty(ai_rep_xarajat(current_date - 30, current_date, 'xodim'));
--    select jsonb_pretty(ai_rep_cashflow(current_date - 30, current_date));
--  rollback;
--
--  ⚠️ Oxirida ROLLBACK.


-- #####################################################################
--  9-BO'LIM — PostgREST sxema keshini yangilash
-- #####################################################################
--  Busiz yangi RPC'lar klientdan/EF dan "function not found" (PGRST202)
--  beradi.

-- ⬇⬇⬇  9-BO'LIM  ⬇⬇⬇
notify pgrst, 'reload schema';
-- ⬆⬆⬆  9-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  10-BO'LIM — ROLLBACK (kerak bo'lsa, QO'LDA)
-- #####################################################################
--  Ataylab izohda turibdi — tasodifan RUN bo'lmasin.
--  ⚠️ Bu fayl BOSHQA HECH NARSAGA tegmagani uchun rollback ham hech
--     qanday mavjud funksiyani/view'ni qaytarmaydi: faqat 10 ta yangi
--     funksiya o'chadi. Ma'lumot yo'qolmaydi (birorta jadval yaratilmagan),
--     `ai_ctx_*` (4-bosqich) va `pnl` / `balans` / `cashflow` /
--     `pul_qoldiq` / `jurnal` JOYIDA QOLADI.
--  ⚠️ Tartib: avval ochiq RPC'lar, keyin ular chaqiradigan yordamchilar.
--  ⚠️ Rollback'dan keyin Edge Function ning hisobot tool'lari ishlamay
--     qoladi (AI faqat kassa/qarzdor/transfer kontekstida qoladi) —
--     avval EF ni orqaga qaytaring.
--
-- drop function if exists ai_rep_jurnal(date, date, text, numeric, numeric);
-- drop function if exists ai_rep_balans(date);
-- drop function if exists ai_rep_cashflow(date, date);
-- drop function if exists ai_rep_kirim(date, date, text);
-- drop function if exists ai_rep_xarajat(date, date, text);
-- drop function if exists ai_rep_top(jsonb, int);
-- drop function if exists ai_rep_filial_scope();
-- drop function if exists ai_rep_scope();
-- drop function if exists ai_rep_davr(date, date);
-- drop function if exists ai_rep_yoq(text);
-- notify pgrst, 'reload schema';


-- #####################################################################
--  11-BO'LIM — EDGE FUNCTION UCHUN SHARTNOMA  (faqat izoh, RUN qilinmaydi)
-- #####################################################################
--
--  🔴🔴  ENG MUHIM QOIDA  🔴🔴
--  EF bu RPC'larni FOYDALANUVCHI JWT SI BILAN chaqirsin —
--  SERVICE_ROLE BILAN EMAS. service_role da `auth.uid()` NULL bo'ladi va
--  javob BO'SH keladi (`ok:false`, `sabab:'Avtorizatsiya yoq...'`).
--  Bu XATO emas, ATAYLAB qilingan. Agar kimdir bu qorovulni "tuzatib"
--  service_role ga ochsa — butun ruxsat mantiqi CHETLAB O'TILADI va
--  boshqa filialning puli AI orqali sizadi.
--  Mavjud naqsh (`ai-chat` EF): anon key + foydalanuvchining
--  `Authorization` headeri bilan klient quriladi. AYNAN o'sha klientdan
--  `sb.rpc(...)` qiling.
--
--  ---------------------------------------------------------------
--  0) HAMMA RPC UCHUN UMUMIY SHAKL  (mijoz shunga tayanadi)
--  ---------------------------------------------------------------
--     Muvaffaqiyat:
--        {
--          "ok": true,
--          "ruxsat": "admin" | "all" | "list",
--          "qamrov": "hamma kassalar" | "faqat ruxsatdagi kassalar"
--                    | "butun kompaniya (balans kassa boyicha bolinmaydi)",
--          "davr": { "from":"2026-08-01", "to":"2026-08-14",
--                    "kunlar":13, "maks_kun":400, "qisqartirildi":false },
--          "columns": ["Yorliq", ..., "Summa"],     // 🔴 MAJBURIY
--          "rows":    [ ["Yorliq", ..., 12345] ],   // 🔴 MAJBURIY
--          "izoh": "..."
--        }
--     Ruxsat yo'q / bo'sh:
--        { "ok": false, "sabab": "...", "ruxsat": "yoq",
--          "columns": [], "rows": [], "qatorlar": [] }
--
--  🔴 CHART / EXCEL SHARTNOMASI (o'zgartirilmasin):
--     • `columns` — ustun sarlavhalari (matn massivi);
--     • `rows`    — massivlar massivi, HAR QATORDA ustunlar `columns`
--                   TARTIBIDA: **YORLIQ BIRINCHI, RAQAM OXIRGI**;
--     • demak chart uchun: yorliq = row[0], qiymat = row[row.length-1];
--     • Excel/CSV uchun: `[columns, ...rows]` — tayyor jadval
--       (hisobot-dev.html dagi `downloadCSV(...)` ayni shu shaklni kutadi:
--       [['Kod','Nomi','Summa'], ...]);
--     • ichki bloklar (`kirim_taqsimot`, `chiqim_taqsimot`,
--       `aktiv_taqsimot`, `passiv_taqsimot`, `pnl_bolim`) ham AYNAN shu
--       `{columns, rows}` shakliga ega — ular ham to'g'ridan chart bo'ladi;
--     • `qatorlar` — o'sha ma'lumotning obyekt ko'rinishi (kod, nom,
--       subtitle, kassa_turi, ulush foizi...) — AI matnda ishlatadi,
--       chart uchun `rows` yetarli.
--     • Pie chart uchun `qatorlar[].ulush` — foiz (yig'indisi ~100).
--       Limitdan oshgan qatorlar BITTA "Boshqalar (N ta)" qatoriga
--       yig'ilgan, ya'ni sum(rows) = `jami`.
--
--  ---------------------------------------------------------------
--  1) ai_rep_xarajat(p_from date, p_to date, p_kesim text)
--  ---------------------------------------------------------------
--     sb.rpc('ai_rep_xarajat', { p_from:'2026-08-01', p_to:'2026-08-14',
--                                p_kesim:'xodim' })
--     p_kesim: 'xodim' (sukut) | 'kategoriya' | 'filial'
--     Sana ixtiyoriy: p_to yo'q -> bugun (Toshkent), p_from yo'q -> oy boshi.
--     Sahifa ruxsati: 'hisobot'.
--
--     -> {
--          "ok": true, "ruxsat":"admin", "qamrov":"hamma kassalar",
--          "kesim":"xodim",
--          "davr": {...},
--          "soni": 12, "kesildi": false, "jami": 84500000,
--          "columns": ["Kassa / hodim","Kod","Summa"],
--          "rows": [ ["Aziz Karimov","5403",12400000],
--                    ["Toshkent Kassa","5011",9800000],
--                    ["Boshqalar (7 ta)",null,6100000] ],
--          "qatorlar": [ { "kod":"5403","nom":"Aziz Karimov",
--                          "subtitle":"Chilonzor · Menejer",
--                          "kassa_turi":"xarajat",
--                          "summa":12400000,"ulush":14.7 }, ... ],
--          "taqsimlangan": false,        // true = filial kesimi (qara: pastda)
--          "filial_cheklangan": null,
--          "pnl_bolim": null,            // faqat kategoriya + cheklovsiz
--          "pnl_sabab": "P&L faqat kategoriya kesimida beriladi",
--          "izoh": "..."
--        }
--
--     kesim='kategoriya' da `qatorlar[]` da qo'shimcha `netto` bor
--     (debit-credit). `summa` = sum(debit) — hisobot sahifasidagi CEO
--     bloki bilan bir xil.
--     kesim='kategoriya' VA kassa cheklovi yo'q bo'lsa `pnl_bolim`:
--        { "columns":["Korsatkich","Summa"],
--          "rows":[["Tushum",..],["Tannarx",..],["Yalpi foyda",..],
--                  ["Operatsion xarajat",..],["Operatsion foyda",..],
--                  ["Boshqa",..],["Soliq",..],["Sof foyda",..]],
--          "tushum":..,"tannarx":..,"yalpi_foyda":..,"operatsion":..,
--          "operatsion_foyda":..,"boshqa":..,"soliq":..,"sof_foyda":.. }
--     ⚠️ `taqsimlangan: true` (filial kesimi) — bitta yozuv bir nechta
--        filialga tegishli bo'lsa summa har biriga to'liq yozilgan, ya'ni
--        `jami` boshqa kesimlardan katta bo'lishi mumkin. AI buni
--        "xarajat oshdi" deb TALQIN QILMASIN.
--
--  ---------------------------------------------------------------
--  2) ai_rep_kirim(p_from date, p_to date, p_kesim text)
--  ---------------------------------------------------------------
--     sb.rpc('ai_rep_kirim', { p_from:..., p_to:..., p_kesim:'manba' })
--     p_kesim: 'manba' (sukut) | 'filial'.  Sahifa ruxsati: 'hisobot'.
--     Shakl 1-band bilan bir xil:
--        columns: ['Manba','Kod','Summa']  yoki  ['Kassa / filial','Kod','Summa']
--     `qatorlar[]`: manba uchun `tur` (accounts.type), filial uchun
--     `kassa_turi` + `subtitle`.
--     ⚠️ Kirim = Dt pul va Kt pul EMAS -> KASSALARARO TRANSFER kirim deb
--        sanalmaydi. AI "kirim = tushum" deb umumlashtirmasin: 9010 savdo
--        tushumidan tashqari qarz qaytishi, kapital kiritish ham bo'lishi
--        mumkin — qatorlar kodini o'qisin.
--
--  ---------------------------------------------------------------
--  3) ai_rep_cashflow(p_from date, p_to date)
--  ---------------------------------------------------------------
--     sb.rpc('ai_rep_cashflow', { p_from:'2026-08-01', p_to:'2026-08-14' })
--     Sahifa ruxsati: 'cashflow'.
--
--     -> { "ok":true, "ruxsat":"admin", "qamrov":"hamma kassalar",
--          "davr": {...},
--          "boshi": 412000000, "kirim": 98000000, "chiqim": 76000000,
--          "ozgarish": 22000000, "oxiri": 434000000,
--          "tekshiruv": { "farq":0, "ok":true, "izoh":"..." },
--          "columns": ["Korsatkich","Summa"],
--          "rows": [["Davr boshi",412000000],["Kirim",98000000],
--                   ["Chiqim",76000000],["Davr oxiri",434000000]],
--          "kirim_taqsimot":  { "columns":["Modda","Kod","Summa"], "rows":[...],
--                               "qatorlar":[...], "soni":8, "kesildi":false },
--          "chiqim_taqsimot": { ... },
--          "izoh": "..." }
--
--     ⚠️ `tekshiruv.ok = false` bo'lsa AI raqamni "aniq" deb bermasin —
--        `cashflow.html` da ham xuddi shu farq chiqadi (bu RPC xatosi
--        emas, bazadagi holat).
--     ⚠️ Cheklangan userda ikkita O'Z kassasi orasidagi transfer birida
--        kirim, ikkinchisida chiqim bo'lib ko'rinadi (izohda yozilgan).
--
--  ---------------------------------------------------------------
--  4) ai_rep_balans(p_sana date)
--  ---------------------------------------------------------------
--     sb.rpc('ai_rep_balans', { p_sana:'2026-08-14' })   // p_sana ixtiyoriy
--     Sahifa ruxsati: 'balans'.  🔴 KASSA FILTRI YO'Q — butun kompaniya
--     (UI da ham shunday; 5-BO'LIM izohiga qara).
--
--     -> { "ok":true, "ruxsat":"admin", "sana":"2026-08-14",
--          "aktiv": 1240000000, "passiv": 310000000, "kapital": 930000000,
--          "passiv_kapital": 1240000000, "farq": 0, "muvozanat": true,
--          "qator_soni": 63, "kesildi": false,
--          "columns": ["Bolim","Summa"],
--          "rows": [["AKTIV",1240000000],["PASSIV",310000000],
--                   ["KAPITAL",930000000]],
--          "aktiv_taqsimot":  { "columns":["Bolim","Summa"], "rows":[["pul",..],["tovar",..]] },
--          "passiv_taqsimot": { "columns":["Bolim","Summa"], "rows":[["PASSIV / kreditor",..]] },
--          "qatorlar": [ {"bolim":"AKTIV","section":"pul","kod":"5011",
--                         "nom":"Toshkent Kassa","summa":178000000}, ... ],
--          "qatorlar_columns": ["Hisob","Kod","Summa"],
--          "qatorlar_rows":    [["Toshkent Kassa","5011",178000000], ...],
--          "izoh": "..." }
--
--     ⚠️ `muvozanat:false` (farq <> 0) bo'lsa — bu bazadagi nomuvofiqlik,
--        AI uni yashirmasin, aksincha ogohlantirsin.
--     ⚠️ Amortizatsiya MANFIY qator (kontr-aktiv) — AI uni "xato" demasin.
--
--  ---------------------------------------------------------------
--  5) ai_rep_jurnal(p_from, p_to, p_qidiruv, p_min, p_max)
--  ---------------------------------------------------------------
--     sb.rpc('ai_rep_jurnal', { p_from:'2026-08-01', p_to:'2026-08-14',
--                               p_qidiruv:'ijara', p_min:1000000, p_max:null })
--     Hammasi ixtiyoriy. Sahifa ruxsati: 'jurnal'.  Maks 50 qator.
--
--     -> { "ok":true, "ruxsat":"list", "qamrov":"faqat ruxsatdagi kassalar",
--          "davr": {...},
--          "filtr": { "qidiruv":"ijara","qidiruv_kesildi":false,
--                     "min":1000000,"max":null },
--          "skan": { "olingan":500, "chegara":500 },
--          "soni": 50, "jami": 240000000,
--          "kesildi": true, "toliq_emas": true,
--          "columns": ["Sana","Izoh","Dt","Kt","Summa"],
--          "rows": [["2026-08-12","Ofis ijarasi","9421 Ijara","5011 Toshkent Kassa",12000000]],
--          "qatorlar": [ {"sana":"2026-08-12","dt_kod":"9421","dt_nom":"Ijara",
--                         "kt_kod":"5011","kt_nom":"Toshkent Kassa",
--                         "summa":12000000,"izoh":"Ofis ijarasi",
--                         "tur":"chiqim","maskalangan":false} ],
--          "izoh": "..." }
--
--     ⚠️ `"kt_nom":"ruxsat yoq"` (va `kt_kod:null`) = o'sha tomon
--        foydalanuvchi ruxsatidan tashqarida. AI uni TAXMIN QILMASIN
--        ("Sergeli bo'lsa kerak" — TAQIQ), "ruxsatingizdan tashqaridagi
--        kassa" desin. Bunday qatorda `izoh` ham `null` bo'ladi
--        (`maskalangan:true`).
--     ⚠️ `toliq_emas:true` -> davr ichida boshqa yozuvlar ham bor
--        (skan chegarasi). AI "hammasi shu" DEMASIN — davrni toraytirishni
--        yoki qidiruvni aniqlashtirish taklif qilsin.
--     ⚠️ `tur`: transfer | kirim | chiqim | neytral | boshqa
--        (`section='pul'` bo'yicha, CLAUDE.md jurnal tasnifi).
--
--  ---------------------------------------------------------------
--  UMUMIY (EF tomonida)
--  ---------------------------------------------------------------
--   • `sb.rpc()` `{ data, error }` qaytaradi va THROW QILMAYDI —
--     `error` DOIM tekshirilsin (CLAUDE.md 6-qoida). Xatoni jimgina
--     yutib "ma'lumot yo'q" deb Claude'ga bermang: AI raqamni o'ylab
--     topib qo'yishi mumkin. Tool natijasida xato ochiq "XATO" bo'lib
--     ketsin (4-bosqichdagi naqsh).
--   • `ok:false` — bu XATO EMAS, RUXSAT holati. AI "ruxsatingiz yo'q"
--     desin va raqam O'YLAB TOPMASIN.
--   • `davr.qisqartirildi:true` bo'lsa AI javobda HAQIQIY davrni aytsin
--     (foydalanuvchi so'ragan davrni emas).
--   • `qamrov` — javobda ochiq: "faqat ruxsatdagi kassalar" bo'lsa AI
--     "bu kompaniya bo'yicha jami" demasin.
--   • Sana argumentlari model tomonidan beriladi — EF ularni regex VA
--     kalendar bilan tekshirsin (4-bosqichdagi qoida). RPC o'zi ham
--     himoyalangan: noto'g'ri tur -> PostgREST xatosi, 400 kundan uzun
--     davr -> qisqartiriladi.
--   • Hech bir RPC yozmaydi — `ai-chat` EF ning "Provodka jadvaliga
--     yozmaydi" invarianti buzilmaydi.
--   • Yangi hisobot RPC qo'shilsa: nomi `ai_rep_` bilan boshlansin,
--     ruxsatni `ai_rep_scope()` / `ai_ctx_has_page()` dan olsin, mavjud
--     hisobot RPC si bo'lsa uni O'RASIN (qayta yozmasin), `columns`+`rows`
--     bersin va 7-BO'LIM ro'yxatiga qo'shilsin (statik tekshiruv uni ham
--     qamrasin).
-- #####################################################################
