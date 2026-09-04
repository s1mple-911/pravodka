-- =====================================================================
-- PROVODKA_KONVERT_V3_ROOT.sql  (2026-09-04)
-- Konvert v3: «Toshkent kassa · Naqd» (pul turi bola-hisobi) dan «Toshkent kassa USD»
-- ga konvert «Valyuta hisobi shu kassaga tegishli emas» berardi.
-- SABAB: convert_start_v3 (PROVODKA_KONVERT_V3.sql) egalikni `t.parent_id = f.id`
-- deb tekshirardi — valyuta hisobi ILDIZ kassaga (5011) bog'langan, pul esa
-- naqd/Click bolasidan (parent=5011) chiqadi → mos kelmaydi. Eski v2
-- (PROVODKA_VALYUTA.sql) buni `kassa_root()` bilan to'g'ri qilardi, v3 da tushib qolgan.
-- Asilbek QO'LDA RUN qiladi. ADDITIVE: `create or replace` eski imzo bilan
-- (convert_start_v3(uuid,uuid,numeric,numeric,text,numeric)), qolgan tana AYNAN
-- v3 nusxasi — faqat ikkita egalik sharti kassa_root() ga o'tdi. kassa_root()
-- idempotent qayta e'lon qilinadi (VALYUTA RUN qilinmagan bazada ham ishlasin).
-- Izohda dollar-qavs yozilmaydi. Tanalar nomlangan teg bilan.
-- =====================================================================

create or replace function kassa_root(p_id uuid)
returns uuid
language sql
stable
as $kr$
  select case
           when a.parent_id is not null
                and (coalesce(a.currency,'UZS') <> 'UZS' or a.pul_turi is not null)
             then a.parent_id
           else a.id
         end
    from accounts a where a.id = p_id;
$kr$;

revoke all on function kassa_root(uuid) from public, anon;
grant execute on function kassa_root(uuid) to authenticated, service_role;

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

revoke all on function convert_start_v3(uuid, uuid, numeric, numeric, text, numeric) from public, anon;
grant execute on function convert_start_v3(uuid, uuid, numeric, numeric, text, numeric) to authenticated;

-- Tekshiruv: select kassa_root(id), code, name, pul_turi, currency from accounts
--   where code like '50%' or code like '55%' or code like '56%' order by code;
