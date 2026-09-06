-- =====================================================================
-- PROVODKA_KONVERT_FARQ_RUXSAT.sql  (2026-09-06, URGENT — buxgalterlar bloklangan)
-- ---------------------------------------------------------------------
-- IKKI ALOHIDA NOSOZLIK, ikkalasi ham prod'da jonli userlarga tegdi:
--
--  1) KONVERT: kassa/konvert ruxsati bor buxgalter «Sotib olish» qilsa
--     «Ruxsat yoq: "9437 Konvert kurs farqi" xarajat moddasi rolingizda yoq»
--     (42501). Sabab: convert_start_v3 kurs farqini ALOHIDA yozuv qilib
--     Dt 9437 (type='xarajat') ga yozadi; PROVODKA_RBAC.sql dagi
--     trg_rbac_guard_entry_line esa HAR type='xarajat' Dt satrini
--     «rolda modda bormi» deb tekshiradi — 9437 hech kimning rolida yo'q
--     (u konvertning texnik moddasi, hodim tanlamaydi). Natija: konvert
--     ruxsati bor odam konvert qila olmaydi.
--     YECHIM: konvert ruxsati (perm_can_convert) = shu moddaga yozish
--     ruxsati. Guard shu bitta moddaga, faqat konvert ruxsati bo'lsa,
--     istisno beradi. Boshqa hamma modda avvalgidek rol bilan tekshiriladi.
--
--  2) FAYL YUKLASH (chek): professional/hodim'da yozuv saqlanadi, lekin
--     «fayl yuklanmadi: permission denied for function _ehson_is_admin».
--     Sabab: PROVODKA_EHSON.sql `ehson-hujjat` bucket'i uchun storage.objects
--     ga policy qo'ydi va uning ichida _ehson_is_admin() chaqiriladi, lekin
--     funksiya authenticated'dan REVOKE qilingan («ichki» deb). storage.objects
--     BITTA jadval — Postgres permissive policy'larni OR bilan yig'adi va
--     `bucket_id = 'ehson-hujjat' and _ehson_is_admin()` ichidagi AND'ni
--     qisqa tutashuv (short-circuit) kafolatisiz baholaydi. Ya'ni BOSHQA
--     bucket'ga (xarajat-cheklari, rasm-tahlil, qarz-tilxat…) yuklashda ham
--     shu funksiya chaqiriladi va admin bo'lmagan har bir user 42501 oladi.
--     YECHIM: _ehson_is_admin() ga authenticated uchun EXECUTE. U faqat
--     «men adminmanmi» degan boolean qaytaradi (is_admin() bilan bir xil,
--     u allaqachon hammaga ochiq) — sizadigan ma'lumot yo'q.
--
-- ADDITIVE: imzo/ustun o'zgarmaydi, drop yo'q. Ikkalasi idempotent.
-- Old shart: PROVODKA_RBAC.sql, PROVODKA_KONVERT_V3.sql,
-- PROVODKA_KONVERT_KASSA_RUXSAT.sql (perm_can_convert), PROVODKA_EHSON.sql
-- allaqachon RUN qilingan (xato matnlari aynan shulardan chiqyapti).
-- Izohlarda dollar-teg yozilmaydi (CLAUDE.md qoidasi).
-- =====================================================================


-- #####################################################################
-- ##  1-BO'LIM — rbac_guard_entry_line: konvert kurs farqi istisnosi   ##
-- ---------------------------------------------------------------------
-- Tana PROVODKA_RBAC.sql 5-bo'limdagi bilan AYNAN bir xil, faqat
-- rbac_modda_ok() dan OLDIN bitta istisno qo'shildi:
--   new.account_id = conv_farq_hisob_id()  VA  perm_can_convert()  -> o'tadi.
-- Trigger o'zi (trg_rbac_guard_entry_line) qayta yaratilmaydi — funksiya
-- almashgani yetarli. Debit<=0 / type<>'xarajat' / admin / service_role
-- shoxlari o'zgarmagan.
-- Yordamchi funksiyalar dinamik chaqiriladi (execute) — birortasi yo'q
-- bazada guard avvalgidek ishlayveradi (istisno shunchaki bermaydi).
-- Kt tomoni (farq manfiy — foyda, Kt 9437) guardga umuman tushmaydi
-- (debit=0), o'zgarish yo'q.
-- #####################################################################

create or replace function rbac_guard_entry_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $rbac_guard$
declare
  v_type text;
  v_lbl  text;
  v_farq uuid;
  v_conv boolean;
begin
  if coalesce(new.debit, 0) <= 0 then
    return new;
  end if;

  select a.type, coalesce(a.code || ' ' || a.name, new.account_id::text)
    into v_type, v_lbl
    from accounts a where a.id = new.account_id;

  if v_type is distinct from 'xarajat' then
    return new;
  end if;

  -- Konvert kurs farqi (texnik modda): konvert ruxsati = shu moddaga yozish ruxsati.
  if to_regprocedure('public.conv_farq_hisob_id()') is not null
     and to_regprocedure('public.perm_can_convert()') is not null then
    execute 'select public.conv_farq_hisob_id()' into v_farq;
    if v_farq is not null and new.account_id = v_farq then
      execute 'select public.perm_can_convert()' into v_conv;
      if coalesce(v_conv, false) then
        return new;
      end if;
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
  'YANGI (trg_perm_guard_entry_line dan ALOHIDA): rbac_role_modda boyicha xarajat moddasini tosadi. '
  'service_role (n8n) va admin otadi. Faqat debit>0 va type=xarajat satrlarga tegadi. '
  'ISTISNO (2026-09-06): conv_farq_hisob_id() moddasi — perm_can_convert() true bolsa rol tekshirilmaydi.';


-- #####################################################################
-- ##  2-BO'LIM — _ehson_is_admin() authenticated uchun EXECUTE          ##
-- ---------------------------------------------------------------------
-- storage.objects policy ichida chaqirilgani uchun HAMMA bucket'ga yuklash
-- shunga bog'liq. Funksiya yo'q bazada (Ehson RUN qilinmagan) — o'tkazib
-- yuboriladi. PROVODKA_EHSON.sql dagi revoke qatori va 11-bo'lim
-- o'z-o'zini tekshiruvi ham shu bilan moslashtirildi (qayta RUN qilinsa
-- grantni yana olib qo'ymasin).
-- #####################################################################

do $ehson_grant$
begin
  if to_regprocedure('public._ehson_is_admin()') is not null then
    grant execute on function public._ehson_is_admin() to authenticated;
    raise notice '2-BOLIM: _ehson_is_admin() authenticated uchun ochildi (storage policy uchun).';
  else
    raise notice '2-BOLIM: _ehson_is_admin() yoq — Ehson RUN qilinmagan, otkazib yuborildi.';
  end if;
end
$ehson_grant$;


-- #####################################################################
-- ##  3-BO'LIM — O'Z-O'ZINI TEKSHIRUV                                  ##
-- #####################################################################

do $check$
declare
  v_src text;
begin
  select pg_get_functiondef('public.rbac_guard_entry_line()'::regprocedure) into v_src;
  if v_src not like '%conv_farq_hisob_id%' or v_src not like '%perm_can_convert%' then
    raise exception '1-BOLIM: rbac_guard_entry_line ichida konvert istisnosi yoq';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.entry_line'::regclass
                    and tgname = 'trg_rbac_guard_entry_line' and not tgisinternal) then
    raise exception '1-BOLIM: trg_rbac_guard_entry_line yoq — RBAC guard orin almashgan, tekshiring';
  end if;
  if to_regprocedure('public.conv_farq_hisob_id()') is null then
    raise warning '1-BOLIM: conv_farq_hisob_id() yoq — PROVODKA_KONVERT_V3.sql RUN qilinmagan, istisno ishlamaydi';
  end if;
  if to_regprocedure('public.perm_can_convert()') is null then
    raise warning '1-BOLIM: perm_can_convert() yoq — PROVODKA_PERMS.sql RUN qilinmagan, istisno ishlamaydi';
  end if;

  if to_regprocedure('public._ehson_is_admin()') is not null
     and not has_function_privilege('authenticated', 'public._ehson_is_admin()', 'execute') then
    raise exception '2-BOLIM: _ehson_is_admin() hamon authenticated uchun yopiq';
  end if;

  raise notice 'PROVODKA_KONVERT_FARQ_RUXSAT.sql: hammasi joyida.';
end
$check$;
