-- =====================================================================
--  PROVODKA_5KUNLIK.sql — «5 kunlik» sahifasi — 1-BOSQICH (SKELET)
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  #####  MAQSAD (1-BOSQICH)  ##############################################
--
--  Yangi sahifa `5kunlik-dev.html` — Aksessuar/Zapchast profillari uchun
--  5 kunlik savdo reja/fakt kuzatuvi + Aros yukiga to'lov muddati. Bu fayl
--  FAQAT ruxsat kaliti + bo'sh jadvallarni ochadi (RLS bilan) — HALI HECH
--  QANDAY RPC/HISOB-KITOB YO'Q, klient hozircha bu jadvallarga yozmaydi.
--  Ma'lumot ulash (RPC, reja/fakt hisob-kitobi) KEYINGI bosqichda.
--
--  #####  FAYL TARKIBI  ###################################################
--     0-BO'LIM — old shart tekshiruvi (faqat select/raise)
--     1-BO'LIM — `perm_pages()` qayta e'lon — 22-kalit: `beshkunlik`
--                (sahifa) + `beshkunlik_edit` (tahrir bayrog'i)
--     2-BO'LIM — `beshkunlik_reja` jadvali (+ RLS)
--     3-BO'LIM — `beshkunlik_kun` jadvali (+ RLS)
--     4-BO'LIM — `yuk_deadline` jadvali (+ RLS)
--     5-BO'LIM — PostgREST sxema keshini yangilash
--     6-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/raise)
--
--  #####  🔴 KLIENT TOMONI — BUSIZ ISHLAMAYDI (boshqa agent bajaradi)  ####
--    (a) `perms-dev.js` PAGES ga 'beshkunlik', FLAGS ga 'beshkunlik_edit'
--        (ehson_kirim naqshi — bayroq PAGES ga QO'SHILMAYDI);
--    (b) `index-dev.html` CARDS ga beshkunlik kartasi (beshkunlik_edit — YO'Q);
--    (c) 15+ dev faylda nav (sidebar + "Ko'proq" sheet + prefetch);
--    (d) `promote.sh` PAGES ga '5kunlik' (fayl nomi, ruxsat kaliti EMAS);
--    (e) admin-dev `PVS_PAGES` ga {key:'beshkunlik',...} + {key:'beshkunlik_edit',...}
--        (boshqa repo — TaskFix, shu repoda YO'Q).
--    Birortasi qoldirilsa `admin_set_provodka_perms` kalitni "noma'lum" deb
--    JIMGINA tashlab yuboradi.
--
--  #####  ADDITIVE KAFOLATI  ###############################################
--   * Hech narsa drop qilinmaydi, hech qanday mavjud jadval/ustun/funksiya
--     imzosi o'zgartirilmaydi. Hammasi YANGI, `beshkunlik_`/`yuk_deadline`
--     prefiksi bilan (+ ichki `_beshkunlik_touch()`).
--   * `perm_pages()` imzo/til/immutable saqlanadi — eski 20 kalit tegilmaydi,
--     yangi ikkitasi OXIRIGA qo'shiladi.
--   * Idempotent: `create table if not exists`, `create or replace function`,
--     `drop policy if exists` + `create policy`, CHECK constraint
--     `if not exists (select ... from pg_constraint ...)`, `drop trigger
--     if exists` + `create trigger`.
--   * Anonim `do` bloki YO'Q — har `do` bloki nomlangan teg bilan. Funksiya
--     tanasi ham nomlangan teg bilan. Izohlarda ketma-ket dollar belgi
--     YOZILMAGAN (soxta blok xavfi — CLAUDE.md).
--
--  #####  RUXSAT  ###########################################################
--  O'qish — `perm_has_page('beshkunlik')` (fail-open faqat SQL RUN
--  qilinmagan yoki service_role holatida — `perm_has_page()` ning o'zidagi
--  qoida, CLAUDE.md'da yozilgan). Yozish (insert/update) — HAR IKKI jadval
--  VA `yuk_deadline` uchun ham `perm_has_page('beshkunlik_edit')`.
--  Ustun `updated_by`/`updated_at` klient qo'liga ISHONILMAYDI — trigger
--  `_beshkunlik_touch()` har insert/update'da o'zi `auth.uid()`/`now()`
--  bilan qayta yozadi.
--
--  #####  TALAB (0-BO'LIM tekshiradi)  #####################################
--     profiles, user_perms         — asosiy migratsiya
--     perm_pages(), perm_has_page(text) — PROVODKA_PERMS.sql / PROVODKA_PAGES_EMPTY.sql
--
--  🔴 SQL'ni ASILBEK o'zi RUN qiladi. Agent bajarmaydi.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI                                 ##
-- #####################################################################

do $bk_pre$
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
  if to_regprocedure('public.perm_has_page(text)') is null then
    raise exception 'perm_has_page(text) yoq — avval PROVODKA_PAGES_EMPTY.sql ni bajaring';
  end if;
end
$bk_pre$;


-- #####################################################################
-- ##  1-BO'LIM — perm_pages() qayta e'lon — 22-kalit                  ##
-- #####################################################################
-- 🔴 Imzo/til/immutable saqlanadi. Eski 20 kalit tegilmaydi, `beshkunlik`
-- (sahifa) va `beshkunlik_edit` (tahrir bayrog'i — 'ehson_kirim' bilan bir
-- xil naqsh: allowed_pages ichida saqlanadi, lekin karta/nav/promote'da
-- ISHTIROK ETMAYDI) OXIRIGA qo'shiladi.

create or replace function perm_pages()
returns text[]
language sql
immutable
as $perm_pages$
  select array['kassa','jurnal','professional','hisobot','balans','cashflow',
               'qarzdor','filial','valyuta','konvert','sozlama','provodka',
               'yuklar','standart','tannarx','ai','sorovlar','ehson','ehson_kirim',
               'aylanma','beshkunlik','beshkunlik_edit']::text[];
$perm_pages$;

revoke all on function perm_pages() from public, anon;
grant execute on function perm_pages() to authenticated, service_role;

comment on function perm_pages() is
  'Provodka ruxsat kalitlari (22 ta: 20 eski + beshkunlik sahifasi + beshkunlik_edit bayrogi). '
  'perms-dev.js PAGES+FLAGS va admin-dev PVS_PAGES bilan bir xil bo''lishi shart. '
  'hodim.html bu ro''yxatga KIRMAYDI — hech qachon cheklanmaydi.';


-- #####################################################################
-- ##  ICHKI YORDAMCHI — _beshkunlik_touch() (audit trigger)           ##
-- #####################################################################
-- `updated_by`/`updated_at` klientdan ISHONCH bilan qabul qilinmaydi —
-- har insert/update'da server o'zi qo'yadi. `auth.uid()` null bo'lsa
-- (service_role) ustun eskisidek qoladi — n8n/SQL editor bloklanmaydi.

create or replace function _beshkunlik_touch()
returns trigger
language plpgsql
as $bk_touch$
begin
  new.updated_at := now();
  if auth.uid() is not null then
    new.updated_by := auth.uid();
  end if;
  return new;
end
$bk_touch$;

comment on function _beshkunlik_touch() is
  'ICHKI: beshkunlik_reja / beshkunlik_kun / yuk_deadline uchun umumiy audit trigger. '
  'updated_at/updated_by klientdan emas, serverdan yoziladi.';


-- #####################################################################
-- ##  2-BO'LIM — beshkunlik_reja                                      ##
-- #####################################################################
-- Har kun uchun bitta profil (aksessuar|zapchast) rejasi. `reja` = asl
-- reja (o'zgarmas rejalashtirilgan summa), `uzgardi` = keyin tuzatilgan
-- reja. Ikkalasi ham DOLLARDA (kurs bilan bog'liq emas — reja/uzgardi
-- valyuta konversiyasi keyingi bosqichda kerak bo'lsa alohida ko'rib
-- chiqiladi, hozircha xom son).

create table if not exists beshkunlik_reja (
  profil      text        not null,
  sana        date        not null,
  reja        numeric     not null default 0,
  uzgardi     numeric     not null default 0,
  updated_by  uuid,
  updated_at  timestamptz not null default now(),
  primary key (profil, sana)
);

-- 🔴 7-BOSQICH (2026-09-12): ro'yxat 'umumiy' bilan kengaytirilgan (fresh install
-- uchun) — mavjud bazada bu blok "if not exists" tufayli qayta ishlamaydi, tor
-- constraintni kengaytirish 13-BO'LIMDA (pastda, pg_get_constraintdef bilan).
do $bk_reja_chk$
begin
  if not exists (select 1 from pg_constraint where conname = 'beshkunlik_reja_profil_chk') then
    alter table beshkunlik_reja
      add constraint beshkunlik_reja_profil_chk
      check (profil in ('aksessuar','zapchast','umumiy'));
  end if;
end
$bk_reja_chk$;

comment on table beshkunlik_reja is
  '5 kunlik sahifasi: kun/profil bo''yicha savdo rejasi (dollarda). '
  '`reja` = asl reja, `uzgardi` = keyin tuzatilgan reja. 1-bosqichda klient hali yozmaydi.';
comment on column beshkunlik_reja.profil is
  'umumiy (7-bosqichdan, bitta platforma) | aksessuar | zapchast (tarixiy, 7-bosqichgacha).';
comment on column beshkunlik_reja.reja is 'Asl (birinchi kiritilgan) reja, dollarda.';
comment on column beshkunlik_reja.uzgardi is 'Tuzatilgan reja, dollarda. Boshida reja bilan bir xil bo''lishi mumkin.';

alter table beshkunlik_reja enable row level security;
revoke all on table beshkunlik_reja from public, anon;
grant select, insert, update on table beshkunlik_reja to authenticated;

drop policy if exists beshkunlik_reja_sel on beshkunlik_reja;
create policy beshkunlik_reja_sel on beshkunlik_reja
  for select to authenticated
  using (perm_has_page('beshkunlik'));

drop policy if exists beshkunlik_reja_ins on beshkunlik_reja;
create policy beshkunlik_reja_ins on beshkunlik_reja
  for insert to authenticated
  with check (perm_has_page('beshkunlik_edit'));

drop policy if exists beshkunlik_reja_upd on beshkunlik_reja;
create policy beshkunlik_reja_upd on beshkunlik_reja
  for update to authenticated
  using (perm_has_page('beshkunlik_edit'))
  with check (perm_has_page('beshkunlik_edit'));

drop trigger if exists trg_beshkunlik_reja_touch on beshkunlik_reja;
create trigger trg_beshkunlik_reja_touch
  before insert or update on beshkunlik_reja
  for each row execute function _beshkunlik_touch();


-- #####################################################################
-- ##  3-BO'LIM — beshkunlik_kun                                       ##
-- #####################################################################
-- Kunlik savdo SURATI (snapshot). `kurs_uzs` — o'sha kun muhrlangan
-- USD→UZS kursi: kurs keyin o'zgarsa ham bu qator o'ZGARMAYDI (tarixiy
-- muhr, `frozen_at` — qachon muhrlangani).

create table if not exists beshkunlik_kun (
  profil      text        not null,
  sana        date        not null,
  savdo_uzs   numeric     not null default 0,
  savdo_usd   numeric     not null default 0,
  kurs_uzs    numeric,
  frozen_at   timestamptz,
  primary key (profil, sana)
);

do $bk_kun_chk$
begin
  if not exists (select 1 from pg_constraint where conname = 'beshkunlik_kun_profil_chk') then
    alter table beshkunlik_kun
      add constraint beshkunlik_kun_profil_chk
      check (profil in ('aksessuar','zapchast'));
  end if;
end
$bk_kun_chk$;

comment on table beshkunlik_kun is
  '5 kunlik sahifasi: kun/profil bo''yicha savdo SURATI (fakt). `kurs_uzs` muhrlangan '
  'kurs — keyin o''zgarsa ham bu qator tegilmaydi. 1-bosqichda klient hali yozmaydi.';
comment on column beshkunlik_kun.kurs_uzs is
  'O''sha kun muhrlangan USD->UZS kursi. Joriy kurs o''zgarganda BU QIYMAT o''zgarmaydi.';
comment on column beshkunlik_kun.frozen_at is
  'Qachon muhrlangani (kun surati yopilgan payt). Hali muhrlanmagan (jonli) qator uchun null.';

alter table beshkunlik_kun enable row level security;
revoke all on table beshkunlik_kun from public, anon;
grant select, insert, update on table beshkunlik_kun to authenticated;

drop policy if exists beshkunlik_kun_sel on beshkunlik_kun;
create policy beshkunlik_kun_sel on beshkunlik_kun
  for select to authenticated
  using (perm_has_page('beshkunlik'));

drop policy if exists beshkunlik_kun_ins on beshkunlik_kun;
create policy beshkunlik_kun_ins on beshkunlik_kun
  for insert to authenticated
  with check (perm_has_page('beshkunlik_edit'));

drop policy if exists beshkunlik_kun_upd on beshkunlik_kun;
create policy beshkunlik_kun_upd on beshkunlik_kun
  for update to authenticated
  using (perm_has_page('beshkunlik_edit'))
  with check (perm_has_page('beshkunlik_edit'));

drop trigger if exists trg_beshkunlik_kun_touch on beshkunlik_kun;
create trigger trg_beshkunlik_kun_touch
  before insert or update on beshkunlik_kun
  for each row execute function _beshkunlik_touch();


-- #####################################################################
-- ##  4-BO'LIM — yuk_deadline                                         ##
-- #####################################################################
-- Aros yukiga to'lov muddati. `yuk_id` — Aros yuk id (product-income) —
-- Provodkada yuk jadvali YO'Q (yuk_tannarx/entry_yuk ham xuddi shunday
-- xom `yuk_id integer` bilan ishlaydi — FK yo'q).

create table if not exists yuk_deadline (
  yuk_id      integer     primary key,
  deadline    date,
  izoh        text,
  updated_by  uuid,
  updated_at  timestamptz not null default now()
);

comment on table yuk_deadline is
  'Aros yukiga (product-income) to''lov muddati. yuk_id — Aros yuk id, FK YO''Q '
  '(Provodkada yuk jadvali mavjud emas, yuk_tannarx/entry_yuk naqshi bilan bir xil). '
  'Deadline YUKLAR sahifasida qo''yiladi, 5 kunlik uni faqat o''qiydi — shuning uchun '
  'ruxsat: yuklar YOKI beshkunlik. 1-bosqichda klient hali yozmaydi.';

alter table yuk_deadline enable row level security;
revoke all on table yuk_deadline from public, anon;
grant select, insert, update on table yuk_deadline to authenticated;

drop policy if exists yuk_deadline_sel on yuk_deadline;
create policy yuk_deadline_sel on yuk_deadline
  for select to authenticated
  using (perm_has_page('beshkunlik') or perm_has_page('yuklar'));

drop policy if exists yuk_deadline_ins on yuk_deadline;
create policy yuk_deadline_ins on yuk_deadline
  for insert to authenticated
  with check (perm_has_page('beshkunlik_edit') or perm_has_page('yuklar'));

drop policy if exists yuk_deadline_upd on yuk_deadline;
create policy yuk_deadline_upd on yuk_deadline
  for update to authenticated
  using (perm_has_page('beshkunlik_edit') or perm_has_page('yuklar'))
  with check (perm_has_page('beshkunlik_edit') or perm_has_page('yuklar'));

drop trigger if exists trg_yuk_deadline_touch on yuk_deadline;
create trigger trg_yuk_deadline_touch
  before insert or update on yuk_deadline
  for each row execute function _beshkunlik_touch();


-- #####################################################################
-- ##  5-BO'LIM — PostgREST sxema keshini yangilash                    ##
-- #####################################################################

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  6-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/raise)                ##
-- #####################################################################

do $bk_final$
declare
  v_ok boolean;
begin
  if array_length(perm_pages(), 1) <> 22 then
    raise exception 'YAKUNIY TEKSHIRUV: perm_pages() 22 ta bulishi kerak, hozir: %', array_length(perm_pages(), 1);
  end if;
  if not ('beshkunlik' = any(perm_pages())) then
    raise exception 'YAKUNIY TEKSHIRUV: perm_pages() da beshkunlik kaliti yoq';
  end if;
  if not ('beshkunlik_edit' = any(perm_pages())) then
    raise exception 'YAKUNIY TEKSHIRUV: perm_pages() da beshkunlik_edit bayrogi yoq';
  end if;

  if to_regclass('public.beshkunlik_reja') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_reja jadvali yaralmadi';
  end if;
  if to_regclass('public.beshkunlik_kun') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_kun jadvali yaralmadi';
  end if;
  if to_regclass('public.yuk_deadline') is null then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_deadline jadvali yaralmadi';
  end if;

  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='beshkunlik_reja' and policyname='beshkunlik_reja_sel') then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_reja_sel policy yoq';
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='beshkunlik_kun' and policyname='beshkunlik_kun_sel') then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_kun_sel policy yoq';
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='yuk_deadline' and policyname='yuk_deadline_sel') then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_deadline_sel policy yoq';
  end if;

  select has_table_privilege('authenticated', 'public.beshkunlik_reja', 'select') into v_ok;
  if not coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: authenticated uchun beshkunlik_reja SELECT yoq';
  end if;
  select has_table_privilege('anon', 'public.beshkunlik_reja', 'select') into v_ok;
  if coalesce(v_ok, false) then
    raise exception 'YAKUNIY TEKSHIRUV: anon beshkunlik_reja ni o''qiy olmasligi kerak edi';
  end if;

  raise notice 'PROVODKA_5KUNLIK.sql: hammasi joyida (1-bosqich skelet)';
end
$bk_final$;


-- #####################################################################
-- ##  7-BO'LIM — beshkunlik_kurs / beshkunlik_kurslar (3-BOSQICH)     ##
-- #####################################################################
--  Sanali USD->UZS kurs — «5 kunlik» sahifasi kunlik savdoni (Aros'dan
--  so'mda keladi) dollarga aylantirish va MUHRLASH uchun ishlatadi.
--  Muhrlangan kundan keyin joriy kurs o'zgarsa ham o'sha kun tegilmaydi —
--  bu funksiya faqat HALI muhrlanmagan kun hisoblanganda chaqiriladi
--  (5kunlik-dev.html, beshkunlik_kun jadvaliga yozishdan oldin).
--
--  Mantiq: (1) currency_rate'dan USD->UZS, rate_at <= p_sana bo'yicha eng
--  so'nggisi; (2) topilmasa conv_baza_kurs('USD') (joriy kursga) fallback;
--  (3) u ham bo'lmasa null. Eski funksiyalarga tegilmagan — ikkalasi ham
--  YANGI, additive.

do $bk_kurs_pre$
begin
  if to_regclass('public.currency_rate') is null then
    raise exception 'currency_rate jadvali yoq — avval valyuta migratsiyasini bajaring';
  end if;
  if to_regprocedure('public.conv_baza_kurs(text)') is null then
    raise exception 'conv_baza_kurs(text) yoq — avval PROVODKA_VALYUTA_ALIAS.sql (yoki PROVODKA_VALYUTA.sql) ni bajaring';
  end if;
end
$bk_kurs_pre$;

create or replace function beshkunlik_kurs(p_sana date)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $bk_kurs$
declare v numeric;
begin
  if p_sana is null then
    return null;
  end if;

  select rate into v from currency_rate
   where upper(from_code) = 'USD' and upper(to_code) = 'UZS' and rate_at <= p_sana
   order by rate_at desc, created_at desc limit 1;
  if v is not null then
    return v;
  end if;

  return conv_baza_kurs('USD');
end
$bk_kurs$;

revoke all on function beshkunlik_kurs(date) from public, anon;
grant execute on function beshkunlik_kurs(date) to authenticated;

comment on function beshkunlik_kurs(date) is
  '5 kunlik: sanali USD->UZS kurs. Avval currency_rate dan (from_code=USD, to_code=UZS, '
  'rate_at <= p_sana) eng songgisi, topilmasa conv_baza_kurs(''USD'') (joriy kurs) fallback, '
  'u ham bulmasa null. Faqat hali muhrlanmagan kun hisoblanganda chaqiriladi.';


-- ---------------------------------------------------------------------
-- beshkunlik_kurslar(p_sanalar) — bir nechta sana uchun bitta so'rovda
-- ---------------------------------------------------------------------
-- yuk_kurslar(text[]) bilan bir xil naqsh: har element uchun ichki
-- beshkunlik_kurs() chaqiriladi, xato bo'lsa o'sha sana uchun null.

create or replace function beshkunlik_kurslar(p_sanalar date[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bk_kurslar$
declare d date; r numeric; out jsonb := '{}'::jsonb;
begin
  if p_sanalar is null then
    return out;
  end if;
  foreach d in array p_sanalar loop
    if d is null then continue; end if;
    begin
      r := beshkunlik_kurs(d);
    exception when others then
      r := null;
    end;
    out := out || jsonb_build_object(to_char(d, 'YYYY-MM-DD'), r);
  end loop;
  return out;
end
$bk_kurslar$;

revoke all on function beshkunlik_kurslar(date[]) from public, anon;
grant execute on function beshkunlik_kurslar(date[]) to authenticated;

comment on function beshkunlik_kurslar(date[]) is
  '5 kunlik: beshkunlik_kurs(date) ni bir nechta sana uchun bitta sorovda qaytaradi. '
  'Javob: {"YYYY-MM-DD": kurs, ...} — topilmagan sana uchun qiymat null.';


-- #####################################################################
-- ##  8-BO'LIM — YAKUNIY TEKSHIRUV (3-BOSQICH, faqat select/raise)    ##
-- #####################################################################

do $bk_kurs_final$
begin
  if to_regprocedure('public.beshkunlik_kurs(date)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_kurs(date) yaralmadi';
  end if;
  if to_regprocedure('public.beshkunlik_kurslar(date[])') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_kurslar(date[]) yaralmadi';
  end if;

  raise notice 'PROVODKA_5KUNLIK.sql: beshkunlik_kurs/beshkunlik_kurslar tayyor (3-bosqich qoshimchasi)';
end
$bk_kurs_final$;


-- #####################################################################
-- ##  9-BO'LIM — yuk_deadline: profil / narx / valyuta (6-BOSQICH)    ##
-- #####################################################################
--  Qarz JONLI hisoblanadi (10-BO'LIM), shuning uchun yuk hujjatining
--  o'zi (narx/valyuta) va u qaysi profilga tegishli ekani shu yerda
--  SAQLANISHI kerak — Aros'dan profil BILINMAYDI (hamma yuk "Asosiy
--  ombor"ga tushadi). `narx`/`valyuta` — deadline qo'yilayotgan
--  paytdagi yuk hujjat narxining SURATI, keyin o'zgarmaydi.
--  Ustunlar ustiga yozuvchi UI hali YO'Q (keyingi bosqich) — bu bo'lim
--  faqat sxemani tayyorlaydi, additive.

do $bk_deadline_pre$
begin
  if to_regclass('public.yuk_deadline') is null then
    raise exception 'yuk_deadline jadvali yoq — avval shu faylning 4-BOLIMini bajaring';
  end if;
end
$bk_deadline_pre$;

alter table yuk_deadline add column if not exists profil text;
alter table yuk_deadline add column if not exists narx numeric;
alter table yuk_deadline add column if not exists valyuta text;

do $bk_deadline_chk$
begin
  if not exists (select 1 from pg_constraint where conname = 'yuk_deadline_profil_chk') then
    alter table yuk_deadline
      add constraint yuk_deadline_profil_chk
      check (profil is null or profil in ('aksessuar','zapchast'));
  end if;
end
$bk_deadline_chk$;

comment on column yuk_deadline.profil is
  'aksessuar | zapchast. Aros''dan bilinmaydi (hamma yuk "Asosiy ombor"ga tushadi) — deadline '
  'qo''yilganda qo''lda tanlanadi. Qo''yilmagan bo''lsa null — 5 kunlik qarz hisobiga kirmaydi.';
comment on column yuk_deadline.narx is
  'Yuk hujjat narxining SURATI (deadline qo''yilgan paytdagi qiymat), keyin o''zgarmaydi.';
comment on column yuk_deadline.valyuta is
  'yuk_deadline.narx valyutasi (masalan USD, CNY, UZS). beshkunlik_qarz UZSga shu bilan o''giradi.';


-- #####################################################################
-- ##  10-BO'LIM — beshkunlik_qarz(p_from, p_to) — «5 kunlik» Qarz bloki (6-BOSQICH) ##
-- #####################################################################
--  IMZO: beshkunlik_qarz(p_from date, p_to date) returns jsonb
--  Javob: [{sana, profil, qarzmiz_uzs, berdik_uzs}, ...] — HAMMASI SO'MDA
--  (dollarga o'girish klientda, beshkunlik_kurslar bilan sanali kurs).
--
--  qarzmiz_uzs — deadline shu kunga tushgan yuklar (profil qo'yilgan),
--  profil bo'yicha guruhlangan, har yukning QOLDIQ qarzi:
--    narx_uzs = narx * conv_baza_kurs(valyuta)   (valyuta UZS bo'lsa kurs 1)
--    qoldiq   = greatest(0, narx_uzs + tannarx_jami + bojxona_uzs - tolangan_uzs)
--  🔴 JONLI — muhrlanmaydi. Tannarx/to'lov keyin qo'shilsa qarz ham
--  o'zgaradi (Asilbek bilan kelishilgan qaror, BRIEF_5KUNLIK.md).
--
--  berdik_uzs — shu kuni HAQIQATDA to'langan summa: entry_yuk + entry
--  (faqat posted, o'chirilmagan), entry SANASI bo'yicha guruhlangan.
--  Profil — o'sha yukning yuk_deadline.profil'idan; deadline/profil
--  qo'yilmagan yuk to'lovi hech qaysi profilga tushmaydi (kutilgan holat).
--
--  Ruxsat: `perm_has_page('beshkunlik')` funksiya ICHIDA — yo'q bo'lsa
--  bo'sh massiv. `security definer` — chaqiruvchi o'zi entry/entry_yuk'ni
--  o'qiy olmasa ham (ular RLS bilan `authenticated using(true)`,
--  hozircha muammo yo'q, lekin guard baribir birinchi qatorda).

do $bk_qarz_pre$
begin
  if to_regprocedure('public.yuk_tannarx_jami(integer[])') is null then
    raise exception 'yuk_tannarx_jami(integer[]) yoq — avval PROVODKA_YUK_TANNARX.sql ni bajaring';
  end if;
  if to_regprocedure('public.yuk_bojxona_jami(integer[])') is null then
    raise exception 'yuk_bojxona_jami(integer[]) yoq — avval PROVODKA_YUK_BOJXONA.sql ni bajaring';
  end if;
  if to_regprocedure('public.yuk_tolangan_summa(integer[])') is null then
    raise exception 'yuk_tolangan_summa(integer[]) yoq — avval PROVODKA_YUK_QISMAN.sql ni bajaring';
  end if;
  if to_regclass('public.entry_yuk') is null then
    raise exception 'entry_yuk jadvali yoq — avval PROVODKA_YUK_QISMAN.sql ni bajaring';
  end if;
end
$bk_qarz_pre$;

create or replace function beshkunlik_qarz(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bk_qarz$
declare
  v_ids integer[];
  v_tannarx jsonb;
  v_bojxona jsonb;
  v_tolangan_map jsonb := '{}'::jsonb;
begin
  if not coalesce(perm_has_page('beshkunlik'), false) then
    return '[]'::jsonb;
  end if;
  if p_from is null or p_to is null then
    return '[]'::jsonb;
  end if;

  select coalesce(array_agg(yd.yuk_id), '{}'::integer[])
    into v_ids
    from yuk_deadline yd
   where yd.deadline between p_from and p_to
     and yd.profil is not null;

  v_tannarx := coalesce(yuk_tannarx_jami(v_ids), '{}'::jsonb);
  v_bojxona := coalesce(yuk_bojxona_jami(v_ids), '{}'::jsonb);

  select coalesce(jsonb_object_agg(t ->> 'yuk_id', t ->> 'tolangan_uzs'), '{}'::jsonb)
    into v_tolangan_map
    from jsonb_array_elements(coalesce(yuk_tolangan_summa(v_ids), '[]'::jsonb)) as t;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'sana', x.sana, 'profil', x.profil,
             'qarzmiz_uzs', x.qarzmiz_uzs, 'berdik_uzs', x.berdik_uzs)
             order by x.sana, x.profil)
      from (
        select coalesce(q.sana, b.sana) as sana,
               coalesce(q.profil, b.profil) as profil,
               coalesce(q.qarzmiz_uzs, 0) as qarzmiz_uzs,
               coalesce(b.berdik_uzs, 0) as berdik_uzs
          from (
            select yd.deadline as sana, yd.profil,
                   sum(greatest(0,
                     coalesce(yd.narx, 0)
                       * coalesce(case when upper(coalesce(yd.valyuta, 'UZS')) = 'UZS' then 1::numeric
                                       else conv_baza_kurs(yd.valyuta) end, 0)
                     + coalesce((v_tannarx -> yd.yuk_id::text ->> 'jami_uzs')::numeric, 0)
                     + coalesce((v_bojxona -> yd.yuk_id::text ->> 'bojxona_uzs')::numeric, 0)
                     - coalesce((v_tolangan_map ->> yd.yuk_id::text)::numeric, 0)
                   )) as qarzmiz_uzs
              from yuk_deadline yd
             where yd.deadline between p_from and p_to
               and yd.profil is not null
             group by yd.deadline, yd.profil
          ) q
          full outer join (
            select e.entry_date as sana, yd2.profil,
                   sum(ey.summa_uzs) as berdik_uzs
              from entry_yuk ey
              join entry e on e.id = ey.entry_id
              join yuk_deadline yd2 on yd2.yuk_id = ey.yuk_id
             where e.status = 'posted' and e.is_deleted = false
               and e.entry_date between p_from and p_to
               and yd2.profil is not null
             group by e.entry_date, yd2.profil
          ) b on b.sana = q.sana and b.profil = q.profil
      ) x
  ), '[]'::jsonb);
end
$bk_qarz$;

revoke all on function beshkunlik_qarz(date, date) from public, anon;
grant execute on function beshkunlik_qarz(date, date) to authenticated;

comment on function beshkunlik_qarz(date, date) is
  '5 kunlik Qarz bloki, SOMDA: [{sana, profil, qarzmiz_uzs, berdik_uzs}]. Qarzmiz — deadline shu '
  'kunga tushgan yuklar (JONLI: narx+tannarx+bojxona-tolangan, muhrlanmaydi). Berdik — shu kuni '
  'entry_yuk orqali haqiqatda tolangan (posted, ochirilmagan). Profil qoyilmagan yuk hech qaysi '
  'kunga/profilga tushmaydi. Ruxsat: perm_has_page(''beshkunlik'') ichida, yoq bolsa bosh massiv.';


-- #####################################################################
-- ##  11-BO'LIM — beshkunlik_qarz_detal(p_sana, p_profil) — hover (6-BOSQICH) ##
-- #####################################################################
--  IMZO: beshkunlik_qarz_detal(p_sana date, p_profil text) returns jsonb
--  Bitta kun/profil uchun deadline'i shu kunga tushgan yuklarning
--  qatorlari — 5kunlik-dev.html Qarzmiz katagi hover'ida ko'rsatiladi.
--  Javob: [{yuk_id, narx, valyuta, izoh, qoldiq_uzs}, ...]
--  🔴 `yetkazuvchi` YO'Q — Provodka bazasida yuk yetkazib beruvchisi
--  hech qayerda saqlanmaydi (yuklar sahifasi uni Aros webhook'idan
--  jonli oladi, yuk_deadline'da bu ustun yo'q). Hover shu bilan
--  cheklangan: yuk id + izoh (agar deadline qo'yilganda yozilgan bo'lsa) + qoldiq.

create or replace function beshkunlik_qarz_detal(p_sana date, p_profil text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bk_qarz_detal$
declare
  v_ids integer[];
  v_tannarx jsonb;
  v_bojxona jsonb;
  v_tolangan_map jsonb := '{}'::jsonb;
begin
  if not coalesce(perm_has_page('beshkunlik'), false) then
    return '[]'::jsonb;
  end if;
  if p_sana is null or p_profil is null then
    return '[]'::jsonb;
  end if;

  select coalesce(array_agg(yd.yuk_id), '{}'::integer[])
    into v_ids
    from yuk_deadline yd
   where yd.deadline = p_sana and yd.profil = p_profil;

  if array_length(v_ids, 1) is null then
    return '[]'::jsonb;
  end if;

  v_tannarx := coalesce(yuk_tannarx_jami(v_ids), '{}'::jsonb);
  v_bojxona := coalesce(yuk_bojxona_jami(v_ids), '{}'::jsonb);

  select coalesce(jsonb_object_agg(t ->> 'yuk_id', t ->> 'tolangan_uzs'), '{}'::jsonb)
    into v_tolangan_map
    from jsonb_array_elements(coalesce(yuk_tolangan_summa(v_ids), '[]'::jsonb)) as t;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'yuk_id', yd.yuk_id, 'narx', yd.narx, 'valyuta', yd.valyuta, 'izoh', yd.izoh,
             'qoldiq_uzs', greatest(0,
               coalesce(yd.narx, 0)
                 * coalesce(case when upper(coalesce(yd.valyuta, 'UZS')) = 'UZS' then 1::numeric
                                 else conv_baza_kurs(yd.valyuta) end, 0)
               + coalesce((v_tannarx -> yd.yuk_id::text ->> 'jami_uzs')::numeric, 0)
               + coalesce((v_bojxona -> yd.yuk_id::text ->> 'bojxona_uzs')::numeric, 0)
               - coalesce((v_tolangan_map ->> yd.yuk_id::text)::numeric, 0)))
             order by yd.yuk_id)
      from yuk_deadline yd
     where yd.yuk_id = any(v_ids)
  ), '[]'::jsonb);
end
$bk_qarz_detal$;

revoke all on function beshkunlik_qarz_detal(date, text) from public, anon;
grant execute on function beshkunlik_qarz_detal(date, text) to authenticated;

comment on function beshkunlik_qarz_detal(date, text) is
  '5 kunlik Qarzmiz katagi hover: bitta kun/profil uchun yuk qatorlari '
  '[{yuk_id, narx, valyuta, izoh, qoldiq_uzs}]. yetkazuvchi YOQ (bazada saqlanmaydi). '
  'Ruxsat: perm_has_page(''beshkunlik'') ichida, yoq bolsa bosh massiv.';


-- #####################################################################
-- ##  12-BO'LIM — YAKUNIY TEKSHIRUV (6-BOSQICH, faqat select/raise)   ##
-- #####################################################################

do $bk_qarz_final$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='yuk_deadline' and column_name='profil'
  ) then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_deadline.profil ustuni yaralmadi';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='yuk_deadline' and column_name='narx'
  ) then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_deadline.narx ustuni yaralmadi';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='yuk_deadline' and column_name='valyuta'
  ) then
    raise exception 'YAKUNIY TEKSHIRUV: yuk_deadline.valyuta ustuni yaralmadi';
  end if;
  if to_regprocedure('public.beshkunlik_qarz(date,date)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_qarz(date,date) yaralmadi';
  end if;
  if to_regprocedure('public.beshkunlik_qarz_detal(date,text)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_qarz_detal(date,text) yaralmadi';
  end if;

  raise notice 'PROVODKA_5KUNLIK.sql: Qarz bloki tayyor (6-bosqich qoshimchasi)';
end
$bk_qarz_final$;


-- #####################################################################
-- ##  13-BO'LIM — beshkunlik_reja: mavjud CHECK'ni 'umumiy'ga kengaytir (7-BOSQICH) ##
-- #####################################################################
--  Biznes qarori (Asilbek, 2026-09-12): Aksessuar/Zapchast profillari endi
--  ikkiga bo'linmaydi — BITTA platforma. Reja/Uzgardi shu bosqichdan
--  boshlab profil='umumiy' bilan yoziladi. Eski aksessuar/zapchast qatorlar
--  O'CHIRILMAYDI (14-BO'LIM ularni 'umumiy'ga ko'chiradi, lekin eskisi
--  qoladi — beshkunlik_kun hali profil bo'yicha muhrlanadi, hover uchun).
--  2-BO'LIMDAGI do bloki "if not exists" tufayli mavjud bazada qayta
--  ishlamaydi (constraint allaqachon bor) — shuning uchun bu bo'lim uni
--  pg_get_constraintdef bilan tekshirib, kerak bo'lsagina drop+qayta qo'shadi.

do $bk_reja_chk_widen$
declare
  v_def text;
begin
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint where conname = 'beshkunlik_reja_profil_chk';
  if v_def is null then
    alter table beshkunlik_reja
      add constraint beshkunlik_reja_profil_chk
      check (profil in ('aksessuar','zapchast','umumiy'));
  elsif v_def not like '%umumiy%' then
    alter table beshkunlik_reja drop constraint beshkunlik_reja_profil_chk;
    alter table beshkunlik_reja
      add constraint beshkunlik_reja_profil_chk
      check (profil in ('aksessuar','zapchast','umumiy'));
  end if;
end
$bk_reja_chk_widen$;


-- #####################################################################
-- ##  14-BO'LIM — bir martalik ko'chirish: aksessuar+zapchast -> umumiy (7-BOSQICH) ##
-- #####################################################################
--  Mavjud aksessuar+zapchast reja/uzgardi yig'indisi kun bo'yicha 'umumiy'
--  qatoriga yoziladi. `on conflict do nothing` — qayta RUN qilinsa ikkinchi
--  marta qo'shilmaydi (idempotent). Eski aksessuar/zapchast qatorlar
--  SAQLANADI, hech narsa o'chirilmaydi.

insert into beshkunlik_reja (profil, sana, reja, uzgardi)
select 'umumiy', sana, sum(reja), sum(uzgardi)
  from beshkunlik_reja
 where profil in ('aksessuar','zapchast')
 group by sana
on conflict (profil, sana) do nothing;


-- #####################################################################
-- ##  15-BO'LIM — beshkunlik_qarz_v2 / beshkunlik_qarz_detal_v2 (7-BOSQICH) ##
-- #####################################################################
--  10/11-BO'LIMDAGI beshkunlik_qarz / beshkunlik_qarz_detal bilan BIR XIL
--  mantiq, faqat PROFILSIZ — bitta platforma qarori bilan Qarz bloki endi
--  profil bo'yicha bo'linmaydi (deadline qo'yilgan HAMMA yuk). Eski v1
--  funksiyalarga TEGILMAGAN (eski klient/keshlar sinmasin).
--
--  IMZO: beshkunlik_qarz_v2(p_from date, p_to date) returns jsonb
--  Javob: [{sana, qarzmiz_uzs, berdik_uzs}, ...] — SO'MDA.
--  IMZO: beshkunlik_qarz_detal_v2(p_sana date) returns jsonb
--  Javob: [{yuk_id, narx, valyuta, izoh, qoldiq_uzs}, ...]

create or replace function beshkunlik_qarz_v2(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bk_qarz_v2$
declare
  v_ids integer[];
  v_tannarx jsonb;
  v_bojxona jsonb;
  v_tolangan_map jsonb := '{}'::jsonb;
begin
  if not coalesce(perm_has_page('beshkunlik'), false) then
    return '[]'::jsonb;
  end if;
  if p_from is null or p_to is null then
    return '[]'::jsonb;
  end if;

  select coalesce(array_agg(yd.yuk_id), '{}'::integer[])
    into v_ids
    from yuk_deadline yd
   where yd.deadline between p_from and p_to;

  v_tannarx := coalesce(yuk_tannarx_jami(v_ids), '{}'::jsonb);
  v_bojxona := coalesce(yuk_bojxona_jami(v_ids), '{}'::jsonb);

  select coalesce(jsonb_object_agg(t ->> 'yuk_id', t ->> 'tolangan_uzs'), '{}'::jsonb)
    into v_tolangan_map
    from jsonb_array_elements(coalesce(yuk_tolangan_summa(v_ids), '[]'::jsonb)) as t;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'sana', x.sana, 'qarzmiz_uzs', x.qarzmiz_uzs, 'berdik_uzs', x.berdik_uzs)
             order by x.sana)
      from (
        select coalesce(q.sana, b.sana) as sana,
               coalesce(q.qarzmiz_uzs, 0) as qarzmiz_uzs,
               coalesce(b.berdik_uzs, 0) as berdik_uzs
          from (
            select yd.deadline as sana,
                   sum(greatest(0,
                     coalesce(yd.narx, 0)
                       * coalesce(case when upper(coalesce(yd.valyuta, 'UZS')) = 'UZS' then 1::numeric
                                       else conv_baza_kurs(yd.valyuta) end, 0)
                     + coalesce((v_tannarx -> yd.yuk_id::text ->> 'jami_uzs')::numeric, 0)
                     + coalesce((v_bojxona -> yd.yuk_id::text ->> 'bojxona_uzs')::numeric, 0)
                     - coalesce((v_tolangan_map ->> yd.yuk_id::text)::numeric, 0)
                   )) as qarzmiz_uzs
              from yuk_deadline yd
             where yd.deadline between p_from and p_to
             group by yd.deadline
          ) q
          full outer join (
            select e.entry_date as sana,
                   sum(ey.summa_uzs) as berdik_uzs
              from entry_yuk ey
              join entry e on e.id = ey.entry_id
              join yuk_deadline yd2 on yd2.yuk_id = ey.yuk_id
             where e.status = 'posted' and e.is_deleted = false
               and e.entry_date between p_from and p_to
               and yd2.deadline is not null
             group by e.entry_date
          ) b on b.sana = q.sana
      ) x
  ), '[]'::jsonb);
end
$bk_qarz_v2$;

revoke all on function beshkunlik_qarz_v2(date, date) from public, anon;
grant execute on function beshkunlik_qarz_v2(date, date) to authenticated;

comment on function beshkunlik_qarz_v2(date, date) is
  '5 kunlik Qarz bloki (7-bosqich, PROFILSIZ — bitta platforma), SOMDA: '
  '[{sana, qarzmiz_uzs, berdik_uzs}]. Mantiq beshkunlik_qarz(date,date) bilan bir xil, '
  'faqat profil bo''yicha filtr/guruhlash YOQ. Ruxsat: perm_has_page(''beshkunlik'') ichida.';

create or replace function beshkunlik_qarz_detal_v2(p_sana date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $bk_qarz_detal_v2$
declare
  v_ids integer[];
  v_tannarx jsonb;
  v_bojxona jsonb;
  v_tolangan_map jsonb := '{}'::jsonb;
begin
  if not coalesce(perm_has_page('beshkunlik'), false) then
    return '[]'::jsonb;
  end if;
  if p_sana is null then
    return '[]'::jsonb;
  end if;

  select coalesce(array_agg(yd.yuk_id), '{}'::integer[])
    into v_ids
    from yuk_deadline yd
   where yd.deadline = p_sana;

  if array_length(v_ids, 1) is null then
    return '[]'::jsonb;
  end if;

  v_tannarx := coalesce(yuk_tannarx_jami(v_ids), '{}'::jsonb);
  v_bojxona := coalesce(yuk_bojxona_jami(v_ids), '{}'::jsonb);

  select coalesce(jsonb_object_agg(t ->> 'yuk_id', t ->> 'tolangan_uzs'), '{}'::jsonb)
    into v_tolangan_map
    from jsonb_array_elements(coalesce(yuk_tolangan_summa(v_ids), '[]'::jsonb)) as t;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'yuk_id', yd.yuk_id, 'narx', yd.narx, 'valyuta', yd.valyuta, 'izoh', yd.izoh,
             'qoldiq_uzs', greatest(0,
               coalesce(yd.narx, 0)
                 * coalesce(case when upper(coalesce(yd.valyuta, 'UZS')) = 'UZS' then 1::numeric
                                 else conv_baza_kurs(yd.valyuta) end, 0)
               + coalesce((v_tannarx -> yd.yuk_id::text ->> 'jami_uzs')::numeric, 0)
               + coalesce((v_bojxona -> yd.yuk_id::text ->> 'bojxona_uzs')::numeric, 0)
               - coalesce((v_tolangan_map ->> yd.yuk_id::text)::numeric, 0)))
             order by yd.yuk_id)
      from yuk_deadline yd
     where yd.yuk_id = any(v_ids)
  ), '[]'::jsonb);
end
$bk_qarz_detal_v2$;

revoke all on function beshkunlik_qarz_detal_v2(date) from public, anon;
grant execute on function beshkunlik_qarz_detal_v2(date) to authenticated;

comment on function beshkunlik_qarz_detal_v2(date) is
  '5 kunlik Qarzmiz katagi hover (7-bosqich, PROFILSIZ): bitta kun uchun yuk qatorlari '
  '[{yuk_id, narx, valyuta, izoh, qoldiq_uzs}]. Ruxsat: perm_has_page(''beshkunlik'') ichida.';


-- #####################################################################
-- ##  16-BO'LIM — beshkunlik_sozlama (7-BOSQICH — boshlang'ich qoldiq) ##
-- #####################################################################
--  Bitta qatorli sozlama: yig'ilma qachondan va qancha pul bilan
--  boshlangani (Excelda 23-avgustda 108 228 dollar bilan boshlangan edi).
--  Qator bo'lmasa sahifa sukut (boshlanish=null, boshlangich_usd=0) ishlatadi.

create table if not exists beshkunlik_sozlama (
  id              int         primary key default 1 check (id = 1),
  boshlanish      date,
  boshlangich_usd numeric     not null default 0,
  updated_by      uuid,
  updated_at      timestamptz not null default now()
);

comment on table beshkunlik_sozlama is
  '5 kunlik: bitta qatorli sozlama — yig''ilma rekursiyasining boshlang''ich nuqtasi '
  '(boshlanish sanasi + shu kundagi boshlang''ich pul, dollarda). Qator bo''lmasa sahifa '
  'sukutni ishlatadi (boshlanish=eng erta ma''lumot sanasi, boshlangich_usd=0).';

alter table beshkunlik_sozlama enable row level security;
revoke all on table beshkunlik_sozlama from public, anon;
grant select, insert, update on table beshkunlik_sozlama to authenticated;

drop policy if exists beshkunlik_sozlama_sel on beshkunlik_sozlama;
create policy beshkunlik_sozlama_sel on beshkunlik_sozlama
  for select to authenticated
  using (perm_has_page('beshkunlik'));

drop policy if exists beshkunlik_sozlama_ins on beshkunlik_sozlama;
create policy beshkunlik_sozlama_ins on beshkunlik_sozlama
  for insert to authenticated
  with check (perm_has_page('beshkunlik_edit'));

drop policy if exists beshkunlik_sozlama_upd on beshkunlik_sozlama;
create policy beshkunlik_sozlama_upd on beshkunlik_sozlama
  for update to authenticated
  using (perm_has_page('beshkunlik_edit'))
  with check (perm_has_page('beshkunlik_edit'));

drop trigger if exists trg_beshkunlik_sozlama_touch on beshkunlik_sozlama;
create trigger trg_beshkunlik_sozlama_touch
  before insert or update on beshkunlik_sozlama
  for each row execute function _beshkunlik_touch();


-- #####################################################################
-- ##  17-BO'LIM — beshkunlik_muhrla(p_data jsonb) — kechasi avtomuhrlash (7-BOSQICH) ##
-- #####################################################################
--  n8n har kechasi chaqiradi (workflow alohida quriladi — bu fayl faqat
--  RPC'ni tayyorlaydi). Har sana/profil uchun beshkunlik_kun ga faqat HALI
--  MUHRLANMAGAN (qator yo'q yoki frozen_at null) bo'lsagina yoziladi —
--  muhrlangan qatorga HECH QACHON tegilmaydi (`on conflict ... where
--  frozen_at is null` — qo'shimcha himoya, race'ga qarshi ham).
--
--  IMZO: beshkunlik_muhrla(p_data jsonb) returns jsonb
--  Kirish:  {"kunlar":[{"sana":"YYYY-MM-DD","aksessuar_uzs":N,"zapchast_uzs":N}, ...]}
--  Chiqish: {"ok":true,"yozildi":N,"otkazildi":N,"kurs_yoq":["YYYY-MM-DD", ...]}
--           yoki {"ok":false,"error":"..."} — bo'sh/noto'g'ri payload, hech narsa yozilmaydi.
--  Faqat sana < BUGUN (Toshkent) qabul qilinadi (bugungi/kelajak kun — jonli,
--  sahifaning o'zi hisoblaydi). Kurs topilmasa (beshkunlik_kurs null) o'sha
--  sana o'tkazib yuboriladi va kurs_yoq ro'yxatiga qo'shiladi.
--  🔴 VAQT (2026-09-12, tekshirilgan fakt): n8n `cache_calendar_daily` har kechasi
--  ~01:00-01:11 (Toshkent) oxirgi kunlarni QAYTA hisoblaydi, ya'ni "kecha" faqat
--  shundan keyin to'liq. Shu sababli n8n workflow bu funksiyani soat 02:00da
--  chaqiradi (kecha allaqachon to'liq) — "sana < bugun" shu holatda TO'G'RI va
--  o'zgartirilmagan. Sahifaning o'zi (5kunlik-dev.html, `computeAndFreeze()`)
--  esa ertalab ham ochilishi mumkin bo'lgani uchun ehtiyotkorroq: faqat
--  `sana <= bugun-2 kun` bo'lgan kunni muhrlaydi, "kecha"ni bu RPC'ga qoldiradi.
--  🔴 service_role ONLY — faqat n8n chaqiradi, klient/anon/authenticated'dan yopiq.

create or replace function beshkunlik_muhrla(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $bk_muhrla$
declare
  v_today      date := (now() at time zone 'Asia/Tashkent')::date;
  v_kun        jsonb;
  v_sana       date;
  v_uzs        numeric;
  v_kurs       numeric;
  v_usd        numeric;
  v_frozen     timestamptz;
  v_yozildi    int := 0;
  v_otkazildi  int := 0;
  v_kurs_yoq   date[] := '{}';
  v_p          text;
begin
  if p_data is null or not (p_data ? 'kunlar') or jsonb_typeof(p_data -> 'kunlar') <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'kunlar massivi kutilgan (jsonb array)');
  end if;

  for v_kun in select * from jsonb_array_elements(p_data -> 'kunlar')
  loop
    v_sana := null;
    begin
      v_sana := (v_kun ->> 'sana')::date;
    exception when others then
      v_sana := null;
    end;
    if v_sana is null or v_sana >= v_today then
      continue;
    end if;

    v_kurs := beshkunlik_kurs(v_sana);
    if v_kurs is null then
      if not (v_sana = any(v_kurs_yoq)) then
        v_kurs_yoq := v_kurs_yoq || v_sana;
      end if;
      continue;
    end if;

    foreach v_p in array array['aksessuar','zapchast']
    loop
      v_uzs := coalesce((v_kun ->> (v_p || '_uzs'))::numeric, 0);

      select frozen_at into v_frozen from beshkunlik_kun where profil = v_p and sana = v_sana;
      if v_frozen is not null then
        v_otkazildi := v_otkazildi + 1;
        continue;
      end if;

      v_usd := round(v_uzs / v_kurs);
      insert into beshkunlik_kun (profil, sana, savdo_uzs, savdo_usd, kurs_uzs, frozen_at)
        values (v_p, v_sana, v_uzs, v_usd, v_kurs, now())
      on conflict (profil, sana) do update
        set savdo_uzs = excluded.savdo_uzs,
            savdo_usd = excluded.savdo_usd,
            kurs_uzs  = excluded.kurs_uzs,
            frozen_at = excluded.frozen_at
        where beshkunlik_kun.frozen_at is null;
      v_yozildi := v_yozildi + 1;
    end loop;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'yozildi', v_yozildi,
    'otkazildi', v_otkazildi,
    'kurs_yoq', coalesce((select jsonb_agg(to_char(d, 'YYYY-MM-DD') order by d) from unnest(v_kurs_yoq) d), '[]'::jsonb)
  );
end
$bk_muhrla$;

revoke all on function beshkunlik_muhrla(jsonb) from public, anon, authenticated;
grant execute on function beshkunlik_muhrla(jsonb) to service_role;

comment on function beshkunlik_muhrla(jsonb) is
  '5 kunlik: kechasi avtomatik muhrlash (n8n, service_role ONLY). Kirish '
  '{"kunlar":[{"sana","aksessuar_uzs","zapchast_uzs"}, ...]}, chiqish '
  '{"ok","yozildi","otkazildi","kurs_yoq"}. Faqat sana<bugun(Toshkent) va HALI '
  'muhrlanmagan (frozen_at is null) qatorga yozadi — muhrlangan qatorga hech qachon tegmaydi.';


-- #####################################################################
-- ##  18-BO'LIM — YAKUNIY TEKSHIRUV (7-BOSQICH, faqat select/raise)   ##
-- #####################################################################

do $bk_umumiy_final$
declare
  v_def text;
begin
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint where conname = 'beshkunlik_reja_profil_chk';
  if v_def is null or v_def not like '%umumiy%' then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_reja_profil_chk umumiy ni qamramaydi';
  end if;

  if to_regclass('public.beshkunlik_sozlama') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_sozlama jadvali yaralmadi';
  end if;
  if to_regprocedure('public.beshkunlik_qarz_v2(date,date)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_qarz_v2(date,date) yaralmadi';
  end if;
  if to_regprocedure('public.beshkunlik_qarz_detal_v2(date)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_qarz_detal_v2(date) yaralmadi';
  end if;
  if to_regprocedure('public.beshkunlik_muhrla(jsonb)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_muhrla(jsonb) yaralmadi';
  end if;

  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='beshkunlik_sozlama' and policyname='beshkunlik_sozlama_sel') then
    raise exception 'YAKUNIY TEKSHIRUV: beshkunlik_sozlama_sel policy yoq';
  end if;

  raise notice 'PROVODKA_5KUNLIK.sql: bitta platforma (umumiy) + Qarz v2 + sozlama + muhrla tayyor (7-bosqich qoshimchasi)';
end
$bk_umumiy_final$;
