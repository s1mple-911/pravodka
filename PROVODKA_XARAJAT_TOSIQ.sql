-- =====================================================================
-- PROVODKA_XARAJAT_TOSIQ.sql
-- 70% xarajat to'sig'i + "to'lanmagan xarajat" (hisobdor shaxsga qarz)
-- ---------------------------------------------------------------------
-- Brief: BRIEF_PROVODKA_XARAJAT_TOSIQ.md
-- Bu fayl FAQAT SQL. Klient tomoni (hodim / jurnal / kassa UI) keyingi bosqichda.
-- =====================================================================
--
-- ## MUAMMO
-- Hodimlar qo'liga tashlangan pulni ishlatib yuborishadi, xarajatni esa
-- yozishmaydi. Bugalter esa yana kirim qilib tashlaydi — nazorat yo'q.
--
-- ## YECHIM — IKKI QISM
--
-- ### 1) "To'lanmagan xarajat" = HISOBDOR SHAXSGA QARZ (passiv hisob)
-- Hodim qo'lidagidan ko'p xarajat yozsa, kassa MANFIYGA TUSHMAYDI.
-- Yetmagan qism kompaniyaning hodimga qarzi bo'lib passiv hisobda turadi:
--
--     6720  "Hisobdor shaxslarga qarz"  — KONTEYNER (5400 naqshi).
--                                         Unga to'g'ridan pul yozilmaydi.
--     6721+ har hodimga BITTA bola-hisob (parent_id = 6720),
--           name = hodim ismi, subtitle = "Filial · Lavozim".
--
-- Buxgalteriya oqimi (raqamlar bilan):
--
--   a) Hodim qo'lida 300 000, u 400 000 lik xarajat yozdi:
--        Dt 9421 Xarajat modda   400 000
--        Kt 5401 Hodim kassasi   300 000    <- qo'lidagi pul
--        Kt 6721 Hodimga qarz    100 000    <- TO'LANMAGAN (qizil)
--      Kassa qoldig'i 0 (manfiy emas), qarz qoldig'i 100 000.
--
--   b) Bugalter 500 000 beradi (qarz AVVAL yopiladi, qolgani qo'liga):
--        Dt 6721 Hodimga qarz    100 000    <- qarz yopildi
--        Dt 5401 Hodim kassasi   400 000    <- qo'liga
--        Kt 5011 Markaziy kassa  500 000
--      Qarz qoldig'i 0, kassa qoldig'i 400 000.
--
--   Dt = Kt ikkala yozuvda ham teng (check_entry_balanced baribir tekshiradi).
--   Balansda 6721 PASSIV tomonda turadi: "biz hodimga qarzdormiz".
--
-- ### 2) 70% TO'SIG'I
-- foiz = jami_xarajat / jami_kirim * 100.  foiz < 70 bo'lsa:
--   • hodim kassasiga KIRIM qilib bo'lmaydi,
--   • hodim kassasidan TRANSFER qilib bo'lmaydi.
-- Xarajat yozish va QARZ YOPISH hech qachon to'silmaydi — aks holda qulf
-- abadiy yopiq qolardi (hodim 70% ga hech qachon chiqolmasdi).
--
-- 🔴 To'siqni HECH KIM chetlab o'tolmaydi — admin ham (Asilbek qarori).
--    Yagona lever: umumiy foizni o'zgartirish (set_hodim_tosiq_foiz),
--    conv_koridor_foiz() naqshi — qiymat provodka_config jadvalida.
--
-- =====================================================================
-- ## RUN TARTIBI (Asilbek)
-- Butun faylni birdaniga RUN qilish MUMKIN — pul yozmaydi. Faqat DDL +
-- bitta yangi hisob (6720 konteyner) + bitta config qatori.
-- Tavsiya: 1..8 bo'limlarni birga RUN qiling, keyin 9-bo'lim (TEKSHIRUV).
--
-- ## OLD SHARTLAR (bazada allaqachon bo'lishi kerak)
--   • accounts / entry / entry_line / profiles
--   • provodka_config                                (PROVODKA_V8.sql)
--   • kassa_oila(uuid)                               (PROVODKA_CASHFLOW_FIX.sql)
--   • is_admin()
--   • trg_perm_guard_entry_line                      (PROVODKA_PERMS.sql)
--   • 5400 "Hodim xarajat kassalari" (kassa_turi='xarajat_guruh') + hodim
--     kassalari 5401+ (kassa_turi='xarajat')
--
-- ## ADDITIVE KAFOLATI
--   • Hech narsa drop QILINMAYDI. Yagona `drop trigger if exists` — SHU
--     faylning O'Z triggeri (qayta RUN idempotent bo'lsin uchun).
--   • Mavjud funksiya imzolari o'zgarmaydi; mavjud trigger TEGILMAYDI —
--     trg_perm_guard_entry_line YONIDA yangi trg_hodim_tosiq_entry_line turadi.
--   • Yangi ustunlar `add column if not exists` — bor bo'lsa no-op.
--   • Anonim `do` bloki YO'Q (Supabase SQL Editor 42P01 beradi) — tekshiruv
--     9-bo'limdagi oddiy select'lar bilan.
--
-- ## ⚠️ TAN OLINGAN CHEKLOVLAR (har birida batafsil izoh o'z joyida)
--   1. `tur_convert` (naqd -> click) BLOKLANGAN hodimda ishlamaydi — satr
--      tartibi sababli ichki ko'chirish ham to'siqqa tushadi (5-bo'lim).
--   2. Bloklangan hodimga QARZDAN ORTIQ pul berib bo'lmaydi: brief'dagi
--      "qarz + qolgani qo'liga" yozuvi faqat blok YO'Q holatda ishlaydi
--      (7-bo'lim, batafsil sabab o'sha yerda). Asilbekning 2-qarori talabi.
--   3. Qarz hisobi hodim kassasiga `accounts.hodim_kassa_id` (uuid) bilan
--      bog'lanadi; `taskfix_user_id` nusxalanadi va ZAXIRA kalit — 2.3
--      izohida nega shunday qilingani yozilgan (repoda bu ustun ko'p
--      hodimda BO'SH ekani hujjatlashtirilgan).
-- =====================================================================


-- #####################################################################
-- ## 1-BO'LIM — Ustunlar, konteyner hisob (6720), config kaliti
-- #####################################################################

-- 1.1 Qarz hisobini hodim kassasiga bog'lovchi ustun.
--     🔴 NEGA YANGI USTUN: bog'lanish uuid bo'yicha bo'lsa BIR MA'NOLI.
--     `parent_id` band (6720 guruh a'zoligi), ism bo'yicha bog'lash esa
--     TAQIQ (ism takrorlanadi — CLAUDE.md). Batafsil: 2.3 izohi.
alter table accounts
  add column if not exists hodim_kassa_id uuid;

comment on column accounts.hodim_kassa_id is
  'Qarz hisobi (6721+) qaysi HODIM KASSASIGA (5401+) tegishli. Faqat 6720 bolalarida to''ladi.';

-- Bitta hodim kassasiga BITTA qarz hisobi — takror ochilib qolmasin.
create unique index if not exists accounts_hodim_kassa_id_uniq
  on accounts(hodim_kassa_id) where hodim_kassa_id is not null;

-- 1.2 taskfix_user_id — MAVJUD bo'lsa bu qator NO-OP (turi o'zgarmaydi).
--     Kerak, chunki biz bu ustunga YOZAMIZ. PROVODKA_HODIM_NOTIFY.sql uni
--     ataylab `to_jsonb(r)->>'taskfix_user_id'` bilan o'qiydi, ya'ni
--     borligiga ishonmaydi — o'sha ehtiyotkorlikni biz `add column if not
--     exists` bilan bir marta yopamiz.
alter table accounts
  add column if not exists taskfix_user_id text;

-- 1.3 6720 "Hisobdor shaxslarga qarz" — KONTEYNER (5400 naqshi), idempotent.
--     🔴 `section` TAXMIN QILINMAYDI — mavjud passiv hisoblardan O'QILADI:
--        avval 6010 (yetkazib beruvchilar) qiymati, u yo'q bo'lsa passiv
--        hisoblarda eng ko'p uchraydigan qiymat. Shunda balans hisoboti
--        (`balans()` `section` bo'yicha guruhlaydi) 6720 ni mavjud
--        kreditorlar yonida ko'rsatadi, yetim bo'lim tug'ilmaydi.
--     🔴 `kassa_turi` ATAYLAB NULL: 6720/6721 pul hisobi EMAS. Unga
--        'xarajat_guruh' yozilsa v_hisob_royxat kabi `kassa_turi` bo'yicha
--        GURUHLAYDIGAN joylarda kassa bo'lib ko'rinib qolardi.
insert into accounts (code, name, type, section, currency, is_active)
select '6720',
       'Hisobdor shaxslarga qarz',
       'passiv',
       coalesce(
         (select a.section from accounts a where a.code = '6010' limit 1),
         (select a.section from accounts a
           where a.type = 'passiv' and a.section is not null
           group by a.section order by count(*) desc, a.section limit 1)
       ),
       'UZS',
       true
 where not exists (select 1 from accounts where code = '6720');

-- 1.4 To'siq foizi — provodka_config (conv_koridor_foiz naqshi).
--     Jadval PROVODKA_V8.sql da yaratilgan; bu yerda faqat kalit qo'shiladi.
--     Mavjud qiymat bo'lsa TEGILMAYDI (do nothing) — admin sozlagani qolsin.
insert into provodka_config(key, val)
values ('hodim_tosiq_foiz', '70')
on conflict (key) do nothing;


-- #####################################################################
-- ## 2-BO'LIM — Yordamchilar: hodim kassa ildizi + qarz hisobi
-- #####################################################################

-- 2.1 hodim_kassa_ildiz — berilgan hisob HODIM kassasimi, ildizi qaysi.
--     Kirish tur/valyuta bolasi (naqd/click/payme/USD) bo'lishi mumkin —
--     ildiz qaytariladi. Hodim kassasi bo'lmasa NULL.
--     Bola-hisobni ajratuvchi shart kassa_oila() / perm_op_key() bilan
--     AYNAN bir xil:  currency <> 'UZS'  YOKI  pul_turi is not null.
--     (parent_id ikki ma'noli — shunchaki parentga qarash 5400 guruhini
--      "ota kassa" deb o'qib xato qilardi.)
--     Hodim kassasi tasdig'i: o'zi kassa_turi='xarajat' VA otasi 5400
--     konteyner (kassa_turi='xarajat_guruh').
create or replace function hodim_kassa_ildiz(p_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  with x as (
    select case
             when a.parent_id is not null
                  and (coalesce(a.currency, 'UZS') <> 'UZS' or a.pul_turi is not null)
               then a.parent_id
             else a.id
           end as root
      from accounts a
     where a.id = p_id
  )
  select r.id
    from x
    join accounts r on r.id = x.root
    join accounts g on g.id = r.parent_id and g.kassa_turi = 'xarajat_guruh'
   where coalesce(r.kassa_turi, '') = 'xarajat';
$$;

revoke all on function hodim_kassa_ildiz(uuid) from public, anon;
grant execute on function hodim_kassa_ildiz(uuid) to authenticated, service_role;

comment on function hodim_kassa_ildiz(uuid) is
  'Hisob HODIM kassasi (yoki uning tur/valyuta bolasi) bo''lsa — ildiz kassa id. Aks holda NULL.';


-- 2.2 hodim_qarz_hisob_topish — MAVJUD qarz hisobini topadi (YARATMAYDI).
--     Trigger va view'lar shundan foydalanadi: ular hech qachon YOZMASLIGI
--     kerak (stable/read-only bo'lib qolsin).
create or replace function hodim_qarz_hisob_topish(p_hodim_kassa uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select q.id
    from accounts q
   where q.hodim_kassa_id = hodim_kassa_ildiz(p_hodim_kassa)
     and q.parent_id = (select id from accounts where code = '6720')
     and q.is_active
   limit 1;
$$;

revoke all on function hodim_qarz_hisob_topish(uuid) from public, anon;
grant execute on function hodim_qarz_hisob_topish(uuid) to authenticated, service_role;

comment on function hodim_qarz_hisob_topish(uuid) is
  'Hodim kassasining qarz hisobi (6721+) — faqat O''QIYDI, yaratmaydi. Yo''q bo''lsa NULL.';


-- 2.3 hodim_qarz_hisob — idempotent LAZY-CREATE.
--     Kod: 6721 dan boshlab, diapazondagi eng kattasi + 1 — sozlama.html /
--     PROVODKA_HODIM_KAPITAL.sql qoidasi bilan bir xil.
--
--     🔴 BOG'LANISH KALITI — TANLOV IZOHI (Asilbek e'tiboriga):
--     Brief `taskfix_user_id` bo'yicha bog'lashni so'ragan edi. Lekin repoda
--     hujjatlashtirilgan haqiqat boshqacha: PROVODKA_HODIM_NOTIFY_DIAG.sql
--     (6-bo'lim) va HODIM_NOTIFY_DEPLOY.txt bu ustun KO'P hodim kassasida
--     BO'SH ekanini yozadi ("qabul qiluvchi topilmadi -> accounts.
--     taskfix_user_id bo'sh"). Agar bo'sh bo'lganda XATO bersak, o'sha
--     hodimlarda butun "to'lanmagan xarajat" mexanizmi ishlamay qolardi:
--     qoldiqdan ortiq xarajat umuman yozilmasdi. Shuning uchun:
--       • ASOSIY kalit — `hodim_kassa_id` (uuid). Bir ma'noli va "ism
--         bo'yicha bog'lama" qoidasini ham buzmaydi (bu uuid, ism emas).
--       • `taskfix_user_id` NUSXALANADI (n8n telegram xabari uchun kerak)
--         va ZAXIRA kalit: qo'lda ochilgan, `hodim_kassa_id` si bo'sh qarz
--         hisobi bo'lsa u shu bo'yicha topiladi va backfill qilinadi.
--       • Ism bo'yicha izlash HECH QACHON qilinmaydi.
--     Bo'sh `taskfix_user_id` — XATO EMAS. 9.8 tekshiruvi bunday hodimlarni
--     ro'yxatlaydi (ularga telegram xabari bormaydi — bu alohida muammo).
--
--     FAIL-CLOSED joylar (jimgina noto'g'ri hisob YARATILMAYDI):
--       • kirish hisob hodim kassasi bo'lmasa -> XATO,
--       • hodim kassasi faol bo'lmasa        -> XATO,
--       • 6720 konteyner yo'q bo'lsa         -> XATO,
--       • kod bloki (6721-6799) to'lgan bo'lsa -> XATO.
create or replace function hodim_qarz_hisob(p_hodim_kassa uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_root uuid;
  v_k    accounts%rowtype;
  v_grp  uuid;
  v_sec  text;
  v_tfid text;
  v_id   uuid;
  v_next int;
begin
  v_root := hodim_kassa_ildiz(p_hodim_kassa);
  if v_root is null then
    raise exception 'Bu hodim kassasi emas — qarz hisobi ochilmaydi'
      using errcode = '22000',
            hint = 'Talab: kassa_turi=xarajat, otasi kassa_turi=xarajat_guruh (5400).';
  end if;

  select * into v_k from accounts where id = v_root;
  if not coalesce(v_k.is_active, false) then
    raise exception 'Hodim kassasi faol emas: % %', v_k.code, v_k.name
      using errcode = '22000';
  end if;

  select id, section into v_grp, v_sec from accounts where code = '6720';
  if v_grp is null then
    raise exception '6720 "Hisobdor shaxslarga qarz" konteyner hisobi topilmadi'
      using errcode = '22000',
            hint = 'PROVODKA_XARAJAT_TOSIQ.sql 1-bo''limini RUN qiling.';
  end if;

  -- (1) ASOSIY kalit: hodim_kassa_id
  select q.id into v_id
    from accounts q
   where q.hodim_kassa_id = v_root and q.parent_id = v_grp and q.is_active
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  -- (2) ZAXIRA kalit: taskfix_user_id (faqat BO'SH BO'LMAGANDA).
  --     ::text — ustun turi text/uuid/bigint bo'lishidan qat'i nazar ishlasin.
  v_tfid := nullif(btrim(v_k.taskfix_user_id::text), '');
  if v_tfid is not null then
    select q.id into v_id
      from accounts q
     where q.parent_id = v_grp
       and q.is_active
       and q.hodim_kassa_id is null
       and nullif(btrim(q.taskfix_user_id::text), '') = v_tfid
     limit 1;
    if v_id is not null then
      update accounts set hodim_kassa_id = v_root where id = v_id;   -- backfill
      return v_id;
    end if;
  end if;

  -- (3) Yangi hisob: kod = 6721..6799 oralig'idagi eng kattasi + 1
  select coalesce(max(a.code::int), 6720) + 1 into v_next
    from accounts a
   where a.code ~ '^[0-9]{4}$' and a.code::int between 6721 and 6799;

  if v_next > 6799 then
    raise exception 'Qarz hisoblari uchun 6721-6799 kod bloki to''ldi'
      using errcode = '22000',
            hint = 'Kod sxemasini kengaytiring (masalan 6800 blokini oching).';
  end if;

  insert into accounts (code, name, type, section, currency, parent_id,
                        is_active, subtitle, hodim_kassa_id, taskfix_user_id)
  values (v_next::text,
          v_k.name,                 -- hodim ismi (kassadan NUSXA)
          'passiv',
          v_sec,                    -- konteyner bilan bir xil bo'lim
          'UZS',
          v_grp,
          true,
          v_k.subtitle,             -- "Filial · Lavozim"
          v_root,
          v_tfid)
  returning id into v_id;

  return v_id;
end $$;

revoke all on function hodim_qarz_hisob(uuid) from public, anon;
grant execute on function hodim_qarz_hisob(uuid) to authenticated, service_role;

comment on function hodim_qarz_hisob(uuid) is
  'Hodim kassasining qarz hisobi (6721+). Idempotent lazy-create. Bog''lanish hodim_kassa_id (uuid), '
  'zaxira kalit taskfix_user_id. Ism bo''yicha HECH QACHON bog''lamaydi.';


-- #####################################################################
-- ## 3-BO'LIM — O'lchov: kirim / xarajat / foiz / to'lanmagan (FIFO)
-- #####################################################################

-- 3.1 hodim_balans_bir — BITTA hodim kassasining o'lchovi.
--     🔴 YAGONA MANBA: view ham, to'siq trigger ham, hisobot RPC ham AYNAN
--        shu funksiyani chaqiradi. Mantiq ikki joyda yozilsa drift bo'lardi —
--        UI bir raqam, to'siq boshqa raqam ko'rsatib turardi.
--
--     KENGAYTIRILGAN OILA = kassa_oila(ildiz) + qarz hisobi (6721).
--
--     jami_kirim — kengaytirilgan oilaga tushgan DEBET, lekin OILA ICHIDAGI
--       harakat chiqarib tashlanadi (tur_convert naqd->click ikki marta
--       sanalmasin). Boshlang'ich qoldiq ham kiradi — u ham berilgan pul.
--       🔴 Qarz hisobiga tushgan Dt (qarzning yopilishi) HAM kirim: bugalter
--          o'sha pulni hodimga bergan (hodim o'z pulidan sarflaganini
--          qaytarib olyapti). Aks holda foiz sun'iy ravishda YUQORI chiqib,
--          to'siq bo'shab qolardi. Misol: 300k berilgan, 400k xarajat,
--          keyin 500k berilgan -> to'g'ri jami_kirim 800k (foiz 50%),
--          qarz Dt hisobga olinmasa 700k (foiz 57%) bo'lib ketardi.
--
--     jami_xarajat — kengaytirilgan oiladan chiqqan KREDIT, faqat qarshi
--       tomonida Dt type='xarajat' bor yozuvlardan. Bu AYNAN mavjud
--       hodim_oy_jami_kop() mantiqi (hodim sahifasidagi "Bu oy sarflandi"
--       bilan bir xil raqam chiqsin), faqat qarz hisobi qo'shilgan: hodim
--       O'Z PULIDAN sarflagani ham xarajat.
--
--     Faqat status='posted' and is_deleted=false (CLAUDE.md qat'iy qoidasi).
create or replace function hodim_balans_bir(p_kassa uuid)
returns table (jami_kirim    numeric,
               jami_xarajat  numeric,
               kassa_qoldiq  numeric,
               qarz_qoldiq   numeric,
               qarz_hisob_id uuid)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_root uuid;
  v_ids  uuid[];
  v_qarz uuid;
  v_ext  uuid[];
begin
  v_root := hodim_kassa_ildiz(p_kassa);
  if v_root is null then
    return;                        -- hodim kassasi emas -> qator yo'q
  end if;

  v_ids  := coalesce(kassa_oila(v_root), array[v_root]);
  v_qarz := hodim_qarz_hisob_topish(v_root);
  v_ext  := case when v_qarz is null then v_ids else v_ids || v_qarz end;

  return query
  with kir as (
    select coalesce(sum(l.debit), 0) as s
      from entry_line l
      join entry e on e.id = l.entry_id
     where l.account_id = any(v_ext)
       and l.debit > 0
       and e.status = 'posted' and e.is_deleted = false
       and not exists (select 1 from entry_line c
                        where c.entry_id = l.entry_id
                          and c.credit > 0
                          and c.account_id = any(v_ext))
  ),
  xar as (
    select coalesce(sum(l.credit), 0) as s
      from entry_line l
      join entry e on e.id = l.entry_id
     where l.account_id = any(v_ext)
       and l.credit > 0
       and e.status = 'posted' and e.is_deleted = false
       and exists (select 1 from entry_line d
                     join accounts a on a.id = d.account_id
                    where d.entry_id = l.entry_id
                      and d.debit > 0
                      and a.type = 'xarajat')
  ),
  bal as (
    select coalesce(sum(l.debit - l.credit), 0) as s
      from entry_line l
      join entry e on e.id = l.entry_id
     where l.account_id = any(v_ids)
       and e.status = 'posted' and e.is_deleted = false
  ),
  qrz as (
    select case when v_qarz is null then 0::numeric else coalesce((
             select sum(l.credit - l.debit)
               from entry_line l
               join entry e on e.id = l.entry_id
              where l.account_id = v_qarz
                and e.status = 'posted' and e.is_deleted = false), 0) end as s
  )
  select kir.s, xar.s, bal.s, qrz.s, v_qarz
    from kir, xar, bal, qrz;
end $$;

revoke all on function hodim_balans_bir(uuid) from public, anon;
grant execute on function hodim_balans_bir(uuid) to authenticated, service_role;

comment on function hodim_balans_bir(uuid) is
  'Bitta hodim kassasi o''lchovi: jami_kirim, jami_xarajat, kassa_qoldiq, qarz_qoldiq, qarz_hisob_id. '
  'To''siq, view va hisobotlarning YAGONA manbasi (drift bo''lmasin).';


-- 3.2 v_hodim_balans — har hodim kassasi uchun BITTA qator.
--     security_invoker: accounts o'qish uchun. Raqamlar esa DEFINER
--     funksiyadan keladi, ya'ni entry_line RLS'i raqamni buzmaydi
--     (hodim_qoldiqlar bilan bir xil naqsh).
create or replace view v_hodim_balans as
select k.id                                                    as kassa_id,
       k.code                                                  as kassa_kod,
       k.name                                                  as kassa_nom,
       k.subtitle                                              as subtitle,
       b.jami_kirim,
       b.jami_xarajat,
       round(b.jami_xarajat / nullif(b.jami_kirim, 0) * 100, 1) as foiz,
       b.kassa_qoldiq,
       b.qarz_qoldiq,
       b.qarz_hisob_id
  from accounts k
  join accounts g on g.id = k.parent_id and g.kassa_turi = 'xarajat_guruh'
  cross join lateral hodim_balans_bir(k.id) b
 where k.kassa_turi = 'xarajat'
   and k.section = 'pul'
   and k.pul_turi is null
   and coalesce(k.currency, 'UZS') = 'UZS'
   and k.is_active;

alter view v_hodim_balans set (security_invoker = on);
revoke all on v_hodim_balans from public, anon;
grant select on v_hodim_balans to authenticated;

comment on view v_hodim_balans is
  'Har hodim kassasi: jami_kirim / jami_xarajat / foiz (NULL = hali pul berilmagan) / '
  'kassa_qoldiq / qarz_qoldiq / qarz_hisob_id. Faqat posted va o''chirilmagan yozuvlardan.';


-- 3.3 hodim_tolanmagan_bir — to'lanmagan xarajatlar, FIFO.
--     🔴 ALOHIDA ALLOKATSIYA JADVALI YO'Q — drift bo'lmasin. Qoplanish har
--        safar entry_line'dan qayta hisoblanadi:
--          qarz tug'ilgan yozuvlar = Kt qarz hisobi satrlari (sana bo'yicha),
--          jami qoplangan          = Dt qarz hisobi satrlari yig'indisi,
--          qoplangan(i)            = clamp(jami_qoplangan - kumulyativ_oldingi).
--        Invariant: sum(ochiq_summa) = qarz_qoldiq (9.7 tekshiruvi).
--     Tartib barqaror: entry_date, created_at, entry_id (jurnal_v2 naqshi).
create or replace function hodim_tolanmagan_bir(p_kassa uuid)
returns table (entry_id         uuid,
               kassa_id         uuid,
               sana             date,
               summa            numeric,
               tolanmagan_summa numeric,
               qoplangan_summa  numeric,
               ochiq_summa      numeric,
               hali_ochiq       boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_root uuid;
  v_qarz uuid;
begin
  v_root := hodim_kassa_ildiz(p_kassa);
  if v_root is null then
    return;
  end if;
  v_qarz := hodim_qarz_hisob_topish(v_root);
  if v_qarz is null then
    return;                         -- qarz hisobi yo'q -> to'lanmagan ham yo'q
  end if;

  return query
  with qarz as (
    select l.entry_id as eid, e.entry_date as sana, e.created_at as yaratildi,
           sum(l.credit) as qarz_summa
      from entry_line l
      join entry e on e.id = l.entry_id
     where l.account_id = v_qarz
       and l.credit > 0
       and e.status = 'posted' and e.is_deleted = false
     group by l.entry_id, e.entry_date, e.created_at
  ),
  tolov as (
    select coalesce(sum(l.debit), 0) as s
      from entry_line l
      join entry e on e.id = l.entry_id
     where l.account_id = v_qarz
       and l.debit > 0
       and e.status = 'posted' and e.is_deleted = false
  ),
  kum as (
    select q.eid, q.sana, q.yaratildi, q.qarz_summa,
           coalesce(sum(q.qarz_summa) over (order by q.sana, q.yaratildi, q.eid
                        rows between unbounded preceding and 1 preceding), 0) as oldingi
      from qarz q
  )
  select k.eid,
         v_root,
         k.sana,
         -- shu yozuvdagi jami xarajat summasi (Dt type='xarajat')
         coalesce((select sum(l2.debit)
                     from entry_line l2
                     join accounts a2 on a2.id = l2.account_id
                    where l2.entry_id = k.eid and l2.debit > 0 and a2.type = 'xarajat'), 0),
         k.qarz_summa,
         least(k.qarz_summa, greatest(t.s - k.oldingi, 0)),
         k.qarz_summa - least(k.qarz_summa, greatest(t.s - k.oldingi, 0)),
         (k.qarz_summa - least(k.qarz_summa, greatest(t.s - k.oldingi, 0))) > 0
    from kum k
    cross join tolov t
   order by k.sana desc, k.yaratildi desc, k.eid desc;
end $$;

revoke all on function hodim_tolanmagan_bir(uuid) from public, anon;
grant execute on function hodim_tolanmagan_bir(uuid) to authenticated, service_role;

comment on function hodim_tolanmagan_bir(uuid) is
  'Bitta hodimning to''lanmagan xarajatlari (FIFO). Allokatsiya jadvali YO''Q — har safar qayta hisoblanadi.';


-- 3.4 v_hodim_tolanmagan — hamma hodim bo'yicha to'lanmagan xarajatlar.
--     hali_ochiq = true  -> qizil "To'lanmagan"
--     hali_ochiq = false -> yopilgan (kichik qizil belgi: "avval to'lanmagan edi")
create or replace view v_hodim_tolanmagan as
select t.entry_id,
       t.kassa_id,
       k.code as kassa_kod,
       k.name as kassa_nom,
       t.sana,
       t.summa,
       t.tolanmagan_summa,
       t.qoplangan_summa,
       t.ochiq_summa,
       t.hali_ochiq
  from accounts k
  join accounts g on g.id = k.parent_id and g.kassa_turi = 'xarajat_guruh'
  cross join lateral hodim_tolanmagan_bir(k.id) t
 where k.kassa_turi = 'xarajat'
   and k.section = 'pul'
   and k.pul_turi is null
   and coalesce(k.currency, 'UZS') = 'UZS'
   and k.is_active;

alter view v_hodim_tolanmagan set (security_invoker = on);
revoke all on v_hodim_tolanmagan from public, anon;
grant select on v_hodim_tolanmagan to authenticated;

comment on view v_hodim_tolanmagan is
  'To''lanmagan xarajatlar (FIFO). hali_ochiq=true -> qizil "To''lanmagan"; false -> yopilgan (tarix belgisi).';


-- #####################################################################
-- ## 4-BO'LIM — To'siq: foiz sozlamasi, holat, xato matni
-- #####################################################################

-- 4.1 hodim_tosiq_foiz() — conv_koridor_foiz() naqshi. YAGONA manba.
--     0 qiymati = to'siq butunlay o'chirilgan (avariya klapani).
create or replace function hodim_tosiq_foiz()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
           (select nullif(val, '')::numeric from provodka_config where key = 'hodim_tosiq_foiz'),
           70);
$$;

revoke all on function hodim_tosiq_foiz() from public, anon;
grant execute on function hodim_tosiq_foiz() to authenticated, service_role;

comment on function hodim_tosiq_foiz() is
  'Hodim xarajat to''sig''i foizi (provodka_config.hodim_tosiq_foiz; default 70). 0 = to''siq o''chirilgan.';


-- 4.2 set_hodim_tosiq_foiz — ADMIN only (set_koridor_foiz naqshi).
--     🔴 Bu to'siqni yumshatishning YAGONA yo'li va u UMUMIY: bitta hodimga
--        istisno qilib bo'lmaydi (Asilbekning 2-qarori).
create or replace function set_hodim_tosiq_foiz(p_foiz numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_by text;
begin
  if not is_admin() then
    raise exception 'Faqat admin xarajat to''sig''i foizini o''zgartira oladi'
      using errcode = '42501';
  end if;
  if p_foiz is null or p_foiz < 0 or p_foiz > 100 then
    raise exception 'Foiz 0 va 100 oraligida bolishi kerak (0 = tosiq ochirilgan)'
      using errcode = '22000';
  end if;
  select coalesce(full_name, '') into v_by from profiles where id = auth.uid();
  insert into provodka_config(key, val, updated_by, updated_at)
  values ('hodim_tosiq_foiz', p_foiz::text, v_by, now())
  on conflict (key) do update
    set val = excluded.val, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  return p_foiz;
end $$;

revoke all on function set_hodim_tosiq_foiz(numeric) from public, anon;
grant execute on function set_hodim_tosiq_foiz(numeric) to authenticated;

comment on function set_hodim_tosiq_foiz(numeric) is
  'Hodim xarajat to''sig''i foizini o''zgartiradi (faqat admin). 0 = to''siq o''chadi. '
  'Umumiy sozlama — bitta hodimga istisno yo''q.';


-- 4.3 hodim_tosiq_msg — xato matnining YAGONA manbai (trigger 3 joyda + RPC).
--     `rtrim(..., '.')`: to_char(70,'FM999990.99') -> '70.' bo'lib qoladi.
create or replace function hodim_tosiq_msg(p_kerak numeric, p_foiz numeric)
returns text
language sql
immutable
set search_path = public
as $$
  select 'Bu hodim tashlangan pulning ' || rtrim(to_char(p_kerak, 'FM999990.99'), '.')
      || '%''ini xarajatga yozmagan (hozir '
      || rtrim(to_char(round(coalesce(p_foiz, 0), 1), 'FM999990.9'), '.')
      || '%). Avval xarajat yozilsin.';
$$;

revoke all on function hodim_tosiq_msg(numeric, numeric) from public, anon;
grant execute on function hodim_tosiq_msg(numeric, numeric) to authenticated, service_role;

comment on function hodim_tosiq_msg(numeric, numeric) is
  'To''siq xato matni (o''zbekcha). Trigger va RPC lar shundan foydalanadi — matn bir joyda.';


-- 4.4 hodim_tosiq_blok — ICHKI: bloklanganmi?
--     Qaytishi: NULL = blok YO'Q; aks holda JORIY FOIZ (xato matni uchun).
--     🔴 jami_kirim = 0 (yangi hodim, hali pul berilmagan) -> NULL, ya'ni
--        BLOK YO'Q. Aks holda birinchi kirim hech qachon yozilmasdi:
--        0 xarajat / 0 kirim -> foiz 0% < 70% bo'lib qulf tug'ilishidayoq
--        yopilib qolardi va hodimga umuman pul berib bo'lmasdi.
create or replace function hodim_tosiq_blok(p_kassa uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_kerak numeric;
  v_foiz  numeric;
  b       record;
begin
  v_kerak := hodim_tosiq_foiz();
  if v_kerak is null or v_kerak <= 0 then
    return null;                    -- to'siq o'chirilgan
  end if;

  select * into b from hodim_balans_bir(p_kassa);
  if not found then
    return null;                    -- hodim kassasi emas
  end if;
  if coalesce(b.jami_kirim, 0) = 0 then
    return null;                    -- hali pul berilmagan
  end if;

  v_foiz := b.jami_xarajat / b.jami_kirim * 100;
  if v_foiz >= v_kerak then
    return null;
  end if;
  return v_foiz;
end $$;

-- ICHKI: authenticated CHAQIRA OLMAYDI (UI uchun hodim_tosiq_holat bor).
revoke all on function hodim_tosiq_blok(uuid) from public, anon, authenticated;
grant execute on function hodim_tosiq_blok(uuid) to service_role;

comment on function hodim_tosiq_blok(uuid) is
  'ICHKI: hodim to''silganmi. NULL = blok yo''q, aks holda joriy foiz. Trigger va RPC lar ishlatadi.';


-- 4.5 hodim_tosiq_holat — UI uchun BITTA chaqiruv.
--     Faqat jamlanma raqamlar qaytadi (v_kassa_card darajasidagi ma'lumot),
--     shuning uchun qo'shimcha ruxsat qorovuli qo'yilmagan.
create or replace function hodim_tosiq_holat(p_kassa uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b        record;
  v_kerak  numeric;
  v_foiz   numeric;
  v_yetmas numeric;
begin
  v_kerak := hodim_tosiq_foiz();
  select * into b from hodim_balans_bir(p_kassa);
  if not found then
    return jsonb_build_object('foiz', null, 'kerak_foiz', v_kerak, 'blok', false,
                              'jami_kirim', null, 'jami_xarajat', null,
                              'kassa_qoldiq', null, 'qarz_qoldiq', null,
                              'yetishmaydi_summa', 0,
                              'izoh', 'Bu hodim kassasi emas');
  end if;

  v_foiz := case when coalesce(b.jami_kirim, 0) = 0 then null
                 else round(b.jami_xarajat / b.jami_kirim * 100, 1) end;

  -- 70% ga yetish uchun yana qancha XARAJAT yozilishi kerak.
  v_yetmas := case
    when v_kerak is null or v_kerak <= 0 or coalesce(b.jami_kirim, 0) = 0 then 0
    else greatest(ceil(v_kerak / 100 * b.jami_kirim - b.jami_xarajat), 0)
  end;

  return jsonb_build_object(
    'foiz',              v_foiz,
    'kerak_foiz',        v_kerak,
    'blok',              (hodim_tosiq_blok(p_kassa) is not null),
    'jami_kirim',        b.jami_kirim,
    'jami_xarajat',      b.jami_xarajat,
    'kassa_qoldiq',      b.kassa_qoldiq,
    'qarz_qoldiq',       b.qarz_qoldiq,
    'yetishmaydi_summa', v_yetmas);
end $$;

revoke all on function hodim_tosiq_holat(uuid) from public, anon;
grant execute on function hodim_tosiq_holat(uuid) to authenticated, service_role;

comment on function hodim_tosiq_holat(uuid) is
  'UI uchun bitta chaqiruv: {foiz, kerak_foiz, blok, jami_kirim, jami_xarajat, kassa_qoldiq, '
  'qarz_qoldiq, yetishmaydi_summa}. foiz NULL = hali pul berilmagan.';


-- #####################################################################
-- ## 5-BO'LIM — 🔴 TO'SIQ TRIGGERI (entry_line)
-- #####################################################################
--
-- NEGA TRIGGER: Provodka yozuvlari RPC orqali emas, klientdan to'g'ridan
-- entry + entry_line insert bilan ham yoziladi (provodka/professional/
-- jurnal tahriri/hodim). Yagona ishonchli to'siq — entry_line ustidagi
-- trigger. PROVODKA_PERMS.sql da AYNAN shu sabab bilan trg_perm_guard
-- qo'yilgan; bu esa uning YONIDA turadi, unga TEGILMAYDI.
--
-- ─────────────────────────────────────────────────────────────────────
-- NIMA BLOKLANADI (faqat foiz < kerak_foiz bo'lganda):
--
--   (a) KIRIM — hodim kassa OILASIGA debet (`debit > 0`).
--       Satr-lokal, ishonchli: satrning o'zidan ko'rinadi, boshqa satrga
--       bog'liq emas.
--       ISTISNO: shu yozuvda AYNI OILADAN kredit bo'lsa — bu ichki
--       ko'chirish (naqd -> click), yangi pul emas, o'tkaziladi.
--
--   (b) TRANSFER — hodim kassasidan chiqib boshqa PUL hisobiga tushishi:
--       yozuvda Kt hodim kassa VA Dt section='pul' (boshqa oiladan).
--       Ikki tomondan ham tekshiriladi — qaysi satr KEYIN kelsa, o'sha ushlaydi.
--
-- NIMA HECH QACHON BLOKLANMAYDI:
--
--   • Dt type='xarajat' / Kt hodim kassa — XARAJAT YOZISH.
--     (kassada debit yo'q -> (a) tegmaydi; Dt modda section<>'pul' -> (b) tegmaydi.)
--   • Dt/Kt 6721 QARZ HISOBI — qarz tug'ilishi va qarz yopilishi.
--     Qarz hisobi 6xxx passiv: hodim kassa oilasiga KIRMAYDI va section<>'pul'.
--     Ya'ni "Dt 6721 / Kt 5011" yozuvi hodim BLOKLANGAN bo'lsa ham o'tadi —
--     bugalter qarzni HAR DOIM yopa oladi. O'LIK QULF YO'Q.
--   • auth.uid() is null (service_role / n8n avtomatik sinxroni) —
--     🔴 o'tkaziladi, aks holda har 30 daqiqalik Aros sinxroni to'xtardi.
--   • jami_kirim = 0 (hali pul berilmagan hodim) — 4.4 izohiga qara.
--
--   • ADMIN ISTISNOSI YO'Q (Asilbek qarori): is_admin() umuman tekshirilmaydi.
--
-- ─────────────────────────────────────────────────────────────────────
-- 🔴 YOZUV TRANZAKSIYADA EMAS — SATRLAR KETMA-KET KELADI
-- CLAUDE.md: `entry` insert -> keyin `entry_line`lar insert. Ya'ni birinchi
-- satr kelganda ukasi hali YO'Q. Shuning uchun (b) qoidasi har insertda
-- YOZUVNING O'SHA PAYTDAGI HOLATIGA qarab tekshiriladi:
--   • birinchi satr kelganda juftlik ko'rinmaydi -> o'tkaziladi,
--   • ikkinchi satr kelganda juftlik to'liq     -> USHLANADI.
-- Natija bir xil: TO'LIQ transfer yozuvi hech qachon saqlanmaydi.
-- (Klient odatda ikkala satrni BITTA insert bilan yuboradi — u holda
--  ikkinchi qatorning triggeri birinchisini allaqachon ko'radi.)
-- `l.id is distinct from new.id` — UPDATE holatida satr o'zini sanamasin.
--
-- ⚠️ SHU SABABLI TAN OLINGAN CHEKLOV: `tur_convert` (naqd -> click) avval
--    Dt satrini, keyin Kt satrini yozadi. Dt kelganda oila krediti hali
--    yo'q -> (a) qoidasi BLOKLANGAN hodimda uni ham to'sadi. Bu xavfsiz
--    tomonga xato (pul ko'paymaydi) va hodim baribir bloklangan. Kerak
--    bo'lsa keyinchalik tur_convert satrlarini bitta insertga yig'ish yoki
--    deferred constraint trigger'ga o'tish bilan yumshatiladi.
-- ─────────────────────────────────────────────────────────────────────
create or replace function hodim_tosiq_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_root  uuid;
  v_sec   text;
  v_ids   uuid[];
  v_foiz  numeric;
  v_kerak numeric;
  v_ich   numeric;
  r       record;
begin
  -- 0) service_role / n8n avtosinxron — o'tkaziladi
  if auth.uid() is null then
    return new;
  end if;

  v_kerak := hodim_tosiq_foiz();
  if v_kerak is null or v_kerak <= 0 then
    return new;                                   -- to'siq o'chirilgan
  end if;

  select a.section into v_sec from accounts a where a.id = new.account_id;
  v_root := hodim_kassa_ildiz(new.account_id);    -- NULL = hodim kassasi emas

  -- Tez chiqish: satr na hodim kassasi, na pul hisobi (xarajat moddasi,
  -- qarz hisobi, tovar, kapital... — hammasi shu yerdan chiqib ketadi).
  if v_root is null and v_sec is distinct from 'pul' then
    return new;
  end if;

  -- ── (a) KIRIM: hodim kassa oilasiga debet ─────────────────────────
  if v_root is not null and coalesce(new.debit, 0) > 0 then
    v_ids := coalesce(kassa_oila(v_root), array[v_root]);
    -- ISTISNO (avval tekshiriladi — arzon): ichki ko'chirish.
    select coalesce(sum(l.credit), 0) into v_ich
      from entry_line l
     where l.entry_id = new.entry_id
       and l.credit > 0
       and l.account_id = any(v_ids)
       and l.id is distinct from new.id;
    if coalesce(new.debit, 0) > v_ich then
      v_foiz := hodim_tosiq_blok(v_root);
      if v_foiz is not null then
        raise exception '%', hodim_tosiq_msg(v_kerak, v_foiz) using errcode = '42501';
      end if;
    end if;
  end if;

  -- ── (b1) Yangi satr hodim oilasidan KREDIT: yozuvda tashqi pul Dt bormi?
  if v_root is not null and coalesce(new.credit, 0) > 0 then
    v_ids := coalesce(kassa_oila(v_root), array[v_root]);
    if exists (select 1
                 from entry_line l
                 join accounts a on a.id = l.account_id
                where l.entry_id = new.entry_id
                  and l.debit > 0
                  and a.section = 'pul'
                  and not (l.account_id = any(v_ids))
                  and l.id is distinct from new.id) then
      v_foiz := hodim_tosiq_blok(v_root);
      if v_foiz is not null then
        raise exception '%', hodim_tosiq_msg(v_kerak, v_foiz) using errcode = '42501';
      end if;
    end if;
  end if;

  -- ── (b2) Yangi satr PUL hisobiga DEBET: yozuvda hodim oilasidan Kt bormi?
  --        (o'zining oilasi hisobga olinmaydi — u (a) da tekshirilgan)
  if v_sec = 'pul' and coalesce(new.debit, 0) > 0 then
    for r in select distinct hodim_kassa_ildiz(l.account_id) as root
               from entry_line l
              where l.entry_id = new.entry_id
                and l.credit > 0
                and l.id is distinct from new.id
    loop
      if r.root is not null and r.root is distinct from v_root then
        v_foiz := hodim_tosiq_blok(r.root);
        if v_foiz is not null then
          raise exception '%', hodim_tosiq_msg(v_kerak, v_foiz) using errcode = '42501';
        end if;
      end if;
    end loop;
  end if;

  return new;
end $$;

revoke all on function hodim_tosiq_guard() from public, anon, authenticated;

-- 🔴 `drop trigger if exists` — FAQAT SHU faylning O'Z triggeri (qayta RUN
--    idempotent bo'lsin). trg_perm_guard_entry_line ga TEGILMAYDI.
drop trigger if exists trg_hodim_tosiq_entry_line on entry_line;
create trigger trg_hodim_tosiq_entry_line
  before insert or update of account_id, debit, credit on entry_line
  for each row execute function hodim_tosiq_guard();

comment on function hodim_tosiq_guard() is
  'Hodim 70% xarajat to''sig''i: kassaga KIRIM va kassadan TRANSFER bloklanadi. Xarajat yozish va '
  'qarz yopish HECH QACHON bloklanmaydi. service_role (auth.uid() null) o''tadi; admin uchun istisno YO''Q.';


-- #####################################################################
-- ## 6-BO'LIM — hodim_xarajat_yoz: server avtoritar xarajat yozuvi
-- #####################################################################
--
-- 🔴 SERVER AVTORITAR: kassa qoldig'ini SERVER o'qiydi va bo'linishni
--    SERVER hisoblaydi. Klient hisoblasa POYGA bo'lardi — qoldiqni o'qish
--    bilan yozish orasida boshqa yozuv tushib, kassa manfiyga ketardi.
--
-- Kirish shakli xarajat_saqlash_taqsim(jsonb) ga MOS (o'sha kalitlar),
-- qo'shimcha aliaslar bilan (klient qaysisini yuborsa ham ishlaydi):
--   { "kassa_account" | "kassa_id" : uuid    -- pul CHIQADIGAN hisob
--                                              (tur/valyuta bolasi bo'lishi mumkin)
--     "dt_account"    | "modda_id" : uuid    -- xarajat moddasi (type='xarajat')
--     "summa"                      : numeric -- SO'MDA
--     "entry_date"    | "sana"     : date    (default bugun, Tashkent)
--     "description"   | "izoh"     : text
--     "source" (default 'manual'), "status" (default 'posted')
--     "filial_ids": [uuid], "davr_start", "davr_end", "kommunal_turi"
--     "yuk_ids": [int], "kassa_currency" (default 'UZS'), "kassa_kurs"
--   }
--
-- Mantiq:
--   qoldiq = pul chiqadigan hisobning O'Z qoldig'i (tanlangan tur hisobi —
--            hodim sahifasi qaysi turni ko'rsatgan bo'lsa, o'shaniki;
--            v_hisob_bal bilan bir xil: posted + o'chirilmagan).
--   summa <= qoldiq -> ODDIY 2 satrli yozuv. 🔴 HOZIRGI XATTI-HARAKAT,
--                      hech narsa o'zgarmaydi.
--   summa >  qoldiq -> 3 satrli bo'linish + qarz hisobi lazy-create:
--                      Dt modda summa / Kt kassa qoldiq / Kt qarz (summa-qoldiq)
--
-- Qaytishi: {ok, entry_id, kassa_summa, tolanmagan_summa, qarz_hisob_id}
--           tolanmagan_summa > 0 -> klient QIZIL status ko'rsatadi.
--
-- ⚠️ VALYUTA: bo'linish faqat UZS kassada. Valyuta kassasida (USD/CNY)
--    qoldiqdan ortiq yozuvga RUXSAT BERILMAYDI — fc_amount ni ikki satrga
--    bo'lish tarixiy kurs bilan chalkashlik tug'diradi (v_kassa_toliq izohi).
--    Aniq, o'zbekcha xato beriladi.
create or replace function hodim_xarajat_yoz(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_kassa  uuid := coalesce(nullif(p_data->>'kassa_account','')::uuid,
                            nullif(p_data->>'kassa_id','')::uuid);
  v_modda  uuid := coalesce(nullif(p_data->>'dt_account','')::uuid,
                            nullif(p_data->>'modda_id','')::uuid);
  v_summa  numeric := nullif(p_data->>'summa','')::numeric;
  v_cur    text    := coalesce(nullif(p_data->>'kassa_currency',''), 'UZS');
  v_kurs   numeric := nullif(p_data->>'kassa_kurs','')::numeric;
  v_root   uuid;
  v_qoldiq numeric;
  v_kqism  numeric;
  v_qqism  numeric;
  v_qarz   uuid;
  v_fc     numeric;
  v_entry  uuid;
  v_filial uuid[];
  v_yuk    int[];
  v_mtype  text;
begin
  if v_kassa is null or v_modda is null then
    raise exception 'Kassa yoki xarajat moddasi berilmadi' using errcode = '22000';
  end if;
  if v_summa is null or v_summa <= 0 then
    raise exception 'Summa musbat bolishi kerak' using errcode = '22000';
  end if;
  if v_kurs is not null and v_kurs <= 0 then
    raise exception 'Kurs musbat bolishi kerak' using errcode = '22000';
  end if;

  v_root := hodim_kassa_ildiz(v_kassa);
  if v_root is null then
    raise exception 'Bu hodim kassasi emas — hodim_xarajat_yoz faqat hodim kassalari uchun'
      using errcode = '22000';
  end if;

  select a.type into v_mtype from accounts a where a.id = v_modda;
  if v_mtype is distinct from 'xarajat' then
    raise exception 'Tanlangan hisob xarajat moddasi emas' using errcode = '22000';
  end if;

  -- filial_ids / yuk_ids — jsonb massivdan (massiv bo'lmasa bo'sh)
  select coalesce(array_agg(t.x::uuid), '{}'::uuid[]) into v_filial
    from jsonb_array_elements_text(
           case when jsonb_typeof(p_data->'filial_ids') = 'array'
                then p_data->'filial_ids' else '[]'::jsonb end) as t(x)
   where nullif(btrim(t.x), '') is not null;

  select coalesce(array_agg(t.x::int), '{}'::int[]) into v_yuk
    from jsonb_array_elements_text(
           case when jsonb_typeof(p_data->'yuk_ids') = 'array'
                then p_data->'yuk_ids' else '[]'::jsonb end) as t(x)
   where nullif(btrim(t.x), '') is not null;

  -- 🔴 QOLDIQ SERVERDA O'QILADI (v_hisob_bal bilan bir xil mantiq)
  select coalesce(sum(l.debit - l.credit), 0) into v_qoldiq
    from entry_line l
    join entry e on e.id = l.entry_id
   where l.account_id = v_kassa
     and e.status = 'posted' and e.is_deleted = false;

  v_qoldiq := greatest(coalesce(v_qoldiq, 0), 0);   -- manfiy qoldiqni 0 deb olamiz
  v_kqism  := least(v_summa, v_qoldiq);
  v_qqism  := v_summa - v_kqism;

  if v_qqism > 0 and v_cur <> 'UZS' then
    raise exception 'Valyuta kassasida qoldiqdan ortiq xarajat yozilmaydi (qoldiq: %)', v_qoldiq
      using errcode = '22000',
            hint = 'Avval so''mga konvert qiling yoki summani kamaytiring.';
  end if;

  if v_qqism > 0 then
    v_qarz := hodim_qarz_hisob(v_root);             -- idempotent lazy-create
  end if;

  -- fc FAQAT valyuta kassasi satriga (klient bilan bir xil mantiq)
  if v_cur <> 'UZS' then
    v_fc := case when v_kurs is not null then round(v_kqism / v_kurs, 2) else v_kqism end;
  end if;

  insert into entry (entry_date, description, source, status, filial_ids,
                     davr_start, davr_end, kommunal_turi, fc_rate, yuk_ids)
  values (coalesce(nullif(p_data->>'entry_date','')::date,
                   nullif(p_data->>'sana','')::date,
                   (now() at time zone 'Asia/Tashkent')::date),
          coalesce(nullif(p_data->>'description',''), nullif(p_data->>'izoh','')),
          coalesce(nullif(p_data->>'source',''), 'manual'),
          coalesce(nullif(p_data->>'status',''), 'posted'),
          v_filial,
          nullif(p_data->>'davr_start','')::date,
          nullif(p_data->>'davr_end','')::date,
          nullif(p_data->>'kommunal_turi',''),
          case when v_cur <> 'UZS' then v_kurs end,
          v_yuk)
  returning id into v_entry;

  -- Uchala satr BITTA insert bilan (xarajat_saqlash_taqsim naqshi).
  -- Nol satrlar `where` bilan tushib qoladi — entry_line cheklovi bir satrda
  -- faqat bittasi > 0 bo'lishini talab qiladi.
  insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
  select v_entry, x.acc, x.dt, x.kt, x.fc
    from (values (v_modda, v_summa,    0::numeric, null::numeric),
                 (v_kassa, 0::numeric, v_kqism,    v_fc),
                 (v_qarz,  0::numeric, v_qqism,    null::numeric)
         ) as x(acc, dt, kt, fc)
   where x.acc is not null and (x.dt > 0 or x.kt > 0);

  return jsonb_build_object(
    'ok',               true,
    'entry_id',         v_entry,
    'kassa_summa',      v_kqism,
    'tolanmagan_summa', v_qqism,
    'qarz_hisob_id',    v_qarz);
end $$;

revoke all on function hodim_xarajat_yoz(jsonb) from public, anon;
grant execute on function hodim_xarajat_yoz(jsonb) to authenticated;

comment on function hodim_xarajat_yoz(jsonb) is
  'Hodim xarajati (atomik). Qoldiq yetmasa kassa MANFIYGA TUSHMAYDI — yetmagan qism qarz hisobiga '
  '(6721+) yoziladi. Qoldiqni server o''zi o''qiydi (poyga bo''lmasin). '
  'Qaytishi: {entry_id, kassa_summa, tolanmagan_summa, qarz_hisob_id}.';


-- #####################################################################
-- ## 7-BO'LIM — hodim_kirim_yop: bugalter kirimi (qarz avval yopiladi)
-- #####################################################################
--
-- Mantiq:
--   qarz = qarz_qoldiq;  yop = least(p_summa, qarz);  qolgan = p_summa - yop
--   yozuv:  Dt 6721 yop  ·  Dt kassa qolgan  /  Kt manba p_summa
--   qarz yo'q bo'lsa — oddiy 2 satrli kirim (hozirgi xatti-harakat).
--
-- 🔴 TO'SIQDAN O'TISH — O'LIK QULF YO'Q:
--    Qarz yopish satri Dt 6721 (passiv, section<>'pul', hodim kassa oilasiga
--    KIRMAYDI). Trigger qoidalari (a) va (b) unga umuman tegmaydi. Ya'ni
--    "Dt 6721 / Kt 5011" yozuvi hodim BLOKLANGAN bo'lsa ham o'tadi — bugalter
--    qarzni har doim yopa oladi va hodim keyin yana ishlay boshlaydi.
--
-- 🔴 BLOKLANGAN HODIMGA QARZDAN ORTIQ PUL BERIB BO'LMAYDI (ataylab).
--    Brief'dagi "qarz + qolgani qo'liga" bitta yozuvi FAQAT blok YO'Q
--    holatda ishlaydi. Sabab: agar "yozuvda qarz Dt bo'lsa qolgan qismi ham
--    o'tadi" desak, 100 000 qarzi bor hodimga 10 000 000 kirim qilib to'siq
--    BUTUNLAY chetlab o'tilardi — bu Asilbekning 2-qaroriga ("70% ni HECH
--    KIM chetlab o'tolmaydi") to'g'ridan-to'g'ri zid. Shuning uchun:
--      • bu RPC bloklangan holatda p_summa > qarz_qoldiq bo'lsa ANIQ xato
--        beradi va eng ko'p qancha berish mumkinligini aytadi;
--      • trigger ham buni MUSTAQIL to'sadi (kassaga Dt tushishi (a) qoidasi),
--        ya'ni klient bu RPC ni chetlab o'tib to'g'ridan insert qilsa ham
--        natija bir xil.
--    Brief misolidagi 500 000 lik yozuv o'z oqimida BLOKSIZ holatda bo'ladi
--    (hodim 400 000 xarajat yozgan, foizi 70% dan yuqori) — ya'ni misol
--    ishlaydi.
create or replace function hodim_kirim_yop(p_kassa uuid,
                                           p_summa numeric,
                                           p_manba uuid,
                                           p_izoh  text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_root  uuid;
  v_qarz  uuid;
  b       record;
  v_yop   numeric;
  v_qol   numeric;
  v_foiz  numeric;
  v_entry uuid;
  v_sec   text;
begin
  if p_kassa is null or p_manba is null then
    raise exception 'Kassa yoki manba hisob berilmadi' using errcode = '22000';
  end if;
  if p_summa is null or p_summa <= 0 then
    raise exception 'Summa musbat bolishi kerak' using errcode = '22000';
  end if;

  v_root := hodim_kassa_ildiz(p_kassa);
  if v_root is null then
    raise exception 'Bu hodim kassasi emas' using errcode = '22000';
  end if;

  select a.section into v_sec from accounts a where a.id = p_manba;
  if v_sec is distinct from 'pul' then
    raise exception 'Manba pul hisobi bolishi kerak' using errcode = '22000';
  end if;

  select * into b from hodim_balans_bir(v_root);
  v_yop := least(p_summa, greatest(coalesce(b.qarz_qoldiq, 0), 0));
  v_qol := p_summa - v_yop;

  if v_yop > 0 then
    v_qarz := hodim_qarz_hisob(v_root);        -- bor bo'lsa o'shani qaytaradi
  end if;

  -- Blok holati: YANGI pul (qolgan qism) bo'lsa va hodim to'silgan bo'lsa — rad.
  if v_qol > 0 then
    v_foiz := hodim_tosiq_blok(v_root);
    if v_foiz is not null then
      raise exception '% Hozircha faqat qarzni yopish mumkin: eng kop % som.',
            hodim_tosiq_msg(hodim_tosiq_foiz(), v_foiz),
            trim(to_char(greatest(coalesce(b.qarz_qoldiq, 0), 0), 'FM999999999999990'))
        using errcode = '42501';
    end if;
  end if;

  insert into entry (entry_date, description, source, status)
  values ((now() at time zone 'Asia/Tashkent')::date,
          coalesce(nullif(btrim(p_izoh), ''),
                   case when v_yop > 0 then 'Hodimga pul berildi (qarz yopildi)'
                        else 'Hodimga pul berildi' end),
          'manual', 'posted')
  returning id into v_entry;

  -- Satrlar bitta insert bilan; qarz satri birinchi (jurnalda o'qishga qulay).
  insert into entry_line (entry_id, account_id, debit, credit)
  select v_entry, x.acc, x.dt, x.kt
    from (values (v_qarz,  v_yop,      0::numeric),
                 (p_kassa, v_qol,      0::numeric),
                 (p_manba, 0::numeric, p_summa)
         ) as x(acc, dt, kt)
   where x.acc is not null and (x.dt > 0 or x.kt > 0);

  return jsonb_build_object(
    'ok',            true,
    'entry_id',      v_entry,
    'qarz_yopildi',  v_yop,
    'kassaga',       v_qol,
    'qarz_hisob_id', v_qarz,
    'qarz_qoldiq',   greatest(coalesce(b.qarz_qoldiq, 0) - v_yop, 0));
end $$;

revoke all on function hodim_kirim_yop(uuid, numeric, uuid, text) from public, anon;
grant execute on function hodim_kirim_yop(uuid, numeric, uuid, text) to authenticated;

comment on function hodim_kirim_yop(uuid, numeric, uuid, text) is
  'Bugalter kirimi (atomik, bitta entry): avval hodim qarzi (6721+) yopiladi, qolgani kassaga. '
  'Hodim to''silgan bo''lsa FAQAT qarzni yopish mumkin — yangi pul berilmaydi.';


-- #####################################################################
-- ## 8-BO'LIM — PostgREST sxema keshi
-- #####################################################################

notify pgrst, 'reload schema';


-- #####################################################################
-- ## 9-BO'LIM — TEKSHIRUV (faqat SELECT, `do` bloki YO'Q)
-- #####################################################################

-- 9.1 Hamma obyekt o'rnidami (hammasi true bo'lishi kerak)
select to_regprocedure('public.hodim_kassa_ildiz(uuid)')                 is not null as f_ildiz,
       to_regprocedure('public.hodim_qarz_hisob_topish(uuid)')           is not null as f_qarz_topish,
       to_regprocedure('public.hodim_qarz_hisob(uuid)')                  is not null as f_qarz_hisob,
       to_regprocedure('public.hodim_balans_bir(uuid)')                  is not null as f_balans_bir,
       to_regprocedure('public.hodim_tolanmagan_bir(uuid)')              is not null as f_tolanmagan_bir,
       to_regprocedure('public.hodim_tosiq_foiz()')                      is not null as f_tosiq_foiz,
       to_regprocedure('public.set_hodim_tosiq_foiz(numeric)')           is not null as f_set_tosiq,
       to_regprocedure('public.hodim_tosiq_msg(numeric,numeric)')        is not null as f_tosiq_msg,
       to_regprocedure('public.hodim_tosiq_blok(uuid)')                  is not null as f_tosiq_blok,
       to_regprocedure('public.hodim_tosiq_holat(uuid)')                 is not null as f_tosiq_holat,
       to_regprocedure('public.hodim_xarajat_yoz(jsonb)')                is not null as f_xarajat_yoz,
       to_regprocedure('public.hodim_kirim_yop(uuid,numeric,uuid,text)') is not null as f_kirim_yop,
       to_regclass('public.v_hodim_balans')                              is not null as v_balans,
       to_regclass('public.v_hodim_tolanmagan')                          is not null as v_tolanmagan;

-- 9.2 Triggerlar: YANGISI qo'shildi, ESKISI joyida (ikkalasi ham true bo'lsin)
select exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                where c.relname = 'entry_line'
                  and t.tgname = 'trg_hodim_tosiq_entry_line') as yangi_tosiq_trigger,
       exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                where c.relname = 'entry_line'
                  and t.tgname = 'trg_perm_guard_entry_line')  as eski_perm_guard_saqlandi;

-- 9.3 Ruxsatlar: ICHKI funksiya YOPIQ, anon HECH QAYERGA kira olmaydi
select has_function_privilege('authenticated', 'public.hodim_tosiq_blok(uuid)', 'execute')  as blok_ochiq_BULMASIN,
       has_function_privilege('authenticated', 'public.hodim_tosiq_holat(uuid)', 'execute') as holat_ochiq_BULSIN,
       has_function_privilege('anon',          'public.hodim_xarajat_yoz(jsonb)', 'execute') as anon_yoz_BULMASIN,
       has_function_privilege('anon',          'public.hodim_kirim_yop(uuid,numeric,uuid,text)', 'execute') as anon_kirim_BULMASIN;

-- 9.4 6720 konteyner + foiz sozlamasi
select a.code, a.name, a.type, a.section, a.parent_id, a.kassa_turi, a.is_active,
       (select val from provodka_config where key = 'hodim_tosiq_foiz') as config_foiz,
       hodim_tosiq_foiz()                                               as funksiya_foiz
  from accounts a
 where a.code = '6720';

-- 9.5 🔴 ASOSIY KO'RINISH — har hodim: foiz, qoldiq, qarz, blok holati.
--     foiz IS NULL  = hali pul berilmagan (to'siq ishlamaydi — bu NORMAL).
--     blok = true   = kirim/transfer yopiq.
select b.kassa_kod, b.kassa_nom, b.subtitle,
       b.jami_kirim, b.jami_xarajat, b.foiz,
       b.kassa_qoldiq, b.qarz_qoldiq,
       (b.foiz is not null and b.foiz < hodim_tosiq_foiz()) as blok
  from v_hodim_balans b
 order by b.foiz nulls last, b.kassa_kod;

-- 9.6 To'lanmagan xarajatlar. Mexanizm YANGI bo'lgani uchun birinchi RUN'da
--     bo'sh chiqishi KUTILADI (hali birorta qarz yozuvi yo'q).
select * from v_hodim_tolanmagan order by sana desc limit 20;

-- 9.7 INVARIANT: har hodimda  sum(ochiq_summa) = qarz_qoldiq
--     farq_0_bulsin ustuni 0 bo'lmasa — FIFO va qoldiq mos emas, xabar bering.
select b.kassa_kod, b.kassa_nom,
       b.qarz_qoldiq,
       coalesce((select sum(t.ochiq_summa) from v_hodim_tolanmagan t
                  where t.kassa_id = b.kassa_id), 0) as fifo_ochiq,
       b.qarz_qoldiq
         - coalesce((select sum(t.ochiq_summa) from v_hodim_tolanmagan t
                      where t.kassa_id = b.kassa_id), 0) as farq_0_bulsin
  from v_hodim_balans b
 order by b.kassa_kod;

-- 9.8 ℹ️ taskfix_user_id BO'SH hodim kassalari — bu XATO EMAS (qarz hisobi
--     hodim_kassa_id bo'yicha bog'lanadi, 2.3 izohiga qara), lekin bu
--     hodimlarga n8n telegram xabari BORMAYDI (alohida, eski muammo).
select k.code, k.name, k.subtitle,
       nullif(btrim(k.taskfix_user_id::text), '') as taskfix_user_id,
       case when nullif(btrim(k.taskfix_user_id::text), '') is null
            then 'telegram xabari bormaydi' else 'ok' end as holat
  from accounts k
  join accounts g on g.id = k.parent_id and g.kassa_turi = 'xarajat_guruh'
 where k.kassa_turi = 'xarajat' and k.is_active and k.pul_turi is null
 order by k.code;

-- 9.9 ℹ️ IXTIYORIY INDEKS (tezlik). Trigger har entry_line insertida shu
--     yozuvning boshqa satrlarini o'qiydi. entry_line(entry_id) indeksi
--     odatda FK bilan birga bor. Quyidagi so'rov false qaytarsa —
--     PROVODKA_HODIM_INDEKS.sql uslubida ALOHIDA RUN qiling (CONCURRENTLY
--     tranzaksiya ichida ishlamaydi):
--       create index concurrently if not exists idx_entry_line_entry
--         on entry_line(entry_id);
select exists (select 1 from pg_indexes
                where tablename = 'entry_line'
                  and indexdef like '%(entry_id%') as entry_id_indeks_bor;
