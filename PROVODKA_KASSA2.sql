-- =====================================================================
-- PROVODKA_KASSA2.sql
-- Hodim kassalari to'laqonli + Transfer + Konvert ko'p-valyuta (v2)
-- Foydalanuvchi QO'LDA ishga tushiradi. Idempotent — qayta-qayta run qilsa bo'ladi.
--
-- Qoidalar (BRIEF_PROVODKA_KASSA2.md):
--   * har yangi view  -> security_invoker = on
--   * har yangi funksiya -> REVOKE ... FROM PUBLIC, anon; faqat kerakli rolga GRANT
--   * xato holat -> RAISE EXCEPTION (jimgina o'tkazib yuborma)
--   * upsert_hodim_kassa() — TaskFix EF ishlatadi, service_role only. TEGILMAYDI.
--
-- MUHIM: bu fayl mavjud view'ni QAYTA YARATADI. Run qilishdan oldin eski
-- ta'rifni saqlab qo'ying:
--   select pg_get_viewdef('v_pul_hisoblar'::regclass, true);
-- =====================================================================


-- =====================================================================
-- 0-BOSQICH — Hodim kassalari hamma tanlagichda
-- ---------------------------------------------------------------------
-- provodka.html / professional.html / jurnal.html to'g'ridan `accounts`
-- jadvalidan o'qiydi — 54xx u yerda allaqachon bor, SQL kerak emas.
-- Faqat cashflow.html `v_pul_hisoblar` view'iga bog'langan, u esa kodni
-- qattiq yozib qo'ygan (5011/5012/5110 = markaziy, 52xx = filial), shuning
-- uchun 54xx unga tushmaydi. Endi view `kassa_turi` bo'yicha ishlaydi.
-- =====================================================================

-- 0.1 Kerakli ustunlar bormi — bo'lmasa to'xta (jimgina noto'g'ri view yasamaslik uchun)
do $$
declare
  m text;
begin
  select string_agg(c, ', ')
    into m
    from unnest(array['subtitle','kassa_turi','is_active','currency','parent_id','type','code','name']) as c
   where not exists (
     select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'accounts' and column_name = c
   );
  if m is not null then
    raise exception 'accounts jadvalida ustun(lar) yo''q: %. Avval migratsiyani bajaring.', m;
  end if;
end $$;

-- 0.2 v_pul_hisoblar — kassa tanlagichlari uchun (cashflow.html)
--     Ustunlar o'zgargani uchun CREATE OR REPLACE emas, DROP + CREATE kerak.
--     is_filial eski klient uchun qoladi (sindirma), yoniga kassa_turi/subtitle qo'shildi.
drop view if exists v_pul_hisoblar;
create view v_pul_hisoblar as
select
  a.id,
  a.code,
  a.name,
  a.subtitle,
  a.kassa_turi,
  a.parent_id,
  coalesce(a.currency, 'UZS')       as currency,
  (a.kassa_turi = 'filial')         as is_filial
from accounts a
where a.is_active
  and a.type = 'aktiv'
  and a.code like '5%'
  -- 5400 "Hodim xarajat kassalari" — konteyner, unga to'g'ridan pul yozilmaydi
  and coalesce(a.kassa_turi, '') <> 'xarajat_guruh';

alter view v_pul_hisoblar set (security_invoker = on);
revoke all on v_pul_hisoblar from public, anon;
grant select on v_pul_hisoblar to authenticated;

comment on view v_pul_hisoblar is
  'Pul hisoblari tanlagichi (cashflow.html). kassa_turi bo''yicha: markaziy/filial/xarajat. '
  'xarajat = hodim kassalari (54xx, parent 5400). Guruh qatorining o''zi chiqmaydi.';

-- 0.3 Tekshiruv: hodim kassalari view'ga tushdimi, guruh tushmadimi
do $$
declare
  n_guruh int;
begin
  select count(*) into n_guruh
    from v_pul_hisoblar where kassa_turi = 'xarajat_guruh';
  if n_guruh > 0 then
    raise exception 'v_pul_hisoblar ichida xarajat_guruh qatori bor — filtr ishlamadi';
  end if;
  raise notice 'v_pul_hisoblar: % ta hodim kassasi, % ta markaziy, % ta filial',
    (select count(*) from v_pul_hisoblar where kassa_turi = 'xarajat'),
    (select count(*) from v_pul_hisoblar where kassa_turi = 'markaziy'),
    (select count(*) from v_pul_hisoblar where kassa_turi = 'filial');
end $$;

-- 0-BOSQICH TUGADI ----------------------------------------------------
