-- =====================================================================
--  PROVODKA_5KUNLIK_GRAFIK.sql — «5 kunlik» / «Yuklar» — TO'LOV GRAFIGI
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  #####  MAQSAD  ###########################################################
--  Bitta yukka bir nechta to'lov muddati (grafik) — Asilbek qarorlari
--  (2026-09-13), BRIEF_5KUNLIK.md. Eski `yuk_deadline` (bitta muddat)
--  ENDI faqat SURAT: `deadline` = grafikdagi eng erta sana, `izoh` = butun
--  grafik bo'yicha kelishuv matni (masalan "50% oldindan, qolgani 2 oyda").
--  Bu fayl SHU repodagi IKKI sahifa uchun umumiy SQL shartnoma:
--    * `5kunlik-dev.html` — Qarz bloki (beshkunlik_qarz_v3/_detal_v3) +
--      haqiqiy kassa qoldig'i (beshkunlik_kassa_qoldiq).
--    * `yuklar-dev.html` — grafik muharriri (yuk_grafik_*). BU FAYLGA
--      TEGILMAGAN — kontrakt (nom/argument/javob) ANIQ shu yerda yozilgan
--      imzolarga mos.
--
--  #####  FAYL TARKIBI  #####################################################
--     0-BO'LIM  — old shart tekshiruvi
--     1-BO'LIM  — yuk_tolov_grafik jadvali (+ RLS, trigger)
--     2-BO'LIM  — bir martalik ko'chirish: yuk_deadline -> yuk_tolov_grafik
--     3-BO'LIM  — _yuk_grafik_taqsim(p_yuk_ids) — ICHKI, FIFO taqsimot
--     4-BO'LIM  — _yuk_grafik_maqsad_calc(...) — ICHKI + yuk_grafik_maqsad(...)
--     5-BO'LIM  — yuk_grafik_saqla(...)
--     6-BO'LIM  — yuk_grafik_royxat(...)
--     7-BO'LIM  — beshkunlik_qarz_v3(...) / beshkunlik_qarz_detal_v3(...)
--     8-BO'LIM  — beshkunlik_kassa_qoldiq(...)
--     9-BO'LIM  — PostgREST sxema keshini yangilash
--    10-BO'LIM  — YAKUNIY TEKSHIRUV (faqat select/raise)
--
--  #####  ADDITIVE KAFOLATI  ################################################
--   * Hech narsa drop qilinmaydi. Mavjud jadval/ustun/funksiya imzosi
--     o'zgartirilmaydi (`yuk_deadline` ustiga yangi ustun QO'SHILMAYDI —
--     mavjud narx/valyuta/izoh/profil/deadline yetarli, faqat semantika
--     aniqlashtirilgan: izoh = "kelishuv matni").
--   * Idempotent: `create table if not exists`, `create or replace function`,
--     `drop policy if exists` + `create policy`, `drop trigger if exists` +
--     `create trigger`, migratsiya `not exists` bilan qo'riqlangan.
--   * Anonim `do` bloki YO'Q — har `do` bloki nomlangan teg bilan. Funksiya
--     tanasi ham nomlangan teg bilan. Izohlarda ketma-ket dollar belgi
--     YOZILMAGAN (soxta blok xavfi — CLAUDE.md).
--
--  #####  RUXSAT  ############################################################
--  O'qish (jadval RLS + royxat/qarz RPC'lar ichida): `perm_has_page('beshkunlik')
--  or perm_has_page('yuklar')` (faqat qarz_v3/_detal_v3/kassa_qoldiq —
--  `perm_has_page('beshkunlik')`, chunki ular "5 kunlik" ga xos).
--  Yozish (`yuk_grafik_saqla`): `perm_has_page('beshkunlik_edit') or
--  perm_has_page('yuklar')` — `yuk_deadline` yozish qoidasi bilan bir xil.
--  Jadvalning o'zida to'g'ridan yozish policy YO'Q — faqat RPC (SECURITY
--  DEFINER) yozadi.
--
--  #####  TALAB (0-BO'LIM tekshiradi)  #######################################
--     yuk_deadline, entry_yuk                 — PROVODKA_5KUNLIK.sql / PROVODKA_YUK_QISMAN.sql
--     yuk_tannarx_jami, yuk_bojxona_jami, yuk_tolangan_summa
--     perm_has_page(text), conv_baza_kurs(text), _beshkunlik_touch()
--
--  🔴 SQL'ni ASILBEK o'zi RUN qiladi. Agent bajarmaydi.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI                                 ##
-- #####################################################################

do $ytg_pre$
begin
  if to_regclass('public.yuk_deadline') is null then
    raise exception 'yuk_deadline jadvali yoq — avval PROVODKA_5KUNLIK.sql ni bajaring';
  end if;
  if to_regclass('public.entry_yuk') is null then
    raise exception 'entry_yuk jadvali yoq — avval PROVODKA_YUK_QISMAN.sql ni bajaring';
  end if;
  if to_regprocedure('public.yuk_tannarx_jami(integer[])') is null then
    raise exception 'yuk_tannarx_jami(integer[]) yoq — avval PROVODKA_YUK_TANNARX.sql ni bajaring';
  end if;
  if to_regprocedure('public.yuk_bojxona_jami(integer[])') is null then
    raise exception 'yuk_bojxona_jami(integer[]) yoq — avval PROVODKA_YUK_BOJXONA.sql ni bajaring';
  end if;
  if to_regprocedure('public.yuk_tolangan_summa(integer[])') is null then
    raise exception 'yuk_tolangan_summa(integer[]) yoq — avval PROVODKA_YUK_QISMAN.sql ni bajaring';
  end if;
  if to_regprocedure('public.perm_has_page(text)') is null then
    raise exception 'perm_has_page(text) yoq — avval PROVODKA_PAGES_EMPTY.sql ni bajaring';
  end if;
  if to_regprocedure('public.conv_baza_kurs(text)') is null then
    raise exception 'conv_baza_kurs(text) yoq — avval valyuta migratsiyasini bajaring';
  end if;
  if to_regprocedure('public._beshkunlik_touch()') is null then
    raise exception '_beshkunlik_touch() yoq — avval PROVODKA_5KUNLIK.sql ni bajaring';
  end if;
end
$ytg_pre$;


-- #####################################################################
-- ##  1-BO'LIM — yuk_tolov_grafik                                     ##
-- #####################################################################
-- Bitta yukka bir nechta to'lov muddati. `summa` — YUK HUJJAT VALYUTASIDA
-- (masalan yuk dollarda bo'lsa qator ham dollarda). `valyuta` — sukut UZS
-- (yagona-valyuta yuklar uchun ham to'g'ri ishlaydi).

create table if not exists yuk_tolov_grafik (
  id          bigserial   primary key,
  yuk_id      integer     not null,
  sana        date        not null,
  summa       numeric     not null check (summa > 0),
  valyuta     text        not null default 'UZS',
  izoh        text,
  updated_by  uuid,
  updated_at  timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

create index if not exists yuk_tolov_grafik_yuk_idx  on yuk_tolov_grafik(yuk_id);
create index if not exists yuk_tolov_grafik_sana_idx on yuk_tolov_grafik(sana);

comment on table yuk_tolov_grafik is
  'Aros yukiga (product-income) bir nechta to''lov muddati. summa — yuk hujjat '
  'valyutasida (yuk_deadline.valyuta bilan bir xil bo''lishi kutiladi). '
  'Yagona yozish yo''li — yuk_grafik_saqla(). yuk_deadline.deadline/izoh SURAT '
  '(eng erta sana / kelishuv matni), bu jadval haqiqiy manba.';
comment on column yuk_tolov_grafik.summa is
  'Yuk hujjat valyutasida (masalan dollarda). Sigma summa (bir yuk bo''yicha) = butun tannarx '
  '(±1 birlik) — yuk_grafik_saqla tekshiradi.';
comment on column yuk_tolov_grafik.izoh is
  'Shu MUDDAT qatoriga oid qisqa izoh (masalan "1-bo''lim"). Butun grafik bo''yicha '
  'umumiy kelishuv matni — yuk_deadline.izoh (alohida, p_kelishuv orqali yoziladi).';

alter table yuk_tolov_grafik enable row level security;
-- 🔴 Supabase yangi jadvalga authenticated'ga ALL huquqni avtomatik beradi —
--    shuning uchun authenticated'dan HAM olib tashlanadi, keyin faqat SELECT
--    qaytariladi (yozish faqat yuk_grafik_saqla RPC orqali).
revoke all on table yuk_tolov_grafik from public, anon, authenticated;
grant select on table yuk_tolov_grafik to authenticated;

drop policy if exists yuk_tolov_grafik_sel on yuk_tolov_grafik;
create policy yuk_tolov_grafik_sel on yuk_tolov_grafik
  for select to authenticated
  using (perm_has_page('beshkunlik') or perm_has_page('yuklar'));

-- 🔴 To'g'ridan insert/update/delete policy YO'Q — faqat yuk_grafik_saqla()
-- (SECURITY DEFINER) yozadi, RLS'ni funksiya egasi sifatida chetlab o'tadi.

drop trigger if exists trg_yuk_tolov_grafik_touch on yuk_tolov_grafik;
create trigger trg_yuk_tolov_grafik_touch
  before insert or update on yuk_tolov_grafik
  for each row execute function _beshkunlik_touch();


-- #####################################################################
-- ##  2-BO'LIM — bir martalik ko'chirish: yuk_deadline -> yuk_tolov_grafik ##
-- #####################################################################
-- Har `deadline is not null` yuk uchun, agar hali grafik qatori bo'lmasa,
-- BITTA qator yaratiladi: sana=deadline, valyuta=coalesce(valyuta,'UZS'),
-- summa = butun tannarx (narx + (qo'shilgan tannarx_uzs + bojxona_uzs) /
-- kurs(valyuta)). `narx` null yoki kurs topilmasa — o'tkazib yuboriladi
-- (hisobotda aytiladi, quyida raise notice). Idempotent — qayta RUN
-- qilinsa allaqachon ko'chirilgan yuk qayta ko'chirilmaydi (NOT EXISTS).

do $ytg_migrate$
declare
  v_ids       integer[];
  v_tannarx   jsonb;
  v_bojxona   jsonb;
  v_done      int := 0;
  v_skip_narx int := 0;
  v_skip_kurs int := 0;
begin
  select coalesce(array_agg(yd.yuk_id), '{}'::integer[])
    into v_ids
    from yuk_deadline yd
   where yd.deadline is not null
     and not exists (select 1 from yuk_tolov_grafik g where g.yuk_id = yd.yuk_id);

  if array_length(v_ids, 1) is null then
    raise notice 'PROVODKA_5KUNLIK_GRAFIK.sql migratsiya: kochirish uchun yuk topilmadi (hammasi grafikka ega yoki deadline yoq)';
  else
    select count(*) into v_skip_narx
      from yuk_deadline yd
     where yd.yuk_id = any(v_ids) and yd.narx is null;

    v_tannarx := coalesce(yuk_tannarx_jami(v_ids), '{}'::jsonb);
    v_bojxona := coalesce(yuk_bojxona_jami(v_ids), '{}'::jsonb);

    with kandidat as (
      select yd.yuk_id, yd.deadline, yd.narx,
             upper(coalesce(yd.valyuta, 'UZS')) as valyuta,
             case when upper(coalesce(yd.valyuta, 'UZS')) = 'UZS' then 1::numeric
                  else conv_baza_kurs(yd.valyuta) end as kurs
        from yuk_deadline yd
       where yd.yuk_id = any(v_ids)
         and yd.narx is not null
    ),
    ins as (
      insert into yuk_tolov_grafik (yuk_id, sana, summa, valyuta, izoh)
      select k.yuk_id, k.deadline,
             k.narx + (coalesce((v_tannarx -> k.yuk_id::text ->> 'jami_uzs')::numeric, 0)
                       + coalesce((v_bojxona -> k.yuk_id::text ->> 'bojxona_uzs')::numeric, 0)) / k.kurs,
             k.valyuta,
             'Ko''chirildi (bitta muddat)'
        from kandidat k
       where k.kurs is not null and k.kurs > 0
      returning 1
    )
    select count(*) into v_done from ins;

    select count(*) into v_skip_kurs
      from yuk_deadline yd
     where yd.yuk_id = any(v_ids) and yd.narx is not null
       and (case when upper(coalesce(yd.valyuta, 'UZS')) = 'UZS' then 1::numeric
                 else conv_baza_kurs(yd.valyuta) end) is null;

    raise notice 'PROVODKA_5KUNLIK_GRAFIK.sql migratsiya: % kochirildi, % narx yoq (otkazib yuborildi), % kurs topilmadi (otkazib yuborildi)',
      v_done, v_skip_narx, v_skip_kurs;
  end if;
end
$ytg_migrate$;


-- #####################################################################
-- ##  3-BO'LIM — _yuk_grafik_taqsim(p_yuk_ids) — ICHKI, FIFO taqsimot ##
-- #####################################################################
-- Har grafik qatori uchun: yuk to'lovlari (entry_yuk, posted+ochirilmagan,
-- entry_date bo'yicha) ENG ESKI MUDDATDAN boshlab (FIFO) taqsimlanadi.
-- Kumulyativ oraliqlar kesishmasi (window funksiyalar) — sikl yo'q.
-- `kech` — shu qatorga taqsimlangan to'lovlardan birortasi muddatdan
-- KEYIN qilingan bo'lsa true. `tolov_sanalari` — shu qatorga taqsimlangan
-- to'lovlarning (distinct) entry_date'lari.

create or replace function _yuk_grafik_taqsim(p_yuk_ids integer[])
returns table (
  id             bigint,
  yuk_id         integer,
  sana           date,
  summa          numeric,
  valyuta        text,
  izoh           text,
  summa_uzs      numeric,
  tolangan_uzs   numeric,
  qoldiq_uzs     numeric,
  kech           boolean,
  tolov_sanalari date[]
)
language sql
stable
security definer
set search_path = public
as $yg_taqsim$
  with g as (
    select t.id, t.yuk_id, t.sana, t.summa, t.valyuta, t.izoh,
           round(t.summa * case when upper(coalesce(t.valyuta, 'UZS')) = 'UZS' then 1::numeric
                                 else coalesce(conv_baza_kurs(t.valyuta), 0::numeric) end) as summa_uzs
      from yuk_tolov_grafik t
     where p_yuk_ids is null or t.yuk_id = any(p_yuk_ids)
  ),
  gc as (
    select g.*,
           sum(g.summa_uzs) over (partition by g.yuk_id order by g.sana, g.id) as cum_to,
           sum(g.summa_uzs) over (partition by g.yuk_id order by g.sana, g.id) - g.summa_uzs as cum_from
      from g
  ),
  p as (
    select ey.entry_id, ey.yuk_id, e.entry_date, ey.summa_uzs
      from entry_yuk ey
      join entry e on e.id = ey.entry_id
     where e.status = 'posted' and e.is_deleted = false
       and (p_yuk_ids is null or ey.yuk_id = any(p_yuk_ids))
  ),
  pc as (
    select p.*,
           sum(p.summa_uzs) over (partition by p.yuk_id order by p.entry_date, p.entry_id) as cum_to,
           sum(p.summa_uzs) over (partition by p.yuk_id order by p.entry_date, p.entry_id) - p.summa_uzs as cum_from
      from p
  ),
  ov as (
    select gc.id as grafik_id, pc.entry_date as entry_date,
           greatest(0, least(gc.cum_to, pc.cum_to) - greatest(gc.cum_from, pc.cum_from)) as ov
      from gc
      join pc on pc.yuk_id = gc.yuk_id
     where least(gc.cum_to, pc.cum_to) > greatest(gc.cum_from, pc.cum_from)
  )
  select gc.id, gc.yuk_id, gc.sana, gc.summa, gc.valyuta, gc.izoh, gc.summa_uzs,
         coalesce(sum(ov.ov), 0)                                        as tolangan_uzs,
         gc.summa_uzs - coalesce(sum(ov.ov), 0)                         as qoldiq_uzs,
         coalesce(bool_or(ov.entry_date > gc.sana), false)              as kech,
         coalesce(array_agg(distinct ov.entry_date order by ov.entry_date)
                    filter (where ov.entry_date is not null), '{}'::date[]) as tolov_sanalari
    from gc
    left join ov on ov.grafik_id = gc.id
   group by gc.id, gc.yuk_id, gc.sana, gc.summa, gc.valyuta, gc.izoh, gc.summa_uzs
   order by gc.yuk_id, gc.sana, gc.id;
$yg_taqsim$;

revoke all on function _yuk_grafik_taqsim(integer[]) from public, anon, authenticated;

comment on function _yuk_grafik_taqsim(integer[]) is
  'ICHKI: har yuk_tolov_grafik qatori uchun FIFO taqsimlangan tolov (kumulyativ '
  'oraliqlar kesishmasi, sikl yoq). p_yuk_ids null -> hammasi. Grafikdan ortiq '
  'tolov hech qaysi qatorga tushmaydi (cum_to grafik jami bilan chegaralangan).';


-- #####################################################################
-- ##  4-BO'LIM — yuk_grafik_maqsad — "butun tannarx" (C formulasi)    ##
-- #####################################################################
-- Butun tannarx (hujjat valyutasida) = hujjat narxi + (qo'shilgan
-- tannarx_uzs + bojxona_uzs) / kurs(valyuta). UZS bo'lsa kurs 1.

create or replace function _yuk_grafik_maqsad_calc(p_yuk_id integer, p_narx numeric, p_valyuta text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $yg_maqsad_calc$
declare
  v_valyuta text := upper(coalesce(p_valyuta, 'UZS'));
  v_kurs    numeric;
  v_tannarx numeric := 0;
  v_bojxona numeric := 0;
begin
  if v_valyuta = 'UZS' then
    v_kurs := 1;
  else
    v_kurs := conv_baza_kurs(v_valyuta);
  end if;
  if v_kurs is null or v_kurs <= 0 then
    return jsonb_build_object('ok', false, 'kod', 'kurs_yoq', 'valyuta', v_valyuta);
  end if;

  select coalesce((yuk_tannarx_jami(array[p_yuk_id]) -> p_yuk_id::text ->> 'jami_uzs')::numeric, 0)
    into v_tannarx;
  select coalesce((yuk_bojxona_jami(array[p_yuk_id]) -> p_yuk_id::text ->> 'bojxona_uzs')::numeric, 0)
    into v_bojxona;

  return jsonb_build_object(
    'ok', true,
    'maqsad', coalesce(p_narx, 0) + (v_tannarx + v_bojxona) / v_kurs,
    'valyuta', v_valyuta,
    'narx', p_narx,
    'tannarx_uzs', v_tannarx,
    'bojxona_uzs', v_bojxona,
    'kurs', v_kurs);
end
$yg_maqsad_calc$;

revoke all on function _yuk_grafik_maqsad_calc(integer, numeric, text) from public, anon, authenticated;

comment on function _yuk_grafik_maqsad_calc(integer, numeric, text) is
  'ICHKI: "butun tannarx" hisob-kitobi (Asilbek qarori C). Ruxsat tekshirmaydi — '
  'chaqiruvchi (yuk_grafik_maqsad / yuk_grafik_saqla) o''zi tekshiradi.';


create or replace function yuk_grafik_maqsad(p_yuk_id integer, p_narx numeric, p_valyuta text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $yg_maqsad$
declare
  v_calc jsonb;
begin
  if not coalesce(perm_has_page('beshkunlik') or perm_has_page('yuklar'), false) then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  if p_yuk_id is null then
    return jsonb_build_object('ok', false, 'kod', 'yuk_id');
  end if;

  v_calc := _yuk_grafik_maqsad_calc(p_yuk_id, p_narx, p_valyuta);
  return coalesce(v_calc, jsonb_build_object('ok', false, 'kod', 'kurs_yoq'));
end
$yg_maqsad$;

revoke all on function yuk_grafik_maqsad(integer, numeric, text) from public, anon;
grant execute on function yuk_grafik_maqsad(integer, numeric, text) to authenticated;

comment on function yuk_grafik_maqsad(integer, numeric, text) is
  '"Butun tannarx" (maqsad summasi) — {ok, maqsad, valyuta, narx, tannarx_uzs, '
  'bojxona_uzs, kurs} yoki {ok:false, kod}. Yuk hujjat valyutasida (p_valyuta). '
  'Ruxsat: perm_has_page(''beshkunlik'') or perm_has_page(''yuklar'').';


-- #####################################################################
-- ##  5-BO'LIM — yuk_grafik_saqla — grafikni TO'LIQ almashtiradi      ##
-- #####################################################################
-- p_rows = [{sana, summa, izoh}]. Bo'sh massiv -> grafik o'chiriladi.
-- Aks holda |Σ summa - maqsad| <= 1 talab qilinadi, aks holda hech narsa
-- yozilmaydi. Muvaffaqiyatda yuk_deadline ham upsert (deadline = eng erta
-- sana, narx/valyuta surat). p_kelishuv (ixtiyoriy) berilsa yuk_deadline.izoh
-- ga yoziladi (butun grafik bo'yicha kelishuv matni) — null bo'lsa izoh
-- o'zgarmaydi.

create or replace function yuk_grafik_saqla(
  p_yuk_id    integer,
  p_narx      numeric,
  p_valyuta   text,
  p_rows      jsonb,
  p_kelishuv  text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $yg_saqla$
declare
  v_calc     jsonb;
  v_maqsad   numeric;
  v_rows     jsonb;
  v_row      jsonb;
  v_sana     date;
  v_summa    numeric;
  v_izoh     text;
  v_jami     numeric := 0;
  v_n        int := 0;
  v_farq     numeric;
  v_min_sana date;
  v_valyuta  text := upper(coalesce(p_valyuta, 'UZS'));
begin
  if not coalesce(perm_has_page('beshkunlik_edit') or perm_has_page('yuklar'), false) then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  if p_yuk_id is null then
    return jsonb_build_object('ok', false, 'kod', 'yuk_id');
  end if;

  perform pg_advisory_xact_lock(hashtext('yuk_grafik:' || p_yuk_id::text));

  v_rows := coalesce(p_rows, '[]'::jsonb);
  if jsonb_typeof(v_rows) <> 'array' then
    return jsonb_build_object('ok', false, 'kod', 'rows_shakli');
  end if;

  if jsonb_array_length(v_rows) = 0 then
    delete from yuk_tolov_grafik where yuk_id = p_yuk_id;
    update yuk_deadline set deadline = null,
                             izoh = case when p_kelishuv is not null then p_kelishuv else izoh end
     where yuk_id = p_yuk_id;
    return jsonb_build_object('ok', true, 'jami', 0);
  end if;

  for v_row in select * from jsonb_array_elements(v_rows) loop
    v_sana := null; v_summa := null;
    begin v_sana := (v_row ->> 'sana')::date; exception when others then v_sana := null; end;
    begin v_summa := (v_row ->> 'summa')::numeric; exception when others then v_summa := null; end;
    if v_sana is null or v_summa is null or v_summa <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'qator_notogri');
    end if;
    v_jami := v_jami + v_summa;
    v_n := v_n + 1;
  end loop;

  v_calc := _yuk_grafik_maqsad_calc(p_yuk_id, p_narx, p_valyuta);
  if not coalesce((v_calc ->> 'ok')::boolean, false) then
    return coalesce(v_calc, jsonb_build_object('ok', false, 'kod', 'kurs_yoq'));
  end if;
  v_maqsad := (v_calc ->> 'maqsad')::numeric;
  v_farq := v_jami - v_maqsad;
  if abs(v_farq) > 1 then
    return jsonb_build_object('ok', false, 'kod', 'summa_mos_emas', 'jami', v_jami, 'maqsad', v_maqsad, 'farq', v_farq);
  end if;

  delete from yuk_tolov_grafik where yuk_id = p_yuk_id;
  v_min_sana := null;
  for v_row in select * from jsonb_array_elements(v_rows) loop
    v_sana  := (v_row ->> 'sana')::date;
    v_summa := (v_row ->> 'summa')::numeric;
    v_izoh  := v_row ->> 'izoh';
    insert into yuk_tolov_grafik (yuk_id, sana, summa, valyuta, izoh)
      values (p_yuk_id, v_sana, v_summa, v_valyuta, v_izoh);
    if v_min_sana is null or v_sana < v_min_sana then
      v_min_sana := v_sana;
    end if;
  end loop;

  insert into yuk_deadline (yuk_id, deadline, narx, valyuta, izoh)
    values (p_yuk_id, v_min_sana, p_narx, v_valyuta, p_kelishuv)
  on conflict (yuk_id) do update
    set deadline = excluded.deadline,
        narx     = excluded.narx,
        valyuta  = excluded.valyuta,
        izoh     = case when p_kelishuv is not null then excluded.izoh else yuk_deadline.izoh end;

  return jsonb_build_object('ok', true, 'jami', v_jami, 'maqsad', v_maqsad, 'n', v_n);
end
$yg_saqla$;

revoke all on function yuk_grafik_saqla(integer, numeric, text, jsonb, text) from public, anon;
grant execute on function yuk_grafik_saqla(integer, numeric, text, jsonb, text) to authenticated;

comment on function yuk_grafik_saqla(integer, numeric, text, jsonb, text) is
  'Yukning to''lov grafigini TO''LIQ almashtiradi. p_rows=[{sana,summa,izoh}]. '
  'Bo''sh massiv -> grafik o''chiriladi (deadline null). Aks holda |jami-maqsad|<=1 '
  'talab qilinadi (yuk_grafik_maqsad formulasi), aks holda {ok:false,kod:''summa_mos_emas''} '
  'va hech narsa yozilmaydi. p_kelishuv (ixtiyoriy) berilsa yuk_deadline.izoh ga yoziladi. '
  'Ruxsat: perm_has_page(''beshkunlik_edit'') or perm_has_page(''yuklar'').';


-- #####################################################################
-- ##  6-BO'LIM — yuk_grafik_royxat — barcha (yoki tanlangan) yuklar   ##
-- #####################################################################

create or replace function yuk_grafik_royxat(p_yuk_ids integer[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $yg_royxat$
begin
  if not coalesce(perm_has_page('beshkunlik') or perm_has_page('yuklar'), false) then
    return jsonb_build_object('ok', false, 'rows', '[]'::jsonb);
  end if;

  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id, 'yuk_id', t.yuk_id, 'sana', t.sana, 'summa', t.summa, 'valyuta', t.valyuta,
             'izoh', t.izoh, 'summa_uzs', t.summa_uzs, 'tolangan_uzs', t.tolangan_uzs,
             'qoldiq_uzs', t.qoldiq_uzs, 'kech', t.kech, 'tolov_sanalari', t.tolov_sanalari,
             'holat', case when t.qoldiq_uzs <= 0.5 then 'tolangan'
                           when t.tolangan_uzs > 0.5 then 'qisman'
                           else 'tolanmagan' end)
           order by t.yuk_id, t.sana, t.id)
      from _yuk_grafik_taqsim(p_yuk_ids) t
  ), '[]'::jsonb));
end
$yg_royxat$;

revoke all on function yuk_grafik_royxat(integer[]) from public, anon;
grant execute on function yuk_grafik_royxat(integer[]) to authenticated;

comment on function yuk_grafik_royxat(integer[]) is
  'Grafik qatorlari (p_yuk_ids null -> hammasi) — {ok, rows:[{id,yuk_id,sana,summa,'
  'valyuta,izoh,summa_uzs,tolangan_uzs,qoldiq_uzs,kech,tolov_sanalari,holat}]}. '
  'Ruxsat: perm_has_page(''beshkunlik'') or perm_has_page(''yuklar'').';


-- #####################################################################
-- ##  7-BO'LIM — beshkunlik_qarz_v3 / beshkunlik_qarz_detal_v3        ##
-- #####################################################################
-- Asilbek qarori D (2026-09-13): Qarzmiz(D) = D kuniga tushgan grafik
-- qatorlari summasi (to'langan-to'lanmaganidan qat'i nazar), Berdik(D) =
-- shu qatorlarga FIFO taqsimlangan to'lov, Raznitsa = Qarzmiz-Berdik
-- (to'lanmagan qoldiq). qarzmiz_uzs/berdik_uzs/raznitsa_uzs MUSBAT son
-- (ishorani klient qo'yadi — v2 naqshi).

create or replace function beshkunlik_qarz_v3(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bk_qarz_v3$
declare
  v_ids integer[];
begin
  if not coalesce(perm_has_page('beshkunlik'), false) then
    return '[]'::jsonb;
  end if;
  if p_from is null or p_to is null then
    return '[]'::jsonb;
  end if;

  select coalesce(array_agg(distinct yuk_id), '{}'::integer[])
    into v_ids
    from yuk_tolov_grafik
   where sana between p_from and p_to;

  if array_length(v_ids, 1) is null then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'sana', x.sana, 'qarzmiz_uzs', x.qarzmiz_uzs, 'berdik_uzs', x.berdik_uzs,
             'raznitsa_uzs', x.raznitsa_uzs, 'kech_bor', x.kech_bor, 'n_tolov', x.n_tolov)
           order by x.sana)
      from (
        select t.sana,
               sum(t.summa_uzs)   as qarzmiz_uzs,
               sum(t.tolangan_uzs) as berdik_uzs,
               sum(t.qoldiq_uzs)  as raznitsa_uzs,
               bool_or(t.kech)    as kech_bor,
               count(*)           as n_tolov
          from _yuk_grafik_taqsim(v_ids) t
         where t.sana between p_from and p_to
         group by t.sana
      ) x
  ), '[]'::jsonb);
end
$bk_qarz_v3$;

revoke all on function beshkunlik_qarz_v3(date, date) from public, anon;
grant execute on function beshkunlik_qarz_v3(date, date) to authenticated;

comment on function beshkunlik_qarz_v3(date, date) is
  '5 kunlik Qarz bloki (Asilbek qarori D, 2026-09-13), SO''MDA: [{sana, qarzmiz_uzs, '
  'berdik_uzs, raznitsa_uzs, kech_bor, n_tolov}]. qarzmiz_uzs — D kuniga tushgan grafik '
  'qatorlari summasi (musbat, to''langan-to''lanmaganidan qat''i nazar). berdik_uzs — shu '
  'qatorlarga FIFO taqsimlangan to''lov. raznitsa_uzs = qarzmiz_uzs-berdik_uzs (tolanmagan '
  'qoldiq). kech_bor — shu kunga tushgan qatorlardan birortasi kech to''langan bo''lsa true. '
  'n_tolov — shu kunga tushgan grafik qatorlari soni. Ruxsat: perm_has_page(''beshkunlik'').';


create or replace function beshkunlik_qarz_detal_v3(p_sana date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bk_qarz_detal_v3$
declare
  v_ids integer[];
begin
  if not coalesce(perm_has_page('beshkunlik'), false) then
    return '[]'::jsonb;
  end if;
  if p_sana is null then
    return '[]'::jsonb;
  end if;

  select coalesce(array_agg(distinct yuk_id), '{}'::integer[])
    into v_ids
    from yuk_tolov_grafik
   where sana = p_sana;

  if array_length(v_ids, 1) is null then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'grafik_id', t.id, 'yuk_id', t.yuk_id, 'izoh', t.izoh, 'summa', t.summa,
             'valyuta', t.valyuta, 'summa_uzs', t.summa_uzs, 'tolangan_uzs', t.tolangan_uzs,
             'qoldiq_uzs', t.qoldiq_uzs,
             'holat', case when t.qoldiq_uzs <= 0.5 then 'tolangan'
                           when t.tolangan_uzs > 0.5 then 'qisman'
                           else 'tolanmagan' end,
             'kech', t.kech, 'tolov_sanalari', t.tolov_sanalari,
             'kelishuv', yd.izoh)
           order by t.yuk_id)
      from _yuk_grafik_taqsim(v_ids) t
      left join yuk_deadline yd on yd.yuk_id = t.yuk_id
     where t.sana = p_sana
  ), '[]'::jsonb);
end
$bk_qarz_detal_v3$;

revoke all on function beshkunlik_qarz_detal_v3(date) from public, anon;
grant execute on function beshkunlik_qarz_detal_v3(date) to authenticated;

comment on function beshkunlik_qarz_detal_v3(date) is
  '5 kunlik Qarzmiz katagi hover (bitta kun, profilsiz): [{grafik_id, yuk_id, izoh, summa, '
  'valyuta, summa_uzs, tolangan_uzs, qoldiq_uzs, holat, kech, tolov_sanalari, kelishuv}]. '
  'kelishuv — yuk_deadline.izoh (butun grafik bo''yicha umumiy matn). '
  'Ruxsat: perm_has_page(''beshkunlik'').';


-- #####################################################################
-- ##  8-BO'LIM — beshkunlik_kassa_qoldiq — haqiqiy kassa puli         ##
-- #####################################################################
-- Asilbek qarori A (2026-09-13): «Haqiqiy» = kassalardagi haqiqiy pul —
-- section='pul', hodim xarajat kassalari (kassa_turi in ('xarajat',
-- 'xarajat_guruh')) DAN TASHQARI hammasi (filial/markaziy + ularning pul
-- turi va valyuta bolalari — create_pul_turi_child/create_valyuta_child
-- kassa_turi'ni parentdan NUSXALAYDI, shuning uchun bitta filtr yetarli —
-- parent_id bo'yicha rekursiya SHART EMAS). `uzs` = UZS hisoblar + USD'dan
-- boshqa xorijiy valyuta hisoblarining so'm ekvivalenti; `usd` = USD
-- hisoblarning fc_amount qoldig'i (dollarning o'zi, so'mga o'girilmagan).
-- Har kun uchun kun OXIRIDAGI qoldiq: p_from'dan oldingi boshlang'ich
-- (bitta yig'indi so'rovi) + kunlik deltalar (bitta guruhlash) kumulyativ
-- (generate_series bilan harakatsiz kun ham qator beradi).

create or replace function beshkunlik_kassa_qoldiq(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bk_kassa$
declare
  v_before_uzs numeric := 0;
  v_before_usd numeric := 0;
begin
  if not coalesce(perm_has_page('beshkunlik'), false) then
    return '[]'::jsonb;
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    return '[]'::jsonb;
  end if;

  select coalesce(sum(case when a.currency is distinct from 'USD' then (l.debit - l.credit) else 0 end), 0),
         coalesce(sum(case when a.currency = 'USD'
                            then (case when l.debit > 0::numeric then coalesce(l.fc_amount, 0)
                                       else -coalesce(l.fc_amount, 0) end)
                            else 0 end), 0)
    into v_before_uzs, v_before_usd
    from entry_line l
    join entry e on e.id = l.entry_id
    join accounts a on a.id = l.account_id
   where e.status = 'posted' and e.is_deleted = false
     and e.entry_date < p_from
     and a.section = 'pul'
     and coalesce(a.kassa_turi, '') not in ('xarajat', 'xarajat_guruh');

  return coalesce((
    select jsonb_agg(jsonb_build_object('sana', x.sana, 'uzs', x.uzs, 'usd', x.usd) order by x.sana)
      from (
        select d.sana,
               v_before_uzs + coalesce(sum(dl.d_uzs) over (order by d.sana), 0) as uzs,
               v_before_usd + coalesce(sum(dl.d_usd) over (order by d.sana), 0) as usd
          from (select gs::date as sana
                  from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') gs) d
          left join (
            select e.entry_date as sana,
                   sum(case when a.currency is distinct from 'USD' then (l.debit - l.credit) else 0 end) as d_uzs,
                   sum(case when a.currency = 'USD'
                            then (case when l.debit > 0::numeric then coalesce(l.fc_amount, 0)
                                       else -coalesce(l.fc_amount, 0) end)
                            else 0 end) as d_usd
              from entry_line l
              join entry e on e.id = l.entry_id
              join accounts a on a.id = l.account_id
             where e.status = 'posted' and e.is_deleted = false
               and e.entry_date between p_from and p_to
               and a.section = 'pul'
               and coalesce(a.kassa_turi, '') not in ('xarajat', 'xarajat_guruh')
             group by e.entry_date
          ) dl on dl.sana = d.sana
      ) x
  ), '[]'::jsonb);
end
$bk_kassa$;

revoke all on function beshkunlik_kassa_qoldiq(date, date) from public, anon;
grant execute on function beshkunlik_kassa_qoldiq(date, date) to authenticated;

comment on function beshkunlik_kassa_qoldiq(date, date) is
  '5 kunlik "Haqiqiy" ustuni — kun OXIRIDAGI haqiqiy kassa puli: [{sana, uzs, usd}]. '
  'section=''pul'' va kassa_turi hodim xarajat kassalari (xarajat/xarajat_guruh) DAN '
  'TASHQARI (filial/markaziy + ularning pul turi/valyuta bolalari — kassa_turi parentdan '
  'nusxalangan). uzs — UZS + boshqa xorijiy valyuta hisoblarining so''m ekvivalenti; '
  'usd — USD hisoblarning fc_amount qoldig''i (dollarning o''zi). Faqat posted, '
  'ochirilmagan, entry_date<=sana. Ruxsat: perm_has_page(''beshkunlik'').';


-- #####################################################################
-- ##  9-BO'LIM — PostgREST sxema keshini yangilash                    ##
-- #####################################################################

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  10-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/raise)               ##
-- #####################################################################

do $ytg_final$
declare
  v_ok boolean;
begin
  if to_regclass('public.yuk_tolov_grafik') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_tolov_grafik jadvali yaralmadi';
  end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and tablename='yuk_tolov_grafik' and indexname='yuk_tolov_grafik_yuk_idx') then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_tolov_grafik_yuk_idx yaralmadi';
  end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and tablename='yuk_tolov_grafik' and indexname='yuk_tolov_grafik_sana_idx') then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_tolov_grafik_sana_idx yaralmadi';
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='yuk_tolov_grafik' and policyname='yuk_tolov_grafik_sel') then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_tolov_grafik_sel policy yoq';
  end if;

  select has_table_privilege('authenticated', 'public.yuk_tolov_grafik', 'select') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun yuk_tolov_grafik SELECT yoq';
  end if;
  select has_table_privilege('authenticated', 'public.yuk_tolov_grafik', 'insert') into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated yuk_tolov_grafikka togridan yoza olmasligi kerak edi';
  end if;
  select has_table_privilege('anon', 'public.yuk_tolov_grafik', 'select') into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: anon yuk_tolov_grafikni oqiy olmasligi kerak edi';
  end if;

  if to_regprocedure('public._yuk_grafik_taqsim(integer[])') is null then
    raise exception 'YAKUNIY TEKSHIRUV: _yuk_grafik_taqsim(integer[]) yaralmadi';
  end if;
  if to_regprocedure('public.yuk_grafik_maqsad(integer,numeric,text)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_grafik_maqsad(integer,numeric,text) yaralmadi';
  end if;
  if to_regprocedure('public.yuk_grafik_saqla(integer,numeric,text,jsonb,text)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_grafik_saqla(integer,numeric,text,jsonb,text) yaralmadi';
  end if;
  if to_regprocedure('public.yuk_grafik_royxat(integer[])') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_grafik_royxat(integer[]) yaralmadi';
  end if;
  if to_regprocedure('public.beshkunlik_qarz_v3(date,date)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_qarz_v3(date,date) yaralmadi';
  end if;
  if to_regprocedure('public.beshkunlik_qarz_detal_v3(date)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_qarz_detal_v3(date) yaralmadi';
  end if;
  if to_regprocedure('public.beshkunlik_kassa_qoldiq(date,date)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_kassa_qoldiq(date,date) yaralmadi';
  end if;

  raise notice 'PROVODKA_5KUNLIK_GRAFIK.sql: hammasi joyida (yuk_tolov_grafik + grafik RPC + qarz_v3 + kassa_qoldiq)';
end
$ytg_final$;
