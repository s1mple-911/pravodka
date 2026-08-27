-- =====================================================================
-- PROVODKA_RASM_DETECT.sql
-- "CHEK / SPIDOMETR AI TEKSHIRUVI" — SERVER QISMI
-- ---------------------------------------------------------------------
-- Hodim xarajat yozganda chek (yoki mashina spidometri) rasmini yuklaydi.
-- Edge Function (keyingi bosqich, alohida deploy) rasmni Claude'ga
-- yuboradi, natijani `rasm_tahlil` jadvaliga service_role bilan yozadi.
-- Bu fayl FAQAT baza qismi: jadval, RLS, tamper-proof yozish, shubhali
-- hisoblash (0 tolerance, lekin faqat AI ANIQ o'qigan bo'lsa), km tarixi.
--
-- ## RUN TARTIBI (Asilbek, Supabase SQL editor) — BO'LIMLARNI TARTIB BILAN
--   0-BO'LIM — old shart tekshiruvi (faqat select)
--   1-BO'LIM — accounts.ai_tekshir + accounts.spidometr_ai (ikki mustaqil
--              bayroq) + set_modda_flag('ai'|'spidometr') (imzo saqlanadi)
--   2-BO'LIM — rasm_tahlil jadvali + RLS (faqat service_role yozadi)
--   3-BO'LIM — entry ustunlari (rasm_tahlil_id, spidometr_tahlil_id,
--              shubhali, shubhali_sabab, ai_holat, ai_tekshirildi_at)
--   3.5-BO'LIM — mashina_km JADVALI (faqat jadval — RPC 6-BO'LIMda; jadval
--              ERTAROQ kerak, chunki 4-BO'LIMdagi funksiya undan %rowtype
--              bilan foydalanadi)
--   4-BO'LIM — rasm_shubhali_hisobla(uuid) + ikki tomonlama triggerlar
--              (entry / rasm_tahlil / entry_line)
--   5-BO'LIM — entry_ai_bogla(uuid,uuid,uuid) — klient RPC (chek/spidometr
--              tahlilni yozuvga bog'laydi)
--   6-BO'LIM — mashina_km_yoz(uuid,uuid,int,uuid)
--   7-BO'LIM — v_shubhali, v_mashina_samara (admin ko'rinishlari)
--   8-BO'LIM — storage bucket `rasm-tahlil` (private) + RLS
--   9-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog) + notify pgrst
--
-- ## OLD SHART (bazada bo'lishi kerak — 0-BO'LIM tekshiradi)
--   PROVODKA_PERMS.sql          -> is_admin(), perm_check_accounts(uuid[])
--   PROVODKA_XARAJAT_MAYDON.sql -> xarajat_royxat_element, xm_entry_yoz_ok(uuid)
--   PROVODKA_MAYDON_QOROVUL.sql -> xm_entry_yoz_ok(uuid) QATTIQLASHTIRILGAN versiyasi
--   PROVODKA_OVQAT.sql          -> set_modda_flag(uuid,text,boolean) ENG OXIRGI imzo
--                                   (chek|izoh|davr|filial|ovqat shoxlari — SAQLANADI)
--   PROVODKA_IJROCHI.sql        -> entry.created_by matn/uuid aralash naqshi
--
-- ## ASOSIY QOIDALAR (tasdiqlangan)
--   * Shubhali — 0 TOLERANCE (entry summa <> AI summa -> shubhali), LEKIN
--     faqat AI ANIQ o'qigan bo'lsa (`rasm_tahlil.ishonch >= 0.7` VA
--     `natija->>'muammo'` bo'sh). AI noaniq o'qigan bo'lsa — shubhali=false,
--     shunchaki "AI aniq o'qimadi" izohi.
--   * TAMPER-PROOF: `rasm_tahlil` ga yozish policy'si UMUMAN YO'Q — faqat
--     Edge Function (service_role) yozadi. Foydalanuvchi o'z natijasini
--     o'zgartira olmaydi.
--   * Hodim HECH NARSA ko'rmaydi (`v_shubhali`/`v_mashina_samara` faqat
--     admin) — hodim faqat rasmni yuklaydi, natija uni qiziqtirmaydi.
--   * AI FONDA ishlaydi: `entry` va tahlil ISTALGAN TARTIBDA kelishi mumkin
--     (klient tahlil id'sini OLDINDAN generatsiya qiladi va EF ga beradi,
--     EF esa rasmni tahlil qilib BIROZ KECHROQ yozadi) — shuning uchun
--     `entry.rasm_tahlil_id`/`spidometr_tahlil_id` da FK YO'Q (pastga
--     qarang, 3-BO'LIM), va ikki tomonlama trigger bor (4-BO'LIM).
--   * km tarixi MASHINAGA (`xarajat_royxat_element` — PROVODKA_XARAJAT_MAYDON.sql
--     dagi universal "royxat" varianti) bog'lanadi, alohida "mashina" jadvali
--     YO'Q — o'sha universal konstruktordan foydalaniladi.
--
-- ## ADDITIVE KAFOLATI
--   * Mavjud BIRORTA jadval/ustun/funksiya/view O'ZGARTIRILMAYDI (imzosi
--     buzilmaydi). `set_modda_flag` — imzo (uuid,text,boolean) AYNAN
--     saqlanadi, faqat yangi 'ai' shoxi qo'shiladi (eski 5 shox — chek,
--     izoh, davr, filial, ovqat — so'zma-so'z ko'chiriladi).
--   * `entry`/`entry_line` ga yangi ustun QO'SHILADI, eski hech narsa
--     o'zgarmaydi. Yozuv yo'li (entry -> entry_line insert) TEGILMAYDI.
--   * Anonim "do" bloki YO'Q. Har funksiya tanasi NOMLANGAN dollar-teg
--     (fn) bilan o'raladi (izohda bu tegning ozi yozilmaydi — parity buzilmasin).
--   * Faylda RPC ni JONLI chaqiradigan operator YO'Q — faqat katalog/select.
--   * Idempotent: bir necha marta RUN qilish xavfsiz.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (faqat ko'rish)                 ##
-- #####################################################################

select to_regprocedure('public.is_admin()')                     is not null as is_admin_bor,
       to_regprocedure('public.perm_check_accounts(uuid[])')    is not null as perm_check_accounts_bor,
       to_regprocedure('public.xm_entry_yoz_ok(uuid)')          is not null as xm_entry_yoz_ok_bor,
       to_regprocedure('public.set_modda_flag(uuid,text,boolean)') is not null as set_modda_flag_bor,
       to_regclass('public.xarajat_royxat_element')             is not null as xarajat_royxat_element_bor,
       to_regclass('public.entry')                              is not null as entry_bor,
       to_regclass('public.entry_line')                         is not null as entry_line_bor,
       to_regclass('public.accounts')                           is not null as accounts_bor,
       to_regprocedure('public.gen_random_uuid()')              is not null as gen_random_uuid_bor;


-- #####################################################################
-- ##  1-BO'LIM — accounts.ai_tekshir + spidometr_ai + set_modda_flag  ##
-- #####################################################################

alter table accounts
  add column if not exists ai_tekshir boolean not null default false;

comment on column accounts.ai_tekshir is
  'Xarajat moddasi: chek AI tekshiruvi yoqilganmi (UNIVERSAL — istalgan modda). true bolsa hodim.html '
  'shu moddaga yozganda chek rasmini yuklashni taklif qiladi (klient ishi — bu ustun faqat bayroq).';

alter table accounts
  add column if not exists spidometr_ai boolean not null default false;

comment on column accounts.spidometr_ai is
  'Xarajat moddasi: spidometr AI tekshiruvi yoqilganmi. FAQAT benzin/gaz (mashina) moddalarida '
  'mantiqiy — hodim.html bu bayroq true VA "Mashina" maydoni tanlangandagina spidometr bolimini korsatadi. '
  'ai_tekshir dan MUSTAQIL (Asilbek qarori — ikki alohida bayroq).';

-- 🔴 IMZO O'ZGARMAYDI (uuid, text, boolean) — PROVODKA_OVQAT.sql dagi eng
--    oxirgi versiya + 'ai' va 'spidometr' shoxlari qoshildi. Eski 5 shox
--    (chek/izoh/davr/filial/ovqat) SOZMA-SOZ saqlandi.
create or replace function set_modda_flag(p_account uuid, p_flag text, p_bool boolean)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not is_admin() then
    raise exception 'Faqat admin' using errcode = '42501';
  end if;
  if p_flag = 'chek' then
    update accounts set chek_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'izoh' then
    update accounts set izoh_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'davr' then
    update accounts set davr_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'filial' then
    update accounts set filial_majburiy = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'ovqat' then
    update accounts set ovqat_modda = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'ai' then
    update accounts set ai_tekshir = coalesce(p_bool, false) where id = p_account;
  elsif p_flag = 'spidometr' then
    update accounts set spidometr_ai = coalesce(p_bool, false) where id = p_account;
  else
    raise exception 'Nomalum bayroq';
  end if;
end $fn$;

revoke all on function set_modda_flag(uuid, text, boolean) from public, anon;
grant execute on function set_modda_flag(uuid, text, boolean) to authenticated;

comment on function set_modda_flag(uuid, text, boolean) is
  'Admin: xarajat moddasi bayrogi (chek|izoh|davr|filial|ovqat|ai|spidometr) yoqadi yoki ochiradi.';


-- #####################################################################
-- ##  2-BO'LIM — rasm_tahlil (chek/spidometr AI natijasi)             ##
-- #####################################################################
-- Yozish faqat service_role (Edge Function). RLS'da insert/update/delete
-- policy UMUMAN YO'Q — foydalanuvchi (authenticated) hech qanday holatda
-- o'z natijasini o'zgartira olmaydi (tamper-proof).

create table if not exists rasm_tahlil (
  id           uuid        primary key default gen_random_uuid(),
  user_id      uuid        not null,
  tur          text        not null,
  storage_path text,
  natija       jsonb       not null default '{}'::jsonb,
  ai_summa     numeric,
  ai_sana      date,
  ai_km        int,
  ishonch      numeric,
  aniq         boolean     not null default false,
  model        text,
  holat        text        not null default 'ok',
  xato         text,
  created_at   timestamptz not null default now()
);

alter table rasm_tahlil
  drop constraint if exists rasm_tahlil_tur_chk;
alter table rasm_tahlil
  add constraint rasm_tahlil_tur_chk
  check (tur in ('chek', 'spidometr'));

alter table rasm_tahlil
  drop constraint if exists rasm_tahlil_holat_chk;
alter table rasm_tahlil
  add constraint rasm_tahlil_holat_chk
  check (holat in ('ok', 'xato', 'chek_emas'));

alter table rasm_tahlil
  drop constraint if exists rasm_tahlil_ishonch_chk;
alter table rasm_tahlil
  add constraint rasm_tahlil_ishonch_chk
  check (ishonch is null or (ishonch >= 0 and ishonch <= 1));

alter table rasm_tahlil
  drop constraint if exists rasm_tahlil_natija_chk;
alter table rasm_tahlil
  add constraint rasm_tahlil_natija_chk
  check (jsonb_typeof(natija) = 'object');

create index if not exists rasm_tahlil_user_idx on rasm_tahlil (user_id);

comment on table rasm_tahlil is
  'Chek/spidometr AI tahlili natijasi. Yozish FAQAT service_role (Edge Function) — '
  'RLS da insert/update/delete policy YOQ. `id`ni klient OLDINDAN generatsiya qilib '
  'EF ga beradi (fonda ishlash uchun) — shuning uchun `entry.rasm_tahlil_id` da FK YOQ.';
comment on column rasm_tahlil.natija is
  'AI ning TOLIQ xom javobi (jsonb). `aniq` shundan qayta hisoblanadi (ishonchli manba) — '
  'pastdagi trg_rasm_tahlil_aniq trigeriga qarang.';
comment on column rasm_tahlil.aniq is
  'ishonch >= 0.7 VA natija->>muammo bosh. EF hisoblab yuboradi, lekin trigger QAYTA '
  'hisoblaydi (natija jsonb ishonchli manba) — EF xato/soxta bayroq yuborsa ham togrilanadi.';
comment on column rasm_tahlil.holat is
  'ok = tahlil muvaffaqiyatli, xato = AI/tarmoq xatosi, chek_emas = rasm chek/spidometr emas.';

-- 🔴🔴 TAMPER-PROOF: aniq/ishonch ni natija (jsonb) dan qayta hisoblovchi
--    BEFORE trigger — EF yuborgan alohida ustunlarga emas, `natija` ga ishonamiz.
create or replace function trg_rasm_tahlil_aniq_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare v_ishonch numeric;
begin
  if new.natija is null or jsonb_typeof(new.natija) <> 'object' then
    new.aniq := false;
    return new;
  end if;

  begin
    v_ishonch := (new.natija ->> 'ishonch')::numeric;
  exception when others then
    v_ishonch := null;   -- buzuq qiymat -> qaror ustundagi ishonchga qoladi
  end;
  new.ishonch := coalesce(v_ishonch, new.ishonch, 0);

  new.aniq := new.ishonch >= 0.7
              and nullif(btrim(coalesce(new.natija ->> 'muammo', '')), '') is null
              -- EF bilan BIR XIL qoida: o'qilgan qiymatning o'zi ham bo'lishi shart
              -- (chek -> summa, spidometr -> km). Aks holda "aniq, lekin summa yo'q" chiqardi.
              and case when new.tur = 'spidometr'
                       then nullif(btrim(coalesce(new.natija ->> 'km', '')), '') is not null
                       else nullif(btrim(coalesce(new.natija ->> 'summa', '')), '') is not null
                  end;
  return new;
end $fn$;

drop trigger if exists trg_rasm_tahlil_aniq on rasm_tahlil;
create trigger trg_rasm_tahlil_aniq
  before insert or update on rasm_tahlil
  for each row execute function trg_rasm_tahlil_aniq_fn();

comment on function trg_rasm_tahlil_aniq_fn() is
  'natija (jsonb) -> ishonch/aniq qayta hisoblaydi (ishonchli manba natija, ustun emas). Tamper-proof zanjirning bir qismi.';

-- --- RLS: faqat SELECT (o'zi yoki admin). Yozish policy UMUMAN YOQ. ---
alter table rasm_tahlil enable row level security;

drop policy if exists rasm_tahlil_sel on rasm_tahlil;
create policy rasm_tahlil_sel on rasm_tahlil
  for select to authenticated
  using ((select auth.uid()) = user_id or is_admin());

revoke all on rasm_tahlil from public, anon;
grant select on rasm_tahlil to authenticated;
grant all    on rasm_tahlil to service_role;


-- #####################################################################
-- ##  3-BO'LIM — entry ustunlari (metadata + shubhali natija)         ##
-- #####################################################################
-- 🔴 `rasm_tahlil_id`/`spidometr_tahlil_id` da ATAYLAB FK YOQ: klient
--    tahlil `id`sini OLDINDAN generatsiya qilib EF ga beradi, so'ng
--    darrov `entry_ai_bogla()` bilan yozuvga bogilaydi — bu payt
--    `rasm_tahlil` qatori HALI mavjud bolmasligi mumkin (EF fonda hali
--    ishlayapti). FK bolsa shu yerda insert 23503 bilan yiqilardi.
--    O'rniga: indeks + `ai_holat='kutilmoqda'` (4/5-BOLIM) va ikki
--    tomonlama trigger — tahlil kelganda avtomat qayta hisoblanadi.

alter table entry
  add column if not exists rasm_tahlil_id      uuid,
  add column if not exists spidometr_tahlil_id uuid,
  add column if not exists shubhali            boolean not null default false,
  add column if not exists shubhali_sabab      text,
  add column if not exists ai_holat            text,
  add column if not exists ai_tekshirildi_at    timestamptz;

alter table entry
  drop constraint if exists entry_ai_holat_chk;
alter table entry
  add constraint entry_ai_holat_chk
  check (ai_holat is null or ai_holat in ('ok', 'yoq', 'xato', 'kutilmoqda'));

comment on column entry.rasm_tahlil_id is
  'Chek AI tahlili (rasm_tahlil.tur=chek). FK YOQ — tahlil fonda kech kelishi mumkin (3-BOLIM izohi).';
comment on column entry.spidometr_tahlil_id is
  'Spidometr AI tahlili (rasm_tahlil.tur=spidometr). FK YOQ — sabab yuqoridagi bilan bir xil.';
comment on column entry.shubhali is
  'rasm_shubhali_hisobla() natijasi: chek summasi/spidometr km AI bilan mos kelmadimi '
  '(faqat AI ANIQ oqigan bolsa — 0 tolerance) YOKI km uzluksizligi buzildi.';
comment on column entry.shubhali_sabab is
  'Inson-oqiladigan sabab (masalan "AI chek: 50 000 - yozildi 70 000"). Bir nechta sabab " * " bilan qoshiladi.';
comment on column entry.ai_holat is
  'ok | yoq (AI tekshiruvi biriktirilmagan) | xato (AI/tarmoq xatosi) | kutilmoqda (tahlil hali kelmadi).';

create index if not exists entry_rasm_tahlil_idx
  on entry (rasm_tahlil_id) where rasm_tahlil_id is not null;
create index if not exists entry_spidometr_tahlil_idx
  on entry (spidometr_tahlil_id) where spidometr_tahlil_id is not null;
create index if not exists entry_shubhali_idx
  on entry (shubhali) where shubhali;


-- #####################################################################
-- ##  3.5-BO'LIM — mashina_km JADVALI (RPC 6-BO'LIMda — bu yerda faqat  ##
-- ##  jadval, chunki 4-BO'LIMdagi funksiya %rowtype bilan foydalanadi) ##
-- #####################################################################

create table if not exists mashina_km (
  id                  uuid        primary key default gen_random_uuid(),
  entry_id            uuid        not null references entry(id) on delete cascade,
  mashina_element_id  uuid        not null references xarajat_royxat_element(id) on delete restrict,
  km                  int         not null,
  sana                date        not null,
  rasm_tahlil_id      uuid,        -- FK YOQ — 3-BOLIM bilan bir xil sabab (fonda kelishi mumkin)
  user_id             uuid        not null,
  oldingi_km          int,
  yurgan_km           int,
  som_per_km          numeric,
  created_at          timestamptz not null default now()
);

alter table mashina_km
  drop constraint if exists mashina_km_km_chk;
alter table mashina_km
  add constraint mashina_km_km_chk
  check (km >= 0);

create unique index if not exists mashina_km_entry_uq on mashina_km (entry_id);
create index if not exists mashina_km_element_idx on mashina_km (mashina_element_id);

comment on table mashina_km is
  'Mashina spidometr tarixi — har entry uchun BITTA qator (unique entry_id). '
  'mashina_element_id -> xarajat_royxat_element (universal "royxat" maydon konstruktori, PROVODKA_XARAJAT_MAYDON.sql). '
  'Yozish faqat mashina_km_yoz() orqali (6-BOLIM).';
comment on column mashina_km.oldingi_km is
  'Shu mashina uchun avvalgi (sana, created_at boyicha eng oxirgi) yozuvdagi km. Birinchi yozuvda null.';
comment on column mashina_km.yurgan_km is
  'km - oldingi_km. Manfiy bolishi mumkin (km orqaga) — rasm_shubhali_hisobla shuni shubhali qiladi.';
comment on column mashina_km.som_per_km is
  'Shu yozuv summasi / yurgan_km (yurgan_km > 0 bolsa). v_mashina_samara shu ustunlardan yigindi oladi.';

alter table mashina_km enable row level security;

drop policy if exists mashina_km_sel on mashina_km;
create policy mashina_km_sel on mashina_km
  for select to authenticated
  using ((select auth.uid()) = user_id or is_admin());

revoke all on mashina_km from public, anon;
grant select on mashina_km to authenticated;   -- yozish faqat RPC (definer, RLS insert policy yoq)


-- #####################################################################
-- ##  4-BO'LIM — rasm_shubhali_hisobla(uuid) + ikki tomonlama trigger ##
-- #####################################################################
-- Bitta funksiya — YAGONA hisoblash manbai. `entry`, `rasm_tahlil`,
-- `entry_line` uchtasi ham shuni chaqiradi (tartibdan qatiy nazar togri
-- natija chiqsin — AI fonda, satrlar ham fonda kelishi mumkin).
--
-- ⚠️ `ai_holat` combain qoidasi (chek + spidometr ikkalasi ham bolsa)
--    QATIY EMAS — sodda ustunlik: xato > kutilmoqda > ok > yoq. Ya'ni
--    ikkalasi ham biriktirilgan bolsa va biri "ok" biri "kutilmoqda"
--    bolsa, umumiy holat taxminan korsatiladi (aniq holat uchun ikkala
--    tahlilni alohida sorash kerak — bu funksiya faqat entry.ai_holat
--    uchun bitta ozet beradi).
create or replace function rasm_shubhali_hisobla(p_entry uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_rasm_id    uuid;
  v_spid_id    uuid;
  v_entry_date date;
  v_summa      numeric;
  v_t          rasm_tahlil%rowtype;
  v_km         mashina_km%rowtype;
  v_km_found   boolean := false;
  v_holat      text := 'yoq';
  v_shubhali   boolean := false;
  v_sabab      text[] := '{}'::text[];
begin
  if p_entry is null then
    return;
  end if;

  select rasm_tahlil_id, spidometr_tahlil_id, entry_date
    into v_rasm_id, v_spid_id, v_entry_date
    from entry where id = p_entry;
  if not found then
    return;   -- yozuv topilmadi (allaqachon ochirilgan bolishi mumkin)
  end if;

  -- ---- CHEK: 0 tolerance, faqat AI ANIQ oqigan bolsa ----
  if v_rasm_id is not null then
    select * into v_t from rasm_tahlil where id = v_rasm_id;
    if not found then
      v_holat := 'kutilmoqda';   -- klient bogladi, EF hali yozmagan
    elsif v_t.holat is distinct from 'ok' then
      v_holat := 'xato';
    elsif not coalesce(v_t.aniq, false) then
      v_holat := 'ok';
      v_sabab := v_sabab || ('AI chekni aniq oqimadi (ishonch '
                              || coalesce(round(v_t.ishonch, 2)::text, '?') || ')');
    else
      v_holat := 'ok';
      select coalesce(sum(l.debit), 0) into v_summa
        from entry_line l join accounts a on a.id = l.account_id
       where l.entry_id = p_entry and l.debit > 0 and a.type = 'xarajat';

      if v_t.ai_summa is not null and v_t.ai_summa is distinct from coalesce(v_summa, 0) then
        v_shubhali := true;
        v_sabab := v_sabab || ('AI chek: ' || replace(to_char(v_t.ai_summa, 'FM999G999G999'), ',', ' ')
                                || ' * yozildi ' || replace(to_char(coalesce(v_summa, 0), 'FM999G999G999'), ',', ' '));
      end if;
      if v_t.ai_sana is not null and v_entry_date is not null and v_t.ai_sana is distinct from v_entry_date then
        v_sabab := v_sabab || ('sana AI ' || v_t.ai_sana::text || ', hisob ' || v_entry_date::text);
      end if;
    end if;
  end if;

  -- ---- mashina_km qatorini oldindan olib qoyamiz (ikki bolim ishlatadi) ----
  select * into v_km from mashina_km where entry_id = p_entry;
  v_km_found := found;

  -- ---- SPIDOMETR AI: 0 tolerance, faqat AI ANIQ oqigan bolsa ----
  if v_spid_id is not null then
    select * into v_t from rasm_tahlil where id = v_spid_id;
    if not found then
      if v_holat = 'yoq' then v_holat := 'kutilmoqda'; end if;
    elsif v_t.holat is distinct from 'ok' then
      if v_holat in ('yoq', 'ok') then v_holat := 'xato'; end if;
    elsif not coalesce(v_t.aniq, false) then
      if v_holat = 'yoq' then v_holat := 'ok'; end if;
      v_sabab := v_sabab || ('AI spidometrni aniq oqimadi (ishonch '
                              || coalesce(round(v_t.ishonch, 2)::text, '?') || ')');
    else
      if v_holat = 'yoq' then v_holat := 'ok'; end if;
      if v_km_found and v_t.ai_km is not null and v_t.ai_km is distinct from v_km.km then
        v_shubhali := true;
        v_sabab := v_sabab || ('AI spidometr: ' || v_t.ai_km || ' km * yozildi ' || v_km.km || ' km');
      end if;
    end if;
  end if;

  -- ---- KM UZLUKSIZLIGI (AI'dan mustaqil — mashina_km_yoz hisoblagan) ----
  if v_km_found then
    if v_km.oldingi_km is not null and v_km.km < v_km.oldingi_km then
      v_shubhali := true;
      v_sabab := v_sabab || ('km orqaga: ' || v_km.oldingi_km || ' -> ' || v_km.km);
    end if;
    if v_km.yurgan_km is not null and v_km.yurgan_km > 2000 then
      v_shubhali := true;
      v_sabab := v_sabab || ('km sakrashi: ' || v_km.yurgan_km || ' km');
    end if;
  end if;

  update entry
     set shubhali          = v_shubhali,
         shubhali_sabab    = nullif(array_to_string(v_sabab, ' * '), ''),
         ai_holat          = v_holat,
         ai_tekshirildi_at = now()
   where id = p_entry;
end $fn$;

revoke all on function rasm_shubhali_hisobla(uuid) from public, anon;
grant execute on function rasm_shubhali_hisobla(uuid) to authenticated;   -- trigger + RPC ichidan

comment on function rasm_shubhali_hisobla(uuid) is
  'YAGONA hisoblash manbai: entry.shubhali/shubhali_sabab/ai_holat ni chek + spidometr AI + '
  'km uzluksizligidan qayta hisoblaydi. entry/rasm_tahlil/entry_line triggerlari va '
  'entry_ai_bogla/mashina_km_yoz RPC lari shuni chaqiradi (idempotent).';

-- --- 4a. entry AFTER INSERT/UPDATE OF rasm_tahlil_id, spidometr_tahlil_id ---
create or replace function trg_entry_ai_hisobla_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  perform rasm_shubhali_hisobla(new.id);
  return null;   -- AFTER trigger
end $fn$;

drop trigger if exists trg_entry_ai_hisobla on entry;
create trigger trg_entry_ai_hisobla
  after insert or update of rasm_tahlil_id, spidometr_tahlil_id on entry
  for each row execute function trg_entry_ai_hisobla_fn();

-- --- 4b. rasm_tahlil AFTER INSERT/UPDATE — bogliq entry(lar)ni qayta hisobla ---
create or replace function trg_rasm_tahlil_hisobla_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare r record;
begin
  for r in
    select id from entry
     where rasm_tahlil_id = new.id or spidometr_tahlil_id = new.id
  loop
    perform rasm_shubhali_hisobla(r.id);
  end loop;
  return null;   -- AFTER trigger
end $fn$;

drop trigger if exists trg_rasm_tahlil_hisobla on rasm_tahlil;
create trigger trg_rasm_tahlil_hisobla
  after insert or update on rasm_tahlil
  for each row execute function trg_rasm_tahlil_hisobla_fn();

-- --- 4c. entry_line AFTER INSERT (xarajat satri) — summa keyin kelsa ham ---
-- Faqat AI allaqachon biriktirilgan yozuvda ishlaydi (aks holda hech narsa
-- hisoblanadigan narsa yoq — ortiqcha yozuv/tezlik yoqotilmasin).
create or replace function trg_entry_line_ai_hisobla_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_type   text;
  v_has_ai boolean;
begin
  if new.debit is null or new.debit <= 0 then
    return null;
  end if;

  select a.type into v_type from accounts a where a.id = new.account_id;
  if v_type is distinct from 'xarajat' then
    return null;
  end if;

  select (rasm_tahlil_id is not null or spidometr_tahlil_id is not null)
    into v_has_ai
    from entry where id = new.entry_id;

  if coalesce(v_has_ai, false) then
    perform rasm_shubhali_hisobla(new.entry_id);
  end if;
  return null;
end $fn$;

drop trigger if exists trg_entry_line_ai_hisobla on entry_line;
create trigger trg_entry_line_ai_hisobla
  after insert on entry_line
  for each row execute function trg_entry_line_ai_hisobla_fn();


-- #####################################################################
-- ##  5-BO'LIM — entry_ai_bogla(uuid,uuid,uuid) — klient RPC          ##
-- #####################################################################
-- Egalik tekshiruvi `xm_entry_yoz_ok()` orqali QAYTA ISHLATILADI (bir xil
-- qoida ikki joyda ikki xil bolib qolmasin): ochirilmagan + (admin | ozi
-- yozgan yozuv) + entry_line hisoblarida amaliyot ruxsati.
create or replace function entry_ai_bogla(p_entry uuid, p_tahlil uuid, p_spidometr uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_owner uuid;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if p_entry is null then
    raise exception 'Yozuv tanlanmadi' using errcode = '22000';
  end if;
  if p_tahlil is null and p_spidometr is null then
    raise exception 'Tahlil id kerak' using errcode = '22000';
  end if;

  if not xm_entry_yoz_ok(p_entry) then
    raise exception 'Bu yozuvga rasm tahlil biriktirish huquqingiz yoq' using errcode = '42501';
  end if;

  -- Begona tahlilni bogilab bolmaydi. Tahlil hali kelmagan bolsa (EF fonda
  -- ishlayapti) — egalik tekshirilmaydi, id baribir yoziladi (kutilmoqda).
  if p_tahlil is not null then
    select user_id into v_owner from rasm_tahlil where id = p_tahlil;
    if found and v_owner is distinct from v_uid and not is_admin() then
      raise exception 'Begona tahlilni biriktirib bolmaydi' using errcode = '42501';
    end if;
  end if;
  if p_spidometr is not null then
    select user_id into v_owner from rasm_tahlil where id = p_spidometr;
    if found and v_owner is distinct from v_uid and not is_admin() then
      raise exception 'Begona tahlilni biriktirib bolmaydi' using errcode = '42501';
    end if;
  end if;

  update entry
     set rasm_tahlil_id      = coalesce(p_tahlil, rasm_tahlil_id),
         spidometr_tahlil_id = coalesce(p_spidometr, spidometr_tahlil_id)
   where id = p_entry;
  if not found then
    raise exception 'Yozuv topilmadi' using errcode = '22000';
  end if;

  perform rasm_shubhali_hisobla(p_entry);
end $fn$;

revoke all on function entry_ai_bogla(uuid, uuid, uuid) from public, anon;
grant execute on function entry_ai_bogla(uuid, uuid, uuid) to authenticated;

comment on function entry_ai_bogla(uuid, uuid, uuid) is
  'Klient RPC: chek/spidometr AI tahlil id sini yozuvga bogilaydi. Egalik — xm_entry_yoz_ok() '
  '(pul guardi bilan bir xil qoida). Tahlil hali kelmagan bolsa ham id yoziladi (ai_holat=kutilmoqda).';


-- #####################################################################
-- ##  6-BO'LIM — mashina_km_yoz(uuid,uuid,int,uuid) (jadval 3.5-BOLIMda) ##
-- #####################################################################

create or replace function mashina_km_yoz(p_entry uuid, p_mashina uuid, p_km int, p_tahlil uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid := auth.uid();
  v_sana    date;
  v_prev_km int;    -- 🔴 SKALAR, "record" EMAS: 0 qator qaytsa generic record
                     --    "is not assigned yet" xato beradi, skalar esa null boladi.
  v_summa   numeric;
  v_yurgan  int;
  v_som     numeric;
  v_id      uuid;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if p_entry is null or p_mashina is null or p_km is null then
    raise exception 'Yozuv, mashina va km kerak' using errcode = '22000';
  end if;
  if p_km < 0 then
    raise exception 'Km manfiy bololmaydi' using errcode = '22000';
  end if;

  if not exists (select 1 from xarajat_royxat_element where id = p_mashina and is_active) then
    raise exception 'Mashina topilmadi yoki ochirilgan' using errcode = '22000';
  end if;

  -- Egalik — xm_entry_yoz_ok() bilan BIR XIL qoida (5-BOLIM naqshi).
  if not xm_entry_yoz_ok(p_entry) then
    raise exception 'Bu yozuvga km yozish huquqingiz yoq' using errcode = '42501';
  end if;

  select entry_date into v_sana from entry where id = p_entry;
  if not found then
    raise exception 'Yozuv topilmadi' using errcode = '22000';
  end if;

  -- Shu mashina uchun eng oxirgi yozuv (o'zidan tashqari): sana, keyin created_at.
  select mk.km into v_prev_km
    from mashina_km mk
   where mk.mashina_element_id = p_mashina
     and mk.entry_id <> p_entry
   order by mk.sana desc, mk.created_at desc
   limit 1;

  v_yurgan := case when v_prev_km is not null then p_km - v_prev_km else null end;

  select coalesce(sum(l.debit), 0) into v_summa
    from entry_line l join accounts a on a.id = l.account_id
   where l.entry_id = p_entry and l.debit > 0 and a.type = 'xarajat';

  v_som := case when v_yurgan is not null and v_yurgan > 0
                then round(coalesce(v_summa, 0) / v_yurgan, 2)
                else null end;

  insert into mashina_km (entry_id, mashina_element_id, km, sana, rasm_tahlil_id, user_id,
                          oldingi_km, yurgan_km, som_per_km)
  values (p_entry, p_mashina, p_km, coalesce(v_sana, current_date), p_tahlil, v_uid,
          v_prev_km, v_yurgan, v_som)
  on conflict (entry_id) do update
     set mashina_element_id = excluded.mashina_element_id,
         km                 = excluded.km,
         sana               = excluded.sana,
         rasm_tahlil_id     = excluded.rasm_tahlil_id,
         oldingi_km         = excluded.oldingi_km,
         yurgan_km          = excluded.yurgan_km,
         som_per_km         = excluded.som_per_km
  returning id into v_id;

  perform rasm_shubhali_hisobla(p_entry);

  return v_id;
end $fn$;

revoke all on function mashina_km_yoz(uuid, uuid, int, uuid) from public, anon;
grant execute on function mashina_km_yoz(uuid, uuid, int, uuid) to authenticated;

comment on function mashina_km_yoz(uuid, uuid, int, uuid) is
  'Km yozuvi (entry ustiga upsert, unique entry_id). oldingi_km/yurgan_km/som_per_km avtomat hisoblanadi. '
  'km < oldingi yoki yurgan_km > 2000 bolsa BLOKLAMAYDI — rasm_shubhali_hisobla shubhali qiladi.';


-- #####################################################################
-- ##  7-BO'LIM — v_shubhali, v_mashina_samara (FAQAT ADMIN)           ##
-- #####################################################################
-- Ikkalasi ham WHERE is_admin() bilan gate qilingan — noadmin 0 qator
-- oladi (hodim hech narsa kormaydi talabi). Hodim ismi ornida KASSA NOMI
-- ishlatiladi (ijrochi_nomi() authenticated uchun revoke qilingan —
-- security_invoker view uni chaqira olmaydi).

create or replace view v_shubhali as
select
  e.id                  as entry_id,
  e.entry_date,
  e.description,
  k.name                as kassa_nomi,
  k.code                as kassa_kod,
  coalesce(sm.summa, 0) as summa,
  e.shubhali,
  e.shubhali_sabab,
  e.ai_holat,
  e.ai_tekshirildi_at,
  rt.tur                as tahlil_turi,
  rt.holat               as tahlil_holat,
  rt.ishonch,
  rt.ai_summa,
  rt.ai_sana,
  rt.ai_km,
  rt.storage_path
  from entry e
  left join lateral (
    select sum(l.debit) as summa
      from entry_line l
      join accounts a on a.id = l.account_id
     where l.entry_id = e.id and l.debit > 0 and a.type = 'xarajat'
  ) sm on true
  left join lateral (
    select a.name, a.code
      from entry_line l
      join accounts a on a.id = l.account_id
     where l.entry_id = e.id and l.credit > 0
     limit 1
  ) k on true
  left join rasm_tahlil rt on rt.id = coalesce(e.rasm_tahlil_id, e.spidometr_tahlil_id)
 where is_admin()
   and (e.shubhali or e.ai_holat in ('yoq', 'xato'));

alter view v_shubhali set (security_invoker = on);
revoke all on v_shubhali from public, anon;
grant select on v_shubhali to authenticated;

comment on view v_shubhali is
  'Admin: shubhali (yoki AI tekshira olmagan) xarajat yozuvlari. Fail-closed: is_admin() emas bolsa 0 qator.';

create or replace view v_mashina_samara as
select
  el.id                                                    as mashina_id,
  el.nom                                                    as mashina_nomi,
  el.qiymat                                                 as mashina_qiymat,
  date_trunc('month', mk.sana)::date                        as oy,
  sum(coalesce(mk.yurgan_km, 0))                            as yurgan_km,
  sum(coalesce(sm.summa, 0))                                as som,
  case when sum(coalesce(mk.yurgan_km, 0)) > 0
       then round(sum(coalesce(sm.summa, 0)) / sum(mk.yurgan_km), 2)
       else null end                                        as som_per_km,
  count(*)                                                  as yozuvlar_soni
  from mashina_km mk
  join xarajat_royxat_element el on el.id = mk.mashina_element_id
  left join lateral (
    select sum(l.debit) as summa
      from entry_line l
      join accounts a on a.id = l.account_id
     where l.entry_id = mk.entry_id and l.debit > 0 and a.type = 'xarajat'
  ) sm on true
 where is_admin()
 group by el.id, el.nom, el.qiymat, date_trunc('month', mk.sana);

alter view v_mashina_samara set (security_invoker = on);
revoke all on v_mashina_samara from public, anon;
grant select on v_mashina_samara to authenticated;

comment on view v_mashina_samara is
  'Admin: mashina x oy — yurgan km, som, som/km, yozuvlar soni. Fail-closed: is_admin() emas bolsa 0 qator.';


-- #####################################################################
-- ##  8-BO'LIM — storage bucket rasm-tahlil (private) + RLS           ##
-- #####################################################################
-- Yol nashqi: {user_id}/{tahlil_id}.jpg (HODIM_V3 dagi {kassa_id}/{entry_id}.jpg
-- naqshiga oxshash, faqat 1-papka bu yerda user_id). INSERT policy YOQ —
-- faqat Edge Function (service_role) yuklaydi.

insert into storage.buckets (id, name, public)
values ('rasm-tahlil', 'rasm-tahlil', false)
on conflict (id) do nothing;

drop policy if exists "rasm_tahlil_bucket_select" on storage.objects;
create policy "rasm_tahlil_bucket_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'rasm-tahlil'
    and (
      is_admin()
      or (
        (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
        and ((storage.foldername(name))[1])::uuid = (select auth.uid())
      )
    )
  );
-- insert/update/delete policy ATAYLAB YOQ — faqat service_role (RLS'ni bypass qiladi).


-- #####################################################################
-- ##  9-BO'LIM — YAKUNIY TEKSHIRUV (faqat select/katalog)             ##
-- #####################################################################

select column_name, data_type
  from information_schema.columns
 where table_schema = 'public' and table_name = 'accounts'
   and column_name in ('ai_tekshir', 'spidometr_ai')
 order by column_name;

select to_regclass('public.rasm_tahlil')    is not null as t_rasm_tahlil,
       to_regclass('public.mashina_km')     is not null as t_mashina_km,
       to_regprocedure('public.entry_ai_bogla(uuid,uuid,uuid)')      is not null as fn_entry_ai_bogla,
       to_regprocedure('public.mashina_km_yoz(uuid,uuid,int,uuid)')  is not null as fn_mashina_km_yoz,
       to_regprocedure('public.rasm_shubhali_hisobla(uuid)')         is not null as fn_hisobla,
       to_regprocedure('public.set_modda_flag(uuid,text,boolean)')   is not null as fn_set_modda_flag,
       to_regclass('public.v_shubhali')        is not null as v_shubhali_bor,
       to_regclass('public.v_mashina_samara')  is not null as v_mashina_samara_bor;

-- entry ustunlari borligini tekshirish
select column_name, data_type
  from information_schema.columns
 where table_schema = 'public' and table_name = 'entry'
   and column_name in ('rasm_tahlil_id', 'spidometr_tahlil_id', 'shubhali', 'shubhali_sabab',
                        'ai_holat', 'ai_tekshirildi_at')
 order by column_name;

-- policy sanog'i (rasm_tahlil FAQAT 1 ta select policy bolishi kerak — tamper-proof)
select tablename, policyname, cmd
  from pg_policies
 where schemaname = 'public' and tablename in ('rasm_tahlil', 'mashina_km')
 order by tablename, cmd;

select to_regclass('storage.objects') is not null as storage_bor,
       exists(select 1 from storage.buckets where id = 'rasm-tahlil') as bucket_bor;

notify pgrst, 'reload schema';


-- =====================================================================
-- KONTRAKTLAR (klient/EF uchun, RPC kirish-chiqishi)
-- ---------------------------------------------------------------------
-- Klient (hodim.html/professional.html) rasm yuklashda:
--   1) chek/spidometr rasmini olgach, klient `crypto.randomUUID()` bilan
--      tahlil id sini OLDINDAN generatsiya qiladi.
--   2) rasmni Storage `rasm-tahlil` bucketiga TOG'RIDAN yuklamaydi (bucket
--      insert policy yoq) — rasm EF ga base64/multipart bilan yuboriladi,
--      EF ozi Storage ga (service_role) yozadi va `storage_path` ni
--      shu yolga qoyadi: `{user_id}/{tahlil_id}.jpg`.
--   3) klient darrov `entry_ai_bogla(p_entry, p_tahlil_id, null)` (chek)
--      yoki `entry_ai_bogla(p_entry, null, p_tahlil_id)` (spidometr) ni
--      chaqiradi — tahlil hali kelmagan bolsa ham ai_holat='kutilmoqda'
--      bolib qoladi, EF yozgach trigger avtomat qayta hisoblaydi.
--   4) mashina tanlangan bolsa: `mashina_km_yoz(p_entry, p_mashina_element_id,
--      p_km, p_spidometr_tahlil_id)`.
--
-- Edge Function (keyingi bosqich) `rasm_tahlil` ga YOZADIGAN ustunlar:
--   id            — klientdan kelgan tahlil id (OLDINDAN generatsiya qilingan)
--   user_id       — auth.uid() (JWT dan, EF service_role bilan ishlagani
--                   uchun bu ustunni EF ozi tuldiradi — auth.uid() null bolardi)
--   tur           — 'chek' | 'spidometr'
--   storage_path  — '{user_id}/{id}.jpg'
--   natija        — Claude ning toliq javobi (jsonb): kamida
--                   {"ishonch": 0..1, "muammo": text|null, "summa": number|null,
--                    "sana": "YYYY-MM-DD"|null, "km": int|null}
--   ai_summa, ai_sana, ai_km — natija dan ozi ajratib yozadi (qulaylik uchun,
--                   filtr/JOIN tez bolsin — natija baribir toliq saqlanadi)
--   ishonch       — natija->>ishonch (trigger baribir qayta hisoblaydi)
--   model         — masalan 'claude-sonnet-5'
--   holat         — 'ok' | 'xato' | 'chek_emas'
--   xato          — xato bolsa matn (foydalanuvchiga korsatish uchun EMAS —
--                   ichki log, hodim buni kormaydi)
--
-- =====================================================================
-- ROLLBACK (kerak bolsa, Asilbek qollab RUN qiladi — hech narsa avtomat emas)
-- ---------------------------------------------------------------------
-- drop trigger if exists trg_entry_line_ai_hisobla on entry_line;
-- drop trigger if exists trg_rasm_tahlil_hisobla on rasm_tahlil;
-- drop trigger if exists trg_entry_ai_hisobla on entry;
-- drop trigger if exists trg_rasm_tahlil_aniq on rasm_tahlil;
-- drop function if exists trg_entry_line_ai_hisobla_fn();
-- drop function if exists trg_rasm_tahlil_hisobla_fn();
-- drop function if exists trg_entry_ai_hisobla_fn();
-- drop function if exists trg_rasm_tahlil_aniq_fn();
-- drop function if exists mashina_km_yoz(uuid, uuid, int, uuid);
-- drop function if exists entry_ai_bogla(uuid, uuid, uuid);
-- drop function if exists rasm_shubhali_hisobla(uuid);
-- drop view if exists v_mashina_samara;
-- drop view if exists v_shubhali;
-- drop table if exists mashina_km;
-- -- entry ustunlarini OLIB TASHLASH TAQIQ (CLAUDE.md) — faqat qoldiring.
-- drop policy if exists "rasm_tahlil_bucket_select" on storage.objects;
-- drop table if exists rasm_tahlil;
-- -- accounts.ai_tekshir / spidometr_ai ustunlarini OLIB TASHLASH TAQIQ — faqat qoldiring.
-- -- set_modda_flag 'ai'/'spidometr' shoxlarini olib tashlash uchun PROVODKA_OVQAT.sql dagi
-- -- versiyani qayta RUN qiling (o'sha shoxlarsiz qaytadi).
-- =====================================================================
