-- =====================================================================
-- DIAG_RBAC_TEZLIK.sql — RBAC (PROVODKA_RBAC.sql) tezlik o'lchovi
-- ---------------------------------------------------------------------
-- ⚠️ SQL Editor `postgres` (superuser) sifatida ulanadi, JWT yo'q ->
--    `auth.uid()` NULL. RBAC funksiyalarining aksariyati (`my_perms()`,
--    `rbac_modda_ok()`, `rbac_guard_entry_line()` trigger ichida) xuddi
--    shu holatda "service_role — tekshirmayman -> true" yo'lidan o'tadi
--    (fail-open faqat pul/GUC darajasida emas, service_role uchun ataylab
--    shunday, PROVODKA_PERMS.sql'dagi eski naqsh bilan bir xil). Ya'ni
--    bu yerdagi `explain analyze` REAL HODIM uchun tekshiruv YO'LINI emas,
--    faqat CTE so'rovining o'zi qancha vaqt olishini ko'rsatadi.
--    HAQIQIY (JWT bilan) o'lchov uchun 3-BO'LIMga qarang.
-- =====================================================================


-- ############ 1-SO'ROV — rbac_my() ichidagi CTE tezligi ############
-- `rbac_my()` `auth.uid()` ga tayanmaydi (parametr) — SQL Editorda ham
-- to'g'ridan chaqirish mumkin (superuser bo'lgani uchun REVOKE'lar
-- to'smaydi). O'RNIGA haqiqiy foydalanuvchi id qo'ying (profiles.id).
explain (analyze, buffers, format text)
select rbac_my('00000000-0000-0000-0000-000000000000'::uuid);
--
-- QANDAY O'QISH: "Execution Time" — bitta chaqiruv narxi (kutilgan: <1ms,
-- 5 ta kichik jadval + indekslangan join). 5+ ms bo'lsa indekslarni tekshiring:
--   \d rbac_user_role   -- pk(user_id,role_id) + role_id indeksi bormi
--   \d rbac_role_modda  -- pk(role_id,account_id) + account_id indeksi bormi


-- ############ 2-SO'ROV — rbac_modda_ok() bitta chaqiruv narxi ############
-- 🔴 Bu yerda SQL Editorda `auth.uid() is null -> true` yo'liga tushadi —
--    ya'ni FAQAT funksiya chaqiruv overhead'ini o'lchaydi, ICHIDAGI
--    EXISTS so'rovi ISHGA TUSHMAYDI (real hodim uchun bundan biroz sekinroq
--    bo'ladi — pastdagi 3-BO'LIMga qarang).
-- 🔴 Kod BILAN almashtiring — real xarajat moddasi hisobining id'si.
explain (analyze, buffers)
select rbac_modda_ok((select id from accounts where type = 'xarajat' limit 1));


-- ############ 3-SO'ROV — trigger real ta'siri (JWT bilan, ROLLBACK) ############
-- SQL Editorda `set_config('request.jwt.claims', ...)` bilan haqiqiy
-- foydalanuvchi rolini simulyatsiya qilish mumkin (auth.uid() shundan
-- o'qiydi). `local` — faqat shu tranzaksiya ichida, ROLLBACK bilan
-- HECH NARSA yozilmaydi.
--
-- 🔴 USER_ID va ACCOUNT_ID ni HAQIQIY qiymatlarga almashtiring:
--    - v_uid    = xarajat yozadigan hodimning profiles.id
--    - v_kassa  = shu hodimning pul kassasi (Kt tomon, masalan 5011)
--    - v_modda  = hodim rolida BOR xarajat moddasi (Dt tomon)
begin;
  select set_config('request.jwt.claims',
    json_build_object('sub', 'BU_YERGA_USER_ID', 'role', 'authenticated')::text, true);

  explain (analyze, buffers)
  insert into entry_line (entry_id, account_id, debit, credit)
  values (
    (select id from entry order by created_at desc limit 1),  -- 🔴 mavjud entry, faqat vaqt o'lchash uchun
    'BU_YERGA_MODDA_ACCOUNT_ID'::uuid,
    1, 0
  );
rollback;
--
-- QANDAY O'QISH: bu bitta INSERT ikkala trigger (`trg_perm_guard_entry_line`
-- + `trg_rbac_guard_entry_line`) orqali o'tadi — "Trigger" qatoridagi vaqtlar
-- yig'indisi muhim. Kutilgan: har biri <1ms (indekslangan EXISTS).
-- ROLLBACK bo'lgani uchun baza o'zgarmaydi — xohlagancha qayta ishga tushirish mumkin.


-- ############ 4-SO'ROV (TAVSIYA ETILGAN) — brauzerda haqiqiy o'lchov ############
-- Eng ishonchli usul — SQL Editor emas, ilovaning o'zi:
--   1. `hodim-dev.html` (yoki boshqa sahifa) ni brauzerda oching, DevTools -> Console.
--   2. `performance.now()` bilan `permLoad(sb)` chaqiruvini o'rang:
--        const t0 = performance.now();
--        await permLoad(sb);
--        console.log('permLoad:', performance.now() - t0, 'ms');
--   3. RBAC RUN qilishdan OLDIN va KEYIN solishtiring (bir xil user bilan,
--      bir necha marta — birinchi chaqiruv sovuq keshli bo'lishi mumkin).
-- 🔴 Kutilgan farq: bir necha millisekund (bitta qo'shimcha RPC ichidagi
--    bitta qo'shimcha CTE so'rov) — sezilarli sekinlashish BO'LMASLIGI kerak.
--    Sezilsa — birinchi navbatda `rbac_user_role_role_idx` va
--    `rbac_role_modda_account_idx` borligini tekshiring (1-BO'LIM, PROVODKA_RBAC.sql).
