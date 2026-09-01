-- =====================================================================
-- PROVODKA_KONVERT_V3.sql
-- Konvert: "kurs farqi" (naqd berish/olishda yaxlitlash/qo'lda tuzatish)
-- ---------------------------------------------------------------------
-- Foydalanuvchi QO'LDA ishga tushiradi. Idempotent — qayta-qayta run
-- qilsa bo'ladi. SQL FAQAT ADDITIVE — hech qanday DROP yo'q, mavjud
-- imzolar (convert_start_v2, convert_start, do_convert_v2, do_convert,
-- convert_approve) SAQLANADI.
--
-- 2026-09-01: Supabase'da RUN QILINGAN (Asilbek). Bu fayl bazadagi holat hujjati.
--
-- NIMA UCHUN
-- ---------------------------------------------------------------------
-- Amalda konvert (naqd sotib olish/sotish) paytida berilgan/olingan
-- summa hisoblangan kursdagi summadan ozgina farq qilishi mumkin
-- (yaxlitlash, kassirning qo'lda berishi). `convert_start_v3` bunday
-- holatda ASOSIY konvert yozuvi (do_convert_v2, o'zgarmagan) ustiga
-- ALOHIDA "Konvert kurs farqi" yozuvi qo'shadi — farq Dt=Kt buziladigan
-- uchinchi tomonga yozilmaydi, alohida xarajat/foyda moddasiga tushadi.
--
-- MUHIM FARQ v2'dan: `p_amount` bu yerda HAR DOIM VALYUTADA beriladi
-- (sotib olishda ham, sotishda ham) — v2'da sotib olishda so'mda edi.
-- Bu ataylab: naqd konvertda odam qo'lida turgan narsa har doim
-- "necha dollar/pul birligi" bo'ladi, so'm summasi undan hisoblanadi.
--
-- YANGI OB'EKTLAR (boshqa agentlar uchun kontrakt):
--   * accounts: name='Konvert kurs farqi', type='xarajat' — bitta hisob
--   * convert_request.farq numeric — imzoli farq (musbat=ko'p berilgan)
--   * convert_start_v3(p_from uuid, p_to uuid, p_amount numeric,
--       p_rate numeric, p_note text default null, p_farq numeric default null)
--       returns jsonb — YANGI funksiya, v2 bilan bir xil javob shakli
--       + 'farq_entry_id' (bo'lsa)
--   * convert_approve(p_id uuid) — IMZO O'ZGARMAGAN, ichiga farq yozuvi
--       qo'shildi (r.farq ustunidan, eski so'rovlarda null — ta'sirsiz)
--   * jurnal_savdosiz_ok() returns boolean — klient "SQL RUN qilinganmi" belgisi
-- =====================================================================


-- #####################################################################
-- ##  0. OLD SHART — v2 infratuzilmasi joyida bo'lishi shart          ##
-- #####################################################################
do $do$
begin
  if to_regprocedure('public.convert_start_v2(uuid,uuid,numeric,numeric,text)') is null
     or to_regprocedure('public.do_convert_v2(uuid,uuid,numeric,numeric,numeric,text,text,text)') is null
     or to_regprocedure('public.acc_fc_balance(uuid)') is null
     or to_regprocedure('public.conv_baza_kurs(text)') is null
     or to_regprocedure('public.conv_koridor_foiz()') is null
  then
    raise exception 'Old shart yoq: PROVODKA_KASSA2.sql (2-BOSQICH, konvert v2) avval RUN qilinsin.'
      using errcode = '55000';
  end if;
end
$do$;


-- #####################################################################
-- ##  1. "Konvert kurs farqi" xarajat moddasi                        ##
-- #####################################################################
-- Idempotent: nom + tur bo'yicha bor-yo'qligi tekshiriladi. Kod —
-- sozlama.html avtokod qoidasi bilan bir xil: 94xx blokidagi eng katta
-- kod + 1, hech qanday bo'lmasa 9421 (sozlama.html nextCode('94',9421)).
do $do$
declare
  v_id   uuid;
  v_code text;
  v_next int;
begin
  select id into v_id
    from accounts
   where name = 'Konvert kurs farqi' and type = 'xarajat'
   limit 1;

  if v_id is not null then
    raise notice '1-BAND: "Konvert kurs farqi" hisobi allaqachon bor (id=%).', v_id;
  else
    select coalesce(max(a.code::int), 9420) + 1
      into v_next
      from accounts a
     where a.code ~ '^94[0-9]+$';

    v_code := v_next::text;

    insert into accounts(code, name, type, section, is_active)
    values (v_code, 'Konvert kurs farqi', 'xarajat', 'operatsion', true)
    returning id into v_id;

    raise notice '1-BAND: "Konvert kurs farqi" hisobi OCHILDI — kod % (id=%).', v_code, v_id;
  end if;
end
$do$;


-- #####################################################################
-- ##  2. convert_request.farq — imzoli farq ustuni                   ##
-- #####################################################################
-- musbat = ko'p berilgan (xarajat), manfiy = kam berilgan (foyda)
alter table convert_request add column if not exists farq numeric;

comment on column convert_request.farq is
  'Konvert v3: naqd berilgan/olingan summaning hisoblangan summadan imzoli farqi (so''mda). '
  'Musbat = ko''p berilgan (xarajat), manfiy = kam berilgan (foyda). Eski qatorlarda null.';


-- #####################################################################
-- ##  3. conv_farq_hisob_id() — ICHKI yordamchi, modda id'sini topadi ##
-- #####################################################################
-- 2-band qismidagi hisob 1-bandda yaratiladi/mavjud bo'ladi deb kutiladi.
-- Topilmasa (SQL run qilinmagan yoki hisob o'chirilgan) NULL qaytaradi —
-- chaqiruvchi shu holatni RAISE EXCEPTION bilan ushlaydi (jimgina yutmaydi).
create or replace function conv_farq_hisob_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $fn$
  select id from accounts
   where name = 'Konvert kurs farqi' and type = 'xarajat' and is_active
   order by created_at asc
   limit 1;
$fn$;

revoke all on function conv_farq_hisob_id() from public, anon;


-- #####################################################################
-- ##  4. convert_start_v3 — p_amount HAR DOIM valyutada + qo'lda farq ##
-- #####################################################################
create or replace function convert_start_v3(p_from uuid, p_to uuid, p_amount numeric,
                                            p_rate numeric, p_note text default null,
                                            p_farq numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_who text; v_foiz numeric; v_baza numeric; v_lo numeric; v_hi numeric;
  v_uzs numeric; v_fc numeric; v_cur text; v_yon text;
  v_bal numeric; v_entry uuid; v_req uuid; v_farq_entry uuid;
  f accounts%rowtype; t accounts%rowtype;
  v_fcur text; v_tcur text;
  v_ruxsat boolean;
  v_som_kassa uuid; v_modda uuid;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'Avtorizatsiya kerak');
  end if;

  -- Konvert ruxsati (v2 bilan bir xil naqsh — to_regprocedure orqali,
  -- ikki SQL fayl tartibga bog'lanmasin)
  if to_regprocedure('public.perm_can_convert()') is not null then
    execute 'select perm_can_convert()' into v_ruxsat;
    if not coalesce(v_ruxsat, true) then
      return jsonb_build_object('ok', false, 'error', 'Konvert ruxsati yoq');
    end if;
  end if;

  select coalesce(full_name, 'foydalanuvchi') into v_who from profiles where id = auth.uid();

  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('ok', false, 'error', 'Summa notogri');
  end if;
  if p_rate is null or p_rate <= 0 then
    return jsonb_build_object('ok', false, 'error', 'Kurs notogri');
  end if;

  select * into f from accounts where id = p_from;
  select * into t from accounts where id = p_to;
  if f.id is null or t.id is null then
    return jsonb_build_object('ok', false, 'error', 'Hisob topilmadi');
  end if;
  if p_from = p_to then
    return jsonb_build_object('ok', false, 'error', 'Bir hisobning ozida konvert bolmaydi');
  end if;
  if not f.is_active or not t.is_active then
    return jsonb_build_object('ok', false, 'error', 'Hisob faol emas');
  end if;

  -- Filial asosiy kassasi Aros bilan sinxronlanadi — ikkala tomonda ham taqiq
  if f.kassa_turi = 'filial' or t.kassa_turi = 'filial' then
    return jsonb_build_object('ok', false,
      'error', 'Filial asosiy kassasida konvert qilib bolmaydi (Aros bilan sinxronlanadi). Xarajat kassasidan foydalaning.');
  end if;
  -- 5400 konteyner — unga to'g'ridan pul yozilmaydi
  if f.kassa_turi = 'xarajat_guruh' or t.kassa_turi = 'xarajat_guruh' then
    return jsonb_build_object('ok', false, 'error', 'Guruh hisobida konvert qilib bolmaydi');
  end if;

  v_fcur := coalesce(f.currency, 'UZS');
  v_tcur := coalesce(t.currency, 'UZS');

  if v_fcur = 'UZS' and v_tcur = 'UZS' then
    return jsonb_build_object('ok', false, 'error', 'Ikkala hisob ham somda — bu transfer, konvert emas');
  elsif v_fcur <> 'UZS' and v_tcur <> 'UZS' then
    return jsonb_build_object('ok', false, 'error', 'Avval somga soting, keyin ikkinchi valyutani soting');
  elsif v_fcur = 'UZS' then
    -- SOTIB OLISH: so'm kassasidan uning valyuta bolasiga
    v_yon := 'sotib_olish'; v_cur := v_tcur;
    if t.parent_id is distinct from f.id then
      return jsonb_build_object('ok', false, 'error', 'Valyuta hisobi shu kassaga tegishli emas');
    end if;
    v_fc  := p_amount;
    v_uzs := round(p_amount * p_rate, 2);
    v_som_kassa := p_from;
  else
    -- SOTISH: valyuta bolasidan o'z so'm kassasiga
    v_yon := 'sotish'; v_cur := v_fcur;
    if f.parent_id is distinct from t.id then
      return jsonb_build_object('ok', false, 'error', 'Valyuta hisobi shu kassaga tegishli emas');
    end if;
    v_fc  := p_amount;
    v_uzs := round(p_amount * p_rate, 2);
    v_som_kassa := p_to;
  end if;

  if p_farq is not null and p_farq <> 0 and abs(p_farq) > v_uzs then
    return jsonb_build_object('ok', false, 'error', 'Farq summadan katta — tekshiring');
  end if;

  -- Balans tekshiruvi: faqat sotib olishda (so'm kassadan chiqadi + farq
  -- ham qo'shimcha chiqishi mumkin). Sotishda soddalik uchun tekshirilmaydi
  -- (farq baribir so'm tomonda, valyuta qoldig'iga ta'sir qilmaydi).
  if v_yon = 'sotib_olish' then
    v_bal := acc_balance(p_from);
    if v_bal < v_uzs + greatest(coalesce(p_farq, 0), 0) then
      return jsonb_build_object('ok', false, 'error', 'Kassada yetarli pul yoq', 'qoldiq', v_bal);
    end if;
  else
    v_bal := acc_fc_balance(p_from);
    if v_bal < v_fc then
      return jsonb_build_object('ok', false,
        'error', 'Kassada yetarli ' || v_cur || ' yoq', 'qoldiq', v_bal);
    end if;
  end if;

  v_foiz := conv_koridor_foiz();
  v_baza := conv_baza_kurs(v_cur);

  -- Kurs tarixi bo'lmasa koridor yo'q — qarorni admin qabul qiladi
  if v_baza is null then
    insert into convert_request(from_account, to_account, amount, rate, fc_amount,
                                aros_rate, note, requested_by_name, farq)
    values (p_from, p_to, v_uzs, p_rate, v_fc, null, p_note, v_who, p_farq)
    returning id into v_req;
    return jsonb_build_object('ok', false, 'status', 'pending', 'request_id', v_req,
      'yonalish', v_yon, 'currency', v_cur, 'fc_amount', v_fc, 'amount', v_uzs,
      'aros_rate', null, 'lo', null, 'hi', null, 'foiz', v_foiz, 'farq', p_farq,
      'error', 'Bu juftlik uchun kurs tarixi yoq — admin tasdigi kerak');
  end if;

  v_lo := round(v_baza * (1 - v_foiz / 100), 4);
  v_hi := round(v_baza * (1 + v_foiz / 100), 4);

  if p_rate >= v_lo and p_rate <= v_hi then
    v_entry := do_convert_v2(p_from, p_to, v_uzs, p_rate, v_fc, v_who, p_note, null);

    -- Kurs farqi — alohida 2-satrli yozuv, asosiy konvertdan KEYIN,
    -- bitta plpgsql tranzaksiyasi ichida (funksiya xato bersa hammasi
    -- birga orqaga qaytadi).
    if p_farq is not null and p_farq <> 0 then
      v_modda := conv_farq_hisob_id();
      if v_modda is null then
        raise exception '"Konvert kurs farqi" hisobi topilmadi — PROVODKA_KONVERT_V3.sql 1-band RUN qilinsin.';
      end if;

      insert into entry(entry_date, description, source, status, created_by, ext_ref)
      values (current_date,
              'Konvert kurs farqi: ' || (case when p_farq > 0 then '+' else '-' end)
                || abs(p_farq)::text || ' · kurs ' || p_rate::text,
              'manual', 'posted', v_who, 'convfarq:' || v_entry::text)
      returning id into v_farq_entry;

      if p_farq > 0 then
        -- ko'p berildi (xarajat): Dt modda / Kt so'm kassa
        insert into entry_line(entry_id, account_id, debit, credit)
        values (v_farq_entry, v_modda, abs(p_farq), 0);
        insert into entry_line(entry_id, account_id, debit, credit)
        values (v_farq_entry, v_som_kassa, 0, abs(p_farq));
      else
        -- kam berildi (foyda): Dt so'm kassa / Kt modda
        insert into entry_line(entry_id, account_id, debit, credit)
        values (v_farq_entry, v_som_kassa, abs(p_farq), 0);
        insert into entry_line(entry_id, account_id, debit, credit)
        values (v_farq_entry, v_modda, 0, abs(p_farq));
      end if;
    end if;

    return jsonb_build_object('ok', true, 'status', 'done',
      'entry_id', v_entry, 'yonalish', v_yon, 'currency', v_cur,
      'fc_amount', v_fc, 'amount', v_uzs,
      'aros_rate', v_baza, 'lo', v_lo, 'hi', v_hi, 'foiz', v_foiz,
      'farq', p_farq, 'farq_entry_id', v_farq_entry);
  end if;

  insert into convert_request(from_account, to_account, amount, rate, fc_amount,
                              aros_rate, note, requested_by_name, farq)
  values (p_from, p_to, v_uzs, p_rate, v_fc, v_baza, p_note, v_who, p_farq)
  returning id into v_req;

  return jsonb_build_object('ok', false, 'status', 'pending', 'request_id', v_req,
    'yonalish', v_yon, 'currency', v_cur, 'fc_amount', v_fc, 'amount', v_uzs,
    'aros_rate', v_baza, 'lo', v_lo, 'hi', v_hi, 'foiz', v_foiz, 'farq', p_farq,
    'error', 'Kurs tayanch kursdan ' || trim(to_char(v_foiz, 'FM990.99'))
             || '% dan kop farq qilyapti. Admin tasdigi kerak.');
end
$fn$;

revoke all on function convert_start_v3(uuid,uuid,numeric,numeric,text,numeric) from public, anon;
grant execute on function convert_start_v3(uuid,uuid,numeric,numeric,text,numeric) to authenticated;

comment on function convert_start_v3(uuid,uuid,numeric,numeric,text,numeric) is
  'Konvert v3: v2 kabi, lekin p_amount HAR DOIM valyutada (sotib olishda ham). '
  'p_farq (ixtiyoriy, so''mda, imzoli) berilsa asosiy yozuvdan keyin alohida '
  '"Konvert kurs farqi" yozuvi qo''shiladi. v2/v1 imzolari TEGILMAGAN.';


-- #####################################################################
-- ##  5. convert_approve — farq yozuvi qo'shildi (imzo o'zgarmagan)   ##
-- #####################################################################
create or replace function convert_approve(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r convert_request; v_entry uuid; v_who text; v_bal numeric; v_fcur text;
  v_som_kassa uuid; v_modda uuid; v_farq_entry uuid;
begin
  if not is_admin() then
    return jsonb_build_object('ok', false, 'error', 'Faqat admin tasdiqlay oladi');
  end if;
  select coalesce(full_name, 'admin') into v_who from profiles where id = auth.uid();

  select * into r from convert_request where id = p_id;
  if r.id is null then return jsonb_build_object('ok', false, 'error', 'Sorov topilmadi'); end if;
  if r.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'Sorov allaqachon hal qilingan: ' || r.status);
  end if;

  select coalesce(currency, 'UZS') into v_fcur from accounts where id = r.from_account;

  if v_fcur = 'UZS' then
    -- sotib olish: so'm qoldig'i. Musbat farq (ko'p berilgan) ham kassadan chiqadi —
    -- convert_start_v3 dagi tekshiruv bilan bir xil: amount + greatest(farq, 0).
    v_bal := acc_balance(r.from_account);
    if v_bal < r.amount + greatest(coalesce(r.farq, 0), 0) then
      return jsonb_build_object('ok', false, 'error', 'Kassada yetarli pul yoq', 'qoldiq', v_bal);
    end if;
    v_som_kassa := r.from_account;
  else
    -- sotish: valyuta qoldig'i
    v_bal := acc_fc_balance(r.from_account);
    if v_bal < r.fc_amount then
      return jsonb_build_object('ok', false,
        'error', 'Kassada yetarli ' || v_fcur || ' yoq', 'qoldiq', v_bal);
    end if;
    v_som_kassa := r.to_account;
  end if;

  v_entry := do_convert_v2(r.from_account, r.to_account, r.amount, r.rate, r.fc_amount,
                           r.requested_by_name, coalesce(r.note,'') || ' (admin: ' || v_who || ')',
                           'conv:' || r.id::text);

  -- 🔴 YANGI (v3): r.farq bor va <> 0 bo'lsa — kurs farqi yozuvi.
  -- select * into r bo'lgani uchun farq ustuni avtomat keladi; eski
  -- so'rovlarda null — bu shox butunlay o'tkazib yuboriladi.
  if r.farq is not null and r.farq <> 0 then
    v_modda := conv_farq_hisob_id();
    if v_modda is null then
      raise exception '"Konvert kurs farqi" hisobi topilmadi — PROVODKA_KONVERT_V3.sql 1-band RUN qilinsin.';
    end if;

    insert into entry(entry_date, description, source, status, created_by, ext_ref)
    values (current_date,
            'Konvert kurs farqi: ' || (case when r.farq > 0 then '+' else '-' end)
              || abs(r.farq)::text || ' · kurs ' || r.rate::text,
            'manual', 'posted', v_who, 'convfarq:' || v_entry::text)
    returning id into v_farq_entry;

    if r.farq > 0 then
      insert into entry_line(entry_id, account_id, debit, credit)
      values (v_farq_entry, v_modda, abs(r.farq), 0);
      insert into entry_line(entry_id, account_id, debit, credit)
      values (v_farq_entry, v_som_kassa, 0, abs(r.farq));
    else
      insert into entry_line(entry_id, account_id, debit, credit)
      values (v_farq_entry, v_som_kassa, abs(r.farq), 0);
      insert into entry_line(entry_id, account_id, debit, credit)
      values (v_farq_entry, v_modda, 0, abs(r.farq));
    end if;
  end if;

  update convert_request
  set status = 'approved', decided_by_name = v_who, decided_at = now(), entry_id = v_entry
  where id = p_id;

  return jsonb_build_object('ok', true, 'status', 'approved', 'entry_id', v_entry, 'farq_entry_id', v_farq_entry);
end
$fn$;

-- convert_reject o'zgarmaydi — farqga bog'liq emas (rad etilgan so'rovda hech narsa yozilmaydi).


-- #####################################################################
-- ##  6. jurnal_savdosiz_ok() — klient uchun "SQL RUN qilingan" belgisi ##
-- #####################################################################
-- jurnal_pul_filtr_ok() ning aynan nusxasi — jurnal-dev.html/kassa-dev.html
-- shu funksiyani chaqirib PROVODKA_KONVERT_V3.sql RUN qilinganini biladi
-- (PGRST202/42883 bo'lsa yo'q deb hisoblaydi, hech narsa oqmaydi).
create or replace function jurnal_savdosiz_ok()
returns boolean
language sql
stable
as $fn$ select true $fn$;

revoke all on function jurnal_savdosiz_ok() from public, anon;
grant execute on function jurnal_savdosiz_ok() to authenticated;

comment on function jurnal_savdosiz_ok() is
  'Klient uchun "PROVODKA_KONVERT_V3.sql RUN qilinganmi" belgisi. Hech narsa oqmaydi.';


-- #####################################################################
-- ##  7. jurnal_v2_baza — 'savdosiz' tokeni                           ##
-- #####################################################################
-- PROVODKA_JURNAL_PUL.sql dagi tanadan VERBATIM davom — imzo va
-- `returns table(...)` shakli AYNAN bir xil, faqat `declare`ga 2 ta
-- o'zgaruvchi va OXIRGI `where` qatoriga shart qo'shildi ('pul' tokeni
-- bilan bir xil naqsh). Token yo'q bo'lsa xatti-harakat AYNAN eskidek.
--
-- Ma'no: 'savdosiz' bo'lsa aros_auto (avtomatik sinxron) yozuvlaridan
-- FAQAT transfer (filial -> markaziy kassa, pul<->pul) qoladi; avtomatik
-- savdo tushumi/kamayishi (aros_auto, pul<->daromad yoki teskari) va
-- boshqa avtomatik yozuvlar (masalan boshlang'ich kapital) yashiriladi.
-- Qo'lda kiritilgan (source<>'aros_auto') yozuvlarga TA'SIR YO'Q.
do $do$
begin
  if to_regprocedure('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)') is null then
    raise exception 'Old shart yoq: PROVODKA_JURNAL_PUL.sql avval RUN qilinsin.'
      using errcode = '55000';
  end if;
end
$do$;

create or replace function jurnal_v2_baza(
  p_from     date,
  p_to       date,
  p_accounts uuid[],
  p_moddalar uuid[],
  p_turlar   text[],
  p_q        text)
returns table(
  id uuid, entry_date date, created_at timestamptz, description text,
  source text, is_deleted boolean, deleted_by_name text, deleted_at timestamptz,
  edited_at timestamptz, edited_by_name text,
  n_lines int, summa numeric, tur text,
  begona boolean,
  ijrochi_raw text
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_perm     uuid[] := perm_view_pul_ids();   -- null = cheklovsiz, '{}' = hech narsa
  v_moddalar uuid[];
  v_q        text;
  -- 'pul' tokeni — faqat pul satri bor yozuvlar (PROVODKA_JURNAL_PUL.sql)
  v_pul      boolean := (p_turlar is not null and 'pul' = any(p_turlar));
  -- 🔴 YANGI (PROVODKA_KONVERT_V3.sql): 'savdosiz' tokeni — aros_auto
  -- yozuvlardan faqat transfer qoladi (savdo tushumi/kamayishi yashiriladi).
  v_savdosiz boolean := (p_turlar is not null and 'savdosiz' = any(p_turlar));
  v_turlar   text[]  := p_turlar;
begin
  -- ⚠️ TUZOQ — bo'sh massiv MA'NOSI bu funksiyada BIR XIL EMAS:
  --   p_moddalar = '{}' → "filtr yo'q";  p_accounts / p_turlar = '{}' → HECH NARSA.
  if p_moddalar is null or array_length(p_moddalar, 1) is null then
    v_moddalar := null;
  else
    v_moddalar := p_moddalar;
  end if;

  -- 'pul' va 'savdosiz' tokenlari tur ro'yxatidan OLIB TASHLANADI; faqat
  -- shu tokenlar qolsa tur filtri yo'q (null).
  if v_pul then
    v_turlar := array_remove(v_turlar, 'pul');
  end if;
  if v_savdosiz then
    v_turlar := array_remove(v_turlar, 'savdosiz');
  end if;
  if array_length(v_turlar, 1) is null then
    v_turlar := null;
  end if;

  -- Qidiruv: LIKE metabelgilari tozalanadi.
  if p_q is null or btrim(p_q) = '' then
    v_q := null;
  else
    v_q := '%' || replace(replace(replace(btrim(p_q), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  return query
  with e as (
    select en.id                as e_id,
           en.entry_date        as e_date,
           en.created_at        as e_created,
           en.description       as e_desc,
           en.source            as e_source,
           en.is_deleted        as e_del,
           en.deleted_by_name   as e_delby,
           en.deleted_at        as e_delat,
           en.edited_at         as e_edat,
           en.edited_by_name    as e_edby,
           nullif(btrim(coalesce(to_jsonb(en) ->> 'created_by', '')), '') as e_by,
           (v_perm is not null and exists (
              select 1 from entry_line el join accounts ab on ab.id = el.account_id
               where el.entry_id = en.id
                 and ab.type = 'aktiv' and ab.code like '5%'
                 and ab.kassa_turi is distinct from 'xarajat_guruh'
                 and not (el.account_id = any(v_perm)))) as e_begona
      from entry en
     where en.status = 'posted'
       -- 🔴 is_deleted filtri ATAYLAB YO'Q (jurnal o'chirilganini ham ko'rsatadi)
       -- 🔴 SANA -> KIRITILGAN VAQT (PROVODKA_JURNAL_KIRITILGAN.sql) — o'zgarmagan.
       and en.created_at >= (p_from::timestamp at time zone 'Asia/Tashkent')
       and en.created_at <  ((p_to + 1)::timestamp at time zone 'Asia/Tashkent')
       and (p_accounts is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(p_accounts)))
       and (v_moddalar is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(v_moddalar)
                and el.debit > 0))
       -- 🔴 RUXSAT (server tomonda, klient filtridan MUSTAQIL)
       and (v_perm is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(v_perm)))
       and (v_q is null or en.description ilike v_q escape '\')
       -- 'pul' tokeni — kamida bitta satri pul hisobi bo'lsin.
       --    Chala yozuv (satr yo'q) ISTISNO — u tovar emas, diagnostika.
       and (not v_pul
            or exists (
                 select 1 from entry_line el join accounts ap on ap.id = el.account_id
                  where el.entry_id = en.id and ap.section = 'pul')
            or not exists (select 1 from entry_line el where el.entry_id = en.id))
  ),
  c as (
    select e.*,
           (select count(*)::int from entry_line l where l.entry_id = e.e_id) as n,
           (select coalesce(sum(l.debit), 0)::numeric from entry_line l where l.entry_id = e.e_id) as s,
           d.sec as dt_sec, d.typ as dt_type,
           k.sec as kt_sec, k.typ as kt_type
      from e
      left join lateral (
        select a.section as sec, a.type as typ
          from entry_line l join accounts a on a.id = l.account_id
         where l.entry_id = e.e_id and l.debit > 0
         order by l.debit desc limit 1) d on true
      left join lateral (
        select a.section as sec, a.type as typ
          from entry_line l join accounts a on a.id = l.account_id
         where l.entry_id = e.e_id and l.credit > 0
         order by l.credit desc limit 1) k on true
  ),
  t as (
    select c.*,
           case
             when c.n > 2                                    then 'boshqa'
             when c.dt_sec = 'pul' and c.kt_sec = 'pul'      then 'transfer'
             when c.dt_sec = 'pul' and c.kt_type = 'daromad' then 'tushum'
             when c.dt_sec = 'pul'                           then 'kirim'
             when c.kt_sec = 'pul' and c.dt_type = 'xarajat' then 'xarajat'
             when c.kt_sec = 'pul'                           then 'chiqim'
             else 'boshqa'
           end as tt
      from c
  )
  select t.e_id::uuid, t.e_date::date, t.e_created::timestamptz, t.e_desc::text,
         t.e_source::text, t.e_del::boolean, t.e_delby::text, t.e_delat::timestamptz,
         t.e_edat::timestamptz, t.e_edby::text,
         t.n::int, t.s::numeric, t.tt::text, t.e_begona::boolean,
         t.e_by::text
    from t
   -- 🔴 p_turlar emas, 'pul'/'savdosiz' siz v_turlar bilan taqqoslanadi.
   where (v_turlar is null or t.tt = any(v_turlar))
     -- 🔴 YANGI: 'savdosiz' tokeni — aros_auto yozuvlardan faqat transfer qoladi.
     and (not v_savdosiz or t.e_source is distinct from 'aros_auto' or t.tt = 'transfer');
end
$fn$;

revoke all on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text) from public, anon, authenticated;

comment on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text) is
  'ICHKI: jurnal v2 uchun filtrlangan yozuvlar + tur tasnifi + ijrochi_raw. Ruxsat shu yerda. '
  'Sana filtri created_at (Asia/Tashkent) boyicha. p_turlar ichida ''pul'' bolsa faqat pul satri '
  'bor yozuvlar; ''savdosiz'' bolsa aros_auto yozuvlardan faqat transfer qoladi (PROVODKA_KONVERT_V3.sql).';


-- #####################################################################
-- ##  8. TEKSHIRUV — eski imzolar buzilmaganini tasdiqlash            ##
-- #####################################################################
do $do$
declare v_n int;
begin
  if to_regprocedure('public.convert_start_v2(uuid,uuid,numeric,numeric,text)') is null then
    raise exception 'convert_start_v2 imzosi topilmadi — buzildi!';
  end if;
  if to_regprocedure('public.do_convert_v2(uuid,uuid,numeric,numeric,numeric,text,text,text)') is null then
    raise exception 'do_convert_v2 imzosi topilmadi — buzildi!';
  end if;
  if to_regprocedure('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)') is null then
    raise exception 'jurnal_v2_baza imzosi topilmadi — buzildi!';
  end if;
  if to_regprocedure('public.convert_start_v3(uuid,uuid,numeric,numeric,text,numeric)') is null then
    raise exception 'convert_start_v3 yaratilmadi!';
  end if;

  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname, pg_get_function_identity_arguments(p.oid)) in (
       ('convert_start',  'p_from uuid, p_to uuid, p_amount numeric, p_rate numeric, p_note text'),
       ('do_convert',     'p_from uuid, p_to uuid, p_amount numeric, p_rate numeric, p_fc numeric, p_who text, p_note text, p_ext text')
     );
  if v_n <> 2 then
    raise exception 'Eski imzolar buzildi (topildi: %). Eski pending sorovlar approve bolmay qoladi.', v_n;
  end if;

  raise notice 'PROVODKA_KONVERT_V3.sql: hammasi joyida. "Konvert kurs farqi" hisob id: %', conv_farq_hisob_id();
end
$do$;


-- #####################################################################
-- ##  TEKSHIRUV (ixtiyoriy, o'qish uchun)                             ##
-- #####################################################################
-- select convert_start_v3('<uzs-kassa-id>', '<usd-kassa-id>', 100, 12700, 'test', 500);
-- select id, from_account, to_account, amount, rate, fc_amount, farq, status from convert_request order by requested_at desc limit 5;
-- select count(*) from jurnal_v2_baza(current_date - 30, current_date, null, null, array['pul'], null);
-- select count(*) from jurnal_v2_baza(current_date - 30, current_date, null, null, array['pul','savdosiz'], null);


-- #####################################################################
-- ##  ROLLBACK (qo'lda, kerak bo'lsa)                                 ##
-- #####################################################################
-- drop function if exists convert_start_v3(uuid,uuid,numeric,numeric,text,numeric);
-- drop function if exists conv_farq_hisob_id();
-- drop function if exists jurnal_savdosiz_ok();
-- PROVODKA_JURNAL_PUL.sql 1-bo'limini qayta RUN qiling (tana 'savdosiz' tokensiz qaytadi).
-- convert_approve — PROVODKA_KASSA2.sql 2.6-bandini qayta RUN qiling (farq shoxisiz).
-- alter table convert_request drop column if exists farq;
-- accounts dan 'Konvert kurs farqi' hisobini o'chirish — QO'LDA, faqat undan
-- foydalanuvchi yozuv bo'lmasa (aks holda tarix yetim qoladi).
