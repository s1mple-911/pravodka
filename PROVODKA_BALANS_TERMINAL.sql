-- ============================================================================
--  PROVODKA_BALANS_TERMINAL.sql — 2026-09-19 — Balans Sync (filial kirim) TERMINAL turi + yangi Aros shakli
--  HODISA: 2026-09-08 dan filial kassalariga KIRIM (Dt filial tur-hisobi / Kt 9010) yozilmay qoldi,
--  transferlar (Kt) yozilaverdi → HAMMA filial kassa manfiyga ketdi (kassa sahifasi). Sabab — Aros
--  adminka yangilanishi: cachier detail `balances[]` shakli o'zgargan (label → label_code, payme → terminal),
--  n8n «Build Payload» eski `label` ni o'qiydi → payload'da cash/click/... YO'Q → RPC hech narsa yozmaydi.
--  Bu fayl SERVER tomonini tayyorlaydi (terminal turi), n8n «Build Payload» kodi — N8N_BALANS_SYNC_BUILD_PAYLOAD.js
--  (Asilbek n8n'da QO'LDA almashtiradi — update_workflow kreditlarni uzadi).
--  Additive: view create or replace (ustunlar bir xil), RPC imzosi bir xil (tana verbatim + 2 qator).
--  Tur-hisoblar: PROVODKA_TERMINAL_TUR.sql (terminal_tur_toldir) avval RUN qilingan bo'lsin.
-- ============================================================================

-- 1) mapping view — terminal
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
  and (c.pul_turi in ('naqd','click','payme','terminal') or c.currency = 'USD')
where k.section = 'pul'
  and k.is_active
  and k.parent_id is null          -- kassaning o'zi, bola-hisob emas
  and coalesce(k.currency,'UZS') = 'UZS'
  and k.filial_ref is not null;    -- Aros bilan bog'langan kassalar

-- 2) sync_filial_balans — tana PROVODKA_SYNC_BALANS.sql dan VERBATIM, faqat tur ro'yxatiga 'terminal' qo'shildi
create or replace function sync_filial_balans(p_data jsonb, p_dry_run boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
  v_baza_rate numeric;    -- Provodka joriy kursi (JSON'da kurs bo'lmasa ishlatiladi)
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

  v_map_soni  bigint;    -- RPC ICHIDA mapping nechta qator ko'rinadi
  v_fil_qator int;       -- shu filial_ref uchun nechta qator bor
  v_wh        text;      -- ref warehouse_id sifatida mos keldimi (chalkashlik diagnostikasi)
  v_reflar    text;      -- mavjud filial_ref lardan namuna

  n_filial    int := 0;
  n_yozuv     int := 0;
  n_otkaz     int := 0;
  -- ⬇️ DIAGNOSTIKA: "yozuvlar: 0, tafsilot: []" ning UCH xil sababi bor edi va
  --    javobda ular bir xil ko'rinardi. Endi ajratiladi:
  --      n_tegilmadi  — JSON'da maydon yo'q/null (n8n yubormagan)   -> TEGILMADI
  --      n_ozgarmagan — maydon keldi, lekin delta = 0               -> HAQIQATAN teng
  --    Ikkovi 0 bo'lsa — filial umuman kelmagan (n_filial ga qara).
  n_tegilmadi int := 0;
  n_ozgarmagan int := 0;
  v_nol       jsonb := '[]'::jsonb;   -- delta=0 qatorlar (faqat dry_run'da qaytadi)
  v_ogoh      jsonb := '[]'::jsonb;
  v_tafsil    jsonb := '[]'::jsonb;
begin
  -- ---- 0. Bir vaqtda ikkita sync ishlamasin ------------------------
  -- Ikki chaqiruv bir paytda kelsa ikkalasi ham "joriy qoldiq" ni bir xil
  -- o'qib, deltani IKKI MARTA yozib yuborardi. Lock tranzaksiya oxirida
  -- o'zi bo'shaydi.
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
  -- Bu SECURITY DEFINER funksiya — ichkarida joriy foydalanuvchi funksiya
  -- EGASI bo'ladi, tashqaridagi service_role emas. v_filial_sync_mapping esa
  -- security_invoker=on. Ya'ni "tashqarida 124 qator, ichkarida 0" bo'lishi
  -- nazariy jihatdan mumkin — shuning uchun aniq o'lchab, aytib qo'yamiz.
  select count(*) into v_map_soni from v_filial_sync_mapping;
  raise notice 'v_filial_sync_mapping: RPC ichida % qator ko''rinyapti', v_map_soni;

  if v_map_soni = 0 then
    return jsonb_build_object('ok', false,
      'error', 'v_filial_sync_mapping RPC ichida BO''SH (tashqarida qator bo''lsa ham). '
               || 'Bu grant/RLS masalasi — SEED yoki taqqoslash masalasi emas.',
      'mapping_soni', 0);
  end if;

  -- Mavjud filial_ref lardan namuna — topilmasa nima bilan solishtirilganini ko'rsatish uchun
  select string_agg(x, ', ' order by x)
    into v_reflar
    from (select distinct btrim(m.filial_ref::text) as x
            from v_filial_sync_mapping m limit 12) s;

  -- ---- 2.1 Zaxira dollar kursi -------------------------------------
  -- JSON'da dollar_rate bo'lmasa Provodka'ning joriy kursi ishlatiladi:
  -- conv_baza_kurs('USD') -> aros_usd_rate(), u bo'lmasa currency_rate'dagi
  -- oxirgisi. Ya'ni n8n kursni umuman yubormasligi ham mumkin.
  -- Bir marta hisoblanadi (butun sync uchun bitta kurs).
  -- to_regprocedure: bu fayl PROVODKA_KASSA2.sql tartibiga bog'lanib qolmasin.
  if to_regprocedure('public.conv_baza_kurs(text)') is not null then
    begin
      execute 'select conv_baza_kurs($1)' into v_baza_rate using 'USD';
    exception when others then
      v_baza_rate := null;   -- kurs olinmasa sync to'xtamasin, dollar o'tkaziladi
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
    -- Kurs: JSON'dagisi USTUN, bo'lmasa Provodka joriy kursi
    v_rate := coalesce(nullif(v_el ->> 'dollar_rate', '')::numeric, v_baza_rate);
    v_kurs_manba := case
                      when nullif(v_el ->> 'dollar_rate', '') is not null then 'json'
                      when v_baza_rate is not null then 'provodka'
                      else null
                    end;

    -- ---- Filial mapping'da bormi (turlar bo'yicha aylanishdan OLDIN) ----
    -- Bo'lmasa to'rtta bir xil "hisob topilmadi" o'rniga BITTA aniq xabar,
    -- va eng ko'p uchraydigan sababni darrov tekshiramiz: n8n cachier id
    -- o'rniga warehouse id yuborayotgan bo'lishi mumkin (accounts'da ikkovi
    -- alohida ustun: filial_ref = cachier, warehouse_id = warehouse).
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

    -- ---- har tur ----
    foreach v_maydon in array array['cash','click','payme','terminal','dollar_usd']
    loop
      -- Aros qiymati. Maydon yo'q yoki null bo'lsa — TEGMAYMIZ (0 emas!)
      -- ⚠️ Bu JIMGINA o'tkazish edi: n8n cash/click/payme ni umuman yubormasa
      --    javob "yozuvlar: 0, tafsilot: []" bo'lardi — xuddi "hammasi teng"
      --    kabi. Endi sanaladi va javobda alohida ko'rinadi.
      if (v_el -> v_maydon) is null or jsonb_typeof(v_el -> v_maydon) = 'null' then
        n_tegilmadi := n_tegilmadi + 1;
        continue;
      end if;
      v_yangi := (v_el ->> v_maydon)::numeric;

      -- Child hisobni mapping'dan topamiz.
      -- ⚠️ TAQQOSLASH: ikkala tomon ham ::text va btrim qilinadi.
      --    Avval faqat v_ref btrim qilinardi — bazadagi qiymatda ko'rinmas
      --    bo'sh joy ('20 ') bo'lsa moslik topilmasdi.
      --    Ikkinchi shart: raqamli yozilish farqi ('20' va '20.0', '020')
      --    ham to'sib qo'ymasin — ikkovi ham raqam bo'lsa son sifatida solishtiriladi.
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
        -- Filial mapping'da BOR (yuqorida tekshirildi), lekin aynan shu TUR yo'q.
        -- Ya'ni o'sha kassada bu tur child'i ochilmagan.
        v_ogoh := v_ogoh || jsonb_build_object(
          'filial_ref', v_ref, 'aros_maydon', v_maydon,
          'sabab', 'bu filialda "' || v_maydon || '" turi uchun hisob yo''q — '
                   || 'PROVODKA_VALYUTA_SEED.sql o''sha kassaga ochmaganmi?');
        continue;
      end if;

      -- ---- TO'SIQ: topilgan hisob HAQIQATAN kassa tur child'imi ----------
      -- v_acc faqat v_filial_sync_mapping'dan keladi, ya'ni nazariy jihatdan
      -- boshqa narsa bo'lishi mumkin emas. Lekin bu PUL yozadigan funksiya:
      -- view kelajakda o'zgarsa yoki kimdir uni qayta yozsa, xato jimgina
      -- o'tib ketmasin. Shart: hisob section='pul' + biror kassaning bolasi +
      -- (pul_turi to'ldirilgan yoki USD). Ombor (section='tovar'), mustaqil
      -- hisob yoki boshqa har qanday narsa shu yerda to'xtaydi.
      if not exists (
            select 1
              from accounts c
              join accounts k on k.id = c.parent_id
             where c.id = v_acc
               and c.is_active and c.section = 'pul'
               and (c.pul_turi in ('naqd','click','payme','terminal') or c.currency = 'USD')
               and k.is_active and k.section = 'pul' and k.parent_id is null
          ) then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object(
          'filial_ref', v_ref, 'aros_maydon', v_maydon, 'account_id', v_acc,
          'sabab', 'XAVFSIZLIK: topilgan hisob kassa tur child''i EMAS — yozilmadi. '
                   || 'v_filial_sync_mapping buzilgan bo''lishi mumkin.');
        continue;
      end if;

      -- Joriy qoldiq + yozuv bor-yo'qligi (bitta o'qishda)
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

      -- Delta: dollar DOLLARDA, qolgani so'mda
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

      -- Yo'nalish va qarshi hisob
      if v_delta_uzs > 0 then
        v_dt := v_acc;
        v_kt := case when v_birinchi then v_kapital else v_9010 end;
      else
        v_dt := case when v_birinchi then v_kapital else v_9010 end;
        v_kt := v_acc;
      end if;
      v_summa := abs(v_delta_uzs);

      -- Himoya: so'm summasi 0 ga yaxlitlansa (juda kichik dollar deltasi)
      -- ikkala satr ham 0 bo'lib qolardi — entry_line cheklovi buni rad etadi
      -- ("bir satrda faqat bittasi > 0"). Yozmaymiz, lekin aytamiz.
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
        -- dollar uchun: qaysi kurs ishlatildi va qayerdan olindi
        'kurs', case when v_maydon = 'dollar_usd' then v_rate else null end,
        'kurs_manba', case when v_maydon = 'dollar_usd' then v_kurs_manba else null end);

      if p_dry_run then
        n_yozuv := n_yozuv + 1;
        continue;
      end if;

      -- Yozuv: bitta entry, ikki satr. Dt = Kt (trigger ham tekshiradi).
      insert into entry(entry_date, description, source, status, created_by, fc_rate)
      values (current_date,
              v_izoh || ' · ' || coalesce(v_kassa, '') || ' · ' || coalesce(v_tur, v_maydon),
              'aros_auto', 'posted', 'aros_sync',
              case when v_maydon = 'dollar_usd' then v_rate else null end)
      returning id into v_entry;

      -- fc_amount FAQAT valyuta hisobi satriga va HAR DOIM musbat
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
    -- Voronka: filiallar × 4 tur = tegilmadi + ozgarmagan + yozuvlar + otkazildi
    --   tegilmadi  > 0  -> n8n o'sha maydonni YUBORMAGAN (Aros javobi/Build Payload)
    --   ozgarmagan > 0  -> maydon keldi, daftar Aros'ga TENG (haqiqatan o'zgarish yo'q)
    --   ikkovi ham 0    -> filial mapping'ga tushmagan yoki massiv bo'sh kelgan
    'tegilmadi', n_tegilmadi,
    'ozgarmagan', n_ozgarmagan,
    'ozgarmagan_royxat', case when p_dry_run then v_nol else '[]'::jsonb end,
    'mapping_soni', v_map_soni,          -- RPC ICHIDA ko'ringan qatorlar
    'mavjud_reflar', v_reflar,           -- namuna: nima bilan solishtirildi
    'ogohlantirishlar', v_ogoh,
    'tafsilot', v_tafsil);
end $$;

select aros_maydon, count(*) as hisob from v_filial_sync_mapping group by 1 order by 1;
