-- =====================================================================
--  PROVODKA_KAPITAL.sql — "Boshlang'ich kapital" hisobi + n8n sync mapping
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  NEGA KERAK:
--    Wipe'dan keyin daftar bo'sh, Aros'da esa filiallarda haqiqiy pul turibdi.
--    O'sha pulni daftarga kiritish kerak — lekin bu TUSHUM EMAS, u allaqachon
--    ishlab topilgan pul. Agar Kt tomoniga 9010 (savdo tushumi) yozilsa,
--    o'sha kunning P&L'ida butun kassa puli daromad bo'lib ko'rinadi va
--    hisobot shishadi.
--
--    To'g'ri yozuv:
--        Dt <filial kassaning tur child'i>      (aktiv o'sadi — pul keldi)
--        Kt <Boshlang'ich kapital>              (kapital o'sadi — egasining puli)
--
--    Balansda: AKTIV o'sdi, KAPITAL o'sdi -> tenglik saqlanadi,
--    P&L'ga esa umuman tegmaydi. Aynan shu kerak.
--
--  IDEMPOTENT: hisob bor bo'lsa qayta yaratilmaydi, kod ham o'zgarmaydi.
--  Bir necha marta RUN qilish xavfsiz.
--
--  TALAB: accounts.pul_turi ustuni bo'lsin (PROVODKA_VALYUTA.sql).
--         Mapping to'lishi uchun tur child'lari ham ochilgan bo'lsin
--         (PROVODKA_VALYUTA_SEED.sql) — aks holda 6-bo'lim buni ko'rsatadi.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. OLDINDAN KO'RISH — 8xxx va kapital hisoblari hozir qanday
-- ---------------------------------------------------------------------
select code, name, type, section, is_active
  from accounts
 where code like '8%' or type = 'kapital'
 order by code;
-- Eslatma: `8710 Yig'ilgan sof foyda` — balans() ichida HISOBLANADIGAN
-- sintetik qator, accounts jadvalida qatori yo'q. Shuning uchun 87xx bo'sh.


-- ---------------------------------------------------------------------
-- 2. HISOBNI OCHISH
-- ---------------------------------------------------------------------
do $kap$
declare
  v_id    uuid;
  v_code  text;
  v_kod   text := '8720';        -- ⚙️ istalgan kod; band bo'lsa keyingi bo'sh 87xx olinadi
  v_next  int;
begin
  -- Bor bo'lsa tegmaymiz (nom bo'yicha — kod o'zgargan bo'lishi mumkin)
  select id, code into v_id, v_code
    from accounts
   where type = 'kapital'
     and lower(btrim(name)) = 'boshlang''ich kapital'
   limit 1;

  if v_id is not null then
    if not (select is_active from accounts where id = v_id) then
      update accounts set is_active = true where id = v_id;
      raise notice 'QAYTA FAOLLASHTIRILDI: % (%)', v_code, v_id;
    else
      raise notice 'ALLAQACHON BOR: % (%) — hech narsa o''zgarmadi', v_code, v_id;
    end if;
    return;
  end if;

  -- Kod: 8720 band bo'lsa 87xx dagi keyingi bo'sh raqam
  if exists (select 1 from accounts where code = v_kod) then
    select coalesce(max(substring(code from 3 for 2)::int), 19) + 1
      into v_next
      from accounts
     where code ~ '^87[0-9]{2}$';
    if v_next > 99 then
      raise exception '87xx bloki to''ldi — kodni qo''lda tanlang (v_kod o''zgaruvchisi)';
    end if;
    v_kod := '87' || lpad(v_next::text, 2, '0');
  end if;

  insert into accounts(code, name, type, section, is_active)
  values (v_kod, 'Boshlang''ich kapital', 'kapital', 'kapital', true)
  returning id into v_id;

  raise notice 'OCHILDI: % (%)', v_kod, v_id;
end
$kap$;


-- ---------------------------------------------------------------------
-- 3. ⬇️ N8N UCHUN KERAKLI QIYMAT — shuni ko'chirib oling
-- ---------------------------------------------------------------------
select id   as kapital_account_id,
       code as kapital_code,
       name, type, section
  from accounts
 where type = 'kapital'
   and lower(btrim(name)) = 'boshlang''ich kapital';


-- ---------------------------------------------------------------------
-- 4. boshlangich_kapital_id() — n8n uuid'ni QATTIQ YOZMASIN
-- ---------------------------------------------------------------------
-- Sync workflow'ida uuid'ni qo'lda yozib qo'ysa, hisob qayta yaratilganda
-- (yoki boshqa muhitda) jimgina noto'g'ri hisobga yozib ketadi. Funksiya
-- orqali olsa — har doim to'g'risini topadi.
create or replace function boshlangich_kapital_id()
returns uuid
language sql
stable
as $$
  select id from accounts
   where type = 'kapital'
     and lower(btrim(name)) = 'boshlang''ich kapital'
     and is_active
   limit 1;
$$;

revoke all on function boshlangich_kapital_id() from public, anon;
grant execute on function boshlangich_kapital_id() to authenticated, service_role;

comment on function boshlangich_kapital_id() is
  'Boshlang''ich kapital hisobining id''si. Wipe''dan keyingi Aros boshlang''ich '
  'qoldig''i shunga yoziladi: Dt tur child / Kt shu hisob (9010 EMAS).';


-- ---------------------------------------------------------------------
-- 5. v_filial_sync_mapping — n8n uchun YAGONA mapping
-- ---------------------------------------------------------------------
-- FAQAT accounts ustunlaridan quriladi. Boshqa view'ga (v_kassa_turlar)
-- bog'lanmaydi — bitta bog'liqlik kamaysa, bo'shab qolish sababi ham kamayadi
-- va service_role uchun grant zanjiri kerak bo'lmaydi.
--
-- Aros bog'lanishi accounts'dagi ikki ustunda:
--   filial_ref   — Aros CACHIER id. Sync aynan shuni ishlatadi:
--                  billing/cachiers/{filial_ref}/
--   warehouse_id — Aros WAREHOUSE id. Solishtirish/tekshirish uchun beriladi,
--                  join kaliti sifatida ishlatilmaydi.
--
-- Tur ikki xil joyda yashaydi va shu yerda birlashtiriladi:
--   naqd/click/payme -> accounts.pul_turi   (currency = 'UZS')
--   dollar           -> accounts.currency = 'USD'  (pul_turi NULL!)
--
-- Natija ustunlari to'g'ridan-to'g'ri Aros javobidagi maydon nomlariga mos:
--   aros_maydon = 'cash' | 'click' | 'payme' | 'dollar_usd'
-- Ya'ni sync: har filial obyektining har maydoni uchun account_id ni olib,
--   Dt account_id / Kt boshlangich_kapital_id()  yozadi.
--
-- ⚠️ kassa_turi bo'yicha FILTRLAMAYDI. Avvalgi variantda `kassa_turi='filial'`
--    sharti bor edi — agar o'sha ustunda boshqa qiymat tursa view jimgina
--    bo'shab qolardi. Endi yagona shart: filial_ref to'ldirilgan bo'lsin,
--    ya'ni "bu kassa Aros cachier'iga bog'langan".
drop view if exists v_filial_sync_mapping;
create view v_filial_sync_mapping as
select
  k.filial_ref,                                   -- Aros cachier id (join kaliti)
  k.warehouse_id,                                 -- Aros warehouse id (ma'lumot uchun)
  k.id                       as kassa_id,
  k.code                     as kassa_code,
  k.name                     as kassa_name,
  k.kassa_turi,
  case
    when c.pul_turi = 'naqd'  then 'cash'
    when c.pul_turi = 'click' then 'click'
    when c.pul_turi = 'payme' then 'payme'
    when c.currency = 'USD'   then 'dollar_usd'
  end                        as aros_maydon,      -- Aros JSON maydoni
  coalesce(c.pul_turi, 'dollar')                as turi,
  c.id                       as account_id,       -- ⬅️ sync shu hisobga yozadi
  c.code                     as hisob_code,
  coalesce(c.currency, 'UZS')                   as currency
from accounts k
join accounts c
  on  c.parent_id = k.id
  and c.is_active
  and c.section   = 'pul'
  and (c.pul_turi in ('naqd','click','payme') or c.currency = 'USD')
where k.section = 'pul'
  and k.is_active
  and k.parent_id is null          -- kassaning o'zi, bola-hisob emas
  and coalesce(k.currency,'UZS') = 'UZS'
  and k.filial_ref is not null;    -- Aros bilan bog'langan kassalar

alter view v_filial_sync_mapping set (security_invoker = on);
revoke all on v_filial_sync_mapping from public, anon;
grant select on v_filial_sync_mapping to authenticated, service_role;

-- security_invoker=on: ostidagi jadval CHAQIRUVCHI huquqi bilan o'qiladi.
-- n8n service_role bilan keladi.
grant select on accounts to service_role;

comment on view v_filial_sync_mapping is
  'n8n Aros sync: filial_ref (cachier id) + aros_maydon (cash|click|payme|dollar_usd) -> account_id. '
  'Faqat accounts ustunlaridan quriladi. Som turlari pul_turi''dan, dollar currency=''USD'' dan.';


-- ---------------------------------------------------------------------
-- 6. DIAGNOSTIKA — mapping BO'SH chiqsa, sababi shu yerda ko'rinadi
-- ---------------------------------------------------------------------
-- Voronka: yuqoridan pastga qarab qaysi qadamda 0 ga tushganini ko'rasiz.
select '1. pul kassalari (parent, UZS, faol)' as qadam,
       count(*) as soni
  from accounts
 where section='pul' and is_active and parent_id is null
   and coalesce(currency,'UZS')='UZS'
union all
select '2. ...shundan filial_ref to''ldirilgan (Aros cachier)',
       count(*)
  from accounts
 where section='pul' and is_active and parent_id is null
   and coalesce(currency,'UZS')='UZS' and filial_ref is not null
union all
select '3. som turi child''lari (pul_turi: naqd/click/payme)',
       count(*)
  from accounts
 where section='pul' and is_active and parent_id is not null
   and pul_turi in ('naqd','click','payme')
union all
select '4. USD child''lari (currency=USD)',
       count(*)
  from accounts
 where section='pul' and is_active and parent_id is not null and currency='USD'
union all
select '5. MAPPING QATORLARI (natija)',
       count(*)
  from v_filial_sync_mapping;

-- Qadamlarni o'qish:
--   2 = 0  -> kassalarda filial_ref to'ldirilmagan. Aros bog'lanishi yo'q:
--             sozlama-dev.html "Filiallarni bog'lash" (aros-filial-map) ni ishlating.
--   3 = 0  -> PROVODKA_VALYUTA_SEED.sql hali RUN qilinmagan (tur child'lari yo'q).
--   4 = 0  -> USD child'lari yo'q: SEED'da p_usd=false bo'lgan yoki
--             PROVODKA_KASSA_MODEL.sql B-QISM eski valyuta kassalarni bog'lamagan.
--   5 = 0, lekin 2/3 > 0 -> tur child'lari filial_ref'i BOR kassalarga emas,
--             boshqa kassalarga tegishli. 6.1 dagi so'rov buni ko'rsatadi.

-- 6.1 Kassalar va ularning Aros bog'lanishi + nechta child'i bor
select k.code, k.name, k.kassa_turi,
       k.filial_ref, k.warehouse_id,
       count(c.id) filter (where c.pul_turi is not null) as som_turi,
       count(c.id) filter (where c.currency = 'USD')     as usd
  from accounts k
  left join accounts c on c.parent_id = k.id and c.is_active and c.section='pul'
 where k.section='pul' and k.is_active and k.parent_id is null
   and coalesce(k.currency,'UZS')='UZS'
 group by k.code, k.name, k.kassa_turi, k.filial_ref, k.warehouse_id
 order by k.code;

-- 6.2 Kapital hisobi balansda KAPITAL bo'limida ko'rinadimi
--     (qoldig'i 0 bo'lsa balans() uni ko'rsatmasligi mumkin — bu normal)
select bolim, section, code, name, amount
  from balans(current_date)
 where code = (select code from accounts
                where type = 'kapital'
                  and lower(btrim(name)) = 'boshlang''ich kapital');

-- 6.3 Har Aros-bog'langan kassada 4 qator bo'lishi kerak
select kassa_code, kassa_name, filial_ref,
       count(*) as qatorlar,
       string_agg(aros_maydon, ', ' order by aros_maydon) as maydonlar
  from v_filial_sync_mapping
 group by kassa_code, kassa_name, filial_ref
 order by kassa_code;

-- 6.4 4 tadan kam bo'lganlar (bo'sh chiqishi kerak)
select kassa_code, kassa_name, count(*) as bor,
       string_agg(aros_maydon, ', ' order by aros_maydon) as bor_maydonlar
  from v_filial_sync_mapping
 group by kassa_code, kassa_name
having count(*) < 4
 order by kassa_code;

-- 6.5 ⬇️ TO'LIQ MAPPING — n8n ga shuni bering
select filial_ref, warehouse_id, kassa_code, aros_maydon, turi, hisob_code, account_id
  from v_filial_sync_mapping
 order by kassa_code, aros_maydon;
