-- ============================================================================
--  PROVODKA_PUL_USTI.sql — 2026-10-06 — «Pul usti» xarajat moddasi; kurs farqi fonda qoladi, ko'rinmaydi
--  Asilbek: «konvertdagi ustama "Konvert kurs farqi"ga urilyapti — "Pul usti" degan xarajat turi ochib shunga urish kerak,
--  eskilarini ham; "Konvert kurs farqi" logikasi bizga kerak emas — mayli fonda ketaversin, lekin biz uni ko'rmaylik,
--  chalg'ityapti. Konvert qatorida o'sha paytdagi kurs yozilsa yetadi».
--
--  QAROR
--   * «Pul usti» (94xx, type xarajat) — konvertda qo'lda kiritilgan farq (v3 UZS↔valyuta «ko'p/kam berildi») VA v4
--     valyuta→valyuta ustamasi shu moddaga. Eski yozuvlar (ext_ref 'convfarq:%' va 'convust:%') shu moddaga KO'CHIRILADI
--     (entry_history izi bilan). «Konvert ustama» moddasi satrsiz qolsa is_active=false.
--   * Avtomat qayta baholash (PROVODKA_KURS_FARQI_AVTO.sql, ext_ref 'kursfarq:%', modda 9437 «Konvert kurs farqi») FONDA
--     QOLADI — busiz valyuta hisobining so'm qoldig'i «osilib» qoladi (G'iyos USD sabog'i). Lekin foydalanuvchiga
--     KO'RINMAYDI: jurnal (sukut yashirin, «Texnik yozuvlar» belgisi), hisobot P&L (qator chiqarilmaydi), aylanma kunlik
--     xarajat (bu fayl: aylanma_kun_xarajat / aylanma_hisobot_tafsilot 9437 ni xarajat deb sanamaydi).
--   * RBAC: «Pul usti»ga yozish = konvert ruxsati (perm_can_convert), kurs farqi/ustama istisnosi naqshi.
--  Tanalar: convert_start_v3 (PROVODKA_KONVERT_V3_ROOT.sql), convert_approve (PROVODKA_KONVERT_V3.sql), convert_valyuta_v4
--  (PROVODKA_KONVERT_V4_FIX.sql), rbac_guard_entry_line (PROVODKA_RBAC_EHSON_KIRIM_RUXSAT.sql), aylanma_kun_xarajat
--  (PROVODKA_AYLANMA_HISOBOT.sql), aylanma_hisobot_tafsilot (PROVODKA_AYLANMA_HISOBOT_2.sql) — VERBATIM + belgilangan o'zgarish.
--  🔴 Shu 6 funksiyaning ENG OXIRGI versiyasi endi SHU faylda. Asilbek RUN qiladi. Idempotent.
-- ============================================================================

-- ######## 1) «Pul usti» moddasi (94xx avtokod — Konvert kurs farqi/ustama bilan bir xil naqsh) ########
do $pul_usti_modda$
declare v_id uuid; v_next int;
begin
  select id into v_id from accounts where name = 'Pul usti' and type = 'xarajat' order by created_at limit 1;
  if v_id is null then
    select coalesce(max(a.code::int), 9420) + 1 into v_next from accounts a where a.code ~ '^94[0-9]+$';
    insert into accounts(code, name, type, section, is_active)
    values (v_next::text, 'Pul usti', 'xarajat', 'operatsion', true) returning id into v_id;
    raise notice 'Pul usti moddasi OCHILDI: kod % (id=%)', v_next, v_id;
  else
    update accounts set is_active = true where id = v_id and coalesce(is_active, true) = false;
    raise notice 'Pul usti moddasi allaqachon bor (id=%)', v_id;
  end if;
end
$pul_usti_modda$;

create or replace function conv_pul_usti_hisob_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $fn$
  select id from accounts
   where name = 'Pul usti' and type = 'xarajat' and is_active
   order by created_at asc limit 1;
$fn$;
revoke all on function conv_pul_usti_hisob_id() from public, anon;

-- ######## 2) Konvert funksiyalari — farq/ustama endi «Pul usti»ga ########
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
    -- TUR BOLALARI (naqd/Click/Payme): valyuta hisobi ILDIZ kassaga bog'langan, pul esa
    -- bola-hisobdan chiqadi — shuning uchun "ayni kassaga tegishli" (kassa_root) deb tekshiriladi.
    if kassa_root(p_to) is distinct from kassa_root(p_from) then
      return jsonb_build_object('ok', false, 'error', 'Valyuta hisobi shu kassaga tegishli emas');
    end if;
    v_fc  := p_amount;
    v_uzs := round(p_amount * p_rate, 2);
    v_som_kassa := p_from;
  else
    -- SOTISH: valyuta bolasidan o'z so'm kassasiga
    v_yon := 'sotish'; v_cur := v_fcur;
    if kassa_root(p_from) is distinct from kassa_root(p_to) then
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
      v_modda := conv_pul_usti_hisob_id();   -- 🔴 2026-10-06: «Pul usti» (avval Konvert kurs farqi 9437)
      if v_modda is null then
        raise exception '"Pul usti" moddasi topilmadi — PROVODKA_PUL_USTI.sql RUN qilinsin.';
      end if;

      insert into entry(entry_date, description, source, status, created_by, ext_ref)
      values (current_date,
              'Pul usti (konvert): ' || (case when p_farq > 0 then '+' else '-' end)
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
    v_modda := conv_pul_usti_hisob_id();   -- 🔴 2026-10-06: «Pul usti»
    if v_modda is null then
      raise exception '"Pul usti" moddasi topilmadi — PROVODKA_PUL_USTI.sql RUN qilinsin.';
    end if;

    insert into entry(entry_date, description, source, status, created_by, ext_ref)
    values (current_date,
            'Pul usti (konvert): ' || (case when r.farq > 0 then '+' else '-' end)
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

create or replace function convert_valyuta_v4(p_from uuid, p_to uuid, p_amount numeric, p_to_amount numeric,
                                              p_ustama numeric default null, p_ustama_foiz numeric default null,
                                              p_uzs numeric default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  f accounts%rowtype; t accounts%rowtype;
  v_who text; v_ruxsat boolean;
  v_fcur text; v_tcur text;
  v_uzs numeric; v_kurs numeric; v_cross numeric;
  v_ust_fc numeric := 0; v_ust_uzs numeric := 0;
  v_bal numeric; v_entry uuid; v_ust_entry uuid; v_modda uuid; v_req uuid;
  v_desc text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'Avtorizatsiya kerak'); end if;
  if to_regprocedure('public.perm_can_convert()') is not null then
    execute 'select perm_can_convert()' into v_ruxsat;
    if not coalesce(v_ruxsat, true) then return jsonb_build_object('ok', false, 'error', 'Konvert ruxsati yoq'); end if;
  end if;
  select coalesce(full_name, 'foydalanuvchi') into v_who from profiles where id = auth.uid();

  if p_amount is null or p_amount <= 0 then return jsonb_build_object('ok', false, 'error', 'Beriladigan summa notogri'); end if;
  if p_to_amount is null or p_to_amount <= 0 then return jsonb_build_object('ok', false, 'error', 'Olinadigan summa notogri'); end if;
  if p_from = p_to then return jsonb_build_object('ok', false, 'error', 'Bir hisobning ozida konvert bolmaydi'); end if;

  select * into f from accounts where id = p_from;
  select * into t from accounts where id = p_to;
  if f.id is null or t.id is null then return jsonb_build_object('ok', false, 'error', 'Hisob topilmadi'); end if;
  if not f.is_active or not t.is_active then return jsonb_build_object('ok', false, 'error', 'Hisob faol emas'); end if;
  v_fcur := coalesce(f.currency, 'UZS'); v_tcur := coalesce(t.currency, 'UZS');
  if v_fcur = 'UZS' or v_tcur = 'UZS' then
    return jsonb_build_object('ok', false, 'error', 'Bu funksiya faqat valyuta → valyuta uchun. Som bilan konvert — sotib olish/sotish.');
  end if;
  if f.kassa_turi = 'filial' or t.kassa_turi = 'filial' or f.kassa_turi = 'xarajat_guruh' or t.kassa_turi = 'xarajat_guruh' then
    return jsonb_build_object('ok', false, 'error', 'Bu hisobda konvert qilib bolmaydi');
  end if;

  -- ustama
  if p_ustama is not null and p_ustama < 0 then return jsonb_build_object('ok', false, 'error', 'Ustama manfiy bolmaydi'); end if;
  if p_ustama_foiz is not null and (p_ustama_foiz < 0 or p_ustama_foiz > 50) then
    return jsonb_build_object('ok', false, 'error', 'Ustama foizi 0..50 oraligida bolsin');
  end if;
  v_ust_fc := coalesce(p_ustama, 0) + case when coalesce(p_ustama_foiz, 0) > 0 then round(p_amount * p_ustama_foiz / 100, 2) else 0 end;

  -- so'm baholash
  if p_uzs is not null and p_uzs > 0 then
    v_uzs := round(p_uzs, 0);
    v_kurs := round(p_uzs / p_amount, 4);
  else
    v_kurs := conv_baza_kurs(v_fcur);
    if v_kurs is null then
      return jsonb_build_object('ok', false, 'error', v_fcur || ' uchun kurs tarixi yoq — som ekvivalentini (p_uzs) kiriting');
    end if;
    v_uzs := round(p_amount * v_kurs, 0);
  end if;
  v_ust_uzs := round(v_ust_fc * v_kurs, 0);
  v_cross := round(p_to_amount / p_amount, 6);   -- 1 birlik berilayotgan valyuta = necha birlik olinayotgan

  -- balans: beruvchi valyuta hisobida miqdor + ustama bo'lishi kerak
  v_bal := acc_fc_balance(p_from);
  if v_bal < p_amount + v_ust_fc then
    return jsonb_build_object('ok', false, 'error', 'Kassada yetarli ' || v_fcur || ' yoq', 'qoldiq', v_bal, 'kerak', p_amount + v_ust_fc);
  end if;

  -- 1-yozuv: konvert (ikkala satr bir xil so'm qiymatda, fc o'z valyutasida)
  v_desc := 'Konvert: ' || f.name || ' -> ' || t.name
            || ' · ' || trim(to_char(p_amount, 'FM999999999990.00')) || ' ' || v_fcur
            || ' → ' || trim(to_char(p_to_amount, 'FM999999999990.00')) || ' ' || v_tcur
            || ' · kurs ' || trim(to_char(v_cross, 'FM999999990.000000'))
            || coalesce(' · ' || nullif(btrim(p_note), ''), '');
  insert into entry(entry_date, description, source, status, fc_rate, ext_ref, created_by)
  values (current_date, v_desc, 'manual', 'posted', v_cross, 'convxy:' || gen_random_uuid()::text, v_who)
  returning id into v_entry;
  insert into entry_line(entry_id, account_id, debit, credit, fc_amount) values (v_entry, p_to,   v_uzs, 0, p_to_amount);
  insert into entry_line(entry_id, account_id, debit, credit, fc_amount) values (v_entry, p_from, 0, v_uzs, p_amount);

  -- 2-yozuv: ustama — xarajat (Dt Konvert ustama / Kt beruvchi valyuta hisobi)
  if v_ust_fc > 0 then
    v_modda := conv_pul_usti_hisob_id();   -- 🔴 2026-10-06: «Pul usti» (avval Konvert ustama)
    if v_modda is null then raise exception '"Pul usti" moddasi topilmadi — PROVODKA_PUL_USTI.sql RUN qilinsin.'; end if;
    insert into entry(entry_date, description, source, status, fc_rate, ext_ref, created_by)
    values (current_date,
            'Pul usti (konvert): ' || trim(to_char(v_ust_fc, 'FM999999999990.00')) || ' ' || v_fcur
              || case when coalesce(p_ustama_foiz, 0) > 0 then ' (' || trim(to_char(p_ustama_foiz, 'FM990.99')) || '%)' else '' end
              || ' · ' || f.name || ' -> ' || t.name,
            'manual', 'posted', v_kurs, 'convust:' || v_entry::text, v_who)
    returning id into v_ust_entry;
    insert into entry_line(entry_id, account_id, debit, credit, fc_amount) values (v_ust_entry, v_modda, v_ust_uzs, 0, null);
    insert into entry_line(entry_id, account_id, debit, credit, fc_amount) values (v_ust_entry, p_from, 0, v_ust_uzs, v_ust_fc);
  end if;

  -- tarix uchun convert_request (konvert sahifasidagi ro'yxatda ko'rinsin)
  insert into convert_request(from_account, to_account, amount, rate, fc_amount, aros_rate, status, note,
                              requested_by_name, decided_by_name, decided_at, entry_id, farq)
  values (p_from, p_to, v_uzs, v_cross, p_amount, null, 'approved',   -- status check: pending|approved|rejected (FIX 2026-10-03)
          coalesce(nullif(btrim(p_note), ''), '') || ' [valyuta→valyuta ' || v_fcur || '→' || v_tcur
            || case when v_ust_fc > 0 then ', ustama ' || trim(to_char(v_ust_fc, 'FM999999999990.00')) || ' ' || v_fcur else '' end || ']',
          v_who, v_who, now(), v_entry, case when v_ust_uzs > 0 then v_ust_uzs else null end)
  returning id into v_req;

  return jsonb_build_object('ok', true, 'status', 'done', 'entry_id', v_entry, 'ustama_entry_id', v_ust_entry,
    'request_id', v_req, 'from_cur', v_fcur, 'to_cur', v_tcur, 'amount', p_amount, 'to_amount', p_to_amount,
    'cross_rate', v_cross, 'uzs', v_uzs, 'kurs_uzs', v_kurs, 'ustama_fc', v_ust_fc, 'ustama_uzs', v_ust_uzs);
end
$fn$;

-- ######## 3) ESKI YOZUVLAR → «Pul usti» (convfarq: va convust:), entry_history izi bilan ########
do $pul_usti_migr$
declare
  v_pu   uuid := conv_pul_usti_hisob_id();
  v_farq uuid := conv_farq_hisob_id();
  v_ust  uuid := (select id from accounts where name = 'Konvert ustama' and type = 'xarajat' order by created_at limit 1);
  v_n    int := 0; v_m int := 0;
  r record;
begin
  if v_pu is null then raise exception 'Pul usti moddasi yoq'; end if;
  for r in
    select l.id as line_id, l.entry_id, l.account_id
      from entry_line l join entry e on e.id = l.entry_id
     where (e.ext_ref like 'convfarq:%' or e.ext_ref like 'convust:%')
       and l.account_id in (v_farq, v_ust) and l.account_id is not null
  loop
    begin
      insert into entry_history(entry_id, data, action, changed_by_name)
      select r.entry_id,
             jsonb_build_object('line_id', r.line_id, 'eski_account_id', r.account_id, 'yangi_account_id', v_pu,
                                'sabab', 'Pul usti moddasiga kochirish (2026-10-06)'),
             'edit', 'Pul usti migratsiya'
       where to_regclass('public.entry_history') is not null;
    exception when others then null;   -- entry_history shakli boshqacha bo'lsa iz qoldirilmaydi, ko'chirish davom etadi
    end;
    update entry_line set account_id = v_pu where id = r.line_id;
    v_n := v_n + 1;
  end loop;
  -- yozuv matni: «Konvert kurs farqi: …» / «Konvert ustama: …» → «Pul usti (konvert): …»
  update entry set description = regexp_replace(description, '^(Konvert kurs farqi|Konvert ustama): ', 'Pul usti (konvert): ')
   where (ext_ref like 'convfarq:%' or ext_ref like 'convust:%')
     and description ~ '^(Konvert kurs farqi|Konvert ustama): ';
  get diagnostics v_m = row_count;
  -- «Konvert ustama» moddasi bo'shab qolsa — nofaol
  if v_ust is not null and not exists (select 1 from entry_line where account_id = v_ust) then
    update accounts set is_active = false where id = v_ust;
  end if;
  raise notice 'Pul usti migratsiya: % satr kochirildi, % yozuv matni yangilandi', v_n, v_m;
end
$pul_usti_migr$;

-- ######## 4) RBAC istisno + aylanma xarajatidan texnik kurs farqini chiqarish ########
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
    -- 🔴 2026-10-06: «Pul usti» (konvert farqi/ustama) — konvert ruxsati yetarli
    v_farq := null;
    if to_regprocedure('public.conv_pul_usti_hisob_id()') is not null then
      execute 'select public.conv_pul_usti_hisob_id()' into v_farq;
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

create or replace function aylanma_kun_xarajat(p_sana date)
returns numeric
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(sum(dt.debit), 0)
    from entry e
    join entry_line dt on dt.entry_id = e.id and dt.debit > 0
    join accounts ma on ma.id = dt.account_id and ma.type = 'xarajat'
                    and ma.id is distinct from conv_farq_hisob_id()   -- 🔴 2026-10-06: avto kurs farqi (texnik) xarajat EMAS
   where e.entry_date = p_sana and e.status = 'posted' and e.is_deleted = false
     and exists (select 1 from entry_line kt
                  where kt.entry_id = e.id and kt.credit > 0
                    and kt.account_id = any(aylanma_asosiy_hisoblar()));
$fn$;
revoke all on function aylanma_kun_xarajat(date) from public, anon;
grant execute on function aylanma_kun_xarajat(date) to authenticated;

create or replace function aylanma_hisobot_tafsilot(p_sana date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_kurs numeric;
  v_foyda jsonb; v_xarajat jsonb; v_royxat jsonb;
begin
  if not aylanma_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  select kurs_usd into v_kurs from aylanma_snapshot
   where sana in (p_sana + 1, p_sana) and kurs_usd is not null
   order by (sana = p_sana + 1) desc, (rejim = 'cron') desc, hisoblangan_at desc limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
           'filial', filial, 'sotilgan', sotilgan, 'qaytarilgan', qaytarilgan, 'kirim_usd', kirim_usd,
           'sotuv_usd', sotuv_usd, 'keshbek_usd', keshbek_usd, 'foyda_usd', foyda_usd,
           'foyda_uzs', case when v_kurs is not null then round(foyda_usd * v_kurs, 0) end
         ) order by (filial = 'JAMI'), foyda_usd desc), '[]'::jsonb)
    into v_foyda
    from aylanma_foyda where sana = p_sana;

  -- modda/kassa bo'yicha jami (avvalgidek)
  select coalesce(jsonb_agg(jsonb_build_object('modda', modda, 'kassa', kassa, 'summa', summa, 'soni', soni) order by summa desc), '[]'::jsonb)
    into v_xarajat
    from (
      select ma.name as modda, ka.name as kassa, sum(dt.debit) as summa, count(distinct e.id) as soni
        from entry e
        join entry_line dt on dt.entry_id = e.id and dt.debit > 0
        join accounts ma on ma.id = dt.account_id and ma.type = 'xarajat'
                        and ma.id is distinct from conv_farq_hisob_id()   -- 🔴 2026-10-06: texnik kurs farqi chiqarildi
        join lateral (select kt.account_id from entry_line kt
                       where kt.entry_id = e.id and kt.credit > 0
                         and kt.account_id = any(aylanma_asosiy_hisoblar()) limit 1) k on true
        join accounts ka on ka.id = k.account_id
       where e.entry_date = p_sana and e.status = 'posted' and e.is_deleted = false
       group by ma.name, ka.name
    ) x;

  -- YANGI: har bir xarajat yozuvi
  select coalesce(jsonb_agg(jsonb_build_object(
           'entry_id', entry_id, 'vaqt', vaqt, 'kassa', kassa, 'modda', modda, 'summa', summa,
           'izoh', izoh, 'ijrochi', ijrochi, 'filial', filial
         ) order by vaqt desc), '[]'::jsonb)
    into v_royxat
    from (
      select e.id as entry_id, e.created_at as vaqt, ka.name as kassa, ma.name as modda, dt.debit as summa,
             e.description as izoh,
             coalesce((to_jsonb(e) ->> 'created_by_name'),
                      (select p.full_name from profiles p where p.id::text = (to_jsonb(e) ->> 'created_by') limit 1)) as ijrochi,
             (select string_agg(fa.name, ', ') from accounts fa where fa.id = any(coalesce(e.filial_ids, '{}'::uuid[]))) as filial
        from entry e
        join entry_line dt on dt.entry_id = e.id and dt.debit > 0
        join accounts ma on ma.id = dt.account_id and ma.type = 'xarajat'
                        and ma.id is distinct from conv_farq_hisob_id()   -- 🔴 2026-10-06: texnik kurs farqi chiqarildi
        join lateral (select kt.account_id from entry_line kt
                       where kt.entry_id = e.id and kt.credit > 0
                         and kt.account_id = any(aylanma_asosiy_hisoblar()) limit 1) k on true
        join accounts ka on ka.id = k.account_id
       where e.entry_date = p_sana and e.status = 'posted' and e.is_deleted = false
    ) r;

  return jsonb_build_object('ok', true, 'sana', p_sana, 'kurs', v_kurs, 'foyda', v_foyda, 'xarajat', v_xarajat,
                            'xarajat_royxat', v_royxat, 'xarajat_jami', aylanma_kun_xarajat(p_sana));
end
$fn$;
revoke all on function aylanma_hisobot_tafsilot(date) from public, anon;
grant execute on function aylanma_hisobot_tafsilot(date) to authenticated;


notify pgrst, 'reload schema';

-- TEKSHIRUV
select (select code||' '||name from accounts where id = conv_pul_usti_hisob_id()) as pul_usti,
       (select count(*) from entry_line where account_id = conv_pul_usti_hisob_id()) as pul_usti_satrlar,
       (select count(*) from entry_line l join entry e on e.id=l.entry_id where l.account_id = conv_farq_hisob_id() and (e.ext_ref like 'convfarq:%' or e.ext_ref like 'convust:%')) as kochmagan_farq,
       (select count(*) from entry where ext_ref like 'kursfarq:%' and is_deleted = false) as avto_kurs_farqi_fonda;
