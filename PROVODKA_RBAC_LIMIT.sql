-- =====================================================================
-- PROVODKA_RBAC_LIMIT.sql
-- Rolga OYLIK LIMIT (som) qo'shiladi: har xarajat moddasi va har ovqat
-- turi uchun alohida limit. null = cheksiz (avvalgidek). Hodimning oy
-- davomida shu moddaga yozgan xarajatlari yig'indisi limitdan oshsa —
-- qattiq blok (42501). Ovqatda limit YEYUVCHI hodimga tegishli (kim
-- yozganidan qat'i nazar) — rbac_staff_ovqat/rbac_limit_ovqat_staff bilan
-- BIR XIL manba: aros_staff.user_id bog'langan bo'lsa userning
-- rbac_user_role rollari, aks holda rbac_staff_role.
-- ---------------------------------------------------------------------
-- ## RUN TARTIBI (Asilbek) — bo'limlarni tartib bilan
--   0-BO'LIM — old shart tekshiruvi (faqat select)
--   1-BO'LIM — rbac_role_modda.limit_uzs / rbac_role_ovqat.limit_uzs ustuni
--   2-BO'LIM — samarali limit funksiyalari (rbac_limit_modda,
--              rbac_limit_ovqat_staff, rbac_modda_ishlatildi, rbac_ovqat_ishlatildi)
--   3-BO'LIM — SERVER GUARD: trg_rbac_limit_entry_line (YANGI, alohida trigger)
--   4-BO'LIM — xarajat_saqlash_ovqat(jsonb) — ovqat limiti tekshiruvi qo'shiladi
--   5-BO'LIM — rbac_role_save(jsonb) — moddalar/ovqat elementlariga limit qabul qiladi
--   6-BO'LIM — rbac_royxat() — modda_limit / ovqat_limit qo'shiladi
--   7-BO'LIM — klient RPC'lari: rbac_my_limitlar(), ovqat_limit_qoldiq(int[])
--   8-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)
--
-- ## OLD SHART (bazada bo'lishi kerak)
--   PROVODKA_RBAC.sql         -> rbac_role, rbac_role_modda, rbac_role_ovqat,
--                                 rbac_user_role, rbac_my(uuid), rbac_modda_ok,
--                                 rbac_guard_entry_line/trg_rbac_guard_entry_line,
--                                 rbac_role_save(jsonb)
--   PROVODKA_RBAC_STAFF.sql   -> rbac_staff_role, xarajat_saqlash_ovqat(jsonb)
--                                 (kechki bilan), rbac_royxat() (staff_soni bilan)
--   PROVODKA_RBAC_LINK.sql    -> aros_staff.user_id, rbac_staff_ovqat(int)
--                                 (bog'langan bo'lsa user manbai)
--   PROVODKA_OVQAT.sql / PROVODKA_OVQAT_KECHKI.sql -> entry_ovqat (kechki bilan)
--   PROVODKA_V7.sql           -> limit_guard_entry_line (filial-modda limiti —
--                                 bu faylga tegishli EMAS, faqat regressiya
--                                 tekshiruvi uchun ma'lumot)
--
-- ## QOIDALAR (CLAUDE.md, buzilmadi)
--   * anonim do bloki YO'Q — har do bloki NOMLANGAN teg bilan.
--   * har funksiya tanasi NOMLANGAN dollar-teg bilan o'raladi.
--   * izohda dollar-qavs (yonma-yon ikkita $) YO'Q.
--   * hammasi additive: eski jadval/ustun/funksiya imzosi buzilmaydi
--     (rbac_role_save, rbac_royxat, xarajat_saqlash_ovqat — uchalasi ham
--     imzo bo'yicha AYNAN saqlandi, faqat tana kengaydi).
--   * idempotent: qayta RUN qilish xavfsiz.
--   * ichki hisoblash funksiyalari (rbac_limit_modda va sh.k.) authenticated'ga
--     ham GRANT qilinmaydi — faqat boshqa SECURITY DEFINER funksiya/trigger
--     ichidan chaqiriladi (rbac_my(uuid) bilan bir xil naqsh).
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (faqat select)                 ##
-- #####################################################################

do $rbac_limit_pre$
begin
  if to_regclass('public.rbac_role_modda') is null then
    raise exception 'rbac_role_modda jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_role_ovqat') is null then
    raise exception 'rbac_role_ovqat jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_user_role') is null then
    raise exception 'rbac_user_role jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_staff_role') is null then
    raise exception 'rbac_staff_role jadvali yoq — avval PROVODKA_RBAC_STAFF.sql ni bajaring';
  end if;
  if to_regclass('public.entry_ovqat') is null then
    raise exception 'entry_ovqat jadvali yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'aros_staff' and column_name = 'user_id'
  ) then
    raise exception 'aros_staff.user_id ustuni yoq — avval PROVODKA_RBAC_LINK.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_staff_ovqat(int)') is null then
    raise exception 'rbac_staff_ovqat(int) yoq — avval PROVODKA_RBAC_STAFF.sql / PROVODKA_RBAC_LINK.sql ni bajaring';
  end if;
  if to_regprocedure('public.xarajat_saqlash_ovqat(jsonb)') is null then
    raise exception 'xarajat_saqlash_ovqat(jsonb) yoq — avval PROVODKA_RBAC_STAFF.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_royxat()') is null then
    raise exception 'rbac_royxat() yoq — avval PROVODKA_RBAC.sql / PROVODKA_RBAC_STAFF.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_role_save(jsonb)') is null then
    raise exception 'rbac_role_save(jsonb) yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'is_admin() funksiyasi yoq — RBAC_LIMIT unga tayanadi';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.entry_line'::regclass
                    and tgname  = 'trg_rbac_guard_entry_line') then
    raise exception 'trg_rbac_guard_entry_line yoq — RBAC modda guardi orin almashgan bolishi mumkin, avval tekshiring';
  end if;

  -- rbac_royxat() staff_soni maydonini bilishi shart — bu RBAC_STAFF.sql
  -- versiyasi RUN qilinganini bildiradi (eski RBAC.sql versiyasida yoq,
  -- va bu faylning 6-BO'LIMi o'sha tananing ustiga quriladi).
  if position('staff_soni' in (select prosrc from pg_proc where proname = 'rbac_royxat' limit 1)) = 0 then
    raise exception 'rbac_royxat() da staff_soni yoq — avval PROVODKA_RBAC_STAFF.sql ni bajaring';
  end if;
end
$rbac_limit_pre$;


-- #####################################################################
-- ##  1-BO'LIM — Ustunlar: limit_uzs                                 ##
-- #####################################################################

alter table rbac_role_modda
  add column if not exists limit_uzs numeric check (limit_uzs is null or limit_uzs > 0);

comment on column rbac_role_modda.limit_uzs is
  'Oylik limit (som), shu rol + xarajat moddasi uchun. null = cheksiz. '
  'Bir hodimda bir nechta rol bo''lsa va bittasida limit yo''q (null) bo''lsa — CHEKSIZ '
  '(rbac_limit_modda ichida hisoblanadi). Boshqacha holda MAX effektiv.';

alter table rbac_role_ovqat
  add column if not exists limit_uzs numeric check (limit_uzs is null or limit_uzs > 0);

comment on column rbac_role_ovqat.limit_uzs is
  'Oylik limit (som), shu rol + ovqat turi uchun. null = cheksiz. Limit YEYUVCHI '
  'hodimga tegishli (rbac_limit_ovqat_staff — rbac_staff_ovqat bilan bir xil manba), '
  'yozuvchiga emas. Bir hodimda bir nechta rol bittasida null bo''lsa — CHEKSIZ.';


-- #####################################################################
-- ##  2-BO'LIM — Samarali limit funksiyalari                         ##
-- #####################################################################

-- 2.1 rbac_limit_modda(p_uid, p_account) — foydalanuvchining shu moddaga
--     effektiv oylik limiti. Hech qaysi rolda modda yo'q -> null (limit
--     yo'q — boshqa guard, rbac_guard_entry_line, allaqachon rad etadi).
--     Bittasida limit_uzs null (cheksiz) bo'lsa -> null. Aks holda MAX.
create or replace function rbac_limit_modda(p_uid uuid, p_account uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_cnt      int;
  v_has_null boolean;
  v_max      numeric;
begin
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
  'Rolida modda yoq -> null. Bir nechta rolda bittasi cheksiz -> null. Aks holda MAX(limit_uzs).';


-- 2.2 rbac_limit_ovqat_staff(p_staff, p_tur) — YEYUVCHI hodimning shu
--     ovqat turiga effektiv oylik limiti. rbac_staff_ovqat (PROVODKA_RBAC_LINK.sql)
--     bilan AYNAN bir xil manba tanlovi: bog'langan bo'lsa (aros_staff.user_id)
--     userning rbac_user_role rollari, aks holda hodimning rbac_staff_role
--     rollari. 🔴 Bu FAQAT limit — "ovqat turi ruxsatlimi" degan savolga
--     javob bermaydi (u rbac_staff_ovqat() da, o'zgartirilmagan).
create or replace function rbac_limit_ovqat_staff(p_staff int, p_tur text)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_user_id  uuid;
  v_cnt      int;
  v_has_null boolean;
  v_max      numeric;
begin
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
  'ICHKI: YEYUVCHI hodimning shu ovqat turiga effektiv oylik limiti. Manba rbac_staff_ovqat '
  '(PROVODKA_RBAC_LINK.sql) bilan bir xil: bog''langan bo''lsa user rollari, aks holda hodim rollari.';


-- 2.3 rbac_modda_ishlatildi(p_uid, p_account, p_oy) — foydalanuvchining
--     shu oyda (kalendar, Toshkent) shu moddaga yozgan xarajatlari yig'indisi.
--     Egasi entry.created_by orqali (matn, uuid shaklida bo'lishi kerak —
--     PROVODKA_IJROCHI.sql naqshi). status posted/pending, o'chirilmagan.
--     ⚠️ entry.created_by ustun turi noma'lum (uuid yoki text) — shuning
--     uchun expression index qoyilmaydi, faqat entry(entry_date) yetarli.
create or replace function rbac_modda_ishlatildi(p_uid uuid, p_account uuid, p_oy date)
returns numeric
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(sum(el.debit), 0)
    from entry_line el
    join entry e on e.id = el.entry_id
   where el.account_id = p_account
     and el.debit > 0
     and e.is_deleted = false
     and e.status in ('posted', 'pending')
     and date_trunc('month', e.entry_date) = date_trunc('month', p_oy)
     and (to_jsonb(e) ->> 'created_by') = p_uid::text;
$fn$;

revoke all on function rbac_modda_ishlatildi(uuid, uuid, date) from public, anon, authenticated;

comment on function rbac_modda_ishlatildi(uuid, uuid, date) is
  'ICHKI: foydalanuvchi (created_by) tomonidan shu oy (p_oy oyi, kalendar) shu moddaga '
  'yozilgan (posted/pending, ochirilmagan) xarajatlar yigindisi.';


-- 2.4 rbac_ovqat_ishlatildi(p_staff, p_tur, p_oy) — hodimning shu oyda
--     yeyilgan (staff_id, tur) ovqat summasi. kun ustunidan (entry.entry_date
--     emas — ovqat uchun kun alohida ustun).
create or replace function rbac_ovqat_ishlatildi(p_staff int, p_tur text, p_oy date)
returns numeric
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(sum(eo.narx), 0)
    from entry_ovqat eo
    join entry e on e.id = eo.entry_id
   where eo.staff_id = p_staff
     and eo.tur = p_tur
     and eo.is_deleted = false
     and e.is_deleted = false
     and e.status in ('posted', 'pending')
     and date_trunc('month', eo.kun) = date_trunc('month', p_oy);
$fn$;

revoke all on function rbac_ovqat_ishlatildi(int, text, date) from public, anon, authenticated;

comment on function rbac_ovqat_ishlatildi(int, text, date) is
  'ICHKI: hodim (staff_id) shu oy (p_oy oyi, kalendar, entry_ovqat.kun boyicha) shu ovqat '
  'turida yegan (posted/pending, ochirilmagan) summasi.';


-- #####################################################################
-- ##  3-BO'LIM — SERVER GUARD: xarajat moddasi OYLIK LIMITI (YANGI)  ##
-- ---------------------------------------------------------------------
-- Mavjud trg_rbac_guard_entry_line (rolda modda bormi) va
-- trg_perm_guard_entry_line (pul/kassa) ga TEGILMAYDI — bu YANGI, ALOHIDA
-- trigger, AFTER INSERT (rbac_guard BEFORE dan farqli — yangi satr
-- yigindiga ALLAQACHON kirgan bolishi kerak, PROVODKA_V7.sql
-- limit_guard_entry_line bilan bir xil naqsh).
-- #####################################################################

create or replace function rbac_limit_entry_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_type    text;
  v_date    date;
  v_status  text;
  v_deleted boolean;
  v_raw     text;
  v_ega     uuid;
  v_lim     numeric;
  v_used    numeric;
  v_lbl     text;
begin
  if coalesce(new.debit, 0) <= 0 then
    return new;
  end if;

  select a.type into v_type from accounts a where a.id = new.account_id;
  if v_type is distinct from 'xarajat' then
    return new;
  end if;

  if auth.uid() is null then
    return new;                                     -- service_role (n8n)
  end if;
  if is_admin() then
    return new;
  end if;

  select e.entry_date, coalesce(e.status, 'posted'), coalesce(e.is_deleted, false),
         (to_jsonb(e) ->> 'created_by')
    into v_date, v_status, v_deleted, v_raw
    from entry e where e.id = new.entry_id;
  if not found then
    return new;
  end if;
  if v_deleted or v_status not in ('posted', 'pending') then
    return new;
  end if;

  -- Egasi: entry.created_by (matn/uuid shaklida bo'lishi mumkin,
  -- PROVODKA_IJROCHI.sql naqshi). Bosh bo'lsa -> auth.uid(). uuid shaklida
  -- EMAS (masalan 'aros_sync') bo'lsa -> bu guard sukut qiladi (fail-open
  -- EMAS — egasi shunchaki nomalum, boshqa guardlar baribir amal qiladi).
  v_raw := nullif(btrim(coalesce(v_raw, '')), '');
  if v_raw is null then
    v_ega := auth.uid();
  elsif v_raw ~ '^[0-9a-fA-F-]{36}$' then
    v_ega := v_raw::uuid;
  else
    return new;
  end if;

  -- ONGLI QAROR (Asilbek, 2026-08-29): "Ruxsat sorovi" (PROVODKA_RUXSAT_SOROV.sql)
  -- orqali yozilgan xarajatda modda hodimning OZ rolida YOQ (aynan shu sabab
  -- sorov yozilgan) -> rbac_limit_modda null -> oylik limit TEKSHIRILMAYDI.
  -- Bu bug emas: u yerda limit orniga tasdiqlovchi odamning qarori turadi
  -- (har sorov alohida, summa/modda tasdiqlovchi koradi). Ozgartirilmasin.
  v_lim := rbac_limit_modda(v_ega, new.account_id);
  if v_lim is null then
    return new;                                      -- limit qoyilmagan yoki cheksiz
  end if;

  -- AFTER INSERT — yangi satr yigindiga ALLAQACHON kirgan (rbac_modda_ishlatildi
  -- ichida shu satr ham hisoblanadi).
  v_used := rbac_modda_ishlatildi(v_ega, new.account_id, v_date);
  if v_used > v_lim then
    select coalesce(a.code || ' ' || a.name, new.account_id::text) into v_lbl
      from accounts a where a.id = new.account_id;
    raise exception 'Oylik limit oshdi: "%" — limit %, shu oyda ishlatildi % (shu bilan)',
      v_lbl, round(v_lim), round(v_used)
      using errcode = '42501';
  end if;

  return new;
end
$fn$;

revoke all on function rbac_limit_entry_line() from public, anon;

drop trigger if exists trg_rbac_limit_entry_line on entry_line;
create trigger trg_rbac_limit_entry_line
  after insert on entry_line
  for each row execute function rbac_limit_entry_line();

comment on function rbac_limit_entry_line() is
  'YANGI (trg_rbac_guard_entry_line dan ALOHIDA): rbac_role_modda.limit_uzs boyicha OYLIK '
  'limitni majburlaydi (egasi entry.created_by). service_role (n8n) va admin otadi. '
  'Ovqat xarajati (xarajat_saqlash_ovqat) ham Dt xarajat satri yozgani uchun bu trigger '
  'ham ishlaydi — odatda ovqat moddasiga bu limit emas, tur boyicha limit (4-BO''LIM) '
  'qoyiladi, lekin ovqat moddasiga ham limit qoyilgan bolsa ATAYLAB amal qiladi.';


-- #####################################################################
-- ##  4-BO'LIM — xarajat_saqlash_ovqat(jsonb) — OVQAT limiti qoshiladi##
-- ---------------------------------------------------------------------
-- 🔴 PROVODKA_RBAC_STAFF.sql (193-439) dagi ENG OXIRGI tananing VERBATIM
--    nusxasi + YEYUVCHI ruxsati tekshiruvidan (rbac_staff_ovqat) DARHOL
--    KEYIN, entry insertdan OLDIN (1-o'tish, faqat tekshiruv), limit
--    tekshiruvi qo'shiladi: shu (staff, tur) uchun shu so'rovdagi narx +
--    shu oyda avval yeyilgani (rbac_ovqat_ishlatildi) limitdan (agar null
--    bo'lmasa) oshsa — rad.
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
  'ikkalasi ham o''tishi shart. YANGI (PROVODKA_RBAC_LIMIT.sql): YEYUVCHI hodimning OYLIK ovqat limiti '
  '(rbac_limit_ovqat_staff) — entry insertdan oldin, hech narsa yozilmasdan tekshiriladi. '
  'Tahrirlash taqiq (PROVODKA_OVQAT.sql 8-BO''LIM).';


-- #####################################################################
-- ##  5-BO'LIM — rbac_role_save(jsonb) — moddalar/ovqat limit qabul  ##
-- ---------------------------------------------------------------------
-- 🔴 PROVODKA_RBAC.sql (613-702) dagi tana asosida — imzo VA hamma
--    tekshiruv (nom, amallar, moddalar turi/type, ovqat whitelist) VERBATIM
--    saqlanadi. O'zgargani: `moddalar`/`ovqat` massivi elementlari ESKI
--    shakl (uuid/text matn) YOKI YANGI shakl ({id,limit} / {tur,limit})
--    bo'lishi mumkin — ikkalasi ham qabul qilinadi. Eski shaklda limit
--    har doim null (cheksiz, o'zgarishsiz xatti-harakat).
-- #####################################################################

create or replace function rbac_role_save(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $rbac_role_save$
declare
  v_id       uuid;
  v_nom      text;
  v_izoh     text;
  v_active   boolean;
  v_amallar  text[];
  v_moddalar uuid[];
  v_ovqat    text[];
  v_bad      int;
  v_dup      uuid;

  -- YANGI (PROVODKA_RBAC_LIMIT.sql): parallel limit massivlari (generate_subscripts
  -- bilan v_moddalar/v_ovqat ga index boyicha moslashtiriladi)
  v_modda_limit numeric[];
  v_ovqat_limit numeric[];
  el         jsonb;
  v_m_id     uuid;
  v_m_lim    numeric;
  v_o_tur    text;
  v_o_lim    numeric;
begin
  if not is_admin() then
    raise exception 'Faqat admin rol yarata/tahrirlay oladi' using errcode = '42501';
  end if;

  v_id   := nullif(p_data ->> 'id', '')::uuid;
  v_nom  := nullif(btrim(p_data ->> 'nom'), '');
  v_izoh := nullif(p_data ->> 'izoh', '');
  v_active := coalesce((p_data ->> 'is_active')::boolean, true);

  if v_nom is null then
    raise exception 'Rol nomi kerak' using errcode = '22000';
  end if;

  select id into v_dup from rbac_role
   where lower(btrim(nom)) = lower(v_nom) and id is distinct from v_id;
  if v_dup is not null then
    raise exception 'Bu nomda rol allaqachon bor: %', v_nom using errcode = '23505';
  end if;

  select coalesce(array_agg(distinct x), '{}') into v_amallar
    from jsonb_array_elements_text(coalesce(p_data -> 'amallar', '[]'::jsonb)) x;
  select count(*) into v_bad from unnest(v_amallar) x
   where not (x = any(perm_pages()) or x = 'hodim');
  if v_bad > 0 then
    raise exception 'Noma''lum amal kaliti(lar) bor (perm_pages() yoki hodim bo''lishi kerak)'
      using errcode = '22000';
  end if;

  -- 🔴 YANGI: har element {id, limit} (obyekt) yoki xom uuid/text (eski)
  --    bo'lishi mumkin. el ->> 'id' obyektda ishlaydi, boshqasida null
  --    qaytaradi (jsonb operator qoidasi) -> el #>> '{}' bilan xom qiymat
  --    olinadi (skalyar uchun to'g'ri matn, obyekt uchun butun JSON —
  --    keyingi ::uuid cast xato bersa aniq xabar bilan rad etadi).
  v_moddalar := '{}'::uuid[];
  v_modda_limit := '{}'::numeric[];
  for el in select * from jsonb_array_elements(coalesce(p_data -> 'moddalar', '[]'::jsonb))
  loop
    v_m_id := nullif(coalesce(el ->> 'id', el #>> '{}'), '')::uuid;
    if v_m_id is null then
      raise exception 'Modda ro''yxatida bo''sh yoki noto''g''ri id bor' using errcode = '22000';
    end if;
    v_m_lim := nullif(el ->> 'limit', '')::numeric;
    if v_m_lim is not null and v_m_lim <= 0 then
      raise exception 'Modda limiti musbat bo''lishi kerak (bo''sh qoldirilsa — cheksiz)' using errcode = '22000';
    end if;
    if v_m_id = any(v_moddalar) then
      continue;   -- takror -> jimgina tashlanadi (eski array_agg(distinct) xatti-harakati saqlanadi)
    end if;
    v_moddalar    := v_moddalar || v_m_id;
    v_modda_limit := v_modda_limit || v_m_lim;
  end loop;

  select count(*) into v_bad from unnest(v_moddalar) x
   where not exists (select 1 from accounts a where a.id = x and a.type = 'xarajat');
  if v_bad > 0 then
    raise exception 'Noma''lum xarajat moddasi id bor' using errcode = '22000';
  end if;

  v_ovqat := '{}'::text[];
  v_ovqat_limit := '{}'::numeric[];
  for el in select * from jsonb_array_elements(coalesce(p_data -> 'ovqat', '[]'::jsonb))
  loop
    v_o_tur := nullif(coalesce(el ->> 'tur', el #>> '{}'), '');
    if v_o_tur is null then
      raise exception 'Ovqat ro''yxatida bo''sh tur bor' using errcode = '22000';
    end if;
    v_o_lim := nullif(el ->> 'limit', '')::numeric;
    if v_o_lim is not null and v_o_lim <= 0 then
      raise exception 'Ovqat limiti musbat bo''lishi kerak (bo''sh qoldirilsa — cheksiz)' using errcode = '22000';
    end if;
    if v_o_tur = any(v_ovqat) then
      continue;   -- takror -> jimgina tashlanadi (eski xatti-harakat)
    end if;
    v_ovqat       := v_ovqat || v_o_tur;
    v_ovqat_limit := v_ovqat_limit || v_o_lim;
  end loop;

  select count(*) into v_bad from unnest(v_ovqat) x
   where x not in ('obed','zavtrak','kechki');
  if v_bad > 0 then
    raise exception 'Noma''lum ovqat turi bor (obed|zavtrak|kechki kerak)' using errcode = '22000';
  end if;

  if v_id is null then
    insert into rbac_role (nom, izoh, is_active, updated_by)
    values (v_nom, v_izoh, v_active, auth.uid())
    returning id into v_id;
  else
    update rbac_role
       set nom = v_nom, izoh = v_izoh, is_active = v_active,
           updated_at = now(), updated_by = auth.uid()
     where id = v_id;
    if not found then
      raise exception 'Rol topilmadi: %', v_id using errcode = '22023';
    end if;
  end if;

  delete from rbac_role_amal where role_id = v_id;
  insert into rbac_role_amal (role_id, amal)
    select v_id, x from unnest(v_amallar) x;

  delete from rbac_role_modda where role_id = v_id;
  insert into rbac_role_modda (role_id, account_id, limit_uzs)
    select v_id, v_moddalar[i], v_modda_limit[i]
      from generate_subscripts(v_moddalar, 1) i;

  delete from rbac_role_ovqat where role_id = v_id;
  insert into rbac_role_ovqat (role_id, tur, limit_uzs)
    select v_id, v_ovqat[i], v_ovqat_limit[i]
      from generate_subscripts(v_ovqat, 1) i;

  return jsonb_build_object('id', v_id);
end
$rbac_role_save$;

revoke all on function rbac_role_save(jsonb) from public, anon;
grant execute on function rbac_role_save(jsonb) to authenticated;

comment on function rbac_role_save(jsonb) is
  'Admin: rol yaratish/tahrirlash, bolalarni (amallar/moddalar/ovqat) tolik almashtiradi. '
  'moddalar/ovqat elementlari eski (xom uuid/text) yoki yangi ({id,limit}/{tur,limit}) '
  'shaklda bolishi mumkin — limit_uzs shundan olinadi (PROVODKA_RBAC_LIMIT.sql).';


-- #####################################################################
-- ##  6-BO'LIM — rbac_royxat() — modda_limit / ovqat_limit qoshiladi ##
-- ---------------------------------------------------------------------
-- 🔴 PROVODKA_RBAC_STAFF.sql (staff_soni bilan, ENG OXIRGI) dagi tana
--    asosida — barcha eski maydonlar VERBATIM saqlanadi, faqat har rolga
--    modda_limit ({account_id: limit}) va ovqat_limit ({tur: limit})
--    qoshiladi (faqat limit_uzs NOT NULL bolgan qatorlar).
-- #####################################################################

create or replace function rbac_royxat()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $rbac_royxat$
begin
  if not is_admin() then
    raise exception 'Faqat admin rol ro''yxatini ko''ra oladi' using errcode = '42501';
  end if;

  return (
    with rr as (
      select r.id, r.nom, r.izoh, r.is_active,
        coalesce((select jsonb_agg(ra.amal order by ra.amal)
                    from rbac_role_amal ra where ra.role_id = r.id), '[]'::jsonb) as amallar,
        coalesce((select jsonb_agg(rm.account_id)
                    from rbac_role_modda rm where rm.role_id = r.id), '[]'::jsonb) as moddalar,
        coalesce((select jsonb_agg(ro.tur order by ro.tur)
                    from rbac_role_ovqat ro where ro.role_id = r.id), '[]'::jsonb) as ovqat,
        (select count(*) from rbac_user_role ur where ur.role_id = r.id)::int as user_soni,
        (select count(*) from rbac_staff_role sr where sr.role_id = r.id)::int as staff_soni,
        coalesce((select jsonb_object_agg(rm.account_id::text, rm.limit_uzs)
                    from rbac_role_modda rm
                   where rm.role_id = r.id and rm.limit_uzs is not null), '{}'::jsonb) as modda_limit,
        coalesce((select jsonb_object_agg(ro.tur, ro.limit_uzs)
                    from rbac_role_ovqat ro
                   where ro.role_id = r.id and ro.limit_uzs is not null), '{}'::jsonb) as ovqat_limit
        from rbac_role r
    )
    select jsonb_build_object(
      'rollar', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', id, 'nom', nom, 'izoh', izoh, 'is_active', is_active,
          'amallar', amallar, 'moddalar', moddalar, 'ovqat', ovqat,
          'user_soni', user_soni, 'staff_soni', staff_soni,
          'modda_limit', modda_limit, 'ovqat_limit', ovqat_limit)
          order by nom)
        from rr), '[]'::jsonb),
      'amal_royxati', to_jsonb(perm_pages() || array['hodim']),
      'moddalar', coalesce((
        select jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name) order by a.code)
          from accounts a
         where a.type = 'xarajat' and coalesce(a.is_active, true)), '[]'::jsonb)
    )
  );
end
$rbac_royxat$;

revoke all on function rbac_royxat() from public, anon;
grant execute on function rbac_royxat() to authenticated;

comment on function rbac_royxat() is
  'Admin: rollar royxati (amallar/moddalar/ovqat + user_soni/staff_soni) + tanlov royxatlari. '
  'Har rolga modda_limit/ovqat_limit ham qoshildi (PROVODKA_RBAC_LIMIT.sql, faqat limit qoyilganlar).';


-- #####################################################################
-- ##  7-BO'LIM — Klient RPC'lari: limit/qoldiq korish                ##
-- #####################################################################

-- 7.1 rbac_my_limitlar() — chaqiruvchining oz limitlari (joriy Toshkent oyi).
--     Admin -> [] (cheklovsiz, korsatiladigan narsa yoq).
create or replace function rbac_my_limitlar()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_oy  date := (now() at time zone 'Asia/Tashkent')::date;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '28000';
  end if;
  if is_admin() then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'account_id', x.account_id,
        'limit',      x.lim,
        'ishlatildi', x.used,
        'qoldi',      x.lim - x.used
      ) order by x.code)
    from (
      select distinct rm.account_id, a.code,
             rbac_limit_modda(v_uid, rm.account_id) as lim,
             rbac_modda_ishlatildi(v_uid, rm.account_id, v_oy) as used
        from rbac_user_role ur
        join rbac_role r on r.id = ur.role_id and r.is_active
        join rbac_role_modda rm on rm.role_id = ur.role_id
        join accounts a on a.id = rm.account_id
       where ur.user_id = v_uid
    ) x
    where x.lim is not null
  ), '[]'::jsonb);
end
$fn$;

revoke all on function rbac_my_limitlar() from public, anon;
grant execute on function rbac_my_limitlar() to authenticated;

comment on function rbac_my_limitlar() is
  'Chaqiruvchining (auth.uid()) oz rollaridagi limit qoyilgan xarajat moddalari: joriy Toshkent '
  'oyidagi limit/ishlatildi/qoldi. Admin -> bosh massiv (cheklovsiz).';


-- 7.2 ovqat_limit_qoldiq(p_staff) — berilgan (yoki hamma faol) hodimlar
--     uchun 3 tur boyicha limit/ishlatildi/qoldi (joriy Toshkent oyi).
create or replace function ovqat_limit_qoldiq(p_staff int[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_oy date := (now() at time zone 'Asia/Tashkent')::date;
begin
  if auth.uid() is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '28000';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'staff_id',   x.staff_id,
        'tur',        x.tur,
        'limit',      x.lim,
        'ishlatildi', x.used,
        'qoldi',      x.lim - x.used
      ) order by x.staff_id, x.tur)
    from (
      select s.staff_id, t.tur,
             rbac_limit_ovqat_staff(s.staff_id, t.tur) as lim,
             rbac_ovqat_ishlatildi(s.staff_id, t.tur, v_oy) as used
        from aros_staff s
        cross join unnest(array['obed','zavtrak','kechki']) as t(tur)
       where s.is_active
         and (p_staff is null or s.staff_id = any(p_staff))
    ) x
    where x.lim is not null
  ), '[]'::jsonb);
end
$fn$;

revoke all on function ovqat_limit_qoldiq(int[]) from public, anon;
grant execute on function ovqat_limit_qoldiq(int[]) to authenticated;

comment on function ovqat_limit_qoldiq(int[]) is
  'Berilgan (yoki hamma faol) hodimlar x 3 ovqat turi boyicha limit qoyilgan kombinatsiyalar: '
  'joriy Toshkent oyidagi limit/ishlatildi/qoldi. p_staff null -> hamma faol hodim.';


-- #####################################################################
-- ##  8-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)            ##
-- #####################################################################

do $rbac_limit_check$
declare
  v_n int;
begin
  -- 8.1 Ustunlar
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'rbac_role_modda' and column_name = 'limit_uzs'
  ) then
    raise exception 'rbac_role_modda.limit_uzs ustuni yaratilmadi';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'rbac_role_ovqat' and column_name = 'limit_uzs'
  ) then
    raise exception 'rbac_role_ovqat.limit_uzs ustuni yaratilmadi';
  end if;

  -- 8.2 Funksiyalar (imzo bo'yicha)
  if to_regprocedure('public.rbac_limit_modda(uuid, uuid)') is null then
    raise exception 'rbac_limit_modda(uuid, uuid) yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_limit_ovqat_staff(int, text)') is null then
    raise exception 'rbac_limit_ovqat_staff(int, text) yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_modda_ishlatildi(uuid, uuid, date)') is null then
    raise exception 'rbac_modda_ishlatildi(uuid, uuid, date) yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_ovqat_ishlatildi(int, text, date)') is null then
    raise exception 'rbac_ovqat_ishlatildi(int, text, date) yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_limit_entry_line()') is null then
    raise exception 'rbac_limit_entry_line() yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_my_limitlar()') is null then
    raise exception 'rbac_my_limitlar() yaratilmadi';
  end if;
  if to_regprocedure('public.ovqat_limit_qoldiq(int[])') is null then
    raise exception 'ovqat_limit_qoldiq(int[]) yaratilmadi';
  end if;

  -- 8.3 YANGI trigger o'z joyidami va yoqilganmi
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.entry_line'::regclass
       and tgname  = 'trg_rbac_limit_entry_line'
       and tgenabled <> 'D'
  ) then
    raise exception 'trg_rbac_limit_entry_line ornatilmadi yoki ochirilgan';
  end if;

  -- 8.4 Eski triggerlar hamon joyida va yoqilgan (regressiya yoq)
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.entry_line'::regclass
       and tgname  = 'trg_rbac_guard_entry_line'
       and tgenabled <> 'D'
  ) then
    raise exception 'trg_rbac_guard_entry_line yoqolib qolgan yoki ochirilgan — regressiya';
  end if;
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.entry_line'::regclass
       and tgname  = 'trg_perm_guard_entry_line'
       and tgenabled <> 'D'
  ) then
    raise exception 'trg_perm_guard_entry_line yoqolib qolgan yoki ochirilgan — regressiya';
  end if;
  -- trg_limit_guard_entry_line (PROVODKA_V7.sql, filial-modda limiti) — IXTIYORIY:
  -- shu fayl uni talab qilmaydi, lekin BOR bolsa hamon yoqilgan bolishi shart.
  if exists (
    select 1 from pg_trigger
     where tgrelid = 'public.entry_line'::regclass and tgname = 'trg_limit_guard_entry_line'
  ) and not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.entry_line'::regclass
       and tgname  = 'trg_limit_guard_entry_line'
       and tgenabled <> 'D'
  ) then
    raise exception 'trg_limit_guard_entry_line ochirilgan — regressiya';
  end if;

  -- 8.5 Tana ichida yangi mantiq borligini tekshirish
  if position('limit_uzs' in (select prosrc from pg_proc where proname = 'rbac_role_save' limit 1)) = 0 then
    raise exception 'rbac_role_save() ichida limit_uzs yoq — yangilanmadi';
  end if;
  if position('rbac_limit_ovqat_staff' in (select prosrc from pg_proc where proname = 'xarajat_saqlash_ovqat' limit 1)) = 0 then
    raise exception 'xarajat_saqlash_ovqat() ichida rbac_limit_ovqat_staff chaqiruvi yoq — yangilanmadi';
  end if;
  if position('modda_limit' in (select prosrc from pg_proc where proname = 'rbac_royxat' limit 1)) = 0 then
    raise exception 'rbac_royxat() ichida modda_limit yoq — yangilanmadi';
  end if;

  -- 8.6 Grant sanity (klient RPC'lari ochiq, ichki funksiyalar yopiq)
  if not has_function_privilege('authenticated', 'public.rbac_my_limitlar()', 'execute') then
    raise exception 'rbac_my_limitlar() authenticated uchun yopiq';
  end if;
  if has_function_privilege('anon', 'public.rbac_my_limitlar()', 'execute') then
    raise exception 'rbac_my_limitlar() anon uchun ochiq qolgan';
  end if;
  if not has_function_privilege('authenticated', 'public.ovqat_limit_qoldiq(int[])', 'execute') then
    raise exception 'ovqat_limit_qoldiq(int[]) authenticated uchun yopiq';
  end if;
  if has_function_privilege('anon', 'public.ovqat_limit_qoldiq(int[])', 'execute') then
    raise exception 'ovqat_limit_qoldiq(int[]) anon uchun ochiq qolgan';
  end if;
  if has_function_privilege('authenticated', 'public.rbac_limit_modda(uuid, uuid)', 'execute') then
    raise exception 'rbac_limit_modda(uuid, uuid) authenticated uchun ochiq qolgan — ICHKI bolishi kerak';
  end if;
  if has_function_privilege('authenticated', 'public.rbac_limit_ovqat_staff(int, text)', 'execute') then
    raise exception 'rbac_limit_ovqat_staff(int, text) authenticated uchun ochiq qolgan — ICHKI bolishi kerak';
  end if;

  select count(*) into v_n from rbac_role_modda where limit_uzs is not null;
  raise notice 'RBAC_LIMIT tayyor. Limit qoyilgan (rol, modda) juftligi: % ta', v_n;
end
$rbac_limit_check$;

-- Sxema keshi — busiz yangi RPC 404 beradi.
notify pgrst, 'reload schema';
