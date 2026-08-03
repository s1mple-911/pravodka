-- =====================================================================
--  PROVODKA_SYNC_FIX2.sql — bo'sh (NULL) ustunli kassalarni tuzatish
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  MUAMMO: 5232 (Karshi Bahor Accessories, filial_ref=34) da
--          section = NULL va kassa_turi = NULL.
--          SEED va SYNC_FIX shartlarida `section = 'pul'` bor —
--          NULL = 'pul' -> NULL (ya'ni FALSE), shuning uchun 5232 jimgina
--          chetda qolgan va tur child'lari ochilmagan.
--
--  ⚠️ SECTION YOLG'IZ MUAMMO EMAS. Boshqa joylar ham NULL'dan yiqiladi:
--     • v_kassa_card:  `p.currency = 'UZS'` (coalesce'SIZ!) -> currency NULL
--       bo'lsa kassa KARTADA UMUMAN KO'RINMAYDI.
--     • klient isKassa(): `a.type === 'aktiv'` -> type NULL bo'lsa kassa
--       dropdownlarda chiqmaydi (provodka, jurnal, professional).
--     Shuning uchun bu skript to'rtta ustunni ham tekshiradi:
--       section, kassa_turi, currency, type
--
--  USUL: qiymatlar QO'LDA yozilmaydi — mavjud filial kassalaridan
--        (52xx, faol, mustaqil) eng ko'p uchraydigani olinadi.
--
--  XAVFSIZLIK: FAQAT NULL/bo'sh qiymatlar to'ldiriladi. Mavjud (NULL bo'lmagan)
--        qiymat HECH QACHON ustiga yozilmaydi — noto'g'ri bo'lsa ham,
--        u haqda faqat xabar beriladi.
--
--  IDEMPOTENT: qayta RUN xavfsiz (to'ldiradigan NULL qolmaydi).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. DIAGNOSTIKA — avval shuni o'qing
-- ---------------------------------------------------------------------

-- 0.1 5232 va uning "sog'lom" qo'shnilari yonma-yon
select code, name, section, kassa_turi, currency, type, is_active,
       parent_id is null as mustaqil, filial_ref, warehouse_id
  from accounts
 where code in ('5230','5231','5232','5233')
    or (code ~ '^52[0-9]{2}$' and section = 'pul')
 order by code
 limit 15;

-- 0.2 Bo'sh ustunli HAMMA hisob (nafaqat 52xx) — to'liq manzara.
--     `tuzatiladi` ustuni: bu skript unga tegadimi yoki yo'q.
select code, name, section, kassa_turi, currency, type, is_active,
       parent_id is null as mustaqil,
       case when code ~ '^52[0-9]{2}$' and parent_id is null and is_active
            then 'HA — filial kassasi'
            else 'yo''q — qo''lda hal qiling'
       end as tuzatiladi
  from accounts
 where section is null or kassa_turi is null or currency is null or type is null
 order by code;

-- 0.3 Sanoq: nechta 52xx kassada bo'sh ustun bor
select count(*) filter (where section is null)     as section_null,
       count(*) filter (where kassa_turi is null)  as kassa_turi_null,
       count(*) filter (where currency is null)    as currency_null,
       count(*) filter (where type is null)        as type_null
  from accounts
 where code ~ '^52[0-9]{2}$' and parent_id is null and is_active;


-- ---------------------------------------------------------------------
-- 1. BO'SH USTUNLARNI TO'LDIRISH (52xx mustaqil kassalar)
-- ---------------------------------------------------------------------
do $fix$
declare
  v_section text;
  v_turi    text;
  v_cur     text;
  v_type    text;
  v_namuna  int;
  r         record;
  n_tuzat   int := 0;
  n_farq    int := 0;
begin
  -- ---- 1.1 Etalon qiymatlarni SOG'LOM filial kassalaridan olamiz ----
  -- Qo'lda 'pul'/'filial' deb yozib qo'ymaymiz: bazada qanday bo'lsa shunday.
  select count(*) into v_namuna
    from accounts
   where code ~ '^52[0-9]{2}$' and parent_id is null and is_active
     and section is not null and kassa_turi is not null;

  if v_namuna = 0 then
    raise exception 'TO''XTADI: taqqoslash uchun sog''lom 52xx kassa topilmadi. '
                    'Etalon qiymatni aniqlab bo''lmadi — 0.1 so''rovini ko''ring.';
  end if;

  select mode() within group (order by section)    into v_section
    from accounts where code ~ '^52[0-9]{2}$' and parent_id is null and is_active and section is not null;
  select mode() within group (order by kassa_turi) into v_turi
    from accounts where code ~ '^52[0-9]{2}$' and parent_id is null and is_active and kassa_turi is not null;
  select mode() within group (order by currency)   into v_cur
    from accounts where code ~ '^52[0-9]{2}$' and parent_id is null and is_active and currency is not null;
  select mode() within group (order by type)       into v_type
    from accounts where code ~ '^52[0-9]{2}$' and parent_id is null and is_active and type is not null;

  raise notice 'Etalon (% ta sog''lom kassadan): section=% kassa_turi=% currency=% type=%',
    v_namuna, v_section, v_turi, v_cur, v_type;

  if v_section is null or v_turi is null or v_cur is null or v_type is null then
    raise exception 'TO''XTADI: etalon qiymatlarning biri aniqlanmadi '
                    '(section=%, kassa_turi=%, currency=%, type=%)', v_section, v_turi, v_cur, v_type;
  end if;

  -- ---- 1.2 Faqat NULL larni to'ldiramiz ----------------------------
  for r in
    select id, code, name, section, kassa_turi, currency, type
      from accounts
     where code ~ '^52[0-9]{2}$' and parent_id is null and is_active
       and (section is null or kassa_turi is null or currency is null or type is null)
     order by code
  loop
    update accounts
       set section    = coalesce(section,    v_section),
           kassa_turi = coalesce(kassa_turi, v_turi),
           currency   = coalesce(currency,   v_cur),
           type       = coalesce(type,       v_type)
     where id = r.id;

    n_tuzat := n_tuzat + 1;
    raise notice 'TUZATILDI: % (%) — section:% kassa_turi:% currency:% type:%',
      r.code, r.name,
      case when r.section    is null then v_section || ' (yangi)' else r.section    || ' (tegilmadi)' end,
      case when r.kassa_turi is null then v_turi    || ' (yangi)' else r.kassa_turi || ' (tegilmadi)' end,
      case when r.currency   is null then v_cur     || ' (yangi)' else r.currency   || ' (tegilmadi)' end,
      case when r.type       is null then v_type    || ' (yangi)' else r.type       || ' (tegilmadi)' end;
  end loop;

  -- ---- 1.3 NULL emas, lekin etalondan FARQ qiladiganlar -------------
  -- Bularga TEGILMAYDI (ataylab) — faqat aytiladi, qarorni odam qabul qiladi.
  for r in
    select code, name, section, kassa_turi, currency, type
      from accounts
     where code ~ '^52[0-9]{2}$' and parent_id is null and is_active
       and (section <> v_section or kassa_turi <> v_turi or currency <> v_cur or type <> v_type)
     order by code
  loop
    n_farq := n_farq + 1;
    raise notice 'DIQQAT (tegilmadi): % (%) — section=% kassa_turi=% currency=% type=%',
      r.code, r.name, r.section, r.kassa_turi, r.currency, r.type;
  end loop;

  raise notice '--- 1-band: % kassa tuzatildi | % kassada etalondan farq bor (tegilmadi)',
    n_tuzat, n_farq;
end
$fix$;


-- ---------------------------------------------------------------------
-- 2. TUR CHILD'LARINI OCHISH (endi 5232 ham shartga tushadi)
-- ---------------------------------------------------------------------
-- SEED bilan ayni algoritm. 1-band section/currency ni to'ldirgani uchun
-- 5232 endi bu shartdan o'tadi.
do $child$
declare
  r          record;
  t          text;
  v_prefix   text;
  v_next     int;
  v_code     text;
  v_lbl      text;
  v_usd_pref text;
  n_turi     int := 0;
  n_usd      int := 0;
  n_qoldi    int := 0;
begin
  -- Xavfsizlik: 1-banddan keyin bo'sh section qolmasligi kerak
  select count(*) into n_qoldi
    from accounts
   where code ~ '^52[0-9]{2}$' and parent_id is null and is_active and section is null;
  if n_qoldi > 0 then
    raise exception 'TO''XTADI: % ta 52xx kassada hali section NULL — 1-band ishlamadi', n_qoldi;
  end if;

  select prefix into v_usd_pref from valyuta_kod_blok where currency = 'USD';
  if v_usd_pref is null then
    raise exception 'valyuta_kod_blok''da USD prefiksi yo''q';
  end if;

  for r in
    select k.id, k.code, k.name, k.kassa_turi, k.subtitle
      from accounts k
     where k.section = 'pul' and k.is_active
       and coalesce(k.currency,'UZS') = 'UZS'
       and k.parent_id is null
       and coalesce(k.kassa_turi,'') <> 'xarajat_guruh'
     order by k.code
  loop
    foreach t in array array['naqd','click','payme']
    loop
      if exists (select 1 from accounts c
                  where c.parent_id = r.id and c.pul_turi = t and c.is_active) then
        continue;
      end if;

      v_prefix := null;
      select b.prefix, coalesce(mx.n, 0) + 1
        into v_prefix, v_next
        from pul_turi_kod_blok b
        left join lateral (
          select max(substring(a.code from 3 for 2)::int) as n
            from accounts a where a.code ~ ('^' || b.prefix || '[0-9]{2}$')
        ) mx on true
       where coalesce(mx.n, 0) + 1 <= 99
       order by b.nav
       limit 1;

      if v_prefix is null then
        raise exception 'Tur kod bloklari to''ldi (% kassada to''xtadi)', r.code;
      end if;

      v_code := v_prefix || lpad(v_next::text, 2, '0');
      v_lbl  := case t when 'naqd' then 'Naqd' when 'click' then 'Click' else 'Payme' end;

      insert into accounts(code, name, type, section, currency, parent_id,
                           kassa_turi, is_active, subtitle, pul_turi)
      values (v_code, r.name || ' · ' || v_lbl, 'aktiv', 'pul', 'UZS', r.id,
              r.kassa_turi, true, r.subtitle, t);
      n_turi := n_turi + 1;
      raise notice 'OCHILDI: % — % (%)', r.code, v_lbl, v_code;
    end loop;

    if not exists (select 1 from accounts c
                    where c.parent_id = r.id and c.currency = 'USD' and c.is_active) then
      select coalesce(max(substring(a.code from 3 for 2)::int), 0) + 1
        into v_next
        from accounts a
       where a.code ~ ('^' || v_usd_pref || '[0-9]{2}$');
      if v_next > 99 then
        raise exception 'USD kod bloki (%xx) to''ldi (% kassada)', v_usd_pref, r.code;
      end if;
      v_code := v_usd_pref || lpad(v_next::text, 2, '0');

      insert into accounts(code, name, type, section, currency, parent_id,
                           kassa_turi, is_active, subtitle)
      values (v_code, r.name || ' · USD', 'aktiv', 'pul', 'USD', r.id,
              r.kassa_turi, true, r.subtitle);
      n_usd := n_usd + 1;
      raise notice 'OCHILDI: % — USD (%)', r.code, v_code;
    end if;
  end loop;

  raise notice '--- 2-band: % som-turi | % USD ochildi', n_turi, n_usd;
end
$child$;


-- ---------------------------------------------------------------------
-- 3. TEKSHIRUV
-- ---------------------------------------------------------------------

-- 3.1 ⬅️ ASOSIY: mapping 124 -> 128 bo'lishi kerak
select count(*) as mapping_jami,
       count(distinct filial_ref) as filiallar
  from v_filial_sync_mapping;

-- 3.2 5232 (filial_ref=34) mapping'da 4 qator bilan turibdimi
select filial_ref, kassa_code, kassa_name,
       count(*) as qatorlar,
       string_agg(aros_maydon, ', ' order by aros_maydon) as maydonlar
  from v_filial_sync_mapping
 where btrim(filial_ref::text) in ('19','34')
 group by filial_ref, kassa_code, kassa_name
 order by kassa_code;

-- 3.3 5232 endi kassa KARTASIDA ham ko'rinadimi
--     (currency NULL bo'lsa v_kassa_card uni umuman ko'rsatmasdi)
select code, name, kassa_turi, uzs, naqd, click, payme, usd, jami, turi_soni
  from v_kassa_card
 where code in ('5231','5232')
 order by code;

-- 3.4 Bo'sh ustunli 52xx kassa qoldimi (BO'SH chiqishi kerak)
select code, name, section, kassa_turi, currency, type
  from accounts
 where code ~ '^52[0-9]{2}$' and parent_id is null and is_active
   and (section is null or kassa_turi is null or currency is null or type is null);

-- 3.5 52xx dan TASHQARIDA bo'sh ustunli hisob qoldimi
--     (bularga skript tegmagan — ko'rib chiqing, kerak bo'lsa qo'lda tuzating)
select code, name, section, kassa_turi, currency, type, parent_id is null as mustaqil
  from accounts
 where (section is null or kassa_turi is null or currency is null or type is null)
   and not (code ~ '^52[0-9]{2}$' and parent_id is null and is_active)
 order by code;

-- 3.6 Tur child'i yetishmayotgan kassa qoldimi (BO'SH chiqishi kerak)
select k.code, k.name,
       3 - count(c.id) filter (where c.pul_turi is not null) as yetmayotgan_som_turi,
       1 - count(c.id) filter (where c.currency = 'USD')     as yetmayotgan_usd
  from accounts k
  left join accounts c on c.parent_id = k.id and c.is_active and c.section = 'pul'
 where k.section = 'pul' and k.is_active
   and coalesce(k.currency,'UZS') = 'UZS'
   and k.parent_id is null
   and coalesce(k.kassa_turi,'') <> 'xarajat_guruh'
 group by k.id, k.code, k.name
having count(c.id) filter (where c.pul_turi is not null) < 3
    or count(c.id) filter (where c.currency = 'USD') < 1
 order by k.code;

-- 3.7 Yangi hisoblarda pul YO'Q ekani (struktura o'zgardi, qoldiq emas)
select coalesce(sum(qoldiq), 0) as yangi_hisoblardagi_pul_nol_bolishi_kerak
  from v_kassa_turlar;
