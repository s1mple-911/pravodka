-- =====================================================================
-- PROVODKA — RUXSAT SO'ROVIDA MODDA TALABLARI (2026-09-09, Asilbek)
-- ---------------------------------------------------------------------
-- ## MUAMMO (prodda topilgan)
--   Yopiq xarajat moddasiga "Ruxsat so'rash" (Tab 2) moddaning bayroqlarini
--   UMUMAN bilmasdi: chek / filial / davr / kommunal turi / maxsus maydon —
--   hech biri so'ralmasdi, Excel jadvali esa ixtiyoriy edi. `ruxsat_tasdiq`
--   provodkani O'ZI yozgani uchun bu yo'l moddaning HAMMA talabini chetlab
--   o'tardi. Ya'ni: hodim "Oziq-ovqat" ga ruxsat so'rab, chek va Excel'siz
--   xarajat yozdira olardi — asosiy formada esa bu mumkin emas.
--
-- ## YECHIM
--   Talablar so'rov paytida yig'iladi (`ruxsat_sorov` ga metadata ustunlari),
--   SERVER ularni majburlaydi (`ruxsat_yarat_v2`), tasdiqda esa hammasi
--   yaratilayotgan `entry` ga ko'chadi (`ruxsat_tasdiq`).
--   Chek surati uchun: klient entry id'sini OLDINDAN yaratadi (`entry_uid`),
--   chekni odatdagi yo'lga (`xarajat-cheklari/{kassa_id}/{entry_id}.jpg`)
--   yuklaydi, `ruxsat_tasdiq` esa `entry` ni AYNAN shu id bilan yaratadi.
--   Shu tufayli storage policy'ga, fayl ko'chirishga, jurnaldagi o'qish
--   yo'liga TEGILMAYDI — chek o'z joyida turadi.
--
-- ## RUN TARTIBI (Asilbek) — bo'limlarni tartib bilan
--   0-BO'LIM — old shart tekshiruvi (hech narsa yozmaydi)
--   1-BO'LIM — ruxsat_sorov yangi ustunlari + cheklovlar
--   2-BO'LIM — ruxsat_talab(uuid) — ICHKI, moddaning talablari
--   3-BO'LIM — ruxsat_yopiq_moddalar() — bayroqlar qo'shiladi
--   4-BO'LIM — ruxsat_yarat_v2(jsonb) — YANGI (eski ruxsat_yarat TEGILMAYDI)
--   5-BO'LIM — ruxsat_qator(...) — yangi kalitlar
--   6-BO'LIM — ruxsat_tasdiq(uuid) — metadata entry ga ko'chadi
--   notify pgrst — PostgREST sxema keshi
--   7-BO'LIM — YAKUNIY TEKSHIRUV (faqat select)
--
-- ## OLD SHART (bazada bo'lishi kerak)
--   PROVODKA_RUXSAT_SOROV.sql  -> ruxsat_sorov, ruxsat_yarat, ruxsat_qator,
--                                 ruxsat_tasdiq, ruxsat_yopiq_moddalar
--   PROVODKA_JADVAL_2.sql      -> ruxsat_sorov.jadval, excel_jadval bayrog'i
--   PROVODKA_XARAJAT_MAYDON.sql-> xarajat_maydon, xarajat_maydon_modda,
--                                 entry_maydon, xm_majburiy_yoq
--
-- ## QOIDALAR (CLAUDE.md, buzilmasin)
--   * anonim `do` bloki YO'Q — har `do` bloki NOMLANGAN teg bilan.
--   * har funksiya tanasi NOMLANGAN dollar-teg bilan o'raladi.
--   * izohda dollar-qavs (ikki dollar yonma-yon) YO'Q.
--   * xato matnlarida apostrof ISHLATILMAYDI (mavjud uslub).
--   * hammasi ADDITIVE: eski jadval/ustun/funksiya imzosi buzilmaydi.
--     `ruxsat_yarat` (6 argumentli) TEGILMAYDI — prod frontend uni chaqiradi.
--   * idempotent: qayta RUN qilish xavfsiz.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (faqat select/exception)        ##
-- #####################################################################

do $rxtalab_pre$
declare
  v_yoq text;
begin
  if to_regclass('public.ruxsat_sorov') is null then
    raise exception 'ruxsat_sorov jadvali yoq — avval PROVODKA_RUXSAT_SOROV.sql ni bajaring';
  end if;
  if to_regprocedure('public.ruxsat_yarat(uuid,uuid,numeric,text,uuid,text)') is null then
    raise exception 'ruxsat_yarat(...) yoq — avval PROVODKA_RUXSAT_SOROV.sql ni bajaring';
  end if;
  if to_regprocedure('public.ruxsat_qator(ruxsat_sorov,uuid)') is null then
    raise exception 'ruxsat_qator(...) yoq — avval PROVODKA_RUXSAT_SOROV.sql ni bajaring';
  end if;
  if to_regprocedure('public.ruxsat_tasdiq(uuid)') is null then
    raise exception 'ruxsat_tasdiq(uuid) yoq — avval PROVODKA_RUXSAT_SOROV.sql ni bajaring';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_name = 'ruxsat_sorov' and column_name = 'jadval') then
    raise exception 'ruxsat_sorov.jadval yoq — avval PROVODKA_JADVAL_2.sql ni bajaring';
  end if;
  if to_regclass('public.xarajat_maydon_modda') is null then
    raise exception 'xarajat_maydon_modda yoq — avval PROVODKA_XARAJAT_MAYDON.sql ni bajaring';
  end if;
  if to_regprocedure('public.xm_majburiy_yoq(uuid)') is null then
    raise exception 'xm_majburiy_yoq(uuid) yoq — avval PROVODKA_XARAJAT_MAYDON.sql ni bajaring';
  end if;

  -- Modda bayroqlari: 2-BO'LIM ularga TO'G'RIDAN murojaat qiladi.
  select string_agg(k, ', ') into v_yoq
    from unnest(array['chek_majburiy','izoh_majburiy','davr_majburiy','filial_majburiy',
                      'ovqat_modda','ai_tekshir','spidometr_ai','excel_jadval']) k
   where not exists (select 1 from information_schema.columns
                      where table_name = 'accounts' and column_name = k);
  if v_yoq is not null then
    raise exception 'accounts ustunlari yoq: % — avval tegishli SQL fayllarni bajaring', v_yoq;
  end if;

  -- entry metadata ustunlari (sorov_yarat ham shularga yozadi).
  select string_agg(k, ', ') into v_yoq
    from unnest(array['filial_ids','davr_start','davr_end','kommunal_turi','jadval']) k
   where not exists (select 1 from information_schema.columns
                      where table_name = 'entry' and column_name = k);
  if v_yoq is not null then
    raise exception 'entry ustunlari yoq: %', v_yoq;
  end if;
end
$rxtalab_pre$;


-- #####################################################################
-- ##  1-BO'LIM — ruxsat_sorov yangi ustunlari                         ##
-- #####################################################################
-- Hammasi NULLABLE / default bilan — eski qatorlar tegilmaydi, eski
-- `ruxsat_yarat` (6 argumentli) ham avvalgidek ishlayveradi.

alter table ruxsat_sorov add column if not exists entry_uid     uuid;
alter table ruxsat_sorov add column if not exists filial_ids    uuid[];
alter table ruxsat_sorov add column if not exists davr_start    date;
alter table ruxsat_sorov add column if not exists davr_end      date;
alter table ruxsat_sorov add column if not exists kommunal_turi text;
alter table ruxsat_sorov add column if not exists chek_bor      boolean not null default false;
alter table ruxsat_sorov add column if not exists maydonlar     jsonb;

comment on column ruxsat_sorov.entry_uid is
  'Klient OLDINDAN yaratgan entry id. Chek surati sorov paytida shu id bilan '
  'xarajat-cheklari/{kassa_id}/{entry_uid}.jpg ga yuklanadi; ruxsat_tasdiq entry ni '
  'AYNAN shu id bilan yaratadi — shuning uchun fayl kochirilmaydi, jurnal odatdagidek topadi.';
comment on column ruxsat_sorov.filial_ids is
  'Modda filial_majburiy bolsa tanlangan filiallar. Tasdiqda entry.filial_ids ga kochadi. '
  'DIQQAT: endi bosh emas — ya''ni filial-modda OYLIK LIMITI bu yozuvga ham taalluqli boladi.';
comment on column ruxsat_sorov.davr_start is 'Modda davr_majburiy bolsa davr boshi. Tasdiqda entry.davr_start.';
comment on column ruxsat_sorov.davr_end   is 'Modda davr_majburiy bolsa davr oxiri. Tasdiqda entry.davr_end.';
comment on column ruxsat_sorov.kommunal_turi is 'Kommunal modda (9413) uchun tur. Tasdiqda entry.kommunal_turi.';
comment on column ruxsat_sorov.chek_bor is
  'Klient chek suratini yuklaganini bildiradi (fayl storage da, server uni korolmaydi). '
  'Asosiy formadagi bilan BIR XIL ishonch darajasi — u yerda ham tekshiruv klientda.';
comment on column ruxsat_sorov.maydonlar is
  'Maxsus maydon qiymatlari: [{"maydon_id":uuid,"element_id":uuid}] yoki [{"maydon_id":uuid,"qiymat":"..."}]. '
  'Tasdiqda entry_maydon qatorlariga kochadi (entry_maydon_yoz bilan bir xil shakl).';

do $rxtalab_chk$
begin
  if not exists (select 1 from pg_constraint where conname = 'ruxsat_sorov_maydonlar_chk') then
    alter table ruxsat_sorov
      add constraint ruxsat_sorov_maydonlar_chk
      check (maydonlar is null
             or (jsonb_typeof(maydonlar) = 'array' and pg_column_size(maydonlar) <= 20000));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ruxsat_sorov_davr_chk') then
    alter table ruxsat_sorov
      add constraint ruxsat_sorov_davr_chk
      check (davr_start is null or davr_end is null or davr_end >= davr_start);
  end if;
end
$rxtalab_chk$;

-- Bitta entry id ikki sorovga berilmasin (chek fayli aralashib ketmasin).
create unique index if not exists ruxsat_sorov_entry_uid_uq
  on ruxsat_sorov (entry_uid) where entry_uid is not null;


-- #####################################################################
-- ##  2-BO'LIM — ruxsat_talab(uuid) — ICHKI                           ##
-- #####################################################################
-- Moddaning talablari BITTA joyda: `ruxsat_yopiq_moddalar` (klient nima
-- korsatishini bilsin) va `ruxsat_yarat_v2` (server majburlasin) — ikkalasi
-- ham shundan oqiydi, hech qachon bir-biridan ajrab ketmaydi.
--
-- 🔴 `bloklangan` — bu talabni ruxsat sorovi shakli IFODALAY OLMAYDI:
--    * ovqat_modda  — hodimma-hodim taqsimot royxati kerak (asosiy formada
--                     ham "Pul sorash" TAQIQ, ayni sabab);
--    * spidometr_ai — mashina tablosi surati + km + AI tahlili kerak.
--    Bunday moddaga ruxsat sorash RAD etiladi — talab chetlab otilmasin.

create or replace function ruxsat_talab(p_modda uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  a         accounts;
  v_maydon  boolean := false;
  v_mreq    boolean := false;
  v_blok    text    := null;
begin
  select * into a from accounts where id = p_modda;
  if not found then
    return jsonb_build_object('bor', false);
  end if;

  select count(*) > 0,
         count(*) filter (where coalesce(mm.required, m.required)) > 0
    into v_maydon, v_mreq
    from xarajat_maydon m
    join xarajat_maydon_modda mm on mm.maydon_id = m.id
   where m.is_active and mm.modda_id = p_modda;

  if coalesce(a.ovqat_modda, false) then
    v_blok := 'Ovqat xarajati ruxsat sorash orqali yozilmaydi — u hodimma-hodim royxat bilan, faqat oddiy yolda yoziladi';
  elsif coalesce(a.spidometr_ai, false) then
    v_blok := 'Bu turda mashina tablosi surati va km kerak — ruxsat sorash orqali yozib bolmaydi';
  end if;

  return jsonb_build_object(
    'bor',        true,
    'chek',       coalesce(a.chek_majburiy, false) or coalesce(a.ai_tekshir, false)
                                                   or coalesce(a.spidometr_ai, false),
    'ai',         coalesce(a.ai_tekshir, false) or coalesce(a.spidometr_ai, false),
    'izoh',       coalesce(a.izoh_majburiy, false),
    'davr',       coalesce(a.davr_majburiy, false),
    'filial',     coalesce(a.filial_majburiy, false),
    'kommunal',   (a.code = '9413'),
    'ovqat',      coalesce(a.ovqat_modda, false),
    'spidometr',  coalesce(a.spidometr_ai, false),
    'excel',      coalesce(a.excel_jadval, false),
    'maydon',     v_maydon,
    'maydon_req', v_mreq,
    'bloklangan', (v_blok is not null),
    'blok_sabab', v_blok
  );
end $fn$;

revoke all on function ruxsat_talab(uuid) from public, anon;
grant execute on function ruxsat_talab(uuid) to authenticated;

comment on function ruxsat_talab(uuid) is
  'Xarajat moddasining talab bayroqlari (chek/izoh/davr/filial/kommunal/excel/maydon) + '
  'bloklangan (ovqat yoki spidometr — ruxsat sorovi shakli ularni ifodalay olmaydi). '
  'YAGONA manba: ruxsat_yopiq_moddalar ham, ruxsat_yarat_v2 ham shundan oqiydi.';


-- #####################################################################
-- ##  3-BO'LIM — ruxsat_yopiq_moddalar() — bayroqlar                  ##
-- #####################################################################
-- 🔴 PROVODKA_JADVAL_2.sql (4-BO'LIM) dagi ENG OXIRGI tananing VERBATIM
--    nusxasi. Yagona farq: 'excel' o'rniga to'liq `ruxsat_talab(a.id)`
--    obyekti ('talab' kaliti) — 'excel' kaliti ESKI JOYIDA QOLADI, chunki
--    prod `hodim.html` aynan `m.excel` ni o'qiydi.

create or replace function ruxsat_yopiq_moddalar()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  -- Adminga hech narsa yopiq emas — royxat bosh.
  if is_admin() then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name,
                             'excel', coalesce(a.excel_jadval, false),
                             'talab', ruxsat_talab(a.id))
                             order by a.code), '[]'::jsonb)
    into v_out
    from accounts a
   where a.type = 'xarajat'
     and coalesce(a.is_active, true)
     and a.code <> '9110-1'
     and not rbac_modda_ok(a.id);

  return v_out;
end $fn$;

revoke all on function ruxsat_yopiq_moddalar() from public, anon;
grant execute on function ruxsat_yopiq_moddalar() to authenticated;

comment on function ruxsat_yopiq_moddalar() is
  'Chaqiruvchi uchun YOPIQ xarajat moddalari royxati (rbac_modda_ok false). Admin -> bosh massiv. '
  'Har element: excel (eski, prod hodim.html shuni oqiydi) + talab (PROVODKA_RUXSAT_TALAB.sql).';


-- #####################################################################
-- ##  4-BO'LIM — ruxsat_yarat_v2(jsonb) — YANGI                       ##
-- #####################################################################
-- 🔴 ESKI `ruxsat_yarat(uuid,uuid,numeric,text,uuid,text)` TEGILMAYDI —
--    prod `hodim.html` aynan uni chaqiradi. v2 uni ICHIDAN chaqiradi:
--    kassa/modda/summa/izoh/kimdan/ext_ref qoidalari BIR JOYDA qoladi va
--    hech qachon ikkiga ajralmaydi. Bitta funksiya chaqiruvi = bitta
--    tranzaksiya, shuning uchun sorov va uning metadatasi ATOMAR yoziladi
--    (jadval uchun ishlatilgan "keyin biriktirish" naqshi bu yerda
--    YETARLI EMAS: metadata MAJBURIY, yarim yozilgan sorov bolmasin).
--
-- p_data kalitlari:
--   kassa, modda, summa, izoh, kimdan, ext_ref  — eski imzo bilan bir xil
--   entry_uid      uuid   — chek yuklangan yolning entry id'si
--   chek_bor       bool
--   filial_ids     uuid[] (jsonb massiv)
--   davr_start, davr_end  date (matn)
--   kommunal_turi  text
--   jadval         jsonb  (excel shabloni)
--   maydonlar      jsonb  (massiv)

create or replace function ruxsat_yarat_v2(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_modda  uuid;
  v_talab  jsonb;
  v_euid   uuid;
  v_fil    uuid[] := '{}'::uuid[];
  v_ds     date;
  v_de     date;
  v_komm   text;
  v_jadval jsonb;
  v_mayd   jsonb;
  v_chek   boolean;
  v_res    jsonb;
  v_id     uuid;
  v_yoq    text;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if jsonb_typeof(p_data) is distinct from 'object' then
    raise exception 'Malumot formati notogri' using errcode = '22000';
  end if;

  v_modda := nullif(p_data->>'modda', '')::uuid;
  if v_modda is null then
    raise exception 'Xarajat turi tanlanmagan' using errcode = '22000';
  end if;

  -- ---- 1) Moddaning talablari (YAGONA manba) -------------------------
  v_talab := ruxsat_talab(v_modda);
  if not coalesce((v_talab->>'bor')::boolean, false) then
    raise exception 'Xarajat moddasi topilmadi' using errcode = '22000';
  end if;
  if coalesce((v_talab->>'bloklangan')::boolean, false) then
    raise exception '%', coalesce(v_talab->>'blok_sabab', 'Bu turga ruxsat sorab bolmaydi')
      using errcode = '22000';
  end if;

  -- ---- 2) Maydonlarni o'qish ----------------------------------------
  v_euid   := nullif(p_data->>'entry_uid', '')::uuid;
  v_chek   := coalesce((p_data->>'chek_bor')::boolean, false);
  v_ds     := nullif(p_data->>'davr_start', '')::date;
  v_de     := nullif(p_data->>'davr_end', '')::date;
  v_komm   := nullif(btrim(coalesce(p_data->>'kommunal_turi', '')), '');
  v_jadval := case when jsonb_typeof(p_data->'jadval')    = 'object' then p_data->'jadval'    end;
  v_mayd   := case when jsonb_typeof(p_data->'maydonlar') = 'array'  then p_data->'maydonlar' end;

  if jsonb_typeof(p_data->'filial_ids') = 'array' then
    select coalesce(array_agg(distinct x::uuid), '{}'::uuid[])
      into v_fil
      from jsonb_array_elements_text(p_data->'filial_ids') x
     where nullif(btrim(x), '') is not null;
  end if;

  -- ---- 3) TALABLARNI MAJBURLASH (server qatlami) ---------------------
  -- 🔴 Bu tekshiruvlar UI dagi bilan bir xil, lekin UI dan MUSTAQIL:
  --    yangi klient yozilsa ham teshik ochilmasin.
  if coalesce((v_talab->>'chek')::boolean, false) and not v_chek then
    raise exception 'Bu xarajat uchun chek surati shart' using errcode = '22000';
  end if;
  if coalesce((v_talab->>'excel')::boolean, false) and v_jadval is null then
    raise exception 'Bu xarajat uchun Excel jadvali shart' using errcode = '22000';
  end if;
  if coalesce((v_talab->>'filial')::boolean, false) and coalesce(array_length(v_fil, 1), 0) = 0 then
    raise exception 'Bu xarajat uchun filial tanlanishi shart' using errcode = '22000';
  end if;
  if coalesce((v_talab->>'davr')::boolean, false) and (v_ds is null or v_de is null) then
    raise exception 'Bu xarajat uchun davr sanasi shart' using errcode = '22000';
  end if;
  if v_ds is not null and v_de is not null and v_de < v_ds then
    raise exception 'Davr oxiri boshidan oldin bolmaydi' using errcode = '22000';
  end if;
  if coalesce((v_talab->>'kommunal')::boolean, false) and v_komm is null then
    raise exception 'Kommunal turini tanlang' using errcode = '22000';
  end if;

  -- Maxsus maydonlar: har MAJBURIY maydon uchun bosh bolmagan qiymat kelsin.
  if coalesce((v_talab->>'maydon_req')::boolean, false) then
    select string_agg(m.nom, ', ' order by m.tartib, m.nom)
      into v_yoq
      from xarajat_maydon m
      join xarajat_maydon_modda mm on mm.maydon_id = m.id
     where m.is_active
       and mm.modda_id = v_modda
       and coalesce(mm.required, m.required)
       and not exists (
             select 1 from jsonb_array_elements(coalesce(v_mayd, '[]'::jsonb)) x
              where (x->>'maydon_id')::uuid = m.id
                and (nullif(x->>'element_id', '') is not null
                     or nullif(btrim(coalesce(x->>'qiymat', '')), '') is not null));
    if v_yoq is not null then
      raise exception 'Toldirilmagan majburiy maydon: %', v_yoq using errcode = '22000';
    end if;
  end if;

  -- Jadval hajmi (ruxsat_sorov_jadval_chk bilan bir xil chegara).
  if v_jadval is not null and pg_column_size(v_jadval) > 120000 then
    raise exception 'Jadval hajmi juda katta' using errcode = '22000';
  end if;

  -- entry_uid band bolmasin (chek fayli boshqa yozuvga yopishmasin).
  if v_euid is not null then
    if exists (select 1 from entry where id = v_euid)
       or exists (select 1 from ruxsat_sorov where entry_uid = v_euid) then
      raise exception 'Yozuv kaliti band — sahifani yangilab qayta urining' using errcode = '22000';
    end if;
  end if;

  -- ---- 4) Sorovning ozi — ESKI RPC (qoidalar bir joyda) --------------
  v_res := ruxsat_yarat(
             nullif(p_data->>'kassa', '')::uuid,
             v_modda,
             nullif(p_data->>'summa', '')::numeric,
             p_data->>'izoh',
             nullif(p_data->>'kimdan', '')::uuid,
             nullif(p_data->>'ext_ref', ''));

  if not coalesce((v_res->>'ok')::boolean, false) then
    return v_res;                       -- kod=takror va boshqalar ozgarmasdan qaytadi
  end if;

  v_id := (v_res->>'ruxsat_id')::uuid;

  -- ---- 5) Metadata — AYNI tranzaksiyada ------------------------------
  update ruxsat_sorov
     set entry_uid     = v_euid,
         chek_bor      = v_chek,
         filial_ids    = v_fil,
         davr_start    = v_ds,
         davr_end      = v_de,
         kommunal_turi = v_komm,
         jadval        = v_jadval,
         maydonlar     = v_mayd
   where id = v_id;

  return v_res || jsonb_build_object('v', 2);
end $fn$;

revoke all on function ruxsat_yarat_v2(jsonb) from public, anon;
grant execute on function ruxsat_yarat_v2(jsonb) to authenticated;

comment on function ruxsat_yarat_v2(jsonb) is
  'Ruxsat sorovi + moddaning HAMMA talabi (chek/filial/davr/kommunal/excel/maxsus maydon) '
  'BITTA tranzaksiyada. Eski ruxsat_yarat ni ichidan chaqiradi (qoidalar bir joyda). '
  'Ovqat va spidometr moddalari RAD etiladi — sorov shakli ularni ifodalay olmaydi.';


-- #####################################################################
-- ##  5-BO'LIM — ruxsat_qator(ruxsat_sorov, uuid) — yangi kalitlar    ##
-- #####################################################################
-- 🔴 PROVODKA_JADVAL_2.sql (6-BO'LIM) dagi ENG OXIRGI tananing VERBATIM
--    nusxasi. Yagona farq: oxiridagi metadata kalitlari — tasdiqlovchi
--    chekni va tanlangan filial/davrni KORISHI kerak, aks holda u nimani
--    tasdiqlayotganini bilmaydi.

create or replace function ruxsat_qator(r ruxsat_sorov, p_uid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_modda_kod text;
  v_modda_nom text;
  v_kassa_sub text;
  v_fil_nom   text;
begin
  select a.code, a.name into v_modda_kod, v_modda_nom
    from accounts a where a.id = r.modda_id;

  select nullif(btrim(coalesce(subtitle, '')), '') into v_kassa_sub
    from accounts where id = r.kassa_id;

  -- Filial NOMLARI: tasdiqlovchida filiallar royxati yoq (sorovlar sahifasi uni
  -- yuklamaydi), shuning uchun nom SERVERDA yigiladi — uuid korsatishdan mano yoq.
  select string_agg(a.name, ', ' order by a.name) into v_fil_nom
    from accounts a
   where a.id = any (coalesce(r.filial_ids, '{}'::uuid[]));

  return jsonb_build_object(
    'id',                    r.id,
    'turi',                  'ruxsat',
    'sorovchi_id',           r.hodim_id,
    'sorovchi_nom',          sorov_ism(r.hodim_id, r.kassa_id),
    'sorovchi_sub',          v_kassa_sub,
    'kimdan_id',             r.kimdan_id,
    'kimdan_nom',            sorov_ism(r.kimdan_id, null),
    'summa',                 r.summa,
    'izoh',                  r.izoh,
    'modda_id',              r.modda_id,
    'modda_kod',             v_modda_kod,
    'modda_nom',             v_modda_nom,
    'kassa_id',              r.kassa_id,
    'status',                r.status,
    'qaror_izoh',            r.rad_izoh,
    'qaror_kim',             case when r.decided_by is null then null
                                   else sorov_ism(r.decided_by, null) end,
    'qaror_vaqt',            r.decided_at,
    'sana',                  r.created_at,
    'entry_id',              r.entry_id,
    'meniki',                (r.hodim_id = p_uid),
    -- SERVER hisoblaydi: admin hamma sorovni koradi, lekin faqat OZINING
    -- ROLIDA bolgan moddaga tasdiq bera oladi (6-BOLIM 3-shart bilan bir xil).
    'men_qaror_qila_olaman', (r.status = 'pending'
                              and (r.kimdan_id = p_uid or is_admin())
                              and (is_admin() or rbac_modda_ok(r.modda_id))),
    -- UI "bu modda sizning rolingizda ham yoq" deb tushuntirsin.
    'modda_menda_yoq',       (not (is_admin() or rbac_modda_ok(r.modda_id))),
    -- YANGI (PROVODKA_JADVAL_2.sql): to'liq jadval emas, faqat ozet.
    'jadval_n',              (r.jadval->>'n')::int,
    'jadval_jami',           (r.jadval->>'jami')::numeric,
    -- YANGI (PROVODKA_RUXSAT_TALAB.sql): tasdiqlovchi nimani tasdiqlayotganini korsin.
    'chek_bor',              coalesce(r.chek_bor, false),
    -- Chek yoli: xarajat-cheklari/{kassa_id}/{entry_uid}.jpg (tasdiqdan KEYIN ham
    -- ayni fayl, chunki entry AYNAN shu id bilan yaratiladi).
    'chek_uid',              r.entry_uid,
    'filial_ids',            to_jsonb(coalesce(r.filial_ids, '{}'::uuid[])),
    'filial_nom',            v_fil_nom,
    'davr_start',            r.davr_start,
    'davr_end',              r.davr_end,
    'kommunal_turi',         r.kommunal_turi,
    'maydon_n',              case when jsonb_typeof(r.maydonlar) = 'array'
                                  then jsonb_array_length(r.maydonlar) else 0 end
  );
end $fn$;

revoke all on function ruxsat_qator(ruxsat_sorov, uuid) from public, anon, authenticated;

comment on function ruxsat_qator(ruxsat_sorov, uuid) is
  'ICHKI: bitta ruxsat sorovi qatorining jsonb shakli. Ikkala royxat ham shuni ishlatadi. '
  'YANGI (PROVODKA_RUXSAT_TALAB.sql): chek_bor/chek_uid/filial_ids/filial_nom/davr/kommunal_turi/maydon_n.';


-- #####################################################################
-- ##  6-BO'LIM — ruxsat_tasdiq(uuid) — metadata entry ga ko'chadi      ##
-- #####################################################################
-- 🔴 PROVODKA_JADVAL_2.sql (8-BO'LIM) dagi ENG OXIRGI tananing VERBATIM
--    nusxasi. Farqlar FAQAT shular:
--      a) `entry.id` — imkon bolsa `r.entry_uid` (chek fayli shu id bilan
--         allaqachon yuklangan; kochirish YOQ);
--      b) `filial_ids` endi BOSH EMAS — `r.filial_ids` dan;
--      c) `davr_start`/`davr_end`/`kommunal_turi` kochadi;
--      d) `entry_maydon` qatorlari yoziladi va `xm_majburiy_yoq` bilan
--         fail-closed tekshiriladi.
--
-- ⚠️ ONGLI OZGARISH (2026-09-09): eski izohda "ruxsat sorovida FILIAL
--    tushunchasi yoq, shuning uchun filial-modda OYLIK LIMITI taalluqli
--    emas" deb yozilgan edi. Endi filial tanlanadi — demak `sorov_post_tosiq`
--    limit shoxi bu yozuvga ham ISHLAYDI. Bu ATAYLAB: ruxsat berilgani
--    limitni bekor qilmasligi kerak.

create or replace function ruxsat_tasdiq(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  r       ruxsat_sorov;
  v_modda accounts;
  v_kassa accounts;
  v_entry uuid;
  v_tosiq text;
  v_eid   uuid;      -- klient oldindan bergan id (bosh bolsa null -> yangi uuid)
  v_yoq   text;      -- toldirilmagan majburiy maxsus maydonlar
begin
  perform set_config('lock_timeout', '5s', true);

  -- 1) Auth + sahifa
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('sorovlar') then
    raise exception 'Sorovlar sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  select * into r from ruxsat_sorov where id = p_id for update;
  if not found then
    raise exception 'Sorov topilmadi' using errcode = '22000';
  end if;

  -- 2) Kim tasdiqlaydi
  if r.kimdan_id <> v_uid and not is_admin() then
    raise exception 'Sorovni faqat sorov kelgan odam yoki admin tasdiqlaydi'
      using errcode = '42501';
  end if;

  -- 3) 🔴 TASDIQLOVCHI OZ MODDASINI BERADI: uning ozida yoq ruxsatni
  --    boshqaga bera olmaydi (admin buni chetlab otadi).
  if not is_admin() and not rbac_modda_ok(r.modda_id) then
    raise exception 'Bu modda sizning rolingizda ham yoq — ozingizda yoq ruxsatni bera olmaysiz'
      using errcode = '42501';
  end if;

  -- 4) Ikki marta tasdiqlash/rad — idempotent
  if r.status <> 'pending' then
    return jsonb_build_object('ok', false, 'kod', 'already_decided', 'holat', r.status);
  end if;

  -- 5) Modda va kassa hamon faol/togri turdami
  select * into v_modda from accounts where id = r.modda_id;
  if not found or v_modda.is_active is distinct from true or v_modda.type <> 'xarajat' then
    return jsonb_build_object('ok', false, 'kod', 'hisob_yoq');
  end if;

  select * into v_kassa from accounts where id = r.kassa_id;
  if not found or v_kassa.is_active is distinct from true then
    return jsonb_build_object('ok', false, 'kod', 'hisob_yoq');
  end if;

  -- 6) 🔴 PUL YETADIMI (tasdiqda ham) — so'rov PENDING qoladi, summa/qoldiq
  --    raqami klientga YUBORILMAYDI (balans sizmasin).
  if sorov_kassa_bal(r.kassa_id) < r.summa then
    return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi', 'qoldiq_yetmadi', true);
  end if;

  -- 6b) Chek fayli sorov paytida `{kassa_id}/{entry_uid}.jpg` ga yuklangan —
  --     yozuvni AYNAN shu id bilan yaratamiz, shunda jurnal uni odatdagidek
  --     topadi. Id band bolib qolgan bolsa (deyarli imkonsiz) yangi id
  --     olinadi va javobda `chek_uzildi` bilan ogohlantiramiz.
  if r.entry_uid is not null and not exists (select 1 from entry where id = r.entry_uid) then
    v_eid := r.entry_uid;
  end if;

  -- ---- Xarajat provodkasi: Dt modda / Kt hodim kassa, DARROV posted ----
  insert into entry (id, entry_date, description, source, status, ext_ref, created_by,
                     filial_ids, davr_start, davr_end, kommunal_turi, jadval)
  values (coalesce(v_eid, gen_random_uuid()),
          (now() at time zone 'Asia/Tashkent')::date,
          'Ruxsat bilan: ' || r.izoh,
          'manual',
          'posted',
          'ruxsat:' || r.id::text,
          r.hodim_id,
          coalesce(r.filial_ids, '{}'::uuid[]),
          r.davr_start,
          r.davr_end,
          r.kommunal_turi,
          -- so'rovga biriktirilgan jadval xarajat yozuviga ko'chadi (PROVODKA_JADVAL_2.sql).
          r.jadval)
  returning id into v_entry;

  -- 🔴 TARTIB MUHIM: `entry_line` dan OLDIN `ruxsat_sorov` yangilanadi —
  --    PROVODKA_RUXSAT_SOROV.sql 8-BOLIM dagi guard istisnosi aynan
  --    `entry_id`/`decided_at` bogini qidiradi. Teskari tartibda
  --    tasdiqlash 42501 bilan yiqilardi.
  update ruxsat_sorov
     set status     = 'tasdiq',
         entry_id   = v_entry,
         decided_at = now(),
         decided_by = v_uid
   where id = r.id;

  insert into entry_line (entry_id, account_id, debit, credit)
  values (v_entry, r.modda_id, r.summa, 0),
         (v_entry, r.kassa_id, 0,       r.summa);

  -- ---- Maxsus maydonlar (entry_maydon_yoz bilan bir xil shakl) --------
  -- 🔴 To'g'ridan insert: `entry_maydon_yoz` egalikni (`xm_entry_yoz_ok`)
  --    tekshiradi, bu yerda esa yozuv egasi HODIM, chaqiruvchi esa
  --    TASDIQLOVCHI — RPC uni rad etardi. Qiymatlar allaqachon
  --    `ruxsat_yarat_v2` da tekshirilgan.
  if jsonb_typeof(r.maydonlar) = 'array' then
    insert into entry_maydon (entry_id, maydon_id, element_id, qiymat_matn)
    select v_entry,
           (x->>'maydon_id')::uuid,
           nullif(x->>'element_id', '')::uuid,
           nullif(btrim(coalesce(x->>'qiymat', '')), '')
      from jsonb_array_elements(r.maydonlar) x
     where nullif(x->>'maydon_id', '') is not null
       and (nullif(x->>'element_id', '') is not null
            or nullif(btrim(coalesce(x->>'qiymat', '')), '') is not null)
    on conflict (entry_id, maydon_id) do nothing;
  end if;

  -- Fail-closed: sorovdan keyin ta'rif ozgargan bolsa ham majburiy maydon
  -- toldirilmagan yozuv POSTED bolib qolmasin.
  v_yoq := xm_majburiy_yoq(v_entry);
  if v_yoq is not null then
    raise exception 'Toldirilmagan majburiy maydon: %', v_yoq using errcode = '22000';
  end if;

  -- Modda oylik limiti / kassa qoldigi — sorov_post_tosiq YAGONA predikat.
  v_tosiq := sorov_post_tosiq(v_entry);
  if v_tosiq is not null then
    raise exception 'Limit: %', v_tosiq using errcode = '22000';
  end if;

  if to_regprocedure('public.sorov_notify_post(uuid)') is not null then
    perform sorov_notify_post(v_entry);
  end if;

  return jsonb_build_object('ok', true, 'holat', 'tasdiq', 'entry_id', v_entry,
                            'chek_uzildi', (r.entry_uid is not null and v_eid is null));

exception
  -- Poyga: bir vaqtda ikki chaqiruv qulfdan otib ketsa ham ikkinchi
  -- provodka ext_ref UNIQUE ga urilib qaytadi — xarajat ikki marta yozilmaydi.
  when unique_violation then
    return jsonb_build_object('ok', false, 'kod', 'already_decided', 'holat', 'tasdiq');
end $fn$;

revoke all on function ruxsat_tasdiq(uuid) from public, anon;
grant execute on function ruxsat_tasdiq(uuid) to authenticated;

comment on function ruxsat_tasdiq(uuid) is
  'Ruxsat sorovini tasdiqlaydi: Dt modda / Kt hodim kassa, darrov posted. Pul harakat qilmaydi. '
  'Sorov kelgan odam YOKI admin, VA moddaning ozi tasdiqlovchi rolida bolishi shart. '
  'Idempotent: for update + status tekshiruvi + ext_ref UNIQUE. '
  'YANGI (PROVODKA_RUXSAT_TALAB.sql): entry AYNAN r.entry_uid bilan yaratiladi (chek yoli), '
  'filial_ids/davr/kommunal_turi/jadval/maxsus maydonlar sorovdan kochadi, '
  'xm_majburiy_yoq fail-closed tekshiriladi.';


-- #####################################################################
-- ##  PostgREST sxema keshi                                           ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  7-BO'LIM — YAKUNIY TEKSHIRUV (faqat select)                     ##
-- #####################################################################

select
  (select count(*) from information_schema.columns
    where table_name = 'ruxsat_sorov'
      and column_name in ('entry_uid','filial_ids','davr_start','davr_end',
                          'kommunal_turi','chek_bor','maydonlar'))            as ustun_7,
  to_regprocedure('public.ruxsat_talab(uuid)')          is not null           as fn_ruxsat_talab,
  to_regprocedure('public.ruxsat_yarat_v2(jsonb)')      is not null           as fn_ruxsat_yarat_v2,
  to_regprocedure('public.ruxsat_yarat(uuid,uuid,numeric,text,uuid,text)')
                                                        is not null           as fn_eski_saqlandi,
  to_regprocedure('public.ruxsat_qator(ruxsat_sorov,uuid)') is not null       as fn_ruxsat_qator,
  to_regprocedure('public.ruxsat_tasdiq(uuid)')         is not null           as fn_ruxsat_tasdiq;

-- Kutilgan: ustun_7 = 7, qolgan hammasi t.
--
-- QO'LDA SINOV (dev):
--   1. sozlama-dev da biror YOPIQ moddaga «Chek» + «Excel» yoqing.
--   2. hodim-dev -> Ruxsat so'rash -> o'sha turni tanlang: chek va Excel
--      so'ralishi, ikkalasisiz «So'rov yuborish» yopiq bo'lishi kerak.
--   3. sorovlar-dev da tasdiqlovchi chekni ko'rsin, tasdiqlasin.
--   4. jurnal-dev da yozuv chek belgisi bilan chiqsin (fayl ko'chirilmaydi —
--      u boshidanoq to'g'ri yo'lda turadi).
--   5. Ovqat yoki spidometr moddasini tanlab ko'ring — ro'yxatda «ruxsat
--      so'rab bo'lmaydi» deb chiqishi kerak.
