-- =====================================================================
--  DIAG_AYLANMA_KASSA.sql — «Sof aylanma kapital» A bo'limi (pul) diagnostikasi
--  FAQAT O'QIYDI. Natijani (3 ta jadval) Fable'ga yuboring.
-- ---------------------------------------------------------------------
--  Savol: nega filial kassalari (5228, 5210, 5213 …) snapshot'da MINUS?
--  Gipoteza: Balans Sync har soat naqd/click/payme/USD BOLALARINI Aros'ga
--  tenglashtiradi, lekin parent (5213) ning O'Z qoldig'i (bolalarga bo'linmasdan
--  oldingi eski yozuvlar) manfiy qolib ketgan → v_kassa_card.jami = o'z + bolalar
--  manfiy chiqadi. Quyidagi 1-jadval buni ko'rsatadi.
-- =====================================================================

-- 1. Har markaziy/filial kassa: o'z qoldig'i, bolalari yig'indisi, karta jami
with k as (
  select a.id, a.code, a.name, a.kassa_turi, a.is_active, a.filial_ref, a.aros_title
    from accounts a
   where a.kassa_turi in ('markaziy', 'filial') and a.parent_id is null
),
oz as (
  select k.id, coalesce(sum(l.debit - l.credit), 0) as oz_uzs
    from k
    left join entry_line l on l.account_id = k.id
    left join entry e on e.id = l.entry_id
   where e.id is null or (e.status = 'posted' and e.is_deleted = false)
   group by k.id
),
bola as (
  select c.parent_id,
         coalesce(sum(case when c.currency = 'UZS' then l.debit - l.credit else 0 end), 0) as bola_uzs,
         coalesce(sum(case when c.currency <> 'UZS' then l.debit - l.credit else 0 end), 0) as bola_val_uzs,
         coalesce(sum(case when c.currency = 'USD' then
                    (case when l.debit > 0 then coalesce(l.fc_amount, 0) else -coalesce(l.fc_amount, 0) end)
                    else 0 end), 0) as bola_usd,
         count(distinct c.id) as bola_soni,
         string_agg(distinct coalesce(c.pul_turi, c.currency), ', ') as bola_turlari
    from accounts c
    join k on k.id = c.parent_id
    left join entry_line l on l.account_id = c.id
    left join entry e on e.id = l.entry_id
   where e.id is null or (e.status = 'posted' and e.is_deleted = false)
   group by c.parent_id
)
select k.code, k.name, k.kassa_turi, k.is_active, k.filial_ref, k.aros_title,
       oz.oz_uzs                                   as parent_oz_qoldigi,
       coalesce(b.bola_uzs, 0)                     as bolalar_uzs,
       coalesce(b.bola_val_uzs, 0)                 as bolalar_valyuta_uzs,
       coalesce(b.bola_usd, 0)                     as bolalar_usd,
       coalesce(b.bola_soni, 0)                    as bola_soni,
       b.bola_turlari,
       vc.jami                                     as karta_jami,
       vc.usd                                      as karta_usd
  from k
  left join oz on oz.id = k.id
  left join bola b on b.parent_id = k.id
  left join v_kassa_card vc on vc.id = k.id
 order by vc.jami nulls last;

-- 2. Aros jonli balans (filial-dev «Yangilash» oxirgi natijasi) — solishtirish uchun
select fs.synced_at, fs.synced_by_name, fs.total,
       r ->> 'name' as nom, r ->> 'id' as cachier_id, r ->> 'warehouse_id' as warehouse_id,
       r ->> 'cash' as cash, r ->> 'click' as click, r ->> 'payme' as payme, r ->> 'usd' as usd,
       r ->> 'jami' as jami
  from filial_snapshot fs
  cross join lateral jsonb_array_elements(coalesce(fs.data -> 'rows', '[]'::jsonb)) r
 where fs.id = 1
 order by (r ->> 'jami')::numeric desc nulls last;

-- 3. v_kassa_card ustunlari (is_active bormi, nechta qator markaziy/filial)
select column_name from information_schema.columns
 where table_schema = 'public' and table_name = 'v_kassa_card' order by ordinal_position;
select kassa_turi, count(*) as qator, sum(jami) as jami
  from v_kassa_card group by kassa_turi order by 1;

-- 4. 🔴 RLS FARQI: RPC (security definer, egasi postgres) RLS'ni CHETLAB hamma yozuvni ko'radi,
--    brauzerdagi admin esa policy orqali. Shu ikki qarash farq qilsa — snapshot minus, kassa-dev musbat.
--    Quyidagi blokni ALOHIDA (begin…rollback bilan birga) RUN qiling — u admin sifatida o'qiydi.
begin;
select set_config('request.jwt.claims',
       json_build_object('sub', (select id::text from profiles where role = 'admin' limit 1),
                         'role', 'authenticated')::text, true);
set local role authenticated;
select code, name, kassa_turi, jami as admin_korgan_jami, usd
  from v_kassa_card
 where kassa_turi in ('markaziy', 'filial')
 order by jami;
rollback;

-- 5. Postgres (RLS'siz) ko'rgan — 4 bilan solishtiring; farq bo'lsa qaysi kassalarda?
select code, name, kassa_turi, jami as postgres_korgan_jami, usd
  from v_kassa_card
 where kassa_turi in ('markaziy', 'filial')
 order by jami;

-- 6. entry / entry_line RLS policy'lari (qaysi yozuvlar adminga ko'rinmaydi?)
select tablename, policyname, cmd, roles, qual
  from pg_policies
 where schemaname = 'public' and tablename in ('entry', 'entry_line')
 order by tablename, policyname;
