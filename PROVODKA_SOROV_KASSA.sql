-- =====================================================================
-- PROVODKA_SOROV_KASSA.sql — tasdiqlash: HAMMA kassa + MOS pul turi
-- ---------------------------------------------------------------------
-- MUAMMO (jonli, 2026-08-26):
--   Abror akaga 5 ta kassa biriktirilgan, lekin tasdiqlash modalida
--   FAQAT BITTA oila (eng kichik kodli markaziy kassa) ko'rinardi —
--   o'zining qo'lidagi pul ro'yxatda yo'q edi va to'lay olmasdi.
--
-- SABAB (ikki bo'g'in):
--   1. `sorovlar.kimdan_kassa_id` so'rov YARATILGANDA `sorov_kassa_of()`
--      bilan QOTIB qoladi — u `op_kassa_ids` dagi ENG KICHIK KODLI UZS
--      ildizni oladi (3.3, "bir odamda bir nechta kassa bo'lsa" izohi).
--   2. `sorov_qaror_ctx` (7.3) `v_root := s.kimdan_kassa_id` qilib
--      FAQAT o'sha ildiz + bevosita bolalarini ko'rsatadi; `sorov_tasdiq`
--      (8.4 oila chegarasi) ham shu oila bilan cheklaydi.
--
-- QILINGANI:
--   1) `sorov_qaror_ctx` — manba ro'yxati = SO'ROV KELGAN ODAMNING
--      `op_kassa_ids` idagi HAMMA UZS ildiz kassa + UZS tur-bolalari.
--      Har qatorda YANGI `guruh` / `guruh_id` kalitlari (ildiz kassa).
--   2) `sorov_tasdiq` — (a) oila chegarasi shu doiraga kengaydi;
--      (b) pul MANBA hisobning pul turiga MOS bolaga tushadi
--      ("Toshkent · Naqd" -> so'rovchining "· Naqd" hisobi).
--   3) `perm_guard_entry_line` — istisno doirasi pul-turi bolasini ham
--      qamraydi (2-band busiz 42501 bilan yiqilardi, pastda batafsil).
--
-- 🔴 IMZOLAR O'ZGARMADI: sorov_qaror_ctx(uuid),
--    sorov_tasdiq(uuid, numeric, uuid), perm_guard_entry_line().
--    Uchalasi ham `create or replace` — PostgREST'da noaniqlik YO'Q,
--    prod klient (2 va 3 argumentli chaqiruv) avvalgidek ishlaydi.
-- 🔴 ADDITIVE: faol qatorlarda `drop`/`alter` YO'Q. Trigger DDL ham
--    QAYTA YOZILMAYDI — `create or replace function` funksiya OID ini
--    saqlaydi, mavjud `trg_perm_guard_entry_line` uzilmaydi.
-- 🔴 Funksiya tanalari PROVODKA_SOROVLAR.sql DAN DASTUR BILAN ko'chirildi
--    (qo'lda qayta yozilmadi); faqat quyidagi bloklar almashtirildi.
-- ⚠️ Funksiya tanalari NOMLANGAN teg bilan (fn tegi) — manbadagidek.
-- ⚠️ Bu faylning izohlarida dollar-qavs YO'Q (CLAUDE.md): teg soni juft
--    va aynan funksiya soniga mos bo'lishi kerak (3 funksiya = 6 teg).
--
-- 🔴 ORTGA QAYTARISH: PROVODKA_SOROVLAR.sql ning 4-BO'LIM (guard),
--    7.3 (`sorov_qaror_ctx`) va 8-BO'LIM (`sorov_tasdiq`) bloklarini
--    qayta RUN qiling — ular ayni shu uch funksiyaning eski tanasi.
-- =====================================================================


-- #####################################################################
-- ##  1-QADAM — sorov_qaror_ctx(): MANBA RO'YXATI                     ##
-- #####################################################################
-- FARQ (manbaga nisbatan, 4 blok):
--   A1  declare  : `v_up user_perms` + `v_ops uuid[]` qo'shildi
--   A2  tana     : `s.kimdan_id` ning user_perms qatori o'qiladi
--   A3  so'rov   : where -> `perm_op_key(a.id) = any(v_ops)` (zaxira bilan),
--                  `guruh`/`guruh_id` kalitlari, tartib ildiz kodi bo'yicha
--   A4  comment  : matn yangilandi
-- Qolgan HAMMA qator (auth/sahifa qorovuli, admin izohi, javob kalitlari
-- `soralgan`/`mening_qoldigim`/`valyuta`/`kassa_nom`/`ozim`/`kimdan_nom`,
-- `perm_check_accounts` filtri, UZS/xarajat_guruh shartlari) — BIR XIL.
-- #####################################################################

create or replace function sorov_qaror_ctx(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid  uuid := auth.uid();
  s      sorovlar;
  v_nom  text;
  v_root uuid;
  v_his  jsonb;
  v_up   user_perms;   -- SO'ROV KELGAN ODAMNING ruxsat qatori
  v_ops  uuid[];       -- uning op_kassa_ids i (null -> ZAXIRA: eski oila yo'li)
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('sorovlar') then
    raise exception 'Sorovlar sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  select * into s from sorovlar where id = p_id;
  if not found then
    raise exception 'Sorov topilmadi' using errcode = '22000';
  end if;
  -- 🔴 So'ralgan odam YOKI admin (Asilbek qarori 2026-08-25 — 8.1 ga qara).
  if s.kimdan_id <> v_uid and not is_admin() then
    raise exception 'Bu sorov sizga kelmagan' using errcode = '42501';
  end if;

  -- 🔴 ILDIZ har doim `kimdan_kassa_id` — ADMIN uchun ham. Ya'ni admin
  --    o'z hisoblarini emas, SO'ROV KELGAN ODAMNING hisoblarini ko'radi:
  --    pul o'shaning kassasidan chiqadi (adminda kassa biriktirilmagan).
  --    ⚠️ Bu "boshqa odamning balansi ko'rinmasin" qoidasidan ONGLI
  --    ISTISNO: admin o'sha odam nomidan qaror qilyapti, qarorni raqamsiz
  --    qabul qilib bo'lmaydi. Oddiy foydalanuvchida bunday yo'l YO'Q.
  v_root := s.kimdan_kassa_id;
  select name into v_nom from accounts where id = v_root;

  -- 🔴 MANBA RO'YXATI KENGAYDI (2026-08-26 — PROVODKA_SOROV_KASSA.sql).
  --    Avval faqat `kimdan_kassa_id` OILASI ko'rinardi. U esa so'rov
  --    YARATILGANDA `sorov_kassa_of()` bilan qotib qoladi va odamning
  --    ENG KICHIK KODLI kassasini oladi. Beshta kassasi bor odam shu
  --    sababli o'z qo'lidagi pulni ko'rmasdi va to'lay olmasdi.
  --    Endi ro'yxat = so'rov kelgan odamning `op_kassa_ids` idagi HAMMA
  --    UZS ildiz kassa + ularning UZS tur-bolalari (Naqd/Click/Payme).
  --    Predikat `perm_op_key(a.id) = any(op_kassa_ids)` — 3.3 va 8.4
  --    bilan AYNAN bir xil (bola ruxsatni parentdan oladi).
  -- 🔴 ADMIN uchun ham SHU ro'yxat: pul baribir o'sha odamning
  --    kassasidan chiqadi (yuqoridagi izohdagi qaror o'zgarmadi).
  -- 🔴 ZAXIRA: qator yo'q / `kassa_scope <> 'list'` / ro'yxat bo'sh
  --    bo'lsa ESKI yo'l (`v_root` oilasi). Busiz `all`-scope beruvchi
  --    umuman to'lay olmay qolardi.
  select * into v_up from user_perms where user_id = s.kimdan_id;
  if found and v_up.kassa_scope = 'list'
     and coalesce(array_length(v_up.op_kassa_ids, 1), 0) > 0 then
    v_ops := v_up.op_kassa_ids;
  end if;

  -- Hisoblar: ildiz kassa VA uning bevosita bolalari (Naqd/Click/Payme).
  -- 🔴 FAQAT UZS. Valyuta bolasidan (56xx USD, 57xx CNY...) to'lash kurs
  --    konvertatsiyasini talab qiladi — so'rov so'mda, hisob dollarda.
  --    Yarim ishlaydigan yo'l ochilmaydi: konvert alohida mexanizm
  --    (`convert_start_v2`) va u o'z koridori/tasdig'i bilan keladi.
  -- 🔴 `perm_check_accounts` — 8.4 dagi VALIDATSIYA bilan AYNAN bir xil
  --    predikat: ro'yxatda ko'ringan hisob har doim to'lovga yaroqli
  --    (admin/all-scope -> hammasi, list-scope -> op_kassa_ids).
  -- `guruh`/`guruh_id` — ildiz kassa (klient ro'yxatni shu bo'yicha
  -- guruhlab chizadi). Ildiz qator uchun ham to'ldiriladi (o'ziga o'zi).
  -- `guruh_kod` FAQAT tartib uchun — javobga chiqmaydi (`- 'guruh_kod'`).
  select coalesce(jsonb_agg((to_jsonb(x) - 'guruh_kod'::text)
                            order by x.guruh_kod, x.code), '[]'::jsonb)
    into v_his
    from (
      select a.id as account_id, a.code, a.name,
             sorov_kassa_bal(a.id) as qoldiq,
             g.name as guruh, g.id as guruh_id, g.code as guruh_kod
        from accounts a
        left join accounts g
          on g.id = case when v_ops is null then v_root
                         else perm_op_key(a.id) end
       where (case when v_ops is null
                   then (a.id = v_root or a.parent_id = v_root)
                   else perm_op_key(a.id) = any (v_ops) end)
         and a.is_active is true
         and a.type = 'aktiv' and a.code like '5%'
         and coalesce(a.currency, 'UZS') = 'UZS'
         and a.kassa_turi is distinct from 'xarajat_guruh'
         and perm_check_accounts(array[a.id])
    ) x;

  return jsonb_build_object(
    'soralgan',        s.summa,
    -- Ildiz kassa qoldig'i (eski kalit — klient tanlovdan keyin uni
    -- TANLANGAN hisobniki bilan almashtiradi).
    'mening_qoldigim', sorov_kassa_bal(v_root),
    'valyuta',         'UZS',
    -- 🔴 `xarajat_summa` YO'Q — balans ayirma orqali tiklanardi.
    --    Tasdiqlovchiga kerak emas: u SO'RALGAN summani ko'radi.
    'kassa_nom',       v_nom,
    'hisoblar',        v_his,
    -- `ozim=false` -> admin boshqa odam nomidan qaror qilyapti; klient
    -- yorliqni almashtiradi ("Qo'lingizdagi pul" -> "<Nom> qo'lidagi pul").
    'ozim',            (s.kimdan_id = v_uid),
    'kimdan_nom',      sorov_ism(s.kimdan_id, v_root));
end $fn$;

revoke all on function sorov_qaror_ctx(uuid) from public, anon;
grant execute on function sorov_qaror_ctx(uuid) to authenticated;

comment on function sorov_qaror_ctx(uuid) is
  'Tasdiqlash modali konteksti + tolov hisoblari royxati. 2026-08-26: royxat = sorov kelgan '
  'odamning op_kassa_ids idagi HAMMA UZS kassasi + ularning UZS tur-bolalari, qoldiq bilan; '
  'har qatorda guruh/guruh_id (ildiz kassa) kalitlari. Zaxira - eski kimdan_kassa_id oilasi. '
  'Faqat sorov kelgan odam yoki ADMIN. Admin holatida royxat sorov kelgan odamnikidir.';

-- #####################################################################
-- ##  2-QADAM — sorov_tasdiq(): OILA CHEGARASI + MANZIL               ##
-- #####################################################################
-- FARQ (manbaga nisbatan, 5 blok):
--   B1  create   : `create` -> `create or replace` (imzo AYNAN o'sha;
--                  manbadagi ikkita `drop function` bu yerga KO'CHMADI)
--   B2  declare  : `v_up`, `v_ops`, `v_dt` qo'shildi
--   B3  8.4      : oila chegarasi `op_kassa_ids` doirasiga kengaydi
--                  (+ ZAXIRA sifatida eski shart), xato matni yangilandi
--   B4  entry_line: Dt = `v_dt` (mos pul turi bolasi, topilmasa ildiz)
--   B5  comment  : matn yangilandi
-- 🔴 TEGILMAGAN: 8.1 (kim tasdiqlaydi), 8.2 idempotentlik (for update +
--    status + ext_ref UNIQUE + unique_violation tutqichi), 8.3 qisman,
--    8.5 xarajat holati, 8.6 pending xarajatni yopish, 8A limit qorovuli,
--    `sorovlar` update TARTIBI va `kimdan_kassa_id = v_gk` yozuvi,
--    `jonatma_entry_id`, javob kalitlari.
-- #####################################################################

create or replace function sorov_tasdiq(p_id uuid, p_summa numeric, p_kassa uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  s        sorovlar;
  v_est    text;
  v_edel   boolean;
  v_xar    numeric := 0;
  v_bal    numeric;
  v_entry  uuid;
  v_holat  text;
  v_yopdi  boolean := false;
  v_gk     uuid;       -- HAQIQATDA to'lanadigan hisob (ildiz yoki tur-bolasi)
  v_acc    accounts;
  v_tosiq  text;       -- 8A: limit/qoldiq to'sig'i sababi (null = to'siq yo'q)
  v_up     user_perms; -- SO'ROV KELGAN ODAMNING ruxsat qatori (oila chegarasi)
  v_ops    uuid[];     -- uning op_kassa_ids i (null -> ZAXIRA: eski shart)
  v_dt     uuid;       -- MANZIL: so'rovchining pul turiga MOS hisobi
begin
  perform set_config('lock_timeout', '5s', true);

  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not sorov_page_ok('sorovlar') then
    raise exception 'Sorovlar sahifasi ruxsatingizda yoq' using errcode = '42501';
  end if;

  -- 8.2 (1) — qator qulfi
  select * into s from sorovlar where id = p_id for update;
  if not found then
    raise exception 'Sorov topilmadi' using errcode = '22000';
  end if;

  -- 8.1 — 🔴 YAGONA JOY: so'rov kelgan odam YOKI admin.
  if s.kimdan_id <> v_uid and not is_admin() then
    raise exception 'Sorovni faqat sorov kelgan odam yoki admin tasdiqlaydi'
      using errcode = '42501';
  end if;

  -- 8.2 (2) — ikki marta tasdiqlash: pul IKKI MARTA jo'natilmaydi
  if s.status <> 'pending' then
    return jsonb_build_object('ok', false, 'kod', 'already_decided',
                              'holat', s.status,
                              'jonatilgan_summa', s.jonatilgan_summa);
  end if;

  -- Summa chegarasi
  if p_summa is null or p_summa <= 0 or p_summa <> round(p_summa, 2) then
    raise exception 'Summa musbat bolishi kerak' using errcode = '22000';
  end if;
  if p_summa > s.summa then
    raise exception 'Soralgandan kop jonatib bolmaydi' using errcode = '22000';
  end if;

  -- 8.5 — xarajat holati
  if s.xarajat_entry_id is not null then
    select e.status, e.is_deleted into v_est, v_edel
      from entry e where e.id = s.xarajat_entry_id for update;

    if not found or v_edel is true then
      update sorovlar
         set status     = 'rad',
             rad_izoh   = 'Xarajat ochirilgan — sorov avtomat yopildi',
             decided_at = now(),
             decided_by = v_uid
       where id = s.id;
      return jsonb_build_object('ok', false, 'kod', 'xarajat_yoq', 'holat', 'rad');
    end if;

    -- 🔴 Summa NUSXAGA emas, YOZUVGA qarab olinadi (tahrirlangan bo'lishi mumkin)
    select coalesce(sum(l.credit), 0) into v_xar
      from entry_line l
     where l.entry_id = s.xarajat_entry_id and l.account_id = s.kassa_id;
  end if;

  -- 8.4 — TO'LOV HISOBI (8.1b): tanlangan yoki sukut bo'yicha ildiz kassa
  v_gk := coalesce(p_kassa, s.kimdan_kassa_id);

  select * into v_acc from accounts where id = v_gk;
  if not found or v_acc.is_active is distinct from true then
    raise exception 'Tolov hisobi topilmadi yoki faol emas' using errcode = '22000';
  end if;
  if v_acc.type <> 'aktiv' or v_acc.code not like '5%'
     or v_acc.kassa_turi is not distinct from 'xarajat_guruh' then
    raise exception 'Bu hisob kassa emas' using errcode = '22000';
  end if;
  -- 🔴 FAQAT UZS: so'rov so'mda. Valyuta hisobidan to'lash kurs
  --    konvertatsiyasini talab qiladi — u alohida mexanizm (konvert).
  if coalesce(v_acc.currency, 'UZS') <> 'UZS' then
    raise exception 'Valyuta hisobidan tolab bolmaydi — avval somga konvert qiling'
      using errcode = '22000';
  end if;
  -- 🔴 OILA CHEGARASI (2026-08-26 kengaytirildi — PROVODKA_SOROV_KASSA.sql).
  --    Avval faqat `kimdan_kassa_id` ning O'ZI yoki BEVOSITA bolasi
  --    o'tardi — ya'ni odamning qolgan 4 kassasidan to'lab bo'lmasdi.
  --    Endi doira = SO'ROV KELGAN ODAMGA BIRIKTIRILGAN har qanday kassa
  --    (`perm_op_key(v_gk) = any(op_kassa_ids)`), 7.3 dagi ro'yxat bilan
  --    AYNAN bir xil predikat.
  -- 🔴 CHEGARANING O'ZI SAQLANADI: admin (unda kassa cheklovi yo'q)
  --    ixtiyoriy hisob id'sini yuborib BEGONA kassani bo'shata olmaydi.
  -- 🔴 ZAXIRA: qator yo'q / `kassa_scope <> 'list'` / ro'yxat bo'sh ->
  --    ESKI shart AYNAN o'z holicha ishlaydi.
  select * into v_up from user_perms where user_id = s.kimdan_id;
  if found and v_up.kassa_scope = 'list'
     and coalesce(array_length(v_up.op_kassa_ids, 1), 0) > 0 then
    v_ops := v_up.op_kassa_ids;
  end if;

  if v_ops is null then
    if v_gk <> s.kimdan_kassa_id
       and v_acc.parent_id is distinct from s.kimdan_kassa_id then
      raise exception 'Bu hisob sorov kelgan odamning kassalariga tegishli emas'
        using errcode = '42501';
    end if;
  -- `coalesce(..., false)` — massivda null bo'lsa `= any` null qaytaradi
  -- va `not null` tekshiruvdan JIM o'tib ketardi (fail-closed).
  elsif not coalesce(perm_op_key(v_gk) = any (v_ops), false) then
    raise exception 'Bu hisob sorov kelgan odamning kassalariga tegishli emas'
      using errcode = '42501';
  end if;
  -- Ruxsat: `sorov_qaror_ctx.hisoblar` bilan AYNAN bir xil predikat
  if not perm_check_accounts(array[v_gk]) then
    raise exception 'Bu kassada amaliyot qilish huquqingiz yoq' using errcode = '42501';
  end if;
  v_bal := sorov_kassa_bal(v_gk);
  if v_bal < p_summa then
    raise exception 'Tanlangan hisobda pul yetmaydi (qoldiq: %)', v_bal using errcode = '22000';
  end if;

  -- ---- Pul provodkasi: Dt so'rovchi kassasi / Kt tasdiqlovchi kassasi
  -- 8.2 (3) — ext_ref UNIQUE: ikkinchi provodka bazaga kirmaydi
  insert into entry (entry_date, description, source, status, ext_ref)
  values ((now() at time zone 'Asia/Tashkent')::date,
          'Pul sorovi: ' || s.izoh,
          'manual',
          'posted',
          'sorov:' || s.id::text || ':jonatma')
  returning id into v_entry;

  -- 🔴 TARTIB MUHIM: `entry_line` dan OLDIN `sorovlar` yangilanadi —
  --    4-BO'LIM dagi guard istisnosi aynan `jonatma_entry_id` bog'lanishini
  --    qidiradi. Teskari tartibda tasdiqlash 42501 bilan yiqilardi.
  v_holat := case when p_summa = s.summa then 'tasdiq' else 'qisman' end;

  update sorovlar
     set jonatma_entry_id = v_entry,
         status           = v_holat,
         jonatilgan_summa = p_summa,
         -- 🔴 HAQIQATDA ishlatilgan hisob yoziladi. IKKI sabab:
         --    (1) guard istisnosi (4-BO'LIM) aynan shu ustunga qaraydi —
         --        tur-bolasidan to'langanda ham u ro'yxatda bo'lsin;
         --    (2) audit: keyin "pul qaysi hisobdan chiqdi" savoliga
         --        javob qatorning o'zida turadi.
         kimdan_kassa_id  = v_gk,
         decided_at       = now(),
         decided_by       = v_uid
   where id = s.id;

  -- 🔴 MANZIL (Dt) — 2026-08-26, PROVODKA_SOROV_KASSA.sql. IKKI XIL YO'L:
  --      xarajatga BOG'LANGAN so'rov -> `s.kassa_id` (o'zgarmaydi, pastdagi sabab)
  --      sof TOP-UP                  -> manba pul turiga MOS bola, topilmasa ildiz
  -- ⚠️ `s.kassa_id` USTUNI ikkala yo'lda ham TEGILMAYDI (audit uchun saqlanadi).
  -- 🔴🔴 XARAJATGA BOG'LANGAN so'rovda MANZIL O'ZGARMAYDI — aynan `s.kassa_id`.
  --    SABAB (QA topilmasi): 8.6 pending xarajatni yopishdan oldin
  --    `sorov_kassa_bal(s.kassa_id)` ni tekshiradi, u esa OILANI EMAS,
  --    BITTA hisobni sanaydi (3.2). Pulni boshqa hisobga (bolaga) tushirsak
  --    `s.kassa_id` qoldig'i o'smaydi -> xarajat MANGU pending qolardi
  --    ('qoldiq_yetmadi'), ya'ni "Pul so'rash" ning asosiy oqimi buzilardi.
  --    Xarajat qaysi hisobdan yozilgan bo'lsa, pul O'SHA hisobga qaytadi —
  --    bu mantiqan ham to'g'ri (hodim naqd sarfladi -> naqdiga tushsin).
  if s.xarajat_entry_id is not null then
    v_dt := s.kassa_id;
  else
    -- Sof TOP-UP (xarajatga bog'lanmagan): 8.6 umuman ishlamaydi, shuning
    -- uchun manzilni manba pul turiga moslash xavfsiz va Asilbek talabiga mos:
    -- "Toshkent · Naqd" dan berilsa so'rovchining "· Naqd" hisobiga tushsin.
    -- 🔴 Manba ILDIZ bo'lsa (`pul_turi is null`) moslashuv UMUMAN qilinmaydi.
    --    Aks holda predikat `c.pul_turi is null` ga aylanib, pul-turisiz UZS
    --    bolasi bo'lsa pul jimgina o'sha yerga ketardi — kutilgani esa ildiz.
    if v_acc.pul_turi is not null then
      select c.id into v_dt
        from accounts c
       where c.parent_id = s.kassa_id
         and c.pul_turi = v_acc.pul_turi
         and c.is_active is true
         and c.type = 'aktiv'
         and c.code like '5%'
         and coalesce(c.currency, 'UZS') = 'UZS'
         and c.kassa_turi is distinct from 'xarajat_guruh'
       order by c.code
       limit 1;
    end if;
    v_dt := coalesce(v_dt, s.kassa_id);   -- mos bola yo'q -> ildiz (eski xatti-harakat)
  end if;

  insert into entry_line (entry_id, account_id, debit, credit)
  values (v_entry, v_dt,  p_summa, 0),
         (v_entry, v_gk,  0,       p_summa);

  -- 8.6 — pending xarajatni yopish (faqat pul yetsa VA to'siq bo'lmasa)
  if s.xarajat_entry_id is not null and v_est = 'pending' then
    -- Bu tranzaksiyada yozilgan pul allaqachon 'posted' — qoldiqqa kiradi.
    -- 🔴 `v_xar > 0` SHART: yozuv tahrirlanib boshqa kassaga ko'chirilgan
    --    bo'lsa v_xar = 0 bo'lardi va biz begona yozuvni "posted" qilib
    --    yuborardik. Nol bo'lsa — tegmaymiz, pending qoladi.
    if v_xar > 0 and sorov_kassa_bal(s.kassa_id) >= v_xar then
      -- 🔴 8A: OYLIK LIMIT / QOLDIQ QOROVULI (QA topilmasi 2026-08-26).
      --    `limit_guard_entry_line` `entry_line` da turadi va pending
      --    satrni o'tkazib yuboradi; `status` yangilanganda esa
      --    `entry_line` o'zgarmagani uchun u QAYTA ISHLAMAYDI. Ya'ni
      --    "Pul so'rash" yo'li limitni butunlay chetlab o'tardi.
      --    🔴 PUL BARIBIR JO'NATILADI (u alohida qaror va allaqachon
      --    yozilgan) — faqat XARAJAT pending qoladi va javob buni
      --    ochiq aytadi. Trigger bilan qilib bo'lmasdi: u butun
      --    tranzaksiyani, pul jo'natishni ham, orqaga qaytarardi.
      v_tosiq := sorov_post_tosiq(s.xarajat_entry_id);
      if v_tosiq is null then
        update entry set status = 'posted' where id = s.xarajat_entry_id;
        v_yopdi := true;
        -- 🔴 8A.3: Telegram xabari. `entry_line` triggeri yozuv PENDING
        --    paytida ishlagan va `_hodim_notify_qoy` uni tashlab yuborgan
        --    (`status <> 'posted'`), ya'ni busiz so'rovlar oqimidan
        --    o'tgan HAR QANDAY xarajat alertdan ko'rinmas bo'lardi.
        --    Funksiya o'zi fail-open: xabar tizimi yo'q bo'lsa jim o'tadi.
        perform sorov_notify_post(s.xarajat_entry_id);
      end if;
    end if;
  end if;

  update sorovlar set xarajat_yopildi = v_yopdi where id = s.id;

  return jsonb_build_object(
    'ok',               true,
    'holat',            v_holat,
    'jonatilgan_summa', p_summa,
    'jonatma_entry_id', v_entry,
    'tolov_hisob',      v_gk,
    'xarajat_yopildi',  v_yopdi,
    -- 🔴 8A: xarajat POSTED qilinmadi, chunki limit/qoldiq to'sdi.
    --    Pul esa JO'NATILDI — klient ikkalasini ham aytishi shart.
    'limit_oshdi',      (v_tosiq is not null),
    'limit_sabab',      v_tosiq,
    -- UI shuni yozadi: "Pul jonatildi, lekin xarajat hamon tasdiq kutmoqda".
    -- ⚠️ MA'NOSI KENGAYDI: "xarajat pending qoldi" (sabab qoldiq YOKI
    --    limit). Aniq sababi `limit_sabab` da. Ataylab shunday: PRODDAGI
    --    `sorovlar.html` faqat shu kalitni biladi va u bo'lmasa
    --    foydalanuvchi HECH QANDAY ogohlantirish ko'rmasdi.
    'qoldiq_yetmadi',   (s.xarajat_entry_id is not null and v_est = 'pending' and not v_yopdi));

exception
  -- Poyga: bir vaqtda ikki chaqiruv qulfdan o'tib ketsa ham ikkinchi
  -- provodka ext_ref UNIQUE ga urilib qaytadi — pul ikki marta chiqmaydi.
  when unique_violation then
    return jsonb_build_object('ok', false, 'kod', 'already_decided',
                              'holat', 'tasdiq');
end $fn$;

revoke all on function sorov_tasdiq(uuid, numeric, uuid) from public, anon;
grant execute on function sorov_tasdiq(uuid, numeric, uuid) to authenticated;

comment on function sorov_tasdiq(uuid, numeric, uuid) is
  'Pul jonatish (toliq yoki qisman) + pending xarajatni yopish. Sorov kelgan odam YOKI admin. '
  'p_kassa — qaysi hisobdan tolanadi (sorov kelgan odamning HAR QANDAY UZS kassasi yoki uning '
  'tur-bolasi; null -> kimdan_kassa_id). Pul manba pul turiga MOS bolaga tushadi (2026-08-26). '
  'Idempotent: for update + status tekshiruvi + ext_ref UNIQUE.';

-- #####################################################################
-- ##  3-QADAM — perm_guard_entry_line(): ISTISNO DOIRASI (MAJBURIY)   ##
-- #####################################################################
-- 🔴 NEGA BU YERDA (2-qadamning MAJBURIY hamrohi — busiz xususiyat o'lik):
--   4-BO'LIM dagi istisno `new.account_id in (s.kassa_id, s.kimdan_kassa_id)`
--   deb yozilgan. 2-qadamdan keyin Dt satri so'rovchining ILDIZ hisobi
--   emas, uning "· Naqd" BOLASI bo'lishi mumkin. Tasdiqlovchi (admin
--   emas, oddiy hodim) so'rovchining hisobiga huquqsiz -> 1-qoida
--   (`perm_check_accounts`) rad etadi -> istisno ham mos kelmaydi ->
--   BUTUN TASDIQLASH 42501 bilan yiqilardi.
--
-- 🔴 DOIRA KENGAYMAYDI: `perm_op_key` bolani PARENTGA ko'taradi, ya'ni
--   ruxsat berilgan to'plam AYNAN o'sha ikki kassaning OILASI. Qolgan
--   uch shart (`kimdan_id = auth.uid()`, `decided_at = now()` — faqat
--   `sorov_tasdiq` ning O'Z tranzaksiyasi, va summa tengligi) BUZILMADI.
--
-- ⚠️ Trigger QAYTA YARATILMAYDI (`drop trigger` yo'q) — `create or replace`
--    funksiya OID ini saqlaydi, mavjud trigger avtomat yangi tanaga o'tadi.
-- #####################################################################

create or replace function perm_guard_entry_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_lbl text;
  v_ok  boolean;
begin
  -- 1) ESKI QOIDA — o'zgarmagan
  if perm_check_accounts(array[new.account_id]) then
    return new;
  end if;

  -- 2) SO'ROV ISTISNOSI (faqat shu — rad etish — yo'lida)
  begin
    select exists (
      select 1
        from sorovlar s
       where s.jonatma_entry_id = new.entry_id
         and s.kimdan_id = auth.uid()
         -- 🔴 2026-08-26 (PROVODKA_SOROV_KASSA.sql): Dt endi so'rovchining
         --    ILDIZ hisobi emas, pul turiga MOS BOLASI bo'lishi mumkin
         --    ("· Naqd"). `perm_op_key` bolani parentga ko'taradi, ya'ni
         --    doira AYNAN o'sha ikki kassa OILASI bilan cheklangan —
         --    kengaytirilmaydi. Busiz tasdiqlash 42501 bilan yiqilardi.
         and (new.account_id in (s.kassa_id, s.kimdan_kassa_id)
              or perm_op_key(new.account_id) in (s.kassa_id, s.kimdan_kassa_id))
         -- 🔴 VAQT CHEGARASI — istisnoning eng muhim sharti.
         --    `now()` = transaction_timestamp(), `sorov_tasdiq` esa
         --    `decided_at = now()` ni AYNI SHU tranzaksiyada yozadi.
         --    Ya'ni tenglik faqat `sorov_tasdiq` ning o'z tranzaksiyasi
         --    ichida rost bo'ladi, undan keyingi HAR QANDAY tranzaksiyada
         --    yolg'on.
         --    Busiz tasdiqlovchi keyinchalik o'sha `entry_id` ga
         --    to'g'ridan `entry_line` yozib (PostgREST orqali) so'rovchi
         --    kassasidan CHEKLOVSIZ pul ko'chira olardi — pul qorovuli
         --    butunlay chetlab o'tilardi.
         and s.decided_at = now()
         -- 🔴 SUMMA CHEGARASI (ikkinchi qavat): satr aynan jo'natilgan
         --    summaga teng bo'lsin. `sorov_tasdiq` ikkala satrni ham
         --    `p_summa` bilan yozadi (Dt yoki Kt), ya'ni yig'indi har
         --    doim `jonatilgan_summa` ga teng.
         and (coalesce(new.debit, 0) + coalesce(new.credit, 0)) = s.jonatilgan_summa
    ) into v_ok;
  exception when undefined_table or undefined_column then
    -- Jadval yo'q (bu fayl RUN qilinmagan) — eski xatti-harakat
    v_ok := false;
  end;

  if coalesce(v_ok, false) then
    return new;
  end if;

  -- 3) RAD ETISH — matn va kod AYNAN eskisi
  select coalesce(a.code || ' ' || a.name, new.account_id::text)
    into v_lbl from accounts a where a.id = new.account_id;

  raise exception 'Ruxsat yoq: % kassasida amaliyot qilish huquqingiz yoq', v_lbl
    using errcode = '42501';
end $fn$;

revoke all on function perm_guard_entry_line() from public, anon;

comment on function perm_guard_entry_line() is
  'user_perms boyicha pul hisoblarini tosadi. service_role (n8n) va admin otadi. '
  'ISTISNO: sorov_tasdiq yozgan pul provodkasi (sorovlar.jonatma_entry_id bilan tasdiqlanadi). '
  '2026-08-26: istisno hisobning pul-turi BOLASINI ham qamraydi (perm_op_key bilan, ayni oila).';


-- #####################################################################
-- ##  4-QADAM — TEKSHIRUV (RUN dan keyin, xato qaytmasligi kerak)     ##
-- #####################################################################

-- 4.0  🔴🔴 OLD SHART — BUNI BIRINCHI RUN QILING.
--      Butun o'zgarish `perm_op_key()` ning pul-turi bolasini PARENTGA
--      ko'taradigan versiyasiga tayanadi (PROVODKA_PERM_TUR_FIX.sql).
--      Agar bazada eski versiya tursa (u faqat `currency <> 'UZS'` ni
--      ko'taradi), unda:
--        · 1-QADAM ro'yxatida pul-turi bolalari UMUMAN ko'rinmaydi;
--        · 3-QADAM guard tuzatishi no-op bo'ladi va Dt "· Naqd" bo'lgan
--          har bir tasdiqlash 42501 bilan yiqiladi (pul harakat qilmaydi).
--      `tur_fix_run` FALSE chiqsa — avval PROVODKA_PERM_TUR_FIX.sql ni
--      RUN qiling, keyin shu faylni.
select p.prosrc like '%pul_turi%' as tur_fix_run
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'perm_op_key';
-- Kutilgan: tur_fix_run = true

-- 4.1  Uch funksiya ham joyida va yangi tanadami.
select p.proname,
       pg_get_function_identity_arguments(p.oid) as argumentlar,
       (pg_get_functiondef(p.oid) like '%guruh_id%')         as ctx_yangi,
       (pg_get_functiondef(p.oid) like '%v_dt%')             as tasdiq_yangi,
       (pg_get_functiondef(p.oid) like '%perm_op_key(new.account_id)%') as guard_yangi
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('sorov_qaror_ctx', 'sorov_tasdiq', 'perm_guard_entry_line')
 order by p.proname;
-- Kutilgan: sorov_qaror_ctx -> ctx_yangi = true
--           sorov_tasdiq(uuid, numeric, uuid) -> tasdiq_yangi = true (BITTA qator!)
--           perm_guard_entry_line -> guard_yangi = true

-- 4.2  Trigger hamon o'z joyida (funksiya almashdi, bog'lanish uzilmadi).
select t.tgname, t.tgenabled, c.relname
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
 where t.tgname = 'trg_perm_guard_entry_line';
-- Kutilgan: bitta qator, tgenabled = 'O'

-- 4.3  Odamga qaysi hisoblar ko'rinadi (ADMIN sifatida RUN qiling).
--      <UUID> o'rniga tekshiriladigan hodimning user_id sini qo'ying.
-- select a.code, a.name, a.pul_turi, k.code as ildiz_kod, k.name as ildiz_nom
--   from user_perms up
--   join accounts a
--     on perm_op_key(a.id) = any (up.op_kassa_ids)
--   left join accounts k on k.id = perm_op_key(a.id)
--  where up.user_id = '<UUID>'
--    and a.is_active is true and a.type = 'aktiv' and a.code like '5%'
--    and coalesce(a.currency, 'UZS') = 'UZS'
--    and a.kassa_turi is distinct from 'xarajat_guruh'
--  order by k.code, a.code;
-- Kutilgan: 5 ta ildiz + ularning Naqd/Click/Payme bolalari.

-- 4.4  Ochiq so'rov bo'lsa — modal konteksti (SO'ROV KELGAN ODAM sifatida).
-- select jsonb_pretty(sorov_qaror_ctx('<SOROV_UUID>'));
-- Kutilgan: hisoblar[] uzun, har elementda guruh va guruh_id bor.

-- 4.5  So'rovchining pul-turi bolalari bormi (2-band shu bo'lsa ishlaydi).
-- select p.code as ildiz, p.name, c.code as bola, c.name, c.pul_turi
--   from accounts p join accounts c on c.parent_id = p.id
--  where p.id = '<SOROVCHI_KASSA_UUID>'
--    and coalesce(c.currency, 'UZS') = 'UZS'
--  order by c.code;
-- Bo'sh chiqsa -> pul ILDIZGA tushadi (eski xatti-harakat, bu XATO EMAS).


-- #####################################################################
-- ##  5-QADAM — MA'LUM CHEKLOV (Asilbek qaroriga havola)              ##
-- #####################################################################
-- ⚠️ PUL-TURI MOSLASHUVI FAQAT SOF TOP-UP DA ISHLAYDI.
--    Xarajatga BOG'LANGAN so'rovda pul har doim `s.kassa_id` ga tushadi
--    (ya'ni xarajat qaysi hisobdan yozilgan bo'lsa — o'shanga qaytadi).
--
-- 🔴 BU ATAYLAB, VA UNI "TUZATMANG". Sabab: 8.6 (pending xarajatni yopish)
--    `sorov_kassa_bal(s.kassa_id)` ni tekshiradi, u esa OILANI EMAS, BITTA
--    hisobni sanaydi (3.2). Pulni boshqa hisobga (bolaga) tushirsak
--    `s.kassa_id` qoldig'i o'smaydi va pending xarajat MANGU ochiq qolardi
--    (javobda `qoldiq_yetmadi: true`, UI: "Pul jonatildi, lekin xarajat
--    hamon tasdiq kutmoqda") — ya'ni "Pul so'rash" ning ASOSIY oqimi buzilardi.
--    Shuning uchun `if s.xarajat_entry_id is not null then v_dt := s.kassa_id;`
--    shoxi TEGILMAYDI.
--
--    Agar kelajakda xarajatli so'rovda ham moslashuv kerak bo'lsa, AVVAL
--    8.6 qoldig'i oila bo'yicha yig'iladigan qilinsin (ildiz + bolalari),
--    keyingina bu shox o'zgartirilsin. Tartib teskari bo'lsa — pul chiqadi,
--    xarajat esa pending qolib ketadi.
