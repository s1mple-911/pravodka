-- =====================================================================
--  ⚠️⚠️  SUPABASE SQL EDITOR — QANDAY RUN QILINADI (avval SHUNI o'qing)
-- ---------------------------------------------------------------------
--   1) Bu faylda anonim blok (`do ...`) UMUMAN YO'Q va dollar-quote
--      belgisi (ikki dollar yonma-yon) FAQAT funksiya tanasining boshi
--      va oxirida — izohlarda umuman yo'q, ichma-ich ham yo'q.
--      Sabab: Supabase SQL Editor anonim blokni bo'lib yuborardi va
--      PL/pgSQL o'zgaruvchisini jadval deb izlardi
--      (`ERROR: 42P01: relation "v_def" does not exist`) — besh xil faylda
--      takrorlandi. `create or replace function ... as` esa muammosiz
--      ishlaydi. Shuning uchun MANTIQ O'ZGARMAGAN holda qayta qadoqlandi:
--        • tekshiruv bloklari  -> oddiy `select` (natijada `holat` ustuni)
--        • shartli DDL bloklari -> funksiya + `select f();`
--
--   2) Tartib:
--        1-BO'LIM   — PREFLIGHT (5 ta tekshiruv, HECH NARSA YOZMAYDI)
--        2..8.5     — DDL: cheklov, kod bloklari, funksiyalar, trigger
--        9-BO'LIM   — o'zini tekshiruv (HECH NARSA YOZMAYDI)
--        10-BO'LIM  — ko'rish so'rovlari (HECH NARSA YOZMAYDI)
--        11-BO'LIM  — BACKFILL (funksiya yaratiladi, CHAQIRUVI izohda)
--        12-BO'LIM  — orqaga qaytarish (izohda)
--
--   3) Butun faylni tepadan pastgacha RUN qilsa bo'ladi (idempotent),
--      LEKIN Supabase faqat OXIRGI statement natijasini ko'rsatadi.
--      Tekshiruv natijalarini ko'rish uchun har bo'lakni ⬇⬇⬇ va ⬆⬆⬆
--      belgilari orasidan ALOHIDA belgilab RUN qiling.
--
--   4) 🔴 PREFLIGHT endi faylni O'ZI TO'XTATMAYDI (avval `raise exception`
--      qilardi). Natijada ❌ ko'rsangiz PASTINI RUN QILMANG — avval
--      sababini hal qiling. ✅ / ⚠️ bo'lsa davom eting.
-- =====================================================================

-- =====================================================================
--  PROVODKA_TURLAR_AVTO.sql
--  Yangi hodim kassasiga PUL TURLARI avtomatik ochilsin
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  TALAB (Asilbek): "har user yaratilganda unga kassa yaratilsa hammasida
--  turlar bo'lsin — naqd, karta, payme, click. Ular qiynalib qolmasin."
--
--  Hozir: TaskFix `upsert_hodim_kassa()` orqali 5401+ hodim kassasini ochadi,
--  turlar esa QO'LDA (`create_pul_turi_child`) ochilishi kerak edi. 60+ hodim
--  bo'lgani uchun bu ish qo'lda bajarilmay qolgan.
--
--  BU FAYL NIMA QILADI:
--    1. `create_pul_turi_child` ga yangi turlar: karta / terminal / plastik
--       (imzo O'ZGARMAYDI: create_pul_turi_child(uuid, text) -> uuid)
--    2. Kod diapazoni kengaytirildi — 4 xonali bloklar to'lganda 5 xonali
--       bloklarga o'tadi (`pul_turi_kod_blok.raqam_uzunlik`)
--    3. Yangi RPC `hodim_kassa_turlar_toldir(uuid, boolean)` — bitta kassaga
--       standart turlarni (naqd/click/payme/karta) ochadi, idempotent
--    4. `accounts` ustidagi AFTER INSERT trigger — yangi hodim kassasiga
--       turlar O'ZI ochiladi (TaskFix tomonda hech narsa o'zgarmaydi)
--    5. Yangi RPC `pul_turi_ochir(uuid)` — xato ochilgan tur hisobini YOPADI
--       (is_active=false, HECH QACHON delete emas). Qoldiq 0 bo'lishi shart.
--       `create_pul_turi_child` yopilganini qayta yoqadi (yangi kod yemaydi).
--    6. BACKFILL — mavjud hodim kassalari uchun (chaqiruvi izohda, ALOHIDA RUN)
--
--  ⛔⛔ 0-TALAB — AVVAL PROMOTE, KEYIN RUN:  bash promote.sh hodim
--    ⛔ AVVAL 'bash promote.sh hodim' — prod hodim.html tur bolalarini
--       bilmaydi. Promote qilinmasa 60+ hodimda kassa tanlagich buziladi.
--       Bu SQL'ni promote'dan KEYIN RUN qiling.
--
--    NEGA: Supabase dev va prod uchun BITTA baza. Bu SQL RUN bo'lishi bilan
--    hodim kassalarida tur bolalari (naqd/click/payme/karta) paydo bo'ladi.
--    PROD `hodim.html` esa `pul_turi` / `isSubChild` mantig'ini BILMAYDI —
--    uning `kassaList()` si (hodim.html:496-503) faqat `currency==='UZS'`
--    bilan filtrlaydi. Ya'ni tur bolalari ALOHIDA KASSA bo'lib ro'yxatga
--    chiqadi va prod'da darrov quyidagi buziladi:
--      • bitta kassali hodim 5 ta "kassa" ko'radi (ildiz + 4 tur),
--      • bitta kassa bo'lganda avtomat tanlash yo'qoladi,
--      • `renderKassaBal` noto'g'ri qoldiq ko'rsatadi (ildizda pul turmaydi).
--    Tartib: 1) bash promote.sh hodim  2) prod hodim.html tekshirildi
--            3) SHU FAYL RUN QILINADI.
--
--  ⚠️ BU FAYLDAN OLDIN RUN QILINGAN BO'LISHI SHART:
--    • PROVODKA_VALYUTA.sql        — accounts.pul_turi, pul_turi_kod_blok,
--                                    create_pul_turi_child, v_kassa_turlar
--    • PROVODKA_PERM_TUR_FIX.sql   — perm_op_key() tur bolasini PARENT
--      kassaga bog'laydi. Bu tuzatmasiz yangi turlar cheklangan
--      (kassa_scope='list') foydalanuvchilar uchun ruxsatdan CHETDA qoladi
--      va entry_line guard triggeri 42501 beradi. Quyida 1.3-bo'lim buni
--      TEKSHIRADI va noto'g'ri bo'lsa ❌ ko'rsatadi (to'xtang).
--      (PROVODKA_VALYUTA.sql ning 7-bo'limi ham ayni tuzatmani beradi —
--       ikkalasidan biri yetarli.)
--
--  ADDITIVE: ustun/funksiya/view O'CHIRILMAYDI, imzo o'zgarmaydi.
--  UCH joyda ataylab "kengaytirish" bor (uchtasi ham faqat BO'SHATADI,
--  hech qaysi mavjud qator/chaqiruv buzilmaydi — 2, 3 va 4-bo'limlarga qara):
--    • accounts_pul_turi_chk       — ruxsat etilgan turlar ro'yxati kengaydi
--    • pul_turi_kod_blok(prefix)   — unique endi (prefix, raqam_uzunlik) bo'yicha
--    • create_pul_turi_child ichidagi "ota bola-hisob bo'lmasin" sharti —
--      `parent_id is not null` o'rniga `pul_turi is not null`. Eski shart
--      HODIM KASSASINI (parent = 5400 konteyner) ham rad etardi, ya'ni
--      hodim kassasiga tur ochish umuman mumkin emas edi (4-bo'limga qara).
--
--  QADOQLASH uchun qo'shilgan YORDAMCHI funksiyalar (mantiq o'zgarmagan,
--  ular avval `do` bloki edi; hammasi public/anon/authenticated dan revoke):
--    • turlar_avto_perm_tekshir()  — 1.3 preflight (perm_op_key ni dinamik
--                                    chaqiradi, shuning uchun `select` emas)
--    • turlar_avto_chk_yangila()   — 2-bo'lim, accounts_pul_turi_chk
--    • turlar_avto_blok_chk()      — 3.1, pul_turi_kod_blok_uzunlik_chk
--    • turlar_avto_uniq_yangila()  — 3.2, eski `prefix unique` ni olib tashlash
--    • hodim_turlar_backfill()     — 11.2 (CHAQIRUVI IZOHDA)
--
--  Bir necha marta RUN qilish xavfsiz (idempotent).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. PREFLIGHT — bog'liqliklar joyidami.  HECH NARSA YOZMAYDI.
-- ---------------------------------------------------------------------
-- Har bo'lakni ALOHIDA belgilab RUN qiling. `holat` ustunida ❌ bo'lsa
-- pastini RUN QILMANG.

-- 1.1 PROVODKA_VALYUTA.sql RUN qilinganmi
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
select 'pul_turi_kod_blok jadvali' as tekshiruv,
       case when to_regclass('public.pul_turi_kod_blok') is not null
            then '✅ OK' else '❌ MUAMMO' end as holat,
       case when to_regclass('public.pul_turi_kod_blok') is not null then '—'
            else 'pul_turi_kod_blok jadvali yo''q — avval PROVODKA_VALYUTA.sql ni RUN qiling' end as izoh
union all
select 'create_pul_turi_child(uuid,text)',
       case when to_regprocedure('public.create_pul_turi_child(uuid,text)') is not null
            then '✅ OK' else '❌ MUAMMO' end,
       case when to_regprocedure('public.create_pul_turi_child(uuid,text)') is not null then '—'
            else 'create_pul_turi_child yo''q — avval PROVODKA_VALYUTA.sql ni RUN qiling' end
union all
select 'accounts.pul_turi ustuni',
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'accounts'
                            and column_name = 'pul_turi')
            then '✅ OK' else '❌ MUAMMO' end,
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'accounts'
                            and column_name = 'pul_turi') then '—'
            else 'accounts.pul_turi ustuni yo''q — avval PROVODKA_VALYUTA.sql' end;
-- ⬆⬆⬆  1.1 shu yerda tugadi  ⬆⬆⬆

-- 1.2 accounts.code ga 5 xonali kod sig'adimi.
--     Kod `text` bo'lsa cheklov yo'q (character_maximum_length = NULL).
--     varchar(4) bo'lsa 5 xonali blok ishlamaydi — JIMGINA o'tkazib yubormaymiz.
--     ⚠️ 5 raqami `pul_turi_kod_blok_uzunlik_chk` (3.1) bilan MOS: prefiks 2 belgi
--        + raqam_uzunlik ko'pi bilan 3 = eng uzun kod 5 belgi. Cheklovni
--        `raqam_uzunlik = 4` gacha kengaytirsangiz, bu yerdagi 5 ni ham 6 qiling.
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
select 'accounts.code uzunligi' as tekshiruv,
       coalesce(c.character_maximum_length::text, 'text (cheklovsiz)') as uzunlik,
       case when c.character_maximum_length is not null
             and c.character_maximum_length < 5
            then '❌ MUAMMO' else '✅ OK' end as holat,
       case when c.character_maximum_length is not null
             and c.character_maximum_length < 5
            then 'accounts.code uzunligi ' || c.character_maximum_length::text ||
                 ' — 5 xonali kod sig''maydi. Avval: alter table accounts alter column code type text;'
            else '—' end as izoh
  from information_schema.columns c
 where c.table_schema = 'public' and c.table_name = 'accounts' and c.column_name = 'code';
-- ⬆⬆⬆  1.2 shu yerda tugadi  ⬆⬆⬆

-- 1.3 ⭐ RUXSAT TEKSHIRUVI — perm_op_key tur bolasini parentga bog'laydimi.
--     Bog'lamasa, bu fayl ochadigan yuzlab yangi tur hisobi cheklangan
--     foydalanuvchilar uchun ishlamaydi (42501). Shuning uchun ❌ chiqsa
--     PASTINI RUN QILMANG.
--
--     IKKI QATLAM (ikkalasi ham kerak):
--       (a) FUNKSIYA TA'RIFI — asosiy. Mavjud ma'lumotga tayanmaydi.
--           Eski tekshiruv faqat mavjud `pul_turi is not null` hisoblarni
--           sanardi: bitta ham bo'lmasa (yoki hammasi is_active=false)
--           tekshiruv JIMGINA o'tardi va eski perm_op_key bilan 240 ta
--           ishlamaydigan hisob ochilardi — cheklangan userlar har
--           xarajatda 42501 olardi. Endi ta'rifning o'zi tekshiriladi.
--       (b) MAVJUD MA'LUMOT — qo'shimcha qatlam (ta'rif to'g'ri, lekin
--           amalda boshqacha ishlayotgan holatni ushlaydi).
--
--     NEGA FUNKSIYA (oddiy `select` emas): (b) qatlami `perm_op_key(...)` ni
--     chaqiradi, funksiya bo'lmasa esa oddiy `select` PARSE bosqichidayoq
--     yiqilardi. Funksiya ichida u `execute` bilan chaqiriladi, ya'ni
--     "perm_op_key yo'q" holati eskisidek jimgina o'tkazib yuboriladi.
-- ⬇⬇⬇  1.3: SHU QATORDAN pastdagi `select * from turlar_avto_perm_tekshir();` GACHA  ⬇⬇⬇
create or replace function turlar_avto_perm_tekshir()
returns table(tekshiruv text, holat text, izoh text)
language plpgsql
as $$
declare
  n      int;
  n_bor  int;
  v_def  text;
  v_root text;
  v_ok   boolean := false;
begin
  if to_regprocedure('public.perm_op_key(uuid)') is null then
    tekshiruv := 'perm_op_key(uuid)';
    holat     := '⚠️ O''TKAZIB YUBORILDI';
    izoh      := 'perm_op_key yo''q — ruxsat tizimi o''rnatilmagan, tekshiruv o''tkazib yuborildi';
    return next;
    return;
  end if;

  -- (a) TA'RIF bo'yicha: `pul_turi` sharti bormi.
  --     Ikki to'g'ri variant bor:
  --       • PROVODKA_PERM_TUR_FIX.sql — shart to'g'ridan perm_op_key ichida
  --       • PROVODKA_VALYUTA.sql 7-bo'lim — perm_op_key kassa_root() ga delegat,
  --         shart o'sha yerda. Shuning uchun kassa_root ta'rifi ham qaraladi.
  v_def := pg_get_functiondef(to_regprocedure('public.perm_op_key(uuid)')::oid);

  if v_def ilike '%pul_turi%' then
    v_ok := true;
  elsif v_def ilike '%kassa_root%' then
    if to_regprocedure('public.kassa_root(uuid)') is null then
      tekshiruv := '(a) perm_op_key ta''rifi';
      holat     := '❌ MUAMMO — TO''XTANG';
      izoh      := 'perm_op_key kassa_root() ni chaqiryapti, lekin kassa_root(uuid) yo''q — avval PROVODKA_VALYUTA.sql ni RUN qiling';
      return next;
      return;
    end if;
    v_root := pg_get_functiondef(to_regprocedure('public.kassa_root(uuid)')::oid);
    v_ok   := v_root ilike '%pul_turi%';
  end if;

  if not v_ok then
    tekshiruv := '(a) perm_op_key ta''rifi';
    holat     := '❌ MUAMMO — TO''XTANG';
    izoh      := 'perm_op_key() ta''rifida `pul_turi` sharti YO''Q — tur bola-hisoblari cheklangan (kassa_scope=''list'') foydalanuvchilar uchun ruxsatdan chetda qoladi va entry_line guard triggeri 42501 beradi. AVVAL PROVODKA_PERM_TUR_FIX.sql ni RUN qiling (yoki PROVODKA_VALYUTA.sql 7-bo''limini).';
    return next;
    return;
  end if;

  tekshiruv := '(a) perm_op_key ta''rifi';
  holat     := '✅ OK';
  izoh      := 'ta''rifda `pul_turi` sharti bor';
  return next;

  -- (b) MAVJUD MA'LUMOT bo'yicha (eski tekshiruv — saqlanadi).
  --     Bitta ham tur hisobi bo'lmasligi normal (bu fayl aynan ularni ochadi),
  --     shuning uchun bu qatlam yolg'iz o'zi yetarli emas — (a) bilan birga ishlaydi.
  execute 'select count(*), count(*) filter (where perm_op_key(c.id) is distinct from c.parent_id)
             from accounts c
            where c.is_active
              and c.pul_turi is not null
              and c.parent_id is not null'
    into n_bor, n;

  if n > 0 then
    tekshiruv := '(b) mavjud tur hisoblari';
    holat     := '❌ MUAMMO — TO''XTANG';
    izoh      := 'perm_op_key tur bola-hisobini parent kassaga bog''lamayapti (' || n::text ||
                 ' ta hisob) — avval PROVODKA_PERM_TUR_FIX.sql ni RUN qiling';
    return next;
    return;
  end if;

  tekshiruv := '(b) mavjud tur hisoblari';
  holat     := '✅ OK';
  izoh      := 'perm_op_key OK: ta''rifda pul_turi sharti bor + mavjud ' || n_bor::text ||
               ' ta tur hisobi tekshirildi';
  return next;
  return;
end $$;

revoke all on function turlar_avto_perm_tekshir() from public, anon, authenticated;

comment on function turlar_avto_perm_tekshir() is
  'PREFLIGHT 1.3: perm_op_key() tur bola-hisobini parent kassaga bog''laydimi. '
  'Hech narsa yozmaydi, faqat tekshiradi.';

select * from turlar_avto_perm_tekshir();
-- ⬆⬆⬆  1.3 shu yerda tugadi  ⬆⬆⬆

-- 1.4 Trigger sharti mavjud hodim kassalariga mos keladimi.
--     Trigger WHEN sharti `section='pul'` ga tayanadi. TaskFix
--     (`upsert_hodim_kassa`, tanasi repoda yo'q) kassani section'siz ochsa,
--     trigger JIMGINA ishlamay qolardi — shuning uchun ochiq tekshiramiz.
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
with h as (
  select count(*)                                          as n_bor,
         count(*) filter (where p.section is distinct from 'pul') as n_sectionsiz
    from accounts p
    join accounts g on g.id = p.parent_id and g.kassa_turi = 'xarajat_guruh'
   where p.is_active and p.kassa_turi = 'xarajat' and p.pul_turi is null
)
select 'Trigger sharti (section=''pul'')' as tekshiruv,
       h.n_bor                            as hodim_kassa,
       h.n_sectionsiz                     as sectionsiz,
       case when h.n_bor = 0            then '⚠️ KASSA YO''Q'
            when h.n_sectionsiz > 0     then '⚠️ DIQQAT'
            else '✅ OK' end              as holat,
       case when h.n_bor = 0
              then 'Hodim kassasi topilmadi (5400 konteyner bo''sh) — trigger baribir o''rnatiladi'
            when h.n_sectionsiz > 0
              then 'DIQQAT: ' || h.n_sectionsiz::text || ' / ' || h.n_bor::text ||
                   ' ta hodim kassasida section <> ''pul'' — trigger ular uchun ishlamaydi (10.2 so''rovi bilan ko''ring)'
            else 'Hodim kassalari: ' || h.n_bor::text || ' ta, hammasi section=''pul'' — trigger sharti mos'
       end                                as izoh
  from h;
-- ⬆⬆⬆  1.4 shu yerda tugadi  ⬆⬆⬆

-- 1.5 👀 PREVIEW — bazada HOZIR qanday pul turlari bor.
--     2-bo'lim `accounts_pul_turi_chk` ni drop+add qiladi; ro'yxatdan tashqari
--     qiymat bo'lsa yangi cheklov o'rnatilmaydi (add constraint xato beradi va
--     jadval CHEKLOVSIZ qolib ketardi). Shuning uchun avval KO'RAMIZ, keyin
--     2-bo'lim boshida qat'iy TEKSHIRAMIZ (u yerda `raise exception` — hech
--     narsaga tegmasdan to'xtaydi).
--
--     Batafsil jadval ko'rinishida kerak bo'lsa — quyidagi so'rovni ALOHIDA RUN qiling:
--
--       select pul_turi, count(*) as nechta
--         from accounts
--        where pul_turi is not null
--        group by pul_turi
--        order by pul_turi;
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
with t as (
  select pul_turi, count(*) as n
    from accounts
   where pul_turi is not null
   group by pul_turi
),
notanish as (
  select string_agg(distinct pul_turi, ', ') as s
    from accounts
   where pul_turi is not null
     and pul_turi not in ('naqd','click','payme','karta','terminal','plastik')
)
select coalesce((select string_agg(t.pul_turi || '=' || t.n::text, ', ' order by t.pul_turi) from t),
                '(bitta ham yo''q)')                as mavjud_turlar,
       coalesce(n.s, '—')                          as royxatdan_tashqari,
       case when n.s is not null then '⚠️ DIQQAT' else '✅ OK' end as holat,
       case when n.s is not null
              then 'DIQQAT: ro''yxatdan TASHQARI pul turi bor: ' || n.s ||
                   ' — 2-bo''lim to''xtaydi. Avval ularni to''g''rilang yoki 2-bo''limdagi ro''yxatga qo''shing.'
            else '—' end                           as izoh
  from notanish n;
-- ⬆⬆⬆  1.5 shu yerda tugadi  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2. accounts_pul_turi_chk — yangi turlar (karta / terminal / plastik)
-- ---------------------------------------------------------------------
-- Nega drop+add: CHECK cheklovini "kengaytirish" boshqa yo'l bilan bo'lmaydi.
-- Bu XAVFSIZ, chunki ro'yxat faqat KENGAYADI — eski qiymatlar
-- (naqd/click/payme) o'z joyida qoladi, ya'ni birorta mavjud qator
-- cheklovni buza olmaydi. Jadval kichik (yuzlab qator) — skan tez.
--
-- Nomlar hodim-dev.html dagi TURI_LBL bilan AYNAN mos:
--   naqd->Naqd, click->Click, payme->Payme, terminal->Terminal,
--   karta->Karta, plastik->Plastik
--
-- ⚠️ AVVAL TEKSHIRAMIZ, KEYIN DROP: agar bazada ro'yxatdan tashqari qiymat
--    bo'lsa, `add constraint` yiqiladi va cheklov drop qilingandan keyin
--    QAYTA O'RNATILMAY qolib ketardi (jadval himoyasiz qoladi). Shuning
--    uchun mos kelmagan qiymatni OLDINDAN topamiz va hech narsaga tegmasdan
--    to'xtaymiz (`raise exception` — bu yerda ATAYLAB saqlangan: cheklov
--    drop bo'lgan holatda davom etib bo'lmaydi). Ro'yxatni preflight 1.5 ham
--    ko'rsatadi.
-- ⬇⬇⬇  2: SHU QATORDAN pastdagi `select turlar_avto_chk_yangila();` GACHA  ⬇⬇⬇
create or replace function turlar_avto_chk_yangila()
returns text
language plpgsql
as $$
declare v_notanish text;
begin
  select string_agg(distinct pul_turi, ', ')
    into v_notanish
    from accounts
   where pul_turi is not null
     and pul_turi not in ('naqd','click','payme','karta','terminal','plastik');

  if v_notanish is not null then
    raise exception
      'accounts.pul_turi da ro''yxatdan TASHQARI qiymat(lar) bor: %. Eski cheklov TEGILMADI. Yo o''sha qatorlarni to''g''rilang, yo quyidagi ro''yxatga (2-bo''lim + _pul_turi_child_ich dagi v_lbl case) o''sha turni qo''shing.',
      v_notanish;
  end if;

  if exists (select 1 from pg_constraint
              where conname = 'accounts_pul_turi_chk'
                and conrelid = 'public.accounts'::regclass) then
    alter table accounts drop constraint accounts_pul_turi_chk;
  end if;
  alter table accounts add constraint accounts_pul_turi_chk
    check (pul_turi is null
           or pul_turi in ('naqd','click','payme','karta','terminal','plastik'));

  return '✅ OK — accounts_pul_turi_chk yangilandi (naqd|click|payme|karta|terminal|plastik)';
end $$;

revoke all on function turlar_avto_chk_yangila() from public, anon, authenticated;

comment on function turlar_avto_chk_yangila() is
  '2-bo''lim: accounts_pul_turi_chk ni yangi turlar bilan qayta o''rnatadi. '
  'Ro''yxatdan tashqari qiymat bo''lsa hech narsaga tegmay xato beradi.';

select turlar_avto_chk_yangila() as natija;
-- ⬆⬆⬆  2 shu yerda tugadi  ⬆⬆⬆

comment on column accounts.pul_turi is
  'Pul turi bola-hisobi: naqd|click|payme|karta|terminal|plastik. '
  'NULL = oddiy kassa yoki valyuta bolasi.';


-- ---------------------------------------------------------------------
-- 3. KOD DIAPAZONI — 4 xonali bloklar to'layapti
-- ---------------------------------------------------------------------
-- MUAMMO: `pul_turi_kod_blok` da 3 ta prefiks (55, 53, 51), har biri
--   `^prefix[0-9]{2}$` — ya'ni 3 x 99 = ~297 ta kod, va ularning bir qismi
--   allaqachon band (5110 markaziy kassa, eski 53xx xarajat kassalari,
--   qo'lda ochilgan 5351/5352 "· Naqd/· Payme" hisoblari...).
--   60+ hodim x 4 tur = 240+ yangi hisob → blok to'ladi va funksiya
--   "Tur kod bloklari to'ldi" xatosini beradi.
--
-- 5xxx fazosi band: 50 markaziy kassa, 51/53/55 tur, 52 filial,
--   54 hodim, 56 USD, 57 CNY, 58/59 valyutaga zaxira. Ya'ni 4 xonali
--   sxemada BO'SH prefiks umuman qolmagan.
--
-- YECHIM: kod uzunligini blokning o'ziga xos xususiyati qilamiz —
--   `raqam_uzunlik` ustuni. '55' + 3 raqam = 55000..55999 (1000 ta kod).
--   `^55[0-9]{3}$` mavjud `^55[0-9]{2}$` (5500..5599) bilan TO'QNASHMAYDI:
--   uzunlik boshqa, ya'ni bir kod ikkala naqshga tusha olmaydi.
--   Yangi bloklar nav 4/5/6 — ya'ni AVVAL 4 xonalilar to'ladi, keyin 5 xonali.
--
-- ⚠️ 5 XONALI KODNING TA'SIRI (tekshirilgan, sindiruvchi joy topilmadi):
--   • SQL kod tanlagichlari (`create_valyuta_child`, PROVODKA_KAPITAL,
--     PROVODKA_SYNC_FIX*, PROVODKA_VALYUTA_SEED) hammasi
--     `code ~ '^NN[0-9]{2}$'` bilan filtrlab, keyin `::int` qiladi —
--     5 xonali kod naqshga TUSHMAYDI, cast ham, max ham buzilmaydi.
--   • `code like '5%'` filtrlar (v_pul_hisoblar, v_kassa_*, PERMS, TUR_BOGLASH)
--     5 xonali kodni ham oladi — bu TO'G'RI, u haqiqatan pul hisobi.
--   • sozlama(-dev).html `nextCode('50',5011)`:
--       parseInt(code) → String(n).startsWith('50')
--     Yangi bloklar 55/53/51 bilan boshlanadi, '50' bilan EMAS — shuning
--     uchun 50xx kassa kodi berish buzilmaydi. ⚠️ Kelajakda `('50', 3)`
--     bloki QO'SHILMASIN: u holda 50123 → nextCode 50124 qaytarardi.
--     `nextCode('94')` / `nextCode('90')` 5xxx ga umuman tegmaydi.
--   • klient `isKassa()` = `type==='aktiv' && code.startsWith('5')` — ishlaydi.
--   • `v_kassa_card` / `v_kassa_toliq` kod uzunligiga tayanmaydi
--     (section/currency/pul_turi/parent_id bo'yicha ishlaydi).
--   • Kod bo'yicha saralash matn bo'yicha: '5500' < '55000' < '5501' —
--     ro'yxat tartibi biroz aralashadi, funksional zarar yo'q.

-- 3.1 Ustun + uzunlik cheklovi
-- ⚠️ Yuqori chegara 3 — preflight 1.2 bilan MOS. 1.2 accounts.code ga
--    ATIGI 5 belgi sig'ishini kafolatlaydi (2 belgili prefiks + 3 raqam).
--    `4` ga ruxsat berilsa 6 belgili kod (550001) paydo bo'lardi va u
--    varchar(5) ustunda RUN paytida yiqilardi — ikkisi bir xil bo'lsin.
--    Kengaytirish kerak bo'lsa: avval 1.2 dagi 5 ni 6 qiling, keyin bu yerni.
-- ⬇⬇⬇  3.1: SHU QATORDAN pastdagi `select turlar_avto_blok_chk();` GACHA  ⬇⬇⬇
alter table pul_turi_kod_blok
  add column if not exists raqam_uzunlik int not null default 2;

create or replace function turlar_avto_blok_chk()
returns text
language plpgsql
as $$
begin
  if not exists (select 1 from pg_constraint where conname = 'pul_turi_kod_blok_uzunlik_chk') then
    alter table pul_turi_kod_blok add constraint pul_turi_kod_blok_uzunlik_chk
      check (raqam_uzunlik between 2 and 3);
    return '✅ OK — pul_turi_kod_blok_uzunlik_chk qo''shildi (raqam_uzunlik 2..3)';
  end if;
  return '✅ OK — pul_turi_kod_blok_uzunlik_chk allaqachon bor (tegilmadi)';
end $$;

revoke all on function turlar_avto_blok_chk() from public, anon, authenticated;

comment on function turlar_avto_blok_chk() is
  '3.1-bo''lim: pul_turi_kod_blok.raqam_uzunlik ga 2..3 cheklovini qo''shadi (bo''lmasa).';

select turlar_avto_blok_chk() as natija;
-- ⬆⬆⬆  3.1 shu yerda tugadi  ⬆⬆⬆

comment on column pul_turi_kod_blok.raqam_uzunlik is
  'Prefiksdan keyingi raqamlar soni: 2 -> 5501, 3 -> 55001 (ruxsat: 2..3, '
  'preflight 1.2 dagi accounts.code uzunligi bilan mos). Kod naqshi: ^prefix[0-9]{raqam_uzunlik}$';

-- 3.2 Eski `prefix unique` cheklovini (prefix, raqam_uzunlik) ga kengaytiramiz.
--     Aks holda ('55',3) qatorini qo'shib bo'lmaydi — '55' allaqachon bor.
--     Bu BO'SHATISH: avval taqiqlangan hech narsa endi ham taqiq
--     (bir xil prefiks + bir xil uzunlik ikki marta bo'lolmaydi).
-- ⬇⬇⬇  3.2: SHU QATORDAN pastdagi `select turlar_avto_uniq_yangila();` GACHA  ⬇⬇⬇
create or replace function turlar_avto_uniq_yangila()
returns text
language plpgsql
as $$
declare
  c      record;
  v_list text := '';
begin
  for c in
    select con.conname
      from pg_constraint con
     where con.conrelid = 'public.pul_turi_kod_blok'::regclass
       and con.contype = 'u'
       and array_length(con.conkey, 1) = 1
       and con.conkey[1] = (select attnum from pg_attribute
                             where attrelid = 'public.pul_turi_kod_blok'::regclass
                               and attname = 'prefix')
  loop
    execute format('alter table pul_turi_kod_blok drop constraint %I', c.conname);
    raise notice 'Eski unique cheklov olib tashlandi: %', c.conname;
    v_list := v_list || case when v_list = '' then '' else ', ' end || c.conname;
  end loop;

  if v_list = '' then
    return '✅ OK — olib tashlanadigan eski `prefix unique` cheklov yo''q';
  end if;
  return '✅ OK — eski unique cheklov olib tashlandi: ' || v_list;
end $$;

revoke all on function turlar_avto_uniq_yangila() from public, anon, authenticated;

comment on function turlar_avto_uniq_yangila() is
  '3.2-bo''lim: pul_turi_kod_blok(prefix) ustidagi bir ustunli unique cheklovlarni olib tashlaydi.';

select turlar_avto_uniq_yangila() as natija;
-- ⬆⬆⬆  3.2 shu yerda tugadi  ⬆⬆⬆

create unique index if not exists pul_turi_kod_blok_prefix_uzunlik_uniq
  on pul_turi_kod_blok(prefix, raqam_uzunlik);

-- 3.3 5 xonali bloklar — nav 4/5/6, ya'ni 4 xonalilardan KEYIN ishlatiladi
insert into pul_turi_kod_blok(nav, prefix, raqam_uzunlik) values
  (4, '55', 3),
  (5, '53', 3),
  (6, '51', 3)
on conflict (nav) do nothing;

comment on table pul_turi_kod_blok is
  'Tur bola-hisoblariga kod beriladigan bloklar. nav tartibida ishlatiladi, '
  'kod naqshi ^prefix[0-9]{raqam_uzunlik}$. Valyuta bloklariga tegmaydi.';


-- ---------------------------------------------------------------------
-- 4. _pul_turi_child_ich — ICHKI yaratuvchi (ADMIN TEKSHIRUVISIZ)
-- ---------------------------------------------------------------------
-- NEGA ALOHIDA: trigger ichida `auth.uid()` NULL bo'ladi (TaskFix kassani
-- service_role orqali yaratadi), ya'ni `create_pul_turi_child` ning admin
-- tekshiruvi triggerni har safar yiqitardi. Shuning uchun mantiq ikkiga
-- bo'lindi:
--    _pul_turi_child_ich  — yaratish mantiqi, ruxsat tekshirmaydi
--    create_pul_turi_child — public yuz, ADMIN tekshiruvi shu yerda qoladi
--
-- ⚠️ XAVFSIZLIK: bu funksiya `authenticated` ga BERILMAYDI (revoke) —
--    aks holda oddiy user admin tekshiruvini chetlab o'tardi. Uni faqat
--    SECURITY DEFINER funksiyalar va trigger chaqiradi (ular egasi nomidan
--    ishlaydi, shuning uchun grant kerak emas).
-- ⬇⬇⬇  4: SHU QATORDAN pastdagi `comment on function _pul_turi_child_ich` GACHA  ⬇⬇⬇
create or replace function _pul_turi_child_ich(p_parent uuid, p_turi text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_parent accounts%rowtype;
  v_turi   text := lower(btrim(coalesce(p_turi, '')));
  v_lbl    text;
  v_prefix text;
  v_uzun   int;
  v_next   int;
  v_code   text;
  v_id     uuid;
begin
  -- Turlar va yorliqlari — hodim-dev.html TURI_LBL bilan AYNAN bir xil
  v_lbl := case v_turi
             when 'naqd'     then 'Naqd'
             when 'click'    then 'Click'
             when 'payme'    then 'Payme'
             when 'karta'    then 'Karta'
             when 'terminal' then 'Terminal'
             when 'plastik'  then 'Plastik'
           end;
  if v_lbl is null then
    raise exception 'Pul turi noto''g''ri: % (naqd|click|payme|karta|terminal|plastik)', p_turi;
  end if;

  select * into v_parent from accounts where id = p_parent;
  if not found then
    raise exception 'Kassa topilmadi: %', p_parent;
  end if;
  if v_parent.section is distinct from 'pul' or coalesce(v_parent.currency,'UZS') <> 'UZS' then
    raise exception 'Tur hisobi faqat so''m kassasiga qo''shiladi (%)', v_parent.code;
  end if;
  if not v_parent.is_active then
    raise exception 'Kassa faol emas: %', v_parent.code;
  end if;
  -- Konteyner guruh (5400) — unga to'g'ridan pul yozilmaydi
  if v_parent.kassa_turi = 'xarajat_guruh' then
    raise exception 'Guruh hisobiga tur qo''shib bo''lmaydi (%)', v_parent.code;
  end if;
  -- Bola-hisobning o'zi ota bo'lolmaydi (ikki qavat bo'lmasin).
  --
  -- 🔴 SHART O'ZGARDI — eski: `if v_parent.parent_id is not null then raise`.
  --    Eski shart HODIM KASSASINI ham rad etardi: uning parenti 5400
  --    KONTEYNER guruh, ya'ni parent_id NULL emas. Natijada
  --    `create_pul_turi_child(<hodim kassasi>, 'naqd')` HAR DOIM
  --    "Bola-hisobga tur qo'shib bo'lmaydi" xatosini berardi — aynan shu
  --    sabab hodim kassalarida turlar qo'lda ham ochilmagan.
  --    Yangi shart `pul_turi is not null` + yuqoridagi `currency='UZS'`
  --    tekshiruvi birgalikda AYNI himoyani beradi (kassa_root() bilan bir
  --    xil mantiq: bola-hisob = valyuta bolasi YOKI tur bolasi), lekin
  --    hodim kassasini to'smaydi. Bu FAQAT BO'SHATISH — avval ruxsat
  --    etilgan hech bir holat yopilmadi.
  if v_parent.pul_turi is not null then
    raise exception 'Tur bola-hisobiga tur qo''shib bo''lmaydi (%)', v_parent.code;
  end if;

  -- idempotent: shu turdagi faol bola bor bo'lsa — o'shani qaytaramiz
  select id into v_id
    from accounts
   where parent_id = p_parent and pul_turi = v_turi and is_active = true
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  -- QAYTA YOQISH: `pul_turi_ochir` (8.5-bo'lim) bilan yopilgan (is_active=false)
  -- shu turdagi bola bo'lsa — YANGI kod ochmaymiz, eskisini tiklaymiz.
  -- Aks holda "o'chirdim → qayta qo'shdim" har safar yangi kod yeb, bir xil
  -- nomli ikki hisob qoldirardi (`accounts_parent_turi_uniq` faqat is_active
  -- qatorlarga qo'yilgan — ya'ni baza buni to'smaydi).
  -- Nom/subtitle parentdan qayta olinadi: kassa nomi o'zgargan bo'lishi mumkin.
  -- Bu UPDATE trg_hodim_kassa_turlar ni ishga tushirmaydi (u AFTER INSERT).
  select id into v_id
    from accounts
   where parent_id = p_parent and pul_turi = v_turi
     and coalesce(is_active, true) = false
   order by code
   limit 1;
  if v_id is not null then
    update accounts
       set is_active = true,
           name      = v_parent.name || ' · ' || v_lbl,
           subtitle  = v_parent.subtitle
     where id = v_id;
    return v_id;
  end if;

  -- Kod: bo'sh joyi bor birinchi blok (nav tartibida). Blokdagi eng katta
  -- kod + 1; faol bo'lmagan eski hisoblar ham hisobga olinadi (kod unique).
  -- `substring(code from 3)` — regexp uzunlikni kafolatlagani uchun ::int xavfsiz.
  -- 5 urinish: bir vaqtda ikki sessiya kassa ochsa kod poygasi bo'lishi mumkin.
  for i in 1..5 loop
    select b.prefix, b.raqam_uzunlik, coalesce(mx.n, 0) + 1
      into v_prefix, v_uzun, v_next
      from pul_turi_kod_blok b
      left join lateral (
        select max(substring(a.code from 3)::int) as n
          from accounts a
         where a.code ~ ('^' || b.prefix || '[0-9]{' || b.raqam_uzunlik::text || '}$')
      ) mx on true
     where coalesce(mx.n, 0) + 1 <= (power(10, b.raqam_uzunlik)::int - 1)
     order by b.nav
     limit 1;

    if v_prefix is null then
      -- ⚠️ raqam_uzunlik faqat 2..3 (pul_turi_kod_blok_uzunlik_chk, 3.1-bo'lim) —
      --    tavsiya yangi PREFIKS qo'shish, uzunlikni oshirish emas.
      raise exception 'Tur kod bloklari to''ldi. pul_turi_kod_blok''ga yangi blok qo''shing (masalan prefix=51, raqam_uzunlik=3 — bo''sh nav raqami bilan).';
    end if;
    v_code := v_prefix || lpad(v_next::text, v_uzun, '0');

    begin
      insert into accounts(code, name, type, section, currency, parent_id,
                           kassa_turi, is_active, subtitle, pul_turi)
      values (v_code,
              v_parent.name || ' · ' || v_lbl,
              'aktiv', 'pul', 'UZS', p_parent,
              v_parent.kassa_turi, true, v_parent.subtitle, v_turi)
      returning id into v_id;
      return v_id;
    exception when unique_violation then
      -- Ikki xil poyga bo'lishi mumkin: (a) kod band, (b) shu tur allaqachon
      -- ochilib bo'lgan (accounts_parent_turi_uniq). (b) bo'lsa — qaytaramiz.
      select id into v_id
        from accounts
       where parent_id = p_parent and pul_turi = v_turi and is_active = true
       limit 1;
      if v_id is not null then
        return v_id;
      end if;
      -- (a): keyingi urinishda max qayta hisoblanadi
    end;
  end loop;

  raise exception 'Tur hisobiga bo''sh kod topilmadi (5 urinish): % / %', v_parent.code, v_turi;
end $$;

revoke all on function _pul_turi_child_ich(uuid, text) from public, anon, authenticated;

comment on function _pul_turi_child_ich(uuid, text) is
  'ICHKI: kassaga pul turi bola-hisobini ochadi. RUXSAT TEKSHIRMAYDI — '
  'faqat create_pul_turi_child va accounts triggeri chaqiradi. authenticated ga berilmagan.';
-- ⬆⬆⬆  4 shu yerda tugadi  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 5. create_pul_turi_child — IMZO O'ZGARMAYDI, xulq eskisidek
-- ---------------------------------------------------------------------
-- Tana ichkiga ko'chdi; bu yerda faqat ADMIN tekshiruvi qoldi.
-- Eski xulq to'liq saqlanadi: admin-only, idempotent, SECURITY DEFINER.
-- Yangilik: turlar ro'yxatiga karta/terminal/plastik qo'shildi.
-- ⬇⬇⬇  5: SHU QATORDAN pastdagi `comment on function create_pul_turi_child` GACHA  ⬇⬇⬇
create or replace function create_pul_turi_child(p_parent uuid, p_turi text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  select role into v_role from profiles where id = auth.uid();
  if v_role is distinct from 'admin' then
    raise exception 'Faqat admin tur hisobi ocha oladi';
  end if;

  return _pul_turi_child_ich(p_parent, p_turi);
end $$;

revoke all on function create_pul_turi_child(uuid, text) from public, anon;
grant execute on function create_pul_turi_child(uuid, text) to authenticated;

comment on function create_pul_turi_child(uuid, text) is
  'Kassaga pul turi (naqd|click|payme|karta|terminal|plastik) bola-hisobini ochadi. Admin, idempotent.';
-- ⬆⬆⬆  5 shu yerda tugadi  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 6. pul_turi_standart() — "yangi kassaga qaysi turlar ochiladi"
-- ---------------------------------------------------------------------
-- Bitta manba: RPC ham, trigger ham, backfill ham shundan o'qiydi —
-- ro'yxat vaqt o'tib uch joyda uch xil bo'lib ketmasin.
-- Aros balanslari: cash / click / payme / dollar. `karta` — Asilbek talabi
-- (naqd emas, lekin dollar ham emas — plastik karta bilan to'lov).
-- USD (dollar) ATAYLAB YO'Q: u valyuta bolasi, `create_valyuta_child` ishi
-- va konvert mantiqiga tegadi (56xx blok, fc_amount, koridor).
-- ⬇⬇⬇  6: SHU QATORDAN pastdagi `comment on function pul_turi_standart` GACHA  ⬇⬇⬇
create or replace function pul_turi_standart()
returns text[]
language sql
immutable
as $$
  select array['naqd','click','payme','karta']::text[];
$$;

revoke all on function pul_turi_standart() from public, anon;
grant execute on function pul_turi_standart() to authenticated, service_role;

comment on function pul_turi_standart() is
  'Yangi kassaga avtomatik ochiladigan pul turlari. USD kirmaydi (u valyuta bolasi).';
-- ⬆⬆⬆  6 shu yerda tugadi  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 7. hodim_kassa_turlar_toldir — bitta HODIM kassasiga standart turlarni ochadi
-- ---------------------------------------------------------------------
-- ⚠️ FAQAT hodim kassasi (otasi 5400 konteyner guruh). Filial/markaziy kassa
--    berilsa xato qaytaradi — nomidagi "hodim" endi haqiqatan majburlanadi.
-- Qaytishi: {"kassa":"5405","nom":"...","yaratildi":["karta"],"bor":["naqd","click","payme"]}
-- Idempotent: bori qayta ochilmaydi, `bor` ro'yxatiga tushadi.
--
-- ⚠️ ADMIN TEKSHIRUVI: auth.uid() NULL bo'lsa (Supabase SQL Editor / n8n
--    service_role) o'tkaziladi — bu loyihadagi mavjud naqsh
--    (entry_line guard triggeri ham aynan shunday: service_role o'tadi).
--    PostgREST orqali auth.uid() faqat service_role kalitida NULL bo'ladi;
--    `anon` ga EXECUTE berilmagan.
-- ⬇⬇⬇  7: SHU QATORDAN pastdagi `comment on function hodim_kassa_turlar_toldir` GACHA  ⬇⬇⬇
create or replace function hodim_kassa_turlar_toldir(p_kassa uuid,
                                                     p_usd boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role       text;
  v_acc        accounts%rowtype;
  v_guruh      boolean;
  t            text;
  v_id         uuid;
  v_usd_id     uuid;
  v_yaratildi  text[] := '{}';
  v_bor        text[] := '{}';
begin
  if auth.uid() is not null then
    select role into v_role from profiles where id = auth.uid();
    if v_role is distinct from 'admin' then
      raise exception 'Faqat admin tur hisobi ocha oladi';
    end if;
  end if;

  select * into v_acc from accounts where id = p_kassa;
  if not found then
    raise exception 'Kassa topilmadi: %', p_kassa;
  end if;

  -- ⭐ FAQAT HODIM KASSASI. Funksiya nomi "hodim_..." deb tursa ham, avval
  --    u istalgan kassani qabul qilardi: admin uni filial kassasiga (52xx)
  --    yoki markaziy kassaga ham chaqira olardi va u yerda 4 ta tur ochib
  --    yuborardi. Filial/markaziy kassalarning turlari ALOHIDA qaror —
  --    ular Aros sinxroni (v_filial_turi_hisob, auto-sync) bilan bog'liq.
  --    Shart trigger (8-bo'lim) bilan AYNAN bir xil: ota kassa_turi='xarajat_guruh'.
  select (g.kassa_turi = 'xarajat_guruh')
    into v_guruh
    from accounts g
   where g.id = v_acc.parent_id;

  if not coalesce(v_guruh, false) then
    raise exception
      'Bu HODIM kassasi emas: % (%). Otasi kassa_turi=''xarajat_guruh'' (5400 "Hodim xarajat kassalari") bo''lishi shart. Boshqa kassaga tur ochish uchun create_pul_turi_child(kassa, tur) dan foydalaning.',
      v_acc.code, v_acc.name;
  end if;

  -- Qolgan tekshiruvlar (section='pul', UZS, faol, guruh emas, bola emas)
  -- _pul_turi_child_ich ichida — bitta joyda, aynan bir xil xabar bilan.

  foreach t in array pul_turi_standart() loop
    select id into v_id
      from accounts
     where parent_id = p_kassa and pul_turi = t and is_active = true
     limit 1;
    if v_id is not null then
      v_bor := v_bor || t;
    else
      perform _pul_turi_child_ich(p_kassa, t);
      v_yaratildi := v_yaratildi || t;
    end if;
  end loop;

  -- USD — faqat ochiq talab bilan. create_valyuta_child o'z admin
  -- tekshiruvini o'zi qiladi (bu yerda chetlab o'tilmaydi).
  if p_usd and to_regprocedure('public.create_valyuta_child(uuid,text)') is not null then
    execute 'select create_valyuta_child($1, $2)' into v_usd_id using p_kassa, 'USD';
  end if;

  return jsonb_build_object(
    'kassa',          v_acc.code,
    'nom',            v_acc.name,
    'yaratildi',      to_jsonb(v_yaratildi),
    'bor',            to_jsonb(v_bor),
    'usd_account_id', v_usd_id
  );
end $$;

revoke all on function hodim_kassa_turlar_toldir(uuid, boolean) from public, anon;
grant execute on function hodim_kassa_turlar_toldir(uuid, boolean) to authenticated, service_role;

comment on function hodim_kassa_turlar_toldir(uuid, boolean) is
  'HODIM kassasiga (otasi kassa_turi=''xarajat_guruh'', ya''ni 5400) standart pul '
  'turlarini (pul_turi_standart) ochadi. Boshqa kassani RAD ETADI. Idempotent, admin. '
  'p_usd=true bo''lsa create_valyuta_child(...,''USD'') ham chaqiriladi.';
-- ⬆⬆⬆  7 shu yerda tugadi  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 8. TRIGGER — yangi hodim kassasiga turlar O'ZI ochilsin
-- ---------------------------------------------------------------------
-- TaskFix `upsert_hodim_kassa()` ni chaqiradi, uning tanasi repoda yo'q va
-- unga TEGILMAYDI (service_role only). Yagona ishonchli ilgak — `accounts`
-- ustidagi trigger: kassa qayerdan yaratilsa ham (TaskFix, sozlama, SQL)
-- turlar avtomat ochiladi.
--
-- GUARDLAR (uchtasi ham kerak):
--   1) pg_trigger_depth() > 1  → o'zimiz ochgan bolalar uchun qayta ishlamaydi
--      (rekursiya himoyasi, shart-mustaqil).
--   2) WHEN sharti — bola-hisoblar (`pul_turi is not null`) va valyuta
--      bolalari (`currency <> 'UZS'`) shartga TUSHMAYDI.
--   3) Parent AYNAN 5400 konteyner (`kassa_turi='xarajat_guruh'`) bo'lsin —
--      ya'ni faqat HODIM kassasi. Filial/markaziy kassalar tegilmaydi
--      (ularning turlari boshqa qaror — Aros sinxroni bilan bog'liq).
--
-- ⚠️ XATO YUTILADI (raise warning): tur ochilmasa ham HODIM KASSASI
--    yaratilishi buzilmasligi kerak — aks holda TaskFix tomon sinadi.
--    Ogohlantirish Postgres logida qoladi, kassa esa ochiladi; turlarni
--    keyin `hodim_kassa_turlar_toldir` bilan qo'lda to'ldirsa bo'ladi.
-- ⬇⬇⬇  8: SHU QATORDAN pastdagi `execute function trg_hodim_kassa_turlar_fn();` GACHA  ⬇⬇⬇
create or replace function trg_hodim_kassa_turlar_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_guruh boolean;
  t       text;
begin
  -- 1) Rekursiya guardi: bu trigger o'zi ochgan hisoblar uchun qayta ishlamasin
  if pg_trigger_depth() > 1 then
    return null;
  end if;

  begin
    -- 3) Parent 5400 konteynermi (WHEN sharti subquery qila olmaydi)
    select (g.kassa_turi = 'xarajat_guruh')
      into v_guruh
      from accounts g
     where g.id = new.parent_id;
    if not coalesce(v_guruh, false) then
      return null;
    end if;

    foreach t in array pul_turi_standart() loop
      perform _pul_turi_child_ich(new.id, t);
    end loop;

  exception when others then
    -- Kassa yaratilishini BUZMAYMIZ — faqat ogohlantiramiz
    raise warning 'Hodim kassasiga turlar ochilmadi (% %): %',
      new.code, new.name, sqlerrm;
  end;

  return null;
end $$;

revoke all on function trg_hodim_kassa_turlar_fn() from public, anon, authenticated;

comment on function trg_hodim_kassa_turlar_fn() is
  'accounts AFTER INSERT: yangi hodim kassasiga (parent=5400 konteyner) standart '
  'pul turlarini ochadi. Xato bo''lsa warning — kassa yaratilishi to''xtamaydi.';

drop trigger if exists trg_hodim_kassa_turlar on accounts;
create trigger trg_hodim_kassa_turlar
after insert on accounts
for each row
when (new.section = 'pul'
      and new.kassa_turi = 'xarajat'
      and new.pul_turi is null
      and new.parent_id is not null
      and coalesce(new.currency, 'UZS') = 'UZS'
      and coalesce(new.is_active, true) = true)
execute function trg_hodim_kassa_turlar_fn();
-- ⬆⬆⬆  8 shu yerda tugadi  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 8.5 pul_turi_ochir(p_id) -> jsonb — tur bola-hisobini YOPISH
-- ---------------------------------------------------------------------
-- Turlarni ochish oson bo'lgach, xato ochilganini YOPISH ham kerak bo'ldi
-- (kassa-dev.html "+" modalidagi 🗑 tugmasi shu funksiyani chaqiradi).
--
-- 🔴 HECH NARSA O'CHIRILMAYDI (CLAUDE.md). `delete from accounts` YO'Q —
--    faqat `is_active = false`. Hisob jurnalda, entry_history'da, balansda
--    o'z joyida qoladi; faqat ro'yxatlardan chiqadi.
--
-- QOIDALAR:
--   1) FAQAT tur bola-hisobi (`pul_turi is not null`). Oddiy kassa, guruh
--      (5400), valyuta bolasi — RAD ETILADI. Kassani yopish boshqa ish
--      (`xarajat_filial_ochir`), bu yerda chalkashmasin.
--   2) Qoldiq 0 BO'LMASA rad etiladi. Qoldiq `v_hisob_bal` dan — sahifa,
--      view va bu funksiya bitta manbadan o'qiydi (yangi hisoblash YO'Q).
--      `uzs` ham, `fc` ham tekshiriladi: tur bolasi UZS bo'lsa ham
--      fc_amount bilan yozuv tushib qolgan holat jimgina yutilmasin.
--   3) Yozuvi bor (entry_line da uchraydi — o'chirilgan yozuvlar ham) →
--      holat 'passiv': tarixi saqlanadi, faqat ro'yxatlardan olinadi.
--   4) Qoldiq 0 va yozuvi yo'q → holat 'ochirildi' (amalda ham is_active=false).
--      Ikkalasining ham bazadagi ta'siri BIR XIL — farq faqat xabarda,
--      foydalanuvchi "tarixi bormi" ni bilib tursin.
--   5) Aros bilan sinxronlanadigan filial kassasining turi RAD ETILADI:
--      `v_filial_turi_hisob` (n8n auto-sync qidiruv jadvali) faqat
--      `is_active` bolalarni ko'radi — yopilsa sinxron o'sha tur uchun
--      hisob topolmay qoladi.
--
-- Qaytishi (exception EMAS — sahifa sinmasin, konvert/tannarx RPC uslubi):
--   {"ok":true,"holat":"ochirildi","id":...,"code":...,"name":...,"pul_turi":...}
--   {"ok":true,"holat":"passiv","satr":N, ...}          -- entry_line satrlari soni
--   {"ok":true,"holat":"allaqachon_passiv", ...}        -- idempotent
--   {"ok":false,"error":"...","qoldiq":N}               -- qoldiq bo'lsa
--
-- ⚠️ v_kassa_card / jami: `v_kassa_turlar` `is_active = true` bilan filtrlaydi,
--    ya'ni yopilgan bola `turi_jami` dan chiqib ketadi. Qoldiq 0 bo'lmasa
--    yopilmagani uchun `jami` ARIFMETIK O'ZGARMAYDI (0 ni ayirish). Kartaning
--    `naqd/click/payme` ustunlari ham 0 ni yo'qotadi — ko'rinish o'zgarmaydi.
--    `v_kassa_toliq`/`v_kassa_tanlov`, `isKassa()` filtrlari ham faol hisoblar
--    bilan ishlaydi — yopilgan tur dropdownlardan chiqadi, bu ayni maqsad.
-- ⬇⬇⬇  8.5: SHU QATORDAN pastdagi `notify pgrst, 'reload schema';` GACHA  ⬇⬇⬇
create or replace function pul_turi_ochir(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_role text;
  v_acc  accounts%rowtype;
  v_par  accounts%rowtype;
  v_uzs  numeric := 0;
  v_fc   numeric := 0;
  v_satr int := 0;
  v_bola int := 0;
begin
  if p_id is null then
    return jsonb_build_object('ok', false, 'error', 'Hisob korsatilmagan');
  end if;

  -- ADMIN. auth.uid() null (SQL Editor / service_role) — o'tkaziladi,
  -- bu loyihadagi mavjud naqsh (7-bo'lim, xarajat_filial_ochir).
  if v_uid is not null then
    select role into v_role from profiles where id = v_uid;
    if v_role is distinct from 'admin' then
      return jsonb_build_object('ok', false, 'error', 'Faqat admin tur hisobini yopa oladi');
    end if;
  end if;

  select * into v_acc from accounts where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Hisob topilmadi');
  end if;

  -- (1) faqat tur bola-hisobi
  if v_acc.pul_turi is null then
    return jsonb_build_object('ok', false,
      'error', 'Bu tur hisobi emas: ' || coalesce(v_acc.code, '?') || ' ' ||
               coalesce(v_acc.name, '') ||
               '. Faqat naqd/click/payme/karta bola-hisobi yopiladi.');
  end if;

  -- idempotent
  if coalesce(v_acc.is_active, true) = false then
    return jsonb_build_object('ok', true, 'holat', 'allaqachon_passiv',
      'id', v_acc.id, 'code', v_acc.code, 'name', v_acc.name, 'pul_turi', v_acc.pul_turi);
  end if;

  -- (5) Aros sinxronidagi filial turi tegilmaydi
  if v_acc.parent_id is not null then
    select * into v_par from accounts where id = v_acc.parent_id;
    if found and v_par.kassa_turi = 'filial' and v_par.filial_ref is not null then
      return jsonb_build_object('ok', false,
        'error', 'Aros bilan sinxronlanadigan filial kassasining turi yopilmaydi: ' ||
                 coalesce(v_par.code, '?') || ' ' || coalesce(v_par.name, '') ||
                 '. Auto-sync shu tur uchun hisob topolmay qoladi.');
    end if;
  end if;

  -- Bola-hisobning o'z bolasi bo'lmasligi kerak (ikki qavat taqiqlangan),
  -- lekin qo'lda ochilgan bo'lsa yetim qolmasin — ochiq aytamiz.
  select count(*) into v_bola
    from accounts
   where parent_id = p_id and coalesce(is_active, true) = true;
  if v_bola > 0 then
    return jsonb_build_object('ok', false,
      'error', 'Bu hisobda ' || v_bola::text || ' ta faol bola-hisob bor — avval ularni yoping.');
  end if;

  -- (2) QOLDIQ — mavjud yordamchidan (v_hisob_bal: posted + o'chirilmagan)
  select coalesce(b.uzs, 0), coalesce(b.fc, 0)
    into v_uzs, v_fc
    from v_hisob_bal b
   where b.account_id = p_id;
  v_uzs := coalesce(v_uzs, 0);
  v_fc  := coalesce(v_fc, 0);

  if v_uzs <> 0 or v_fc <> 0 then
    return jsonb_build_object('ok', false,
      'error', 'Qoldiq nolga teng emas (' || v_uzs::text ||
               ') — avval "Tur otkazish" bilan pulni boshqa turga chiqaring.',
      'qoldiq', v_uzs,
      'fc',     v_fc);
  end if;

  -- (3) yozuvi bormi (o'chirilgan yozuvlar ham sanaladi — tarix baribir bor)
  select count(*) into v_satr from entry_line l where l.account_id = p_id;

  update accounts set is_active = false where id = p_id;

  if v_satr > 0 then
    return jsonb_build_object('ok', true, 'holat', 'passiv', 'satr', v_satr,
      'id', v_acc.id, 'code', v_acc.code, 'name', v_acc.name, 'pul_turi', v_acc.pul_turi);
  end if;

  -- (4) qoldiq 0, yozuv yo'q
  return jsonb_build_object('ok', true, 'holat', 'ochirildi', 'satr', 0,
    'id', v_acc.id, 'code', v_acc.code, 'name', v_acc.name, 'pul_turi', v_acc.pul_turi);

exception when others then
  -- Sahifa sinmasin: har qanday xato ham {ok:false} bo'lib qaytadi.
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end $$;

revoke all on function pul_turi_ochir(uuid) from public, anon;
grant execute on function pul_turi_ochir(uuid) to authenticated;

comment on function pul_turi_ochir(uuid) is
  'Pul turi bola-hisobini YOPADI (is_active=false, HECH QACHON delete emas). Admin, idempotent. '
  'Qoldiq 0 bo''lishi shart; yozuvi bo''lsa holat=passiv, bo''lmasa holat=ochirildi. '
  'Xatoda exception emas, {ok:false,error} qaytaradi.';

notify pgrst, 'reload schema';
-- ⬆⬆⬆  8.5 shu yerda tugadi  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 9. O'ZINI TEKSHIRUV.  HECH NARSA YOZMAYDI.
-- ---------------------------------------------------------------------
-- Avval bitta `do` bloki edi va birinchi muammoda `raise exception` bilan
-- to'xtardi. Endi 5 ta ALOHIDA `select` — har birini alohida belgilab RUN
-- qiling. `holat` ustunida ❌ bo'lsa `izoh` da aynan eski xato matni turadi.

-- 9.1 Funksiyalar va trigger o'rnatildimi
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
select '_pul_turi_child_ich(uuid,text)' as obyekt,
       case when to_regprocedure('public._pul_turi_child_ich(uuid,text)') is not null
            then '✅ OK' else '❌ MUAMMO' end as holat,
       case when to_regprocedure('public._pul_turi_child_ich(uuid,text)') is not null then '—'
            else '_pul_turi_child_ich yaratilmadi' end as izoh
union all
select 'create_pul_turi_child(uuid,text)',
       case when to_regprocedure('public.create_pul_turi_child(uuid,text)') is not null
            then '✅ OK' else '❌ MUAMMO' end,
       case when to_regprocedure('public.create_pul_turi_child(uuid,text)') is not null then '—'
            else 'create_pul_turi_child imzosi yo''qoldi (uuid,text) — ADDITIVE qoidasi buzilgan' end
union all
select 'hodim_kassa_turlar_toldir(uuid,boolean)',
       case when to_regprocedure('public.hodim_kassa_turlar_toldir(uuid,boolean)') is not null
            then '✅ OK' else '❌ MUAMMO' end,
       case when to_regprocedure('public.hodim_kassa_turlar_toldir(uuid,boolean)') is not null then '—'
            else 'hodim_kassa_turlar_toldir yaratilmadi' end
union all
select 'pul_turi_standart()',
       case when to_regprocedure('public.pul_turi_standart()') is not null
            then '✅ OK' else '❌ MUAMMO' end,
       case when to_regprocedure('public.pul_turi_standart()') is not null then '—'
            else 'pul_turi_standart yaratilmadi' end
union all
select 'pul_turi_ochir(uuid)',
       case when to_regprocedure('public.pul_turi_ochir(uuid)') is not null
            then '✅ OK' else '❌ MUAMMO' end,
       case when to_regprocedure('public.pul_turi_ochir(uuid)') is not null then '—'
            else 'pul_turi_ochir yaratilmadi (8.5-bo''lim) — kassa sahifasidagi o''chirish tugmasi ishlamaydi' end
union all
select 'trg_hodim_kassa_turlar (accounts)',
       case when exists (select 1 from pg_trigger
                          where tgrelid = 'public.accounts'::regclass
                            and tgname = 'trg_hodim_kassa_turlar'
                            and not tgisinternal)
            then '✅ OK' else '❌ MUAMMO' end,
       case when exists (select 1 from pg_trigger
                          where tgrelid = 'public.accounts'::regclass
                            and tgname = 'trg_hodim_kassa_turlar'
                            and not tgisinternal) then '—'
            else 'trg_hodim_kassa_turlar triggeri o''rnatilmadi' end;
-- ⬆⬆⬆  9.1 shu yerda tugadi  ⬆⬆⬆

-- 9.2 CHECK kengaydimi
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
with d as (
  select (select pg_get_constraintdef(oid)
            from pg_constraint
           where conname = 'accounts_pul_turi_chk'
             and conrelid = 'public.accounts'::regclass) as def
)
select 'accounts_pul_turi_chk'                as obyekt,
       coalesce(d.def, '(yo''q)')             as tarif,
       case when d.def is not null and d.def like '%karta%'
            then '✅ OK' else '❌ MUAMMO' end  as holat,
       case when d.def is not null and d.def like '%karta%' then '—'
            else 'accounts_pul_turi_chk kengaymadi: ' || coalesce(d.def, '(yo''q)') end as izoh
  from d;
-- ⬆⬆⬆  9.2 shu yerda tugadi  ⬆⬆⬆

-- 9.3 Kod bloklari.
-- ⚠️ JAMI SANOQ YETARLI EMAS: 3.3 dagi `on conflict (nav) do nothing` nav 4/5/6
--    boshqa prefiks bilan allaqachon band bo'lsa qatorni JIMGINA o'tkazib
--    yuboradi — jadvalda baribir 6 ta qator turadi va `count(*) >= 6` yolg'on
--    tasdiq berardi (5 xonali blok aslida qo'shilmagan). Shuning uchun AYNAN
--    5 xonali bloklar (raqam_uzunlik = 3) sanaladi.
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
with b as (
  select count(*)                                  as jami,
         count(*) filter (where raqam_uzunlik = 3) as uzun3
    from pul_turi_kod_blok
)
select 'Kod bloklari'                     as obyekt,
       b.jami                             as bloklar,
       b.uzun3                            as besh_xonali,
       case when b.uzun3 >= 3 then '✅ OK' else '❌ MUAMMO' end as holat,
       case when b.uzun3 >= 3 then '—'
            else '5 xonali blok (raqam_uzunlik=3) atigi ' || b.uzun3::text ||
                 ' ta — 3 ta kerak (jami blok: ' || b.jami::text ||
                 '). Ehtimol nav 4/5/6 boshqa prefiks bilan band va 3.3 dagi insert o''tkazib yuborilgan. Bo''sh nav raqamlari bilan qo''lda qo''shing: insert into pul_turi_kod_blok(nav, prefix, raqam_uzunlik) values (<bo''sh nav>, ''55'', 3), ...'
       end                                as izoh
  from b;
-- ⬆⬆⬆  9.3 shu yerda tugadi  ⬆⬆⬆

-- 9.4 Standart turlar ro'yxati
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
select 'pul_turi_standart()'                       as obyekt,
       array_to_string(pul_turi_standart(), ', ')  as royxat,
       case when 'karta' = any(pul_turi_standart())
            then '✅ OK' else '❌ MUAMMO' end       as holat,
       case when 'karta' = any(pul_turi_standart()) then '—'
            else 'pul_turi_standart ichida karta yo''q' end as izoh;
-- ⬆⬆⬆  9.4 shu yerda tugadi  ⬆⬆⬆

-- 9.5 Bo'sh kod sig'imi (taqribiy: har blokda "eng katta band kod"dan yuqorisi
--     bo'sh deb sanaladi — o'rtadagi bo'shliqlar qayta ishlatilmaydi)
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
select 'Bo''sh kod sig''imi'  as obyekt,
       count(*)              as bloklar,
       sum(greatest((power(10, b.raqam_uzunlik)::int - 1) - coalesce(mx.n, 0), 0)) as bosh_kod,
       '✅ OK — turlar avtomatikasi tayyor' as holat
  from pul_turi_kod_blok b
  left join lateral (
    select max(substring(a.code from 3)::int) as n
      from accounts a
     where a.code ~ ('^' || b.prefix || '[0-9]{' || b.raqam_uzunlik::text || '}$')
  ) mx on true;
-- ⬆⬆⬆  9.5 shu yerda tugadi  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 10. TEKSHIRUV SO'ROVLARI (o'zgartirmaydi)
-- ---------------------------------------------------------------------
-- ⚠️ Supabase SQL Editor FAQAT OXIRGI statement natijasini ko'rsatadi —
--    hammasini birga RUN qilsangiz faqat oxirgisini ko'rasiz.
--    Har birini SICHQONCHA BILAN BELGILAB alohida RUN qiling.

-- 10.1 Bloklar va ularda qolgan joy
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
select b.nav, b.prefix, b.raqam_uzunlik,
       ('^' || b.prefix || '[0-9]{' || b.raqam_uzunlik::text || '}$') as naqsh,
       coalesce(mx.n, 0)                                        as oxirgi_band,
       (power(10, b.raqam_uzunlik)::int - 1) - coalesce(mx.n, 0) as bosh_joy
  from pul_turi_kod_blok b
  left join lateral (
    select max(substring(a.code from 3)::int) as n
      from accounts a
     where a.code ~ ('^' || b.prefix || '[0-9]{' || b.raqam_uzunlik::text || '}$')
  ) mx on true
 order by b.nav;
-- ⬆⬆⬆  10.1 shu yerda tugadi  ⬆⬆⬆

-- 10.2 Hodim kassalari va ularda qaysi turlar bor / yetishmaydi.
--      `section` ustuni ataylab chiqariladi: 'pul' bo'lmasa trigger
--      o'sha kassa uchun ishlamaydi (1.4-tekshiruvga qara).
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
select p.code, p.name, p.subtitle, p.section,
       coalesce(string_agg(c.pul_turi, ', ' order by c.pul_turi), '—') as bor_turlar,
       (select string_agg(s.t, ', ')
          from unnest(pul_turi_standart()) as s(t)
         where not exists (select 1 from accounts x
                            where x.parent_id = p.id and x.is_active and x.pul_turi = s.t)
       ) as yetishmaydi
  from accounts p
  join accounts g on g.id = p.parent_id and g.kassa_turi = 'xarajat_guruh'
  left join accounts c on c.parent_id = p.id and c.is_active and c.pul_turi is not null
 where p.is_active and p.kassa_turi = 'xarajat'
   and p.pul_turi is null and coalesce(p.currency,'UZS') = 'UZS'
 group by p.id, p.code, p.name, p.subtitle, p.section
 order by p.code;
-- ⬆⬆⬆  10.2 shu yerda tugadi  ⬆⬆⬆

-- 10.3 Triggerni SINAB ko'rish (ixtiyoriy — test kassa ochadi va o'chiradi).
--      ⚠️ accounts dan DELETE qiladi — faqat yozuvsiz test kassasi uchun.
--      Avval `do` bloki edi; endi 4 ta oddiy statement, ATAYLAB izohda.
--      Ishlatish: qator boshidagi `-- ` larni olib tashlang va statementlarni
--      BIRMA-BIR RUN qiling (2-statement `4` qaytarishi kerak), oxirgi ikkitasi
--      test kassani tozalaydi.
-- ⬇⬇⬇  10.3 SINOV — izohni olib tashlagach shu oraliqni belgilang  ⬇⬇⬇
-- insert into accounts(code, name, type, section, currency, parent_id, kassa_turi, is_active, subtitle)
-- select '5499', 'ZZZ Test Hodim', 'aktiv', 'pul', 'UZS', g.id, 'xarajat', true, 'Test'
--   from accounts g where g.kassa_turi = 'xarajat_guruh' and g.is_active limit 1;
--
-- select count(*) as trigger_ochgan_turlar   -- 4 bo'lishi kerak
--   from accounts c join accounts k on k.id = c.parent_id
--  where k.code = '5499' and c.pul_turi is not null;
--
-- delete from accounts where parent_id = (select id from accounts where code = '5499');
-- delete from accounts where code = '5499';
-- ⬆⬆⬆  10.3 SINOV shu yerda tugadi  ⬆⬆⬆

-- 10.4 Qaysi tur hisobini YOPSA bo'ladi (pul_turi_ochir uchun oldindan ko'rish).
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
select c.code, c.name, c.pul_turi,
       coalesce(b.uzs, 0)                                           as qoldiq,
       (select count(*) from entry_line l where l.account_id = c.id) as satr,
       case when coalesce(b.uzs, 0) <> 0 or coalesce(b.fc, 0) <> 0
              then 'yoq — qoldiq bor'
            when p.kassa_turi = 'filial' and p.filial_ref is not null
              then 'yoq — Aros sinxroni'
            when exists (select 1 from entry_line l where l.account_id = c.id)
              then 'ha (passiv, tarixi saqlanadi)'
            else 'ha' end                                           as yopish_mumkin
  from accounts c
  left join accounts p    on p.id = c.parent_id
  left join v_hisob_bal b on b.account_id = c.id
 where c.pul_turi is not null and c.is_active
 order by c.code;
-- ⬆⬆⬆  10.4 shu yerda tugadi  ⬆⬆⬆


-- =====================================================================
-- 11. BACKFILL — MAVJUD hodim kassalariga turlarni to'ldirish
--     ⚠️ ixtiyoriy, ALOHIDA RUN. Yuqoridagi qism bilan birga ishlamaydi.
-- =====================================================================

-- 11.1 ⭐ AVVAL PREVIEW — nechta kassa, nechta yangi hisob ochiladi.
--      Bu so'rov hech narsani o'zgartirmaydi.
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
with k as (
  select p.id, p.code,
         (select count(*)
            from unnest(pul_turi_standart()) as s(t)
           where not exists (select 1 from accounts x
                              where x.parent_id = p.id and x.is_active and x.pul_turi = s.t)
         ) as yetishmaydi
    from accounts p
    join accounts g on g.id = p.parent_id and g.kassa_turi = 'xarajat_guruh'
   where p.is_active and p.section = 'pul' and p.kassa_turi = 'xarajat'
     and p.pul_turi is null and coalesce(p.currency,'UZS') = 'UZS'
),
bosh as (
  select sum(greatest((power(10, b.raqam_uzunlik)::int - 1) - coalesce(mx.n, 0), 0)) as joy
    from pul_turi_kod_blok b
    left join lateral (
      select max(substring(a.code from 3)::int) as n
        from accounts a
       where a.code ~ ('^' || b.prefix || '[0-9]{' || b.raqam_uzunlik::text || '}$')
    ) mx on true
)
select count(*)                                   as hodim_kassa_soni,
       count(*) filter (where yetishmaydi > 0)    as toldiriladigan_kassa,
       coalesce(sum(yetishmaydi), 0)              as ochiladigan_hisob,
       (select joy from bosh)                     as bosh_kod_joyi,
       case when coalesce(sum(yetishmaydi), 0) <= (select joy from bosh)
            then 'YETADI' else 'KOD YETMAYDI — pul_turi_kod_blok ga yangi blok qo''shing' end as holat
  from k;
-- ⬆⬆⬆  11.1 shu yerda tugadi  ⬆⬆⬆

-- 11.2 BAJARISH — 11.1 natijasi to'g'ri bo'lsa.
--      hodim_kassa_turlar_toldir har kassaga idempotent ishlaydi:
--      bori qayta ochilmaydi. Bitta kassada xato bo'lsa — o'sha kassa
--      o'tkazib yuboriladi (warning), qolganlari davom etadi.
--
--      🔴 FUNKSIYA YARATILADI, LEKIN CHAQIRILMAYDI. Butun fayl RUN
--         qilinganda 240 ta hisob o'z-o'zidan ochilib ketmasligi uchun
--         chaqiruv ATAYLAB izohda turibdi (pastdagi oxirgi qator).
--         Ishlatish: o'sha bitta qatorning `-- ` sini olib tashlang va
--         FAQAT o'sha qatorni belgilab RUN qiling.
-- ⬇⬇⬇  11.2: funksiya (xavfsiz, hech narsa qilmaydi)  ⬇⬇⬇
create or replace function hodim_turlar_backfill()
returns jsonb
language plpgsql
as $$
declare
  r        record;
  v_res    jsonb;
  n_kassa  int := 0;
  n_yangi  int := 0;
  n_xato   int := 0;
begin
  for r in
    select p.id, p.code, p.name
      from accounts p
      join accounts g on g.id = p.parent_id and g.kassa_turi = 'xarajat_guruh'
     where p.is_active and p.section = 'pul' and p.kassa_turi = 'xarajat'
       and p.pul_turi is null and coalesce(p.currency,'UZS') = 'UZS'
     order by p.code
  loop
    begin
      v_res   := hodim_kassa_turlar_toldir(r.id);   -- p_usd = false
      n_kassa := n_kassa + 1;
      n_yangi := n_yangi + coalesce(jsonb_array_length(v_res -> 'yaratildi'), 0);
    exception when others then
      n_xato := n_xato + 1;
      raise warning 'Kassa % (%) to''ldirilmadi: %', r.code, r.name, sqlerrm;
    end;
  end loop;

  raise notice 'BACKFILL: % ta kassa ko''rildi, % ta yangi tur hisobi ochildi, % ta xato',
    n_kassa, n_yangi, n_xato;

  return jsonb_build_object('kassa', n_kassa, 'yangi_hisob', n_yangi, 'xato', n_xato);
end $$;

revoke all on function hodim_turlar_backfill() from public, anon, authenticated;

comment on function hodim_turlar_backfill() is
  'BACKFILL: mavjud hodim kassalarining hammasiga standart turlarni to''ldiradi. '
  'Idempotent; bitta kassadagi xato qolganlarini to''xtatmaydi (warning). '
  'ATAYLAB avtomatik chaqirilmaydi — PROVODKA_TURLAR_AVTO.sql 11.2 ga qara.';
-- ⬆⬆⬆  11.2 funksiya shu yerda tugadi  ⬆⬆⬆

-- 🔴 BACKFILLNI HAQIQATAN BAJARISH — faqat shu qatorning izohini oling:
-- select jsonb_pretty(hodim_turlar_backfill()) as backfill_natija;

-- 11.3 Backfilldan keyin: 10.2 ni qayta RUN qiling — `yetishmaydi` ustuni
--      hamma qatorda bo'sh bo'lishi kerak.


-- =====================================================================
-- 12. ORQAGA QAYTARISH (kerak bo'lsa)
-- =====================================================================
-- 12.1 Avtomatikani o'chirish (yaratilgan hisoblar joyida qoladi):
--   drop trigger if exists trg_hodim_kassa_turlar on accounts;
--
-- 12.2 Backfill ochgan, HALI ISHLATILMAGAN tur hisoblarini yopish
--      (o'chirmaymiz — CLAUDE.md: hech narsa o'chirilmaydi, faqat is_active=false).
--      ⚠️ RO'YXATNI KO'RING va faqat KERAKLI id'larni yoping. Hamma
--         `pul_turi is not null` hisobini ko'r-ko'rona yopib bo'lmaydi —
--         orasida ESKI, ishlatilayotgan turlar (5351 "· Naqd"…) ham bor.
--   select c.id, c.code, c.name, c.pul_turi,
--          (select count(*) from entry_line l where l.account_id = c.id) as yozuvlar
--     from accounts c
--    where c.pul_turi is not null and c.is_active
--    order by c.code;
--
--   -- Faqat yozuvsizlarini va faqat tanlangan id'larni:
--   update accounts set is_active = false
--    where id in ('<id1>', '<id2>')
--      and not exists (select 1 from entry_line l where l.account_id = accounts.id);
--
-- 12.2b `pul_turi_ochir` bilan yopilgan hisobni QAYTA ochish (undo).
--       Eng oson yo'l — kassa sahifasidagi "+" modalidan o'sha turni qayta
--       qo'shish: `create_pul_turi_child` yopilgan bolani TIKLAYDI (yangi kod
--       ochmaydi, 4-bo'limdagi "QAYTA YOQISH" blokiga qara).
--       Qo'lda: update accounts set is_active = true where id = '<id>';
--
-- 12.3 5 xonali bloklarni olib tashlash (yangi kod berilmasin):
--   delete from pul_turi_kod_blok where raqam_uzunlik = 3;
--   -- ⚠️ Allaqachon berilgan 5 xonali kodlar o'z joyida qoladi (ular unique va
--   --    hech qaysi so'rovni buzmaydi) — faqat YANGI kod 4 xonali bo'ladi.
