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
