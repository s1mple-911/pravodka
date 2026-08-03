-- =====================================================================
--  PROVODKA_TRANSFER.sql — 2-BOSQICH: Aros cachier-transfer sync
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  RPC:  sync_transfer_balans(p_data jsonb,
--                             p_dry_run boolean default false,
--                             p_from    timestamptz default null) -> jsonb
--
--  Filialdan markaziy kassaga qabul qilingan pul TUR bo'yicha yoziladi:
--        Dt <markaziy kassa . tur child>  /  Kt <filial kassa . tur child>
--  (naqd->naqd, click->click, payme->payme, USD->USD — tur saqlanadi)
--
--
--  #####  IKKI MARTA YOZILISH — TAHLIL VA TANLANGAN YECHIM  #############
--
--  Muammo: Aros filial balansi transferni HISOBGA OLGAN (pul jo'natilsa
--  filial balansi kamaygan). sync_filial_balans esa o'sha kamayishni
--  ko'rib "chiqim" (Dt 9010) deb yozadi. Transfer ham yozilsa — ikki marta.
--
--  ⚠️ Variant A (delta'dan transfer summasini AYIRISH) — XATO BO'LARDI.
--     Sabab: delta = aros − DAFTAR. Transfer yozuvi daftarni allaqachon
--     kamaytirgan, ya'ni delta uni ko'rgan. Yana ayirsak IKKI MARTA
--     ayirilgan bo'lardi (endi teskari tomonga xato).
--
--  ⚠️ Variant B (transferlarsiz "xom balans"dan hisoblash) — to'g'ri,
--     lekin har filial × tur uchun ikkinchi (soya) balans yuritishni
--     talab qiladi. Keraksiz murakkablik.
--
--  ✅ TANLANDI — Variant C: TARTIB. Hech narsa ayirilmaydi.
--     sync_filial_balans ga UMUMAN TEGILMAYDI (ishlab turgan, pul
--     yozadigan RPC — teginmaslikning o'zi yutuq).
--
--     Delta sync "qo'shish" emas, "tenglashtirish": u daftarni Aros'ga
--     tenglashtiradi. Transfer avval yozilsa, delta'ga QOLGANI aynan
--     haqiqiy savdo/xarajat bo'lib qoladi:
--
--       boshi:                   daftar A      | aros A
--       filial 3 sotdi, 5 jo'natdi:            | aros A+3−5 = A−2
--       1) transfer yozildi:     daftar A−5    | aros A−2
--       2) delta = (A−2)−(A−5) = +3  ->  Dt filial / Kt 9010 = 3  ✅ savdo
--       markaziy tomon: transfer +5, aros +5 -> delta = 0          ✅ soxta tushum yo'q
--
--     Ya'ni yechim bitta qoidaga tushadi:
--
--       ###  HAR SIKLDA: AVVAL TRANSFER, KEYIN BALANS DELTASI  ###
--
--     n8n uchun aniq tartib (MUHIM):
--       1. cachier-transfers ni o'qi
--       2. sync_transfer_balans(...)          <- avval SHU
--       3. cachiers balanslarini YANGIDAN o'qi (2-qadamdan KEYIN)
--       4. sync_filial_balans(...)            <- keyin SHU
--     Balans snapshot'i transfer yozilgandan keyin olinsa, u transferni
--     allaqachon o'z ichiga oladi va delta 0 chiqadi.
--     Tartibni umuman xato qilib bo'lmasligi uchun 3-bo'limdagi
--     sync_aros_full() wrapper'i bor — n8n bitta chaqiruv qilsa bo'ladi.
--
--     Qo'shimcha to'siq: bu RPC ikkala advisory lock'ni ham oladi
--     ('sync_filial_balans' + 'sync_transfer_balans'), shuning uchun
--     transfer yozilayotganda delta sync O'RTAGA TUSHA OLMAYDI.
--
--
--  #####  CUTOFF — eng xavfli joy, shuning uchun MAJBURIY  ##############
--
--  ⚠️⚠️ TUZATILDI (avvalgi mantiq XATO edi — o'qing, sabab muhim):
--
--  Avval cutoff "BIRINCHI delta sync payti (boshlang'ich qoldiq)" deb
--  olingan edi. Bu NOTO'G'RI. Sabab:
--
--     Delta sync bir martalik emas — u HAR 30 DAQIQADA daftarni Aros'ga
--     QAYTA TENGLASHTIRADI. Ya'ni har ishlaganda daftar = Aros bo'lib
--     qoladi, va o'sha paytgacha bo'lgan HAMMA transfer daftarga allaqachon
--     singib ketgan bo'ladi (filialda "chiqim", markaziyda "kirim" bo'lib).
--
--     Demak "allaqachon hisobga olingan" chegara — boshlang'ich qoldiq
--     emas, OXIRGI delta sync. Undan oldingi transferni yozish = ikki
--     marta ayirish.
--
--  ✅ TO'G'RI QOIDA:
--
--       cutoff = OXIRGI delta sync (balans sinxroni) vaqti
--       faqat  received_at > cutoff  bo'lgan transfer yoziladi
--
--  Cutoff manbasi (eng ishonchlisidan):
--     1. aros_sync_state.last_balans_at — delta sync tugagach qo'yiladigan
--        muhr (ixtiyoriy, n8n bitta node bilan qo'yadi — 0.5-bo'limga qarang)
--     2. `aros_sync` yozuvlarining MAX(created_at) — oxirgi delta sync
--        biror narsa yozgan payt (muhr bo'lmasa shu ishlatiladi)
--     Ikkovidan KATTASI olinadi.
--
--  p_from argumenti faqat QATTIQLASHTIRA oladi (kechroq sana bera oladi).
--  Undan oldingi sana berilsa E'TIBORSIZ qoldiriladi va javobda aytiladi —
--  aks holda qo'lda berilgan eski sana himoyani ochib yuborardi.
--
--  ❌ sync_state.transfers_from ENDI ISHLATILMAYDI. U eski (o'chirilgan)
--     sync_received_transfers mexanizminiki va ma'nosi boshqa: "Aros'dan
--     qaysi sanadan boshlab O'QISH kerak", "daftar haqiqati qayerdan
--     boshlanadi" emas. Qiymati oylar oldingi bo'lishi mumkin va himoyani
--     butunlay ochib yuborardi. Diagnostika uchun ko'rsatiladi, xolos.
--
--  Cutoff umuman topilmasa (delta sync hech qachon ishlamagan) RPC
--  HECH NARSA YOZMAYDI -> ok:false. (p_dry_run bunda ham ishlaydi.)
--
--  KONSERVATIV YO'NALISH: chegara ustidagi shubhali holatlarda transfer
--  YOZILMAYDI. U holda o'sha pul delta tomonidan "tushum/chiqim" bo'lib
--  yoziladi — noto'g'ri TASNIF, lekin pul ikki marta ketmaydi. Teskarisi
--  (ikki marta ayirish) — tuzatib bo'lmaydigan zarar.
--
--
--  #####  QOLGAN NOZIK JOY: sent -> received oynasi  ###################
--
--  Aros filial balansi pul JO'NATILGANDA kamayadi, biz esa QABUL
--  QILINGANDA yozamiz. Oradagi siklda delta o'sha kamayishni "manfiy
--  tushum" deb yozadi; qabul qilingach transfer yozilib, keyingi delta
--  uni teskarisi bilan NOLGA chiqaradi. Ya'ni PUL TO'G'RI, lekin jurnalda
--  ikkita ortiqcha satr qoladi va o'sha kunlik P&L chalg'iydi.
--
--  Oyna qisqa (soatlar) bo'lsa — chidasa bo'ladi, hozircha shunday
--  qoldirildi (brief: "sent hozircha yozilmaydi"). Uzoq bo'lsa 3-bosqichda
--  "Yo'ldagi pul (transit)" hisobi qo'shiladi:
--     sent     -> Dt transit / Kt filial       (ext_ref ...:sent)
--     received -> Dt markaziy / Kt transit     (ext_ref ...:recv)
--  ext_ref sxemasi shunga tayyor qilib qo'yilgan (pastga qarang).
--
--
--  #####  TAKRORLANMASLIK  #############################################
--
--  Har transfer × har tur uchun BITTA entry:
--     entry.ext_ref = 'aros_tr:<transfer_id>:<tur>'
--  ext_ref UNIQUE — baza darajasida ikkinchi marta yozilmaydi. RPC
--  qo'shimcha ravishda oldindan tekshiradi (is_deleted bo'lsa ham qayta
--  yozmaydi — admin o'chirgan yozuvni sync tiriltirmasin).
--
--  ATOMIK: plpgsql chaqiruvchi tranzaksiyasida ishlaydi — biror joyda
--  xato chiqsa hammasi orqaga qaytadi.
--
--  TALAB: PROVODKA_VALYUTA.sql (pul_turi), PROVODKA_VALYUTA_SEED.sql
--         (tur child'lari), PROVODKA_KAPITAL.sql, PROVODKA_SYNC_BALANS.sql.
--
--  YONDOSH FAYLLAR:
--    PROVODKA_AROS_TITLE.sql — accounts.aros_title ni Aros nomlari bilan
--         to'ldiradi. Sender FAQAT NOM bilan kelgani uchun SHU KERAK.
--    PROVODKA_TRANSFER_TEST.sql — takrorlanmaslikni haqiqiy bazada sinaydi
--         (hamma narsa orqaga qaytadi, iz qolmaydi). Sync'ni yoqishdan
--         OLDIN shuni RUN qiling.
-- =====================================================================


-- ---------------------------------------------------------------------
--  KUTILADIGAN JSON  (n8n shu shaklda yuboradi)
-- ---------------------------------------------------------------------
--  Ikki shakl ham qabul qilinadi:
--    (a) to'g'ridan massiv:  [ {...}, {...} ]
--    (b) o'ram bilan:        { "transferlar": [...] }  yoki { "transfers": [...] }
--
--  Har element:
--    {
--      "id":            12345,                  MAJBURIY — Aros transfer id
--      "status":        "received",             yo'q bo'lsa 'received' deb olinadi
--      "sender_id":     3,                      ixtiyoriy — Aros cachier id (ANIQ kalit)
--      "sender_title":  "Yunusobod Universam",  sender_id bo'lmasa shu ishlatiladi
--      "receiver_id":   1,                      ixtiyoriy — Aros cachier id
--      "receiver_title":"Toshkent Kassa",
--      "received_at":   "2026-07-30T14:22:00",  MAJBURIY (cutoff shunga qarab)
--      "cash":  5000000, "click": 0, "payme": 0,
--      "dollar_usd": 0,                         DOLLARDA (so'mda emas!)
--      "dollar_rate": 12100                     ixtiyoriy
--    }
--
--  MAYDON SINONIMLARI (Aros detali qanday kelsa shunday yuborsa ham bo'ladi):
--    id           <- id | transfer_id
--    received_at  <- received_at | received_datetime
--    cash         <- cash | seller_cash
--    click        <- click | seller_click
--    payme        <- payme | seller_payme
--    dollar_usd   <- dollar_usd | seller_dollar | dollar
--    dollar_rate  <- dollar_rate | currency_rate (obyekt bo'lsa .rate) | rate
--
--  ⚠️ SUMMALAR: n8n items[] bo'yicha YIG'IB yuborsin (bitta transferning
--     har turi uchun bitta son). RPC ichida items ochilmaydi.
--
--  ⚠️ received_at vaqt zonasiz kelsa (Aros naive saqlaydi) Toshkent vaqti
--     deb olinadi (+05). Zonali kelsa — qanday bo'lsa shunday.
--
--  ⚠️ status 'received' BO'LMAGANI yozilmaydi (sent = yo'ldagi pul,
--     canceled = bo'lmagan pul). Ular sanaladi va javobda ko'rinadi.
-- ---------------------------------------------------------------------



-- #####################################################################
--  0-BO'LIM — ext_ref UNIQUE: IKKI MARTA YOZILMASLIKNING POYDEVORI
-- #####################################################################
--  Takrorlanmaslik UCH QATLAM bilan ta'minlanadi:
--
--    1-qatlam (RPC ichida): har tur uchun yozishdan oldin
--         if exists (select 1 from entry where ext_ref = 'aros_tr:<id>:<tur>')
--       -> bor bo'lsa o'tkazib yuboriladi ("takror" deb sanaladi).
--       ⚠️ `is_deleted` bo'yicha FILTRLAMAYDI — admin o'chirgan yozuvni
--          sync qayta tiriltirmasin (aks holda o'chirish ma'nosini yo'qotardi).
--
--    2-qatlam (baza): entry.ext_ref ustidagi UNIQUE indeks. Ikki sync bir
--       vaqtda ishlab, ikkalasi ham "yo'q ekan" deb ko'rsa ham — ikkinchisi
--       INSERT paytida unique_violation oladi.
--
--    3-qatlam (RPC ichida): o'sha unique_violation `exception` bloki bilan
--       ushlanadi -> "takror" deb sanaladi, sync yiqilmaydi, PUL YOZILMAYDI.
--
--  Ya'ni hamma narsa 2-qatlamga tayanadi. Shuning uchun indeks BOR ekanini
--  shu yerda tekshiramiz, yo'q bo'lsa yaratamiz (additive, xavfsiz).
do $uniq$
declare
  v_bor  int;
  v_dub  int;
  v_ruy  text;
begin
  select count(*)
    into v_bor
    from pg_index x
    join pg_class t     on t.oid = x.indrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public'
     and t.relname = 'entry'
     and x.indisunique
     and x.indnkeyatts = 1
     and x.indkey[0] = (select attnum from pg_attribute
                         where attrelid = t.oid and attname = 'ext_ref' and not attisdropped);

  if v_bor > 0 then
    raise notice '✅ entry.ext_ref ustida UNIQUE indeks BOR (% ta) — takror to''sig''i ishlaydi', v_bor;
    return;
  end if;

  -- Yo'q ekan. Yaratishdan oldin: dublikat bormi (bo'lsa indeks yaralmaydi)
  select count(*) into v_dub
    from (select ext_ref from entry
           where ext_ref is not null
           group by ext_ref having count(*) > 1) s;

  if v_dub > 0 then
    select string_agg(ext_ref, ', ') into v_ruy
      from (select ext_ref from entry
             where ext_ref is not null
             group by ext_ref having count(*) > 1 limit 10) s;
    raise exception 'TO''XTADI: entry.ext_ref da % ta takroriy qiymat bor (%). '
                    'UNIQUE indeks yaratib bo''lmaydi. Avval takrorlarni hal qiling — '
                    'ular allaqachon ikki marta yozilgan yozuvlar bo''lishi mumkin!', v_dub, v_ruy;
  end if;

  create unique index entry_ext_ref_uniq on entry(ext_ref);
  raise notice '⚙️ YARATILDI: entry_ext_ref_uniq (entry.ext_ref UNIQUE). '
               'Null qiymatlar cheklanmaydi — qo''lda yozuvlar ta''sirlanmaydi.';
end
$uniq$;


-- #####################################################################
--  0.5-BO'LIM — CUTOFF: "daftar haqiqati" chegarasi
-- #####################################################################
--  Bu bo'lim bitta savolga javob beradi:
--     "Daftar Aros bilan OXIRGI MARTA qachon tenglashtirilgan?"
--  Undan oldingi hamma transfer daftarga allaqachon singib ketgan —
--  ularni yozish ikki marta ayirish demak.

-- ---------------------------------------------------------------------
-- 0.5.1 aros_sync_state — sync muhri (bitta qator, id = 1)
-- ---------------------------------------------------------------------
-- Ixtiyoriy, lekin TAVSIYA ETILADI. Muhrsiz ham ishlaydi (o'shanda oxirgi
-- `aros_sync` YOZUVI vaqti ishlatiladi), lekin muhr aniqroq: delta sync
-- hech narsa yozmagan siklni ham qayd etadi.
create table if not exists aros_sync_state (
  id               int primary key default 1,
  last_balans_at   timestamptz,     -- delta (balans) sync oxirgi marta TUGAGAN payt
  last_transfer_at timestamptz,     -- transfer sync oxirgi marta ishlagan payt (ma'lumot uchun)
  constraint aros_sync_state_bitta check (id = 1)
);

insert into aros_sync_state(id) values (1) on conflict (id) do nothing;

alter table aros_sync_state enable row level security;
revoke all on aros_sync_state from public, anon, authenticated;
grant select, insert, update on aros_sync_state to service_role;

comment on table aros_sync_state is
  'Aros sync muhri. last_balans_at = daftar Aros bilan oxirgi marta tenglashtirilgan payt. '
  'Transfer sync cutoff''i shunga tayanadi: undan OLDINGI transfer yozilmaydi.';


-- ---------------------------------------------------------------------
-- 0.5.2 aros_sync_stamp(nima) — muhrni qo'yish
-- ---------------------------------------------------------------------
-- ⚠️ 'balans' muhri delta sync TUGAGANDAN KEYIN qo'yilishi shart.
--    Oldin qo'yilsa cutoff kerakdan oldinga siljiydi va haqiqiy yangi
--    transferlar to'silib qoladi (pul yo'qolmaydi, lekin tasnif buziladi).
-- n8n: delta sync node'idan KEYIN bitta HTTP node —
--    POST .../rpc/aros_sync_stamp   body: {"p_nima": "balans"}
--
-- ⚠️ p_vaqt — "Aros balansi QACHON O'QILGAN" payti (ixtiyoriy, lekin ANIQROQ).
--    Muhrning ma'nosi: "daftar Aros'ning SHU PAYTDAGI holatiga tenglashdi".
--    Bu Aros balansi O'QILGAN payt, RPC chaqirilgan payt emas. Ikkovi orasida
--    (n8n o'qidi -> RPC'ga yubordi) bir necha soniya/daqiqa bor va o'sha oynada
--    kelgan transfer balansda YO'Q, lekin muhr now() bilan qo'yilsa keyingi
--    siklda cutoff uni to'sib qo'yadi -> u pul "tushum" bo'lib yoziladi
--    (pul to'g'ri, tasnif xato). p_vaqt berilsa bu oyna butunlay yopiladi.
--    n8n: balansni o'qish node'idan OLDIN {{ $now }} ni saqlab qo'ying va
--    shuni p_vaqt qilib yuboring.
--
-- Muhr HECH QACHON ORQAGA ketmaydi (greatest) — kech kelgan eski p_vaqt
-- himoyani zaiflashtira olmasin. Kelajak vaqt ham qabul qilinmaydi.
create or replace function aros_sync_stamp(p_nima text,
                                           p_vaqt timestamptz default null)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vaqt timestamptz := coalesce(p_vaqt, now());
  v_res  timestamptz;
begin
  if p_nima not in ('balans', 'transfer') then
    raise exception 'aros_sync_stamp: p_nima "balans" yoki "transfer" bo''lishi kerak (keldi: %)', p_nima;
  end if;

  -- Kelajakdagi muhr cutoff'ni oldinga surib, haqiqiy transferlarni to'sib
  -- qo'yardi. 1 daqiqa — soat farqiga chidam.
  if v_vaqt > now() + interval '1 minute' then
    raise exception 'aros_sync_stamp: p_vaqt kelajakda (%) — muhr qo''yilmadi', v_vaqt;
  end if;

  insert into aros_sync_state(id, last_balans_at, last_transfer_at)
  values (1,
          case when p_nima = 'balans'   then v_vaqt end,
          case when p_nima = 'transfer' then v_vaqt end)
  on conflict (id) do update
     set last_balans_at   = case when p_nima = 'balans'
                                 then greatest(aros_sync_state.last_balans_at, v_vaqt)
                                 else aros_sync_state.last_balans_at end,
         last_transfer_at = case when p_nima = 'transfer'
                                 then greatest(aros_sync_state.last_transfer_at, v_vaqt)
                                 else aros_sync_state.last_transfer_at end
  returning (case when p_nima = 'balans' then last_balans_at else last_transfer_at end)
       into v_res;

  return v_res;
end $$;

revoke all on function aros_sync_stamp(text, timestamptz) from public, anon, authenticated;
grant execute on function aros_sync_stamp(text, timestamptz) to service_role;

comment on function aros_sync_stamp(text, timestamptz) is
  'Aros sync muhri. p_nima=''balans'' -> daftar Aros bilan tenglashgan payt (transfer '
  'cutoff''i shundan olinadi). p_vaqt = Aros balansi O''QILGAN payt (berilmasa now()). '
  'Muhr orqaga ketmaydi.';


-- ---------------------------------------------------------------------
-- 0.5.3 aros_transfer_cutoff(p_from) — cutoff'ning YAGONA manbasi
-- ---------------------------------------------------------------------
-- RPC ham, diagnostika ham SHU funksiyadan oladi — ikki joyda ikki xil
-- mantiq bo'lib qolmasin. Faqat o'qiydi, hech narsa yozmaydi.
--
-- Qaytishi:
--   { "cutoff": ..., "manba": ...,
--     "oxirgi_delta_yozuvi": ..., "birinchi_delta_yozuvi": ..., "delta_yozuvlari": N,
--     "muhr_last_balans_at": ...,
--     "p_from": ..., "p_from_ishlatilmadi": true|false,
--     "sync_state_transfers_from": "..."   <- FAQAT MA'LUMOT, ishlatilmaydi
--   }
create or replace function aros_transfer_cutoff(p_from timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_muhr     timestamptz;
  v_oxirgi   timestamptz;
  v_birinchi timestamptz;
  v_n        int := 0;
  v_ss       text;
  v_cut      timestamptz;
  v_manba    text;
  v_qoldi    boolean := false;
begin
  -- 1) Muhr (bo'lsa)
  if to_regclass('public.aros_sync_state') is not null then
    begin
      execute 'select last_balans_at from aros_sync_state where id = 1' into v_muhr;
    exception when others then
      v_muhr := null;
    end;
  end if;

  -- 2) Oxirgi delta sync YOZUVI
  select min(created_at), max(created_at), count(*)
    into v_birinchi, v_oxirgi, v_n
    from entry
   where source = 'aros_auto' and created_by = 'aros_sync';

  -- Ikkovidan KATTASI (greatest null'ni e'tiborsiz qoldiradi)
  v_cut := greatest(v_muhr, v_oxirgi);
  v_manba := case
               when v_cut is null                      then null
               when v_muhr is not null and v_cut = v_muhr then 'aros_sync_state.last_balans_at (muhr)'
               else 'oxirgi delta sync yozuvi (entry.created_at)'
             end;

  -- 3) p_from FAQAT qattiqlashtira oladi
  if p_from is not null then
    if v_cut is null or p_from > v_cut then
      v_cut   := p_from;
      v_manba := 'p_from (qattiqroq — chegaradan keyin)';
    else
      v_qoldi := true;    -- berilgan, lekin chegaradan oldin -> e'tiborsiz
    end if;
  end if;

  -- 4) Eski mexanizm qiymati — FAQAT diagnostika uchun ko'rsatiladi
  if to_regclass('public.sync_state') is not null then
    begin
      execute 'select max(transfers_from)::text from sync_state' into v_ss;
    exception when others then
      v_ss := null;
    end;
  end if;

  return jsonb_build_object(
    'cutoff', v_cut,
    'manba', coalesce(v_manba, '(topilmadi)'),
    'muhr_last_balans_at', v_muhr,
    'oxirgi_delta_yozuvi', v_oxirgi,
    'birinchi_delta_yozuvi', v_birinchi,
    'delta_yozuvlari', v_n,
    'p_from', p_from,
    'p_from_ishlatilmadi', v_qoldi,
    'sync_state_transfers_from', v_ss,
    'izoh', 'Faqat received_at > cutoff bo''lgan transfer yoziladi. '
            || 'sync_state.transfers_from ISHLATILMAYDI (eski mexanizmniki).');
end $$;

revoke all on function aros_transfer_cutoff(timestamptz) from public, anon;
grant execute on function aros_transfer_cutoff(timestamptz) to authenticated, service_role;

comment on function aros_transfer_cutoff(timestamptz) is
  'Transfer sync cutoff''i: daftar Aros bilan oxirgi marta tenglashtirilgan payt. '
  'Undan oldingi transferlar daftarga allaqachon singigan — yozilmaydi.';


-- #####################################################################
--  1-BO'LIM — YORDAMCHI FUNKSIYALAR
-- #####################################################################

-- ---------------------------------------------------------------------
-- 1.1 aros_nom_norm(text) — nomlarni solishtirish uchun normallashtirish
-- ---------------------------------------------------------------------
-- "Qarshi" va "Karshi", "Toshkent Kassa" va "toshkent  kassa" bir xil
-- bo'lishi kerak. Shuning uchun: kichik harf -> q=k, x=h -> harf va
-- raqamdan boshqa hamma narsa (bo'sh joy, apostrof, tire) olib tashlanadi.
--   'Qashqadaryo Kassa' -> 'kashkadaryokassa'
--   'Karshi Bahor'      -> 'karshibahor'
--   'Qarshi Bahor'      -> 'karshibahor'   (bir xil — aynan shu kerak)
create or replace function aros_nom_norm(p_nom text)
returns text
language sql
immutable
as $$
  select nullif(
           regexp_replace(
             translate(lower(btrim(coalesce(p_nom, ''))), 'qx', 'kh'),
             '[^a-z0-9]', '', 'g'),
           '');
$$;

revoke all on function aros_nom_norm(text) from public, anon;
grant execute on function aros_nom_norm(text) to authenticated, service_role;

comment on function aros_nom_norm(text) is
  'Kassa nomini solishtirish uchun normallashtiradi (q=k, x=h, faqat harf/raqam). '
  'Qarshi/Karshi kabi yozilish farqi mosligni buzmasin.';


-- ---------------------------------------------------------------------
-- 1.2 aros_tur_hisob(kassa, maydon) — kassaning TUR child'i
-- ---------------------------------------------------------------------
-- Aros maydoni (cash|click|payme|dollar_usd) -> o'sha kassaning bola-hisobi.
-- v_filial_sync_mapping ISHLATILMAYDI: u faqat filial_ref to'ldirilgan
-- kassalarni ko'rsatadi, markaziy kassada esa filial_ref bo'lmasligi mumkin.
--
-- Shartlar (delta sync'dagi xavfsizlik to'sig'i bilan bir xil):
--   • child faol, section='pul'
--   • parent — mustaqil (top-level) faol pul kassasi
--   • som turi: pul_turi mos + currency UZS
--   • dollar:   currency='USD'
create or replace function aros_tur_hisob(p_kassa uuid, p_maydon text)
returns uuid
language sql
stable
as $$
  select c.id
    from accounts c
    join accounts k on k.id = c.parent_id
   where c.parent_id = p_kassa
     and c.is_active and c.section = 'pul'
     and k.is_active and k.section = 'pul' and k.parent_id is null
     and (
           ( p_maydon in ('cash','naqd','click','payme')
             and c.pul_turi = case p_maydon when 'cash' then 'naqd' else p_maydon end
             and coalesce(c.currency, 'UZS') = 'UZS' )
        or ( p_maydon in ('dollar_usd','dollar','usd')
             and c.currency = 'USD' )
         )
   order by c.code
   limit 1;
$$;

revoke all on function aros_tur_hisob(uuid, text) from public, anon;
grant execute on function aros_tur_hisob(uuid, text) to authenticated, service_role;

comment on function aros_tur_hisob(uuid, text) is
  'Kassaning tur child hisobi: cash|click|payme -> pul_turi, dollar_usd -> currency=USD. '
  'Transfer sync shu bilan Dt/Kt hisoblarini topadi.';


-- ---------------------------------------------------------------------
-- 1.3 aros_kassa_topish(ref, nom) — Aros tomonini Provodka kassasiga bog'lash
-- ---------------------------------------------------------------------
-- Tartib (birinchi moslik yutadi):
--   1. filial_ref (Aros cachier id) — ENG ISHONCHLI
--   2. accounts.aros_title (normallashtirilgan)  <- SENDER shu bilan topiladi:
--      transferda sender uchun faqat NOM keladi, id kelmaydi. aros_title ni
--      Aros nomlari bilan to'ldirish: PROVODKA_AROS_TITLE.sql (sync_aros_title).
--   3. accounts.name (normallashtirilgan)
--   4. qattiq jadval: 'Toshkent Kassa' -> 5011, 'Qashqadaryo Kassa' -> 5012
--
-- ⚠️ Bir nechta moslik topilsa — ATAYLAB null qaytaradi (sabab bilan).
--    Pul yozadigan joyda "tasodifiy birini olish" mumkin emas.
--
-- Qaytishi: {"ok":true, "id":..., "code":..., "name":..., "usul":...}
--        yoki {"ok":false, "sabab":"..."}
create or replace function aros_kassa_topish(p_ref text, p_nom text)
returns jsonb
language plpgsql
stable
as $$
declare
  v_ref  text;
  v_nrm  text;
  v_n    int;
  v_id   uuid;
  v_usul text;
  v_code text;
  v_name text;
  v_nomlar text;
begin
  v_ref := nullif(btrim(coalesce(p_ref, '')), '');
  v_nrm := aros_nom_norm(p_nom);

  if v_ref is null and v_nrm is null then
    return jsonb_build_object('ok', false, 'sabab', 'na id, na nom berilgan');
  end if;

  -- ---- 1) Aros cachier id (filial_ref) ----
  if v_ref is not null then
    select count(*), (array_agg(a.id order by a.code))[1]
      into v_n, v_id
      from accounts a
     where a.section = 'pul' and a.is_active and a.parent_id is null
       and coalesce(a.currency, 'UZS') = 'UZS'
       and coalesce(a.kassa_turi, '') <> 'xarajat_guruh'
       and a.filial_ref is not null
       and ( btrim(a.filial_ref::text) = v_ref
             or ( v_ref ~ '^-?[0-9]+(\.[0-9]+)?$'
                  and btrim(a.filial_ref::text) ~ '^-?[0-9]+(\.[0-9]+)?$'
                  and btrim(a.filial_ref::text)::numeric = v_ref::numeric ) );

    if v_n > 1 then
      return jsonb_build_object('ok', false,
        'sabab', 'filial_ref=' || v_ref || ' bir nechta kassada — dublikatni avval hal qiling');
    elsif v_n = 1 then
      v_usul := 'filial_ref';
    else
      v_id := null;
    end if;
  end if;

  -- ---- 2) aros_title ----
  if v_id is null and v_nrm is not null then
    select count(*), (array_agg(a.id order by a.code))[1]
      into v_n, v_id
      from accounts a
     where a.section = 'pul' and a.is_active and a.parent_id is null
       and coalesce(a.currency, 'UZS') = 'UZS'
       and coalesce(a.kassa_turi, '') <> 'xarajat_guruh'
       and aros_nom_norm(a.aros_title) = v_nrm;

    if v_n > 1 then
      return jsonb_build_object('ok', false,
        'sabab', 'aros_title "' || coalesce(p_nom, '') || '" bir nechta kassaga mos keldi');
    elsif v_n = 1 then
      v_usul := 'aros_title';
    else
      v_id := null;
    end if;
  end if;

  -- ---- 3) kassa nomi ----
  if v_id is null and v_nrm is not null then
    select count(*), (array_agg(a.id order by a.code))[1]
      into v_n, v_id
      from accounts a
     where a.section = 'pul' and a.is_active and a.parent_id is null
       and coalesce(a.currency, 'UZS') = 'UZS'
       and coalesce(a.kassa_turi, '') <> 'xarajat_guruh'
       and aros_nom_norm(a.name) = v_nrm;

    if v_n > 1 then
      return jsonb_build_object('ok', false,
        'sabab', 'nom "' || coalesce(p_nom, '') || '" bir nechta kassaga mos keldi');
    elsif v_n = 1 then
      v_usul := 'nom';
    else
      v_id := null;
    end if;
  end if;

  -- ---- 4) qattiq jadval (markaziy kassalar) ----
  -- ⚙️ SOZLAMA: yangi markaziy kassa qo'shilsa shu ro'yxatga qo'shing.
  --    Ammo eng to'g'ri yo'l — o'sha kassaning aros_title ustunini
  --    to'ldirish (u holda 2-qadam ishlaydi va bu jadval kerak bo'lmaydi).
  if v_id is null and v_nrm is not null then
    select a.id, a.code
      into v_id, v_code
      from accounts a
      join (values ('toshkentkassa',    '5011'),
                   ('kashkadaryokassa', '5012')) m(nrm, kod)
        on m.kod = a.code
     where m.nrm = v_nrm
       and a.section = 'pul' and a.is_active and a.parent_id is null
     limit 1;

    if v_id is not null then
      v_usul := 'jadval';
    end if;
  end if;

  if v_id is null then
    -- Topilmadi: nima bilan solishtirilganini ko'rsatamiz (diagnostika uchun)
    select string_agg(x, ', ' order by x)
      into v_nomlar
      from (select distinct a.code || ' ' || a.name as x
              from accounts a
             where a.section = 'pul' and a.is_active and a.parent_id is null
               and coalesce(a.currency, 'UZS') = 'UZS'
               and coalesce(a.kassa_turi, '') = 'markaziy'
             limit 10) s;

    return jsonb_build_object('ok', false,
      'sabab', 'kassa topilmadi (id=' || coalesce(v_ref, '-')
               || ', nom=' || coalesce(p_nom, '-') || ')',
      'markaziy_kassalar', v_nomlar);
  end if;

  select code, name into v_code, v_name from accounts where id = v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'code', v_code,
                            'name', v_name, 'usul', v_usul);
end $$;

revoke all on function aros_kassa_topish(text, text) from public, anon;
grant execute on function aros_kassa_topish(text, text) to authenticated, service_role;

comment on function aros_kassa_topish(text, text) is
  'Aros tomonini (cachier id yoki nom) Provodka kassasiga bog''laydi: '
  'filial_ref -> aros_title -> name -> qattiq jadval. Ikki moslikda ATAYLAB null.';



-- #####################################################################
--  2-BO'LIM — ASOSIY RPC
-- #####################################################################

create or replace function sync_transfer_balans(p_data jsonb,
                                               p_dry_run boolean default false,
                                               p_from timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_list        jsonb;
  v_el          jsonb;

  v_cutoff      timestamptz;
  v_cutoff_man  text;
  v_cut_info    jsonb;

  v_tr_id       text;
  v_status      text;
  v_txt         text;
  v_recv        timestamptz;
  v_sana        date;

  v_send_res    jsonb;
  v_recv_res    jsonb;
  v_send_id     uuid;
  v_recv_id     uuid;
  v_send_nom    text;
  v_recv_nom    text;
  v_recv_turi   text;

  v_maydon      text;
  v_lbl         text;
  v_amt         numeric;
  v_rate        numeric;
  v_baza_rate   numeric;
  v_tr_rate     numeric;
  v_kurs_manba  text;

  v_dt          uuid;
  v_kt          uuid;
  v_summa       numeric;
  v_fc          numeric;
  v_ext         text;
  v_entry       uuid;

  n_jami        int := 0;
  n_yozuv       int := 0;
  n_takror      int := 0;
  n_otkaz       int := 0;
  n_status      int := 0;
  n_eski        int := 0;
  v_ogoh        jsonb := '[]'::jsonb;
  v_tafsil      jsonb := '[]'::jsonb;
begin
  -- ---- 0. Qulflar ---------------------------------------------------
  -- IKKALASI ham olinadi va SHU TARTIBDA. Sabab: transfer yozilayotganda
  -- sync_filial_balans o'rtaga tushsa, u transferni ko'rmagan daftar
  -- ustidan delta hisoblab, o'sha pulni "tushum" deb yozib yuborardi.
  -- Delta sync faqat o'z lock'ini oladi -> deadlock bo'lishi mumkin emas.
  perform pg_advisory_xact_lock(hashtext('sync_filial_balans'));
  perform pg_advisory_xact_lock(hashtext('sync_transfer_balans'));

  -- ---- 1. Kirishni normallashtirish ---------------------------------
  if p_data is null then
    return jsonb_build_object('ok', false, 'error', 'p_data bo''sh');
  end if;

  if jsonb_typeof(p_data) = 'object' and p_data ? 'transferlar' then
    v_list := p_data -> 'transferlar';
  elsif jsonb_typeof(p_data) = 'object' and p_data ? 'transfers' then
    v_list := p_data -> 'transfers';
  elsif jsonb_typeof(p_data) = 'object' and p_data ? 'results' then
    v_list := p_data -> 'results';          -- Aros API sahifalangan javobi
  else
    v_list := p_data;
  end if;

  if jsonb_typeof(v_list) <> 'array' then
    return jsonb_build_object('ok', false,
      'error', 'JSON massiv kutilgan edi (yoki {transferlar:[...]}), keldi: '
               || jsonb_typeof(v_list));
  end if;

  -- ---- 2. CUTOFF ----------------------------------------------------
  -- Chegara = daftar Aros bilan OXIRGI marta tenglashtirilgan payt
  -- (oxirgi delta sync). Undan oldingi transferlar daftarga allaqachon
  -- singib ketgan — ularni yozish IKKI MARTA AYIRISH demak.
  -- Yagona manba: aros_transfer_cutoff() (0.5-bo'lim).
  v_cut_info   := aros_transfer_cutoff(p_from);
  v_cutoff     := nullif(v_cut_info ->> 'cutoff', '')::timestamptz;
  v_cutoff_man := v_cut_info ->> 'manba';

  if v_cutoff is null and not p_dry_run then
    return jsonb_build_object('ok', false,
      'error', 'CUTOFF topilmadi — hech narsa yozilmadi. Chegara "daftar Aros bilan '
               || 'oxirgi marta qachon tenglashtirilgan" degani; usiz eski transferni '
               || 'yozish pulni IKKI MARTA ayirib yuboradi. Delta sync (sync_filial_balans) '
               || 'hech qachon ishlamaganga o''xshaydi — avval uni ishlating, '
               || 'yoki p_from ni aniq bering.',
      'cutoff_info', v_cut_info,
      'maslahat', 'select sync_transfer_balans(''[...]''::jsonb, false, ''2026-07-31T12:00:00+05'')');
  end if;

  -- p_from berilgan, lekin chegaradan OLDIN edi -> e'tiborsiz qoldirildi.
  -- Jimgina o'tkazib yubormaymiz: qo'lda berilgan sana himoyani ochib
  -- yuborishga urinayotgan bo'lishi mumkin.
  if coalesce((v_cut_info ->> 'p_from_ishlatilmadi')::boolean, false) then
    v_ogoh := v_ogoh || jsonb_build_object(
      'p_from', p_from,
      'sabab', 'p_from chegaradan OLDIN — e''tiborsiz qoldirildi. Cutoff faqat '
               || 'qattiqlashtirilishi mumkin (kechroq sana). Ishlatilgan cutoff: '
               || coalesce(v_cutoff::text, '(yo''q)'));
  end if;

  -- ---- 3. Zaxira dollar kursi ---------------------------------------
  if to_regprocedure('public.conv_baza_kurs(text)') is not null then
    begin
      execute 'select conv_baza_kurs($1)' into v_baza_rate using 'USD';
    exception when others then
      v_baza_rate := null;
    end;
  end if;

  -- ---- 4. Har transfer ----------------------------------------------
  for v_el in select * from jsonb_array_elements(v_list)
  loop
    n_jami := n_jami + 1;

    -- 4.1 id (majburiy — takrorlanmaslik shunga tayanadi)
    v_tr_id := nullif(btrim(coalesce(v_el ->> 'id', v_el ->> 'transfer_id', '')), '');
    if v_tr_id is null then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', null, 'sabab', 'transfer id yo''q — ext_ref yasab bo''lmaydi');
      continue;
    end if;

    -- 4.2 status: faqat 'received' yoziladi
    v_status := lower(btrim(coalesce(nullif(v_el ->> 'status', ''), 'received')));
    if v_status <> 'received' then
      n_status := n_status + 1;
      continue;
    end if;

    -- 4.3 received_at (majburiy — cutoff shunga qarab ishlaydi)
    v_txt := nullif(btrim(coalesce(v_el ->> 'received_at',
                                   v_el ->> 'received_datetime', '')), '');
    v_recv := null;
    if v_txt is not null then
      -- Aros vaqtni zonasiz (naive, Toshkent vaqtida) saqlaydi -> +05 qo'shamiz.
      -- ⚠️ "Zona bormi" tekshiruvi ehtiyotkor yozilgan: sanadagi tire ('2026-07-30')
      --    zona deb o'qilib qolmasin. Shuning uchun zona faqat VAQT qismidan keyin
      --    tan olinadi, sana-only alohida ko'riladi.
      if v_txt ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_txt := v_txt || 'T00:00:00+05';
      elsif v_txt !~ '([Zz]|[+-][0-9]{2}:[0-9]{2}|[+-][0-9]{4}|:[0-9]{2}(\.[0-9]+)?[+-][0-9]{2})$' then
        v_txt := v_txt || '+05';
      end if;
      begin
        v_recv := v_txt::timestamptz;
      exception when others then
        v_recv := null;
      end;
    end if;

    if v_recv is null then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', v_tr_id,
        'sabab', 'received_at yo''q yoki o''qib bo''lmadi — cutoff tekshirib bo''lmaydi, '
                 || 'yozilmadi (received_at: ' || coalesce(v_el ->> 'received_at', '(yo''q)') || ')');
      continue;
    end if;

    -- 4.4 CUTOFF: daftarga allaqachon singib ketgan transferlar
    -- `<=` (kichik YOKI TENG): chegara ustidagi transfer ham yozilmaydi.
    -- Konservativ yo'nalish — shubhada yozmaslik.
    if v_cutoff is not null and v_recv <= v_cutoff then
      n_eski := n_eski + 1;
      continue;
    end if;

    -- 4.5 Tomonlarni bog'lash
    v_send_res := aros_kassa_topish(v_el ->> 'sender_id',
                                    coalesce(v_el ->> 'sender_title', v_el ->> 'sender'));
    if not (v_send_res ->> 'ok')::boolean then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', v_tr_id, 'tomon', 'sender',
        'sabab', v_send_res ->> 'sabab');
      continue;
    end if;

    v_recv_res := aros_kassa_topish(v_el ->> 'receiver_id',
                                    coalesce(v_el ->> 'receiver_title', v_el ->> 'receiver'));
    if not (v_recv_res ->> 'ok')::boolean then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', v_tr_id, 'tomon', 'receiver',
        'sabab', v_recv_res ->> 'sabab',
        'markaziy_kassalar', v_recv_res -> 'markaziy_kassalar');
      continue;
    end if;

    v_send_id  := (v_send_res ->> 'id')::uuid;
    v_recv_id  := (v_recv_res ->> 'id')::uuid;
    v_send_nom := v_send_res ->> 'name';
    v_recv_nom := v_recv_res ->> 'name';

    if v_send_id = v_recv_id then
      n_otkaz := n_otkaz + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'transfer', v_tr_id,
        'sabab', 'jo''natuvchi va qabul qiluvchi bir xil kassa (' || v_send_nom || ') — yozilmadi');
      continue;
    end if;

    -- Qabul qiluvchi markaziy emasmi — bloklamaymiz, faqat aytamiz
    select kassa_turi into v_recv_turi from accounts where id = v_recv_id;

    -- 4.6 Transferning o'z kursi (dollar uchun)
    v_tr_rate := null;
    if (v_el ? 'dollar_rate') and jsonb_typeof(v_el -> 'dollar_rate') <> 'null' then
      v_tr_rate := nullif(v_el ->> 'dollar_rate', '')::numeric;
    elsif (v_el ? 'currency_rate') and jsonb_typeof(v_el -> 'currency_rate') = 'object' then
      v_tr_rate := nullif(v_el -> 'currency_rate' ->> 'rate', '')::numeric;
    elsif (v_el ? 'currency_rate') and jsonb_typeof(v_el -> 'currency_rate') in ('number','string') then
      v_tr_rate := nullif(v_el ->> 'currency_rate', '')::numeric;
    elsif (v_el ? 'rate') and jsonb_typeof(v_el -> 'rate') in ('number','string') then
      v_tr_rate := nullif(v_el ->> 'rate', '')::numeric;
    end if;

    v_sana := least((v_recv at time zone 'Asia/Tashkent')::date,
                    (now() at time zone 'Asia/Tashkent')::date);

    -- ---- 4.7 HAR TUR ----
    foreach v_maydon in array array['cash','click','payme','dollar_usd']
    loop
      -- Summa (sinonim maydonlar bilan)
      v_amt := null;
      begin
        v_amt := nullif(btrim(coalesce(
                   case v_maydon
                     when 'cash'       then coalesce(v_el ->> 'cash',  v_el ->> 'seller_cash')
                     when 'click'      then coalesce(v_el ->> 'click', v_el ->> 'seller_click')
                     when 'payme'      then coalesce(v_el ->> 'payme', v_el ->> 'seller_payme')
                     when 'dollar_usd' then coalesce(v_el ->> 'dollar_usd',
                                                     v_el ->> 'seller_dollar',
                                                     v_el ->> 'dollar')
                   end, '')), '')::numeric;
      exception when others then
        v_amt := null;
      end;

      if v_amt is null or v_amt <= 0 then
        continue;                       -- bu turda pul o'tmagan
      end if;

      -- Takror? (is_deleted bo'lsa ham qayta yozmaymiz — admin o'chirganini tiriltirmasin)
      v_ext := 'aros_tr:' || v_tr_id || ':' || v_maydon;
      if exists (select 1 from entry where ext_ref = v_ext) then
        n_takror := n_takror + 1;
        continue;
      end if;

      -- Dt/Kt hisoblari
      v_dt := aros_tur_hisob(v_recv_id, v_maydon);
      v_kt := aros_tur_hisob(v_send_id, v_maydon);

      if v_dt is null or v_kt is null then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object(
          'transfer', v_tr_id, 'tur', v_maydon, 'summa', v_amt,
          'sabab', case
                     when v_dt is null and v_kt is null then
                       'ikkala kassada ham "' || v_maydon || '" turi uchun hisob yo''q'
                     when v_dt is null then
                       'qabul qiluvchi (' || v_recv_nom || ') da "' || v_maydon || '" hisobi yo''q'
                     else
                       'jo''natuvchi (' || v_send_nom || ') da "' || v_maydon || '" hisobi yo''q'
                   end || ' — PROVODKA_SYNC_FIX.sql / SEED tur child''ini ochmaganmi?');
        continue;
      end if;

      -- Summa va valyuta
      if v_maydon = 'dollar_usd' then
        v_rate       := coalesce(v_tr_rate, v_baza_rate);
        v_kurs_manba := case when v_tr_rate is not null then 'transfer'
                             when v_baza_rate is not null then 'provodka'
                             else null end;
        if v_rate is null or v_rate <= 0 then
          n_otkaz := n_otkaz + 1;
          v_ogoh := v_ogoh || jsonb_build_object(
            'transfer', v_tr_id, 'tur', v_maydon, 'usd', v_amt,
            'sabab', 'kurs yo''q: transferda ham, Provodka''da ham USD kursi topilmadi');
          continue;
        end if;
        v_fc    := v_amt;                       -- dollar miqdori
        v_summa := round(v_amt * v_rate, 2);    -- so'm ekvivalenti
      else
        v_rate       := null;
        v_kurs_manba := null;
        v_fc         := null;
        v_summa      := v_amt;
      end if;

      if v_summa = 0 then
        n_otkaz := n_otkaz + 1;
        v_ogoh := v_ogoh || jsonb_build_object(
          'transfer', v_tr_id, 'tur', v_maydon,
          'sabab', 'so''m summasi 0 ga yaxlitlandi — yozuv yozilmadi');
        continue;
      end if;

      v_lbl := case v_maydon when 'cash' then 'Naqd' when 'click' then 'Click'
                             when 'payme' then 'Payme' else 'USD' end;

      v_tafsil := v_tafsil || jsonb_build_object(
        'transfer', v_tr_id,
        'sana', v_sana,
        'tur', v_lbl,
        'jonatuvchi', v_send_nom,
        'qabul_qiluvchi', v_recv_nom,
        'summa_uzs', v_summa,
        'usd', v_fc,
        'kurs', v_rate,
        'kurs_manba', v_kurs_manba,
        'ext_ref', v_ext,
        'qabul_kassa_turi', v_recv_turi,
        'ogoh', case when coalesce(v_recv_turi, '') <> 'markaziy'
                     then 'qabul qiluvchi markaziy kassa emas (' || coalesce(v_recv_turi, '?') || ')'
                     else null end);

      if p_dry_run then
        n_yozuv := n_yozuv + 1;
        continue;
      end if;

      -- ---- YOZUV: bitta entry, ikki satr ----
      -- ext_ref UNIQUE: poyga holatida (ikki sync bir vaqtda) ikkinchisi
      -- unique_violation oladi -> takror deb sanaymiz, sync to'xtamaydi.
      begin
        insert into entry(entry_date, description, source, status,
                          created_by, fc_rate, ext_ref)
        values (v_sana,
                'Aros transfer #' || v_tr_id || ' · ' || coalesce(v_send_nom, '?')
                  || ' → ' || coalesce(v_recv_nom, '?') || ' · ' || v_lbl,
                'aros_auto', 'posted', 'aros_transfer',
                case when v_maydon = 'dollar_usd' then v_rate else null end,
                v_ext)
        returning id into v_entry;
      exception when unique_violation then
        v_entry  := null;
        n_takror := n_takror + 1;
      end;

      if v_entry is null then
        continue;
      end if;

      -- Dt: qabul qiluvchi (markaziy) — pul keldi
      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, v_dt, v_summa, 0, v_fc);
      -- Kt: jo'natuvchi (filial) — pul chiqdi
      -- ⚠️ Dollarda IKKALA satr ham valyuta hisobi, shuning uchun fc_amount
      --    ikkalasiga ham yoziladi (musbat). Ishora Dt/Kt dan kelib chiqadi:
      --    v_hisob_bal -> debit>0 ? +fc : −fc.
      insert into entry_line(entry_id, account_id, debit, credit, fc_amount)
      values (v_entry, v_kt, 0, v_summa, v_fc);

      n_yozuv := n_yozuv + 1;
    end loop;
  end loop;

  -- Muhr: transfer sync qachon ishlagani (cutoff'ga TA'SIR QILMAYDI — ma'lumot uchun)
  if not p_dry_run and to_regprocedure('public.aros_sync_stamp(text, timestamptz)') is not null then
    begin
      perform aros_sync_stamp('transfer', null);
    exception when others then
      null;   -- muhr qo'yilmasa ham sync yiqilmasin
    end;
  end if;

  return jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'sana', to_char(now() at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI:SS'),
    'cutoff', v_cutoff,
    'cutoff_manba', coalesce(v_cutoff_man, '(topilmadi — dry_run)'),
    'cutoff_info', v_cut_info,        -- to'liq diagnostika: muhr, oxirgi/birinchi delta, p_from
    'transferlar', n_jami,
    'yozuvlar', n_yozuv,              -- yozilgan entry soni (transfer × tur)
    'takror', n_takror,               -- allaqachon yozilgan (ext_ref bor)
    'received_emas', n_status,        -- sent/canceled
    'cutoffdan_eski', n_eski,         -- daftarga allaqachon singigan (oxirgi delta syncdan oldin)
    'otkazildi', n_otkaz,
    'ogohlantirishlar', v_ogoh,
    'tafsilot', v_tafsil,
    'eslatma', 'Delta sync SHUNDAN KEYIN ishlashi shart (balanslarni qayta o''qib).');
end $$;

revoke all on function sync_transfer_balans(jsonb, boolean, timestamptz)
  from public, anon, authenticated;
grant execute on function sync_transfer_balans(jsonb, boolean, timestamptz) to service_role;

comment on function sync_transfer_balans(jsonb, boolean, timestamptz) is
  '2-bosqich: Aros cachier-transfer sync. received transferlarni tur bo''yicha '
  'Dt markaziy.tur / Kt filial.tur qilib yozadi. ext_ref = aros_tr:<id>:<tur> (unique). '
  'Cutoff = OXIRGI delta sync payti (aros_transfer_cutoff()): undan oldingi transferlar '
  'daftarga allaqachon singigan, yozilmaydi. p_from faqat qattiqlashtira oladi. '
  'HAR SIKLDA delta sync''DAN OLDIN chaqirilishi shart. service_role only.';



-- #####################################################################
--  3-BO'LIM — sync_aros_full(): tartibni xato qilib bo'lmasin
-- #####################################################################
-- Ixtiyoriy, lekin TAVSIYA ETILADI. n8n ikki RPC'ni ikki qadamda chaqirsa,
-- kimdir kelajakda tartibni almashtirib qo'yishi mumkin (avval delta, keyin
-- transfer) — o'shanda transferlar bir sikl davomida "tushum" bo'lib yoziladi.
-- Bu wrapper tartibni KODGA qotiradi va ikkalasini BITTA tranzaksiyada bajaradi
-- (biri yiqilsa — ikkalasi ham orqaga qaytadi).
--
-- ⚠️ n8n uchun qoida o'zgarmaydi: transferlar ro'yxatini AVVAL o'qing,
--    balanslarni KEYIN (shunda balans snapshot'i transferni o'z ichiga oladi).
--
-- ⚠️ Transfer qismi ok:false qaytarsa — delta UMUMAN ishlamaydi. Ataylab:
--    transfersiz delta o'sha pulni tushum deb yozib yuborardi.
--
-- ⚠️ p_balans_at — Aros balansi QACHON O'QILGAN payti (ixtiyoriy, TAVSIYA).
--    Muhr shu bilan qo'yiladi; berilmasa now() ishlatiladi. Farqi 0.5.2 da
--    tushuntirilgan: o'qish bilan yozish orasidagi oynada kelgan transfer
--    keyingi siklda to'silib qolmasin.
create or replace function sync_aros_full(p_transferlar jsonb,
                                          p_balanslar jsonb,
                                          p_dry_run boolean default false,
                                          p_from timestamptz default null,
                                          p_balans_at timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tr   jsonb;
  v_bal  jsonb;
  v_muhr timestamptz;
begin
  -- 1) AVVAL transfer
  v_tr := sync_transfer_balans(p_transferlar, p_dry_run, p_from);

  if not coalesce((v_tr ->> 'ok')::boolean, false) then
    return jsonb_build_object(
      'ok', false,
      'bosqich', 'transfer',
      'error', 'Transfer sync yiqildi — delta sync ISHLAMADI (ataylab: '
               || 'transfersiz delta o''sha pulni tushum deb yozib yuborardi)',
      'transfer', v_tr);
  end if;

  -- 2) KEYIN delta
  v_bal := sync_filial_balans(p_balanslar, p_dry_run);

  -- 3) Delta tugadi -> daftar Aros bilan tenglashdi. MUHRNI SHU YERDA qo'yamiz:
  --    keyingi siklda cutoff aynan shu payt bo'ladi va shu paytgacha bo'lgan
  --    transferlar (delta ularni allaqachon singdirgan) yozilmaydi.
  if not p_dry_run
     and coalesce((v_bal ->> 'ok')::boolean, false)
     and to_regprocedure('public.aros_sync_stamp(text, timestamptz)') is not null then
    begin
      v_muhr := aros_sync_stamp('balans', p_balans_at);
    exception when others then
      v_muhr := null;   -- muhr qo'yilmasa zaxira (oxirgi aros_sync yozuvi) ishlaydi
    end;
  end if;

  return jsonb_build_object(
    'ok', coalesce((v_bal ->> 'ok')::boolean, false),
    'dry_run', p_dry_run,
    'muhr', v_muhr,                    -- keyingi siklning cutoff'i shu bo'ladi
    'transfer', v_tr,
    'balans', v_bal);
end $$;

revoke all on function sync_aros_full(jsonb, jsonb, boolean, timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function sync_aros_full(jsonb, jsonb, boolean, timestamptz, timestamptz) to service_role;

comment on function sync_aros_full(jsonb, jsonb, boolean, timestamptz, timestamptz) is
  'Aros sync bitta chaqiruvda, TO''G''RI TARTIBDA: avval sync_transfer_balans, '
  'keyin sync_filial_balans, keyin cutoff muhri. Bitta tranzaksiya. '
  'Transfer yiqilsa delta ishlamaydi. p_balans_at = Aros balansi o''qilgan payt.';



-- #####################################################################
--  4-BO'LIM — TAYYORLIK TEKSHIRUVI (yozishdan OLDIN o'qing)
-- #####################################################################

-- 4.1 ⬅️ ASOSIY: markaziy kassalarda tur child'lari bormi?
--     Har markaziy kassada naqd/click/payme (+ USD) bo'lishi kerak,
--     aks holda transferning Dt tomoni topilmaydi.
select k.code, k.name, k.kassa_turi, k.filial_ref, k.aros_title,
       string_agg(coalesce(c.pul_turi, c.currency), ', ' order by coalesce(c.pul_turi, c.currency)) as turlar,
       count(c.id) as child_soni
  from accounts k
  left join accounts c on c.parent_id = k.id and c.is_active and c.section = 'pul'
                      and (c.pul_turi in ('naqd','click','payme') or c.currency = 'USD')
 where k.section = 'pul' and k.is_active and k.parent_id is null
   and coalesce(k.kassa_turi, '') = 'markaziy'
 group by k.code, k.name, k.kassa_turi, k.filial_ref, k.aros_title
 order by k.code;
-- child_soni < 4 bo'lsa: PROVODKA_SYNC_FIX.sql 2-bandini RUN qiling.

-- 4.2 Markaziy kassa Aros nomi bilan bog'langanmi (aros_title)
--     Bo'lmasa aros_kassa_topish 4-qadamdagi qattiq jadvalga tayanadi
--     ('Toshkent Kassa'->5011, 'Qashqadaryo Kassa'->5012).
--     Eng to'g'ri yo'l — aros_title ni to'ldirish:
--       update accounts set aros_title = 'Toshkent Kassa' where code = '5011';
select code, name, aros_title, aros_nom_norm(aros_title) as normal_shakl
  from accounts
 where section = 'pul' and is_active and parent_id is null
   and coalesce(kassa_turi, '') = 'markaziy'
 order by code;

-- 4.3 Nom bog'lanishini sinab ko'rish (yozmaydi, faqat topadi)
select 'Toshkent Kassa'    as aros_nom, aros_kassa_topish(null, 'Toshkent Kassa')    as natija
union all
select 'Qashqadaryo Kassa',                aros_kassa_topish(null, 'Qashqadaryo Kassa')
union all
select 'Karshi Kassa',                     aros_kassa_topish(null, 'Karshi Kassa');

-- 4.4 ⬅️⬅️ ENG MUHIM: CUTOFF qayerda turibdi
--     Chegara = daftar Aros bilan OXIRGI marta tenglashtirilgan payt.
--     RPC ham AYNAN shu funksiyadan oladi — bu yerda ko'rgan qiymatingiz
--     yozuv paytida ishlaydigan qiymat (ikki xil mantiq yo'q).
select jsonb_pretty(aros_transfer_cutoff());
--
-- Javobni QANDAY o'qish kerak:
--   "cutoff"                    <- SHUNDAN OLDINGI transfer YOZILMAYDI
--   "manba"                     <- muhrmi yoki oxirgi delta yozuvimi
--   "oxirgi_delta_yozuvi"       <- delta sync oxirgi marta qachon yozgan
--   "birinchi_delta_yozuvi"     <- boshlang'ich qoldiq payti (FAQAT ma'lumot!
--                                  cutoff SIFATIDA ISHLATILMAYDI — eski xato shu edi)
--   "sync_state_transfers_from" <- eski mexanizm qiymati (FAQAT ma'lumot,
--                                  ISHLATILMAYDI; oylar oldingi bo'lishi mumkin)
--
-- ⚠️ "cutoff" null chiqsa: delta sync hech qachon ishlamagan. RPC hech narsa
--    yozmaydi (ok:false). Avval sync_filial_balans ni bir marta ishlating.

-- 4.4b Delta sync qachon-qachon ishlagan (cutoff shu ro'yxatning ENG OXIRGISI)
select created_at, count(*) over () as jami_delta_yozuvlari
  from entry
 where source = 'aros_auto' and created_by = 'aros_sync'
 order by created_at desc
 limit 10;

-- 4.4c ⬅️ XAVF TEKSHIRUVI: yubormoqchi bo'lgan transferlaringizdan
--      qaysi biri to'siladi, qaysi biri yoziladi.
--      ⚙️ VALUES ichiga dry_run ko'rsatgan (id, received_at) larni qo'ying.
with cut as (select nullif(aros_transfer_cutoff() ->> 'cutoff', '')::timestamptz as c),
     tr(id, received_at) as (values
       ('1044', '2026-07-31T00:00:00+05'::timestamptz),
       ('1046', '2026-07-30T00:00:00+05'::timestamptz)
     )
select tr.id,
       tr.received_at,
       cut.c as cutoff,
       case when cut.c is null              then '⚠️ cutoff yo''q — RPC yozmaydi'
            when tr.received_at <= cut.c    then '🛡️ TO''SILADI (daftarga allaqachon kirgan)'
            else                                 '✍️ YOZILADI (yangi transfer)'
       end as natija
  from tr, cut
 order by tr.received_at;
-- 1044/1046 kabi eski transferlar '🛡️ TO'SILADI' bo'lishi SHART.
-- '✍️ YOZILADI' chiqsa — YOQMANG, avval menga ayting.

-- 4.5 Dublikat filial_ref (bo'sh chiqishi kerak — bo'lmasa bog'lash noaniq)
select btrim(filial_ref::text) as ref, count(*) as nechta,
       string_agg(code || ' ' || name, ' | ') as kassalar
  from accounts
 where section = 'pul' and is_active and parent_id is null and filial_ref is not null
 group by btrim(filial_ref::text)
having count(*) > 1;

-- 4.6 Bir xil normallashgan NOMLI kassalar (nom bo'yicha bog'lash noaniq bo'ladi)
select aros_nom_norm(name) as normal_nom, count(*) as nechta,
       string_agg(code || ' ' || name, ' | ') as kassalar
  from accounts
 where section = 'pul' and is_active and parent_id is null
   and coalesce(currency, 'UZS') = 'UZS'
   and coalesce(kassa_turi, '') <> 'xarajat_guruh'
 group by aros_nom_norm(name)
having count(*) > 1;



-- #####################################################################
--  5-BO'LIM — SINOV (dry_run bilan)
-- #####################################################################

-- 5.1 QURUQ YUGURISH — hech narsa yozmaydi.
--     ⚙️ id/nom/summalarni o'zingizdagi haqiqiy transferga almashtiring.
-- select jsonb_pretty(sync_transfer_balans('[
--   {"id": 12345,
--    "status": "received",
--    "sender_id": 3,
--    "sender_title": "Yunusobod Universam",
--    "receiver_title": "Toshkent Kassa",
--    "received_at": "2026-07-31T12:00:00",
--    "cash": 5000000, "click": 1500000, "payme": 0, "dollar_usd": 0}
-- ]'::jsonb, true));
--
-- Javobda tekshiring:
--   • "cutoff" va "cutoff_manba" — 4.4 dagi qiymat bilan bir xilmi
--   • "cutoff_info"    — to'liq diagnostika (muhr, oxirgi/birinchi delta, p_from)
--   • "tafsilot"       — jonatuvchi/qabul_qiluvchi TO'G'RI kassalarmi
--   • "ogohlantirishlar" — bo'sh bo'lishi kerak
--   • "cutoffdan_eski" — ⬅️ ENG MUHIM SANOQ:
--        ESKI transfer (1044, 1046 kabi) bu sanoqqa TUSHISHI SHART.
--        Ular "yozuvlar"ga tushsa — TO'XTANG, sync'ni YOQMANG.
--        Faqat cutoff'dan KEYIN qabul qilingan transfer yozilishi kerak.
--
-- ⚠️ p_from (3-argument) — himoyani OCHA OLMAYDI, faqat qattiqlashtiradi.
--    Cutoff'dan oldingi sana berilsa e'tiborsiz qoldiriladi va javobning
--    "ogohlantirishlar" qismida aytiladi. Ataylab shunday: qo'lda berilgan
--    eski sana eski transferlarni ikki marta yozib yuborardi.

-- 5.2 HAQIQIY yozuv (dry_run'siz) — avval BITTA transfer bilan sinang:
-- select jsonb_pretty(sync_transfer_balans('[ ... bitta transfer ... ]'::jsonb));

-- 5.3 IDEMPOTENTLIK: aynan o'sha JSON bilan qayta chaqiring.
--     "yozuvlar": 0, "takror": N bo'lishi SHART.
-- select sync_transfer_balans('[ ... o''sha JSON ... ]'::jsonb) -> 'takror';

-- 5.4 To'liq sikl (wrapper) — tartib kafolatlangan:
-- select jsonb_pretty(sync_aros_full(
--   '[ ...transferlar... ]'::jsonb,
--   '[ ...balanslar... ]'::jsonb,
--   true,                         -- dry_run
--   null,                         -- p_from (kerak emas — cutoff o'zi topiladi)
--   '2026-08-03T10:00:00+05'));   -- p_balans_at: Aros balansi O'QILGAN payt
--
-- n8n uchun tartib (transfer sync workflow'i):
--   1) HTTP: cachier-transfers ro'yxati    -> transferlar
--   2) Set:  o'qish paytini saqlash        -> {{ $now }}   (p_balans_at)
--   3) HTTP: cachiers balanslari           -> balanslar
--   4) HTTP: POST /rpc/sync_aros_full  {p_transferlar, p_balanslar,
--            p_dry_run:false, p_balans_at}
--   Muhrni wrapper O'ZI qo'yadi — alohida stamp node KERAK EMAS.
--   (Ikki RPC alohida chaqirilsa: transfer -> balans -> aros_sync_stamp)



-- #####################################################################
--  6-BO'LIM — YOZUVDAN KEYINGI TEKSHIRUV
-- #####################################################################

-- 6.1 Transfer sync yozgan yozuvlar
select e.entry_date, e.ext_ref, e.description, e.fc_rate,
       a.code, a.name, l.debit, l.credit, l.fc_amount
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a   on a.id = l.account_id
 where e.created_by = 'aros_transfer'
   and e.is_deleted = false
 order by e.created_at desc, l.debit desc
 limit 50;

-- 6.2 Har transfer BIR MARTA yozilganmi (bo'sh chiqishi kerak)
select ext_ref, count(*) as nechta
  from entry
 where ext_ref like 'aros_tr:%'
 group by ext_ref
having count(*) > 1;

-- 6.3 ⬅️ ENG MUHIM: balans tenglikda qoldimi
select sum(case when bolim = 'AKTIV'   then amount else 0 end) as aktiv,
       sum(case when bolim = 'PASSIV'  then amount else 0 end) as passiv,
       sum(case when bolim = 'KAPITAL' then amount else 0 end) as kapital,
       sum(case when bolim = 'AKTIV'   then amount else 0 end)
     - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end) as farq
  from balans(current_date);
-- farq = 0 bo'lishi SHART.

-- 6.4 Transfer TUSHUM'ga tegmaganini tasdiqlash:
--     transfer yozuvlarida 9010 (savdo tushumi) UMUMAN bo'lmasligi kerak.
--     Bo'sh chiqishi SHART.
select e.ext_ref, a.code, a.name, l.debit, l.credit
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a   on a.id = l.account_id
 where e.created_by = 'aros_transfer'
   and a.code = '9010';

-- 6.5 Delta sync'dan keyin: kassa qoldiqlari Aros bilan mos keldimi
select code, name, kassa_turi, naqd, click, payme, usd, jami
  from v_kassa_card
 where kassa_turi in ('markaziy','filial')
 order by kassa_turi, code;

-- 6.6 "sent -> received oynasi" izi: 9010 ga qarshi manfiy yozuvlar.
--     Bir necha soat ichida teskarisi paydo bo'lib nolga chiqishi kerak.
--     Har kuni ko'p chiqsa — 3-bosqichda transit hisobi kerak bo'ladi.
select e.entry_date, e.description, l.debit as dt_9010, e.created_by
  from entry e
  join entry_line l on l.entry_id = e.id
  join accounts a   on a.id = l.account_id
 where a.code = '9010' and l.debit > 0            -- Dt 9010 = tushum kamaydi
   and e.source = 'aros_auto' and e.is_deleted = false
   and e.entry_date >= current_date - 7
 order by e.entry_date desc, l.debit desc
 limit 30;



-- #####################################################################
--  7-BO'LIM — ORQAGA QAYTARISH (faqat kerak bo'lsa — IZOHDA turibdi)
-- #####################################################################
-- ⚠️ Avval n8n'dagi transfer workflow'ini O'CHIRING, aks holda yozuvlar
--    keyingi siklda qayta paydo bo'ladi.
-- ⚠️ Transfer yozuvlari o'chirilsa daftar Aros'dan chetga chiqadi —
--    keyingi delta sync farqni "tushum/chiqim" qilib yozadi. Ya'ni tozalash
--    o'zi yetmaydi, cutoff'ni ham qayta o'ylash kerak.
--
-- do $rb$
-- declare v_ids uuid[]; v_soni int;
-- begin
--   select array_agg(id) into v_ids
--     from entry where ext_ref like 'aros_tr:%';
--   v_soni := coalesce(array_length(v_ids, 1), 0);
--   if v_soni = 0 then raise notice 'Transfer yozuvi yo''q'; return; end if;
--   delete from entry_line where entry_id = any(v_ids);
--   delete from entry      where id       = any(v_ids);
--   raise notice 'O''CHIRILDI: % ta transfer yozuvi', v_soni;
-- end $rb$;
