-- =====================================================================
--  PROVODKA_SOROVLAR.sql
--  PUL SO'ROVLARI — hodim balansidan ko'p xarajat yozsa TO'SILMAYDI,
--  xarajat PENDING bo'lib tushadi va pul SO'RALADI.
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). Dev-first. Asilbek RUN qiladi.
--  Brief:   BRIEF_PROVODKA_SOROVLAR.md (1-band, "Oqim", "XAVFSIZLIK / edge case")
--  UI:      .sorov-ui.md (dizayner kontrakti — RPC nomlari, javob shakllari)
--
--  #####  OQIM (bir qarashda)  ########################################
--
--   1) Hodim 500 000 xarajat yozdi, qo'lida 100 000. "Pul so'rash".
--   2) `sorov_yarat(...)` — BITTA TRANZAKSIYADA:
--        * `entry` (status='pending') + 2 ta `entry_line`
--          Dt xarajat modda / Kt hodim kassasi
--        * `sorovlar` qatori (kimdan, qancha, izoh)
--      🔴 `status='pending'` yozuv BALANSGA UMUMAN TA'SIR QILMAYDI —
--      butun hisob-kitob `status='posted'` bilan filtrlangan (0.3 auditi).
--   3) So'ralgan odam (yoki ADMIN) `sorovlar-dev.html` da ko'radi:
--        `sorov_tasdiq(id, summa, kassa)` — to'liq yoki qisman;
--        `kassa` = qaysi hisobdan (ildiz yoki Naqd/Click/Payme bolasi)
--        `sorov_rad(id, sabab)`     — sabab MAJBURIY
--   4) Tasdiqda:
--        * pul provodkasi: Dt hodim kassasi / Kt tasdiqlovchi kassasi (posted)
--        * pending xarajat YOPILADI (pending -> posted) — LEKIN faqat
--          o'shanda pul YETSA (8.6 ga qara), aks holda pending qoladi.
--
--  #####  BU FAYL NIMA YARATADI  ######################################
--
--   0-BO'LIM  Old shart + DIAGNOSTIKA (hech narsa yozmaydi)
--             🔴 `status='posted'` filtri AUDITI — pending pul sizadimi?
--   1-BO'LIM  perm_pages() ga 'sorovlar' kaliti (16 -> 17)
--   2-BO'LIM  `sorovlar` jadvali + indekslar + RLS
--   3-BO'LIM  Ichki yordamchilar (page guard, qoldiq, kassa, nomzod, qator)
--   4-BO'LIM  perm_guard_entry_line() — MA'LUMOT bilan tasdiqlangan istisno
--   5-BO'LIM  sorov_kimdan()
--   6-BO'LIM  sorov_yarat()          <- ATOMIK (yetim sarlavha YO'Q)
--   7-BO'LIM  sorov_royxat() · sorov_menikilar() · sorov_qaror_ctx()
--   8-BO'LIM  sorov_tasdiq()         <- idempotent, for update + unique ext_ref
--   9-BO'LIM  sorov_rad() · sorov_xarajat_bekor()
--  10-BO'LIM  notify pgrst
--  11-BO'LIM  TEKSHIRUV (katalog so'rovlari)
--  12-BO'LIM  ROLLBACK (izohda)
--  13-BO'LIM  KLIENT KONTRAKTI (coder uchun)
--
--  #####  QAT'IY QOIDALAR (buzma)  ####################################
--
--   * ADDITIVE: birorta mavjud ustun/funksiya O'CHIRILMAYDI, birorta
--     imzo O'ZGARMAYDI. Yagona qayta yozilgan mavjud obyekt —
--     `perm_pages()` (kalit qo'shildi) va `perm_guard_entry_line()`
--     (4-BO'LIM, faqat RAD ETISH yo'liga ma'lumot bilan tasdiqlangan
--     istisno qo'shildi — imzo va tanadagi eski mantiq o'sha-o'sha).
--   * Faylda `do` bloki YO'Q, JONLI RPC chaqiruvi YO'Q — Postgres butun
--     skriptni bitta tranzaksiyada bajaradi, bitta 42501 hammasini
--     orqaga qaytarardi (PROVODKA_JURNAL_V2.sql saboqi).
--   * Funksiya tanasi NOMLANGAN teg bilan (izohda dollar-qavs YOZILMAYDI --
--     u editorning juftlik sanogini buzadi va 42P01 beradi; CLAUDE.md 729).
--   * 🔴 SO'ROVNI SO'RALGAN ODAM YOKI ADMIN TASDIQLAYDI (Asilbek qarori,
--     2026-08-25 jonli sinovdan keyin o'zgardi — avval "admin ham emas"
--     edi). Kodda bu YAGONA shart, ikki joyda takrorlanadi:
--       `if s.kimdan_id <> v_uid and not is_admin()`
--     — 8-BO'LIM `sorov_tasdiq`, 9-BO'LIM `sorov_rad` (+ 7.3 dagi hosila).
--     🔴 ADMIN TASDIQLAGANDA PUL SO'ROV KELGAN ODAMNING KASSASIDAN
--     CHIQADI (adminda kassa biriktirilmagan). Ya'ni admin boshqa odam
--     nomidan qaror qiladi — ongli qaror, 8.1 da asos bilan yozilgan.
--     Qattiqlashtirish: o'sha ikki qatordan `and not is_admin()` ni
--     olib tashlang, boshqa hech qayerga tegilmaydi.
--
--  TALAB (RUN qilinmagan bo'lsa 0-BO'LIM aytadi):
--     PROVODKA_PERMS.sql        — user_perms, perm_op_key, perm_check_accounts,
--                                 perm_guard_entry_line, perm_pages
--     PROVODKA_EXT_REF.sql      — entry.ext_ref UNIQUE indeksi (takror himoyasi)
--     PROVODKA_ISM.sql          — profiles.full_name (ixtiyoriy: bo'lmasa
--                                 ism kassa nomidan olinadi)
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART + DIAGNOSTIKA.  HECH NARSA YOZMAYDI.      ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 0.1  Old shartlar joyidami
-- ---------------------------------------------------------------------
select 'user_perms'               as tekshiruv,
       case when to_regclass('public.user_perms') is not null
            then 'BOR' else 'YOQ — avval PROVODKA_PERMS.sql' end as natija
union all
select 'perm_op_key(uuid)',
       case when to_regprocedure('public.perm_op_key(uuid)') is not null
            then 'BOR' else 'YOQ — avval PROVODKA_PERMS.sql' end
union all
select 'perm_check_accounts(uuid[])',
       case when to_regprocedure('public.perm_check_accounts(uuid[])') is not null
            then 'BOR' else 'YOQ — avval PROVODKA_PERMS.sql' end
union all
select 'perm_guard_entry_line()',
       case when to_regprocedure('public.perm_guard_entry_line()') is not null
            then 'BOR' else 'YOQ — avval PROVODKA_PERMS.sql' end
union all
select 'is_admin()',
       case when to_regprocedure('public.is_admin()') is not null
            then 'BOR' else 'YOQ — asosiy migratsiya bajarilmagan' end
union all
select 'perm_pages()',
       case when to_regprocedure('public.perm_pages()') is not null
            then 'BOR' else 'YOQ — avval PROVODKA_PERMS.sql' end
union all
select 'entry.ext_ref UNIQUE',
       case when exists (select 1 from pg_indexes
                          where schemaname = 'public' and tablename = 'entry'
                            and indexdef ilike '%unique%' and indexdef ilike '%ext_ref%')
            then 'BOR' else 'YOQ — avval PROVODKA_EXT_REF.sql (takror himoyasi)' end
union all
select 'profiles.full_name',
       case when exists (select 1 from information_schema.columns
                          where table_schema='public' and table_name='profiles'
                            and column_name='full_name')
            then 'BOR' else 'YOQ — ism kassa nomidan olinadi (xato emas)' end
union all
select 'accounts.pul_turi',
       case when exists (select 1 from information_schema.columns
                          where table_schema='public' and table_name='accounts'
                            and column_name='pul_turi')
            then 'BOR' else 'YOQ — avval PROVODKA_VALYUTA.sql' end;

-- ---------------------------------------------------------------------
-- 0.2  🔴 `entry.status` — 'pending' qiymatini qabul qiladimi?
--
--      Kutilgan: `entry.status` da CHECK constraint YO'Q (yoki 'pending'
--      ga ruxsat beradi). Agar cheklovchi CHECK chiqsa — 6-BO'LIM
--      insert'i 23514 bilan yiqiladi va butun fayl orqaga qaytadi.
--      U holda avval constraint kengaytiriladi (Asilbek qaroriga).
-- ---------------------------------------------------------------------
select conname, pg_get_constraintdef(oid) as tarif
  from pg_constraint
 where conrelid = 'public.entry'::regclass and contype = 'c'
 order by conname;

-- Hozir bazada qanday statuslar bor (kutilgan: faqat 'posted')
select status, count(*) as soni
  from entry group by status order by 2 desc;

-- ---------------------------------------------------------------------
-- 0.3  🔴🔴 ENG MUHIM AUDIT — `status='posted'` FILTRI HAMMA JOYDAMI?
--
--      Butun g'oya shunga tayanadi: `status='pending'` yozuv BALANSGA
--      TA'SIR QILMAYDI. Bitta funksiya/view filtrlamasa — pending pul
--      qoldiqqa SIZADI va hodim yo'q pulni sarflab yuboradi.
--
--      Quyidagi so'rov har obyekt tanasida `posted` so'zini yoki
--      `v_hisob_bal` (u o'zi posted bilan filtrlangan) manbasini qidiradi.
--
--      🔴 NATIJANI O'QISH:
--        'POSTED — TOGRIDAN'   — o'zi filtrlaydi, xavfsiz
--        'POSTED — v_hisob_bal orqali' — manbasi filtrlangan, xavfsiz
--        'FILTR YOQ  <-- TEKSHIRING'   — 🔴 shu obyekt orqali pending
--                                        pul sizishi MUMKIN
--        '— bazada yoq'        — obyekt bu bazada mavjud emas (xato emas)
--
--      ⚠️ `jurnal` / `jurnal_v2*` / `jurnal_dash` uchun "FILTR YOQ" —
--      sizish emas, KO'RINISH masalasi: pending yozuv jurnalda ko'rinishi
--      KERAK (brief: "jurnalga tushadi (pending)"). 13-BO'LIM ga qara.
-- ---------------------------------------------------------------------
with obj as (
  select p.proname as nom, 'funksiya' as tur, p.prosrc as src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = any (array[
       'acc_balance','acc_fc_balance','balans','pnl','cashflow','pul_qoldiq',
       'cashflow_kassa','pul_qoldiq_kassa','hodim_oz_tarix','hodim_amallar',
       'hodim_oy_jami','hodim_kassa_hisobot','hodim_kategoriya_hisobot',
       'hodim_xarajat_royxat','jurnal','jurnal_count','jurnal_v2_baza',
       'ai_rep_balans','ai_rep_cashflow','ai_rep_xarajat','ai_rep_kirim',
       'ai_ctx_kassa','ai_ctx_qarzdor','ai_ctx_transfer'])
  union all
  select c.relname, 'view', pg_get_viewdef(c.oid)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('v','m')
     and c.relname = any (array[
       'v_hisob_bal','v_hisob_qoldiq','v_kassa_qoldiq','v_kassa_card',
       'v_kassa_toliq','v_kassa_valyutalar','v_aylanma_saldo','v_pul_hisoblar'])
)
select k.nom, k.tur,
       case
         when o.src is null                          then '— bazada yoq'
         when position('posted' in o.src) > 0        then 'POSTED — TOGRIDAN'
         when position('v_hisob_bal' in o.src) > 0   then 'POSTED — v_hisob_bal orqali'
         else 'FILTR YOQ  <-- TEKSHIRING'
       end as natija
  from (select distinct nom, tur from obj) k
  left join obj o on o.nom = k.nom and o.tur = k.tur
 order by 3 desc, 1;

-- ---------------------------------------------------------------------
-- 0.4  Kimlar "kimdan so'rash" ro'yxatiga tushadi (1-BO'LIM dan KEYIN
--      qayta RUN qiling — 'sorovlar' kaliti o'shanda paydo bo'ladi).
--      🔴 Bo'sh chiqsa xususiyat ISHLAMAYDI: hech kimdan so'rab bo'lmaydi.
--      Sabab va yechim — 5-BO'LIM sarlavhasida.
-- ---------------------------------------------------------------------
-- ⚠️ `profiles.full_name` `to_jsonb()` orqali o'qiladi — PROVODKA_ISM.sql
--    RUN qilinmagan bazada ustun YO'Q va to'g'ridan murojaat butun
--    skriptni yiqitardi (Postgres hammasini bitta tranzaksiyada bajaradi).
select up.user_id,
       coalesce(nullif(btrim(coalesce(to_jsonb(pr) ->> 'full_name', '')), ''),
                k.name)                                            as nom,
       k.code, k.name as kassa, k.subtitle,
       ('sorovlar' = any(coalesce(up.allowed_pages, '{}'::text[]))) as sahifa_ruxsati
  from user_perms up
  join profiles pr on pr.id = up.user_id
  join lateral (
    select a.code, a.name, a.subtitle
      from accounts a
     where a.is_active is true and a.type = 'aktiv' and a.code like '5%'
       and coalesce(a.currency, 'UZS') = 'UZS'
       and a.pul_turi is null
       and a.kassa_turi is distinct from 'xarajat_guruh'
       and perm_op_key(a.id) = any (up.op_kassa_ids)
     order by a.code
     limit 1) k on true
 where up.kassa_scope = 'list'
 order by 2;


-- #####################################################################
-- ##  1-BO'LIM — perm_pages() ga 'sorovlar' (16 -> 17)               ##
-- #####################################################################
-- 🔴 KLIENT TOMONI — BUSIZ ISHLAMAYDI (coder bajaradi):
--    (a) `perms-dev.js` dagi `PAGES` massiviga 'sorovlar';
--    (b) `admin-dev.html` dagi `PVS_PAGES` ga {key:'sorovlar', label:"So'rovlar"};
--    (c) `index-dev.html` dagi `CARDS` ga sorovlar kartasi;
--    (d) `promote.sh` `PAGES` ga 'sorovlar'.
--    Aks holda `admin_set_provodka_perms` kalitni "noma'lum" deb JIMGINA
--    tashlab yuboradi va admin sahifani hech kimga bera olmaydi.
--
-- ⚠️ TARTIB OGOHLANTIRISHI: PROVODKA_PERMS.sql / PROVODKA_PAGES_EMPTY.sql /
--    PROVODKA_YUK_TANNARX.sql / PROVODKA_AI_AGENT.sql KEYIN RUN qilinsa
--    ular `perm_pages()` ni eski ro'yxatga qaytaradi va 'sorovlar'
--    YO'QOLADI. O'shanda 1-BO'LIMni qayta RUN qiling (11-BO'LIM aytadi).
-- #####################################################################

create or replace function perm_pages()
returns text[]
language sql
immutable
as $perm_pages$
  select array['kassa','jurnal','professional','hisobot','balans','cashflow',
               'qarzdor','filial','valyuta','konvert','sozlama','provodka',
               'yuklar','standart','tannarx','ai','sorovlar']::text[];
$perm_pages$;

revoke all on function perm_pages() from public, anon;
grant execute on function perm_pages() to authenticated, service_role;

comment on function perm_pages() is
  'Provodka sahifa kalitlari (17 ta). perms.js dagi PAGES va admin-dev PVS_PAGES bilan bir xil. '
  'hodim.html bu royxatga KIRMAYDI — u hech qachon cheklanmaydi.';


-- #####################################################################
-- ##  2-BO'LIM — `sorovlar` jadvali + indekslar + RLS                ##
-- #####################################################################
-- ## SXEMA QARORLARI
--
--  * `kassa_id`        — SO'ROVCHINING kassasi. Pending xarajat SHU
--    hisobdan chiqadi (Kt) va pul SHUNGA tushadi (Dt). Ikkalasi bitta
--    hisob bo'lishi SHART — aks holda qoldiq mos kelmaydi.
--  * `kimdan_kassa_id` — TASDIQLOVCHINING kassasi (pul chiqadigan joy).
--    So'rov paytida BELGILANADI (5-BO'LIM: odamning asosiy UZS kassasi),
--    tasdiqda QAYTA TEKSHIRILADI. Ikkalasini saqlash 4-BO'LIM dagi
--    guard istisnosini "ma'lumot bilan tasdiqlangan" qiladi.
--  * `summa`           — so'ralgan. `jonatilgan_summa` — haqiqatda berilgan.
--  * `xarajat_summa`   — audit/diagnostika nusxasi. 🔴 IKKI CHEKLOV:
--    (1) hisob-kitobda ISHLATILMAYDI — tasdiqda haqiqiy summa
--        `entry_line` dan QAYTA o'qiladi (yozuv tahrirlangan bo'lishi
--        mumkin — 8.5), "qolganini so'rash" chegarasi ham shundan (6.4);
--    (2) 🔴 KLIENTGA HECH QACHON YUBORILMAYDI (`sorov_qator` 3.6,
--        `sorov_qaror_ctx` 7.3) — tasdiqlovchi `qoldiq = xarajat_summa -
--        summa` ni hisoblab, so'rovchining BALANSINI bilib olardi.
--  * `xarajat_yopildi` — pending xarajat posted ga o'tdimi (8.6).
--  * `ext_ref`         — takror himoyasi (`xarajat_saqlash_taqsim` naqshi).
--  * Valyuta ustuni YO'Q: so'rov FAQAT UZS hisobida (.sorov-ui.md §1.6-e).
--    Yarim ishlaydigan valyuta yo'li ochilmaydi.
-- #####################################################################

create table if not exists sorovlar (
  id                uuid primary key default gen_random_uuid(),
  sorovchi_id       uuid        not null,
  kimdan_id         uuid        not null,
  kassa_id          uuid        not null references accounts(id),
  kimdan_kassa_id   uuid        not null references accounts(id),
  summa             numeric     not null check (summa > 0),
  izoh              text        not null,
  status            text        not null default 'pending'
                      check (status in ('pending','qisman','tasdiq','rad')),
  jonatilgan_summa  numeric     check (jonatilgan_summa >= 0),
  xarajat_entry_id  uuid        references entry(id),
  xarajat_summa     numeric,
  xarajat_yopildi   boolean     not null default false,
  jonatma_entry_id  uuid        references entry(id),
  ext_ref           text        unique,
  created_at        timestamptz not null default now(),
  decided_at        timestamptz,
  decided_by        uuid,
  rad_izoh          text,
  -- O'ziga o'zi so'rash — jadval darajasida ham to'silgan (RPC dan tashqari
  -- yo'l bo'lmasa ham: yozuv faqat RPC orqali kiradi, bu ikkinchi qavat).
  constraint sorov_ozidan_emas check (sorovchi_id <> kimdan_id)
);

-- Eski variant RUN qilingan bo'lsa yetishmagan ustunlar qo'shilsin (idempotent)
alter table sorovlar add column if not exists xarajat_summa    numeric;
alter table sorovlar add column if not exists xarajat_yopildi  boolean not null default false;
alter table sorovlar add column if not exists jonatma_entry_id uuid;
alter table sorovlar add column if not exists ext_ref          text;
alter table sorovlar add column if not exists rad_izoh         text;

comment on table sorovlar is
  'Pul sorovlari: hodim oz balansidan kop xarajat yozganda pul soraydi. '
  'Yozuv FAQAT sorov_* RPClari orqali kiradi (yozish policysi ataylab YOQ).';
comment on column sorovlar.kassa_id is
  'Sorovchining kassasi: pending xarajat Kt, pul jonatilganda Dt. Bittasi bolishi SHART.';
comment on column sorovlar.kimdan_kassa_id is
  'Tasdiqlovchining kassasi: pul jonatilganda Kt. Sorov paytida — asosiy (ildiz) kassa; '
  'tasdiqdan keyin — HAQIQATDA tolangan hisob (tur-bolasi bolishi mumkin, sorov_tasdiq 8.1b). '
  'Guard istisnosi (4-BOLIM) aynan shu ustunga tayanadi.';
comment on column sorovlar.xarajat_summa is
  'Audit nusxasi. Hisob-kitob entry_line dan qayta oqiladi. KLIENTGA YUBORILMAYDI '
  '(balans ayirma orqali tiklanardi) — sorov_qator va sorov_qaror_ctx javobida YOQ.';

-- Indekslar (brief talab qilgani + ro'yxat tartibi uchun)
create index if not exists sorovlar_kimdan_status_idx on sorovlar (kimdan_id, status);
create index if not exists sorovlar_sorovchi_idx      on sorovlar (sorovchi_id, created_at desc);
create index if not exists sorovlar_created_idx       on sorovlar (created_at desc);

-- 🔴 `ext_ref` UNIQUE — takror himoyasining IKKINCHI qavati.
--    `create table` dagi `unique` faqat jadval YANGI yaratilganda ishlaydi;
--    eski (ext_ref siz) jadval ustiga `add column if not exists` UNIQUE
--    qo'shmaydi va himoya JIMGINA yo'qolardi (QA topilmasi 2026-08-25).
--    🔴 "Qolganini so'rash" oqimida yangi `entry` UMUMAN yozilmaydi, ya'ni
--    `entry.ext_ref` to'sig'i ishlamaydi — takrorni FAQAT shu indeks to'sadi.
create unique index if not exists sorovlar_ext_ref_uniq
  on sorovlar (ext_ref) where ext_ref is not null;

-- 🔴 BITTA pending xarajatga BITTA ochiq so'rov. Busiz hodim bitta
--    xarajat uchun 5 odamdan pul so'rab, 5 martalik pulni olib qolardi.
create unique index if not exists sorovlar_ochiq_xarajat_uniq
  on sorovlar (xarajat_entry_id)
  where status = 'pending' and xarajat_entry_id is not null;

-- ---------------------------------------------------------------------
-- 2.2  RLS — FAIL-CLOSED
--   O'qish: so'rovchi, so'ralgan odam, admin.
--   Yozish: POLICY UMUMAN YO'Q -> `authenticated` hech qachon yoza olmaydi.
--           Yozuvchi faqat SECURITY DEFINER `sorov_*` RPClari (egasi
--           jadval egasi bo'lgani uchun RLS ni chetlab o'tadi).
--   ⚠️ `force row level security` ATAYLAB QO'YILMAGAN — u egani ham
--      to'sib, RPClarni ishlamas qilardi.
-- ---------------------------------------------------------------------
alter table sorovlar enable row level security;

revoke all on table sorovlar from public, anon;
grant select on table sorovlar to authenticated;

drop policy if exists sorovlar_select_own on sorovlar;
create policy sorovlar_select_own on sorovlar
  for select to authenticated
  using (
    sorovchi_id = (select auth.uid())
    or kimdan_id = (select auth.uid())
    or is_admin()
  );


-- #####################################################################
-- ##  3-BO'LIM — ICHKI YORDAMCHILAR                                  ##
-- ##  Hammasi: security definer + set search_path + GRANT YO'Q.       ##
-- ##  (faqat sorov_* RPClari ichidan chaqiriladi)                     ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 3.1  sorov_page_ok(text) — SAHIFA QOROVULI (fail-closed).
--      `jurnal_page_ok` / `ai_ctx_has_page` naqshining AYNAN nusxasi.
--      🔴 `perm_has_page()` YOLG'IZ ishlatilmaydi: uning tanasida
--      "kalit perm_pages() da yo'q bo'lsa true" (fail-OPEN) shoxi bor.
--      Avval `allowed_pages` ning o'zi (fail-closed), keyin AND.
--      ⚠️ Nusxa ko'chirildi, chaqirilmadi: `jurnal_page_ok` boshqa
--      faylda va u RUN qilinmagan bo'lishi mumkin (42883 bilan yiqilardi).
-- ---------------------------------------------------------------------
create or replace function sorov_page_ok(p_key text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid;
  v_pages text[];
  v_ok    boolean;
begin
  v_uid := auth.uid();
  if v_uid is null then return false; end if;
  if is_admin()     then return true;  end if;

  select allowed_pages into v_pages from user_perms where user_id = v_uid;
  if not found then return false; end if;
  if not (p_key = any(coalesce(v_pages, '{}'::text[]))) then return false; end if;

  if to_regprocedure('public.perm_has_page(text)') is not null then
    execute 'select public.perm_has_page($1)' into v_ok using p_key;
    return coalesce(v_ok, false);
  end if;

  return true;
end $fn$;

revoke all on function sorov_page_ok(text) from public, anon, authenticated;

comment on function sorov_page_ok(text) is
  'ICHKI: sorovlar sahifasi qorovuli (fail-closed). Faqat DEFINER funksiyalar ichidan.';

-- ---------------------------------------------------------------------
-- 3.2  sorov_kassa_bal(uuid) — hisob qoldig'i.
--      🔴 `status='posted' and is_deleted=false` — ya'ni PENDING xarajat
--      bu raqamga KIRMAYDI. `v_hisob_bal` bilan bir xil qoida, lekin
--      view'ga bog'lanmaydi (view security_invoker — definer ichida RLS
--      holati chalkashmasin).
-- ---------------------------------------------------------------------
create or replace function sorov_kassa_bal(p_account uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(sum(l.debit - l.credit), 0)::numeric
    from entry_line l
    join entry e on e.id = l.entry_id
   where l.account_id = p_account
     and e.status = 'posted'
     and e.is_deleted = false;
$fn$;

revoke all on function sorov_kassa_bal(uuid) from public, anon, authenticated;

comment on function sorov_kassa_bal(uuid) is
  'ICHKI: hisob qoldigi (posted + ochirilmagan). PENDING yozuv KIRMAYDI.';

-- ---------------------------------------------------------------------
-- 3.3  sorov_kassa_of(uuid) — odamning ASOSIY UZS kassasi.
--
--      🔴 QOIDA (buzma): tanlash sharti `perm_op_key(a.id) = any(op_kassa_ids)`
--      — `perm_check_accounts` bilan AYNAN BIR XIL predikat. Shu tufayli
--      bu funksiya qaytargan kassada tasdiqlovchi HAR DOIM amaliyot qila
--      oladi (guard uni to'smaydi) — bog'liqlik tasodifiy emas.
--
--      Bir odamda bir nechta kassa bo'lsa — eng KICHIK KODLI (asosiy).
--      ⚠️ MA'LUM CHEKLOV: pul tur-bolasida (Naqd/Click/Payme) tursa
--      ildiz kassa qoldig'i 0 bo'lishi mumkin va tasdiqlash "pul yetmaydi"
--      deydi. Yechim — tasdiqlovchi avval o'z ichida transfer qiladi.
--      Avtomatik "eng puli ko'p bolani tanlash" ATAYLAB QILINMADI: u
--      pulni foydalanuvchi ko'rsatmagan hisobdan olib chiqardi.
-- ---------------------------------------------------------------------
create or replace function sorov_kassa_of(p_uid uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare p user_perms; v_id uuid;
begin
  if p_uid is null then return null; end if;

  select * into p from user_perms where user_id = p_uid;
  -- 🔴 Cheklovsiz (`all`) va adminlarda BIRIKTIRILGAN kassa YO'Q —
  --    ular "kimdan" ro'yxatiga tushmaydi (5-BO'LIM sarlavhasi).
  if not found or p.kassa_scope <> 'list' then return null; end if;

  select a.id into v_id
    from accounts a
   where a.is_active is true
     and a.type = 'aktiv'
     and a.code like '5%'
     and coalesce(a.currency, 'UZS') = 'UZS'
     and a.pul_turi is null
     and a.kassa_turi is distinct from 'xarajat_guruh'
     and perm_op_key(a.id) = any (p.op_kassa_ids)
   order by a.code
   limit 1;

  return v_id;
end $fn$;

revoke all on function sorov_kassa_of(uuid) from public, anon, authenticated;

comment on function sorov_kassa_of(uuid) is
  'ICHKI: odamning asosiy UZS kassasi (eng kichik kod). perm_check_accounts bilan bir xil predikat.';

-- ---------------------------------------------------------------------
-- 3.4  sorov_nomzod_ok(uuid) — bu odamdan so'rasa bo'ladimi.
--      Shartlar (hammasi):
--        * o'zi emas
--        * profiles qatori bor
--        * asosiy UZS kassasi bor (3.3)
--        * 🔴 'sorovlar' SAHIFASI ochiq — javob bera olmaydigan odamdan
--          so'rash mumkin emas (so'rov abadiy osilib qolardi).
-- ---------------------------------------------------------------------
create or replace function sorov_nomzod_ok(p_uid uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_pages text[];
begin
  if p_uid is null or p_uid = auth.uid() then return false; end if;
  if not exists (select 1 from profiles where id = p_uid) then return false; end if;
  if sorov_kassa_of(p_uid) is null then return false; end if;

  select allowed_pages into v_pages from user_perms where user_id = p_uid;
  if not found then return false; end if;
  return 'sorovlar' = any (coalesce(v_pages, '{}'::text[]));
end $fn$;

revoke all on function sorov_nomzod_ok(uuid) from public, anon, authenticated;

comment on function sorov_nomzod_ok(uuid) is
  'ICHKI: bu odamdan pul sorasa boladimi (kassa + sorovlar sahifasi ruxsati).';

-- ---------------------------------------------------------------------
-- 3.5  sorov_ism(uuid, uuid) — ko'rsatish uchun ism.
--      profiles.full_name -> kassa nomi (hodim kassasi = hodim ismi).
--      🔴 EMAIL ga QAYTMAYDI: `full_name_or_email` auth.users dan email
--      o'qiydi va uni boshqa odamga ko'rsatish — keraksiz sizish.
-- ---------------------------------------------------------------------
--      ⚠️ `full_name` `to_jsonb()` orqali o'qiladi: PROVODKA_ISM.sql RUN
--      qilinmagan bazada ustun YO'Q va to'g'ridan murojaat ishlash paytida
--      42703 berardi (naqsh: PROVODKA_HODIM_AMALLAR.sql `created_by`).
create or replace function sorov_ism(p_uid uuid, p_kassa uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v text;
begin
  select nullif(btrim(coalesce(to_jsonb(pr) ->> 'full_name', '')), '') into v
    from profiles pr where pr.id = p_uid;
  if v is not null then return v; end if;

  select nullif(btrim(coalesce(name, '')), '') into v
    from accounts where id = p_kassa;
  return coalesce(v, 'Nomalum');
end $fn$;

revoke all on function sorov_ism(uuid, uuid) from public, anon, authenticated;

comment on function sorov_ism(uuid, uuid) is
  'ICHKI: korsatish uchun ism (profiles.full_name -> kassa nomi). Emailga qaytmaydi.';

-- ---------------------------------------------------------------------
-- 3.6  sorov_qator(sorovlar, uuid) — BITTA qatorning jsonb shakli.
--      🔴 YAGONA joy: `sorov_royxat` ham, `sorov_menikilar` ham shuni
--      chaqiradi — ikki ro'yxat hech qachon bir-biridan ajrab ketmaydi.
--      Shakl: .sorov-ui.md §0.5-b.
--      🔴 `men_qaror_qila_olaman` SERVERDA hisoblanadi (klient taxmin
--      qilmaydi): admin hamma so'rovni KO'RADI, lekin tasdiqlay OLMAYDI.
-- ---------------------------------------------------------------------
create or replace function sorov_qator(s sorovlar, p_uid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_sub text;
begin
  select nullif(btrim(coalesce(subtitle, '')), '') into v_sub
    from accounts where id = s.kassa_id;

  return jsonb_build_object(
    'id',                     s.id,
    'sorovchi_id',            s.sorovchi_id,
    'sorovchi_nom',           sorov_ism(s.sorovchi_id, s.kassa_id),
    'sorovchi_sub',           v_sub,
    'kimdan_id',              s.kimdan_id,
    'kimdan_nom',             sorov_ism(s.kimdan_id, s.kimdan_kassa_id),
    'summa',                  s.summa,
    'izoh',                   s.izoh,
    'status',                 s.status,
    'jonatilgan_summa',       s.jonatilgan_summa,
    'qaror_izoh',             s.rad_izoh,
    'qaror_kim',              case when s.decided_by is null then null
                                   else sorov_ism(s.decided_by, s.kimdan_kassa_id) end,
    'qaror_vaqt',             s.decided_at,
    'sana',                   s.created_at,
    'entry_id',               s.xarajat_entry_id,
    'jonatma_entry_id',       s.jonatma_entry_id,
    -- 🔴 `xarajat_summa` ATAYLAB YUBORILMAYDI (QA topilmasi 2026-08-25).
    --    Klient sukut so'rov summasini `ceil((xarajat - qoldiq)/1000)*1000`
    --    deb hisoblaydi, ya'ni tasdiqlovchi `qoldiq = xarajat_summa - summa`
    --    ni ±1000 aniqlikda HISOBLAB CHIQARARDI — bu so'rovchining balansi.
    --    ".sorov-ui.md": boshqa odamning balansi hech qanday shaklda
    --    ko'rinmaydi. Xarajat summasi UI da hech qayerda chizilmaydi.
    'xarajat_yopildi',        s.xarajat_yopildi,
    'meniki',                 (s.sorovchi_id = p_uid),
    -- 🔴 SERVER hisoblaydi (klient `kimdan_id === my_uid` deb taxmin
    --    QILMASIN): 2026-08-25 dan ADMIN ham qaror qila oladi (8.1),
    --    lekin pul SO'ROV KELGAN ODAMNING kassasidan chiqadi.
    'men_qaror_qila_olaman',  (s.status = 'pending'
                               and (s.kimdan_id = p_uid or is_admin()))
  );
end $fn$;

revoke all on function sorov_qator(sorovlar, uuid) from public, anon, authenticated;

comment on function sorov_qator(sorovlar, uuid) is
  'ICHKI: bitta sorov qatorining jsonb shakli (.sorov-ui.md §0.5-b). Ikkala royxat ham shuni ishlatadi.';


-- #####################################################################
-- ##  4-BO'LIM — perm_guard_entry_line() — ISTISNO (ma'lumot bilan)  ##
-- #####################################################################
-- ## MUAMMO
--   `sorov_tasdiq` pul provodkasini TASDIQLOVCHI nomidan yozadi:
--       Dt so'rovchining kassasi / Kt tasdiqlovchining kassasi
--   Tasdiqlovchida so'rovchining kassasiga amaliyot huquqi YO'Q
--   (`op_kassa_ids` da u yo'q) -> `trg_perm_guard_entry_line` 42501
--   beradi va TASDIQLASH UMUMAN ISHLAMAYDI (faqat admin/`all` scope
--   userlarda ishlardi, ya'ni xususiyat o'lik bo'lardi).
--
-- ## NEGA BAYROQ (GUC) EMAS
--   `set_config('app.sorov_ok', ...)` + guardda tekshirish — eng oson
--   yo'l, lekin u CHETLAB O'TISH YO'LI ochadi: bayroqni qo'ya olgan
--   har qanday sessiya butun kassa ruxsat tizimini o'chirib qo'yadi.
--   Brief aniq talab qiladi: "chetlab o'tish yo'li bo'lmasin".
--
-- ## YECHIM — MA'LUMOT BILAN TASDIQLANGAN ISTISNO
--   Guard `sorovlar` jadvalidan SO'RAYDI:
--     "shu entry aynan SHU foydalanuvchi hal qilgan so'rovning pul
--      provodkasimi, va hisob o'sha so'rovning IKKI kassasidan birimi?"
--   `sorovlar` ga YOZISH POLICYSI YO'Q (2.2) — ya'ni bunday qatorni
--   `sorov_tasdiq` dan boshqa hech kim yarata olmaydi. Soxtalashtirib
--   bo'lmaydi: kalit — ma'lumot, bayroq emas.
--
-- ## NARX — NOL (hot path tegilmagan)
--   Qo'shimcha so'rov FAQAT `perm_check_accounts` RAD ETGANDA ishlaydi,
--   ya'ni avval baribir exception chiqadigan yo'lda. Oddiy yozuvlar
--   (kirim/chiqim/transfer/professional/konvert) uchun bitta ham
--   qo'shimcha so'rov yo'q.
--
-- 🔴 ESKI MANTIQ AYNAN SAQLANGAN: imzo, trigger, xato matni va kodi
--    (42501) o'zgarmadi. Faqat rad etishdan OLDIN bitta istisno.
-- ⚠️ PROVODKA_PERMS.sql KEYIN RUN qilinsa bu istisno YO'QOLADI va
--    tasdiqlash faqat admin/`all` userlarda ishlaydi. 11-BO'LIM shuni
--    tekshiradi — o'shanda 4-BO'LIMni qayta RUN qiling.
-- #####################################################################

create or replace function perm_guard_entry_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_lbl text;
  v_ok  boolean;
begin
  -- 1) ESKI QOIDA — o'zgarmagan
  if perm_check_accounts(array[new.account_id]) then
    return new;
  end if;

  -- 2) SO'ROV ISTISNOSI (faqat shu — rad etish — yo'lida)
  begin
    select exists (
      select 1
        from sorovlar s
       where s.jonatma_entry_id = new.entry_id
         and s.kimdan_id = auth.uid()
         and new.account_id in (s.kassa_id, s.kimdan_kassa_id)
         -- 🔴 VAQT CHEGARASI — istisnoning eng muhim sharti.
         --    `now()` = transaction_timestamp(), `sorov_tasdiq` esa
         --    `decided_at = now()` ni AYNI SHU tranzaksiyada yozadi.
         --    Ya'ni tenglik faqat `sorov_tasdiq` ning o'z tranzaksiyasi
         --    ichida rost bo'ladi, undan keyingi HAR QANDAY tranzaksiyada
         --    yolg'on.
         --    Busiz tasdiqlovchi keyinchalik o'sha `entry_id` ga
         --    to'g'ridan `entry_line` yozib (PostgREST orqali) so'rovchi
         --    kassasidan CHEKLOVSIZ pul ko'chira olardi — pul qorovuli
         --    butunlay chetlab o'tilardi.
         and s.decided_at = now()
         -- 🔴 SUMMA CHEGARASI (ikkinchi qavat): satr aynan jo'natilgan
         --    summaga teng bo'lsin. `sorov_tasdiq` ikkala satrni ham
         --    `p_summa` bilan yozadi (Dt yoki Kt), ya'ni yig'indi har
         --    doim `jonatilgan_summa` ga teng.
         and (coalesce(new.debit, 0) + coalesce(new.credit, 0)) = s.jonatilgan_summa
    ) into v_ok;
  exception when undefined_table or undefined_column then
    -- Jadval yo'q (bu fayl RUN qilinmagan) — eski xatti-harakat
    v_ok := false;
  end;

  if coalesce(v_ok, false) then
    return new;
  end if;

  -- 3) RAD ETISH — matn va kod AYNAN eskisi
  select coalesce(a.code || ' ' || a.name, new.account_id::text)
    into v_lbl from accounts a where a.id = new.account_id;

  raise exception 'Ruxsat yoq: % kassasida amaliyot qilish huquqingiz yoq', v_lbl
    using errcode = '42501';
end $fn$;

revoke all on function perm_guard_entry_line() from public, anon;

drop trigger if exists trg_perm_guard_entry_line on entry_line;
create trigger trg_perm_guard_entry_line
  before insert or update of account_id on entry_line
  for each row execute function perm_guard_entry_line();

comment on function perm_guard_entry_line() is
  'user_perms boyicha pul hisoblarini tosadi. service_role (n8n) va admin otadi. '
  'ISTISNO: sorov_tasdiq yozgan pul provodkasi (sorovlar.jonatma_entry_id bilan tasdiqlanadi).';


-- #####################################################################
-- ##  5-BO'LIM — sorov_kimdan()                                      ##
-- #####################################################################
-- ## KIM RO'YXATGA KIRADI (asos bilan)
--   * `user_perms.kassa_scope = 'list'` VA `op_kassa_ids` da UZS ildiz
--     kassa bor — ya'ni odamning HAQIQATDA pul turadigan kassasi bor.
--   * `allowed_pages` da 'sorovlar' bor — ya'ni javob bera oladi.
--   * O'zi emas.
--
--   🔴 ADMIN VA `kassa_scope='all'` USERLAR RO'YXATDA YO'Q. Sabab:
--   ularga kassa BIRIKTIRILMAGAN (admin_set_provodka_perms admin qatorini
--   o'chiradi), ya'ni "pul qaysi kassadan chiqadi?" savoliga javob yo'q.
--   Pulni taxmin qilingan kassadan chiqarish — eng yomon variant.
--   ✅ YECHIM (Asilbek uchun): bugalter/kassir ro'yxatda ko'rinishi kerak
--   bo'lsa, admin-dev'dan unga `kassa_scope='list'` + o'z kassasi
--   biriktirilsin va 'sorovlar' sahifasi ochilsin. 0.4 so'rovi kim
--   ro'yxatga tushishini oldindan ko'rsatadi.
--
-- 🔴 BALANS/SUMMA UMUMAN YUBORILMAYDI va TARTIB BALANSDAN MUSTAQIL
--    (.sorov-ui.md §0.5-a). Tartibning O'ZI "kimda ko'p pul bor"
--    savoliga javob berardi — yashirin kanal. Tartib:
--      oxirgi_soralgan (yaqin -> uzoq) -> nom (alifbo).
--    `oxirgi_soralgan` — XATTI-HARAKAT ma'lumoti (so'nggi 30 kunda shu
--    hodim kimdan so'ragan), moliyaviy emas.
--
-- ⚠️ SAHIFA QOROVULI YO'Q — bu RPC `hodim-dev.html` dan chaqiriladi,
--    u sahifa hech qachon cheklanmaydi (CLAUDE.md). Qorovul — auth.
-- #####################################################################

create or replace function sorov_kimdan()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by
                              x.oxirgi_soralgan desc nulls last, x.nom), '[]'::jsonb)
    into v_out
  from (
    select up.user_id,
           k.id                                        as kassa_id,
           sorov_ism(up.user_id, k.id)                 as nom,
           nullif(btrim(coalesce(k.subtitle, '')), '') as subtitle,
           (select max(s.created_at)::date
              from sorovlar s
             where s.sorovchi_id = v_uid
               and s.kimdan_id  = up.user_id
               and s.created_at >= now() - interval '30 days') as oxirgi_soralgan
      from user_perms up
      join profiles pr on pr.id = up.user_id
      -- `sorov_kassa_of` odamning ASOSIY UZS kassasini beradi (3.3).
      -- `join accounts` shu id bo'yicha — nom/subtitle o'shandan.
      join accounts k on k.id = sorov_kassa_of(up.user_id)
     where up.user_id <> v_uid
       and up.kassa_scope = 'list'
       and 'sorovlar' = any (coalesce(up.allowed_pages, '{}'::text[]))
  ) x;

  return v_out;
end $fn$;

revoke all on function sorov_kimdan() from public, anon;
grant execute on function sorov_kimdan() to authenticated;

comment on function sorov_kimdan() is
  'Kimdan pul sorash mumkin. 🔴 BALANS/SUMMA MAYDONI YOQ va tartib balansdan MUSTAQIL '
  '(oxirgi_soralgan -> nom). Nomzod: kassa_scope=list + UZS ildiz kassa + sorovlar sahifasi.';


-- #####################################################################
-- ##  6-BO'LIM — sorov_yarat()  🔴 ATOMIK                            ##
-- #####################################################################
-- ## NEGA BITTA RPC (muzokara qilinmaydi)
--   Xarajat va so'rov IKKI qadamda yozilsa "xarajat tushdi, so'rov
--   tushmadi" holati paydo bo'ladi va uni UI dan tuzatib BO'LMAYDI —
--   bugungi prod hodisasi (yetim sarlavha) aynan shundan chiqqan.
--   Funksiya tanasi bitta tranzaksiya: xato bo'lsa HAMMASI qaytadi.
--
-- ## IKKI OQIM (bitta RPC)
--
--   (b) YANGI XARAJAT — hodim formadan yozadi. Klient yuboradi:
--       p_kassa, p_modda, p_summa_xarajat, p_izoh_xarajat, p_kimdan,
--       p_sorov_summa, p_sorov_izoh, p_ext_ref (+ metadata).
--
--   (a) "QOLGANINI SO'RASH" — `p_xarajat_entry` beriladi. Klient FAQAT
--       4 kalit yuboradi: p_xarajat_entry, p_kimdan, p_sorov_summa,
--       p_sorov_izoh (+ p_ext_ref). Yangi xarajat YOZILMAYDI; kassa va
--       so'rov chegarasi YOZUVNING O'ZIDAN olinadi.
--       🔴 NEGA SERVERDAN: klient xarajat summasini BILMAYDI — u
--       `sorov_qator` javobidan ataylab olib tashlangan (tasdiqlovchi
--       `qoldiq = xarajat - so'ralgan` ni hisoblab, so'rovchining
--       balansini bilib olardi). Bundan tashqari klient yuborgan
--       summa/kassa soxta bo'lishi mumkin — yozuvning o'zi yagona
--       haqiqat manbai. p_kassa yuborilsa yozuvnikiga MOS bo'lishi shart.
--
-- ## PARAMETRLAR (hammasi `default null` — sabab imzo ustidagi izohda)
--   p_kassa          — so'rovchining kassasi (xarajat Kt). UZS bo'lishi SHART.
--                      (a) oqimida IXTIYORIY, berilsa mos kelishi shart.
--   p_modda          — xarajat moddasi (Dt), type='xarajat'. Faqat (b).
--   p_summa_xarajat  — xarajat summasi (so'm). Faqat (b).
--   p_izoh_xarajat   — xarajat izohi (entry.description). Faqat (b).
--   p_kimdan         — kimdan so'raladi (user_id, `sorov_kimdan` dan).
--   p_sorov_summa    — qancha so'raladi.
--   p_sorov_izoh     — nega kerak (MAJBURIY, >= 3 belgi).
--   p_ext_ref        — takror himoyasi tokeni (ixtiyoriy, 8..120 belgi).
--                      🔴 (a) oqimida YANGI `entry` yozilmaydi, ya'ni
--                      `entry.ext_ref` to'sig'i ishlamaydi — takrorni
--                      `sorovlar_ext_ref_uniq` indeksi to'sadi (2-BO'LIM).
--   p_entry_date     — sana (null -> bugun, Toshkent). Faqat (b).
--   p_filial_ids     — xarajat metadata (ixtiyoriy). Faqat (b).
--   p_davr_start/end — davr metadata (ixtiyoriy). Faqat (b).
--   p_kommunal_turi  — kommunal turi (ixtiyoriy). Faqat (b).
--   p_xarajat_entry  — 🔴 MAVJUD pending xarajatga ULANISH (8.6). Egalik
--                      (`created_by`) fail-closed tekshiriladi.
--
-- ## QAYTISH
--   {ok:true, sorov_id, entry_id, status:'pending', xarajat_yangi:bool}
--   `xarajat_yangi=false` -> (a) oqimi: mavjud pending yozuvga ulandi.
--
-- ⚠️ VALYUTA: faqat UZS. So'rov modali valyuta kassasida umuman
--    chiqmaydi (.sorov-ui.md §1.6-e) — server ham shuni majburlaydi,
--    yarim ishlaydigan yo'l ochilmasin.
-- #####################################################################

-- 🔴 HAMMA PARAMETRDA `default null` — sabab 6.4 da. Qisqasi: "qolganini
--    so'rash" oqimida klient xarajat kassasi/summasini BILMAYDI (u
--    `sorov_qator` javobidan ATAYLAB olib tashlangan — balans sizishi),
--    shuning uchun atigi 4 kalit yuboradi va qolganini server O'ZI oladi.
--    ⚠️ IMZO O'ZGARMAGAN: argument turlari ro'yxati AYNAN o'sha 14 ta,
--    faqat sukut qiymatlar qo'shildi (`create or replace` buni qabul
--    qiladi — funksiya identifikatori turlar ro'yxati).
--    ⚠️ Postgres qoidasi: sukutli parametrdan KEYINGI hamma parametr ham
--    sukutli bo'lishi shart — shuning uchun hammasi.
create or replace function sorov_yarat(
  p_kassa          uuid    default null,
  p_modda          uuid    default null,
  p_summa_xarajat  numeric default null,
  p_izoh_xarajat   text    default null,
  p_kimdan         uuid    default null,
  p_sorov_summa    numeric default null,
  p_sorov_izoh     text    default null,
  p_ext_ref        text    default null,
  p_entry_date     date    default null,
  p_filial_ids     uuid[]  default null,
  p_davr_start     date    default null,
  p_davr_end       date    default null,
  p_kommunal_turi  text    default null,
  p_xarajat_entry  uuid    default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_ext    text := nullif(btrim(p_ext_ref), '');
  v_izoh   text := nullif(btrim(p_sorov_izoh), '');
  v_xizoh  text := nullif(btrim(p_izoh_xarajat), '');
  v_kassa  accounts;
  v_modda  accounts;
  v_gk     uuid;
  v_entry  uuid;
  v_sorov  uuid;
  v_yangi  boolean := true;
  v_chegara numeric;
  v_est    text;
  v_edel   boolean;
  v_ega    text;      -- xarajat yozuvining egasi (created_by, tur-mustaqil)
  v_kid    uuid;      -- xarajat qaysi kassadan chiqadi (yozuvdan yoki p_kassa)
  v_xar    numeric;   -- xarajat summasi (yozuvdan yoki p_summa_xarajat)
begin
  -- "Saqlanmoqda…" abadiy aylanmasin (xarajat_saqlash_taqsim naqshi)
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  -- ---- 6.1 So'rov summasi -------------------------------------------
  if p_sorov_summa is null or p_sorov_summa <= 0
     or p_sorov_summa <> round(p_sorov_summa, 2) then
    raise exception 'Sorov summasi musbat bolishi kerak' using errcode = '22000';
  end if;

  -- ---- 6.2 Izoh — MAJBURIY (.sorov-ui.md §1.4) ----------------------
  if v_izoh is null or length(v_izoh) < 3 then
    raise exception 'Sorov izohi majburiy (kamida 3 belgi)' using errcode = '22000';
  end if;
  if length(v_izoh) > 200 then
    raise exception 'Sorov izohi 200 belgidan oshmasin' using errcode = '22000';
  end if;

  -- ---- 6.3 Token shakli (xarajat_saqlash_taqsim bilan bir xil) ------
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bolishi kerak' using errcode = '22000';
  end if;

  -- ---- 6.4 XARAJAT MANBASI: mavjud pending yozuv YOKI yangi ---------
  --
  -- 🔴 IKKI OQIM, BITTA RPC:
  --   (a) `p_xarajat_entry` BERILGAN — "qolganini so'rash". Yangi xarajat
  --       YOZILMAYDI, so'rov MAVJUD pending yozuvga ulanadi.
  --       ⚠️ Kassa VA chegara YOZUVDAN olinadi, klientdan EMAS. Sabab
  --       ikkita va ikkalasi ham majburiy:
  --         1) Klient xarajat summasini BILMAYDI — u javobdan ataylab
  --            olib tashlangan (balans ayirma orqali tiklanardi);
  --         2) Klient yuborgan summa/kassa SOXTA bo'lishi mumkin edi —
  --            yozuvning o'zi yagona haqiqat manbai.
  --   (b) `p_xarajat_entry` NULL — odatiy oqim: yangi pending xarajat.
  if p_xarajat_entry is not null then
    select e.status, e.is_deleted, to_jsonb(e) ->> 'created_by'
      into v_est, v_edel, v_ega
      from entry e where e.id = p_xarajat_entry for update;
    if not found then
      raise exception 'Xarajat yozuvi topilmadi' using errcode = '22000';
    end if;
    if v_edel is true then
      raise exception 'Xarajat yozuvi ochirilgan' using errcode = '22000';
    end if;
    if v_est <> 'pending' then
      raise exception 'Bu xarajat allaqachon kuchda — sorov kerak emas' using errcode = '22000';
    end if;
    -- 🔴 EGALIK — FAIL-CLOSED (sorov_xarajat_bekor dagi qoida bilan bir xil).
    --    `created_by` `to_jsonb()` orqali: ustun turi repoda ANIQLANMAGAN.
    --    Busiz har qanday user begona pending xarajatga o'z so'rovini
    --    ulab, unga BOSHQA odamning pulini tortib olardi.
    if not is_admin() and (v_ega is null or v_ega <> v_uid::text) then
      raise exception 'Bu xarajat sizniki emas' using errcode = '42501';
    end if;

    -- Kassa satri (eng katta Kt pul satri) — kassa va summa manbai
    select l.account_id, l.credit into v_kid, v_xar
      from entry_line l
      join accounts a on a.id = l.account_id
     where l.entry_id = p_xarajat_entry and l.credit > 0
       and a.type = 'aktiv' and a.code like '5%'
     order by l.credit desc
     limit 1;
    if v_kid is null or coalesce(v_xar, 0) <= 0 then
      raise exception 'Xarajat yozuvining kassa satri topilmadi' using errcode = '22000';
    end if;
    -- Klient kassa yuborsa — mos kelishi shart (jimgina boshqasiga yozilmasin)
    if p_kassa is not null and p_kassa <> v_kid then
      raise exception 'Kassa xarajat yozuviga mos emas' using errcode = '22000';
    end if;
    -- Ochiq so'rov bo'lsa — ANIQ matn (aks holda 23505 handleri
    -- "allaqachon saqlangan" deb chalg'ituvchi javob berardi).
    if exists (select 1 from sorovlar s
                where s.xarajat_entry_id = p_xarajat_entry and s.status = 'pending') then
      raise exception 'Bu xarajat uchun ochiq sorov allaqachon bor' using errcode = '22000';
    end if;
    v_entry := p_xarajat_entry;
    v_yangi := false;
  else
    if p_summa_xarajat is null or p_summa_xarajat <= 0
       or p_summa_xarajat <> round(p_summa_xarajat, 2) then
      raise exception 'Xarajat summasi musbat bolishi kerak' using errcode = '22000';
    end if;
    if p_kassa is null then
      raise exception 'Kassa tanlanmagan' using errcode = '22000';
    end if;
    v_kid := p_kassa;
    v_xar := p_summa_xarajat;

    -- Modda faqat YANGI yozuvda kerak
    select * into v_modda from accounts where id = p_modda;
    if not found or v_modda.is_active is distinct from true then
      raise exception 'Xarajat moddasi topilmadi' using errcode = '22000';
    end if;
    if v_modda.type <> 'xarajat' then
      raise exception 'Tanlangan hisob xarajat moddasi emas' using errcode = '22000';
    end if;
  end if;

  -- ---- 6.5 Kassa tekshiruvi (IKKALA oqim uchun BITTA joyda) ---------
  select * into v_kassa from accounts where id = v_kid;
  if not found or v_kassa.is_active is distinct from true then
    raise exception 'Kassa topilmadi yoki faol emas' using errcode = '22000';
  end if;
  if v_kassa.type <> 'aktiv' or v_kassa.code not like '5%'
     or v_kassa.kassa_turi is not distinct from 'xarajat_guruh' then
    raise exception 'Bu hisob kassa emas' using errcode = '22000';
  end if;
  if coalesce(v_kassa.currency, 'UZS') <> 'UZS' then
    raise exception 'Pul sorash faqat som kassasida ishlaydi' using errcode = '22000';
  end if;
  -- 🔴 O'z kassasi ekanini SERVER tekshiradi (trigger baribir tekshiradi,
  --    bu esa ANIQ xato matni beradi va yarim ish qilinmaydi).
  if not perm_check_accounts(array[v_kid]) then
    raise exception 'Ruxsat yoq: bu kassada amaliyot qilish huquqingiz yoq'
      using errcode = '42501';
  end if;

  -- ---- 6.6 So'rov summasining YUQORI CHEGARASI ----------------------
  -- 🔴 Chegara XARAJAT summasidan (balansdan EMAS), 1000 ga yuqoriga
  --    yaxlitlangan — klient aynan shunday yaxlitlaydi (.sorov-ui.md §1.3),
  --    aks holda 500 500 lik xarajatda to'g'ri 501 000 lik so'rov rad
  --    etilardi. "Qolganini so'rash" oqimida chegara YOZUVDAN keladi.
  v_chegara := ceil(v_xar / 1000.0) * 1000;
  if p_sorov_summa > v_chegara then
    raise exception 'Sorov summasi xarajatdan katta bola olmaydi' using errcode = '22000';
  end if;

  -- ---- 6.7 Kimdan ---------------------------------------------------
  if p_kimdan is null then
    raise exception 'Kimdan sorash tanlanmagan' using errcode = '22000';
  end if;
  if p_kimdan = v_uid then
    raise exception 'Ozingizdan pul sorab bolmaydi' using errcode = '22000';
  end if;
  if not sorov_nomzod_ok(p_kimdan) then
    raise exception 'Bu odamdan sorab bolmaydi (kassasi yoki sorovlar ruxsati yoq)'
      using errcode = '22000';
  end if;
  v_gk := sorov_kassa_of(p_kimdan);
  if v_gk is null then
    raise exception 'Bu odamning kassasi aniqlanmadi' using errcode = '22000';
  end if;

  -- ---- 6.7b YANGI pending xarajat (faqat (b) oqimida) ---------------
  if v_yangi then
    insert into entry (entry_date, description, source, status,
                       filial_ids, davr_start, davr_end, kommunal_turi,
                       ext_ref, created_by)
    values (
      coalesce(p_entry_date, (now() at time zone 'Asia/Tashkent')::date),
      v_xizoh,
      'manual',                       -- 🔴 jurnal tasnifi o'zgarmasin
      'pending',                      -- 🔴 BALANSGA TA'SIR QILMAYDI
      coalesce(p_filial_ids, '{}'::uuid[]),
      p_davr_start, p_davr_end,
      nullif(btrim(coalesce(p_kommunal_turi, '')), ''),
      v_ext,
      -- 🔴 `created_by` ANIQ yoziladi (trigger/default'ga tayanilmaydi):
      --    `sorov_xarajat_bekor` va 6.4 dagi egalik tekshiruvi shu ustunga
      --    tayanadi. Bo'sh bo'lsa ikkalasi ham fail-closed rad etib, hodim
      --    o'z pending xarajatini bekor ham, davom ham ettira olmasdi.
      --    ⚠️ `entry_ijrochi_set` trigger'i `new.created_by is null`
      --    shartida ishlaydi — bu yerda null emas, ya'ni u TEGMAYDI.
      v_uid)
    returning id into v_entry;

    -- Dt xarajat modda / Kt kassa. Dt = Kt (check_entry_balanced rozi).
    insert into entry_line (entry_id, account_id, debit, credit)
    values (v_entry, p_modda, v_xar, 0),
           (v_entry, v_kid,   0,     v_xar);
  end if;

  -- ---- 6.8 So'rov qatori --------------------------------------------
  insert into sorovlar (sorovchi_id, kimdan_id, kassa_id, kimdan_kassa_id,
                        summa, izoh, status, xarajat_entry_id, xarajat_summa,
                        ext_ref)
  values (v_uid, p_kimdan, v_kid, v_gk,
          p_sorov_summa, v_izoh, 'pending', v_entry, v_xar,
          case when v_ext is null then null else v_ext || ':sorov' end)
  returning id into v_sorov;

  return jsonb_build_object('ok', true,
                            'sorov_id',      v_sorov,
                            'entry_id',      v_entry,
                            'status',        'pending',
                            'xarajat_yangi', v_yangi);

exception
  -- 🔴 TAKROR. Kod 23505 O'ZGARMAYDI — klient aynan shu kod bo'yicha
  --    "allaqachon saqlangan" deb qaror qiladi (xarajat_saqlash_taqsim
  --    bilan AYNAN bir xil kod).
  when unique_violation then
    if v_ext is null then
      -- Token yuborilmagan: bizning to'siq emas. Ochiq so'rov indeksi
      -- (sorovlar_ochiq_xarajat_uniq) bo'lsa — tushunarli matn.
      if p_xarajat_entry is not null then
        raise exception 'Bu xarajat uchun ochiq sorov allaqachon bor'
          using errcode = '23505';
      end if;
      raise;
    end if;
    -- 🔴 (a) "qolganini so'rash" oqimida YANGI xarajat yozilmagan, ya'ni
    --    yagona mumkin bo'lgan takror — `sorovlar_ext_ref_uniq`, ya'ni
    --    SO'ROV allaqachon yozilgan. Matn shuni aniq aytadi: klient
    --    "xarajat saqlandi" degan yolg'on xabarni ko'rsatmasin.
    if p_xarajat_entry is not null then
      raise exception 'Bu sorov allaqachon yuborilgan (takroriy yuborish tosildi)'
        using errcode = '23505';
    end if;
    raise exception 'Bu xarajat allaqachon saqlangan (takroriy yuborish tosildi)'
      using errcode = '23505';
end $fn$;

revoke all on function sorov_yarat(uuid, uuid, numeric, text, uuid, numeric, text,
                                   text, date, uuid[], date, date, text, uuid)
  from public, anon;
grant execute on function sorov_yarat(uuid, uuid, numeric, text, uuid, numeric, text,
                                      text, date, uuid[], date, date, text, uuid)
  to authenticated;

comment on function sorov_yarat(uuid, uuid, numeric, text, uuid, numeric, text,
                                text, date, uuid[], date, date, text, uuid) is
  'ATOMIK: pending xarajat (entry + 2 entry_line) + sorovlar qatori bitta tranzaksiyada. '
  'ext_ref berilsa takror yuborish 23505 bilan tosiladi. p_xarajat_entry berilsa mavjud '
  'pending xarajatga ulanadi (qisman qoplangan xarajat uchun ikkinchi sorov).';


-- #####################################################################
-- ##  7-BO'LIM — sorov_royxat() · sorov_menikilar() · qaror_ctx()    ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 7.1  sorov_royxat(p_holat, p_hammasi) — SO'ROVLAR SAHIFASI.
--
--   Qamrov: menga kelganlar (`kimdan_id`) + men yuborganlar (`sorovchi_id`).
--   `p_hammasi=true` VA admin bo'lsa — HAMMASI (brief: admin hammasini
--   ko'radi). Admin bo'lmasa bayroq JIMGINA e'tiborsiz qoldirilmaydi:
--   qamrov o'zgarmaydi (fail-closed), xato ham berilmaydi — UI da
--   almashtirgich faqat adminda ko'rinadi.
--
--   `p_holat`: null|'all' — hammasi · 'pending' · 'qisman' · 'tasdiq'
--              · 'rad' · 'done' (= qisman + tasdiq).
--
--   🔴 SAHIFA QOROVULI: `sorov_page_ok('sorovlar')`. Kassa ruxsati
--   YETARLI EMAS — `kassa_scope` sukuti 'all', ya'ni cheklovsiz userda
--   kassa filtri umuman yo'q edi (jurnal_v2 saboqi).
-- ---------------------------------------------------------------------
create or replace function sorov_royxat(p_holat text default null,
                                        p_hammasi boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_all   boolean;
  v_h     text := nullif(btrim(coalesce(p_holat, '')), '');
  v_out   jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('sorovlar') then
    raise exception 'Sorovlar sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  v_all := coalesce(p_hammasi, false) and is_admin();

  if v_h is not null and v_h not in ('all','pending','qisman','tasdiq','rad','done') then
    raise exception 'Notanish holat: %', v_h using errcode = '22000';
  end if;

  -- 🔴 `sorov_qator(s, ...)` SHU YERDA chaqiriladi (ichki so'rovda), chunki
  --    `s` — HAQIQIY jadval aliasi. Tashqi `select ... from (select s.*) q`
  --    da qator turi anonim `record` bo'lib qolardi va funksiya topilmasdi.
  select coalesce(jsonb_agg(q.j order by q.sana desc), '[]'::jsonb)
    into v_out
    from (
      select sorov_qator(s, v_uid) as j, s.created_at as sana
        from sorovlar s
       where (v_all or s.kimdan_id = v_uid or s.sorovchi_id = v_uid)
         and (v_h is null or v_h = 'all'
              or (v_h = 'done' and s.status in ('qisman','tasdiq'))
              or (v_h not in ('all','done') and s.status = v_h))
       order by s.created_at desc
       limit 300
    ) q;

  return v_out;
end $fn$;

revoke all on function sorov_royxat(text, boolean) from public, anon;
grant execute on function sorov_royxat(text, boolean) to authenticated;

comment on function sorov_royxat(text, boolean) is
  'Sorovlar sahifasi: menga kelganlar + men yuborganlar (admin + p_hammasi -> hammasi). '
  'Sahifa qorovuli: sorov_page_ok(sorovlar). Eng yangi 300 ta.';

-- ---------------------------------------------------------------------
-- 7.2  sorov_menikilar(p_limit) — HODIM SAHIFASI uchun.
--
--   🔴 NEGA ALOHIDA RPC: `hodim-dev.html` hech qachon cheklanmaydi, lekin
--   hodimda 'sorovlar' SAHIFASI bo'lmasligi mumkin. Tarixda "Tasdiq
--   kutilmoqda" nishonini (.sorov-ui.md §1.8) ko'rsatish uchun unga
--   O'Z so'rovlari kerak — sahifa qorovulisiz. Qamrov: FAQAT
--   `sorovchi_id = auth.uid()`, ya'ni sizadigan narsa yo'q.
-- ---------------------------------------------------------------------
create or replace function sorov_menikilar(p_limit int default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_n   int  := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  -- Yuqoridagi bilan bir xil naqsh (jadval aliasi ichki so'rovda)
  select coalesce(jsonb_agg(q.j order by q.sana desc), '[]'::jsonb)
    into v_out
    from (
      select sorov_qator(s, v_uid) as j, s.created_at as sana
        from sorovlar s
       where s.sorovchi_id = v_uid
       order by s.created_at desc
       limit v_n
    ) q;

  return v_out;
end $fn$;

revoke all on function sorov_menikilar(int) from public, anon;
grant execute on function sorov_menikilar(int) to authenticated;

comment on function sorov_menikilar(int) is
  'Hodimning OZ sorovlari (sahifa qorovulisiz — hodim.html cheklanmaydi). Faqat sorovchi_id = auth.uid().';

-- ---------------------------------------------------------------------
-- 7.3  sorov_qaror_ctx(p_id) — tasdiqlash modali konteksti.
--      {soralgan, mening_qoldigim, valyuta, kassa_nom, hisoblar[],
--       ozim, kimdan_nom}
--
--   🔴 `mening_qoldigim` va `hisoblar[].qoldiq` — TASDIQLOVCHINING O'Z
--   puli. Funksiya faqat `kimdan_id = auth.uid()` YOKI adminga javob
--   beradi; SO'ROVCHIGA hech qachon bermaydi (.sorov-ui.md §2.7).
--
--   🔴 `hisoblar[]` = {account_id, code, name, qoldiq} — ildiz kassa VA
--   uning UZS bolalari (Naqd/Click/Payme). NEGA KERAK: pul tur-bolasida
--   tursa ildiz kassa qoldig'i 0 bo'ladi va tasdiqlash "pul yetmaydi"
--   deb rad etardi (jonli sinovda aynan shu chiqdi). Endi tanlovni
--   TASDIQLOVCHINING O'ZI qiladi — server "eng puli ko'p bolani" o'zi
--   tanlab, foydalanuvchi ko'rsatmagan hisobdan pul olib chiqmaydi.
-- ---------------------------------------------------------------------
create or replace function sorov_qaror_ctx(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid  uuid := auth.uid();
  s      sorovlar;
  v_nom  text;
  v_root uuid;
  v_his  jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('sorovlar') then
    raise exception 'Sorovlar sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  select * into s from sorovlar where id = p_id;
  if not found then
    raise exception 'Sorov topilmadi' using errcode = '22000';
  end if;
  -- 🔴 So'ralgan odam YOKI admin (Asilbek qarori 2026-08-25 — 8.1 ga qara).
  if s.kimdan_id <> v_uid and not is_admin() then
    raise exception 'Bu sorov sizga kelmagan' using errcode = '42501';
  end if;

  -- 🔴 ILDIZ har doim `kimdan_kassa_id` — ADMIN uchun ham. Ya'ni admin
  --    o'z hisoblarini emas, SO'ROV KELGAN ODAMNING hisoblarini ko'radi:
  --    pul o'shaning kassasidan chiqadi (adminda kassa biriktirilmagan).
  --    ⚠️ Bu "boshqa odamning balansi ko'rinmasin" qoidasidan ONGLI
  --    ISTISNO: admin o'sha odam nomidan qaror qilyapti, qarorni raqamsiz
  --    qabul qilib bo'lmaydi. Oddiy foydalanuvchida bunday yo'l YO'Q.
  v_root := s.kimdan_kassa_id;
  select name into v_nom from accounts where id = v_root;

  -- Hisoblar: ildiz kassa VA uning bevosita bolalari (Naqd/Click/Payme).
  -- 🔴 FAQAT UZS. Valyuta bolasidan (56xx USD, 57xx CNY...) to'lash kurs
  --    konvertatsiyasini talab qiladi — so'rov so'mda, hisob dollarda.
  --    Yarim ishlaydigan yo'l ochilmaydi: konvert alohida mexanizm
  --    (`convert_start_v2`) va u o'z koridori/tasdig'i bilan keladi.
  -- 🔴 `perm_check_accounts` — 8.4 dagi VALIDATSIYA bilan AYNAN bir xil
  --    predikat: ro'yxatda ko'ringan hisob har doim to'lovga yaroqli
  --    (admin/all-scope -> hammasi, list-scope -> op_kassa_ids).
  select coalesce(jsonb_agg(to_jsonb(x) order by x.code), '[]'::jsonb)
    into v_his
    from (
      select a.id as account_id, a.code, a.name,
             sorov_kassa_bal(a.id) as qoldiq
        from accounts a
       where (a.id = v_root or a.parent_id = v_root)
         and a.is_active is true
         and a.type = 'aktiv' and a.code like '5%'
         and coalesce(a.currency, 'UZS') = 'UZS'
         and a.kassa_turi is distinct from 'xarajat_guruh'
         and perm_check_accounts(array[a.id])
    ) x;

  return jsonb_build_object(
    'soralgan',        s.summa,
    -- Ildiz kassa qoldig'i (eski kalit — klient tanlovdan keyin uni
    -- TANLANGAN hisobniki bilan almashtiradi).
    'mening_qoldigim', sorov_kassa_bal(v_root),
    'valyuta',         'UZS',
    -- 🔴 `xarajat_summa` YO'Q — balans ayirma orqali tiklanardi.
    --    Tasdiqlovchiga kerak emas: u SO'RALGAN summani ko'radi.
    'kassa_nom',       v_nom,
    'hisoblar',        v_his,
    -- `ozim=false` -> admin boshqa odam nomidan qaror qilyapti; klient
    -- yorliqni almashtiradi ("Qo'lingizdagi pul" -> "<Nom> qo'lidagi pul").
    'ozim',            (s.kimdan_id = v_uid),
    'kimdan_nom',      sorov_ism(s.kimdan_id, v_root));
end $fn$;

revoke all on function sorov_qaror_ctx(uuid) from public, anon;
grant execute on function sorov_qaror_ctx(uuid) to authenticated;

comment on function sorov_qaror_ctx(uuid) is
  'Tasdiqlash modali konteksti + tolov hisoblari royxati (ildiz kassa va UZS bolalari, qoldiq bilan). '
  'Faqat sorov kelgan odam yoki ADMIN. Admin holatida royxat sorov kelgan odamnikidir.';


-- #####################################################################
-- ##  8-BO'LIM — sorov_tasdiq()  🔴 IDEMPOTENT                       ##
-- #####################################################################
-- ## 8.1  KIM TASDIQLAYDI
--   🔴 `kimdan_id = auth.uid()` YOKI **ADMIN** (Asilbek qarori 2026-08-25).
--   Avvalgi sukut "admin ham emas" edi; jonli sinovdan keyin o'zgardi.
--   ⚠️ ADMIN TASDIQLAGANDA PUL SO'ROV KELGAN ODAMNING KASSASIDAN CHIQADI
--   (adminda kassa biriktirilmagan — 5-BO'LIM). Ya'ni admin BOSHQA ODAM
--   NOMIDAN qaror qiladi va uning qoldig'ini ko'radi (7.3). Bu ONGLI
--   qaror: adminsiz navbat qotib qolardi (odam ta'tilda/kasal).
--   Qattiqlashtirish kerak bo'lsa — `and not is_admin()` ni ikkala
--   joydan (8.1 va 9.1) olib tashlang, boshqa hech qayerga tegilmaydi.
--
-- ## 8.1b  QAYSI HISOBDAN TO'LANADI — `p_kassa`
--   Pul Naqd/Click/Payme tur-bolasida turishi mumkin; ildiz kassa qoldig'i
--   0 bo'lsa eski kod "pul yetmaydi" deb rad etardi (jonli sinov). Endi
--   tasdiqlovchi hisobni O'ZI tanlaydi (`sorov_qaror_ctx.hisoblar`).
--   `p_kassa is null` -> eski xatti-harakat (`kimdan_kassa_id`).
--   Tekshiruv (uch qavat): (1) hisob ILDIZning o'zi yoki BEVOSITA bolasi;
--   (2) `perm_check_accounts` (admin/all -> ok, list -> op_kassa_ids);
--   (3) qoldig'i yetadi.
--   🔴 GUARD ISTISNOSI UCHUN: `entry_line` dan OLDIN `sorovlar.kimdan_kassa_id`
--   HAQIQATDA ishlatilgan hisobga yangilanadi — 4-BO'LIM dagi istisno
--   `new.account_id in (s.kassa_id, s.kimdan_kassa_id)` ga tayanadi va
--   shu tufayli O'ZGARISHSIZ ishlaydi.
--
-- ## 8.2  IDEMPOTENTLIK — UCH QAVAT
--   (1) `select ... for update` — qator qulflanadi, ikkinchi tranzaksiya
--       kutadi va statusni YANGILANGAN holda ko'radi;
--   (2) `status <> 'pending'` -> pul HARAKAT QILMAYDI, javob
--       {ok:false, kod:'already_decided'} (XATO EMAS — UI modalni jimgina
--       yopadi, .sorov-ui.md §2.7);
--   (3) pul provodkasining `ext_ref` = 'sorov:<id>:jonatma' va u
--       `entry.ext_ref` UNIQUE indeksi bilan qo'riqlanadi — (1) va (2)
--       qandaydir tarzda chetlab o'tilsa ham IKKINCHI provodka bazaga
--       KIRMAYDI (23505).
--
-- ## 8.3  QISMAN
--   `p_summa < summa` -> status 'qisman' va SO'ROV YOPILADI (ochiq
--   qolmaydi). Asos (.sorov-ui.md §2.5): ochiq qolsa bitta so'rov ikki
--   holatda bo'lardi ('qisman' VA 'pending'), tasdiqlovchi navbatida
--   o'zi hal qilgan karta qayta paydo bo'lardi, va so'rovchi qolgan
--   qismni BOSHQA odamdan sorashi to'silardi. Qolgan qism uchun YANGI
--   so'rov yuboriladi — pending xarajatga ulanib (`p_xarajat_entry`).
--
-- ## 8.4  PULI YETMASA
--   `sorov_kassa_bal(kimdan_kassa) < p_summa` -> ANIQ xato, tasdiqlovchi
--   kassasi HECH QACHON manfiyga tushmaydi.
--
-- ## 8.5  XARAJAT O'CHIRILGAN / TAHRIRLANGAN BO'LSA
--   * o'chirilgan yoki yo'q -> PUL JO'NATILMAYDI. So'rov 'rad' bo'lib
--     avtomat yopiladi ({ok:false, kod:'xarajat_yoq'}) — sababi yo'qolgan
--     so'rov navbatda osilib qolmasin.
--   * tahrirlangan -> summa `entry_line` dan QAYTA o'qiladi
--     (`xarajat_summa` nusxasiga ishonilmaydi).
--   * allaqachon 'posted' (admin qo'lda o'tkazgan) -> pul baribir
--     jo'natiladi (hodim pulni sarflagan), status flip kerak emas.
--
-- ## 8.6  PENDING XARAJAT QACHON YOPILADI
--   Pul tushgandan KEYINGI qoldiq xarajatni qoplasa:
--       sorov_kassa_bal(kassa) >= xarajat_summa   -> pending -> posted
--   Aks holda xarajat PENDING QOLADI va javobda `qoldiq_yetmadi:true`.
--   Asos: 500k xarajatga 300k berilsa "posted" qilish kassani MANFIYGA
--   tushirardi — bu tizim yo'q qilmoqchi bo'lgan holatning o'zi.
--   Hodim yetmagan qismini yana so'raydi (`p_xarajat_entry` bilan) yoki
--   `sorov_xarajat_bekor` bilan xarajatni bekor qiladi (9.2).
-- #####################################################################

-- 🔴 IMZO O'ZGARDI (p_kassa qo'shildi) -> `drop` BEVOSITA `create` ustida.
--    `create or replace` yolg'iz 42P13 beradi ("cannot change name of input
--    parameter" / argument soni). Eski 2-argumentli variant ham tushiriladi:
--    aks holda `sorov_tasdiq(id, summa)` chaqiruvi IKKI funksiyaga mos kelib
--    "function is not unique" (42725) berardi.
--    ⚠️ XAVFSIZ: `sorovlar-dev.html` hali PRODGA CHIQMAGAN, ya'ni bu imzoga
--    bog'langan jonli klient YO'Q.
drop function if exists sorov_tasdiq(uuid, numeric);
drop function if exists sorov_tasdiq(uuid, numeric, uuid);

create function sorov_tasdiq(p_id uuid, p_summa numeric, p_kassa uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  s        sorovlar;
  v_est    text;
  v_edel   boolean;
  v_xar    numeric := 0;
  v_bal    numeric;
  v_entry  uuid;
  v_holat  text;
  v_yopdi  boolean := false;
  v_gk     uuid;       -- HAQIQATDA to'lanadigan hisob (ildiz yoki tur-bolasi)
  v_acc    accounts;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('sorovlar') then
    raise exception 'Sorovlar sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  -- 8.2 (1) — qator qulfi
  select * into s from sorovlar where id = p_id for update;
  if not found then
    raise exception 'Sorov topilmadi' using errcode = '22000';
  end if;

  -- 8.1 — 🔴 YAGONA JOY: so'rov kelgan odam YOKI admin.
  if s.kimdan_id <> v_uid and not is_admin() then
    raise exception 'Sorovni faqat sorov kelgan odam yoki admin tasdiqlaydi'
      using errcode = '42501';
  end if;

  -- 8.2 (2) — ikki marta tasdiqlash: pul IKKI MARTA jo'natilmaydi
  if s.status <> 'pending' then
    return jsonb_build_object('ok', false, 'kod', 'already_decided',
                              'holat', s.status,
                              'jonatilgan_summa', s.jonatilgan_summa);
  end if;

  -- Summa chegarasi
  if p_summa is null or p_summa <= 0 or p_summa <> round(p_summa, 2) then
    raise exception 'Summa musbat bolishi kerak' using errcode = '22000';
  end if;
  if p_summa > s.summa then
    raise exception 'Soralgandan kop jonatib bolmaydi' using errcode = '22000';
  end if;

  -- 8.5 — xarajat holati
  if s.xarajat_entry_id is not null then
    select e.status, e.is_deleted into v_est, v_edel
      from entry e where e.id = s.xarajat_entry_id for update;

    if not found or v_edel is true then
      update sorovlar
         set status     = 'rad',
             rad_izoh   = 'Xarajat ochirilgan — sorov avtomat yopildi',
             decided_at = now(),
             decided_by = v_uid
       where id = s.id;
      return jsonb_build_object('ok', false, 'kod', 'xarajat_yoq', 'holat', 'rad');
    end if;

    -- 🔴 Summa NUSXAGA emas, YOZUVGA qarab olinadi (tahrirlangan bo'lishi mumkin)
    select coalesce(sum(l.credit), 0) into v_xar
      from entry_line l
     where l.entry_id = s.xarajat_entry_id and l.account_id = s.kassa_id;
  end if;

  -- 8.4 — TO'LOV HISOBI (8.1b): tanlangan yoki sukut bo'yicha ildiz kassa
  v_gk := coalesce(p_kassa, s.kimdan_kassa_id);

  select * into v_acc from accounts where id = v_gk;
  if not found or v_acc.is_active is distinct from true then
    raise exception 'Tolov hisobi topilmadi yoki faol emas' using errcode = '22000';
  end if;
  if v_acc.type <> 'aktiv' or v_acc.code not like '5%'
     or v_acc.kassa_turi is not distinct from 'xarajat_guruh' then
    raise exception 'Bu hisob kassa emas' using errcode = '22000';
  end if;
  -- 🔴 FAQAT UZS: so'rov so'mda. Valyuta hisobidan to'lash kurs
  --    konvertatsiyasini talab qiladi — u alohida mexanizm (konvert).
  if coalesce(v_acc.currency, 'UZS') <> 'UZS' then
    raise exception 'Valyuta hisobidan tolab bolmaydi — avval somga konvert qiling'
      using errcode = '22000';
  end if;
  -- 🔴 OILA CHEGARASI: faqat so'rov yo'naltirilgan kassaning O'ZI yoki
  --    uning BEVOSITA bolasi. Busiz admin (unda kassa cheklovi yo'q)
  --    ixtiyoriy hisob id'sini yuborib BEGONA kassani bo'shatib qo'yardi.
  if v_gk <> s.kimdan_kassa_id
     and v_acc.parent_id is distinct from s.kimdan_kassa_id then
    raise exception 'Bu hisob sorov kelgan kassaga tegishli emas' using errcode = '42501';
  end if;
  -- Ruxsat: `sorov_qaror_ctx.hisoblar` bilan AYNAN bir xil predikat
  if not perm_check_accounts(array[v_gk]) then
    raise exception 'Bu kassada amaliyot qilish huquqingiz yoq' using errcode = '42501';
  end if;
  v_bal := sorov_kassa_bal(v_gk);
  if v_bal < p_summa then
    raise exception 'Tanlangan hisobda pul yetmaydi (qoldiq: %)', v_bal using errcode = '22000';
  end if;

  -- ---- Pul provodkasi: Dt so'rovchi kassasi / Kt tasdiqlovchi kassasi
  -- 8.2 (3) — ext_ref UNIQUE: ikkinchi provodka bazaga kirmaydi
  insert into entry (entry_date, description, source, status, ext_ref)
  values ((now() at time zone 'Asia/Tashkent')::date,
          'Pul sorovi: ' || s.izoh,
          'manual',
          'posted',
          'sorov:' || s.id::text || ':jonatma')
  returning id into v_entry;

  -- 🔴 TARTIB MUHIM: `entry_line` dan OLDIN `sorovlar` yangilanadi —
  --    4-BO'LIM dagi guard istisnosi aynan `jonatma_entry_id` bog'lanishini
  --    qidiradi. Teskari tartibda tasdiqlash 42501 bilan yiqilardi.
  v_holat := case when p_summa = s.summa then 'tasdiq' else 'qisman' end;

  update sorovlar
     set jonatma_entry_id = v_entry,
         status           = v_holat,
         jonatilgan_summa = p_summa,
         -- 🔴 HAQIQATDA ishlatilgan hisob yoziladi. IKKI sabab:
         --    (1) guard istisnosi (4-BO'LIM) aynan shu ustunga qaraydi —
         --        tur-bolasidan to'langanda ham u ro'yxatda bo'lsin;
         --    (2) audit: keyin "pul qaysi hisobdan chiqdi" savoliga
         --        javob qatorning o'zida turadi.
         kimdan_kassa_id  = v_gk,
         decided_at       = now(),
         decided_by       = v_uid
   where id = s.id;

  insert into entry_line (entry_id, account_id, debit, credit)
  values (v_entry, s.kassa_id, p_summa, 0),
         (v_entry, v_gk,       0,       p_summa);

  -- 8.6 — pending xarajatni yopish (faqat pul yetsa)
  if s.xarajat_entry_id is not null and v_est = 'pending' then
    -- Bu tranzaksiyada yozilgan pul allaqachon 'posted' — qoldiqqa kiradi.
    -- 🔴 `v_xar > 0` SHART: yozuv tahrirlanib boshqa kassaga ko'chirilgan
    --    bo'lsa v_xar = 0 bo'lardi va biz begona yozuvni "posted" qilib
    --    yuborardik. Nol bo'lsa — tegmaymiz, pending qoladi.
    if v_xar > 0 and sorov_kassa_bal(s.kassa_id) >= v_xar then
      update entry set status = 'posted' where id = s.xarajat_entry_id;
      v_yopdi := true;
    end if;
  end if;

  update sorovlar set xarajat_yopildi = v_yopdi where id = s.id;

  return jsonb_build_object(
    'ok',               true,
    'holat',            v_holat,
    'jonatilgan_summa', p_summa,
    'jonatma_entry_id', v_entry,
    'tolov_hisob',      v_gk,
    'xarajat_yopildi',  v_yopdi,
    -- UI shuni yozadi: "Pul jonatildi, lekin xarajat hamon tasdiq kutmoqda"
    'qoldiq_yetmadi',   (s.xarajat_entry_id is not null and v_est = 'pending' and not v_yopdi));

exception
  -- Poyga: bir vaqtda ikki chaqiruv qulfdan o'tib ketsa ham ikkinchi
  -- provodka ext_ref UNIQUE ga urilib qaytadi — pul ikki marta chiqmaydi.
  when unique_violation then
    return jsonb_build_object('ok', false, 'kod', 'already_decided',
                              'holat', 'tasdiq');
end $fn$;

revoke all on function sorov_tasdiq(uuid, numeric, uuid) from public, anon;
grant execute on function sorov_tasdiq(uuid, numeric, uuid) to authenticated;

comment on function sorov_tasdiq(uuid, numeric, uuid) is
  'Pul jonatish (toliq yoki qisman) + pending xarajatni yopish. Sorov kelgan odam YOKI admin. '
  'p_kassa — qaysi hisobdan tolanadi (ildiz kassa yoki uning UZS tur-bolasi; null -> ildiz). '
  'Idempotent: for update + status tekshiruvi + ext_ref UNIQUE.';


-- #####################################################################
-- ##  9-BO'LIM — sorov_rad() · sorov_xarajat_bekor()                 ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 9.1  sorov_rad(p_id, p_izoh)
--
--   Sabab MAJBURIY (>= 3 belgi): sababsiz rad — so'rovchi uchun eng yomon
--   natija, u telefon qiladi (.sorov-ui.md §2.7).
--
--   🔴 RAD ETILSA PENDING XARAJAT NIMA BO'LADI — QAROR: AVTOMAT BEKOR
--      (`is_deleted = true`).
--   Asos:
--     * Pending xarajat hech qachon BALANSGA TA'SIR QILMAGAN — bekor
--       qilish hech qanday pulni o'zgartirmaydi (0.3 auditi).
--     * Uni tiriltirishning YAGONA yo'li — pul kelishi edi; pul kelmadi.
--     * Egasiz pending yozuv jurnalda ABADIY qolardi va uni tozalaydigan
--       hech kim yo'q (brief: "pending abadiy qolmasin").
--     * Hodim uchun narx — 30 soniya: xarajatni qaytadan kiritadi va
--       boshqa odamdan so'raydi.
--   ⚠️ YUMSHATISH bitta qatorda: `v_auto_bekor` ni `false` qiling —
--      u holda xarajat pending qoladi va hodim `sorov_xarajat_bekor`
--      bilan o'zi hal qiladi.
-- ---------------------------------------------------------------------
create or replace function sorov_rad(p_id uuid, p_izoh text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  s       sorovlar;
  v_izoh  text := nullif(btrim(coalesce(p_izoh, '')), '');
  v_auto_bekor boolean := true;      -- 🔴 yumshatish shu yerda
  v_bekor boolean := false;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('sorovlar') then
    raise exception 'Sorovlar sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;
  if v_izoh is null or length(v_izoh) < 3 then
    raise exception 'Rad etish sababi majburiy (kamida 3 belgi)' using errcode = '22000';
  end if;
  if length(v_izoh) > 200 then
    raise exception 'Sabab 200 belgidan oshmasin' using errcode = '22000';
  end if;

  select * into s from sorovlar where id = p_id for update;
  if not found then
    raise exception 'Sorov topilmadi' using errcode = '22000';
  end if;

  -- 🔴 8.1 bilan AYNAN bir xil qoida (sorov kelgan odam YOKI admin)
  if s.kimdan_id <> v_uid and not is_admin() then
    raise exception 'Sorovni faqat sorov kelgan odam yoki admin rad etadi'
      using errcode = '42501';
  end if;

  if s.status <> 'pending' then
    return jsonb_build_object('ok', false, 'kod', 'already_decided', 'holat', s.status);
  end if;

  update sorovlar
     set status     = 'rad',
         rad_izoh   = v_izoh,
         decided_at = now(),
         decided_by = v_uid
   where id = s.id;

  -- Pending xarajatni avtomat bekor qilish
  if v_auto_bekor and s.xarajat_entry_id is not null then
    update entry
       set is_deleted      = true,
           deleted_at      = now(),
           deleted_by_name = 'Sorov rad etildi'
     where id = s.xarajat_entry_id
       and status = 'pending'
       and is_deleted = false;
    v_bekor := found;
  end if;

  return jsonb_build_object('ok', true, 'holat', 'rad', 'xarajat_bekor', v_bekor);
end $fn$;

revoke all on function sorov_rad(uuid, text) from public, anon;
grant execute on function sorov_rad(uuid, text) to authenticated;

comment on function sorov_rad(uuid, text) is
  'Sorovni rad etish (sabab majburiy). Sorov kelgan odam YOKI admin. '
  'Pending xarajat AVTOMAT bekor qilinadi (is_deleted) — balansga tegmagan yozuv '
  'jurnalda abadiy qolmasin.';

-- ---------------------------------------------------------------------
-- 9.2  sorov_xarajat_bekor(p_entry) — hodim O'Z pending xarajatini
--      bekor qiladi (qisman qoplanib, qolganini so'ramoqchi bo'lmasa).
--
--   Shartlar (fail-closed):
--     * yozuv `status='pending'` va o'chirilmagan;
--     * yozuv AYNAN chaqiruvchi amaliyot qila oladigan kassadan chiqqan
--       (`perm_check_accounts`) — begona pending yozuvni o'chirib bo'lmaydi;
--     * bu xarajatga OCHIQ so'rov qolmagan (aks holda tasdiqlovchi
--       hal qilayotgan yozuv oyog'i ostidan tortib olinardi).
-- ---------------------------------------------------------------------
create or replace function sorov_xarajat_bekor(p_entry uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_est   text;
  v_edel  boolean;
  v_ega   text;
  v_kas   uuid;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  -- 🔴 `created_by` `to_jsonb()` orqali: ustun turi repoda ANIQLANMAGAN
  --    (uuid ham, matn ham bo'lishi mumkin — PROVODKA_EXT_REF.sql 0.4).
  select e.status, e.is_deleted, to_jsonb(e) ->> 'created_by'
    into v_est, v_edel, v_ega
    from entry e where e.id = p_entry for update;
  if not found then
    raise exception 'Yozuv topilmadi' using errcode = '22000';
  end if;
  if v_edel is true then
    return jsonb_build_object('ok', true, 'kod', 'already_deleted');
  end if;
  if v_est <> 'pending' then
    raise exception 'Faqat tasdiq kutayotgan xarajatni bekor qilish mumkin'
      using errcode = '22000';
  end if;

  -- Qaysi kassadan chiqqan
  select l.account_id into v_kas
    from entry_line l
    join accounts a on a.id = l.account_id
   where l.entry_id = p_entry and l.credit > 0
     and a.type = 'aktiv' and a.code like '5%'
   limit 1;
  if v_kas is null or not perm_check_accounts(array[v_kas]) then
    raise exception 'Bu yozuvni bekor qilish huquqingiz yoq' using errcode = '42501';
  end if;

  -- 🔴 EGALIK — FAIL-CLOSED. `perm_check_accounts` yolg'iz YETARLI EMAS:
  --    u `kassa_scope='all'` userga (sukut!) HAR qanday kassani ochib
  --    beradi, ya'ni begona pending xarajat o'chirilib ketardi.
  --    CLAUDE.md: "o'chirish faqat admin" — bu yerdagi yagona istisno
  --    YOZUV EGASI (o'z pending xarajati, balansga tegmagan).
  --    Egalikni tasdiqlab bo'lmasa (created_by bo'sh) — RAD ETAMIZ.
  if not is_admin() and (v_ega is null or v_ega <> v_uid::text) then
    raise exception 'Faqat yozuv egasi bekor qila oladi' using errcode = '42501';
  end if;

  if exists (select 1 from sorovlar s
              where s.xarajat_entry_id = p_entry and s.status = 'pending') then
    raise exception 'Bu xarajat uchun ochiq sorov bor — avval u hal bolsin'
      using errcode = '22000';
  end if;

  update entry
     set is_deleted      = true,
         deleted_at      = now(),
         deleted_by_name = 'Hodim bekor qildi'
   where id = p_entry;

  return jsonb_build_object('ok', true);
end $fn$;

revoke all on function sorov_xarajat_bekor(uuid) from public, anon;
grant execute on function sorov_xarajat_bekor(uuid) to authenticated;

comment on function sorov_xarajat_bekor(uuid) is
  'Hodim oz PENDING xarajatini bekor qiladi (ochiq sorov qolmagan bolsa). Balansga tegmaydi.';


-- #####################################################################
-- ## 10-BO'LIM — PostgREST sxema keshi                               ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ## 11-BO'LIM — TEKSHIRUV (hammasi true / kutilgan qiymat bo'lsin)  ##
-- #####################################################################

-- 11.1  Jadval, indekslar, RLS
select to_regclass('public.sorovlar') is not null                 as jadval_bor,
       (select relrowsecurity from pg_class
         where oid = 'public.sorovlar'::regclass)                 as rls_yoqilgan,
       (select count(*)::int from pg_policies
         where schemaname='public' and tablename='sorovlar')      as policy_soni_1_bulsin,
       (select count(*)::int from pg_policies
         where schemaname='public' and tablename='sorovlar'
           and cmd <> 'SELECT')                                   as yozish_policy_0_bulsin,
       (select count(*)::int from pg_indexes
         where schemaname='public' and tablename='sorovlar')      as indeks_soni,
       -- 🔴 nomma-nom: takror himoyasining ikkinchi qavati
       exists (select 1 from pg_indexes
                where schemaname='public' and tablename='sorovlar'
                  and indexname='sorovlar_ext_ref_uniq')          as ext_ref_uniq_bor,
       exists (select 1 from pg_indexes
                where schemaname='public' and tablename='sorovlar'
                  and indexname='sorovlar_ochiq_xarajat_uniq')    as ochiq_xarajat_uniq_bor;

-- 11.2  authenticated FAQAT select qila olsin
select has_table_privilege('authenticated','public.sorovlar','select') as select_ok_true,
       has_table_privilege('authenticated','public.sorovlar','insert') as insert_BULMASIN,
       has_table_privilege('authenticated','public.sorovlar','update') as update_BULMASIN,
       has_table_privilege('authenticated','public.sorovlar','delete') as delete_BULMASIN;

-- 11.3  perm_pages() da 'sorovlar' bormi (17 ta)
select array_length(perm_pages(), 1)         as kalit_soni_17_bulsin,
       'sorovlar' = any(perm_pages())        as sorovlar_kaliti_bor;

-- 11.4  Ochiq RPC lar mavjud va authenticated ga ochiqmi
select p.proname,
       has_function_privilege('authenticated', p.oid, 'execute') as ochiq
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('sorov_kimdan','sorov_yarat','sorov_royxat','sorov_menikilar',
                     'sorov_qaror_ctx','sorov_tasdiq','sorov_rad','sorov_xarajat_bekor')
 order by 1;

-- 11.5  ICHKI funksiyalar YOPIQ bo'lsin (hammasi false)
select p.proname,
       has_function_privilege('authenticated', p.oid, 'execute') as ochiq_BULMASIN
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('sorov_page_ok','sorov_kassa_bal','sorov_kassa_of',
                     'sorov_nomzod_ok','sorov_ism','sorov_qator')
 order by 1;

-- 11.6  🔴 GUARD ISTISNOSI O'RNIDAMI (PROVODKA_PERMS.sql keyin RUN
--       qilinsa bu FALSE bo'ladi -> 4-BO'LIMni qayta RUN qiling)
select (select p.prosrc like '%jonatma_entry_id%'
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname='public' and p.proname='perm_guard_entry_line'
         limit 1)                                                 as guard_istisnosi_bor,
       exists (select 1 from pg_trigger
                where tgrelid = 'public.entry_line'::regclass
                  and tgname = 'trg_perm_guard_entry_line'
                  and not tgisinternal)                           as trigger_joyida;

-- 11.7  Sahifa qorovuli uchala sahifa RPC sida bormi (3 bo'lsin)
select (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname='public'
           and p.proname in ('sorov_royxat','sorov_qaror_ctx','sorov_tasdiq')
           and p.prosrc like '%sorov_page_ok(''sorovlar'')%')     as qorovulli_rpc_3_bulsin,
       (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname='public' and p.proname = 'sorov_rad'
           and p.prosrc like '%sorov_page_ok(''sorovlar'')%')     as rad_qorovulli_1_bulsin;

-- 11.8  🔴 PENDING PUL SIZMAYDIMI — jonli tekshiruv.
--       Kutilgan: `pending_qoldiqda` = 0 (pending yozuvlar qoldiqqa
--       umuman qo'shilmagan). Pending yozuv bo'lmasa 0 chiqadi — normal.
select count(*)::int                                              as pending_yozuv,
       coalesce(sum(x.summa), 0)                                  as pending_summa,
       0                                                          as pending_qoldiqda_kutilgan
  from (
    select e.id, coalesce(sum(l.debit), 0) as summa
      from entry e join entry_line l on l.entry_id = e.id
     where e.status = 'pending' and e.is_deleted = false
     group by e.id
  ) x;

-- 11.9  Nazorat: pending yozuv `v_hisob_bal` ga tushmaganini isbotlash.
--       Kutilgan: har qatorda `farq_0_bulsin` = 0.
--       🔴 ALOHIDA RUN QILING (fayl ichida emas): `v_hisob_bal` bo'lmagan
--       bazada bu so'rov butun skriptni orqaga qaytarardi.
--
-- select a.code, a.name,
--        coalesce(b.uzs, 0)                         as view_qoldiq,
--        sorov_kassa_bal(a.id)                      as funksiya_qoldiq,
--        coalesce(b.uzs, 0) - sorov_kassa_bal(a.id) as farq_0_bulsin
--   from accounts a
--   left join v_hisob_bal b on b.account_id = a.id
--  where a.id in (select distinct l.account_id
--                   from entry e join entry_line l on l.entry_id = e.id
--                  where e.status = 'pending')
--  order by a.code;

-- 11.10 JONLI SINOV — 🔴 SQL EDITORIDA RUN QILINMAYDI (ataylab izohda).
--   Sabab: editorda so'rov `postgres` roli bilan, JWT'siz ketadi ->
--   `auth.uid()` NULL -> qorovul fail-closed bo'lib 42501 beradi, va
--   Postgres ko'p-operatorli skriptni BITTA tranzaksiyada bajargani
--   uchun BUTUN FAYL orqaga qaytardi (funksiyalar yaratilmasdi).
--   Sinov BRAUZERDA qilinadi (Network panelida rpc/sorov_* -> 200):
--     * 404 -> SQL RUN bo'lmagan;
--     * 403 -> userda 'sorovlar' sahifa ruxsati yo'q.
--
--   -- select sorov_kimdan();
--   -- select sorov_royxat('pending');
--   -- select sorov_menikilar(5);


-- #####################################################################
-- ## 12-BO'LIM — ROLLBACK (qo'lda, kerak bo'lganda)                  ##
-- #####################################################################
-- ⚠️ Tartib MUHIM: avval funksiyalar, keyin jadval (FK va composite
--    parametr `sorov_qator(sorovlar, uuid)` jadvalga bog'langan).
--
-- -- 12.1  Ochiq RPC lar
-- drop function if exists sorov_xarajat_bekor(uuid);
-- drop function if exists sorov_rad(uuid, text);
-- drop function if exists sorov_tasdiq(uuid, numeric, uuid);
-- drop function if exists sorov_tasdiq(uuid, numeric);   -- eski imzo (bo lsa)
-- drop function if exists sorov_qaror_ctx(uuid);
-- drop function if exists sorov_menikilar(int);
-- drop function if exists sorov_royxat(text, boolean);
-- drop function if exists sorov_yarat(uuid, uuid, numeric, text, uuid, numeric, text,
--                                     text, date, uuid[], date, date, text, uuid);
-- drop function if exists sorov_kimdan();
--
-- -- 12.2  Ichki yordamchilar
-- drop function if exists sorov_qator(sorovlar, uuid);
-- drop function if exists sorov_ism(uuid, uuid);
-- drop function if exists sorov_nomzod_ok(uuid);
-- drop function if exists sorov_kassa_of(uuid);
-- drop function if exists sorov_kassa_bal(uuid);
-- drop function if exists sorov_page_ok(text);
--
-- -- 12.3  🔴 GUARD ni eski holiga (PROVODKA_PERMS.sql 4-BO'LIMi)
-- --       Bu SHART: aks holda funksiya yo'q `sorovlar` jadvaliga
-- --       murojaat qilib qolardi.
-- -- (PROVODKA_PERMS.sql dagi perm_guard_entry_line() ni qayta RUN qiling)
--
-- -- 12.4  Jadval. 🔴 DIQQAT: pending xarajatlar YETIM QOLADI.
-- --       Avval ularni hal qiling:
-- --   select e.id, e.entry_date, e.description
-- --     from entry e where e.status = 'pending' and e.is_deleted = false;
-- --   update entry set is_deleted = true, deleted_at = now(),
-- --          deleted_by_name = 'Sorovlar tizimi ochirildi'
-- --    where status = 'pending' and is_deleted = false;
-- drop table if exists sorovlar;
--
-- -- 12.5  perm_pages() dan 'sorovlar' ni olib tashlash
-- --       (PROVODKA_AI_AGENT.sql 1-BO'LIMini qayta RUN qiling — 16 kalit)


-- #####################################################################
-- ## 13-BO'LIM — KLIENT KONTRAKTI (coder uchun)                      ##
-- #####################################################################
--
-- ## 13.1  RPC lar (hammasi `sb.rpc(nom, {...})`, nomlangan argument)
--
--   sorov_kimdan()
--     -> [{user_id, kassa_id, nom, subtitle, oxirgi_soralgan}]
--     🔴 BALANS/SUMMA MAYDONI YO'Q. Tartib serverda (oxirgi_soralgan -> nom) —
--        klient QAYTA SARALAMASIN, aks holda yashirin kanal ochiladi.
--     ⚠️ Bo'sh massiv qaytishi MUMKIN (nomzod yo'q) -> .sorov-ui.md §1.6-c
--        dagi "So'rash mumkin bo'lgan odam topilmadi" holati.
--
--   sorov_yarat({p_kassa, p_modda, p_summa_xarajat, p_izoh_xarajat,
--                p_kimdan, p_sorov_summa, p_sorov_izoh, p_ext_ref,
--                p_entry_date, p_filial_ids, p_davr_start, p_davr_end,
--                p_kommunal_turi, p_xarajat_entry})
--     -> {ok:true, sorov_id, entry_id, status:'pending', xarajat_yangi}
--     🔴 "QOLGANINI SO'RASH" (qisman qoplangan xarajat uchun ikkinchi
--        so'rov) — FAQAT 5 kalit:
--          {p_xarajat_entry, p_kimdan, p_sorov_summa, p_sorov_izoh, p_ext_ref}
--        Yangi xarajat yozilmaydi; kassa/chegara yozuvdan olinadi.
--        ⚠️ Bu oqimda `entry` yozilmagani uchun `xarajat_qayta_urinish`
--        ('yoq' qaytaradi) takrorni ANIQLAY OLMAYDI — takror `23505`
--        (`sorovlar_ext_ref_uniq`) bilan to'siladi. Klient (a) oqimida
--        23505 ni "so'rov allaqachon yuborilgan" deb o'qisin (jimgina
--        muvaffaqiyat), 'nomalum' deb emas.
--     🔴 `p_ext_ref` — `hodim-dev.html` dagi MAVJUD token (`tokenBoshla`)
--        AYNAN qayta ishlatiladi; 23505 -> "Allaqachon saqlangan" (mavjud
--        `isDup(e)` shoxi o'zgarmaydi).
--     🔴 Chek yuklash: javobdagi `entry_id` bilan, mavjud yo'l bo'yicha
--        (`xarajat-cheklari/<kassa_id>/<entry_id>.jpg`).
--
--   sorov_menikilar({p_limit})   -> [qator]   (hodim tarixidagi nishon)
--   sorov_royxat({p_holat, p_hammasi}) -> [qator]  (sorovlar sahifasi)
--   sorov_qaror_ctx({p_id})      -> {soralgan, mening_qoldigim, valyuta,
--                                    kassa_nom, hisoblar[], ozim, kimdan_nom}
--     `hisoblar[]` = [{account_id, code, name, qoldiq}] — FAQAT UZS.
--     `ozim=false` -> admin boshqa odam nomidan: yorliq almashadi.
--   sorov_tasdiq({p_id, p_summa, p_kassa})
--                                -> {ok, holat, jonatilgan_summa,
--                                    jonatma_entry_id, tolov_hisob,
--                                    xarajat_yopildi, qoldiq_yetmadi}
--     🔴 `p_kassa` — `sorov_qaror_ctx.hisoblar` dan TANLANGAN hisob
--        (ildiz kassa yoki uning UZS tur-bolasi). Bittadan ko'p bo'lsa
--        tanlov MAJBURIY; null yuborilsa ildiz kassa ishlatiladi.
--                                 yoki {ok:false, kod:'already_decided'|'xarajat_yoq'}
--   sorov_rad({p_id, p_izoh})    -> {ok, holat:'rad', xarajat_bekor}
--   sorov_xarajat_bekor({p_entry}) -> {ok}
--
-- ## 13.2  Qator shakli (.sorov-ui.md §0.5-b + qo'shimchalar)
--   {id, sorovchi_id, sorovchi_nom, sorovchi_sub, kimdan_id, kimdan_nom,
--    summa, izoh, status, jonatilgan_summa, qaror_izoh, qaror_kim,
--    qaror_vaqt, sana, entry_id, jonatma_entry_id,
--    xarajat_yopildi, meniki, men_qaror_qila_olaman}
--   🔴 `xarajat_summa` javobda YO'Q (balans ayirma orqali tiklanardi).
--      "Qolganini so'rash" oqimida u KERAK EMAS: `sorov_yarat` kassa va
--      chegarani `p_xarajat_entry` dan O'ZI oladi (6.4).
--   🔴 `men_qaror_qila_olaman` SERVERDAN keladi. Klient
--      `kimdan_id === my_uid` deb O'ZI hisoblamasin (admin hamma so'rovni
--      ko'radi, lekin hech birini tasdiqlay olmaydi). Maydon umuman
--      kelmasa -> `.s-ro` (fail-closed, .sorov-ui.md §2.8).
--   ℹ️ `.sorov-ui.md` dagi `v_sorov_royxat` = shu `sorov_royxat()` RPC si.
--      View ATAYLAB yaratilmadi: ism/ruxsat mantiqi ikki joyda takrorlanib,
--      vaqt o'tib ajralib ketardi (bitta shakl — `sorov_qator`).
--
-- ## 13.3  Har `{data, error}` tekshiriladi (supabase-js throw QILMAYDI)
--   * 42501 -> `permErr(e)`;
--   * 23505 -> "allaqachon saqlangan" (mavjud takror-himoya shoxi);
--   * `{ok:false, kod:'already_decided'}` — XATO EMAS: modal jimgina
--     yopiladi va ro'yxat `load(true)` bilan yangilanadi;
--   * `{ok:false, kod:'xarajat_yoq'}` — "Xarajat o'chirilgan, so'rov yopildi".
--
-- ## 13.4  🔴 UCH+ JOYGA YOZILADI (busiz sahifa jimgina ko'rinmay qoladi)
--   (a) `perms-dev.js` -> `PAGES` ga 'sorovlar'
--   (b) `admin-dev.html` -> `PVS_PAGES` ga {key:'sorovlar', label:"So'rovlar"}
--   (c) `index-dev.html` -> `CARDS` ga sorovlar kartasi
--   (d) `promote.sh` -> `PAGES` ga 'sorovlar'
--   (e) 15 dev faylda sidebar (16-element, Konvert dan OLDIN) + "Ko'proq" sheet
--
-- ## 13.5  ⚠️ HODIM SAHIFASIDA "Pul so'rash" TUGMASI
--   `srvNeeded()` sharti: `over && accCur()==='UZS' && selKassa && selModda
--   && amt>0 && okAmt`. Server ham AYNAN shuni majburlaydi (6.4: valyuta
--   kassasida xato). Valyuta kassasida tugma CHIQMASIN.
--
-- ## 13.6  ⚠️ PENDING XARAJAT JURNALDA
--   `jurnal_v2_baza` / `jurnal_dash` / `hodim_oz_tarix` / `hodim_amallar`
--   `status='posted'` bilan filtrlaydi (0.3 auditi) — ya'ni pending
--   xarajat JURNALDA VA HODIM TARIXIDA KO'RINMAYDI. Bu XAVFSIZ (pul
--   sizmaydi), lekin brief "jurnalga tushadi (pending)" deydi.
--   🔴 QAROR ASILBEKKA: ko'rinishi kerak bo'lsa — ALOHIDA ish
--   (`jurnal_v2_baza` ga `status in ('posted','pending')` + pending
--   yozuvni ro'yxatda nishonlash, AGREGATDA esa QAT'IY chiqarib tashlash).
--   Bu faylda ATAYLAB QILINMADI: agregat filtri bitta joyda xato
--   qo'yilsa pending pul dashboardga sizardi.
--   Hozircha hodim o'z pending so'rovini `sorov_menikilar()` orqali
--   ko'radi (.sorov-ui.md §1.8 nishoni aynan shundan chiziladi).
--
-- ## 13.7  🔴 YETIM PENDING XARAJAT — KLIENT MAJBURIYATI (hodim-dev.html)
--   Qisman tasdiqda so'rov YOPILADI (8.3), lekin pul yetmasa xarajat
--   PENDING QOLADI (8.6). Bu holat KLIENTDA ko'rinmasa, hodim formadan
--   qaytadan yozib IKKINCHI pending yaratadi va birinchisi abadiy yetim
--   qoladi — admin uni keyin qo'lda posted qilsa xarajat IKKI MARTA
--   hisoblanadi. `sorovlar_ochiq_xarajat_uniq` buni TO'SMAYDI (yopilgan
--   so'rov "ochiq" emas).
--   Shuning uchun `#srvPend` bloki `sorov_menikilar()` javobidan
--     status in ('qisman','tasdiq') and xarajat_yopildi = false and entry_id
--   qatorlarini ALOHIDA guruh qilib chizadi va ikki amal beradi:
--     (a) "Qolganini so'rash" -> sorov_yarat({p_xarajat_entry, p_kimdan,
--         p_sorov_summa, p_sorov_izoh, p_ext_ref})   <- 6.4 (a) oqimi
--     (b) "Bekor qilish"       -> sorov_xarajat_bekor({p_entry})
--   Ikkalasi ham fail-closed: RPC yo'q bo'lsa tugma chizilmaydi.
-- =====================================================================
