-- =====================================================================
--  PROVODKA_CASHFLOW_FIX.sql — cashflow kassa bo'yicha tur bolalarini ham yig'sin
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  MUAMMO (o'lchangan):
--     pul_qoldiq(current_date, <filial kassa id>) -> 0
--     v_kassa_card.jami                           -> Sergeli 2.2 mln, Nukus 5.8 mln
--     Sabab: pul endi kassaning TUR BOLALARIDA turadi (naqd/click/payme + USD
--     child), parent kassaning o'z qoldig'i esa 0. pul_qoldiq() va cashflow()
--     esa faqat berilgan BITTA account_id ni ko'radi — bolalarni yig'maydi.
--     Natija: cashflow sahifasida kassa tanlansa hammasi bo'sh chiqadi.
--
--  YECHIM: eski funksiyalarga TEGILMAYDI (ular ishlab turibdi va boshqa
--     joylardan chaqirilishi mumkin). Ikkita YANGI funksiya qo'shiladi:
--
--        pul_qoldiq_kassa(p_date, p_kassa default null)   -> numeric
--        cashflow_kassa(p_from, p_to, p_kassa default null)
--
--     Ikkovi ham "kassa oilasi" bilan ishlaydi: kassaning O'ZI + hamma
--     tur/valyuta bolasi (aynan v_kassa_card.jami qanday yig'sa, shunday).
--     p_kassa = null bo'lsa — eski funksiyalarga delegat qiladi (hamma
--     kassalar holati allaqachon to'g'ri ishlaydi, takrorlashning hojati yo'q).
--
--  ⚠️ cashflow_kassa ESKI cashflow() USTIDA QURILGAN, uni qayta yozmaydi.
--     Sabab: cashflow() ning tasnifi (section, qarshi hisob nomi, ko'p satrli
--     yozuvlarni taqsimlashi) butun ilovada bir xil bo'lib qolishi kerak.
--     Oila a'zolarining har biri uchun cashflow() chaqiriladi, keyin
--     natijalar yig'iladi va OILA ICHIDAGI harakat olib tashlanadi:
--        cashflow() qarshi tomonning kodini qaytaradi, shuning uchun
--        "naqd -> click" (tur_convert) satri code = o'sha oila a'zosi
--        bo'ladi va filtrga tushadi. Ya'ni ichki ko'chirish KIRIM/CHIQIM
--        bo'lib ikki marta ko'rinmaydi.
--     Tashqi harakat esa saqlanadi: filialdan markaziy kassaga jo'natilgan
--     pul avvalgidek CHIQIM bo'lib ko'rinadi (bu to'g'ri — pul shu kassadan
--     chiqqan; cashflow.html izohi ham shuni yozadi).
--
--  SECURITY INVOKER — ataylab, eski cashflow()/pul_qoldiq() bilan bir xil.
--     DEFINER bo'lsa funksiya EGASI huquqi bilan o'qir edi va RLS chetlab
--     o'tilardi: cheklangan foydalanuvchi o'ziga berilmagan kassaning
--     oqimini ham ko'rib qolishi mumkin. Yangi funksiya eski xulqni
--     o'zgartirmasligi kerak.
--
--  IMZOLAR: hech biri o'zgarmadi. Prod klienti eski cashflow()/pul_qoldiq()
--     ni chaqiraverаdi va avvalgidek ishlaydi; cashflow-dev.html yangisiga
--     o'tkazildi.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. AVVAL: eski funksiyalarning imzosi kutilganidekmi
-- ---------------------------------------------------------------------
-- cashflow_kassa cashflow() ustunlariga (yonalish, section, code, name,
-- amount) tayanadi. Quyidagi so'rov shuni ko'rsatadi — mos kelmasa
-- 2-bo'limdagi `returns table(...)` ni o'sha turlarga keltiring.
select p.proname,
       pg_get_function_identity_arguments(p.oid) as argumentlar,
       pg_get_function_result(p.oid)             as natija
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('cashflow', 'pul_qoldiq')
 order by p.proname;

-- 0.1 Muammoning o'zini ko'rish: parent 0, bolalarida pul
select k.code, k.name,
       pul_qoldiq(current_date, k.id) as eski_pul_qoldiq,
       c.jami                         as haqiqiy_jami
  from accounts k
  join v_kassa_card c on c.id = k.id
 where k.section = 'pul' and k.is_active and k.parent_id is null
 order by c.jami desc nulls last
 limit 15;


-- ---------------------------------------------------------------------
-- 1. kassa_oila — kassa + hamma tur/valyuta bolasi
-- ---------------------------------------------------------------------
-- ⚠️ Bola-hisobni aniqlashda parent_id ga YOLG'IZ tayanilmaydi: hodim
--    kassasining parenti 5400 (konteyner guruh), lekin u bola-hisob EMAS —
--    o'zi mustaqil kassa. Ajratuvchi shart ikkita:
--       currency <> 'UZS'      -> valyuta bolasi (56xx USD, 57xx CNY…)
--       pul_turi is not null   -> pul turi bolasi (naqd/click/payme)
--    (Ayni qoida perm_op_key() va perms.js keyOf() da ham ishlatiladi.)
--
-- p_kassa bola-hisobning o'zi bo'lib qolsa ham to'g'ri ishlaydi: avval
-- ildiz topiladi, keyin butun oila qaytariladi.
create or replace function kassa_oila(p_kassa uuid)
returns uuid[]
language sql
stable
security invoker
set search_path = public
as $$
  with ildiz as (
    select case
             when a.parent_id is not null
                  and (coalesce(a.currency,'UZS') <> 'UZS' or a.pul_turi is not null)
               then a.parent_id
             else a.id
           end as id
      from accounts a
     where a.id = p_kassa
  )
  select array_agg(x.id)
    from (
      select i.id from ildiz i
      union
      select c.id
        from accounts c, ildiz i
       where c.parent_id = i.id
         and c.is_active
         and (coalesce(c.currency,'UZS') <> 'UZS' or c.pul_turi is not null)
    ) x;
$$;

revoke all on function kassa_oila(uuid) from public, anon;
grant execute on function kassa_oila(uuid) to authenticated, service_role;

comment on function kassa_oila(uuid) is
  'Kassa + uning tur (naqd/click/payme) va valyuta bola-hisoblari. '
  'Hodim kassasi (parent = 5400 konteyner) — yolg''iz o''zi qaytadi.';


-- ---------------------------------------------------------------------
-- 2. pul_qoldiq_kassa — oila bo'yicha qoldiq
-- ---------------------------------------------------------------------
-- p_kassa null -> eski pul_qoldiq(p_date, null) (hamma kassalar) delegat.
-- Aks holda oila a'zolarining entry_line yig'indisi — v_kassa_card.jami
-- bilan AYNI mantiq (posted + o'chirilmagan, so'mda).
create or replace function pul_qoldiq_kassa(p_date date, p_kassa uuid default null)
returns numeric
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_ids uuid[];
  v_sum numeric;
begin
  if p_kassa is null then
    return pul_qoldiq(p_date, null);
  end if;

  v_ids := kassa_oila(p_kassa);
  if v_ids is null then
    return 0;
  end if;

  select coalesce(sum(l.debit - l.credit), 0)
    into v_sum
    from entry_line l
    join entry e on e.id = l.entry_id
   where l.account_id = any(v_ids)
     and e.status = 'posted'
     and e.is_deleted = false
     and e.entry_date <= p_date;

  return coalesce(v_sum, 0);
end $$;

revoke all on function pul_qoldiq_kassa(date, uuid) from public, anon;
grant execute on function pul_qoldiq_kassa(date, uuid) to authenticated;

comment on function pul_qoldiq_kassa(date, uuid) is
  'Kassaning sanaga qoldig''i — kassa + tur/valyuta bolalari birga. '
  'p_kassa null bo''lsa pul_qoldiq(p_date, null) ga delegat.';


-- ---------------------------------------------------------------------
-- 3. cashflow_kassa — oila bo'yicha pul oqimi
-- ---------------------------------------------------------------------
-- Eski cashflow() ustida: har a'zo uchun chaqiriladi, natijalar yig'iladi,
-- OILA ICHIDAGI harakat (qarshi tomon ham shu oiladan) olib tashlanadi.
create or replace function cashflow_kassa(p_from date, p_to date,
                                          p_kassa uuid default null)
returns table(yonalish text, section text, code text, name text, amount numeric)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_ids   uuid[];
  v_kodlar text[];
begin
  if p_kassa is null then
    return query select c.yonalish, c.section, c.code, c.name, c.amount
                   from cashflow(p_from, p_to, null) c;
    return;
  end if;

  v_ids := kassa_oila(p_kassa);
  if v_ids is null then
    return;
  end if;

  -- Oila a'zolarining kodlari — ichki harakatni tanib olish uchun.
  -- cashflow() QARSHI tomonning kodini qaytaradi, shuning uchun ichki
  -- ko'chirish (masalan tur_convert: naqd -> click) satrining code'i
  -- shu ro'yxatda bo'ladi.
  select array_agg(a.code) into v_kodlar from accounts a where a.id = any(v_ids);

  return query
    select t.yonalish, t.section, t.code, t.name, sum(t.amount)::numeric
      from unnest(v_ids) as u(acc)
      cross join lateral cashflow(p_from, p_to, u.acc) as t
     where t.code is null or not (t.code = any(v_kodlar))
     group by t.yonalish, t.section, t.code, t.name
    having sum(t.amount) <> 0;
end $$;

revoke all on function cashflow_kassa(date, date, uuid) from public, anon;
grant execute on function cashflow_kassa(date, date, uuid) to authenticated;

comment on function cashflow_kassa(date, date, uuid) is
  'Kassa bo''yicha pul oqimi — kassa + tur/valyuta bolalari birga, oila '
  'ichidagi ko''chirish (tur o''tkazish) chiqarib tashlanadi. '
  'p_kassa null bo''lsa cashflow(p_from, p_to, null) ga delegat.';


-- ---------------------------------------------------------------------
-- 4. TEKSHIRUV
-- ---------------------------------------------------------------------

-- 4.1 ⭐ Qoldiq endi kartadagi jami bilan mos keladimi.
--     `farq` ustuni HAMMA qatorda 0 bo'lishi SHART.
--     (Yagona istisno: entry_date KELAJAK sanasi bo'lgan yozuv bo'lsa —
--      v_kassa_card.jami sanaga qaramaydi, pul_qoldiq_kassa esa qaraydi.)
select k.code, k.name,
       pul_qoldiq(current_date, k.id)       as eski,
       pul_qoldiq_kassa(current_date, k.id) as yangi,
       c.jami,
       round(pul_qoldiq_kassa(current_date, k.id) - c.jami) as farq
  from accounts k
  join v_kassa_card c on c.id = k.id
 where k.section = 'pul' and k.is_active and k.parent_id is null
   and coalesce(k.kassa_turi,'') <> 'xarajat_guruh'
 order by c.jami desc nulls last;

-- 4.2 Oila to'g'ri yig'ilganmi (bitta kassa misolida)
select a.code, a.name, a.pul_turi, a.currency
  from unnest(kassa_oila((select id from accounts where code = '5011'))) u(id)
  join accounts a on a.id = u.id
 order by a.code;

-- 4.3 ⭐ Cashflow tekshiruvi — sahifadagi "farq = 0" qatori shu:
--     davr oxiri − davr boshi = kirim − chiqim
with d as (select (date_trunc('month', current_date))::date as d1, current_date as d2),
     k as (select id from accounts where code = '5011'),
     f as (select coalesce(sum(case when yonalish = 'KIRIM'  then amount else 0 end), 0) as kirim,
                  coalesce(sum(case when yonalish = 'CHIQIM' then amount else 0 end), 0) as chiqim
             from d, k, cashflow_kassa(d.d1, d.d2, k.id))
select f.kirim, f.chiqim,
       pul_qoldiq_kassa((select d1 from d) - 1, (select id from k)) as boshi,
       pul_qoldiq_kassa((select d2 from d),     (select id from k)) as oxiri,
       round( (pul_qoldiq_kassa((select d2 from d), (select id from k))
             - pul_qoldiq_kassa((select d1 from d) - 1, (select id from k)))
             - (f.kirim - f.chiqim) ) as farq
  from f;
-- farq = 0 bo'lishi SHART. Boshqa kassalar uchun '5011' ni almashtiring.

-- 4.4 "Hamma kassalar" holati o'zgarmaganini tasdiqlash (delegat ishlayaptimi)
select (select count(*) from cashflow(current_date - 30, current_date, null))        as eski_qator,
       (select count(*) from cashflow_kassa(current_date - 30, current_date, null))  as yangi_qator;
-- Ikkovi TENG bo'lishi kerak.
