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
--  TALAB: PROVODKA_VALYUTA.sql (pul_turi, v_kassa_turlar) RUN qilingan bo'lsin.
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
-- 5. v_filial_sync_mapping — n8n uchun YAGONA jadval
-- ---------------------------------------------------------------------
-- Muammo: som turlari (naqd/click/payme) `pul_turi` bilan belgilangan, dollar
-- esa `pul_turi` EMAS — u valyuta child'i (currency='USD'). Ya'ni ular ikki xil
-- joyda. n8n ikkita so'rov qilib, ikki xil mantiq yozmasin — shu view ikkovini
-- birlashtirib, TO'G'RIDAN-TO'G'RI Aros javobidagi maydon nomi bilan beradi.
--
-- n8n javobidagi filial obyekti:  { id, cash, click, payme, dollar_usd, ... }
-- Shu view:                        aros_maydon = 'cash'|'click'|'payme'|'dollar_usd'
-- Ya'ni sync shunchaki: har filial uchun aros_maydon bo'yicha account_id ni olib,
--   Dt account_id / Kt boshlangich_kapital_id()  yozadi.
create or replace view v_filial_sync_mapping as
-- (a) som turlari — pul_turi child'lari
select p.filial_ref,
       p.id                     as kassa_id,
       p.code                   as kassa_code,
       p.name                   as kassa_name,
       case t.pul_turi
         when 'naqd'  then 'cash'
         when 'click' then 'click'
         when 'payme' then 'payme'
       end                      as aros_maydon,
       t.pul_turi               as turi,
       t.account_id,
       t.code                   as hisob_code,
       'UZS'::text              as currency
  from accounts p
  join v_kassa_turlar t on t.parent_id = p.id
 where p.kassa_turi = 'filial'
   and p.filial_ref is not null
   and p.is_active

union all

-- (b) dollar — pul_turi EMAS, valyuta child'i (currency='USD')
select p.filial_ref,
       p.id,
       p.code,
       p.name,
       'dollar_usd'::text       as aros_maydon,
       'dollar'::text           as turi,
       c.id                     as account_id,
       c.code                   as hisob_code,
       c.currency
  from accounts p
  join accounts c on c.parent_id = p.id and c.is_active and c.currency = 'USD'
 where p.kassa_turi = 'filial'
   and p.filial_ref is not null
   and p.is_active;

alter view v_filial_sync_mapping set (security_invoker = on);
revoke all on v_filial_sync_mapping from public, anon;
grant select on v_filial_sync_mapping to authenticated, service_role;

-- security_invoker=on: view ostidagi jadval/viewlar CHAQIRUVCHI huquqi bilan
-- o'qiladi. n8n service_role bilan keladi, shuning uchun ichkaridagilarga ham
-- aniq grant kerak (PROVODKA_VALYUTA.sql'da faqat authenticated berilgan edi).
grant select on v_kassa_turlar to service_role;
grant select on v_hisob_bal   to service_role;

comment on view v_filial_sync_mapping is
  'n8n Aros sync uchun: filial_ref + aros_maydon (cash|click|payme|dollar_usd) -> account_id. '
  'Som turlari pul_turi child''laridan, dollar esa USD valyuta child''idan keladi.';


-- ---------------------------------------------------------------------
-- 6. TEKSHIRUV
-- ---------------------------------------------------------------------

-- 6.1 Kapital hisobi balansda KAPITAL bo'limida ko'rinadimi.
--     (Hozir qoldig'i 0 — sync hali yozmagan. Muhimi: bolim = 'KAPITAL'.)
select bolim, section, code, name, amount
  from balans(current_date)
 where code = (select code from accounts
                where type = 'kapital'
                  and lower(btrim(name)) = 'boshlang''ich kapital');
-- Agar BU SO'ROV BO'SH qaytarsa — bu normal: balans() qoldig'i 0 bo'lgan
-- hisobni ko'rsatmasligi mumkin. Sync birinchi yozuvni yozgach paydo bo'ladi.

-- 6.2 Mapping to'ldimi — har filial uchun 4 qator bo'lishi kerak
--     (cash, click, payme, dollar_usd):
select kassa_code, kassa_name, filial_ref,
       count(*)                                   as qatorlar,
       string_agg(aros_maydon, ', ' order by aros_maydon) as maydonlar
  from v_filial_sync_mapping
 group by kassa_code, kassa_name, filial_ref
 order by kassa_code;

-- 6.3 Yetishmayotgani bormi (4 tadan kam bo'lgan filiallar):
select kassa_code, kassa_name, count(*) as bor
  from v_filial_sync_mapping
 group by kassa_code, kassa_name
having count(*) < 4
 order by kassa_code;
-- Bo'sh chiqishi kerak. Chiqsa — PROVODKA_VALYUTA_SEED.sql RUN qilinmagan
-- yoki o'sha kassada USD child yo'q.

-- 6.4 To'liq mapping (n8n ga ko'chirish uchun):
select filial_ref, kassa_code, aros_maydon, turi, hisob_code, account_id
  from v_filial_sync_mapping
 order by kassa_code, aros_maydon;
