-- =====================================================================
-- PROVODKA_EHSON_ZAKOT.sql — Ehson jamg'armasi: 3 child jamg'arma
-- (Ehson soliq · Ehson asosiy · Zakot) + dinamik pul turi (naqd/dollar/
-- karta/click) — 2026-09-07
-- ---------------------------------------------------------------------
-- Brief: ARX_PROVODKA_EHSON_ZAKOT.md (Asilbek: "bu faqat zakot uchun
-- bo'ladi — esingdan chiqarma"). Bu fayl PROVODKA_EHSON.sql ustiga
-- QO'SHILADI (additive) — hech narsa o'chirilmaydi, imzolar saqlanadi.
--
-- ## RUN TARTIBI — butun faylni birdaniga RUN qilish mumkin.
--   0-BOLIM   — old shart tekshiruvi (faqat select/raise)
--   2.1-BOLIM — ehson_kassa: parent_id/is_container/tartib + _ehson_xarajat_modda
--               qayta e'lon (parent nomi prefiksi) + ildiz konteyner + 3 child seed
--   2.2-BOLIM — ehson_pul_turi jadvali (dinamik pul turi) + har child uchun 4 ta seed
--   2.3-BOLIM — ustunlar: ehson_kirim/ehson_berish pul_turi/valyuta/fc_summa,
--               entry.ehson_pul_turi
--   2.4-BOLIM — _ehson_kirim_sync qayta e'lon (pul_turi taxmin/entry'dan + valyuta/fc_summa)
--   2.5-BOLIM — v_ehson_kassa_pul view + ehson_kassa_daraxt() RPC
--   2.6-BOLIM — ehson_ber qayta e'lon (pul_turi/dollar/kurs/qoldiq pul turi kesimida)
--   2.7-BOLIM — ehson_dash / ehson_kirim_royxat / ehson_berish_royxat qayta e'lon
--   2.8-BOLIM — ehson_tarix.obyekt CHECK kengaytirish + ehson_kassa_saqla +
--               ehson_pul_turi_saqla (admin)
--   10-BOLIM  — PostgREST sxema keshi
--   11-BOLIM  — YAKUNIY TEKSHIRUV (faqat select)
--
-- ## OLD SHART (PROVODKA_EHSON.sql RUN qilingan bo'lishi kerak)
--   ehson_kassa, _ehson_xarajat_modda(uuid), _ehson_kirim_sync(uuid),
--   ehson_ber(jsonb), ehson_dash(), ehson_kirim_royxat(jsonb),
--   ehson_berish_royxat(jsonb).
--
-- ## ADDITIVE KAFOLATI
--   * Hech narsa drop qilinmaydi. Qayta yoziladigan obyektlar — faqat shu
--     faylda sanab o'tilganlar, imzolari (argument/tur) O'ZGARMAYDI.
--   * `to_regprocedure` ISHLATILMAYDI (Supabase editorida ba'zan null
--     berdi) — funksiya mavjudligi `pg_proc` + `pg_namespace` +
--     `oidvectortypes(proargtypes)` bilan tekshiriladi.
--   * Anonim `do` bloki YO'Q — har `do` bloki NOMLANGAN teg bilan (ez_ prefiksi).
--     Funksiya tanasi nomlangan teg bilan o'raladi. Izohlarda dollar belgi
--     ikkitalab yonma-yon YOZILMAGAN (soxta blok xavfi).
--   * Idempotent: `add column if not exists`, `create or replace function`,
--     `create table if not exists`, `drop policy if exists` + `create policy`,
--     seed `where not exists` / `on conflict do nothing`.
--
-- ## IZOLYATSIYA (PROVODKA_EHSON.sql 12-BOLIM bilan bir xil qoida)
--   Bu fayl ham buxgalteriya jadvallariga (entry/entry_line) YOZMAYDI —
--   faqat entry.ehson_pul_turi ustunini QO'SHADI (Professional kaskadi
--   uchun, ixtiyoriy) va _ehson_kirim_sync orqali O'QIYDI. Kirim hamon
--   FAQAT jurnal orqali (Dt ehson moddasi / Kt kassa) — Ehson ichida
--   kirim yozish yo'li ochilmaydi. Berish/jamg'arma boshqaruvi FAQAT
--   ehson_* jadvallarida, kompaniya balansiga ta'sir yo'q.
-- =====================================================================


-- #####################################################################
-- ##  0-BOLIM — OLD SHART TEKSHIRUVI (faqat select/raise)             ##
-- #####################################################################

do $ez_pre$
declare
  v_ok boolean;
begin
  if to_regclass('public.ehson_kassa') is null then
    raise exception 'ehson_kassa jadvali yoq — avval PROVODKA_EHSON.sql ni bajaring';
  end if;

  select exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = '_ehson_xarajat_modda'
       and oidvectortypes(pr.proargtypes) = 'uuid'
  ) into v_ok;
  if not v_ok then
    raise exception '_ehson_xarajat_modda(uuid) yoq — avval PROVODKA_EHSON.sql ni bajaring';
  end if;

  select exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = '_ehson_kirim_sync'
       and oidvectortypes(pr.proargtypes) = 'uuid'
  ) into v_ok;
  if not v_ok then
    raise exception '_ehson_kirim_sync(uuid) yoq — avval PROVODKA_EHSON.sql ni bajaring';
  end if;

  select exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = 'ehson_ber'
       and oidvectortypes(pr.proargtypes) = 'jsonb'
  ) into v_ok;
  if not v_ok then
    raise exception 'ehson_ber(jsonb) yoq — avval PROVODKA_EHSON.sql ni bajaring';
  end if;

  select exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = 'ehson_dash'
       and oidvectortypes(pr.proargtypes) = ''
  ) into v_ok;
  if not v_ok then
    raise exception 'ehson_dash() yoq — avval PROVODKA_EHSON.sql ni bajaring';
  end if;

  select exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = 'ehson_kirim_royxat'
       and oidvectortypes(pr.proargtypes) = 'jsonb'
  ) into v_ok;
  if not v_ok then
    raise exception 'ehson_kirim_royxat(jsonb) yoq — avval PROVODKA_EHSON.sql ni bajaring';
  end if;

  select exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = 'ehson_berish_royxat'
       and oidvectortypes(pr.proargtypes) = 'jsonb'
  ) into v_ok;
  if not v_ok then
    raise exception 'ehson_berish_royxat(jsonb) yoq — avval PROVODKA_EHSON.sql ni bajaring';
  end if;
end
$ez_pre$;


-- #####################################################################
-- ##  2.1-BOLIM — ehson_kassa: parent_id/is_container/tartib +        ##
-- ##  _ehson_xarajat_modda qayta e'lon + ildiz konteyner + 3 child    ##
-- #####################################################################

alter table ehson_kassa add column if not exists parent_id    uuid references ehson_kassa(id);
alter table ehson_kassa add column if not exists is_container boolean not null default false;
alter table ehson_kassa add column if not exists tartib       integer not null default 0;

create index if not exists ehson_kassa_parent_idx on ehson_kassa (parent_id);

comment on column ehson_kassa.parent_id    is 'Ildiz jamg''arma (is_container=true) -> child jamg''arma. Ildizning o''zida null.';
comment on column ehson_kassa.is_container is 'true = konteyner (yangi kirim/berish yozilmaydi, faqat childlari orqali). v1 ildiz "Ehson jamg''armasi" shunday belgilandi.';
comment on column ehson_kassa.tartib       is 'Ko''rsatish tartibi (kichik oldin).';

-- _ehson_xarajat_modda(p_kassa) qayta e'lon — IMZO SAQLANADI (uuid -> uuid).
-- Yagona farq: modda nomi endi parentga qarab tanlanadi — child (parent_id bor)
-- uchun "<ildiz nomi> · <child nomi>" (masalan "Ehson jamg'armasi · Zakot"),
-- ildizning o'zi (parent_id yo'q) uchun ESKI qoida o'zgarmagan (nomida "ehson"
-- bo'lsa o'zi, aks holda "Ehson: <nom>") — mavjud ildiz moddasiga TEGILMAYDI,
-- chunki mavjud bog'langan hisob (v_acc) bo'lsa funksiya uni darrov qaytaradi,
-- nomni QAYTA YOZMAYDI.
create or replace function _ehson_xarajat_modda(p_kassa uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_acc        uuid;
  v_nom        text;
  v_parent_id  uuid;
  v_parent_nom text;
  v_max        int;
  v_code       text;
  v_modda_nom  text;
begin
  select k.xarajat_account_id, k.nom, k.parent_id into v_acc, v_nom, v_parent_id
    from ehson_kassa k where k.id = p_kassa;

  if v_parent_id is not null then
    select p.nom into v_parent_nom from ehson_kassa p where p.id = v_parent_id;
  end if;

  if v_parent_nom is not null then
    v_modda_nom := v_parent_nom || ' · ' || coalesce(v_nom, 'jamg''arma');
  elsif lower(coalesce(v_nom, '')) like '%ehson%' then
    v_modda_nom := v_nom;
  else
    v_modda_nom := 'Ehson: ' || coalesce(v_nom, 'jamg''arma');
  end if;

  if v_acc is not null and exists (select 1 from accounts a where a.id = v_acc and coalesce(a.is_active, true)) then
    update accounts set ehson_kassa_id = p_kassa where id = v_acc and ehson_kassa_id is distinct from p_kassa;
    return v_acc;
  end if;
  -- Nomi bo'yicha mavjud modda (qayta RUN / qo'lda ochilgan bo'lsa)
  select a.id into v_acc from accounts a
   where a.type = 'xarajat' and coalesce(a.is_active, true)
     and lower(a.name) = lower(v_modda_nom)
   limit 1;
  if v_acc is null then
    perform pg_advisory_xact_lock(hashtext('ehson_xarajat_modda'));
    select max(code::int) into v_max from accounts where code ~ '^94[0-9]{2}$';
    v_code := (coalesce(v_max, 9420) + 1)::text;
    if v_code::int > 9499 then
      raise exception 'Xarajat moddalari kod bloki (9421–9499) to''ldi';
    end if;
    insert into accounts (code, name, type, section, is_active, ehson_kassa_id)
    values (v_code, v_modda_nom, 'xarajat', 'operatsion', true, p_kassa)
    returning id into v_acc;
  end if;
  update accounts set ehson_kassa_id = p_kassa where id = v_acc and ehson_kassa_id is distinct from p_kassa;
  update ehson_kassa set xarajat_account_id = v_acc where id = p_kassa;
  return v_acc;
end
$fn$;

revoke all on function _ehson_xarajat_modda(uuid) from public, anon, authenticated;

comment on function _ehson_xarajat_modda(uuid) is
  'ICHKI: jamg''arma uchun xarajat moddasi (94xx) — bor bo''lsa qaytaradi, yo''q bo''lsa ochadi. '
  'Child kassa (parent_id bor) uchun modda nomi "<ildiz nomi> · <child nomi>". Mavjud bog''langan moddaga tegmaydi.';

-- Ildizni konteyner qilish + 3 ta child jamg'arma (idempotent, nom bo'yicha).
do $ez_root_seed$
declare
  v_root uuid;
  v_seed record;
  v_kid  record;
begin
  select id into v_root from ehson_kassa
   where parent_id is null
   order by (nom ilike 'Ehson jamg%') desc, created_at asc
   limit 1;

  if v_root is null then
    raise notice 'ehson_kassa ildiz qatori topilmadi — zakot child kassalar ochilmadi (avval PROVODKA_EHSON.sql ni bajaring)';
    return;
  end if;

  update ehson_kassa set is_container = true
   where id = v_root and not is_container;

  for v_seed in
    select * from (values
      ('Ehson soliq',  1),
      ('Ehson asosiy', 2),
      ('Zakot',        3)
    ) as t(nom, tartib)
  loop
    if not exists (select 1 from ehson_kassa where parent_id = v_root and lower(nom) = lower(v_seed.nom)) then
      insert into ehson_kassa (nom, parent_id, is_active, tartib)
      values (v_seed.nom, v_root, true, v_seed.tartib);
    end if;
  end loop;

  for v_kid in select id from ehson_kassa where parent_id = v_root and is_active loop
    perform _ehson_xarajat_modda(v_kid.id);
  end loop;
end
$ez_root_seed$;


-- #####################################################################
-- ##  2.2-BOLIM — ehson_pul_turi (dinamik pul turi, admin) + seed     ##
-- #####################################################################

create table if not exists ehson_pul_turi (
  id         uuid        primary key default gen_random_uuid(),
  kassa_id   uuid        not null references ehson_kassa(id),
  kod        text        not null check (kod ~ '^[a-z_]{2,20}$'),
  nom        text        not null,
  valyuta    text        not null default 'UZS',
  is_active  boolean     not null default true,
  tartib     int         not null default 0,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (kassa_id, kod)
);

comment on table ehson_pul_turi is
  'Jamg''arma kassasi (ehson_kassa) ichidagi pul turi (naqd/dollar/karta/click, dinamik, admin boshqaradi). '
  'Provodka accounts bilan bog''lanmagan — faqat Ehson ichki hisob-kitobi uchun.';

create index if not exists ehson_pul_turi_kassa_idx on ehson_pul_turi (kassa_id);

alter table ehson_pul_turi enable row level security;
revoke all on table ehson_pul_turi from public, anon;
grant select on table ehson_pul_turi to authenticated;

drop policy if exists ehson_pul_turi_select on ehson_pul_turi;
create policy ehson_pul_turi_select on ehson_pul_turi
  for select to authenticated
  using (ehson_page_ok() or ehson_kirim_ok());

-- Har faol child uchun 4 ta sukut pul turi (idempotent). 4 ta FAOL borligi
-- FAQAT shu seed paytida `raise notice` bilan ma''lum qilinadi (qattiq
-- tekshiruv EMAS) — admin keyinroq birortasini deaktiv qilsa, fayl qayta
-- RUN qilinganda bu blok xato bermaydi (additive falsafa).
do $ez_pt_seed$
declare
  v_kassa record;
  v_cnt   int;
begin
  for v_kassa in select id, nom from ehson_kassa where parent_id is not null and is_active loop
    insert into ehson_pul_turi (kassa_id, kod, nom, valyuta, tartib)
    select v_kassa.id, x.kod, x.nom, x.valyuta, x.tartib
      from (values
        ('naqd',   'Naqd',   'UZS', 1),
        ('dollar', 'Dollar', 'USD', 2),
        ('karta',  'Karta',  'UZS', 3),
        ('click',  'Click',  'UZS', 4)
      ) as x(kod, nom, valyuta, tartib)
     on conflict (kassa_id, kod) do nothing;

    select count(*) into v_cnt from ehson_pul_turi where kassa_id = v_kassa.id and is_active;
    if v_cnt < 4 then
      raise notice 'Ehson kassa "%": faol pul turi % ta (4 tadan kam bo''lishi mumkin — admin keyinroq o''zgartirgan, xato emas)', v_kassa.nom, v_cnt;
    end if;
  end loop;
end
$ez_pt_seed$;


-- #####################################################################
-- ##  2.3-BOLIM — ustunlar: ehson_kirim/ehson_berish pul_turi/        ##
-- ##  valyuta/fc_summa, entry.ehson_pul_turi                          ##
-- #####################################################################

alter table ehson_kirim  add column if not exists pul_turi text;
alter table ehson_kirim  add column if not exists valyuta  text;
alter table ehson_kirim  add column if not exists fc_summa numeric;

alter table ehson_berish add column if not exists pul_turi text;
alter table ehson_berish add column if not exists valyuta  text;
alter table ehson_berish add column if not exists fc_summa numeric;

alter table entry add column if not exists ehson_pul_turi text;

comment on column ehson_kirim.pul_turi   is 'ehson_pul_turi.kod (naqd/dollar/karta/click...). entry.ehson_pul_turi''dan yoki Kt kassadan taxmin (_ehson_kirim_sync).';
comment on column ehson_kirim.valyuta    is 'Kt pul qatori valyutasi (UZS/USD/...).';
comment on column ehson_kirim.fc_summa   is 'Valyutadagi summa (USD bo''lsa) — entry_line.fc_amount.';
comment on column ehson_berish.pul_turi  is 'ehson_pul_turi.kod — qaysi pul turidan berildi.';
comment on column ehson_berish.valyuta   is 'Berish valyutasi (UZS/USD).';
comment on column ehson_berish.fc_summa  is 'Dollar tanlansa USD miqdori (ehson_ber orqali).';
comment on column entry.ehson_pul_turi   is 'Professional kaskadida tanlangan ehson_pul_turi.kod (ixtiyoriy) — _ehson_kirim_sync shundan o''qiydi, bo''lmasa Kt kassadan taxmin qiladi.';


-- #####################################################################
-- ##  2.4-BOLIM — _ehson_kirim_sync qayta e'lon (pul_turi/valyuta/    ##
-- ##  fc_summa)                                                       ##
-- #####################################################################
-- IMZO SAQLANADI (uuid -> void). Eski mantiq (12.3) to'liq saqlanadi,
-- ustiga pul_turi/valyuta/fc_summa qo'shiladi: avval entry.ehson_pul_turi
-- (Professional kaskadi tanlagan), aks holda Kt pul qatoridan taxmin
-- (currency='USD' -> dollar; pul_turi click/payme -> click; aks holda
-- naqd) — FAQAT shu jamg'armada shu kod FAOL bo'lsa, aks holda null
-- ("belgilanmagan").
create or replace function _ehson_kirim_sync(p_entry uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_e       entry%rowtype;
  k         record;
  v_summa   numeric;
  v_pul     uuid;
  v_fc      numeric;
  v_cur     text;
  v_ptur    text;
  v_turi    text;
  v_valyuta text;
  v_fc_out  numeric;
  v_row     ehson_kirim;
  v_id      uuid;
  v_faol    boolean;
  v_cb      uuid;
begin
  if p_entry is null then return; end if;
  select * into v_e from entry where id = p_entry;
  -- 🔴 2026-09-07 (Asilbek testi): entry.created_by TEXT (ism yoki uuid matni), ehson_kirim.created_by UUID —
  --    to'g'ridan nusxalash "column created_by is of type uuid but expression is of type text" bilan yiqilardi,
  --    trigger esa xatoni raise warning bilan yutib yuborardi → jurnal orqali kirim HECH QACHON tushmagan
  --    (asl PROVODKA_EHSON.sql da ham shu xato). entry_jadval_yoz naqshi: regex bilan xavfsiz cast, aks holda null.
  v_cb := case when (to_jsonb(v_e) ->> 'created_by') ~ '^[0-9a-fA-F-]{36}$'
               then (to_jsonb(v_e) ->> 'created_by')::uuid end;
  v_faol := found and coalesce(v_e.is_deleted, false) = false and coalesce(v_e.status, 'posted') = 'posted';

  for k in select id, xarajat_account_id from ehson_kassa where xarajat_account_id is not null loop
    select coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0) into v_summa
      from entry_line l where l.entry_id = p_entry and l.account_id = k.xarajat_account_id;

    select l.account_id, l.fc_amount, a.currency, a.pul_turi
      into v_pul, v_fc, v_cur, v_ptur
      from entry_line l join accounts a on a.id = l.account_id
     where l.entry_id = p_entry and l.credit > 0 and a.section = 'pul'
     order by l.credit desc limit 1;

    v_valyuta := coalesce(v_cur, 'UZS');
    v_fc_out  := case when v_cur = 'USD' then v_fc end;

    v_turi := null;
    if v_e.ehson_pul_turi is not null and exists (
      select 1 from ehson_pul_turi where kassa_id = k.id and kod = v_e.ehson_pul_turi and is_active
    ) then
      v_turi := v_e.ehson_pul_turi;
    else
      v_turi := case
                  when v_cur = 'USD' then 'dollar'
                  when v_ptur in ('click', 'payme') then 'click'
                  else 'naqd'
                end;
      if not exists (select 1 from ehson_pul_turi where kassa_id = k.id and kod = v_turi and is_active) then
        v_turi := null;
      end if;
    end if;

    select * into v_row from ehson_kirim where entry_id = p_entry and kassa_id = k.id;

    if v_faol and v_summa > 0 then
      if found then
        update ehson_kirim
           set summa = v_summa, sana = v_e.entry_date, izoh = v_e.description, pul_kassa_id = v_pul,
               pul_turi = v_turi, valyuta = v_valyuta, fc_summa = v_fc_out,
               is_deleted = false, deleted_by = null, deleted_at = null
         where id = v_row.id
           and (summa is distinct from v_summa or sana is distinct from v_e.entry_date
                or izoh is distinct from v_e.description or pul_kassa_id is distinct from v_pul
                or pul_turi is distinct from v_turi or valyuta is distinct from v_valyuta
                or fc_summa is distinct from v_fc_out or is_deleted);
        if found then
          perform _ehson_tarix_yoz('kirim', v_row.id, 'jurnal_yangilandi',
            jsonb_build_object('entry_id', p_entry, 'summa', v_summa, 'pul_turi', v_turi));
        end if;
      else
        insert into ehson_kirim (kassa_id, summa, sana, manba, izoh, created_by, entry_id, pul_kassa_id,
                                  ext_ref, pul_turi, valyuta, fc_summa)
        values (k.id, v_summa, v_e.entry_date, 'Jurnal', v_e.description, v_cb, p_entry, v_pul,
                'entry:' || p_entry::text || ':' || k.id::text, v_turi, v_valyuta, v_fc_out)
        returning id into v_id;
        perform _ehson_tarix_yoz('kirim', v_id, 'jurnaldan_keldi',
          jsonb_build_object('entry_id', p_entry, 'summa', v_summa, 'pul_kassa_id', v_pul, 'pul_turi', v_turi));
      end if;
    elsif found and not v_row.is_deleted then
      update ehson_kirim set is_deleted = true, deleted_at = now(), deleted_by = v_cb
       where id = v_row.id;
      perform _ehson_tarix_yoz('kirim', v_row.id, 'jurnalda_ochirildi',
        jsonb_build_object('entry_id', p_entry));
    end if;
  end loop;
end
$fn$;

revoke all on function _ehson_kirim_sync(uuid) from public, anon, authenticated;

comment on function _ehson_kirim_sync(uuid) is
  'Jurnal yozuvi (Dt ehson moddasi / Kt kassa) -> ehson_kirim avtomat, + pul_turi/valyuta/fc_summa (2026-09-07 zakot). Hech qachon entry ni to''smaydi.';

-- Mavjud ehson_kirim qatorlarini yangi ustunlar bilan bir martalik sinxronlash.
-- Backfill: (a) mavjud ehson_kirim yozuvlari; (b) 🔴 ehson moddasiga yozilgan, lekin created_by xatosi tufayli
-- ehson_kirim ga TUSHMAGAN entry'lar (2026-09-07 gacha hammasi shunday edi) — qayta sinxron.
do $ez_sync_backfill$
declare e record; n int := 0;
begin
  for e in
    select distinct l.entry_id
      from entry_line l
      join ehson_kassa k on k.xarajat_account_id = l.account_id
     union
    select distinct entry_id from ehson_kirim where entry_id is not null
  loop
    perform _ehson_kirim_sync(e.entry_id);
    n := n + 1;
  end loop;
  raise notice 'ehson kirim backfill: % ta entry qayta sinxronlandi', n;
end
$ez_sync_backfill$;


-- #####################################################################
-- ##  2.5-BOLIM — v_ehson_kassa_pul view + ehson_kassa_daraxt() RPC   ##
-- #####################################################################

create or replace view v_ehson_kassa_pul as
select
  x.kassa_id,
  x.pul_turi,
  x.valyuta,
  sum(x.kirim)                        as kirim,
  sum(x.berildi)                      as berildi,
  sum(x.kirim) - sum(x.berildi)       as qoldiq,
  sum(x.fc_kirim)                     as fc_kirim,
  sum(x.fc_berildi)                   as fc_berildi,
  sum(x.fc_kirim) - sum(x.fc_berildi) as fc_qoldiq
from (
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS') as valyuta,
         summa as kirim, 0::numeric as berildi,
         coalesce(fc_summa, 0) as fc_kirim, 0::numeric as fc_berildi
    from ehson_kirim where is_deleted = false
  union all
  select kassa_id, pul_turi, coalesce(valyuta, 'UZS') as valyuta,
         0::numeric as kirim, summa as berildi,
         0::numeric as fc_kirim, coalesce(fc_summa, 0) as fc_berildi
    from ehson_berish where holat = 'berildi'
) x
group by x.kassa_id, x.pul_turi, x.valyuta;

alter view v_ehson_kassa_pul set (security_invoker = on);
revoke all on v_ehson_kassa_pul from public, anon;
grant select on v_ehson_kassa_pul to authenticated;

comment on view v_ehson_kassa_pul is
  'Har jamg''arma + pul turi kesimida kirim/berildi/qoldiq (so''m) va fc_kirim/fc_berildi/fc_qoldiq (dollar). pul_turi null = eski/belgilanmagan yozuvlar.';

-- ehson_kassa_daraxt() — Professional kaskadi va Ehson uchun BITTA manba:
-- ildiz + har faol child (modda, qoldiq, pul turlari qoldiq bilan).
create or replace function ehson_kassa_daraxt()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_root ehson_kassa;
  v_list jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not (ehson_page_ok() or ehson_kirim_ok()) then
    raise exception 'Ehson kaskadini ko''rish ruxsatingiz yo''q' using errcode = '42501';
  end if;

  select * into v_root from ehson_kassa where is_container and is_active
   order by created_at limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', k.id, 'nom', k.nom, 'izoh', k.izoh, 'is_active', k.is_active, 'tartib', k.tartib,
           'modda', case when a.id is not null then jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name) end,
           'qoldiq', coalesce(vk.qoldiq, 0),
           'pul_turlari', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', pt.id, 'kod', pt.kod, 'nom', pt.nom, 'valyuta', pt.valyuta,
                      'is_active', pt.is_active, 'tartib', pt.tartib,
                      'qoldiq', coalesce(vp.qoldiq, 0), 'fc_qoldiq', coalesce(vp.fc_qoldiq, 0)
                    ) order by pt.tartib, pt.nom)
               from ehson_pul_turi pt
               left join v_ehson_kassa_pul vp on vp.kassa_id = pt.kassa_id and vp.pul_turi = pt.kod
              where pt.kassa_id = k.id and pt.is_active
           ), '[]'::jsonb)
         ) order by k.tartib, k.nom), '[]'::jsonb)
    into v_list
    from ehson_kassa k
    left join accounts a on a.id = k.xarajat_account_id
    left join v_ehson_kassa vk on vk.id = k.id
   where k.is_active and not k.is_container
     and (v_root.id is null or k.parent_id = v_root.id);

  return jsonb_build_object(
    'ildiz', case when v_root.id is not null then jsonb_build_object('id', v_root.id, 'nom', v_root.nom) end,
    'kassalar', coalesce(v_list, '[]'::jsonb)
  );
end
$fn$;

revoke all on function ehson_kassa_daraxt() from public, anon;
grant execute on function ehson_kassa_daraxt() to authenticated;

comment on function ehson_kassa_daraxt() is
  'Professional/Ehson kaskadi uchun: ildiz jamg''arma + har faol child kassa (modda, qoldiq, pul turlari). Ruxsat: ehson_page_ok() YOKI ehson_kirim_ok().';


-- #####################################################################
-- ##  2.6-BOLIM — ehson_ber qayta e'lon (pul_turi/dollar/kurs/        ##
-- ##  qoldiq pul turi kesimida)                                       ##
-- #####################################################################
-- IMZO SAQLANADI (jsonb -> jsonb). Eski chaqiruv (kassada faol pul turi
-- yo'q — v1 holat) o'zgarishsiz ishlaydi. Konteyner kassaga berish rad
-- etiladi (yangi qoida, is_container 2.1-bo'limda qo'shildi).
create or replace function ehson_ber(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid        uuid    := auth.uid();
  v_oila       uuid    := nullif(p->>'oila_id', '')::uuid;
  v_kassa      uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_summa      numeric := nullif(p->>'summa', '')::numeric;
  v_sana       date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_tur        text    := nullif(p->>'tur', '');
  v_izoh       text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_reja       uuid    := nullif(p->>'reja_id', '')::uuid;
  v_kkch       date    := nullif(p->>'keyingi_korib_chiqish', '')::date;
  v_ext        text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  v_pul_turi_p text    := nullif(p->>'pul_turi', '');
  v_fc_p       numeric := nullif(p->>'fc_summa', '')::numeric;
  v_oila_r     ehson_oila;
  v_kassa_r    ehson_kassa;
  v_pt         ehson_pul_turi;
  v_pt_cnt     int;
  v_kurs       numeric;
  v_qoldiq     numeric;
  v_qoldiq_fc  numeric;
  v_id         uuid;
  v_exist      uuid;
  v_cnt        int;
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
    select count(*) into v_cnt from ehson_kassa where is_active and not is_container;
    if v_cnt <> 1 then
      return jsonb_build_object('ok', false, 'kod', 'kassa_tanlanmagan');
    end if;
    select id into v_kassa from ehson_kassa where is_active and not is_container limit 1;
  end if;
  select * into v_kassa_r from ehson_kassa where id = v_kassa and is_active;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi');
  end if;
  if v_kassa_r.is_container then
    return jsonb_build_object('ok', false, 'kod', 'kassa_konteyner');
  end if;

  -- Pul turi: kassada faol pul turi bo'lmasa — eski xatti-harakat (jami qoldiq,
  -- pul turisiz). Bo'lsa — majburiy, tanlangani faol bo'lishi shart. Dollar
  -- tanlansa summa USD'da (fc_summa), so'm ekvivalenti conv_baza_kurs('USD') bilan.
  select count(*) into v_pt_cnt from ehson_pul_turi where kassa_id = v_kassa and is_active;
  if v_pt_cnt > 0 then
    if v_pul_turi_p is null then
      return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak');
    end if;
    select * into v_pt from ehson_pul_turi where kassa_id = v_kassa and kod = v_pul_turi_p and is_active;
    if not found then
      return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak');
    end if;

    if v_pt.valyuta = 'USD' then
      if v_fc_p is null or v_fc_p <= 0 then
        return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
      end if;
      v_kurs := null;
      if exists (
        select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
         where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs'
           and oidvectortypes(pr.proargtypes) = 'text'
      ) then
        execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
      end if;
      if v_kurs is null or v_kurs <= 0 then
        return jsonb_build_object('ok', false, 'kod', 'kurs_yoq');
      end if;
      v_summa := round(v_fc_p * v_kurs);
    else
      v_fc_p := null;
      if v_summa is null or v_summa <= 0 then
        return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
      end if;
    end if;
  else
    v_pul_turi_p := null;
    v_fc_p := null;
    if v_summa is null or v_summa <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || v_kassa::text));

  if v_pt.id is not null then
    select qoldiq, fc_qoldiq into v_qoldiq, v_qoldiq_fc
      from v_ehson_kassa_pul where kassa_id = v_kassa and pul_turi = v_pt.kod;
    if v_pt.valyuta = 'USD' then
      if coalesce(v_qoldiq_fc, 0) < v_fc_p then
        return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi');
      end if;
    else
      if coalesce(v_qoldiq, 0) < v_summa then
        return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi');
      end if;
    end if;
  else
    select qoldiq into v_qoldiq from v_ehson_kassa where id = v_kassa;
    if coalesce(v_qoldiq, 0) < v_summa then
      return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi');
    end if;
  end if;

  insert into ehson_berish (
    oila_id, kassa_id, summa, sana, tur, izoh, reja_id, holat,
    keyingi_korib_chiqish, created_by, ext_ref, pul_turi, valyuta, fc_summa
  ) values (
    v_oila, v_kassa, v_summa, v_sana, v_tur, v_izoh, v_reja, 'berildi',
    v_kkch, v_uid, v_ext, v_pt.kod, coalesce(v_pt.valyuta, 'UZS'), v_fc_p
  )
  returning id into v_id;

  perform _ehson_tarix_yoz('berish', v_id, 'yaratildi',
    jsonb_build_object('oila_id', v_oila, 'summa', v_summa, 'tur', v_tur, 'pul_turi', v_pt.kod));

  return jsonb_build_object('ok', true, 'id', v_id);
exception when unique_violation then
  select id into v_exist from ehson_berish where ext_ref = v_ext;
  return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;

revoke all on function ehson_ber(jsonb) from public, anon;
grant execute on function ehson_ber(jsonb) to authenticated;

comment on function ehson_ber(jsonb) is
  'Berish. Kassada faol pul turi bo''lsa pul_turi majburiy (dollar -> fc_summa USD + conv_baza_kurs), qoldiq shu kesimda tekshiriladi. '
  'Konteyner kassaga berish rad etiladi. Eski chaqiruv (pul turisiz kassa) o''zgarmagan.';


-- #####################################################################
-- ##  2.7-BOLIM — ehson_dash / ehson_kirim_royxat / ehson_berish_     ##
-- ##  royxat qayta e'lon (pul_turi/valyuta/fc_summa + kassa filtri)   ##
-- #####################################################################
-- IMZOLAR SAQLANADI. Eski kalitlar o'zgarmaydi — faqat yangi maydon/filtr qo'shiladi.

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
  v_moddalar   jsonb;
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
           'id', k.id, 'nom', k.nom, 'is_active', k.is_active,
           'kirim', vk.kirim, 'berildi', vk.berildi, 'qoldiq', vk.qoldiq,
           'parent_id', k.parent_id, 'is_container', k.is_container, 'tartib', k.tartib,
           'pul_turlari', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'kod', pt.kod, 'nom', pt.nom, 'valyuta', pt.valyuta,
                      'qoldiq', coalesce(vp.qoldiq, 0), 'fc_qoldiq', coalesce(vp.fc_qoldiq, 0)
                    ) order by pt.tartib, pt.nom)
               from ehson_pul_turi pt
               left join v_ehson_kassa_pul vp on vp.kassa_id = pt.kassa_id and vp.pul_turi = pt.kod
              where pt.kassa_id = k.id and pt.is_active
           ), '[]'::jsonb)
         ) order by k.tartib, k.nom), '[]'::jsonb)
    into v_kassalar
    from ehson_kassa k
    join v_ehson_kassa vk on vk.id = k.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'kassa_id', k.id, 'id', a.id, 'code', a.code, 'name', a.name
         ) order by a.code), '[]'::jsonb)
    into v_moddalar
    from ehson_kassa k join accounts a on a.id = k.xarajat_account_id;

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
    'moddalar',      v_moddalar,
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

comment on function ehson_dash() is
  'Bosh sahifa statistikasi. kassalar[] endi parent_id/is_container/tartib/pul_turlari[] bilan (2026-09-07 zakot). Qolgan kalitlar o''zgarmagan.';


create or replace function ehson_kirim_royxat(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid    := auth.uid();
  v_from   date    := nullif(p->>'from', '')::date;
  v_to     date    := nullif(p->>'to', '')::date;
  v_q      text    := nullif(btrim(coalesce(p->>'q', '')), '');
  v_bekor  boolean := coalesce((p->>'bekor')::boolean, true);
  v_kassa  uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_pt     text    := nullif(p->>'pul_turi', '');
  v_limit  int     := greatest(1, least(coalesce(nullif(p->>'limit', '')::int, 50), 200));
  v_offset int     := greatest(0, coalesce(nullif(p->>'offset', '')::int, 0));
  v_rows   jsonb;
  v_jami   int;
  v_summa  numeric;
  v_all    boolean := false;
  v_ok_ids uuid[]  := '{}';
  v_view   uuid[];
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  if _ehson_is_admin() then
    v_all := true;
  else
    select u.view_kassa_ids into v_view from user_perms u where u.user_id = v_uid and u.kassa_scope = 'list';
    if not found then
      v_all := true;
    elsif exists (
      select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
       where ns.nspname = 'public' and pr.proname = 'perm_op_key' and oidvectortypes(pr.proargtypes) = 'uuid'
    ) then
      execute 'select coalesce(array_agg(a.id), ''{}''::uuid[]) from accounts a where perm_op_key(a.id) = any($1)'
         into v_ok_ids using coalesce(v_view, '{}'::uuid[]);
    end if;
  end if;

  select count(*), coalesce(sum(k.summa) filter (where not k.is_deleted), 0)
    into v_jami, v_summa
    from ehson_kirim k
    left join accounts pa on pa.id = k.pul_kassa_id
   where (v_from  is null or k.sana >= v_from)
     and (v_to    is null or k.sana <= v_to)
     and (v_bekor or not k.is_deleted)
     and (v_kassa is null or k.kassa_id = v_kassa)
     and (v_pt    is null or k.pul_turi = v_pt)
     and (v_q is null or k.manba ilike '%' || v_q || '%' or k.izoh ilike '%' || v_q || '%'
                      or pa.name ilike '%' || v_q || '%');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', k.id, 'sana', k.sana, 'summa', k.summa, 'manba', k.manba, 'izoh', k.izoh,
           'kassa_id', k.kassa_id, 'kassa_nom', ks.nom,
           'pul_turi', k.pul_turi, 'valyuta', k.valyuta, 'fc_summa', k.fc_summa,
           'pul_kassa_id', case when v_all or k.pul_kassa_id = any(v_ok_ids) then k.pul_kassa_id end,
           'pul_kassa_nom', case when k.pul_kassa_id is null then null
                                 when v_all or k.pul_kassa_id = any(v_ok_ids) then pa.name
                                 else 'Kompaniya kassasi' end,
           'pul_kassa_kod', case when v_all or k.pul_kassa_id = any(v_ok_ids) then pa.code end,
           'entry_id', k.entry_id,
           'kim', coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum'),
           'created_at', k.created_at,
           'is_deleted', k.is_deleted, 'deleted_at', k.deleted_at,
           'bekor_kim', case when k.is_deleted then coalesce(nullif(btrim(pd.full_name), ''), 'Jurnal') end,
           'bekor_sabab', case when k.is_deleted then coalesce(t.sabab, 'Jurnalda o''chirildi') end
         ) order by k.sana desc, k.created_at desc), '[]'::jsonb)
    into v_rows
    from (
      select k.* from ehson_kirim k
      left join accounts pa on pa.id = k.pul_kassa_id
       where (v_from  is null or k.sana >= v_from)
         and (v_to    is null or k.sana <= v_to)
         and (v_bekor or not k.is_deleted)
         and (v_kassa is null or k.kassa_id = v_kassa)
         and (v_pt    is null or k.pul_turi = v_pt)
         and (v_q is null or k.manba ilike '%' || v_q || '%' or k.izoh ilike '%' || v_q || '%'
                          or pa.name ilike '%' || v_q || '%')
       order by k.sana desc, k.created_at desc
       limit v_limit offset v_offset
    ) k
    left join ehson_kassa ks on ks.id = k.kassa_id
    left join accounts pa on pa.id = k.pul_kassa_id
    left join profiles pr on pr.id = k.created_by
    left join profiles pd on pd.id = k.deleted_by
    left join lateral (
      select x.data->>'sabab' as sabab
        from ehson_tarix x
       where x.obyekt = 'kirim' and x.obyekt_id = k.id and x.hodisa = 'bekor'
       order by x.vaqt desc limit 1
    ) t on true;

  return jsonb_build_object('rows', coalesce(v_rows, '[]'::jsonb), 'jami', v_jami, 'jami_summa', v_summa);
end
$fn$;

revoke all on function ehson_kirim_royxat(jsonb) from public, anon;
grant execute on function ehson_kirim_royxat(jsonb) to authenticated;

comment on function ehson_kirim_royxat(jsonb) is
  'Kirim tarixi. + pul_turi/valyuta/fc_summa qatorda, filtr kassa_id/pul_turi ixtiyoriy (2026-09-07 zakot). Qolgan shakl o''zgarmagan.';


create or replace function ehson_berish_royxat(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid    := auth.uid();
  v_from   date    := nullif(p->>'from', '')::date;
  v_to     date    := nullif(p->>'to', '')::date;
  v_oila   uuid    := nullif(p->>'oila_id', '')::uuid;
  v_tur    text    := nullif(p->>'tur', '');
  v_holat  text    := nullif(p->>'holat', '');
  v_kim    uuid    := nullif(p->>'kim', '')::uuid;
  v_kassa  uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_pt     text    := nullif(p->>'pul_turi', '');
  v_q      text    := nullif(btrim(coalesce(p->>'q', '')), '');
  v_limit  int     := greatest(1, least(coalesce(nullif(p->>'limit', '')::int, 50), 200));
  v_offset int     := greatest(0, coalesce(nullif(p->>'offset', '')::int, 0));
  v_rows   jsonb;
  v_jami   int;
  v_summa  numeric;
  v_tur_j  jsonb;
  v_masul  jsonb;
  v_ids    uuid[];
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;
  if v_tur is not null and v_tur not in ('pul','oziq_ovqat','kiyim','dori','boshqa') then
    return jsonb_build_object('ok', false, 'kod', 'tur_notogri');
  end if;
  if v_holat is not null and v_holat not in ('berildi','bekor') then
    return jsonb_build_object('ok', false, 'kod', 'holat_notogri');
  end if;

  select coalesce(array_agg(b.id), '{}'::uuid[]) into v_ids
    from ehson_berish b
    join ehson_oila o on o.id = b.oila_id
   where (v_from  is null or b.sana >= v_from)
     and (v_to    is null or b.sana <= v_to)
     and (v_oila  is null or b.oila_id = v_oila)
     and (v_tur   is null or b.tur = v_tur)
     and (v_holat is null or b.holat = v_holat)
     and (v_kim   is null or b.created_by = v_kim)
     and (v_kassa is null or b.kassa_id = v_kassa)
     and (v_pt    is null or b.pul_turi = v_pt)
     and (v_q is null or o.fio ilike '%' || v_q || '%' or o.oila_kod ilike '%' || v_q || '%'
                      or b.izoh ilike '%' || v_q || '%');

  select count(*), coalesce(sum(b.summa) filter (where b.holat = 'berildi'), 0)
    into v_jami, v_summa
    from ehson_berish b where b.id = any(v_ids);

  select coalesce(jsonb_object_agg(tur, s), '{}'::jsonb) into v_tur_j
    from (select b.tur, sum(b.summa) as s
            from ehson_berish b where b.id = any(v_ids)
             and b.holat = 'berildi' group by b.tur) x;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom) order by nom), '[]'::jsonb) into v_masul
    from (select distinct b.created_by as id,
                 coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') as nom
            from ehson_berish b
            left join profiles pr on pr.id = b.created_by
           where b.created_by is not null) m;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'sana', b.sana, 'summa', b.summa, 'tur', b.tur, 'izoh', b.izoh,
           'holat', b.holat, 'reja_id', b.reja_id, 'oila_id', b.oila_id,
           'oila_kod', o.oila_kod, 'fio', o.fio,
           'kassa_id', b.kassa_id, 'kassa_nom', ks.nom,
           'pul_turi', b.pul_turi, 'valyuta', b.valyuta, 'fc_summa', b.fc_summa,
           'kim', coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum'),
           'created_at', b.created_at, 'keyingi_korib_chiqish', b.keyingi_korib_chiqish,
           'bekor_sabab', case when b.holat = 'bekor' then b.bekor_sabab end,
           'bekor_kim', case when b.holat = 'bekor' then coalesce(nullif(btrim(pd.full_name), ''), 'Noma''lum') end,
           'deleted_at', b.deleted_at
         ) order by b.sana desc, b.created_at desc), '[]'::jsonb)
    into v_rows
    from (
      select b.* from ehson_berish b where b.id = any(v_ids)
       order by b.sana desc, b.created_at desc
       limit v_limit offset v_offset
    ) b
    join ehson_oila o on o.id = b.oila_id
    left join ehson_kassa ks on ks.id = b.kassa_id
    left join profiles pr on pr.id = b.created_by
    left join profiles pd on pd.id = b.deleted_by;

  return jsonb_build_object('rows', coalesce(v_rows, '[]'::jsonb), 'jami', v_jami,
                            'jami_summa', v_summa, 'tur_jami', v_tur_j, 'masullar', v_masul);
end
$fn$;

revoke all on function ehson_berish_royxat(jsonb) from public, anon;
grant execute on function ehson_berish_royxat(jsonb) to authenticated;

comment on function ehson_berish_royxat(jsonb) is
  'Berish tarixi. + kassa_id/kassa_nom/pul_turi/valyuta/fc_summa qatorda, filtr kassa_id/pul_turi ixtiyoriy (2026-09-07 zakot). Qolgan shakl o''zgarmagan.';


-- #####################################################################
-- ##  2.8-BOLIM — ehson_tarix.obyekt CHECK kengaytirish + admin RPC   ##
-- ##  ehson_kassa_saqla / ehson_pul_turi_saqla                        ##
-- #####################################################################

-- Mavjud CHECK ('oila','azo','berish','kirim','reja','kassa') ga 'pul_turi'
-- qo'shiladi (drop + qayta yaratish — inline check bo'lgani uchun nomi ma'lum:
-- ehson_tarix_obyekt_check). Eski qiymatlar SAQLANADI.
alter table ehson_tarix drop constraint if exists ehson_tarix_obyekt_check;
alter table ehson_tarix add constraint ehson_tarix_obyekt_check
  check (obyekt in ('oila','azo','berish','kirim','reja','kassa','pul_turi'));

-- ehson_kassa_saqla(p) — admin. Yangi (id yo'q) -> child (parent=ildiz),
-- modda ochiladi, 4 ta sukut pul turi seed qilinadi. Tahrir (id bor) ->
-- nom/izoh/is_active/tartib yangilanadi; deaktiv faqat qoldiq 0 bo'lsa;
-- konteynerni deaktiv qilish RAD etiladi.
create or replace function ehson_kassa_saqla(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid    := auth.uid();
  v_id     uuid    := nullif(p->>'id', '')::uuid;
  v_nom    text    := nullif(btrim(coalesce(p->>'nom', '')), '');
  v_izoh   text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_active boolean := coalesce((p->>'is_active')::boolean, true);
  v_tartib int     := coalesce(nullif(p->>'tartib', '')::int, 0);
  v_root   uuid;
  v_row    ehson_kassa;
  v_qoldiq numeric;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not _ehson_is_admin() then
    raise exception 'Faqat admin jamg''arma kassalarini boshqaradi' using errcode = '42501';
  end if;
  if v_nom is null then
    return jsonb_build_object('ok', false, 'kod', 'nom_kerak');
  end if;

  if v_id is not null then
    select * into v_row from ehson_kassa where id = v_id;
    if not found then
      return jsonb_build_object('ok', false, 'kod', 'topilmadi');
    end if;
    if v_row.is_container and not v_active then
      return jsonb_build_object('ok', false, 'kod', 'kassa_konteyner');
    end if;
    if exists (
      select 1 from ehson_kassa
       where id <> v_id and coalesce(parent_id, id) = coalesce(v_row.parent_id, v_row.id)
         and lower(nom) = lower(v_nom)
    ) then
      return jsonb_build_object('ok', false, 'kod', 'takror');
    end if;
    if v_row.is_active and not v_active then
      select qoldiq into v_qoldiq from v_ehson_kassa where id = v_id;
      if coalesce(v_qoldiq, 0) <> 0 then
        return jsonb_build_object('ok', false, 'kod', 'qoldiq_bor');
      end if;
    end if;

    update ehson_kassa set nom = v_nom, izoh = v_izoh, is_active = v_active, tartib = v_tartib
     where id = v_id;

    perform _ehson_xarajat_modda(v_id);
    perform _ehson_tarix_yoz('kassa', v_id, 'yangilandi', p);
    return jsonb_build_object('ok', true, 'id', v_id);
  end if;

  select id into v_root from ehson_kassa where is_container and is_active order by created_at limit 1;
  if v_root is null then
    return jsonb_build_object('ok', false, 'kod', 'ildiz_topilmadi');
  end if;
  if exists (select 1 from ehson_kassa where parent_id = v_root and lower(nom) = lower(v_nom)) then
    return jsonb_build_object('ok', false, 'kod', 'takror');
  end if;

  insert into ehson_kassa (nom, izoh, is_active, parent_id, is_container, tartib, created_by)
  values (v_nom, v_izoh, v_active, v_root, false, v_tartib, v_uid)
  returning id into v_id;

  perform _ehson_xarajat_modda(v_id);

  insert into ehson_pul_turi (kassa_id, kod, nom, valyuta, tartib)
  select v_id, x.kod, x.nom, x.valyuta, x.tartib
    from (values
      ('naqd',   'Naqd',   'UZS', 1),
      ('dollar', 'Dollar', 'USD', 2),
      ('karta',  'Karta',  'UZS', 3),
      ('click',  'Click',  'UZS', 4)
    ) as x(kod, nom, valyuta, tartib)
   on conflict (kassa_id, kod) do nothing;

  perform _ehson_tarix_yoz('kassa', v_id, 'yaratildi', p);
  return jsonb_build_object('ok', true, 'id', v_id);
end
$fn$;

revoke all on function ehson_kassa_saqla(jsonb) from public, anon;
grant execute on function ehson_kassa_saqla(jsonb) to authenticated;

comment on function ehson_kassa_saqla(jsonb) is
  'Admin: jamg''arma (child) kassa qo''shish/tahrir. Yangi -> parent=ildiz + modda + 4 sukut pul turi. Deaktiv faqat qoldiq 0. Konteyner deaktiv qilinmaydi.';

-- ehson_pul_turi_saqla(p) — admin. Yangi (id yo'q) -> kassa_id majburiy
-- (konteyner bo'lmasin), kod regex + kassa ichida unique. Tahrir (id bor)
-- -> nom/valyuta/is_active/tartib (kod o'zgarmaydi — kirim/berish yozuvlari
-- shu kodga tayanadi). Deaktiv faqat qoldiq (so'm VA dollar) 0 bo'lsa.
create or replace function ehson_pul_turi_saqla(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid    := auth.uid();
  v_id     uuid    := nullif(p->>'id', '')::uuid;
  v_kassa  uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_kod    text    := lower(nullif(btrim(coalesce(p->>'kod', '')), ''));
  v_nom    text    := nullif(btrim(coalesce(p->>'nom', '')), '');
  v_val    text    := coalesce(nullif(upper(btrim(coalesce(p->>'valyuta', ''))), ''), 'UZS');
  v_active boolean := coalesce((p->>'is_active')::boolean, true);
  v_tartib int     := coalesce(nullif(p->>'tartib', '')::int, 0);
  v_row    ehson_pul_turi;
  v_qoldiq numeric;
  v_fc     numeric;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not _ehson_is_admin() then
    raise exception 'Faqat admin pul turlarini boshqaradi' using errcode = '42501';
  end if;
  if v_nom is null then
    return jsonb_build_object('ok', false, 'kod', 'nom_kerak');
  end if;

  if v_id is not null then
    select * into v_row from ehson_pul_turi where id = v_id;
    if not found then
      return jsonb_build_object('ok', false, 'kod', 'topilmadi');
    end if;
    if v_row.is_active and not v_active then
      select qoldiq, fc_qoldiq into v_qoldiq, v_fc
        from v_ehson_kassa_pul where kassa_id = v_row.kassa_id and pul_turi = v_row.kod;
      if coalesce(v_qoldiq, 0) <> 0 or coalesce(v_fc, 0) <> 0 then
        return jsonb_build_object('ok', false, 'kod', 'qoldiq_bor');
      end if;
    end if;

    update ehson_pul_turi set nom = v_nom, valyuta = v_val, is_active = v_active, tartib = v_tartib
     where id = v_id;

    perform _ehson_tarix_yoz('pul_turi', v_id, 'yangilandi', p);
    return jsonb_build_object('ok', true, 'id', v_id);
  end if;

  if v_kassa is null then
    return jsonb_build_object('ok', false, 'kod', 'kassa_kerak');
  end if;
  if not exists (select 1 from ehson_kassa where id = v_kassa and not is_container) then
    return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi');
  end if;
  if v_kod is null or v_kod !~ '^[a-z_]{2,20}$' then
    return jsonb_build_object('ok', false, 'kod', 'kod_notogri');
  end if;
  if exists (select 1 from ehson_pul_turi where kassa_id = v_kassa and kod = v_kod) then
    return jsonb_build_object('ok', false, 'kod', 'takror');
  end if;

  insert into ehson_pul_turi (kassa_id, kod, nom, valyuta, is_active, tartib, created_by)
  values (v_kassa, v_kod, v_nom, v_val, v_active, v_tartib, v_uid)
  returning id into v_id;

  perform _ehson_tarix_yoz('pul_turi', v_id, 'yaratildi', p);
  return jsonb_build_object('ok', true, 'id', v_id);
end
$fn$;

revoke all on function ehson_pul_turi_saqla(jsonb) from public, anon;
grant execute on function ehson_pul_turi_saqla(jsonb) to authenticated;

comment on function ehson_pul_turi_saqla(jsonb) is
  'Admin: kassa ichida pul turi qo''shish/tahrir. Yangi -> kassa_id+kod majburiy (konteynerga taqiq). Kod tahrirda o''zgarmaydi. Deaktiv faqat qoldiq 0 (so''m va dollar).';


-- #####################################################################
-- ##  2.9-BOLIM — entry_ehson_pul_turi_yoz(text, text) — Professional ##
-- ##  kaskadi uchun (tester topilmasi, 2026-09-07)                    ##
-- #####################################################################
-- Professional yozuvlari `provodka_yoz(jsonb)` / `xarajat_saqlash_taqsim(jsonb)`
-- orqali yoziladi — ularning `insert into entry` qismi `ehson_pul_turi` ni
-- bilmaydi va bu RPC'lar (katta/xavfli) qayta e'lon QILINMAYDI. O'rniga
-- `entry_jadval_yoz(text, jsonb)` naqshi (PROVODKA_JADVAL.sql 4-BO'LIM)
-- AYNAN takrorlanadi: entry `ext_ref` bo'yicha yaratilgach, tanlangan pul
-- turi shu RPC bilan ALOHIDA yoziladi. `created_by` turi bazada aniqlanmagan
-- (uuid ham, text ham bo'lishi mumkin) — regex bilan tekshirib cast qilinadi,
-- bir marta, 30 daqiqa ichida, faqat egasi.
create or replace function entry_ehson_pul_turi_yoz(p_ext_ref text, p_pul_turi text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid            uuid := auth.uid();
  v_ext            text := nullif(btrim(coalesce(p_ext_ref, '')), '');
  v_pt             text := lower(nullif(btrim(coalesce(p_pul_turi, '')), ''));
  v_id             uuid;
  v_created_at     timestamptz;
  v_ehson_pul_turi text;
  v_created_by_raw text;
  v_owner          uuid;
  v_kassa_id       uuid;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if v_ext is null then
    return jsonb_build_object('ok', false, 'kod', 'ext_ref_kerak');
  end if;
  if v_pt is null then
    return jsonb_build_object('ok', false, 'kod', 'pul_turi_notogri');
  end if;

  select e.id, e.created_at, e.ehson_pul_turi, (to_jsonb(e) ->> 'created_by')
    into v_id, v_created_at, v_ehson_pul_turi, v_created_by_raw
    from entry e
   where e.ext_ref = v_ext
   limit 1;

  if v_id is null then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi');
  end if;

  -- 🔴 `created_by` turi bazada aniqlanmagan (entry_jadval_yoz naqshi,
  --    PROVODKA_JADVAL.sql) — `::uuid` cast FAQAT to'liq uuid shaklida.
  v_owner := case when v_created_by_raw ~ '^[0-9a-fA-F-]{36}$' then v_created_by_raw::uuid end;
  if v_owner is distinct from v_uid then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat_yoq');
  end if;
  if v_created_at is null or v_created_at < now() - interval '30 minutes' then
    return jsonb_build_object('ok', false, 'kod', 'muddat_tugagan');
  end if;
  if v_ehson_pul_turi is not null then
    return jsonb_build_object('ok', false, 'kod', 'allaqachon');
  end if;

  select a.ehson_kassa_id into v_kassa_id
    from entry_line l join accounts a on a.id = l.account_id
   where l.entry_id = v_id and l.debit > 0 and a.ehson_kassa_id is not null
   limit 1;

  if v_kassa_id is null then
    return jsonb_build_object('ok', false, 'kod', 'ehson_emas');
  end if;

  if not exists (select 1 from ehson_pul_turi where kassa_id = v_kassa_id and kod = v_pt and is_active) then
    return jsonb_build_object('ok', false, 'kod', 'pul_turi_notogri');
  end if;

  update entry set ehson_pul_turi = v_pt where id = v_id;

  perform _ehson_kirim_sync(v_id);

  return jsonb_build_object('ok', true);
end
$fn$;

revoke all on function entry_ehson_pul_turi_yoz(text, text) from public, anon;
grant execute on function entry_ehson_pul_turi_yoz(text, text) to authenticated;

comment on function entry_ehson_pul_turi_yoz(text, text) is
  'Professional kaskadida tanlangan Ehson pul turini entry yaratilgach yozadi — provodka_yoz/xarajat_saqlash_taqsim imzosi TEGILMAGAN. '
  'entry_jadval_yoz naqshi: egalik created_by=auth.uid() (turi noaniq, regex bilan cast), 30 daqiqa, bir marta (ehson_pul_turi is null). '
  'Faqat kamida bitta Dt satri ehson moddasiga (accounts.ehson_kassa_id) tegishli yozuvda ishlaydi, pul_turi shu kassada faol bo''lishi shart. '
  'Muvaffaqiyatdan keyin _ehson_kirim_sync(entry_id) chaqiriladi — ehson_kirim.pul_turi darrov yangilanadi.';


-- #####################################################################
-- ##  10-BOLIM — PostgREST sxema keshi                                ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  11-BOLIM — YAKUNIY TEKSHIRUV (faqat select)                     ##
-- #####################################################################

do $ez_check$
declare
  v_root_id   uuid;
  v_child_cnt int;
  v_bad_pt    int;
  v_bad_modda int;
begin
  -- Ustunlar
  if not exists (select 1 from information_schema.columns where table_name = 'ehson_kassa' and column_name = 'parent_id') then
    raise exception 'ehson_kassa.parent_id yoq';
  end if;
  if not exists (select 1 from information_schema.columns where table_name = 'ehson_kassa' and column_name = 'is_container') then
    raise exception 'ehson_kassa.is_container yoq';
  end if;
  if not exists (select 1 from information_schema.columns where table_name = 'ehson_kirim' and column_name = 'pul_turi') then
    raise exception 'ehson_kirim.pul_turi yoq';
  end if;
  if not exists (select 1 from information_schema.columns where table_name = 'ehson_berish' and column_name = 'pul_turi') then
    raise exception 'ehson_berish.pul_turi yoq';
  end if;
  if not exists (select 1 from information_schema.columns where table_name = 'entry' and column_name = 'ehson_pul_turi') then
    raise exception 'entry.ehson_pul_turi yoq';
  end if;

  -- Jadval/view
  if to_regclass('public.ehson_pul_turi')    is null then raise exception 'ehson_pul_turi yaratilmadi'; end if;
  if to_regclass('public.v_ehson_kassa_pul') is null then raise exception 'v_ehson_kassa_pul yaratilmadi'; end if;

  -- RLS
  if not (select relrowsecurity from pg_class where oid = 'public.ehson_pul_turi'::regclass) then
    raise exception 'ehson_pul_turi da RLS yoqilmagan';
  end if;

  -- Funksiyalar (pg_proc + pg_namespace, to_regprocedure ISHLATILMAGAN)
  if not exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = 'ehson_kassa_daraxt' and oidvectortypes(pr.proargtypes) = ''
  ) then
    raise exception 'ehson_kassa_daraxt() yaratilmadi';
  end if;
  if not exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = 'ehson_kassa_saqla' and oidvectortypes(pr.proargtypes) = 'jsonb'
  ) then
    raise exception 'ehson_kassa_saqla(jsonb) yaratilmadi';
  end if;
  if not exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = 'ehson_pul_turi_saqla' and oidvectortypes(pr.proargtypes) = 'jsonb'
  ) then
    raise exception 'ehson_pul_turi_saqla(jsonb) yaratilmadi';
  end if;
  -- 2 argumentli funksiya — oidvectortypes vergul formatiga tayanmaymiz,
  -- pronargs + proargtypes[i] (0-asosli) bilan aniq tekshiramiz.
  if not exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = 'entry_ehson_pul_turi_yoz'
       and pr.pronargs = 2
       and pr.proargtypes[0] = 'text'::regtype
       and pr.proargtypes[1] = 'text'::regtype
  ) then
    raise exception 'entry_ehson_pul_turi_yoz(text, text) yaratilmadi';
  end if;

  -- Seed: ildiz + kamida 3 faol child, har birida togri bogliq modda va
  -- kamida 1 ta pul turi qatori. 🔴 "4 ta FAOL" QATTIQ TEKSHIRILMAYDI —
  -- admin keyinroq birortasini deaktiv qilishi mumkin (ez_pt_seed'da faqat
  -- raise notice), qattiq talab additive falsafaga zid bo'lardi.
  select id into v_root_id from ehson_kassa where is_container and is_active order by created_at limit 1;
  if v_root_id is null then
    raise exception 'Ehson ildiz (is_container) topilmadi';
  end if;

  select count(*) into v_child_cnt from ehson_kassa where parent_id = v_root_id and is_active;
  if v_child_cnt < 3 then
    raise exception 'Ildiz ostida kamida 3 faol child kassa bo''lishi kerak, hozir: %', v_child_cnt;
  end if;

  select count(*) into v_bad_pt from (
    select k.id from ehson_kassa k
     where k.parent_id = v_root_id and k.is_active
       and not exists (select 1 from ehson_pul_turi pt where pt.kassa_id = k.id)
  ) x;
  if v_bad_pt > 0 then
    raise exception '% ta child kassada birorta ham pul turi qatori yoq', v_bad_pt;
  end if;

  select count(*) into v_bad_modda from (
    select k.id from ehson_kassa k
     where k.parent_id = v_root_id and k.is_active
       and (k.xarajat_account_id is null
            or not exists (select 1 from accounts a where a.id = k.xarajat_account_id and a.ehson_kassa_id = k.id))
  ) x;
  if v_bad_modda > 0 then
    raise exception '% ta child kassada xarajat moddasi to''g''ri bog''lanmagan', v_bad_modda;
  end if;

  -- GRANT tekshiruvi
  if not has_function_privilege('authenticated', 'public.ehson_kassa_daraxt()', 'execute') then
    raise exception 'ehson_kassa_daraxt() authenticated uchun yopiq';
  end if;
  if not has_function_privilege('authenticated', 'public.ehson_kassa_saqla(jsonb)', 'execute') then
    raise exception 'ehson_kassa_saqla(jsonb) authenticated uchun yopiq';
  end if;
  if has_function_privilege('anon', 'public.ehson_kassa_saqla(jsonb)', 'execute') then
    raise exception 'ehson_kassa_saqla(jsonb) anon uchun ochiq qolgan';
  end if;
  if not has_function_privilege('authenticated', 'public.ehson_pul_turi_saqla(jsonb)', 'execute') then
    raise exception 'ehson_pul_turi_saqla(jsonb) authenticated uchun yopiq';
  end if;
  if has_function_privilege('anon', 'public.ehson_pul_turi_saqla(jsonb)', 'execute') then
    raise exception 'ehson_pul_turi_saqla(jsonb) anon uchun ochiq qolgan';
  end if;
  if not has_function_privilege('authenticated', 'public.entry_ehson_pul_turi_yoz(text, text)', 'execute') then
    raise exception 'entry_ehson_pul_turi_yoz(text, text) authenticated uchun yopiq';
  end if;
  if has_function_privilege('anon', 'public.entry_ehson_pul_turi_yoz(text, text)', 'execute') then
    raise exception 'entry_ehson_pul_turi_yoz(text, text) anon uchun ochiq qolgan';
  end if;

  raise notice 'PROVODKA_EHSON_ZAKOT.sql tayyor. Ildiz: %, faol child: % ta', v_root_id, v_child_cnt;
end
$ez_check$;
