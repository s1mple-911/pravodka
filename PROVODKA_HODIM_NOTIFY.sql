-- ============================================================================
-- PROVODKA_HODIM_NOTIFY.sql
-- Hodim kassasidagi HAR harakat uchun Telegram xabari.
--   kirim · chiqim · transfer (kirim/chiqim) · tahrir · o'chirish
-- Xabar matni: "shuncha bor edi — shuncha ketti/keldi — shuncha qoldi".
--
-- ⛔ ADDITIVE. Birorta mavjud ustun/funksiya/imzo o'zgarmaydi.
--    Yangi: 2 jadval, 8 funksiya, 2 trigger.
--    Qayta RUN qilish xavfsiz (idempotent).
--
-- ⚠️ `create trigger` `entry_line` va `entry` ga ACCESS EXCLUSIVE lock oladi
--    (bir zumga). Kam yuklamali paytda RUN qiling.
--
-- ARXITEKTURA — nega OUTBOX (jadval), to'g'ridan webhook emas:
--   Trigger ichidan HTTP chaqirsak (pg_net) — tarmoq nosozligida xabar
--   YO'QOLADI va hech kim bilmaydi; sekin bo'lsa provodka saqlanishi
--   sekinlashadi. Shuning uchun trigger faqat LOKAL jadvalga yozadi
--   (mikrosoniya), n8n esa har daqiqada o'qib yuboradi va `sent_at` qo'yadi.
--
-- 🔴 XABAR HECH QACHON PULNI TO'SMAYDI: ikkala trigger ham FAIL-OPEN
--    (`exception when others` -> `raise warning` + davom). Xabar tizimidagi
--    har qanday nosozlik provodka yozilishini to'xtatmaydi.
--
-- 🔴 KOMPENSATSIYA HIMOYASI: Provodka yozuvi tranzaksiyada emas
--    (entry insert → entry_line insert → xato bo'lsa entry qo'lda delete).
--    Shuning uchun (a) `entry_id ... on delete cascade`; (b) navbat faqat
--    30 soniyadan OSHGAN qatorlarni beradi va yozuv hamon `posted` +
--    o'chirilmaganini QAYTA tekshiradi.
--
-- OMMAVIY SKRIPT UCHUN O'CHIRGICH (tuzatish/migratsiya 62 hodimga spam
-- qilmasin). ⚠️ `set local` FAQAT ochiq tranzaksiya ichida ishlaydi —
-- Supabase editorida alohida qator sifatida yozilsa JIMGINA e'tiborsiz
-- qoladi. Shuning uchun har doim `begin; ... commit;` bilan:
--    begin;
--      set local provodka.notify_off = '1';
--      ... insert/update ...
--    commit;
-- Ommaviy yozuvda bu TAVSIYA emas, MAJBURIY: bitta tranzaksiyada 64 tadan
-- ko'p hodim satri yozilsa subtranzaksiya (savepoint) overflow bo'ladi va
-- shu vaqtda parallel sessiyalar sekinlashadi.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. OUTBOX jadval
-- ---------------------------------------------------------------------------
-- `delta` — ISHORALI: musbat = kassaga kirdi, manfiy = kassadan chiqdi.
-- `dt_yon` — satrning ASL yo'nalishi (Dt tomonda edimi). 🔴 Qarshi tomonni
--   izlash SHUNGA tayanadi, `delta` ishorasiga EMAS: o'chirishda va summani
--   kamaytiruvchi tahrirda delta teskari bo'lib, qarshi tomon sifatida
--   kassaning O'ZI chiqib qolardi ("Ijara" o'rniga "Abror · Naqd").
-- Kirim/chiqim/transfer ajratmasi bu yerda SAQLANMAYDI — u yuborish paytida
--   hisoblanadi (trigger ishlaganda qarshi tomon hali yozilmagan bo'lishi
--   mumkin). `hodisa` faqat maxsus holatda ('tahrir' | 'ochirildi').
create table if not exists hodim_notify (
  id            bigserial primary key,
  entry_id      uuid          not null references entry(id) on delete cascade,
  line_ref      text,                       -- entry_line.id (turi noma'lum -> text)
  kassa_id      uuid          not null references accounts(id),  -- ROOT hodim kassasi
  acc_id        uuid,                       -- harakat qilgan aniq hisob (naqd/click/USD)
  delta         numeric(18,2) not null,     -- ishorali, so'mda
  fc            numeric(18,2),              -- ishorali, hisobning o'z valyutasida
  dt_yon        boolean       not null default false,
  hodisa        text,                       -- null | 'tahrir' | 'ochirildi'
  qoldiq_oldin  numeric(18,2),
  qoldiq_keyin  numeric(18,2),
  created_at    timestamptz   not null default now(),
  sent_at       timestamptz,
  attempts      int           not null default 0,
  last_error    text
);

-- Eski o'rnatma ustidan qayta RUN qilinsa yangi ustunlar qo'shilsin
alter table hodim_notify add column if not exists fc     numeric(18,2);
alter table hodim_notify add column if not exists dt_yon boolean not null default false;

create index if not exists idx_hodim_notify_pending
  on hodim_notify (id) where sent_at is null;
create index if not exists idx_hodim_notify_entry
  on hodim_notify (entry_id);
-- (entry, kassa) bo'yicha birlashtirish uchun (_hodim_notify_qoy)
create index if not exists idx_hodim_notify_merge
  on hodim_notify (entry_id, kassa_id) where sent_at is null;

alter table hodim_notify enable row level security;
-- ⚠️ POLICY ATAYLAB YO'Q: bu jadval faqat service_role (n8n) va
--    SECURITY DEFINER triggerlar uchun. `force row level security`
--    QO'YILMAYDI — aks holda trigger o'zi ham yoza olmay qoladi.
revoke all on table hodim_notify from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 2. Admin qabul qiluvchilar
-- ---------------------------------------------------------------------------
-- Hodim o'z kassasi haqidagi xabarni o'zi oladi; bu jadvaldagilar esa
-- HAMMA hodim kassasi harakatini oladi (nazorat uchun).
-- BO'SH bo'lsa — hech kimga qo'shimcha xabar ketmaydi (xavfsiz sukut).
create table if not exists hodim_notify_admin (
  telegram_id text primary key,
  ism         text,
  is_active   boolean     not null default true,
  added_at    timestamptz not null default now()
);

alter table hodim_notify_admin enable row level security;
revoke all on table hodim_notify_admin from public, anon, authenticated;

-- Adminlarni qo'shish (Asilbek to'ldiradi — Telegram raqam id'lari):
--   insert into hodim_notify_admin(telegram_id, ism) values
--     ('1255605633', 'Asilbek')
--   on conflict (telegram_id) do update set is_active = true;
-- Vaqtincha o'chirish:
--   update hodim_notify_admin set is_active = false where telegram_id = '...';


-- ---------------------------------------------------------------------------
-- 3. hodim_kassa_root — "bu hisob qaysi HODIM kassasiniki?"
-- ---------------------------------------------------------------------------
-- 🔴 REKURSIV (bir daraja emas). `hodim-dev.html` `subChildren()`/`walk()`
--    (840–846) nevaralarni ham yuradi: valyuta hisobi ba'zan pul turi
--    bolasining ostida ochiladi ("Ism · Naqd · USD"). Bir darajali ko'tarilish
--    bunda ROOT sifatida "· Naqd" ni qaytarib, xabardagi "qoldi" ni hodim
--    ekranidagi raqamdan boshqa qilib qo'yardi.
--
-- To'xtash sharti `kassa_root()` (PROVODKA_VALYUTA.sql) bilan bir xil:
-- hisob tur/valyuta bolasi bo'lsagina yuqoriga ko'tariladi. Hodim kassasining
-- o'zi ham `parent_id` ga ega (5400 guruh) — lekin u tur/valyuta bolasi EMAS,
-- shuning uchun aynan shu yerda to'xtaydi.
--
-- Hodim kassasi bo'lmasa null -> trigger darrov chiqib ketadi, ya'ni n8n
-- auto-sync yozadigan minglab filial satriga amalda ta'sir qilmaydi.
create or replace function hodim_kassa_root(p_account uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id uuid := p_account;
  v_a  accounts%rowtype;
  v_i  int := 0;
begin
  if p_account is null then return null; end if;
  loop
    select * into v_a from accounts where id = v_id;
    if not found then return null; end if;
    exit when v_a.parent_id is null;
    -- tur/valyuta bolasi emasmi -> shu ildiz
    exit when coalesce(v_a.currency, 'UZS') = 'UZS' and v_a.pul_turi is null;
    v_id := v_a.parent_id;
    v_i  := v_i + 1;
    if v_i > 8 then return null; end if;   -- sikl/buzuq daraxt himoyasi
  end loop;
  if v_a.kassa_turi = 'xarajat' then
    return v_a.id;
  end if;
  return null;
end $$;

-- 🔴 `authenticated` ga BERILMAYDI: funksiya SECURITY DEFINER, ya'ni RLS'ni
--    chetlab o'tadi. Triggerlar uni egasi (postgres) nomidan chaqiradi —
--    grant kerak emas. (PROVODKA_HODIM_TEZLIK.sql:41–44 dagi ogohlantirish.)
revoke all on function hodim_kassa_root(uuid) from public, anon, authenticated;
grant execute on function hodim_kassa_root(uuid) to service_role;

comment on function hodim_kassa_root(uuid) is
  'Hisob hodim (xarajat) kassasiga tegishli bo''lsa uning ROOT id''si, aks holda null. '
  'Rekursiv: nevara hisoblarni (Naqd · USD) ham to''g''ri ko''taradi.';


-- ---------------------------------------------------------------------------
-- 4. hodim_kassa_qoldiq — kassa kartasidagi raqam
-- ---------------------------------------------------------------------------
-- ROOT + BUTUN daraxt (naqd/click/payme/karta/USD va ularning bolalari).
-- Bu aynan `hodim-dev.html` kartasidagi jami raqam — xabardagi "qoldi"
-- sahifadagi raqamdan farq qilmasligi uchun boshqa formula ishlatilmaydi.
-- `idx_entry_line_account` indeksi bor (PROVODKA_HODIM_INDEKS.sql).
--
-- 🔴 `authenticated` ga BERILMAYDI — 3-bo'limdagi sabab (bu funksiya bilan
--    har foydalanuvchi istalgan hodimning qoldig'ini o'qiy olardi).
create or replace function hodim_kassa_qoldiq(p_root uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  with recursive daraxt as (
    select a.id, 0 as chuqur
      from accounts a
     where a.id = p_root
    union all
    select c.id, d.chuqur + 1
      from accounts c
      join daraxt d on c.parent_id = d.id
     where d.chuqur < 8
       and (coalesce(c.currency, 'UZS') <> 'UZS' or c.pul_turi is not null)
  )
  select coalesce(sum(l.debit - l.credit), 0)::numeric
    from entry_line l
    join entry e on e.id = l.entry_id
   where l.account_id in (select id from daraxt)
     and e.status = 'posted'
     and e.is_deleted = false;
$$;

revoke all on function hodim_kassa_qoldiq(uuid) from public, anon, authenticated;
grant execute on function hodim_kassa_qoldiq(uuid) to service_role;

comment on function hodim_kassa_qoldiq(uuid) is
  'Hodim kassasining jami qoldig''i: root + butun bola daraxti (posted, o''chirilmagan).';


-- ---------------------------------------------------------------------------
-- 5. _hodim_notify_qoy — outbox'ga qator qo'yadi (ichki)
-- ---------------------------------------------------------------------------
-- 🔴 BIR YOZUV + BIR KASSA = BIR XABAR. Yuborilmagan qator bo'lsa yangisi
--    qo'shilmaydi, mavjudi BIRLASHTIRILADI. Sababi `tur_convert()`
--    (PROVODKA_TUR_CONVERT.sql — hodim "Naqd → Click" qilsa) va bitta kassa
--    ichidagi `do_convert_v2`: bitta yozuvda shu kassaning IKKI satri bor.
--    Birlashtirmasak hodim ikkita xabar va hech qachon mavjud bo'lmagan
--    oraliq qoldiqni ko'rardi ("B+X bor edi"), kassa jami esa o'zgarmagan.
--    Yig'indi nolga teng bo'lsa — qator butunlay o'chiriladi (xabar yo'q).
--
-- ⚠️ Bu faylning AVVALGI tahriridagi 6-argumentli imzo olib tashlanadi.
--    `create or replace` argument ro'yxati o'zgarganda YANGI overload yaratadi,
--    eskisi esa bazada o'lik qolib ketardi (chalkashlik manbai). Funksiya ichki
--    (`revoke ... from public/anon/authenticated`), boshqa hech kim chaqirmaydi.
drop function if exists _hodim_notify_qoy(uuid, text, uuid, uuid, numeric, text);

create or replace function _hodim_notify_qoy(
  p_entry  uuid,
  p_line   text,
  p_root   uuid,
  p_acc    uuid,
  p_delta  numeric,
  p_fc     numeric default null,
  p_dt     boolean default false,
  p_hodisa text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_e     entry%rowtype;
  v_keyin numeric;
  v_old   hodim_notify%rowtype;
  v_delta numeric;
  v_fc    numeric;
begin
  if p_root is null or coalesce(p_delta, 0) = 0 then
    return;
  end if;

  select * into v_e from entry where id = p_entry;
  if not found then return; end if;
  if v_e.status is distinct from 'posted' then return; end if;

  -- O'chirilgan yozuvga faqat 'ochirildi' xabari qo'yiladi
  if coalesce(v_e.is_deleted, false) and coalesce(p_hodisa, '') <> 'ochirildi' then
    return;
  end if;

  v_keyin := hodim_kassa_qoldiq(p_root);

  -- 🔴 `attempts = 0` SHART: n8n qatorni AVVAL oladi (attempts++), Telegramga
  --    yuboradi, KEYIN `hodim_notify_sent` qiladi. Shu oynada kelgan tahrir
  --    allaqachon yuborilgan qatorga birlashsa, `hodim_notify_sent` uni yopib
  --    qo'yardi va tahrir haqidagi xabar HECH QACHON ketmasdi.
  -- 🔴 `skip locked`: qator n8n tranzaksiyasida qulflangan bo'lsa KUTMAYMIZ —
  --    yangi qator ochamiz. Kutish `exception when others` bilan ushlanmaydi
  --    (57014 query_canceled), ya'ni bu pul yo'lidagi yagona bloklanish
  --    nuqtasi bo'lardi. Eng yomoni — bitta o'rniga ikkita xabar.
  select * into v_old
    from hodim_notify
   where entry_id = p_entry and kassa_id = p_root
     and sent_at is null and attempts = 0
   order by id
   limit 1
   for update skip locked;

  if found then
    v_delta := v_old.delta + p_delta;
    v_fc    := coalesce(v_old.fc, 0) + coalesce(p_fc, 0);

    if v_delta = 0 then
      -- Kassa ichidagi o'tkazma (Naqd -> Click): jami o'zgarmadi, xabar shart emas
      delete from hodim_notify where id = v_old.id;
      return;
    end if;

    update hodim_notify
       set delta        = v_delta,
           fc           = nullif(v_fc, 0),
           -- Yo'nalish/hisob: qaysi satr KATTAROQ bo'lsa o'shanikini olamiz
           dt_yon       = case when abs(p_delta) > abs(v_old.delta) then p_dt  else v_old.dt_yon end,
           acc_id       = case when abs(p_delta) > abs(v_old.delta) then p_acc else v_old.acc_id end,
           line_ref     = case when abs(p_delta) > abs(v_old.delta) then p_line else v_old.line_ref end,
           -- 🔴 Yorliq: 'ochirildi' HAR DOIM ustun, aks holda ESKISI saqlanadi.
           --    `coalesce(v_old.hodisa, p_hodisa)` ikki joyda yolg'on gapirardi:
           --    (a) yangi yozuv 30s ichida tahrirlansa hodim hali birinchi
           --        xabarni olmagan holda "tahrirlandi" degan xabar olardi;
           --    (b) tahrirdan keyin o'chirilsa "tahrirlandi" bo'lib qolardi.
           hodisa       = case when p_hodisa = 'ochirildi' then 'ochirildi'
                               else v_old.hodisa end,
           qoldiq_keyin = v_keyin,
           qoldiq_oldin = v_keyin - v_delta,
           -- 30 soniyalik oyna qaytadan boshlanadi: yozuv to'liq bo'lsin.
           -- ⚠️ Lekin 5 daqiqadan ortiq cho'zilmasin — yozuvni har 20 soniyada
           --    tahrirlab tursa xabar abadiy kechikib qolardi.
           created_at   = least(v_old.created_at + interval '5 minutes', now())
     where id = v_old.id;
    return;
  end if;

  insert into hodim_notify(entry_id, line_ref, kassa_id, acc_id, delta, fc,
                           dt_yon, hodisa, qoldiq_oldin, qoldiq_keyin)
  values (p_entry, p_line, p_root, p_acc, p_delta, nullif(coalesce(p_fc, 0), 0),
          coalesce(p_dt, false), p_hodisa, v_keyin - p_delta, v_keyin);
end $$;

revoke all on function _hodim_notify_qoy(uuid, text, uuid, uuid, numeric, numeric, boolean, text)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 6. TRIGGER: entry_line — kirim / chiqim / transfer / tahrir
-- ---------------------------------------------------------------------------
-- 🔴 FAIL-OPEN: butun tana `exception when others` bilan o'ralgan. Xabar
--    tizimi (jadval huquqi, RLS, funksiya) buzilsa — xabar yo'qoladi, LEKIN
--    kirim/chiqim/xarajat/tahrir avvalgidek yoziladi. Xabar hech qachon
--    jonli foydalanuvchini to'sib qo'ymasligi kerak.
-- ⚠️ AFTER ROW: PostgreSQL bunday triggerlarni STATEMENT oxirida ishga
--    tushiradi, ya'ni ko'p satrli bitta insert'da qarshi tomon ko'rinadi.
--    Baribir tur (kirim/chiqim/transfer) YUBORISH paytida qayta hisoblanadi.
create or replace function hodim_notify_line_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_root uuid;
  v_old_root uuid;
  v_new_d    numeric;
  v_old_d    numeric;
  v_new_fc   numeric;
  v_old_fc   numeric;
begin
  -- Ommaviy tuzatish/migratsiya skripti uchun o'chirgich
  if coalesce(current_setting('provodka.notify_off', true), '') = '1' then
    return null;
  end if;

  if tg_op = 'INSERT' then
    v_new_root := hodim_kassa_root(new.account_id);
    if v_new_root is null then return null; end if;
    v_new_d  := coalesce(new.debit, 0) - coalesce(new.credit, 0);
    v_new_fc := case when coalesce(new.debit, 0) > 0
                     then coalesce(new.fc_amount, 0)
                     else -coalesce(new.fc_amount, 0) end;
    perform _hodim_notify_qoy(new.entry_id, new.id::text, v_new_root, new.account_id,
                              v_new_d, v_new_fc, coalesce(new.debit, 0) > 0, null);
    return null;
  end if;

  -- UPDATE = admin tahriri. jurnal-dev.html satrni UPDATE qiladi
  -- (o'chirib qayta yozmaydi), shuning uchun INSERT triggeri takror ishlamaydi.
  v_new_root := hodim_kassa_root(new.account_id);
  v_old_root := hodim_kassa_root(old.account_id);
  v_new_d    := coalesce(new.debit, 0) - coalesce(new.credit, 0);
  v_old_d    := coalesce(old.debit, 0) - coalesce(old.credit, 0);
  v_new_fc   := case when coalesce(new.debit, 0) > 0
                     then coalesce(new.fc_amount, 0) else -coalesce(new.fc_amount, 0) end;
  v_old_fc   := case when coalesce(old.debit, 0) > 0
                     then coalesce(old.fc_amount, 0) else -coalesce(old.fc_amount, 0) end;

  if v_new_root is not distinct from v_old_root then
    -- Kassa o'zgarmadi: faqat summa farqi xabar bo'ladi
    if v_new_root is not null and v_new_d <> v_old_d then
      perform _hodim_notify_qoy(new.entry_id, new.id::text, v_new_root, new.account_id,
                                v_new_d - v_old_d, v_new_fc - v_old_fc,
                                coalesce(new.debit, 0) > 0, 'tahrir');
    end if;
  else
    -- Kassa almashdi: eskisiga qaytdi, yangisiga tushdi (ikki xabar)
    if v_old_root is not null then
      perform _hodim_notify_qoy(new.entry_id, new.id::text, v_old_root, old.account_id,
                                -v_old_d, -v_old_fc, coalesce(old.debit, 0) > 0, 'tahrir');
    end if;
    if v_new_root is not null then
      perform _hodim_notify_qoy(new.entry_id, new.id::text, v_new_root, new.account_id,
                                v_new_d, v_new_fc, coalesce(new.debit, 0) > 0, 'tahrir');
    end if;
  end if;
  return null;

exception when others then
  -- 🔴 Provodka yozilishini TO'XTATMAYMIZ. Server logida qoladi.
  raise warning 'hodim_notify (line, %): %', tg_op, sqlerrm;
  return null;
end $$;

drop trigger if exists trg_hodim_notify_entry_line on entry_line;
create trigger trg_hodim_notify_entry_line
  after insert or update of account_id, debit, credit, fc_amount on entry_line
  for each row execute function hodim_notify_line_fn();


-- ---------------------------------------------------------------------------
-- 7. TRIGGER: entry — soft-delete
-- ---------------------------------------------------------------------------
-- "Hech narsa o'chirilmaydi" qoidasi: o'chirish = is_deleted=true.
-- Pul kassaga QAYTADI, shuning uchun delta ishorasi teskari (-d) —
-- lekin `dt_yon` ASL yo'nalishni saqlaydi (qarshi tomon to'g'ri topilsin).
create or replace function hodim_notify_entry_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare r record;
begin
  if coalesce(current_setting('provodka.notify_off', true), '') = '1' then
    return null;
  end if;

  if coalesce(old.is_deleted, false) = false
     and coalesce(new.is_deleted, false) = true then
    for r in
      select l.id::text as lid,
             l.account_id,
             coalesce(l.debit, 0) - coalesce(l.credit, 0) as d,
             case when coalesce(l.debit, 0) > 0
                  then coalesce(l.fc_amount, 0) else -coalesce(l.fc_amount, 0) end as fc,
             coalesce(l.debit, 0) > 0 as dt,
             hodim_kassa_root(l.account_id) as root
        from entry_line l
       where l.entry_id = new.id
    loop
      if r.root is not null and r.d <> 0 then
        perform _hodim_notify_qoy(new.id, r.lid, r.root, r.account_id,
                                  -r.d, -r.fc, r.dt, 'ochirildi');
      end if;
    end loop;
  end if;
  return null;

exception when others then
  raise warning 'hodim_notify (entry): %', sqlerrm;
  return null;
end $$;

drop trigger if exists trg_hodim_notify_entry on entry;
create trigger trg_hodim_notify_entry
  after update of is_deleted on entry
  for each row execute function hodim_notify_entry_fn();


-- ---------------------------------------------------------------------------
-- 8. hodim_notify_pending — n8n o'qiydigan navbat
-- ---------------------------------------------------------------------------
-- Qaytishi: { items: [...], adminlar: [{telegram_id, ism}] }
-- ⚠️ Chaqirilganda `attempts` OSHADI. Chegara 30 — n8n/Telegram bir necha
--    daqiqa ishlamay qolsa xabar yo'qolmasin (har daqiqada 1 urinish).
-- ⚠️ `for update ... skip locked` — ikki n8n run bir vaqtda tushsa bir xil
--    qatorlarni olib, hodimga dublikat xabar yubormasin.
create or replace function hodim_notify_pending(p_limit int default 50)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids   bigint[] := '{}';
  v_items jsonb;
  v_admin jsonb;
  r       record;
begin
  -- (a) TOZALASH: 30 soniya ichida o'chirilgan/bekor qilingan yozuvlarning
  --     qatorlari hech qachon tanlanmaydi va navbatda abadiy osilib qolardi.
  update hodim_notify n
     set sent_at = now(),
         last_error = 'yozuv o''chirilgan yoki posted emas'
    from entry e
   where e.id = n.entry_id
     and n.sent_at is null
     and coalesce(n.hodisa, '') <> 'ochirildi'
     and (e.is_deleted or e.status is distinct from 'posted');

  -- (b) Navbatdan olish
  for r in
    select n.id
      from hodim_notify n
      join entry e on e.id = n.entry_id
     where n.sent_at is null
       and n.attempts < 30
       and n.created_at < now() - interval '30 seconds'
       and e.status = 'posted'
       and (e.is_deleted = false or n.hodisa = 'ochirildi')
     order by n.id
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update of n skip locked
  loop
    v_ids := array_append(v_ids, r.id);
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
           'telegram_id', telegram_id, 'ism', coalesce(ism, '')
         )), '[]'::jsonb)
    into v_admin
    from hodim_notify_admin
   where is_active;

  if array_length(v_ids, 1) is null then
    return jsonb_build_object('items', '[]'::jsonb, 'adminlar', v_admin);
  end if;

  update hodim_notify set attempts = attempts + 1 where id = any(v_ids);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb) into v_items
  from (
    select
      n.id,
      n.entry_id,
      n.kassa_id,
      -- Tur: maxsus hodisa bo'lmasa qarshi tomondan aniqlanadi.
      -- 🔴 `section='pul'` bo'yicha — kod prefiksi (5xxx) bilan EMAS
      --    (jurnal-dev.html klass() bilan bir xil qoida).
      coalesce(n.hodisa,
        case when n.delta > 0
             then case when coalesce(q.qarshi_pul, false) then 'transfer_kirim' else 'kirim' end
             else case when coalesce(q.qarshi_pul, false) then 'transfer_chiqim' else 'chiqim' end
        end)                                  as hodisa,
      (n.delta > 0)                           as kirimmi,
      abs(n.delta)::numeric                   as summa,
      abs(coalesce(n.fc, 0))::numeric         as fc_summa,
      n.qoldiq_oldin,
      n.qoldiq_keyin,
      r.code                                  as kassa_kod,
      r.name                                  as kassa_nom,
      -- to_jsonb(...)->> : ustun yo'q bo'lsa ham so'rov yiqilmaydi
      to_jsonb(r) ->> 'subtitle'              as subtitle,
      to_jsonb(r) ->> 'taskfix_user_id'       as taskfix_user_id,
      to_jsonb(a) ->> 'pul_turi'              as pul_turi,
      coalesce(a.currency, 'UZS')             as valyuta,
      q.qarshi_kod,
      q.qarshi_nom,
      e.entry_date::text                      as sana,
      e.description                           as izoh,
      e.source                                as manba,
      -- 🔴 `full_name_or_email()` ga BOG'LANMAYDI: PROVODKA_ISM.sql RUN
      --    qilinmagan bazada butun RPC 42883 bilan yiqilardi.
      coalesce(
        nullif(to_jsonb(e)  ->> 'created_by_name', ''),
        nullif(to_jsonb(pr) ->> 'full_name', ''),
        '')                                   as kim
    from hodim_notify n
    join entry e    on e.id = n.entry_id
    join accounts r on r.id = n.kassa_id
    left join accounts a on a.id = n.acc_id
    -- ⚠️ `created_by` turi bazada aniqlanmagan (PROVODKA_ISM.sql 7.5) — uuid ham,
    --    matn ham bo'lishi mumkin. `::uuid` cast FAQAT to'liq uuid shaklida
    --    bajariladi; aks holda bitta buzuq qiymat 22P02 bilan BUTUN RPC ni
    --    yiqitardi (PROVODKA_AI_HISOBOT.sql dagi qat'iy shakl).
    left join profiles pr
      on pr.id = case when (to_jsonb(e) ->> 'created_by') ~ '^[0-9a-fA-F-]{36}$'
                      then (to_jsonb(e) ->> 'created_by')::uuid end
    left join lateral (
      select bool_or(a2.section = 'pul')        as qarshi_pul,
             string_agg(distinct a2.code, ', ') as qarshi_kod,
             string_agg(distinct a2.name, ', ') as qarshi_nom
        from entry_line l2
        join accounts a2 on a2.id = l2.account_id
       where l2.entry_id = n.entry_id
         -- 🔴 Yon ASL yo'nalishdan (n.dt_yon), `delta` ishorasidan EMAS:
         --    o'chirish va summani kamaytiruvchi tahrirda delta teskari
         --    bo'lib, qarshi tomon sifatida kassaning O'ZI chiqardi.
         and case when n.dt_yon then l2.credit else l2.debit end > 0
         -- Shu kassa daraxtining satrlari qarshi tomon emas
         and hodim_kassa_root(l2.account_id) is distinct from n.kassa_id
    ) q on true
   where n.id = any(v_ids)
  ) x;

  return jsonb_build_object('items', v_items, 'adminlar', v_admin);
end $$;

revoke all on function hodim_notify_pending(int) from public, anon, authenticated;
grant execute on function hodim_notify_pending(int) to service_role;

comment on function hodim_notify_pending(int) is
  'n8n uchun: yuborilmagan hodim-kassa xabarlari + admin qabul qiluvchilar. '
  'Chaqirilganda attempts oshadi (takror yuborishga qarshi).';


-- ---------------------------------------------------------------------------
-- 9. Yuborildi / xato belgilash
-- ---------------------------------------------------------------------------
create or replace function hodim_notify_sent(p_ids bigint[])
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_n int;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;
  update hodim_notify
     set sent_at = now(), last_error = null
   where id = any(p_ids) and sent_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function hodim_notify_fail(p_ids bigint[], p_err text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_n int;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;
  update hodim_notify
     set last_error = left(coalesce(p_err, ''), 500)
   where id = any(p_ids) and sent_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke all on function hodim_notify_sent(bigint[]) from public, anon, authenticated;
revoke all on function hodim_notify_fail(bigint[], text) from public, anon, authenticated;
grant execute on function hodim_notify_sent(bigint[]) to service_role;
grant execute on function hodim_notify_fail(bigint[], text) to service_role;


notify pgrst, 'reload schema';


-- ============================================================================
-- 10. TEKSHIRUV (RUN qilgandan keyin — alohida ishlatiladi)
-- ============================================================================
-- a) Triggerlar o'rnatildimi:
--   select tgname, tgrelid::regclass from pg_trigger
--    where tgname in ('trg_hodim_notify_entry_line', 'trg_hodim_notify_entry');
--
-- b) 🔴 EGALIK — jadval va funksiyalar BIR XIL rolniki bo'lsin, aks holda
--    trigger jadvalga yoza olmaydi (fail-open tufayli xabar jimgina yo'qoladi):
--   select c.relname, c.relrowsecurity, c.relforcerowsecurity,
--          c.relowner::regrole as jadval_egasi,
--          (select proowner::regrole from pg_proc where proname = '_hodim_notify_qoy')
--            as funksiya_egasi
--     from pg_class c where c.relname = 'hodim_notify';
--   -- jadval_egasi = funksiya_egasi  VA  relforcerowsecurity = false
--
-- c) Bog'lanmagan eski tur hisoblari (bo'lsa — PROVODKA_TUR_BOGLASH.sql RUN
--    qiling, aks holda ular uchun xabar chiqmaydi yoki qoldiq bo'lak-bo'lak
--    hisoblanadi):
--   select code, name, parent_id, pul_turi, kassa_turi, currency
--     from accounts
--    where is_active and code like '5%' and parent_id is null
--      and name ~* '·\s*(Naqd|Click|Payme|Terminal|Karta|Plastik|USD|EUR)\s*$';
--   -- bo'sh chiqishi kerak
--
-- d) Sinov: hodim-dev.html dan kichik xarajat kiriting, keyin:
--   select id, hodisa, delta, dt_yon, qoldiq_oldin, qoldiq_keyin, created_at, sent_at
--     from hodim_notify order by id desc limit 5;
--   -- qoldiq_keyin hodim sahifasidagi raqamga TENG bo'lishi shart
--
-- e) n8n ko'radigan payload (⚠️ attempts oshadi — sinovda bir marta):
--   select hodim_notify_pending(10);
--
-- f) Navbatda qotib qolgan xabarlar:
--   select id, entry_id, attempts, last_error from hodim_notify
--    where sent_at is null and attempts >= 30;
--
-- g) Tozalash (jadval cheksiz o'smasin — chorakda bir marta):
--   delete from hodim_notify where sent_at < now() - interval '90 days';
--
-- ROLLBACK (faqat xabarni to'xtatadi, provodkaga umuman tegmaydi):
--   drop trigger if exists trg_hodim_notify_entry_line on entry_line;
--   drop trigger if exists trg_hodim_notify_entry on entry;
-- ============================================================================
