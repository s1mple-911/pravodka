-- ============================================================================
--  PROVODKA_KURS_FARQI_AVTO.sql — 2026-09-21 — VALYUTA HISOBIDA KURS FARQI AVTOMAT
--  Asilbek: «dollar kirdi — dollar chiqdi, demak qolmasin; farqni qo'lda yozish shart emas,
--  kurs farqini jurnaldan ko'rib boramiz». Hodisa: G'iyos · USD — $1 226 019 turli kursda kirib,
--  hammasi 11 850 da chiqdi → dollar 0, so'm 94 425 650 «osilib» qoldi.
--
--  QOIDA (o'rtacha tannarx): valyuta hisobidan CHIQIM (credit, fc_amount>0) yozilganda hisobning
--  shu paytgacha o'rtacha kursi (so'm qoldiq / valyuta qoldiq) bo'yicha "kerakli so'm" hisoblanadi;
--  yozuvdagi so'm bilan farqi ALOHIDA avto-yozuvga tushadi: Dt «Konvert kurs farqi» / Kt hisob
--  (zarar) yoki Dt hisob / Kt farq (foyda). Natija: valyuta 0 bo'lsa so'm ham 0, farq jurnalda
--  ko'rinadi (izoh «Kurs farqi (avto): …», ext_ref kursfarq:<entry>:<line>).
--  Asl yozuv TEGILMAYDI (2 satr, tahrirlanadi); asl yozuv o'chirilsa/tahrirlansa avto-yozuv ham
--  o'chadi/qayta hisoblanadi. Kirim (debit) satrlari tegilmaydi — ular tannarxni belgilaydi.
--  Eski (allaqachon osilib qolgan) qoldiqlar uchun: PROVODKA_KURS_FARQI_TOZALASH.sql (bir marta).
--  Additive. Asilbek RUN qiladi.
-- ============================================================================

-- ---------------------------------------------------------------- 1) asosiy funksiya
create or replace function _kurs_farqi_yoz(p_line_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $kf$
declare
  l          record;
  e          record;
  a          record;
  v_farq_acc uuid;
  v_uzs      numeric;
  v_fc       numeric;
  v_avg      numeric;
  v_target   numeric;
  v_farq     numeric;
  v_ref      text;
  v_entry    uuid;
begin
  select * into l from entry_line where id = p_line_id;
  if l is null then return; end if;
  select * into e from entry where id = l.entry_id;
  if e is null then return; end if;
  v_ref := 'kursfarq:' || e.id::text || ':' || l.id::text;

  -- eski avto-yozuv (qayta hisob / tahrir) — soft-delete
  update entry set is_deleted = true, deleted_at = now(), deleted_by_name = 'avto (kurs farqi qayta)'
   where ext_ref = v_ref and is_deleted = false;

  -- avto-yozuvning o'zi, o'chirilgan/nashr qilinmagan yozuv, kirim satri, valyutasiz → hech narsa
  if coalesce(e.ext_ref, '') like 'kursfarq:%' or e.is_deleted or e.status is distinct from 'posted' then return; end if;
  if coalesce(l.credit, 0) <= 0 or coalesce(l.fc_amount, 0) <= 0 then return; end if;
  select id, code, name, currency, section, is_active into a from accounts where id = l.account_id;
  if a is null or a.section is distinct from 'pul' or coalesce(a.currency, 'UZS') = 'UZS' then return; end if;

  -- shu satrgacha bo'lgan qoldiq (posted, o'chirilmagan, shu satrsiz)
  -- (avvalgi avto-farq yozuvlari ham kiradi — ular qoldiqni o'rtacha tannarxga keltirgan)
  select coalesce(sum(x.debit - x.credit), 0),
         coalesce(sum(case when x.debit > 0 then coalesce(x.fc_amount, 0) else -coalesce(x.fc_amount, 0) end), 0)
    into v_uzs, v_fc
    from entry_line x join entry ex on ex.id = x.entry_id
   where x.account_id = l.account_id and x.id <> l.id
     and ex.status = 'posted' and ex.is_deleted = false;

  if v_fc <= 0.005 then return; end if;                 -- tannarx asosi yo'q (qoldiq 0 yoki manfiy)
  v_avg    := v_uzs / v_fc;
  v_target := round(least(l.fc_amount, v_fc) * v_avg)   -- qoldiqdan ortig'i uchun farq yozilmaydi
              + case when l.fc_amount > v_fc then round((l.fc_amount - v_fc) * (l.credit / l.fc_amount)) else 0 end;
  v_farq   := v_target - round(l.credit);
  if abs(v_farq) < 1 then return; end if;

  execute 'select public.conv_farq_hisob_id()' into v_farq_acc;
  if v_farq_acc is null then
    raise warning 'Kurs farqi (avto): «Konvert kurs farqi» moddasi topilmadi — % uchun farq % yozilmadi', a.code, v_farq;
    return;
  end if;

  perform set_config('provodka.avto_kurs', '1', true);
  perform set_config('provodka.notify_off', '1', true);
  insert into entry (entry_date, description, source, status, ext_ref, created_by)
    values (e.entry_date,
            'Kurs farqi (avto): ' || a.code || ' ' || a.name || ' · ' || l.fc_amount::text || ' ' || a.currency
              || ' · o''rtacha ' || round(v_avg)::text || ' vs ' || round(l.credit / l.fc_amount)::text
              || coalesce(' · ' || nullif(e.description, ''), ''),
            'manual', 'posted', v_ref, e.created_by)
    returning id into v_entry;
  if v_farq > 0 then
    -- yozuvdagi so'm o'rtacha tannarxdan KAM chiqdi → hisobda so'm ortiqcha qoladi → zarar
    insert into entry_line (entry_id, account_id, debit, credit, fc_amount) values (v_entry, v_farq_acc, v_farq, 0, null);
    insert into entry_line (entry_id, account_id, debit, credit, fc_amount) values (v_entry, l.account_id, 0, v_farq, 0);
  else
    -- yozuvdagi so'm o'rtacha tannarxdan KO'P chiqdi → hisob so'mda manfiyga ketardi → foyda
    insert into entry_line (entry_id, account_id, debit, credit, fc_amount) values (v_entry, l.account_id, -v_farq, 0, 0);
    insert into entry_line (entry_id, account_id, debit, credit, fc_amount) values (v_entry, v_farq_acc, 0, -v_farq, null);
  end if;
  perform set_config('provodka.avto_kurs', '', true);
  perform set_config('provodka.notify_off', '', true);
end
$kf$;
revoke all on function _kurs_farqi_yoz(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 2) triggerlar
create or replace function trg_kurs_farqi_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $t$
begin
  if coalesce(current_setting('provodka.avto_kurs', true), '') = '1' then return new; end if;
  if coalesce(new.credit, 0) > 0 or (tg_op = 'UPDATE' and coalesce(old.credit, 0) > 0) then
    perform _kurs_farqi_yoz(new.id);
  end if;
  return new;
end
$t$;
drop trigger if exists trg_kurs_farqi_entry_line on entry_line;
create trigger trg_kurs_farqi_entry_line
  after insert or update of debit, credit, fc_amount, account_id on entry_line
  for each row execute function trg_kurs_farqi_line();

-- asl yozuv o'chirilsa / holati o'zgarsa → avto-yozuv ham
create or replace function trg_kurs_farqi_entry()
returns trigger
language plpgsql
security definer
set search_path = public
as $t$
begin
  if coalesce(current_setting('provodka.avto_kurs', true), '') = '1' then return new; end if;
  if coalesce(new.ext_ref, '') like 'kursfarq:%' then return new; end if;
  if new.is_deleted and not old.is_deleted then
    update entry set is_deleted = true, deleted_at = now(), deleted_by_name = coalesce(new.deleted_by_name, 'avto')
     where ext_ref like 'kursfarq:' || new.id::text || ':%' and is_deleted = false;
  elsif (not new.is_deleted and old.is_deleted) or new.status is distinct from old.status then
    perform _kurs_farqi_yoz(x.id) from entry_line x where x.entry_id = new.id and coalesce(x.credit, 0) > 0;
  end if;
  return new;
end
$t$;
drop trigger if exists trg_kurs_farqi_entry on entry;
create trigger trg_kurs_farqi_entry
  after update of is_deleted, status on entry
  for each row execute function trg_kurs_farqi_entry();

-- ---------------------------------------------------------------- 3) rbac guard — avto-yozuv rol tekshiruvidan o'tadi
-- Tana PROVODKA_KONVERT_FARQ_RUXSAT.sql dan VERBATIM, boshiga 1 qator (provodka.avto_kurs) qo'shildi.
create or replace function rbac_guard_entry_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $rbac_guard$
declare
  v_type text;
  v_lbl  text;
  v_farq uuid;
  v_conv boolean;
begin
  if coalesce(current_setting('provodka.avto_kurs', true), '') = '1' then
    return new;                                   -- kurs farqi avto-yozuvi (faqat _kurs_farqi_yoz ichida)
  end if;
  if coalesce(new.debit, 0) <= 0 then
    return new;
  end if;

  select a.type, coalesce(a.code || ' ' || a.name, new.account_id::text)
    into v_type, v_lbl
    from accounts a where a.id = new.account_id;

  if v_type is distinct from 'xarajat' then
    return new;
  end if;

  if to_regprocedure('public.conv_farq_hisob_id()') is not null
     and to_regprocedure('public.perm_can_convert()') is not null then
    execute 'select public.conv_farq_hisob_id()' into v_farq;
    if v_farq is not null and new.account_id = v_farq then
      execute 'select public.perm_can_convert()' into v_conv;
      if coalesce(v_conv, false) then
        return new;
      end if;
    end if;
  end if;

  if rbac_modda_ok(new.account_id) then
    return new;
  end if;

  raise exception 'Ruxsat yoq: "%" xarajat moddasi rolingizda yoq', v_lbl
    using errcode = '42501';
end
$rbac_guard$;
revoke all on function rbac_guard_entry_line() from public, anon;

-- ---------------------------------------------------------------- 4) tekshiruv
select 'trg_kurs_farqi_entry_line' as obyekt, (select count(*) from pg_trigger where tgname = 'trg_kurs_farqi_entry_line') as bor
union all select 'trg_kurs_farqi_entry', (select count(*) from pg_trigger where tgname = 'trg_kurs_farqi_entry')
union all select 'farq moddasi', (select count(*) from accounts where id = conv_farq_hisob_id());
