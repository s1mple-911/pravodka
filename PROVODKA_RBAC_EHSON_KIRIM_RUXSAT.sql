-- ============================================================================
--  PROVODKA_RBAC_EHSON_KIRIM_RUXSAT.sql — 2026-10-05 — RBAC qorovuli: ehson moddasi «ehson_kirim» bayrog'i bilan,
--  «Konvert ustama» moddasi konvert ruxsati bilan ochiladi (rol shart emas)
--  Asilbek: «"9441 Ehson jamg'armasi · Ehson asosiy" rolingizda yoq» — ehson_kirim bayrog'ini bergan, lekin professionalda
--  yozolmayapti; Ehson sahifasi sanoqli odamga ochiq, ehsonga PUL CHIQARISH esa alohida beriladigan bo'lsin.
--  Sabab: rbac_guard_entry_line() ehson moddasini (accounts.ehson_kassa_id) oddiy xarajat moddasi deb «rolda bormi» deb
--  tekshirardi. Konvert kurs farqi (9437) uchun qilingan istisno naqshi (PROVODKA_KONVERT_FARQ_RUXSAT.sql) kengaytirildi:
--   1) accounts.ehson_kassa_id IS NOT NULL (ehson jamg'arma moddasi) VA ehson_kirim_ok() → rol tekshirilmaydi
--      (trg_ehson_kirim_guard baribir ehson_kirim_ok() ni talab qiladi — ikki qatlam bir xil qoida).
--   2) conv_ustama_hisob_id() moddasi («Konvert ustama», V4) VA perm_can_convert() → rol tekshirilmaydi (V4 da unutilgan).
--  Tana PROVODKA_KURS_FARQI_AVTO.sql dagi ENG OXIRGI versiyadan verbatim + ikki istisno. Asilbek RUN qiladi.
--  🔴 rbac_guard_entry_line ning ENG OXIRGI versiyasi endi SHU faylda.
-- ============================================================================
create or replace function rbac_guard_entry_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $rbac_guard$
declare
  v_type  text;
  v_lbl   text;
  v_ehson uuid;
  v_farq  uuid;
  v_conv  boolean;
  v_ok    boolean;
begin
  if coalesce(current_setting('provodka.avto_kurs', true), '') = '1' then
    return new;                                   -- kurs farqi avto-yozuvi (faqat _kurs_farqi_yoz ichida)
  end if;
  if coalesce(new.debit, 0) <= 0 then
    return new;
  end if;

  select a.type, coalesce(a.code || ' ' || a.name, new.account_id::text), (to_jsonb(a) ->> 'ehson_kassa_id')::uuid
    into v_type, v_lbl, v_ehson
    from accounts a where a.id = new.account_id;

  if v_type is distinct from 'xarajat' then
    return new;
  end if;

  -- 🔴 2026-10-05: Ehson jamg'arma moddasi — «ehson_kirim» bayrog'i (yoki admin) yetarli, rol shart emas
  if v_ehson is not null and to_regprocedure('public.ehson_kirim_ok()') is not null then
    execute 'select public.ehson_kirim_ok()' into v_ok;
    if coalesce(v_ok, false) then
      return new;
    end if;
  end if;

  -- Konvert kurs farqi (9437) va Konvert ustama (V4): konvert ruxsati = shu moddalarga yozish ruxsati
  if to_regprocedure('public.perm_can_convert()') is not null then
    v_farq := null;
    if to_regprocedure('public.conv_farq_hisob_id()') is not null then
      execute 'select public.conv_farq_hisob_id()' into v_farq;
    end if;
    if v_farq is not null and new.account_id = v_farq then
      execute 'select public.perm_can_convert()' into v_conv;
      if coalesce(v_conv, false) then return new; end if;
    end if;
    v_farq := null;
    if to_regprocedure('public.conv_ustama_hisob_id()') is not null then
      execute 'select public.conv_ustama_hisob_id()' into v_farq;
    end if;
    if v_farq is not null and new.account_id = v_farq then
      execute 'select public.perm_can_convert()' into v_conv;
      if coalesce(v_conv, false) then return new; end if;
    end if;
  end if;

  if rbac_modda_ok(new.account_id) then
    return new;
  end if;

  raise exception 'Ruxsat yoq: "%" xarajat moddasi rolingizda yoq', v_lbl
    using errcode = '42501';
end
$rbac_guard$;
revoke all on function rbac_guard_entry_line() from public, anon;

comment on function rbac_guard_entry_line() is
  'rbac_role_modda boyicha xarajat moddasini tosadi (debit>0, type=xarajat). ISTISNOLAR: provodka.avto_kurs; '
  'ehson moddasi (accounts.ehson_kassa_id) + ehson_kirim_ok(); conv_farq_hisob_id() / conv_ustama_hisob_id() + perm_can_convert().';

-- O'Z-O'ZINI TEKSHIRUV
do $check$
declare v_src text;
begin
  select pg_get_functiondef('public.rbac_guard_entry_line()'::regprocedure) into v_src;
  if v_src not like '%ehson_kirim_ok%' or v_src not like '%conv_ustama_hisob_id%' then
    raise exception 'rbac_guard_entry_line ichida ehson/ustama istisnosi yoq';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.entry_line'::regclass
                    and tgname = 'trg_rbac_guard_entry_line' and not tgisinternal) then
    raise exception 'trg_rbac_guard_entry_line yoq';
  end if;
  if to_regprocedure('public.ehson_kirim_ok()') is null then
    raise warning 'ehson_kirim_ok() yoq — PROVODKA_EHSON.sql RUN qilinmagan, ehson istisnosi ishlamaydi';
  end if;
  raise notice 'PROVODKA_RBAC_EHSON_KIRIM_RUXSAT.sql: hammasi joyida.';
end
$check$;
