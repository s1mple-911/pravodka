-- =====================================================================
-- PROVODKA — OMBORLAR BALANSI (kassa + tovar yonma-yon)
-- ---------------------------------------------------------------------
-- balans.html'dagi "Omborlar" kartasi uchun: har ombor bitta qator,
-- KASSA (filial kassa qoldig'i) va TOVARLAR (ombor tovar qoldig'i) ustunlari.
--
-- Manba:
--   TOVARLAR -> accounts.section='tovar' (omborlar, masalan 29xx). Qoldiq = Dt−Kt.
--   KASSA    -> accounts.section='pul' AND kassa_turi='filial' (filial kassalari, 52xx).
--
-- OMBOR ↔ KASSA bog'lanishi (DIQQAT — ASILBEK TEKSHIRSIN):
--   1) BIRLAMCHI: filial_ref bir xil bo'lsa (ikkalasida ham Aros id) — aniq juftlik.
--   2) ZAXIRA:   tovar hisobda filial_ref bo'lmasa — nomning BIRINCHI so'zi bo'yicha
--                ('Qarshi shourum ombori' ↔ 'Qarshi ...' kassa).
--   Agar KASSA ustuni bo'sh ('—') yoki noto'g'ri chiqsa — pastdagi lateral join
--   shartini to'g'rilang (filial_ref yoki nom kaliti). Boshqa joyni o'zgartirmang.
--   Juftlik topilmasa KASSA = NULL ('—') — HECH QACHON noto'g'ri kassaga ulanmaydi
--   (filial_ref unikal; nom mos kelmasa bo'sh qoladi).
--
-- MUHIM: bu FAQAT ko'rsatuv (breakdown) — buxgalteriya balansini o'zgartirmaydi.
--   Aktiv/Passiv hisoblari va balans() RPC'si tegilmaydi.
--
-- SECURITY DEFINER (balans hisoboti — to'liq ko'rinadi), REVOKE anon. Idempotent.
-- Asilbek qo'lda RUN qiladi.
-- =====================================================================

create or replace function ombor_balans(p_date date)
returns table(code text, name text, kassa numeric, tovar numeric, jami numeric)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return query
  with bal as (
    -- har hisobning sanaga qadar qoldig'i (posted + o'chirilmagan)
    select el.account_id, sum(el.debit - el.credit) as b
      from entry_line el
      join entry e on e.id = el.entry_id
     where e.status = 'posted'
       and e.is_deleted = false
       and e.entry_date <= p_date
     group by el.account_id
  ),
  kas as (
    -- filial kassalari: filial_ref va nom-kaliti (birinchi so'z) bilan
    select a.filial_ref                       as fref,
           lower(split_part(a.name, ' ', 1))  as nkey,
           coalesce(b.b, 0)                    as bal
      from accounts a
      left join bal b on b.account_id = a.id
     where a.section = 'pul'
       and a.kassa_turi = 'filial'
  ),
  tov as (
    -- omborlar (tovar hisoblari)
    select a.code, a.name, a.filial_ref,
           lower(split_part(a.name, ' ', 1))  as nkey,
           coalesce(b.b, 0)                    as bal
      from accounts a
      left join bal b on b.account_id = a.id
     where a.section = 'tovar'
  )
  select t.code, t.name,
         k.bal                          as kassa,
         t.bal                          as tovar,
         t.bal + coalesce(k.bal, 0)     as jami
    from tov t
    left join lateral (
      -- ===== JUFTLIK SHARTI (kerak bo'lsa shu yerni to'g'rilang) =====
      select sum(kk.bal) as bal
        from kas kk
       where (t.filial_ref is not null and kk.fref = t.filial_ref)
          or (t.filial_ref is null     and kk.nkey = t.nkey)
      -- ================================================================
    ) k on true
   order by t.bal desc, t.code;
end $$;

revoke all on function ombor_balans(date) from public, anon;
grant execute on function ombor_balans(date) to authenticated;

comment on function ombor_balans(date) is
  'Omborlar balansi: har ombor uchun kassa (filial) + tovar qoldig''i. Faqat ko''rsatuv (breakdown).';


-- =====================================================================
-- Tekshiruv
-- =====================================================================

do $$
begin
  if to_regprocedure('public.ombor_balans(date)') is null then
    raise exception 'ombor_balans(date) yaratilmadi';
  end if;
  if has_function_privilege('anon', 'public.ombor_balans(date)', 'execute') then
    raise exception 'ombor_balans anon uchun ochiq qolgan';
  end if;
  raise notice 'ombor_balans tayyor. Omborlar (section=tovar): % ta',
    (select count(*) from accounts where section = 'tovar');
end $$;
