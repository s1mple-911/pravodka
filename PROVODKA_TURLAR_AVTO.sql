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
--    5. BACKFILL — mavjud hodim kassalari uchun (izohda, ALOHIDA RUN)
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
--      TEKSHIRADI va noto'g'ri bo'lsa faylni to'xtatadi.
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
--  Bir necha marta RUN qilish xavfsiz (idempotent).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. PREFLIGHT — bog'liqliklar joyidami
-- ---------------------------------------------------------------------

-- 1.1 PROVODKA_VALYUTA.sql RUN qilinganmi
do $$
begin
  if to_regclass('public.pul_turi_kod_blok') is null then
    raise exception 'pul_turi_kod_blok jadvali yo''q — avval PROVODKA_VALYUTA.sql ni RUN qiling';
  end if;
  if to_regprocedure('public.create_pul_turi_child(uuid,text)') is null then
    raise exception 'create_pul_turi_child yo''q — avval PROVODKA_VALYUTA.sql ni RUN qiling';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'accounts'
                    and column_name = 'pul_turi') then
    raise exception 'accounts.pul_turi ustuni yo''q — avval PROVODKA_VALYUTA.sql';
  end if;
end $$;

-- 1.2 accounts.code ga 5 xonali kod sig'adimi.
--     Kod `text` bo'lsa cheklov yo'q (character_maximum_length = NULL).
--     varchar(4) bo'lsa 5 xonali blok ishlamaydi — JIMGINA o'tkazib yubormaymiz.
--     ⚠️ 5 raqami `pul_turi_kod_blok_uzunlik_chk` (3.1) bilan MOS: prefiks 2 belgi
--        + raqam_uzunlik ko'pi bilan 3 = eng uzun kod 5 belgi. Cheklovni
--        `raqam_uzunlik = 4` gacha kengaytirsangiz, bu yerdagi 5 ni ham 6 qiling.
do $$
declare v_len int;
begin
  select character_maximum_length into v_len
    from information_schema.columns
   where table_schema = 'public' and table_name = 'accounts' and column_name = 'code';
  if v_len is not null and v_len < 5 then
    raise exception
      'accounts.code uzunligi % — 5 xonali kod sig''maydi. Avval: alter table accounts alter column code type text;',
      v_len;
  end if;
end $$;

-- 1.3 ⭐ RUXSAT TEKSHIRUVI — perm_op_key tur bolasini parentga bog'laydimi.
--     Bog'lamasa, bu fayl ochadigan yuzlab yangi tur hisobi cheklangan
--     foydalanuvchilar uchun ishlamaydi (42501). Shuning uchun TO'XTATAMIZ.
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
do $preflight13$
declare
  n      int;
  n_bor  int;
  v_def  text;
  v_root text;
  v_ok   boolean := false;
begin
  if to_regprocedure('public.perm_op_key(uuid)') is null then
    raise notice 'perm_op_key yo''q — ruxsat tizimi o''rnatilmagan, tekshiruv o''tkazib yuborildi';
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
      raise exception
        'perm_op_key kassa_root() ni chaqiryapti, lekin kassa_root(uuid) yo''q — avval PROVODKA_VALYUTA.sql ni RUN qiling';
    end if;
    v_root := pg_get_functiondef(to_regprocedure('public.kassa_root(uuid)')::oid);
    v_ok   := v_root ilike '%pul_turi%';
  end if;

  if not v_ok then
    raise exception
      'perm_op_key() ta''rifida `pul_turi` sharti YO''Q — tur bola-hisoblari cheklangan (kassa_scope=''list'') foydalanuvchilar uchun ruxsatdan chetda qoladi va entry_line guard triggeri 42501 beradi. AVVAL PROVODKA_PERM_TUR_FIX.sql ni RUN qiling (yoki PROVODKA_VALYUTA.sql 7-bo''limini).';
  end if;

  -- (b) MAVJUD MA'LUMOT bo'yicha (eski tekshiruv — saqlanadi).
  --     Bitta ham tur hisobi bo'lmasligi normal (bu fayl aynan ularni ochadi),
  --     shuning uchun bu qatlam yolg'iz o'zi yetarli emas — (a) bilan birga ishlaydi.
  select count(*),
         count(*) filter (where perm_op_key(c.id) is distinct from c.parent_id)
    into n_bor, n
    from accounts c
   where c.is_active
     and c.pul_turi is not null
     and c.parent_id is not null;

  if n > 0 then
    raise exception
      'perm_op_key tur bola-hisobini parent kassaga bog''lamayapti (% ta hisob) — avval PROVODKA_PERM_TUR_FIX.sql ni RUN qiling',
      n;
  end if;

  raise notice 'perm_op_key OK: ta''rifda pul_turi sharti bor + mavjud % ta tur hisobi tekshirildi', n_bor;
end $preflight13$;

-- 1.4 Trigger sharti mavjud hodim kassalariga mos keladimi.
--     Trigger WHEN sharti `section='pul'` ga tayanadi. TaskFix
--     (`upsert_hodim_kassa`, tanasi repoda yo'q) kassani section'siz ochsa,
--     trigger JIMGINA ishlamay qolardi — shuning uchun ochiq tekshiramiz.
do $$
declare n_bor int; n_sectionsiz int;
begin
  select count(*),
         count(*) filter (where p.section is distinct from 'pul')
    into n_bor, n_sectionsiz
    from accounts p
    join accounts g on g.id = p.parent_id and g.kassa_turi = 'xarajat_guruh'
   where p.is_active and p.kassa_turi = 'xarajat' and p.pul_turi is null;

  if n_bor = 0 then
    raise notice 'Hodim kassasi topilmadi (5400 konteyner bo''sh) — trigger baribir o''rnatiladi';
  elsif n_sectionsiz > 0 then
    raise warning 'DIQQAT: % / % ta hodim kassasida section <> ''pul'' — trigger ular uchun ishlamaydi (10.2 so''rovi bilan ko''ring)', n_sectionsiz, n_bor;
  else
    raise notice 'Hodim kassalari: % ta, hammasi section=''pul'' — trigger sharti mos', n_bor;
  end if;
end $$;

-- 1.5 👀 PREVIEW — bazada HOZIR qanday pul turlari bor.
--     2-bo'lim `accounts_pul_turi_chk` ni drop+add qiladi; ro'yxatdan tashqari
--     qiymat bo'lsa yangi cheklov o'rnatilmaydi (add constraint xato beradi va
--     jadval CHEKLOVSIZ qolib ketadi). Shuning uchun avval KO'RAMIZ, keyin
--     2-bo'lim boshida qat'iy TEKSHIRAMIZ.
--
--     Taqsimot `raise notice` bilan chiqadi (Supabase → "Messages" paneli),
--     chunki oraga `select` qo'yilsa u faylning oxirgi natijasini bosib qolardi.
--     Batafsil jadval ko'rinishida kerak bo'lsa — quyidagi so'rovni ALOHIDA RUN qiling:
--
--       select pul_turi, count(*) as nechta
--         from accounts
--        where pul_turi is not null
--        group by pul_turi
--        order by pul_turi;
do $preflight15$
declare
  v_taqsimot text;
  v_notanish text;
begin
  select string_agg(t.pul_turi || '=' || t.n::text, ', ' order by t.pul_turi)
    into v_taqsimot
    from (select pul_turi, count(*) as n
            from accounts
           where pul_turi is not null
           group by pul_turi) t;

  raise notice 'Mavjud pul turlari: %', coalesce(v_taqsimot, '(bitta ham yo''q)');

  select string_agg(distinct pul_turi, ', ')
    into v_notanish
    from accounts
   where pul_turi is not null
     and pul_turi not in ('naqd','click','payme','karta','terminal','plastik');

  if v_notanish is not null then
    raise warning 'DIQQAT: ro''yxatdan TASHQARI pul turi bor: % — 2-bo''lim to''xtaydi. Avval ularni to''g''rilang yoki 2-bo''limdagi ro''yxatga qo''shing.', v_notanish;
  end if;
end $preflight15$;


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
--    to'xtaymiz. Ro'yxatni preflight 1.5 ham ko'rsatadi.
do $bolim2$
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
end $bolim2$;

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

-- 3.1 Ustun
alter table pul_turi_kod_blok
  add column if not exists raqam_uzunlik int not null default 2;

do $$
begin
  -- ⚠️ Yuqori chegara 3 — preflight 1.2 bilan MOS. 1.2 accounts.code ga
  --    ATIGI 5 belgi sig'ishini kafolatlaydi (2 belgili prefiks + 3 raqam).
  --    `4` ga ruxsat berilsa 6 belgili kod (550001) paydo bo'lardi va u
  --    varchar(5) ustunda RUN paytida yiqilardi — ikkisi bir xil bo'lsin.
  --    Kengaytirish kerak bo'lsa: avval 1.2 dagi 5 ni 6 qiling, keyin bu yerni.
  if not exists (select 1 from pg_constraint where conname = 'pul_turi_kod_blok_uzunlik_chk') then
    alter table pul_turi_kod_blok add constraint pul_turi_kod_blok_uzunlik_chk
      check (raqam_uzunlik between 2 and 3);
  end if;
end $$;

comment on column pul_turi_kod_blok.raqam_uzunlik is
  'Prefiksdan keyingi raqamlar soni: 2 -> 5501, 3 -> 55001 (ruxsat: 2..3, '
  'preflight 1.2 dagi accounts.code uzunligi bilan mos). Kod naqshi: ^prefix[0-9]{raqam_uzunlik}$';

-- 3.2 Eski `prefix unique` cheklovini (prefix, raqam_uzunlik) ga kengaytiramiz.
--     Aks holda ('55',3) qatorini qo'shib bo'lmaydi — '55' allaqachon bor.
--     Bu BO'SHATISH: avval taqiqlangan hech narsa endi ham taqiq
--     (bir xil prefiks + bir xil uzunlik ikki marta bo'lolmaydi).
do $$
declare c record;
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
  end loop;
end $$;

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


-- ---------------------------------------------------------------------
-- 5. create_pul_turi_child — IMZO O'ZGARMAYDI, xulq eskisidek
-- ---------------------------------------------------------------------
-- Tana ichkiga ko'chdi; bu yerda faqat ADMIN tekshiruvi qoldi.
-- Eski xulq to'liq saqlanadi: admin-only, idempotent, SECURITY DEFINER.
-- Yangilik: turlar ro'yxatiga karta/terminal/plastik qo'shildi.
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


-- ---------------------------------------------------------------------
-- 6. pul_turi_standart() — "yangi kassaga qaysi turlar ochiladi"
-- ---------------------------------------------------------------------
-- Bitta manba: RPC ham, trigger ham, backfill ham shundan o'qiydi —
-- ro'yxat vaqt o'tib uch joyda uch xil bo'lib ketmasin.
-- Aros balanslari: cash / click / payme / dollar. `karta` — Asilbek talabi
-- (naqd emas, lekin dollar ham emas — plastik karta bilan to'lov).
-- USD (dollar) ATAYLAB YO'Q: u valyuta bolasi, `create_valyuta_child` ishi
-- va konvert mantiqiga tegadi (56xx blok, fc_amount, koridor).
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


notify pgrst, 'reload schema';


-- ---------------------------------------------------------------------
-- 9. O'ZINI TEKSHIRUV
-- ---------------------------------------------------------------------
do $$
declare
  v_def   text;
  v_blok  int;
  v_blok3 int;
  v_bosh  bigint;
  v_std   text[];
begin
  if to_regprocedure('public._pul_turi_child_ich(uuid,text)') is null then
    raise exception '_pul_turi_child_ich yaratilmadi';
  end if;
  if to_regprocedure('public.create_pul_turi_child(uuid,text)') is null then
    raise exception 'create_pul_turi_child imzosi yo''qoldi (uuid,text) — ADDITIVE qoidasi buzilgan';
  end if;
  if to_regprocedure('public.hodim_kassa_turlar_toldir(uuid,boolean)') is null then
    raise exception 'hodim_kassa_turlar_toldir yaratilmadi';
  end if;
  if to_regprocedure('public.pul_turi_standart()') is null then
    raise exception 'pul_turi_standart yaratilmadi';
  end if;

  -- Trigger o'rnatildimi
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.accounts'::regclass
       and tgname = 'trg_hodim_kassa_turlar'
       and not tgisinternal
  ) then
    raise exception 'trg_hodim_kassa_turlar triggeri o''rnatilmadi';
  end if;

  -- CHECK kengaydimi
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint
   where conname = 'accounts_pul_turi_chk'
     and conrelid = 'public.accounts'::regclass;
  if v_def is null or v_def not like '%karta%' then
    raise exception 'accounts_pul_turi_chk kengaymadi: %', coalesce(v_def, '(yo''q)');
  end if;

  -- Kod bloklari.
  -- ⚠️ JAMI SANOQ YETARLI EMAS: 3.3 dagi `on conflict (nav) do nothing` nav 4/5/6
  --    boshqa prefiks bilan allaqachon band bo'lsa qatorni JIMGINA o'tkazib
  --    yuboradi — jadvalda baribir 6 ta qator turadi va `count(*) >= 6` yolg'on
  --    tasdiq berardi (5 xonali blok aslida qo'shilmagan). Shuning uchun AYNAN
  --    5 xonali bloklar (raqam_uzunlik = 3) sanaladi.
  select count(*), count(*) filter (where raqam_uzunlik = 3)
    into v_blok, v_blok3
    from pul_turi_kod_blok;

  if v_blok3 < 3 then
    raise exception
      '5 xonali blok (raqam_uzunlik=3) atigi % ta — 3 ta kerak (jami blok: %). Ehtimol nav 4/5/6 boshqa prefiks bilan band va 3.3 dagi insert o''tkazib yuborilgan. Bo''sh nav raqamlari bilan qo''lda qo''shing: insert into pul_turi_kod_blok(nav, prefix, raqam_uzunlik) values (<bo''sh nav>, ''55'', 3), ...',
      v_blok3, v_blok;
  end if;

  -- Standart turlar ro'yxati
  v_std := pul_turi_standart();
  if not ('karta' = any(v_std)) then
    raise exception 'pul_turi_standart ichida karta yo''q';
  end if;

  -- Bo'sh kod sig'imi (taqribiy: har blokda "eng katta band kod"dan yuqorisi
  -- bo'sh deb sanaladi — o'rtadagi bo'shliqlar qayta ishlatilmaydi)
  select sum(greatest((power(10, b.raqam_uzunlik)::int - 1) - coalesce(mx.n, 0), 0))
    into v_bosh
    from pul_turi_kod_blok b
    left join lateral (
      select max(substring(a.code from 3)::int) as n
        from accounts a
       where a.code ~ ('^' || b.prefix || '[0-9]{' || b.raqam_uzunlik::text || '}$')
    ) mx on true;

  raise notice 'OK: turlar avtomatikasi tayyor. Bloklar: %, bo''sh kod (taqribiy): %',
    v_blok, v_bosh;
end $$;


-- ---------------------------------------------------------------------
-- 10. TEKSHIRUV SO'ROVLARI (o'zgartirmaydi)
-- ---------------------------------------------------------------------
-- ⚠️ Bu bo'limda 2 ta SELECT bor (10.1 va 10.2), 11.1 da yana bittasi.
--    Supabase SQL Editor FAQAT OXIRGI statement natijasini ko'rsatadi —
--    hammasini birga RUN qilsangiz faqat oxirgisini ko'rasiz.
--    Har birini SICHQONCHA BILAN BELGILAB alohida RUN qiling.

-- 10.1 Bloklar va ularda qolgan joy
-- ⚠️ Bu SELECT'ni ALOHIDA belgilab RUN qiling (Supabase faqat oxirgi natijani ko'rsatadi)
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

-- 10.2 Hodim kassalari va ularda qaysi turlar bor / yetishmaydi.
--      `section` ustuni ataylab chiqariladi: 'pul' bo'lmasa trigger
--      o'sha kassa uchun ishlamaydi (1.4-tekshiruvga qara).
-- ⚠️ Bu SELECT'ni ALOHIDA belgilab RUN qiling (Supabase faqat oxirgi natijani ko'rsatadi)
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

-- 10.3 Triggerni SINAB ko'rish (ixtiyoriy — test kassa ochadi va o'chiradi).
--      ⚠️ accounts dan DELETE qiladi — faqat yozuvsiz test kassasi uchun.
-- do $$
-- declare v_g uuid; v_k uuid; n int;
-- begin
--   select id into v_g from accounts where kassa_turi = 'xarajat_guruh' and is_active limit 1;
--   insert into accounts(code, name, type, section, currency, parent_id, kassa_turi, is_active, subtitle)
--   values ('5499', 'ZZZ Test Hodim', 'aktiv', 'pul', 'UZS', v_g, 'xarajat', true, 'Test')
--   returning id into v_k;
--   select count(*) into n from accounts where parent_id = v_k and pul_turi is not null;
--   raise notice 'Trigger ochgan turlar soni: % (4 bo''lishi kerak)', n;
--   delete from accounts where parent_id = v_k;
--   delete from accounts where id = v_k;
-- end $$;


-- =====================================================================
-- 11. BACKFILL — MAVJUD hodim kassalariga turlarni to'ldirish
--     ⚠️ ixtiyoriy, ALOHIDA RUN. Yuqoridagi qism bilan birga ishlamaydi.
-- =====================================================================

-- 11.1 ⭐ AVVAL PREVIEW — nechta kassa, nechta yangi hisob ochiladi.
--      Bu so'rov hech narsani o'zgartirmaydi.
-- ⚠️ Bu SELECT'ni ALOHIDA belgilab RUN qiling (Supabase faqat oxirgi natijani ko'rsatadi)
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

-- 11.2 BAJARISH — 11.1 natijasi to'g'ri bo'lsa, quyidagi bloknining
--      izohini olib tashlab RUN qiling.
--      hodim_kassa_turlar_toldir har kassaga idempotent ishlaydi:
--      bori qayta ochilmaydi. Bitta kassada xato bo'lsa — o'sha kassa
--      o'tkazib yuboriladi (warning), qolganlari davom etadi.
--
-- do $$
-- declare
--   r        record;
--   v_res    jsonb;
--   n_kassa  int := 0;
--   n_yangi  int := 0;
--   n_xato   int := 0;
-- begin
--   for r in
--     select p.id, p.code, p.name
--       from accounts p
--       join accounts g on g.id = p.parent_id and g.kassa_turi = 'xarajat_guruh'
--      where p.is_active and p.section = 'pul' and p.kassa_turi = 'xarajat'
--        and p.pul_turi is null and coalesce(p.currency,'UZS') = 'UZS'
--      order by p.code
--   loop
--     begin
--       v_res   := hodim_kassa_turlar_toldir(r.id);   -- p_usd = false
--       n_kassa := n_kassa + 1;
--       n_yangi := n_yangi + coalesce(jsonb_array_length(v_res -> 'yaratildi'), 0);
--     exception when others then
--       n_xato := n_xato + 1;
--       raise warning 'Kassa % (%) to''ldirilmadi: %', r.code, r.name, sqlerrm;
--     end;
--   end loop;
--   raise notice 'BACKFILL: % ta kassa ko''rildi, % ta yangi tur hisobi ochildi, % ta xato',
--     n_kassa, n_yangi, n_xato;
-- end $$;

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
-- 12.3 5 xonali bloklarni olib tashlash (yangi kod berilmasin):
--   delete from pul_turi_kod_blok where raqam_uzunlik = 3;
--   -- ⚠️ Allaqachon berilgan 5 xonali kodlar o'z joyida qoladi (ular unique va
--   --    hech qaysi so'rovni buzmaydi) — faqat YANGI kod 4 xonali bo'ladi.
