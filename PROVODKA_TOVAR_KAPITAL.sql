-- =====================================================================
--  PROVODKA_TOVAR_KAPITAL.sql — ombor sync'ini kapital mantig'iga o'tkazish
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  MAQSAD: sync_tovar_balances ham sync_filial_balans kabi ishlasin —
--     ombor hisobida HALI YOZUV YO'Q bo'lsa (wipe'dan keyingi birinchi
--     yozuv) qarshi tomon `boshlangich_kapital_id()` (8720) bo'lsin,
--     soxta "tovar kirimi" EMAS.
--
--  ⚠️⚠️ MUHIM: sync_tovar_balances ning HOZIRGI tanasi repoda YO'Q —
--     u n8n/SQL orqali alohida yaratilgan. Men uni ko'rmadim.
--     Shuning uchun 1-bo'lim uni bazadan CHIQARADI.
--
--     TARTIB:
--       1) 0-bo'limni RUN qiling (faqat o'qiydi).
--       2) Chiqqan ta'rifni 2-bo'limdagi yangi versiya bilan solishtiring.
--          Ayniqsa QARSHI HISOB kodlari va kurs mantig'iga qarang.
--       3) Konstantalar mos bo'lmasa — 2-bo'lim boshidagi ⚙️ qiymatlarni
--          to'g'rilang (yoki eski ta'rifni menga yuboring, moslab beraman).
--       4) Shundan keyingina 2-bo'limni RUN qiling.
--
--  TALAB: PROVODKA_KAPITAL.sql (boshlangich_kapital_id) RUN qilingan bo'lsin.
--
--  ⚠️ Tovar Sync workflow (DkIxfOW2kLs0tpIe) Inactive bo'lsin — funksiya
--     almashayotganda o'rtada ishlab qolmasin.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. HOZIRGI HOLAT — avval shuni RUN qiling
-- ---------------------------------------------------------------------

-- 0.1 ⬅️ ENG MUHIM: hozirgi funksiyaning to'liq ta'rifi.
--     Yangi versiya bilan solishtiring; farq bo'lsa menga yuboring.
select p.oid::regprocedure as imzo,
       pg_get_functiondef(p.oid) as tarif
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'sync_tovar_balances';

-- 0.2 Ombor hisoblari: warehouse_id bog'lanishi va hozirgi qoldiq
select a.code, a.name, a.section, a.type, a.currency,
       a.warehouse_id, a.parent_id is null as mustaqil, a.is_active,
       coalesce(sum(l.debit - l.credit), 0) as qoldiq_uzs,
       coalesce(sum(case when l.debit > 0 then coalesce(l.fc_amount,0)
                         else -coalesce(l.fc_amount,0) end), 0) as qoldiq_usd,
       count(l.id) as satrlar
  from accounts a
  left join entry_line l on l.account_id = a.id
  left join entry e on e.id = l.entry_id and e.status = 'posted' and e.is_deleted = false
 where a.section = 'tovar' or a.warehouse_id is not null
 group by a.code, a.name, a.section, a.type, a.currency, a.warehouse_id, a.parent_id, a.is_active
 order by a.code;

-- 0.3 Eski tovar yozuvlari QAYSI qarshi hisobni ishlatgan.
--     (ROLLBACK'dan OLDIN RUN qilsangiz to'liq ko'rinadi; keyin bo'sh chiqadi —
--      o'shanda javob 0.1 dagi ta'rifda.)
select ao.code as ombor_kod, ao.name as ombor_nom,
       aq.code as qarshi_kod, aq.name as qarshi_nom, aq.type as qarshi_type,
       count(*) as nechta, sum(lo.debit + lo.credit) as summa
  from entry e
  join entry_line lo on lo.entry_id = e.id
  join accounts ao   on ao.id = lo.account_id and ao.section = 'tovar'
  join entry_line lq on lq.entry_id = e.id and lq.id <> lo.id
  join accounts aq   on aq.id = lq.account_id
 where e.source = 'aros_auto' and e.is_deleted = false
 group by ao.code, ao.name, aq.code, aq.name, aq.type
 order by ao.code;


-- ---------------------------------------------------------------------
-- 2. YANGI sync_tovar_balances
-- ---------------------------------------------------------------------
-- ⚠️ 0-bo'lim natijasini ko'rmasdan RUN QILMANG.
--
-- IMZO: n8n workflow `{ p_data: [{ref, name, usd}] }` yuboradi
--       (ref = warehouse_id, usd = ombor qiymati DOLLARDA).
--       Shuning uchun imzo: sync_tovar_balances(p_data jsonb).
--       Qo'shimcha p_dry_run default'li — eski 1-argumentli chaqiruv ishlayveradi.
--
-- MANTIQ (sync_filial_balans bilan bir xil):
--   joriy  := ombor hisobining USD qoldig'i (fc)
--   delta  := aros_usd − joriy
--   delta = 0  -> yozilmaydi
--   delta <> 0 -> bitta entry (2 satr):
--      • ombor hisobida HALI YOZUV YO'Q  -> Dt ombor / Kt boshlang'ich kapital
--      • aks holda delta > 0 (o'sish)    -> Dt ombor / Kt <v_kod_kirim>
--      • aks holda delta < 0 (kamayish)  -> Dt <v_kod_cogs> / Kt ombor
create or replace function sync_tovar_balances(p_data jsonb, p_dry_run boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- ⚙️⚙️ QARSHI HISOBLAR — 0.1 / 0.3 natijasiga qarab TEKSHIRING
  --     v_kod_kirim : ombor O'SGANDA Kt tomoni (tovar kirimi manbai)
  --     v_kod_cogs  : ombor KAMAYGANDA Dt tomoni (sotilgan tovar tannarxi)
  v_kod_kirim text := '6010';   -- yetkazib beruvchilar (qarz) — eski funksiya boshqasini
                                 -- ishlatgan bo'lsa shu yerda to'g'rilang
  v_kod_cogs  text := '9110';   -- tovar tannarxi (COGS)

  v_list      jsonb;
  v_el        jsonb;
  v_ref       text;
  v_kapital   uuid;
  v_kirim     uuid;
  v_cogs      uuid;
  v_sana      timestamptz := now() at time zone 'Asia/Tashkent';
  v_izoh      text;
  v_rate      numeric;

  v_acc       uuid;
  v_acc_code  text;
  v_acc_nom   text;
  v_yangi     numeric;
  v_fc        numeric;
  v_cnt       bigint;
  v_delta_fc  numeric;
  v_delta_uzs numeric;
  v_summa     numeric;
  v_dt        uuid;
  v_kt        uuid;
  v_entry     uuid;
  v_birinchi  boolean;

  n_ombor     int := 0;
  n_yozuv     int := 0;
  n_otkaz     int := 0;
  v_ogoh      jsonb := '[]'::jsonb;
  v_tafsil    jsonb := '[]'::jsonb;
begin
  -- Ikkita sync bir vaqtda ishlab, deltani ikki marta yozmasin
  perform pg_advisory_xact_lock(hashtext('sync_tovar_balances'));

  if p_data is null then
    return jsonb_build_object('ok', false, 'error', 'p_data bo''sh');
  end if;
  if jsonb_typeof(p_data) = 'object' and p_data ? 'p_data' then
    v_list := p_data -> 'p_data';
  else
    v_list := p_data;
  end if;
  if jsonb_typeof(v_list) <> 'array' then
    return jsonb_build_object('ok', false,
      'error', 'JSON massiv kutilgan edi, keldi: ' || jsonb_typeof(v_list));
  end if;

  -- Qarshi hisoblar
  v_kapital := boshlangich_kapital_id();
  if v_kapital is null then
    return jsonb_build_object('ok', false,
      'error', 'Boshlang''ich kapital hisobi topilmadi — PROVODKA_KAPITAL.sql RUN qilinganmi?');
  end if;
  select id into v_kirim from accounts where code = v_kod_kirim and is_active limit 1;
  select id into v_cogs  from accounts where code = v_kod_cogs  and is_active limit 1;
  if v_kirim is null or v_cogs is null then
    return jsonb_build_object('ok', false,
      'error', 'Qarshi hisob topilmadi: kirim=' || v_kod_kirim || ' cogs=' || v_kod_cogs
               || '. Funksiya boshidagi ⚙️ konstantalarni to''g''rilang.');
  end if;

  -- Ombor qiymati DOLLARDA keladi -> so'm ekvivalenti uchun kurs kerak
  if to_regprocedure('public.conv_baza_kurs(text)') is not null then
    begin
      execute 'select conv_baza_kurs($1)' into v_rate using 'USD';
    exception when others then v_rate := null;
    end;
  end if;

  v_izoh := 'Aros ombor sync ' || to_char(v_sana, 'YYYY-MM-DD HH24:MI');

  for v_el in select * from jsonb_array_elements(v_list)
  loop
    v_ref := nullif(btrim(coalesce(v_el ->> 'ref', '')), '');
    if v_ref is null then
      v_ogoh := v_ogoh || jsonb_build_object('ref', null, 'sabab', 'ref yo''q');
      continue;
    end if;
    if (v_el -> 'usd') is null or jsonb_typeof(v_el -> 'usd') = 'null' then
      continue;                       -- maydon yo'q -> tegilmaydi (0 EMAS)
    end if;
    v_yangi := (v_el ->> 'usd')::numeric;
    n_ombor := n_ombor + 1;

    -- Ombor hisobini warehouse_id bo'yicha topamiz.
    -- ⚠️ TO'SIQ: faqat section='tovar'. Shu shart bo'lmasa xato bir kun
    --    pulni kassaga yoki boshqa hisobga yozib yuborishi mumkin.
    select a.id, a.code, a.name
      into v_acc, v_acc_code, v_acc_nom
      from accounts a
     where a.is_active
       and a.section = 'tovar'
       and a.warehouse_id is not null
       and btrim(a.warehouse_id::text) = v_ref
     limit 1;

    if v_acc is null then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object('ref', v_ref,
        'sabab', 'warehouse_id=' || v_ref || ' bo''yicha faol tovar hisobi topilmadi');
      continue;
    end if;

    -- Joriy USD qoldiq + yozuv bor-yo'qligi
    select coalesce(sum(case when l.debit > 0 then coalesce(l.fc_amount, 0)
                             else -coalesce(l.fc_amount, 0) end), 0),
           count(*)
      into v_fc, v_cnt
      from entry_line l
      join entry e on e.id = l.entry_id
     where l.account_id = v_acc
       and e.status = 'posted'
       and e.is_deleted = false;

    v_birinchi := (v_cnt = 0);
    v_delta_fc := v_yangi - v_fc;
    if v_delta_fc = 0 then continue; end if;

    if v_rate is null or v_rate <= 0 then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object('ref', v_ref, 'delta_usd', v_delta_fc,
        'sabab', 'USD kursi topilmadi — so''m ekvivalentini hisoblab bo''lmadi');
      continue;
    end if;

    v_delta_uzs := round(v_delta_fc * v_rate, 2);
    v_summa := abs(v_delta_uzs);
    if v_summa = 0 then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object('ref', v_ref, 'delta_usd', v_delta_fc,
        'sabab', 'so''m summasi 0 ga yaxlitlandi — yozilmadi');
      continue;
    end if;

    -- Yo'nalish va qarshi hisob
    if v_delta_fc > 0 then
      v_dt := v_acc;
      v_kt := case when v_birinchi then v_kapital else v_kirim end;
    else
      v_dt := case when v_birinchi then v_kapital else v_cogs end;
      v_kt := v_acc;
    end if;

    v_tafsil := v_tafsil || jsonb_build_object(
      'ref', v_ref, 'ombor', v_acc_code, 'nom', v_acc_nom,
      'joriy_usd', v_fc, 'aros_usd', v_yangi, 'delta_usd', v_delta_fc,
      'kurs', v_rate, 'summa_uzs', v_summa,
      'qarshi', case when v_birinchi then 'boshlangich_kapital'
                     when v_delta_fc > 0 then v_kod_kirim else v_kod_cogs end,
      'birinchi', v_birinchi);

    if p_dry_run then
      n_yozuv := n_yozuv + 1;
      continue;
    end if;

    insert into entry(entry_date, description, source, status, created_by, fc_rate)
    values (current_date,
            v_izoh || ' · ' || coalesce(v_acc_nom, v_acc_code),
            'aros_auto', 'posted', 'tovar_sync', v_rate)
    returning id into v_entry;

    -- fc_amount FAQAT ombor satriga (u USD'da o'lchanadi) va HAR DOIM musbat
    insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
    values (v_entry, v_dt, v_summa, 0,
            case when v_dt = v_acc then abs(v_delta_fc) else null end);
    insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
    values (v_entry, v_kt, 0, v_summa,
            case when v_kt = v_acc then abs(v_delta_fc) else null end);

    n_yozuv := n_yozuv + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'sana', to_char(v_sana, 'YYYY-MM-DD HH24:MI:SS'),
    'omborlar', n_ombor,
    'yozuvlar', n_yozuv,
    'otkazildi', n_otkaz,
    'kurs', v_rate,
    'ogohlantirishlar', v_ogoh,
    'tafsilot', v_tafsil);
end $$;

revoke all on function sync_tovar_balances(jsonb, boolean) from public, anon, authenticated;
grant execute on function sync_tovar_balances(jsonb, boolean) to service_role;

comment on function sync_tovar_balances(jsonb, boolean) is
  'Aros ombor qoldig''i (USD) delta sync. Birinchi yozuvda Kt boshlang''ich kapital '
  '(soxta "tovar kirimi" emas), keyingilarida kirim/COGS. service_role only.';


-- ---------------------------------------------------------------------
-- 3. TEKSHIRUV
-- ---------------------------------------------------------------------

-- 3.1 Quruq yugurish — HECH NARSA YOZMAYDI (ref = warehouse_id)
-- select jsonb_pretty(sync_tovar_balances('[{"ref":"1","name":"Ombor","usd":150000}]'::jsonb, true));

-- 3.2 Yangi imzo o'rnatildimi (ikkalasi ham ko'rinishi mumkin — eski
--     1-argumentli chaqiruv default tufayli yangisiga tushadi)
select oid::regprocedure as imzo
  from pg_proc
 where proname = 'sync_tovar_balances';

-- 3.3 Ombor hisoblari va qoldiqlari
select a.code, a.name, a.warehouse_id,
       coalesce(sum(l.debit - l.credit), 0) as uzs,
       coalesce(sum(case when l.debit > 0 then coalesce(l.fc_amount,0)
                         else -coalesce(l.fc_amount,0) end), 0) as usd
  from accounts a
  left join entry_line l on l.account_id = a.id
  left join entry e on e.id = l.entry_id and e.status = 'posted' and e.is_deleted = false
 where a.section = 'tovar'
 group by a.code, a.name, a.warehouse_id
 order by a.code;

-- 3.4 Birinchi yozuvlar KAPITALGA tushdimi (9010/6010 ga emas)
select e.description, e.created_by,
       ad.code as dt_kod, ad.name as dt_nom,
       ak.code as kt_kod, ak.name as kt_nom,
       ld.debit as summa
  from entry e
  join entry_line ld on ld.entry_id = e.id and ld.debit > 0
  join entry_line lk on lk.entry_id = e.id and lk.credit > 0
  join accounts ad on ad.id = ld.account_id
  join accounts ak on ak.id = lk.account_id
 where e.source = 'aros_auto' and e.created_by = 'tovar_sync' and e.is_deleted = false
 order by e.created_at desc
 limit 20;

-- 3.5 Balans tenglikda (farq = 0 bo'lishi SHART)
select sum(case when bolim = 'AKTIV'   then amount else 0 end)
     - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end) as farq
  from balans(current_date);
