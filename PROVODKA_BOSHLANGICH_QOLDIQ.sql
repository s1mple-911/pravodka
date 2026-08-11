-- =====================================================================
--  PROVODKA_BOSHLANGICH_QOLDIQ.sql
--  UCHTA kassani NOLGA tushirib, boshlang'ich kapital sifatida yangi
--  qoldiq kiritish:
--      5011  Toshkent kassa
--      5012  Qashqadaryo kassa
--      54xx  Abrorxo'ja Axmadov (hodim kassasi — kod qidiruv bilan topiladi)
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  NIMA QILADI (har kassa uchun 2 ta yozuv, jami 6 ta):
--    1) "Reset"    — kassaning O'ZI va BARCHA bola-hisoblari (naqd/click/
--                    payme/USD va boshqa valyutalar) qoldig'ini 0 ga tushiradi.
--                       Dt Boshlang'ich kapital / Kt <hisob>   (qoldiq musbat bo'lsa)
--    2) "Ochilish" — yangi qoldiqni kiritadi:
--                       Dt <hisob> / Kt Boshlang'ich kapital
--
--  NEGA 9010 (savdo tushumi) EMAS: bu pul TUSHUM emas, u allaqachon
--  ishlab topilgan. Kt tomoniga 9010 yozilsa o'sha kunning P&L'i shishadi.
--  Kapitalga yozilganda balansda AKTIV va KAPITAL birga o'zgaradi,
--  P&L'ga umuman tegmaydi. (Ayni mantiq — PROVODKA_KAPITAL.sql.)
--
--  ⚠️⚠️ RAQAMLARNI TEKSHIRING — ayniqsa Toshkent USD = 405 245.
--       Bu joriy kursda ~5 MLRD so'm, ya'ni naqd (181,5 mln) dan ~28 barobar
--       katta. Qashqadaryoda esa atigi 8 270 $. Agar 405 245 xato bo'lsa
--       (masalan 4 052,45 yoki 40 524 bo'lishi kerak bo'lsa) — 1-BO'LIMdagi
--       `boshlangich_qoldiq_reja` jadvalidagi qiymatni tuzating va 3-BO'LIM
--       oldindan ko'rish natijasida so'm ekvivalentini ko'zdan kechiring.
--
--  ⚠️ ABRORXO'JA — HODIM KASSASI. Hodim kassalarida (5401+) naqd/payme/USD
--     bola-hisoblari YO'Q: PROVODKA_VALYUTA_SEED.sql ularni ataylab chetlab
--     o'tgan (u faqat mustaqil kassalarga — parent_id IS NULL — ochadi).
--     Shuning uchun 2-BO'LIM yetishmayotgan bola-hisoblarni ochadi.
--     Tekshirildi, hech narsani buzmaydi:
--       • v_kassa_card — `p.pul_turi is null` sharti bor, tur bolalari
--         alohida karta bo'lib chiqmaydi; `jami` esa ularni qo'shib hisoblaydi.
--       • USD bolasi `p.currency='UZS'` sharti bilan kartadan chiqib ketadi;
--         5400 guruh qatoriga ta'sir qilmaydi (u USD bola olmayapti).
--       • kassa_root() -> perm_op_key(): `pul_turi is not null` -> parent.
--         Ya'ni ruxsat hodim kassasidan meros bo'ladi, qayta sozlash shart emas.
--       • v_filial_tanlov `pul_turi is null and currency='UZS'` bilan filtrlaydi
--         — yangi bolalar filial ro'yxatiga tushmaydi.
--
--  TALAB:
--    • PROVODKA_KAPITAL.sql RUN qilingan  -> boshlangich_kapital_id()
--    • PROVODKA_VALYUTA.sql RUN qilingan  -> pul_turi, pul_turi_kod_blok
--    • PROVODKA_VALYUTA_SEED.sql RUN qilingan (5011/5012 bolalari uchun)
--    • conv_baza_kurs('USD') null qaytarmasin (Valyuta bo'limida kurs bo'lsin)
--
--  TARTIB:
--    1-BO'LIM RUN  -> reja jadvali; Abrorxo'ja kodi qidiruv bilan topiladi
--    2-BO'LIM RUN  -> yetishmayotgan bola-hisoblar ochiladi (PUL YOZMAYDI)
--    3-BO'LIM RUN  -> FAQAT O'QIYDI. Hozirgi / yangi / farq. Ko'zdan kechiring.
--    4-BO'LIM      -> `p_tasdiq := true` qiling va RUN qiling (yozadi)
--    5-BO'LIM RUN  -> tekshiruv
--
--  ⚠️ RUN QILISHDAN OLDIN: n8n "Aros Provodka - Auto Sync" (7MSHrXnz9cGAFBTh)
--     ni DEACTIVATE qiling. U har 30 daqiqada Aros balansi bilan farqni
--     yozadi — reset va ochilish o'rtasida tushib qolsa aralashib ketadi.
--     Ish tugagach qaytarib yoqing.
--
--  ⚠️ Auto Sync yoqilgach NIMA BO'LADI: sync Aros'dagi balans bilan
--     daftardagini solishtiradi. Yangi qoldiq Aros'dagi haqiqiy raqamga
--     mos bo'lsa — sync hech narsa yozmaydi. Mos bo'lmasa farqni tushum
--     qilib yozadi. Ya'ni 5011/5012 raqamlari Aros'dagi bilan bir xil
--     bo'lishi kerak. (Hodim kassasi Aros bilan sinxronlanmaydi.)
--
--  QAYTARISH (rollback): 6-BO'LIMga qarang.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1-BO'LIM. REJA JADVALI — qaysi hisobga qancha
-- ---------------------------------------------------------------------
-- Alohida jadval, chunki 2/3/4/5-bo'limlar AYNI raqamlarni ko'rishi shart.
-- Ikki joyda qo'lda takrorlansa — bir joyini tuzatib, ikkinchisini unutish
-- xavfi bor. Jadval yozuvdan keyin ham qoladi: nima kiritilgani hujjatlashadi.

create table if not exists boshlangich_qoldiq_reja (
  kassa_code text    not null,
  turi       text    not null check (turi in ('naqd','click','payme','USD')),
  miqdor     numeric not null default 0 check (miqdor >= 0),
  izoh       text,
  primary key (kassa_code, turi)
);

comment on table boshlangich_qoldiq_reja is
  'Boshlang''ich qoldiq rejasi (PROVODKA_BOSHLANGICH_QOLDIQ.sql). '
  'miqdor — hisobning O''Z valyutasida: naqd/click/payme = so''m, USD = dollar. '
  'Kiritilmagan tur 0 deb hisoblanadi.';

revoke all on boshlangich_qoldiq_reja from public, anon;
-- RLS yoqilgan, policy YO'Q -> anon/authenticated umuman o'qiy olmaydi.
-- Jadval faqat SQL editor (postgres) uchun; PostgREST orqali ochilmasin.
alter table boshlangich_qoldiq_reja enable row level security;


-- 1.1 QIDIRUV YORDAMCHISI — Abrorxo'ja qaysi kassa ekanini ko'rish uchun.
--     1.2 xato bersa shu ro'yxatdan aniq kodni toping va 1.2 dagi
--     `p_kod` o'zgaruvchisiga qo'lda yozing.
select a.code, a.name, a.subtitle, a.kassa_turi, a.is_active,
       p.code as parent_code, p.name as parent_nom
  from accounts a
  left join accounts p on p.id = a.parent_id
 where a.section = 'pul'
   and (lower(a.name) like '%abror%' or lower(a.name) like '%axmad%'
        or lower(a.name) like '%ahmad%')
 order by a.code;


-- ⚙️⚙️ RAQAMLAR SHU YERDA. miqdor hisobning O'Z valyutasida:
--      naqd/click/payme -> so'm,   USD -> dollar.
--      0 = o'sha hisob bo'sh qoladi (reset qilingandan keyin tegilmaydi).
insert into boshlangich_qoldiq_reja (kassa_code, turi, miqdor, izoh) values
  ('5011', 'naqd',  181502000, 'Toshkent kassa · naqd (so''m)'),
  ('5011', 'click',         0, 'Toshkent kassa · click — berilmagan, 0'),
  ('5011', 'payme',   8815000, 'Toshkent kassa · payme (so''m)'),
  ('5011', 'USD',      405245, 'Toshkent kassa · dollar ⚠️ TEKSHIRING'),
  ('5012', 'naqd',  294914000, 'Qashqadaryo kassa · naqd (so''m)'),
  ('5012', 'click',         0, 'Qashqadaryo kassa · click — berilmagan, 0'),
  ('5012', 'payme',         0, 'Qashqadaryo kassa · payme — berilmagan, 0'),
  ('5012', 'USD',        8270, 'Qashqadaryo kassa · dollar')
on conflict (kassa_code, turi) do update
   set miqdor = excluded.miqdor,
       izoh   = excluded.izoh;


-- 1.2 ABRORXO'JA — kodi noma'lum, shuning uchun NOM bo'yicha topiladi.
--     Aniq bitta kassa topilmasa xato beradi (jimgina noto'g'ri hisobga
--     yozib yubormasin).
do $abr$
declare
  -- ⚙️ Qidiruv. `p_kod` to'ldirilsa qidiruv o'tkazib yuboriladi.
  p_qidiruv text := 'abrorxo';   -- nomning ajralib turadigan qismi (kichik harf)
  p_kod     text := null;        -- masalan '5423' — 1.1 ro'yxatidan olinadi

  -- ⚙️⚙️ RAQAMLAR
  p_naqd  numeric := 324041000;
  p_click numeric := 0;
  p_payme numeric := 664128000;
  p_usd   numeric := 22065;

  v_kod   text;
  v_nom   text;
  v_soni  int;
begin
  if p_kod is not null then
    select code, name into v_kod, v_nom
      from accounts
     where code = p_kod and section = 'pul';
    if v_kod is null then
      raise exception 'p_kod = % — bunday pul hisobi yo''q (1.1 ro''yxatiga qarang)', p_kod;
    end if;
  else
    -- ⚠️ Bola-hisoblar (… · Naqd / … · USD) qidiruvdan CHIQARILADI: aks holda
    --    2-BO'LIM ularni ochgandan keyin bu blokni qayta RUN qilsa "4 ta
    --    kassa topildi" deb xato berardi. Kassaning O'ZIDA pul_turi NULL
    --    va currency UZS bo'ladi.
    select count(*) into v_soni
      from accounts
     where section = 'pul' and is_active
       and pul_turi is null and coalesce(currency,'UZS') = 'UZS'
       and lower(name) like '%' || p_qidiruv || '%';

    if v_soni = 0 then
      raise exception E'"%" bo''yicha kassa topilmadi.\n'
        '1.1 so''rovini RUN qilib aniq kodni toping va shu blokdagi '
        '`p_kod` o''zgaruvchisiga yozing.', p_qidiruv;
    end if;
    if v_soni > 1 then
      raise exception E'"%" bo''yicha % ta kassa topildi — qaysi biri ekani noaniq.\n'
        '1.1 so''rovidan aniq kodni olib `p_kod` ga yozing.', p_qidiruv, v_soni;
    end if;

    select code, name into v_kod, v_nom
      from accounts
     where section = 'pul' and is_active
       and pul_turi is null and coalesce(currency,'UZS') = 'UZS'
       and lower(name) like '%' || p_qidiruv || '%';
  end if;

  raise notice 'Abrorxo''ja kassasi: % — %', v_kod, v_nom;

  insert into boshlangich_qoldiq_reja (kassa_code, turi, miqdor, izoh) values
    (v_kod, 'naqd',  p_naqd,  v_nom || ' · naqd (so''m)'),
    (v_kod, 'click', p_click, v_nom || ' · click — berilmagan, 0'),
    (v_kod, 'payme', p_payme, v_nom || ' · payme (so''m)'),
    (v_kod, 'USD',   p_usd,   v_nom || ' · dollar')
  on conflict (kassa_code, turi) do update
     set miqdor = excluded.miqdor,
         izoh   = excluded.izoh;
end
$abr$;

-- 1.3 Reja to'liq ko'rinishi (uchala kassa shu yerda bo'lishi kerak)
select r.kassa_code, a.name as kassa_nom, r.turi, r.miqdor, r.izoh
  from boshlangich_qoldiq_reja r
  left join accounts a on a.code = r.kassa_code and a.section = 'pul'
 order by r.kassa_code, r.turi;

-- Raqam o'zgarsa: yuqoridagi qiymatni tuzatib, o'sha insert'ni (yoki 1.2
-- blokini) qayta RUN qiling — on conflict tufayli yangilanadi.


-- ---------------------------------------------------------------------
-- 2-BO'LIM. YETISHMAYOTGAN BOLA-HISOBLARNI OCHISH — PUL YOZMAYDI
-- ---------------------------------------------------------------------
-- Rejada nolmas qiymati bor, lekin hisobi yo'q turlar uchun bola-hisob
-- ochadi. Amalda bu faqat Abrorxo'ja (hodim kassasi) uchun ishlaydi —
-- 5011/5012 da bolalar allaqachon bor.
--
-- Kod ajratish mantig'i PROVODKA_VALYUTA_SEED.sql dan AYNAN ko'chirilgan:
-- som turlari `pul_turi_kod_blok`, USD `valyuta_kod_blok` prefiksidan.
-- create_pul_turi_child()/create_valyuta_child() CHAQIRILMAYDI — ular
-- auth.uid() orqali adminlikni tekshiradi, SQL editorda esa u NULL.
--
-- IDEMPOTENT: bor bo'lgan bola qayta ochilmaydi. Qayta RUN xavfsiz.

do $och$
declare
  r          record;
  v_kassa    uuid;
  v_nom      text;
  v_turi     text;
  v_prefix   text;
  v_next     int;
  v_code     text;
  v_lbl      text;
  v_usd_pref text;
  n_yangi    int := 0;
  n_bor      int := 0;
begin
  for r in
    select p.kassa_code, p.turi
      from boshlangich_qoldiq_reja p
     where p.miqdor <> 0
     order by p.kassa_code, p.turi
  loop
    select a.id, a.name, a.kassa_turi
      into v_kassa, v_nom, v_turi
      from accounts a
     where a.code = r.kassa_code and a.section = 'pul';

    if v_kassa is null then
      raise exception 'Kassa topilmadi: % (1.3 rejasini tekshiring)', r.kassa_code;
    end if;

    -- Bor bo'lsa tegmaymiz
    if r.turi = 'USD' then
      if exists (select 1 from accounts c
                  where c.parent_id = v_kassa and c.is_active
                    and coalesce(c.currency,'UZS') = 'USD') then
        n_bor := n_bor + 1;
        continue;
      end if;

      select prefix into v_usd_pref from valyuta_kod_blok where currency = 'USD';
      if v_usd_pref is null then
        raise exception 'valyuta_kod_blok''da USD prefiksi yo''q — PROVODKA_KASSA2.sql RUN qilinganmi?';
      end if;

      select coalesce(max(substring(a.code from 3 for 2)::int), 0) + 1
        into v_next
        from accounts a
       where a.code ~ ('^' || v_usd_pref || '[0-9]{2}$');
      if v_next > 99 then
        raise exception 'USD kod bloki (%xx) to''ldi — kodni qo''lda tanlang', v_usd_pref;
      end if;
      v_code := v_usd_pref || lpad(v_next::text, 2, '0');

      insert into accounts(code, name, type, section, currency, parent_id,
                           kassa_turi, is_active, subtitle)
      values (v_code, v_nom || ' · USD', 'aktiv', 'pul', 'USD', v_kassa,
              v_turi, true, (select subtitle from accounts where id = v_kassa));

    else
      if exists (select 1 from accounts c
                  where c.parent_id = v_kassa and c.is_active
                    and c.pul_turi = r.turi
                    and coalesce(c.currency,'UZS') = 'UZS') then
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
        raise exception 'Tur kod bloklari to''ldi (% kassada to''xtadi). '
                        'pul_turi_kod_blok''ga yangi prefiks qo''shing.', r.kassa_code;
      end if;

      v_code := v_prefix || lpad(v_next::text, 2, '0');
      v_lbl  := case r.turi when 'naqd' then 'Naqd'
                            when 'click' then 'Click' else 'Payme' end;

      insert into accounts(code, name, type, section, currency, parent_id,
                           kassa_turi, is_active, subtitle, pul_turi)
      values (v_code, v_nom || ' · ' || v_lbl, 'aktiv', 'pul', 'UZS', v_kassa,
              v_turi, true, (select subtitle from accounts where id = v_kassa), r.turi);
    end if;

    n_yangi := n_yangi + 1;
    raise notice 'OCHILDI: %  %  (% · %)', v_code, v_nom, r.kassa_code, r.turi;
  end loop;

  raise notice '--- % ta yangi bola-hisob ochildi | % tasi allaqachon bor edi',
    n_yangi, n_bor;
end
$och$;

-- 2.1 Yangi hisoblarda PUL YO'Q ekaniga ishonch (0 bo'lishi SHART)
select coalesce(sum(l.debit - l.credit), 0) as yangi_hisoblardagi_pul_nol_bolishi_kerak
  from accounts a
  join accounts k on k.id = a.parent_id
  left join entry_line l on l.account_id = a.id
  left join entry e on e.id = l.entry_id and e.status = 'posted' and e.is_deleted = false
 where k.code in (select distinct kassa_code from boshlangich_qoldiq_reja)
   and (a.pul_turi is not null or coalesce(a.currency,'UZS') <> 'UZS');

-- 2.2 Kartalar buzilmadimi — har kassa BITTA qator (bo'sh chiqishi SHART)
select id, count(*) as nechta_qator
  from v_kassa_card
 group by id
having count(*) > 1;


-- ---------------------------------------------------------------------
-- 3-BO'LIM. OLDINDAN KO'RISH — FAQAT O'QIYDI, hech narsa yozmaydi
-- ---------------------------------------------------------------------

-- 3.1 ⬅️ ASOSIY: hozirgi qoldiq / yangi qoldiq / farq.
--     `hozir_uzs`/`hozir_valyuta` — daftardagi haqiqiy qoldiq (posted, o'chirilmagan).
--     `yangi_uzs` — USD uchun joriy kursda hisoblangan so'm ekvivalenti.
with kassa as (
  select k.id, k.code, k.name
    from accounts k
   where k.code in (select distinct kassa_code from boshlangich_qoldiq_reja)
     and k.section = 'pul'
),
hisob as (
  -- kassaning o'zi + barcha bola-hisoblari (faol bo'lmaganlari ham —
  -- ularda ham qoldiq turgan bo'lishi mumkin)
  select k.code as kassa_code, k.name as kassa_nom,
         a.id, a.code, a.name, a.pul_turi, coalesce(a.currency,'UZS') as currency,
         a.is_active, (a.id = k.id) as kassaning_ozi
    from kassa k
    join accounts a on a.id = k.id or a.parent_id = k.id
),
bal as (
  select h.*,
         coalesce((select sum(l.debit - l.credit)
                     from entry_line l join entry e on e.id = l.entry_id
                    where l.account_id = h.id
                      and e.status = 'posted' and e.is_deleted = false), 0) as hozir_uzs,
         coalesce((select sum(case when l.debit > 0 then coalesce(l.fc_amount,0)
                                   else -coalesce(l.fc_amount,0) end)
                     from entry_line l join entry e on e.id = l.entry_id
                    where l.account_id = h.id
                      and e.status = 'posted' and e.is_deleted = false), 0) as hozir_fc
    from hisob h
)
select b.kassa_code, b.kassa_nom, b.code, b.name,
       coalesce(b.pul_turi, b.currency) as turi,
       b.is_active,
       b.hozir_uzs,
       nullif(b.hozir_fc, 0)            as hozir_valyuta,
       r.miqdor                         as yangi_miqdor,
       case when b.currency <> 'UZS'
            then round(coalesce(r.miqdor,0) * coalesce(conv_baza_kurs(b.currency), 0), 2)
            else coalesce(r.miqdor, 0)
       end                              as yangi_uzs,
       case when b.currency <> 'UZS' then conv_baza_kurs(b.currency) end as kurs,
       case
         when b.kassaning_ozi and b.hozir_uzs <> 0
              then '⚠️ kassaning O''ZIDA pul bor — 0 ga tushadi'
         when b.kassaning_ozi then 'konteyner (0 bo''lib qoladi)'
         when r.miqdor is null  then '⚠️ rejada yo''q — 0 bo''lib qoladi'
         when r.miqdor = 0      then '0 bo''lib qoladi'
         else 'yangi qoldiq yoziladi'
       end                              as holat
  from bal b
  left join boshlangich_qoldiq_reja r
         on r.kassa_code = b.kassa_code
        and r.turi = case when b.currency <> 'UZS' then b.currency else b.pul_turi end
 order by b.kassa_code, b.kassaning_ozi desc, b.code;

-- 3.2 ⚠️ TO'SIQ TEKSHIRUVI: so'm va valyuta qoldig'ining ISHORASI mos kelmayotgan
--     hisob bormi. Bunday hisobni bitta satr bilan 0 ga tushirib bo'lmaydi
--     (satrda debit yoki credit bittasi > 0, fc_amount esa musbat).
--     BO'SH chiqishi SHART — bo'sh bo'lmasa 4-bo'lim xato beradi va menga ayting.
with hisob as (
  select a.id, a.code, a.name
    from accounts k
    join accounts a on a.id = k.id or a.parent_id = k.id
   where k.code in (select distinct kassa_code from boshlangich_qoldiq_reja)
     and k.section = 'pul'
)
select h.code, h.name, b.uzs, b.fc,
       'so''m va valyuta ishorasi mos emas' as muammo
  from hisob h
  join lateral (
    select coalesce(sum(l.debit - l.credit), 0) as uzs,
           coalesce(sum(case when l.debit > 0 then coalesce(l.fc_amount,0)
                             else -coalesce(l.fc_amount,0) end), 0) as fc
      from entry_line l join entry e on e.id = l.entry_id
     where l.account_id = h.id and e.status = 'posted' and e.is_deleted = false
  ) b on true
 where b.fc <> 0
   and (b.uzs = 0 or sign(b.uzs) <> sign(b.fc));

-- 3.3 Kartada hozir qanday ko'rinadi (yozuvdan keyin taqqoslash uchun saqlang)
select code, name, kassa_turi, uzs, naqd, click, payme, usd, usd_uzs, jami
  from v_kassa_card
 where code in (select distinct kassa_code from boshlangich_qoldiq_reja)
 order by code;

-- 3.4 Kerakli hisoblar joyidami. `❌ topilmadi` chiqmasligi SHART
--     (2-bo'lim ularni ochgan bo'lishi kerak).
select r.kassa_code, r.turi, r.miqdor,
       coalesce(a.code, '❌ topilmadi') as hisob_code, a.name as hisob_nom
  from boshlangich_qoldiq_reja r
  join accounts k on k.code = r.kassa_code and k.section = 'pul'
  left join accounts a
         on a.parent_id = k.id and a.is_active
        and (case when r.turi = 'USD' then coalesce(a.currency,'UZS') = 'USD'
                  else a.pul_turi = r.turi and coalesce(a.currency,'UZS') = 'UZS' end)
 where r.miqdor <> 0
 order by r.kassa_code, r.turi;

-- 3.5 Kapital hisobi va USD kursi bormi
select boshlangich_kapital_id()  as kapital_id,
       (select code from accounts where id = boshlangich_kapital_id()) as kapital_code,
       conv_baza_kurs('USD')     as usd_kurs;

-- 3.6 Jami kiritiladigan summa (so'mda) — kapital shunga o'sadi
select r.kassa_code, a.name as kassa_nom,
       sum(case when r.turi = 'USD'
                then round(r.miqdor * conv_baza_kurs('USD'), 2)
                else r.miqdor end) as jami_uzs
  from boshlangich_qoldiq_reja r
  join accounts a on a.code = r.kassa_code and a.section = 'pul'
 group by r.kassa_code, a.name
 order by r.kassa_code;


-- ---------------------------------------------------------------------
-- 4-BO'LIM. YOZISH
-- ---------------------------------------------------------------------
-- ⚙️ `p_tasdiq := true` QILMAGUNCHA hech narsa yozilmaydi — blok xato berib
--    to'xtaydi. Bu 3-bo'limni ko'rmasdan tasodifan RUN qilishdan saqlaydi.
-- Butun blok BITTA tranzaksiya: biror joyda xato bo'lsa hammasi orqaga qaytadi
-- (yarim yozilgan holat bo'lmaydi).

do $bq$
declare
  -- ⚙️ SOZLAMALAR ------------------------------------------------------
  p_tasdiq boolean := false;         -- ⬅️ YOZISH UCHUN true QILING
  p_kurs   numeric := null;          -- USD kursi; null = conv_baza_kurs('USD')
  p_sana   date    := current_date;  -- boshlang'ich qoldiq sanasi
  -- --------------------------------------------------------------------

  v_kapital  uuid;
  v_kurs     numeric;
  v_usd_bor  boolean;

  r_kassa    record;
  r_hisob    record;
  r_reja     record;

  v_entry    uuid;
  v_acc      uuid;
  v_acc_code text;
  v_uzs      numeric;
  v_fc       numeric;
  v_jami     numeric;
  v_line_uzs numeric;
  v_line_fc  numeric;
  v_dt       numeric;
  v_kt       numeric;

  n_reset    int := 0;   -- nolga tushirilgan hisoblar
  n_ochilish int := 0;   -- yangi qoldiq yozilgan hisoblar
  n_entry    int := 0;
begin
  if not p_tasdiq then
    raise exception E'TO''XTADI — hech narsa yozilmadi.\n'
      '3-BO''LIMni RUN qilib natijani ko''ring (ayniqsa 3.1, 3.2 va 3.4), '
      'keyin shu blokdagi `p_tasdiq := false` ni `true` qiling.';
  end if;

  -- Ikki marta yozib yuborilmasin (ext_ref bilan belgilaymiz)
  if exists (select 1 from entry where ext_ref like 'bq:%') then
    raise exception E'TO''XTADI: `bq:%%` belgili yozuvlar allaqachon bor — '
      E'bu skript avval RUN qilingan.\n'
      'Qayta yozish kerak bo''lsa avval 6-BO''LIMdagi rollback''ni bajaring.';
  end if;

  -- ---- Kapital hisobi ------------------------------------------------
  v_kapital := boshlangich_kapital_id();
  if v_kapital is null then
    raise exception 'Boshlang''ich kapital hisobi topilmadi — PROVODKA_KAPITAL.sql RUN qilinganmi?';
  end if;

  -- ---- USD kursi (faqat USD rejasi bo'lsa kerak) ---------------------
  select exists (select 1 from boshlangich_qoldiq_reja where turi = 'USD' and miqdor <> 0)
    into v_usd_bor;

  v_kurs := p_kurs;
  if v_kurs is null and to_regprocedure('public.conv_baza_kurs(text)') is not null then
    begin
      execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
    exception when others then v_kurs := null;
    end;
  end if;
  if v_usd_bor and (v_kurs is null or v_kurs <= 0) then
    raise exception 'USD kursi topilmadi (conv_baza_kurs(''USD'') = %). '
                    'Valyuta bo''limida kursni import qiling yoki `p_kurs` ni qo''lda yozing.',
                    v_kurs;
  end if;
  raise notice 'Kapital hisob: % | USD kursi: %',
    (select code from accounts where id = v_kapital), v_kurs;

  -- ---- Kassalar bo'yicha aylanish ------------------------------------
  for r_kassa in
    select k.id, k.code, k.name
      from accounts k
     where k.code in (select distinct kassa_code from boshlangich_qoldiq_reja)
       and k.section = 'pul'
     order by k.code
  loop
    raise notice '=== % — %', r_kassa.code, r_kassa.name;

    -- ================================================================
    -- 4.1 RESET — kassa va uning barcha bola-hisoblarini 0 ga tushirish
    -- ================================================================
    -- is_active bo'yicha FILTRLAMAYDI: faol bo'lmagan bola-hisobda ham
    -- qoldiq turgan bo'lishi mumkin, u ham 0 ga tushishi kerak.
    v_entry := null;
    v_jami  := 0;

    for r_hisob in
      select a.id, a.code, a.name
        from accounts a
       where a.id = r_kassa.id or a.parent_id = r_kassa.id
       order by a.code
    loop
      select coalesce(sum(l.debit - l.credit), 0),
             coalesce(sum(case when l.debit > 0 then coalesce(l.fc_amount, 0)
                               else -coalesce(l.fc_amount, 0) end), 0)
        into v_uzs, v_fc
        from entry_line l
        join entry e on e.id = l.entry_id
       where l.account_id = r_hisob.id
         and e.status = 'posted' and e.is_deleted = false;

      if v_uzs = 0 and v_fc = 0 then
        continue;                                   -- allaqachon bo'sh
      end if;

      -- Bitta teskari satr bilan so'm ham, valyuta ham 0 ga tushishi uchun
      -- ikkovining ishorasi bir xil bo'lishi shart (3.2 tekshiruvi).
      if v_fc <> 0 and (v_uzs = 0 or sign(v_uzs) <> sign(v_fc)) then
        raise exception '% (%) — so''m qoldig''i % , valyuta qoldig''i % : '
          E'ishoralar mos emas, bitta satr bilan 0 ga tushirib bo''lmaydi.\n'
          'Bu holatni qo''lda hal qilish kerak — 3.2 so''rovi natijasini yuboring.',
          r_hisob.code, r_hisob.name, v_uzs, v_fc;
      end if;

      if v_entry is null then
        insert into entry(entry_date, description, source, status, created_by, ext_ref)
        values (p_sana,
                'Boshlang''ich qoldiq: ' || r_kassa.name || ' — eski qoldiq nolga tushirildi',
                'manual', 'posted', 'boshlangich_qoldiq',
                'bq:' || r_kassa.code || ':reset')
        returning id into v_entry;
        n_entry := n_entry + 1;
      end if;

      -- Qoldiq musbat (Dt) bo'lsa -> Kt qilamiz; manfiy bo'lsa -> Dt.
      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, r_hisob.id,
              case when v_uzs < 0 then -v_uzs else 0 end,
              case when v_uzs > 0 then  v_uzs else 0 end,
              nullif(abs(v_fc), 0));

      v_jami  := v_jami + v_uzs;
      n_reset := n_reset + 1;
      raise notice '  reset  %  uzs=%  fc=%', r_hisob.code, v_uzs, v_fc;
    end loop;

    -- Muvozanat satri: kapital. v_jami = 0 bo'lsa (hisoblar bir-birini
    -- yopgan) satr kerak emas — Dt=Kt baribir saqlanadi.
    if v_entry is not null and v_jami <> 0 then
      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, v_kapital,
              case when v_jami > 0 then  v_jami else 0 end,
              case when v_jami < 0 then -v_jami else 0 end,
              null);
    end if;

    if v_entry is null then
      raise notice '  (qoldiq yo''q edi — reset yozuvi kerak bo''lmadi)';
    else
      -- Dt=Kt o'zimiz tekshiramiz: check_entry_balanced deferred, u faqat
      -- COMMIT paytida ishlaydi va o'sha yerdagi xato tushunarsiz bo'ladi.
      select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
        into v_dt, v_kt from entry_line where entry_id = v_entry;
      if v_dt <> v_kt then
        raise exception 'RESET yozuvi muvozanatda emas: Dt=% Kt=% (%)', v_dt, v_kt, r_kassa.code;
      end if;
    end if;

    -- ================================================================
    -- 4.2 OCHILISH — yangi qoldiqni kapitaldan kiritish
    -- ================================================================
    v_entry := null;
    v_jami  := 0;

    for r_reja in
      select turi, miqdor
        from boshlangich_qoldiq_reja
       where kassa_code = r_kassa.code and miqdor <> 0
       order by turi
    loop
      -- Nishon hisobni topamiz
      if r_reja.turi = 'USD' then
        select a.id, a.code into v_acc, v_acc_code
          from accounts a
         where a.parent_id = r_kassa.id and a.is_active
           and coalesce(a.currency, 'UZS') = 'USD'
         order by a.code
         limit 1;
        v_line_uzs := round(r_reja.miqdor * v_kurs, 2);
        v_line_fc  := r_reja.miqdor;
      else
        select a.id, a.code into v_acc, v_acc_code
          from accounts a
         where a.parent_id = r_kassa.id and a.is_active
           and a.pul_turi = r_reja.turi
           and coalesce(a.currency, 'UZS') = 'UZS'
         order by a.code
         limit 1;
        v_line_uzs := r_reja.miqdor;
        v_line_fc  := null;
      end if;

      if v_acc is null then
        raise exception '% kassasida "%" hisobi topilmadi — '
                        '2-BO''LIM RUN qilinganmi? (3.4 so''rovi)',
                        r_kassa.code, r_reja.turi;
      end if;
      if v_line_uzs <= 0 then
        raise exception '% · % — so''m summasi % bo''lib chiqdi (kurs %?)',
                        r_kassa.code, r_reja.turi, v_line_uzs, v_kurs;
      end if;

      if v_entry is null then
        insert into entry(entry_date, description, source, status,
                          created_by, ext_ref, fc_rate)
        values (p_sana,
                'Boshlang''ich kapital: ' || r_kassa.name,
                'manual', 'posted', 'boshlangich_qoldiq',
                'bq:' || r_kassa.code || ':ochilish',
                case when v_usd_bor then v_kurs end)
        returning id into v_entry;
        n_entry := n_entry + 1;
      end if;

      -- Dt: pul hisobi (aktiv o'sadi). fc_amount FAQAT valyuta satriga.
      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, v_acc, v_line_uzs, 0, v_line_fc);

      v_jami     := v_jami + v_line_uzs;
      n_ochilish := n_ochilish + 1;
      raise notice '  kirim  %  (%)  uzs=%  fc=%',
        v_acc_code, r_reja.turi, v_line_uzs, coalesce(v_line_fc, 0);
    end loop;

    -- Kt: boshlang'ich kapital (butun summa bitta satrda)
    if v_entry is not null then
      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, v_kapital, 0, v_jami, null);

      select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
        into v_dt, v_kt from entry_line where entry_id = v_entry;
      if v_dt <> v_kt then
        raise exception 'OCHILISH yozuvi muvozanatda emas: Dt=% Kt=% (%)', v_dt, v_kt, r_kassa.code;
      end if;
      raise notice '  jami kirim: % so''m', v_jami;
    else
      raise notice '  (rejada nolmas qiymat yo''q — ochilish yozuvi kerak bo''lmadi)';
    end if;
  end loop;

  if n_entry = 0 then
    raise exception 'TO''XTADI: birorta yozuv yaratilmadi — kutilmagan holat. '
                    '3.4 so''rovini tekshiring (kassalar topildimi).';
  end if;

  raise notice '--- TUGADI: % ta yozuv | % hisob nolga tushdi | % hisobga qoldiq kiritildi',
    n_entry, n_reset, n_ochilish;
end
$bq$;


-- ---------------------------------------------------------------------
-- 5-BO'LIM. TEKSHIRUV
-- ---------------------------------------------------------------------

-- 5.1 ⬅️ ASOSIY: yangi qoldiq rejaga MOS keldimi (farq 0 bo'lishi SHART)
with hisob as (
  select k.code as kassa_code, a.id, a.code, a.name,
         coalesce(a.currency,'UZS') as currency, a.pul_turi
    from accounts k
    join accounts a on a.id = k.id or a.parent_id = k.id
   where k.code in (select distinct kassa_code from boshlangich_qoldiq_reja)
     and k.section = 'pul'
)
select h.kassa_code, h.code, h.name,
       coalesce(h.pul_turi, h.currency) as turi,
       b.uzs, nullif(b.fc, 0) as valyuta,
       r.miqdor as reja,
       case
         when h.currency <> 'UZS' then b.fc - coalesce(r.miqdor, 0)
         else b.uzs - coalesce(r.miqdor, 0)
       end as farq
  from hisob h
  join lateral (
    select coalesce(sum(l.debit - l.credit), 0) as uzs,
           coalesce(sum(case when l.debit > 0 then coalesce(l.fc_amount,0)
                             else -coalesce(l.fc_amount,0) end), 0) as fc
      from entry_line l join entry e on e.id = l.entry_id
     where l.account_id = h.id and e.status = 'posted' and e.is_deleted = false
  ) b on true
  left join boshlangich_qoldiq_reja r
         on r.kassa_code = h.kassa_code
        and r.turi = case when h.currency <> 'UZS' then h.currency else h.pul_turi end
 order by h.kassa_code, h.code;

-- 5.2 Kartada qanday ko'rinadi (3.3 bilan solishtiring)
select code, name, kassa_turi, uzs, naqd, click, payme, usd, usd_uzs, jami
  from v_kassa_card
 where code in (select distinct kassa_code from boshlangich_qoldiq_reja)
 order by code;

-- 5.3 Yaratilgan yozuvlar (6 ta bo'lishi kutiladi)
select e.ext_ref, e.entry_date, e.description, e.fc_rate,
       count(l.id) as satrlar,
       sum(l.debit) as dt, sum(l.credit) as kt,
       sum(l.debit) - sum(l.credit) as farq_nol_bolishi_kerak
  from entry e
  join entry_line l on l.entry_id = e.id
 where e.ext_ref like 'bq:%'
 group by e.id, e.ext_ref, e.entry_date, e.description, e.fc_rate
 order by e.ext_ref;

-- 5.4 Balans tenglikda (farq = 0 bo'lishi SHART)
select sum(case when bolim = 'AKTIV' then amount else 0 end)
     - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end) as farq
  from balans(current_date);

-- 5.5 P&L'ga tegmadimi — bizning yozuvlarda daromad/xarajat hisobi
--     BO'LMASLIGI kerak (bo'sh chiqadi)
select e.ext_ref, e.description, a.code, a.name, a.type
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a   on a.id = l.account_id
 where e.ext_ref like 'bq:%'
   and a.type in ('daromad', 'xarajat');

-- 5.6 Boshlang'ich kapital hisobining yangi qoldig'i
select bolim, code, name, amount
  from balans(current_date)
 where code = (select code from accounts where id = boshlangich_kapital_id());

-- 5.7 Kartalar buzilmadimi — har kassa BITTA qator (bo'sh chiqishi SHART)
select id, count(*) as nechta_qator
  from v_kassa_card
 group by id
having count(*) > 1;


-- ---------------------------------------------------------------------
-- 6-BO'LIM. ROLLBACK — noto'g'ri raqam yozilib qolsa
-- ---------------------------------------------------------------------
-- Yozuvlar `ext_ref` = 'bq:...' bilan belgilangan, shuning uchun aniq
-- topiladi. IKKI yo'l bor:
--
-- A) YUMSHOQ (tavsiya etiladi) — jurnalda usti chizilgan holda qoladi,
--    tarix saqlanadi. Kassa qoldiqlari darrov 0 ga qaytadi.
--
--    update entry set is_deleted = true,
--                     deleted_at = now(),
--                     deleted_by_name = 'rollback: boshlangich qoldiq'
--     where ext_ref like 'bq:%';
--
--    ⚠️ Shundan keyin 4-BO'LIMni qayta RUN qilib bo'lmaydi: ext_ref unique
--       to'sig'i bor. Qayta yozish uchun avval ext_ref'ni bo'shating:
--         update entry set ext_ref = ext_ref || ':bekor:' || id::text
--          where ext_ref like 'bq:%' and is_deleted;
--
-- B) QATTIQ — butunlay o'chirish, izsiz. Faqat xato darrov sezilsa.
--
--    delete from entry_line where entry_id in (select id from entry where ext_ref like 'bq:%');
--    delete from entry where ext_ref like 'bq:%';
--
--    ⚠️ entry_line BITTA statement bilan o'chiriladi — deferred balans
--       triggeri COMMIT paytida 0=0 ko'radi va to'smaydi.
--
-- Ikkalasidan keyin ham 3.3 dagi eski qoldiqlar QAYTMAYDI — reset yozuvi
-- ham bekor bo'lgani uchun kassa yozuvdan OLDINGI holatiga qaytadi.
--
-- 2-BO'LIMda ochilgan bola-hisoblar rollbackda TEGILMAYDI (ular bo'sh
-- hisob, zarari yo'q). Kerak bo'lsa qo'lda: update accounts set is_active=false.
