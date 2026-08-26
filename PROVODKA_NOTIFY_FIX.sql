-- =====================================================================
-- PROVODKA_NOTIFY_FIX.sql — hodim_notify_pending() ni tuzatish
-- ---------------------------------------------------------------------
-- XATO (n8n `Navbat` node, 2026-08-26):
--   Bad request - column reference "r.id" is ambiguous   (SQLSTATE 42702)
--
-- SABAB: `hodim_notify_pending()` ichida IKKI XIL `r` bor edi —
--   · PL/pgSQL yozuv o'zgaruvchisi:  `r record;` + `for r in ... loop`
--   · SQL jadval taxallusi:          `join accounts r on r.id = n.kassa_id`
--   PL/pgSQL `r.id` ni qaysi biriga tegishli ekanini hal qila olmaydi va
--   BUTUN funksiyani 42702 bilan yiqitadi.
--
-- 🔴 NEGA HECH KIM SEZMADI VA NEGA `attempts` 0 DA QOLDI:
--   Buzuq `select` navbatda KAMIDA BITTA qator bo'lgandagina bajariladi —
--   undan oldin `if array_length(v_ids,1) is null then return ...` erta
--   qaytish bor. Ya'ni:
--     · navbat BO'SH  -> funksiya erta qaytadi, xato YO'Q, items: []
--       (aynan shuning uchun navbat tozalangach n8n'da IF false chiqdi)
--     · navbat TO'LA   -> 42702, va funksiya BITTA TRANZAKSIYA bo'lgani uchun
--       undan oldingi `update hodim_notify set attempts = attempts + 1`
--       ORQAGA QAYTADI. Shuning uchun 110 qatorning hammasi `attempts = 0`
--       va `last_error` bo'sh bo'lib qoldi — n8n `hodim_notify_fail` gacha
--       yetib bormaydi (400 ni `Navbat` node oladi).
--   Ya'ni bot BIRINCHI KUNDANOQ hech qachon ishlamagan.
--
-- TUZATISH: PL/pgSQL yozuv o'zgaruvchisi `r` -> `v_r` deb qayta nomlandi.
--   SQL taxallusi `r` (accounts) TEGILMADI — `r.code`, `r.name`, `to_jsonb(r)`
--   endi bir ma'noli. Boshqa BIRORTA qator o'zgarmadi.
--
-- ⚠️ ADDITIVE: imzo O'ZGARMAYDI — `hodim_notify_pending(int)`.
--    Faqat tana almashadi. `grant`/`revoke` ham o'sha-o'sha qayta yoziladi.
-- ⚠️ Funksiya tanasi NOMLANGAN teg bilan (CLAUDE.md qoidasi).
-- =====================================================================


-- ############ 1-QADAM — TUZATILGAN FUNKSIYA ############
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
  v_r     record;
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
  '2026-08-26: plpgsql yozuv ozgaruvchisi r -> v_r (accounts taxallusi r bilan ziddiyat, 42702).';


-- ############ 2-QADAM — DARROV TEKSHIRISH ############
-- Xato qaytmasligi kerak. Navbat bo'sh bo'lsa: {"items": [], "adminlar": [...]}
-- Navbatda qator bo'lsa: items ichida xabarlar.
-- 🔴 DIQQAT: bu chaqiruv HAM `attempts` ni oshiradi va qatorlarni "olingan"
--    deb belgilamaydi — n8n keyingi daqiqada ularni baribir oladi. Xavfsiz.
select hodim_notify_pending(5);


-- ############ 3-QADAM — n8n ############
-- Boshqa hech narsa kerak emas: workflow, kredensial va triggerlar SOZ edi.
-- 1-2 daqiqadan keyin n8n Executions'da yashil bajarilishlar paydo bo'ladi.
-- Tekshirish (DIAG_BOT 4-so'rov yoki quyidagi):
-- select case
--          when n.sent_at is not null and n.last_error is null then 'yuborildi'
--          when n.sent_at is not null                          then 'yopilgan'
--          when n.attempts >= 30                               then 'olgan'
--          when n.last_error is not null                       then 'xato'
--          else 'navbatda' end   as holat,
--        count(*) as soni, max(n.attempts) as eng_kop_urinish
--   from hodim_notify n group by 1 order by 1;
-- `eng_kop_urinish` > 0 -> RPC endi xatosiz ishlayapti ✅
