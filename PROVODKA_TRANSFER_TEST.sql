-- =====================================================================
--  PROVODKA_TRANSFER_TEST.sql — takrorlanmaslikni SINAB TASDIQLASH
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  🔴 ENG MUHIM SAVOL: transfer bir marta yozilgach, sync qayta ishlaganda
--     QAYTA yozadimi? Pul ikki marta ayirilsa — halokat.
--     Bu skript shuni HAQIQIY bazada, HAQIQIY kassalarda sinaydi.
--
--  ✅ XAVFSIZ: skript oxirida ATAYLAB `raise exception` bor. PostgreSQL'da
--     DO bloki bitta tranzaksiya — exception butun blokni ORQAGA QAYTARADI.
--     Ya'ni sinov davomida yozilgan HAMMA narsa (test yozuvlari, o'chirish
--     belgisi) yo'qoladi. Bazada IZ QOLMAYDI.
--
--  ⚠️ SHUNING UCHUN NATIJA "XATO" (ERROR) BO'LIB CHIQADI — qo'rqmang.
--     Xato matnining o'zi — sinov hisoboti. Uni o'qing:
--        "NATIJA: ✅ HAMMASI TO'G'RI"   yoki   "NATIJA: ❌ N ta XATO"
--
--  ⚠️ TALAB: PROVODKA_TRANSFER.sql avval RUN qilingan bo'lsin.
--
--  🛡️ 7-SINOV — CUTOFF. Ikkinchi halokat yo'li shu: eski (daftarga allaqachon
--     singib ketgan) transferni yozish ham pulni ikki marta ayiradi.
--     7a — 3 kun oldingi transfer to'siladimi.
--     7b — qo'lda berilgan ESKI p_from himoyani OCHA oladimi (OCHMASLIGI SHART).
--          Cutoff = OXIRGI delta sync payti; sync_state.transfers_from
--          ISHLATILMAYDI (u boshqa mexanizmniki va oylar oldingi bo'lishi mumkin).
--
--  ESLATMA: bu sinov TAKRORLANMASLIKni tekshiradi. `check_entry_balanced`
--  triggeri kechiktirilgan (deferred) bo'lsa u faqat COMMIT paytida ishlaydi,
--  bu yerda esa commit yo'q — shuning uchun Dt=Kt ni skript O'ZI tekshiradi.
-- =====================================================================

do $test$
declare
  -- Sinov uchun tanlanadigan haqiqiy kassalar
  v_fil       uuid; v_fil_kod text; v_fil_nom text; v_fil_ref text;
  v_mar       uuid; v_mar_kod text; v_mar_nom text; v_mar_ref text;
  v_naqd_fil  uuid; v_naqd_mar  uuid;
  v_click_fil uuid; v_click_mar uuid;

  -- p_from: RPC'ga beriladigan "qo'lda chegara". YANGI mantiqda u himoyani
  -- FAQAT QATTIQLASHTIRA oladi — bo'shata olmaydi (7-sinov shuni tekshiradi).
  v_from      timestamptz := now() - interval '1 day';
  v_cut_info  jsonb;
  v_tmp       jsonb;
  v_cut       timestamptz;   -- haqiqiy cutoff (oxirgi delta sync payti)
  v_vaqt      text;
  v_eski_vaqt text;

  v_summa     numeric := 1234567;
  v_summa2    numeric := 222000;

  v_json      jsonb; v_json2 jsonb; v_json3 jsonb; v_json_eski jsonb;
  v_r         jsonb;

  v_ext       text := 'aros_tr:TEST-IDEMP-1:cash';
  v_n         int;
  v_dt_acc    uuid; v_kt_acc uuid;
  v_dt_sum    numeric; v_kt_sum numeric;

  v_bal_0     numeric;   -- filial naqd qoldig'i: boshida
  v_bal_1     numeric;   -- 1-chaqiruvdan keyin
  v_bal_2     numeric;   -- 2-chaqiruvdan keyin (O'ZGARMASLIGI SHART)
  v_ochirilgan boolean;

  v_ind       int;
  v_rap       text := '';
  v_xato      int := 0;

  -- kichik yordamchi: hisobot satri qo'shish
  v_ok        boolean;
begin
  -- ⚠️ Cutoff = daftar Aros bilan OXIRGI marta tenglashtirilgan payt, ya'ni
  --    u now()ga JUDA YAQIN bo'lishi mumkin (delta har 30 daqiqada ishlaydi).
  --    Shuning uchun "yozilishi kerak" degan sinov transferlari cutoff'dan
  --    ANIQ keyin bo'lsin — aks holda ular haqli ravishda to'silib, sinov
  --    yolg'on ❌ berardi.
  v_vaqt      := to_char((now() + interval '1 minute') at time zone 'Asia/Tashkent',
                         'YYYY-MM-DD"T"HH24:MI:SS');
  v_eski_vaqt := to_char((now() - interval '3 days') at time zone 'Asia/Tashkent',
                         'YYYY-MM-DD"T"HH24:MI:SS');

  -- Haqiqiy cutoff (RPC ham AYNAN shundan oladi) — 7-sinov shunga tayanadi
  v_cut_info := aros_transfer_cutoff();
  v_cut      := nullif(v_cut_info ->> 'cutoff', '')::timestamptz;

  v_rap := chr(10) || '════════ TRANSFER SYNC — TAKRORLANMASLIK SINOVI ════════' || chr(10);

  -- =================================================================
  -- 0. POYDEVOR: ext_ref ustida UNIQUE indeks bormi
  -- =================================================================
  select count(*)
    into v_ind
    from pg_index x
    join pg_class t     on t.oid = x.indrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public' and t.relname = 'entry' and x.indisunique
     and x.indnkeyatts = 1
     and x.indkey[0] = (select attnum from pg_attribute
                         where attrelid = t.oid and attname = 'ext_ref' and not attisdropped);

  if v_ind > 0 then
    v_rap := v_rap || '✅ 0. entry.ext_ref UNIQUE indeksi bor (2-himoya qatlami ishlaydi)' || chr(10);
  else
    v_xato := v_xato + 1;
    v_rap := v_rap || '❌ 0. entry.ext_ref UNIQUE indeksi YO''Q! '
                   || 'PROVODKA_TRANSFER.sql 0-bo''limini RUN qiling.' || chr(10);
  end if;

  -- =================================================================
  -- 1. Sinov uchun HAQIQIY kassalarni tanlaymiz
  -- =================================================================
  select k.id, k.code, k.name, btrim(k.filial_ref::text)
    into v_fil, v_fil_kod, v_fil_nom, v_fil_ref
    from accounts k
   where k.section = 'pul' and k.is_active and k.parent_id is null
     and coalesce(k.currency, 'UZS') = 'UZS'
     and coalesce(k.kassa_turi, '') = 'filial'
     and k.filial_ref is not null
     and aros_tur_hisob(k.id, 'cash') is not null
   order by k.code
   limit 1;

  select k.id, k.code, k.name, btrim(k.filial_ref::text)
    into v_mar, v_mar_kod, v_mar_nom, v_mar_ref
    from accounts k
   where k.section = 'pul' and k.is_active and k.parent_id is null
     and coalesce(k.currency, 'UZS') = 'UZS'
     and coalesce(k.kassa_turi, '') = 'markaziy'
     and aros_tur_hisob(k.id, 'cash') is not null
   order by k.code
   limit 1;

  if v_fil is null or v_mar is null then
    raise exception 'SINOV BOSHLANMADI: naqd child''i bor filial (%) yoki markaziy (%) '
                    'kassa topilmadi. PROVODKA_SYNC_FIX.sql 2-bandini RUN qiling.',
                    coalesce(v_fil_kod, 'YO''Q'), coalesce(v_mar_kod, 'YO''Q');
  end if;

  v_naqd_fil  := aros_tur_hisob(v_fil, 'cash');
  v_naqd_mar  := aros_tur_hisob(v_mar, 'cash');
  v_click_fil := aros_tur_hisob(v_fil, 'click');
  v_click_mar := aros_tur_hisob(v_mar, 'click');

  v_rap := v_rap || '   Jo''natuvchi : ' || v_fil_kod || ' ' || v_fil_nom
                 || ' (filial_ref=' || v_fil_ref || ')' || chr(10)
                 || '   Qabul qiluvchi: ' || v_mar_kod || ' ' || v_mar_nom || chr(10)
                 || '   Summa       : ' || v_summa::text || chr(10)
                 || '────────────────────────────────────────────────────────' || chr(10);

  -- Boshlang'ich qoldiq (filial naqd child)
  select coalesce(sum(l.debit - l.credit), 0)
    into v_bal_0
    from entry_line l
    join entry e on e.id = l.entry_id
   where l.account_id = v_naqd_fil and e.status = 'posted' and e.is_deleted = false;

  -- Sinov JSON'i (AYNAN bir xil — ikki marta yuboriladi)
  v_json := jsonb_build_array(jsonb_build_object(
              'id',             'TEST-IDEMP-1',
              'status',         'received',
              'sender_id',      v_fil_ref,
              'sender_title',   v_fil_nom,
              'receiver_id',    v_mar_ref,
              'receiver_title', v_mar_nom,
              'received_at',    v_vaqt,
              'cash',           v_summa));

  -- =================================================================
  -- 2. BIRINCHI CHAQIRUV — yozilishi kerak
  -- =================================================================
  v_r := sync_transfer_balans(v_json, false, v_from);

  v_ok := coalesce((v_r ->> 'yozuvlar')::int, -1) = 1
      and coalesce((v_r ->> 'takror')::int, -1) = 0;
  if v_ok then
    v_rap := v_rap || '✅ 1-chaqiruv: yozuvlar=1, takror=0' || chr(10);
  else
    v_xato := v_xato + 1;
    v_rap := v_rap || '❌ 1-chaqiruv: yozuvlar=' || coalesce(v_r ->> 'yozuvlar', '?')
                   || ' takror=' || coalesce(v_r ->> 'takror', '?')
                   || ' (kutilgan 1 / 0)' || chr(10)
                   || '   javob: ' || coalesce(v_r::text, 'null') || chr(10);
  end if;

  -- Yozuv haqiqatan to'g'ri hisoblarga tushdimi
  select count(*) into v_n from entry where ext_ref = v_ext;
  select l.account_id, l.debit into v_dt_acc, v_dt_sum
    from entry e join entry_line l on l.entry_id = e.id
   where e.ext_ref = v_ext and l.debit > 0 limit 1;
  select l.account_id, l.credit into v_kt_acc, v_kt_sum
    from entry e join entry_line l on l.entry_id = e.id
   where e.ext_ref = v_ext and l.credit > 0 limit 1;

  if v_n = 1 and v_dt_acc = v_naqd_mar and v_kt_acc = v_naqd_fil
     and v_dt_sum = v_summa and v_kt_sum = v_summa then
    v_rap := v_rap || '✅ 1-chaqiruv: Dt markaziy.naqd / Kt filial.naqd, Dt=Kt='
                   || v_summa::text || chr(10);
  else
    v_xato := v_xato + 1;
    v_rap := v_rap || '❌ 1-chaqiruv: yozuv noto''g''ri — entry soni=' || v_n::text
                   || ' dt=' || coalesce(v_dt_sum::text, 'null')
                   || ' kt=' || coalesce(v_kt_sum::text, 'null')
                   -- coalesce SHART: null bo'lsa butun hisobot NULL bo'lib ketardi
                   || ' dt_hisob mos=' || coalesce((v_dt_acc = v_naqd_mar)::text, 'yozuv yo''q')
                   || ' kt_hisob mos=' || coalesce((v_kt_acc = v_naqd_fil)::text, 'yozuv yo''q')
                   || chr(10);
  end if;

  -- Qoldiq aynan BIR MARTA kamaydimi
  select coalesce(sum(l.debit - l.credit), 0)
    into v_bal_1
    from entry_line l
    join entry e on e.id = l.entry_id
   where l.account_id = v_naqd_fil and e.status = 'posted' and e.is_deleted = false;

  if v_bal_1 = v_bal_0 - v_summa then
    v_rap := v_rap || '✅ 1-chaqiruv: filial qoldig''i aynan BIR MARTA kamaydi ('
                   || v_bal_0::text || ' -> ' || v_bal_1::text || ')' || chr(10);
  else
    v_xato := v_xato + 1;
    v_rap := v_rap || '❌ 1-chaqiruv: qoldiq kutilganidek emas: ' || v_bal_0::text
                   || ' -> ' || v_bal_1::text || ' (kutilgan '
                   || (v_bal_0 - v_summa)::text || ')' || chr(10);
  end if;

  -- =================================================================
  -- 3. 🔴 IKKINCHI CHAQIRUV — AYNAN O'SHA JSON. QAYTA YOZMASLIGI SHART
  -- =================================================================
  v_r := sync_transfer_balans(v_json, false, v_from);

  if coalesce((v_r ->> 'yozuvlar')::int, -1) = 0
     and coalesce((v_r ->> 'takror')::int, -1) = 1 then
    v_rap := v_rap || '✅ 2-chaqiruv: yozuvlar=0, takror=1 — QAYTA YOZILMADI' || chr(10);
  else
    v_xato := v_xato + 1;
    v_rap := v_rap || '🔴 2-chaqiruv: yozuvlar=' || coalesce(v_r ->> 'yozuvlar', '?')
                   || ' takror=' || coalesce(v_r ->> 'takror', '?')
                   || ' (kutilgan 0 / 1) — IKKI MARTA YOZILDI!' || chr(10);
  end if;

  select count(*) into v_n from entry where ext_ref = v_ext;
  select coalesce(sum(l.debit - l.credit), 0)
    into v_bal_2
    from entry_line l
    join entry e on e.id = l.entry_id
   where l.account_id = v_naqd_fil and e.status = 'posted' and e.is_deleted = false;

  if v_n = 1 and v_bal_2 = v_bal_1 then
    v_rap := v_rap || '✅ 2-chaqiruv: entry soni hali ham 1, qoldiq O''ZGARMADI ('
                   || v_bal_2::text || ')' || chr(10);
  else
    v_xato := v_xato + 1;
    v_rap := v_rap || '🔴 2-chaqiruv: entry soni=' || v_n::text
                   || ', qoldiq ' || v_bal_1::text || ' -> ' || v_bal_2::text
                   || ' — PUL IKKI MARTA AYIRILDI!' || chr(10);
  end if;

  -- =================================================================
  -- 4. O'CHIRILGAN (is_deleted) yozuv TIRILMASLIGI kerak
  -- =================================================================
  update entry set is_deleted = true where ext_ref = v_ext;

  v_r := sync_transfer_balans(v_json, false, v_from);

  select count(*) into v_n from entry where ext_ref = v_ext;
  select is_deleted into v_ochirilgan from entry where ext_ref = v_ext limit 1;

  if coalesce((v_r ->> 'yozuvlar')::int, -1) = 0
     and v_n = 1 and coalesce(v_ochirilgan, false) then
    v_rap := v_rap || '✅ 3-chaqiruv: o''chirilgan yozuv TIRILMADI (yozuvlar=0, '
                   || 'is_deleted saqlanib qoldi)' || chr(10);
  else
    v_xato := v_xato + 1;
    v_rap := v_rap || '❌ 3-chaqiruv: yozuvlar=' || coalesce(v_r ->> 'yozuvlar', '?')
                   || ' entry soni=' || v_n::text
                   || ' is_deleted=' || coalesce(v_ochirilgan::text, 'null')
                   || ' — o''chirilgan yozuv qayta yozildi!' || chr(10);
  end if;

  -- =================================================================
  -- 5. BOSHQA id — dedup HAMMASINI to'sib qo'ymaganini tasdiqlash
  --    (bu ham muhim: "hech narsa yozmaydigan" sync ham buzuq sync)
  -- =================================================================
  v_json2 := jsonb_build_array(jsonb_build_object(
               'id',             'TEST-IDEMP-2',
               'status',         'received',
               'sender_id',      v_fil_ref,
               'sender_title',   v_fil_nom,
               'receiver_id',    v_mar_ref,
               'receiver_title', v_mar_nom,
               'received_at',    v_vaqt,
               'cash',           v_summa2));

  v_r := sync_transfer_balans(v_json2, false, v_from);

  if coalesce((v_r ->> 'yozuvlar')::int, -1) = 1 then
    v_rap := v_rap || '✅ Boshqa id (TEST-IDEMP-2): yozildi — dedup faqat '
                   || 'AYNAN o''sha transferni to''sadi' || chr(10);
  else
    v_xato := v_xato + 1;
    v_rap := v_rap || '❌ Boshqa id: yozuvlar=' || coalesce(v_r ->> 'yozuvlar', '?')
                   || ' (kutilgan 1) — haqiqiy transferlar ham yozilmayapti!' || chr(10)
                   || '   javob: ' || coalesce(v_r::text, 'null') || chr(10);
  end if;

  -- =================================================================
  -- 6. Bitta transfer, IKKI TUR — alohida yozuv + alohida dedup
  -- =================================================================
  if v_click_fil is null or v_click_mar is null then
    v_rap := v_rap || '⏭ Ikki tur sinovi o''tkazildi (click child''i yo''q)' || chr(10);
  else
    v_json3 := jsonb_build_array(jsonb_build_object(
                 'id',             'TEST-IDEMP-3',
                 'status',         'received',
                 'sender_id',      v_fil_ref,
                 'sender_title',   v_fil_nom,
                 'receiver_id',    v_mar_ref,
                 'receiver_title', v_mar_nom,
                 'received_at',    v_vaqt,
                 'cash',           100000,
                 'click',          50000));

    v_r := sync_transfer_balans(v_json3, false, v_from);
    if coalesce((v_r ->> 'yozuvlar')::int, -1) = 2 then
      v_rap := v_rap || '✅ Ikki tur: 2 ta alohida yozuv (naqd + click)' || chr(10);
    else
      v_xato := v_xato + 1;
      v_rap := v_rap || '❌ Ikki tur: yozuvlar=' || coalesce(v_r ->> 'yozuvlar', '?')
                     || ' (kutilgan 2)' || chr(10);
    end if;

    v_r := sync_transfer_balans(v_json3, false, v_from);
    if coalesce((v_r ->> 'yozuvlar')::int, -1) = 0
       and coalesce((v_r ->> 'takror')::int, -1) = 2 then
      v_rap := v_rap || '✅ Ikki tur, qayta chaqiruv: yozuvlar=0, takror=2' || chr(10);
    else
      v_xato := v_xato + 1;
      v_rap := v_rap || '🔴 Ikki tur, qayta chaqiruv: yozuvlar='
                     || coalesce(v_r ->> 'yozuvlar', '?')
                     || ' takror=' || coalesce(v_r ->> 'takror', '?')
                     || ' (kutilgan 0 / 2)' || chr(10);
    end if;
  end if;

  -- =================================================================
  -- 7. CUTOFF — daftarga allaqachon singib ketgan eski transfer
  --    Cutoff = OXIRGI delta sync payti (birinchisi EMAS). Undan oldingi
  --    transfer daftarga allaqachon kirgan — yozilsa IKKI MARTA ayiriladi.
  -- =================================================================
  v_json_eski := jsonb_build_array(jsonb_build_object(
                   'id',             'TEST-IDEMP-ESKI',
                   'status',         'received',
                   'sender_id',      v_fil_ref,
                   'sender_title',   v_fil_nom,
                   'receiver_id',    v_mar_ref,
                   'receiver_title', v_mar_nom,
                   'received_at',    v_eski_vaqt,     -- 3 kun oldin
                   'cash',           999000));

  v_r := sync_transfer_balans(v_json_eski, false, v_from);

  if coalesce((v_r ->> 'yozuvlar')::int, -1) = 0
     and coalesce((v_r ->> 'cutoffdan_eski')::int, -1) = 1 then
    v_rap := v_rap || '✅ Cutoff: 3 kun oldingi transfer yozilmadi '
                   || '(daftarga allaqachon singigan)' || chr(10);
  else
    v_xato := v_xato + 1;
    v_rap := v_rap || '❌ Cutoff: yozuvlar=' || coalesce(v_r ->> 'yozuvlar', '?')
                   || ' cutoffdan_eski=' || coalesce(v_r ->> 'cutoffdan_eski', '?')
                   || ' (kutilgan 0 / 1) — cutoff='
                   || coalesce(v_r ->> 'cutoff', 'null') || chr(10);
  end if;

  -- -----------------------------------------------------------------
  -- 7b. ⬅️ AYNAN TUZATILGAN XATO: p_from himoyani OCHA OLMAYDI.
  --     Eski mantiqda qo'lda berilgan eski sana (yoki oylar oldingi
  --     sync_state.transfers_from) cutoff'ni orqaga surib, 1044/1046 kabi
  --     eski transferlarni ikki marta yozib yuborardi.
  -- -----------------------------------------------------------------
  if v_cut is null then
    v_rap := v_rap || '⚠️ 7b o''tkazib yuborildi: cutoff yo''q (delta sync hech '
                   || 'qachon ishlamagan). Avval sync_filial_balans ni ishlating.' || chr(10);
  else
    -- (1) Funksiya darajasida: 1 yil oldingi p_from cutoff'ni siljitmasin
    v_tmp := aros_transfer_cutoff(v_cut - interval '365 days');
    if nullif(v_tmp ->> 'cutoff', '')::timestamptz = v_cut
       and coalesce((v_tmp ->> 'p_from_ishlatilmadi')::boolean, false) then
      v_rap := v_rap || '✅ p_from: eski sana e''tiborsiz qoldirildi, cutoff joyida'
                     || chr(10);
    else
      v_xato := v_xato + 1;
      v_rap := v_rap || '🔴 p_from HIMOYANI OCHDI: cutoff '
                     || coalesce(v_cut::text, 'null') || ' -> '
                     || coalesce(v_tmp ->> 'cutoff', 'null')
                     || ' (SYNC''NI YOQMANG)' || chr(10);
    end if;

    -- (2) RPC darajasida: o'sha eski p_from bilan ham eski transfer yozilmasin
    --     (dry_run — hech narsa yozilmaydi, faqat sanoq ko'riladi)
    v_r := sync_transfer_balans(v_json_eski, true, v_cut - interval '365 days');
    if coalesce((v_r ->> 'yozuvlar')::int, -1) = 0
       and coalesce((v_r ->> 'cutoffdan_eski')::int, -1) = 1 then
      v_rap := v_rap || '✅ p_from + eski transfer: baribir to''sildi' || chr(10);
    else
      v_xato := v_xato + 1;
      v_rap := v_rap || '🔴 p_from + eski transfer O''TIB KETDI: yozuvlar='
                     || coalesce(v_r ->> 'yozuvlar', '?')
                     || ' cutoffdan_eski=' || coalesce(v_r ->> 'cutoffdan_eski', '?')
                     || ' (kutilgan 0 / 1) — SYNC''NI YOQMANG' || chr(10);
    end if;

    -- (3) sync_state.transfers_from ENDI ISHLATILMAYDI — ko'rsatib qo'yamiz
    v_rap := v_rap || '   ℹ️ cutoff=' || v_cut::text
                   || ' · manba: ' || coalesce(v_cut_info ->> 'manba', '?')
                   || chr(10)
                   || '   ℹ️ sync_state.transfers_from='
                   || coalesce(v_cut_info ->> 'sync_state_transfers_from', '(yo''q)')
                   || ' (ISHLATILMAYDI — faqat ma''lumot)' || chr(10);
  end if;

  -- =================================================================
  -- 8. Yakuniy sanoq
  -- =================================================================
  select count(*) into v_n from entry where ext_ref like 'aros_tr:TEST-IDEMP-%';
  v_rap := v_rap || '────────────────────────────────────────────────────────' || chr(10)
                 || '   Sinov yozuvlari jami: ' || v_n::text
                 || ' (1 + 1 + 2 = 4 kutiladi, click yo''q bo''lsa 2)' || chr(10);

  -- =================================================================
  -- 9. HISOBOT + MAJBURIY ROLLBACK
  -- =================================================================
  v_rap := v_rap || '════════════════════════════════════════════════════════' || chr(10)
        || case when v_xato = 0
                then 'NATIJA: ✅ HAMMASI TO''G''RI — transfer ikki marta yozilmaydi.'
                else 'NATIJA: ❌ ' || v_xato::text || ' ta XATO — yuqoridagi ❌/🔴 satrlarni o''qing. '
                     || 'SYNC''NI YOQMANG!' end
        || chr(10)
        || '(Bu "xato" ataylab: hamma sinov yozuvi ORQAGA QAYTARILDI, bazada iz yo''q.)'
        || chr(10);

  raise exception '%', v_rap;
end
$test$;


-- =====================================================================
--  SINOVDAN KEYIN: bazada haqiqatan iz qolmaganini tasdiqlash
-- ---------------------------------------------------------------------
--  ⚠️ Buni ALOHIDA RUN qiling (yuqoridagi blok xato bilan tugagani uchun
--     bitta skript ichida bu so'rovgacha yetib bormasligi mumkin).
--     Natija 0 bo'lishi SHART.
-- =====================================================================
select count(*) as qolgan_test_yozuvlari
  from entry
 where ext_ref like 'aros_tr:TEST-IDEMP-%';
-- 0 bo'lishi SHART. 0 bo'lmasa — menga ayting, qo'lda tozalaymiz:
--   delete from entry_line where entry_id in (select id from entry where ext_ref like 'aros_tr:TEST-IDEMP-%');
--   delete from entry where ext_ref like 'aros_tr:TEST-IDEMP-%';
