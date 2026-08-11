-- =====================================================================
--  PROVODKA_BOSHLANGICH_QOLDIQ.sql
--  UCHTA kassani NOLGA tushirib, boshlang'ich kapital sifatida yangi
--  qoldiq kiritish:
--      5011  Toshkent kassa
--      5012  Qashqadaryo kassa
--      54xx  Abrorxo'ja (hodim kassasi — kodi nom bo'yicha topiladi)
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  ✅ BUTUN FAYLNI BIR MARTA RUN QILING. Boshdan oxirigacha belgilab
--     "Run" bosing — bo'lib-bo'lib RUN qilish SHART EMAS.
--     Hammasi bitta tranzaksiya: biror joyda xato bo'lsa HAMMASI orqaga
--     qaytadi (yarim yozilgan holat bo'lmaydi).
--
--  NIMA QILADI:
--    1) Reja jadvalini yaratadi va raqamlar bilan to'ldiradi
--    2) Yetishmayotgan bola-hisoblarni ochadi (hodim kassasida naqd/payme/USD yo'q)
--    3) Har kassa uchun 2 ta yozuv (jami 6 ta):
--         "Reset"    — Dt Boshlang'ich kapital / Kt <hisob>   (eski qoldiq 0 ga)
--         "Ochilish" — Dt <hisob> / Kt Boshlang'ich kapital   (yangi qoldiq)
--    4) O'ZINI O'ZI TEKSHIRADI: har hisob rejaga mos keldimi + balans
--       tenglikda qoldimi. Mos kelmasa xato beradi va hammasi bekor bo'ladi.
--
--  NEGA 9010 (savdo tushumi) EMAS: bu pul TUSHUM emas, u allaqachon ishlab
--  topilgan. Kt tomoniga 9010 yozilsa o'sha kunning P&L'i shishadi. Kapitalga
--  yozilganda AKTIV va KAPITAL birga o'zgaradi, P&L'ga umuman tegmaydi.
--
--  ⚠️⚠️ RAQAMLARNI TEKSHIRING — ayniqsa Toshkent USD = 405 245.
--       Joriy kursda ~5 MLRD so'm, ya'ni naqddan (181,5 mln) ~28 barobar
--       katta. Qashqadaryoda esa atigi 8 270 $. Xato bo'lsa quyidagi
--       ⚙️ RAQAMLAR blokida tuzating.
--       Yozilib bo'lgach ham qaytarish mumkin — pastdagi ROLLBACK.
--
--  ⚠️ ABRORXO'JA — HODIM KASSASI. Hodim kassalarida (5401+) naqd/payme/USD
--     bola-hisoblari YO'Q (PROVODKA_VALYUTA_SEED.sql ularni chetlab o'tgan).
--     Skript ularni o'zi ochadi. Tekshirildi, hech narsa buzilmaydi:
--       • v_kassa_card — `p.pul_turi is null`: tur bolalari alohida karta
--         bo'lmaydi, `jami` esa ularni qo'shib hisoblaydi
--       • USD bolasi hodimga qo'shiladi, 5400 guruhga emas
--       • kassa_root() -> perm_op_key(): ruxsat hodim kassasidan meros bo'ladi
--       • v_filial_tanlov `pul_turi is null` bilan filtrlaydi — tegmaydi
--
--  TALAB: PROVODKA_KAPITAL.sql, PROVODKA_VALYUTA.sql, PROVODKA_VALYUTA_SEED.sql
--         RUN qilingan bo'lsin. conv_baza_kurs('USD') kurs qaytarsin.
--
--  ⚠️ RUN QILISHDAN OLDIN: n8n "Aros Provodka - Auto Sync" (7MSHrXnz9cGAFBTh)
--     ni DEACTIVATE qiling — u har 30 daqiqada Aros farqini yozadi.
--     Ish tugagach qaytarib yoqing. 5011/5012 raqamlari Aros'dagi haqiqiy
--     balans bilan bir xil bo'lishi kerak, aks holda sync farqni tushum
--     qilib yozadi. (Hodim kassasi Aros bilan sinxronlanmaydi.)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. REJA JADVALI
-- ---------------------------------------------------------------------
create table if not exists boshlangich_qoldiq_reja (
  kassa_code text    not null,
  turi       text    not null check (turi in ('naqd','click','payme','USD')),
  miqdor     numeric not null default 0 check (miqdor >= 0),
  izoh       text,
  primary key (kassa_code, turi)
);

comment on table boshlangich_qoldiq_reja is
  'Boshlang''ich qoldiq rejasi (PROVODKA_BOSHLANGICH_QOLDIQ.sql). '
  'miqdor — hisobning O''Z valyutasida: naqd/click/payme = so''m, USD = dollar.';

revoke all on boshlangich_qoldiq_reja from public, anon;
-- RLS yoqilgan, policy YO'Q -> anon/authenticated o'qiy olmaydi.
-- Egasi (postgres, SQL editor) RLS'dan o'tadi, shuning uchun skript ishlaydi.
alter table boshlangich_qoldiq_reja enable row level security;


-- ---------------------------------------------------------------------
-- ⚙️⚙️ RAQAMLAR — FAQAT SHU BLOKNI TAHRIRLANG
-- ---------------------------------------------------------------------
-- miqdor hisobning O'Z valyutasida: naqd/click/payme -> so'm, USD -> dollar.
-- 0 = o'sha hisob bo'sh qoladi.
do $reja$
declare
  -- Toshkent (5011)
  t_naqd  numeric := 181502000;
  t_click numeric := 0;
  t_payme numeric := 8815000;
  t_usd   numeric := 405245;          -- ⚠️ TEKSHIRING

  -- Qashqadaryo (5012)
  q_naqd  numeric := 294914000;
  q_click numeric := 0;
  q_payme numeric := 0;
  q_usd   numeric := 8270;

  -- Abrorxo'ja (hodim kassasi)
  a_naqd  numeric := 324041000;
  a_click numeric := 0;
  a_payme numeric := 664128000;
  a_usd   numeric := 22065;

  -- Abrorxo'jani qanday topamiz. `a_kod` to'ldirilsa qidiruv o'tkazib
  -- yuboriladi (masalan a_kod := '5423').
  a_qidiruv text := 'abrorxo';        -- nomning ajralib turadigan qismi
  a_kod     text := null;

  v_kod  text;
  v_nom  text;
  v_soni int;
begin
  -- ---- Abrorxo'ja kassasini topish ----------------------------------
  -- Bola-hisoblar (… · Naqd / … · USD) qidiruvdan CHIQARILADI: skript
  -- qayta RUN qilinganda ular "bir nechta topildi" xatosini bermasin.
  if a_kod is not null then
    select code, name into v_kod, v_nom
      from accounts where code = a_kod and section = 'pul';
    if v_kod is null then
      raise exception 'a_kod = % — bunday pul hisobi yo''q', a_kod;
    end if;
  else
    select count(*) into v_soni
      from accounts
     where section = 'pul' and is_active
       and pul_turi is null and coalesce(currency,'UZS') = 'UZS'
       and lower(name) like '%' || a_qidiruv || '%';

    if v_soni <> 1 then
      raise exception E'"%" bo''yicha % ta kassa topildi (1 ta kerak).\n'
        'Quyidagi so''rovni alohida RUN qilib aniq kodni toping va yuqoridagi '
        '`a_kod` o''zgaruvchisiga yozing:\n'
        '  select code, name, subtitle, kassa_turi from accounts\n'
        '   where section = ''pul'' and pul_turi is null\n'
        '     and (lower(name) like ''%%abror%%'' or lower(name) like ''%%axmad%%''\n'
        '          or lower(name) like ''%%ahmad%%'') order by code;',
        a_qidiruv, v_soni;
    end if;

    select code, name into v_kod, v_nom
      from accounts
     where section = 'pul' and is_active
       and pul_turi is null and coalesce(currency,'UZS') = 'UZS'
       and lower(name) like '%' || a_qidiruv || '%';
  end if;

  raise notice 'Abrorxo''ja kassasi: % — %', v_kod, v_nom;

  -- ---- Rejani yozish -------------------------------------------------
  insert into boshlangich_qoldiq_reja (kassa_code, turi, miqdor, izoh) values
    ('5011', 'naqd',  t_naqd,  'Toshkent kassa · naqd'),
    ('5011', 'click', t_click, 'Toshkent kassa · click'),
    ('5011', 'payme', t_payme, 'Toshkent kassa · payme'),
    ('5011', 'USD',   t_usd,   'Toshkent kassa · dollar'),
    ('5012', 'naqd',  q_naqd,  'Qashqadaryo kassa · naqd'),
    ('5012', 'click', q_click, 'Qashqadaryo kassa · click'),
    ('5012', 'payme', q_payme, 'Qashqadaryo kassa · payme'),
    ('5012', 'USD',   q_usd,   'Qashqadaryo kassa · dollar'),
    (v_kod,  'naqd',  a_naqd,  v_nom || ' · naqd'),
    (v_kod,  'click', a_click, v_nom || ' · click'),
    (v_kod,  'payme', a_payme, v_nom || ' · payme'),
    (v_kod,  'USD',   a_usd,   v_nom || ' · dollar')
  on conflict (kassa_code, turi) do update
     set miqdor = excluded.miqdor,
         izoh   = excluded.izoh;

  -- Uchala kassa ham topildimi
  select count(distinct r.kassa_code) into v_soni
    from boshlangich_qoldiq_reja r
    join accounts k on k.code = r.kassa_code and k.section = 'pul';
  if v_soni <> 3 then
    raise exception 'Rejada % ta kassa topildi (3 kerak) — 5011/5012 kodlari to''g''rimi?', v_soni;
  end if;
end
$reja$;


-- ---------------------------------------------------------------------
-- 2. YETISHMAYOTGAN BOLA-HISOBLARNI OCHISH — PUL YOZMAYDI
-- ---------------------------------------------------------------------
-- Kod ajratish mantig'i PROVODKA_VALYUTA_SEED.sql dan ko'chirilgan.
-- create_pul_turi_child()/create_valyuta_child() CHAQIRILMAYDI — ular
-- auth.uid() orqali adminlikni tekshiradi, SQL editorda esa u NULL.
-- IDEMPOTENT: bor bo'lgan bola qayta ochilmaydi.
do $och$
declare
  r          record;
  v_kassa    uuid;
  v_nom      text;
  v_turi     text;
  v_sub      text;
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
    select a.id, a.name, a.kassa_turi, a.subtitle
      into v_kassa, v_nom, v_turi, v_sub
      from accounts a
     where a.code = r.kassa_code and a.section = 'pul';

    if v_kassa is null then
      raise exception 'Kassa topilmadi: %', r.kassa_code;
    end if;

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
        raise exception 'USD kod bloki (%xx) to''ldi', v_usd_pref;
      end if;
      v_code := v_usd_pref || lpad(v_next::text, 2, '0');

      insert into accounts(code, name, type, section, currency, parent_id,
                           kassa_turi, is_active, subtitle)
      values (v_code, v_nom || ' · USD', 'aktiv', 'pul', 'USD', v_kassa,
              v_turi, true, v_sub);

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
              v_turi, true, v_sub, r.turi);
    end if;

    n_yangi := n_yangi + 1;
    raise notice 'HISOB OCHILDI: %  %', v_code, v_nom || ' · ' || r.turi;
  end loop;

  raise notice '--- % ta yangi bola-hisob | % tasi allaqachon bor edi', n_yangi, n_bor;
end
$och$;


-- ---------------------------------------------------------------------
-- 3. YOZISH — reset + ochilish + o'z-o'zini tekshirish
-- ---------------------------------------------------------------------
do $bq$
declare
  p_kurs   numeric := null;          -- ⚙️ USD kursi; null = conv_baza_kurs('USD')
  p_sana   date    := current_date;  -- ⚙️ boshlang'ich qoldiq sanasi

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
  v_xato     int;
  v_farq     numeric;

  n_reset    int := 0;
  n_ochilish int := 0;
  n_entry    int := 0;
begin
  -- Ikki marta yozib yuborilmasin
  if exists (select 1 from entry where ext_ref like 'bq:%') then
    raise exception E'TO''XTADI: `bq:%%` belgili yozuvlar allaqachon bor.\n'
      'Bu skript avval RUN qilingan. Qayta yozish uchun avval fayl oxiridagi '
      'ROLLBACK ni bajaring.';
  end if;

  v_kapital := boshlangich_kapital_id();
  if v_kapital is null then
    raise exception 'Boshlang''ich kapital hisobi topilmadi — PROVODKA_KAPITAL.sql RUN qilinganmi?';
  end if;

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

  for r_kassa in
    select k.id, k.code, k.name
      from accounts k
     where k.code in (select distinct kassa_code from boshlangich_qoldiq_reja)
       and k.section = 'pul'
     order by k.code
  loop
    raise notice '=== % — %', r_kassa.code, r_kassa.name;

    -- ---- 3.1 RESET: kassa + barcha bolalarini 0 ga -------------------
    -- is_active bo'yicha FILTRLAMAYDI: faol bo'lmagan bolada ham qoldiq
    -- turgan bo'lishi mumkin.
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
        continue;
      end if;

      -- Bitta teskari satr bilan so'm ham, valyuta ham 0 ga tushishi uchun
      -- ikkovining ishorasi bir xil bo'lishi shart (satrda debit yoki credit
      -- bittasi > 0, fc_amount esa musbat).
      if v_fc <> 0 and (v_uzs = 0 or sign(v_uzs) <> sign(v_fc)) then
        raise exception E'% (%) — so''m qoldig''i %, valyuta qoldig''i %:\n'
          'ishoralar mos emas, bitta satr bilan 0 ga tushirib bo''lmaydi. '
          'Bu holatni qo''lda hal qilish kerak — menga xabar bering.',
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

    -- Muvozanat satri: kapital. v_jami = 0 bo'lsa satr kerak emas.
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
      -- check_entry_balanced DEFERRED, u faqat COMMIT paytida ishlaydi va
      -- o'sha yerdagi xato tushunarsiz bo'ladi — shuning uchun o'zimiz tekshiramiz.
      select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
        into v_dt, v_kt from entry_line where entry_id = v_entry;
      if v_dt <> v_kt then
        raise exception 'RESET yozuvi muvozanatda emas: Dt=% Kt=% (%)', v_dt, v_kt, r_kassa.code;
      end if;
    end if;

    -- ---- 3.2 OCHILISH: yangi qoldiq kapitaldan --------------------------
    v_entry := null;
    v_jami  := 0;

    for r_reja in
      select turi, miqdor
        from boshlangich_qoldiq_reja
       where kassa_code = r_kassa.code and miqdor <> 0
       order by turi
    loop
      if r_reja.turi = 'USD' then
        select a.id, a.code into v_acc, v_acc_code
          from accounts a
         where a.parent_id = r_kassa.id and a.is_active
           and coalesce(a.currency, 'UZS') = 'USD'
         order by a.code limit 1;
        v_line_uzs := round(r_reja.miqdor * v_kurs, 2);
        v_line_fc  := r_reja.miqdor;
      else
        select a.id, a.code into v_acc, v_acc_code
          from accounts a
         where a.parent_id = r_kassa.id and a.is_active
           and a.pul_turi = r_reja.turi
           and coalesce(a.currency, 'UZS') = 'UZS'
         order by a.code limit 1;
        v_line_uzs := r_reja.miqdor;
        v_line_fc  := null;
      end if;

      if v_acc is null then
        raise exception '% kassasida "%" hisobi topilmadi', r_kassa.code, r_reja.turi;
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
    end if;
  end loop;

  if n_entry = 0 then
    raise exception 'TO''XTADI: birorta yozuv yaratilmadi — kutilmagan holat.';
  end if;

  -- ---- 3.3 O'Z-O'ZINI TEKSHIRISH ------------------------------------
  -- Bu yerdan chiqadigan har qanday xato BUTUN skriptni orqaga qaytaradi.

  -- (a) Har hisob rejaga aniq mos keldimi
  select count(*) into v_xato
    from boshlangich_qoldiq_reja r
    join accounts k on k.code = r.kassa_code and k.section = 'pul'
    join accounts a on a.parent_id = k.id and a.is_active
      and (case when r.turi = 'USD' then coalesce(a.currency,'UZS') = 'USD'
                else a.pul_turi = r.turi and coalesce(a.currency,'UZS') = 'UZS' end)
    join lateral (
      select coalesce(sum(l.debit - l.credit), 0) as uzs,
             coalesce(sum(case when l.debit > 0 then coalesce(l.fc_amount,0)
                               else -coalesce(l.fc_amount,0) end), 0) as fc
        from entry_line l join entry e on e.id = l.entry_id
       where l.account_id = a.id and e.status = 'posted' and e.is_deleted = false
    ) b on true
   where (case when r.turi = 'USD' then b.fc else b.uzs end) <> r.miqdor;

  if v_xato > 0 then
    raise exception 'TEKSHIRUV XATO: % ta hisob rejaga mos kelmadi — hammasi bekor qilindi.', v_xato;
  end if;

  -- (b) Kassalarning O'ZIDA pul qolmadimi (hammasi bolalarda bo'lishi kerak)
  select count(*) into v_xato
    from accounts k
    join lateral (
      select coalesce(sum(l.debit - l.credit), 0) as uzs
        from entry_line l join entry e on e.id = l.entry_id
       where l.account_id = k.id and e.status = 'posted' and e.is_deleted = false
    ) b on true
   where k.code in (select distinct kassa_code from boshlangich_qoldiq_reja)
     and k.section = 'pul' and b.uzs <> 0;

  if v_xato > 0 then
    raise exception 'TEKSHIRUV XATO: % ta kassaning o''zida pul qoldi', v_xato;
  end if;

  -- (c) Balans tenglikda qoldimi
  select coalesce(sum(case when bolim = 'AKTIV' then amount else 0 end)
                - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end), 0)
    into v_farq
    from balans(p_sana);

  if v_farq <> 0 then
    raise exception 'TEKSHIRUV XATO: balans tenglikda emas, farq = % — hammasi bekor qilindi.', v_farq;
  end if;

  raise notice '--- ✅ TUGADI: % ta yozuv | % hisob nolga tushdi | % hisobga qoldiq kiritildi | balans farqi 0',
    n_entry, n_reset, n_ochilish;
end
$bq$;


-- ---------------------------------------------------------------------
-- 4. NATIJA — skriptning oxirgi so'rovi, Supabase shuni ko'rsatadi
-- ---------------------------------------------------------------------
select k.code                                    as kassa,
       k.name                                    as kassa_nom,
       a.code                                    as hisob,
       coalesce(a.pul_turi, a.currency)          as turi,
       b.uzs                                     as qoldiq_som,
       nullif(b.fc, 0)                           as qoldiq_valyuta,
       r.miqdor                                  as reja,
       case when a.id = k.id then 0
            when coalesce(a.currency,'UZS') <> 'UZS' then b.fc - coalesce(r.miqdor, 0)
            else b.uzs - coalesce(r.miqdor, 0)
       end                                       as farq_nol_bolishi_kerak
  from accounts k
  join accounts a on a.id = k.id or a.parent_id = k.id
  join lateral (
    select coalesce(sum(l.debit - l.credit), 0) as uzs,
           coalesce(sum(case when l.debit > 0 then coalesce(l.fc_amount,0)
                             else -coalesce(l.fc_amount,0) end), 0) as fc
      from entry_line l join entry e on e.id = l.entry_id
     where l.account_id = a.id and e.status = 'posted' and e.is_deleted = false
  ) b on true
  left join boshlangich_qoldiq_reja r
         on r.kassa_code = k.code
        and r.turi = case when coalesce(a.currency,'UZS') <> 'UZS'
                          then coalesce(a.currency,'UZS') else a.pul_turi end
 where k.code in (select distinct kassa_code from boshlangich_qoldiq_reja)
   and k.section = 'pul'
 order by k.code, (a.id = k.id) desc, a.code;


-- =====================================================================
--  QO'SHIMCHA TEKSHIRUVLAR — kerak bo'lsa alohida RUN qiling
-- =====================================================================
-- Kartada qanday ko'rinadi:
--   select code, name, kassa_turi, uzs, naqd, click, payme, usd, usd_uzs, jami
--     from v_kassa_card
--    where code in (select distinct kassa_code from boshlangich_qoldiq_reja)
--    order by code;
--
-- Yaratilgan yozuvlar (6 ta kutiladi):
--   select e.ext_ref, e.entry_date, e.description, e.fc_rate, count(l.id) as satrlar,
--          sum(l.debit) as dt, sum(l.credit) as kt
--     from entry e join entry_line l on l.entry_id = e.id
--    where e.ext_ref like 'bq:%'
--    group by e.id, e.ext_ref, e.entry_date, e.description, e.fc_rate
--    order by e.ext_ref;
--
-- P&L'ga tegmadimi (BO'SH chiqishi SHART):
--   select e.ext_ref, a.code, a.name, a.type
--     from entry e join entry_line l on l.entry_id = e.id
--     join accounts a on a.id = l.account_id
--    where e.ext_ref like 'bq:%' and a.type in ('daromad','xarajat');
--
-- Kapital hisobining yangi qoldig'i:
--   select bolim, code, name, amount from balans(current_date)
--    where code = (select code from accounts where id = boshlangich_kapital_id());


-- =====================================================================
--  ROLLBACK — noto'g'ri raqam yozilib qolsa
-- =====================================================================
-- Yozuvlar `ext_ref` = 'bq:...' bilan belgilangan, shuning uchun aniq topiladi.
--
-- A) YUMSHOQ (tavsiya) — jurnalda usti chizilgan holda qoladi, tarix saqlanadi.
--    Kassa qoldiqlari yozuvdan OLDINGI holatiga qaytadi (reset ham bekor bo'ladi).
--
--    update entry set is_deleted = true,
--                     deleted_at = now(),
--                     deleted_by_name = 'rollback: boshlangich qoldiq'
--     where ext_ref like 'bq:%';
--
--    Keyin qayta RUN qilish uchun ext_ref'ni bo'shatish SHART (unique to'siq):
--    update entry set ext_ref = ext_ref || ':bekor:' || id::text
--     where ext_ref like 'bq:%' and is_deleted;
--
-- B) QATTIQ — butunlay o'chirish, izsiz. Faqat xato darrov sezilsa.
--    entry_line BITTA statement bilan o'chiriladi — deferred balans triggeri
--    COMMIT paytida 0=0 ko'radi va to'smaydi.
--
--    delete from entry_line where entry_id in (select id from entry where ext_ref like 'bq:%');
--    delete from entry where ext_ref like 'bq:%';
--
-- Ochilgan bola-hisoblar rollbackda TEGILMAYDI (bo'sh hisob, zarari yo'q).
-- Kerak bo'lsa: update accounts set is_active = false where code = '...';
