-- PROVODKA_EHSON_XAYRIYA_944X_20261107.sql
-- Kompaniya kitobida Ehson'ga berilgan pul = Dt «Ehson jamg'armasi» (94xx xarajat) / Kt kassa  ->  Cashflow B «Xayriya» qatori.
--
-- DALIL (yangi hisob OCHILMAYDI): Ehson jamg'armasiga pul kompaniyadan Professional'dagi oddiy provodka bilan o'tadi:
-- Dt accounts.ehson_kassa_id is not null (94xx xarajat, _ehson_xarajat_modda) / Kt kassa; ehson_kirim shu entry'dan
-- _ehson_kirim_sync bilan AVTOMAT hosil bo'ladi. Ehson ichidagi «qo'lda kirim» (ehson_kirim_qolda, tur='qolda') esa
-- entry/accounts'ga UMUMAN YOZILMAYDI (PROVODKA_EHSON_KIRIM.sql) - kompaniya kassasidan kelmaydi, ikki marta hisoblanmaydi.
-- Shuning uchun 9440 ochilmaydi, ehson_kirim_provodka RPC yozilmaydi (ikkinchi yo'l kerak emas).
--
-- Bu fayl faqat ADDITIVE:
--   1) accounts.cf_modda='xayriya' (+ faoliyat_turi='operatsion', balans_bolimi='xarajat' - faqat bo'sh bo'lsa) barcha ehson
--      moddalariga; ustun bo'lmasa jim o'tadi. Kelajakdagi yangi ehson moddasi uchun BEFORE trigger.
--   2) entry.entry_type='ehson' - _entry_type_ehson_belgila(entry_id): ustun bo'lmasa jim; qiymat faqat NULL yoki ustun
--      sukut qiymatiga teng bo'lsa almashtiriladi (boshqa tur qo'lda belgilangan bo'lsa tegilmaydi).
--   3) entry_line AFTER INSERT trigger (yangi yozuvlar) + entry_ehson_pul_turi_yoz (imzo bir xil, +1 qator) + eski yozuvlar backfill.
-- Jurnal, kassalar, summalar O'ZGARMAYDI. Idempotent. Old shart: PROVODKA_EHSON.sql, PROVODKA_EHSON_ZAKOT.sql.

do $chk$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='accounts' and column_name='ehson_kassa_id') then
    raise exception 'accounts.ehson_kassa_id yoq - avval PROVODKA_EHSON.sql';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='entry' and column_name='ehson_pul_turi') then
    raise exception 'entry.ehson_pul_turi yoq - avval PROVODKA_EHSON_ZAKOT.sql';
  end if;
end
$chk$;

-- 1-BOLIM: accounts belgilari --------------------------------------------------------------------------------------
create or replace function _accounts_ehson_cf_belgila()
returns trigger
language plpgsql
as $fn$
declare
  v_j jsonb := to_jsonb(new);
  v_set jsonb := '{}'::jsonb;
begin
  if new.ehson_kassa_id is null then
    return new;
  end if;
  if v_j ? 'cf_modda' and nullif(btrim(coalesce(v_j ->> 'cf_modda', '')), '') is null then
    v_set := v_set || jsonb_build_object('cf_modda', 'xayriya');
  end if;
  if v_j ? 'faoliyat_turi' and nullif(btrim(coalesce(v_j ->> 'faoliyat_turi', '')), '') is null then
    v_set := v_set || jsonb_build_object('faoliyat_turi', 'operatsion');
  end if;
  if v_j ? 'balans_bolimi' and nullif(btrim(coalesce(v_j ->> 'balans_bolimi', '')), '') is null then
    v_set := v_set || jsonb_build_object('balans_bolimi', 'xarajat');
  end if;
  if v_set = '{}'::jsonb then
    return new;
  end if;
  return jsonb_populate_record(new, v_set);
end
$fn$;

drop trigger if exists trg_accounts_ehson_cf on accounts;
create trigger trg_accounts_ehson_cf
  before insert or update of ehson_kassa_id on accounts
  for each row execute function _accounts_ehson_cf_belgila();

-- mavjud ehson moddalari: no-op update trigger orqali to'ldiradi (faqat bo'sh ustunlar)
update accounts set ehson_kassa_id = ehson_kassa_id where ehson_kassa_id is not null;

-- 2-BOLIM: entry.entry_type='ehson' ----------------------------------------------------------------------------------
create or replace function _entry_type_ehson_belgila(p_entry uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_def  text;
  v_dlit text;
  v_n    int;
begin
  select c.column_default into v_def
    from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'entry' and c.column_name = 'entry_type';
  if not found then
    return false;
  end if;
  v_dlit := substring(coalesce(v_def, '') from '^''(.*)''(::[a-z ]+)?$');
  execute 'update entry set entry_type = $1 where id = $2 and (entry_type is null or entry_type::text = $3) and entry_type::text is distinct from $1'
    using 'ehson', p_entry, coalesce(v_dlit, chr(1));
  get diagnostics v_n = row_count;
  return v_n > 0;
exception when others then
  raise warning '_entry_type_ehson_belgila(%): %', p_entry, sqlerrm;
  return false;
end
$fn$;

revoke all on function _entry_type_ehson_belgila(uuid) from public, anon, authenticated;

comment on function _entry_type_ehson_belgila(uuid) is
  'ICHKI: entry.entry_type=''ehson'' (ustun bo''lsa). Faqat NULL yoki ustun sukut qiymati bo''lsa almashtiradi; xatoda raise warning (provodkani to''smaydi).';

create or replace function _entry_line_ehson_tur()
returns trigger
language plpgsql
as $fn$
begin
  if coalesce(new.debit, 0) > 0
     and exists (select 1 from accounts a where a.id = new.account_id and a.ehson_kassa_id is not null) then
    perform _entry_type_ehson_belgila(new.entry_id);
  end if;
  return null;
end
$fn$;

drop trigger if exists trg_entry_line_ehson_tur on entry_line;
create trigger trg_entry_line_ehson_tur
  after insert on entry_line
  for each row execute function _entry_line_ehson_tur();

-- 3-BOLIM: entry_ehson_pul_turi_yoz (imzo bir xil; PROVODKA_EHSON_ZAKOT.sql 2.9 dan verbatim + 1 qator) -----------------
create or replace function entry_ehson_pul_turi_yoz(p_ext_ref text, p_pul_turi text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid            uuid := auth.uid();
  v_ext            text := nullif(btrim(coalesce(p_ext_ref, '')), '');
  v_pt             text := lower(nullif(btrim(coalesce(p_pul_turi, '')), ''));
  v_id             uuid;
  v_created_at     timestamptz;
  v_ehson_pul_turi text;
  v_created_by_raw text;
  v_owner          uuid;
  v_kassa_id       uuid;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if v_ext is null then
    return jsonb_build_object('ok', false, 'kod', 'ext_ref_kerak');
  end if;
  if v_pt is null then
    return jsonb_build_object('ok', false, 'kod', 'pul_turi_notogri');
  end if;

  select e.id, e.created_at, e.ehson_pul_turi, (to_jsonb(e) ->> 'created_by')
    into v_id, v_created_at, v_ehson_pul_turi, v_created_by_raw
    from entry e
   where e.ext_ref = v_ext
   limit 1;

  if v_id is null then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi');
  end if;

  -- 🔴 `created_by` turi bazada aniqlanmagan (entry_jadval_yoz naqshi,
  --    PROVODKA_JADVAL.sql) — `::uuid` cast FAQAT to'liq uuid shaklida.
  v_owner := case when v_created_by_raw ~ '^[0-9a-fA-F-]{36}$' then v_created_by_raw::uuid end;
  if v_owner is distinct from v_uid then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat_yoq');
  end if;
  if v_created_at is null or v_created_at < now() - interval '30 minutes' then
    return jsonb_build_object('ok', false, 'kod', 'muddat_tugagan');
  end if;
  if v_ehson_pul_turi is not null then
    return jsonb_build_object('ok', false, 'kod', 'allaqachon');
  end if;

  select a.ehson_kassa_id into v_kassa_id
    from entry_line l join accounts a on a.id = l.account_id
   where l.entry_id = v_id and l.debit > 0 and a.ehson_kassa_id is not null
   limit 1;

  if v_kassa_id is null then
    return jsonb_build_object('ok', false, 'kod', 'ehson_emas');
  end if;

  if not exists (select 1 from ehson_pul_turi where kassa_id = v_kassa_id and kod = v_pt and is_active) then
    return jsonb_build_object('ok', false, 'kod', 'pul_turi_notogri');
  end if;

  update entry set ehson_pul_turi = v_pt where id = v_id;

  perform _ehson_kirim_sync(v_id);
  perform _entry_type_ehson_belgila(v_id);

  return jsonb_build_object('ok', true);
end
$fn$;

revoke all on function entry_ehson_pul_turi_yoz(text, text) from public, anon;
grant execute on function entry_ehson_pul_turi_yoz(text, text) to authenticated;

-- 4-BOLIM: backfill (eski yozuvlar; faqat entry_type ustuni qiymati) --------------------------------------------------
do $bf$
declare
  r record;
  v_n int := 0;
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='entry' and column_name='entry_type') then
    raise notice 'entry.entry_type yoq - backfill o''tkazib yuborildi (boshqa SQL qo''shgach qayta RUN qiling)';
    return;
  end if;
  for r in
    select distinct e.id
      from entry e
     where e.ehson_pul_turi is not null
        or exists (select 1 from entry_line l join accounts a on a.id = l.account_id
                    where l.entry_id = e.id and l.debit > 0 and a.ehson_kassa_id is not null)
  loop
    if _entry_type_ehson_belgila(r.id) then v_n := v_n + 1; end if;
  end loop;
  raise notice 'entry_type=ehson backfill: % ta yozuv', v_n;
end
$bf$;

notify pgrst, 'reload schema';
