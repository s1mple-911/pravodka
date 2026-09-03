-- =====================================================================
-- PROVODKA_EHSON.sql — Ehson (xayriya) bo'limi, 1-BOSQICH (SQL + skelet)
-- ---------------------------------------------------------------------
-- Brief: ARX_PROVODKA_EHSON.md (Asilbek TASDIQLADI, 2026-09-03).
--
-- 🔴 IZOLYATSIYA — BU FAYLNING BOSH QOIDASI: Ehson tizimi Provodka'ning
-- ikki tomonlama buxgalteriya moduliga UMUMAN KIRMAYDI. Buxgalteriya
-- jadvallari (yozuv sarlavhasi, yozuv qatorlari, hisob rejasi) bu faylda
-- BIR MARTA HAM tilga OLINMAYDI — na o'qish, na yozish. Pul harakati
-- FAQAT shu faylning o'z jadvallari (ehson_kirim / ehson_berish) ichida.
-- Buni buzadigan har qanday keyingi o'zgarish RAD etilishi kerak.
--
-- ## RUN TARTIBI — butun faylni birdaniga RUN qilish mumkin.
--   1-BOLIM   — old shart tekshiruvi (faqat select/raise)
--   2-BOLIM   — perm_pages() ga 'ehson' kaliti (17 -> 18)
--   3-BOLIM   — _ehson_is_admin() (moslashuvchan) + ehson_page_ok()
--   4-BOLIM   — jadvallar: ehson_kassa, ehson_oila, ehson_reja, ehson_azo,
--               ehson_kirim, ehson_berish, ehson_tarix (+ RLS + trigger)
--   5-BOLIM   — seed: bitta "Ehson jamg'armasi"
--   6-BOLIM   — viewlar: v_ehson_kassa, v_ehson_azo, v_ehson_oila_jami, v_ehson_oy
--   7-BOLIM   — ichki yordamchilar: _ehson_tarix_yoz, _ehson_kod_next
--   8-BOLIM   — RPC'lar (dashboard, kirim, oila/a'zo, import, berish, reja, ro'yxat)
--   9-BOLIM   — bucket `ehson-hujjat` + storage policy
--  10-BOLIM   — PostgREST sxema keshi
--  11-BOLIM   — YAKUNIY TEKSHIRUV (faqat select)
--
-- ## OLD SHART (bazada bo'lishi kerak)
--   profiles / user_perms / perm_pages()  -> asosiy migratsiya + PROVODKA_PERMS.sql
--   is_admin()  -> BOR bo'lsa ishlatiladi; YO'Q bo'lsa `profiles.role='admin'`
--                  bilan ICHKI qobiq (_ehson_is_admin) o'zi tuziladi (3-BOLIM).
--
-- ## ADDITIVE KAFOLATI
--   * Hech narsa drop qilinmaydi. Yagona QAYTA YOZILADIGAN mavjud obyekt —
--     `perm_pages()` (kalit qo'shiladi, eski ro'yxat saqlanadi).
--   * Hamma jadval/funksiya/view YANGI, `ehson_` yoki `_ehson_` prefiksi bilan.
--   * Anonim `do` bloki YO'Q — har `do` bloki NOMLANGAN teg bilan.
--     Funksiya tanasi nomlangan "fn" tegi bilan o'raladi. Izohlarda dollar
--     belgi ikkitalab yonma-yon YOZILMAGAN (soxta blok xavfi — CLAUDE.md).
--   * Idempotent: `create table if not exists`, `create or replace function`,
--     `drop policy if exists` + `create policy`, seed `where not exists`.
--
-- ## FAIL-CLOSED QOIDALARI
--   * Yozuv/RLS: har jadvalda SELECT policy `ehson_page_ok()` (admin YOKI
--     'ehson' ∈ allowed_pages). INSERT/UPDATE/DELETE policy UMUMAN YO'Q —
--     yozish faqat shu fayldagi `security definer` RPC'lar orqali.
--   * Berish (`ehson_ber`) jamg'arma qoldig'idan ortiq bo'lsa RAD ETADI —
--     hech narsa yozilmaydi. Kirimni bekor qilish qoldiqni manfiy qilib
--     qo'ysa RAD ETADI.
--   * Tahrir (mavjud oila/a'zo yangilash), bekor qilish, import, reja
--     to'xtatish — FAQAT admin. Berish va kirim yozish, yangi oila/a'zo
--     ro'yxatga olish — 'ehson' ruxsatli har qanday foydalanuvchi.
-- =====================================================================


-- #####################################################################
-- ##  1-BOLIM — OLD SHART TEKSHIRUVI (faqat select/raise)             ##
-- #####################################################################

do $ehson_pre$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'profiles jadvali yoq — avval asosiy migratsiyani bajaring';
  end if;
  if to_regclass('public.user_perms') is null then
    raise exception 'user_perms jadvali yoq — avval PROVODKA_PERMS.sql ni bajaring';
  end if;
  if to_regprocedure('public.perm_pages()') is null then
    raise exception 'perm_pages() yoq — avval PROVODKA_PERMS.sql ni bajaring';
  end if;
end
$ehson_pre$;


-- #####################################################################
-- ##  2-BOLIM — perm_pages() ga 'ehson' kaliti (17 -> 18)             ##
-- #####################################################################
-- 🔴 KLIENT TOMONI — BUSIZ ISHLAMAYDI (boshqa agent bajaradi):
--    (a) `perms-dev.js` dagi `PAGES` massiviga 'ehson';
--    (b) `index-dev.html` dagi `CARDS` ga ehson kartasi;
--    (c) 15 dev faylda nav (sidebar + "Ko'proq" sheet);
--    (d) `promote.sh` `PAGES` ga 'ehson';
--    (e) admin-dev `PVS_PAGES` ga {key:'ehson', label:'Ehson'} (boshqa repo).
--    Aks holda `admin_set_provodka_perms` kalitni "noma'lum" deb JIMGINA
--    tashlab yuboradi.
-- #####################################################################

create or replace function perm_pages()
returns text[]
language sql
immutable
as $perm_pages$
  select array['kassa','jurnal','professional','hisobot','balans','cashflow',
               'qarzdor','filial','valyuta','konvert','sozlama','provodka',
               'yuklar','standart','tannarx','ai','sorovlar','ehson']::text[];
$perm_pages$;

revoke all on function perm_pages() from public, anon;
grant execute on function perm_pages() to authenticated, service_role;

comment on function perm_pages() is
  'Provodka sahifa kalitlari (18 ta). perms.js dagi PAGES va admin-dev PVS_PAGES bilan bir xil. '
  'hodim.html bu ro''yxatga KIRMAYDI — u hech qachon cheklanmaydi.';


-- #####################################################################
-- ##  3-BOLIM — _ehson_is_admin() (moslashuvchan) + ehson_page_ok()   ##
-- #####################################################################
-- 🔴 `is_admin()` bu bazada deyarli kafolatlangan mavjud (butun loyihada
--    o'nlab joyda ishlatiladi), lekin shu modul MUSTAQIL bo'lishi kerak
--    (ARX 0-bo'lim) — shuning uchun mavjud bo'lmasa `profiles.role='admin'`
--    bilan ICHKI qobiq quriladi. Boshqa hech qanday RPC to'g'ridan
--    `is_admin()` ni CHAQIRMAYDI — hammasi shu qobiqdan foydalanadi, aks
--    holda `is_admin()` yo'q bazada butun fayl CREATE bosqichida yiqiladi
--    (funksiya tanasi tekshiriladi — `plpgsql.check_function_bodies`).
-- #####################################################################

do $ehson_is_admin_setup$
declare
  v_admin_expr text;
begin
  if to_regprocedure('public.is_admin()') is not null then
    v_admin_expr := 'is_admin()';
  else
    v_admin_expr := $x$coalesce((select role = 'admin' from profiles where id = auth.uid()), false)$x$;
  end if;

  execute format($ddl$
    create or replace function _ehson_is_admin()
    returns boolean
    language sql
    stable
    security definer
    set search_path = public
    as $fn$
      select %s;
    $fn$;
  $ddl$, v_admin_expr);
end
$ehson_is_admin_setup$;

revoke all on function _ehson_is_admin() from public, anon, authenticated;

comment on function _ehson_is_admin() is
  'ICHKI: admin tekshiruvi. is_admin() bor bo''lsa shuni, bo''lmasa profiles.role=admin ni ishlatadi. '
  'Boshqa hech qanday ehson_* funksiya is_admin() ni to''g''ridan chaqirmaydi — hammasi shu qobiqdan foydalanadi.';

create or replace function ehson_page_ok()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select _ehson_is_admin() or coalesce(
    (select 'ehson' = any(coalesce(allowed_pages, '{}'::text[]))
       from user_perms where user_id = auth.uid()),
    false
  );
$fn$;

revoke all on function ehson_page_ok() from public, anon;
grant execute on function ehson_page_ok() to authenticated;

comment on function ehson_page_ok() is
  'RLS qorovuli: admin YOKI ehson sahifasi ruxsati (allowed_pages ∋ ''ehson''). '
  'auth.uid() null bo''lsa false (fail-closed).';


-- #####################################################################
-- ##  4-BOLIM — JADVALLAR (bog'liqlik tartibida) + RLS + trigger      ##
-- #####################################################################
-- Tartib ARX ro'yxatidan farq qiladi (bog'lanish uchun): jamg'arma ->
-- oila -> reja -> a'zo -> kirim -> berish -> tarix. Har jadvalning
-- USTUNLARI ARX 2-bo'limdagi bilan AYNAN bir xil.
-- #####################################################################

-- 4.1 ehson_kassa — jamg'arma. Balans USTUN emas, view'dan hisoblanadi.
create table if not exists ehson_kassa (
  id          uuid        primary key default gen_random_uuid(),
  nom         text        not null,
  izoh        text,
  is_active   boolean     not null default true,
  created_by  uuid,
  created_at  timestamptz not null default now()
);

comment on table ehson_kassa is
  'Ehson jamg''armasi (v1 — bitta qator, sxema ko''p jamg''armaga tayyor). Balans view''dan hisoblanadi.';

alter table ehson_kassa enable row level security;
revoke all on table ehson_kassa from public, anon;
grant select on table ehson_kassa to authenticated;

drop policy if exists ehson_kassa_select on ehson_kassa;
create policy ehson_kassa_select on ehson_kassa
  for select to authenticated
  using (ehson_page_ok());


-- 4.2 ehson_oila — Excel "Oilalar" varag'i + kengaytirish.
create table if not exists ehson_oila (
  id                     uuid        primary key default gen_random_uuid(),
  oila_kod               text        not null unique,
  fio                    text        not null,
  telefon                text,
  manzil                 text,
  tavsiya                text,
  oilaviy_holat          text,
  uyjoy_holat            text,
  oylik_daromad          numeric,
  muhtojlik_sabab        text,
  yordam_turi            text,
  yordam_miqdor          text,
  muhtojlik_daraja       text check (muhtojlik_daraja is null or muhtojlik_daraja in ('yuqori','orta','past')),
  kiritilgan_sana        date,
  tekshirgan             text,
  tekshirilgan_sana      date,
  izoh                   text,
  holat                  text        not null default 'faol' check (holat in ('faol','kuzatuv','yopildi')),
  hudud                  text,
  keyingi_korib_chiqish  date,
  hujjat_path            text,
  created_by             uuid,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  updated_by             uuid
);

comment on table ehson_oila is
  'Ehson oluvchi oila (Excel "Oilalar" varag''i + kengaytirish). Yosh a''zolarda SAQLANMAYDI (v_ehson_azo hisoblaydi).';

create index if not exists ehson_oila_muhtojlik_idx on ehson_oila (muhtojlik_daraja);
create index if not exists ehson_oila_holat_idx      on ehson_oila (holat);
create index if not exists ehson_oila_hudud_idx      on ehson_oila (hudud);

alter table ehson_oila enable row level security;
revoke all on table ehson_oila from public, anon;
grant select on table ehson_oila to authenticated;

drop policy if exists ehson_oila_select on ehson_oila;
create policy ehson_oila_select on ehson_oila
  for select to authenticated
  using (ehson_page_ok());


-- 4.3 ehson_reja — oyma-oy majburiyat. Bitta oilada bitta faol reja.
create table if not exists ehson_reja (
  id              uuid        primary key default gen_random_uuid(),
  oila_id         uuid        not null references ehson_oila(id),
  oylik_summa     numeric     not null check (oylik_summa > 0),
  boshlanish      date        not null,
  oylar_soni      int         check (oylar_soni is null or oylar_soni > 0),
  tugash          date,
  holat           text        not null default 'faol' check (holat in ('faol','tugadi','toxtatildi')),
  izoh            text,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  toxtatilgan_at  timestamptz,
  toxtat_sabab    text
);

comment on table ehson_reja is
  'Oyma-oy majburiyat. boshlanish har doim oyning 1-kuniga siljitiladi (RPC ichida). '
  'oylar_soni=null -> muddatsiz (tugash=null).';

create unique index if not exists ehson_reja_oila_faol_uniq
  on ehson_reja (oila_id) where holat = 'faol';
create index if not exists ehson_reja_oila_idx on ehson_reja (oila_id);

alter table ehson_reja enable row level security;
revoke all on table ehson_reja from public, anon;
grant select on table ehson_reja to authenticated;

drop policy if exists ehson_reja_select on ehson_reja;
create policy ehson_reja_select on ehson_reja
  for select to authenticated
  using (ehson_page_ok());


-- 4.4 ehson_azo — Excel "Oila a'zolari". Yosh SAQLANMAYDI (view hisoblaydi).
create table if not exists ehson_azo (
  id             uuid        primary key default gen_random_uuid(),
  oila_id        uuid        not null references ehson_oila(id),
  azo_kod        text        not null,
  qarindosh      text,
  fio            text        not null,
  tugilgan_sana  date,
  sogliq         text,
  sogliq_izoh    text,
  ish_oqish      text,
  kasb_sinf      text,
  oylik_daromad  numeric,
  qaramogida     boolean     not null default false,
  izoh           text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (oila_id, azo_kod)
);

comment on table ehson_azo is
  'Oila a''zosi. Yosh SAQLANMAYDI — v_ehson_azo tugilgan_sana''dan age() bilan hisoblaydi.';

create index if not exists ehson_azo_oila_idx on ehson_azo (oila_id);

alter table ehson_azo enable row level security;
revoke all on table ehson_azo from public, anon;
grant select on table ehson_azo to authenticated;

drop policy if exists ehson_azo_select on ehson_azo;
create policy ehson_azo_select on ehson_azo
  for select to authenticated
  using (ehson_page_ok());


-- 4.5 ehson_kirim — jamg'armaga pul kelishi.
create table if not exists ehson_kirim (
  id          uuid        primary key default gen_random_uuid(),
  kassa_id    uuid        not null references ehson_kassa(id),
  summa       numeric     not null check (summa > 0),
  sana        date        not null default ((now() at time zone 'Asia/Tashkent')::date),
  manba       text,
  izoh        text,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  is_deleted  boolean     not null default false,
  deleted_by  uuid,
  deleted_at  timestamptz
);

comment on table ehson_kirim is
  'Jamg''armaga pul kelishi (manba: "Kompaniya", "Xayriyachi: ..."). Soft-delete (is_deleted).';

create index if not exists ehson_kirim_kassa_idx on ehson_kirim (kassa_id);
create index if not exists ehson_kirim_sana_idx  on ehson_kirim (sana);

alter table ehson_kirim enable row level security;
revoke all on table ehson_kirim from public, anon;
grant select on table ehson_kirim to authenticated;

drop policy if exists ehson_kirim_select on ehson_kirim;
create policy ehson_kirim_select on ehson_kirim
  for select to authenticated
  using (ehson_page_ok());


-- 4.6 ehson_berish — pul/yordam berish (Excel "Ehson tarixi").
create table if not exists ehson_berish (
  id                     uuid        primary key default gen_random_uuid(),
  oila_id                uuid        not null references ehson_oila(id),
  kassa_id               uuid        not null references ehson_kassa(id),
  summa                  numeric     not null check (summa > 0),
  sana                   date        not null default ((now() at time zone 'Asia/Tashkent')::date),
  tur                    text        not null check (tur in ('pul','oziq_ovqat','kiyim','dori','boshqa')),
  izoh                   text        not null check (length(btrim(izoh)) >= 3),
  reja_id                uuid        references ehson_reja(id),
  holat                  text        not null default 'berildi' check (holat in ('berildi','bekor')),
  keyingi_korib_chiqish  date,
  created_by             uuid,
  created_at             timestamptz not null default now(),
  is_deleted             boolean     not null default false,
  deleted_by             uuid,
  deleted_at             timestamptz,
  bekor_sabab            text,
  ext_ref                text        unique
);

comment on table ehson_berish is
  'Oilaga berish. summa har turda (pul/oziq-ovqat/kiyim/dori/boshqa) jamg''armadan PUL sifatida chiqadi. '
  'Tahrir YO''Q — faqat soft-bekor (ehson_berish_bekor, admin, sabab majburiy). ext_ref — takror himoyasi.';

create index if not exists ehson_berish_oila_idx  on ehson_berish (oila_id);
create index if not exists ehson_berish_kassa_idx on ehson_berish (kassa_id);
create index if not exists ehson_berish_sana_idx  on ehson_berish (sana);
create index if not exists ehson_berish_reja_idx  on ehson_berish (reja_id);

alter table ehson_berish enable row level security;
revoke all on table ehson_berish from public, anon;
grant select on table ehson_berish to authenticated;

drop policy if exists ehson_berish_select on ehson_berish;
create policy ehson_berish_select on ehson_berish
  for select to authenticated
  using (ehson_page_ok());


-- 4.7 ehson_tarix — audit (append-only).
create table if not exists ehson_tarix (
  id         bigserial   primary key,
  obyekt     text        not null check (obyekt in ('oila','azo','berish','kirim','reja','kassa')),
  obyekt_id  uuid,
  hodisa     text        not null,
  data       jsonb       not null default '{}'::jsonb,
  kim        uuid,
  vaqt       timestamptz not null default now()
);

comment on table ehson_tarix is
  'Audit (append-only) — har RPC bir hodisa qatori qo''shadi. obyekt_id null bo''lishi mumkin (masalan import xulosasi).';

create index if not exists ehson_tarix_obyekt_idx on ehson_tarix (obyekt, obyekt_id, vaqt desc);

alter table ehson_tarix enable row level security;
revoke all on table ehson_tarix from public, anon;
grant select on table ehson_tarix to authenticated;

drop policy if exists ehson_tarix_select on ehson_tarix;
create policy ehson_tarix_select on ehson_tarix
  for select to authenticated
  using (ehson_page_ok());


-- 4.8 updated_at trigger (oddiy) — ehson_oila, ehson_azo.
create or replace function _ehson_set_updated_at()
returns trigger
language plpgsql
as $fn$
begin
  new.updated_at := now();
  return new;
end
$fn$;

revoke all on function _ehson_set_updated_at() from public, anon, authenticated;

drop trigger if exists ehson_oila_updated_at on ehson_oila;
create trigger ehson_oila_updated_at
  before update on ehson_oila
  for each row execute function _ehson_set_updated_at();

drop trigger if exists ehson_azo_updated_at on ehson_azo;
create trigger ehson_azo_updated_at
  before update on ehson_azo
  for each row execute function _ehson_set_updated_at();


-- #####################################################################
-- ##  5-BOLIM — SEED: bitta "Ehson jamg'armasi"                       ##
-- #####################################################################

insert into ehson_kassa (nom, izoh, is_active)
select 'Ehson jamg''armasi', 'Sukut jamg''arma (v1 — bitta).', true
where not exists (select 1 from ehson_kassa);


-- #####################################################################
-- ##  6-BOLIM — VIEWLAR (security_invoker = on)                       ##
-- #####################################################################

create or replace view v_ehson_kassa as
select
  k.id,
  k.nom,
  k.is_active,
  coalesce(ki.summa, 0)                        as kirim,
  coalesce(be.summa, 0)                        as berildi,
  coalesce(ki.summa, 0) - coalesce(be.summa, 0) as qoldiq
from ehson_kassa k
left join lateral (
  select sum(summa) as summa from ehson_kirim where kassa_id = k.id and is_deleted = false
) ki on true
left join lateral (
  select sum(summa) as summa from ehson_berish where kassa_id = k.id and holat = 'berildi'
) be on true;

alter view v_ehson_kassa set (security_invoker = on);
revoke all on v_ehson_kassa from public, anon;
grant select on v_ehson_kassa to authenticated;

comment on view v_ehson_kassa is 'Har jamg''arma uchun: kirim/berildi/qoldiq. security_invoker — RLS o''zi ishlaydi.';


create or replace view v_ehson_azo as
select
  az.*,
  case when az.tugilgan_sana is null then null
       else extract(year  from age(current_date, az.tugilgan_sana))::int end as yosh_yil,
  case when az.tugilgan_sana is null then null
       else extract(month from age(current_date, az.tugilgan_sana))::int end as yosh_oy,
  case when az.tugilgan_sana is null then null
       else extract(day   from age(current_date, az.tugilgan_sana))::int end as yosh_kun,
  case when az.tugilgan_sana is null then null
       else extract(year  from age(current_date, az.tugilgan_sana))::int || ' yil ' ||
            extract(month from age(current_date, az.tugilgan_sana))::int || ' oy'
  end as yosh_matn,
  case when az.tugilgan_sana is null then null
       else extract(year from age(current_date, az.tugilgan_sana)) < 18
  end as bola
from ehson_azo az;

alter view v_ehson_azo set (security_invoker = on);
revoke all on v_ehson_azo from public, anon;
grant select on v_ehson_azo to authenticated;

comment on view v_ehson_azo is 'ehson_azo + yosh (tugilgan_sana''dan age() bilan hisoblangan, saqlanmaydi) + bola bayrog''i (<18).';


create or replace view v_ehson_oila_jami as
select
  o.id                          as oila_id,
  coalesce(az.azo_soni, 0)      as azo_soni,
  coalesce(az.bola_soni, 0)     as bola_soni,
  coalesce(az.qaramog_soni, 0)  as qaramog_soni,
  coalesce(be.jami_olgan, 0)    as jami_olgan,
  be.oxirgi_sana,
  rj.oylik_summa                as faol_reja_summa
from ehson_oila o
left join lateral (
  select count(*)                                as azo_soni,
         count(*) filter (where v.bola)          as bola_soni,
         count(*) filter (where v.qaramogida)    as qaramog_soni
    from v_ehson_azo v where v.oila_id = o.id
) az on true
left join lateral (
  select sum(summa) as jami_olgan, max(sana) as oxirgi_sana
    from ehson_berish where oila_id = o.id and holat = 'berildi'
) be on true
left join lateral (
  select oylik_summa from ehson_reja where oila_id = o.id and holat = 'faol' limit 1
) rj on true;

alter view v_ehson_oila_jami set (security_invoker = on);
revoke all on v_ehson_oila_jami from public, anon;
grant select on v_ehson_oila_jami to authenticated;

comment on view v_ehson_oila_jami is 'Oila kesimi: a''zo/bola/qaramog''idagi soni, jami olgan, oxirgi berish sanasi, faol reja summasi.';


create or replace view v_ehson_oy as
select
  gm.oy::date                                       as oy,
  r.oila_id,
  o.oila_kod,
  o.fio,
  r.id                                               as reja_id,
  r.oylik_summa                                      as reja_summa,
  coalesce(f.fakt_summa, 0)                          as fakt_summa,
  coalesce(f.fakt_summa, 0) - r.oylik_summa          as farq,
  case
    when coalesce(f.fakt_summa, 0) >= r.oylik_summa then 'berildi'
    when coalesce(f.fakt_summa, 0) > 0              then 'qisman'
    when gm.oy >= date_trunc('month', current_date) then 'kutilmoqda'
    else 'qoldi'
  end                                                as holat
from ehson_reja r
join ehson_oila o on o.id = r.oila_id
cross join lateral generate_series(
  date_trunc('month', r.boshlanish),
  coalesce(date_trunc('month', r.tugash), date_trunc('month', current_date)),
  interval '1 month'
) as gm(oy)
left join lateral (
  select sum(b.summa) as fakt_summa
    from ehson_berish b
   where b.oila_id = r.oila_id
     and b.holat = 'berildi'
     and date_trunc('month', b.sana) = date_trunc('month', gm.oy)
) f on true
where r.holat = 'faol';

alter view v_ehson_oy set (security_invoker = on);
revoke all on v_ehson_oy from public, anon;
grant select on v_ehson_oy to authenticated;

comment on view v_ehson_oy is
  'Reja vs fakt, faol rejalar bo''yicha, boshlanishdan joriy oygacha (ochiq muddat uchun). '
  'holat: berildi (fakt>=reja) · qisman (0<fakt<reja) · kutilmoqda (joriy/kelasi oy, fakt=0) · qoldi (o''tgan oy, fakt<reja).';


-- #####################################################################
-- ##  7-BOLIM — ICHKI YORDAMCHILAR                                    ##
-- #####################################################################

-- 7.1 _ehson_tarix_yoz(...) — audit qatori qo'yadi.
create or replace function _ehson_tarix_yoz(p_obyekt text, p_obyekt_id uuid, p_hodisa text,
                                             p_data jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path = public
as $fn$
  insert into ehson_tarix (obyekt, obyekt_id, hodisa, data, kim)
  values (p_obyekt, p_obyekt_id, p_hodisa, coalesce(p_data, '{}'::jsonb), auth.uid());
$fn$;

revoke all on function _ehson_tarix_yoz(text, uuid, text, jsonb) from public, anon, authenticated;

comment on function _ehson_tarix_yoz(text, uuid, text, jsonb) is
  'ICHKI: ehson_tarix ga bitta audit qatori qo''shadi. Hech qachon RAD etib butun amalni to''smaydi (RPC ichida perform bilan).';


-- 7.2 _ehson_kod_next(kind, scope) — OILA-/AZO- kodlarini max+1, 3 xonali.
--     p_kind='oila' -> global (ehson_oila.oila_kod). p_kind='azo' -> p_scope
--     (oila_id) ICHIDA unique (ehson_azo.azo_kod). Advisory lock — bir vaqtda
--     import qilinganda bir xil kod ikki marta berilmasin.
create or replace function _ehson_kod_next(p_kind text, p_scope uuid default null)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_prefix text;
  v_max    int;
begin
  perform pg_advisory_xact_lock(hashtext('ehson_kod:' || p_kind || ':' || coalesce(p_scope::text, '')));

  if p_kind = 'oila' then
    v_prefix := 'OILA-';
    select coalesce(max(substring(oila_kod from '\d+$')::int), 0)
      into v_max
      from ehson_oila
     where oila_kod ~ '^OILA-\d+$';
  elsif p_kind = 'azo' then
    v_prefix := 'AZO-';
    select coalesce(max(substring(azo_kod from '\d+$')::int), 0)
      into v_max
      from ehson_azo
     where oila_id = p_scope
       and azo_kod ~ '^AZO-\d+$';
  else
    raise exception 'Notogri kod turi: %', p_kind;
  end if;

  return v_prefix || lpad((v_max + 1)::text, 3, '0');
end
$fn$;

revoke all on function _ehson_kod_next(text, uuid) from public, anon, authenticated;

comment on function _ehson_kod_next(text, uuid) is
  'ICHKI: keyingi OILA-NNN / AZO-NNN (oila ichida unique) kodi. Advisory lock bilan poyga himoyalangan.';


-- #####################################################################
-- ##  8-BOLIM — RPC'LAR                                               ##
-- #####################################################################

-- 8.1 ehson_dash() — bosh sahifa statistikasi.
create or replace function ehson_dash()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid        uuid := auth.uid();
  v_kassalar   jsonb;
  v_oila_holat jsonb;
  v_muhtojlik  jsonb;
  v_bu_oy      date := date_trunc('month', (now() at time zone 'Asia/Tashkent'))::date;
  v_oy_reja    numeric;
  v_oy_fakt    numeric;
  v_jami_yil   numeric;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'nom', nom, 'is_active', is_active,
           'kirim', kirim, 'berildi', berildi, 'qoldiq', qoldiq
         ) order by nom), '[]'::jsonb)
    into v_kassalar
    from v_ehson_kassa;

  select coalesce(jsonb_object_agg(holat, soni), '{}'::jsonb)
    into v_oila_holat
    from (select holat, count(*) as soni from ehson_oila group by holat) x;

  select coalesce(jsonb_object_agg(coalesce(muhtojlik_daraja, 'belgilanmagan'), soni), '{}'::jsonb)
    into v_muhtojlik
    from (
      select muhtojlik_daraja, count(*) as soni
        from ehson_oila where holat <> 'yopildi'
       group by muhtojlik_daraja
    ) x;

  select coalesce(sum(oylik_summa), 0) into v_oy_reja
    from ehson_reja where holat = 'faol';

  select coalesce(sum(summa), 0) into v_oy_fakt
    from ehson_berish
   where holat = 'berildi' and date_trunc('month', sana) = v_bu_oy;

  select coalesce(sum(summa), 0) into v_jami_yil
    from ehson_berish
   where holat = 'berildi'
     and date_trunc('year', sana) = date_trunc('year', (now() at time zone 'Asia/Tashkent'));

  return jsonb_build_object(
    'kassalar',      v_kassalar,
    'oilalar_holat', v_oila_holat,
    'muhtojlik',     v_muhtojlik,
    'bu_oy_reja',    v_oy_reja,
    'bu_oy_fakt',    v_oy_fakt,
    'jami_oy',       v_oy_fakt,
    'jami_yil',      v_jami_yil
  );
end
$fn$;

revoke all on function ehson_dash() from public, anon;
grant execute on function ehson_dash() to authenticated;


-- 8.2 ehson_kirim_yoz(p) — jamg'armaga kirim.
create or replace function ehson_kirim_yoz(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid    := auth.uid();
  v_kassa uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_summa numeric := nullif(p->>'summa', '')::numeric;
  v_sana  date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_manba text    := nullif(btrim(coalesce(p->>'manba', '')), '');
  v_izoh  text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_cnt   int;
  v_id    uuid;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;
  if v_summa is null or v_summa <= 0 then
    return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
  end if;

  if v_kassa is null then
    select count(*) into v_cnt from ehson_kassa where is_active;
    if v_cnt <> 1 then
      return jsonb_build_object('ok', false, 'kod', 'kassa_tanlanmagan');
    end if;
    select id into v_kassa from ehson_kassa where is_active limit 1;
  end if;
  if not exists (select 1 from ehson_kassa where id = v_kassa and is_active) then
    return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi');
  end if;

  insert into ehson_kirim (kassa_id, summa, sana, manba, izoh, created_by)
  values (v_kassa, v_summa, v_sana, v_manba, v_izoh, v_uid)
  returning id into v_id;

  perform _ehson_tarix_yoz('kirim', v_id, 'yaratildi', jsonb_build_object('summa', v_summa, 'kassa_id', v_kassa));

  return jsonb_build_object('ok', true, 'id', v_id);
end
$fn$;

revoke all on function ehson_kirim_yoz(jsonb) from public, anon;
grant execute on function ehson_kirim_yoz(jsonb) to authenticated;


-- 8.3 ehson_kirim_bekor(p_id, p_sabab) — admin. Qoldiq manfiy bo'lsa RAD.
create or replace function ehson_kirim_bekor(p_id uuid, p_sabab text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid          uuid := auth.uid();
  v_sabab        text := nullif(btrim(coalesce(p_sabab, '')), '');
  v_row          ehson_kirim;
  v_kirim_qolgan numeric;
  v_berildi      numeric;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not _ehson_is_admin() then
    raise exception 'Faqat admin bekor qila oladi' using errcode = '42501';
  end if;
  if v_sabab is null then
    return jsonb_build_object('ok', false, 'kod', 'sabab_kerak');
  end if;

  select * into v_row from ehson_kirim where id = p_id and is_deleted = false;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi');
  end if;

  select coalesce(sum(summa), 0) into v_kirim_qolgan
    from ehson_kirim where kassa_id = v_row.kassa_id and is_deleted = false and id <> p_id;
  select coalesce(sum(summa), 0) into v_berildi
    from ehson_berish where kassa_id = v_row.kassa_id and holat = 'berildi';

  if v_kirim_qolgan - v_berildi < 0 then
    return jsonb_build_object('ok', false, 'kod', 'qoldiq_manfiy');
  end if;

  update ehson_kirim set is_deleted = true, deleted_by = v_uid, deleted_at = now()
   where id = p_id;

  perform _ehson_tarix_yoz('kirim', p_id, 'bekor', jsonb_build_object('sabab', v_sabab));

  return jsonb_build_object('ok', true);
end
$fn$;

revoke all on function ehson_kirim_bekor(uuid, text) from public, anon;
grant execute on function ehson_kirim_bekor(uuid, text) to authenticated;


-- 8.4 ehson_oila_saqla(p) — insert (ehson user) / update (admin).
create or replace function ehson_oila_saqla(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid       uuid := auth.uid();
  v_id        uuid := nullif(p->>'id', '')::uuid;
  v_kod       text;
  v_fio       text := nullif(btrim(coalesce(p->>'fio', '')), '');
  v_muhtojlik text := nullif(p->>'muhtojlik_daraja', '');
  v_holat     text := coalesce(nullif(p->>'holat', ''), 'faol');
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;
  if v_fio is null then
    return jsonb_build_object('ok', false, 'kod', 'fio_kerak');
  end if;
  if v_muhtojlik is not null and v_muhtojlik not in ('yuqori','orta','past') then
    return jsonb_build_object('ok', false, 'kod', 'muhtojlik_notogri');
  end if;
  if v_holat not in ('faol','kuzatuv','yopildi') then
    return jsonb_build_object('ok', false, 'kod', 'holat_notogri');
  end if;

  if v_id is not null then
    if not _ehson_is_admin() then
      raise exception 'Faqat admin oila malumotini tahrirlashi mumkin' using errcode = '42501';
    end if;
    if not exists (select 1 from ehson_oila where id = v_id) then
      return jsonb_build_object('ok', false, 'kod', 'topilmadi');
    end if;

    update ehson_oila set
      fio                   = v_fio,
      telefon               = nullif(btrim(coalesce(p->>'telefon', '')), ''),
      manzil                = nullif(btrim(coalesce(p->>'manzil', '')), ''),
      tavsiya               = nullif(btrim(coalesce(p->>'tavsiya', '')), ''),
      oilaviy_holat         = nullif(btrim(coalesce(p->>'oilaviy_holat', '')), ''),
      uyjoy_holat           = nullif(btrim(coalesce(p->>'uyjoy_holat', '')), ''),
      oylik_daromad         = nullif(p->>'oylik_daromad', '')::numeric,
      muhtojlik_sabab       = nullif(btrim(coalesce(p->>'muhtojlik_sabab', '')), ''),
      yordam_turi           = nullif(btrim(coalesce(p->>'yordam_turi', '')), ''),
      yordam_miqdor         = nullif(btrim(coalesce(p->>'yordam_miqdor', '')), ''),
      muhtojlik_daraja      = v_muhtojlik,
      kiritilgan_sana       = nullif(p->>'kiritilgan_sana', '')::date,
      tekshirgan            = nullif(btrim(coalesce(p->>'tekshirgan', '')), ''),
      tekshirilgan_sana     = nullif(p->>'tekshirilgan_sana', '')::date,
      izoh                  = nullif(btrim(coalesce(p->>'izoh', '')), ''),
      holat                 = v_holat,
      hudud                 = nullif(btrim(coalesce(p->>'hudud', '')), ''),
      keyingi_korib_chiqish = nullif(p->>'keyingi_korib_chiqish', '')::date,
      hujjat_path           = coalesce(nullif(btrim(coalesce(p->>'hujjat_path', '')), ''), hujjat_path),
      updated_by            = v_uid
    where id = v_id;

    perform _ehson_tarix_yoz('oila', v_id, 'yangilandi', p);
    return jsonb_build_object('ok', true, 'id', v_id);
  end if;

  v_kod := nullif(btrim(coalesce(p->>'oila_kod', '')), '');
  if v_kod is null then
    v_kod := _ehson_kod_next('oila', null);
  end if;

  begin
    insert into ehson_oila (
      oila_kod, fio, telefon, manzil, tavsiya, oilaviy_holat, uyjoy_holat, oylik_daromad,
      muhtojlik_sabab, yordam_turi, yordam_miqdor, muhtojlik_daraja, kiritilgan_sana,
      tekshirgan, tekshirilgan_sana, izoh, holat, hudud, keyingi_korib_chiqish, hujjat_path,
      created_by
    ) values (
      v_kod, v_fio, nullif(btrim(coalesce(p->>'telefon', '')), ''),
      nullif(btrim(coalesce(p->>'manzil', '')), ''), nullif(btrim(coalesce(p->>'tavsiya', '')), ''),
      nullif(btrim(coalesce(p->>'oilaviy_holat', '')), ''), nullif(btrim(coalesce(p->>'uyjoy_holat', '')), ''),
      nullif(p->>'oylik_daromad', '')::numeric,
      nullif(btrim(coalesce(p->>'muhtojlik_sabab', '')), ''), nullif(btrim(coalesce(p->>'yordam_turi', '')), ''),
      nullif(btrim(coalesce(p->>'yordam_miqdor', '')), ''), v_muhtojlik,
      coalesce(nullif(p->>'kiritilgan_sana', '')::date, (now() at time zone 'Asia/Tashkent')::date),
      nullif(btrim(coalesce(p->>'tekshirgan', '')), ''), nullif(p->>'tekshirilgan_sana', '')::date,
      nullif(btrim(coalesce(p->>'izoh', '')), ''), v_holat, nullif(btrim(coalesce(p->>'hudud', '')), ''),
      nullif(p->>'keyingi_korib_chiqish', '')::date, nullif(btrim(coalesce(p->>'hujjat_path', '')), ''),
      v_uid
    )
    returning id into v_id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'kod', 'takror');
  end;

  perform _ehson_tarix_yoz('oila', v_id, 'yaratildi', p);
  return jsonb_build_object('ok', true, 'id', v_id, 'oila_kod', v_kod);
end
$fn$;

revoke all on function ehson_oila_saqla(jsonb) from public, anon;
grant execute on function ehson_oila_saqla(jsonb) to authenticated;


-- 8.5 ehson_azo_saqla(p) — insert (ehson user) / update (admin).
create or replace function ehson_azo_saqla(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_id   uuid := nullif(p->>'id', '')::uuid;
  v_oila uuid := nullif(p->>'oila_id', '')::uuid;
  v_kod  text;
  v_fio  text := nullif(btrim(coalesce(p->>'fio', '')), '');
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;
  if v_fio is null then
    return jsonb_build_object('ok', false, 'kod', 'fio_kerak');
  end if;

  if v_id is not null then
    if not _ehson_is_admin() then
      raise exception 'Faqat admin azo malumotini tahrirlashi mumkin' using errcode = '42501';
    end if;
    if not exists (select 1 from ehson_azo where id = v_id) then
      return jsonb_build_object('ok', false, 'kod', 'topilmadi');
    end if;

    update ehson_azo set
      qarindosh     = nullif(btrim(coalesce(p->>'qarindosh', '')), ''),
      fio           = v_fio,
      tugilgan_sana = nullif(p->>'tugilgan_sana', '')::date,
      sogliq        = nullif(btrim(coalesce(p->>'sogliq', '')), ''),
      sogliq_izoh   = nullif(btrim(coalesce(p->>'sogliq_izoh', '')), ''),
      ish_oqish     = nullif(btrim(coalesce(p->>'ish_oqish', '')), ''),
      kasb_sinf     = nullif(btrim(coalesce(p->>'kasb_sinf', '')), ''),
      oylik_daromad = nullif(p->>'oylik_daromad', '')::numeric,
      qaramogida    = coalesce((p->>'qaramogida')::boolean, false),
      izoh          = nullif(btrim(coalesce(p->>'izoh', '')), '')
    where id = v_id;

    perform _ehson_tarix_yoz('azo', v_id, 'yangilandi', p);
    return jsonb_build_object('ok', true, 'id', v_id);
  end if;

  if v_oila is null or not exists (select 1 from ehson_oila where id = v_oila) then
    return jsonb_build_object('ok', false, 'kod', 'oila_topilmadi');
  end if;

  v_kod := nullif(btrim(coalesce(p->>'azo_kod', '')), '');
  if v_kod is null then
    v_kod := _ehson_kod_next('azo', v_oila);
  end if;

  begin
    insert into ehson_azo (
      oila_id, azo_kod, qarindosh, fio, tugilgan_sana, sogliq, sogliq_izoh,
      ish_oqish, kasb_sinf, oylik_daromad, qaramogida, izoh
    ) values (
      v_oila, v_kod, nullif(btrim(coalesce(p->>'qarindosh', '')), ''), v_fio,
      nullif(p->>'tugilgan_sana', '')::date, nullif(btrim(coalesce(p->>'sogliq', '')), ''),
      nullif(btrim(coalesce(p->>'sogliq_izoh', '')), ''), nullif(btrim(coalesce(p->>'ish_oqish', '')), ''),
      nullif(btrim(coalesce(p->>'kasb_sinf', '')), ''), nullif(p->>'oylik_daromad', '')::numeric,
      coalesce((p->>'qaramogida')::boolean, false), nullif(btrim(coalesce(p->>'izoh', '')), '')
    )
    returning id into v_id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'kod', 'takror');
  end;

  perform _ehson_tarix_yoz('azo', v_id, 'yaratildi', p);
  return jsonb_build_object('ok', true, 'id', v_id, 'azo_kod', v_kod);
end
$fn$;

revoke all on function ehson_azo_saqla(jsonb) from public, anon;
grant execute on function ehson_azo_saqla(jsonb) to authenticated;


-- 8.6 ehson_azo_ochir(p_id) — admin, qattiq o'chirish (tarixga nusxa yoziladi).
create or replace function ehson_azo_ochir(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row ehson_azo;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not _ehson_is_admin() then
    raise exception 'Faqat admin azoni ochira oladi' using errcode = '42501';
  end if;

  select * into v_row from ehson_azo where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi');
  end if;

  perform _ehson_tarix_yoz('azo', p_id, 'ochirildi', to_jsonb(v_row));
  delete from ehson_azo where id = p_id;

  return jsonb_build_object('ok', true);
end
$fn$;

revoke all on function ehson_azo_ochir(uuid) from public, anon;
grant execute on function ehson_azo_ochir(uuid) to authenticated;


-- 8.7 ehson_import(p) — admin. {oilalar:[...], azolar:[...]} upsert kod bo'yicha.
create or replace function ehson_import(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid              uuid  := auth.uid();
  v_oilalar          jsonb := coalesce(p->'oilalar', '[]'::jsonb);
  v_azolar           jsonb := coalesce(p->'azolar', '[]'::jsonb);
  r                  jsonb;
  v_kod              text;
  v_id               uuid;
  v_oila_id          uuid;
  v_oila_yangi       int := 0;
  v_oila_yangilandi  int := 0;
  v_azo_yangi        int := 0;
  v_azo_yangilandi   int := 0;
  v_xato             jsonb := '[]'::jsonb;
  v_i                int := 0;
  v_muhtojlik        text;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not _ehson_is_admin() then
    raise exception 'Faqat admin import qila oladi' using errcode = '42501';
  end if;
  if jsonb_typeof(v_oilalar) <> 'array' or jsonb_typeof(v_azolar) <> 'array' then
    return jsonb_build_object('ok', false, 'kod', 'shakl_notogri');
  end if;
  if jsonb_array_length(v_oilalar) > 500 then
    return jsonb_build_object('ok', false, 'kod', 'oila_kop', 'limit', 500);
  end if;
  if jsonb_array_length(v_azolar) > 2000 then
    return jsonb_build_object('ok', false, 'kod', 'azo_kop', 'limit', 2000);
  end if;

  for r in select * from jsonb_array_elements(v_oilalar)
  loop
    v_i := v_i + 1;
    begin
      v_kod := nullif(btrim(coalesce(r->>'oila_kod', '')), '');
      if v_kod is null then
        v_xato := v_xato || jsonb_build_object('varaq', 'Oilalar', 'qator', v_i, 'sabab', 'oila_kod bo''sh');
        continue;
      end if;
      if nullif(btrim(coalesce(r->>'fio', '')), '') is null then
        v_xato := v_xato || jsonb_build_object('varaq', 'Oilalar', 'qator', v_i, 'sabab', 'fio bo''sh');
        continue;
      end if;
      v_muhtojlik := nullif(r->>'muhtojlik_daraja', '');
      if v_muhtojlik is not null and v_muhtojlik not in ('yuqori','orta','past') then
        v_xato := v_xato || jsonb_build_object('varaq', 'Oilalar', 'qator', v_i, 'sabab', 'muhtojlik_daraja notogri');
        continue;
      end if;

      select id into v_id from ehson_oila where oila_kod = v_kod;
      if found then
        update ehson_oila set
          fio               = btrim(r->>'fio'),
          telefon           = coalesce(nullif(btrim(coalesce(r->>'telefon', '')), ''), telefon),
          manzil            = coalesce(nullif(btrim(coalesce(r->>'manzil', '')), ''), manzil),
          tavsiya           = coalesce(nullif(btrim(coalesce(r->>'tavsiya', '')), ''), tavsiya),
          oilaviy_holat     = coalesce(nullif(btrim(coalesce(r->>'oilaviy_holat', '')), ''), oilaviy_holat),
          uyjoy_holat       = coalesce(nullif(btrim(coalesce(r->>'uyjoy_holat', '')), ''), uyjoy_holat),
          oylik_daromad     = coalesce(nullif(r->>'oylik_daromad', '')::numeric, oylik_daromad),
          muhtojlik_sabab   = coalesce(nullif(btrim(coalesce(r->>'muhtojlik_sabab', '')), ''), muhtojlik_sabab),
          yordam_turi       = coalesce(nullif(btrim(coalesce(r->>'yordam_turi', '')), ''), yordam_turi),
          yordam_miqdor     = coalesce(nullif(btrim(coalesce(r->>'yordam_miqdor', '')), ''), yordam_miqdor),
          muhtojlik_daraja  = coalesce(v_muhtojlik, muhtojlik_daraja),
          kiritilgan_sana   = coalesce(nullif(r->>'kiritilgan_sana', '')::date, kiritilgan_sana),
          tekshirgan        = coalesce(nullif(btrim(coalesce(r->>'tekshirgan', '')), ''), tekshirgan),
          tekshirilgan_sana = coalesce(nullif(r->>'tekshirilgan_sana', '')::date, tekshirilgan_sana),
          izoh              = coalesce(nullif(btrim(coalesce(r->>'izoh', '')), ''), izoh),
          hudud             = coalesce(nullif(btrim(coalesce(r->>'hudud', '')), ''), hudud),
          updated_by        = v_uid
        where id = v_id;
        v_oila_yangilandi := v_oila_yangilandi + 1;
      else
        insert into ehson_oila (
          oila_kod, fio, telefon, manzil, tavsiya, oilaviy_holat, uyjoy_holat, oylik_daromad,
          muhtojlik_sabab, yordam_turi, yordam_miqdor, muhtojlik_daraja, kiritilgan_sana,
          tekshirgan, tekshirilgan_sana, izoh, hudud, created_by
        ) values (
          v_kod, btrim(r->>'fio'), nullif(btrim(coalesce(r->>'telefon', '')), ''),
          nullif(btrim(coalesce(r->>'manzil', '')), ''), nullif(btrim(coalesce(r->>'tavsiya', '')), ''),
          nullif(btrim(coalesce(r->>'oilaviy_holat', '')), ''), nullif(btrim(coalesce(r->>'uyjoy_holat', '')), ''),
          nullif(r->>'oylik_daromad', '')::numeric,
          nullif(btrim(coalesce(r->>'muhtojlik_sabab', '')), ''), nullif(btrim(coalesce(r->>'yordam_turi', '')), ''),
          nullif(btrim(coalesce(r->>'yordam_miqdor', '')), ''), v_muhtojlik,
          coalesce(nullif(r->>'kiritilgan_sana', '')::date, (now() at time zone 'Asia/Tashkent')::date),
          nullif(btrim(coalesce(r->>'tekshirgan', '')), ''), nullif(r->>'tekshirilgan_sana', '')::date,
          nullif(btrim(coalesce(r->>'izoh', '')), ''), nullif(btrim(coalesce(r->>'hudud', '')), ''), v_uid
        );
        v_oila_yangi := v_oila_yangi + 1;
      end if;
    exception when others then
      v_xato := v_xato || jsonb_build_object('varaq', 'Oilalar', 'qator', v_i, 'sabab', sqlstate || ': import xatosi');
    end;
  end loop;

  v_i := 0;
  for r in select * from jsonb_array_elements(v_azolar)
  loop
    v_i := v_i + 1;
    begin
      v_kod := nullif(btrim(coalesce(r->>'oila_kod', '')), '');
      if v_kod is null then
        v_xato := v_xato || jsonb_build_object('varaq', 'Oila a''zolari', 'qator', v_i, 'sabab', 'oila_kod bo''sh');
        continue;
      end if;
      select id into v_oila_id from ehson_oila where oila_kod = v_kod;
      if not found then
        v_xato := v_xato || jsonb_build_object('varaq', 'Oila a''zolari', 'qator', v_i, 'sabab', 'oila topilmadi: ' || v_kod);
        continue;
      end if;
      if nullif(btrim(coalesce(r->>'fio', '')), '') is null then
        v_xato := v_xato || jsonb_build_object('varaq', 'Oila a''zolari', 'qator', v_i, 'sabab', 'fio bo''sh');
        continue;
      end if;

      v_kod := nullif(btrim(coalesce(r->>'azo_kod', '')), '');
      if v_kod is null then
        v_kod := _ehson_kod_next('azo', v_oila_id);
      end if;

      select id into v_id from ehson_azo where oila_id = v_oila_id and azo_kod = v_kod;
      if found then
        update ehson_azo set
          qarindosh     = coalesce(nullif(btrim(coalesce(r->>'qarindosh', '')), ''), qarindosh),
          fio           = btrim(r->>'fio'),
          tugilgan_sana = coalesce(nullif(r->>'tugilgan_sana', '')::date, tugilgan_sana),
          sogliq        = coalesce(nullif(btrim(coalesce(r->>'sogliq', '')), ''), sogliq),
          sogliq_izoh   = coalesce(nullif(btrim(coalesce(r->>'sogliq_izoh', '')), ''), sogliq_izoh),
          ish_oqish     = coalesce(nullif(btrim(coalesce(r->>'ish_oqish', '')), ''), ish_oqish),
          kasb_sinf     = coalesce(nullif(btrim(coalesce(r->>'kasb_sinf', '')), ''), kasb_sinf),
          oylik_daromad = coalesce(nullif(r->>'oylik_daromad', '')::numeric, oylik_daromad),
          qaramogida    = coalesce((r->>'qaramogida')::boolean, qaramogida),
          izoh          = coalesce(nullif(btrim(coalesce(r->>'izoh', '')), ''), izoh)
        where id = v_id;
        v_azo_yangilandi := v_azo_yangilandi + 1;
      else
        insert into ehson_azo (
          oila_id, azo_kod, qarindosh, fio, tugilgan_sana, sogliq, sogliq_izoh,
          ish_oqish, kasb_sinf, oylik_daromad, qaramogida, izoh
        ) values (
          v_oila_id, v_kod, nullif(btrim(coalesce(r->>'qarindosh', '')), ''), btrim(r->>'fio'),
          nullif(r->>'tugilgan_sana', '')::date, nullif(btrim(coalesce(r->>'sogliq', '')), ''),
          nullif(btrim(coalesce(r->>'sogliq_izoh', '')), ''), nullif(btrim(coalesce(r->>'ish_oqish', '')), ''),
          nullif(btrim(coalesce(r->>'kasb_sinf', '')), ''), nullif(r->>'oylik_daromad', '')::numeric,
          coalesce((r->>'qaramogida')::boolean, false), nullif(btrim(coalesce(r->>'izoh', '')), '')
        );
        v_azo_yangi := v_azo_yangi + 1;
      end if;
    exception when others then
      v_xato := v_xato || jsonb_build_object('varaq', 'Oila a''zolari', 'qator', v_i, 'sabab', sqlstate || ': import xatosi');
    end;
  end loop;

  perform _ehson_tarix_yoz('oila', null, 'import', jsonb_build_object(
    'oila_yangi', v_oila_yangi, 'oila_yangilandi', v_oila_yangilandi,
    'azo_yangi', v_azo_yangi, 'azo_yangilandi', v_azo_yangilandi,
    'xato_soni', jsonb_array_length(v_xato)
  ));

  return jsonb_build_object(
    'ok', true,
    'oila_yangi', v_oila_yangi, 'oila_yangilandi', v_oila_yangilandi,
    'azo_yangi', v_azo_yangi, 'azo_yangilandi', v_azo_yangilandi,
    'xato', v_xato
  );
end
$fn$;

revoke all on function ehson_import(jsonb) from public, anon;
grant execute on function ehson_import(jsonb) to authenticated;


-- 8.8 ehson_ber(p) — berish. Fail-closed: izoh<3, qoldiq yetmasa, oila yopiq.
create or replace function ehson_ber(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid    := auth.uid();
  v_oila   uuid    := nullif(p->>'oila_id', '')::uuid;
  v_kassa  uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_summa  numeric := nullif(p->>'summa', '')::numeric;
  v_sana   date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_tur    text    := nullif(p->>'tur', '');
  v_izoh   text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_reja   uuid    := nullif(p->>'reja_id', '')::uuid;
  v_kkch   date    := nullif(p->>'keyingi_korib_chiqish', '')::date;
  v_ext    text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  v_oila_r ehson_oila;
  v_qoldiq numeric;
  v_id     uuid;
  v_exist  uuid;
  v_cnt    int;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  if v_ext is not null then
    select id into v_exist from ehson_berish where ext_ref = v_ext;
    if found then
      return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
    end if;
  end if;

  if v_oila is null then
    return jsonb_build_object('ok', false, 'kod', 'oila_kerak');
  end if;
  select * into v_oila_r from ehson_oila where id = v_oila;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'oila_topilmadi');
  end if;
  if v_oila_r.holat = 'yopildi' then
    return jsonb_build_object('ok', false, 'kod', 'oila_yopiq');
  end if;
  if v_summa is null or v_summa <= 0 then
    return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
  end if;
  if v_tur is null or v_tur not in ('pul','oziq_ovqat','kiyim','dori','boshqa') then
    return jsonb_build_object('ok', false, 'kod', 'tur_notogri');
  end if;
  if v_izoh is null or length(v_izoh) < 3 then
    return jsonb_build_object('ok', false, 'kod', 'izoh_kerak');
  end if;
  if v_reja is not null and not exists (select 1 from ehson_reja where id = v_reja and oila_id = v_oila) then
    return jsonb_build_object('ok', false, 'kod', 'reja_topilmadi');
  end if;

  if v_kassa is null then
    select count(*) into v_cnt from ehson_kassa where is_active;
    if v_cnt <> 1 then
      return jsonb_build_object('ok', false, 'kod', 'kassa_tanlanmagan');
    end if;
    select id into v_kassa from ehson_kassa where is_active limit 1;
  end if;
  if not exists (select 1 from ehson_kassa where id = v_kassa and is_active) then
    return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi');
  end if;

  perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || v_kassa::text));

  select qoldiq into v_qoldiq from v_ehson_kassa where id = v_kassa;
  if coalesce(v_qoldiq, 0) < v_summa then
    return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi');
  end if;

  insert into ehson_berish (
    oila_id, kassa_id, summa, sana, tur, izoh, reja_id, holat,
    keyingi_korib_chiqish, created_by, ext_ref
  ) values (
    v_oila, v_kassa, v_summa, v_sana, v_tur, v_izoh, v_reja, 'berildi',
    v_kkch, v_uid, v_ext
  )
  returning id into v_id;

  perform _ehson_tarix_yoz('berish', v_id, 'yaratildi',
    jsonb_build_object('oila_id', v_oila, 'summa', v_summa, 'tur', v_tur));

  return jsonb_build_object('ok', true, 'id', v_id);
exception when unique_violation then
  select id into v_exist from ehson_berish where ext_ref = v_ext;
  return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;

revoke all on function ehson_ber(jsonb) from public, anon;
grant execute on function ehson_ber(jsonb) to authenticated;


-- 8.9 ehson_berish_bekor(p_id, p_sabab) — admin, sabab majburiy.
create or replace function ehson_berish_bekor(p_id uuid, p_sabab text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_row   ehson_berish;
  v_sabab text := nullif(btrim(coalesce(p_sabab, '')), '');
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not _ehson_is_admin() then
    raise exception 'Faqat admin bekor qila oladi' using errcode = '42501';
  end if;
  if v_sabab is null then
    return jsonb_build_object('ok', false, 'kod', 'sabab_kerak');
  end if;

  select * into v_row from ehson_berish where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi');
  end if;
  if v_row.holat = 'bekor' then
    return jsonb_build_object('ok', false, 'kod', 'allaqachon_bekor');
  end if;

  update ehson_berish set
    holat = 'bekor', is_deleted = true, deleted_by = v_uid, deleted_at = now(), bekor_sabab = v_sabab
  where id = p_id;

  perform _ehson_tarix_yoz('berish', p_id, 'bekor', jsonb_build_object('sabab', v_sabab));

  return jsonb_build_object('ok', true);
end
$fn$;

revoke all on function ehson_berish_bekor(uuid, text) from public, anon;
grant execute on function ehson_berish_bekor(uuid, text) to authenticated;


-- 8.10 ehson_reja_saqla(p) — yangi reja, eski faol reja avtomat to'xtaydi.
create or replace function ehson_reja_saqla(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid    := auth.uid();
  v_oila  uuid    := nullif(p->>'oila_id', '')::uuid;
  v_summa numeric := nullif(p->>'oylik_summa', '')::numeric;
  v_bosh  date    := nullif(p->>'boshlanish', '')::date;
  v_n     int     := nullif(p->>'oylar_soni', '')::int;
  v_izoh  text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_tugash date;
  v_id     uuid;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;
  if v_oila is null or not exists (select 1 from ehson_oila where id = v_oila) then
    return jsonb_build_object('ok', false, 'kod', 'oila_topilmadi');
  end if;
  if v_summa is null or v_summa <= 0 then
    return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
  end if;
  if v_bosh is null then
    return jsonb_build_object('ok', false, 'kod', 'boshlanish_kerak');
  end if;
  if v_n is not null and v_n <= 0 then
    return jsonb_build_object('ok', false, 'kod', 'oylar_soni_notogri');
  end if;

  v_bosh := date_trunc('month', v_bosh)::date;
  if v_n is not null then
    v_tugash := (date_trunc('month', v_bosh) + (v_n || ' months')::interval - interval '1 day')::date;
  else
    v_tugash := null;
  end if;

  update ehson_reja set holat = 'toxtatildi', toxtatilgan_at = now(), toxtat_sabab = 'Yangi reja yaratildi'
   where oila_id = v_oila and holat = 'faol';

  insert into ehson_reja (oila_id, oylik_summa, boshlanish, oylar_soni, tugash, holat, izoh, created_by)
  values (v_oila, v_summa, v_bosh, v_n, v_tugash, 'faol', v_izoh, v_uid)
  returning id into v_id;

  perform _ehson_tarix_yoz('reja', v_id, 'yaratildi',
    jsonb_build_object('oila_id', v_oila, 'oylik_summa', v_summa, 'boshlanish', v_bosh, 'oylar_soni', v_n));

  return jsonb_build_object('ok', true, 'id', v_id, 'tugash', v_tugash);
end
$fn$;

revoke all on function ehson_reja_saqla(jsonb) from public, anon;
grant execute on function ehson_reja_saqla(jsonb) to authenticated;


-- 8.11 ehson_reja_toxtat(p_id, p_sabab) — admin.
create or replace function ehson_reja_toxtat(p_id uuid, p_sabab text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row ehson_reja;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not _ehson_is_admin() then
    raise exception 'Faqat admin toxtata oladi' using errcode = '42501';
  end if;

  select * into v_row from ehson_reja where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi');
  end if;
  if v_row.holat <> 'faol' then
    return jsonb_build_object('ok', false, 'kod', 'faol_emas');
  end if;

  update ehson_reja set
    holat = 'toxtatildi', toxtatilgan_at = now(), toxtat_sabab = nullif(btrim(coalesce(p_sabab, '')), '')
  where id = p_id;

  perform _ehson_tarix_yoz('reja', p_id, 'toxtatildi', jsonb_build_object('sabab', p_sabab));

  return jsonb_build_object('ok', true);
end
$fn$;

revoke all on function ehson_reja_toxtat(uuid, text) from public, anon;
grant execute on function ehson_reja_toxtat(uuid, text) to authenticated;


-- 8.12 ehson_oy(p_oy) — joriy oy sukut. Reja vs fakt + rejadan tashqari.
create or replace function ehson_oy(p_oy date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid              uuid := auth.uid();
  v_oy               date := date_trunc('month', coalesce(p_oy, (now() at time zone 'Asia/Tashkent')::date))::date;
  v_rows             jsonb;
  v_rejadan_tashqari jsonb;
  v_jami_reja        numeric;
  v_jami_fakt        numeric;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'oila_id', oila_id, 'oila_kod', oila_kod, 'fio', fio,
           'reja_id', reja_id, 'reja_summa', reja_summa, 'fakt_summa', fakt_summa,
           'farq', farq, 'holat', holat
         ) order by fio), '[]'::jsonb),
         coalesce(sum(reja_summa), 0), coalesce(sum(fakt_summa), 0)
    into v_rows, v_jami_reja, v_jami_fakt
    from v_ehson_oy
   where oy = v_oy;

  select coalesce(jsonb_agg(jsonb_build_object(
           'oila_id', b.oila_id, 'oila_kod', o.oila_kod, 'fio', o.fio,
           'summa', b.summa, 'sana', b.sana, 'tur', b.tur
         ) order by b.sana), '[]'::jsonb)
    into v_rejadan_tashqari
    from ehson_berish b
    join ehson_oila o on o.id = b.oila_id
   where b.holat = 'berildi'
     and b.reja_id is null
     and date_trunc('month', b.sana) = v_oy;

  return jsonb_build_object(
    'oy', v_oy, 'rows', v_rows, 'jami_reja', v_jami_reja, 'jami_fakt', v_jami_fakt,
    'rejadan_tashqari', v_rejadan_tashqari
  );
end
$fn$;

revoke all on function ehson_oy(date) from public, anon;
grant execute on function ehson_oy(date) to authenticated;


-- 8.13 ehson_oila_kart(p_id) — oila kartasi: to'liq ma'lumot.
create or replace function ehson_oila_kart(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_oila   ehson_oila;
  v_azolar jsonb;
  v_berish jsonb;
  v_reja   jsonb;
  v_tarix  jsonb;
  v_jami   jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  select * into v_oila from ehson_oila where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi');
  end if;

  select coalesce(jsonb_agg(to_jsonb(v) order by v.tugilgan_sana nulls last), '[]'::jsonb)
    into v_azolar from v_ehson_azo v where v.oila_id = p_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'summa', b.summa, 'sana', b.sana, 'tur', b.tur, 'izoh', b.izoh,
           'holat', b.holat, 'reja_id', b.reja_id, 'bekor_sabab', b.bekor_sabab
         ) order by b.sana desc), '[]'::jsonb)
    into v_berish from ehson_berish b where b.oila_id = p_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'oylik_summa', oylik_summa, 'boshlanish', boshlanish,
           'oylar_soni', oylar_soni, 'tugash', tugash, 'holat', holat, 'izoh', izoh
         ) order by created_at desc), '[]'::jsonb)
    into v_reja from ehson_reja where oila_id = p_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'obyekt', t.obyekt, 'hodisa', t.hodisa, 'data', t.data, 'vaqt', t.vaqt
         ) order by t.vaqt desc), '[]'::jsonb)
    into v_tarix
    from (
      select obyekt, hodisa, data, vaqt from ehson_tarix
       where obyekt_id = p_id
          or obyekt_id in (select id from ehson_azo where oila_id = p_id)
          or obyekt_id in (select id from ehson_berish where oila_id = p_id)
          or obyekt_id in (select id from ehson_reja where oila_id = p_id)
       order by vaqt desc
       limit 50
    ) t;

  select to_jsonb(j) into v_jami from v_ehson_oila_jami j where j.oila_id = p_id;

  return jsonb_build_object(
    'ok', true,
    'oila', to_jsonb(v_oila),
    'jami', v_jami,
    'azolar', v_azolar,
    'berishlar', v_berish,
    'rejalar', v_reja,
    'tarix', v_tarix
  );
end
$fn$;

revoke all on function ehson_oila_kart(uuid) from public, anon;
grant execute on function ehson_oila_kart(uuid) to authenticated;


-- 8.14 ehson_royxat(p) — qidiruv + filtr + sahifalash.
create or replace function ehson_royxat(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid    := auth.uid();
  v_q      text    := nullif(btrim(coalesce(p->>'q', '')), '');
  v_muh    text    := nullif(p->>'muhtojlik', '');
  v_holat  text    := nullif(p->>'holat', '');
  v_hudud  text    := nullif(p->>'hudud', '');
  v_rejali boolean := coalesce((p->>'faqat_rejali')::boolean, false);
  v_limit  int     := greatest(1, least(coalesce(nullif(p->>'limit', '')::int, 50), 200));
  v_offset int     := greatest(0, coalesce(nullif(p->>'offset', '')::int, 0));
  v_rows   jsonb;
  v_jami   int;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  select count(*) into v_jami
    from ehson_oila o
   where (v_q is null or o.fio ilike '%' || v_q || '%' or o.oila_kod ilike '%' || v_q || '%'
                       or o.telefon ilike '%' || v_q || '%')
     and (v_muh is null or o.muhtojlik_daraja = v_muh)
     and (v_holat is null or o.holat = v_holat)
     and (v_hudud is null or o.hudud = v_hudud)
     and (not v_rejali or exists (select 1 from ehson_reja r where r.oila_id = o.id and r.holat = 'faol'));

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.id, 'oila_kod', o.oila_kod, 'fio', o.fio, 'telefon', o.telefon,
           'muhtojlik_daraja', o.muhtojlik_daraja, 'holat', o.holat, 'hudud', o.hudud,
           'keyingi_korib_chiqish', o.keyingi_korib_chiqish,
           'azo_soni', j.azo_soni, 'bola_soni', j.bola_soni, 'qaramog_soni', j.qaramog_soni,
           'jami_olgan', j.jami_olgan, 'oxirgi_sana', j.oxirgi_sana, 'faol_reja_summa', j.faol_reja_summa
         ) order by o.fio), '[]'::jsonb)
    into v_rows
    from (
      select * from ehson_oila o
       where (v_q is null or o.fio ilike '%' || v_q || '%' or o.oila_kod ilike '%' || v_q || '%'
                           or o.telefon ilike '%' || v_q || '%')
         and (v_muh is null or o.muhtojlik_daraja = v_muh)
         and (v_holat is null or o.holat = v_holat)
         and (v_hudud is null or o.hudud = v_hudud)
         and (not v_rejali or exists (select 1 from ehson_reja r where r.oila_id = o.id and r.holat = 'faol'))
       order by o.fio
       limit v_limit offset v_offset
    ) o
    left join v_ehson_oila_jami j on j.oila_id = o.id;

  return jsonb_build_object('rows', coalesce(v_rows, '[]'::jsonb), 'jami', v_jami);
end
$fn$;

revoke all on function ehson_royxat(jsonb) from public, anon;
grant execute on function ehson_royxat(jsonb) to authenticated;


-- #####################################################################
-- ##  9-BOLIM — bucket `ehson-hujjat` + storage policy                ##
-- #####################################################################
-- Naqsh: qarz-tilxat (PROVODKA_QARZ.sql 9-BOLIM). Yo'l: <oila_id>/....
-- select — ehson_page_ok(); insert/update — faqat admin.
-- #####################################################################

insert into storage.buckets (id, name, public)
values ('ehson-hujjat', 'ehson-hujjat', false)
on conflict (id) do nothing;

create or replace function ehson_hujjat_yol_ok(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if (storage.foldername(p_name))[1] ~ '^[0-9a-fA-F-]{36}$' then
    return exists (select 1 from ehson_oila where id = (storage.foldername(p_name))[1]::uuid);
  end if;
  return false;
end
$fn$;

revoke all on function ehson_hujjat_yol_ok(text) from public, anon;
grant execute on function ehson_hujjat_yol_ok(text) to authenticated;

comment on function ehson_hujjat_yol_ok(text) is
  'Storage RLS uchun: <oila_id>/... shaklidagi yo''l, oila mavjud bo''lsa true. Notanish shakl -> false (fail-closed).';

drop policy if exists "ehson_hujjat_select" on storage.objects;
create policy "ehson_hujjat_select" on storage.objects
  for select to authenticated
  using (bucket_id = 'ehson-hujjat' and ehson_page_ok());

drop policy if exists "ehson_hujjat_insert" on storage.objects;
create policy "ehson_hujjat_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'ehson-hujjat' and _ehson_is_admin() and ehson_hujjat_yol_ok(name));

drop policy if exists "ehson_hujjat_update" on storage.objects;
create policy "ehson_hujjat_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'ehson-hujjat' and _ehson_is_admin() and ehson_hujjat_yol_ok(name))
  with check (bucket_id = 'ehson-hujjat' and _ehson_is_admin() and ehson_hujjat_yol_ok(name));


-- #####################################################################
-- ##  10-BOLIM — PostgREST sxema keshi                                ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  11-BOLIM — YAKUNIY TEKSHIRUV (faqat select)                     ##
-- #####################################################################

do $ehson_check$
declare
  v_n int;
begin
  -- 11.1 perm_pages() 18 ta va 'ehson' bor
  if array_length(perm_pages(), 1) <> 18 then
    raise exception 'perm_pages() 18 ta bulishi kerak, hozir: %', array_length(perm_pages(), 1);
  end if;
  if not ('ehson' = any(perm_pages())) then
    raise exception 'perm_pages() da ehson kaliti yoq';
  end if;

  -- 11.2 Jadvallar
  if to_regclass('public.ehson_kassa')  is null then raise exception 'ehson_kassa yaratilmadi';  end if;
  if to_regclass('public.ehson_oila')   is null then raise exception 'ehson_oila yaratilmadi';   end if;
  if to_regclass('public.ehson_reja')   is null then raise exception 'ehson_reja yaratilmadi';   end if;
  if to_regclass('public.ehson_azo')    is null then raise exception 'ehson_azo yaratilmadi';    end if;
  if to_regclass('public.ehson_kirim')  is null then raise exception 'ehson_kirim yaratilmadi';  end if;
  if to_regclass('public.ehson_berish') is null then raise exception 'ehson_berish yaratilmadi'; end if;
  if to_regclass('public.ehson_tarix')  is null then raise exception 'ehson_tarix yaratilmadi';  end if;

  -- 11.3 Seed
  if not exists (select 1 from ehson_kassa) then
    raise exception 'ehson_kassa seed qatori yoq';
  end if;

  -- 11.4 RLS yoqilgan
  if not (select relrowsecurity from pg_class where oid = 'public.ehson_kassa'::regclass)  then raise exception 'ehson_kassa da RLS yoqilmagan';  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.ehson_oila'::regclass)   then raise exception 'ehson_oila da RLS yoqilmagan';   end if;
  if not (select relrowsecurity from pg_class where oid = 'public.ehson_reja'::regclass)   then raise exception 'ehson_reja da RLS yoqilmagan';   end if;
  if not (select relrowsecurity from pg_class where oid = 'public.ehson_azo'::regclass)    then raise exception 'ehson_azo da RLS yoqilmagan';    end if;
  if not (select relrowsecurity from pg_class where oid = 'public.ehson_kirim'::regclass)  then raise exception 'ehson_kirim da RLS yoqilmagan';  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.ehson_berish'::regclass) then raise exception 'ehson_berish da RLS yoqilmagan'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.ehson_tarix'::regclass)  then raise exception 'ehson_tarix da RLS yoqilmagan';  end if;

  -- 11.5 Har jadvalda FAQAT bitta (select) policy bor — insert/update/delete YO'Q
  select count(*) into v_n from pg_policies
   where schemaname = 'public' and tablename in
     ('ehson_kassa','ehson_oila','ehson_reja','ehson_azo','ehson_kirim','ehson_berish','ehson_tarix');
  if v_n <> 7 then
    raise exception 'ehson_* jadvallarda policy soni notogri (kutilgan 7, hozir %) — faqat SELECT policy bulishi kerak', v_n;
  end if;

  -- 11.6 Viewlar
  if to_regclass('public.v_ehson_kassa')     is null then raise exception 'v_ehson_kassa yaratilmadi';     end if;
  if to_regclass('public.v_ehson_azo')       is null then raise exception 'v_ehson_azo yaratilmadi';       end if;
  if to_regclass('public.v_ehson_oila_jami') is null then raise exception 'v_ehson_oila_jami yaratilmadi'; end if;
  if to_regclass('public.v_ehson_oy')        is null then raise exception 'v_ehson_oy yaratilmadi';        end if;

  -- 11.7 Funksiyalar (imzo bo'yicha)
  if to_regprocedure('public.ehson_page_ok()')                is null then raise exception 'ehson_page_ok() yaratilmadi'; end if;
  if to_regprocedure('public._ehson_is_admin()')               is null then raise exception '_ehson_is_admin() yaratilmadi'; end if;
  if to_regprocedure('public._ehson_tarix_yoz(text, uuid, text, jsonb)') is null then raise exception '_ehson_tarix_yoz(...) yaratilmadi'; end if;
  if to_regprocedure('public._ehson_kod_next(text, uuid)')     is null then raise exception '_ehson_kod_next(text,uuid) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_dash()')                    is null then raise exception 'ehson_dash() yaratilmadi'; end if;
  if to_regprocedure('public.ehson_kirim_yoz(jsonb)')          is null then raise exception 'ehson_kirim_yoz(jsonb) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_kirim_bekor(uuid, text)')   is null then raise exception 'ehson_kirim_bekor(uuid,text) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_oila_saqla(jsonb)')         is null then raise exception 'ehson_oila_saqla(jsonb) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_azo_saqla(jsonb)')          is null then raise exception 'ehson_azo_saqla(jsonb) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_azo_ochir(uuid)')           is null then raise exception 'ehson_azo_ochir(uuid) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_import(jsonb)')             is null then raise exception 'ehson_import(jsonb) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_ber(jsonb)')                is null then raise exception 'ehson_ber(jsonb) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_berish_bekor(uuid, text)')  is null then raise exception 'ehson_berish_bekor(uuid,text) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_reja_saqla(jsonb)')         is null then raise exception 'ehson_reja_saqla(jsonb) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_reja_toxtat(uuid, text)')   is null then raise exception 'ehson_reja_toxtat(uuid,text) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_oy(date)')                  is null then raise exception 'ehson_oy(date) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_oila_kart(uuid)')           is null then raise exception 'ehson_oila_kart(uuid) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_royxat(jsonb)')             is null then raise exception 'ehson_royxat(jsonb) yaratilmadi'; end if;
  if to_regprocedure('public.ehson_hujjat_yol_ok(text)')       is null then raise exception 'ehson_hujjat_yol_ok(text) yaratilmadi'; end if;

  -- 11.8 GRANT/REVOKE tekshiruvi (namuna)
  if not has_function_privilege('authenticated', 'public.ehson_page_ok()', 'execute') then
    raise exception 'ehson_page_ok() authenticated uchun yopiq — RLS SELECT hammaga 42501 berardi';
  end if;
  if not has_function_privilege('authenticated', 'public.ehson_ber(jsonb)', 'execute') then
    raise exception 'ehson_ber(jsonb) authenticated uchun yopiq — UI ishlamaydi';
  end if;
  if has_function_privilege('anon', 'public.ehson_ber(jsonb)', 'execute') then
    raise exception 'ehson_ber(jsonb) anon uchun ochiq qolgan';
  end if;
  if has_function_privilege('authenticated', 'public._ehson_is_admin()', 'execute') then
    raise exception '_ehson_is_admin() authenticated uchun ochiq qolgan (ICHKI bulishi kerak)';
  end if;

  -- 11.9 Bucket
  if not exists (select 1 from storage.buckets where id = 'ehson-hujjat') then
    raise exception 'ehson-hujjat bucket yaratilmadi';
  end if;

  raise notice 'PROVODKA_EHSON.sql tayyor. Jami oila: % ta, jamg''arma: % ta',
    (select count(*) from ehson_oila), (select count(*) from ehson_kassa);
end
$ehson_check$;
