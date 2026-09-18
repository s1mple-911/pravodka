-- ============================================================================
--  PROVODKA_YUK_YOPISH.sql — 2026-09-19 (Asilbek)
--
--  «Yetkazib beruvchi bo'yicha qoldiqni to'g'rilash»: Asilbek «Zahra $10 000» desa —
--  eng YANGI yuk hujjatlaridan shu summaga yetguncha OCHIQ qoladi, qolgan eski
--  hujjatlar «qayta hisob bilan yopildi» deb belgilanadi (chegaradagi hujjat QISMAN).
--  Pul harakati YO'Q: yopiq summa `yuk_yopiq` jadvalida, to'lov (entry_yuk) EMAS —
--  5 kunlik «Berdik» shishmaydi. Qarz hisobida esa to'langan kabi kamayadi.
--
--  Additive: yangi jadval + 3 yangi RPC; `yuk_tolangan_summa` va
--  `_yuk_grafik_maqsad_calc` IMZOSI SAQLANIB tanasi qayta e'lon qilinadi
--  (tolangan_uzs ichiga yopiq qo'shiladi; grafik maqsadi yopiq qadar kamayadi).
--  Ruxsat: admin YOKI `perm_has_page('yuklar')` (tannarx amallari bilan bir xil).
--
--  Frontend: yuklar-dev.html «Qoldiqni to'g'rilash» modali + «Yopilgan» chipi.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) Jadval
-- ---------------------------------------------------------------------------
create table if not exists yuk_yopiq (
  id              bigserial primary key,
  yuk_id          integer      not null,
  summa_uzs       numeric      not null check (summa_uzs > 0),
  toliq           boolean      not null default false,   -- hujjat butunlay yopildimi
  sabab           text,
  kalit           text         unique,                    -- idempotentlik (qayta bosishda takror yozilmasin)
  created_by      uuid         default auth.uid(),
  created_by_name text,
  created_at      timestamptz  not null default now(),
  is_deleted      boolean      not null default false,
  deleted_at      timestamptz,
  deleted_by      uuid
);
create index if not exists yuk_yopiq_yuk_idx on yuk_yopiq (yuk_id) where not is_deleted;

comment on table yuk_yopiq is
  'Yuk qarzining PULSIZ yopilgan qismi (qayta hisob). yuk_tolangan_summa ichida to''langan kabi '
  'sanaladi (yopiq=true belgisi bilan), entry_yuk EMAS — 5 kunlik Berdik ga kirmaydi.';

alter table yuk_yopiq enable row level security;
drop policy if exists yuk_yopiq_sel on yuk_yopiq;
create policy yuk_yopiq_sel on yuk_yopiq for select to authenticated using (true);
-- yozish faqat RPC (security definer)
revoke all on yuk_yopiq from public, anon;
grant select on yuk_yopiq to authenticated;

-- ---------------------------------------------------------------------------
-- 2) Ruxsat yordamchisi
-- ---------------------------------------------------------------------------
create or replace function _yuk_yopiq_ok()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    return false;
  end if;
  if is_admin() then
    return true;
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'perm_has_page') then
    return perm_has_page('yuklar');
  end if;
  return false;
end
$fn$;
revoke all on function _yuk_yopiq_ok() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3) yuk_yopiq_jami(p_ids) → {"<yuk_id>": {yopiq_uzs, toliq, sabab, sana, kim}}
-- ---------------------------------------------------------------------------
create or replace function yuk_yopiq_jami(p_ids integer[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(jsonb_object_agg(y.yuk_id::text, jsonb_build_object(
           'yopiq_uzs', y.tot,
           'toliq',     y.toliq,
           'sabab',     y.sabab,
           'sana',      y.sana,
           'kim',       y.kim)), '{}'::jsonb)
    from (
      select yuk_id,
             sum(summa_uzs)::numeric                 as tot,
             bool_or(toliq)                          as toliq,
             max(sabab)                              as sabab,
             max(created_at)::date                   as sana,
             max(created_by_name)                    as kim
        from yuk_yopiq
       where not is_deleted and yuk_id = any(coalesce(p_ids, '{}'))
       group by yuk_id
    ) y;
$fn$;
revoke all on function yuk_yopiq_jami(integer[]) from public, anon;
grant execute on function yuk_yopiq_jami(integer[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 4) yuk_yopish_toplam(p_rows, p_sabab, p_kalit) — bir yetkazuvchi uchun bir zarbda
--    p_rows = [{yuk_id, summa_uzs, toliq}]  (summa_uzs = YOPILADIGAN qism, so'mda)
--    To'liq yopilgan hujjatning grafigi/muddati olib tashlanadi (guruhda bo'lsa — tegilmaydi,
--    ogohlantirish qaytadi). Idempotent: p_kalit takror bo'lsa {ok:true, takror:true}.
-- ---------------------------------------------------------------------------
create or replace function yuk_yopish_toplam(p_rows jsonb, p_sabab text default null, p_kalit text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r        jsonb;
  v_id     integer;
  v_sum    numeric;
  v_toliq  boolean;
  v_kalit  text;
  v_n      int := 0;
  v_ogoh   text[] := '{}';
  v_nom    text;
  v_grp    uuid;
begin
  if not _yuk_yopiq_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Yuklar sahifasiga ruxsat yoq');
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('ok', false, 'kod', 'bosh', 'error', 'Qatorlar yoq');
  end if;
  if p_kalit is not null and exists (select 1 from yuk_yopiq where kalit like p_kalit || ':%') then
    return jsonb_build_object('ok', true, 'takror', true, 'yozildi', 0);
  end if;
  select coalesce(full_name, '') into v_nom from profiles where id = auth.uid();

  for r in select * from jsonb_array_elements(p_rows) loop
    v_id    := (r ->> 'yuk_id')::integer;
    v_sum   := round((r ->> 'summa_uzs')::numeric, 2);
    v_toliq := coalesce((r ->> 'toliq')::boolean, false);
    if v_id is null or v_sum is null or v_sum <= 0 then
      continue;
    end if;
    v_kalit := case when p_kalit is null then null else p_kalit || ':' || v_id end;
    insert into yuk_yopiq (yuk_id, summa_uzs, toliq, sabab, kalit, created_by_name)
    values (v_id, v_sum, v_toliq, p_sabab, v_kalit, v_nom);
    v_n := v_n + 1;

    if v_toliq then
      -- grafik: guruhda bo'lsa tegmaymiz (guruh grafigi butun a'zolar bo'yicha), ogohlantiramiz
      select gy.guruh_id into v_grp from yuk_grafik_guruh_yuk gy where gy.yuk_id = v_id limit 1;
      if v_grp is not null then
        v_ogoh := v_ogoh || ('#' || v_id || ' guruh grafigida — grafikni qolda tuzating');
      else
        delete from yuk_tolov_grafik where yuk_id = v_id and guruh_id is null;
        update yuk_deadline set deadline = null, updated_at = now() where yuk_id = v_id;
      end if;
    else
      -- qisman: mavjud grafik jami endi maqsaddan katta — qayta saqlash kerak
      if exists (select 1 from yuk_tolov_grafik where yuk_id = v_id) then
        v_ogoh := v_ogoh || ('#' || v_id || ' qisman yopildi — to''lov grafigini yangi qoldiqqa qayta saqlang');
      end if;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'yozildi', v_n, 'ogoh', to_jsonb(v_ogoh));
end
$fn$;
revoke all on function yuk_yopish_toplam(jsonb, text, text) from public, anon;
grant execute on function yuk_yopish_toplam(jsonb, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) yuk_yopiq_bekor(p_yuk_id) — hujjatning yopiq yozuvlarini bekor qilish (soft)
-- ---------------------------------------------------------------------------
create or replace function yuk_yopiq_bekor(p_yuk_id integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_n int;
begin
  if not _yuk_yopiq_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Yuklar sahifasiga ruxsat yoq');
  end if;
  update yuk_yopiq
     set is_deleted = true, deleted_at = now(), deleted_by = auth.uid()
   where yuk_id = p_yuk_id and not is_deleted;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'bekor', v_n);
end
$fn$;
revoke all on function yuk_yopiq_bekor(integer) from public, anon;
grant execute on function yuk_yopiq_bekor(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 6) yuk_tolangan_summa — QAYTA E'LON (imzo bir xil): yopiq summa to'langan kabi qo'shiladi.
--    entrylar ichida yopiq qatorlar `yopiq:true` (entry_id null) bilan ajralib turadi.
--    Iste'molchilar (qarzdor-dev, yuklar-dev, 5kunlik muddatsiz) o'zgarishsiz to'g'ri qoldiq oladi.
--    🔴 _yuk_grafik_taqsim BU FUNKSIYANI ISHLATMAYDI (entry_yuk ni to'g'ridan o'qiydi) — grafik
--    yo'lida yopiq MAQSAD orqali hisobga olinadi (7-bo'lim), ikki marta sanalmaydi.
-- ---------------------------------------------------------------------------
create or replace function yuk_tolangan_summa(p_ids integer[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'yuk_id',       y.yuk_id,
           'tolangan_uzs', y.tot,
           'entrylar',     y.entrylar) order by y.yuk_id), '[]'::jsonb)
    from (
      select u.yuk_id,
             sum(u.summa_uzs)::numeric as tot,
             jsonb_agg(jsonb_build_object(
               'entry_id',   u.entry_id,
               'entry_date', u.entry_date,
               'summa_uzs',  u.summa_uzs,
               'yopiq',      u.yopiq,
               'sabab',      u.sabab) order by u.entry_date) as entrylar
        from (
          select ey.yuk_id, e.id as entry_id, e.entry_date, ey.summa_uzs, false as yopiq, null::text as sabab
            from entry_yuk ey
            join entry e on e.id = ey.entry_id
           where e.status = 'posted' and e.is_deleted = false
             and ey.yuk_id = any(coalesce(p_ids, '{}'))
          union all
          select yq.yuk_id, null::uuid, yq.created_at::date, yq.summa_uzs, true, yq.sabab
            from yuk_yopiq yq
           where not yq.is_deleted and yq.yuk_id = any(coalesce(p_ids, '{}'))
        ) u
       group by u.yuk_id
    ) y;
$fn$;
revoke all on function yuk_tolangan_summa(integer[]) from public, anon;
grant execute on function yuk_tolangan_summa(integer[]) to authenticated;
comment on function yuk_tolangan_summa(integer[]) is
  'Har yuk uchun to''langan jami (UZS) + entrylar. entry_yuk (posted, o''chirilmagan) + yuk_yopiq '
  '(qayta hisob bilan yopilgan qism, yopiq=true). ENG OXIRGI versiya: PROVODKA_YUK_YOPISH.sql.';

-- ---------------------------------------------------------------------------
-- 7) _yuk_grafik_maqsad_calc — QAYTA E'LON (imzo bir xil): maqsad yopiq qadar kamayadi.
--    Qisman yopilgan hujjatga grafik = (narx + tannarx + bojxona − yopiq) bo'yicha qo'yiladi,
--    FIFO esa faqat haqiqiy to'lovlarni sanaydi → qoldiq to'g'ri.
-- ---------------------------------------------------------------------------
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
  v_yopiq   numeric := 0;
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
  select coalesce(sum(summa_uzs), 0) into v_yopiq
    from yuk_yopiq where yuk_id = p_yuk_id and not is_deleted;

  return jsonb_build_object(
    'ok', true,
    'maqsad', greatest(0, coalesce(p_narx, 0) + (v_tannarx + v_bojxona - v_yopiq) / v_kurs),
    'valyuta', v_valyuta,
    'narx', p_narx,
    'tannarx_uzs', v_tannarx,
    'bojxona_uzs', v_bojxona,
    'yopiq_uzs', v_yopiq,
    'kurs', v_kurs);
end
$yg_maqsad_calc$;
revoke all on function _yuk_grafik_maqsad_calc(integer, numeric, text) from public, anon, authenticated;
comment on function _yuk_grafik_maqsad_calc(integer, numeric, text) is
  'ICHKI: "butun tannarx" (C) minus qayta hisobda yopilgan qism (yuk_yopiq). ENG OXIRGI versiya: '
  'PROVODKA_YUK_YOPISH.sql.';

-- ---------------------------------------------------------------------------
-- TEKSHIRUV
-- ---------------------------------------------------------------------------
select 'yuk_yopiq' as obyekt, case when to_regclass('public.yuk_yopiq') is not null then '✅' else '❌' end as holat
union all select 'yuk_yopish_toplam', case when to_regprocedure('public.yuk_yopish_toplam(jsonb,text,text)') is not null then '✅' else '❌' end
union all select 'yuk_yopiq_jami', case when to_regprocedure('public.yuk_yopiq_jami(integer[])') is not null then '✅' else '❌' end
union all select 'yuk_yopiq_bekor', case when to_regprocedure('public.yuk_yopiq_bekor(integer)') is not null then '✅' else '❌' end
union all select 'yuk_tolangan_summa (yopiq bilan)', case when pg_get_functiondef('public.yuk_tolangan_summa(integer[])'::regprocedure) like '%yuk_yopiq%' then '✅' else '❌' end
union all select '_yuk_grafik_maqsad_calc (yopiq bilan)', case when pg_get_functiondef('public._yuk_grafik_maqsad_calc(integer,numeric,text)'::regprocedure) like '%yopiq%' then '✅' else '❌' end;
