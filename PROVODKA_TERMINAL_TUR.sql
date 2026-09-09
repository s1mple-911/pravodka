-- =====================================================================
--  PROVODKA_TERMINAL_TUR.sql   (2026-09-09, Asilbek)
--  Aros «terminal» to'lov turi -> Provodkada tur bola-hisobi
-- ---------------------------------------------------------------------
--  ## SABAB
--  Aros adminka yangilanishida transfer hujjatidagi to'lov turlari
--  o'zgardi: `payme` o'rniga `terminal` paydo bo'ldi.
--      items[].document.amounts[].label_code =
--          cash_balance | click_balance | dollar_balance | terminal
--  Provodkada esa `terminal` tur-hisobi yo'q edi — transfer sinxroni
--  bunday pulni qayerga yozishni bilmasdi.
--
--  ## YAXSHI XABAR
--  `PROVODKA_TURLAR_AVTO.sql` allaqachon `terminal` ni QO'LLAB-QUVVATLAYDI:
--    * `accounts_pul_turi_chk` -> naqd|click|payme|karta|terminal|plastik
--    * `_pul_turi_child_ich`   -> yorlig'i «Terminal», idempotent
--  Ya'ni yangi ustun/cheklov KERAK EMAS — faqat bola-hisoblarni ochish
--  va `aros_tur_hisob` ga `terminal` ni tanitish qoldi.
--
--  ## QAMROV
--  Terminal bola-hisobi FAQAT transferda qatnashadigan kassalarga
--  ochiladi: yuqori darajadagi (parent_id is null) so'm kassalari —
--  markaziy (5011/5012) va filiallar. Hodim kassalari (5400 ostidagi)
--  transferda qatnashmaydi, shuning uchun sukut bo'yicha TEGILMAYDI
--  (kerak bo'lsa `p_hammasi := true`).
--
--  ## QOIDALAR (CLAUDE.md)
--   * ADDITIVE: `aros_tur_hisob(uuid,text)` imzosi O'ZGARMAYDI.
--   * anonim `do` bloki YO'Q; funksiya tanasi nomlangan dollar-teg bilan.
--   * idempotent: bola bor bo'lsa qayta ochilmaydi.
-- =====================================================================


-- #####################################################################
--  0-BO'LIM — OLD SHART (faqat select/exception)
-- #####################################################################

do $term_pre$
begin
  if to_regprocedure('public._pul_turi_child_ich(uuid,text)') is null then
    raise exception '_pul_turi_child_ich yoq — avval PROVODKA_TURLAR_AVTO.sql ni bajaring';
  end if;
  if to_regprocedure('public.aros_tur_hisob(uuid,text)') is null then
    raise exception 'aros_tur_hisob yoq — avval PROVODKA_TRANSFER.sql ni bajaring';
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'accounts_pul_turi_chk'
                    and pg_get_constraintdef(oid) like '%terminal%') then
    raise exception 'accounts_pul_turi_chk da terminal yoq — avval PROVODKA_TURLAR_AVTO.sql ni bajaring';
  end if;
end
$term_pre$;


-- #####################################################################
--  1-BO'LIM — OLDINDAN KO'RISH: kimga ochiladi (hech narsa yozmaydi)
-- #####################################################################
-- ⬇⬇⬇
select a.code, a.name, a.kassa_turi,
       exists (select 1 from accounts c
                where c.parent_id = a.id and c.pul_turi = 'terminal') as terminal_bor
  from accounts a
 where a.section = 'pul'
   and a.parent_id is null
   and coalesce(a.currency, 'UZS') = 'UZS'
   and coalesce(a.is_active, true)
   and a.kassa_turi is distinct from 'xarajat_guruh'
   and exists (select 1 from accounts c
                where c.parent_id = a.id and c.pul_turi = 'payme')
 order by a.code;
-- ⬆⬆⬆
--  `terminal_bor = false` qatorlarga 2-BO'LIM bola-hisob ochadi.


-- #####################################################################
--  2-BO'LIM — terminal_tur_toldir() — bola-hisoblarni ochadi
-- #####################################################################

create or replace function terminal_tur_toldir(p_hammasi boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
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
                    where c.parent_id = a.id and c.pul_turi = 'payme')
     order by a.code
  loop
    if exists (select 1 from accounts c
                where c.parent_id = r.id and c.pul_turi = 'terminal') then
      v_bor := v_bor || jsonb_build_object('code', r.code, 'nom', r.name);
    else
      v_id := _pul_turi_child_ich(r.id, 'terminal');
      v_yangi := v_yangi || jsonb_build_object('code', r.code, 'nom', r.name, 'child_id', v_id);
    end if;
  end loop;

  return jsonb_build_object('ok', true,
                            'yaratildi', jsonb_array_length(v_yangi),
                            'bor_edi',   jsonb_array_length(v_bor),
                            'yangi',     v_yangi,
                            'bor',       v_bor);
end $fn$;

revoke all on function terminal_tur_toldir(boolean) from public, anon;
grant execute on function terminal_tur_toldir(boolean) to authenticated;

comment on function terminal_tur_toldir(boolean) is
  'Transferda qatnashadigan kassalarga «Terminal» tur bola-hisobini ochadi (idempotent). '
  'Sukut: faqat yuqori darajadagi kassalar (markaziy + filial). p_hammasi=true -> hodim '
  'kassalari ham. Aros 2026-09-09 yangilanishida payme o''rniga terminal paydo bo''ldi.';

-- ⬇⬇⬇  ISHGA TUSHIRISH (1-BO'LIM ro'yxatini ko'rgach)
select jsonb_pretty(terminal_tur_toldir());
-- ⬆⬆⬆


-- #####################################################################
--  3-BO'LIM — aros_tur_hisob: `terminal` ni taniydi
-- #####################################################################
-- 🔴 PROVODKA_TRANSFER.sql (496-516) dagi tananing VERBATIM nusxasi.
--    Yagona farq: birinchi shoxdagi tur ro'yxatiga karta/terminal/plastik
--    qo'shildi. `case` allaqachon 'cash' -> 'naqd', qolgani o'zicha —
--    shuning uchun yangi turlar avtomat to'g'ri ishlaydi.

create or replace function aros_tur_hisob(p_kassa uuid, p_maydon text)
returns uuid
language sql
stable
as $fn$
  select c.id
    from accounts c
    join accounts k on k.id = c.parent_id
   where c.parent_id = p_kassa
     and c.is_active and c.section = 'pul'
     and k.is_active and k.section = 'pul' and k.parent_id is null
     and (
           ( p_maydon in ('cash','naqd','click','payme','karta','terminal','plastik')
             and c.pul_turi = case p_maydon when 'cash' then 'naqd' else p_maydon end
             and coalesce(c.currency, 'UZS') = 'UZS' )
        or ( p_maydon in ('dollar_usd','dollar','usd')
             and c.currency = 'USD' )
         )
   order by c.code
   limit 1;
$fn$;

revoke all on function aros_tur_hisob(uuid, text) from public, anon;
grant execute on function aros_tur_hisob(uuid, text) to authenticated, service_role;

comment on function aros_tur_hisob(uuid, text) is
  'Kassaning tur child hisobi: cash|naqd|click|payme|karta|terminal|plastik -> pul_turi, '
  'dollar_usd -> currency=USD. Transfer sync shu bilan Dt/Kt hisoblarini topadi. '
  'YANGI (PROVODKA_TERMINAL_TUR.sql): terminal/karta/plastik qo''shildi.';


-- #####################################################################
--  PostgREST sxema keshi
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
--  4-BO'LIM — TEKSHIRUV (faqat select)
-- #####################################################################

-- 4.1 Terminal bola-hisoblari ochildimi
-- ⬇⬇⬇
select k.code as kassa, k.name as kassa_nomi,
       c.code as terminal_kod, c.name as terminal_nomi
  from accounts c
  join accounts k on k.id = c.parent_id
 where c.pul_turi = 'terminal'
 order by k.code;
-- ⬆⬆⬆

-- 4.2 aros_tur_hisob terminalni topayaptimi (Toshkent kassa misolida)
-- ⬇⬇⬇
select a.code, a.name,
       aros_tur_hisob(a.id, 'cash')     as naqd_id,
       aros_tur_hisob(a.id, 'click')    as click_id,
       aros_tur_hisob(a.id, 'payme')    as payme_id,
       aros_tur_hisob(a.id, 'terminal') as terminal_id
  from accounts a
 where a.code in ('5011','5012')
 order by a.code;
-- ⬆⬆⬆
--  `terminal_id` NULL bo'lmasligi kerak. NULL bo'lsa 2-BO'LIM ishlamagan.


-- #####################################################################
--  5-BO'LIM — sync_transfer_balans: `terminal` turini yozadi
-- #####################################################################
--  🔴 MUAMMO: RPC turlarni QATTIQ ro'yxatdan o'qirdi —
--        foreach v_maydon in array array['cash','click','payme','dollar_usd']
--     ya'ni n8n `terminal` yuborsa ham u JIMGINA e'tiborsiz qolardi va pul
--     yo'qolardi. Aynan shu «jimgina tashlab yuborish» bugungi falokatning
--     ildizi edi — takrorlanmasin.
--
--  🔴 PROVODKA_TRANSFER_CUTOFF_FIX.sql (749-1202) dagi tananing VERBATIM
--     nusxasi. Farqlar FAQAT ikkita:
--       a) tur ro'yxatiga 'terminal' qo'shildi;
--       b) summa o'qishga `when 'terminal' then ...` shoxi qo'shildi.
--     Anonim dollar-teg nomlanganga o'tkazildi (CLAUDE.md).
--     `aros_tr_fix:` yorlig'i `else v_maydon` orqali 'terminal' ni o'zi oladi.
--
--  ⚠️ TARTIB: bu bo'lim 2-BO'LIM (bola-hisoblar) va 3-BO'LIM
--     (aros_tur_hisob) dan KEYIN bajarilishi shart — aks holda RPC
--     terminal hisobini topolmay «hisob yo'q» deb ogohlantiradi.

create or replace function sync_transfer_balans(p_data jsonb,
                                               p_dry_run boolean default false,
                                               p_from timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $stb$
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
  v_fix_ext     text;                    -- ⭐ YANGI: 'aros_tr_fix:<id>:<tur>' kaliti
  v_natija      jsonb;                   -- ⭐ YANGI: javob (log yozishdan oldin ushlanadi)

  n_jami        int := 0;
  n_yozuv       int := 0;
  n_takror      int := 0;
  n_otkaz       int := 0;
  n_status      int := 0;
  n_eski        int := 0;
  v_ogoh        jsonb := '[]'::jsonb;
  v_tafsil      jsonb := '[]'::jsonb;
  v_eski_ruy    jsonb := '[]'::jsonb;    -- ⭐ YANGI: cutoff bilan tashlanganlar ro'yxati
  n_fix         int := 0;                -- ⭐ YANGI: qo'lda to'g'irlangani uchun o'tkazilgan
begin
  -- ---- 0. Qulflar ---------------------------------------------------
  -- IKKALASI ham olinadi va SHU TARTIBDA. Sabab: transfer yozilayotganda
  -- sync_filial_balans o'rtaga tushsa, u transferni ko'rmagan daftar
  -- ustidan delta hisoblab, o'sha pulni "tushum" deb yozib yuborardi.
  -- Delta sync faqat o'z lock'ini oladi -> deadlock bo'lishi mumkin emas.
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
  -- Chegara = daftar Aros bilan OXIRGI marta tenglashtirilgan payt
  -- (oxirgi delta sync). Undan oldingi transferlar daftarga allaqachon
  -- singib ketgan — ularni yozish IKKI MARTA AYIRISH demak.
  -- Yagona manba: aros_transfer_cutoff() (0.5-bo'lim).
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

  -- p_from berilgan, lekin chegaradan OLDIN edi -> e'tiborsiz qoldirildi.
  -- Jimgina o'tkazib yubormaymiz: qo'lda berilgan sana himoyani ochib
  -- yuborishga urinayotgan bo'lishi mumkin.
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
      -- Aros vaqtni zonasiz (naive, Toshkent vaqtida) saqlaydi -> +05 qo'shamiz.
      -- ⚠️ "Zona bormi" tekshiruvi ehtiyotkor yozilgan: sanadagi tire ('2026-07-30')
      --    zona deb o'qilib qolmasin. Shuning uchun zona faqat VAQT qismidan keyin
      --    tan olinadi, sana-only alohida ko'riladi.
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
    -- `<=` (kichik YOKI TENG): chegara ustidagi transfer ham yozilmaydi.
    -- Konservativ yo'nalish — shubhada yozmaslik.
    if v_cutoff is not null and v_recv <= v_cutoff then
      n_eski := n_eski + 1;
      -- ⭐ YANGI: IZ QOLDIRAMIZ. Avval bu jimgina "continue" edi — 2026-08-12 da
      -- 9 ta transfer (352 835 000 so'm) aynan shu yerda IZSIZ yo'qolgan: javobda
      -- faqat "cutoffdan_eski: 9" raqami turardi. Endi qaysi transfer, qachon,
      -- kimdan-kimga — javobda ham, aros_transfer_dropped logida ham ko'rinadi.
      -- Bu blok PUL YOZMAYDI, faqat ro'yxatga qo'shadi.
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

    -- Qabul qiluvchi markaziy emasmi — bloklamaymiz, faqat aytamiz
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

    -- ---- 4.7 HAR TUR ----
    foreach v_maydon in array array['cash','click','payme','terminal','dollar_usd']
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

      -- ⭐ YANGI: QO'LDA TO'G'IRLANGANMI (aros_tr_fix:<id>:<tur>)
      -- Kalitlar boshqa-boshqa bo'lgani uchun ext_ref UNIQUE buni tutolmaydi,
      -- lekin IKKALASI HAM markaziy kassaga pul kiritadi -> yozilsa IKKI MARTA.
      -- Bu tekshiruv trigger (trg_aros_tr_fix_guard) bilan IKKI QAVAT: trigger
      -- oxirgi to'siq, bu esa toza hisobot beradi (n_fix + ogohlantirish).
      -- `tur` nomlari TUZATISH skriptiniki: naqd | click | payme | dollar.
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
      -- ext_ref UNIQUE: poyga holatida (ikki sync bir vaqtda) ikkinchisi
      -- unique_violation oladi -> takror deb sanaymiz, sync to'xtamaydi.
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
      -- ⚠️ Dollarda IKKALA satr ham valyuta hisobi, shuning uchun fc_amount
      --    ikkalasiga ham yoziladi (musbat). Ishora Dt/Kt dan kelib chiqadi:
      --    v_hisob_bal -> debit>0 ? +fc : −fc.
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
      null;   -- muhr qo'yilmasa ham sync yiqilmasin
    end;
  end if;

  v_natija := jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'sana', to_char(now() at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI:SS'),
    'cutoff', v_cutoff,
    'cutoff_manba', coalesce(v_cutoff_man, '(topilmadi — dry_run)'),
    'cutoff_info', v_cut_info,        -- to'liq diagnostika: muhr, oxirgi/birinchi delta, p_from
    'transferlar', n_jami,
    'yozuvlar', n_yozuv,              -- yozilgan entry soni (transfer × tur)
    'takror', n_takror,               -- allaqachon yozilgan (ext_ref bor)
    'received_emas', n_status,        -- sent/canceled
    'cutoffdan_eski', n_eski,         -- daftarga allaqachon singigan (oxirgi delta syncdan oldin)
    'otkazildi', n_otkaz,
    'qolda_tuzatilgan', n_fix,        -- ⭐ YANGI: aros_tr_fix bor -> ataylab o'tkazildi
    'cutoffdan_eski_royxat', v_eski_ruy,  -- ⭐ YANGI: QAYSI transferlar tashlandi
    'ogohlantirishlar', v_ogoh,
    'tafsilot', v_tafsil,
    'eslatma', 'Delta sync SHUNDAN KEYIN ishlashi shart (balanslarni qayta o''qib).');

  -- ⭐ YANGI: TASHLANGANLARNI LOGGA YOZISH.
  -- Butunlay exception ichida: log yiqilsa ham sinxron va PUL YOZUVI
  -- ta'sirlanmaydi. to_regprocedure — funksiya hali yaratilmagan bo'lsa ham
  -- (eski baza) sinxron ishlayversin.
  if to_regprocedure('public.aros_transfer_drop_yoz(jsonb, boolean)') is not null then
    begin
      perform aros_transfer_drop_yoz(v_natija, p_dry_run);
    exception when others then
      null;
    end;
  end if;

  return v_natija;
end $stb$;
