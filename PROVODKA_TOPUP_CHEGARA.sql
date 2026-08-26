-- =====================================================================
-- PROVODKA_TOPUP_CHEGARA.sql — top-up chegarasini 500 000 so'mga qo'yish
-- ---------------------------------------------------------------------
-- MUAMMO (2026-08-26): `provodka_config.sorov_topup_chegara` = **500**.
--   Bu 500 SO'M (~4 tsent). Hech bir hodimda undan kam pul bo'lmaydi, ya'ni
--   "balans chegaradan kam" sharti HECH QACHON bajarilmagan va "Pul so'rash"
--   tugmasi doim YO'RIQNOMA modalini ochgan (top-up hech qachon taklif
--   qilinmagan). Mo'ljal — 500 000 so'm.
--
-- 🔴 NEGA `set_sorov_topup_chegara(500000)` EMAS:
--    SQL editorida so'rov `postgres` roli bilan, JWT'siz ketadi ->
--    `auth.uid()` NULL -> `is_admin()` false -> **42501**. Shuning uchun
--    `provodka_config` ga TO'G'RIDAN yoziladi (PROVODKA_SOROV_TOPUP.sql 1.3
--    dagi ogohlantirishning o'zi shuni tavsiya qiladi).
--
-- ⚠️ ADDITIVE: jadval/funksiya/imzo O'ZGARMAYDI — faqat bitta kalitning
--    qiymati. Deploy KERAK EMAS: klient chegarani har ochilishda bazadan
--    o'qiydi (`sorov_topup_chegara()`), shuning uchun sahifani yangilash
--    kifoya.
-- ⚠️ Idempotent — qayta RUN qilinsa ham xavfsiz.
-- =====================================================================


-- ############ 1-QADAM — HOZIRGI qiymatni ko'rish (o'zgartirishdan OLDIN) ############
-- ⚠️ Supabase editori ko'p statementli skriptda FAQAT OXIRGI natijani ko'rsatadi.
--    Shuning uchun bu so'rovni SICHQONCHA BILAN BELGILAB, alohida RUN qiling —
--    aks holda "oldingi qiymat" surati ekranda umuman chiqmaydi va 2-qadam uni
--    ustidan yozib yuboradi (audit qolmaydi).
select key, val, updated_by,
       (updated_at + interval '5 hours')::timestamp as ozgartirilgan_uzb
  from provodka_config
 where key = 'sorov_topup_chegara';
-- Kutilgan: val = '500'  (yoki qator umuman yo'q -> funksiya 500 qaytaradi).


-- ############ 2-QADAM — 500 000 ga qo'yish  ⚠️ YOZADI ############
-- ℹ️ NEGA EDITORDAN YOZILADI: `provodka_config` da RLS `enable` qilingan
--    (PROVODKA_V8.sql:308), `force` EMAS — jadval egasi (`postgres`, ya'ni SQL
--    editori) RLS'ni chetlab o'tadi. `authenticated` ga esa faqat `select`
--    berilgan, shuning uchun brauzerdan yozib bo'lmaydi (o'zgarmadi).
--    Agar baribir 42501 kelsa: `set local role postgres;` qo'shib qayta urining.
insert into provodka_config(key, val, updated_by, updated_at)
values ('sorov_topup_chegara', '500000', 'asilbek (sql editor)', now())
on conflict (key) do update
  set val        = excluded.val,
      updated_by = excluded.updated_by,
      updated_at = excluded.updated_at;


-- ############ 3-QADAM — TASDIQLASH ############
select c.val                       as saqlangan_qiymat,
       sorov_topup_chegara()       as funksiya_qaytargani,
       case when sorov_topup_chegara() = 500000
            then 'TO''G''RI — endi 500 000 so''mdan kam bo''lsa top-up ochiladi'
            else 'XATO — qiymat qo''llanmadi, 2-qadamni qayta RUN qiling'
       end                         as holat
  from provodka_config c
 where c.key = 'sorov_topup_chegara';
--
-- Shundan keyin brauzerda `hodim` sahifasini YANGILANG (F5) — chegara
-- `init()` da bir marta o'qiladi, ochiq tabda eski qiymat qolib ketadi.


-- ---------------------------------------------------------------------
-- ORQAGA QAYTARISH (kerak bo'lsa)
-- ---------------------------------------------------------------------
-- update provodka_config set val = '500', updated_by = 'rollback', updated_at = now()
--  where key = 'sorov_topup_chegara';
--
-- 0 qo'yilsa top-up BUTUNLAY o'chadi (0 dan kam bo'lolmaydi -> faqat yo'riqnoma).


-- ---------------------------------------------------------------------
-- ESLATMA — IKKI ZAXIRA QIYMAT ham bor (ikkalasi ham 500 edi)
-- ---------------------------------------------------------------------
--  (a) KLIENT: `hodim-dev.html` -> `SRV_CHEGARA_ZAXIRA`. RPC javob bermasa
--      (tarmoq xatosi / SQL RUN qilinmagan) shu ishlatiladi.
--      ✅ 500000 ga tuzatildi — promote'dan keyin prodda ham shunday bo'ladi.
--
--  (b) SERVER: `sorov_topup_chegara()` ichidagi `coalesce(..., 500)`.
--      U FAQAT `provodka_config` da qator BO'LMAGANDA ishlaydi. 2-qadamdan
--      keyin qator BOR, ya'ni bu default hech qachon ishlatilmaydi.
--      Shuning uchun funksiya QAYTA YOZILMADI — jonli funksiyaga keraksiz
--      tegmaslik uchun (imzo va tana o'sha-o'sha qoladi).
