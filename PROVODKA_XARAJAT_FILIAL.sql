-- =====================================================================
--  ⚠️⚠️  SUPABASE SQL EDITOR — QANDAY RUN QILINADI (avval SHUNI o'qing)
-- ---------------------------------------------------------------------
--   1) Tartib: 0-BOSQICH (tekshiruv) → 1-BOSQICH (funksiyalar) →
--      2-BOSQICH (o'z-o'zini test) → 3-BOSQICH (ko'rish). Butun faylni
--      birdaniga RUN QILMANG.
--   2) Har bo'lak ⬇⬇⬇ va ⬆⬆⬆ belgilari orasida — AYNAN o'sha oraliqni
--      belgilab RUN qiling.
--   3) Bu faylda `do` bloki UMUMAN YO'Q. Dollar-quote belgisi (ikki dollar
--      yonma-yon) FAQAT ikki funksiyaning tanasida (1.1 va 1.2) — izohlarda
--      umuman yo'q. NOMLANGAN dollar-teg ham, ichma-ich dollar-quote ham yo'q.
--      Sabab: Supabase SQL Editor `do` blokini bo'lib yuborar va PL/pgSQL
--      o'zgaruvchisini jadval deb izlar edi
--      (`ERROR: 42P01: relation "v_yoq" does not exist`).
--      `create or replace function ... as` esa muammosiz ishlaydi.
--   4) Shu sababli 1.1 / 1.2 funksiyasini BOSHIDAN OXIRIGACHA belgilang:
--      `create or replace function` qatoridan pastdagi yopuvchi dollar-quote
--      qatorigacha (ikkalasi ham ichida). Yarim belgilansa Postgres tanani
--      PL/pgSQL emas, oddiy SQL deb o'qiydi va yana o'sha 42P01 xatosi
--      chiqadi — bu FAYL XATOSI EMAS, qayta to'liq belgilang.
--   5) 2-BOSQICH (o'zini tekshiruv) endi bitta blok emas — oddiy `select`
--      lar ketma-ketligi. 2.0 dan 2.8 gacha TARTIB bilan, har birini
--      alohida belgilab RUN qiling va `natija` ustuniga qarang.
-- =====================================================================

-- =====================================================================
--  PROVODKA_XARAJAT_FILIAL.sql — "savdo qilmaydigan, lekin xarajati bor"
--  filiallarni qo'lda qo'shish (Aros'ga BOG'LANMAGAN filial hisobi)
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  MUAMMO: ba'zi filiallar Aros'da kassa (cachier) sifatida umuman yo'q —
--     ular savdo qilmaydi. Lekin ularga xarajat yoziladi (ijara, kommunal,
--     ta'mir...). Hozir bunday filial `accounts` da yo'q, shuning uchun:
--        • hodim-dev.html / professional-dev.html / standart-dev.html
--          "Filial" tanlagichida KO'RINMAYDI (manba: v_filial_tanlov);
--        • admin-dev.html ruxsat oynasida ham chiqmaydi (manba: kassalar
--          ro'yxatidan kassa_turi='filial' filtri).
--
--  YECHIM: oddiy filial kassa hisobi (52xx, kassa_turi='filial'), lekin
--     `filial_ref = NULL`. Ya'ni:
--        ✔ v_filial_tanlov ga o'z-o'zidan tushadi (shart: kassa_turi='filial',
--          is_active, pul_turi is null, currency='UZS') — VIEW O'ZGARMAYDI;
--        ✔ admin-dev.html ruxsat ro'yxatida chiqadi (kassa_turi='filial');
--        ✔ Aros SINXRONI UNGA TEGMAYDI — v_filial_sync_mapping da
--          `k.filial_ref is not null` sharti bor (PROVODKA_KAPITAL.sql),
--          filial_ref NULL bo'lgan hisob u yerga umuman tushmaydi.
--          `sync_filial_balans` / `sync_received_transfers` ham shu mapping
--          orqali ishlaydi — ya'ni bu filialga hech qachon avtomatik pul
--          yozilmaydi. Bu ATAYLAB: u savdo qilmaydi, faqat xarajat tegi.
--
--  ⚠️ KUTILGAN YON TA'SIR: yangi filial `kassa-dev.html` da "Filial
--     kassalari" guruhida 0 qoldiqli karta bo'lib ko'rinadi (v_kassa_card
--     sharti: section='pul' + currency='UZS' + is_active). Bu buzilish emas —
--     hisob haqiqatan ham mavjud kassa hisobi, shunchaki qoldig'i 0.
--     Uning tur (naqd/click/payme) va valyuta bolalari OCHILMAYDI:
--        • trg_hodim_kassa_turlar faqat parent=5400 (hodim) uchun ishlaydi;
--        • parent_id NULL bo'lgani uchun v_kassa_valyutalar ga tushmaydi.
--     Ya'ni `jami` = o'zining qoldig'i = 0.
--
--  ADDITIVE: birorta jadval/ustun/view/funksiya o'chirilmaydi va imzosi
--     o'zgartirilmaydi. Faqat IKKI YANGI funksiya qo'shiladi.
--
--  TALAB: accounts da `kassa_turi`, `subtitle`, `pul_turi`, `filial_ref`
--     ustunlari bo'lsin (PROVODKA_V6 / PROVODKA_VALYUTA allaqachon qo'shgan).
--
--  ⚠️ Supabase SQL Editor faqat OXIRGI `select` natijasini ko'rsatadi.
--     Shuning uchun quyida har `select` alohida belgilanadi — matnda
--     ⬇⬇⬇ / ⬆⬆⬆ chegaralari qo'yilgan.
-- =====================================================================


-- #####################################################################
--  0-BOSQICH — TEKSHIRUV (o'zgartirmaydi).  ALOHIDA belgilab RUN qiling.
-- #####################################################################
--  Oddiy `select` — `do` bloki EMAS, shuning uchun belgilash xatosi bo'lmaydi.
--  `holat` ustunida ❌ chiqsa 1-BOSQICHGA O'TMANG: `nima_qilish` ustunini o'qing.
--  Tekshiruvlar (ilgari `raise exception` bo'lgan) AYNAN o'sha shartlar:
--    • accounts da 11 ta ustun bormi;  • v_filial_tanlov view bormi;
--    • 52xx blokida hozir nechta hisob bor.

-- ⬇⬇⬇  SHU QATORDAN pastdagi `) t;` QATORIGACHA (ikkalasi ham ichida) BELGILANG  ⬇⬇⬇
select case
         when t.yoq is not null then '❌ accounts jadvalida ustun(lar) yo''q: ' || t.yoq
         when t.view_yoq        then '❌ v_filial_tanlov view topilmadi'
         else '✅ OK: ustunlar joyida, view bor — 1-BOSQICHGA o''ting'
       end                                                     as holat,
       coalesce(t.yoq, '—')                                    as yetishmagan_ustunlar,
       case when t.view_yoq then '❌ yo''q' else '✅ bor' end   as v_filial_tanlov,
       t.n52                                                   as hisob_52xx,
       case
         when t.yoq is not null
           then 'Avval PROVODKA_V6.sql / PROVODKA_VALYUTA.sql migratsiyalarini bajaring.'
         when t.view_yoq
           then 'PROVODKA_V6.sql (4-bo''lim) yoki PROVODKA_PAGES_EMPTY.sql (6-bo''lim) ni RUN qiling.'
         else '—'
       end                                                     as nima_qilish
  from (
    select (select string_agg(c, ', ')
              from unnest(array['code','name','type','section','currency','parent_id',
                                'kassa_turi','is_active','subtitle','pul_turi','filial_ref']) c
             where not exists (
               select 1 from information_schema.columns
                where table_schema = 'public'
                  and table_name  = 'accounts'
                  and column_name = c))                        as yoq,
           (to_regclass('public.v_filial_tanlov') is null)      as view_yoq,
           (select count(*) from accounts
             where code ~ '^52[0-9]{2}$')                      as n52
  ) t;
-- ⬆⬆⬆  SHU QATORGACHA BELGILANG (0-BOSQICH tugadi)  ⬆⬆⬆


-- #####################################################################
--  1-BOSQICH — FUNKSIYALAR.  Butun 1-BOSQICHNI birdaniga RUN qilsa bo'ladi
--  (1.1 boshidan `notify pgrst` qatorigacha). Xato chiqsa — 1.1 va 1.2 ni
--  ⬇⬇⬇ / ⬆⬆⬆ chegaralari bo'yicha ALOHIDA, TO'LIQ belgilab RUN qiling.
-- #####################################################################

-- ---------------------------------------------------------------------
-- 1.1 xarajat_filial_yarat(p_nom, p_subtitle) -> jsonb
-- ---------------------------------------------------------------------
-- Admin, SECURITY DEFINER, idempotent.
-- Yaratadigan qator (kassa hisobi, lekin Aros'siz):
--     code       = 52xx (bo'sh keyingi raqam)
--     type       = 'aktiv',  section = 'pul',  currency = 'UZS'
--     kassa_turi = 'filial'  <- v_filial_tanlov va admin-dev shundan oladi
--     parent_id  = NULL      <- kassaning O'ZI, bola-hisob emas
--     pul_turi   = NULL      <- tur bolasi emas
--     filial_ref = NULL      <- ⚠️ AROS SINXRONI TEGMAYDI (yuqoridagi izoh)
--     aros_title = NULL      <- markaziy kassa nomiga ham bog'lanmaydi
--
-- IDEMPOTENT: aynan shu nomli FAOL filial (parent_id is null) bo'lsa —
-- yangisi ochilmaydi, mavjudi `yangi:false` bilan qaytadi. Solishtirish
-- katta/kichik harf va chetdagi bo'shliqlarga sezgir emas.
--
-- ⚠️ NOM TO'QNASHUVI: idempotentlikdan KEYIN yana bir tekshiruv bor —
-- yangi nom mavjud pul kassasi bilan `aros_nom_norm` bo'yicha bir xil
-- normallashsa (masalan "Kashkadaryo kassa" ↔ "Qashqadaryo Kassa"),
-- funksiya `raise exception` bilan to'xtaydi. Sabab: aros_kassa_topish()
-- 3-qadami ikkita moslik topib, o'sha filial transferlarini jimgina
-- yozmay qo'yardi. Tafsilot — funksiya tanasidagi izohda.
--
-- Qaytishi: {"ok":true,"id":"...","code":"5233","name":"...","yangi":true|false}
--
-- ⚠️ ADMIN TEKSHIRUVI: auth.uid() NULL bo'lsa (Supabase SQL Editor yoki n8n
--    service_role) o'tkaziladi — loyihadagi mavjud naqsh
--    (hodim_kassa_turlar_toldir, entry_line guard triggeri ham shunday).
--    `anon` ga EXECUTE berilmagan.
-- ⬇⬇⬇  1.1: SHU QATORDAN pastdagi YOPUVCHI dollar-quote qatorigacha
--       (ikkalasi ham ichida) BELGILANG  ⬇⬇⬇
create or replace function xarajat_filial_yarat(p_nom text, p_subtitle text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_role text;
  v_nom  text := btrim(coalesce(p_nom, ''));
  v_sub  text := nullif(btrim(coalesce(p_subtitle, '')), '');
  v_id   uuid;
  v_code text;
  v_next int;
  i      int;
  v_tq_code text;   -- nom to'qnashuvi topilsa — mavjud hisob kodi
  v_tq_name text;   -- ... va nomi (xato hint'ida ko'rsatiladi)
begin
  -- auth: faqat admin (uid yo'q = service_role/SQL editor -> o'tadi)
  if v_uid is not null then
    select role into v_role from profiles where id = v_uid;
    if v_role is distinct from 'admin' then
      raise exception 'Faqat admin filial qo''sha oladi';
    end if;
  end if;

  if v_nom = '' then
    raise exception 'Filial nomi bo''sh bo''lmasin';
  end if;
  if length(v_nom) > 80 then
    raise exception 'Filial nomi juda uzun (% belgi, 80 dan oshmasin)', length(v_nom);
  end if;

  -- idempotent: shu nomli faol filial bormi (bola-hisoblar hisobga olinmaydi)
  select id, code into v_id, v_code
    from accounts
   where kassa_turi = 'filial'
     and coalesce(is_active, true) = true
     and parent_id is null
     and lower(btrim(name)) = lower(v_nom)
   order by code
   limit 1;

  if v_id is not null then
    return jsonb_build_object('ok', true, 'id', v_id, 'code', v_code,
                              'name', v_nom, 'yangi', false);
  end if;

  -- ⚠️ NOM TO'QNASHUVI — Aros transfer sinxronini to'xtatib qo'yishi mumkin.
  --    `aros_kassa_topish()` (PROVODKA_TRANSFER.sql) 3-qadamda kassani
  --    `aros_nom_norm(a.name)` bo'yicha izlaydi. `aros_nom_norm` esa kichik
  --    harfga o'tkazadi, `q→k`, `x→h` qiladi va harf/raqamdan boshqa hamma
  --    narsani tashlaydi. Ya'ni "Kashkadaryo kassa" va "Qashqadaryo Kassa"
  --    AYNAN bir xil normallashadi. Bunday ikkinchi hisob ochilsa, 3-qadam
  --    IKKITA moslik topadi va ataylab `ok:false` qaytaradi — o'sha filial
  --    transferlari JIMGINA yozilmay qoladi (xato ko'rinmaydi, pul yo'qoladi).
  --    Shuning uchun insertdan OLDIN to'sib qo'yamiz.
  --
  --    Filtr AYNAN 3-qadamnikidek: faol, top-level (parent_id is null),
  --    section='pul', currency='UZS', kassa_turi<>'xarajat_guruh'. Kengroq
  --    olsak — sinxronga aloqasi yo'q hisob uchun ham bekorga rad etardik.
  --    `aros_nom_norm` bazada bo'lmasa (PROVODKA_TRANSFER.sql hali RUN
  --    qilinmagan) tekshiruv o'tkazib yuboriladi — u holda sinxron ham yo'q.
  --    Chaqiruv `execute` bilan: funksiya yo'q bo'lsa plpgsql tanani
  --    tayyorlashda ham xato bermasin.
  --    ⚠️ So'rov matni ODDIY BIR TIRNOQLI satr (ichma-ich dollar-quote YO'Q,
  --    aks holda funksiya tanasi vaqtidan oldin yopilardi). Shuning uchun
  --    ichkaridagi har `'` ikkilangan: 'pul' -> ''pul'', '' -> ''''.
  if to_regprocedure('public.aros_nom_norm(text)') is not null then
    execute '
      select a.code, a.name
        from accounts a
       where a.section = ''pul'' and a.is_active and a.parent_id is null
         and coalesce(a.currency, ''UZS'') = ''UZS''
         and coalesce(a.kassa_turi, '''') <> ''xarajat_guruh''
         and aros_nom_norm(a.name) = aros_nom_norm($1)
       order by a.code
       limit 1'
    into v_tq_code, v_tq_name using v_nom;

    if v_tq_code is not null then
      raise exception 'Bu nom mavjud kassa nomi bilan bir xil o''qiladi — Aros transfer sinxroni buziladi'
        using hint = 'To''qnashuv: ' || v_tq_code || ' ' || v_tq_name ||
                     '. Nomni farqlantiring — solishtirishda q=k, x=h va bo''sh joy/tinish belgilari e''tiborga olinmaydi.';
    end if;
  end if;

  -- Kod: 52xx blokidagi eng katta raqam + 1 (faol bo'lmagan eski hisoblar ham
  -- sanaladi — kod unique). `substring(code from 3)` — regexp uzunlikni
  -- kafolatlagani uchun ::int xavfsiz. 5 urinish: bir vaqtda ikki sessiya
  -- filial ochsa kod poygasi bo'lishi mumkin (create_pul_turi_child naqshi).
  for i in 1..5 loop
    select coalesce(max(substring(a.code from 3)::int), 0) + 1
      into v_next
      from accounts a
     where a.code ~ '^52[0-9]{2}$';

    if v_next > 99 then
      raise exception '52xx filial kod bloki to''ldi (5299 gacha band).'
        using hint = 'Yangi blok kerak: 52xx tugadi. Boshqa prefiks (masalan 55xx) uchun bu funksiya yangilanishi shart — kod diapazoni hozir qat''iy 52xx.';
    end if;

    v_code := '52' || lpad(v_next::text, 2, '0');

    begin
      insert into accounts(code, name, type, section, currency, parent_id,
                           kassa_turi, is_active, subtitle, pul_turi,
                           filial_ref, aros_title)
      values (v_code, v_nom, 'aktiv', 'pul', 'UZS', null,
              'filial', true, v_sub, null,
              null, null)      -- ⚠️ filial_ref/aros_title NULL: Aros sinxroni tegmaydi
      returning id into v_id;

      return jsonb_build_object('ok', true, 'id', v_id, 'code', v_code,
                                'name', v_nom, 'yangi', true);
    exception when unique_violation then
      -- kod band bo'lib qolgan — keyingi urinishda max qayta hisoblanadi
      null;
    end;
  end loop;

  raise exception 'Filialga bo''sh kod topilmadi (5 urinish): %', v_nom;
end
$$;
-- ⬆⬆⬆  1.1 shu yergacha (yopuvchi dollar-quote qatori ham ichida)  ⬆⬆⬆

revoke all on function xarajat_filial_yarat(text, text) from public, anon;
grant execute on function xarajat_filial_yarat(text, text) to authenticated, service_role;

comment on function xarajat_filial_yarat(text, text) is
  'Qo''lda xarajat filiali ochadi (52xx, kassa_turi=''filial'', filial_ref NULL — '
  'Aros sinxroni tegmaydi). Admin, idempotent (nom bo''yicha). '
  'Qaytishi: {ok,id,code,name,yangi}.';


-- ---------------------------------------------------------------------
-- 1.2 xarajat_filial_ochir(p_id) -> jsonb
-- ---------------------------------------------------------------------
-- HECH NARSA O'CHIRMAYDI — faqat `is_active=false` (loyiha qoidasi).
-- Ruxsat beriladigan holat FAQAT: qo'lda ochilgan, hali ishlatilmagan filial.
-- Rad etiladi:
--   • filial_ref to'ldirilgan (Aros bilan bog'langan) — sinxron sindirilmasin;
--   • hisobda (yoki bola-hisoblarida) birorta entry_line bor;
--   • birorta yozuvning `entry.filial_ids` massivida turibdi (xarajat tegi);
--   • standart_xarajat da limiti bor.
-- Bola-hisoblari bo'lsa (qo'lda ochilgan tur/valyuta) — ular ham birga
-- passivlashtiriladi, chunki ular yolg'iz qolsa kassa kartasi buziladi.
--
-- Qaytishi: {"ok":true,"id":"...","code":"...","name":"...","bolalar":N}
-- ⬇⬇⬇  1.2: SHU QATORDAN pastdagi YOPUVCHI dollar-quote qatorigacha
--       (ikkalasi ham ichida) BELGILANG  ⬇⬇⬇
create or replace function xarajat_filial_ochir(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_role  text;
  v_acc   accounts%rowtype;
  v_n     int;
  v_bola  int;
begin
  if v_uid is not null then
    select role into v_role from profiles where id = v_uid;
    if v_role is distinct from 'admin' then
      raise exception 'Faqat admin filialni o''chira oladi';
    end if;
  end if;

  select * into v_acc from accounts where id = p_id;
  if not found then
    raise exception 'Hisob topilmadi';
  end if;

  if v_acc.kassa_turi is distinct from 'filial' or v_acc.parent_id is not null then
    raise exception 'Bu filial kassasi emas: % %', v_acc.code, v_acc.name;
  end if;

  if v_acc.filial_ref is not null then
    raise exception 'Aros bilan bog''langan filial o''chirilmaydi: % %', v_acc.code, v_acc.name
      using hint = 'filial_ref to''ldirilgan — bu filial Aros sinxronida qatnashadi. Uni Aros tomonda yoping.';
  end if;

  -- yozuvi bormi (o'zi + bola-hisoblari; o'chirilgan yozuvlar ham sanaladi)
  select count(*) into v_n
    from entry_line l
    join accounts a on a.id = l.account_id
   where a.id = p_id or a.parent_id = p_id;
  if v_n > 0 then
    raise exception 'Filialda % ta provodka satri bor — o''chirib bo''lmaydi (% %)', v_n, v_acc.code, v_acc.name
      using hint = 'Yozuvi bor hisob passivlashtirilmaydi: hisobot va balans undan o''qiydi.';
  end if;

  -- xarajat tegi sifatida ishlatilganmi
  select count(*) into v_n from entry e where p_id = any(e.filial_ids);
  if v_n > 0 then
    raise exception 'Filial % ta xarajat yozuvida teg sifatida turibdi (% %)', v_n, v_acc.code, v_acc.name
      using hint = 'entry.filial_ids ichida uchraydi — teg yo''qolib qolmasin.';
  end if;

  -- standart xarajat limiti bormi (jadval bo'lmasa o'tkazib yuboriladi)
  if to_regclass('public.standart_xarajat') is not null then
    execute 'select count(*) from standart_xarajat where filial_id = $1'
      into v_n using p_id;
    if v_n > 0 then
      raise exception 'Filialga % ta standart xarajat limiti biriktirilgan (% %)', v_n, v_acc.code, v_acc.name
        using hint = 'Avval standart-dev.html da limitlarni o''chiring.';
    end if;
  end if;

  update accounts set is_active = false
   where parent_id = p_id and coalesce(is_active, true) = true;
  get diagnostics v_bola = row_count;

  update accounts set is_active = false where id = p_id;

  return jsonb_build_object('ok', true, 'id', v_acc.id, 'code', v_acc.code,
                            'name', v_acc.name, 'bolalar', v_bola);
end
$$;
-- ⬆⬆⬆  1.2 shu yergacha (yopuvchi dollar-quote qatori ham ichida)  ⬆⬆⬆

revoke all on function xarajat_filial_ochir(uuid) from public, anon;
grant execute on function xarajat_filial_ochir(uuid) to authenticated, service_role;

comment on function xarajat_filial_ochir(uuid) is
  'Qo''lda ochilgan xarajat filialini passivlashtiradi (is_active=false, o''chirmaydi). '
  'Admin. Aros bilan bog''langan (filial_ref) yoki yozuvi/tegi/limiti bor filial rad etiladi.';


-- ---------------------------------------------------------------------
-- 1.3 v_filial_tanlov — O'ZGARTIRILMAYDI
-- ---------------------------------------------------------------------
-- Joriy ta'rif (PROVODKA_PAGES_EMPTY.sql, 6-bo'lim):
--     kassa_turi='filial' and is_active and pul_turi is null and currency='UZS'
-- Yangi qator shu shartlarning HAMMASIGA tushadi, shuning uchun view
-- create or replace QILINMAYDI (imzo ham, qatorlar ham o'zgarmasin).
-- Quyidagi tekshiruv shuni MAJBURLAYDI: view yangi filialni ko'rmasa —
-- 2-bosqich xato beradi va sabab darrov ko'rinadi.

notify pgrst, 'reload schema';


-- #####################################################################
--  2-BOSQICH — O'ZINI TEKSHIRUV (test filial ochib, tekshirib, o'chiradi)
-- #####################################################################
--  Avval bu bo'lim bitta `do` bloki edi — Supabase SQL Editor uni bo'lib
--  yuborar va PL/pgSQL o'zgaruvchisini jadval deb izlar edi
--  (`ERROR: 42P01: relation "v_nom" does not exist`). Endi har tekshiruv
--  ALOHIDA oddiy `select`. Shartlar, ketma-ketlik va xato matnlari
--  `do` blokidagi bilan AYNAN bir xil — faqat qadoqlash o'zgardi.
--
--  QANDAY O'QILADI: `natija` ustuni
--     ✅ OK      -> keyingi bo'lakka o'ting
--     ❌ ...XATO -> TO'XTANG, sababni hal qiling.
--
--  🔴 IKKI MUHIM FARQ (`do` blokiga nisbatan):
--   1. Tartib MUHIM: 2.0 → 2.8 gacha KETMA-KET, birin-ketin. Har bo'lak
--      o'zidan oldingisi qoldirgan holatga tayanadi (test filial nom
--      bo'yicha topiladi, `order by code desc limit 1` — eng yangisi).
--   2. Endi hammasi BITTA tranzaksiya emas: biror tekshiruv ❌ bersa test
--      filial bazada QOLIB KETADI. Shuning uchun ❌ chiqsa ham oxirida
--      2.8 TOZALASH ni baribir RUN qiling (u xavfsiz — faqat
--      'ZZ Test filial%' nomli, filial_ref NULL qatorlarga tegadi).
--
--  Test filial 2.8 da jadvaldan BUTUNLAY o'chiriladi — 52xx kodi bo'shab
--  qoladi (har RUN da bittadan yeyilmasin).

-- ---------------------------------------------------------------------
-- 2.0 Boshlashdan oldin: eski test filial qolib ketmaganmi.
--     ❌ bo'lsa avval ROLLBACK (b) bilan tozalang, keyin 2.1 ga o'ting.
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
select case when count(*) = 0
              then '✅ OK: eski test filial yo''q — 2.1 ga o''ting'
              else '❌ MUAMMO: eski test filial bor — avval ROLLBACK (b) ni bajaring'
       end                        as natija,
       count(*)                   as qolgan_qator
  from accounts
 where name ilike 'ZZ Test filial%';
-- ⬆⬆⬆  2.0 shu yergacha  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.1 (a) YARATISH — test filial ochiladi (bu bo'lak accounts ga YOZADI).
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
with r as (
  select xarajat_filial_yarat('ZZ Test filial (o''chiriladi)', 'Test · Xarajat') as res
)
select case
         when (r.res->>'ok') is distinct from 'true'
              or nullif(r.res->>'id', '') is null
           then '❌ TEST 1 XATO: yaratilmadi — ' || r.res::text
         when (r.res->>'yangi') <> 'true'
           then '❌ TEST 1 XATO: yangi=false, oldin qolib ketgan test filial bormi? — ' || r.res::text
         else '✅ TEST 1 OK: ' || (r.res->>'code') || ' ochildi (' || (r.res->>'name') || ')'
       end        as natija,
       r.res      as javob
  from r;
-- ⬆⬆⬆  2.1 shu yergacha  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.2 (b) IDEMPOTENTLIK — ikkinchi chaqiruv YANGI ochmasin.
--     Nom ataylab lower() bilan beriladi (katta/kichik harf sezgir emas).
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
with t as (
  select id, code from accounts
   where name ilike 'ZZ Test filial%'
   order by code desc limit 1
),
r as (
  -- ⚠️ t bo'sh bo'lsa funksiya UMUMAN chaqirilmaydi — aks holda bu bo'lak
  --    2.1 ni bajarmasdan RUN qilinganda test filialni O'ZI ochib qo'yardi.
  select case when (select id from t) is null then null::jsonb
              else xarajat_filial_yarat(lower('ZZ Test filial (o''chiriladi)'), null)
         end as res
)
select case
         when t.id is null
           then '❌ TEST 2 XATO: test filial topilmadi — 2.1 ni bajardingizmi?'
         when (r.res->>'yangi') <> 'false'
              or (r.res->>'id') is distinct from t.id::text
           then '❌ TEST 2 XATO: idempotent emas — ' || r.res::text
         else '✅ TEST 2 OK: idempotent (yangi=false)'
       end        as natija,
       t.code     as test_filial,
       r.res      as javob
  from r left join t on true;
-- ⬆⬆⬆  2.2 shu yergacha  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.3 (c) v_filial_tanlov KO'RDIMI — view o'zgartirilmagani shu bilan
--     tasdiqlanadi (hodim / professional / standart aynan shundan oladi).
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
with t as (
  select id, code from accounts
   where name ilike 'ZZ Test filial%'
   order by code desc limit 1
),
v as (
  select count(*) as n from v_filial_tanlov where id = (select id from t)
)
select case
         when (select id from t) is null
           then '❌ TEST 3 XATO: test filial topilmadi — 2.1 ni bajardingizmi?'
         when v.n <> 1
           then '❌ TEST 3 XATO: v_filial_tanlov da ' || v.n
                || ' qator (1 kutilgandi) — view sharti mos kelmadi'
         else '✅ TEST 3 OK: v_filial_tanlov da ko''rinadi'
       end        as natija,
       v.n        as qator,
       (select code from t) as test_filial
  from v;
-- ⬆⬆⬆  2.3 shu yergacha  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.4 (d) KASSA KARTASI buzilmadimi: yangi filial BITTA qator, jami = 0.
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
with t as (
  select id, code from accounts
   where name ilike 'ZZ Test filial%'
   order by code desc limit 1
),
k as (
  select count(*)                            as n,
         count(*) filter (where jami = 0)    as n0
    from v_kassa_card where id = (select id from t)
)
select case
         when (select id from t) is null
           then '❌ TEST 4 XATO: test filial topilmadi — 2.1 ni bajardingizmi?'
         when k.n <> 1
           then '❌ TEST 4 XATO: v_kassa_card da ' || k.n || ' qator (1 kutilgandi)'
         when k.n0 <> 1
           then '❌ TEST 4 XATO: yangi filialning jami qoldig''i 0 emas'
         else '✅ TEST 4 OK: v_kassa_card — 1 qator, jami = 0'
       end        as natija,
       k.n        as qator,
       k.n0       as jami_nol
  from k;
-- ⬆⬆⬆  2.4 shu yergacha  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.5 (e) AROS SINXRONI TEGMASIN — mapping'da umuman bo'lmasin.
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
with t as (
  select id, code from accounts
   where name ilike 'ZZ Test filial%'
   order by code desc limit 1
),
m as (
  select count(*) as n from v_filial_sync_mapping where kassa_id = (select id from t)
)
select case
         when (select id from t) is null
           then '❌ TEST 5 XATO: test filial topilmadi — 2.1 ni bajardingizmi?'
         when m.n <> 0
           then '❌ TEST 5 XATO: v_filial_sync_mapping da ' || m.n
                || ' qator — Aros sinxroni bu filialga yozadi!'
         else '✅ TEST 5 OK: Aros sinxroni tegmaydi (filial_ref NULL)'
       end        as natija,
       m.n        as qator
  from m;
-- ⬆⬆⬆  2.5 shu yergacha  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.6 (f) VALYUTA BOLASI paydo bo'lmadimi (parent_id NULL — tushmasligi kerak).
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
with t as (
  select id, code from accounts
   where name ilike 'ZZ Test filial%'
   order by code desc limit 1
),
v as (
  select count(*) as n from v_kassa_valyutalar where parent_id = (select id from t)
)
select case
         when (select id from t) is null
           then '❌ TEST 6 XATO: test filial topilmadi — 2.1 ni bajardingizmi?'
         when v.n <> 0
           then '❌ TEST 6 XATO: v_kassa_valyutalar da ' || v.n || ' qator'
         else '✅ TEST 6 OK: valyuta bolasi yo''q'
       end        as natija,
       v.n        as qator
  from v;
-- ⬆⬆⬆  2.6 shu yergacha  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.7 (g1) O'CHIRISH ishlaydimi — xarajat_filial_ochir() chaqiriladi.
--      Bu bo'lak accounts ni O'ZGARTIRADI (is_active=false).
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
with t as (
  select id, code from accounts
   where name ilike 'ZZ Test filial%'
   order by code desc limit 1
),
o as (
  select case when (select id from t) is null then null::jsonb
              else xarajat_filial_ochir((select id from t)) end as res
)
select case
         when o.res is null
           then '❌ TEST 7 XATO: test filial topilmadi — 2.1 ni bajardingizmi?'
         when (o.res->>'ok') <> 'true'
           then '❌ TEST 7 XATO: o''chirilmadi — ' || o.res::text
         else '✅ TEST 7 OK (1/2): passivlashtirildi — endi 2.7.1 ni RUN qiling'
       end        as natija,
       o.res      as javob
  from o;
-- ⬆⬆⬆  2.7 shu yergacha  ⬆⬆⬆

-- ---------------------------------------------------------------------
-- 2.7.1 (g2) O'chirilgandan keyin ro'yxatdan chiqdimi.
--      ⚠️ ALOHIDA `select` bo'lishi SHART: bitta `select` ichida view
--         hali o'chirishdan OLDINGI suratni ko'rar edi (statement snapshot).
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
with t as (
  select id, code from accounts
   where name ilike 'ZZ Test filial%'
   order by code desc limit 1
),
v as (
  select count(*) as n from v_filial_tanlov where id = (select id from t)
)
select case
         when (select id from t) is null
           then '❌ TEST 7 XATO: test filial topilmadi — 2.1 ni bajardingizmi?'
         when v.n <> 0
           then '❌ TEST 7 XATO: o''chirilgandan keyin ham v_filial_tanlov da turibdi'
         else '✅ TEST 7 OK (2/2): passivlashtirildi, ro''yxatdan chiqdi'
       end        as natija,
       v.n        as qator
  from v;
-- ⬆⬆⬆  2.7.1 shu yergacha  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.8 (h) TOZALASH: test filial `is_active=false` bo'lib qolsa 52xx kodi
--     band bo'lib qoladi va bu test har RUN da bittadan kod yeydi (5299
--     gacha 97 ta joy bor). Shuning uchun butunlay o'chiramiz.
--     XAVFSIZ: hisob 2.1 da endigina yaratildi va 2.7 dagi
--     xarajat_filial_ochir() uning entry_line'i, entry.filial_ids tegi va
--     standart_xarajat limiti YO'Qligini allaqachon tekshirdi (bo'lganida
--     TEST 7 xato berardi). Ya'ni delete birorta yozuvni yetim qoldirmaydi.
--     Bola-hisob nazariy jihatdan ham yo'q, lekin FK xatosi bo'lmasin uchun
--     avval ular o'chiriladi.
--     Qo'shimcha to'siq: `filial_ref is null` — Aros bilan bog'langan
--     hisobga hech qachon tegmaydi.
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  IKKI `delete` NI BIRGA belgilab RUN qiling  ⬇⬇⬇
delete from accounts
 where parent_id in (select id from accounts
                      where name ilike 'ZZ Test filial%'
                        and filial_ref is null);

delete from accounts
 where name ilike 'ZZ Test filial%'
   and filial_ref is null;
-- ⬆⬆⬆  2.8 shu yergacha  ⬆⬆⬆

-- ---------------------------------------------------------------------
-- 2.8.1 Tozalash tasdig'i. Hammasi ✅ bo'lsa: HAMMA TEST O'TDI, test filial
--       jadvaldan o'chirildi, iz qolmadi.
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
select case when count(*) <> 0
              then '❌ TEST 8 XATO: test filial o''chmadi (' || count(*) || ' ta qator qoldi)'
              else '✅ TEST 8 OK: test filial butunlay o''chirildi — 52xx kodi bo''shadi'
       end                        as natija,
       count(*)                   as qolgan_qator
  from accounts
 where name ilike 'ZZ Test filial%';
-- ⬆⬆⬆  2.8.1 shu yergacha (2-BOSQICH tugadi)  ⬆⬆⬆


-- #####################################################################
--  3-BOSQICH — KO'RISH.  Har `select` ni ALOHIDA belgilab RUN qiling.
-- #####################################################################

-- 3.1 Hozirgi filiallar: qaysilari Aros bilan bog'langan, qaysilari qo'lda
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
select a.code,
       a.name,
       a.subtitle,
       a.filial_ref,
       case when a.filial_ref is null then 'qo''lda (xarajat)' else 'Aros sinxroni' end as manba,
       a.is_active,
       (select count(*) from accounts c where c.parent_id = a.id and c.is_active) as bolalar
  from accounts a
 where a.kassa_turi = 'filial'
   and a.parent_id is null
 order by a.code;
-- ⬆⬆⬆  shu yergacha  ⬆⬆⬆

-- 3.2 Tanlagich nima ko'rsatadi (hodim / professional / standart aynan shuni oladi)
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
select * from v_filial_tanlov order by name;
-- ⬆⬆⬆  shu yergacha  ⬆⬆⬆

-- 3.3 Test filialdan iz qolmaganini tekshirish — natija BO'SH bo'lishi kerak.
--     (Qator chiqsa: 2.8 TOZALASH bajarilmagan, yoki eski versiya bilan
--      RUN qilingan test is_active=false bo'lib qolgan. Yechim: 2.8 ni
--      RUN qiling — u ROLLBACK (b) bilan bir xil ishni bajaradi.)
-- ⬇⬇⬇  ALOHIDA belgilab RUN qiling  ⬇⬇⬇
select code, name, is_active from accounts where name ilike 'ZZ Test filial%';
-- ⬆⬆⬆  shu yergacha  ⬆⬆⬆


-- #####################################################################
--  ROLLBACK (kerak bo'lsa — izohni oching)
-- #####################################################################
--
-- (a) Faqat funksiyalarni olib tashlash (yaratilgan filiallar QOLADI):
--        drop function if exists xarajat_filial_yarat(text, text);
--        drop function if exists xarajat_filial_ochir(uuid);
--        notify pgrst, 'reload schema';
--
-- (b) Test filialini butunlay yo'qotish. 2-BOSQICH buni ENDI O'ZI qiladi —
--     bu satr faqat faylning eski versiyasi bilan RUN qilingan va
--     is_active=false bo'lib qolgan test filiallarni tozalash uchun
--     (o'sha 52xx kodlari bo'shaydi). Yozuvi yo'q bo'lgani uchun xavfsiz:
--        delete from accounts where name ilike 'ZZ Test filial%' and filial_ref is null;
--
-- (c) Qo'lda qo'shilgan biror filialni qaytarish (passiv -> faol):
--        update accounts set is_active = true where code = '52XX';
--
-- ⚠️ v_filial_tanlov, v_kassa_card, v_filial_sync_mapping va boshqa
--    view/funksiyalar bu faylda UMUMAN o'zgartirilmagan — ularni qaytarish
--    kerak emas.
