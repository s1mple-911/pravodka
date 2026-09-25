-- =====================================================================
-- PROVODKA_STANDART_LIMIT_V2.sql — Asilbek, 6 masala («Standart xarajatlar»)
-- ---------------------------------------------------------------------
-- 1) LIMIT NOTO'G'RI JOYDAN YECHILARDI: Gulnoza (rol limiti 1 000 000,
--    «Yo'l harajati») filial «Malika»ni tanlab yozsa — sarf FAQAT Malika
--    filial limitidan yechilardi, uning shaxsiy (rol/override) limiti
--    KAMAYMASDI. Sabab: rbac_limit_entry_line() «filial override» topilsa
--    ERTA QAYTARDI (return new). Endi IKKALASI ham: hodimning o'z (rol/
--    override) limiti HAR DOIM tekshiriladi (o'zi yozgani, created_by
--    bo'yicha), filial limiti bor bo'lsa u HAM (alohida trigger,
--    limit_guard_entry_line — tegilmagan) tekshiriladi.
-- 2) Hodim tab: bitta hodim endi BITTA qator (yig'ma sarlavha), bosilsa
--    hamma modda/ovqat qatori ochiladi («Hammasini ochish/yopish»).
-- 3) Hodim tab filtri: ism qidiruv apostrof/registrga sezgir emas endi
--    (standart_norm'ga o'xshash JS normalizatsiya).
-- 4) Limit endi UZS/USD/CNY bo'lishi mumkin (hodim override VA filial
--    limiti) — kurs JONLI (conv_baza_kurs), muzlatilmagan.
-- 5) Hodim tab kengaytirildi (to'liq sahifa kengligi, kattaroq shrift).
-- 6) Yangi Provodka-only filial kassa «Ta'minot Xitoy» + 2 hodim (G'iyos
--    Ergashev, Ural Ruziyev) yangi staff_filial_qolda jadvali orqali
--    unga biriktiriladi (Aros filiali yo'q hodimlar uchun).
-- ---------------------------------------------------------------------
-- ## RUN TARTIBI (bo'limlarni tartib bilan, Asilbek RUN qiladi)
--   0-BO'LIM  — old shart tekshiruvi (faqat select)
--   1-BO'LIM  — MASALA #1: rbac_limit_entry_line() qayta e'lon (filial
--               override ERTA QAYTISH olib tashlandi, qolgani VERBATIM)
--   2-BO'LIM  — MASALA #4: valyuta ustunlari (rbac_staff_limit,
--               standart_xarajat) + backfill (additive)
--   3-BO'LIM  — standart_limit_uzs(numeric, text) — YANGI ICHKI yordamchi
--   4-BO'LIM  — rbac_limit_modda(uuid,uuid) qayta e'lon — valyuta-aware
--   5-BO'LIM  — rbac_limit_ovqat_staff(int,text) qayta e'lon — valyuta-aware
--   6-BO'LIM  — standart_limit_set: eski imzo qayta e'lon (UZS normalizatsiya)
--               + YANGI overload (uuid,uuid,numeric,text)
--   7-BO'LIM  — standart_hodim_limit_set: eski imzo qayta e'lon (UZS
--               normalizatsiya) + YANGI overload (int,text,numeric,boolean,text)
--   8-BO'LIM  — MASALA #6: staff_filial_qolda jadvali (YANGI, additive)
--   9-BO'LIM  — standart_filial_moddalar(uuid) qayta e'lon — qolda union +
--               valyuta maydonlari
--   10-BO'LIM — standart_filial_limit_sarf(uuid,date) qayta e'lon — qolda union
--   11-BO'LIM — standart_hodim_limitlar(uuid,date) qayta e'lon — qolda union +
--               valyuta-aware override + hodim guruhlash uchun kerakli maydonlar
--   12-BO'LIM — standart_holat(date) qayta e'lon — valyuta-aware limit_uzs
--   13-BO'LIM — limit_guard_entry_line() qayta e'lon — valyuta-aware filial limiti
--   14-BO'LIM — MASALA #6: «Ta'minot Xitoy» filial kassa (idempotent)
--   15-BO'LIM — MASALA #6: G'iyos Ergashev / Ural Ruziyev -> staff_filial_qolda
--   16-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)
--
-- ## OLD SHART (bazada bo'lishi kerak)
--   PROVODKA_STANDART_HODIM.sql  -> rbac_staff_limit, rbac_limit_modda,
--                                    rbac_limit_ovqat_staff, standart_hodim_limitlar,
--                                    standart_hodim_limit_set
--   PROVODKA_STANDART_ROL.sql    -> standart_norm/standart_translit/standart_ball,
--                                    staff_branch_map.filial_id, rbac_limit_entry_line()
--                                    (filial override shoxi bilan versiya)
--   PROVODKA_STANDART_RUXSAT.sql -> standart_page_ok(), standart_limit_set/delete
--                                    (standart_page_ok() bilan versiya), standart_branch_bogla
--   PROVODKA_STANDART_LIMIT_SARF.sql -> standart_filial_limit_sarf, standart_filial_moddalar
--                                    (ovqat-modda tuzatilgan versiya)
--   PROVODKA_V7.sql              -> standart_xarajat, standart_holat, limit_guard_entry_line
--   PROVODKA_VALYUTA_ALIAS.sql   -> conv_baza_kurs(text)
--   PROVODKA_OSHXONA_KASSA.sql   -> _pul_turi_child_ich(uuid,text) naqshi (bu faylda ham ishlatiladi)
--   PROVODKA_OVQAT.sql           -> aros_staff, staff_branch_map, nom_norm(text)
--
-- ## QOIDALAR (CLAUDE.md, buzilmadi)
--   * anonim `do` bloki YO'Q — har `do` bloki NOMLANGAN teg bilan.
--   * har funksiya tanasi NOMLANGAN dollar-teg (masalan "fn") bilan o'raladi.
--   * izohda dollar-qavs (ikkita "$" yonma-yon) YO'Q.
--   * hammasi additive: eski jadval/ustun/funksiya imzosi buzilmaydi —
--     rbac_limit_modda, rbac_limit_ovqat_staff, standart_limit_set (3-arg),
--     standart_hodim_limit_set (4-arg), standart_filial_moddalar,
--     standart_filial_limit_sarf, standart_hodim_limitlar, standart_holat,
--     limit_guard_entry_line, rbac_limit_entry_line — hammasi AYNAN o'sha
--     imzo bilan, faqat tana kengaydi. YANGI: standart_limit_set(uuid,uuid,
--     numeric,text) va standart_hodim_limit_set(int,text,numeric,boolean,text)
--     — bular ALOHIDA overload (eskisi YONIDA turadi, o'chirilmaydi).
--   * 🔴 standart_hodim_limit_set YANGI overloadida `p_valyuta` ATAYLAB
--     DEFAULTSIZ (5 argument HAMMASI majburiy): agar defaultli bo'lsa
--     (p_valyuta text default 'UZS'), 4 nomlangan argument bilan qilingan
--     RPC chaqiruvi IKKI funksiyaga (eski 4-argumentli VA yangi 5-argumentli)
--     bab teng mos keladi — PostgREST "PGRST203 could not choose the best
--     candidate function" beradi (bu xato bu repoda allaqachon bir marta
--     uchragan — qarang PROVODKA_JURNAL_MAYDON.sql izohi). Klient endi
--     har doim 5 argumentni ham yuboradi (standart-dev.html yangilandi).
--   * idempotent: qayta RUN qilish xavfsiz.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (faqat select)                 ##
-- #####################################################################

do $standart_limit_v2_pre$
begin
  if to_regclass('public.rbac_staff_limit') is null then
    raise exception 'rbac_staff_limit jadvali yoq — avval PROVODKA_STANDART_HODIM.sql ni bajaring';
  end if;
  if to_regclass('public.standart_xarajat') is null then
    raise exception 'standart_xarajat jadvali yoq — avval PROVODKA_V7.sql ni bajaring';
  end if;
  if to_regclass('public.aros_staff') is null then
    raise exception 'aros_staff jadvali yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;
  if to_regclass('public.staff_branch_map') is null then
    raise exception 'staff_branch_map jadvali yoq — avval PROVODKA_OVQAT.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_limit_entry_line()') is null then
    raise exception 'rbac_limit_entry_line() yoq — avval PROVODKA_STANDART_ROL.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_limit_modda(uuid, uuid)') is null then
    raise exception 'rbac_limit_modda(uuid,uuid) yoq — avval PROVODKA_STANDART_HODIM.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_limit_ovqat_staff(int, text)') is null then
    raise exception 'rbac_limit_ovqat_staff(int,text) yoq — avval PROVODKA_STANDART_HODIM.sql ni bajaring';
  end if;
  if to_regprocedure('public.standart_page_ok()') is null then
    raise exception 'standart_page_ok() yoq — avval PROVODKA_STANDART_RUXSAT.sql ni bajaring';
  end if;
  if to_regprocedure('public.standart_limit_set(uuid, uuid, numeric)') is null then
    raise exception 'standart_limit_set(uuid,uuid,numeric) yoq — avval PROVODKA_STANDART_RUXSAT.sql ni bajaring';
  end if;
  if to_regprocedure('public.standart_hodim_limit_set(int, text, numeric, boolean)') is null then
    raise exception 'standart_hodim_limit_set(int,text,numeric,boolean) yoq — avval PROVODKA_STANDART_HODIM.sql ni bajaring';
  end if;
  if to_regprocedure('public.standart_hodim_limitlar(uuid, date)') is null then
    raise exception 'standart_hodim_limitlar(uuid,date) yoq — avval PROVODKA_STANDART_HODIM.sql ni bajaring';
  end if;
  if to_regprocedure('public.standart_filial_moddalar(uuid)') is null then
    raise exception 'standart_filial_moddalar(uuid) yoq — avval PROVODKA_STANDART_ROL.sql ni bajaring';
  end if;
  if to_regprocedure('public.standart_filial_limit_sarf(uuid, date)') is null then
    raise exception 'standart_filial_limit_sarf(uuid,date) yoq — avval PROVODKA_STANDART_LIMIT_SARF.sql ni bajaring';
  end if;
  if to_regprocedure('public.standart_holat(date)') is null then
    raise exception 'standart_holat(date) yoq — avval PROVODKA_V7.sql ni bajaring';
  end if;
  if to_regprocedure('public.limit_guard_entry_line()') is null then
    raise exception 'limit_guard_entry_line() yoq — avval PROVODKA_V7.sql ni bajaring';
  end if;
  if to_regprocedure('public.conv_baza_kurs(text)') is null then
    raise exception 'conv_baza_kurs(text) yoq — avval PROVODKA_VALYUTA_ALIAS.sql (yoki PROVODKA_KASSA2.sql) ni bajaring';
  end if;
  if to_regprocedure('public._pul_turi_child_ich(uuid, text)') is null then
    raise exception '_pul_turi_child_ich(uuid,text) yoq — avval PROVODKA_TURLAR_AVTO.sql ni bajaring';
  end if;
  if to_regprocedure('public.standart_norm(text)') is null then
    raise exception 'standart_norm(text) yoq — avval PROVODKA_STANDART_ROL.sql ni bajaring';
  end if;
  if to_regprocedure('public.standart_ball(text, text)') is null then
    raise exception 'standart_ball(text,text) yoq — avval PROVODKA_STANDART_ROL.sql ni bajaring';
  end if;
  if to_regprocedure('public.rbac_staff_ovqat(int)') is null then
    raise exception 'rbac_staff_ovqat(int) yoq — avval PROVODKA_RBAC_LINK.sql ni bajaring';
  end if;
end
$standart_limit_v2_pre$;


-- #####################################################################
-- ##  1-BO'LIM — MASALA #1: rbac_limit_entry_line() qayta e'lon      ##
-- ---------------------------------------------------------------------
-- PROVODKA_STANDART_ROL.sql dagi ENG OXIRGI tananing nusxasi, YAGONA farq:
-- "filial limiti rol limitini override qiladi" bloki (standart_xarajat
-- mavjudligini tekshirib ERTA `return new` qiluvchi qism) OLIB TASHLANDI.
-- Endi bu funksiya HAR DOIM hodimning o'z (rol/hodim-override) OYLIK
-- limitini tekshiradi (created_by orqali, filialdan qat'i nazar) — filial
-- limiti esa ALOHIDA trigger (limit_guard_entry_line, PROVODKA_V7.sql,
-- TEGILMAGAN) bilan MUSTAQIL tekshiriladi. Natija: Gulnoza «Yo'l harajati»
-- moddasiga Malika filialida yozsa — ham Gulnozaning shaxsiy limiti, ham
-- (bor bo'lsa) Malika filial limiti kamayadi. Qolgan hammasi VERBATIM.
-- #####################################################################

create or replace function rbac_limit_entry_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_type    text;
  v_date    date;
  v_status  text;
  v_deleted boolean;
  v_raw     text;
  v_ega     uuid;
  v_lim     numeric;
  v_used    numeric;
  v_lbl     text;
  v_fids    uuid[];
begin
  if coalesce(new.debit, 0) <= 0 then
    return new;
  end if;

  select a.type into v_type from accounts a where a.id = new.account_id;
  if v_type is distinct from 'xarajat' then
    return new;
  end if;

  if auth.uid() is null then
    return new;                                     -- service_role (n8n)
  end if;
  if is_admin() then
    return new;
  end if;

  select e.entry_date, coalesce(e.status, 'posted'), coalesce(e.is_deleted, false),
         (to_jsonb(e) ->> 'created_by'), e.filial_ids
    into v_date, v_status, v_deleted, v_raw, v_fids
    from entry e where e.id = new.entry_id;
  if not found then
    return new;
  end if;
  if v_deleted or v_status not in ('posted', 'pending') then
    return new;
  end if;

  -- 🔴 MASALA #1 TUZATISH (2026-09-25, PROVODKA_STANDART_LIMIT_V2.sql):
  -- avvalgi "filial limiti bor bo'lsa bu shox o'tkazib yuboriladi" bloki
  -- OLIB TASHLANDI — hodimning o'z limiti HAR DOIM tekshiriladi, filial
  -- limiti bo'lishi buni bekor qilmaydi (ikkalasi mustaqil, AND emas —
  -- ikkalasi ham o'z triggerida ishlaydi).

  -- Egasi: entry.created_by (matn/uuid shaklida bo'lishi mumkin,
  -- PROVODKA_IJROCHI.sql naqshi). Bosh bo'lsa -> auth.uid(). uuid shaklida
  -- EMAS (masalan 'aros_sync') bo'lsa -> bu guard sukut qiladi (fail-open
  -- EMAS — egasi shunchaki nomalum, boshqa guardlar baribir amal qiladi).
  v_raw := nullif(btrim(coalesce(v_raw, '')), '');
  if v_raw is null then
    v_ega := auth.uid();
  elsif v_raw ~ '^[0-9a-fA-F-]{36}$' then
    v_ega := v_raw::uuid;
  else
    return new;
  end if;

  -- ONGLI QAROR (Asilbek, 2026-08-29): "Ruxsat sorovi" (PROVODKA_RUXSAT_SOROV.sql)
  -- orqali yozilgan xarajatda modda hodimning OZ rolida YOQ (aynan shu sabab
  -- sorov yozilgan) -> rbac_limit_modda null -> oylik limit TEKSHIRILMAYDI.
  -- Bu bug emas: u yerda limit orniga tasdiqlovchi odamning qarori turadi
  -- (har sorov alohida, summa/modda tasdiqlovchi koradi). Ozgartirilmasin.
  v_lim := rbac_limit_modda(v_ega, new.account_id);
  if v_lim is null then
    return new;                                      -- limit qoyilmagan yoki cheksiz
  end if;

  -- AFTER INSERT — yangi satr yigindiga ALLAQACHON kirgan (rbac_modda_ishlatildi
  -- ichida shu satr ham hisoblanadi).
  v_used := rbac_modda_ishlatildi(v_ega, new.account_id, v_date);
  if v_used > v_lim then
    select coalesce(a.code || ' ' || a.name, new.account_id::text) into v_lbl
      from accounts a where a.id = new.account_id;
    raise exception 'Oylik limit oshdi: "%" — limit %, shu oyda ishlatildi % (shu bilan)',
      v_lbl, round(v_lim), round(v_used)
      using errcode = '42501';
  end if;

  return new;
end
$fn$;

revoke all on function rbac_limit_entry_line() from public, anon;

drop trigger if exists trg_rbac_limit_entry_line on entry_line;
create trigger trg_rbac_limit_entry_line
  after insert on entry_line
  for each row execute function rbac_limit_entry_line();

comment on function rbac_limit_entry_line() is
  'rbac_role_modda.limit_uzs (yoki hodim-override) boyicha OYLIK limitni majburlaydi (egasi '
  'entry.created_by). service_role (n8n) va admin otadi. YANGI (2026-09-25, '
  'PROVODKA_STANDART_LIMIT_V2.sql): filial limiti (standart_xarajat) mavjudligi endi bu '
  'shoxni O''TKAZIB YUBORMAYDI — hodimning o''z limiti VA filial limiti (limit_guard_entry_line, '
  'mustaqil trigger) ENDI IKKALASI HAM amal qiladi.';

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  2-BO'LIM — MASALA #4: valyuta ustunlari (additive)             ##
-- ---------------------------------------------------------------------
-- Ikkala jadvalga: `limit_val` (hodimning/filialning TANLAGAN valyutasidagi
-- xom qiymati) + `valyuta` ('UZS'|'USD'|'CNY', sukut 'UZS'). `limit_uzs`
-- SAQLANADI (eski o'quvchilar uchun) — FAQAT valyuta='UZS' bo'lganda amal
-- qiladi (frozen emas, chunki UZS o'z-o'ziga muzlamaydi). Chet valyutada
-- limit_uzs NULL qoladi (kurs JONLI hisoblanadi, standart_limit_uzs orqali,
-- har o'qishda) — shuning uchun standart_xarajat.limit_uzs endi NULLABLE.
-- #####################################################################

alter table rbac_staff_limit
  add column if not exists limit_val numeric check (limit_val is null or limit_val > 0);
alter table rbac_staff_limit
  add column if not exists valyuta text not null default 'UZS' check (valyuta in ('UZS', 'USD', 'CNY'));

update rbac_staff_limit set limit_val = limit_uzs where limit_val is null and limit_uzs is not null;

comment on column rbac_staff_limit.limit_val is
  'Override qiymati hodim TANLAGAN valyutasida (masalan 1000 = $1000). valyuta=''UZS'' bolsa '
  'limit_uzs bilan bir xil (mirror). null = cheksiz override (limit_uzs ham null bolishi shart).';
comment on column rbac_staff_limit.valyuta is
  'Override valyutasi: UZS|USD|CNY. Sukut UZS (eski qatorlar). YANGI (PROVODKA_STANDART_LIMIT_V2.sql).';

alter table standart_xarajat
  add column if not exists limit_val numeric check (limit_val > 0);
alter table standart_xarajat
  add column if not exists valyuta text not null default 'UZS' check (valyuta in ('UZS', 'USD', 'CNY'));

update standart_xarajat set limit_val = limit_uzs where limit_val is null;
alter table standart_xarajat alter column limit_val set not null;
alter table standart_xarajat alter column limit_uzs drop not null;

comment on column standart_xarajat.limit_val is
  'Filial limiti TANLANGAN valyutada (masalan 1000 = $1000). valyuta=''UZS'' bolsa limit_uzs '
  'bilan bir xil (mirror). HAR DOIM to''ldirilgan (NOT NULL) — filial limitida cheksiz yoq.';
comment on column standart_xarajat.valyuta is
  'Limit valyutasi: UZS|USD|CNY. Sukut UZS (eski qatorlar). YANGI (PROVODKA_STANDART_LIMIT_V2.sql). '
  'valyuta<>UZS bolsa limit_uzs NULL boladi — jonli qiymat standart_limit_uzs()/o''quvchi '
  'funksiyalar orqali hisoblanadi (muzlatilmagan).';


-- #####################################################################
-- ##  3-BO'LIM — standart_limit_uzs(numeric, text) — YANGI ICHKI     ##
-- ---------------------------------------------------------------------
-- 1 birlik chet valyuta necha so'm ekanini conv_baza_kurs() dan JONLI
-- olib, p_val'ni so'mga o'tkazadi. UZS uchun aynan p_val. Kurs topilmasa
-- (conv_baza_kurs null) — aniq xato (yozishda fail-fast, o'qishda ham
-- exception — chaqiruvchi funksiya standart_page_ok() ortidagi RPC,
-- foydalanuvchi tushunadigan xabar ko'radi).
-- #####################################################################

create or replace function standart_limit_uzs(p_val numeric, p_cur text)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_cur  text := upper(coalesce(p_cur, 'UZS'));
  v_rate numeric;
begin
  if p_val is null then
    return null;
  end if;
  if v_cur = 'UZS' then
    return p_val;
  end if;
  if v_cur not in ('USD', 'CNY') then
    raise exception 'Nomalum valyuta: % (UZS|USD|CNY kerak)', p_cur using errcode = '22000';
  end if;

  v_rate := conv_baza_kurs(v_cur);
  if v_rate is null then
    raise exception '% kursi topilmadi (Valyuta bo''limida kurs kiritilmagan)', v_cur using errcode = '22023';
  end if;

  return round(p_val * v_rate, 2);
end
$fn$;

revoke all on function standart_limit_uzs(numeric, text) from public, anon, authenticated;

comment on function standart_limit_uzs(numeric, text) is
  'ICHKI: p_val (p_cur valyutasida) necha so''m ekanini JONLI hisoblaydi (conv_baza_kurs orqali, '
  'muzlatilmagan). UZS -> aynan p_val. Kurs topilmasa exception (fail-fast).';


-- #####################################################################
-- ##  4-BO'LIM — rbac_limit_modda(uuid,uuid) qayta e'lon             ##
-- ---------------------------------------------------------------------
-- PROVODKA_STANDART_HODIM.sql dagi tananing nusxasi + hodim-override
-- o'qilishi endi valyuta-aware (limit_val/valyuta, standart_limit_uzs).
-- Rol qismi (o'zgarmagan — rollar hamon faqat UZS) VERBATIM.
-- #####################################################################

create or replace function rbac_limit_modda(p_uid uuid, p_account uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_staff    int;
  v_found    boolean := false;
  v_ov_lim   numeric;
  v_ov_val   numeric;
  v_ov_cur   text;
  v_cnt      int;
  v_has_null boolean;
  v_max      numeric;
begin
  if to_regclass('public.rbac_staff_limit') is not null then
    select s.staff_id into v_staff from aros_staff s where s.user_id = p_uid limit 1;
    if v_staff is not null then
      select true, sl.limit_uzs, sl.limit_val, coalesce(sl.valyuta, 'UZS')
        into v_found, v_ov_lim, v_ov_val, v_ov_cur
        from rbac_staff_limit sl
       where sl.staff_id = v_staff and sl.kalit = 'modda:' || p_account::text;
      if coalesce(v_found, false) then
        if v_ov_lim is null and v_ov_val is null then
          return null;                                -- cheksiz override
        end if;
        if v_ov_cur = 'UZS' then
          return coalesce(v_ov_lim, v_ov_val);
        end if;
        return standart_limit_uzs(v_ov_val, v_ov_cur); -- YANGI: chet valyuta, jonli kurs
      end if;
    end if;
  end if;

  select count(*), bool_or(rm.limit_uzs is null), max(rm.limit_uzs)
    into v_cnt, v_has_null, v_max
    from rbac_user_role ur
    join rbac_role r on r.id = ur.role_id and r.is_active
    join rbac_role_modda rm on rm.role_id = ur.role_id and rm.account_id = p_account
   where ur.user_id = p_uid;

  if coalesce(v_cnt, 0) = 0 then
    return null;                                    -- shu moddaga rolida limit qoyilmagan
  end if;
  if v_has_null then
    return null;                                     -- kamida bitta rolda cheksiz
  end if;
  return v_max;
end
$fn$;

revoke all on function rbac_limit_modda(uuid, uuid) from public, anon, authenticated;

comment on function rbac_limit_modda(uuid, uuid) is
  'ICHKI: foydalanuvchining (rbac_user_role orqali) shu xarajat moddasiga effektiv oylik limiti. '
  'Hodim darajasidagi override (rbac_staff_limit, ''modda:<account>'') bor bo''lsa — rol '
  'logikasidan OLDIN o''sha qaytadi (null = cheksiz). YANGI (PROVODKA_STANDART_LIMIT_V2.sql): '
  'override chet valyutada (USD/CNY) bo''lsa — standart_limit_uzs() orqali JONLI so''mga '
  'o''tkaziladi. Rolida modda yoq -> null. Bir nechta rolda bittasi cheksiz -> null. Aks holda MAX(limit_uzs).';


-- #####################################################################
-- ##  5-BO'LIM — rbac_limit_ovqat_staff(int,text) qayta e'lon        ##
-- ---------------------------------------------------------------------
-- PROVODKA_STANDART_HODIM.sql dagi tananing nusxasi + per-tur hodim-override
-- o'qilishi endi valyuta-aware. 'ovqat:umumiy' shoxi (per-tur cheksiz)
-- VERBATIM (jami limit rbac_ovqat_umumiy_qoldi() da alohida tekshiriladi,
-- u ham valyuta-aware — 11-BO'LIMga qarang, standart_hodim_limitlar orqali
-- ko'rsatiladi; xarajat_saqlash_ovqat guardidagi chaqiruv o'zgarmagan).
-- #####################################################################

create or replace function rbac_limit_ovqat_staff(p_staff int, p_tur text)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_user_id  uuid;
  v_found    boolean := false;
  v_ov_lim   numeric;
  v_ov_val   numeric;
  v_ov_cur   text;
  v_cnt      int;
  v_has_null boolean;
  v_max      numeric;
begin
  if to_regclass('public.rbac_staff_limit') is not null then
    if exists (
      select 1 from rbac_staff_limit where staff_id = p_staff and kalit = 'ovqat:umumiy'
    ) then
      return null;               -- UMUMIY rejim — per-tur cheksiz, jami boshqa joyda tekshiriladi
    end if;

    select true, limit_uzs, limit_val, coalesce(valyuta, 'UZS')
      into v_found, v_ov_lim, v_ov_val, v_ov_cur
      from rbac_staff_limit
     where staff_id = p_staff and kalit = 'ovqat:' || p_tur;
    if coalesce(v_found, false) then
      if v_ov_lim is null and v_ov_val is null then
        return null;                                  -- cheksiz override
      end if;
      if v_ov_cur = 'UZS' then
        return coalesce(v_ov_lim, v_ov_val);
      end if;
      return standart_limit_uzs(v_ov_val, v_ov_cur);   -- YANGI: chet valyuta, jonli kurs
    end if;
  end if;

  select user_id into v_user_id from aros_staff where staff_id = p_staff;

  if v_user_id is not null then
    select count(*), bool_or(ro.limit_uzs is null), max(ro.limit_uzs)
      into v_cnt, v_has_null, v_max
      from rbac_user_role ur
      join rbac_role r on r.id = ur.role_id and r.is_active
      join rbac_role_ovqat ro on ro.role_id = ur.role_id and ro.tur = p_tur
     where ur.user_id = v_user_id;
  else
    select count(*), bool_or(ro.limit_uzs is null), max(ro.limit_uzs)
      into v_cnt, v_has_null, v_max
      from rbac_staff_role sr
      join rbac_role r on r.id = sr.role_id and r.is_active
      join rbac_role_ovqat ro on ro.role_id = sr.role_id and ro.tur = p_tur
     where sr.staff_id = p_staff;
  end if;

  if coalesce(v_cnt, 0) = 0 then
    return null;
  end if;
  if v_has_null then
    return null;
  end if;
  return v_max;
end
$fn$;

revoke all on function rbac_limit_ovqat_staff(int, text) from public, anon, authenticated;

comment on function rbac_limit_ovqat_staff(int, text) is
  'ICHKI: YEYUVCHI hodimning shu ovqat turiga effektiv oylik limiti. ''ovqat:umumiy'' override '
  'bor bo''lsa — null (per-tur cheksiz). Aks holda shu turga override bo''lsa — o''sha (YANGI, '
  'PROVODKA_STANDART_LIMIT_V2.sql: chet valyutada bo''lsa standart_limit_uzs() orqali jonli). '
  'Aks holda eski rol logikasi (rbac_staff_ovqat bilan bir xil manba).';


-- #####################################################################
-- ##  6-BO'LIM — standart_limit_set: eski imzo + YANGI overload      ##
-- #####################################################################

-- 6.1 — eski imzo (uuid,uuid,numeric) qayta e'lon: limit_val/valyuta='UZS'
-- ham to'ldiriladi (standart_xarajat.limit_val NOT NULL bo'lgani uchun
-- SHART) — bu chaqiruv HAR DOIM UZS deb qabul qilinadi (imzoda valyuta yo'q).
create or replace function standart_limit_set(p_filial uuid, p_modda uuid, p_limit numeric)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare v_id uuid; v_by text;
begin
  if not standart_page_ok() then
    raise exception 'Standart xarajatlar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;
  if p_filial is null or p_modda is null then raise exception 'Filial/modda tanlanmadi' using errcode = '22000'; end if;
  if p_limit is null or p_limit <= 0 then raise exception 'Limit musbat bo''lishi kerak' using errcode = '22000'; end if;
  select coalesce(full_name, '') into v_by from profiles where id = auth.uid();
  insert into standart_xarajat (filial_id, modda_id, limit_uzs, limit_val, valyuta, updated_by)
  values (p_filial, p_modda, p_limit, p_limit, 'UZS', v_by)
  on conflict (filial_id, modda_id) do update
    set limit_uzs = excluded.limit_uzs, limit_val = excluded.limit_val,
        valyuta = excluded.valyuta, updated_by = excluded.updated_by
  returning id into v_id;
  return v_id;
end $fn$;

revoke all on function standart_limit_set(uuid, uuid, numeric) from public, anon;
grant execute on function standart_limit_set(uuid, uuid, numeric) to authenticated;

comment on function standart_limit_set(uuid, uuid, numeric) is
  'Limit qo''yish/yangilash — UZS ONLY (chet valyuta uchun standart_limit_set(uuid,uuid,numeric,text) '
  'ishlatilsin). YANGI (PROVODKA_STANDART_LIMIT_V2.sql): limit_val/valyuta=''UZS'' ham yozadi '
  '(oldingi chet-valyuta override bo''lsa ham UZS ga qaytaradi — imzoda valyuta yo''q).';

-- 6.2 — YANGI overload: valyuta tanlab limit qo'yish (UZS|USD|CNY).
create or replace function standart_limit_set(p_filial uuid, p_modda uuid, p_limit numeric, p_valyuta text)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_id  uuid;
  v_by  text;
  v_cur text := upper(coalesce(p_valyuta, 'UZS'));
begin
  if not standart_page_ok() then
    raise exception 'Standart xarajatlar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;
  if p_filial is null or p_modda is null then raise exception 'Filial/modda tanlanmadi' using errcode = '22000'; end if;
  if p_limit is null or p_limit <= 0 then raise exception 'Limit musbat bo''lishi kerak' using errcode = '22000'; end if;
  if v_cur not in ('UZS', 'USD', 'CNY') then
    raise exception 'Valyuta noto''g''ri: % (UZS|USD|CNY kerak)', p_valyuta using errcode = '22000';
  end if;

  -- fail-fast: chet valyutada kurs yo'q bo'lsa yozishdan OLDIN xato.
  if v_cur <> 'UZS' then
    perform standart_limit_uzs(p_limit, v_cur);
  end if;

  select coalesce(full_name, '') into v_by from profiles where id = auth.uid();
  insert into standart_xarajat (filial_id, modda_id, limit_uzs, limit_val, valyuta, updated_by)
  values (p_filial, p_modda, case when v_cur = 'UZS' then p_limit else null end, p_limit, v_cur, v_by)
  on conflict (filial_id, modda_id) do update
    set limit_uzs = excluded.limit_uzs, limit_val = excluded.limit_val,
        valyuta = excluded.valyuta, updated_by = excluded.updated_by
  returning id into v_id;
  return v_id;
end
$fn$;

revoke all on function standart_limit_set(uuid, uuid, numeric, text) from public, anon;
grant execute on function standart_limit_set(uuid, uuid, numeric, text) to authenticated;

comment on function standart_limit_set(uuid, uuid, numeric, text) is
  'YANGI (PROVODKA_STANDART_LIMIT_V2.sql): standart_limit_set(uuid,uuid,numeric) bilan bir xil, '
  'lekin p_valyuta (UZS|USD|CNY) qo''shiladi. Chet valyutada limit_uzs NULL qoladi (jonli hisoblanadi).';


-- #####################################################################
-- ##  7-BO'LIM — standart_hodim_limit_set: eski imzo + YANGI overload ##
-- #####################################################################

-- 7.1 — eski imzo (int,text,numeric,boolean) qayta e'lon: yozganda
-- limit_val/valyuta='UZS' ham normallashtiradi (bu imzo — UZS ONLY yo'l).
create or replace function standart_hodim_limit_set(p_staff int, p_kalit text,
                                                     p_limit numeric,
                                                     p_cheksiz boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_account uuid;
  v_tur     text;
  v_ok_role boolean := false;
begin
  if not standart_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  if p_staff is null or p_kalit is null then
    raise exception 'Hodim/kalit tanlanmadi' using errcode = '22000';
  end if;
  if not exists (select 1 from aros_staff where staff_id = p_staff) then
    raise exception 'Hodim topilmadi: %', p_staff using errcode = '22023';
  end if;
  if p_limit is not null and p_limit <= 0 then
    raise exception 'Limit musbat bo''lishi kerak (bo''sh/cheksiz belgi bilan cheksiz qo''yiladi)'
      using errcode = '22000';
  end if;

  if p_kalit ~ '^modda:[0-9a-fA-F-]{36}$' then
    v_account := substring(p_kalit from 7)::uuid;
  elsif p_kalit in ('ovqat:obed', 'ovqat:zavtrak', 'ovqat:kechki', 'ovqat:umumiy') then
    v_tur := substring(p_kalit from 7);
  else
    raise exception 'Kalit shakli notogri (modda:<uuid> yoki ovqat:obed|zavtrak|kechki|umumiy kerak)'
      using errcode = '22000';
  end if;

  if v_account is not null then
    select exists (
      select 1
        from rbac_staff_role sr
        join rbac_role_modda rm on rm.role_id = sr.role_id
        join accounts a on a.id = rm.account_id and a.type = 'xarajat' and not coalesce(a.ovqat_modda, false)
       where sr.staff_id = p_staff and rm.account_id = v_account
      union all
      select 1
        from aros_staff s
        join rbac_user_role ur on ur.user_id = s.user_id
        join rbac_role r on r.id = ur.role_id and r.is_active
        join rbac_role_modda rm on rm.role_id = ur.role_id
        join accounts a on a.id = rm.account_id and a.type = 'xarajat' and not coalesce(a.ovqat_modda, false)
       where s.staff_id = p_staff and s.user_id is not null and rm.account_id = v_account
      union all
      select 1
        from aros_staff s
        join profiles p on p.id = s.user_id
        join accounts a on a.id = v_account and a.type = 'xarajat' and not coalesce(a.ovqat_modda, false)
       where s.staff_id = p_staff and s.user_id is not null and p.role = 'admin'
    ) into v_ok_role;
    if not v_ok_role then
      raise exception 'Bu modda hodimning rollarida yoq' using errcode = '22000';
    end if;
  end if;

  if v_tur is not null and v_tur <> 'umumiy' then
    if not (v_tur = any(rbac_staff_ovqat(p_staff))) then
      raise exception 'Bu ovqat turi hodim rolida yoq' using errcode = '22000';
    end if;
  end if;
  if v_tur = 'umumiy' and cardinality(rbac_staff_ovqat(p_staff)) = 0 then
    raise exception 'Hodimning hech qaysi ovqat turiga ruxsati yoq' using errcode = '22000';
  end if;

  if p_limit is null and not coalesce(p_cheksiz, false) then
    delete from rbac_staff_limit where staff_id = p_staff and kalit = p_kalit;
    return jsonb_build_object('ok', true, 'holat', 'rol_limitiga_qaytdi');
  end if;

  insert into rbac_staff_limit (staff_id, kalit, limit_uzs, limit_val, valyuta, updated_by, updated_at)
  values (p_staff, p_kalit, p_limit, p_limit, 'UZS', auth.uid(), now())
  on conflict (staff_id, kalit) do update
    set limit_uzs  = excluded.limit_uzs,
        limit_val  = excluded.limit_val,
        valyuta    = excluded.valyuta,
        updated_by = excluded.updated_by,
        updated_at = now();

  return jsonb_build_object('ok', true, 'holat', case when p_limit is null then 'cheksiz' else 'saqlandi' end);
end
$fn$;

revoke all on function standart_hodim_limit_set(int, text, numeric, boolean) from public, anon;
grant execute on function standart_hodim_limit_set(int, text, numeric, boolean) to authenticated;

comment on function standart_hodim_limit_set(int, text, numeric, boolean) is
  'Hodim darajasidagi limit override — UZS ONLY (chet valyuta uchun standart_hodim_limit_set '
  '(int,text,numeric,boolean,text) ishlatilsin). YANGI (PROVODKA_STANDART_LIMIT_V2.sql): '
  'limit_val/valyuta=''UZS'' ham yozadi.';

-- 7.2 — YANGI overload: valyuta tanlab hodim override qo'yish (UZS|USD|CNY).
-- 🔴 p_valyuta ATAYLAB DEFAULTSIZ — sabab 0-bo'lim/fayl boshidagi izohda
--    (PostgREST overload ambiguity, PROVODKA_JURNAL_MAYDON.sql saboqi).
create or replace function standart_hodim_limit_set(p_staff int, p_kalit text,
                                                     p_limit numeric,
                                                     p_cheksiz boolean,
                                                     p_valyuta text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_account uuid;
  v_tur     text;
  v_ok_role boolean := false;
  v_cur     text := upper(coalesce(p_valyuta, 'UZS'));
begin
  if not standart_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  if v_cur not in ('UZS', 'USD', 'CNY') then
    raise exception 'Valyuta noto''g''ri: % (UZS|USD|CNY kerak)', p_valyuta using errcode = '22000';
  end if;

  if p_staff is null or p_kalit is null then
    raise exception 'Hodim/kalit tanlanmadi' using errcode = '22000';
  end if;
  if not exists (select 1 from aros_staff where staff_id = p_staff) then
    raise exception 'Hodim topilmadi: %', p_staff using errcode = '22023';
  end if;
  if p_limit is not null and p_limit <= 0 then
    raise exception 'Limit musbat bo''lishi kerak (bo''sh/cheksiz belgi bilan cheksiz qo''yiladi)'
      using errcode = '22000';
  end if;

  if p_kalit ~ '^modda:[0-9a-fA-F-]{36}$' then
    v_account := substring(p_kalit from 7)::uuid;
  elsif p_kalit in ('ovqat:obed', 'ovqat:zavtrak', 'ovqat:kechki', 'ovqat:umumiy') then
    v_tur := substring(p_kalit from 7);
  else
    raise exception 'Kalit shakli notogri (modda:<uuid> yoki ovqat:obed|zavtrak|kechki|umumiy kerak)'
      using errcode = '22000';
  end if;

  if v_account is not null then
    select exists (
      select 1
        from rbac_staff_role sr
        join rbac_role_modda rm on rm.role_id = sr.role_id
        join accounts a on a.id = rm.account_id and a.type = 'xarajat' and not coalesce(a.ovqat_modda, false)
       where sr.staff_id = p_staff and rm.account_id = v_account
      union all
      select 1
        from aros_staff s
        join rbac_user_role ur on ur.user_id = s.user_id
        join rbac_role r on r.id = ur.role_id and r.is_active
        join rbac_role_modda rm on rm.role_id = ur.role_id
        join accounts a on a.id = rm.account_id and a.type = 'xarajat' and not coalesce(a.ovqat_modda, false)
       where s.staff_id = p_staff and s.user_id is not null and rm.account_id = v_account
      union all
      select 1
        from aros_staff s
        join profiles p on p.id = s.user_id
        join accounts a on a.id = v_account and a.type = 'xarajat' and not coalesce(a.ovqat_modda, false)
       where s.staff_id = p_staff and s.user_id is not null and p.role = 'admin'
    ) into v_ok_role;
    if not v_ok_role then
      raise exception 'Bu modda hodimning rollarida yoq' using errcode = '22000';
    end if;
  end if;

  if v_tur is not null and v_tur <> 'umumiy' then
    if not (v_tur = any(rbac_staff_ovqat(p_staff))) then
      raise exception 'Bu ovqat turi hodim rolida yoq' using errcode = '22000';
    end if;
  end if;
  if v_tur = 'umumiy' and cardinality(rbac_staff_ovqat(p_staff)) = 0 then
    raise exception 'Hodimning hech qaysi ovqat turiga ruxsati yoq' using errcode = '22000';
  end if;

  if p_limit is null and not coalesce(p_cheksiz, false) then
    delete from rbac_staff_limit where staff_id = p_staff and kalit = p_kalit;
    return jsonb_build_object('ok', true, 'holat', 'rol_limitiga_qaytdi');
  end if;

  -- fail-fast: chet valyutada kurs topilmasa yozishdan OLDIN xato.
  if p_limit is not null and v_cur <> 'UZS' then
    perform standart_limit_uzs(p_limit, v_cur);
  end if;

  insert into rbac_staff_limit (staff_id, kalit, limit_uzs, limit_val, valyuta, updated_by, updated_at)
  values (p_staff, p_kalit,
          case when p_limit is null then null when v_cur = 'UZS' then p_limit else null end,
          p_limit, v_cur, auth.uid(), now())
  on conflict (staff_id, kalit) do update
    set limit_uzs  = excluded.limit_uzs,
        limit_val  = excluded.limit_val,
        valyuta    = excluded.valyuta,
        updated_by = excluded.updated_by,
        updated_at = now();

  return jsonb_build_object('ok', true, 'holat', case when p_limit is null then 'cheksiz' else 'saqlandi' end);
end
$fn$;

revoke all on function standart_hodim_limit_set(int, text, numeric, boolean, text) from public, anon;
grant execute on function standart_hodim_limit_set(int, text, numeric, boolean, text) to authenticated;

comment on function standart_hodim_limit_set(int, text, numeric, boolean, text) is
  'YANGI (PROVODKA_STANDART_LIMIT_V2.sql): standart_hodim_limit_set(int,text,numeric,boolean) '
  'bilan bir xil, lekin p_valyuta (UZS|USD|CNY, DEFAULTSIZ — PostgREST ambiguity oldini olish '
  'uchun) qo''shiladi. Chet valyutada limit_uzs NULL qoladi (jonli hisoblanadi).';

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  8-BO'LIM — MASALA #6: staff_filial_qolda jadvali (YANGI)       ##
-- ---------------------------------------------------------------------
-- Aros filiali (branch_id) bo'lmagan yoki staff_branch_map xaritasiga
-- tushmagan hodimni QO'LDA bitta Provodka filialiga biriktirish.
-- standart_filial_moddalar/standart_hodim_limitlar/standart_filial_limit_sarf
-- buni staff_branch_map bilan UNION qilib o'qiydi (9/10/11-BO'LIM).
-- #####################################################################

create table if not exists staff_filial_qolda (
  staff_id   int         primary key references aros_staff(staff_id) on delete cascade,
  filial_id  uuid        not null references accounts(id),
  updated_at timestamptz not null default now(),
  updated_by uuid
);

comment on table staff_filial_qolda is
  'Aros filial xaritasiga (staff_branch_map) tushmaydigan hodimni QO''LDA bitta Provodka filial '
  'kassasiga (accounts.id, kassa_turi=filial) biriktirish (masalan "Ta''minot Xitoy"). '
  'standart_filial_moddalar/standart_hodim_limitlar/standart_filial_limit_sarf buni '
  'staff_branch_map bilan UNION qilib o''qiydi — qo''shimcha filial a''zoligi.';

alter table staff_filial_qolda enable row level security;

drop policy if exists staff_filial_qolda_sel on staff_filial_qolda;
create policy staff_filial_qolda_sel on staff_filial_qolda
  for select to authenticated using (true);

-- 🔴 insert/update/delete policy YO'Q — hozircha bu faylning 15-BO'LIMi
--    (owner/service_role sifatida) yozadi. Kelajakda admin RPC kerak
--    bo'lsa alohida ish sifatida qo'shiladi.
revoke all on staff_filial_qolda from public, anon;
grant select on staff_filial_qolda to authenticated;


-- #####################################################################
-- ##  9-BO'LIM — standart_filial_moddalar(uuid) qayta e'lon          ##
-- ---------------------------------------------------------------------
-- PROVODKA_STANDART_LIMIT_SARF.sql dagi ENG OXIRGI tananing nusxasi (ovqat
-- moddasi rbac_role_ovqat dan limit oladigan versiya) + IKKI qo'shimcha:
-- (a) staff_in ga staff_filial_qolda UNION shoxi (MASALA #6); (b) chiqishga
-- filial_limit_val/filial_limit_valyuta + filial_limit_uzs endi valyuta-aware
-- (MASALA #4). Qolgani VERBATIM.
-- #####################################################################

create or replace function standart_filial_moddalar(p_filial uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_page_ok    boolean := false;
  v_filial_id  uuid;
  v_filial_nom text;
  v_bids       int[];
begin
  if auth.uid() is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  if is_admin() then
    v_page_ok := true;
  elsif exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'perm_has_page'
  ) then
    v_page_ok := perm_has_page('standart');
  end if;
  if not v_page_ok then
    raise exception 'Standart xarajatlar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;

  if p_filial is null then
    raise exception 'Filial tanlanmadi' using errcode = '22000';
  end if;

  select id, name into v_filial_id, v_filial_nom
    from accounts
   where id = p_filial
     and kassa_turi = 'filial'
     and parent_id is null
     and coalesce(is_active, true);
  if v_filial_id is null then
    raise exception 'Filial topilmadi: %', p_filial using errcode = '22023';
  end if;

  select coalesce(array_agg(m.branch_id), '{}'::int[]) into v_bids
    from staff_branch_map m
   where m.filial_id = v_filial_id or m.provodka_filial = v_filial_nom;

  return (
    with staff_in as (
      select s.staff_id,
             coalesce(nullif(btrim(s.toliq_nom), ''),
                      btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))) as nom,
             s.lavozim, s.user_id
        from aros_staff s
       where s.is_active
         and (
           s.branch_id = any(v_bids)
           or exists (
             select 1 from jsonb_array_elements(coalesce(s.branches, '[]'::jsonb)) b
              where (b ->> 'id') ~ '^\d+$' and (b ->> 'id')::int = any(v_bids)
           )
           -- 🔴 YANGI (MASALA #6, PROVODKA_STANDART_LIMIT_V2.sql): qo'lda biriktirilgan
           --    (Aros filiali yo'q) hodim ham shu filialga tegishli hisoblanadi.
           or exists (
             select 1 from staff_filial_qolda q
              where q.staff_id = s.staff_id and q.filial_id = v_filial_id
           )
         )
    ),
    -- Bog'langan (user_id bor) VA o'sha user admin -> alohida shox (rbac_staff_ovqat
    -- bilan bir xil: profiles.role='admin'). Profiles qatori yo'q -> admin EMAS.
    staff_admin as (
      select si.staff_id
        from staff_in si
        join profiles p on p.id = si.user_id
       where si.user_id is not null and p.role = 'admin'
    ),
    -- Effektiv rollar: admin-bog'langan hodim bu yerda YO'Q (alohida qatnaydi).
    staff_role as (
      select si.staff_id, r.id as role_id, r.nom as role_nom
        from staff_in si
        join rbac_user_role ur on ur.user_id = si.user_id
        join rbac_role r on r.id = ur.role_id and r.is_active
       where si.user_id is not null
         and not exists (select 1 from staff_admin sa where sa.staff_id = si.staff_id)
      union all
      select si.staff_id, r.id, r.nom
        from staff_in si
        join rbac_staff_role sr on sr.staff_id = si.staff_id
        join rbac_role r on r.id = sr.role_id and r.is_active
       where si.user_id is null
    ),
    hodim_rollar as (
      select si.staff_id, si.nom, si.lavozim,
             case when exists (select 1 from staff_admin sa where sa.staff_id = si.staff_id)
                  then '["Admin"]'::jsonb
                  else coalesce((
                    select jsonb_agg(distinct sr.role_nom order by sr.role_nom)
                      from staff_role sr where sr.staff_id = si.staff_id
                  ), '[]'::jsonb)
             end as rollar
        from staff_in si
    ),
    -- Modda yig'ma manbasi: oddiy rol orqali (faqat xarajat/faol modda) +
    -- admin-bog'langan hodim uchun HAMMA faol xarajat modda (cheksiz).
    modda_z as (
      select sr.staff_id, si.nom, am.id as modda_id, rm.limit_uzs
        from staff_role sr
        join staff_in si on si.staff_id = sr.staff_id
        join rbac_role_modda rm on rm.role_id = sr.role_id
        join accounts am on am.id = rm.account_id and am.type = 'xarajat' and coalesce(am.is_active, true)
                        and not coalesce(am.ovqat_modda, false)
      union all
      -- 🔴 OVQAT moddasi: limit rbac_role_modda da EMAS — rbac_role_ovqat da
      -- (rol × obed/zavtrak/kechki). Rol limiti = turlar yig'indisi; bittasi
      -- cheksiz bo'lsa cheksiz.
      select sr.staff_id, si.nom, am.id as modda_id,
             case when bool_or(ro.limit_uzs is null) then null else sum(ro.limit_uzs) end
        from staff_role sr
        join staff_in si on si.staff_id = sr.staff_id
        join rbac_role_ovqat ro on ro.role_id = sr.role_id
        cross join (select a.id from accounts a
                     where coalesce(a.ovqat_modda, false) and a.type = 'xarajat'
                       and coalesce(a.is_active, true)) am
       group by sr.staff_id, si.nom, am.id, sr.role_id
      union all
      select sa.staff_id, si.nom, a.id as modda_id, null::numeric as limit_uzs
        from staff_admin sa
        join staff_in si on si.staff_id = sa.staff_id
        cross join accounts a
       where a.type = 'xarajat' and coalesce(a.is_active, true)
    ),
    -- Har hodimning shu moddaga EFFEKTIV limiti: rollari ichidan MAX, bittasi cheksiz → cheksiz
    hodim_lim as (
      select z.staff_id, z.modda_id,
             bool_or(z.limit_uzs is null) as cheksiz,
             max(z.limit_uzs)             as lim
        from modda_z z
       group by z.staff_id, z.modda_id
    ),
    -- Shu oyda FILIAL bo'yicha sarf (entry.filial_ids; posted+pending) — standart_holat bilan bir manba
    modda_sarf as (
      select h.modda_id,
             coalesce((select sum(el.debit)
                         from entry e
                         join entry_line el on el.entry_id = e.id and el.account_id = h.modda_id and el.debit > 0
                        where e.is_deleted = false and e.status in ('posted', 'pending')
                          and date_trunc('month', e.entry_date)
                              = date_trunc('month', (now() at time zone 'Asia/Tashkent')::date)
                          and v_filial_id = any(e.filial_ids)), 0) as sarf_uzs
        from (select distinct modda_id from modda_z) h
    ),
    modda_agg as (
      select z.modda_id,
             count(distinct z.staff_id)::int as hodim_soni,
             to_jsonb(array_agg(distinct z.nom order by z.nom)) as hodimlar,
             min(z.limit_uzs) filter (where z.limit_uzs is not null) as rol_limit_min,
             max(z.limit_uzs) filter (where z.limit_uzs is not null) as rol_limit_max,
             bool_or(z.limit_uzs is null) as cheksiz_bor,
             -- JAMI = filial hodimlari effektiv limitlari yig'indisi (Asilbek: «jami necha pul ruxsat berilgan»)
             (select sum(hl.lim) filter (where not hl.cheksiz) from hodim_lim hl where hl.modda_id = z.modda_id) as rol_limit_jami,
             (select ms.sarf_uzs from modda_sarf ms where ms.modda_id = z.modda_id) as sarf_uzs
        from modda_z z
       group by z.modda_id
    ),
    -- Filialga bog'langan Aros bo'limlar (filial_id VA provodka_filial ikkalasidan
    -- ham — v_bids bilan bir xil manba), UI'da "Bo'limlar: X (N hodim)" uchun.
    branch_in as (
      select m.branch_id, m.branch_nomi
        from staff_branch_map m
       where m.filial_id = v_filial_id or m.provodka_filial = v_filial_nom
    )
    select jsonb_build_object(
      'filial', jsonb_build_object('id', v_filial_id, 'name', v_filial_nom),
      'bog_yoq', (array_length(v_bids, 1) is null),
      'branchlar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'branch_id',   bi.branch_id,
                 'branch_nomi', bi.branch_nomi,
                 'hodim_soni',  (
                   select count(*) from aros_staff s2
                    where s2.is_active
                      and (s2.branch_id = bi.branch_id
                           or exists (
                             select 1 from jsonb_array_elements(coalesce(s2.branches, '[]'::jsonb)) b2
                              where (b2 ->> 'id') ~ '^\d+$' and (b2 ->> 'id')::int = bi.branch_id
                           ))
                 )
               ) order by bi.branch_nomi)
          from branch_in bi
      ), '[]'::jsonb),
      'hodimlar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'staff_id',  hr.staff_id,
                 'toliq_nom', hr.nom,
                 'lavozim',   hr.lavozim,
                 'rollar',    hr.rollar
               ) order by hr.nom)
          from hodim_rollar hr
      ), '[]'::jsonb),
      'moddalar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'modda_id',             ma.modda_id,
                 'code',                 a.code,
                 'name',                 a.name,
                 'hodim_soni',           ma.hodim_soni,
                 'hodimlar',             ma.hodimlar,
                 'rol_limit_min',        ma.rol_limit_min,
                 'rol_limit_max',        ma.rol_limit_max,
                 'rol_limit_jami',       ma.rol_limit_jami,
                 'sarf_uzs',             ma.sarf_uzs,
                 'cheksiz_bor',          ma.cheksiz_bor,
                 'filial_limit_uzs',     case when sx.id is null then null
                                              when coalesce(sx.valyuta, 'UZS') = 'UZS' then coalesce(sx.limit_uzs, sx.limit_val)
                                              else standart_limit_uzs(sx.limit_val, sx.valyuta) end,
                 'filial_limit_val',     sx.limit_val,
                 'filial_limit_valyuta', coalesce(sx.valyuta, 'UZS')
               ) order by a.code)
          from modda_agg ma
          join accounts a on a.id = ma.modda_id
          left join standart_xarajat sx on sx.filial_id = v_filial_id and sx.modda_id = ma.modda_id
      ), '[]'::jsonb)
    )
  );
end
$fn$;

revoke all on function standart_filial_moddalar(uuid) from public, anon;
grant execute on function standart_filial_moddalar(uuid) to authenticated;

comment on function standart_filial_moddalar(uuid) is
  'Standart xarajatlar UI: shu filial hodimlari (staff_branch_map + YANGI staff_filial_qolda, '
  'MASALA #6) + ularning EFFEKTIV rollaridagi xarajat moddalari + filial_limit_uzs/val/valyuta '
  '(MASALA #4, chet valyutada jonli hisoblangan). Admin yoki ''standart'' sahifa ruxsati kerak.';


-- #####################################################################
-- ##  10-BO'LIM — standart_filial_limit_sarf(uuid,date) qayta e'lon  ##
-- ---------------------------------------------------------------------
-- PROVODKA_STANDART_LIMIT_SARF.sql dagi tananing VERBATIM nusxasi + BITTA
-- qo'shimcha: staff_in ga staff_filial_qolda UNION shoxi (MASALA #6). Bu
-- funksiya rbac_staff_limit/standart_xarajat ni O'QIMAYDI (limitlar FAQAT
-- rol orqali) — shuning uchun valyuta o'zgarishi bu yerga TA'SIR qilmaydi.
-- #####################################################################

create or replace function standart_filial_limit_sarf(p_filial uuid,
                                                      p_oy date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_page_ok    boolean := false;
  v_filial_id  uuid;
  v_filial_nom text;
  v_bids       int[];
  v_oy         date;
begin
  if auth.uid() is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  -- Ruxsat: standart_filial_moddalar bilan AYNAN bir xil qoida.
  if is_admin() then
    v_page_ok := true;
  elsif exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'perm_has_page'
  ) then
    v_page_ok := perm_has_page('standart');
  end if;
  if not v_page_ok then
    raise exception 'Standart xarajatlar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;

  if p_filial is null then
    raise exception 'Filial tanlanmadi' using errcode = '22000';
  end if;

  v_oy := date_trunc('month', coalesce(p_oy, (now() at time zone 'Asia/Tashkent')::date))::date;

  select id, name into v_filial_id, v_filial_nom
    from accounts
   where id = p_filial
     and kassa_turi = 'filial'
     and parent_id is null
     and coalesce(is_active, true);
  if v_filial_id is null then
    raise exception 'Filial topilmadi: %', p_filial using errcode = '22023';
  end if;

  select coalesce(array_agg(m.branch_id), '{}'::int[]) into v_bids
    from staff_branch_map m
   where m.filial_id = v_filial_id or m.provodka_filial = v_filial_nom;

  return (
    with staff_in as (
      select s.staff_id,
             coalesce(nullif(btrim(s.toliq_nom), ''),
                      btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))) as nom,
             s.lavozim, s.user_id
        from aros_staff s
       where s.is_active
         and (
           s.branch_id = any(v_bids)
           or exists (
             select 1 from jsonb_array_elements(coalesce(s.branches, '[]'::jsonb)) b
              where (b ->> 'id') ~ '^\d+$' and (b ->> 'id')::int = any(v_bids)
           )
           -- 🔴 YANGI (MASALA #6, PROVODKA_STANDART_LIMIT_V2.sql).
           or exists (
             select 1 from staff_filial_qolda q
              where q.staff_id = s.staff_id and q.filial_id = v_filial_id
           )
         )
    ),
    staff_admin as (
      select si.staff_id
        from staff_in si
        join profiles p on p.id = si.user_id
       where si.user_id is not null and p.role = 'admin'
    ),
    staff_role as (
      select si.staff_id, r.id as role_id
        from staff_in si
        join rbac_user_role ur on ur.user_id = si.user_id
        join rbac_role r on r.id = ur.role_id and r.is_active
       where si.user_id is not null
         and not exists (select 1 from staff_admin sa where sa.staff_id = si.staff_id)
      union all
      select si.staff_id, r.id
        from staff_in si
        join rbac_staff_role sr on sr.staff_id = si.staff_id
        join rbac_role r on r.id = sr.role_id and r.is_active
       where si.user_id is null
    ),
    -- 🔴 HODIMNING O'Z KASSASI (5400 ostidagi 54xx, kassa_turi='xarajat') —
    -- filial kassasi EMAS. Bog'lanish nom bo'yicha: kassa nomi = hodim ismi
    -- (TaskFix shunday ochadi). Nomlar normallashtiriladi (registr + probel +
    -- tinish belgisi olib tashlanadi); bir nechta mos kassa bo'lsa yig'iladi.
    hodim_kassa as (
      select si.staff_id, sum(coalesce(k.jami, 0)) as kassa_uzs
        from staff_in si
        join accounts a
          on a.kassa_turi = 'xarajat'
         and coalesce(a.is_active, true)
         and nullif(lower(regexp_replace(a.name,  '[^[:alnum:]]', '', 'g')), '')
           = nullif(lower(regexp_replace(si.nom, '[^[:alnum:]]', '', 'g')), '')
        left join v_kassa_card k on k.id = a.id
       group by si.staff_id
    ),
    -- Ovqat moddasi (accounts.ovqat_modda) ALOHIDA: limiti rbac_role_ovqat da
    -- (obed/zavtrak/kechki), yeyilgani entry_ovqat da — pastdagi ov_* CTE'lar.
    ov_modda as (
      select a.id from accounts a
       where coalesce(a.ovqat_modda, false) and a.type = 'xarajat' and coalesce(a.is_active, true)
    ),
    -- Hodim × modda (ovqat moddasidan tashqari): rol orqali + admin (hamma modda, cheksiz).
    hm_raw as (
      select sr.staff_id, am.id as modda_id, rm.limit_uzs
        from staff_role sr
        join rbac_role_modda rm on rm.role_id = sr.role_id
        join accounts am on am.id = rm.account_id
                        and am.type = 'xarajat'
                        and coalesce(am.is_active, true)
                        and not coalesce(am.ovqat_modda, false)
      union all
      select sa.staff_id, a.id, null::numeric
        from staff_admin sa
        cross join accounts a
       where a.type = 'xarajat' and coalesce(a.is_active, true)
         and not coalesce(a.ovqat_modda, false)
    ),
    hm as (
      select r.staff_id, r.modda_id,
             bool_or(r.limit_uzs is null)                                  as cheksiz,
             max(r.limit_uzs)                                              as limit_uzs
        from hm_raw r
       group by r.staff_id, r.modda_id
    ),
    -- Hodim satridagi sarf: o'zi yozgani (entry.created_by).
    sarf as (
      select h.staff_id, h.modda_id,
             coalesce((
               select sum(el.debit)
                 from entry_line el
                 join entry e on e.id = el.entry_id
                where el.account_id = h.modda_id
                  and el.debit > 0
                  and e.is_deleted = false
                  and e.status in ('posted', 'pending')
                  and date_trunc('month', e.entry_date) = v_oy
                  and (to_jsonb(e) ->> 'created_by') = si.user_id::text
             ), 0) as sarf_uzs
        from hm h
        join staff_in si on si.staff_id = h.staff_id
       where si.user_id is not null
    ),
    hm_full as (
      select h.staff_id, si.nom, si.lavozim, (si.user_id is not null) as bog_langan,
             h.modda_id, null::text as tur, h.cheksiz, h.limit_uzs,
             coalesce(s.sarf_uzs, 0)  as sarf_uzs,
             coalesce(hk.kassa_uzs, 0) as kassa_uzs
        from hm h
        join staff_in si on si.staff_id = h.staff_id
        left join sarf s        on s.staff_id  = h.staff_id and s.modda_id = h.modda_id
        left join hodim_kassa hk on hk.staff_id = h.staff_id
    ),
    -- 🔴 OVQAT: hodim × tur limiti — rbac_limit_ovqat_staff bilan AYNAN bir xil
    -- manba (user_id bog'langan → rbac_user_role, aks holda rbac_staff_role);
    -- rollar ichidan MAX, bittasi cheksiz bo'lsa cheksiz. Tur rolda yo'q → satr yo'q.
    ov_lim as (
      select si.staff_id, t.tur,
             bool_or(ro.limit_uzs is null) as cheksiz,
             max(ro.limit_uzs)             as limit_uzs
        from staff_in si
        cross join unnest(array['obed', 'zavtrak', 'kechki']) as t(tur)
        join lateral (
          select ro.role_id, ro.limit_uzs
            from rbac_user_role ur
            join rbac_role r on r.id = ur.role_id and r.is_active
            join rbac_role_ovqat ro on ro.role_id = ur.role_id and ro.tur = t.tur
           where si.user_id is not null and ur.user_id = si.user_id
          union all
          select ro.role_id, ro.limit_uzs
            from rbac_staff_role sr
            join rbac_role r on r.id = sr.role_id and r.is_active
            join rbac_role_ovqat ro on ro.role_id = sr.role_id and ro.tur = t.tur
           where si.user_id is null and sr.staff_id = si.staff_id
        ) ro on true
       group by si.staff_id, t.tur
    ),
    -- Yeyilgani: entry_ovqat (yeyuvchi hodim bo'yicha, kim yozganidan qat'i nazar).
    ov_full as (
      select si.staff_id, si.nom, si.lavozim, (si.user_id is not null) as bog_langan,
             am.id as modda_id, ol.tur, ol.cheksiz,
             case when ol.cheksiz then null else ol.limit_uzs end as limit_uzs,
             rbac_ovqat_ishlatildi(si.staff_id, ol.tur, v_oy)      as sarf_uzs,
             coalesce(hk.kassa_uzs, 0)                              as kassa_uzs
        from ov_lim ol
        join staff_in si on si.staff_id = ol.staff_id
        cross join ov_modda am
        left join hodim_kassa hk on hk.staff_id = si.staff_id
    ),
    all_full as (
      select * from hm_full
      union all
      select * from ov_full
    ),
    -- Modda bo'yicha jami sarf: filial kesimi (kim yozganidan qat'i nazar).
    sarf_filial as (
      select h.modda_id,
             coalesce((
               select sum(el.debit)
                 from entry e
                 join entry_line el on el.entry_id = e.id
                                   and el.account_id = h.modda_id
                                   and el.debit > 0
                where e.is_deleted = false
                  and e.status in ('posted', 'pending')
                  and date_trunc('month', e.entry_date) = v_oy
                  and v_filial_id = any(e.filial_ids)
             ), 0) as sarf_uzs
        from (select distinct modda_id from all_full) h
    ),
    modda_agg as (
      select f.modda_id,
             count(*)::int                                                  as hodim_soni,
             bool_or(f.cheksiz)                                             as cheksiz_bor,
             sum(f.limit_uzs) filter (where not f.cheksiz)                  as limit_jami,
             max(sf.sarf_uzs)                                               as sarf_jami,
             jsonb_agg(jsonb_build_object(
               'staff_id',   f.staff_id,
               'nom',        f.nom,
               'lavozim',    f.lavozim,
               'tur',        f.tur,
               'bog_langan', f.bog_langan,
               'cheksiz',    f.cheksiz,
               'limit_uzs',  f.limit_uzs,
               'sarf_uzs',   f.sarf_uzs,
               'kassa_uzs',  f.kassa_uzs,
               'qoldi_uzs',  case when f.cheksiz or f.limit_uzs is null then null
                                  else greatest(0, f.limit_uzs - f.sarf_uzs) end
             ) order by f.nom, f.tur)                                       as hodimlar
        from all_full f
        join sarf_filial sf on sf.modda_id = f.modda_id
       group by f.modda_id
    )
    select jsonb_build_object(
      'ok',     true,
      'oy',     to_char(v_oy, 'YYYY-MM'),
      'filial', jsonb_build_object('id', v_filial_id, 'name', v_filial_nom),
      -- Filial hodimlarining O'Z kassalaridagi jonli pul (filial kassasi emas).
      'kassa_qoldiq_uzs', (select coalesce(sum(hk.kassa_uzs), 0) from hodim_kassa hk),
      'jami', jsonb_build_object(
        'limit_uzs', (select coalesce(sum(ma.limit_jami), 0) from modda_agg ma),
        'sarf_uzs',  (select coalesce(sum(ma.sarf_jami), 0)  from modda_agg ma),
        'qoldi_uzs', (select greatest(0, coalesce(sum(ma.limit_jami), 0) - coalesce(sum(ma.sarf_jami), 0))
                        from modda_agg ma)
      ),
      'moddalar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'modda_id',    ma.modda_id,
                 'code',        a.code,
                 'name',        a.name,
                 'hodim_soni',  ma.hodim_soni,
                 'cheksiz_bor', ma.cheksiz_bor,
                 'limit_uzs',   ma.limit_jami,
                 'sarf_uzs',    ma.sarf_jami,
                 'qoldi_uzs',   case when ma.limit_jami is null then null
                                     else greatest(0, ma.limit_jami - ma.sarf_jami) end,
                 'foiz',        case when coalesce(ma.limit_jami, 0) > 0
                                     then least(999, round(ma.sarf_jami / ma.limit_jami * 100))
                                     else null end,
                 'hodimlar',    ma.hodimlar
               ) order by (ma.limit_jami is null), coalesce(ma.sarf_jami, 0) desc, a.code)
          from modda_agg ma
          join accounts a on a.id = ma.modda_id
      ), '[]'::jsonb)
    )
  );
end
$fn$;

revoke all on function standart_filial_limit_sarf(uuid, date) from public, anon;
grant execute on function standart_filial_limit_sarf(uuid, date) to authenticated;

comment on function standart_filial_limit_sarf(uuid, date) is
  'Filial hodimlariga ROL orqali berilgan xarajat limitlari (UZS only — bu funksiya '
  'rbac_staff_limit/standart_xarajat ni o''qimaydi, shuning uchun MASALA #4 ga daxli yo''q). '
  'YANGI (MASALA #6, PROVODKA_STANDART_LIMIT_V2.sql): staff_in endi staff_filial_qolda ni ham '
  'UNION qiladi (Aros filiali yo''q hodimlar). Faqat o''qish.';


-- #####################################################################
-- ##  11-BO'LIM — standart_hodim_limitlar(uuid,date) qayta e'lon     ##
-- ---------------------------------------------------------------------
-- PROVODKA_STANDART_HODIM.sql dagi tananing nusxasi + UCH qo'shimcha:
-- (a) staff_in/staff_filial ga staff_filial_qolda (MASALA #6); (b) YANGI
-- staff_limit_eff CTE (valyuta-aware override, MASALA #4) — modda_eff/
-- ov_eff/ov_umumiy shundan o'qiydi; (c) chiqishga hodim_limit_val/
-- hodim_limit_valyuta (+ ovqat_umumiy.limit_val/valyuta) qo'shildi. Guruhlash
-- (MASALA #2) klient tomonda (standart-dev.html) — bu RPC allaqachon har
-- hodim uchun bitta jsonb obyekt (qatorlar massivi bilan) qaytaradi,
-- server tomonda o'zgarish shart emas.
-- #####################################################################

create or replace function standart_hodim_limitlar(p_filial uuid default null, p_oy date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_oy         date;
  v_filial_id  uuid;
  v_filial_nom text;
  v_bids       int[];
begin
  if not standart_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  v_oy := date_trunc('month', coalesce(p_oy, (now() at time zone 'Asia/Tashkent')::date))::date;

  if p_filial is not null then
    select id, name into v_filial_id, v_filial_nom
      from accounts
     where id = p_filial
       and kassa_turi = 'filial'
       and parent_id is null
       and coalesce(is_active, true);
    if v_filial_id is null then
      raise exception 'Filial topilmadi: %', p_filial using errcode = '22023';
    end if;
    select coalesce(array_agg(m.branch_id), '{}'::int[]) into v_bids
      from staff_branch_map m
     where m.filial_id = v_filial_id or m.provodka_filial = v_filial_nom;
  end if;

  return (
    with staff_in as (
      select s.staff_id,
             coalesce(nullif(btrim(s.toliq_nom), ''),
                      btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))) as nom,
             s.lavozim, s.user_id, s.branch_id, s.branch_nomi
        from aros_staff s
       where s.is_active
         and (
           v_filial_id is null
           or s.branch_id = any(v_bids)
           or exists (
             select 1 from jsonb_array_elements(coalesce(s.branches, '[]'::jsonb)) b
              where (b ->> 'id') ~ '^\d+$' and (b ->> 'id')::int = any(v_bids)
           )
           -- 🔴 YANGI (MASALA #6, PROVODKA_STANDART_LIMIT_V2.sql).
           or (v_filial_id is not null and exists (
             select 1 from staff_filial_qolda q
              where q.staff_id = s.staff_id and q.filial_id = v_filial_id
           ))
         )
    ),
    staff_admin as (
      select si.staff_id
        from staff_in si
        join profiles p on p.id = si.user_id
       where si.user_id is not null and p.role = 'admin'
    ),
    staff_role as (
      select si.staff_id, r.id as role_id, r.nom as role_nom
        from staff_in si
        join rbac_user_role ur on ur.user_id = si.user_id
        join rbac_role r on r.id = ur.role_id and r.is_active
       where si.user_id is not null
         and not exists (select 1 from staff_admin sa where sa.staff_id = si.staff_id)
      union all
      select si.staff_id, r.id, r.nom
        from staff_in si
        join rbac_staff_role sr on sr.staff_id = si.staff_id
        join rbac_role r on r.id = sr.role_id and r.is_active
       where si.user_id is null
    ),
    staff_eff as (
      select staff_id from staff_role
      union
      select staff_id from staff_admin
    ),
    -- 🔴 YANGI (MASALA #6): filial_nom endi staff_filial_qolda dan ham
    -- fallback qiladi (branch mapping'i bo'lmagan hodim uchun).
    staff_filial as (
      select si.staff_id, coalesce(fa.name, fq.name, si.branch_nomi) as filial_nom
        from staff_in si
        left join staff_branch_map m on m.branch_id = si.branch_id
        left join accounts fa on fa.id = m.filial_id
        left join staff_filial_qolda q on q.staff_id = si.staff_id
        left join accounts fq on fq.id = q.filial_id
    ),
    hodim_meta as (
      select si.staff_id, si.nom, si.lavozim,
             case when exists (select 1 from staff_admin sa where sa.staff_id = si.staff_id)
                  then '["Admin"]'::jsonb
                  else coalesce((select jsonb_agg(distinct sr.role_nom order by sr.role_nom)
                                   from staff_role sr where sr.staff_id = si.staff_id), '[]'::jsonb)
             end as rollar
        from staff_in si
       where si.staff_id in (select staff_id from staff_eff)
    ),
    -- 🔴 YANGI (MASALA #4, PROVODKA_STANDART_LIMIT_V2.sql): rbac_staff_limit
    -- override'ining valyuta-aware (jonli so'm ekvivalenti) versiyasi, bir marta
    -- hisoblanadi — modda_eff/ov_eff/ov_umumiy shundan o'qiydi.
    staff_limit_eff as (
      select staff_id, kalit, limit_val, coalesce(valyuta, 'UZS') as valyuta,
             case when limit_uzs is null and limit_val is null then null
                  when coalesce(valyuta, 'UZS') = 'UZS' then coalesce(limit_uzs, limit_val)
                  else standart_limit_uzs(limit_val, valyuta) end as eff_uzs
        from rbac_staff_limit
    ),
    -- MODDA (xarajat, ovqat_modda EMAS) yig'ma manbasi: rol orqali + admin shox (hamma, cheksiz).
    modda_z as (
      select sr.staff_id, am.id as modda_id, am.code, am.name, rm.limit_uzs
        from staff_role sr
        join rbac_role_modda rm on rm.role_id = sr.role_id
        join accounts am on am.id = rm.account_id and am.type = 'xarajat'
                        and coalesce(am.is_active, true) and not coalesce(am.ovqat_modda, false)
      union all
      select sa.staff_id, a.id, a.code, a.name, null::numeric
        from staff_admin sa
        cross join accounts a
       where a.type = 'xarajat' and coalesce(a.is_active, true) and not coalesce(a.ovqat_modda, false)
    ),
    modda_rol as (
      select z.staff_id, z.modda_id, min(z.code) as code, min(z.name) as name,
             bool_or(z.limit_uzs is null) as rol_cheksiz,
             max(z.limit_uzs)             as rol_lim
        from modda_z z
       group by z.staff_id, z.modda_id
    ),
    modda_eff as (
      select mr.staff_id, mr.modda_id, mr.code, mr.name, mr.rol_cheksiz, mr.rol_lim,
             sle.limit_val               as override_val,
             coalesce(sle.valyuta,'UZS') as override_cur,
             sle.eff_uzs                 as override_lim,
             (sle.staff_id is not null)  as has_override,
             case when sle.staff_id is not null then sle.eff_uzs
                  when mr.rol_cheksiz then null else mr.rol_lim end as eff_lim
        from modda_rol mr
        left join staff_limit_eff sle
          on sle.staff_id = mr.staff_id and sle.kalit = 'modda:' || mr.modda_id::text
    ),
    modda_qator as (
      select me.staff_id, me.code,
             jsonb_build_object(
               'kalit',               'modda:' || me.modda_id::text,
               'turi',                'modda',
               'account_id',          me.modda_id,
               'code',                me.code,
               'name',                me.name,
               'tur',                 null,
               'rol_limit',           case when me.rol_cheksiz then null else me.rol_lim end,
               'hodim_limit',         me.override_lim,
               'hodim_limit_val',     me.override_val,
               'hodim_limit_valyuta', me.override_cur,
               'effektiv_limit',      me.eff_lim,
               'sarf',                coalesce(msf.sarf, 0),
               'qoldi',               case when me.eff_lim is null then null else me.eff_lim - coalesce(msf.sarf, 0) end,
               'override',            me.has_override
             ) as qator
        from modda_eff me
        left join staff_in si on si.staff_id = me.staff_id
        left join lateral (
          select case when si.user_id is not null
                      then rbac_modda_ishlatildi(si.user_id, me.modda_id, v_oy)
                      else 0 end as sarf
        ) msf on true
    ),
    -- OVQAT: 3 tur (rol orqali ruxsat etilgan yoki admin shox — hamma tur, cheksiz).
    ov_modda as (
      select id, code, name from accounts
       where coalesce(ovqat_modda, false) and type = 'xarajat' and coalesce(is_active, true)
    ),
    ov_z as (
      select sr.staff_id, ro.tur, ro.limit_uzs
        from staff_role sr
        join rbac_role_ovqat ro on ro.role_id = sr.role_id
      union all
      select sa.staff_id, t.tur, null::numeric
        from staff_admin sa
        cross join unnest(array['obed', 'zavtrak', 'kechki']) as t(tur)
    ),
    ov_rol as (
      select z.staff_id, z.tur,
             bool_or(z.limit_uzs is null) as rol_cheksiz,
             max(z.limit_uzs)             as rol_lim
        from ov_z z
       group by z.staff_id, z.tur
    ),
    ov_umumiy as (
      select staff_id, limit_val, valyuta, eff_uzs as limit_uzs
        from staff_limit_eff where kalit = 'ovqat:umumiy'
    ),
    ov_eff as (
      select orr.staff_id, orr.tur, orr.rol_cheksiz, orr.rol_lim,
             sle.limit_val               as override_val,
             coalesce(sle.valyuta,'UZS') as override_cur,
             sle.eff_uzs                 as override_lim,
             (sle.staff_id is not null)  as has_override,
             (u.staff_id is not null)    as umumiy_on,
             case when u.staff_id is not null then null
                  when sle.staff_id is not null then sle.eff_uzs
                  when orr.rol_cheksiz then null else orr.rol_lim end as eff_lim,
             rbac_ovqat_ishlatildi(orr.staff_id, orr.tur, v_oy) as sarf
        from ov_rol orr
        left join staff_limit_eff sle on sle.staff_id = orr.staff_id and sle.kalit = 'ovqat:' || orr.tur
        left join ov_umumiy u on u.staff_id = orr.staff_id
    ),
    ov_qator as (
      select oe.staff_id, oe.tur,
             jsonb_build_object(
               'kalit',               'ovqat:' || oe.tur,
               'turi',                'ovqat',
               'account_id',          ov.id,
               'code',                ov.code,
               'name',                ov.name,
               'tur',                 oe.tur,
               'rol_limit',           case when oe.rol_cheksiz then null else oe.rol_lim end,
               'hodim_limit',         oe.override_lim,
               'hodim_limit_val',     oe.override_val,
               'hodim_limit_valyuta', oe.override_cur,
               'effektiv_limit',      oe.eff_lim,
               'sarf',                oe.sarf,
               'qoldi',               case when oe.eff_lim is null then null else oe.eff_lim - oe.sarf end,
               'override',            oe.has_override,
               'umumiy_rejim',        oe.umumiy_on
             ) as qator
        from ov_eff oe
        cross join ov_modda ov
    ),
    modda_agg as (
      select staff_id, jsonb_agg(qator order by code) as arr
        from modda_qator
       group by staff_id
    ),
    ov_agg as (
      select staff_id,
             jsonb_agg(qator order by case tur when 'obed' then 1 when 'zavtrak' then 2 when 'kechki' then 3 else 4 end) as arr
        from ov_qator
       group by staff_id
    ),
    umumiy_agg as (
      select hm.staff_id,
             jsonb_build_object(
               'bor',       (u.staff_id is not null),
               'limit',     u.limit_uzs,
               'limit_val', u.limit_val,
               'valyuta',   coalesce(u.valyuta, 'UZS'),
               'sarf',      coalesce(s.sarf, 0),
               'qoldi',     case when u.staff_id is null or u.limit_uzs is null then null
                                 else u.limit_uzs - coalesce(s.sarf, 0) end
             ) as obj
        from hodim_meta hm
        left join ov_umumiy u on u.staff_id = hm.staff_id
        left join lateral (
          select coalesce(sum(rbac_ovqat_ishlatildi(hm.staff_id, t.tur, v_oy)), 0) as sarf
            from unnest(array['obed', 'zavtrak', 'kechki']) as t(tur)
        ) s on true
    )
    select jsonb_build_object(
      'ok', true,
      'oy', to_char(v_oy, 'YYYY-MM'),
      'hodimlar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'staff_id',     hm.staff_id,
                 'toliq_nom',    hm.nom,
                 'lavozim',      hm.lavozim,
                 'filial_nom',   sf.filial_nom,
                 'rollar',       hm.rollar,
                 'qatorlar',     coalesce(ma.arr, '[]'::jsonb) || coalesce(oa.arr, '[]'::jsonb),
                 'ovqat_umumiy', ua.obj
               ) order by hm.nom)
          from hodim_meta hm
          join staff_filial sf on sf.staff_id = hm.staff_id
          left join modda_agg  ma on ma.staff_id = hm.staff_id
          left join ov_agg     oa on oa.staff_id = hm.staff_id
          left join umumiy_agg ua on ua.staff_id = hm.staff_id
      ), '[]'::jsonb)
    )
  );
end
$fn$;

revoke all on function standart_hodim_limitlar(uuid, date) from public, anon;
grant execute on function standart_hodim_limitlar(uuid, date) to authenticated;

comment on function standart_hodim_limitlar(uuid, date) is
  '"Hodim bo''yicha xarajatlar" bo''limi: kamida bitta rolga ega har hodim (ixtiyoriy filial '
  'filtri, endi staff_filial_qolda ham hisobga olinadi — MASALA #6) x har limit qatori (modda '
  'YOKI ovqat:obed/zavtrak/kechki) — rol limiti, hodim darajasidagi override (rbac_staff_limit, '
  'MASALA #4: chet valyutada bo''lsa jonli so''m ekvivalenti + hodim_limit_val/valyuta xom '
  'qiymati), effektiv limit, shu oy sarfi/qoldig''i + ''ovqat_umumiy''. Ruxsat yo''q bo''lsa '
  'exception EMAS — {ok:false, kod:''ruxsat''}. Ruxsat: standart_page_ok().';

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  12-BO'LIM — standart_holat(date) qayta e'lon                  ##
-- ---------------------------------------------------------------------
-- PROVODKA_V7.sql dagi tananing nusxasi + limit_uzs endi valyuta-aware
-- (chet valyutada standart_limit_uzs() orqali jonli). Chiqish USTUNLARI
-- (imzo) o'zgarmagan.
-- #####################################################################

create or replace function standart_holat(p_oy date)
returns table(
  id uuid, filial_id uuid, filial_code text, filial_name text,
  modda_id uuid, modda_code text, modda_name text,
  limit_uzs numeric, sarflandi numeric, qoldi numeric
)
language sql
stable
security definer
set search_path = public
as $fn$
  with oy as (
    select date_trunc('month', p_oy)::date as f,
           (date_trunc('month', p_oy) + interval '1 month - 1 day')::date as t
  ),
  lim as (
    select s.id, s.filial_id, s.modda_id,
           case when coalesce(s.valyuta, 'UZS') = 'UZS' then coalesce(s.limit_uzs, s.limit_val)
                else standart_limit_uzs(s.limit_val, s.valyuta) end as limit_uzs
      from standart_xarajat s
  )
  select l.id, l.filial_id, fa.code, fa.name,
         l.modda_id, ma.code, ma.name,
         l.limit_uzs,
         coalesce(sp.sarflandi, 0)                 as sarflandi,
         l.limit_uzs - coalesce(sp.sarflandi, 0)   as qoldi
    from lim l
    join accounts fa on fa.id = l.filial_id
    join accounts ma on ma.id = l.modda_id
    cross join oy
    left join lateral (
      select sum(el.debit) as sarflandi
        from entry e
        join entry_line el on el.entry_id = e.id and el.account_id = l.modda_id and el.debit > 0
       where e.status = 'posted' and e.is_deleted = false
         and e.entry_date >= oy.f and e.entry_date <= oy.t
         and l.filial_id = any(e.filial_ids)
    ) sp on true
   order by fa.name, ma.name;
$fn$;

revoke all on function standart_holat(date) from public, anon;
grant execute on function standart_holat(date) to authenticated;

comment on function standart_holat(date) is
  'Har limit uchun berilgan oyda sarflangan + qoldi (entry_date oyi, posted, o''chirilmagan). '
  'YANGI (MASALA #4, PROVODKA_STANDART_LIMIT_V2.sql): limit_uzs chet valyutada (USD/CNY) bo''lsa '
  'standart_limit_uzs() orqali JONLI hisoblanadi (muzlatilmagan).';


-- #####################################################################
-- ##  13-BO'LIM — limit_guard_entry_line() qayta e'lon               ##
-- ---------------------------------------------------------------------
-- PROVODKA_V7.sql dagi tananing nusxasi + filial limiti o'qilishi endi
-- valyuta-aware (MASALA #4). Trigger/imzo o'zgarmagan.
-- #####################################################################

create or replace function limit_guard_entry_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_fids      uuid[];
  v_date      date;
  v_deleted   boolean;
  v_status    text;
  f           uuid;
  v_limit     numeric;
  v_limit_val numeric;
  v_limit_cur text;
  v_spent     numeric;
  v_f         date;
  v_t         date;
  v_fname     text;
  v_mname     text;
begin
  if new.debit is null or new.debit <= 0 then return new; end if;
  if auth.uid() is null then return new; end if;   -- avtomat sinxron (n8n) o'tadi

  select filial_ids, entry_date, is_deleted, status
    into v_fids, v_date, v_deleted, v_status
    from entry where id = new.entry_id;
  if not found then return new; end if;
  if v_deleted or coalesce(v_status, 'posted') <> 'posted' then return new; end if;
  if v_fids is null or array_length(v_fids, 1) is null then return new; end if;

  v_f := date_trunc('month', v_date)::date;
  v_t := (date_trunc('month', v_date) + interval '1 month - 1 day')::date;

  foreach f in array v_fids loop
    v_limit := null; v_limit_val := null; v_limit_cur := null;
    select limit_uzs, limit_val, valyuta into v_limit, v_limit_val, v_limit_cur
      from standart_xarajat where filial_id = f and modda_id = new.account_id;
    if found then
      -- YANGI (MASALA #4): chet valyutada bo'lsa jonli so'm ekvivalenti hisoblanadi.
      if coalesce(v_limit_cur, 'UZS') <> 'UZS' then
        v_limit := standart_limit_uzs(v_limit_val, v_limit_cur);
      else
        v_limit := coalesce(v_limit, v_limit_val);
      end if;
    end if;
    if v_limit is not null then
      select coalesce(sum(el.debit), 0) into v_spent
        from entry e
        join entry_line el on el.entry_id = e.id and el.account_id = new.account_id and el.debit > 0
       where e.status = 'posted' and e.is_deleted = false
         and e.entry_date >= v_f and e.entry_date <= v_t
         and f = any(e.filial_ids);
      if v_spent > v_limit then
        select name into v_fname from accounts where id = f;
        select name into v_mname from accounts where id = new.account_id;
        raise exception 'Limit oshib ketdi: "%" filialida "%" uchun oylik limit % so''m, bu oy jami % so''m bo''ladi',
          coalesce(v_fname, '?'), coalesce(v_mname, '?'), v_limit, v_spent
          using errcode = 'P0001';
      end if;
    end if;
  end loop;
  return new;
end
$fn$;

revoke all on function limit_guard_entry_line() from public, anon;

drop trigger if exists trg_limit_guard_entry_line on entry_line;
create trigger trg_limit_guard_entry_line
  after insert on entry_line
  for each row execute function limit_guard_entry_line();

comment on function limit_guard_entry_line() is
  'standart_xarajat oylik limitini majburlaydi (filial+modda). service_role/n8n o''tadi. '
  'YANGI (MASALA #4, PROVODKA_STANDART_LIMIT_V2.sql): limit chet valyutada (USD/CNY) bo''lsa '
  'standart_limit_uzs() orqali JONLI hisoblanadi.';

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  14-BO'LIM — MASALA #6: "Ta'minot Xitoy" filial kassa           ##
-- ---------------------------------------------------------------------
-- PROVODKA_OSHXONA_KASSA.sql naqshi: Provodka'ning o'z filial kassasi
-- (Aros cachier EMAS, filial_ref yo'q). kassa_turi='filial', kod 52xx
-- (eng kattasi + 1), tur bola-hisoblari: naqd/click/terminal. Idempotent
-- (nom bo'yicha tekshiriladi).
-- #####################################################################

do $taminot_xitoy$
declare
  v_nom  text := 'Ta''minot Xitoy';
  v_code text;
  v_id   uuid;
  v_tur  text;
begin
  select id into v_id from accounts
   where lower(name) = lower(v_nom) and section = 'pul' and parent_id is null limit 1;
  if v_id is not null then
    raise notice 'bor: % (%)', v_nom, v_id;
  else
    select lpad((coalesce(max(code::int), 5200) + 1)::text, 4, '0') into v_code
      from accounts where code ~ '^52[0-9]{2}$';
    insert into accounts (code, name, subtitle, type, section, kassa_turi, currency, parent_id, is_active)
      values (v_code, v_nom, 'Ta''minot', 'aktiv', 'pul', 'filial', 'UZS', null, true)
      returning id into v_id;
    raise notice 'ochildi: % kod %', v_nom, v_code;
  end if;
  foreach v_tur in array array['naqd', 'click', 'terminal'] loop
    begin
      perform _pul_turi_child_ich(v_id, v_tur);
    exception when others then
      raise notice '  tur % ochilmadi: %', v_tur, sqlerrm;
    end;
  end loop;
end
$taminot_xitoy$;

select k.code, k.name, k.subtitle, k.kassa_turi,
       (select string_agg(c.pul_turi, ', ' order by c.code) from accounts c where c.parent_id = k.id and c.pul_turi is not null) as turlar
  from accounts k
 where k.section = 'pul' and k.parent_id is null and lower(k.name) = lower('Ta''minot Xitoy');


-- #####################################################################
-- ##  15-BO'LIM — MASALA #6: 2 hodimni "Ta'minot Xitoy"ga biriktirish ##
-- ---------------------------------------------------------------------
-- G'iyos Ergashev / Ural Ruziyev — aros_staff da standart_norm() bo'yicha
-- izlanadi (registr/probel/tinish-belgi sezgir emas). Topilsa —
-- staff_filial_qolda ga idempotent yoziladi. Topilmasa — RAISE NOTICE
-- bilan eng yaqin nomzodlar (standart_ball >= 2) ko'rsatiladi, blok
-- davom etadi (fail emas — Asilbek keyin qo'lda hal qiladi).
-- #####################################################################

do $taminot_staff$
declare
  v_filial_id uuid;
  v_names     text[] := array['G''iyos Ergashev', 'Ural Ruziyev'];
  v_nom       text;
  v_staff_id  int;
  v_cand      record;
begin
  select id into v_filial_id from accounts
   where lower(name) = lower('Ta''minot Xitoy') and section = 'pul' and parent_id is null limit 1;
  if v_filial_id is null then
    raise exception 'Ta''minot Xitoy kassasi topilmadi — 14-BO''LIM muvaffaqiyatsiz bo''lgan bo''lishi mumkin';
  end if;

  foreach v_nom in array v_names loop
    v_staff_id := null;
    select s.staff_id into v_staff_id
      from aros_staff s
     where standart_norm(coalesce(nullif(btrim(s.toliq_nom), ''),
                                   btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))))
           = standart_norm(v_nom)
     order by s.is_active desc
     limit 1;

    if v_staff_id is null then
      raise notice 'TOPILMADI: % — eng yaqin nomzodlar:', v_nom;
      for v_cand in
        select coalesce(nullif(btrim(s.toliq_nom), ''),
                         btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))) as nom,
               s.staff_id,
               standart_ball(coalesce(nullif(btrim(s.toliq_nom), ''),
                                       btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))), v_nom) as ball
          from aros_staff s
         where standart_ball(coalesce(nullif(btrim(s.toliq_nom), ''),
                                       btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))), v_nom) >= 2
         order by ball desc, nom
         limit 5
      loop
        raise notice '  - % (staff_id=%, ball=%)', v_cand.nom, v_cand.staff_id, v_cand.ball;
      end loop;
      continue;
    end if;

    insert into staff_filial_qolda (staff_id, filial_id, updated_by)
    values (v_staff_id, v_filial_id, auth.uid())
    on conflict (staff_id) do update
      set filial_id = excluded.filial_id, updated_at = now(), updated_by = excluded.updated_by;

    raise notice 'BOGLANDI: % (staff_id=%) -> Ta''minot Xitoy', v_nom, v_staff_id;
  end loop;
end
$taminot_staff$;

select s.staff_id, coalesce(nullif(btrim(s.toliq_nom), ''),
                             btrim(coalesce(s.ism, '') || ' ' || coalesce(s.familiya, ''))) as nom,
       q.filial_id, a.name as filial_nom
  from staff_filial_qolda q
  join aros_staff s on s.staff_id = q.staff_id
  join accounts a on a.id = q.filial_id
 order by nom;


-- #####################################################################
-- ##  16-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)           ##
-- #####################################################################

select 'rbac_staff_limit.limit_val/valyuta' as obyekt,
       case when exists (select 1 from information_schema.columns
                          where table_name = 'rbac_staff_limit' and column_name = 'limit_val')
             and exists (select 1 from information_schema.columns
                          where table_name = 'rbac_staff_limit' and column_name = 'valyuta')
            then '✅ qoshildi' else '❌' end as holat
union all
select 'standart_xarajat.limit_val/valyuta',
       case when exists (select 1 from information_schema.columns
                          where table_name = 'standart_xarajat' and column_name = 'limit_val')
             and exists (select 1 from information_schema.columns
                          where table_name = 'standart_xarajat' and column_name = 'valyuta')
            then '✅ qoshildi' else '❌' end
union all
select 'standart_limit_uzs(numeric,text)',
       case when to_regprocedure('public.standart_limit_uzs(numeric,text)') is not null
            then '✅ yaratildi' else '❌' end
union all
select 'standart_limit_set(uuid,uuid,numeric,text) — YANGI overload',
       case when to_regprocedure('public.standart_limit_set(uuid,uuid,numeric,text)') is not null
            then '✅ yaratildi' else '❌' end
union all
select 'standart_hodim_limit_set(int,text,numeric,boolean,text) — YANGI overload',
       case when to_regprocedure('public.standart_hodim_limit_set(int,text,numeric,boolean,text)') is not null
            then '✅ yaratildi' else '❌' end
union all
select 'staff_filial_qolda (jadval)',
       case when to_regclass('public.staff_filial_qolda') is not null
            then '✅ yaratildi' else '❌' end
union all
select 'Ta''minot Xitoy (kassa)',
       case when exists (select 1 from accounts where lower(name) = lower('Ta''minot Xitoy') and parent_id is null)
            then '✅ yaratildi' else '❌' end
union all
select 'rbac_limit_entry_line() — filial override erta-qaytish olib tashlandi',
       case when not exists (
              select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'rbac_limit_entry_line'
                 and position('filial override' in p.prosrc) > 0
            ) then '✅ olib tashlandi' else '⚠️ tekshirib koring' end
union all
select 'standart_hodim_limitlar(uuid,date)',
       case when to_regprocedure('public.standart_hodim_limitlar(uuid,date)') is not null
            then '✅ yangilandi' else '❌' end
union all
select 'standart_filial_moddalar(uuid)',
       case when to_regprocedure('public.standart_filial_moddalar(uuid)') is not null
            then '✅ yangilandi' else '❌' end
union all
select 'standart_filial_limit_sarf(uuid,date)',
       case when to_regprocedure('public.standart_filial_limit_sarf(uuid,date)') is not null
            then '✅ yangilandi' else '❌' end
union all
select 'standart_holat(date)',
       case when to_regprocedure('public.standart_holat(date)') is not null
            then '✅ yangilandi' else '❌' end
union all
select 'limit_guard_entry_line()',
       case when to_regprocedure('public.limit_guard_entry_line()') is not null
            then '✅ yangilandi' else '❌' end;
