-- =====================================================================
--  PROVODKA_VALYUTA_SEED.sql — pul turi hisoblarini OMMAVIY ochish
-- ---------------------------------------------------------------------
--  ⚠️ AVVAL `PROVODKA_VALYUTA.sql` RUN qilingan bo'lishi shart
--     (accounts.pul_turi ustuni va pul_turi_kod_blok jadvali shundan keladi).
--
--  NIMA QILADI: har MARKAZIY va FILIAL kassaga bola-hisoblarni ochadi:
--        💵 Naqd   (pul_turi='naqd',  currency=UZS)
--        💳 Click  (pul_turi='click', currency=UZS)
--        📱 Payme  (pul_turi='payme', currency=UZS)
--        💲 USD    (currency='USD',   pul_turi=NULL)  ← valyuta bolasi
--
--  KIMGA OCHILMAYDI (ataylab):
--    • hodim xarajat kassalari (5401+, kassa_turi='xarajat') — ularga pul
--      naqd berib yuboriladi, Click/Payme tushmaydi. 62 ta kassa × 3 tur
--      kod bloklarini ham keraksiz to'ldirib yuborardi.
--    • 5400 konteyner guruh — unga to'g'ridan pul yozilmaydi.
--    • bola-hisoblarning o'zi (ikki qavat bo'lmasin).
--
--  NEGA HAMMA KASSAGA, faqat "Aros'da puli borlarga" emas:
--    Aros hozir 32 filialdan Click'ni 11 tasida, Payme'ni 4 tasida,
--    dollarni 10 tasida ko'rsatyapti. Lekin bugun 0 bo'lgan tur ertaga
--    ishlatiladi va n8n auto-sync tur bo'yicha yozganda hisob OLDINDAN
--    turishi kerak — bo'lmasa sinxron o'sha pulni yozolmay, jimgina
--    tashlab ketadi. Bo'sh hisob esa hech narsaga zarar qilmaydi:
--    qoldig'i 0, kartada ko'rinmaydi, hisobotga ta'sir qilmaydi.
--
--  IDEMPOTENT: bor bo'lgan tur qayta ochilmaydi. Qayta RUN qilish xavfsiz —
--  ikkinchi marta "0 ta ochildi, N ta bor edi" deydi.
--
--  ⚠️ create_pul_turi_child() / create_valyuta_child() CHAQIRILMAYDI:
--     ular auth.uid() orqali adminlikni tekshiradi, SQL editorda esa
--     auth.uid() NULL — "Faqat admin..." deb rad etardi. Shuning uchun bu
--     skript kod ajratish mantig'ini o'zi takrorlaydi (ayni algoritm).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1-QADAM. OLDINDAN KO'RISH — RUN qilishdan oldin shuni o'qing
-- ---------------------------------------------------------------------
-- Qaysi kassalarga ochiladi va nechta hisob kerak:
select kassa_turi,
       count(*)                                             as kassa_soni,
       count(*) * 3                                         as kerak_som_turi,
       count(*)                                             as kerak_usd
  from accounts
 where section = 'pul' and is_active
   and coalesce(currency,'UZS') = 'UZS'
   and parent_id is null
   and kassa_turi in ('markaziy','filial')
 group by kassa_turi
 order by kassa_turi;

-- Chetda qolayotgan pul hisoblari (ataylab — lekin ko'zdan kechiring):
select code, name, kassa_turi,
       case when kassa_turi = 'xarajat_guruh' then 'konteyner guruh'
            when kassa_turi = 'xarajat'       then 'hodim kassasi'
            when parent_id is not null        then 'bola-hisob'
            else 'kassa_turi mos emas: ' || coalesce(kassa_turi,'(bo''sh)')
       end as sabab
  from accounts
 where section = 'pul' and is_active
   and not (coalesce(currency,'UZS') = 'UZS' and parent_id is null
            and kassa_turi in ('markaziy','filial'))
 order by kassa_turi, code;

-- Kod bloklarida qancha joy bor (yetmasa 2-qadam HECH NARSA yozmay to'xtaydi):
select 'som turlari (' || b.prefix || 'xx)' as blok,
       99 - coalesce(mx.n, 0)               as bosh_joy
  from pul_turi_kod_blok b
  left join lateral (
    select max(substring(a.code from 3 for 2)::int) as n
      from accounts a where a.code ~ ('^' || b.prefix || '[0-9]{2}$')
  ) mx on true
 order by b.nav
union all
select 'USD (' || v.prefix || 'xx)',
       99 - coalesce((select max(substring(a.code from 3 for 2)::int)
                        from accounts a where a.code ~ ('^' || v.prefix || '[0-9]{2}$')), 0)
  from valyuta_kod_blok v where v.currency = 'USD';


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
  -- ---- 2.1 Oldindan sig'im tekshiruvi -------------------------------
  -- Yarim ochilib qolmasin: joy yetmasa hech narsa yozmasdan to'xtaymiz.
  -- Aniq hisob: har kassada 3 turdan nechtasi YETISHMAYAPTI (yarim to'ldirilgani ham sanaladi)
  select coalesce(sum(3 - s.bor), 0) into v_kerak
    from (
      select a.id, count(c.id) filter (where c.pul_turi is not null) as bor
        from accounts a
        left join accounts c on c.parent_id = a.id and c.is_active
       where a.section = 'pul' and a.is_active and coalesce(a.currency,'UZS') = 'UZS'
         and a.parent_id is null and a.kassa_turi in ('markaziy','filial')
       group by a.id
    ) s;

  select coalesce(sum(99 - coalesce(mx.n, 0)), 0) into v_bosh
    from pul_turi_kod_blok b
    left join lateral (
      select max(substring(a.code from 3 for 2)::int) as n
        from accounts a where a.code ~ ('^' || b.prefix || '[0-9]{2}$')
    ) mx on true;

  if v_bosh < v_kerak then
    raise exception 'Kod bloklarida joy yetmaydi: kerak ~%, bo''sh %. '
                    'pul_turi_kod_blok''ga yangi prefiks qo''shing '
                    '(masalan: insert into pul_turi_kod_blok(nav,prefix) values (4,''59''));',
                    v_kerak, v_bosh;
  end if;

  select prefix into v_usd_pref from valyuta_kod_blok where currency = 'USD';
  if p_usd and v_usd_pref is null then
    raise exception 'valyuta_kod_blok''da USD prefiksi yo''q — PROVODKA_KASSA2.sql RUN qilinganmi?';
  end if;

  -- ---- 2.2 Kassalar bo'yicha aylanish -------------------------------
  for r in
    select a.id, a.code, a.name, a.kassa_turi, a.subtitle
      from accounts a
     where a.section = 'pul' and a.is_active
       and coalesce(a.currency,'UZS') = 'UZS'
       and a.parent_id is null
       and a.kassa_turi in ('markaziy','filial')
     order by a.code
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

  raise notice '--- SEED tugadi: % kassa ko''rildi | % som-turi ochildi | % USD ochildi | % ta allaqachon bor edi',
    n_kassa, n_turi, n_usd, n_bor;
end
$seed$;


-- ---------------------------------------------------------------------
-- 3-QADAM. TEKSHIRUV
-- ---------------------------------------------------------------------
-- 3.1 Har kassada nechta tur bor (markaziy/filial uchun 3 bo'lishi kerak,
--     USD bilan birga valyuta_soni ham 1):
select c.code, c.name, c.kassa_turi, c.turi_soni, c.valyuta_soni, c.jami
  from v_kassa_card c
  join accounts a on a.id = c.id
 where a.kassa_turi in ('markaziy','filial')
 order by a.kassa_turi, c.code;

-- 3.2 Turi yetishmayotgan kassa qoldimi (bo'sh chiqishi kerak):
select a.code, a.name, a.kassa_turi,
       3 - count(c.id) filter (where c.pul_turi is not null) as yetishmayotgan_tur
  from accounts a
  left join accounts c on c.parent_id = a.id and c.is_active
 where a.section = 'pul' and a.is_active and coalesce(a.currency,'UZS') = 'UZS'
   and a.parent_id is null and a.kassa_turi in ('markaziy','filial')
 group by a.id, a.code, a.name, a.kassa_turi
having 3 - count(c.id) filter (where c.pul_turi is not null) > 0
 order by a.code;

-- 3.3 Ochilgan hisoblar ro'yxati (kod + tur):
select p.code as kassa, p.name as kassa_nomi,
       c.code, c.name, coalesce(c.pul_turi, c.currency) as turi
  from accounts c
  join accounts p on p.id = c.parent_id
 where c.section = 'pul' and c.is_active
   and (c.pul_turi is not null or c.currency <> 'UZS')
   and p.kassa_turi in ('markaziy','filial')
 order by p.code, c.code;

-- 3.4 Kassa qoldiqlari O'ZGARMAGANIGA ishonch:
--     yangi hisoblarda yozuv yo'q, ya'ni hammasi 0 — jami avvalgidek qolishi kerak.
select coalesce(sum(qoldiq), 0) as yangi_hisoblardagi_pul_nol_bolishi_kerak
  from v_kassa_turlar;

-- 3.5 n8n uchun qidiruv jadvali to'ldimi (filial_ref + pul_turi -> account_id):
select filial_ref, kassa_code, pul_turi, turi_code
  from v_filial_turi_hisob
 order by kassa_code, pul_turi;
