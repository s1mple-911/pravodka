-- =====================================================================
-- PROVODKA V8 — 8 ta ish uchun SQL (bosqichlar izoh bilan ajratilgan)
-- ---------------------------------------------------------------------
-- Tartib (brief): 2 (bug) → 5 (hisob type) → 3 (limit reset) → 4 (suv) →
--                 6 (konvert izoh — SQLsiz) → 7 (koridor sozlama) →
--                 1 (hisobot) → 8 (qarzdorlar).
--
-- QOIDA (bitta DB, prod ishlab turibdi): SQL ADDITIVE.
--   * add column if not exists / create table if not exists
--   * yangi funksiya/view yoki `create or replace` ESKI IMZONI SAQLAB
--   * ustun/funksiya O'CHIRISH yoki imzo (argument/tur) O'ZGARTIRISH — TAQIQ
--   * yangi RPC: SECURITY DEFINER + set search_path=public + REVOKE public,anon
--   * entry.created_by = TEXT (ism) — profiles bilan JOIN QILINMAYDI
--
-- Asilbek qo'lda RUN qiladi. Har bosqichni alohida ham ishga tushirsa bo'ladi.
-- =====================================================================


-- #####################################################################
-- ##  2-BOSQICH — BUG: professional'da "Ijara" (9411) saqlanmaydi     ##
-- #####################################################################
-- SQL O'ZGARTIRISH YO'Q — bu bosqich faqat DIAGNOSTIKA.
--
-- Sabab (frontendda topildi va tuzatildi): 9411 moddasida
-- accounts.davr_majburiy = true. professional-dev.html'da davr uchun ikkita
-- native <input type="date"> yonma-yon (flex:1; min-width:0) turardi —
-- mobil ekranda ular qisilib, native kalendar tugmasi kesilib qolardi:
-- sana TANLAB BO'LMASDI → davrOk() hech qachon true bo'lmasdi →
-- "Saqlash" abadiy disabled. 9412 (Ish haqi)da davr_majburiy=false
-- bo'lgani uchun u ishlardi — farq aynan shu bayroqda.
--
-- Tuzatish (frontend, professional-dev.html):
--   * davr uchun hodim-dev.html'dagi ikki oylik O'Z kalendarimiz;
--   * "Shu oy / O'tgan oy / Keyingi oy / Tozalash" tez tugmalari;
--   * Saqlash tugmasi ostida "nega yopiq" izohi (jim disabled qolmaydi).
--
-- Quyidagi SELECT bilan tasdiqlang (hech narsani o'zgartirmaydi):
--   select code, name, type, section,
--          chek_majburiy, izoh_majburiy, davr_majburiy, is_active
--     from accounts
--    where code in ('9411','9412','9413')
--    order by code;
--
-- Kutilgan: 9411 → davr_majburiy = true, 9412 → false.
-- Agar 9411'da davr_majburiy = false chiqsa, sabab boshqa bayroqda
-- (izoh_majburiy) yoki standart_xarajat limitida — quyidagi so'rov ko'rsatadi:
--   select fa.name as filial, ma.code, ma.name, s.limit_uzs
--     from standart_xarajat s
--     join accounts fa on fa.id = s.filial_id
--     join accounts ma on ma.id = s.modda_id
--    where ma.code = '9411';

do $$
declare v_davr boolean; v_izoh boolean;
begin
  select davr_majburiy, izoh_majburiy into v_davr, v_izoh
    from accounts where code = '9411' limit 1;
  if not found then
    raise notice '2-BOSQICH: 9411 hisobi topilmadi (kod boshqacha bo''lishi mumkin).';
  else
    raise notice '2-BOSQICH DIAGNOSTIKA: 9411 davr_majburiy=%, izoh_majburiy=%', v_davr, v_izoh;
  end if;
  raise notice '2-BOSQICH OK: SQL o''zgarishi yo''q — tuzatish frontendda (professional-dev.html).';
end $$;


-- #####################################################################
-- ##  5-BOSQICH — 5 ta hisobni type='xarajat' ga o'tkazish            ##
-- #####################################################################
-- 0130 Mashina va uskunalar, 0140 Mebel va jihozlar, 0150 Transport
-- vositalari, 0200 Amortizatsiya, 2910 Tovarlar — hozir 'aktiv' (yoki
-- boshqa) turida. Ular xarajat modda tanlagichlarida (professional-dev,
-- hodim-dev: `type==='xarajat'`) chiqishi kerak.
--
-- ⚠️ OQIBATLARI (Asilbek shuni xohlaydi — lekin bilib turing):
--   1) BALANS: bu hisoblar AKTIV tomonidan CHIQIB KETADI. Aktiv jami
--      shu hisoblar qoldig'i qadar KAMAYADI. Balans TENGLIGI buzilmaydi:
--      `8710 Yigilgan sof foyda` sintetik qatori (daromad − xarajat)
--      xuddi shu summaga kamayadi. Quyida buni MAJBURIY tekshiramiz —
--      teng bo'lmasa butun bosqich ROLLBACK bo'ladi.
--   2) P&L (hisobot): bu hisoblar endi xarajat qatori bo'lib chiqadi.
--      Zinapoyada `section` bo'yicha guruhlanadi (odatda BOSHQA bo'limi).
--      Ya'ni o'tgan davrlar foydasi ham qayta hisoblanadi — tarixiy
--      hisobotlar bugungidan farq qiladi.
--   3) ⚠️ 0200 AMORTIZATSIYA — KONTR-AKTIV, qoldig'i KREDITDA. Xarajatda
--      summa = debit − kredit bo'lgani uchun u P&L'da MANFIY xarajat
--      bo'lib chiqadi (xarajatni kamaytiradi). Bu buxgalteriya jihatdan
--      noto'g'ri ko'rinadi. Quyida uning qoldig'i NOTICE bilan yoziladi —
--      agar kreditda bo'lsa, 0200'ni alohida ko'rib chiqish kerak
--      (masalan uni o'tkazmaslik yoki alohida section berish).
--   4) v_hisob_royxat (jurnal filtri): 2910 `section='tovar'` bo'lsa
--      "Omborlar" guruhida QOLADI (birinchi moslik yutadi). Qolgan 4 tasi
--      "Boshqa"dan "Xarajat moddasi" guruhiga ko'chadi — kutilgan xatti-harakat.
--   5) Kassa/pul mantig'iga TA'SIR YO'Q: isKassa() `type='aktiv' AND code
--      like '5%'` — bu kodlarning hech biri 5xxx emas.

do $$
declare
  v_codes   text[] := array['0130','0140','0150','0200','2910'];
  c         text;
  v_old     text;
  v_bal     numeric;
  v_a       numeric;
  v_p       numeric;
  v_k       numeric;
  v_diff    numeric;
  v_bugun   date := (now() at time zone 'Asia/Tashkent')::date;
begin
  -- 5.1 OLDIN: har hisobning hozirgi turi + qoldig'i (debit − kredit)
  foreach c in array v_codes loop
    select a.type,
           coalesce((select sum(el.debit) - sum(el.credit)
                       from entry_line el
                       join entry e on e.id = el.entry_id
                      where el.account_id = a.id
                        and e.status = 'posted' and e.is_deleted = false), 0)
      into v_old, v_bal
      from accounts a where a.code = c limit 1;
    if v_old is null then
      raise notice '5-BOSQICH: % hisobi topilmadi — o''tkazildi.', c;
    else
      raise notice '5-BOSQICH OLDIN: % type=% qoldiq(Dt-Kt)=%', c, v_old, v_bal;
      if c = '0200' and v_bal < 0 then
        raise notice '5-BOSQICH ⚠️  0200 qoldig''i KREDITDA (%). P&L''da MANFIY xarajat bo''lib chiqadi.', v_bal;
      end if;
    end if;
  end loop;

  -- 5.2 O'ZGARTIRISH
  update accounts set type = 'xarajat' where code = any(v_codes);
  raise notice '5-BOSQICH: % ta hisob type=''xarajat'' qilindi.',
    (select count(*) from accounts where code = any(v_codes) and type = 'xarajat');

  -- 5.3 KEYIN: balans tengligini MAJBURIY tekshirish (buzilsa hamma narsa rollback)
  select coalesce(sum(case when bolim = 'AKTIV'   then amount end), 0),
         coalesce(sum(case when bolim = 'PASSIV'  then amount end), 0),
         coalesce(sum(case when bolim = 'KAPITAL' then amount end), 0)
    into v_a, v_p, v_k
    from balans(v_bugun);
  v_diff := v_a - (v_p + v_k);
  raise notice '5-BOSQICH KEYIN: AKTIV=% PASSIV=% KAPITAL=% farq=%', v_a, v_p, v_k, v_diff;
  if abs(v_diff) > 1 then
    raise exception '5-BOSQICH: balans buzildi (farq %). Hammasi bekor qilindi — 0200/2910 turini qayta ko''rib chiqing.', v_diff;
  end if;

  raise notice '5-BOSQICH OK: 5 hisob xarajatga o''tdi, balans tengligi saqlandi.';
end $$;

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  3-BOSQICH — Standart limit har oy reset (TEKSHIRUV — SQLsiz)    ##
-- #####################################################################
-- SQL O'ZGARTIRISH YO'Q. Savol: "limitlar har oy boshida 0 dan boshlanadimi?"
-- JAVOB: HA — mexanizm allaqachon oylik va AVTOMAT. Alohida reset ishi,
-- cron yoki "yangi oy" tugmasi KERAK EMAS. Tekshirilgan joylar:
--
--   1) standart_holat(p_oy)  (PROVODKA_V7.sql, 4.1)
--      with oy as (select date_trunc('month', p_oy) ... )
--      sarflandi = shu oy oynasidagi (entry_date >= oy.f and <= oy.t)
--      posted + o'chirilmagan Dt yig'indisi. Ya'ni "sarflandi" HISOBLANADI,
--      hech qayerda SAQLANMAYDI → nolga tushirish uchun yozuv kerak emas.
--
--   2) limit_guard_entry_line() trigger (PROVODKA_V7.sql, 4.3)
--      v_f := date_trunc('month', v_date)  /  v_t := oy oxiri
--      Bu yerda v_date = YANGI yozuvning entry_date'i. Ya'ni sentabr
--      yozuvini tekshirganda faqat sentabr xarajatlari sanaladi —
--      avgustники umuman qo'shilmaydi. TASDIQLANDI.
--
--   3) standart_xarajat.limit_uzs — hech qachon o'zgarmaydi (faqat admin
--      standart_limit_set bilan). Oy almashishi unga tegmaydi. TASDIQLANDI.
--
-- Frontend (standart-dev.html) shu bosqichda tekshirildi va yaxshilandi:
--   * <input type="month" id="oy"> default JORIY oy (init: oyNowStr()) — TO'G'RI edi
--   * qo'shildi: ◀ / ▶ oy tugmalari + "Bu oy" qaytish tugmasi
--   * qo'shildi: "limit har oy 1-sanasida qaytadan boshlanadi" izohi
--   * qo'shildi: karta/detal sarlavhasida oy nomi — "Sarflandi" qaysi oyники
--     ekani hech qachon noaniq qolmaydi
--
-- Qo'lda tekshirish (o'zgartirmaydi) — bir limit bo'yicha 3 oy yonma-yon:
--   select 'o''tgan oy' as oy, * from standart_holat((date_trunc('month', now()) - interval '1 month')::date)
--   union all select 'shu oy',   * from standart_holat(date_trunc('month', now())::date)
--   union all select 'keyingi',  * from standart_holat((date_trunc('month', now()) + interval '1 month')::date);
--   -- limit_uzs uchala qatorda BIR XIL, sarflandi esa har oy boshqacha bo'ladi.

do $$
begin
  if to_regprocedure('public.standart_holat(date)') is null then
    raise exception '3-BOSQICH: standart_holat(date) yo''q — PROVODKA_V7.sql RUN qilinmagan';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'trg_limit_guard_entry_line') then
    raise exception '3-BOSQICH: limit guard trigger yo''q — PROVODKA_V7.sql RUN qilinmagan';
  end if;
  raise notice '3-BOSQICH OK: oylik reset mexanizmi joyida (standart_holat + limit_guard).';
end $$;


-- #####################################################################
-- ##  4-BOSQICH — Kommunalga "Suv" qo'shish                           ##
-- #####################################################################
-- entry.kommunal_turi CHECK ro'yxati: gaz | svet | musor  →  + suv.
-- Bu ADDITIVE: eski qiymatlar ('gaz','svet','musor') o'z holicha qoladi,
-- faqat yangi qiymat ruxsat etiladi. Ustun O'CHIRILMAYDI, turi o'zgarmaydi.
-- kommunal_hisobot(p_from,p_to) `group by turi` bo'lgani uchun 'suv'ni
-- AVTOMAT qamrab oladi — funksiyani qayta yozish shart emas.
--
-- DIQQAT (tartib): avval constraint DROP, keyin ADD. Ikkalasi bitta
-- tranzaksiyada — orada yaroqsiz qiymat kirib qololmaydi.

alter table entry drop constraint if exists entry_kommunal_turi_check;
alter table entry add constraint entry_kommunal_turi_check
  check (kommunal_turi is null or kommunal_turi in ('gaz','svet','musor','suv'));

comment on column entry.kommunal_turi is
  'Kommunal xarajat (9413) turi: gaz|svet|musor|suv. NULL — kommunal emas.';

notify pgrst, 'reload schema';

do $$
declare v_ok boolean;
begin
  -- constraint rostdan 'suv'ni qabul qiladimi — pg_get_constraintdef bilan tekshiramiz
  select pg_get_constraintdef(oid) like '%suv%' into v_ok
    from pg_constraint
   where conrelid = 'public.entry'::regclass and conname = 'entry_kommunal_turi_check';
  if not coalesce(v_ok, false) then
    raise exception '4-BOSQICH: entry_kommunal_turi_check ichida ''suv'' yo''q';
  end if;
  raise notice '4-BOSQICH OK: kommunal turlari — gaz|svet|musor|suv.';
end $$;


-- #####################################################################
-- ##  6-BOSQICH — Konvertdan koridor izohini olib tashlash            ##
-- #####################################################################
-- SQL O'ZGARTIRISH YO'Q — bu bosqich faqat frontend (ko'rinish).
--
-- Nima o'zgardi:
--   * kassa-dev.html konvert modali: "Tayanch: X · ruxsat A – B (±N%)"
--     matni va "koridordan tashqarida" sariq ogohlantirishi ODDIY
--     FOYDALANUVCHIGA KO'RSATILMAYDI. O'rniga neytral izoh:
--     "Kursni kiriting. Kurs odatdagidan sezilarli farq qilsa, so'rov
--      admin tasdig'iga tushadi."
--   * kassa-dev.html pending javobi: "Tayanch kurs ... ruxsat lo – hi"
--     endi faqat adminga.
--   * konvert-dev.html so'rov kartasi: "Tayanch kurs" va "Farq %"
--     kataklari faqat adminga (u tasdiqlaydi — unga kerak).
--   * konvert-dev.html oddiy foydalanuvchida conv_koridor_foiz() umuman
--     CHAQIRILMAYDI.
--
-- HIMOYA YO'QOLMAYDI: koridor tekshiruvi convert_start_v2() ichida,
-- serverda. Chetdan chiqqan kurs baribir pending bo'ladi va pul harakat
-- qilmaydi. O'zgargani — foydalanuvchi chegarani OLDINDAN ko'rmaydi.
--
-- ⚠️ ESLATMA: conv_koridor_foiz() hamon `authenticated` uchun ochiq
-- (7-bosqichda sozlama sahifasi va admin UI shuni o'qiydi). Ya'ni juda
-- qiziquvchan foydalanuvchi RPC'ni to'g'ridan chaqirib foizni bilib
-- olishi mumkin. Buni butunlay yopish kerak bo'lsa — alohida ish:
--     revoke execute on function conv_koridor_foiz() from authenticated;
--     grant  execute on function conv_koridor_foiz() to service_role;
-- lekin unda admin sahifasi ham o'qiy olmaydi (admin-only wrapper kerak).
-- Hozir brief talab qilgani — UI'dan olib tashlash — bajarildi.

do $$
begin
  raise notice '6-BOSQICH OK: SQL o''zgarishi yo''q — koridor UI''dan yashirildi (kassa-dev, konvert-dev).';
end $$;


-- #####################################################################
-- ##  7-BOSQICH — Konvert koridori foizi SOZLAMADAN (admin), 5% → 0.7%##
-- #####################################################################
-- Hozir conv_koridor_foiz() qattiq 5 qaytaradi. Endi u kichik config
-- jadvalidan o'qiydi; admin sozlama-dev.html'dan o'zgartira oladi.
--
-- ⚠️ 0.7% JUDA TOR: 1$ ≈ 12 800 so'm bo'lsa oraliq ≈ 12 710 – 12 890.
-- Ya'ni konvertlarning ancha ko'pi admin tasdig'iga (pending) tushadi.
-- Asilbek shuni xohlaydi. Foizni istalgan payt sozlamadan ko'tarish mumkin.
--
-- IMZO O'ZGARMAYDI: conv_koridor_foiz() → numeric (argumentsiz), oldingidek.
-- convert_start_v2 ichidagi chaqiruv tegilmaydi.

-- 7.1 provodka_config — umumiy kalit/qiymat sozlamalari (kelajakda kengayadi)
create table if not exists provodka_config (
  key        text primary key,
  val        text not null,
  updated_by text,
  updated_at timestamptz default now()
);

comment on table provodka_config is
  'Provodka umumiy sozlamalari (kalit/qiymat). Yozish faqat RPC orqali (admin).';

insert into provodka_config(key, val)
values ('konvert_koridor_foiz', '0.7')
on conflict (key) do nothing;

-- Mavjud DB'da qator allaqachon bo'lsa (masalan eski 5 bilan) — brief 0.7 ni
-- talab qiladi, shuning uchun aniq shu kalitni majburan 0.7 ga tushiramiz.
-- Keyinchalik admin sozlamadan o'zgartirsa, bu skript qayta ishga tushirilmaydi.
update provodka_config
   set val = '0.7', updated_by = 'PROVODKA_V8.sql', updated_at = now()
 where key = 'konvert_koridor_foiz' and val <> '0.7';

-- RLS: o'qish authenticated (admin UI joriy qiymatni ko'rsatadi),
-- yozish policy'si UMUMAN YO'Q — faqat SECURITY DEFINER RPC yozadi.
alter table provodka_config enable row level security;
drop policy if exists cfg_sel on provodka_config;
create policy cfg_sel on provodka_config for select to authenticated using (true);
revoke all on provodka_config from public, anon;
grant select on provodka_config to authenticated;

-- 7.2 conv_koridor_foiz() — endi config'dan o'qiydi (topilmasa 0.7)
-- ESKI IMZO SAQLANADI: () -> numeric. convert_start_v2 shuni chaqiradi.
create or replace function conv_koridor_foiz()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
           (select nullif(val, '')::numeric from provodka_config where key = 'konvert_koridor_foiz'),
           0.7);
$$;

revoke all on function conv_koridor_foiz() from public, anon;
grant execute on function conv_koridor_foiz() to authenticated, service_role;

comment on function conv_koridor_foiz() is
  'Konvert koridori foizi (provodka_config.konvert_koridor_foiz; default 0.7). Yagona manba.';

-- 7.3 set_koridor_foiz(p_foiz) — ADMIN only
create or replace function set_koridor_foiz(p_foiz numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_by text;
begin
  if not is_admin() then
    raise exception 'Faqat admin koridor foizini o''zgartira oladi' using errcode = '42501';
  end if;
  if p_foiz is null or p_foiz <= 0 or p_foiz > 100 then
    raise exception 'Foiz 0 dan katta va 100 dan kichik bo''lishi kerak' using errcode = '22000';
  end if;
  select coalesce(full_name, '') into v_by from profiles where id = auth.uid();
  insert into provodka_config(key, val, updated_by, updated_at)
  values ('konvert_koridor_foiz', p_foiz::text, v_by, now())
  on conflict (key) do update
    set val = excluded.val, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  return p_foiz;
end $$;

revoke all on function set_koridor_foiz(numeric) from public, anon;
grant execute on function set_koridor_foiz(numeric) to authenticated;

comment on function set_koridor_foiz(numeric) is
  'Konvert koridori foizini o''zgartiradi (admin only). sozlama-dev.html shuni chaqiradi.';

notify pgrst, 'reload schema';

do $$
declare v numeric;
begin
  if to_regclass('public.provodka_config') is null then
    raise exception '7-BOSQICH: provodka_config jadvali yaratilmadi';
  end if;
  if to_regprocedure('public.set_koridor_foiz(numeric)') is null then
    raise exception '7-BOSQICH: set_koridor_foiz(numeric) yaratilmadi';
  end if;
  select conv_koridor_foiz() into v;
  if v is null then raise exception '7-BOSQICH: conv_koridor_foiz() null qaytardi'; end if;
  if v <> 0.7 then
    raise notice '7-BOSQICH ⚠️  conv_koridor_foiz() = % (0.7 emas) — config qatorini tekshiring.', v;
  end if;
  raise notice '7-BOSQICH OK: koridor foizi sozlanadigan bo''ldi, joriy qiymat = %', v;
end $$;


-- #####################################################################
-- ##  1-BOSQICH — Hisobot sahifasi (filtrli jurnal + xarajat totallar)##
-- #####################################################################
-- hisobot-dev.html Aros hisobotiga o'xshash bo'ladi:
--   filtr: sana oralig'i + kassa + tur (kirim/chiqim/xarajat/tushum/transfer)
--   tepada: tanlangan xarajat turlari bo'yicha jami (filtrlarga bo'ysunadi)
--   pastda: jurnal ko'rinishidagi ro'yxat (# / Sana / Kt / Dt / Summa / Maqsad)
--
-- TUR TASNIFI — jurnal.klass() bilan bir xil mantiq, lekin SERVERDA:
--   n_lines > 2                        -> boshqa     (ko'p satrli, Professional)
--   Dt pul  va Kt pul                  -> transfer
--   Dt pul  va Kt daromad              -> tushum     ("kassa tushum")
--   Dt pul                             -> kirim      (boshqa pul kirimi)
--   Kt pul  va Dt xarajat              -> xarajat
--   Kt pul                             -> chiqim     (boshqa pul chiqimi)
--   aks holda                          -> boshqa     (neytral: ombor -> tannarx)
-- Turlar O'ZARO KESISHMAYDI — shuning uchun turlar bo'yicha jami = umumiy jami.
-- "boshqa" ataylab bor: aks holda neytral yozuvlar jimgina yo'qolib ketardi.
--
-- O'CHIRILGAN yozuvlar hisobotga KIRMAYDI (is_deleted=false) — jurnaldan farqi
-- shu: jurnal ularni usti chizilgan holda ko'rsatadi, hisobot esa hisobot.
--
-- RUXSAT: RPC'lar SECURITY DEFINER, shuning uchun ruxsat SERVERDA majburlanadi
-- (klient p_accounts'ni o'zgartirsa ham foyda bermaydi) — perm_view_pul_ids()
-- bilan kesishtiriladi. Bu jurnal.html'dagi klient-filtridan KUCHLIROQ.

-- 1.1 perm_view_pul_ids() — caller KO'RA oladigan pul hisoblari (null = cheklovsiz)
create or replace function perm_view_pul_ids()
returns uuid[]
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare p user_perms; v uuid[];
begin
  if auth.uid() is null then return null; end if;      -- service_role / n8n
  if is_admin() then return null; end if;
  select * into p from user_perms where user_id = auth.uid();
  if not found or p.kassa_scope <> 'list' then return null; end if;
  select array_agg(a.id) into v
    from accounts a
   where a.type = 'aktiv' and a.code like '5%'
     and a.kassa_turi is distinct from 'xarajat_guruh'
     and perm_op_key(a.id) = any(p.view_kassa_ids);
  return coalesce(v, '{}'::uuid[]);                    -- bo'sh massiv = hech narsa ko'rmaydi
end $fn$;

revoke all on function perm_view_pul_ids() from public, anon;
grant execute on function perm_view_pul_ids() to authenticated, service_role;

comment on function perm_view_pul_ids() is
  'Caller ko''ra oladigan pul hisoblari (view_kassa_ids). NULL = cheklovsiz (admin/qatorsiz).';

-- 1.2 hisobot_acc(p_accounts) — ICHKI: ruxsat bilan kesishtirish
create or replace function hisobot_acc(p_accounts uuid[])
returns uuid[]
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_perm uuid[] := perm_view_pul_ids();
begin
  if v_perm is null then return p_accounts; end if;                  -- cheklovsiz
  if p_accounts is null then return v_perm; end if;                  -- faqat o'z kassalari
  return array(select unnest(p_accounts) intersect select unnest(v_perm));
end $fn$;

revoke all on function hisobot_acc(uuid[]) from public, anon, authenticated;

comment on function hisobot_acc(uuid[]) is
  'ICHKI: so''ralgan kassalarni caller ruxsati bilan kesishtiradi (server tomonda majburlash).';

-- 1.3 hisobot_baza(...) — ICHKI: filtrlangan yozuvlar + tur tasnifi
-- ---------------------------------------------------------------------
-- Uchala ochiq RPC (royxat / xulosa / modda_total) SHU bitta manbadan oziqlanadi —
-- ya'ni ro'yxatdagi qatorlar bilan yuqoridagi totallar hech qachon farq qilmaydi.
-- Ruxsat bu yerda TEKSHIRILMAYDI (wrapper hisobot_acc() bilan kesishtirib beradi) —
-- shuning uchun authenticated'ga execute BERILMAYDI.
create or replace function hisobot_baza(
  p_from date, p_to date, p_accounts uuid[], p_turlar text[])
returns table(
  id uuid, entry_date date, created_at timestamptz, description text,
  edited_at timestamptz, edited_by_name text,
  n_lines int, summa numeric, tur text,
  dt_id uuid, dt_code text, dt_name text, dt_sub text, dt_sec text, dt_type text,
  kt_id uuid, kt_code text, kt_name text, kt_sub text, kt_sec text, kt_type text,
  filial_nomlari text[], davr_start date, davr_end date, kommunal_turi text, yuk_ids jsonb
)
language sql
stable
security definer
set search_path = public
as $fn$
  with e as (
    select en.id, en.entry_date, en.created_at, en.description,
           en.edited_at, en.edited_by_name,
           en.filial_ids, en.davr_start, en.davr_end, en.kommunal_turi, en.yuk_ids
      from entry en
     where en.status = 'posted' and en.is_deleted = false
       and en.entry_date >= p_from and en.entry_date <= p_to
       and (p_accounts is null or exists (
             select 1 from entry_line el
              where el.entry_id = en.id and el.account_id = any(p_accounts)))
  ),
  c as (
    select e.*,
           (select count(*)::int from entry_line l where l.entry_id = e.id) as n_lines,
           (select coalesce(sum(l.debit), 0)::numeric from entry_line l where l.entry_id = e.id) as summa,
           d.account_id as dt_id, d.code as dt_code, d.name as dt_name,
           d.subtitle  as dt_sub, d.section as dt_sec, d.type as dt_type,
           k.account_id as kt_id, k.code as kt_code, k.name as kt_name,
           k.subtitle  as kt_sub, k.section as kt_sec, k.type as kt_type
      from e
      left join lateral (
        select l.account_id, a.code, a.name, a.subtitle, a.section, a.type
          from entry_line l join accounts a on a.id = l.account_id
         where l.entry_id = e.id and l.debit > 0
         order by l.debit desc limit 1) d on true
      left join lateral (
        select l.account_id, a.code, a.name, a.subtitle, a.section, a.type
          from entry_line l join accounts a on a.id = l.account_id
         where l.entry_id = e.id and l.credit > 0
         order by l.credit desc limit 1) k on true
  ),
  t as (
    select c.*,
           case
             when c.n_lines > 2                              then 'boshqa'
             when c.dt_sec = 'pul' and c.kt_sec = 'pul'      then 'transfer'
             when c.dt_sec = 'pul' and c.kt_type = 'daromad' then 'tushum'
             when c.dt_sec = 'pul'                           then 'kirim'
             when c.kt_sec = 'pul' and c.dt_type = 'xarajat' then 'xarajat'
             when c.kt_sec = 'pul'                           then 'chiqim'
             else 'boshqa'
           end as tur
      from c
  )
  select t.id, t.entry_date, t.created_at, t.description,
         t.edited_at, t.edited_by_name,
         t.n_lines, t.summa, t.tur,
         t.dt_id, t.dt_code, t.dt_name, t.dt_sub, t.dt_sec, t.dt_type,
         t.kt_id, t.kt_code, t.kt_name, t.kt_sub, t.kt_sec, t.kt_type,
         (select array_agg(a.name order by a.name) from accounts a where a.id = any(t.filial_ids)) as filial_nomlari,
         t.davr_start, t.davr_end, t.kommunal_turi,
         to_jsonb(coalesce(t.yuk_ids, '{}')) as yuk_ids
    from t
   where p_turlar is null or t.tur = any(p_turlar);
$fn$;

revoke all on function hisobot_baza(date, date, uuid[], text[]) from public, anon, authenticated;

comment on function hisobot_baza(date, date, uuid[], text[]) is
  'ICHKI: hisobot uchun filtrlangan yozuvlar + tur tasnifi. Faqat hisobot_* wrapperlari chaqiradi.';

-- 1.4 hisobot_royxat(...) — jurnal ko'rinishidagi ro'yxat (sahifalangan)
create or replace function hisobot_royxat(
  p_from date, p_to date,
  p_accounts uuid[] default null,
  p_turlar   text[] default null,
  p_limit    int    default 200,
  p_offset   int    default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_acc uuid[]; v_out jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  v_acc := hisobot_acc(p_accounts);

  select coalesce(jsonb_agg(to_jsonb(r) order by r.entry_date desc, r.created_at desc), '[]'::jsonb)
    into v_out
    from (
      select b.*,
             -- satrlar faqat ko'p satrli yozuv uchun (javob yengil qolsin)
             case when b.n_lines > 2 then (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'code', a.code, 'name', a.name, 'section', a.section,
                        'currency', a.currency, 'debit', l.debit, 'credit', l.credit,
                        'fc_amount', l.fc_amount) order by l.debit desc), '[]'::jsonb)
                 from entry_line l join accounts a on a.id = l.account_id
                where l.entry_id = b.id)
             else '[]'::jsonb end as lines
        from hisobot_baza(p_from, p_to, v_acc, p_turlar) b
       order by b.entry_date desc, b.created_at desc
       limit  greatest(coalesce(p_limit, 200), 1)
       offset greatest(coalesce(p_offset, 0), 0)
    ) r;

  return v_out;
end $fn$;

revoke all on function hisobot_royxat(date, date, uuid[], text[], int, int) from public, anon;
grant execute on function hisobot_royxat(date, date, uuid[], text[], int, int) to authenticated;

comment on function hisobot_royxat(date, date, uuid[], text[], int, int) is
  'Hisobot royxati: filtrlangan yozuvlar (jurnal korinishi), sahifalangan.';

-- 1.5 hisobot_xulosa(...) — tur bo'yicha soni/summa + umumiy jami
-- `turlar` HAMMA turni qaytaradi (p_turlar'siz) — chiplarda sanoq korsatish uchun;
-- jami_* esa tanlangan turlar bo'yicha.
create or replace function hisobot_xulosa(
  p_from date, p_to date,
  p_accounts uuid[] default null,
  p_turlar   text[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_acc uuid[]; v_turlar jsonb; v_soni int; v_summa numeric;
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  v_acc := hisobot_acc(p_accounts);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.summa desc), '[]'::jsonb) into v_turlar
    from (
      select b.tur, count(*)::int as soni, coalesce(sum(b.summa), 0)::numeric as summa
        from hisobot_baza(p_from, p_to, v_acc, null) b
       group by b.tur
    ) x;

  select count(*)::int, coalesce(sum(b.summa), 0)::numeric
    into v_soni, v_summa
    from hisobot_baza(p_from, p_to, v_acc, p_turlar) b;

  return jsonb_build_object('jami_soni', v_soni, 'jami_summa', v_summa, 'turlar', v_turlar);
end $fn$;

revoke all on function hisobot_xulosa(date, date, uuid[], text[]) from public, anon;
grant execute on function hisobot_xulosa(date, date, uuid[], text[]) to authenticated;

comment on function hisobot_xulosa(date, date, uuid[], text[]) is
  'Hisobot xulosasi: tur boyicha soni/summa (hamma tur) + tanlangan turlar boyicha jami.';

-- 1.6 hisobot_modda_total(...) — tanlangan xarajat moddalari bo'yicha jami
-- Tepadagi "Ijara: 5 000 000" kartalari uchun YENGIL so'rov. Filtrlarga bo'ysunadi.
create or replace function hisobot_modda_total(
  p_from date, p_to date,
  p_moddalar uuid[],
  p_accounts uuid[] default null,
  p_turlar   text[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_acc uuid[]; v_out jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'Sana oraligi berilmadi' using errcode = '22000';
  end if;
  if p_moddalar is null or array_length(p_moddalar, 1) is null then
    return '[]'::jsonb;
  end if;
  v_acc := hisobot_acc(p_accounts);

  with b as (select * from hisobot_baza(p_from, p_to, v_acc, p_turlar))
  select coalesce(jsonb_agg(to_jsonb(r) order by r.summa desc), '[]'::jsonb) into v_out
    from (
      select a.id as account_id, a.code, a.name,
             coalesce((select sum(l.debit) from entry_line l join b on b.id = l.entry_id
                        where l.account_id = a.id and l.debit > 0), 0)::numeric as summa,
             coalesce((select count(distinct l.entry_id) from entry_line l join b on b.id = l.entry_id
                        where l.account_id = a.id and l.debit > 0), 0)::int as soni
        from accounts a
       where a.id = any(p_moddalar)
    ) r;

  return v_out;
end $fn$;

revoke all on function hisobot_modda_total(date, date, uuid[], uuid[], text[]) from public, anon;
grant execute on function hisobot_modda_total(date, date, uuid[], uuid[], text[]) to authenticated;

comment on function hisobot_modda_total(date, date, uuid[], uuid[], text[]) is
  'Tanlangan xarajat moddalari boyicha davr jami (hisobot filtrlariga boysunadi).';

notify pgrst, 'reload schema';

do $$
begin
  if to_regprocedure('public.perm_view_pul_ids()') is null then raise exception '1-BOSQICH: perm_view_pul_ids yoq'; end if;
  if to_regprocedure('public.hisobot_acc(uuid[])') is null then raise exception '1-BOSQICH: hisobot_acc yoq'; end if;
  if to_regprocedure('public.hisobot_baza(date,date,uuid[],text[])') is null then raise exception '1-BOSQICH: hisobot_baza yoq'; end if;
  if to_regprocedure('public.hisobot_royxat(date,date,uuid[],text[],int,int)') is null then raise exception '1-BOSQICH: hisobot_royxat yoq'; end if;
  if to_regprocedure('public.hisobot_xulosa(date,date,uuid[],text[])') is null then raise exception '1-BOSQICH: hisobot_xulosa yoq'; end if;
  if to_regprocedure('public.hisobot_modda_total(date,date,uuid[],uuid[],text[])') is null then raise exception '1-BOSQICH: hisobot_modda_total yoq'; end if;
  raise notice '1-BOSQICH OK: hisobot RPClari tayyor (royxat / xulosa / modda_total).';
end $$;
