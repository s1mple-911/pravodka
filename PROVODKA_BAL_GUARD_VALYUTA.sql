-- ============================================================================
--  PROVODKA_BAL_GUARD_VALYUTA.sql — 2026-09-22 — balans qorovuli VALYUTA hisobida valyutada tekshiradi
--  Hodisa: Qashqadaryo kassa $ (5633) da $2 bor, so'm ekvivalenti 23 621 (o'rtacha kurs 11 810).
--  Hodim $2 ni 11 850 kursida yechmoqchi → so'mda 23 700 > 23 621 → «Kassada yetarli mablag yoq.
--  Qoldiq: 23621 som» — dollar yetarli bo'lsa ham. Sabab: bal_guard_entry_line hamma kassani
--  so'mda (acc_balance) solishtiradi. Endi valyuta hisobida (accounts.currency <> 'UZS')
--  fc_amount ↔ acc_fc_balance solishtiriladi, xabar valyutada. So'm qoldiq farqini
--  «Kurs farqi (avto)» triggeri (PROVODKA_KURS_FARQI_AVTO.sql) o'zi to'g'irlaydi.
--  Tana PROVODKA_BAL_GUARD_PENDING.sql dan VERBATIM + valyuta shoxi. Asilbek RUN qiladi.
-- ============================================================================

create or replace function public.bal_guard_entry_line()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_turi text;
  v_bal  numeric;
  v_lbl  text;
  v_st   text;
  v_cur  text;
begin
  -- service_role / n8n avtomatik sinxron (auth.uid() yo'q) — tekshirmaymiz.
  if auth.uid() is null then
    return new;
  end if;
  -- kurs farqi avto-yozuvi (fc_amount 0, faqat so'm tuzatish) — tekshirilmaydi
  if coalesce(current_setting('provodka.avto_kurs', true), '') = '1' then
    return new;
  end if;

  -- faqat pul chiqishi (kredit) tekshiriladi; kirim (debit) erkin
  if new.credit is null or new.credit <= 0 then
    return new;
  end if;

  select a.kassa_turi, coalesce(a.code || ' ' || a.name, new.account_id::text), coalesce(a.currency, 'UZS')
    into v_turi, v_lbl, v_cur
    from accounts a
   where a.id = new.account_id;

  -- pul kassasi emas yoki qamrovga kirmaydi -> tekshirmaymiz
  if v_turi is null or v_turi not in ('xarajat', 'markaziy') then
    return new;
  end if;

  -- PENDING yozuv balansga ta'sir qilmaydi (so'rovlar tizimi) — tekshirilmaydi
  select e.status into v_st from entry e where e.id = new.entry_id;
  if v_st = 'pending' then
    return new;
  end if;

  -- 🔴 VALYUTA hisobi: qoldiq VALYUTADA (fc), so'm ekvivalenti kurs farqi tufayli ishonchsiz
  if v_cur <> 'UZS' then
    if coalesce(new.fc_amount, 0) <= 0 then
      return new;                                   -- valyutasiz so'm tuzatish satri (kurs farqi va h.k.)
    end if;
    v_bal := coalesce(acc_fc_balance(new.account_id), 0);
    if new.fc_amount > v_bal + 0.005 then
      raise exception 'Kassada yetarli mablag yoq. Qoldiq: % % (% kassasi)',
        to_char(v_bal, 'FM999999999990.00'), v_cur, v_lbl
        using errcode = 'P0001';
    end if;
    return new;
  end if;

  -- qoldiq = acc_balance(kassa). UI ham shu manbadan ko'rsatadi (server=UI mos).
  v_bal := coalesce(acc_balance(new.account_id), 0);

  if new.credit > v_bal then
    raise exception 'Kassada yetarli mablag yoq. Qoldiq: % som (% kassasi)',
      to_char(round(v_bal), 'FM999999999990'), v_lbl
      using errcode = 'P0001';
  end if;

  return new;
end $fn$;

comment on function public.bal_guard_entry_line() is
  'entry_line qorovuli: kassadan qoldiqdan ortiq pul chiqmasin. PENDING tekshirilmaydi. '
  'Valyuta hisobida (currency<>UZS) fc_amount vs acc_fc_balance (2026-09-22). ENG OXIRGI: PROVODKA_BAL_GUARD_VALYUTA.sql';

select (p.prosrc ilike '%acc_fc_balance%') as valyuta_shoxi_bor,
       (p.prosrc ilike '%pending%')        as pending_istisnosi_saqlangan
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'bal_guard_entry_line';
