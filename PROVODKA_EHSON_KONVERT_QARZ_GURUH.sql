-- ============================================================================
--  PROVODKA_EHSON_KONVERT_QARZ_GURUH.sql — 2026-10-26 — Ehson: KONVERT ($ ↔ so'm) + QARZLAR qarzdor bo'yicha BITTA umumiy
--  Asilbek: «qarz berishda avval qarz bergan odamga ham yana qarz berish; yangi qarz o'z muddati bilan yoziladi, lekin
--  1 ta umumiy bo'lib saqlanadi — ustiga bosganda qaysi qarz muddati qachon ekani chiqadi. Ehson kassalari uchun konvert
--  ham kerak — kassadagi $ ni so'mga qilish».
--
--  Qarorlar:
--   KONVERT — alohida jadval YO'Q: `ehson_transfer` ga ustunlar qo'shiladi (`turi` transfer|konvert, `kurs`, `to_valyuta`,
--     `to_summa`, `to_fc_summa`). Chiqqan tomon avvalgidek (valyuta/summa/fc_summa), kirgan tomon yangi ustunlardan.
--     Faqat USD ↔ UZS, kursni foydalanuvchi kiritadi (sukut `conv_baza_kurs('USD')` — `ehson_kurs_usd()`), so'm ekvivalenti
--     ikkala tomonda BIR XIL (summa = to_summa) → umumiy Ehson so'm jami o'zgarmaydi. Pul Ehson ICHIDA — entry/accounts
--     ga TEGILMAYDI (kompaniya konverti — konvert.html — bu emas). Bir kassa ichida ham (dollar → naqd), kassalar aro ham.
--   v_ehson_kassa_pul / v_ehson_kassa — kirgan tomon `coalesce(to_valyuta, valyuta)` / `coalesce(to_summa, summa)` /
--     to_fc_summa bilan. Ustunlar O'ZGARMAGAN (create or replace), eski transferlar (to_* null) avvalgidek.
--   ehson_transfer_bekor / ehson_transfer_royxat — qayta e'lon: kirgan tomon yangi ustunlardan, ro'yxatda turi/kurs/to_*.
--   QARZ GURUH — jadval o'zgarmaydi: har qarz o'z qatori (o'z muddati, grafigi, to'lovlari). Yangi RPC
--     `ehson_qarz_guruh_royxat` qarzdor (oila_id | shaxs ismi) + valyuta kesimida yig'adi: berildi/to'landi/qoldi jami,
--     eng yaqin keyingi sana, kechikkan, `qarzlar` (har qarz `_ehson_qarz_qator` bilan — muddatlari ko'rinadi).
--     `ehson_qarz_guruh_tolov` — umumiy qarzga to'lov: faol qarzlarga ENG ESKI SANADAN (FIFO) taqsimlanadi, har biri
--     `ehson_qarz_tolov` orqali (ext_ref = asosiy:qarz_id), biri yiqilsa hammasi qaytariladi.
--
--   🔴 Ma'lum xususiyat: USD pul turining SO'M qoldig'i (view `qoldiq`) kirim kursida, konvert esa foydalanuvchi kursida yoziladi —
--     dollar to'liq konvert qilinsa `fc_qoldiq`=0, lekin so'm `qoldiq` kurs farqicha qolishi mumkin (umumiy Ehson so'm jami to'g'ri).
--     Dollar hisobida haqiqiy qoldiq = fc_qoldiq. (ehson_pul_turi o'chirishdagi `qoldiq<>0` tekshiruvi shunga urilishi mumkin.)
--  Old shart: PROVODKA_EHSON_TRANSFER.sql (ehson_transfer, view'larning transfer versiyasi). Additive, idempotent.
--  Bo'limlar: 0 old shart · 1 ehson_transfer ustunlari · 2 view'lar · 3 ehson_kurs_usd · 4 ehson_konvert_yoz ·
--             5 ehson_transfer_bekor · 6 ehson_transfer_royxat · 7 ehson_qarz_guruh_royxat · 8 ehson_qarz_guruh_tolov · 9 tekshiruv
-- ============================================================================

-- ######## 0) OLD SHART ########
do $ehc_pre$
begin
  if to_regclass('public.ehson_transfer') is null then
    raise exception 'ehson_transfer yoq — avval PROVODKA_EHSON_TRANSFER.sql';
  end if;
  if to_regclass('public.ehson_qarz') is null or to_regclass('public.ehson_qarz_jadval') is null then
    raise exception 'ehson_qarz yoq — avval PROVODKA_EHSON_QARZ.sql';
  end if;
  if to_regprocedure('public._ehson_qarz_qator(ehson_qarz)') is null then
    raise exception '_ehson_qarz_qator yoq — avval PROVODKA_EHSON_QARZ.sql';
  end if;
  if to_regprocedure('public.ehson_qarz_tolov(jsonb)') is null then
    raise exception 'ehson_qarz_tolov yoq — avval PROVODKA_EHSON_QARZ.sql';
  end if;
  if to_regprocedure('public._ehson_tarix_yoz(text,uuid,text,jsonb)') is null then
    raise exception '_ehson_tarix_yoz yoq';
  end if;
  if to_regprocedure('public.ehson_page_ok()') is null or to_regprocedure('public._ehson_is_admin()') is null then
    raise exception 'ehson_page_ok / _ehson_is_admin yoq';
  end if;
end
$ehc_pre$;

-- ######## 1) ehson_transfer — konvert ustunlari ########
alter table ehson_transfer add column if not exists turi        text    not null default 'transfer';
alter table ehson_transfer add column if not exists kurs        numeric;            -- konvertda: 1 USD = kurs so'm
alter table ehson_transfer add column if not exists to_valyuta  text;               -- null = valyuta bilan bir xil (transfer)
alter table ehson_transfer add column if not exists to_summa    numeric;            -- kirgan tomon so'm ekvivalenti (null = summa)
alter table ehson_transfer add column if not exists to_fc_summa numeric;            -- kirgan tomon USD (to_valyuta='USD')
do $ehc_turi$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.ehson_transfer'::regclass and conname = 'ehson_transfer_turi_check') then
    alter table ehson_transfer add constraint ehson_transfer_turi_check check (turi in ('transfer', 'konvert'));
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.ehson_transfer'::regclass and conname = 'ehson_transfer_konvert_check') then
    alter table ehson_transfer add constraint ehson_transfer_konvert_check check (
      (turi = 'transfer' and kurs is null and to_valyuta is null and to_summa is null and to_fc_summa is null) or
      (turi = 'konvert'  and kurs > 0 and to_valyuta is not null and to_valyuta <> valyuta and to_summa > 0)
    );
  end if;
end
$ehc_turi$;
comment on column ehson_transfer.turi is 'transfer = bir xil valyuta o''tkazma; konvert = USD<->UZS, kurs bilan (2026-10-26)';
comment on column ehson_transfer.to_summa is 'Kirgan tomon so''m ekvivalenti; null = summa (transfer). Konvertda summa = to_summa (umumiy so''m jami o''zgarmaydi)';

-- ######## 2) QOLDIQ VIEW'LARI — kirgan tomon to_* ustunlardan (ustunlar o'zgarmagan) ########
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
  -- o'tkazma / konvert: chiqqan kassa (avvalgidek)
  select from_kassa_id, from_pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, 0, 0,
         0, 0, 0, 0,
         summa, 0, coalesce(fc_summa, 0), 0
    from ehson_transfer where is_deleted = false
  union all
  -- o'tkazma / konvert: kirgan kassa — 2026-10-26: konvertda boshqa valyuta (to_valyuta) va to_summa/to_fc_summa
  select to_kassa_id, to_pul_turi, coalesce(to_valyuta, valyuta, 'UZS'),
         0, 0, 0, 0,
         0, 0, 0, 0,
         0, coalesce(to_summa, summa), 0,
         case when coalesce(to_valyuta, valyuta, 'UZS') = 'USD' then coalesce(to_fc_summa, fc_summa, 0) else 0 end
    from ehson_transfer where is_deleted = false
) x
group by x.kassa_id, x.pul_turi, x.valyuta;
alter view v_ehson_kassa_pul set (security_invoker = on);
revoke all on v_ehson_kassa_pul from public, anon;
grant select on v_ehson_kassa_pul to authenticated;
comment on view v_ehson_kassa_pul is
  'Har jamg''arma + pul turi kesimida kirim/berildi/qoldiq (so''m) va fc_* (dollar). qoldiq = kirim − berildi − qarz_berildi + '
  'qarz_qaytdi − tr_chiqdi + tr_kirdi (ehson_transfer: transfer + konvert; kirgan tomon to_valyuta/to_summa/to_fc_summa, 2026-10-26).';

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
left join lateral (select sum(coalesce(to_summa, summa)) as summa from ehson_transfer where to_kassa_id = k.id and is_deleted = false) tk on true;
alter view v_ehson_kassa set (security_invoker = on);
revoke all on v_ehson_kassa from public, anon;
grant select on v_ehson_kassa to authenticated;

-- ######## 3) KURS (UI sukut qiymati) ########
create or replace function ehson_kurs_usd()
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v numeric;
begin
  if auth.uid() is null or not ehson_page_ok() then return null; end if;
  if exists (select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
              where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs' and oidvectortypes(pr.proargtypes) = 'text') then
    execute 'select conv_baza_kurs($1)' into v using 'USD';
  end if;
  return v;
end
$fn$;
revoke all on function ehson_kurs_usd() from public, anon;
grant execute on function ehson_kurs_usd() to authenticated;

-- ######## 4) KONVERT YOZISH ########
--  p = {from_kassa_id, from_pul_turi, to_kassa_id, to_pul_turi, summa (CHIQQAN valyutada: USD bo'lsa dollar, aks holda so'm),
--       kurs (1 USD = kurs so'm), sana?, izoh?, ext_ref?}
--  -> {ok:true, id, summa (so'm ekv.), fc_summa, to_valyuta, to_summa, to_fc_summa, kurs} | {ok:false, kod}
--  kod: takror · kassa_kerak · kassa_topilmadi · kassa_konteyner · pul_turi_kerak · valyuta_bir_xil (o'tkazma kerak) ·
--       valyuta_qollanmaydi (faqat USD<->UZS) · kurs_notogri · summa_notogri · sana_notogri · qoldiq_yetmaydi (+qoldiq, valyuta)
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

  select coalesce(sum(qoldiq), 0), coalesce(sum(fc_qoldiq), 0) into v_qoldiq, v_fcq
    from v_ehson_kassa_pul
   where kassa_id = v_from and pul_turi = v_fpt and valyuta = v_fval;

  if v_fval = 'USD' then
    if v_fcq < v_fc then
      return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmaydi', 'qoldiq', v_fcq, 'valyuta', 'USD');
    end if;
  else
    if v_qoldiq < v_uzs then
      return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmaydi', 'qoldiq', v_qoldiq, 'valyuta', 'UZS');
    end if;
  end if;

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

-- ######## 5) BEKOR — kirgan tomon to_* bilan (imzo o'zgarmagan) ########
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

  -- qabul qilgan kassa bu pulni allaqachon berib/qarzga/konvertga chiqarib yuborgan bo'lsa — bekor qilib bo'lmaydi
  v_tval := coalesce(t.to_valyuta, t.valyuta, 'UZS');
  select coalesce(sum(qoldiq), 0), coalesce(sum(fc_qoldiq), 0) into v_q, v_fcq
    from v_ehson_kassa_pul
   where kassa_id = t.to_kassa_id and pul_turi = t.to_pul_turi and valyuta = v_tval;
  if (v_tval = 'USD' and v_fcq - coalesce(t.to_fc_summa, t.fc_summa, 0) < 0)
     or (v_tval <> 'USD' and v_q - coalesce(t.to_summa, t.summa) < 0) then
    return jsonb_build_object('ok', false, 'kod', 'qoldiq_manfiy');
  end if;

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

-- ######## 6) RO'YXAT — + turi, kurs, to_valyuta, to_summa, to_fc_summa; filtr turi? ########
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
  v_turi   text    := nullif(p->>'turi', '');
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
       and (v_turi is null or t.turi = v_turi)
       and (v_q is null or fk.nom ilike '%' || v_q || '%' or tk.nom ilike '%' || v_q || '%' or coalesce(t.izoh, '') ilike '%' || v_q || '%')
  )
  select coalesce((
           select jsonb_agg(jsonb_build_object(
                    'id', x.id, 'sana', x.sana, 'turi', x.turi,
                    'from_kassa_id', x.from_kassa_id, 'from_kassa_nom', x.from_kassa_nom, 'from_pul_turi', x.from_pul_turi, 'from_pul_nom', x.from_pul_nom,
                    'to_kassa_id',   x.to_kassa_id,   'to_kassa_nom',   x.to_kassa_nom,   'to_pul_turi',   x.to_pul_turi,   'to_pul_nom',   x.to_pul_nom,
                    'valyuta', x.valyuta, 'summa', x.summa, 'fc_summa', x.fc_summa,
                    'kurs', x.kurs, 'to_valyuta', coalesce(x.to_valyuta, x.valyuta), 'to_summa', coalesce(x.to_summa, x.summa),
                    'to_fc_summa', case when coalesce(x.to_valyuta, x.valyuta) = 'USD' then coalesce(x.to_fc_summa, x.fc_summa) end,
                    'izoh', x.izoh,
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

-- ######## 7) QARZLAR — QARZDOR BO'YICHA GURUH (bitta umumiy qarz) ########
--  p = {holat? (faol | kechikkan | yopildi | bekor), q?, kassa_id?, oila_id?, ism?, limit? (50, ≤500), offset?}
--  -> {ok, rows:[{kalit, valyuta, qarzdor_turi, qarzdor_nom, oila_id, oila_kod, telefon, soni, faol_soni, berildi, tolandi,
--      qoldi, keyingi_sana, kechikkan_kun, kechikkan_summa, holat, oxirgi_sana, birinchi_sana, kassa_nomlar,
--      qarzlar:[_ehson_qarz_qator… (sana desc)]}], jami, stat:{faol_soni, kechikkan_soni, yopildi_soni, ochiq_uzs, ochiq_usd}}
--  Guruh kaliti: oila -> 'oila:<oila_id>', shaxs -> 'shaxs:<ism kichik harf>'. Bir qarzdorda USD va so'm qarz bo'lsa — ikki guruh.
--  berildi/tolandi/qoldi/… QARZ VALYUTASIDA (guruh valyutasi). Guruh holati: kechikkan (biror faol qarz kechikkan) > faol >
--  yopildi > bekor. holat='faol' filtri kechikkanlarni ham oladi (eski ro'yxat bilan bir xil).
create or replace function ehson_qarz_guruh_royxat(p jsonb default '{}'::jsonb)
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
  v_oila   uuid := nullif(p->>'oila_id', '')::uuid;
  v_ism    text := nullif(lower(btrim(coalesce(p->>'ism', ''))), '');
  v_limit  int  := least(greatest(coalesce(nullif(p->>'limit', '')::int, 50), 1), 500);
  v_offset int  := greatest(coalesce(nullif(p->>'offset', '')::int, 0), 0);
  v_today  date := (now() at time zone 'Asia/Tashkent')::date;
  v_rows   jsonb; v_jami int; v_stat jsonb;
begin
  if auth.uid() is null or not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;

  with l as (
    select q.id, q.qarzdor_turi, q.oila_id, q.ism, q.telefon, q.kassa_id, q.valyuta, q.holat, q.sana, q.created_at, q.izoh,
           case when q.qarzdor_turi = 'oila' then 'oila:' || q.oila_id::text
                else 'shaxs:' || lower(btrim(coalesce(q.ism, ''))) end as kalit,
           case when q.valyuta = 'USD' then coalesce(q.fc_summa, 0) else q.summa end as asosiy,
           (select coalesce(sum(case when q.valyuta = 'USD' then coalesce(t.fc_summa, 0) else t.summa end), 0)
              from ehson_qarz_tolov t where t.qarz_id = q.id and t.is_deleted = false) as tolandi,
           (select min(j.sana) from ehson_qarz_jadval j where j.qarz_id = q.id and j.tolangan < j.summa) as keyingi_sana,
           (select coalesce(sum(j.summa - j.tolangan), 0) from ehson_qarz_jadval j
             where j.qarz_id = q.id and j.tolangan < j.summa and j.sana < v_today) as kechikkan_summa,
           case when q.qarzdor_turi = 'oila' then (select o.fio from ehson_oila o where o.id = q.oila_id) else q.ism end as qarzdor_nom,
           (select o.oila_kod from ehson_oila o where o.id = q.oila_id) as oila_kod,
           (select k.nom from ehson_kassa k where k.id = q.kassa_id) as kassa_nom
      from ehson_qarz q
     where (v_kassa is null or q.kassa_id = v_kassa)
       and (v_oila is null or q.oila_id = v_oila)
       and (v_ism is null or (q.qarzdor_turi = 'shaxs' and lower(btrim(coalesce(q.ism, ''))) = v_ism))
  ),
  g as (
    select l.kalit, l.valyuta,
           max(l.qarzdor_turi) as qarzdor_turi,
           max(l.qarzdor_nom)  as qarzdor_nom,
           max(l.oila_id::text)::uuid as oila_id,
           max(l.oila_kod)     as oila_kod,
           (array_agg(l.telefon order by l.created_at desc) filter (where nullif(btrim(l.telefon), '') is not null))[1] as telefon,
           count(*) filter (where l.holat <> 'bekor') as soni,
           count(*) filter (where l.holat = 'faol')   as faol_soni,
           coalesce(sum(l.asosiy)  filter (where l.holat in ('faol', 'yopildi')), 0) as berildi,
           coalesce(sum(l.tolandi) filter (where l.holat in ('faol', 'yopildi')), 0) as tolandi,
           coalesce(sum(greatest(l.asosiy - l.tolandi, 0)) filter (where l.holat = 'faol'), 0) as qoldi,
           min(l.keyingi_sana) filter (where l.holat = 'faol') as keyingi_sana,
           coalesce(sum(l.kechikkan_summa) filter (where l.holat = 'faol'), 0) as kechikkan_summa,
           max(l.sana) as oxirgi_sana, min(l.sana) as birinchi_sana, max(l.created_at) as oxirgi_at,
           string_agg(distinct l.kassa_nom, ', ') as kassa_nomlar,
           bool_or(l.holat = 'faol' and l.keyingi_sana < v_today) as kechikkan,
           bool_or(l.holat = 'faol')    as faol,
           bool_or(l.holat = 'yopildi') as yopildi,
           string_agg(coalesce(l.ism, '') || ' ' || coalesce(l.telefon, '') || ' ' || coalesce(l.izoh, ''), ' ') as qidiruv
      from l
     group by l.kalit, l.valyuta
  ),
  g2 as (
    select g.*,
           case when g.kechikkan then 'kechikkan' when g.faol then 'faol' when g.yopildi then 'yopildi' else 'bekor' end as holat,
           case when g.kechikkan then (v_today - g.keyingi_sana) else 0 end as kechikkan_kun
      from g
  ),
  f as (
    select * from g2
     where (v_holat is null
            or (v_holat = 'faol' and g2.holat in ('faol', 'kechikkan'))
            or (v_holat <> 'faol' and g2.holat = v_holat))
       and (v_q is null or coalesce(g2.qarzdor_nom, '') ilike '%' || v_q || '%'
            or coalesce(g2.oila_kod, '') ilike '%' || v_q || '%' or g2.qidiruv ilike '%' || v_q || '%')
  )
  select coalesce((
           select jsonb_agg(jsonb_build_object(
                    'kalit', x.kalit, 'valyuta', x.valyuta, 'qarzdor_turi', x.qarzdor_turi, 'qarzdor_nom', x.qarzdor_nom,
                    'oila_id', x.oila_id, 'oila_kod', x.oila_kod, 'telefon', x.telefon,
                    'soni', x.soni, 'faol_soni', x.faol_soni, 'berildi', x.berildi, 'tolandi', x.tolandi, 'qoldi', x.qoldi,
                    'keyingi_sana', x.keyingi_sana, 'kechikkan_kun', x.kechikkan_kun, 'kechikkan_summa', x.kechikkan_summa,
                    'holat', x.holat, 'oxirgi_sana', x.oxirgi_sana, 'birinchi_sana', x.birinchi_sana, 'kassa_nomlar', x.kassa_nomlar,
                    'qarzlar', coalesce((
                      select jsonb_agg(_ehson_qarz_qator(q.*) order by q.sana desc, q.created_at desc)
                        from ehson_qarz q
                       where q.valyuta = x.valyuta
                         and (case when q.qarzdor_turi = 'oila' then 'oila:' || q.oila_id::text
                                   else 'shaxs:' || lower(btrim(coalesce(q.ism, ''))) end) = x.kalit
                         and (v_kassa is null or q.kassa_id = v_kassa)), '[]'::jsonb)
                  ) order by (x.holat = 'kechikkan') desc, (x.holat = 'faol') desc, x.keyingi_sana asc nulls last, x.oxirgi_at desc, x.kalit)
             from (select * from f
                    order by (f.holat = 'kechikkan') desc, (f.holat = 'faol') desc, f.keyingi_sana asc nulls last, f.oxirgi_at desc, f.kalit
                    limit v_limit offset v_offset) x
         ), '[]'::jsonb),
         (select count(*) from f),
         -- stat — guruh darajasida (qarzdorlar soni), kassa filtri bo'yicha, holat/qidiruvdan qat'i nazar
         -- 🔴 SHU so'rov ichida (CTE g2 faqat o'z so'rovida bor — alohida select "relation g2 does not exist" berardi)
         (select jsonb_build_object(
                   'faol_soni',      count(*) filter (where g2.holat in ('faol', 'kechikkan')),
                   'kechikkan_soni', count(*) filter (where g2.holat = 'kechikkan'),
                   'yopildi_soni',   count(*) filter (where g2.holat = 'yopildi'),
                   'ochiq_uzs',      coalesce(sum(g2.qoldi) filter (where g2.valyuta <> 'USD'), 0),
                   'ochiq_usd',      coalesce(sum(g2.qoldi) filter (where g2.valyuta = 'USD'), 0))
            from g2)
    into v_rows, v_jami, v_stat;

  return jsonb_build_object('ok', true, 'rows', v_rows, 'jami', v_jami, 'stat', v_stat);
end
$fn$;
revoke all on function ehson_qarz_guruh_royxat(jsonb) from public, anon;
grant execute on function ehson_qarz_guruh_royxat(jsonb) to authenticated;

-- ######## 8) UMUMIY QARZGA TO'LOV — faol qarzlarga eng eski sanadan (FIFO), har biri ehson_qarz_tolov orqali ########
--  p = {kalit, valyuta, kassa_id?, pul_turi?, summa (so'm) | fc_summa (USD), sana?, izoh?, ext_ref}
--  -> {ok:true, tolovlar:[{qarz_id, summa (birlik), holat}], qoldi} | {ok:false, kod (+qarz_id)}
--  kod: ruxsat · kalit_kerak · topilmadi (faol qarz yo'q) · summa_notogri · kop (+qoldi) · ehson_qarz_tolov kodlari (valyuta_mos_emas,
--       kassa_topilmadi, pul_turi_kerak, kurs_yoq …) — biri yiqilsa HAMMASI qaytariladi (atomar).
create or replace function ehson_qarz_guruh_tolov(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid    := auth.uid();
  v_kalit   text    := nullif(btrim(coalesce(p->>'kalit', '')), '');
  v_val     text    := coalesce(nullif(p->>'valyuta', ''), 'UZS');
  v_summa   numeric := nullif(p->>'summa', '')::numeric;
  v_fc      numeric := nullif(p->>'fc_summa', '')::numeric;
  v_ext     text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  v_birlik  numeric;
  v_rem     numeric;
  v_jami    numeric := 0;
  v_qoldi_i numeric;
  v_port    numeric;
  v_sub     jsonb;
  v_r       jsonb;
  v_out     jsonb := '[]'::jsonb;
  qr        record;
  v_n       int := 0;
  v_detail  text;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Avtorizatsiya kerak'); end if;
  if not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Ehson sahifasi ruxsatingizda yoq'); end if;
  if v_kalit is null then return jsonb_build_object('ok', false, 'kod', 'kalit_kerak'); end if;
  if v_ext is null then return jsonb_build_object('ok', false, 'kod', 'ext_ref_kerak'); end if;
  -- takror (javob yo'qolib UI qayta yuborsa): qism to'lovlari ext_ref 'asosiy:qarz_id' bilan yozilgan
  if exists (select 1 from ehson_qarz_tolov t where t.ext_ref like v_ext || ':%') then
    return jsonb_build_object('ok', false, 'kod', 'takror');
  end if;

  v_birlik := case when v_val = 'USD' then v_fc else v_summa end;
  if v_birlik is null or v_birlik <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
  v_birlik := case when v_val = 'USD' then round(v_birlik, 2) else round(v_birlik) end;

  -- guruhning faol qarzlari (eng eski sanadan) qulflanadi, umumiy qoldiq hisoblanadi
  for qr in
    select q.id, q.sana, q.created_at,
           (select coalesce(sum(j.summa - j.tolangan), 0) from ehson_qarz_jadval j where j.qarz_id = q.id and j.tolangan < j.summa) as qoldi
      from ehson_qarz q
     where q.holat = 'faol' and q.valyuta = v_val
       and (case when q.qarzdor_turi = 'oila' then 'oila:' || q.oila_id::text
                 else 'shaxs:' || lower(btrim(coalesce(q.ism, ''))) end) = v_kalit
     order by q.sana, q.created_at
     for update of q
  loop
    v_n := v_n + 1;
    v_jami := v_jami + greatest(qr.qoldi, 0);
  end loop;
  if v_n = 0 then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if v_birlik > v_jami + 0.009 then return jsonb_build_object('ok', false, 'kod', 'kop', 'qoldi', v_jami); end if;

  v_rem := v_birlik;
  for qr in
    select q.id,
           (select coalesce(sum(j.summa - j.tolangan), 0) from ehson_qarz_jadval j where j.qarz_id = q.id and j.tolangan < j.summa) as qoldi
      from ehson_qarz q
     where q.holat = 'faol' and q.valyuta = v_val
       and (case when q.qarzdor_turi = 'oila' then 'oila:' || q.oila_id::text
                 else 'shaxs:' || lower(btrim(coalesce(q.ism, ''))) end) = v_kalit
     order by q.sana, q.created_at
  loop
    exit when v_rem <= 0.009;
    v_qoldi_i := greatest(qr.qoldi, 0);
    continue when v_qoldi_i <= 0;
    v_port := least(v_rem, v_qoldi_i);
    v_sub := jsonb_build_object('qarz_id', qr.id, 'ext_ref', v_ext || ':' || qr.id::text)
             || (p - 'kalit' - 'valyuta' - 'summa' - 'fc_summa' - 'ext_ref')
             || case when v_val = 'USD' then jsonb_build_object('fc_summa', v_port) else jsonb_build_object('summa', v_port) end;
    v_r := ehson_qarz_tolov(v_sub);
    if coalesce((v_r->>'ok')::boolean, false) = false and coalesce(v_r->>'kod', '') <> 'takror' then
      -- 🔴 biror qism yiqildi — butun to'lov bekor (exception blokida qaytariladi)
      raise exception using message = coalesce(v_r->>'kod', 'xato'), errcode = 'P0001', detail = qr.id::text;
    end if;
    v_out := v_out || jsonb_build_object('qarz_id', qr.id, 'summa', v_port, 'holat', coalesce(v_r->>'holat', 'faol'),
                                         'takror', coalesce(v_r->>'kod', '') = 'takror');
    v_rem := v_rem - v_port;
  end loop;

  return jsonb_build_object('ok', true, 'tolovlar', v_out, 'qoldi', greatest(v_jami - v_birlik, 0));
exception
  when others then
    if sqlstate = 'P0001' then
      get stacked diagnostics v_detail = pg_exception_detail;
      return jsonb_build_object('ok', false, 'kod', sqlerrm, 'qarz_id', nullif(v_detail, ''));
    end if;
    raise;
end
$fn$;
revoke all on function ehson_qarz_guruh_tolov(jsonb) from public, anon;
grant execute on function ehson_qarz_guruh_tolov(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- ######## 9) TEKSHIRUV ########
select (select count(*) from ehson_transfer) as transfer_soni,
       (select count(*) from ehson_transfer where turi = 'konvert') as konvert_soni,
       (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_name = 'ehson_transfer' and column_name in ('turi','kurs','to_valyuta','to_summa','to_fc_summa')) as yangi_ustunlar,
       ehson_kurs_usd() as kurs_usd,
       (select count(*) from ehson_qarz) as qarz_soni;

-- guruh ro'yxati sinovi (faqat o'qiydi): qarzdor bo'yicha nechta qarz, jami qoldi
select r->>'qarzdor_nom' as qarzdor, r->>'valyuta' as valyuta, r->>'soni' as qarz_soni, r->>'qoldi' as qoldi, r->>'holat' as holat,
       jsonb_array_length(r->'qarzlar') as qarzlar
  from jsonb_array_elements((ehson_qarz_guruh_royxat('{"limit":20}'::jsonb))->'rows') r;
