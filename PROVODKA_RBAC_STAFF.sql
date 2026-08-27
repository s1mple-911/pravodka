-- =====================================================================
-- PROVODKA_RBAC_STAFF.sql
-- Ovqat cheklovini YOZUVCHI (auth user) dan YEYUVCHI HODIMGA (aros_staff)
-- ko'chiradi. Muammo: hozir "kim yozdi" tekshiriladi (rbac_ovqat_ok —
-- auth.uid() roli), shuning uchun bitta "obed" ruxsatli xodim yozganda
-- ro'yxatdagi HAMMA hamkasbga obed ochiq bo'lib qolyapti. Yechim: rollar
-- endi aros_staff hodimlariga ham biriktiriladi (rbac_staff_role), va
-- xarajat_saqlash_ovqat() ICHIDA har satr uchun hodimning O'ZI ruxsatli
-- ovqat turimi tekshiriladi — YOZUVCHI tekshiruvi (rbac_ovqat_ok, eski)
-- BILAN BIRGA (AND), biri o'rniga emas.
-- ---------------------------------------------------------------------
-- ## RUN TARTIBI (Asilbek) — bo'limlarni tartib bilan
--   0-BO'LIM — old shart tekshiruvi (faqat select)
--   1-BO'LIM — rbac_staff_role jadvali + RLS
--   2-BO'LIM — rbac_staff_ovqat(int) + ovqat_ruxsatlar(int[])
--   3-BO'LIM — xarajat_saqlash_ovqat(jsonb) — YEYUVCHI cheklovi qo'shiladi
--              (PROVODKA_OVQAT_KECHKI.sql dagi ENG OXIRGI tananing VERBATIM
--              nusxasi + bitta qo'shimcha IF)
--   4-BO'LIM — rbac_staff_royxat() / rbac_staff_set() — admin RPC
--   5-BO'LIM — rbac_royxat() — staff_soni qo'shiladi (imzo bir xil)
--   6-BO'LIM — rbac_role_delete() — rbac_staff_role biriktirilgan bo'lsa ham rad
--   7-BO'LIM — migratsiya (bir martalik, provodka_config bayrog'i bilan)
--   8-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)
--
-- ## OLD SHART (bazada bo'lishi kerak)
--   PROVODKA_RBAC.sql          -> rbac_role, rbac_role_ovqat, rbac_user_role,
--                                 rbac_ovqat_ok, rbac_royxat, rbac_role_delete,
--                                 "Standart hodim" migratsiyasi
--   PROVODKA_OVQAT.sql         -> aros_staff, entry_ovqat
--   PROVODKA_OVQAT_KECHKI.sql  -> xarajat_saqlash_ovqat() eng oxirgi tanasi
--
-- ## QOIDALAR (CLAUDE.md, buzilmadi)
--   * anonim `do` bloki YO'Q — har `do` bloki NOMLANGAN teg bilan
--     (masalan "rbac_staff_pre"/"rbac_staff_migrate" nomli — PROVODKA_RBAC.sql
--     bilan bir xil naqsh).
--   * har funksiya tanasi NOMLANGAN dollar-teg (masalan "fn" nomli) bilan o'raladi.
--   * izohda dollar-qavs ($+$) YO'Q.
--   * hammasi additive: eski jadval/ustun/funksiya imzosi buzilmaydi.
--   * idempotent: qayta RUN qilish xavfsiz (migratsiya provodka_config
--     bayrog'i bilan bir martalik).
--   * 🔴 Admin YOZUVCHI bo'lsa ham (rbac_ovqat_ok/writer tekshiruvidan
--     o'tadi) — YEYUVCHI hodim cheklovi baribir AMAL QILADI. Bu kompaniya
--     qoidasi: ruxsat ovqatni YEYDIGAN hodimga tegishli, yozuvchiga emas.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (faqat select)                 ##
-- #####################################################################

do $rbac_staff_pre$
begin
  if to_regclass('public.aros_staff') is null then
    raise exception 'aros_staff jadvali yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;
  if to_regclass('public.entry_ovqat') is null then
    raise exception 'entry_ovqat jadvali yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_role') is null then
    raise exception 'rbac_role jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regclass('public.rbac_role_ovqat') is null then
    raise exception 'rbac_role_ovqat jadvali yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'is_admin() funksiyasi yoq — RBAC_STAFF unga tayanadi';
  end if;
  if to_regprocedure('public.rbac_royxat()') is null then
    raise exception 'rbac_royxat() funksiyasi yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_role_delete(uuid)') is null then
    raise exception 'rbac_role_delete(uuid) funksiyasi yoq — avval PROVODKA_RBAC.sql ni bajaring';
  end if;
  if to_regprocedure('public.xarajat_saqlash_ovqat(jsonb)') is null then
    raise exception 'xarajat_saqlash_ovqat(jsonb) funksiyasi yoq — avval PROVODKA_OVQAT_KECHKI.sql ni bajaring';
  end if;
  -- 🔴 KECHKI haqiqatan RUN qilinganmi: entry_ovqat.tur check'ida 'kechki' bo'lsin.
  --    Aks holda bu fayl kechki-tanani yozib, constraint hali 2 turli qoladi —
  --    tur='kechki' yozuv xom Postgres xatosi bilan yiqilardi.
  if not exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.entry_ovqat'::regclass
       and c.contype = 'c'
       and pg_get_constraintdef(c.oid) like '%kechki%') then
    raise exception 'entry_ovqat.tur check''ida kechki yoq — avval PROVODKA_OVQAT_KECHKI.sql ni bajaring';
  end if;
end
$rbac_staff_pre$;


-- #####################################################################
-- ##  1-BO'LIM — rbac_staff_role jadvali + RLS                       ##
-- #####################################################################

create table if not exists rbac_staff_role (
  staff_id    int         not null references aros_staff(staff_id) on delete cascade,
  role_id     uuid        not null references rbac_role(id) on delete cascade,
  created_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (staff_id, role_id)
);

create index if not exists rbac_staff_role_role_idx on rbac_staff_role (role_id);

comment on table rbac_staff_role is
  'YEYUVCHI hodim (aros_staff) <-> rol. Ovqat cheklovi shu jadvaldan (rbac_staff_ovqat()) — '
  'YOZUVCHI (rbac_user_role/auth user) rolidan EMAS. Yozish faqat rbac_staff_set() orqali (admin).';

alter table rbac_staff_role enable row level security;

-- Ro'yxat (hodim + rol) hamma kirgan userga kerak (hodim ro'yxatini chizish
-- uchun, masalan xarajat kiritish sahifasida "kim nima ola oladi" ko'rsatish).
-- aros_staff_sel bilan bir xil naqsh (select true).
drop policy if exists rbac_staff_role_sel on rbac_staff_role;
create policy rbac_staff_role_sel on rbac_staff_role
  for select to authenticated using (true);

-- 🔴 insert/update/delete policy YO'Q — faqat rbac_staff_set() (security
--    definer, table owner) yozadi.
revoke all on rbac_staff_role from public, anon;
grant select on rbac_staff_role to authenticated;


-- #####################################################################
-- ##  2-BO'LIM — rbac_staff_ovqat(int) + ovqat_ruxsatlar(int[])      ##
-- #####################################################################

-- 2.1 rbac_staff_ovqat(p_staff) — shu hodimning faol rollari bo'yicha
--     UNION ovqat turlari. Rol yo'q -> '{}' (FAIL-CLOSED).
create or replace function rbac_staff_ovqat(p_staff int)
returns text[]
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(array_agg(distinct ro.tur), '{}'::text[])
    from rbac_staff_role sr
    join rbac_role r on r.id = sr.role_id and r.is_active
    join rbac_role_ovqat ro on ro.role_id = sr.role_id
   where sr.staff_id = p_staff;
$fn$;

revoke all on function rbac_staff_ovqat(int) from public, anon;
grant execute on function rbac_staff_ovqat(int) to authenticated, service_role;

comment on function rbac_staff_ovqat(int) is
  'Hodimning (aros_staff.staff_id) o''zi ruxsatli ovqat turlari (rbac_staff_role orqali, UNION). '
  'Rol biriktirilmagan hodim -> {} (hech narsa yeyolmaydi, fail-closed).';


-- 2.2 ovqat_ruxsatlar(p_staff int[] default null) — klient ro'yxat
--     chizishda BITTA so'rov: { "<staff_id>": ["obed","kechki"], ... }.
--     p_staff = null -> hamma FAOL hodim.
create or replace function ovqat_ruxsatlar(p_staff int[] default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(jsonb_object_agg(x.staff_id::text, to_jsonb(x.turlar)), '{}'::jsonb)
    from (
      select s.staff_id,
             coalesce(array_agg(distinct ro.tur) filter (where ro.tur is not null), '{}'::text[]) as turlar
        from aros_staff s
        left join rbac_staff_role sr on sr.staff_id = s.staff_id
        left join rbac_role r on r.id = sr.role_id and r.is_active
        left join rbac_role_ovqat ro on ro.role_id = r.id
       where s.is_active
         and (p_staff is null or s.staff_id = any(p_staff))
       group by s.staff_id
    ) x;
$fn$;

revoke all on function ovqat_ruxsatlar(int[]) from public, anon;
grant execute on function ovqat_ruxsatlar(int[]) to authenticated;

comment on function ovqat_ruxsatlar(int[]) is
  'Klient uchun: hodimlarning ruxsatli ovqat turlari, bitta group by so''rov. '
  'p_staff null -> hamma faol hodim. Rolsiz hodim -> bo''sh massiv (fail-closed).';


-- #####################################################################
-- ##  3-BO'LIM — xarajat_saqlash_ovqat(jsonb) — YEYUVCHI cheklovi    ##
-- #####################################################################
-- 🔴 PROVODKA_OVQAT_KECHKI.sql dagi ENG OXIRGI tananing VERBATIM nusxasi
--    (kechki tur + yozuvchi rbac_ovqat_ok guard) + BITTA qo'shimcha IF:
--    har satrda hodimning O'ZI (rbac_staff_ovqat) shu ovqat turiga
--    ruxsatli ekanini tekshiradi. Ikkalasi (yozuvchi VA yeyuvchi) AND —
--    ikkalasi ham o'tishi shart, biri ikkinchisini almashtirmaydi.
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
  'summa ro''yxatga AYNAN teng bo''lishi shart, kuniga bir hodim/tur bir marta. '
  'Ikki mustaqil ruxsat: YOZUVCHI (rbac_ovqat_ok, kim yozyapti) VA YEYUVCHI (rbac_staff_ovqat, kimga yozilyapti) — '
  'ikkalasi ham o''tishi shart (PROVODKA_RBAC_STAFF.sql). Tahrirlash taqiq (PROVODKA_OVQAT.sql 8-BO''LIM).';


-- #####################################################################
-- ##  4-BO'LIM — Admin RPC: rbac_staff_royxat() / rbac_staff_set()   ##
-- #####################################################################

-- 4.1 rbac_staff_royxat() — sozlama UI uchun: faol hodimlar (rollari
--     bilan) + tanlash uchun rollar ro'yxati (ovqat turlari bilan).
create or replace function rbac_staff_royxat()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not is_admin() then
    raise exception 'Faqat admin hodim-rol ro''yxatini ko''ra oladi' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'hodimlar', coalesce((
      select jsonb_agg(jsonb_build_object(
          'staff_id',    s.staff_id,
          'toliq_nom',   coalesce(nullif(btrim(s.toliq_nom), ''),
                                   btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))),
          'lavozim',     s.lavozim,
          'branch_nomi', s.branch_nomi,
          'rollar',      coalesce((
            select jsonb_agg(jsonb_build_object('id', r.id, 'nom', r.nom) order by r.nom)
              from rbac_staff_role sr
              join rbac_role r on r.id = sr.role_id
             where sr.staff_id = s.staff_id), '[]'::jsonb)
        ) order by coalesce(nullif(btrim(s.toliq_nom), ''), s.staff_id::text))
      from aros_staff s
     where s.is_active), '[]'::jsonb),
    'rollar', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id',    r.id,
          'nom',   r.nom,
          'ovqat', coalesce((select jsonb_agg(ro.tur order by ro.tur)
                                from rbac_role_ovqat ro where ro.role_id = r.id), '[]'::jsonb)
        ) order by r.nom)
      from rbac_role r
     where r.is_active), '[]'::jsonb)
  );
end
$fn$;

revoke all on function rbac_staff_royxat() from public, anon;
grant execute on function rbac_staff_royxat() to authenticated;

comment on function rbac_staff_royxat() is
  'Admin: faol aros_staff hodimlari (o''z rollari bilan) + tanlash uchun faol rollar ro''yxati (ovqat turlari bilan).';


-- 4.2 rbac_staff_set(p_staff, p_roles) — hodimning rollarini to'liq almashtiradi
create or replace function rbac_staff_set(p_staff int, p_roles uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_roles uuid[];
  v_bad   int;
begin
  if not is_admin() then
    raise exception 'Faqat admin hodimga rol beradi' using errcode = '42501';
  end if;

  if not exists (select 1 from aros_staff where staff_id = p_staff) then
    raise exception 'Hodim topilmadi: %', p_staff using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct x), '{}') into v_roles
    from unnest(coalesce(p_roles, '{}'::uuid[])) x;

  select count(*) into v_bad from unnest(v_roles) x
   where not exists (select 1 from rbac_role r where r.id = x);
  if v_bad > 0 then
    raise exception 'Noma''lum rol id bor' using errcode = '22023';
  end if;

  delete from rbac_staff_role where staff_id = p_staff;
  insert into rbac_staff_role (staff_id, role_id, updated_by)
    select p_staff, x, auth.uid() from unnest(v_roles) x;

  return jsonb_build_object('ok', true, 'staff_id', p_staff, 'roles', to_jsonb(v_roles));
end
$fn$;

revoke all on function rbac_staff_set(int, uuid[]) from public, anon;
grant execute on function rbac_staff_set(int, uuid[]) to authenticated;

comment on function rbac_staff_set(int, uuid[]) is
  'Admin: hodimning (aros_staff.staff_id) rollarini TO''LIQ almashtiradi (eskisi o''chiriladi, yangisi yoziladi).';


-- #####################################################################
-- ##  5-BO'LIM — rbac_royxat() — staff_soni qo'shiladi (imzo bir xil)##
-- #####################################################################
-- 🔴 PROVODKA_RBAC.sql 8.1 dagi tana asosida — barcha eski maydonlar
--    VERBATIM saqlanadi, faqat har rol uchun staff_soni qo'shiladi.
create or replace function rbac_royxat()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $rbac_royxat$
begin
  if not is_admin() then
    raise exception 'Faqat admin rol ro''yxatini ko''ra oladi' using errcode = '42501';
  end if;

  return (
    with rr as (
      select r.id, r.nom, r.izoh, r.is_active,
        coalesce((select jsonb_agg(ra.amal order by ra.amal)
                    from rbac_role_amal ra where ra.role_id = r.id), '[]'::jsonb) as amallar,
        coalesce((select jsonb_agg(rm.account_id)
                    from rbac_role_modda rm where rm.role_id = r.id), '[]'::jsonb) as moddalar,
        coalesce((select jsonb_agg(ro.tur order by ro.tur)
                    from rbac_role_ovqat ro where ro.role_id = r.id), '[]'::jsonb) as ovqat,
        (select count(*) from rbac_user_role ur where ur.role_id = r.id)::int as user_soni,
        (select count(*) from rbac_staff_role sr where sr.role_id = r.id)::int as staff_soni
        from rbac_role r
    )
    select jsonb_build_object(
      'rollar', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', id, 'nom', nom, 'izoh', izoh, 'is_active', is_active,
          'amallar', amallar, 'moddalar', moddalar, 'ovqat', ovqat,
          'user_soni', user_soni, 'staff_soni', staff_soni)
          order by nom)
        from rr), '[]'::jsonb),
      'amal_royxati', to_jsonb(perm_pages() || array['hodim']),
      'moddalar', coalesce((
        select jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name) order by a.code)
          from accounts a
         where a.type = 'xarajat' and coalesce(a.is_active, true)), '[]'::jsonb)
    )
  );
end
$rbac_royxat$;

revoke all on function rbac_royxat() from public, anon;
grant execute on function rbac_royxat() to authenticated;


-- #####################################################################
-- ##  6-BO'LIM — rbac_role_delete() — rbac_staff_role ham tekshiriladi#
-- #####################################################################
-- 🔴 PROVODKA_RBAC.sql 8.3 dagi tana asosida — eski user_soni tekshiruvi
--    VERBATIM saqlanadi, staff_soni tekshiruvi QO'SHILADI.
create or replace function rbac_role_delete(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $rbac_role_delete$
declare
  v_n  int;
  v_n2 int;
begin
  if not is_admin() then
    raise exception 'Faqat admin rol o''chira oladi' using errcode = '42501';
  end if;

  select count(*) into v_n from rbac_user_role where role_id = p_id;
  if v_n > 0 then
    raise exception 'Bu rolga % ta foydalanuvchi biriktirilgan — avval ularni boshqa rolga o''tkazing', v_n
      using errcode = '23503';
  end if;

  select count(*) into v_n2 from rbac_staff_role where role_id = p_id;
  if v_n2 > 0 then
    raise exception 'Bu rolga % ta hodim biriktirilgan — avval ularni boshqa rolga o''tkazing', v_n2
      using errcode = '23503';
  end if;

  delete from rbac_role where id = p_id;
  if not found then
    raise exception 'Rol topilmadi: %', p_id using errcode = '22023';
  end if;
end
$rbac_role_delete$;

revoke all on function rbac_role_delete(uuid) from public, anon;
grant execute on function rbac_role_delete(uuid) to authenticated;


-- #####################################################################
-- ##  7-BO'LIM — Migratsiya (bir martalik, provodka_config bayrog'i) ##
-- #####################################################################
-- Hamma FAOL aros_staff (rbac_staff_role da qatori yo'q) -> "Standart
-- hodim" roli (PROVODKA_RBAC.sql dagi nom bilan top; rol yo'q bo'lsa
-- xato bilan to'xtaydi). Bir martalik: provodka_config.'rbac_staff_migrated'
-- bayrog'i — qayta RUN qilinsa ikkinchi marta ishlamaydi, shuning uchun
-- SINXRONDA yangi kelgan staff (aros_staff_sync orqali) rolsiz qoladi
-- (FAIL-CLOSED — admin keyin rbac_staff_set() bilan qo'lda beradi).
-- aros_staff_sync() ga TEGILMAYDI.
do $rbac_staff_migrate$
declare
  v_std_role uuid;
  v_flag     text;
  v_staff_id int;
  v_n        int := 0;
begin
  select val into v_flag from provodka_config where key = 'rbac_staff_migrated';
  if v_flag = 'true' then
    raise notice 'RBAC_STAFF migratsiya allaqachon bajarilgan — o''tkazib yuborildi';
    return;
  end if;

  select id into v_std_role from rbac_role where lower(btrim(nom)) = lower('Standart hodim');
  if v_std_role is null then
    raise exception 'Standart hodim roli topilmadi — avval PROVODKA_RBAC.sql RUN qiling';
  end if;

  for v_staff_id in
    select s.staff_id from aros_staff s
     where s.is_active
       and not exists (select 1 from rbac_staff_role sr where sr.staff_id = s.staff_id)
  loop
    insert into rbac_staff_role (staff_id, role_id) values (v_staff_id, v_std_role)
    on conflict do nothing;
    v_n := v_n + 1;
  end loop;

  insert into provodka_config (key, val, updated_at)
  values ('rbac_staff_migrated', 'true', now())
  on conflict (key) do update set val = 'true', updated_at = now();

  raise notice 'RBAC_STAFF migratsiya: % ta hodimga "Standart hodim" roli biriktirildi', v_n;
end
$rbac_staff_migrate$;


-- #####################################################################
-- ##  8-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)            ##
-- #####################################################################

-- 1) Jadval bormi + RLS yoqilgan + yozish policy YO'Q
select to_regclass('public.rbac_staff_role') is not null as rbac_staff_role_ok;

do $rbac_staff_check$
declare
  v_n int;
begin
  if not (select relrowsecurity from pg_class where oid = 'public.rbac_staff_role'::regclass) then
    raise exception 'rbac_staff_role da RLS yoqilmagan';
  end if;

  select count(*) into v_n from pg_policies
   where schemaname = 'public' and tablename = 'rbac_staff_role' and cmd <> 'SELECT';
  if v_n > 0 then
    raise exception 'rbac_staff_role da yozish policy''si bor (% ta) — bo''lmasligi kerak', v_n;
  end if;

  -- 2) Funksiyalar (imzo bo'yicha)
  if to_regprocedure('public.rbac_staff_ovqat(int)') is null then
    raise exception 'rbac_staff_ovqat(int) yaratilmadi';
  end if;
  if to_regprocedure('public.ovqat_ruxsatlar(int[])') is null then
    raise exception 'ovqat_ruxsatlar(int[]) yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_staff_royxat()') is null then
    raise exception 'rbac_staff_royxat() yaratilmadi';
  end if;
  if to_regprocedure('public.rbac_staff_set(int, uuid[])') is null then
    raise exception 'rbac_staff_set(int, uuid[]) yaratilmadi';
  end if;

  -- 3) xarajat_saqlash_ovqat() yangi shoxni bilishimi
  if position('rbac_staff_ovqat' in (select prosrc from pg_proc where proname = 'xarajat_saqlash_ovqat' limit 1)) = 0 then
    raise exception 'xarajat_saqlash_ovqat() ichida rbac_staff_ovqat chaqiruvi yo''q — yangilanmadi';
  end if;

  -- 4) rbac_royxat() / rbac_role_delete() yangilanganmi
  if position('staff_soni' in (select prosrc from pg_proc where proname = 'rbac_royxat' limit 1)) = 0 then
    raise exception 'rbac_royxat() ichida staff_soni yo''q — yangilanmadi';
  end if;
  if position('rbac_staff_role' in (select prosrc from pg_proc where proname = 'rbac_role_delete' limit 1)) = 0 then
    raise exception 'rbac_role_delete() ichida rbac_staff_role tekshiruvi yo''q — yangilanmadi';
  end if;

  -- 5) Grant sanity
  if not has_function_privilege('authenticated', 'public.rbac_staff_set(int, uuid[])', 'execute') then
    raise exception 'rbac_staff_set(int, uuid[]) authenticated uchun yopiq — admin UI ishlamaydi';
  end if;
  if has_function_privilege('anon', 'public.rbac_staff_set(int, uuid[])', 'execute') then
    raise exception 'rbac_staff_set(int, uuid[]) anon uchun ochiq qolgan';
  end if;
  if has_function_privilege('anon', 'public.rbac_staff_ovqat(int)', 'execute') then
    raise exception 'rbac_staff_ovqat(int) anon uchun ochiq qolgan';
  end if;

  raise notice 'RBAC_STAFF tayyor. Hodim-rol bogʻlanishi: % ta', (select count(*) from rbac_staff_role);
end
$rbac_staff_check$;

-- Sxema keshi — busiz yangi RPC 404 beradi.
notify pgrst, 'reload schema';
