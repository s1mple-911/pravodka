-- =====================================================================
-- PROVODKA — MAXSUS MAYDON QOROVULLARI (xavfsizlik qattiqlashtirish)
-- ---------------------------------------------------------------------
-- Manba: PROVODKA_XARAJAT_MAYDON.sql (jadvallar/policy/RPC — TEGILMAYDI).
-- Bu fayl faqat IKKI teshikni yopadi:
--
--   QA 2-band — `entry_maydon` YOZISH ruxsatida teshik.
--     `xm_entry_yoz_ok()` oxirida `perm_check_accounts()` bor, lekin u
--     `kassa_scope <> 'list'` bo'lsa DOIM `true` qaytaradi (sukut 'all').
--     Egalik tekshiruvi esa `created_by` bo'sh/matn bo'lsa O'TKAZIB
--     YUBORILARDI. Natija: `created_by` bo'sh ESKI yozuvlarga (bazadagi
--     yozuvlarning deyarli hammasi) istalgan authenticated foydalanuvchi
--     maydon qiymati yozishi, ustidan yozishi va O'CHIRISHI mumkin edi.
--
--   QA 3-band — `entry_maydon` O'QISHIDA sahifa qorovuli yo'q.
--     `entry_maydon_sel` faqat `perm_view_pul_ids()` ga tayanardi, u esa
--     sukut ('all') da null = cheklovsiz. Ya'ni `allowed_pages=['hodim']`
--     bo'lgan (jurnal ham, hisobot ham YOPIQ) foydalanuvchi
--     `GET /rest/v1/v_entry_maydon` bilan BUTUN KOMPANIYA metadatasini
--     o'qiy olardi. `jurnal_v2*` da bu qorovul allaqachon bor
--     (`jurnal_page_ok('jurnal')`) — shu bo'shliq to'ldiriladi.
--
-- 🔴 ADDITIV: yangi ustun/jadval yo'q, imzo o'zgarmaydi
--    (`xm_entry_yoz_ok(uuid)` AYNAN o'sha imzo — `create or replace`),
--    yangi funksiya bitta: `xm_korish_ok()`.
--
-- 🔴 TARTIB: bu fayl PROVODKA_XARAJAT_MAYDON.sql DAN KEYIN RUN qilinadi.
--    ⚠️ Agar kelajakda PROVODKA_XARAJAT_MAYDON.sql QAYTA RUN qilinsa,
--    u eski (yumshoq) ta'riflarni tiklaydi — SHU FAYLNI HAM QAYTA RUN
--    QILING. (O'sha faylda ikkala joyga eslatma izohi qo'yilgan.)
--
-- Asilbek qo'lda RUN qiladi. Idempotent.
-- =====================================================================


-- #####################################################################
-- ##  1-BO'LIM — YOZISH: xm_entry_yoz_ok() FAIL-CLOSED EGALIK        ##
-- #####################################################################
-- TANLANGAN VARIANT: (a) — 5-band (egalik) fail-closed.
--
-- NEGA (b) EMAS ("6-bandni qat'iyroq qil: op_kassa_ids bo'yicha haqiqiy
-- tekshiruv, `kassa_scope='all'` da ham"):
--   1) `kassa_scope='all'` da `op_kassa_ids` BO'SH bo'ladi — "haqiqiy
--      tekshiruv" amalda "ro'yxati bo'lmagan hammani rad et" degani.
--      Bu METADATA ni PULDAN QAT'IYROQ qilib qo'yardi: aynan o'sha
--      foydalanuvchi `entry_line` triggeridan (u ham `perm_check_accounts`
--      ishlatadi) bemalol o'tib PUL yozuvini yozaveradi, lekin o'z
--      yozuvining yorlig'ini yoza olmasdi. Ikki qorovul ikki xil qoidaga
--      bo'linardi — bu faylning butun mantig'i esa "bitta qoida, bitta
--      funksiya" ustiga qurilgan.
--   2) (b) haqiqiy tahdidni YOPMAYDI: ro'yxati bor ikki hodim bitta
--      kassada ishlasa, ular bir-birining yozuvini baribir tahrirlardi.
--      Tahdid — BEGONA YOZUV, kassa emas.
--   3) (a) BUGUNGI UI ni umuman o'zgartirmaydi (pastdagi "ESKI YOZUVLAR"
--      bandiga qara) va tahdidni aynan ildizidan kesadi.
--
-- 🔴 ESKI YOZUVLAR BILAN NIMA BO'LADI (ochiq yozamiz):
--   * `created_by` bo'sh yoki MATN ('aros_sync', 'tovar_sync', …) bo'lgan
--     yozuvga endi FAQAT ADMIN maydon qiymati yoza/o'chira oladi.
--     Oddiy foydalanuvchi uchun bu yo'l TO'LIQ YOPILADI.
--   * Bugungi UI dan hech narsa yo'qolmaydi: `hodim-dev.html`,
--     `professional-dev.html`, `provodka-dev.html` maydon qiymatini
--     FAQAT o'zi hozir yaratgan yozuvga yozadi (tartib: entry ->
--     entry_line -> entry_maydon_yoz). Eski yozuvni tahrirlaydigan
--     ekran YO'Q — `jurnal-dev.html` va `hisobot-dev.html` faqat O'QIYDI.
--   * Ya'ni bu o'zgarish "yo'qotilgan imkoniyat" emas, "hech qachon
--     ishlatilmagan, lekin ochiq turgan eshik".
--
-- 🔴 OLD SHART — PROVODKA_IJROCHI.sql:
--   YANGI yozuvda `entry.created_by` `trg_entry_ijrochi` BEFORE INSERT
--   trigger'i bilan avtomat to'ladi (`auth.uid()`). Bu trigger BO'LMASA
--   yangi yozuvlarda ham `created_by` bo'sh qoladi va maxsus maydon
--   qiymati ADMIN dan boshqaga YOZILMAYDI (klient buni jimgina yutmaydi:
--   `mxdWarn` bilan "qo'shimcha maydon yozilmadi: …" deb aytadi).
--   Pastdagi TEKSHIRUV 2-bandi trigger borligini tasdiqlaydi — RUN dan
--   oldin SHUNI ko'ring.
--
-- Tartib (o'zgargan joy faqat 5-band):
--   1) p_entry null / auth.uid() null            -> false
--   2) yozuv topilmadi                            -> false
--   3) yozuv O'CHIRILGAN (is_deleted)             -> false
--   4) is_admin()                                 -> true
--   5) EGALIK — created_by uuid EMAS yoki MENIKI EMAS -> false  🔴 YANGI
--   6) PUL GUARDI: perm_check_accounts (o'zgarmagan)
--   7) satrsiz yozuv                              -> false
-- #####################################################################
create or replace function xm_entry_yoz_ok(p_entry uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_del boolean;
  v_raw text;
  v_own uuid;
  v_ids uuid[];
begin
  if p_entry is null or v_uid is null then return false; end if;

  -- ⚠️ `created_by` USTUN TURI NOMA'LUM (repoda ba'zan uuid, ba'zan matn) —
  --    PROVODKA_IJROCHI.sql dagi `to_jsonb(e)->>'created_by'` naqshi.
  select coalesce(e.is_deleted, false), nullif(btrim(coalesce(to_jsonb(e) ->> 'created_by', '')), '')
    into v_del, v_raw
    from entry e where e.id = p_entry;
  if not found then return false; end if;
  if v_del     then return false; end if;

  if is_admin() then return true; end if;

  -- ---- 5) EGALIK — FAIL-CLOSED --------------------------------------
  -- Avval: uuid shaklida bo'lmasa tekshiruv O'TKAZIB YUBORILARDI va
  -- qaror 6-bandga (u esa sukutda hammaga `true`) qolardi.
  -- Endi: egalikni ISBOTLAB bo'lmasa — rad.
  if v_raw is null or v_raw !~ '^[0-9a-fA-F-]{36}$' then
    return false;
  end if;
  begin
    v_own := v_raw::uuid;
  exception when others then
    return false;            -- buzuq uuid ham egalik ISBOTI emas (22P02 bilan yiqilmaymiz)
  end;
  if v_own is distinct from v_uid then return false; end if;

  -- ---- 6) PUL GUARDI (O'ZGARMAGAN) ----------------------------------
  -- `entry_line` triggeri bilan AYNAN bitta funksiya: ikki joyda ikki xil
  -- qoida paydo bo'lmasin (yuqoridagi "nega (b) emas" 1-bandi).
  select coalesce(array_agg(distinct l.account_id), '{}'::uuid[]) into v_ids
    from entry_line l where l.entry_id = p_entry;
  if array_length(v_ids, 1) is null then return false; end if;   -- satrsiz -> fail-closed

  return coalesce(perm_check_accounts(v_ids), false);
end $fn$;

revoke all on function xm_entry_yoz_ok(uuid) from public, anon;
-- 🔴 GRANT SHART: RLS policy ichida chaqiriladi (policy chaqiruvchi huquqi
--    bilan bajariladi). Javob faqat "MEN shu yozuvga yoza olamanmi".
grant execute on function xm_entry_yoz_ok(uuid) to authenticated;

comment on function xm_entry_yoz_ok(uuid) is
  'Yozuvga maxsus maydon qiymatini yozish mumkinmi (FAIL-CLOSED): ochirilmagan + (admin | ISBOTLANGAN muallif) + '
  'entry_line hisoblarida amaliyot ruxsati (perm_check_accounts). created_by uuid emas (bosh/matn) -> faqat admin. '
  'PROVODKA_MAYDON_QOROVUL.sql da qattiqlashtirilgan.';


-- #####################################################################
-- ##  2-BO'LIM — O'QISH: entry_maydon_sel ga SAHIFA QOROVULI          ##
-- #####################################################################
-- `xm_page_ok()` ICHKI (authenticated dan revoke qilingan) — uni policy
-- ichidan TO'G'RIDAN chaqirib bo'lmaydi: policy CHAQIRUVCHI huquqi bilan
-- bajariladi va `permission denied for function xm_page_ok` berardi.
-- Shuning uchun granted DEFINER o'ram: `xm_korish_ok()`.
create or replace function xm_korish_ok()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  -- Maxsus maydon qiymatlarini KO'RSATADIGAN ikki sahifa:
  --   jurnal-dev.html  (chip + `refreshMxd`)
  --   hisobot-dev.html (chip + "To'liq ro'yxat" ostqatori va kesimi)
  -- `hodim` ATAYLAB yo'q: u faqat YOZADI (o'qimaydi), va `hodim` kaliti
  -- `perm_pages()` ro'yxatida umuman bo'lmagani uchun `xm_page_ok('hodim')`
  -- baribir false qaytarardi.
  return xm_page_ok('jurnal') or xm_page_ok('hisobot');
end $fn$;

revoke all on function xm_korish_ok() from public, anon;
grant execute on function xm_korish_ok() to authenticated;   -- RLS policy ichida

comment on function xm_korish_ok() is
  'ICHKI-ish, granted: maxsus maydon QIYMATLARINI korish sahifa ruxsati (jurnal YOKI hisobot, fail-closed). '
  'entry_maydon_sel policysi shunga tayanadi.';

-- ---------------------------------------------------------------------
-- entry_maydon_sel — sahifa qorovuli + mavjud kassa qoidasi
-- ---------------------------------------------------------------------
-- 🔴 IKKI shox, ATAYLAB:
--   (1) `xm_korish_ok()` — jurnal/hisobot ochiq bo'lsa KO'RISH mumkin
--       (mavjud kassa cheklovi ustiga qo'shiladi, uni almashtirmaydi).
--   (2) `xm_entry_yoz_ok()` — YOZUVCHI o'z yozuvi ustida ishlayapti.
--       BUSIZ YOZISH YO'LI SINARDI: `entry_maydon_yoz()` ichida
--       `on conflict do update` (mavjud qatorni O'QIYDI) va bo'sh qiymatda
--       `delete … where` bor — Postgres bunday paytda SELECT policy'sini
--       ham qo'llaydi. `allowed_pages=['hodim']` bo'lgan hodim (jurnal ham,
--       hisobot ham yopiq) qiymatni QAYTA saqlaganda yoki tozalaganda
--       jimgina rad etilardi. Bu shox yangi ma'lumot OCHMAYDI: u allaqachon
--       o'sha yozuvga YOZA oladigan (ya'ni egasi bo'lgan) foydalanuvchi.
--   ⚠️ `(select …)` — InitPlan: so'rovga BIR MARTA hisoblanadi, har qatorga
--      emas (100 yozuvli jurnalda sezilarli farq). `xm_entry_yoz_ok`
--      qatorga bog'liq, shuning uchun u `(select …)` ga o'ralmaydi —
--      lekin birinchi shox rost bo'lsa umuman baholanmaydi.
drop policy if exists entry_maydon_sel on entry_maydon;
create policy entry_maydon_sel on entry_maydon
  for select to authenticated
  using (
    (
      (select xm_korish_ok())
      or xm_entry_yoz_ok(entry_maydon.entry_id)
    )
    and (
      (select perm_view_pul_ids()) is null
      or exists (
        select 1 from entry_line l
         where l.entry_id = entry_maydon.entry_id
           -- 🔴 `coalesce(…)` SHART: `any((select f()))` da qavs pastki
           --    so'rov deb o'qiladi va 42883 beradi. `coalesce` uni skalar
           --    ifoda qiladi; InitPlan afzalligi saqlanadi.
           and l.account_id = any(coalesce((select perm_view_pul_ids()), '{}'::uuid[])))
    )
  );

comment on policy entry_maydon_sel on entry_maydon is
  'Korish: (jurnal|hisobot sahifasi RUXSATI yoki yozuvning egasi) VA ruxsat etilgan pul hisobi qatnashgan yozuv.';


-- #####################################################################
-- ##  3-BO'LIM — PostgREST sxema keshi                                ##
-- #####################################################################
notify pgrst, 'reload schema';


-- =====================================================================
-- TEKSHIRUV (RUN dan keyin — faqat SELECT)
-- ---------------------------------------------------------------------
-- 🔴 Jonli chaqiruv YO'Q: SQL editorda `auth.uid()` NULL bo'lgani uchun
--    `xm_entry_yoz_ok(...)` doim false, `xm_korish_ok()` doim false
--    qaytaradi — bu XATO EMAS, fail-closed ta'rifning o'zi.
-- =====================================================================

-- 1) Funksiyalar o'rnidami + definer + huquqlar (anon HECH QAYERDA)
select p.proname, p.prosecdef as definer,
       has_function_privilege('anon',          p.oid, 'execute') as anon_ok,
       has_function_privilege('authenticated', p.oid, 'execute') as auth_ok
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('xm_entry_yoz_ok', 'xm_korish_ok', 'xm_page_ok')
 order by p.proname;
-- Kutilgan: xm_entry_yoz_ok  definer=t anon=f auth=t
--           xm_korish_ok     definer=t anon=f auth=t
--           xm_page_ok       definer=t anon=f auth=f   (ICHKI — o'zgarmaydi)

-- 2) 🔴 OLD SHART: `entry.created_by` ni avtomat to'ldiradigan trigger
--    (PROVODKA_IJROCHI.sql). Bo'lmasa — o'sha faylni AVVAL RUN qiling.
select exists (
  select 1 from pg_trigger t
   where t.tgrelid = 'public.entry'::regclass
     and not t.tgisinternal
     and t.tgname = 'trg_entry_ijrochi') as ijrochi_trigger_bor;

-- 3) Policy o'rnidami (entry_maydon uchun 4 ta bo'lishi kerak)
select polname, polcmd
  from pg_policy
 where polrelid = 'public.entry_maydon'::regclass
 order by polname;

-- 4) Yangi SELECT policy ifodasida sahifa qorovuli bormi
select polname, pg_get_expr(polqual, polrelid) as using_ifoda
  from pg_policy
 where polrelid = 'public.entry_maydon'::regclass
   and polname = 'entry_maydon_sel';
-- Kutilgan: ifoda ichida `xm_korish_ok()` VA `xm_entry_yoz_ok(entry_id)` bo'lsin.

-- 5) Nechta yozuvda egalik ISBOTLANMAGAN (ya'ni endi faqat admin yozadi)
select count(*) filter (where (to_jsonb(e) ->> 'created_by') ~ '^[0-9a-fA-F-]{36}$') as egasi_bor,
       count(*) filter (where nullif(btrim(coalesce(to_jsonb(e) ->> 'created_by', '')), '') is null) as bosh,
       count(*) filter (where nullif(btrim(coalesce(to_jsonb(e) ->> 'created_by', '')), '') is not null
                          and (to_jsonb(e) ->> 'created_by') !~ '^[0-9a-fA-F-]{36}$')                as matn
  from entry e;


-- =====================================================================
-- ROLLBACK (kerak bo'lsa — PROVODKA_XARAJAT_MAYDON.sql ni QAYTA RUN
-- qilish yetarli: u ikkala ta'rifni ham eski holiga qaytaradi.
-- Faqat `xm_korish_ok()` qoladi, u hech qayerdan chaqirilmaydi:
--   drop function if exists xm_korish_ok();
--   notify pgrst, 'reload schema';
-- =====================================================================
