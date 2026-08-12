-- =====================================================================
--  PROVODKA_TRANSFER_TUZATISH.sql — delta "savdo minus" bo'lib yozilgan
--  transferlarni to'g'rilash
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  ⚠️ RPC ning DEFAULTI p_dry_run = TRUE. Ataylab: bu pul yozadigan
--     funksiya, tasodifan chaqirilib qolsa hech narsa yozilmasin.
--
--  #####  NIMA BO'LDI  #################################################
--
--  Transfer Sync workflow'ining Supabase kaliti placeholder edi
--  (SERVICE_KEY_SHU_YERGA -> 401), ya'ni transferlar HECH QACHON
--  yozilmagan. Filial markazga pul jo'natganda esa:
--     1. Aros'da filial balansi kamaydi
--     2. delta sync buni ko'rdi: delta < 0
--     3. va uni "savdo minus" deb yozdi:  Dt 9010 / Kt <filial tur child>
--  Misol: Malika click −18 mln "9010 savdo" — aslida Toshkentga transfer.
--
--  #####  HOZIR NIMA TO'G'RI, NIMA XATO  ###############################
--
--  Filial tomoni TO'G'RI: daftar Aros bilan teng (delta shuning uchun
--  endi 0 qaytaradi). Ya'ni filialdan pul chiqqani to'g'ri yozilgan.
--
--  XATO — faqat QARSHI TOMON:
--     • Toshkent markaziy kassa pulni OLMAGAN (0 turibdi)
--     • 9010 savdo tushumi transfer summasiga KAM ko'rsatilgan
--
--  Ya'ni ikkita hisob, aynan transfer summasiga xato. Balans buzilmagan
--  (Dt=Kt saqlangan), faqat tasnif noto'g'ri.
--
--  #####  YECHIM — TO'G'IRLOVCHI PROVODKA  #############################
--
--  Belgilar:  S = o'sha davrda tur bo'yicha savdo,  T = transfer summasi
--             delta = S − T   (delta sync aynan shuni yozgan)
--
--  Hozirgi holat (delta yozuvi):     child += delta,   9010 += delta
--  To'g'ri holat:                    child += delta,   9010 += S,
--                                    markaziy += T
--  Ayirma (to'g'ri − hozirgi):       child 0,  9010 += (S − delta) = T,
--                                    markaziy += T
--
--        ###  Dt <markaziy tur child>  /  Kt 9010  =  T  ###
--
--  Ya'ni FILIAL TOMONIGA UMUMAN TEGILMAYDI — u Aros bilan teng, tegish
--  sof xavf. Faqat yetishmayotgan ikki tomon yoziladi.
--
--  ⭐ MUHIM: bu formula savdo va transfer BIR SOATDA bo'lgan holatda ham
--     to'g'ri. Deltani "qancha savdo, qancha transfer" deb ajratish SHART
--     EMAS — faqat T ni bilish yetarli. Shuning uchun Aros ma'lumotidan
--     bizga kerak bo'ladigan yagona narsa — transfer summasi.
--
--  Nega eski yozuvni TAHRIRLAMAYMIZ yoki O'CHIRMAYMIZ:
--     • tahrir (9010 ni markaziyga almashtirish) faqat S = 0 bo'lganda
--       to'g'ri bo'lardi — savdo aralashgan soatda summa xato chiqadi;
--     • o'chirish esa filial daftarini Aros'dan ajratib yuboradi va
--       keyingi delta run o'sha "savdo minus"ni QAYTA yozadi (aylanma).
--     Ikkovi ham "pul ikki marta" xavfini tug'diradi. To'g'irlovchi
--     provodka esa qo'shimcha — hech narsani buzmaydi va kerak bo'lsa
--     oddiy soft-delete bilan qaytariladi.
--
--  #####  IKKI MARTA YOZILMASLIK — UCH QAVAT HIMOYA  ###################
--
--  1. ext_ref = 'aros_tr_fix:<transfer_id>:<tur>' — UNIQUE. Ikkinchi
--     marta chaqirilsa baza o'zi to'sadi (RPC oldindan ham tekshiradi).
--  2. Agar o'sha transfer uchun HAQIQIY transfer yozuvi bor bo'lsa
--     ('aros_tr:<id>:<tur>'), to'g'irlash YOZILMAYDI — demak transfer
--     sync uni to'g'ri yozib bo'lgan, delta uni yutmagan.
--  3. ⭐ CUTOFF: faqat received_at <= cutoff bo'lgan transfer to'g'rilanadi.
--     Sabab: cutoff = daftar Aros bilan oxirgi marta tenglashtirilgan payt
--     (aros_transfer_cutoff()). Undan OLDINGI transferni delta allaqachon
--     yutgan — to'g'irlash kerak. Undan KEYINGISINI esa transfer sync
--     o'zi normal yozadi — to'g'irlansa IKKI MARTA bo'lardi.
--     Shu sabab tuzatishni transfer sync bilan bir vaqtda ishlatish ham
--     xavfsiz: ikkovi bir-birining hududiga kirmaydi.
--
--  #####  JURNALDA QANDAY KO'RINADI  ###################################
--
--  Dt pul / Kt 9010 — ya'ni "Kirim" (yashil ↙) bo'lib chiqadi, "Transfer"
--  emas. Bu ataylab: yozuv transferning O'ZI emas, uning yetishmayotgan
--  yarmi. Izohda to'liq yozilgan, izlash uchun: description like
--  'To''g''irlash: transfer%'.
--
--  TALAB: PROVODKA_TRANSFER.sql (aros_kassa_topish, aros_tur_hisob,
--         aros_transfer_cutoff).
-- =====================================================================


-- ---------------------------------------------------------------------
--  KUTILADIGAN JSON — transfer sync bilan AYNI shakl
-- ---------------------------------------------------------------------
--  n8n "Aros Provodka - Transfer Sync" -> "Build Transfer Payload"
--  node'ining chiqishini o'zgartirmasdan shu yerga berish mumkin:
--
--    { "transferlar": [
--        { "id": 1234, "sender_title": "Malika", "receiver_title": "Toshkent Kassa",
--          "status": "received", "received_at": "2026-08-07T09:12:00",
--          "cash": 0, "click": 18000000, "payme": 0, "dollar": 0 }
--    ] }
--
--  (massiv ham bo'ladi). Kerakli maydonlar: id, receiver_title,
--  received_at va tur summalari. sender_title faqat izoh uchun.
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- D. DIAGNOSTIKA — avval shuni o'qing
-- ---------------------------------------------------------------------

-- D.1 ⭐ Gumondorlar: delta sync 9010 ga yozgan MANFIY yozuvlar
--     (Dt 9010 / Kt filial tur child = "savdo minus"). Aynan shular
--     transfer bo'lishi mumkin.
select e.id, e.created_at at time zone 'Asia/Tashkent' as vaqt,
       e.description,
       k.code as filial_kassa, k.name as filial,
       c.code as tur_hisob, coalesce(c.pul_turi, c.currency) as tur,
       l9.debit as sotuvdan_ayrildi
  from entry e
  join entry_line l9 on l9.entry_id = e.id and l9.debit > 0
  join accounts a9   on a9.id = l9.account_id and a9.code = '9010'
  join entry_line lc on lc.entry_id = e.id and lc.credit > 0
  join accounts c    on c.id = lc.account_id
  join accounts k    on k.id = c.parent_id
 where e.source = 'aros_auto' and e.created_by = 'aros_sync'
   and e.is_deleted = false
   and e.created_at >= current_date - 1
 order by e.created_at;

-- D.2 Cutoff qayerda turibdi (qaysi transferlar to'g'irlanadi, qaysilari yo'q)
select jsonb_pretty(aros_transfer_cutoff());

-- D.3 Toshkent markaziy kassaning turlari hozir nechada
select k.code as kassa, c.code as hisob,
       coalesce(c.pul_turi, c.currency) as tur,
       coalesce((select sum(l.debit - l.credit)
                   from entry_line l join entry e on e.id = l.entry_id
                  where l.account_id = c.id
                    and e.status = 'posted' and e.is_deleted = false), 0) as qoldiq
  from accounts k
  join accounts c on c.parent_id = k.id and c.is_active
 where k.code in ('5011','5012','5110')
 order by k.code, c.code;


-- ---------------------------------------------------------------------
-- 1. RPC
-- ---------------------------------------------------------------------
create or replace function transfer_tuzatish(p_data jsonb,
                                             p_dry_run boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_list    jsonb;
  v_el      jsonb;
  v_id      text;
  v_recv    text;
  v_send    text;
  v_rat     timestamptz;
  v_cut     timestamptz;
  v_kassa   jsonb;
  v_kid     uuid;
  v_kcode   text;
  v_9010    uuid;
  v_maydon  text;
  v_tur     text;
  v_amt     numeric;
  v_fc      numeric;
  v_rate    numeric;
  v_acc     uuid;
  v_ext     text;
  v_entry   uuid;
  n_yozuv   int := 0;
  n_otkaz   int := 0;
  v_ogoh    jsonb := '[]'::jsonb;
  v_tafsil  jsonb := '[]'::jsonb;
begin
  -- Transfer sync bilan bir vaqtda ishlab qolmasin
  perform pg_advisory_xact_lock(hashtext('sync_transfer_balans'));

  if p_data is null then
    return jsonb_build_object('ok', false, 'error', 'p_data bo''sh');
  end if;
  if jsonb_typeof(p_data) = 'object' and p_data ? 'transferlar' then
    v_list := p_data -> 'transferlar';
  else
    v_list := p_data;
  end if;
  if jsonb_typeof(v_list) <> 'array' then
    return jsonb_build_object('ok', false,
      'error', 'JSON massiv kutilgan edi (yoki {transferlar:[...]})');
  end if;

  select id into v_9010 from accounts where code = '9010' and is_active limit 1;
  if v_9010 is null then
    return jsonb_build_object('ok', false, 'error', '9010 hisobi topilmadi');
  end if;

  -- Cutoff — 3-qavat himoya (fayl boshidagi izohga qarang)
  v_cut := (aros_transfer_cutoff() ->> 'cutoff')::timestamptz;
  if v_cut is null then
    return jsonb_build_object('ok', false,
      'error', 'Cutoff topilmadi (delta sync hech qachon yozmagan). '
               'Bunday holatda delta hech narsani yutmagan — to''g''irlash kerak emas, '
               'transfer sync o''zi yozadi.');
  end if;

  for v_el in select * from jsonb_array_elements(v_list)
  loop
    v_id   := nullif(btrim(coalesce(v_el ->> 'id', '')), '');
    v_recv := nullif(btrim(coalesce(v_el ->> 'receiver_title', '')), '');
    v_send := coalesce(nullif(btrim(coalesce(v_el ->> 'sender_title', '')), ''), '?');
    v_rat  := nullif(v_el ->> 'received_at', '')::timestamptz;

    if v_id is null or v_recv is null then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object('id', v_id,
        'sabab', 'id yoki receiver_title yo''q');
      continue;
    end if;

    -- ⭐ CUTOFF: keyingi transferni transfer sync o'zi yozadi — tegmaymiz
    if v_rat is null then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object('id', v_id,
        'sabab', 'received_at yo''q — cutoff tekshirib bo''lmadi, xavfsizlik uchun tashlandi');
      continue;
    end if;
    if v_rat > v_cut then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object('id', v_id, 'received_at', v_rat,
        'cutoff', v_cut,
        'sabab', 'cutoff''dan KEYIN — delta uni yutmagan, transfer sync o''zi yozadi');
      continue;
    end if;

    -- Qabul qiluvchi (markaziy) kassa
    v_kassa := aros_kassa_topish(null, v_recv);
    if not coalesce((v_kassa ->> 'ok')::boolean, false) then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object('id', v_id, 'receiver', v_recv,
        'sabab', coalesce(v_kassa ->> 'sabab', 'qabul qiluvchi kassa topilmadi'));
      continue;
    end if;
    v_kid   := (v_kassa ->> 'id')::uuid;
    v_kcode := v_kassa ->> 'code';

    foreach v_maydon in array array['cash','click','payme','dollar']
    loop
      v_amt := coalesce(nullif(v_el ->> v_maydon, '')::numeric, 0);
      if v_amt <= 0 then continue; end if;

      v_tur := case v_maydon when 'cash' then 'naqd' else v_maydon end;
      v_ext := 'aros_tr_fix:' || v_id || ':' || v_tur;

      -- 1-himoya: shu to'g'irlash allaqachon yozilganmi
      if exists (select 1 from entry where ext_ref = v_ext) then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object('id', v_id, 'tur', v_tur,
          'sabab', 'allaqachon to''g''irlangan (ext_ref bor)');
        continue;
      end if;

      -- 2-himoya: haqiqiy transfer yozuvi bormi -> delta uni yutmagan
      if exists (select 1 from entry
                  where ext_ref = 'aros_tr:' || v_id || ':' || v_tur) then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object('id', v_id, 'tur', v_tur,
          'sabab', 'transfer sync buni to''g''ri yozgan — to''g''irlash kerak emas');
        continue;
      end if;

      -- Dt: markaziy kassaning shu tur child'i
      v_acc := aros_tur_hisob(v_kid, v_maydon);
      if v_acc is null then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object('id', v_id, 'tur', v_tur,
          'kassa', v_kcode,
          'sabab', 'markaziy kassada "' || v_tur || '" tur hisobi yo''q');
        continue;
      end if;

      -- Dollar: summa VALYUTADA keladi, so'm ekvivalenti kurs orqali
      v_fc   := null;
      v_rate := null;
      if v_maydon = 'dollar' then
        v_rate := nullif(v_el ->> 'dollar_rate', '')::numeric;
        if v_rate is null or v_rate <= 0 then
          n_otkaz := n_otkaz + 1;
          v_ogoh := v_ogoh || jsonb_build_object('id', v_id, 'tur', v_tur,
            'sabab', 'dollar_rate yo''q — so''m ekvivalentini hisoblab bo''lmaydi');
          continue;
        end if;
        v_fc  := v_amt;
        v_amt := round(v_amt * v_rate, 2);
      end if;

      v_tafsil := v_tafsil || jsonb_build_object(
        'transfer_id', v_id, 'kimdan', v_send, 'kimga', v_kcode,
        'tur', v_tur, 'summa_uzs', v_amt, 'fc', v_fc,
        'received_at', v_rat, 'hisob', v_acc, 'ext_ref', v_ext);

      if p_dry_run then
        n_yozuv := n_yozuv + 1;
        continue;
      end if;

      insert into entry(entry_date, description, source, status, created_by,
                        fc_rate, ext_ref)
      values (coalesce(v_rat::date, current_date),
              'To''g''irlash: transfer ' || v_send || ' → ' || v_recv
                || ' · ' || v_tur || ' (delta sync uni 9010 savdoga yozib yuborgan)',
              'aros_auto', 'posted', 'transfer_fix', v_rate, v_ext)
      returning id into v_entry;

      -- Dt markaziy tur child / Kt 9010.  Filial tomoniga TEGILMAYDI.
      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, v_acc, v_amt, 0, v_fc);
      insert into entry_line(entry_id, account_id, debit, credit)
      values (v_entry, v_9010, 0, v_amt);

      n_yozuv := n_yozuv + 1;
    end loop;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'cutoff', v_cut,
    'yozuvlar', n_yozuv,
    'otkazildi', n_otkaz,
    'ogohlantirishlar', v_ogoh,
    'tafsilot', v_tafsil);
end $$;

revoke all on function transfer_tuzatish(jsonb, boolean) from public, anon, authenticated;
grant execute on function transfer_tuzatish(jsonb, boolean) to service_role;

comment on function transfer_tuzatish(jsonb, boolean) is
  'Delta sync 9010 ga yozib yuborgan transferlarni to''g''irlaydi: '
  'Dt markaziy tur child / Kt 9010 = transfer summasi. Filial tomoniga tegmaydi. '
  'Faqat cutoff''dan OLDINGI transferlar. ext_ref bilan takrorlanmaydi. service_role only.';


-- ---------------------------------------------------------------------
-- 2. ISHLATISH TARTIBI
-- ---------------------------------------------------------------------
-- 2.1 QURUQ YUGURISH (default) — hech narsa yozmaydi, nima bo'lishini ko'rsatadi.
--     JSON'ni n8n "Build Transfer Payload" node'idan oling (Transfer Sync
--     workflow'ini bir marta ishga tushirib, o'sha node chiqishini nusxalang).
-- select jsonb_pretty(transfer_tuzatish('{"transferlar":[
--   {"id":1234,"sender_title":"Malika","receiver_title":"Toshkent Kassa",
--    "received_at":"2026-08-07T09:12:00","cash":0,"click":18000000,"payme":0,"dollar":0}
-- ]}'::jsonb));
--
--     `tafsilot` ni O'QING: har qator uchun summa va qaysi hisobga
--     tushishi ko'rsatiladi. `ogohlantirishlar` da nima uchun o'tkazib
--     yuborilgani yozilgan (eng ko'p uchraydigani: "cutoff'dan KEYIN").

-- 2.2 HAQIQIY YOZUV — dry_run'ni ochiq false qilib:
-- select jsonb_pretty(transfer_tuzatish('{"transferlar":[ ... ]}'::jsonb, false));


-- ---------------------------------------------------------------------
-- 3. TEKSHIRUV (yozgandan keyin)
-- ---------------------------------------------------------------------

-- 3.1 To'g'irlash yozuvlari
select e.entry_date, e.description, e.ext_ref,
       a.code, a.name, l.debit, l.credit, l.fc_amount
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a on a.id = l.account_id
 where e.created_by = 'transfer_fix' and e.is_deleted = false
 order by e.created_at desc, l.debit desc;

-- 3.2 ⭐ Toshkent kassa endi pul ko'rdimi (D.3 bilan solishtiring)
select k.code as kassa, c.code as hisob,
       coalesce(c.pul_turi, c.currency) as tur,
       coalesce((select sum(l.debit - l.credit)
                   from entry_line l join entry e on e.id = l.entry_id
                  where l.account_id = c.id
                    and e.status = 'posted' and e.is_deleted = false), 0) as qoldiq
  from accounts k
  join accounts c on c.parent_id = k.id and c.is_active
 where k.code in ('5011','5012','5110')
 order by k.code, c.code;

-- 3.3 ⭐ FILIAL TOMONI O'ZGARMAGANINI tasdiqlash — eng muhim tekshiruv.
--     To'g'irlash filialga TEGMASLIGI kerak, ya'ni keyingi delta sync
--     baribir 0 qaytarishi shart. Shuni quruq yugurish bilan tekshiring:
--     sync_filial_balans(<o'sha payload>, true) -> "yozuvlar": 0
--     (Aros balansi shu orada o'zgargan bo'lsa farq bo'lishi tabiiy.)

-- 3.4 Balans tenglikda qoldimi
select sum(case when bolim = 'AKTIV' then amount else 0 end)
     - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end) as farq
  from balans(current_date);
-- farq = 0 bo'lishi SHART.

-- 3.5 Xato bo'lsa QAYTARISH: to'g'irlash oddiy yozuv — soft-delete yetadi.
-- update entry set is_deleted = true, deleted_at = now(),
--        deleted_by_name = 'tuzatish qaytarildi'
--  where created_by = 'transfer_fix' and is_deleted = false;
