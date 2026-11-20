-- =====================================================================
-- PROVODKA — «BIZ QARZDOR» YAGONA HISOB: Qarz sahifasi = Aylanma Q2b (2026-11-20, Asilbek)
-- ---------------------------------------------------------------------
-- ## MUAMMO
--   20.11.2026: Aylanma «Biz qarzdormiz» (Q2b) 71,16 mlrd, Qarz sahifasi (qarzdor-dev, «Biz qarzdor»,
--   JAMI QARZ) 25,8 mlrd (shundan yo'lda 7,8). Asilbek: «Aylanmadagi qarzdormiz TO'LIQ Qarz sahifasidan
--   o'qisin, nega ikkalasi ikki xil». Sabablar:
--     1) OYNA: Aylanma n8n payloadidagi 365 kunlik hujjat; Qarz sahifasi n8n `aros-provodka-yuklar`
--        (eng yangi 500 ta). Provodka to'lov yozuvidan oldingi (to'lovsiz) eski hujjatlar faqat Aylanmada edi.
--     2) FORMULA: Q2b = narx x kurs - yuk_tolangan_summa (so'm, kursga qaytadi). Qarz sahifasi esa
--        yuk_tolangan_fc (valyutada) + qo'shilgan tannarx + qoldiq chegarasi.
--     3) TARKIB: Q2b da on_way (yo'ldagi) yuklar, yuk_qolda (boshlang'ich qarz) yo'q edi; yetkazuvchi
--        avansi ayirilmasdi; «Qayta kirim», «Samarqand filiali» kabi ICHKI yetkazuvchilar qarz deb sanalardi.
--
-- ## NIMA O'ZGARADI (ADDITIVE; hech narsa o'chirilmaydi, imzolar saqlanadi)
--   1-BO'LIM  yuk_ichki_yetkazuvchi(nom text pk) — ichki (filial/tizim) yetkazuvchilar ro'yxati, default qatorlar bilan.
--             Ro'yxatga qator qo'shish/o'chirish — oddiy insert/delete (Asilbek ko'rib chiqadi).
--   2-BO'LIM  biz_qarz_hisob(p_yuklar jsonb, p_kurs_usd numeric default null) -> jsonb — YAGONA hisob.
--             Qarz sahifasi (qarzdor-dev, klient formulasi o'rniga) va sync_aylanma_snapshot Q2b shuni chaqiradi.
--             Formula (qarzdor-dev dagi AYNAN): narx x kurs + qo'shilgan tannarx (yuk_tannarx_jami)
--             - tolangan (yuk_tolangan_fc: valyutada, kursga qaytmaydi); qoldiq chegarasidan kichigi = 0;
--             posted + on_way(yo'lda) hujjatlar + yuk_qolda; yetkazuvchi avansi (entry.yuk_kutilmoqda) ayiriladi;
--             ICHKI yetkazuvchilar jamiga KIRMAYDI, lekin ichki{soni, uzs, nomlar, qatorlar} da ko'rinadi.
--             Chegara: yaxlitlash_chegara(text) (PROVODKA_YAXLITLASH_20261120.sql; VALYUTA BIRLIGIDA: USD 1, CHY 100,
--             UZS 10000 — kurs bilan so'mga o'giriladi) BOR va > 0 bo'lsa — o'sha; aks holda qarzdor-dev eski qoidasi
--             (UZS: 1 so'm; valyutali: min(max(1, 1,5%), 10 USD)). Javobda chegara_manba ko'rsatadi.
--             Funksiya YO'Q bo'lsa Yaxlitlash SQL keyin RUN qilinsa ham bu funksiyani qayta RUN qilish shart EMAS (dinamik).
--   3-BO'LIM  sync_aylanma_snapshot(jsonb) QAYTA e'lon — imzo bir xil, tana PROVODKA_AYLANMA_HODIM_KASSA.sql
--             dan VERBATIM; FAQAT [Q2b] bloki biz_qarz_hisob ni chaqiradi (+ declare da v_q2b_in, v_biz).
--             Q2b = jami qarz - avans. Qatorlar: har hujjat + «avans» (minus) + «ichki hujjatlar» (hisobga=false,
--             lekin Aylanma tafsilotida har doim ko'rinadi). n8n payload O'ZGARMAYDI.
--             Aros payloadda on_way hujjat bo'lmasa — aros_yuk_snapshot dagi (365 kun ichidagi) yo'ldagilar qo'shiladi.
--
-- ## RUN TARTIBI
--   1) shu fayl (bitta RUN; faqat yangi jadval/funksiya, eski ma'lumotga tegmaydi)
--   2) qarzdor-dev.html + aylanma-dev.html ni yangilash (Ctrl+F5)
--   3) keyingi cron snapshot (yoki n8n «qolda») — Q2b yangi formula bilan. Eski snapshotlar O'ZGARMAYDI (tarix).
--   4) ixtiyoriy: pastdagi TEKSHIRUV so'rovlari
-- Idempotent. Pul harakati YO'Q. Funksiya tanalari NOMLI dollar-teg bilan (biz_pre / biz_fn / ayl_sync).
-- =====================================================================

do $biz_pre$
begin
  if to_regprocedure('public.sync_aylanma_snapshot(jsonb)') is null then
    raise exception 'sync_aylanma_snapshot(jsonb) yoq — avval PROVODKA_AYLANMA_HODIM_KASSA.sql ni bajaring';
  end if;
  if to_regprocedure('public.yuk_tolangan_fc(jsonb)') is null then
    raise exception 'yuk_tolangan_fc(jsonb) yoq — avval PROVODKA_YUK_TOLOV_VALYUTA.sql ni bajaring';
  end if;
  if to_regprocedure('public.yuk_tannarx_jami(integer[])') is null then
    raise exception 'yuk_tannarx_jami(integer[]) yoq — avval PROVODKA_YUK_TANNARX.sql ni bajaring';
  end if;
  if to_regprocedure('public.yuk_kurslar(text[])') is null then
    raise exception 'yuk_kurslar(text[]) yoq — avval PROVODKA_VALYUTA_ALIAS.sql ni bajaring';
  end if;
  if to_regclass('public.yuk_qolda') is null then
    raise exception 'yuk_qolda yoq — avval PROVODKA_YUK_QOLDA.sql ni bajaring';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'entry' and column_name in ('yetkazuvchi')) then
    raise exception 'entry.yetkazuvchi yoq — avval PROVODKA_YUK_AVANS_YETKAZUVCHI.sql ni bajaring';
  end if;
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'is_admin() yoq — asosiy migratsiya bajarilmagan';
  end if;
end
$biz_pre$;


-- #####################################################################
-- ##  1-BO'LIM — yuk_ichki_yetkazuvchi                                ##
-- #####################################################################
-- Aros'da «yetkazuvchi» sifatida turadigan, lekin aslida ichki (filial/tizim) hujjatlar — haqiqiy qarz EMAS.
-- Moslash: lower(btrim(nom)) — registr va chetdagi bo'shliqqa qaramaydi.
create table if not exists yuk_ichki_yetkazuvchi (
  nom        text primary key,
  izoh       text,
  created_at timestamptz not null default now()
);
create unique index if not exists yuk_ichki_yetkazuvchi_lower_uq on yuk_ichki_yetkazuvchi (lower(btrim(nom)));

alter table yuk_ichki_yetkazuvchi enable row level security;
revoke all on table yuk_ichki_yetkazuvchi from public, anon, authenticated;
grant select on table yuk_ichki_yetkazuvchi to authenticated;
drop policy if exists yuk_ichki_yetkazuvchi_sel on yuk_ichki_yetkazuvchi;
create policy yuk_ichki_yetkazuvchi_sel on yuk_ichki_yetkazuvchi for select to authenticated using (true);
-- yozish faqat SQL editor (admin) orqali: insert into yuk_ichki_yetkazuvchi (nom, izoh) values ('...', '...');

comment on table yuk_ichki_yetkazuvchi is
  'Ichki (filial/tizim) yetkazuvchilar — biz_qarz_hisob ularni jamiga QOSHMAYDI, ichki{} da alohida ko''rsatadi. '
  'ENG OXIRGI: PROVODKA_BIZ_QARZ_YAGONA_20261120.sql';

insert into yuk_ichki_yetkazuvchi (nom, izoh) values
  ('Qayta kirim',                  'ichki: qayta kirim hujjatlari'),
  ('Mijozdan qaytgan tovarlar',    'ichki: mijoz qaytargan tovar'),
  ('Asosiy Qarshi (Shahboz)',      'ichki: filial'),
  ('Samarqand filiali',            'ichki: filial'),
  ('Mobil sentr',                  'ichki'),
  ('Taminotchi_zapchast',          'ichki: tizim yetkazuvchisi'),
  ('Taminotchi_Aks',               'ichki: tizim yetkazuvchisi')
on conflict do nothing;


-- #####################################################################
-- ##  2-BO'LIM — biz_qarz_hisob(p_yuklar, p_kurs_usd)                  ##
-- #####################################################################
-- p_yuklar: Aros hujjatlar massivi (n8n yuk shakli): [{id, narx|document_price, valyuta, status, delivery_status,
--           yetkazuvchi, ombor, sana}]. Faqat status='posted' YOKI (status posted/canceled emas va delivery_status
--           ='on_way') olinadi. `qolda:true` qatorlar e'tiborga olinmaydi — boshlang'ich qarz yuk_qolda jadvalidan
--           funksiyaning o'zi qo'shadi (yuk_qolda_royxat() service_role da bo'sh qaytadi, shuning uchun jadvaldan).
-- Ruxsat: service_role/ichki (auth.uid null) — doim; foydalanuvchi — admin yoki perm_has_page qarzdor/balans/aylanma/yuklar.
create or replace function biz_qarz_hisob(p_yuklar jsonb, p_kurs_usd numeric default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $biz_fn$
declare
  v_ok       boolean := true;
  v_docs     jsonb;
  v_ids      int[];
  v_curs     text[];
  v_kurs     jsonb;
  v_paid     jsonb;
  v_tan      jsonb;
  v_usd      numeric;
  v_cap      numeric;
  v_cur      text;
  v_x        numeric;
  v_chegara  jsonb := '{}'::jsonb;
  v_ch_manba text := 'eski_qoida';
  v_all      jsonb;
  v_qator    jsonb;
  v_jami     numeric;
  v_yolda    numeric;
  v_avans    numeric;
  v_ich_soni int;
  v_ich_uzs  numeric;
  v_ich_qat  jsonb;
  v_ich_nom  jsonb;
  v_kurs_yoq jsonb;
  v_skip     int := 0;
begin
  if auth.uid() is not null then
    v_ok := is_admin();
    if not v_ok and to_regprocedure('public.perm_has_page(text)') is not null then
      v_ok := coalesce(perm_has_page('qarzdor') or perm_has_page('balans')
                       or perm_has_page('aylanma') or perm_has_page('yuklar'), false);
    end if;
    if not v_ok then
      return jsonb_build_object('ok', false, 'kod', 'ruxsat_yoq');
    end if;
  end if;

  -- ---- 1) hujjatlar: posted + yo'lda (Aros) + boshlang'ich qarz (yuk_qolda); bir id — bitta qator ----
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id, 'yetk', d.yetk, 'ombor', d.ombor, 'narx', d.narx, 'val', d.val,
           'yolda', d.yolda, 'qolda', d.qolda) order by d.id), '[]'::jsonb)
    into v_docs
    from (
      select distinct on (u.id) u.*
        from (
          select (x ->> 'id')::int as id,
                 nullif(btrim(x ->> 'yetkazuvchi'), '') as yetk,
                 nullif(btrim(x ->> 'ombor'), '') as ombor,
                 coalesce(nullif(x ->> 'narx', ''), nullif(x ->> 'document_price', ''), '0')::numeric as narx,
                 upper(coalesce(nullif(btrim(x ->> 'valyuta'), ''), 'UZS')) as val,
                 (coalesce(x ->> 'status', '') not in ('posted', 'canceled') and x ->> 'delivery_status' = 'on_way') as yolda,
                 false as qolda,
                 1 as pr,
                 ord
            from jsonb_array_elements(case when jsonb_typeof(p_yuklar) = 'array' then p_yuklar else '[]'::jsonb end)
                 with ordinality as e(x, ord)
           where (x ->> 'id') ~ '^[0-9]{1,9}$'
             and coalesce(nullif(x ->> 'narx', ''), nullif(x ->> 'document_price', ''), '0') ~ '^-?[0-9]+(\.[0-9]+)?$'
             and coalesce(x ->> 'qolda', '') <> 'true'
             and (x ->> 'status' = 'posted'
                  or (coalesce(x ->> 'status', '') not in ('posted', 'canceled') and x ->> 'delivery_status' = 'on_way'))
          union all
          select q.id, nullif(btrim(q.yetkazuvchi), ''), 'Boshlang''ich qarz', q.narx,
                 upper(coalesce(nullif(btrim(q.valyuta), ''), 'UZS')), false, true, 0, 0::bigint
            from yuk_qolda q
           where not q.is_deleted
        ) u
       order by u.id, u.pr, u.ord
    ) d;

  -- yaroqsiz element (id sondan tashqari/katta, narx son emas) butun hisobni yiqitmasin — o'tkaziladi va sanaladi
  select count(*) into v_skip
    from jsonb_array_elements(case when jsonb_typeof(p_yuklar) = 'array' then p_yuklar else '[]'::jsonb end) x
   where jsonb_typeof(x) = 'object'
     and coalesce(x ->> 'qolda', '') <> 'true'
     and (x ->> 'status' = 'posted'
          or (coalesce(x ->> 'status', '') not in ('posted', 'canceled') and x ->> 'delivery_status' = 'on_way'))
     and not ((x ->> 'id') ~ '^[0-9]{1,9}$'
              and coalesce(nullif(x ->> 'narx', ''), nullif(x ->> 'document_price', ''), '0') ~ '^-?[0-9]+(\.[0-9]+)?$');

  select coalesce(array_agg(t.id), '{}') into v_ids from jsonb_to_recordset(v_docs) as t(id int);
  select coalesce(array_agg(distinct t.val), '{}') || array['USD'] into v_curs from jsonb_to_recordset(v_docs) as t(val text);

  -- ---- 2) kurslar (yuk_kurslar = conv_baza_kurs, CHY=CNY) ----
  v_kurs := yuk_kurslar(v_curs);
  if p_kurs_usd is not null and p_kurs_usd > 0 then
    v_kurs := v_kurs || jsonb_build_object('USD', p_kurs_usd);
  end if;
  v_usd := nullif(v_kurs ->> 'USD', '')::numeric;
  if not (coalesce(v_usd, 0) > 0) then v_usd := null; end if;
  v_cap := case when v_usd is not null then v_usd * 10 else 120000 end;   -- kursFarqiCapUzs()

  -- ---- 3) qoldiq chegarasi: yaxlitlash_chegara(valyuta) bor bo'lsa shu (so'mda), aks holda eski qoida ----
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'yaxlitlash_chegara'
                and oidvectortypes(p.proargtypes) = 'text') then
    for v_cur in select distinct t.val from jsonb_to_recordset(v_docs) as t(val text) loop
      begin
        execute 'select yaxlitlash_chegara($1)::numeric' into v_x using v_cur;
        if v_x is not null and v_x > 0 then
          v_chegara := v_chegara || jsonb_build_object(v_cur, v_x);
          v_ch_manba := 'yaxlitlash_chegara';
        end if;
      exception when others then
        raise warning 'biz_qarz_hisob: yaxlitlash_chegara(%) xato: % — eski qoida', v_cur, sqlerrm;
      end;
    end loop;
  end if;

  -- ---- 4) to'langan (valyutada) + qo'shilgan tannarx ----
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'valyuta', t.val)), '[]'::jsonb)
    into v_paid from jsonb_to_recordset(v_docs) as t(id int, val text);
  v_paid := yuk_tolangan_fc(v_paid);
  v_tan := yuk_tannarx_jami(v_ids);

  -- ---- 5) har hujjat qoldig'i (qarzdor-dev qoldiqUzs bilan AYNAN bir xil) ----
  select coalesce(jsonb_agg(jsonb_build_object(
           'ref', z.id::text,
           'nom', coalesce(z.yetk, '') || case when z.ombor is not null then ' · ' || z.ombor else '' end,
           'yetkazuvchi', z.yetk, 'ombor', z.ombor,
           'uzs', z.uzs,
           'usd', case when z.uzs is not null and v_usd is not null then round(z.uzs / v_usd, 2) end,
           'valyuta', z.val, 'yolda', z.yolda, 'qolda', z.qolda,
           'kurs_yoq', z.uzs is null, 'ichki', z.ichki) order by z.uzs desc nulls last, z.id), '[]'::jsonb)
    into v_all
    from (
      select y.*,
             case when y.r is null then null
                  when y.q <= y.lim then 0
                  else y.q end as uzs
        from (
          select w.*,
                 w.jami - w.tolangan as q,
                 -- yaxlitlash_chegara VALYUTA BIRLIGIDA (USD 1, CHY 100, UZS 10000) — so'mga kurs bilan o'giriladi
                 coalesce(nullif((v_chegara ->> w.val), '')::numeric * w.r,
                          case when w.r = 1 then 1
                               else least(greatest(1, w.jami * 0.015), v_cap) end) as lim
            from (
              select d.id, d.yetk, d.ombor, d.val, d.yolda, d.qolda,
                     c.r,
                     round(coalesce(d.narx, 0) * c.r) + coalesce((v_tan -> (d.id::text) ->> 'jami_uzs')::numeric, 0) as jami,
                     case
                       when p.yuk_id is null then 0
                       when p.tolangan_fc is not null and c.r is not null and c.r <> 1 then p.tolangan_fc * c.r
                       else coalesce(p.tolangan_uzs, 0)
                     end as tolangan,
                     coalesce(exists (select 1 from yuk_ichki_yetkazuvchi i
                                       where lower(btrim(i.nom)) = lower(btrim(d.yetk))), false) as ichki
                from jsonb_to_recordset(v_docs) as d(id int, yetk text, ombor text, narx numeric, val text, yolda boolean, qolda boolean)
                left join lateral (
                  select case when d.val = 'UZS' then 1::numeric else nullif(v_kurs ->> d.val, '')::numeric end as r
                ) c on true
                left join jsonb_to_recordset(v_paid) as p(yuk_id int, tolangan_uzs numeric, tolangan_fc numeric)
                  on p.yuk_id = d.id
            ) w
        ) y
    ) z
   -- to'liq to'langan (qoldiq 0, kurs BOR) hujjat ro'yxatga kirmaydi; kursi yo'q — kirishi SHART (yashirin nol emas)
   where z.uzs is null or z.uzs > 0;

  -- ---- 6) jamlar ----
  select coalesce(sum((q ->> 'uzs')::numeric) filter (where (q ->> 'ichki')::boolean is not true), 0),
         coalesce(sum((q ->> 'uzs')::numeric) filter (where (q ->> 'ichki')::boolean is not true and (q ->> 'yolda')::boolean), 0),
         count(*) filter (where (q ->> 'ichki')::boolean),
         coalesce(sum((q ->> 'uzs')::numeric) filter (where (q ->> 'ichki')::boolean), 0)
    into v_jami, v_yolda, v_ich_soni, v_ich_uzs
    from jsonb_array_elements(v_all) q;

  select coalesce(jsonb_agg(q), '[]'::jsonb) into v_qator
    from jsonb_array_elements(v_all) q where (q ->> 'ichki')::boolean is not true;
  select coalesce(jsonb_agg(q), '[]'::jsonb) into v_ich_qat
    from jsonb_array_elements(v_all) q where (q ->> 'ichki')::boolean;
  select coalesce(jsonb_agg(distinct q ->> 'yetkazuvchi'), '[]'::jsonb) into v_ich_nom
    from jsonb_array_elements(v_ich_qat) q;

  select coalesce(jsonb_object_agg(k.val, k.n), '{}'::jsonb) into v_kurs_yoq
    from (select q ->> 'valyuta' as val, count(*) as n
            from jsonb_array_elements(v_qator) q
           where (q ->> 'kurs_yoq')::boolean group by 1) k;

  -- ---- 7) yetkazuvchi avansi (yetkazuvchi_avans_royxat bilan bir xil so'rov, auth tekshiruvisiz; ichkilari chiqarilgan) ----
  select coalesce(sum(case when coalesce(q.qoldiq, 0) > 0 then q.qoldiq else coalesce(q.jami, 0) end), 0)
    into v_avans
    from entry e
    left join lateral (
      select coalesce(sum(el.debit), 0) as jami,
             coalesce(sum(el.debit) filter (where a.code = '9110-1'), 0) as qoldiq
        from entry_line el join accounts a on a.id = el.account_id
       where el.entry_id = e.id and el.debit > 0
    ) q on true
   where e.yuk_kutilmoqda = true and e.is_deleted = false and e.status = 'posted'
     and nullif(btrim(coalesce(e.yetkazuvchi, '')), '') is not null
     and not exists (select 1 from yuk_ichki_yetkazuvchi i where lower(btrim(i.nom)) = lower(btrim(e.yetkazuvchi)));

  return jsonb_build_object(
    'ok', true,
    'jami_uzs', v_jami,
    'jami_usd', case when v_usd is not null then round(v_jami / v_usd, 2) end,
    'yolda_uzs', v_yolda,
    'avans_uzs', v_avans,
    'sof_uzs', v_jami - v_avans,
    'kurs_usd', v_usd,
    'soni', jsonb_array_length(v_qator),
    'qatorlar', v_qator,
    'kurs_yoq', v_kurs_yoq,
    'ichki', jsonb_build_object('soni', v_ich_soni, 'uzs', v_ich_uzs, 'nomlar', v_ich_nom, 'qatorlar', v_ich_qat),
    'ichki_nomlar', coalesce((select jsonb_agg(i.nom order by i.nom) from yuk_ichki_yetkazuvchi i), '[]'::jsonb),
    'otkazildi', v_skip,
    'chegara_manba', v_ch_manba);
end
$biz_fn$;

revoke all on function biz_qarz_hisob(jsonb, numeric) from public, anon;
grant execute on function biz_qarz_hisob(jsonb, numeric) to authenticated, service_role;
comment on function biz_qarz_hisob(jsonb, numeric) is
  'YAGONA «Biz qarzdor» hisobi (Qarz sahifasi + Aylanma Q2b). p_yuklar = Aros hujjatlar [{id,narx,valyuta,status,'
  'delivery_status,yetkazuvchi,ombor}]. Qoldiq = narx*kurs + tannarx - yuk_tolangan_fc*kurs; posted + yo''lda + yuk_qolda; '
  'avans ayiriladi (sof_uzs); ichki yetkazuvchilar (yuk_ichki_yetkazuvchi) jamiga kirmaydi — ichki{}. '
  'ENG OXIRGI: PROVODKA_BIZ_QARZ_YAGONA_20261120.sql';


-- #####################################################################
-- ##  3-BO'LIM — sync_aylanma_snapshot (imzo bir xil; HODIM_KASSA tanasi + yangi [Q2b])
-- #####################################################################

create or replace function sync_aylanma_snapshot(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $ayl_sync$
declare
  v_role         text;
  v_sana         date;
  v_rejim        text;
  v_manba        jsonb;
  v_omborlar     jsonb;
  v_yuklar       jsonb;
  v_transferlar  jsonb;
  v_buyurtmalar  jsonb;
  v_order_ids    int[];
  v_yuk_ids      int[];
  v_curs         text[];
  v_kurs_map     jsonb;
  v_kurs_usd     numeric;
  v_paid         jsonb;
  v_paid_map     jsonb;
  v_boj          numeric;
  v_row_val      numeric;
  v_tolangan     numeric;
  v_hisobga      boolean;
  v_q2b_missing  jsonb;
  v_curkey       text;
  v_curcnt       numeric;
  v_q2b_in       jsonb;
  v_biz          jsonb;

  v_toliq        boolean := true;
  v_xatolar      text[] := '{}';
  v_bolimlar     jsonb := '{}'::jsonb;
  v_qatorlar     jsonb := '[]'::jsonb;
  v_snapshot_id  uuid;
  v_jami_uzs     numeric;
  v_jami_usd     numeric;

  -- umumiy loop/scratch o'zgaruvchilari (bo'limlar KETMA-KET, parallel emas)
  v_el   jsonb;
  v_ref  text;
  v_nom  text;
  v_num  numeric;
  v_num2 numeric;
  v_bool boolean;
  v_txt  text;
  v_meta jsonb;

  -- har bo'lim uchun alohida jamlovchilar
  v_a_uzs   numeric; v_a_usd   numeric; v_a_soni   int; v_a_rows   jsonb;
  v_bola_uzs numeric; v_bola_usd numeric; v_bola_n int; v_farq numeric;   -- A: filial = Aros jonli
  v_kas_map jsonb; v_kas_ref text;
  v_b_uzs   numeric; v_b_usd   numeric; v_b_soni   int; v_b_rows   jsonb;
  v_t1_uzs  numeric;                    v_t1_soni  int; v_t1_rows  jsonb;
  v_t5_uzs  numeric;                    v_t5_soni  int; v_t5_rows  jsonb;
  v_y3a_uzs numeric;                    v_y3a_soni int; v_y3a_rows jsonb;
  v_k3b_uzs numeric;                    v_k3b_soni int; v_k3b_rows jsonb;
  v_k4_uzs  numeric;                    v_k4_soni  int; v_k4_rows  jsonb;
  v_b6_uzs  numeric;                    v_b6_soni  int; v_b6_rows  jsonb;
  v_q2a_uzs numeric;                                     v_q2a_rows jsonb;
  v_q2b_uzs numeric;                    v_q2b_soni int; v_q2b_rows jsonb;
  v_d_rows  jsonb;
  v_h_uzs   numeric; v_h_usd   numeric; v_h_soni   int; v_h_rows   jsonb; v_h jsonb;   -- H: hodim kassalari (2026-10-28)
begin
  -- ---- service_role ONLY (sync_transfer_yolda/sync_aros_qarzdor bilan bir xil naqsh) ----
  if auth.uid() is not null then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is not null and v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('sync_aylanma_snapshot'));

  -- ---- kirish validatsiyasi ----
  if p_data is null or jsonb_typeof(p_data) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'error', 'p_data object kutilgan edi');
  end if;

  begin
    v_sana := nullif(p_data ->> 'sana', '')::date;
  exception when others then
    v_sana := null;
  end;
  if v_sana is null then
    return jsonb_build_object('ok', false, 'error', 'sana (YYYY-MM-DD) kerak/notogri formatda');
  end if;

  v_rejim := lower(btrim(coalesce(p_data ->> 'rejim', '')));
  if v_rejim not in ('cron', 'qolda') then
    return jsonb_build_object('ok', false, 'error', 'rejim ''cron'' yoki ''qolda'' bolishi kerak');
  end if;

  v_manba := coalesce(p_data -> 'manba', '{}'::jsonb);
  if jsonb_typeof(v_manba) is distinct from 'object' then v_manba := '{}'::jsonb; end if;

  v_omborlar := p_data -> 'omborlar';
  if jsonb_typeof(v_omborlar) is distinct from 'array' then v_omborlar := '[]'::jsonb; end if;
  v_yuklar := p_data -> 'yuklar';
  if jsonb_typeof(v_yuklar) is distinct from 'array' then v_yuklar := '[]'::jsonb; end if;
  v_transferlar := p_data -> 'transferlar';
  if jsonb_typeof(v_transferlar) is distinct from 'array' then v_transferlar := '[]'::jsonb; end if;
  v_buyurtmalar := p_data -> 'buyurtmalar';
  if jsonb_typeof(v_buyurtmalar) is distinct from 'array' then v_buyurtmalar := '[]'::jsonb; end if;

  -- K3b/K4 uchun: order_id B6 (buyurtmalar) ichida bormi — ikki marta sanalmasin
  v_order_ids := '{}';
  begin
    select coalesce(array_agg((x ->> 'id')::int), '{}')
      into v_order_ids
      from jsonb_array_elements(v_buyurtmalar) x
     where nullif(x ->> 'id', '') ~ '^[0-9]+$';
  exception when others then
    v_order_ids := '{}';
  end;

  -- ---- kurs_usd (bir marta, hamma USD hisob shundan) ----
  v_kurs_usd := null;
  begin
    if _aylanma_fn_bor('aros_usd_rate', '') then
      execute 'select aros_usd_rate()' into v_kurs_usd;
    end if;
  exception when others then
    v_kurs_usd := null;
  end;
  if v_kurs_usd is null then
    begin
      if _aylanma_fn_bor('conv_baza_kurs', 'text') then
        execute 'select conv_baza_kurs($1)' into v_kurs_usd using 'USD';
      end if;
    exception when others then
      v_kurs_usd := null;
    end;
  end if;
  if v_kurs_usd is null then
    -- 🔴 USD ga bog'liq bo'limlar (A.usd/B/T1/T5) so'mga to'liq o'tolmaydi -> toliq=false.
    v_toliq := false;
    v_xatolar := array_append(v_xatolar,
      'USD kursi topilmadi (aros_usd_rate/conv_baza_kurs) — USD qiymatlar hisobga olinmadi');
  end if;

  -- =====================================================================
  -- [A] Pul (markaziy + filial kassalar) — v_kassa_card
  -- =====================================================================
  begin
    v_a_rows := '[]'::jsonb; v_a_uzs := 0; v_a_usd := 0; v_a_soni := 0;

    -- Aros jonli balans xaritasi (n8n payload kassalar[]): cachier_id -> qator
    v_kas_map := '{}'::jsonb;
    if jsonb_typeof(p_data -> 'kassalar') = 'array' then
      for v_el in select value from jsonb_array_elements(p_data -> 'kassalar') loop
        if (v_el ->> 'cachier_id') is not null then
          v_kas_map := v_kas_map || jsonb_build_object(btrim(v_el ->> 'cachier_id'), v_el);
        end if;
      end loop;
    end if;

    -- 🔴 2026-09-08 (DIAG bilan tasdiqlangan, Asilbek):
    --   * MARKAZIY kassalar (5011/5012, filial_ref NULL) — PROVODKA DAFTARI (v_kassa_card.jami):
    --     Aros'da yo'q chiqimlar shu yerda. Balans Sync ularga tegmaydi.
    --   * FILIAL kassalar (filial_ref bor) — daftar = Aros'ning soatlik nusxasi (parent 0, bolalar
    --     Aros'ga tenglashtiriladi). Jo'natish/qabul oralig'ida (1 soatgacha) daftar VAQTINCHA
    --     MANFIY bo'ladi (5213 −75 mln snapshot'da, DIAG'da +57 750). Shuning uchun filial uchun
    --     AROS JONLI balans (payload kassalar[]) olinadi = tenglashtirilgandan keyingi daftar.
    --     Aros qatori kelmasa — daftar (meta.manba='daftar').
    for v_ref, v_nom, v_num, v_num2, v_bola_n, v_kas_ref in
      select k.code, k.name, coalesce(k.jami, 0)::numeric, coalesce(k.usd, 0)::numeric,
             case when a.filial_ref is not null then 1 else 0 end, btrim(a.filial_ref::text)
        from v_kassa_card k
        left join accounts a on a.id = k.id
       where k.kassa_turi in ('markaziy', 'filial')
         and coalesce((to_jsonb(k) ->> 'is_active')::boolean, true)   -- nofaol kassa yo'q (kassa-dev filtri); ustun bo'lmasa true
    loop
      v_el := null;
      if v_bola_n = 1 and v_kas_ref is not null then v_el := v_kas_map -> v_kas_ref; end if;
      if v_el is not null then
        v_bola_usd := coalesce(nullif(v_el ->> 'dollar_usd', '')::numeric, 0);
        v_bola_uzs := coalesce(nullif(v_el ->> 'cash', '')::numeric, 0)
                    + coalesce(nullif(v_el ->> 'click', '')::numeric, 0)
                    + coalesce(nullif(v_el ->> 'payme', '')::numeric, 0)
                    + case when coalesce(v_kurs_usd, 0) > 0 then v_bola_usd * v_kurs_usd else 0 end;
        v_farq := v_num - v_bola_uzs;                 -- daftar − Aros (transient yoki kurs farqi)
        v_a_rows := v_a_rows || jsonb_build_object(
          'bolim', 'A', 'ref', v_ref, 'nom', v_nom, 'uzs', v_bola_uzs, 'usd', v_bola_usd,
          'soni', null, 'hisobga', true,
          'meta', jsonb_build_object('manba', 'aros', 'daftar_jami', v_num, 'daftar_usd', v_num2,
                                     'farq', v_farq, 'cash', v_el ->> 'cash', 'click', v_el ->> 'click',
                                     'payme', v_el ->> 'payme', 'manfiy', v_bola_uzs < 0));
        v_num := v_bola_uzs; v_num2 := v_bola_usd;
      else
        v_a_rows := v_a_rows || jsonb_build_object(
          'bolim', 'A', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', v_num2,
          'soni', null, 'hisobga', true,
          'meta', jsonb_build_object('manba', 'daftar', 'manfiy', v_num < 0));
      end if;
      if v_num < 0 then
        v_xatolar := array_append(v_xatolar, 'A: ' || v_nom || ' manfiy (' || round(v_num) || ')');
      end if;
      v_a_uzs  := v_a_uzs + v_num;
      v_a_usd  := v_a_usd + v_num2;
      v_a_soni := v_a_soni + 1;
    end loop;

    v_bolimlar := v_bolimlar || jsonb_build_object('A',
      jsonb_build_object('uzs', v_a_uzs, 'usd', v_a_usd, 'soni', v_a_soni));
    v_qatorlar := v_qatorlar || v_a_rows;
  exception when others then
    v_a_uzs := null; v_a_usd := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('A', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'A: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [H] Hodim kassalari (xaridor/hodim pullari) — 2026-10-28, Asilbek:
  --     «G'iyosni kassasini ham asosiy qilish kerak va barcha hodim kassalarni
  --     ham aylanmada ko'rsatishimiz kerak». 5400 «Hodim xarajat kassalari»
  --     konteyneri ostidagi BARCHA kassalar (54xx, kassa_turi='xarajat') —
  --     valyuta (USD/CHY/CNY/AED) va tur (naqd/click/payme) bola-hisoblari bilan.
  --     Avval A bo'limidan ATAYLAB chiqarilgan edi — shu sabab Toshkent kassa →
  --     G'iyos (5669 USD) o'tkazmalari SAK ni ~15 mlrd «yo'qotardi» (27.10: −1,2 mlrd).
  --     Hisob: aylanma_hodim_kassa(null, null) = JONLI daftar (v_hisob_bal semantikasi,
  --     PROVODKA_AYLANMA_HODIM_KASSA.sql). uzs — tarixiy kursdagi so'm ekvivalenti
  --     (A daftar qatorlari bilan bir xil), usd — USD bola-hisoblar fc yig'indisi.
  --     Alohida bo'lim (A ichiga qo'shilmagan): Asilbek «ko'rsatishimiz kerak» —
  --     zinapoyada ko'rinsin, A ning tarixiy ma'nosi (markaziy+filial) buzilmasin.
  -- =====================================================================
  begin
    v_h_rows := '[]'::jsonb; v_h_uzs := 0; v_h_usd := 0; v_h_soni := 0;
    v_h := aylanma_hodim_kassa(null, null);
    if coalesce((v_h ->> 'ok')::boolean, false) is not true then
      raise exception '%', coalesce(v_h ->> 'kod', v_h ->> 'error', 'aylanma_hodim_kassa xato');
    end if;
    v_h_uzs  := coalesce((v_h ->> 'uzs')::numeric, 0);
    v_h_usd  := coalesce((v_h ->> 'usd')::numeric, 0);
    v_h_soni := coalesce((v_h ->> 'soni')::int, 0);
    v_h_rows := coalesce(v_h -> 'rows', '[]'::jsonb);
    for v_el in select value from jsonb_array_elements(v_h_rows) loop
      if coalesce((v_el ->> 'uzs')::numeric, 0) < 0 then
        v_xatolar := array_append(v_xatolar,
          'H: ' || coalesce(v_el ->> 'nom', '?') || ' manfiy (' || round((v_el ->> 'uzs')::numeric) || ')');
      end if;
    end loop;

    v_bolimlar := v_bolimlar || jsonb_build_object('H',
      jsonb_build_object('uzs', v_h_uzs, 'usd', v_h_usd, 'soni', v_h_soni, 'manba', 'daftar'));
    v_qatorlar := v_qatorlar || v_h_rows;
  exception when others then
    v_h_uzs := null; v_h_usd := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('H', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'H: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [B] Yo'ldagi pul — aros_transfer_yolda status='sent'
  -- =====================================================================
  begin
    v_b_rows := '[]'::jsonb; v_b_uzs := 0; v_b_usd := 0; v_b_soni := 0;

    if to_regclass('public.aros_transfer_yolda') is not null then
      for v_ref, v_nom, v_num, v_num2, v_meta in
        select t.transfer_id,
               coalesce(t.sender_title, '?') || ' -> ' || coalesce(t.receiver_title, '?'),
               coalesce(t.s_cash, 0) + coalesce(t.s_click, 0) + coalesce(t.s_payme, 0)
                 + coalesce(t.s_usd, 0) * coalesce(v_kurs_usd, 0),
               coalesce(t.s_usd, 0),
               case when v_kurs_usd is null and coalesce(t.s_usd, 0) <> 0
                    then jsonb_build_object('kurs_yoq', true) else '{}'::jsonb end
          from aros_transfer_yolda t
         where t.status = 'sent'
      loop
        v_b_uzs  := v_b_uzs + v_num;
        v_b_usd  := v_b_usd + v_num2;
        v_b_soni := v_b_soni + 1;
        v_b_rows := v_b_rows || jsonb_build_object(
          'bolim', 'B', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', v_num2,
          'soni', null, 'hisobga', true, 'meta', v_meta);
      end loop;
    end if;

    v_bolimlar := v_bolimlar || jsonb_build_object('B',
      jsonb_build_object('uzs', v_b_uzs, 'usd', v_b_usd, 'soni', v_b_soni));
    v_qatorlar := v_qatorlar || v_b_rows;
  exception when others then
    v_b_uzs := null; v_b_usd := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('B', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'B: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [T1]/[T5] Tovar + brak omborlarda (Aros profit-summary, USD tannarx, payload orqali)
  -- =====================================================================
  begin
    v_t1_rows := '[]'::jsonb; v_t1_uzs := 0; v_t1_soni := 0;
    v_t5_rows := '[]'::jsonb; v_t5_uzs := 0; v_t5_soni := 0;

    if coalesce(v_manba ->> 'profit_api', v_manba ->> 'metabase', '') = 'xato' or coalesce(v_manba ->> 'warehouses', '') = 'xato' then
      v_t1_uzs := null; v_t5_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('T1', null, 'T5', null);
      v_toliq := false;
      if coalesce(v_manba ->> 'profit_api', v_manba ->> 'metabase', '') = 'xato' then
        v_xatolar := array_append(v_xatolar, 'T1/T5: manba.profit_api=xato — otkazib yuborildi');
      end if;
      if coalesce(v_manba ->> 'warehouses', '') = 'xato' then
        v_xatolar := array_append(v_xatolar, 'T1/T5: manba.warehouses=xato — otkazib yuborildi');
      end if;
    else
      for v_el in select * from jsonb_array_elements(v_omborlar) loop
        v_ref  := coalesce(v_el ->> 'id', '');
        v_nom  := coalesce(v_el ->> 'nom', '');
        v_bool := coalesce((v_el ->> 'is_broken')::boolean, false);
        v_num  := nullif(v_el ->> 'usd', '')::numeric;      -- ombor tannarxi (USD)

        if v_num is null then
          v_num2 := 0;
          v_meta := jsonb_build_object('yoq', true);
        elsif v_kurs_usd is null then
          v_num2 := 0;
          v_meta := jsonb_build_object('kurs_yoq', true);
        else
          v_num2 := round(v_num * v_kurs_usd, 2);
          v_meta := '{}'::jsonb;
        end if;

        if nullif(v_el ->> 'tr_yolda_uzs', '') is not null then
          v_meta := v_meta || jsonb_build_object('tr_yolda_uzs', (v_el ->> 'tr_yolda_uzs')::numeric);
        end if;

        if v_bool then
          v_t5_uzs  := v_t5_uzs + v_num2;
          v_t5_soni := v_t5_soni + 1;
          v_t5_rows := v_t5_rows || jsonb_build_object(
            'bolim', 'T5', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num2, 'usd', v_num,
            'soni', null, 'hisobga', true, 'meta', v_meta);
        else
          v_t1_uzs  := v_t1_uzs + v_num2;
          v_t1_soni := v_t1_soni + 1;
          v_t1_rows := v_t1_rows || jsonb_build_object(
            'bolim', 'T1', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num2, 'usd', v_num,
            'soni', null, 'hisobga', true, 'meta', v_meta);
        end if;
      end loop;

      v_bolimlar := v_bolimlar || jsonb_build_object(
        'T1', jsonb_build_object('uzs', v_t1_uzs, 'usd', null, 'soni', v_t1_soni),
        'T5', jsonb_build_object('uzs', v_t5_uzs, 'usd', null, 'soni', v_t5_soni));
      v_qatorlar := v_qatorlar || v_t1_rows || v_t5_rows;
    end if;
  exception when others then
    v_t1_uzs := null; v_t5_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('T1', null, 'T5', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'T1/T5: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [Y3a] Yo'ldagi yuklar — status=posted, delivery_status=on_way
  -- =====================================================================
  begin
    v_y3a_rows := '[]'::jsonb; v_y3a_uzs := 0; v_y3a_soni := 0;

    if coalesce(v_manba ->> 'incomes', '') = 'xato' then
      v_y3a_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('Y3a', null);
      v_toliq := false;
      v_xatolar := array_append(v_xatolar, 'Y3a: manba.incomes=xato — otkazib yuborildi');
    else
      select coalesce(array_agg(distinct upper(btrim(x ->> 'valyuta'))), '{}')
        into v_curs
        from jsonb_array_elements(v_yuklar) x
       where nullif(btrim(coalesce(x ->> 'valyuta', '')), '') is not null;

      v_kurs_map := '{}'::jsonb;
      if coalesce(array_length(v_curs, 1), 0) > 0
         and _aylanma_fn_bor('yuk_kurslar', 'text[]') then
        begin
          v_kurs_map := yuk_kurslar(v_curs);
        exception when others then
          v_kurs_map := '{}'::jsonb;
        end;
      end if;
      if v_kurs_usd is not null then
        v_kurs_map := v_kurs_map || jsonb_build_object('USD', v_kurs_usd);
      end if;

      for v_el in
        select * from jsonb_array_elements(v_yuklar) x
         where x ->> 'status' = 'posted' and x ->> 'delivery_status' = 'on_way'
      loop
        v_ref := coalesce(v_el ->> 'id', '');
        v_nom := coalesce(v_el ->> 'ombor', '')
          || case when nullif(v_el ->> 'yetkazuvchi', '') is not null
                  then ' · ' || (v_el ->> 'yetkazuvchi') else '' end;
        v_txt  := upper(btrim(coalesce(v_el ->> 'valyuta', '')));
        v_num  := nullif(v_kurs_map ->> v_txt, '')::numeric;
        v_num2 := coalesce(nullif(v_el ->> 'narx', '')::numeric, 0);

        if v_num is null then
          v_row_val := 0;
          v_meta := jsonb_build_object('kurs_yoq', true, 'valyuta', v_txt);
          v_xatolar := array_append(v_xatolar,
            'Y3a: yuk ' || coalesce(v_ref, '?') || ' kursi topilmadi (' || coalesce(v_txt, '?') || ')');
        else
          v_row_val := round(v_num2 * v_num, 2);
          v_meta := '{}'::jsonb;
        end if;

        -- bojxona (aros_yuk_bojxona) — mavjud bo'lsa qo'shiladi
        v_boj := 0;
        if to_regclass('public.aros_yuk_bojxona') is not null and v_ref ~ '^[0-9]+$' then
          begin
            select coalesce(bojxona_uzs, 0) into v_boj from aros_yuk_bojxona where yuk_id = v_ref::int;
          exception when others then
            v_boj := 0;
          end;
        end if;
        v_row_val := coalesce(v_row_val, 0) + coalesce(v_boj, 0);

        v_y3a_uzs  := v_y3a_uzs + v_row_val;
        v_y3a_soni := v_y3a_soni + 1;
        v_y3a_rows := v_y3a_rows || jsonb_build_object(
          'bolim', 'Y3a', 'ref', v_ref, 'nom', v_nom, 'uzs', v_row_val, 'usd', null,
          'soni', null, 'hisobga', true, 'meta', v_meta);
      end loop;

      v_bolimlar := v_bolimlar || jsonb_build_object('Y3a',
        jsonb_build_object('uzs', v_y3a_uzs, 'usd', null, 'soni', v_y3a_soni));
      v_qatorlar := v_qatorlar || v_y3a_rows;
    end if;
  exception when others then
    v_y3a_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('Y3a', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'Y3a: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [K3b]/[K4] Ko'chirish yo'lda (on_way) / yaratilgan (created)
  -- =====================================================================
  begin
    v_k3b_rows := '[]'::jsonb; v_k3b_uzs := 0; v_k3b_soni := 0;
    v_k4_rows  := '[]'::jsonb; v_k4_uzs  := 0; v_k4_soni  := 0;

    if coalesce(v_manba ->> 'transfers', '') = 'xato' then
      v_k3b_uzs := null; v_k4_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('K3b', null, 'K4', null);
      v_toliq := false;
      v_xatolar := array_append(v_xatolar, 'K3b/K4: manba.transfers=xato — otkazib yuborildi');
    else
      for v_el in select * from jsonb_array_elements(v_transferlar) loop
        v_ref  := coalesce(v_el ->> 'id', '');
        v_nom  := coalesce(v_el ->> 'from_nom', '?') || ' -> ' || coalesce(v_el ->> 'to_nom', '?');
        v_num  := coalesce(nullif(v_el ->> 'tannarx_uzs', '')::numeric,
                            nullif(v_el ->> 'price_uzs', '')::numeric, 0);
        v_txt  := v_el ->> 'status';
        v_bool := coalesce((v_el ->> 'to_brak')::boolean, false);
        v_num2 := nullif(v_el ->> 'order_id', '')::numeric;

        v_meta := '{}'::jsonb;
        if v_bool then v_meta := v_meta || jsonb_build_object('to_brak', true); end if;

        v_hisobga := true;
        if v_num2 is not null and v_num2::int = any(v_order_ids) then
          v_hisobga := false;              -- B6 (ochiq buyurtma) ichida — ikki marta sanalmasin
          v_meta := v_meta || jsonb_build_object('order_qoshildi', true);
        end if;

        if v_txt = 'on_way' then
          v_k3b_soni := v_k3b_soni + 1;
          if v_hisobga then v_k3b_uzs := v_k3b_uzs + v_num; end if;
          v_k3b_rows := v_k3b_rows || jsonb_build_object(
            'bolim', 'K3b', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', null,
            'soni', null, 'hisobga', v_hisobga, 'meta', v_meta);
        elsif v_txt = 'created' then
          v_k4_soni := v_k4_soni + 1;
          if v_hisobga then v_k4_uzs := v_k4_uzs + v_num; end if;
          v_k4_rows := v_k4_rows || jsonb_build_object(
            'bolim', 'K4', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', null,
            'soni', null, 'hisobga', v_hisobga, 'meta', v_meta);
        end if;
      end loop;

      v_bolimlar := v_bolimlar || jsonb_build_object(
        'K3b', jsonb_build_object('uzs', v_k3b_uzs, 'usd', null, 'soni', v_k3b_soni),
        'K4',  jsonb_build_object('uzs', v_k4_uzs,  'usd', null, 'soni', v_k4_soni));
      v_qatorlar := v_qatorlar || v_k3b_rows || v_k4_rows;
    end if;
  exception when others then
    v_k3b_uzs := null; v_k4_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('K3b', null, 'K4', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'K3b/K4: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [B6] Ochiq buyurtmalar — sotuv narxida (total_uzs)
  -- =====================================================================
  begin
    v_b6_rows := '[]'::jsonb; v_b6_uzs := 0; v_b6_soni := 0;

    if coalesce(v_manba ->> 'orders', '') = 'xato' then
      v_b6_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('B6', null);
      v_toliq := false;
      v_xatolar := array_append(v_xatolar, 'B6: manba.orders=xato — otkazib yuborildi');
    else
      for v_el in select * from jsonb_array_elements(v_buyurtmalar) loop
        v_ref := coalesce(v_el ->> 'id', '');
        v_nom := coalesce(v_el ->> 'warehouse', '');
        v_num := coalesce(nullif(v_el ->> 'total_uzs', '')::numeric, 0);

        v_b6_uzs  := v_b6_uzs + v_num;
        v_b6_soni := v_b6_soni + 1;
        v_b6_rows := v_b6_rows || jsonb_build_object(
          'bolim', 'B6', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', null,
          'soni', null, 'hisobga', true, 'meta', jsonb_build_object('status', v_el ->> 'status'));
      end loop;

      v_bolimlar := v_bolimlar || jsonb_build_object('B6',
        jsonb_build_object('uzs', v_b6_uzs, 'usd', null, 'soni', v_b6_soni));
      v_qatorlar := v_qatorlar || v_b6_rows;
    end if;
  exception when others then
    v_b6_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('B6', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'B6: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [Q2a] Bizdan qarzdor — Provodka qarz + Aros mijozlar
  -- ---------------------------------------------------------------------
  -- 🔴 `qarz_umumiy_dash()`/`qarz_dash()`/`aros_qarzdor_dash()` CHAQIRILMAYDI —
  -- ularning ICHIDA `qarz_dash()` `auth.uid() is null` bo'lsa "Avtorizatsiya
  -- kerak" bilan RAISE qiladi va `sorov_page_ok()` (qarz_page_ok orqali)
  -- ATAYLAB fail-closed (auth.uid() null -> false) — bu funksiyalar
  -- service_role/cron kontekstidan UMUMAN chaqirilishga mo'ljallanmagan
  -- (PROVODKA_SOROVLAR.sql/PROVODKA_QARZ.sql tanasi tegilmaydi). Shuning
  -- uchun bir xil raqam FORMULASI to'g'ridan jadval/view'dan takrorlanadi:
  --   Provodka = qarz_dash() dagi "jami_qolgan"  = sum(v_qarz_holat.qolgan) faol qarzlar
  --   Aros     = qarz_umumiy_dash() dagi "aros.total_debt" = aros_qarzdor_sync.summary->>'total_debt'
  --              (aros_qarzdor qatorlari YIG'INDISI EMAS — n8n bergan xom Aros summary).
  -- =====================================================================
  begin
    v_q2a_rows := '[]'::jsonb; v_q2a_uzs := 0;
    v_num := 0; v_num2 := 0;

    if to_regclass('public.qarz') is not null and to_regclass('public.v_qarz_holat') is not null then
      select coalesce(sum(h.qolgan), 0) into v_num
        from qarz q
        join v_qarz_holat h on h.qarz_id = q.id
       where q.status = 'faol';
    end if;

    -- 🔴 2026-09-09 TUZATISH (Asilbek: «qarzni noto'g'ri ko'rsatyapti, faqat
    --    hamyon balansni ko'rsatyaptimi deyman»).
    --    ESKI XATO: Aros qarzi FAQAT `summary ->> 'total_debt'` dan olinardi va
    --    u yo'q bo'lsa (summary null / kalit yo'q / sync qatori yo'q) JIMGINA 0
    --    bo'lardi — hamyon esa BARIBIR ayirilardi. Natija:
    --        Q2a = provodka + 0 − hamyon   → aslida «minus hamyon» ko'rinardi.
    --    Bu shu faylning O'Z qoidasini buzardi: «manba yo'q → bo'lim null +
    --    toliq=false + xatolar[]; JIMGINA 0 YO'Q».
    --    ENDI: manba aniq tanlanadi va qarz bilan hamyon AYNI manbadan olinadi
    --    (summary bilan jadval aralashmaydi — ular boshqa-boshqa qamrov).
    --      1) summary bo'lsa: qarz = summary.total_debt, hamyon = summary.total_wallet_balance
    --      2) bo'lmasa jadval: qarz = Σ total_debt (faol), hamyon = Σ wallet_balance (faol)
    --      3) ikkalasi ham yo'q: Q2a = null + toliq=false + xatolar[]  (0 EMAS)
    v_txt := null;                                  -- qaysi manba ishlatilgani
    v_num2 := null; v_bola_uzs := null;

    if to_regclass('public.aros_qarzdor_sync') is not null then
      select (s.summary ->> 'total_debt')::numeric,
             (s.summary ->> 'total_wallet_balance')::numeric
        into v_num2, v_bola_uzs
        from aros_qarzdor_sync s where s.id = 1;
      if v_num2 is not null then
        v_txt := 'summary';
        v_bola_uzs := coalesce(v_bola_uzs, 0);      -- qarz bor, hamyon kaliti yo'q → 0
      end if;
    end if;

    if v_txt is null and to_regclass('public.aros_qarzdor') is not null then
      -- Jadval zaxirasi: ARX bo'yicha Σ total_debt = summary.total_debt.
      select coalesce(sum(a.total_debt), 0), coalesce(sum(a.wallet_balance), 0)
        into v_num2, v_bola_uzs
        from aros_qarzdor a
       where coalesce((to_jsonb(a) ->> 'faol')::boolean, true);
      if v_num2 is not null then
        v_txt := 'jadval';
      end if;
    end if;

    if v_txt is null then
      -- Aros manbasi umuman yo'q — 0 deb ko'rsatmaymiz, ochiq xato beramiz.
      raise exception 'Aros mijozlar qarzi manbasi yoq (aros_qarzdor_sync.summary ham, aros_qarzdor jadvali ham)';
    end if;

    -- Hamyon: mijoz hamyonidagi pul bizga allaqachon berilgan pul, umumiy
    -- qarzdan ayiriladi (Asilbek 2026-09-08). cashback hamyon emas — ayirilmaydi.
    v_q2a_uzs := coalesce(v_num, 0) + v_num2 - coalesce(v_bola_uzs, 0);

    v_q2a_rows := v_q2a_rows
      || jsonb_build_object('bolim', 'Q2a', 'ref', 'provodka', 'nom', 'Provodka qarz (bizdan qarzdor)',
           'uzs', v_num, 'usd', null, 'soni', null, 'hisobga', true, 'meta', '{}'::jsonb)
      || jsonb_build_object('bolim', 'Q2a', 'ref', 'aros', 'nom', 'Aros mijozlar qarzi (umumiy)',
           'uzs', v_num2, 'usd', null, 'soni', null, 'hisobga', true,
           'meta', jsonb_build_object('manba', v_txt))
      || jsonb_build_object('bolim', 'Q2a', 'ref', 'aros_hamyon', 'nom', 'Aros mijozlar hamyoni (bizga berilgan pul) — ayiriladi',
           'uzs', -coalesce(v_bola_uzs, 0), 'usd', null, 'soni', null, 'hisobga', true,
           'meta', jsonb_build_object('hamyon', true, 'manba', v_txt));

    v_bolimlar := v_bolimlar || jsonb_build_object('Q2a',
      jsonb_build_object('uzs', v_q2a_uzs, 'usd', null, 'soni', 3, 'manba', v_txt));
    v_qatorlar := v_qatorlar || v_q2a_rows;
  exception when others then
    v_q2a_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('Q2a', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'Q2a: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [Q2b] Biz qarzdormiz — Qarz sahifasi bilan YAGONA manba: biz_qarz_hisob (2026-11-20, Asilbek)
  --       Q2b = jami qarz (posted + yo'lda + boshlang'ich) - yetkazuvchi avansi; ichki yetkazuvchilar
  --       jamiga kirmaydi (alohida «ichki» qatori, hisobga=false)
  -- =====================================================================
  begin
    v_q2b_rows := '[]'::jsonb; v_q2b_uzs := 0; v_q2b_soni := 0;

    if coalesce(v_manba ->> 'incomes', '') = 'xato' then
      v_q2b_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('Q2b', null);
      v_toliq := false;
      v_xatolar := array_append(v_xatolar, 'Q2b: manba.incomes=xato — otkazib yuborildi');
    else
      -- payloadda yo'ldagi (on_way) hujjat bo'lmasa ham Qarz sahifasi bilan bir xil chiqsin: kesh (aros_yuk_snapshot)
      -- dagi, 365 kun ichidagi yo'ldagilar payloadda yo'q id bo'yicha qo'shiladi.
      v_q2b_in := v_yuklar;
      if to_regclass('public.aros_yuk_snapshot') is not null then
        v_q2b_in := v_q2b_in || coalesce((
          select jsonb_agg(jsonb_build_object(
                   'id', s.yuk_id, 'yetkazuvchi', s.yetkazuvchi, 'ombor', s.ombor, 'narx', s.narx,
                   'valyuta', s.valyuta, 'status', s.status, 'delivery_status', s.delivery_status))
            from aros_yuk_snapshot s
           where s.mavjud = true
             and coalesce(s.status, '') not in ('posted', 'canceled')
             and s.delivery_status = 'on_way'
             and s.sana >= v_sana - 365
             and not exists (select 1 from jsonb_array_elements(v_yuklar) x where x ->> 'id' = s.yuk_id::text)
        ), '[]'::jsonb);
      end if;

      if not _aylanma_fn_bor('biz_qarz_hisob', 'jsonb, numeric') then
        raise exception 'biz_qarz_hisob(jsonb, numeric) yoq — PROVODKA_BIZ_QARZ_YAGONA_20261120.sql 2-BOLIM';
      end if;
      v_biz := biz_qarz_hisob(v_q2b_in, v_kurs_usd);
      if coalesce((v_biz ->> 'ok')::boolean, false) is not true then
        raise exception 'biz_qarz_hisob: %', coalesce(v_biz ->> 'kod', 'xato');
      end if;

      for v_el in select * from jsonb_array_elements(v_biz -> 'qatorlar') loop
        v_q2b_soni := v_q2b_soni + 1;
        v_q2b_rows := v_q2b_rows || jsonb_build_object(
          'bolim', 'Q2b', 'ref', v_el ->> 'ref', 'nom', v_el ->> 'nom',
          'uzs', nullif(v_el ->> 'uzs', '')::numeric, 'usd', null,
          'soni', null, 'hisobga', true,
          'meta', case when (v_el ->> 'kurs_yoq')::boolean
                       then jsonb_build_object('kurs_yoq', true, 'valyuta', v_el ->> 'valyuta')
                       else '{}'::jsonb end
                  || case when (v_el ->> 'yolda')::boolean then jsonb_build_object('yolda', true) else '{}'::jsonb end);
      end loop;

      if coalesce((v_biz ->> 'avans_uzs')::numeric, 0) > 0 then
        v_q2b_rows := v_q2b_rows || jsonb_build_object(
          'bolim', 'Q2b', 'ref', 'avans', 'nom', 'Yetkazuvchilarga berilgan avans (qarzdan ayiriladi)',
          'uzs', -(v_biz ->> 'avans_uzs')::numeric, 'usd', null, 'soni', null, 'hisobga', true,
          'meta', jsonb_build_object('avans', true));
      end if;

      if coalesce((v_biz -> 'ichki' ->> 'soni')::int, 0) > 0 then
        v_q2b_rows := v_q2b_rows || jsonb_build_object(
          'bolim', 'Q2b', 'ref', 'ichki',
          'nom', 'Ichki hujjatlar: ' || (v_biz -> 'ichki' ->> 'soni') || ' ta (jamiga KIRMAYDI)',
          'uzs', (v_biz -> 'ichki' ->> 'uzs')::numeric, 'usd', null,
          'soni', (v_biz -> 'ichki' ->> 'soni')::numeric, 'hisobga', false,
          'meta', jsonb_build_object('ichki', true, 'nomlar', v_biz -> 'ichki' -> 'nomlar'));
      end if;

      v_q2b_uzs := coalesce((v_biz ->> 'jami_uzs')::numeric, 0) - coalesce((v_biz ->> 'avans_uzs')::numeric, 0);

      if v_biz -> 'kurs_yoq' <> '{}'::jsonb then
        v_toliq := false;
        for v_curkey, v_curcnt in select key, value::numeric from jsonb_each_text(v_biz -> 'kurs_yoq') loop
          v_xatolar := array_append(v_xatolar,
            'Q2b: ' || coalesce(v_curkey, '?') || ' kursi yo''q (' || v_curcnt::int || ' yuk)');
        end loop;
      end if;

      v_bolimlar := v_bolimlar || jsonb_build_object('Q2b',
        jsonb_build_object('uzs', v_q2b_uzs, 'usd', null, 'soni', v_q2b_soni,
          'jami_uzs', (v_biz ->> 'jami_uzs')::numeric, 'avans_uzs', (v_biz ->> 'avans_uzs')::numeric,
          'yolda_uzs', (v_biz ->> 'yolda_uzs')::numeric,
          'ichki_soni', (v_biz -> 'ichki' ->> 'soni')::int, 'ichki_uzs', (v_biz -> 'ichki' ->> 'uzs')::numeric,
          'manba', 'biz_qarz_hisob'));
      v_qatorlar := v_qatorlar || v_q2b_rows;
    end if;
  exception when others then
    v_q2b_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('Q2b', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'Q2b: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [D] Daftar 4010/6010 — QO'SHIMCHA MA'LUMOT, jamiga KIRMAYDI
  -- =====================================================================
  begin
    v_d_rows := '[]'::jsonb;

    if to_regclass('public.v_hisob_qoldiq') is not null then
      for v_ref, v_nom, v_num in
        select h.code, h.code || ' daftar qoldigi', coalesce(h.qoldiq, 0)::numeric
          from v_hisob_qoldiq h
         where h.code in ('4010', '6010')
      loop
        v_d_rows := v_d_rows || jsonb_build_object(
          'bolim', 'D', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', null,
          'soni', null, 'hisobga', false, 'meta', '{}'::jsonb);
      end loop;
    end if;

    v_bolimlar := v_bolimlar || jsonb_build_object('D',
      jsonb_build_object('uzs', null, 'usd', null, 'soni', jsonb_array_length(v_d_rows)));
    v_qatorlar := v_qatorlar || v_d_rows;
  exception when others then
    -- D jamiga kirmaydi — toliq bu sabab bilan false qilinmaydi, faqat qayd etiladi.
    v_bolimlar := v_bolimlar || jsonb_build_object('D', null);
    v_xatolar := array_append(v_xatolar, 'D: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- JAMI: SAK = A+H+B+T1+T5+Y3a+K3b+K4+B6+Q2a − Q2b  (null = 0)   -- H qo'shildi 2026-10-28
  -- =====================================================================
  v_jami_uzs := coalesce(v_a_uzs, 0) + coalesce(v_h_uzs, 0) + coalesce(v_b_uzs, 0) + coalesce(v_t1_uzs, 0)
    + coalesce(v_t5_uzs, 0) + coalesce(v_y3a_uzs, 0) + coalesce(v_k3b_uzs, 0)
    + coalesce(v_k4_uzs, 0) + coalesce(v_b6_uzs, 0) + coalesce(v_q2a_uzs, 0)
    - coalesce(v_q2b_uzs, 0);
  -- USD: jami va usd'si bo'sh bo'limlar so'mdan kurs bilan (2026-09-08 tuzatish —
  -- avval jami_usd faqat A+B yig'indisi edi: 11,98 mlrd so'mga $199 ming chiqardi).
  if coalesce(v_kurs_usd, 0) > 0 then
    v_jami_usd := round(v_jami_uzs / v_kurs_usd, 2);
    for v_ref, v_el in select key, value from jsonb_each(v_bolimlar) loop
      if v_el is not null and jsonb_typeof(v_el) = 'object'
         and (v_el ->> 'usd') is null and (v_el ->> 'uzs') is not null then
        v_bolimlar := jsonb_set(v_bolimlar, array[v_ref, 'usd'],
                        to_jsonb(round((v_el ->> 'uzs')::numeric / v_kurs_usd, 2)));
      end if;
    end loop;
  else
    v_jami_usd := null;
  end if;

  -- ---- yozish: HAR KUN UCHUN BITTA QATOR (2026-09-09, Asilbek: «2 snapshot
  -- bo'p qoldi, faqat 1 ta kerak — eng oxirgi»). Rejimdan QAT'I NAZAR o'sha
  -- kunning eski qatori o'chiriladi (cascade `aylanma_qator` ni ham oladi).
  --   ESKI xatti-harakat: faqat 'cron' o'chirilardi, 'qolda' esa HAR DOIM
  --   yangi qator qo'shardi — qo'lda ikki marta ishga tushirilsa bir kunda
  --   ikki snapshot qolardi va sahifadagi ro'yxat select'i ikkalasini
  --   ko'rsatardi.
  --   OQIBAT: qo'lda hisob o'sha kunning cron qatorini ham almashtiradi —
  --   ONGLI, chunki oxirgi hisob eng to'g'risi. Tarix kun kesimida saqlanadi.
  -- 2026-10-17: profit-summary yig'indi tekshiruvi (omborlar jami <> umumiy javob >1%) — banner (toliq o'zgarmaydi)
  if jsonb_typeof(p_data -> 'profit_ogoh') = 'array' then
    v_xatolar := v_xatolar || array(select left(x, 200) from jsonb_array_elements_text(p_data -> 'profit_ogoh') x limit 10);
  end if;

  delete from aylanma_snapshot where sana = v_sana;

  insert into aylanma_snapshot (
    sana, rejim, hisoblangan_at, kurs_usd, jami_uzs, jami_usd, toliq, bolimlar, manba_holati, xatolar)
  values (
    v_sana, v_rejim, now(), v_kurs_usd, v_jami_uzs, v_jami_usd, v_toliq, v_bolimlar, v_manba, v_xatolar)
  returning id into v_snapshot_id;

  if jsonb_array_length(v_qatorlar) > 0 then
    insert into aylanma_qator (snapshot_id, bolim, ref, nom, usd, uzs, soni, hisobga, meta)
    select v_snapshot_id,
           q ->> 'bolim', q ->> 'ref', q ->> 'nom',
           nullif(q ->> 'usd', '')::numeric, nullif(q ->> 'uzs', '')::numeric,
           nullif(q ->> 'soni', '')::numeric, coalesce((q ->> 'hisobga')::boolean, true),
           coalesce(q -> 'meta', '{}'::jsonb)
      from jsonb_array_elements(v_qatorlar) q;
  end if;

  return jsonb_build_object(
    'ok', true, 'id', v_snapshot_id, 'sana', v_sana, 'rejim', v_rejim,
    'jami_uzs', v_jami_uzs, 'jami_usd', v_jami_usd, 'toliq', v_toliq,
    'bolimlar', v_bolimlar, 'xatolar', to_jsonb(v_xatolar));
end
$ayl_sync$;
revoke all on function sync_aylanma_snapshot(jsonb) from public, anon, authenticated;
grant execute on function sync_aylanma_snapshot(jsonb) to service_role;
comment on function sync_aylanma_snapshot(jsonb) is
  'service_role ONLY (n8n «Aros Provodka - Aylanma Snapshot»). Har bo''lim ALOHIDA exception '
  'blokida. PUL HARAKATI YO''Q. Q2a qarz va hamyon AYNI manbadan (Q2A_FIX); HAR KUN UCHUN BITTA qator (BIR_KUN); '
  'tovar/brak manbai Aros profit-summary (PROFIT_API). '
  'YANGI (PROVODKA_AYLANMA_HODIM_KASSA.sql, 2026-10-28): [H] hodim kassalari (5400 ostidagi barcha 54xx, '
  'aylanma_hodim_kassa) — SAK = A+H+B+T1+T5+Y3a+K3b+K4+B6+Q2a−Q2b. '
  'YANGI (PROVODKA_BIZ_QARZ_YAGONA_20261120.sql): Q2b = biz_qarz_hisob (Qarz sahifasi bilan yagona manba).';


-- #####################################################################
-- ##  TEKSHIRUV (faqat select; SQL editor'da auth.uid null — ruxsat tekshiruvisiz ishlaydi)
-- #####################################################################
-- Eslatma: p_yuklar ni sahifa/n8n beradi; quyidagi — faqat boshlang'ich qarz (yuk_qolda) + ichki ro'yxat tekshiruvi.
-- select biz_qarz_hisob('[]'::jsonb) - 'qatorlar' - 'ichki_nomlar';
-- select nom from yuk_ichki_yetkazuvchi order by nom;
-- Aros'da shunga o'xshash ichki nomlar bormi (ko'rib chiqing, kerak bo'lsa yuk_ichki_yetkazuvchi ga qo'shing):
-- select yetkazuvchi, count(*), sum(narx) from aros_yuk_snapshot where mavjud group by 1 order by 2 desc limit 60;
-- Oxirgi snapshot Q2b:  select bolimlar -> 'Q2b' from aylanma_snapshot order by sana desc limit 1;

notify pgrst, 'reload schema';
