-- =====================================================================
--  PROVODKA_KASSA_MODEL.sql — bitta kassa + child hisoblar modeliga o'tish
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  MAQSAD: har valyuta alohida kassa bo'lib turgan holatdan
--          BITTA kassa + ichida child hisoblar modeliga o'tish.
--
--      HOZIR (4 alohida kassa)          KEYIN (1 kassa + child'lar)
--      5011 Toshkent kassa              5011 Toshkent kassa
--      5632 Toshkent $                   ├ naqd    (pul_turi='naqd',  UZS)
--      5802 Toshkent AED                 ├ click   (pul_turi='click', UZS)
--      5901 Toshkent CHY                 ├ payme   (pul_turi='payme', UZS)
--                                        ├ 5632    (currency='USD')
--                                        ├ 5802    (currency='AED')
--                                        └ 5901    (currency='CHY')
--
--  ⚠️ "dollar" ALOHIDA pul_turi EMAS. Dollar — valyuta, ya'ni kassaning USD
--     child'i (currency='USD', pul_turi=NULL). Brief 2-bandi ham shuni aytadi:
--     "dollar child = mavjud valyuta kassa bilan BIR XIL bo'lsin".
--     Shuning uchun pul_turi faqat: naqd | click | payme.
--     Har kassada 4 ta child bo'ladi: 3 ta som turi + USD.
--
--  ⚠️ BU FAYL O'ZI HECH NARSANI O'ZGARTIRMAYDI, agar A-QISM natijasi
--     ko'rilmagan bo'lsa. Tartib:
--        A-QISM  → faqat O'QIYDI. Natijasini menga yuboring.
--        B-QISM  → migratsiya. A-QISM natijasi tasdiqlangach RUN qilinadi.
--        C-QISM  → konvertda yangi valyuta child'ini avtomat ochish (RPC).
--
--  TALAB: PROVODKA_VALYUTA.sql allaqachon RUN qilingan bo'lsin
--         (accounts.pul_turi, kassa_root(), v_kassa_turlar, ...).
-- =====================================================================



-- #####################################################################
--  A-QISM — DIAGNOSTIKA (faqat o'qiydi, hech narsani o'zgartirmaydi)
--  Shuni RUN qiling va natijasini menga yuboring.
-- #####################################################################

-- A.1 Wipe haqiqatan bo'lganini tasdiqlash. Butun migratsiyaning xavfsizligi
--     shunga tayanadi: yozuv yo'q => qoldiq yo'q => qayta qurish zararsiz.
select (select count(*) from entry)      as entry_soni,
       (select count(*) from entry_line) as entry_line_soni;

-- A.2 Hamma pul hisobi — hozirgi tuzilma qanday ekanini ko'rish uchun ASOSIY so'rov.
--     Diqqat qiladigan ustunlar: parent_id (bormi?), currency, pul_turi, kassa_turi.
select a.code,
       a.name,
       a.kassa_turi,
       a.currency,
       a.pul_turi,
       a.is_active,
       p.code                as parent_code,       -- NULL => mustaqil (top-level) hisob
       a.filial_ref,
       a.aros_title
  from accounts a
  left join accounts p on p.id = a.parent_id
 where a.section = 'pul'
 order by coalesce(p.code, a.code), a.code;

-- A.3 MUAMMOLI qatorlar: valyuta hisobi bo'lib, lekin MUSTAQIL turganlar.
--     Aynan shular child qilinishi kerak (5632, 5802, 5901, 5633, 5801 ...).
--     `taxmin_parent` — nom bo'yicha avtomat topilgan ildiz kassa (TAXMIN!).
--     `nechta_moslik` = 1 bo'lsa taxmin ishonchli; 0 yoki >1 bo'lsa qo'lda ko'rsatiladi.
with kassa as (
  select id, code, name, filial_ref
    from accounts
   where section = 'pul' and is_active
     and coalesce(currency,'UZS') = 'UZS'
     and parent_id is null
     and coalesce(kassa_turi,'') <> 'xarajat_guruh'
),
yetim as (
  select id, code, name, currency, filial_ref
    from accounts
   where section = 'pul' and is_active
     and coalesce(currency,'UZS') <> 'UZS'
     and parent_id is null
)
select y.code                                   as yetim_kod,
       y.name                                   as yetim_nom,
       y.currency,
       (select string_agg(k.code, ', ' order by length(k.name) desc)
          from kassa k
         where (y.filial_ref is not null and k.filial_ref = y.filial_ref)
            or lower(y.name) like lower(k.name) || '%')   as taxmin_parent,
       (select count(*)
          from kassa k
         where (y.filial_ref is not null and k.filial_ref = y.filial_ref)
            or lower(y.name) like lower(k.name) || '%')   as nechta_moslik
  from yetim y
 order by y.code;

-- A.4 Bir kassada bir valyutadan IKKITA child bormi? (bo'lsa v_kassa_card
--     kartani ikki marta chizadi — migratsiyadan oldin bilish shart)
select p.code as kassa, c.currency, count(*) as nechta,
       string_agg(c.code, ', ' order by c.code) as kodlar
  from accounts c
  join accounts p on p.id = c.parent_id
 where c.section = 'pul' and c.is_active and coalesce(c.currency,'UZS') <> 'UZS'
 group by p.code, c.currency
having count(*) > 1;

-- A.5 Bu hisoblar ruxsatlarda ishlatilganmi? (ishlatilgan bo'lsa ularni
--     O'CHIRMASLIK kerak — id saqlanib qolsin, faqat parent o'zgarsin)
select u.user_id, pr.full_name,
       (select string_agg(a.code, ', ')
          from accounts a where a.id = any(u.view_kassa_ids)) as korish,
       (select string_agg(a.code, ', ')
          from accounts a where a.id = any(u.op_kassa_ids))   as amaliyot
  from user_perms u
  left join profiles pr on pr.id = u.user_id
 where coalesce(array_length(u.view_kassa_ids,1),0) > 0
    or coalesce(array_length(u.op_kassa_ids,1),0) > 0;



-- #####################################################################
--  B-QISM — MIGRATSIYA
--  A-QISM natijasi ko'rilgach RUN qilinadi.
-- #####################################################################

-- ---------------------------------------------------------------------
-- B.0 Qo'lda mapping (KERAK BO'LSA)
-- ---------------------------------------------------------------------
-- A.3 da `nechta_moslik` 1 bo'lmagan (0 yoki 2+) qatorlar avtomat
-- bog'lanmaydi — ular shu jadvalga qo'lda yoziladi. Hammasi 1 bo'lsa
-- bu jadval bo'sh qolaveradi.
create table if not exists kassa_model_map (
  child_code  text primary key,   -- masalan '5802'
  parent_code text not null       -- masalan '5011'
);

-- MISOL (kerak bo'lsa izohni oching va to'ldiring):
-- insert into kassa_model_map(child_code, parent_code) values
--   ('5802','5011'), ('5801','5215')
-- on conflict (child_code) do update set parent_code = excluded.parent_code;


-- ---------------------------------------------------------------------
-- B.1 Migratsiya
-- ---------------------------------------------------------------------
-- USUL: O'CHIRMAYDI, qayta bog'laydi (update parent_id).
--   Sabab — id saqlanadi: user_perms massivlari, filial_snapshot va boshqa
--   havolalar buzilmaydi. O'chirib qayta yaratish xuddi shu natijani beradi,
--   lekin id o'zgargani uchun havolalar yetim qoladi. Wipe yozuvlarni
--   o'chirdi, hisoblarni emas.
do $mig$
declare
  -- ⚙️ Nomlarni bir xillashtirish: child nomi "<kassa nomi> · USD" ga keltiriladi.
  --    false bo'lsa nomlar o'z holicha qoladi.
  p_nom_tekislash boolean := true;

  r         record;
  v_parent  uuid;
  v_pcode   text;
  v_pname   text;
  n_bogl    int := 0;
  n_ochir   int := 0;
  n_qoldi   int := 0;
  v_entry   bigint;
begin
  -- ---- B.1.1 XAVFSIZLIK ESHIGI ------------------------------------
  -- Butun rejaning asosi: yozuv yo'q. Yozuv bo'lsa qayta bog'lash
  -- qoldiqlarni bir kassadan boshqasiga ko'chirib yuboradi — TO'XTAYMIZ.
  select count(*) into v_entry from entry_line;
  if v_entry > 0 then
    raise exception 'TO''XTADI: entry_line''da % qator bor. Bu migratsiya faqat '
                    'WIPE''dan keyin (yozuv 0 bo''lganda) xavfsiz.', v_entry;
  end if;

  -- ---- B.1.2 Mustaqil valyuta hisoblarini child qilish -------------
  for r in
    with kassa as (
      select id, code, name, filial_ref
        from accounts
       where section = 'pul' and is_active
         and coalesce(currency,'UZS') = 'UZS'
         and parent_id is null
         and coalesce(kassa_turi,'') <> 'xarajat_guruh'
    ),
    yetim as (
      select id, code, name, currency, filial_ref
        from accounts
       where section = 'pul' and is_active
         and coalesce(currency,'UZS') <> 'UZS'
         and parent_id is null
    )
    select y.id, y.code, y.name, y.currency,
           -- 1) qo'lda mapping ustun turadi
           coalesce(
             (select k.id from kassa k
               join kassa_model_map m on m.parent_code = k.code
              where m.child_code = y.code),
             -- 2) filial_ref bo'yicha aniq moslik
             (select k.id from kassa k
               where y.filial_ref is not null and k.filial_ref = y.filial_ref
               limit 1),
             -- 3) nom prefiksi bo'yicha YAGONA moslik (eng uzun nom yutadi)
             (select k.id from kassa k
               where lower(y.name) like lower(k.name) || '%'
                 and (select count(*) from kassa k2
                       where lower(y.name) like lower(k2.name) || '%') = 1
               limit 1)
           ) as parent_id
      from yetim y
     order by y.code
  loop
    if r.parent_id is null then
      -- Bog'lanmadi: TEGILMAYDI. kassa_model_map'ga yozib qayta RUN qiling.
      n_qoldi := n_qoldi + 1;
      raise notice 'BOG''LANMADI: % (%) — kassa_model_map''ga qo''shing', r.code, r.name;
      continue;
    end if;

    select code, name into v_pcode, v_pname from accounts where id = r.parent_id;

    -- Shu kassada bu valyutadan FAOL child allaqachon bormi?
    -- Bo'lsa — ikkita bo'lib qolmasin (v_kassa_card kartani takrorlab yuboradi).
    -- Yozuv yo'q, shuning uchun ortiqchasini faolsizlantiramiz (o'chirmaymiz).
    if exists (select 1 from accounts c
                where c.parent_id = r.parent_id
                  and c.currency = r.currency
                  and c.is_active and c.id <> r.id) then
      update accounts
         set is_active = false,
             name = name || ' (eski — ' || v_pcode || ' da allaqachon ' || r.currency || ' bor)'
       where id = r.id;
      n_ochir := n_ochir + 1;
      raise notice 'FAOLSIZLANTIRILDI: % (% da % child allaqachon bor)', r.code, v_pcode, r.currency;
      continue;
    end if;

    update accounts
       set parent_id  = r.parent_id,
           pul_turi   = null,                       -- valyuta child'i, som turi emas
           kassa_turi = (select kassa_turi from accounts where id = r.parent_id),
           name       = case when p_nom_tekislash then v_pname || ' · ' || r.currency else name end
     where id = r.id;
    n_bogl := n_bogl + 1;
    raise notice 'BOG''LANDI: % (%) -> %', r.code, r.currency, v_pcode;
  end loop;

  raise notice '--- B.1 tugadi: % bog''landi | % faolsizlantirildi | % bog''lanmadi',
    n_bogl, n_ochir, n_qoldi;

  if n_qoldi > 0 then
    raise exception 'TO''XTADI: % ta valyuta hisobi bog''lanmadi (yuqoridagi NOTICE''larga qarang). '
                    'kassa_model_map''ni to''ldirib qayta RUN qiling — shu paytgacha '
                    'HECH NARSA o''zgarmaydi (rollback).', n_qoldi;
  end if;
end
$mig$;


-- ---------------------------------------------------------------------
-- B.2 Takrorlanishga qarshi qulf
-- ---------------------------------------------------------------------
-- Bitta kassada bir valyutadan ikkita FAOL child bo'lsa v_kassa_card
-- ichidagi `left join accounts u ... u.currency='USD'` bir nechta qator
-- qaytaradi va KARTA IKKI MARTA chiziladi. Bundan keyin baza o'zi to'sadi.
-- (Agar bu indeks yaratilmasa — demak hali dublikat bor, B.1 NOTICE'lariga qarang.)
create unique index if not exists accounts_parent_currency_uniq
  on accounts(parent_id, currency)
  where parent_id is not null and currency <> 'UZS' and is_active;


-- ---------------------------------------------------------------------
-- B.3 Standart turlarni ochish
-- ---------------------------------------------------------------------
-- Har markaziy va filial kassaga naqd/click/payme (+ USD) child ochiladi.
-- Bu ALOHIDA faylda: PROVODKA_VALYUTA_SEED.sql — o'shani B.2 dan keyin RUN qiling.
-- U idempotent: B.1 da bog'langan USD child'ni qayta yaratmaydi
-- ("mavjud USD child bo'lsa o'tkazib yuboradi" sharti bor).



-- #####################################################################
--  C-QISM — Konvertda yangi valyuta child'i AVTOMAT ochilishi
-- #####################################################################

-- Muammo: create_valyuta_child() faqat ADMIN uchun. Konvert qiluvchi oddiy
-- foydalanuvchi kassada hali yo'q valyutani (masalan AED) tanlay olmasdi —
-- avval admin hisob ochib berishi kerak edi. Brief 3-bandi buni avtomat qilishni
-- so'raydi: konvert qilinsa child o'zi yaratilsin.
--
-- Tuzilma (ataylab uch qismga bo'lingan):
--   valyuta_child_yarat()  — YARATISHNING O'ZI, huquq tekshirmaydi. Ichki.
--   create_valyuta_child() — admin uchun (mavjud imzo, kassa.html "Valyuta qo'shish")
--   ensure_valyuta_child() — konvert oqimi uchun (admin shart emas)
-- Kod bloki / nom / tekshiruvlar mantig'i BITTA joyda — ikki nusxa vaqt o'tib
-- bir-biridan ajralib ketmasin.

-- ---------------------------------------------------------------------
-- C.1 valyuta_child_yarat — ichki (huquq tekshiruvi YO'Q)
-- ---------------------------------------------------------------------
-- ⚠️ Buni to'g'ridan chaqirmang: huquqni chaqiruvchi tekshiradi.
--    authenticated'dan execute olib tashlangan; faqat SECURITY DEFINER
--    o'ramlar (pastdagi ikkitasi) chaqira oladi.
create or replace function valyuta_child_yarat(p_parent uuid, p_currency text)
returns uuid
language plpgsql
as $$
declare
  v_cur    text := upper(btrim(coalesce(p_currency, '')));
  v_parent accounts%rowtype;
  v_prefix text;
  v_next   int;
  v_code   text;
  v_id     uuid;
begin
  if v_cur = '' or v_cur = 'UZS' then
    raise exception 'Valyuta noto''g''ri: %', p_currency;
  end if;

  select * into v_parent from accounts where id = p_parent;
  if not found then
    raise exception 'Kassa topilmadi: %', p_parent;
  end if;
  if v_parent.section is distinct from 'pul' or coalesce(v_parent.currency,'UZS') <> 'UZS' then
    raise exception 'Valyuta hisobi faqat so''m kassasiga qo''shiladi (%)', v_parent.code;
  end if;
  if v_parent.parent_id is not null then
    raise exception 'Bola-hisobga valyuta qo''shib bo''lmaydi (%)', v_parent.code;
  end if;
  if not v_parent.is_active then
    raise exception 'Kassa faol emas: %', v_parent.code;
  end if;
  if v_parent.kassa_turi = 'xarajat_guruh' then
    raise exception 'Guruh hisobiga valyuta qo''shib bo''lmaydi (%)', v_parent.code;
  end if;

  -- idempotent
  select id into v_id
    from accounts
   where parent_id = p_parent and currency = v_cur and is_active
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  select prefix into v_prefix from valyuta_kod_blok where currency = v_cur;
  if v_prefix is null then
    select p into v_prefix
      from unnest(array['57','58','59']) as p
     where not exists (select 1 from valyuta_kod_blok b where b.prefix = p)
     limit 1;
    if v_prefix is null then
      raise exception 'Bo''sh kod bloki qolmadi (57–59 band). Kod sxemasini kengaytiring.';
    end if;
    insert into valyuta_kod_blok(currency, prefix) values (v_cur, v_prefix);
  end if;

  select coalesce(max(substring(code from 3 for 2)::int), 0) + 1 into v_next
    from accounts
   where code ~ ('^' || v_prefix || '[0-9]{2}$');
  if v_next > 99 then
    raise exception 'Kod bloki % to''ldi', v_prefix;
  end if;
  v_code := v_prefix || lpad(v_next::text, 2, '0');

  insert into accounts(code, name, type, section, currency, parent_id,
                       kassa_turi, is_active, subtitle)
  values (v_code, v_parent.name || ' · ' || v_cur, 'aktiv', 'pul', v_cur,
          p_parent, v_parent.kassa_turi, true, v_parent.subtitle)
  returning id into v_id;

  return v_id;
end $$;

revoke all on function valyuta_child_yarat(uuid, text) from public, anon, authenticated;

comment on function valyuta_child_yarat(uuid, text) is
  'ICHKI: valyuta child yaratadi, huquq TEKSHIRMAYDI. Faqat create_valyuta_child / '
  'ensure_valyuta_child o''ramlaridan chaqiriladi.';


-- ---------------------------------------------------------------------
-- C.2 create_valyuta_child — admin uchun (IMZO O'ZGARMAYDI)
-- ---------------------------------------------------------------------
-- Tanasi qisqardi: yaratish C.1 ga ko'chdi, bu yerda faqat admin tekshiruvi.
-- Xatti-harakati avvalgidek: admin bo'lmasa xato, bor bo'lsa mavjudini qaytaradi.
create or replace function create_valyuta_child(p_parent uuid, p_currency text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_role text;
begin
  select role into v_role from profiles where id = auth.uid();
  if v_role is distinct from 'admin' then
    raise exception 'Faqat admin valyuta hisobi ocha oladi';
  end if;
  return valyuta_child_yarat(p_parent, p_currency);
end $$;

revoke all on function create_valyuta_child(uuid, text) from public, anon;
grant execute on function create_valyuta_child(uuid, text) to authenticated;


-- ---------------------------------------------------------------------
-- C.3 ensure_valyuta_child — konvert oqimi uchun (admin SHART EMAS)
-- ---------------------------------------------------------------------
-- Bu ruxsatni kengaytirish, shuning uchun ATAYLAB tor:
--   • faqat hisob OCHADI — pul harakat qilmaydi, qoldiq o'zgarmaydi;
--   • konvert ruxsati (perm_can_convert) bo'lishi shart;
--   • o'sha kassada amaliyot ruxsati (perm_check_accounts) bo'lishi shart.
-- Pulni ko'chirish baribir convert_start_v2 orqali va u o'z tekshiruvlarini
-- qiladi (koridor, qoldiq, filial taqiqi, konvert ruxsati).
create or replace function ensure_valyuta_child(p_kassa uuid, p_currency text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_ok boolean;
begin
  if auth.uid() is null then
    raise exception 'Avtorizatsiya kerak';
  end if;

  if to_regprocedure('public.perm_can_convert()') is not null then
    execute 'select perm_can_convert()' into v_ok;
    if not coalesce(v_ok, true) then
      raise exception 'Konvert ruxsati yo''q';
    end if;
  end if;

  if to_regprocedure('public.perm_check_accounts(uuid[])') is not null then
    execute 'select perm_check_accounts(array[$1]::uuid[])' into v_ok using p_kassa;
    if not coalesce(v_ok, true) then
      raise exception 'Bu kassada amaliyot ruxsatingiz yo''q';
    end if;
  end if;

  return valyuta_child_yarat(p_kassa, p_currency);
end $$;

revoke all on function ensure_valyuta_child(uuid, text) from public, anon;
grant execute on function ensure_valyuta_child(uuid, text) to authenticated;

comment on function ensure_valyuta_child(uuid, text) is
  'Kassaga valyuta child ochadi (bor bo''lsa o''shani qaytaradi). Konvert oqimi uchun: '
  'admin emas, KONVERT + amaliyot ruxsati yetarli. Faqat hisob ochadi, pul ko''chirmaydi.';



-- #####################################################################
--  D — TEKSHIRUV (B va SEED dan keyin)
-- #####################################################################

-- D.1 Mustaqil valyuta hisobi qolmadimi (BO'SH chiqishi kerak):
select code, name, currency
  from accounts
 where section = 'pul' and is_active
   and coalesce(currency,'UZS') <> 'UZS'
   and parent_id is null;

-- D.2 Yangi tuzilma — har kassa va uning child'lari:
select p.code as kassa, p.name as kassa_nomi,
       c.code as child, c.name as child_nomi,
       coalesce(c.pul_turi, c.currency) as turi
  from accounts p
  left join accounts c on c.parent_id = p.id and c.is_active
 where p.section = 'pul' and p.is_active
   and coalesce(p.currency,'UZS') = 'UZS'
   and p.parent_id is null
   and coalesce(p.kassa_turi,'') <> 'xarajat_guruh'
 order by p.code, c.code;

-- D.3 Kartalar to'g'ri chizilyaptimi (har kassa BITTA qator bo'lishi kerak):
select id, count(*) as nechta_qator from v_kassa_card group by id having count(*) > 1;

-- D.4 Kassa kartalari (hammasi 0 — wipe'dan keyin, sync hali yozmagan):
select code, name, kassa_turi, uzs, naqd, click, payme, usd, jami,
       turi_soni, valyuta_soni
  from v_kassa_card
 order by code;

-- D.5 n8n uchun mapping (filial_ref + pul_turi -> account_id):
select filial_ref, kassa_code, kassa_name, pul_turi, turi_code, account_id
  from v_filial_turi_hisob
 order by kassa_code, pul_turi;

-- D.6 n8n uchun DOLLAR mapping (dollar = USD child, pul_turi EMAS):
select p.filial_ref, p.code as kassa_code, p.name as kassa_name,
       c.currency, c.code as valyuta_code, c.id as account_id
  from accounts p
  join accounts c on c.parent_id = p.id and c.is_active and c.currency = 'USD'
 where p.kassa_turi = 'filial' and p.filial_ref is not null and p.is_active
 order by p.code;
