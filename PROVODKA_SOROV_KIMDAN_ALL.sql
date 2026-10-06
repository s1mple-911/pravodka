-- ============================================================================
--  PROVODKA_SOROV_KIMDAN_ALL.sql — 2026-10-06 — «Barcha kassalar» (kassa_scope='all') user ham «Kimdan» ro'yxatida
--  Asilbek: «hamma kassalar deyilgan bo'lsa o'sha hammasini tiqvorsak bo'lmaydimi — hozir scope'ni ochib hammasini
--  qayta tanlab chiqyapman». Abror aka: kassa_scope='all', sorovlar bor, op kassa 0 → ro'yxatda yo'q edi.
--  Eski qoida (PROVODKA_SOROVLAR.sql 5-BO'LIM, DIAG_SOROV_KIMDAN.sql): 'all' user — «pul qaysi kassadan?» noma'lum → chiqarilgan.
--  YANGI qoida: 'all' user = HAMMA UZS kassa unga tegishli (hodim 54xx xarajat kassalaridan tashqari):
--   * sorov_kassa_of('all') → sukut kassa = eng kichik kodli faol UZS ildiz kassa (markaziy birinchi) — faqat sukut/ko'rsatish;
--   * sorov_kimdan() → kassa_scope sharti olib tashlandi (sorovlar sahifasi + sukut kassa yetarli);
--   * sorov_qaror_ctx() hisoblar → all-scope uchun hamma UZS kassa + UZS tur-bolalari (tasdiqlashda o'zi tanlaydi);
--   * sorov_tasdiq() → all-scope uchun oila chegarasi yo'q (perm_check_accounts saqlanadi), 54xx dan to'lanmaydi.
--  sorov_nomzod_ok / sorov_yarat (TOPUP) sorov_kassa_of orqali avtomat. Admin (user_perms qatori yo'q) avvalgidek chiqmaydi.
--  Tanalar PROVODKA_SOROV_KASSA.sql dan VERBATIM + belgilangan qo'shimchalar. Asilbek RUN qiladi.
--  🔴 sorov_kassa_of / sorov_kimdan / sorov_qaror_ctx / sorov_tasdiq ning ENG OXIRGI versiyasi endi SHU faylda.
-- ============================================================================
create or replace function sorov_kassa_of(p_uid uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare p user_perms; v_id uuid;
begin
  if p_uid is null then return null; end if;
  select * into p from user_perms where user_id = p_uid;
  if not found then return null; end if;                 -- admin / qatorsiz: biriktirilgan kassa yo'q

  if p.kassa_scope = 'all' then
    -- 🔴 2026-10-06: hamma kassa tegishli — sukut = markaziy, eng kichik kod (tasdiqlashda o'zi tanlaydi)
    select a.id into v_id
      from accounts a
     where a.is_active is true
       and a.type = 'aktiv'
       and a.code like '5%'
       and coalesce(a.currency, 'UZS') = 'UZS'
       and a.pul_turi is null
       and a.parent_id is null
       and a.kassa_turi is distinct from 'xarajat_guruh'
       and a.kassa_turi is distinct from 'xarajat'
     order by (a.kassa_turi = 'markaziy') desc, a.code
     limit 1;
    return v_id;
  end if;

  if p.kassa_scope <> 'list' then return null; end if;
  select a.id into v_id
    from accounts a
   where a.is_active is true
     and a.type = 'aktiv'
     and a.code like '5%'
     and coalesce(a.currency, 'UZS') = 'UZS'
     and a.pul_turi is null
     and a.kassa_turi is distinct from 'xarajat_guruh'
     and perm_op_key(a.id) = any (p.op_kassa_ids)
   order by a.code
   limit 1;
  return v_id;
end $fn$;
revoke all on function sorov_kassa_of(uuid) from public, anon, authenticated;

create or replace function sorov_kimdan()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.oxirgi_soralgan desc nulls last, x.nom), '[]'::jsonb)
    into v_out
  from (
    select up.user_id,
           k.id                                        as kassa_id,
           sorov_ism(up.user_id, k.id)                 as nom,
           case when up.kassa_scope = 'all' then 'Barcha kassalar'
                else nullif(btrim(coalesce(k.subtitle, '')), '') end as subtitle,
           (select max(s.created_at)::date
              from sorovlar s
             where s.sorovchi_id = v_uid and s.kimdan_id = up.user_id
               and s.created_at >= now() - interval '30 days') as oxirgi_soralgan
      from user_perms up
      join profiles pr on pr.id = up.user_id
      join accounts k on k.id = sorov_kassa_of(up.user_id)   -- 🔴 2026-10-06: 'all' uchun sukut kassa (kassa_scope sharti yo'q)
     where up.user_id <> v_uid
       and 'sorovlar' = any (coalesce(up.allowed_pages, '{}'::text[]))
  ) x;
  return v_out;
end $fn$;
revoke all on function sorov_kimdan() from public, anon;
grant execute on function sorov_kimdan() to authenticated;
comment on function sorov_kimdan() is
  'Kimdan pul sorash mumkin. Nomzod: sorovlar sahifasi + sukut UZS kassa (list: op_kassa_ids; all: markaziy). '
  '2026-10-06: kassa_scope=all userlar ham chiqadi, kassani tasdiqlashda tanlaydi. Admin (qatorsiz) chiqmaydi.';

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
  v_all  boolean := false;   -- 🔴 2026-10-06: so'rov kelgan odam kassa_scope='all' — HAMMA UZS kassa (hodim xarajat kassalaridan tashqari)
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
  if found and v_up.kassa_scope = 'all' then v_all := true; end if;   -- 🔴 2026-10-06

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
          on g.id = case when v_all then perm_op_key(a.id)
                         when v_ops is null then v_root
                         else perm_op_key(a.id) end
       where (case when v_all then a.kassa_turi is distinct from 'xarajat'   -- 🔴 all-scope: hamma kassa (hodim 54xx emas)
                   when v_ops is null
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
  v_all    boolean := false;   -- 🔴 2026-10-06: kimdan kassa_scope='all'
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
  if found and v_up.kassa_scope = 'all' then v_all := true; end if;   -- 🔴 2026-10-06

  if v_all then
    -- all-scope beruvchi: oila chegarasi yo'q — har qanday UZS kassa (hodim xarajat kassasi emas);
    -- perm_check_accounts (pastda) baribir tekshiriladi.
    if v_acc.kassa_turi is not distinct from 'xarajat' then
      raise exception 'Hodim xarajat kassasidan sorov tolanmaydi' using errcode = '42501';
    end if;
  elsif v_ops is null then
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

notify pgrst, 'reload schema';

-- TEKSHIRUV: all-scope + sorovlar userlar endi sukut kassa bilan
select p.full_name, up.kassa_scope, (select name from accounts where id = sorov_kassa_of(p.id)) as sukut_kassa
  from user_perms up join profiles p on p.id = up.user_id
 where 'sorovlar' = any(coalesce(up.allowed_pages,'{}')) order by up.kassa_scope, p.full_name;
