-- =====================================================================
-- PROVODKA — JURNAL V2 (yangi jurnal sahifasi uchun server RPC'lari)
-- ---------------------------------------------------------------------
-- NIMA UCHUN:
--   Eski `jurnal()` / `jurnal_count()` faqat SANA + HISOB bo'yicha filtrlaydi.
--   Tur (kirim/chiqim/transfer…) va matn qidiruvi KLIENTDA bajarilardi —
--   ya'ni ular faqat YUKLANGAN 100 qatorga ta'sir qilardi, sanoq esa
--   serverdagi to'liq sonni ko'rsatardi. Yangi jurnalda filtrlar
--   (hisob + xarajat moddasi + tur + qidiruv) SERVERDA, AND bilan
--   bajariladi va dashboard raqamlari ro'yxat bilan bitta manbadan keladi.
--
--   Naqsh AYNAN `hisobot_baza()`/`hisobot_royxat()`/`hisobot_xulosa()`
--   (PROVODKA_V8.sql, 1-BOSQICH) dan olingan: bitta ICHKI baza funksiyasi +
--   uning ustida ochiq wrapperlar. Shu tufayli ro'yxatdagi qatorlar bilan
--   yuqoridagi totallar hech qachon farq qilmaydi.
--
--   🔴 JURNAL ↔ HISOBOT FARQI: jurnalda O'CHIRILGAN yozuvlar ham ko'rinadi
--   (usti chizilgan holda — kim/qachon o'chirgani bilan), hisobotda esa yo'q.
--   Shuning uchun `jurnal_v2_baza` da `is_deleted = false` sharti YO'Q.
--   Ammo dashboard'dagi "nimaga qancha" (xarajat breakdown) o'chirilgan
--   yozuvlarni HISOBGA OLMAYDI — u pul harakati emas.
--
--   🔴 RUXSAT SERVERDA: `perm_view_pul_ids()` bo'yicha, klient nima
--   yuborishidan qat'i nazar (pastda "RUXSAT" izohiga qara). Fail-closed:
--   bo'sh massiv (hech narsa ko'rmaydigan user) → hech qanday qator/summa
--   qaytmaydi.
--
--   🔴 SAHIFA QOROVULI: uchala ochiq RPC boshida `jurnal_page_ok('jurnal')`
--   (`ai_ctx_has_page` naqshi). Kassa ruxsati YETARLI EMAS — `kassa_scope`
--   sukuti `'all'`, ya'ni yangi userda kassa filtri umuman yo'q va
--   `allowed_pages=['hodim']` bo'lgan user RPC ni to'g'ridan chaqirib butun
--   jurnalni olardi. Endi server UI bilan izchil (42501 qaytadi).
--
--   🔴 AGREGAT FAIL-CLOSED (summa orqali sizishga qarshi). `jurnal_dash`
--   raqamlaridan IKKI xil yozuv chiqarib tashlanadi (ro'yxatda esa ko'rinadi —
--   bu jurnal semantikasi, `jurnal()` bilan bir xil):
--     1) O'CHIRILGAN yozuv — pul harakati emas. Uchala raqamda ham
--        (`jami`/`turlar`/`xarajat`) bir xil, izchil.
--     2) ARALASH KO'P SATRLI yozuv — `begona and n_lines > 2`: ichida menga
--        ruxsat berilmagan pul hisobi bor. Misol:
--        `Dt Ijara 10 mln / Kt mening kassam 1 mln / Kt begona kassa 9 mln`
--        — summa butun yozuvniki (10 mln), menikisi atigi 1 mln; yozuv
--        jamiga qo'shilsa begona 9 mln sizardi. Pro-rata ATAYLAB qilinmadi
--        (taxminiy raqam berardi — AI 5-bosqich qarori bilan bir xil).
--   ⚠️ `n_lines > 2` sharti MAJBURIY: 2 satrli yozuvda sizadigan narsa yo'q
--   (Dt=Kt=bitta summa, u ro'yxatda ko'rinadi). Usiz filial kassiri uchun
--   markazga jo'natilgan HAR transfer dashboarddan tushib qolardi.
--   ⚠️ SHUNING UCHUN: dashboard jami ro'yxatdagi yozuvlar jamisidan KICHIK
--   bo'lishi MUMKIN va bu XATO EMAS. Nechtasi chetlanganini javob ochiq
--   aytadi: `chetlangan = {soni, ochirilgan}` (jimgina kam ko'rsatish — xato
--   manbai, CLAUDE.md `shakl_shubhali` saboqi). UI shuni yozadi:
--   "N ta aralash + M ta o'chirilgan yozuv jamiga kirmadi".
--   INVARIANT (p_turlar := NULL bilan):
--     jami.soni + chetlangan.soni + chetlangan.ochirilgan
--       = jurnal_v2_count(p_from, p_to, p_accounts, p_moddalar, null, p_q)
--
--   🔴 DASHBOARD `p_turlar` GA BO'YSUNMAYDI: u DAVR XULOSASI (davr +
--   hisob + modda + qidiruv), tur esa RO'YXAT ko'rinishi tugmasi. Parametr
--   imzoda qoladi (klient moslik uchun yuboradi), lekin e'tiborga olinmaydi.
--   Aks holda `turlar` kesimi (tabiatan hamma tur) bilan `jami` bitta
--   ekranda zid raqam berardi — 4-BO'LIM izohiga qara. Ya'ni tur
--   tanlanganda ro'yxat soni dashboard jamisidan kichik bo'lishi NORMAL.
--
-- ADDITIVE: hech narsa drop qilinmaydi, mavjud imzo o'zgarmaydi.
--   `jurnal()` / `jurnal_count()` TEGILMAGAN — eski jurnal ishlayveradi.
--   `set_modda_flag(uuid,text,boolean)` imzosi o'zgarmaydi (faqat tanasiga
--   'filial' bayrog'i qo'shiladi), eski 'chek'|'izoh'|'davr' TEGILMAGAN.
--   Bir necha marta RUN qilish xavfsiz (idempotent).
--
-- RUN TARTIBI (Asilbek, Supabase SQL editor):
--   0) Old shart — allaqachon bazada bo'lishi kerak:
--        PROVODKA_PERMS.sql      → perm_op_key(), is_admin(), user_perms
--        PROVODKA_V6.sql         → set_modda_flag(), accounts.izoh/davr_majburiy
--        PROVODKA_V8.sql         → perm_view_pul_ids()  (1-BOSQICH bo'limi)
--        PROVODKA_PAGES_EMPTY.sql→ perm_has_page()  — SHART EMAS (ixtiyoriy):
--            sahifa qorovuli uni dinamik tekshiradi, yo'q bo'lsa
--            `allowed_pages` ning o'zi bilan ishlayveradi (fail-closed).
--   1) Shu faylni BUTUNLIGICHA nusxalab RUN qiling (bo'lib emas).
--      ⚠️ AGAR bu faylning AVVALGI varianti allaqachon RUN qilingan bo'lsa,
--      `jurnal_v2_baza` ning `returns table(...)` ro'yxati o'zgargani uchun
--      `create or replace` quyidagi xatoni beradi:
--         ERROR: cannot change return type of existing function
--      Yechim — avval ICHKI funksiyani tashlab yuboring, keyin faylni
--      QAYTADAN to'liq RUN qiling:
--         drop function if exists public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text);
--      🔴 Bu XAVFSIZ: `jurnal_v2_baza` ICHKI (authenticated'ga execute
--      berilmagan, hech qanday klient/PostgREST unga bog'lanmagan) va fayl
--      uni darrov qayta yaratadi. OCHIQ RPC lar (`jurnal_v2`, `jurnal_v2_count`,
--      `jurnal_dash`, `set_modda_flag`) HECH QACHON drop QILINMAYDI.
--   2) Oxiridagi TEKSHIRUV select'lari hamma ustunda `true` bersin.
--   3) `notify pgrst, 'reload schema'` avtomatik bajariladi (fayl ichida).
-- =====================================================================


-- =====================================================================
-- 1-BO'LIM — jurnal_v2_baza() — ICHKI: filtrlangan yozuvlar + tur tasnifi
-- ---------------------------------------------------------------------
-- Uchala ochiq RPC (jurnal_v2 / jurnal_v2_count / jurnal_dash) SHU bitta
-- manbadan oziqlanadi.
--
-- TUR TASNIFI — hisobot_baza() bilan AYNAN bir xil (jurnal.klass() ning
-- server nusxasi):
--   n_lines > 2                        -> boshqa     (ko'p satrli, Professional)
--   Dt pul  va Kt pul                  -> transfer
--   Dt pul  va Kt daromad              -> tushum
--   Dt pul                             -> kirim
--   Kt pul  va Dt xarajat              -> xarajat
--   Kt pul                             -> chiqim
--   aks holda                          -> boshqa     (neytral: ombor -> tannarx)
-- Turlar o'zaro kesishmaydi → turlar bo'yicha jami = umumiy jami.
--
-- FILTRLAR — hammasi AND (OR emas):
--   sana        : entry_date between p_from and p_to
--   p_accounts  : yozuvda shu hisoblardan biri QATNASHGAN bo'lsin (Dt yoki Kt)
--   p_moddalar  : yozuvda shu hisoblardan biriga DEBET satri bo'lsin
--                 (xarajat moddasi filtri — "nimaga sarflandi")
--   p_turlar    : yuqoridagi tasnif bo'yicha
--   p_q         : entry.description ilike '%q%'  (metabelgilar tozalangan)
--
-- 🔴 RUXSAT (fail-closed, hisobot_acc() naqshi):
--   perm_view_pul_ids() null bo'lsa  → cheklovsiz (admin / qatorsiz user /
--     service_role) — qo'shimcha shart qo'yilmaydi.
--   null bo'lmasa (kassa_scope='list') → yozuvda o'sha ruxsat etilgan PUL
--     hisoblaridan kamida bittasi qatnashgan bo'lishi SHART. Bu klient
--     filtri (p_accounts) bilan KESISHTIRILMAYDI, balki ALOHIDA `exists`
--     sharti bo'lib AND qilinadi — sabab: klient p_accounts ga kassa
--     yuboradi, p_moddalar ga xarajat moddasini; ruxsat esa faqat pul
--     hisoblari bo'yicha yuritiladi. Kesishma olinsa modda filtri ruxsatni
--     yo'q qilib yuborardi.
--   Bo'sh massiv ('{}') → `= any('{}')` hech qachon true bermaydi → NOL
--     qator. Ya'ni "hech narsa ko'rmaydigan" user hech narsa olmaydi.
--
-- Ruxsat SHU YERDA majburlangani uchun (hisobot_baza dan farqi — u
-- wrapperga tashlaydi) uchala wrapper ham avtomat himoyalangan.
-- authenticated'ga execute BERILMAYDI.
-- =====================================================================

create or replace function jurnal_v2_baza(
  p_from     date,
  p_to       date,
  p_accounts uuid[],
  p_moddalar uuid[],
  p_turlar   text[],
  p_q        text)
returns table(
  id uuid, entry_date date, created_at timestamptz, description text,
  source text, is_deleted boolean, deleted_by_name text, deleted_at timestamptz,
  edited_at timestamptz, edited_by_name text,
  n_lines int, summa numeric, tur text,
  begona boolean
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_perm     uuid[] := perm_view_pul_ids();   -- null = cheklovsiz, '{}' = hech narsa
  v_moddalar uuid[];
  v_q        text;
begin
  -- ⚠️ TUZOQ — bo'sh massiv MA'NOSI bu funksiyada BIR XIL EMAS:
  --   p_moddalar = '{}' → "filtr yo'q"  (shu yerda null ga aylantiriladi)
  --   p_accounts = '{}' → HECH NARSA    (= any('{}') hech qachon true emas)
  --   p_turlar   = '{}' → HECH NARSA    (hisobot_baza bilan bir xil)
  -- Klient hech qachon `[]` yubormaydi (jurnal-dev.html bo'sh massivni
  -- serverga umuman jo'natmaydi), shuning uchun xatti-harakat O'ZGARTIRILMADI —
  -- lekin yangi chaqiruvchi yozayotgan bo'lsang SHU FARQNI unutma.
  if p_moddalar is null or array_length(p_moddalar, 1) is null then
    v_moddalar := null;
  else
    v_moddalar := p_moddalar;
  end if;

  -- Qidiruv: LIKE metabelgilarini tozalaymiz — '%' yozgan user butun bazani
  -- olib qo'ymasin, '_' esa bitta harf o'rniga o'zi bo'lib qidirilsin.
  if p_q is null or btrim(p_q) = '' then
    v_q := null;
  else
    v_q := '%' || replace(replace(replace(btrim(p_q), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  return query
  with e as (
    select en.id                as e_id,
           en.entry_date        as e_date,
           en.created_at        as e_created,
           en.description       as e_desc,
           en.source            as e_source,
           en.is_deleted        as e_del,
           en.deleted_by_name   as e_delby,
           en.deleted_at        as e_delat,
           en.edited_at         as e_edat,
           en.edited_by_name    as e_edby,
           -- 🔴 ARALASH YOZUV BAYROG'I (fail-closed agregat uchun):
           -- yozuvda menga ruxsat BERILMAGAN pul hisobi qatnashganmi.
           -- Misol (professional-dev.html, ko'p satrli):
           --   Dt Ijara 10 mln / Kt mening kassam 1 mln / Kt begona kassa 9 mln
           -- Yozuv ro'yxatda ko'rinadi (jurnal semantikasi, jurnal() bilan bir xil),
           -- lekin AGREGATGA kirmasligi kerak — aks holda begona 9 mln `jami`
           -- va `xarajat` kesimi orqali sizardi. Pro-rata ATAYLAB qilinmagan:
           -- u taxminiy raqam berardi (AI 5-bosqichda ham shu qaror).
           -- v_perm null (admin / cheklovsiz) → har doim false.
           --
           -- 🔴 DIQQAT: bu bayroqning O'ZI yozuvni agregatdan CHIQARMAYDI.
           -- `jurnal_dash` uni FAQAT `n_lines > 2` bilan birga qo'llaydi.
           -- Sabab: 2 satrli yozuvda sizadigan narsa yo'q (Dt=Kt=bitta summa,
           -- yozuv ro'yxatda ko'ringani uchun user summani allaqachon biladi).
           -- Aks holda filial kassiri uchun markazga jo'natilgan HAR transfer
           -- (Dt 5011 markaziy / Kt 52xx meniki) dashboarddan tushib qolardi —
           -- ro'yxatda 40 yozuv, dashboardda 0.
           -- ⚠️ Hisob tanlash sharti perm_view_pul_ids() BILAN AYNAN BIR XIL
           -- bo'lishi shart (type='aktiv' + code like '5%' + xarajat_guruh emas).
           -- `section='pul'` ishlatilsa, shu uch shartga tushmaydigan pul
           -- hisobi HECH QACHON v_perm da bo'lmaydi → yozuv doim "begona"
           -- deb belgilanib, dashboarddan bejiz tushib qolardi.
           (v_perm is not null and exists (
              select 1 from entry_line el join accounts ab on ab.id = el.account_id
               where el.entry_id = en.id
                 and ab.type = 'aktiv' and ab.code like '5%'
                 and ab.kassa_turi is distinct from 'xarajat_guruh'
                 and not (el.account_id = any(v_perm)))) as e_begona
      from entry en
     where en.status = 'posted'
       -- 🔴 is_deleted filtri ATAYLAB YO'Q (jurnal o'chirilganini ham ko'rsatadi)
       and en.entry_date >= p_from and en.entry_date <= p_to
       -- klient hisob filtri (kassa / hisob)
       and (p_accounts is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(p_accounts)))
       -- xarajat moddasi filtri: shu moddaga DEBET yozilgan bo'lsin
       and (v_moddalar is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(v_moddalar)
                and el.debit > 0))
       -- 🔴 RUXSAT (server tomonda, klient filtridan MUSTAQIL)
       and (v_perm is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(v_perm)))
       -- matn qidiruvi
       and (v_q is null or en.description ilike v_q escape '\')
  ),
  c as (
    select e.*,
           (select count(*)::int from entry_line l where l.entry_id = e.e_id) as n,
           (select coalesce(sum(l.debit), 0)::numeric from entry_line l where l.entry_id = e.e_id) as s,
           d.sec as dt_sec, d.typ as dt_type,
           k.sec as kt_sec, k.typ as kt_type
      from e
      left join lateral (
        select a.section as sec, a.type as typ
          from entry_line l join accounts a on a.id = l.account_id
         where l.entry_id = e.e_id and l.debit > 0
         order by l.debit desc limit 1) d on true
      left join lateral (
        select a.section as sec, a.type as typ
          from entry_line l join accounts a on a.id = l.account_id
         where l.entry_id = e.e_id and l.credit > 0
         order by l.credit desc limit 1) k on true
  ),
  t as (
    select c.*,
           case
             when c.n > 2                                    then 'boshqa'
             when c.dt_sec = 'pul' and c.kt_sec = 'pul'      then 'transfer'
             when c.dt_sec = 'pul' and c.kt_type = 'daromad' then 'tushum'
             when c.dt_sec = 'pul'                           then 'kirim'
             when c.kt_sec = 'pul' and c.dt_type = 'xarajat' then 'xarajat'
             when c.kt_sec = 'pul'                           then 'chiqim'
             else 'boshqa'
           end as tt
      from c
  )
  -- ⚠️ Aniq cast: entry ustunlari varchar bo'lsa ham "structure of query does
  -- not match function result type" xatosi chiqmasin.
  select t.e_id::uuid, t.e_date::date, t.e_created::timestamptz, t.e_desc::text,
         t.e_source::text, t.e_del::boolean, t.e_delby::text, t.e_delat::timestamptz,
         t.e_edat::timestamptz, t.e_edby::text,
         t.n::int, t.s::numeric, t.tt::text, t.e_begona::boolean
    from t
   where p_turlar is null or t.tt = any(p_turlar);
end $fn$;

revoke all on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text) from public, anon, authenticated;

comment on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text) is
  'ICHKI: jurnal v2 uchun filtrlangan yozuvlar + tur tasnifi (ruxsat shu yerda majburlanadi). Faqat jurnal_v2* wrapperlari chaqiradi.';


-- =====================================================================
-- 1B-BO'LIM — jurnal_page_ok() — SAHIFA QOROVULI (ICHKI)
-- ---------------------------------------------------------------------
-- 🔴 NIMA UCHUN KERAK (tester topgan teshik): uchala ochiq RPC
-- `security definer` + `grant to authenticated`, ichida esa faqat KASSA
-- ruxsati bor. `kassa_scope` sukuti — `'all'`, ya'ni yangi userda
-- `perm_view_pul_ids()` NULL (cheklovsiz). Natijada `allowed_pages=['hodim']`
-- bo'lgan, jurnal sahifasi UI'da YOPIQ user
--   POST /rest/v1/rpc/jurnal_v2 {p_from:'2020-01-01',p_to:'2030-01-01',p_limit:1000}
-- deb butun kompaniya jurnalini olardi. Endi UI bilan izchil.
--
-- Naqsh — `PROVODKA_AI_KONTEKST.sql` dagi `ai_ctx_has_page()` ning AYNAN
-- nusxasi (Asilbek qarori 2026-08-14: sahifa qorovuli har DEFINER RPC da):
--   auth.uid() null      → false   (service_role/anon uchun ochiq emas)
--   is_admin()           → true    (admin hech qachon cheklanmaydi)
--   user_perms qatori yo'q → false (qatorsiz = sahifa ruxsati YO'Q)
--   allowed_pages ∌ key  → false
--   + `perm_has_page()` bo'lsa u ham rozi bo'lsin (IKKI tekshiruv AND).
--
-- ⚠️ Nega ai_ctx_has_page() TO'G'RIDAN chaqirilmadi: u `PROVODKA_AI_KONTEKST.sql`
-- da va u fayl hali RUN qilinmagan bo'lishi mumkin — bog'liqlik qo'shsak
-- shu fayl RUN qilinganda 42883 bilan yiqilardi. Mantiq bir xil, fail-closed.
-- ⚠️ `perm_has_page()` YOLG'IZ ishlatilmaydi: uning tanasida
-- "kalit perm_pages() da yo'q bo'lsa true" (fail-OPEN) shoxi bor.
-- Shuning uchun avval `allowed_pages` o'zi tekshiriladi (fail-closed),
-- keyin AND bilan `perm_has_page`.
-- =====================================================================

create or replace function jurnal_page_ok(p_key text)
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

  -- Ikkinchi qavat (bo'lsa) — dinamik: funksiya yo'q bazada ham fayl ishlasin.
  if to_regprocedure('public.perm_has_page(text)') is not null then
    execute 'select public.perm_has_page($1)' into v_ok using p_key;
    return coalesce(v_ok, false);
  end if;

  return true;
end $fn$;

revoke all on function jurnal_page_ok(text) from public, anon, authenticated;

comment on function jurnal_page_ok(text) is
  'ICHKI: jurnal v2 RPClari uchun sahifa qorovuli (ai_ctx_has_page naqshi, fail-closed). Faqat DEFINER funksiyalar ichidan chaqiriladi.';


-- =====================================================================
-- 2-BO'LIM — jurnal_v2() — ro'yxat (sahifalangan), jsonb massiv
-- ---------------------------------------------------------------------
-- 🔴 ELEMENT SHAKLI eski `jurnal()` bilan AYNAN BIR XIL — klientdagi
-- render kodi (klass/accCell/maqsadHtml/lineRow) o'zgarmaydi:
--   {id, entry_date, description, source, is_deleted, deleted_by_name,
--    deleted_at, edited_at, edited_by_name, created_at,
--    lines:[{id, account_id, code, name, section, currency,
--            debit, credit, fc_amount}]}
--
-- 🔴 `lines` HAR DOIM to'liq qaytadi (hisobot_royxat dagi "faqat ko'p
--    satrli uchun" optimizatsiyasi BU YERDA QILINMAYDI): jurnal klienti
--    klass() ni har qator uchun satrlardan hisoblaydi — satrlarsiz hamma
--    yozuv "neytral" bo'lib ko'rinardi.
-- 🔴 `lines` ichida Dt (debit > 0) BIRINCHI — order by l.debit desc.
--
-- Tartib: entry_date desc, created_at desc (eski jurnal bilan bir xil).
-- =====================================================================

create or replace function jurnal_v2(
  p_from     date,
  p_to       date,
  p_accounts uuid[] default null,
  p_moddalar uuid[] default null,
  p_turlar   text[] default null,
  p_q        text   default null,
  p_limit    int    default 100,
  p_offset   int    default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_out jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  -- 🔴 SAHIFA QOROVULI: kassa ruxsati YETARLI EMAS (kassa_scope sukuti 'all').
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  -- ⚪ TARTIB BARQAROR bo'lishi shart: `created_at` teng bo'lsa (bir soniyada
  -- yozilgan ikki yozuv) p_offset bilan qator takrorlanardi yoki tushib
  -- qolardi. Shuning uchun oxirgi kalit — `id desc` (unique).
  select coalesce(jsonb_agg(to_jsonb(r) order by r.entry_date desc, r.created_at desc, r.id desc), '[]'::jsonb)
    into v_out
    from (
      select b.id, b.entry_date, b.description, b.source,
             b.is_deleted, b.deleted_by_name, b.deleted_at,
             b.edited_at, b.edited_by_name, b.created_at,
             (select coalesce(jsonb_agg(jsonb_build_object(
                       'id',         l.id,
                       'account_id', l.account_id,
                       'code',       a.code,
                       'name',       a.name,
                       'section',    a.section,
                       'currency',   a.currency,
                       'debit',      l.debit,
                       'credit',     l.credit,
                       'fc_amount',  l.fc_amount) order by l.debit desc), '[]'::jsonb)
                from entry_line l join accounts a on a.id = l.account_id
               where l.entry_id = b.id) as lines
        from jurnal_v2_baza(p_from, p_to, p_accounts, p_moddalar, p_turlar, p_q) b
       order by b.entry_date desc, b.created_at desc, b.id desc
       limit  greatest(coalesce(p_limit, 100), 1)
       offset greatest(coalesce(p_offset, 0), 0)
    ) r;

  return v_out;
end $fn$;

revoke all on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int) from public, anon;
grant execute on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int) to authenticated;

comment on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int) is
  'Jurnal v2 royxati: sana + hisob + xarajat moddasi + tur + qidiruv (hammasi AND, serverda). '
  'Javob shakli eski jurnal() bilan bir xil, lines har doim toliq (Dt birinchi). '
  'Sahifa qorovuli: jurnal_page_ok(''jurnal'') — ruxsat yoq bolsa 42501. Tartib: entry_date desc, created_at desc, id desc.';


-- =====================================================================
-- 3-BO'LIM — jurnal_v2_count() — filtrga tushgan yozuvlar soni
-- ---------------------------------------------------------------------
-- Sahifalash uchun (p_limit/p_offset'siz). Ro'yxat bilan AYNAN bir xil
-- filtrlar/ruxsat — shuning uchun "N tadan M ta" hech qachon chalkashmaydi.
-- =====================================================================

create or replace function jurnal_v2_count(
  p_from     date,
  p_to       date,
  p_accounts uuid[] default null,
  p_moddalar uuid[] default null,
  p_turlar   text[] default null,
  p_q        text   default null)
returns int
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_n int;
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  -- 🔴 SAHIFA QOROVULI: kassa ruxsati YETARLI EMAS (kassa_scope sukuti 'all').
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  select count(*)::int into v_n
    from jurnal_v2_baza(p_from, p_to, p_accounts, p_moddalar, p_turlar, p_q) b;

  return coalesce(v_n, 0);
end $fn$;

revoke all on function jurnal_v2_count(date, date, uuid[], uuid[], text[], text) from public, anon;
grant execute on function jurnal_v2_count(date, date, uuid[], uuid[], text[], text) to authenticated;

comment on function jurnal_v2_count(date, date, uuid[], uuid[], text[], text) is
  'Jurnal v2: filtrga tushgan yozuvlar soni (sahifalash uchun). Filtr/ruxsat royxat bilan bir xil, sahifa qorovuli ham (42501).';


-- =====================================================================
-- 4-BO'LIM — jurnal_dash() — dashboard, BITTA so'rov
-- ---------------------------------------------------------------------
-- Javob:
--   {
--     "jami":       {"soni": int, "summa": numeric},
--     "turlar":     [{"tur":"xarajat","soni":int,"summa":numeric}, ...],
--     "xarajat":    [{"account_id":uuid,"code":text,"name":text,
--                     "summa":numeric,"soni":int}, ...],
--     "chetlangan": {"soni": int, "ochirilgan": int}
--   }
--
-- 🔴 QAROR — DASHBOARD `p_turlar` GA BO'YSUNMAYDI (butun bo'lim shunga
--    qurilgan, "bug" deb tuzatib yubormang):
--    Dashboard — DAVR XULOSASI. U davr + `p_accounts` + `p_moddalar` + `p_q`
--    ga bo'ysunadi, TUR filtriga esa YO'Q. Tur — ro'yxat ko'rinishi tugmasi
--    (qaysi yozuvlarni ko'rsatish), xulosa filtri emas.
--    ⚠️ `p_turlar` imzoda QOLADI (klient uni yuboradi — moslik buzilmasin),
--    lekin e'tiborga OLINMAYDI.
--    Sabab (test topgan zidlik): agar `jami`/`xarajat` tur filtriga
--    bo'ysunib, `turlar` kesimi (u tabiatan hamma turni ko'rsatishi kerak)
--    bo'ysunmasa — Transfer tanlanganda bitta ekranda "Chiqim 1 000 000" va
--    "xarajat yozuvi yo'q" degan IKKI ZID raqam chiqardi. Endi uchala raqam
--    ham bitta to'plamdan (`bs`).
--    Mijoz matni ham shunday yozilsin: "Davr xulosasi" (tur tanlovi uni
--    o'zgartirmaydi).
--
-- `jami`    — davrdagi (tur filtrisiz) yozuvlar soni va summasi.
-- `turlar`  — HAMMA tur bo'yicha soni/summa (hisobot_xulosa naqshi),
--             chiplarda sanoq ko'rsatish uchun. Qolgan filtrlar
--             (sana/hisob/modda/qidiruv) ularga ham qo'llanadi.
-- `xarajat` — "nimaga qancha": accounts.type='xarajat' hisoblariga tushgan
--             DEBET summasi, faqat filtrga tushgan yozuvlardan.
--             summa desc (teng bo'lsa kod bo'yicha); summa = 0 chiqmaydi.
--
-- `chetlangan` — jamiga KIRMAGAN, lekin ro'yxatda KO'RINADIGAN yozuvlar:
--             `soni`       — aralash ko'p satrli (begona and n_lines > 2),
--             `ochirilgan` — o'chirilgan (is_deleted).
--             🔴 Bitta yozuv ikkalasiga tushsa faqat `ochirilgan` da
--             sanaladi (bir marta) — invariant buzilmasin.
--             Cheklovsiz (admin) userda `soni` har doim 0.
--
-- 🔴 AGREGAT FAIL-CLOSED — jami / turlar / xarajat UCHALASI ham bir xil
--    `bs` to'plamidan: `is_deleted = false and not (begona and n_lines > 2)`
--    (tur filtrisiz — yuqoridagi qarorga qara).
--    (Avval `xarajat` o'chirilganni chiqarib tashlardi, `jami`/`turlar` esa
--    qo'shib yuborardi — o'chirilgan 10 mln jamida ko'rinib, breakdown'da
--    yo'q edi; endi izchil.)
--    Sabab: yozuv "kamida bitta satri meniki" bo'lsa ro'yxatga tushadi,
--    lekin summa BUTUN yozuvniki — ko'p satrli (professional) yozuvda
--    begona pul aynan shu summa orqali sizardi. Pro-rata yo'q (taxminiy
--    raqam berardi). ⚠️ Natijada dashboard jami ro'yxatdagi yozuvlar
--    jamisidan kichik bo'lishi MUMKIN — bu xato emas, `chetlangan` uni
--    ochiq ko'rsatadi. INVARIANT (🔴 p_turlar := NULL bilan):
--      jami.soni + chetlangan.soni + chetlangan.ochirilgan
--        = jurnal_v2_count(p_from, p_to, p_accounts, p_moddalar, null, p_q)
--    Tur tanlangan bo'lsa RO'YXAT soni (jurnal_v2_count p_turlar bilan)
--    bundan KICHIK bo'ladi — bu normal, dashboard davr xulosasi.
--
-- 🔴 Ruxsat/filtrlar jurnal_v2 bilan AYNAN bir xil. perm_view_pul_ids()
--    bo'sh massiv qaytarsa baza nol qator beradi → jami 0, turlar [],
--    xarajat [], chetlangan 0 (hech qanday summa sizmaydi).
-- ⚠️ Baza FAQAT BIR MARTA chaqiriladi (CTE `b`), keyin turlar filtri
--    xotirada qo'llanadi — dashboard bitta so'rov bo'lib qoladi.
-- =====================================================================

create or replace function jurnal_dash(
  p_from     date,
  p_to       date,
  p_accounts uuid[] default null,
  p_moddalar uuid[] default null,
  p_turlar   text[] default null,
  p_q        text   default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_out jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  -- 🔴 SAHIFA QOROVULI: kassa ruxsati YETARLI EMAS (kassa_scope sukuti 'all').
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  with b as materialized (
    -- 🔴 p_turlar ATAYLAB null: dashboard davr xulosasi, tur filtriga
    -- bo'ysunmaydi (parametr imzoda qoladi, lekin ishlatilmaydi).
    select * from jurnal_v2_baza(p_from, p_to, p_accounts, p_moddalar, null, p_q)
  ),
  -- 🔴 AGREGAT MANBASI — FAIL-CLOSED, IKKI chetlash (ikkalasi ham UCHALA
  -- raqamga birdek qo'llanadi — jami, turlar, xarajat izchil bo'lsin):
  --   1) O'CHIRILGAN yozuv (is_deleted) — pul harakati emas.
  --   2) ARALASH yozuv: `begona and n_lines > 2` — ichida menga ruxsat
  --      berilmagan pul hisobi bor KO'P SATRLI yozuv (summa butun yozuvniki).
  -- ⚠️ `n_lines > 2` sharti MAJBURIY: 2 satrli yozuvda sizadigan narsa yo'q
  --    (Dt=Kt=bitta summa, yozuv ro'yxatda ko'rinadi). Usiz filial kassiri
  --    uchun markazga jo'natilgan HAR transfer dashboarddan tushib qolardi.
  -- Cheklovsiz (admin) userda begona = false → chetlash faqat o'chirilganlar.
  --
  -- 🔴 `p_turlar` BU YERDA QO'LLANMAYDI (qaror, pastdagi sarlavha izohiga qara):
  -- butun dashboard — DAVR XULOSASI. Shuning uchun jami / turlar / xarajat
  -- UCHALASI ham bitta `bs` to'plamidan oziqlanadi — bitta ekranda ikki zid
  -- raqam chiqishi mumkin emas.
  bs as (select * from b
          where coalesce(b.is_deleted, false) = false
            and not (b.begona and b.n_lines > 2)),
  j as (
    select count(*)::int as soni, coalesce(sum(bs.summa), 0)::numeric as summa from bs
  ),
  ch as (     -- chetlanganlar (UI shuni ochiq yozadi — jimgina kam ko'rsatilmasin)
    -- 🔴 Bitta yozuv ikkala sababga tushsa FAQAT `ochirilgan` da sanaladi
    -- (bir marta) — invariant buzilmasin:
    --   jami.soni + chetlangan.soni + chetlangan.ochirilgan
    --     = jurnal_v2_count(p_from, p_to, p_accounts, p_moddalar, NULL, p_q)
    select (count(*) filter (where coalesce(b.is_deleted, false) = false
                               and b.begona and b.n_lines > 2))::int as soni,
           (count(*) filter (where coalesce(b.is_deleted, false)))::int as ochirilgan
      from b
  ),
  t as (
    select bs.tur, count(*)::int as soni, coalesce(sum(bs.summa), 0)::numeric as summa
      from bs group by bs.tur
  ),
  x as (
    select a.id as account_id, a.code, a.name,
           coalesce(sum(l.debit), 0)::numeric   as summa,
           count(distinct l.entry_id)::int      as soni
      from bs
      join entry_line l on l.entry_id = bs.id and l.debit > 0
      join accounts   a on a.id = l.account_id
     where a.type = 'xarajat'
       -- o'chirilgan va aralash yozuvlar `bs` da allaqachon chiqarilgan
     group by a.id, a.code, a.name
    having coalesce(sum(l.debit), 0) > 0
  )
  select jsonb_build_object(
           'jami',       (select to_jsonb(j) from j),
           -- ⚪ tartib barqaror bo'lsin: summa teng bo'lsa tur/kod bo'yicha
           'turlar',     (select coalesce(jsonb_agg(to_jsonb(t) order by t.summa desc, t.tur), '[]'::jsonb) from t),
           'xarajat',    (select coalesce(jsonb_agg(to_jsonb(x) order by x.summa desc, x.code), '[]'::jsonb) from x),
           'chetlangan', (select to_jsonb(ch) from ch)
         )
    into v_out;

  return coalesce(v_out, jsonb_build_object(
    'jami',       jsonb_build_object('soni', 0, 'summa', 0),
    'turlar',     '[]'::jsonb,
    'xarajat',    '[]'::jsonb,
    'chetlangan', jsonb_build_object('soni', 0, 'ochirilgan', 0)));
end $fn$;

revoke all on function jurnal_dash(date, date, uuid[], uuid[], text[], text) from public, anon;
grant execute on function jurnal_dash(date, date, uuid[], uuid[], text[], text) to authenticated;

comment on function jurnal_dash(date, date, uuid[], uuid[], text[], text) is
  'Jurnal v2 dashboard (DAVR XULOSASI): jami + tur kesimi (hamma tur) + xarajat moddalari kesimi + chetlangan {soni, ochirilgan}. '
  'Sahifa qorovuli: jurnal_page_ok(''jurnal''). '
  '🔴 p_turlar IMZODA QOLADI, lekin ETIBORGA OLINMAYDI: tur filtri ROYXATGA tegishli, XULOSAGA emas '
  '(aks holda tur tanlanganda turlar kesimi bilan jami bir ekranda zid raqam berardi). '
  'Dashboard davr + p_accounts + p_moddalar + p_q ga boysunadi. '
  'AGREGAT FAIL-CLOSED: ochirilgan yozuv va aralash kop satrli yozuv (begona pul satri bor, n_lines>2) '
  'jamiga KIRMAYDI, royxatda esa korinadi — shuning uchun dashboard jami royxat jamisidan kichik bolishi '
  'MUMKIN va bu XATO EMAS. Invariant: jami.soni + chetlangan.soni + chetlangan.ochirilgan = jurnal_v2_count(...).';


-- =====================================================================
-- 5-BO'LIM — accounts.filial_majburiy + set_modda_flag('filial')
-- ---------------------------------------------------------------------
-- Xarajat moddasi uchun 4-bayroq: filial(lar) tanlanishi majburiymi.
-- chek_majburiy / izoh_majburiy / davr_majburiy naqshi (PROVODKA_V6.sql).
-- Default false — mavjud moddalar o'zgarmaydi.
--
-- 🔴 set_modda_flag IMZOSI O'ZGARMAYDI (uuid, text, boolean) — sozlama.html
--    (prod) va sozlama-dev.html bir xil chaqiradi, faqat yangi p_flag
--    qiymati qo'shildi. Eski 'chek'|'izoh'|'davr' shoxlari TEGILMAGAN.
--    Dinamik SQL yo'q — ustun nomi whitelist'dan (static UPDATE).
-- =====================================================================

alter table accounts
  add column if not exists filial_majburiy boolean not null default false;

comment on column accounts.filial_majburiy is
  'Xarajat moddasi: filial(lar) tanlash majburiymi (hodim/professional yozuvida tekshiriladi).';

create or replace function set_modda_flag(p_account uuid, p_flag text, p_bool boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Faqat admin' using errcode = '42501';
  end if;
  if p_flag = 'chek' then
    update accounts set chek_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'izoh' then
    update accounts set izoh_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'davr' then
    update accounts set davr_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'filial' then
    update accounts set filial_majburiy = coalesce(p_bool, false) where id = p_account;
  else
    raise exception 'Nomalum bayroq';
  end if;
end $$;

revoke all on function set_modda_flag(uuid, text, boolean) from public, anon;
grant execute on function set_modda_flag(uuid, text, boolean) to authenticated;

comment on function set_modda_flag(uuid, text, boolean) is
  'Admin: xarajat moddasi bayrogi (chek|izoh|davr|filial) yoqadi yoki ochiradi.';


-- =====================================================================
-- PostgREST sxemasini yangilash (busiz yangi RPC 404 beradi)
-- =====================================================================

notify pgrst, 'reload schema';


-- =====================================================================
-- TEKSHIRUV — anonim DO bloki ISHLATILMAYDI (Supabase editorida 42P01 beradi).
-- Quyidagi select'lar hamma ustunda `true` qaytarishi kerak.
-- =====================================================================

-- 1) Funksiyalar o'rnida turibdimi
select to_regprocedure('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)')  is not null as jurnal_v2_baza_ok,
       to_regprocedure('public.jurnal_v2(date,date,uuid[],uuid[],text[],text,int,int)') is not null as jurnal_v2_ok,
       to_regprocedure('public.jurnal_v2_count(date,date,uuid[],uuid[],text[],text)') is not null as jurnal_v2_count_ok,
       to_regprocedure('public.jurnal_dash(date,date,uuid[],uuid[],text[],text)')     is not null as jurnal_dash_ok,
       to_regprocedure('public.set_modda_flag(uuid,text,boolean)')                    is not null as set_modda_flag_ok,
       to_regprocedure('public.perm_view_pul_ids()')                                  is not null as perm_view_pul_ids_ok,
       -- eski jurnal() / jurnal_count() TEGILMAGAN (imzoga bog'lanmasdan tekshiramiz)
       exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'jurnal')                  as eski_jurnal_saqlandi,
       exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'jurnal_count')            as eski_jurnal_count_saqlandi;

-- 2) Yangi ustun qo'shildimi
select exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'accounts'
                  and column_name = 'filial_majburiy') as filial_majburiy_ok;

-- 3) ICHKI funksiya yopiqmi (authenticated CHAQIRA OLMASLIGI kerak → false)
select has_function_privilege('authenticated',
         'public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)', 'execute') as baza_ochiq_BULMASIN,
       has_function_privilege('authenticated',
         'public.jurnal_v2(date,date,uuid[],uuid[],text[],text,int,int)', 'execute') as jurnal_v2_ochiq,
       has_function_privilege('authenticated',
         'public.jurnal_dash(date,date,uuid[],uuid[],text[],text)', 'execute') as dash_ochiq;

-- 4) Tirik ma'lumotda tez sinov (oxirgi 30 kun) — xato bermasligi kerak.
--    Admin sifatida RUN qilinsa hamma yozuv, cheklangan user sifatida faqat
--    o'z kassalari qatnashgani ko'rinadi.
select jsonb_array_length(jurnal_v2((now() at time zone 'Asia/Tashkent')::date - 30,
                                    (now() at time zone 'Asia/Tashkent')::date,
                                    null, null, null, null, 5, 0)) as royxat_soni,
       jurnal_v2_count((now() at time zone 'Asia/Tashkent')::date - 30,
                       (now() at time zone 'Asia/Tashkent')::date)  as jami_soni,
       jurnal_dash((now() at time zone 'Asia/Tashkent')::date - 30,
                   (now() at time zone 'Asia/Tashkent')::date)      as dash;

-- 5) MUVOFIQLIK INVARIANTI (HAR QANDAY user uchun true bo'lishi shart):
--      jami.soni + chetlangan.soni + chetlangan.ochirilgan
--        = jurnal_v2_count(p_from, p_to, p_accounts, p_moddalar, NULL, p_q)
--    🔴 `jurnal_v2_count` SHU YERDA p_turlar := NULL bilan chaqiriladi —
--    dashboard tur filtriga bo'ysunmaydi (davr xulosasi). Tur tanlangan
--    bo'lsa RO'YXAT soni bundan kichik bo'ladi va bu NORMAL.
--    🔴 `jami.soni` ning O'ZI count'ga TENG BO'LMASLIGI mumkin va bu XATO EMAS:
--      • o'chirilgan yozuvlar ro'yxatda ko'rinadi, agregatga kirmaydi;
--      • cheklangan userda aralash ko'p satrli yozuv ham shunday.
--    Admin bazasida ham `ochirilgan` > 0 bo'lishi normal (soft-delete).
select (d -> 'jami'       ->> 'soni')::int                             as jami_soni,
       (d -> 'chetlangan' ->> 'soni')::int                             as chetlangan_aralash,
       (d -> 'chetlangan' ->> 'ochirilgan')::int                       as chetlangan_ochirilgan,
       n                                                               as jurnal_v2_count,
       ((d -> 'jami' ->> 'soni')::int
        + (d -> 'chetlangan' ->> 'soni')::int
        + (d -> 'chetlangan' ->> 'ochirilgan')::int) = n               as dash_count_mos
  from (
    select jurnal_dash((now() at time zone 'Asia/Tashkent')::date - 30,
                       (now() at time zone 'Asia/Tashkent')::date) as d,
           -- 🔴 p_turlar ATAYLAB null (nomlangan argument bilan ochiq yozildi):
           -- dashboard tur filtriga bo'ysunmaydi, invariant ham shunga qurilgan.
           jurnal_v2_count(p_from   => (now() at time zone 'Asia/Tashkent')::date - 30,
                           p_to     => (now() at time zone 'Asia/Tashkent')::date,
                           p_turlar => null) as n
  ) q;

-- 6) Yangi `begona` ustuni + sahifa qorovuli o'rnidami.
select exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'jurnal_v2_baza'
     and 'begona' = any(p.proargnames)
) as begona_ustuni_bor,
to_regprocedure('public.jurnal_page_ok(text)') is not null as qorovul_bor,
has_function_privilege('authenticated', 'public.jurnal_page_ok(text)', 'execute')
  as qorovul_ochiq_BULMASIN,
-- Uchala ochiq RPC tanasida qorovul chaqiruvi bormi (matn bo'yicha tekshiruv)
(select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('jurnal_v2','jurnal_v2_count','jurnal_dash')
    and p.prosrc like '%jurnal_page_ok(''jurnal'')%') as qorovulli_rpc_soni_3_bulsin;
