-- =====================================================================
-- PROVODKA_HODIM_TARIX_QARZ.sql
-- Hodim TARIXI va OYLIK JAMISI qarz (6721) satrini ham ko'rsin
-- ---------------------------------------------------------------------
-- ## MUAMMO (QA topdi, tasdiqlangan)
-- `PROVODKA_XARAJAT_QARZ.sql` yoqilgach xarajat yozuvi UCH SATRLI emas,
-- ko'pincha IKKI satrli bo'ladi:
--
--     qoldiq 500k, xarajat 500k  ->  Dt modda 500k / Kt kassa 500k   (eski)
--     qoldiq 200k, xarajat 500k  ->  Dt modda 500k / Kt kassa 200k / Kt 6721 300k
--     qoldiq   0k, xarajat 500k  ->  Dt modda 500k /                  Kt 6721 500k
--
-- Oxirgi shakl — chekka holat EMAS: hodim qo'lidagi pulni sarflab
-- bo'lgach, kassa qoldig'i 0 da qoladi va SHUNDAN KEYINGI HAR xarajat
-- to'liq qarzga tushadi. Ya'ni bu DOIMIY holat.
--
-- Nol satr `entry_line` cheklovi tufayli `where` bilan tushib qoladi
-- (`PROVODKA_XARAJAT_QARZ.sql`, "Uchala satr BITTA insert bilan"), ya'ni
-- yozuvda KASSA Kt SATRI UMUMAN BO'LMAYDI.
--
-- Natijada uchta joy jimgina "ko'r" bo'lib qoladi:
--   1) `hodim_oz_tarix(date,date)`   — ikkala so'rovi ham
--        `join entry_line kl ... and kl.account_id = any(v_ids)`
--      bilan boshlanadi -> kassa Kt satri yo'q yozuv NA ro'yxatga, NA
--      kategoriya taqsimotiga tushadi. Hodim o'z xarajatini KO'RMAYDI.
--   2) `hodim_oy_jami_kop(uuid[],date,date)` va `hodim_oy_jami(uuid,date,date)`
--      — `sum(el.credit)` faqat kassa hisoblari bo'yicha -> "Bu oy
--      sarflandi" kam yoki 0 ko'rsatadi.
--   3) `hodim-dev.html` dagi "To'lanmagan" rozetkasi `histRows` ustiga
--      chiziladi (`renderHistList`) -> qator yo'q bo'lsa rozetka ham yo'q.
--
-- ⚠️ QISMAN holat (kqism>0 va qqism>0) ham ZID: ro'yxat `dl.debit` (to'liq
--    500k) ko'rsatadi, oylik jami esa faqat `kqism` (200k) ni sanaydi.
--
-- ## YECHIM — MANBANI BIRLASHTIRISH
-- To'g'ri manba ALLAQACHON bor: `hodim_balans_bir()` (PROVODKA_XARAJAT_TOSIQ.sql)
-- `xar` CTE da KENGAYTIRILGAN OILA ishlatadi:
--
--     v_ext = kassa oilasi (v_ids) || qarz hisobi (6721)
--
-- Shu sababli 70% to'siq va "Mening hisobim" paneli TO'G'RI ishlaydi.
-- Bu fayl AYNAN o'sha manbani tarix va oylik jamiga ham beradi — ya'ni
-- ikki manba bir-biriga zid raqam bermaydi.
--
-- ## QOIDALAR (buzilmadi)
--   * FAQAT ADDITIVE: `drop` yo'q, ustun qo'shilmaydi/o'chirilmaydi.
--   * 🔴 IMZOLAR BAYT-MA-BAYT O'ZGARMAYDI — uchala funksiyani ham PROD
--     `hodim.html` chaqiradi (argument nomlari PostgREST uchun ham muhim:
--     `p_from`, `p_to`, `p_account`, `p_accounts`). 6-BO'LIM buni katalogdan
--     tekshiradi.
--   * 🔴 REGRESSIYA NOL: qarz hisobi YO'Q hodimda (yoki
--     `PROVODKA_XARAJAT_TOSIQ.sql` RUN QILINMAGAN bazada) natija AYNAN
--     hozirgidek. `hodim_qarz_hisob_topish()` DINAMIK chaqiriladi
--     (`to_regprocedure` + `execute` — `convert_start_v2` naqshi), funksiya
--     yo'q bo'lsa `v_ext = v_ids` bo'lib qoladi. 7-BO'LIMda satrma-satr.
--   * `security definer` + `set search_path = public` + grantlar AYNAN
--     eskisidek qayta beriladi.
--   * `do $$` bloki YO'Q (Supabase editorida 42P01).
--   * Faylda RPC ni JONLI chaqiradigan operator YO'Q — faqat KATALOG va
--     jadval so'rovlari (`PROVODKA_JURNAL_V2.sql` bugun aynan shundan
--     rollback bo'ldi: editorda `auth.uid()` null).
--   * HTML ga TEGILMAGAN.
--
-- ## RUN TARTIBI (Asilbek)
-- 🔴 Bu fayl `PROVODKA_XARAJAT_QARZ.sql` dan KEYIN turadi:
--
--      1) PROVODKA_HODIM_V3.sql / V5.sql / V7.sql   (hodim_oy_jami, hodim_oz_tarix — asosi)
--      2) PROVODKA_HODIM_TEZLIK.sql                 (hodim_oy_jami_kop)
--      3) PROVODKA_XARAJAT_TOSIQ.sql                (6720/6721, qarz, to'siq)
--      4) PROVODKA_XARAJAT_QARZ.sql                 (qarz asosiy oqimda)
--      5) PROVODKA_HODIM_TARIX_QARZ.sql             <-- SHU FAYL, oxirgi
--
--    Agar 1) yoki 2) shu fayldan KEYIN qayta RUN qilinsa — ular eski
--    versiyani tiklaydi va bu faylning ishi YO'QOLADI. U holda shu faylni
--    yana RUN qiling (idempotent, `create or replace`).
--
-- Bo'limlarni BITTALAB, TARTIB BILAN belgilab RUN qiling (1-BO'LIM
-- yordamchilari qolganlaridan OLDIN yaratilishi shart — `language sql`
-- funksiyalar tanasi yaratilish paytida tekshiriladi):
--    0-BO'LIM — OLD SHART tekshiruvi (faqat select, hech narsa o'zgarmaydi)
--    1-BO'LIM — hodim_qarz_map / hodim_qarz_ids  (YANGI yordamchilar)
--    2-BO'LIM — hodim_oz_tarix       (create or replace)
--    3-BO'LIM — hodim_oy_jami_kop    (create or replace)
--    4-BO'LIM — hodim_oy_jami        (create or replace)
--    5-BO'LIM — notify pgrst
--    6-BO'LIM — IMZO va GRANT tekshiruvi (faqat katalog select)
--    7-BO'LIM — nima O'ZGARMADI + dublikat tahlili (faqat izoh)
--    8-BO'LIM — ixtiyoriy DIAGNOSTIKA (faqat jadval select)
--    9-BO'LIM — ROLLBACK
--
-- ## OLD SHARTLAR
--   * `hodim_oz_tarix(date,date)`, `hodim_oy_jami(uuid,date,date)`,
--     `hodim_oy_jami_kop(uuid[],date,date)` mavjud bo'lsin.
--   * `hodim_qarz_hisob_topish(uuid)` — IXTIYORIY. Yo'q bo'lsa bu fayl
--     baribir RUN bo'ladi va natija hozirgidek qoladi (qorovul o'chiradi).
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (hech narsa o'zgarmaydi)       ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 0.1  Kerakli obyektlar o'rnidami?
--      `f_tarix` / `f_oy` / `f_oy_kop` false chiqsa — avval mos faylni
--      RUN qiling (yuqoridagi RUN TARTIBI).
--      `f_qarz_topish` false bo'lsa — XATO EMAS: bu fayl RUN bo'ladi,
--      lekin qarz qo'shilmaydi (natija hozirgidek). Keyin
--      PROVODKA_XARAJAT_TOSIQ.sql RUN qilinsa, SHU FAYLNI qayta RUN
--      qilish SHART EMAS — qorovul ish vaqtida tekshiriladi.
-- ---------------------------------------------------------------------
select to_regprocedure('public.hodim_oz_tarix(date,date)')            is not null as f_tarix,
       to_regprocedure('public.hodim_oy_jami(uuid,date,date)')        is not null as f_oy,
       to_regprocedure('public.hodim_oy_jami_kop(uuid[],date,date)')  is not null as f_oy_kop,
       to_regprocedure('public.hodim_qarz_hisob_topish(uuid)')        is not null as f_qarz_topish,
       to_regprocedure('public.hodim_kassa_ildiz(uuid)')              is not null as f_ildiz,
       exists (select 1 from accounts where code = '6720')                        as a_6720;


-- ---------------------------------------------------------------------
-- 0.2  Overload bormi? (PostgREST PGRST203 xavfi)
--      Kutilgan: har `proname` uchun AYNAN 1 qator.
-- ---------------------------------------------------------------------
select p.proname,
       count(*)                                            as overload_soni,
       string_agg(pg_get_function_arguments(p.oid), ' | ') as imzolar
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('hodim_oz_tarix', 'hodim_oy_jami', 'hodim_oy_jami_kop')
 group by p.proname
 order by p.proname;


-- ---------------------------------------------------------------------
-- 0.3  Nomlar bo'shmi? (1-BO'LIM ikkita YANGI funksiya yaratadi)
--      Kutilgan: ikkalasi ham `false`. `true` chiqsa — nom band, MENGA
--      AYTING (boshqa faylda o'sha nom bor degani, ustiga yozmang).
-- ---------------------------------------------------------------------
select to_regprocedure('public.hodim_qarz_map(uuid[])') is not null as band_map,
       to_regprocedure('public.hodim_qarz_ids(uuid[])') is not null as band_ids;


-- #####################################################################
-- ##  1-BO'LIM — YANGI YORDAMCHILAR (qorovul BITTA joyda)            ##
-- #####################################################################
-- 🔴 Dinamik chaqiruv FAQAT shu ikki funksiyada. Qolgan uchtasi ularni
--    oddiy chaqiradi -> "TOSIQ RUN qilinmagan" holati bitta joyda
--    hal qilinadi va uchala RPC ham bir xil qoidaga bo'ysunadi.

-- ---------------------------------------------------------------------
-- 1.1  hodim_qarz_map(uuid[]) -> jsonb
--      { "<qarz_hisob_id>": "<kassa_id>", ... }
--
--      Berilgan kassa id'lari uchun MAVJUD qarz hisoblarini (6721+) topadi.
--      Qiymat — o'sha qarz hisobiga tegishli KASSA id'si; u faqat
--      `hodim_oz_tarix` ro'yxatidagi `kassa_id` maydonini to'ldirish uchun
--      kerak (chek papkasi shu id bo'yicha ochiladi).
--      Bola-hisob (Naqd/Click/USD) va ildiz kassa ikkalasi ham ro'yxatda
--      bo'lsa — ILDIZ tanlanadi (`parent_id` ro'yxat ichida bo'lmagani).
--
--      🔴 QOROVUL: `hodim_qarz_hisob_topish(uuid)` YO'Q bo'lsa bo'sh `{}`
--         qaytadi. Chaqiruv `execute` orqali, ya'ni funksiya yo'q bazada
--         bu fayl RUN bo'lganda ham, ishlaganda ham XATO BERMAYDI
--         (`convert_start_v2` naqshi).
--      🔴 `hodim_qarz_hisob_topish` — FAQAT O'QIYDI (yaratmaydi), shuning
--         uchun `stable` funksiyadan chaqirish xavfsiz.
-- ---------------------------------------------------------------------
create or replace function hodim_qarz_map(p_accounts uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_out jsonb;
begin
  if p_accounts is null or array_length(p_accounts, 1) is null then
    return '{}'::jsonb;
  end if;

  -- TOSIQ RUN qilinmagan -> qarz tushunchasi umuman yo'q -> bo'sh map.
  if to_regprocedure('public.hodim_qarz_hisob_topish(uuid)') is null then
    return '{}'::jsonb;
  end if;

  execute $q$
    select coalesce(jsonb_object_agg(s.qarz_id::text, s.kassa_id::text), '{}'::jsonb)
      from (
        select distinct on (q.id) q.id as qarz_id, a.id as kassa_id
          from unnest($1) as t(x)
          join accounts a on a.id = t.x
          cross join lateral public.hodim_qarz_hisob_topish(t.x) as q(id)
         where q.id is not null
         order by q.id,
                  -- ildiz kassa oldinda: parenti ro'yxatda bo'lgan (ya'ni
                  -- bola-hisob) qator ORQAGA suriladi
                  (exists (select 1 from accounts pp
                            where pp.id = a.parent_id
                              and pp.id = any($1))) asc,
                  a.code asc
      ) s
  $q$
  into v_out
  using p_accounts;

  return coalesce(v_out, '{}'::jsonb);
end $$;

revoke all on function hodim_qarz_map(uuid[]) from public, anon;
grant execute on function hodim_qarz_map(uuid[]) to authenticated, service_role;

comment on function hodim_qarz_map(uuid[]) is
  'Kassa id''lari uchun MAVJUD qarz hisoblari: {qarz_hisob_id: kassa_id}. '
  'hodim_qarz_hisob_topish() yo''q bo''lsa bo''sh {} (eski xatti-harakat).';


-- ---------------------------------------------------------------------
-- 1.2  hodim_qarz_ids(uuid[]) -> uuid[]
--      Yuqoridagi map ning KALITLARI. Kassa to'plamini "kengaytirilgan
--      oila"ga aylantirish uchun:  v_ext = p_accounts || hodim_qarz_ids(...)
--      Hech qachon NULL qaytarmaydi (bo'sh massiv), shuning uchun `||`
--      natijani NULL ga aylantirib yubormaydi.
-- ---------------------------------------------------------------------
create or replace function hodim_qarz_ids(p_accounts uuid[])
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
           (select array_agg(k::uuid)
              from jsonb_object_keys(hodim_qarz_map(p_accounts)) as k),
           '{}'::uuid[]);
$$;

revoke all on function hodim_qarz_ids(uuid[]) from public, anon;
grant execute on function hodim_qarz_ids(uuid[]) to authenticated, service_role;

comment on function hodim_qarz_ids(uuid[]) is
  'Kassa id''lariga tegishli qarz hisoblari (6721+) massivi. Yo''q bo''lsa bo''sh massiv.';


-- #####################################################################
-- ##  2-BO'LIM — hodim_oz_tarix (IMZO O'ZGARMAYDI)                   ##
-- #####################################################################
-- O'zgargan YAGONA narsa — "bu yozuv shu hodimniki" FILTRI:
--     eski:  join entry_line kl ... and kl.account_id = any(v_ids)
--     yangi: kengaytirilgan oila (v_ext = v_ids || qarz) bo'yicha,
--            YOZUV DARAJASIDA, `distinct` bilan.
--
-- 🔴 DUBLIKAT XAVFI VA U QANDAY YOPILDI
--    QISMAN holatda bitta yozuvda IKKITA mos Kt satri bo'ladi
--    (Kt kassa 200k + Kt 6721 300k). Eski `join` shaklida bu satrlar
--    Dt satrini IKKI MARTA ko'paytirardi -> kategoriya jamisi va ro'yxat
--    IKKILANARDI (500k o'rniga 1 000 000).
--    Yechim: mos Kt satrlari BOSHIDA `select distinct kl.entry_id` CTE
--    (`ent`) ga siqiladi -> har yozuv AYNAN BIR MARTA. Dt satrlari esa
--    avvalgidek alohida qator bo'lib qoladi (ko'p moddali yozuv uchun
--    ataylab — bu eski xatti-harakat).
--    Yon foyda: bu eski, YASHIRIN dublikat xavfini ham yopadi (bitta
--    yozuvda hodimning IKKI kassasi Kt bo'lsa — `professional.html`
--    ko'p satrli yozuvi — eski kod summani ikkilantirardi).
--
-- 🔴 SUMMA MANBASI O'ZGARMADI: `dl.debit` (Dt xarajat moddasi) — u har
--    doim TO'LIQ (kassa qismi + qarz qismi). Kt tomoni FAQAT filtr uchun.
--
-- 🔴 `kassa_id` (chek papkasi) qanday to'ldiriladi:
--      1) mos Kt satrlari orasida KASSA satri bo'lsa — o'sha (eski
--         xatti-harakat, bayt-ma-bayt);
--      2) faqat qarz satri bo'lsa (qoldiq 0) — `hodim_qarz_map` dagi
--         kassa id. Qarz hisobining O'Z id'si HECH QACHON qaytmaydi:
--         u storage papkasi emas va `xarajat-cheklari` RLS policy'si uni
--         rad etardi.
--      ⚠️ Hodimda tur bolalari bo'lsa (Naqd/Click) va chek bola papkasiga
--         yuklangan bo'lsa, 2) holatda 📎 tugmasi chiqmasligi mumkin —
--         yozuvning O'ZI endi ko'rinadi, bu ILGARIGIDAN yaxshi.
-- #####################################################################

create or replace function hodim_oz_tarix(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p     user_perms;
  v_ids uuid[];
  v_map jsonb;
  v_ext uuid[];
  v_kat jsonb;
  v_roy jsonb;
begin
  -- caller kassalari  (BU BLOK O'ZGARMADI)
  select * into p from user_perms where user_id = auth.uid();
  if found and p.kassa_scope = 'list' then
    -- op kassalari (perm key = hodim kassasining o'z id'si; valyuta bolasi bo'lmaydi)
    select array_agg(a.id) into v_ids
      from accounts a
     where a.type = 'aktiv' and a.code like '5%'
       and a.kassa_turi <> 'xarajat_guruh'
       and perm_op_key(a.id) = any(p.op_kassa_ids);
  else
    -- cheklovsiz / admin: barcha hodim (xarajat) kassalari
    select array_agg(a.id) into v_ids
      from accounts a
     where a.kassa_turi = 'xarajat';
  end if;

  if v_ids is null or array_length(v_ids, 1) is null then
    return jsonb_build_object('kategoriya', '[]'::jsonb, 'royxat', '[]'::jsonb);
  end if;

  -- YANGI: kengaytirilgan oila = kassalar + ularning qarz hisoblari (6721+).
  -- Qarz hisobi yo'q bo'lsa (yoki TOSIQ RUN qilinmagan bo'lsa) v_map = '{}'
  -- va v_ext AYNAN v_ids ga teng -> quyidagi ikki so'rov eski natijani beradi.
  v_map := hodim_qarz_map(v_ids);
  v_ext := v_ids || hodim_qarz_ids(v_ids);

  -- Kategoriya: shu kassalardan (yoki ularning qarz hisobidan) chiqqan
  -- xarajat modda (Dt) bo'yicha jami.
  with ent as (
    -- 🔴 distinct — bitta yozuv bir marta (qisman holatda 2 ta mos Kt satri bor)
    select distinct kl.entry_id as id
      from entry_line kl
      join entry e2 on e2.id = kl.entry_id
     where kl.credit > 0
       and kl.account_id = any(v_ext)
       and e2.status = 'posted' and e2.is_deleted = false
       and e2.entry_date >= p_from and e2.entry_date <= p_to
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.jami desc), '[]'::jsonb) into v_kat
  from (
    select ma.code, ma.name, sum(dl.debit)::numeric as jami
      from ent
      join entry e on e.id = ent.id
      join entry_line dl on dl.entry_id = e.id and dl.debit > 0
      join accounts ma on ma.id = dl.account_id and ma.type = 'xarajat'
     where e.status = 'posted' and e.is_deleted = false
       and e.entry_date >= p_from and e.entry_date <= p_to
     group by ma.code, ma.name
    having sum(dl.debit) > 0
  ) x;

  -- Ro'yxat: har xarajat yozuvi (eng yangi 200 ta)
  with ent as (
    select distinct kl.entry_id as id
      from entry_line kl
      join entry e2 on e2.id = kl.entry_id
     where kl.credit > 0
       and kl.account_id = any(v_ext)
       and e2.status = 'posted' and e2.is_deleted = false
       and e2.entry_date >= p_from and e2.entry_date <= p_to
  )
  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v_roy
  from (
    select e.id as entry_id, e.entry_date, e.created_at,
           -- kassa satri bo'lsa o'sha, aks holda qarz hisobining kassasi
           case when kk.account_id = any(v_ids)
                then kk.account_id
                else nullif(v_map ->> kk.account_id::text, '')::uuid
           end as kassa_id,
           ma.code as modda_code, ma.name as modda_name,
           dl.debit::numeric as summa,
           e.description as izoh
      from ent
      join entry e on e.id = ent.id
      join entry_line dl on dl.entry_id = e.id and dl.debit > 0
      join accounts ma on ma.id = dl.account_id and ma.type = 'xarajat'
      -- BITTA mos Kt satri: avval kassa, keyin qarz. `limit 1` -> qator ko'paymaydi.
      join lateral (
        select kl.account_id
          from entry_line kl
         where kl.entry_id = e.id
           and kl.credit > 0
           and kl.account_id = any(v_ext)
         order by (kl.account_id = any(v_ids)) desc, kl.credit desc, kl.id asc
         limit 1
      ) kk on true
     where e.status = 'posted' and e.is_deleted = false
       and e.entry_date >= p_from and e.entry_date <= p_to
     order by e.created_at desc
     limit 200
  ) r;

  return jsonb_build_object('kategoriya', v_kat, 'royxat', v_roy);
end $$;

revoke all on function hodim_oz_tarix(date, date) from public, anon;
grant execute on function hodim_oz_tarix(date, date) to authenticated;

comment on function hodim_oz_tarix(date, date) is
  'Hodim o''z xarajat tarixi (kategoriya + ro''yxat) — auth.uid() ning o''z kassalari '
  'VA ularning qarz hisoblari (6721+) bo''yicha. Summa Dt (xarajat moddasi) satridan.';


-- #####################################################################
-- ##  3-BO'LIM — hodim_oy_jami_kop (IMZO O'ZGARMAYDI)                ##
-- #####################################################################
-- "Bu oy sarflandi". O'zgargan YAGONA narsa — hisob to'plami:
--     eski:  el.account_id = any(p_accounts)
--     yangi: el.account_id = any(p_accounts || hodim_qarz_ids(p_accounts))
--
-- 🔴 DUBLIKAT XAVFI YO'Q: bu yerda `join` emas, SATR yig'indisi
--    (`sum(el.credit)`) — har `entry_line` AYNAN BIR MARTA sanaladi.
--    Qisman holatda ikkala satr ham qo'shiladi: 200k + 300k = 500k, ya'ni
--    Dt (to'liq summa) bilan TENG.
--
-- 🔴 NEGA Kt YIG'INDISI, Dt EMAS (ataylab):
--    (a) `hodim_balans_bir()` ning `xar` CTE si AYNAN shunday hisoblaydi
--        -> to'siq foizi bilan "Bu oy sarflandi" hech qachon zid bo'lmaydi;
--    (b) qarz oqimida Kt yig'indisi = Dt (yuqoridagi 200k+300k misoli),
--        ya'ni "summa Dt dan" talabi natijada BAJARILADI;
--    (c) FAIL-CLOSED: `professional.html` ko'p satrli yozuvida (Dt Ijara
--        10 mln / Kt hodim 1 mln / Kt begona kassa 9 mln) Dt ga o'tish
--        hodimning oylik jamisiga BEGONA 9 mln ni qo'shib yuborardi.
--        Kt yig'indisi faqat hodimning o'z ulushini oladi.
--        (Bu AI_HISOBOT dagi "summa orqali sizish" saboqi.)
-- #####################################################################

create or replace function hodim_oy_jami_kop(p_accounts uuid[], p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(el.credit), 0)
    from entry_line el
    join entry e on e.id = el.entry_id
   where el.account_id = any(p_accounts || hodim_qarz_ids(p_accounts))
     and el.credit > 0
     and e.status = 'posted'
     and e.is_deleted = false
     and e.entry_date >= p_from
     and e.entry_date <= p_to
     and exists (
       select 1
         from entry_line dl
         join accounts a on a.id = dl.account_id
        where dl.entry_id = e.id
          and dl.debit > 0
          and a.type = 'xarajat'
     );
$$;

revoke all on function hodim_oy_jami_kop(uuid[], date, date) from public, anon;
grant execute on function hodim_oy_jami_kop(uuid[], date, date) to authenticated;

comment on function hodim_oy_jami_kop(uuid[], date, date) is
  'Kassa, bola-hisoblari VA qarz hisobidan (6721+) davr ichida chiqqan xarajat jami '
  '(hodim_oy_jami ning to''plamli varianti; hodim_balans_bir.jami_xarajat bilan bir xil mantiq).';


-- #####################################################################
-- ##  4-BO'LIM — hodim_oy_jami (IMZO O'ZGARMAYDI)                    ##
-- #####################################################################
-- Bitta hisobli eski variant (klient `hodim_oy_jami_kop` yo'q bo'lsa
-- shunga tushadi — `hodim-dev.html` fallback). Oila bo'yicha YIG'INDISI
-- 3-BO'LIM natijasiga TENG bo'lishi shart, aks holda fallback boshqa
-- raqam ko'rsatardi.
--
-- ⚠️ `el.account_id = p_account` -> `= any(...)` ga o'zgardi. Qarz hisobi
--    yo'q bo'lsa massiv aynan `array[p_account]` bo'ladi -> bir xil natija.
--
-- 🔴 DUBLIKAT XAVFI — SHU YERDA HAQIQIY, VA U QANDAY YOPILDI
--    Klient bu RPC ni HAR HISOB uchun ALOHIDA chaqiradi va natijalarni
--    QO'SHADI (`hodim-dev.html` -> `loadMonth`):
--        ids = [kassa, naqd bolasi, click bolasi, ...]
--        jami = res.reduce((s,v) => s + v)
--    Qarz hisobi esa BUTUN OILAGA BITTA. Agar har chaqiruvga qarzni
--    qo'shsak, 3 ta hisobli hodimda qarz qismi 3 MARTA sanalardi.
--    Shuning uchun qarz FAQAT ILDIZ kassa chaqiruvida qo'shiladi:
--    berilgan hisobning PARENTI hodim kassasi (kassa_turi='xarajat')
--    bo'lsa — bu bola-hisob, unga qarz QO'SHILMAYDI.
--    Yig'indi natija: qarz AYNAN BIR MARTA (`hodim_oy_jami_kop` bilan teng).
--    ⚠️ Bola-hisob YOLG'IZ so'ralsa (klient bunday qilmaydi) natija
--       eskisidek — qarzsiz. Bu ataylab: kam ko'rsatish ikkilantirishdan
--       xavfsizroq.
-- #####################################################################

create or replace function hodim_oy_jami(p_account uuid, p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(el.credit), 0)
    from entry_line el
    join entry e on e.id = el.entry_id
   where el.account_id = any(
           array[p_account] ||
           case when exists (select 1
                               from accounts c
                               join accounts pa on pa.id = c.parent_id
                              where c.id = p_account
                                and coalesce(pa.kassa_turi, '') = 'xarajat')
                then '{}'::uuid[]                       -- bola-hisob: qarz ildizda qo'shiladi
                else hodim_qarz_ids(array[p_account])   -- ildiz kassa (yoki oddiy hisob)
           end)
     and el.credit > 0
     and e.status = 'posted'
     and e.is_deleted = false
     and e.entry_date >= p_from
     and e.entry_date <= p_to
     and exists (
       select 1
         from entry_line dl
         join accounts a on a.id = dl.account_id
        where dl.entry_id = e.id
          and dl.debit > 0
          and a.type = 'xarajat'
     );
$$;

revoke all on function hodim_oy_jami(uuid, date, date) from public, anon;
grant execute on function hodim_oy_jami(uuid, date, date) to authenticated;

comment on function hodim_oy_jami(uuid, date, date) is
  'Kassadan VA uning qarz hisobidan (6721+) davr ichida chiqqan xarajat jami '
  '(Kt yig''indisi, qarshi tomoni type=xarajat).';


-- #####################################################################
-- ##  5-BO'LIM — PostgREST sxema keshi                               ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  6-BO'LIM — IMZO VA GRANT TEKSHIRUVI (faqat katalog select)     ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 6.1  IMZOLAR AYNAN ESKISIDEKMI?
--      KUTILGAN (uch qator):
--        hodim_oy_jami      | p_account uuid, p_from date, p_to date  | numeric | t | s | {search_path=public}
--        hodim_oy_jami_kop  | p_accounts uuid[], p_from date, p_to date | numeric | t | s | {search_path=public}
--        hodim_oz_tarix     | p_from date, p_to date                  | jsonb   | t | s | {search_path=public}
--      (t = security definer, s = stable)
--      Argument NOMLARI ham muhim: PostgREST ularni kalit sifatida
--      yuboradi (`{p_from, p_to}`). Bitta harf farq qilsa PGRST202.
-- ---------------------------------------------------------------------
select p.proname,
       pg_get_function_arguments(p.oid) as argumentlar,
       pg_get_function_result(p.oid)    as natija,
       p.prosecdef                      as definer,
       p.provolatile                    as volatillik,
       p.proconfig                      as sozlama
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('hodim_oz_tarix', 'hodim_oy_jami', 'hodim_oy_jami_kop')
 order by p.proname;


-- ---------------------------------------------------------------------
-- 6.2  GRANTLAR eskisidek?
--      KUTILGAN: `auth_ok` ustunlari true, `anon_ok` ustunlari FALSE.
-- ---------------------------------------------------------------------
select has_function_privilege('authenticated', 'public.hodim_oz_tarix(date,date)', 'execute')           as tarix_auth_ok,
       has_function_privilege('anon',          'public.hodim_oz_tarix(date,date)', 'execute')           as tarix_anon_ok,
       has_function_privilege('authenticated', 'public.hodim_oy_jami(uuid,date,date)', 'execute')       as oy_auth_ok,
       has_function_privilege('anon',          'public.hodim_oy_jami(uuid,date,date)', 'execute')       as oy_anon_ok,
       has_function_privilege('authenticated', 'public.hodim_oy_jami_kop(uuid[],date,date)', 'execute') as kop_auth_ok,
       has_function_privilege('anon',          'public.hodim_oy_jami_kop(uuid[],date,date)', 'execute') as kop_anon_ok,
       has_function_privilege('authenticated', 'public.hodim_qarz_ids(uuid[])', 'execute')              as ids_auth_ok,
       has_function_privilege('anon',          'public.hodim_qarz_ids(uuid[])', 'execute')              as ids_anon_ok;


-- ---------------------------------------------------------------------
-- 6.3  YANGI yordamchilar o'rnidami?
--      KUTILGAN: ikkalasi ham true.
-- ---------------------------------------------------------------------
select to_regprocedure('public.hodim_qarz_map(uuid[])') is not null as f_map,
       to_regprocedure('public.hodim_qarz_ids(uuid[])') is not null as f_ids;


-- #####################################################################
-- ##  7-BO'LIM — NIMA O'ZGARMADI (faqat izoh, SQL yo'q)              ##
-- #####################################################################
--
--  ── QARZ HISOBI YO'Q HOLAT (regressiya nol) ─────────────────────────
--  `hodim_qarz_map()` bo'sh `{}` qaytadi (funksiya yo'q, YOKI hodimda
--  6721 hisobi ochilmagan), demak:
--      hodim_qarz_ids(v_ids) = '{}'::uuid[]
--      v_ext                 = v_ids || '{}' = v_ids
--  * hodim_oy_jami / _kop:  `any(p_accounts || '{}')` = `any(p_accounts)`
--    -> so'rov rejasi ham, natija ham AYNAN eskisi.
--  * hodim_oz_tarix: `ent` CTE si `kl.account_id = any(v_ids)` bo'lib
--    qoladi. Eski `join` bilan farq FAQAT bitta holatda bo'ladi: yozuvda
--    v_ids dan IKKI XIL Kt satri bo'lsa (`professional.html` ko'p satrli
--    yozuvi). Eski kod u yozuvni IKKI MARTA sanardi (summa ikkilanardi),
--    yangi kod BIR MARTA. Ya'ni farq — eski XATO ning tuzatilishi;
--    oddiy bir kassali xarajatda natija bayt-ma-bayt bir xil.
--
--  ── IMZO / KONTRAKT ─────────────────────────────────────────────────
--  * Uchala funksiya ham `create or replace`, argument nomi/turi/tartibi
--    va `returns` shakli TEGILMAGAN (6.1 tekshiradi).
--  * `hodim_oz_tarix` javob SHAKLI o'zgarmadi:
--        { kategoriya: [{code, name, jami}],
--          royxat:     [{entry_id, entry_date, created_at, kassa_id,
--                        modda_code, modda_name, summa, izoh}] }
--    Maydon nomlari, tartibi, turlari va `limit 200` bir xil.
--  * `security definer`, `stable`, `set search_path = public`, `revoke ...
--    from public, anon`, `grant ... to authenticated` — AYNAN qayta berildi.
--
--  ── DUBLIKAT — UCH JOY, UCH XIL YECHIM (yig'ma) ─────────────────────
--  Qisman holatda (Kt kassa 200k + Kt 6721 300k) BITTA yozuvda IKKITA
--  mos Kt satri bo'ladi. Har funksiyada xavf boshqacha:
--   1) hodim_oz_tarix  — `join` qator KO'PAYTIRARDI ->
--                        `select distinct kl.entry_id` CTE (`ent`) +
--                        `join lateral (... limit 1)` -> har yozuv 1 marta,
--                        summa Dt (`dl.debit`) dan.
--   2) hodim_oy_jami_kop — xavf YO'Q: satr yig'indisi, har satr 1 marta;
--                        200k + 300k = 500k = Dt.
--   3) hodim_oy_jami   — xavf KLIENTDA: RPC har hisob uchun chaqirilib
--                        QO'SHILADI -> qarz faqat ILDIZ chaqiruvida
--                        qo'shiladi (parent tekshiruvi), ya'ni 1 marta.
--
--  ── TEGILMAGAN ──────────────────────────────────────────────────────
--  * `hodim_balans_bir()`, `hodim_tolanmagan_bir()`, `v_hodim_tolanmagan`,
--    to'siq trigger, `hodim_xarajat_yoz()`, `xarajat_saqlash_taqsim()` —
--    bu fayl ularga TEGMAYDI (o'qimaydi ham).
--  * Yozuv yo'llari (entry/entry_line insert) TEGILMAGAN — bu fayl faqat
--    O'QIY-DIGAN (stable) funksiyalarni o'zgartiradi.
--  * `hodim_qoldiqlar()` TEGILMAGAN: qoldiq — KASSA qoldig'i, qarz emas.
--    (Qarz "Mening hisobim" panelida alohida ko'rsatiladi.)
--
--  ── XATTI-HARAKAT ATAYLAB O'ZGARGAN YAGONA JOY ──────────────────────
--  Kt 6721 satri bor xarajat endi:
--    * hodim tarixi RO'YXATIDA ko'rinadi (va "To'lanmagan" rozetkasi
--      shu qator ustiga chiziladi);
--    * kategoriya taqsimotiga TO'LIQ summasi bilan kiradi;
--    * "Bu oy sarflandi" raqamiga kiradi.
--  Bu — shu faylning MAQSADI.
--
--  ⚠️ KUTILADIGAN "O'ZGARISH": qisman holatda (200k kassa + 300k qarz)
--     "Bu oy sarflandi" endi 500k ko'rsatadi (ilgari 200k edi). Bu XATO
--     EMAS — ro'yxatdagi 500k va `hodim_balans_bir.jami_xarajat` bilan
--     endi MOS keladi.
--
--  ⚠️ MA'LUM, TUZATILMAGAN NOMUVOFIQLIK (bu faylning ishi emas):
--     `professional.html` ko'p satrli yozuvida (Dt 10 mln / Kt hodim 1 mln /
--     Kt begona 9 mln) kategoriya taqsimoti Dt ni (10 mln) ko'rsatadi,
--     "Bu oy sarflandi" esa hodim ulushini (1 mln). Bu ILGARIDAN shunday
--     va u yerda begona summa ko'rinmasligi uchun ALOHIDA (fail-closed)
--     qaror kerak — shu faylda ATAYLAB o'zgartirilmadi.
--
--  ── ISHLASH TEZLIGI ─────────────────────────────────────────────────
--  `ent` CTE eski `join` ning selektiv qismini SAQLAYDI
--  (`entry_line.account_id` indeksi ishlaydi), keyin Dt satrlari
--  qo'shiladi — ya'ni reja avvalgidek "kichik to'plamdan boshlash".
--  `hodim_qarz_map` chaqiruvi bir marta (plpgsql o'zgaruvchisiga yoziladi);
--  `hodim_oy_jami*` da esa u korrelyatsiyasiz InitPlan.
--
--
-- #####################################################################
-- ##  8-BO'LIM — IXTIYORIY DIAGNOSTIKA (faqat jadval select)         ##
-- #####################################################################
-- RPC CHAQIRILMAYDI (editorda auth.uid() null) — oddiy jadval so'rovlari.

-- ---------------------------------------------------------------------
-- 8.1  "Ko'rinmay qolgan" xarajatlar bormi? (fix ta'sir qiladigan yozuvlar)
--      Kt 6721 satri BOR, lekin kassa (5xxx) Kt satri YO'Q yozuvlar.
--      Bu qatorlar ILGARI tarixda umuman ko'rinmasdi.
-- ---------------------------------------------------------------------
select e.id as entry_id, e.entry_date, e.description, sum(l.credit) as qarz_summa
  from entry e
  join entry_line l on l.entry_id = e.id and l.credit > 0
  join accounts q   on q.id = l.account_id
 where q.parent_id = (select id from accounts where code = '6720')
   and e.status = 'posted' and e.is_deleted = false
   and not exists (
     select 1 from entry_line k2
       join accounts a2 on a2.id = k2.account_id
      where k2.entry_id = e.id and k2.credit > 0
        and a2.type = 'aktiv' and a2.code like '5%')
 group by e.id, e.entry_date, e.description
 order by e.entry_date desc
 limit 50;

-- ---------------------------------------------------------------------
-- 8.2  QISMAN yozuvlar (kassa Kt + qarz Kt bitta yozuvda) — dublikat
--      tekshiruvi uchun eng muhim namuna.
--      KUTILGAN: `dt_summa` = `kassa_kt` + `qarz_kt` (Dt=Kt qoidasi).
--      Fix'dan keyin tarix shu yozuvni BIR MARTA va `dt_summa` bilan
--      ko'rsatishi kerak.
-- ---------------------------------------------------------------------
select e.id as entry_id, e.entry_date,
       sum(case when a.type = 'xarajat' and l.debit > 0 then l.debit else 0 end)                         as dt_summa,
       sum(case when a.type = 'aktiv' and a.code like '5%' and l.credit > 0 then l.credit else 0 end)    as kassa_kt,
       sum(case when a.parent_id = (select id from accounts where code = '6720')
                 and l.credit > 0 then l.credit else 0 end)                                             as qarz_kt
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a   on a.id = l.account_id
 where e.status = 'posted' and e.is_deleted = false
 group by e.id, e.entry_date
having sum(case when a.parent_id = (select id from accounts where code = '6720')
                 and l.credit > 0 then l.credit else 0 end) > 0
   and sum(case when a.type = 'aktiv' and a.code like '5%' and l.credit > 0 then l.credit else 0 end) > 0
 order by e.entry_date desc
 limit 50;


-- #####################################################################
-- ##  9-BO'LIM — ROLLBACK                                            ##
-- #####################################################################
--  🔴 `drop` QILMANG — uchala funksiyani ham PROD `hodim.html` chaqiradi.
--     Orqaga qaytarish = ESKI versiyani QAYTA RUN qilish (hammasi
--     `create or replace`, imzo bir xil):
--
--   (A) FAQAT tarix:      PROVODKA_HODIM_V5.sql  (yoki PROVODKA_HODIM_V7.sql
--                         — ikkalasidagi `hodim_oz_tarix` tanasi AYNAN bir xil)
--   (B) FAQAT oylik jami: PROVODKA_HODIM_TEZLIK.sql -> 3-bo'lim
--                         (`hodim_oy_jami_kop`)
--                         + PROVODKA_HODIM_V3.sql -> 5-BO'LIM (`hodim_oy_jami`)
--       ⚠️ PROVODKA_HODIM_TEZLIK.sql oxirida `do $$` bloki bor — Supabase
--          editorida u 42P01 beradi. Faqat 3-bo'limni belgilab RUN qiling.
--   (C) HAMMASI: (A) + (B).
--
--   Yordamchilar (`hodim_qarz_map`, `hodim_qarz_ids`) rollbackda
--   JOYIDA QOLAVERADI — ular hech kim chaqirmasa zararsiz (yangi nom,
--   eski kod ularni bilmaydi). Xohlansa keyin alohida o'chiriladi.
--
--   Har rollbackdan keyin:  notify pgrst, 'reload schema';
--
--   🔴 Rollback MA'LUMOTNI o'zgartirmaydi: bu faylda birorta `insert` /
--      `update` / `delete` YO'Q. Qarz satrlari (Kt 6721) joyida qoladi,
--      shunchaki tarixda yana KO'RINMAY qoladi.


-- #####################################################################
-- ##  YAKUN — PostgREST sxema keshi (takroriy, zararsiz)             ##
-- #####################################################################
notify pgrst, 'reload schema';
-- =====================================================================
