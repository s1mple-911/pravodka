-- ============================================================================
--  PROVODKA_YUK_PROF_TANNARX.sql — 2026-09-15 (Asilbek)
--  «Tannarx qo'shish» endi Professional sahifasidan ham: xarajat yozayotganda
--  to'lov turi (tovar narxi / yo'l puli / bojxona / Abusaxiy …) tanlanadi va
--  bitta to'lov BIR NECHTA yukka taqsimlanib darhol bog'lanadi.
--
--  Asilbek qarorlari:
--    1) bitta xizmat to'lovi bir nechta yukka taqsimlanadi;
--    2) Aros bojxona limiti YANGI yo'lda faqat OGOHLANTIRADI (bloklamaydi) —
--       Yuklar sahifasidagi «Tannarx qo'shish» esa eskicha bloklaydi;
--    3) «tannarx» ruxsati yo'q foydalanuvchining to'lovi bog'lanmagan bo'lib
--       turaveradi (yukka bog'lashni ruxsatli xodim keyin qiladi).
--
--  BU FAYL ADDITIVE. Ikki marta RUN qilinsa ham xato bermaydi.
--  Old shart: PROVODKA_YUK_TANNARX.sql, PROVODKA_YUK_BOJXONA.sql,
--             PROVODKA_YUK_BOGLANMAGAN_V2.sql — RUN qilingan bo'lishi kerak
--             (0-BO'LIM buni tekshiradi va sababini aniq yozadi).
-- ============================================================================


-- ============================================================================
--  0-BO'LIM — OLD SHARTLAR
--  Nega kerak: 1-BO'LIMdagi funksiya tanasi `aros_yuk_bojxona` jadvalining
--  rowtype'iga tayanadi (u PROVODKA_YUK_BOJXONA.sql da yaratiladi), 2-BO'LIM
--  esa `entry.yuk_sabab_id` ustuniga (PROVODKA_YUK_BOGLANMAGAN_V2.sql).
--  Jimgina yarim ishlaydigan holatdan ko'ra ochiq xato yaxshiroq.
-- ============================================================================
do $chk$
begin
  if to_regclass('public.aros_yuk_bojxona') is null then
    raise exception 'Avval PROVODKA_YUK_BOJXONA.sql ni RUN qiling (aros_yuk_bojxona jadvali yo''q)';
  end if;
  if to_regprocedure('public._yuk_bojxona_fare_uzs(text, numeric)') is null then
    raise exception 'Avval PROVODKA_YUK_BOJXONA.sql ni RUN qiling (_yuk_bojxona_fare_uzs funksiyasi yo''q)';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'entry'
                    and column_name = 'yuk_sabab_id') then
    raise exception 'Avval PROVODKA_YUK_BOGLANMAGAN_V2.sql ni RUN qiling (entry.yuk_sabab_id ustuni yo''q)';
  end if;
  if to_regprocedure('public.yuk_tannarx_ruxsat()') is null then
    raise exception 'Avval PROVODKA_YUK_TANNARX.sql ni RUN qiling (yuk_tannarx_ruxsat funksiyasi yo''q)';
  end if;
  raise notice 'Old shartlar joyida — davom etamiz';
end
$chk$;


-- ============================================================================
--  1-BO'LIM — yuk_tannarx_qosh: yangi 5-chi argument p_limit_ogoh
--
--  Tana PROVODKA_YUK_BOJXONA.sql 6-BO'LIMdan AYNAN ko'chirilgan; YAGONA farq —
--  1.5-BOSQICHdagi bojxona limiti:
--     p_limit_ogoh = false (SUKUT) → eski xatti-harakat: {ok:false, kod:'limit'},
--                                    hech narsa yozilmaydi (Yuklar sahifasi shu holatda);
--     p_limit_ogoh = true          → limitdan oshsa ham YOZADI, faqat
--                                    `ogohlantirishlar` ga qator qo'shadi (Professional).
--
--  🔴 Imzo o'zgargani uchun avval DROP (42P13 saboqi), keyin darhol CREATE.
--     Eski 4 argumentli chaqiruvlar — yuklar-dev.html:1791 va yuk_boglash_koplik
--     ichidagi — sukut qiymat tufayli O'ZGARISHSIZ ishlayveradi.
-- ============================================================================
drop function if exists yuk_tannarx_qosh(jsonb, int, text, text);

create or replace function yuk_tannarx_qosh(p_data jsonb, p_sabab_id int,
                                            p_izoh text default null,
                                            p_kalit text default null,
                                            p_limit_ogoh boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_who    text;
  v_uid    uuid := auth.uid();
  v_kalit  text;
  v_sabab  yuk_tannarx_sabab;
  el       jsonb;
  v_yuk    integer;
  v_sum    numeric;
  v_izoh   text;
  v_xato   text;
  v_id     bigint;
  v_ok     int   := 0;
  v_skip   int   := 0;
  v_dup    int   := 0;
  v_rows   jsonb := '[]'::jsonb;
  v_warn   jsonb := '[]'::jsonb;
  v_map    jsonb := '{}'::jsonb;
  v_key    text;
  v_val    jsonb;
  v_n      int;
  -- ---- Aros bojxona limiti uchun ----
  v_bar_jadval boolean;
  v_boj        aros_yuk_bojxona%rowtype;
  v_limit_uzs  numeric;
  v_qoshilgan  numeric;
  v_yangi_jami numeric;
begin
  if not yuk_tannarx_ruxsat() then
    return jsonb_build_object('ok', false, 'kod', 'tannarx_ruxsat',
                              'error', 'Tannarx kiritish ruxsati yoq');
  end if;

  if p_data is null or jsonb_typeof(p_data) <> 'array' then
    return jsonb_build_object('ok', false, 'error',
      'p_data massiv bolishi kerak: [{"yuk_id":1204,"summa":5000000}]');
  end if;

  v_n := jsonb_array_length(p_data);
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'Birorta yuk tanlanmagan');
  end if;
  if v_n > 500 then
    return jsonb_build_object('ok', false, 'error',
      'Bir marta eng kopi 500 ta yuk. Hozir: ' || v_n);
  end if;

  select * into v_sabab from yuk_tannarx_sabab where id = p_sabab_id;
  if v_sabab.id is null then
    return jsonb_build_object('ok', false, 'error', 'Sabab topilmadi');
  end if;
  if not v_sabab.is_active then
    return jsonb_build_object('ok', false, 'error',
      'Bu sabab passiv qilingan: ' || v_sabab.nom);
  end if;

  -- ===== IDEMPOTENTLIK: shu kalit bilan allaqachon yozilganmi =====
  v_kalit := nullif(btrim(coalesce(p_kalit, '')), '');
  if v_kalit is not null then
    if length(v_kalit) > 80 then
      return jsonb_build_object('ok', false, 'error', 'p_kalit juda uzun (80 belgigacha)');
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
             'yuk_id', t.yuk_id, 'id', t.id, 'summa_uzs', t.summa_uzs)
             order by t.id), '[]'::jsonb)
      into v_rows
      from yuk_tannarx t
     where t.kalit = v_kalit and not t.is_deleted;

    if jsonb_array_length(v_rows) > 0 then
      return jsonb_build_object(
        'ok',              true,
        'takror',          true,
        'qoshildi',        0,
        'otkazildi',       0,
        'birlashtirildi',  0,
        'sabab',           v_sabab.nom,
        'qatorlar',        v_rows,
        'ogohlantirishlar',
          jsonb_build_array('Bu saqlash allaqachon bajarilgan — qayta yozilmadi'));
    end if;
    v_rows := '[]'::jsonb;
  end if;

  select coalesce(full_name, 'foydalanuvchi') into v_who
    from profiles where id = v_uid;
  v_who := coalesce(v_who, 'tizim');

  -- ===== 1-BOSQICH: tekshirish + bir xil yuk_id larni birlashtirish =====
  for el in select value from jsonb_array_elements(p_data) loop
    v_yuk  := null;
    v_sum  := null;
    v_xato := null;

    -- Cast xatolari butun sorovni yiqitmasin. Har maydon ALOHIDA tekshiriladi,
    -- aks holda buzuq `summa` yuzasidan "yuk_id notogri" deb yozilardi.
    begin
      v_yuk := nullif(el ->> 'yuk_id', '')::integer;
    exception when others then
      v_xato := 'yuk_id';
    end;
    begin
      v_sum := nullif(el ->> 'summa', '')::numeric;
    exception when others then
      v_xato := coalesce(v_xato || ' va summa', 'summa');
    end;

    v_izoh := nullif(btrim(coalesce(el ->> 'izoh', p_izoh, '')), '');

    if v_xato is not null then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('notogri qiymat (' || v_xato || '): '
                                   || coalesce(el::text, 'null'));
      continue;
    end if;

    if v_yuk is null then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('yuk_id yoq: ' || coalesce(el::text, 'null'));
      continue;
    end if;

    if v_sum is null or v_sum <= 0 then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('yuk ' || v_yuk || ': summa 0 yoki manfiy — otkazildi');
      continue;
    end if;

    -- Yaxlitlash TEKSHIRUVDAN OLDIN (jadvalda check summa_uzs > 0)
    v_sum := round(v_sum, 2);
    if v_sum <= 0 then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('yuk ' || v_yuk
                                   || ': summa yaxlitlangach 0 boldi — otkazildi');
      continue;
    end if;

    v_key := v_yuk::text;
    if v_map ? v_key then
      v_dup  := v_dup + 1;
      v_sum  := v_sum + coalesce((v_map -> v_key ->> 'summa')::numeric, 0);
      v_izoh := coalesce(nullif(v_map -> v_key ->> 'izoh', ''), v_izoh);
    end if;
    v_map := v_map || jsonb_build_object(v_key,
               jsonb_build_object('summa', v_sum, 'izoh', v_izoh));
  end loop;

  if v_dup > 0 then
    v_warn := v_warn || to_jsonb(v_dup
      || ' ta element bir xil yuk uchun kelgan — summalari qoshib birlashtirildi');
  end if;

  -- ===== 1.5-BOSQICH: Aros BOJXONA LIMITI =====
  -- Insertlardan OLDIN HAMMA elementni tekshiramiz. p_limit_ogoh = false bolsa
  -- birortasi limitdan oshsa BUTUN chaqiruv rad etiladi (eski xatti-harakat);
  -- true bolsa faqat ogohlantirish yoziladi va yozuv davom etadi (Asilbek, 2026-09-15).
  v_bar_jadval := (to_regclass('public.aros_yuk_bojxona') is not null);
  if v_bar_jadval then
    -- Poyga himoyasi: ikki parallel chaqiruv bir yukka bir vaqtda kelsa
    -- ikkalasi ham "limit ichida" deb otib ketmasin — tekshiruv + yozish bitta qulf ostida.
    perform pg_advisory_xact_lock(hashtext('yuk_tannarx_qosh_limit'));
    for v_key, v_val in select key, value from jsonb_each(v_map) order by key::integer loop
      v_yuk := v_key::integer;
      v_sum := (v_val ->> 'summa')::numeric;

      select * into v_boj from aros_yuk_bojxona where yuk_id = v_yuk;
      if v_boj.yuk_id is null then
        v_warn := v_warn || to_jsonb('Yuk #' || v_yuk
          || ': Aros bojxona malumoti hali sinxron bolmagan');
        continue;
      end if;

      v_limit_uzs := coalesce(v_boj.bojxona_uzs, 0)
                   + _yuk_bojxona_fare_uzs(v_boj.currency, v_boj.fare_cur);

      if v_limit_uzs <= 0 then
        continue;                     -- limit malum emas / nol — tekshiruv otkazib yuboriladi
      end if;

      select coalesce(sum(t.summa_uzs), 0) into v_qoshilgan
        from yuk_tannarx t
       where t.yuk_id = v_yuk and not t.is_deleted;

      v_yangi_jami := v_qoshilgan + v_sum;

      if v_yangi_jami > v_limit_uzs then
        if p_limit_ogoh then
          v_warn := v_warn || to_jsonb('Yuk #' || v_yuk || ': Aros bojxona limitidan '
            || replace(to_char(v_yangi_jami - v_limit_uzs, 'FM999G999G999G999'), ',', ' ')
            || ' som oshdi (limit '
            || replace(to_char(v_limit_uzs, 'FM999G999G999G999'), ',', ' ')
            || ', qoshilgan '
            || replace(to_char(v_qoshilgan, 'FM999G999G999G999'), ',', ' ')
            || ') — ogohlantirish, yozildi');
        else
          return jsonb_build_object(
            'ok', false,
            'kod', 'limit',
            'error', 'Yuk #' || v_yuk || ': Aros bojxona '
              || replace(to_char(v_limit_uzs, 'FM999G999G999G999'), ',', ' ')
              || ', qoshilgan ' || replace(to_char(v_qoshilgan, 'FM999G999G999G999'), ',', ' ')
              || ', yana ' || replace(to_char(v_sum, 'FM999G999G999G999'), ',', ' ')
              || ' qoshib bolmaydi (qoldi '
              || replace(to_char(greatest(v_limit_uzs - v_qoshilgan, 0), 'FM999G999G999G999'), ',', ' ')
              || ')',
            'yuk_id', v_yuk,
            'limit_uzs', v_limit_uzs,
            'qoshilgan_uzs', v_qoshilgan,
            'qoldi_uzs', greatest(v_limit_uzs - v_qoshilgan, 0));
        end if;
      end if;
    end loop;
  end if;

  -- ===== 2-BOSQICH: yozish =====
  for v_key, v_val in select key, value from jsonb_each(v_map) order by key::integer loop
    v_yuk  := v_key::integer;
    v_sum  := (v_val ->> 'summa')::numeric;
    v_izoh := nullif(v_val ->> 'izoh', '');
    v_id   := null;

    -- Poyga holati (ikki sorov bir vaqtda, bir xil kalit): unique indeks
    -- tosadi, `do nothing` uni jimgina otkazadi va v_id null qoladi.
    insert into yuk_tannarx (yuk_id, sabab_id, summa_uzs, izoh, kalit,
                             created_by, created_by_name)
    values (v_yuk, v_sabab.id, v_sum, v_izoh, v_kalit, v_uid, v_who)
    on conflict (kalit, yuk_id) where kalit is not null and not is_deleted
    do nothing
    returning id into v_id;

    if v_id is null then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('yuk ' || v_yuk
                                   || ': shu kalit bilan allaqachon yozilgan — otkazildi');
      continue;
    end if;

    v_ok   := v_ok + 1;
    v_rows := v_rows || jsonb_build_object('yuk_id', v_yuk, 'id', v_id,
                                           'summa_uzs', v_sum);
  end loop;

  return jsonb_build_object(
    'ok',              true,
    'takror',          false,
    'qoshildi',        v_ok,
    'otkazildi',       v_skip,
    'birlashtirildi',  v_dup,
    'sabab',           v_sabab.nom,
    'qatorlar',        v_rows,
    'ogohlantirishlar', v_warn);
end
$fn$;

revoke all on function yuk_tannarx_qosh(jsonb, int, text, text, boolean) from public, anon;
grant execute on function yuk_tannarx_qosh(jsonb, int, text, text, boolean) to authenticated;

comment on function yuk_tannarx_qosh(jsonb, int, text, text, boolean) is
  'Bir nechta yukka birdan tannarx qoshadi. PUL HARAKATI YOQ. p_kalit — idempotentlik. '
  'p_limit_ogoh=false (sukut): Aros bojxona limitidan oshsa {ok:false,kod:limit} va hech narsa '
  'yozilmaydi (Yuklar sahifasi). true: yozadi, ogohlantirishlar ga qator qoshadi (Professional).';


-- ============================================================================
--  2-BO'LIM — yuk_boglash_taqsim: BITTA bog'lanmagan to'lovni BIR NECHTA yukka
--
--  yuk_boglash_koplik ning teskarisi: u N ta to'lovni 1 ta yukka bog'laydi,
--  bu esa 1 ta to'lovni N ta yukka TAQSIMLAB bog'laydi (Professional'da xizmat
--  to'lovi bir nechta yukka tegishli bo'lganda kerak).
--
--  Yozish qismi yuk_boglash / yuk_boglash_koplik bilan AYNAN bir xil:
--    entry_yuk upsert · 9110-1 Dt satri → 9110 · entry.yuk_kutilmoqda=false +
--    yuk_ids · entry_history · sabab bo'lsa yuk_tannarx_qosh(kalit='entry:<id>').
--  Kalit o'sha-o'sha ('entry:<id>') — yuk_boglash_bekor uni tanib o'chiradi.
-- ============================================================================
create or replace function yuk_boglash_taqsim(p_entry uuid,
                                              p_taqsim jsonb,
                                              p_qoldiq jsonb default null,
                                              p_limit_ogoh boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
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
  v_entry_sum numeric;
  v_deleted   boolean;
  v_kutil     boolean;
  v_status    text;
  v_sabab     integer;
  v_desc      text;
  v_9110      uuid;
  v_9110_1    uuid;
  v_line_id   uuid;
  v_snap      jsonb;
  v_ids       integer[] := '{}'::integer[];
  v_nomlar    text := '';
  v_tan       jsonb := null;
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

  perform pg_advisory_xact_lock(hashtext('yuk_boglash_taqsim'));

  begin  -- ichki blok: xato bolsa SHU BLOKDAGI hamma yozuv bekor (savepoint)

    -- ===== 1-BOSQICH: tekshiruv (yozishdan OLDIN) =====
    select is_deleted, coalesce(yuk_kutilmoqda, false), status, yuk_sabab_id, description
      into v_deleted, v_kutil, v_status, v_sabab, v_desc
      from entry where id = p_entry;
    if not found then
      v_err := jsonb_build_object('ok', false, 'kod', 'topilmadi', 'error', 'Yozuv topilmadi');
      raise exception 'yuk_boglash_taqsim: topilmadi';
    end if;
    if v_deleted then
      v_err := jsonb_build_object('ok', false, 'kod', 'ochirilgan',
                                   'error', 'O''chirilgan yozuvni bog''lab bo''lmaydi');
      raise exception 'yuk_boglash_taqsim: ochirilgan';
    end if;
    if coalesce(v_status, '') <> 'posted' then
      v_err := jsonb_build_object('ok', false, 'kod', 'holat',
                                   'error', 'Yozuv holati posted emas: ' || coalesce(v_status, 'null'));
      raise exception 'yuk_boglash_taqsim: holat';
    end if;
    if not v_kutil then
      v_err := jsonb_build_object('ok', false, 'kod', 'yolda_emas',
                                   'error', 'Bu yozuv hujjat kutmayapti (allaqachon bog''langan yoki oddiy yozuv)');
      raise exception 'yuk_boglash_taqsim: yolda_emas';
    end if;

    select coalesce(sum(debit), 0) into v_entry_sum from entry_line where entry_id = p_entry;

    select id into v_line_id from entry_line
     where entry_id = p_entry and account_id = v_9110_1 and debit > 0
     limit 1;
    if v_line_id is null then
      v_err := jsonb_build_object('ok', false, 'kod', 'satr_yoq',
                                   'error', 'Bu yozuvda "yo''ldagi tovar" (9110-1) satri yo''q');
      raise exception 'yuk_boglash_taqsim: satr_yoq';
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
        raise exception 'yuk_boglash_taqsim: notogri';
      end if;
      v_sum := round(v_sum, 2);
      v_key := v_yuk::text;
      if v_map ? v_key then
        v_sum := v_sum + coalesce((v_map -> v_key ->> 'summa')::numeric, 0);
      end if;
      v_map := v_map || jsonb_build_object(v_key, jsonb_build_object('summa', v_sum));
    end loop;

    select coalesce(sum((value ->> 'summa')::numeric), 0) into v_total from jsonb_each(v_map);

    -- Taqsimot yozuv summasiga AYNAN teng bolsin (1 tiyin xatolikka yol qoyiladi)
    if abs(v_total - v_entry_sum) > 0.01 then
      v_err := jsonb_build_object('ok', false, 'kod', 'summa_notogri',
                                   'error', 'Taqsimot yozuv summasiga teng emas',
                                   'kerak', v_entry_sum, 'berilgan', v_total);
      raise exception 'yuk_boglash_taqsim: summa_notogri';
    end if;

    -- Tovar to'lovi (sababsiz) har yuk qoldig'idan oshmasin. Qoldiqni server
    -- bilmaydi — klient beradi (yuk_boglash_koplik dagi bir xil qoida).
    -- Xizmat to'lovi (sabab bor) tekshirilmaydi: u tannarxni O'ZI oshiradi.
    if v_sabab is null and p_qoldiq is not null and jsonb_typeof(p_qoldiq) = 'object' then
      for v_key, v_val in select key, value from jsonb_each(v_map) order by key::integer loop
        v_qoldiq := nullif(p_qoldiq ->> v_key, '')::numeric;
        v_sum    := (v_val ->> 'summa')::numeric;
        if v_qoldiq is not null and v_sum > v_qoldiq + 0.01 then
          v_err := jsonb_build_object('ok', false, 'kod', 'qoldiq',
                                       'error', 'Yuk #' || v_key || ': to''lov yuk qoldig''idan oshib ketdi',
                                       'yuk_id', v_key::integer, 'summa', v_sum, 'qoldiq_uzs', v_qoldiq);
          raise exception 'yuk_boglash_taqsim: qoldiq';
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

    update entry_line set account_id = v_9110 where id = v_line_id;

    update entry
       set yuk_kutilmoqda = false,
           yuk_ids = (select coalesce(array_agg(distinct x), '{}'::integer[])
                        from unnest(coalesce(yuk_ids, '{}'::integer[]) || v_ids) x),
           edited_at = now(),
           edited_by_name = v_who
     where id = p_entry;

    insert into entry_history (entry_id, action, snapshot, changed_by_name)
    values (p_entry, 'edit',
            jsonb_build_object('note', 'Yukka bog''landi (taqsim): ' || v_nomlar,
                               'summa_uzs', v_total, 'old', v_snap),
            v_who);

    -- Xizmat to'lovi bo'lsa — tannarx qatorlari (BITTA chaqiruv, massiv bilan).
    -- Kalit har doim 'entry:<id>' — takror bog'lanishda ikkinchi marta yozilmaydi.
    if v_sabab is not null then
      v_tan := yuk_tannarx_qosh(
        (select coalesce(jsonb_agg(jsonb_build_object(
                  'yuk_id', key::integer, 'summa', (value ->> 'summa')::numeric)
                  order by key::integer), '[]'::jsonb)
           from jsonb_each(v_map)),
        v_sabab, v_desc, 'entry:' || p_entry::text, p_limit_ogoh);

      if coalesce((v_tan ->> 'ok')::boolean, false) is not true then
        if v_tan ? 'kod' then
          v_err := v_tan;
        elsif position('ruxsat' in coalesce(v_tan ->> 'error', '')) > 0 then
          v_err := v_tan || jsonb_build_object('kod', 'tannarx_ruxsat');
        else
          v_err := v_tan || jsonb_build_object('kod', 'tannarx_xato');
        end if;
        raise exception 'yuk_boglash_taqsim: tannarx';
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
    'ok',        true,
    'entry_id',  p_entry,
    'yuk_ids',   to_jsonb(v_ids),
    'sabab_id',  v_sabab,
    'tovar_uzs', case when v_sabab is null then v_total else 0 end,
    'xizmat_uzs',case when v_sabab is null then 0 else v_total end,
    'tannarx',   v_tan,
    'ogohlantirishlar', v_warn);
end
$fn$;

revoke all on function yuk_boglash_taqsim(uuid, jsonb, jsonb, boolean) from public, anon;
grant execute on function yuk_boglash_taqsim(uuid, jsonb, jsonb, boolean) to authenticated;

comment on function yuk_boglash_taqsim(uuid, jsonb, jsonb, boolean) is
  'BITTA bog''lanmagan to''lovni (yuk_kutilmoqda) bir nechta yukka TAQSIMLAB bog''laydi. '
  'Taqsimot yigindisi yozuv summasiga teng bolishi shart. Sabab (xizmat turi) bor bolsa '
  'yuk_tannarx qatorlari ham yoziladi (kalit entry:<id>). Atomik: xato bolsa hech narsa yozilmaydi.';


-- ============================================================================
--  3-BO'LIM — DIAG (natijani Asilbek RUN natijasida ko'radi)
--  🔴 Funksiya mavjudligi oidvectortypes(proargtypes) bilan tekshiriladi —
--     pg_get_function_identity_arguments parametr NOMINI ham qaytaradi va
--     solishtiruv har doim false bo'lib qolardi (PROVODKA_AYLANMA saboqi).
-- ============================================================================
do $diag$
declare
  v_qosh    int;
  v_taqsim  int;
  v_grant1  boolean;
  v_grant2  boolean;
begin
  select count(*) into v_qosh
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'yuk_tannarx_qosh'
     and oidvectortypes(p.proargtypes) = 'jsonb, integer, text, text, boolean';

  select count(*) into v_taqsim
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'yuk_boglash_taqsim'
     and oidvectortypes(p.proargtypes) = 'uuid, jsonb, jsonb, boolean';

  v_grant1 := has_function_privilege('authenticated',
                'public.yuk_tannarx_qosh(jsonb, int, text, text, boolean)', 'execute');
  v_grant2 := has_function_privilege('authenticated',
                'public.yuk_boglash_taqsim(uuid, jsonb, jsonb, boolean)', 'execute');

  raise notice '--- PROVODKA_YUK_PROF_TANNARX DIAG ---';
  raise notice 'yuk_tannarx_qosh (5 arg, p_limit_ogoh): % ta', v_qosh;
  raise notice 'yuk_boglash_taqsim: % ta', v_taqsim;
  raise notice 'grant authenticated: qosh=% taqsim=%', v_grant1, v_grant2;

  if v_qosh <> 1 or v_taqsim <> 1 then
    raise exception 'YAKUNIY TEKSHIRUV: funksiyalar kutilganday yaratilmadi (qosh=%, taqsim=%)',
      v_qosh, v_taqsim;
  end if;
  if not v_grant1 or not v_grant2 then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun execute ruxsati berilmagan';
  end if;
  raise notice 'HAMMASI JOYIDA';
end
$diag$;
