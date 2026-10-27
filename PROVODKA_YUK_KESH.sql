-- ============================================================================
--  PROVODKA_YUK_KESH.sql — 2026-10-27 — Aros yuklar KESHI: sahifalar har safar Aros'ga bormaydi
--  ----------------------------------------------------------------------------
--  Muammo (Asilbek): yuklar/professional «Tovar tannarxi» ro'yxati har ochilishda n8n → Aros'ga
--  boradi (sekin), 30 kunlik oyna + Aros 1 sahifa = 500 chegarasi sabab eski yuklar (2600–2700)
--  ko'rinmaydi, ID bilan qidirib bo'lmaydi.
--  Yechim: mavjud `aros_yuk_snapshot` (PROVODKA_YUK_GURUH_OZGARISH.sql, 12-BO'LIM) TO'LIQ KESH bo'ladi:
--    1  qo'shimcha ustunlar (sahifa ishlatadigan maydonlar): ombor_id, yetkazuvchi_tel, delivery_status,
--       post_at, sana_vaqt + indekslar
--    2  sync_aros_yuk_snapshot(p_data) QAYTA e'lon — yangi maydonlarni ham yozadi; kichik oyna (≤14 kun,
--       refresh webhook) uchun «10 tadan kam → payload_kichik» qoidasi yumshatildi (0 ta → payload_bosh)
--    3  yuk_kesh_royxat(p jsonb) — SAHIFA o'qiydigan RPC (webhook `yuklar[]` SHAKLIDA qaytaradi),
--       filtr: from/to | ids | q (ID yoki matn) | yetkazuvchi | ombor; + yetkazuvchilar ro'yxati + kesh holati
--    4  yakuniy tekshiruvlar
--  n8n: N8N_YUK_SNAPSHOT_V2.sh — «Yuk Snapshot Sync» 45 kunlik bo'laklar bilan o'qiydi (500 chegarasi
--  yutmasin), yangi webhook `aros-provodka-yuk-refresh?days=7|date_from&date_to` — sahifadagi «Aros'dan
--  yangilash» tugmasi va BIR MARTALIK BACKFILL (date_from=2024-01-01) shu orqali.
--  OLD SHART: PROVODKA_YUK_GURUH_OZGARISH.sql RUN qilingan (aros_yuk_snapshot, _ays_* yordamchilar).
--  ADDITIVE: drop yo'q, faqat `create or replace` / `add column if not exists`. IDEMPOTENT.
--  Dollar-quote: faqat NOMLI teglar ($yk_...$).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0) OLD SHART tekshiruvi
-- ---------------------------------------------------------------------------
do $yk_pre$
begin
  if to_regclass('public.aros_yuk_snapshot') is null then
    raise exception 'OLD SHART: aros_yuk_snapshot yo''q — avval PROVODKA_YUK_GURUH_OZGARISH.sql RUN qiling';
  end if;
  if to_regprocedure('public._ays_muhim(integer)') is null
     or to_regprocedure('public._ays_izoh(integer)') is null then
    raise exception 'OLD SHART: _ays_muhim/_ays_izoh yo''q — PROVODKA_YUK_GURUH_OZGARISH.sql to''liq RUN qilinmagan';
  end if;
end
$yk_pre$;

-- ---------------------------------------------------------------------------
-- 1) Ustunlar + indekslar
-- ---------------------------------------------------------------------------
alter table aros_yuk_snapshot add column if not exists ombor_id        integer;
alter table aros_yuk_snapshot add column if not exists yetkazuvchi_tel text;
alter table aros_yuk_snapshot add column if not exists delivery_status text;
alter table aros_yuk_snapshot add column if not exists post_at         timestamptz;
alter table aros_yuk_snapshot add column if not exists sana_vaqt       timestamptz;

comment on column aros_yuk_snapshot.ombor_id        is 'Aros warehouse.id';
comment on column aros_yuk_snapshot.yetkazuvchi_tel is 'Aros provider.phone_number';
comment on column aros_yuk_snapshot.delivery_status is 'Aros delivery_status (accepted|on_way|...)';
comment on column aros_yuk_snapshot.post_at         is 'Aros post_at — nashr vaqti';
comment on column aros_yuk_snapshot.sana_vaqt       is 'Aros created_datetime (to''liq vaqt); sana = shuning kuni';

create index if not exists aros_yuk_snapshot_mavjud_sana_idx on aros_yuk_snapshot (mavjud, sana desc);
create index if not exists aros_yuk_snapshot_yetk_idx on aros_yuk_snapshot (lower(yetkazuvchi));

-- ---------------------------------------------------------------------------
-- 2) sync_aros_yuk_snapshot(p_data) — QAYTA (yangi maydonlar + kichik oyna qoidasi)
--    Mantiq 15-BO'LIM bilan BIR XIL (narx/valyuta/qaytdi/ochirildi hodisalari), farqlar:
--      * upsert ombor_id/yetkazuvchi_tel/delivery_status/post_at/sana_vaqt ni ham yozadi
--        (payloadda yo'q bo'lsa eski qiymat saqlanadi — coalesce);
--      * yuklar=0 → {ok:false,kod:'payload_bosh'}; yuklar<10 FAQAT oyna >14 kun bo'lsa
--        'payload_kichik' (7 kunlik refresh'da 3 ta yuk bo'lishi normal);
--      * p_data.manba ('soat'|'webhook') javobda qaytariladi (diagnostika).
-- ---------------------------------------------------------------------------
create or replace function sync_aros_yuk_snapshot(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $yk_sync$
declare
  v_role         text;
  v_yuklar       jsonb;
  v_el           jsonb;
  v_oyna_from    date;
  v_oyna_to      date;
  v_id           integer;
  v_narx         numeric;
  v_valyuta      text;
  v_status       text;
  v_ombor        text;
  v_ombor_id     integer;
  v_yetkazuvchi  text;
  v_yetk_tel     text;
  v_sana         date;
  v_sana_vaqt    timestamptz;
  v_dstatus      text;
  v_post_at      timestamptz;
  v_old          aros_yuk_snapshot;
  v_stale        aros_yuk_snapshot;
  v_muhim        boolean;
  v_izoh         text;
  v_tur          text;
  v_was_insert   boolean;
  v_ids_korilgan integer[] := '{}';
  n_yozildi      int := 0;
  n_yangilandi   int := 0;
  n_yangi_hodisa int := 0;
  n_ochirildi    int := 0;
  n_tashlandi    int := 0;
begin
  -- ---- service_role ONLY (n8n) ----
  if auth.uid() is not null then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;
  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is not null and v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('sync_aros_yuk_snapshot'));

  if p_data is null or jsonb_typeof(p_data) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'kod', 'payload_shakli');
  end if;

  v_yuklar := p_data -> 'yuklar';
  if jsonb_typeof(v_yuklar) is distinct from 'array' or jsonb_array_length(v_yuklar) = 0 then
    return jsonb_build_object('ok', false, 'kod', 'payload_bosh');
  end if;

  v_oyna_from := nullif(p_data ->> 'oyna_from', '')::date;
  v_oyna_to   := nullif(p_data ->> 'oyna_to', '')::date;

  -- Katta oynada 10 tadan kam yuk — shubhali (Transfer Sync sabog'i: jimgina 0 yo'q).
  if jsonb_array_length(v_yuklar) < 10
     and (v_oyna_from is null or v_oyna_to is null or (v_oyna_to - v_oyna_from) > 14) then
    return jsonb_build_object('ok', false, 'kod', 'payload_kichik');
  end if;

  for v_el in select * from jsonb_array_elements(v_yuklar)
  loop
    begin
      v_id := nullif(v_el ->> 'id', '')::integer;
      if v_id is null then
        n_tashlandi := n_tashlandi + 1;
        continue;
      end if;
      v_ids_korilgan := array_append(v_ids_korilgan, v_id);

      v_narx        := nullif(v_el ->> 'narx', '')::numeric;
      v_valyuta     := upper(nullif(btrim(coalesce(v_el ->> 'valyuta', '')), ''));
      v_status      := nullif(btrim(coalesce(v_el ->> 'status', '')), '');
      v_ombor       := nullif(btrim(coalesce(v_el ->> 'ombor', '')), '');
      v_ombor_id    := nullif(v_el ->> 'ombor_id', '')::integer;
      v_yetkazuvchi := nullif(btrim(coalesce(v_el ->> 'yetkazuvchi', '')), '');
      v_yetk_tel    := nullif(btrim(coalesce(v_el ->> 'yetkazuvchi_tel', '')), '');
      v_sana_vaqt   := nullif(v_el ->> 'sana_vaqt', '')::timestamptz;
      v_sana        := coalesce(nullif(v_el ->> 'sana', '')::date, (v_sana_vaqt at time zone 'Asia/Tashkent')::date);
      v_dstatus     := nullif(btrim(coalesce(v_el ->> 'delivery_status', '')), '');
      v_post_at     := nullif(v_el ->> 'post_at', '')::timestamptz;

      select * into v_old from aros_yuk_snapshot where yuk_id = v_id;
      v_muhim := _ays_muhim(v_id);

      if v_old.yuk_id is not null and v_old.mavjud = false then
        if not _ays_ochiq_bor(v_id, 'qaytdi', v_old.narx, v_narx, v_valyuta) then
          v_izoh := 'Aros''da qayta paydo boldi (avval yoqolgan/ochirilgan edi). ' || _ays_izoh(v_id);
          insert into aros_yuk_ozgarish (yuk_id, tur, eski_narx, yangi_narx, valyuta, muhim, izoh)
            values (v_id, 'qaytdi', v_old.narx, v_narx, v_valyuta, v_muhim, v_izoh);
          n_yangi_hodisa := n_yangi_hodisa + 1;
        end if;
      end if;

      if v_old.yuk_id is not null and v_narx is not null and v_old.narx is not null
         and v_narx is distinct from v_old.narx then
        v_tur := case when v_narx < v_old.narx then 'narx_kamaydi' else 'narx_oshdi' end;
        if not _ays_ochiq_bor(v_id, v_tur, v_old.narx, v_narx, v_valyuta) then
          v_izoh := (case when v_tur = 'narx_kamaydi' then 'Aros''da narx kamaydi' else 'Aros''da narx oshdi' end)
                    || ' (' || coalesce(v_old.narx::text, '?') || ' -> ' || coalesce(v_narx::text, '?') || '). '
                    || _ays_izoh(v_id);
          insert into aros_yuk_ozgarish (yuk_id, tur, eski_narx, yangi_narx, valyuta, muhim, izoh)
            values (v_id, v_tur, v_old.narx, v_narx, v_valyuta, v_muhim, v_izoh);
          n_yangi_hodisa := n_yangi_hodisa + 1;
        end if;
      end if;

      if v_old.yuk_id is not null and v_valyuta is not null and v_old.valyuta is not null
         and v_valyuta is distinct from v_old.valyuta then
        if not _ays_ochiq_bor(v_id, 'valyuta', null, null, v_valyuta) then
          v_izoh := 'Aros''da valyuta ozgardi (' || v_old.valyuta || ' -> ' || v_valyuta || '). ' || _ays_izoh(v_id);
          insert into aros_yuk_ozgarish (yuk_id, tur, eski_narx, yangi_narx, valyuta, muhim, izoh)
            values (v_id, 'valyuta', null, null, v_valyuta, v_muhim, v_izoh);
          n_yangi_hodisa := n_yangi_hodisa + 1;
        end if;
      end if;

      insert into aros_yuk_snapshot (yuk_id, narx, valyuta, status, ombor, ombor_id, yetkazuvchi, yetkazuvchi_tel,
                                      sana, sana_vaqt, delivery_status, post_at,
                                      mavjud, birinchi_korilgan, oxirgi_korilgan)
      values (v_id, v_narx, v_valyuta, v_status, v_ombor, v_ombor_id, v_yetkazuvchi, v_yetk_tel,
              v_sana, v_sana_vaqt, v_dstatus, v_post_at, true, now(), now())
      on conflict (yuk_id) do update
         set narx            = excluded.narx,
             valyuta         = excluded.valyuta,
             status          = excluded.status,
             ombor           = excluded.ombor,
             ombor_id        = coalesce(excluded.ombor_id,        aros_yuk_snapshot.ombor_id),
             yetkazuvchi     = excluded.yetkazuvchi,
             yetkazuvchi_tel = coalesce(excluded.yetkazuvchi_tel, aros_yuk_snapshot.yetkazuvchi_tel),
             sana            = coalesce(excluded.sana,            aros_yuk_snapshot.sana),
             sana_vaqt       = coalesce(excluded.sana_vaqt,       aros_yuk_snapshot.sana_vaqt),
             delivery_status = coalesce(excluded.delivery_status, aros_yuk_snapshot.delivery_status),
             post_at         = coalesce(excluded.post_at,         aros_yuk_snapshot.post_at),
             mavjud          = true,
             oxirgi_korilgan = now()
      returning (xmax = 0) into v_was_insert;

      if v_was_insert then
        n_yozildi := n_yozildi + 1;
      else
        n_yangilandi := n_yangilandi + 1;
      end if;

    exception when others then
      n_tashlandi := n_tashlandi + 1;
      continue;
    end;
  end loop;

  -- Oynada, avval ko'rilgan, lekin bu payloadda YO'Q yuklar -> mavjud=false + ochirildi.
  -- 2026-10-27: KICHIK oyna (≤14 kun, refresh webhook) va <10 yukda SWEEP QILINMAYDI — Aros qisman javob
  -- bersa yuklar jimgina «ochirildi» bo'lib qolmasin; o'chirishni soatlik 90 kunlik sync aniqlaydi.
  if v_oyna_from is not null and v_oyna_to is not null
     and ((v_oyna_to - v_oyna_from) > 14 or jsonb_array_length(v_yuklar) >= 10) then
    for v_stale in
      select s.* from aros_yuk_snapshot s
       where s.mavjud = true
         and s.sana between v_oyna_from and v_oyna_to
         and not (s.yuk_id = any(v_ids_korilgan))
    loop
      v_muhim := _ays_muhim(v_stale.yuk_id);
      if not _ays_ochiq_bor(v_stale.yuk_id, 'ochirildi', v_stale.narx, null, v_stale.valyuta) then
        v_izoh := 'Aros''da ochirilgan (butunlay yoqolgan). ' || _ays_izoh(v_stale.yuk_id);
        insert into aros_yuk_ozgarish (yuk_id, tur, eski_narx, yangi_narx, valyuta, muhim, izoh)
          values (v_stale.yuk_id, 'ochirildi', v_stale.narx, null, v_stale.valyuta, v_muhim, v_izoh);
        n_yangi_hodisa := n_yangi_hodisa + 1;
      end if;
      update aros_yuk_snapshot set mavjud = false, oxirgi_korilgan = now() where yuk_id = v_stale.yuk_id;
      n_ochirildi := n_ochirildi + 1;
    end loop;
  end if;

  return jsonb_build_object(
    'ok', true,
    'manba', p_data ->> 'manba',
    'oyna_from', v_oyna_from, 'oyna_to', v_oyna_to,
    'korildi', coalesce(array_length(v_ids_korilgan, 1), 0),
    'yangi_hodisa', n_yangi_hodisa,
    'ochirildi', n_ochirildi,
    'yozildi', n_yozildi,
    'yangilandi', n_yangilandi,
    'tashlandi', n_tashlandi);
end
$yk_sync$;

revoke all on function sync_aros_yuk_snapshot(jsonb) from public, anon, authenticated;
grant execute on function sync_aros_yuk_snapshot(jsonb) to service_role;

comment on function sync_aros_yuk_snapshot(jsonb) is
  'service_role ONLY (n8n). p_data={oyna_from,oyna_to,manba,yuklar:[{id,narx,valyuta,status,ombor,ombor_id,'
  'yetkazuvchi,yetkazuvchi_tel,sana,sana_vaqt,delivery_status,post_at}]}. 2026-10-27: TO''LIQ KESH — '
  'yuklar=0 -> payload_bosh; <10 FAQAT oyna>14 kun bo''lsa payload_kichik. Narx/valyuta o''zgarishi va oyna '
  'ichida yo''qolgan yuklar aros_yuk_ozgarish ga yoziladi.';

-- ---------------------------------------------------------------------------
-- 3) yuk_kesh_royxat(p jsonb) — sahifa o'qiydi. Ruxsat: har qanday LOGIN qilgan user
--    (webhook `aros-provodka-yuklar` ham ochiq edi; professional modali har hodimga kerak).
--    p = { from:'YYYY-MM-DD', to:'YYYY-MM-DD'      -- sana oynasi (default oxirgi 30 kun, eng ko'pi 1100 kun)
--          ids:[int,...]                           -- berilsa sana oynasi E'TIBORSIZ (ID bo'yicha qidiruv)
--          q:'2712' | 'akmal'                      -- raqam -> yuk_id teng YOKI shu bilan boshlanadi (oynadan tashqari ham!);
--                                                  -- matn -> ombor/yetkazuvchi/tel ilike
--          yetkazuvchi:'...', ombor:'...',         -- aniq moslik
--          limit:int (default 5000, max 20000) }
--    Qaytishi: { ok, rows:[{id,sana,ombor,ombor_id,yetkazuvchi,yetkazuvchi_tel,narx,valyuta,status,
--                           delivery_status,post_at,kesh:true}],  -- webhook yuklar[] bilan BIR XIL shakl
--                jami, yetkazuvchilar:[...], holat:{jami, min_sana, max_sana, synced_at} }
--    `rows` sana bo'yicha kamayib (yangi birinchi) — Aros ordering=-1 bilan bir xil.
-- ---------------------------------------------------------------------------
create or replace function yuk_kesh_royxat(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $yk_royxat$
declare
  v_from   date;
  v_to     date;
  v_ids    integer[];
  v_q      text;
  v_qid    boolean := false;
  v_qnum   integer;                 -- q raqam bo'lsa — cast BIR MARTA shu yerda (where ichida cast xato bermasin)
  v_yetk   text;
  v_ombor  text;
  v_limit  int;
  v_rows   jsonb;
  v_jami   int;
  v_yetks  jsonb;
  v_holat  jsonb;
begin
  if auth.uid() is null then
    raise exception 'Login kerak' using errcode = '42501';
  end if;
  p := coalesce(p, '{}'::jsonb);

  v_to    := coalesce(nullif(p ->> 'to', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_from  := coalesce(nullif(p ->> 'from', '')::date, v_to - 30);
  if v_from > v_to then v_from := v_to; end if;
  if (v_to - v_from) > 1100 then v_from := v_to - 1100; end if;

  if jsonb_typeof(p -> 'ids') = 'array' then
    select coalesce(array_agg((x)::integer), '{}') into v_ids
      from jsonb_array_elements_text(p -> 'ids') x where x ~ '^\d{1,9}$';
  end if;
  v_q := nullif(btrim(coalesce(p ->> 'q', '')), '');
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');   -- like/ilike wildcard emas, oddiy matn
  if v_q is not null and v_q ~ '^\d{1,9}$' then v_qid := true; v_qnum := v_q::integer; end if;
  v_yetk  := nullif(btrim(coalesce(p ->> 'yetkazuvchi', '')), '');
  v_ombor := nullif(btrim(coalesce(p ->> 'ombor', '')), '');
  v_limit := least(greatest(coalesce(nullif(p ->> 'limit', '')::int, 5000), 1), 20000);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',              l.yuk_id,
           'sana',            coalesce(to_char(l.sana_vaqt at time zone 'Asia/Tashkent', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '+05:00',
                                       to_char(l.sana, 'YYYY-MM-DD') || 'T00:00:00+05:00'),
           'ombor',           coalesce(l.ombor, ''),
           'ombor_id',        l.ombor_id,
           'yetkazuvchi',     coalesce(l.yetkazuvchi, ''),
           'yetkazuvchi_tel', coalesce(l.yetkazuvchi_tel, ''),
           'narx',            coalesce(l.narx, 0)::text,
           'valyuta',         coalesce(l.valyuta, ''),
           'status',          coalesce(l.status, ''),
           'delivery_status', coalesce(l.delivery_status, ''),
           'post_at',         case when l.post_at is null then null
                                   else to_char(l.post_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '+05:00' end,
           'kesh',            true
         ) order by coalesce(l.sana_vaqt, l.sana::timestamptz) desc, l.yuk_id desc), '[]'::jsonb),
         count(*)
    into v_rows, v_jami
    from (
      select s.*
        from aros_yuk_snapshot s
       where s.mavjud = true
         and (
               -- ID qidiruvi / ids — sana oynasidan QAT'I NAZAR
               (v_ids is not null and cardinality(v_ids) > 0 and s.yuk_id = any(v_ids))
            or (v_qid and (s.yuk_id = v_qnum or s.yuk_id::text like v_q || '%'))
            or (
                 (v_ids is null or cardinality(v_ids) = 0) and not v_qid
                 and s.sana between v_from and v_to
                 and (v_q is null or s.ombor ilike '%' || v_q || '%' or s.yetkazuvchi ilike '%' || v_q || '%'
                      or s.yetkazuvchi_tel ilike '%' || v_q || '%')
               )
             )
         and (v_yetk  is null or s.yetkazuvchi = v_yetk)
         and (v_ombor is null or s.ombor = v_ombor)
       order by coalesce(s.sana_vaqt, s.sana::timestamptz) desc, s.yuk_id desc
       limit v_limit
    ) l;

  -- Yetkazib beruvchilar — tanlangan oynada (ID qidiruvida ham oyna bo'yicha, filtr tanlovi uchun)
  select coalesce(jsonb_agg(x.yetkazuvchi order by x.yetkazuvchi), '[]'::jsonb) into v_yetks
    from (select distinct s.yetkazuvchi
            from aros_yuk_snapshot s
           where s.mavjud = true and s.sana between v_from and v_to
             and nullif(btrim(coalesce(s.yetkazuvchi, '')), '') is not null) x;

  select jsonb_build_object(
           'jami',      count(*),
           'min_sana',  min(s.sana),
           'max_sana',  max(s.sana),
           'synced_at', max(s.oxirgi_korilgan))
    into v_holat
    from aros_yuk_snapshot s where s.mavjud = true;

  return jsonb_build_object(
    'ok', true,
    'from', v_from, 'to', v_to,
    'rows', v_rows,
    'jami', v_jami,
    'yetkazuvchilar', v_yetks,
    'holat', v_holat);
end
$yk_royxat$;

revoke all on function yuk_kesh_royxat(jsonb) from public, anon;
grant execute on function yuk_kesh_royxat(jsonb) to authenticated, service_role;

comment on function yuk_kesh_royxat(jsonb) is
  'Aros yuklar KESHI (aros_yuk_snapshot, mavjud=true) — sahifalar Aros''ga bormay shu yerdan o''qiydi. '
  'p={from,to|ids|q|yetkazuvchi|ombor|limit}. rows[] webhook aros-provodka-yuklar yuklar[] bilan BIR XIL '
  'shakl (+kesh:true). q raqam bo''lsa yuk_id bo''yicha, sana oynasidan tashqari ham topadi. Login kerak.';

-- ---------------------------------------------------------------------------
-- 4) Yakuniy tekshiruv
-- ---------------------------------------------------------------------------
do $yk_check$
declare v_ok boolean;
begin
  perform 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'aros_yuk_snapshot' and column_name = 'sana_vaqt';
  if not found then raise exception 'YAKUNIY: aros_yuk_snapshot.sana_vaqt yo''q'; end if;

  if to_regprocedure('public.yuk_kesh_royxat(jsonb)') is null then
    raise exception 'YAKUNIY: yuk_kesh_royxat(jsonb) yaralmadi';
  end if;
  select has_function_privilege('authenticated', 'public.yuk_kesh_royxat(jsonb)', 'execute') into v_ok;
  if not v_ok then raise exception 'YAKUNIY: authenticated uchun yuk_kesh_royxat EXECUTE yo''q'; end if;
  select has_function_privilege('anon', 'public.yuk_kesh_royxat(jsonb)', 'execute') into v_ok;
  if v_ok then raise exception 'YAKUNIY: anon yuk_kesh_royxat ni chaqira olmasligi kerak edi'; end if;
  select has_function_privilege('authenticated', 'public.sync_aros_yuk_snapshot(jsonb)', 'execute') into v_ok;
  if v_ok then raise exception 'YAKUNIY: authenticated sync_aros_yuk_snapshot ni chaqira olmasligi kerak edi'; end if;
  raise notice 'PROVODKA_YUK_KESH.sql OK — endi N8N_YUK_SNAPSHOT_V2.sh + Publish, keyin backfill: '
               'curl "https://n8n.arosmarket.com/webhook/aros-provodka-yuk-refresh?date_from=2024-01-01"';
end
$yk_check$;

notify pgrst, 'reload schema';

-- KO'RISH: select (yuk_kesh_royxat('{"q":"2700"}'::jsonb)) -> rows[0].id = 2700 (backfill'dan keyin)
