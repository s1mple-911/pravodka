-- =====================================================================
-- PROVODKA_YUK_BOGLANMAGAN_V2.sql
-- Bog'lanmagan (yo'ldagi) to'lovlar v2 — xizmat turi (yuk_sabab_id) + ko'p
-- tanlab bittada bog'lash (yuk_boglash_koplik). BRIEF_YUK_BOGLANMAGAN_V2.md.
-- ---------------------------------------------------------------------
-- Project: Provodka (kxzerccdpcltmzrxutlo). ADDITIVE — mavjud
-- yuk_boglash(uuid,integer,numeric) va yuk_kutayotgan() TEGILMAYDI (eski
-- bitta-bitta yo'l saqlanadi — jurnal '.. teg modali ham shu bilan ishlayveradi,
-- professional-dev.html dagi "1 ta" yuk tanlash oqimi ham tegilmagan).
--
-- Old shart: PROVODKA_V7.sql (entry.yuk_kutilmoqda, 9110-1, yuk_boglash,
-- yuk_kutayotgan), PROVODKA_YUK_QISMAN.sql (entry_yuk), PROVODKA_YUK_TANNARX.sql
-- (yuk_tannarx_sabab, yuk_tannarx, yuk_tannarx_qosh) — barchasi RUN qilingan
-- bo'lishi kerak (PROVODKA_YUK_BOJXONA.sql'dagi qayta e'lon ENG OXIRGISI).
--
-- Tartib:
--   1-BO'LIM — entry.yuk_sabab_id ustuni
--   2-BO'LIM — entry_yuk_sabab_yoz(text, integer) — Professional kaskadi
--   3-BO'LIM — yuk_kutayotgan_v2() — sabab/status/ext_ref bilan kengaytirilgan ro'yxat
--   4-BO'LIM — yuk_boglash_koplik(uuid[], integer, numeric) — ko'p tanlab bog'lash
--   5-BO'LIM — PostgREST sxema keshi
--   6-BO'LIM — DIAG (faqat select, hech narsa yozmaydi)
--
-- Asilbek qo'lda RUN qiladi.
-- =====================================================================


-- #####################################################################
-- ##  1-BO'LIM — entry.yuk_sabab_id                                  ##
-- #####################################################################
-- Yo'ldagi to'lov (yuk_kutilmoqda=true) uchun ixtiyoriy xizmat turi. NULL —
-- tovar narxi (hujjat) uchun to'lov, avvalgidek. Sabab bor bo'lsa bog'langanda
-- (4-BO'LIM) yuk_tannarx qatoriga ham qo'shiladi.

alter table entry add column if not exists yuk_sabab_id integer references yuk_tannarx_sabab(id);

comment on column entry.yuk_sabab_id is
  'Yo''ldagi to''lov (yuk_kutilmoqda) uchun xizmat turi (yol puli/bojxona...). '
  'NULL = tovar narxi (hujjat) uchun to''lov. Bog''langanda (yuk_boglash_koplik) '
  'sabab bor bo''lsa yuk_tannarx qatoriga ham qo''shiladi.';


-- #####################################################################
-- ##  2-BO'LIM — entry_yuk_sabab_yoz(text, integer)                  ##
-- #####################################################################
-- entry_jadval_yoz / entry_ehson_pul_turi_yoz naqshi (PROVODKA_JADVAL.sql
-- 4-BO'LIM, PROVODKA_EHSON_ZAKOT.sql 2.9-BO'LIM — ENG OXIRGI nusxa): Professional
-- "yo'ldagi tovar" saqlashdan KEYIN, ext_ref bo'yicha, egalik created_by=auth.uid()
-- (turi bazada aniqlanmagan — regex bilan cast), 30 daqiqa ichida, bir marta
-- (yuk_sabab_id hali null), faqat yuk_kutilmoqda=true yozuvda.

create or replace function entry_yuk_sabab_yoz(p_ext_ref text, p_sabab_id integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid            uuid := auth.uid();
  v_ext            text := nullif(btrim(coalesce(p_ext_ref, '')), '');
  v_id             uuid;
  v_created_at     timestamptz;
  v_kutil          boolean;
  v_sabab_old      integer;
  v_created_by_raw text;
  v_owner          uuid;
  v_sabab          yuk_tannarx_sabab;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if v_ext is null then
    return jsonb_build_object('ok', false, 'kod', 'ext_ref_kerak');
  end if;
  if p_sabab_id is null then
    return jsonb_build_object('ok', false, 'kod', 'sabab_notogri');
  end if;

  select e.id, e.created_at, coalesce(e.yuk_kutilmoqda, false), e.yuk_sabab_id,
         (to_jsonb(e) ->> 'created_by')
    into v_id, v_created_at, v_kutil, v_sabab_old, v_created_by_raw
    from entry e
   where e.ext_ref = v_ext
   limit 1;

  if v_id is null then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi');
  end if;

  -- 🔴 `created_by` turi bazada aniqlanmagan (entry_jadval_yoz naqshi) —
  --    `::uuid` cast FAQAT to'liq uuid shaklida bajariladi.
  v_owner := case when v_created_by_raw ~ '^[0-9a-fA-F-]{36}$' then v_created_by_raw::uuid end;
  if v_owner is distinct from v_uid then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat_yoq');
  end if;
  if v_created_at is null or v_created_at < now() - interval '30 minutes' then
    return jsonb_build_object('ok', false, 'kod', 'muddat_tugagan');
  end if;
  if not v_kutil then
    return jsonb_build_object('ok', false, 'kod', 'yolda_emas');
  end if;
  if v_sabab_old is not null then
    return jsonb_build_object('ok', false, 'kod', 'allaqachon');
  end if;

  select * into v_sabab from yuk_tannarx_sabab where id = p_sabab_id;
  if v_sabab.id is null or not v_sabab.is_active then
    return jsonb_build_object('ok', false, 'kod', 'sabab_notogri');
  end if;

  update entry set yuk_sabab_id = p_sabab_id where id = v_id;

  return jsonb_build_object('ok', true);
end
$fn$;

revoke all on function entry_yuk_sabab_yoz(text, integer) from public, anon;
grant execute on function entry_yuk_sabab_yoz(text, integer) to authenticated;

comment on function entry_yuk_sabab_yoz(text, integer) is
  'Professional "yo''ldagi tovar" saqlashdan keyin xizmat turini (yuk_tannarx_sabab) yozadi. '
  'entry_jadval_yoz naqshi: egalik created_by=auth.uid(), 30 daqiqa, bir marta, '
  'faqat yuk_kutilmoqda=true yozuvda (yuk_sabab_id hali null bo''lsa).';


-- #####################################################################
-- ##  3-BO'LIM — yuk_kutayotgan_v2() — kengaytirilgan ro'yxat        ##
-- #####################################################################
-- yuk_kutayotgan() (PROVODKA_V7.sql 1.4) bilan AYNAN bir xil asosiy tanlov
-- va filtr (yuk_kutilmoqda=true, is_deleted=false, status='posted'), ustiga
-- sabab/status/ext_ref/description qo'shilgan. Ruxsat — V7 dagi kabi hech
-- qanday qo'shimcha sahifa cheklovi yo'q (har authenticated — imzo eskisi
-- bilan bir xil xatti-harakat, faqat qaytish shakli boshqacha: jsonb obyekt
-- {ok, rows, jami_summa, soni}, eski funksiya esa to'g'ridan massiv qaytaradi).

create or replace function yuk_kutayotgan_v2()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select jsonb_build_object(
           'ok',         true,
           'soni',       coalesce(count(*), 0),
           'jami_summa', coalesce(sum(r.summa), 0),
           'rows',       coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb))
    from (
      select e.id as entry_id, e.ext_ref, e.entry_date, e.created_at, e.status,
             e.description as izoh, e.description,
             (select coalesce(sum(el.debit), 0) from entry_line el where el.entry_id = e.id) as summa,
             ka.id as kassa_id, ka.code as kassa_code, ka.name as kassa_name, ka.subtitle as kassa_subtitle,
             coalesce(pr.full_name, '') as kim,
             e.yuk_sabab_id as sabab_id, s.nom as sabab_nom, s.ikonka as sabab_ikonka
        from entry e
        left join lateral (
          select el.account_id from entry_line el
            join accounts a on a.id = el.account_id
           where el.entry_id = e.id and el.credit > 0 and a.section = 'pul'
           limit 1
        ) kl on true
        left join accounts ka on ka.id = kl.account_id
        left join profiles pr on pr.id = e.created_by
        left join yuk_tannarx_sabab s on s.id = e.yuk_sabab_id
       where e.yuk_kutilmoqda = true and e.is_deleted = false and e.status = 'posted'
    ) r;
$fn$;

revoke all on function yuk_kutayotgan_v2() from public, anon;
grant execute on function yuk_kutayotgan_v2() to authenticated;

comment on function yuk_kutayotgan_v2() is
  'yuk_kutayotgan() bilan bir xil tanlov + sabab_id/sabab_nom/sabab_ikonka/status/ext_ref/description. '
  'Qaytishi: {ok:true, rows:[...], jami_summa, soni}. Eski yuk_kutayotgan() TEGILMAGAN.';


-- #####################################################################
-- ##  4-BO'LIM — yuk_boglash_koplik(uuid[], integer, numeric)        ##
-- #####################################################################
-- Bir nechta bog'lanmagan to'lovni BITTADA bitta yukka bog'laydi. Har entry
-- uchun yuk_boglash() (PROVODKA_V7.sql 1.3) bilan AYNAN bir xil tekshiruv va
-- yozish (entry_yuk upsert, Dt 9110-1->9110, yuk_kutilmoqda=false, yuk_ids,
-- entry_history). Sabab (yuk_sabab_id) bor entry'lar uchun QO'SHIMCHA
-- yuk_tannarx_qosh(...) chaqiriladi (bitta entry — bitta chaqiruv, kalit
-- 'entry:'||entry_id — idempotent, bojxona limiti ham shu orqali tekshiriladi).
--
-- ATOMIK: butun funksiya bitta ichki BEGIN/EXCEPTION bloki ichida — istalgan
-- bosqichda xato (tekshiruv, qoldiq, yuk_tannarx_qosh limit/ruxsat) chiqsa
-- SHU BLOKDAGI hamma yozuv (entry_yuk/entry_line/entry/entry_history/yuk_tannarx)
-- savepoint bilan bekor qilinadi va tuzilgan {ok:false,...} qaytadi — plpgsql
-- mahalliy o'zgaruvchilar (v_err) rollback'dan TA'SIRLANMAYDI, shuning uchun
-- xato tafsilotini yo'qotmasdan qaytarish mumkin.
--
-- Tovar qoldig'i (server narxni bilmaydi — V7 1.3 dagi izoh naqshi): faqat
-- klientdan kelgan p_qoldiq_uzs bilan tekshiriladi (null bo'lsa tekshirilmaydi).
-- Xizmat (sabab bor) to'lovlar bu tekshiruvga kirmaydi — ular tannarxga
-- qo'shiladi, o'z limiti (Aros bojxona) yuk_tannarx_qosh ichida alohida.

create or replace function yuk_boglash_koplik(p_entries uuid[], p_yuk_id integer,
                                              p_qoldiq_uzs numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_who        text;
  v_entries    uuid[];
  v_n          int;
  v_entry_id   uuid;
  v_deleted    boolean;
  v_kutil      boolean;
  v_sabab      integer;
  v_desc       text;
  v_entry_sum  numeric;
  v_9110       uuid;
  v_9110_1     uuid;
  v_line_id    uuid;
  v_snap       jsonb;
  v_tovar_uzs  numeric := 0;
  v_xizmat_uzs numeric := 0;
  v_boglandi   int := 0;
  v_tan_rows   jsonb := '[]'::jsonb;
  v_boj_res    jsonb;
  v_err        jsonb := null;
begin
  if p_yuk_id is null then
    return jsonb_build_object('ok', false, 'kod', 'yuk_yoq', 'error', 'Yuk tanlanmadi');
  end if;

  -- Takrorlarni va nullarni tashlab, deduplikatsiya (bir entry ikki marta hisoblanmasin)
  select array_agg(x) into v_entries from (select distinct x from unnest(p_entries) x where x is not null) t;
  if v_entries is null or array_length(v_entries, 1) is null or array_length(v_entries, 1) = 0 then
    return jsonb_build_object('ok', false, 'kod', 'bosh', 'error', 'Birorta to''lov tanlanmagan');
  end if;
  v_n := array_length(v_entries, 1);
  if v_n > 300 then
    return jsonb_build_object('ok', false, 'kod', 'kop', 'error', 'Bir marta eng ko''pi 300 ta to''lov');
  end if;

  select id into v_9110_1 from accounts where code = '9110-1' limit 1;
  select id into v_9110   from accounts where code = '9110'   limit 1;
  if v_9110 is null or v_9110_1 is null then
    return jsonb_build_object('ok', false, 'kod', 'hisob_yoq', 'error', '9110/9110-1 hisoblari topilmadi');
  end if;

  select coalesce(full_name, '') into v_who from profiles where id = auth.uid();

  -- Poyga himoyasi (yuk_tannarx_qosh 1.5-BOSQICH bilan bir xil naqsh) —
  -- ikki parallel chaqiruv bir yukka bir vaqtda kelsa ustma-ust tushmasin.
  perform pg_advisory_xact_lock(hashtext('yuk_boglash_koplik'));

  begin  -- ichki blok: xato bo'lsa SHU BLOKDAGI hamma yozuv bekor (savepoint)

    -- 1-BOSQICH: tekshiruv + tovar/xizmat summasi (yozishdan OLDIN)
    foreach v_entry_id in array v_entries loop
      select is_deleted, coalesce(yuk_kutilmoqda, false), yuk_sabab_id
        into v_deleted, v_kutil, v_sabab
        from entry where id = v_entry_id;
      if not found then
        v_err := jsonb_build_object('ok', false, 'kod', 'topilmadi',
                                     'error', 'Yozuv topilmadi', 'entry_id', v_entry_id);
        raise exception 'yuk_boglash_koplik: topilmadi';
      end if;
      if v_deleted then
        v_err := jsonb_build_object('ok', false, 'kod', 'ochirilgan',
                                     'error', 'O''chirilgan yozuvni bog''lab bo''lmaydi', 'entry_id', v_entry_id);
        raise exception 'yuk_boglash_koplik: ochirilgan';
      end if;
      if not v_kutil then
        v_err := jsonb_build_object('ok', false, 'kod', 'yolda_emas',
                                     'error', 'Bu yozuv hujjat kutmayapti (allaqachon bog''langan yoki oddiy yozuv)',
                                     'entry_id', v_entry_id);
        raise exception 'yuk_boglash_koplik: yolda_emas';
      end if;

      select coalesce(sum(debit), 0) into v_entry_sum from entry_line where entry_id = v_entry_id;

      select id into v_line_id from entry_line
       where entry_id = v_entry_id and account_id = v_9110_1 and debit > 0
       limit 1;
      if v_line_id is null then
        v_err := jsonb_build_object('ok', false, 'kod', 'satr_yoq',
                                     'error', 'Bu yozuvda "yo''ldagi tovar" (9110-1) satri yo''q', 'entry_id', v_entry_id);
        raise exception 'yuk_boglash_koplik: satr_yoq';
      end if;

      if v_sabab is null then
        v_tovar_uzs := v_tovar_uzs + v_entry_sum;
      else
        v_xizmat_uzs := v_xizmat_uzs + v_entry_sum;
      end if;
    end loop;

    -- Tovar qismi yuk qoldig'idan oshmasin (klientdan kelgan qiymat bilan — server narxni bilmaydi)
    if p_qoldiq_uzs is not null and v_tovar_uzs > p_qoldiq_uzs then
      v_err := jsonb_build_object('ok', false, 'kod', 'qoldiq',
                                   'error', 'Tovar to''lovlari yuk qoldig''idan oshib ketdi',
                                   'tovar_uzs', v_tovar_uzs, 'qoldiq_uzs', p_qoldiq_uzs);
      raise exception 'yuk_boglash_koplik: qoldiq';
    end if;

    -- 2-BOSQICH: yozish (har entry uchun — entry_yuk/Dt satr/entry/entry_history,
    -- sabab bor bo'lsa qo'shimcha yuk_tannarx_qosh)
    foreach v_entry_id in array v_entries loop
      select yuk_sabab_id into v_sabab from entry where id = v_entry_id;
      select coalesce(sum(debit), 0) into v_entry_sum from entry_line where entry_id = v_entry_id;
      select id into v_line_id from entry_line
       where entry_id = v_entry_id and account_id = v_9110_1 and debit > 0
       limit 1;
      select description into v_desc from entry where id = v_entry_id;
      select to_jsonb(e) into v_snap from entry e where e.id = v_entry_id;

      insert into entry_yuk (entry_id, yuk_id, summa_uzs)
      values (v_entry_id, p_yuk_id, v_entry_sum)
      on conflict (entry_id, yuk_id) do update
        set summa_uzs = entry_yuk.summa_uzs + excluded.summa_uzs;

      update entry_line set account_id = v_9110 where id = v_line_id;

      update entry
         set yuk_kutilmoqda = false,
             yuk_ids = case when p_yuk_id = any(coalesce(yuk_ids, '{}'))
                            then yuk_ids else coalesce(yuk_ids, '{}') || p_yuk_id end,
             edited_at = now(),
             edited_by_name = v_who
       where id = v_entry_id;

      insert into entry_history (entry_id, action, snapshot, changed_by_name)
      values (v_entry_id, 'edit',
              jsonb_build_object('note', 'Yukka bog''landi (ko''plik): #' || p_yuk_id,
                                 'summa_uzs', v_entry_sum, 'old', v_snap),
              v_who);

      v_boglandi := v_boglandi + 1;

      if v_sabab is not null then
        v_boj_res := yuk_tannarx_qosh(
          jsonb_build_array(jsonb_build_object('yuk_id', p_yuk_id, 'summa', v_entry_sum)),
          v_sabab, v_desc, 'entry:' || v_entry_id::text);
        if coalesce((v_boj_res ->> 'ok')::boolean, false) is not true then
          if v_boj_res ? 'kod' then
            v_err := v_boj_res;
          elsif position('ruxsat' in coalesce(v_boj_res ->> 'error', '')) > 0 then
            v_err := v_boj_res || jsonb_build_object('kod', 'tannarx_ruxsat');
          else
            v_err := v_boj_res || jsonb_build_object('kod', 'tannarx_xato');
          end if;
          raise exception 'yuk_boglash_koplik: tannarx';
        end if;
        v_tan_rows := v_tan_rows || v_boj_res;
      end if;
    end loop;

  exception when others then
    if v_err is not null then
      return v_err;
    end if;
    return jsonb_build_object('ok', false, 'kod', 'xato', 'error', sqlerrm);
  end;

  return jsonb_build_object('ok', true, 'yuk_id', p_yuk_id, 'boglandi', v_boglandi,
    'tovar_uzs', v_tovar_uzs, 'xizmat_uzs', v_xizmat_uzs, 'tannarx_qatorlar', v_tan_rows);
end
$fn$;

revoke all on function yuk_boglash_koplik(uuid[], integer, numeric) from public, anon;
grant execute on function yuk_boglash_koplik(uuid[], integer, numeric) to authenticated;

comment on function yuk_boglash_koplik(uuid[], integer, numeric) is
  'Bir nechta bog''lanmagan to''lovni (yuk_kutilmoqda) BITTADA bitta yukka bog''laydi — har entry uchun '
  'yuk_boglash() bilan bir xil yozish + sabab bor bo''lsa yuk_tannarx_qosh(). Atomik (ichki savepoint): '
  'xato chiqsa hech narsa yozilmay qoladi. p_qoldiq_uzs — klientdan (server narxni bilmaydi), faqat tovar '
  'qismi shunga qarshi tekshiriladi; xizmat qismi cheklanmaydi (tannarxga qo''shiladi).';


-- #####################################################################
-- ##  5-BO'LIM — PostgREST sxema keshini yangilash                   ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  6-BO'LIM — DIAG.  HECH BIRI YOZMAYDI.                           ##
-- #####################################################################

-- 6.1 Obyektlar joyidami
select 'entry.yuk_sabab_id ustuni' as tekshiruv,
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'entry'
                            and column_name = 'yuk_sabab_id')
            then '✅ OK' else '❌ YO''Q' end as natija
union all
select 'entry_yuk_sabab_yoz(text,integer)',
       case when to_regprocedure('public.entry_yuk_sabab_yoz(text,integer)') is not null
            then '✅ OK' else '❌ YO''Q' end
union all
select 'yuk_kutayotgan_v2()',
       case when to_regprocedure('public.yuk_kutayotgan_v2()') is not null
            then '✅ OK' else '❌ YO''Q' end
union all
select 'yuk_boglash_koplik(uuid[],integer,numeric)',
       case when to_regprocedure('public.yuk_boglash_koplik(uuid[],integer,numeric)') is not null
            then '✅ OK' else '❌ YO''Q' end
union all
select 'eski yuk_boglash(uuid,integer,numeric) tegilmaganmi',
       case when to_regprocedure('public.yuk_boglash(uuid,integer,numeric)') is not null
            then '✅ OK — hali bor' else '❌ YO''QOLGAN (buzilgan)' end
union all
select 'eski yuk_kutayotgan() tegilmaganmi',
       case when to_regprocedure('public.yuk_kutayotgan()') is not null
            then '✅ OK — hali bor' else '❌ YO''QOLGAN (buzilgan)' end;

-- 6.2 Smoke test — bo'sh chaqiruv (yozmaydi)
select jsonb_pretty(yuk_kutayotgan_v2()) as bosh_royxat;

-- 6.3 Hozirgi bog'lanmagan to'lovlar soni + qanchasida sabab bor
select count(*) as yolda_soni,
       count(*) filter (where yuk_sabab_id is not null) as sababli_soni
  from entry
 where yuk_kutilmoqda = true and is_deleted = false and status = 'posted';

-- 6.4 🔴 PUL HARAKATI YO'QLIGI — bu fayl balansga tegmaganini tasdiqlaydi
--     (yuk_boglash_koplik faqat hisob almashtiradi 9110-1->9110, summa o'zgarmaydi).
select 'Balans tengligi' as tekshiruv,
       sum(case when bolim = 'AKTIV' then amount else 0 end)
     - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end) as farq,
       case when abs(sum(case when bolim = 'AKTIV' then amount else 0 end)
                   - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end)) <= 0.01
            then '✅ OK' else '❌ TEKSHIRING' end as natija
  from balans(current_date);
