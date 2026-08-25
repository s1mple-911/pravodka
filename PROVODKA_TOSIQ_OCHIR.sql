-- =====================================================================
-- PROVODKA_TOSIQ_OCHIR.sql
-- 70% XARAJAT TO'SIG'I + QARZ (6720/6721) MEXANIZMINI BUTUNLAY O'CHIRISH
-- ---------------------------------------------------------------------
-- Brief: BRIEF_PROVODKA_SOROVLAR.md — 0-band.
-- Bu fayl FAQAT SQL. HTML ga TEGILMAGAN (klient tomonini boshqa agent oladi).
--
-- ## NIMA O'CHADI
--   PROVODKA_XARAJAT_TOSIQ.sql      — hammasi (trigger, to'siq, qarz, view)
--   PROVODKA_XARAJAT_QARZ.sql       — qarz mantiqi asosiy oqimdan chiqadi
--   PROVODKA_HODIM_TARIX_QARZ.sql   — qarz yordamchilari (map/ids)
--
-- ## NIMA TIKLANADI (o'chirilmaydi — PROD hodim.html chaqiradi!)
--   xarajat_saqlash_taqsim(jsonb)      -> PROVODKA_EXT_REF.sql versiyasi
--   hodim_oz_tarix(date,date)          -> qarzsiz (dublikat tuzatishi SAQLANDI)
--   hodim_oy_jami_kop(uuid[],date,date)-> PROVODKA_HODIM_TEZLIK.sql versiyasi
--   hodim_oy_jami(uuid,date,date)      -> PROVODKA_HODIM_V3.sql versiyasi
--
-- =====================================================================
-- ## 🔴 HAR QANDAY KOMBINATSIYADA ISHLAYDI
-- Asilbek qaysi fayllarni RUN qilgani ANIQ EMAS. Shuning uchun:
--   * hamma o'chirish `drop ... if exists` — yo'q obyekt xato bermaydi;
--   * hech qanday shart tekshirilmaydi ("avval TOSIQ RUN qilinsin" YO'Q);
--   * tiklanadigan to'rtta funksiya `create or replace` — imzo bayt-ma-bayt
--     bir xil (42P13 chiqmaydi), ya'ni QARZ.sql / TARIX_QARZ.sql RUN
--     qilingan bo'lsa ham, qilinmagan bo'lsa ham natija BIR XIL bo'ladi;
--   * qayta RUN qilish xavfsiz (idempotent).
--
-- ## 🔴 SQL VA HTML BIRGA CHIQADI (eng muhim bog'liqlik)
-- Quyidagi funksiyalar hozir DEV HTML fayllarida chaqiriladi:
--   hodim_xarajat_yoz(jsonb)   <- hodim-dev.html  (qarzOk sharti bilan)
--   xarajat_qarz_versiya()     <- hodim-dev.html  (imkoniyat belgisi)
--   hodim_tosiq_holat(uuid)    <- hodim-dev / professional-dev / provodka-dev
--   hodim_tosiq_foiz()         <- kassa-dev.html
--   hodim_tosiq_blok(uuid)     <- kassa-dev.html
--   hodim_kirim_yop(...)       <- kassa-dev.html, hodim-dev.html
--   hodim_tolanmagan_bir(uuid) <- hodim-dev.html
--   v_hodim_balans             <- kassa-dev.html
--   v_hodim_tolanmagan         <- hodim-dev.html, jurnal-dev.html
-- Bu fayl RUN qilinsa ular YO'Q bo'ladi va o'sha chaqiruvlar PostgREST
-- xatosi (PGRST202 / 42883) qaytaradi. Shuning uchun:
--   🔴 SHU SQL VA KLIENT TOZALASHI BITTA CHIQISHDA (bitta commit) KETSIN.
--   ⚠️ PROD `.html` fayllari TEKSHIRILDI — ularda bu nomlarning BIRORTASI
--      YO'Q, ya'ni bu fayl PROD ni sindirmaydi. Faqat DEV kutmoqda.
--
-- ## RUN TARTIBI (Asilbek) — bo'limlarni BITTALAB, TARTIB BILAN
--   0-BO'LIM — TEKSHIRUV (faqat select, hech narsa o'zgarmaydi)
--   1-BO'LIM — TRIGGER o'chirish  🔴 ENG AVVAL (pul oqimi darrov ochiladi)
--   2-BO'LIM — PROD funksiyalarni TIKLASH (4 ta)
--   3-BO'LIM — qolgan funksiya / view / config o'chirish
--   4-BO'LIM — 6720/6721 hisoblari + accounts.hodim_kassa_id ustuni
--   5-BO'LIM — notify pgrst
--   6-BO'LIM — YAKUNIY TEKSHIRUV (faqat select)
--   7-BO'LIM — ROLLBACK (qaytarish kerak bo'lsa)
--
--   🔴 2-BO'LIM 3-BO'LIMDAN OLDIN bo'lishi SHART: 2-BO'LIM tiklaydigan
--      uchta hodim RPC si hozir `hodim_qarz_ids()` ni chaqiradi, 3-BO'LIM
--      esa uni o'chiradi. Teskari tartibda RUN qilinsa oraliqda hodim
--      sahifasi "function does not exist" beradi — lekin bu VAQTINCHA:
--      2-BO'LIM RUN qilinishi bilan tuzaladi (yo'qotish yo'q).
--
-- ## QOIDALAR (buzilmadi)
--   * anonim `do` bloki YO'Q (Supabase editorida 42P01).
--   * Faylda RPC ni JONLI chaqiradigan operator YO'Q — faqat KATALOG va
--     jadval so'rovlari (editorda `auth.uid()` null, natija chalg'itadi).
--   * Izohlarda dollar-qavs YOZILMAGAN (bu faylda birorta dollar belgisi
--     faqat funksiya tanasining NOMLANGAN tegida uchraydi) — shu sababli
--     izohdagi belgi dollar-qavs paritetini buzmaydi (CLAUDE.md).
--   * `drop function` bo'lgan joyda o'sha funksiya qayta yaratilmaydi
--     (tiklanadigan 4 tasi `create or replace` — drop umuman yo'q) — 42P13
--     xavfi yo'q.
--   * `cascade` ISHLATILMAYDI: kutilmagan bog'liqlik bo'lsa xato CHIQSIN,
--     jimgina begona obyekt o'chib ketmasin.
--
-- ## 🔴 TEGILMAYDI (aniq ajratildi — 6-BO'LIM katalogdan tasdiqlaydi)
--   * `entry.ext_ref`, `xarajat_qayta_urinish(text)`, `xarajat_saqlash_taqsim`
--     ichidagi 23505 + `<token>:<i>` mantiqi   — TAKROR HIMOYASI, boshqa mavzu
--   * `entry_ijrochi_set`, `ijrochi_nomi`, `jurnal_v2*`, `jurnal_ijrochilar`
--   * `accounts.filial_majburiy`, `set_modda_flag`
--   * `hodim_amallar(date,date)`, `hodim_ijrochi_nomi(text)`
--   * `perm_*`, `trg_perm_guard_entry_line`
--   * `trg_limit_guard_entry_line`
--   * `hodim_notify*`, `trg_hodim_notify_entry_line`
--   * `accounts.taskfix_user_id`  — TOSIQ.sql uni `add column if not exists`
--     bilan "kafolatlagan", lekin ustun undan OLDIN ham bor edi va uni
--     `hodim_notify` (telegram) ishlatadi. O'CHIRILMAYDI.
--   * `hodim_qoldiqlar`, `standart_holat`, `acc_balance`, `kassa_oila`
--
-- ## ⚠️ Bu fayldan keyin ISHLAMAY QOLADIGAN DIAGNOSTIKA skriptlari
--   `DIAG_KIM_BLOK.sql`, `DIAG_YETIM.sql` (82-qator) — ular `hodim_tosiq_*`
--   ni chaqiradi. Ular bir martalik diagnostika, obyekt emas — repoda
--   qolaveradi, shunchaki endi RUN qilinmaydi.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — TEKSHIRUV (hech narsa o'zgarmaydi, faqat select)    ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 0.1  Bazada NIMA bor? (qaysi fayl RUN qilinganini shundan bilamiz)
--      TOSIQ.sql RUN qilingan  -> f_tosiq_guard/f_tosiq_foiz = true
--      QARZ.sql RUN qilingan   -> f_qarz_versiya = true
--      TARIX_QARZ RUN qilingan -> f_qarz_map/f_qarz_ids = true
--      false chiqqanlari uchun hech narsa qilinmaydi (drop if exists).
-- ---------------------------------------------------------------------
select to_regprocedure('public.hodim_tosiq_guard()')                     is not null as f_tosiq_guard,
       to_regprocedure('public.hodim_tosiq_foiz()')                      is not null as f_tosiq_foiz,
       to_regprocedure('public.set_hodim_tosiq_foiz(numeric)')           is not null as f_set_tosiq,
       to_regprocedure('public.hodim_tosiq_msg(numeric,numeric)')        is not null as f_tosiq_msg,
       to_regprocedure('public.hodim_tosiq_blok(uuid)')                  is not null as f_tosiq_blok,
       to_regprocedure('public.hodim_tosiq_holat(uuid)')                 is not null as f_tosiq_holat,
       to_regprocedure('public.hodim_balans_bir(uuid)')                  is not null as f_balans_bir,
       to_regprocedure('public.hodim_tolanmagan_bir(uuid)')              is not null as f_tolanmagan_bir,
       to_regprocedure('public.hodim_kassa_ildiz(uuid)')                 is not null as f_kassa_ildiz,
       to_regprocedure('public.hodim_qarz_hisob(uuid)')                  is not null as f_qarz_hisob,
       to_regprocedure('public.hodim_qarz_hisob_topish(uuid)')           is not null as f_qarz_topish,
       to_regprocedure('public.hodim_kirim_yop(uuid,numeric,uuid,text)') is not null as f_kirim_yop,
       to_regprocedure('public.hodim_xarajat_yoz(jsonb)')                is not null as f_xarajat_yoz,
       to_regprocedure('public.xarajat_qarz_versiya()')                  is not null as f_qarz_versiya,
       to_regprocedure('public.hodim_qarz_map(uuid[])')                  is not null as f_qarz_map,
       to_regprocedure('public.hodim_qarz_ids(uuid[])')                  is not null as f_qarz_ids,
       to_regclass('public.v_hodim_balans')                              is not null as v_balans,
       to_regclass('public.v_hodim_tolanmagan')                          is not null as v_tolanmagan;

-- ---------------------------------------------------------------------
-- 0.2  entry_line triggerlari — nima o'chadi, nima QOLADI.
--      Kutilgan natija SHU FAYLDAN KEYIN:
--        trg_hodim_tosiq_entry_line  -> YO'Q
--        trg_perm_guard_entry_line   -> BOR (ruxsat)
--        trg_limit_guard_entry_line  -> BOR (oylik limit)
--        trg_hodim_notify_entry_line -> BOR (telegram)
-- ---------------------------------------------------------------------
select t.tgname,
       case when t.tgname = 'trg_hodim_tosiq_entry_line'
            then 'OCHIRILADI (1-BOLIM)' else 'QOLADI — TEGILMAYDI' end as holat,
       pg_get_triggerdef(t.oid) as tarif
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
 where c.relname = 'entry_line'
   and not t.tgisinternal
 order by t.tgname;

-- ---------------------------------------------------------------------
-- 0.3  🔴 6720 / 6721 HISOBLARIDA YOZUV BORMI?
--      Har hisob bo'yicha: satr soni va qarz qoldig'i (Kt - Dt, posted).
--      Bo'sh chiqsa — 6720 umuman ochilmagan (TOSIQ.sql RUN qilinmagan).
-- ---------------------------------------------------------------------
select a.code,
       a.name,
       a.subtitle,
       a.type,
       a.is_active,
       (select count(*) from entry_line l where l.account_id = a.id) as satr_soni,
       coalesce((select sum(l.credit - l.debit)
                   from entry_line l
                   join entry e on e.id = l.entry_id
                  where l.account_id = a.id
                    and e.status = 'posted' and e.is_deleted = false), 0) as qarz_qoldiq
  from accounts a
 where a.code = '6720'
    or a.parent_id = (select id from accounts where code = '6720')
 order by a.code;

-- ---------------------------------------------------------------------
-- 0.4  🔴 QAROR SATRI — 4-BO'LIMni qanday o'qish kerakligini aytadi.
--      'BOSH'      -> hisoblar bo'sh, 4-BO'LIM ularni jimgina is_active=false
--                     qiladi (o'chirmaydi — CLAUDE.md: hech narsa o'chirilmaydi).
--      'YOZUV BOR' -> 🔴 hisoblar TEGILMAYDI. Ular BUXGALTERIYA MA'LUMOTI:
--                     kompaniyaning hodimga haqiqiy qarzi turibdi. Qo'lda
--                     qaror kerak (yopish provodkasi yozilsinmi yoki balansda
--                     qolsinmi). 4-BO'LIM faqat BO'SH hisoblarga tegadi —
--                     yozuvi borlarini o'zi chetlab o'tadi.
-- ---------------------------------------------------------------------
select case
         when coalesce(sum(x.satr_soni), 0) = 0
           then 'BOSH — 6720/6721 da birorta yozuv yoq. 4-BOLIM xavfsiz (faqat is_active=false).'
         else 'YOZUV BOR: ' || coalesce(sum(x.satr_soni), 0)::text || ' satr, ochiq qarz '
              || coalesce(sum(x.qoldiq), 0)::text || ' som. '
              || 'HISOBLAR OCHIRILMAYDI — bu buxgalteriya malumoti, qolda qaror kerak. '
              || '4-BOLIM yozuvi bor hisobga TEGMAYDI.'
       end as qaror,
       coalesce(sum(x.satr_soni), 0) as jami_satr,
       coalesce(sum(x.qoldiq), 0)    as jami_ochiq_qarz
  from (
    select (select count(*) from entry_line l where l.account_id = a.id) as satr_soni,
           coalesce((select sum(l.credit - l.debit)
                       from entry_line l
                       join entry e on e.id = l.entry_id
                      where l.account_id = a.id
                        and e.status = 'posted' and e.is_deleted = false), 0) as qoldiq
      from accounts a
     where a.code = '6720'
        or a.parent_id = (select id from accounts where code = '6720')
  ) x;

-- ---------------------------------------------------------------------
-- 0.5  To'siq foizi (config kaliti) — 3-BO'LIMda o'chiriladi.
-- ---------------------------------------------------------------------
select key, val, updated_by, updated_at
  from provodka_config
 where key = 'hodim_tosiq_foiz';


-- #####################################################################
-- ##  1-BO'LIM — 🔴 TRIGGER O'CHIRISH (ENG AVVAL RUN QILING)         ##
-- #####################################################################
-- Bu ikki qator RUN bo'lishi bilan 70% to'sig'i BUTUNLAY ishlamay qoladi:
-- hodim kassasiga kirim va hodim kassasidan transfer darrov ochiladi.
-- Qolgan bo'limlar keyinroq RUN qilinsa ham pul oqimi allaqachon tiklangan.
--
-- ⚠️ Trigger avval, funksiya keyin: teskari bo'lsa PostgreSQL bog'liqlik
--    tufayli funksiyani o'chirmaydi (2BP01).
-- ⚠️ `trg_perm_guard_entry_line` / `trg_limit_guard_entry_line` /
--    `trg_hodim_notify_entry_line` — TEGILMAYDI.
-- ---------------------------------------------------------------------

drop trigger if exists trg_hodim_tosiq_entry_line on entry_line;

drop function if exists hodim_tosiq_guard();


-- #####################################################################
-- ##  2-BO'LIM — PROD FUNKSIYALARINI TIKLASH (o'chirilmaydi!)        ##
-- #####################################################################
-- Bu to'rtta funksiyani PROD `hodim.html` chaqiradi:
--   sb.rpc('xarajat_saqlash_taqsim', ...)  sb.rpc('hodim_oz_tarix', ...)
--   sb.rpc('hodim_oy_jami', ...)           sb.rpc('hodim_oy_jami_kop', ...)
-- Ularni o'chirib bo'lmaydi — qarzdan OLDINGI, to'g'ri versiyaga qaytariladi.
-- Imzolar (nom, argument nomlari, turlar, qaytish turi) BAYT-MA-BAYT bir xil,
-- shuning uchun `create or replace` yetadi va PostgREST kontrakti buzilmaydi.
-- #####################################################################


-- ---------------------------------------------------------------------
-- 2.1  xarajat_saqlash_taqsim(jsonb)
--      -> PROVODKA_EXT_REF.sql dagi versiya, AYNAN.
--
--      NIMA OLIB TASHLANDI (QARZ.sql qo'shgani):
--        * `hodim_kassa_ildiz` / `hodim_qarz_hisob` dinamik chaqiruvlari,
--        * qoldiqni o'qib `kqism` / `qqism` ga bo'lish,
--        * uchinchi satr `Kt 6721`,
--        * valyuta kassasida "qoldiqdan ortiq" tekshiruvi (u faqat qarz
--          shoxi uchun qo'shilgan edi),
--        * javobdagi `kassa_summa` / `tolanmagan_summa` / `qarz_hisob_id`.
--      Javob yana AYNAN {ok, count, entry_ids} — eski klient shuni kutadi,
--      yangi (dev) klient ham qo'shimcha kalitlarni ixtiyoriy o'qiydi.
--
--      🔴 NIMA SAQLANDI (TEGILMAYDI — boshqa mavzu, takror himoyasi):
--        * `p_data.ext_ref` -> `entry.ext_ref = '<token>:' || <indeks>`,
--        * `unique_violation` (23505) ni "allaqachon saqlangan" ga o'girish,
--        * token uzunligi 8..120 tekshiruvi,
--        * `lock_timeout = 5s`,
--        * fc (valyuta) taqsimoti va oxirgi ulushga qoldiq berish.
--      ⚠️ QARZ.sql `unique_violation` shoxiga qo'shgan "faqat ext_ref
--         constraint'i tarjima qilinsin" ehtiyoti endi KERAK EMAS: u
--         `hodim_qarz_hisob()` ning `accounts_hodim_kassa_id_uniq` poygasi
--         uchun edi, o'sha chaqiruv esa yo'q. EXT_REF.sql dagi soddaroq
--         shakl qaytarildi (bu funksiya endi faqat `entry`/`entry_line` ga
--         yozadi, ya'ni yagona unique manbai `entry.ext_ref`).
-- ---------------------------------------------------------------------
create or replace function xarajat_saqlash_taqsim(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  it       jsonb;
  v_entry  uuid;
  v_ids    uuid[] := '{}';
  v_dt     uuid := nullif(p_data->>'dt_account','')::uuid;
  v_kt     uuid := nullif(p_data->>'kt_account','')::uuid;
  v_kassa  uuid := nullif(p_data->>'kassa_account','')::uuid;
  v_cur    text := nullif(p_data->>'kassa_currency','');
  -- 1 birlik valyuta necha so'm. null -> eski xatti-harakat (fc = summa).
  v_kurs   numeric := nullif(p_data->>'kassa_kurs','')::numeric;
  -- Takrorga qarshi token (ixtiyoriy). null -> eski xatti-harakat.
  v_ext    text := nullif(trim(p_data->>'ext_ref'), '');
  v_summa  numeric;
  v_filial uuid;
  v_fc     numeric;
  v_fc_dt  numeric;
  v_fc_kt  numeric;
  -- fc yaxlitlash siljishini yo'qotish uchun: jami valyuta miqdori va sarflangani.
  v_jami   numeric := 0;
  v_fc_bar numeric;
  v_fc_qol numeric;
  v_n      int;
  v_i      int := 0;
begin
  -- lock_timeout — "Saqlanmoqda…" abadiy aylanmasin (5s, 55P03).
  -- `statement_timeout` ATAYLAB o'zgartirilmaydi (joriy so'rovga ta'sir qilmaydi).
  perform set_config('lock_timeout', '5s', true);

  if v_dt is null or v_kt is null then
    raise exception 'dt/kt hisob berilmadi' using errcode = '22000';
  end if;
  if p_data->'taqsim' is null or jsonb_typeof(p_data->'taqsim') <> 'array'
     or jsonb_array_length(p_data->'taqsim') = 0 then
    raise exception 'Taqsimot bo''sh' using errcode = '22000';
  end if;
  if v_kurs is not null and v_kurs <= 0 then
    raise exception 'Kurs musbat bo''lishi kerak' using errcode = '22000';
  end if;
  -- Juda qisqa token butun bir guruh yozuvni "o'ziniki" qilib qo'yishi
  -- mumkin edi (prefiks qidiruvi) — uzunlik chegaralanadi, jim qolinmaydi.
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bo''lishi kerak' using errcode = '22000';
  end if;

  -- Valyuta jamisi BIR MARTA hisoblanadi (ulushlar yig'indisidan), keyin
  -- ulushlarga taqsimlanadi — sum(fc) = round(jami/kurs, 2) aniq mos keladi.
  v_n := jsonb_array_length(p_data->'taqsim');
  if v_kurs is not null then
    select coalesce(sum((x->>'summa')::numeric), 0) into v_jami
      from jsonb_array_elements(p_data->'taqsim') as x;
    v_fc_bar := round(v_jami / v_kurs, 2);
    v_fc_qol := v_fc_bar;
  end if;

  for it in select * from jsonb_array_elements(p_data->'taqsim') loop
    v_i := v_i + 1;
    v_summa  := (it->>'summa')::numeric;
    v_filial := nullif(it->>'filial_id','')::uuid;
    if v_summa is null or v_summa <= 0 then
      raise exception 'Har filial summasi musbat bo''lishi kerak' using errcode = '22000';
    end if;

    insert into entry (entry_date, description, source, status, filial_ids,
                       davr_start, davr_end, kommunal_turi, fc_rate, ext_ref)
    values (
      nullif(p_data->>'entry_date','')::date,
      nullif(p_data->>'description',''),
      coalesce(nullif(p_data->>'source',''), 'manual'),
      coalesce(nullif(p_data->>'status',''), 'posted'),
      case when v_filial is null then '{}'::uuid[] else array[v_filial] end,
      nullif(p_data->>'davr_start','')::date,
      nullif(p_data->>'davr_end','')::date,
      nullif(p_data->>'kommunal_turi',''),
      case when v_cur is not null and v_cur <> 'UZS' then v_kurs end,
      -- Token berilmasa null (eski xatti-harakat AYNAN saqlanadi).
      -- Shakl `<token>:<i>` — MAVJUD kontrakt, o'zgarmaydi.
      case when v_ext is null then null else v_ext || ':' || v_i::text end
    )
    returning id into v_entry;

    -- fc_amount faqat valyuta kassasi satriga (klient bilan bir xil mantiq).
    -- OXIRGI ulushga taqsimlanmay qolgan qoldiq beriladi.
    if v_kurs is null then
      v_fc := v_summa;                                   -- eski xatti-harakat
    elsif v_i = v_n then
      v_fc := v_fc_qol;
    else
      v_fc := round(v_fc_bar * v_summa / nullif(v_jami, 0), 2);
      v_fc_qol := v_fc_qol - v_fc;
    end if;
    v_fc_dt := case when v_cur is not null and v_cur <> 'UZS' and v_kassa = v_dt then v_fc else null end;
    v_fc_kt := case when v_cur is not null and v_cur <> 'UZS' and v_kassa = v_kt then v_fc else null end;

    -- 🔴 IKKI SATR — qarz (uchinchi) satri YO'Q. Dt = Kt = v_summa.
    insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
    values (v_entry, v_dt, v_summa, 0, v_fc_dt),
           (v_entry, v_kt, 0, v_summa, v_fc_kt);

    v_ids := v_ids || v_entry;
  end loop;

  return jsonb_build_object('ok', true,
                            'count', coalesce(array_length(v_ids, 1), 0),
                            'entry_ids', to_jsonb(v_ids));

exception
  -- Takror. Xato KODI o'zgarmaydi (23505) — klient aynan shu kod bo'yicha
  -- "allaqachon saqlangan" deb qaror qiladi. Funksiya tranzaksiya bo'lgani
  -- uchun bu yerga yetganda BU URINISHDAN hech narsa yozilmagan.
  when unique_violation then
    if v_ext is null then
      raise;                                   -- bizning to'siq EMAS
    end if;
    raise exception 'Bu xarajat allaqachon saqlangan (takroriy yuborish tosildi)'
      using errcode = '23505';
end $fn$;

revoke all on function xarajat_saqlash_taqsim(jsonb) from public, anon;
grant execute on function xarajat_saqlash_taqsim(jsonb) to authenticated;

comment on function xarajat_saqlash_taqsim(jsonb) is
  'Filial bo''yicha alohida provodka: har filialga bitta entry (atomik). perm guard har satrga ishlaydi. '
  'kassa_kurs berilsa valyuta kassasida fc = summa/kurs (aks holda fc = summa — eski xatti-harakat). '
  'ext_ref berilsa har entry ga <token>:<indeks> yoziladi — takror yuborish 23505 bilan tosiladi. '
  'lock_timeout = 5s.';


-- ---------------------------------------------------------------------
-- 2.2  hodim_oz_tarix(date, date)
--      -> qarzsiz, LEKIN TARIX_QARZ.sql ning DUBLIKAT TUZATISHI SAQLANDI.
--
--      🔴 NEGA sof V5 ga qaytarilmadi (qaror va asosi):
--      TARIX_QARZ.sql qarzdan tashqari ESKI, YASHIRIN bug ni ham tuzatgan
--      edi. V5 dagi shakl:
--          join entry_line kl on kl.entry_id = e.id and kl.credit > 0
--                            and kl.account_id = any(v_ids)
--      bitta yozuvda hodimning IKKI hisobi Kt bo'lsa (masalan
--      `professional.html` ko'p satrli yozuvi, yoki hodimning Naqd + Click
--      bolalari bir yozuvda) Dt satrini IKKI MARTA ko'paytirardi ->
--      kategoriya jamisi va ro'yxat IKKILANARDI. Bu qarzdan MUSTAQIL bug —
--      V5 ga qaytarish uni QAYTA OCHIB YUBORARDI.
--      Shuning uchun: mos Kt satrlari `select distinct kl.entry_id` CTE
--      (`ent`) ga siqiladi, ro'yxatda esa `join lateral ... limit 1` bilan
--      BITTA Kt satri tanlanadi. Har yozuv AYNAN BIR MARTA.
--
--      NIMA OLIB TASHLANDI: `hodim_qarz_map` / `hodim_qarz_ids` chaqiruvlari
--      va `v_ext`. Endi to'plam faqat `v_ids` (kassa va bola-hisoblari).
--      `kassa_id` maydoni yana to'g'ridan-to'g'ri Kt satrining hisobi —
--      qarz hisobi ro'yxatga umuman tushmaydi, ya'ni map ham keraksiz.
--
--      SUMMA MANBASI O'ZGARMADI: `dl.debit` (Dt xarajat moddasi).
--      Ruxsat bloki (user_perms / perm_op_key) TEGILMAGAN.
-- ---------------------------------------------------------------------
create or replace function hodim_oz_tarix(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  p     user_perms;
  v_ids uuid[];
  v_kat jsonb;
  v_roy jsonb;
begin
  -- caller kassalari (TEGILMAGAN)
  select * into p from user_perms where user_id = auth.uid();
  if found and p.kassa_scope = 'list' then
    -- op kassalari (perm key = hodim kassasining o'z id'si; valyuta bolasi bo'lmaydi)
    select array_agg(a.id) into v_ids
      from accounts a
     where a.type = 'aktiv' and a.code like '5%'
       and a.kassa_turi <> 'xarajat_guruh'
       and perm_op_key(a.id) = any(p.op_kassa_ids);
  else
    -- cheklovsiz / admin: barcha hodim (xarajat) kassalari
    select array_agg(a.id) into v_ids
      from accounts a
     where a.kassa_turi = 'xarajat';
  end if;

  if v_ids is null or array_length(v_ids, 1) is null then
    return jsonb_build_object('kategoriya', '[]'::jsonb, 'royxat', '[]'::jsonb);
  end if;

  -- Kategoriya: shu kassalardan chiqqan (Kt = kassa) xarajat modda (Dt) bo'yicha jami.
  with ent as (
    -- 🔴 distinct — bitta yozuv AYNAN BIR MARTA (ikki Kt satri ikkilantirmasin)
    select distinct kl.entry_id as id
      from entry_line kl
      join entry e2 on e2.id = kl.entry_id
     where kl.credit > 0
       and kl.account_id = any(v_ids)
       and e2.status = 'posted' and e2.is_deleted = false
       and e2.entry_date >= p_from and e2.entry_date <= p_to
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.jami desc), '[]'::jsonb) into v_kat
  from (
    select ma.code, ma.name, sum(dl.debit)::numeric as jami
      from ent
      join entry e on e.id = ent.id
      join entry_line dl on dl.entry_id = e.id and dl.debit > 0
      join accounts ma on ma.id = dl.account_id and ma.type = 'xarajat'
     where e.status = 'posted' and e.is_deleted = false
       and e.entry_date >= p_from and e.entry_date <= p_to
     group by ma.code, ma.name
    having sum(dl.debit) > 0
  ) x;

  -- Ro'yxat: har xarajat yozuvi (eng yangi 200 ta)
  with ent as (
    select distinct kl.entry_id as id
      from entry_line kl
      join entry e2 on e2.id = kl.entry_id
     where kl.credit > 0
       and kl.account_id = any(v_ids)
       and e2.status = 'posted' and e2.is_deleted = false
       and e2.entry_date >= p_from and e2.entry_date <= p_to
  )
  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v_roy
  from (
    select e.id as entry_id, e.entry_date, e.created_at,
           kk.account_id as kassa_id,
           ma.code as modda_code, ma.name as modda_name,
           dl.debit::numeric as summa,
           e.description as izoh
      from ent
      join entry e on e.id = ent.id
      join entry_line dl on dl.entry_id = e.id and dl.debit > 0
      join accounts ma on ma.id = dl.account_id and ma.type = 'xarajat'
      -- BITTA mos Kt satri (eng kattasi). `limit 1` -> qator ko'paymaydi.
      join lateral (
        select kl.account_id
          from entry_line kl
         where kl.entry_id = e.id
           and kl.credit > 0
           and kl.account_id = any(v_ids)
         order by kl.credit desc, kl.id asc
         limit 1
      ) kk on true
     where e.status = 'posted' and e.is_deleted = false
       and e.entry_date >= p_from and e.entry_date <= p_to
     order by e.created_at desc
     limit 200
  ) r;

  return jsonb_build_object('kategoriya', v_kat, 'royxat', v_roy);
end $fn$;

revoke all on function hodim_oz_tarix(date, date) from public, anon;
grant execute on function hodim_oz_tarix(date, date) to authenticated;

comment on function hodim_oz_tarix(date, date) is
  'Hodim o''z xarajat tarixi (kategoriya + ro''yxat) — auth.uid() ning o''z kassalari bo''yicha. '
  'Summa Dt (xarajat moddasi) satridan; har yozuv bir marta (dublikat to''silgan).';


-- ---------------------------------------------------------------------
-- 2.3  hodim_oy_jami_kop(uuid[], date, date)
--      -> PROVODKA_HODIM_TEZLIK.sql versiyasi, AYNAN.
--      Olib tashlandi: `|| hodim_qarz_ids(p_accounts)`.
--      Dublikat xavfi bu yerda YO'Q (join emas, satr yig'indisi).
-- ---------------------------------------------------------------------
create or replace function hodim_oy_jami_kop(p_accounts uuid[], p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(sum(el.credit), 0)
    from entry_line el
    join entry e on e.id = el.entry_id
   where el.account_id = any(p_accounts)
     and el.credit > 0
     and e.status = 'posted'
     and e.is_deleted = false
     and e.entry_date >= p_from
     and e.entry_date <= p_to
     and exists (
       select 1
         from entry_line dl
         join accounts a on a.id = dl.account_id
        where dl.entry_id = e.id
          and dl.debit > 0
          and a.type = 'xarajat'
     );
$fn$;

revoke all on function hodim_oy_jami_kop(uuid[], date, date) from public, anon;
grant execute on function hodim_oy_jami_kop(uuid[], date, date) to authenticated;

comment on function hodim_oy_jami_kop(uuid[], date, date) is
  'Kassa va bola-hisoblaridan davr ichida chiqqan xarajat jami (hodim_oy_jami ning to''plamli varianti).';


-- ---------------------------------------------------------------------
-- 2.4  hodim_oy_jami(uuid, date, date)
--      -> PROVODKA_HODIM_V3.sql versiyasi, AYNAN.
--      Olib tashlandi: `= any(array[p_account] || case ... hodim_qarz_ids ...)`
--      va u bilan birga "qarz faqat ildizda qo'shilsin" murakkabligi —
--      qarz yo'q bo'lgach ular ma'nosiz.
--      Klient (`hodim-dev.html` -> `loadMonth`) bu RPC ni har hisob uchun
--      alohida chaqirib natijalarni QO'SHADI; endi har chaqiruv AYNAN
--      bitta hisobni sanaydi, ya'ni yig'indi hodim_oy_jami_kop bilan TENG.
-- ---------------------------------------------------------------------
create or replace function hodim_oy_jami(p_account uuid, p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(sum(el.credit), 0)
    from entry_line el
    join entry e on e.id = el.entry_id
   where el.account_id = p_account
     and el.credit > 0
     and e.status = 'posted'
     and e.is_deleted = false
     and e.entry_date >= p_from
     and e.entry_date <= p_to
     and exists (
       select 1
         from entry_line dl
         join accounts a on a.id = dl.account_id
        where dl.entry_id = e.id
          and dl.debit > 0
          and a.type = 'xarajat'
     );
$fn$;

revoke all on function hodim_oy_jami(uuid, date, date) from public, anon;
grant execute on function hodim_oy_jami(uuid, date, date) to authenticated;

comment on function hodim_oy_jami(uuid, date, date) is
  'Kassadan davr ichida chiqqan xarajat jami (Kt yig''indisi, qarshi tomoni type=xarajat).';


-- Sxema keshi — 2-BO'LIM alohida RUN qilinsa ham PostgREST darrov ko'rsin.
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  3-BO'LIM — QOLGAN OBYEKTLARNI O'CHIRISH                        ##
-- #####################################################################
-- Tartib MUHIM: avval VIEW lar (ular funksiyalarga bog'liq), keyin
-- funksiyalar, keyin config kaliti. `cascade` ISHLATILMAYDI — kutilmagan
-- bog'liqlik bo'lsa xato chiqsin (jimgina begona obyekt o'chib ketmasin).
--
-- ⚠️ 2-BO'LIM SHU BO'LIMDAN OLDIN RUN QILINGAN BO'LSIN — aks holda
--    hodim_oz_tarix / hodim_oy_jami* vaqtincha `hodim_qarz_ids` ni
--    izlab xato beradi (2-BO'LIM RUN bo'lishi bilan tuzaladi).
-- ---------------------------------------------------------------------

-- 3.1  View lar (kassa-dev / hodim-dev / jurnal-dev ishlatardi)
drop view if exists v_hodim_tolanmagan;
drop view if exists v_hodim_balans;

-- 3.2  Ochiq RPC lar (klient chaqiradigan yuza qatlam)
drop function if exists hodim_tosiq_holat(uuid);
drop function if exists hodim_kirim_yop(uuid, numeric, uuid, text);
drop function if exists hodim_xarajat_yoz(jsonb);
drop function if exists xarajat_qarz_versiya();

-- 3.3  O'lchov va to'siq mantiqi
drop function if exists hodim_tolanmagan_bir(uuid);
drop function if exists hodim_tosiq_blok(uuid);
drop function if exists hodim_balans_bir(uuid);
drop function if exists hodim_tosiq_msg(numeric, numeric);
drop function if exists set_hodim_tosiq_foiz(numeric);
drop function if exists hodim_tosiq_foiz();

-- 3.4  Qarz yordamchilari
--      hodim_qarz_ids -> hodim_qarz_map -> hodim_qarz_hisob_topish zanjiri,
--      shuning uchun teskari tartibda.
drop function if exists hodim_qarz_ids(uuid[]);
drop function if exists hodim_qarz_map(uuid[]);
drop function if exists hodim_qarz_hisob(uuid);
drop function if exists hodim_qarz_hisob_topish(uuid);

-- 3.5  hodim_kassa_ildiz(uuid)
--      🔴 TEKSHIRILDI: repoda uni faqat PROVODKA_XARAJAT_TOSIQ.sql,
--         PROVODKA_XARAJAT_QARZ.sql va bir martalik DIAG_KIM_BLOK.sql
--         chaqiradi. `PROVODKA_HODIM_TARIX_QARZ.sql` uni faqat 0-BO'LIM
--         tekshiruvida (to_regprocedure) tilga oladi. `PROVODKA_HODIM_AMALLAR.sql`
--         (hodim_amallar) UNI ISHLATMAYDI — u faqat `hodim_qarz_ids` ni
--         dinamik chaqiradi va yo'q bo'lsa jimgina qarzsiz ishlaydi.
--         Prod/dev HTML da SQL funksiya sifatida chaqirilmaydi
--         (hodim-dev.html dagi ikki uchrash — JS izohida, o'sha qoidaning
--         klient nusxasi haqida).
--      Shuning uchun o'chirish xavfsiz.
drop function if exists hodim_kassa_ildiz(uuid);

-- 3.6  To'siq foizi sozlamasi (provodka_config kaliti).
--      Config kaliti — buxgalteriya yozuvi emas, shuning uchun o'chiriladi.
--      Boshqa kalitlarga (konvert koridori va h.k.) TEGILMAYDI.
delete from provodka_config where key = 'hodim_tosiq_foiz';


-- #####################################################################
-- ##  4-BO'LIM — 6720 / 6721 HISOBLARI va accounts.hodim_kassa_id    ##
-- #####################################################################
-- 🔴 CLAUDE.md: "Hech narsa o'chirilmaydi". Hisoblar `delete` QILINMAYDI —
--    faqat `is_active = false`. Va faqat YOZUVI YO'Q hisoblar: yozuvi
--    borlari kompaniyaning hodimga haqiqiy qarzini ifodalaydi va ular
--    balansda ko'rinib turishi kerak (`is_active=false` qilinsa
--    `balans()` / hisob ro'yxatlaridan tushib qolib, Aktiv = Passiv
--    tengligi buzilishi mumkin — bu risk olinmaydi).
--
--    Yozuvi bor 6721 hisoblari bilan NIMA QILISH — 🔴 ASILBEK QARORI:
--      (a) qoldirish: balansda "Hisobdor shaxslarga qarz" bo'lib turaveradi
--          (hech nima qilmaslik — xavfsiz, tavsiya etiladi), yoki
--          keyinroq real to'lov provodkasi bilan yopiladi
--          (Dt 6721 / Kt 5011 — bu oddiy yozuv, hech qanday RPC kerak emas);
--      (b) qoldig'i 0 bo'lgach shu bo'limni qayta RUN qilish — o'shanda
--          ular ham avtomat `is_active=false` bo'ladi.
--    Qaysi hisobda nima borligi 0.3 / 0.4 tekshiruvida ko'rinadi.
-- ---------------------------------------------------------------------

-- 4.1  Yozuvi YO'Q qarz hisoblari (6721+) -> nofaol.
--      Yozuvi bor hisob bu `where` dan o'tmaydi — u TEGILMAYDI.
update accounts q
   set is_active = false
 where q.parent_id = (select id from accounts where code = '6720')
   and q.is_active
   and not exists (select 1 from entry_line l where l.account_id = q.id);

-- 4.2  6720 konteyner -> nofaol, LEKIN faqat:
--        * o'zida yozuv bo'lmasa (konteynerga hech qachon yozilmagan) VA
--        * faol bolasi qolmagan bo'lsa (ya'ni 4.1 hammasini yopgan).
--      Aks holda konteyner faol qoladi — bolalari balansda ko'rinishi uchun.
update accounts g
   set is_active = false
 where g.code = '6720'
   and g.is_active
   and not exists (select 1 from entry_line l where l.account_id = g.id)
   and not exists (select 1 from accounts q where q.parent_id = g.id and q.is_active);

-- 4.3  🔴 USTUN O'CHIRISHDAN OLDIN — BOG'LANISHNI SAQLAB QO'YING.
--      Quyidagi so'rov natijasini (qarz hisobi -> hodim kassasi) nusxalab
--      oling: 4.4 dan keyin bu ma'lumot BAZADA QOLMAYDI. Hisoblarning
--      `name` / `subtitle` si (hodim ismi, "Filial · Lavozim") saqlanadi,
--      ya'ni identifikatsiya yo'qolmaydi — faqat uuid bog'lanishi ketadi.
--      Bo'sh chiqsa — saqlaydigan narsa yo'q, to'g'ridan 4.4 ga o'ting.
select q.code   as qarz_kod,
       q.name   as qarz_nom,
       q.hodim_kassa_id,
       k.code   as kassa_kod,
       k.name   as kassa_nom
  from accounts q
  left join accounts k on k.id = q.hodim_kassa_id
 where q.hodim_kassa_id is not null
 order by q.code;

-- 4.4  🔴 FAYLDAGI YAGONA QAYTARIB BO'LMAYDIGAN QATOR.
--      `accounts.hodim_kassa_id` — TOSIQ.sql tug'dirgan ustun.
--      TEKSHIRILDI: uni repoda faqat PROVODKA_XARAJAT_TOSIQ.sql va
--      PROVODKA_XARAJAT_QARZ.sql ishlatadi (ikkalasi ham shu fayl bilan
--      o'chdi); birorta view / RPC / HTML unga murojaat qilmaydi.
--      Ustun bilan birga `accounts_hodim_kassa_id_uniq` indeksi ham ketadi.
--      ⚠️ 4.3 natijasini saqlaganingizga ishonch hosil qiling.
--      ⚠️ `accounts.taskfix_user_id` ga TEGILMAYDI — u telegram (hodim_notify)
--         uchun kerak va TOSIQ.sql dan OLDIN ham bor edi.
alter table accounts drop column if exists hodim_kassa_id;


-- #####################################################################
-- ##  5-BO'LIM — PostgREST sxema keshi                               ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  6-BO'LIM — YAKUNIY TEKSHIRUV (faqat select)                    ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 6.1  O'CHDIMI? — HAMMASI false bo'lishi kerak.
-- ---------------------------------------------------------------------
select to_regprocedure('public.hodim_tosiq_guard()')                     is not null as f_tosiq_guard,
       to_regprocedure('public.hodim_tosiq_foiz()')                      is not null as f_tosiq_foiz,
       to_regprocedure('public.set_hodim_tosiq_foiz(numeric)')           is not null as f_set_tosiq,
       to_regprocedure('public.hodim_tosiq_msg(numeric,numeric)')        is not null as f_tosiq_msg,
       to_regprocedure('public.hodim_tosiq_blok(uuid)')                  is not null as f_tosiq_blok,
       to_regprocedure('public.hodim_tosiq_holat(uuid)')                 is not null as f_tosiq_holat,
       to_regprocedure('public.hodim_balans_bir(uuid)')                  is not null as f_balans_bir,
       to_regprocedure('public.hodim_tolanmagan_bir(uuid)')              is not null as f_tolanmagan_bir,
       to_regprocedure('public.hodim_kassa_ildiz(uuid)')                 is not null as f_kassa_ildiz,
       to_regprocedure('public.hodim_qarz_hisob(uuid)')                  is not null as f_qarz_hisob,
       to_regprocedure('public.hodim_qarz_hisob_topish(uuid)')           is not null as f_qarz_topish,
       to_regprocedure('public.hodim_kirim_yop(uuid,numeric,uuid,text)') is not null as f_kirim_yop,
       to_regprocedure('public.hodim_xarajat_yoz(jsonb)')                is not null as f_xarajat_yoz,
       to_regprocedure('public.xarajat_qarz_versiya()')                  is not null as f_qarz_versiya,
       to_regprocedure('public.hodim_qarz_map(uuid[])')                  is not null as f_qarz_map,
       to_regprocedure('public.hodim_qarz_ids(uuid[])')                  is not null as f_qarz_ids,
       to_regclass('public.v_hodim_balans')                              is not null as v_balans,
       to_regclass('public.v_hodim_tolanmagan')                          is not null as v_tolanmagan,
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'accounts'
                  and column_name = 'hodim_kassa_id')                    as c_hodim_kassa_id,
       exists (select 1 from provodka_config where key = 'hodim_tosiq_foiz') as cfg_foiz;

-- ---------------------------------------------------------------------
-- 6.2  TIKLANDIMI? — HAMMASI true bo'lishi kerak.
-- ---------------------------------------------------------------------
select to_regprocedure('public.xarajat_saqlash_taqsim(jsonb)')            is not null as f_taqsim,
       to_regprocedure('public.hodim_oz_tarix(date,date)')                is not null as f_oz_tarix,
       to_regprocedure('public.hodim_oy_jami(uuid,date,date)')            is not null as f_oy_jami,
       to_regprocedure('public.hodim_oy_jami_kop(uuid[],date,date)')      is not null as f_oy_jami_kop,
       -- takror himoyasi TEGILMAGAN
       to_regprocedure('public.xarajat_qayta_urinish(text)')              is not null as f_qayta_urinish,
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'entry'
                  and column_name = 'ext_ref')                            as c_ext_ref;

-- ---------------------------------------------------------------------
-- 6.3  IMZO va GRANT — PostgREST kontrakti buzilmadimi?
--      `argumentlar` ustunidagi nomlar (p_data / p_from / p_to /
--      p_account / p_accounts) O'ZGARMAGAN bo'lishi shart.
--      `authenticated` ustuni hammasida true.
-- ---------------------------------------------------------------------
select p.proname,
       pg_get_function_identity_arguments(p.oid) as argumentlar,
       pg_get_function_result(p.oid)             as qaytish,
       p.prosecdef                               as security_definer,
       has_function_privilege('authenticated', p.oid, 'execute') as auth_ok,
       has_function_privilege('anon',          p.oid, 'execute') as anon_BULMASIN
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('xarajat_saqlash_taqsim', 'hodim_oz_tarix',
                     'hodim_oy_jami', 'hodim_oy_jami_kop')
 order by p.proname;

-- ---------------------------------------------------------------------
-- 6.4  entry_line triggerlari — to'siq ketdi, qolganlari JOYIDA.
--      Kutilgan: 3 qator (perm_guard, limit_guard, hodim_notify),
--      trg_hodim_tosiq_entry_line YO'Q.
-- ---------------------------------------------------------------------
select t.tgname, pg_get_triggerdef(t.oid) as tarif
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
 where c.relname = 'entry_line'
   and not t.tgisinternal
 order by t.tgname;

-- ---------------------------------------------------------------------
-- 6.5  🔴 TEGILMASIN RO'YXATI — hammasi true bo'lishi kerak.
--      (false chiqqani BU FAYL sababli emas — o'sha fayl umuman RUN
--       qilinmagan bo'lishi mumkin; lekin oldin true bo'lgani false
--       bo'lib qolgan bo'lsa — TO'XTANG va xabar bering.)
-- ---------------------------------------------------------------------
select to_regprocedure('public.xarajat_qayta_urinish(text)')        is not null as ext_ref_qayta_urinish,
       to_regprocedure('public.entry_ijrochi_set()')                is not null as ijrochi_set_trigger_fn,
       to_regprocedure('public.ijrochi_nomi(text)')                 is not null as ijrochi_nomi,
       to_regprocedure('public.jurnal_ijrochilar(date,date)')       is not null as jurnal_ijrochilar,
       to_regprocedure('public.set_modda_flag(uuid,text,boolean)')  is not null as set_modda_flag,
       to_regprocedure('public.hodim_amallar(date,date)')           is not null as hodim_amallar,
       to_regprocedure('public.perm_op_key(uuid)')                  is not null as perm_op_key,
       to_regprocedure('public.hodim_qoldiqlar(uuid[])')            is not null as hodim_qoldiqlar,
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'accounts'
                  and column_name = 'filial_majburiy')         as c_filial_majburiy,
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'accounts'
                  and column_name = 'taskfix_user_id')         as c_taskfix_user_id;

-- ---------------------------------------------------------------------
-- 6.6  6720 / 6721 yakuniy holati (0.3 bilan solishtiring).
--      Yozuvi bor hisoblar HAMON is_active = true bo'lib turishi NORMAL.
-- ---------------------------------------------------------------------
select a.code, a.name, a.subtitle, a.is_active,
       (select count(*) from entry_line l where l.account_id = a.id) as satr_soni,
       coalesce((select sum(l.credit - l.debit)
                   from entry_line l
                   join entry e on e.id = l.entry_id
                  where l.account_id = a.id
                    and e.status = 'posted' and e.is_deleted = false), 0) as qarz_qoldiq
  from accounts a
 where a.code = '6720'
    or a.parent_id = (select id from accounts where code = '6720')
 order by a.code;

-- ---------------------------------------------------------------------
-- 6.7  Hodim kassalarida qoldiq MANFIY bo'lib qolmadimi?
--      Qarz mexanizmi kassani manfiyga tushirmasdi. U ketgach, YANGI
--      xarajatlar yana kassani manfiyga tushirishi MUMKIN (eski, qarzdan
--      oldingi xatti-harakat — ataylab, brief 0-band shuni so'ragan).
--      Bu so'rov shunchaki hozirgi holatni ko'rsatadi (yozuvni o'zgartirmaydi).
-- ---------------------------------------------------------------------
select k.code, k.name, k.subtitle,
       coalesce((select sum(l.debit - l.credit)
                   from entry_line l
                   join entry e on e.id = l.entry_id
                  where l.account_id = k.id
                    and e.status = 'posted' and e.is_deleted = false), 0) as qoldiq
  from accounts k
  join accounts g on g.id = k.parent_id and g.kassa_turi = 'xarajat_guruh'
 where k.kassa_turi = 'xarajat'
   and k.is_active
 order by 4 asc, k.code;


-- #####################################################################
-- ##  7-BO'LIM — ROLLBACK (qaytarish kerak bo'lsa)                   ##
-- #####################################################################
-- Bu faylda `create or replace` va `drop` bor, ya'ni "avtomatik rollback"
-- yo'q. Qaytarish — ESKI FAYLLARNI QAYTA RUN QILISH, shu TARTIBDA:
--
--   1) PROVODKA_XARAJAT_TOSIQ.sql        (butun fayl)
--        -> hodim_kassa_ildiz, hodim_qarz_hisob(_topish), hodim_balans_bir,
--           hodim_tolanmagan_bir, v_hodim_balans, v_hodim_tolanmagan,
--           hodim_tosiq_* , hodim_xarajat_yoz, hodim_kirim_yop,
--           trg_hodim_tosiq_entry_line, 6720 hisobi, config kaliti,
--           accounts.hodim_kassa_id ustuni (1.1 da qayta ochiladi)
--
--   2) PROVODKA_XARAJAT_QARZ.sql         (butun fayl)
--        -> hodim_xarajat_yoz (ext_ref bilan), xarajat_saqlash_taqsim
--           (qarz mantiqi bilan), xarajat_qarz_versiya
--
--   3) PROVODKA_HODIM_TARIX_QARZ.sql     (butun fayl)
--        -> hodim_qarz_map, hodim_qarz_ids, hodim_oz_tarix,
--           hodim_oy_jami, hodim_oy_jami_kop (qarzni sanaydigan versiya)
--
-- ⚠️ 4.4 (`drop column hodim_kassa_id`) QAYTARILGANDA ustun BO'SH bo'lib
--    tiklanadi: qarz hisobi <-> hodim kassasi bog'lanishi YO'Q. Uni 4.3
--    natijasidan qo'lda tiklash kerak:
--      update accounts set hodim_kassa_id = '<kassa uuid>' where code = '<6721>';
--    (yoki `hodim_qarz_hisob()` ni ishlatib qayta yaratish — u
--     taskfix_user_id zaxira kaliti bilan backfill qiladi.)
--
-- ⚠️ ROLLBACK dan keyin KLIENT ham qaytarilishi kerak (dev HTML dagi
--    tosiq/qarz chaqiruvlari) — SQL va HTML har doim BIRGA.
--
-- ⚠️ 4.1 / 4.2 (`is_active=false`) qaytarish:
--      update accounts set is_active = true
--       where code = '6720' or parent_id = (select id from accounts where code='6720');
--
-- ⚠️ 3.6 (config kaliti) qaytarish:
--      insert into provodka_config(key, val) values ('hodim_tosiq_foiz','70')
--        on conflict (key) do nothing;
-- =====================================================================
