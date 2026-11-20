-- ============================================================================
--  PROVODKA_YAXLITLASH_20261120.sql — 2026-11-20 — «YAXLITLASH FARQI» (rounding tolerance)
--
--  NIMA: qarz 45,5 $ bo'lsa kassadan 45 yoki 46 $ beriladi (sent yo'q). Avval: ko'p to'lov `kop` deb rad
--  etilardi, kam to'lov 0,5 $ ni abadiy ochiq qoldirardi. Endi to'lov summasi (qarz valyutasida) qoldiqdan
--  `chegara` gacha KAM yoki KO'P bo'lsa qarz/hujjat TO'LIQ yopiladi; farq alohida avto yozuvga tushadi.
--  Kassadan chiqqan/kirgan pul = foydalanuvchi kiritgan REAL summa, qarz yopilgan summa = qoldiq.
--
--  QAYER:
--   1) Sozlama: jadval `yaxlitlash_chegara` (valyuta pk) + default USD 1, EUR 1, AED 1, CHY 100, UZS 10000.
--      Yordamchi `yaxlitlash_chegara(valyuta)` (yo'q valyuta → 0 = yaxlitlash yo'q), RPC
--      `yaxlitlash_chegara_royxat()` (authenticated), `yaxlitlash_chegara_yoz(valyuta, chegara)` (FAQAT admin).
--      CNY = CHY (bitta yuan, `_yuk_val_norm` ning teskarisi: bu yerda kalit CHY).
--   2) Hisoblar: «Yaxlitlash foydasi» (daromad, 90xx) va «Yaxlitlash xarajati» (xarajat, 94xx) — bo'lmasa ochiladi.
--      Avto yozuv `_yaxlit_yoz`: ext_ref `yaxlit:<asl_entry_id>`, izoh «Yaxlitlash farqi (avto): …»; asl yozuv
--      o'chirilsa avto yozuv (va yuk_yopiq 'yaxlitlash' qatori) ham o'chadi (trigger, kurs farqi naqshi).
--      Tomon QOIDASI (iqtisodiy): biz TO'LAYOTGAN qarzda (qarz_ob «oldik», yuk) kam to'lash = foyda, ko'p = xarajat;
--      biz QABUL QILAYOTGAN qarzda (qarz_ob «berdik», qarz_tolov «Bizdan qarzdor») kam kelishi = xarajat, ko'p = foyda.
--   3) To'lov RPC'lari (IMZO O'ZGARMAGAN, tana oxirgi versiyadan + yaxlitlash bloklari):
--        qarz_ob_tolov(jsonb)   — `kop` chegara bilan yumshaydi, FIFO qoldiqni to'liq yopadi, avto yozuv,
--                                  qarz_ob_tarix 'yaxlitlash_farqi', javob `yaxlitlandi:true, farq`.
--        qarz_tolov(uuid,uuid,numeric,date,text) (Bizdan qarzdor; so'm, chegara UZS) — xuddi shunday
--                                  (qarz_tarix hodisa CHECK'i yopiq — farq 'tolov' data'siga yoziladi).
--        ehson_qarz_tolov(jsonb), ehson_qarz_olish_qaytar(jsonb) — ehson provodka (entry) YO'Q, shuning uchun avto
--                                  yozuv yo'q: qarz yopiladi, farq `ehson_tarix` data'siga `yaxlitlash_farqi` bo'lib yoziladi.
--   4) Yuk (Aros yetkazuvchi hujjati): `yuk_yaxlitlash_yop(p_ext_ref)` — professional-dev saqlashdan KEYIN fonda chaqiradi
--      (entry_yuk_valyuta_yoz'dan keyin). To'lovdan keyin hujjat qoldig'i (yuk valyutasida) ≤ chegara bo'lsa
--      `yuk_yopiq` ga toliq=true, sabab='yaxlitlash' qator (pulsiz yopish; qoldiq 0). Ko'p to'langan bo'lsa (≤ chegara)
--      ortiqcha qism avto yozuv (Dt Yaxlitlash xarajati / Kt to'lov debet hisobi). Kam to'langan yukda ledger yozuvi
--      YO'Q: hujjat qiymati ledgerga kirmagan (faqat to'langan summa 9110 da), shuning uchun yopiq summa faqat yuk_yopiq'da.
--
--  QOIDA (YAXLITLASH, hisobdan chiqarish EMAS): to'lov faqat qoldiqning chegara bo'yicha PASTGA yoki YUQORIGA yaxlitlangan
--  qiymatiga teng bo'lsa yopiladi: floor(qoldi/chegara)*chegara yoki ceil(qoldi/chegara)*chegara (ε=0,009) va qoldi o'zi shu
--  qiymatlardan farq qilsa (`_yaxlit_mos`). 45,5 $ → 45/46 ✓, 47 ✗; 5 $ → faqat 5; 95 500 so'm → 90 000/100 000 ✓, 100 000 ga 90 000 ✗.
--  Chegara 0 / valyuta yo'q → eski xatti-harakat aynan saqlanadi. Chegara tengligi hamma joyda `<=`.
--
--  RUN: Supabase SQL Editor'da BUTUN fayl, bir marta (takror RUN xavfsiz — idempotent, additive, hech narsa o'chirilmaydi).
--       Imzolar o'zgarmagan, jadval/ustun o'chirilmaydi. ROLLBACK: eski funksiya tanalari PROVODKA_QARZ_OB.sql /
--       PROVODKA_QARZ.sql / PROVODKA_EHSON_QARZ.sql / PROVODKA_EHSON_QARZ_OLISH_MANFIY_20261106.sql ni qayta RUN qilish.
--  Frontend (faqat -dev): sozlama-dev («Yaxlitlash chegarasi»), qarzdor-dev, professional-dev, qarz-oldi-berdi-dev, ehson-dev.
-- ============================================================================

-- ######## 1) Sozlama jadvali ########
create table if not exists yaxlitlash_chegara (
  valyuta     text        primary key,
  chegara     numeric     not null check (chegara >= 0),
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);
comment on table yaxlitlash_chegara is
  'Yaxlitlash farqi chegarasi (valyuta birligida): to''lov qoldiqdan shuncha kam/ko''p bo''lsa qarz to''liq yopiladi. '
  'Yozish faqat yaxlitlash_chegara_yoz (admin). Kalit CHY (CNY alias).';

insert into yaxlitlash_chegara (valyuta, chegara) values
  ('USD', 1), ('EUR', 1), ('AED', 1), ('CHY', 100), ('UZS', 10000)
on conflict (valyuta) do nothing;

alter table yaxlitlash_chegara enable row level security;
drop policy if exists yaxlitlash_chegara_sel on yaxlitlash_chegara;
create policy yaxlitlash_chegara_sel on yaxlitlash_chegara for select to authenticated using (true);
revoke all on yaxlitlash_chegara from public, anon;
grant select on yaxlitlash_chegara to authenticated;

create or replace function _yaxlit_val_norm(p_val text)
returns text
language sql
immutable
as $fn$
  select case upper(btrim(coalesce(p_val, '')))
           when 'CNY' then 'CHY' when 'RMB' then 'CHY' when '' then 'UZS'
           else upper(btrim(p_val)) end;
$fn$;

-- yo'q valyuta → 0 (yaxlitlash yo'q)
create or replace function yaxlitlash_chegara(p_valyuta text)
returns numeric
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce((select c.chegara from yaxlitlash_chegara c where c.valyuta = _yaxlit_val_norm(p_valyuta)), 0);
$fn$;
revoke all on function yaxlitlash_chegara(text) from public, anon;
grant execute on function yaxlitlash_chegara(text) to authenticated;

-- To'lov qoldiqni chegara bo'yicha pastga/yuqoriga yaxlitlaganmi (aniq tenglik — yaxlitlash EMAS, eski yo'l)
create or replace function _yaxlit_mos(p_qoldi numeric, p_tolov numeric, p_chegara numeric)
returns boolean
language sql
immutable
as $fn$
  select coalesce(
    p_chegara > 0 and p_tolov > 0 and p_qoldi > 0
    and abs(p_qoldi - p_tolov) > 0.009
    and ( abs(p_tolov - floor(p_qoldi / p_chegara) * p_chegara) <= 0.009
          or abs(p_tolov - ceil(p_qoldi / p_chegara) * p_chegara) <= 0.009 ),
    false);
$fn$;

create or replace function yaxlitlash_chegara_royxat()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'valyuta', c.valyuta, 'chegara', c.chegara, 'updated_at', c.updated_at) order by c.valyuta), '[]'::jsonb)
    from yaxlitlash_chegara c
   where auth.uid() is not null;
$fn$;
revoke all on function yaxlitlash_chegara_royxat() from public, anon;
grant execute on function yaxlitlash_chegara_royxat() to authenticated;

create or replace function yaxlitlash_chegara_yoz(p_valyuta text, p_chegara numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_val text;
  v_max numeric;
begin
  if auth.uid() is null or not coalesce(is_admin(), false) then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Faqat admin');
  end if;
  -- bo'sh/NULL valyuta rad (_yaxlit_val_norm uni UZS ga aylantirib yuborardi)
  if p_valyuta is null or btrim(p_valyuta) = '' then
    return jsonb_build_object('ok', false, 'kod', 'valyuta_notogri', 'error', 'Valyuta kodini yozing');
  end if;
  v_val := _yaxlit_val_norm(p_valyuta);
  if v_val !~ '^[A-Z]{2,8}$' then
    return jsonb_build_object('ok', false, 'kod', 'valyuta_notogri', 'error', 'Valyuta kodi 2–8 harf bo''lishi kerak');
  end if;
  if p_chegara is null or p_chegara in ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric) or p_chegara <= 0 then
    return jsonb_build_object('ok', false, 'kod', 'chegara_notogri', 'error', 'Chegara musbat son bo''lishi kerak');
  end if;
  v_max := case when v_val = 'UZS' then 100000 else 1000 end;
  if p_chegara > v_max then
    return jsonb_build_object('ok', false, 'kod', 'chegara_katta', 'error', 'Chegara juda katta (UZS ≤ 100 000, boshqa valyuta ≤ 1 000)');
  end if;
  insert into yaxlitlash_chegara (valyuta, chegara, updated_at, updated_by)
  values (v_val, p_chegara, now(), auth.uid())
  on conflict (valyuta) do update set chegara = excluded.chegara, updated_at = now(), updated_by = auth.uid();
  return jsonb_build_object('ok', true, 'valyuta', v_val, 'chegara', p_chegara);
end
$fn$;
revoke all on function yaxlitlash_chegara_yoz(text, numeric) from public, anon;
grant execute on function yaxlitlash_chegara_yoz(text, numeric) to authenticated;

-- ######## 2) Hisoblar: Yaxlitlash foydasi (daromad) / Yaxlitlash xarajati (xarajat) ########
-- Kod: sozlama.html avtokod qoidasi — daromad 90xx (max+1, kamida 9011), xarajat 94xx (max+1, kamida 9421).
do $yaxlit_modda$
declare v_id uuid; v_next int;
begin
  select id into v_id from accounts where name = 'Yaxlitlash foydasi' and type = 'daromad' order by created_at limit 1;
  if v_id is null then
    select coalesce(max(a.code::int), 9010) + 1 into v_next from accounts a where a.code ~ '^90[0-9]+$';
    insert into accounts (code, name, type, section, is_active)
    values (v_next::text, 'Yaxlitlash foydasi', 'daromad', 'tushum', true) returning id into v_id;
    raise notice 'Yaxlitlash foydasi OCHILDI: kod % (id=%)', v_next, v_id;
  end if;
  select id into v_id from accounts where name = 'Yaxlitlash xarajati' and type = 'xarajat' order by created_at limit 1;
  if v_id is null then
    select coalesce(max(a.code::int), 9420) + 1 into v_next from accounts a where a.code ~ '^94[0-9]+$';
    insert into accounts (code, name, type, section, is_active)
    values (v_next::text, 'Yaxlitlash xarajati', 'xarajat', 'operatsion', true) returning id into v_id;
    raise notice 'Yaxlitlash xarajati OCHILDI: kod % (id=%)', v_next, v_id;
  end if;
end
$yaxlit_modda$;

-- Balans bo'limi / Cashflow moddasi: «Konvert kurs farqi» qatoridan nusxa (additive, faqat null bo'lsa; ustunlar yo'q bo'lsa — o'tkazib yuboriladi)
do $yaxlit_maydon$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'accounts' and column_name = 'balans_bolimi') then
    update accounts set balans_bolimi = 'daromad' where name = 'Yaxlitlash foydasi' and type = 'daromad' and balans_bolimi is null;
    update accounts set balans_bolimi = 'xarajat' where name = 'Yaxlitlash xarajati' and type = 'xarajat' and balans_bolimi is null;
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'accounts' and column_name = 'cf_modda') then
    execute $q$
      update accounts a set cf_modda = k.cf_modda
        from (select cf_modda from accounts where name = 'Konvert kurs farqi' and type = 'xarajat' and cf_modda is not null order by created_at limit 1) k
       where a.name in ('Yaxlitlash foydasi', 'Yaxlitlash xarajati') and a.cf_modda is null
    $q$;
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'accounts' and column_name = 'faoliyat_turi') then
    execute $q$
      update accounts a set faoliyat_turi = k.faoliyat_turi
        from (select faoliyat_turi from accounts where name = 'Konvert kurs farqi' and type = 'xarajat' and faoliyat_turi is not null order by created_at limit 1) k
       where a.name in ('Yaxlitlash foydasi', 'Yaxlitlash xarajati') and a.faoliyat_turi is null
    $q$;
  end if;
end
$yaxlit_maydon$;

create or replace function yaxlit_foyda_hisob_id()
returns uuid language sql stable security definer set search_path = public
as $fn$ select id from accounts where name = 'Yaxlitlash foydasi' and type = 'daromad' and is_active order by created_at limit 1; $fn$;
revoke all on function yaxlit_foyda_hisob_id() from public, anon;

create or replace function yaxlit_xarajat_hisob_id()
returns uuid language sql stable security definer set search_path = public
as $fn$ select id from accounts where name = 'Yaxlitlash xarajati' and type = 'xarajat' and is_active order by created_at limit 1; $fn$;
revoke all on function yaxlit_xarajat_hisob_id() from public, anon;

-- ######## 3) Avto yozuv: asl to'lov yozuviga bog'langan, bitta (ext_ref yaxlit:<asl>) ########
-- p_hisob_tomon — p_hisob (tozalanayotgan balans hisobi) qaysi tomonda: 'kt' → kredit tomonda farq Dt «Yaxlitlash xarajati»,
-- 'dt' → farq Kt «Yaxlitlash foydasi». Qaytaradi: yozuv id (allaqachon bor bo'lsa — mavjud id, takror yozilmaydi).
create or replace function _yaxlit_yoz(p_asl uuid, p_hisob uuid, p_hisob_tomon text, p_summa numeric, p_izoh text)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  e        record;
  v_ref    text := 'yaxlit:' || p_asl::text;
  v_farq   uuid;
  v_entry  uuid;
begin
  if p_summa is null or p_summa <= 0 then return null; end if;
  select id into v_entry from entry where ext_ref = v_ref and is_deleted = false limit 1;
  if v_entry is not null then return v_entry; end if;

  select entry_date, created_by, filial_ids into e from entry where id = p_asl;
  if not found then raise exception 'Yaxlitlash: asl yozuv topilmadi (%)', p_asl using errcode = '22000'; end if;

  if p_hisob_tomon = 'kt' then v_farq := yaxlit_xarajat_hisob_id();
  elsif p_hisob_tomon = 'dt' then v_farq := yaxlit_foyda_hisob_id();
  else raise exception 'Yaxlitlash: tomon notogri (%)', p_hisob_tomon using errcode = '22000';
  end if;
  if v_farq is null then
    raise exception 'Yaxlitlash: «Yaxlitlash foydasi/xarajati» moddasi topilmadi (PROVODKA_YAXLITLASH_20261120.sql RUN qilinganmi?)' using errcode = '22000';
  end if;

  -- avto_kurs: rbac modda guard va kurs farqi triggeri avto yozuvni o'tkazib yuboradi (faqat shu blok ichida)
  perform set_config('provodka.avto_kurs', '1', true);
  perform set_config('provodka.notify_off', '1', true);
  insert into entry (entry_date, description, source, status, ext_ref, created_by, filial_ids)
  values (e.entry_date, 'Yaxlitlash farqi (avto): ' || coalesce(nullif(btrim(p_izoh), ''), '—'),
          'manual', 'posted', v_ref, e.created_by, coalesce(e.filial_ids, '{}'::uuid[]))
  returning id into v_entry;
  if p_hisob_tomon = 'kt' then
    insert into entry_line (entry_id, account_id, debit, credit) values (v_entry, v_farq, p_summa, 0);
    insert into entry_line (entry_id, account_id, debit, credit) values (v_entry, p_hisob, 0, p_summa);
  else
    insert into entry_line (entry_id, account_id, debit, credit) values (v_entry, p_hisob, p_summa, 0);
    insert into entry_line (entry_id, account_id, debit, credit) values (v_entry, v_farq, 0, p_summa);
  end if;
  perform set_config('provodka.avto_kurs', '', true);
  perform set_config('provodka.notify_off', '', true);
  return v_entry;
end
$fn$;
revoke all on function _yaxlit_yoz(uuid, uuid, text, numeric, text) from public, anon, authenticated;

-- asl to'lov yozuvi o'chirilsa avto yozuv (va yuk_yopiq 'yaxlitlash' qatori) ham o'chadi, tiklansa tiklanadi
create or replace function trg_yaxlit_entry()
returns trigger
language plpgsql
security definer
set search_path = public
as $t$
begin
  if new.is_deleted and not old.is_deleted and coalesce(new.ext_ref, '') not like 'yaxlit:%' then
    update entry set is_deleted = true, deleted_at = now(), deleted_by_name = coalesce(new.deleted_by_name, 'avto')
     where ext_ref = 'yaxlit:' || new.id::text and is_deleted = false;
    if to_regclass('public.yuk_yopiq') is not null then
      update yuk_yopiq set is_deleted = true, deleted_at = now()
       where kalit like 'yaxlit:' || new.id::text || ':%' and is_deleted = false;
    end if;
  elsif not new.is_deleted and old.is_deleted and coalesce(new.ext_ref, '') not like 'yaxlit:%' then
    -- asl yozuv tiklansa avto yozuv ham tiklanadi (kurs farqi triggeri naqshi)
    update entry set is_deleted = false, deleted_at = null, deleted_by_name = null
     where ext_ref = 'yaxlit:' || new.id::text and is_deleted = true;
    if to_regclass('public.yuk_yopiq') is not null then
      update yuk_yopiq set is_deleted = false, deleted_at = null
       where kalit like 'yaxlit:' || new.id::text || ':%' and is_deleted = true;
    end if;
  end if;
  return new;
end
$t$;
drop trigger if exists trg_yaxlit_entry on entry;
create trigger trg_yaxlit_entry
  after update of is_deleted on entry
  for each row execute function trg_yaxlit_entry();


-- ######## 4) qarz_ob_tolov(jsonb) — tana PROVODKA_QARZ_OB.sql dan, yaxlitlash bloklari qo'shilgan (imzo o'zgarmagan) ########
create or replace function qarz_ob_tolov(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid    := auth.uid();
  v_qid     uuid    := nullif(p->>'qarz_id', '')::uuid;
  v_kassa   uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_summa   numeric := nullif(p->>'summa', '')::numeric;
  v_fc      numeric := nullif(p->>'fc_summa', '')::numeric;
  v_sana    date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_izoh    text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_ext     text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  q         qarz_ob;
  v_ka      accounts;
  v_val     text;
  v_birlik  numeric;
  v_asosiy  numeric;
  v_qoldi   numeric;
  v_som     numeric;
  v_oldin   numeric;
  v_rem     numeric;
  v_alloc   numeric;
  jr        record;
  v_tid     uuid := gen_random_uuid();
  v_entry   uuid;
  v_4720    uuid;
  v_6820    uuid;
  v_dt      uuid;
  v_kt      uuid;
  v_all     boolean;
  v_exist   uuid;
  v_chegara numeric;      -- yaxlitlash chegarasi (qarz valyutasida)
  v_yax     boolean := false;
  v_farq    numeric;      -- qoldi - to'landi (qarz valyutasida; musbat = kam to'landi)
  v_farq_som numeric := 0;  -- shu farqning so'm ekvivalenti (musbat = kam)
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Avtorizatsiya kerak'); end if;
  if not qarz_ob_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Qarz oldi-berdi sahifasi ruxsatingizda yoq'); end if;
  if v_ext is not null then
    select id into v_exist from qarz_ob_tolov where ext_ref = v_ext;
    if found then return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist); end if;
  end if;

  select * into q from qarz_ob where id = v_qid for update;
  if not found then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if q.holat <> 'faol' then return jsonb_build_object('ok', false, 'kod', 'holat'); end if;

  -- kassa MAJBURIY (ikkala yo'nalishda ham)
  if v_kassa is null then return jsonb_build_object('ok', false, 'kod', 'kassa_kerak'); end if;
  select * into v_ka from accounts where id = v_kassa;
  if not found or v_ka.is_active is distinct from true then return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi'); end if;
  if v_ka.type <> 'aktiv' or v_ka.code not like '5%' or to_jsonb(v_ka) ->> 'kassa_turi' is not distinct from 'xarajat_guruh' then
    return jsonb_build_object('ok', false, 'kod', 'kassa_emas');
  end if;
  if not perm_check_accounts(array[v_kassa]) then return jsonb_build_object('ok', false, 'kod', 'kassa_ruxsat'); end if;
  v_val := coalesce(v_ka.currency, 'UZS');
  if v_val <> q.valyuta then return jsonb_build_object('ok', false, 'kod', 'valyuta_mos_emas'); end if;

  if q.valyuta = 'UZS' then
    v_fc := null;
    if v_summa is null or v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    v_birlik := v_summa;
  else
    if v_fc is null or v_fc <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    v_birlik := v_fc;
  end if;
  v_asosiy := case when q.valyuta <> 'UZS' then coalesce(q.fc_summa, 0) else q.summa end;

  select coalesce(sum(j.summa - j.tolangan), 0) into v_qoldi from qarz_ob_jadval j where j.qarz_id = q.id;
  -- Yaxlitlash: to'lov qoldiqdan chegaragacha kam/ko'p bo'lsa qarz to'liq yopiladi (to'lov qoldiqni yaxlitlagan bo'lsagina: pastga/yuqoriga)
  v_chegara := yaxlitlash_chegara(q.valyuta);
  v_farq := v_qoldi - v_birlik;
  v_yax := _yaxlit_mos(v_qoldi, v_birlik, v_chegara);
  if v_birlik > v_qoldi + 0.009 and not v_yax then return jsonb_build_object('ok', false, 'kod', 'kop', 'qoldi', v_qoldi); end if;

  -- so'm ekvivalenti: qarz berilgan kurs bo'yicha proporsional; oxirgi (yopuvchi) to'lov qoldiq so'mni oladi
  if q.valyuta = 'UZS' then
    v_som := v_summa;
    if v_yax then v_farq_som := v_farq; end if;
  else
    select coalesce(sum(t.summa), 0) into v_oldin from qarz_ob_tolov t where t.qarz_id = q.id and t.is_deleted = false;
    if v_yax then
      -- yaxlitlash: yozuv REAL summa (qarz kursida), qolgan so'm farq avto yozuvga
      v_som := round(v_birlik * q.summa / v_asosiy);
      v_farq_som := (q.summa - v_oldin) - v_som;
    elsif v_birlik >= v_qoldi - 0.009 then v_som := q.summa - v_oldin;
    else v_som := round(v_birlik * q.summa / v_asosiy); end if;
  end if;
  if v_som <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;

  select id into v_4720 from accounts where code = '4720' and is_active;
  select id into v_6820 from accounts where code = '6820' and is_active;
  if q.yonalish = 'berdik' and v_4720 is null then raise exception '4720 hisobi topilmadi' using errcode = '22000'; end if;
  if q.yonalish = 'oldik' and v_6820 is null then raise exception '6820 hisobi topilmadi' using errcode = '22000'; end if;

  perform pg_advisory_xact_lock(hashtext('qarz_ob_kassa:' || v_kassa::text));
  -- oldik qaytarilganda pul kassadan CHIQADI — qoldiq yetishi shart
  if q.yonalish = 'oldik' then
    if q.valyuta = 'UZS' then
      if sorov_kassa_bal(v_kassa) < v_som then return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi'); end if;
    else
      if acc_fc_balance(v_kassa) < v_fc then return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi'); end if;
    end if;
    v_dt := v_6820; v_kt := v_kassa;
  else
    v_dt := v_kassa; v_kt := v_4720;
  end if;

  insert into entry (entry_date, description, source, status, ext_ref, created_by, filial_ids)
  values (v_sana,
          case when q.yonalish = 'berdik' then 'Qarz qaytarildi: ' else 'Qarz to''landi: ' end || q.kontragent
            || coalesce(' · ' || v_izoh, ''),
          'qarz', 'posted', 'qarz_ob_tolov:' || v_tid::text, v_uid, '{}'::uuid[])
  returning id into v_entry;

  insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
  values (v_entry, v_dt, v_som, 0, case when q.yonalish = 'berdik' and v_val <> 'UZS' then v_fc end);
  insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
  values (v_entry, v_kt, 0, v_som, case when q.yonalish = 'oldik' and v_val <> 'UZS' then v_fc end);

  insert into qarz_ob_tolov (id, qarz_id, kassa_id, valyuta, summa, fc_summa, sana, izoh, entry_id, ext_ref, created_by)
  values (v_tid, q.id, v_kassa, q.valyuta, v_som, v_fc, v_sana, v_izoh, v_entry, v_ext, v_uid);

  -- FIFO — eng eski to'lanmagan qatordan
  v_rem := case when v_yax and v_farq > 0 then v_qoldi else v_birlik end;   -- kam to'langan yaxlitlashda qoldiq to'liq yopiladi
  for jr in select * from qarz_ob_jadval where qarz_id = q.id and tolangan < summa order by n for update loop
    exit when v_rem <= 0;
    v_alloc := least(v_rem, jr.summa - jr.tolangan);
    update qarz_ob_jadval set tolangan = tolangan + v_alloc where id = jr.id;
    v_rem := v_rem - v_alloc;
  end loop;

  select not exists (select 1 from qarz_ob_jadval where qarz_id = q.id and tolangan < summa) into v_all;
  if v_all then
    update qarz_ob set holat = 'yopildi', yopilgan_at = now() where id = q.id;
  end if;

  -- farqning so'm ekvivalenti -> avto yozuv. berdik (pul keladi, 4720): kam = xarajat (Kt 4720), ko'p = foyda (Dt 4720);
  -- oldik (pul ketadi, 6820): kam = foyda (Dt 6820), ko'p = xarajat (Kt 6820)
  if v_yax and abs(v_farq_som) >= 1 then
    perform _yaxlit_yoz(v_entry, case when q.yonalish = 'berdik' then v_4720 else v_6820 end,
                        case when (q.yonalish = 'berdik') = (v_farq_som > 0) then 'kt' else 'dt' end,
                        abs(v_farq_som), q.kontragent || ' · ' || v_birlik::text || ' / ' || v_qoldi::text || ' ' || q.valyuta);
  end if;

  perform _qarz_ob_tarix_yoz(q.id, 'tolov',
    jsonb_build_object('tolov_id', v_tid, 'kassa_id', v_kassa, 'summa', v_som, 'fc_summa', v_fc, 'entry_id', v_entry, 'yopildi', v_all));
  if v_yax then
    perform _qarz_ob_tarix_yoz(q.id, 'yaxlitlash_farqi',
      jsonb_build_object('tolov_id', v_tid, 'farq', v_farq, 'farq_som', v_farq_som, 'valyuta', q.valyuta, 'chegara', v_chegara, 'qoldi', v_qoldi, 'tolandi', v_birlik));
  end if;
  return jsonb_build_object('ok', true, 'id', v_tid, 'entry_id', v_entry, 'holat', case when v_all then 'yopildi' else 'faol' end,
                            'qoldi', case when v_yax then 0 else greatest(v_qoldi - v_birlik, 0) end)
         || case when v_yax then jsonb_build_object('yaxlitlandi', true, 'farq', v_farq) else '{}'::jsonb end;
exception
  when unique_violation then
    select id into v_exist from qarz_ob_tolov where ext_ref = v_ext;
    if v_exist is not null then return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist); end if;
    raise;
end
$fn$;
revoke all on function qarz_ob_tolov(jsonb) from public, anon;
grant execute on function qarz_ob_tolov(jsonb) to authenticated;

-- ######## 5) qarz_tolov(uuid,uuid,numeric,date,text) — «Bizdan qarzdor»; tana PROVODKA_QARZ.sql dan + yaxlitlash ########
create or replace function qarz_tolov(p_qarz uuid, p_kassa uuid, p_summa numeric,
                                       p_sana date default null, p_izoh text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid      uuid := auth.uid();
  q          qarz;
  v_qd       qarzdor;
  v_ka       accounts;
  v_debtor   uuid;
  v_entry    uuid;
  v_tolov_id uuid := gen_random_uuid();
  v_sana     date := coalesce(p_sana, (now() at time zone 'Asia/Tashkent')::date);
  v_izoh     text := nullif(btrim(coalesce(p_izoh, '')), '');
  v_qolgan   numeric;
  v_remaining numeric;
  v_alloc    numeric;
  jr         record;
  v_holat    text;
  v_all_paid boolean;
  v_chegara  numeric;      -- yaxlitlash chegarasi (so'm)
  v_yax      boolean := false;
  v_farq     numeric;      -- qolgan - to'landi (musbat = kam to'landi)
begin
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('qarzdor') then
    raise exception 'Qarzdor sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;
  if p_summa is null or p_summa <= 0 then
    raise exception 'Summa musbat bolishi kerak' using errcode = '22000';
  end if;

  select * into q from qarz where id = p_qarz for update;
  if not found then
    raise exception 'Qarz topilmadi' using errcode = '22000';
  end if;
  if q.status <> 'faol' then
    return jsonb_build_object('ok', false, 'kod', 'faol_emas', 'status', q.status);
  end if;

  select * into v_ka from accounts where id = p_kassa;
  if not found or v_ka.is_active is distinct from true then
    raise exception 'Kassa topilmadi yoki faol emas' using errcode = '22000';
  end if;
  if v_ka.type <> 'aktiv' or v_ka.code not like '5%'
     or v_ka.kassa_turi is not distinct from 'xarajat_guruh' then
    raise exception 'Bu hisob kassa emas' using errcode = '22000';
  end if;
  if not perm_check_accounts(array[p_kassa]) then
    raise exception 'Ruxsat yoq: bu kassada amaliyot qilish huquqingiz yoq' using errcode = '42501';
  end if;

  select (q.summa - coalesce(sum(jr2.tolangan), 0)) into v_qolgan
    from qarz_jadval jr2 where jr2.qarz_id = q.id;
  v_qolgan := coalesce(v_qolgan, q.summa);

  -- Yaxlitlash: qoldiqdan chegaragacha kam/ko'p to'lov qarzni to'liq yopadi (to'lov qoldiqni yaxlitlagan bo'lsagina: pastga/yuqoriga)
  v_chegara := yaxlitlash_chegara('UZS');
  v_farq := v_qolgan - p_summa;
  v_yax := _yaxlit_mos(v_qolgan, p_summa, v_chegara);
  if p_summa > v_qolgan and not v_yax then
    return jsonb_build_object('ok', false, 'kod', 'ortiqcha', 'qolgan', v_qolgan);
  end if;

  select * into v_qd from qarzdor where id = q.qarzdor_id;
  v_debtor := qarz_debtor_account(v_qd.tur);
  if v_debtor is null then
    raise exception 'Qarz hisobi (4710/4720) topilmadi' using errcode = '22000';
  end if;

  insert into entry (entry_date, description, source, status, ext_ref, created_by, filial_ids)
  values (v_sana,
          'Qarz qaytarildi: ' || v_qd.ism || ' ' || v_qd.familya,
          'qarz',
          'posted',
          'qarz_tolov:' || v_tolov_id::text,
          v_uid,
          '{}'::uuid[])
  returning id into v_entry;

  insert into entry_line (entry_id, account_id, debit, credit)
  values (v_entry, p_kassa,  p_summa, 0),
         (v_entry, v_debtor, 0,       p_summa);

  -- pul keladi (qarzdor 4710/4720): kam = xarajat (Kt qarz hisobi), ko'p = foyda (Dt qarz hisobi)
  if v_yax then
    perform _yaxlit_yoz(v_entry, v_debtor, case when v_farq > 0 then 'kt' else 'dt' end, abs(v_farq),
                        v_qd.ism || ' ' || v_qd.familya || ' · ' || p_summa::text || ' / ' || v_qolgan::text);
  end if;

  insert into qarz_tolov (id, qarz_id, kassa_id, summa, sana, izoh, entry_id, ext_ref, created_by)
  values (v_tolov_id, q.id, p_kassa, p_summa, v_sana, v_izoh, v_entry,
          'qarz_tolov:' || v_tolov_id::text, v_uid);

  -- FIFO taqsimot — eng eski tolanmagan qatordan boshlab
  v_remaining := case when v_yax and v_farq > 0 then v_qolgan else p_summa end;   -- kam to'langan yaxlitlashda qoldiq to'liq yopiladi
  for jr in
    select * from qarz_jadval
     where qarz_id = q.id and tolangan < summa
     order by n
     for update
  loop
    exit when v_remaining <= 0;
    v_alloc := least(v_remaining, jr.summa - jr.tolangan);
    update qarz_jadval set tolangan = tolangan + v_alloc where id = jr.id;
    v_remaining := v_remaining - v_alloc;
  end loop;

  select not exists (
    select 1 from qarz_jadval where qarz_id = q.id and tolangan < summa
  ) into v_all_paid;

  if v_all_paid then
    update qarz set status = 'yopildi', yopilgan_at = now() where id = q.id;
    v_holat := 'yopildi';
  else
    v_holat := 'faol';
  end if;

  insert into qarz_tarix (qarz_id, hodisa, data, kim)
  values (q.id, 'tolov',
          jsonb_build_object('tolov_id', v_tolov_id, 'summa', p_summa, 'qolgan_keyin', case when v_yax then 0 else v_qolgan - p_summa end)
            || case when v_yax then jsonb_build_object('yaxlitlash_farqi', v_farq, 'chegara', v_chegara) else '{}'::jsonb end,
          v_uid);

  if v_holat = 'yopildi' then
    insert into qarz_tarix (qarz_id, hodisa, data, kim)
    values (q.id, 'yopildi', jsonb_build_object('tolov_id', v_tolov_id), v_uid);
  end if;

  perform qarz_notify_qoy(q.id, v_tolov_id, 'tolov');
  if v_holat = 'yopildi' then
    perform qarz_notify_qoy(q.id, v_tolov_id, 'yopildi');
  end if;

  return jsonb_build_object('ok', true, 'tolov_id', v_tolov_id,
                             'qolgan_keyin', case when v_yax then 0 else v_qolgan - p_summa end, 'status', v_holat)
         || case when v_yax then jsonb_build_object('yaxlitlandi', true, 'farq', v_farq) else '{}'::jsonb end;

exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'kod', 'takror');
end $fn$;

revoke all on function qarz_tolov(uuid, uuid, numeric, date, text) from public, anon;
grant execute on function qarz_tolov(uuid, uuid, numeric, date, text) to authenticated;

-- ######## 6) ehson_qarz_tolov(jsonb) — tana PROVODKA_EHSON_QARZ.sql dan + yaxlitlash (provodka yo'q) ########
create or replace function ehson_qarz_tolov(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid    := auth.uid();
  v_qid     uuid    := nullif(p->>'qarz_id', '')::uuid;
  v_kassa   uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_pt_p    text    := nullif(p->>'pul_turi', '');
  v_summa   numeric := nullif(p->>'summa', '')::numeric;
  v_fc_p    numeric := nullif(p->>'fc_summa', '')::numeric;
  v_sana    date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_izoh    text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_ext     text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  q         ehson_qarz;
  v_pt      ehson_pul_turi;
  v_pt_cnt  int;
  v_pt_val  text;
  v_kurs    numeric;
  v_birlik  numeric;
  v_qoldi   numeric;
  v_rem     numeric;
  v_alloc   numeric;
  jr        record;
  v_id      uuid;
  v_exist   uuid;
  v_all     boolean;
  v_chegara numeric;      -- yaxlitlash chegarasi (qarz valyutasida)
  v_yax     boolean := false;
  v_farq    numeric;      -- qoldi - to'landi (musbat = kam to'landi)
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Avtorizatsiya kerak'); end if;
  if not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Ehson sahifasi ruxsatingizda yoq'); end if;
  if v_ext is not null then
    select id into v_exist from ehson_qarz_tolov where ext_ref = v_ext;
    if found then return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist); end if;
  end if;

  select * into q from ehson_qarz where id = v_qid for update;
  if not found then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if q.holat <> 'faol' then return jsonb_build_object('ok', false, 'kod', 'holat'); end if;

  v_kassa := coalesce(v_kassa, q.kassa_id);
  if not exists (select 1 from ehson_kassa where id = v_kassa and is_active and not is_container) then
    return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi');
  end if;
  v_pt_p := coalesce(v_pt_p, case when v_kassa = q.kassa_id then q.pul_turi end);

  select count(*) into v_pt_cnt from ehson_pul_turi where kassa_id = v_kassa and is_active;
  if v_pt_cnt > 0 then
    if v_pt_p is null then return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak'); end if;
    select * into v_pt from ehson_pul_turi where kassa_id = v_kassa and kod = v_pt_p and is_active;
    if not found then return jsonb_build_object('ok', false, 'kod', 'pul_turi_topilmadi'); end if;
    v_pt_val := coalesce(v_pt.valyuta, 'UZS');
  else
    v_pt_p := null; v_pt_val := 'UZS';
  end if;
  if v_pt_val <> q.valyuta then return jsonb_build_object('ok', false, 'kod', 'valyuta_mos_emas'); end if;

  if q.valyuta = 'USD' then
    if v_fc_p is null or v_fc_p <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    v_kurs := null;
    if exists (select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
                where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs' and oidvectortypes(pr.proargtypes) = 'text') then
      execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
    end if;
    if v_kurs is null or v_kurs <= 0 then return jsonb_build_object('ok', false, 'kod', 'kurs_yoq'); end if;
    v_summa := round(v_fc_p * v_kurs);
    v_birlik := v_fc_p;
  else
    v_fc_p := null;
    if v_summa is null or v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    v_birlik := v_summa;
  end if;

  select coalesce(sum(j.summa - j.tolangan), 0) into v_qoldi from ehson_qarz_jadval j where j.qarz_id = q.id;
  -- Yaxlitlash: chegaragacha kam/ko'p to'lov qarzni to'liq yopadi (provodka yo'q — farq ehson_tarix'da)
  v_chegara := yaxlitlash_chegara(q.valyuta);
  v_farq := v_qoldi - v_birlik;
  v_yax := _yaxlit_mos(v_qoldi, v_birlik, v_chegara);
  if v_birlik > v_qoldi + 0.009 and not v_yax then
    return jsonb_build_object('ok', false, 'kod', 'kop', 'qoldi', v_qoldi);
  end if;

  insert into ehson_qarz_tolov (qarz_id, kassa_id, pul_turi, valyuta, summa, fc_summa, sana, izoh, ext_ref, created_by)
  values (q.id, v_kassa, v_pt_p, q.valyuta, v_summa, v_fc_p, v_sana, v_izoh, v_ext, v_uid)
  returning id into v_id;

  -- FIFO — eng eski to'lanmagan qatordan
  v_rem := case when v_yax and v_farq > 0 then v_qoldi else v_birlik end;   -- kam to'langan yaxlitlashda qoldiq to'liq yopiladi
  for jr in select * from ehson_qarz_jadval where qarz_id = q.id and tolangan < summa order by n for update loop
    exit when v_rem <= 0;
    v_alloc := least(v_rem, jr.summa - jr.tolangan);
    update ehson_qarz_jadval set tolangan = tolangan + v_alloc where id = jr.id;
    v_rem := v_rem - v_alloc;
  end loop;

  select not exists (select 1 from ehson_qarz_jadval where qarz_id = q.id and tolangan < summa) into v_all;
  if v_all then
    update ehson_qarz set holat = 'yopildi', yopilgan_at = now() where id = q.id;
  end if;

  perform _ehson_tarix_yoz('qarz_tolov', v_id, 'tolov',
    jsonb_build_object('qarz_id', q.id, 'kassa_id', v_kassa, 'pul_turi', v_pt_p, 'summa', v_summa, 'fc_summa', v_fc_p, 'yopildi', v_all)
      || case when v_yax then jsonb_build_object('yaxlitlash_farqi', v_farq, 'chegara', v_chegara, 'valyuta', q.valyuta) else '{}'::jsonb end);
  return jsonb_build_object('ok', true, 'id', v_id, 'holat', case when v_all then 'yopildi' else 'faol' end,
                            'qoldi', case when v_yax then 0 else greatest(v_qoldi - v_birlik, 0) end)
         || case when v_yax then jsonb_build_object('yaxlitlandi', true, 'farq', v_farq) else '{}'::jsonb end;
exception
  when unique_violation then
    select id into v_exist from ehson_qarz_tolov where ext_ref = v_ext;
    return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;
revoke all on function ehson_qarz_tolov(jsonb) from public, anon;
grant execute on function ehson_qarz_tolov(jsonb) to authenticated;

-- ######## 7) ehson_qarz_olish_qaytar(jsonb) — tana PROVODKA_EHSON_QARZ_OLISH_MANFIY_20261106.sql dan + yaxlitlash ########
create or replace function ehson_qarz_olish_qaytar(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid    := auth.uid();
  v_qid     uuid    := nullif(p->>'olingan_id', '')::uuid;
  v_kassa   uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_pt_p    text    := nullif(p->>'pul_turi', '');
  v_summa   numeric := nullif(p->>'summa', '')::numeric;
  v_fc_p    numeric := nullif(p->>'fc_summa', '')::numeric;
  v_sana    date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_izoh    text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_ext     text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  q         ehson_qarz_olingan;
  v_pt      ehson_pul_turi;
  v_pt_cnt  int;
  v_pt_val  text;
  v_kurs    numeric;
  v_birlik  numeric;
  v_asosiy  numeric;
  v_qaytdi  numeric;
  v_qoldi   numeric;
  v_id      uuid;
  v_exist   uuid;
  v_all     boolean;
  v_chegara numeric;      -- yaxlitlash chegarasi (qarz valyutasida)
  v_yax     boolean := false;
  v_farq    numeric;      -- qoldi - qaytarildi (musbat = kam)
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Avtorizatsiya kerak'); end if;
  if not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Ehson sahifasi ruxsatingizda yoq'); end if;
  if v_ext is not null then
    select id into v_exist from ehson_qarz_olingan_tolov where ext_ref = v_ext;
    if found then return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist); end if;
  end if;

  select * into q from ehson_qarz_olingan where id = v_qid for update;
  if not found then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if q.holat <> 'faol' then return jsonb_build_object('ok', false, 'kod', 'holat'); end if;

  v_kassa := coalesce(v_kassa, q.kassa_id);
  if not exists (select 1 from ehson_kassa where id = v_kassa and is_active and not is_container) then
    return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi');
  end if;
  v_pt_p := coalesce(v_pt_p, case when v_kassa = q.kassa_id then q.pul_turi end);

  select count(*) into v_pt_cnt from ehson_pul_turi where kassa_id = v_kassa and is_active;
  if v_pt_cnt > 0 then
    if v_pt_p is null then return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak'); end if;
    select * into v_pt from ehson_pul_turi where kassa_id = v_kassa and kod = v_pt_p and is_active;
    if not found then return jsonb_build_object('ok', false, 'kod', 'pul_turi_topilmadi'); end if;
    v_pt_val := coalesce(v_pt.valyuta, 'UZS');
  else
    v_pt_p := null; v_pt_val := 'UZS';
  end if;
  if v_pt_val <> q.valyuta then return jsonb_build_object('ok', false, 'kod', 'valyuta_mos_emas'); end if;

  if q.valyuta = 'USD' then
    if v_fc_p is null or v_fc_p <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    v_kurs := null;
    if exists (select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
                where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs' and oidvectortypes(pr.proargtypes) = 'text') then
      execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
    end if;
    if v_kurs is null or v_kurs <= 0 then return jsonb_build_object('ok', false, 'kod', 'kurs_yoq'); end if;
    v_summa := round(v_fc_p * v_kurs);
    v_birlik := v_fc_p;
  else
    v_fc_p := null;
    if v_summa is null or v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    v_birlik := v_summa;
  end if;

  v_asosiy := case when q.valyuta = 'USD' then coalesce(q.fc_summa, 0) else q.summa end;
  select coalesce(sum(case when q.valyuta = 'USD' then coalesce(t.fc_summa, 0) else t.summa end), 0) into v_qaytdi
    from ehson_qarz_olingan_tolov t where t.olingan_id = q.id and t.is_deleted = false;
  v_qoldi := v_asosiy - v_qaytdi;
  -- Yaxlitlash: chegaragacha kam/ko'p qaytarish qarzni to'liq yopadi (provodka yo'q — farq ehson_tarix'da)
  v_chegara := yaxlitlash_chegara(q.valyuta);
  v_farq := v_qoldi - v_birlik;
  v_yax := _yaxlit_mos(v_qoldi, v_birlik, v_chegara);
  if v_birlik > v_qoldi + 0.009 and not v_yax then
    return jsonb_build_object('ok', false, 'kod', 'kop', 'qoldi', v_qoldi);
  end if;

  insert into ehson_qarz_olingan_tolov (olingan_id, kassa_id, pul_turi, valyuta, summa, fc_summa, sana, izoh, ext_ref, created_by)
  values (q.id, v_kassa, v_pt_p, q.valyuta, v_summa, v_fc_p, v_sana, v_izoh, v_ext, v_uid)
  returning id into v_id;

  v_all := (v_qoldi - v_birlik) <= 0.009 or v_yax;
  if v_all then
    update ehson_qarz_olingan set holat = 'yopildi', yopilgan_at = now() where id = q.id;
  end if;

  perform _ehson_tarix_yoz('qarz_olingan_tolov', v_id, 'tolov',
    jsonb_build_object('olingan_id', q.id, 'kassa_id', v_kassa, 'pul_turi', v_pt_p, 'summa', v_summa, 'fc_summa', v_fc_p, 'yopildi', v_all)
      || case when v_yax then jsonb_build_object('yaxlitlash_farqi', v_farq, 'chegara', v_chegara, 'valyuta', q.valyuta) else '{}'::jsonb end);
  return jsonb_build_object('ok', true, 'id', v_id, 'holat', case when v_all then 'yopildi' else 'faol' end,
                            'qoldi', case when v_yax then 0 else greatest(v_qoldi - v_birlik, 0) end)
         || case when v_yax then jsonb_build_object('yaxlitlandi', true, 'farq', v_farq) else '{}'::jsonb end;
exception
  when unique_violation then
    select id into v_exist from ehson_qarz_olingan_tolov where ext_ref = v_ext;
    return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;
revoke all on function ehson_qarz_olish_qaytar(jsonb) from public, anon;
grant execute on function ehson_qarz_olish_qaytar(jsonb) to authenticated;
-- ######## 8) Yuk: yuk_yaxlitlash_yop(p_ext_ref) — to'lovdan KEYIN fonda (entry_yuk_valyuta_yoz naqshi) ########
-- Har entry_yuk qatori uchun: qoldiq (yuk valyutasida) = narx (aros_yuk_snapshot) + tannarx/kurs − tolangan_fc.
--   0 < qoldiq <= chegara  → yuk_yopiq (toliq=true, sabab='yaxlitlash', pulsiz) → qarzdor/aylanmada qoldiq 0;
--   −chegara <= qoldiq < 0 → ortiqcha to'langan: avto yozuv Dt Yaxlitlash xarajati / Kt to'lov debet hisobi.
-- Faqat to'lov to'lovdan oldingi qoldiqni chegara bo'yicha pastga/yuqoriga yaxlitlagan bo'lsagina (_yaxlit_mos): qisman to'lov hujjatni yopmaydi. Idempotent
-- (yuk_yopiq.kalit unique; avto yozuv ext_ref yaxlit:<entry>). Egalik: yozuv egasi yoki admin, 30 daqiqa.
create or replace function yuk_yaxlitlash_yop(p_ext_ref text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid       uuid := auth.uid();
  v_ext       text := nullif(btrim(coalesce(p_ext_ref, '')), '');
  v_id        uuid;
  v_created   timestamptz;
  v_owner_raw text;
  v_owner     uuid;
  v_status    text;
  v_del       boolean;
  v_kim       text;
  ey          record;
  s           record;
  v_kurs      numeric;
  v_tan_uzs   numeric;
  v_jami      numeric;
  v_tol       jsonb;
  v_tol_fc    numeric;
  v_qoldi     numeric;
  v_chegara   numeric;
  v_pay_fc    numeric;
  v_grp       uuid;
  v_n         integer := 0;
  v_ort_uzs   numeric := 0;
  v_dt_acc    uuid;
  v_izoh      text := '';
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if v_ext is null then
    return jsonb_build_object('ok', false, 'kod', 'ext_ref_kerak');
  end if;

  select e.id, e.created_at, (to_jsonb(e) ->> 'created_by'), e.status, e.is_deleted
    into v_id, v_created, v_owner_raw, v_status, v_del
    from entry e where e.ext_ref = v_ext limit 1;
  if v_id is null then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if v_del or v_status is distinct from 'posted' then return jsonb_build_object('ok', false, 'kod', 'holat'); end if;
  v_owner := case when v_owner_raw ~ '^[0-9a-fA-F-]{36}$' then v_owner_raw::uuid end;
  if v_owner is distinct from v_uid and not coalesce(is_admin(), false) then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat_yoq');
  end if;
  if v_created is null or v_created < now() - interval '30 minutes' then
    return jsonb_build_object('ok', false, 'kod', 'muddat_tugagan');
  end if;

  select coalesce(full_name, '') into v_kim from profiles where id = v_uid;

  for ey in select yuk_id, summa_uzs, summa_fc, kurs from entry_yuk where entry_id = v_id loop
    select narx, valyuta into s from aros_yuk_snapshot where yuk_id = ey.yuk_id;
    if not found or s.narx is null then continue; end if;       -- Aros surati yo'q — yopilmaydi (klient eski qoida bilan ko'rsatadi)

    v_chegara := yaxlitlash_chegara(s.valyuta);
    if v_chegara <= 0 then continue; end if;
    v_kurs := _yuk_kurs_sanada(s.valyuta, now()::date);          -- yuk_tolangan_fc yopiqni created_at::date kursi bilan o'giradi — shu bilan bir xil
    if v_kurs is null or v_kurs <= 0 then continue; end if;

    select coalesce((yuk_tannarx_jami(array[ey.yuk_id]) -> ey.yuk_id::text ->> 'jami_uzs')::numeric, 0) into v_tan_uzs;
    v_jami := s.narx + v_tan_uzs / v_kurs;
    v_tol := yuk_tolangan_fc(jsonb_build_array(jsonb_build_object('id', ey.yuk_id, 'valyuta', s.valyuta))) -> 0;
    v_tol_fc := coalesce((v_tol ->> 'tolangan_fc')::numeric, (v_tol ->> 'tolangan_uzs')::numeric / v_kurs, 0);
    v_qoldi := v_jami - v_tol_fc;
    v_pay_fc := coalesce(ey.summa_fc, ey.summa_uzs / nullif(coalesce(ey.kurs, v_kurs), 0), 0);
    if not _yaxlit_mos(v_qoldi + v_pay_fc, v_pay_fc, v_chegara) then continue; end if;   -- to'lov to'lovdan OLDINGI qoldiqni pastga/yuqoriga yaxlitlagan bo'lishi shart

    if v_qoldi > 0.005 and v_qoldi <= v_chegara then
      insert into yuk_yopiq (yuk_id, summa_uzs, toliq, sabab, kalit, created_by_name)
      values (ey.yuk_id, round(v_qoldi * v_kurs, 2), true, 'yaxlitlash', 'yaxlit:' || v_id::text || ':' || ey.yuk_id, v_kim)
      on conflict (kalit) do nothing;
      if found then
        v_n := v_n + 1;
        -- grafik/muddat: yuk_yopish_toplam bilan bir xil (guruhda bo'lsa tegilmaydi)
        select gy.guruh_id into v_grp from yuk_grafik_guruh_yuk gy where gy.yuk_id = ey.yuk_id limit 1;
        if v_grp is null then
          delete from yuk_tolov_grafik where yuk_id = ey.yuk_id and guruh_id is null;
          update yuk_deadline set deadline = null, updated_at = now() where yuk_id = ey.yuk_id;
        end if;
      end if;
    elsif v_qoldi < -0.005 and -v_qoldi <= v_chegara then
      v_ort_uzs := v_ort_uzs + round(-v_qoldi * v_kurs);
      v_izoh := v_izoh || case when v_izoh = '' then '' else ', ' end || '#' || ey.yuk_id || ' ' || round(-v_qoldi, 2)::text || ' ' || s.valyuta;
    end if;
  end loop;

  if v_ort_uzs >= 1 then
    -- ortiqcha to'langan qism: to'lov yozuvining eng katta debet hisobi (yuk/tovar) kreditlanadi
    select l.account_id into v_dt_acc from entry_line l where l.entry_id = v_id and l.debit > 0 order by l.debit desc limit 1;
    if v_dt_acc is not null then
      perform _yaxlit_yoz(v_id, v_dt_acc, 'kt', v_ort_uzs, 'yuk ortiqcha to''lov ' || v_izoh);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'yopildi', v_n, 'ortiqcha_uzs', v_ort_uzs);
end
$fn$;
revoke all on function yuk_yaxlitlash_yop(text) from public, anon;
grant execute on function yuk_yaxlitlash_yop(text) to authenticated;
comment on function yuk_yaxlitlash_yop(text) is
  'Yuk to''lovi saqlangach fonda: qoldiq ≤ yaxlitlash chegarasi bo''lsa yuk_yopiq (sabab=yaxlitlash), ortiqcha to''langan '
  'qism bo''lsa avto yozuv. Egalik created_by=auth.uid() yoki admin, 30 daqiqa. ENG OXIRGI: PROVODKA_YAXLITLASH_20261120.sql';

-- ######## TEKSHIRUV ########
select 'yaxlitlash_chegara qatorlari' as obyekt, (select count(*) from yaxlitlash_chegara)::text as holat
union all select 'Yaxlitlash foydasi', coalesce((select code from accounts where id = yaxlit_foyda_hisob_id()), '❌')
union all select 'Yaxlitlash xarajati', coalesce((select code from accounts where id = yaxlit_xarajat_hisob_id()), '❌')
union all select 'trg_yaxlit_entry', (select count(*) from pg_trigger where tgname = 'trg_yaxlit_entry')::text
union all select 'yuk_yaxlitlash_yop', case when to_regprocedure('public.yuk_yaxlitlash_yop(text)') is not null then '✅' else '❌' end
union all select 'qarz_ob_tolov (yaxlitlash)', case when pg_get_functiondef('public.qarz_ob_tolov(jsonb)'::regprocedure) like '%yaxlit%' then '✅' else '❌' end
union all select 'qarz_tolov (yaxlitlash)', case when pg_get_functiondef('public.qarz_tolov(uuid,uuid,numeric,date,text)'::regprocedure) like '%yaxlit%' then '✅' else '❌' end
union all select 'ehson_qarz_tolov (yaxlitlash)', case when pg_get_functiondef('public.ehson_qarz_tolov(jsonb)'::regprocedure) like '%yaxlit%' then '✅' else '❌' end
union all select 'ehson_qarz_olish_qaytar (yaxlitlash)', case when pg_get_functiondef('public.ehson_qarz_olish_qaytar(jsonb)'::regprocedure) like '%yaxlit%' then '✅' else '❌' end;
