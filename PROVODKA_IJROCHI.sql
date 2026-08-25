-- =====================================================================
-- PROVODKA — IJROCHI ("kim yozdi") — server qismi
-- ---------------------------------------------------------------------
-- MAQSAD: har provodka yozuvining MUALLIFI ko'rinsin —
--   * Jurnalda alohida ustun ("Ijrochi") + ijrochi bo'yicha FILTR,
--   * filtr dropdowni uchun ro'yxat (kim nechta yozuv yozgan),
--   * bundan keyingi yozuvlarda `entry.created_by` AVTOMAT to'lsin.
--
-- Bu faylda FAQAT SQL. Klient (jurnal-dev.html) keyingi bosqichda.
--
-- =====================================================================
-- 🔴🔴🔴  ENG MUHIM: `entry.created_by` USTUNINING TURI NOMA'LUM  🔴🔴🔴
-- ---------------------------------------------------------------------
-- Repoda IKKALA iz ham bor:
--   PROVODKA_HODIM_V4.sql:129 — `left join profiles pr on pr.id = e.created_by`
--                               (ya'ni UUID deb ishlatadi)
--   PROVODKA_SYNC_DIAG.sql:114 — `e.created_by = 'aros_sync'`
--                               (ya'ni MATN deb ishlatadi)
-- PROVODKA_ISM.sql 7.5 ham buni ochiq yozadi: tur aniqlanmagan.
--
-- 👉 SHUNING UCHUN BU FAYLDAGI HECH BIR KOD USTUN TURIGA BOG'LANMAYDI.
--    Naqsh repoda allaqachon bor va AYNAN o'sha ishlatiladi
--    (PROVODKA_HODIM_NOTIFY.sql:564-570, PROVODKA_EXT_REF.sql:456-467):
--
--      (to_jsonb(e) ->> 'created_by')                    -- MATN sifatida o'qish
--        ~ '^[0-9a-fA-F-]{36}$'                          -- uuid SHAKLINI tekshirish
--        then (to_jsonb(e) ->> 'created_by')::uuid       -- FAQAT shundan keyin cast
--
--    `to_jsonb(...)->>` uch narsani birdan hal qiladi:
--      1) ustun uuid bo'lsa ham, text bo'lsa ham matn qaytadi;
--      2) ustun UMUMAN yo'q bo'lsa ham so'rov yiqilmaydi (null qaytadi);
--      3) buzuq qiymat 22P02 bilan butun RPC ni yiqitmaydi (cast shartli).
--
--    0-BO'LIMdagi diagnostika turni KO'RSATADI, lekin fayldagi hech qanday
--    kod uning natijasiga BOG'LANMAGAN — Asilbek nima chiqishidan qat'i
--    nazar fayl ishlaydi.
-- =====================================================================
--
-- =====================================================================
-- ⚠️⚠️⚠️  IMZO O'ZGARISHI — CLAUDE.md QOIDASINING ONGLI ISTISNOSI  ⚠️⚠️⚠️
-- ---------------------------------------------------------------------
-- CLAUDE.md: "ustun/funksiya o'chirish yoki imzo (argument/tur)
-- o'zgartirish — TAQIQ" (bitta DB, prod frontend sinadi).
--
-- BU FAYLDA UCHTA FUNKSIYA IMZOSI O'ZGARADI:
--     jurnal_v2(...)        + p_ijrochi text  (oxirgi parametr)
--     jurnal_v2_count(...)  + p_ijrochi text
--     jurnal_dash(...)      + p_ijrochi text
-- va ICHKI `jurnal_v2_baza(...)` ning `returns table(...)` ro'yxati
-- kengayadi (+1 ustun: `ijrochi_raw`).
--
-- 🔴 TEZLIK QARORI (QA topilmasi): baza FAQAT XOM kalitni (`ijrochi_raw`)
--    qaytaradi. Ko'rsatiladigan ISM (`ijrochi_nomi()`) endi baza ichida
--    EMAS — u faqat ism HAQIQATAN kerak bo'lgan joyda hisoblanadi:
--      jurnal_v2         → LIMIT/OFFSET dan KEYIN (ya'ni 100 qatorga)
--      jurnal_ijrochilar → GROUP BY dan KEYIN (har guruhga bittadan)
--      jurnal_v2_count / jurnal_dash → UMUMAN chaqirilmaydi (ism javobda yo'q)
--    Filtr esa xom kalitga tayangani uchun xatti-harakat o'zgarmaydi.
--
-- 🔴 NEGA BU XAVFSIZ:
--   `jurnal_v2*` oilasi PROD'da UMUMAN ISHLATILMAYDI. Ularni faqat
--   `jurnal-dev.html` chaqiradi va u hali promote qilinmagan. Prod
--   `jurnal.html` esa ESKI `jurnal()` / `jurnal_count()` ni chaqiradi —
--   ULARGA BU FAYLDA UMUMAN TEGILMAYDI (bitta harf ham).
--
-- 🔴 NEGA `drop function` SHART (oddiy `create or replace` yetmaydi):
--   a) `jurnal_v2_baza` — `returns table(...)` o'zgargani uchun
--      `create or replace` "cannot change return type of existing
--      function" xatosini beradi.
--   b) Ochiq RPC larda yangi parametr `default` bilan qo'shilsa, ESKI
--      imzo bazada QOLADI va PostgREST ikkita mos keluvchi funksiyani
--      ko'rib "Could not choose the best candidate function" (PGRST203)
--      beradi — jurnal-dev butunlay ishlamay qolardi.
--   Shuning uchun ANIQ imzo bo'yicha `drop function if exists` (3.0 band).
-- =====================================================================
--
-- RUN TARTIBI (Asilbek, Supabase SQL editor):
--   0) Old shart (bazada bo'lishi kerak):
--        PROVODKA_JURNAL_V2.sql  → jurnal_v2*, jurnal_page_ok()  (RUN qilingan)
--        PROVODKA_PERMS.sql      → is_admin(), user_perms
--        PROVODKA_ISM.sql        → profiles.full_name  — SHART EMAS
--            (ustun yo'q bo'lsa ham `ijrochi_nomi` yiqilmaydi, 2-BO'LIM izohi)
--   1) Shu faylni BUTUNLIGICHA nusxalab RUN qiling (bo'lib emas).
--      🔴 Butun fayl BITTA tranzaksiyada bajariladi: bitta operator xato
--         bersa HAMMASI orqaga qaytadi. Shuning uchun faylda RPC ni JONLI
--         chaqiradigan tekshiruv YO'Q (editorda `auth.uid()` null →
--         `jurnal_page_ok` 42501 beradi va butun faylni yiqitadi — bugun
--         aynan shu PROVODKA_JURNAL_V2.sql ni yiqitgan edi).
--         Hamma tekshiruv — faqat KATALOG so'rovlari.
--   2) 0-BO'LIM va oxirgi TEKSHIRUV natijalarini ko'rib chiqing.
--   3) Jonli sinov — BRAUZERDA (jurnal-dev.html), SQL editorda emas.
--
-- 🔴 ESKI YOZUVLAR TO'LDIRILMAYDI. Bu faylda birorta `update entry` YO'Q.
--    Hozir ~50 yozuvdan 49 tasida `created_by` bo'sh — ular jurnalda
--    "Noma'lum" bo'lib qoladi va SHUNDAY QOLISHI KERAK: kim yozganini
--    endi taxmin qilib yozib qo'yish — buxgalteriya tarixini soxtalashtirish
--    bo'lardi (PROVODKA_ISM.sql dagi bir xil qaror). Yechim faqat oldinga
--    qaraydi: 1-BO'LIMdagi trigger BUNDAN KEYINGI yozuvlarni to'ldiradi.
--
-- Idempotent — bir necha marta RUN qilish xavfsiz.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — DIAGNOSTIKA (faqat KO'RISH, hech narsani o'zgartirmaydi)
-- #####################################################################
-- ⚠️ Quyidagi natijaga BU FAYLDAGI HECH QANDAY KOD BOG'LANMAGAN.
--    U faqat Asilbek uchun: ustun turi nima, nechta yozuvda to'lgan.
--    Naqsh — PROVODKA_EXT_REF.sql 0.4 bandi.
--
-- Kutilgan javob:
--   created_by_turi : 'uuid' YOKI 'text'/'character varying' — IKKALASI HAM OK
--   uuid_shaklida   : klient yozuvlari (odam yozgan) soni
--   matn_shaklida   : texnik yozuvlar ('aros_sync', 'tovar_sync' …)
--   bosh            : `created_by` to'lmagan yozuvlar — 1-BO'LIM triggeri
--                     RUN qilingandan KEYIN bu son o'smasligi kerak
--                     (eski qatorlar esa shundayligicha qoladi).
-- ---------------------------------------------------------------------

select (select data_type from information_schema.columns
         where table_schema = 'public' and table_name = 'entry'
           and column_name = 'created_by')                                          as created_by_turi,
       count(*)                                                                     as oxirgi_500,
       count(*) filter (where (to_jsonb(e) ->> 'created_by') ~ '^[0-9a-fA-F-]{36}$') as uuid_shaklida,
       count(*) filter (where (to_jsonb(e) ->> 'created_by') is not null
                          and (to_jsonb(e) ->> 'created_by') !~ '^[0-9a-fA-F-]{36}$') as matn_shaklida,
       count(*) filter (where nullif(btrim(coalesce(to_jsonb(e) ->> 'created_by', '')), '') is null) as bosh
  from (select * from entry order by created_at desc limit 500) e;

-- Kim nechta yozuv yozgan (xom qiymat bo'yicha) — trigger ishlayotganini
-- keyinroq shu bilan tekshirish qulay.
select coalesce(nullif(btrim(coalesce(to_jsonb(e) ->> 'created_by', '')), ''), '(bosh)') as created_by_xom,
       count(*)          as yozuvlar,
       min(e.created_at) as birinchi,
       max(e.created_at) as oxirgi
  from entry e
 group by 1
 order by yozuvlar desc
 limit 50;

-- `profiles` da qaysi ustunlar bor (2-BO'LIM email fallback'i uchun muhim:
-- repoda `profiles.email` HECH QAYERDA ishlatilmaydi — email `auth.users` da).
select column_name, data_type
  from information_schema.columns
 where table_schema = 'public' and table_name = 'profiles'
 order by ordinal_position;


-- #####################################################################
-- ##  1-BO'LIM — `created_by` AVTOMAT TO'LSIN (BEFORE INSERT trigger)  ##
-- #####################################################################
-- MUAMMO: yozuvlarning deyarli hammasida `created_by` bo'sh. Klient
-- (`provodka`/`professional`/`hodim`/`jurnal` tahriri) uni yubormaydi,
-- shuning uchun "kim yozdi" ni ko'rsatib bo'lmaydi.
--
-- 🔴 NEGA `alter table entry alter column created_by set default auth.uid()` EMAS
--    (PROVODKA_EXT_REF.sql 1.3 da aynan shu variant taklif qilingan edi,
--     lekin u SHARTLI — "faqat tur uuid bo'lsa"):
--      1) DEFAULT ustun TURIGA bog'liq: text ustunda `auth.uid()` (uuid)
--         default'i cast xatosi beradi — ya'ni faylni RUN qilib bo'lmaydi.
--      2) DEFAULT faqat ustun insert ro'yxatida UMUMAN bo'lmasa ishlaydi.
--         supabase-js esa ko'pincha ustunni OCHIQ `null` bilan yuboradi
--         (obyektda kalit bor, qiymati null) → default umuman qo'llanmaydi.
--    BEFORE INSERT trigger ikkala muammoni ham yechadi.
--
-- 🔴 TURDAN MUSTAQILLIK — `jsonb_populate_record`:
--      new := jsonb_populate_record(new, jsonb_build_object('created_by', auth.uid()::text));
--    U qiymatni USTUN TURIGA qarab o'zi keltiradi (uuid ustunda uuid,
--    text ustunda text). Qolgan ustunlar `new` dan O'ZGARMAY qoladi
--    (jsonb_populate_record ko'rsatilmagan maydonlarni bazadan oladi).
--    Ya'ni `new.created_by := ...` deb TO'G'RIDAN yozilmaydi — u kompilyatsiya
--    paytida turga bog'lanib qolardi.
--
-- 🔴 QAT'IY SHARTLAR (buzma):
--   * `when (new.created_by is null)` — OCHIQ berilgan qiymat TEGILMAYDI.
--     Bazadagi to'g'ridan-to'g'ri insertlar o'z belgisini yozadi va u
--     saqlanishi SHART: 'aros_sync' (PROVODKA_SYNC_BALANS.sql),
--     'tovar_sync' (PROVODKA_TOVAR_KAPITAL.sql), boshlang'ich qoldiq
--     (PROVODKA_BOSHLANGICH_QOLDIQ.sql), hodim kapitali
--     (PROVODKA_HODIM_KAPITAL.sql), konvert/kassa (PROVODKA_KASSA2.sql).
--     Ular diagnostikada `matn_shaklida` bo'lib chiqadi va jurnalda
--     shundayligicha ko'rinadi (2-BO'LIM 2-qoidasi).
--   * `auth.uid()` NULL bo'lsa (n8n / service_role / SQL editor) — TEGMA,
--     null qolsin. ESKI XATTI-HARAKAT AYNAN SAQLANADI: sinxron yozuvlariga
--     soxta muallif yopishtirilmaydi.
--   * `entry` da boshqa BEFORE INSERT trigger bor (`trg_aros_tr_fix_guard`,
--     PROVODKA_TRANSFER_CUTOFF_FIX.sql). TARTIB MUHIM EMAS: bu trigger
--     faqat `created_by` ga yozadi, o'sha guard esa faqat `ext_ref` ni
--     o'qiydi — kesishmaydi. (Postgres bir xil vaqtli triggerlarni NOM
--     bo'yicha alifbo tartibida ishga tushiradi: aros… < entry… .)
--
-- ⚠️ `exception when others` — ATAYLAB: bu trigger PUL YOZUVI yo'lida turadi.
--    "Kim yozdi" — metama'lumot; u tufayli provodka saqlanmay qolishi
--    mumkin emas. Xato bo'lsa ogohlantirish loglanadi va yozuv `created_by`
--    siz o'tadi (hodim_notify triggerlaridagi bir xil qaror).
--    ⚠️ Bu "xatoni jimgina yutish" EMAS: `raise warning` server logida qoladi.
-- ---------------------------------------------------------------------

create or replace function entry_ijrochi_set()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  -- Ikkinchi qavat: trigger WHEN sharti allaqachon tekshiradi, lekin
  -- funksiya WHEN'siz ham to'g'ri ishlashi kerak (kelajakda qayta ulansa).
  if (to_jsonb(new) ->> 'created_by') is null and auth.uid() is not null then
    new := jsonb_populate_record(new, jsonb_build_object('created_by', auth.uid()::text));
  end if;
  return new;
exception when others then
  -- Pul yozuvi metama'lumot uchun to'xtab qolmasin.
  raise warning 'entry_ijrochi_set: %', sqlerrm;
  return new;
end $fn$;

comment on function entry_ijrochi_set() is
  'entry BEFORE INSERT: created_by bosh bolsa auth.uid() yoziladi (jsonb_populate_record — ustun turiga bogliq emas). '
  'Ochiq berilgan qiymat (aros_sync, tovar_sync …) va auth.uid() null holati TEGILMAYDI.';

drop trigger if exists trg_entry_ijrochi on entry;
create trigger trg_entry_ijrochi
  before insert on entry
  for each row
  when (new.created_by is null)          -- 🔴 ochiq berilgan qiymat tegilmasin
  execute function entry_ijrochi_set();

-- ✅ QANDAY TEKSHIRISH (RUN'dan keyin, brauzerda):
--   1) jurnal-dev / provodka-dev orqali BITTA sinov yozuvi kiriting;
--   2) 0-BO'LIMdagi birinchi diagnostikani qayta RUN qiling —
--      `uuid_shaklida` bittaga oshgan, `bosh` OSHMAGAN bo'lishi kerak;
--   3) `bosh` baribir oshgan bo'lsa: Supabase → Logs → Postgres da
--      `entry_ijrochi_set: …` ogohlantirishini qidiring (funksiya xatoni
--      yutmaydi, warning bo'lib logga tushadi) va menga ko'rsating.


-- #####################################################################
-- ##  2-BO'LIM — ijrochi_nomi(text): ko'rsatiladigan ism             ##
-- #####################################################################
-- Kirish — `created_by` ning MATN ko'rinishi (`to_jsonb(e)->>'created_by'`).
--
-- MANTIQ (tartib muhim):
--   1) bo'sh / null            → 'Noma'lum'
--   2) uuid SHAKLIDA EMAS      → matnning O'ZI ('aros_sync', 'tovar_sync' …).
--                                Texnik belgilar shundayligicha ko'rinsin —
--                                ular odam emas, ularni "Noma'lum" ga
--                                aylantirish ma'lumot YO'QOTISH bo'lardi.
--   3) uuid shaklida           → profiles.full_name (bo'sh bo'lmasa)
--                                → bo'sh bo'lsa email fallback (pastga qara)
--                                → profiles da qator yo'q bo'lsa 'Noma'lum'
--
-- 🔴 MAXFIYLIK — EMAIL FALLBACK'i CHEKLANGAN:
--    Jurnal cheklangan foydalanuvchilarga ham ochiq. To'liq email
--    ko'rsatilsa har kassir butun kompaniyaning gmail ro'yxatini yig'ib
--    olardi. Shuning uchun:
--      is_admin()      → TO'LIQ email  (asilbek@gmail.com)
--      qolgan hamma    → faqat '@' gacha (asilbek)
--    ⚠️ `is_admin()` DINAMIK chaqiriladi (to_regprocedure) va xato/yo'qlik
--       holatida `false` — ya'ni FAIL-CLOSED (email to'liq ko'rinmaydi).
--
-- 🔴 `full_name_or_email(uuid)` GA BOG'LANMAYDI (PROVODKA_ISM.sql 6-BO'LIM).
--    Sabab AYNAN PROVODKA_HODIM_NOTIFY.sql:554 dagi qaror:
--      "🔴 `full_name_or_email()` ga BOG'LANMAYDI: PROVODKA_ISM.sql RUN
--       qilinmagan bazada butun RPC 42883 bilan yiqilardi."
--    Qo'shimcha sabab: u maxfiylik farqini bilmaydi (har doim to'liq email
--    qaytaradi) va unda 'Noma'lum' emas, bo'sh matn qaytadi.
--    Bog'liqlik NOL — mantiq shu yerda o'zi yozilgan.
--
-- ⚠️ `profiles` DA EMAIL USTUNI BORMI — TEKSHIRILDI: repoda
--    `profiles.email` HECH QAYERDA ishlatilmaydi, email `auth.users` da
--    (PROVODKA_ISM.sql 6-BO'LIM va 7.2 shundan o'qiydi). Shuning uchun:
--      a) profiles dan email `to_jsonb(p) ->> 'email'` bilan olinadi —
--         ustun BO'LSA ishlatiladi, YO'Q BO'LSA jimgina null (so'rov
--         yiqilmaydi, `information_schema` ga qarash ham shart emas);
--      b) topilmasa `auth.users` dan olinadi, u ham `begin/exception`
--         ichida — auth sxemasi o'qilmasa funksiya XATO BERMAYDI.
--    Ya'ni funksiya `profiles.full_name` yo'q bazada ham, `auth.users`
--    yopiq bazada ham ishlayveradi (PROVODKA_JURNAL_V2.sql:338 dagi
--    "funksiya/ustun yo'q bazada ham fayl ishlasin" naqshi).
--
-- ⚠️ TEZLIK — IKKI QAVAT (QA topilmasi bo'yicha):
--   1) CHAQIRUVLAR SONI CHEKLANGAN. Funksiya `jurnal_v2_baza` ICHIDA
--      hisoblanMAYDI (avval shunday edi — davrdagi HAMMA yozuv uchun,
--      hatto ism umuman qaytmaydigan `jurnal_v2_count`/`jurnal_dash` da
--      ham). Endi faqat: `jurnal_v2` da LIMIT dan KEYIN (≤ p_limit marta)
--      va `jurnal_ijrochilar` da GROUP BY dan KEYIN (guruhlar soni marta).
--      ⚠️ `stable` bu ishni QILMAYDI: Postgres STABLE funksiya natijasini
--      qatorlar bo'ylab keshlamaydi — chegara so'rovning O'ZIDA bo'lishi kerak.
--   2) TANASI ARZON: eng arzon yo'l birinchi — `profiles` dan PK bo'yicha
--      BITTA select (plan sessiyada keshlanadi), `full_name` to'lgan bo'lsa
--      darrov return: `is_admin()` va `auth.users` GA UMUMAN BORILMAYDI.
--      Ya'ni ismi kiritilgan foydalanuvchida qo'shimcha xarajat = 1 indeks o'qishi.
-- ---------------------------------------------------------------------

create or replace function ijrochi_nomi(p_raw text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_txt   text;
  v_uid   uuid;
  v_name  text;
  v_mail  text;
  v_admin boolean := false;
  v_bor   boolean;
begin
  -- 1) bo'sh
  v_txt := nullif(btrim(coalesce(p_raw, '')), '');
  if v_txt is null then
    return 'Noma''lum';
  end if;

  -- 2) uuid shaklida emas → texnik belgi, o'zi qaytadi
  if v_txt !~ '^[0-9a-fA-F-]{36}$' then
    return v_txt;
  end if;

  -- Shakl to'g'ri, lekin baribir cast'ni himoyalaymiz: '------…' ham
  -- 36 belgi va yuqoridagi regexdan o'tadi, `::uuid` esa 22P02 beradi.
  begin
    v_uid := v_txt::uuid;
  exception when others then
    return v_txt;
  end;

  -- 🔴 Shaxsiy ma'lumot faqat kirgan foydalanuvchiga. `auth.uid()` null
  --    bo'lsa (anon / service_role / SQL editor) ism BERILMAYDI.
  --    Jurnal RPC'lari baribir `jurnal_page_ok()` bilan `auth.uid()` talab
  --    qiladi, ya'ni bu qator normal ishga xalaqit qilmaydi.
  if auth.uid() is null then
    return 'Noma''lum';
  end if;

  -- 3) profiles: full_name + (bo'lsa) email — USTUNGA BOG'LANMASDAN
  select nullif(btrim(coalesce(to_jsonb(p) ->> 'full_name', '')), ''),
         nullif(btrim(coalesce(to_jsonb(p) ->> 'email',     '')), ''),
         true
    into v_name, v_mail, v_bor
    from profiles p
   where p.id = v_uid;

  if not coalesce(v_bor, false) then
    return 'Noma''lum';                     -- profiles da qator yo'q
  end if;

  if v_name is not null then
    return v_name;                          -- eng keng tarqalgan yo'l
  end if;

  -- Email fallback: profiles da yo'q bo'lsa auth.users dan.
  if v_mail is null then
    begin
      select nullif(btrim(coalesce(u.email, '')), '') into v_mail
        from auth.users u where u.id = v_uid;
    exception when others then
      v_mail := null;                       -- auth sxemasi o'qilmadi — mayli
    end;
  end if;

  if v_mail is null then
    return 'Noma''lum';
  end if;

  -- 🔴 MAXFIYLIK: to'liq email faqat adminga. Dinamik + fail-closed.
  begin
    if to_regprocedure('public.is_admin()') is not null then
      execute 'select public.is_admin()' into v_admin;
    end if;
  exception when others then
    v_admin := false;
  end;

  if coalesce(v_admin, false) then
    return v_mail;
  end if;

  -- '@' gacha bo'lgan qism (masalan 'asilbek')
  return split_part(v_mail, '@', 1);
end $fn$;

-- 🔴 GRANT ATAYLAB YO'Q (PROVODKA_ISM.sql:360-365 dagi AYNAN shu qaror).
--    Funksiya `security definer` va `profiles` / `auth.users` dan RLS ni
--    chetlab o'qiydi, ichida esa SAHIFA QOROVULI YO'Q. `authenticated` ga
--    berilsa PostgREST uni ochiq RPC qilib qo'yardi va HAR foydalanuvchi
--    (jumladan `allowed_pages = {}` bo'lgan, jurnalga umuman kira olmaydigan
--    hodim) uuid bo'yicha begona odamning ismini/emailini yig'ib chiqarardi:
--      GET /rest/v1/entry?select=created_by   -> uuid ro'yxati
--      GET /rest/v1/rpc/ijrochi_nomi?p_raw=…  -> ism
--    Grant SHART EMAS: funksiya faqat `jurnal_v2_baza` ICHIDAN chaqiriladi,
--    u esa `security definer` — EXECUTE huquqi egalik orqali ta'minlanadi.
revoke all on function ijrochi_nomi(text) from public, anon, authenticated;

comment on function ijrochi_nomi(text) is
  'Korsatish uchun ijrochi ismi. Kirish — entry.created_by ning MATN korinishi (ustun turiga bogliq emas). '
  'bosh -> Nomalum; uuid shaklida EMAS -> matnning ozi (aros_sync…); uuid -> profiles.full_name, '
  'u bosh bolsa email (ADMIN uchun toliq, boshqalarga faqat @ gacha). profiles da qator yoq -> Nomalum. '
  'full_name_or_email() ga ATAYLAB boglanmagan (PROVODKA_ISM.sql RUN qilinmagan bazada ham ishlasin).';


-- #####################################################################
-- ##  3-BO'LIM — jurnal_v2* ga IJROCHI (ustun + filtr)                ##
-- #####################################################################
-- Mavjud `PROVODKA_JURNAL_V2.sql` O'ZGARTIRILMAYDI — shu yerda ustiga
-- qayta yoziladi (fayl tarixi buzilmasin).
--
-- 🔴 `p_ijrochi` — ANIQ MOSLIK, XOM QIYMAT bo'yicha (`ijrochi_raw`), ISMGA
--    EMAS. Sabab: ism o'zgaradi (admin `full_name` ni tahrirlaydi) va ikki
--    xodimning ismi bir xil bo'lishi mumkin — filtr esa barqaror bo'lishi
--    shart.
--
-- 🔴 SENTINEL `'(bosh)'` — `created_by` bo'sh yozuvlar (hozir ularning
--    99% i) ham filtrlanishi kerak, lekin `ijrochi_raw = null` ni SQL
--    tenglik bilan tanlab bo'lmaydi. Kontrakt oddiy:
--      `jurnal_ijrochilar()` nima qaytarsa, klient SHUNI qaytarib yuboradi.
--    Ro'yxatda bo'sh guruh `ijrochi_raw = '(bosh)'` bo'lib keladi,
--    filtrda ham `p_ijrochi = '(bosh)'` → `created_by is null`.
--    (Naqsh repoda bor: PROVODKA_SYNC_DIAG.sql:169 `coalesce(created_by,'(bo''sh)')`.)
--    ⚠️ To'qnashuv xavfi yo'q: haqiqiy `created_by` qiymatlari — uuid yoki
--    '..._sync' shaklidagi texnik belgilar.
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- 3.0  ESKI IMZOLARNI OLIB TASHLASH — 🔴 ENDI HAR CREATE BILAN BIRGA
--      2026-08-25: drop'lar shu yerda BITTA blokda turardi va faylni
--      bo'lib RUN qilganda o'tkazib yuborilib 42P13 (cannot change return
--      type) berardi. Endi har drop O'Z create'ining ustida — ajratib
--      bo'lmaydi. Bu yerda faqat izoh qoldi.
--      🔴 `cascade` ISHLATILMAYDI — plpgsql tanasidagi chaqiruv katalog
--         bog'liqligi emas, shuning uchun oddiy drop yetadi va tasodifan
--         boshqa obyekt o'chib ketmaydi.
--      ⚠️ Bu operatorlar `jurnal()` / `jurnal_count()` ga TEGMAYDI.
-- ---------------------------------------------------------------------



-- ---------------------------------------------------------------------
-- 3.1  jurnal_v2_baza() — ICHKI. AYNAN PROVODKA_JURNAL_V2.sql dagi tana,
--      YAGONA farq: `returns table(...)` OXIRIGA BITTA ustun qo'shildi:
--        ijrochi_raw text  — xom `created_by` (MATN ko'rinishida, nullable)
--      Qolgan ustunlar, ularning TARTIBI, filtrlar, ruxsat mantiqi va
--      `begona` bayrog'i O'ZGARMAGAN (izohlar ham asl faylda qoldi —
--      bu yerda takrorlanmaydi, faqat qisqartirilgan holda).
--
--      🔴 RUXSAT (fail-closed) va 🔴 `is_deleted` filtri YO'Qligi —
--         asl fayldagidek. O'zgartirilmasin.
--
--      🔴 KO'RSATILADIGAN ISM (`ijrochi`) BU YERDA HISOBLANMAYDI (QA topilmasi).
--         Sabab: baza — uchala RPC ning umumiy manbasi, ya'ni ustun bo'lsa
--         ism DAVRDAGI HAMMA yozuv uchun hisoblanardi, hatto `jurnal_v2_count`
--         (faqat `count(*)`) va `jurnal_dash` (javobda ism umuman yo'q)
--         chaqiruvlarida ham. Har chaqiruv = regex + `::uuid` + `auth.uid()`
--         (JWT claims parsing) + `profiles` PK o'qishi.
--         Endi baza faqat XOM kalitni beradi, ism esa chaqiruvchida:
--           jurnal_v2         → LIMIT dan KEYIN
--           jurnal_ijrochilar → GROUP BY dan KEYIN
--         🔴 FILTR BUNDAN TA'SIRLANMAYDI: `p_ijrochi` xom kalitga tayanadi
--         (uchala RPC dagi 3-shoxli `(bosh)` predikati o'zgarmadi).
-- ---------------------------------------------------------------------

-- 🔴 DROP shu CREATE bilan AJRALMAS: imzo (returns table) o'zgargani uchun
--    `create or replace` yolg'iz 42P13 beradi. Faylni bo'lib RUN qilsangiz ham
--    bu ikki qator BIRGA ketadi — drop o'tkazib yuborilishi mumkin emas.
drop function if exists public.jurnal_v2_baza(date, date, uuid[], uuid[], text[], text);
create or replace function jurnal_v2_baza(
  p_from     date,
  p_to       date,
  p_accounts uuid[],
  p_moddalar uuid[],
  p_turlar   text[],
  p_q        text)
returns table(
  id uuid, entry_date date, created_at timestamptz, description text,
  source text, is_deleted boolean, deleted_by_name text, deleted_at timestamptz,
  edited_at timestamptz, edited_by_name text,
  n_lines int, summa numeric, tur text,
  begona boolean,
  ijrochi_raw text          -- 🔴 faqat XOM kalit; ism chaqiruvchida (yuqoridagi izoh)
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_perm     uuid[] := perm_view_pul_ids();   -- null = cheklovsiz, '{}' = hech narsa
  v_moddalar uuid[];
  v_q        text;
begin
  -- ⚠️ TUZOQ — bo'sh massiv MA'NOSI bu funksiyada BIR XIL EMAS:
  --   p_moddalar = '{}' → "filtr yo'q";  p_accounts / p_turlar = '{}' → HECH NARSA.
  if p_moddalar is null or array_length(p_moddalar, 1) is null then
    v_moddalar := null;
  else
    v_moddalar := p_moddalar;
  end if;

  -- Qidiruv: LIKE metabelgilari tozalanadi.
  if p_q is null or btrim(p_q) = '' then
    v_q := null;
  else
    v_q := '%' || replace(replace(replace(btrim(p_q), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  return query
  with e as (
    select en.id                as e_id,
           en.entry_date        as e_date,
           en.created_at        as e_created,
           en.description       as e_desc,
           en.source            as e_source,
           en.is_deleted        as e_del,
           en.deleted_by_name   as e_delby,
           en.deleted_at        as e_delat,
           en.edited_at         as e_edat,
           en.edited_by_name    as e_edby,
           -- 🔴 IJROCHI — XOM QIYMAT, USTUN TURIGA BOG'LANMAGAN HOLDA.
           --    `to_jsonb(en) ->> 'created_by'`: uuid ustunda ham, text
           --    ustunda ham matn qaytadi; ustun umuman yo'q bo'lsa null
           --    (so'rov yiqilmaydi). Cast QILINMAYDI — uni 2-BO'LIMdagi ism
           --    funksiyasi shartli bajaradi (PROVODKA_HODIM_NOTIFY.sql:564-570 naqshi).
           nullif(btrim(coalesce(to_jsonb(en) ->> 'created_by', '')), '') as e_by,
           -- 🔴 ARALASH YOZUV BAYROG'I (fail-closed agregat uchun) — asl
           --    fayldagidek. Shart perm_view_pul_ids() bilan AYNAN bir xil
           --    bo'lishi SHART (type='aktiv' + code like '5%' + xarajat_guruh emas).
           (v_perm is not null and exists (
              select 1 from entry_line el join accounts ab on ab.id = el.account_id
               where el.entry_id = en.id
                 and ab.type = 'aktiv' and ab.code like '5%'
                 and ab.kassa_turi is distinct from 'xarajat_guruh'
                 and not (el.account_id = any(v_perm)))) as e_begona
      from entry en
     where en.status = 'posted'
       -- 🔴 is_deleted filtri ATAYLAB YO'Q (jurnal o'chirilganini ham ko'rsatadi)
       and en.entry_date >= p_from and en.entry_date <= p_to
       and (p_accounts is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(p_accounts)))
       and (v_moddalar is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(v_moddalar)
                and el.debit > 0))
       -- 🔴 RUXSAT (server tomonda, klient filtridan MUSTAQIL)
       and (v_perm is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(v_perm)))
       and (v_q is null or en.description ilike v_q escape '\')
  ),
  c as (
    select e.*,
           (select count(*)::int from entry_line l where l.entry_id = e.e_id) as n,
           (select coalesce(sum(l.debit), 0)::numeric from entry_line l where l.entry_id = e.e_id) as s,
           d.sec as dt_sec, d.typ as dt_type,
           k.sec as kt_sec, k.typ as kt_type
      from e
      left join lateral (
        select a.section as sec, a.type as typ
          from entry_line l join accounts a on a.id = l.account_id
         where l.entry_id = e.e_id and l.debit > 0
         order by l.debit desc limit 1) d on true
      left join lateral (
        select a.section as sec, a.type as typ
          from entry_line l join accounts a on a.id = l.account_id
         where l.entry_id = e.e_id and l.credit > 0
         order by l.credit desc limit 1) k on true
  ),
  t as (
    select c.*,
           case
             when c.n > 2                                    then 'boshqa'
             when c.dt_sec = 'pul' and c.kt_sec = 'pul'      then 'transfer'
             when c.dt_sec = 'pul' and c.kt_type = 'daromad' then 'tushum'
             when c.dt_sec = 'pul'                           then 'kirim'
             when c.kt_sec = 'pul' and c.dt_type = 'xarajat' then 'xarajat'
             when c.kt_sec = 'pul'                           then 'chiqim'
             else 'boshqa'
           end as tt
      from c
  )
  -- ⚠️ Aniq cast: entry ustunlari varchar bo'lsa ham "structure of query does
  -- not match function result type" xatosi chiqmasin.
  select t.e_id::uuid, t.e_date::date, t.e_created::timestamptz, t.e_desc::text,
         t.e_source::text, t.e_del::boolean, t.e_delby::text, t.e_delat::timestamptz,
         t.e_edat::timestamptz, t.e_edby::text,
         t.n::int, t.s::numeric, t.tt::text, t.e_begona::boolean,
         -- 🔴 XOM kalit. Ism funksiyasi SHU YERDA CHAQIRILMAYDI (3.1 tezlik izohi):
         -- u chaqiruvchida — jurnal_v2 da LIMIT dan keyin, royxatda group by dan keyin.
         t.e_by::text
    from t
   where p_turlar is null or t.tt = any(p_turlar);
end $fn$;

revoke all on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text) from public, anon, authenticated;

comment on function jurnal_v2_baza(date, date, uuid[], uuid[], text[], text) is
  'ICHKI: jurnal v2 uchun filtrlangan yozuvlar + tur tasnifi + IJROCHI XOM KALITI (ijrochi_raw). '
  'Korsatiladigan ism ATAYLAB bu yerda hisoblanmaydi (tezlik): jurnal_v2 uni LIMIT dan keyin, '
  'jurnal_ijrochilar group by dan keyin hisoblaydi; count/dash umuman hisoblamaydi. '
  'Ruxsat shu yerda majburlanadi. Faqat jurnal_v2* wrapperlari chaqiradi.';


-- ---------------------------------------------------------------------
-- 3.2  jurnal_v2() — ro'yxat. YANGI: p_ijrochi (OXIRGI parametr) va
--      javob elementiga `ijrochi` / `ijrochi_raw` kalitlari.
--      Qolgan hamma narsa (element shakli, `lines`, tartib, qorovul)
--      O'ZGARMAGAN — klient render kodi sinmaydi.
--
-- 🔴 ISM QAYERDA HISOBLANADI (QA topilmasi, tezlik):
--    So'rov IKKI qavat: ichki `p` — filtr + tartib + LIMIT/OFFSET
--    (`ijrochi_raw` xom kalit bilan), tashqi `r` — o'sha ≤100 qatorga
--    `ijrochi_nomi(p.ijrochi_raw)`.
--    ⚠️ NEGA BU HAQIQATAN KAMAYTIRADI: LIMIT/OFFSET bo'lgan pastki so'rov
--    Postgres uchun "flatten" qilinmaydigan to'siq — tashqi select ro'yxati
--    Limit tugunidan KEYIN, ya'ni faqat QAYTGAN qatorlarga hisoblanadi.
--    (Agar `ijrochi_nomi` ichki qavatda qolsa, u proyeksiya paytida —
--    sort/limit dan OLDIN — davrdagi hamma qator uchun chaqirilardi.)
--    ⚠️ `jsonb_agg(... order by r.…)` va `to_jsonb(r)` kalitlari O'ZGARMADI:
--    jsonb kalitlari baribir tartiblanib saqlanadi, ya'ni klient uchun
--    javob BAYT-MA-BAYT avvalgidek.
--    ℹ️ `lines` pastki so'rovi ATAYLAB ichki qavatda qoldirildi — u
--    PROVODKA_JURNAL_V2.sql dagi asl joyida turibdi; uni ko'chirish alohida
--    (kattaroq) optimizatsiya, bu topshiriq doirasidan tashqarida.
-- ---------------------------------------------------------------------

-- 🔴 DROP shu CREATE bilan AJRALMAS: imzo (returns table) o'zgargani uchun
--    `create or replace` yolg'iz 42P13 beradi. Faylni bo'lib RUN qilsangiz ham
--    bu ikki qator BIRGA ketadi — drop o'tkazib yuborilishi mumkin emas.
drop function if exists public.jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int);
create or replace function jurnal_v2(
  p_from     date,
  p_to       date,
  p_accounts uuid[] default null,
  p_moddalar uuid[] default null,
  p_turlar   text[] default null,
  p_q        text   default null,
  p_limit    int    default 100,
  p_offset   int    default 0,
  p_ijrochi  text   default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_out jsonb;
  v_ij  text := nullif(btrim(coalesce(p_ijrochi, '')), '');
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  -- 🔴 SAHIFA QOROVULI: kassa ruxsati YETARLI EMAS (kassa_scope sukuti 'all').
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.entry_date desc, r.created_at desc, r.id desc), '[]'::jsonb)
    into v_out
    from (
      -- TASHQI qavat: ism FAQAT shu yerda — LIMIT/OFFSET allaqachon qo'llangan,
      -- ya'ni `ijrochi_nomi()` ko'pi bilan `p_limit` marta chaqiriladi.
      select p.*,
             ijrochi_nomi(p.ijrochi_raw) as ijrochi
        from (
          -- ICHKI qavat: filtr + tartib + sahifalash. Faqat XOM kalit.
          select b.id, b.entry_date, b.description, b.source,
                 b.is_deleted, b.deleted_by_name, b.deleted_at,
                 b.edited_at, b.edited_by_name, b.created_at,
                 -- YANGI kalit (qo'shilishi eski klientni sindirmaydi)
                 b.ijrochi_raw,
                 (select coalesce(jsonb_agg(jsonb_build_object(
                           'id',         l.id,
                           'account_id', l.account_id,
                           'code',       a.code,
                           'name',       a.name,
                           'section',    a.section,
                           'currency',   a.currency,
                           'debit',      l.debit,
                           'credit',     l.credit,
                           'fc_amount',  l.fc_amount) order by l.debit desc), '[]'::jsonb)
                    from entry_line l join accounts a on a.id = l.account_id
                   where l.entry_id = b.id) as lines
            from jurnal_v2_baza(p_from, p_to, p_accounts, p_moddalar, p_turlar, p_q) b
            -- 🔴 IJROCHI FILTRI — xom qiymat bo'yicha aniq moslik, '(bosh)' sentinel
           where v_ij is null
              or (v_ij = '(bosh)' and b.ijrochi_raw is null)
              or b.ijrochi_raw = v_ij
           order by b.entry_date desc, b.created_at desc, b.id desc
           limit  greatest(coalesce(p_limit, 100), 1)
           offset greatest(coalesce(p_offset, 0), 0)
        ) p
    ) r;

  return v_out;
end $fn$;

revoke all on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text) from public, anon;
grant execute on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text) to authenticated;

comment on function jurnal_v2(date, date, uuid[], uuid[], text[], text, int, int, text) is
  'Jurnal v2 royxati: sana + hisob + xarajat moddasi + tur + qidiruv + IJROCHI (hammasi AND, serverda). '
  'Javob shakli eski jurnal() bilan bir xil + ijrochi/ijrochi_raw kalitlari; lines har doim toliq (Dt birinchi). '
  'p_ijrochi — XOM created_by boyicha aniq moslik (ismga emas), ''(bosh)'' = created_by yoq yozuvlar. '
  'TEZLIK: ijrochi_nomi() LIMIT/OFFSET dan KEYIN chaqiriladi (kopi bilan p_limit marta). '
  'Sahifa qorovuli: jurnal_page_ok(''jurnal'') — ruxsat yoq bolsa 42501. Tartib: entry_date desc, created_at desc, id desc.';


-- ---------------------------------------------------------------------
-- 3.3  jurnal_v2_count() — YANGI: p_ijrochi (OXIRGI parametr).
--      Filtr ro'yxat bilan AYNAN bir xil bo'lishi SHART, aks holda
--      "N tadan M ta" sanoq chalkashadi.
-- ---------------------------------------------------------------------

-- 🔴 DROP shu CREATE bilan AJRALMAS: imzo (returns table) o'zgargani uchun
--    `create or replace` yolg'iz 42P13 beradi. Faylni bo'lib RUN qilsangiz ham
--    bu ikki qator BIRGA ketadi — drop o'tkazib yuborilishi mumkin emas.
drop function if exists public.jurnal_v2_count(date, date, uuid[], uuid[], text[], text);
create or replace function jurnal_v2_count(
  p_from     date,
  p_to       date,
  p_accounts uuid[] default null,
  p_moddalar uuid[] default null,
  p_turlar   text[] default null,
  p_q        text   default null,
  p_ijrochi  text   default null)
returns int
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_n  int;
  v_ij text := nullif(btrim(coalesce(p_ijrochi, '')), '');
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  -- 🔴 SAHIFA QOROVULI: kassa ruxsati YETARLI EMAS (kassa_scope sukuti 'all').
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  select count(*)::int into v_n
    from jurnal_v2_baza(p_from, p_to, p_accounts, p_moddalar, p_turlar, p_q) b
   where v_ij is null
      or (v_ij = '(bosh)' and b.ijrochi_raw is null)
      or b.ijrochi_raw = v_ij;

  return coalesce(v_n, 0);
end $fn$;

revoke all on function jurnal_v2_count(date, date, uuid[], uuid[], text[], text, text) from public, anon;
grant execute on function jurnal_v2_count(date, date, uuid[], uuid[], text[], text, text) to authenticated;

comment on function jurnal_v2_count(date, date, uuid[], uuid[], text[], text, text) is
  'Jurnal v2: filtrga tushgan yozuvlar soni (sahifalash uchun). Filtr/ruxsat royxat bilan bir xil '
  '(p_ijrochi ham), sahifa qorovuli ham (42501). '
  'TEZLIK: javobda ism yoq — ijrochi_nomi() UMUMAN chaqirilmaydi (filtr xom kalitga tayanadi).';


-- ---------------------------------------------------------------------
-- 3.4  jurnal_dash() — YANGI: p_ijrochi (OXIRGI parametr).
--      🔴 `p_turlar` E'TIBORGA OLINMAYDI (asl fayldagi QAROR — dashboard
--         DAVR XULOSASI, tur esa ro'yxat ko'rinishi tugmasi). Bu saqlanadi.
--      ⚠️ `p_ijrochi` esa AYNAN E'TIBORGA OLINADI: "kim yozgan" — xulosaning
--         o'zi (bitta odamning davr xulosasi), ro'yxat ko'rinishi emas.
--         Ya'ni ijrochi tanlansa dashboard ham o'sha odamniki bo'ladi.
--      Invariant shunga mos ravishda p_ijrochi BILAN o'qiladi:
--        jami.soni + chetlangan.soni + chetlangan.ochirilgan
--          = jurnal_v2_count(p_from, p_to, p_accounts, p_moddalar, NULL, p_q, p_ijrochi)
-- ---------------------------------------------------------------------

-- 🔴 DROP shu CREATE bilan AJRALMAS: imzo (returns table) o'zgargani uchun
--    `create or replace` yolg'iz 42P13 beradi. Faylni bo'lib RUN qilsangiz ham
--    bu ikki qator BIRGA ketadi — drop o'tkazib yuborilishi mumkin emas.
drop function if exists public.jurnal_dash(date, date, uuid[], uuid[], text[], text);
create or replace function jurnal_dash(
  p_from     date,
  p_to       date,
  p_accounts uuid[] default null,
  p_moddalar uuid[] default null,
  p_turlar   text[] default null,
  p_q        text   default null,
  p_ijrochi  text   default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_out jsonb;
  v_ij  text := nullif(btrim(coalesce(p_ijrochi, '')), '');
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  -- 🔴 SAHIFA QOROVULI: kassa ruxsati YETARLI EMAS (kassa_scope sukuti 'all').
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  with b as materialized (
    -- 🔴 p_turlar ATAYLAB null (dashboard davr xulosasi — asl fayldagi qaror).
    --    p_ijrochi esa QO'LLANADI (yuqoridagi izoh).
    select * from jurnal_v2_baza(p_from, p_to, p_accounts, p_moddalar, null, p_q) z
     where v_ij is null
        or (v_ij = '(bosh)' and z.ijrochi_raw is null)
        or z.ijrochi_raw = v_ij
  ),
  -- 🔴 AGREGAT MANBASI — FAIL-CLOSED, IKKI chetlash (asl fayldagidek):
  --   1) o'chirilgan yozuv;  2) aralash ko'p satrli (begona and n_lines > 2).
  bs as (select * from b
          where coalesce(b.is_deleted, false) = false
            and not (b.begona and b.n_lines > 2)),
  j as (
    select count(*)::int as soni, coalesce(sum(bs.summa), 0)::numeric as summa from bs
  ),
  ch as (     -- chetlanganlar (bitta yozuv ikkala sababga tushsa faqat `ochirilgan` da)
    select (count(*) filter (where coalesce(b.is_deleted, false) = false
                               and b.begona and b.n_lines > 2))::int as soni,
           (count(*) filter (where coalesce(b.is_deleted, false)))::int as ochirilgan
      from b
  ),
  t as (
    select bs.tur, count(*)::int as soni, coalesce(sum(bs.summa), 0)::numeric as summa
      from bs group by bs.tur
  ),
  x as (
    select a.id as account_id, a.code, a.name,
           coalesce(sum(l.debit), 0)::numeric   as summa,
           count(distinct l.entry_id)::int      as soni
      from bs
      join entry_line l on l.entry_id = bs.id and l.debit > 0
      join accounts   a on a.id = l.account_id
     where a.type = 'xarajat'
     group by a.id, a.code, a.name
    having coalesce(sum(l.debit), 0) > 0
  )
  select jsonb_build_object(
           'jami',       (select to_jsonb(j) from j),
           'turlar',     (select coalesce(jsonb_agg(to_jsonb(t) order by t.summa desc, t.tur), '[]'::jsonb) from t),
           'xarajat',    (select coalesce(jsonb_agg(to_jsonb(x) order by x.summa desc, x.code), '[]'::jsonb) from x),
           'chetlangan', (select to_jsonb(ch) from ch)
         )
    into v_out;

  return coalesce(v_out, jsonb_build_object(
    'jami',       jsonb_build_object('soni', 0, 'summa', 0),
    'turlar',     '[]'::jsonb,
    'xarajat',    '[]'::jsonb,
    'chetlangan', jsonb_build_object('soni', 0, 'ochirilgan', 0)));
end $fn$;

revoke all on function jurnal_dash(date, date, uuid[], uuid[], text[], text, text) from public, anon;
grant execute on function jurnal_dash(date, date, uuid[], uuid[], text[], text, text) to authenticated;

comment on function jurnal_dash(date, date, uuid[], uuid[], text[], text, text) is
  'Jurnal v2 dashboard (DAVR XULOSASI): jami + tur kesimi (hamma tur) + xarajat moddalari kesimi + chetlangan. '
  'Sahifa qorovuli: jurnal_page_ok(''jurnal''). '
  '🔴 p_turlar IMZODA QOLADI, lekin ETIBORGA OLINMAYDI (tur — royxat korinishi, xulosa filtri emas). '
  'p_ijrochi esa QOLLANADI — "kim yozgan" xulosaning ozi. '
  'AGREGAT FAIL-CLOSED: ochirilgan va aralash kop satrli yozuv jamiga KIRMAYDI, royxatda korinadi. '
  'TEZLIK: javobda ism yoq — ijrochi_nomi() UMUMAN chaqirilmaydi (filtr xom kalitga tayanadi). '
  'Invariant: jami.soni + chetlangan.soni + chetlangan.ochirilgan = jurnal_v2_count(..., NULL, p_q, p_ijrochi).';


-- #####################################################################
-- ##  4-BO'LIM — jurnal_ijrochilar(): filtr dropdowni uchun ro'yxat   ##
-- #####################################################################
-- Qaytishi: (ijrochi_raw text, ijrochi text, soni int) — davrda kim
-- nechta yozuv yozgan. `soni desc, ijrochi` tartibida.
--
-- 🔴 RUXSAT — IKKI qavat:
--   1) `jurnal_page_ok('jurnal')` — uchala jurnal RPC si bilan bir xil
--      qorovul (yo'q bo'lsa 42501).
--   2) Ro'yxat AYNAN `jurnal_v2_baza` ko'radigan yozuvlardan quriladi
--      (o'sha funksiya ichida `perm_view_pul_ids()` fail-closed ishlaydi).
--      Ya'ni cheklangan foydalanuvchi BUTUN KOMPANIYA XODIMLARI RO'YXATINI
--      sanab chiqa olmaydi — u faqat O'ZI KO'RADIGAN yozuvlarning
--      mualliflarini ko'radi. `profiles` dan to'g'ridan o'qish ATAYLAB
--      QILINMAGAN (u butun ro'yxatni ochib berardi).
--
-- 🔴 `'(bosh)'` SENTINEL: `created_by` bo'sh guruh shu kalit bilan qaytadi
--    (3-BO'LIM izohi). Klient qaytarib yuborganda filtr uni tushunadi.
--    Kontrakt: "ro'yxatdan olingan `ijrochi_raw` ni o'zgartirmasdan
--    `p_ijrochi` ga ber".
--
-- ⚠️ Boshqa filtrlar (hisob/modda/tur/qidiruv) ATAYLAB olinmaydi: dropdown
--    davr bo'yicha barqaror bo'lishi kerak — aks holda hisob tanlagan
--    zahoti tanlangan ijrochi ro'yxatdan yo'qolib, filtr o'zini o'zi
--    tozalab yuborardi.
--
-- 🔴 TEZLIK (QA topilmasi): guruhlash XOM kalit bo'yicha bajariladi, ism esa
--    GROUP BY dan KEYIN — ya'ni `ijrochi_nomi()` davrdagi har YOZUV uchun
--    emas, har IJROCHI uchun bir marta chaqiriladi (odatda 3–10 marta).
--    Ichki so'rovda `group by` borligi uni "flatten" qilinishdan saqlaydi,
--    shuning uchun tashqi select ro'yxati faqat guruhlarga hisoblanadi.
--    Natija shakli va tartibi O'ZGARMADI: `(ijrochi_raw, ijrochi, soni)`,
--    `soni desc, ijrochi`.
-- ---------------------------------------------------------------------

create or replace function jurnal_ijrochilar(
  p_from date,
  p_to   date)
returns table(ijrochi_raw text, ijrochi text, soni int)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  -- 🔴 SAHIFA QOROVULI — jurnal_v2* bilan AYNAN bir xil.
  if not jurnal_page_ok('jurnal') then
    raise exception 'Jurnal sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  return query
  -- ⚠️ Ustun ALIASlari ATAYLAB yozilmagan: nomlar `returns table(...)` dan
  --    keladi, plpgsql o'zgaruvchisi bilan chalkashish ehtimoli qolmasin.
  -- 🔴 ISM GROUP BY DAN KEYIN — har guruhga bittadan chaqiruv (tezlik izohi).
  --    `nullif(g.xom, '(bosh)')` — sentinel yana NULL ga qaytariladi, ya'ni
  --    bo'sh guruh uchun `ijrochi_nomi(null)` = 'Noma'lum' (avvalgidek).
  select g.xom::text,
         ijrochi_nomi(nullif(g.xom, '(bosh)'))::text,
         g.n
    from (
      select coalesce(b.ijrochi_raw, '(bosh)') as xom,
             count(*)::int                     as n
        from jurnal_v2_baza(p_from, p_to, null, null, null, null) b
       group by 1
    ) g
   -- Tartib avvalgidek: soni desc, keyin ism (2 = chiqishdagi `ijrochi`).
   order by g.n desc, 2;
end $fn$;

revoke all on function jurnal_ijrochilar(date, date) from public, anon;
grant execute on function jurnal_ijrochilar(date, date) to authenticated;

comment on function jurnal_ijrochilar(date, date) is
  'Jurnal v2 ijrochi filtri uchun royxat: (ijrochi_raw, ijrochi, soni), soni desc. '
  'Manba — jurnal_v2_baza (ya''ni FOYDALANUVCHI KORADIGAN yozuvlar, fail-closed), profiles EMAS. '
  'created_by bosh guruh ijrochi_raw = ''(bosh)'' bolib qaytadi — shuni ozgartirmasdan p_ijrochi ga bering. '
  'TEZLIK: ijrochi_nomi() group by dan KEYIN chaqiriladi (har ijrochiga bitta, har yozuvga emas). '
  'Sahifa qorovuli: jurnal_page_ok(''jurnal'').';


-- =====================================================================
-- PostgREST sxemasini yangilash (busiz yangi imzo 404/PGRST202 beradi)
-- =====================================================================

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  TEKSHIRUV — FAQAT KATALOG SO'ROVLARI                            ##
-- #####################################################################
-- 🔴 JONLI CHAQIRUV YO'Q: editorda `auth.uid()` null → `jurnal_page_ok()`
--    42501 beradi, u esa BUTUN faylni (bitta tranzaksiya) orqaga qaytarib
--    funksiyalarni yaratmay qo'yardi. Jonli sinov — brauzerda.
-- Hamma ustun kutilgan qiymatni bersin.
-- ---------------------------------------------------------------------

-- 1) Funksiyalar YANGI imzo bilan o'rnidami (hammasi true)
select to_regprocedure('public.entry_ijrochi_set()')                                        is not null as trigger_fn_ok,
       to_regprocedure('public.ijrochi_nomi(text)')                                          is not null as ijrochi_nomi_ok,
       to_regprocedure('public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)')         is not null as baza_ok,
       to_regprocedure('public.jurnal_v2(date,date,uuid[],uuid[],text[],text,int,int,text)') is not null as jurnal_v2_ok,
       to_regprocedure('public.jurnal_v2_count(date,date,uuid[],uuid[],text[],text,text)')   is not null as count_ok,
       to_regprocedure('public.jurnal_dash(date,date,uuid[],uuid[],text[],text,text)')       is not null as dash_ok,
       to_regprocedure('public.jurnal_ijrochilar(date,date)')                                is not null as royxat_ok,
       -- 🔴 BOG'LIQ OBYEKTLAR: bular PROVODKA_JURNAL_V2.sql / PROVODKA_PERMS.sql
       --    dan keladi. Ular bo'lmasa BU FAYL BARIBIR MUVAFFAQIYATLI RUN BO'LADI
       --    (plpgsql tanasi yaratishda tekshirilmaydi) va hamma tekshiruv `true`
       --    beradi — lekin brauzerda uchala RPC 42883 bilan yiqiladi va jurnal-dev
       --    jimgina eski `jurnal()` ga tushib ketadi. Shuning uchun SHU YERDA sanaymiz.
       to_regprocedure('public.jurnal_page_ok(text)')                                        is not null as qorovul_bor,
       to_regprocedure('public.perm_view_pul_ids()')                                         is not null as perm_view_bor;

-- 2) 🔴 ESKI IMZOLAR QOLMAGANMI (PostgREST PGRST203 "could not choose the
--    best candidate" bermasin) — uchalasi ham NULL bo'lishi kerak,
--    ya'ni `..._eski_yoq` ustunlari TRUE.
select to_regprocedure('public.jurnal_v2(date,date,uuid[],uuid[],text[],text,int,int)') is null as jurnal_v2_eski_yoq,
       to_regprocedure('public.jurnal_v2_count(date,date,uuid[],uuid[],text[],text)')   is null as count_eski_yoq,
       to_regprocedure('public.jurnal_dash(date,date,uuid[],uuid[],text[],text)')       is null as dash_eski_yoq,
       -- Har nom bo'yicha bitta overload bo'lsin (1 = to'g'ri)
       (select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace
         and p.proname = 'jurnal_v2')       as jurnal_v2_overload_1_bulsin,
       (select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace
         and p.proname = 'jurnal_v2_count') as count_overload_1_bulsin,
       (select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace
         and p.proname = 'jurnal_dash')     as dash_overload_1_bulsin;

-- 3) 🔴 PROD JURNALI TEGILMAGANMI — ikkalasi ham true bo'lishi SHART
select exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
                and p.proname = 'jurnal')       as eski_jurnal_saqlandi,
       exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
                and p.proname = 'jurnal_count') as eski_jurnal_count_saqlandi;

-- 4) Trigger o'rnidami: nomi, BEFORE INSERT, WHEN sharti bormi
select t.tgname,
       (t.tgtype & 2) > 0  as before_ok,      -- 2 = BEFORE
       (t.tgtype & 4) > 0  as insert_ok,      -- 4 = INSERT
       t.tgqual is not null as when_sharti_bor,
       t.tgenabled          as holati          -- 'O' = yoqilgan
  from pg_trigger t
 where t.tgrelid = 'public.entry'::regclass
   and not t.tgisinternal
 order by t.tgname;

-- 5) Baza ustunlari: XOM kalit BOR, ism ustuni YO'Q (tezlik qarori).
--    Ikkala ustun ham `true` bo'lishi kerak.
select 'ijrochi_raw' = any(p.proargnames)       as baza_ijrochi_raw_ustuni,
       not ('ijrochi' = any(p.proargnames))     as baza_ijrochi_ustuni_YUQ
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.proname = 'jurnal_v2_baza';

-- 5B) 🔴 TEZLIK REGRESSIYASI (QA topilmasi qaytib kelmasin).
--     `ijrochi_nomi()` FAQAT ikki joyda chaqirilishi kerak. Hamma ustun `true`:
select (select p.prosrc not like '%ijrochi_nomi%' from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.proname = 'jurnal_v2_baza')
         as bazada_ISM_YUQ,
       (select p.prosrc not like '%ijrochi_nomi%' from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.proname = 'jurnal_v2_count')
         as countda_ISM_YUQ,
       (select p.prosrc not like '%ijrochi_nomi%' from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.proname = 'jurnal_dash')
         as dashda_ISM_YUQ,
       (select p.prosrc like '%ijrochi_nomi(p.ijrochi_raw)%' from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.proname = 'jurnal_v2')
         as jurnal_v2_LIMITDAN_KEYIN,
       (select p.prosrc like '%ijrochi_nomi(nullif(g.xom%' from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.proname = 'jurnal_ijrochilar')
         as royxat_GROUPDAN_KEYIN;

-- 6) Uchala ochiq RPC da p_ijrochi parametri bormi (3 bo'lsin)
select count(*)::int as p_ijrochi_bor_rpc_soni_3_bulsin
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('jurnal_v2','jurnal_v2_count','jurnal_dash')
   and 'p_ijrochi' = any(p.proargnames);

-- 7) Sahifa qorovuli hamma RPC da qoldimi (4 bo'lsin: 3 + jurnal_ijrochilar)
select count(*)::int as qorovulli_rpc_soni_4_bulsin
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('jurnal_v2','jurnal_v2_count','jurnal_dash','jurnal_ijrochilar')
   and p.prosrc like '%jurnal_page_ok(''jurnal'')%';

-- 8) Huquqlar: ICHKI funksiya yopiq, ochiq RPC lar authenticated uchun ochiq
select has_function_privilege('authenticated',
         'public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text)', 'execute') as baza_ochiq_BULMASIN,
       has_function_privilege('anon',
         'public.ijrochi_nomi(text)', 'execute')                                  as ijrochi_nomi_anon_BULMASIN,
       has_function_privilege('authenticated',
         'public.ijrochi_nomi(text)', 'execute')                    as ijrochi_nomi_authenticated_BULMASIN,
       has_function_privilege('authenticated',
         'public.jurnal_v2(date,date,uuid[],uuid[],text[],text,int,int,text)', 'execute') as jurnal_v2_ochiq,
       has_function_privilege('authenticated',
         'public.jurnal_ijrochilar(date,date)', 'execute')                        as royxat_ochiq;


-- #####################################################################
-- ##  KLIENT KONTRAKTI (keyingi bosqich — jurnal-dev.html)            ##
-- #####################################################################
--   Ustun:  har element endi `ijrochi` (ko'rsatiladigan ism) va
--           `ijrochi_raw` (filtr uchun xom kalit) bilan keladi.
--           Bo'sh yozuvda `ijrochi = 'Noma''lum'`, `ijrochi_raw = null`.
--   Filtr:  sb.rpc('jurnal_ijrochilar', {p_from, p_to})
--             → [{ijrochi_raw, ijrochi, soni}]  (soni desc)
--           tanlangan `ijrochi_raw` ni O'ZGARTIRMASDAN uchala RPC ga
--           `p_ijrochi` bo'lib beriladi (jurnal_v2 / jurnal_v2_count /
--           jurnal_dash) — aks holda ro'yxat, sanoq va dashboard
--           bir-biriga mos kelmaydi.
--   ⚠️ Hamma argument NOMLANGAN yuborilsin (`p_ijrochi: …`) — parametr
--      oxiriga qo'shilgan, pozitsiyaga tayanma.
--   ⚠️ `{ data, error }` — error DOIM tekshiriladi; 42501 = sahifa
--      ruxsati yo'q, PGRST202 = SQL RUN qilinmagan (imzo topilmadi).
--
--   ℹ️ ISM QAYERDAN KELADI (tezlik qarori, klientga ta'sir qilmaydi):
--        jurnal_v2         → `ijrochi` + `ijrochi_raw` (avvalgidek)
--        jurnal_ijrochilar → `ijrochi` + `ijrochi_raw` + `soni`
--        jurnal_v2_count / jurnal_dash → ism YO'Q (hech qachon bo'lmagan);
--          ular faqat `p_ijrochi` FILTRINI qabul qiladi.
--      Ya'ni klient ismni FAQAT shu ikki manbadan oladi; `ijrochi_nomi()`
--      ni to'g'ridan chaqirib bo'lmaydi (grant ataylab berilmagan).
--
--
-- #####################################################################
-- ##  ROLLBACK (kerak bo'lsa — bitta-bitta RUN qiling)                ##
-- #####################################################################
-- 🔴 TARTIB: pastdagi qadamlar KETMA-KET, AYNAN shu tartibda.
--    Ya'ni AVVAL yangi imzolar drop qilinadi (3-qadam), FAQAT SHUNDAN KEYIN
--    PROVODKA_JURNAL_V2.sql qayta RUN qilinadi (5-qadam).
--    Teskari qilinsa:
--      * `create or replace function jurnal_v2_baza(...)` ->
--        "cannot change return type of existing function" (bazada 16 ustunli
--        versiya turibdi) va butun rollback yiqiladi;
--      * o'tib ketsa ham 8- va 9-argumentli `jurnal_v2` yonma-yon qolib
--        PostgREST PGRST203 beradi -> jurnal-dev BUTUNLAY ishlamaydi.
--    Rollback vaqtida jurnal-dev qisqa muddat eski `jurnal()` ga tushadi
--    (`v2Off` zaxirasi) — bu kutilgan holat, sahifa bo'sh qolmaydi.
--
-- 1) `created_by` avtomat to'lishini to'xtatish (yozilganlar QOLADI):
--    drop trigger if exists trg_entry_ijrochi on entry;
--    drop function if exists public.entry_ijrochi_set();
--
-- 2) Ijrochi ro'yxati (filtr dropdowni):
--    drop function if exists public.jurnal_ijrochilar(date, date);
--
-- 3) Yangi imzolarni olib tashlash:
--    drop function if exists public.jurnal_v2(date,date,uuid[],uuid[],text[],text,int,int,text);
--    drop function if exists public.jurnal_v2_count(date,date,uuid[],uuid[],text[],text,text);
--    drop function if exists public.jurnal_dash(date,date,uuid[],uuid[],text[],text,text);
--    drop function if exists public.jurnal_v2_baza(date,date,uuid[],uuid[],text[],text);
--
-- 4) Ko'rsatish funksiyasi (3-bosqichdan keyin — unga hech kim bog'lanmasa):
--    drop function if exists public.ijrochi_nomi(text);
--
-- 5) So'ng PROVODKA_JURNAL_V2.sql ni BUTUNLIGICHA qayta RUN qiling
--    (eski imzoli jurnal_v2* qaytadi) va:
--    notify pgrst, 'reload schema';
--
-- 🔴 Rollback `entry.created_by` dagi QIYMATLARNI O'CHIRMAYDI — ular
--    haqiqiy tarix (kim yozgani), o'chirilmaydi.
-- #####################################################################
