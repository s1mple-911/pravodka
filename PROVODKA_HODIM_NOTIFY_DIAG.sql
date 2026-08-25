-- ============================================================================
-- DIAGNOSTIKA: "amal qildim, lekin botdan xabar kelmadi"
-- Faqat SELECT — hech narsani o'zgartirmaydi. Ketma-ket RUN qiling,
-- BIRINCHI muvaffaqiyatsiz bandda to'xtang.
-- ============================================================================

-- ── 1. SQL umuman RUN qilinganmi? ──────────────────────────────────────────
-- Kutilgan: 8 qator funksiya + 2 qator trigger + 2 qator jadval.
-- BO'SH/kam chiqsa -> PROVODKA_HODIM_NOTIFY.sql hali RUN qilinmagan. To'xtang.
select 'funksiya' as tur, proname as nom
  from pg_proc
 where proname in ('hodim_kassa_root','hodim_kassa_qoldiq','_hodim_notify_qoy',
                   'hodim_notify_line_fn','hodim_notify_entry_fn',
                   'hodim_notify_pending','hodim_notify_sent','hodim_notify_fail')
union all
select 'trigger', tgname
  from pg_trigger
 where tgname in ('trg_hodim_notify_entry_line','trg_hodim_notify_entry')
union all
select 'jadval', relname
  from pg_class
 where relname in ('hodim_notify','hodim_notify_admin')
 order by 1, 2;


-- ── 2. Xabar navbatga TUSHDIMI? ────────────────────────────────────────────
-- Bu 1-bandning natijasi to'liq bo'lsagina ma'noli.
--  qator BOR  -> baza tomoni ishlayapti, muammo n8n/Telegramda (5-bandga o'ting)
--  qator YO'Q -> trigger kassani "hodim kassasi" deb tanimagan (3-bandga o'ting)
select id, entry_id, kassa_id, hodisa, delta, dt_yon,
       qoldiq_oldin, qoldiq_keyin, created_at, sent_at, attempts, last_error
  from hodim_notify
 order by id desc
 limit 10;


-- ── 3. 🔴 ENG EHTIMOLIY SABAB: 5351 bog'lanmagan eski hisob ────────────────
-- `5351 "Abrorxo'ja Ahmadov · Naqd"` — PROVODKA_TUR_BOGLASH.sql aynan shu
-- hisobni misol qilib keltiradi: `parent_id` va `pul_turi` BO'SH.
-- Bunday hisobda `hodim_kassa_root()` null qaytaradi -> XABAR CHIQMAYDI.
select a.code, a.name,
       a.parent_id, a.pul_turi, a.kassa_turi, a.currency, a.is_active,
       hodim_kassa_root(a.id) as root_id,
       (select r.code from accounts r where r.id = hodim_kassa_root(a.id)) as root_kod,
       case when hodim_kassa_root(a.id) is null
            then '❌ XABAR CHIQMAYDI'
            else '✅ ok' end as holat
  from accounts a
 where a.code in ('5351', '5401')
 order by a.code;

-- Hammasi bo'yicha: qaysi hodim tur-hisoblari bog'lanmagan
select code, name, parent_id, pul_turi, kassa_turi
  from accounts
 where is_active and code like '5%' and parent_id is null
   and name ~* '·\s*(Naqd|Click|Payme|Terminal|Karta|Plastik|USD|EUR)\s*$'
 order by code;
-- Qator chiqsa -> PROVODKA_TUR_BOGLASH.sql ni RUN qiling, keyin qayta sinang.


-- ── 4. Jadval/funksiya EGASI bir xilmi? ────────────────────────────────────
-- Farq bo'lsa trigger yoza olmaydi va (fail-open tufayli) JIMGINA yo'qotadi.
select c.relname,
       c.relowner::regrole                            as jadval_egasi,
       (select proowner::regrole from pg_proc
         where proname = '_hodim_notify_qoy' limit 1) as funksiya_egasi,
       c.relforcerowsecurity                          as force_rls
  from pg_class c
 where c.relname = 'hodim_notify';
-- jadval_egasi = funksiya_egasi  VA  force_rls = false bo'lsin.


-- ── 5. n8n ko'radigan payload ──────────────────────────────────────────────
-- ⚠️ attempts oshiradi — bir marta chaqiring.
--    items bo'sh chiqsa: qator hali 30 soniya to'ldirmagan yoki
--    yozuv posted emas / o'chirilgan.
select hodim_notify_pending(20);


-- ── 6. Qabul qiluvchi bormi? ───────────────────────────────────────────────
select code, name,
       (to_jsonb(a) ->> 'taskfix_user_id') as taskfix_user_id,
       case when (to_jsonb(a) ->> 'taskfix_user_id') is null
            then '⚠️ hodimga bormaydi (faqat adminlarga)' else '✅' end as holat
  from accounts a
 where a.code in ('5351', '5401');

select * from hodim_notify_admin;
-- Bo'sh bo'lsa VA taskfix_user_id ham yo'q bo'lsa -> xabar HECH KIMGA ketmaydi.
-- Tuzatish:
--   insert into hodim_notify_admin(telegram_id, ism) values ('SIZNING_ID', 'Asilbek')
--   on conflict (telegram_id) do update set is_active = true;


-- ============================================================================
-- n8n TOMONI (baza tomoni ✅ bo'lsa)
-- ============================================================================
-- https://n8n.arosmarket.com/workflow/CuIA9H5oW4VrtnJv
--   a) Workflow AKTIVMI? (yaratilganda ataylab aktivlashtirilmagan)
--   b) 4 node'da kredit bormi: Navbat / Yuborildi Belgila / Xato Yoz
--      (Supabase SERVICE_ROLE) + Aros Userlar (Postgres account 3)
--   c) "Execute workflow" bilan qo'lda ishga tushirib, har node chiqishini ko'ring
-- ============================================================================
