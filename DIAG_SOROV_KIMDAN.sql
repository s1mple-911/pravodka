-- =====================================================================
-- DIAG_SOROV_KIMDAN.sql — "Pul so'rash" modalidagi "kimdan" ro'yxati
-- ---------------------------------------------------------------------
-- SAVOL (2026-08-26): Abror akada `sorovlar` sahifa ruxsati bor, lekin
-- `hodim.html` -> "Pul so'rash" -> "Kimdan so'rayman" ro'yxatida chiqmayapti.
-- Ro'yxat qayerdan keladi va nega tushmayapti?
--
-- ## MANBA: `sorov_kimdan()` RPC (PROVODKA_SOROVLAR.sql:761)
--    Klient (`hodim.html` -> `srvWhoLoad`) shuni chaqiradi va javobni
--    O'ZGARTIRMAYDI (server tartibi saqlanadi, sort YO'Q).
--
-- ## 🔴 SAHIFA RUXSATI YETARLI EMAS — TO'RT SHART, HAMMASI KERAK:
--    1) `user_perms` qatori BOR bo'lsin.
--       ⚠️ ADMIN da bu qator YO'Q: `admin_set_provodka_perms` admin
--          foydalanuvchining qatorini ATAYLAB o'chiradi.
--    2) `kassa_scope = 'list'`  (🔴 `'all'` BO'LMASIN)
--    3) `allowed_pages` ichida `'sorovlar'` bo'lsin
--    4) `sorov_kassa_of(user_id)` NULL qaytarmasin — ya'ni `op_kassa_ids`
--       ichida HAQIQIY UZS ildiz kassa bo'lsin. Shartlari:
--          is_active · type='aktiv' · code like '5%' · currency='UZS'
--          · pul_turi is null · kassa_turi <> 'xarajat_guruh'
--          · perm_op_key(kassa) = any(op_kassa_ids)
--    Va albatta: 5) o'zini o'zi ko'rmaydi (`up.user_id <> auth.uid()`).
--
--    SABABI (PROVODKA_SOROVLAR.sql 5-BO'LIM sarlavhasida yozilgan):
--    admin va `kassa_scope='all'` userga kassa BIRIKTIRILMAGAN, ya'ni
--    "pul QAYSI kassadan chiqadi?" savoliga javob yo'q. Pulni taxmin
--    qilingan kassadan chiqarish — eng yomon variant.
--
-- ## ⚠️ `select sorov_kimdan();` NI SQL EDITORDA CHAQIRMANG
--    Editorda so'rov JWT'siz ketadi -> `auth.uid()` NULL ->
--    funksiya ataylab `42501 Avtorizatsiya kerak` beradi.
--    Quyidagi so'rovlar o'sha mantiqni QAYTA HISOBLAYDI (RPC chaqirmasdan).
--
-- ⚠️ Hech narsa o'zgarmaydi — faqat O'QIYDI.
-- =====================================================================


-- ############ 1-SO'ROV — HAR FOYDALANUVCHI: chiqadimi, chiqmasa NEGA ############
-- 🔴 ASOSIY SO'ROV. Abror akani shu ro'yxatdan toping va `xulosa` ustunini o'qing.
select coalesce(nullif(btrim(coalesce(to_jsonb(pr) ->> 'full_name', '')), ''),
                '(ism yo''q)')                                as ism,
       coalesce(to_jsonb(pr) ->> 'role', '')                  as rol,
       (up.user_id is not null)                               as perms_qatori_bor,
       coalesce(up.kassa_scope, '(qator yo''q)')              as kassa_scope,
       ('sorovlar' = any (coalesce(up.allowed_pages, '{}'::text[]))) as sorovlar_ruxsati,
       coalesce(array_length(up.op_kassa_ids, 1), 0)          as op_kassa_soni,
       (select a.code || ' ' || a.name
          from accounts a where a.id = sorov_kassa_of(pr.id)) as topilgan_kassa,
       case
         when up.user_id is null
           then 'YO''Q: user_perms qatori yo''q (ADMIN da shunday — admin qatori ataylab o''chiriladi)'
         when coalesce(up.kassa_scope, '') <> 'list'
           then 'YO''Q: kassa_scope = ' || coalesce(up.kassa_scope, '(bo''sh)') || ' — ''list'' bo''lishi SHART'
         when not ('sorovlar' = any (coalesce(up.allowed_pages, '{}'::text[])))
           then 'YO''Q: allowed_pages ichida ''sorovlar'' yo''q'
         when sorov_kassa_of(pr.id) is null
           then 'YO''Q: op_kassa_ids ichida yaroqli UZS ildiz kassa topilmadi (2-so''rovga qarang)'
         else 'HA — ro''yxatda ko''rinadi (o''zidan boshqa hammaga)'
       end                                                    as xulosa,
       pr.id                                                  as user_id
  from profiles pr
  left join user_perms up on up.user_id = pr.id
 order by 8, 1;
--
-- 🔴 ESLATMA: `xulosa` = "HA" bo'lsa ham, foydalanuvchi O'Z ro'yxatida
--    o'zini KO'RMAYDI. Agar siz Abror akaning hisobiga kirib turgan
--    bo'lsangiz, u ro'yxatda chiqmasligi TO'G'RI (o'zidan pul so'ralmaydi).


-- ############ 2-SO'ROV — "UZS ildiz kassa topilmadi" sababi ############
-- 1-so'rov `sorov_kassa_of` da to'xtagan bo'lsa, o'sha odamning
-- `op_kassa_ids` idagi HAR kassa qaysi shartda yiqilganini ko'rsatadi.
-- 🔴 user_id ni 1-so'rovdan ko'chirib qo'ying.
-- select a.code, a.name, a.subtitle,
--        a.is_active, a.type, coalesce(a.currency, 'UZS') as valyuta,
--        a.pul_turi, a.kassa_turi,
--        (perm_op_key(a.id) = any (up.op_kassa_ids))       as ruxsatda_bor,
--        case
--          when a.is_active is not true                    then 'YO''Q: is_active emas'
--          when a.type <> 'aktiv'                          then 'YO''Q: type <> aktiv'
--          when a.code not like '5%'                       then 'YO''Q: kod 5 bilan boshlanmaydi'
--          when coalesce(a.currency, 'UZS') <> 'UZS'       then 'YO''Q: valyuta kassasi'
--          when a.pul_turi is not null                     then 'YO''Q: pul turi bolasi (Naqd/Click...), ildiz emas'
--          when a.kassa_turi = 'xarajat_guruh'             then 'YO''Q: konteyner hisob (5400)'
--          when not (perm_op_key(a.id) = any (up.op_kassa_ids)) then 'YO''Q: op_kassa_ids da emas'
--          else 'YAROQLI — shu kassa tanlanadi'
--        end                                               as tahlil
--   from user_perms up
--   join accounts a on a.id = any (up.op_kassa_ids)
--  where up.user_id = 'BU_YERGA_USER_ID'
--  order by a.code;
--
-- Hamma qatorda "YO'Q" chiqsa -> odamga to'g'ri kassa biriktirilmagan.
-- Ko'p uchraydigan xato: `op_kassa_ids` ga ILDIZ kassa o'rniga uning
-- "· Naqd" / "· Click" BOLASI yozilgan (`pul_turi` to'la) yoki USD bolasi.


-- ############ 3-SO'ROV — Abror akani ro'yxatga QANDAY qo'shish ############
-- Tuzatish Provodka'da EMAS — `admin-dev.html` -> ruxsatlar oynasida:
--   (a) `kassa_scope` = 'list' qilinsin (hamma kassa = 'all' EMAS);
--   (b) unga O'Z ildiz UZS kassasi biriktirilsin (op ro'yxatiga);
--   (c) `sorovlar` sahifasi belgilansin.
-- Uchalasi ham bo'lsa — keyingi ochilishda ro'yxatda chiqadi
-- (klientda 5 daqiqalik kesh bor: `prov-swr:hodim:srvwho`, F5 yetarli).
--
-- Hozirgi holatni ko'rish uchun:
-- select up.user_id,
--        coalesce(nullif(btrim(coalesce(to_jsonb(pr) ->> 'full_name', '')), ''), '(ism yo''q)') as ism,
--        up.kassa_scope,
--        up.allowed_pages,
--        up.op_kassa_ids,
--        up.view_kassa_ids,
--        up.can_convert
--   from user_perms up
--   left join profiles pr on pr.id = up.user_id
--  where coalesce(nullif(btrim(coalesce(to_jsonb(pr) ->> 'full_name', '')), ''), '') ilike '%abror%';


-- ############ 4-SO'ROV — ro'yxat AYNAN kim bo'ladi (RPC mantiqi) ############
-- `sorov_kimdan()` ning ichki so'rovi, faqat `auth.uid()` filtri olib tashlangan
-- (editorda u NULL). Ya'ni: "har bir hodim shu odamlarni ko'radi, o'zidan tashqari".
-- select up.user_id,
--        sorov_ism(up.user_id, k.id)                        as nom,
--        nullif(btrim(coalesce(k.subtitle, '')), '')        as subtitle,
--        k.code || ' ' || k.name                            as kassa
--   from user_perms up
--   join profiles pr on pr.id = up.user_id
--   join accounts k  on k.id = sorov_kassa_of(up.user_id)
--  where up.kassa_scope = 'list'
--    and 'sorovlar' = any (coalesce(up.allowed_pages, '{}'::text[]))
--  order by 2;
--
-- Bu ro'yxat BO'SH bo'lsa — hech kimda to'rtala shart to'liq emas.
-- Abror aka bu yerda BOR, lekin modalda YO'Q bo'lsa: siz uning
-- hisobiga kirgansiz (o'zini ko'rmaydi) yoki klient keshi eski (F5).
