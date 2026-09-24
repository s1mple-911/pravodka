-- =====================================================================
-- PROVODKA_STANDART_HODIM.sql
-- Asilbek: "Standart xarajatlar" sahifasida yangi bo'lim — "Hodim bo'yicha
-- xarajatlar". Har hodimga ROLLAR orqali tegishli bo'lgan HAMMA limitni
-- (xarajat moddalari + ovqat 3 turi) bitta joyda ko'rsatadi (shu oy sarfi/
-- qoldig'i bilan) va ADMIN shu HODIM uchun (rolni o'zgartirmasdan) limitni
-- OVERRIDE qilishiga ruxsat beradi. Rollarning o'zi bu bo'limda BERILMAYDI
-- (u "Rollar" sahifasida) — bu yerda faqat KO'RISH + OVERRIDE.
--
-- Ovqat 3 turi (obed/zavtrak/kechki) + "Umumiy ovqatlanish" (jami) rejimi:
-- hodimga "ovqat:umumiy" override qo'yilsa — uch tur ALOHIDA cheksiz
-- bo'lib qoladi, guard esa faqat JAMINI (uch tur yig'indisi) tekshiradi.
-- Umumiy qo'yilmagan bo'lsa — hozirgidek har tur alohida (rol yoki
-- hodim-override) limitiga qaraydi.
-- ---------------------------------------------------------------------
-- ## RUN TARTIBI (bo'limlarni tartib bilan)
--   0-BO'LIM — old shart tekshiruvi (faqat select)
--   1-BO'LIM — rbac_staff_limit jadvali + RLS (additive, yangi jadval)
--   2-BO'LIM — rbac_ovqat_umumiy_qoldi(int, date) — YANGI ICHKI yordamchi
--   3-BO'LIM — rbac_limit_modda(uuid,uuid) qayta e'lon — hodim-override shoxi
--   4-BO'LIM — rbac_limit_ovqat_staff(int,text) qayta e'lon — hodim-override
--              + "ovqat:umumiy" shoxi
--   5-BO'LIM — xarajat_saqlash_ovqat(jsonb) qayta e'lon — UMUMIY limit
--              tekshiruvi qo'shiladi (tana PROVODKA_RBAC_LIMIT.sql dagi ENG
--              OXIRGI versiyaning VERBATIM nusxasi + bitta yangi blok)
--   6-BO'LIM — standart_hodim_limitlar(uuid, date) — O'QISH RPC
--   7-BO'LIM — standart_hodim_limit_set(int, text, numeric, boolean) — YOZISH RPC
--   8-BO'LIM — YAKUNIY TEKSHIRUV (self-check select)
--
-- ## OLD SHART (bazada bo'lishi kerak)
--   PROVODKA_OVQAT.sql           -> aros_staff, staff_branch_map, entry_ovqat
--   PROVODKA_RBAC.sql            -> rbac_role, rbac_role_modda, rbac_role_ovqat,
--                                    rbac_user_role, is_admin()
--   PROVODKA_RBAC_STAFF.sql      -> rbac_staff_role, xarajat_saqlash_ovqat(jsonb)
--   PROVODKA_RBAC_LINK.sql       -> aros_staff.user_id, rbac_staff_ovqat(int)
--   PROVODKA_RBAC_LIMIT.sql      -> rbac_role_modda.limit_uzs, rbac_role_ovqat.limit_uzs,
--                                    rbac_limit_modda, rbac_limit_ovqat_staff,
--                                    rbac_modda_ishlatildi, rbac_ovqat_ishlatildi
--   PROVODKA_STANDART_ROL.sql    -> rbac_limit_entry_line() ENG OXIRGI versiyasi
--                                    (bu faylga tegilmaydi, faqat ma'lumot uchun)
--   PROVODKA_STANDART_RUXSAT.sql -> standart_page_ok()
--
-- ## QOIDALAR (CLAUDE.md, buzilmadi)
--   * anonim `do` bloki YO'Q — har `do` bloki NOMLANGAN teg bilan.
--   * har funksiya tanasi NOMLANGAN dollar-teg (masalan "fn") bilan o'raladi.
--   * izohda dollar-qavs (ikkita "$" yonma-yon) YO'Q.
--   * hammasi additive: eski jadval/ustun/funksiya imzosi buzilmaydi
--     (rbac_limit_modda, rbac_limit_ovqat_staff, xarajat_saqlash_ovqat —
--     uchalasi ham imzo bo'yicha AYNAN saqlandi, faqat tana kengaydi).
--   * idempotent: qayta RUN qilish xavfsiz.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (faqat select)                 ##
-- #####################################################################

do $standart_hodim_pre$
begin
  if to_regclass('public.aros_staff') is null then
    raise exception 'aros_staff jadvali yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;
  if to_regclass('public.staff_branch_map') is null then
    raise exception 'staff_branch_map jadvali yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'aros_staff' and column_name = 'user_id'
  ) then
    raise exception 'aros_staff.user_id ustuni yoq — avval PROVODKA_RBAC_LINK.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_role') is null then
    raise exception 'rbac_role jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_role_modda') is null then
    raise exception 'rbac_role_modda jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'rbac_role_modda' and column_name = 'limit_uzs'
  ) then
    raise exception 'rbac_role_modda.limit_uzs ustuni yoq — avval PROVODKA_RBAC_LIMIT.sql ni bajaring';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'rbac_role_ovqat' and column_name = 'limit_uzs'
  ) then
    raise exception 'rbac_role_ovqat.limit_uzs ustuni yoq — avval PROVODKA_RBAC_LIMIT.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_user_role') is null then
    raise exception 'rbac_user_role jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_staff_role') is null then
    raise exception 'rbac_staff_role jadvali yoq — avval PROVODKA_RBAC_STAFF.sql ni bajaring';
  end if;
  if to_regclass('public.profiles') is null then
    raise exception 'profiles jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'is_admin() funksiyasi yoq';
  end if;
  if to_regprocedure('public.standart_page_ok()') is null then
    raise exception 'standart_page_ok() yoq — avval PROVODKA_STANDART_RUXSAT.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_staff_ovqat(int)') is null then
    raise exception 'rbac_staff_ovqat(int) yoq — avval PROVODKA_RBAC_LINK.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_limit_modda(uuid, uuid)') is null then
    raise exception 'rbac_limit_modda(uuid,uuid) yoq — avval PROVODKA_RBAC_LIMIT.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_limit_ovqat_staff(int, text)') is null then
    raise exception 'rbac_limit_ovqat_staff(int,text) yoq — avval PROVODKA_RBAC_LIMIT.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_modda_ishlatildi(uuid, uuid, date)') is null then
    raise exception 'rbac_modda_ishlatildi(uuid,uuid,date) yoq — avval PROVODKA_RBAC_LIMIT.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_ovqat_ishlatildi(int, text, date)') is null then
    raise exception 'rbac_ovqat_ishlatildi(int,text,date) yoq — avval PROVODKA_RBAC_LIMIT.sql ni bajaring';
  end if;
  if to_regprocedure('public.xarajat_saqlash_ovqat(jsonb)') is null then
    raise exception 'xarajat_saqlash_ovqat(jsonb) yoq — avval PROVODKA_RBAC_STAFF.sql ni bajaring';
  end if;
end
$standart_hodim_pre$;


-- #####################################################################
-- ##  1-BO'LIM — rbac_staff_limit jadvali (additive, YANGI) + RLS    ##
-- ---------------------------------------------------------------------
-- kalit shakli: 'modda:<accounts.id uuid matn>' YOKI
-- 'ovqat:obed' | 'ovqat:zavtrak' | 'ovqat:kechki' | 'ovqat:umumiy'.
-- limit_uzs null = shu hodim uchun CHEKSIZ override (qator BOR, lekin
-- limitsiz) — bu "override yo'q" (qatorning o'zi yo'qligi) dan farqli.
-- #####################################################################

create table if not exists rbac_staff_limit (
  staff_id    int         not null references aros_staff(staff_id) on delete cascade,
  kalit       text        not null
                check (kalit ~ '^(modda:[0-9a-fA-F-]{36}|ovqat:(obed|zavtrak|kechki|umumiy))$'),
  limit_uzs   numeric     check (limit_uzs is null or limit_uzs > 0),
  updated_by  uuid,
  updated_at  timestamptz not null default now(),
  primary key (staff_id, kalit)
);

comment on table rbac_staff_limit is
  'Hodim darajasidagi limit OVERRIDE (rolni o''zgartirmasdan). kalit = ''modda:<account_id>'' '
  'yoki ''ovqat:obed''/''ovqat:zavtrak''/''ovqat:kechki''/''ovqat:umumiy''. limit_uzs null = '
  'shu kalit uchun CHEKSIZ (qator borligi = override faol). Yozish faqat '
  'standart_hodim_limit_set() orqali (standart_page_ok()).';

alter table rbac_staff_limit enable row level security;

drop policy if exists rbac_staff_limit_sel on rbac_staff_limit;
create policy rbac_staff_limit_sel on rbac_staff_limit
  for select to authenticated
  using (standart_page_ok());

-- 🔴 insert/update/delete policy YO'Q — faqat standart_hodim_limit_set()
--    (security definer, table owner sifatida) yozadi.
revoke all on rbac_staff_limit from public, anon;
grant select on rbac_staff_limit to authenticated;


-- #####################################################################
-- ##  2-BO'LIM — rbac_ovqat_umumiy_qoldi(int, date) — YANGI ICHKI    ##
-- ---------------------------------------------------------------------
-- Hodimga 'ovqat:umumiy' override qo'yilgan bo'lsa — jami limitdan shu
-- oyda (uch tur yig'indisi) qolgan qoldiq. Umumiy rejim yoqilmagan yoki
-- umumiy limit cheksiz (qator bor, limit_uzs null) bo'lsa — null (bu
-- holatlarda jami tekshiruv shart emas: birinchi holatda per-tur limit
-- amal qiladi, ikkinchisida hammasi cheksiz).
-- #####################################################################

create or replace function rbac_ovqat_umumiy_qoldi(p_staff int, p_oy date)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_has boolean := false;
  v_lim numeric;
  v_sarf numeric;
begin
  select true, limit_uzs into v_has, v_lim
    from rbac_staff_limit
   where staff_id = p_staff and kalit = 'ovqat:umumiy';

  if not coalesce(v_has, false) then
    return null;                       -- umumiy rejim yoqilmagan
  end if;
  if v_lim is null then
    return null;                       -- umumiy CHEKSIZ
  end if;

  select coalesce(sum(rbac_ovqat_ishlatildi(p_staff, t.tur, p_oy)), 0) into v_sarf
    from unnest(array['obed', 'zavtrak', 'kechki']) as t(tur);

  return v_lim - v_sarf;
end
$fn$;

revoke all on function rbac_ovqat_umumiy_qoldi(int, date) from public, anon, authenticated;

comment on function rbac_ovqat_umumiy_qoldi(int, date) is
  'ICHKI: hodimning ''ovqat:umumiy'' override qoldig''i (limit − uch tur shu oydagi '
  'yig''indisi). Umumiy rejim yoqilmagan yoki cheksiz bo''lsa — null (tekshiruv shart emas).';


-- #####################################################################
-- ##  3-BO'LIM — rbac_limit_modda(uuid,uuid) qayta e'lon             ##
-- ---------------------------------------------------------------------
-- PROVODKA_RBAC_LIMIT.sql dagi ENG OXIRGI tananing VERBATIM nusxasi +
-- BITTA qo'shimcha shox tepada: p_uid biror aros_staff.user_id ga bog'liq
-- bo'lsa va shu hodimga 'modda:<p_account>' override qo'yilgan bo'lsa —
-- ROL logikasi TEKSHIRILMAYDI, override qiymati qaytadi (null = cheksiz).
-- Imzo o'zgarmadi.
-- #####################################################################

create or replace function rbac_limit_modda(p_uid uuid, p_account uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_staff    int;
  v_found    boolean := false;
  v_ov_lim   numeric;
  v_cnt      int;
  v_has_null boolean;
  v_max      numeric;
begin
  -- YANGI (PROVODKA_STANDART_HODIM.sql): hodim darajasidagi OVERRIDE
  -- rol limitini almashtiradi — faqat p_uid biror hodimga (aros_staff.user_id)
  -- bog'langan bo'lsa. rbac_staff_limit jadvali yo'q (SQL run tartibi
  -- buzilgan) bo'lsa bu shox jimgina o'tkazib yuboriladi.
  if to_regclass('public.rbac_staff_limit') is not null then
    select s.staff_id into v_staff from aros_staff s where s.user_id = p_uid limit 1;
    if v_staff is not null then
      select true, sl.limit_uzs into v_found, v_ov_lim
        from rbac_staff_limit sl
       where sl.staff_id = v_staff and sl.kalit = 'modda:' || p_account::text;
      if coalesce(v_found, false) then
        return v_ov_lim;                                -- null = cheksiz override
      end if;
    end if;
  end if;

  select count(*), bool_or(rm.limit_uzs is null), max(rm.limit_uzs)
    into v_cnt, v_has_null, v_max
    from rbac_user_role ur
    join rbac_role r on r.id = ur.role_id and r.is_active
    join rbac_role_modda rm on rm.role_id = ur.role_id and rm.account_id = p_account
   where ur.user_id = p_uid;

  if coalesce(v_cnt, 0) = 0 then
    return null;                                    -- shu moddaga rolida limit qoyilmagan
  end if;
  if v_has_null then
    return null;                                     -- kamida bitta rolda cheksiz
  end if;
  return v_max;
end
$fn$;

revoke all on function rbac_limit_modda(uuid, uuid) from public, anon, authenticated;

comment on function rbac_limit_modda(uuid, uuid) is
  'ICHKI: foydalanuvchining (rbac_user_role orqali) shu xarajat moddasiga effektiv oylik limiti. '
  'YANGI (PROVODKA_STANDART_HODIM.sql): hodim darajasidagi override (rbac_staff_limit, '
  '''modda:<account>'') bor bo''lsa — rol logikasidan OLDIN o''sha qaytadi (null = cheksiz). '
  'Rolida modda yoq -> null. Bir nechta rolda bittasi cheksiz -> null. Aks holda MAX(limit_uzs).';


-- #####################################################################
-- ##  4-BO'LIM — rbac_limit_ovqat_staff(int,text) qayta e'lon        ##
-- ---------------------------------------------------------------------
-- PROVODKA_RBAC_LIMIT.sql dagi ENG OXIRGI tananing VERBATIM nusxasi +
-- IKKI qo'shimcha shox tepada: (1) 'ovqat:umumiy' qatori BOR bo'lsa
-- (qiymatidan qat'i nazar) — bu tur ALOHIDA cheksiz (jami limit boshqa
-- joyda, rbac_ovqat_umumiy_qoldi(), tekshiriladi); (2) aks holda shu
-- (staff, tur) uchun to'g'ridan override bo'lsa — o'sha qiymat. Imzo
-- o'zgarmadi.
-- #####################################################################

create or replace function rbac_limit_ovqat_staff(p_staff int, p_tur text)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_user_id  uuid;
  v_found    boolean := false;
  v_ov_lim   numeric;
  v_cnt      int;
  v_has_null boolean;
  v_max      numeric;
begin
  -- YANGI (PROVODKA_STANDART_HODIM.sql): hodim darajasidagi override.
  if to_regclass('public.rbac_staff_limit') is not null then
    if exists (
      select 1 from rbac_staff_limit where staff_id = p_staff and kalit = 'ovqat:umumiy'
    ) then
      return null;               -- UMUMIY rejim — per-tur cheksiz, jami boshqa joyda tekshiriladi
    end if;

    select true, limit_uzs into v_found, v_ov_lim
      from rbac_staff_limit
     where staff_id = p_staff and kalit = 'ovqat:' || p_tur;
    if coalesce(v_found, false) then
      return v_ov_lim;                                  -- null = cheksiz override
    end if;
  end if;

  select user_id into v_user_id from aros_staff where staff_id = p_staff;

  if v_user_id is not null then
    select count(*), bool_or(ro.limit_uzs is null), max(ro.limit_uzs)
      into v_cnt, v_has_null, v_max
      from rbac_user_role ur
      join rbac_role r on r.id = ur.role_id and r.is_active
      join rbac_role_ovqat ro on ro.role_id = ur.role_id and ro.tur = p_tur
     where ur.user_id = v_user_id;
  else
    select count(*), bool_or(ro.limit_uzs is null), max(ro.limit_uzs)
      into v_cnt, v_has_null, v_max
      from rbac_staff_role sr
      join rbac_role r on r.id = sr.role_id and r.is_active
      join rbac_role_ovqat ro on ro.role_id = sr.role_id and ro.tur = p_tur
     where sr.staff_id = p_staff;
  end if;

  if coalesce(v_cnt, 0) = 0 then
    return null;
  end if;
  if v_has_null then
    return null;
  end if;
  return v_max;
end
$fn$;

revoke all on function rbac_limit_ovqat_staff(int, text) from public, anon, authenticated;

comment on function rbac_limit_ovqat_staff(int, text) is
  'ICHKI: YEYUVCHI hodimning shu ovqat turiga effektiv oylik limiti. YANGI '
  '(PROVODKA_STANDART_HODIM.sql): ''ovqat:umumiy'' override bor bo''lsa — null (per-tur '
  'cheksiz, jami rbac_ovqat_umumiy_qoldi() da); aks holda shu turga to''g''ridan override '
  'bo''lsa — o''sha. Aks holda eski rol logikasi (rbac_staff_ovqat bilan bir xil manba).';


-- #####################################################################
-- ##  5-BO'LIM — xarajat_saqlash_ovqat(jsonb) qayta e'lon            ##
-- ---------------------------------------------------------------------
-- PROVODKA_RBAC_LIMIT.sql dagi ENG OXIRGI tananing VERBATIM nusxasi +
-- YANGI blok: har-tur tekshiruvidan DARHOL KEYIN, entry insertdan OLDIN,
-- UMUMIY ovqat limiti (uch tur yig'indisi) tekshiriladi — rbac_ovqat_umumiy_qoldi()
-- null bo'lmasa (ya'ni umumiy rejim yoqilgan) va shu narx qoldiqdan oshsa rad.
-- #####################################################################

create or replace function xarajat_saqlash_ovqat(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_dt         uuid := nullif(p_data->>'dt_account', '')::uuid;
  v_kt         uuid := nullif(p_data->>'kt_account', '')::uuid;
  v_summa      numeric := nullif(p_data->>'summa', '')::numeric;
  v_ext        text := nullif(trim(p_data->>'ext_ref'), '');
  v_kun        date := coalesce(nullif(p_data->>'kun', '')::date,
                                 (now() at time zone 'Asia/Tashkent')::date);
  v_entry_date date := coalesce(nullif(p_data->>'entry_date', '')::date, v_kun);

  v_dt_ovqat   boolean;
  v_kt_cur     text;

  it           jsonb;
  v_n          int;
  v_i          int := 0;
  v_rbac_ok    boolean;
  v_staff      int;
  v_tur        text;
  v_narx_obed    numeric;
  v_narx_zavtrak numeric;
  v_narx_kechki  numeric;
  v_narx       numeric;
  v_royxat_summa numeric := 0;

  v_seen_keys  text[] := '{}';
  v_key        text;

  v_staff_ids  int[]    := '{}';
  v_turs       text[]   := '{}';
  v_narxs      numeric[]:= '{}';
  v_snoms      text[]   := '{}';
  v_name_seen  int[]    := '{}';
  v_names      text[]   := '{}';

  v_snom       text;
  v_active     boolean;
  v_cnt_obed   int := 0;
  v_cnt_zavtrak int := 0;
  v_cnt_kechki int := 0;

  v_dup_soat   text;
  v_dup_kim    text;
  v_dup_entry  uuid;

  -- YANGI (PROVODKA_RBAC_LIMIT.sql): ovqat OYLIK limiti
  v_narx_shu    numeric;
  v_lim_ovqat   numeric;
  v_used_ovqat  numeric;

  -- YANGI (PROVODKA_STANDART_HODIM.sql): UMUMIY ovqat limiti
  v_umumiy_qoldi numeric;

  v_entry      uuid;
  v_con        text;
  v_det        text;
  j            int;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_dt is null or v_kt is null then
    raise exception 'Modda (Dt) va kassa (Kt) tanlanishi shart' using errcode = '22000';
  end if;
  if v_summa is null or v_summa <= 0 then
    raise exception 'Summa musbat bo''lishi kerak' using errcode = '22000';
  end if;
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bo''lishi kerak' using errcode = '22000';
  end if;
  if p_data->'royxat' is null or jsonb_typeof(p_data->'royxat') <> 'array'
     or jsonb_array_length(p_data->'royxat') = 0 then
    raise exception 'Hodim ro''yxati bo''sh' using errcode = '22000';
  end if;

  select ovqat_modda into v_dt_ovqat from accounts where id = v_dt;
  if not coalesce(v_dt_ovqat, false) then
    raise exception 'Tanlangan modda ovqat moddasi emas (admin uni Sozlamada belgilashi kerak)'
      using errcode = '22000';
  end if;

  select coalesce(currency, 'UZS') into v_kt_cur from accounts where id = v_kt;
  if v_kt_cur is null then
    raise exception 'Kassa topilmadi' using errcode = '22000';
  end if;
  if v_kt_cur <> 'UZS' then
    raise exception 'Ovqat faqat so''m kassasidan yoziladi (valyuta kassasi v1 da qo''llab-quvvatlanmaydi)'
      using errcode = '22000';
  end if;

  select obed, zavtrak, kechki into v_narx_obed, v_narx_zavtrak, v_narx_kechki
    from jsonb_to_record(ovqat_narxlar()) as t(obed numeric, zavtrak numeric, kechki numeric);

  v_n := jsonb_array_length(p_data->'royxat');

  -- ---- 1-O'TISH: FAQAT TEKSHIRUV (hech narsa yozilmaydi) --------------
  for j in 0 .. v_n - 1 loop
    v_i := v_i + 1;
    it := p_data->'royxat'->j;
    v_staff := nullif(it->>'staff_id', '')::int;
    v_tur   := nullif(it->>'tur', '');

    if v_staff is null then
      raise exception 'Ro''yxatdagi %-satrda staff_id ko''rsatilmagan', v_i using errcode = '22000';
    end if;
    if v_tur is null or v_tur not in ('obed', 'zavtrak', 'kechki') then
      raise exception 'Ro''yxatdagi %-satrda tur noto''g''ri (obed|zavtrak|kechki kerak)', v_i using errcode = '22000';
    end if;

    -- 🔴 Asilbek qarori (2026-08-27): YOZUVCHI roli ovqatga TA'SIR QILMAYDI —
    --    faqat yeyuvchi hodim roli (pastdagi rbac_staff_ovqat). Eski yozuvchi
    --    tekshiruvi (rbac_ovqat_ok) ataylab OLIB TASHLANDI: yozuvchida faqat obed
    --    bo'lsa hamkasblarining kechki/zavtragi yashirilib qolardi.

    v_key := v_staff::text || ':' || v_tur;
    if v_key = any(v_seen_keys) then
      select coalesce(nullif(btrim(toliq_nom), ''), btrim(coalesce(ism, '') || ' ' || coalesce(familiya, '')))
        into v_snom from aros_staff where staff_id = v_staff;
      raise exception '% uchun % ro''yxatda ikki marta ko''rsatilgan', coalesce(nullif(v_snom, ''), v_staff::text), v_tur
        using errcode = '22000';
    end if;
    v_seen_keys := v_seen_keys || v_key;

    select coalesce(nullif(btrim(toliq_nom), ''), btrim(coalesce(ism, '') || ' ' || coalesce(familiya, ''))),
           is_active
      into v_snom, v_active
      from aros_staff
     where staff_id = v_staff;

    if v_snom is null then
      raise exception 'Xodim topilmadi (staff_id=%)', v_staff using errcode = '22000';
    end if;
    if not coalesce(v_active, false) then
      raise exception '% faol emas, ovqat yozib bo''lmaydi', v_snom using errcode = '22000';
    end if;

    -- 🔴 YEYUVCHI (PROVODKA_RBAC_STAFF.sql, YANGI): hodimning O'ZI shu ovqat
    --    turiga ruxsatlimi (rbac_staff_role orqali). YOZUVCHI tekshiruvidan
    --    (yuqorida) MUSTAQIL — ikkalasi ham o'tishi shart (AND). Admin
    --    yozayotgan bo'lsa ham (yozuvchi shoxidan o'tadi) bu shox AMAL
    --    QILADI — ruxsat ovqatni yeyadigan hodimga tegishli, kim yozganiga
    --    emas. Rolsiz hodim -> rbac_staff_ovqat() '{}' qaytaradi -> rad.
    if not (v_tur = any(rbac_staff_ovqat(v_staff))) then
      raise exception '% uchun "%" ovqat turi ruxsat etilmagan (hodim roli)', v_snom, v_tur
        using errcode = '42501';
    end if;

    -- 🔴 YANGI (PROVODKA_RBAC_LIMIT.sql): rolda shu ovqat turiga OYLIK
    --    limit qoyilgan bolsa (rbac_role_ovqat.limit_uzs), limit YEYUVCHI
    --    hodimga tegishli (rbac_limit_ovqat_staff — rbac_staff_ovqat bilan
    --    bir xil manba). Bir nechta rolda bittasida limit yoq (null) bolsa
    --    — CHEKSIZ. Tekshiruv entry insertdan OLDIN (hech narsa yozilmaydi).
    -- 🔴 rbac_limit_ovqat_staff endi (PROVODKA_STANDART_HODIM.sql) hodim
    --    override'ini VA 'ovqat:umumiy' rejimini ham hisobga oladi — bu
    --    yerdagi chaqiruv o'zgarmagan, mantiq funksiya ichida kengaydi.
    if v_tur = 'obed' then v_narx_shu := v_narx_obed;
    elsif v_tur = 'zavtrak' then v_narx_shu := v_narx_zavtrak;
    else v_narx_shu := v_narx_kechki;
    end if;

    v_lim_ovqat := rbac_limit_ovqat_staff(v_staff, v_tur);
    if v_lim_ovqat is not null then
      v_used_ovqat := rbac_ovqat_ishlatildi(v_staff, v_tur, v_kun) + v_narx_shu;
      if v_used_ovqat > v_lim_ovqat then
        raise exception 'Oylik ovqat limiti oshdi: % — % (limit %, ishlatildi %)',
          v_snom, v_tur, round(v_lim_ovqat), round(v_used_ovqat)
          using errcode = '42501';
      end if;
    end if;

    -- 🔴 YANGI (PROVODKA_STANDART_HODIM.sql): UMUMIY ovqat limiti (uch
    --    turning yig'indisi). rbac_limit_ovqat_staff yuqorida umumiy
    --    rejimda null qaytargani uchun (per-tur cheksiz) jami bu yerda
    --    ALOHIDA tekshiriladi — rbac_ovqat_umumiy_qoldi() umumiy rejim
    --    yoqilmagan/cheksiz bo'lsa null qaytaradi (tekshiruv shart emas).
    if to_regclass('public.rbac_staff_limit') is not null then
      v_umumiy_qoldi := rbac_ovqat_umumiy_qoldi(v_staff, v_kun);
      if v_umumiy_qoldi is not null and v_narx_shu > v_umumiy_qoldi then
        raise exception 'Umumiy ovqat limiti tugadi: % — qoldi %, kerak %',
          v_snom, round(v_umumiy_qoldi), round(v_narx_shu)
          using errcode = '42501';
      end if;
    end if;

    -- Bazada shu kun/staff/tur allaqachon bormi?
    select to_char(eo.created_at at time zone 'Asia/Tashkent', 'HH24:MI'),
           ovqat_kiritgan((to_jsonb(e) ->> 'created_by')),
           eo.entry_id
      into v_dup_soat, v_dup_kim, v_dup_entry
      from entry_ovqat eo
      join entry e on e.id = eo.entry_id
     where eo.staff_id = v_staff and eo.kun = v_kun and eo.tur = v_tur and not eo.is_deleted
     limit 1;

    if v_dup_entry is not null then
      raise exception '% bugun % olgan (%, %)', v_snom, v_tur, coalesce(v_dup_soat, '?'), coalesce(v_dup_kim, 'Noma''lum')
        using errcode = 'P0001';
    end if;

    -- 🔴 fail-closed: uch turdan tashqarisi bu yergacha yetib kelmaydi
    --    (yuqorida tekshirilgan), lekin ikkinchi qavat himoya sifatida
    --    ELSE holatida boshqa narx yozilib qolmasin — RAISE.
    case v_tur
      when 'obed'    then v_narx := v_narx_obed;
      when 'zavtrak' then v_narx := v_narx_zavtrak;
      when 'kechki'  then v_narx := v_narx_kechki;
      else raise exception 'Nomalum tur (obed|zavtrak|kechki kerak)' using errcode = '22000';
    end case;
    v_royxat_summa := v_royxat_summa + v_narx;

    v_staff_ids := v_staff_ids || v_staff;
    v_turs      := v_turs || v_tur;
    v_narxs     := v_narxs || v_narx;
    v_snoms     := v_snoms || v_snom;

    if v_tur = 'obed' then v_cnt_obed := v_cnt_obed + 1;
    elsif v_tur = 'zavtrak' then v_cnt_zavtrak := v_cnt_zavtrak + 1;
    else v_cnt_kechki := v_cnt_kechki + 1;
    end if;
    if not (v_staff = any(v_name_seen)) then
      v_name_seen := v_name_seen || v_staff;
      v_names := v_names || v_snom;
    end if;
  end loop;

  -- 🔴 Summa AYNAN mos bo'lishi shart (kam ham, ko'p ham xato).
  if v_royxat_summa <> v_summa then
    raise exception 'Summa ro''yxatga mos emas: ro''yxat %, yozilgan %', v_royxat_summa::text, v_summa::text
      using errcode = 'P0001';
  end if;

  -- ---- 2-O'TISH: YOZISH ------------------------------------------------
  -- 🔴 status/source KLIENTDAN OLINMAYDI (fail-closed — tester topilmasi):
  --    status='draft' kelsa pul yozilmay entry_ovqat unique slot abadiy
  --    band bo'lib qolardi (ovqat_bugun'da jim yo'qolgan slot). Shuning
  --    uchun ikkalasi ham QATTIQ literal: har doim 'posted' / 'manual'.
  -- 🔴 `created_by` INSERT ro'yxatida YO'Q — `xarajat_saqlash_taqsim`
  --    (PROVODKA_TOSIQ_OCHIR.sql) bilan AYNAN bir xil naqsh: ustun turi
  --    (`entry.created_by`) bazada noma'lum (PROVODKA_IJROCHI.sql:12-35),
  --    `auth.uid()` (uuid) ni to'g'ridan yozish text ustunda cast xatosi
  --    berishi mumkin. `trg_entry_ijrochi` (BEFORE INSERT, PROVODKA_IJROCHI.sql)
  --    `created_by is null` bo'lganda `jsonb_populate_record` bilan (turga
  --    bog'liq bo'lmagan usulda) avtomat to'ldiradi.
  insert into entry (entry_date, description, source, status, filial_ids,
                     davr_start, davr_end, ext_ref)
  values (
    v_entry_date,
    coalesce(nullif(p_data->>'description', ''),
             'Ovqat: ' || v_cnt_zavtrak || ' zavtrak, ' || v_cnt_obed || ' obed, ' || v_cnt_kechki || ' kechki — ' || array_to_string(v_names, ', ')),
    'manual',
    'posted',
    case when jsonb_typeof(p_data->'filial_ids') = 'array'
         then coalesce((select array_agg(t.val::uuid) from jsonb_array_elements_text(p_data->'filial_ids') as t(val)),
                       '{}'::uuid[])
         else '{}'::uuid[] end,
    nullif(p_data->>'davr_start', '')::date,
    nullif(p_data->>'davr_end', '')::date,
    v_ext
  )
  returning id into v_entry;

  insert into entry_line (entry_id, account_id, debit, credit)
  values (v_entry, v_dt, v_summa, 0),
         (v_entry, v_kt, 0, v_summa);

  for v_i in 1 .. v_n loop
    insert into entry_ovqat (entry_id, staff_id, staff_nom, tur, narx, kun)
    values (v_entry, v_staff_ids[v_i], v_snoms[v_i], v_turs[v_i], v_narxs[v_i], v_kun);
  end loop;

  return jsonb_build_object('entry_id', v_entry, 'summa', v_royxat_summa, 'royxat_soni', v_n);

exception
  when unique_violation then
    get stacked diagnostics v_con = constraint_name, v_det = pg_exception_detail;
    if coalesce(v_con, '') ilike '%entry_ovqat%' or coalesce(v_det, '') ilike '%entry_ovqat%' then
      raise exception 'Shu kun uchun bu hodimga bu ovqat turi boshqa foydalanuvchi tomonidan bir vaqtda yozildi — sahifani yangilang'
        using errcode = 'P0001';
    end if;
    if v_ext is null then
      raise;                                   -- bizning to'siq emas
    end if;
    if coalesce(v_con, '') not ilike '%ext_ref%' and coalesce(v_det, '') not ilike '%ext_ref%' then
      raise;
    end if;
    raise exception 'Bu xarajat allaqachon saqlangan (takroriy yuborish to''sildi)'
      using errcode = '23505';
end $fn$;

revoke all on function xarajat_saqlash_ovqat(jsonb) from public, anon;
grant execute on function xarajat_saqlash_ovqat(jsonb) to authenticated;

comment on function xarajat_saqlash_ovqat(jsonb) is
  'Ovqat (obed/zavtrak/kechki) xarajatini hodim ro''yxati bilan atomik yozadi. Narx serverdan (ovqat_narxlar()), '
  'summa ro''yxatga AYNAN teng bo''lishi shart, kuniga bir hodim/tur bir marta. '
  'Ikki mustaqil ruxsat: YOZUVCHI (rbac_ovqat_ok, kim yozyapti) VA YEYUVCHI (rbac_staff_ovqat, kimga yozilyapti) — '
  'ikkalasi ham o''tishi shart. YEYUVCHI hodimning OYLIK ovqat limiti (rbac_limit_ovqat_staff) — entry insertdan '
  'oldin tekshiriladi. YANGI (PROVODKA_STANDART_HODIM.sql): agar hodimga ''ovqat:umumiy'' override qo''yilgan '
  'bo''lsa — uch tur yig''indisi (rbac_ovqat_umumiy_qoldi) ham tekshiriladi. Tahrirlash taqiq (PROVODKA_OVQAT.sql 8-BO''LIM).';


-- #####################################################################
-- ##  6-BO'LIM — standart_hodim_limitlar(uuid, date) — O'QISH RPC    ##
-- ---------------------------------------------------------------------
-- Har hodim (kamida bitta rol bilan) x har limit (modda YOKI ovqat turi)
-- qatori: rol limiti, hodim-override, effektiv limit, shu oy sarfi/qoldig'i.
-- Ruxsat: standart_page_ok() — YO'Q bo'lsa EXCEPTION emas, jsonb
-- {ok:false, kod:'ruxsat'} (klient RPC yo'q/xato holatidan ajratsin).
-- #####################################################################

create or replace function standart_hodim_limitlar(p_filial uuid default null, p_oy date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_oy         date;
  v_filial_id  uuid;
  v_filial_nom text;
  v_bids       int[];
begin
  if not standart_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  v_oy := date_trunc('month', coalesce(p_oy, (now() at time zone 'Asia/Tashkent')::date))::date;

  if p_filial is not null then
    select id, name into v_filial_id, v_filial_nom
      from accounts
     where id = p_filial
       and kassa_turi = 'filial'
       and parent_id is null
       and coalesce(is_active, true);
    if v_filial_id is null then
      raise exception 'Filial topilmadi: %', p_filial using errcode = '22023';
    end if;
    select coalesce(array_agg(m.branch_id), '{}'::int[]) into v_bids
      from staff_branch_map m
     where m.filial_id = v_filial_id or m.provodka_filial = v_filial_nom;
  end if;

  return (
    with staff_in as (
      select s.staff_id,
             coalesce(nullif(btrim(s.toliq_nom), ''),
                      btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))) as nom,
             s.lavozim, s.user_id, s.branch_id, s.branch_nomi
        from aros_staff s
       where s.is_active
         and (
           v_filial_id is null
           or s.branch_id = any(v_bids)
           or exists (
             select 1 from jsonb_array_elements(coalesce(s.branches, '[]'::jsonb)) b
              where (b ->> 'id') ~ '^\d+$' and (b ->> 'id')::int = any(v_bids)
           )
         )
    ),
    staff_admin as (
      select si.staff_id
        from staff_in si
        join profiles p on p.id = si.user_id
       where si.user_id is not null and p.role = 'admin'
    ),
    staff_role as (
      select si.staff_id, r.id as role_id, r.nom as role_nom
        from staff_in si
        join rbac_user_role ur on ur.user_id = si.user_id
        join rbac_role r on r.id = ur.role_id and r.is_active
       where si.user_id is not null
         and not exists (select 1 from staff_admin sa where sa.staff_id = si.staff_id)
      union all
      select si.staff_id, r.id, r.nom
        from staff_in si
        join rbac_staff_role sr on sr.staff_id = si.staff_id
        join rbac_role r on r.id = sr.role_id and r.is_active
       where si.user_id is null
    ),
    staff_eff as (
      select staff_id from staff_role
      union
      select staff_id from staff_admin
    ),
    staff_filial as (
      select si.staff_id, coalesce(fa.name, si.branch_nomi) as filial_nom
        from staff_in si
        left join staff_branch_map m on m.branch_id = si.branch_id
        left join accounts fa on fa.id = m.filial_id
    ),
    hodim_meta as (
      select si.staff_id, si.nom, si.lavozim,
             case when exists (select 1 from staff_admin sa where sa.staff_id = si.staff_id)
                  then '["Admin"]'::jsonb
                  else coalesce((select jsonb_agg(distinct sr.role_nom order by sr.role_nom)
                                   from staff_role sr where sr.staff_id = si.staff_id), '[]'::jsonb)
             end as rollar
        from staff_in si
       where si.staff_id in (select staff_id from staff_eff)
    ),
    -- MODDA (xarajat, ovqat_modda EMAS) yig'ma manbasi: rol orqali + admin shox (hamma, cheksiz).
    modda_z as (
      select sr.staff_id, am.id as modda_id, am.code, am.name, rm.limit_uzs
        from staff_role sr
        join rbac_role_modda rm on rm.role_id = sr.role_id
        join accounts am on am.id = rm.account_id and am.type = 'xarajat'
                        and coalesce(am.is_active, true) and not coalesce(am.ovqat_modda, false)
      union all
      select sa.staff_id, a.id, a.code, a.name, null::numeric
        from staff_admin sa
        cross join accounts a
       where a.type = 'xarajat' and coalesce(a.is_active, true) and not coalesce(a.ovqat_modda, false)
    ),
    modda_rol as (
      select z.staff_id, z.modda_id, min(z.code) as code, min(z.name) as name,
             bool_or(z.limit_uzs is null) as rol_cheksiz,
             max(z.limit_uzs)             as rol_lim
        from modda_z z
       group by z.staff_id, z.modda_id
    ),
    modda_eff as (
      select mr.staff_id, mr.modda_id, mr.code, mr.name, mr.rol_cheksiz, mr.rol_lim,
             sl.limit_uzs as override_lim,
             (sl.staff_id is not null) as has_override,
             case when sl.staff_id is not null then sl.limit_uzs
                  when mr.rol_cheksiz then null else mr.rol_lim end as eff_lim
        from modda_rol mr
        left join rbac_staff_limit sl
          on sl.staff_id = mr.staff_id and sl.kalit = 'modda:' || mr.modda_id::text
    ),
    modda_qator as (
      select me.staff_id, me.code,
             jsonb_build_object(
               'kalit',          'modda:' || me.modda_id::text,
               'turi',           'modda',
               'account_id',     me.modda_id,
               'code',           me.code,
               'name',           me.name,
               'tur',            null,
               'rol_limit',      case when me.rol_cheksiz then null else me.rol_lim end,
               'hodim_limit',    me.override_lim,
               'effektiv_limit', me.eff_lim,
               'sarf',           coalesce(msf.sarf, 0),
               'qoldi',          case when me.eff_lim is null then null else me.eff_lim - coalesce(msf.sarf, 0) end,
               'override',       me.has_override
             ) as qator
        from modda_eff me
        left join staff_in si on si.staff_id = me.staff_id
        left join lateral (
          select case when si.user_id is not null
                      then rbac_modda_ishlatildi(si.user_id, me.modda_id, v_oy)
                      else 0 end as sarf
        ) msf on true
    ),
    -- OVQAT: 3 tur (rol orqali ruxsat etilgan yoki admin shox — hamma tur, cheksiz).
    ov_modda as (
      select id, code, name from accounts
       where coalesce(ovqat_modda, false) and type = 'xarajat' and coalesce(is_active, true)
    ),
    ov_z as (
      select sr.staff_id, ro.tur, ro.limit_uzs
        from staff_role sr
        join rbac_role_ovqat ro on ro.role_id = sr.role_id
      union all
      select sa.staff_id, t.tur, null::numeric
        from staff_admin sa
        cross join unnest(array['obed', 'zavtrak', 'kechki']) as t(tur)
    ),
    ov_rol as (
      select z.staff_id, z.tur,
             bool_or(z.limit_uzs is null) as rol_cheksiz,
             max(z.limit_uzs)             as rol_lim
        from ov_z z
       group by z.staff_id, z.tur
    ),
    ov_umumiy as (
      select staff_id, limit_uzs from rbac_staff_limit where kalit = 'ovqat:umumiy'
    ),
    ov_eff as (
      select orr.staff_id, orr.tur, orr.rol_cheksiz, orr.rol_lim,
             sl.limit_uzs as override_lim,
             (sl.staff_id is not null) as has_override,
             (u.staff_id is not null)  as umumiy_on,
             case when u.staff_id is not null then null
                  when sl.staff_id is not null then sl.limit_uzs
                  when orr.rol_cheksiz then null else orr.rol_lim end as eff_lim,
             rbac_ovqat_ishlatildi(orr.staff_id, orr.tur, v_oy) as sarf
        from ov_rol orr
        left join rbac_staff_limit sl on sl.staff_id = orr.staff_id and sl.kalit = 'ovqat:' || orr.tur
        left join ov_umumiy u on u.staff_id = orr.staff_id
    ),
    ov_qator as (
      select oe.staff_id, oe.tur,
             jsonb_build_object(
               'kalit',          'ovqat:' || oe.tur,
               'turi',           'ovqat',
               'account_id',     ov.id,
               'code',           ov.code,
               'name',           ov.name,
               'tur',            oe.tur,
               'rol_limit',      case when oe.rol_cheksiz then null else oe.rol_lim end,
               'hodim_limit',    oe.override_lim,
               'effektiv_limit', oe.eff_lim,
               'sarf',           oe.sarf,
               'qoldi',          case when oe.eff_lim is null then null else oe.eff_lim - oe.sarf end,
               'override',       oe.has_override,
               'umumiy_rejim',   oe.umumiy_on
             ) as qator
        from ov_eff oe
        cross join ov_modda ov
    ),
    modda_agg as (
      select staff_id, jsonb_agg(qator order by code) as arr
        from modda_qator
       group by staff_id
    ),
    ov_agg as (
      select staff_id,
             jsonb_agg(qator order by case tur when 'obed' then 1 when 'zavtrak' then 2 when 'kechki' then 3 else 4 end) as arr
        from ov_qator
       group by staff_id
    ),
    umumiy_agg as (
      select hm.staff_id,
             jsonb_build_object(
               'bor',   (u.staff_id is not null),
               'limit', u.limit_uzs,
               'sarf',  coalesce(s.sarf, 0),
               'qoldi', case when u.staff_id is null or u.limit_uzs is null then null
                             else u.limit_uzs - coalesce(s.sarf, 0) end
             ) as obj
        from hodim_meta hm
        left join ov_umumiy u on u.staff_id = hm.staff_id
        left join lateral (
          select coalesce(sum(rbac_ovqat_ishlatildi(hm.staff_id, t.tur, v_oy)), 0) as sarf
            from unnest(array['obed', 'zavtrak', 'kechki']) as t(tur)
        ) s on true
    )
    select jsonb_build_object(
      'ok', true,
      'oy', to_char(v_oy, 'YYYY-MM'),
      'hodimlar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'staff_id',     hm.staff_id,
                 'toliq_nom',    hm.nom,
                 'lavozim',      hm.lavozim,
                 'filial_nom',   sf.filial_nom,
                 'rollar',       hm.rollar,
                 'qatorlar',     coalesce(ma.arr, '[]'::jsonb) || coalesce(oa.arr, '[]'::jsonb),
                 'ovqat_umumiy', ua.obj
               ) order by hm.nom)
          from hodim_meta hm
          join staff_filial sf on sf.staff_id = hm.staff_id
          left join modda_agg  ma on ma.staff_id = hm.staff_id
          left join ov_agg     oa on oa.staff_id = hm.staff_id
          left join umumiy_agg ua on ua.staff_id = hm.staff_id
      ), '[]'::jsonb)
    )
  );
end
$fn$;

revoke all on function standart_hodim_limitlar(uuid, date) from public, anon;
grant execute on function standart_hodim_limitlar(uuid, date) to authenticated;

comment on function standart_hodim_limitlar(uuid, date) is
  '"Hodim bo''yicha xarajatlar" bo''limi: kamida bitta rolga ega har hodim (ixtiyoriy filial '
  'filtri) x har limit qatori (modda YOKI ovqat:obed/zavtrak/kechki) — rol limiti, hodim '
  'darajasidagi override (rbac_staff_limit), effektiv limit, shu oy sarfi/qoldig''i + '
  '''ovqat_umumiy'' (jami ovqat override holati). Ruxsat yo''q bo''lsa exception EMAS — '
  '{ok:false, kod:''ruxsat''}. Ruxsat: standart_page_ok().';


-- #####################################################################
-- ##  7-BO'LIM — standart_hodim_limit_set(...) — YOZISH RPC          ##
-- ---------------------------------------------------------------------
-- p_limit not null -> override (numeric); p_limit null + p_cheksiz=true ->
-- override CHEKSIZ (qator bor, limit_uzs null); p_limit null + p_cheksiz=false
-- -> override o'chiriladi (rol limitiga qaytadi).
-- #####################################################################

create or replace function standart_hodim_limit_set(p_staff int, p_kalit text,
                                                     p_limit numeric,
                                                     p_cheksiz boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_account uuid;
  v_tur     text;
  v_ok_role boolean := false;
begin
  if not standart_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  if p_staff is null or p_kalit is null then
    raise exception 'Hodim/kalit tanlanmadi' using errcode = '22000';
  end if;
  if not exists (select 1 from aros_staff where staff_id = p_staff) then
    raise exception 'Hodim topilmadi: %', p_staff using errcode = '22023';
  end if;
  if p_limit is not null and p_limit <= 0 then
    raise exception 'Limit musbat bo''lishi kerak (bo''sh/cheksiz belgi bilan cheksiz qo''yiladi)'
      using errcode = '22000';
  end if;

  -- kalit shakli (jadval CHECK'i bilan bir xil, aniq xato xabari uchun bu yerda ham).
  if p_kalit ~ '^modda:[0-9a-fA-F-]{36}$' then
    v_account := substring(p_kalit from 7)::uuid;
  elsif p_kalit in ('ovqat:obed', 'ovqat:zavtrak', 'ovqat:kechki', 'ovqat:umumiy') then
    v_tur := substring(p_kalit from 7);
  else
    raise exception 'Kalit shakli notogri (modda:<uuid> yoki ovqat:obed|zavtrak|kechki|umumiy kerak)'
      using errcode = '22000';
  end if;

  -- MODDA kaliti — shu modda hodimning (rol orqali, yoki admin-bog'langan hodim uchun
  -- hamma xarajat moddasi) ro'yxatida bo'lishi shart.
  if v_account is not null then
    select exists (
      select 1
        from rbac_staff_role sr
        join rbac_role_modda rm on rm.role_id = sr.role_id
        join accounts a on a.id = rm.account_id and a.type = 'xarajat' and not coalesce(a.ovqat_modda, false)
       where sr.staff_id = p_staff and rm.account_id = v_account
      union all
      select 1
        from aros_staff s
        join rbac_user_role ur on ur.user_id = s.user_id
        join rbac_role r on r.id = ur.role_id and r.is_active
        join rbac_role_modda rm on rm.role_id = ur.role_id
        join accounts a on a.id = rm.account_id and a.type = 'xarajat' and not coalesce(a.ovqat_modda, false)
       where s.staff_id = p_staff and s.user_id is not null and rm.account_id = v_account
      union all
      select 1
        from aros_staff s
        join profiles p on p.id = s.user_id
        join accounts a on a.id = v_account and a.type = 'xarajat' and not coalesce(a.ovqat_modda, false)
       where s.staff_id = p_staff and s.user_id is not null and p.role = 'admin'
    ) into v_ok_role;
    if not v_ok_role then
      raise exception 'Bu modda hodimning rollarida yoq' using errcode = '22000';
    end if;
  end if;

  -- OVQAT kaliti — turga (yoki 'umumiy' uchun kamida bitta turga) hodim ruxsatli bo'lishi shart.
  if v_tur is not null and v_tur <> 'umumiy' then
    if not (v_tur = any(rbac_staff_ovqat(p_staff))) then
      raise exception 'Bu ovqat turi hodim rolida yoq' using errcode = '22000';
    end if;
  end if;
  if v_tur = 'umumiy' and cardinality(rbac_staff_ovqat(p_staff)) = 0 then
    raise exception 'Hodimning hech qaysi ovqat turiga ruxsati yoq' using errcode = '22000';
  end if;

  if p_limit is null and not coalesce(p_cheksiz, false) then
    delete from rbac_staff_limit where staff_id = p_staff and kalit = p_kalit;
    return jsonb_build_object('ok', true, 'holat', 'rol_limitiga_qaytdi');
  end if;

  insert into rbac_staff_limit (staff_id, kalit, limit_uzs, updated_by, updated_at)
  values (p_staff, p_kalit, p_limit, auth.uid(), now())
  on conflict (staff_id, kalit) do update
    set limit_uzs = excluded.limit_uzs, updated_by = excluded.updated_by, updated_at = now();

  return jsonb_build_object('ok', true, 'holat', case when p_limit is null then 'cheksiz' else 'saqlandi' end);
end
$fn$;

revoke all on function standart_hodim_limit_set(int, text, numeric, boolean) from public, anon;
grant execute on function standart_hodim_limit_set(int, text, numeric, boolean) to authenticated;

comment on function standart_hodim_limit_set(int, text, numeric, boolean) is
  'Hodim darajasidagi limit override qo''yish/o''chirish (rolni o''zgartirmasdan). p_limit + '
  'raqam -> override; p_limit null + p_cheksiz -> override CHEKSIZ; p_limit null + '
  '!p_cheksiz -> override o''chiriladi (rol limitiga qaytadi). Kalit shakli va hodimning '
  'shu modda/ovqat turiga rol orqali huquqi tekshiriladi. Ruxsat: standart_page_ok() '
  '({ok:false,kod:''ruxsat''}, exception emas).';

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  8-BO'LIM — YAKUNIY TEKSHIRUV (self-check select)               ##
-- #####################################################################

select 'rbac_staff_limit (jadval)' as obyekt,
       case when to_regclass('public.rbac_staff_limit') is not null
            then '✅ yaratildi' else '❌ yaratilmadi' end as holat
union all
select 'rbac_ovqat_umumiy_qoldi(int,date)',
       case when to_regprocedure('public.rbac_ovqat_umumiy_qoldi(int,date)') is not null
            then '✅ yaratildi' else '❌ yaratilmadi' end
union all
select 'rbac_limit_modda(uuid,uuid)',
       case when to_regprocedure('public.rbac_limit_modda(uuid,uuid)') is not null
            then '✅ yangilandi' else '❌' end
union all
select 'rbac_limit_ovqat_staff(int,text)',
       case when to_regprocedure('public.rbac_limit_ovqat_staff(int,text)') is not null
            then '✅ yangilandi' else '❌' end
union all
select 'xarajat_saqlash_ovqat(jsonb)',
       case when to_regprocedure('public.xarajat_saqlash_ovqat(jsonb)') is not null
            then '✅ yangilandi' else '❌' end
union all
select 'standart_hodim_limitlar(uuid,date)',
       case when to_regprocedure('public.standart_hodim_limitlar(uuid,date)') is not null
            then '✅ yaratildi' else '❌ yaratilmadi' end
union all
select 'standart_hodim_limit_set(int,text,numeric,boolean)',
       case when to_regprocedure('public.standart_hodim_limit_set(int,text,numeric,boolean)') is not null
            then '✅ yaratildi' else '❌ yaratilmadi' end;
