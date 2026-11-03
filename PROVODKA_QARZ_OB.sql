-- ============================================================================
--  PROVODKA_QARZ_OB.sql — 2026-11-03 — «Qarz oldi-berdi» sahifasi (qarz-oldi-berdi-dev.html), ruxsat kaliti qarz_ob
--  Asilbek: ruxsati bor odam ISTALGAN Provodka kassasidan qarz BERA oladi (berdik) yoki istalgan kassaga qarz OLA oladi (oldik).
--  Model va UX — Ehson ichidagi «Qarz» tabi bilan bir xil (PROVODKA_EHSON_QARZ.sql), lekin pul harakati HAQIQIY provodka.
--
--  PUL HARAKATI (entry/entry_line) FAQAT RPC ICHIDA, foydalanuvchi JWT bilan (service_role EMAS) — trg_perm_guard_entry_line
--  (kassada amaliyot ruxsati) avtomat ishlaydi. entry.source = 'qarz' (entry_source_check PROVODKA_QARZ.sql 14a-bolimida kengaygan).
--
--   berdik        (kompaniya pul beradi, kassa MAJBURIY)
--     yaratish :   Dt 4720 «Boshqa shaxslarga berilgan qarzlar» / Kt kassa
--     qaytarish:   Dt kassa / Kt 4720
--   oldik         (kompaniya qarz oladi)
--     yaratish :   Dt kassa / Kt 6820 «Olingan qarzlar»   (YANGI hisob, passiv)
--     qaytarish:   Dt 6820 / Kt kassa   (kassa MAJBURIY, qoldiq tekshiriladi)
--   oldik + «eski qarz» (pul kassaga kirmagan; kassa YO'Q, pul harakati YO'Q)
--     yaratish :   Dt «Boshlang'ich qoldiq — olingan qarzlar» (YANGI kapital hisob) / Kt 6820
--                  — 6820 qoldig'i to'g'ri chiqadi, keyin qaytarish oddiy (Dt 6820 / Kt kassa).
--                  Valyuta qo'lda tanlanadi (UZS/USD).
--
--  🔴 KAPITAL HISOB KODI: topshiriqda 8710 deyilgan, LEKIN balans() 8710 kodini «Yigilgan sof foyda» SINTETIK qatori uchun
--     ishlatadi (CLAUDE.md). Haqiqiy hisob 8710 bilan ochilsa balansda ikkita 8710 qatori chiqadi. Shuning uchun hisob NOM
--     bo'yicha topiladi/ochiladi va kodi 8730 dan boshlab birinchi bo'sh 87xx bo'ladi (kapital hisob shu blokda yashaydi:
--     8720 Boshlang'ich kapital). Section: mavjud kapital hisobdan, bo'lmasa 6010 nikidan.
--
--  VALYUTA: kassa hisobining currency si qarz valyutasi. Valyutali kassada entry_line.fc_amount = valyuta miqdori, so'm
--  ekvivalenti conv_baza_kurs(valyuta) bilan (ehson_qarz_ber naqshi: summa so'm, fc_summa valyuta; grafik/qoldi/oylik qarz
--  valyutasi birligida). 🔴 QAYTARISHDA so'm ekvivalenti QARZ BERILGAN KURS bo'yicha proporsional (valyuta × summa / asosiy),
--  JORIY kurs bilan emas — shunda 4720 / 6820 qoldig'i aniq nolga tushadi (kurs farqi qoldiq bo'lib osilib qolmaydi). Valyutali
--  kassadagi kurs farqini mavjud avtomat qayta baholash (trg_kurs_farqi_entry_line) o'zi yozadi.
--
--  Qarzlar 5 kunlik va boshqa jadvallarga TA'SIR QILMAYDI. Jurnalda entry sifatida o'zi ko'rinadi (section = pul -> Kirim/Chiqim).
--
--  Jadvallar: qarz_ob, qarz_ob_jadval, qarz_ob_tolov, qarz_ob_tarix. RLS select qarz_ob_page_ok() (admin YOKI allowed_pages
--  ni qarz_ob o'z ichiga oladi), yozish faqat RPC.
--  RPC: qarz_ob_kassalar() · qarz_ob_yarat(p) · qarz_ob_tolov(p) · qarz_ob_bekor(id, sabab) · qarz_ob_royxat(p) ·
--       qarz_ob_kart(id) · qarz_ob_dash().
--  BEKOR: faqat to'lov bo'lmasa, admin YOKI yaratgan. Pul harakati ham qaytariladi — entry soft-delete (is_deleted=true,
--  entry_history izi), balans va jurnal avtomat to'g'rilanadi.
--
--  Additive, idempotent. Asilbek RUN qiladi.
--  Old shart: PROVODKA_QARZ.sql (4720, entry_source_check, sorov_kassa_bal), PROVODKA_KASSA2.sql (acc_fc_balance, conv_baza_kurs),
--             PROVODKA_PERMS.sql (perm_check_accounts, perm_pages, trg_perm_guard_entry_line).
--  admin-dev PVS_PAGES (TaskFix repo) ga {key:'qarz_ob', label:'Qarz oldi-berdi'} qo'shilishi SHART, aks holda admin ruxsat berolmaydi.
-- ============================================================================

-- ######## 0) OLD SHART ########
do $qo_pre$
begin
  if to_regclass('public.accounts') is null then raise exception 'accounts yoq'; end if;
  if to_regclass('public.entry') is null or to_regclass('public.entry_line') is null then raise exception 'entry/entry_line yoq'; end if;
  if to_regclass('public.user_perms') is null then raise exception 'user_perms yoq — avval PROVODKA_PERMS.sql'; end if;
  if to_regprocedure('public.is_admin()') is null then raise exception 'is_admin() yoq'; end if;
  if to_regprocedure('public.perm_pages()') is null then raise exception 'perm_pages() yoq — avval PROVODKA_PERMS.sql'; end if;
  if to_regprocedure('public.perm_check_accounts(uuid[])') is null then raise exception 'perm_check_accounts(uuid[]) yoq'; end if;
  if to_regprocedure('public.sorov_kassa_bal(uuid)') is null then raise exception 'sorov_kassa_bal(uuid) yoq — avval PROVODKA_SOROVLAR.sql'; end if;
  if to_regprocedure('public.acc_fc_balance(uuid)') is null then raise exception 'acc_fc_balance(uuid) yoq — avval PROVODKA_KASSA2.sql'; end if;
  if to_regprocedure('public.conv_baza_kurs(text)') is null then raise exception 'conv_baza_kurs(text) yoq — avval PROVODKA_KASSA2.sql'; end if;
  if not exists (select 1 from accounts where code = '4720') then raise exception '4720 hisobi yoq — avval PROVODKA_QARZ.sql'; end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.entry_line'::regclass and tgname = 'trg_perm_guard_entry_line') then
    raise exception 'trg_perm_guard_entry_line yoq — pul guardi topilmadi, avval tekshiring';
  end if;
  -- source = qarz entry_source_check da bo'lishi shart (PROVODKA_QARZ.sql 14a)
  if exists (select 1 from pg_constraint where conrelid = 'public.entry'::regclass and conname = 'entry_source_check')
     and not exists (select 1 from pg_constraint where conrelid = 'public.entry'::regclass and conname = 'entry_source_check'
                        and pg_get_constraintdef(oid) like '%''qarz''%') then
    raise exception 'entry_source_check qarz ni bilmaydi — avval PROVODKA_QARZ.sql 14a-bolimi';
  end if;
end
$qo_pre$;

-- ######## 1) RUXSAT: perm_pages() ga 'qarz_ob' (joriy ro'yxat o'qiladi va OXIRIGA qo'shiladi) ########
-- Imzo/til/immutable o'zgarmaydi; grant'lar saqlanadi. perms-dev.js PAGES va index-dev.html CARDS bilan AYNAN bir xil kalit.
do $qo_perm$
declare
  v_list text[] := perm_pages();
begin
  if not ('qarz_ob' = any(v_list)) then
    v_list := v_list || array['qarz_ob']::text[];
    execute 'create or replace function perm_pages() returns text[] language sql immutable as $qo_pp$ select '
            || quote_literal(v_list::text) || '::text[] $qo_pp$';
  end if;
end
$qo_perm$;

revoke all on function perm_pages() from public, anon;
grant execute on function perm_pages() to authenticated, service_role;

-- RLS qorovuli: admin YOKI allowed_pages ichida qarz_ob. auth.uid() null bo'lsa false (fail-closed).
-- perm_has_page() ishlatilmaydi: u kalit perm_pages() da bo'lmasa hammaga true beradi (fail-open).
create or replace function qarz_ob_page_ok()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(is_admin(), false) or coalesce(
    (select 'qarz_ob' = any(coalesce(up.allowed_pages, '{}'::text[]))
       from user_perms up where up.user_id = auth.uid()),
    false
  );
$fn$;
revoke all on function qarz_ob_page_ok() from public, anon;
grant execute on function qarz_ob_page_ok() to authenticated;
comment on function qarz_ob_page_ok() is
  'RLS qorovuli: admin YOKI qarz_ob sahifasi ruxsati. Fail-closed.';

-- ######## 2) HISOBLAR: 6820 «Olingan qarzlar» (passiv) + kapital «Boshlang''ich qoldiq — olingan qarzlar» ########
insert into accounts (code, name, type, section, currency, is_active)
select '6820',
       'Olingan qarzlar',
       'passiv',
       coalesce(
         (select a.section from accounts a where a.code = '6010' limit 1),
         (select a.section from accounts a
           where a.type = 'passiv' and a.section is not null
           group by a.section order by count(*) desc, a.section limit 1)
       ),
       'UZS',
       true
 where not exists (select 1 from accounts where code = '6820');

do $qo_kap$
declare
  v_nom  text := 'Boshlang''ich qoldiq — olingan qarzlar';
  v_kod  text;
  v_next int := 30;
  v_sec  text;
begin
  if exists (select 1 from accounts where type = 'kapital' and lower(btrim(name)) = lower(v_nom)) then
    return;   -- allaqachon bor
  end if;
  -- 8710 sintetik qator uchun band (balans() «Yigilgan sof foyda») — 8730 dan boshlab birinchi bo'sh 87xx
  loop
    v_kod := '87' || lpad(v_next::text, 2, '0');
    exit when not exists (select 1 from accounts where code = v_kod);
    v_next := v_next + 1;
    if v_next > 99 then raise exception '87xx bloki to''ldi — kapital hisob uchun kod topilmadi'; end if;
  end loop;
  v_sec := coalesce(
    (select a.section from accounts a where a.type = 'kapital' and a.section is not null order by a.code limit 1),
    (select a.section from accounts a where a.code = '6010' limit 1));
  insert into accounts (code, name, type, section, currency, is_active)
  values (v_kod, v_nom, 'kapital', v_sec, 'UZS', true);
end
$qo_kap$;

-- ######## 3) JADVALLAR ########
create table if not exists qarz_ob (
  id           uuid        primary key default gen_random_uuid(),
  yonalish     text        not null check (yonalish in ('oldik', 'berdik')),
  kassa_id     uuid        references accounts(id),                 -- eski qarzda NULL
  eski_qarz    boolean     not null default false,                  -- oldik: pul kassaga kirmagan
  valyuta      text        not null default 'UZS',
  summa        numeric     not null check (summa > 0),              -- so'm ekvivalenti (har doim)
  fc_summa     numeric     check (fc_summa is null or fc_summa > 0),-- valyuta miqdori (valyuta UZS emas bo'lsa)
  kontragent   text        not null check (length(btrim(kontragent)) >= 2),
  telefon      text,
  muddat_turi  text        not null check (muddat_turi in ('bir_martalik', 'oylik')),
  boshlanish   date,
  tugash       date        not null,
  oylar_soni   int         check (oylar_soni is null or oylar_soni > 0),
  oylik_summa  numeric     check (oylik_summa is null or oylik_summa > 0),   -- qarz valyutasi birligida
  sana         date        not null default ((now() at time zone 'Asia/Tashkent')::date),
  izoh         text        not null check (length(btrim(izoh)) >= 3),
  holat        text        not null default 'faol' check (holat in ('faol', 'yopildi', 'bekor')),
  ext_ref      text        unique,
  entry_id     uuid        references entry(id),
  created_by   uuid,
  created_at   timestamptz not null default now(),
  yopilgan_at  timestamptz,
  bekor_sabab  text,
  bekor_by     uuid,
  bekor_at     timestamptz,
  constraint qarz_ob_kassa_ck check (
    (eski_qarz and yonalish = 'oldik' and kassa_id is null) or
    (not eski_qarz and kassa_id is not null)
  ),
  constraint qarz_ob_muddat_ck check (
    (muddat_turi = 'bir_martalik' and oylar_soni is null) or
    (muddat_turi = 'oylik' and boshlanish is not null and oylar_soni > 0 and oylik_summa > 0)
  )
);
comment on table qarz_ob is
  'Qarz oldi-berdi: berdik = kompaniya qarz berdi (Dt 4720 / Kt kassa), oldik = kompaniya qarz oldi (Dt kassa / Kt 6820; eski qarz: '
  'Dt kapital / Kt 6820). Grafik/qoldi qarz valyutasi birligida, summa — so''m ekvivalenti.';
create index if not exists qarz_ob_holat_idx    on qarz_ob (holat);
create index if not exists qarz_ob_yonalish_idx on qarz_ob (yonalish);
create index if not exists qarz_ob_kassa_idx    on qarz_ob (kassa_id);

create table if not exists qarz_ob_jadval (
  id        uuid    primary key default gen_random_uuid(),
  qarz_id   uuid    not null references qarz_ob(id) on delete cascade,
  n         int     not null check (n > 0),
  sana      date    not null,
  summa     numeric not null check (summa > 0),
  tolangan  numeric not null default 0 check (tolangan >= 0 and tolangan <= summa),
  unique (qarz_id, n)
);
create index if not exists qarz_ob_jadval_qarz_idx on qarz_ob_jadval (qarz_id);
create index if not exists qarz_ob_jadval_sana_idx on qarz_ob_jadval (sana);

create table if not exists qarz_ob_tolov (
  id          uuid        primary key default gen_random_uuid(),
  qarz_id     uuid        not null references qarz_ob(id),
  kassa_id    uuid        not null references accounts(id),
  valyuta     text        not null default 'UZS',
  summa       numeric     not null check (summa > 0),              -- so'm ekvivalenti (qarz berilgan kurs bo'yicha)
  fc_summa    numeric     check (fc_summa is null or fc_summa > 0),
  sana        date        not null default ((now() at time zone 'Asia/Tashkent')::date),
  izoh        text,
  entry_id    uuid        references entry(id),
  ext_ref     text        unique,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  is_deleted  boolean     not null default false
);
create index if not exists qarz_ob_tolov_qarz_idx on qarz_ob_tolov (qarz_id);

create table if not exists qarz_ob_tarix (
  id        uuid        primary key default gen_random_uuid(),
  qarz_id   uuid        not null references qarz_ob(id) on delete cascade,
  hodisa    text        not null,
  data      jsonb       not null default '{}'::jsonb,
  kim       uuid,
  vaqt      timestamptz not null default now()
);
create index if not exists qarz_ob_tarix_qarz_idx on qarz_ob_tarix (qarz_id);

-- RLS — faqat select (qarz_ob_page_ok), yozish faqat RPC
do $qo_rls$
declare t text;
begin
  foreach t in array array['qarz_ob', 'qarz_ob_jadval', 'qarz_ob_tolov', 'qarz_ob_tarix'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from public, anon', t);
    execute format('grant select on table %I to authenticated', t);
    execute format('drop policy if exists %I on %I', t || '_select', t);
    execute format('create policy %I on %I for select to authenticated using (qarz_ob_page_ok())', t || '_select', t);
  end loop;
end
$qo_rls$;

-- ######## 4) YORDAMCHILAR (ichki) ########
-- oy qo'shish, oy oxiriga clamp (31.01 + 1 oy = 28/29.02) — _ehson_oy_qosh nusxasi (Ehson SQL ga bog'lanmaslik uchun)
create or replace function _qarz_ob_oy_qosh(p_date date, p_n int)
returns date
language sql
immutable
as $fn$
  select least(
    (date_trunc('month', p_date) + make_interval(months => p_n))::date + (extract(day from p_date)::int - 1),
    (date_trunc('month', p_date) + make_interval(months => p_n + 1))::date - 1
  );
$fn$;
revoke all on function _qarz_ob_oy_qosh(date, int) from public, anon, authenticated;

create or replace function _qarz_ob_kapital_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $fn$
  select id from accounts
   where type = 'kapital' and lower(btrim(name)) = lower('Boshlang''ich qoldiq — olingan qarzlar') and is_active
   order by code limit 1;
$fn$;
revoke all on function _qarz_ob_kapital_id() from public, anon, authenticated;

create or replace function _qarz_ob_ism()
returns text
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = auth.uid();
$fn$;
revoke all on function _qarz_ob_ism() from public, anon, authenticated;

create or replace function _qarz_ob_tarix_yoz(p_qarz uuid, p_hodisa text, p_data jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path = public
as $fn$
  insert into qarz_ob_tarix (qarz_id, hodisa, data, kim) values (p_qarz, p_hodisa, coalesce(p_data, '{}'::jsonb), auth.uid());
$fn$;
revoke all on function _qarz_ob_tarix_yoz(uuid, text, jsonb) from public, anon, authenticated;

-- Qator serializatori. asosiy/tolandi/qoldi/oylik_summa/kechikkan_summa — QARZ VALYUTASI birligida; summa — so'm ekvivalenti.
-- 🔴 Faqat jadvalning O'Z qatori bilan chaqiriladi (q.*), kengaytirilgan CTE qatori bilan emas.
create or replace function _qarz_ob_qator(q qarz_ob)
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  with t as (
    select coalesce(sum(case when q.valyuta <> 'UZS' then coalesce(t.fc_summa, 0) else t.summa end), 0) as tolandi,
           count(*) as soni
      from qarz_ob_tolov t where t.qarz_id = q.id and t.is_deleted = false
  ),
  j as (
    select min(j.sana) filter (where j.tolangan < j.summa) as keyingi_sana,
           coalesce(sum(j.summa - j.tolangan) filter (where j.tolangan < j.summa
                                                     and j.sana < (now() at time zone 'Asia/Tashkent')::date), 0) as kechikkan_summa
      from qarz_ob_jadval j where j.qarz_id = q.id
  ),
  a as (
    select case when q.valyuta <> 'UZS' then coalesce(q.fc_summa, 0) else q.summa end as asosiy
  )
  select jsonb_build_object(
    'id',              q.id,
    'yonalish',        q.yonalish,
    'kontragent',      q.kontragent,
    'telefon',         q.telefon,
    'kassa_id',        q.kassa_id,
    'kassa_kod',       (select ac.code from accounts ac where ac.id = q.kassa_id),
    'kassa_nom',       (select ac.name from accounts ac where ac.id = q.kassa_id),
    'eski_qarz',       q.eski_qarz,
    'valyuta',         q.valyuta,
    'summa',           q.summa,
    'fc_summa',        q.fc_summa,
    'asosiy',          a.asosiy,
    'tolandi',         t.tolandi,
    'qoldi',           greatest(a.asosiy - t.tolandi, 0),
    'muddat_turi',     q.muddat_turi,
    'boshlanish',      q.boshlanish,
    'tugash',          q.tugash,
    'oylar_soni',      q.oylar_soni,
    'oylik_summa',     q.oylik_summa,
    'keyingi_sana',    case when q.holat = 'faol' then j.keyingi_sana end,
    'kechikkan_kun',   case when q.holat = 'faol' and j.keyingi_sana < (now() at time zone 'Asia/Tashkent')::date
                            then ((now() at time zone 'Asia/Tashkent')::date - j.keyingi_sana) else 0 end,
    'kechikkan_summa', case when q.holat = 'faol' then j.kechikkan_summa else 0 end,
    'holat',           q.holat,
    'izoh',            q.izoh,
    'sana',            q.sana,
    'kim',             (select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = q.created_by),
    'created_at',      q.created_at,
    'yopilgan_at',     q.yopilgan_at,
    'bekor_sabab',     q.bekor_sabab,
    'created_by',      q.created_by,
    'entry_id',        q.entry_id,
    'bekor_mumkin',    (q.holat = 'faol' and t.soni = 0 and (coalesce(is_admin(), false) or q.created_by = auth.uid()))
  )
  from t, j, a;
$fn$;
revoke all on function _qarz_ob_qator(qarz_ob) from public, anon, authenticated;

-- ######## 5) KASSALAR RO'YXATI (foydalanuvchi amaliyot qila oladigan Provodka kassalari + qoldiq) ########
-- sorov_kassa_bal / acc_fc_balance authenticated'ga yopiq (ichki) — qoldiq shu RPC orqali ko'rsatiladi.
-- Filtr: pul hisobi (aktiv, kod 5 bilan), faol, konteyner emas, perm_check_accounts (admin hammasini ko'radi).
create or replace function qarz_ob_kassalar()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null or not qarz_ob_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id, 'code', a.code, 'name', a.name,
             'subtitle', to_jsonb(a) ->> 'subtitle',
             'currency', coalesce(a.currency, 'UZS'),
             'parent_id', a.parent_id,
             'pul_turi', to_jsonb(a) ->> 'pul_turi',
             'kassa_turi', to_jsonb(a) ->> 'kassa_turi',
             'qoldiq', sorov_kassa_bal(a.id),
             'fc_qoldiq', case when coalesce(a.currency, 'UZS') <> 'UZS' then acc_fc_balance(a.id) end
           ) order by a.code)
      from accounts a
     where a.type = 'aktiv' and a.code like '5%' and a.is_active
       and to_jsonb(a) ->> 'kassa_turi' is distinct from 'xarajat_guruh'
       and perm_check_accounts(array[a.id])
  ), '[]'::jsonb));
end
$fn$;
revoke all on function qarz_ob_kassalar() from public, anon;
grant execute on function qarz_ob_kassalar() to authenticated;

-- ######## 6) YARATISH 🔴 PUL HARAKATI ########
create or replace function qarz_ob_yarat(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid       uuid    := auth.uid();
  v_yon       text    := nullif(p->>'yonalish', '');
  v_kassa     uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_eski      boolean := coalesce((p->>'eski_qarz')::boolean, false);
  v_val_p     text    := upper(nullif(btrim(coalesce(p->>'valyuta', '')), ''));
  v_summa     numeric := nullif(p->>'summa', '')::numeric;
  v_fc        numeric := nullif(p->>'fc_summa', '')::numeric;
  v_ism       text    := nullif(btrim(coalesce(p->>'kontragent', '')), '');
  v_tel       text    := nullif(btrim(coalesce(p->>'telefon', '')), '');
  v_mt        text    := nullif(p->>'muddat_turi', '');
  v_tugash    date    := nullif(p->>'tugash', '')::date;
  v_bosh      date    := nullif(p->>'boshlanish', '')::date;
  v_oylar     int     := nullif(p->>'oylar_soni', '')::int;
  v_sana      date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_izoh      text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_ext       text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  v_ka        accounts;
  v_val       text    := 'UZS';
  v_kurs      numeric;
  v_asosiy    numeric;
  v_oylik     numeric;
  v_used      numeric := 0;
  v_row       numeric;
  v_i         int;
  v_id        uuid    := gen_random_uuid();
  v_entry     uuid;
  v_exist     uuid;
  v_4720      uuid;
  v_6820      uuid;
  v_kap       uuid;
  v_dt        uuid;
  v_kt        uuid;
  v_desc      text;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Avtorizatsiya kerak'); end if;
  if not qarz_ob_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Qarz oldi-berdi sahifasi ruxsatingizda yoq'); end if;

  if v_ext is not null then
    select id into v_exist from qarz_ob where ext_ref = v_ext;
    if found then return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist); end if;
  end if;

  if v_yon is null or v_yon not in ('oldik', 'berdik') then return jsonb_build_object('ok', false, 'kod', 'yonalish_notogri'); end if;
  if v_eski and v_yon <> 'oldik' then return jsonb_build_object('ok', false, 'kod', 'eski_faqat_oldik'); end if;
  if v_ism is null or length(v_ism) < 2 then return jsonb_build_object('ok', false, 'kod', 'kontragent_kerak'); end if;
  if v_izoh is null or length(v_izoh) < 3 then return jsonb_build_object('ok', false, 'kod', 'izoh_kerak'); end if;

  -- muddat
  if v_mt = 'bir_martalik' then
    if v_tugash is null or v_tugash < v_sana then return jsonb_build_object('ok', false, 'kod', 'muddat_notogri'); end if;
    v_bosh := null; v_oylar := null;
  elsif v_mt = 'oylik' then
    if v_bosh is null or v_oylar is null or v_oylar < 1 or v_oylar > 120 then
      return jsonb_build_object('ok', false, 'kod', 'muddat_notogri');
    end if;
    v_tugash := _qarz_ob_oy_qosh(v_bosh, v_oylar - 1);
  else
    return jsonb_build_object('ok', false, 'kod', 'muddat_notogri');
  end if;

  -- kassa / valyuta
  if v_eski then
    v_kassa := null;
    if v_val_p is null or v_val_p not in ('UZS', 'USD') then return jsonb_build_object('ok', false, 'kod', 'valyuta_notogri'); end if;
    v_val := v_val_p;
  else
    if v_kassa is null then return jsonb_build_object('ok', false, 'kod', 'kassa_kerak'); end if;
    select * into v_ka from accounts where id = v_kassa;
    if not found or v_ka.is_active is distinct from true then return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi'); end if;
    if v_ka.type <> 'aktiv' or v_ka.code not like '5%' or to_jsonb(v_ka) ->> 'kassa_turi' is not distinct from 'xarajat_guruh' then
      return jsonb_build_object('ok', false, 'kod', 'kassa_emas');
    end if;
    if not perm_check_accounts(array[v_kassa]) then return jsonb_build_object('ok', false, 'kod', 'kassa_ruxsat'); end if;
    v_val := coalesce(v_ka.currency, 'UZS');
  end if;

  -- summa (qarz valyutasi birligida) va so'm ekvivalenti
  if v_val = 'UZS' then
    v_fc := null;
    if v_summa is null or v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
  else
    if v_fc is null or v_fc <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    v_kurs := conv_baza_kurs(v_val);
    if v_kurs is null or v_kurs <= 0 then return jsonb_build_object('ok', false, 'kod', 'kurs_yoq'); end if;
    v_summa := round(v_fc * v_kurs);
    if v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
  end if;

  -- hisoblar
  select id into v_4720 from accounts where code = '4720' and is_active;
  select id into v_6820 from accounts where code = '6820' and is_active;
  v_kap := _qarz_ob_kapital_id();
  if v_yon = 'berdik' and v_4720 is null then raise exception '4720 hisobi topilmadi' using errcode = '22000'; end if;
  if v_yon = 'oldik' and v_6820 is null then raise exception '6820 hisobi topilmadi — PROVODKA_QARZ_OB.sql 2-bolimi' using errcode = '22000'; end if;
  if v_eski and v_kap is null then raise exception 'Boshlang''ich qoldiq (kapital) hisobi topilmadi' using errcode = '22000'; end if;

  -- berdik: kassada pul yetadimi (qarz valyutasi birligida)
  if v_yon = 'berdik' then
    perform pg_advisory_xact_lock(hashtext('qarz_ob_kassa:' || v_kassa::text));
    if v_val = 'UZS' then
      if sorov_kassa_bal(v_kassa) < v_summa then return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi'); end if;
    else
      if acc_fc_balance(v_kassa) < v_fc then return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi'); end if;
    end if;
  end if;

  v_asosiy := case when v_val <> 'UZS' then v_fc else v_summa end;
  if v_mt = 'oylik' then
    v_oylik := case when v_val <> 'UZS' then round(v_asosiy / v_oylar, 2) else floor(v_asosiy / v_oylar) end;
    if v_oylik <= 0 then return jsonb_build_object('ok', false, 'kod', 'muddat_notogri'); end if;
  end if;

  -- yozuv
  if v_yon = 'berdik' then
    v_dt := v_4720; v_kt := v_kassa; v_desc := 'Qarz berildi: ' || v_ism;
  elsif v_eski then
    v_dt := v_kap;  v_kt := v_6820;  v_desc := 'Eski qarz (boshlang''ich qoldiq): ' || v_ism;
  else
    v_dt := v_kassa; v_kt := v_6820; v_desc := 'Qarz olindi: ' || v_ism;
  end if;
  v_desc := v_desc || ' · ' || case when v_mt = 'bir_martalik' then 'muddat ' || to_char(v_tugash, 'DD.MM.YYYY')
                                    else v_oylar::text || ' oy' end || ' · ' || v_izoh;

  insert into entry (entry_date, description, source, status, ext_ref, created_by, filial_ids)
  values (v_sana, v_desc, 'qarz', 'posted', 'qarz_ob:' || v_id::text, v_uid, '{}'::uuid[])
  returning id into v_entry;

  -- Dt birinchi. fc_amount faqat valyutali KASSA satrida (Dt ham, Kt ham musbat; hisob signi debit/credit dan)
  insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
  values (v_entry, v_dt, v_summa, 0,
          case when v_yon = 'oldik' and not v_eski and v_val <> 'UZS' then v_fc end);
  insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
  values (v_entry, v_kt, 0, v_summa,
          case when v_yon = 'berdik' and v_val <> 'UZS' then v_fc end);

  insert into qarz_ob (id, yonalish, kassa_id, eski_qarz, valyuta, summa, fc_summa, kontragent, telefon,
                       muddat_turi, boshlanish, tugash, oylar_soni, oylik_summa, sana, izoh, holat, ext_ref, entry_id, created_by)
  values (v_id, v_yon, v_kassa, v_eski, v_val, v_summa, v_fc, v_ism, v_tel,
          v_mt, v_bosh, v_tugash, v_oylar, v_oylik, v_sana, v_izoh, 'faol', v_ext, v_entry, v_uid);

  -- grafik
  if v_mt = 'bir_martalik' then
    insert into qarz_ob_jadval (qarz_id, n, sana, summa) values (v_id, 1, v_tugash, v_asosiy);
  else
    for v_i in 1..v_oylar loop
      if v_i < v_oylar then v_row := v_oylik; v_used := v_used + v_row;
      else v_row := v_asosiy - v_used; end if;   -- oxirgi oy qoldiqni oladi
      insert into qarz_ob_jadval (qarz_id, n, sana, summa) values (v_id, v_i, _qarz_ob_oy_qosh(v_bosh, v_i - 1), v_row);
    end loop;
  end if;

  perform _qarz_ob_tarix_yoz(v_id, 'yaratildi',
    jsonb_build_object('yonalish', v_yon, 'kassa_id', v_kassa, 'eski_qarz', v_eski, 'valyuta', v_val, 'summa', v_summa,
                       'fc_summa', v_fc, 'kontragent', v_ism, 'muddat_turi', v_mt, 'tugash', v_tugash, 'oylar_soni', v_oylar,
                       'entry_id', v_entry));
  return jsonb_build_object('ok', true, 'id', v_id, 'entry_id', v_entry);
exception
  when unique_violation then
    select id into v_exist from qarz_ob where ext_ref = v_ext;
    if v_exist is not null then return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist); end if;
    raise;
end
$fn$;
revoke all on function qarz_ob_yarat(jsonb) from public, anon;
grant execute on function qarz_ob_yarat(jsonb) to authenticated;

-- ######## 7) TO'LOV (qaytarish, FIFO) 🔴 PUL HARAKATI ########
create or replace function qarz_ob_tolov(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid    := auth.uid();
  v_qid     uuid    := nullif(p->>'qarz_id', '')::uuid;
  v_kassa   uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_summa   numeric := nullif(p->>'summa', '')::numeric;
  v_fc      numeric := nullif(p->>'fc_summa', '')::numeric;
  v_sana    date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_izoh    text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_ext     text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  q         qarz_ob;
  v_ka      accounts;
  v_val     text;
  v_birlik  numeric;
  v_asosiy  numeric;
  v_qoldi   numeric;
  v_som     numeric;
  v_oldin   numeric;
  v_rem     numeric;
  v_alloc   numeric;
  jr        record;
  v_tid     uuid := gen_random_uuid();
  v_entry   uuid;
  v_4720    uuid;
  v_6820    uuid;
  v_dt      uuid;
  v_kt      uuid;
  v_all     boolean;
  v_exist   uuid;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Avtorizatsiya kerak'); end if;
  if not qarz_ob_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Qarz oldi-berdi sahifasi ruxsatingizda yoq'); end if;
  if v_ext is not null then
    select id into v_exist from qarz_ob_tolov where ext_ref = v_ext;
    if found then return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist); end if;
  end if;

  select * into q from qarz_ob where id = v_qid for update;
  if not found then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if q.holat <> 'faol' then return jsonb_build_object('ok', false, 'kod', 'holat'); end if;

  -- kassa MAJBURIY (ikkala yo'nalishda ham)
  if v_kassa is null then return jsonb_build_object('ok', false, 'kod', 'kassa_kerak'); end if;
  select * into v_ka from accounts where id = v_kassa;
  if not found or v_ka.is_active is distinct from true then return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi'); end if;
  if v_ka.type <> 'aktiv' or v_ka.code not like '5%' or to_jsonb(v_ka) ->> 'kassa_turi' is not distinct from 'xarajat_guruh' then
    return jsonb_build_object('ok', false, 'kod', 'kassa_emas');
  end if;
  if not perm_check_accounts(array[v_kassa]) then return jsonb_build_object('ok', false, 'kod', 'kassa_ruxsat'); end if;
  v_val := coalesce(v_ka.currency, 'UZS');
  if v_val <> q.valyuta then return jsonb_build_object('ok', false, 'kod', 'valyuta_mos_emas'); end if;

  if q.valyuta = 'UZS' then
    v_fc := null;
    if v_summa is null or v_summa <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    v_birlik := v_summa;
  else
    if v_fc is null or v_fc <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;
    v_birlik := v_fc;
  end if;
  v_asosiy := case when q.valyuta <> 'UZS' then coalesce(q.fc_summa, 0) else q.summa end;

  select coalesce(sum(j.summa - j.tolangan), 0) into v_qoldi from qarz_ob_jadval j where j.qarz_id = q.id;
  if v_birlik > v_qoldi + 0.009 then return jsonb_build_object('ok', false, 'kod', 'kop', 'qoldi', v_qoldi); end if;

  -- so'm ekvivalenti: qarz berilgan kurs bo'yicha proporsional; oxirgi (yopuvchi) to'lov qoldiq so'mni oladi
  if q.valyuta = 'UZS' then
    v_som := v_summa;
  else
    select coalesce(sum(t.summa), 0) into v_oldin from qarz_ob_tolov t where t.qarz_id = q.id and t.is_deleted = false;
    if v_birlik >= v_qoldi - 0.009 then v_som := q.summa - v_oldin;
    else v_som := round(v_birlik * q.summa / v_asosiy); end if;
  end if;
  if v_som <= 0 then return jsonb_build_object('ok', false, 'kod', 'summa_notogri'); end if;

  select id into v_4720 from accounts where code = '4720' and is_active;
  select id into v_6820 from accounts where code = '6820' and is_active;
  if q.yonalish = 'berdik' and v_4720 is null then raise exception '4720 hisobi topilmadi' using errcode = '22000'; end if;
  if q.yonalish = 'oldik' and v_6820 is null then raise exception '6820 hisobi topilmadi' using errcode = '22000'; end if;

  perform pg_advisory_xact_lock(hashtext('qarz_ob_kassa:' || v_kassa::text));
  -- oldik qaytarilganda pul kassadan CHIQADI — qoldiq yetishi shart
  if q.yonalish = 'oldik' then
    if q.valyuta = 'UZS' then
      if sorov_kassa_bal(v_kassa) < v_som then return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi'); end if;
    else
      if acc_fc_balance(v_kassa) < v_fc then return jsonb_build_object('ok', false, 'kod', 'qoldiq_yetmadi'); end if;
    end if;
    v_dt := v_6820; v_kt := v_kassa;
  else
    v_dt := v_kassa; v_kt := v_4720;
  end if;

  insert into entry (entry_date, description, source, status, ext_ref, created_by, filial_ids)
  values (v_sana,
          case when q.yonalish = 'berdik' then 'Qarz qaytarildi: ' else 'Qarz to''landi: ' end || q.kontragent
            || coalesce(' · ' || v_izoh, ''),
          'qarz', 'posted', 'qarz_ob_tolov:' || v_tid::text, v_uid, '{}'::uuid[])
  returning id into v_entry;

  insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
  values (v_entry, v_dt, v_som, 0, case when q.yonalish = 'berdik' and v_val <> 'UZS' then v_fc end);
  insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
  values (v_entry, v_kt, 0, v_som, case when q.yonalish = 'oldik' and v_val <> 'UZS' then v_fc end);

  insert into qarz_ob_tolov (id, qarz_id, kassa_id, valyuta, summa, fc_summa, sana, izoh, entry_id, ext_ref, created_by)
  values (v_tid, q.id, v_kassa, q.valyuta, v_som, v_fc, v_sana, v_izoh, v_entry, v_ext, v_uid);

  -- FIFO — eng eski to'lanmagan qatordan
  v_rem := v_birlik;
  for jr in select * from qarz_ob_jadval where qarz_id = q.id and tolangan < summa order by n for update loop
    exit when v_rem <= 0;
    v_alloc := least(v_rem, jr.summa - jr.tolangan);
    update qarz_ob_jadval set tolangan = tolangan + v_alloc where id = jr.id;
    v_rem := v_rem - v_alloc;
  end loop;

  select not exists (select 1 from qarz_ob_jadval where qarz_id = q.id and tolangan < summa) into v_all;
  if v_all then
    update qarz_ob set holat = 'yopildi', yopilgan_at = now() where id = q.id;
  end if;

  perform _qarz_ob_tarix_yoz(q.id, 'tolov',
    jsonb_build_object('tolov_id', v_tid, 'kassa_id', v_kassa, 'summa', v_som, 'fc_summa', v_fc, 'entry_id', v_entry, 'yopildi', v_all));
  return jsonb_build_object('ok', true, 'id', v_tid, 'entry_id', v_entry, 'holat', case when v_all then 'yopildi' else 'faol' end,
                            'qoldi', greatest(v_qoldi - v_birlik, 0));
exception
  when unique_violation then
    select id into v_exist from qarz_ob_tolov where ext_ref = v_ext;
    if v_exist is not null then return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist); end if;
    raise;
end
$fn$;
revoke all on function qarz_ob_tolov(jsonb) from public, anon;
grant execute on function qarz_ob_tolov(jsonb) to authenticated;

-- ######## 8) BEKOR (to'lov yo'q bo'lsa; admin yoki yaratgan) — pul harakati ham qaytariladi ########
create or replace function qarz_ob_bekor(p_id uuid, p_sabab text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  q       qarz_ob;
  v_sabab text := nullif(btrim(coalesce(p_sabab, '')), '');
  v_ism   text;
  v_snap  jsonb;
begin
  if v_uid is null or not qarz_ob_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  if v_sabab is null or length(v_sabab) < 3 then return jsonb_build_object('ok', false, 'kod', 'sabab_kerak'); end if;
  select * into q from qarz_ob where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  if q.holat <> 'faol' then return jsonb_build_object('ok', false, 'kod', 'holat'); end if;
  if not (coalesce(is_admin(), false) or q.created_by = v_uid) then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  if exists (select 1 from qarz_ob_tolov where qarz_id = q.id and is_deleted = false) then
    return jsonb_build_object('ok', false, 'kod', 'tolov_bor');
  end if;

  v_ism := _qarz_ob_ism();
  if q.entry_id is not null then
    -- jurnalning o'chirish naqshi: avval eski nusxa entry_history ga, so'ng soft-delete
    select to_jsonb(e) || jsonb_build_object('entry_line', coalesce((select jsonb_agg(to_jsonb(l)) from entry_line l where l.entry_id = e.id), '[]'::jsonb))
      into v_snap from entry e where e.id = q.entry_id;
    insert into entry_history (entry_id, action, snapshot, changed_by_name) values (q.entry_id, 'delete', v_snap, v_ism);
    update entry set is_deleted = true, deleted_at = now(), deleted_by_name = v_ism where id = q.entry_id and is_deleted = false;
  end if;

  update qarz_ob set holat = 'bekor', bekor_sabab = v_sabab, bekor_by = v_uid, bekor_at = now() where id = q.id;
  perform _qarz_ob_tarix_yoz(q.id, 'bekor', jsonb_build_object('sabab', v_sabab, 'entry_id', q.entry_id));
  return jsonb_build_object('ok', true, 'id', q.id);
end
$fn$;
revoke all on function qarz_ob_bekor(uuid, text) from public, anon;
grant execute on function qarz_ob_bekor(uuid, text) to authenticated;

-- ######## 9) STAT (ichki) + DASH ########
-- Faol qarzlar qoldig'i (yo'nalish x valyuta, qarz valyutasi birligida) va kechikkanlar (valyuta bo'yicha).
create or replace function _qarz_ob_stat()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  with today as (select (now() at time zone 'Asia/Tashkent')::date as d),
  b as (
    select q.id, q.yonalish, q.valyuta, q.holat,
           coalesce(sum(j.summa - j.tolangan), 0) as qoldi,
           min(j.sana) filter (where j.tolangan < j.summa) as keyingi,
           coalesce(sum(j.summa - j.tolangan) filter (where j.tolangan < j.summa and j.sana < (select d from today)), 0) as kech
      from qarz_ob q left join qarz_ob_jadval j on j.qarz_id = q.id
     group by q.id, q.yonalish, q.valyuta, q.holat
  )
  select jsonb_build_object(
    'faol_soni',      (select count(*) from b where holat = 'faol'),
    'kechikkan_soni', (select count(*) from b where holat = 'faol' and keyingi < (select d from today)),
    'yopildi_soni',   (select count(*) from b where holat = 'yopildi'),
    'qoldiq', coalesce((select jsonb_agg(jsonb_build_object('yonalish', yonalish, 'valyuta', valyuta, 'soni', soni, 'qoldi', qoldi)
                                         order by yonalish, valyuta)
                          from (select yonalish, valyuta, count(*) as soni, sum(qoldi) as qoldi
                                  from b where holat = 'faol' group by yonalish, valyuta) x), '[]'::jsonb),
    'kechikkan', coalesce((select jsonb_agg(jsonb_build_object('valyuta', valyuta, 'soni', soni, 'summa', summa) order by valyuta)
                             from (select valyuta, count(*) as soni, sum(kech) as summa
                                     from b where holat = 'faol' and keyingi < (select d from today) group by valyuta) y), '[]'::jsonb)
  );
$fn$;
revoke all on function _qarz_ob_stat() from public, anon, authenticated;

create or replace function qarz_ob_dash()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null or not qarz_ob_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  return jsonb_build_object('ok', true, 'stat', _qarz_ob_stat());
end
$fn$;
revoke all on function qarz_ob_dash() from public, anon;
grant execute on function qarz_ob_dash() to authenticated;

-- ######## 10) RO'YXAT ########
create or replace function qarz_ob_royxat(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_holat  text := nullif(p->>'holat', '');
  v_yon    text := nullif(p->>'yonalish', '');
  v_q      text := nullif(btrim(coalesce(p->>'q', '')), '');
  v_limit  int  := least(greatest(coalesce(nullif(p->>'limit', '')::int, 50), 1), 500);
  v_offset int  := greatest(coalesce(nullif(p->>'offset', '')::int, 0), 0);
  v_today  date := (now() at time zone 'Asia/Tashkent')::date;
  v_rows   jsonb; v_jami int;
begin
  if auth.uid() is null or not qarz_ob_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;

  with base as (
    select q.id, q.holat, q.created_at,
           (select min(j.sana) from qarz_ob_jadval j where j.qarz_id = q.id and j.tolangan < j.summa) as keyingi_sana
      from qarz_ob q
     where (v_yon is null or q.yonalish = v_yon)
       and (v_q is null or q.kontragent ilike '%' || v_q || '%' or coalesce(q.telefon, '') ilike '%' || v_q || '%'
            or q.izoh ilike '%' || v_q || '%')
  ),
  f as (
    select b.* from base b
     where v_holat is null
        or (v_holat = 'kechikkan' and b.holat = 'faol' and b.keyingi_sana < v_today)
        or (v_holat <> 'kechikkan' and b.holat = v_holat)
  )
  select coalesce((
           -- 🔴 _qarz_ob_qator(q.*) — jadvalning O'Z qatori (f/x da qo'shimcha ustun bor, row type mos kelmaydi)
           select jsonb_agg(_qarz_ob_qator(q.*) order by
                    (x.holat = 'faol') desc,
                    (x.holat = 'faol' and x.keyingi_sana < v_today) desc,
                    x.keyingi_sana asc nulls last,
                    x.created_at desc)
             from (select f.id, f.holat, f.keyingi_sana, f.created_at
                     from f
                    order by (f.holat = 'faol') desc, (f.holat = 'faol' and f.keyingi_sana < v_today) desc,
                             f.keyingi_sana asc nulls last, f.created_at desc
                    limit v_limit offset v_offset) x
             join qarz_ob q on q.id = x.id
         ), '[]'::jsonb),
         (select count(*) from f)
    into v_rows, v_jami;

  return jsonb_build_object('ok', true, 'rows', v_rows, 'jami', v_jami, 'stat', _qarz_ob_stat());
end
$fn$;
revoke all on function qarz_ob_royxat(jsonb) from public, anon;
grant execute on function qarz_ob_royxat(jsonb) to authenticated;

-- ######## 11) KARTA ########
create or replace function qarz_ob_kart(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  q qarz_ob;
  v_today date := (now() at time zone 'Asia/Tashkent')::date;
begin
  if auth.uid() is null or not qarz_ob_page_ok() then return jsonb_build_object('ok', false, 'kod', 'ruxsat'); end if;
  select * into q from qarz_ob where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'kod', 'topilmadi'); end if;
  return jsonb_build_object(
    'ok', true,
    'qarz', _qarz_ob_qator(q),
    'jadval', coalesce((
      select jsonb_agg(jsonb_build_object(
               'n', j.n, 'sana', j.sana, 'summa', j.summa, 'tolangan', j.tolangan,
               'holat', case when j.tolangan >= j.summa then 'tolandi'
                             when j.tolangan > 0 and j.sana < v_today and q.holat = 'faol' then 'kechikkan'
                             when j.tolangan > 0 then 'qisman'
                             when j.sana < v_today and q.holat = 'faol' then 'kechikkan'
                             else 'kutilmoqda' end) order by j.n)
        from qarz_ob_jadval j where j.qarz_id = q.id), '[]'::jsonb),
    'tolovlar', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'sana', t.sana, 'summa', t.summa, 'fc_summa', t.fc_summa, 'valyuta', t.valyuta,
               'kassa_kod', (select ac.code from accounts ac where ac.id = t.kassa_id),
               'kassa_nom', (select ac.name from accounts ac where ac.id = t.kassa_id),
               'izoh', t.izoh, 'created_at', t.created_at, 'entry_id', t.entry_id,
               'kim', (select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = t.created_by)
             ) order by t.sana desc, t.created_at desc)
        from qarz_ob_tolov t where t.qarz_id = q.id and t.is_deleted = false), '[]'::jsonb),
    'tarix', coalesce((
      select jsonb_agg(jsonb_build_object('hodisa', h.hodisa, 'data', h.data, 'vaqt', h.vaqt,
               'kim_nom', (select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = h.kim)) order by h.vaqt desc)
        from qarz_ob_tarix h where h.qarz_id = q.id), '[]'::jsonb)
  );
end
$fn$;
revoke all on function qarz_ob_kart(uuid) from public, anon;
grant execute on function qarz_ob_kart(uuid) to authenticated;

notify pgrst, 'reload schema';

-- ######## 12) TEKSHIRUV ########
select (select count(*) from qarz_ob) as qarz_soni,
       ('qarz_ob' = any(perm_pages())) as perm_pages_da,
       (select string_agg(code || ' ' || type, ' | ' order by code) from accounts
         where code = '6820' or (type = 'kapital' and lower(name) like 'boshlang%qoldiq%olingan qarzlar')) as yangi_hisoblar;
