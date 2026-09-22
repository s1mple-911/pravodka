-- =====================================================================
--  PROVODKA_QR_TUR.sql   (2026-09-22, Asilbek)
--  Aros «qr_code» to'lov turi -> Provodkada `qr` tur bola-hisobi
-- ---------------------------------------------------------------------
--  ## SABAB
--  Aros adminka yangilanishida transfer/balans hujjatiga yana bir to'lov
--  turi qo'shildi:
--      items[].document.amounts[].label_code =
--          cash_balance | click_balance | dollar_balance | terminal | qr_code
--      cachier detail balances[].label.code = ... | qr_code
--  label_title «QR code», currency UZS. Provodkada `qr` tur-hisobi yo'q
--  edi — "no silent zero" himoyasi ikkita workflow'ni to'xtatdi:
--    «Aros Provodka - Transfer Sync v2» (iqtB5Jk2NHW2r82J)
--    «Aros Provodka - Yolda Sync» (xRARQu9MiZmQ1sAO)
--  «Aros Provodka - Balans Sync» ham (label MAP'da yo'q bo'lsa) xuddi
--  shu sababdan to'xtaydi.
--
--  ## NAQSH — 2026-09-09/12 «terminal» rollovutidan AYNAN ko'chirilgan
--  (PROVODKA_TERMINAL_TUR.sql, PROVODKA_TURLAR_AVTO.sql, PROVODKA_YOLDA_TERMINAL.sql,
--   PROVODKA_BALANS_TERMINAL.sql). `qr` — terminal bilan bir xil turdagi
--   "pul turi bola-hisobi": faqat markaziy/filial (yuqori daraja) so'm
--   kassalariga ochiladi, transfer/balans/yo'lda sinxronlarida terminal
--   bilan qatorma-qator qo'shiladi.
--
--  ## QAMROV
--  `qr` bola-hisobi terminal AVVAL ochilgan kassalarga ochiladi (bir xil
--  kassa to'plami) — `qr_tur_toldir()` shartida `c.pul_turi = 'terminal'`
--  borligini tekshiradi (terminal_tur_toldir() 'payme' borligini tekshirgan
--  edi). Hodim kassalari (5400 ostidagi) sukut bo'yicha TEGILMAYDI.
--
--  ## QOIDALAR (CLAUDE.md)
--   * ADDITIVE: imzosi o'zgarmagan funksiyalar `create or replace` bilan —
--     tanasi VERBATIM ko'chirilib, faqat `qr` qatori qo'shildi.
--   * anonim `do` bloki YO'Q — har bir `do` va funksiya tanasi nomlangan
--     dollar-teg bilan. Izohlarda ketma-ket dollar belgisi yozilmagan.
--   * idempotent: qayta RUN qilinsa ham xato bermaydi, ikki marta yozmaydi.
--
--  ## FAYL TARKIBI
--     0-BO'LIM — old shart tekshiruvi
--     1-BO'LIM — accounts_pul_turi_chk: 'qr' qo'shiladi
--     2-BO'LIM — _pul_turi_child_ich: 'qr' -> 'QR' yorlig'i
--     3-BO'LIM — qr_tur_toldir(): terminal bilan bir xil kassalarga 'qr' ochadi
--     4-BO'LIM — aros_tur_hisob: 'qr' / 'qr_code' ni taniydi
--     5-BO'LIM — sync_transfer_balans: 'qr' turini yozadi (Transfer Sync v2)
--     6-BO'LIM — v_filial_sync_mapping + sync_filial_balans: 'qr' (Balans Sync)
--     7-BO'LIM — aros_transfer_yolda + sync_transfer_yolda/yolda_royxat/yolda_farq:
--                s_qr/c_qr (Yolda Sync — pul harakati YO'Q, faqat registr)
--     8-BO'LIM — PostgREST sxema keshini yangilash
--     9-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/raise)
--
--  🔴 SQL'ni ASILBEK o'zi RUN qiladi. RUN tartibi: bu fayl TO'LIQ birinchi,
--     keyin `N8N_TRANSFER_SYNC_V2_QR.md` dagi ikki node, keyin n8n
--     workflow'larini qayta faollashtirish/qo'lda ishga tushirish.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (faqat select/exception)        ##
-- #####################################################################

do $qr_pre$
begin
  if to_regprocedure('public._pul_turi_child_ich(uuid,text)') is null then
    raise exception '_pul_turi_child_ich yoq — avval PROVODKA_TURLAR_AVTO.sql ni bajaring';
  end if;
  if to_regprocedure('public.aros_tur_hisob(uuid,text)') is null then
    raise exception 'aros_tur_hisob yoq — avval PROVODKA_TRANSFER.sql / PROVODKA_TERMINAL_TUR.sql ni bajaring';
  end if;
  if to_regprocedure('public.sync_transfer_balans(jsonb,boolean,timestamptz)') is null then
    raise exception 'sync_transfer_balans yoq — avval PROVODKA_TRANSFER_CUTOFF_FIX.sql / PROVODKA_TERMINAL_TUR.sql ni bajaring';
  end if;
  if to_regclass('public.v_filial_sync_mapping') is null then
    raise exception 'v_filial_sync_mapping yoq — avval PROVODKA_BALANS_TERMINAL.sql ni bajaring';
  end if;
  if to_regprocedure('public.sync_filial_balans(jsonb,boolean)') is null then
    raise exception 'sync_filial_balans yoq — avval PROVODKA_BALANS_TERMINAL.sql ni bajaring';
  end if;
  if to_regclass('public.aros_transfer_yolda') is null then
    raise exception 'aros_transfer_yolda jadvali yoq — avval PROVODKA_YOLDA.sql ni bajaring';
  end if;
  if to_regprocedure('public.sync_transfer_yolda(jsonb)') is null then
    raise exception 'sync_transfer_yolda(jsonb) yoq — avval PROVODKA_YOLDA.sql / PROVODKA_YOLDA_TERMINAL.sql ni bajaring';
  end if;
  if to_regprocedure('public.yolda_royxat()') is null then
    raise exception 'yolda_royxat() yoq — avval PROVODKA_YOLDA.sql / PROVODKA_YOLDA_TERMINAL.sql ni bajaring';
  end if;
  if to_regprocedure('public.yolda_farq(text[])') is null then
    raise exception 'yolda_farq(text[]) yoq — avval PROVODKA_YOLDA.sql / PROVODKA_YOLDA_TERMINAL.sql ni bajaring';
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'accounts_pul_turi_chk'
                    and pg_get_constraintdef(oid) like '%terminal%') then
    raise exception 'accounts_pul_turi_chk da terminal yoq — avval PROVODKA_TERMINAL_TUR.sql ni bajaring '
                     '(qr terminal bilan bir xil kassa to''plamiga ochiladi)';
  end if;
end
$qr_pre$;


-- #####################################################################
-- ##  1-BO'LIM — accounts_pul_turi_chk: 'qr' qo'shiladi                ##
-- #####################################################################
-- Naqsh PROVODKA_TURLAR_AVTO.sql `turlar_avto_chk_yangila()` bilan bir xil:
-- avval bazada ro'yxatdan tashqari qiymat yo'qligini tekshiramiz, keyin
-- drop+add (CHECK'ni "kengaytirish" boshqa yo'l bilan bo'lmaydi). Eski
-- qiymatlar (naqd/click/payme/karta/terminal/plastik) joyida qoladi —
-- bu FAQAT kengaytirish, hech narsa toraymaydi. Idempotent: qayta RUN
-- qilinsa xuddi shu ro'yxat bilan qayta o'rnatiladi, xato bermaydi.

create or replace function qr_tur_chk_yangila()
returns text
language plpgsql
as $qr_chk$
declare v_notanish text;
begin
  select string_agg(distinct pul_turi, ', ')
    into v_notanish
    from accounts
   where pul_turi is not null
     and pul_turi not in ('naqd','click','payme','karta','terminal','plastik','qr');

  if v_notanish is not null then
    raise exception
      'accounts.pul_turi da ro''yxatdan TASHQARI qiymat(lar) bor: %. Eski cheklov TEGILMADI. '
      'Yo o''sha qatorlarni to''g''irlang, yo quyidagi ro''yxatga (bu funksiya + _pul_turi_child_ich '
      'dagi v_lbl case) o''sha turni qo''shing.',
      v_notanish;
  end if;

  if exists (select 1 from pg_constraint
              where conname = 'accounts_pul_turi_chk'
                and conrelid = 'public.accounts'::regclass) then
    alter table accounts drop constraint accounts_pul_turi_chk;
  end if;
  alter table accounts add constraint accounts_pul_turi_chk
    check (pul_turi is null
           or pul_turi in ('naqd','click','payme','karta','terminal','plastik','qr'));

  return '✅ OK — accounts_pul_turi_chk yangilandi (naqd|click|payme|karta|terminal|plastik|qr)';
end $qr_chk$;

revoke all on function qr_tur_chk_yangila() from public, anon, authenticated;

comment on function qr_tur_chk_yangila() is
  'accounts_pul_turi_chk ni ''qr'' bilan qayta o''rnatadi. Ro''yxatdan tashqari '
  'qiymat bo''lsa hech narsaga tegmay xato beradi (PROVODKA_QR_TUR.sql).';

select qr_tur_chk_yangila() as natija;

comment on column accounts.pul_turi is
  'Pul turi bola-hisobi: naqd|click|payme|karta|terminal|plastik|qr. '
  'NULL = oddiy kassa yoki valyuta bolasi.';


-- #####################################################################
-- ##  2-BO'LIM — _pul_turi_child_ich: 'qr' -> 'QR' yorlig'i            ##
-- #####################################################################
-- 🔴 PROVODKA_TURLAR_AVTO.sql (549-694) dagi tananing VERBATIM nusxasi.
--    Yagona farq: v_lbl case'iga `when 'qr' then 'QR'` qo'shildi va xato
--    xabaridagi ro'yxatga 'qr' qo'shildi. Imzo/RETURNS o'zgarmagan.

create or replace function _pul_turi_child_ich(p_parent uuid, p_turi text)
returns uuid
language plpgsql
security definer
set search_path = public
as $qr_pti$
declare
  v_parent accounts%rowtype;
  v_turi   text := lower(btrim(coalesce(p_turi, '')));
  v_lbl    text;
  v_prefix text;
  v_uzun   int;
  v_next   int;
  v_code   text;
  v_id     uuid;
begin
  -- Turlar va yorliqlari — hodim-dev.html TURI_LBL bilan AYNAN mos
  v_lbl := case v_turi
             when 'naqd'     then 'Naqd'
             when 'click'    then 'Click'
             when 'payme'    then 'Payme'
             when 'karta'    then 'Karta'
             when 'terminal' then 'Terminal'
             when 'plastik'  then 'Plastik'
             when 'qr'       then 'QR'
           end;
  if v_lbl is null then
    raise exception 'Pul turi noto''g''ri: % (naqd|click|payme|karta|terminal|plastik|qr)', p_turi;
  end if;

  select * into v_parent from accounts where id = p_parent;
  if not found then
    raise exception 'Kassa topilmadi: %', p_parent;
  end if;
  if v_parent.section is distinct from 'pul' or coalesce(v_parent.currency,'UZS') <> 'UZS' then
    raise exception 'Tur hisobi faqat so''m kassasiga qo''shiladi (%)', v_parent.code;
  end if;
  if not v_parent.is_active then
    raise exception 'Kassa faol emas: %', v_parent.code;
  end if;
  -- Konteyner guruh (5400) — unga to'g'ridan pul yozilmaydi
  if v_parent.kassa_turi = 'xarajat_guruh' then
    raise exception 'Guruh hisobiga tur qo''shib bo''lmaydi (%)', v_parent.code;
  end if;
  -- Bola-hisobning o'zi ota bo'lolmaydi (ikki qavat bo'lmasin).
  if v_parent.pul_turi is not null then
    raise exception 'Tur bola-hisobiga tur qo''shib bo''lmaydi (%)', v_parent.code;
  end if;

  -- idempotent: shu turdagi faol bola bor bo'lsa — o'shani qaytaramiz
  select id into v_id
    from accounts
   where parent_id = p_parent and pul_turi = v_turi and is_active = true
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  -- QAYTA YOQISH: `pul_turi_ochir` bilan yopilgan (is_active=false) shu
  -- turdagi bola bo'lsa — YANGI kod ochmaymiz, eskisini tiklaymiz.
  select id into v_id
    from accounts
   where parent_id = p_parent and pul_turi = v_turi
     and coalesce(is_active, true) = false
   order by code
   limit 1;
  if v_id is not null then
    update accounts
       set is_active = true,
           name      = v_parent.name || ' · ' || v_lbl,
           subtitle  = v_parent.subtitle
     where id = v_id;
    return v_id;
  end if;

  -- Kod: bo'sh joyi bor birinchi blok (nav tartibida). Blokdagi eng katta
  -- kod + 1; faol bo'lmagan eski hisoblar ham hisobga olinadi (kod unique).
  for i in 1..5 loop
    select b.prefix, b.raqam_uzunlik, coalesce(mx.n, 0) + 1
      into v_prefix, v_uzun, v_next
      from pul_turi_kod_blok b
      left join lateral (
        select max(substring(a.code from 3)::int) as n
          from accounts a
         where a.code ~ ('^' || b.prefix || '[0-9]{' || b.raqam_uzunlik::text || '}$')
      ) mx on true
     where coalesce(mx.n, 0) + 1 <= (power(10, b.raqam_uzunlik)::int - 1)
     order by b.nav
     limit 1;

    if v_prefix is null then
      raise exception 'Tur kod bloklari to''ldi. pul_turi_kod_blok''ga yangi blok qo''shing (masalan prefix=51, raqam_uzunlik=3 — bo''sh nav raqami bilan).';
    end if;
    v_code := v_prefix || lpad(v_next::text, v_uzun, '0');

    begin
      insert into accounts(code, name, type, section, currency, parent_id,
                           kassa_turi, is_active, subtitle, pul_turi)
      values (v_code,
              v_parent.name || ' · ' || v_lbl,
              'aktiv', 'pul', 'UZS', p_parent,
              v_parent.kassa_turi, true, v_parent.subtitle, v_turi)
      returning id into v_id;
      return v_id;
    exception when unique_violation then
      select id into v_id
        from accounts
       where parent_id = p_parent and pul_turi = v_turi and is_active = true
       limit 1;
      if v_id is not null then
        return v_id;
      end if;
    end;
  end loop;

  raise exception 'Tur hisobiga bo''sh kod topilmadi (5 urinish): % / %', v_parent.code, v_turi;
end $qr_pti$;

revoke all on function _pul_turi_child_ich(uuid, text) from public, anon, authenticated;

comment on function _pul_turi_child_ich(uuid, text) is
  'ICHKI: kassaga pul turi bola-hisobini ochadi. RUXSAT TEKSHIRMAYDI — '
  'faqat create_pul_turi_child va accounts triggeri chaqiradi. authenticated ga berilmagan. '
  'YANGI (PROVODKA_QR_TUR.sql): ''qr'' -> ''QR'' yorlig''i qo''shildi.';


-- #####################################################################
-- ##  3-BO'LIM — qr_tur_toldir() — terminal bilan bir xil kassalarga  ##
-- ##             'qr' bola-hisobini ochadi                            ##
-- #####################################################################
-- terminal_tur_toldir() (PROVODKA_TERMINAL_TUR.sql) naqshining AYNAN nusxasi.
-- Yagona farq: eligibility sharti `c.pul_turi = 'payme'` o'rniga
-- `c.pul_turi = 'terminal'` — ya'ni "qr" terminal AVVAL ochilgan bo'lgan
-- xuddi shu kassa to'plamiga ochiladi (topshiriqda talab qilingan).

-- ⬇⬇⬇  PREVIEW — hech narsa yozmaydi
select a.code, a.name, a.kassa_turi,
       exists (select 1 from accounts c
                where c.parent_id = a.id and c.pul_turi = 'qr') as qr_bor
  from accounts a
 where a.section = 'pul'
   and a.parent_id is null
   and coalesce(a.currency, 'UZS') = 'UZS'
   and coalesce(a.is_active, true)
   and a.kassa_turi is distinct from 'xarajat_guruh'
   and exists (select 1 from accounts c
                where c.parent_id = a.id and c.pul_turi = 'terminal')
 order by a.code;
-- ⬆⬆⬆
--  `qr_bor = false` qatorlarga quyidagi funksiya bola-hisob ochadi.

create or replace function qr_tur_toldir(p_hammasi boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $qr_toldir$
declare
  r        record;
  v_id     uuid;
  v_yangi  jsonb := '[]'::jsonb;
  v_bor    jsonb := '[]'::jsonb;
begin
  for r in
    select a.id, a.code, a.name
      from accounts a
     where a.section = 'pul'
       and coalesce(a.currency, 'UZS') = 'UZS'
       and coalesce(a.is_active, true)
       and a.pul_turi is null                        -- bola-hisobning o'zi emas
       and a.kassa_turi is distinct from 'xarajat_guruh'
       and (p_hammasi or a.parent_id is null)        -- sukut: faqat yuqori daraja
       and exists (select 1 from accounts c
                    where c.parent_id = a.id and c.pul_turi = 'terminal')
     order by a.code
  loop
    if exists (select 1 from accounts c
                where c.parent_id = r.id and c.pul_turi = 'qr') then
      v_bor := v_bor || jsonb_build_object('code', r.code, 'nom', r.name);
    else
      v_id := _pul_turi_child_ich(r.id, 'qr');
      v_yangi := v_yangi || jsonb_build_object('code', r.code, 'nom', r.name, 'child_id', v_id);
    end if;
  end loop;

  return jsonb_build_object('ok', true,
                            'yaratildi', jsonb_array_length(v_yangi),
                            'bor_edi',   jsonb_array_length(v_bor),
                            'yangi',     v_yangi,
                            'bor',       v_bor);
end $qr_toldir$;

revoke all on function qr_tur_toldir(boolean) from public, anon;
grant execute on function qr_tur_toldir(boolean) to authenticated;

comment on function qr_tur_toldir(boolean) is
  'Terminal AVVAL ochilgan kassalarga «QR» tur bola-hisobini ochadi (idempotent). '
  'Sukut: faqat yuqori darajadagi kassalar (markaziy + filial). p_hammasi=true -> hodim '
  'kassalari ham. Aros 2026-09-22 yangilanishida ''qr_code'' to''lov turi paydo bo''ldi.';

-- ⬇⬇⬇  ISHGA TUSHIRISH (yuqoridagi PREVIEW ro'yxatini ko'rgach)
select jsonb_pretty(qr_tur_toldir());
-- ⬆⬆⬆


-- #####################################################################
-- ##  4-BO'LIM — aros_tur_hisob: 'qr' / 'qr_code' ni taniydi           ##
-- #####################################################################
-- 🔴 PROVODKA_TERMINAL_TUR.sql (141-161) dagi tananing VERBATIM nusxasi.
--    Yagona farq: birinchi shoxdagi tur ro'yxatiga 'qr' va 'qr_code'
--    qo'shildi, va pul_turi tanlash case'iga `qr_code -> qr` sinonimi
--    qo'shildi (boshqa kalitlar o'zicha ishlaydi — `else p_maydon`).

create or replace function aros_tur_hisob(p_kassa uuid, p_maydon text)
returns uuid
language sql
stable
as $qr_tur_hisob$
  select c.id
    from accounts c
    join accounts k on k.id = c.parent_id
   where c.parent_id = p_kassa
     and c.is_active and c.section = 'pul'
     and k.is_active and k.section = 'pul' and k.parent_id is null
     and (
           ( p_maydon in ('cash','naqd','click','payme','karta','terminal','plastik','qr','qr_code')
             and c.pul_turi = case p_maydon
                                when 'cash'    then 'naqd'
                                when 'qr_code' then 'qr'
                                else p_maydon
                              end
             and coalesce(c.currency, 'UZS') = 'UZS' )
        or ( p_maydon in ('dollar_usd','dollar','usd')
             and c.currency = 'USD' )
         )
   order by c.code
   limit 1;
$qr_tur_hisob$;

revoke all on function aros_tur_hisob(uuid, text) from public, anon;
grant execute on function aros_tur_hisob(uuid, text) to authenticated, service_role;

comment on function aros_tur_hisob(uuid, text) is
  'Kassaning tur child hisobi: cash|naqd|click|payme|karta|terminal|plastik|qr -> pul_turi, '
  'dollar_usd -> currency=USD. Transfer sync shu bilan Dt/Kt hisoblarini topadi. '
  'YANGI (PROVODKA_QR_TUR.sql): qr/qr_code qo''shildi (qr_code -> qr sinonim).';


-- #####################################################################
-- ##  5-BO'LIM — sync_transfer_balans: 'qr' turini yozadi              ##
-- #####################################################################
--  Eng oxirgi mavjud imzo (grep bo'yicha eng yangi ta'rif): PROVODKA_TERMINAL_TUR.sql
--  (2026-09-09). Bu bo'lim shu tananing VERBATIM nusxasi — FAQAT ikkita farq:
--    a) tur ro'yxatiga (`foreach v_maydon in array ...`) 'qr' qo'shildi;
--    b) summa o'qishga `when 'qr' then ...` shoxi qo'shildi.
--  🔴 v_lbl case'i ATAYLAB tegilmagan (u faqat cash/click/payme ni ajratadi,
--     qolgan hamma turda 'USD' qaytaradi — bu eski, terminal ham shu holatda
--     qoldirilgan edi; qamrovdan tashqari, alohida tuzatiladi).
--
--  ⚠️ TARTIB: bu bo'lim 2/3/4-BO'LIM (bola-hisoblar + aros_tur_hisob) dan
--     KEYIN bajarilishi shart — aks holda RPC qr hisobini topolmay
--     «hisob yo'q» deb ogohlantiradi.

create or replace function sync_transfer_balans(p_data jsonb,
                                               p_dry_run boolean default false,
                                               p_from timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $qr_stb$
declare
  v_list        jsonb;
  v_el          jsonb;

  v_cutoff      timestamptz;
  v_cutoff_man  text;
  v_cut_info    jsonb;

  v_tr_id       text;
  v_status      text;
  v_txt         text;
  v_recv        timestamptz;
  v_sana        date;

  v_send_res    jsonb;
  v_recv_res    jsonb;
  v_send_id     uuid;
  v_recv_id     uuid;
  v_send_nom    text;
  v_recv_nom    text;
  v_recv_turi   text;

  v_maydon      text;
  v_lbl         text;
  v_amt         numeric;
  v_rate        numeric;
  v_baza_rate   numeric;
  v_tr_rate     numeric;
  v_kurs_manba  text;

  v_dt          uuid;
  v_kt          uuid;
  v_summa       numeric;
  v_fc          numeric;
  v_ext         text;
  v_entry       uuid;
  v_fix_ext     text;
  v_natija      jsonb;

  n_jami        int := 0;
  n_yozuv       int := 0;
  n_takror      int := 0;
  n_otkaz       int := 0;
  n_status      int := 0;
  n_eski        int := 0;
  v_ogoh        jsonb := '[]'::jsonb;
  v_tafsil      jsonb := '[]'::jsonb;
  v_eski_ruy    jsonb := '[]'::jsonb;
  n_fix         int := 0;
begin
  -- ---- 0. Qulflar ---------------------------------------------------
  perform pg_advisory_xact_lock(hashtext('sync_filial_balans'));
  perform pg_advisory_xact_lock(hashtext('sync_transfer_balans'));

  -- ---- 1. Kirishni normallashtirish ---------------------------------
  if p_data is null then
    return jsonb_build_object('ok', false, 'error', 'p_data bo''sh');
  end if;

  if jsonb_typeof(p_data) = 'object' and p_data ? 'transferlar' then
    v_list := p_data -> 'transferlar';
  elsif jsonb_typeof(p_data) = 'object' and p_data ? 'transfers' then
    v_list := p_data -> 'transfers';
  elsif jsonb_typeof(p_data) = 'object' and p_data ? 'results' then
    v_list := p_data -> 'results';          -- Aros API sahifalangan javobi
  else
    v_list := p_data;
  end if;

  if jsonb_typeof(v_list) <> 'array' then
    return jsonb_build_object('ok', false,
      'error', 'JSON massiv kutilgan edi (yoki {transferlar:[...]}), keldi: '
               || jsonb_typeof(v_list));
  end if;

  -- ---- 2. CUTOFF ----------------------------------------------------
  v_cut_info   := aros_transfer_cutoff(p_from);
  v_cutoff     := nullif(v_cut_info ->> 'cutoff', '')::timestamptz;
  v_cutoff_man := v_cut_info ->> 'manba';

  if v_cutoff is null and not p_dry_run then
    return jsonb_build_object('ok', false,
      'error', 'CUTOFF topilmadi — hech narsa yozilmadi. Chegara "daftar Aros bilan '
               || 'oxirgi marta qachon tenglashtirilgan" degani; usiz eski transferni '
               || 'yozish pulni IKKI MARTA ayirib yuboradi. Delta sync (sync_filial_balans) '
               || 'hech qachon ishlamaganga o''xshaydi — avval uni ishlating, '
               || 'yoki p_from ni aniq bering.',
      'cutoff_info', v_cut_info,
      'maslahat', 'select sync_transfer_balans(''[...]''::jsonb, false, ''2026-07-31T12:00:00+05'')');
  end if;

  if coalesce((v_cut_info ->> 'p_from_ishlatilmadi')::boolean, false) then
    v_ogoh := v_ogoh || jsonb_build_object(
      'p_from', p_from,
      'sabab', 'p_from chegaradan OLDIN — e''tiborsiz qoldirildi. Cutoff faqat '
               || 'qattiqlashtirilishi mumkin (kechroq sana). Ishlatilgan cutoff: '
               || coalesce(v_cutoff::text, '(yo''q)'));
  end if;

  -- ---- 3. Zaxira dollar kursi ---------------------------------------
  if to_regprocedure('public.conv_baza_kurs(text)') is not null then
    begin
      execute 'select conv_baza_kurs($1)' into v_baza_rate using 'USD';
    exception when others then
      v_baza_rate := null;
    end;
  end if;

  -- ---- 4. Har transfer ----------------------------------------------
  for v_el in select * from jsonb_array_elements(v_list)
  loop
    n_jami := n_jami + 1;

    -- 4.1 id (majburiy — takrorlanmaslik shunga tayanadi)
    v_tr_id := nullif(btrim(coalesce(v_el ->> 'id', v_el ->> 'transfer_id', '')), '');
    if v_tr_id is null then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', null, 'sabab', 'transfer id yo''q — ext_ref yasab bo''lmaydi');
      continue;
    end if;

    -- 4.2 status: faqat 'received' yoziladi
    v_status := lower(btrim(coalesce(nullif(v_el ->> 'status', ''), 'received')));
    if v_status <> 'received' then
      n_status := n_status + 1;
      continue;
    end if;

    -- 4.3 received_at (majburiy — cutoff shunga qarab ishlaydi)
    v_txt := nullif(btrim(coalesce(v_el ->> 'received_at',
                                   v_el ->> 'received_datetime', '')), '');
    v_recv := null;
    if v_txt is not null then
      if v_txt ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_txt := v_txt || 'T00:00:00+05';
      elsif v_txt !~ '([Zz]|[+-][0-9]{2}:[0-9]{2}|[+-][0-9]{4}|:[0-9]{2}(\.[0-9]+)?[+-][0-9]{2})$' then
        v_txt := v_txt || '+05';
      end if;
      begin
        v_recv := v_txt::timestamptz;
      exception when others then
        v_recv := null;
      end;
    end if;

    if v_recv is null then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', v_tr_id,
        'sabab', 'received_at yo''q yoki o''qib bo''lmadi — cutoff tekshirib bo''lmaydi, '
                 || 'yozilmadi (received_at: ' || coalesce(v_el ->> 'received_at', '(yo''q)') || ')');
      continue;
    end if;

    -- 4.4 CUTOFF: daftarga allaqachon singib ketgan transferlar
    if v_cutoff is not null and v_recv <= v_cutoff then
      n_eski := n_eski + 1;
      if jsonb_array_length(v_eski_ruy) < 500 then
        v_eski_ruy := v_eski_ruy || jsonb_build_object(
          'transfer', v_tr_id,
          'received_at', v_recv,
          'kimdan', coalesce(v_el ->> 'sender_title', v_el ->> 'sender'),
          'kimga', coalesce(v_el ->> 'receiver_title', v_el ->> 'receiver'),
          'cutoff', v_cutoff,
          'sabab', 'received_at <= cutoff (' || coalesce(v_cutoff_man, '?') || ')');
      end if;
      continue;
    end if;

    -- 4.5 Tomonlarni bog'lash
    v_send_res := aros_kassa_topish(v_el ->> 'sender_id',
                                    coalesce(v_el ->> 'sender_title', v_el ->> 'sender'));
    if not (v_send_res ->> 'ok')::boolean then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', v_tr_id, 'tomon', 'sender',
        'sabab', v_send_res ->> 'sabab');
      continue;
    end if;

    v_recv_res := aros_kassa_topish(v_el ->> 'receiver_id',
                                    coalesce(v_el ->> 'receiver_title', v_el ->> 'receiver'));
    if not (v_recv_res ->> 'ok')::boolean then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', v_tr_id, 'tomon', 'receiver',
        'sabab', v_recv_res ->> 'sabab',
        'markaziy_kassalar', v_recv_res -> 'markaziy_kassalar');
      continue;
    end if;

    v_send_id  := (v_send_res ->> 'id')::uuid;
    v_recv_id  := (v_recv_res ->> 'id')::uuid;
    v_send_nom := v_send_res ->> 'name';
    v_recv_nom := v_recv_res ->> 'name';

    if v_send_id = v_recv_id then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', v_tr_id,
        'sabab', 'jo''natuvchi va qabul qiluvchi bir xil kassa (' || v_send_nom || ') — yozilmadi');
      continue;
    end if;

    select kassa_turi into v_recv_turi from accounts where id = v_recv_id;

    -- 4.6 Transferning o'z kursi (dollar uchun)
    v_tr_rate := null;
    if (v_el ? 'dollar_rate') and jsonb_typeof(v_el -> 'dollar_rate') <> 'null' then
      v_tr_rate := nullif(v_el ->> 'dollar_rate', '')::numeric;
    elsif (v_el ? 'currency_rate') and jsonb_typeof(v_el -> 'currency_rate') = 'object' then
      v_tr_rate := nullif(v_el -> 'currency_rate' ->> 'rate', '')::numeric;
    elsif (v_el ? 'currency_rate') and jsonb_typeof(v_el -> 'currency_rate') in ('number','string') then
      v_tr_rate := nullif(v_el ->> 'currency_rate', '')::numeric;
    elsif (v_el ? 'rate') and jsonb_typeof(v_el -> 'rate') in ('number','string') then
      v_tr_rate := nullif(v_el ->> 'rate', '')::numeric;
    end if;

    v_sana := least((v_recv at time zone 'Asia/Tashkent')::date,
                    (now() at time zone 'Asia/Tashkent')::date);

    -- ---- 4.7 HAR TUR ---- 🔴 YANGI: 'qr' qo'shildi (PROVODKA_QR_TUR.sql)
    foreach v_maydon in array array['cash','click','payme','terminal','qr','dollar_usd']
    loop
      -- Summa (sinonim maydonlar bilan)
      v_amt := null;
      begin
        v_amt := nullif(btrim(coalesce(
                   case v_maydon
                     when 'cash'       then coalesce(v_el ->> 'cash',  v_el ->> 'seller_cash')
                     when 'click'      then coalesce(v_el ->> 'click', v_el ->> 'seller_click')
                     when 'payme'      then coalesce(v_el ->> 'payme', v_el ->> 'seller_payme')
                     when 'terminal'   then coalesce(v_el ->> 'terminal', v_el ->> 'seller_terminal')
                     when 'qr'         then coalesce(v_el ->> 'qr', v_el ->> 'seller_qr')
                     when 'dollar_usd' then coalesce(v_el ->> 'dollar_usd',
                                                     v_el ->> 'seller_dollar',
                                                     v_el ->> 'dollar')
                   end, '')), '')::numeric;
      exception when others then
        v_amt := null;
      end;

      if v_amt is null or v_amt <= 0 then
        continue;                       -- bu turda pul o'tmagan
      end if;

      -- Takror? (is_deleted bo'lsa ham qayta yozmaymiz — admin o'chirganini tiriltirmasin)
      v_ext := 'aros_tr:' || v_tr_id || ':' || v_maydon;
      if exists (select 1 from entry where ext_ref = v_ext) then
        n_takror := n_takror + 1;
        continue;
      end if;

      -- QO'LDA TO'G'IRLANGANMI (aros_tr_fix:<id>:<tur>)
      v_fix_ext := 'aros_tr_fix:' || v_tr_id || ':' ||
                   case v_maydon when 'cash'       then 'naqd'
                                 when 'dollar_usd' then 'dollar'
                                 else v_maydon end;
      if exists (select 1 from entry where ext_ref = v_fix_ext and is_deleted = false) then
        n_fix := n_fix + 1;
        v_ogoh := v_ogoh || jsonb_build_object(
          'transfer', v_tr_id, 'tur', v_maydon, 'summa', v_amt,
          'fix_kalit', v_fix_ext,
          'sabab', 'qo''lda to''g''irlangan (aros_tr_fix) — sinxron qayta yozmaydi, '
                   || 'aks holda markaziy kassa pulni IKKI MARTA olardi');
        continue;
      end if;

      -- Dt/Kt hisoblari
      v_dt := aros_tur_hisob(v_recv_id, v_maydon);
      v_kt := aros_tur_hisob(v_send_id, v_maydon);

      if v_dt is null or v_kt is null then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object(
          'transfer', v_tr_id, 'tur', v_maydon, 'summa', v_amt,
          'sabab', case
                     when v_dt is null and v_kt is null then
                       'ikkala kassada ham "' || v_maydon || '" turi uchun hisob yo''q'
                     when v_dt is null then
                       'qabul qiluvchi (' || v_recv_nom || ') da "' || v_maydon || '" hisobi yo''q'
                     else
                       'jo''natuvchi (' || v_send_nom || ') da "' || v_maydon || '" hisobi yo''q'
                   end || ' — PROVODKA_SYNC_FIX.sql / SEED tur child''ini ochmaganmi?');
        continue;
      end if;

      -- Summa va valyuta
      if v_maydon = 'dollar_usd' then
        v_rate       := coalesce(v_tr_rate, v_baza_rate);
        v_kurs_manba := case when v_tr_rate is not null then 'transfer'
                             when v_baza_rate is not null then 'provodka'
                             else null end;
        if v_rate is null or v_rate <= 0 then
          n_otkaz := n_otkaz + 1;
          v_ogoh := v_ogoh || jsonb_build_object(
            'transfer', v_tr_id, 'tur', v_maydon, 'usd', v_amt,
            'sabab', 'kurs yo''q: transferda ham, Provodka''da ham USD kursi topilmadi');
          continue;
        end if;
        v_fc    := v_amt;                       -- dollar miqdori
        v_summa := round(v_amt * v_rate, 2);    -- so'm ekvivalenti
      else
        v_rate       := null;
        v_kurs_manba := null;
        v_fc         := null;
        v_summa      := v_amt;
      end if;

      if v_summa = 0 then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object(
          'transfer', v_tr_id, 'tur', v_maydon,
          'sabab', 'so''m summasi 0 ga yaxlitlandi — yozuv yozilmadi');
        continue;
      end if;

      -- 🔴 ATAYLAB TEGILMAGAN (terminal versiyasidan meros): bu case faqat
      --    cash/click/payme ni ajratadi, qolgan HAR turda (terminal ham,
      --    endi qr ham) 'USD' qaytaradi. Description matnida kichik nosozlik —
      --    pul yo'nalishi/summasiga ta'sir qilmaydi. Qamrovdan tashqari.
      v_lbl := case v_maydon when 'cash' then 'Naqd' when 'click' then 'Click'
                             when 'payme' then 'Payme' else 'USD' end;

      v_tafsil := v_tafsil || jsonb_build_object(
        'transfer', v_tr_id,
        'sana', v_sana,
        'tur', v_lbl,
        'jonatuvchi', v_send_nom,
        'qabul_qiluvchi', v_recv_nom,
        'summa_uzs', v_summa,
        'usd', v_fc,
        'kurs', v_rate,
        'kurs_manba', v_kurs_manba,
        'ext_ref', v_ext,
        'qabul_kassa_turi', v_recv_turi,
        'ogoh', case when coalesce(v_recv_turi, '') <> 'markaziy'
                     then 'qabul qiluvchi markaziy kassa emas (' || coalesce(v_recv_turi, '?') || ')'
                     else null end);

      if p_dry_run then
        n_yozuv := n_yozuv + 1;
        continue;
      end if;

      -- ---- YOZUV: bitta entry, ikki satr ----
      begin
        insert into entry(entry_date, description, source, status,
                          created_by, fc_rate, ext_ref)
        values (v_sana,
                'Aros transfer #' || v_tr_id || ' · ' || coalesce(v_send_nom, '?')
                  || ' → ' || coalesce(v_recv_nom, '?') || ' · ' || v_lbl,
                'aros_auto', 'posted', 'aros_transfer',
                case when v_maydon = 'dollar_usd' then v_rate else null end,
                v_ext)
        returning id into v_entry;
      exception when unique_violation then
        v_entry  := null;
        n_takror := n_takror + 1;
      end;

      if v_entry is null then
        continue;
      end if;

      -- Dt: qabul qiluvchi (markaziy) — pul keldi
      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, v_dt, v_summa, 0, v_fc);
      -- Kt: jo'natuvchi (filial) — pul chiqdi
      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, v_kt, 0, v_summa, v_fc);

      n_yozuv := n_yozuv + 1;
    end loop;
  end loop;

  -- Muhr: transfer sync qachon ishlagani (cutoff'ga TA'SIR QILMAYDI — ma'lumot uchun)
  if not p_dry_run and to_regprocedure('public.aros_sync_stamp(text, timestamptz)') is not null then
    begin
      perform aros_sync_stamp('transfer', null);
    exception when others then
      null;
    end;
  end if;

  v_natija := jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'sana', to_char(now() at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI:SS'),
    'cutoff', v_cutoff,
    'cutoff_manba', coalesce(v_cutoff_man, '(topilmadi — dry_run)'),
    'cutoff_info', v_cut_info,
    'transferlar', n_jami,
    'yozuvlar', n_yozuv,
    'takror', n_takror,
    'received_emas', n_status,
    'cutoffdan_eski', n_eski,
    'otkazildi', n_otkaz,
    'qolda_tuzatilgan', n_fix,
    'cutoffdan_eski_royxat', v_eski_ruy,
    'ogohlantirishlar', v_ogoh,
    'tafsilot', v_tafsil,
    'eslatma', 'Delta sync SHUNDAN KEYIN ishlashi shart (balanslarni qayta o''qib).');

  if to_regprocedure('public.aros_transfer_drop_yoz(jsonb, boolean)') is not null then
    begin
      perform aros_transfer_drop_yoz(v_natija, p_dry_run);
    exception when others then
      null;
    end;
  end if;

  return v_natija;
end $qr_stb$;

comment on function sync_transfer_balans(jsonb, boolean, timestamptz) is
  'Aros «Transfer Sync v2» pul yozadigan RPC. YANGI (PROVODKA_QR_TUR.sql): '
  '''qr'' turi tur ro''yxatiga va summa o''qishga qo''shildi (terminal bilan bir xil naqsh).';


-- #####################################################################
-- ##  6-BO'LIM — v_filial_sync_mapping + sync_filial_balans: 'qr'      ##
-- #####################################################################
-- Eng oxirgi ta'rif: PROVODKA_BALANS_TERMINAL.sql (2026-09-19). View va
-- funksiya VERBATIM ko'chirildi, faqat 'qr' qo'shildi: view'ning case'iga
-- (aros_maydon='qr'), join shartiga, va funksiya ichidagi tur ro'yxati
-- (`foreach`) + XAVFSIZLIK tekshiruvi shartiga.

create or replace view v_filial_sync_mapping as
select
  k.filial_ref,                                   -- Aros cachier id (join kaliti)
  k.warehouse_id,                                 -- Aros warehouse id (ma'lumot uchun)
  k.id                       as kassa_id,
  k.code                     as kassa_code,
  k.name                     as kassa_name,
  k.kassa_turi,
  case
    when c.pul_turi = 'naqd'  then 'cash'
    when c.pul_turi = 'click' then 'click'
    when c.pul_turi = 'payme' then 'payme'
    when c.pul_turi = 'terminal' then 'terminal'
    when c.pul_turi = 'qr'    then 'qr'
    when c.currency = 'USD'   then 'dollar_usd'
  end                        as aros_maydon,      -- Aros JSON maydoni
  coalesce(c.pul_turi, 'dollar')                as turi,
  c.id                       as account_id,       -- ⬅️ sync shu hisobga yozadi
  c.code                     as hisob_code,
  coalesce(c.currency, 'UZS')                   as currency
from accounts k
join accounts c
  on  c.parent_id = k.id
  and c.is_active
  and c.section   = 'pul'
  and (c.pul_turi in ('naqd','click','payme','terminal','qr') or c.currency = 'USD')
where k.section = 'pul'
  and k.is_active
  and k.parent_id is null          -- kassaning o'zi, bola-hisob emas
  and coalesce(k.currency,'UZS') = 'UZS'
  and k.filial_ref is not null;    -- Aros bilan bog'langan kassalar

alter view v_filial_sync_mapping set (security_invoker = on);
revoke all on v_filial_sync_mapping from public, anon;
grant select on v_filial_sync_mapping to authenticated, service_role;

comment on view v_filial_sync_mapping is
  'Balans Sync uchun: filial_ref + aros_maydon -> account_id. '
  'YANGI (PROVODKA_QR_TUR.sql): pul_turi=qr -> aros_maydon=qr.';

create or replace function sync_filial_balans(p_data jsonb, p_dry_run boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $qr_sfb$
declare
  v_list      jsonb;
  v_el        jsonb;
  v_ref       text;
  v_kapital   uuid;
  v_9010      uuid;
  v_sana      timestamptz := now() at time zone 'Asia/Tashkent';
  v_izoh      text;

  v_tur       text;
  v_maydon    text;
  v_acc       uuid;
  v_acc_code  text;
  v_kassa     text;
  v_yangi     numeric;
  v_rate      numeric;
  v_baza_rate numeric;
  v_kurs_manba text;

  v_uzs       numeric;
  v_fc        numeric;
  v_cnt       bigint;
  v_delta_uzs numeric;
  v_delta_fc  numeric;

  v_dt        uuid;
  v_kt        uuid;
  v_summa     numeric;
  v_fc_line   numeric;
  v_entry     uuid;
  v_birinchi  boolean;

  v_map_soni  bigint;
  v_fil_qator int;
  v_wh        text;
  v_reflar    text;

  n_filial    int := 0;
  n_yozuv     int := 0;
  n_otkaz     int := 0;
  n_tegilmadi int := 0;
  n_ozgarmagan int := 0;
  v_nol       jsonb := '[]'::jsonb;
  v_ogoh      jsonb := '[]'::jsonb;
  v_tafsil    jsonb := '[]'::jsonb;
begin
  -- ---- 0. Bir vaqtda ikkita sync ishlamasin ------------------------
  perform pg_advisory_xact_lock(hashtext('sync_filial_balans'));

  -- ---- 1. Kirishni normallashtirish --------------------------------
  if p_data is null then
    return jsonb_build_object('ok', false, 'error', 'p_data bo''sh');
  end if;
  if jsonb_typeof(p_data) = 'object' and p_data ? 'filiallar' then
    v_list := p_data -> 'filiallar';
  else
    v_list := p_data;
  end if;
  if jsonb_typeof(v_list) <> 'array' then
    return jsonb_build_object('ok', false,
      'error', 'JSON massiv kutilgan edi (yoki {filiallar:[...]}), keldi: ' || jsonb_typeof(v_list));
  end if;

  -- ---- 2. Qarshi hisoblar ------------------------------------------
  v_kapital := boshlangich_kapital_id();
  if v_kapital is null then
    return jsonb_build_object('ok', false,
      'error', 'Boshlang''ich kapital hisobi topilmadi — PROVODKA_KAPITAL.sql RUN qilinganmi?');
  end if;

  select id into v_9010 from accounts where code = '9010' and is_active limit 1;
  if v_9010 is null then
    return jsonb_build_object('ok', false, 'error', '9010 (savdo tushumi) hisobi topilmadi');
  end if;

  v_izoh := 'Aros sync ' || to_char(v_sana, 'YYYY-MM-DD HH24:MI');

  -- ---- 2.0 DIAGNOSTIKA: mapping RPC ICHIDA ko'rinyaptimi ------------
  select count(*) into v_map_soni from v_filial_sync_mapping;
  raise notice 'v_filial_sync_mapping: RPC ichida % qator ko''rinyapti', v_map_soni;

  if v_map_soni = 0 then
    return jsonb_build_object('ok', false,
      'error', 'v_filial_sync_mapping RPC ichida BO''SH (tashqarida qator bo''lsa ham). '
               || 'Bu grant/RLS masalasi — SEED yoki taqqoslash masalasi emas.',
      'mapping_soni', 0);
  end if;

  select string_agg(x, ', ' order by x)
    into v_reflar
    from (select distinct btrim(m.filial_ref::text) as x
            from v_filial_sync_mapping m limit 12) s;

  -- ---- 2.1 Zaxira dollar kursi -------------------------------------
  if to_regprocedure('public.conv_baza_kurs(text)') is not null then
    begin
      execute 'select conv_baza_kurs($1)' into v_baza_rate using 'USD';
    exception when others then
      v_baza_rate := null;
    end;
  end if;

  -- ---- 3. Har filial ------------------------------------------------
  for v_el in select * from jsonb_array_elements(v_list)
  loop
    v_ref := nullif(btrim(coalesce(v_el ->> 'filial_ref', '')), '');
    if v_ref is null then
      v_ogoh := v_ogoh || jsonb_build_object('filial_ref', null, 'sabab', 'filial_ref yo''q');
      continue;
    end if;
    n_filial := n_filial + 1;
    v_rate := coalesce(nullif(v_el ->> 'dollar_rate', '')::numeric, v_baza_rate);
    v_kurs_manba := case
                      when nullif(v_el ->> 'dollar_rate', '') is not null then 'json'
                      when v_baza_rate is not null then 'provodka'
                      else null
                    end;

    select count(*) into v_fil_qator
      from v_filial_sync_mapping m
     where btrim(m.filial_ref::text) = v_ref
        or ( v_ref ~ '^-?[0-9]+(\.[0-9]+)?$'
             and btrim(m.filial_ref::text) ~ '^-?[0-9]+(\.[0-9]+)?$'
             and btrim(m.filial_ref::text)::numeric = v_ref::numeric );

    if v_fil_qator = 0 then
      select string_agg(distinct m.kassa_code, ', ')
        into v_wh
        from v_filial_sync_mapping m
       where m.warehouse_id is not null
         and btrim(m.warehouse_id::text) = v_ref;

      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'filial_ref', v_ref,
        'sabab', case
                   when v_wh is not null then
                     'filial_ref sifatida topilmadi, LEKIN bu qiymat warehouse_id '
                     || 'sifatida mavjud (kassa: ' || v_wh || '). n8n cachier id '
                     || 'o''rniga warehouse id yuboryapti — billing/cachiers/{id} dagi id kerak.'
                   else
                     'bu filial_ref mapping''da yo''q'
                 end,
        'mapping_soni', v_map_soni,
        'mavjud_reflar', v_reflar);
      continue;
    end if;

    -- ---- har tur ---- 🔴 YANGI: 'qr' qo'shildi (PROVODKA_QR_TUR.sql)
    foreach v_maydon in array array['cash','click','payme','terminal','qr','dollar_usd']
    loop
      if (v_el -> v_maydon) is null or jsonb_typeof(v_el -> v_maydon) = 'null' then
        n_tegilmadi := n_tegilmadi + 1;
        continue;
      end if;
      v_yangi := (v_el ->> v_maydon)::numeric;

      select m.account_id, m.hisob_code, m.kassa_code, m.turi
        into v_acc, v_acc_code, v_kassa, v_tur
        from v_filial_sync_mapping m
       where btrim(m.aros_maydon) = v_maydon
         and ( btrim(m.filial_ref::text) = v_ref
               or ( v_ref ~ '^-?[0-9]+(\.[0-9]+)?$'
                    and btrim(m.filial_ref::text) ~ '^-?[0-9]+(\.[0-9]+)?$'
                    and btrim(m.filial_ref::text)::numeric = v_ref::numeric ) )
       limit 1;

      if v_acc is null then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object(
          'filial_ref', v_ref, 'aros_maydon', v_maydon,
          'sabab', 'bu filialda "' || v_maydon || '" turi uchun hisob yo''q — '
                   || 'PROVODKA_VALYUTA_SEED.sql o''sha kassaga ochmaganmi?');
        continue;
      end if;

      -- ---- TO'SIQ: topilgan hisob HAQIQATAN kassa tur child'imi ----------
      if not exists (
            select 1
              from accounts c
              join accounts k on k.id = c.parent_id
             where c.id = v_acc
               and c.is_active and c.section = 'pul'
               and (c.pul_turi in ('naqd','click','payme','terminal','qr') or c.currency = 'USD')
               and k.is_active and k.section = 'pul' and k.parent_id is null
          ) then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object(
          'filial_ref', v_ref, 'aros_maydon', v_maydon, 'account_id', v_acc,
          'sabab', 'XAVFSIZLIK: topilgan hisob kassa tur child''i EMAS — yozilmadi. '
                   || 'v_filial_sync_mapping buzilgan bo''lishi mumkin.');
        continue;
      end if;

      select coalesce(sum(l.debit - l.credit), 0),
             coalesce(sum(case when l.debit > 0 then coalesce(l.fc_amount, 0)
                               else -coalesce(l.fc_amount, 0) end), 0),
             count(*)
        into v_uzs, v_fc, v_cnt
        from entry_line l
        join entry e on e.id = l.entry_id
       where l.account_id = v_acc
         and e.status = 'posted'
         and e.is_deleted = false;

      v_birinchi := (v_cnt = 0);

      if v_maydon = 'dollar_usd' then
        v_delta_fc  := v_yangi - v_fc;
        if v_delta_fc = 0 then
          n_ozgarmagan := n_ozgarmagan + 1;
          if p_dry_run then
            v_nol := v_nol || jsonb_build_object(
              'filial_ref', v_ref, 'kassa', v_kassa, 'tur', v_tur, 'hisob', v_acc_code,
              'joriy', v_fc, 'aros', v_yangi, 'satrlar', v_cnt);
          end if;
          continue;
        end if;
        if v_rate is null or v_rate <= 0 then
          n_otkaz := n_otkaz + 1;
          v_ogoh := v_ogoh || jsonb_build_object(
            'filial_ref', v_ref, 'aros_maydon', v_maydon, 'delta_usd', v_delta_fc,
            'sabab', 'kurs yo''q: JSON''da dollar_rate yuborilmagan va '
                     || 'Provodka''da ham joriy USD kursi topilmadi '
                     || '(Valyuta bo''limida kurs qo''shing yoki dollar_rate yuboring)');
          continue;
        end if;
        v_delta_uzs := round(v_delta_fc * v_rate, 2);
        v_fc_line   := abs(v_delta_fc);
      else
        v_delta_fc  := null;
        v_delta_uzs := v_yangi - v_uzs;
        v_fc_line   := null;
        if v_delta_uzs = 0 then
          n_ozgarmagan := n_ozgarmagan + 1;
          if p_dry_run then
            v_nol := v_nol || jsonb_build_object(
              'filial_ref', v_ref, 'kassa', v_kassa, 'tur', v_tur, 'hisob', v_acc_code,
              'joriy', v_uzs, 'aros', v_yangi, 'satrlar', v_cnt);
          end if;
          continue;
        end if;
      end if;

      if v_delta_uzs > 0 then
        v_dt := v_acc;
        v_kt := case when v_birinchi then v_kapital else v_9010 end;
      else
        v_dt := case when v_birinchi then v_kapital else v_9010 end;
        v_kt := v_acc;
      end if;
      v_summa := abs(v_delta_uzs);

      if v_summa = 0 then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object(
          'filial_ref', v_ref, 'aros_maydon', v_maydon, 'delta', v_delta_fc,
          'sabab', 'so''m summasi 0 ga yaxlitlandi — yozuv yozilmadi');
        continue;
      end if;

      v_tafsil := v_tafsil || jsonb_build_object(
        'filial_ref', v_ref, 'kassa', v_kassa, 'tur', v_tur, 'hisob', v_acc_code,
        'joriy', case when v_maydon = 'dollar_usd' then v_fc else v_uzs end,
        'aros',  v_yangi,
        'delta', case when v_maydon = 'dollar_usd' then v_delta_fc else v_delta_uzs end,
        'summa_uzs', v_summa,
        'qarshi', case when v_birinchi then 'boshlangich_kapital' else '9010' end,
        'birinchi', v_birinchi,
        'kurs', case when v_maydon = 'dollar_usd' then v_rate else null end,
        'kurs_manba', case when v_maydon = 'dollar_usd' then v_kurs_manba else null end);

      if p_dry_run then
        n_yozuv := n_yozuv + 1;
        continue;
      end if;

      insert into entry(entry_date, description, source, status, created_by, fc_rate)
      values (current_date,
              v_izoh || ' · ' || coalesce(v_kassa, '') || ' · ' || coalesce(v_tur, v_maydon),
              'aros_auto', 'posted', 'aros_sync',
              case when v_maydon = 'dollar_usd' then v_rate else null end)
      returning id into v_entry;

      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, v_dt, v_summa, 0,
              case when v_dt = v_acc then v_fc_line else null end);
      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, v_kt, 0, v_summa,
              case when v_kt = v_acc then v_fc_line else null end);

      n_yozuv := n_yozuv + 1;
    end loop;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'sana', to_char(v_sana, 'YYYY-MM-DD HH24:MI:SS'),
    'filiallar', n_filial,
    'yozuvlar', n_yozuv,
    'otkazildi', n_otkaz,
    'tegilmadi', n_tegilmadi,
    'ozgarmagan', n_ozgarmagan,
    'ozgarmagan_royxat', case when p_dry_run then v_nol else '[]'::jsonb end,
    'mapping_soni', v_map_soni,
    'mavjud_reflar', v_reflar,
    'ogohlantirishlar', v_ogoh,
    'tafsilot', v_tafsil);
end $qr_sfb$;

comment on function sync_filial_balans(jsonb, boolean) is
  'Aros «Balans Sync» pul yozadigan RPC. YANGI (PROVODKA_QR_TUR.sql): '
  '''qr'' turi tur ro''yxatiga qo''shildi (terminal bilan bir xil naqsh).';


-- #####################################################################
-- ##  7-BO'LIM — aros_transfer_yolda + sync_transfer_yolda/            ##
-- ##             yolda_royxat/yolda_farq: s_qr/c_qr                    ##
-- #####################################################################
-- PROVODKA_YOLDA_TERMINAL.sql naqshining AYNAN nusxasi (terminal ustunini
-- qanday qo'shgan bo'lsa, shu yerda 'qr' xuddi shunday qo'shiladi). PUL
-- HARAKATI YO'Q — bu bo'lim faqat REGISTR (transit ko'rinishi), entry ga
-- tegmaydi.

alter table aros_transfer_yolda
  add column if not exists s_qr numeric not null default 0;
alter table aros_transfer_yolda
  add column if not exists c_qr numeric;

create or replace function sync_transfer_yolda(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $qr_yolda_sync$
declare
  v_role            text;
  v_list            jsonb;
  v_el              jsonb;

  v_id              text;
  v_status          text;
  v_sender_ref      text;
  v_receiver_ref    text;
  v_sender_title    text;
  v_receiver_title  text;
  v_sent_at         timestamptz;
  v_received_at     timestamptz;

  v_seller          jsonb;
  v_confirmed       jsonb;
  v_s_cash          numeric;
  v_s_click         numeric;
  v_s_payme         numeric;
  v_s_terminal      numeric;
  v_s_qr            numeric;
  v_s_usd           numeric;
  v_c_cash          numeric;
  v_c_click         numeric;
  v_c_payme         numeric;
  v_c_terminal      numeric;
  v_c_qr            numeric;
  v_c_usd           numeric;
  v_rate            numeric;
  v_resp            text;

  v_sender_acc      jsonb;
  v_receiver_acc    jsonb;
  v_was_insert      boolean;

  v_ids_korilgan    text[] := '{}';
  n_yozildi         int := 0;
  n_yangilandi      int := 0;
  n_nomalum         int := 0;
  v_ogoh            jsonb := '[]'::jsonb;
begin
  -- ---- service_role ONLY (admin_set_provodka_perms bilan bir xil naqsh) ----
  if auth.uid() is not null then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is not null and v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('sync_transfer_yolda'));

  if p_data is null then
    return jsonb_build_object('ok', false, 'error', 'p_data bo''sh');
  end if;

  if jsonb_typeof(p_data) = 'object' and p_data ? 'transferlar' then
    v_list := p_data -> 'transferlar';
  elsif jsonb_typeof(p_data) = 'object' and p_data ? 'transfers' then
    v_list := p_data -> 'transfers';
  else
    v_list := p_data;
  end if;

  if jsonb_typeof(v_list) is distinct from 'array' then
    return jsonb_build_object('ok', false,
      'error', 'JSON massiv kutilgan edi (yoki {transferlar:[...]}), keldi: '
               || coalesce(jsonb_typeof(v_list), 'null'));
  end if;

  for v_el in select * from jsonb_array_elements(v_list)
  loop
    begin
      v_id := nullif(btrim(coalesce(v_el ->> 'id', v_el ->> 'transfer_id', '')), '');
      if v_id is null then
        v_ogoh := v_ogoh || jsonb_build_object('transfer', null, 'sabab', 'id yoq');
        continue;
      end if;

      v_ids_korilgan := v_ids_korilgan || v_id;

      v_status := lower(btrim(coalesce(nullif(v_el ->> 'status', ''), 'nomalum')));
      if v_status not in ('sent', 'received', 'canceled') then
        v_status := 'nomalum';
      end if;

      v_sender_title   := nullif(btrim(coalesce(v_el ->> 'sender_title', '')), '');
      v_receiver_title := nullif(btrim(coalesce(v_el ->> 'receiver_title', '')), '');
      v_sender_ref     := nullif(btrim(coalesce(v_el ->> 'sender_ref', '')), '');
      v_receiver_ref   := nullif(btrim(coalesce(v_el ->> 'receiver_ref', '')), '');

      v_sent_at     := _yolda_ts(v_el ->> 'sent_at');
      v_received_at := _yolda_ts(v_el ->> 'received_at');

      v_sender_acc   := aros_kassa_topish(v_sender_ref,   v_sender_title);
      v_receiver_acc := aros_kassa_topish(v_receiver_ref, v_receiver_title);

      v_seller     := coalesce(v_el -> 'seller', '{}'::jsonb);
      v_s_cash     := coalesce((v_seller ->> 'cash')::numeric, 0);
      v_s_click    := coalesce((v_seller ->> 'click')::numeric, 0);
      v_s_payme    := coalesce((v_seller ->> 'payme')::numeric, 0);
      v_s_terminal := coalesce((v_seller ->> 'terminal')::numeric, 0);
      -- 🔴 qr (2026-09-22): eski n8n payloadda kalit yo'q bo'lsa 0 — eski oqim buzilmaydi.
      v_s_qr       := coalesce((v_seller ->> 'qr')::numeric, 0);
      v_s_usd      := coalesce((v_seller ->> 'dollar_usd')::numeric, 0);

      if v_status = 'received'
         and jsonb_typeof(v_el -> 'confirmed') = 'object' then
        v_confirmed  := v_el -> 'confirmed';
        v_c_cash     := coalesce((v_confirmed ->> 'cash')::numeric, 0);
        v_c_click    := coalesce((v_confirmed ->> 'click')::numeric, 0);
        v_c_payme    := coalesce((v_confirmed ->> 'payme')::numeric, 0);
        v_c_terminal := coalesce((v_confirmed ->> 'terminal')::numeric, 0);
        v_c_qr       := coalesce((v_confirmed ->> 'qr')::numeric, 0);
        v_c_usd      := coalesce((v_confirmed ->> 'dollar_usd')::numeric, 0);
      else
        v_c_cash     := null;
        v_c_click    := null;
        v_c_payme    := null;
        v_c_terminal := null;
        v_c_qr       := null;
        v_c_usd      := null;
      end if;

      v_rate := nullif(v_el ->> 'dollar_rate', '')::numeric;
      v_resp := nullif(btrim(coalesce(v_el ->> 'responsible', '')), '');

      insert into aros_transfer_yolda(
        transfer_id, status, sender_id, receiver_id, sender_title, receiver_title,
        sent_at, received_at, s_cash, s_click, s_payme, s_terminal, s_qr, s_usd,
        c_cash, c_click, c_payme, c_terminal, c_qr, c_usd, dollar_rate, responsible, synced_at)
      values (
        v_id, v_status,
        case when coalesce((v_sender_acc   ->> 'ok')::boolean, false) then (v_sender_acc   ->> 'id')::uuid else null end,
        case when coalesce((v_receiver_acc ->> 'ok')::boolean, false) then (v_receiver_acc ->> 'id')::uuid else null end,
        v_sender_title, v_receiver_title, v_sent_at, v_received_at,
        v_s_cash, v_s_click, v_s_payme, v_s_terminal, v_s_qr, v_s_usd,
        v_c_cash, v_c_click, v_c_payme, v_c_terminal, v_c_qr, v_c_usd, v_rate, v_resp, now())
      on conflict (transfer_id) do update
         set status         = excluded.status,
             sender_id      = excluded.sender_id,
             receiver_id    = excluded.receiver_id,
             sender_title   = excluded.sender_title,
             receiver_title = excluded.receiver_title,
             sent_at        = excluded.sent_at,
             received_at    = excluded.received_at,
             s_cash         = excluded.s_cash,
             s_click        = excluded.s_click,
             s_payme        = excluded.s_payme,
             s_terminal     = excluded.s_terminal,
             s_qr           = excluded.s_qr,
             s_usd          = excluded.s_usd,
             c_cash         = excluded.c_cash,
             c_click        = excluded.c_click,
             c_payme        = excluded.c_payme,
             c_terminal     = excluded.c_terminal,
             c_qr           = excluded.c_qr,
             c_usd          = excluded.c_usd,
             dollar_rate    = excluded.dollar_rate,
             responsible    = excluded.responsible,
             synced_at      = now()
      returning (xmax = 0) into v_was_insert;

      if v_was_insert then
        n_yozildi := n_yozildi + 1;
      else
        n_yangilandi := n_yangilandi + 1;
      end if;

      if not coalesce((v_sender_acc ->> 'ok')::boolean, false) then
        v_ogoh := v_ogoh || jsonb_build_object(
          'transfer', v_id, 'tomon', 'sender', 'sabab', v_sender_acc ->> 'sabab');
      end if;
      if not coalesce((v_receiver_acc ->> 'ok')::boolean, false) then
        v_ogoh := v_ogoh || jsonb_build_object(
          'transfer', v_id, 'tomon', 'receiver', 'sabab', v_receiver_acc ->> 'sabab');
      end if;

    exception when others then
      v_ogoh := v_ogoh || jsonb_build_object('transfer', v_id, 'sabab', sqlerrm);
      continue;
    end;
  end loop;

  -- Payloadda ko'rinmay qolgan «sent» qatorlar -> 'nomalum'
  if coalesce(array_length(v_ids_korilgan, 1), 0) > 0 then
    update aros_transfer_yolda
       set status = 'nomalum', synced_at = now()
     where status = 'sent'
       and not (transfer_id = any(v_ids_korilgan));
    get diagnostics n_nomalum = row_count;
  else
    n_nomalum := 0;
    v_ogoh := v_ogoh || jsonb_build_object('sabab', 'payload bosh — sent sweep otkazib yuborildi');
  end if;

  return jsonb_build_object(
    'ok', true,
    'yozildi', n_yozildi,
    'yangilandi', n_yangilandi,
    'nomalum', n_nomalum,
    'ogoh', v_ogoh);
end
$qr_yolda_sync$;

comment on function sync_transfer_yolda(jsonb) is
  'service_role ONLY (n8n «Aros Provodka - Yolda Sync»). aros_transfer_yolda ni upsert qiladi. '
  'PUL HARAKATI YO''Q — entry/entry_line ga tegilmaydi. Payloadda yo''q qolgan avvalgi '
  '''sent'' qatorlar ''nomalum'' ga o''tkaziladi. qr (2026-09-22): seller/confirmed '
  'obyektida ''qr'' kaliti bo''lmasa 0/null.';


create or replace function yolda_royxat()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $qr_yolda_royxat$
declare
  v_uid       uuid;
  p           user_perms%rowtype;
  v_rejim     text;
  v_ids       uuid[] := '{}';
  v_baza_rate numeric;
  v_sent      jsonb;
  v_jami      numeric;
  v_soni      int;
  v_qabul     jsonb;
  v_synced    timestamptz;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('rows', '[]'::jsonb, 'jami_uzs', 0, 'soni', 0,
                              'qabul', '[]'::jsonb, 'synced_at', null);
  end if;

  if is_admin() then
    v_rejim := 'admin';
  else
    select * into p from user_perms where user_id = v_uid;
    if not found
       or not ( 'kassa'  = any(coalesce(p.allowed_pages, '{}'::text[]))
             or 'jurnal' = any(coalesce(p.allowed_pages, '{}'::text[])) ) then
      v_rejim := 'yoq';
    elsif p.kassa_scope is distinct from 'list' then
      v_rejim := 'all';
    else
      v_rejim := 'list';
      v_ids   := coalesce(p.view_kassa_ids, '{}'::uuid[]);
    end if;
  end if;

  if v_rejim = 'yoq' then
    return jsonb_build_object('rows', '[]'::jsonb, 'jami_uzs', 0, 'soni', 0,
                              'qabul', '[]'::jsonb, 'synced_at', null);
  end if;

  if to_regprocedure('public.conv_baza_kurs(text)') is not null then
    begin
      execute 'select conv_baza_kurs($1)' into v_baza_rate using 'USD';
    exception when others then
      v_baza_rate := null;
    end;
  end if;

  -- ---- «Yo'lda» (status = sent) ----
  with base as (
    select t.transfer_id, t.sender_id, t.receiver_id,
           coalesce(sa.name, t.sender_title)     as sender_nom_raw,
           coalesce(ra.name, t.receiver_title)   as receiver_nom_raw,
           t.sent_at, t.s_cash, t.s_click, t.s_payme, t.s_terminal, t.s_qr, t.s_usd, t.dollar_rate,
           (v_rejim in ('admin','all') or perm_op_key(t.sender_id)   = any(v_ids)) as send_ok,
           (v_rejim in ('admin','all') or perm_op_key(t.receiver_id) = any(v_ids)) as recv_ok
      from aros_transfer_yolda t
      left join accounts sa on sa.id = t.sender_id
      left join accounts ra on ra.id = t.receiver_id
     where t.status = 'sent'
  ),
  vis as (
    select b.*,
           case when send_ok then sender_nom_raw   else 'Boshqa kassa' end as sender_nom,
           case when recv_ok then receiver_nom_raw else 'Boshqa kassa' end as receiver_nom,
           coalesce(s_cash,0) + coalesce(s_click,0) + coalesce(s_payme,0) + coalesce(s_terminal,0)
             + coalesce(s_qr,0) + coalesce(s_usd,0) * coalesce(dollar_rate, v_baza_rate, 0) as jami_uzs
      from base b
     where coalesce(send_ok, false) or coalesce(recv_ok, false)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'transfer_id', v.transfer_id, 'sender_id', v.sender_id, 'receiver_id', v.receiver_id,
           'sender_nom', v.sender_nom, 'receiver_nom', v.receiver_nom, 'sent_at', v.sent_at,
           'cash', v.s_cash, 'click', v.s_click, 'payme', v.s_payme, 'terminal', v.s_terminal,
           'qr', v.s_qr, 'usd', v.s_usd,
           'dollar_rate', v.dollar_rate, 'jami_uzs', v.jami_uzs)
           order by v.sent_at desc), '[]'::jsonb),
         coalesce(sum(v.jami_uzs), 0),
         count(*)
    into v_sent, v_jami, v_soni
    from vis v;

  -- ---- Yaqinda qabul qilingan (status = received, so'nggi 48 soat) ----
  with base2 as (
    select t.transfer_id, t.sender_id, t.receiver_id,
           coalesce(sa.name, t.sender_title)     as sender_nom_raw,
           coalesce(ra.name, t.receiver_title)   as receiver_nom_raw,
           t.sent_at, t.received_at,
           t.s_cash, t.s_click, t.s_payme, t.s_terminal, t.s_qr, t.s_usd,
           t.c_cash, t.c_click, t.c_payme, t.c_terminal, t.c_qr, t.c_usd, t.dollar_rate,
           (v_rejim in ('admin','all') or perm_op_key(t.sender_id)   = any(v_ids)) as send_ok,
           (v_rejim in ('admin','all') or perm_op_key(t.receiver_id) = any(v_ids)) as recv_ok
      from aros_transfer_yolda t
      left join accounts sa on sa.id = t.sender_id
      left join accounts ra on ra.id = t.receiver_id
     where t.status = 'received'
       and t.received_at >= now() - interval '48 hours'
  ),
  vis2 as (
    select b.*,
           case when send_ok then sender_nom_raw   else 'Boshqa kassa' end as sender_nom,
           case when recv_ok then receiver_nom_raw else 'Boshqa kassa' end as receiver_nom,
           ( (coalesce(c_cash,0) + coalesce(c_click,0) + coalesce(c_payme,0) + coalesce(c_terminal,0)
                + coalesce(c_qr,0) + coalesce(c_usd,0) * coalesce(dollar_rate, v_baza_rate, 0))
           - (coalesce(s_cash,0) + coalesce(s_click,0) + coalesce(s_payme,0) + coalesce(s_terminal,0)
                + coalesce(s_qr,0) + coalesce(s_usd,0) * coalesce(dollar_rate, v_baza_rate, 0)) ) as farq_uzs
      from base2 b
     where coalesce(send_ok, false) or coalesce(recv_ok, false)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'transfer_id', v.transfer_id, 'sender_id', v.sender_id, 'receiver_id', v.receiver_id,
           'sender_nom', v.sender_nom, 'receiver_nom', v.receiver_nom,
           'sent_at', v.sent_at, 'received_at', v.received_at,
           's_cash', v.s_cash, 's_click', v.s_click, 's_payme', v.s_payme, 's_terminal', v.s_terminal,
           's_qr', v.s_qr, 's_usd', v.s_usd,
           'c_cash', v.c_cash, 'c_click', v.c_click, 'c_payme', v.c_payme, 'c_terminal', v.c_terminal,
           'c_qr', v.c_qr, 'c_usd', v.c_usd,
           'farq_uzs', v.farq_uzs)
           order by v.received_at desc), '[]'::jsonb)
    into v_qabul
    from vis2 v;

  select max(synced_at) into v_synced from aros_transfer_yolda;

  return jsonb_build_object(
    'rows', v_sent, 'jami_uzs', coalesce(v_jami, 0), 'soni', coalesce(v_soni, 0),
    'qabul', v_qabul, 'synced_at', v_synced);
end
$qr_yolda_royxat$;

comment on function yolda_royxat() is
  'Yo''ldagi (status=sent) va yaqinda qabul qilingan (48 soat) transferlar — '
  'ruxsat doirasida (yolda_korish_ok bilan bir xil qoida). Begona tomon nomi '
  '''Boshqa kassa'' bilan maskalanadi. Pul harakati yo''q — faqat SELECT. '
  'qr (2026-09-22): jami_uzs/farq_uzs hisobiga qo''shildi.';


create or replace function yolda_farq(p_ids text[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $qr_yolda_farq$
  select coalesce(jsonb_agg(jsonb_build_object(
           'transfer_id', t.transfer_id, 'status', t.status,
           'sent_at', t.sent_at, 'received_at', t.received_at,
           's_cash', t.s_cash, 's_click', t.s_click, 's_payme', t.s_payme, 's_terminal', t.s_terminal,
           's_qr', t.s_qr, 's_usd', t.s_usd,
           'c_cash', t.c_cash, 'c_click', t.c_click, 'c_payme', t.c_payme, 'c_terminal', t.c_terminal,
           'c_qr', t.c_qr, 'c_usd', t.c_usd,
           'dollar_rate', t.dollar_rate)
           order by t.sent_at desc nulls last), '[]'::jsonb)
    from aros_transfer_yolda t
   where auth.uid() is not null
     and t.transfer_id = any((coalesce(p_ids, '{}'::text[]))[1:500])
     and yolda_korish_ok(t.sender_id, t.receiver_id);
$qr_yolda_farq$;

comment on function yolda_farq(text[]) is
  'Jurnal uchun: berilgan transfer_id lar (<=500) bo''yicha sotuvchi/tasdiqlangan xom sonlar. '
  'Faqat yolda_korish_ok o''tgan qatorlar; ism/kod qaytarmaydi. auth.uid() null -> bo''sh. '
  'qr (2026-09-22): javobga s_qr/c_qr qo''shildi.';


-- #####################################################################
-- ##  8-BO'LIM — PostgREST sxema keshini yangilash                    ##
-- #####################################################################

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  9-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/raise)                ##
-- #####################################################################

do $qr_final$
declare
  v_ok boolean;
  v_def text;
begin
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint
   where conname = 'accounts_pul_turi_chk' and conrelid = 'public.accounts'::regclass;
  if v_def is null or v_def not like '%qr%' then
    raise exception 'YAKUNIY TEKSHIRUV: accounts_pul_turi_chk da qr yoq (%)', coalesce(v_def, '(topilmadi)');
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'aros_transfer_yolda' and column_name = 's_qr'
  ) then
    raise exception 'YAKUNIY TEKSHIRUV: s_qr ustuni yaralmadi';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'aros_transfer_yolda' and column_name = 'c_qr'
  ) then
    raise exception 'YAKUNIY TEKSHIRUV: c_qr ustuni yaralmadi';
  end if;

  if to_regprocedure('public.qr_tur_toldir(boolean)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: qr_tur_toldir(boolean) yoq';
  end if;
  if to_regprocedure('public.sync_transfer_balans(jsonb,boolean,timestamptz)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: sync_transfer_balans yoq';
  end if;
  if to_regprocedure('public.sync_filial_balans(jsonb,boolean)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: sync_filial_balans yoq';
  end if;
  if to_regprocedure('public.sync_transfer_yolda(jsonb)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: sync_transfer_yolda(jsonb) yoq';
  end if;
  if to_regprocedure('public.yolda_royxat()') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yolda_royxat() yoq';
  end if;
  if to_regprocedure('public.yolda_farq(text[])') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yolda_farq(text[]) yoq';
  end if;

  select has_function_privilege('service_role', 'public.sync_transfer_yolda(jsonb)', 'execute')
    into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: service_role uchun sync_transfer_yolda(jsonb) EXECUTE yoq';
  end if;

  select has_function_privilege('authenticated', 'public.yolda_royxat()', 'execute')
    into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun yolda_royxat() EXECUTE yoq';
  end if;

  raise notice 'PROVODKA_QR_TUR.sql: hammasi joyida';
end
$qr_final$;

-- Qo'shimcha ko'rinadigan tekshiruv: qr child'lari va aros_tur_hisob natijasi
select k.code, k.name,
       aros_tur_hisob(k.id, 'terminal') as terminal_id,
       aros_tur_hisob(k.id, 'qr')       as qr_id,
       aros_tur_hisob(k.id, 'qr_code')  as qr_code_sinonim_id
  from accounts k
 where k.section = 'pul' and k.parent_id is null
   and coalesce(k.currency, 'UZS') = 'UZS'
   and exists (select 1 from accounts c where c.parent_id = k.id and c.pul_turi = 'terminal')
 order by k.code;
