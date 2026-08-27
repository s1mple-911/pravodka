-- =====================================================================
-- PROVODKA_OVQAT_KECHKI.sql
-- 3-TUR "KECHKI" (uzhin) qo'shiladi — narx 30000. PROVODKA_OVQAT.sql ga
-- TEGILMAYDI (u RUN qilingan); bu fayl uning ustiga create-or-replace
-- qiladi, imzolar (argument/qaytish turi) o'zgarmaydi. ADDITIVE.
-- ---------------------------------------------------------------------
-- ## RUN TARTIBI (Asilbek) — bo'limlarni tartib bilan
--   1-BO'LIM — provodka_config: ovqat_kechki_narx = 30000
--   2-BO'LIM — entry_ovqat.tur check constraint: 'kechki' qo'shiladi
--   3-BO'LIM — ovqat_narxlar() / set_ovqat_narx(text,numeric) — 'kechki' shoxi
--   4-BO'LIM — xarajat_saqlash_ovqat(jsonb) — 'kechki' narxi + tavsif
--   5-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)
--
-- ## OLD SHART
--   PROVODKA_OVQAT.sql — allaqachon RUN qilingan (entry_ovqat, ovqat_narxlar,
--   set_ovqat_narx, xarajat_saqlash_ovqat, ovqat_bugun, v_ovqat_hisobot).
--
-- ## QOIDALAR (CLAUDE.md, buzilmadi)
--   * anonim `do` bloki YO'Q — constraint nomi PostgreSQL standart avtomat
--     nomlash qoidasi bilan aniq: unnamed inline check(column) -> "<table>_<column>_check".
--     entry_ovqat.tur ustidagi check shu qoidaga ko'ra "entry_ovqat_tur_check".
--   * har funksiya tanasi NOMLANGAN dollar-teg (fn) bilan o'raladi.
--   * ovqat_bugun(date,int[]) va v_ovqat_hisobot O'ZGARTIRILMAYDI — ularda
--     tur bo'yicha filtr yo'q (barcha entry_ovqat qatorlarini o'qiydi),
--     'kechki' avtomatik ko'rinadi, alohida ish shart emas.
--   * hammasi additive/idempotent: qayta RUN qilish xavfsiz.
-- =====================================================================


-- #####################################################################
-- ##  1-BO'LIM — provodka_config: ovqat_kechki_narx                  ##
-- #####################################################################

insert into provodka_config (key, val)
values ('ovqat_kechki_narx', '30000')
on conflict (key) do nothing;


-- #####################################################################
-- ##  2-BO'LIM — entry_ovqat.tur check constraint kengaytirish       ##
-- #####################################################################
-- Original ta'rif (PROVODKA_OVQAT.sql:596): `tur text not null
-- check (tur in ('obed', 'zavtrak'))` — nomsiz inline check, PostgreSQL
-- avtomat nom bergan: "entry_ovqat_tur_check". drop+add — idempotent
-- (qayta RUN qilinsa xato bermaydi).
alter table entry_ovqat
  drop constraint if exists entry_ovqat_tur_check;

alter table entry_ovqat
  add constraint entry_ovqat_tur_check check (tur in ('obed', 'zavtrak', 'kechki'));


-- #####################################################################
-- ##  3-BO'LIM — ovqat_narxlar() / set_ovqat_narx() — 'kechki' shoxi ##
-- #####################################################################

create or replace function ovqat_narxlar()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select jsonb_build_object(
    'obed',    coalesce((select nullif(val, '')::numeric from provodka_config where key = 'ovqat_obed_narx'), 30000),
    'zavtrak', coalesce((select nullif(val, '')::numeric from provodka_config where key = 'ovqat_zavtrak_narx'), 7000),
    'kechki',  coalesce((select nullif(val, '')::numeric from provodka_config where key = 'ovqat_kechki_narx'), 30000)
  );
$fn$;

revoke all on function ovqat_narxlar() from public, anon;
grant execute on function ovqat_narxlar() to authenticated;

comment on function ovqat_narxlar() is
  'Ovqat narxlari (obed/zavtrak/kechki), provodka_config dan. Topilmasa 30000/7000/30000 (sukut).';


create or replace function set_ovqat_narx(p_tur text, p_narx numeric)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare v_key text;
begin
  if not is_admin() then
    raise exception 'Faqat admin ovqat narxini o''zgartira oladi' using errcode = '42501';
  end if;
  if p_narx is null or p_narx <= 0 then
    raise exception 'Narx musbat bo''lishi kerak' using errcode = '22000';
  end if;
  if p_tur = 'obed' then
    v_key := 'ovqat_obed_narx';
  elsif p_tur = 'zavtrak' then
    v_key := 'ovqat_zavtrak_narx';
  elsif p_tur = 'kechki' then
    v_key := 'ovqat_kechki_narx';
  else
    raise exception 'Nomalum tur (obed|zavtrak|kechki kerak)' using errcode = '22000';
  end if;

  insert into provodka_config (key, val, updated_by, updated_at)
  values (v_key, p_narx::text, coalesce(auth.uid()::text, 'admin'), now())
  on conflict (key) do update
     set val = excluded.val, updated_by = excluded.updated_by, updated_at = now();
end $fn$;

revoke all on function set_ovqat_narx(text, numeric) from public, anon;
grant execute on function set_ovqat_narx(text, numeric) to authenticated;

comment on function set_ovqat_narx(text, numeric) is
  'Admin: obed/zavtrak/kechki narxini o''zgartiradi (provodka_config).';


-- #####################################################################
-- ##  4-BO'LIM — xarajat_saqlash_ovqat(jsonb) — 'kechki' qo'shiladi  ##
-- #####################################################################
-- 🔴 PROVODKA_OVQAT.sql dagi ENG OXIRGI tananing VERBATIM nusxasi
--    (created_by insertda yo'q, status='posted'/source='manual' qattiq,
--    ovqat_kiritgan, unique handler P0001) + 'kechki' kengaytmasi:
--      * narx o'qish: jsonb_to_record(ovqat_narxlar()) endi kechki ham oladi.
--      * tur validatsiyasi: ('obed','zavtrak','kechki').
--      * narx tanlash: case v_tur when ... else RAISE (boshqa narx
--        yozilib qolmasin — fail-closed, noma'lum tur bu yergacha
--        yetib kelmasligi kerak, lekin himoya ikki qavat bo'lsin).
--      * avtomat description: "N zavtrak, M obed, K kechki".
-- Boshqa tekshiruvlar (summa aynan teng, takror, staff aktiv, kassa UZS) —
-- o'zgarmagan.
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

    -- 🔴 RBAC (PROVODKA_RBAC.sql): rolida shu ovqat turi bo'lmagan user yoza olmaydi —
    --    SERVER tomonda, UI yashirishi yetarli emas. RBAC fayli hali RUN qilinmagan
    --    bo'lsa (funksiya yo'q) — rol tushunchasi yo'q, eski xatti-harakat (ruxsat).
    --    `execute` orqali: plpgsql mavjud bo'lmagan funksiyani CREATE vaqtida emas,
    --    faqat chaqirilganda izlaydi — to_regprocedure guardi shu yerda ishlaydi.
    if to_regprocedure('public.rbac_ovqat_ok(text)') is not null then
      execute 'select rbac_ovqat_ok($1)' into v_rbac_ok using v_tur;
      if not coalesce(v_rbac_ok, false) then
        raise exception 'Ruxsat yoq: "%" ovqat turi rolingizda yoq', v_tur using errcode = '42501';
      end if;
    end if;

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
                     davr_start, davr_end, ext_ref)
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
    v_ext
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
  'summa ro''yxatga AYNAN teng bo''lishi shart, kuniga bir hodim/tur bir marta. Tahrirlash taqiq (PROVODKA_OVQAT.sql 8-BO''LIM).';


-- #####################################################################
-- ##  5-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)            ##
-- #####################################################################

-- 1) constraint ta'rifida 'kechki' bormi
select conname, pg_get_constraintdef(oid) as tadef
  from pg_constraint
 where conrelid = 'public.entry_ovqat'::regclass
   and conname = 'entry_ovqat_tur_check';

-- 2) config qatori borligini tekshirish
select key, val from provodka_config
 where key in ('ovqat_obed_narx', 'ovqat_zavtrak_narx', 'ovqat_kechki_narx');

-- 3) funksiyalar bormi (imzo o'zgarmagan)
select to_regprocedure('public.ovqat_narxlar()')                   is not null as ovqat_narxlar_ok,
       to_regprocedure('public.set_ovqat_narx(text,numeric)')      is not null as set_ovqat_narx_ok,
       to_regprocedure('public.xarajat_saqlash_ovqat(jsonb)')      is not null as xarajat_saqlash_ovqat_ok;

-- Sxema keshi — busiz o'zgargan funksiya tavsifi eskicha ko'rinishi mumkin.
notify pgrst, 'reload schema';
