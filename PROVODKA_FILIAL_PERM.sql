-- =====================================================================
-- PROVODKA — FILIAL RUXSATI (hodim qaysi filiallarga xarajat qila oladi)
-- ---------------------------------------------------------------------
-- V6'da xarajatga filial multiselect qo'shildi (entry.filial_ids — FAQAT
-- metadata, pul kassadan chiqadi). Hozir hodim HAMMA filialni ko'radi.
-- Kerak: admin har userga ko'rinadigan filiallarni belgilaydi.
--
-- Bu op_kassa_ids'dan ALOHIDA:
--   op_kassa_ids  -> qaysi kassadan PUL chiqaradi (amaliyot; server guard bor).
--   filial_ids    -> xarajat qaysi filialga tegishli (METADATA; server guard yo'q).
--
-- Filiallar manbai: accounts kassa_turi='filial' (5201–5231) = v_filial_tanlov.
--
-- SERVER GUARD KERAK EMAS: filial faqat metadata, pul harakati emas — UI filtri
-- yetarli. (Xohilsa entry insert'da filial_ids ⊆ ruxsat tekshiruvi qo'shsa bo'lardi,
-- lekin bu majburiy emas va hozircha qo'shilmagan — pul baribir kassadan chiqadi,
-- entry_line guard uni allaqachon himoyalaydi.)
--
-- Qoidalar (PROVODKA_PERMS.sql naqshi):
--   * idempotent  * xato -> RAISE EXCEPTION  * SECURITY DEFINER auth guard
--   * REVOKE anon  * admin doim cheklanmagan  * noma'lum kalit tashlanadi
--
-- PROVODKA_PERMS.sql dan KEYIN ishga tushiriladi. Asilbek qo'lda RUN qiladi.
-- =====================================================================


-- =====================================================================
-- 1-BO'LIM — user_perms ga 2 ustun
-- ---------------------------------------------------------------------
-- filial_scope: 'all' (hamma filial) | 'list' (faqat filial_ids).
-- filial_ids:   ruxsat berilgan filial hisoblari (accounts.id, 5201–5231).
-- Default 'all' + bo'sh — mavjud foydalanuvchilar o'zgarmaydi (hammani ko'radi).
-- =====================================================================

alter table user_perms
  add column if not exists filial_scope text  not null default 'all',
  add column if not exists filial_ids   uuid[] not null default '{}';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_perms_filial_scope_chk') then
    alter table user_perms
      add constraint user_perms_filial_scope_chk check (filial_scope in ('all','list'));
  end if;
end $$;

comment on column user_perms.filial_scope is
  'Xarajat filial ko''rinishi: all=hamma filial, list=faqat filial_ids.';
comment on column user_perms.filial_ids is
  'Ruxsat berilgan filial hisoblari (accounts.id, kassa_turi=filial). FAQAT metadata filtri.';


-- =====================================================================
-- 2-BO'LIM — my_perms() — javobga filial_scope + filial_ids qo'shiladi
-- ---------------------------------------------------------------------
-- Uch holatda ham (admin / qatorsiz / oddiy) yangi maydonlar qaytadi.
-- Admin va qatorsiz -> 'all' + bo'sh (cheklanmagan).
-- =====================================================================

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
      'filial_scope',   'all',
      'filial_ids',     '[]'::jsonb,
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
      'filial_scope',   'all',
      'filial_ids',     '[]'::jsonb,
      'is_admin',       false);
  end if;

  return jsonb_build_object(
    'user_id',        p.user_id,
    'allowed_pages',  to_jsonb(p.allowed_pages),
    'kassa_scope',    p.kassa_scope,
    'view_kassa_ids', to_jsonb(p.view_kassa_ids),
    'op_kassa_ids',   to_jsonb(p.op_kassa_ids),
    'can_convert',    p.can_convert,
    'filial_scope',   p.filial_scope,
    'filial_ids',     to_jsonb(p.filial_ids),
    'is_admin',       false);
end $$;

revoke all on function my_perms() from public, anon;
grant execute on function my_perms() to authenticated;


-- =====================================================================
-- 3-BO'LIM — admin_set_provodka_perms(p_data jsonb) — filial maydonlari
-- ---------------------------------------------------------------------
-- Yangi kalitlar: filial_scope ('all'|'list'), filial_ids (uuid[]).
-- Mavjud naqsh saqlanadi:
--   * scope='all' -> filial_ids bo'shatiladi (yarim-holat qolmasin)
--   * noma'lum/notanish filial id -> jimgina TASHLANADI (metadata, qattiq rad
--     etilmaydi — admin-dev ro'yxati bilan mos kelmasa ham save buzilmasin)
--   * profiles.role='admin' -> cheklov yozilmaydi (qatori o'chiriladi)
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

  v_fscope := coalesce(p_data ->> 'filial_scope', 'all');
  if v_fscope not in ('all','list') then
    raise exception 'filial_scope faqat all yoki list bolishi mumkin: %', v_fscope;
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
    'filial_scope', v_fscope, 'filial_ids', to_jsonb(v_fids));
end $$;

revoke all on function admin_set_provodka_perms(jsonb) from public, anon, authenticated;
grant execute on function admin_set_provodka_perms(jsonb) to service_role;


-- =====================================================================
-- 4-BO'LIM — Tekshiruv
-- =====================================================================

do $$
declare v_j jsonb;
begin
  -- Ustunlar joyidami
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='user_perms'
                    and column_name='filial_scope') then
    raise exception 'user_perms.filial_scope ustuni yaratilmadi';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='user_perms'
                    and column_name='filial_ids') then
    raise exception 'user_perms.filial_ids ustuni yaratilmadi';
  end if;

  -- my_perms javobida yangi kalitlar bormi (admin sifatida chaqira olmaymiz shu blokda,
  -- shuning uchun faqat funksiya manbasini tekshiramiz)
  if (select position('filial_scope' in prosrc) from pg_proc where proname='my_perms' limit 1) = 0 then
    raise exception 'my_perms() ichida filial_scope yoq — yangilanmadi';
  end if;
  if (select position('filial_ids' in prosrc) from pg_proc where proname='admin_set_provodka_perms' limit 1) = 0 then
    raise exception 'admin_set_provodka_perms() ichida filial_ids yoq — yangilanmadi';
  end if;

  raise notice 'Filial ruxsati tayyor. filial_scope=list foydalanuvchilar: % ta',
    (select count(*) from user_perms where filial_scope = 'list');
end $$;
