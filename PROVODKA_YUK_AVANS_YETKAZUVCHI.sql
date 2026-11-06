-- =====================================================================
-- PROVODKA_YUK_AVANS_YETKAZUVCHI.sql
-- Yetkazuvchiga berilgan AVANS: bog'lanmagan 9110-1 (tovar) to'lovga yetkazuvchi
-- nomi yoziladi; hujjat (yuk) kelib bog'lanmaguncha pul yetkazuvchi ustida
-- «osilib turadi» va qarzdor sahifasida qarzdan ayriladi.
-- ---------------------------------------------------------------------
-- Project: Provodka (kxzerccdpcltmzrxutlo). ADDITIVE va idempotent:
--   * provodka_yoz, yuk_boglash*, yuk_kutayotgan() TEGILMAYDI.
--   * yuk_kutayotgan_v2() faqat create or replace (imzo bir xil, javobga
--     bitta maydon qo'shiladi: yetkazuvchi).
-- Old shart: PROVODKA_YUK_BOGLANMAGAN_V2.sql va PROVODKA_YUK_BOGLASH_QISMAN.sql
-- (yuk_kutayotgan_v2 ning ENG OXIRGI nusxasi shu yerda) RUN qilingan bo'lishi kerak.
--
-- Tartib:
--   1-BO'LIM — entry.yetkazuvchi ustuni
--   2-BO'LIM — entry_yetkazuvchi_yoz(text, text)  (Professional, saqlashdan keyin)
--   3-BO'LIM — yuk_kutayotgan_v2() QAYTA (+ yetkazuvchi)
--   4-BO'LIM — yetkazuvchi_avans_royxat()  (qarzdor sahifasi)
--   5-BO'LIM — PostgREST sxema keshi
--   6-BO'LIM — DIAG (faqat select)
--
-- Bog'lash mantig'i o'zgarmaydi: yuk_boglash / yuk_boglash_koplik / yuk_boglash_taqsim
-- yozuv TO'LIQ bog'langanda entry.yuk_kutilmoqda=false qiladi, qisman bo'lsa true
-- qoladi (summa = 9110-1 qoldig'i). Avans ro'yxati shu bayroq va qoldiqqa tayanadi,
-- shuning uchun bog'langan qism avtomatik avansdan chiqadi. yuk_boglash_bekor
-- bayroqni qayta true qiladi - avans ham qaytadi.
--
-- Asilbek qo'lda RUN qiladi.
-- =====================================================================


-- #####################################################################
-- ##  1-BO'LIM — entry.yetkazuvchi                                   ##
-- #####################################################################
alter table entry add column if not exists yetkazuvchi text;

comment on column entry.yetkazuvchi is
  'Bog''lanmagan (yo''ldagi, 9110-1) tovar to''lovi kimga berilgani - Aros keshidagi yetkazuvchi matni AYNAN '
  'yoki erkin nom (Boshqa). Yukka bog''langunga qadar yetkazuvchi AVANSi. NULL = ko''rsatilmagan.';

create index if not exists entry_yetkazuvchi_kutilmoqda_idx
  on entry (yetkazuvchi) where yuk_kutilmoqda = true and yetkazuvchi is not null;


-- #####################################################################
-- ##  2-BO'LIM — entry_yetkazuvchi_yoz(text, text)                   ##
-- #####################################################################
-- entry_yuk_sabab_yoz naqshi: ext_ref bo'yicha, egalik created_by=auth.uid()
-- (turi bazada aniqlanmagan - regex bilan cast), 30 daqiqa ichida, bir marta
-- (yetkazuvchi hali null), faqat yuk_kutilmoqda=true yozuvda.

create or replace function entry_yetkazuvchi_yoz(p_ext_ref text, p_yetkazuvchi text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid            uuid := auth.uid();
  v_ext            text := nullif(btrim(coalesce(p_ext_ref, '')), '');
  v_nom            text := nullif(btrim(coalesce(p_yetkazuvchi, '')), '');
  v_id             uuid;
  v_created_at     timestamptz;
  v_kutil          boolean;
  v_old            text;
  v_created_by_raw text;
  v_owner          uuid;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if v_ext is null then
    return jsonb_build_object('ok', false, 'kod', 'ext_ref_kerak');
  end if;
  if v_nom is null or length(v_nom) > 200 then
    return jsonb_build_object('ok', false, 'kod', 'nom_notogri');
  end if;

  select e.id, e.created_at, coalesce(e.yuk_kutilmoqda, false), e.yetkazuvchi,
         (to_jsonb(e) ->> 'created_by')
    into v_id, v_created_at, v_kutil, v_old, v_created_by_raw
    from entry e
   where e.ext_ref = v_ext
   limit 1;

  if v_id is null then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi');
  end if;

  v_owner := case when v_created_by_raw ~ '^[0-9a-fA-F-]{36}$' then v_created_by_raw::uuid end;
  if v_owner is distinct from v_uid then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat_yoq');
  end if;
  if v_created_at is null or v_created_at < now() - interval '30 minutes' then
    return jsonb_build_object('ok', false, 'kod', 'muddat_tugagan');
  end if;
  if not v_kutil then
    return jsonb_build_object('ok', false, 'kod', 'yolda_emas');
  end if;
  if v_old is not null then
    return jsonb_build_object('ok', false, 'kod', 'allaqachon');
  end if;

  update entry set yetkazuvchi = v_nom where id = v_id;

  return jsonb_build_object('ok', true);
end
$fn$;

revoke all on function entry_yetkazuvchi_yoz(text, text) from public, anon;
grant execute on function entry_yetkazuvchi_yoz(text, text) to authenticated;

comment on function entry_yetkazuvchi_yoz(text, text) is
  'Professional «yo''ldagi tovar» saqlashdan keyin yetkazuvchi nomini yozadi (avans). '
  'entry_yuk_sabab_yoz naqshi: egalik created_by=auth.uid(), 30 daqiqa, bir marta, yuk_kutilmoqda=true.';


-- #####################################################################
-- ##  3-BO'LIM — yuk_kutayotgan_v2() QAYTA (+ yetkazuvchi)           ##
-- #####################################################################
-- PROVODKA_YUK_BOGLASH_QISMAN.sql 5-BO'LIM nusxasi AYNAN, faqat select ro'yxatiga
-- `e.yetkazuvchi` qo'shilgan. Imzo va qolgan maydonlar o'zgarmagan.

create or replace function yuk_kutayotgan_v2()
returns jsonb
language sql
stable
security definer
set search_path = public
as $yq_kut2$
  select jsonb_build_object(
           'ok',         true,
           'qisman',     true,
           'soni',       coalesce(count(*), 0),
           'jami_summa', coalesce(sum(r.summa), 0),
           'rows',       coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb))
    from (
      select e.id as entry_id, e.ext_ref, e.entry_date, e.created_at, e.status,
             e.description as izoh, e.description,
             case when coalesce(q.qoldiq, 0) > 0 then q.qoldiq else coalesce(q.jami, 0) end as summa,
             coalesce(q.jami, 0) as summa_jami,
             coalesce(b.boglangan, 0) as boglangan_uzs,
             (coalesce(b.boglangan, 0) > 0) as qisman,
             ka.id as kassa_id, ka.code as kassa_code, ka.name as kassa_name, ka.subtitle as kassa_subtitle,
             coalesce(pr.full_name, '') as kim,
             e.yuk_sabab_id as sabab_id, s.nom as sabab_nom, s.ikonka as sabab_ikonka,
             e.yetkazuvchi
        from entry e
        left join lateral (
          select coalesce(sum(el.debit), 0) as jami,
                 coalesce(sum(el.debit) filter (where a.code = '9110-1'), 0) as qoldiq
            from entry_line el join accounts a on a.id = el.account_id
           where el.entry_id = e.id and el.debit > 0
        ) q on true
        left join lateral (
          select coalesce(sum(ey.summa_uzs), 0) as boglangan from entry_yuk ey where ey.entry_id = e.id
        ) b on true
        left join lateral (
          select el.account_id from entry_line el
            join accounts a on a.id = el.account_id
           where el.entry_id = e.id and el.credit > 0 and a.section = 'pul'
           limit 1
        ) kl on true
        left join accounts ka on ka.id = kl.account_id
        left join profiles pr on pr.id::text = e.created_by::text   -- entry.created_by TEXT (uuid emas)
        left join yuk_tannarx_sabab s on s.id = e.yuk_sabab_id
       where e.yuk_kutilmoqda = true and e.is_deleted = false and e.status = 'posted'
    ) r;
$yq_kut2$;

revoke all on function yuk_kutayotgan_v2() from public, anon;
grant execute on function yuk_kutayotgan_v2() to authenticated;

comment on function yuk_kutayotgan_v2() is
  'yuk_kutayotgan() + sabab/status/ext_ref/description. summa = 9110-1 qoldigi (boglanmagan qism), '
  '+summa_jami, boglangan_uzs, qisman, yetkazuvchi (avans); top-level qisman:true = qisman boglash RPC lari bazada bor.';


-- #####################################################################
-- ##  4-BO'LIM — yetkazuvchi_avans_royxat()                          ##
-- #####################################################################
-- Yetkazuvchi nomi bor, hali yukka bog'lanmagan TOVAR (sababsiz) to'lovlar.
-- summa_uzs = 9110-1 qoldig'i (qisman bog'langan bo'lsa faqat bog'lanmagan qism).
-- fc_summa/valyuta - valyuta kassasidan berilgan bo'lsa, qoldiqqa mutanosib.
-- Ruxsat: admin yoki 'qarzdor' / 'yuklar' sahifasi (perm_has_page naqshi).

create or replace function yetkazuvchi_avans_royxat()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_ok   boolean := false;
  v_rows jsonb;
  v_jami numeric;
  v_soni int;
begin
  if auth.uid() is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if is_admin() then
    v_ok := true;
  elsif to_regprocedure('public.perm_has_page(text)') is not null then
    v_ok := coalesce(perm_has_page('qarzdor') or perm_has_page('yuklar'), false);
  end if;
  if not v_ok then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat_yoq');
  end if;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.yetkazuvchi, r.entry_date desc, r.created_at desc), '[]'::jsonb),
         coalesce(sum(r.summa_uzs), 0),
         count(*)
    into v_rows, v_jami, v_soni
    from (
      select e.id as entry_id, e.ext_ref, e.entry_date, e.created_at,
             e.yetkazuvchi,
             case when coalesce(q.qoldiq, 0) > 0 then q.qoldiq else coalesce(q.jami, 0) end as summa_uzs,
             case when kl.fc_amount is not null and coalesce(q.jami, 0) > 0
                  then round(kl.fc_amount * (case when coalesce(q.qoldiq, 0) > 0 then q.qoldiq else q.jami end) / q.jami, 2)
             end as fc_summa,
             case when kl.fc_amount is not null then ka.currency end as valyuta,
             e.fc_rate as kurs,
             e.description as izoh,
             e.yuk_sabab_id as sabab_id, s.nom as sabab_nom, s.ikonka as sabab_ikonka,
             coalesce(b.boglangan, 0) as boglangan_uzs,
             ka.name as kassa_name,
             coalesce(pr.full_name, '') as kim
        from entry e
        left join lateral (
          select coalesce(sum(el.debit), 0) as jami,
                 coalesce(sum(el.debit) filter (where a.code = '9110-1'), 0) as qoldiq
            from entry_line el join accounts a on a.id = el.account_id
           where el.entry_id = e.id and el.debit > 0
        ) q on true
        left join lateral (
          select coalesce(sum(ey.summa_uzs), 0) as boglangan from entry_yuk ey where ey.entry_id = e.id
        ) b on true
        left join lateral (
          select el.account_id, el.fc_amount from entry_line el
            join accounts a on a.id = el.account_id
           where el.entry_id = e.id and el.credit > 0 and a.section = 'pul'
           limit 1
        ) kl on true
        left join accounts ka on ka.id = kl.account_id
        left join profiles pr on pr.id::text = e.created_by::text
        left join yuk_tannarx_sabab s on s.id = e.yuk_sabab_id
       where e.yuk_kutilmoqda = true and e.is_deleted = false and e.status = 'posted'
         -- sabab filtri YO'Q (06.11.2026): nom faqat tovar va «Boshqa» turida so'raladi, yozilgan bo'lsa avans
         and nullif(btrim(coalesce(e.yetkazuvchi, '')), '') is not null
    ) r;

  return jsonb_build_object('ok', true, 'soni', v_soni, 'jami_uzs', v_jami, 'rows', v_rows);
end
$fn$;

revoke all on function yetkazuvchi_avans_royxat() from public, anon;
grant execute on function yetkazuvchi_avans_royxat() to authenticated;

comment on function yetkazuvchi_avans_royxat() is
  'Yetkazuvchiga berilgan, hali yukka boglanmagan tovar tolovlari (avans): entry.yetkazuvchi + yuk_kutilmoqda=true, '
  'sababsiz. summa_uzs = 9110-1 qoldigi. Ruxsat: admin yoki perm_has_page qarzdor/yuklar.';


-- #####################################################################
-- ##  5-BO'LIM — PostgREST sxema keshi                               ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  6-BO'LIM — DIAG (faqat select, hech narsa yozmaydi)            ##
-- #####################################################################
-- select column_name from information_schema.columns where table_name = 'entry' and column_name = 'yetkazuvchi';
-- select proname from pg_proc where proname in ('entry_yetkazuvchi_yoz', 'yetkazuvchi_avans_royxat');
-- select yetkazuvchi, count(*), sum(summa_uzs) from jsonb_to_recordset(yetkazuvchi_avans_royxat() -> 'rows')
--        as x(yetkazuvchi text, summa_uzs numeric) group by 1;   -- login (auth.uid) kerak: SQL editor'da null bo'ladi
