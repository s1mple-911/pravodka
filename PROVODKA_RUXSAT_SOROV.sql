-- =====================================================================
-- PROVODKA_RUXSAT_SOROV.sql
-- Hodim uchun YOPIQ (RBAC rolida yoq) xarajat moddasiga BIR MARTALIK
-- ruxsat sorovi. Tasdiqlansa xarajat AVTOMAT yoziladi:
--   Dt yopiq modda / Kt hodim kassa, status='posted'.
-- 🔴 TRANSFER YOQ, HODIMGA PUL TUSHMAYDI — bu sorov "pul sorash"
--    (sorovlar/ruxsat_sorov emas) bilan ARALASHTIRILMAYDI, alohida
--    yangi jadval va RPC toplami.
-- Ruxsatsiz yopiq moddaga yozish hamon `trg_rbac_guard_entry_line`
-- orqali 42501 bilan tosiladi (RBAC.sql, TEGILMAYDI).
-- ---------------------------------------------------------------------
-- ## RUN TARTIBI (Asilbek) — bolimlarni tartib bilan
--   0-BOLIM — old shart tekshiruvi (faqat select)
--   1-BOLIM — ruxsat_sorov jadvali + indekslar + RLS
--   2-BOLIM — ruxsat_yopiq_moddalar() — chaqiruvchi uchun yopiq moddalar
--   3-BOLIM — ruxsat_yarat(...) — sorov yaratish
--   4-BOLIM — ruxsat_qator(ruxsat_sorov, uuid) — ICHKI, bitta qator shakli
--   5-BOLIM — ruxsat_royxat(...) / ruxsat_menikilar(...) — royxatlar
--   6-BOLIM — ruxsat_tasdiq(uuid) — tasdiqlash + xarajat yozish
--   7-BOLIM — ruxsat_rad(uuid, text) — rad etish
--   notify pgrst — PostgREST sxema keshi
--   8-BOLIM — perm_guard_entry_line() — ISTISNO qoshiladi (imzo bir xil)
--   9-BOLIM — YAKUNIY TEKSHIRUV (faqat select)
--
-- ## OLD SHART (bazada bolishi kerak)
--   PROVODKA_PERMS.sql   -> user_perms, perm_check_accounts, perm_op_key, is_admin
--   PROVODKA_RBAC.sql    -> rbac_modda_ok(uuid), trg_rbac_guard_entry_line
--   PROVODKA_SOROVLAR.sql -> sorovlar, sorov_page_ok, sorov_kassa_bal,
--                            sorov_kassa_of, sorov_nomzod_ok, sorov_ism,
--                            sorov_post_tosiq, sorov_notify_post,
--                            trg_perm_guard_entry_line
--
-- ## QOIDALAR (CLAUDE.md, buzilmasin)
--   * anonim `do` bloki YOQ — har `do` bloki NOMLANGAN teg bilan.
--   * har funksiya tanasi NOMLANGAN dollar-teg (masalan fn nomli) bilan oraladi.
--   * izohda dollar-qavs ($+$ yonma-yon) YOQ — "anonim do bloki" xavfi.
--   * xato matnlarida apostrof ISHLATILMAYDI (sorov, bolmaydi, yoq — mavjud uslub).
--   * hammasi ADDITIVE: eski jadval/ustun/funksiya imzosi buzilmaydi.
--     Yagona `create or replace` — imzosi bir xil `perm_guard_entry_line()`,
--     u ham faqat YANGI istisno qoshadi, eski mantiq (sorov istisnosi) VERBATIM saqlanadi.
--   * idempotent: qayta RUN qilish xavfsiz (`if not exists` / `create or replace`).
-- =====================================================================


-- #####################################################################
-- ##  0-BOLIM — OLD SHART TEKSHIRUVI (faqat select)                  ##
-- #####################################################################

do $ruxsat_pre$
begin
  if to_regprocedure('public.rbac_modda_ok(uuid)') is null then
    raise exception 'rbac_modda_ok(uuid) yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regclass('public.sorovlar') is null then
    raise exception 'sorovlar jadvali yoq — avval PROVODKA_SOROVLAR.sql ni bajaring';
  end if;
  if to_regprocedure('public.sorov_nomzod_ok(uuid)') is null then
    raise exception 'sorov_nomzod_ok(uuid) yoq — avval PROVODKA_SOROVLAR.sql ni bajaring';
  end if;
  if to_regprocedure('public.sorov_kassa_of(uuid)') is null then
    raise exception 'sorov_kassa_of(uuid) yoq — avval PROVODKA_SOROVLAR.sql ni bajaring';
  end if;
  if to_regprocedure('public.sorov_kassa_bal(uuid)') is null then
    raise exception 'sorov_kassa_bal(uuid) yoq — avval PROVODKA_SOROVLAR.sql ni bajaring';
  end if;
  if to_regprocedure('public.sorov_ism(uuid,uuid)') is null then
    raise exception 'sorov_ism(uuid,uuid) yoq — avval PROVODKA_SOROVLAR.sql ni bajaring';
  end if;
  if to_regprocedure('public.sorov_page_ok(text)') is null then
    raise exception 'sorov_page_ok(text) yoq — avval PROVODKA_SOROVLAR.sql ni bajaring';
  end if;
  if to_regprocedure('public.perm_check_accounts(uuid[])') is null then
    raise exception 'perm_check_accounts(uuid[]) yoq — avval PROVODKA_PERMS.sql ni bajaring';
  end if;
  if to_regprocedure('public.perm_op_key(uuid)') is null then
    raise exception 'perm_op_key(uuid) yoq — avval PROVODKA_PERMS.sql ni bajaring';
  end if;
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'is_admin() funksiyasi yoq — avval asosiy migratsiyani bajaring';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.entry_line'::regclass
                    and tgname  = 'trg_rbac_guard_entry_line') then
    raise exception 'trg_rbac_guard_entry_line yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.entry_line'::regclass
                    and tgname  = 'trg_perm_guard_entry_line') then
    raise exception 'trg_perm_guard_entry_line yoq — pul guardi orin almashgan bolishi mumkin, avval tekshiring';
  end if;
end
$ruxsat_pre$;


-- #####################################################################
-- ##  1-BOLIM — `ruxsat_sorov` jadvali + indekslar + RLS             ##
-- #####################################################################
-- SXEMA QARORLARI (sorovlar bilan bir xil naqsh):
--  * `kassa_id`  — HODIMNING kassasi. Tasdiqlansa Kt shu hisobdan.
--  * `modda_id`  — YOPIQ xarajat moddasi. Tasdiqlansa Dt shu hisobga.
--  * `summa`     — sof so'ralgan/tasdiqlanadigan summa (qisman yoq —
--    bu YOZUV, pul emas, "hammasi yoki hech narsa").
--  * Valyuta ustuni YOQ: xarajat FAQAT UZS kassasidan yoziladi
--    (sorov_yarat 6.5 bilan bir xil qoida).
-- #####################################################################

create table if not exists ruxsat_sorov (
  id          uuid primary key default gen_random_uuid(),
  hodim_id    uuid        not null,
  kimdan_id   uuid        not null,
  kassa_id    uuid        not null references accounts(id),
  modda_id    uuid        not null references accounts(id),
  summa       numeric     not null check (summa > 0),
  izoh        text        not null,
  status      text        not null default 'pending'
                 check (status in ('pending','tasdiq','rad')),
  entry_id    uuid        references entry(id),
  ext_ref     text        unique,
  created_at  timestamptz not null default now(),
  decided_at  timestamptz,
  decided_by  uuid,
  rad_izoh    text,
  -- Ozidan ozi sorash — jadval darajasida ham tosilgan (RPC dan tashqari
  -- yol bolmasa ham: yozuv faqat RPC orqali kiradi, bu ikkinchi qavat).
  constraint ruxsat_ozidan_emas check (hodim_id <> kimdan_id)
);

comment on table ruxsat_sorov is
  'Yopiq xarajat moddasiga bir martalik ruxsat sorovi. Tasdiqlansa Dt modda / Kt hodim kassa '
  'AVTOMAT yoziladi (transfer yoq, hodimga pul tushmaydi). Yozuv FAQAT ruxsat_* RPClari orqali.';
comment on column ruxsat_sorov.kassa_id is
  'Hodimning kassasi — tasdiqlansa Kt shu hisobdan (xarajat shu kassadan chiqadi).';
comment on column ruxsat_sorov.modda_id is
  'Yopiq xarajat moddasi (accounts.type=xarajat, rbac_modda_ok false) — tasdiqlansa Dt shu hisobga.';

create index if not exists ruxsat_sorov_kimdan_status_idx on ruxsat_sorov (kimdan_id, status);
create index if not exists ruxsat_sorov_hodim_idx         on ruxsat_sorov (hodim_id, created_at desc);
create index if not exists ruxsat_sorov_created_idx       on ruxsat_sorov (created_at desc);

-- 🔴 `ext_ref` UNIQUE — ikkinchi qavat himoya (sorovlar_ext_ref_uniq naqshi):
--    jadval `create table` da yaratilganda ham, keyingi qayta RUN'da ham xavfsiz.
create unique index if not exists ruxsat_sorov_ext_ref_uniq
  on ruxsat_sorov (ext_ref) where ext_ref is not null;

-- 🔴 BITTA hodimda BITTA moddaga BITTA ochiq sorov. Busiz hodim bitta
--    yopiq moddaga bir necha marta sorov yuborib, javob kutish navbatini shishirardi.
create unique index if not exists ruxsat_ochiq_uniq
  on ruxsat_sorov (hodim_id, modda_id)
  where status = 'pending';

-- ---------------------------------------------------------------------
-- 1.2  RLS — FAIL-CLOSED (sorovlar 2.2 bilan bir xil naqsh)
--   Oqish: hodim (sorovchi), kimdan (tasdiqlovchi), admin.
--   Yozish: POLICY UMUMAN YOQ -> `authenticated` hech qachon yoza olmaydi.
--   ⚠️ `force row level security` ATAYLAB QOYILMAGAN — u egani ham
--      tosib, RPClarni ishlamas qilardi.
-- ---------------------------------------------------------------------
alter table ruxsat_sorov enable row level security;

revoke all on table ruxsat_sorov from public, anon;
grant select on table ruxsat_sorov to authenticated;

drop policy if exists ruxsat_sorov_select_own on ruxsat_sorov;
create policy ruxsat_sorov_select_own on ruxsat_sorov
  for select to authenticated
  using (
    hodim_id = (select auth.uid())
    or kimdan_id = (select auth.uid())
    or is_admin()
  );


-- #####################################################################
-- ##  2-BOLIM — ruxsat_yopiq_moddalar()                              ##
-- #####################################################################
-- Chaqiruvchi uchun YOPIQ (RBAC rolida yoq) xarajat moddalari royxati.
-- `9110-1` ("Tovar tannarxi (yoldagi)") chetlab otiladi — u tizim ichki
-- otish hisobi, hodim uni qolda hech qachon tanlamaydi.
-- #####################################################################

create or replace function ruxsat_yopiq_moddalar()
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

  -- Adminga hech narsa yopiq emas — royxat bosh.
  if is_admin() then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name)
                             order by a.code), '[]'::jsonb)
    into v_out
    from accounts a
   where a.type = 'xarajat'
     and coalesce(a.is_active, true)
     and a.code <> '9110-1'
     and not rbac_modda_ok(a.id);

  return v_out;
end $fn$;

revoke all on function ruxsat_yopiq_moddalar() from public, anon;
grant execute on function ruxsat_yopiq_moddalar() to authenticated;

comment on function ruxsat_yopiq_moddalar() is
  'Chaqiruvchi uchun YOPIQ xarajat moddalari royxati (rbac_modda_ok false). Admin -> bosh massiv.';


-- #####################################################################
-- ##  3-BOLIM — ruxsat_yarat(...) — sorov yaratish                   ##
-- #####################################################################

create or replace function ruxsat_yarat(
  p_kassa   uuid,
  p_modda   uuid,
  p_summa   numeric,
  p_izoh    text,
  p_kimdan  uuid,
  p_ext_ref text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_ext    text := nullif(btrim(coalesce(p_ext_ref, '')), '');
  v_izoh   text := nullif(btrim(coalesce(p_izoh, '')), '');
  v_modda  accounts;
  v_kassa  accounts;
  v_up     user_perms;
  v_of     uuid;
  v_ruxsat uuid;
begin
  perform set_config('lock_timeout', '5s', true);

  -- 1) Auth
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  -- 2) Summa
  if p_summa is null or p_summa <= 0 or p_summa <> round(p_summa, 2) then
    raise exception 'Summa musbat bolishi kerak' using errcode = '22000';
  end if;
  if p_summa > 100000000 then
    raise exception 'Sorov summasi juda katta — tekshirib qayta yozing' using errcode = '22000';
  end if;

  -- 3) Izoh — majburiy
  if v_izoh is null or length(v_izoh) < 3 then
    raise exception 'Izoh majburiy (kamida 3 belgi)' using errcode = '22000';
  end if;
  if length(v_izoh) > 200 then
    raise exception 'Izoh 200 belgidan oshmasin' using errcode = '22000';
  end if;

  -- 4) ext_ref shakli (sorov_yarat 6.3 bilan bir xil)
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bolishi kerak' using errcode = '22000';
  end if;

  -- 5) Modda — mavjud, faol, xarajat VA aynan YOPIQ bolsin
  select * into v_modda from accounts where id = p_modda;
  if not found or v_modda.is_active is distinct from true then
    raise exception 'Xarajat moddasi topilmadi yoki faol emas' using errcode = '22000';
  end if;
  if v_modda.type <> 'xarajat' then
    raise exception 'Tanlangan hisob xarajat moddasi emas' using errcode = '22000';
  end if;
  -- 🔴 Ochiq moddaga ruxsat sorab bolmaydi — bunday sorov mantiqsiz
  --    (xarajatni oddiy yolda yozish mumkin).
  if rbac_modda_ok(p_modda) then
    raise exception 'Bu modda sizga ochiq — ruxsat kerak emas, xarajatni oddiy yozing'
      using errcode = '22000';
  end if;

  -- 6) Kassa — sorov_yarat 6.5 bilan bir xil qoida + oila chegarasi
  select * into v_kassa from accounts where id = p_kassa;
  if not found or v_kassa.is_active is distinct from true then
    raise exception 'Kassa topilmadi yoki faol emas' using errcode = '22000';
  end if;
  if v_kassa.type <> 'aktiv' or v_kassa.code not like '5%'
     or v_kassa.kassa_turi is not distinct from 'xarajat_guruh' then
    raise exception 'Bu hisob kassa emas' using errcode = '22000';
  end if;
  if coalesce(v_kassa.currency, 'UZS') <> 'UZS' then
    raise exception 'Ruxsat sorovi faqat som kassasida ishlaydi' using errcode = '22000';
  end if;
  if not perm_check_accounts(array[p_kassa]) then
    raise exception 'Ruxsat yoq: bu kassada amaliyot qilish huquqingiz yoq'
      using errcode = '42501';
  end if;
  -- 🔴 OILA CHEGARASI (sorov_yarat 6.5b naqshi) — admin uchun otkazib
  --    yuboriladi (unda biriktirilgan kassa yoq).
  if not is_admin() then
    v_of := sorov_kassa_of(v_uid);
    select * into v_up from user_perms where user_id = v_uid;
    if v_of is null or not found or v_up.kassa_scope <> 'list' then
      raise exception 'Sizga kassa biriktirilmagan — ruxsat sorovi ishlamaydi'
        using errcode = '42501';
    end if;
    if not (
      perm_op_key(p_kassa) = perm_op_key(v_of)
      or perm_op_key(p_kassa) = any (coalesce(v_up.op_kassa_ids, '{}'::uuid[]))
    ) then
      raise exception 'Bu hisob sizning kassangiz emas' using errcode = '42501';
    end if;
  end if;

  -- 7) PUL YETADIMI (Asilbek qarori) — kassangizda pul yetmasa ruxsat emas,
  --    "Pul sorash" orqali sorash kerak. Klient PUL_YETMAYDI prefiksini ushlaydi.
  if sorov_kassa_bal(p_kassa) < p_summa then
    raise exception 'PUL_YETMAYDI: kassangizda pul yetmaydi — bu xarajat uchun ruxsat emas, «Pul sorash» orqali pul sorang'
      using errcode = '22000';
  end if;

  -- 8) Kimdan (tasdiqlovchi)
  if p_kimdan is null then
    raise exception 'Kimdan sorash tanlanmagan' using errcode = '22000';
  end if;
  if p_kimdan = v_uid then
    raise exception 'Ozingizdan ruxsat sorab bolmaydi' using errcode = '22000';
  end if;
  if not sorov_nomzod_ok(p_kimdan) then
    raise exception 'Bu odamdan ruxsat sorab bolmaydi (kassasi yoki sorovlar ruxsati yoq)'
      using errcode = '22000';
  end if;

  -- 9) Ochiq sorov bormi (aniq matn; indeks ham tosadi)
  if exists (
    select 1 from ruxsat_sorov
     where hodim_id = v_uid and modda_id = p_modda and status = 'pending'
  ) then
    raise exception 'Bu modda uchun javob kutayotgan sorovingiz bor' using errcode = '22000';
  end if;

  insert into ruxsat_sorov (hodim_id, kimdan_id, kassa_id, modda_id, summa, izoh, ext_ref)
  values (v_uid, p_kimdan, p_kassa, p_modda, p_summa, v_izoh, v_ext)
  returning id into v_ruxsat;

  return jsonb_build_object('ok', true,
                            'ruxsat_id', v_ruxsat,
                            'status',    'pending',
                            'turi',      'ruxsat');

exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'kod', 'takror');
end $fn$;

revoke all on function ruxsat_yarat(uuid, uuid, numeric, text, uuid, text) from public, anon;
grant execute on function ruxsat_yarat(uuid, uuid, numeric, text, uuid, text) to authenticated;

comment on function ruxsat_yarat(uuid, uuid, numeric, text, uuid, text) is
  'Yopiq xarajat moddasiga bir martalik ruxsat sorovi yaratadi. Transfer yoq, pul harakat qilmaydi. '
  'Idempotent: ext_ref UNIQUE -> takror kod=takror bilan qaytadi.';


-- #####################################################################
-- ##  4-BOLIM — ruxsat_qator(ruxsat_sorov, uuid) — ICHKI              ##
-- #####################################################################
-- 🔴 YAGONA joy: `ruxsat_royxat` ham, `ruxsat_menikilar` ham shuni
--    chaqiradi — ikki royxat hech qachon bir-biridan ajrab ketmaydi.
-- 🔴 `men_qaror_qila_olaman` SERVERDA hisoblanadi: `rbac_modda_ok`
--    `auth.uid()` ga qaraydi, `p_uid` esa chaqiruvchi RPC'larda har doim
--    `auth.uid()` bilan uzatiladi — ya'ni bu yerda ular teng, natija togri.
-- #####################################################################

create or replace function ruxsat_qator(r ruxsat_sorov, p_uid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_modda_kod text;
  v_modda_nom text;
  v_kassa_sub text;
begin
  select a.code, a.name into v_modda_kod, v_modda_nom
    from accounts a where a.id = r.modda_id;

  select nullif(btrim(coalesce(subtitle, '')), '') into v_kassa_sub
    from accounts where id = r.kassa_id;

  return jsonb_build_object(
    'id',                    r.id,
    'turi',                  'ruxsat',
    'sorovchi_id',           r.hodim_id,
    'sorovchi_nom',          sorov_ism(r.hodim_id, r.kassa_id),
    'sorovchi_sub',          v_kassa_sub,
    'kimdan_id',             r.kimdan_id,
    'kimdan_nom',            sorov_ism(r.kimdan_id, null),
    'summa',                 r.summa,
    'izoh',                  r.izoh,
    'modda_id',              r.modda_id,
    'modda_kod',             v_modda_kod,
    'modda_nom',             v_modda_nom,
    'kassa_id',              r.kassa_id,
    'status',                r.status,
    'qaror_izoh',            r.rad_izoh,
    'qaror_kim',             case when r.decided_by is null then null
                                   else sorov_ism(r.decided_by, null) end,
    'qaror_vaqt',            r.decided_at,
    'sana',                  r.created_at,
    'entry_id',              r.entry_id,
    'meniki',                (r.hodim_id = p_uid),
    -- SERVER hisoblaydi: admin hamma sorovni koradi, lekin faqat OZINING
    -- ROLIDA bolgan moddaga tasdiq bera oladi (6-BOLIM 3-shart bilan bir xil).
    'men_qaror_qila_olaman', (r.status = 'pending'
                              and (r.kimdan_id = p_uid or is_admin())
                              and (is_admin() or rbac_modda_ok(r.modda_id))),
    -- UI "bu modda sizning rolingizda ham yoq" deb tushuntirsin.
    'modda_menda_yoq',       (not (is_admin() or rbac_modda_ok(r.modda_id)))
  );
end $fn$;

revoke all on function ruxsat_qator(ruxsat_sorov, uuid) from public, anon, authenticated;

comment on function ruxsat_qator(ruxsat_sorov, uuid) is
  'ICHKI: bitta ruxsat sorovi qatorining jsonb shakli. Ikkala royxat ham shuni ishlatadi.';


-- #####################################################################
-- ##  5-BOLIM — ruxsat_royxat(...) / ruxsat_menikilar(...)           ##
-- #####################################################################
-- `sorov_royxat`/`sorov_menikilar` bilan BIR XIL semantika: sahifa
-- ruxsati `sorov_page_ok('sorovlar')` (bitta sahifa — pul sorovi VA
-- ruxsat sorovi bir joyda koriladi), admin `p_hammasi` bilan hammasini
-- koradi, holat filtri, tartib created_at desc, limit.
-- #####################################################################

create or replace function ruxsat_royxat(p_holat text default null,
                                         p_hammasi boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_all boolean;
  v_h   text := nullif(btrim(coalesce(p_holat, '')), '');
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('sorovlar') then
    raise exception 'Sorovlar sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  v_all := coalesce(p_hammasi, false) and is_admin();

  if v_h is not null and v_h not in ('all','pending','tasdiq','rad') then
    raise exception 'Notanish holat: %', v_h using errcode = '22000';
  end if;

  select coalesce(jsonb_agg(q.j order by q.sana desc), '[]'::jsonb)
    into v_out
    from (
      select ruxsat_qator(r, v_uid) as j, r.created_at as sana
        from ruxsat_sorov r
       where (v_all or r.kimdan_id = v_uid or r.hodim_id = v_uid)
         and (v_h is null or v_h = 'all' or r.status = v_h)
       order by r.created_at desc
       limit 300
    ) q;

  return v_out;
end $fn$;

revoke all on function ruxsat_royxat(text, boolean) from public, anon;
grant execute on function ruxsat_royxat(text, boolean) to authenticated;

comment on function ruxsat_royxat(text, boolean) is
  'Ruxsat sorovlari: menga kelganlar + men yuborganlar (admin + p_hammasi -> hammasi). '
  'Sahifa qorovuli: sorov_page_ok(sorovlar). Eng yangi 300 ta.';


-- ---------------------------------------------------------------------
-- 5.2  ruxsat_menikilar(p_limit) — HODIM SAHIFASI uchun.
--      🔴 sorov_menikilar bilan bir xil sabab: hodim-dev.html hech qachon
--      cheklanmaydi, lekin hodimda 'sorovlar' SAHIFASI bolmasligi mumkin.
--      Qamrov: FAQAT `hodim_id = auth.uid()`, sizadigan narsa yoq.
-- ---------------------------------------------------------------------
create or replace function ruxsat_menikilar(p_limit int default 20)
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

  select coalesce(jsonb_agg(q.j order by q.sana desc), '[]'::jsonb)
    into v_out
    from (
      select ruxsat_qator(r, v_uid) as j, r.created_at as sana
        from ruxsat_sorov r
       where r.hodim_id = v_uid
       order by r.created_at desc
       limit v_n
    ) q;

  return v_out;
end $fn$;

revoke all on function ruxsat_menikilar(int) from public, anon;
grant execute on function ruxsat_menikilar(int) to authenticated;

comment on function ruxsat_menikilar(int) is
  'Hodimning OZ ruxsat sorovlari (sahifa qorovulisiz). Faqat hodim_id = auth.uid().';


-- #####################################################################
-- ##  6-BOLIM — ruxsat_tasdiq(uuid) 🔴 IDEMPOTENT                     ##
-- #####################################################################
-- Tasdiqlansa xarajat AVTOMAT posted qilib yoziladi: Dt modda / Kt hodim
-- kassa. Pul HARAKAT QILMAYDI — bitta yozuv, transfer yoq.
-- #####################################################################

create or replace function ruxsat_tasdiq(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  r       ruxsat_sorov;
  v_modda accounts;
  v_kassa accounts;
  v_entry uuid;
  v_tosiq text;
begin
  perform set_config('lock_timeout', '5s', true);

  -- 1) Auth + sahifa
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('sorovlar') then
    raise exception 'Sorovlar sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  select * into r from ruxsat_sorov where id = p_id for update;
  if not found then
    raise exception 'Sorov topilmadi' using errcode = '22000';
  end if;

  -- 2) Kim tasdiqlaydi
  if r.kimdan_id <> v_uid and not is_admin() then
    raise exception 'Sorovni faqat sorov kelgan odam yoki admin tasdiqlaydi'
      using errcode = '42501';
  end if;

  -- 3) 🔴 TASDIQLOVCHI OZ MODDASINI BERADI: uning ozida yoq ruxsatni
  --    boshqaga bera olmaydi (admin buni chetlab otadi).
  if not is_admin() and not rbac_modda_ok(r.modda_id) then
    raise exception 'Bu modda sizning rolingizda ham yoq — ozingizda yoq ruxsatni bera olmaysiz'
      using errcode = '42501';
  end if;

  -- 4) Ikki marta tasdiqlash/rad — idempotent
  if r.status <> 'pending' then
    return jsonb_build_object('ok', false, 'kod', 'already_decided', 'holat', r.status);
  end if;

  -- 5) Modda va kassa hamon faol/togri turdami
  select * into v_modda from accounts where id = r.modda_id;
  if not found or v_modda.is_active is distinct from true or v_modda.type <> 'xarajat' then
    return jsonb_build_object('ok', false, 'kod', 'hisob_yoq');
  end if;

  select * into v_kassa from accounts where id = r.kassa_id;
  if not found or v_kassa.is_active is distinct from true then
    return jsonb_build_object('ok', false, 'kod', 'hisob_yoq');
  end if;

  -- 6) 🔴 PUL YETADIMI (tasdiqda ham) — so'rov PENDING qoladi, summa/qoldiq
  --    raqami klientga YUBORILMAYDI (balans sizmasin).
  if sorov_kassa_bal(r.kassa_id) < r.summa then
    return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi', 'qoldiq_yetmadi', true);
  end if;

  -- ---- Xarajat provodkasi: Dt modda / Kt hodim kassa, DARROV posted ----
  insert into entry (entry_date, description, source, status, ext_ref, created_by, filial_ids)
  values ((now() at time zone 'Asia/Tashkent')::date,
          'Ruxsat bilan: ' || r.izoh,
          'manual',
          'posted',
          'ruxsat:' || r.id::text,
          r.hodim_id,
          '{}'::uuid[])
  returning id into v_entry;

  -- 🔴 TARTIB MUHIM: `entry_line` dan OLDIN `ruxsat_sorov` yangilanadi —
  --    8-BOLIM dagi guard istisnosi aynan `entry_id`/`decided_at` bogini
  --    qidiradi. Teskari tartibda tasdiqlash 42501 bilan yiqilardi.
  update ruxsat_sorov
     set status     = 'tasdiq',
         entry_id   = v_entry,
         decided_at = now(),
         decided_by = v_uid
   where id = r.id;

  insert into entry_line (entry_id, account_id, debit, credit)
  values (v_entry, r.modda_id, r.summa, 0),
         (v_entry, r.kassa_id, 0,       r.summa);

  -- Modda oylik limiti / kassa qoldigi — sorov_post_tosiq YAGONA predikat.
  v_tosiq := sorov_post_tosiq(v_entry);
  if v_tosiq is not null then
    raise exception 'Limit: %', v_tosiq using errcode = '22000';
  end if;

  if to_regprocedure('public.sorov_notify_post(uuid)') is not null then
    perform sorov_notify_post(v_entry);
  end if;

  return jsonb_build_object('ok', true, 'holat', 'tasdiq', 'entry_id', v_entry);

exception
  -- Poyga: bir vaqtda ikki chaqiruv qulfdan otib ketsa ham ikkinchi
  -- provodka ext_ref UNIQUE ga urilib qaytadi — xarajat ikki marta yozilmaydi.
  when unique_violation then
    return jsonb_build_object('ok', false, 'kod', 'already_decided', 'holat', 'tasdiq');
end $fn$;

revoke all on function ruxsat_tasdiq(uuid) from public, anon;
grant execute on function ruxsat_tasdiq(uuid) to authenticated;

comment on function ruxsat_tasdiq(uuid) is
  'Ruxsat sorovini tasdiqlaydi: Dt modda / Kt hodim kassa, darrov posted. Pul harakat qilmaydi. '
  'Sorov kelgan odam YOKI admin, VA moddaning ozi tasdiqlovchi rolida bolishi shart. '
  'Idempotent: for update + status tekshiruvi + ext_ref UNIQUE.';


-- #####################################################################
-- ##  7-BOLIM — ruxsat_rad(uuid, text) — rad etish                   ##
-- #####################################################################

create or replace function ruxsat_rad(p_id uuid, p_izoh text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid  uuid := auth.uid();
  r      ruxsat_sorov;
  v_izoh text := nullif(btrim(coalesce(p_izoh, '')), '');
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

  select * into r from ruxsat_sorov where id = p_id for update;
  if not found then
    raise exception 'Sorov topilmadi' using errcode = '22000';
  end if;

  -- 🔴 6-BOLIM 2-shart bilan AYNAN bir xil qoida (sorov kelgan odam yoki admin)
  if r.kimdan_id <> v_uid and not is_admin() then
    raise exception 'Sorovni faqat sorov kelgan odam yoki admin rad etadi'
      using errcode = '42501';
  end if;

  if r.status <> 'pending' then
    return jsonb_build_object('ok', false, 'kod', 'already_decided', 'holat', r.status);
  end if;

  update ruxsat_sorov
     set status     = 'rad',
         rad_izoh   = v_izoh,
         decided_at = now(),
         decided_by = v_uid
   where id = r.id;

  return jsonb_build_object('ok', true, 'holat', 'rad');
end $fn$;

revoke all on function ruxsat_rad(uuid, text) from public, anon;
grant execute on function ruxsat_rad(uuid, text) to authenticated;

comment on function ruxsat_rad(uuid, text) is
  'Ruxsat sorovini rad etadi (sabab majburiy). Sorov kelgan odam YOKI admin.';


-- #####################################################################
-- ##  PostgREST sxema keshi                                          ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  8-BOLIM — perm_guard_entry_line() — ISTISNO qoshiladi           ##
-- ##  (create or replace, IMZO BIR XIL — trigger qayta yaratilmaydi) ##
-- #####################################################################
-- ## MUAMMO
--   `ruxsat_tasdiq` xarajat provodkasini TASDIQLOVCHI nomidan yozadi:
--     Dt yopiq modda (v_uid rolida ochiq — 6-BOLIM 3-shart) / Kt HODIM
--     KASSASI. Tasdiqlovchida hodimning kassasiga (Kt) amaliyot huquqi
--     bolmasligi mumkin (`op_kassa_ids` da u yoq) -> `perm_check_accounts`
--     rad etadi -> BUTUN TASDIQLASH 42501 bilan yiqilardi.
--
-- ## YECHIM — MA'LUMOT BILAN TASDIQLANGAN ISTISNO (sorov_tasdiq naqshi)
--   Guard `ruxsat_sorov` jadvalidan SORAYDI: "shu entry aynan SHU
--   foydalanuvchi hal qilgan ruxsat sorovining provodkasimi, va hisob
--   sorovning kassasimi (yoki uning pul-turi/valyuta bolasi)?"
--   `ruxsat_sorov` ga YOZISH POLICYSI YOQ (1.2) — bunday qatorni faqat
--   `ruxsat_tasdiq` yarata oladi, soxtalashtirib bolmaydi.
--
-- ## NARX — NOL (hot path tegilmagan)
--   Qoshimcha sorov FAQAT `perm_check_accounts` VA sorov istisnosi
--   RAD ETGANDA ishlaydi — baribir exception chiqadigan yolda.
--
-- 🔴 ESKI MANTIQ (1-shart va sorov istisnosi) AYNAN SAQLANGAN — faqat
--    rad etishdan OLDIN yana bitta istisno qoshildi.
-- 🔴 `rbac_guard_entry_line` (RBAC.sql) ga TEGILMAYDI: Dt satr (modda)
--    ustidan alohida trigger ishlaydi, u yerda tasdiqlovchi admin yoki
--    moddasi rolida bolgani uchun (6-BOLIM 3-shart) shusiz ham otadi.
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
  -- 1) ESKI QOIDA — ozgarmagan
  if perm_check_accounts(array[new.account_id]) then
    return new;
  end if;

  -- 2) PUL SOROVI ISTISNOSI (sorov_tasdiq) — ozgarmagan, VERBATIM
  begin
    select exists (
      select 1
        from sorovlar s
       where s.jonatma_entry_id = new.entry_id
         and s.kimdan_id = auth.uid()
         and (new.account_id in (s.kassa_id, s.kimdan_kassa_id)
              or perm_op_key(new.account_id) in (s.kassa_id, s.kimdan_kassa_id))
         and s.decided_at = now()
         and (coalesce(new.debit, 0) + coalesce(new.credit, 0)) = s.jonatilgan_summa
    ) into v_ok;
  exception when undefined_table or undefined_column then
    -- Jadval yoq (bu fayl RUN qilinmagan) — eski xatti-harakat
    v_ok := false;
  end;

  if coalesce(v_ok, false) then
    return new;
  end if;

  -- 3) 🔴 RUXSAT SOROVI ISTISNOSI (YANGI, PROVODKA_RUXSAT_SOROV.sql)
  --    `ruxsat_tasdiq` yozgan Dt modda / Kt hodim kassa provodkasi.
  --    Faqat KREDIT satrga (hodim kassasi) kerak, lekin shart universal
  --    yozilgan — Dt (modda) satr ustida ham xato bermaydi, chunki u
  --    allaqachon 1-shartdan (xarajat hisoblar cheklanmaydi) otadi.
  begin
    select exists (
      select 1
        from ruxsat_sorov r
       where r.entry_id = new.entry_id
         and r.decided_by = auth.uid()
         and r.status = 'tasdiq'
         -- 🔴 VAQT CHEGARASI — `now()` = transaction_timestamp(),
         --    `ruxsat_tasdiq` `decided_at = now()` ni AYNI SHU
         --    tranzaksiyada yozadi. Undan keyingi har qanday tranzaksiyada
         --    tenglik yolgon — chetlab otish yoli yopiq.
         and r.decided_at = now()
         and (new.account_id = r.kassa_id or perm_op_key(new.account_id) = r.kassa_id)
         -- 🔴 SUMMA CHEGARASI — Kt satr aynan sorov summasiga teng bolsin.
         and coalesce(new.credit, 0) = r.summa
    ) into v_ok;
  exception when undefined_table or undefined_column then
    -- Jadval yoq (bu fayl RUN qilinmagan) — eski xatti-harakat
    v_ok := false;
  end;

  if coalesce(v_ok, false) then
    return new;
  end if;

  -- 4) RAD ETISH — matn va kod AYNAN eskisi
  select coalesce(a.code || ' ' || a.name, new.account_id::text)
    into v_lbl from accounts a where a.id = new.account_id;

  raise exception 'Ruxsat yoq: % kassasida amaliyot qilish huquqingiz yoq', v_lbl
    using errcode = '42501';
end $fn$;

revoke all on function perm_guard_entry_line() from public, anon;

comment on function perm_guard_entry_line() is
  'user_perms boyicha pul hisoblarini tosadi. service_role (n8n) va admin otadi. '
  'ISTISNO 1: sorov_tasdiq yozgan pul provodkasi (sorovlar.jonatma_entry_id). '
  'ISTISNO 2 (2026-08-29, PROVODKA_RUXSAT_SOROV.sql): ruxsat_tasdiq yozgan '
  'Dt yopiq modda / Kt hodim kassa provodkasi (ruxsat_sorov.entry_id).';


-- #####################################################################
-- ##  9-BOLIM — YAKUNIY TEKSHIRUV (faqat select)                     ##
-- #####################################################################

do $ruxsat_check$
declare
  v_n int;
begin
  -- 9.1 Jadval
  if to_regclass('public.ruxsat_sorov') is null then
    raise exception 'ruxsat_sorov jadvali yaratilmadi';
  end if;

  if not (select relrowsecurity from pg_class where oid = 'public.ruxsat_sorov'::regclass) then
    raise exception 'ruxsat_sorov da RLS yoqilmagan';
  end if;

  select count(*) into v_n from pg_policies
   where schemaname = 'public' and tablename = 'ruxsat_sorov' and cmd <> 'SELECT';
  if v_n > 0 then
    raise exception 'ruxsat_sorov da yozish policysi bor (% ta) — bolmasligi kerak', v_n;
  end if;

  -- 9.2 Indekslar
  if not exists (select 1 from pg_indexes
                  where schemaname = 'public' and indexname = 'ruxsat_ochiq_uniq') then
    raise exception 'ruxsat_ochiq_uniq indeksi yaratilmadi';
  end if;
  if not exists (select 1 from pg_indexes
                  where schemaname = 'public' and indexname = 'ruxsat_sorov_ext_ref_uniq') then
    raise exception 'ruxsat_sorov_ext_ref_uniq indeksi yaratilmadi';
  end if;

  -- 9.3 Funksiyalar (imzo boyicha)
  if to_regprocedure('public.ruxsat_yopiq_moddalar()') is null then
    raise exception 'ruxsat_yopiq_moddalar() yaratilmadi';
  end if;
  if to_regprocedure('public.ruxsat_yarat(uuid, uuid, numeric, text, uuid, text)') is null then
    raise exception 'ruxsat_yarat(uuid, uuid, numeric, text, uuid, text) yaratilmadi';
  end if;
  if to_regprocedure('public.ruxsat_qator(ruxsat_sorov, uuid)') is null then
    raise exception 'ruxsat_qator(ruxsat_sorov, uuid) yaratilmadi';
  end if;
  if to_regprocedure('public.ruxsat_royxat(text, boolean)') is null then
    raise exception 'ruxsat_royxat(text, boolean) yaratilmadi';
  end if;
  if to_regprocedure('public.ruxsat_menikilar(int)') is null then
    raise exception 'ruxsat_menikilar(int) yaratilmadi';
  end if;
  if to_regprocedure('public.ruxsat_tasdiq(uuid)') is null then
    raise exception 'ruxsat_tasdiq(uuid) yaratilmadi';
  end if;
  if to_regprocedure('public.ruxsat_rad(uuid, text)') is null then
    raise exception 'ruxsat_rad(uuid, text) yaratilmadi';
  end if;

  -- 9.4 perm_guard_entry_line() ichida yangi istisno bormi
  if position('ruxsat_sorov' in (select prosrc from pg_proc
                                   where proname = 'perm_guard_entry_line' limit 1)) = 0 then
    raise exception 'perm_guard_entry_line() ichida ruxsat_sorov istisnosi yoq — yangilanmadi';
  end if;

  -- 9.5 Ikkala trigger ham joyida va yoqilgan
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.entry_line'::regclass
                    and tgname  = 'trg_rbac_guard_entry_line'
                    and tgenabled <> 'D') then
    raise exception 'trg_rbac_guard_entry_line yoqilmagan yoki yoq — regressiya!';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.entry_line'::regclass
                    and tgname  = 'trg_perm_guard_entry_line'
                    and tgenabled <> 'D') then
    raise exception 'trg_perm_guard_entry_line yoqilmagan yoki yoq — regressiya!';
  end if;

  -- 9.6 GRANT/REVOKE tekshiruvi
  if not has_function_privilege('authenticated', 'public.ruxsat_yarat(uuid, uuid, numeric, text, uuid, text)', 'execute') then
    raise exception 'ruxsat_yarat(...) authenticated uchun yopiq — UI ishlamaydi';
  end if;
  if has_function_privilege('anon', 'public.ruxsat_yarat(uuid, uuid, numeric, text, uuid, text)', 'execute') then
    raise exception 'ruxsat_yarat(...) anon uchun ochiq qolgan';
  end if;
  if has_function_privilege('authenticated', 'public.ruxsat_qator(ruxsat_sorov, uuid)', 'execute') then
    raise exception 'ruxsat_qator(...) ICHKI funksiya authenticated uchun ochiq qolgan';
  end if;

  raise notice 'ruxsat_sorov tayyor. Jami sorov: % ta', (select count(*) from ruxsat_sorov);
end
$ruxsat_check$;
