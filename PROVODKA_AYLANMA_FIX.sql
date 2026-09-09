-- =====================================================================
-- PROVODKA — AYLANMA sahifasi tuzatishlari (2026-09-09, Asilbek)
-- ---------------------------------------------------------------------
-- ## MUAMMO (prodda topildi)
--   1) «kechagiga nisbatan — ma'lumot yo'q» chiqadi, holbuki kechada
--      snapshot BOR. Sabab: `aylanma_kun` oldingi kunni FAQAT `rejim='cron'`
--      qatorlardan qidiradi. Cron (n8n `o3BZP8uYatGkRu8b`) hali ishlamagan
--      bo'lsa, hamma snapshot `'qolda'` — demak oldingi kun HECH QACHON
--      topilmaydi.
--   2) Chiziqli grafik (trend) chizilmaydi. Ayni sabab: `aylanma_trend`
--      ham faqat `rejim='cron'` oladi -> 0 qator -> klient «Chizish uchun
--      kamida 2 kun kerak» deb turadi.
--
--   🔴 Bu AYNI xato bir marta tuzatilgan edi — `aylanma_kun` ning JORIY kun
--      shoxida (1094-satrdagi izoh: "2026-09-08: faqat cron izlanardi —
--      qo'lda ishga tushirilgan birinchi snapshot sahifada «ma'lumot yo'q»
--      bo'lib ko'rinardi"). O'sha paytda `oldingi` va `trend` shoxlari
--      e'tibordan chetda qolgan.
--
-- ## YECHIM (ikkalasida ham bir xil qoida)
--   Kun uchun BITTA snapshot olinadi: o'sha kunning `cron` qatori ustun,
--   bo'lmasa o'sha kunning ENG OXIRGI `qolda` qatori. Ya'ni cron ishga
--   tushgach ko'rinish o'zgarmaydi (cron baribir ustun), lekin cron
--   yo'q kunlar endi tushib qolmaydi.
--
-- ## 3-BO'LIM — Q2a (bizdan qarzdor) TASHXISI, hech narsa yozmaydi
--   Q2a raqami noto'g'ri ko'rinyapti. Ehtimoliy sabab quyida (3-BO'LIM
--   izohida) — avval SELECT natijasini ko'ramiz, keyin tuzatamiz.
--
-- ## QOIDALAR (CLAUDE.md)
--   * hammasi ADDITIVE: imzo o'zgarmaydi (`create or replace`), jadval
--     va ustunlarga TEGILMAYDI, `sync_aylanma_snapshot` TEGILMAYDI.
--   * anonim `do` bloki YO'Q; funksiya tanasi nomlangan dollar-teg bilan.
--   * idempotent: qayta RUN xavfsiz.
-- =====================================================================


-- #####################################################################
-- ##  0-BO'LIM — OLD SHART (faqat select/exception)                   ##
-- #####################################################################

do $aylfix_pre$
begin
  if to_regclass('public.aylanma_snapshot') is null then
    raise exception 'aylanma_snapshot yoq — avval PROVODKA_AYLANMA.sql ni bajaring';
  end if;
  if to_regprocedure('public.aylanma_kun(date,uuid)') is null then
    raise exception 'aylanma_kun(date,uuid) yoq — avval PROVODKA_AYLANMA.sql ni bajaring';
  end if;
  if to_regprocedure('public.aylanma_trend(date,date)') is null then
    raise exception 'aylanma_trend(date,date) yoq — avval PROVODKA_AYLANMA.sql ni bajaring';
  end if;
  if to_regprocedure('public.aylanma_page_ok()') is null then
    raise exception 'aylanma_page_ok() yoq — avval PROVODKA_AYLANMA.sql ni bajaring';
  end if;
end
$aylfix_pre$;


-- #####################################################################
-- ##  1-BO'LIM — aylanma_kun(date,uuid) — `oldingi` cron'ga bog'liq   ##
-- ##              bo'lmasin                                           ##
-- #####################################################################
-- 🔴 PROVODKA_AYLANMA.sql (1071-1138) dagi tananing VERBATIM nusxasi.
--    Yagona farq: `v_oldingi` so'rovidan `o.rejim = 'cron'` sharti OLINDI,
--    o'rniga kun ichida cron ustun turadigan tartib qo'yildi + javobga
--    `rejim` kaliti qo'shildi (klient «Qo'lda» ekanini ko'rsata olsin).

create or replace function aylanma_kun(p_sana date default null, p_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ayl_kun$
declare
  v_snap     aylanma_snapshot%rowtype;
  v_sana     date;
  v_qatorlar jsonb;
  v_oldingi  jsonb;
begin
  if not aylanma_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  if p_id is not null then
    select * into v_snap from aylanma_snapshot where id = p_id;
  else
    v_sana := coalesce(p_sana, (now() at time zone 'Asia/Tashkent')::date);
    -- Tartib: o'sha kun cron → o'sha kunning ENG OXIRGI qo'lda snapshoti →
    -- oldingi kunlarning eng oxirgisi (cron ustun, bo'lmasa qo'lda).
    -- (2026-09-08: faqat cron izlanardi — qo'lda ishga tushirilgan birinchi
    -- snapshot sahifada «ma'lumot yo'q» bo'lib ko'rinardi.)
    select * into v_snap from aylanma_snapshot
     where sana = v_sana
     order by (rejim = 'cron') desc, hisoblangan_at desc
     limit 1;
    if not found then
      select * into v_snap from aylanma_snapshot
       where sana < v_sana
       order by sana desc, (rejim = 'cron') desc, hisoblangan_at desc
       limit 1;
    end if;
  end if;

  if not found then
    return jsonb_build_object('ok', true, 'snapshot', null, 'qatorlar', '[]'::jsonb, 'oldingi', null);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'bolim', q.bolim, 'ref', q.ref, 'nom', q.nom,
           'usd', q.usd, 'uzs', q.uzs, 'soni', q.soni, 'hisobga', q.hisobga, 'meta', q.meta)
           order by q.bolim, q.uzs desc nulls last), '[]'::jsonb)
    into v_qatorlar
    from aylanma_qator q
   where q.snapshot_id = v_snap.id;

  -- 🔴 2026-09-09: `o.rejim = 'cron'` sharti OLINDI. Cron hali ishlamagan
  --    bo'lsa hamma snapshot 'qolda' bo'ladi va «kechagiga nisbatan» abadiy
  --    «ma'lumot yo'q» bo'lib qolardi. Endi oldingi kunning cron qatori
  --    ustun, bo'lmasa o'sha kunning eng oxirgi qo'lda qatori olinadi —
  --    ya'ni cron yoqilgach ko'rinish O'ZGARMAYDI.
  select jsonb_build_object('id', o.id, 'sana', o.sana, 'rejim', o.rejim,
                            'jami_uzs', o.jami_uzs, 'bolimlar', o.bolimlar)
    into v_oldingi
    from aylanma_snapshot o
   where o.sana < v_snap.sana
   order by o.sana desc, (o.rejim = 'cron') desc, o.hisoblangan_at desc nulls last
   limit 1;

  return jsonb_build_object(
    'ok', true,
    'snapshot', jsonb_build_object(
      'id', v_snap.id, 'sana', v_snap.sana, 'rejim', v_snap.rejim,
      'hisoblangan_at', v_snap.hisoblangan_at, 'kurs_usd', v_snap.kurs_usd,
      'jami_uzs', v_snap.jami_uzs, 'jami_usd', v_snap.jami_usd, 'toliq', v_snap.toliq,
      'bolimlar', v_snap.bolimlar, 'manba_holati', v_snap.manba_holati,
      'xatolar', to_jsonb(v_snap.xatolar)),
    'qatorlar', v_qatorlar,
    'oldingi', v_oldingi);
end
$ayl_kun$;

revoke all on function aylanma_kun(date, uuid) from public, anon;
grant execute on function aylanma_kun(date, uuid) to authenticated;

comment on function aylanma_kun(date, uuid) is
  'Bitta kunlik SAK snapshot (p_id bo''lsa aniq shu qator, aks holda p_sana — sukut bugun). '
  'YANGI (PROVODKA_AYLANMA_FIX.sql): `oldingi` endi cron''ga bog''liq emas — oldingi kunning '
  'cron qatori ustun, bo''lmasa o''sha kunning eng oxirgi qo''lda qatori.';


-- #####################################################################
-- ##  2-BO'LIM — aylanma_trend(date,date) — grafik qo'lda             ##
-- ##              snapshotlarni ham ko'rsin                           ##
-- #####################################################################
-- 🔴 PROVODKA_AYLANMA.sql (1149-1185) tanasining VERBATIM nusxasi.
--    Yagona farq: `where s.rejim = 'cron'` o'rniga HAR KUN uchun BITTA
--    qator (`distinct on (s.sana)`, cron ustun). Grafik nuqtalari kuniga
--    bitta bo'lib qoladi — ikki marta qo'lda hisoblangan kun ikki nuqta
--    bo'lib chiqmaydi.

create or replace function aylanma_trend(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $ayl_trend$
declare
  v_from date := p_from;
  v_to   date := p_to;
  v_tmp  date;
  v_rows jsonb;
begin
  if not aylanma_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  if v_from is null or v_to is null then
    return jsonb_build_object('ok', false, 'error', 'p_from/p_to kerak');
  end if;
  if v_to < v_from then
    v_tmp := v_from; v_from := v_to; v_to := v_tmp;    -- swap (chegara noto'g'ri kelsa)
  end if;
  if (v_to - v_from) > 400 then
    v_from := v_to - 400;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'sana', x.sana, 'jami_uzs', x.jami_uzs, 'jami_usd', x.jami_usd,
           'kurs_usd', x.kurs_usd, 'toliq', x.toliq, 'bolimlar', x.bolimlar, 'rejim', x.rejim)
           order by x.sana), '[]'::jsonb)
    into v_rows
    from (
      select distinct on (s.sana)
             s.id, s.sana, s.jami_uzs, s.jami_usd, s.kurs_usd, s.toliq, s.bolimlar, s.rejim
        from aylanma_snapshot s
       where s.sana between v_from and v_to
       order by s.sana, (s.rejim = 'cron') desc, s.hisoblangan_at desc nulls last
    ) x;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end
$ayl_trend$;

revoke all on function aylanma_trend(date, date) from public, anon;
grant execute on function aylanma_trend(date, date) to authenticated;

comment on function aylanma_trend(date, date) is
  'Grafik uchun: p_from..p_to oralig''ida HAR KUN bitta snapshot (cron ustun, bo''lmasa '
  'o''sha kunning eng oxirgi qo''lda qatori), <=400 kun. '
  'YANGI (PROVODKA_AYLANMA_FIX.sql): avval faqat rejim=cron olinardi — cron yoqilmagan '
  'bo''lsa grafik BO''SH qolardi.';


-- #####################################################################
-- ##  PostgREST sxema keshi                                           ##
-- #####################################################################
notify pgrst, 'reload schema';


-- #####################################################################
-- ##  3-BO'LIM — TEKSHIRUV (1 va 2 uchun) — faqat select              ##
-- #####################################################################

-- 3.1 Bazada nechta snapshot bor va qaysi rejimda
select sana, rejim, hisoblangan_at, jami_uzs, toliq
  from aylanma_snapshot
 order by sana desc, hisoblangan_at desc
 limit 20;

-- 3.2 Grafik nechta nuqta oladi (30 kun). 2 dan kam bo'lsa chiziq chizilmaydi —
--     bu KAMCHILIK EMAS, shunchaki hali kun yetarli emas.
select jsonb_array_length(aylanma_trend(
         ((now() at time zone 'Asia/Tashkent')::date - 30),
         ((now() at time zone 'Asia/Tashkent')::date)) -> 'rows') as trend_nuqta;

-- 3.3 «kechagiga nisbatan» endi to'ladimi (null BO'LMASLIGI kerak,
--     agar bugundan oldin kamida bitta snapshot bo'lsa)
select aylanma_kun(null, null) -> 'oldingi' as oldingi;


-- #####################################################################
-- ##  4-BO'LIM — Q2a «bizdan qarzdor» TASHXISI (faqat select)         ##
-- #####################################################################
-- HECH NARSA YOZMAYDI. Maqsad: Q2a qaysi qismi noto'g'ri ekanini KO'RISH.
--
-- Q2a hozirgi formulasi (PROVODKA_AYLANMA.sql 812-865):
--     Q2a = Provodka qarz            (sum v_qarz_holat.qolgan, status='faol')
--         + Aros umumiy qarz         (aros_qarzdor_sync.summary ->> 'total_debt')
--         − Aros mijozlar hamyoni    (sum aros_qarzdor.wallet_balance, faol)
--
-- 🔴 ASOSIY SHUBHA — ikki xil MANBA aralashgan:
--    `total_debt` Aros ning O'Z yig'indisi (butun ro'yxat uchun, summary),
--    `wallet_balance` esa BIZDAGI `aros_qarzdor` jadvalining yig'indisi.
--    Agar jadval to'liq sinxronlanmagan bo'lsa yoki `faol` bayrog'i eskirgan
--    bo'lsa — ayirma noto'g'ri chiqadi. Summary ning O'ZIDA mos qiymat bor:
--    `total_wallet_balance`. Quyidagi so'rov ikkalasini yonma-yon beradi:
--    agar ular FARQ QILSA — sabab shu.
--
-- 🔴 IKKINCHI SHUBHA: `summary.total_debt` ROSA qarzi bor mijozlarni ham,
--    qarzi 0 bo'lganlarni ham qamraydi (ARX: «2459 mijozning ~1/3 da qarz 0»).
--    Ularning hamyonidagi pul ham ayirilyapti. Bu ONGLI qaror bo'lishi mumkin
--    (hamyondagi pul — bizning majburiyatimiz), lekin «bizdan qarzdor»
--    raqamini kutilganidan KICHIK qiladi. Pastdagi `q2a_faqat_qarzdor`
--    varianti shuni ajratib ko'rsatadi.

select
  -- 1) Provodka qarz tizimi (Qarz sahifasidagi «jami_qolgan» bilan AYNAN bir xil formula)
  (select coalesce(sum(h.qolgan), 0)
     from qarz q join v_qarz_holat h on h.qarz_id = q.id
    where q.status = 'faol')                                          as provodka_qarz,

  -- 2) Aros umumiy qarz — summary (hozir Q2a shuni ishlatadi)
  (select coalesce((s.summary ->> 'total_debt')::numeric, 0)
     from aros_qarzdor_sync s where s.id = 1)                         as aros_summary_total_debt,

  -- 2b) O'sha raqamning jadvaldagi ekvivalenti (mos kelishi kerak)
  (select coalesce(sum(a.total_debt), 0)
     from aros_qarzdor a where a.faol)                                as aros_jadval_total_debt,

  -- 3) Hamyon — summary dagi qiymat (MOS manba)
  (select coalesce((s.summary ->> 'total_wallet_balance')::numeric, 0)
     from aros_qarzdor_sync s where s.id = 1)                         as hamyon_summary,

  -- 3b) Hamyon — jadvaldan, faol (hozir Q2a shuni ishlatadi)
  (select coalesce(sum(a.wallet_balance), 0)
     from aros_qarzdor a where a.faol)                                as hamyon_jadval_faol,

  -- 3c) Hamyon — jadvaldan, HAMMASI (faol filtri qanchaga ta'sir qilyapti)
  (select coalesce(sum(a.wallet_balance), 0) from aros_qarzdor a)     as hamyon_jadval_hammasi,

  -- 3d) Hamyon — FAQAT qarzi bor mijozlarniki
  (select coalesce(sum(a.wallet_balance), 0)
     from aros_qarzdor a where a.faol and a.total_debt > 0)           as hamyon_qarzdorlarniki,

  -- 4) Sinxron holati — jadval summary bilan bir vaqtdami
  (select s.synced_at from aros_qarzdor_sync s where s.id = 1)        as synced_at,
  (select s.soni      from aros_qarzdor_sync s where s.id = 1)        as summary_soni,
  (select count(*) from aros_qarzdor)                                 as jadval_soni,
  (select count(*) from aros_qarzdor a where a.faol)                  as jadval_faol_soni;

-- 4.2 Q2a ning uch varianti yonma-yon — qaysi biri kutgan raqamingiz?
with p as (
  select (select coalesce(sum(h.qolgan), 0)
            from qarz q join v_qarz_holat h on h.qarz_id = q.id
           where q.status = 'faol') as provodka,
         (select coalesce((s.summary ->> 'total_debt')::numeric, 0)
            from aros_qarzdor_sync s where s.id = 1) as debt,
         (select coalesce((s.summary ->> 'total_wallet_balance')::numeric, 0)
            from aros_qarzdor_sync s where s.id = 1) as w_sum,
         (select coalesce(sum(a.wallet_balance), 0)
            from aros_qarzdor a where a.faol) as w_tbl,
         (select coalesce(sum(a.wallet_balance), 0)
            from aros_qarzdor a where a.faol and a.total_debt > 0) as w_qarzdor
)
select provodka + debt                as q2a_hamyonsiz,
       provodka + debt - w_tbl        as q2a_hozirgi,
       provodka + debt - w_sum        as q2a_summary_asosida,
       provodka + debt - w_qarzdor    as q2a_faqat_qarzdor
  from p;

-- 4.3 Snapshotda AYNAN nima saqlangan (oxirgi snapshot Q2a qatorlari)
select q.ref, q.nom, q.uzs, q.meta
  from aylanma_qator q
  join aylanma_snapshot s on s.id = q.snapshot_id
 where q.bolim = 'Q2a'
   and s.id = (select id from aylanma_snapshot order by sana desc, hisoblangan_at desc limit 1)
 order by q.ref;

-- KEYINGI QADAM: 4.2 dagi qaysi ustun to'g'ri ekanini ayting — Q2a shunga
-- moslab tuzatiladi (sync_aylanma_snapshot ning Q2a bloki, imzo o'zgarmaydi).
