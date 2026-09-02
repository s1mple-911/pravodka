-- =====================================================================
-- PROVODKA_JADVAL.sql
-- Xarajatga JADVAL biriktirish (Excel nusxasi / .xlsx) — 1-BOSQICH (SQL)
-- ---------------------------------------------------------------------
-- Brief: BRIEF_PROVODKA_JADVAL.md
-- To'liq ADDITIVE: yangi ustun (jsonb, nullable) + check constraint +
-- 2 ta mavjud RPC ning ENG OXIRGI versiyasiga BITTA ustun qo'shilgan
-- nusxasi (imzo/returns/grant/comment o'zgarmagan) + 1 ta YANGI RPC.
-- Manba (bayt-ma-bayt asos, faqat insert ro'yxatiga `jadval` qo'shilgan):
--   xarajat_saqlash_taqsim  <- PROVODKA_TOSIQ_OCHIR.sql (262-392)
--   xarajat_saqlash_ovqat   <- PROVODKA_RBAC_LIMIT.sql  (405-687)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1-BO'LIM — entry.jadval ustuni + check constraint
-- ---------------------------------------------------------------------
alter table entry add column if not exists jadval jsonb;

comment on column entry.jadval is
  'Kiritishda izohdan alohida saqlangan jadval (Excel nusxasi/.xlsx). '
  'Shakl: BRIEF_PROVODKA_JADVAL.md — {v, manba, fayl, cols, rows, jami, n}. '
  'null = jadval biriktirilmagan (oddiy izohli xarajatlar uchun normal holat).';

-- Anonim do bloki: mavjud bazada constraint takror qo'shilib xato bermasin.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'entry_jadval_chk') then
    alter table entry
      add constraint entry_jadval_chk
      check (jadval is null or (jsonb_typeof(jadval) = 'object' and pg_column_size(jadval) <= 120000));
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 2-BO'LIM — xarajat_saqlash_taqsim(jsonb) — jadval qo'shiladi
--   🔴 PROVODKA_TOSIQ_OCHIR.sql (262-392) dagi ENG OXIRGI tananing VERBATIM
--      nusxasi. YAGONA farq: insert ro'yxatiga `jadval` ustuni qo'shilgan.
--      Har filial yozuviga BIR XIL jadval (taqsimotning har bo'lagi bir
--      xil hujjatga tegishli — mantiqan ham shunday).
-- ---------------------------------------------------------------------
create or replace function xarajat_saqlash_taqsim(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  it       jsonb;
  v_entry  uuid;
  v_ids    uuid[] := '{}';
  v_dt     uuid := nullif(p_data->>'dt_account','')::uuid;
  v_kt     uuid := nullif(p_data->>'kt_account','')::uuid;
  v_kassa  uuid := nullif(p_data->>'kassa_account','')::uuid;
  v_cur    text := nullif(p_data->>'kassa_currency','');
  -- 1 birlik valyuta necha so'm. null -> eski xatti-harakat (fc = summa).
  v_kurs   numeric := nullif(p_data->>'kassa_kurs','')::numeric;
  -- Takrorga qarshi token (ixtiyoriy). null -> eski xatti-harakat.
  v_ext    text := nullif(trim(p_data->>'ext_ref'), '');
  v_summa  numeric;
  v_filial uuid;
  v_fc     numeric;
  v_fc_dt  numeric;
  v_fc_kt  numeric;
  -- fc yaxlitlash siljishini yo'qotish uchun: jami valyuta miqdori va sarflangani.
  v_jami   numeric := 0;
  v_fc_bar numeric;
  v_fc_qol numeric;
  v_n      int;
  v_i      int := 0;
begin
  -- lock_timeout — "Saqlanmoqda…" abadiy aylanmasin (5s, 55P03).
  -- `statement_timeout` ATAYLAB o'zgartirilmaydi (joriy so'rovga ta'sir qilmaydi).
  perform set_config('lock_timeout', '5s', true);

  if v_dt is null or v_kt is null then
    raise exception 'dt/kt hisob berilmadi' using errcode = '22000';
  end if;
  if p_data->'taqsim' is null or jsonb_typeof(p_data->'taqsim') <> 'array'
     or jsonb_array_length(p_data->'taqsim') = 0 then
    raise exception 'Taqsimot bo''sh' using errcode = '22000';
  end if;
  if v_kurs is not null and v_kurs <= 0 then
    raise exception 'Kurs musbat bo''lishi kerak' using errcode = '22000';
  end if;
  -- Juda qisqa token butun bir guruh yozuvni "o'ziniki" qilib qo'yishi
  -- mumkin edi (prefiks qidiruvi) — uzunlik chegaralanadi, jim qolinmaydi.
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bo''lishi kerak' using errcode = '22000';
  end if;

  -- Valyuta jamisi BIR MARTA hisoblanadi (ulushlar yig'indisidan), keyin
  -- ulushlarga taqsimlanadi — sum(fc) = round(jami/kurs, 2) aniq mos keladi.
  v_n := jsonb_array_length(p_data->'taqsim');
  if v_kurs is not null then
    select coalesce(sum((x->>'summa')::numeric), 0) into v_jami
      from jsonb_array_elements(p_data->'taqsim') as x;
    v_fc_bar := round(v_jami / v_kurs, 2);
    v_fc_qol := v_fc_bar;
  end if;

  for it in select * from jsonb_array_elements(p_data->'taqsim') loop
    v_i := v_i + 1;
    v_summa  := (it->>'summa')::numeric;
    v_filial := nullif(it->>'filial_id','')::uuid;
    if v_summa is null or v_summa <= 0 then
      raise exception 'Har filial summasi musbat bo''lishi kerak' using errcode = '22000';
    end if;

    insert into entry (entry_date, description, source, status, filial_ids,
                       davr_start, davr_end, kommunal_turi, fc_rate, ext_ref, jadval)
    values (
      nullif(p_data->>'entry_date','')::date,
      nullif(p_data->>'description',''),
      coalesce(nullif(p_data->>'source',''), 'manual'),
      coalesce(nullif(p_data->>'status',''), 'posted'),
      case when v_filial is null then '{}'::uuid[] else array[v_filial] end,
      nullif(p_data->>'davr_start','')::date,
      nullif(p_data->>'davr_end','')::date,
      nullif(p_data->>'kommunal_turi',''),
      case when v_cur is not null and v_cur <> 'UZS' then v_kurs end,
      -- Token berilmasa null (eski xatti-harakat AYNAN saqlanadi).
      -- Shakl `<token>:<i>` — MAVJUD kontrakt, o'zgarmaydi.
      case when v_ext is null then null else v_ext || ':' || v_i::text end,
      -- YANGI: jadval — har filial yozuviga BIR XIL qiymat.
      case when jsonb_typeof(p_data->'jadval') = 'object' then p_data->'jadval' end
    )
    returning id into v_entry;

    -- fc_amount faqat valyuta kassasi satriga (klient bilan bir xil mantiq).
    -- OXIRGI ulushga taqsimlanmay qolgan qoldiq beriladi.
    if v_kurs is null then
      v_fc := v_summa;                                   -- eski xatti-harakat
    elsif v_i = v_n then
      v_fc := v_fc_qol;
    else
      v_fc := round(v_fc_bar * v_summa / nullif(v_jami, 0), 2);
      v_fc_qol := v_fc_qol - v_fc;
    end if;
    v_fc_dt := case when v_cur is not null and v_cur <> 'UZS' and v_kassa = v_dt then v_fc else null end;
    v_fc_kt := case when v_cur is not null and v_cur <> 'UZS' and v_kassa = v_kt then v_fc else null end;

    -- 🔴 IKKI SATR — qarz (uchinchi) satri YO'Q. Dt = Kt = v_summa.
    insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
    values (v_entry, v_dt, v_summa, 0, v_fc_dt),
           (v_entry, v_kt, 0, v_summa, v_fc_kt);

    v_ids := v_ids || v_entry;
  end loop;

  return jsonb_build_object('ok', true,
                            'count', coalesce(array_length(v_ids, 1), 0),
                            'entry_ids', to_jsonb(v_ids));

exception
  -- Takror. Xato KODI o'zgarmaydi (23505) — klient aynan shu kod bo'yicha
  -- "allaqachon saqlangan" deb qaror qiladi. Funksiya tranzaksiya bo'lgani
  -- uchun bu yerga yetganda BU URINISHDAN hech narsa yozilmagan.
  when unique_violation then
    if v_ext is null then
      raise;                                   -- bizning to'siq EMAS
    end if;
    raise exception 'Bu xarajat allaqachon saqlangan (takroriy yuborish tosildi)'
      using errcode = '23505';
end $fn$;

revoke all on function xarajat_saqlash_taqsim(jsonb) from public, anon;
grant execute on function xarajat_saqlash_taqsim(jsonb) to authenticated;

comment on function xarajat_saqlash_taqsim(jsonb) is
  'Filial bo''yicha alohida provodka: har filialga bitta entry (atomik). perm guard har satrga ishlaydi. '
  'kassa_kurs berilsa valyuta kassasida fc = summa/kurs (aks holda fc = summa — eski xatti-harakat). '
  'ext_ref berilsa har entry ga <token>:<indeks> yoziladi — takror yuborish 23505 bilan tosiladi. '
  'lock_timeout = 5s. YANGI (PROVODKA_JADVAL.sql): p_data.jadval berilsa har filial yozuviga bir xil yoziladi.';


-- ---------------------------------------------------------------------
-- 3-BO'LIM — xarajat_saqlash_ovqat(jsonb) — jadval qo'shiladi
--   🔴 PROVODKA_RBAC_LIMIT.sql (405-687) dagi ENG OXIRGI tananing VERBATIM
--      nusxasi. YAGONA farq: insert ro'yxatiga `jadval` ustuni qo'shilgan.
-- ---------------------------------------------------------------------
create or replace function xarajat_saqlash_ovqat(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_dt         uuid := nullif(p_data->>'dt_account', '')::uuid;
  v_kt         uuid := nullif(p_data->>'kt_account', '')::uuid;
  v_summa      numeric := nullif(p_data->>'summa', '')::numeric;
  v_ext        text := nullif(trim(p_data->>'ext_ref'), '');
  v_kun        date := coalesce(nullif(p_data->>'kun', '')::date,
                                 (now() at time zone 'Asia/Tashkent')::date);
  v_entry_date date := coalesce(nullif(p_data->>'entry_date', '')::date, v_kun);

  v_dt_ovqat   boolean;
  v_kt_cur     text;

  it           jsonb;
  v_n          int;
  v_i          int := 0;
  v_rbac_ok    boolean;
  v_staff      int;
  v_tur        text;
  v_narx_obed    numeric;
  v_narx_zavtrak numeric;
  v_narx_kechki  numeric;
  v_narx       numeric;
  v_royxat_summa numeric := 0;

  v_seen_keys  text[] := '{}';
  v_key        text;

  v_staff_ids  int[]    := '{}';
  v_turs       text[]   := '{}';
  v_narxs      numeric[]:= '{}';
  v_snoms      text[]   := '{}';
  v_name_seen  int[]    := '{}';
  v_names      text[]   := '{}';

  v_snom       text;
  v_active     boolean;
  v_cnt_obed   int := 0;
  v_cnt_zavtrak int := 0;
  v_cnt_kechki int := 0;

  v_dup_soat   text;
  v_dup_kim    text;
  v_dup_entry  uuid;

  -- YANGI (PROVODKA_RBAC_LIMIT.sql): ovqat OYLIK limiti
  v_narx_shu    numeric;
  v_lim_ovqat   numeric;
  v_used_ovqat  numeric;

  v_entry      uuid;
  v_con        text;
  v_det        text;
  j            int;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_dt is null or v_kt is null then
    raise exception 'Modda (Dt) va kassa (Kt) tanlanishi shart' using errcode = '22000';
  end if;
  if v_summa is null or v_summa <= 0 then
    raise exception 'Summa musbat bo''lishi kerak' using errcode = '22000';
  end if;
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bo''lishi kerak' using errcode = '22000';
  end if;
  if p_data->'royxat' is null or jsonb_typeof(p_data->'royxat') <> 'array'
     or jsonb_array_length(p_data->'royxat') = 0 then
    raise exception 'Hodim ro''yxati bo''sh' using errcode = '22000';
  end if;

  select ovqat_modda into v_dt_ovqat from accounts where id = v_dt;
  if not coalesce(v_dt_ovqat, false) then
    raise exception 'Tanlangan modda ovqat moddasi emas (admin uni Sozlamada belgilashi kerak)'
      using errcode = '22000';
  end if;

  select coalesce(currency, 'UZS') into v_kt_cur from accounts where id = v_kt;
  if v_kt_cur is null then
    raise exception 'Kassa topilmadi' using errcode = '22000';
  end if;
  if v_kt_cur <> 'UZS' then
    raise exception 'Ovqat faqat so''m kassasidan yoziladi (valyuta kassasi v1 da qo''llab-quvvatlanmaydi)'
      using errcode = '22000';
  end if;

  select obed, zavtrak, kechki into v_narx_obed, v_narx_zavtrak, v_narx_kechki
    from jsonb_to_record(ovqat_narxlar()) as t(obed numeric, zavtrak numeric, kechki numeric);

  v_n := jsonb_array_length(p_data->'royxat');

  -- ---- 1-O'TISH: FAQAT TEKSHIRUV (hech narsa yozilmaydi) --------------
  for j in 0 .. v_n - 1 loop
    v_i := v_i + 1;
    it := p_data->'royxat'->j;
    v_staff := nullif(it->>'staff_id', '')::int;
    v_tur   := nullif(it->>'tur', '');

    if v_staff is null then
      raise exception 'Ro''yxatdagi %-satrda staff_id ko''rsatilmagan', v_i using errcode = '22000';
    end if;
    if v_tur is null or v_tur not in ('obed', 'zavtrak', 'kechki') then
      raise exception 'Ro''yxatdagi %-satrda tur noto''g''ri (obed|zavtrak|kechki kerak)', v_i using errcode = '22000';
    end if;

    -- 🔴 Asilbek qarori (2026-08-27): YOZUVCHI roli ovqatga TA'SIR QILMAYDI —
    --    faqat yeyuvchi hodim roli (pastdagi rbac_staff_ovqat). Eski yozuvchi
    --    tekshiruvi (rbac_ovqat_ok) ataylab OLIB TASHLANDI: yozuvchida faqat obed
    --    bo'lsa hamkasblarining kechki/zavtragi yashirilib qolardi.

    v_key := v_staff::text || ':' || v_tur;
    if v_key = any(v_seen_keys) then
      select coalesce(nullif(btrim(toliq_nom), ''), btrim(coalesce(ism, '') || ' ' || coalesce(familiya, '')))
        into v_snom from aros_staff where staff_id = v_staff;
      raise exception '% uchun % ro''yxatda ikki marta ko''rsatilgan', coalesce(nullif(v_snom, ''), v_staff::text), v_tur
        using errcode = '22000';
    end if;
    v_seen_keys := v_seen_keys || v_key;

    select coalesce(nullif(btrim(toliq_nom), ''), btrim(coalesce(ism, '') || ' ' || coalesce(familiya, ''))),
           is_active
      into v_snom, v_active
      from aros_staff
     where staff_id = v_staff;

    if v_snom is null then
      raise exception 'Xodim topilmadi (staff_id=%)', v_staff using errcode = '22000';
    end if;
    if not coalesce(v_active, false) then
      raise exception '% faol emas, ovqat yozib bo''lmaydi', v_snom using errcode = '22000';
    end if;

    -- 🔴 YEYUVCHI (PROVODKA_RBAC_STAFF.sql, YANGI): hodimning O'ZI shu ovqat
    --    turiga ruxsatlimi (rbac_staff_role orqali). YOZUVCHI tekshiruvidan
    --    (yuqorida) MUSTAQIL — ikkalasi ham o'tishi shart (AND). Admin
    --    yozayotgan bo'lsa ham (yozuvchi shoxidan o'tadi) bu shox AMAL
    --    QILADI — ruxsat ovqatni yeyadigan hodimga tegishli, kim yozganiga
    --    emas. Rolsiz hodim -> rbac_staff_ovqat() '{}' qaytaradi -> rad.
    if not (v_tur = any(rbac_staff_ovqat(v_staff))) then
      raise exception '% uchun "%" ovqat turi ruxsat etilmagan (hodim roli)', v_snom, v_tur
        using errcode = '42501';
    end if;

    -- 🔴 YANGI (PROVODKA_RBAC_LIMIT.sql): rolda shu ovqat turiga OYLIK
    --    limit qoyilgan bolsa (rbac_role_ovqat.limit_uzs), limit YEYUVCHI
    --    hodimga tegishli (rbac_limit_ovqat_staff — rbac_staff_ovqat bilan
    --    bir xil manba). Bir nechta rolda bittasida limit yoq (null) bolsa
    --    — CHEKSIZ. Tekshiruv entry insertdan OLDIN (hech narsa yozilmaydi).
    if v_tur = 'obed' then v_narx_shu := v_narx_obed;
    elsif v_tur = 'zavtrak' then v_narx_shu := v_narx_zavtrak;
    else v_narx_shu := v_narx_kechki;
    end if;

    v_lim_ovqat := rbac_limit_ovqat_staff(v_staff, v_tur);
    if v_lim_ovqat is not null then
      v_used_ovqat := rbac_ovqat_ishlatildi(v_staff, v_tur, v_kun) + v_narx_shu;
      if v_used_ovqat > v_lim_ovqat then
        raise exception 'Oylik ovqat limiti oshdi: % — % (limit %, ishlatildi %)',
          v_snom, v_tur, round(v_lim_ovqat), round(v_used_ovqat)
          using errcode = '42501';
      end if;
    end if;

    -- Bazada shu kun/staff/tur allaqachon bormi?
    select to_char(eo.created_at at time zone 'Asia/Tashkent', 'HH24:MI'),
           ovqat_kiritgan((to_jsonb(e) ->> 'created_by')),
           eo.entry_id
      into v_dup_soat, v_dup_kim, v_dup_entry
      from entry_ovqat eo
      join entry e on e.id = eo.entry_id
     where eo.staff_id = v_staff and eo.kun = v_kun and eo.tur = v_tur and not eo.is_deleted
     limit 1;

    if v_dup_entry is not null then
      raise exception '% bugun % olgan (%, %)', v_snom, v_tur, coalesce(v_dup_soat, '?'), coalesce(v_dup_kim, 'Noma''lum')
        using errcode = 'P0001';
    end if;

    -- 🔴 fail-closed: uch turdan tashqarisi bu yergacha yetib kelmaydi
    --    (yuqorida tekshirilgan), lekin ikkinchi qavat himoya sifatida
    --    ELSE holatida boshqa narx yozilib qolmasin — RAISE.
    case v_tur
      when 'obed'    then v_narx := v_narx_obed;
      when 'zavtrak' then v_narx := v_narx_zavtrak;
      when 'kechki'  then v_narx := v_narx_kechki;
      else raise exception 'Nomalum tur (obed|zavtrak|kechki kerak)' using errcode = '22000';
    end case;
    v_royxat_summa := v_royxat_summa + v_narx;

    v_staff_ids := v_staff_ids || v_staff;
    v_turs      := v_turs || v_tur;
    v_narxs     := v_narxs || v_narx;
    v_snoms     := v_snoms || v_snom;

    if v_tur = 'obed' then v_cnt_obed := v_cnt_obed + 1;
    elsif v_tur = 'zavtrak' then v_cnt_zavtrak := v_cnt_zavtrak + 1;
    else v_cnt_kechki := v_cnt_kechki + 1;
    end if;
    if not (v_staff = any(v_name_seen)) then
      v_name_seen := v_name_seen || v_staff;
      v_names := v_names || v_snom;
    end if;
  end loop;

  -- 🔴 Summa AYNAN mos bo'lishi shart (kam ham, ko'p ham xato).
  if v_royxat_summa <> v_summa then
    raise exception 'Summa ro''yxatga mos emas: ro''yxat %, yozilgan %', v_royxat_summa::text, v_summa::text
      using errcode = 'P0001';
  end if;

  -- ---- 2-O'TISH: YOZISH ------------------------------------------------
  -- 🔴 status/source KLIENTDAN OLINMAYDI (fail-closed — tester topilmasi):
  --    status='draft' kelsa pul yozilmay entry_ovqat unique slot abadiy
  --    band bo'lib qolardi (ovqat_bugun'da jim yo'qolgan slot). Shuning
  --    uchun ikkalasi ham QATTIQ literal: har doim 'posted' / 'manual'.
  -- 🔴 `created_by` INSERT ro'yxatida YO'Q — `xarajat_saqlash_taqsim`
  --    (PROVODKA_TOSIQ_OCHIR.sql) bilan AYNAN bir xil naqsh: ustun turi
  --    (`entry.created_by`) bazada noma'lum (PROVODKA_IJROCHI.sql:12-35),
  --    `auth.uid()` (uuid) ni to'g'ridan yozish text ustunda cast xatosi
  --    berishi mumkin. `trg_entry_ijrochi` (BEFORE INSERT, PROVODKA_IJROCHI.sql)
  --    `created_by is null` bo'lganda `jsonb_populate_record` bilan (turga
  --    bog'liq bo'lmagan usulda) avtomat to'ldiradi.
  insert into entry (entry_date, description, source, status, filial_ids,
                     davr_start, davr_end, ext_ref, jadval)
  values (
    v_entry_date,
    coalesce(nullif(p_data->>'description', ''),
             'Ovqat: ' || v_cnt_zavtrak || ' zavtrak, ' || v_cnt_obed || ' obed, ' || v_cnt_kechki || ' kechki — ' || array_to_string(v_names, ', ')),
    'manual',
    'posted',
    case when jsonb_typeof(p_data->'filial_ids') = 'array'
         then coalesce((select array_agg(t.val::uuid) from jsonb_array_elements_text(p_data->'filial_ids') as t(val)),
                       '{}'::uuid[])
         else '{}'::uuid[] end,
    nullif(p_data->>'davr_start', '')::date,
    nullif(p_data->>'davr_end', '')::date,
    v_ext,
    -- YANGI (PROVODKA_JADVAL.sql): jadval — izohdan alohida saqlangan jadval.
    case when jsonb_typeof(p_data->'jadval') = 'object' then p_data->'jadval' end
  )
  returning id into v_entry;

  insert into entry_line (entry_id, account_id, debit, credit)
  values (v_entry, v_dt, v_summa, 0),
         (v_entry, v_kt, 0, v_summa);

  for v_i in 1 .. v_n loop
    insert into entry_ovqat (entry_id, staff_id, staff_nom, tur, narx, kun)
    values (v_entry, v_staff_ids[v_i], v_snoms[v_i], v_turs[v_i], v_narxs[v_i], v_kun);
  end loop;

  return jsonb_build_object('entry_id', v_entry, 'summa', v_royxat_summa, 'royxat_soni', v_n);

exception
  when unique_violation then
    get stacked diagnostics v_con = constraint_name, v_det = pg_exception_detail;
    if coalesce(v_con, '') ilike '%entry_ovqat%' or coalesce(v_det, '') ilike '%entry_ovqat%' then
      raise exception 'Shu kun uchun bu hodimga bu ovqat turi boshqa foydalanuvchi tomonidan bir vaqtda yozildi — sahifani yangilang'
        using errcode = 'P0001';
    end if;
    if v_ext is null then
      raise;                                   -- bizning to'siq emas
    end if;
    if coalesce(v_con, '') not ilike '%ext_ref%' and coalesce(v_det, '') not ilike '%ext_ref%' then
      raise;
    end if;
    raise exception 'Bu xarajat allaqachon saqlangan (takroriy yuborish to''sildi)'
      using errcode = '23505';
end $fn$;

revoke all on function xarajat_saqlash_ovqat(jsonb) from public, anon;
grant execute on function xarajat_saqlash_ovqat(jsonb) to authenticated;

comment on function xarajat_saqlash_ovqat(jsonb) is
  'Ovqat (obed/zavtrak/kechki) xarajatini hodim ro''yxati bilan atomik yozadi. Narx serverdan (ovqat_narxlar()), '
  'summa ro''yxatga AYNAN teng bo''lishi shart, kuniga bir hodim/tur bir marta. '
  'Ikki mustaqil ruxsat: YOZUVCHI (rbac_ovqat_ok, kim yozyapti) VA YEYUVCHI (rbac_staff_ovqat, kimga yozilyapti) — '
  'ikkalasi ham o''tishi shart. YANGI (PROVODKA_RBAC_LIMIT.sql): YEYUVCHI hodimning OYLIK ovqat limiti '
  '(rbac_limit_ovqat_staff) — entry insertdan oldin, hech narsa yozilmasdan tekshiriladi. '
  'YANGI (PROVODKA_JADVAL.sql): p_data.jadval berilsa entry.jadval ga yoziladi. '
  'Tahrirlash taqiq (PROVODKA_OVQAT.sql 8-BO''LIM).';


-- ---------------------------------------------------------------------
-- 4-BO'LIM — entry_jadval_yoz(text, jsonb) — YANGI
--   "Pul so'rash" oqimi uchun: entry `sorov_yarat` ichida yaratiladi (imzosi
--   o'zgartirilmaydi), jadval esa MUVAFFAQIYATDAN KEYIN shu RPC bilan
--   alohida yoziladi. security definer — entry edit RLS'ini chetlab o'tadi,
--   shuning uchun FAQAT jadval ustunini yozadi, boshqa hech narsa.
-- ---------------------------------------------------------------------
create or replace function entry_jadval_yoz(p_ext_ref text, p_jadval jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_ext   text := nullif(btrim(p_ext_ref), '');
  v_id    uuid;
  v_jadval_old jsonb;
  v_created_at timestamptz;
  -- 🔴 `created_by` turi bazada aniqlanmagan (PROVODKA_HODIM_NOTIFY.sql
  --    565-571 naqshi): uuid ham, text ham bo'lishi mumkin. `::uuid` cast
  --    FAQAT to'liq uuid shaklida bajariladi — aks holda buzuq qiymat
  --    22P02 bilan butun RPC ni yiqitardi.
  v_created_by_raw text;
  v_owner uuid;
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

  select e.id, e.jadval, e.created_at, (to_jsonb(e) ->> 'created_by')
    into v_id, v_jadval_old, v_created_at, v_created_by_raw
    from entry e
   where e.ext_ref = v_ext
   limit 1;

  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'Yozuv topilmadi');
  end if;

  v_owner := case when v_created_by_raw ~ '^[0-9a-fA-F-]{36}$' then v_created_by_raw::uuid end;
  if v_owner is distinct from v_uid then
    return jsonb_build_object('ok', false, 'error', 'Bu yozuv sizniki emas');
  end if;
  if v_created_at is null or v_created_at < now() - interval '30 minutes' then
    return jsonb_build_object('ok', false, 'error', 'Vaqt tugagan (30 daqiqadan oshgan)');
  end if;
  if v_jadval_old is not null then
    return jsonb_build_object('ok', false, 'error', 'Jadval allaqachon biriktirilgan');
  end if;

  update entry set jadval = p_jadval where id = v_id;

  return jsonb_build_object('ok', true);
end $fn$;

revoke all on function entry_jadval_yoz(text, jsonb) from public, anon;
grant execute on function entry_jadval_yoz(text, jsonb) to authenticated;

comment on function entry_jadval_yoz(text, jsonb) is
  'Pul so''rash oqimida (sorov_yarat) allaqachon yaratilgan entry''ga jadval keyin biriktiriladi. '
  'security definer — entry edit RLS''ini chetlab o''tadi, shuning uchun FAQAT jadval ustunini yozadi. '
  'Shartlar: auth.uid() bor, ext_ref topildi, yozuv o''ziniki, 30 daqiqa ichida, jadval hali bo''sh, hajm <= 120000 bayt.';


-- ---------------------------------------------------------------------
-- 5-BO'LIM — Tekshiruv (faqat select, hech narsani o'zgartirmaydi)
-- ---------------------------------------------------------------------
select
  exists (select 1 from information_schema.columns
           where table_name = 'entry' and column_name = 'jadval')     as jadval_ustun_bor,
  to_regprocedure('public.xarajat_saqlash_taqsim(jsonb)')  is not null as taqsim_bor,
  to_regprocedure('public.xarajat_saqlash_ovqat(jsonb)')   is not null as ovqat_bor,
  to_regprocedure('public.entry_jadval_yoz(text, jsonb)')  is not null as jadval_yoz_bor;
