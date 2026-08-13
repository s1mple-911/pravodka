-- =====================================================================
--  PROVODKA_VALYUTA_GUARD_FIX.sql
--  BUG: "Bola-hisobga valyuta qo'shib bo'lmaydi (5415)"
--
--  Nima bo'lgan:
--    kassa-dev.html "+" modali -> Valyuta -> create_valyuta_child(5415,'USD')
--    xato berardi. 5415 = Giyos, HODIM kassasi. Uning parent_id'si 5400
--    "Hodim xarajat kassalari" KONTEYNER guruh. Ya'ni parent_id NULL emas,
--    lekin bu hisob BOLA-HISOB EMAS - u to'la huquqli kassa.
--
--  Sabab (PROVODKA_KASSA_MODEL.sql, valyuta_child_yarat ichida):
--        if v_parent.parent_id is not null then raise exception ...
--    Bu shart "bola-hisob" ni parent_id bilan aniqlagan. Model o'zgargandan
--    keyin parent_id UCH ma'noli bo'ldi:
--        1) valyuta bolasi   -> currency <> 'UZS'
--        2) tur bolasi       -> pul_turi is not null (naqd/click/payme/...)
--        3) guruh a'zoligi   -> hodim kassasi, parenti 5400 konteyner
--    Faqat 1 va 2 bola-hisob; 3 esa oddiy kassa.
--
--  AYNAN shu xato tur tomonida allaqachon tuzatilgan:
--    PROVODKA_TURLAR_AVTO.sql 4-bo'lim (_pul_turi_child_ich) -> shart
--    `pul_turi is not null` ga almashtirilgan. Valyuta tomonida qolib ketgan.
--
--  Tuzatish (BU FAYL):
--    Yangi shart: bola-hisob = pul_turi is not null YOKI currency <> 'UZS'.
--    Hodim kassasi (parent = 5400, UZS, pul_turi NULL) endi O'TADI.
--    Konteyner guruhning o'ziga (kassa_turi='xarajat_guruh') valyuta qo'shish
--    HAMON TAQIQ - o'sha guard tegilmagan.
--
--  ADDITIVE: `drop` yo'q, IMZOLAR O'ZGARMAYDI:
--    valyuta_child_yarat(uuid, text)   -> uuid
--    create_valyuta_child(uuid, text)  -> uuid
--    ensure_valyuta_child(uuid, text)  -> uuid
--  Uchalasi ham `create or replace` bilan qayta yoziladi. Sabab: bazada
--  qaysi versiya turgani aniq emas (PROVODKA_KASSA2.sql da create_valyuta_child
--  monolit edi, PROVODKA_KASSA_MODEL.sql da uch qavatga bo'lingan). Uchalasini
--  birga yozsak, ikkala holatda ham natija bir xil va tuzatish yo'lda yo'qolmaydi.
--
--  Boshqa guardlar TEGILMAGAN: section='pul', currency='UZS', is_active,
--  xarajat_guruh taqiqi, admin tekshiruvi, konvert/amaliyot ruxsati,
--  idempotentlik, kod bloki mantig'i - hammasi avvalgidek.
--
--  RUN: Asilbek (Supabase SQL editor). `do` bloki YO'Q - hammasi oddiy
--       DDL + select.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. AVVAL: tuzatish nimani ochayotganini ko'ring (RUN dan oldin)
-- ---------------------------------------------------------------------
-- Eski shart tufayli valyuta qo'shib bo'lmaydigan, lekin ASLIDA to'la
-- huquqli kassalar. Odatda bular 5400 ostidagi hodim kassalari.
select a.code, a.name, a.kassa_turi, a.subtitle,
       p.code as parent_kod, p.name as parent_nom
  from accounts a
  join accounts p on p.id = a.parent_id
 where a.section = 'pul'
   and coalesce(a.is_active, true)
   and coalesce(a.currency, 'UZS') = 'UZS'
   and a.pul_turi is null
   and coalesce(a.kassa_turi, '') <> 'xarajat_guruh'
 order by a.code;


-- ---------------------------------------------------------------------
-- 1. valyuta_child_yarat - ICHKI yaratuvchi (guard tuzatildi)
-- ---------------------------------------------------------------------
-- PROVODKA_KASSA_MODEL.sql C.1 ning nusxasi; FAQAT bitta `if` sharti
-- o'zgardi (pastda "SHART O'ZGARDI" izohiga qara). Qolgan hamma qator
-- bayt-ma-bayt o'sha.
-- Huquq TEKSHIRMAYDI - uni chaqiruvchi o'ramlar tekshiradi.
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

  -- 🔴 SHART O'ZGARDI - eski: `if v_parent.parent_id is not null then raise`.
  --    Eski shart HODIM KASSASINI ham rad etardi: uning parenti 5400
  --    KONTEYNER guruh, ya'ni parent_id NULL emas. Natijada
  --    create_valyuta_child(<hodim kassasi>, 'USD') har doim
  --    "Bola-hisobga valyuta qo'shib bo'lmaydi (5415)" xatosini berardi.
  --    Yangi shart _pul_turi_child_ich (PROVODKA_TURLAR_AVTO.sql 4-bo'lim)
  --    bilan bir xil mantiqda: bola-hisob = TUR bolasi yoki VALYUTA bolasi.
  --    currency <> 'UZS' yuqorida allaqachon rad etilgan, lekin shart
  --    ochiq yozilgan - o'qiyotgan odam ikki ma'noni ko'rib tursin.
  --    Bu FAQAT BO'SHATISH: avval ruxsat etilgan biror holat yopilmadi.
  if v_parent.pul_turi is not null or coalesce(v_parent.currency,'UZS') <> 'UZS' then
    raise exception 'Bola-hisobga valyuta qo''shib bo''lmaydi (%)', v_parent.code;
  end if;

  if not v_parent.is_active then
    raise exception 'Kassa faol emas: %', v_parent.code;
  end if;
  -- Konteyner guruh (5400) - unga to'g'ridan pul yozilmaydi. TEGILMAGAN.
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
      raise exception 'Bo''sh kod bloki qolmadi (57-59 band). Kod sxemasini kengaytiring.';
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
  'ensure_valyuta_child o''ramlaridan chaqiriladi. Bola-hisob sharti: '
  'pul_turi is not null yoki currency <> UZS (parent_id EMAS - hodim kassasining '
  'parenti 5400 konteyner guruh).';


-- ---------------------------------------------------------------------
-- 2. create_valyuta_child - ADMIN o'rami (IMZO O'ZGARMAYDI)
-- ---------------------------------------------------------------------
-- Xulq eskisidek: admin bo'lmasa xato; bor bo'lsa mavjudini qaytaradi.
-- Bu yerda qayta yozilishining sababi: agar bazada hali PROVODKA_KASSA2.sql
-- dagi MONOLIT versiya tursa, 1-bo'lim tuzatishi unga yetib bormasdi.
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

comment on function create_valyuta_child(uuid, text) is
  'Kassaga valyuta bola-hisobi ochadi (admin, idempotent). Tana valyuta_child_yarat da.';


-- ---------------------------------------------------------------------
-- 3. ensure_valyuta_child - KONVERT oqimi o'rami (IMZO O'ZGARMAYDI)
-- ---------------------------------------------------------------------
-- Admin shart emas: konvert ruxsati + o'sha kassada amaliyot ruxsati yetadi.
-- Faqat hisob ochadi, pul harakat qilmaydi. Tanasi PROVODKA_KASSA_MODEL.sql
-- C.3 bilan bir xil - bu yerda ham tuzatilgan ichkiga bog'lansin deb turibdi.
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


-- =====================================================================
--  4. TEKSHIRUV (RUN dan keyin) - `do` bloki yo'q, oddiy select
-- =====================================================================

-- 4.1 Uchala funksiya ham joyidami va imzosi o'zgarmaganmi
select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as funksiya,
       pg_get_function_result(p.oid)                                       as qaytaradi,
       case when p.prosecdef then 'definer' else 'invoker' end             as huquq,
       case
         when p.proname = 'valyuta_child_yarat'
              and pg_get_function_identity_arguments(p.oid) = 'p_parent uuid, p_currency text'
           then '✅'
         when p.proname in ('create_valyuta_child', 'ensure_valyuta_child')
              and pg_get_function_identity_arguments(p.oid) like '%uuid, p_currency text'
           then '✅'
         else '❌ imzo kutilganidek emas'
       end as holat
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('valyuta_child_yarat', 'create_valyuta_child', 'ensure_valyuta_child')
 order by p.proname;

-- 4.2 Eski guard matni funksiya tanasida qolmadimi
select case
         when count(*) = 0 then '✅ eski `parent_id is not null` guardi yo''q'
         else '❌ hali eski guard bor: ' || count(*)::text || ' funksiyada'
       end as holat
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('valyuta_child_yarat', 'create_valyuta_child')
   and p.prosrc like '%v_parent.parent_id is not null%';

-- 4.3 KIMGA valyuta qo'shish MUMKIN bo'lib qoldi (to'liq ro'yxat + sabab)
--     Tuzatishdan keyin ruxsat/taqiq shu jadval bo'yicha hal bo'ladi.
select a.code, a.name, a.kassa_turi, coalesce(a.currency, 'UZS') as currency,
       a.pul_turi, p.code as parent_kod,
       case
         when a.section is distinct from 'pul'
              or coalesce(a.currency, 'UZS') <> 'UZS' then '⛔ so''m kassasi emas'
         when a.pul_turi is not null                  then '⛔ tur bola-hisobi'
         when not coalesce(a.is_active, true)         then '⛔ faol emas'
         when a.kassa_turi = 'xarajat_guruh'          then '⛔ konteyner guruh'
         else '✅ valyuta qo''shish mumkin'
       end as natija
  from accounts a
  left join accounts p on p.id = a.parent_id
 where a.section = 'pul'
 order by a.code;

-- 4.4 Hodim kassalari (5400 bolalari) endi o'tadimi
select case
         when count(*) filter (where holat <> '✅') = 0
           then '✅ hamma hodim kassasiga valyuta qo''shish mumkin (' || count(*)::text || ' ta)'
         else '❌ ' || (count(*) filter (where holat <> '✅'))::text || ' ta hodim kassasi hamon to''silgan'
       end as natija
  from (
    select case
             when a.section = 'pul'
              and coalesce(a.currency, 'UZS') = 'UZS'
              and a.pul_turi is null
              and coalesce(a.is_active, true)
              and coalesce(a.kassa_turi, '') <> 'xarajat_guruh'
               then '✅' else '❌'
           end as holat
      from accounts a
      join accounts g on g.id = a.parent_id and g.kassa_turi = 'xarajat_guruh'
     where coalesce(a.is_active, true)
  ) t;

-- 4.5 Konteyner guruhga valyuta HAMON taqiqmi (5400 o'zi)
select code, name,
       case when kassa_turi = 'xarajat_guruh'
              then '✅ taqiq kuchida (guruh hisobiga valyuta qo''shilmaydi)'
            else '❌ kassa_turi kutilganidek emas: ' || coalesce(kassa_turi, 'NULL')
       end as holat
  from accounts
 where kassa_turi = 'xarajat_guruh'
 order by code;

-- 4.6 v_kassa_card buzilmadimi: har kassa BITTA qator bo'lishi shart
--     (parent_id ikki ma'noli - dollar juftligini izlagan join `currency='USD'`
--      shartisiz 5400 ning o'nlab bolasini qaytarib, view'ni portlatardi)
select case
         when count(*) = 0 then '✅ v_kassa_card: har kassa bitta qator'
         else '❌ v_kassa_card: ' || count(*)::text || ' ta kassa takrorlanyapti'
       end as holat
  from (select id from v_kassa_card group by id having count(*) > 1) t;

-- 4.7 Bir parentda bir valyutadan IKKITA faol child bormi (bo'lsa - karta ikkilanadi)
select case
         when count(*) = 0 then '✅ dublikat valyuta bolasi yo''q'
         else '❌ ' || count(*)::text || ' ta parentda dublikat valyuta bolasi bor'
       end as holat
  from (
    select parent_id, currency
      from accounts
     where parent_id is not null
       and coalesce(currency, 'UZS') <> 'UZS'
       and is_active
     group by parent_id, currency
    having count(*) > 1
  ) t;

-- 4.8 v_kassa_valyutalar hodim kassasining valyutasini ko'rsatadimi
--     (qator bo'lmasa ham xato emas - hali hech kim USD ochmagan bo'lishi mumkin)
select v.parent_id, k.code as kassa_kod, k.name as kassa_nom,
       v.code, v.currency, v.uzs, v.fc_qoldiq
  from v_kassa_valyutalar v
  join accounts k on k.id = v.parent_id
  join accounts g on g.id = k.parent_id and g.kassa_turi = 'xarajat_guruh'
 order by k.code, v.currency;


-- =====================================================================
--  5. ROLLBACK (kerak bo'lsa) - eski guardni qaytarish
-- =====================================================================
-- Faqat 1-bo'limdagi `if` ni eskisiga qaytarish yetadi:
--     if v_parent.parent_id is not null then
--       raise exception 'Bola-hisobga valyuta qo''shib bo''lmaydi (%)', v_parent.code;
--     end if;
-- Shundan keyin hodim kassalariga valyuta qo'shish yana yopiladi (ya'ni bug
-- qaytadi) - rollback faqat kutilmagan yon ta'sir chiqsa.
