-- =====================================================================
--  PROVODKA_TRANSFER_CUTOFF_FIX.sql
--  Transfer sinxroni: "bir sikl kechikkan transfer ABADIY yo'qoladi"
--  muammosining ILDIZ yechimi.
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--  Talab:   PROVODKA_TRANSFER.sql (sync_transfer_balans, aros_transfer_cutoff,
--           aros_kassa_topish, aros_tur_hisob) allaqachon RUN qilingan.
--
--  ⛔ BU FAYLDA BIRORTA ANONIM `do` BLOKI YO'Q — Supabase SQL editor
--     ularni ishlata olmaydi. Hamma mantiq funksiya ichida, hamma tekshiruv
--     oddiy `select`. Har bo'lak ⬇⬇⬇ bilan boshlanadi, ⬆⬆⬆ bilan tugaydi.
--
--  ⚠️ HECH NARSANI O'ZINGIZ EMAS — bosqichma-bosqich RUN qiling:
--     0-BOSQICH (faqat select, hech narsa yozmaydi)  -> natijani o'qing
--     1-BOSQICH (jadval + funksiya + trigger)        -> xatti-harakat O'ZGARMAYDI
--     2-BOSQICH (POLni qo'yish — SIZ TAHRIRLAYSIZ)   -> shu yerda o'zgaradi
--     3-BOSQICH (tekshiruv select'lari)              -> ✅/❌
--
--
--  #####  MUAMMO — nima bo'lgan  ######################################
--
--  `sync_transfer_balans` har transferni cutoff bilan taqqoslaydi:
--
--      if v_cutoff is not null and v_recv <= v_cutoff then
--        n_eski := n_eski + 1;   continue;          -- jimgina TASHLAB YUBORADI
--      end if;
--
--  cutoff esa (`aros_transfer_cutoff()`):
--
--      greatest( aros_sync_state.last_balans_at,
--                max(entry.created_at where created_by = 'aros_sync') )
--
--  Ikkinchi qism — SINXRONNING O'Z YOZUVLARI. Ya'ni cutoff har siklda
--  o'zi-o'zidan oldinga suriladi va amalda "oxirgi sikl vaqti" bo'lib
--  qoladi. Natija:
--
--    • bir sikl kechikkan transfer (Aros API kech berdi, tarmoq uzildi,
--      n8n xato qildi, kalit noto'g'ri edi) KEYINGI siklda ham
--      `received_at <= cutoff` bo'lib qoladi -> ABADIY to'siladi;
--    • qayta urinish YO'Q;
--    • IZ ham YO'Q — javobda faqat `cutoffdan_eski: N` degan raqam,
--      qaysi transfer ekani hech qayerda saqlanmaydi.
--
--  2026-08-12 da aynan shu sabab 9 ta transfer (352 835 000 so'm) tushib
--  qolgan va PROVODKA_TRANSFER_TIKLASH_0812.sql bilan QO'LDA tiklangan.
--
--
--  #####  TANLANGAN YECHIM  ###########################################
--
--  (c) LOG  +  (a) ning MAQSADI, lekin harakatlanuvchi watermark'siz:
--      cutoff — HARAKATLANMAYDIGAN, QO'LDA QO'YILADIGAN **POL**.
--
--  1. `aros_transfer_wm` — bitta qatorli jadval, `wm_at` = POL.
--     Pol o'zi-o'zidan SURILMAYDI. Uni faqat `aros_transfer_wm_set()`
--     surа oladi (odam, ataylab). Ya'ni "sinxronning o'z yozuvi cutoff'ni
--     suradi" degan ildiz sabab BUTUNLAY yo'qoladi.
--
--  2. `aros_transfer_cutoff()` — pol qo'yilgan bo'lsa FAQAT undan oladi;
--     `last_balans_at` ham, `created_by='aros_sync'` yozuvlari ham
--     E'TIBORGA OLINMAYDI. Pol qo'yilmagan bo'lsa — eski mantiq
--     (ya'ni 1-BOSQICH o'zi hech narsani o'zgartirmaydi).
--
--  3. Natijada QAYTA URINISH AVTOMAT bo'ladi: poldan keyingi har transfer
--     HAR siklda qayta ko'riladi. Allaqachon yozilgani `ext_ref` bo'yicha
--     "takror" deb o'tkaziladi (indeksli, arzon), yozilmagani esa
--     YOZILADI. Backlog o'z-o'zidan yopiladi — (d) talab ham bajarildi.
--
--  4. `aros_transfer_dropped` — tashlangan har transfer LOG'ga tushadi
--     (sabab, urinishlar soni, birinchi/oxirgi vaqt). Pul yozmaydi,
--     xavfi nol. Endi "jimgina yo'qolish" degan holat yo'q.
--
--  NEGA HARAKATLANUVCHI WATERMARK EMAS: har qanday avtomatik suriluvchi
--  chegara — bu YANA BIR harakatlanuvchi qism. U noto'g'ri surilsa (bug,
--  poyga, xato hisob) transfer yana yo'qoladi yoki qayta ochiladi. Statik
--  pol esa noto'g'ri surila olmaydi. "Bir siklda ko'p ish" degan yagona
--  narxi bor, u ham indeksli `ext_ref` qidiruvi — arzon.
--
--
--  #####  IKKI MARTA YOZILMASLIK — 5 QAVAT  ###########################
--
--  Qavatlar bir-birini ALMASHTIRMAYDI, har biri BOSHQA xavfdan saqlaydi:
--
--  1. ⭐ `entry.ext_ref` UNIQUE — `aros_tr:<id>:<maydon>`. Bitta transfer
--     bitta tur uchun BIR MARTA yoziladi, payload necha marta kelsa ham.
--     Bu — asosiy va bazaviy kafolat (cutoff EMAS).
--
--  2. ⭐ YANGI: `aros_tr_fix` GUARD (1.6). Qo'lda to'g'irlangan transfer
--     (`aros_tr_fix:<id>:<tur>`, Dt markaziy / Kt 9010) uchun sinxron
--     `aros_tr:<id>:<maydon>` (Dt markaziy / Kt filial) yozsa — markaziy
--     kassa pulni IKKI MARTA olardi. `ext_ref` UNIQUE buni TUTA OLMAYDI,
--     chunki kalitlar boshqa-boshqa. Endi `entry` ustidagi trigger tutadi.
--     🔴 POLni pastga tushirishning yagona haqiqiy xavfi shu edi — yopildi.
--
--  3. ⭐ POL (2-BOSQICH). Poldan OLDINGI transferlar boshlang'ich qoldiqqa
--     singib ketgan (31-iyul – 11-avgust oralig'idagi ~74 ta transfer).
--     Pol 12-avgustdan KEYIN turadi -> ular hech qachon qayta yozilmaydi.
--
--  4. ⭐ Advisory lock (mavjud, tegilmadi): `sync_transfer_balans` ham
--     `sync_filial_balans` lock'ini, ham o'zinikini oladi -> delta sinxroni
--     transfer yozilayotgan paytda o'rtaga tusha olmaydi.
--
--  5. ⭐ Delta sinxronining O'ZI — ABSOLYUT tenglashtirish (pastga qara).
--
--
--  #####  DELTA SINXRONI QAYTA YOQILSA NIMA BO'LADI  ##################
--
--  Hozir `Aros Provodka - Auto Sync` (sync_filial_balans) O'CHIRILGAN.
--  Yoqilganda ham bu yechim ikki marta hisoblashdan saqlaydi. Sabab —
--  delta DELTA emas, ABSOLYUT tenglashtirish: u "filial daftar qoldig'i"
--  ni Aros balansiga TENGLASHTIRADI (`v_delta = aros − daftar`).
--
--  Eng yomon holat: transfer T bir sikl kechikdi va delta uni "savdo minus"
--  deb yutdi. Belgilar: S = o'sha davr savdosi, T = transfer summasi.
--
--    1-sikl (delta yutdi):    filial += (S − T),   9010 += (S − T)
--    keyingi sikl (transfer,  markaziy += T,       filial −= T
--    endi to'silmaydi):
--    keyingi delta:           daftar Aros'dan T kam -> filial += T, 9010 += T
--
--    JAMI:  filial = S − T ✅ (Aros bilan teng)
--           9010   = S     ✅ (haqiqiy savdo)
--           markaziy = T   ✅ (BIR marta — `ext_ref` kafolati)
--
--  Ya'ni kech yozilgan transfer O'Z-O'ZIDAN TUZALADI, chunki delta har
--  siklda daftarni Aros'ga tenglashtiradi. Yagona qoladigan farq —
--  to'g'irlash yozuvining SANASI (P&L davri bo'yicha siljish), pul emas.
--
--  Markaziy kassa esa deltaga UMUMAN kirmaydi (`v_filial_sync_mapping`
--  faqat `filial_ref` bor kassalarni oladi) — u pulni faqat transfer
--  sinxronidan oladi, u ham `ext_ref` bilan bir martalik.
--
--  ⚠️ SHUNING UCHUN n8n TARTIBI O'ZGARMAYDI: AVVAL transfer, KEYIN delta.
--     Bu tartib buzilsa pul yo'qolmaydi (yuqoridagi hisob baribir tuzaladi),
--     lekin oraliq holat noto'g'ri ko'rinadi.
--
--
--  #####  ESKI YECHIMLAR BILAN TO'QNASHUV  ############################
--
--  • `transfer_tuzatish()` (PROVODKA_TRANSFER_TUZATISH.sql) `received_at <=
--    cutoff` hududida ishlaydi — ya'ni SINXRONNING TESKARISI. Cutoff endi
--    surilmaydigan pol bo'lgani uchun bu hudud ham surilmaydi: tuzatish
--    faqat POLDAN OLDINGI (boshlang'ich qoldiq davri) transferlarni
--    to'g'irlaydi. Bu — to'g'ri va oldingidan ANIQROQ chegara.
--  • `aros_tr_fix:` kalitlariga TEGILMAYDI. Aksincha, 1.6 trigger ularni
--    endi HIMOYA qiladi (2-qavat).
--  • `sync_aros_full()`, `aros_sync_stamp()`, `aros_sync_state` — o'chirilmadi,
--    imzolari o'zgarmadi. `last_balans_at` endi cutoff'ga TA'SIR QILMAYDI
--    (pol qo'yilgandan keyin), lekin ma'lumot sifatida yozilaveradi.
-- =====================================================================



-- #####################################################################
--  0-BOSQICH — PREFLIGHT.  FAQAT `select`. HECH NARSA YOZMAYDI.
-- #####################################################################
--  Hammasini RUN qiling va natijani o'qing. ❌ bo'lsa 1-BOSQICHga o'tmang.


-- ⬇⬇⬇ 0.1 — HOZIRGI cutoff qayerdan kelyapti ⬇⬇⬇
select 'joriy cutoff'                                                    as nima,
       (aros_transfer_cutoff() ->> 'cutoff')::timestamptz                as cutoff_utc,
       to_char((aros_transfer_cutoff() ->> 'cutoff')::timestamptz
                 at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI')     as cutoff_toshkent,
       aros_transfer_cutoff() ->> 'manba'                                as manba,
       case when (aros_transfer_cutoff() ->> 'manba') like 'oxirgi delta%'
            then '🔴 ILDIZ SABAB: cutoff sinxronning O''Z yozuvidan kelyapti'
            when (aros_transfer_cutoff() ->> 'cutoff') is null
            then '⚠️ cutoff yo''q — hozir sinxron UMUMAN yozmaydi (ok:false qaytaradi)'
            else '⚠️ cutoff muhrdan — u ham har delta siklida oldinga suriladi'
       end                                                               as izoh;
-- ⬆⬆⬆ 0.1 ⬆⬆⬆


-- ⬇⬇⬇ 0.2 — Kerakli obyektlar joyidami ⬇⬇⬇
select 'sync_transfer_balans(jsonb,boolean,timestamptz)' as obyekt,
       case when to_regprocedure('public.sync_transfer_balans(jsonb,boolean,timestamptz)') is not null
            then '✅ bor' else '❌ YO''Q — avval PROVODKA_TRANSFER.sql ni RUN qiling' end as holat
union all
select 'aros_transfer_cutoff(timestamptz)',
       case when to_regprocedure('public.aros_transfer_cutoff(timestamptz)') is not null
            then '✅ bor' else '❌ YO''Q — avval PROVODKA_TRANSFER.sql' end
union all
select 'entry.ext_ref UNIQUE indeksi',
       case when exists (select 1 from pg_indexes
                          where schemaname = 'public' and indexname = 'entry_ext_ref_uniq')
            then '✅ bor — bu 1-QAVAT himoya, ENG MUHIMI'
            else '❌ YO''Q — takrorlanish himoyasi OCHIQ! To''xtang.' end
union all
select 'aros_transfer_wm (bu fayl yaratadi)',
       case when to_regclass('public.aros_transfer_wm') is not null
            then '⚠️ allaqachon bor — 1-BOSQICH uni buzmaydi' else '➖ hali yo''q (normal)' end
union all
select 'aros_transfer_dropped (bu fayl yaratadi)',
       case when to_regclass('public.aros_transfer_dropped') is not null
            then '⚠️ allaqachon bor — 1-BOSQICH uni buzmaydi' else '➖ hali yo''q (normal)' end
union all
select 'trg_aros_tr_fix_guard (bu fayl yaratadi)',
       case when exists (select 1 from pg_trigger
                          where tgname = 'trg_aros_tr_fix_guard' and not tgisinternal)
            then '⚠️ allaqachon bor' else '➖ hali yo''q (normal)' end;
-- ⬆⬆⬆ 0.2 ⬆⬆⬆


-- ⬇⬇⬇ 0.3 — QO'LDA TO'G'IRLANGAN transferlar (aros_tr_fix) ⬇⬇⬇
--  🔴 ENG MUHIM RO'YXAT. Bu transferlar uchun pul ALLAQACHON yozilgan
--     (Dt markaziy / Kt 9010). Agar pol shulardan OLDIN qo'yilsa va
--     sinxron ularni qayta yozsa — markaziy kassa pulni IKKI MARTA olardi.
--     1.6 dagi trigger aynan shuni to'sadi, lekin polni baribir shulardan
--     KEYIN qo'ying (ikki qavat himoya).
select split_part(e.ext_ref, ':', 2)                                as tr_id,
       string_agg(distinct split_part(e.ext_ref, ':', 3), ', ')     as turlar,
       min(e.entry_date)                                            as sana,
       sum(l.debit)                                                 as summa_uzs,
       count(*)                                                     as yozuvlar
  from entry e
  join entry_line l on l.entry_id = e.id and l.debit > 0
 where left(e.ext_ref, 12) = 'aros_tr_fix:'
   and e.is_deleted = false
 group by 1
 order by 3, 1;
-- ⬆⬆⬆ 0.3 ⬆⬆⬆


-- ⬇⬇⬇ 0.4 — Sinxron oxirgi marta QACHON transfer yozgan ⬇⬇⬇
select 'sinxron yozuvlari (aros_tr:)'                     as nima,
       count(*)                                           as yozuvlar,
       min(e.entry_date)                                  as birinchi_sana,
       max(e.entry_date)                                  as oxirgi_sana,
       max(e.created_at)                                  as oxirgi_yozilgan_at
  from entry e
 where left(e.ext_ref, 8) = 'aros_tr:' and e.is_deleted = false
union all
select 'qo''lda to''g''irlash (aros_tr_fix:)',
       count(*), min(e.entry_date), max(e.entry_date), max(e.created_at)
  from entry e
 where left(e.ext_ref, 12) = 'aros_tr_fix:' and e.is_deleted = false
union all
select 'delta sinxroni yozuvlari (aros_sync)',
       count(*), min(e.entry_date), max(e.entry_date), max(e.created_at)
  from entry e
 where e.source = 'aros_auto' and e.created_by = 'aros_sync' and e.is_deleted = false;
-- ⬆⬆⬆ 0.4 ⬆⬆⬆


-- ⬇⬇⬇ 0.5 — 2-BOSQICH uchun POL TAVSIYASI ⬇⬇⬇
--  Qoida: pol = daftarga ALLAQACHON singib ketgan oxirgi transfer kunining
--  OXIRI (Toshkent vaqtida). Undan keyingi hamma transfer sinxronga ochiq.
--  Boshlang'ich qoldiq davri (31-iyul – 11-avgust) va 12-avgust qo'lda
--  tiklashi — hammasi poldan OLDINDA qolishi SHART.
select '2-BOSQICH uchun tavsiya'                                          as nima,
       greatest(
         coalesce((select max(e.entry_date) from entry e
                    where left(e.ext_ref, 12) = 'aros_tr_fix:' and e.is_deleted = false),
                  date '2026-08-12'),
         date '2026-08-12'
       )                                                                  as oxirgi_qolda_tiklangan_kun,
       ((greatest(
           coalesce((select max(e.entry_date) from entry e
                      where left(e.ext_ref, 12) = 'aros_tr_fix:' and e.is_deleted = false),
                    date '2026-08-12'),
           date '2026-08-12')::timestamp + interval '1 day')
         at time zone 'Asia/Tashkent')                                    as tavsiya_pol,
       'Shu paytdan KEYINGI transferlar sinxronga ochiq bo''ladi'         as mano;
-- ⬆⬆⬆ 0.5 ⬆⬆⬆



-- #####################################################################
--  1-BOSQICH — JADVAL + FUNKSIYA + TRIGGER
-- #####################################################################
--  ⚠️ Bu bosqich XATTI-HARAKATNI O'ZGARTIRMAYDI: pol (`wm_at`) hali null,
--     shuning uchun `aros_transfer_cutoff()` eski mantiqda ishlayveradi.
--     Faqat LOG va GUARD yoqiladi. O'zgarish 2-BOSQICHda boshlanadi.


-- ⬇⬇⬇ 1.1 — aros_transfer_wm: cutoff POLi (bitta qator, id = 1) ⬇⬇⬇
create table if not exists aros_transfer_wm (
  id          int primary key default 1,
  wm_at       timestamptz,                       -- POL: shundan KEYINGI transfer yoziladi
  izoh        text,
  updated_at  timestamptz not null default now(),
  updated_by  text,
  constraint aros_transfer_wm_bitta check (id = 1)
);

-- Qator bor, lekin wm_at NULL -> eski mantiq. Ataylab: 1-BOSQICH xavfsiz.
insert into aros_transfer_wm(id, wm_at, izoh)
values (1, null, 'PROVODKA_TRANSFER_CUTOFF_FIX.sql 1-BOSQICH — pol hali qo''yilmagan')
on conflict (id) do nothing;

alter table aros_transfer_wm enable row level security;
revoke all on aros_transfer_wm from public, anon, authenticated;
grant select on aros_transfer_wm to service_role;

comment on table aros_transfer_wm is
  'Transfer sinxroni cutoff POLi. Faqat shu jadvaldan keladi va O''ZI-O''ZIDAN '
  'SURILMAYDI — aros_transfer_wm_set() bilan qo''lda suriladi. wm_at null bo''lsa '
  'aros_transfer_cutoff() eski mantiqqa (muhr + aros_sync yozuvlari) qaytadi.';
-- ⬆⬆⬆ 1.1 ⬆⬆⬆


-- ⬇⬇⬇ 1.2 — aros_transfer_dropped: TASHLANGANLAR LOGI ⬇⬇⬇
--  Pul yozmaydi. Yagona vazifasi — "jimgina yo'qolish" ni yo'q qilish.
--  PK (tr_id, tur, sabab_turi): har sikl qayta urinilganda yangi qator
--  emas, `urinishlar` oshadi -> jadval o'smaydi.
create table if not exists aros_transfer_dropped (
  tr_id        text        not null,
  tur          text        not null default '-',   -- cash|click|payme|dollar_usd|'-'
  sabab_turi   text        not null,               -- cutoff|mapping|kurs|atayin|boshqa
  sabab        text,
  received_at  timestamptz,
  cutoff       timestamptz,
  summa        numeric,
  payload      jsonb,
  urinishlar   int         not null default 1,
  birinchi_at  timestamptz not null default now(),
  oxirgi_at    timestamptz not null default now(),
  hal_qilindi  boolean     not null default false,
  hal_izoh     text,
  primary key (tr_id, tur, sabab_turi)
);

create index if not exists aros_transfer_dropped_ochiq
  on aros_transfer_dropped (oxirgi_at desc) where hal_qilindi = false;
create index if not exists aros_transfer_dropped_turi
  on aros_transfer_dropped (sabab_turi, oxirgi_at desc);

alter table aros_transfer_dropped enable row level security;
revoke all on aros_transfer_dropped from public, anon, authenticated;
grant select, insert, update on aros_transfer_dropped to service_role;

comment on table aros_transfer_dropped is
  'Transfer sinxroni YOZMAGAN transferlar logi. Pul yozmaydi. PK (tr_id,tur,sabab_turi) — '
  'qayta urinishda urinishlar oshadi. hal_qilindi=true bo''lsa keyinchalik yozilgan.';
-- ⬆⬆⬆ 1.2 ⬆⬆⬆


-- ⬇⬇⬇ 1.3 — aros_transfer_wm_set(): POLni qo'yish (yagona yo'l) ⬇⬇⬇
--  Himoyalar:
--    • null pol — TAQIQ (tasodifan eski mantiqqa qaytmasin)
--    • kelajakdagi pol — TAQIQ (hamma transfer to'silib qolardi)
--    • 2026-08-12 dan oldingi pol — TAQIQ (boshlang'ich qoldiq + qo'lda
--      tiklash hududi) — faqat p_force => true bilan
--    • ORQAGA surish — TAQIQ, faqat p_force => true bilan
create or replace function aros_transfer_wm_set(p_at    timestamptz,
                                                p_izoh  text default null,
                                                p_force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eski timestamptz;
  v_pol  constant timestamptz := timestamptz '2026-08-12 00:00:00+05';
  v_kim  text;
begin
  if p_at is null then
    raise exception 'AROS WM: pol (p_at) bo''sh bo''lishi mumkin emas'
      using hint = 'Pol = "shu paytdan KEYINGI transferlar yoziladi". Null bersangiz '
                   'cutoff eski (o''zi suriluvchi) mantiqqa qaytadi — aynan shu bug edi. '
                   'Ataylab qaytarmoqchi bo''lsangiz: update aros_transfer_wm set wm_at = null where id = 1;';
  end if;

  if p_at > now() then
    raise exception 'AROS WM: pol KELAJAKDA (%) — hamma transfer to''silib qolardi', p_at
      using hint = 'Polni faqat o''tgan paytga qo''ying.';
  end if;

  if p_at < v_pol and not p_force then
    raise exception 'AROS WM: pol 2026-08-12 dan OLDIN (%) — bloklandi', p_at
      using hint = 'Undan oldingi transferlar boshlang''ich qoldiqqa singib ketgan '
                   '(31-iyul – 11-avgust, ~74 ta) va 12-avgustdagilari qo''lda tiklangan. '
                   'Ularni qayta ochish pulni IKKI MARTA yozardi. Ataylab bo''lsa: '
                   'p_force => true, lekin AVVAL 3.4 select''ini ko''ring.';
  end if;

  select wm_at into v_eski from aros_transfer_wm where id = 1;

  if v_eski is not null and p_at < v_eski and not p_force then
    raise exception 'AROS WM: pol ORQAGA surilyapti (% dan % ga) — bloklandi', v_eski, p_at
      using hint = 'Orqaga surish eski transferlarni qayta ochadi. Qayta yozilishdan '
                   'ext_ref UNIQUE va aros_tr_fix guard saqlaydi, lekin baribir ataylab '
                   'qilinishi kerak: p_force => true.';
  end if;

  v_kim := coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), current_user);

  insert into aros_transfer_wm(id, wm_at, izoh, updated_at, updated_by)
  values (1, p_at, p_izoh, now(), v_kim)
  on conflict (id) do update
     set wm_at      = excluded.wm_at,
         izoh       = excluded.izoh,
         updated_at = now(),
         updated_by = excluded.updated_by;

  return jsonb_build_object(
    'ok', true,
    'eski_pol', v_eski,
    'yangi_pol', p_at,
    'yangi_pol_toshkent', to_char(p_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI'),
    'izoh', p_izoh,
    'kim', v_kim,
    'eslatma', 'Endi FAQAT shu poldan keyingi transferlar yoziladi va ular HAR siklda '
               'qayta uriniladi (ext_ref takrorni to''sadi).');
end $$;

revoke all on function aros_transfer_wm_set(timestamptz, text, boolean) from public, anon, authenticated;
grant execute on function aros_transfer_wm_set(timestamptz, text, boolean) to service_role;

comment on function aros_transfer_wm_set(timestamptz, text, boolean) is
  'Transfer sinxroni cutoff POLini qo''yadi. Kelajak / 2026-08-12 dan oldin / orqaga '
  'surish — p_force siz TAQIQ. Pol o''zi-o''zidan hech qachon surilmaydi.';
-- ⬆⬆⬆ 1.3 ⬆⬆⬆


-- ⬇⬇⬇ 1.4 — aros_transfer_drop_yoz(): sinxron javobini LOGga yozadi ⬇⬇⬇
--  `sync_transfer_balans` javobidan (`ogohlantirishlar`, `cutoffdan_eski_royxat`,
--  `tafsilot`) foydalanadi. Xato bersa sinxron TO'XTAMAYDI — chaqiruv joyi
--  exception bloki ichida. dry_run da hech narsa yozmaydi.
create or replace function aros_transfer_drop_yoz(p_natija  jsonb,
                                                  p_dry_run boolean default false)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_el   jsonb;
  v_id   text;
  v_tur  text;
  v_turi text;
  v_n    int := 0;
begin
  if p_natija is null or coalesce(p_dry_run, false) then
    return 0;
  end if;

  -- 1) CUTOFF bilan tashlanganlar (butun transfer)
  for v_el in
    select * from jsonb_array_elements(coalesce(p_natija -> 'cutoffdan_eski_royxat', '[]'::jsonb))
  loop
    v_id := nullif(btrim(coalesce(v_el ->> 'transfer', '')), '');
    if v_id is null then continue; end if;

    insert into aros_transfer_dropped(tr_id, tur, sabab_turi, sabab, received_at, cutoff, payload)
    values (v_id, '-', 'cutoff', v_el ->> 'sabab',
            nullif(v_el ->> 'received_at', '')::timestamptz,
            nullif(v_el ->> 'cutoff', '')::timestamptz,
            v_el)
    on conflict (tr_id, tur, sabab_turi) do update
       set urinishlar = aros_transfer_dropped.urinishlar + 1,
           oxirgi_at  = now(),
           sabab      = excluded.sabab,
           cutoff     = excluded.cutoff,
           payload    = excluded.payload;
    v_n := v_n + 1;
  end loop;

  -- 2) OGOHLANTIRISHLAR (mapping / kurs / ataylab o'tkazilgan / boshqa)
  for v_el in
    select * from jsonb_array_elements(coalesce(p_natija -> 'ogohlantirishlar', '[]'::jsonb))
  loop
    v_id := nullif(btrim(coalesce(v_el ->> 'transfer', '')), '');
    if v_id is null then continue; end if;         -- transfersiz ogoh (p_from va h.k.)

    v_tur  := coalesce(nullif(btrim(coalesce(v_el ->> 'tur', '')), ''), '-');
    v_turi := case
                when (v_el ->> 'fix_kalit') is not null                then 'atayin'
                when coalesce(v_el ->> 'sabab', '') ilike '%kurs%'     then 'kurs'
                when (v_el ->> 'tomon') is not null                    then 'mapping'
                when coalesce(v_el ->> 'sabab', '') ilike '%hisob%'    then 'mapping'
                when coalesce(v_el ->> 'sabab', '') ilike '%kassa%'    then 'mapping'
                else 'boshqa'
              end;

    -- 'atayin' = qo'lda to'g'irlangan -> bu XATO EMAS, QAROR. Darrov
    -- hal_qilindi deb belgilanadi, aks holda backlog view'ida (1.8) abadiy
    -- osilib qolardi va haqiqiy muammolarni ko'rsatmay qo'yardi.
    insert into aros_transfer_dropped(tr_id, tur, sabab_turi, sabab, summa, payload,
                                      hal_qilindi, hal_izoh)
    values (v_id, v_tur, v_turi, v_el ->> 'sabab',
            nullif(v_el ->> 'summa', '')::numeric, v_el,
            (v_turi = 'atayin'),
            case when v_turi = 'atayin'
                 then 'qo''lda to''g''irlangan (aros_tr_fix) — muammo emas' end)
    on conflict (tr_id, tur, sabab_turi) do update
       set urinishlar = aros_transfer_dropped.urinishlar + 1,
           oxirgi_at  = now(),
           sabab      = excluded.sabab,
           summa      = excluded.summa,
           payload    = excluded.payload;
    v_n := v_n + 1;
  end loop;

  -- 3) Endi YOZILGANLARINI "hal qilindi" deb belgilash.
  --    tur bo'yicha emas, tr_id bo'yicha (javobdagi `tafsilot` turni
  --    yorliq bilan beradi: 'Naqd'/'Click'/... — maydon nomi emas).
  --    'atayin' qatorlariga tegilmaydi: ular xato emas, qaror.
  for v_el in
    select * from jsonb_array_elements(coalesce(p_natija -> 'tafsilot', '[]'::jsonb))
  loop
    v_id := nullif(btrim(coalesce(v_el ->> 'transfer', '')), '');
    if v_id is null then continue; end if;

    update aros_transfer_dropped
       set hal_qilindi = true,
           hal_izoh    = 'sinxron yozdi: ' || coalesce(v_el ->> 'ext_ref', '?'),
           oxirgi_at   = now()
     where tr_id = v_id
       and hal_qilindi = false
       and sabab_turi <> 'atayin';
  end loop;

  return v_n;
end $$;

revoke all on function aros_transfer_drop_yoz(jsonb, boolean) from public, anon, authenticated;
grant execute on function aros_transfer_drop_yoz(jsonb, boolean) to service_role;

comment on function aros_transfer_drop_yoz(jsonb, boolean) is
  'sync_transfer_balans javobini aros_transfer_dropped logiga yozadi. Pul yozmaydi. '
  'dry_run da hech narsa qilmaydi. Xato bersa sinxron to''xtamaydi (chaqiruvi exception ichida).';
-- ⬆⬆⬆ 1.4 ⬆⬆⬆


-- ⬇⬇⬇ 1.5 — aros_transfer_cutoff(): POL birinchi, eski mantiq zaxira ⬇⬇⬇
--  🔴 ILDIZ TUZATISH SHU YERDA.
--  Eski: cutoff = greatest(muhr, max(entry.created_at where created_by='aros_sync'))
--        -> sinxronning O'Z yozuvi cutoff'ni suradi -> kechikkan transfer abadiy yo'qoladi.
--  Yangi: pol qo'yilgan bo'lsa cutoff = FAQAT pol (surilmaydi).
--         Pol yo'q bo'lsa — eski mantiq (orqaga moslik; 1-BOSQICH xavfsiz bo'lishi uchun).
--
--  ⚠️ Chiqish kalitlari BITTA HAM olib tashlanmadi (TIKLASH/DIAG/TUZATISH
--     skriptlari `->> 'cutoff'` va boshqalarni o'qiydi). Faqat yangi kalitlar
--     qo'shildi: `pol`, `pol_izoh`, `rejim`.
create or replace function aros_transfer_cutoff(p_from timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_muhr     timestamptz;
  v_oxirgi   timestamptz;
  v_birinchi timestamptz;
  v_n        int := 0;
  v_ss       text;
  v_cut      timestamptz;
  v_manba    text;
  v_qoldi    boolean := false;
  v_pol      timestamptz;
  v_pol_izoh text;
  v_rejim    text;
begin
  -- 1) POL (yangi, asosiy manba)
  if to_regclass('public.aros_transfer_wm') is not null then
    begin
      execute 'select wm_at, izoh from aros_transfer_wm where id = 1'
        into v_pol, v_pol_izoh;
    exception when others then
      v_pol := null; v_pol_izoh := null;
    end;
  end if;

  -- 2) Eski manbalar — POL bo'lsa ham DIAGNOSTIKA uchun o'qiladi
  if to_regclass('public.aros_sync_state') is not null then
    begin
      execute 'select last_balans_at from aros_sync_state where id = 1' into v_muhr;
    exception when others then
      v_muhr := null;
    end;
  end if;

  select min(created_at), max(created_at), count(*)
    into v_birinchi, v_oxirgi, v_n
    from entry
   where source = 'aros_auto' and created_by = 'aros_sync';

  -- 3) Cutoff'ni tanlash
  if v_pol is not null then
    -- ⭐ POL REJIMI: muhr ham, sinxron yozuvlari ham E'TIBORGA OLINMAYDI.
    --    Aynan shu ikkovi cutoff'ni har siklda oldinga surib, kechikkan
    --    transferni abadiy to'sib qo'yardi.
    v_cut   := v_pol;
    v_manba := 'aros_transfer_wm.wm_at (POL — o''zi surilmaydi)';
    v_rejim := 'pol';
  else
    v_cut := greatest(v_muhr, v_oxirgi);
    v_manba := case
                 when v_cut is null                         then null
                 when v_muhr is not null and v_cut = v_muhr  then 'aros_sync_state.last_balans_at (muhr)'
                 else 'oxirgi delta sync yozuvi (entry.created_at)'
               end;
    v_rejim := 'eski (pol qo''yilmagan)';
  end if;

  -- 4) p_from FAQAT qattiqlashtira oladi (o'zgarmadi)
  if p_from is not null then
    if v_cut is null or p_from > v_cut then
      v_cut   := p_from;
      v_manba := 'p_from (qattiqroq — chegaradan keyin)';
    else
      v_qoldi := true;
    end if;
  end if;

  -- 5) Eski mexanizm qiymati — FAQAT diagnostika
  if to_regclass('public.sync_state') is not null then
    begin
      execute 'select max(transfers_from)::text from sync_state' into v_ss;
    exception when others then
      v_ss := null;
    end;
  end if;

  return jsonb_build_object(
    'cutoff', v_cut,
    'manba', coalesce(v_manba, '(topilmadi)'),
    'rejim', v_rejim,
    'pol', v_pol,
    'pol_izoh', v_pol_izoh,
    'muhr_last_balans_at', v_muhr,
    'oxirgi_delta_yozuvi', v_oxirgi,
    'birinchi_delta_yozuvi', v_birinchi,
    'delta_yozuvlari', v_n,
    'p_from', p_from,
    'p_from_ishlatilmadi', v_qoldi,
    'sync_state_transfers_from', v_ss,
    'izoh', 'Faqat received_at > cutoff bo''lgan transfer yoziladi. '
            || 'POL rejimida cutoff aros_transfer_wm.wm_at dan keladi va o''zi surilmaydi — '
            || 'shuning uchun kechikkan transfer keyingi siklda QAYTA uriniladi.');
end $$;

revoke all on function aros_transfer_cutoff(timestamptz) from public, anon;
grant execute on function aros_transfer_cutoff(timestamptz) to authenticated, service_role;

comment on function aros_transfer_cutoff(timestamptz) is
  'Transfer sync cutoff''i. POL rejimi (aros_transfer_wm.wm_at) — asosiy: o''zi surilmaydi, '
  'kechikkan transfer keyingi siklda qayta uriniladi. Pol yo''q bo''lsa eski mantiq '
  '(muhr + oxirgi delta yozuvi) — orqaga moslik uchun saqlangan.';
-- ⬆⬆⬆ 1.5 ⬆⬆⬆


-- ⬇⬇⬇ 1.6 — GUARD: qo'lda to'g'irlangan transfer QAYTA yozilmasin ⬇⬇⬇
--  🔴 POLni pastga tushirishning YAGONA haqiqiy pul xavfi shu edi.
--
--  `ext_ref` UNIQUE buni TUTOLMAYDI, chunki ikki yo'l ikki xil kalit yozadi:
--     sinxron        -> 'aros_tr:<id>:<maydon>'      maydon = cash|click|payme|dollar_usd
--     qo'lda tuzatish-> 'aros_tr_fix:<id>:<tur>'     tur    = naqd|click|payme|dollar
--  Ikkovi ham markaziy kassaga PUL KIRITADI. Ikkalasi yozilsa — IKKI MARTA.
--
--  Trigger `23505` (unique_violation) kodi bilan xato beradi. Bu ATAYLAB:
--  `sync_transfer_balans` ichidagi mavjud `exception when unique_violation`
--  bloki uni "takror" deb sanaydi va sinxron TO'XTAMAYDI. Ya'ni katta
--  funksiyaga qo'shimcha tuzatish kerak emas — himoya HAMMA yozuv yo'liga
--  (sinxron, tuzatish, tiklash, qo'lda) bir joyda tushadi.
--
--  ESCAPE: yozuv soft-delete qilingan bo'lsa (`is_deleted = true`) guard
--  ishlamaydi. Ya'ni admin noto'g'ri to'g'irlashni o'chirsa, sinxron haqiqiy
--  transferni yoza oladi — bu KERAKLI tuzatish yo'li.
create or replace function aros_tr_fix_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id     text;
  v_maydon text;
  v_tur    text;
  v_kalit  text;
begin
  if new.ext_ref is null then
    return new;
  end if;

  -- A) Sinxron yozuvi -> qo'lda to'g'irlash BORMI
  -- left() ishlatiladi, `like` emas: `_` LIKE da joker belgi.
  if left(new.ext_ref, 8) = 'aros_tr:' then
    v_id     := split_part(new.ext_ref, ':', 2);
    v_maydon := split_part(new.ext_ref, ':', 3);
    v_tur    := case v_maydon when 'cash'       then 'naqd'
                              when 'dollar_usd' then 'dollar'
                              else v_maydon end;
    v_kalit  := 'aros_tr_fix:' || v_id || ':' || v_tur;

    if exists (select 1 from entry where ext_ref = v_kalit and is_deleted = false) then
      raise exception 'AROS GUARD: transfer % (%) allaqachon QO''LDA to''g''irlangan — yozilmadi', v_id, v_maydon
        using errcode = '23505',
              hint = 'Kalit: ' || v_kalit || '. Bu transfer uchun pul markaziy kassaga '
                     'allaqachon kiritilgan (Dt markaziy / Kt 9010). Sinxron yana yozsa '
                     'markaziy kassa pulni IKKI MARTA olardi. Agar to''g''irlash NOTO''G''RI '
                     'bo''lsa — avval o''sha yozuvni jurnaldan o''chiring (soft-delete), '
                     'keyin sinxron o''zi yozadi.';
    end if;

  -- B) Qo'lda to'g'irlash -> sinxron yozuvi BORMI (teskari yo'nalish)
  elsif left(new.ext_ref, 12) = 'aros_tr_fix:' then
    v_id     := split_part(new.ext_ref, ':', 2);
    v_tur    := split_part(new.ext_ref, ':', 3);
    v_maydon := case v_tur when 'naqd'   then 'cash'
                           when 'dollar' then 'dollar_usd'
                           else v_tur end;
    v_kalit  := 'aros_tr:' || v_id || ':' || v_maydon;

    if exists (select 1 from entry where ext_ref = v_kalit and is_deleted = false) then
      raise exception 'AROS GUARD: transfer % (%) sinxron tomonidan allaqachon yozilgan — to''g''irlash yozilmadi', v_id, v_tur
        using errcode = '23505',
              hint = 'Kalit: ' || v_kalit || '. transfer_tuzatish() buni o''zi ham tekshiradi '
                     '(2-himoya); bu trigger — oxirgi to''siq.';
    end if;
  end if;

  return new;
end $$;

drop trigger if exists trg_aros_tr_fix_guard on entry;
create trigger trg_aros_tr_fix_guard
  before insert on entry
  for each row
  when (new.ext_ref is not null)
  execute function aros_tr_fix_guard();

comment on function aros_tr_fix_guard() is
  'entry BEFORE INSERT guard: bitta Aros transferi uchun ham sinxron (aros_tr:), '
  'ham qo''lda to''g''irlash (aros_tr_fix:) yozuvi BIR VAQTDA bo''lishiga yo''l qo''ymaydi. '
  '23505 kodi bilan xato beradi — sinxron uni "takror" deb sanaydi va to''xtamaydi.';
-- ⬆⬆⬆ 1.6 ⬆⬆⬆


-- ⬇⬇⬇ 1.7 — sync_transfer_balans(): IZ QOLDIRISH + fix-guard ⬇⬇⬇
--  ⚠️ Bu — PROVODKA_TRANSFER.sql:684-1083 dagi funksiyaning AYNAN nusxasi,
--     imzosi `(jsonb, boolean, timestamptz)` O'ZGARMAGAN. Faqat 4 ta joyga
--     tegildi, hammasi ⭐ YANGI deb belgilangan va HECH BIRI pul yozish
--     mantiqiga tegmaydi:
--       1) declare — 4 ta yangi o'zgaruvchi
--       2) 4.4 cutoff — tashlangan transferni RO'YXATGA qo'shish (iz)
--       3) 4.7 takror — 'aros_tr_fix:' kaliti bo'lsa ataylab o'tkazish
--       4) oxiri    — javobni v_natija ga olib, LOGga yozib, keyin qaytarish
--
--  🔴 PROVODKA_TRANSFER.sql ni KEYINCHALIK qayta RUN qilsangiz, bu funksiya
--     eski holiga qaytadi (iz va fix-guard yo'qoladi). O'shanda SHU FAYLNING
--     1.5 va 1.7 bo'limlarini qayta RUN qiling. 1.6 trigger esa mustaqil —
--     u `entry` ustida turadi va qayta RUN talab qilmaydi.

create or replace function sync_transfer_balans(p_data jsonb,
                                               p_dry_run boolean default false,
                                               p_from timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_list        jsonb;
  v_el          jsonb;

  v_cutoff      timestamptz;
  v_cutoff_man  text;
  v_cut_info    jsonb;

  v_tr_id       text;
  v_status      text;
  v_txt         text;
  v_recv        timestamptz;
  v_sana        date;

  v_send_res    jsonb;
  v_recv_res    jsonb;
  v_send_id     uuid;
  v_recv_id     uuid;
  v_send_nom    text;
  v_recv_nom    text;
  v_recv_turi   text;

  v_maydon      text;
  v_lbl         text;
  v_amt         numeric;
  v_rate        numeric;
  v_baza_rate   numeric;
  v_tr_rate     numeric;
  v_kurs_manba  text;

  v_dt          uuid;
  v_kt          uuid;
  v_summa       numeric;
  v_fc          numeric;
  v_ext         text;
  v_entry       uuid;
  v_fix_ext     text;                    -- ⭐ YANGI: 'aros_tr_fix:<id>:<tur>' kaliti
  v_natija      jsonb;                   -- ⭐ YANGI: javob (log yozishdan oldin ushlanadi)

  n_jami        int := 0;
  n_yozuv       int := 0;
  n_takror      int := 0;
  n_otkaz       int := 0;
  n_status      int := 0;
  n_eski        int := 0;
  v_ogoh        jsonb := '[]'::jsonb;
  v_tafsil      jsonb := '[]'::jsonb;
  v_eski_ruy    jsonb := '[]'::jsonb;    -- ⭐ YANGI: cutoff bilan tashlanganlar ro'yxati
  n_fix         int := 0;                -- ⭐ YANGI: qo'lda to'g'irlangani uchun o'tkazilgan
begin
  -- ---- 0. Qulflar ---------------------------------------------------
  -- IKKALASI ham olinadi va SHU TARTIBDA. Sabab: transfer yozilayotganda
  -- sync_filial_balans o'rtaga tushsa, u transferni ko'rmagan daftar
  -- ustidan delta hisoblab, o'sha pulni "tushum" deb yozib yuborardi.
  -- Delta sync faqat o'z lock'ini oladi -> deadlock bo'lishi mumkin emas.
  perform pg_advisory_xact_lock(hashtext('sync_filial_balans'));
  perform pg_advisory_xact_lock(hashtext('sync_transfer_balans'));

  -- ---- 1. Kirishni normallashtirish ---------------------------------
  if p_data is null then
    return jsonb_build_object('ok', false, 'error', 'p_data bo''sh');
  end if;

  if jsonb_typeof(p_data) = 'object' and p_data ? 'transferlar' then
    v_list := p_data -> 'transferlar';
  elsif jsonb_typeof(p_data) = 'object' and p_data ? 'transfers' then
    v_list := p_data -> 'transfers';
  elsif jsonb_typeof(p_data) = 'object' and p_data ? 'results' then
    v_list := p_data -> 'results';          -- Aros API sahifalangan javobi
  else
    v_list := p_data;
  end if;

  if jsonb_typeof(v_list) <> 'array' then
    return jsonb_build_object('ok', false,
      'error', 'JSON massiv kutilgan edi (yoki {transferlar:[...]}), keldi: '
               || jsonb_typeof(v_list));
  end if;

  -- ---- 2. CUTOFF ----------------------------------------------------
  -- Chegara = daftar Aros bilan OXIRGI marta tenglashtirilgan payt
  -- (oxirgi delta sync). Undan oldingi transferlar daftarga allaqachon
  -- singib ketgan — ularni yozish IKKI MARTA AYIRISH demak.
  -- Yagona manba: aros_transfer_cutoff() (0.5-bo'lim).
  v_cut_info   := aros_transfer_cutoff(p_from);
  v_cutoff     := nullif(v_cut_info ->> 'cutoff', '')::timestamptz;
  v_cutoff_man := v_cut_info ->> 'manba';

  if v_cutoff is null and not p_dry_run then
    return jsonb_build_object('ok', false,
      'error', 'CUTOFF topilmadi — hech narsa yozilmadi. Chegara "daftar Aros bilan '
               || 'oxirgi marta qachon tenglashtirilgan" degani; usiz eski transferni '
               || 'yozish pulni IKKI MARTA ayirib yuboradi. Delta sync (sync_filial_balans) '
               || 'hech qachon ishlamaganga o''xshaydi — avval uni ishlating, '
               || 'yoki p_from ni aniq bering.',
      'cutoff_info', v_cut_info,
      'maslahat', 'select sync_transfer_balans(''[...]''::jsonb, false, ''2026-07-31T12:00:00+05'')');
  end if;

  -- p_from berilgan, lekin chegaradan OLDIN edi -> e'tiborsiz qoldirildi.
  -- Jimgina o'tkazib yubormaymiz: qo'lda berilgan sana himoyani ochib
  -- yuborishga urinayotgan bo'lishi mumkin.
  if coalesce((v_cut_info ->> 'p_from_ishlatilmadi')::boolean, false) then
    v_ogoh := v_ogoh || jsonb_build_object(
      'p_from', p_from,
      'sabab', 'p_from chegaradan OLDIN — e''tiborsiz qoldirildi. Cutoff faqat '
               || 'qattiqlashtirilishi mumkin (kechroq sana). Ishlatilgan cutoff: '
               || coalesce(v_cutoff::text, '(yo''q)'));
  end if;

  -- ---- 3. Zaxira dollar kursi ---------------------------------------
  if to_regprocedure('public.conv_baza_kurs(text)') is not null then
    begin
      execute 'select conv_baza_kurs($1)' into v_baza_rate using 'USD';
    exception when others then
      v_baza_rate := null;
    end;
  end if;

  -- ---- 4. Har transfer ----------------------------------------------
  for v_el in select * from jsonb_array_elements(v_list)
  loop
    n_jami := n_jami + 1;

    -- 4.1 id (majburiy — takrorlanmaslik shunga tayanadi)
    v_tr_id := nullif(btrim(coalesce(v_el ->> 'id', v_el ->> 'transfer_id', '')), '');
    if v_tr_id is null then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', null, 'sabab', 'transfer id yo''q — ext_ref yasab bo''lmaydi');
      continue;
    end if;

    -- 4.2 status: faqat 'received' yoziladi
    v_status := lower(btrim(coalesce(nullif(v_el ->> 'status', ''), 'received')));
    if v_status <> 'received' then
      n_status := n_status + 1;
      continue;
    end if;

    -- 4.3 received_at (majburiy — cutoff shunga qarab ishlaydi)
    v_txt := nullif(btrim(coalesce(v_el ->> 'received_at',
                                   v_el ->> 'received_datetime', '')), '');
    v_recv := null;
    if v_txt is not null then
      -- Aros vaqtni zonasiz (naive, Toshkent vaqtida) saqlaydi -> +05 qo'shamiz.
      -- ⚠️ "Zona bormi" tekshiruvi ehtiyotkor yozilgan: sanadagi tire ('2026-07-30')
      --    zona deb o'qilib qolmasin. Shuning uchun zona faqat VAQT qismidan keyin
      --    tan olinadi, sana-only alohida ko'riladi.
      if v_txt ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_txt := v_txt || 'T00:00:00+05';
      elsif v_txt !~ '([Zz]|[+-][0-9]{2}:[0-9]{2}|[+-][0-9]{4}|:[0-9]{2}(\.[0-9]+)?[+-][0-9]{2})$' then
        v_txt := v_txt || '+05';
      end if;
      begin
        v_recv := v_txt::timestamptz;
      exception when others then
        v_recv := null;
      end;
    end if;

    if v_recv is null then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', v_tr_id,
        'sabab', 'received_at yo''q yoki o''qib bo''lmadi — cutoff tekshirib bo''lmaydi, '
                 || 'yozilmadi (received_at: ' || coalesce(v_el ->> 'received_at', '(yo''q)') || ')');
      continue;
    end if;

    -- 4.4 CUTOFF: daftarga allaqachon singib ketgan transferlar
    -- `<=` (kichik YOKI TENG): chegara ustidagi transfer ham yozilmaydi.
    -- Konservativ yo'nalish — shubhada yozmaslik.
    if v_cutoff is not null and v_recv <= v_cutoff then
      n_eski := n_eski + 1;
      -- ⭐ YANGI: IZ QOLDIRAMIZ. Avval bu jimgina "continue" edi — 2026-08-12 da
      -- 9 ta transfer (352 835 000 so'm) aynan shu yerda IZSIZ yo'qolgan: javobda
      -- faqat "cutoffdan_eski: 9" raqami turardi. Endi qaysi transfer, qachon,
      -- kimdan-kimga — javobda ham, aros_transfer_dropped logida ham ko'rinadi.
      -- Bu blok PUL YOZMAYDI, faqat ro'yxatga qo'shadi.
      if jsonb_array_length(v_eski_ruy) < 500 then
        v_eski_ruy := v_eski_ruy || jsonb_build_object(
          'transfer', v_tr_id,
          'received_at', v_recv,
          'kimdan', coalesce(v_el ->> 'sender_title', v_el ->> 'sender'),
          'kimga', coalesce(v_el ->> 'receiver_title', v_el ->> 'receiver'),
          'cutoff', v_cutoff,
          'sabab', 'received_at <= cutoff (' || coalesce(v_cutoff_man, '?') || ')');
      end if;
      continue;
    end if;

    -- 4.5 Tomonlarni bog'lash
    v_send_res := aros_kassa_topish(v_el ->> 'sender_id',
                                    coalesce(v_el ->> 'sender_title', v_el ->> 'sender'));
    if not (v_send_res ->> 'ok')::boolean then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', v_tr_id, 'tomon', 'sender',
        'sabab', v_send_res ->> 'sabab');
      continue;
    end if;

    v_recv_res := aros_kassa_topish(v_el ->> 'receiver_id',
                                    coalesce(v_el ->> 'receiver_title', v_el ->> 'receiver'));
    if not (v_recv_res ->> 'ok')::boolean then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', v_tr_id, 'tomon', 'receiver',
        'sabab', v_recv_res ->> 'sabab',
        'markaziy_kassalar', v_recv_res -> 'markaziy_kassalar');
      continue;
    end if;

    v_send_id  := (v_send_res ->> 'id')::uuid;
    v_recv_id  := (v_recv_res ->> 'id')::uuid;
    v_send_nom := v_send_res ->> 'name';
    v_recv_nom := v_recv_res ->> 'name';

    if v_send_id = v_recv_id then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', v_tr_id,
        'sabab', 'jo''natuvchi va qabul qiluvchi bir xil kassa (' || v_send_nom || ') — yozilmadi');
      continue;
    end if;

    -- Qabul qiluvchi markaziy emasmi — bloklamaymiz, faqat aytamiz
    select kassa_turi into v_recv_turi from accounts where id = v_recv_id;

    -- 4.6 Transferning o'z kursi (dollar uchun)
    v_tr_rate := null;
    if (v_el ? 'dollar_rate') and jsonb_typeof(v_el -> 'dollar_rate') <> 'null' then
      v_tr_rate := nullif(v_el ->> 'dollar_rate', '')::numeric;
    elsif (v_el ? 'currency_rate') and jsonb_typeof(v_el -> 'currency_rate') = 'object' then
      v_tr_rate := nullif(v_el -> 'currency_rate' ->> 'rate', '')::numeric;
    elsif (v_el ? 'currency_rate') and jsonb_typeof(v_el -> 'currency_rate') in ('number','string') then
      v_tr_rate := nullif(v_el ->> 'currency_rate', '')::numeric;
    elsif (v_el ? 'rate') and jsonb_typeof(v_el -> 'rate') in ('number','string') then
      v_tr_rate := nullif(v_el ->> 'rate', '')::numeric;
    end if;

    v_sana := least((v_recv at time zone 'Asia/Tashkent')::date,
                    (now() at time zone 'Asia/Tashkent')::date);

    -- ---- 4.7 HAR TUR ----
    foreach v_maydon in array array['cash','click','payme','dollar_usd']
    loop
      -- Summa (sinonim maydonlar bilan)
      v_amt := null;
      begin
        v_amt := nullif(btrim(coalesce(
                   case v_maydon
                     when 'cash'       then coalesce(v_el ->> 'cash',  v_el ->> 'seller_cash')
                     when 'click'      then coalesce(v_el ->> 'click', v_el ->> 'seller_click')
                     when 'payme'      then coalesce(v_el ->> 'payme', v_el ->> 'seller_payme')
                     when 'dollar_usd' then coalesce(v_el ->> 'dollar_usd',
                                                     v_el ->> 'seller_dollar',
                                                     v_el ->> 'dollar')
                   end, '')), '')::numeric;
      exception when others then
        v_amt := null;
      end;

      if v_amt is null or v_amt <= 0 then
        continue;                       -- bu turda pul o'tmagan
      end if;

      -- Takror? (is_deleted bo'lsa ham qayta yozmaymiz — admin o'chirganini tiriltirmasin)
      v_ext := 'aros_tr:' || v_tr_id || ':' || v_maydon;
      if exists (select 1 from entry where ext_ref = v_ext) then
        n_takror := n_takror + 1;
        continue;
      end if;

      -- ⭐ YANGI: QO'LDA TO'G'IRLANGANMI (aros_tr_fix:<id>:<tur>)
      -- Kalitlar boshqa-boshqa bo'lgani uchun ext_ref UNIQUE buni tutolmaydi,
      -- lekin IKKALASI HAM markaziy kassaga pul kiritadi -> yozilsa IKKI MARTA.
      -- Bu tekshiruv trigger (trg_aros_tr_fix_guard) bilan IKKI QAVAT: trigger
      -- oxirgi to'siq, bu esa toza hisobot beradi (n_fix + ogohlantirish).
      -- `tur` nomlari TUZATISH skriptiniki: naqd | click | payme | dollar.
      v_fix_ext := 'aros_tr_fix:' || v_tr_id || ':' ||
                   case v_maydon when 'cash'       then 'naqd'
                                 when 'dollar_usd' then 'dollar'
                                 else v_maydon end;
      if exists (select 1 from entry where ext_ref = v_fix_ext and is_deleted = false) then
        n_fix := n_fix + 1;
        v_ogoh := v_ogoh || jsonb_build_object(
          'transfer', v_tr_id, 'tur', v_maydon, 'summa', v_amt,
          'fix_kalit', v_fix_ext,
          'sabab', 'qo''lda to''g''irlangan (aros_tr_fix) — sinxron qayta yozmaydi, '
                   || 'aks holda markaziy kassa pulni IKKI MARTA olardi');
        continue;
      end if;

      -- Dt/Kt hisoblari
      v_dt := aros_tur_hisob(v_recv_id, v_maydon);
      v_kt := aros_tur_hisob(v_send_id, v_maydon);

      if v_dt is null or v_kt is null then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object(
          'transfer', v_tr_id, 'tur', v_maydon, 'summa', v_amt,
          'sabab', case
                     when v_dt is null and v_kt is null then
                       'ikkala kassada ham "' || v_maydon || '" turi uchun hisob yo''q'
                     when v_dt is null then
                       'qabul qiluvchi (' || v_recv_nom || ') da "' || v_maydon || '" hisobi yo''q'
                     else
                       'jo''natuvchi (' || v_send_nom || ') da "' || v_maydon || '" hisobi yo''q'
                   end || ' — PROVODKA_SYNC_FIX.sql / SEED tur child''ini ochmaganmi?');
        continue;
      end if;

      -- Summa va valyuta
      if v_maydon = 'dollar_usd' then
        v_rate       := coalesce(v_tr_rate, v_baza_rate);
        v_kurs_manba := case when v_tr_rate is not null then 'transfer'
                             when v_baza_rate is not null then 'provodka'
                             else null end;
        if v_rate is null or v_rate <= 0 then
          n_otkaz := n_otkaz + 1;
          v_ogoh := v_ogoh || jsonb_build_object(
            'transfer', v_tr_id, 'tur', v_maydon, 'usd', v_amt,
            'sabab', 'kurs yo''q: transferda ham, Provodka''da ham USD kursi topilmadi');
          continue;
        end if;
        v_fc    := v_amt;                       -- dollar miqdori
        v_summa := round(v_amt * v_rate, 2);    -- so'm ekvivalenti
      else
        v_rate       := null;
        v_kurs_manba := null;
        v_fc         := null;
        v_summa      := v_amt;
      end if;

      if v_summa = 0 then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object(
          'transfer', v_tr_id, 'tur', v_maydon,
          'sabab', 'so''m summasi 0 ga yaxlitlandi — yozuv yozilmadi');
        continue;
      end if;

      v_lbl := case v_maydon when 'cash' then 'Naqd' when 'click' then 'Click'
                             when 'payme' then 'Payme' else 'USD' end;

      v_tafsil := v_tafsil || jsonb_build_object(
        'transfer', v_tr_id,
        'sana', v_sana,
        'tur', v_lbl,
        'jonatuvchi', v_send_nom,
        'qabul_qiluvchi', v_recv_nom,
        'summa_uzs', v_summa,
        'usd', v_fc,
        'kurs', v_rate,
        'kurs_manba', v_kurs_manba,
        'ext_ref', v_ext,
        'qabul_kassa_turi', v_recv_turi,
        'ogoh', case when coalesce(v_recv_turi, '') <> 'markaziy'
                     then 'qabul qiluvchi markaziy kassa emas (' || coalesce(v_recv_turi, '?') || ')'
                     else null end);

      if p_dry_run then
        n_yozuv := n_yozuv + 1;
        continue;
      end if;

      -- ---- YOZUV: bitta entry, ikki satr ----
      -- ext_ref UNIQUE: poyga holatida (ikki sync bir vaqtda) ikkinchisi
      -- unique_violation oladi -> takror deb sanaymiz, sync to'xtamaydi.
      begin
        insert into entry(entry_date, description, source, status,
                          created_by, fc_rate, ext_ref)
        values (v_sana,
                'Aros transfer #' || v_tr_id || ' · ' || coalesce(v_send_nom, '?')
                  || ' → ' || coalesce(v_recv_nom, '?') || ' · ' || v_lbl,
                'aros_auto', 'posted', 'aros_transfer',
                case when v_maydon = 'dollar_usd' then v_rate else null end,
                v_ext)
        returning id into v_entry;
      exception when unique_violation then
        v_entry  := null;
        n_takror := n_takror + 1;
      end;

      if v_entry is null then
        continue;
      end if;

      -- Dt: qabul qiluvchi (markaziy) — pul keldi
      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, v_dt, v_summa, 0, v_fc);
      -- Kt: jo'natuvchi (filial) — pul chiqdi
      -- ⚠️ Dollarda IKKALA satr ham valyuta hisobi, shuning uchun fc_amount
      --    ikkalasiga ham yoziladi (musbat). Ishora Dt/Kt dan kelib chiqadi:
      --    v_hisob_bal -> debit>0 ? +fc : −fc.
      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, v_kt, 0, v_summa, v_fc);

      n_yozuv := n_yozuv + 1;
    end loop;
  end loop;

  -- Muhr: transfer sync qachon ishlagani (cutoff'ga TA'SIR QILMAYDI — ma'lumot uchun)
  if not p_dry_run and to_regprocedure('public.aros_sync_stamp(text, timestamptz)') is not null then
    begin
      perform aros_sync_stamp('transfer', null);
    exception when others then
      null;   -- muhr qo'yilmasa ham sync yiqilmasin
    end;
  end if;

  v_natija := jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'sana', to_char(now() at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI:SS'),
    'cutoff', v_cutoff,
    'cutoff_manba', coalesce(v_cutoff_man, '(topilmadi — dry_run)'),
    'cutoff_info', v_cut_info,        -- to'liq diagnostika: muhr, oxirgi/birinchi delta, p_from
    'transferlar', n_jami,
    'yozuvlar', n_yozuv,              -- yozilgan entry soni (transfer × tur)
    'takror', n_takror,               -- allaqachon yozilgan (ext_ref bor)
    'received_emas', n_status,        -- sent/canceled
    'cutoffdan_eski', n_eski,         -- daftarga allaqachon singigan (oxirgi delta syncdan oldin)
    'otkazildi', n_otkaz,
    'qolda_tuzatilgan', n_fix,        -- ⭐ YANGI: aros_tr_fix bor -> ataylab o'tkazildi
    'cutoffdan_eski_royxat', v_eski_ruy,  -- ⭐ YANGI: QAYSI transferlar tashlandi
    'ogohlantirishlar', v_ogoh,
    'tafsilot', v_tafsil,
    'eslatma', 'Delta sync SHUNDAN KEYIN ishlashi shart (balanslarni qayta o''qib).');

  -- ⭐ YANGI: TASHLANGANLARNI LOGGA YOZISH.
  -- Butunlay exception ichida: log yiqilsa ham sinxron va PUL YOZUVI
  -- ta'sirlanmaydi. to_regprocedure — funksiya hali yaratilmagan bo'lsa ham
  -- (eski baza) sinxron ishlayversin.
  if to_regprocedure('public.aros_transfer_drop_yoz(jsonb, boolean)') is not null then
    begin
      perform aros_transfer_drop_yoz(v_natija, p_dry_run);
    exception when others then
      null;
    end;
  end if;

  return v_natija;
end $$;


revoke all on function sync_transfer_balans(jsonb, boolean, timestamptz)
  from public, anon, authenticated;
grant execute on function sync_transfer_balans(jsonb, boolean, timestamptz) to service_role;

comment on function sync_transfer_balans(jsonb, boolean, timestamptz) is
  '2-bosqich: Aros cachier-transfer sync. received transferlarni tur bo''yicha '
  'Dt markaziy.tur / Kt filial.tur qilib yozadi. ext_ref = aros_tr:<id>:<tur> (unique). '
  'Cutoff = aros_transfer_cutoff() (POL rejimida o''zi surilmaydi -> kechikkan transfer '
  'keyingi siklda QAYTA uriniladi). Tashlangan har transfer aros_transfer_dropped ga '
  'yoziladi. Qo''lda to''g''irlangan (aros_tr_fix) transfer qayta yozilmaydi. service_role only.';
-- ⬆⬆⬆ 1.7 ⬆⬆⬆


-- ⬇⬇⬇ 1.8 — v_aros_transfer_backlog: ochiq (hal qilinmagan) tashlanganlar ⬇⬇⬇
create or replace view v_aros_transfer_backlog as
  select d.tr_id,
         d.tur,
         d.sabab_turi,
         d.sabab,
         d.received_at,
         to_char(d.received_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI') as qabul_toshkent,
         d.cutoff,
         d.summa,
         d.urinishlar,
         d.birinchi_at,
         d.oxirgi_at,
         (now() - d.birinchi_at)                                                   as necha_vaqt,
         d.payload
    from aros_transfer_dropped d
   where d.hal_qilindi = false
   order by d.birinchi_at;

revoke all on v_aros_transfer_backlog from public, anon, authenticated;
grant select on v_aros_transfer_backlog to service_role;

comment on view v_aros_transfer_backlog is
  'Sinxron hali YOZMAGAN transferlar. Bo''sh bo''lishi kerak. Bo''sh bo''lmasa — '
  'sabab_turi ga qarang: cutoff (pol juda yuqori) / mapping (kassa yoki tur hisobi yo''q) / '
  'kurs (USD kursi yo''q) / atayin (qo''lda to''g''irlangan — normal).';
-- ⬆⬆⬆ 1.8 ⬆⬆⬆


-- ⬇⬇⬇ 1.9 — aros_transfer_wm_muzlat(): Variant A ni XAVFSIZ bajaradi ⬇⬇⬇
--  "Joriy cutoffni pol qilib qotir" — lekin faqat XAVFSIZ bo'lsa.
--  ⚠️ Ataylab HECH QACHON `raise` qilmaydi, faqat jsonb holat qaytaradi.
--     Sabab: Supabase editor butun faylni BITTA tranzaksiyada bajaradi —
--     bu yerda xato chiqsa 1-BOSQICH ham orqaga qaytib ketardi.
create or replace function aros_transfer_wm_muzlat()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pol constant timestamptz := timestamptz '2026-08-12 00:00:00+05';
  v_cur timestamptz;
  v_bor timestamptz;
begin
  select wm_at into v_bor from aros_transfer_wm where id = 1;

  if v_bor is not null then
    return jsonb_build_object('ok', true, 'ozgardi', false, 'pol', v_bor,
      'holat', '➖ Pol allaqachon qo''yilgan — tegilmadi. O''zgartirish uchun 2.2 dan foydalaning.');
  end if;

  v_cur := (aros_transfer_cutoff() ->> 'cutoff')::timestamptz;

  if v_cur is null then
    return jsonb_build_object('ok', false, 'ozgardi', false,
      'holat', '⚠️ Joriy cutoff YO''Q — muzlatib bo''lmaydi. 2.2 (Variant B) bilan aniq sana qo''ying.');
  end if;

  if v_cur < v_pol then
    return jsonb_build_object('ok', false, 'ozgardi', false, 'joriy_cutoff', v_cur,
      'holat', '⚠️ Joriy cutoff 2026-08-12 dan OLDIN — muzlatilsa boshlang''ich qoldiq davri '
               || 'ochilib ketardi. 2.2 (Variant B) bilan aniq sana qo''ying.');
  end if;

  if v_cur > now() then
    return jsonb_build_object('ok', false, 'ozgardi', false, 'joriy_cutoff', v_cur,
      'holat', '⚠️ Joriy cutoff kelajakda — muzlatilmadi. 2.2 bilan aniq sana qo''ying.');
  end if;

  perform aros_transfer_wm_set(v_cur,
    'A — joriy cutoff muzlatildi (CUTOFF_FIX 1.9/2.1). Xatti-harakat o''zgarmadi, '
    || 'faqat avtomatik surilish to''xtadi.');

  return jsonb_build_object('ok', true, 'ozgardi', true, 'pol', v_cur,
    'pol_toshkent', to_char(v_cur at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI'),
    'holat', '✅ Pol joriy cutoffda muzlatildi. Bugundan boshlab cutoff O''ZI SURILMAYDI.');
end $$;

revoke all on function aros_transfer_wm_muzlat() from public, anon, authenticated;
grant execute on function aros_transfer_wm_muzlat() to service_role;

comment on function aros_transfer_wm_muzlat() is
  'Variant A: joriy cutoffni pol qilib qotiradi (xatti-harakat o''zgarmaydi, faqat '
  'avtomatik surilish to''xtaydi). Xavfsiz bo''lmasa hech narsa qilmaydi va sababni qaytaradi. '
  'Hech qachon xato ko''tarmaydi.';
-- ⬆⬆⬆ 1.9 ⬆⬆⬆



-- #####################################################################
--  2-BOSQICH — POLni QO'YISH.  🔴 ASILBEK SHU BLOKNI TAHRIRLAYDI.
-- #####################################################################
--  Shu paytgacha hech narsa o'zgarmadi (pol null -> eski mantiq).
--  O'zgarish AYNAN shu yerda boshlanadi.
--
--  🔴 QOIDA: pol 2026-08-12 dan KEYIN turishi SHART.
--     Undan oldingi transferlar:
--       • 31-iyul – 11-avgust (~74 ta) — boshlang'ich qoldiqqa kirgan;
--       • 12-avgust (9 ta, 352 835 000 so'm) — qo'lda tiklangan (aros_tr_fix).
--     Ularni qayta ochish pulni IKKI MARTA yozardi. Funksiya 2026-08-12 dan
--     oldingi polni p_force siz RAD ETADI — bu qasddan qo'yilgan to'siq.
--
--  IKKI VARIANT BOR. TARTIB BILAN BORING: avval A, keyin (kerak bo'lsa) B.


-- ⬇⬇⬇ 2.1 — VARIANT A (TAVSIYA, BIRINCHI QADAM): joriy cutoffni MUZLATISH ⬇⬇⬇
--  Nima qiladi: hozirgi cutoff qiymatini pol qilib qotiradi.
--  Nima o'zgaradi: BUGUN — hech narsa. Ertaga — cutoff endi O'ZI SURILMAYDI,
--                  ya'ni "bir sikl kechikkan transfer abadiy yo'qoladi" bug'i
--                  BUGUNDAN BOSHLAB QAYTALANMAYDI.
--  Nega birinchi: eski backlog ochilmaydi, ya'ni bu qadamning pul xavfi NOL.
--  Keyin: bir-ikki sikl kutib, 3.6 / 3.7 select'larida LOGni ko'ring —
--         qaysi transferlar cutoff bilan tashlanayotgani ENDI ko'rinadi.
--
--  ⚠️ XAVFSIZ: bu chaqiruv hech qachon xato ko'tarmaydi. Cutoff yo'q bo'lsa,
--     12-avgustdan oldin bo'lsa yoki pol allaqachon qo'yilgan bo'lsa —
--     HECH NARSA QILMAYDI va sababni `holat` ustunida yozib beradi.
--     Ya'ni butun faylni bir marta RUN qilib yuborsangiz ham xavf yo'q.
select aros_transfer_wm_muzlat() as natija;
-- ⬆⬆⬆ 2.1 ⬆⬆⬆


-- ⬇⬇⬇ 2.2 — VARIANT B: POLni ANIQ sanaga qo'yish (backlogni ochish) ⬇⬇⬇
--  🔴 SANANI SHU YERDA TAHRIRLANG. Boshqa hech qayerda sana yozilmagan.
--
--  Nima qiladi: poldan KEYINGI hamma transfer sinxronga ochiladi va HAR
--               siklda qayta uriniladi.
--  Qachon kerak: 2.1 dan keyin logda (3.7) haqiqatan yo'qolgan transfer
--               ko'rinsa — polni o'shalardan OLDINGA tushirasiz.
--
--  Himoya qavatlari (pol tushganda ishlaydiganlari):
--    1. ext_ref UNIQUE      -> allaqachon yozilgani qayta yozilmaydi
--    2. aros_tr_fix guard   -> qo'lda tiklangani qayta yozilmaydi (1.6)
--    3. funksiya to'siqlari -> 2026-08-12 dan oldin / orqaga surish -> rad
--
--  TAVSIYA ETILGAN QIYMAT: 0.5 select'i chiqargan `tavsiya_pol`.
--  Pastdagi standart qiymat — 13-avgust 00:00 (Toshkent), ya'ni 12-avgust
--  to'liq yopiq qoladi.
--
--  ISHLATISH: pastdagi qatordan `--` ni oling va sanani to'g'rilang.

-- select aros_transfer_wm_set(
--          timestamptz '2026-08-13 00:00:00+05',   -- ⬅️ SHU SANANI TAHRIRLANG
--          'B — pol 2026-08-13 00:00 Toshkent (CUTOFF_FIX 2.2). Undan keyingi '
--          || 'transferlar har siklda qayta uriniladi.') as natija;
-- ⬆⬆⬆ 2.2 ⬆⬆⬆


-- ⬇⬇⬇ 2.3 — (kerak bo'lsa) POLni O'CHIRISH: eski mantiqqa qaytish ⬇⬇⬇
--  Faqat rollback uchun. Bug qaytadi — ataylab qilmang.
-- update aros_transfer_wm set wm_at = null, izoh = 'rollback', updated_at = now() where id = 1;
-- ⬆⬆⬆ 2.3 ⬆⬆⬆



-- #####################################################################
--  3-BOSQICH — TEKSHIRUV.  FAQAT `select`. HECH NARSA YOZMAYDI.
-- #####################################################################


-- ⬇⬇⬇ 3.1 — Obyektlar yaratildimi ⬇⬇⬇
select 'aros_transfer_wm (pol jadvali)' as obyekt,
       case when to_regclass('public.aros_transfer_wm') is not null
            then '✅ bor' else '❌ YO''Q' end as holat
union all
select 'aros_transfer_dropped (log)',
       case when to_regclass('public.aros_transfer_dropped') is not null
            then '✅ bor' else '❌ YO''Q' end
union all
select 'v_aros_transfer_backlog (view)',
       case when to_regclass('public.v_aros_transfer_backlog') is not null
            then '✅ bor' else '❌ YO''Q' end
union all
select 'aros_transfer_wm_set()',
       case when to_regprocedure('public.aros_transfer_wm_set(timestamptz,text,boolean)') is not null
            then '✅ bor' else '❌ YO''Q' end
union all
select 'aros_transfer_drop_yoz()',
       case when to_regprocedure('public.aros_transfer_drop_yoz(jsonb,boolean)') is not null
            then '✅ bor' else '❌ YO''Q' end
union all
select 'trg_aros_tr_fix_guard (entry ustida)',
       case when exists (select 1 from pg_trigger t
                          join pg_class c on c.oid = t.tgrelid
                         where t.tgname = 'trg_aros_tr_fix_guard'
                           and c.relname = 'entry' and not t.tgisinternal)
            then '✅ o''rnatilgan' else '❌ YO''Q — 1.6 ni qayta RUN qiling' end
union all
select 'sync_transfer_balans imzosi o''zgarmagan',
       case when to_regprocedure('public.sync_transfer_balans(jsonb,boolean,timestamptz)') is not null
            then '✅ (jsonb, boolean, timestamptz) joyida'
            else '❌ IMZO BUZILGAN — n8n chaqiruvi sinadi!' end;
-- ⬆⬆⬆ 3.1 ⬆⬆⬆


-- ⬇⬇⬇ 3.2 — Cutoff endi qayerdan kelyapti ⬇⬇⬇
select aros_transfer_cutoff() ->> 'rejim'                              as rejim,
       (aros_transfer_cutoff() ->> 'cutoff')::timestamptz              as cutoff,
       to_char((aros_transfer_cutoff() ->> 'cutoff')::timestamptz
                 at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI')   as cutoff_toshkent,
       aros_transfer_cutoff() ->> 'manba'                              as manba,
       case when aros_transfer_cutoff() ->> 'rejim' = 'pol'
            then '✅ POL rejimi — cutoff o''zi SURILMAYDI'
            else '⚠️ hali eski rejim — 2-BOSQICH bajarilmagan' end     as holat,
       (aros_transfer_cutoff() ->> 'oxirgi_delta_yozuvi')::timestamptz as eski_mantiq_bergan_bolardi;
-- ⬆⬆⬆ 3.2 ⬆⬆⬆


-- ⬇⬇⬇ 3.3 — Pol holati ⬇⬇⬇
select w.wm_at                                                            as pol,
       to_char(w.wm_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI') as pol_toshkent,
       w.izoh,
       w.updated_at,
       w.updated_by,
       case when w.wm_at is null           then '⚠️ pol yo''q — eski mantiq ishlayapti'
            when w.wm_at < timestamptz '2026-08-12 00:00:00+05'
                                            then '🔴 POL 12-AVGUSTDAN OLDIN — boshlang''ich qoldiq davri OCHIQ!'
            when w.wm_at > now()            then '🔴 POL KELAJAKDA — hamma transfer to''silyapti'
            else '✅ pol to''g''ri oraliqda' end                          as holat
  from aros_transfer_wm w
 where w.id = 1;
-- ⬆⬆⬆ 3.3 ⬆⬆⬆


-- ⬇⬇⬇ 3.4 — 🔴 IKKI MARTA YOZILGANLIK DETEKTORI ⬇⬇⬇
--  Bitta transfer+tur uchun HAM sinxron yozuvi (aros_tr:), HAM qo'lda
--  to'g'irlash (aros_tr_fix:) bo'lsa — markaziy kassa pulni IKKI MARTA olgan.
--  Bu SELECT har o'zgarishdan keyin ✅ chiqishi SHART.
with s as (
  select split_part(e.ext_ref, ':', 2) as tr_id,
         case split_part(e.ext_ref, ':', 3)
           when 'cash'       then 'naqd'
           when 'dollar_usd' then 'dollar'
           else split_part(e.ext_ref, ':', 3)
         end                           as tur
    from entry e
   where left(e.ext_ref, 8) = 'aros_tr:' and e.is_deleted = false
),
f as (
  select split_part(e.ext_ref, ':', 2) as tr_id,
         split_part(e.ext_ref, ':', 3) as tur
    from entry e
   where left(e.ext_ref, 12) = 'aros_tr_fix:' and e.is_deleted = false
)
select case when count(*) = 0
            then '✅ TOZA — birorta transfer ikki marta yozilmagan'
            else '❌ ' || count(*)::text || ' ta transfer/tur IKKI MARTA — DARHOL TEKSHIRING'
       end as holat
  from (select tr_id, tur from s intersect select tr_id, tur from f) x;
-- ⬆⬆⬆ 3.4 ⬆⬆⬆


-- ⬇⬇⬇ 3.5 — 3.4 ❌ bo'lsa: qaysi transferlar (tafsilot) ⬇⬇⬇
with s as (
  select split_part(e.ext_ref, ':', 2) as tr_id,
         case split_part(e.ext_ref, ':', 3)
           when 'cash'       then 'naqd'
           when 'dollar_usd' then 'dollar'
           else split_part(e.ext_ref, ':', 3)
         end                           as tur
    from entry e
   where left(e.ext_ref, 8) = 'aros_tr:' and e.is_deleted = false
),
f as (
  select split_part(e.ext_ref, ':', 2) as tr_id,
         split_part(e.ext_ref, ':', 3) as tur
    from entry e
   where left(e.ext_ref, 12) = 'aros_tr_fix:' and e.is_deleted = false
),
juft as (select tr_id, tur from s intersect select tr_id, tur from f)
select j.tr_id,
       j.tur,
       e.ext_ref,
       e.entry_date,
       e.description,
       e.created_by,
       (select sum(l.debit) from entry_line l where l.entry_id = e.id) as dt_summa
  from juft j
  join entry e
    on e.is_deleted = false
   and (e.ext_ref = 'aros_tr_fix:' || j.tr_id || ':' || j.tur
        or e.ext_ref = 'aros_tr:' || j.tr_id || ':' ||
           case j.tur when 'naqd' then 'cash' when 'dollar' then 'dollar_usd' else j.tur end)
 order by j.tr_id, e.ext_ref;
-- ⬆⬆⬆ 3.5 ⬆⬆⬆


-- ⬇⬇⬇ 3.6 — ext_ref takrorlanmaganini tasdiqlash (1-qavat sog'ligi) ⬇⬇⬇
select case when count(*) = 0
            then '✅ ext_ref takrorlanmagan — 1-qavat himoya sog''lom'
            else '❌ ' || count(*)::text || ' ta takroriy ext_ref — UNIQUE indeks yo''q!'
       end as holat
  from (select ext_ref from entry
         where ext_ref is not null group by ext_ref having count(*) > 1) d;
-- ⬆⬆⬆ 3.6 ⬆⬆⬆


-- ⬇⬇⬇ 3.7 — BACKLOG: sinxron hali yozmagan transferlar ⬇⬇⬇
--  Bir-ikki sinxron siklidan KEYIN qarang (n8n har 30 daqiqada).
--  Bo'sh bo'lsa — hammasi yozilgan.
select * from v_aros_transfer_backlog;
-- ⬆⬆⬆ 3.7 ⬆⬆⬆


-- ⬇⬇⬇ 3.8 — LOG statistikasi: sabab bo'yicha ⬇⬇⬇
select d.sabab_turi,
       count(*)                                        as transferlar,
       sum(d.urinishlar)                               as jami_urinish,
       count(*) filter (where d.hal_qilindi)           as keyin_yozilgan,
       count(*) filter (where not d.hal_qilindi)       as hali_ochiq,
       min(d.birinchi_at)                              as eng_eski,
       max(d.oxirgi_at)                                as eng_yangi,
       case d.sabab_turi
         when 'cutoff' then 'Pol juda yuqori — 2.2 bilan pastga tushiring'
         when 'mapping' then 'Kassa yoki tur hisobi yo''q — sozlama/SEED tekshiring'
         when 'kurs'    then 'USD kursi yo''q — Valyuta bo''limiga kurs qo''shing'
         when 'atayin'  then 'Qo''lda to''g''irlangan — NORMAL, aralashmang'
         else 'Qo''lda ko''ring (payload ustuni)'
       end                                             as nima_qilish
  from aros_transfer_dropped d
 group by d.sabab_turi
 order by 5 desc, 2 desc;
-- ⬆⬆⬆ 3.8 ⬆⬆⬆


-- ⬇⬇⬇ 3.9 — Sinxron oxirgi 7 kunda nima yozdi (nazorat) ⬇⬇⬇
select e.entry_date,
       count(*)                                        as yozuvlar,
       count(distinct split_part(e.ext_ref, ':', 2))   as transferlar,
       sum(l.debit)                                    as jami_uzs
  from entry e
  join entry_line l on l.entry_id = e.id and l.debit > 0
 where left(e.ext_ref, 8) = 'aros_tr:'
   and e.is_deleted = false
   and e.entry_date >= (now() at time zone 'Asia/Tashkent')::date - 7
 group by 1
 order by 1 desc;
-- ⬆⬆⬆ 3.9 ⬆⬆⬆



-- #####################################################################
--  ROLLBACK — hamma narsani ortga qaytarish (izohda, RUN qilinmagan)
-- #####################################################################
--
--  Bosqichma-bosqich, eng yumshog'idan eng qattig'iga.
--
--  R1) Faqat POLni o'chirish — cutoff eski (o'zi suriluvchi) mantiqqa qaytadi.
--      Bug ham qaytadi. Log va guard joyida qoladi.
--        update aros_transfer_wm set wm_at = null, izoh = 'rollback R1',
--               updated_at = now() where id = 1;
--
--  R2) fix-guard triggerini o'chirish (qo'lda to'g'irlangan transferni
--      sinxron qayta yozishiga yo'l ochiladi — TAVSIYA ETILMAYDI):
--        drop trigger if exists trg_aros_tr_fix_guard on entry;
--
--  R3) sync_transfer_balans va aros_transfer_cutoff ni ESKI holiga qaytarish:
--        PROVODKA_TRANSFER.sql ni qayta RUN qiling (u ikkalasini ham
--        create or replace qiladi). Iz qoldirish va n_fix hisobi yo'qoladi.
--        ⚠️ Bu holda 1.4 (aros_transfer_drop_yoz) chaqirilmay qoladi — funksiya
--           turaveradi, zarari yo'q.
--
--  R4) Log va pol jadvallarini butunlay olib tashlash (pul yozmaydi,
--      shoshilinch emas):
--        drop view  if exists v_aros_transfer_backlog;
--        drop table if exists aros_transfer_dropped;
--        drop table if exists aros_transfer_wm;
--        drop function if exists aros_transfer_wm_set(timestamptz, text, boolean);
--        drop function if exists aros_transfer_drop_yoz(jsonb, boolean);
--        drop function if exists aros_tr_fix_guard();
--      ⚠️ aros_transfer_wm o'chirilsa aros_transfer_cutoff() o'zi eski
--         mantiqqa qaytadi (to_regclass tekshiruvi bor) — sinmaydi.
--
--  🔴 HECH QACHON: `aros_tr:` yoki `aros_tr_fix:` ext_ref li yozuvlarni
--     DELETE qilmang. O'chirish kerak bo'lsa — jurnaldan soft-delete
--     (is_deleted = true). Hard delete qilinsa idempotentlik kaliti
--     yo'qoladi va keyingi sikl o'sha pulni QAYTA yozadi.
--
--
--  #####  KEYINGI QADAM (n8n — MAJBURIY EMAS)  ########################
--
--  Bu fayl n8n'dan HECH NARSA talab qilmaydi: `sync_transfer_balans`
--  imzosi ham, kutilayotgan JSON ham o'zgarmadi.
--
--  Ixtiyoriy yaxshilanish: `Aros Provodka - Transfer Sync` javobida endi
--  `cutoffdan_eski_royxat`, `qolda_tuzatilgan` kalitlari bor. Ularni
--  Telegram/xabarnomaga chiqarish mumkin — lekin baza LOGi (3.7) baribir
--  yozib boradi, shuning uchun shart emas.
--
--  ⚠️ Delta sinxroni (`Aros Provodka - Auto Sync`) qayta yoqilsa:
--     tartib o'zgarmaydi — AVVAL transfer, KEYIN delta. Sabab fayl
--     boshidagi "DELTA SINXRONI QAYTA YOQILSA" bo'limida.
-- =====================================================================
