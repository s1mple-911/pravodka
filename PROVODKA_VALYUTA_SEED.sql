-- =====================================================================
--  PROVODKA_VALYUTA_SEED.sql — pul turi hisoblarini OMMAVIY ochish
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  ⚠️ AVVAL `PROVODKA_VALYUTA.sql` RUN qilingan bo'lishi shart
--     (accounts.pul_turi ustuni va pul_turi_kod_blok jadvali shundan keladi).
--
--  NIMA QILADI: har kassaga bola-hisoblarni ochadi:
--        💵 Naqd   (pul_turi='naqd',  currency=UZS)
--        💳 Click  (pul_turi='click', currency=UZS)
--        📱 Payme  (pul_turi='payme', currency=UZS)
--        💲 USD    (currency='USD',   pul_turi=NULL)  ← valyuta bolasi
--
--  QAYSI KASSAGA — kassa_turi matniga TAYANMAYDI:
--     tanlash sharti "mustaqil so'm kassasi": section='pul', currency='UZS',
--     parent_id IS NULL, faol, va konteyner guruh (5400) emas.
--     Bu markaziy va filial kassalarni oladi. Hodim kassalari (5401+) o'z-o'zidan
--     chetda qoladi — ularning parent_id'si 5400, ya'ni mustaqil emas.
--     ⚠️ Avvalgi variantda `kassa_turi in ('markaziy','filial')` sharti bor edi;
--        o'sha ustunda boshqa qiymat tursa seed JIMGINA hech narsa yaratmasdi.
--        Endi 0 kassa topilsa — xato beradi, jimgina o'tmaydi.
--
--  IDEMPOTENT: bor bo'lgan tur qayta ochilmaydi. Qayta RUN xavfsiz.
--
--  ⚠️ create_pul_turi_child() / create_valyuta_child() CHAQIRILMAYDI:
--     ular auth.uid() orqali adminlikni tekshiradi, SQL editorda esa
--     auth.uid() NULL — "Faqat admin..." deb rad etardi. Shuning uchun bu
--     skript kod ajratish mantig'ini o'zi takrorlaydi (ayni algoritm).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1-QADAM. OLDINDAN KO'RISH — RUN qilishdan oldin shuni o'qing
-- ---------------------------------------------------------------------

-- 1.1 Qaysi kassalarga ochiladi (shu ro'yxat BO'SH bo'lmasligi kerak):
select code, name, kassa_turi, filial_ref,
       (select count(*) from accounts c
         where c.parent_id = k.id and c.is_active and c.pul_turi is not null) as hozir_som_turi,
       (select count(*) from accounts c
         where c.parent_id = k.id and c.is_active and c.currency = 'USD')     as hozir_usd
  from accounts k
 where k.section = 'pul' and k.is_active
   and coalesce(k.currency,'UZS') = 'UZS'
   and k.parent_id is null
   and coalesce(k.kassa_turi,'') <> 'xarajat_guruh'
 order by k.code;

-- 1.2 Chetda qolayotgan pul hisoblari (ataylab — lekin ko'zdan kechiring):
select code, name, kassa_turi, currency, parent_id is not null as bola_hisob,
       case when coalesce(kassa_turi,'') = 'xarajat_guruh' then 'konteyner guruh'
            when parent_id is not null then 'bola-hisob (hodim kassasi yoki tur/valyuta child)'
            when coalesce(currency,'UZS') <> 'UZS' then 'valyuta hisobi (mustaqil turibdi)'
            else 'faol emas'
       end as sabab
  from accounts
 where section = 'pul'
   and not (is_active and coalesce(currency,'UZS') = 'UZS' and parent_id is null
            and coalesce(kassa_turi,'') <> 'xarajat_guruh')
 order by code;

-- 1.3 Kod bloklarida qancha joy bor.
--     ⚠️ ORDER BY faqat UNION'dan KEYIN kelishi mumkin — shuning uchun
--        saralash tashqi so'rovda (avvalgi versiyada shu yerda sintaksis xato bor edi).
select s.blok, s.bosh_joy
  from (
    select 1 as guruh,
           b.nav as tartib,
           'som turlari (' || b.prefix || 'xx)' as blok,
           99 - coalesce(mx.n, 0) as bosh_joy
      from pul_turi_kod_blok b
      left join lateral (
        select max(substring(a.code from 3 for 2)::int) as n
          from accounts a where a.code ~ ('^' || b.prefix || '[0-9]{2}$')
      ) mx on true
    union all
    select 2 as guruh,
           0 as tartib,
           'USD (' || v.prefix || 'xx)' as blok,
           99 - coalesce((select max(substring(a.code from 3 for 2)::int)
                            from accounts a where a.code ~ ('^' || v.prefix || '[0-9]{2}$')), 0) as bosh_joy
      from valyuta_kod_blok v
     where v.currency = 'USD'
  ) s
 order by s.guruh, s.tartib;


-- ---------------------------------------------------------------------
-- 2-QADAM. OCHISH
-- ---------------------------------------------------------------------
do $seed$
declare
  -- ⚙️ SOZLAMA: USD bolasi ham ochilsinmi. Kod bloki (56xx) tor bo'lsa
  --    false qilib, som turlarini alohida ochish mumkin.
  p_usd boolean := true;

  r          record;
  t          text;
  v_prefix   text;
  v_next     int;
  v_code     text;
  v_lbl      text;
  v_usd_pref text;
  n_kassa    int := 0;
  n_turi     int := 0;
  n_usd      int := 0;
  n_bor      int := 0;
  v_kerak    int;
  v_bosh     int;
begin
  -- ---- 2.1 Nishon kassalar bormi -----------------------------------
  select count(*) into n_kassa
    from accounts k
   where k.section = 'pul' and k.is_active
     and coalesce(k.currency,'UZS') = 'UZS'
     and k.parent_id is null
     and coalesce(k.kassa_turi,'') <> 'xarajat_guruh';

  if n_kassa = 0 then
    raise exception 'TO''XTADI: birorta mustaqil so''m kassasi topilmadi. '
                    'Shart: section=''pul'', currency=''UZS'', parent_id IS NULL, '
                    'is_active, kassa_turi <> ''xarajat_guruh''. 1.1 so''rovini tekshiring.';
  end if;
  raise notice 'Nishon kassalar: % ta', n_kassa;
  n_kassa := 0;

  -- ---- 2.2 Oldindan sig'im tekshiruvi -------------------------------
  -- Yarim ochilib qolmasin: joy yetmasa hech narsa yozmasdan to'xtaymiz.
  select coalesce(sum(3 - s.bor), 0) into v_kerak
    from (
      select k.id, count(c.id) filter (where c.pul_turi is not null) as bor
        from accounts k
        left join accounts c on c.parent_id = k.id and c.is_active
       where k.section = 'pul' and k.is_active
         and coalesce(k.currency,'UZS') = 'UZS'
         and k.parent_id is null
         and coalesce(k.kassa_turi,'') <> 'xarajat_guruh'
       group by k.id
    ) s;

  select coalesce(sum(99 - coalesce(mx.n, 0)), 0) into v_bosh
    from pul_turi_kod_blok b
    left join lateral (
      select max(substring(a.code from 3 for 2)::int) as n
        from accounts a where a.code ~ ('^' || b.prefix || '[0-9]{2}$')
    ) mx on true;

  raise notice 'Kerak: % ta som-turi | Bo''sh kod: % ta', v_kerak, v_bosh;

  if v_bosh < v_kerak then
    raise exception 'Kod bloklarida joy yetmaydi: kerak %, bo''sh %. '
                    'pul_turi_kod_blok''ga yangi prefiks qo''shing '
                    '(masalan: insert into pul_turi_kod_blok(nav,prefix) values (4,''59''));',
                    v_kerak, v_bosh;
  end if;

  if p_usd then
    select prefix into v_usd_pref from valyuta_kod_blok where currency = 'USD';
    if v_usd_pref is null then
      raise exception 'valyuta_kod_blok''da USD prefiksi yo''q — PROVODKA_KASSA2.sql RUN qilinganmi?';
    end if;
  end if;

  -- ---- 2.3 Kassalar bo'yicha aylanish -------------------------------
  for r in
    select k.id, k.code, k.name, k.kassa_turi, k.subtitle
      from accounts k
     where k.section = 'pul' and k.is_active
       and coalesce(k.currency,'UZS') = 'UZS'
       and k.parent_id is null
       and coalesce(k.kassa_turi,'') <> 'xarajat_guruh'
     order by k.code
  loop
    n_kassa := n_kassa + 1;

    -- --- som turlari: naqd / click / payme ---
    foreach t in array array['naqd','click','payme']
    loop
      if exists (select 1 from accounts c
                  where c.parent_id = r.id and c.pul_turi = t and c.is_active) then
        n_bor := n_bor + 1;
        continue;
      end if;

      -- Bo'sh joyi bor birinchi blok. Har aylanishda qayta hisoblanadi —
      -- shu tranzaksiyada yangi qo'shilgan kodlar ham ko'rinadi.
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
    end loop;

    -- --- USD (valyuta bolasi — pul_turi EMAS) ---
    if p_usd then
      if exists (select 1 from accounts c
                  where c.parent_id = r.id and c.currency = 'USD' and c.is_active) then
        n_bor := n_bor + 1;
      else
        select coalesce(max(substring(a.code from 3 for 2)::int), 0) + 1
          into v_next
          from accounts a
         where a.code ~ ('^' || v_usd_pref || '[0-9]{2}$');
        if v_next > 99 then
          raise exception 'USD kod bloki (%xx) to''ldi (% kassada to''xtadi). '
                          'p_usd := false qilib som turlarini alohida oching.', v_usd_pref, r.code;
        end if;
        v_code := v_usd_pref || lpad(v_next::text, 2, '0');

        insert into accounts(code, name, type, section, currency, parent_id,
                             kassa_turi, is_active, subtitle)
        values (v_code, r.name || ' · USD', 'aktiv', 'pul', 'USD', r.id,
                r.kassa_turi, true, r.subtitle);
        n_usd := n_usd + 1;
      end if;
    end if;
  end loop;

  raise notice '--- SEED tugadi: % kassa | % som-turi ochildi | % USD ochildi | % ta allaqachon bor edi',
    n_kassa, n_turi, n_usd, n_bor;

  if n_turi = 0 and n_usd = 0 and n_bor = 0 then
    raise exception 'TO''XTADI: birorta hisob ochilmadi va bor ham emas — kutilmagan holat.';
  end if;
end
$seed$;


-- ---------------------------------------------------------------------
-- 3-QADAM. TEKSHIRUV
-- ---------------------------------------------------------------------

-- 3.1 Har kassada nechta tur bor (3 som-turi + 1 USD bo'lishi kerak):
select k.code, k.name, k.kassa_turi,
       count(c.id) filter (where c.pul_turi is not null) as som_turi,
       count(c.id) filter (where c.currency = 'USD')     as usd
  from accounts k
  left join accounts c on c.parent_id = k.id and c.is_active and c.section = 'pul'
 where k.section = 'pul' and k.is_active
   and coalesce(k.currency,'UZS') = 'UZS'
   and k.parent_id is null
   and coalesce(k.kassa_turi,'') <> 'xarajat_guruh'
 group by k.code, k.name, k.kassa_turi
 order by k.code;

-- 3.2 Turi yetishmayotgan kassa qoldimi (BO'SH chiqishi kerak):
select k.code, k.name,
       3 - count(c.id) filter (where c.pul_turi is not null) as yetishmayotgan_tur
  from accounts k
  left join accounts c on c.parent_id = k.id and c.is_active
 where k.section = 'pul' and k.is_active
   and coalesce(k.currency,'UZS') = 'UZS'
   and k.parent_id is null
   and coalesce(k.kassa_turi,'') <> 'xarajat_guruh'
 group by k.id, k.code, k.name
having 3 - count(c.id) filter (where c.pul_turi is not null) > 0
 order by k.code;

-- 3.3 Ochilgan hisoblar ro'yxati:
select p.code as kassa, p.name as kassa_nomi,
       c.code, c.name, coalesce(c.pul_turi, c.currency) as turi
  from accounts c
  join accounts p on p.id = c.parent_id
 where c.section = 'pul' and c.is_active
   and (c.pul_turi is not null or coalesce(c.currency,'UZS') <> 'UZS')
 order by p.code, c.code;

-- 3.4 Kassa qoldiqlari O'ZGARMAGANIGA ishonch:
--     yangi hisoblarda yozuv yo'q, ya'ni hammasi 0.
select coalesce(sum(qoldiq), 0) as yangi_hisoblardagi_pul_nol_bolishi_kerak
  from v_kassa_turlar;

-- 3.5 Kartalar to'g'ri chizilyaptimi (har kassa BITTA qator):
select id, count(*) as nechta_qator
  from v_kassa_card
 group by id
having count(*) > 1;
