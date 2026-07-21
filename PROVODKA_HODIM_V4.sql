-- =====================================================================
-- PROVODKA — HODIM V4
-- ---------------------------------------------------------------------
-- 3) CEO kategoriya oy hisoboti (hisobot.html):
--      hodim_kategoriya_hisobot(p_from,p_to) → kategoriya (xarajat modda) jami
--      hodim_kassa_hisobot(p_from,p_to)      → qaysi kassa/hodim ko'p sarfladi
-- 4) Excel/CSV to'liq ro'yxat:
--      hodim_xarajat_royxat(p_from,p_to)     → har yozuv (sana/kassa/modda/summa/izoh/kim)
--
-- Hammasi ADMIN only (is_admin), SECURITY DEFINER, REVOKE anon. Idempotent.
-- Asilbek qo'lda RUN qiladi. entry insert yo'li o'zgarmaydi.
-- =====================================================================


-- =====================================================================
-- 3.1 Kategoriya bo'yicha xarajat jami (kamayish tartibida)
-- ---------------------------------------------------------------------
-- Har xarajat moddasi (type='xarajat') bo'yicha davr ichida jami Dt (sarflangan).
-- =====================================================================
create or replace function hodim_kategoriya_hisobot(p_from date, p_to date)
returns table(code text, name text, jami numeric)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Faqat admin ko''ra oladi' using errcode = '42501';
  end if;
  return query
    select a.code, a.name, sum(el.debit)::numeric as jami
      from entry_line el
      join entry e on e.id = el.entry_id
      join accounts a on a.id = el.account_id
     where a.type = 'xarajat'
       and el.debit > 0
       and e.status = 'posted'
       and e.is_deleted = false
       and e.entry_date >= p_from
       and e.entry_date <= p_to
     group by a.code, a.name
    having sum(el.debit) > 0
     order by sum(el.debit) desc, a.code;
end $$;

revoke all on function hodim_kategoriya_hisobot(date, date) from public, anon;
grant execute on function hodim_kategoriya_hisobot(date, date) to authenticated;

comment on function hodim_kategoriya_hisobot(date, date) is
  'CEO: xarajat moddalari bo''yicha davr jami (kamayish tartibida). Admin only.';


-- =====================================================================
-- 3.2 Kassa (hodim/filial) bo'yicha xarajat jami — kim ko'p sarfladi
-- ---------------------------------------------------------------------
-- Pul kassasidan (Kt) chiqqan, qarshi tomoni xarajat bo'lgan summalar.
-- =====================================================================
create or replace function hodim_kassa_hisobot(p_from date, p_to date)
returns table(code text, name text, subtitle text, jami numeric)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Faqat admin ko''ra oladi' using errcode = '42501';
  end if;
  return query
    select ka.code, ka.name, ka.subtitle, sum(kl.credit)::numeric as jami
      from entry_line kl
      join entry e on e.id = kl.entry_id
      join accounts ka on ka.id = kl.account_id and ka.section = 'pul'
     where kl.credit > 0
       and e.status = 'posted'
       and e.is_deleted = false
       and e.entry_date >= p_from
       and e.entry_date <= p_to
       and exists (
         select 1 from entry_line dl
           join accounts da on da.id = dl.account_id
          where dl.entry_id = e.id and dl.debit > 0 and da.type = 'xarajat'
       )
     group by ka.code, ka.name, ka.subtitle
    having sum(kl.credit) > 0
     order by sum(kl.credit) desc, ka.code;
end $$;

revoke all on function hodim_kassa_hisobot(date, date) from public, anon;
grant execute on function hodim_kassa_hisobot(date, date) to authenticated;

comment on function hodim_kassa_hisobot(date, date) is
  'CEO: kassa (hodim/filial) bo''yicha xarajat jami. Admin only.';


-- =====================================================================
-- 4. To'liq xarajat ro'yxati (Excel eksport uchun)
-- ---------------------------------------------------------------------
-- Har xarajat yozuvi: sana, kassa, modda, summa, izoh, kim (created_by → profiles).
-- Oddiy 2-satrli xarajatda 1 qator; ko'p satrli yozuvda har xarajat satri alohida.
-- =====================================================================
create or replace function hodim_xarajat_royxat(p_from date, p_to date)
returns table(
  entry_date date, kassa_code text, kassa_name text, kassa_subtitle text,
  modda_code text, modda_name text, summa numeric, izoh text, kim text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Faqat admin ko''ra oladi' using errcode = '42501';
  end if;
  return query
    select e.entry_date,
           ka.code, ka.name, ka.subtitle,
           ma.code, ma.name,
           dl.debit::numeric,
           e.description,
           pr.full_name
      from entry e
      join entry_line dl on dl.entry_id = e.id and dl.debit > 0
      join accounts ma on ma.id = dl.account_id and ma.type = 'xarajat'
      join entry_line kl on kl.entry_id = e.id and kl.credit > 0
      join accounts ka on ka.id = kl.account_id and ka.section = 'pul'
      left join profiles pr on pr.id = e.created_by
     where e.status = 'posted'
       and e.is_deleted = false
       and e.entry_date >= p_from
       and e.entry_date <= p_to
     order by e.entry_date, ka.name, ma.name;
end $$;

revoke all on function hodim_xarajat_royxat(date, date) from public, anon;
grant execute on function hodim_xarajat_royxat(date, date) to authenticated;

comment on function hodim_xarajat_royxat(date, date) is
  'CEO: davr ichidagi to''liq xarajat ro''yxati (Excel eksport). Admin only.';
