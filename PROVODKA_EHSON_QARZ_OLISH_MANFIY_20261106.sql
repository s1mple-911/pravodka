-- =====================================================================================================================
--  PROVODKA_EHSON_QARZ_OLISH_MANFIY_20261106.sql  (2026-11-06, Asilbek; faqat DEV, ADDITIVE, idempotent — Asilbek RUN qiladi)
--
--  Asilbek: «Ehson bo'limida qarz OLISH ham bo'lsin (jamg'arma kimdandir qarz oladi, pul ehson kassasiga KIRADI;
--  kimdan va izoh majburiy); ehson kassalari manfiyda ham yursin».
--
--  1) QARZ OLISH — ALOHIDA jadvallar (ehson_qarz.yonalish ustuni EMAS):
--       ehson_qarz_olingan        — olingan qarz (kassa + pul turi, kimdan = shaxs ism/telefon, izoh, ixtiyoriy muddat, holat faol|yopildi|bekor)
--       ehson_qarz_olingan_tolov  — qaytarish (pul ehson kassasidan qarz beruvchiga CHIQADI)
--     Sabab: ehson_qarz va uning hisoblari (v_ehson_kassa_pul, ehson_qarz_royxat, ehson_qarz_guruh_royxat/_tolov, kechikkan,
--     Excel, ehson_qarz_muddat_set) hammasi «berilgan qarz» deb faraz qiladi. Ustun qo'shilsa har birini filtrlash kerak edi —
--     mavjud «qarz berish» mantiqi o'zgarmasligi shart. Alohida jadval = berish tomoni BAYT-BAYT o'zgarmaydi.
--     Grafik (jadval) YO'Q: qarz olishda muddat ixtiyoriy (bitta sana), qoldiq = olingan − qaytarilgan.
--  2) v_ehson_kassa_pul / v_ehson_kassa: qoldiq += qarz_olindi − qarz_olingan_qaytdi. Yangi ustunlar OXIRIGA, eskilari tegilmagan.
--     🔴 Bu ikki view'ning ENG OXIRGI versiyasi endi SHU faylda. USD_QOLDIQ / KONVERT_QARZ_GURUH / TRANSFER / QARZ / ZAKOT
--     fayllari qayta RUN qilinsa — shu faylni ham qayta RUN qiling (ular view'ni eski ko'rinishga qaytaradi).
--  3) MANFIY QOLDIQ: ehson ichida qoldiq tekshiruvi OLIB TASHLANDI (faqat ehson kassalari — bu RPC'lar faqat ehson_* jadvallarida
--     ishlaydi): ehson_ber (qoldiq_yetmadi), ehson_qarz_ber (qoldiq_yetmadi), ehson_transfer_yoz / ehson_konvert_yoz
--     (qoldiq_yetmaydi), ehson_transfer_bekor (qoldiq_manfiy). Funksiya tanalari oxirgi versiyadan VERBATIM, faqat shu bloklar
--     izohga almashtirilgan; imzolar o'zgarmagan. Kompaniya bal_guard (PROVODKA_BAL_GUARD_VALYUTA.sql) ehson kassalariga
--     TEGISHLI EMAS: u entry_line/accounts da kassa_turi in (xarajat, markaziy) hisoblarni tekshiradi, ehson balansi esa
--     entry/accounts da yozilmaydi (faqat ehson_* jadvallari). Shuning uchun bal_guard tegilmadi.
--  4) ehson_dash O'ZGARMADI: kassalar[].qoldiq view orqali olingan qarzni o'z ichiga oladi; olingan qarz yig'indisi
--     ehson_qarz_olish_royxat().stat da (UI dash kartasi shundan oladi).
--
--  RPC: ehson_qarz_olish(p) · ehson_qarz_olish_qaytar(p) · ehson_qarz_olish_bekor(id, sabab) · ehson_qarz_olish_royxat(p)
--  Ruxsat: ehson_page_ok() (Ehson sahifasi) — bekor faqat admin yoki yaratgan (ehson_qarz_bekor naqshi).
--  Old shart: PROVODKA_EHSON_USD_QOLDIQ.sql (v_ehson_kassa_pul eng oxirgi) + KONVERT_QARZ_GURUH + TRANSFER + QARZ + ZAKOT.
-- =====================================================================================================================

-- ######## 0) OLD SHART ########
do $eho_pre$
begin
  if to_regclass('public.ehson_qarz') is null then raise exception 'Old shart: avval PROVODKA_EHSON_QARZ.sql'; end if;
  if to_regclass('public.ehson_transfer') is null then raise exception 'Old shart: avval PROVODKA_EHSON_TRANSFER.sql'; end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'ehson_transfer' and column_name = 'to_fc_summa') then
    raise exception 'Old shart: avval PROVODKA_EHSON_KONVERT_QARZ_GURUH.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'v_ehson_kassa_pul' and column_name = 'kurs_yoq') then
    raise exception 'Old shart: avval PROVODKA_EHSON_USD_QOLDIQ.sql (v_ehson_kassa_pul.kurs_yoq)';
  end if;
  if to_regprocedure('public._ehson_kurs_usd_ich()') is null then raise exception 'Old shart: _ehson_kurs_usd_ich() yoq (PROVODKA_EHSON_USD_QOLDIQ.sql)'; end if;
  if to_regprocedure('public.ehson_page_ok()') is null then raise exception 'ehson_page_ok() yoq'; end if;
  if to_regprocedure('public._ehson_is_admin()') is null then raise exception '_ehson_is_admin() yoq'; end if;
  if to_regprocedure('public._ehson_tarix_yoz(text,uuid,text,jsonb)') is null then raise exception '_ehson_tarix_yoz yoq'; end if;
end
$eho_pre$;

-- ######## 1) JADVALLAR ########
create table if not exists ehson_qarz_olingan (
  id           uuid        primary key default gen_random_uuid(),
  kassa_id     uuid        not null references ehson_kassa(id),          -- pul KIRGAN ehson kassa
  pul_turi     text,
  valyuta      text        not null default 'UZS',
  summa        numeric     not null check (summa > 0),                   -- so'm ekvivalenti (har doim)
  fc_summa     numeric     check (fc_summa is null or fc_summa > 0),     -- valyuta miqdori (USD bo'lsa)
  ism          text        not null check (length(btrim(ism)) >= 2),     -- KIMDAN olingan (shaxs)
  telefon      text,
  muddat       date,                                                     -- qaytarish muddati (ixtiyoriy)
  sana         date        not null default ((now() at time zone 'Asia/Tashkent')::date),
  izoh         text        not null check (length(btrim(izoh)) >= 3),
  holat        text        not null default 'faol' check (holat in ('faol','yopildi','bekor')),
  ext_ref      text        unique,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  yopilgan_at  timestamptz,
  bekor_sabab  text,
  bekor_by     uuid,
  bekor_at     timestamptz
);
comment on table ehson_qarz_olingan is
  'Ehson jamg''armasi tomonidan OLINGAN qarz (kimdandir). Pul ehson kassasiga kiradi (v_ehson_kassa_pul.qarz_olindi), qaytarilsa '
  'kassadan chiqadi (qarz_olingan_qaytdi). Kompaniya buxgalteriyasiga (entry/accounts) TEGILMAYDI. Qoldiq qarz valyutasi birligida.';
create index if not exists ehson_qarz_olingan_kassa_idx on ehson_qarz_olingan (kassa_id);
create index if not exists ehson_qarz_olingan_holat_idx on ehson_qarz_olingan (holat);

create table if not exists ehson_qarz_olingan_tolov (
  id           uuid        primary key default gen_random_uuid(),
  olingan_id   uuid        not null references ehson_qarz_olingan(id),
  kassa_id     uuid        not null references ehson_kassa(id),          -- pul CHIQQAN ehson kassa
  pul_turi     text,
  valyuta      text        not null default 'UZS',
  summa        numeric     not null check (summa > 0),                   -- so'm ekvivalenti
  fc_summa     numeric     check (fc_summa is null or fc_summa > 0),
  sana         date        not null default ((now() at time zone 'Asia/Tashkent')::date),
  izoh         text,
  ext_ref      text        unique,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  is_deleted   boolean     not null default false
);
create index if not exists ehson_qarz_olingan_tolov_qarz_idx on ehson_qarz_olingan_tolov (olingan_id);

-- RLS — ehson jadvallari naqshi: faqat select (ehson_page_ok), yozish faqat RPC
do $eho_rls$
declare t text;
begin
  foreach t in array array['ehson_qarz_olingan','ehson_qarz_olingan_tolov'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from public, anon', t);
    execute format('grant select on table %I to authenticated', t);
    execute format('drop policy if exists %I on %I', t || '_select', t);
    execute format('create policy %I on %I for select to authenticated using (ehson_page_ok())', t || '_select', t);
  end loop;
end
$eho_rls$;

-- ehson_tarix.obyekt check'iga 'qarz_olingan','qarz_olingan_tolov' (MAVJUD ro'yxat constraint tanasidan o'qiladi — transfer naqshi)
do $eho_tarix$
declare v_name text; v_def text; v_list text; v_x text;
begin
  select conname, pg_get_constraintdef(oid) into v_name, v_def
    from pg_constraint
   where conrelid = 'public.ehson_tarix'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%obyekt%'
   limit 1;
  if v_name is not null and v_def not like '%qarz_olingan_tolov%' then
    select string_agg(distinct quote_literal(m[1]), ',')
      into v_list
      from regexp_matches(v_def, '''([a-z_]+)''', 'g') as m;
    v_list := coalesce(v_list, '''oila'',''azo'',''berish'',''kirim'',''reja'',''kassa'',''qarz'',''qarz_tolov''');
    foreach v_x in array array['qarz_olingan', 'qarz_olingan_tolov'] loop
      if position(quote_literal(v_x) in v_list) = 0 then
        v_list := v_list || ',' || quote_literal(v_x);
      end if;
    end loop;
    execute format('alter table ehson_tarix drop constraint %I', v_name);
    execute 'alter table ehson_tarix add constraint ehson_tarix_obyekt_check check (obyekt in (' || v_list || '))';
  end if;
end
$eho_tarix$;

-- ######## 2) QOLDIQ VIEW'LARI — olingan qarz kirimi / qaytarish chiqimi (ustunlar OXIRIGA qo'shildi) ########
create or replace view v_ehson_kassa_pul as
select
  x.kassa_id,
  x.pul_turi,
  x.valyuta,
  sum(x.kirim)                                                              as kirim,
  sum(x.berildi)                                                            as berildi,
  case when x.valyuta = 'USD' and kk.kurs is not null
       then round((sum(x.fc_kirim) - sum(x.fc_berildi) - sum(x.fc_qarz_berildi) + sum(x.fc_qarz_qaytdi)
                   - sum(x.fc_tr_chiqdi) + sum(x.fc_tr_kirdi)
                   + sum(x.fc_qo_kirdi) - sum(x.fc_qo_chiqdi)) * kk.kurs, 2)
       else sum(x.kirim) - sum(x.berildi) - sum(x.qarz_berildi) + sum(x.qarz_qaytdi)
              - sum(x.tr_chiqdi) + sum(x.tr_kirdi)
              + sum(x.qo_kirdi) - sum(x.qo_chiqdi)
  end                                                                       as qoldiq,
  sum(x.fc_kirim)                                                           as fc_kirim,
  sum(x.fc_berildi)                                                         as fc_berildi,
  sum(x.fc_kirim) - sum(x.fc_berildi) - sum(x.fc_qarz_berildi) + sum(x.fc_qarz_qaytdi)
    - sum(x.fc_tr_chiqdi) + sum(x.fc_tr_kirdi)
    + sum(x.fc_qo_kirdi) - sum(x.fc_qo_chiqdi)                              as fc_qoldiq,
  sum(x.qarz_berildi)                                                       as qarz_berildi,
  sum(x.qarz_qaytdi)                                                        as qarz_qaytdi,
  sum(x.fc_qarz_berildi)                                                    as fc_qarz_berildi,
  sum(x.fc_qarz_qaytdi)                                                     as fc_qarz_qaytdi,
  sum(x.tr_chiqdi)                                                          as tr_chiqdi,
  sum(x.tr_kirdi)                                                           as tr_kirdi,
  sum(x.fc_tr_chiqdi)                                                       as fc_tr_chiqdi,
  sum(x.fc_tr_kirdi)                                                        as fc_tr_kirdi,
  (x.valyuta = 'USD' and kk.kurs is null)                                   as kurs_yoq,
  sum(x.qo_kirdi)                                                           as qarz_olindi,
  sum(x.qo_chiqdi)                                                          as qarz_olingan_qaytdi,
  sum(x.fc_qo_kirdi)                                                        as fc_qarz_olindi,
  sum(x.fc_qo_chiqdi)                                                       as fc_qarz_olingan_qaytdi
from (
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS') as valyuta,
         summa as kirim, 0::numeric as berildi, 0::numeric as qarz_berildi, 0::numeric as qarz_qaytdi,
         coalesce(fc_summa, 0) as fc_kirim, 0::numeric as fc_berildi, 0::numeric as fc_qarz_berildi, 0::numeric as fc_qarz_qaytdi,
         0::numeric as tr_chiqdi, 0::numeric as tr_kirdi, 0::numeric as fc_tr_chiqdi, 0::numeric as fc_tr_kirdi,
         0::numeric as qo_kirdi, 0::numeric as qo_chiqdi, 0::numeric as fc_qo_kirdi, 0::numeric as fc_qo_chiqdi
    from ehson_kirim where is_deleted = false
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, summa, 0, 0,
         0, coalesce(fc_summa, 0), 0, 0,
         0, 0, 0, 0,
         0, 0, 0, 0
    from ehson_berish where holat = 'berildi'
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, summa, 0,
         0, 0, coalesce(fc_summa, 0), 0,
         0, 0, 0, 0,
         0, 0, 0, 0
    from ehson_qarz where holat in ('faol', 'yopildi')
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, 0, summa,
         0, 0, 0, coalesce(fc_summa, 0),
         0, 0, 0, 0,
         0, 0, 0, 0
    from ehson_qarz_tolov where is_deleted = false
  union all
  -- o'tkazma / konvert: chiqqan kassa (avvalgidek)
  select from_kassa_id, from_pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, 0, 0,
         0, 0, 0, 0,
         summa, 0, coalesce(fc_summa, 0), 0,
         0, 0, 0, 0
    from ehson_transfer where is_deleted = false
  union all
  -- o'tkazma / konvert: kirgan kassa — konvertda boshqa valyuta (to_valyuta) va to_summa/to_fc_summa
  select to_kassa_id, to_pul_turi, coalesce(to_valyuta, valyuta, 'UZS'),
         0, 0, 0, 0,
         0, 0, 0, 0,
         0, coalesce(to_summa, summa), 0,
         case when coalesce(to_valyuta, valyuta, 'UZS') = 'USD' then coalesce(to_fc_summa, fc_summa, 0) else 0 end,
         0, 0, 0, 0
    from ehson_transfer where is_deleted = false
  union all
  -- OLINGAN qarz: pul ehson kassasiga KIRADI
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, 0, 0,
         0, 0, 0, 0,
         0, 0, 0, 0,
         summa, 0, coalesce(fc_summa, 0), 0
    from ehson_qarz_olingan where holat in ('faol', 'yopildi')
  union all
  -- OLINGAN qarzni qaytarish: pul ehson kassasidan CHIQADI
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, 0, 0,
         0, 0, 0, 0,
         0, 0, 0, 0,
         0, summa, 0, coalesce(fc_summa, 0)
    from ehson_qarz_olingan_tolov where is_deleted = false
) x
cross join (select _ehson_kurs_usd_ich() as kurs) kk
group by x.kassa_id, x.pul_turi, x.valyuta, kk.kurs;
alter view v_ehson_kassa_pul set (security_invoker = on);
revoke all on v_ehson_kassa_pul from public, anon;
grant select on v_ehson_kassa_pul to authenticated;
comment on view v_ehson_kassa_pul is
  'Har jamg''arma + pul turi kesimida kirim/berildi/qoldiq (so''m) va fc_* (dollar). qoldiq = kirim − berildi − qarz_berildi + '
  'qarz_qaytdi − tr_chiqdi + tr_kirdi + qarz_olindi − qarz_olingan_qaytdi. USD qatorda qoldiq = fc_qoldiq × JORIY kurs '
  '(_ehson_kurs_usd_ich; kurs yoq bo''lsa so''m yig''indisi va kurs_yoq = true). Qoldiq MANFIY bo''lishi mumkin (2026-11-06).';

create or replace view v_ehson_kassa as
select k.id, k.nom, k.is_active,
  coalesce(ki.summa, 0) as kirim,
  coalesce(be.summa, 0) as berildi,
  coalesce(vq.qoldiq, 0) as qoldiq,
  coalesce(qb.summa, 0) as qarz_berildi,
  coalesce(qq.summa, 0) as qarz_qaytdi,
  coalesce(tc.summa, 0) as tr_chiqdi,
  coalesce(tk.summa, 0) as tr_kirdi,
  coalesce(qo.summa, 0) as qarz_olindi,
  coalesce(oq.summa, 0) as qarz_olingan_qaytdi
from ehson_kassa k
left join lateral (select sum(summa) as summa from ehson_kirim       where kassa_id = k.id and is_deleted = false) ki on true
left join lateral (select sum(summa) as summa from ehson_berish      where kassa_id = k.id and holat = 'berildi') be on true
left join lateral (select sum(summa) as summa from ehson_qarz        where kassa_id = k.id and holat in ('faol','yopildi')) qb on true
left join lateral (select sum(summa) as summa from ehson_qarz_tolov  where kassa_id = k.id and is_deleted = false) qq on true
left join lateral (select sum(summa) as summa from ehson_transfer    where from_kassa_id = k.id and is_deleted = false) tc on true
left join lateral (select sum(coalesce(to_summa, summa)) as summa from ehson_transfer where to_kassa_id = k.id and is_deleted = false) tk on true
left join lateral (select sum(qoldiq) as qoldiq from v_ehson_kassa_pul where kassa_id = k.id) vq on true
left join lateral (select sum(summa) as summa from ehson_qarz_olingan       where kassa_id = k.id and holat in ('faol','yopildi')) qo on true
left join lateral (select sum(summa) as summa from ehson_qarz_olingan_tolov where kassa_id = k.id and is_deleted = false) oq on true;
alter view v_ehson_kassa set (security_invoker = on);
revoke all on v_ehson_kassa from public, anon;
grant select on v_ehson_kassa to authenticated;
comment on view v_ehson_kassa is
  'Jamg''arma jami: qoldiq = v_ehson_kassa_pul.qoldiq yig''indisi (olingan qarz kirimi va qaytarish chiqimi ichida; manfiy bo''lishi mumkin). '
  'kirim/berildi/... — xom so''m yig''indilar.';

-- ######## 3) MANFIY QOLDIQ — ehson ichidagi amallarda qoldiq tekshiruvi olib tashlandi ########
--  Quyidagi 5 funksiya oxirgi versiyasidan verbatim, faqat qoldiq bloki izohga almashtirilgan (imzo o'zgarmagan).
--  ehson_ber: PROVODKA_EHSON_ZAKOT.sql · ehson_qarz_ber: PROVODKA_EHSON_QARZ.sql · ehson_transfer_yoz: PROVODKA_EHSON_TRANSFER.sql
--  ehson_konvert_yoz / ehson_transfer_bekor: PROVODKA_EHSON_KONVERT_QARZ_GURUH.sql

create or replace function ehson_ber(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid        uuid    := auth.uid();
  v_oila       uuid    := nullif(p->>'oila_id', '')::uuid;
  v_kassa      uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_summa      numeric := nullif(p->>'summa', '')::numeric;
  v_sana       date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_tur        text    := nullif(p->>'tur', '');
  v_izoh       text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_reja       uuid    := nullif(p->>'reja_id', '')::uuid;
  v_kkch       date    := nullif(p->>'keyingi_korib_chiqish', '')::date;
  v_ext        text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  v_pul_turi_p text    := nullif(p->>'pul_turi', '');
  v_fc_p       numeric := nullif(p->>'fc_summa', '')::numeric;
  v_oila_r     ehson_oila;
  v_kassa_r    ehson_kassa;
  v_pt         ehson_pul_turi;
  v_pt_cnt     int;
  v_kurs       numeric;
  v_qoldiq     numeric;
  v_qoldiq_fc  numeric;
  v_id         uuid;
  v_exist      uuid;
  v_cnt        int;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  if v_ext is not null then
    select id into v_exist from ehson_berish where ext_ref = v_ext;
    if found then
      return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
    end if;
  end if;

  if v_oila is null then
    return jsonb_build_object('ok', false, 'kod', 'oila_kerak');
  end if;
  select * into v_oila_r from ehson_oila where id = v_oila;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'oila_topilmadi');
  end if;
  if v_oila_r.holat = 'yopildi' then
    return jsonb_build_object('ok', false, 'kod', 'oila_yopiq');
  end if;
  if v_tur is null or v_tur not in ('pul','oziq_ovqat','kiyim','dori','boshqa') then
    return jsonb_build_object('ok', false, 'kod', 'tur_notogri');
  end if;
  if v_izoh is null or length(v_izoh) < 3 then
    return jsonb_build_object('ok', false, 'kod', 'izoh_kerak');
  end if;
  if v_reja is not null and not exists (select 1 from ehson_reja where id = v_reja and oila_id = v_oila) then
    return jsonb_build_object('ok', false, 'kod', 'reja_topilmadi');
  end if;

  if v_kassa is null then
    select count(*) into v_cnt from ehson_kassa where is_active and not is_container;
    if v_cnt <> 1 then
      return jsonb_build_object('ok', false, 'kod', 'kassa_tanlanmagan');
    end if;
    select id into v_kassa from ehson_kassa where is_active and not is_container limit 1;
  end if;
  select * into v_kassa_r from ehson_kassa where id = v_kassa and is_active;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi');
  end if;
  if v_kassa_r.is_container then
    return jsonb_build_object('ok', false, 'kod', 'kassa_konteyner');
  end if;

  -- Pul turi: kassada faol pul turi bo'lmasa — eski xatti-harakat (jami qoldiq,
  -- pul turisiz). Bo'lsa — majburiy, tanlangani faol bo'lishi shart. Dollar
  -- tanlansa summa USD'da (fc_summa), so'm ekvivalenti conv_baza_kurs('USD') bilan.
  select count(*) into v_pt_cnt from ehson_pul_turi where kassa_id = v_kassa and is_active;
  if v_pt_cnt > 0 then
    if v_pul_turi_p is null then
      return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak');
    end if;
    select * into v_pt from ehson_pul_turi where kassa_id = v_kassa and kod = v_pul_turi_p and is_active;
    if not found then
      return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak');
    end if;

    if v_pt.valyuta = 'USD' then
      if v_fc_p is null or v_fc_p <= 0 then
        return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
      end if;
      v_kurs := null;
      if exists (
        select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
         where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs'
           and oidvectortypes(pr.proargtypes) = 'text'
      ) then
        execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
      end if;
      if v_kurs is null or v_kurs <= 0 then
        return jsonb_build_object('ok', false, 'kod', 'kurs_yoq');
      end if;
      v_summa := round(v_fc_p * v_kurs);
    else
      v_fc_p := null;
      if v_summa is null or v_summa <= 0 then
        return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
      end if;
    end if;
  else
    v_pul_turi_p := null;
    v_fc_p := null;
    if v_summa is null or v_summa <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || v_kassa::text));

  -- 2026-11-06: ehson kassasi MANFIYGA tushishi mumkin — qoldiq tekshiruvi olib tashlandi (Asilbek).

  insert into ehson_berish (
    oila_id, kassa_id, summa, sana, tur, izoh, reja_id, holat,
    keyingi_korib_chiqish, created_by, ext_ref, pul_turi, valyuta, fc_summa
  ) values (
    v_oila, v_kassa, v_summa, v_sana, v_tur, v_izoh, v_reja, 'berildi',
    v_kkch, v_uid, v_ext, v_pt.kod, coalesce(v_pt.valyuta, 'UZS'), v_fc_p
  )
  returning id into v_id;

  perform _ehson_tarix_yoz('berish', v_id, 'yaratildi',
    jsonb_build_object('oila_id', v_oila, 'summa', v_summa, 'tur', v_tur, 'pul_turi', v_pt.kod));

  return jsonb_build_object('ok', true, 'id', v_id);
exception when unique_violation then
  select id into v_exist from ehson_berish where ext_ref = v_ext;
  return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;
revoke all on function ehson_ber(jsonb) from public, anon;
grant execute on function ehson_ber(jsonb) to authenticated;

create or replace function ehson_qarz_ber(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid        uuid    := auth.uid();
  v_kassa      uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_summa      numeric := nullif(p->>'summa', '')::numeric;
  v_fc_p       numeric := nullif(p->>'fc_summa', '')::numeric;
  v_pul_turi_p text    := nullif(p->>'pul_turi', '');
  v_sana       date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_qt         text    := nullif(p->>'qarzdor_turi', '');
  v_oila       uuid    := nullif(p->>'oila_id', '')::uuid;
  v_ism        text    := nullif(btrim(coalesce(p->>'ism', '')), '');
  v_tel        text    := nullif(btrim(coalesce(p->>'telefon', '')), '');
  v_mt         text    := nullif(p->>'muddat_turi', '');
  v_tugash     date    := nullif(p->>'tugash', '')::date;
  v_bosh       date    := nullif(p->>'boshlanish', '')::date;
  v_oylar      int     := nullif(p->>'oylar_soni', '')::int;
  v_izoh       text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_ext        text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  v_kassa_r    ehson_kassa;
  v_pt         ehson_pul_turi;
  v_pt_cnt     int;
  v_kurs       numeric;
  v_qoldiq     numeric;
  v_qoldiq_fc  numeric;
  v_valyuta    text := 'UZS';
  v_asosiy     numeric;
  v_oylik      numeric;
  v_used       numeric := 0;
  v_row        numeric;
  v_i          int;
  v_id         uuid;
  v_exist      uuid;
  v_cnt        int;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Avtorizatsiya kerak'); end if;
  if not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Ehson sahifasi ruxsatingizda yoq'); end if;

  if v_ext is not null then
    select id into v_exist from ehson_qarz where ext_ref = v_ext;
    if found then return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist); end if;
  end if;

  -- qarzdor
  if v_qt = 'oila' then
    if v_oila is null then return jsonb_build_object('ok', false, 'kod', 'qarzdor_kerak'); end if;
    if not exists (select 1 from ehson_oila o where o.id = v_oila) then
      return jsonb_build_object('ok', false, 'kod', 'oila_topilmadi');
    end if;
    v_ism := null;
  elsif v_qt = 'shaxs' then
    if v_ism is null or length(v_ism) < 2 then return jsonb_build_object('ok', false, 'kod', 'qarzdor_kerak'); end if;
    v_oila := null;
  else
    return jsonb_build_object('ok', false, 'kod', 'qarzdor_kerak');
  end if;

  if v_izoh is null or length(v_izoh) < 3 then return jsonb_build_object('ok', false, 'kod', 'izoh_kerak'); end if;

  -- muddat
  if v_mt = 'bir_martalik' then
    if v_tugash is null or v_tugash < v_sana then return jsonb_build_object('ok', false, 'kod', 'muddat_notogri'); end if;
    v_bosh := null; v_oylar := null;
  elsif v_mt = 'oylik' then
    if v_bosh is null or v_oylar is null or v_oylar < 1 or v_oylar > 120 then
      return jsonb_build_object('ok', false, 'kod', 'muddat_notogri');
    end if;
    v_tugash := _ehson_oy_qosh(v_bosh, v_oylar - 1);
  else
    return jsonb_build_object('ok', false, 'kod', 'muddat_notogri');
  end if;

  -- kassa (ehson_ber bilan bir xil)
  if v_kassa is null then
    select count(*) into v_cnt from ehson_kassa where is_active and not is_container;
    if v_cnt = 1 then
      select id into v_kassa from ehson_kassa where is_active and not is_container;
    else
      return jsonb_build_object('ok', false, 'kod', 'kassa_tanlanmagan');
    end if;
  end if;
  select * into v_kassa_r from ehson_kassa where id = v_kassa and is_active;
  if not found then return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi'); end if;
  if v_kassa_r.is_container then return jsonb_build_object('ok', false, 'kod', 'kassa_konteyner'); end if;

  -- pul turi + valyuta/kurs (ehson_ber bilan bir xil)
  select count(*) into v_pt_cnt from ehson_pul_turi where kassa_id = v_kassa and is_active;
  if v_pt_cnt > 0 then
    if v_pul_turi_p is null then return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak'); end if;
    select * into v_pt from ehson_pul_turi where kassa_id = v_kassa and kod = v_pul_turi_p and is_active;
    if not found then return jsonb_build_object('ok', false, 'kod', 'pul_turi_topilmadi'); end if;
    v_valyuta := coalesce(v_pt.valyuta, 'UZS');
    if v_valyuta = 'USD' then
      if v_fc_p is null or v_fc_p <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
      v_kurs := null;
      if exists (select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
                  where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs' and oidvectortypes(pr.proargtypes) = 'text') then
        execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
      end if;
      if v_kurs is null or v_kurs <= 0 then return jsonb_build_object('ok', false, 'kod', 'kurs_yoq'); end if;
      v_summa := round(v_fc_p * v_kurs);
    else
      v_fc_p := null;
      if v_summa is null or v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    end if;
  else
    v_pul_turi_p := null; v_fc_p := null;
    if v_summa is null or v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
  end if;

  -- qoldiq tekshiruvi yo'q: ehson kassasi manfiyga tushishi mumkin (2026-11-06, Asilbek). Advisory lock saqlandi.
  perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || v_kassa::text));

  -- asosiy (qarz valyutasi birligi) va oylik
  v_asosiy := case when v_valyuta = 'USD' then v_fc_p else v_summa end;
  if v_mt = 'oylik' then
    v_oylik := case when v_valyuta = 'USD' then round(v_asosiy / v_oylar, 2) else floor(v_asosiy / v_oylar) end;
    if v_oylik <= 0 then return jsonb_build_object('ok', false, 'kod', 'muddat_notogri'); end if;
  end if;

  insert into ehson_qarz (kassa_id, pul_turi, valyuta, summa, fc_summa, qarzdor_turi, oila_id, ism, telefon,
                          muddat_turi, boshlanish, tugash, oylar_soni, oylik_summa, sana, izoh, holat, ext_ref, created_by)
  values (v_kassa, v_pul_turi_p, v_valyuta, v_summa, v_fc_p, v_qt, v_oila, v_ism, v_tel,
          v_mt, v_bosh, v_tugash, v_oylar, v_oylik, v_sana, v_izoh, 'faol', v_ext, v_uid)
  returning id into v_id;

  -- grafik
  if v_mt = 'bir_martalik' then
    insert into ehson_qarz_jadval (qarz_id, n, sana, summa) values (v_id, 1, v_tugash, v_asosiy);
  else
    for v_i in 1..v_oylar loop
      if v_i < v_oylar then v_row := v_oylik; v_used := v_used + v_row;
      else v_row := v_asosiy - v_used; end if;   -- oxirgi oy qoldiqni oladi
      insert into ehson_qarz_jadval (qarz_id, n, sana, summa) values (v_id, v_i, _ehson_oy_qosh(v_bosh, v_i - 1), v_row);
    end loop;
  end if;

  perform _ehson_tarix_yoz('qarz', v_id, 'yaratildi',
    jsonb_build_object('kassa_id', v_kassa, 'pul_turi', v_pul_turi_p, 'summa', v_summa, 'fc_summa', v_fc_p,
                       'valyuta', v_valyuta, 'qarzdor_turi', v_qt, 'oila_id', v_oila, 'ism', v_ism,
                       'muddat_turi', v_mt, 'tugash', v_tugash, 'oylar_soni', v_oylar));
  return jsonb_build_object('ok', true, 'id', v_id);
exception
  when unique_violation then
    select id into v_exist from ehson_qarz where ext_ref = v_ext;
    return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;
revoke all on function ehson_qarz_ber(jsonb) from public, anon;
grant execute on function ehson_qarz_ber(jsonb) to authenticated;

create or replace function ehson_transfer_yoz(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid    := auth.uid();
  v_from    uuid    := nullif(p->>'from_kassa_id', '')::uuid;
  v_fpt     text    := nullif(p->>'from_pul_turi', '');
  v_to      uuid    := nullif(p->>'to_kassa_id', '')::uuid;
  v_tpt     text    := nullif(p->>'to_pul_turi', '');
  v_summa   numeric := nullif(p->>'summa', '')::numeric;
  v_fc      numeric := nullif(p->>'fc_summa', '')::numeric;
  v_bugun   date    := (now() at time zone 'Asia/Tashkent')::date;
  v_sana    date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_izoh    text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_ext     text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  v_fk      ehson_kassa;
  v_tk      ehson_kassa;
  v_fp      ehson_pul_turi;
  v_tp      ehson_pul_turi;
  v_kurs    numeric;
  v_qoldiq  numeric;
  v_fcq     numeric;
  v_id      uuid;
  v_exist   uuid;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  if v_ext is not null then
    select id into v_exist from ehson_transfer where ext_ref = v_ext;
    if found then
      return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
    end if;
  end if;

  if v_sana > v_bugun then
    return jsonb_build_object('ok', false, 'kod', 'sana_notogri');
  end if;
  if v_from is null or v_to is null then
    return jsonb_build_object('ok', false, 'kod', 'kassa_kerak');
  end if;
  if v_fpt is null or v_tpt is null then
    return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak');
  end if;
  if v_from = v_to and v_fpt = v_tpt then
    return jsonb_build_object('ok', false, 'kod', 'bir_xil');
  end if;

  select * into v_fk from ehson_kassa where id = v_from and is_active;
  if not found then return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi', 'tomon', 'from'); end if;
  select * into v_tk from ehson_kassa where id = v_to and is_active;
  if not found then return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi', 'tomon', 'to'); end if;
  if v_fk.is_container or v_tk.is_container then
    return jsonb_build_object('ok', false, 'kod', 'kassa_konteyner');
  end if;

  select * into v_fp from ehson_pul_turi where kassa_id = v_from and kod = v_fpt and is_active;
  if not found then return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak', 'tomon', 'from'); end if;
  select * into v_tp from ehson_pul_turi where kassa_id = v_to and kod = v_tpt and is_active;
  if not found then return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak', 'tomon', 'to'); end if;

  if coalesce(v_fp.valyuta, 'UZS') <> coalesce(v_tp.valyuta, 'UZS') then
    return jsonb_build_object('ok', false, 'kod', 'valyuta_mos_emas',
                              'from_valyuta', coalesce(v_fp.valyuta, 'UZS'), 'to_valyuta', coalesce(v_tp.valyuta, 'UZS'));
  end if;

  if coalesce(v_fp.valyuta, 'UZS') = 'USD' then
    if v_fc is null or v_fc <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
    end if;
    v_fc := round(v_fc, 2);
    v_kurs := null;
    if exists (
      select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
       where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs'
         and oidvectortypes(pr.proargtypes) = 'text'
    ) then
      execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
    end if;
    if v_kurs is null or v_kurs <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'kurs_yoq');
    end if;
    v_summa := round(v_fc * v_kurs);
    if v_summa <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
    end if;
  else
    v_fc := null;
    v_summa := round(coalesce(v_summa, 0));   -- avval round, keyin tekshiruv (0.4 -> 0 check'ga urilmasin)
    if v_summa <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
    end if;
  end if;

  -- ikkala kassa qulflanadi (id tartibida — deadlock bo'lmasin), keyin qoldiq o'qiladi
  perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || least(v_from::text, v_to::text)));
  if v_from <> v_to then
    perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || greatest(v_from::text, v_to::text)));
  end if;

  -- 2026-11-06: ehson kassasi MANFIYGA tushishi mumkin — qoldiq tekshiruvi olib tashlandi (Asilbek).

  insert into ehson_transfer (from_kassa_id, from_pul_turi, to_kassa_id, to_pul_turi, valyuta, summa, fc_summa, sana, izoh, ext_ref, created_by)
  values (v_from, v_fpt, v_to, v_tpt, coalesce(v_fp.valyuta, 'UZS'), v_summa, v_fc, v_sana, v_izoh, v_ext, v_uid)
  returning id into v_id;

  perform _ehson_tarix_yoz('transfer', v_id, 'yaratildi',
    jsonb_build_object('from_kassa_id', v_from, 'from_pul_turi', v_fpt, 'to_kassa_id', v_to, 'to_pul_turi', v_tpt,
                       'summa', v_summa, 'fc_summa', v_fc, 'sana', v_sana, 'izoh', v_izoh));

  return jsonb_build_object('ok', true, 'id', v_id, 'summa', v_summa, 'fc_summa', v_fc);
exception when unique_violation then
  select id into v_exist from ehson_transfer where ext_ref = v_ext;
  return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;
revoke all on function ehson_transfer_yoz(jsonb) from public, anon;
grant execute on function ehson_transfer_yoz(jsonb) to authenticated;

create or replace function ehson_konvert_yoz(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid    := auth.uid();
  v_from    uuid    := nullif(p->>'from_kassa_id', '')::uuid;
  v_fpt     text    := nullif(p->>'from_pul_turi', '');
  v_to      uuid    := nullif(p->>'to_kassa_id', '')::uuid;
  v_tpt     text    := nullif(p->>'to_pul_turi', '');
  v_in      numeric := nullif(p->>'summa', '')::numeric;
  v_kurs    numeric := nullif(p->>'kurs', '')::numeric;
  v_bugun   date    := (now() at time zone 'Asia/Tashkent')::date;
  v_sana    date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_izoh    text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_ext     text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  v_fk      ehson_kassa;
  v_tk      ehson_kassa;
  v_fp      ehson_pul_turi;
  v_tp      ehson_pul_turi;
  v_fval    text;
  v_tval    text;
  v_uzs     numeric;      -- so'm ekvivalenti (ikkala tomon)
  v_fc      numeric;      -- chiqqan USD (from USD bo'lsa)
  v_to_fc   numeric;      -- kirgan USD (to USD bo'lsa)
  v_qoldiq  numeric;
  v_fcq     numeric;
  v_id      uuid;
  v_exist   uuid;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  if v_ext is not null then
    select id into v_exist from ehson_transfer where ext_ref = v_ext;
    if found then
      return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
    end if;
  end if;

  if v_sana > v_bugun then return jsonb_build_object('ok', false, 'kod', 'sana_notogri'); end if;
  if v_from is null or v_to is null then return jsonb_build_object('ok', false, 'kod', 'kassa_kerak'); end if;
  if v_fpt is null or v_tpt is null then return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak'); end if;

  select * into v_fk from ehson_kassa where id = v_from and is_active;
  if not found then return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi', 'tomon', 'from'); end if;
  select * into v_tk from ehson_kassa where id = v_to and is_active;
  if not found then return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi', 'tomon', 'to'); end if;
  if v_fk.is_container or v_tk.is_container then
    return jsonb_build_object('ok', false, 'kod', 'kassa_konteyner');
  end if;

  select * into v_fp from ehson_pul_turi where kassa_id = v_from and kod = v_fpt and is_active;
  if not found then return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak', 'tomon', 'from'); end if;
  select * into v_tp from ehson_pul_turi where kassa_id = v_to and kod = v_tpt and is_active;
  if not found then return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak', 'tomon', 'to'); end if;

  v_fval := coalesce(v_fp.valyuta, 'UZS');
  v_tval := coalesce(v_tp.valyuta, 'UZS');
  if v_fval = v_tval then
    return jsonb_build_object('ok', false, 'kod', 'valyuta_bir_xil');       -- bu konvert emas, o'tkazma
  end if;
  if not ((v_fval = 'USD' and v_tval = 'UZS') or (v_fval = 'UZS' and v_tval = 'USD')) then
    return jsonb_build_object('ok', false, 'kod', 'valyuta_qollanmaydi', 'from_valyuta', v_fval, 'to_valyuta', v_tval);
  end if;
  if v_kurs is null or v_kurs <= 0 then return jsonb_build_object('ok', false, 'kod', 'kurs_notogri'); end if;
  if v_in is null or v_in <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;

  if v_fval = 'USD' then
    v_fc    := round(v_in, 2);
    v_uzs   := round(v_fc * v_kurs);
    v_to_fc := null;
  else
    v_fc    := null;
    v_uzs   := round(v_in);
    v_to_fc := round(v_uzs / v_kurs, 2);
  end if;
  if v_uzs <= 0 or (v_fc is not null and v_fc <= 0) or (v_to_fc is not null and v_to_fc <= 0) then
    return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
  end if;

  -- ikkala kassa qulflanadi (id tartibida — deadlock bo'lmasin), keyin qoldiq o'qiladi
  perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || least(v_from::text, v_to::text)));
  if v_from <> v_to then
    perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || greatest(v_from::text, v_to::text)));
  end if;

  -- 2026-11-06: ehson kassasi MANFIYGA tushishi mumkin — qoldiq tekshiruvi olib tashlandi (Asilbek).

  insert into ehson_transfer (from_kassa_id, from_pul_turi, to_kassa_id, to_pul_turi, valyuta, summa, fc_summa, sana, izoh, ext_ref, created_by,
                              turi, kurs, to_valyuta, to_summa, to_fc_summa)
  values (v_from, v_fpt, v_to, v_tpt, v_fval, v_uzs, v_fc, v_sana, v_izoh, v_ext, v_uid,
          'konvert', v_kurs, v_tval, v_uzs, v_to_fc)
  returning id into v_id;

  perform _ehson_tarix_yoz('transfer', v_id, 'konvert',
    jsonb_build_object('from_kassa_id', v_from, 'from_pul_turi', v_fpt, 'to_kassa_id', v_to, 'to_pul_turi', v_tpt,
                       'valyuta', v_fval, 'summa', v_uzs, 'fc_summa', v_fc, 'to_valyuta', v_tval, 'to_fc_summa', v_to_fc,
                       'kurs', v_kurs, 'sana', v_sana, 'izoh', v_izoh));

  return jsonb_build_object('ok', true, 'id', v_id, 'summa', v_uzs, 'fc_summa', v_fc, 'to_valyuta', v_tval,
                            'to_summa', v_uzs, 'to_fc_summa', v_to_fc, 'kurs', v_kurs);
exception when unique_violation then
  select id into v_exist from ehson_transfer where ext_ref = v_ext;
  return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;
revoke all on function ehson_konvert_yoz(jsonb) from public, anon;
grant execute on function ehson_konvert_yoz(jsonb) to authenticated;

create or replace function ehson_transfer_bekor(p_id uuid, p_sabab text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  t       ehson_transfer;
  v_tval  text;
  v_q     numeric;
  v_fcq   numeric;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not _ehson_is_admin() then
    raise exception 'O''tkazmani bekor qilish faqat admin uchun' using errcode = '42501';
  end if;
  if p_sabab is null or length(btrim(p_sabab)) < 3 then
    return jsonb_build_object('ok', false, 'kod', 'sabab_kerak');
  end if;
  select * into t from ehson_transfer where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if t.is_deleted then return jsonb_build_object('ok', false, 'kod', 'allaqachon'); end if;

  perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || least(t.from_kassa_id::text, t.to_kassa_id::text)));
  if t.from_kassa_id <> t.to_kassa_id then
    perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || greatest(t.from_kassa_id::text, t.to_kassa_id::text)));
  end if;

  -- 2026-11-06: qabul qilgan kassa qoldig'i manfiy bo'lsa ham bekor qilinadi (ehson kassalari manfiyda yurishi mumkin).

  update ehson_transfer
     set is_deleted = true, deleted_by = v_uid, deleted_at = now(), bekor_sabab = btrim(p_sabab)
   where id = p_id;

  perform _ehson_tarix_yoz('transfer', p_id, 'bekor',
    jsonb_build_object('sabab', btrim(p_sabab), 'turi', t.turi, 'summa', t.summa, 'fc_summa', t.fc_summa,
                       'to_summa', t.to_summa, 'to_fc_summa', t.to_fc_summa));
  return jsonb_build_object('ok', true);
end
$fn$;
revoke all on function ehson_transfer_bekor(uuid, text) from public, anon;
grant execute on function ehson_transfer_bekor(uuid, text) to authenticated;

-- ######## 4) SERIALIZATOR (faqat jadval qatori bilan chaqiriladi) ########
create or replace function _ehson_qarz_olingan_qator(q ehson_qarz_olingan)
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select jsonb_build_object(
    'id',            q.id,
    'ism',           q.ism,
    'telefon',       q.telefon,
    'kassa_id',      q.kassa_id,
    'kassa_nom',     (select k.nom from ehson_kassa k where k.id = q.kassa_id),
    'pul_turi',      q.pul_turi,
    'pul_turi_nom',  (select pt.nom from ehson_pul_turi pt where pt.kassa_id = q.kassa_id and pt.kod = q.pul_turi),
    'valyuta',       q.valyuta,
    'summa',         q.summa,
    'fc_summa',      q.fc_summa,
    'asosiy',        a.asosiy,
    'qaytarildi',    t.qaytarildi,
    'qoldi',         greatest(a.asosiy - t.qaytarildi, 0),
    'muddat',        q.muddat,
    'kechikkan_kun', case when q.holat = 'faol' and q.muddat is not null
                               and q.muddat < (now() at time zone 'Asia/Tashkent')::date
                          then ((now() at time zone 'Asia/Tashkent')::date - q.muddat) else 0 end,
    'holat',         q.holat,
    'izoh',          q.izoh,
    'sana',          q.sana,
    'kim',           (select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = q.created_by),
    'created_at',    q.created_at,
    'yopilgan_at',   q.yopilgan_at,
    'bekor_sabab',   q.bekor_sabab,
    'created_by',    q.created_by,
    'tolovlar',      coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', tt.id, 'sana', tt.sana, 'summa', tt.summa, 'fc_summa', tt.fc_summa, 'valyuta', tt.valyuta,
               'kassa_id', tt.kassa_id, 'kassa_nom', (select k.nom from ehson_kassa k where k.id = tt.kassa_id),
               'pul_turi', tt.pul_turi, 'izoh', tt.izoh, 'created_at', tt.created_at,
               'kim', (select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = tt.created_by)
             ) order by tt.sana desc, tt.created_at desc)
        from ehson_qarz_olingan_tolov tt where tt.olingan_id = q.id and tt.is_deleted = false), '[]'::jsonb)
  )
  from (select case when q.valyuta = 'USD' then coalesce(q.fc_summa, 0) else q.summa end as asosiy) a,
       (select coalesce(sum(case when q.valyuta = 'USD' then coalesce(t2.fc_summa, 0) else t2.summa end), 0) as qaytarildi
          from ehson_qarz_olingan_tolov t2 where t2.olingan_id = q.id and t2.is_deleted = false) t;
$fn$;
revoke all on function _ehson_qarz_olingan_qator(ehson_qarz_olingan) from public, anon, authenticated;

-- ######## 5) QARZ OLISH — pul ehson kassasiga KIRADI (qoldiq tekshiruvi YO'Q: kirim) ########
--  Kodlar: ruxsat · takror · kimdan_kerak · izoh_kerak · muddat_notogri · kassa_tanlanmagan · kassa_topilmadi · kassa_konteyner ·
--          pul_turi_kerak · pul_turi_topilmadi · summa_notogri · kurs_yoq
create or replace function ehson_qarz_olish(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid        uuid    := auth.uid();
  v_kassa      uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_summa      numeric := nullif(p->>'summa', '')::numeric;
  v_fc_p       numeric := nullif(p->>'fc_summa', '')::numeric;
  v_pul_turi_p text    := nullif(p->>'pul_turi', '');
  v_sana       date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_ism        text    := nullif(btrim(coalesce(p->>'ism', '')), '');
  v_tel        text    := nullif(btrim(coalesce(p->>'telefon', '')), '');
  v_muddat     date    := nullif(p->>'muddat', '')::date;
  v_izoh       text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_ext        text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  v_kassa_r    ehson_kassa;
  v_pt         ehson_pul_turi;
  v_pt_cnt     int;
  v_kurs       numeric;
  v_valyuta    text := 'UZS';
  v_id         uuid;
  v_exist      uuid;
  v_cnt        int;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Avtorizatsiya kerak'); end if;
  if not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Ehson sahifasi ruxsatingizda yoq'); end if;

  if v_ext is not null then
    select id into v_exist from ehson_qarz_olingan where ext_ref = v_ext;
    if found then return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist); end if;
  end if;

  -- majburiy: kimdan + izoh (server tomonida; jadvalda ham check)
  if v_ism is null or length(v_ism) < 2 then return jsonb_build_object('ok', false, 'kod', 'kimdan_kerak'); end if;
  if v_izoh is null or length(v_izoh) < 3 then return jsonb_build_object('ok', false, 'kod', 'izoh_kerak'); end if;
  if v_muddat is not null and v_muddat < v_sana then return jsonb_build_object('ok', false, 'kod', 'muddat_notogri'); end if;

  -- qabul qiluvchi kassa FAQAT ehson kassasi (ehson_qarz_ber bilan bir xil tanlov)
  if v_kassa is null then
    select count(*) into v_cnt from ehson_kassa where is_active and not is_container;
    if v_cnt = 1 then
      select id into v_kassa from ehson_kassa where is_active and not is_container;
    else
      return jsonb_build_object('ok', false, 'kod', 'kassa_tanlanmagan');
    end if;
  end if;
  select * into v_kassa_r from ehson_kassa where id = v_kassa and is_active;
  if not found then return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi'); end if;
  if v_kassa_r.is_container then return jsonb_build_object('ok', false, 'kod', 'kassa_konteyner'); end if;

  -- pul turi + valyuta/kurs (ehson_qarz_ber bilan bir xil)
  select count(*) into v_pt_cnt from ehson_pul_turi where kassa_id = v_kassa and is_active;
  if v_pt_cnt > 0 then
    if v_pul_turi_p is null then return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak'); end if;
    select * into v_pt from ehson_pul_turi where kassa_id = v_kassa and kod = v_pul_turi_p and is_active;
    if not found then return jsonb_build_object('ok', false, 'kod', 'pul_turi_topilmadi'); end if;
    v_valyuta := coalesce(v_pt.valyuta, 'UZS');
    if v_valyuta = 'USD' then
      if v_fc_p is null or v_fc_p <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
      v_kurs := null;
      if exists (select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
                  where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs' and oidvectortypes(pr.proargtypes) = 'text') then
        execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
      end if;
      if v_kurs is null or v_kurs <= 0 then return jsonb_build_object('ok', false, 'kod', 'kurs_yoq'); end if;
      v_summa := round(v_fc_p * v_kurs);
    else
      v_fc_p := null;
      if v_summa is null or v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    end if;
  else
    v_pul_turi_p := null; v_fc_p := null;
    if v_summa is null or v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
  end if;

  insert into ehson_qarz_olingan (kassa_id, pul_turi, valyuta, summa, fc_summa, ism, telefon, muddat, sana, izoh, holat, ext_ref, created_by)
  values (v_kassa, v_pul_turi_p, v_valyuta, v_summa, v_fc_p, v_ism, v_tel, v_muddat, v_sana, v_izoh, 'faol', v_ext, v_uid)
  returning id into v_id;

  perform _ehson_tarix_yoz('qarz_olingan', v_id, 'yaratildi',
    jsonb_build_object('kassa_id', v_kassa, 'pul_turi', v_pul_turi_p, 'summa', v_summa, 'fc_summa', v_fc_p,
                       'valyuta', v_valyuta, 'ism', v_ism, 'muddat', v_muddat));
  return jsonb_build_object('ok', true, 'id', v_id);
exception
  when unique_violation then
    select id into v_exist from ehson_qarz_olingan where ext_ref = v_ext;
    return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;
revoke all on function ehson_qarz_olish(jsonb) from public, anon;
grant execute on function ehson_qarz_olish(jsonb) to authenticated;

-- ######## 6) QAYTARISH — pul ehson kassasidan qarz beruvchiga CHIQADI (qoldiq tekshiruvi YO'Q: manfiy mumkin) ########
--  Kodlar: ruxsat · takror · topilmadi · holat · kassa_topilmadi · pul_turi_kerak · pul_turi_topilmadi · valyuta_mos_emas ·
--          summa_notogri · kurs_yoq · kop (+qoldi)
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
  if v_birlik > v_qoldi + 0.009 then
    return jsonb_build_object('ok', false, 'kod', 'kop', 'qoldi', v_qoldi);
  end if;

  insert into ehson_qarz_olingan_tolov (olingan_id, kassa_id, pul_turi, valyuta, summa, fc_summa, sana, izoh, ext_ref, created_by)
  values (q.id, v_kassa, v_pt_p, q.valyuta, v_summa, v_fc_p, v_sana, v_izoh, v_ext, v_uid)
  returning id into v_id;

  v_all := (v_qoldi - v_birlik) <= 0.009;
  if v_all then
    update ehson_qarz_olingan set holat = 'yopildi', yopilgan_at = now() where id = q.id;
  end if;

  perform _ehson_tarix_yoz('qarz_olingan_tolov', v_id, 'tolov',
    jsonb_build_object('olingan_id', q.id, 'kassa_id', v_kassa, 'pul_turi', v_pt_p, 'summa', v_summa, 'fc_summa', v_fc_p, 'yopildi', v_all));
  return jsonb_build_object('ok', true, 'id', v_id, 'holat', case when v_all then 'yopildi' else 'faol' end,
                            'qoldi', greatest(v_qoldi - v_birlik, 0));
exception
  when unique_violation then
    select id into v_exist from ehson_qarz_olingan_tolov where ext_ref = v_ext;
    return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;
revoke all on function ehson_qarz_olish_qaytar(jsonb) from public, anon;
grant execute on function ehson_qarz_olish_qaytar(jsonb) to authenticated;

-- ######## 7) BEKOR (qaytarish yo'q bo'lsa; admin yoki yaratgan) ########
create or replace function ehson_qarz_olish_bekor(p_id uuid, p_sabab text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  q ehson_qarz_olingan;
  v_sabab text := nullif(btrim(coalesce(p_sabab, '')), '');
begin
  if v_uid is null or not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  if v_sabab is null or length(v_sabab) < 3 then return jsonb_build_object('ok', false, 'kod', 'sabab_kerak'); end if;
  select * into q from ehson_qarz_olingan where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if q.holat <> 'faol' then return jsonb_build_object('ok', false, 'kod', 'holat'); end if;
  if not (_ehson_is_admin() or q.created_by = v_uid) then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  if exists (select 1 from ehson_qarz_olingan_tolov where olingan_id = q.id and is_deleted = false) then
    return jsonb_build_object('ok', false, 'kod', 'tolov_bor');
  end if;
  update ehson_qarz_olingan set holat = 'bekor', bekor_sabab = v_sabab, bekor_by = v_uid, bekor_at = now() where id = q.id;
  perform _ehson_tarix_yoz('qarz_olingan', q.id, 'bekor', jsonb_build_object('sabab', v_sabab));
  return jsonb_build_object('ok', true, 'id', q.id);
end
$fn$;
revoke all on function ehson_qarz_olish_bekor(uuid, text) from public, anon;
grant execute on function ehson_qarz_olish_bekor(uuid, text) to authenticated;

-- ######## 8) RO'YXAT + STAT ########
--  p: holat? (faol|kechikkan|yopildi|bekor) · q? (ism/telefon/izoh) · kassa_id? · limit? · offset?
--  stat har doim kassa filtri bo'yicha, holat/qidiruvdan qat'i nazar (dash kartasi shundan oladi).
create or replace function ehson_qarz_olish_royxat(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_holat  text := nullif(p->>'holat', '');
  v_q      text := nullif(btrim(coalesce(p->>'q', '')), '');
  v_kassa  uuid := nullif(p->>'kassa_id', '')::uuid;
  v_limit  int  := least(greatest(coalesce(nullif(p->>'limit', '')::int, 50), 1), 500);
  v_offset int  := greatest(coalesce(nullif(p->>'offset', '')::int, 0), 0);
  v_today  date := (now() at time zone 'Asia/Tashkent')::date;
  v_rows   jsonb; v_jami int; v_stat jsonb;
begin
  if auth.uid() is null or not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;

  with f as (
    select q.id, q.holat, q.sana, q.created_at
      from ehson_qarz_olingan q
     where (v_kassa is null or q.kassa_id = v_kassa)
       and (v_holat is null
            or (v_holat = 'kechikkan' and q.holat = 'faol' and q.muddat is not null and q.muddat < v_today)
            or (v_holat <> 'kechikkan' and q.holat = v_holat))
       and (v_q is null or coalesce(q.ism, '') || ' ' || coalesce(q.telefon, '') ilike '%' || v_q || '%' or q.izoh ilike '%' || v_q || '%')
  )
  select coalesce((
           -- 🔴 _ehson_qarz_olingan_qator(q.*) — jadvalning O'Z qatori
           select jsonb_agg(_ehson_qarz_olingan_qator(q.*) order by (x.holat = 'faol') desc, x.sana desc, x.created_at desc)
             from (select f.id, f.holat, f.sana, f.created_at from f
                    order by (f.holat = 'faol') desc, f.sana desc, f.created_at desc
                    limit v_limit offset v_offset) x
             join ehson_qarz_olingan q on q.id = x.id
         ), '[]'::jsonb),
         (select count(*) from f)
    into v_rows, v_jami;

  select jsonb_build_object(
           'faol_soni',      count(*) filter (where b.holat = 'faol'),
           'kechikkan_soni', count(*) filter (where b.holat = 'faol' and b.muddat is not null and b.muddat < v_today),
           'yopildi_soni',   count(*) filter (where b.holat = 'yopildi'),
           'ochiq_uzs',      coalesce(sum(case when b.holat = 'faol' and b.valyuta <> 'USD'
                                               then b.summa - coalesce((select sum(t.summa) from ehson_qarz_olingan_tolov t where t.olingan_id = b.id and not t.is_deleted), 0) end), 0),
           'ochiq_usd',      coalesce(sum(case when b.holat = 'faol' and b.valyuta = 'USD'
                                               then coalesce(b.fc_summa, 0) - coalesce((select sum(coalesce(t.fc_summa, 0)) from ehson_qarz_olingan_tolov t where t.olingan_id = b.id and not t.is_deleted), 0) end), 0)
         )
    into v_stat
    from ehson_qarz_olingan b
   where (v_kassa is null or b.kassa_id = v_kassa);

  return jsonb_build_object('ok', true, 'rows', v_rows, 'jami', v_jami, 'stat', v_stat);
end
$fn$;
revoke all on function ehson_qarz_olish_royxat(jsonb) from public, anon;
grant execute on function ehson_qarz_olish_royxat(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- ######## 9) TEKSHIRUV (faqat o'qish) ########
select (select count(*) from ehson_qarz_olingan) as olingan_soni,
       (select count(*) from ehson_qarz) as berilgan_qarz_soni,
       (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_schema = 'public' and table_name = 'v_ehson_kassa_pul') as pul_view_ustunlar;
