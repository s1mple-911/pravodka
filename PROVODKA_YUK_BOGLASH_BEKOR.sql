-- =====================================================================
--  PROVODKA_YUK_BOGLASH_BEKOR.sql — yuk bog'lanishini BEKOR qilish
--  (Asilbek, 2026-09-14)
-- ---------------------------------------------------------------------
--  MUAMMO: to'lov Aros yukiga bog'langan (9110, entry_yuk), keyin o'sha
--  hujjat Aros adminkadan O'CHIRILDI. Pul chiqqan, lekin u endi mavjud
--  bo'lmagan hujjatga biriktirilgan holda qolib ketadi — «Bog'lanmagan
--  to'lovlar» tabida ham ko'rinmaydi, boshqa yukka ham bog'lab bo'lmaydi.
--
--  YECHIM: `yuk_boglash` (PROVODKA_V7.sql) ning TESKARISI. To'lov yana
--  «hujjat kutmoqda» holatiga qaytadi (9110-1, yuk_kutilmoqda=true) va
--  «Bog'lanmagan to'lovlar» tabida paydo bo'ladi — u yerdan boshqa yukka
--  bog'lanadi.
--
--  🔴 AVTOMATIK EMAS. Aros'dan o'chirish xato ham bo'lishi mumkin, buxgalteriya
--  yozuvi esa faqat ONGLI ravishda o'zgartiriladi — tugma Yuklar sahifasidagi
--  «Aros'dagi o'zgarishlar» panelida, tasdiq bilan.
--
--  #####  FAYL TARKIBI  ###################################################
--     0-BO'LIM — old shart tekshiruvi
--     1-BO'LIM — yuk_boglash_bekor(p_entry uuid, p_yuk_id integer)
--     2-BO'LIM — yuk_boglash_bekor_hammasi(p_yuk_id integer)
--     3-BO'LIM — yuk_tolovlari(p_yuk_id integer) — ro'yxat (faqat o'qish)
--     4-BO'LIM — YAKUNIY TEKSHIRUV
--
--  #####  QOIDALAR  #######################################################
--   * HECH NARSA o'chirilmaydi: entry_yuk qatori olib tashlanadi (u pul
--     yozuvi emas, bog'lanish jadvali), lekin `entry`/`entry_line` SAQLANADI
--     — faqat Dt satri 9110 -> 9110-1 ga qaytadi. Har amal `entry_history`
--     ga yoziladi (kim, qachon, nega).
--   * Yozuvda BIR NECHTA yuk bog'langan bo'lsa — rad etiladi (`kod:'kop_yuk'`):
--     bunda qaysi satr qaysi yukka tegishli ekani noaniq, qo'lda ko'rib
--     chiqilsin.
--   * `yuk_boglash_koplik` qo'shgan xizmat-tannarx qatori (kalit = 'entry:<id>')
--     ham bekor qilinadi (is_deleted=true) — aks holda yukda yo'q xarajat
--     qolib ketardi.
--   * Idempotent: allaqachon bog'lanmagan yozuv `{ok:true, holat:'allaqachon'}`.
--
--  🔴 SQL'ni ASILBEK RUN qiladi.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI                                 ##
-- #####################################################################

do $ybb_pre$
begin
  if to_regprocedure('public.yuk_boglash(uuid,integer,numeric)') is null then
    raise exception 'yuk_boglash() yoq — avval PROVODKA_V7.sql ni bajaring';
  end if;
  if to_regclass('public.entry_yuk') is null then
    raise exception 'entry_yuk jadvali yoq — avval PROVODKA_YUK_QISMAN.sql ni bajaring';
  end if;
  if to_regclass('public.yuk_tannarx') is null then
    raise exception 'yuk_tannarx jadvali yoq — avval PROVODKA_YUK_TANNARX.sql ni bajaring';
  end if;
  if not exists (select 1 from accounts where code = '9110-1') then
    raise exception '9110-1 "Yoldagi tovar" hisobi yoq — avval PROVODKA_V7.sql ni bajaring';
  end if;
end
$ybb_pre$;


-- #####################################################################
-- ##  1-BO'LIM — yuk_boglash_bekor(p_entry, p_yuk_id)                 ##
-- #####################################################################

create or replace function yuk_boglash_bekor(p_entry uuid, p_yuk_id integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $ybb$
declare
  v_deleted  boolean;
  v_kutil    boolean;
  v_9110     uuid;
  v_9110_1   uuid;
  v_line_id  uuid;
  v_n_yuk    int;
  v_name     text;
  v_snap     jsonb;
  v_summa    numeric;
  v_tan      int := 0;
begin
  if p_entry is null or p_yuk_id is null then
    return jsonb_build_object('ok', false, 'kod', 'argument');
  end if;

  select is_deleted, coalesce(yuk_kutilmoqda, false)
    into v_deleted, v_kutil
    from entry where id = p_entry;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'yozuv_yoq');
  end if;
  if v_deleted then
    return jsonb_build_object('ok', false, 'kod', 'ochirilgan');
  end if;

  select count(*) into v_n_yuk from entry_yuk where entry_id = p_entry;
  if v_n_yuk = 0 then
    -- allaqachon bog'lanmagan (yoki hech qachon bog'lanmagan)
    return jsonb_build_object('ok', true, 'holat', 'allaqachon', 'entry_id', p_entry);
  end if;
  if v_n_yuk > 1 then
    return jsonb_build_object('ok', false, 'kod', 'kop_yuk', 'soni', v_n_yuk, 'entry_id', p_entry);
  end if;

  select summa_uzs into v_summa from entry_yuk where entry_id = p_entry and yuk_id = p_yuk_id;
  if v_summa is null then
    return jsonb_build_object('ok', false, 'kod', 'boshqa_yuk', 'entry_id', p_entry);
  end if;

  select id into v_9110_1 from accounts where code = '9110-1' limit 1;
  select id into v_9110   from accounts where code = '9110'   limit 1;
  if v_9110 is null or v_9110_1 is null then
    return jsonb_build_object('ok', false, 'kod', 'hisob_yoq');
  end if;

  select id into v_line_id from entry_line
   where entry_id = p_entry and account_id = v_9110 and debit > 0
   limit 1;
  if v_line_id is null then
    return jsonb_build_object('ok', false, 'kod', 'satr_yoq', 'entry_id', p_entry);
  end if;

  select to_jsonb(e) into v_snap from entry e where e.id = p_entry;
  select coalesce(full_name, '') into v_name from profiles where id = auth.uid();

  -- 1) bog'lanish jadvalidan olib tashlanadi (pul yozuvi emas)
  delete from entry_yuk where entry_id = p_entry and yuk_id = p_yuk_id;

  -- 2) Dt satri 9110 -> 9110-1 (yo'ldagi tovarga qaytadi)
  update entry_line set account_id = v_9110_1 where id = v_line_id;

  -- 3) yozuv yana «hujjat kutmoqda» holatiga qaytadi
  update entry
     set yuk_kutilmoqda = true,
         yuk_ids = coalesce(array_remove(yuk_ids, p_yuk_id), '{}'),
         edited_at = now(),
         edited_by_name = v_name
   where id = p_entry;

  -- 4) shu to'lov qo'shgan xizmat-tannarx qatori (yuk_boglash_koplik naqshi)
  update yuk_tannarx
     set is_deleted = true,
         deleted_by_name = v_name,
         deleted_at = now()
   where yuk_id = p_yuk_id
     and kalit = 'entry:' || p_entry::text
     and is_deleted = false;
  get diagnostics v_tan = row_count;

  -- 5) tahrir izi
  insert into entry_history (entry_id, action, snapshot, changed_by_name)
  values (p_entry, 'edit',
          jsonb_build_object('note', 'Yuk bog''lanishi bekor qilindi: #' || p_yuk_id
                                     || ' (to''lov «Bog''lanmagan to''lovlar»ga qaytdi)',
                             'summa_uzs', v_summa,
                             'tannarx_bekor', v_tan,
                             'old', v_snap),
          v_name);

  return jsonb_build_object('ok', true, 'holat', 'bekor', 'entry_id', p_entry,
                            'yuk_id', p_yuk_id, 'summa_uzs', v_summa, 'tannarx_bekor', v_tan);
end
$ybb$;

revoke all on function yuk_boglash_bekor(uuid, integer) from public, anon;
grant execute on function yuk_boglash_bekor(uuid, integer) to authenticated;

comment on function yuk_boglash_bekor(uuid, integer) is
  'yuk_boglash teskarisi: entry_yuk olib tashlanadi, Dt 9110 -> 9110-1, yuk_kutilmoqda=true, '
  'yuk_ids dan chiqariladi, entry:<id> kalitli qoshimcha tannarx bekor qilinadi, entry_history ga yoziladi. '
  'Yozuvda bir nechta yuk bolsa rad etadi (kod: kop_yuk).';


-- #####################################################################
-- ##  2-BO'LIM — yuk_boglash_bekor_hammasi(p_yuk_id)                  ##
-- #####################################################################
-- Aros'dan o'chirilgan yukning HAMMA to'lovini bir zarbda qaytaradi.
-- Har biri alohida tekshiriladi; o'tmaganlari `otkazildi[]` da sababi bilan.

create or replace function yuk_boglash_bekor_hammasi(p_yuk_id integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $ybbh$
declare
  v_rec        record;
  v_res        jsonb;
  v_ok         int := 0;
  v_summa      numeric := 0;
  v_otkazildi  jsonb := '[]'::jsonb;
begin
  if p_yuk_id is null then
    return jsonb_build_object('ok', false, 'kod', 'argument');
  end if;

  perform pg_advisory_xact_lock(hashtext('yuk_boglash_bekor:' || p_yuk_id::text));

  for v_rec in
    select ey.entry_id
      from entry_yuk ey
      join entry e on e.id = ey.entry_id
     where ey.yuk_id = p_yuk_id
       and e.is_deleted = false
     order by ey.entry_id
  loop
    v_res := yuk_boglash_bekor(v_rec.entry_id, p_yuk_id);
    if coalesce((v_res ->> 'ok')::boolean, false) and (v_res ->> 'holat') = 'bekor' then
      v_ok := v_ok + 1;
      v_summa := v_summa + coalesce((v_res ->> 'summa_uzs')::numeric, 0);
    elsif (v_res ->> 'holat') is distinct from 'allaqachon' then
      v_otkazildi := v_otkazildi || jsonb_build_object(
        'entry_id', v_rec.entry_id, 'kod', coalesce(v_res ->> 'kod', 'nomalum'));
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'yuk_id', p_yuk_id,
                            'bekor', v_ok, 'summa_uzs', v_summa,
                            'otkazildi', v_otkazildi);
end
$ybbh$;

revoke all on function yuk_boglash_bekor_hammasi(integer) from public, anon;
grant execute on function yuk_boglash_bekor_hammasi(integer) to authenticated;

comment on function yuk_boglash_bekor_hammasi(integer) is
  'Yukning hamma bogliq tolovini «Boglanmagan tolovlar»ga qaytaradi (yuk_boglash_bekor har biriga). '
  'Otmaganlari otkazildi[] da sababi bilan qaytadi.';


-- #####################################################################
-- ##  3-BO'LIM — yuk_tolovlari(p_yuk_id) — faqat o'qish               ##
-- #####################################################################
-- Panelda «qaysi to'lovlar qaytariladi» ro'yxatini ko'rsatish uchun.

create or replace function yuk_tolovlari(p_yuk_id integer)
returns jsonb
language sql
stable
security definer
set search_path = public
as $ybt$
  select coalesce(jsonb_agg(jsonb_build_object(
           'entry_id', x.entry_id, 'entry_date', x.entry_date, 'summa_uzs', x.summa_uzs,
           'izoh', x.izoh, 'kassa', x.kassa, 'kim', x.kim,
           'kop_yuk', x.n_yuk > 1) order by x.entry_date, x.entry_id), '[]'::jsonb)
    from (
      select ey.entry_id, e.entry_date, ey.summa_uzs, e.description as izoh,
             coalesce(ka.name, '') as kassa,
             coalesce(pr.full_name, '') as kim,
             (select count(*) from entry_yuk e2 where e2.entry_id = ey.entry_id) as n_yuk
        from entry_yuk ey
        join entry e on e.id = ey.entry_id
        left join lateral (
          select el.account_id from entry_line el
            join accounts a on a.id = el.account_id
           where el.entry_id = e.id and el.credit > 0 and a.section = 'pul'
           limit 1
        ) kl on true
        left join accounts ka on ka.id = kl.account_id
        left join profiles pr on pr.id = e.created_by
       where ey.yuk_id = p_yuk_id
         and e.is_deleted = false
    ) x;
$ybt$;

revoke all on function yuk_tolovlari(integer) from public, anon;
grant execute on function yuk_tolovlari(integer) to authenticated;

comment on function yuk_tolovlari(integer) is
  'Yukka boglangan tolovlar royxati (faqat oqish) — «Arosdagi ozgarishlar» panelida korsatiladi.';

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  4-BO'LIM — YAKUNIY TEKSHIRUV                                     ##
-- #####################################################################

do $ybb_final$
begin
  if to_regprocedure('public.yuk_boglash_bekor(uuid,integer)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_boglash_bekor(uuid,integer) yaralmadi';
  end if;
  if to_regprocedure('public.yuk_boglash_bekor_hammasi(integer)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_boglash_bekor_hammasi(integer) yaralmadi';
  end if;
  if to_regprocedure('public.yuk_tolovlari(integer)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_tolovlari(integer) yaralmadi';
  end if;

  raise notice 'PROVODKA_YUK_BOGLASH_BEKOR.sql: tayyor — Arosda ochirilgan yukning tolovini qaytarish mumkin';
end
$ybb_final$;

-- Tekshirish (ixtiyoriy):
-- select yuk_tolovlari(1234);
-- select yuk_boglash_bekor_hammasi(1234);
