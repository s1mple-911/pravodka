-- =====================================================================
--  PROVODKA_NOTIFY_IKKI_BARAVAR_FIX.sql
--  Telegram xabaridagi summa IKKI BARAVAR chiqishi — tuzatish
--  2026-09-12
-- =====================================================================
--
--  ## MUAMMO (jonli misol, Asilbek)
--
--    🔴 📤 Chiqim · Obidjon Murtazayev
--    💰 −260 000 so'm      <-- bot
--    📝 Ruxsat bilan: цемент кум блок
--
--  Jurnalda esa −130 000 (ruxsat berilgan haqiqiy summa). Ya'ni bot
--  AYNAN IKKI BARAVAR ko'rsatdi.
--
--  ## SABAB
--
--  `_hodim_notify_qoy()` bir xil (entry_id, kassa_id) bo'yicha hali
--  YUBORILMAGAN navbat qatoriga delta ni QO'SHADI (PROVODKA_HODIM_NOTIFY.sql
--  ~281: `v_delta := v_old.delta + p_delta`). Bu ATAYLAB shunday — bitta
--  yozuvda bir nechta satr bo'lsa (Naqd -> Click ko'chirish) ular bitta
--  xabarga birlashishi kerak.
--
--  Lekin navbatga IKKI XIL yo'l bilan, IKKI MARTA qo'yiladi:
--
--    1) TRIGGERLAR (avtomatik):
--       - `trg_hodim_notify_entry_line` — entry_line INSERT/UPDATE da
--         (PROVODKA_HODIM_NOTIFY.sql ~407)
--       - `trg_hodim_notify_status` — entry.status -> 'posted' bo'lganda
--         (PROVODKA_NOTIFY_TOLIQ.sql ~87)
--
--    2) QO'LDA: `perform sorov_notify_post(v_entry)` — 5 joyda:
--       PROVODKA_JADVAL_2.sql:514, PROVODKA_RUXSAT_SOROV.sql:651,
--       PROVODKA_RUXSAT_TALAB.sql:696, PROVODKA_SOROV_KASSA.sql:425,
--       PROVODKA_SOROVLAR.sql:1896
--
--  Ikkala yo'l ham ishlaydi:
--
--    Ruxsat yo'li (RUXSAT_TALAB):
--      entry 'posted' bo'lib yaratiladi -> entry_line insert ->
--      trg_hodim_notify_entry_line ishlaydi (delta -130 000) ->
--      sorov_notify_post CHAQIRILADI -> o'sha qatorga yana -130 000
--      QO'SHILADI -> -260 000  ❌
--
--    Pul so'rash yo'li (SOROV_KASSA):
--      entry 'pending' -> satrlar yoziladi (trigger jim, status posted emas)
--      -> `update entry set status='posted'` -> trg_hodim_notify_status
--      ishlaydi (delta -130 000) -> sorov_notify_post CHAQIRILADI ->
--      yana -130 000 QO'SHILADI -> -260 000  ❌
--
--  Ya'ni `sorov_notify_post()` HAR IKKALA yo'lda ham ORTIQCHA.
--  U yozilganda (PROVODKA_SOROVLAR.sql 7-BO'LIM) `trg_hodim_notify_status`
--  hali yo'q edi; keyin trigger qo'shilgan, lekin qo'lda chaqiruv
--  olib tashlanmagan.
--
--  ## YECHIM
--
--  `sorov_notify_post()` ni IDEMPOTENT qilamiz: bu yozuv uchun navbatda
--  allaqachon qator bo'lsa — hech narsa qilmaydi.
--
--  Nega 5 ta RPC dan chaqiruvni olib tashlamadik: ular katta, pul yo'lidagi
--  funksiyalar. Bitta kichik funksiyaga qo'yilgan qo'riqchi xavfsizroq va
--  kelajakdagi yangi chaqiruvchilarni ham himoya qiladi. `sorov_notify_post`
--  zaxira sifatida qoladi — agar biror sababdan ikkala trigger ham
--  ishlamasa, xabar baribir ketadi.
--
--  🔴 ADDITIVE: hech narsa o'chirilmaydi, imzo o'zgarmaydi.
-- =====================================================================


-- #####################################################################
-- ##  1-BO'LIM — sorov_notify_post() idempotent bo'ladi               ##
-- #####################################################################

create or replace function sorov_notify_post(p_entry uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r    record;
  v_rt uuid;
begin
  if to_regclass('public.hodim_notify') is null then return; end if;
  if coalesce(current_setting('provodka.notify_off', true), '') = '1' then return; end if;

  -- 🔴 IKKI BARAVAR QO'RIQCHISI (2026-09-12)
  --    Bu yozuv uchun navbatda qator BOR bo'lsa, uni triggerlardan biri
  --    allaqachon qo'ygan. Qayta chaqirsak `_hodim_notify_qoy` deltani
  --    QO'SHIB yuboradi va summa ikki baravar bo'lib ketadi.
  --    `sent_at` ga qaramaymiz: yuborilgan bo'lsa ham qayta xabar kerak emas.
  if exists (select 1 from hodim_notify where entry_id = p_entry) then
    return;
  end if;

  for r in select l.id, l.account_id,
                  coalesce(l.debit, 0) - coalesce(l.credit, 0) as d,
                  case when coalesce(l.debit, 0) > 0
                       then coalesce(l.fc_amount, 0)
                       else -coalesce(l.fc_amount, 0) end       as fc,
                  coalesce(l.debit, 0) > 0                      as dt
             from entry_line l
            where l.entry_id = p_entry
  loop
    v_rt := hodim_kassa_root(r.account_id);
    if v_rt is not null then
      perform _hodim_notify_qoy(p_entry, r.id::text, v_rt, r.account_id,
                                r.d, r.fc, r.dt, null);
    end if;
  end loop;

exception when others then
  raise warning 'sorov_notify_post(%): %', p_entry, sqlerrm;
end $fn$;

revoke all on function sorov_notify_post(uuid) from public, anon, authenticated;

comment on function sorov_notify_post(uuid) is
  'ICHKI, IDEMPOTENT: pending -> posted qilingan yozuv uchun hodim_notify navbatiga qator '
  'qoyadi. Navbatda shu entry uchun qator BOR bolsa jim qaytadi — triggerlar '
  '(trg_hodim_notify_entry_line / trg_hodim_notify_status) allaqachon qoygan, '
  'takror chaqiruv summani ikki baravar qilardi (2026-09-12). FAIL-OPEN.';


-- #####################################################################
-- ##  2-BO'LIM — HOZIR NAVBATDA TURGAN XATO QATORLAR                  ##
-- #####################################################################
--
-- Tuzatishdan OLDIN navbatga tushgan, hali yuborilmagan qatorlarda summa
-- ikki baravar bo'lishi mumkin. Quyidagi so'rov ularni ko'rsatadi:
-- navbatdagi `delta` yozuvning haqiqiy hodim-kassa satrlari yig'indisidan
-- farq qilsa — shubhali.

select n.id                          as navbat_id,
       n.entry_id,
       e.description,
       n.delta                       as navbatdagi,
       x.haqiqiy,
       round(n.delta / nullif(x.haqiqiy, 0), 2) as nisbat,
       n.created_at
  from hodim_notify n
  join entry e on e.id = n.entry_id
  join lateral (
        select sum(coalesce(l.debit, 0) - coalesce(l.credit, 0)) as haqiqiy
          from entry_line l
         where l.entry_id = n.entry_id
           and hodim_kassa_root(l.account_id) = n.kassa_id
       ) x on true
 where n.sent_at is null
   and x.haqiqiy is not null
   and n.delta is distinct from x.haqiqiy
 order by n.created_at desc;


-- ---------------------------------------------------------------------
-- Yuqoridagi ro'yxat bo'sh bo'lmasa — shu blok bilan TUZATING.
-- Ehtiyot uchun izohda: avval yuqoridagi select ni ko'ring, keyin
-- quyidagi ikki qatordan izohni oling va RUN qiling.
-- ---------------------------------------------------------------------

-- update hodim_notify n
--    set delta        = x.haqiqiy,
--        qoldiq_oldin = n.qoldiq_keyin - x.haqiqiy
--   from (select n2.id,
--                (select sum(coalesce(l.debit,0) - coalesce(l.credit,0))
--                   from entry_line l
--                  where l.entry_id = n2.entry_id
--                    and hodim_kassa_root(l.account_id) = n2.kassa_id) as haqiqiy
--           from hodim_notify n2
--          where n2.sent_at is null) x
--  where n.id = x.id
--    and x.haqiqiy is not null
--    and n.delta is distinct from x.haqiqiy;


-- #####################################################################
-- ##  3-BO'LIM — TEKSHIRUV                                            ##
-- #####################################################################

-- 3.1 Qo'riqchi o'rnatildimi
select 'sorov_notify_post' as funksiya,
       case when pg_get_functiondef('public.sorov_notify_post(uuid)'::regprocedure)
                 ilike '%IKKI BARAVAR QO%' then '✅ qo''riqchi bor'
            else '❌ eski versiya' end as holat;

-- 3.2 Navbatda farqli qator qoldimi (bo'sh bo'lishi kerak)
select count(*) as farqli_qatorlar
  from hodim_notify n
  join lateral (
        select sum(coalesce(l.debit, 0) - coalesce(l.credit, 0)) as haqiqiy
          from entry_line l
         where l.entry_id = n.entry_id
           and hodim_kassa_root(l.account_id) = n.kassa_id
       ) x on true
 where n.sent_at is null
   and x.haqiqiy is not null
   and n.delta is distinct from x.haqiqiy;
