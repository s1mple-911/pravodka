-- =====================================================================
-- PROVODKA — FOYDALANUVCHI RUXSATLARI (rol tizimi, 1-prompt)
-- ---------------------------------------------------------------------
-- Har foydalanuvchiga alohida:
--   (1) qaysi kassalarni KO'RADI      -> view_kassa_ids
--   (2) qaysi kassalarda AMALIYOT     -> op_kassa_ids  (view ichida)
--   (3) KONVERT ruxsati               -> can_convert
--   (4) qaysi SAHIFALAR ochiq         -> allowed_pages
--
-- Sozlash: admin-dev.html -> n8n webhook -> admin_set_provodka_perms()
-- Bajarilish: klient UI yashiradi + SERVER GUARD to'sadi (UI yetarli emas).
--
-- Qoidalar:
--   * idempotent — qayta-qayta ishga tushirsa bo'ladi
--   * xato holat -> RAISE EXCEPTION (jimgina o'tkazib yuborma)
--   * har view -> security_invoker = on
--   * har funksiya -> REVOKE ALL FROM public, anon + faqat kerakli rolga GRANT
--   * SECURITY DEFINER funksiyada auth guard
--
-- PROVODKA_KASSA2.sql dan KEYIN ishga tushiriladi (majburiy emas, lekin tavsiya).
-- =====================================================================


-- =====================================================================
-- 1-BO'LIM — Old shartlar
-- =====================================================================

do $$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'profiles jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regclass('public.accounts') is null then
    raise exception 'accounts jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regclass('public.entry_line') is null then
    raise exception 'entry_line jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'is_admin() funksiyasi yoq — ruxsat tizimi unga tayanadi';
  end if;
end $$;


-- =====================================================================
-- 2-BO'LIM — Jadval
-- =====================================================================

-- allowed_pages BO'SH = hamma sahifa ochiq (cheklanmagan foydalanuvchi).
-- kassa_scope 'all' = hamma kassa ko'rinadi va hammasida amaliyot mumkin.
create table if not exists user_perms (
  user_id        uuid primary key,                    -- auth.users.id (= profiles.id)
  allowed_pages  text[]      not null default '{}',
  kassa_scope    text        not null default 'all',  -- 'all' | 'list'
  view_kassa_ids uuid[]      not null default '{}',
  op_kassa_ids   uuid[]      not null default '{}',   -- HAR DOIM view_kassa_ids ichida
  can_convert    boolean     not null default true,
  updated_at     timestamptz not null default now(),
  updated_by     uuid
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_perms_scope_chk') then
    alter table user_perms
      add constraint user_perms_scope_chk check (kassa_scope in ('all','list'));
  end if;
end $$;

comment on table user_perms is
  'Provodka foydalanuvchi ruxsatlari. Yozish faqat admin_set_provodka_perms() orqali (service_role). '
  'Qatori yo''q foydalanuvchi = cheklanmagan.';

alter table user_perms enable row level security;

-- O'qish: o'zi yoki admin. Yozish uchun POLICY YO'Q — ya'ni hech kim (RPC service_role bilan ishlaydi).
drop policy if exists user_perms_read on user_perms;
create policy user_perms_read on user_perms
  for select to authenticated
  using (user_id = auth.uid() or is_admin());

revoke all on user_perms from public, anon;
grant select on user_perms to authenticated;


-- =====================================================================
-- 3-BO'LIM — Yordamchilar
-- =====================================================================

-- 3.1 Sahifa kalitlari — yagona manba (klient perms.js dagi ro'yxat bilan bir xil)
create or replace function perm_pages()
returns text[]
language sql
immutable
as $$
  select array['kassa','jurnal','professional','hisobot','balans','cashflow',
               'qarzdor','filial','valyuta','konvert','sozlama','provodka']::text[];
$$;

revoke all on function perm_pages() from public, anon;
grant execute on function perm_pages() to authenticated, service_role;

-- 3.2 perm_op_key — hisob uchun "ruxsat kaliti" (qaysi kassaga tegishli).
--     Valyuta bola-hisobi (masalan USD 56xx) o'z parentiga tegishli — ruxsat
--     kassa darajasida beriladi, valyuta darajasida emas.
--     DIQQAT: parent_id ikki ma'noli (valyuta juftligi + guruh a'zoligi), shuning
--     uchun currency <> 'UZS' sharti majburiy — aks holda hodim kassalari (54xx,
--     parent = 5400) o'z ruxsatini yo'qotib, guruh ruxsatiga bog'lanib qolardi.
create or replace function perm_op_key(p_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select case
           when a.parent_id is not null and coalesce(a.currency,'UZS') <> 'UZS'
             then a.parent_id
           else a.id
         end
    from accounts a where a.id = p_id;
$$;

revoke all on function perm_op_key(uuid) from public, anon;
grant execute on function perm_op_key(uuid) to authenticated, service_role;

-- 3.3 my_perms — o'z ruxsatlari. Qatori yo'q yoki admin -> hammasi ochiq.
create or replace function my_perms()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare p user_perms; v_admin boolean;
begin
  if auth.uid() is null then
    raise exception 'Avtorizatsiya kerak';
  end if;

  v_admin := is_admin();

  -- Admin har doim to'liq huquqli — user_perms qatori bo'lsa ham e'tiborga olinmaydi.
  if v_admin then
    return jsonb_build_object(
      'user_id',        auth.uid(),
      'allowed_pages',  '[]'::jsonb,
      'kassa_scope',    'all',
      'view_kassa_ids', '[]'::jsonb,
      'op_kassa_ids',   '[]'::jsonb,
      'can_convert',    true,
      'is_admin',       true);
  end if;

  select * into p from user_perms where user_id = auth.uid();

  if not found then
    return jsonb_build_object(
      'user_id',        auth.uid(),
      'allowed_pages',  '[]'::jsonb,
      'kassa_scope',    'all',
      'view_kassa_ids', '[]'::jsonb,
      'op_kassa_ids',   '[]'::jsonb,
      'can_convert',    true,
      'is_admin',       false);
  end if;

  return jsonb_build_object(
    'user_id',        p.user_id,
    'allowed_pages',  to_jsonb(p.allowed_pages),
    'kassa_scope',    p.kassa_scope,
    'view_kassa_ids', to_jsonb(p.view_kassa_ids),
    'op_kassa_ids',   to_jsonb(p.op_kassa_ids),
    'can_convert',    p.can_convert,
    'is_admin',       false);
end $$;

revoke all on function my_perms() from public, anon;
grant execute on function my_perms() to authenticated;

-- 3.4 perm_check_accounts — berilgan hisoblarning HAMMASIDA amaliyot mumkinmi.
--     Faqat pul hisoblari (aktiv + 5xxx) cheklanadi; xarajat/daromad/tovar erkin.
create or replace function perm_check_accounts(p_ids uuid[])
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare p user_perms;
begin
  -- auth.uid() yo'q = service_role (n8n avtomatik sinxron) -> tekshirmaymiz
  if auth.uid() is null then return true; end if;
  if is_admin() then return true; end if;

  select * into p from user_perms where user_id = auth.uid();
  if not found or p.kassa_scope <> 'list' then return true; end if;

  return not exists (
    select 1
      from accounts a
     where a.id = any(p_ids)
       and a.type = 'aktiv'
       and a.code like '5%'
       and not (perm_op_key(a.id) = any(p.op_kassa_ids))
  );
end $$;

revoke all on function perm_check_accounts(uuid[]) from public, anon;
grant execute on function perm_check_accounts(uuid[]) to authenticated, service_role;

-- 3.5 perm_can_convert — konvert ruxsati (convert_start_v2 shuni chaqiradi)
create or replace function perm_can_convert()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare p user_perms;
begin
  if auth.uid() is null then return true; end if;
  if is_admin() then return true; end if;
  select * into p from user_perms where user_id = auth.uid();
  if not found then return true; end if;
  return p.can_convert;
end $$;

revoke all on function perm_can_convert() from public, anon;
grant execute on function perm_can_convert() to authenticated, service_role;


-- =====================================================================
-- 4-BO'LIM — SERVER GUARD
-- ---------------------------------------------------------------------
-- Provodka yozuvlari RPC orqali emas, to'g'ridan-to'g'ri klientdan
-- `entry` + `entry_line` insert bilan yoziladi (provodka.html, professional.html,
-- jurnal.html tahriri). Shuning uchun yagona ishonchli to'siq — entry_line
-- ustidagi TRIGGER. U hamma yo'lni bir joyda qamrab oladi:
--   kirim / chiqim / transfer / professional / tahrir / konvert.
-- =====================================================================

create or replace function perm_guard_entry_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_lbl text;
begin
  if perm_check_accounts(array[new.account_id]) then
    return new;
  end if;

  select coalesce(a.code || ' ' || a.name, new.account_id::text)
    into v_lbl from accounts a where a.id = new.account_id;

  raise exception 'Ruxsat yoq: % kassasida amaliyot qilish huquqingiz yoq', v_lbl
    using errcode = '42501';
end $$;

revoke all on function perm_guard_entry_line() from public, anon;

drop trigger if exists trg_perm_guard_entry_line on entry_line;
create trigger trg_perm_guard_entry_line
  before insert or update of account_id on entry_line
  for each row execute function perm_guard_entry_line();

comment on function perm_guard_entry_line() is
  'user_perms bo''yicha pul hisoblarini to''sadi. service_role (n8n) va admin o''tadi.';


-- =====================================================================
-- 5-BO'LIM — convert_start_v2 ga konvert ruxsati tekshiruvi
-- ---------------------------------------------------------------------
-- Funksiyaning o'zi PROVODKA_KASSA2.sql da — bu yerda uni qayta yozmaymiz
-- (ikki fayl bir-birini ustiga yozib, ishga tushirish tartibiga bog'lanib
-- qolmasin). O'rniga KASSA2.sql ichida `perm_can_convert()` mavjud bo'lsa
-- chaqiriladi (to_regprocedure bilan himoyalangan chaqiruv).
-- Bu yerda faqat TEKSHIRAMIZ: o'sha chaqiruv o'z joyidami.
-- =====================================================================

do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'convert_start_v2'
   limit 1;

  if v_src is null then
    raise notice 'convert_start_v2 topilmadi — PROVODKA_KASSA2.sql hali ishga tushirilmagan.';
  elsif position('perm_can_convert' in v_src) = 0 then
    raise exception 'convert_start_v2 ichida perm_can_convert() chaqiruvi yoq — '
      'PROVODKA_KASSA2.sql ning yangi versiyasini qayta ishga tushiring.';
  else
    raise notice 'convert_start_v2: konvert ruxsati tekshiruvi joyida.';
  end if;
end $$;


-- =====================================================================
-- 6-BO'LIM — admin_set_provodka_perms (n8n / service_role ONLY)
-- ---------------------------------------------------------------------
-- p_data: {user_id, allowed_pages[], kassa_scope, view_kassa_ids[],
--          op_kassa_ids[], can_convert, updated_by}
-- Majburlanadi:
--   * op_kassa_ids ⊆ view_kassa_ids (ortiqchasi kesiladi)
--   * scope='all' bo'lsa ro'yxatlar bo'shatiladi
--   * noma'lum sahifa kaliti tashlab yuboriladi
--   * profiles.role='admin' foydalanuvchiga CHEKLOV YOZILMAYDI (qatori o'chiriladi)
-- =====================================================================

create or replace function admin_set_provodka_perms(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role   text;
  v_uid    uuid;
  v_scope  text;
  v_pages  text[];
  v_view   uuid[];
  v_op     uuid[];
  v_conv   boolean;
  v_by     uuid;
  v_target text;
  v_bad    int;
begin
  -- service_role ONLY. GRANT ham shuni beradi, bu ikkinchi qavat.
  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  v_uid := nullif(p_data ->> 'user_id', '')::uuid;
  if v_uid is null then
    raise exception 'user_id kerak';
  end if;

  select role into v_target from profiles where id = v_uid;
  if v_target is null then
    raise exception 'Bunday Provodka foydalanuvchisi yoq: %', v_uid;
  end if;

  -- Admin doim to'liq huquqli — unga cheklov saqlanmaydi.
  if v_target = 'admin' then
    delete from user_perms where user_id = v_uid;
    return jsonb_build_object('ok', true, 'skipped', 'admin',
      'note', 'Admin doim toliq huquqli — cheklov saqlanmadi');
  end if;

  v_scope := coalesce(p_data ->> 'kassa_scope', 'all');
  if v_scope not in ('all','list') then
    raise exception 'kassa_scope faqat all yoki list bolishi mumkin: %', v_scope;
  end if;

  v_conv := coalesce((p_data ->> 'can_convert')::boolean, true);
  v_by   := nullif(p_data ->> 'updated_by', '')::uuid;

  -- Sahifalar: faqat ma'lum kalitlar
  select coalesce(array_agg(x order by x), '{}')
    into v_pages
    from (select distinct jsonb_array_elements_text(coalesce(p_data -> 'allowed_pages','[]'::jsonb)) as x) s
   where x = any(perm_pages());

  -- 12 tasi ham belgilangan bo'lsa — bu "hammasi" degani, bo'sh saqlaymiz (izohli holat)
  if array_length(v_pages, 1) = array_length(perm_pages(), 1) then
    v_pages := '{}';
  end if;

  select coalesce(array_agg(distinct x::uuid), '{}') into v_view
    from jsonb_array_elements_text(coalesce(p_data -> 'view_kassa_ids','[]'::jsonb)) as x;
  select coalesce(array_agg(distinct x::uuid), '{}') into v_op
    from jsonb_array_elements_text(coalesce(p_data -> 'op_kassa_ids','[]'::jsonb)) as x;

  if v_scope = 'all' then
    -- Cheklov yo'q — ro'yxatlarni saqlab o'tirmaymiz (yarim-holat qolmasin)
    v_view := '{}';
    v_op   := '{}';
  else
    -- op ⊆ view majburlash: ortiqchasini kesib tashlaymiz
    select coalesce(array_agg(x), '{}') into v_op
      from unnest(v_op) as x where x = any(v_view);

    -- Mavjud bo'lmagan hisob id'lari kelib qolmasin
    select count(*) into v_bad
      from unnest(v_view) as x where not exists (select 1 from accounts a where a.id = x);
    if v_bad > 0 then
      raise exception 'view_kassa_ids ichida % ta notanish hisob id bor', v_bad;
    end if;
  end if;

  insert into user_perms(user_id, allowed_pages, kassa_scope, view_kassa_ids,
                         op_kassa_ids, can_convert, updated_at, updated_by)
  values (v_uid, v_pages, v_scope, v_view, v_op, v_conv, now(), v_by)
  on conflict (user_id) do update
     set allowed_pages  = excluded.allowed_pages,
         kassa_scope    = excluded.kassa_scope,
         view_kassa_ids = excluded.view_kassa_ids,
         op_kassa_ids   = excluded.op_kassa_ids,
         can_convert    = excluded.can_convert,
         updated_at     = now(),
         updated_by     = excluded.updated_by;

  return jsonb_build_object('ok', true, 'user_id', v_uid,
    'allowed_pages', to_jsonb(v_pages), 'kassa_scope', v_scope,
    'view_kassa_ids', to_jsonb(v_view), 'op_kassa_ids', to_jsonb(v_op),
    'can_convert', v_conv);
end $$;

revoke all on function admin_set_provodka_perms(jsonb) from public, anon, authenticated;
grant execute on function admin_set_provodka_perms(jsonb) to service_role;


-- =====================================================================
-- 7-BO'LIM — Tekshiruv
-- =====================================================================

do $$
declare v_n int;
begin
  -- RLS yoqilganmi
  if not (select relrowsecurity from pg_class where oid = 'public.user_perms'::regclass) then
    raise exception 'user_perms da RLS yoqilmagan';
  end if;

  -- Yozish policy'si BO'LMASLIGI kerak (faqat RPC yozadi)
  select count(*) into v_n from pg_policies
   where schemaname = 'public' and tablename = 'user_perms' and cmd <> 'SELECT';
  if v_n > 0 then
    raise exception 'user_perms da yozish policy''si bor (% ta) — bolmasligi kerak', v_n;
  end if;

  -- Trigger o'z joyidami
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.entry_line'::regclass
                    and tgname  = 'trg_perm_guard_entry_line') then
    raise exception 'entry_line guard trigger o''rnatilmadi';
  end if;

  -- admin_set_provodka_perms anon/authenticated uchun yopiqmi
  if has_function_privilege('authenticated', 'public.admin_set_provodka_perms(jsonb)', 'execute') then
    raise exception 'admin_set_provodka_perms authenticated uchun ochiq qolgan';
  end if;
  if has_function_privilege('anon', 'public.my_perms()', 'execute') then
    raise exception 'my_perms() anon uchun ochiq qolgan';
  end if;

  raise notice 'Ruxsat tizimi tayyor. Cheklangan foydalanuvchilar: % ta',
    (select count(*) from user_perms where kassa_scope = 'list'
        or array_length(allowed_pages,1) > 0 or not can_convert);
end $$;
