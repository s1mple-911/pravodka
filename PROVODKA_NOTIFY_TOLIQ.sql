-- =====================================================================
-- PROVODKA_NOTIFY_TOLIQ.sql — hodim kassasidagi HAR amal xabar bo'lsin
-- ---------------------------------------------------------------------
-- QAROR (Asilbek, 2026-08-26): "aynan chiqim deb olmaylik — hodim
-- kassasiga QANAQA amal bo'lsa ham yozadigan qilaylik".
--
-- HOZIRGI QAMROV (tekshirildi — bular ALLAQACHON ishlaydi, tegilmaydi):
--   kirim · chiqim · transfer (kirim/chiqim) — `trg_hodim_notify_entry_line`
--       (after insert on entry_line). Chiqimda `delta` manfiy, `_hodim_notify_qoy`
--       faqat `delta = 0` ni tashlaydi — ya'ni chiqim ham qamrab olingan.
--   tahrir  — o'sha trigger (after update of account_id/debit/credit/fc_amount)
--   o'chirish — `trg_hodim_notify_entry` (after update of is_deleted)
--
-- 🔴 TOPILGAN YAGONA TESHIK — "Pul so'rash" tasdiqlanganda XABAR YO'Q.
--   `sorov_yarat` xarajatni `status='pending'` qilib yozadi. O'sha payt
--   `_hodim_notify_qoy` ataylab chiqib ketadi (`status <> 'posted'` -> return),
--   chunki pul hali harakat qilmagan — TO'G'RI.
--   Keyin `sorov_tasdiq` `update entry set status='posted'` qiladi va PUL
--   HAQIQATDA CHIQADI, lekin `entry_line` O'ZGARMAGANI uchun birorta trigger
--   qayta ishlamaydi -> hodim hech qanday xabar OLMAYDI.
--   (Bu PROVODKA_SOROVLAR.sql 1386-1400 da hujjatlangan muammoning notify qismi;
--    o'sha yerda limit qismi `sorov_post_tosiq()` bilan yopilgan, notify qismi YO'Q.)
--
-- BU FAYL IKKI ISH QILADI:
--   1-BO'LIM  yangi trigger: `status` -> 'posted' bo'lganda xabar qo'yiladi
--   2-BO'LIM  `hodim_notify_pending()` javobiga `vaqt` va `hodisa_sana` qo'shiladi
--             (Telegram xabarida "25.08.2026 14:30" ko'rinishi uchun)
--
-- ⚠️ ADDITIVE: hech narsa o'chirilmaydi, birorta imzo o'zgarmaydi.
--    `hodim_notify_pending(int)` tanasi almashadi — faqat 2 ta ustun QO'SHILADI.
-- ⚠️ Old shart: PROVODKA_NOTIFY_FIX.sql (42702 tuzatishi) RUN qilingan bo'lsin.
-- ⚠️ Funksiya tanalari NOMLANGAN teg bilan; izohlarda dollar-qavs YO'Q.
-- =====================================================================


-- #####################################################################
-- ##  1-BO'LIM — pending -> posted bo'lganda xabar                    ##
-- #####################################################################

-- `hodim_notify_entry_fn()` (soft-delete) naqshining aynan o'zi, faqat
-- hodisa boshqa: bu yerda pul HAQIQATDA harakat qiladi, shuning uchun
-- `p_hodisa` = null (oddiy kirim/chiqim deb ko'rsatiladi, "tahrir" emas).
--
-- 🔴 TAKROR XAVFI YO'Q: satrlar PENDING holatda yozilganda
--    `_hodim_notify_qoy` chiqib ketgan edi, ya'ni navbatda qator YO'Q.
--    Bu trigger o'sha yagona xabarni qo'yadi.
-- 🔴 `exception when others` — ATAYLAB: bu trigger PUL YO'LIDA turadi.
--    Xabar metama'lumot; u tufayli tasdiqlash yiqilishi mumkin emas
--    (mavjud notify triggerlaridagi bir xil qaror).
create or replace function hodim_notify_status_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare v_r record;
begin
  -- Ommaviy tuzatish/migratsiya skripti uchun o'chirgich (mavjud naqsh)
  if coalesce(current_setting('provodka.notify_off', true), '') = '1' then
    return null;
  end if;

  for v_r in
    select l.id::text as lid,
           l.account_id,
           coalesce(l.debit, 0) - coalesce(l.credit, 0) as d,
           case when coalesce(l.debit, 0) > 0
                then coalesce(l.fc_amount, 0) else -coalesce(l.fc_amount, 0) end as fc,
           coalesce(l.debit, 0) > 0 as dt,
           hodim_kassa_root(l.account_id) as root
      from entry_line l
     where l.entry_id = new.id
  loop
    if v_r.root is not null and v_r.d <> 0 then
      perform _hodim_notify_qoy(new.id, v_r.lid, v_r.root, v_r.account_id,
                                v_r.d, v_r.fc, v_r.dt, null);
    end if;
  end loop;
  return null;

exception when others then
  raise warning 'hodim_notify (status): %', sqlerrm;
  return null;
end $fn$;

drop trigger if exists trg_hodim_notify_status on entry;
create trigger trg_hodim_notify_status
  after update of status on entry
  for each row
  when (old.status is distinct from 'posted' and new.status = 'posted')
  execute function hodim_notify_status_fn();

comment on function hodim_notify_status_fn() is
  'entry.status -> posted bolganda hodim kassasiga xabar qoyadi. Pul sorash (sorov_tasdiq) '
  'yoli: satrlar pending yozilgani uchun entry_line triggeri ishlamagan edi.';


-- #####################################################################
-- ##  2-BO'LIM — javobga `vaqt` va `hodisa_sana` qo'shiladi           ##
-- #####################################################################

-- 🔴 Tana PROVODKA_NOTIFY_FIX.sql dagining AYNAN o'zi (v_r tuzatishi bilan),
--    faqat ikkita ustun qo'shildi. Boshqa birorta qator o'zgarmadi.
create or replace function hodim_notify_pending(p_limit int default 50)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_ids   bigint[] := '{}';
  v_items jsonb;
  v_admin jsonb;
  v_r     record;   -- 🔴 `r` EMAS: pastda `join accounts r` taxallusi bor,
                    --    ikkalasi ziddiyatga tushib 42702 berardi
begin
  -- (a) TOZALASH: 30 soniya ichida o'chirilgan/bekor qilingan yozuvlarning
  --     qatorlari hech qachon tanlanmaydi va navbatda abadiy osilib qolardi.
  update hodim_notify n
     set sent_at = now(),
         last_error = 'yozuv o''chirilgan yoki posted emas'
    from entry e
   where e.id = n.entry_id
     and n.sent_at is null
     and coalesce(n.hodisa, '') <> 'ochirildi'
     and (e.is_deleted or e.status is distinct from 'posted');

  -- (b) Navbatdan olish
  for v_r in
    select n.id
      from hodim_notify n
      join entry e on e.id = n.entry_id
     where n.sent_at is null
       and n.attempts < 30
       and n.created_at < now() - interval '30 seconds'
       and e.status = 'posted'
       and (e.is_deleted = false or n.hodisa = 'ochirildi')
     order by n.id
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update of n skip locked
  loop
    v_ids := array_append(v_ids, v_r.id);
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
           'telegram_id', telegram_id, 'ism', coalesce(ism, '')
         )), '[]'::jsonb)
    into v_admin
    from hodim_notify_admin
   where is_active;

  if array_length(v_ids, 1) is null then
    return jsonb_build_object('items', '[]'::jsonb, 'adminlar', v_admin);
  end if;

  update hodim_notify set attempts = attempts + 1 where id = any(v_ids);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb) into v_items
  from (
    select
      n.id,
      n.entry_id,
      n.kassa_id,
      -- Tur: maxsus hodisa bo'lmasa qarshi tomondan aniqlanadi.
      -- 🔴 `section='pul'` bo'yicha — kod prefiksi (5xxx) bilan EMAS
      --    (jurnal-dev.html klass() bilan bir xil qoida).
      coalesce(n.hodisa,
        case when n.delta > 0
             then case when coalesce(q.qarshi_pul, false) then 'transfer_kirim' else 'kirim' end
             else case when coalesce(q.qarshi_pul, false) then 'transfer_chiqim' else 'chiqim' end
        end)                                  as hodisa,
      (n.delta > 0)                           as kirimmi,
      abs(n.delta)::numeric                   as summa,
      abs(coalesce(n.fc, 0))::numeric         as fc_summa,
      n.qoldiq_oldin,
      n.qoldiq_keyin,
      r.code                                  as kassa_kod,
      r.name                                  as kassa_nom,
      -- to_jsonb(...)->> : ustun yo'q bo'lsa ham so'rov yiqilmaydi
      to_jsonb(r) ->> 'subtitle'              as subtitle,
      to_jsonb(r) ->> 'taskfix_user_id'       as taskfix_user_id,
      to_jsonb(a) ->> 'pul_turi'              as pul_turi,
      coalesce(a.currency, 'UZS')             as valyuta,
      q.qarshi_kod,
      q.qarshi_nom,
      e.entry_date::text                      as sana,
      -- 🔴 YANGI (2026-08-26): hodisa VAQTI. `n.created_at` — bu qator navbatga
      --    tushgan payt, ya'ni amal HAQIQATDA sodir bo'lgan lahza (tahrir/tasdiq
      --    uchun ham to'g'ri). `sana` esa BUXGALTERIYA sanasi (qo'lda tanlanadi)
      --    va hodisa sanasidan farq qilishi mumkin — shuning uchun ikkalasi ham.
      to_char(n.created_at + interval '5 hours', 'DD.MM.YYYY') as hodisa_sana,
      to_char(n.created_at + interval '5 hours', 'HH24:MI')   as vaqt,
      e.description                           as izoh,
      e.source                                as manba,
      -- 🔴 `full_name_or_email()` ga BOG'LANMAYDI: PROVODKA_ISM.sql RUN
      --    qilinmagan bazada butun RPC 42883 bilan yiqilardi.
      coalesce(
        nullif(to_jsonb(e)  ->> 'created_by_name', ''),
        nullif(to_jsonb(pr) ->> 'full_name', ''),
        '')                                   as kim
    from hodim_notify n
    join entry e    on e.id = n.entry_id
    join accounts r on r.id = n.kassa_id
    left join accounts a on a.id = n.acc_id
    -- ⚠️ `created_by` turi bazada aniqlanmagan (PROVODKA_ISM.sql 7.5) — uuid ham,
    --    matn ham bo'lishi mumkin. `::uuid` cast FAQAT to'liq uuid shaklida
    --    bajariladi; aks holda bitta buzuq qiymat 22P02 bilan BUTUN RPC ni
    --    yiqitardi (PROVODKA_AI_HISOBOT.sql dagi qat'iy shakl).
    left join profiles pr
      on pr.id = case when (to_jsonb(e) ->> 'created_by') ~ '^[0-9a-fA-F-]{36}$'
                      then (to_jsonb(e) ->> 'created_by')::uuid end
    left join lateral (
      select bool_or(a2.section = 'pul')        as qarshi_pul,
             string_agg(distinct a2.code, ', ') as qarshi_kod,
             string_agg(distinct a2.name, ', ') as qarshi_nom
        from entry_line l2
        join accounts a2 on a2.id = l2.account_id
       where l2.entry_id = n.entry_id
         -- 🔴 Yon ASL yo'nalishdan (n.dt_yon), `delta` ishorasidan EMAS:
         --    o'chirish va summani kamaytiruvchi tahrirda delta teskari
         --    bo'lib, qarshi tomon sifatida kassaning O'ZI chiqardi.
         and case when n.dt_yon then l2.credit else l2.debit end > 0
         -- Shu kassa daraxtining satrlari qarshi tomon emas
         and hodim_kassa_root(l2.account_id) is distinct from n.kassa_id
    ) q on true
   where n.id = any(v_ids)
  ) x;

  return jsonb_build_object('items', v_items, 'adminlar', v_admin);
end $fn$;

revoke all on function hodim_notify_pending(int) from public, anon, authenticated;
grant execute on function hodim_notify_pending(int) to service_role;

comment on function hodim_notify_pending(int) is
  'n8n uchun: yuborilmagan hodim-kassa xabarlari + admin qabul qiluvchilar. '
  'Chaqirilganda attempts oshadi (takror yuborishga qarshi). '
  '2026-08-26: plpgsql yozuv ozgaruvchisi r -> v_r (42702); javobga vaqt va hodisa_sana qoshildi.';


-- ############ TEKSHIRISH ############
-- (a) Yangi trigger o'rnidami — 3 qator chiqishi kerak:
-- select t.tgname, t.tgrelid::regclass as jadval,
--        case t.tgenabled when 'O' then 'yoqilgan' else t.tgenabled::text end as holat
--   from pg_trigger t
--  where t.tgname in ('trg_hodim_notify_entry_line', 'trg_hodim_notify_entry',
--                     'trg_hodim_notify_status')
--  order by t.tgname;

-- (b) Javobda yangi kalitlar bormi (navbat bo'sh bo'lsa items ham bo'sh keladi):
select hodim_notify_pending(3);

-- (c) Uchdan-uchga sinov:
--     1. hodim kassasidan xarajat  -> "Chiqim" xabari
--     2. kassaga transfer          -> "Kirim" / "Transfer" xabari
--     3. jurnaldan tahrir          -> "Tahrir" xabari
--     4. jurnaldan o'chirish       -> "O'chirildi" xabari
--     5. "Pul so'rash" -> admin tasdiqlaydi -> 🆕 endi xabar KELADI
--     Har birida 60 soniya kuting (navbatda 30 soniyalik ataylab kechikish bor).
