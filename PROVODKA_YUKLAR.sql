-- =====================================================================
-- PROVODKA — YUKLAR (Aros product-incomes) + xarajatga bog'lash
-- ---------------------------------------------------------------------
-- entry.yuk_ids: bir xarajat qaysi Aros yuk(lar)ini qoplaganini saqlaydi.
--   Aros product-income `id` lari (integer[]). Multiselect (bir necha yuk).
--   MUHIM: bu FAQAT bog'lanish metadata'si. Pul harakati o'zgarmaydi
--   (entry_line: Dt 9110 Tovar tannarxi / Kt kassa — o'zgarmaydi).
--
-- To'lov statusi ALOHIDA saqlanmaydi — hisoblanadi: yuk id biror
-- o'chirilmagan, posted entry'ning yuk_ids ichida bo'lsa → to'langan.
--
-- Additive: add column if not exists, yangi RPC, perm_pages() ga 'yuklar'.
-- Asilbek qo'lda RUN qiladi.
-- =====================================================================


-- =====================================================================
-- 1-BO'LIM — entry.yuk_ids ustuni + GIN indeks
-- =====================================================================

alter table entry
  add column if not exists yuk_ids integer[] not null default '{}';

create index if not exists entry_yuk_ids_idx on entry using gin (yuk_ids);

comment on column entry.yuk_ids is
  'Xarajat qaysi Aros yuk(lar)ini qopladi — product-income id lari. Bog''lanish metadata.';


-- =====================================================================
-- 2-BO'LIM — yuk_tolov_holati(p_ids) — to'lov statusini hisoblaydi
-- ---------------------------------------------------------------------
-- Har berilgan yuk id uchun: to'langanmi, qaysi entry, sanasi, summasi.
-- tolangan = o'chirilmagan posted entry'ning yuk_ids ichida bor.
-- summa = o'sha entry debet yig'indisi (xarajat summasi; Dt 9110 / Kt kassa).
-- SECURITY DEFINER (balans hisoblari kabi), REVOKE anon.
-- =====================================================================

create or replace function yuk_tolov_holati(p_ids integer[])
returns table(yuk_id integer, tolangan boolean, entry_id uuid, entry_date date, summa numeric)
language sql
stable
security definer
set search_path = public
as $$
  select y.yuk_id,
         (e.id is not null)                          as tolangan,
         e.id                                        as entry_id,
         e.entry_date                                as entry_date,
         coalesce(e.summa, 0)                        as summa
    from unnest(coalesce(p_ids, '{}')) as y(yuk_id)
    left join lateral (
      select en.id, en.entry_date,
             (select sum(el.debit) from entry_line el where el.entry_id = en.id) as summa
        from entry en
       where en.status = 'posted'
         and en.is_deleted = false
         and y.yuk_id = any(en.yuk_ids)
       order by en.entry_date desc, en.id desc
       limit 1
    ) e on true;
$$;

revoke all on function yuk_tolov_holati(integer[]) from public, anon;
grant execute on function yuk_tolov_holati(integer[]) to authenticated;

comment on function yuk_tolov_holati(integer[]) is
  'Har yuk id uchun to''lov holati (tolangan/entry/sana/summa). yuk_ids ustunidan hisoblanadi.';


-- =====================================================================
-- 3-BO'LIM — perm_pages() ga 'yuklar' qo'shiladi (additive)
-- ---------------------------------------------------------------------
-- Sahifa kalitlari yagona manba — perms.js PAGES bilan bir xil bo'lishi shart.
-- create or replace grant'larni saqlaydi, lekin xavfsizlik uchun qayta beramiz.
-- =====================================================================

create or replace function perm_pages()
returns text[]
language sql
immutable
as $$
  select array['kassa','jurnal','professional','hisobot','balans','cashflow',
               'qarzdor','filial','valyuta','konvert','sozlama','provodka','yuklar']::text[];
$$;

revoke all on function perm_pages() from public, anon;
grant execute on function perm_pages() to authenticated, service_role;


-- =====================================================================
-- 4-BO'LIM — Tekshiruv
-- =====================================================================

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='entry' and column_name='yuk_ids') then
    raise exception 'entry.yuk_ids ustuni yaratilmadi';
  end if;
  if to_regprocedure('public.yuk_tolov_holati(integer[])') is null then
    raise exception 'yuk_tolov_holati(integer[]) yaratilmadi';
  end if;
  if not ('yuklar' = any(perm_pages())) then
    raise exception 'perm_pages() ichida yuklar yoq';
  end if;
  raise notice 'Yuklar DB tayyor. yuk_ids bor entrylar: % ta',
    (select count(*) from entry where array_length(yuk_ids,1) > 0);
end $$;
