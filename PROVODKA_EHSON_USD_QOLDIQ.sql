-- =====================================================================================================================
--  PROVODKA_EHSON_USD_QOLDIQ.sql  (2026-10-28, Asilbek; faqat DEV, ADDITIVE, idempotent — Asilbek RUN qiladi)
--
--  MUAMMO: USD pul turining SO'M «qoldiq»i kirim paytidagi turli kurslarda yig'iladi, dollar qoldig'i esa aniq.
--  Jonli ma'lumot: Zakot / dollar: +5 000 $ (11 900), +7 000 $ (11 850), tuzatish −12 000 $ (11 950) -> dollar 0 $,
--  lekin so'mda −950 000 -> Zakot jami −474 000 ko'rinardi (naqd 476 000 to'g'ri). Ehson soliq dollar: 0 $ / −1 532 200 so'm.
--
--  YECHIM: v_ehson_kassa_pul da valyutasi USD bo'lgan qatorning so'm `qoldiq`i = `fc_qoldiq` × JORIY kurs
--  (fc 0 -> so'm 0). UZS pul turlari avvalgidek. v_ehson_kassa.qoldiq (kassa jami) = shu qatorlar yig'indisi.
--  Kurs yo'q (null) bo'lsa — ESKI xatti-harakat (so'm yig'indisi), `kurs_yoq = true` (yangi OXIRGI ustun).
--
--  Ustun nomlari/tartibi O'ZGARMAGAN (faqat v_ehson_kassa_pul OXIRIGA `kurs_yoq` qo'shildi) -> view'ni o'qiydigan hammasi
--  (ehson_dash, ehson_ber, ehson_kassa_daraxt, ehson_qarz_ber, ehson_transfer_yoz, ehson_konvert_yoz, ehson_kirim_qolda,
--  ehson_kassa_saqla) avtomat to'g'rilanadi. USD tekshiruvlari (`qoldiq_yetmaydi`/`qoldiq_yetmadi`) AVVAL HAM fc_qoldiq bilan
--  ishlaydi — tegilmadi. ehson_dash ning stat'lari (bu oy / yil) ehson_berish dan, kirim yig'indisidan emas — tegilmadi.
--
--  Kurs manbai: ichki `_ehson_kurs_usd_ich()` — `ehson_kurs_usd()` bilan BIR XIL manba (conv_baza_kurs('USD')), lekin
--  auth/ruxsat tekshiruvisiz: view SQL editor'dan, service_role'dan va ehson_kirim bayrog'i bor (ehson sahifasi yo'q) userdan
--  ham BIR XIL qoldiq berishi kerak. `ehson_kurs_usd()` (UI sukut kursi) o'zgarmadi.
--
--  View tanalari PROVODKA_EHSON_KONVERT_QARZ_GURUH.sql (ENG OXIRGI versiya) dan verbatim, faqat qoldiq ifodalari o'zgargan.
--  🔴 v_ehson_kassa_pul / v_ehson_kassa ning ENG OXIRGI versiyasi endi SHU faylda. KONVERT_QARZ_GURUH / TRANSFER / QARZ /
--  ZAKOT fayllari qayta RUN qilinsa — shu faylni ham qayta RUN qiling (ular view'ni eski ko'rinishga qaytaradi).
-- =====================================================================================================================

-- ######## 0) OLD SHART ########
do $ehu_old$
begin
  if to_regclass('public.ehson_transfer') is null or to_regclass('public.v_ehson_kassa_pul') is null
     or to_regclass('public.v_ehson_kassa') is null then
    raise exception 'Old shart: avval PROVODKA_EHSON_KONVERT_QARZ_GURUH.sql (v_ehson_kassa_pul / v_ehson_kassa)';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'ehson_transfer' and column_name = 'to_fc_summa') then
    raise exception 'Old shart: ehson_transfer.to_fc_summa yoq — avval PROVODKA_EHSON_KONVERT_QARZ_GURUH.sql';
  end if;
end
$ehu_old$;

-- ######## 1) ICHKI KURS ########
create or replace function _ehson_kurs_usd_ich()
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v numeric;
begin
  if exists (select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
              where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs' and oidvectortypes(pr.proargtypes) = 'text') then
    execute 'select conv_baza_kurs($1)' into v using 'USD';
  end if;
  if v is null or v <= 0 then return null; end if;
  return v;
end
$fn$;
revoke all on function _ehson_kurs_usd_ich() from public, anon;
grant execute on function _ehson_kurs_usd_ich() to authenticated;
comment on function _ehson_kurs_usd_ich() is
  'Ichki: USD joriy kursi (conv_baza_kurs, ehson_kurs_usd() manbasi) — auth tekshiruvisiz, v_ehson_kassa_pul uchun. null = kurs yoq.';

-- ######## 2) v_ehson_kassa_pul — USD qatorda so'm qoldiq = fc_qoldiq × joriy kurs ########
create or replace view v_ehson_kassa_pul as
select
  x.kassa_id,
  x.pul_turi,
  x.valyuta,
  sum(x.kirim)                                                              as kirim,
  sum(x.berildi)                                                            as berildi,
  case when x.valyuta = 'USD' and kk.kurs is not null
       then round((sum(x.fc_kirim) - sum(x.fc_berildi) - sum(x.fc_qarz_berildi) + sum(x.fc_qarz_qaytdi)
                   - sum(x.fc_tr_chiqdi) + sum(x.fc_tr_kirdi)) * kk.kurs, 2)
       else sum(x.kirim) - sum(x.berildi) - sum(x.qarz_berildi) + sum(x.qarz_qaytdi)
              - sum(x.tr_chiqdi) + sum(x.tr_kirdi)
  end                                                                       as qoldiq,
  sum(x.fc_kirim)                                                           as fc_kirim,
  sum(x.fc_berildi)                                                         as fc_berildi,
  sum(x.fc_kirim) - sum(x.fc_berildi) - sum(x.fc_qarz_berildi) + sum(x.fc_qarz_qaytdi)
    - sum(x.fc_tr_chiqdi) + sum(x.fc_tr_kirdi)                              as fc_qoldiq,
  sum(x.qarz_berildi)                                                       as qarz_berildi,
  sum(x.qarz_qaytdi)                                                        as qarz_qaytdi,
  sum(x.fc_qarz_berildi)                                                    as fc_qarz_berildi,
  sum(x.fc_qarz_qaytdi)                                                     as fc_qarz_qaytdi,
  sum(x.tr_chiqdi)                                                          as tr_chiqdi,
  sum(x.tr_kirdi)                                                           as tr_kirdi,
  sum(x.fc_tr_chiqdi)                                                       as fc_tr_chiqdi,
  sum(x.fc_tr_kirdi)                                                        as fc_tr_kirdi,
  (x.valyuta = 'USD' and kk.kurs is null)                                   as kurs_yoq
from (
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS') as valyuta,
         summa as kirim, 0::numeric as berildi, 0::numeric as qarz_berildi, 0::numeric as qarz_qaytdi,
         coalesce(fc_summa, 0) as fc_kirim, 0::numeric as fc_berildi, 0::numeric as fc_qarz_berildi, 0::numeric as fc_qarz_qaytdi,
         0::numeric as tr_chiqdi, 0::numeric as tr_kirdi, 0::numeric as fc_tr_chiqdi, 0::numeric as fc_tr_kirdi
    from ehson_kirim where is_deleted = false
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, summa, 0, 0,
         0, coalesce(fc_summa, 0), 0, 0,
         0, 0, 0, 0
    from ehson_berish where holat = 'berildi'
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, summa, 0,
         0, 0, coalesce(fc_summa, 0), 0,
         0, 0, 0, 0
    from ehson_qarz where holat in ('faol', 'yopildi')
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, 0, summa,
         0, 0, 0, coalesce(fc_summa, 0),
         0, 0, 0, 0
    from ehson_qarz_tolov where is_deleted = false
  union all
  -- o'tkazma / konvert: chiqqan kassa (avvalgidek)
  select from_kassa_id, from_pul_turi, coalesce(valyuta, 'UZS'),
         0, 0, 0, 0,
         0, 0, 0, 0,
         summa, 0, coalesce(fc_summa, 0), 0
    from ehson_transfer where is_deleted = false
  union all
  -- o'tkazma / konvert: kirgan kassa — konvertda boshqa valyuta (to_valyuta) va to_summa/to_fc_summa
  select to_kassa_id, to_pul_turi, coalesce(to_valyuta, valyuta, 'UZS'),
         0, 0, 0, 0,
         0, 0, 0, 0,
         0, coalesce(to_summa, summa), 0,
         case when coalesce(to_valyuta, valyuta, 'UZS') = 'USD' then coalesce(to_fc_summa, fc_summa, 0) else 0 end
    from ehson_transfer where is_deleted = false
) x
cross join (select _ehson_kurs_usd_ich() as kurs) kk
group by x.kassa_id, x.pul_turi, x.valyuta, kk.kurs;
alter view v_ehson_kassa_pul set (security_invoker = on);
revoke all on v_ehson_kassa_pul from public, anon;
grant select on v_ehson_kassa_pul to authenticated;
comment on view v_ehson_kassa_pul is
  'Har jamg''arma + pul turi kesimida kirim/berildi/qoldiq (so''m) va fc_* (dollar). UZS: qoldiq = kirim − berildi − qarz_berildi + '
  'qarz_qaytdi − tr_chiqdi + tr_kirdi. USD qatorda qoldiq = fc_qoldiq × JORIY kurs (_ehson_kurs_usd_ich; kurs yoq bo''lsa so''m '
  'yig''indisi va kurs_yoq = true) — eski kurslar aralashmasi so''mda «qoldiq» qoldirmasin (2026-10-28).';

-- ######## 3) v_ehson_kassa — qoldiq = pul turi qatorlari qoldig'i yig'indisi (qolgan ustunlar o'zgarmagan) ########
create or replace view v_ehson_kassa as
select k.id, k.nom, k.is_active,
  coalesce(ki.summa, 0) as kirim,
  coalesce(be.summa, 0) as berildi,
  coalesce(vq.qoldiq, 0) as qoldiq,
  coalesce(qb.summa, 0) as qarz_berildi,
  coalesce(qq.summa, 0) as qarz_qaytdi,
  coalesce(tc.summa, 0) as tr_chiqdi,
  coalesce(tk.summa, 0) as tr_kirdi
from ehson_kassa k
left join lateral (select sum(summa) as summa from ehson_kirim       where kassa_id = k.id and is_deleted = false) ki on true
left join lateral (select sum(summa) as summa from ehson_berish      where kassa_id = k.id and holat = 'berildi') be on true
left join lateral (select sum(summa) as summa from ehson_qarz        where kassa_id = k.id and holat in ('faol','yopildi')) qb on true
left join lateral (select sum(summa) as summa from ehson_qarz_tolov  where kassa_id = k.id and is_deleted = false) qq on true
left join lateral (select sum(summa) as summa from ehson_transfer    where from_kassa_id = k.id and is_deleted = false) tc on true
left join lateral (select sum(coalesce(to_summa, summa)) as summa from ehson_transfer where to_kassa_id = k.id and is_deleted = false) tk on true
left join lateral (select sum(qoldiq) as qoldiq from v_ehson_kassa_pul where kassa_id = k.id) vq on true;
alter view v_ehson_kassa set (security_invoker = on);
revoke all on v_ehson_kassa from public, anon;
grant select on v_ehson_kassa to authenticated;
comment on view v_ehson_kassa is
  'Jamg''arma jami: qoldiq = v_ehson_kassa_pul.qoldiq yig''indisi (USD pul turlari fc_qoldiq × joriy kurs). kirim/berildi/... — xom so''m yig''indilar.';

-- ######## 4) TEKSHIRUV (faqat o'qish) ########
--  Kutiladi: Zakot jami_qoldiq = 476000 (kurs mavjud bo'lsa), Ehson soliq dollar qoldiq = 0 va fc_qoldiq = 0.
select k.nom as kassa, 'jami' as qator, vk.qoldiq, null::numeric as fc_qoldiq, null::boolean as kurs_yoq
  from ehson_kassa k join v_ehson_kassa vk on vk.id = k.id
 where lower(k.nom) in ('zakot', 'ehson soliq', 'ehson asosiy') and k.parent_id is not null
union all
select k.nom, 'pul turi: ' || vp.pul_turi, vp.qoldiq, vp.fc_qoldiq, vp.kurs_yoq
  from ehson_kassa k join v_ehson_kassa_pul vp on vp.kassa_id = k.id
 where lower(k.nom) in ('zakot', 'ehson soliq', 'ehson asosiy') and k.parent_id is not null
   and vp.valyuta = 'USD'
 order by 1, 2;
