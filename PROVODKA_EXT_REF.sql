-- =====================================================================
-- PROVODKA_EXT_REF.sql
-- Takroriy yozuvga qarshi: ext_ref token + "qayta urinish" tekshiruvi
-- ---------------------------------------------------------------------
-- ## BUGUNGI HODISA (2026-08-24, prod)
-- Hodim `hodim.html` da 1 245 000 so'mlik xarajatni 5 filialga taqsimlab
-- saqlamoqchi bo'ldi. "Saqlanmoqda…" 5 DAQIQA qotib qoldi.
-- Diagnostika: bazada qulf yo'q, boshqa yozuvlar normal tushgan, o'sha yozuv
-- esa UMUMAN yozilmagan — so'rov yo'lda (mobil tarmoqda) osilib qolgan.
--
-- Klientda:
--   * timeout YO'Q          -> tugma abadiy aylanadi;
--   * takror himoyasi YO'Q  -> hodim qayta bossa yozuv IKKI MARTA tushardi.
-- Bu safar omad: yozuv tushmagan edi. Agar tushgan bo'lsa-yu hodim qayta
-- bosganida 1,2 mln (yoki 10 mln) ikki marta chiqib ketardi va hech kim
-- sezmasdi — jurnalda ikkita bir xil yozuv "normal" ko'rinadi.
--
-- ## SHU FAYL NIMA QILADI (SQL tomoni)
--   1) `entry.ext_ref` ustidagi UNIQUE indeks BOR ekanini tekshiradi /
--      yo'q bo'lsa qo'shadi. Bu — takrorga qarshi YAGONA ishonchli to'siq
--      (klient qancha marta yubormasin, baza ikkinchisini qabul qilmaydi).
--   2) `xarajat_saqlash_taqsim(jsonb)` endi IXTIYORIY `ext_ref` tokenini
--      qabul qiladi va yozadigan HAR entry ga `<token>:<indeks>` qo'yadi.
--      Token berilmasa — xatti-harakat AYNAN eskisidek (null).
--   3) YANGI `xarajat_qayta_urinish(p_ext_ref text)` — klient qayta
--      yozishdan OLDIN so'raydigan savol: "bu token bilan nima yozilgan?".
--      Chala (yetim/nomutanosib) sarlavhani tozalaydi, to'liq yozuvga
--      hech qachon tegmaydi.
--   4) `lock_timeout` — baza band bo'lsa so'rov 5 soniyada aniq xato bilan
--      qaytsin, abadiy kutmasin.
--
-- 🔴 Klient tomoni (token yaratish, AbortController timeout, qayta urinish
--    tugmasi) — ALOHIDA ish. Bu fayl faqat SQL. Klient kontrakti eng
--    oxirgi bo'limda (9-BO'LIM) batafsil yozilgan.
--
-- ## QOIDALAR
--   * FAQAT ADDITIVE: `drop` yo'q, imzo o'zgarmaydi, `ext_ref` berilmaganda
--     mavjud xatti-harakat AYNAN o'sha-o'shaligicha qoladi.
--   * `do $$` bloklari ISHLATILMAGAN (Supabase SQL editorida 42P01 beradi) —
--     hamma tekshiruv oddiy `select`.
--
-- ## RUN TARTIBI (Asilbek)
-- 🔴 Supabase editori FAQAT OXIRGI natijani ko'rsatadi — shuning uchun
--    bo'limlarni BITTALAB (belgilab) RUN qiling, tartib bilan:
--
--    0-BO'LIM  — TEKSHIRUV (0.1 … 0.5). Har `select` ni ALOHIDA belgilab
--                RUN qiling va natijasini ko'ring. Hech narsani o'zgartirmaydi.
--    1-BO'LIM  — indekslar (0.2 "indeks YO'Q" desa; 0.3 dublikat 0 bo'lsa).
--    2-BO'LIM  — xarajat_saqlash_taqsim (create or replace).
--    3-BO'LIM  — xarajat_qayta_urinish (yangi funksiya).
--    4-BO'LIM  — notify pgrst (sxema keshi).
--    5-BO'LIM  — YAKUNIY TEKSHIRUV (select'lar).
--    6..9      — faqat izoh (SQL yo'q): qaror jadvali, xavfsizlik, klient kontrakti.
--
-- ## OLD SHARTLAR
--   * `entry`, `entry_line`, `accounts`            (mavjud)
--   * `xarajat_saqlash_taqsim(jsonb)`              (PROVODKA_HODIM_VALYUTA.sql)
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — TEKSHIRUV (hech narsa o'zgarmaydi)                  ##
-- #####################################################################
-- Har birini ALOHIDA belgilab RUN qiling.

-- ---------------------------------------------------------------------
-- 0.1  `entry.ext_ref` ustuni bormi va turi qanday?
--      Kutilgan: bitta qator, data_type = text.
--      Qator CHIQMASA — pastdagi hech narsani RUN qilmang, avval ustun
--      qo'shilishi kerak (bu fayl ustun yaratmaydi: CLAUDE.md bo'yicha
--      `ext_ref` allaqachon bor deb hisoblanadi).
-- ---------------------------------------------------------------------
select column_name, data_type, is_nullable
  from information_schema.columns
 where table_schema = 'public' and table_name = 'entry'
   and column_name = 'ext_ref';


-- ---------------------------------------------------------------------
-- 0.2  `ext_ref` ustida UNIQUE indeks BORMI?
--      Kutilgan: kamida bitta qator (odatda `entry_ext_ref_uniq`) —
--      PROVODKA_TRANSFER.sql uni `do` blokida yaratardi, lekin Supabase
--      editorida `do` bloki ishlamasligi mumkin, shuning uchun TEKSHIRAMIZ.
--      Qator CHIQMASA -> 1-BO'LIM ni RUN qiling.
-- ---------------------------------------------------------------------
select i.relname                       as indeks,
       x.indisunique                   as unikalmi,
       pg_get_indexdef(x.indexrelid)   as tarif
  from pg_index x
  join pg_class t     on t.oid = x.indrelid
  join pg_class i     on i.oid = x.indexrelid
  join pg_namespace n on n.oid = t.relnamespace
 where n.nspname = 'public'
   and t.relname = 'entry'
   and x.indnkeyatts = 1
   and x.indkey[0] = (select attnum from pg_attribute
                       where attrelid = t.oid and attname = 'ext_ref' and not attisdropped)
 order by x.indisunique desc, i.relname;


-- ---------------------------------------------------------------------
-- 0.3  Dublikat `ext_ref` bormi? (UNIQUE indeks yaratishga xalaqit beradi)
--      Kutilgan: 0 qator. Qator chiqsa — ular ALLAQACHON ikki marta
--      yozilgan yozuvlar bo'lishi mumkin: avval Asilbek ularni ko'rib
--      chiqsin (1-BO'LIM ni RUN QILMANG, indeks baribir yaralmaydi).
-- ---------------------------------------------------------------------
select ext_ref, count(*) as nechta, min(created_at) as birinchi, max(created_at) as oxirgi
  from entry
 where ext_ref is not null
 group by ext_ref
having count(*) > 1
 order by count(*) desc
 limit 50;


-- ---------------------------------------------------------------------
-- 0.4  🔴 ENG MUHIM TEKSHIRUV — `entry.created_by` kim tomonidan to'ladi?
--      `xarajat_qayta_urinish` EGALIKni shu ustundan aniqlaydi
--      ("faqat o'z yozuvim"). Ustun turi repoda ANIQLANMAGAN
--      (PROVODKA_ISM.sql 7.5) — uuid ham, matn ham bo'lishi mumkin.
--
--      Kutilgan natija: data_type = uuid VA `uuid_shaklida` soni
--      `oxirgi_200` ga teng (ya'ni klient yozuvlarida to'lgan).
--
--      Agar `uuid_shaklida = 0` chiqsa: funksiya ishlaydi, lekin HAR DOIM
--      'yoq' qaytaradi (egalikni tasdiqlab bo'lmaydi) — bu XAVFSIZ, lekin
--      foydasiz. U holda 1.3 bandiga qarang (default qo'shish, Asilbek qaroriga).
-- ---------------------------------------------------------------------
select (select data_type from information_schema.columns
         where table_schema='public' and table_name='entry' and column_name='created_by') as created_by_turi,
       count(*)                                                                            as oxirgi_200,
       count(*) filter (where (to_jsonb(e) ->> 'created_by') ~ '^[0-9a-fA-F-]{36}$')        as uuid_shaklida,
       count(*) filter (where (to_jsonb(e) ->> 'created_by') is null)                       as bosh
  from (select * from entry order by created_at desc limit 200) e;


-- ---------------------------------------------------------------------
-- 0.5  Rol darajasidagi `statement_timeout` (Supabase sukuti odatda 8s).
--      🔴 UNI OSHIRMAYMIZ — aks holda osilgan so'rov yanada uzoq turadi.
--      Bu yerda faqat KO'RAMIZ (3-BO'LIM izohida nega funksiya ichida
--      o'zgartirilmasligi tushuntirilgan).
-- ---------------------------------------------------------------------
select rolname, rolconfig
  from pg_roles
 where rolname in ('anon', 'authenticated', 'service_role')
 order by rolname;


-- #####################################################################
-- ##  1-BO'LIM — INDEKSLAR (0.2 bo'sh chiqqan bo'lsa)                ##
-- #####################################################################
-- ⚠️ `create index` jadvalga SHARE lock oladi — yozuv (insert) shu vaqtda
--    kutadi. `entry` katta emas, lekin baribir tinch daqiqada RUN qiling.

-- ---------------------------------------------------------------------
-- 1.1  UNIQUE indeks — takrorga qarshi YAGONA ishonchli to'siq.
--
-- 🔴 NULL lar HAQIDA: oddiy btree UNIQUE indeksda NULL qiymatlar
--    "bir-biriga teng emas" deb hisoblanadi, ya'ni `ext_ref is null`
--    bo'lgan yozuvlar CHEKLANMAYDI — ular xohlagancha ko'p bo'lishi
--    mumkin. Bu bizga aynan KERAK: mavjud qo'lda yozuvlarning
--    (provodka/professional/jurnal tahriri) hammasida `ext_ref` null va
--    ular hech qanday tarzda ta'sirlanmaydi.
--    ⚠️ Shuning uchun `nulls not distinct` (PG15+) ATAYLAB ishlatilmadi —
--    u ikkinchi null'ni ham rad etib, butun prodni sindirar edi.
--    Ya'ni: himoya faqat TOKEN yuborilgan yozuvlarga tegishli.
-- ---------------------------------------------------------------------
create unique index if not exists entry_ext_ref_uniq on entry (ext_ref);

-- ---------------------------------------------------------------------
-- 1.2  Prefiks indeksi — `xarajat_qayta_urinish` uchun.
--      Taqsimot RPC'si `<token>:1`, `<token>:2` … yozadi, ya'ni qidiruv
--      `ext_ref like '<token>:%'` bo'lib ketadi. Oddiy btree indeks LIKE
--      prefiksini kollatsiyaga qarab ishlatmasligi mumkin —
--      `text_pattern_ops` esa har doim ishlatadi. Busiz har qayta urinish
--      butun `entry` jadvalini skan qilardi.
-- ---------------------------------------------------------------------
create index if not exists entry_ext_ref_prefix on entry (ext_ref text_pattern_ops);

-- ---------------------------------------------------------------------
-- 1.3  IXTIYORIY — FAQAT 0.4 da `created_by_turi = uuid` VA
--      `uuid_shaklida = 0` chiqsa (ya'ni ustun bor, lekin bo'sh qolayapti).
--      Asilbek qaroridan keyin alohida RUN qilinadi.
--      Additive: mavjud qatorlar TEGILMAYDI, faqat yangi insertlarga
--      default qo'yiladi. n8n (service_role) `created_by` ni o'zi
--      yozadi — unga ta'sir qilmaydi (default faqat ustun berilmaganda).
--
--   alter table entry alter column created_by set default auth.uid();
--
--      ⚠️ 0.4 da tur `text` chiqsa BU QATORNI RUN QILMANG — cast xatosi
--      beradi va egalik tekshiruvini boshqa yo'l bilan qurish kerak bo'ladi.
-- ---------------------------------------------------------------------


-- #####################################################################
-- ##  2-BO'LIM — xarajat_saqlash_taqsim: ixtiyoriy `ext_ref` token   ##
-- #####################################################################
-- 🔴 IMZO O'ZGARMAYDI: xarajat_saqlash_taqsim(jsonb).
--    Prod `hodim.html` ham, `hodim-dev.html` ham AYNI chaqiruvni qiladi:
--      sb.rpc('xarajat_saqlash_taqsim', { p_data })
--    `p_data.ext_ref` bo'lmasa — hamma narsa avvalgidek (ext_ref = null).
--
-- YANGI: `p_data.ext_ref` berilsa, RPC yozadigan HAR entry ga
--        `ext_ref = '<token>:' || <indeks>` qo'yiladi (1 dan boshlab).
--        Nega indeks bilan? RPC N ta ALOHIDA entry yozadi (har filialga
--        bittadan) — `ext_ref` UNIQUE bo'lgani uchun ular bir xil bo'lsa
--        RPC o'zining ikkinchi yozuvida yiqilardi.
--
-- TAKROR KELGANDA: birinchi `<token>:1` da 23505 (unique_violation) —
--        BU MAQSAD. RPC butunlay yiqiladi, ya'ni funksiya TRANZAKSIYA
--        bo'lgani uchun HECH NARSA yozilmaydi, yarim holat qolmaydi.
--        Klient 23505 ni "allaqachon saqlangan" deb tushunadi (9-BO'LIM).
--
-- lock_timeout: pastdagi izohga qarang.
-- ---------------------------------------------------------------------
create or replace function xarajat_saqlash_taqsim(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  it       jsonb;
  v_entry  uuid;
  v_ids    uuid[] := '{}';
  v_dt     uuid := nullif(p_data->>'dt_account','')::uuid;
  v_kt     uuid := nullif(p_data->>'kt_account','')::uuid;
  v_kassa  uuid := nullif(p_data->>'kassa_account','')::uuid;
  v_cur    text := nullif(p_data->>'kassa_currency','');
  -- 1 birlik valyuta necha so'm. null → eski xatti-harakat (fc = summa).
  v_kurs   numeric := nullif(p_data->>'kassa_kurs','')::numeric;
  -- YANGI: takrorga qarshi token (ixtiyoriy). null → eski xatti-harakat.
  v_ext    text := nullif(trim(p_data->>'ext_ref'), '');
  v_summa  numeric;
  v_filial uuid;
  v_fc     numeric;
  v_fc_dt  numeric;
  v_fc_kt  numeric;
  -- fc yaxlitlash siljishini yo'qotish uchun: jami valyuta miqdori va sarflangani.
  -- Har ulushni alohida round(summa/kurs,2) qilsak yig'indi ±0.02 farq qilardi va
  -- vaqt o'tib dollar qoldig'i siljib ketardi. Oxirgi ulushga qoldiq yuklanadi.
  v_jami   numeric := 0;
  v_fc_bar numeric;
  v_fc_qol numeric;
  v_n      int;
  v_i      int := 0;
begin
  -- 🔴 lock_timeout — "Saqlanmoqda…" abadiy aylanmasin.
  -- Baza band bo'lsa (boshqa tranzaksiya qatorni ushlab tursa) INSERT
  -- cheksiz kutmaydi: 5 soniyadan keyin 55P03 (lock_not_available) bilan
  -- ANIQ xato qaytadi va klient uni ko'rsatadi.
  -- ⚠️ `set local` FAQAT tranzaksiya ichida ishlaydi — funksiya chaqiruvi
  --    har doim tranzaksiya ichida bo'ladi, shuning uchun to'g'ri ishlaydi.
  --    Funksiyada `set search_path` bandi borligi uchun PostgreSQL chiqishda
  --    GUC larni avtomat tiklaydi (sessiyaga sizib ketmaydi).
  -- ⚠️ `statement_timeout` ATAYLAB O'ZGARTIRILMAYDI: u statement BOSHLANGANDA
  --    o'rnatiladi, funksiya ichida o'zgartirish JORIY so'rovga ta'sir qilmaydi
  --    (foydasiz kod bo'lardi). Uzilishning haqiqiy joyi — rol sukuti (0.5,
  --    Supabase'da 8s, biz uni OSHIRMAYMIZ) va klientdagi AbortController.
  perform set_config('lock_timeout', '5s', true);

  if v_dt is null or v_kt is null then
    raise exception 'dt/kt hisob berilmadi' using errcode = '22000';
  end if;
  if p_data->'taqsim' is null or jsonb_typeof(p_data->'taqsim') <> 'array'
     or jsonb_array_length(p_data->'taqsim') = 0 then
    raise exception 'Taqsimot bo''sh' using errcode = '22000';
  end if;
  if v_kurs is not null and v_kurs <= 0 then
    raise exception 'Kurs musbat bo''lishi kerak' using errcode = '22000';
  end if;
  -- Token shakli: tasodifiy uuid kutiladi. Juda qisqa token butun bir
  -- guruh yozuvni "o'ziniki" qilib qo'yishi mumkin edi (prefiks qidiruvi),
  -- shuning uchun uzunlik chegaralanadi. Xato bo'lsa JIM QOLMAYMIZ.
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bo''lishi kerak' using errcode = '22000';
  end if;

  -- Valyuta jamisi BIR MARTA hisoblanadi (ulushlar yig'indisidan), keyin ulushlarga
  -- taqsimlanadi — shunda sum(fc) = round(jami/kurs, 2) aniq mos keladi.
  v_n := jsonb_array_length(p_data->'taqsim');
  if v_kurs is not null then
    select coalesce(sum((x->>'summa')::numeric), 0) into v_jami
      from jsonb_array_elements(p_data->'taqsim') as x;
    v_fc_bar := round(v_jami / v_kurs, 2);
    v_fc_qol := v_fc_bar;
  end if;

  for it in select * from jsonb_array_elements(p_data->'taqsim') loop
    v_i := v_i + 1;
    v_summa  := (it->>'summa')::numeric;
    v_filial := nullif(it->>'filial_id','')::uuid;
    if v_summa is null or v_summa <= 0 then
      raise exception 'Har filial summasi musbat bo''lishi kerak' using errcode = '22000';
    end if;

    insert into entry (entry_date, description, source, status, filial_ids,
                       davr_start, davr_end, kommunal_turi, fc_rate, ext_ref)
    values (
      nullif(p_data->>'entry_date','')::date,
      nullif(p_data->>'description',''),
      coalesce(nullif(p_data->>'source',''), 'manual'),
      coalesce(nullif(p_data->>'status',''), 'posted'),
      case when v_filial is null then '{}'::uuid[] else array[v_filial] end,
      nullif(p_data->>'davr_start','')::date,
      nullif(p_data->>'davr_end','')::date,
      nullif(p_data->>'kommunal_turi',''),
      case when v_cur is not null and v_cur <> 'UZS' then v_kurs end,
      -- YANGI: token berilmasa null (eski xatti-harakat AYNAN saqlanadi)
      case when v_ext is null then null else v_ext || ':' || v_i::text end
    )
    returning id into v_entry;

    -- fc_amount faqat valyuta kassasi satriga (client bilan bir xil mantiq).
    -- Kurs berilgan bo'lsa so'm ulushi valyutaga aylantiriladi; OXIRGI ulushga
    -- taqsimlanmay qolgan qoldiq beriladi — sum(fc) = round(jami/kurs, 2).
    if v_kurs is null then
      v_fc := v_summa;                                   -- eski xatti-harakat
    elsif v_i = v_n then
      v_fc := v_fc_qol;
    else
      v_fc := round(v_fc_bar * v_summa / nullif(v_jami, 0), 2);
      v_fc_qol := v_fc_qol - v_fc;
    end if;
    v_fc_dt := case when v_cur is not null and v_cur <> 'UZS' and v_kassa = v_dt then v_fc else null end;
    v_fc_kt := case when v_cur is not null and v_cur <> 'UZS' and v_kassa = v_kt then v_fc else null end;

    insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
    values (v_entry, v_dt, v_summa, 0, v_fc_dt),
           (v_entry, v_kt, 0, v_summa, v_fc_kt);

    v_ids := v_ids || v_entry;
  end loop;

  return jsonb_build_object('ok', true,
                            'count', coalesce(array_length(v_ids, 1), 0),
                            'entry_ids', to_jsonb(v_ids));

exception
  -- 🔴 Takror. Xato KODI o'zgarmaydi (23505) — klient aynan shu kod bo'yicha
  --    "allaqachon saqlangan" deb qaror qiladi. Faqat matn tushunarli bo'ladi.
  --    Funksiya tranzaksiya bo'lgani uchun bu yerga yetganda BU URINISHDAN
  --    hech narsa yozilmagan (hammasi qaytarilgan) — yarim holat YO'Q.
  when unique_violation then
    -- Token yuborilmagan bo'lsa — bu bizning to'siq EMAS: xatoni AYNAN
    -- o'zgartirmasdan qaytaramiz (eski klient uchun xatti-harakat bir xil).
    if v_ext is null then
      raise;
    end if;
    raise exception 'Bu xarajat allaqachon saqlangan (takroriy yuborish tosildi)'
      using errcode = '23505';
end $$;

revoke all on function xarajat_saqlash_taqsim(jsonb) from public, anon;
grant execute on function xarajat_saqlash_taqsim(jsonb) to authenticated;

comment on function xarajat_saqlash_taqsim(jsonb) is
  'Filial bo''yicha alohida provodka: har filialga bitta entry (atomik). perm guard har satrga ishlaydi. '
  'kassa_kurs berilsa valyuta kassasida fc = summa/kurs (aks holda fc = summa — eski xatti-harakat). '
  'ext_ref berilsa har entry ga <token>:<indeks> yoziladi — takror yuborish 23505 bilan tosiladi. '
  'lock_timeout = 5s.';


-- #####################################################################
-- ##  3-BO'LIM — xarajat_qayta_urinish(text)  🔴 ENG MUHIM QISM      ##
-- #####################################################################
-- ## NEGA KERAK
-- `hodim.html` ning ODDIY (taqsimsiz) saqlash yo'li TRANZAKSIYADA EMAS:
--
--     1) insert into entry  ...        -> commit
--     2) insert into entry_line (2 ta) -> commit
--
-- Agar 1) tushib, javob yo'lda yo'qolsa va 2) umuman yozilmasa, bazada
-- YETIM SARLAVHA qoladi: `entry` bor, satrlari yo'q, ya'ni PUL YOZILMAGAN
-- (balans hisobi faqat entry_line dan yig'iladi).
-- Klient qayta urinsa `ext_ref` UNIQUE uni "takror" deb rad etadi va
-- klient "saqlandi" deb ko'rsatadi — ASLIDA PUL YOZILMAGAN. Bu jim
-- yo'qotish, dublikatdan ham yomonroq (hech kim sezmaydi).
--
-- Shuning uchun klient QAYTA YOZISHDAN OLDIN shu RPC ni chaqiradi va
-- javobga qarab qaror qiladi.
--
-- ## QAYTISH SHAKLI
--   {"holat": "yoq" | "toliq" | "chala_tozalandi",
--    "entry_ids": [...],        -- funksiya tugagach MAVJUD yozuvlar
--    "summa": numeric}          -- o'sha yozuvlarning Dt yig'indisi
--
-- ## TASNIF (bir entry uchun)
--   * `is_deleted = true`                     -> TO'LIQ deb sanaladi.
--       Sabab: uni ATAYLAB admin o'chirgan. Qayta yozilsa "o'chirilgan
--       yozuv o'zidan-o'zi tirildi" bo'lardi.
--   * status='posted' + kamida 2 satr + sum(debit)=sum(credit) + sum(debit)>0
--                                             -> TO'LIQ (daftarda turibdi).
--   * satri YO'Q yoki Dt<>Kt                  -> CHALA -> O'CHIRILADI.
--   * balansli, lekin status <> 'posted'      -> TEGILMAYDI va TO'LIQ deb
--       qaytariladi. Ikki qoida to'qnashadi: "balansli yozuvga tegma" va
--       "posted bo'lmagani daftarda emas". Pul xavfsizligi ustun: o'chirmaymiz
--       (ma'lumot yo'qolmasin) va klientga "qayta yozma" deymiz — aks holda
--       bir xil pul ikki marta yozilishi mumkin edi. Amalda bu holat YO'Q:
--       hodim ham, RPC ham har doim 'posted' yozadi (0.x tekshiruvlariga qarang).
--
-- ## XAVFSIZLIK
--   * FAQAT `auth.uid()` ning O'Z yozuvi bilan ishlaydi (`entry.created_by`).
--     Begona token uchun — hech qanday ma'lumot qaytarmaydi, 'yoq' deydi.
--     Ya'ni tasodifiy uuid bilan "zondlash" hech narsa bermaydi.
--   * `auth.uid()` null (anon/service_role) -> darrov 'yoq'. `perm_has_page`
--     dagi fail-OPEN naqshi bu yerda ATAYLAB TAKRORLANMAGAN.
--   * Egalikni tasdiqlab bo'lmasa (created_by bo'sh yoki uuid emas) —
--     yana 'yoq'. Bu XAVFSIZ tomonga xato: klient qayta yozadi, agar yozuv
--     haqiqatan bor bo'lsa `ext_ref` UNIQUE uni 23505 bilan to'sadi
--     (pul ikkilanmaydi, foydalanuvchi aniq xato ko'radi).
--   * O'chirish FAQAT chala sarlavhaga. Balansli yozuvga HECH QACHON tegmaydi.
--
-- ## QULF (poyga holati)
-- `select ... for update` entry qatorini ushlaydi. Bu tasodifan emas:
-- `entry_line` ga insert qilish ota qatorga FOR KEY SHARE lock oladi, ya'ni
-- BIR VAQTDA ketayotgan "kechikkan" satr inserti bizni kutadi. Shunda
-- "satr yo'q ekan" deb ko'rib, keyin satr paydo bo'lib qolishi mumkin emas.
-- `lock_timeout = 5s` — kutish cheksiz bo'lmasin.
-- ---------------------------------------------------------------------
create or replace function xarajat_qayta_urinish(p_ext_ref text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid   := auth.uid();
  v_tok   text   := nullif(trim(p_ext_ref), '');
  v_pat   text;
  v_ids   uuid[] := '{}';      -- funksiya tugagach saqlanib qolgan yozuvlar
  v_summa numeric := 0;
  v_chala int    := 0;         -- nechta chala sarlavha tozalandi
  v_begona int   := 0;         -- token bo'yicha TOPILDI, lekin egalik tasdiqlanmadi
  v_satr  int;
  v_dt    numeric;
  v_kt    numeric;
  v_del   int;
  v_cb    text;
  r       record;
begin
  -- lock_timeout: 2-BO'LIMdagi izoh bilan bir xil sabab.
  perform set_config('lock_timeout', '5s', true);

  -- Fail-closed: foydalanuvchi yo'q yoki token shakli noto'g'ri -> 'yoq'.
  -- (Qisqa token prefiks qidiruvida begona yozuvlarni qamrab olardi.)
  if v_uid is null or v_tok is null or length(v_tok) < 8 or length(v_tok) > 120 then
    return jsonb_build_object('holat', 'yoq', 'entry_ids', '[]'::jsonb, 'summa', 0);
  end if;

  -- LIKE uchun maxsus belgilar ekranlanadi (token baribir uuid, lekin
  -- '%' yuborilsa butun jadval prefiksga tushib qolardi).
  v_pat := replace(replace(replace(v_tok, '\', '\\'), '%', '\%'), '_', '\_') || ':%';

  for r in
    select e.id, coalesce(e.is_deleted, false) as ochirilgan, e.status as holati,
           (to_jsonb(e) ->> 'created_by')      as kim
      from entry e
     where (e.ext_ref = v_tok or e.ext_ref like v_pat escape '\')
     order by e.ext_ref
     for update
  loop
    -- ---- EGALIK: faqat o'z yozuvim -------------------------------------
    -- `created_by` turi bazada aniqlanmagan (uuid ham, matn ham bo'lishi
    -- mumkin — PROVODKA_ISM.sql 7.5), shuning uchun `::uuid` cast FAQAT
    -- to'liq uuid shaklida bajariladi: bitta buzuq qiymat 22P02 bilan
    -- butun RPC ni yiqitmasin (PROVODKA_AI_HISOBOT.sql dagi qat'iy naqsh).
    v_cb := case when r.kim ~ '^[0-9a-fA-F-]{36}$' then lower(r.kim) end;
    if v_cb is null or v_cb <> lower(v_uid::text) then
      -- 🔴 Token BO'YICHA topildi, lekin egalik tasdiqlanmadi (`created_by` bo'sh
      --    yoki begona). Bu "yozuv yo'q" degani EMAS. Token — klient yaratgan
      --    tasodifiy uuid, ya'ni topilishning o'zi kuchli dalil: mos yozuv BOR.
      --    'yoq' desak klient "saqlanmadi, qaytadan kiriting" deb ko'rsatadi va
      --    hodim qo'lda ikkinchi marta yozadi (yangi token — unique to'smaydi).
      --    Shuning uchun natija 'nomalum' bo'ladi: hech narsa yozilmaydi, odam
      --    jurnaldan tekshiradi. `created_by` to'lgach bu shox umuman yopiladi.
      v_begona := v_begona + 1;
      continue;                       -- begona yoki tasdiqlab bo'lmaydi -> jim
    end if;

    select count(*), coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0)
      into v_satr, v_dt, v_kt
      from entry_line l
     where l.entry_id = r.id;

    -- ---- TO'LIQ (tegilmaydi) -------------------------------------------
    -- ⚠️ `status <> 'posted'` bo'lsa ham, yozuv BALANSLI bo'lsa TEGILMAYDI —
    --    "balansli yozuvga hech qachon tegmaslik" qoidasi ustun. Lekin bunday
    --    yozuv daftarda turmaydi, shuning uchun `summa` ga QO'SHILMAYDI:
    --    foydalanuvchiga "saqlandi: 1 245 000" deb yolg'on raqam ko'rsatilmasin.
    --    (`is_deleted` yozuv ham shunday: holat 'toliq', summa 0.)
    if r.ochirilgan
       or (v_satr >= 2 and v_dt = v_kt and v_dt > 0) then
      v_ids   := v_ids || r.id;
      if r.holati = 'posted' and not r.ochirilgan then
        v_summa := v_summa + v_dt;
      end if;
      continue;
    end if;

    -- ---- CHALA: satri yo'q yoki Dt <> Kt -> TOZALANADI ------------------
    -- 🔴 Bu yerga faqat NOMUTANOSIB yoki SATRSIZ sarlavha tushadi.
    --    Balansli yozuv yuqoridagi shoxda `continue` bilan chiqib ketgan.
    -- Satrlarni o'chirish HECH QANDAY triggerni uyg'otmaydi: entry_line
    -- ustidagi 4 ta trigger ham (trg_perm_guard_entry_line /
    -- trg_hodim_tosiq_entry_line / trg_limit_guard_entry_line /
    -- trg_hodim_notify_entry_line) faqat INSERT/UPDATE ga qo'yilgan —
    -- tekshirilgan. `hodim_notify` va `entry_yuk` esa entry ga
    -- `on delete cascade` bilan bog'langan, ya'ni sarlavha o'chsa
    -- ular ham o'zi ketadi (yetim navbat qolmaydi).
    begin
      delete from entry_line where entry_id = r.id;
      -- `not exists` — himoya qatlami: qulf tufayli bu yerga satr kelib
      -- qolishi mumkin emas, lekin sharti bo'lgan delete arzon va aniq.
      delete from entry e2
       where e2.id = r.id
         and not exists (select 1 from entry_line l where l.entry_id = e2.id);
      get diagnostics v_del = row_count;
    exception when foreign_key_violation then
      -- Boshqa jadval (masalan konvert so'rovi) shu sarlavhaga bog'langan.
      -- JIM QOLMAYMIZ: klient aniq xato ko'rsin, odam tekshirsin.
      raise exception 'Chala yozuvni tozalab bo''lmadi — u boshqa yozuvga bog''langan (id %)', r.id
        using errcode = '55000';
    end;

    if v_del = 1 then
      v_chala := v_chala + 1;
    else
      -- O'chmadi (kutilmagan holat) — "yo'q" demaymiz, aks holda klient
      -- qayta yozib 23505 olardi. To'liq deb sanaymiz: odam tekshiradi.
      v_ids := v_ids || r.id;
    end if;
  end loop;

  -- ---- NATIJA ----------------------------------------------------------
  -- ⚠️ ARALASH holat (bittasi to'liq, bittasi chala) — taqsimot RPC'si
  --    tranzaksiya bo'lgani uchun amalda uchramaydi. Uchrasa 'chala_tozalandi'
  --    ustun keladi: klient qayta yozishga urinadi va omon qolgan yozuv
  --    tufayli 23505 oladi — ya'ni odam KO'RADI. "Jim to'liq" deyish
  --    esa pulning bir qismini abadiy yozilmay qoldirardi.
  return jsonb_build_object(
    'holat', case when v_chala > 0                        then 'chala_tozalandi'
                  when coalesce(array_length(v_ids,1),0) > 0 then 'toliq'
                  -- Fail-closed: token bo'yicha yozuv bor, lekin u meniki ekani
                  -- tasdiqlanmadi -> 'yoq' emas, 'nomalum' (yuqoridagi izohga qara).
                  when v_begona > 0                          then 'nomalum'
                  else 'yoq' end,
    'entry_ids', to_jsonb(v_ids),
    'summa', v_summa);
end $$;

revoke all on function xarajat_qayta_urinish(text) from public, anon;
grant execute on function xarajat_qayta_urinish(text) to authenticated;

comment on function xarajat_qayta_urinish(text) is
  'Qayta urinishdan OLDIN chaqiriladi: ext_ref token bilan nima yozilgan? '
  'yoq = yozilmagan (qayta yozsa boladi) · toliq = yozilgan (qayta yozilmasin) · '
  'chala_tozalandi = yetim/nomutanosib sarlavha ochirildi (qayta yozsa boladi). '
  'nomalum = token boyicha topildi, lekin egalik tasdiqlanmadi (created_by bosh) — qayta YOZILMASIN. '
  'Faqat auth.uid() ning oz yozuvi (entry.created_by); topilmagan token uchun yoq. '
  'Balansli yozuvga hech qachon tegmaydi. lock_timeout = 5s.';


-- #####################################################################
-- ##  4-BO'LIM — PostgREST sxema keshi                               ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  5-BO'LIM — YAKUNIY TEKSHIRUV (o'zgartirmaydi)                  ##
-- #####################################################################
-- Har `select` ni ALOHIDA RUN qiling.

-- 5.1  Ikkala funksiya ham joyidami va imzo saqlanganmi?
--      Kutilgan: 2 qator, `bor = true`.
select f.imzo,
       to_regprocedure(f.imzo) is not null as bor
  from (values ('xarajat_saqlash_taqsim(jsonb)'),
               ('xarajat_qayta_urinish(text)')) as f(imzo);

-- 5.2  Grantlar to'g'rimi?
--      Kutilgan: anon = false, authenticated = true, service_role = true.
select p.proname, r.rolname, has_function_privilege(r.rolname, p.oid, 'execute') as execute_bor
  from pg_proc p
  cross join (values ('anon'),('authenticated'),('service_role')) as r(rolname)
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('xarajat_saqlash_taqsim', 'xarajat_qayta_urinish')
 order by p.proname, r.rolname;

-- 5.3  Indekslar o'z joyidami? Kutilgan: 2 qator (uniq + prefix).
select i.relname as indeks, x.indisunique as unikalmi
  from pg_index x
  join pg_class t on t.oid = x.indrelid
  join pg_class i on i.oid = x.indexrelid
 where t.relname = 'entry'
   and i.relname in ('entry_ext_ref_uniq', 'entry_ext_ref_prefix')
 order by i.relname;

-- 5.4  Eski xatti-harakat buzilmadimi? `ext_ref` siz yozuvlar soni
--      o'zgarmasligi kerak (bu fayl mavjud ma'lumotga TEGMAYDI).
select count(*) filter (where ext_ref is null)     as ext_refsiz,
       count(*) filter (where ext_ref is not null) as ext_refli,
       count(*)                                    as jami
  from entry;

-- 5.5  Yetim sarlavhalar (satri yo'q entry) — bugungi hodisaning izi.
--      Bu fayl ularni O'ZI tozalamaydi (faqat token bilan so'ralganini).
--      Ro'yxat uzun bo'lsa Asilbek alohida ko'rib chiqadi.
select e.id, e.entry_date, e.created_at, e.source, e.description, e.ext_ref
  from entry e
 where not exists (select 1 from entry_line l where l.entry_id = e.id)
 order by e.created_at desc
 limit 50;


-- #####################################################################
-- ##  6-BO'LIM — QAROR JADVALI (izoh)                                ##
-- #####################################################################
--  xarajat_qayta_urinish('<token>') javobi va klient nima qilishi:
--
--  ┌────────────────────┬───────────────────────────┬──────────────────────────┐
--  │ holat              │ Bazadagi holat            │ Klient nima qiladi       │
--  ├────────────────────┼───────────────────────────┼──────────────────────────┤
--  │ yoq                │ token bilan yozuv yo'q    │ AYNI token bilan qayta   │
--  │                    │ (yoki begona/tasdiqlanmagan)│ yozadi                 │
--  ├────────────────────┼───────────────────────────┼──────────────────────────┤
--  │ toliq              │ yozuv(lar) bor va balansli│ "Allaqachon saqlangan"   │
--  │                    │ (yoki ataylab o'chirilgan)│ QAYTA YOZMAYDI, formani  │
--  │                    │                           │ tozalaydi                │
--  ├────────────────────┼───────────────────────────┼──────────────────────────┤
--  │ chala_tozalandi    │ yetim/nomutanosib sarlavha│ AYNI token bilan qayta   │
--  │                    │ topildi va O'CHIRILDI     │ yozadi                   │
--  └────────────────────┴───────────────────────────┴──────────────────────────┘
--
--  `entry_ids` — funksiya tugagach MAVJUD yozuvlar (tozalangani kirmaydi).
--  `summa`     — DAFTARDA turgan yozuvlarning Dt yig'indisi (so'mda):
--                faqat `status='posted'` va `is_deleted=false`. 'yoq' da 0.
--                Ya'ni "toliq + summa 0" = yozuv bor, lekin o'chirilgan
--                (yoki posted emas) — klient qayta YOZMAYDI, xabar beradi.


-- #####################################################################
-- ##  7-BO'LIM — NIMA O'ZGARMADI (regression uchun)                  ##
-- #####################################################################
--  * `xarajat_saqlash_taqsim` IMZOSI: (jsonb) — o'sha-o'sha.
--  * `p_data` da `ext_ref` BO'LMASA: entry.ext_ref = null, ya'ni prod
--    `hodim.html` ning bugungi xatti-harakati BAYT-MA-BAYT o'sha.
--  * `kassa_kurs` / fc taqsimoti mantiqi TEGILMAGAN (nusxa ko'chirilgan).
--  * `filial_ids`, `davr_*`, `kommunal_turi`, `fc_rate` — tegilmagan.
--  * Qaytish shakli {ok, count, entry_ids} — tegilmagan.
--  * Hech qanday ustun/funksiya/trigger O'CHIRILMADI yoki qayta nomlanmadi.
--  * Mavjud yozuvlarga (`entry`, `entry_line`) HECH QANDAY update/delete
--    qilinmadi — faqat yangi indeks va yangi funksiya qo'shildi.


-- #####################################################################
-- ##  8-BO'LIM — ROLLBACK (kerak bo'lsa)                             ##
-- #####################################################################
--  ⚠️ `xarajat_saqlash_taqsim` ni ORQAGA qaytarish = PROVODKA_HODIM_VALYUTA.sql
--     dagi versiyani qayta RUN qilish (u ham `create or replace`, imzo bir xil).
--     Klient token yuborayotgan bo'lsa u JIMGINA e'tiborsiz qoladi va
--     takror himoyasi YO'QOLADI — avval klientni qaytaring.
--
--  Yangi funksiyani olib tashlash (faqat zarurat bo'lsa):
--    drop function if exists xarajat_qayta_urinish(text);
--
--  Indekslarni olib tashlash TAVSIYA ETILMAYDI (ular himoyaning o'zi):
--    drop index if exists entry_ext_ref_prefix;
--    -- drop index if exists entry_ext_ref_uniq;   -- 🔴 buni qilmang


-- #####################################################################
-- ##  9-BO'LIM — KLIENT KONTRAKTI (keyingi bosqich, bu faylda SQL yo'q)
-- #####################################################################
--  Token: har SAQLASH BOSHLANGANDA bir marta yaratiladi va urinishlar
--  bo'ylab SAQLANADI:
--
--      const tok = crypto.randomUUID();     // 36 belgi — 8..120 oralig'ida
--
--  🔴 Foydalanuvchi summani/moddani/taqsimotni O'ZGARTIRSA — YANGI token.
--     Aks holda tuzatilgan yozuv "takror" deb rad etilardi.
--
--  A) TAQSIMOTLI yo'l (2+ filial, RPC):
--       p_data.ext_ref = tok;
--       const {data,error} = await sb.rpc('xarajat_saqlash_taqsim',{p_data});
--       * error.code === '23505'  -> "Allaqachon saqlangan" (dublikat to'sildi),
--                                    formani tozala, XATO deb ko'rsatma.
--       * error.code === '55P03'  -> "Baza band, qayta urinib ko'ring" (lock_timeout).
--       * tarmoq uzildi / timeout -> B) bandidagi qayta urinish oqimi.
--
--  B) ODDIY yo'l (bitta filial, to'g'ridan insert):
--       entryPayload.ext_ref = tok;          // <- YANGI, entry ga
--       // entry_line o'zgarmaydi
--
--  C) TIMEOUT (klientda hozir umuman yo'q — qo'shilishi shart):
--       AbortController + 20..25s. supabase-js: .abortSignal(ctrl.signal).
--       Timeoutda "Saqlanmoqda…" TO'XTAYDI va "Qayta urinish" tugmasi chiqadi.
--       🔴 "Saqlandi" DEB KO'RSATILMAYDI — natija noma'lum.
--
--  D) QAYTA URINISH OQIMI (majburiy tartib):
--       const {data:d, error:e} = await sb.rpc('xarajat_qayta_urinish',
--                                              { p_ext_ref: tok });
--       if (e) { /* {data,error} — error DOIM tekshiriladi */
--                toast(permErr(e), true); return; }        // qayta YOZMA
--       if (d.holat === 'toliq') {
--          toast('Bu xarajat allaqachon saqlangan');       // qayta YOZMA
--          formani tozala; loadBalances(); loadHist();
--       } else {
--          // 'yoq' yoki 'chala_tozalandi' -> AYNI token bilan qayta yoz
--       }
--     ⚠️ RPC xatosida qayta yozish TAQIQ — noma'lum holatda yozish aynan
--        dublikat xavfini qaytaradi.
--
--  E) 23505 ni tarjima qilish (translateErr / permErr):
--       "Bu xarajat allaqachon saqlangan" — bu XATO emas, MUVAFFAQIYAT.
--       Qizil toast emas, oddiy xabar + forma tozalanadi.
-- =====================================================================
