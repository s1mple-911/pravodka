-- =====================================================================
-- PROVODKA_JADVAL_NOTIFY.sql — Telegram xabariga JADVAL xulosasi (3-bosqich)
-- ---------------------------------------------------------------------
-- BRIEF_PROVODKA_JADVAL.md. Hodim Excel'dan nusxalagan ro'yxat endi
-- `entry.jadval` jsonb ustunida (PROVODKA_JADVAL.sql, 1-bosqich). Xabarda
-- 1500 belgilik blob o'rniga "📋 Jadval: 38 qator · jami 5 719 500 so'm".
--
-- BU FAYL BIR ISH QILADI: `hodim_notify_pending(int)` javobidagi har item'ga
-- ikki maydon QO'SHADI — `jadval_n` (int) va `jadval_jami` (numeric).
-- Tana PROVODKA_NOTIFY_TOLIQ.sql (2026-08-26) dagi ENG OXIRGI versiyaning
-- nusxasi, faqat shu ikki qator qo'shilgan. Imzo/returns/grant o'zgarmagan.
--
-- ⚠️ ADDITIVE. `to_jsonb(e) -> 'jadval'` naqshi tufayli PROVODKA_JADVAL.sql
--    RUN qilinmagan bazada ham ishlaydi (maydonlar null keladi).
-- ⚠️ Old shart: PROVODKA_NOTIFY_TOLIQ.sql RUN qilingan bo'lsin (u yerdagi
--    1-bo'lim triggeri bu faylda YO'Q — bu fayl faqat RPC tanasi).
-- ⚠️ n8n tomoni: N8N_XABAR_TUZ.js matni "Xabar Tuz" node'iga QO'LDA qo'yiladi.
-- ⚠️ Funksiya tanasi NOMLANGAN teg bilan; izohlarda dollar-qavs YO'Q.
-- =====================================================================

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
      -- 🆕 2026-09-02 (jadval): Excel'dan nusxalangan ro'yxat endi `entry.jadval` jsonb da
      --    (PROVODKA_JADVAL.sql). Telegram'ga faqat XULOSA: qator soni + jami.
      --    `to_jsonb(e)` naqshi ataylab — ustun hali yo'q bazada ham RPC yiqilmaydi (null).
      (to_jsonb(e) -> 'jadval' ->> 'n')::int          as jadval_n,
      (to_jsonb(e) -> 'jadval' ->> 'jami')::numeric   as jadval_jami,
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
  '2026-08-26: plpgsql yozuv ozgaruvchisi r -> v_r (42702); javobga vaqt va hodisa_sana qoshildi. '
  '2026-09-02: javobga jadval_n va jadval_jami qoshildi (entry.jadval xulosasi).';

-- ############ TEKSHIRISH ############
-- Javobda yangi kalitlar bormi (service_role bilan; navbat bo'sh bo'lsa items = []):
-- select jsonb_pretty(hodim_notify_pending(1));
-- Funksiya o'rnidami:
-- select to_regprocedure('public.hodim_notify_pending(int)') is not null as f_pending;
