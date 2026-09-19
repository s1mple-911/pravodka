-- ============================================================================
--  PROVODKA_YUK_QOLDA.sql — 2026-09-19 — BOSHLANG'ICH (qo'lda) QARZ HUJJATI
--  Aros'da hujjati bo'lmagan yetkazuvchi qarzi (eski qarz, Aros'da yo'q yetkazuvchi) Provodka'da
--  oddiy yuk hujjati kabi yuritiladi: yuk_id ≥ 9 000 001 (Aros id'lari bilan to'qnashmaydi), shu id
--  bilan entry_yuk (to'lov), yuk_tannarx, yuk_deadline, yuk_tolov_grafik, yuk_grafik_guruh_yuk, yuk_yopiq
--  O'ZGARISHSIZ ishlaydi (Provodka'da yuk jadvali yo'q — hech qaysi RPC id'ni Aros'ga qarshi tekshirmaydi).
--  Sahifalar (yuklar/qarzdor/5 kunlik) n8n ro'yxatiga yuk_qolda_royxat() qatorlarini qo'shadi.
--  Additive. Asilbek RUN qiladi. 3-BO'LIM — Asilbek ro'yxati (19.09.2026) bo'yicha 23 hujjat (kalit bilan, takror xavfsiz).
-- ============================================================================

-- ---------------------------------------------------------------- 1) jadval
create sequence if not exists yuk_qolda_id_seq start 9001000;
create table if not exists yuk_qolda (
  id           integer     primary key default nextval('yuk_qolda_id_seq'),
  kalit        text        unique,
  yetkazuvchi  text        not null,
  narx         numeric     not null check (narx > 0),
  valyuta      text        not null default 'UZS',
  sana         date        not null default (now() at time zone 'Asia/Tashkent')::date,
  turi         text        not null default 'boshlangich',   -- eski | hujjat_yoq | aros_yoq | boshlangich
  izoh         text,
  created_by   uuid        default auth.uid(),
  created_by_name text,
  created_at   timestamptz not null default now(),
  is_deleted   boolean     not null default false,
  deleted_at   timestamptz,
  deleted_by   uuid
);
do $yq_chk$ begin
  if not exists (select 1 from pg_constraint where conname = 'yuk_qolda_id_range') then
    alter table yuk_qolda add constraint yuk_qolda_id_range check (id >= 9000001);
  end if;
end $yq_chk$;
comment on table yuk_qolda is
  'Boshlangich (qolda) qarz hujjati — Aros''da hujjati yoq yetkazuvchi qarzi. id >= 9000001, Aros yuk id''lari '
  'bilan toqnashmaydi; entry_yuk/yuk_tannarx/yuk_deadline/yuk_tolov_grafik/yuk_yopiq shu id bilan ishlaydi. '
  'Sahifalar yuk_qolda_royxat() orqali n8n royxatiga qoshadi. ENG OXIRGI: PROVODKA_YUK_QOLDA.sql';
create index if not exists yuk_qolda_yetk_idx on yuk_qolda(yetkazuvchi) where not is_deleted;

alter table yuk_qolda enable row level security;
revoke all on table yuk_qolda from public, anon, authenticated;
grant select on table yuk_qolda to authenticated;
drop policy if exists yuk_qolda_sel on yuk_qolda;
create policy yuk_qolda_sel on yuk_qolda for select to authenticated using (true);
-- yozish faqat RPC orqali (security definer)

-- ---------------------------------------------------------------- 2) ruxsat + RPC
create or replace function _yuk_qolda_korish_ok()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then return false; end if;
  if is_admin() then return true; end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'perm_has_page') then
    return perm_has_page('yuklar') or perm_has_page('qarzdor') or perm_has_page('beshkunlik') or perm_has_page('tannarx');
  end if;
  return false;
end
$fn$;
revoke all on function _yuk_qolda_korish_ok() from public, anon, authenticated;

create or replace function _yuk_qolda_yozish_ok()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then return false; end if;
  if is_admin() then return true; end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'perm_has_page') then
    return perm_has_page('yuklar');
  end if;
  return false;
end
$fn$;
revoke all on function _yuk_qolda_yozish_ok() from public, anon, authenticated;

-- n8n yuk qatori SHAKLIDA (id, sana, ombor, yetkazuvchi, narx, valyuta, status, delivery_status, post_at, qatorlar) + qolda:true
create or replace function yuk_qolda_royxat()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not _yuk_qolda_korish_ok() then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', q.id,
             'sana', to_char(q.sana, 'YYYY-MM-DD') || 'T00:00:00+05:00',
             'ombor', 'Boshlang''ich qarz', 'ombor_id', null,
             'yetkazuvchi', q.yetkazuvchi, 'yetkazuvchi_tel', null,
             'narx', to_char(q.narx, 'FM999999999999990.00'),
             'valyuta', q.valyuta,
             'status', 'posted', 'delivery_status', 'accepted',
             'post_at', to_char(q.sana, 'YYYY-MM-DD') || 'T00:00:00+05:00',
             'qatorlar', '[]'::jsonb,
             'qolda', true, 'turi', q.turi, 'izoh', q.izoh, 'kalit', q.kalit) order by q.id)
      from yuk_qolda q where not q.is_deleted), '[]'::jsonb);
end
$fn$;
revoke all on function yuk_qolda_royxat() from public, anon;
grant execute on function yuk_qolda_royxat() to authenticated;

create or replace function yuk_qolda_yarat(p_yetkazuvchi text, p_narx numeric, p_valyuta text,
                                           p_sana date default null, p_izoh text default null, p_turi text default 'boshlangich')
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_id integer;
  v_nom text;
begin
  if not _yuk_qolda_yozish_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  if coalesce(trim(p_yetkazuvchi), '') = '' then return jsonb_build_object('ok', false, 'kod', 'yetkazuvchi'); end if;
  if p_narx is null or p_narx <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa'); end if;
  select full_name into v_nom from profiles where id = auth.uid();
  insert into yuk_qolda (yetkazuvchi, narx, valyuta, sana, izoh, turi, created_by_name)
    values (trim(p_yetkazuvchi), p_narx, upper(coalesce(nullif(trim(p_valyuta), ''), 'UZS')),
            coalesce(p_sana, (now() at time zone 'Asia/Tashkent')::date), p_izoh, coalesce(p_turi, 'boshlangich'), v_nom)
    returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end
$fn$;
revoke all on function yuk_qolda_yarat(text, numeric, text, date, text, text) from public, anon;
grant execute on function yuk_qolda_yarat(text, numeric, text, date, text, text) to authenticated;

-- o'chirish: to'lov / grafik / yopiq bog'langan bo'lsa RAD (avval ular yechilsin)
create or replace function yuk_qolda_ochir(p_id integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not _yuk_qolda_yozish_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  if not exists (select 1 from yuk_qolda where id = p_id and not is_deleted) then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi');
  end if;
  if exists (select 1 from entry_yuk ey join entry e on e.id = ey.entry_id where ey.yuk_id = p_id and e.is_deleted = false)
     or exists (select 1 from yuk_tolov_grafik where yuk_id = p_id)
     or exists (select 1 from yuk_grafik_guruh_yuk where yuk_id = p_id)
     or exists (select 1 from yuk_yopiq where yuk_id = p_id and not is_deleted) then
    return jsonb_build_object('ok', false, 'kod', 'bogliq');
  end if;
  update yuk_qolda set is_deleted = true, deleted_at = now(), deleted_by = auth.uid() where id = p_id;
  delete from yuk_deadline where yuk_id = p_id;
  return jsonb_build_object('ok', true);
end
$fn$;
revoke all on function yuk_qolda_ochir(integer) from public, anon;
grant execute on function yuk_qolda_ochir(integer) to authenticated;

-- ---------------------------------------------------------------- 3) Asilbek ro'yxati 19.09.2026 — 23 hujjat
-- id'lar QAT'IY (9000001…) — PROVODKA_GRAFIK_20260919.sql shu id'larga grafik qo'yadi. Takror RUN xavfsiz (kalit).
insert into yuk_qolda (id, kalit, yetkazuvchi, narx, valyuta, turi, izoh, sana, created_by_name) 
select v.id, v.kalit, v.yetkazuvchi, v.narx, v.valyuta, v.turi, v.izoh, date '2026-09-19', 'Asilbek (ro''yxat 19.09.2026)'
  from (values
  (9000001, 'bq20260919:Evro Mobile:UZS', 'Evro Mobile', 106392500, 'UZS', 'eski', 'Eski qarz: ro''yxat 151 063 500 − Aros hujjatlari 44 671 000'),
  (9000002, 'bq20260919:Lobaropa (Sergeli):UZS', 'Lobaropa (Sergeli)', 41664500, 'UZS', 'eski', 'Eski qarz: ro''yxat 42 984 500 − Aros 1 320 000'),
  (9000003, 'bq20260919:56-do''kon:UZS', '56-do''kon', 36718000, 'UZS', 'eski', 'Eski qarz: ro''yxat 36 750 000 − Aros 32 000'),
  (9000004, 'bq20260919:Xinbo:CHY', 'Xinbo', 448823.8, 'CHY', 'eski', 'Eski qarz: ro''yxat ¥598 664 − Aros ¥149 840,2'),
  (9000005, 'bq20260919:Bonny:CHY', 'Bonny', 159542, 'CHY', 'eski', 'Eski qarz: ro''yxat ¥557 863 − Aros ¥398 321'),
  (9000006, 'bq20260919:RS-Mobile:USD', 'RS-Mobile', 11966.1, 'USD', 'eski', 'Eski qarz: ro''yxat $14 486,1 − Aros $2 520'),
  (9000007, 'bq20260919:Mobil Plus:UZS', 'Mobil Plus', 3390000, 'UZS', 'eski', 'Eski qarz: ro''yxat 6 515 000 − Aros 3 125 000'),
  (9000008, 'bq20260919:Azizaka (SP Itel):USD', 'Azizaka (SP Itel)', 1815, 'USD', 'eski', 'Eski qarz: ro''yxat $3 190 − Aros $1 375'),
  (9000009, 'bq20260919:BEST:USD', 'BEST', 388.8, 'USD', 'eski', 'Eski qarz: ro''yxat $772,8 − Aros $384'),
  (9000010, 'bq20260919:A33 (Malika):USD', 'A33 (Malika)', 6158, 'USD', 'hujjat_yoq', 'Ro''yxat $6 158 (Asilbek: USD) — Aros hujjati to''langan'),
  (9000011, 'bq20260919:Evro Mobile:USD', 'Evro Mobile', 663, 'USD', 'hujjat_yoq', 'Dollar hujjati Aros''da yo''q'),
  (9000012, 'bq20260919:Mega Star:USD', 'Mega Star', 1152, 'USD', 'hujjat_yoq', 'Aros hujjati Provodka''da to''liq to''langan, ro''yxatda $1 152 qarz'),
  (9000013, 'bq20260919:FRANSHIZA PULLARI:UZS', 'FRANSHIZA PULLARI', 175632000, 'UZS', 'aros_yoq', 'Yetkazuvchi Aros''da yo''q'),
  (9000014, 'bq20260919:202-D:UZS', '202-D', 51904600, 'UZS', 'aros_yoq', 'Yetkazuvchi Aros''da yo''q (19 qator, +65 095 400 avans hisobga olingan)'),
  (9000015, 'bq20260919:164-D:UZS', '164-D', 38930000, 'UZS', 'aros_yoq', 'Yetkazuvchi Aros''da yo''q'),
  (9000016, 'bq20260919:Temuraka Xorazm:USD', 'Temuraka Xorazm', 13760.1, 'USD', 'aros_yoq', 'Yetkazuvchi Aros''da yo''q'),
  (9000017, 'bq20260919:786-D:USD', '786-D', 1705, 'USD', 'aros_yoq', 'Yetkazuvchi Aros''da yo''q'),
  (9000018, 'bq20260919:786-D:UZS', '786-D', 4010000, 'UZS', 'aros_yoq', 'Yetkazuvchi Aros''da yo''q'),
  (9000019, 'bq20260919:BRAVO:UZS', 'BRAVO', 2550000, 'UZS', 'aros_yoq', 'Yetkazuvchi Aros''da yo''q'),
  (9000020, 'bq20260919:RAZERSHOP:USD', 'RAZERSHOP', 1456.8, 'USD', 'aros_yoq', 'Yetkazuvchi Aros''da yo''q'),
  (9000021, 'bq20260919:LiN LSD:CHY', 'LiN LSD', 7168, 'CHY', 'aros_yoq', 'Yetkazuvchi Aros''da yo''q'),
  (9000022, 'bq20260919:ULTRA MABAIL:UZS', 'ULTRA MABAIL', 200000, 'UZS', 'aros_yoq', 'Yetkazuvchi Aros''da yo''q'),
  (9000023, 'bq20260919:haseb:AED', 'haseb', 201, 'AED', 'aros_yoq', 'Yetkazuvchi Aros''da yo''q; AED kursi bazada bo''lmasa ko''rinmaydi')
  ) as v(id, kalit, yetkazuvchi, narx, valyuta, turi, izoh)
on conflict (kalit) do nothing;

select id, yetkazuvchi, narx, valyuta, turi from yuk_qolda where kalit like 'bq20260919:%' and not is_deleted order by id;
