-- =====================================================================
--  ⚠️⚠️  SUPABASE SQL EDITOR — QANDAY RUN QILINADI (avval SHUNI o'qing)
-- ---------------------------------------------------------------------
--   1) Bu faylda `do` bloki UMUMAN YO'Q va dollar-quote belgisi ham
--      (ikki dollar yonma-yon) UMUMAN YO'Q — izohlarda ham yo'q.
--      Hammasi oddiy `select` / `create table` / `insert`. Supabase SQL
--      Editor `do` blokini bo'lib yuborar va o'zgaruvchini jadval deb
--      izlar edi (`ERROR: 42P01: relation "v_payload" does not exist`) —
--      shuning uchun mantiq o'zgarmagan holda qayta qadoqlandi.
--
--   2) Tartib:
--        0-BOSQICH  — shart-sharoit tekshiruvi (hech narsa yozmaydi)
--        1-BOSQICH  — reja jadvali + PREVIEW + "OLDIN" surati (yozmaydi)
--        2.1        — MAJBURIY DRY-RUN (yozmaydi)
--        2.2        — 🔴 YOZISH (haqiqiy pul)
--        2.3.x      — yozgandan keyingi O'ZINI TEKSHIRUVLAR (har biri alohida)
--        3-BOSQICH  — natija ko'rinishi
--        4-BOSQICH  — ROLLBACK (qo'lda, izohdan chiqarib ishlatiladi)
--      BUTUN FAYLNI BIRDANIGA RUN QILMANG — 2.2 haqiqiy pul yozadi.
--
--   3) Har bo'lak ⬇⬇⬇ va ⬆⬆⬆ belgilari orasida — AYNAN o'sha oraliqni
--      belgilab RUN qiling. Bitta `select` = bitta tranzaksiya: 2.2 ichida
--      xato bo'lsa Postgres o'zi hammasini orqaga qaytaradi (yarim yozuv qolmaydi).
--
--   4) 🔴 YOZISHDAN OLDIN n8n `Aros Provodka - Transfer Sync`
--      (eAsNswlsZO9VKKAq) ni VAQTINCHA DEACTIVATE QILING, 2.3.x
--      tekshiruvlari tugagach qayta yoqing.
--      Sabab: 2.2 ichidagi RPC `pg_advisory_xact_lock` oladi (u funksiya
--      ichida, PROVODKA_TRANSFER_TUZATISH.sql:216 — YO'QOLMAGAN), ya'ni
--      sinxron bilan bir vaqtda YOZISH mumkin emas. Lekin sinxron 2.2 dan
--      keyin, tekshiruvlar orasida ishga tushsa raqamlar "jonli" o'zgaradi
--      va tekshiruvlar sababsiz ❌ ko'rsatishi mumkin.
-- =====================================================================

-- =====================================================================
--  PROVODKA_TRANSFER_TIKLASH_0812.sql
--  12-avgust 2026 da sinxron TUSHIRIB QOLDIRGAN 9 ta transferni tiklash
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  #####  NIMA BO'LGAN  ################################################
--
--  12-avgust kuni Aros'da 9 ta transfer `received` bo'lgan, lekin transfer
--  sync ularni Provodka'ga YOZMAGAN (`ext_ref = 'aros_tr:<id>:<tur>'` yo'q).
--  Delta sync esa keyin ishlagan: filial balansi kamayganini ko'rib, uni
--  "savdo minus" deb yozgan — Dt 9010 / Kt <filial tur child>.
--
--  Natija: filial tomoni TO'G'RI (daftar Aros bilan teng), lekin
--     • markaziy kassa (Toshkent / Qashqadaryo) pulni OLMAGAN,
--     • 9010 savdo tushumi transfer summasiga KAM ko'rsatilgan.
--
--  Bu AYNAN `transfer_tuzatish()` hal qiladigan holat. Shuning uchun bu
--  fayl yangi mantiq YOZMAYDI — faqat 9 ta transferni reja jadvaliga
--  qo'yadi, payload yasaydi va tuzatilgan RPC ni chaqiradi:
--
--        Dt <markaziy kassaning tur child'i>  /  Kt 9010  =  T
--
--  FILIAL TOMONIGA UMUMAN TEGILMAYDI.
--
--  #####  🔴 AVVAL PROVODKA_TRANSFER_TUZATISH.sql RUN QILINSIN  ########
--
--  2026-08-13 da `transfer_tuzatish()` da IKKI JIDDIY XATO tuzatildi:
--     A1) 2-himoya ("sinxron buni allaqachon yozgan") noto'g'ri kalit
--         izlardi: 'aros_tr:<id>:naqd' / ':dollar'. Sinxron esa
--         'aros_tr:<id>:cash' / ':dollar_usd' yozadi. Ya'ni NAQD va
--         DOLLAR uchun 2-himoya hech qachon ishlamagan — to'g'ri yozilgan
--         transfer ustiga ikkinchi marta pul yozilishi mumkin edi.
--     A2) `received_at` zonasiz matn edi va UTC deb o'qilardi (5 soat
--         siljish) — cutoff solishtiruvi sinxronnikidan farq qilardi.
--  Eski (tuzatilmagan) RPC bilan bu skriptni ishlatish PULNI IKKI MARTA
--  YOZISH XAVFI. Shuning uchun 0-BOSQICH buni tekshiradi va 2.1/2.2
--  bloklarining O'ZI ham eski versiyada RPC ni umuman chaqirmaydi.
--
--  #####  9 TA TRANSFER  ###############################################
--
--   id   received_at (Toshkent)  kimdan                  kimga
--   1148 2026-08-12 15:47:37     Izza Shourum            Toshkent Kassa
--   1165 2026-08-12 12:05:49     O'rikzor 43-do'kon      Toshkent Kassa
--   1166 2026-08-12 12:35:44     Qarshi Bahor Aksessuar  Qashqadaryo Kassa
--   1167 2026-08-12 12:35:31     Qarshi Bahor            Qashqadaryo Kassa
--   1168 2026-08-12 12:34:37     Qarshi Asosiy ombor     Qashqadaryo Kassa
--   1169 2026-08-12 12:06:58     O'rikzor Mobile Center  Toshkent Kassa
--   1170 2026-08-12 15:23:39     Buxoro Eski Sum         Toshkent Kassa
--   1171 2026-08-12 12:22:12     Chilonzor               Toshkent Kassa
--   1174 2026-08-12 12:10:32     O'rikzor C8             Toshkent Kassa
--
--  Kutilgan: 21 ta yozuv (transfer × tur, summasi > 0 bo'lganlari).
--  So'm qismi: 339 625 000. Dollar: 1100 USD (kurs bilan ≈ 13 210 000).
--  JAMI ≈ 352 835 000 so'm. Skript haqiqiy jamini oxirida chiqaradi va
--  Asilbek aytgan mo'ljal (352 068 000) bilan farqini ko'rsatadi —
--  farq bo'lsa DARROV ko'rinadi (yozish bekor qilinmaydi, faqat
--  ogohlantiradi: mo'ljal taxminiy, reja jadvalidagi raqamlar aniq).
--
--  🔴 11-avgustgacha bo'lgan transferlar TIKLANMAYDI — ular boshlang'ich
--     kapitalga kirgan (11-avgust kechqurun). Reja jadvalida faqat 12-avgust.
--
--  #####  NEGA IKKI MARTA YOZILMAYDI  ##################################
--     1. `aros_tr_fix:<id>:<tur>` — UNIQUE ext_ref. Skriptni ikki marta
--        RUN qilsang ikkinchisi 0 yozuv qiladi (RPC 1-himoya + baza unique).
--     2. `aros_tr:<id>:<maydon>` — sinxron o'sha transferni oradan
--        yozib qo'ygan bo'lsa, tuzatish o'sha turni O'TKAZIB YUBORADI.
--        (Aynan shu himoya A1 da tuzatildi.)
--     3. CUTOFF — received_at cutoff'dan keyin bo'lsa tegilmaydi
--        (uni sinxronning o'zi yozadi).
--     4. `pg_advisory_xact_lock` — RPC ning O'Z ichida (funksiya yo'qolmadi),
--        ya'ni transfer sync bilan bir vaqtda YOZISH imkonsiz.
--     5. 2.2 bloki eski RPC versiyasida va reja jadvali 9 qator bo'lmasa
--        RPC ni umuman CHAQIRMAYDI (CASE ichida to'silgan).
--     + PREVIEW (1.3): yozishdan oldin har satr uchun qaror ko'rinadi.
--     + DRY-RUN (2.1): RPC ning o'zi nima yozishini aytadi, yozmaydi.
--     + 2.3.7: yozgandan keyin "bir tur ikki marta yozilmaganini" tekshiradi.
--
--  TALAB: PROVODKA_TRANSFER.sql (aros_kassa_topish, aros_tur_hisob,
--         aros_transfer_cutoff), PROVODKA_TRANSFER_TUZATISH.sql (tuzatilgan).
--
--  ADDITIVE: mavjud jadval/ustun/funksiya/view o'zgartirilmaydi. Yangi
--  jadvallar `transfer_tiklash_0812` va `transfer_tiklash_0812_oldin` —
--  SHU skriptning o'z jadvallari.
-- =====================================================================


-- #####################################################################
--  0-BOSQICH — SHART-SHAROIT TEKSHIRUVI.  HECH NARSA YOZMAYDI.
-- #####################################################################

-- 0.1 `transfer_tuzatish()` TUZATILGAN versiyadami?
--     Ikkala qator ham "✅ OK" bo'lishi SHART. Aks holda avval
--     PROVODKA_TRANSFER_TUZATISH.sql ni RUN qiling.
select 'A1 — sinxron kaliti (dollar_usd)' as tekshiruv,
       case when p.prosrc like '%dollar_usd%' then '✅ OK'
            else '❌ ESKI VERSIYA — RUN QILMANG' end as natija
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'transfer_tuzatish'
union all
select 'A2 — vaqt zonasi normalizatsiyasi (+05)',
       case when p.prosrc like '%T00:00:00+05%' then '✅ OK'
            else '❌ ESKI VERSIYA — RUN QILMANG' end
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'transfer_tuzatish';

-- 0.2 Cutoff qayerda turibdi. 9 ta transfer 12-avgust 12:05–15:47 (+05) —
--     cutoff SHULARDAN KEYIN bo'lishi kerak (delta sync o'shandan beri
--     ko'p marta ishlagan). Aks holda transferlarni delta yutmagan va
--     to'g'irlash o'rniga sinxronning o'zini ishlatish kerak.
select jsonb_pretty(aros_transfer_cutoff());

-- 0.3 Bu 9 ta transfer haqiqatan yozilmaganmi (bo'sh natija = yozilmagan).
select e.ext_ref, e.entry_date, e.description, e.is_deleted
  from entry e
 where e.ext_ref like 'aros_tr:%'
   and split_part(e.ext_ref, ':', 2) in
       ('1148','1165','1166','1167','1168','1169','1170','1171','1174')
 order by e.ext_ref;

-- 0.4 Oldin to'g'irlanmaganmi (bo'sh natija = to'g'irlanmagan).
select e.ext_ref, e.entry_date, e.description, e.is_deleted
  from entry e
 where e.ext_ref like 'aros_tr_fix:%'
   and split_part(e.ext_ref, ':', 2) in
       ('1148','1165','1166','1167','1168','1169','1170','1171','1174')
 order by e.ext_ref;


-- #####################################################################
--  1-BOSQICH — REJA JADVALI + PREVIEW + "OLDIN" SURATI.  PUL YOZMAYDI.
-- #####################################################################

-- ---------------------------------------------------------------------
-- 1.1 REJA JADVALI
-- ---------------------------------------------------------------------
-- `transfer_tiklash_0812` — SHU SKRIPTNING O'Z jadvali. Frontend, view,
-- RPC yoki boshqa .sql fayl unga murojaat qilmaydi, shuning uchun
-- drop+create ADDITIVE qoidasini buzmaydi.
--
-- ⚠️ `received_at` — Aros naive (Toshkent) beradi, shuning uchun bu yerda
--    ochiq `+05` bilan yozilgan. Payloadga ham `+05:00` bilan chiqadi.
-- ⚠️ `sender` faqat IZOH matni uchun — kassa qidiruvi FAQAT `receiver`
--    bo'yicha bo'ladi (pul markaziy kassaga tushadi). Ya'ni jo'natuvchi
--    nomidagi yozilish farqi pulga ta'sir qilmaydi.
--
-- ⬇⬇⬇  1.1 + 1.2: SHU QATORDAN 1.2 oxiridagi `;` GACHA BELGILANG  ⬇⬇⬇
drop table if exists transfer_tiklash_0812;

create table transfer_tiklash_0812 (
  tr_id       text        primary key,
  received_at timestamptz not null,
  sender      text        not null,
  receiver    text        not null,
  cash        numeric     not null default 0 check (cash       >= 0),
  click       numeric     not null default 0 check (click      >= 0),
  payme       numeric     not null default 0 check (payme      >= 0),
  dollar_usd  numeric     not null default 0 check (dollar_usd >= 0),
  kurs        numeric     check (kurs is null or kurs > 0)
);

comment on table transfer_tiklash_0812 is
  '12-avgust 2026 da sinxron tushirib qoldirgan 9 ta Aros transferi. '
  'Faqat PROVODKA_TRANSFER_TIKLASH_0812.sql ishlatadi.';

-- ---------------------------------------------------------------------
-- 1.2 9 TA TRANSFER (Aros bazasidan olingan, Asilbek tekshirgan)
-- ---------------------------------------------------------------------
insert into transfer_tiklash_0812
  (tr_id, received_at, sender, receiver, cash, click, payme, dollar_usd, kurs)
values
  ('1148', timestamptz '2026-08-12 15:47:37+05', 'Izza Shourum',
           'Toshkent Kassa',    35550000,  5084000,        0,   0, 12050),
  ('1165', timestamptz '2026-08-12 12:05:49+05', 'O''rikzor 43-do''kon',
           'Toshkent Kassa',     1365000,        0,        0,   0, 12000),
  ('1166', timestamptz '2026-08-12 12:35:44+05', 'Qarshi Bahor Aksessuar',
           'Qashqadaryo Kassa',   655000,        0,        0,   0, 12000),
  ('1167', timestamptz '2026-08-12 12:35:31+05', 'Qarshi Bahor',
           'Qashqadaryo Kassa', 14920000,        0,  6665000,   0, 12000),
  ('1168', timestamptz '2026-08-12 12:34:37+05', 'Qarshi Asosiy ombor',
           'Qashqadaryo Kassa', 56900000, 16360000, 20750000, 700, 12000),
  ('1169', timestamptz '2026-08-12 12:06:58+05', 'O''rikzor Mobile Center',
           'Toshkent Kassa',     1655000,  3210000,        0, 100, 12000),
  ('1170', timestamptz '2026-08-12 15:23:39+05', 'Buxoro Eski Sum',
           'Toshkent Kassa',    35641000, 10779000,        0, 100, 12050),
  ('1171', timestamptz '2026-08-12 12:22:12+05', 'Chilonzor',
           'Toshkent Kassa',    39594000,        0,        0, 100, 12050),
  ('1174', timestamptz '2026-08-12 12:10:32+05', 'O''rikzor C8',
           'Toshkent Kassa',    54850000, 35647000,        0, 100, 12000);
-- ⬆⬆⬆  1.1 + 1.2 shu yerda tugadi  ⬆⬆⬆

-- 1.2.1 Reja jamisi (ko'z bilan tekshirish uchun)
select count(*)                                        as transferlar,
       sum(cash)                                       as naqd,
       sum(click)                                      as click,
       sum(payme)                                      as payme,
       sum(cash + click + payme)                       as som_jami,
       sum(dollar_usd)                                 as usd,
       sum(round(dollar_usd * kurs, 2))                as usd_somda,
       sum(cash + click + payme + round(dollar_usd * kurs, 2)) as jami
  from transfer_tiklash_0812;

-- ---------------------------------------------------------------------
-- 1.3 ⭐ PREVIEW — har transfer × tur uchun QAROR.  HECH NARSA YOZMAYDI.
-- ---------------------------------------------------------------------
--  Ustunlar:
--    sync_kalit / sync_bor  — sinxron yozadigan kalit va u bazada bormi
--    fix_kalit  / fix_bor   — to'g'irlash kaliti va u bazada bormi
--    dt_kod/dt_nom          — pul TUSHADIGAN hisob (markaziy kassa turi)
--    kt_kod                 — 9010 (savdo tushumi) — har doim
--    qaror                  — ✅ YOZILADI / ⏭ o'tkaziladi / ⛔ MUAMMO
--
--  🔴 ⛔ belgisi bo'lgan bitta qator bo'lsa ham — 2.2 NI RUN QILMANG.
--     Avval sabab hal qilinsin (kassa nomi / tur bola-hisobi / kurs).
with turlar(maydon, tur, lbl) as (
  values ('cash', 'naqd', 'Naqd'), ('click', 'click', 'Click'),
         ('payme', 'payme', 'Payme'), ('dollar_usd', 'dollar', 'USD')
),
qator as (
  select r.tr_id, r.received_at, r.sender, r.receiver, r.kurs,
         t.maydon, t.tur, t.lbl,
         case t.maydon
           when 'cash'  then r.cash
           when 'click' then r.click
           when 'payme' then r.payme
           else r.dollar_usd
         end as miqdor
    from transfer_tiklash_0812 r
   cross join turlar t
),
faol as (
  select q.*,
         'aros_tr:'     || q.tr_id || ':' || q.maydon as sync_kalit,
         'aros_tr_fix:' || q.tr_id || ':' || q.tur    as fix_kalit,
         case when q.maydon = 'dollar_usd'
              then round(q.miqdor * q.kurs, 2) else q.miqdor end as summa_uzs,
         aros_kassa_topish(null::text, q.receiver)    as kres,
         (aros_transfer_cutoff() ->> 'cutoff')::timestamptz as cutoff
    from qator q
   where q.miqdor > 0
),
toliq as (
  select f.*,
         coalesce((f.kres ->> 'ok')::boolean, false)      as kassa_ok,
         f.kres ->> 'sabab'                               as kassa_sabab,
         f.kres ->> 'code'                                as kassa_kod,
         aros_tur_hisob(nullif(f.kres ->> 'id', '')::uuid, f.maydon) as dt_id,
         exists (select 1 from entry e where e.ext_ref = f.sync_kalit) as sync_bor,
         exists (select 1 from entry e where e.ext_ref = f.fix_kalit)  as fix_bor
    from faol f
)
select t.tr_id,
       to_char(t.received_at at time zone 'Asia/Tashkent',
               'YYYY-MM-DD HH24:MI') as qabul_vaqti,
       t.sender                      as kimdan,
       t.receiver                    as kimga,
       t.lbl                         as tur,
       t.miqdor,
       t.kurs,
       t.summa_uzs,
       t.kassa_kod                   as kassa,
       a.code                        as dt_kod,
       a.name                        as dt_nom,
       '9010'                        as kt_kod,
       t.sync_kalit, t.sync_bor,
       t.fix_kalit,  t.fix_bor,
       case
         when not t.kassa_ok
           then '⛔ KASSA TOPILMADI: ' || coalesce(t.kassa_sabab, '?')
         when t.dt_id is null
           then '⛔ TUR HISOBI YO''Q (' || t.lbl || ') — kassada bola-hisob ochilmagan'
         when t.maydon = 'dollar_usd' and coalesce(t.kurs, 0) <= 0
           then '⛔ KURS YO''Q — so''m ekvivalenti hisoblanmaydi'
         when t.fix_bor
           then '⏭ allaqachon to''g''irlangan (fix_kalit bor)'
         when t.sync_bor
           then '⏭ sinxron to''g''ri yozgan (sync_kalit bor) — 2-himoya'
         when t.cutoff is null
           then '⛔ CUTOFF YO''Q — RPC baribir rad etadi'
         when t.received_at > t.cutoff
           then '⏭ cutoffdan KEYIN — sinxronning o''zi yozadi'
         else '✅ YOZILADI'
       end as qaror
  from toliq t
  left join accounts a on a.id = t.dt_id
 order by t.tr_id, t.maydon;

-- 1.3.1 Preview yakuni — nechta yoziladi, jami qancha.
--       `yoziladigan_satr` 2.1 DRY-RUN dagi `yozuvlar` bilan MOS kelsin.
with turlar(maydon, tur) as (
  values ('cash', 'naqd'), ('click', 'click'),
         ('payme', 'payme'), ('dollar_usd', 'dollar')
),
qator as (
  select r.tr_id, r.received_at, r.kurs, t.maydon, t.tur,
         case t.maydon
           when 'cash'  then r.cash
           when 'click' then r.click
           when 'payme' then r.payme
           else r.dollar_usd
         end as miqdor
    from transfer_tiklash_0812 r
   cross join turlar t
)
select count(*) as yoziladigan_satr,
       sum(case when q.maydon = 'dollar_usd'
                then round(q.miqdor * q.kurs, 2) else q.miqdor end) as jami_uzs,
       352068000 as moljal,
       sum(case when q.maydon = 'dollar_usd'
                then round(q.miqdor * q.kurs, 2) else q.miqdor end)
         - 352068000 as farq
  from qator q
 where q.miqdor > 0
   and not exists (select 1 from entry e
                    where e.ext_ref = 'aros_tr:' || q.tr_id || ':' || q.maydon)
   and not exists (select 1 from entry e
                    where e.ext_ref = 'aros_tr_fix:' || q.tr_id || ':' || q.tur);

-- ---------------------------------------------------------------------
-- 1.4 ⭐ MANTIQIY TEKSHIRUV — delta bu pulni haqiqatan "savdo minus"
--     qilib yutganmi? (to'g'irlash formulasi shunga tayanadi)
-- ---------------------------------------------------------------------
--  Bu yerda 12-avgust va undan keyin delta sync 9010 ga Dt qilgan
--  (ya'ni tushumdan AYIRGAN) summalar filial bo'yicha ko'rinadi.
--  Ular reja jamisiga yaqin bo'lishi kerak. Agar bu ro'yxat BO'SH bo'lsa —
--  delta hech narsa yutmagan, demak to'g'irlash o'rniga sinxronni
--  (sync_transfer_balans) ishlatish kerak. TO'XTANG va aytib qo'ying.
select k.code as filial_kassa, k.name as filial,
       coalesce(c.pul_turi, c.currency) as tur,
       sum(l9.debit) as sotuvdan_ayrilgan,
       count(*)      as yozuvlar
  from entry e
  join entry_line l9 on l9.entry_id = e.id and l9.debit > 0
  join accounts a9   on a9.id = l9.account_id and a9.code = '9010'
  join entry_line lc on lc.entry_id = e.id and lc.credit > 0
  join accounts c    on c.id = lc.account_id
  join accounts k    on k.id = c.parent_id
 where e.source = 'aros_auto' and e.created_by = 'aros_sync'
   and e.is_deleted = false
   and e.created_at >= timestamptz '2026-08-12 00:00:00+05'
 group by k.code, k.name, coalesce(c.pul_turi, c.currency)
 order by k.code, tur;

-- ---------------------------------------------------------------------
-- 1.5 🔴 MAJBURIY — "OLDIN" SURATI (yozishdan oldingi holat)
-- ---------------------------------------------------------------------
--  Avval `do` bloki bu raqamlarni o'zgaruvchida saqlar edi. Endi blok
--  yo'q, shuning uchun ular kichik jadvalga yoziladi va 2.3.4 / 2.3.6
--  tekshiruvlari shu bilan solishtiradi.
--  🔴 BU BLOKNI 2.2 DAN OLDIN RUN QILING — aks holda 2.3.4 va 2.3.6
--     tekshiruvlari ishlamaydi (jadval topilmaydi).
--  🔴 VA 2.2 DAN KEYIN QAYTA RUN QILMANG — u "oldin" holatini yozadi,
--     yozgandan keyin qayta olinsa tekshiruvlar soxta ✅ beradi.
--
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG  ⬇⬇⬇
drop table if exists transfer_tiklash_0812_oldin;

create table transfer_tiklash_0812_oldin as
select now() as olingan_at,
       (select coalesce(sum(case when bolim = 'AKTIV' then amount else 0 end)
                      - sum(case when bolim in ('PASSIV','KAPITAL')
                                 then amount else 0 end), 0)
          from balans(current_date))                            as balans_farqi,
       (select coalesce(sum(l.credit) - sum(l.debit), 0)
          from entry e
          join entry_line l on l.entry_id = e.id
          join accounts a   on a.id = l.account_id and a.code = '9010'
         where e.entry_date = date '2026-08-12'
           and e.status = 'posted' and e.is_deleted = false)     as sof_9010_0812,
       (select count(*) from entry
         where ext_ref like 'aros_tr_fix:%' and is_deleted = false) as fix_yozuvlar;
-- ⬆⬆⬆  1.5 shu yerda tugadi  ⬆⬆⬆

-- 1.5.1 Suratni ko'rish. `balans_farqi` 0 bo'lishi kerak (yozishdan oldin ham).
select * from transfer_tiklash_0812_oldin;


-- #####################################################################
--  2-BOSQICH — DRY-RUN va YOZISH
-- #####################################################################
--  2.1 va 2.2 bloklari BAYT-MA-BAYT bir xil, farqi FAQAT oxirgi argument:
--
--        2.1  →   transfer_tuzatish(p.payload,  **true**  )   PUL YOZMAYDI
--        2.2  →   transfer_tuzatish(p.payload,  **false** )   🔴 PUL YOZADI
--
--  Avval 2.1 ni RUN qiling, natijasini o'qing (`yozuvlar` soni 1.3.1 dagi
--  `yoziladigan_satr` bilan mos, `ogohlantirishlar` kutilgan sabablar) —
--  shundan KEYIN 2.2.
--
--  Ikkala blokdagi ikkita QO'RIQCHI (RPC umuman chaqirilmaydi, agar):
--    • `transfer_tuzatish()` eski versiyada bo'lsa (A1/A2 yamog'i yo'q);
--    • `transfer_tiklash_0812` da 9 qator bo'lmasa (1-BOSQICH RUN qilinmagan
--      yoki reja o'zgargan).
--  CASE tanlanmagan shoxni HISOBLAMAYDI, shuning uchun bu holatlarda RPC
--  chaqirilmaydi va hech narsa yozilmaydi.

-- ---------------------------------------------------------------------
-- 2.1 ⭐ MAJBURIY DRY-RUN — HECH NARSA YOZMAYDI (oxirgi argument: true)
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG (DRY-RUN)  ⬇⬇⬇
with p as (
  select jsonb_build_object('transferlar', jsonb_agg(jsonb_build_object(
           'id',             r.tr_id,
           'sender_title',   r.sender,
           'receiver_title', r.receiver,
           'status',         'received',
           'received_at',    to_char(r.received_at at time zone 'Asia/Tashkent',
                                     'YYYY-MM-DD"T"HH24:MI:SS') || '+05:00',
           'cash',           r.cash,
           'click',          r.click,
           'payme',          r.payme,
           'dollar_usd',     r.dollar_usd,
           'dollar_rate',    r.kurs) order by r.tr_id)) as payload,
         count(*)                                       as n_reja
    from transfer_tiklash_0812 r
),
g as (
  select exists (select 1
                   from pg_proc pr
                   join pg_namespace n on n.oid = pr.pronamespace
                  where n.nspname = 'public'
                    and pr.proname = 'transfer_tuzatish'
                    and pr.prosrc like '%dollar_usd%'
                    and pr.prosrc like '%T00:00:00+05%') as versiya_ok
)
select jsonb_pretty(
         case
           when not g.versiya_ok
             then jsonb_build_object('ok', false, 'error',
                    'transfer_tuzatish() ESKI versiyada — RPC CHAQIRILMADI. '
                    'Avval PROVODKA_TRANSFER_TUZATISH.sql ni RUN qiling.')
           when p.n_reja <> 9
             then jsonb_build_object('ok', false, 'error',
                    'transfer_tiklash_0812 da 9 qator kutilgan edi, hozir '
                    || p.n_reja || ' ta — RPC CHAQIRILMADI. 1-BOSQICHNI RUN qiling.')
           else transfer_tuzatish(p.payload, true)
         end) as natija
  from p cross join g;
-- ⬆⬆⬆  2.1 DRY-RUN shu yerda tugadi  ⬆⬆⬆


-- ---------------------------------------------------------------------
-- 2.2 🔴🔴🔴 YOZISH — HAQIQIY PUL (oxirgi argument: false)
-- ---------------------------------------------------------------------
--  Shartlar (hammasi bajarilsin):
--    • 0.1 ikkala qator ✅ OK
--    • 1.3 PREVIEW da ⛔ YO'Q
--    • 1.5 "oldin" surati olingan
--    • 2.1 DRY-RUN natijasi to'g'ri (ok:true, yozuvlar = kutilgan son)
--    • n8n `Aros Provodka - Transfer Sync` (eAsNswlsZO9VKKAq) DEACTIVATE
--
--  Bitta `select` = bitta tranzaksiya. RPC ichida xato chiqsa (masalan
--  Dt=Kt triggeri, unique ext_ref) — YOZILGAN HAMMA NARSA ORQAGA QAYTADI.
--
-- ⬇⬇⬇  SHU QATORDAN quyidagi `;` GACHA BELGILANG (YOZADI!)  ⬇⬇⬇
with p as (
  select jsonb_build_object('transferlar', jsonb_agg(jsonb_build_object(
           'id',             r.tr_id,
           'sender_title',   r.sender,
           'receiver_title', r.receiver,
           'status',         'received',
           'received_at',    to_char(r.received_at at time zone 'Asia/Tashkent',
                                     'YYYY-MM-DD"T"HH24:MI:SS') || '+05:00',
           'cash',           r.cash,
           'click',          r.click,
           'payme',          r.payme,
           'dollar_usd',     r.dollar_usd,
           'dollar_rate',    r.kurs) order by r.tr_id)) as payload,
         count(*)                                       as n_reja
    from transfer_tiklash_0812 r
),
g as (
  select exists (select 1
                   from pg_proc pr
                   join pg_namespace n on n.oid = pr.pronamespace
                  where n.nspname = 'public'
                    and pr.proname = 'transfer_tuzatish'
                    and pr.prosrc like '%dollar_usd%'
                    and pr.prosrc like '%T00:00:00+05%') as versiya_ok
)
select jsonb_pretty(
         case
           when not g.versiya_ok
             then jsonb_build_object('ok', false, 'error',
                    'transfer_tuzatish() ESKI versiyada — RPC CHAQIRILMADI. '
                    'Avval PROVODKA_TRANSFER_TUZATISH.sql ni RUN qiling.')
           when p.n_reja <> 9
             then jsonb_build_object('ok', false, 'error',
                    'transfer_tiklash_0812 da 9 qator kutilgan edi, hozir '
                    || p.n_reja || ' ta — RPC CHAQIRILMADI. 1-BOSQICHNI RUN qiling.')
           else transfer_tuzatish(p.payload, false)
         end) as natija
  from p cross join g;
-- ⬆⬆⬆  2.2 YOZISH shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  2.3 — O'ZINI TEKSHIRUVLAR (yozgandan KEYIN).  HECH BIRI YOZMAYDI.
-- #####################################################################
--  Avval `do` bloki bularni ichkarida bajarib, mos kelmasa `raise exception`
--  bilan orqaga qaytarardi. Endi ular ALOHIDA `select` — natija ustuniga
--  qarang: hammasi ✅ OK bo'lsa ish tugadi. Bittasi ham
--  "❌ MUAMMO — ROLLBACK qiling" bo'lsa → 4-BOSQICH (rollback) ni bajaring.
--  Har tekshiruvni ALOHIDA belgilab RUN qiling.

-- ---------------------------------------------------------------------
-- ⚠️ 2.3.1 ALOHIDA belgilab RUN qiling — YOZUVLAR SONI rejadagidek bo'lsin.
--    Ko'rsatadi: reja bo'yicha nechta satr yozilishi kerak edi va bazada
--    nechta `aros_tr_fix:` yozuv paydo bo'ldi.
-- ---------------------------------------------------------------------
with turlar(maydon, tur) as (
  values ('cash', 'naqd'), ('click', 'click'),
         ('payme', 'payme'), ('dollar_usd', 'dollar')
),
qator as (
  select r.tr_id, r.received_at, r.kurs, t.maydon, t.tur,
         case t.maydon
           when 'cash'  then r.cash
           when 'click' then r.click
           when 'payme' then r.payme
           else r.dollar_usd
         end as miqdor
    from transfer_tiklash_0812 r
   cross join turlar t
),
reja as (
  select count(*) as n
    from qator q
   where q.miqdor > 0
     and q.received_at <= (aros_transfer_cutoff() ->> 'cutoff')::timestamptz
     and not exists (select 1 from entry e
                      where e.ext_ref = 'aros_tr:' || q.tr_id || ':' || q.maydon)
),
haqiqiy as (
  select count(*) as n
    from entry e
   where e.is_deleted = false
     and e.ext_ref in (select 'aros_tr_fix:' || q.tr_id || ':' || q.tur from qator q)
)
select 'Yozuvlar soni = reja' as tekshiruv,
       r.n as kutilgan, h.n as yozilgan,
       case when h.n = r.n then '✅ OK'
            else '❌ MUAMMO — ROLLBACK qiling' end as natija,
       case when h.n = r.n then 'Reja bo''yicha hamma satr yozildi'
            else 'RPC javobidagi `ogohlantirishlar` ni o''qing: kassa topilmagan, '
                 'tur hisobi yo''q yoki cutoff to''sgan bo''lishi mumkin' end as izoh
  from reja r cross join haqiqiy h;

-- ---------------------------------------------------------------------
-- ⚠️ 2.3.2 ALOHIDA belgilab RUN qiling — HAR YOZUVDA Dt = Kt.
--    Ko'rsatadi: muvozanatsiz (Dt<>Kt) yozuvlar soni — 0 bo'lishi shart.
-- ---------------------------------------------------------------------
with turlar(tur) as (values ('naqd'), ('click'), ('payme'), ('dollar')),
kalit as (
  select 'aros_tr_fix:' || r.tr_id || ':' || t.tur as ext
    from transfer_tiklash_0812 r cross join turlar t
),
nomutanosib as (
  select count(*) as n
    from (select e.id
            from entry e
            join entry_line l on l.entry_id = e.id
           where e.ext_ref in (select ext from kalit)
             and e.is_deleted = false
           group by e.id
          having sum(l.debit) <> sum(l.credit)) x
)
select 'Har yozuvda Dt = Kt' as tekshiruv,
       n as muvozanatsiz_yozuv,
       case when n = 0 then '✅ OK'
            else '❌ MUAMMO — ROLLBACK qiling' end as natija
  from nomutanosib;

-- ---------------------------------------------------------------------
-- ⚠️ 2.3.3 ALOHIDA belgilab RUN qiling — Kt 9010 jami = Dt jami.
--    Ko'rsatadi: to'g'irlash yozuvlarida markaziy kassalarga tushgan Dt
--    jamisi va 9010 ga yozilgan Kt jamisi — TENG bo'lishi shart.
-- ---------------------------------------------------------------------
with turlar(tur) as (values ('naqd'), ('click'), ('payme'), ('dollar')),
kalit as (
  select 'aros_tr_fix:' || r.tr_id || ':' || t.tur as ext
    from transfer_tiklash_0812 r cross join turlar t
),
dt as (
  select coalesce(sum(l.debit), 0) as s
    from entry e
    join entry_line l on l.entry_id = e.id and l.debit > 0
   where e.ext_ref in (select ext from kalit) and e.is_deleted = false
),
kt as (
  select coalesce(sum(l.credit), 0) as s
    from entry e
    join entry_line l on l.entry_id = e.id and l.credit > 0
    join accounts a   on a.id = l.account_id and a.code = '9010'
   where e.ext_ref in (select ext from kalit) and e.is_deleted = false
)
select 'Kt 9010 = Dt jami' as tekshiruv,
       dt.s as dt_jami, kt.s as kt_9010, kt.s - dt.s as farq,
       case when abs(kt.s - dt.s) <= 0.01 then '✅ OK'
            else '❌ MUAMMO — ROLLBACK qiling' end as natija
  from dt cross join kt;

-- ---------------------------------------------------------------------
-- ⚠️ 2.3.4 ALOHIDA belgilab RUN qiling — BALANS TENGLIGI (oldin/keyin).
--    Ko'rsatadi: AKTIV − (PASSIV+KAPITAL) farqi yozishdan OLDIN (1.5 surati)
--    va HOZIR. Ikkalasi ham 0 bo'lishi va o'zgarmasligi shart.
-- ---------------------------------------------------------------------
with keyin as (
  select coalesce(sum(case when bolim = 'AKTIV' then amount else 0 end)
                - sum(case when bolim in ('PASSIV','KAPITAL')
                           then amount else 0 end), 0) as farq
    from balans(current_date)
)
select 'Balans tengligi (oldin/keyin)' as tekshiruv,
       o.balans_farqi as farq_oldin, k.farq as farq_keyin,
       case when abs(k.farq) <= 0.01
             and abs(k.farq - o.balans_farqi) <= 0.01 then '✅ OK'
            else '❌ MUAMMO — ROLLBACK qiling' end as natija,
       'Ikkala farq ham 0 va bir xil bo''lishi shart' as izoh
  from transfer_tiklash_0812_oldin o cross join keyin k;

-- ---------------------------------------------------------------------
-- ⚠️ 2.3.5 ALOHIDA belgilab RUN qiling — JAMI SUMMA = REJA.
--    Ko'rsatadi: reja bo'yicha kutilgan so'm va haqiqatan yozilgan so'm.
--    Qo'shimcha: Asilbek aytgan mo'ljal (352 068 000) bilan farq —
--    u FAQAT ma'lumot uchun, natijaga ta'sir qilmaydi.
-- ---------------------------------------------------------------------
with turlar(maydon, tur) as (
  values ('cash', 'naqd'), ('click', 'click'),
         ('payme', 'payme'), ('dollar_usd', 'dollar')
),
qator as (
  select r.tr_id, r.received_at, r.kurs, t.maydon, t.tur,
         case t.maydon
           when 'cash'  then r.cash
           when 'click' then r.click
           when 'payme' then r.payme
           else r.dollar_usd
         end as miqdor
    from transfer_tiklash_0812 r
   cross join turlar t
),
reja as (
  select coalesce(sum(case when q.maydon = 'dollar_usd'
                           then round(q.miqdor * q.kurs, 2)
                           else q.miqdor end), 0) as s
    from qator q
   where q.miqdor > 0
     and q.received_at <= (aros_transfer_cutoff() ->> 'cutoff')::timestamptz
     and not exists (select 1 from entry e
                      where e.ext_ref = 'aros_tr:' || q.tr_id || ':' || q.maydon)
),
haqiqiy as (
  select coalesce(sum(l.debit), 0) as s
    from entry e
    join entry_line l on l.entry_id = e.id and l.debit > 0
   where e.is_deleted = false
     and e.ext_ref in (select 'aros_tr_fix:' || q.tr_id || ':' || q.tur from qator q)
)
select 'Jami summa = reja' as tekshiruv,
       r.s as reja_uzs, h.s as yozilgan_uzs, h.s - r.s as farq,
       352068000 as moljal, h.s - 352068000 as moljal_farqi,
       case when abs(h.s - r.s) <= 0.01 then '✅ OK'
            else '❌ MUAMMO — ROLLBACK qiling' end as natija
  from reja r cross join haqiqiy h;

-- ---------------------------------------------------------------------
-- ⚠️ 2.3.6 ALOHIDA belgilab RUN qiling — P&L GA TO'G'RI TUSHDIMI.
--    Ko'rsatadi: 12-avgust kuni 9010 (savdo tushumi) sof qoldig'i
--    yozishdan OLDIN va HOZIR. Farq AYNAN yozilgan jami summaga teng
--    bo'lishi shart (delta sync ayirib qo'ygan minus qaytarildi, ortiqcha
--    tushum PAYDO BO'LMADI).
-- ---------------------------------------------------------------------
with turlar(tur) as (values ('naqd'), ('click'), ('payme'), ('dollar')),
kalit as (
  select 'aros_tr_fix:' || r.tr_id || ':' || t.tur as ext
    from transfer_tiklash_0812 r cross join turlar t
),
yozilgan as (
  select coalesce(sum(l.debit), 0) as s
    from entry e
    join entry_line l on l.entry_id = e.id and l.debit > 0
   where e.ext_ref in (select ext from kalit) and e.is_deleted = false
),
keyin as (
  select coalesce(sum(l.credit) - sum(l.debit), 0) as sof
    from entry e
    join entry_line l on l.entry_id = e.id
    join accounts a   on a.id = l.account_id and a.code = '9010'
   where e.entry_date = date '2026-08-12'
     and e.status = 'posted' and e.is_deleted = false
)
select 'P&L — 9010 sof tushum (12-avgust)' as tekshiruv,
       o.sof_9010_0812 as sof_oldin, k.sof as sof_keyin,
       k.sof - o.sof_9010_0812 as osdi, y.s as yozilgan_jami,
       case when abs((k.sof - o.sof_9010_0812) - y.s) <= 0.01 then '✅ OK'
            else '❌ MUAMMO — ROLLBACK qiling' end as natija,
       'osdi = yozilgan_jami bo''lsin. Farq bo''lsa: oradan boshqa yozuv '
       'tushgan (sinxron?) — avval shuni tekshiring' as izoh
  from transfer_tiklash_0812_oldin o cross join keyin k cross join yozilgan y;

-- ---------------------------------------------------------------------
-- ⚠️ 2.3.7 ALOHIDA belgilab RUN qiling — 🔴 IKKI MARTA YOZILMADIMI.
--    Ko'rsatadi: har (transfer × tur) uchun sinxron kaliti (`aros_tr:`)
--    VA to'g'irlash kaliti (`aros_tr_fix:`) BIR VAQTDA bormi, hamda bitta
--    fix kalitiga bir nechta yozuv bormi. Ikkalasi ham 0 bo'lishi SHART.
-- ---------------------------------------------------------------------
with turlar(maydon, tur) as (
  values ('cash', 'naqd'), ('click', 'click'),
         ('payme', 'payme'), ('dollar_usd', 'dollar')
),
qator as (
  select r.tr_id, t.maydon, t.tur,
         'aros_tr:'     || r.tr_id || ':' || t.maydon as sync_kalit,
         'aros_tr_fix:' || r.tr_id || ':' || t.tur    as fix_kalit
    from transfer_tiklash_0812 r
   cross join turlar t
),
ikkilangan as (
  select count(*) as n
    from qator q
   where exists (select 1 from entry e
                  where e.ext_ref = q.sync_kalit and e.is_deleted = false)
     and exists (select 1 from entry e
                  where e.ext_ref = q.fix_kalit  and e.is_deleted = false)
),
takror as (
  select count(*) as n
    from (select e.ext_ref
            from entry e
           where e.ext_ref in (select fix_kalit from qator)
             and e.is_deleted = false
           group by e.ext_ref
          having count(*) > 1) x
)
select 'Ikki marta yozilmadi' as tekshiruv,
       i.n as sync_va_fix_birga, t.n as takrorlangan_fix_kalit,
       case when i.n = 0 and t.n = 0 then '✅ OK'
            else '❌ MUAMMO — ROLLBACK qiling' end as natija,
       'sync_va_fix_birga > 0 = bitta pul ikki marta yozilgan (ENG XAVFLISI)' as izoh
  from ikkilangan i cross join takror t;

-- ---------------------------------------------------------------------
-- ⚠️ 2.3.8 ALOHIDA belgilab RUN qiling — FILIAL TOMONIGA TEGILMADIMI.
--    Ko'rsatadi: to'g'irlash yozuvlarida filial kassasiga (yoki uning
--    bola-hisobiga) tushgan satrlar soni — 0 bo'lishi SHART.
--    Dt faqat MARKAZIY kassa turi, Kt faqat 9010 bo'lishi kerak.
-- ---------------------------------------------------------------------
with turlar(tur) as (values ('naqd'), ('click'), ('payme'), ('dollar')),
kalit as (
  select 'aros_tr_fix:' || r.tr_id || ':' || t.tur as ext
    from transfer_tiklash_0812 r cross join turlar t
),
satr as (
  select a.code, a.name, a.kassa_turi, p.kassa_turi as parent_turi
    from entry e
    join entry_line l on l.entry_id = e.id
    join accounts a   on a.id = l.account_id
    left join accounts p on p.id = a.parent_id
   where e.ext_ref in (select ext from kalit) and e.is_deleted = false
)
select 'Filial tomoniga tegilmadi' as tekshiruv,
       count(*) filter (where s.kassa_turi = 'filial'
                           or s.parent_turi = 'filial') as filial_satrlar,
       count(*) as jami_satr,
       case when count(*) filter (where s.kassa_turi = 'filial'
                                    or s.parent_turi = 'filial') = 0
            then '✅ OK'
            else '❌ MUAMMO — ROLLBACK qiling' end as natija
  from satr s;


-- #####################################################################
--  3-BOSQICH — NATIJA TEKSHIRUVI (faqat o'qiydi)
-- #####################################################################

-- 3.1 Yozilgan to'g'irlashlar
select e.ext_ref, e.entry_date, e.description,
       a.code, a.name, l.debit, l.credit, l.fc_amount, e.fc_rate
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a   on a.id = l.account_id
 where e.ext_ref like 'aros_tr_fix:%'
   and split_part(e.ext_ref, ':', 2) in
       ('1148','1165','1166','1167','1168','1169','1170','1171','1174')
   and e.is_deleted = false
 order by e.ext_ref, l.debit desc;

-- 3.2 Markaziy kassalar qoldig'i (12-avgustdan oldingi holat bilan solishtiring)
select k.code as kassa, k.name, c.code as hisob,
       coalesce(c.pul_turi, c.currency) as tur,
       coalesce((select sum(l.debit - l.credit)
                   from entry_line l
                   join entry e on e.id = l.entry_id
                  where l.account_id = c.id
                    and e.status = 'posted' and e.is_deleted = false), 0) as qoldiq
  from accounts k
  join accounts c on c.parent_id = k.id and c.is_active
 where k.code in ('5011','5012','5110')
 order by k.code, c.code;

-- 3.3 Balans tenglikda (farq = 0 bo'lishi SHART)
select sum(case when bolim = 'AKTIV' then amount else 0 end)
     - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end) as farq
  from balans(current_date);

-- 3.4 P&L ga ta'siri — 12-avgust kuni 9010 bo'yicha sof tushum
--     (delta sync ayirgan minus qaytarilgani ko'rinadi)
select sum(l.credit) as kt_9010,
       sum(l.debit)  as dt_9010,
       sum(l.credit) - sum(l.debit) as sof_tushum
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a   on a.id = l.account_id and a.code = '9010'
 where e.entry_date = date '2026-08-12'
   and e.status = 'posted' and e.is_deleted = false;

-- 3.5 ⭐ FILIAL TOMONI O'ZGARMAGANINI tasdiqlash — eng muhim tekshiruv.
--     To'g'irlash filialga TEGMAYDI, ya'ni keyingi delta sync baribir
--     0 qaytarishi kerak. n8n "Auto Sync" ni QAYTA YOQIB bir marta
--     ishlatib, uning sync_filial_balans natijasida "yozuvlar": 0
--     ekanini ko'ring. (Aros balansi shu orada o'zgargan bo'lsa farq
--     bo'lishi tabiiy.)

-- 3.6 🔴 n8n `Aros Provodka - Transfer Sync` (eAsNswlsZO9VKKAq) ni
--     QAYTA ACTIVATE QILISHNI UNUTMANG.


-- #####################################################################
--  4-BOSQICH — ROLLBACK (2.3.x da ❌ chiqsa)
-- #####################################################################
--  Avval `do` bloki xato bo'lsa o'zi orqaga qaytarardi. Endi yozish
--  alohida `select` bo'lgani uchun ROLLBACK QO'LDA bajariladi —
--  quyidagi ikki qadam bilan.
--
--  To'g'irlash oddiy yozuv: soft-delete yetadi (hech narsa o'chirilmaydi).
--  Faqat SHU 9 ta transferning to'g'irlashlarini qaytaradi — boshqa
--  `aros_tr_fix:` yozuvlariga tegmaydi.

-- ---------------------------------------------------------------------
-- 4.1 AVVAL KO'RING — nima qaytariladi (bu select xavfsiz, yozmaydi)
-- ---------------------------------------------------------------------
select e.id, e.ext_ref, e.entry_date, e.description,
       (select sum(l.debit) from entry_line l where l.entry_id = e.id) as summa
  from entry e
 where e.ext_ref like 'aros_tr_fix:%'
   and split_part(e.ext_ref, ':', 2) in
       ('1148','1165','1166','1167','1168','1169','1170','1171','1174')
   and e.is_deleted = false
 order by e.ext_ref;

-- ---------------------------------------------------------------------
-- 4.2 ROLLBACK — quyidagi 8 qatorning har birining boshidagi `-- ` ni
--     olib tashlang va BELGILAB RUN qiling. Tasodifan RUN bo'lmasin
--     uchun ataylab izohda turibdi.
-- ---------------------------------------------------------------------
-- ⬇⬇⬇  ROLLBACK — izohni olib tashlagach shu oraliqni belgilang  ⬇⬇⬇
-- update entry
--    set is_deleted = true,
--        deleted_at = now(),
--        deleted_by_name = 'transfer tiklash 12-08 qaytarildi'
--  where ext_ref like 'aros_tr_fix:%'
--    and split_part(ext_ref, ':', 2) in
--        ('1148','1165','1166','1167','1168','1169','1170','1171','1174')
--    and is_deleted = false;
-- ⬆⬆⬆  ROLLBACK shu yerda tugadi  ⬆⬆⬆

-- ---------------------------------------------------------------------
-- 4.3 Rollbackdan keyin tekshirish: balans farqi yana 0 bo'lsin,
--     4.1 bo'sh natija bersin.
-- ---------------------------------------------------------------------
-- select sum(case when bolim = 'AKTIV' then amount else 0 end)
--      - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end) as farq
--   from balans(current_date);

-- ⚠️ Qaytargandan keyin QAYTA yozmoqchi bo'lsangiz: 1-himoya (ext_ref)
--    o'chirilgan yozuvni HAM ko'radi va ikkinchi marta yozdirmaydi.
--    Shuning uchun qayta yozish uchun avval o'sha qatorlarni butunlay
--    o'chirish kerak (`delete from entry ...`) — buni faqat ongli ravishda,
--    Asilbek bilan kelishib qiling.
