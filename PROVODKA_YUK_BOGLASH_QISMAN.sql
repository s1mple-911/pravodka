-- =====================================================================
--  PROVODKA_YUK_BOGLASH_QISMAN.sql — bog'lanmagan to'lovni QISMAN bog'lash
--  (Asilbek, 2026-10-28: «30 ming bog'lanmagan bo'lsa shu 30 ming bilan
--   20 minglik yukni yopib, 10 ming yana bog'lanmagan qolsin; yoki 50
--   minglik yukning 30 mingini yopsin — tiyin-tiyin to'g'ri kelishi
--   shart bo'lmasin»)
-- ---------------------------------------------------------------------
--  HOZIRGACHA: bitta to'lov rejimida Σ taqsim = yozuv summasi SHART
--  (yuk_boglash_taqsim ±0.01), ko'p-to'lov rejimida har to'lov TO'LIQ
--  ketadi (yuk_boglash_koplik), yuk qoldig'idan oshsa kod:'qoldiq'.
--  Eski yuk_boglash (V7) esa p_summa < yozuv summasi bo'lsa ham BUTUN
--  9110-1 satrini 9110 ga o'tkazib yuborardi — qoldiq jimgina yo'qolardi
--  (entry_yuk da faqat p_summa, yozuv esa «bog'langan» bo'lib qolardi).
--
--  YECHIM — Dt satrini IKKIGA BO'LISH (yangi entry YARATILMAYDI):
--     to'lov 30 000:   Dt 9110-1 30 000 / Kt kassa 30 000
--     20 000 bog'landi: Dt 9110   20 000  (yangi satr — yukka ketdi)
--                      Dt 9110-1 10 000  (eski satr, kamaytirildi — yo'lda)
--                      Kt kassa  30 000  (TEGILMAYDI)
--  Yozuv jami o'zgarmaydi, Dt = Kt saqlanadi, yuk_kutilmoqda=true QOLADI,
--  «Bog'lanmagan to'lovlar» ro'yxatida u 10 000 bilan turadi va yana
--  bog'lanadi (keyingi bog'lash 9110-1 qoldig'idan hisoblanadi).
--
--  Nega yangi entry emas: qoldiq uchun yangi yozuv ochish Kt kassa satrini
--  ham bo'lishni talab qiladi — kassa satri insert'i perm_guard (bog'lovchi
--  user o'sha kassaga ruxsatli bo'lmasligi mumkin), bal_guard (kassa
--  qoldig'i), trg_kurs_farqi (avto kurs farqi yozuvi), hodim_notify
--  («pul chiqdi» xabari) qorovullaridan o'tishi kerak — bu pul harakati
--  EMAS, shuning uchun u yo'l rad etildi. Dt satrini bo'lishda esa faqat
--  9110 satri insert bo'ladi — bu bugungi `9110-1 -> 9110` update'i bilan
--  AYNAN bir xil qorovul talabini (rbac_guard: 9110 moddasi rolda yoki
--  admin) qo'yadi, yangi talab tug'ilmaydi. 9110-1 satrining `debit`i
--  kamaytiriladi — perm/rbac guard `update of account_id` ga ulangan,
--  debit o'zgarishi ularni ishga tushirmaydi; hodim_notify/kurs_farqi
--  kredit satrlarga qaraydi (bu yerda debit). check_entry_balanced
--  DEFERRED — commit paytida Dt = Kt tekshiradi, u saqlanadi.
--
--  ⚠️ Ma'lum yon ta'sir: qisman bog'langan yozuv 3 (yoki ko'proq) satrli
--  bo'ladi — jurnalda u «ko'p satrli» ko'rinishda chiqadi va qalam
--  (tahrir faqat 2 satrli yozuvga) ko'rinmaydi. Bekor qilinsa satrlar
--  yana bitta 9110-1 ga QO'SHILADI va yozuv 2 satrli holiga qaytadi.
--
--  #####  FAYL TARKIBI  ###################################################
--     0-BO'LIM — old shart tekshiruvi
--     1-BO'LIM — _yuk_boglash_satr(...)      ICHKI: Dt satr(lar)ini bo'lish/o'tkazish
--                _yuk_tannarx_kalit(...)     ICHKI: tannarx kaliti (takror bog'lash)
--     2-BO'LIM — yuk_boglash_qisman(p_entry, p_taqsim, p_qoldiq, p_limit_ogoh)  YANGI
--     3-BO'LIM — yuk_boglash_koplik (QAYTA, imzo o'sha) + yuk_boglash_koplik_qisman (YANGI)
--     4-BO'LIM — yuk_boglash (V7, QAYTA, imzo o'sha) — qisman-aware
--     5-BO'LIM — yuk_kutayotgan / yuk_kutayotgan_v2 (QAYTA) — summa = 9110-1 qoldig'i
--     6-BO'LIM — yuk_boglash_bekor (QAYTA, imzo o'sha) — qisman yozuvni to'g'ri qaytaradi
--     7-BO'LIM — DIAG + PostgREST
--
--  #####  QOIDALAR  #######################################################
--   * ADDITIVE: hech qanday funksiya o'chirilmaydi, imzo o'zgarmaydi.
--     `create or replace` eski imzo bilan; yangi nomlar: yuk_boglash_qisman,
--     yuk_boglash_koplik_qisman. OVERLOAD YO'Q (PostgREST PGRST203
--     noaniqligi bo'lmasin).
--   * Xato kodlari eskisi bilan bir xil + `qoldiq_kichik` (bo'linganda
--     qoladigan 9110-1 qismi 1 so'mdan kichik — tiyin changi qolmasin).
--   * Idempotent/tranzaksion: ichki BEGIN/EXCEPTION (savepoint),
--     {ok:false,kod} qaytsa HECH NARSA yozilmaydi. Advisory lock.
--   * Dollar-teglar NOMLI (izohda dollar-qavs yo'q).
--   * 🔴 SQL'ni ASILBEK RUN qiladi. Supabase SQL editorida bitta fayl.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI                                 ##
-- #####################################################################

do $yq_pre$
begin
  if to_regprocedure('public.yuk_boglash(uuid,integer,numeric)') is null then
    raise exception 'yuk_boglash() yoq — avval PROVODKA_V7.sql ni bajaring';
  end if;
  if to_regprocedure('public.yuk_boglash_taqsim(uuid,jsonb,jsonb,boolean)') is null then
    raise exception 'yuk_boglash_taqsim() yoq — avval PROVODKA_YUK_PROF_TANNARX.sql ni bajaring';
  end if;
  if to_regprocedure('public.yuk_boglash_koplik(uuid[],integer,numeric)') is null then
    raise exception 'yuk_boglash_koplik() yoq — avval PROVODKA_YUK_BOGLANMAGAN_V2.sql ni bajaring';
  end if;
  if to_regprocedure('public.yuk_boglash_bekor(uuid,integer)') is null then
    raise exception 'yuk_boglash_bekor() yoq — avval PROVODKA_YUK_BOGLASH_BEKOR.sql ni bajaring';
  end if;
  if to_regprocedure('public.yuk_tannarx_qosh(jsonb,integer,text,text,boolean)') is null then
    raise exception 'yuk_tannarx_qosh(5-arg) yoq — avval PROVODKA_YUK_PROF_TANNARX.sql ni bajaring';
  end if;
  if to_regclass('public.entry_yuk') is null then
    raise exception 'entry_yuk jadvali yoq — avval PROVODKA_YUK_QISMAN.sql ni bajaring';
  end if;
  if not exists (select 1 from accounts where code = '9110-1') then
    raise exception '9110-1 "Yoldagi tovar" hisobi yoq — avval PROVODKA_V7.sql ni bajaring';
  end if;
end
$yq_pre$;


-- #####################################################################
-- ##  1-BO'LIM — ICHKI YORDAMCHILAR                                   ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 1.1 _yuk_boglash_satr(p_entry, p_summa, p_9110, p_9110_1)
--     Yozuvdagi 9110-1 Dt satr(lar)idan p_summa ni 9110 ga o'tkazadi.
--       * p_summa >= qoldiq (±0.01)  → hamma 9110-1 satri 9110 ga (eski yo'l, TO'LIQ)
--       * p_summa <  qoldiq          → satr IKKIGA bo'linadi:
--             eski satr: debit = debit − p_summa (9110-1 da qoladi)
--             yangi satr: Dt 9110 p_summa (fc_amount bo'lsa proporsional)
--         (9110-1 satri bir nechta bo'lsa — kattasidan boshlab yopiladi)
--     Qaytadi: {toliq bool, qoldiq numeric, satrlar jsonb}
--     Tekshiruvni CHAQIRUVCHI qiladi (bu funksiya faqat yozadi), xato
--     bo'lsa raise — chaqiruvchining savepoint'i hamma yozuvni bekor qiladi.
--     ICHKI: authenticated/anon chaqira olmaydi.
-- ---------------------------------------------------------------------
create or replace function _yuk_boglash_satr(p_entry uuid, p_summa numeric,
                                             p_9110 uuid, p_9110_1 uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $yq_satr$
declare
  v_qoldiq  numeric;
  v_left    numeric;
  r         record;
  v_fc_take numeric;
  v_new     uuid;
  v_rows    jsonb := '[]'::jsonb;
begin
  if p_summa is null or p_summa <= 0 then
    raise exception '_yuk_boglash_satr: summa musbat bolishi kerak';
  end if;

  select coalesce(sum(debit), 0) into v_qoldiq
    from entry_line where entry_id = p_entry and account_id = p_9110_1 and debit > 0;
  if v_qoldiq <= 0 then
    raise exception '_yuk_boglash_satr: 9110-1 satri yoq';
  end if;
  if p_summa > v_qoldiq + 0.01 then
    raise exception '_yuk_boglash_satr: summa 9110-1 qoldigidan oshdi (% > %)', p_summa, v_qoldiq;
  end if;

  -- TO'LIQ: eski xatti-harakat — barcha yo'ldagi satrlar 9110 ga o'tadi
  if p_summa >= v_qoldiq - 0.01 then
    update entry_line set account_id = p_9110
     where entry_id = p_entry and account_id = p_9110_1 and debit > 0;
    return jsonb_build_object('toliq', true, 'qoldiq', 0, 'otkazildi', v_qoldiq);
  end if;

  -- QISMAN: kattasidan boshlab
  v_left := round(p_summa, 2);
  for r in
    select id, debit, fc_amount from entry_line
     where entry_id = p_entry and account_id = p_9110_1 and debit > 0
     order by debit desc, id
  loop
    exit when v_left <= 0;
    if r.debit <= v_left + 0.005 then
      -- butun satr ketadi
      update entry_line set account_id = p_9110 where id = r.id;
      v_rows := v_rows || jsonb_build_object('id', r.id, 'amal', 'otkazildi', 'summa', r.debit);
      v_left := v_left - r.debit;
    else
      -- satr ikkiga bo'linadi
      v_fc_take := case when r.fc_amount is null then null
                        else round(r.fc_amount * v_left / r.debit, 2) end;
      update entry_line
         set debit     = r.debit - v_left,
             fc_amount = case when r.fc_amount is null then null else r.fc_amount - v_fc_take end
       where id = r.id;
      insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
      values (p_entry, p_9110, v_left, 0, v_fc_take)
      returning id into v_new;
      v_rows := v_rows || jsonb_build_object('id', r.id, 'amal', 'kamaytirildi',
                                             'qoldi', r.debit - v_left, 'yangi_id', v_new,
                                             'summa', v_left);
      v_left := 0;
    end if;
  end loop;

  return jsonb_build_object('toliq', false, 'qoldiq', round(v_qoldiq - p_summa, 2),
                            'otkazildi', p_summa, 'satrlar', v_rows);
end
$yq_satr$;

revoke all on function _yuk_boglash_satr(uuid, numeric, uuid, uuid) from public, anon, authenticated;

comment on function _yuk_boglash_satr(uuid, numeric, uuid, uuid) is
  'ICHKI. Yozuvdagi 9110-1 Dt satridan p_summa ni 9110 ga otkazadi: qoldiqqa teng bolsa satr '
  'otkaziladi (eski yol), kam bolsa satr ikkiga bolinadi (9110 yangi satr + 9110-1 kamayadi). '
  'Kt satr tegilmaydi, yozuv jami ozgarmaydi.';


-- ---------------------------------------------------------------------
-- 1.2 _yuk_tannarx_kalit(p_entry) — xizmat to'lovi tannarx kaliti
--     Birinchi bog'lash: 'entry:<id>' (eskisi bilan bir xil — bekor tanidi).
--     Yozuv QISMAN bog'lanib yana bog'lansa shu kalit band bo'ladi
--     (yuk_tannarx_qosh idempotent — ikkinchi qismni YOZMAY qo'yardi),
--     shuning uchun 'entry:<id>:2', ':3' … beriladi. yuk_boglash_bekor
--     ikkala shaklni ham bekor qiladi (kalit like 'entry:<id>%').
-- ---------------------------------------------------------------------
create or replace function _yuk_tannarx_kalit(p_entry uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $yq_kalit$
declare
  v_base text := 'entry:' || p_entry::text;
  v_i    int  := 2;
begin
  if not exists (select 1 from yuk_tannarx where kalit = v_base and not is_deleted) then
    return v_base;
  end if;
  while exists (select 1 from yuk_tannarx where kalit = v_base || ':' || v_i and not is_deleted) loop
    v_i := v_i + 1;
    if v_i > 500 then
      raise exception '_yuk_tannarx_kalit: juda kop takror bog''lash (%)', p_entry;
    end if;
  end loop;
  return v_base || ':' || v_i;
end
$yq_kalit$;

revoke all on function _yuk_tannarx_kalit(uuid) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 1.3 _yuk_qoldiq_summa(p_entry, p_9110_1) — yozuvning HALI BOG'LANMAGAN
--     qismi = 9110-1 Dt satrlari yig'indisi. 9110-1 satri yo'q bo'lsa 0.
-- ---------------------------------------------------------------------
create or replace function _yuk_qoldiq_summa(p_entry uuid, p_9110_1 uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $yq_qs$
  select coalesce(sum(debit), 0) from entry_line
   where entry_id = p_entry and account_id = p_9110_1 and debit > 0;
$yq_qs$;

revoke all on function _yuk_qoldiq_summa(uuid, uuid) from public, anon, authenticated;


-- #####################################################################
-- ##  2-BO'LIM — yuk_boglash_qisman(p_entry, p_taqsim, p_qoldiq,     ##
-- ##             p_limit_ogoh)                                       ##
-- #####################################################################
-- yuk_boglash_taqsim ning nusxasi, FARQ:
--   * «yozuv summasi» = 9110-1 QOLDIG'I (butun entry summasi emas —
--     oldin qisman bog'langan yozuvda farq qiladi).
--   * Σ taqsim <  qoldiq  → QISMAN: Dt satr ikkiga bo'linadi, yozuv
--                           yuk_kutilmoqda=true QOLADI, ro'yxatda qoladi.
--   * Σ taqsim =  qoldiq  → TO'LIQ (eski taqsim bilan bir xil natija).
--   * Σ taqsim >  qoldiq  → kod:'summa_notogri' (avvalgidek).
--   * 0.01 < qoldiq − Σ < 1 → kod:'qoldiq_kichik' (tiyin changi qolmasin).
--   * Sababli (xizmat) to'lov: tannarx qatori Σ bilan, kalit
--     _yuk_tannarx_kalit (takror bog'lashda ':2', ':3').
-- Xato kodlari: topilmadi|ochirilgan|holat|yolda_emas|satr_yoq|hisob_yoq|
--   bosh|kop|notogri|summa_notogri|qoldiq_kichik|qoldiq|tannarx_ruxsat|
--   limit|tannarx_xato|xato.
create or replace function yuk_boglash_qisman(p_entry uuid,
                                              p_taqsim jsonb,
                                              p_qoldiq jsonb default null,
                                              p_limit_ogoh boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $yq_qisman$
declare
  v_who       text;
  v_n         int;
  el          jsonb;
  v_yuk       integer;
  v_sum       numeric;
  v_key       text;
  v_val       jsonb;
  v_map       jsonb := '{}'::jsonb;
  v_total     numeric := 0;
  v_entry_sum numeric;     -- 9110-1 qoldig'i (bog'lanmagan qism)
  v_jami      numeric;     -- butun yozuv Dt yig'indisi (faqat hisobot uchun)
  v_qoldi     numeric;     -- bog'lashdan keyin qoladigan 9110-1 qismi
  v_deleted   boolean;
  v_kutil     boolean;
  v_status    text;
  v_sabab     integer;
  v_desc      text;
  v_9110      uuid;
  v_9110_1    uuid;
  v_snap      jsonb;
  v_satr      jsonb;
  v_ids       integer[] := '{}'::integer[];
  v_nomlar    text := '';
  v_tan       jsonb := null;
  v_kalit     text;
  v_warn      jsonb := '[]'::jsonb;
  v_qoldiq    numeric;
  v_err       jsonb := null;
begin
  if p_entry is null then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi', 'error', 'Yozuv tanlanmadi');
  end if;

  if p_taqsim is null or jsonb_typeof(p_taqsim) <> 'array' then
    return jsonb_build_object('ok', false, 'kod', 'bosh',
      'error', 'p_taqsim massiv bolishi kerak: [{"yuk_id":1204,"summa":5000000}]');
  end if;

  v_n := jsonb_array_length(p_taqsim);
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'kod', 'bosh', 'error', 'Birorta yuk tanlanmagan');
  end if;
  if v_n > 100 then
    return jsonb_build_object('ok', false, 'kod', 'kop',
      'error', 'Bir marta eng kopi 100 ta yuk. Hozir: ' || v_n);
  end if;

  select id into v_9110_1 from accounts where code = '9110-1' limit 1;
  select id into v_9110   from accounts where code = '9110'   limit 1;
  if v_9110 is null or v_9110_1 is null then
    return jsonb_build_object('ok', false, 'kod', 'hisob_yoq',
      'error', '9110/9110-1 hisoblari topilmadi');
  end if;

  select coalesce(full_name, '') into v_who from profiles where id = auth.uid();

  -- Bitta yozuv ustida parallel ikki bog'lash bo'lmasin (taqsim/koplik bilan bir xil lock)
  perform pg_advisory_xact_lock(hashtext('yuk_boglash_taqsim'));

  begin  -- ichki blok: xato bolsa SHU BLOKDAGI hamma yozuv bekor (savepoint)

    -- ===== 1-BOSQICH: tekshiruv (yozishdan OLDIN) =====
    select is_deleted, coalesce(yuk_kutilmoqda, false), status, yuk_sabab_id, description
      into v_deleted, v_kutil, v_status, v_sabab, v_desc
      from entry where id = p_entry;
    if not found then
      v_err := jsonb_build_object('ok', false, 'kod', 'topilmadi', 'error', 'Yozuv topilmadi');
      raise exception 'yuk_boglash_qisman: topilmadi';
    end if;
    if v_deleted then
      v_err := jsonb_build_object('ok', false, 'kod', 'ochirilgan',
                                   'error', 'O''chirilgan yozuvni bog''lab bo''lmaydi');
      raise exception 'yuk_boglash_qisman: ochirilgan';
    end if;
    if coalesce(v_status, '') <> 'posted' then
      v_err := jsonb_build_object('ok', false, 'kod', 'holat',
                                   'error', 'Yozuv holati posted emas: ' || coalesce(v_status, 'null'));
      raise exception 'yuk_boglash_qisman: holat';
    end if;
    if not v_kutil then
      v_err := jsonb_build_object('ok', false, 'kod', 'yolda_emas',
                                   'error', 'Bu yozuv hujjat kutmayapti (allaqachon bog''langan yoki oddiy yozuv)');
      raise exception 'yuk_boglash_qisman: yolda_emas';
    end if;

    select coalesce(sum(debit), 0) into v_jami from entry_line where entry_id = p_entry;
    v_entry_sum := _yuk_qoldiq_summa(p_entry, v_9110_1);
    if v_entry_sum <= 0 then
      v_err := jsonb_build_object('ok', false, 'kod', 'satr_yoq',
                                   'error', 'Bu yozuvda "yo''ldagi tovar" (9110-1) satri yo''q');
      raise exception 'yuk_boglash_qisman: satr_yoq';
    end if;

    -- Taqsimotni tekshirish + bir xil yuk_id larni birlashtirish
    for el in select value from jsonb_array_elements(p_taqsim) loop
      v_yuk := null;
      v_sum := null;
      begin
        v_yuk := nullif(el ->> 'yuk_id', '')::integer;
        v_sum := nullif(el ->> 'summa', '')::numeric;
      exception when others then
        v_yuk := null;
      end;
      if v_yuk is null or v_sum is null or v_sum <= 0 then
        v_err := jsonb_build_object('ok', false, 'kod', 'notogri',
                                     'error', 'Taqsimotda notogri qator: ' || coalesce(el::text, 'null'));
        raise exception 'yuk_boglash_qisman: notogri';
      end if;
      v_sum := round(v_sum, 2);
      v_key := v_yuk::text;
      if v_map ? v_key then
        v_sum := v_sum + coalesce((v_map -> v_key ->> 'summa')::numeric, 0);
      end if;
      v_map := v_map || jsonb_build_object(v_key, jsonb_build_object('summa', v_sum));
    end loop;

    select coalesce(sum((value ->> 'summa')::numeric), 0) into v_total from jsonb_each(v_map);

    -- Σ taqsim bog'lanmagan qismdan OSHMASIN (1 tiyin xatolikka yol qoyiladi)
    if v_total > v_entry_sum + 0.01 then
      v_err := jsonb_build_object('ok', false, 'kod', 'summa_notogri',
                                   'error', 'Taqsimot yozuvning bog''lanmagan qismidan oshib ketdi',
                                   'kerak', v_entry_sum, 'berilgan', v_total);
      raise exception 'yuk_boglash_qisman: summa_notogri';
    end if;

    v_qoldi := round(v_entry_sum - v_total, 2);
    if v_qoldi <= 0.01 then
      v_qoldi := 0;                                   -- to'liq
    elsif v_qoldi < 1 then
      v_err := jsonb_build_object('ok', false, 'kod', 'qoldiq_kichik',
                                   'error', 'Bo''lgandan keyin 1 so''mdan kam qoldiq qoladi — summani to''g''rilang yoki to''liq bog''lang',
                                   'qoldiq', v_qoldi, 'kerak', v_entry_sum, 'berilgan', v_total);
      raise exception 'yuk_boglash_qisman: qoldiq_kichik';
    end if;

    -- Tovar to'lovi (sababsiz) har yuk qoldig'idan oshmasin (klient beradi).
    -- Xizmat to'lovi (sabab bor) tekshirilmaydi: u tannarxni O'ZI oshiradi.
    if v_sabab is null and p_qoldiq is not null and jsonb_typeof(p_qoldiq) = 'object' then
      for v_key, v_val in select key, value from jsonb_each(v_map) order by key::integer loop
        v_qoldiq := nullif(p_qoldiq ->> v_key, '')::numeric;
        v_sum    := (v_val ->> 'summa')::numeric;
        if v_qoldiq is not null and v_sum > v_qoldiq + 0.01 then
          v_err := jsonb_build_object('ok', false, 'kod', 'qoldiq',
                                       'error', 'Yuk #' || v_key || ': to''lov yuk qoldig''idan oshib ketdi',
                                       'yuk_id', v_key::integer, 'summa', v_sum, 'qoldiq_uzs', v_qoldiq);
          raise exception 'yuk_boglash_qisman: qoldiq';
        end if;
      end loop;
    end if;

    -- ===== 2-BOSQICH: yozish =====
    select to_jsonb(e) into v_snap from entry e where e.id = p_entry;

    for v_key, v_val in select key, value from jsonb_each(v_map) order by key::integer loop
      v_yuk := v_key::integer;
      v_sum := (v_val ->> 'summa')::numeric;

      insert into entry_yuk (entry_id, yuk_id, summa_uzs)
      values (p_entry, v_yuk, v_sum)
      on conflict (entry_id, yuk_id) do update
        set summa_uzs = entry_yuk.summa_uzs + excluded.summa_uzs;

      v_ids    := v_ids || v_yuk;
      v_nomlar := case when v_nomlar = '' then '' else v_nomlar || ', ' end
                  || '#' || v_yuk || ' — '
                  || replace(to_char(v_sum, 'FM999G999G999G999'), ',', ' ');
    end loop;

    -- Dt satr(lar): to'liq → 9110 ga o'tadi; qisman → ikkiga bo'linadi
    v_satr := _yuk_boglash_satr(p_entry, v_total, v_9110, v_9110_1);

    update entry
       set yuk_kutilmoqda = (v_qoldi > 0),            -- qisman bo'lsa ro'yxatda QOLADI
           yuk_ids = (select coalesce(array_agg(distinct x), '{}'::integer[])
                        from unnest(coalesce(yuk_ids, '{}'::integer[]) || v_ids) x),
           edited_at = now(),
           edited_by_name = v_who
     where id = p_entry;

    insert into entry_history (entry_id, action, snapshot, changed_by_name)
    values (p_entry, 'edit',
            jsonb_build_object('note', case when v_qoldi > 0
                                 then 'Yukka QISMAN bog''landi: ' || v_nomlar
                                      || ' · bog''lanmagan qoldi '
                                      || replace(to_char(v_qoldi, 'FM999G999G999G999D00'), ',', ' ')
                                 else 'Yukka bog''landi (taqsim): ' || v_nomlar end,
                               'summa_uzs', v_total, 'qoldiq_uzs', v_qoldi,
                               'qisman', (v_qoldi > 0), 'satrlar', v_satr, 'old', v_snap),
            v_who);

    -- Xizmat to'lovi bo'lsa — tannarx qatorlari (BITTA chaqiruv, massiv bilan).
    if v_sabab is not null then
      v_kalit := _yuk_tannarx_kalit(p_entry);
      v_tan := yuk_tannarx_qosh(
        (select coalesce(jsonb_agg(jsonb_build_object(
                  'yuk_id', key::integer, 'summa', (value ->> 'summa')::numeric)
                  order by key::integer), '[]'::jsonb)
           from jsonb_each(v_map)),
        v_sabab, v_desc, v_kalit, p_limit_ogoh);

      if coalesce((v_tan ->> 'ok')::boolean, false) is not true then
        if v_tan ? 'kod' then
          v_err := v_tan;
        elsif position('ruxsat' in coalesce(v_tan ->> 'error', '')) > 0 then
          v_err := v_tan || jsonb_build_object('kod', 'tannarx_ruxsat');
        else
          v_err := v_tan || jsonb_build_object('kod', 'tannarx_xato');
        end if;
        raise exception 'yuk_boglash_qisman: tannarx';
      end if;
      v_warn := v_warn || coalesce(v_tan -> 'ogohlantirishlar', '[]'::jsonb);
    end if;

  exception when others then
    if v_err is not null then
      return v_err;
    end if;
    return jsonb_build_object('ok', false, 'kod', 'xato', 'error', sqlerrm);
  end;

  return jsonb_build_object(
    'ok',         true,
    'entry_id',   p_entry,
    'yuk_ids',    to_jsonb(v_ids),
    'sabab_id',   v_sabab,
    'qisman',     (v_qoldi > 0),
    'boglandi_uzs', v_total,
    'qoldiq_uzs', v_qoldi,
    'jami_uzs',   v_jami,
    'tovar_uzs',  case when v_sabab is null then v_total else 0 end,
    'xizmat_uzs', case when v_sabab is null then 0 else v_total end,
    'tannarx',    v_tan,
    'ogohlantirishlar', v_warn);
end
$yq_qisman$;

revoke all on function yuk_boglash_qisman(uuid, jsonb, jsonb, boolean) from public, anon;
grant execute on function yuk_boglash_qisman(uuid, jsonb, jsonb, boolean) to authenticated;

comment on function yuk_boglash_qisman(uuid, jsonb, jsonb, boolean) is
  'BITTA bog''lanmagan to''lovni bir nechta yukka taqsimlab bog''laydi — yuk_boglash_taqsim kabi, lekin '
  'Σ taqsim yozuvning bog''lanmagan (9110-1) qismidan KAM bolishi mumkin: Dt satr ikkiga bolinadi '
  '(9110 Σ + 9110-1 qoldiq), yuk_kutilmoqda=true qoladi, qoldiq keyin yana boglanadi. '
  'Σ > qoldiq → summa_notogri; qoldiq 1 somdan kam → qoldiq_kichik. Atomik.';


-- #####################################################################
-- ##  3-BO'LIM — yuk_boglash_koplik (QAYTA) + yuk_boglash_koplik_qisman ##
-- #####################################################################
-- Ikkalasi bitta ICHKI implementatsiyaga tayanadi. Farq p_qisman:
--   false (eski yuk_boglash_koplik, imzo o'sha): tovar Σ > p_qoldiq_uzs
--         bo'lsa kod:'qoldiq' (avvalgidek). Yagona o'zgarish — har to'lov
--         summasi endi 9110-1 QOLDIG'I (oldin qisman bog'langan yozuvda
--         butun summa ikki marta hisoblanmasin).
--   true  (yuk_boglash_koplik_qisman): to'lovlar BERILGAN TARTIBDA
--         bog'lanadi; tovar byudjeti (p_qoldiq_uzs) tugaydigan to'lov
--         QISMAN bog'lanadi (qoldig'i bog'lanmagan qoladi), undan keyingi
--         tovar to'lovlari umuman bog'lanmaydi (`boglanmadi[]`). Xizmat
--         to'lovlari cheklanmaydi (tannarxga qo'shiladi). Hech biri
--         bog'lanmasa → kod:'qoldiq'.
create or replace function _yuk_boglash_koplik_impl(p_entries uuid[], p_yuk_id integer,
                                                    p_qoldiq_uzs numeric, p_qisman boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $yq_kimpl$
declare
  v_who        text;
  v_entries    uuid[];
  v_n          int;
  v_entry_id   uuid;
  v_deleted    boolean;
  v_kutil      boolean;
  v_sabab      integer;
  v_desc       text;
  v_entry_sum  numeric;
  v_take       numeric;
  v_budget     numeric;
  v_9110       uuid;
  v_9110_1     uuid;
  v_snap       jsonb;
  v_satr       jsonb;
  v_kalit      text;
  v_tovar_uzs  numeric := 0;
  v_xizmat_uzs numeric := 0;
  v_boglandi   int := 0;
  v_qisman_id  uuid := null;
  v_qisman_uzs numeric := 0;
  v_boglanmadi jsonb := '[]'::jsonb;
  v_tan_rows   jsonb := '[]'::jsonb;
  v_boj_res    jsonb;
  v_err        jsonb := null;
begin
  if p_yuk_id is null then
    return jsonb_build_object('ok', false, 'kod', 'yuk_yoq', 'error', 'Yuk tanlanmadi');
  end if;

  -- Takrorlar va nullar tashlanadi, TARTIB saqlanadi (birinchi uchrashi qoladi)
  select array_agg(x order by ord) into v_entries
    from (select x, min(ord) as ord
            from unnest(p_entries) with ordinality as t(x, ord)
           where x is not null group by x) s;
  if v_entries is null or array_length(v_entries, 1) is null or array_length(v_entries, 1) = 0 then
    return jsonb_build_object('ok', false, 'kod', 'bosh', 'error', 'Birorta to''lov tanlanmagan');
  end if;
  v_n := array_length(v_entries, 1);
  if v_n > 300 then
    return jsonb_build_object('ok', false, 'kod', 'kop', 'error', 'Bir marta eng ko''pi 300 ta to''lov');
  end if;

  select id into v_9110_1 from accounts where code = '9110-1' limit 1;
  select id into v_9110   from accounts where code = '9110'   limit 1;
  if v_9110 is null or v_9110_1 is null then
    return jsonb_build_object('ok', false, 'kod', 'hisob_yoq', 'error', '9110/9110-1 hisoblari topilmadi');
  end if;

  select coalesce(full_name, '') into v_who from profiles where id = auth.uid();

  perform pg_advisory_xact_lock(hashtext('yuk_boglash_koplik'));

  begin  -- ichki blok: xato bo'lsa SHU BLOKDAGI hamma yozuv bekor (savepoint)

    -- 1-BOSQICH: tekshiruv + tovar/xizmat summasi (yozishdan OLDIN)
    foreach v_entry_id in array v_entries loop
      select is_deleted, coalesce(yuk_kutilmoqda, false), yuk_sabab_id
        into v_deleted, v_kutil, v_sabab
        from entry where id = v_entry_id;
      if not found then
        v_err := jsonb_build_object('ok', false, 'kod', 'topilmadi',
                                     'error', 'Yozuv topilmadi', 'entry_id', v_entry_id);
        raise exception 'yuk_boglash_koplik: topilmadi';
      end if;
      if v_deleted then
        v_err := jsonb_build_object('ok', false, 'kod', 'ochirilgan',
                                     'error', 'O''chirilgan yozuvni bog''lab bo''lmaydi', 'entry_id', v_entry_id);
        raise exception 'yuk_boglash_koplik: ochirilgan';
      end if;
      if not v_kutil then
        v_err := jsonb_build_object('ok', false, 'kod', 'yolda_emas',
                                     'error', 'Bu yozuv hujjat kutmayapti (allaqachon bog''langan yoki oddiy yozuv)',
                                     'entry_id', v_entry_id);
        raise exception 'yuk_boglash_koplik: yolda_emas';
      end if;

      v_entry_sum := _yuk_qoldiq_summa(v_entry_id, v_9110_1);
      if v_entry_sum <= 0 then
        v_err := jsonb_build_object('ok', false, 'kod', 'satr_yoq',
                                     'error', 'Bu yozuvda "yo''ldagi tovar" (9110-1) satri yo''q', 'entry_id', v_entry_id);
        raise exception 'yuk_boglash_koplik: satr_yoq';
      end if;

      if v_sabab is null then
        v_tovar_uzs := v_tovar_uzs + v_entry_sum;
      else
        v_xizmat_uzs := v_xizmat_uzs + v_entry_sum;
      end if;
    end loop;

    -- Tovar qismi yuk qoldig'idan oshmasin (klientdan kelgan qiymat bilan)
    if p_qoldiq_uzs is not null and v_tovar_uzs > p_qoldiq_uzs + 0.01 then
      if not p_qisman then
        v_err := jsonb_build_object('ok', false, 'kod', 'qoldiq',
                                     'error', 'Tovar to''lovlari yuk qoldig''idan oshib ketdi',
                                     'tovar_uzs', v_tovar_uzs, 'qoldiq_uzs', p_qoldiq_uzs);
        raise exception 'yuk_boglash_koplik: qoldiq';
      end if;
      if p_qoldiq_uzs < 1 then
        v_err := jsonb_build_object('ok', false, 'kod', 'qoldiq',
                                     'error', 'Yukda bog''lash uchun qoldiq yo''q',
                                     'tovar_uzs', v_tovar_uzs, 'qoldiq_uzs', p_qoldiq_uzs);
        raise exception 'yuk_boglash_koplik: qoldiq';
      end if;
    end if;
    v_budget := case when p_qisman and p_qoldiq_uzs is not null then round(p_qoldiq_uzs, 2) else null end;
    v_tovar_uzs := 0;   -- yozish bosqichida haqiqiy bog'langan summa qayta yig'iladi

    -- 2-BOSQICH: yozish (tartib bilan)
    foreach v_entry_id in array v_entries loop
      select yuk_sabab_id, description into v_sabab, v_desc from entry where id = v_entry_id;
      v_entry_sum := _yuk_qoldiq_summa(v_entry_id, v_9110_1);
      v_take := v_entry_sum;

      if v_sabab is null and v_budget is not null then
        if v_budget < 1 then
          -- byudjet tugadi — bu to'lov bog'lanmaydi
          v_boglanmadi := v_boglanmadi || jsonb_build_object('entry_id', v_entry_id, 'summa_uzs', v_entry_sum);
          continue;
        end if;
        if v_entry_sum > v_budget + 0.01 then
          v_take := v_budget;
          -- 1 so'mdan kam tiyin qoldig'i qolmasin
          if v_entry_sum - v_take < 1 then v_take := v_entry_sum; end if;
        end if;
        v_budget := v_budget - v_take;
      end if;

      select to_jsonb(e) into v_snap from entry e where e.id = v_entry_id;

      insert into entry_yuk (entry_id, yuk_id, summa_uzs)
      values (v_entry_id, p_yuk_id, v_take)
      on conflict (entry_id, yuk_id) do update
        set summa_uzs = entry_yuk.summa_uzs + excluded.summa_uzs;

      v_satr := _yuk_boglash_satr(v_entry_id, v_take, v_9110, v_9110_1);

      update entry
         set yuk_kutilmoqda = not coalesce((v_satr ->> 'toliq')::boolean, true),
             yuk_ids = case when p_yuk_id = any(coalesce(yuk_ids, '{}'))
                            then yuk_ids else coalesce(yuk_ids, '{}') || p_yuk_id end,
             edited_at = now(),
             edited_by_name = v_who
       where id = v_entry_id;

      insert into entry_history (entry_id, action, snapshot, changed_by_name)
      values (v_entry_id, 'edit',
              jsonb_build_object('note', case when coalesce((v_satr ->> 'toliq')::boolean, true)
                                   then 'Yukka bog''landi (ko''plik): #' || p_yuk_id
                                   else 'Yukka QISMAN bog''landi (ko''plik): #' || p_yuk_id
                                        || ' · bog''lanmagan qoldi '
                                        || replace(to_char((v_satr ->> 'qoldiq')::numeric, 'FM999G999G999G999D00'), ',', ' ') end,
                                 'summa_uzs', v_take,
                                 'qoldiq_uzs', (v_satr ->> 'qoldiq')::numeric,
                                 'qisman', not coalesce((v_satr ->> 'toliq')::boolean, true),
                                 'satrlar', v_satr, 'old', v_snap),
              v_who);

      v_boglandi := v_boglandi + 1;
      if v_sabab is null then
        v_tovar_uzs := v_tovar_uzs + v_take;
      else
        v_xizmat_uzs := v_xizmat_uzs + v_take;
      end if;
      if not coalesce((v_satr ->> 'toliq')::boolean, true) then
        v_qisman_id  := v_entry_id;
        v_qisman_uzs := (v_satr ->> 'qoldiq')::numeric;
      end if;

      if v_sabab is not null then
        v_kalit := _yuk_tannarx_kalit(v_entry_id);
        v_boj_res := yuk_tannarx_qosh(
          jsonb_build_array(jsonb_build_object('yuk_id', p_yuk_id, 'summa', v_take)),
          v_sabab, v_desc, v_kalit);
        if coalesce((v_boj_res ->> 'ok')::boolean, false) is not true then
          if v_boj_res ? 'kod' then
            v_err := v_boj_res;
          elsif position('ruxsat' in coalesce(v_boj_res ->> 'error', '')) > 0 then
            v_err := v_boj_res || jsonb_build_object('kod', 'tannarx_ruxsat');
          else
            v_err := v_boj_res || jsonb_build_object('kod', 'tannarx_xato');
          end if;
          raise exception 'yuk_boglash_koplik: tannarx';
        end if;
        v_tan_rows := v_tan_rows || v_boj_res;
      end if;
    end loop;

    if v_boglandi = 0 then
      v_err := jsonb_build_object('ok', false, 'kod', 'qoldiq',
                                   'error', 'Birorta to''lov bog''lanmadi — yuk qoldig''i yetarli emas',
                                   'qoldiq_uzs', p_qoldiq_uzs);
      raise exception 'yuk_boglash_koplik: hech biri';
    end if;

  exception when others then
    if v_err is not null then
      return v_err;
    end if;
    return jsonb_build_object('ok', false, 'kod', 'xato', 'error', sqlerrm);
  end;

  return jsonb_build_object('ok', true, 'yuk_id', p_yuk_id, 'boglandi', v_boglandi,
    'tovar_uzs', v_tovar_uzs, 'xizmat_uzs', v_xizmat_uzs, 'tannarx_qatorlar', v_tan_rows,
    'qisman_entry_id', v_qisman_id, 'qisman_qoldiq_uzs', v_qisman_uzs,
    'boglanmadi', v_boglanmadi);
end
$yq_kimpl$;

revoke all on function _yuk_boglash_koplik_impl(uuid[], integer, numeric, boolean) from public, anon, authenticated;

-- 3.1 ESKI imzo — xatti-harakat avvalgidek (Σ tovar > qoldiq → kod:'qoldiq')
create or replace function yuk_boglash_koplik(p_entries uuid[], p_yuk_id integer,
                                              p_qoldiq_uzs numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $yq_koplik$
begin
  return _yuk_boglash_koplik_impl(p_entries, p_yuk_id, p_qoldiq_uzs, false);
end
$yq_koplik$;

revoke all on function yuk_boglash_koplik(uuid[], integer, numeric) from public, anon;
grant execute on function yuk_boglash_koplik(uuid[], integer, numeric) to authenticated;

comment on function yuk_boglash_koplik(uuid[], integer, numeric) is
  'Bir nechta bog''lanmagan to''lovni BITTADA bitta yukka bog''laydi (har biri TO''LIQ). Atomik. '
  'p_qoldiq_uzs — klientdan; tovar qismi oshsa kod:qoldiq. 2026-10-28: summa = 9110-1 qoldigi '
  '(qisman boglangan yozuv ikki marta hisoblanmaydi); qisman imkon — yuk_boglash_koplik_qisman.';

-- 3.2 YANGI — oxirgi to'lov qisman, qolgani bog'lanmagan qoladi
create or replace function yuk_boglash_koplik_qisman(p_entries uuid[], p_yuk_id integer,
                                                     p_qoldiq_uzs numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $yq_koplik_q$
begin
  return _yuk_boglash_koplik_impl(p_entries, p_yuk_id, p_qoldiq_uzs, true);
end
$yq_koplik_q$;

revoke all on function yuk_boglash_koplik_qisman(uuid[], integer, numeric) from public, anon;
grant execute on function yuk_boglash_koplik_qisman(uuid[], integer, numeric) to authenticated;

comment on function yuk_boglash_koplik_qisman(uuid[], integer, numeric) is
  'yuk_boglash_koplik kabi, lekin tovar Σ yuk qoldigidan (p_qoldiq_uzs) oshsa xato bermaydi: '
  'tolovlar berilgan tartibda boglanadi, byudjet tugagan tolov QISMAN boglanadi (qoldigi '
  'boglanmagan qoladi), keyingilari boglanmaydi (boglanmadi[]). Xizmat tolovlari cheklanmaydi.';


-- #####################################################################
-- ##  4-BO'LIM — yuk_boglash(p_entry, p_yuk_id, p_summa) — V7 QAYTA   ##
-- #####################################################################
-- Imzo, xato matnlari (errcode 22000) va qaytish shakli AYNAN eskisi.
-- FARQ: p_summa 9110-1 QOLDIG'I bilan cheklanadi (butun yozuv emas) va
-- p_summa < qoldiq bo'lsa satr IKKIGA bo'linadi, yozuv ro'yxatda qoladi
-- (oldin butun satr 9110 ga o'tib, farq jimgina yo'qolardi). Jurnal ⏳
-- modali (jurnal-dev/jurnal) shu funksiyani chaqiradi — HTML tegilmagan,
-- u endi avtomatik qisman-to'g'ri ishlaydi. Tannarx (sabab) bu yo'lda
-- avvalgidek YOZILMAYDI (V7 semantikasi; yuklar-dev endi yuk_boglash_qisman ishlatadi).
create or replace function yuk_boglash(p_entry uuid, p_yuk_id integer, p_summa numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $yq_v7$
declare
  v_deleted   boolean;
  v_kutil     boolean;
  v_entry_sum numeric;
  v_qoldi     numeric;
  v_9110      uuid;
  v_9110_1    uuid;
  v_name      text;
  v_snap      jsonb;
  v_satr      jsonb;
begin
  if p_yuk_id is null then raise exception 'Yuk tanlanmadi' using errcode = '22000'; end if;
  if p_summa is null or p_summa <= 0 then
    raise exception 'Summa musbat bo''lishi kerak' using errcode = '22000';
  end if;

  -- 1) entry holati
  select is_deleted, coalesce(yuk_kutilmoqda, false)
    into v_deleted, v_kutil
    from entry where id = p_entry;
  if not found then raise exception 'Yozuv topilmadi' using errcode = '22000'; end if;
  if v_deleted then raise exception 'O''chirilgan yozuvni bog''lab bo''lmaydi' using errcode = '22000'; end if;
  if not v_kutil then
    raise exception 'Bu yozuv hujjat kutmayapti (allaqachon bog''langan yoki oddiy yozuv)'
      using errcode = '22000';
  end if;

  select id into v_9110_1 from accounts where code = '9110-1' limit 1;
  select id into v_9110   from accounts where code = '9110'   limit 1;
  if v_9110 is null then
    raise exception '9110 "Tovar tannarxi" hisobi topilmadi' using errcode = '22000';
  end if;

  perform pg_advisory_xact_lock(hashtext('yuk_boglash_taqsim'));

  -- bog'lanmagan qism (9110-1 satrlari) va cheklov
  v_entry_sum := _yuk_qoldiq_summa(p_entry, v_9110_1);
  if v_entry_sum <= 0 then
    raise exception 'Bu yozuvda "yo''ldagi tovar" (9110-1) satri yo''q' using errcode = '22000';
  end if;
  if p_summa > v_entry_sum + 0.01 then
    raise exception 'Summa yozuv summasidan oshib ketdi (max % so''m)', v_entry_sum
      using errcode = '22000';
  end if;
  v_qoldi := round(v_entry_sum - p_summa, 2);
  if v_qoldi <= 0.01 then
    v_qoldi := 0;
  elsif v_qoldi < 1 then
    raise exception 'Bo''lgandan keyin 1 so''mdan kam qoldiq qoladi (%) — summani to''g''rilang', v_qoldi
      using errcode = '22000';
  end if;

  -- 2) tahrir izi uchun eski holat
  select to_jsonb(e) into v_snap from entry e where e.id = p_entry;
  select coalesce(full_name, '') into v_name from profiles where id = auth.uid();

  -- 3) entry_yuk (bir yukka takror bog'lansa summa qo'shiladi)
  insert into entry_yuk (entry_id, yuk_id, summa_uzs)
  values (p_entry, p_yuk_id, p_summa)
  on conflict (entry_id, yuk_id) do update
    set summa_uzs = entry_yuk.summa_uzs + excluded.summa_uzs;

  -- 4) Dt satr: to'liq → 9110-1 -> 9110; qisman → ikkiga bo'linadi
  v_satr := _yuk_boglash_satr(p_entry, p_summa, v_9110, v_9110_1);

  -- 5) yuk_kutilmoqda (qisman bo'lsa true qoladi) + yuk_ids + tahrir izi
  update entry
     set yuk_kutilmoqda = (v_qoldi > 0),
         yuk_ids = case when p_yuk_id = any(coalesce(yuk_ids, '{}'))
                        then yuk_ids else coalesce(yuk_ids, '{}') || p_yuk_id end,
         edited_at = now(),
         edited_by_name = v_name
   where id = p_entry;

  -- 6) entry_history (mavjud naqsh)
  insert into entry_history (entry_id, action, snapshot, changed_by_name)
  values (p_entry, 'edit',
          jsonb_build_object('note', case when v_qoldi > 0
                               then 'Yukka QISMAN bog''landi: #' || p_yuk_id || ' · bog''lanmagan qoldi '
                                    || replace(to_char(v_qoldi, 'FM999G999G999G999D00'), ',', ' ')
                               else 'Yukka bog''landi: #' || p_yuk_id end,
                             'summa_uzs', p_summa, 'qoldiq_uzs', v_qoldi,
                             'qisman', (v_qoldi > 0), 'satrlar', v_satr, 'old', v_snap),
          v_name);

  return jsonb_build_object('ok', true, 'entry_id', p_entry,
                            'yuk_id', p_yuk_id, 'summa', p_summa,
                            'qisman', (v_qoldi > 0), 'qoldiq_uzs', v_qoldi);
end
$yq_v7$;

revoke all on function yuk_boglash(uuid, integer, numeric) from public, anon;
grant execute on function yuk_boglash(uuid, integer, numeric) to authenticated;

comment on function yuk_boglash(uuid, integer, numeric) is
  'Yo''ldagi to''lovni (9110-1, yuk_kutilmoqda) Aros yukiga bog''laydi: entry_yuk + Dt 9110-1->9110 + yuk_ids. '
  '2026-10-28: p_summa 9110-1 qoldigidan kam bolsa satr ikkiga bolinadi, yozuv boglanmaganlarda qoladi.';


-- #####################################################################
-- ##  5-BO'LIM — yuk_kutayotgan / yuk_kutayotgan_v2 (QAYTA)           ##
-- #####################################################################
-- «summa» endi = 9110-1 Dt satrlari yig'indisi (bog'lanmagan qism).
-- 9110-1 satri yo'q g'alati yozuvda eski qiymat (butun Dt yig'indisi).
-- v2 ga qo'shildi: summa_jami (butun yozuv), boglangan_uzs (Σ entry_yuk),
-- qisman (bool) va top-level `qisman:true` — klient shu bayroq bilan
-- qisman bog'lash RPC'lari bazada borligini biladi.

create or replace function yuk_kutayotgan()
returns jsonb
language sql
stable
security definer
set search_path = public
as $yq_kut$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb)
  from (
    select e.id as entry_id, e.entry_date, e.created_at, e.description as izoh,
           case when coalesce(q.qoldiq, 0) > 0 then q.qoldiq else coalesce(q.jami, 0) end as summa,
           ka.id as kassa_id, ka.code as kassa_code, ka.name as kassa_name, ka.subtitle as kassa_subtitle,
           coalesce(pr.full_name, '') as kim
      from entry e
      left join lateral (
        select coalesce(sum(el.debit), 0) as jami,
               coalesce(sum(el.debit) filter (where a.code = '9110-1'), 0) as qoldiq
          from entry_line el join accounts a on a.id = el.account_id
         where el.entry_id = e.id and el.debit > 0
      ) q on true
      left join lateral (
        select el.account_id from entry_line el
          join accounts a on a.id = el.account_id
         where el.entry_id = e.id and el.credit > 0 and a.section = 'pul'
         limit 1
      ) kl on true
      left join accounts ka on ka.id = kl.account_id
      left join profiles pr on pr.id::text = e.created_by::text
     where e.yuk_kutilmoqda = true and e.is_deleted = false and e.status = 'posted'
  ) r;
$yq_kut$;

revoke all on function yuk_kutayotgan() from public, anon;
grant execute on function yuk_kutayotgan() to authenticated;

comment on function yuk_kutayotgan() is
  'Bog''lanmagan (yo''ldagi) to''lovlar: yuk_kutilmoqda=true entrylar. 2026-10-28: summa = 9110-1 qoldigi.';


create or replace function yuk_kutayotgan_v2()
returns jsonb
language sql
stable
security definer
set search_path = public
as $yq_kut2$
  select jsonb_build_object(
           'ok',         true,
           'qisman',     true,
           'soni',       coalesce(count(*), 0),
           'jami_summa', coalesce(sum(r.summa), 0),
           'rows',       coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb))
    from (
      select e.id as entry_id, e.ext_ref, e.entry_date, e.created_at, e.status,
             e.description as izoh, e.description,
             case when coalesce(q.qoldiq, 0) > 0 then q.qoldiq else coalesce(q.jami, 0) end as summa,
             coalesce(q.jami, 0) as summa_jami,
             coalesce(b.boglangan, 0) as boglangan_uzs,
             (coalesce(b.boglangan, 0) > 0) as qisman,
             ka.id as kassa_id, ka.code as kassa_code, ka.name as kassa_name, ka.subtitle as kassa_subtitle,
             coalesce(pr.full_name, '') as kim,
             e.yuk_sabab_id as sabab_id, s.nom as sabab_nom, s.ikonka as sabab_ikonka
        from entry e
        left join lateral (
          select coalesce(sum(el.debit), 0) as jami,
                 coalesce(sum(el.debit) filter (where a.code = '9110-1'), 0) as qoldiq
            from entry_line el join accounts a on a.id = el.account_id
           where el.entry_id = e.id and el.debit > 0
        ) q on true
        left join lateral (
          select coalesce(sum(ey.summa_uzs), 0) as boglangan from entry_yuk ey where ey.entry_id = e.id
        ) b on true
        left join lateral (
          select el.account_id from entry_line el
            join accounts a on a.id = el.account_id
           where el.entry_id = e.id and el.credit > 0 and a.section = 'pul'
           limit 1
        ) kl on true
        left join accounts ka on ka.id = kl.account_id
        left join profiles pr on pr.id::text = e.created_by::text   -- entry.created_by TEXT (uuid emas)
        left join yuk_tannarx_sabab s on s.id = e.yuk_sabab_id
       where e.yuk_kutilmoqda = true and e.is_deleted = false and e.status = 'posted'
    ) r;
$yq_kut2$;

revoke all on function yuk_kutayotgan_v2() from public, anon;
grant execute on function yuk_kutayotgan_v2() to authenticated;

comment on function yuk_kutayotgan_v2() is
  'yuk_kutayotgan() + sabab/status/ext_ref/description. 2026-10-28: summa = 9110-1 qoldigi (boglanmagan qism), '
  '+summa_jami, boglangan_uzs, qisman; top-level qisman:true = qisman boglash RPC lari bazada bor.';


-- #####################################################################
-- ##  6-BO'LIM — yuk_boglash_bekor(p_entry, p_yuk_id) — QAYTA         ##
-- #####################################################################
-- Imzo, kodlar va qaytish shakli eskisi. FARQ — qisman bog'langan yozuv:
--   * 9110 Dt satrlari (bir nechta bo'lishi mumkin) 9110-1 ga QAYTADI va
--     bitta satrga QO'SHILADI: mavjud 9110-1 satri bo'lsa unga, bo'lmasa
--     birinchi 9110 satri 9110-1 ga aylanib, qolganlari uning ustiga
--     qo'shiladi; qo'shilgan satrlar o'chiriladi (ular bo'lish paytida
--     yaratilgan texnik satrlar — pul harakati emas; nusxasi entry_history
--     snapshot'ida `satrlar` da qoladi). Natija: yozuv yana 2 satrli.
--   * tannarx: kalit 'entry:<id>' VA 'entry:<id>:N' (takror bog'lash).
-- yuk_boglash_bekor_hammasi / yuk_tolovlari tegilmagan (ular shuni chaqiradi).
create or replace function yuk_boglash_bekor(p_entry uuid, p_yuk_id integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $yq_bekor$
declare
  v_deleted  boolean;
  v_kutil    boolean;
  v_9110     uuid;
  v_9110_1   uuid;
  v_line_id  uuid;
  v_n_yuk    int;
  v_name     text;
  v_snap     jsonb;
  v_summa    numeric;
  v_tan      int := 0;
  r          record;
  v_birl     int := 0;
  v_satrlar  jsonb := '[]'::jsonb;
begin
  if p_entry is null or p_yuk_id is null then
    return jsonb_build_object('ok', false, 'kod', 'argument');
  end if;

  select is_deleted, coalesce(yuk_kutilmoqda, false)
    into v_deleted, v_kutil
    from entry where id = p_entry;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'yozuv_yoq');
  end if;
  if v_deleted then
    return jsonb_build_object('ok', false, 'kod', 'ochirilgan');
  end if;

  select count(*) into v_n_yuk from entry_yuk where entry_id = p_entry;
  if v_n_yuk = 0 then
    return jsonb_build_object('ok', true, 'holat', 'allaqachon', 'entry_id', p_entry);
  end if;
  if v_n_yuk > 1 then
    return jsonb_build_object('ok', false, 'kod', 'kop_yuk', 'soni', v_n_yuk, 'entry_id', p_entry);
  end if;

  select summa_uzs into v_summa from entry_yuk where entry_id = p_entry and yuk_id = p_yuk_id;
  if v_summa is null then
    return jsonb_build_object('ok', false, 'kod', 'boshqa_yuk', 'entry_id', p_entry);
  end if;

  select id into v_9110_1 from accounts where code = '9110-1' limit 1;
  select id into v_9110   from accounts where code = '9110'   limit 1;
  if v_9110 is null or v_9110_1 is null then
    return jsonb_build_object('ok', false, 'kod', 'hisob_yoq');
  end if;

  if not exists (select 1 from entry_line where entry_id = p_entry and account_id = v_9110 and debit > 0) then
    return jsonb_build_object('ok', false, 'kod', 'satr_yoq', 'entry_id', p_entry);
  end if;

  perform pg_advisory_xact_lock(hashtext('yuk_boglash_taqsim'));

  select to_jsonb(e) into v_snap from entry e where e.id = p_entry;
  select coalesce(full_name, '') into v_name from profiles where id = auth.uid();

  -- 1) bog'lanish jadvalidan olib tashlanadi (pul yozuvi emas)
  delete from entry_yuk where entry_id = p_entry and yuk_id = p_yuk_id;

  -- 2) Dt satrlari 9110 -> 9110-1. Nishon satr: mavjud 9110-1 (qisman
  --    bog'langan yozuv), bo'lmasa birinchi 9110 satri (eski yo'l).
  select id into v_line_id from entry_line
   where entry_id = p_entry and account_id = v_9110_1 and debit > 0
   order by debit desc, id limit 1;
  if v_line_id is null then
    select id into v_line_id from entry_line
     where entry_id = p_entry and account_id = v_9110 and debit > 0
     order by debit desc, id limit 1;
    update entry_line set account_id = v_9110_1 where id = v_line_id;
  end if;
  -- qolgan 9110 satrlari nishonga qo'shiladi va o'chiriladi
  for r in
    select id, debit, fc_amount from entry_line
     where entry_id = p_entry and account_id = v_9110 and debit > 0 and id <> v_line_id
     order by id
  loop
    update entry_line
       set debit     = debit + r.debit,
           fc_amount = case when fc_amount is null and r.fc_amount is null then null
                            else coalesce(fc_amount, 0) + coalesce(r.fc_amount, 0) end
     where id = v_line_id;
    v_satrlar := v_satrlar || jsonb_build_object('id', r.id, 'debit', r.debit, 'fc_amount', r.fc_amount);
    delete from entry_line where id = r.id;
    v_birl := v_birl + 1;
  end loop;

  -- 3) yozuv yana «hujjat kutmoqda» holatiga qaytadi
  update entry
     set yuk_kutilmoqda = true,
         yuk_ids = coalesce(array_remove(yuk_ids, p_yuk_id), '{}'),
         edited_at = now(),
         edited_by_name = v_name
   where id = p_entry;

  -- 4) shu to'lov qo'shgan xizmat-tannarx qatorlari (asosiy kalit + takror ':N')
  update yuk_tannarx
     set is_deleted = true,
         deleted_by_name = v_name,
         deleted_at = now()
   where yuk_id = p_yuk_id
     and (kalit = 'entry:' || p_entry::text or kalit like 'entry:' || p_entry::text || ':%')
     and is_deleted = false;
  get diagnostics v_tan = row_count;

  -- 5) tahrir izi
  insert into entry_history (entry_id, action, snapshot, changed_by_name)
  values (p_entry, 'edit',
          jsonb_build_object('note', 'Yuk bog''lanishi bekor qilindi: #' || p_yuk_id
                                     || ' (to''lov «Bog''lanmagan to''lovlar»ga qaytdi)',
                             'summa_uzs', v_summa,
                             'tannarx_bekor', v_tan,
                             'birlashtirildi', v_birl,
                             'satrlar', v_satrlar,
                             'old', v_snap),
          v_name);

  return jsonb_build_object('ok', true, 'holat', 'bekor', 'entry_id', p_entry,
                            'yuk_id', p_yuk_id, 'summa_uzs', v_summa, 'tannarx_bekor', v_tan,
                            'birlashtirildi', v_birl);
end
$yq_bekor$;

revoke all on function yuk_boglash_bekor(uuid, integer) from public, anon;
grant execute on function yuk_boglash_bekor(uuid, integer) to authenticated;

comment on function yuk_boglash_bekor(uuid, integer) is
  'yuk_boglash teskarisi: entry_yuk olib tashlanadi, Dt 9110 -> 9110-1, yuk_kutilmoqda=true, '
  'yuk_ids dan chiqariladi, entry:<id>(:N) kalitli tannarx bekor qilinadi, entry_history ga yoziladi. '
  '2026-10-28: qisman boglangan yozuvda 9110 satrlari bitta 9110-1 satriga qoshiladi (yozuv 2 satrli boladi). '
  'Yozuvda bir nechta yuk bolsa rad etadi (kod: kop_yuk).';


-- #####################################################################
-- ##  7-BO'LIM — DIAG + PostgREST                                      ##
-- #####################################################################
notify pgrst, 'reload schema';

do $yq_final$
begin
  if to_regprocedure('public.yuk_boglash_qisman(uuid,jsonb,jsonb,boolean)') is null then
    raise exception 'YAKUNIY: yuk_boglash_qisman yaralmadi';
  end if;
  if to_regprocedure('public.yuk_boglash_koplik_qisman(uuid[],integer,numeric)') is null then
    raise exception 'YAKUNIY: yuk_boglash_koplik_qisman yaralmadi';
  end if;
  if to_regprocedure('public._yuk_boglash_satr(uuid,numeric,uuid,uuid)') is null then
    raise exception 'YAKUNIY: _yuk_boglash_satr yaralmadi';
  end if;
  -- overload bo'lmasin (PostgREST noaniqligi)
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'yuk_boglash_koplik') <> 1 then
    raise exception 'YAKUNIY: yuk_boglash_koplik bir nechta nusxa — overload chiqib qoldi';
  end if;
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'yuk_boglash') <> 1 then
    raise exception 'YAKUNIY: yuk_boglash bir nechta nusxa — overload chiqib qoldi';
  end if;
  if has_function_privilege('authenticated', 'public._yuk_boglash_satr(uuid,numeric,uuid,uuid)', 'execute') then
    raise exception 'YAKUNIY: _yuk_boglash_satr ICHKI funksiya authenticated uchun ochiq qolgan';
  end if;
  if not has_function_privilege('authenticated', 'public.yuk_boglash_qisman(uuid,jsonb,jsonb,boolean)', 'execute') then
    raise exception 'YAKUNIY: yuk_boglash_qisman authenticated uchun yopiq — UI ishlamaydi';
  end if;
  if position('qisman' in (select prosrc from pg_proc where proname = 'yuk_kutayotgan_v2' limit 1)) = 0 then
    raise exception 'YAKUNIY: yuk_kutayotgan_v2 yangilanmadi';
  end if;

  raise notice 'PROVODKA_YUK_BOGLASH_QISMAN.sql: tayyor — qisman boglash (yuk_boglash_qisman, yuk_boglash_koplik_qisman), '
               'yuk_boglash/koplik/bekor/kutayotgan qayta elon qilindi. Hozir boglanmagan: % ta',
               (select count(*) from entry where yuk_kutilmoqda = true and is_deleted = false and status = 'posted');
end
$yq_final$;

-- Tekshirish (ixtiyoriy, hech narsa yozmaydi):
-- select yuk_kutayotgan_v2() -> 'qisman';          -- true
-- select yuk_kutayotgan_v2() -> 'rows' -> 0;        -- summa, summa_jami, boglangan_uzs
