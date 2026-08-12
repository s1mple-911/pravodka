-- =====================================================================
--  ⚠️⚠️  SUPABASE SQL EDITOR — QANDAY RUN QILINADI (avval SHUNI o'qing)
-- ---------------------------------------------------------------------
--   1) Tartib: 0-BOSQICH → 1-BOSQICH (jadval + PREVIEW) → preview TOZA
--      bo'lsa → 2-BOSQICH (pul yozadi) → 3-BOSQICH (natija).
--      BUTUN FAYLNI BIRDANIGA RUN QILMANG — 2-BOSQICH haqiqiy pul yozadi.
--   2) Har bo'lak ⬇⬇⬇ va ⬆⬆⬆ belgilari orasida — AYNAN o'sha oraliqni
--      belgilab RUN qiling.
--   3) `do $$` blokini TO'LIQ belgilash SHART: `do $$` qatoridan `$$;`
--      qatorigacha, ikkalasi ham ichida. Yarim belgilansa Postgres blokni
--      PL/pgSQL emas, oddiy SQL deb o'qiydi va o'zgaruvchini jadval deb izlaydi.
--   4) O'shanda chiqadigan xato — `ERROR: 42P01: relation "v_payload" does
--      not exist` (yoki boshqa `v_...` nomi). Bu FAYL XATOSI EMAS, belgilash
--      noto'g'ri: blokni boshidan oxirigacha qayta belgilab RUN qiling.
--   5) Faylda NOMLANGAN dollar-teg (dollar + nom + dollar ko'rinishi) YO'Q —
--      faqat oddiy `$$`. Ichma-ich dollar-quote ham yo'q.
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
--  YOZISH XAVFI. Shuning uchun 0-BOSQICH va 2-BOSQICH ikkalasi ham RPC
--  versiyasini tekshiradi va eski bo'lsa TO'XTAYDI.
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
--  So'm qismi: 339 625 000. Dollar: 1100 $ (kurs bilan ≈ 13 210 000).
--  JAMI ≈ 352 835 000 so'm. Skript haqiqiy jamini oxirida chiqaradi va
--  Asilbek aytgan mo'ljal (352 068 000) bilan farqini ko'rsatadi —
--  farq bo'lsa DARROV ko'rinadi (2-BOSQICH bekor qilinmaydi, faqat
--  ogohlantiradi: mo'ljal taxminiy, reja jadvalidagi raqamlar aniq).
--
--  🔴 11-avgustgacha bo'lgan transferlar TIKLANMAYDI — ular boshlang'ich
--     kapitalga kirgan (11-avgust kechqurun). Reja jadvalida faqat 12-avgust.
--
--  #####  NEGA IKKI MARTA YOZILMAYDI  ##################################
--     1. `aros_tr_fix:<id>:<tur>` — UNIQUE ext_ref. Skriptni ikki marta
--        RUN qilsang ikkinchisi 0 yozuv qiladi.
--     2. `aros_tr:<id>:<maydon>` — sinxron o'sha transferni oradan
--        yozib qo'ygan bo'lsa, tuzatish o'sha turni O'TKAZIB YUBORADI.
--        (Aynan shu himoya A1 da tuzatildi.)
--     3. CUTOFF — received_at cutoff'dan keyin bo'lsa tegilmaydi
--        (uni sinxronning o'zi yozadi).
--     + PREVIEW: yozishdan oldin har satr uchun qaror ko'rinadi.
--     + 2-BOSQICH: bitta tranzaksiya, o'zini tekshiradi, mos kelmasa
--        `raise exception` bilan HAMMASI ORQAGA QAYTADI.
--
--  TALAB: PROVODKA_TRANSFER.sql (aros_kassa_topish, aros_tur_hisob,
--         aros_transfer_cutoff), PROVODKA_TRANSFER_TUZATISH.sql (tuzatilgan).
--
--  ADDITIVE: mavjud jadval/ustun/funksiya/view o'zgartirilmaydi. Yangi
--  jadval `transfer_tiklash_0812` — SHU skriptning o'z jadvali.
-- =====================================================================


-- #####################################################################
--  0-BOSQICH — SHART-SHAROIT TEKSHIRUVI.  HECH NARSA YOZMAYDI.
-- #####################################################################

-- 0.1 `transfer_tuzatish()` TUZATILGAN versiyadami?
--     Ikkala qator ham "OK" bo'lishi SHART. Aks holda avval
--     PROVODKA_TRANSFER_TUZATISH.sql ni RUN qiling.
select 'A1 — sinxron kaliti (dollar_usd)' as tekshiruv,
       case when p.prosrc like '%dollar_usd%' then 'OK'
            else 'ESKI VERSIYA — RUN QILMANG' end as holat
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'transfer_tuzatish'
union all
select 'A2 — vaqt zonasi normalizatsiyasi (+05)',
       case when p.prosrc like '%T00:00:00+05%' then 'OK'
            else 'ESKI VERSIYA — RUN QILMANG' end
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
--  1-BOSQICH — REJA JADVALI + PREVIEW.  PUL YOZMAYDI.
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
--       (`do` bloki yo'q — oddiy DDL/DML, birdaniga RUN qilinadi)
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
--  🔴 ⛔ belgisi bo'lgan bitta qator bo'lsa ham — 2-BOSQICHNI RUN QILMANG.
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

-- 1.3.1 Preview yakuni — nechta yoziladi, jami qancha
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
-- 1.4 RPC ning O'Z quruq yugurishi (p_dry_run = true) — pul yozmaydi
-- ---------------------------------------------------------------------
--  `yozuvlar` soni 1.3.1 dagi `yoziladigan_satr` bilan MOS kelishi kerak.
--  `ogohlantirishlar` bo'sh yoki faqat kutilgan sabablar bo'lsin.
select jsonb_pretty(transfer_tuzatish(
  (select jsonb_build_object('transferlar', jsonb_agg(jsonb_build_object(
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
            'dollar_rate',    r.kurs) order by r.tr_id))
     from transfer_tiklash_0812 r),
  true));

-- ---------------------------------------------------------------------
-- 1.5 ⭐ MANTIQIY TEKSHIRUV — delta bu pulni haqiqatan "savdo minus"
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


-- #####################################################################
--  2-BOSQICH — 🔴 HAQIQIY PUL YOZADI.  Faqat preview TOZA bo'lsa.
-- #####################################################################
--  Bitta tranzaksiya: blok ichida biror tekshiruv yiqilsa `raise exception`
--  bo'ladi va YOZILGAN HAMMA NARSA ORQAGA QAYTADI (hech narsa qolmaydi).
--
--  Blok o'zi tekshiradigan narsalar:
--    1. `transfer_tuzatish()` TUZATILGAN versiyadami (A1 + A2)
--    2. reja jadvali bo'sh emasmi
--    3. RPC `ok:true` qaytardimi
--    4. yozilgan satrlar soni REJADAGI kutilgan son bilan mos keldimi
--    5. har yozuvda Dt = Kt
--    6. balans tenglikdan chiqmadimi (oldin/keyin farqi o'zgarmasin)
--    7. jami summa — reja bilan mos, mo'ljal bilan farqi ko'rsatiladi
--
-- ⬇⬇⬇  SHU QATORDAN quyidagi `$$;` QATORIGACHA BELGILANG  ⬇⬇⬇
do $$
declare
  v_payload      jsonb;
  v_res          jsonb;
  v_kalitlar     text[];
  v_n_kutilgan   int;
  v_kutilgan     numeric;
  v_n_yozildi    int;
  v_n_entry      int;
  v_haqiqiy      numeric;
  v_kt9010       numeric;
  v_farq_oldin   numeric;
  v_farq_keyin   numeric;
  v_nomutanosib  int;
  v_r            record;
begin
  -- ---- 1) Tuzatilgan RPC ligini tekshirish -------------------------
  if not exists (select 1
                   from pg_proc p
                   join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public'
                    and p.proname = 'transfer_tuzatish'
                    and p.prosrc like '%dollar_usd%'
                    and p.prosrc like '%T00:00:00+05%') then
    raise exception 'transfer_tuzatish() ESKI versiyada — hech narsa yozilmadi'
      using hint = 'Avval PROVODKA_TRANSFER_TUZATISH.sql ni RUN qiling. Eski '
                   'versiyada 2-himoya naqd/dollar uchun ishlamaydi va vaqt '
                   'zonasi 5 soat siljiydi — pul ikki marta yozilishi mumkin.';
  end if;

  -- ---- 2) Reja -> payload -------------------------------------------
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
           'dollar_rate',    r.kurs) order by r.tr_id))
    into v_payload
    from transfer_tiklash_0812 r;

  if v_payload is null or jsonb_typeof(v_payload -> 'transferlar') <> 'array' then
    raise exception 'transfer_tiklash_0812 jadvali bo''sh — avval 1-BOSQICHNI RUN qiling';
  end if;

  -- ---- 3) Kutilgan natija (yozishdan OLDIN hisoblanadi) --------------
  with turlar(maydon, tur) as (
    values ('cash', 'naqd'), ('click', 'click'),
           ('payme', 'payme'), ('dollar_usd', 'dollar')
  ),
  qator as (
    select r.tr_id, r.kurs, t.maydon, t.tur,
           case t.maydon
             when 'cash'  then r.cash
             when 'click' then r.click
             when 'payme' then r.payme
             else r.dollar_usd
           end as miqdor
      from transfer_tiklash_0812 r
     cross join turlar t
  )
  select count(*),
         coalesce(sum(case when q.maydon = 'dollar_usd'
                           then round(q.miqdor * q.kurs, 2)
                           else q.miqdor end), 0)
    into v_n_kutilgan, v_kutilgan
    from qator q
   where q.miqdor > 0
     and not exists (select 1 from entry e
                      where e.ext_ref = 'aros_tr:' || q.tr_id || ':' || q.maydon)
     and not exists (select 1 from entry e
                      where e.ext_ref = 'aros_tr_fix:' || q.tr_id || ':' || q.tur);

  select array_agg('aros_tr_fix:' || r.tr_id || ':' || t.tur)
    into v_kalitlar
    from transfer_tiklash_0812 r
   cross join (values ('naqd'), ('click'), ('payme'), ('dollar')) t(tur);

  -- Balans farqi — YOZISHDAN OLDIN
  select coalesce(sum(case when bolim = 'AKTIV' then amount else 0 end)
                - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end), 0)
    into v_farq_oldin
    from balans(current_date);

  raise notice 'Kutilmoqda: % ta yozuv, jami % so''m', v_n_kutilgan, v_kutilgan;

  if v_n_kutilgan = 0 then
    raise notice 'Yozadigan narsa yo''q — hammasi allaqachon yozilgan. To''xtatildi.';
    return;
  end if;

  -- ---- 4) YOZISH -----------------------------------------------------
  v_res := transfer_tuzatish(v_payload, false);

  if not coalesce((v_res ->> 'ok')::boolean, false) then
    raise exception 'transfer_tuzatish() xato qaytardi: %',
                    coalesce(v_res ->> 'error', '(sababsiz)')
      using hint = 'Hech narsa yozilmadi (tranzaksiya orqaga qaytdi).';
  end if;

  v_n_yozildi := coalesce((v_res ->> 'yozuvlar')::int, 0);

  -- ---- 5) O'ZINI TEKSHIRISH -----------------------------------------
  -- 5.1 Soni rejadagidek bo'lsin
  if v_n_yozildi <> v_n_kutilgan then
    raise exception 'Yozuvlar soni mos kelmadi: yozildi %, kutilgan %',
                    v_n_yozildi, v_n_kutilgan
      using hint = 'HAMMASI ORQAGA QAYTARILDI. 1.3 PREVIEW ni qayta ko''ring: '
                   'kassa topilmagan, tur hisobi yo''q yoki cutoff to''sgan '
                   'bo''lishi mumkin (RPC javobidagi ogohlantirishlar).';
  end if;

  -- 5.2 Haqiqiy yozilgan summa va yozuvlar
  select count(distinct e.id), coalesce(sum(l.debit), 0)
    into v_n_entry, v_haqiqiy
    from entry e
    join entry_line l on l.entry_id = e.id and l.debit > 0
   where e.ext_ref = any(v_kalitlar)
     and e.is_deleted = false;

  -- 5.3 Dt = Kt (har yozuvda)
  select count(*)
    into v_nomutanosib
    from (select e.id
            from entry e
            join entry_line l on l.entry_id = e.id
           where e.ext_ref = any(v_kalitlar)
             and e.is_deleted = false
           group by e.id
          having sum(l.debit) <> sum(l.credit)) x;

  if v_nomutanosib > 0 then
    raise exception 'Dt <> Kt bo''lgan yozuv topildi: % ta', v_nomutanosib
      using hint = 'HAMMASI ORQAGA QAYTARILDI.';
  end if;

  -- 5.4 9010 ga Kt — Dt bilan teng bo'lishi kerak (har yozuv 2 satrli)
  select coalesce(sum(l.credit), 0)
    into v_kt9010
    from entry e
    join entry_line l on l.entry_id = e.id and l.credit > 0
    join accounts a   on a.id = l.account_id and a.code = '9010'
   where e.ext_ref = any(v_kalitlar)
     and e.is_deleted = false;

  if v_kt9010 <> v_haqiqiy then
    raise exception 'Kt 9010 (%) Dt jamisiga (%) teng emas', v_kt9010, v_haqiqiy
      using hint = 'HAMMASI ORQAGA QAYTARILDI.';
  end if;

  -- 5.5 Balans tenglikdan chiqmadimi
  select coalesce(sum(case when bolim = 'AKTIV' then amount else 0 end)
                - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end), 0)
    into v_farq_keyin
    from balans(current_date);

  if abs(v_farq_keyin - v_farq_oldin) > 0.01 then
    raise exception 'Balans tenglikdan chiqdi: oldin %, keyin %',
                    v_farq_oldin, v_farq_keyin
      using hint = 'HAMMASI ORQAGA QAYTARILDI.';
  end if;

  -- 5.6 Reja summasi bilan mos kelsinmi
  if abs(v_haqiqiy - v_kutilgan) > 0.01 then
    raise exception 'Yozilgan summa (%) reja summasidan (%) farq qildi',
                    v_haqiqiy, v_kutilgan
      using hint = 'HAMMASI ORQAGA QAYTARILDI.';
  end if;

  -- ---- 6) HISOBOT ----------------------------------------------------
  raise notice '--------------------------------------------------------';
  for v_r in select e.ext_ref, e.entry_date, a.code, a.name, l.debit, l.fc_amount
               from entry e
               join entry_line l on l.entry_id = e.id and l.debit > 0
               join accounts a   on a.id = l.account_id
              where e.ext_ref = any(v_kalitlar)
                and e.is_deleted = false
              order by e.ext_ref
  loop
    raise notice '% | % | % % | Dt % | usd %',
                 v_r.ext_ref, v_r.entry_date, v_r.code, v_r.name,
                 v_r.debit, coalesce(v_r.fc_amount, 0);
  end loop;
  raise notice '--------------------------------------------------------';
  raise notice 'YOZILDI: % ta yozuv (entry: %)', v_n_yozildi, v_n_entry;
  raise notice 'JAMI: % so''m (Dt markaziy kassalar = Kt 9010)', v_haqiqiy;
  raise notice 'MO''LJAL: 352068000 so''m · FARQ: %', v_haqiqiy - 352068000;
  raise notice 'Balans farqi: oldin % -> keyin % (o''zgarmasligi shart)',
               v_farq_oldin, v_farq_keyin;
  raise notice 'P&L: 9010 ga Kt % so''m qo''shildi', v_kt9010;
  raise notice 'Tugadi.'
    using hint = 'P&L SHISHMAYDI: delta sync o''sha summani 9010 dan Dt qilib '
                 'AYIRIB qo''ygan edi (1.5 tekshiruvi), bu yozuv o''shani '
                 'qaytaradi. Filial tomoniga tegilmadi. Keyingi delta sync '
                 'baribir 0 qaytarishi kerak.';
end $$;
-- ⬆⬆⬆  2-BOSQICH shu yerda tugadi  ⬆⬆⬆


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
--     0 qaytarishi kerak. n8n "Auto Sync" ni bir marta ishlatib, uning
--     sync_filial_balans natijasida "yozuvlar": 0 ekanini ko'ring.
--     (Aros balansi shu orada o'zgargan bo'lsa farq bo'lishi tabiiy.)


-- #####################################################################
--  4. ROLLBACK — xato bo'lsa qaytarish
-- #####################################################################
--  To'g'irlash oddiy yozuv: soft-delete yetadi (hech narsa o'chirilmaydi).
--  Faqat SHU 9 ta transferning to'g'irlashlarini qaytaradi — boshqa
--  `transfer_fix` yozuvlariga tegmaydi.
--
--  ⚠️ Qaytargandan keyin qayta yozmoqchi bo'lsang: 1-himoya (ext_ref)
--     o'chirilgan yozuvni ham ko'radi va IKKINCHI marta yozdirmaydi.
--     Shuning uchun qayta yozish uchun avval o'sha qatorlarni butunlay
--     o'chirish kerak (`delete from entry ...`) — buni faqat ongli ravishda,
--     Asilbek bilan kelishib qiling.
--
-- update entry
--    set is_deleted = true,
--        deleted_at = now(),
--        deleted_by_name = 'transfer tiklash 12-08 qaytarildi'
--  where ext_ref like 'aros_tr_fix:%'
--    and split_part(ext_ref, ':', 2) in
--        ('1148','1165','1166','1167','1168','1169','1170','1171','1174')
--    and is_deleted = false;
