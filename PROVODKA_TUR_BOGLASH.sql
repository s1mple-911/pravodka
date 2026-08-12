-- =====================================================================
-- PROVODKA_TUR_BOGLASH.sql
-- Eski "· Naqd / · Payme / · Click" hisoblarini ILDIZ kassaga bog'lash
-- =====================================================================
-- MUAMMO (hodim-dev.html kassa ro'yxatida ko'ringan):
--   5351  "Abrorxo'ja Ahmadov · Naqd"   ← parent_id BO'SH, pul_turi BO'SH
--   5352  "Abrorxo'ja Ahmadov · Payme"  ← parent_id BO'SH, pul_turi BO'SH
--   5405  "Abrorxo'ja Ahmadov"          ← ildiz kassa
-- Bu hisoblar `create_pul_turi_child()` dan OLDIN qo'lda ochilgan, shuning uchun
-- ustunlari to'ldirilmagan. Natijada:
--   1) UI ularni bola deb tanimaydi → bitta hodim 3 ta kassa bo'lib ko'rinadi
--   2) perm_op_key() ham parentga bog'lay olmaydi → cheklangan foydalanuvchi
--      "· Naqd" hisobidan xarajat yozsa entry_line guard triggeri 42501 beradi
--   3) v_kassa_card ularni alohida karta qilib chizadi
--
-- Bu fayl FAQAT `parent_id` va `pul_turi` ustunlarini to'ldiradi.
-- Pul harakati YO'Q: entry / entry_line / qoldiqlar TEGILMAYDI.
--
-- ⚠️ TARTIB: avval 1-BO'LIMni RUN qilib RO'YXATNI KO'R. Hammasi to'g'ri bo'lsa
--    2-BO'LIMni RUN qil. 3-BO'LIM — tekshiruv, 4-BO'LIM — orqaga qaytarish.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. KO'RISH (o'zgartirmaydi) — nima bog'lanadi?
-- ---------------------------------------------------------------------
-- Nom naqshi: "<ildiz nomi> · <tur>". create_pul_turi_child va
-- create_valyuta_child ham aynan shunday nom beradi (parent.name || ' · ' || tur),
-- shuning uchun nomdan ildizni tiklash ishonchli.
with bola as (
  select c.id, c.code, c.name, c.parent_id, c.pul_turi, c.currency, c.kassa_turi,
         lower(regexp_replace(c.name, '\s*·\s*(Naqd|Click|Payme|Terminal|Karta|Plastik)\s*$', '', 'i')) as ildiz_nom,
         lower((regexp_match(c.name, '·\s*(Naqd|Click|Payme|Terminal|Karta|Plastik)\s*$', 'i'))[1]) as turi
    from accounts c
   where c.is_active
     and c.type = 'aktiv' and c.code like '5%'
     and c.name ~* '·\s*(Naqd|Click|Payme|Terminal|Karta|Plastik)\s*$'
     and c.pul_turi is null          -- allaqachon to'ldirilganlarga tegmaymiz
)
-- ⚠️ Shartlar 2-BO'LIM (UPDATE) bilan AYNAN bir xil bo'lishi shart — aks holda
--    bu yerda ko'rilgan qator UPDATE'da jimgina tashlab ketilardi.
--    `holat` ustuni: nima bo'lishini ochiq yozadi.
select b.code   as bola_kod,
       b.name   as bola_nom,
       b.turi   as yoziladigan_pul_turi,
       p.code   as ildiz_kod,
       p.name   as ildiz_nom,
       b.parent_id as hozirgi_parent,
       p.id     as yoziladigan_parent,
       case when count(*) over (partition by b.id) > 1
            then 'TASHLANADI — shu nomda bir nechta ildiz kassa bor'
            else 'BOG''LANADI' end as holat
  from bola b
  join accounts p
    on p.is_active and p.type = 'aktiv' and p.code like '5%'
   and lower(p.name) = b.ildiz_nom
   and p.id <> b.id
   and p.pul_turi is null                        -- ildizning o'zi bola bo'lmasin
   and coalesce(p.currency,'UZS') = 'UZS'
 order by p.code, b.code;

-- Ildizi UMUMAN topilmagan "· Tur" hisoblari (yuqoridagi ro'yxatga tushmaydi):
select c.code, c.name, 'ildiz topilmadi — qo''lda ko''rish kerak' as holat
  from accounts c
 where c.is_active and c.type = 'aktiv' and c.code like '5%'
   and c.name ~* '·\s*(Naqd|Click|Payme|Terminal|Karta|Plastik)\s*$'
   and c.pul_turi is null
   and not exists (
     select 1 from accounts p
      where p.is_active and p.type = 'aktiv' and p.code like '5%'
        and p.pul_turi is null and coalesce(p.currency,'UZS') = 'UZS' and p.id <> c.id
        and lower(p.name) = lower(regexp_replace(c.name, '\s*·\s*(Naqd|Click|Payme|Terminal|Karta|Plastik)\s*$', '', 'i'))
   )
 order by c.code;


-- ---------------------------------------------------------------------
-- 2. BOG'LASH (UPDATE) — 1-bo'lim ro'yxati to'g'ri bo'lsa RUN qil
-- ---------------------------------------------------------------------
-- Xavfsizlik shartlari:
--   • faqat pul_turi BO'SH bo'lganlar (ikki marta ishlatish zararsiz — idempotent)
--   • ildiz nomi AYNAN bitta hisobga mos kelishi shart (ko'p bo'lsa tashlab ketiladi)
--   • ildizning o'zi bola bo'lmasligi kerak (zanjir yasalmasin)
-- ⚠️ FAQAT PUL TURLARI (Naqd/Click/Payme/…). "· USD" kabi VALYUTA hisoblari bu yerga
--    KIRMAYDI: ular uchun `currency` ustuni to'ldirilishi kerak, `pul_turi` emas —
--    ikkisini aralashtirish v_kassa_card va konvertni buzardi. Ustunsiz valyuta
--    hisoblari bo'lsa alohida ko'rib chiqiladi (hodim-dev.html nom-fallback'i
--    ularni vaqtincha baribir to'g'ri guruhlaydi).

-- Orqaga qaytarish uchun NUSXA (4-bo'limga qara). Doimiy jadval — RUN qilingach qoladi.
create table if not exists tur_boglash_backup(
  id uuid primary key,
  eski_parent_id uuid,
  eski_pul_turi text,
  eski_currency text,
  yozildi timestamptz not null default now()
);

do $$
declare n int;
begin
  -- 1) Avval o'zgaradigan qatorlarning ESKI holatini saqlaymiz
  insert into tur_boglash_backup(id, eski_parent_id, eski_pul_turi, eski_currency)
  select a.id, a.parent_id, a.pul_turi, a.currency
    from accounts a
   where a.is_active and a.type = 'aktiv' and a.code like '5%'
     and a.name ~* '·\s*(Naqd|Click|Payme|Terminal|Karta|Plastik)\s*$'
     and a.pul_turi is null
  on conflict (id) do nothing;

  with bola as (
    select c.id, c.name,
           lower(regexp_replace(c.name, '\s*·\s*(Naqd|Click|Payme|Terminal|Karta|Plastik)\s*$', '', 'i')) as ildiz_nom,
           lower((regexp_match(c.name, '·\s*(Naqd|Click|Payme|Terminal|Karta|Plastik)\s*$', 'i'))[1]) as turi
      from accounts c
     where c.is_active and c.type = 'aktiv' and c.code like '5%'
       and c.name ~* '·\s*(Naqd|Click|Payme|Terminal|Karta|Plastik)\s*$'
       and c.pul_turi is null
  ),
  mos as (
    select b.id, b.turi, p.id as pid
      from bola b
      join accounts p
        on p.is_active and p.type = 'aktiv' and p.code like '5%'
       and lower(p.name) = b.ildiz_nom
       and p.id <> b.id
       and p.pul_turi is null                    -- ildizning o'zi bola bo'lmasin
       and coalesce(p.currency,'UZS') = 'UZS'
  ),
  yagona as (                                     -- ildiz nomi bitta hisobga mos kelsin
    select id, min(turi) as turi, min(pid::text)::uuid as pid
      from mos group by id having count(*) = 1
  )
  update accounts a
     set parent_id = y.pid,
         pul_turi  = y.turi,
         currency  = coalesce(a.currency, 'UZS')
    from yagona y
   where a.id = y.id;
  get diagnostics n = row_count;
  raise notice 'Bog''landi: % ta tur hisobi', n;
end $$;


-- ---------------------------------------------------------------------
-- 3. TEKSHIRUV — bog'langach ro'yxat qanday ko'rinadi
-- ---------------------------------------------------------------------
-- Har ildiz kassa BITTA qator, bolalari alohida ustunda.
select p.code as kassa_kod, p.name as kassa, p.subtitle,
       coalesce(string_agg(c.code || ' ' || coalesce(c.pul_turi, c.currency, '?'),
                           ', ' order by c.code), '—') as turlari
  from accounts p
  left join accounts c
    on c.parent_id = p.id and c.is_active
   and (c.pul_turi is not null or coalesce(c.currency,'UZS') <> 'UZS')
 where p.is_active and p.type = 'aktiv' and p.code like '5%'
   and p.pul_turi is null and coalesce(p.currency,'UZS') = 'UZS'
   and p.kassa_turi is distinct from 'xarajat_guruh'
 group by p.code, p.name, p.subtitle
 order by p.code;

-- Bog'lanmay qolgan "· Tur" hisoblari (ildizi topilmagan) — qo'lda ko'rish uchun
select code, name, parent_id, pul_turi
  from accounts
 where is_active and type = 'aktiv' and code like '5%'
   and name ~* '·\s*(Naqd|Click|Payme|Terminal|Karta|Plastik)\s*$'
   and pul_turi is null
 order by code;


-- ---------------------------------------------------------------------
-- 4. ORQAGA QAYTARISH — tur_boglash_backup jadvalidan (AYNAN o'zgarganlar)
-- ---------------------------------------------------------------------
-- 2-bo'lim o'zgartirishdan OLDIN eski holatni `tur_boglash_backup` ga yozadi,
-- shuning uchun qaytarish aniq id'lar bo'yicha — kod diapazoniga taxmin qilmaydi
-- va create_pul_turi_child ochgan haqiqiy bolalarni TEGMAYDI.
--
-- Avval ko'r:
--   select b.*, a.code, a.name, a.parent_id as hozirgi_parent, a.pul_turi as hozirgi_turi
--     from tur_boglash_backup b join accounts a on a.id = b.id order by a.code;
--
-- Qaytarish:
--   update accounts a
--      set parent_id = b.eski_parent_id,
--          pul_turi  = b.eski_pul_turi,
--          currency  = b.eski_currency
--     from tur_boglash_backup b
--    where a.id = b.id;
--
-- Hammasi joyida bo'lsa nusxani o'chirish mumkin (majburiy emas):
--   drop table tur_boglash_backup;
