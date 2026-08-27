-- =====================================================================
--  PROVODKA_JURNAL_KIRITILGAN.sql — Jurnal filtri/tartibi: KIRITILGAN
--  VAQT (entry.created_at) bo'yicha, entry_date (hisob sanasi) EMAS.
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  MUAMMO (prod bug): hodim TaskFix/professional/kirim-chiqim orqali
--  xarajat kiritganda "hisob sanasi" (entry_date) ni qo'lda o'zgacha
--  qo'yishi mumkin (masalan bugun 27.08 kiritib, sanani 25.08 qo'yadi).
--  jurnal-dev.html "Bugun" filtri entry_date bo'yicha ishlaganda bu yozuv
--  bugungi ro'yxatda UMUMAN ko'rinmay qoladi — hodim/admin uni "yo'qolgan"
--  deb o'ylaydi.
--
--  QAROR (Asilbek): JURNAL sahifasi (ro'yxat, sanoq, dashboard, ijrochilar,
--  davr xulosasi) endi qachon KIRITILGANI (entry.created_at, Toshkent
--  vaqti UTC+5) bo'yicha filtrlanadi va tartiblanadi. `p_from`/`p_to` sana
--  maydonlari o'zgarmaydi (klient hamon kalendar sanasini yuboradi), lekin
--  ular endi "shu kunlarda YOZILGAN" degani, "shu kunlarga OID QILINGAN"
--  emas.
--
--  🔴 HISOBOTLAR (balans/pnl/cashflow/pul_qoldiq) TEGILMAYDI — ular
--     entry_date (buxgalteriya davri) bo'yicha qoladi. Bu fayl FAQAT
--     jurnal_v2* + jurnal_qoldiq zanjirini o'zgartiradi.
--
--  NIMA O'ZGARADI (hammasi ADDITIVE — `create or replace`, imzolar bir xil,
--  faqat `jurnal_v2_baza` uchun `drop`+`create` — ijrochi.sql'dagi ANIQ
--  o'sha naqsh, chunki `returns table(...)` bor):
--    1) jurnal_v2_baza  — sana predikati entry_date -> created_at (sargable
--       oraliq, `Asia/Tashkent`).
--    2) jurnal_v2       — ikkala `order by` entry_date/created_at/id ->
--       created_at/id (tartib ham kiritilgan vaqt bo'yicha).
--    3) pul_qoldiq_kassa_kiritilgan (YANGI funksiya, eski pul_qoldiq_kassa
--       ga TEGILMAYDI) + jurnal_qoldiq (create or replace, o'sha imzo) —
--       davr boshi/oxiri endi "shu paytgacha KIRITILGAN yozuvlar" qoldig'i.
--    jurnal_v2_count, jurnal_dash, jurnal_ijrochilar — hech biri o'zgarmadi,
--    hammasi jurnal_v2_baza orqali AVTOMAT yangi semantikaga o'tadi
--    (ular to'g'ridan-to'g'ri entry_date/created_at bilan ishlamaydi).
--
--  🔴 PROD TA'SIRI: Supabase bitta — dev va prod bitta bazaga ulanadi.
--     Bu fayl RUN bo'lgan zahoti `jurnal.html` (PROD) ham darrov yangi
--     semantikaga o'tadi (baza umumiy). Bu ATAYLAB — bug ikkala tomonda
--     ham bor edi, tuzatish ham ikkalasiga baravar tegishi kerak.
--
--  SQL ADDITIVE: mavjud ustun/jadval o'chirilmaydi. `jurnal_v2_baza`/
--  `jurnal_v2` imzosi (argument ro'yxati, returns shakli) O'ZGARMAYDI —
--  faqat tana ichidagi predikat/tartib. `pul_qoldiq_kassa`ning O'ZIGA
--  tegilmagan (cashflow.html shundan foydalanishda davom etadi).
-- =====================================================================


-- #####################################################################
-- ##  0. OLD SHART — PROVODKA_IJROCHI.sql RUN QILINGANMI?             ##
-- #####################################################################
-- 🔴 MUHIM: jurnal_v2 ning 9-argumentli (p_ijrochi bilan) versiyasi YO'Q
--    bo'lsa, bu faylda uni "create or replace" bilan yaratish ESKI
--    (masalan 8-argumentli) versiya bilan yonma-yon OVERLOAD hosil
--    qiladi -> PostgREST "more than one function matches" (300) beradi.
--    Shuning uchun bu yerda TO'XTAYMIZ, agar old shart yo'q bo'lsa.
do $do$
begin
  if to_regprocedure(
       'public.jurnal_v2(date,date,uuid[],uuid[],text[],text,int,int,text)'
     ) is null then
    raise exception
      'Old shart yoq: PROVODKA_IJROCHI.sql avval RUN qilinishi kerak '
      '(jurnal_v2(date,date,uuid[],uuid[],text[],text,int,int,text) topilmadi). '
      'Bu faylni RUN qilish hozircha bekor qilindi.'
      using errcode = '55000';
  end if;
end
$do$;


-- #####################################################################
-- ##  1. jurnal_v2_baza() — sana predikati: created_at (KIRITILGAN)   ##
-- #####################################################################
-- Manba: PROVODKA_IJROCHI.sql (~440-602 qatorlar), tana VERBATIM ko'chirildi.
-- YAGONA farq — quyidagi sharh ichida ko'rsatilgan bitta predikat qatori:
--   ESKI:  and en.entry_date >= p_from and en.entry_date <= p_to
--   YANGI: and en.created_at >= (p_from::timestamp at time zone 'Asia/Tashkent')
--          and en.created_at <  ((p_to + 1)::timestamp at time zone 'Asia/Tashkent')
-- `p_to + 1` (yarim ochiq oraliq) ishlatilgan — `::date`/`date_trunc` cast
-- bilan emas, ya'ni `created_at` ustunidagi indeks bo'lsa ham SARGABLE
-- qoladi (ustunga funksiya qo'llanmaydi, faqat qiymatga).
--
-- 🔴 RUXSAT (fail-closed) va 🔴 `is_deleted` filtri YO'Qligi (jurnal
--    o'chirilgan yozuvni ham ko'rsatadi) — ASL FAYLDAGIDEK, o'zgarmagan.
-- 🔴 KO'RSATILADIGAN ISM (`ijrochi`) bu bazada hisoblanmaydi — chaqiruvchida
--    (`jurnal_v2` LIMIT dan keyin, `jurnal_ijrochilar` GROUP BY dan keyin).
-- ---------------------------------------------------------------------

-- 🔴 DROP shu CREATE bilan AJRALMAS: imzo (returns table) o'zgargani uchun
--    `create or replace` yolg'iz 42P13 beradi. Faylni bo'lib RUN qilsangiz ham
--    bu ikki qator BIRGA ketadi — drop o'tkazib yuborilishi mumkin emas.
drop function if exists public.jurnal_v2_baza(date, date, uuid[], uuid[], text[], text);
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
  begona boolean,
  ijrochi_raw text          -- 🔴 faqat XOM kalit; ism chaqiruvchida (yuqoridagi izoh)
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
  --   p_moddalar = '{}' → "filtr yo'q";  p_accounts / p_turlar = '{}' → HECH NARSA.
  if p_moddalar is null or array_length(p_moddalar, 1) is null then
    v_moddalar := null;
  else
    v_moddalar := p_moddalar;
  end if;

  -- Qidiruv: LIKE metabelgilari tozalanadi.
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
           -- 🔴 IJROCHI — XOM QIYMAT, USTUN TURIGA BOG'LANMAGAN HOLDA.
           --    `to_jsonb(en) ->> 'created_by'`: uuid ustunda ham, text
           --    ustunda ham matn qaytadi; ustun umuman yo'q bo'lsa null
           --    (so'rov yiqilmaydi). Cast QILINMAYDI — uni 2-BO'LIMdagi ism
           --    funksiyasi shartli bajaradi (PROVODKA_HODIM_NOTIFY.sql:564-570 naqshi).
           nullif(btrim(coalesce(to_jsonb(en) ->> 'created_by', '')), '') as e_by,
           -- 🔴 ARALASH YOZUV BAYROG'I (fail-closed agregat uchun) — asl
           --    fayldagidek. Shart perm_view_pul_ids() bilan AYNAN bir xil
           --    bo'lishi SHART (type='aktiv' + code like '5%' + xarajat_guruh emas).
           (v_perm is not null and exists (
              select 1 from entry_line el join accounts ab on ab.id = el.account_id
               where el.entry_id = en.id
                 and ab.type = 'aktiv' and ab.code like '5%'
                 and ab.kassa_turi is distinct from 'xarajat_guruh'
                 and not (el.account_id = any(v_perm)))) as e_begona
      from entry en
     where en.status = 'posted'
       -- 🔴 is_deleted filtri ATAYLAB YO'Q (jurnal o'chirilganini ham ko'rsatadi)
       -- 🔴 SANA -> KIRITILGAN VAQT (2026-08-27 qaror): endi entry_date EMAS,
       --    en.created_at (Toshkent, UTC+5) bo'yicha filtrlanadi. Yarim ochiq
       --    oraliq [p_from 00:00, p_to+1 00:00) — sargable, ustunga cast yo'q.
       and en.created_at >= (p_from::timestamp at time zone 'Asia/Tashkent')
       and en.created_at <  ((p_to + 1)::timestamp at time zone 'Asia/Tashkent')
       and (p_accounts is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(p_accounts)))
       and (v_moddalar is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(v_moddalar)
                and el.debit > 0))
       -- 🔴 RUXSAT (server tomonda, klient filtridan MUSTAQIL)
       and (v_perm is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(v_perm)))
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
         t.n::int, t.s::numeric, t.tt::text, t.e_begona::boolean,
         -- 🔴 XOM kalit. Ism funksiyasi SHU YERDA CHAQIRILMAYDI (yuqoridagi izoh):
         -- u chaqiruvchida — jurnal_v2 da LIMIT dan keyin, royxatda group by dan keyin.
         t.e_by::text
    from t
   where p_turlar is null or t.tt = any(p_turlar);
end $fn$;

revoke all on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text) from public, anon, authenticated;

comment on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text) is
  'ICHKI: jurnal v2 uchun filtrlangan yozuvlar + tur tasnifi + IJROCHI XOM KALITI (ijrochi_raw). '
  'Korsatiladigan ism ATAYLAB bu yerda hisoblanmaydi (tezlik): jurnal_v2 uni LIMIT dan keyin, '
  'jurnal_ijrochilar group by dan keyin hisoblaydi; count/dash umuman hisoblamaydi. '
  'Ruxsat shu yerda majburlanadi. Faqat jurnal_v2* wrapperlari chaqiradi. '
  '🔴 2026-08-27: sana filtri endi entry_date (hisob sanasi) emas, en.created_at '
  '(KIRITILGAN vaqt, Asia/Tashkent) boyicha — PROVODKA_JURNAL_KIRITILGAN.sql. '
  'Hisobotlar (balans/pnl/cashflow) bunga tegishli emas, ular entry_date da qoladi.';


-- #####################################################################
-- ##  2. jurnal_v2() — tartib: created_at (KIRITILGAN)                ##
-- #####################################################################
-- Manba: PROVODKA_IJROCHI.sql (~628-708 qatorlar), tana VERBATIM ko'chirildi.
-- Imzo/`returns` O'ZGARMAGANI uchun faqat `create or replace` (drop shart
-- emas). YAGONA farq — ikkala `order by` qatorida `entry_date desc,` olib
-- tashlandi (kiritilgan yozuvlar orasida saralash endi faqat vaqt+id bilan).
-- ---------------------------------------------------------------------

create or replace function jurnal_v2(
  p_from     date,
  p_to       date,
  p_accounts uuid[] default null,
  p_moddalar uuid[] default null,
  p_turlar   text[] default null,
  p_q        text   default null,
  p_limit    int    default 100,
  p_offset   int    default 0,
  p_ijrochi  text   default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_out jsonb;
  v_ij  text := nullif(btrim(coalesce(p_ijrochi, '')), '');
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  -- 🔴 SAHIFA QOROVULI: kassa ruxsati YETARLI EMAS (kassa_scope sukuti 'all').
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  -- 🔴 2026-08-27: tartib entry_date EMAS, created_at (KIRITILGAN) boyicha.
  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc, r.id desc), '[]'::jsonb)
    into v_out
    from (
      -- TASHQI qavat: ism FAQAT shu yerda — LIMIT/OFFSET allaqachon qo'llangan,
      -- ya'ni `ijrochi_nomi()` ko'pi bilan `p_limit` marta chaqiriladi.
      select p.*,
             ijrochi_nomi(p.ijrochi_raw) as ijrochi
        from (
          -- ICHKI qavat: filtr + tartib + sahifalash. Faqat XOM kalit.
          select b.id, b.entry_date, b.description, b.source,
                 b.is_deleted, b.deleted_by_name, b.deleted_at,
                 b.edited_at, b.edited_by_name, b.created_at,
                 -- YANGI kalit (qo'shilishi eski klientni sindirmaydi)
                 b.ijrochi_raw,
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
            -- 🔴 IJROCHI FILTRI — xom qiymat bo'yicha aniq moslik, '(bosh)' sentinel
           where v_ij is null
              or (v_ij = '(bosh)' and b.ijrochi_raw is null)
              or b.ijrochi_raw = v_ij
           order by b.created_at desc, b.id desc
           limit  greatest(coalesce(p_limit, 100), 1)
           offset greatest(coalesce(p_offset, 0), 0)
        ) p
    ) r;

  return v_out;
end $fn$;

revoke all on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text) from public, anon;
grant execute on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text) to authenticated;

comment on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text) is
  'Jurnal v2 royxati: sana + hisob + xarajat moddasi + tur + qidiruv + IJROCHI (hammasi AND, serverda). '
  'Javob shakli eski jurnal() bilan bir xil + ijrochi/ijrochi_raw kalitlari; lines har doim toliq (Dt birinchi). '
  'p_ijrochi — XOM created_by boyicha aniq moslik (ismga emas), ''(bosh)'' = created_by yoq yozuvlar. '
  'TEZLIK: ijrochi_nomi() LIMIT/OFFSET dan KEYIN chaqiriladi (kopi bilan p_limit marta). '
  'Sahifa qorovuli: jurnal_page_ok(''jurnal''). '
  '🔴 2026-08-27: p_from/p_to endi KIRITILGAN VAQT (created_at, entry_date EMAS) boyicha filtrlanadi va '
  'tartiblanadi (created_at desc, id desc) — PROVODKA_JURNAL_KIRITILGAN.sql.';


-- #####################################################################
-- ##  3. jurnal_qoldiq() davr xulosasi — davr boshi/oxiri: KIRITILGAN ##
-- #####################################################################
-- `jurnal_qoldiq` (PROVODKA_JURNAL_QOLDIQ.sql) qoldiqni `pul_qoldiq_kassa()`
-- (entry_date bo'yicha, cashflow bilan bitta manba) orqali oladi, oqimni esa
-- `jurnal_v2_baza()` orqali (yuqorida endi created_at bo'yicha). Ikkalasi
-- bittasi entry_date, ikkinchisi created_at bo'lsa zinapoya tenglamasi
-- (boshi + kirim − chiqim = oxiri) buziladi. Yechim: qoldiq uchun ham
-- KIRITILGAN vaqtga mos YANGI yordamchi funksiya — eski `pul_qoldiq_kassa`
-- ga (cashflow.html hamon undan foydalanadi) TEGILMAYDI.
--
-- 🔴 `p_kassa is null` (bitta kassa emas, "hammasi") holatida eski
--    `pul_qoldiq_kassa` `pul_qoldiq(p_date, null)` ga delegat qiladi —
--    o'sha funksiya bu repoda .sql fayl sifatida yo'q (Supabase'da to'g'ridan
--    yaratilgan, entry_date bilan) va uni bilmasdan qayta yozish xavfli.
--    Shu sabab `pul_qoldiq_kassa_kiritilgan` "hammasi" holatini o'zi,
--    mustaqil hisoblaydi (`accounts.section='pul'`, `xarajat_guruh` chiqarib
--    tashlanadi — jurnal_qoldiq/jurnal_v2_baza dagi "pul" ta'rifi bilan bir xil).
-- ---------------------------------------------------------------------

-- Old shart: eski `pul_qoldiq_kassa` (kassa_oila) borligini tekshiramiz —
-- bola-hisob oilasini yig'ish mantig'ini undan olamiz (nusxalaymiz), lekin
-- o'zini chaqirmaymiz (u entry_date bilan ishlaydi).
do $do$
begin
  if to_regprocedure('public.kassa_oila(uuid)') is null then
    raise exception
      'Old shart yoq: kassa_oila(uuid) topilmadi (PROVODKA_CASHFLOW_FIX.sql). '
      'Bu faylni RUN qilish hozircha bekor qilindi.'
      using errcode = '55000';
  end if;
end
$do$;

create or replace function pul_qoldiq_kassa_kiritilgan(p_date date, p_kassa uuid default null)
returns numeric
language plpgsql
stable
security invoker
set search_path = public
as $fn$
declare
  v_ids  uuid[];
  v_sum  numeric;
  v_ceil timestamptz := (p_date + 1)::timestamp at time zone 'Asia/Tashkent';
begin
  if p_kassa is null then
    -- "Hammasi" — barcha pul hisoblari (xarajat_guruh konteyner bundan
    -- mustasno), AYNAN jurnal_qoldiq/jurnal_v2_baza dagi "pul" ta'rifi bilan.
    select coalesce(sum(l.debit - l.credit), 0)
      into v_sum
      from entry_line l
      join entry    e on e.id = l.entry_id
      join accounts a on a.id = l.account_id
     where e.status = 'posted'
       and e.is_deleted = false
       and a.section = 'pul'
       and a.kassa_turi is distinct from 'xarajat_guruh'
       and e.created_at < v_ceil;

    return coalesce(v_sum, 0);
  end if;

  v_ids := kassa_oila(p_kassa);
  if v_ids is null then
    return 0;
  end if;

  select coalesce(sum(l.debit - l.credit), 0)
    into v_sum
    from entry_line l
    join entry e on e.id = l.entry_id
   where l.account_id = any(v_ids)
     and e.status = 'posted'
     and e.is_deleted = false
     and e.created_at < v_ceil;

  return coalesce(v_sum, 0);
end $fn$;

revoke all on function pul_qoldiq_kassa_kiritilgan(date, uuid) from public, anon;
grant execute on function pul_qoldiq_kassa_kiritilgan(date, uuid) to authenticated;

comment on function pul_qoldiq_kassa_kiritilgan(date, uuid) is
  'pul_qoldiq_kassa() ning KIRITILGAN VAQT (created_at, Asia/Tashkent) nusxasi — faqat jurnal_qoldiq() '
  'ichida ishlatiladi. Eski pul_qoldiq_kassa()/pul_qoldiq() (entry_date, cashflow.html) ga TEGILMAGAN. '
  'p_kassa null bo''lsa mustaqil hisoblaydi (accounts.section=''pul'', xarajat_guruh chiqarib tashlanadi).';


-- 🔴 DROP KERAK EMAS: `jurnal_qoldiq(date,date,uuid[])` imzosi/`returns jsonb`
--    o'zgarmaydi — faqat tana ichidagi qoldiq chaqiruvi almashtiriladi.
-- Manba: PROVODKA_JURNAL_QOLDIQ.sql (~167-355 qatorlar), tana VERBATIM
-- ko'chirildi. Farqlar: (a) old-shart tekshiruvi yangi funksiya nomiga,
-- (b) 4 ta `pul_qoldiq_kassa(` chaqiruvi -> `pul_qoldiq_kassa_kiritilgan(`.
create or replace function jurnal_qoldiq(
  p_from     date,
  p_to       date,
  p_accounts uuid[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  c_eps    constant numeric := 1;      -- 1 so'm — yaxlitlash bardoshi
  c_max    constant int     := 150;    -- ildizlar chegarasi (tezlik qorovuli)
  v_perm   uuid[];
  v_scope  uuid[];
  v_roots  uuid[];
  v_fam    uuid[];
  v_hammasi boolean := false;
  v_open   numeric := 0;
  v_close  numeric := 0;
  v_kirim  numeric := 0;
  v_chiqim numeric := 0;
  v_tr     numeric := 0;
  v_trnet  numeric := 0;
  v_boshqa numeric := 0;
  v_chet   numeric := 0;
  v_farq   numeric := 0;
  v_mos    boolean := false;
  v_sabab  text    := null;
  v_n      int     := 0;
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;

  -- 🔴 SAHIFA QOROVULI — uchala jurnal RPC si bilan AYNAN bir xil naqsh.
  --    Kassa ruxsati YETARLI EMAS (kassa_scope sukuti 'all').
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  -- Old shart: bu fayl RUN qilinmagan bo'lsa jimgina "mos emas" qaytariladi
  -- (klient zinapoyani chizmaydi, jurnal ishlayveradi). Xato ko'tarilmaydi.
  if to_regprocedure('public.pul_qoldiq_kassa_kiritilgan(date,uuid)') is null then
    return jsonb_build_object('mos', false, 'sabab', 'pul_qoldiq_kassa_kiritilgan yoq',
                              'kassa_soni', 0);
  end if;

  v_perm := perm_view_pul_ids();               -- null = cheklovsiz (admin)

  -- 1–2) Tanlov + ruxsat kesishmasi
  select array_agg(a.id) into v_scope
    from accounts a
   where a.section = 'pul'
     and a.kassa_turi is distinct from 'xarajat_guruh'
     and (p_accounts is null or a.id = any(p_accounts))
     and (v_perm     is null or a.id = any(v_perm));

  if v_scope is null or array_length(v_scope, 1) is null then
    return jsonb_build_object('mos', false, 'sabab', 'qamrovda pul hisobi yoq',
                              'kassa_soni', 0);
  end if;

  v_hammasi := (p_accounts is null and v_perm is null);

  if v_hammasi then
    -- 4) HAMMASI: pul_qoldiq_kassa_kiritilgan(p_date, null) o'zi mustaqil
    --    hisoblaydi (yuqoridagi izoh).
    v_fam   := v_scope;
    v_open  := coalesce(pul_qoldiq_kassa_kiritilgan(p_from - 1, null), 0);
    v_close := coalesce(pul_qoldiq_kassa_kiritilgan(p_to,       null), 0);
  else
    -- 3) OILA: ildizlar (DISTINCT) -> har biriga pul_qoldiq_kassa_kiritilgan()
    select array_agg(distinct perm_op_key(u.id)) into v_roots
      from unnest(v_scope) u(id);

    if v_roots is null or array_length(v_roots, 1) is null then
      return jsonb_build_object('mos', false, 'sabab', 'ildiz topilmadi',
                                'kassa_soni', 0);
    end if;

    v_n := array_length(v_roots, 1);
    if v_n > c_max then
      return jsonb_build_object('mos', false, 'sabab', 'qamrov juda keng',
                                'kassa_soni', v_n);
    end if;

    -- Butun oila (parent + tur/valyuta bolalari) — transfer_net va
    -- diagnostika satrlarini shu ro'yxat bo'yicha o'lchaymiz.
    select array_agg(distinct f.id) into v_fam
      from unnest(v_roots) r(id), unnest(kassa_oila(r.id)) f(id);

    select coalesce(sum(pul_qoldiq_kassa_kiritilgan(p_from - 1, r.id)), 0) into v_open
      from unnest(v_roots) r(id);
    select coalesce(sum(pul_qoldiq_kassa_kiritilgan(p_to,       r.id)), 0) into v_close
      from unnest(v_roots) r(id);
  end if;

  if v_fam is null or array_length(v_fam, 1) is null then
    v_fam := v_scope;
  end if;

  -- OQIM — jurnal_dash BILAN BITTA MANBA (endi KIRITILGAN vaqt boyicha).
  -- 🔴 p_accounts AYNAN o'zgartirilmasdan uzatiladi (oila kengaytmasi
  --    EMAS): jurnal_dash ham shu qiymat bilan chaqiriladi, ya'ni yozuv
  --    to'plami ikkalasida bir xil bo'ladi.
  -- 🔴 p_moddalar / p_turlar / p_q — null. p_turlar jurnal_dash da ham
  --    e'tiborga olinmaydi; moddalar/qidiruv esa bu RPC imzosida yo'q.
  with b as materialized (
    select * from jurnal_v2_baza(p_from, p_to, p_accounts, null, null, null) z
  ),
  bs as (
    -- AYNAN jurnal_dash dagi ikki chetlash (fail-closed agregat)
    select * from b
     where coalesce(b.is_deleted, false) = false
       and not (b.begona and b.n_lines > 2)
  ),
  t as (
    select coalesce(sum(bs.summa) filter (where bs.tur in ('kirim', 'tushum')),   0)::numeric as kirim,
           coalesce(sum(bs.summa) filter (where bs.tur in ('chiqim', 'xarajat')), 0)::numeric as chiqim,
           coalesce(sum(bs.summa) filter (where bs.tur = 'transfer'),             0)::numeric as tr
      from bs
  ),
  trn as (
    -- Transferning QAMROVGA net ta'siri: oila ichidagi ko'chirish 0 beradi,
    -- tashqariga jo'natilgani manfiy, tashqaridan kelgani musbat.
    select coalesce(sum(l.debit - l.credit), 0)::numeric as net
      from bs
      join entry_line l on l.entry_id = bs.id
     where bs.tur = 'transfer'
       and l.account_id = any(v_fam)
  ),
  bq as (
    -- Diagnostika (A bandi): ko'p satrli / neytral yozuvlarning pulga ta'siri
    select coalesce(sum(l.debit - l.credit), 0)::numeric as net
      from bs
      join entry_line l on l.entry_id = bs.id
     where bs.tur = 'boshqa'
       and l.account_id = any(v_fam)
  ),
  ch as (
    -- Diagnostika (B bandi): agregatdan chetlangan aralash yozuvlar
    select coalesce(sum(l.debit - l.credit), 0)::numeric as net
      from b
      join entry_line l on l.entry_id = b.id
     where coalesce(b.is_deleted, false) = false
       and b.begona and b.n_lines > 2
       and l.account_id = any(v_fam)
  )
  select t.kirim, t.chiqim, t.tr, trn.net, bq.net, ch.net
    into v_kirim, v_chiqim, v_tr, v_trnet, v_boshqa, v_chet
    from t, trn, bq, ch;

  v_kirim  := coalesce(v_kirim, 0);
  v_chiqim := coalesce(v_chiqim, 0);
  v_tr     := coalesce(v_tr, 0);
  v_trnet  := coalesce(v_trnet, 0);
  v_boshqa := coalesce(v_boshqa, 0);
  v_chet   := coalesce(v_chet, 0);

  v_farq := (v_open + v_kirim - v_chiqim + v_trnet) - v_close;
  v_mos  := abs(v_farq) < c_eps;

  if not v_mos then
    v_sabab := 'tenglama chiqmadi';
    if abs(v_boshqa) >= c_eps then
      v_sabab := v_sabab || ' · kop satrli/neytral yozuv pulga tegdi';
    end if;
    if abs(v_chet) >= c_eps then
      v_sabab := v_sabab || ' · aralash yozuv chetlangan';
    end if;
  end if;

  return jsonb_build_object(
    'boshlangich',    round(v_open),
    'tugash',         round(v_close),
    'kirim',          round(v_kirim),
    'chiqim',         round(v_chiqim),
    'transfer',       round(v_tr),
    'transfer_net',   round(v_trnet),
    'boshqa_pul',     round(v_boshqa),
    'chetlangan_pul', round(v_chet),
    'farq',           round(v_farq),
    'mos',            v_mos,
    'sabab',          v_sabab,
    'qamrov',         case when v_hammasi then 'hammasi' else 'tanlangan' end,
    'kassa_soni',     coalesce(array_length(v_roots, 1), array_length(v_scope, 1), 0));
end $fn$;

revoke all on function jurnal_qoldiq(date, date, uuid[]) from public, anon;
grant execute on function jurnal_qoldiq(date, date, uuid[]) to authenticated;

comment on function jurnal_qoldiq(date, date, uuid[]) is
  'Jurnal davr xulosasi uchun BOSHLANGICH (p_from − 1 kun) va TUGASH (p_to) pul qoldigi. '
  '🔴 2026-08-27: p_from/p_to endi KIRITILGAN VAQT boyicha (jurnal_v2_baza va '
  'pul_qoldiq_kassa_kiritilgan() orqali) — PROVODKA_JURNAL_KIRITILGAN.sql, eski pul_qoldiq_kassa()/'
  'pul_qoldiq() (entry_date, cashflow.html) ga TEGILMAGAN. '
  'Ildizlar perm_op_key() bilan DISTINCT qilinadi — oila ikki marta sanalmaydi. '
  'Ruxsat perm_view_pul_ids() bilan SHU YERDA majburlanadi (DEFINER ichida INVOKER RLS ni chetlab otadi). '
  'Sahifa qorovuli: jurnal_page_ok(''jurnal''). Pending yozuvlar ikkala tomonda ham HISOBGA KIRMAYDI (status=''posted''). '
  'Tenglama: boshlangich + kirim − chiqim + transfer_net = tugash. Chiqmasa mos=false + farq + sabab qaytadi '
  'va klient zinapoyani UMUMAN chizmaydi (fail-closed). jurnal_dash() ga TEGILMAGAN.';


-- =====================================================================
-- PostgREST sxemasini yangilash (busiz yangi funksiya 404/PGRST202 beradi)
-- =====================================================================

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  4. TEKSHIRUV — FAQAT KATALOG SO'ROVLARI                        ##
-- #####################################################################
-- 🔴 JONLI RPC CHAQIRUVI YO'Q: SQL editorda `auth.uid()` null → sahifa
--    qorovuli (`jurnal_page_ok`) 42501 beradi va butun fayl (bitta
--    tranzaksiya) orqaga qaytib, funksiyalar umuman yaratilmasdi.
--    Jonli sinov — brauzerda.
-- ---------------------------------------------------------------------

-- 4.1 jurnal_v2_baza — o'rnidami, overload bittami
select to_regprocedure('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)') is not null
         as jurnal_v2_baza_ok,
       (select count(*)::int from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname = 'jurnal_v2_baza') = 1
         as jurnal_v2_baza_overload_bittami;

-- 4.2 jurnal_v2 (9-argumentli) — o'rnidami, overload bittami (eski
--     8-argumentli imzo YO'Q bo'lishi shart, aks holda PostgREST 300 beradi)
select to_regprocedure('public.jurnal_v2(date,date,uuid[],uuid[],text[],text,int,int,text)') is not null
         as jurnal_v2_ok,
       to_regprocedure('public.jurnal_v2(date,date,uuid[],uuid[],text[],text,int,int)') is null
         as jurnal_v2_eski_imzo_yoq,
       (select count(*)::int from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname = 'jurnal_v2') = 1
         as jurnal_v2_overload_bittami;

-- 4.3 pul_qoldiq_kassa_kiritilgan — YANGI, eski pul_qoldiq_kassa
--     TEGILMAGANMI (ikkalasi ham true bo'lishi shart)
select to_regprocedure('public.pul_qoldiq_kassa_kiritilgan(date,uuid)') is not null
         as pul_qoldiq_kassa_kiritilgan_ok,
       to_regprocedure('public.pul_qoldiq_kassa(date,uuid)') is not null
         as eski_pul_qoldiq_kassa_saqlangan;

-- 4.4 jurnal_qoldiq — o'rnidami, overload bittami
select to_regprocedure('public.jurnal_qoldiq(date,date,uuid[])') is not null
         as jurnal_qoldiq_ok,
       (select count(*)::int from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname = 'jurnal_qoldiq') = 1
         as jurnal_qoldiq_overload_bittami;

-- 4.5 🔴 jurnal_v2_count / jurnal_dash / jurnal_ijrochilar TEGILMAGANMI
--     (bu fayl ularni na drop qiladi, na replace — ular jurnal_v2_baza
--     orqali AVTOMAT yangi semantikaga o'tadi, tekshiruv ataylab qat'iy)
select to_regprocedure('public.jurnal_v2_count(date,date,uuid[],uuid[],text[],text,text)') is not null
         as jurnal_v2_count_joyida,
       to_regprocedure('public.jurnal_dash(date,date,uuid[],uuid[],text[],text,text)') is not null
         as jurnal_dash_joyida,
       to_regprocedure('public.jurnal_ijrochilar(date,date)') is not null
         as jurnal_ijrochilar_joyida;

-- 4.6 🔴 cashflow/balans/pnl HISOBOT FUNKSIYALARI TEGILMAGANMI (hammasi
--     true bo'lishi shart — bu fayl ularga umuman tegmadi)
select to_regprocedure('public.pul_qoldiq_kassa(date,uuid)') is not null
         as pul_qoldiq_kassa_joyida,
       to_regprocedure('public.balans(date)') is not null
         as balans_joyida,
       to_regprocedure('public.pnl(date,date)') is not null
         as pnl_joyida,
       to_regprocedure('public.cashflow(date,date,uuid)') is not null
         as cashflow_joyida;
