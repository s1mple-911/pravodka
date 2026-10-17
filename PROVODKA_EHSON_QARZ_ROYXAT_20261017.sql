-- ============================================================================
--  PROVODKA_EHSON_QARZ_ROYXAT_20261017.sql — 2026-10-17 — Excel ro'yxatidagi ehson QARZLARINI yozish
--  Asilbek: Ehson asosiy va Ehson soliq kassalaridan Excel ro'yxatidagi odamlarga ISMI bilan qarz yozilsin; pul aynan shu
--  kassadan AYIRILSIN. Muddat (deadline / oyma-oy) keyin UI'da qo'yiladi.
--
--  🔴 2026-10-17 TUZATISH: bu faylda avval qarzlardan KEYIN balansni maqsadga qaytaruvchi 'b' qismi bor edi — u XATO faraz edi
--  (maqsad qoldiqlar qarzlardan OLDINGI). 'b' qismi bu fayldan OLIB TASHLANDI (qayta RUN yana yozmasin); allaqachon yozilgan
--  'b' tuzatishlar PROVODKA_EHSON_QARZ_TUZATISH_BEKOR_20261017.sql bilan bekor qilinadi. Natija jadvali endi faqat QARZ qatorlari.
--  RUN TARTIBI: avval PROVODKA_EHSON.sql, ZAKOT, QARZ, so'ng PROVODKA_EHSON_KIRIM.sql, ENG OXIRIDA shu fayl.
--
--  Qanday yoziladi (ehson_qarz_ber bilan BIR XIL jadvallar/shakl, UI Qarz tabi ularni ko'radi):
--   * ehson_qarz: qarzdor_turi='shaxs', ism = Excel qatoridagi nom (aynan), pul_turi naqd (UZS) / dollar (USD), holat='faol',
--     muddat_turi='bir_martalik', tugash = 2099-12-31 (jadval talab qiladi: tugash NOT NULL). 2099 = «MUDDATSIZ» belgisi:
--     UI uni «Muddatsiz» deb ko'rsatadi, kechikkan bo'lmaydi. Izoh = Excel matni (+ shart: «har oylikdan 1 500 000 dan» ...).
--   * ehson_qarz_jadval: 1 qator (n=1, sana=2099-12-31, summa=asosiy). Pul v_ehson_kassa_pul.qarz_berildi orqali kassadan ayriladi.
--   * USD: fc_summa = dollar miqdori, summa = round(fc * conv_baza_kurs('USD')) (kurs yo'q bo'lsa USD qatorlari o'tkaziladi).
--   * ehson_tarix 'qarz'/'yaratildi'. entry/entry_line/accounts ga TEGILMAYDI.
--   * IDEMPOTENT: ext_ref 'excel_qarz_20261017:<kassa>:<n>' (unique) — qayta RUN qarzni ikkinchi marta yaratmaydi.
--   * Qoldiq tekshiruvi ataylab YO'Q (ehson_qarz_ber 'qoldiq_yetmadi' bergan bo'lardi). Qarzlar kassadan AYIRILADI; balans qayta to'g'irlanmaydi.
--  + ehson_qarz_muddat_set(p) — YANGI RPC: qarz muddatini UI'dan qo'yish (UI'da avval muddatni o'zgartirish yo'q edi).
--  ADDITIVE: hech narsa drop qilinmaydi. Asilbek RUN qiladi. Oxirida natija jadvali: qarzlar.
-- ============================================================================

-- ######## 0) OLD SHART (yo'q bo'lsa aniq xato) ########
do $eqr_pre$
begin
  if to_regclass('public.ehson_qarz') is null or to_regclass('public.ehson_qarz_jadval') is null then
    raise exception 'ehson_qarz yoq — avval PROVODKA_EHSON_QARZ.sql RUN qiling';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'v_ehson_kassa_pul' and column_name = 'qarz_berildi') then
    raise exception 'v_ehson_kassa_pul da qarz_berildi yoq — avval PROVODKA_EHSON_QARZ.sql RUN qiling';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ehson_kirim' and column_name = 'tur') then
    raise exception 'ehson_kirim.tur yoq — avval PROVODKA_EHSON_KIRIM.sql RUN qiling';
  end if;
  if to_regprocedure('public._ehson_balans_togrila_20261017()') is null then
    raise exception '_ehson_balans_togrila_20261017() yoq — avval PROVODKA_EHSON_KIRIM.sql RUN qiling';
  end if;
  if to_regprocedure('public._ehson_oy_qosh(date,integer)') is null then
    raise exception '_ehson_oy_qosh yoq — avval PROVODKA_EHSON_QARZ.sql RUN qiling';
  end if;
  if to_regprocedure('public._ehson_tarix_yoz(text,uuid,text,jsonb)') is null then
    raise exception '_ehson_tarix_yoz yoq';
  end if;
end
$eqr_pre$;


-- ######## 1) ehson_qarz_muddat_set(p) — muddatni UI'dan qo'yish ########
-- p: {id, muddat_turi:'bir_martalik'|'oylik', tugash (bir_martalik), boshlanish + oylar_soni (oylik)}
-- Faqat 'faol' qarz. Oyma-oy ga o'tish / oylik grafikni qayta qurish faqat TO'LOV YO'Q bo'lganda (FIFO taqsimot buzilmasin).
-- Bir martalik -> bir martalik (deadline almashtirish) to'lov bo'lsa ham mumkin (jadvaldagi bitta qatorning sanasi o'zgaradi).
-- Javob: {ok:true} | {ok:false,kod}. kod: ruxsat · topilmadi · holat · muddat_notogri · tolov_bor.
create or replace function ehson_qarz_muddat_set(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_id     uuid := nullif(p->>'id', '')::uuid;
  v_mt     text := nullif(p->>'muddat_turi', '');
  v_tugash date := nullif(p->>'tugash', '')::date;
  v_bosh   date := nullif(p->>'boshlanish', '')::date;
  v_oylar  int  := nullif(p->>'oylar_soni', '')::int;
  q        ehson_qarz;
  v_tolov  boolean;
  v_asosiy numeric;
  v_oylik  numeric;
  v_used   numeric := 0;
  v_row    numeric;
  v_i      int;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Avtorizatsiya kerak'); end if;
  if not ehson_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Ehson sahifasi ruxsatingizda yoq'); end if;

  select * into q from ehson_qarz where id = v_id for update;
  if not found then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if q.holat <> 'faol' then return jsonb_build_object('ok', false, 'kod', 'holat'); end if;

  select exists (select 1 from ehson_qarz_tolov t where t.qarz_id = q.id and t.is_deleted = false) into v_tolov;
  v_asosiy := case when q.valyuta = 'USD' then coalesce(q.fc_summa, 0) else q.summa end;

  if v_mt = 'bir_martalik' then
    if v_tugash is null or v_tugash < q.sana then return jsonb_build_object('ok', false, 'kod', 'muddat_notogri'); end if;
    if q.muddat_turi = 'bir_martalik' then
      update ehson_qarz_jadval set sana = v_tugash where qarz_id = q.id and n = 1;
      update ehson_qarz set tugash = v_tugash where id = q.id;
    else
      if v_tolov then return jsonb_build_object('ok', false, 'kod', 'tolov_bor'); end if;
      delete from ehson_qarz_jadval where qarz_id = q.id;
      update ehson_qarz set muddat_turi = 'bir_martalik', tugash = v_tugash, boshlanish = null, oylar_soni = null, oylik_summa = null
       where id = q.id;
      insert into ehson_qarz_jadval (qarz_id, n, sana, summa) values (q.id, 1, v_tugash, v_asosiy);
    end if;
  elsif v_mt = 'oylik' then
    if v_bosh is null or v_oylar is null or v_oylar < 1 or v_oylar > 120 then
      return jsonb_build_object('ok', false, 'kod', 'muddat_notogri');
    end if;
    if v_tolov then return jsonb_build_object('ok', false, 'kod', 'tolov_bor'); end if;
    v_oylik := case when q.valyuta = 'USD' then round(v_asosiy / v_oylar, 2) else floor(v_asosiy / v_oylar) end;
    if v_oylik <= 0 then return jsonb_build_object('ok', false, 'kod', 'muddat_notogri'); end if;
    v_tugash := _ehson_oy_qosh(v_bosh, v_oylar - 1);
    delete from ehson_qarz_jadval where qarz_id = q.id;
    update ehson_qarz set muddat_turi = 'oylik', boshlanish = v_bosh, tugash = v_tugash, oylar_soni = v_oylar, oylik_summa = v_oylik
     where id = q.id;
    for v_i in 1..v_oylar loop
      if v_i < v_oylar then v_row := v_oylik; v_used := v_used + v_row;
      else v_row := v_asosiy - v_used; end if;
      insert into ehson_qarz_jadval (qarz_id, n, sana, summa) values (q.id, v_i, _ehson_oy_qosh(v_bosh, v_i - 1), v_row);
    end loop;
  else
    return jsonb_build_object('ok', false, 'kod', 'muddat_notogri');
  end if;

  perform _ehson_tarix_yoz('qarz', q.id, 'muddat_ozgardi',
    jsonb_build_object('muddat_turi', v_mt, 'tugash', v_tugash, 'boshlanish', v_bosh, 'oylar_soni', v_oylar));
  return jsonb_build_object('ok', true);
end
$fn$;
revoke all on function ehson_qarz_muddat_set(jsonb) from public, anon;
grant execute on function ehson_qarz_muddat_set(jsonb) to authenticated;

comment on function ehson_qarz_muddat_set(jsonb) is
  'Faol qarz muddatini qo''yish/o''zgartirish (deadline yoki oyma-oy). 2099-12-31 = muddatsiz belgisi. Oyma-oy/turi almashtirish faqat to''lov yo''q bo''lganda.';


-- ######## 2) QARZLAR (bir martalik, idempotent) — natija jadvali qaytaradi ########
-- Kassa NOM bo'yicha topiladi (child, faol, konteyner emas) — bu bazada boshqa ishonchli belgi yo'q (PROVODKA_EHSON_KIRIM.sql bilan bir xil).
-- UZS summalar Excel'dagi qiymat x 1000 (Excel'da «000» kam yozilgan) — quyida allaqachon yakuniy so'mda.
create or replace function _ehson_qarz_royxat_20261017()
returns table (o_bolim text, o_nom text, o_kassa text, o_pul_turi text, o_valyuta text,
               o_summa numeric, o_oldin numeric, o_maqsad numeric, o_keyin numeric, o_holat text)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_bugun  date := (now() at time zone 'Asia/Tashkent')::date;
  v_muddatsiz constant date := date '2099-12-31';
  v_kurs   numeric;
  v_t      record;
  v_cnt    int;
  v_kassa  uuid;
  v_pt     ehson_pul_turi;
  v_ext    text;
  v_fc     numeric;
  v_summa  numeric;
  v_id     uuid;
begin
  if exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs' and oidvectortypes(pr.proargtypes) = 'text'
  ) then
    execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
  end if;

  -- ---------- A) QARZLAR ----------
  for v_t in
    select * from (values
      -- (n, kassa_key, kassa_nom, ism, pul_kod, valyuta, miqdor, izoh_qoshimcha)
      (1,  'ehson asosiy', 'Ehson asosiy', 'ASILBEK 43 AKSESSUR QARZ',                       'naqd',   'UZS', 10000000::numeric, null::text),
      (2,  'ehson asosiy', 'Ehson asosiy', 'ASILBEK ERMATOV',                                'dollar', 'USD', 100::numeric,      null),
      (3,  'ehson asosiy', 'Ehson asosiy', 'AZIZ STUDENT SENTYABIR OHIRIGACHA',              'naqd',   'UZS', 10000000::numeric, 'sentyabr oxirigacha'),
      (4,  'ehson asosiy', 'Ehson asosiy', 'BEGZOT QARSHI SHOVRUM HAR OYLIKDAN 1500 DAN',    'naqd',   'UZS', 13500000::numeric, 'har oylikdan 1 500 000 dan'),
      (5,  'ehson asosiy', 'Ehson asosiy', 'HUSNIDDIN GVARDIYA QARZ',                        'naqd',   'UZS', 5000000::numeric,  null),
      (6,  'ehson asosiy', 'Ehson asosiy', 'IBROHIM STUDENT',                                'dollar', 'USD', 500::numeric,      null),
      (7,  'ehson asosiy', 'Ehson asosiy', 'JAVLON AKA',                                     'naqd',   'UZS', 4000000::numeric,  null),
      (8,  'ehson asosiy', 'Ehson asosiy', 'KARIMBEK QARZ',                                  'dollar', 'USD', 5100::numeric,     null),
      (9,  'ehson asosiy', 'Ehson asosiy', 'SARVAR MACHIT',                                  'dollar', 'USD', 1000::numeric,     null),
      (10, 'ehson asosiy', 'Ehson asosiy', 'ULUG`BEK AKAMGA',                                'dollar', 'USD', 3000::numeric,     null),
      (11, 'ehson asosiy', 'Ehson asosiy', 'ULUG`BEK AKANI KUYOVI',                          'naqd',   'UZS', 10000000::numeric, null),
      (12, 'ehson asosiy', 'Ehson asosiy', 'ZAKOTGA',                                        'dollar', 'USD', 3800::numeric,     null),
      (21, 'ehson soliq',  'Ehson soliq',  'AKMAL SKLATCHI HAR OY 2500 MILDAN',              'naqd',   'UZS', 53500000::numeric, 'har oy 2 500 000 dan'),
      (22, 'ehson soliq',  'Ehson soliq',  'FERUZ AKAMDI BOXXI SNIFDOSHIGA',                 'dollar', 'USD', 1500::numeric,     null),
      (23, 'ehson soliq',  'Ehson soliq',  'Giyos',                                          'dollar', 'USD', 18000::numeric,    null),
      (24, 'ehson soliq',  'Ehson soliq',  'IZZAT SAMARQANT',                                'dollar', 'USD', 400::numeric,      null),
      (25, 'ehson soliq',  'Ehson soliq',  'MUHAMMAT AKA',                                   'dollar', 'USD', 2900::numeric,     null),
      (26, 'ehson soliq',  'Ehson soliq',  'NODIR AKA QARZ HAR OY 500 DAN',                  'dollar', 'USD', 17800::numeric,    'har oy 500 dan'),
      (27, 'ehson soliq',  'Ehson soliq',  'RAVSHAN DAMAZCHI 1500 DAN',                      'naqd',   'UZS', 5000000::numeric,  '1 500 000 dan'),
      (28, 'ehson soliq',  'Ehson soliq',  'SHERDIL AKA',                                    'naqd',   'UZS', 50000000::numeric, null),
      (29, 'ehson soliq',  'Ehson soliq',  'Sherzod sinfdosh',                               'dollar', 'USD', 7100::numeric,     null),
      (30, 'ehson soliq',  'Ehson soliq',  'SHOXRUX AKA',                                    'dollar', 'USD', 800::numeric,      null)
    ) as x(n, kassa_key, kassa_nom, ism, pul_kod, valyuta, miqdor, qosh)
    order by n
  loop
    o_bolim := 'QARZ'; o_nom := v_t.ism; o_kassa := v_t.kassa_nom; o_pul_turi := v_t.pul_kod; o_valyuta := v_t.valyuta;
    o_summa := v_t.miqdor; o_oldin := null; o_maqsad := null; o_keyin := null;

    select count(*), min(k.id::text)::uuid into v_cnt, v_kassa
      from ehson_kassa k
     where k.parent_id is not null and not k.is_container and k.is_active and lower(btrim(k.nom)) = v_t.kassa_key;
    if v_cnt <> 1 then
      o_holat := case when v_cnt = 0 then 'O''TKAZILDI: kassa nomi bo''yicha topilmadi' else 'O''TKAZILDI: bir nechta kassa shu nomda' end;
      return next; continue;
    end if;

    select * into v_pt from ehson_pul_turi where kassa_id = v_kassa and kod = v_t.pul_kod and is_active;
    if not found then
      o_holat := 'O''TKAZILDI: faol pul turi yoq'; return next; continue;
    end if;

    v_ext := 'excel_qarz_20261017:' || replace(v_t.kassa_key, ' ', '_') || ':' || v_t.n::text;
    if exists (select 1 from ehson_qarz where ext_ref = v_ext) then
      o_holat := 'allaqachon yaratilgan (o''tkazildi)'; return next; continue;
    end if;

    if v_t.valyuta = 'USD' then
      if v_kurs is null or v_kurs <= 0 then
        o_holat := 'O''TKAZILDI: USD kursi yoq (Valyuta bo''limida kurs kiriting, so''ng qayta RUN)'; return next; continue;
      end if;
      v_fc := v_t.miqdor;
      v_summa := round(v_fc * v_kurs);
    else
      v_fc := null;
      v_summa := v_t.miqdor;
    end if;

    perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || v_kassa::text));

    insert into ehson_qarz (kassa_id, pul_turi, valyuta, summa, fc_summa, qarzdor_turi, ism,
                            muddat_turi, tugash, sana, izoh, holat, ext_ref, created_by)
    values (v_kassa, v_pt.kod, v_t.valyuta, v_summa, v_fc, 'shaxs', v_t.ism,
            'bir_martalik', v_muddatsiz, v_bugun,
            'Excel ro''yxati 2026-10-17: ' || v_t.ism || coalesce(' (' || v_t.qosh || ')', ''),
            'faol', v_ext, null)
    returning id into v_id;

    insert into ehson_qarz_jadval (qarz_id, n, sana, summa) values (v_id, 1, v_muddatsiz, case when v_t.valyuta = 'USD' then v_fc else v_summa end);

    perform _ehson_tarix_yoz('qarz', v_id, 'yaratildi',
      jsonb_build_object('kassa_id', v_kassa, 'pul_turi', v_pt.kod, 'summa', v_summa, 'fc_summa', v_fc,
                         'valyuta', v_t.valyuta, 'qarzdor_turi', 'shaxs', 'ism', v_t.ism,
                         'muddat_turi', 'bir_martalik', 'manba', 'excel_20261017'));
    o_holat := 'YOZILDI';
    return next;
  end loop;

  return;
end
$fn$;

-- Faqat SQL editor (postgres/service_role) — brauzerdan chaqirilmaydi
revoke all on function _ehson_qarz_royxat_20261017() from public, anon, authenticated;

comment on function _ehson_qarz_royxat_20261017() is
  'Bir martalik: Excel ro''yxatidagi ehson qarzlari (asosiy/soliq). Idempotent. Balansga tegmaydi.';

-- NATIJA JADVALI: QARZ qatorlari (ism, kassa, summa, valyuta)
select * from _ehson_qarz_royxat_20261017();

notify pgrst, 'reload schema';

do $eqr_check$
begin
  if to_regprocedure('public.ehson_qarz_muddat_set(jsonb)') is null then raise exception 'ehson_qarz_muddat_set yaratilmadi'; end if;
  raise notice 'PROVODKA_EHSON_QARZ_ROYXAT_20261017.sql: hammasi joyida.';
end
$eqr_check$;
