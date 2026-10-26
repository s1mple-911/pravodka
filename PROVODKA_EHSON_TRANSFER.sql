-- ============================================================================
--  PROVODKA_EHSON_TRANSFER.sql — 2026-10-26 — Ehson kassalari ORASIDA o'tkazma + yangi kassa «Dilnoza Nazarova»
--  Asilbek: «ehson kassalar o'rtasida tranzaksiya qilish imkoni kerak (Ehson soliq -> Zakot), yangi kassa Dilnoza Nazarova».
--
--  Qarorlar:
--   - Pul Ehson ICHIDA qoladi: faqat `ehson_transfer` jadvali, entry/entry_line/accounts ga TEGILMAYDI (ehson izolyatsiyasi).
--     Chiqqan kassa qoldig'i kamayadi, kirgan kassa qoldig'i oshadi — umumiy Ehson jami O'ZGARMAYDI.
--   - Faqat BIR XIL valyuta (naqd->naqd, dollar->dollar). Konvert (dollar->naqd) YO'Q — kurs tanlash alohida masala.
--   - Ruxsat: ehson sahifasi (ehson_page_ok) — berish kim qila olsa, o'tkazmani ham u qiladi. Bekor — faqat admin.
--   - Qoldiq: v_ehson_kassa_pul / v_ehson_kassa qayta e'lon — ustunlar OXIRIGA tr_chiqdi/tr_kirdi (+fc) qo'shildi,
--     qoldiq = kirim - berildi - qarz_berildi + qarz_qaytdi - tr_chiqdi + tr_kirdi. Eski ustunlar tegilmagan ->
--     ehson_dash / ehson_ber / ehson_qarz_ber / ehson_kassa_daraxt / ehson_kassa_saqla avtomat to'g'ri qoldiq oladi.
--   - Yangi kassa «Dilnoza Nazarova»: ehson_kassa_saqla bilan BIR XIL shaklda (ildiz child + 94xx modda + 4 pul turi),
--     idempotent (nom bo'yicha). Admin UI'dan ham qo'shsa bo'lardi — SQL'da qo'shildi, Asilbek so'ragan.
--
--  Old shart: PROVODKA_EHSON.sql -> ZAKOT -> QARZ (v_ehson_kassa_pul ning qarz versiyasi). Asilbek RUN qiladi.
--  Bo'limlar: 0 old shart · 1 jadval + RLS · 2 tarix check · 3 view'lar · 4 ehson_transfer_yoz · 5 ehson_transfer_bekor ·
--             6 ehson_transfer_royxat · 7 yangi kassa · 8 tekshiruv
-- ============================================================================

-- ######## 0) OLD SHART ########
do $eht_pre$
begin
  if to_regclass('public.ehson_kassa') is null or to_regclass('public.ehson_pul_turi') is null then
    raise exception 'ehson_kassa / ehson_pul_turi yoq — avval PROVODKA_EHSON.sql va PROVODKA_EHSON_ZAKOT.sql';
  end if;
  if to_regclass('public.ehson_qarz') is null or to_regclass('public.ehson_qarz_tolov') is null then
    raise exception 'ehson_qarz yoq — avval PROVODKA_EHSON_QARZ.sql (qoldiq view shu versiyadan davom etadi)';
  end if;
  if to_regprocedure('public._ehson_tarix_yoz(text,uuid,text,jsonb)') is null then
    raise exception '_ehson_tarix_yoz yoq';
  end if;
  if to_regprocedure('public._ehson_xarajat_modda(uuid)') is null then
    raise exception '_ehson_xarajat_modda yoq — avval PROVODKA_EHSON_ZAKOT.sql';
  end if;
  if to_regprocedure('public.ehson_page_ok()') is null or to_regprocedure('public._ehson_is_admin()') is null then
    raise exception 'ehson_page_ok / _ehson_is_admin yoq';
  end if;
end
$eht_pre$;

-- ######## 1) JADVAL ########
create table if not exists ehson_transfer (
  id             uuid        primary key default gen_random_uuid(),
  from_kassa_id  uuid        not null references ehson_kassa(id),
  from_pul_turi  text        not null,
  to_kassa_id    uuid        not null references ehson_kassa(id),
  to_pul_turi    text        not null,
  valyuta        text        not null default 'UZS',
  summa          numeric     not null check (summa > 0),          -- so'm ekvivalenti (USD'da kurs bilan)
  fc_summa       numeric     check (fc_summa is null or fc_summa > 0),   -- USD miqdori (valyuta='USD')
  sana           date        not null default ((now() at time zone 'Asia/Tashkent')::date),
  izoh           text,
  ext_ref        text        unique,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  is_deleted     boolean     not null default false,
  deleted_by     uuid,
  deleted_at     timestamptz,
  bekor_sabab    text,
  constraint ehson_transfer_turli_check check (from_kassa_id <> to_kassa_id or from_pul_turi <> to_pul_turi)
);
create index if not exists ehson_transfer_from_idx on ehson_transfer (from_kassa_id, from_pul_turi) where is_deleted = false;
create index if not exists ehson_transfer_to_idx   on ehson_transfer (to_kassa_id, to_pul_turi)     where is_deleted = false;
create index if not exists ehson_transfer_sana_idx on ehson_transfer (sana desc, created_at desc);

comment on table ehson_transfer is
  'Ehson jamg''arma kassalari ORASIDA o''tkazma (Ehson soliq -> Zakot). Faqat Ehson ichki hisobi — entry/accounts ga tegmaydi, '
  'umumiy Ehson jami o''zgarmaydi. Bir xil valyuta. summa = so''m ekvivalenti, fc_summa = USD. Soft-bekor (is_deleted).';

-- RLS — ehson jadvallari naqshi: faqat select (ehson_page_ok), yozish faqat RPC
alter table ehson_transfer enable row level security;
revoke all on table ehson_transfer from public, anon;
grant select on table ehson_transfer to authenticated;
drop policy if exists ehson_transfer_select on ehson_transfer;
create policy ehson_transfer_select on ehson_transfer for select to authenticated using (ehson_page_ok());

-- ######## 2) ehson_tarix.obyekt check'iga 'transfer' (constraint nomi pg_constraint dan — qarz naqshi) ########
do $eht_tarix$
declare v_name text; v_def text; v_list text;
begin
  select conname, pg_get_constraintdef(oid) into v_name, v_def
    from pg_constraint
   where conrelid = 'public.ehson_tarix'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%obyekt%'
   limit 1;
  if v_name is not null and v_def not like '%''transfer''%' then
    -- 🔴 MAVJUD ro'yxat constraint tanasidan o'qiladi (qattiq yozilmaydi): QARZ fayli 'pul_turi' ni tushirib qoldirgan edi
    --    (ZAKOT qo'shgan, ehson_pul_turi_saqla yozadi) — shu yerda u ham, boshqa har qanday qiymat ham qaytariladi.
    select string_agg(distinct quote_literal(m[1]), ',')
      into v_list
      from regexp_matches(v_def, '''([a-z_]+)''', 'g') as m;
    v_list := coalesce(v_list, '''oila'',''azo'',''berish'',''kirim'',''reja'',''kassa''');
    foreach v_name in array array['pul_turi', 'qarz', 'qarz_tolov', 'transfer'] loop
      if position(quote_literal(v_name) in v_list) = 0 then
        v_list := v_list || ',' || quote_literal(v_name);
      end if;
    end loop;
    select conname into v_name from pg_constraint
     where conrelid = 'public.ehson_tarix'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%obyekt%' limit 1;
    execute format('alter table ehson_tarix drop constraint %I', v_name);
    execute 'alter table ehson_tarix add constraint ehson_tarix_obyekt_check check (obyekt in (' || v_list || '))';
  end if;
end
$eht_tarix$;

-- ######## 3) QOLDIQ VIEW'LARI — o'tkazma chiqimi/kirimi (ustunlar OXIRIGA qo'shildi) ########
create or replace view v_ehson_kassa_pul as
select
  x.kassa_id,
  x.pul_turi,
  x.valyuta,
  sum(x.kirim)                                                              as kirim,
  sum(x.berildi)                                                            as berildi,
  sum(x.kirim) - sum(x.berildi) - sum(x.qarz_berildi) + sum(x.qarz_qaytdi)
    - sum(x.tr_chiqdi) + sum(x.tr_kirdi)                                    as qoldiq,
  sum(x.fc_kirim)                                                           as fc_kirim,
  sum(x.fc_berildi)                                                         as fc_berildi,
  sum(x.fc_kirim) - sum(x.fc_berildi) - sum(x.fc_qarz_berildi) + sum(x.fc_qarz_qaytdi)
    - sum(x.fc_tr_chiqdi) + sum(x.fc_tr_kirdi)                              as fc_qoldiq,
  sum(x.qarz_berildi)                                                       as qarz_berildi,
  sum(x.qarz_qaytdi)                                                        as qarz_qaytdi,
  sum(x.fc_qarz_berildi)                                                    as fc_qarz_berildi,
  sum(x.fc_qarz_qaytdi)                                                     as fc_qarz_qaytdi,
  sum(x.tr_chiqdi)                                                          as tr_chiqdi,
  sum(x.tr_kirdi)                                                           as tr_kirdi,
  sum(x.fc_tr_chiqdi)                                                       as fc_tr_chiqdi,
  sum(x.fc_tr_kirdi)                                                        as fc_tr_kirdi
from (
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS') as valyuta,
         summa as kirim, 0::numeric as berildi, 0::numeric as qarz_berildi, 0::numeric as qarz_qaytdi,
         coalesce(fc_summa, 0) as fc_kirim, 0::numeric as fc_berildi, 0::numeric as fc_qarz_berildi, 0::numeric as fc_qarz_qaytdi,
         0::numeric as tr_chiqdi, 0::numeric as tr_kirdi, 0::numeric as fc_tr_chiqdi, 0::numeric as fc_tr_kirdi
    from ehson_kirim where is_deleted = false
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, summa, 0, 0,
         0, coalesce(fc_summa, 0), 0, 0,
         0, 0, 0, 0
    from ehson_berish where holat = 'berildi'
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, summa, 0,
         0, 0, coalesce(fc_summa, 0), 0,
         0, 0, 0, 0
    from ehson_qarz where holat in ('faol', 'yopildi')
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, 0, summa,
         0, 0, 0, coalesce(fc_summa, 0),
         0, 0, 0, 0
    from ehson_qarz_tolov where is_deleted = false
  union all
  -- o'tkazma: chiqqan kassa
  select from_kassa_id, from_pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, 0, 0,
         0, 0, 0, 0,
         summa, 0, coalesce(fc_summa, 0), 0
    from ehson_transfer where is_deleted = false
  union all
  -- o'tkazma: kirgan kassa
  select to_kassa_id, to_pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, 0, 0,
         0, 0, 0, 0,
         0, summa, 0, coalesce(fc_summa, 0)
    from ehson_transfer where is_deleted = false
) x
group by x.kassa_id, x.pul_turi, x.valyuta;
alter view v_ehson_kassa_pul set (security_invoker = on);
revoke all on v_ehson_kassa_pul from public, anon;
grant select on v_ehson_kassa_pul to authenticated;
comment on view v_ehson_kassa_pul is
  'Har jamg''arma + pul turi kesimida kirim/berildi/qoldiq (so''m) va fc_* (dollar). 2026-10-26: qoldiq = kirim − berildi − '
  'qarz_berildi + qarz_qaytdi − tr_chiqdi + tr_kirdi (ehson_transfer). pul_turi null = eski yozuvlar.';

create or replace view v_ehson_kassa as
select k.id, k.nom, k.is_active,
  coalesce(ki.summa, 0) as kirim,
  coalesce(be.summa, 0) as berildi,
  coalesce(ki.summa, 0) - coalesce(be.summa, 0) - coalesce(qb.summa, 0) + coalesce(qq.summa, 0)
    - coalesce(tc.summa, 0) + coalesce(tk.summa, 0) as qoldiq,
  coalesce(qb.summa, 0) as qarz_berildi,
  coalesce(qq.summa, 0) as qarz_qaytdi,
  coalesce(tc.summa, 0) as tr_chiqdi,
  coalesce(tk.summa, 0) as tr_kirdi
from ehson_kassa k
left join lateral (select sum(summa) as summa from ehson_kirim       where kassa_id = k.id and is_deleted = false) ki on true
left join lateral (select sum(summa) as summa from ehson_berish      where kassa_id = k.id and holat = 'berildi') be on true
left join lateral (select sum(summa) as summa from ehson_qarz        where kassa_id = k.id and holat in ('faol','yopildi')) qb on true
left join lateral (select sum(summa) as summa from ehson_qarz_tolov  where kassa_id = k.id and is_deleted = false) qq on true
left join lateral (select sum(summa) as summa from ehson_transfer    where from_kassa_id = k.id and is_deleted = false) tc on true
left join lateral (select sum(summa) as summa from ehson_transfer    where to_kassa_id   = k.id and is_deleted = false) tk on true;
alter view v_ehson_kassa set (security_invoker = on);
revoke all on v_ehson_kassa from public, anon;
grant select on v_ehson_kassa to authenticated;

-- ######## 4) O'TKAZMA YOZISH ########
--  p = {from_kassa_id, from_pul_turi, to_kassa_id, to_pul_turi, summa (so'm) | fc_summa (USD), sana?, izoh?, ext_ref?}
--  -> {ok:true,id} | {ok:false,kod}  kod: takror · kassa_kerak · kassa_topilmadi · kassa_konteyner · pul_turi_kerak ·
--     bir_xil · valyuta_mos_emas · summa_notogri · kurs_yoq · sana_notogri · qoldiq_yetmaydi (+qoldiq)
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

  select coalesce(sum(qoldiq), 0), coalesce(sum(fc_qoldiq), 0) into v_qoldiq, v_fcq
    from v_ehson_kassa_pul
   where kassa_id = v_from and pul_turi = v_fpt and valyuta = coalesce(v_fp.valyuta, 'UZS');

  if coalesce(v_fp.valyuta, 'UZS') = 'USD' then
    if v_fcq < v_fc then
      return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmaydi', 'qoldiq', v_fcq, 'valyuta', 'USD');
    end if;
  else
    if v_qoldiq < v_summa then
      return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmaydi', 'qoldiq', v_qoldiq, 'valyuta', 'UZS');
    end if;
  end if;

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
comment on function ehson_transfer_yoz(jsonb) is
  'Ehson kassalari orasida o''tkazma (bir xil valyuta). Ruxsat ehson_page_ok(). Qoldiq v_ehson_kassa_pul kesimida, '
  'USD -> fc_summa + conv_baza_kurs. Faqat ehson_transfer ga yozadi — entry/accounts ga TEGMAYDI.';

-- ######## 5) BEKOR (soft) — faqat admin ########
create or replace function ehson_transfer_bekor(p_id uuid, p_sabab text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  t       ehson_transfer;
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

  -- qabul qilgan kassa bu pulni allaqachon berib/qarzga chiqarib yuborgan bo'lsa — bekor qilib bo'lmaydi
  select coalesce(sum(qoldiq), 0), coalesce(sum(fc_qoldiq), 0) into v_q, v_fcq
    from v_ehson_kassa_pul
   where kassa_id = t.to_kassa_id and pul_turi = t.to_pul_turi and valyuta = t.valyuta;
  if (t.valyuta = 'USD' and v_fcq - coalesce(t.fc_summa, 0) < 0) or (t.valyuta <> 'USD' and v_q - t.summa < 0) then
    return jsonb_build_object('ok', false, 'kod', 'qoldiq_manfiy');
  end if;

  update ehson_transfer
     set is_deleted = true, deleted_by = v_uid, deleted_at = now(), bekor_sabab = btrim(p_sabab)
   where id = p_id;

  perform _ehson_tarix_yoz('transfer', p_id, 'bekor', jsonb_build_object('sabab', btrim(p_sabab), 'summa', t.summa, 'fc_summa', t.fc_summa));
  return jsonb_build_object('ok', true);
end
$fn$;
revoke all on function ehson_transfer_bekor(uuid, text) from public, anon;
grant execute on function ehson_transfer_bekor(uuid, text) to authenticated;

-- ######## 6) RO'YXAT ########
--  p = {from?, to?, kassa_id? (chiqqan YOKI kirgan), q?, bekor? (default true — bekorlar ham), limit? (50, ≤200), offset?}
--  -> {ok, rows:[{id, sana, from_kassa_id, from_kassa_nom, from_pul_turi, from_pul_nom, to_kassa_id, to_kassa_nom, to_pul_turi,
--      to_pul_nom, valyuta, summa, fc_summa, izoh, kim, created_at, is_deleted, bekor_kim, bekor_sabab, deleted_at}], jami}
create or replace function ehson_transfer_royxat(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid    := auth.uid();
  v_from   date    := nullif(p->>'from', '')::date;
  v_to     date    := nullif(p->>'to', '')::date;
  v_q      text    := nullif(btrim(coalesce(p->>'q', '')), '');
  v_bekor  boolean := coalesce((p->>'bekor')::boolean, true);
  v_kassa  uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_limit  int     := greatest(1, least(coalesce(nullif(p->>'limit', '')::int, 50), 200));
  v_offset int     := greatest(0, coalesce(nullif(p->>'offset', '')::int, 0));
  v_rows   jsonb; v_jami int;
begin
  if v_uid is null or not ehson_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  with f as (
    select t.*,
           fk.nom as from_kassa_nom, tk.nom as to_kassa_nom,
           (select pt.nom from ehson_pul_turi pt where pt.kassa_id = t.from_kassa_id and pt.kod = t.from_pul_turi) as from_pul_nom,
           (select pt.nom from ehson_pul_turi pt where pt.kassa_id = t.to_kassa_id   and pt.kod = t.to_pul_turi)   as to_pul_nom
      from ehson_transfer t
      join ehson_kassa fk on fk.id = t.from_kassa_id
      join ehson_kassa tk on tk.id = t.to_kassa_id
     where (v_from is null or t.sana >= v_from)
       and (v_to   is null or t.sana <= v_to)
       and (v_bekor or not t.is_deleted)
       and (v_kassa is null or t.from_kassa_id = v_kassa or t.to_kassa_id = v_kassa)
       and (v_q is null or fk.nom ilike '%' || v_q || '%' or tk.nom ilike '%' || v_q || '%' or coalesce(t.izoh, '') ilike '%' || v_q || '%')
  )
  select coalesce((
           select jsonb_agg(jsonb_build_object(
                    'id', x.id, 'sana', x.sana,
                    'from_kassa_id', x.from_kassa_id, 'from_kassa_nom', x.from_kassa_nom, 'from_pul_turi', x.from_pul_turi, 'from_pul_nom', x.from_pul_nom,
                    'to_kassa_id',   x.to_kassa_id,   'to_kassa_nom',   x.to_kassa_nom,   'to_pul_turi',   x.to_pul_turi,   'to_pul_nom',   x.to_pul_nom,
                    'valyuta', x.valyuta, 'summa', x.summa, 'fc_summa', x.fc_summa, 'izoh', x.izoh,
                    'kim', (select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = x.created_by),
                    'created_at', x.created_at, 'is_deleted', x.is_deleted, 'deleted_at', x.deleted_at, 'bekor_sabab', x.bekor_sabab,
                    'bekor_kim', (select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = x.deleted_by)
                  ) order by x.sana desc, x.created_at desc)
             from (select * from f order by sana desc, created_at desc limit v_limit offset v_offset) x
         ), '[]'::jsonb),
         (select count(*) from f)
    into v_rows, v_jami;

  return jsonb_build_object('ok', true, 'rows', v_rows, 'jami', v_jami);
end
$fn$;
revoke all on function ehson_transfer_royxat(jsonb) from public, anon;
grant execute on function ehson_transfer_royxat(jsonb) to authenticated;

-- ######## 7) YANGI KASSA «Dilnoza Nazarova» — ehson_kassa_saqla shaklida, idempotent (nom bo'yicha) ########
do $eht_kassa$
declare
  v_root   uuid;
  v_id     uuid;
  v_tartib int;
begin
  select id into v_root from ehson_kassa where is_container and is_active order by created_at limit 1;
  if v_root is null then
    raise exception 'Ildiz (konteyner) jamg''arma topilmadi — avval PROVODKA_EHSON_ZAKOT.sql';
  end if;

  select id into v_id from ehson_kassa
   where parent_id = v_root and lower(btrim(nom)) = lower('Dilnoza Nazarova') limit 1;

  if v_id is null then
    select coalesce(max(tartib), 0) + 1 into v_tartib from ehson_kassa where parent_id = v_root;
    insert into ehson_kassa (nom, izoh, is_active, parent_id, is_container, tartib)
    values ('Dilnoza Nazarova', 'Ehson kassasi (2026-10-26, Asilbek)', true, v_root, false, v_tartib)
    returning id into v_id;
    perform _ehson_tarix_yoz('kassa', v_id, 'yaratildi', jsonb_build_object('nom', 'Dilnoza Nazarova', 'manba', 'PROVODKA_EHSON_TRANSFER.sql'));
    raise notice 'Yangi kassa yaratildi: Dilnoza Nazarova (%)', v_id;
  else
    -- qayta RUN: mavjud kassaga tegilmaydi (admin nofaol qilgan bo'lsa, qayta yoqilmaydi)
    raise notice 'Kassa allaqachon bor: Dilnoza Nazarova (%)', v_id;
  end if;

  perform _ehson_xarajat_modda(v_id);

  insert into ehson_pul_turi (kassa_id, kod, nom, valyuta, tartib)
  select v_id, x.kod, x.nom, x.valyuta, x.tartib
    from (values
      ('naqd',   'Naqd',   'UZS', 1),
      ('dollar', 'Dollar', 'USD', 2),
      ('karta',  'Karta',  'UZS', 3),
      ('click',  'Click',  'UZS', 4)
    ) as x(kod, nom, valyuta, tartib)
   on conflict (kassa_id, kod) do nothing;
end
$eht_kassa$;

notify pgrst, 'reload schema';

-- ######## 8) TEKSHIRUV ########
select k.nom, k.is_active, k.tartib, vk.qoldiq,
       (select string_agg(pt.kod, ',' order by pt.tartib) from ehson_pul_turi pt where pt.kassa_id = k.id) as pul_turlari,
       (select a.code || ' ' || a.name from accounts a where a.id = k.xarajat_account_id) as modda
  from ehson_kassa k join v_ehson_kassa vk on vk.id = k.id
 where k.parent_id is not null and not k.is_container
 order by k.tartib, k.nom;

select (select count(*) from ehson_transfer) as transfer_soni,
       (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_name = 'v_ehson_kassa_pul') as pul_view_ustunlar;
