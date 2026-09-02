-- =====================================================================
-- PROVODKA_JADVAL_2.sql
-- Xarajatga JADVAL biriktirish (Excel nusxasi / .xlsx) — 4-BOSQICH (SQL)
-- ---------------------------------------------------------------------
-- Brief: BRIEF_PROVODKA_JADVAL.md, "4-5-BOSQICH" bo'limi.
-- Asilbek: «Excel ko'p narsaga kerak bo'lishi mumkin — sozlamalarga Excel
-- katakchasi qo'sh, yoqilsa hozirgidek ishlasin; Ruxsat so'rash modalida
-- ham shu turga Excel yoqiq bo'lsa yuklash imkoni bo'lsin va so'rovni
-- qabul qiluvchi uni ko'ra olsin.»
--
-- To'liq ADDITIVE: yangi ustun (accounts.excel_jadval, ruxsat_sorov.jadval)
-- + 5 ta mavjud RPC ning ENG OXIRGI versiyasiga qo'shimcha shox/kalit
-- qo'shilgan nusxasi (imzo/returns/grant/comment o'zgarmagan) + 1 ta
-- YANGI RPC (ruxsat_jadval_yoz).
-- Manba (bayt-ma-bayt asos):
--   set_modda_flag        <- PROVODKA_RASM_DETECT.sql   (108-141)
--   ruxsat_yopiq_moddalar <- PROVODKA_RUXSAT_SOROV.sql  (186-222)
--   ruxsat_qator          <- PROVODKA_RUXSAT_SOROV.sql  (386-439)
--   ruxsat_tasdiq         <- PROVODKA_RUXSAT_SOROV.sql  (549-669)
--   sorov_qator           <- PROVODKA_SOROVLAR.sql      (573-622)
--
-- ## OLD SHART (bazada bo'lishi kerak)
--   PROVODKA_JADVAL.sql       -> entry.jadval, entry_jadval_yoz(text,jsonb)
--   PROVODKA_RASM_DETECT.sql  -> set_modda_flag(uuid,text,boolean)
--   PROVODKA_RUXSAT_SOROV.sql -> ruxsat_sorov, ruxsat_yopiq_moddalar,
--                                 ruxsat_qator, ruxsat_tasdiq
--   PROVODKA_SOROVLAR.sql     -> sorovlar, sorov_qator
--
-- ## QOIDALAR (CLAUDE.md, buzilmasin)
--   * anonim `do` bloki YO'Q — har `do` bloki NOMLANGAN teg bilan.
--   * har funksiya tanasi NOMLANGAN dollar-teg (fn) bilan o'raladi.
--   * izohda dollar-qavs ($+$ yonma-yon) YO'Q.
--   * hammasi ADDITIVE: eski jadval/ustun/funksiya imzosi buzilmaydi.
--   * idempotent: qayta RUN qilish xavfsiz.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (faqat select/exception)        ##
-- #####################################################################

do $jadval2_pre$
begin
  if not exists (select 1 from information_schema.columns
                  where table_name = 'entry' and column_name = 'jadval') then
    raise exception 'entry.jadval yo''q — avval PROVODKA_JADVAL.sql ni bajaring';
  end if;
  if to_regprocedure('public.entry_jadval_yoz(text,jsonb)') is null then
    raise exception 'entry_jadval_yoz(text,jsonb) yo''q — avval PROVODKA_JADVAL.sql ni bajaring';
  end if;
  if to_regprocedure('public.set_modda_flag(uuid,text,boolean)') is null then
    raise exception 'set_modda_flag(uuid,text,boolean) yo''q — avval PROVODKA_RASM_DETECT.sql (yoki oldingi) ni bajaring';
  end if;
  if to_regclass('public.ruxsat_sorov') is null then
    raise exception 'ruxsat_sorov jadvali yo''q — avval PROVODKA_RUXSAT_SOROV.sql ni bajaring';
  end if;
  if to_regprocedure('public.ruxsat_yopiq_moddalar()') is null then
    raise exception 'ruxsat_yopiq_moddalar() yo''q — avval PROVODKA_RUXSAT_SOROV.sql ni bajaring';
  end if;
  if to_regprocedure('public.ruxsat_qator(ruxsat_sorov,uuid)') is null then
    raise exception 'ruxsat_qator(ruxsat_sorov,uuid) yo''q — avval PROVODKA_RUXSAT_SOROV.sql ni bajaring';
  end if;
  if to_regprocedure('public.ruxsat_tasdiq(uuid)') is null then
    raise exception 'ruxsat_tasdiq(uuid) yo''q — avval PROVODKA_RUXSAT_SOROV.sql ni bajaring';
  end if;
  if to_regclass('public.sorovlar') is null then
    raise exception 'sorovlar jadvali yo''q — avval PROVODKA_SOROVLAR.sql ni bajaring';
  end if;
  if to_regprocedure('public.sorov_qator(sorovlar,uuid)') is null then
    raise exception 'sorov_qator(sorovlar,uuid) yo''q — avval PROVODKA_SOROVLAR.sql ni bajaring';
  end if;
end
$jadval2_pre$;


-- #####################################################################
-- ##  1-BO'LIM — accounts.excel_jadval ustuni                        ##
-- #####################################################################

alter table accounts
  add column if not exists excel_jadval boolean not null default false;

comment on column accounts.excel_jadval is
  'Xarajat moddasi: Excel/jadval biriktirish yoqilgan. sozlama -> Excel katakchasi. '
  'true bolsa hodim.html shu moddaga yozganda jadval (paste/.xlsx) yuklashi mumkin.';


-- #####################################################################
-- ##  2-BO'LIM — set_modda_flag(uuid,text,boolean) — 'excel' shoxi   ##
-- #####################################################################
-- 🔴 IMZO O'ZGARMAYDI (uuid, text, boolean) — PROVODKA_RASM_DETECT.sql
--    dagi ENG OXIRGI versiya (7 shox) SO'ZMA-SO'Z saqlandi, faqat 'excel'
--    shoxi qo'shildi.
create or replace function set_modda_flag(p_account uuid, p_flag text, p_bool boolean)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not is_admin() then
    raise exception 'Faqat admin' using errcode = '42501';
  end if;
  if p_flag = 'chek' then
    update accounts set chek_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'izoh' then
    update accounts set izoh_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'davr' then
    update accounts set davr_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'filial' then
    update accounts set filial_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'ovqat' then
    update accounts set ovqat_modda = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'ai' then
    update accounts set ai_tekshir = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'spidometr' then
    update accounts set spidometr_ai = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'excel' then
    update accounts set excel_jadval = coalesce(p_bool, false) where id = p_account;
  else
    raise exception 'Nomalum bayroq';
  end if;
end $fn$;

revoke all on function set_modda_flag(uuid, text, boolean) from public, anon;
grant execute on function set_modda_flag(uuid, text, boolean) to authenticated;

comment on function set_modda_flag(uuid, text, boolean) is
  'Admin: xarajat moddasi bayrogi (chek|izoh|davr|filial|ovqat|ai|spidometr|excel) yoqadi yoki ochiradi.';


-- #####################################################################
-- ##  3-BO'LIM — ruxsat_sorov.jadval ustuni + check constraint       ##
-- #####################################################################

alter table ruxsat_sorov add column if not exists jadval jsonb;

comment on column ruxsat_sorov.jadval is
  'Ruxsat so''rashda izohdan alohida saqlangan jadval (Excel nusxasi/.xlsx). '
  'Shakl entry.jadval bilan bir xil (BRIEF_PROVODKA_JADVAL.md). Tasdiqlansa entry.jadval ga ko''chadi.';

do $ruxsat_jadval_chk$
begin
  if not exists (select 1 from pg_constraint where conname = 'ruxsat_sorov_jadval_chk') then
    alter table ruxsat_sorov
      add constraint ruxsat_sorov_jadval_chk
      check (jadval is null or (jsonb_typeof(jadval) = 'object' and pg_column_size(jadval) <= 120000));
  end if;
end
$ruxsat_jadval_chk$;


-- #####################################################################
-- ##  4-BO'LIM — ruxsat_yopiq_moddalar() — 'excel' kaliti qo'shiladi ##
-- #####################################################################
-- 🔴 PROVODKA_RUXSAT_SOROV.sql (186-222) dagi ENG OXIRGI tananing
--    VERBATIM nusxasi. Yagona farq: jsonb_build_object ga 'excel' kaliti.
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

  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name,
                             'excel', coalesce(a.excel_jadval, false))
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
  'Chaqiruvchi uchun YOPIQ xarajat moddalari royxati (rbac_modda_ok false). Admin -> bosh massiv. '
  'YANGI (PROVODKA_JADVAL_2.sql): har element "excel" kaliti (excel_jadval bayrogi).';


-- #####################################################################
-- ##  5-BO'LIM — ruxsat_jadval_yoz(text, jsonb) — YANGI               ##
-- #####################################################################
-- `entry_jadval_yoz` (PROVODKA_JADVAL.sql, 4-BO'LIM) ning aynan naqshi,
-- faqat `ruxsat_sorov` uchun. `ruxsat_yarat` muvaffaqiyatidan KEYIN
-- klient shu RPC bilan jadvalni alohida biriktiradi.
-- 🔴 `ruxsat_sorov.hodim_id` uuid — entry.created_by dagi kabi tur
--    noaniqligi YO'Q, to'g'ridan taqqoslanadi.
create or replace function ruxsat_jadval_yoz(p_ext_ref text, p_jadval jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_ext text := nullif(btrim(p_ext_ref), '');
  r     ruxsat_sorov;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'Avtorizatsiya yo''q');
  end if;
  if v_ext is null then
    return jsonb_build_object('ok', false, 'error', 'ext_ref berilmagan');
  end if;
  if jsonb_typeof(p_jadval) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'error', 'Jadval formati noto''g''ri');
  end if;
  if pg_column_size(p_jadval) > 120000 then
    return jsonb_build_object('ok', false, 'error', 'Jadval hajmi juda katta');
  end if;

  select * into r from ruxsat_sorov where ext_ref = v_ext limit 1;

  if r.id is null then
    return jsonb_build_object('ok', false, 'error', 'Sorov topilmadi');
  end if;
  if r.hodim_id is distinct from v_uid then
    return jsonb_build_object('ok', false, 'error', 'Bu sorov sizniki emas');
  end if;
  if r.created_at is null or r.created_at < now() - interval '30 minutes' then
    return jsonb_build_object('ok', false, 'error', 'Vaqt tugagan (30 daqiqadan oshgan)');
  end if;
  if r.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'Sorov allaqachon hal qilingan');
  end if;
  if r.jadval is not null then
    return jsonb_build_object('ok', false, 'error', 'Jadval allaqachon biriktirilgan');
  end if;

  update ruxsat_sorov set jadval = p_jadval where id = r.id;

  return jsonb_build_object('ok', true);
end $fn$;

revoke all on function ruxsat_jadval_yoz(text, jsonb) from public, anon;
grant execute on function ruxsat_jadval_yoz(text, jsonb) to authenticated;

comment on function ruxsat_jadval_yoz(text, jsonb) is
  'Ruxsat so''rash oqimida (ruxsat_yarat) allaqachon yaratilgan so''rovga jadval keyin biriktiriladi. '
  'entry_jadval_yoz bilan bir xil naqsh. Shartlar: auth.uid() bor, ext_ref topildi, so''rov o''ziniki, '
  '30 daqiqa ichida, status=pending, jadval hali bo''sh, hajm <= 120000 bayt.';


-- #####################################################################
-- ##  6-BO'LIM — ruxsat_qator(ruxsat_sorov, uuid) — jadval kalitlari ##
-- #####################################################################
-- 🔴 PROVODKA_RUXSAT_SOROV.sql (386-439) dagi ENG OXIRGI tananing
--    VERBATIM nusxasi. Yagona farq: 'jadval_n'/'jadval_jami' kalitlari.
--    To'liq jadval ro'yxatga KIRMAYDI — bosilganda `ruxsat_sorov.jadval`
--    RLS bilan alohida o'qiladi.
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
    'modda_menda_yoq',       (not (is_admin() or rbac_modda_ok(r.modda_id))),
    -- YANGI (PROVODKA_JADVAL_2.sql): to'liq jadval emas, faqat ozet.
    'jadval_n',              (r.jadval->>'n')::int,
    'jadval_jami',           (r.jadval->>'jami')::numeric
  );
end $fn$;

revoke all on function ruxsat_qator(ruxsat_sorov, uuid) from public, anon, authenticated;

comment on function ruxsat_qator(ruxsat_sorov, uuid) is
  'ICHKI: bitta ruxsat sorovi qatorining jsonb shakli. Ikkala royxat ham shuni ishlatadi. '
  'YANGI (PROVODKA_JADVAL_2.sql): jadval_n/jadval_jami ozet (tolik jadval alohida oqiladi).';


-- #####################################################################
-- ##  7-BO'LIM — sorov_qator(sorovlar, uuid) — jadval kalitlari      ##
-- #####################################################################
-- 🔴 PROVODKA_SOROVLAR.sql (573-622) dagi ENG OXIRGI tananing VERBATIM
--    nusxasi. Yagona farq: 'jadval_n'/'jadval_jami' kalitlari — xarajat
--    entry'sidan `to_jsonb(e)` naqshi bilan (entry.jadval ustuni yo'q
--    bo'lsa ham funksiya yiqilmaydi — null qaytadi).
create or replace function sorov_qator(s sorovlar, p_uid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_sub         text;
  v_jadval_n    int;
  v_jadval_jami numeric;
begin
  select nullif(btrim(coalesce(subtitle, '')), '') into v_sub
    from accounts where id = s.kassa_id;

  if s.xarajat_entry_id is not null then
    select (to_jsonb(e) -> 'jadval' ->> 'n')::int,
           (to_jsonb(e) -> 'jadval' ->> 'jami')::numeric
      into v_jadval_n, v_jadval_jami
      from entry e where e.id = s.xarajat_entry_id;
  end if;

  return jsonb_build_object(
    'id',                     s.id,
    'sorovchi_id',            s.sorovchi_id,
    'sorovchi_nom',           sorov_ism(s.sorovchi_id, s.kassa_id),
    'sorovchi_sub',           v_sub,
    'kimdan_id',              s.kimdan_id,
    'kimdan_nom',             sorov_ism(s.kimdan_id, s.kimdan_kassa_id),
    'summa',                  s.summa,
    'izoh',                   s.izoh,
    'status',                 s.status,
    'jonatilgan_summa',       s.jonatilgan_summa,
    'qaror_izoh',             s.rad_izoh,
    'qaror_kim',              case when s.decided_by is null then null
                                   else sorov_ism(s.decided_by, s.kimdan_kassa_id) end,
    'qaror_vaqt',             s.decided_at,
    'sana',                   s.created_at,
    'entry_id',               s.xarajat_entry_id,
    'jonatma_entry_id',       s.jonatma_entry_id,
    -- 🔴 `xarajat_summa` ATAYLAB YUBORILMAYDI (QA topilmasi 2026-08-25).
    --    Klient sukut so'rov summasini `ceil((xarajat - qoldiq)/1000)*1000`
    --    deb hisoblaydi, ya'ni tasdiqlovchi `qoldiq = xarajat_summa - summa`
    --    ni ±1000 aniqlikda HISOBLAB CHIQARARDI — bu so'rovchining balansi.
    --    ".sorov-ui.md": boshqa odamning balansi hech qanday shaklda
    --    ko'rinmaydi. Xarajat summasi UI da hech qayerda chizilmaydi.
    'xarajat_yopildi',        s.xarajat_yopildi,
    'meniki',                 (s.sorovchi_id = p_uid),
    -- 🔴 SERVER hisoblaydi (klient `kimdan_id === my_uid` deb taxmin
    --    QILMASIN): 2026-08-25 dan ADMIN ham qaror qila oladi (8.1),
    --    lekin pul SO'ROV KELGAN ODAMNING kassasidan chiqadi.
    'men_qaror_qila_olaman',  (s.status = 'pending'
                               and (s.kimdan_id = p_uid or is_admin())),
    -- YANGI (PROVODKA_JADVAL_2.sql): xarajat yozuviga biriktirilgan jadval
    -- ozeti (entry.jadval, to_jsonb naqshi — ustun yo'q bo'lsa null).
    'jadval_n',               v_jadval_n,
    'jadval_jami',            v_jadval_jami
  );
end $fn$;

revoke all on function sorov_qator(sorovlar, uuid) from public, anon, authenticated;

comment on function sorov_qator(sorovlar, uuid) is
  'ICHKI: bitta sorov qatorining jsonb shakli (.sorov-ui.md §0.5-b). Ikkala royxat ham shuni ishlatadi. '
  'YANGI (PROVODKA_JADVAL_2.sql): jadval_n/jadval_jami — xarajat entry.jadval dan (to_jsonb naqshi).';


-- #####################################################################
-- ##  8-BO'LIM — ruxsat_tasdiq(uuid) — jadval entry ga ko'chadi       ##
-- #####################################################################
-- 🔴 PROVODKA_RUXSAT_SOROV.sql (549-669) dagi ENG OXIRGI tananing
--    VERBATIM nusxasi. Yagona farq: `insert into entry` ga `jadval`
--    ustuni + `r.jadval` qiymati. Boshqa hech narsa o'zgarmaydi.
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
  insert into entry (entry_date, description, source, status, ext_ref, created_by, filial_ids, jadval)
  values ((now() at time zone 'Asia/Tashkent')::date,
          'Ruxsat bilan: ' || r.izoh,
          'manual',
          'posted',
          'ruxsat:' || r.id::text,
          r.hodim_id,
          -- ⚠️ ONGLI QAROR (QA 2026-08-29): ruxsat sorovida FILIAL tushunchasi yoq,
          --    shuning uchun filial_ids bosh. Oqibat: filial-modda OYLIK LIMITI
          --    (sorov_post_tosiq limit shoxi, trg_limit_guard_entry_line) bu yozuvga
          --    TAALLUQLI EMAS — faqat kassa qoldigi (sorov_kassa_bal) tekshiriladi.
          --    Ruxsatni odam (tasdiqlovchi) beradi — limit orniga shu qaror turadi.
          --    Filial kerak bolsa: ruxsat_yarat ga p_filial_ids qoshiladi (keyingi bosqich).
          '{}'::uuid[],
          -- YANGI (PROVODKA_JADVAL_2.sql): so'rovga biriktirilgan jadval xarajat yozuviga ko'chadi.
          r.jadval)
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
  'Idempotent: for update + status tekshiruvi + ext_ref UNIQUE. '
  'YANGI (PROVODKA_JADVAL_2.sql): so''rovga biriktirilgan jadval (r.jadval) entry.jadval ga ko''chadi.';


-- #####################################################################
-- ##  PostgREST sxema keshi                                          ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  9-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)             ##
-- #####################################################################

select exists (select 1 from information_schema.columns
                where table_name = 'accounts' and column_name = 'excel_jadval')  as excel_jadval_ustun_bor,
       exists (select 1 from information_schema.columns
                where table_name = 'ruxsat_sorov' and column_name = 'jadval')    as ruxsat_jadval_ustun_bor;

select to_regprocedure('public.set_modda_flag(uuid,text,boolean)')      is not null as fn_set_modda_flag,
       to_regprocedure('public.ruxsat_yopiq_moddalar()')                is not null as fn_ruxsat_yopiq_moddalar,
       to_regprocedure('public.ruxsat_jadval_yoz(text,jsonb)')          is not null as fn_ruxsat_jadval_yoz,
       to_regprocedure('public.ruxsat_qator(ruxsat_sorov,uuid)')        is not null as fn_ruxsat_qator,
       to_regprocedure('public.sorov_qator(sorovlar,uuid)')             is not null as fn_sorov_qator,
       to_regprocedure('public.ruxsat_tasdiq(uuid)')                    is not null as fn_ruxsat_tasdiq;


-- =====================================================================
-- ROLLBACK (kerak bolsa, Asilbek qollab RUN qiladi — hech narsa avtomat emas)
-- ---------------------------------------------------------------------
-- drop function if exists ruxsat_jadval_yoz(text, jsonb);
-- -- ruxsat_qator/sorov_qator/ruxsat_tasdiq/ruxsat_yopiq_moddalar/set_modda_flag
-- -- ni oldingi versiyaga qaytarish uchun tegishli eski faylni qayta RUN qiling
-- -- (PROVODKA_RUXSAT_SOROV.sql / PROVODKA_SOROVLAR.sql / PROVODKA_RASM_DETECT.sql).
-- alter table ruxsat_sorov drop constraint if exists ruxsat_sorov_jadval_chk;
-- -- ruxsat_sorov.jadval / accounts.excel_jadval ustunlarini OLIB TASHLASH TAQIQ — faqat qoldiring.
-- =====================================================================
