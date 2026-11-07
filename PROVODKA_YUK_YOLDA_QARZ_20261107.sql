-- ============================================================================
--  PROVODKA_YUK_YOLDA_QARZ_20261107.sql — 2026-11-07 — YO'LDAGI yuklar (on_way, nashr qilinmagan) HAM yetkazuvchi qarzi
--  ----------------------------------------------------------------------------
--  Asilbek: «yo'ldagi yuk ham yetkazuvchiga qarz — kelmagan yukdan qarz». Hozir faqat status='posted' qarz.
--  Fakt: Yuk Snapshot Sync (n8n) Aros webhook'idan HAMMA yukni oladi (status filtri yo'q) — on_way yuklar
--  aros_yuk_snapshot da allaqachon bor (delivery_status='on_way'), n8n O'ZGARMAYDI.
--  Bu fayl:
--    1  aros_yuk_ozgarish.tur CHECK ga 'yolda_narx', 'yolda_posted' qo'shiladi
--    2  sync_aros_yuk_snapshot QAYTA (PROVODKA_YUK_KESH.sql nusxasi AYNAN + 2 ta yangi hodisa):
--         yolda_narx   — yo'ldagi (nashr qilinmagan, on_way) yukda narx o'zgardi (narx_oshdi/narx_kamaydi o'rniga)
--         yolda_posted — yo'ldagi yuk nashr qilindi; oxirgi narx YAKUNIY (narx o'zgarmagan bo'lsa faqat tarix: korildi=true)
--    3  yuk_kesh_royxat(p) QAYTA — rows[] ga `yolda` (boolean) qo'shildi; mavjud maydonlar o'zgarmadi
--    4  YANGI yuk_yolda_jami() — {ok, soni, jami_uzs, by_cur[], by_yetk[], kurs_sana} (Balans/Qarzdor uchun)
--  OLD SHART: PROVODKA_YUK_KESH.sql RUN qilingan. ADDITIVE, IDEMPOTENT (create or replace; CHECK qayta tuziladi,
--  mavjud qatorlar yangi ro'yxatga mos). Dollar-quote: faqat NOMLI teglar.
--  Yo'ldagi yukka PUL TO'LASH hali ham taqiqlangan (professional: faqat posted) — bu fayl unga tegmaydi.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0) OLD SHART
-- ---------------------------------------------------------------------------
do $yy_pre$
begin
  if to_regclass('public.aros_yuk_snapshot') is null or to_regclass('public.aros_yuk_ozgarish') is null then
    raise exception 'OLD SHART: aros_yuk_snapshot/aros_yuk_ozgarish yo''q — avval PROVODKA_YUK_GURUH_OZGARISH.sql RUN qiling';
  end if;
  perform 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'aros_yuk_snapshot' and column_name = 'delivery_status';
  if not found then
    raise exception 'OLD SHART: aros_yuk_snapshot.delivery_status yo''q — avval PROVODKA_YUK_KESH.sql RUN qiling';
  end if;
  if to_regprocedure('public.conv_baza_kurs(text)') is null then
    raise exception 'OLD SHART: conv_baza_kurs(text) yo''q — PROVODKA_KASSA2.sql RUN qilinmagan';
  end if;
end
$yy_pre$;

-- ---------------------------------------------------------------------------
-- 1) aros_yuk_ozgarish.tur CHECK — yangi turlar
-- ---------------------------------------------------------------------------
do $yy_ck$
declare r record;
begin
  for r in select c.conname from pg_constraint c
            where c.conrelid = 'public.aros_yuk_ozgarish'::regclass and c.contype = 'c'
              and pg_get_constraintdef(c.oid) ilike '%narx_kamaydi%'
  loop
    execute format('alter table public.aros_yuk_ozgarish drop constraint %I', r.conname);
  end loop;
  alter table public.aros_yuk_ozgarish
    add constraint aros_yuk_ozgarish_tur_check
    check (tur in ('ochirildi','qaytdi','narx_kamaydi','narx_oshdi','valyuta','yolda_narx','yolda_posted'));
end
$yy_ck$;

-- ---------------------------------------------------------------------------
-- 2) sync_aros_yuk_snapshot(p_data) — QAYTA (yolda_narx / yolda_posted hodisalari qo'shildi, qolgani AYNAN avvalgidek)
-- ---------------------------------------------------------------------------

create or replace function sync_aros_yuk_snapshot(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $yy_sync$
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
  v_yolda_old    boolean;
  v_yolda_new    boolean;
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

      -- Yo'lda = nashr qilinmagan (posted/canceled emas) va delivery_status = on_way. Eski surat v_old da,
      -- yangisi payloaddan (delivery_status bo'sh kelsa upsert eskisini saqlaydi — coalesce).
      v_yolda_old := v_old.yuk_id is not null
                     and coalesce(v_old.status, '') not in ('posted', 'canceled')
                     and v_old.delivery_status = 'on_way';
      v_yolda_new := coalesce(v_status, '') not in ('posted', 'canceled')
                     and coalesce(v_dstatus, v_old.delivery_status) = 'on_way';

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
        v_tur := case when v_yolda_old or v_yolda_new then 'yolda_narx'
                      when v_narx < v_old.narx then 'narx_kamaydi' else 'narx_oshdi' end;
        if not _ays_ochiq_bor(v_id, v_tur, v_old.narx, v_narx, v_valyuta) then
          v_izoh := (case when v_tur = 'yolda_narx' then 'Yo''ldagi yukda narx ' || (case when v_narx < v_old.narx then 'kamaydi' else 'oshdi' end)
                          when v_tur = 'narx_kamaydi' then 'Aros''da narx kamaydi' else 'Aros''da narx oshdi' end)
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

      -- Yo'ldagi yuk nashr qilindi: oxirgi narx YAKUNIY. Narx o'zgargan bo'lsa yuqoridagi yolda_narx ham yozilgan;
      -- narx o'zgarmagan bo'lsa bu hodisa faqat tarix (korildi=true) — banner to'lib ketmasin.
      if v_yolda_old and v_status = 'posted' then
        if not _ays_ochiq_bor(v_id, 'yolda_posted', v_old.narx, coalesce(v_narx, v_old.narx), v_valyuta) then
          v_izoh := 'Yo''ldagi yuk nashr qilindi — yakuniy narx ' || coalesce(v_narx, v_old.narx)::text
                    || ' (yo''lda oxirgi: ' || coalesce(v_old.narx::text, '?') || '). ' || _ays_izoh(v_id);
          insert into aros_yuk_ozgarish (yuk_id, tur, eski_narx, yangi_narx, valyuta, muhim, izoh, korildi, korildi_at)
            values (v_id, 'yolda_posted', v_old.narx, coalesce(v_narx, v_old.narx), v_valyuta, v_muhim, v_izoh,
                    (v_narx is null or v_narx is not distinct from v_old.narx),
                    case when (v_narx is null or v_narx is not distinct from v_old.narx) then now() end);
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
$yy_sync$;

revoke all on function sync_aros_yuk_snapshot(jsonb) from public, anon, authenticated;
grant execute on function sync_aros_yuk_snapshot(jsonb) to service_role;

comment on function sync_aros_yuk_snapshot(jsonb) is
  'service_role ONLY (n8n). p_data={oyna_from,oyna_to,manba,yuklar:[{id,narx,valyuta,status,ombor,ombor_id,'
  'yetkazuvchi,yetkazuvchi_tel,sana,sana_vaqt,delivery_status,post_at}]}. To''liq kesh; narx/valyuta/yoqolish '
  'hodisalari aros_yuk_ozgarish ga yoziladi. 2026-11-07: yoldagi (on_way, nashr qilinmagan) yukda narx '
  'ozgarsa tur=yolda_narx; yolda yuk posted bolsa tur=yolda_posted (yakuniy narx).';

-- ---------------------------------------------------------------------------
-- 3) yuk_kesh_royxat(p) — QAYTA: rows[].yolda (boolean) qo'shildi, boshqa hamma narsa AYNAN avvalgidek
-- ---------------------------------------------------------------------------

create or replace function yuk_kesh_royxat(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $yy_royxat$
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
           'kesh',            true,
           'yolda',           (coalesce(l.status, '') not in ('posted', 'canceled') and l.delivery_status = 'on_way')
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
$yy_royxat$;

revoke all on function yuk_kesh_royxat(jsonb) from public, anon;
grant execute on function yuk_kesh_royxat(jsonb) to authenticated, service_role;

comment on function yuk_kesh_royxat(jsonb) is
  'Aros yuklar KESHI (aros_yuk_snapshot, mavjud=true) — sahifalar Aros''ga bormay shu yerdan o''qiydi. '
  'p={from,to|ids|q|yetkazuvchi|ombor|limit}. rows[] webhook aros-provodka-yuklar yuklar[] bilan BIR XIL '
  'shakl (+kesh:true, +yolda: nashr qilinmagan va delivery_status=on_way). q raqam bo''lsa yuk_id bo''yicha, '
  'sana oynasidan tashqari ham topadi. Login kerak.';

-- ---------------------------------------------------------------------------
-- 4) yuk_yolda_jami() — yo'ldagi (kelmagan, nashr qilinmagan) yuklar jami qarzi
--    Faqat: mavjud, status posted/canceled EMAS, delivery_status='on_way'. Summa = narx x JORIY kurs
--    (conv_baza_kurs: USD -> aros_usd_rate, bo'lmasa/boshqa valyuta -> currency_rate oxirgisi; CHY = CNY;
--    UZS = 1) — qarzdor sahifasidagi yuk_kurslar bilan BIR XIL. Kursi topilmagan valyuta jamiga QO'SHILMAYDI,
--    `kurs_yoq` da ro'yxatlanadi (jimgina yo'qolmasin).
--    Ruxsat: is_admin() yoki perm_has_page('qarzdor') yoki perm_has_page('balans').
--    Qaytishi: {ok, soni, jami_uzs, by_cur:[{valyuta,narx,uzs}], by_yetk:[{yetkazuvchi,soni,uzs}], kurs_sana,
--               kurs_yoq:[valyuta], eski_soni}
--    kurs_sana — ishlatilgan kurslar currency_rate dagi eng yangi rate_at sanasi (yo'q bo'lsa null).
--    eski_soni — 90 kundan eski yo'ldagi yuklar: soatlik sync (90 kun) ularni yangilamaydi, holati eskirgan
--    bo'lishi mumkin (nashr qilingan bo'lsa ham "yo'lda" ko'rinadi) — yangilash: refresh webhook date_from bilan.
-- ---------------------------------------------------------------------------
create or replace function yuk_yolda_jami()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $yy_jami$
declare
  v_ok     boolean := false;
  v_kurs   jsonb := '{}'::jsonb;
  v_cur    text;
  v_r      numeric;
  v_cur_n  text;
  v_by_cur jsonb;
  v_by_yet jsonb;
  v_soni   int;
  v_jami   numeric;
  v_sana   date;
  v_yoq    jsonb;
  v_eski   int;
begin
  if auth.uid() is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if is_admin() then
    v_ok := true;
  else
    v_ok := coalesce(perm_has_page('qarzdor') or perm_has_page('balans'), false);
  end if;
  if not v_ok then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat_yoq');
  end if;

  -- valyuta -> kurs (bir marta har valyutaga)
  for v_cur in
    select distinct upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS'))
      from aros_yuk_snapshot s
     where s.mavjud = true and coalesce(s.status, '') <> 'posted' and coalesce(s.status, '') <> 'canceled'
       and s.delivery_status = 'on_way'
  loop
    if v_cur = 'UZS' then
      v_r := 1;
    else
      v_cur_n := case v_cur when 'CHY' then 'CNY' else v_cur end;
      begin
        v_r := conv_baza_kurs(v_cur_n);
      exception when others then v_r := null;
      end;
      if v_r is not null and v_r <= 0 then v_r := null; end if;
    end if;
    v_kurs := v_kurs || jsonb_build_object(v_cur, v_r);
  end loop;

  with y as (
    select s.yuk_id, s.sana,
           coalesce(nullif(btrim(s.yetkazuvchi), ''), '—') as yetk,
           upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS')) as cur,
           coalesce(s.narx, 0) as narx,
           nullif(v_kurs ->> upper(coalesce(nullif(btrim(s.valyuta), ''), 'UZS')), '')::numeric as kurs
      from aros_yuk_snapshot s
     where s.mavjud = true and coalesce(s.status, '') <> 'posted' and coalesce(s.status, '') <> 'canceled'
       and s.delivery_status = 'on_way'
  )
  select
    count(*),
    coalesce(sum(round(narx * kurs)) filter (where kurs is not null), 0),
    count(*) filter (where sana < (now() at time zone 'Asia/Tashkent')::date - 90),
    coalesce((select jsonb_agg(jsonb_build_object('valyuta', g.cur, 'narx', g.narx, 'uzs', g.uzs) order by g.uzs desc, g.cur)
                from (select cur, sum(narx) as narx,
                             coalesce(sum(round(narx * kurs)) filter (where kurs is not null), 0) as uzs
                        from y group by cur) g), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object('yetkazuvchi', g.yetk, 'soni', g.soni, 'uzs', g.uzs) order by g.uzs desc, g.yetk)
                from (select yetk, count(*) as soni,
                             coalesce(sum(round(narx * kurs)) filter (where kurs is not null), 0) as uzs
                        from y group by yetk) g), '[]'::jsonb),
    coalesce((select jsonb_agg(distinct cur) from y where kurs is null), '[]'::jsonb)
    into v_soni, v_jami, v_eski, v_by_cur, v_by_yet, v_yoq
    from y;

  select max(cr.rate_at)::date into v_sana
    from currency_rate cr
   where upper(cr.to_code) = 'UZS' and cr.rate > 0
     and (case upper(cr.from_code) when 'CHY' then 'CNY' else upper(cr.from_code) end)
         in (select case k when 'CHY' then 'CNY' else k end from jsonb_object_keys(v_kurs) k);

  return jsonb_build_object(
    'ok', true,
    'soni', coalesce(v_soni, 0),
    'jami_uzs', coalesce(v_jami, 0),
    'by_cur', v_by_cur,
    'by_yetk', v_by_yet,
    'kurs_sana', v_sana,
    'kurs_yoq', v_yoq,
    'eski_soni', coalesce(v_eski, 0));
end
$yy_jami$;

revoke all on function yuk_yolda_jami() from public, anon;
grant execute on function yuk_yolda_jami() to authenticated, service_role;

comment on function yuk_yolda_jami() is
  'Yoldagi (kelmagan, nashr qilinmagan: status posted/canceled emas, delivery_status=on_way) yuklar jami qarzi: '
  '{ok, soni, jami_uzs, by_cur:[{valyuta,narx,uzs}], by_yetk:[{yetkazuvchi,soni,uzs}], kurs_sana, kurs_yoq, eski_soni}. '
  'narx x joriy kurs (conv_baza_kurs). Ruxsat: admin yoki perm_has_page(qarzdor|balans).';


-- ---------------------------------------------------------------------------
-- 5) Yakuniy tekshiruv
-- ---------------------------------------------------------------------------
do $yy_check$
declare v_ok boolean;
begin
  if to_regprocedure('public.yuk_yolda_jami()') is null then
    raise exception 'YAKUNIY: yuk_yolda_jami() yaralmadi';
  end if;
  select has_function_privilege('anon', 'public.yuk_yolda_jami()', 'execute') into v_ok;
  if v_ok then raise exception 'YAKUNIY: anon yuk_yolda_jami ni chaqira olmasligi kerak edi'; end if;
  select has_function_privilege('authenticated', 'public.yuk_yolda_jami()', 'execute') into v_ok;
  if not v_ok then raise exception 'YAKUNIY: authenticated uchun yuk_yolda_jami EXECUTE yo''q'; end if;
  select has_function_privilege('authenticated', 'public.sync_aros_yuk_snapshot(jsonb)', 'execute') into v_ok;
  if v_ok then raise exception 'YAKUNIY: authenticated sync_aros_yuk_snapshot ni chaqira olmasligi kerak edi'; end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.aros_yuk_ozgarish'::regclass and conname = 'aros_yuk_ozgarish_tur_check'
                    and pg_get_constraintdef(oid) like '%yolda_posted%') then
    raise exception 'YAKUNIY: aros_yuk_ozgarish_tur_check yangilanmadi';
  end if;
  raise notice 'PROVODKA_YUK_YOLDA_QARZ_20261107.sql OK';
end
$yy_check$;

notify pgrst, 'reload schema';

-- KO'RISH: select yuk_yolda_jami();  select yuk_id, yolda from jsonb_to_recordset((yuk_kesh_royxat('{}'::jsonb))->'rows') as t(yuk_id int, yolda bool);
