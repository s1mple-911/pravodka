-- =====================================================================
-- PROVODKA_HODIM_AMALLAR.sql
-- hodim.html — "Bugun / Bu hafta / Bu oy" da HAMMA amal ko'rinsin
-- (kirim, chiqim/xarajat, transfer) — faqat O'Z kassasi bo'yicha.
-- ---------------------------------------------------------------------
-- ## MUAMMO
-- `hodim_oz_tarix(date,date)` faqat XARAJAT ni beradi:
--     join accounts ma on ma.id = dl.account_id and ma.type = 'xarajat'
-- Ya'ni hodim kassasiga bugalter pul bergani (transfer), boshlang'ich
-- qoldiq (kirim) yoki qarz yopilishi ro'yxatda UMUMAN ko'rinmaydi.
-- Hodim "qoldig'im nega o'zgardi" degan savolga javob topolmaydi.
--
-- ## YECHIM
-- Yangi RPC `hodim_amallar(p_from, p_to)` -> jsonb massiv. Har element:
--   entry_id, sana, vaqt, tur, summa, izoh, qarshi_nom, qarshi_kod,
--   kassa_id, kassa_nom, pul_turi, valyuta, fc_summa, ijrochi, is_deleted
-- `tur`: kirim | chiqim | transfer_kirim | transfer_chiqim
--
-- 🔴 `hodim_oz_tarix` GA TEGILMAGAN. Bu fayl faqat YANGI obyekt yaratadi
--    (`hodim_amallar`, `hodim_ijrochi_nomi`). PROVODKA_HODIM_TARIX_QARZ.sql
--    ning ishi (qarz hisobini ham sanash) buzilmaydi — aksincha, ayni
--    o'sha yordamchilar (`hodim_qarz_ids`) shu yerda ham ishlatiladi.
--
-- ## QOIDALAR (buzilmadi)
--   * FAQAT ADDITIVE: `drop` yo'q, ustun qo'shilmaydi/o'chirilmaydi,
--     mavjud funksiya imzosi o'zgarmaydi.
--   * anonim `do` bloki YO'Q (Supabase editorida 42P01).
--   * Faylda RPC ni JONLI chaqiradigan operator YO'Q — faqat KATALOG
--     so'rovlari (editorda `auth.uid()` null, natija chalg'itadi).
--   * Funksiya tanasi NOMLANGAN dollar-teg bilan o'ralgan (fn tegi) —
--     izohdagi belgi dollar-qavs paritetiga ta'sir qilmasin (CLAUDE.md).
--     🔴 Shu sababli bu faylning IZOHIDA dollar-teg YOZILMAGAN.
--   * `security definer` + `set search_path = public` + `revoke public,anon`
--     + `grant authenticated` + `comment on function`.
--
-- ## RUN TARTIBI (Asilbek)
--   Old shart (ixtiyoriy, lekin tavsiya):
--      1) PROVODKA_PERMS.sql / PROVODKA_V8.sql  (perm_op_key, perm_view_pul_ids)
--      2) PROVODKA_XARAJAT_TOSIQ.sql            (hodim_qarz_hisob_topish)
--      3) PROVODKA_HODIM_TARIX_QARZ.sql         (hodim_qarz_ids/hodim_qarz_map)
--      4) PROVODKA_IJROCHI.sql                  (ijrochi_nomi)
--      5) PROVODKA_HODIM_AMALLAR.sql            <-- SHU FAYL
--   🔴 2/3/4 YO'Q bo'lsa ham bu fayl RUN bo'ladi va ishlaydi — uchala
--      bog'liqlik ham DINAMIK (`to_regprocedure` + `execute`,
--      `convert_start_v2` naqshi). Yo'qligining natijasi:
--        hodim_qarz_ids yo'q   -> qarz hisobi oilaga qo'shilmaydi
--        perm_view_pul_ids yo'q-> begona pul tomoni HAR DOIM niqoblanadi (fail-closed)
--        ijrochi_nomi yo'q     -> `ijrochi` null (yoki texnik belgi matni)
--
--   Bo'limlarni BITTALAB, TARTIB BILAN belgilab RUN qiling:
--      0-BO'LIM — OLD SHART tekshiruvi (faqat select)
--      1-BO'LIM — hodim_ijrochi_nomi(text)   (YANGI, ichki)
--      2-BO'LIM — hodim_amallar(date,date)   (YANGI, ochiq RPC)
--      3-BO'LIM — notify pgrst
--      4-BO'LIM — IMZO va GRANT tekshiruvi (faqat katalog select)
--      5-BO'LIM — QARORLAR va ular NEGA shunday (faqat izoh)
--      6-BO'LIM — ixtiyoriy DIAGNOSTIKA (faqat katalog/jadval select)
--      7-BO'LIM — ROLLBACK
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART TEKSHIRUVI (hech narsa o'zgarmaydi)       ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 0.1  Bog'liqliklar o'rnidami?
--      `f_perm_op` false chiqsa — TO'XTANG (PROVODKA_PERMS.sql kerak):
--        oila aniqlash mumkin emas.
--      Qolganlari false bo'lsa — XATO EMAS (yuqoridagi "yo'qligining
--      natijasi" jadvaliga qarang).
-- ---------------------------------------------------------------------
select to_regprocedure('public.perm_op_key(uuid)')          is not null as f_perm_op,
       to_regprocedure('public.perm_view_pul_ids()')        is not null as f_perm_view,
       to_regprocedure('public.hodim_qarz_ids(uuid[])')     is not null as f_qarz_ids,
       to_regprocedure('public.ijrochi_nomi(text)')         is not null as f_ijrochi,
       to_regprocedure('public.hodim_oz_tarix(date,date)')  is not null as f_oz_tarix;


-- ---------------------------------------------------------------------
-- 0.2  Nomlar bo'shmi? Kutilgan: IKKALASI ham `false`.
--      `true` chiqsa — nom band, MENGA AYTING (ustiga yozmang).
-- ---------------------------------------------------------------------
select to_regprocedure('public.hodim_amallar(date,date)')  is not null as band_amallar,
       to_regprocedure('public.hodim_ijrochi_nomi(text)')  is not null as band_ijrochi;


-- ---------------------------------------------------------------------
-- 0.3  Kerakli ustunlar bormi? (hammasi `true` bo'lsin)
--      `entry.created_by` ATAYLAB tekshirilmaydi — u `to_jsonb()` orqali
--      o'qiladi, ya'ni ustun yo'q bo'lsa ham so'rov yiqilmaydi
--      (PROVODKA_IJROCHI.sql dagi ayni qaror).
-- ---------------------------------------------------------------------
select exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='entry_line' and column_name='fc_amount') as c_fc_amount,
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='accounts'   and column_name='pul_turi')  as c_pul_turi,
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='accounts'   and column_name='currency')  as c_currency,
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='accounts'   and column_name='section')   as c_section;


-- #####################################################################
-- ##  1-BO'LIM — hodim_ijrochi_nomi(text)  — ICHKI                   ##
-- #####################################################################
-- `ijrochi_nomi(text)` ustidagi YUPQA qobiq. Nima uchun alohida:
--
--   1) 🔴 BOG'LIQLIK NOL: `PROVODKA_IJROCHI.sql` RUN qilinmagan bazada
--      `hodim_amallar` 42883 bilan yiqilmasin. Chaqiruv `execute` orqali
--      (`convert_start_v2` naqshi) va xato ushlanadi.
--   2) 🔴 MAXFIYLIK: `ijrochi_nomi` ATAYLAB `authenticated` ga
--      berilmagan (PROVODKA_IJROCHI.sql 2-BO'LIM izohi: aks holda har
--      kim uuid bo'yicha begona odamning ismini/emailini yig'ib olardi).
--      Shu qobiq ham AYNI SABAB bilan `authenticated` ga BERILMAYDI —
--      u faqat `hodim_amallar` ichidan chaqiriladi, EXECUTE huquqi
--      egalik (owner) orqali ta'minlanadi.
--
-- `ijrochi_nomi` yo'q bo'lgan holatda xatti-harakat:
--   * xom qiymat uuid SHAKLIDA  -> null  (xom uuid ko'rsatishdan foyda yo'q)
--   * uuid shaklida EMAS        -> matnning o'zi ('aros_sync', 'tovar_sync')
--     — bu ma'lumot YO'QOTMASLIK uchun (PROVODKA_IJROCHI.sql bilan bir xil qoida).

-- ⬇⬇⬇  1-BO'LIM: SHU QATORDAN 1-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function hodim_ijrochi_nomi(p_raw text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_txt text;
  v_out text;
begin
  v_txt := nullif(btrim(coalesce(p_raw, '')), '');
  if v_txt is null then
    return null;
  end if;

  -- PROVODKA_IJROCHI.sql RUN qilinmagan -> zaxira qoida
  if to_regprocedure('public.ijrochi_nomi(text)') is null then
    if v_txt ~ '^[0-9a-fA-F-]{36}$' then
      return null;
    end if;
    return v_txt;
  end if;

  begin
    execute 'select public.ijrochi_nomi($1::text)' into v_out using v_txt;
  exception when others then
    return null;                       -- ism ko'rsatilmasa ham amal ro'yxati chiqsin
  end;

  return nullif(btrim(coalesce(v_out, '')), '');
end $fn$;

-- 🔴 GRANT ATAYLAB YO'Q (yuqoridagi 2-sabab). `authenticated` ga berilsa
--    PostgREST uni ochiq ism-qidiruv RPC qilib qo'yardi.
revoke all on function hodim_ijrochi_nomi(text) from public, anon, authenticated;

comment on function hodim_ijrochi_nomi(text) is
  'ICHKI: ijrochi_nomi(text) ustidagi qobiq — funksiya yoq bazada ham hodim_amallar ishlasin. '
  'authenticated ga ATAYLAB berilmagan (ochiq ism-qidiruv RPC bolib qolmasin).';
-- ⬆⬆⬆  1-BO'LIM oxiri  ⬆⬆⬆


-- #####################################################################
-- ##  2-BO'LIM — hodim_amallar(p_from, p_to)  — OCHIQ RPC            ##
-- #####################################################################
--
-- ## OILA (kimning amallari) — 🔴 `hodim_oz_tarix` BILAN AYNI MANTIQ
--    Bayt-ma-bayt o'sha ikki shox:
--      kassa_scope = 'list'  -> perm_op_key(a.id) = any(op_kassa_ids)
--                               (type='aktiv' + code like '5%' + xarajat_guruh emas)
--      aks holda (admin / cheklovsiz / qatorsiz)
--                            -> barcha hodim kassalari (kassa_turi='xarajat')
--    Keyin oila QARZ hisobi bilan kengaytiriladi (`hodim_qarz_ids`) —
--    `hodim_oz_tarix` da (PROVODKA_HODIM_TARIX_QARZ.sql) ayni shunday.
--    🔴 Ikki joyda ikki xil qoida bo'lsa hodim bir ekranda ikki xil
--       ro'yxat ko'rardi — shuning uchun MANBA BIR XIL.
--
-- ## FAIL-CLOSED (uch qavat)
--   1) `auth.uid() is null` -> BO'SH massiv. Ya'ni service_role / anon /
--      SQL editor hech narsa olmaydi. Foydalanuvchi ID argumenti YO'Q —
--      kim so'rayotganini FAQAT `auth.uid()` aytadi, mijoz aralasha olmaydi.
--   2) Oila bo'sh (`v_ids` null) -> BO'SH massiv. `op_kassa_ids` null
--      bo'lsa `= any(null)` null beradi -> hech qanday hisob tanlanmaydi.
--   3) Yozuv FAQAT oila satri qatnashgan bo'lsa ro'yxatga tushadi
--      (`exists ... account_id = any(v_ext)`).
--
-- ## SUMMA — 🔴 BEGONA PUL SIZMAYDI
--    summa = abs( sum(debit) - sum(credit) )  — FAQAT OILA satrlari bo'yicha.
--    Sabab (AI 5-bosqichdagi (a) sizishining aynan o'zi):
--      `professional.html` ko'p satrli yozuv yozadi —
--         Dt Ijara 10 mln / Kt mening kassam 1 mln / Kt begona kassa 9 mln
--      Agar summa yozuvning O'ZIDAN (Dt jami) olinsa, hodimga 10 mln
--      ko'rinardi va begona 9 mln summa orqali sizardi.
--    Yon foyda — qarz oqimi bilan ZID EMAS:
--         Dt modda 500k / Kt kassa 200k / Kt 6721 300k
--      oila = {kassa, 6721} -> net = -(200k+300k) = -500k -> summa 500k,
--      ya'ni `hodim_oz_tarix` dagi `dl.debit` (500k) bilan bir xil va
--      `hodim_oy_jami_kop` (Kt yig'indisi) bilan ham bir xil.
--
-- ## TUR — tasnif `section='pul'` bo'yicha (CLAUDE.md "Jurnal tasnifi"),
--    kod prefiksi (5xxx) bilan EMAS. Yo'nalish esa HODIM nuqtai nazaridan:
--      net > 0 (oilaga pul KIRDI)  + qarshi tomon section='pul' -> transfer_kirim
--      net > 0                     + qarshi tomon pul EMAS      -> kirim
--      net < 0 (oiladan pul CHIQDI)+ qarshi tomon section='pul' -> transfer_chiqim
--      net < 0                     + qarshi tomon pul EMAS      -> chiqim
--    ⚠️ `net = 0` yozuv CHIQARILADI: bu oila ICHIDAGI harakat (masalan
--       hodimning Naqd -> Click hisobi, yoki valyuta konverti). Hodimning
--       puli o'zgarmagan, 4 turning hech biriga ham to'g'ri kelmaydi va
--       ro'yxatni "0 so'm" qatorlari bilan to'ldirardi.
--    ⚠️ Qarz-only xarajat (Dt modda / Kt 6721, kassa satri UMUMAN YO'Q)
--       ham TO'G'RI ishlaydi: 6721 oilada, net<0, qarshi tomon modda
--       (`section` pul emas) -> `chiqim`. Aynan shu holat
--       PROVODKA_HODIM_TARIX_QARZ.sql da tuzatilgan edi.
--
-- ## QARSHI TOMON = net ga QARAMA-QARSHI tomondagi, oiladan TASHQARI
--    eng katta satr (`limit 1` -> qator ko'paymaydi). Dt=Kt bo'lgani uchun
--    `net <> 0` bo'lsa bunday satr HAR DOIM mavjud.
--
-- ## 🔴 BEGONA TOMON NIQOBLASHI (`PROVODKA_AI_KONTEKST.sql` -> ai_ctx_transfer)
--    Qoida AYNAN o'sha:
--      * qarshi tomon PUL EMAS (xarajat moddasi, kapital, daromad) ->
--        ochiq ko'rinadi. Moddalar ruxsat bilan cheklanmaydi — hodim
--        ularni `moddaList()` da baribir ko'radi.
--      * qarshi tomon PUL va ko'rish doirasida -> ochiq.
--      * qarshi tomon PUL, doiradan TASHQARIDA -> `qarshi_kod = null`,
--        `qarshi_nom = 'Ruxsat yo''q'` VA 🔴 `izoh = null`.
--        Izoh ham yashiriladi, chunki unda odatda kassa NOMI turadi
--        ("Sergeli -> Toshkent") — busiz nom aynan o'sha yerdan sizardi.
--      * qarshi tomon topilmadi (nazariy) -> niqoblanadi (fail-closed).
--    Summa ko'rinadi: u hodimning O'Z kassasidan chiqqan/kirgan pul,
--    sir bo'lgani — narigi tomonning kimligi.
--
--    Ko'rish doirasi manbasi — `perm_view_pul_ids()`: u ALLAQACHON
--    kengaytirilgan hisob id'lari ro'yxatini beradi (`perm_op_key(a.id) =
--    any(view_kassa_ids)` dan o'tgan). Shuning uchun tekshiruv
--    `q_id = any(v_view)` — 🔴 `perm_op_key(q_id)` BILAN EMAS: AI
--    5-bosqichdagi (b) sizishi aynan shundan chiqqandi (yolg'iz bola-hisob
--    parentga ko'tarilib butun oilani ochib yuborardi).
--    `null` = cheklovsiz (admin) -> niqoblash yo'q.
--    Funksiya YO'Q bo'lsa `'{}'` -> HAMMASI niqoblanadi (fail-closed).
--
-- ## O'CHIRILGAN YOZUVLAR — CHIQARILADI (`is_deleted = false`). NEGA:
--    (a) Shu EKRANDAGI qolgan hamma raqam ularni chiqaradi —
--        `hodim_oz_tarix`, `hodim_oy_jami*`, `hodim_tosiq_holat`, qoldiq.
--        Ro'yxatda ko'rinsa, "Bu oy sarflandi" va to'siq foizi bilan bir
--        ekranda ZID raqam bo'lardi (PROVODKA_HODIM_TARIX_QARZ.sql aynan
--        shu zidlikni tuzatgan edi).
--    (b) Tahrir/o'chirish faqat adminda — hodim usti chizilgan qator
--        bilan hech narsa qila olmaydi, u faqat chalg'itadi.
--    🔴 LEKIN `is_deleted` KALITI JAVOBDA QOLADI (hozircha doim `false`) —
--    mijoz uni usti chizilgan holda chizishga TAYYOR, ya'ni kelajakda
--    filtr yumshatilsa HTML o'zgarmaydi (additive).
--
-- ## LIMIT 200, tartib: sana desc, vaqt desc, entry_id desc.
--    (`hodim_oz_tarix` ham 200 — ikki ro'yxat bir xil chuqurlikda bo'lsin.)

-- ⬇⬇⬇  2-BO'LIM: SHU QATORDAN 2-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function hodim_amallar(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_lim  constant int := 200;
  p      user_perms;
  v_ids  uuid[];
  v_ext  uuid[];
  v_view uuid[] := '{}'::uuid[];      -- fail-closed sukut: hamma begona pul niqoblanadi
  v_tmp  uuid[];
  v_out  jsonb;
begin
  -- 1-QAVAT: kim so'rayapti (mijoz argumenti YO'Q)
  if auth.uid() is null then
    return '[]'::jsonb;
  end if;

  if p_from is null or p_to is null or p_from > p_to then
    return '[]'::jsonb;
  end if;

  -- 2-QAVAT: OILA — hodim_oz_tarix bilan AYNI mantiq
  select * into p from user_perms where user_id = auth.uid();
  if found and p.kassa_scope = 'list' then
    select array_agg(a.id) into v_ids
      from accounts a
     where a.type = 'aktiv' and a.code like '5%'
       and a.kassa_turi <> 'xarajat_guruh'
       and perm_op_key(a.id) = any(p.op_kassa_ids);
  else
    select array_agg(a.id) into v_ids
      from accounts a
     where a.kassa_turi = 'xarajat';
  end if;

  if v_ids is null or array_length(v_ids, 1) is null then
    return '[]'::jsonb;
  end if;

  -- Kengaytirilgan oila = kassalar + ularning qarz hisoblari (6721+).
  -- DINAMIK: PROVODKA_HODIM_TARIX_QARZ.sql RUN qilinmagan bo'lsa v_ext = v_ids.
  v_ext := v_ids;
  if to_regprocedure('public.hodim_qarz_ids(uuid[])') is not null then
    begin
      -- ⚠️ Aniq cast: EXECUTE ichida `$1` ning turi noaniq bo'lib qolmasin (42P08).
      execute 'select $1::uuid[] || public.hodim_qarz_ids($1::uuid[])' into v_tmp using v_ids;
      v_ext := coalesce(v_tmp, v_ids);
    exception when others then
      v_ext := v_ids;                 -- qarz qo'shilmasa ham ro'yxat chiqsin
    end;
  end if;

  -- Ko'rish doirasi (niqoblash uchun). null = cheklovsiz.
  if to_regprocedure('public.perm_view_pul_ids()') is not null then
    begin
      execute 'select public.perm_view_pul_ids()' into v_view;
    exception when others then
      v_view := '{}'::uuid[];         -- fail-closed
    end;
  end if;

  with e as (
    select en.id                             as e_id,
           en.entry_date                     as e_date,
           en.created_at                     as e_created,
           en.description                    as e_desc,
           en.is_deleted                     as e_del,
           (to_jsonb(en) ->> 'created_by')   as e_ijr
      from entry en
     where en.status = 'posted'
       and en.is_deleted = false
       and en.entry_date >= p_from and en.entry_date <= p_to
       -- 3-QAVAT: oila satri qatnashmagan yozuv UMUMAN chiqmaydi
       and exists (select 1 from entry_line l
                    where l.entry_id = en.id and l.account_id = any(v_ext))
  ),
  m as (
    -- Oilaning SOF harakati. 🔴 Faqat oila satrlari — begona pul summaga kirmaydi.
    select e.e_id,
           sum(l.debit - l.credit)::numeric as net,
           sum(case when l.debit > 0 then coalesce(l.fc_amount, 0)
                    else -coalesce(l.fc_amount, 0) end)::numeric as net_fc
      from e
      join entry_line l on l.entry_id = e.e_id and l.account_id = any(v_ext)
     group by e.e_id
    having sum(l.debit - l.credit) <> 0     -- oila ICHIDAGI harakat chiqariladi
  ),
  dom as (
    -- Oiladan qaysi hisob eng ko'p harakat qildi (kassa_id / pul_turi / valyuta shundan)
    select m.e_id, x.a_id, x.a_nom, x.a_turi, x.a_cur
      from m
      join lateral (
        select a.id                            as a_id,
               a.name                          as a_nom,
               nullif(btrim(coalesce(a.pul_turi, '')), '') as a_turi,
               upper(coalesce(nullif(btrim(coalesce(a.currency, '')), ''), 'UZS')) as a_cur,
               sum(abs(l.debit - l.credit))    as w
          from entry_line l
          join accounts a on a.id = l.account_id
         where l.entry_id = m.e_id
           and l.account_id = any(v_ext)
         group by a.id, a.name, a.pul_turi, a.currency
         order by w desc, a.id asc
         limit 1) x on true
  ),
  q as (
    -- QARSHI TOMON: net ga qarama-qarshi tomondagi, oiladan TASHQARI eng katta satr
    select m.e_id, y.q_id, y.q_kod, y.q_nom, y.q_sec
      from m
      left join lateral (
        select a.id      as q_id,
               a.code    as q_kod,
               a.name    as q_nom,
               a.section as q_sec,
               sum(case when m.net < 0 then l.debit else l.credit end) as w
          from entry_line l
          join accounts a on a.id = l.account_id
         where l.entry_id = m.e_id
           and not (l.account_id = any(v_ext))
           and (case when m.net < 0 then l.debit else l.credit end) > 0
         group by a.id, a.code, a.name, a.section
         order by w desc, a.id asc
         limit 1) y on true
  ),
  r as (
    select e.e_id, e.e_date, e.e_created, e.e_desc, e.e_del, e.e_ijr,
           m.net, m.net_fc,
           dom.a_id, dom.a_nom, dom.a_turi, dom.a_cur,
           q.q_id, q.q_kod, q.q_nom, q.q_sec,
           -- 🔴 NIQOB QOROVULI (ai_ctx_transfer naqshi, fail-closed)
           (q.q_id is not null
            and (q.q_sec is distinct from 'pul'          -- modda/kapital/daromad — ochiq
                 or v_view is null                        -- cheklovsiz (admin)
                 or q.q_id = any(v_view))) as q_ok
      from e
      join m   on m.e_id   = e.e_id
      join dom on dom.e_id = e.e_id
      join q   on q.e_id   = e.e_id
  ),
  lim as (
    select * from r
     order by r.e_date desc, r.e_created desc, r.e_id desc
     limit v_lim
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'entry_id',   lim.e_id,
           'sana',       lim.e_date,
           'vaqt',       lim.e_created,
           'tur',        case when lim.net > 0
                              then case when lim.q_sec = 'pul' then 'transfer_kirim'  else 'kirim'  end
                              else case when lim.q_sec = 'pul' then 'transfer_chiqim' else 'chiqim' end
                         end,
           'summa',      abs(lim.net),
           -- izohda kassa nomi turadi -> tomon niqoblansa izoh ham niqoblanadi
           'izoh',       case when lim.q_ok
                              then nullif(btrim(left(coalesce(lim.e_desc, ''), 200)), '')
                              else null end,
           'qarshi_nom', case when lim.q_ok then lim.q_nom else 'Ruxsat yo''q' end,
           'qarshi_kod', case when lim.q_ok then lim.q_kod else null end,
           'kassa_id',   lim.a_id,
           'kassa_nom',  lim.a_nom,
           'pul_turi',   lim.a_turi,
           'valyuta',    lim.a_cur,
           'fc_summa',   nullif(abs(coalesce(lim.net_fc, 0)), 0),
           'ijrochi',    hodim_ijrochi_nomi(lim.e_ijr),
           'is_deleted', coalesce(lim.e_del, false)
         ) order by lim.e_date desc, lim.e_created desc, lim.e_id desc), '[]'::jsonb)
    into v_out
    from lim;

  return coalesce(v_out, '[]'::jsonb);
end $fn$;

revoke all on function hodim_amallar(date, date) from public, anon;
grant execute on function hodim_amallar(date, date) to authenticated;

comment on function hodim_amallar(date, date) is
  'Hodim OZ kassasi (va uning bola-hisoblari + qarz hisobi) boyicha davrdagi HAMMA amal: '
  'kirim / chiqim / transfer_kirim / transfer_chiqim. Manba FAQAT auth.uid() — foydalanuvchi ID argumenti YOQ. '
  'Oila aniqlash mantigi hodim_oz_tarix bilan AYNI. Summa = oila satrlarining sof harakati (begona pul sizmaydi). '
  'Begona PUL tomoni niqoblanadi: qarshi_nom=Ruxsat yoq, qarshi_kod=null va izoh ham null. '
  'Ochirilgan yozuvlar chiqariladi (is_deleted kaliti kontraktda qoladi). Limit 200.';
-- ⬆⬆⬆  2-BO'LIM oxiri  ⬆⬆⬆


-- #####################################################################
-- ##  3-BO'LIM — PostgREST sxemasini yangilash                       ##
-- #####################################################################
-- Busiz mijoz birinchi chaqiruvda PGRST202 oladi (mijozda zaxira bor,
-- ya'ni sahifa buzilmaydi — lekin yangi ro'yxat ko'rinmaydi).
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  4-BO'LIM — IMZO va GRANT TEKSHIRUVI (faqat katalog)            ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 4.1  Ikkala funksiya ham o'rnidami, xossalari to'g'rimi?
--      Kutilgan:
--        hodim_amallar      : prosecdef=t, provolatile='s', config={search_path=public}
--        hodim_ijrochi_nomi : prosecdef=t, provolatile='s', config={search_path=public}
-- ---------------------------------------------------------------------
select p.proname,
       pg_get_function_arguments(p.oid) as imzo,
       pg_get_function_result(p.oid)    as qaytish,
       p.prosecdef                      as security_definer,
       p.provolatile                    as volatile_s,
       p.proconfig                      as config
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('hodim_amallar', 'hodim_ijrochi_nomi')
 order by p.proname;


-- ---------------------------------------------------------------------
-- 4.2  Overload bormi? (PostgREST PGRST203 xavfi)
--      Kutilgan: har `proname` uchun AYNAN 1.
-- ---------------------------------------------------------------------
select p.proname, count(*) as overload_soni
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('hodim_amallar', 'hodim_ijrochi_nomi')
 group by p.proname
 order by p.proname;


-- ---------------------------------------------------------------------
-- 4.3  GRANT to'g'rimi?
--      Kutilgan AYNAN shunday:
--        amallar_authenticated = true    (mijoz chaqiradi)
--        amallar_anon          = false   (kirmagan foydalanuvchi YO'Q)
--        ijrochi_authenticated = false   🔴 ATAYLAB — ochiq ism-qidiruv
--                                        RPC bo'lib qolmasin
--        ijrochi_anon          = false
-- ---------------------------------------------------------------------
select has_function_privilege('authenticated', 'public.hodim_amallar(date,date)', 'execute') as amallar_authenticated,
       has_function_privilege('anon',          'public.hodim_amallar(date,date)', 'execute') as amallar_anon,
       has_function_privilege('authenticated', 'public.hodim_ijrochi_nomi(text)', 'execute') as ijrochi_authenticated,
       has_function_privilege('anon',          'public.hodim_ijrochi_nomi(text)', 'execute') as ijrochi_anon;


-- ---------------------------------------------------------------------
-- 4.4  🔴 SIZISH QOROVULLARI TANADA TURIBDIMI?
--      Hammasi `true` bo'lishi SHART. Birortasi `false` bo'lsa —
--      funksiya boshqa (eski/o'zgartirilgan) versiya, MENGA AYTING.
-- ---------------------------------------------------------------------
select position('auth.uid()'          in prosrc) > 0 as q_auth_uid,
       position('perm_op_key'         in prosrc) > 0 as q_perm_op_key,
       position('perm_view_pul_ids'   in prosrc) > 0 as q_view_ids,
       position('Ruxsat yo'           in prosrc) > 0 as q_niqob,
       position('is_deleted = false'  in prosrc) > 0 as q_ochirilgan_chiqarilgan,
       -- foydalanuvchi ID argumenti YO'Qligi: imzoda faqat ikkita date
       pg_get_function_arguments(oid) = 'p_from date, p_to date' as q_imzo_toza
  from pg_proc
 where oid = to_regprocedure('public.hodim_amallar(date,date)')::oid;


-- #####################################################################
-- ##  5-BO'LIM — QARORLAR (faqat izoh, RUN qilinadigan narsa yo'q)   ##
-- #####################################################################
--
-- 5.1  NEGA `hodim_oz_tarix` KENGAYTIRILMADI (yangi RPC ochildi)?
--      * Imzo bir xil bo'lsa ham javob SHAKLI o'zgarardi
--        (`{kategoriya, royxat}`), PROD `hodim.html` esa aynan shu
--        shaklga tayangan -> prod sahifa jimgina buzilardi. CLAUDE.md:
--        "imzo (argument/tur) o'zgartirish — TAQIQ".
--      * Yangi RPC bilan mijozda ZAXIRA yo'li mumkin: RPC yo'q/xato bo'lsa
--        eski xarajat ro'yxati avvalgidek ishlayveradi.
--
-- 5.2  NEGA SAHIFA QOROVULI (`perm_has_page`) YO'Q?
--      `hodim.html` ruxsat ro'yxatiga KIRMAYDI va hech qachon
--      cheklanmaydi (CLAUDE.md: `perm_pages()` ichida `hodim` kaliti
--      yo'q). `hodim_oz_tarix` da ham qorovul yo'q. Qorovul qo'yilsa
--      `allowed_pages = {}` bo'lgan 80% foydalanuvchi o'z xarajatini
--      ko'ra olmay qolardi. Himoya KASSA darajasida (oila + niqob).
--
-- 5.3  NEGA `kassa_scope <> 'list'` da BARCHA hodim kassasi ko'rinadi?
--      Bu YANGI ochilish emas — `hodim_oz_tarix` (V5 dan beri) ayni
--      shunday ishlaydi. `kassa_scope='all'` = admin/bugalter, ya'ni
--      cheklovsiz. Bu yerda BOSHQA qoida yozilsa bir ekranda ikki xil
--      ro'yxat bo'lardi. Haqiqiy hodimlar `kassa_scope='list'` bilan
--      sozlanadi va ular FAQAT o'z kassasini ko'radi.
--
-- 5.4  NEGA `net = 0` yozuv chiqariladi?
--      Oila ICHIDAGI harakat (Naqd -> Click, konvert). Hodimning puli
--      o'zgarmagan; 4 turning birortasi ham unga to'g'ri kelmaydi.
--      ⚠️ Kelajakda "ichki" turi kerak bo'lsa: `having` sharti olib
--      tashlanadi va `tur` ga `when net = 0 then 'ichki'` qo'shiladi —
--      mijoz noma'lum turni allaqachon "Amal" deb chizadi.
--
-- 5.5  DUBLIKAT XAVFI YO'Q: har yozuv `m` CTE da `group by e_id` bilan
--      AYNAN BIR QATORGA siqiladi; `dom` va `q` — `limit 1` li lateral.
--      Ya'ni ko'p satrli professional yozuv ham bitta qator beradi
--      (`hodim_oz_tarix` esa har Dt satri uchun alohida qator beradi —
--      bu ATAYLAB farq: u xarajat MODDALARI ro'yxati, bu esa AMALLAR).
--
-- 5.6  TEZLIK: og'ir joy — `e` CTE dagi `exists (... account_id = any(v_ext))`.
--      `entry_line(account_id)` va `entry(entry_date)` indekslari kifoya
--      (PROVODKA_HODIM_INDEKS.sql). Davr mijozda eng ko'pi 1 oy.


-- #####################################################################
-- ##  6-BO'LIM — IXTIYORIY DIAGNOSTIKA (faqat select)                ##
-- #####################################################################
-- 🔴 Bu yerda RPC JONLI CHAQIRILMAYDI: SQL editorda `auth.uid()` null,
--    ya'ni `hodim_amallar` bo'sh massiv qaytaradi va natija chalg'itadi.

-- ---------------------------------------------------------------------
-- 6.1  Hodim kassalari va ularning qarz hisoblari soni
-- ---------------------------------------------------------------------
select count(*) filter (where kassa_turi = 'xarajat')        as hodim_kassa_soni,
       count(*) filter (where kassa_turi = 'xarajat_guruh')  as konteyner_soni,
       count(*) filter (where code like '672%')              as qarz_hisob_soni
  from accounts;

-- ---------------------------------------------------------------------
-- 6.2  Oxirgi 30 kunda hodim kassalari qatnashgan yozuvlar — tur kesimi
--      (RUXSATSIZ, umumiy manzara. Foydalanuvchi ko'radigan ro'yxat
--      bundan KAM bo'ladi — oila + niqob cheklaydi.)
-- ---------------------------------------------------------------------
with fam as (
  select id from accounts where kassa_turi = 'xarajat'
),
mm as (
  select l.entry_id, sum(l.debit - l.credit) as net
    from entry_line l
    join fam f on f.id = l.account_id
    join entry e on e.id = l.entry_id
   where e.status = 'posted' and e.is_deleted = false
     and e.entry_date >= (now() at time zone 'Asia/Tashkent')::date - 30
   group by l.entry_id
)
select case when net > 0 then 'oilaga KIRDI' when net < 0 then 'oiladan CHIQDI' else 'ichki (chiqariladi)' end as yonalish,
       count(*) as yozuv_soni,
       sum(abs(net))::numeric as jami
  from mm
 group by 1
 order by 1;

-- ---------------------------------------------------------------------
-- 6.3  `entry.created_by` to'lganmi? (bo'sh bo'lsa `ijrochi` = 'Noma'lum')
-- ---------------------------------------------------------------------
select count(*)                                                                          as jami,
       count(*) filter (where nullif(btrim(coalesce(to_jsonb(e) ->> 'created_by','')),'') is not null) as ijrochili
  from entry e
 where e.entry_date >= (now() at time zone 'Asia/Tashkent')::date - 30;


-- #####################################################################
-- ##  7-BO'LIM — ROLLBACK                                            ##
-- #####################################################################
-- Ikkala funksiya ham YANGI, ya'ni ularni o'chirish hech qanday mavjud
-- xatti-harakatni qaytarmaydi — `hodim_oz_tarix` va qolgan hammasi
-- TEGILMAGAN. Mijozda zaxira bor: RPC yo'qolsa `hodim-dev.html`
-- avtomat eski xarajat ro'yxatiga qaytadi (PGRST202/42883).
--
-- Kerak bo'lsa (belgilab RUN qiling):
--
--   drop function if exists hodim_amallar(date, date);
--   drop function if exists hodim_ijrochi_nomi(text);
--   notify pgrst, 'reload schema';
--
-- =====================================================================
