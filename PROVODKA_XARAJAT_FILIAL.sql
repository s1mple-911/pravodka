-- =====================================================================
--  ⚠️⚠️  SUPABASE SQL EDITOR — QANDAY RUN QILINADI (avval SHUNI o'qing)
-- ---------------------------------------------------------------------
--   1) Tartib: 0-BOSQICH (tekshiruv) → 1-BOSQICH (funksiyalar) →
--      2-BOSQICH (o'z-o'zini test) → 3-BOSQICH (ko'rish). Butun faylni
--      birdaniga RUN QILMANG.
--   2) Har bo'lak ⬇⬇⬇ va ⬆⬆⬆ belgilari orasida — AYNAN o'sha oraliqni
--      belgilab RUN qiling.
--   3) `do $$` va `as $$` bloklarini TO'LIQ belgilash SHART: `do $$`
--      (yoki `create or replace function`) qatoridan `$$;` qatorigacha,
--      ikkalasi ham ichida. Yarim belgilansa Postgres blokni PL/pgSQL emas,
--      oddiy SQL deb o'qiydi va o'zgaruvchini jadval deb izlaydi.
--   4) O'shanda chiqadigan xato — `ERROR: 42P01: relation "v_yoq" does not
--      exist` (yoki boshqa `v_...` nomi). Bu FAYL XATOSI EMAS, belgilash
--      noto'g'ri: blokni boshidan oxirigacha qayta belgilab RUN qiling.
--   5) Faylda NOMLANGAN dollar-teg (dollar + nom + dollar ko'rinishi) YO'Q —
--      faqat oddiy `$$`. Ichma-ich dollar-quote ham yo'q.
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
-- ⬇⬇⬇  1.1: SHU QATORDAN pastdagi `$$;` QATORIGACHA (ikkalasi ham ichida) BELGILANG  ⬇⬇⬇
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
-- ⬆⬆⬆  1.1 shu yergacha (`$$;` ham ichida)  ⬆⬆⬆

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
-- ⬇⬇⬇  1.2: SHU QATORDAN pastdagi `$$;` QATORIGACHA (ikkalasi ham ichida) BELGILANG  ⬇⬇⬇
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
-- ⬆⬆⬆  1.2 shu yergacha (`$$;` ham ichida)  ⬆⬆⬆

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
--  ALOHIDA belgilab RUN qiling. Test filial oxirida jadvaldan BUTUNLAY
--  o'chiriladi — 52xx kodi bo'shab qoladi (har RUN da bittadan yeyilmasin).
-- #####################################################################

-- ⚠️ Belgilashni AYNAN quyidagi `do $$` qatoridan boshlang va pastdagi `$$;`
--    qatorigacha (u ham ichida) belgilang. `do $$` yoki `declare` tashqarida
--    qolsa: ERROR 42P01 relation "v_nom" does not exist — bu fayl xatosi emas.
-- ⬇⬇⬇⬇⬇⬇⬇⬇⬇  `do $$` QATORIDAN `$$;` QATORIGACHA BELGILANG  ⬇⬇⬇⬇⬇⬇⬇⬇⬇
do $$
declare
  v_nom  text := 'ZZ Test filial (o''chiriladi)';
  v_r    jsonb;
  v_r2   jsonb;
  v_id   uuid;
  v_n    int;
begin
  -- (a) yaratish
  v_r  := xarajat_filial_yarat(v_nom, 'Test · Xarajat');
  v_id := (v_r->>'id')::uuid;
  if (v_r->>'ok') <> 'true' or v_id is null then
    raise exception 'TEST 1 XATO: yaratilmadi — %', v_r;
  end if;
  if (v_r->>'yangi') <> 'true' then
    raise exception 'TEST 1 XATO: yangi=false, oldin qolib ketgan test filial bormi? — %', v_r;
  end if;
  raise notice 'TEST 1 OK: % ochildi (%)', v_r->>'code', v_r->>'name';

  -- (b) idempotentlik: ikkinchi chaqiruv YANGI ochmasin
  v_r2 := xarajat_filial_yarat(lower(v_nom), null);
  if (v_r2->>'yangi') <> 'false' or (v_r2->>'id') <> (v_r->>'id') then
    raise exception 'TEST 2 XATO: idempotent emas — %', v_r2;
  end if;
  raise notice 'TEST 2 OK: idempotent (yangi=false)';

  -- (c) v_filial_tanlov ko'rdimi (view o'zgartirilmagani shu bilan tasdiqlanadi)
  select count(*) into v_n from v_filial_tanlov where id = v_id;
  if v_n <> 1 then
    raise exception 'TEST 3 XATO: v_filial_tanlov da % qator (1 kutilgandi) — view sharti mos kelmadi', v_n;
  end if;
  raise notice 'TEST 3 OK: v_filial_tanlov da ko''rinadi';

  -- (d) kassa kartasi buzilmadimi: yangi filial BITTA qator, jami = 0
  select count(*) into v_n from v_kassa_card where id = v_id;
  if v_n <> 1 then
    raise exception 'TEST 4 XATO: v_kassa_card da % qator (1 kutilgandi)', v_n;
  end if;
  select count(*) into v_n from v_kassa_card where id = v_id and jami = 0;
  if v_n <> 1 then
    raise exception 'TEST 4 XATO: yangi filialning jami qoldig''i 0 emas';
  end if;
  raise notice 'TEST 4 OK: v_kassa_card — 1 qator, jami = 0';

  -- (e) Aros sinxroni tegmasin: mapping'da umuman bo'lmasin
  select count(*) into v_n from v_filial_sync_mapping where kassa_id = v_id;
  if v_n <> 0 then
    raise exception 'TEST 5 XATO: v_filial_sync_mapping da % qator — Aros sinxroni bu filialga yozadi!', v_n;
  end if;
  raise notice 'TEST 5 OK: Aros sinxroni tegmaydi (filial_ref NULL)';

  -- (f) valyuta bolasi paydo bo'lmadimi (parent_id NULL — tushmasligi kerak)
  select count(*) into v_n from v_kassa_valyutalar where parent_id = v_id;
  if v_n <> 0 then
    raise exception 'TEST 6 XATO: v_kassa_valyutalar da % qator', v_n;
  end if;
  raise notice 'TEST 6 OK: valyuta bolasi yo''q';

  -- (g) o'chirish ishlaydimi
  v_r2 := xarajat_filial_ochir(v_id);
  if (v_r2->>'ok') <> 'true' then
    raise exception 'TEST 7 XATO: o''chirilmadi — %', v_r2;
  end if;
  select count(*) into v_n from v_filial_tanlov where id = v_id;
  if v_n <> 0 then
    raise exception 'TEST 7 XATO: o''chirilgandan keyin ham v_filial_tanlov da turibdi';
  end if;
  raise notice 'TEST 7 OK: passivlashtirildi, ro''yxatdan chiqdi';

  -- (h) TOZALASH: test filial `is_active=false` bo'lib qolsa 52xx kodi band
  --     bo'lib qoladi va bu blok har RUN da bittadan kod yeydi (5299 gacha
  --     97 ta joy bor). Shuning uchun butunlay o'chiramiz.
  --     XAVFSIZ: hisob shu blokda endigina yaratildi va yuqoridagi
  --     xarajat_filial_ochir() uning entry_line'i, entry.filial_ids tegi va
  --     standart_xarajat limiti YO'Qligini allaqachon tekshirdi (bo'lganida
  --     TEST 7 xato berardi). Ya'ni delete birorta yozuvni yetim qoldirmaydi.
  --     Bola-hisob nazariy jihatdan ham yo'q, lekin FK xatosi bo'lmasin uchun
  --     avval ular o'chiriladi.
  delete from accounts where parent_id = v_id;
  delete from accounts where id = v_id;

  select count(*) into v_n from accounts where id = v_id;
  if v_n <> 0 then
    raise exception 'TEST 8 XATO: test filial o''chmadi (% ta qator qoldi)', v_n;
  end if;
  raise notice 'TEST 8 OK: test filial butunlay o''chirildi — % kodi bo''shadi', v_r->>'code';

  raise notice '===== HAMMA TEST O''TDI. Test filial (%) jadvaldan o''chirildi, iz qolmadi. =====',
    v_r->>'code';
end
$$;
-- ⬆⬆⬆⬆⬆⬆⬆⬆⬆  SHU QATORGACHA (`$$;` ham ichida) BELGILANG (2-BOSQICH tugadi)  ⬆⬆⬆⬆⬆⬆⬆⬆⬆


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
--     (Qator chiqsa: bu faylning ESKI versiyasi bilan RUN qilingan test —
--      is_active=false bo'lib qolgan. Qo'lda o'chirish: ROLLBACK (b).)
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
