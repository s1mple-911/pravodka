-- =====================================================================
--  PROVODKA_SYNC_FIX.sql — sync'dan chetda qolgan kassalarni tuzatish
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  IKKI ISH:
--    1) 5217 Yunusobod Universam — filial_ref 10 -> 19
--       (Aros bu kassani id=19 bilan yuboradi)
--    2) 5232 Karshi Bahor Accessories (filial_ref=34) va tur child'i
--       yo'q boshqa kassalarga naqd/click/payme + USD ochish
--
--  filial_ref=18 — TEGILMAYDI (keraksiz kassa, so'ralgani bo'yicha).
--
--  IDEMPOTENT: qayta RUN xavfsiz — o'zgargan narsa qayta o'zgarmaydi,
--  bor child qayta ochilmaydi.
--
--  ⚠️ 2-band SEED bilan AYNI algoritm (kod bloki + ketma-ket raqam).
--     Alohida yozilgan sababi: bu bir martalik tuzatish fayli, hech qanday
--     boshqa faylga bog'lanmasin. create_pul_turi_child() chaqirilmaydi —
--     u auth.uid() orqali adminlikni tekshiradi, SQL editorda auth.uid() NULL.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. HOZIRGI HOLAT (avval shuni o'qing)
-- ---------------------------------------------------------------------

-- 0.1 Gap ketayotgan kassalar va ular bilan bog'liq filial_ref lar
select k.code, k.name, k.kassa_turi, k.filial_ref, k.warehouse_id, k.is_active,
       (select count(*) from accounts c
         where c.parent_id = k.id and c.is_active and c.pul_turi is not null) as som_turi,
       (select count(*) from accounts c
         where c.parent_id = k.id and c.is_active and c.currency = 'USD')     as usd
  from accounts k
 where k.code in ('5217','5232')
    or btrim(k.filial_ref::text) in ('10','18','19','34')
 order by k.code;

-- 0.2 filial_ref bo'yicha DUBLIKAT bormi (bo'sh chiqishi kerak).
--     Dublikat = v_filial_sync_mapping bitta ref uchun ikki qator beradi,
--     RPC esa limit 1 bilan tasodifiy birini oladi -> pul noto'g'ri hisobga.
select btrim(filial_ref::text) as ref, count(*) as nechta,
       string_agg(code || ' ' || name, ' | ') as kassalar
  from accounts
 where section = 'pul' and is_active and parent_id is null and filial_ref is not null
 group by btrim(filial_ref::text)
having count(*) > 1;

-- 0.3 Tur child'i yetishmayotgan kassalar (5232 shu yerda ko'rinishi kerak)
select k.code, k.name, k.filial_ref,
       3 - count(c.id) filter (where c.pul_turi is not null) as yetmayotgan_som_turi,
       1 - count(c.id) filter (where c.currency = 'USD')     as yetmayotgan_usd
  from accounts k
  left join accounts c on c.parent_id = k.id and c.is_active and c.section = 'pul'
 where k.section = 'pul' and k.is_active
   and coalesce(k.currency,'UZS') = 'UZS'
   and k.parent_id is null
   and coalesce(k.kassa_turi,'') <> 'xarajat_guruh'
 group by k.id, k.code, k.name, k.filial_ref
having count(c.id) filter (where c.pul_turi is not null) < 3
    or count(c.id) filter (where c.currency = 'USD') < 1
 order by k.code;


-- ---------------------------------------------------------------------
-- 1. 5217 Yunusobod Universam: filial_ref 10 -> 19
-- ---------------------------------------------------------------------
do $ref$
declare
  -- ⚙️ SOZLAMA
  p_kod   text := '5217';
  p_eski  text := '10';
  p_yangi text := '19';

  v_id      uuid;
  v_joriy   text;
  v_nom     text;
  v_band    text;
  v_eski_eg text;
begin
  select id, btrim(filial_ref::text), name
    into v_id, v_joriy, v_nom
    from accounts
   where code = p_kod and is_active;

  if v_id is null then
    raise exception 'Kassa % topilmadi (yoki faol emas)', p_kod;
  end if;

  -- Idempotent: allaqachon yangi qiymatda bo'lsa tegmaymiz
  if v_joriy is not distinct from p_yangi then
    raise notice 'O''ZGARMADI: % (%) allaqachon filial_ref=%', p_kod, v_nom, p_yangi;
    return;
  end if;

  -- Kutilgan eski qiymatda ekanini tasdiqlaymiz — boshqa qiymat bo'lsa
  -- kimdir oldin o'zgartirgan, ko'r-ko'rona ustiga yozmaymiz.
  if v_joriy is distinct from p_eski then
    raise exception 'TO''XTADI: % kassaning filial_ref''i % (kutilgani %). '
                    'Kimdir o''zgartirganmi? Qo''lda tekshiring.', p_kod, coalesce(v_joriy,'(bo''sh)'), p_eski;
  end if;

  -- ⚠️ ASOSIY TO'SIQ: yangi qiymat boshqa kassada band bo'lmasin.
  select string_agg(code || ' ' || name, ' | ')
    into v_band
    from accounts
   where section = 'pul' and is_active and parent_id is null
     and btrim(filial_ref::text) = p_yangi
     and id <> v_id;

  if v_band is not null then
    raise exception 'TO''XTADI: filial_ref=% allaqachon band: %. '
                    'Ikki kassada bir xil ref bo''lsa sync pulni tasodifiy '
                    'birontasiga yozadi. Avval o''sha kassani hal qiling.', p_yangi, v_band;
  end if;

  update accounts set filial_ref = p_yangi where id = v_id;
  raise notice 'O''ZGARDI: % (%) filial_ref % -> %', p_kod, v_nom, p_eski, p_yangi;

  -- Eski qiymat endi bo'shadi — boshqa kassa uni ishlatayotgan bo'lsa aytamiz
  select string_agg(code || ' ' || name, ' | ')
    into v_eski_eg
    from accounts
   where section = 'pul' and is_active and parent_id is null
     and btrim(filial_ref::text) = p_eski;

  if v_eski_eg is not null then
    raise notice 'ESLATMA: filial_ref=% ni boshqa kassa ham ishlatyapti: %', p_eski, v_eski_eg;
  else
    raise notice 'ESLATMA: filial_ref=% endi hech qaysi kassada yo''q. Aros''da shu id li '
                 'cachier bo''lsa, unga mos kassa Provodka''da yo''q degani.', p_eski;
  end if;
end
$ref$;


-- ---------------------------------------------------------------------
-- 2. Tur child'i yo'q kassalarga ochish (5232 va boshqalari)
-- ---------------------------------------------------------------------
-- Faqat 5232 emas — YETISHMAYOTGAN hammasiga. Sababi: 5232 SEED'dan keyin
-- qo'shilgan; xuddi shunday yana kassa qo'shilgan bo'lsa u ham tuzalsin.
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
  n_kassa    int := 0;
begin
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
    -- som turlari
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

    -- USD (valyuta child'i — pul_turi EMAS)
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

    n_kassa := n_kassa + 1;
  end loop;

  raise notice '--- 2-band tugadi: % kassa ko''rildi | % som-turi | % USD ochildi',
    n_kassa, n_turi, n_usd;
end
$child$;


-- ---------------------------------------------------------------------
-- 3. TEKSHIRUV — 34 va 19 mapping'da paydo bo'ldimi
-- ---------------------------------------------------------------------

-- 3.1 ⬅️ ASOSIY: 34 va 19 bo'yicha 4 tadan qator bo'lishi kerak
select filial_ref, kassa_code, kassa_name,
       count(*) as qatorlar,
       string_agg(aros_maydon, ', ' order by aros_maydon) as maydonlar
  from v_filial_sync_mapping
 where btrim(filial_ref::text) in ('19','34')
 group by filial_ref, kassa_code, kassa_name
 order by kassa_code;

-- 3.2 Mapping jami (avval 124 edi — endi ko'proq bo'lishi kerak)
select count(*) as mapping_jami,
       count(distinct filial_ref) as filiallar
  from v_filial_sync_mapping;

-- 3.3 Dublikat ref qolmadimi (BO'SH chiqishi kerak)
select btrim(filial_ref::text) as ref, count(*) as nechta,
       string_agg(code || ' ' || name, ' | ') as kassalar
  from accounts
 where section = 'pul' and is_active and parent_id is null and filial_ref is not null
 group by btrim(filial_ref::text)
having count(*) > 1;

-- 3.4 Tur child'i yetishmayotgan kassa qoldimi (BO'SH chiqishi kerak)
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

-- 3.5 Yangi hisoblarda pul YO'Q ekani (struktura o'zgardi, qoldiq emas)
select coalesce(sum(qoldiq), 0) as yangi_hisoblardagi_pul_nol_bolishi_kerak
  from v_kassa_turlar;
