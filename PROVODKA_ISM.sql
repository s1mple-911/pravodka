-- =====================================================================
-- PROVODKA — ISM-FAMILIYA (profiles.full_name) tizimi
-- ---------------------------------------------------------------------
-- Maqsad: Provodka'da hamma joyda gmail o'rniga ism-familiya ko'rinsin.
-- Ism admin tomonidan `admin-dev.html` → n8n webhook orqali kiritiladi.
--
-- QOIDA (bitta DB, prod ishlab turibdi): SQL ADDITIVE.
--   * add column if not exists / yangi funksiya
--   * `create or replace` FAQAT eski imzoni saqlab
--   * ustun/funksiya o'chirish yoki imzo o'zgartirish — TAQIQ
--   * yangi RPC: SECURITY DEFINER + set search_path=public + REVOKE public,anon
--
-- 🔴 ESKI YOZUVLAR TEGILMAYDI. entry.created_by / deleted_by_name /
--    edited_by_name / requested_by_name / decided_by_name / synced_by_name —
--    bular yozuv PAYTIDA MATN sifatida saqlangan (o'sha paytda kim yozgani).
--    Eski qatorlarda gmail turgan bo'lsa — SHUNDAY QOLADI, bu buxgalteriya
--    tarixi. Bu faylda ularni UPDATE qiladigan blok ATAYLAB YO'Q.
--    Yechim faqat oldinga qaraydi: frontend `myName` ni endi full_name'dan
--    oladi, ya'ni BUNDAN KEYINGI yozuvlarga ism-familiya tushadi.
--
-- Asilbek qo'lda RUN qiladi. Idempotent — qayta ishga tushirsa bo'ladi.
-- =====================================================================


-- =====================================================================
-- 1-BO'LIM — Old shartlar
-- =====================================================================

do $$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'profiles jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
end $$;


-- =====================================================================
-- 2-BO'LIM — profiles.full_name ustuni (additive, xavfsiz)
-- ---------------------------------------------------------------------
-- Ustun allaqachon bor va ishlatilyapti (kassa/jurnal/filial/konvert/
-- provodka/valyuta/hodim sahifalari o'qiydi). `if not exists` — bor bo'lsa
-- hech narsa qilmaydi, yo'q muhitda esa yaratadi.
-- =====================================================================

alter table profiles add column if not exists full_name text;

comment on column profiles.full_name is
  'Foydalanuvchining ism-familiyasi. Bo''sh/null bo''lsa UI gmail (email) ga qaytadi.';


-- =====================================================================
-- 3-BO'LIM — Ichki yordamchi: normalizatsiya + yozish
-- ---------------------------------------------------------------------
-- Bitta joyda: bo'shliqlar kesiladi, bo'sh matn -> NULL (fallback gmailga
-- qaytsin). Noma'lum user_id -> false (chaqiruvchi jimgina o'tkazadi).
-- Faqat SECURITY DEFINER funksiyalar ichidan chaqiriladi.
-- =====================================================================

create or replace function set_profile_full_name(p_uid uuid, p_name text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  if p_uid is null then
    return false;
  end if;
  -- '   ' ham bo'sh hisoblanadi -> null
  v_name := nullif(btrim(coalesce(p_name, '')), '');
  update profiles set full_name = v_name where id = p_uid;
  return found;
end $$;

revoke all on function set_profile_full_name(uuid, text) from public, anon, authenticated;

comment on function set_profile_full_name(uuid, text) is
  'Ichki: profiles.full_name yozadi (trim, bo''sh -> null). Faqat definer RPC ichidan.';


-- =====================================================================
-- 4-BO'LIM — admin_set_full_name(p_data jsonb) — service_role ONLY
-- ---------------------------------------------------------------------
-- n8n webhook uchun mustaqil RPC (admin_set_provodka_perms naqshida).
-- Ikki payload shakli qabul qilinadi:
--   bitta:  {"user_id":"<uuid>", "full_name":"Ism Familiya"}
--   ko'p:   {"users":[{"user_id":"<uuid>","full_name":"Ism Familiya"}, ...]}
--
--   * full_name bo'sh/probel  -> NULL yoziladi (UI gmailga qaytadi)
--   * full_name kaliti YO'Q   -> o'sha element o'tkazib yuboriladi (tegilmaydi)
--   * noma'lum user_id        -> jimgina o'tkaziladi (skipped sanog'iga tushadi)
--
-- Qaytishi: {"ok":true,"updated":N,"skipped":M,"users":[...]}
-- =====================================================================

create or replace function admin_set_full_name(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role  text;
  v_items jsonb;
  v_it    jsonb;
  v_uid   uuid;
  v_name  text;
  v_upd   int := 0;
  v_skip  int := 0;
  v_res   jsonb := '[]'::jsonb;
begin
  -- service_role ONLY. GRANT ham shuni beradi, bu ikkinchi qavat.
  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  if jsonb_typeof(p_data -> 'users') = 'array' then
    v_items := p_data -> 'users';
  else
    v_items := jsonb_build_array(coalesce(p_data, '{}'::jsonb));
  end if;

  for v_it in select value from jsonb_array_elements(v_items) loop
    -- Kalit umuman kelmagan bo'lsa — tegmaymiz (tasodifan o'chirib qo'ymaslik uchun)
    if not (v_it ? 'full_name') then
      v_skip := v_skip + 1;
      continue;
    end if;

    begin
      v_uid := nullif(v_it ->> 'user_id', '')::uuid;
    exception when others then
      v_uid := null;                       -- buzuq uuid — jimgina o'tkazamiz
    end;

    v_name := v_it ->> 'full_name';

    if v_uid is null or not set_profile_full_name(v_uid, v_name) then
      v_skip := v_skip + 1;
      continue;
    end if;

    v_upd := v_upd + 1;
    v_res := v_res || jsonb_build_object(
      'user_id', v_uid,
      'full_name', nullif(btrim(coalesce(v_name, '')), ''));
  end loop;

  return jsonb_build_object('ok', true, 'updated', v_upd,
                            'skipped', v_skip, 'users', v_res);
end $$;

revoke all on function admin_set_full_name(jsonb) from public, anon, authenticated;
grant execute on function admin_set_full_name(jsonb) to service_role;

comment on function admin_set_full_name(jsonb) is
  'n8n (service_role): profiles.full_name yozadi. {user_id,full_name} yoki {users:[...]}. Bo''sh -> null.';


-- =====================================================================
-- 5-BO'LIM — admin_set_provodka_perms: IXTIYORIY full_name
-- ---------------------------------------------------------------------
-- ⚠️ IMZO O'ZGARMAYDI: admin_set_provodka_perms(p_data jsonb).
-- Tana PROVODKA_PAGES_EMPTY.sql dagi bilan AYNAN bir xil, faqat bitta
-- qo'shimcha: agar payloadda `full_name` kaliti bo'lsa — profiles'ga
-- yoziladi. Kalit bo'lmasa hech narsa o'zgarmaydi (eski n8n chaqiruvlari
-- shundayligicha ishlaydi).
--
-- Shuning uchun ADMIN-DEV YANGI WEBHOOK OCHMAYDI — mavjud
-- `aros-provodka-perms-save` payloadiga bitta maydon qo'shildi, xolos.
--
-- full_name ADMIN uchun ham yoziladi: admin'ga cheklov saqlanmaydi
-- (erta return), lekin ismi baribir kerak — shuning uchun full_name
-- bloki admin tekshiruvidan OLDIN turadi.
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
  v_fscope text;
  v_fids   uuid[];
  v_by     uuid;
  v_target text;
  v_bad    int;
  v_name   boolean := false;   -- ism-familiya yozildimi
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

  -- YANGI: ism-familiya (ixtiyoriy). Kalit kelmasa — tegilmaydi.
  if p_data ? 'full_name' then
    v_name := set_profile_full_name(v_uid, p_data ->> 'full_name');
  end if;

  -- Admin doim to'liq huquqli — unga cheklov saqlanmaydi.
  if v_target = 'admin' then
    delete from user_perms where user_id = v_uid;
    return jsonb_build_object('ok', true, 'skipped', 'admin',
      'full_name_saved', v_name,
      'note', 'Admin doim toliq huquqli — cheklov saqlanmadi');
  end if;

  v_scope := coalesce(p_data ->> 'kassa_scope', 'all');
  if v_scope not in ('all','list') then
    raise exception 'kassa_scope faqat all yoki list bolishi mumkin: %', v_scope;
  end if;

  v_fscope := coalesce(p_data ->> 'filial_scope', 'all');
  if v_fscope not in ('all','list') then
    raise exception 'filial_scope faqat all yoki list bolishi mumkin: %', v_fscope;
  end if;

  v_conv := coalesce((p_data ->> 'can_convert')::boolean, true);
  v_by   := nullif(p_data ->> 'updated_by', '')::uuid;

  -- Sahifalar: faqat ma'lum kalitlar. Bo'sh kelsa BO'SH saqlanadi = ruxsat yo'q.
  select coalesce(array_agg(x order by x), '{}')
    into v_pages
    from (select distinct jsonb_array_elements_text(coalesce(p_data -> 'allowed_pages','[]'::jsonb)) as x) s
   where x = any(perm_pages());

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

  -- Filial ro'yxati (metadata) — kelgan id'lardan FAQAT mavjud filial hisoblari qoladi.
  -- Qattiq rad etmaymiz: admin-dev ro'yxati bilan farq bo'lsa ham save o'tishi kerak.
  select coalesce(array_agg(distinct x::uuid), '{}') into v_fids
    from jsonb_array_elements_text(coalesce(p_data -> 'filial_ids','[]'::jsonb)) as x;

  if v_fscope = 'all' then
    v_fids := '{}';                       -- cheklov yo'q — ro'yxat saqlanmaydi
  else
    select coalesce(array_agg(a.id), '{}') into v_fids
      from accounts a
     where a.id = any(v_fids) and a.kassa_turi = 'filial';
  end if;

  insert into user_perms(user_id, allowed_pages, kassa_scope, view_kassa_ids,
                         op_kassa_ids, can_convert, filial_scope, filial_ids,
                         updated_at, updated_by)
  values (v_uid, v_pages, v_scope, v_view, v_op, v_conv, v_fscope, v_fids, now(), v_by)
  on conflict (user_id) do update
     set allowed_pages  = excluded.allowed_pages,
         kassa_scope    = excluded.kassa_scope,
         view_kassa_ids = excluded.view_kassa_ids,
         op_kassa_ids   = excluded.op_kassa_ids,
         can_convert    = excluded.can_convert,
         filial_scope   = excluded.filial_scope,
         filial_ids     = excluded.filial_ids,
         updated_at     = now(),
         updated_by     = excluded.updated_by;

  return jsonb_build_object('ok', true, 'user_id', v_uid,
    'allowed_pages', to_jsonb(v_pages), 'kassa_scope', v_scope,
    'view_kassa_ids', to_jsonb(v_view), 'op_kassa_ids', to_jsonb(v_op),
    'can_convert', v_conv,
    'filial_scope', v_fscope, 'filial_ids', to_jsonb(v_fids),
    'full_name_saved', v_name,
    'has_provodka', coalesce(array_length(v_pages,1),0) > 0);
end $$;

revoke all on function admin_set_provodka_perms(jsonb) from public, anon, authenticated;
grant execute on function admin_set_provodka_perms(jsonb) to service_role;

comment on function admin_set_provodka_perms(jsonb) is
  'n8n (service_role): Provodka ruxsatlari. Ixtiyoriy full_name kaliti profiles.full_name ga yoziladi.';


-- =====================================================================
-- 6-BO'LIM — full_name_or_email(uuid): ko'rsatish uchun fallback
-- ---------------------------------------------------------------------
-- Server tomonda ism kerak bo'lganda: full_name bo'sh bo'lsa auth.users
-- email'iga qaytadi (frontenddagi fallback bilan bir xil mantiq).
-- auth.users o'qilmasa — xato bermaydi, bo'sh matn qaytaradi (hisobot
-- funksiyasi shu sabab yiqilmasin).
--
-- Hozircha hech qayerdan chaqirilmaydi — 7-BO'LIMdagi diagnostikadan
-- keyin, kerak bo'lsa, hisobot funksiyalariga qo'shiladi.
-- =====================================================================

create or replace function full_name_or_email(p_uid uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_name text;
  v_mail text;
begin
  if p_uid is null then
    return '';
  end if;
  select nullif(btrim(coalesce(full_name, '')), '') into v_name
    from profiles where id = p_uid;
  if v_name is not null then
    return v_name;
  end if;
  begin
    select nullif(btrim(coalesce(u.email, '')), '') into v_mail
      from auth.users u where u.id = p_uid;
  exception when others then
    v_mail := null;
  end;
  return coalesce(v_mail, '');
end $$;

-- ⚠️ GRANT ATAYLAB YO'Q. Funksiya security definer va auth.users'dan email
--    o'qiydi — ya'ni RLS'ni chetlab o'tadi. `authenticated` ga berilsa har
--    qanday foydalanuvchi uuid bo'yicha boshqa odamning ismi va emailini
--    ola olardi. Hozircha u hech qayerdan chaqirilmaydi; 7.6 dagi hisobot
--    funksiyasiga qo'shilganda o'sha funksiya SECURITY DEFINER bo'lgani
--    uchun ichkaridan baribir ishlaydi — grant SHART EMAS.
revoke all on function full_name_or_email(uuid) from public, anon, authenticated;

comment on function full_name_or_email(uuid) is
  'Ko''rsatish uchun ism: profiles.full_name, bo''sh bo''lsa auth.users.email, u ham yo''q bo''lsa bo''sh matn.';


notify pgrst, 'reload schema';


-- =====================================================================
-- 7-BO'LIM — TEKSHIRUV (RUN qilgandan keyin ko'rib chiqing)
-- ---------------------------------------------------------------------

-- 7.1 Ustun bormi?
select column_name, data_type
  from information_schema.columns
 where table_schema = 'public' and table_name = 'profiles'
   and column_name = 'full_name';

-- 7.2 Kim ismsiz qolgan? (bularga admin-dev'dan ism kiritish kerak —
--     ular hozir Provodka'da gmail bilan ko'rinadi)
select p.id, u.email, p.role, p.full_name
  from profiles p
  left join auth.users u on u.id = p.id
 where nullif(btrim(coalesce(p.full_name, '')), '') is null
 order by u.email;

-- 7.3 Umumiy sanoq
select count(*) filter (where nullif(btrim(coalesce(full_name,'')),'') is not null) as ismi_bor,
       count(*) filter (where nullif(btrim(coalesce(full_name,'')),'') is null)     as ismsiz,
       count(*)                                                                    as jami
  from profiles;

-- 7.4 Yangi RPC faqat service_role uchunmi? (authenticated qatori CHIQMASLIGI kerak)
select p.proname, r.rolname, has_function_privilege(r.rolname, p.oid, 'execute') as execute_bor
  from pg_proc p
  cross join (values ('anon'),('authenticated'),('service_role')) as r(rolname)
 where p.proname in ('admin_set_full_name','admin_set_provodka_perms','set_profile_full_name')
   and p.pronamespace = 'public'::regnamespace
 order by p.proname, r.rolname;

-- ---------------------------------------------------------------------
-- 7.5 DIAGNOSTIKA — hisobotdagi "Kim" ustuni (hisobot-dev Excel eksporti,
--     yuklar-dev "Bog'lanmagan to'lovlar") entry.created_by dan keladi.
--     entry.created_by turi ANIQLANMAGAN (repoda ikkala variant ham bor):
--       * uuid bo'lsa  -> "Kim" profiles'dan JONLI o'qiladi, ya'ni full_name
--                         to'ldirilishi bilan o'zi to'g'rilanadi. Xohlansa
--                         bo'sh full_name uchun email fallback'i qo'shiladi
--                         (pastdagi izohli blok).
--       * text bo'lsa  -> "Kim" yozuv paytida saqlangan MATN (tarix) —
--                         TEGILMAYDI, faqat yangi yozuvlar ism bilan tushadi.
--     Quyidagi SELECT javobni beradi:
select column_name, data_type, is_nullable
  from information_schema.columns
 where table_schema = 'public' and table_name = 'entry'
   and column_name in ('created_by', 'created_by_name');

-- 7.6 IXTIYORIY (faqat 7.5 da created_by = uuid chiqsa; Asilbek qaroridan
--     keyin alohida RUN qilinadi — imzo o'zgarmaydi, faqat "kim" ustuni
--     bo'sh bo'lganda emailga qaytadi):
--
-- create or replace function hodim_xarajat_royxat(p_from date, p_to date)
-- returns table(
--   entry_date date, kassa_code text, kassa_name text, kassa_subtitle text,
--   modda_code text, modda_name text, summa numeric, izoh text, kim text
-- )
-- language plpgsql stable security definer set search_path = public as $fn$
-- begin
--   if not is_admin() then
--     raise exception 'Faqat admin ko''ra oladi' using errcode = '42501';
--   end if;
--   return query
--     select e.entry_date, ka.code, ka.name, ka.subtitle, ma.code, ma.name,
--            dl.debit::numeric, e.description,
--            full_name_or_email(e.created_by)        -- <— yagona o'zgarish
--       from entry e
--       join entry_line dl on dl.entry_id = e.id and dl.debit > 0
--       join accounts ma on ma.id = dl.account_id and ma.type = 'xarajat'
--       join entry_line kl on kl.entry_id = e.id and kl.credit > 0
--       join accounts ka on ka.id = kl.account_id and ka.section = 'pul'
--      where e.status = 'posted' and e.is_deleted = false
--        and e.entry_date >= p_from and e.entry_date <= p_to
--      order by e.entry_date, ka.name, ma.name;
-- end $fn$;
