-- =====================================================================
-- PROVODKA — CEO "To'liq ro'yxat"ga MAXSUS MAYDONLAR (additive)
-- ---------------------------------------------------------------------
-- MUAMMO (QA 1-band):
--   `hisobot-dev.html` ning CEO "To'liq ro'yxat" bloki har qatorda
--   `r.maydonlar` ni kutadi (ostqator + "Maxsus maydon bo'yicha" kesimi
--   + Excel ustuni), lekin manba RPC — `hodim_xarajat_royxat(p_from,p_to)`
--   (PROVODKA_HODIM_V4.sql:103) — bu ustunni QAYTARMAYDI. Klient
--   fail-closed yozilgan: sahifa yiqilmaydi, lekin `#mxdGrp` HECH QACHON
--   ko'rinmaydi va Excel ustuni bo'sh qoladi — xususiyat o'lik.
--
-- YECHIM: ADDITIV `hodim_xarajat_royxat_v2(p_from, p_to)`.
--   Eski ustunlar AYNAN o'sha tartibda + `entry_id uuid` + `maydonlar jsonb`.
--
-- 🔴 ESKI IMZOGA TEGILMAYDI. `hodim_xarajat_royxat(date,date)` `drop`
--    QILINMAYDI va o'zgartirilmaydi — uni PROD `hisobot.html` chaqiradi
--    (dev/prod bitta bazada). Bu fayl faqat YANGI funksiya qo'shadi.
--
-- 🔴 MANTIQ QAYTA YOZILMAYDI — O'RALADI (CLAUDE.md, AI hisobot naqshi):
--    * maydon qiymatlari `v_entry_maydon` dan olinadi (korinish matni
--      SERVERDA bitta joyda yasaladi — jurnal / hisobot / Excel uch xil
--      matn bermasin);
--    * `v_entry_maydon` bo'lmasa (PROVODKA_XARAJAT_MAYDON.sql hali RUN
--      qilinmagan) funksiya ESKISINI o'raydi va `maydonlar` = null
--      qaytaradi — sahifa bugungidek ishlaydi.
--
-- Ruxsat: `is_admin()` — eski funksiya bilan AYNAN bir xil (CEO hisoboti).
-- SECURITY DEFINER, `set search_path = public`, revoke anon. Idempotent.
-- Asilbek qo'lda RUN qiladi. entry insert yo'li o'zgarmaydi.
--
-- OLD SHART (ixtiyoriy, lekin `maydonlar` shusiz doim null bo'ladi):
--   PROVODKA_XARAJAT_MAYDON.sql (jadvallar + `v_entry_maydon`).
-- =====================================================================


-- =====================================================================
-- 1. hodim_xarajat_royxat_v2 — to'liq xarajat ro'yxati + maxsus maydonlar
-- ---------------------------------------------------------------------
-- Qator shakli (klient shunga tayanadi, tartib MUHIM emas — PostgREST
-- kalit nomi bilan beradi, lekin eski 9 ustun nomi O'ZGARMAGAN):
--   entry_date, kassa_code, kassa_name, kassa_subtitle,
--   modda_code, modda_name, summa, izoh, kim,        -- ESKI (v1 bilan bir xil)
--   entry_id, maydonlar                              -- YANGI
--
-- `maydonlar` — jsonb massiv yoki null. Har element `v_entry_maydon`
-- shakli bilan bir xil (`entry_maydonlar(uuid[])` RPC si bilan AYNAN
-- bitta kalit ro'yxati):
--   {maydon_id, nom, maydon_turi, tartib, element_id, element_nom,
--    element_qiymat, rasm_url, qiymat_matn, korinish}
-- Klientdagi `mxdNorm()` `nom` / `maydon_turi` / `korinish` / `rasm_url`
-- kalitlarini o'qiydi — qo'shimcha moslash KERAK EMAS.
--
-- ⚠️ QATOR SONI v1 bilan BIR XIL qoladi: ko'p satrli yozuvda (Dt xarajat ×
--    Kt pul) v1 ham dekart ko'paytma beradi. `maydonlar` YOZUVGA tegishli,
--    ya'ni bir yozuvning har qatorida TAKRORLANADI — klient shuni kutadi
--    (`mxdList(r)` har qatordan alohida o'qiydi).
-- =====================================================================
create or replace function hodim_xarajat_royxat_v2(p_from date, p_to date)
returns table(
  entry_date date, kassa_code text, kassa_name text, kassa_subtitle text,
  modda_code text, modda_name text, summa numeric, izoh text, kim text,
  entry_id uuid, maydonlar jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  -- 🔴 View bor-yo'qligi BIR MARTA, so'rovdan tashqarida tekshiriladi.
  --    Yo'q bo'lsa quyidagi `return query` UMUMAN bajarilmaydi, ya'ni
  --    plpgsql uning rejasini ham tuzmaydi (42P01 bilan yiqilmaymiz).
  v_bor boolean := (to_regclass('public.v_entry_maydon') is not null);
begin
  if not is_admin() then
    raise exception 'Faqat admin ko''ra oladi' using errcode = '42501';
  end if;

  -- ---- ZAXIRA: maxsus maydon tizimi hali o'rnatilmagan ---------------
  -- Eski funksiya O'RALADI (nusxa ko'chirilmaydi) — ikki joyda ikki xil
  -- filtr/tartib paydo bo'lmasin. `is_admin()` u yerda ham tekshiriladi.
  if not v_bor then
    return query
      select r.entry_date, r.kassa_code, r.kassa_name, r.kassa_subtitle,
             r.modda_code, r.modda_name, r.summa, r.izoh, r.kim,
             null::uuid, null::jsonb
        from hodim_xarajat_royxat(p_from, p_to) r;
    return;
  end if;

  -- ---- ASOSIY: v1 ning AYNAN o'sha so'rovi + 2 ustun ------------------
  return query
    select e.entry_date,
           ka.code, ka.name, ka.subtitle,
           ma.code, ma.name,
           dl.debit::numeric,
           e.description,
           pr.full_name,
           e.id,
           mx.arr
      from entry e
      join entry_line dl on dl.entry_id = e.id and dl.debit > 0
      join accounts ma on ma.id = dl.account_id and ma.type = 'xarajat'
      join entry_line kl on kl.entry_id = e.id and kl.credit > 0
      join accounts ka on ka.id = kl.account_id and ka.section = 'pul'
      left join profiles pr on pr.id = e.created_by
      -- 🔴 LATERAL: yozuvga BITTA marta hisoblanadi (qatorga emas).
      --    Bo'sh `korinish` tashlanadi — klient ham shunday qiladi
      --    (`mxdNorm` bo'sh qiymatni null qilib filtrlaydi), ikki tomon
      --    bir xil qatorni sanasin.
      left join lateral (
        select jsonb_agg(jsonb_build_object(
                 'maydon_id',      v.maydon_id,
                 'nom',            v.maydon_nom,
                 'maydon_turi',    v.maydon_turi,
                 'tartib',         v.tartib,
                 'element_id',     v.element_id,
                 'element_nom',    v.element_nom,
                 'element_qiymat', v.element_qiymat,
                 'rasm_url',       v.rasm_url,
                 'qiymat_matn',    v.qiymat_matn,
                 'korinish',       v.korinish)
               order by v.tartib, v.maydon_nom) as arr
          from v_entry_maydon v
         where v.entry_id = e.id
           and nullif(btrim(coalesce(v.korinish, '')), '') is not null
      ) mx on true
     where e.status = 'posted'
       and e.is_deleted = false
       and e.entry_date >= p_from
       and e.entry_date <= p_to
     order by e.entry_date, ka.name, ma.name;
end $fn$;

revoke all on function hodim_xarajat_royxat_v2(date, date) from public, anon;
grant execute on function hodim_xarajat_royxat_v2(date, date) to authenticated;

comment on function hodim_xarajat_royxat_v2(date, date) is
  'CEO: davr ichidagi to''liq xarajat ro''yxati + maxsus maydonlar (entry_id, maydonlar jsonb). '
  'v1 (hodim_xarajat_royxat) TEGILMAGAN — prod hisobot.html uni chaqiradi. '
  'v_entry_maydon yo''q bolsa v1 oraladi va maydonlar null qaytadi. Admin only.';


-- =====================================================================
-- 2. PostgREST sxema keshini yangilash
-- ---------------------------------------------------------------------
-- Busiz yangi funksiya `PGRST202` ("Could not find the function") berib
-- turadi va klient jimgina eski yo'lga tushib qoladi.
-- =====================================================================
notify pgrst, 'reload schema';


-- =====================================================================
-- TEKSHIRUV (RUN dan keyin — faqat SELECT, hech narsa o'zgartirmaydi)
-- ---------------------------------------------------------------------
-- 🔴 Jonli chaqiruv YO'Q: SQL editorda `auth.uid()` NULL, ya'ni
--    `is_admin()` false -> funksiya 42501 berardi. Shuning uchun faqat
--    katalog tekshiriladi.
-- =====================================================================

-- 1) Ikkala imzo ham o'rnidami (v1 SAQLANGAN bo'lishi SHART)
select to_regprocedure('public.hodim_xarajat_royxat(date,date)')    is not null as v1_bor,
       to_regprocedure('public.hodim_xarajat_royxat_v2(date,date)') is not null as v2_bor,
       to_regclass('public.v_entry_maydon')                         is not null as view_bor;

-- 2) Yangi funksiya ustunlari (11 ta: 9 eski + entry_id + maydonlar)
select p.proname,
       pg_get_function_result(p.oid) as natija
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('hodim_xarajat_royxat', 'hodim_xarajat_royxat_v2')
 order by p.proname;

-- 3) Huquqlar: anon YO'Q, authenticated BOR, definer
select p.proname, p.prosecdef as definer,
       has_function_privilege('anon',          p.oid, 'execute') as anon_ok,
       has_function_privilege('authenticated', p.oid, 'execute') as auth_ok
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname = 'hodim_xarajat_royxat_v2';


-- =====================================================================
-- ROLLBACK (kerak bo'lsa)
-- ---------------------------------------------------------------------
-- drop function if exists hodim_xarajat_royxat_v2(date, date);
-- notify pgrst, 'reload schema';
-- (Klient `useMxdV2` naqshi bilan o'zi eski funksiyaga tushadi —
--  hisobot sahifasi ishlashda davom etadi, faqat maydon kesimi yo'qoladi.)
-- =====================================================================
