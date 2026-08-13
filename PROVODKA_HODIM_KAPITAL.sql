-- =====================================================================
--  ⚠️⚠️  SUPABASE SQL EDITOR — QANDAY RUN QILINADI (avval SHUNI o'qing)
-- ---------------------------------------------------------------------
--   1) Bu faylda `do` bloki UMUMAN YO'Q. Dollar-quote belgisi (ikki dollar
--      yonma-yon) FAQAT 2.0 dagi ikki funksiya tanasining boshi va oxirida —
--      izohlarda umuman yo'q. NOMLANGAN dollar-teg ham yo'q, ichma-ich
--      dollar-quote ham yo'q.
--      Sabab: Supabase SQL Editor `do` blokini bo'lib yuborar va PL/pgSQL
--      o'zgaruvchisini jadval deb izlar edi
--      (`ERROR: 42P01: relation "v_kap_code" does not exist`). Shuning uchun
--      MANTIQ O'ZGARMAGAN holda funksiyaga qayta qadoqlandi —
--      `create or replace function ... as` esa muammosiz ishlaydi.
--
--   2) Tartib:
--        1-BOSQICH  — reja jadvali + PREVIEW (pul yozmaydi)
--        2.0        — funksiyani yaratish (DDL, pul yozmaydi)
--        2.1        — MAJBURIY DRY-RUN (bajaradi va darrov orqaga qaytaradi)
--        2.2        — 🔴 YOZISH (haqiqiy pul)
--        3-BOSQICH  — natija ko'rinishi
--      BUTUN FAYLNI BIRDANIGA RUN QILMANG — 2.2 haqiqiy pul yozadi.
--
--   3) Har bo'lak ⬇⬇⬇ va ⬆⬆⬆ belgilari orasida — AYNAN o'sha oraliqni
--      belgilab RUN qiling. Bitta `select` = bitta tranzaksiya: funksiya
--      ichida xato chiqsa Postgres hammasini orqaga qaytaradi (yarim
--      yozilgan holat bo'lmaydi).
--
--   4) ♻️ YANGI HODIMLAR UCHUN QAYTA ISHLATISH: faqat 1.2 dagi `insert`
--      qatorlarini yangilang (kassa kodi + summa) va 1.1+1.2 ni RUN qiling,
--      keyin 1.3 PREVIEW → 2.1 DRY-RUN → 2.2 YOZISH. 2.0 funksiyasi
--      o'zgarmaydi — u bir marta yaratilgani yetadi. Avval pul olgan
--      kassalar `ext_ref` tufayli ikkinchi marta yozilmaydi (o'tkazib
--      yuboriladi), shuning uchun eski qatorlarni ro'yxatda qoldirsa ham
--      bo'ladi.
-- =====================================================================

-- =====================================================================
--  PROVODKA_HODIM_KAPITAL.sql   (KOD BO'YICHA — nom qidiruvi YO'Q)
--  Hodim kassalariga boshlang'ich kapital sifatida NAQD pul kirim qilish.
--      Dt <hodim kassasi · Naqd>  /  Kt <Boshlang'ich kapital (87xx)>
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  20 ta kassa: 5405 – 5424.  JAMI: 29 949 000 so'm.
--
--  🔴 RESET YO'Q — eski qoldiq ustiga QO'SHILADI (naqd_keyin = eski + reja).
--  🔴 Kassa FAQAT `code` bo'yicha topiladi. Nom bilan qidirish OLIB TASHLANDI.
--     `kutilgan_nom` faqat ko'z bilan tekshirish uchun (preview'da bazadagi
--     nom bilan yonma-yon chiqadi; mos kelmasa ⚠️ belgisi).
--  🔴 Bu fayl PROVODKA_TURLAR_AVTO.sql dan OLDIN RUN qilingani ma'qul
--     (naqd bola-hisob kodlari uchun 4 xonali bloklarda hali joy bor).
--
--  IKKI BOSQICH — butun faylni birdaniga RUN QILMANG:
--     1-BOSQICH (jadval + reja + PREVIEW) pul yozmaydi.
--     2-BOSQICH: 2.0 funksiya (yozmaydi) → 2.1 dry-run (yozmaydi) →
--     2.2 haqiqiy pul yozadi — faqat preview toza bo'lsa.
--
--  NEGA KAPITAL, 9010 EMAS: bu pul TUSHUM emas, allaqachon ishlab topilgan.
--  Kt'ga 9010 yozilsa o'sha kunning P&L'i shishadi. Kapitalga yozilganda
--  AKTIV va KAPITAL birga o'sadi, P&L'ga umuman tegilmaydi.
--
--  HAMMASI NAQD: pul kassaning `pul_turi='naqd'` bola-hisobiga tushadi,
--  ildiz hisobga EMAS (ildizda pul turmaydi — u konteyner).
--
--  IDEMPOTENT: har yozuv `ext_ref = 'bkap:hodim:<kassa_code>'`. Qayta RUN
--  qilinsa o'sha kassa o'tkazib yuboriladi (pul ikki marta yozilmaydi).
--
--  TALAB: PROVODKA_KAPITAL.sql (boshlangich_kapital_id), PROVODKA_VALYUTA.sql
--         (pul_turi_kod_blok) RUN qilingan bo'lsin.
--
--  ADDITIVE: mavjud jadval/ustun/funksiya/view o'zgartirilmaydi, `drop` yo'q.
--  Faqat ikki YANGI funksiya qo'shiladi (2.0): `hodim_kapital_ish()` va
--  `hodim_kapital_yoz(boolean)`. Eski `hodim_nom_norm()` / `hodim_kassa_top()`
--  bazada QOLADI, lekin bu fayl ularga umuman bog'lanmaydi.
-- =====================================================================


-- #####################################################################
--  1-BOSQICH — REJA + PREVIEW.  PUL YOZMAYDI.
-- #####################################################################

-- ---------------------------------------------------------------------
-- 1.1 REJA JADVALI — qayta yaratiladi
-- ---------------------------------------------------------------------
-- `hodim_kapital_reja` — SHU SKRIPTNING O'Z jadvali. Frontend, view, RPC yoki
-- boshqa .sql fayl unga murojaat qilmaydi, shuning uchun drop+create ADDITIVE
-- qoidasini buzmaydi (tuzilishi nom -> kod ga o'zgardi, eski ustunlar keraksiz).
--
-- ⬇⬇⬇  1.1 + 1.2: SHU QATORDAN 1.2 oxiridagi `('5424', ...);` GACHA BELGILANG  ⬇⬇⬇
--       (`do` bloki yo'q — oddiy DDL/DML, birdaniga RUN qilinadi)
drop table if exists hodim_kapital_reja;

create table hodim_kapital_reja (
  kassa_code   text    primary key,
  kutilgan_nom text,
  miqdor       numeric not null check (miqdor >= 0),
  faol         boolean not null default true
);

comment on table hodim_kapital_reja is
  'Hodim kassalariga boshlang''ich kapital rejasi (PROVODKA_HODIM_KAPITAL.sql). '
  'Kassa FAQAT kassa_code bo''yicha topiladi. miqdor — so''mda, hammasi NAQD. '
  'faol=false qator yozilmaydi.';

comment on column hodim_kapital_reja.kutilgan_nom is
  'Faqat ko''z bilan tekshirish uchun — qidiruvda ISHLATILMAYDI.';

revoke all on hodim_kapital_reja from public, anon;
-- RLS yoqilgan, policy YO'Q -> anon/authenticated o'qiy olmaydi.
-- Egasi (postgres, SQL editor) RLS'dan o'tadi.
alter table hodim_kapital_reja enable row level security;


-- ---------------------------------------------------------------------
-- 1.2 ⚙️⚙️ RAQAMLAR — FAQAT SHU BLOKNI TAHRIRLANG
-- ---------------------------------------------------------------------
-- Hammasi so'mda, hammasi NAQD.
-- Qatorni O'CHIRMANG — kerak bo'lmasa faol=false qiling:
--     update hodim_kapital_reja set faol = false where kassa_code = '5412';
insert into hodim_kapital_reja (kassa_code, kutilgan_nom, miqdor) values
  ('5405', 'Abrorxo''ja Ahmadov',      32000),
  ('5406', 'Alisher Ruyiddinov',     1600000),
  ('5407', 'Sardor Bahodirov',        868000),
  ('5408', 'Qilichov Sardor',        1056000),
  ('5409', 'Ozodbek Abduhomidov',     238000),
  ('5410', 'Samariddin Mirxoliqov',  1017000),
  ('5411', 'Shahboz Xoliyorov',       732000),
  ('5412', 'Shovkatbek Fayziyev',      30000),
  ('5413', 'Saidov Nuriddin',        2169000),
  ('5414', 'Abdujalil',              3766000),
  ('5415', 'Giyos',                  2472000),
  ('5416', 'Umidjon Meyliyev',       7070000),
  ('5417', 'Choriyev Diyorbek',       148000),
  ('5418', 'Ilyos HRM',              1627000),
  ('5419', 'Asilbek Aliyorov',        470000),
  ('5420', 'Rovshanbek Aliyorov',    2015000),
  ('5421', 'ural maximum',            392000),
  ('5422', 'Xudoberdi',              1317000),
  ('5423', 'Sherdil Saidov',         1210000),
  ('5424', 'Tojiddin',               1720000);
-- ⬆⬆⬆  1.1 + 1.2 shu yergacha  ⬆⬆⬆
-- JAMI: 20 qator, 29 949 000 so'm.


-- ---------------------------------------------------------------------
-- 1.3 👀 PREVIEW — ASILBEK SHUNI TEKSHIRSIN
-- ---------------------------------------------------------------------
--  ⛔ `kassa_topildi` ustunida ❌ bo'lsa — 2-BOSQICHNI RUN QILMANG
--     (2-bosqich baribir xato beradi va hammasi orqaga qaytadi, lekin
--      avval sababini toping: kod noto'g'ri yoki kassa shartga mos emas).
--  ⚠️ `nom_mos` ustunida ⚠️ FARQ bo'lsa — ham TO'XTANG va tekshiring:
--     kod boshqa odamning kassasiga tushib qolgan bo'lishi mumkin.
--     Nom haqiqatan boshqacha yozilgan bo'lsa (imlo), davom etsa bo'ladi.
--
--  Ustunlar:
--    naqd_qoldiq_hozir — FAQAT naqd bola-hisobi (pul aynan shu yerga tushadi)
--    jami_qoldiq_hozir — ildiz hisob + HAMMA bolalari (kassa.html kartasidagi
--                        `jami`). Ikkisi teng bo'lmasligi NORMAL.
--    naqd_keyin        — naqd_qoldiq_hozir + yoziladi (RESET YO'Q!)
--    avval_yozilgan    — ✔ bo'lsa 2-bosqich uni o'tkazib yuboradi
--    naqd_hisob_kod    — '(ochiladi)' bo'lsa muammo emas, 2-bosqich o'zi ochadi
--
--  Oxirgi qator — JAMI.
--
-- ⬇⬇⬇⬇⬇⬇⬇⬇⬇  SHU QATORDAN `;` BILAN TUGAGUNCHA BELGILANG  ⬇⬇⬇⬇⬇⬇⬇⬇⬇
with d as (
  select r.kassa_code,
         r.kutilgan_nom,
         r.miqdor,
         r.faol,
         a.id                                     as kassa_id,
         a.name                                   as bazadagi_nom,
         a.subtitle,
         -- kassa shartga mos keladimi (2-bosqich AYNAN shu shartni qo'yadi)
         (a.id is not null
          and a.section = 'pul'
          and a.is_active
          and a.pul_turi is null
          and coalesce(a.currency, 'UZS') = 'UZS'
          and exists (select 1 from accounts g
                       where g.id = a.parent_id
                         and g.kassa_turi = 'xarajat_guruh'))   as mos,
         exists (select 1 from entry e
                  where e.ext_ref = 'bkap:hodim:' || r.kassa_code) as bor,
         n.code                                   as naqd_code,
         coalesce(nb.uzs, 0)                      as naqd_qoldiq,
         coalesce(jb.uzs, 0)                      as jami_qoldiq
    from hodim_kapital_reja r
    left join accounts a on a.code = r.kassa_code
    left join lateral (
      select c.id, c.code
        from accounts c
       where c.parent_id = a.id and c.is_active
         and c.pul_turi = 'naqd'
         and coalesce(c.currency, 'UZS') = 'UZS'
       order by c.code limit 1
    ) n on true
    left join lateral (
      select coalesce(sum(l.debit - l.credit), 0) as uzs
        from entry_line l
        join entry e on e.id = l.entry_id
       where l.account_id = n.id
         and e.status = 'posted' and e.is_deleted = false
    ) nb on true
    -- Ildiz + HAMMA bolalari (valyuta bolasi tarixiy kursdagi so'm ekvivalenti
    -- bilan kiradi — v_kassa_card `jami` bilan bir xil qoida).
    left join lateral (
      select coalesce(sum(l.debit - l.credit), 0) as uzs
        from entry_line l
        join entry e on e.id = l.entry_id
        join accounts x on x.id = l.account_id
       where (x.id = a.id or x.parent_id = a.id)
         and e.status = 'posted' and e.is_deleted = false
    ) jb on true
),
p as (
  select d.*,
         case when d.faol and d.mos then d.miqdor else 0 end as yoziladi,
         -- avval yozilgan bo'lsa summa allaqachon qoldiqda bor
         case when d.faol and d.mos and not d.bor then d.miqdor else 0 end as qoshiladi,
         -- nomni solishtirish: kichik harf + apostrof variantlari + ortiqcha probel
         (regexp_replace(regexp_replace(lower(coalesce(d.kutilgan_nom, '')),
            '[''ʻʼ`´‘’]', '', 'g'), '\s+', ' ', 'g') =
          regexp_replace(regexp_replace(lower(coalesce(d.bazadagi_nom, '')),
            '[''ʻʼ`´‘’]', '', 'g'), '\s+', ' ', 'g'))                     as nom_teng
    from d
)
select kassa_code, kutilgan_nom, bazadagi_nom, nom_mos, subtitle,
       kassa_topildi, naqd_hisob_kod, avval_yozilgan,
       naqd_qoldiq_hozir, jami_qoldiq_hozir, yoziladi, naqd_keyin
  from (
    select 0                                        as srt,
           p.kassa_code,
           p.kutilgan_nom,
           coalesce(p.bazadagi_nom, '—')            as bazadagi_nom,
           case when p.bazadagi_nom is null then '—'
                when p.nom_teng then '✅'
                else '⚠️ FARQ' end                  as nom_mos,
           coalesce(p.subtitle, '—')                as subtitle,
           case when p.bazadagi_nom is null then '❌ YO''Q (kod topilmadi)'
                when not p.mos then '❌ SHART MOS EMAS'
                else '✅' end                       as kassa_topildi,
           coalesce(p.naqd_code, '(ochiladi)')      as naqd_hisob_kod,
           case when p.bor then '✔' else '—' end    as avval_yozilgan,
           p.naqd_qoldiq                            as naqd_qoldiq_hozir,
           p.jami_qoldiq                            as jami_qoldiq_hozir,
           p.yoziladi,
           p.naqd_qoldiq + p.qoshiladi              as naqd_keyin
      from p
    union all
    select 1,
           'JAMI',
           count(*)::text || ' qator',
           '—',
           '—',
           count(*) filter (where p.mos and p.faol)::text || ' ta tayyor',
           case when count(*) filter (where not p.mos and p.faol) > 0
                then '❌ ' || count(*) filter (where not p.mos and p.faol)::text || ' ta MUAMMO'
                else '✅ hammasi joyida' end,
           '—',
           count(*) filter (where p.bor)::text || ' ta',
           sum(p.naqd_qoldiq),
           sum(p.jami_qoldiq),
           sum(p.yoziladi),
           sum(p.naqd_qoldiq + p.qoshiladi)
      from p
  ) t
 order by t.srt, t.kassa_code;
-- ⬆⬆⬆⬆⬆⬆⬆⬆⬆  SHU QATORGACHA BELGILANG (1-BOSQICH tugadi)  ⬆⬆⬆⬆⬆⬆⬆⬆⬆


-- #####################################################################
--
--   ⛔⛔  FAQAT PREVIEW TEKSHIRILGANDAN KEYIN RUN QILING  ⛔⛔
--
--   Quyidagi 2-BOSQICH haqiqiy pul yozadi (29 949 000 so'm).
--   Hammasi BITTA tranzaksiya: biror joyda xato bo'lsa HAMMASI orqaga
--   qaytadi (yarim yozilgan holat bo'lmaydi).
--
-- #####################################################################

-- ---------------------------------------------------------------------
-- 2-BOSQICH — YOZISH: Dt hodim naqd / Kt Boshlang'ich kapital
-- ---------------------------------------------------------------------
--  Uch qadam:  2.0 funksiyalar (DDL — pul yozmaydi)
--           →  2.1 DRY-RUN  (bajaradi va DARROV orqaga qaytaradi)
--           →  2.2 YOZISH   (🔴 haqiqiy pul)
--
--  Avval bu mantiq `do` blokida edi va Supabase SQL Editor uni bo'lib
--  yuborardi (`ERROR: 42P01: relation "v_kap_code" does not exist`).
--  Funksiya ichida esa xuddi shu mantiq muammosiz ishlaydi — shuning uchun
--  MANTIQ, SUMMALAR, TEKSHIRUVLAR va XATO MATNLARI o'zgarmagan holda
--  funksiyaga ko'chirildi. `raise exception` funksiya ichida ham butun
--  tranzaksiyani orqaga qaytaradi, ya'ni himoya kuchi bir xil.

-- ---------------------------------------------------------------------
-- 2.0 FUNKSIYALAR.  PUL YOZMAYDI — faqat funksiyani yaratadi.
-- ---------------------------------------------------------------------
--  Ikkita funksiya:
--    hodim_kapital_ish()                       -> jsonb   (butun mantiq)
--    hodim_kapital_yoz(p_dry_run boolean=true) -> jsonb   (chaqiruvchi)
--
--  hodim_kapital_yoz(true)   — ichki blokda hamma yozuv HAQIQATAN
--       bajariladi, 5 ta o'zini tekshiruv ishlaydi, so'ng blok o'zini
--       ORQAGA QAYTARADI: bazada iz qolmaydi. Javobda "dry_run": true.
--       Ya'ni bu "sanoq" emas — 2.2 ning aynan mashqi.
--  hodim_kapital_yoz(false)  — 🔴 haqiqiy yozuv.
--
--  Kirim / o'tkazib yuborish satrlari NOTICE bo'lib chiqadi (Supabase
--  natija panelidagi "Messages"/"Logs"), yakuniy hisobot esa jsonb.
--
--  ADDITIVE: ikki YANGI funksiya. Mavjud jadval/ustun/view/funksiya
--  o'zgartirilmaydi, `drop` yo'q.
--
-- ⬇⬇⬇⬇⬇⬇⬇⬇⬇  2.0: SHU QATORDAN pastdagi `comment on function
--            hodim_kapital_yoz...;` QATORIGACHA BELGILANG  ⬇⬇⬇⬇⬇⬇⬇⬇⬇
create or replace function hodim_kapital_ish()
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  -- ⚙️ Yozuv belgisi. ext_ref = '<batch>:<kassa_code>' -> takroriy RUN pulni
  --    ikki marta yozmaydi. Sanadan mustaqil. ROLLBACK ham shu belgi bo'yicha.
  v_batch  text := 'bkap:hodim';
  -- ⚙️ Yozuv sanasi. UZB vaqti (Supabase UTC'da yuradi — current_date emas).
  p_sana   date := (now() at time zone 'Asia/Tashkent')::date;

  v_kapital  uuid;
  v_kap_code text;
  v_source   text := 'boshlangich_kapital';

  r          record;
  v_soni     int;
  v_kassa    uuid;
  v_kod      text;
  v_nom      text;
  v_sub      text;
  v_turi     text;

  v_naqd     uuid;
  v_naqd_kod text;
  v_prefix   text;
  v_uzun     int;
  v_next     int;
  v_code     text;
  v_uzun_bor boolean;

  v_oldin    numeric;
  v_keyin    numeric;
  v_entry    uuid;
  v_ext      text;
  v_dt       numeric;
  v_kt       numeric;
  v_xato     int;
  v_farq     numeric;

  n_yozildi  int := 0;
  n_otkaz    int := 0;
  n_ochildi  int := 0;
  v_jami     numeric := 0;
  v_natija   jsonb;
begin
  -- ---- Kapital hisobi -----------------------------------------------
  v_kapital := boshlangich_kapital_id();
  if v_kapital is null then
    raise exception 'Boshlang''ich kapital hisobi topilmadi — PROVODKA_KAPITAL.sql RUN qilinganmi?';
  end if;
  select code into v_kap_code from accounts where id = v_kapital;

  -- ---- `source` ustunida cheklov bormi -------------------------------
  -- Bazada entry.source ga check constraint qo'yilgan bo'lsa, notanish qiymat
  -- butun tranzaksiyani yiqitadi. Shu holatda xavfsiz 'manual' ga tushamiz —
  -- yozuvni baribir created_by va ext_ref belgilaydi.
  if exists (select 1 from pg_constraint c
              where c.conrelid = 'public.entry'::regclass
                and c.contype = 'c'
                and pg_get_constraintdef(c.oid) ilike '%source%') then
    v_source := 'manual';
    raise notice 'DIQQAT: entry.source da cheklov bor -> source = ''manual'' ishlatiladi';
  end if;

  raise notice 'Kapital hisob: % (%) | sana: % | belgi: %',
    v_kap_code, v_kapital, p_sana, v_batch;

  -- ---- Har kassa uchun ------------------------------------------------
  for r in
    select kassa_code, kutilgan_nom, miqdor
      from hodim_kapital_reja
     where faol and miqdor > 0
     order by kassa_code
  loop
    -- 2.1 Kassani KOD bo'yicha topish. Shartlar preview bilan AYNAN bir xil:
    --     section='pul', is_active, pul_turi is null (ildiz hisob),
    --     currency='UZS', otasi kassa_turi='xarajat_guruh' (5400).
    select count(*) into v_soni
      from accounts a
      join accounts g on g.id = a.parent_id and g.kassa_turi = 'xarajat_guruh'
     where a.code = r.kassa_code
       and a.section = 'pul'
       and a.is_active
       and a.pul_turi is null
       and coalesce(a.currency, 'UZS') = 'UZS';

    if v_soni <> 1 then
      -- ⚠️ raise format satri BITTA literal bo'lishi SHART (yonma-yon 'a' 'b'
      --    PL/pgSQL'da syntax error beradi). Uzun tushuntirish -> USING HINT.
      raise exception 'Kassa % ("%") — % ta mos hisob topildi (aniq 1 ta kerak). HAMMASI BEKOR QILINDI.',
        r.kassa_code, coalesce(r.kutilgan_nom, '?'), v_soni
        using hint = 'Talab: section=pul, is_active, pul_turi is null, currency=UZS, otasi kassa_turi=xarajat_guruh. 1-BOSQICH preview dagi kassa_topildi ustunini tekshiring.';
    end if;

    select a.id, a.code, a.name, a.subtitle, a.kassa_turi
      into v_kassa, v_kod, v_nom, v_sub, v_turi
      from accounts a
      join accounts g on g.id = a.parent_id and g.kassa_turi = 'xarajat_guruh'
     where a.code = r.kassa_code
       and a.section = 'pul'
       and a.is_active
       and a.pul_turi is null
       and coalesce(a.currency, 'UZS') = 'UZS';

    -- 2.2 Allaqachon yozilganmi (takroriy RUN himoyasi)
    v_ext := v_batch || ':' || v_kod;
    if exists (select 1 from entry where ext_ref = v_ext) then
      n_otkaz := n_otkaz + 1;
      raise notice '  o''tkazildi  % — % (avval yozilgan)', v_kod, v_nom;
      continue;
    end if;

    -- 2.3 Naqd bola-hisobi — yo'q bo'lsa ochamiz.
    -- create_pul_turi_child() CHAQIRILMAYDI: u auth.uid() orqali adminlikni
    -- tekshiradi, SQL editorda esa u NULL. Kod ajratish mantig'i o'sha
    -- funksiyadan (PROVODKA_VALYUTA.sql) ko'chirilgan.
    v_naqd := null;
    select a.id, a.code into v_naqd, v_naqd_kod
      from accounts a
     where a.parent_id = v_kassa and a.is_active
       and a.pul_turi = 'naqd'
       and coalesce(a.currency, 'UZS') = 'UZS'
     order by a.code limit 1;

    if v_naqd is null then
      -- Bo'sh joyi bor birinchi blok (nav tartibida). Har aylanishda qayta
      -- hisoblanadi — shu tranzaksiyada yangi qo'shilgan kodlar ham ko'rinadi.
      --
      -- ⚠️ FAYLLAR TARTIBI: bu fayl PROVODKA_TURLAR_AVTO.sql dan OLDIN RUN
      --    qilinishi ko'zda tutilgan. TURLAR_AVTO `pul_turi_kod_blok` ga
      --    `raqam_uzunlik` ustunini qo'shadi va 5 xonali bloklarni ochadi.
      --    Shuning uchun MOSLASHUV:
      --      • ustun BOR   -> blokning o'z uzunligi (5 xonali ham) ishlatiladi;
      --      • ustun YO'Q  -> eski 2 raqamli mantiq (o'zgarishsiz).
      --    Ustunga statik havola qilinmaydi (ustun yo'q bazada butun blok parse
      --    xatosi berardi) — shuning uchun dinamik `execute`.
      --    ⚠️ So'rov matni ODDIY BIR TIRNOQLI satr (ichma-ich dollar-quote
      --    YO'Q, aks holda funksiya tanasi vaqtidan oldin yopilardi).
      --    Shuning uchun ichkaridagi har `'` ikkilangan: '^' -> ''^''.
      v_prefix := null;
      v_uzun   := 2;

      select exists (select 1 from information_schema.columns
                      where table_schema = 'public'
                        and table_name  = 'pul_turi_kod_blok'
                        and column_name = 'raqam_uzunlik')
        into v_uzun_bor;

      if v_uzun_bor then
        execute '
          select b.prefix, b.raqam_uzunlik, coalesce(mx.n, 0) + 1
            from pul_turi_kod_blok b
            left join lateral (
              select max(substring(a.code from 3)::int) as n
                from accounts a
               where a.code ~ (''^'' || b.prefix || ''[0-9]{'' || b.raqam_uzunlik::text || ''}$'')
            ) mx on true
           where coalesce(mx.n, 0) + 1 <= (power(10, b.raqam_uzunlik)::int - 1)
           order by b.nav
           limit 1'
        into v_prefix, v_uzun, v_next;
      else
        select b.prefix, 2, coalesce(mx.n, 0) + 1
          into v_prefix, v_uzun, v_next
          from pul_turi_kod_blok b
          left join lateral (
            select max(substring(a.code from 3 for 2)::int) as n
              from accounts a where a.code ~ ('^' || b.prefix || '[0-9]{2}$')
          ) mx on true
         where coalesce(mx.n, 0) + 1 <= 99
         order by b.nav
         limit 1;
      end if;

      if v_prefix is null then
        raise exception 'Tur kod bloklari to''ldi (% kassada to''xtadi).', v_kod
          using hint = 'pul_turi_kod_blok ga yangi prefiks qo''shing yoki PROVODKA_TURLAR_AVTO.sql ni RUN qiling (u raqam_uzunlik ustunini qo''shib 5 xonali bloklarni ochadi).';
      end if;

      v_code := v_prefix || lpad(v_next::text, v_uzun, '0');

      insert into accounts(code, name, type, section, currency, parent_id,
                           kassa_turi, is_active, subtitle, pul_turi)
      values (v_code, v_nom || ' · Naqd', 'aktiv', 'pul', 'UZS', v_kassa,
              v_turi, true, v_sub, 'naqd')
      returning id, code into v_naqd, v_naqd_kod;

      n_ochildi := n_ochildi + 1;
      raise notice '  HISOB OCHILDI: %  % · Naqd', v_naqd_kod, v_nom;
    end if;

    -- 2.4 Yozuvdan OLDINGI naqd qoldiq (RESET YO'Q — ustiga qo'shiladi)
    select coalesce(sum(l.debit - l.credit), 0)
      into v_oldin
      from entry_line l
      join entry e on e.id = l.entry_id
     where l.account_id = v_naqd
       and e.status = 'posted' and e.is_deleted = false;

    -- 2.5 Yozuv: Dt naqd hisob / Kt boshlang'ich kapital
    insert into entry(entry_date, description, source, status, created_by, ext_ref)
    values (p_sana,
            'Boshlang''ich kapital — ' || v_nom,
            v_source, 'posted', 'boshlangich_kapital', v_ext)
    returning id into v_entry;

    insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
    values (v_entry, v_naqd, r.miqdor, 0, null);

    insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
    values (v_entry, v_kapital, 0, r.miqdor, null);

    -- check_entry_balanced DEFERRED — u COMMIT paytida ishlaydi va o'sha yerdagi
    -- xato tushunarsiz bo'ladi, shuning uchun o'zimiz darrov tekshiramiz.
    select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
      into v_dt, v_kt from entry_line where entry_id = v_entry;
    if v_dt <> v_kt then
      raise exception 'Yozuv muvozanatda emas: Dt=% Kt=% (% — %)', v_dt, v_kt, v_kod, v_nom;
    end if;

    -- (a) TEKSHIRUV: naqd qoldiq = eski + reja
    select coalesce(sum(l.debit - l.credit), 0)
      into v_keyin
      from entry_line l
      join entry e on e.id = l.entry_id
     where l.account_id = v_naqd
       and e.status = 'posted' and e.is_deleted = false;

    if v_keyin <> v_oldin + r.miqdor then
      raise exception 'TEKSHIRUV XATO (%): naqd qoldiq % bo''ldi, % kutilgan edi — hammasi bekor qilindi.',
        v_kod, v_keyin, v_oldin + r.miqdor;
    end if;

    n_yozildi := n_yozildi + 1;
    v_jami    := v_jami + r.miqdor;
    raise notice '  kirim  %  %  %  +% so''m  (oldin: %, keyin: %)',
      v_kod, v_naqd_kod, v_nom, r.miqdor, v_oldin, v_keyin;
  end loop;

  if n_yozildi = 0 and n_otkaz = 0 then
    raise exception 'TO''XTADI: birorta faol qator yo''q — reja bo''shmi?';
  end if;

  -- ---- O'Z-O'ZINI TEKSHIRISH -----------------------------------------
  -- Bu yerdan chiqadigan har qanday xato BUTUN skriptni orqaga qaytaradi.

  -- (b) Har yozuvda aniq 2 satr va Dt = Kt
  select count(*) into v_xato
    from entry e
    join lateral (
      select count(*) as n, coalesce(sum(l.debit), 0) as dt,
             coalesce(sum(l.credit), 0) as kt
        from entry_line l where l.entry_id = e.id
    ) s on true
   where e.ext_ref like v_batch || ':%'
     and (s.n <> 2 or s.dt <> s.kt);

  if v_xato > 0 then
    raise exception 'TEKSHIRUV XATO: % ta yozuv noto''g''ri tuzilgan (satr soni yoki Dt<>Kt)', v_xato;
  end if;

  -- (c) P&L'ga tegmadimi — daromad/xarajat satri bo'lmasligi SHART
  select count(*) into v_xato
    from entry e
    join entry_line l on l.entry_id = e.id
    join accounts a on a.id = l.account_id
   where e.ext_ref like v_batch || ':%'
     and a.type in ('daromad', 'xarajat');

  if v_xato > 0 then
    raise exception 'TEKSHIRUV XATO: % ta satr daromad/xarajat hisobiga tushib qolgan (P&L shishadi)', v_xato;
  end if;

  -- (d) Kapital hisobiga tushgan Kt summasi shu RUN'da yozilganga tengmi
  --     (n_otkaz > 0 bo'lsa ext_ref bo'yicha summa avvalgi RUN'larni ham
  --      qamraydi — u holda bu tekshiruv o'tkazib yuboriladi.)
  select coalesce(sum(l.credit), 0) - coalesce(sum(l.debit), 0)
    into v_farq
    from entry e
    join entry_line l on l.entry_id = e.id
   where e.ext_ref like v_batch || ':%'
     and l.account_id = v_kapital;

  if n_otkaz = 0 and v_farq <> v_jami then
    raise exception 'TEKSHIRUV XATO: kapitalga % yozildi, reja bo''yicha % kutilgan edi', v_farq, v_jami;
  end if;

  -- (e) Balans tenglikda qoldimi (AKTIV = PASSIV + KAPITAL)
  select coalesce(sum(case when bolim = 'AKTIV' then amount else 0 end)
                - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end), 0)
    into v_farq
    from balans(p_sana);

  if v_farq <> 0 then
    raise exception 'TEKSHIRUV XATO: balans tenglikda emas, farq = % — hammasi bekor qilindi.', v_farq;
  end if;

  raise notice '--- ✅ TUGADI: % ta yozuv | % ta o''tkazib yuborildi | % ta naqd hisob ochildi | jami % so''m | balans farqi 0',
    n_yozildi, n_otkaz, n_ochildi, v_jami;

  -- Yakuniy hisobot (NOTICE lar bilan bir xil raqamlar, jsonb ko'rinishida)
  v_natija := jsonb_build_object(
    'ok',            true,
    'yozildi',       n_yozildi,
    'otkazildi',     n_otkaz,
    'hisob_ochildi', n_ochildi,
    'jami_som',      v_jami,
    'kapital_hisob', v_kap_code,
    'sana',          p_sana,
    'belgi',         v_batch,
    'balans_farqi',  v_farq);

  return v_natija;
end
$$;

-- ---------------------------------------------------------------------
-- 2.0.b Chaqiruvchi — DRY-RUN shu yerda hal qilinadi
-- ---------------------------------------------------------------------
-- Ichki `begin ... exception ... end` = SUBTRANZAKSIYA: ichida yozilgan
-- hamma narsa xato ushlanganda bekor bo'ladi. Dry-run uchun ataylab
-- 'DRYRN' kodli xato ko'tariladi va o'sha yerda ushlanadi -> hamma yozuv
-- orqaga qaytadi, natija esa DETAIL orqali qo'ldan-qo'lga o'tadi.
-- Boshqa har qanday xato (tekshiruv, Dt<>Kt, kassa topilmadi...) ushlanmaydi
-- — u yuqoriga chiqadi va butun tranzaksiyani orqaga qaytaradi.
create or replace function hodim_kapital_yoz(p_dry_run boolean default true)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_natija jsonb;
  v_detail text;
begin
  begin
    v_natija := hodim_kapital_ish() || jsonb_build_object('dry_run', p_dry_run);

    if p_dry_run then
      raise exception using errcode = 'DRYRN',
        message = 'DRY-RUN — hech narsa yozilmadi',
        detail  = v_natija::text;
    end if;

    v_natija := v_natija || jsonb_build_object(
      'izoh', 'YOZILDI — haqiqiy pul. 3-BOSQICH bilan tekshiring.');
  exception when sqlstate 'DRYRN' then
    get stacked diagnostics v_detail = pg_exception_detail;
    v_natija := (v_detail::jsonb) || jsonb_build_object(
      'izoh', 'DRY-RUN: hammasi bajarildi va ORQAGA QAYTARILDI — bazada iz yo''q');
  end;

  return v_natija;
end
$$;

revoke all on function hodim_kapital_ish() from public, anon;
revoke all on function hodim_kapital_yoz(boolean) from public, anon;

comment on function hodim_kapital_ish() is
  'Hodim kassalariga boshlang''ich kapital yozadi (Dt hodim naqd / Kt 87xx), '
  'reja: hodim_kapital_reja. To''g''ridan chaqirmang — hodim_kapital_yoz() orqali. '
  'PROVODKA_HODIM_KAPITAL.sql.';

comment on function hodim_kapital_yoz(boolean) is
  'hodim_kapital_ish() chaqiruvchisi. p_dry_run=true -> hammasi bajariladi va '
  'orqaga qaytariladi (bazada iz yo''q), false -> haqiqiy yozuv. '
  'Idempotent: ext_ref = bkap:hodim:<kassa_code>.';
-- ⬆⬆⬆⬆⬆⬆⬆⬆⬆  2.0 SHU QATORGACHA BELGILANG (funksiyalar tayyor)  ⬆⬆⬆⬆⬆⬆⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.1 ⭐ MAJBURIY DRY-RUN — PUL YOZMAYDI (argument: true)
-- ---------------------------------------------------------------------
--  Nima bo'ladi: yozuvlar HAQIQATAN yoziladi, naqd bola-hisob kerak bo'lsa
--  ochiladi, 5 ta tekshiruv (Dt=Kt, qoldiq, P&L, kapital, balans) ishlaydi —
--  so'ng HAMMASI orqaga qaytariladi. Bazada iz qolmaydi.
--
--  Natijani o'qing:
--    • "dry_run": true          — ha, hech narsa yozilmadi
--    • "yozildi"                — 2.2 da nechta yozuv paydo bo'ladi
--    • "jami_som"               — 1.3 PREVIEW dagi JAMI `yoziladi` bilan MOS kelsin
--    • "otkazildi"              — avval yozilgan (ext_ref bor) kassalar
--    • "hisob_ochildi"          — nechta naqd bola-hisob ochiladi
--    • "balans_farqi": 0        — balans tenglikda qoladi
--  Xato chiqsa (masalan "Kassa 5412 ... 0 ta mos hisob topildi") — 2.2 NI
--  RUN QILMANG, avval sababini hal qiling.
--
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG (DRY-RUN — YOZMAYDI)  ⬇⬇⬇
select jsonb_pretty(hodim_kapital_yoz(true)) as dry_run_natija;
-- ⬆⬆⬆  2.1 DRY-RUN shu yerda tugadi  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.2 🔴🔴🔴 YOZISH — HAQIQIY PUL (argument: false)
-- ---------------------------------------------------------------------
--  Shartlar (hammasi bajarilsin):
--    • 1.3 PREVIEW da ❌ va ⚠️ FARQ yo'q
--    • 2.0 funksiyalar yaratilgan
--    • 2.1 DRY-RUN natijasi to'g'ri (yozildi / jami_som kutilgandek,
--      balans_farqi = 0)
--
--  Bitta `select` = bitta tranzaksiya. Funksiya ichida xato chiqsa
--  (Dt<>Kt, tekshiruv, unique ext_ref) — YOZILGAN HAMMA NARSA ORQAGA QAYTADI.
--
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG (YOZADI!)  ⬇⬇⬇
select jsonb_pretty(hodim_kapital_yoz(false)) as yozish_natijasi;
-- ⬆⬆⬆  2.2 YOZISH shu yerda tugadi  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 3-BOSQICH — NATIJA.  2-bosqich tugagach ALOHIDA belgilab RUN qiling.
-- ---------------------------------------------------------------------
-- `naqd_qoldiq` — faqat naqd hisob (yozuv shu yerga tushdi).
-- `jami_qoldiq` — ildiz + hamma bolalari (kassa.html kartasidagi raqam).
-- `yozilgan`    — shu skript yozgan summa (ext_ref bo'yicha; o'chirilgani hisobga olinmaydi).
--
-- ⬇⬇⬇  SHU QATORDAN pastdagi ` order by r.kassa_code;` GACHA BELGILANG  ⬇⬇⬇
select r.kassa_code,
       coalesce(a.name, '—')                as nom,
       coalesce(nb.uzs, 0)                  as naqd_qoldiq,
       coalesce(jb.uzs, 0)                  as jami_qoldiq,
       coalesce(w.summa, 0)                 as yozilgan,
       r.miqdor                             as reja
  from hodim_kapital_reja r
  left join accounts a on a.code = r.kassa_code
  left join lateral (
    select c.id from accounts c
     where c.parent_id = a.id and c.is_active and c.pul_turi = 'naqd'
       and coalesce(c.currency, 'UZS') = 'UZS'
     order by c.code limit 1
  ) n on true
  left join lateral (
    select coalesce(sum(l.debit - l.credit), 0) as uzs
      from entry_line l join entry e on e.id = l.entry_id
     where l.account_id = n.id
       and e.status = 'posted' and e.is_deleted = false
  ) nb on true
  left join lateral (
    select coalesce(sum(l.debit - l.credit), 0) as uzs
      from entry_line l
      join entry e on e.id = l.entry_id
      join accounts x on x.id = l.account_id
     where (x.id = a.id or x.parent_id = a.id)
       and e.status = 'posted' and e.is_deleted = false
  ) jb on true
  left join lateral (
    select coalesce(sum(l.debit), 0) as summa
      from entry e join entry_line l on l.entry_id = e.id
     where e.ext_ref = 'bkap:hodim:' || r.kassa_code
       and e.is_deleted = false
       and l.debit > 0
  ) w on true
 where r.faol
 order by r.kassa_code;
-- ⬆⬆⬆  3-BOSQICH shu yergacha  ⬆⬆⬆


-- =====================================================================
--  QO'SHIMCHA TEKSHIRUVLAR — kerak bo'lsa alohida RUN qiling
-- =====================================================================
-- Yaratilgan yozuvlar:
--   select e.ext_ref, e.entry_date, e.description, count(l.id) as satrlar,
--          sum(l.debit) as dt, sum(l.credit) as kt
--     from entry e join entry_line l on l.entry_id = e.id
--    where e.ext_ref like 'bkap:hodim:%'
--    group by e.id, e.ext_ref, e.entry_date, e.description
--    order by e.ext_ref;
--
-- Jami yozilgan summa (29 949 000 bo'lishi kerak):
--   select count(*) as yozuvlar, sum(l.debit) as jami_som
--     from entry e join entry_line l on l.entry_id = e.id
--     join accounts a on a.id = l.account_id
--    where e.ext_ref like 'bkap:hodim:%' and a.section = 'pul';
--
-- P&L'ga tegmadimi (BO'SH chiqishi SHART):
--   select e.ext_ref, a.code, a.name, a.type
--     from entry e join entry_line l on l.entry_id = e.id
--     join accounts a on a.id = l.account_id
--    where e.ext_ref like 'bkap:hodim:%' and a.type in ('daromad','xarajat');
--
-- Kartada qanday ko'rinadi:
--   select c.code, c.name, c.kassa_turi, c.uzs, c.jami
--     from v_kassa_card c
--    where c.code in (select kassa_code from hodim_kapital_reja)
--    order by c.code;
--
-- Kapital hisobining yangi qoldig'i:
--   select bolim, code, name, amount from balans(current_date)
--    where code = (select code from accounts where id = boshlangich_kapital_id());


-- =====================================================================
--  ROLLBACK — noto'g'ri summa yoki noto'g'ri kassaga yozilib qolsa
-- =====================================================================
-- Yozuvlar `ext_ref` = 'bkap:hodim:<kod>' bilan belgilangan — aniq topiladi,
-- boshqa hech narsaga tegmaydi.
--
-- A) HAMMASINI qaytarish (yumshoq — tarix saqlanadi, jurnalda usti chizilgan
--    holda qoladi, naqd qoldiq yozuvdan OLDINGI holatiga qaytadi):
--
--    update entry set is_deleted = true,
--                     deleted_at = now(),
--                     deleted_by_name = 'rollback: hodim boshlangich kapital'
--     where ext_ref like 'bkap:hodim:%' and is_deleted = false;
--
--    Qayta RUN qilish uchun ext_ref'ni bo'shatish SHART (unique to'siq, aks
--    holda skript "avval yozilgan" deb o'tkazib yuboradi):
--    update entry set ext_ref = ext_ref || ':bekor:' || id::text
--     where ext_ref like 'bkap:hodim:%' and is_deleted;
--
-- B) BITTA kassani qaytarish (5423 o'rniga kerakli kodni yozing):
--
--    update entry set is_deleted = true, deleted_at = now(),
--                     deleted_by_name = 'rollback: hodim boshlangich kapital'
--     where ext_ref = 'bkap:hodim:5423';
--    update entry set ext_ref = ext_ref || ':bekor:' || id::text
--     where ext_ref = 'bkap:hodim:5423' and is_deleted;
--    update hodim_kapital_reja set faol = false where kassa_code = '5423';
--
-- C) QATTIQ — butunlay o'chirish, izsiz. Faqat xato darrov sezilsa.
--    entry_line BITTA statement bilan o'chiriladi — deferred balans triggeri
--    COMMIT paytida 0=0 ko'radi va to'smaydi.
--
--    delete from entry_line where entry_id in (select id from entry where ext_ref like 'bkap:hodim:%');
--    delete from entry where ext_ref like 'bkap:hodim:%';
--
-- Ochilgan naqd bola-hisoblar rollbackda TEGILMAYDI (bo'sh hisob, zarari yo'q,
-- hodim baribir xarajat kiritganda ular kerak bo'ladi).
-- Kerak bo'lsa: update accounts set is_active = false where code = '...';
--
-- Rollbackdan keyin qayta yozish: butun faylni emas — 1.3 PREVIEW →
-- 2.1 DRY-RUN → 2.2 YOZISH. 2.0 funksiyalari joyida turadi.
