-- =====================================================================
--  PROVODKA_HODIM_KAPITAL.sql
--  Hodim kassalariga boshlang'ich kapital sifatida NAQD pul kirim qilish.
--      Dt <hodim kassasi · Naqd>  /  Kt <Boshlang'ich kapital (87xx)>
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  ⚠️ BU SKRIPT IKKI BOSQICHLI — BUTUN FAYLNI BIRDANIGA RUN QILMANG.
--     1-BOSQICH (PREVIEW) hech qanday pul yozmaydi — faqat rejani tuzadi
--     va "qaysi nom qaysi kassaga tushdi" ni ko'rsatadi.
--     2-BOSQICH (YOZISH) ni FAQAT preview tekshirilgandan keyin RUN qiling.
--
--  NEGA IKKI BOSQICH: ro'yxatdagi 24 ta nomning 12 tasi — 6 juft, ular
--  bir xil summa bilan, faqat imlosi boshqacha yozilgan:
--      Sardor Bahodirov / Sardor Baxodirov            868 000
--      Samariddin Mirxoliqov / Samariddin           1 017 000
--      Qilichov Sardor / Sardor Klichov             1 056 000
--      Alisher Ruyiddinov / Alisher Ruitdinov       1 600 000
--      Ozodbek Abduhomidov / Ozodbek Abduhamidov      238 000
--      Shovkatbek Fayziyev / Shavkatbek Fayziyev       30 000
--  Agar bular BITTA odamning ikki hisobi bo'lsa (eskisi + yangisi), ikkalasiga
--  ham yozilsa pul IKKI BAROBAR bo'lib ketadi va uni faqat qo'lda tuzatish
--  mumkin. Shuning uchun qaror MASHINA emas, ODAM tomonidan qabul qilinadi.
--
--  🔴 IKKI BAROBAR YOZILISHIGA QARSHI AVTOMATIK HIMOYA YO'Q.
--     YAGONA HIMOYA — ASILBEKNING PREVIEW (1.6/1.7) QARORI.
--
--     (Avvalgi izohda "ikkala imlo bitta hisobga tushsa ext_ref to'sadi"
--      deyilgan edi — bu NOTO'G'RI, shuning uchun olib tashlandi.)
--     Sabab: `hodim_kassa_top()` NORMALLASHGAN NOM TENGLIGI bo'yicha
--     qidiradi, `hodim_nom_norm()` esa q/x/h harflariga TEGMAYDI (1.1 ga
--     qarang). Ya'ni "Bahodirov" va "Baxodirov" hech qachon bitta hisobga
--     tusha olmaydi — yo har biri o'z kassasini topadi (u holda ext_ref ham
--     boshqa: 'bkap:hodim:<kassa_code>'), yo biri umuman topilmaydi
--     (u holda 2-bosqich xato beradi va HAMMASI orqaga qaytadi).
--     Juftlik ikki alohida hisob bo'lsa PUL IKKI BAROBAR yoziladi va uni
--     faqat qo'lda (pastdagi ROLLBACK B) tuzatish mumkin.
--
--     `ext_ref` unique belgisi FAQAT bitta narsani kafolatlaydi: skript
--     QAYTA RUN qilinsa o'sha kassaga ikkinchi marta yozilmaydi
--     (takroriy RUN himoyasi). Juft-nom himoyasi emas.
--
--  NIMA QILADI (2-bosqich):
--    1) Har nom uchun ANIQ BITTA hodim kassasini topadi (ildiz hisob:
--       kassa_turi='xarajat', pul_turi is null, ota = 5400 konteyner).
--       0 yoki 2+ topilsa — raise exception, HAMMASI orqaga qaytadi.
--    2) Kassada `naqd` bola-hisobi bo'lmasa — ochadi (pul yozmasdan).
--    3) Har hodimga BITTA yozuv: Dt naqd bolasi / Kt Boshlang'ich kapital.
--    4) O'zini o'zi tekshiradi: qoldiq (eski + yangi) kutilganga tengmi,
--       balans tenglikda qoldimi, P&L'ga tegmadimi.
--
--  ⚠️ RESET YO'Q. PROVODKA_BOSHLANGICH_QOLDIQ.sql eski qoldiqni avval nolga
--     tushirardi — BU SKRIPT UNDAY QILMAYDI. Kassada allaqachon pul bo'lsa,
--     yangi summa USTIGA QO'SHILADI. Ya'ni yakuniy qoldiq = eski + reja.
--     Preview'da IKKI ustun bor: `oldin_qoldiq` (faqat NAQD bolasi — pul
--     aynan shu yerga tushadi) va `jami_hozir` (ildiz + hamma bolalar, ya'ni
--     kassa.html kartasidagi raqam). Ular teng bo'lmasligi normal.
--
--  NEGA 9010 (savdo tushumi) EMAS: bu pul TUSHUM emas, u allaqachon ishlab
--  topilgan. Kt tomoniga 9010 yozilsa o'sha kunning P&L'i shishadi. Kapitalga
--  yozilganda AKTIV va KAPITAL birga o'sadi, P&L'ga umuman tegmaydi.
--  Kapital hisobi: PROVODKA_KAPITAL.sql dagi `Boshlang'ich kapital` (odatda
--  8720, type='kapital'). Kodini qattiq yozmaymiz — boshlangich_kapital_id().
--
--  HAMMASI NAQD: pul hodim kassasining `pul_turi='naqd'` bola-hisobiga
--  tushadi, ildiz hisobning o'ziga EMAS (kassa modeli shunday: ildizda pul
--  turmaydi, u faqat konteyner; v_kassa_card `jami` ni bolalardan yig'adi).
--
--  IDEMPOTENT: har yozuv `ext_ref` = '<batch>:<kassa_code>' bilan belgilanadi.
--  Skript qayta RUN qilinsa o'sha kassa O'TKAZIB YUBORILADI (pul ikki marta
--  yozilmaydi). Ro'yxatga keyin yangi hodim qo'shilsa — faqat u yoziladi.
--
--  TALAB: PROVODKA_KAPITAL.sql, PROVODKA_VALYUTA.sql (pul_turi_kod_blok)
--         RUN qilingan bo'lsin.
--
--  ADDITIVE: birorta mavjud jadval/ustun/funksiya/view o'zgartirilmaydi va
--  o'chirilmaydi. Yangi: 2 ta yordamchi funksiya + 1 ta reja jadvali.
-- =====================================================================


-- #####################################################################
--  1-BOSQICH — PREVIEW.  PUL YOZMAYDI.
--
--  ⚠️⚠️ SUPABASE FAQAT OXIRGI STATEMENT NATIJASINI KO'RSATADI.
--     Agar 1.1–1.7 ni bir marta belgilab RUN qilsangiz, faqat 1.7 (c)
--     natijasini ko'rasiz — eng muhim 1.6 ro'yxati va 1.7 (a) "muammoli
--     qatorlar" KO'RINMAY QOLADI.
--
--     TO'G'RI TARTIB:
--       1-qadam: 1.1 dan 1.5 gacha (funksiyalar + jadval + reja + bog'lash)
--                — bir marta belgilab RUN qiling. Natija muhim emas.
--       2-qadam: 1.6 ni ALOHIDA belgilab RUN qiling  ← asosiy ro'yxat
--       3-qadam: 1.7 (a) ni ALOHIDA belgilab RUN qiling ← BO'SH bo'lishi kerak
--       4-qadam: 1.7 (b) ni ALOHIDA belgilab RUN qiling ← juftlar
--       5-qadam: 1.7 (c) ni ALOHIDA belgilab RUN qiling ← yakuniy summa
--     Rejaga o'zgartirish kiritsangiz (faol=false), 1.5 ni qayta RUN qilib
--     keyin 1.6/1.7 ga qayting.
-- #####################################################################

-- ---------------------------------------------------------------------
-- 1.1 hodim_nom_norm(text) — nomni solishtirishga tayyorlash
-- ---------------------------------------------------------------------
-- Faqat kichik harf + apostrof variantlari + ortiqcha bo'sh joy tozalanadi:
--   "Abrorxo'ja Ahmadov" / "Abrorxoʻja  Ahmadov" / "abrorxo’ja ahmadov"
--   -> hammasi "abrorxoja ahmadov"
--
-- ⚠️ ATAYLAB aros_nom_norm() ISHLATILMADI. U q->k, x->h qiladi, ya'ni
--    "Bahodirov" va "Baxodirov" ni BIR XIL deb ko'radi. Bu yerda esa aynan
--    teskarisi kerak: ular baza'da ikki alohida hisob bo'lishi mumkin va
--    skript ularni o'zi birlashtirib yubormasligi kerak — qarorni Asilbek
--    qabul qiladi (1.6 dagi "bir xil summa" ro'yxatiga qarang).
create or replace function hodim_nom_norm(p_nom text)
returns text
language sql
immutable
as $$
  select nullif(
           btrim(
             regexp_replace(
               regexp_replace(lower(coalesce(p_nom, '')), '[''ʻʼ`´‘’]', '', 'g'),
               '\s+', ' ', 'g')),
           '');
$$;

revoke all on function hodim_nom_norm(text) from public, anon;

comment on function hodim_nom_norm(text) is
  'Hodim ismini solishtirish uchun normallashtiradi: kichik harf, apostrof '
  'variantlari (''/ʻ/ʼ/’) olib tashlanadi, ketma-ket bo''sh joylar bittaga. '
  'q/x harflariga TEGMAYDI — Bahodirov va Baxodirov alohida qoladi.';


-- ---------------------------------------------------------------------
-- 1.2 hodim_kassa_top(text) — nom bo'yicha hodim kassasini qidirish
-- ---------------------------------------------------------------------
-- Qidiruv shartlari (preview va yozish AYNAN shu funksiyani ishlatadi —
-- shuning uchun ikkalasi hech qachon bir-biridan farq qilmaydi):
--   • section='pul', is_active
--   • kassa_turi='xarajat'  -> hodim kassasi (5401+)
--   • pul_turi is null      -> ILDIZ hisob; "... · Naqd/Click/Payme" TUSHMAYDI
--   • currency='UZS'        -> "... · USD" bola-hisobi TUSHMAYDI
--   • ota = kassa_turi='xarajat_guruh' (odatda 5400 "Hodim xarajat kassalari")
-- Bir nechta qator qaytishi MUMKIN — chaqiruvchi sonini o'zi tekshiradi.
create or replace function hodim_kassa_top(p_nom text)
returns table (kassa_id uuid, kassa_code text, kassa_nom text,
               kassa_sub text, kassa_tur text)
language sql
stable
as $$
  select a.id, a.code, a.name, a.subtitle, a.kassa_turi
    from accounts a
    join accounts g on g.id = a.parent_id
                   and g.kassa_turi = 'xarajat_guruh'
   where a.section = 'pul'
     and a.is_active
     and a.kassa_turi = 'xarajat'
     and a.pul_turi is null
     and coalesce(a.currency, 'UZS') = 'UZS'
     and hodim_nom_norm(a.name) = hodim_nom_norm(p_nom)
   order by a.code;
$$;

revoke all on function hodim_kassa_top(text) from public, anon;

comment on function hodim_kassa_top(text) is
  'Nom bo''yicha hodim kassasini (ildiz hisob) topadi. '
  'PROVODKA_HODIM_KAPITAL.sql uchun: preview ham, yozish ham shuni chaqiradi.';


-- ---------------------------------------------------------------------
-- 1.3 REJA JADVALI
-- ---------------------------------------------------------------------
create table if not exists hodim_kapital_reja (
  nom          text    not null primary key,
  miqdor       numeric not null default 0 check (miqdor >= 0),
  faol         boolean not null default true,
  izoh         text,
  -- pastdagilarni skript to'ldiradi, qo'lda tegmang:
  nechta       int,
  kassa_code   text,
  naqd_code    text,
  oldin_qoldiq numeric,
  jami_hozir   numeric,
  kutilgan     numeric,
  holat        text,
  entry_id     uuid
);

-- Jadval avvalgi RUN'dan qolgan bo'lsa — yetishmagan ustunlarni qo'shamiz
-- (ADDITIVE, bor ustunga tegilmaydi).
alter table hodim_kapital_reja add column if not exists nechta       int;
alter table hodim_kapital_reja add column if not exists kassa_code   text;
alter table hodim_kapital_reja add column if not exists naqd_code    text;
alter table hodim_kapital_reja add column if not exists oldin_qoldiq numeric;
alter table hodim_kapital_reja add column if not exists jami_hozir   numeric;
alter table hodim_kapital_reja add column if not exists kutilgan     numeric;
alter table hodim_kapital_reja add column if not exists holat        text;
alter table hodim_kapital_reja add column if not exists entry_id     uuid;
alter table hodim_kapital_reja add column if not exists faol         boolean not null default true;

comment on table hodim_kapital_reja is
  'Hodim kassalariga boshlang''ich kapital rejasi (PROVODKA_HODIM_KAPITAL.sql). '
  'miqdor — so''mda, hammasi NAQD. faol=false qator yozilmaydi.';

comment on column hodim_kapital_reja.oldin_qoldiq is
  'FAQAT naqd bola-hisobidagi qoldiq (pul shu yerga yoziladi). '
  'Ildizdagi yoki click/payme/USD bolasidagi pul BU YERGA KIRMAYDI — jami uchun jami_hozir ga qarang.';

comment on column hodim_kapital_reja.jami_hozir is
  'Kassaning JAMI puli: ildiz hisob + HAMMA bolalari (naqd/click/payme/valyuta). '
  'kassa.html kartasidagi `jami` bilan bir xil o''qiladi. Valyuta bolasi TARIXIY kursdagi '
  'so''m ekvivalenti bilan kiradi. Faqat ko''rsatkich — yozish mantig''iga ta''sir qilmaydi.';

revoke all on hodim_kapital_reja from public, anon;
-- RLS yoqilgan, policy YO'Q -> anon/authenticated o'qiy olmaydi.
-- Egasi (postgres, SQL editor) RLS'dan o'tadi, shuning uchun skript ishlaydi.
alter table hodim_kapital_reja enable row level security;


-- ---------------------------------------------------------------------
-- 1.4 ⚙️⚙️ RAQAMLAR — FAQAT SHU BLOKNI TAHRIRLANG
-- ---------------------------------------------------------------------
-- Hammasi so'mda, hammasi NAQD.
-- ⚠️ `faol` ustuni ATAYLAB YANGILANMAYDI (on conflict'da yo'q): siz
--    qatorni `faol=false` qilgan bo'lsangiz, preview qayta RUN qilinganda
--    u qayta yoqilmaydi.
--
-- 🔴 KERAKSIZ QATORNI `delete` QILMANG — faqat `faol = false`:
--       update hodim_kapital_reja set faol = false where nom = '...';
--    Sabab: quyidagi `insert ... on conflict (nom)` — o'chirilgan qator
--    endi mavjud emas, ya'ni konflikt bo'lmaydi va qator QAYTADAN
--    qo'shiladi, `faol` esa ustun DEFAULT'i (true) bilan TIRILADI.
--    Ya'ni delete + preview qayta RUN = o'sha hodim yana rejaga qaytadi.
insert into hodim_kapital_reja (nom, miqdor, izoh) values
  ('Abrorxo''ja Ahmadov',      32000, null),
  ('Alisher Ruyiddinov',     1600000, 'juft: Alisher Ruitdinov'),
  ('Sardor Bahodirov',        868000, 'juft: Sardor Baxodirov'),
  ('Qilichov Sardor',        1056000, 'juft: Sardor Klichov'),
  ('Ozodbek Abduhomidov',     238000, 'juft: Ozodbek Abduhamidov'),
  ('Samariddin Mirxoliqov',  1017000, 'juft: Samariddin'),
  ('Shahboz Xoliyorov',       732000, null),
  ('Shovkatbek Fayziyev',      30000, 'juft: Shavkatbek Fayziyev'),
  ('Choriyev Diyorbek',       148000, null),
  ('Abdujalil',              3766000, null),
  ('Shavkatbek Fayziyev',      30000, 'juft: Shovkatbek Fayziyev'),
  ('Sardor Baxodirov',        868000, 'juft: Sardor Bahodirov'),
  ('Asilbek Aliyorov',        470000, null),
  ('Giyos',                  2472000, null),
  ('Umidjon Meyliyev',       7070000, null),
  ('Saidov Nuriddin',        2169000, null),
  ('Rovshanbek Aliyorov',    2015000, null),
  ('Samariddin',             1017000, 'juft: Samariddin Mirxoliqov'),
  ('Sherdil Saidov',         1210000, null),
  ('Xudoberdi',              1317000, null),
  ('Ilyos HRM',              1627000, null),
  ('Sardor Klichov',         1056000, 'juft: Qilichov Sardor'),
  ('Alisher Ruitdinov',      1600000, 'juft: Alisher Ruyiddinov'),
  ('Ozodbek Abduhamidov',     238000, 'juft: Ozodbek Abduhomidov')
on conflict (nom) do update
   set miqdor = excluded.miqdor,
       izoh   = excluded.izoh;
-- Jami (24 qator, hammasi faol): 32 646 000 so'm
-- Agar 6 juftning har biridan bittasi o'chirilsa: 27 837 000 so'm


-- ---------------------------------------------------------------------
-- 1.5 Rejani hisoblar bilan bog'lash (faqat REJA jadvali yangilanadi)
-- ---------------------------------------------------------------------
-- Bu UPDATE `accounts` ga ham, `entry` ga ham TEGMAYDI — pul yozilmaydi.
--
-- IKKI XIL QOLDIQ HISOBLANADI, ikkalasi ham preview'da ko'rinadi:
--   • oldin_qoldiq — FAQAT `naqd` bola-hisobi (pul aynan shu yerga yoziladi,
--                    shuning uchun `kutilgan` ham shundan hisoblanadi);
--   • jami_hozir   — kassaning JAMI puli: ildiz + HAMMA bolalari
--                    (naqd/click/payme/valyuta). kassa.html kartasidagi
--                    `jami` shu. Ikkisi teng bo'lmasligi NORMAL.
update hodim_kapital_reja r
   set nechta       = m.nechta,
       kassa_code   = m.kassa_code,
       naqd_code    = m.naqd_code,
       oldin_qoldiq = m.naqd_qoldiq,
       jami_hozir   = m.jami_qoldiq,
       kutilgan     = case when m.nechta = 1 then coalesce(m.naqd_qoldiq, 0) + r.miqdor end
  from (
    select p.nom,
           (select count(*) from hodim_kassa_top(p.nom))          as nechta,
           k.kassa_code,
           n.code                                                 as naqd_code,
           b.uzs                                                  as naqd_qoldiq,
           j.uzs                                                  as jami_qoldiq
      from hodim_kapital_reja p
      left join lateral (select * from hodim_kassa_top(p.nom) limit 1) k on true
      left join lateral (
        select a.id, a.code
          from accounts a
         where a.parent_id = k.kassa_id and a.is_active
           and a.pul_turi = 'naqd'
           and coalesce(a.currency, 'UZS') = 'UZS'
         order by a.code limit 1
      ) n on true
      left join lateral (
        select coalesce(sum(l.debit - l.credit), 0) as uzs
          from entry_line l
          join entry e on e.id = l.entry_id
         where l.account_id = n.id
           and e.status = 'posted' and e.is_deleted = false
      ) b on true
      -- Ildiz kassa + HAMMA bolalari (is_active shart emas — pul puldir).
      -- Valyuta bolasi tarixiy kursdagi so'm ekvivalenti bilan kiradi
      -- (v_kassa_card `jami` bilan bir xil qoida).
      left join lateral (
        select coalesce(sum(l.debit - l.credit), 0) as uzs
          from entry_line l
          join entry e on e.id = l.entry_id
          join accounts a on a.id = l.account_id
         where (a.id = k.kassa_id or a.parent_id = k.kassa_id)
           and e.status = 'posted' and e.is_deleted = false
      ) j on true
  ) m
 where m.nom = r.nom;


-- ---------------------------------------------------------------------
-- 1.6 👀 PREVIEW — ASOSIY RO'YXAT.  ASILBEK SHUNI TEKSHIRSIN.
-- ---------------------------------------------------------------------
--  ⚠️⚠️  BU RO'YXATNI ASILBEK O'ZI TEKSHIRSIN  ⚠️⚠️
--
--  1) `nechta` ustuni HAMMA faol qatorda 1 bo'lishi SHART.
--     0 = kassa topilmadi (nom baza'dagidan boshqacha yozilgan).
--     2+ = bir nechta kassa mos keldi (qaysi biri kerakligi noma'lum).
--     Ikkala holatda ham 2-bosqich XATO beradi va hech narsa yozilmaydi.
--
--  2) TAKRORLANGAN ISMLAR — 1.7 dagi "bir xil summa" ro'yxatiga qarang.
--     Agar juftlik BITTA odam bo'lsa (eski hisob + yangi hisob), keraksizini
--     O'CHIRMANG, balki FAOLSIZLANTIRING, aks holda pul ikki barobar yoziladi:
--         update hodim_kapital_reja set faol = false where nom = 'Sardor Baxodirov';
--     ⚠️ `delete` QILMANG: 1.4 dagi insert qatorni faol=true bilan tiriltadi
--        (sababi 1.4 izohida).
--     Agar bular HAQIQATAN ikki xil odam bo'lsa — hech narsa qilmang.
--
--  3) IKKI XIL QOLDIQ USTUNI — chalkashtirmang:
--     • `oldin_qoldiq` — FAQAT naqd bola-hisobidagi pul. Yozuv aynan shu
--       hisobga tushadi, shuning uchun `yozilgandan_keyin` (= kutilgan)
--       ham shundan hisoblanadi.
--     • `jami_hozir`   — kassaning JAMI puli: ildiz hisob + HAMMA bolalari
--       (naqd + click + payme + valyuta). `kassa.html` kartasida ko'rinadigan
--       raqam AYNAN shu.
--     Ikkalasi teng bo'lmasligi NORMAL: pul click/payme bolasida yoki
--     ildiz hisobning o'zida turgan bo'lishi mumkin. Ya'ni
--     `yozilgandan_keyin` ni hodimning JAMI puli deb o'qimang — u faqat
--     naqd hisobning bo'lajak qoldig'i. Hodimning yozuvdan keyingi jami puli
--     taxminan `jami_hozir + miqdor` bo'ladi.
--     RESET YO'Q: yangi summa ustiga qo'shiladi. Agar "shuncha bo'lsin"
--     degan bo'lsangiz — miqdorni kamaytiring yoki menga ayting.
--
--  4) `naqd_code` bo'sh (null) bo'lsa — muammo emas: 2-bosqich naqd
--     bola-hisobini o'zi ochadi.
-- ⚠️ Bu SELECT'ni ALOHIDA belgilab RUN qiling (Supabase faqat oxirgi natijani ko'rsatadi)
select r.nom,
       r.miqdor,
       r.faol,
       r.nechta                                  as nechta_kassa_topildi,
       r.kassa_code,
       k.kassa_nom                               as kassa_nomi_bazada,
       k.kassa_sub                               as filial_lavozim,
       coalesce(r.naqd_code, '(ochiladi)')       as naqd_hisob,
       coalesce(r.oldin_qoldiq, 0)               as oldin_qoldiq,
       coalesce(r.jami_hozir, 0)                 as jami_hozir,
       r.kutilgan                                as yozilgandan_keyin,
       r.izoh
  from hodim_kapital_reja r
  left join lateral (select * from hodim_kassa_top(r.nom) limit 1) k on true
 order by (r.nechta is distinct from 1) desc, r.faol desc, r.nom;


-- ---------------------------------------------------------------------
-- 1.7 ⚠️ MUAMMOLI QATORLAR — bu ro'yxat BO'SH bo'lishi kerak
-- ---------------------------------------------------------------------
-- (a) topilmagan / bir nechta topilgan nomlar
-- ⚠️ Bu SELECT'ni ALOHIDA belgilab RUN qiling (Supabase faqat oxirgi natijani ko'rsatadi)
select case when coalesce(r.nechta, 0) = 0 then 'TOPILMADI'
            else 'BIR NECHTA TOPILDI (' || r.nechta || ')' end as muammo,
       r.nom,
       r.miqdor,
       (select string_agg(t.kassa_code || ' ' || t.kassa_nom, ' | ' order by t.kassa_code)
          from hodim_kassa_top(r.nom) t)                       as topilganlar
  from hodim_kapital_reja r
 where r.faol and coalesce(r.nechta, 0) <> 1
 order by r.nechta, r.nom;

-- (b) BIR XIL SUMMALI QATORLAR — ehtimoliy takror (bitta odam ikki nomda)
--     Bu yerda 6 juft chiqishi KUTILADI. Har juftni ko'zdan kechiring:
--     bitta odammi? Bo'lsa — bittasini faol=false qiling.
-- ⚠️ Bu SELECT'ni ALOHIDA belgilab RUN qiling (Supabase faqat oxirgi natijani ko'rsatadi)
select r.miqdor,
       count(*)                                                     as nechta_nom,
       string_agg(r.nom || ' [' || coalesce(r.kassa_code, '—') || ']',
                  '  ·  ' order by r.nom)                           as nomlar,
       sum(r.miqdor)                                                as jami_yoziladi
  from hodim_kapital_reja r
 where r.faol
 group by r.miqdor
having count(*) > 1
 order by r.miqdor desc;

-- (c) YAKUNIY SUMMA — 2-bosqich shuncha pul yozadi
-- ⚠️ Bu SELECT'ni ALOHIDA belgilab RUN qiling (Supabase faqat oxirgi natijani ko'rsatadi)
select count(*)      as qatorlar,
       sum(miqdor)   as jami_som
  from hodim_kapital_reja
 where faol and miqdor > 0;

-- (d) Yordamchi: baza'dagi HAMMA hodim kassasi (nom qidirishda adashsangiz)
--     Alohida RUN qiling:
--       select a.code, a.name, a.subtitle, hodim_nom_norm(a.name) as normal_shakl
--         from accounts a
--         join accounts g on g.id = a.parent_id and g.kassa_turi = 'xarajat_guruh'
--        where a.section = 'pul' and a.is_active and a.pul_turi is null
--          and coalesce(a.currency,'UZS') = 'UZS'
--        order by a.code;


-- #####################################################################
--
--   ⛔⛔  FAQAT PREVIEW TEKSHIRILGANDAN KEYIN RUN QILING  ⛔⛔
--
--   Quyidagi 2-BOSQICH haqiqiy pul yozadi. Yuqoridagi 1.7 (a) ro'yxati
--   BO'SH bo'lsin va 1.7 (b) dagi juftlar bo'yicha qaror qabul qilingan
--   bo'lsin. Shundan keyingina shu bo'limni belgilab RUN qiling.
--
--   Hammasi BITTA tranzaksiya: biror joyda xato bo'lsa HAMMASI orqaga
--   qaytadi (yarim yozilgan holat bo'lmaydi).
--
-- #####################################################################

-- ---------------------------------------------------------------------
-- 2. YOZISH — Dt hodim naqd / Kt Boshlang'ich kapital
-- ---------------------------------------------------------------------
do $yoz$
declare
  -- ⚙️ Yozuv belgisi. ext_ref = '<batch>:<kassa_code>' -> takroriy RUN pulni
  --    ikki marta yozmaydi. Sanadan MUSTAQIL: ertaga RUN qilsangiz ham
  --    o'sha kassalar qayta yozilmaydi. ROLLBACK ham shu belgi bo'yicha.
  v_batch  text := 'bkap:hodim';
  -- ⚙️ Yozuv sanasi. UZB vaqti (Supabase UTC'da yuradi — current_date emas).
  p_sana   date := (now() at time zone 'Asia/Tashkent')::date;

  v_kapital  uuid;
  v_kap_code text;
  v_source   text := 'boshlangich_kapital';

  r          record;
  v_kassa    uuid;
  v_kod      text;
  v_nom      text;
  v_sub      text;
  v_turi     text;
  v_soni     int;
  v_topilgan text;

  v_naqd     uuid;
  v_naqd_kod text;
  v_prefix   text;
  v_uzun     int;
  v_next     int;
  v_code     text;
  v_uzun_bor boolean;

  v_oldin    numeric;
  -- ⚠️ nomi ataylab v_jami EMAS: pastda `v_jami` (yozilgan umumiy summa) bor.
  v_kassa_jami numeric;   -- kassaning ildiz + hamma bolalari qoldig'i (ko'rsatkich)
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
begin
  -- ---- Kapital hisobi -----------------------------------------------
  v_kapital := boshlangich_kapital_id();
  if v_kapital is null then
    raise exception 'Boshlang''ich kapital hisobi topilmadi — PROVODKA_KAPITAL.sql RUN qilinganmi?';
  end if;
  select code into v_kap_code from accounts where id = v_kapital;

  -- ---- `source` ustunida cheklov bormi -------------------------------
  -- Bazada entry.source ga check constraint qo'yilgan bo'lsa, notanish
  -- qiymat butun tranzaksiyani yiqitadi. Shu holatda xavfsiz 'manual' ga
  -- tushamiz — yozuvni baribir created_by='boshlangich_kapital' va ext_ref
  -- belgilaydi, hech narsa yo'qolmaydi.
  if exists (select 1 from pg_constraint c
              where c.conrelid = 'public.entry'::regclass
                and c.contype = 'c'
                and pg_get_constraintdef(c.oid) ilike '%source%') then
    v_source := 'manual';
    raise notice 'DIQQAT: entry.source da cheklov bor -> source = ''manual'' ishlatiladi';
  end if;

  raise notice 'Kapital hisob: % (%) | sana: % | belgi: %',
    v_kap_code, v_kapital, p_sana, v_batch;

  -- ---- Har hodim uchun ------------------------------------------------
  for r in
    select nom, miqdor
      from hodim_kapital_reja
     where faol and miqdor > 0
     order by nom
  loop
    -- 2.1 Kassani topish: ANIQ BITTA bo'lishi SHART
    select count(*) into v_soni from hodim_kassa_top(r.nom);

    if v_soni <> 1 then
      select coalesce(string_agg(t.kassa_code || ' ' || t.kassa_nom, ' | '
                                 order by t.kassa_code), '(yo''q)')
        into v_topilgan
        from hodim_kassa_top(r.nom) t;
      raise exception E'"%" — % ta hodim kassasi topildi (aniq 1 ta kerak).\n'
        E'Topilganlar: %\n'
        'HAMMASI BEKOR QILINDI. 1-BOSQICH (preview) ni qayta RUN qilib '
        '1.7 (a) ro''yxatini tekshiring: nomni baza''dagi yozilishiga moslang '
        'yoki qatorni faol=false qiling.',
        r.nom, v_soni, v_topilgan;
    end if;

    select t.kassa_id, t.kassa_code, t.kassa_nom, t.kassa_sub, t.kassa_tur
      into v_kassa, v_kod, v_nom, v_sub, v_turi
      from hodim_kassa_top(r.nom) t;

    -- 2.2 Allaqachon yozilganmi (takroriy RUN)
    v_ext := v_batch || ':' || v_kod;
    if exists (select 1 from entry where ext_ref = v_ext) then
      n_otkaz := n_otkaz + 1;
      update hodim_kapital_reja
         set holat = 'otkazildi (avval yozilgan)'
       where nom = r.nom;
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
      --    qilinishi ko'zda tutilgan (o'shanda 4 xonali bloklarda joy bor).
      --    TURLAR_AVTO `pul_turi_kod_blok` ga `raqam_uzunlik` ustunini qo'shadi
      --    va 5 xonali bloklarni (55xxx / 53xxx / 51xxx) ochadi, chunki
      --    60+ hodim x 4 tur 4 xonali bloklarni to'ldiradi.
      --    Shuning uchun quyida MOSLASHUV bor:
      --      • ustun BOR   -> blokning o'z uzunligi ishlatiladi (5 xonali ham);
      --      • ustun YO'Q  -> eski 2 raqamli mantiq (o'zgarishsiz).
      --    Ustunga statik havola qilinmaydi (ustun yo'q bazada butun blok
      --    parse xatosi berardi) — shuning uchun dinamik `execute`.
      v_prefix := null;
      v_uzun   := 2;

      select exists (select 1 from information_schema.columns
                      where table_schema = 'public'
                        and table_name  = 'pul_turi_kod_blok'
                        and column_name = 'raqam_uzunlik')
        into v_uzun_bor;

      if v_uzun_bor then
        execute $q$
          select b.prefix, b.raqam_uzunlik, coalesce(mx.n, 0) + 1
            from pul_turi_kod_blok b
            left join lateral (
              select max(substring(a.code from 3)::int) as n
                from accounts a
               where a.code ~ ('^' || b.prefix || '[0-9]{' || b.raqam_uzunlik::text || '}$')
            ) mx on true
           where coalesce(mx.n, 0) + 1 <= (power(10, b.raqam_uzunlik)::int - 1)
           order by b.nav
           limit 1
        $q$ into v_prefix, v_uzun, v_next;
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
        raise exception 'Tur kod bloklari to''ldi (% kassada to''xtadi). '
                        'pul_turi_kod_blok''ga yangi prefiks qo''shing — yoki '
                        'PROVODKA_TURLAR_AVTO.sql ni RUN qilib 5 xonali '
                        'bloklarni oching (u raqam_uzunlik ustunini qo''shadi).', v_kod;
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

    -- 2.4 Yozuvdan OLDINGI qoldiq (reset yo'q — ustiga qo'shiladi).
    --     ⚠️ FAQAT NAQD bolasi — pul aynan shu hisobga tushadi, shuning uchun
    --        `kutilgan` va 2.6 (a) tekshiruvi ham shundan hisoblanadi.
    select coalesce(sum(l.debit - l.credit), 0)
      into v_oldin
      from entry_line l
      join entry e on e.id = l.entry_id
     where l.account_id = v_naqd
       and e.status = 'posted' and e.is_deleted = false;

    -- 2.4b Kassaning JAMI puli: ildiz + HAMMA bolalari (naqd/click/payme/valyuta).
    --      kassa.html kartasidagi `jami` bilan bir xil o'qiladi.
    --      FAQAT KO'RSATKICH — yozish mantig'iga ta'sir qilmaydi (pul baribir
    --      naqd bolasiga tushadi). `oldin_qoldiq` bilan farqi normal.
    select coalesce(sum(l.debit - l.credit), 0)
      into v_kassa_jami
      from entry_line l
      join entry e on e.id = l.entry_id
      join accounts a on a.id = l.account_id
     where (a.id = v_kassa or a.parent_id = v_kassa)
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

    -- check_entry_balanced DEFERRED, u faqat COMMIT paytida ishlaydi va
    -- o'sha yerdagi xato tushunarsiz bo'ladi — shuning uchun o'zimiz tekshiramiz.
    select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
      into v_dt, v_kt from entry_line where entry_id = v_entry;
    if v_dt <> v_kt then
      raise exception 'Yozuv muvozanatda emas: Dt=% Kt=% (% — %)', v_dt, v_kt, v_kod, v_nom;
    end if;

    update hodim_kapital_reja
       set nechta       = 1,
           kassa_code   = v_kod,
           naqd_code    = v_naqd_kod,
           oldin_qoldiq = v_oldin,
           jami_hozir   = v_kassa_jami + r.miqdor,   -- ildiz + hamma bolalar, yozuvdan KEYIN
           kutilgan     = v_oldin + r.miqdor,
           holat        = 'yozildi',
           entry_id     = v_entry
     where nom = r.nom;

    n_yozildi := n_yozildi + 1;
    v_jami    := v_jami + r.miqdor;
    raise notice '  kirim  %  %  +% so''m  (oldin: %, keyin: %)',
      v_naqd_kod, v_nom, r.miqdor, v_oldin, v_oldin + r.miqdor;
  end loop;

  if n_yozildi = 0 and n_otkaz = 0 then
    raise exception 'TO''XTADI: birorta faol qator yo''q — reja bo''shmi?';
  end if;

  -- ---- 2.6 O'Z-O'ZINI TEKSHIRISH -------------------------------------
  -- Bu yerdan chiqadigan har qanday xato BUTUN skriptni orqaga qaytaradi.

  -- (a) Har naqd hisobning qoldig'i kutilganga tengmi (eski + yangi)
  select count(*) into v_xato
    from hodim_kapital_reja r
    join accounts n on n.code = r.naqd_code
    join lateral (
      select coalesce(sum(l.debit - l.credit), 0) as uzs
        from entry_line l join entry e on e.id = l.entry_id
       where l.account_id = n.id
         and e.status = 'posted' and e.is_deleted = false
    ) b on true
   where r.holat = 'yozildi' and b.uzs <> r.kutilgan;

  if v_xato > 0 then
    raise exception 'TEKSHIRUV XATO: % ta hisob qoldig''i kutilganga teng emas — hammasi bekor qilindi.', v_xato;
  end if;

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

  -- (c) P&L'ga tegmadimi — daromad/xarajat hisobi bo'lmasligi SHART
  select count(*) into v_xato
    from entry e
    join entry_line l on l.entry_id = e.id
    join accounts a on a.id = l.account_id
   where e.ext_ref like v_batch || ':%'
     and a.type in ('daromad', 'xarajat');

  if v_xato > 0 then
    raise exception 'TEKSHIRUV XATO: % ta satr daromad/xarajat hisobiga tushib qolgan (P&L shishadi)', v_xato;
  end if;

  -- (d) Kapital hisobiga tushgan Kt summasi rejaga tengmi
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
end
$yoz$;


-- ---------------------------------------------------------------------
-- 3. NATIJA — skriptning oxirgi so'rovi, Supabase shuni ko'rsatadi
-- ---------------------------------------------------------------------
-- `hozirgi_qoldiq` — FAQAT naqd hisob (yozuv shu yerga tushdi), `kutilgan`
-- bilan solishtiriladi. `jami_kassa_hozir` — hodimning JAMI puli (ildiz +
-- hamma bolalari), ya'ni kassa.html kartasida ko'rinadigan raqam. Ikkisi
-- teng bo'lmasligi NORMAL: click/payme/valyuta bolasida ham pul bo'lishi mumkin.
select r.nom,
       r.miqdor,
       r.holat,
       r.kassa_code,
       r.naqd_code,
       r.oldin_qoldiq,
       r.kutilgan,
       b.uzs                                   as hozirgi_qoldiq,
       b.uzs - coalesce(r.kutilgan, b.uzs)     as farq_nol_bolishi_kerak,
       jb.uzs                                  as jami_kassa_hozir
  from hodim_kapital_reja r
  left join accounts n on n.code = r.naqd_code
  left join lateral (
    select coalesce(sum(l.debit - l.credit), 0) as uzs
      from entry_line l join entry e on e.id = l.entry_id
     where l.account_id = n.id
       and e.status = 'posted' and e.is_deleted = false
  ) b on true
  left join accounts kk on kk.code = r.kassa_code
  left join lateral (
    select coalesce(sum(l.debit - l.credit), 0) as uzs
      from entry_line l
      join entry e on e.id = l.entry_id
      join accounts a on a.id = l.account_id
     where (a.id = kk.id or a.parent_id = kk.id)
       and e.status = 'posted' and e.is_deleted = false
  ) jb on true
 where r.faol
 order by r.nom;


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
-- Jami yozilgan summa (reja bilan solishtiring):
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
--    where c.code in (select kassa_code from hodim_kapital_reja where holat = 'yozildi')
--    order by c.code;
--
-- Kapital hisobining yangi qoldig'i:
--   select bolim, code, name, amount from balans(current_date)
--    where code = (select code from accounts where id = boshlangich_kapital_id());


-- =====================================================================
--  ROLLBACK — noto'g'ri summa yoki noto'g'ri hodimga yozilib qolsa
-- =====================================================================
-- Yozuvlar `ext_ref` = 'bkap:hodim:...' bilan belgilangan, shuning uchun
-- aniq topiladi va boshqa hech narsaga tegmaydi.
--
-- A) HAMMASINI qaytarish (yumshoq — tarix saqlanadi, jurnalda usti chizilgan
--    holda qoladi, kassa qoldig'i yozuvdan OLDINGI holatiga qaytadi):
--
--    update entry set is_deleted = true,
--                     deleted_at = now(),
--                     deleted_by_name = 'rollback: hodim boshlangich kapital'
--     where ext_ref like 'bkap:hodim:%' and is_deleted = false;
--
--    Keyin qayta RUN qilish uchun ext_ref'ni bo'shatish SHART (unique to'siq,
--    aks holda skript "avval yozilgan" deb o'tkazib yuboradi):
--    update entry set ext_ref = ext_ref || ':bekor:' || id::text
--     where ext_ref like 'bkap:hodim:%' and is_deleted;
--
--    Rejani ham tozalang:
--    update hodim_kapital_reja set holat = null, entry_id = null;
--
-- B) BITTA hodimni qaytarish (masalan takror ekani keyin ma'lum bo'lsa):
--    5423 o'rniga o'sha hodimning kassa kodini yozing.
--
--    update entry set is_deleted = true, deleted_at = now(),
--                     deleted_by_name = 'rollback: takror hodim'
--     where ext_ref = 'bkap:hodim:5423';
--    update entry set ext_ref = ext_ref || ':bekor:' || id::text
--     where ext_ref = 'bkap:hodim:5423' and is_deleted;
--    update hodim_kapital_reja set faol = false, holat = null, entry_id = null
--     where kassa_code = '5423';
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
