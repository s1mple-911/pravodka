-- =====================================================================
--  PROVODKA_SOROV_TOPUP.sql
--  "Pul so'rash" tugmasi DOIM ishlaydi: XARAJATSIZ SOF SO'ROV (TOP-UP)
--  + chegara sozlamasi (provodka_config).
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). Dev-first. Asilbek RUN qiladi.
--  Brief:   BRIEF_PROVODKA_SOROV_TUGMA.md
--  Old fayl: PROVODKA_SOROVLAR.sql  (SHU FAYL UNGA QO'SHIMCHA, o'rnini BOSMAYDI)
--
--  #####  NIMA O'ZGARADI  #############################################
--
--   1) `sorov_yarat()` ga UCHINCHI REJIM qo'shiladi — TOP-UP:
--        p_modda is null AND p_summa_xarajat is null AND p_xarajat_entry is null
--      Bu holatda XARAJAT UMUMAN YARATILMAYDI: faqat `sorovlar` qatori
--      yoziladi (`xarajat_entry_id = null`). Tasdiqlanganda hodim
--      kassasiga SOF pul tushadi (balans to'ldirish).
--      🔴 IMZO O'ZGARMAYDI — o'sha 14 parametr, o'sha turlar, o'sha
--         sukut qiymatlar. Ya'ni `drop` KERAK EMAS va mavjud klient
--         (xarajatli so'rov, "qolganini so'rash") HECH O'ZGARMAYDI.
--
--   2) `sorov_topup_chegara()` — 500 so'm chegarasi endi BAZADA
--      (`provodka_config.sorov_topup_chegara`). Sabab: uni deploy'siz
--      (promote'siz) o'zgartirish kerak. `hodim_tosiq_foiz()` naqshi.
--      + `set_sorov_topup_chegara(numeric)` (admin).
--
--   3) `sorovlar_ochiq_topup_uniq` — bir odamda bir vaqtda BITTA ochiq
--      top-up so'rovi (spam qorovuli, asos 1.4 da).
--
--  #####  NIMAGA TEGILMAYDI (buzma)  ##################################
--
--   * `sorov_tasdiq` / `sorov_rad` / `sorov_xarajat_bekor` / `sorov_qator`
--     / `sorov_royxat` / `sorov_menikilar` / `perm_guard_entry_line`
--     — BIRORTASI O'ZGARMAYDI. Ular `xarajat_entry_id is null` holatini
--     ALLAQACHON to'g'ri ko'taradi (tekshirildi, 5-BO'LIM tahliliga qara).
--   * Mavjud xarajatli oqim (over -> pending xarajat + so'rov) va
--     "qolganini so'rash" oqimi — bir qator ham o'zgarmadi.
--
--  #####  QAT'IY QOIDALAR  ############################################
--
--   * ADDITIVE: hech narsa o'chirilmaydi, imzo o'zgarmaydi.
--   * `do` bloki YO'Q, jonli RPC chaqiruvi YO'Q (butun skript bitta
--     tranzaksiya — bitta 42501 hammasini orqaga qaytarardi).
--   * Funksiya tanasi NOMLANGAN teg bilan; izohlarda dollar-qavs
--     YOZILMAYDI (editorning juftlik sanog'i buziladi -> 42P01).
--     Bu faylda nomlangan teg AYNAN 6 marta uchraydi (3 funksiya x 2).
--
--  #####  TARTIB OGOHLANTIRISHI  ######################################
--   🔴 `PROVODKA_SOROVLAR.sql` BU FAYLDAN KEYIN RUN qilinsa, u
--      `sorov_yarat` ni ESKI (top-up siz) holatiga qaytaradi va tugma
--      "balans to'ldirish" rejimida jimgina xato bera boshlaydi.
--      O'shanda BU FAYLNI qayta RUN qiling (4.3 tekshiruvi aytadi).
--
--  TALAB (yo'q bo'lsa 0-BO'LIM aytadi):
--     PROVODKA_SOROVLAR.sql  — sorovlar jadvali + sorov_* funksiyalari
--     PROVODKA_V8.sql        — provodka_config jadvali
--     PROVODKA_PERMS.sql     — perm_op_key, perm_check_accounts, is_admin
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART (hech narsa yozmaydi)                     ##
-- #####################################################################

select 'sorovlar jadvali' as tekshiruv,
       case when to_regclass('public.sorovlar') is not null
            then 'BOR' else 'YOQ — avval PROVODKA_SOROVLAR.sql' end as natija
union all
select 'provodka_config',
       case when to_regclass('public.provodka_config') is not null
            then 'BOR' else 'YOQ — avval PROVODKA_V8.sql' end
union all
select 'sorov_kassa_of(uuid)',
       case when to_regprocedure('public.sorov_kassa_of(uuid)') is not null
            then 'BOR' else 'YOQ — avval PROVODKA_SOROVLAR.sql' end
union all
select 'sorov_nomzod_ok(uuid)',
       case when to_regprocedure('public.sorov_nomzod_ok(uuid)') is not null
            then 'BOR' else 'YOQ — avval PROVODKA_SOROVLAR.sql' end
union all
select 'perm_op_key(uuid)',
       case when to_regprocedure('public.perm_op_key(uuid)') is not null
            then 'BOR' else 'YOQ — avval PROVODKA_PERMS.sql' end
union all
select 'perm_check_accounts(uuid[])',
       case when to_regprocedure('public.perm_check_accounts(uuid[])') is not null
            then 'BOR' else 'YOQ — avval PROVODKA_PERMS.sql' end
union all
select 'sorovlar.xarajat_entry_id NULL bola oladimi',
       case when (select is_nullable from information_schema.columns
                   where table_schema='public' and table_name='sorovlar'
                     and column_name='xarajat_entry_id') = 'YES'
            then 'HA — top-up mumkin' else 'YOQ — top-up ishlamaydi, ustunni bosating' end;


-- #####################################################################
-- ##  1-BO'LIM — CHEGARA SOZLAMASI + TOP-UP INDEKSI                  ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 1.1  Boshlang'ich qiymat. Mavjud bo'lsa TEGILMAYDI (admin sozlagani
--      qolsin) — `hodim_tosiq_foiz` naqshi.
--
--      🔴 2026-08-26: 500 -> 500000. Avvalgi qiymat 500 SO'M edi (~4 tsent) —
--      hech bir hodimda undan kam pul bo'lmaydi, ya'ni "balans chegaradan kam"
--      sharti HECH QACHON bajarilmagan va top-up modali umuman ochilmagan.
--      `do nothing` — mavjud bazada bu qator qiymatni O'ZGARTIRMAYDI;
--      jonli bazani tuzatish uchun PROVODKA_TOPUP_CHEGARA.sql ishlatiladi.
-- ---------------------------------------------------------------------
insert into provodka_config(key, val)
values ('sorov_topup_chegara', '500000')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 1.2  sorov_topup_chegara() — YAGONA manba (klient ham shundan o'qiydi).
--      `hodim_tosiq_foiz()` / `conv_koridor_foiz()` naqshi.
--      Ma'nosi: hodim balansi shu qiymatdan KAM bo'lsa "Pul so'rash"
--      tugmasi TOP-UP modalini ochadi, aks holda YO'RIQNOMA ko'rsatiladi.
--      🔴 Qiymatning O'ZI foydalanuvchiga hech qayerda ko'rsatilmaydi
--         (balans sizishi) — u faqat QAROR uchun.
-- ---------------------------------------------------------------------
create or replace function sorov_topup_chegara()
returns numeric
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(
           (select nullif(val, '')::numeric from provodka_config
             where key = 'sorov_topup_chegara'),
           500);
$fn$;

revoke all on function sorov_topup_chegara() from public, anon;
grant execute on function sorov_topup_chegara() to authenticated, service_role;

comment on function sorov_topup_chegara() is
  'Balans toldirish (top-up) chegarasi somda (provodka_config.sorov_topup_chegara; default 500000). '
  'Balans shundan KAM bolsa hodimga top-up modali, aks holda yoriqnoma korsatiladi.';

-- ---------------------------------------------------------------------
-- 1.3  set_sorov_topup_chegara(numeric) — ADMIN only.
--      `set_hodim_tosiq_foiz` naqshi. Chegara 0..1 000 000 000
--      (0 = top-up hech qachon taklif qilinmaydi, faqat yo'riqnoma).
--      ⚠️ `full_name` `to_jsonb()` orqali o'qiladi: PROVODKA_ISM.sql RUN
--         qilinmagan bazada ustun YO'Q va to'g'ridan murojaat 42703
--         berardi (PROVODKA_SOROVLAR.sql 3.5 dagi naqsh).
--
--  🔴🔴 SQL EDITORIDA BU FUNKSIYA ISHLAMAYDI.
--       Editorda so'rov `postgres` roli bilan, JWT'siz ketadi ->
--       `auth.uid()` NULL -> `is_admin()` false -> 42501. (2026-08-25 da
--       aynan shu bo'lgan.) Editordan o'zgartirish uchun 1.5 dagi
--       to'g'ridan-to'g'ri INSERT blokini ishlating.
-- ---------------------------------------------------------------------
create or replace function set_sorov_topup_chegara(p_summa numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $fn$
declare v_by text;
begin
  if not is_admin() then
    raise exception 'Faqat admin top-up chegarasini ozgartira oladi'
      using errcode = '42501';
  end if;
  if p_summa is null or p_summa < 0 or p_summa > 1000000000 then
    raise exception 'Chegara 0 va 1 000 000 000 oraligida bolishi kerak'
      using errcode = '22000';
  end if;

  select nullif(btrim(coalesce(to_jsonb(pr) ->> 'full_name', '')), '') into v_by
    from profiles pr where pr.id = auth.uid();

  insert into provodka_config(key, val, updated_by, updated_at)
  values ('sorov_topup_chegara', p_summa::text, coalesce(v_by, 'admin'), now())
  on conflict (key) do update
    set val = excluded.val, updated_by = excluded.updated_by,
        updated_at = excluded.updated_at;

  return p_summa;
end $fn$;

revoke all on function set_sorov_topup_chegara(numeric) from public, anon;
grant execute on function set_sorov_topup_chegara(numeric) to authenticated;

comment on function set_sorov_topup_chegara(numeric) is
  'Top-up chegarasini ozgartiradi (faqat admin, BRAUZERDAN). SQL editorda ishlamaydi: '
  'auth.uid() null -> is_admin() false -> 42501. Editorda provodka_config ga togridan insert qiling.';

-- ---------------------------------------------------------------------
-- 1.4  🔴 BITTA OCHIQ TOP-UP — bir odamda bir vaqtda BITTA.
--
--   ASOS (qaror va sababi):
--     * Top-up xarajatga BOG'LANMAGAN, ya'ni `sorovlar_ochiq_xarajat_uniq`
--       (u faqat `xarajat_entry_id is not null` ga tegishli) uni UMUMAN
--       to'smaydi — cheklovsiz hodim 10 odamdan 10 marta "pul kerak" deb
--       so'rab, 10 martalik pulni olib qolardi. Xarajatli so'rovda bunday
--       bo'lolmaydi: u yerda chegara xarajat summasi.
--     * Bitta ochiq so'rov + tasdiq/rad bo'lgach yangisi — hodim uchun
--       narx nol, tizim uchun spam qorovuli.
--   YUMSHATISH: shu indeksni `drop` qiling VA `sorov_yarat` ichidagi
--   "Sizda javob kutayotgan sorov bor" tekshiruvini olib tashlang
--   (ikkalasi birga — biri qolsa xatti-harakat chala bo'ladi).
-- ---------------------------------------------------------------------
create unique index if not exists sorovlar_ochiq_topup_uniq
  on sorovlar (sorovchi_id)
  where status = 'pending' and xarajat_entry_id is null;

-- ---------------------------------------------------------------------
-- 1.5  CHEGARANI SQL EDITORDAN O'ZGARTIRISH — NAMUNA (IZOHDA).
--
--      🔴 2026-08-26: bu blok avval IZOHSIZ, ya'ni FAOL edi va `do update`
--      qilardi. Ya'ni shu faylni har qayta RUN qilish (funksiya tuzatish,
--      qayta deploy) jonli bazadagi chegarani JIMGINA '500' ga qaytarardi —
--      hech qanday xato chiqmasdan top-up shoxi yana o'lardi. Endi izohda.
--
--      Chegarani o'zgartirish uchun ALOHIDA fayl bor: PROVODKA_TOPUP_CHEGARA.sql
--      (oldingi qiymatni ko'rsatadi, yozadi, tasdiqlaydi, rollback beradi).
--      Shoshilinch holatda quyidagi uch qatorni izohdan chiqaring:
-- ---------------------------------------------------------------------
-- insert into provodka_config (key, val, updated_by, updated_at)
-- values ('sorov_topup_chegara', '500000', 'admin', now())
-- on conflict (key) do update set val = excluded.val, updated_at = now();


-- #####################################################################
-- ##  2-BO'LIM — sorov_yarat()  🔴 UCHINCHI REJIM (TOP-UP)           ##
-- #####################################################################
-- ## UCH OQIM, BITTA RPC (imzo o'zgarmaydi)
--
--   (a) "QOLGANINI SO'RASH" — `p_xarajat_entry` berilgan. O'ZGARMADI.
--   (b) YANGI XARAJAT — `p_modda` + `p_summa_xarajat`. O'ZGARMADI.
--   (c) 🆕 TOP-UP (sof balans to'ldirish) — `p_modda`, `p_summa_xarajat`
--       va `p_xarajat_entry` UCHALASI HAM null. Xarajat YOZILMAYDI.
--       Klient yuboradi: p_kimdan, p_sorov_summa, p_sorov_izoh,
--       p_ext_ref (+ ixtiyoriy p_kassa).
--
-- ## (c) OQIMIDA QAYSI HISOBGA PUL TUSHADI — `p_kassa`
--   `p_kassa` berilmasa `sorov_kassa_of(auth.uid())` (odamning asosiy UZS
--   kassasi). Berilsa — UCH QAVAT tekshiriladi:
--     (1) 6.5 dagi umumiy kassa shakli: faol, aktiv, 5xxx, xarajat_guruh
--         EMAS, valyutasi UZS;
--     (2) `perm_check_accounts` — mavjud qoida (ikkala eski oqimda ham bor);
--     (3) 🔴 OILA CHEGARASI (faqat top-up uchun, YANGI):
--         `perm_op_key(p_kassa) = any(op_kassa_ids)` — ya'ni hisob
--         HAQIQATDA so'rovchining oilasiga tegishli.
--   NEGA (3) KERAK: `perm_check_accounts` `kassa_scope <> 'list'` bo'lgan
--   userga (sukut 'all') va adminga HAR QANDAY hisob uchun `true` beradi.
--   Xarajatli oqimda bu xavfsiz edi (pul o'sha hisobdan CHIQARDI), top-up
--   da esa pul hisobga KIRADI — cheklovsiz user boshqa odamning kassasiga
--   pul so'rab, tasdiqlovchining pulini begona kassaga ko'chirardi.
--   `perm_op_key` valyuta/pul-turi bolalarini parentga yig'adi, ya'ni
--   Naqd/Click bolasiga tushirish MUMKIN (o'z oilasi).
--   ⚠️ Kassa biriktirilmagan user (admin, `kassa_scope='all'`) top-up
--   YARATA OLMAYDI — ANIQ xato oladi. Ongli: unda "qaysi kassa" savoliga
--   javob yo'q, taxmin qilib pul ko'chirish eng yomon variant
--   (PROVODKA_SOROVLAR.sql 5-BO'LIM dagi qaror bilan bir xil).
--
-- ## (c) OQIMIDA SUMMA CHEGARASI
--   Xarajatli oqimdagi `ceil(xarajat/1000)*1000` chegarasi TOP-UP ga
--   UMUMAN taalluqli emas (xarajat yo'q). O'rniga faqat XATO TERISH
--   qorovuli: 100 000 000 so'm. Bu balans emas, moliyaviy qaror ham
--   emas — pulni baribir tasdiqlovchi beradi.
--   🔴 `sorov_topup_chegara()` (500) BU YERDA ISHLATILMAYDI: u KLIENT
--   qarori (qaysi modal ochiladi), server sharti EMAS. Aks holda hodim
--   500 dan ko'p puli bo'lsa ham asosli top-up so'rayolmasdi va tugma
--   jimgina xato bera boshlardi.
--
-- ## QAYTISH
--   {ok:true, sorov_id, entry_id, status:'pending', xarajat_yangi, turi}
--   `turi` — YANGI kalit: 'topup' yoki 'xarajat'. Klient AYNAN shu bilan
--   "eski SQL" holatini aniqlaydi (fail-closed): eski `sorov_yarat` bu
--   kalitni umuman qaytarmaydi.
--   Top-up da: `entry_id = null`, `xarajat_yangi = false`.
--
-- ⚠️ (c) oqimida XARAJAT METADATASI (p_izoh_xarajat, p_entry_date,
--    p_filial_ids, p_davr_*, p_kommunal_turi) E'TIBORSIZ qoldiriladi —
--    yozuv yaratilmagani uchun yozadigan joy yo'q. Klient ularni
--    yubormaydi; javobdagi `entry_id = null` buni ochiq ko'rsatadi.
-- #####################################################################

create or replace function sorov_yarat(
  p_kassa          uuid    default null,
  p_modda          uuid    default null,
  p_summa_xarajat  numeric default null,
  p_izoh_xarajat   text    default null,
  p_kimdan         uuid    default null,
  p_sorov_summa    numeric default null,
  p_sorov_izoh     text    default null,
  p_ext_ref        text    default null,
  p_entry_date     date    default null,
  p_filial_ids     uuid[]  default null,
  p_davr_start     date    default null,
  p_davr_end       date    default null,
  p_kommunal_turi  text    default null,
  p_xarajat_entry  uuid    default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_ext    text := nullif(btrim(p_ext_ref), '');
  v_izoh   text := nullif(btrim(p_sorov_izoh), '');
  v_xizoh  text := nullif(btrim(p_izoh_xarajat), '');
  v_kassa  accounts;
  v_modda  accounts;
  v_gk     uuid;
  v_entry  uuid;
  v_sorov  uuid;
  v_yangi  boolean := true;
  v_chegara numeric;
  v_berilgan numeric := 0;   -- shu xarajatga ALLAQACHON jonatilgan pul (kumulyativ chegara)
  v_est    text;
  v_edel   boolean;
  v_ega    text;      -- xarajat yozuvining egasi (created_by, tur-mustaqil)
  v_kid    uuid;      -- xarajat qaysi kassadan chiqadi (yozuvdan yoki p_kassa)
  v_xar    numeric;   -- xarajat summasi (yozuvdan yoki p_summa_xarajat)
  v_topup  boolean := false;      -- 🆕 (c) oqimi: xarajatsiz sof so'rov
  v_up     user_perms;            -- 🆕 top-up oila chegarasi uchun
  v_topmax numeric := 100000000;  -- 🆕 xato terish qorovuli (100 mln)
begin
  -- "Saqlanmoqda…" abadiy aylanmasin (xarajat_saqlash_taqsim naqshi)
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  -- ---- 6.1 So'rov summasi -------------------------------------------
  if p_sorov_summa is null or p_sorov_summa <= 0
     or p_sorov_summa <> round(p_sorov_summa, 2) then
    raise exception 'Sorov summasi musbat bolishi kerak' using errcode = '22000';
  end if;

  -- ---- 6.2 Izoh — MAJBURIY (.sorov-ui.md §1.4) ----------------------
  if v_izoh is null or length(v_izoh) < 3 then
    raise exception 'Sorov izohi majburiy (kamida 3 belgi)' using errcode = '22000';
  end if;
  if length(v_izoh) > 200 then
    raise exception 'Sorov izohi 200 belgidan oshmasin' using errcode = '22000';
  end if;

  -- ---- 6.3 Token shakli (xarajat_saqlash_taqsim bilan bir xil) ------
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bolishi kerak' using errcode = '22000';
  end if;

  -- ---- 6.3b 🆕 REJIM: TOP-UP mi? ------------------------------------
  --      Shart AYNAN uchta null: modda, xarajat summasi va mavjud yozuv.
  --      Bittasi berilgan bo'lsa — eski oqimlar, ular O'ZGARMAGAN.
  v_topup := (p_modda is null and p_summa_xarajat is null and p_xarajat_entry is null);

  -- ---- 6.4 XARAJAT MANBASI: top-up / mavjud pending yozuv / yangi ---
  if v_topup then
    -- (c) SOF SO'ROV: xarajat YO'Q. Faqat pul TUSHADIGAN hisob aniqlanadi.
    v_kid   := coalesce(p_kassa, sorov_kassa_of(v_uid));
    v_xar   := null;      -- xarajat summasi YO'Q (sorovlar.xarajat_summa null)
    v_yangi := false;     -- yangi entry YOZILMAYDI (6.7b o'tkazib yuboriladi)
    if v_kid is null then
      raise exception 'Sizga kassa biriktirilmagan — balans toldirish sorovi ishlamaydi'
        using errcode = '22000';
    end if;
    -- 🔴 SPAM QOROVULI (1.4): bir vaqtda BITTA ochiq top-up.
    --    Indeks ham to'sadi; bu yerdagi tekshiruv ANIQ matn beradi.
    if exists (select 1 from sorovlar s
                where s.sorovchi_id = v_uid
                  and s.status = 'pending'
                  and s.xarajat_entry_id is null) then
      raise exception 'Sizda javob kutayotgan sorov bor — avval unga javob kelsin'
        using errcode = '22000';
    end if;

  elsif p_xarajat_entry is not null then
    select e.status, e.is_deleted, to_jsonb(e) ->> 'created_by'
      into v_est, v_edel, v_ega
      from entry e where e.id = p_xarajat_entry for update;
    if not found then
      raise exception 'Xarajat yozuvi topilmadi' using errcode = '22000';
    end if;
    if v_edel is true then
      raise exception 'Xarajat yozuvi ochirilgan' using errcode = '22000';
    end if;
    if v_est <> 'pending' then
      raise exception 'Bu xarajat allaqachon kuchda — sorov kerak emas' using errcode = '22000';
    end if;
    -- 🔴 EGALIK — FAIL-CLOSED (sorov_xarajat_bekor dagi qoida bilan bir xil).
    if not is_admin() and (v_ega is null or v_ega <> v_uid::text) then
      raise exception 'Bu xarajat sizniki emas' using errcode = '42501';
    end if;

    -- Kassa satri (eng katta Kt pul satri) — kassa va summa manbai
    select l.account_id, l.credit into v_kid, v_xar
      from entry_line l
      join accounts a on a.id = l.account_id
     where l.entry_id = p_xarajat_entry and l.credit > 0
       and a.type = 'aktiv' and a.code like '5%'
     order by l.credit desc
     limit 1;
    if v_kid is null or coalesce(v_xar, 0) <= 0 then
      raise exception 'Xarajat yozuvining kassa satri topilmadi' using errcode = '22000';
    end if;
    -- Klient kassa yuborsa — mos kelishi shart (jimgina boshqasiga yozilmasin)
    if p_kassa is not null and p_kassa <> v_kid then
      raise exception 'Kassa xarajat yozuviga mos emas' using errcode = '22000';
    end if;
    -- Ochiq so'rov bo'lsa — ANIQ matn (aks holda 23505 handleri
    -- "allaqachon saqlangan" deb chalg'ituvchi javob berardi).
    if exists (select 1 from sorovlar s
                where s.xarajat_entry_id = p_xarajat_entry and s.status = 'pending') then
      raise exception 'Bu xarajat uchun ochiq sorov allaqachon bor' using errcode = '22000';
    end if;
    v_entry := p_xarajat_entry;
    v_yangi := false;

  else
    if p_summa_xarajat is null or p_summa_xarajat <= 0
       or p_summa_xarajat <> round(p_summa_xarajat, 2) then
      raise exception 'Xarajat summasi musbat bolishi kerak' using errcode = '22000';
    end if;
    if p_kassa is null then
      raise exception 'Kassa tanlanmagan' using errcode = '22000';
    end if;
    v_kid := p_kassa;
    v_xar := p_summa_xarajat;

    -- Modda faqat YANGI yozuvda kerak
    select * into v_modda from accounts where id = p_modda;
    if not found or v_modda.is_active is distinct from true then
      raise exception 'Xarajat moddasi topilmadi' using errcode = '22000';
    end if;
    if v_modda.type <> 'xarajat' then
      raise exception 'Tanlangan hisob xarajat moddasi emas' using errcode = '22000';
    end if;
  end if;

  -- ---- 6.5 Kassa tekshiruvi (UCHALA oqim uchun BITTA joyda) ---------
  select * into v_kassa from accounts where id = v_kid;
  if not found or v_kassa.is_active is distinct from true then
    raise exception 'Kassa topilmadi yoki faol emas' using errcode = '22000';
  end if;
  if v_kassa.type <> 'aktiv' or v_kassa.code not like '5%'
     or v_kassa.kassa_turi is not distinct from 'xarajat_guruh' then
    raise exception 'Bu hisob kassa emas' using errcode = '22000';
  end if;
  if coalesce(v_kassa.currency, 'UZS') <> 'UZS' then
    raise exception 'Pul sorash faqat som kassasida ishlaydi' using errcode = '22000';
  end if;
  -- 🔴 O'z kassasi ekanini SERVER tekshiradi (trigger baribir tekshiradi,
  --    bu esa ANIQ xato matni beradi va yarim ish qilinmaydi).
  if not perm_check_accounts(array[v_kid]) then
    raise exception 'Ruxsat yoq: bu kassada amaliyot qilish huquqingiz yoq'
      using errcode = '42501';
  end if;

  -- ---- 6.5b 🆕 TOP-UP OILA CHEGARASI (sabab 2-BO'LIM sarlavhasida) --
  if v_topup then
    select * into v_up from user_perms where user_id = v_uid;
    if not found or v_up.kassa_scope <> 'list' then
      raise exception 'Sizga kassa biriktirilmagan — balans toldirish sorovi ishlamaydi'
        using errcode = '42501';
    end if;
    if not (perm_op_key(v_kid) = any (coalesce(v_up.op_kassa_ids, '{}'::uuid[]))) then
      raise exception 'Bu hisob sizning kassangiz emas' using errcode = '42501';
    end if;
  end if;

  -- ---- 6.6 So'rov summasining YUQORI CHEGARASI ----------------------
  if v_topup then
    -- 🆕 Xarajat yo'q -> xarajatga bog'liq chegara ham yo'q. Faqat xato
    --    terish qorovuli (100 mln). Pulni baribir tasdiqlovchi beradi.
    if p_sorov_summa > v_topmax then
      raise exception 'Sorov summasi juda katta — tekshirib qayta yozing'
        using errcode = '22000';
    end if;
  else
    -- 🔴 KUMULYATIV CHEGARA (QA topilmasi 2026-08-26 — PUL XAVFI).
    --    Chegara XARAJAT summasidan (balansdan EMAS), 1000 ga yuqoriga
    --    yaxlitlangan — klient aynan shunday yaxlitlaydi (.sorov-ui.md §1.3).
    --    ⚠️ Undan SHU XARAJATGA ALLAQACHON JO'NATILGAN pul AYIRILADI.
    --    Busiz: 500k xarajat -> A so'rovi 500k -> 300k berildi ('qisman',
    --    so'rov YOPILADI) -> `sorovlar_ochiq_xarajat_uniq` to'smaydi
    --    ('qisman' <> 'pending') -> B so'rovi YANA 500k chegara bilan ochiladi
    --    -> jami 800k, xarajat 500k, hodimda 300k ORTIQCHA pul qoladi.
    --    Klient ham, tasdiqlovchi ham buni ko'rmaydi (xarajat summasi
    --    javobdan ataylab olib tashlangan) — ya'ni yagona to'siq SHU YERDA.
    --    'qisman' VA 'tasdiq' ikkalasi ham sanaladi: ikkalasida ham pul
    --    haqiqatan chiqqan (`jonatilgan_summa`), 'rad' da esa chiqmagan.
    if p_xarajat_entry is not null then
      select coalesce(sum(s2.jonatilgan_summa), 0) into v_berilgan
        from sorovlar s2
       where s2.xarajat_entry_id = p_xarajat_entry
         and s2.status in ('qisman', 'tasdiq');
    end if;
    v_chegara := ceil(v_xar / 1000.0) * 1000 - v_berilgan;
    if v_chegara <= 0 then
      raise exception 'Bu xarajat uchun yetarli pul allaqachon jonatilgan'
        using errcode = '22000';
    end if;
    if p_sorov_summa > v_chegara then
      raise exception 'Sorov summasi qolgan qismdan katta bola olmaydi (qolgan: %)',
        v_chegara using errcode = '22000';
    end if;
  end if;

  -- ---- 6.7 Kimdan ---------------------------------------------------
  if p_kimdan is null then
    raise exception 'Kimdan sorash tanlanmagan' using errcode = '22000';
  end if;
  if p_kimdan = v_uid then
    raise exception 'Ozingizdan pul sorab bolmaydi' using errcode = '22000';
  end if;
  if not sorov_nomzod_ok(p_kimdan) then
    raise exception 'Bu odamdan sorab bolmaydi (kassasi yoki sorovlar ruxsati yoq)'
      using errcode = '22000';
  end if;
  v_gk := sorov_kassa_of(p_kimdan);
  if v_gk is null then
    raise exception 'Bu odamning kassasi aniqlanmadi' using errcode = '22000';
  end if;

  -- ---- 6.7b YANGI pending xarajat (faqat (b) oqimida) ---------------
  --      Top-up da `v_yangi` false — bu blok UMUMAN ishlamaydi.
  if v_yangi then
    insert into entry (entry_date, description, source, status,
                       filial_ids, davr_start, davr_end, kommunal_turi,
                       ext_ref, created_by)
    values (
      coalesce(p_entry_date, (now() at time zone 'Asia/Tashkent')::date),
      v_xizoh,
      'manual',                       -- 🔴 jurnal tasnifi o'zgarmasin
      'pending',                      -- 🔴 BALANSGA TA'SIR QILMAYDI
      coalesce(p_filial_ids, '{}'::uuid[]),
      p_davr_start, p_davr_end,
      nullif(btrim(coalesce(p_kommunal_turi, '')), ''),
      v_ext,
      -- 🔴 `created_by` ANIQ yoziladi (trigger/default'ga tayanilmaydi):
      --    `sorov_xarajat_bekor` va 6.4 dagi egalik tekshiruvi shu ustunga
      --    tayanadi.
      v_uid)
    returning id into v_entry;

    -- Dt xarajat modda / Kt kassa. Dt = Kt (check_entry_balanced rozi).
    insert into entry_line (entry_id, account_id, debit, credit)
    values (v_entry, p_modda, v_xar, 0),
           (v_entry, v_kid,   0,     v_xar);
  end if;

  -- ---- 6.8 So'rov qatori --------------------------------------------
  --      Top-up: v_entry null (xarajatga bog'lanmagan), v_xar null.
  insert into sorovlar (sorovchi_id, kimdan_id, kassa_id, kimdan_kassa_id,
                        summa, izoh, status, xarajat_entry_id, xarajat_summa,
                        ext_ref)
  values (v_uid, p_kimdan, v_kid, v_gk,
          p_sorov_summa, v_izoh, 'pending', v_entry, v_xar,
          case when v_ext is null then null else v_ext || ':sorov' end)
  returning id into v_sorov;

  return jsonb_build_object('ok', true,
                            'sorov_id',      v_sorov,
                            'entry_id',      v_entry,
                            'status',        'pending',
                            'xarajat_yangi', v_yangi,
                            -- 🆕 klient shu kalit bilan rejimni tasdiqlaydi
                            'turi',          case when v_topup then 'topup' else 'xarajat' end);

exception
  -- 🔴 TAKROR. Kod 23505 O'ZGARMAYDI — klient aynan shu kod bo'yicha
  --    "allaqachon saqlangan" deb qaror qiladi.
  when unique_violation then
    -- 🆕 TOP-UP: bu oqimda `entry` UMUMAN yozilmaydi, ya'ni yagona mumkin
    --    bo'lgan takror — `sorovlar_ext_ref_uniq` yoki
    --    `sorovlar_ochiq_topup_uniq`. Ikkalasi ham "so'rov allaqachon
    --    yuborilgan" degani; "xarajat saqlandi" degan yolg'on matn bu
    --    yerda CHIQMASLIGI shart.
    if v_topup then
      raise exception 'Bu sorov allaqachon yuborilgan (takroriy yuborish tosildi)'
        using errcode = '23505';
    end if;
    if v_ext is null then
      -- Token yuborilmagan: bizning to'siq emas. Ochiq so'rov indeksi
      -- (sorovlar_ochiq_xarajat_uniq) bo'lsa — tushunarli matn.
      if p_xarajat_entry is not null then
        raise exception 'Bu xarajat uchun ochiq sorov allaqachon bor'
          using errcode = '23505';
      end if;
      raise;
    end if;
    -- 🔴 (a) "qolganini so'rash" oqimida YANGI xarajat yozilmagan, ya'ni
    --    yagona mumkin bo'lgan takror — `sorovlar_ext_ref_uniq`.
    if p_xarajat_entry is not null then
      raise exception 'Bu sorov allaqachon yuborilgan (takroriy yuborish tosildi)'
        using errcode = '23505';
    end if;
    raise exception 'Bu xarajat allaqachon saqlangan (takroriy yuborish tosildi)'
      using errcode = '23505';
end $fn$;

revoke all on function sorov_yarat(uuid, uuid, numeric, text, uuid, numeric, text,
                                   text, date, uuid[], date, date, text, uuid)
  from public, anon;
grant execute on function sorov_yarat(uuid, uuid, numeric, text, uuid, numeric, text,
                                      text, date, uuid[], date, date, text, uuid)
  to authenticated;

comment on function sorov_yarat(uuid, uuid, numeric, text, uuid, numeric, text,
                                text, date, uuid[], date, date, text, uuid) is
  'ATOMIK: pending xarajat (entry + 2 entry_line) + sorovlar qatori bitta tranzaksiyada. '
  'UCH oqim: (a) p_xarajat_entry -> mavjud pendingga ulanish; (b) p_modda + p_summa_xarajat '
  '-> yangi pending xarajat; (c) uchalasi null -> TOP-UP (xarajatsiz sof sorov, entry_id null). '
  'Javobdagi turi kaliti: topup yoki xarajat.';


-- #####################################################################
-- ##  3-BO'LIM — PostgREST sxema keshi                               ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  4-BO'LIM — TEKSHIRUV (kutilgan qiymatlar izohda)               ##
-- #####################################################################

-- 4.1  Chegara sozlamasi joyidami (kutilgan: 500 yoki admin qo'ygan qiymat)
select (select val from provodka_config where key = 'sorov_topup_chegara') as config_qiymat,
       sorov_topup_chegara()                                               as funksiya_qiymat;

-- 4.2  Yangi funksiyalar authenticated ga ochiqmi (ikkalasi ham true)
select p.proname,
       has_function_privilege('authenticated', p.oid, 'execute') as ochiq
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('sorov_topup_chegara','set_sorov_topup_chegara')
 order by 1;

-- 4.3  🔴 `sorov_yarat` TOP-UP rejimini biladimi (ikkalasi ham true bo'lsin).
--      false chiqsa -> PROVODKA_SOROVLAR.sql keyin RUN qilingan, BU FAYLNI
--      qayta RUN qiling.
select (select p.prosrc like '%v_topup%'
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname='public' and p.proname='sorov_yarat' limit 1) as topup_shoxi_bor,
       (select p.prosrc like '%''turi''%'
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname='public' and p.proname='sorov_yarat' limit 1) as turi_kaliti_bor;

-- 4.4  Imzo O'ZGARMAGANmi (kutilgan: aynan 14 argument)
select p.pronargs as argument_soni_14_bulsin,
       pg_get_function_identity_arguments(p.oid) as imzo
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'sorov_yarat';

-- 4.5  Top-up indeksi (true bo'lsin)
select exists (select 1 from pg_indexes
                where schemaname='public' and tablename='sorovlar'
                  and indexname='sorovlar_ochiq_topup_uniq') as topup_uniq_bor;

-- 4.6  Ochiq top-up so'rovlari (diagnostika; xarajatsiz qatorlar)
select s.id, s.sorovchi_id, s.summa, s.izoh, s.status, s.created_at
  from sorovlar s
 where s.xarajat_entry_id is null
 order by s.created_at desc
 limit 20;


-- #####################################################################
-- ##  5-BO'LIM — `sorov_tasdiq` TAHLILI (o'zgartirilmadi — sabab)    ##
-- #####################################################################
--
-- 🔴 TASDIQLASHDA XARAJAT YOPISH BOSQICHI O'ZI O'TKAZIB YUBORILADI.
--    `sorov_tasdiq` tanasidagi UCHALA xarajat bloki ham
--    `if s.xarajat_entry_id is not null ...` sharti bilan o'ralgan:
--      * 8.5 — xarajat holati (o'chirilgan/tahrirlangan) tekshiruvi;
--      * 8.6 — pending xarajatni posted qilish;
--      * javobdagi `qoldiq_yetmadi` bayrog'i.
--    Top-up qatorida `xarajat_entry_id` NULL, ya'ni uchalasi ham
--    o'tkazib yuboriladi va faqat PUL PROVODKASI yoziladi:
--
--        Dt  sorovlar.kassa_id        (so'rovchining kassasi)    p_summa
--        Kt  tanlangan tolov hisobi   (tasdiqlovchining kassasi) p_summa
--        entry.status = 'posted', source = 'manual',
--        ext_ref = sorov:<id>:jonatma, description = Pul sorovi: <izoh>
--
--    Natija: so'rovchining kassasi + p_summa, tasdiqlovchiniki - p_summa.
--    Sof balans to'ldirish — aynan kerakli xatti-harakat. Dt = Kt, ya'ni
--    `check_entry_balanced` rozi. `xarajat_yopildi` false qoladi (to'g'ri:
--    yopadigan xarajat yo'q), `qoldiq_yetmadi` ham false.
--    ✅ SHU SABABLI `sorov_tasdiq` GA BIRORTA QATOR TEGILMADI.
--
-- 🔴 GUARD ISTISNOSI (PROVODKA_SOROVLAR.sql 4-BO'LIM) top-up da ham
--    ishlaydi: u `s.jonatma_entry_id` + `s.kimdan_id = auth.uid()` +
--    `new.account_id in (s.kassa_id, s.kimdan_kassa_id)` + `decided_at = now()`
--    + summa tengligiga qaraydi — xarajat haqida hech narsa so'ramaydi.
--
-- ℹ️ `sorov_rad` ham xavfsiz: xarajatni bekor qilish bloki
--    `if v_auto_bekor and s.xarajat_entry_id is not null` — top-up da
--    o'tkazib yuboriladi, faqat status 'rad' bo'ladi.
-- ℹ️ `sorov_qator` javobida top-up qatori `entry_id: null`,
--    `xarajat_yopildi: false` bo'lib keladi. Klient (`hodim-dev.html`
--    `srvPendRender`) "yetim xarajat" guruhiga FAQAT uuid shaklidagi
--    `entry_id` bo'lgan qatorlarni oladi — top-up u yerga TUSHMAYDI,
--    "Tasdiq kutayotgan so'rovlar" guruhida ko'rinadi.
--
--
-- #####################################################################
-- ##  6-BO'LIM — KLIENT KONTRAKTI (hodim-dev.html)                   ##
-- #####################################################################
--
--   sorov_topup_chegara()  -> numeric (500). `init()` da BIR MARTA,
--     mavjud Promise.all ichida. Xato/RPC yo'q bo'lsa klient zaxira 500
--     ishlatadi (ikkala shox ham pul harakatlantirmaydi — qaror faqat
--     "qaysi modal ochiladi"; pul baribir tasdiqdan keyin chiqadi).
--     🔴 Qiymat foydalanuvchiga HECH QAYERDA ko'rsatilmaydi.
--
--   sorov_yarat({p_kimdan, p_sorov_summa, p_sorov_izoh, p_ext_ref
--                [, p_kassa]})   <- TOP-UP (modda/summa/entry YUBORILMAYDI)
--     -> {ok:true, sorov_id, entry_id:null, status:'pending',
--         xarajat_yangi:false, turi:'topup'}
--     🔴 FAIL-CLOSED: `turi` !== 'topup' bo'lsa klient MUVAFFAQIYAT
--        DEMASLIGI kerak (eski SQL boshqa narsa yozgan bo'lishi mumkin).
--        Eski SQL bu chaqiruvga 22000 "Xarajat summasi musbat bolishi
--        kerak" beradi — klient uni "hali ulanmagan" deb tarjima qiladi.
--     🔴 23505 -> "So'rov allaqachon yuborilgan" (takror himoyasi ishladi,
--        bu MUVAFFAQIYAT — mavjud `isDup` shoxi).
--     ⚠️ "Sizda javob kutayotgan sorov bor" (22000) — bitta ochiq top-up
--        qoidasi (1.4). Klient matnni o'sha holicha ko'rsatadi.
--
--
-- #####################################################################
-- ##  7-BO'LIM — ROLLBACK (qo'lda)                                   ##
-- #####################################################################
-- -- 7.1 sorov_yarat ni ESKI holatiga: PROVODKA_SOROVLAR.sql ning
-- --     6-BO'LIMini qayta RUN qiling (imzo bir xil — replace yetadi).
-- --     ⚠️ Undan OLDIN ochiq top-up so'rovlarini hal qiling (4.6):
-- --     eski funksiya ularni yarata olmaydi, lekin mavjudlari
-- --     sorov_tasdiq/sorov_rad orqali baribir hal qilinadi.
-- --
-- -- 7.2 Indeks:
-- -- drop index if exists sorovlar_ochiq_topup_uniq;
-- --
-- -- 7.3 Chegara funksiyalari:
-- -- drop function if exists set_sorov_topup_chegara(numeric);
-- -- drop function if exists sorov_topup_chegara();
-- -- delete from provodka_config where key = 'sorov_topup_chegara';
-- =====================================================================
