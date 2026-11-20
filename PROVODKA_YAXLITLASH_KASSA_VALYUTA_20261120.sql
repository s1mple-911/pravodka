-- ============================================================================
--  PROVODKA_YAXLITLASH_KASSA_VALYUTA_20261120.sql — 2026-11-20 — yuk yaxlitlashi KASSA valyutasi bo'yicha
--
--  HOLAT (Asilbek, Professional #3201): hujjat 650 000 so'm (UZS), to'lov USD kassadan 54 $ (= 650 700 so'm).
--  PROVODKA_YAXLITLASH_20261120.sql dagi yuk_yaxlitlash_yop HUJJAT valyutasi (UZS, chegara 10 000) bo'yicha
--  floor/ceil tekshirardi: qoldiq 650 000 o'zi 10 000 ning karralisi -> faqat AYNAN 53,94 $ o'tadi, 54 $ rad.
--  Naqd pul esa KASSA valyutasi birligida beriladi (butun dollar) — yaxlitlash birligi ham shu bo'lishi kerak.
--
--  QOIDA (yangi): to'lov kassasi valyutasi hujjat valyutasidan FARQ qilsa — chegara = yaxlitlash_chegara(KASSA valyutasi),
--  floor/ceil tekshiruvi kassa valyutasida (53,94 $ -> 53 yoki 54 $ ✓, 52/55 ✗), yopish chegarasi hujjat valyutasiga
--  kassa kursi bilan o'giriladi (1 $ = 12 050 so'm). Valyutalar bir xil bo'lsa — eski qoida aynan.
--  Kassa valyutasi = to'lov yozuvining eng katta KREDIT satri hisobining `currency` si (Kt kassa);
--  kassa kursi = o'sha satr credit/fc_amount (yozuvning o'z kursi), bo'lmasa _yuk_kurs_sanada(kassa_valyuta, bugun).
--
--  Imzo o'zgarmagan (create or replace). Faqat yuk_yaxlitlash_yop; qarz_ob_tolov/qarz_tolov/ehson da kassa valyutasi
--  qarz valyutasiga teng bo'lishi shart edi (valyuta_mos_emas) — ularga tegilmaydi.
--  Klient jufti: professional-dev.html `yukOrtiqLim` — chegara to'lov birligi valyutasidan (`yukYaxlLimVal(u.cur)`).
--  OLD SHART: PROVODKA_YAXLITLASH_20261120.sql RUN qilingan (yaxlitlash_chegara, _yaxlit_mos, _yaxlit_yoz, yuk_yopiq.kalit).
--  Additive, idempotent. Asilbek RUN qiladi.
-- ============================================================================

do $chk$
begin
  if to_regprocedure('public.yuk_yaxlitlash_yop(text)') is null or to_regprocedure('public._yaxlit_mos(numeric,numeric,numeric)') is null then
    raise exception 'PROVODKA_YAXLITLASH_20261120.sql avval RUN qilinishi kerak (yuk_yaxlitlash_yop/_yaxlit_mos yoq)';
  end if;
end
$chk$;

create or replace function yuk_yaxlitlash_yop(p_ext_ref text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid       uuid := auth.uid();
  v_ext       text := nullif(btrim(coalesce(p_ext_ref, '')), '');
  v_id        uuid;
  v_created   timestamptz;
  v_owner_raw text;
  v_owner     uuid;
  v_status    text;
  v_del       boolean;
  v_kim       text;
  ey          record;
  s           record;
  v_kurs      numeric;
  v_tan_uzs   numeric;
  v_jami      numeric;
  v_tol       jsonb;
  v_tol_fc    numeric;
  v_qoldi     numeric;
  v_chegara   numeric;        -- yopish chegarasi, HUJJAT valyutasida
  v_pay_fc    numeric;
  v_grp       uuid;
  v_n         integer := 0;
  v_ort_uzs   numeric := 0;
  v_dt_acc    uuid;
  v_izoh      text := '';
  -- kassa (to'lov) valyutasi
  v_kcur      text;
  v_kcredit   numeric;
  v_kfc       numeric;
  v_kkurs     numeric;
  v_kcheg     numeric;
  v_mos       boolean;
  v_dcur      text;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if v_ext is null then
    return jsonb_build_object('ok', false, 'kod', 'ext_ref_kerak');
  end if;

  select e.id, e.created_at, (to_jsonb(e) ->> 'created_by'), e.status, e.is_deleted
    into v_id, v_created, v_owner_raw, v_status, v_del
    from entry e where e.ext_ref = v_ext limit 1;
  if v_id is null then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if v_del or v_status is distinct from 'posted' then return jsonb_build_object('ok', false, 'kod', 'holat'); end if;
  v_owner := case when v_owner_raw ~ '^[0-9a-fA-F-]{36}$' then v_owner_raw::uuid end;
  if v_owner is distinct from v_uid and not coalesce(is_admin(), false) then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat_yoq');
  end if;
  if v_created is null or v_created < now() - interval '30 minutes' then
    return jsonb_build_object('ok', false, 'kod', 'muddat_tugagan');
  end if;

  select coalesce(full_name, '') into v_kim from profiles where id = v_uid;

  -- Kassa (to'lov) valyutasi: eng katta kredit satri (Kt kassa). Yo'q bo'lsa UZS deb olinadi.
  select upper(coalesce(a.currency, 'UZS')), l.credit, l.fc_amount
    into v_kcur, v_kcredit, v_kfc
    from entry_line l join accounts a on a.id = l.account_id
   where l.entry_id = v_id and l.credit > 0
   order by l.credit desc limit 1;
  v_kcur := coalesce(v_kcur, 'UZS');
  if v_kcur = 'CNY' then v_kcur := 'CHY'; end if;
  if v_kcur = 'UZS' then
    v_kkurs := 1;
  elsif v_kfc is not null and v_kfc > 0 and v_kcredit is not null and v_kcredit > 0 then
    v_kkurs := v_kcredit / v_kfc;                                  -- yozuvning o'z kursi
  else
    v_kkurs := _yuk_kurs_sanada(v_kcur, now()::date);
  end if;

  for ey in select yuk_id, summa_uzs, summa_fc, kurs from entry_yuk where entry_id = v_id loop
    select narx, valyuta into s from aros_yuk_snapshot where yuk_id = ey.yuk_id;
    if not found or s.narx is null then continue; end if;       -- Aros surati yo'q — yopilmaydi

    v_dcur := upper(coalesce(s.valyuta, 'UZS'));
    if v_dcur = 'CNY' then v_dcur := 'CHY'; end if;
    v_kurs := _yuk_kurs_sanada(s.valyuta, now()::date);          -- hujjat valyutasi kursi (yuk_tolangan_fc bilan bir xil)
    if v_kurs is null or v_kurs <= 0 then continue; end if;

    select coalesce((yuk_tannarx_jami(array[ey.yuk_id]) -> ey.yuk_id::text ->> 'jami_uzs')::numeric, 0) into v_tan_uzs;
    v_jami := s.narx + v_tan_uzs / v_kurs;
    v_tol := yuk_tolangan_fc(jsonb_build_array(jsonb_build_object('id', ey.yuk_id, 'valyuta', s.valyuta))) -> 0;
    v_tol_fc := coalesce((v_tol ->> 'tolangan_fc')::numeric, (v_tol ->> 'tolangan_uzs')::numeric / v_kurs, 0);
    v_qoldi := v_jami - v_tol_fc;                                 -- hujjat valyutasida, to'lovdan KEYIN
    v_pay_fc := coalesce(ey.summa_fc, ey.summa_uzs / nullif(coalesce(ey.kurs, v_kurs), 0), 0);

    if v_kcur = v_dcur or v_kkurs is null or v_kkurs <= 0 then
      -- bir xil valyuta (yoki kassa kursi noma'lum) — eski qoida: hujjat valyutasi chegarasi
      v_chegara := yaxlitlash_chegara(s.valyuta);
      if v_chegara <= 0 then continue; end if;
      v_mos := _yaxlit_mos(v_qoldi + v_pay_fc, v_pay_fc, v_chegara);
    else
      -- KASSA valyutasi bo'yicha: 650 000 so'm hujjat, 54 $ to'lov -> 53,94 $ qoldiq, 53 yoki 54 $ ✓
      v_kcheg := yaxlitlash_chegara(v_kcur);
      if v_kcheg <= 0 then continue; end if;
      v_mos := _yaxlit_mos((v_qoldi + v_pay_fc) * v_kurs / v_kkurs, ey.summa_uzs / v_kkurs, v_kcheg);
      v_chegara := v_kcheg * v_kkurs / v_kurs;                     -- yopish chegarasi hujjat valyutasida (1 $ = 12 050 so'm)
    end if;
    if not v_mos then continue; end if;                            -- to'lov qoldiqni pastga/yuqoriga yaxlitlagan bo'lishi shart

    if v_qoldi > 0.005 and v_qoldi <= v_chegara then
      insert into yuk_yopiq (yuk_id, summa_uzs, toliq, sabab, kalit, created_by_name)
      values (ey.yuk_id, round(v_qoldi * v_kurs, 2), true, 'yaxlitlash', 'yaxlit:' || v_id::text || ':' || ey.yuk_id, v_kim)
      on conflict (kalit) do nothing;
      if found then
        v_n := v_n + 1;
        select gy.guruh_id into v_grp from yuk_grafik_guruh_yuk gy where gy.yuk_id = ey.yuk_id limit 1;
        if v_grp is null then
          delete from yuk_tolov_grafik where yuk_id = ey.yuk_id and guruh_id is null;
          update yuk_deadline set deadline = null, updated_at = now() where yuk_id = ey.yuk_id;
        end if;
      end if;
    elsif v_qoldi < -0.005 and -v_qoldi <= v_chegara then
      v_ort_uzs := v_ort_uzs + round(-v_qoldi * v_kurs);
      v_izoh := v_izoh || case when v_izoh = '' then '' else ', ' end || '#' || ey.yuk_id || ' ' || round(-v_qoldi, 2)::text || ' ' || s.valyuta;
    end if;
  end loop;

  if v_ort_uzs >= 1 then
    select l.account_id into v_dt_acc from entry_line l where l.entry_id = v_id and l.debit > 0 order by l.debit desc limit 1;
    if v_dt_acc is not null then
      perform _yaxlit_yoz(v_id, v_dt_acc, 'kt', v_ort_uzs, 'yuk ortiqcha to''lov ' || v_izoh);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'yopildi', v_n, 'ortiqcha_uzs', v_ort_uzs, 'kassa_valyuta', v_kcur);
end
$fn$;
revoke all on function yuk_yaxlitlash_yop(text) from public, anon;
grant execute on function yuk_yaxlitlash_yop(text) to authenticated;
comment on function yuk_yaxlitlash_yop(text) is
  'Yuk to''lovi saqlangach fonda: qoldiq <= yaxlitlash chegarasi bo''lsa yuk_yopiq (sabab=yaxlitlash), ortiqcha to''langan qism bo''lsa avto yozuv. '
  'Kassa valyutasi hujjat valyutasidan farq qilsa chegara/floor-ceil KASSA valyutasida (54 $ -> 650 000 so''m hujjat). '
  'Egalik created_by=auth.uid() yoki admin, 30 daqiqa. ENG OXIRGI: PROVODKA_YAXLITLASH_KASSA_VALYUTA_20261120.sql';

-- ######## TEKSHIRUV ########
select 'yuk_yaxlitlash_yop (kassa valyuta)' as obyekt,
       case when pg_get_functiondef('public.yuk_yaxlitlash_yop(text)'::regprocedure) like '%kassa_valyuta%' then '✅' else '❌' end as holat;
