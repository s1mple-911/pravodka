-- =====================================================================
--  PROVODKA_AROS_TITLE.sql — accounts.aros_title ni Aros nomlari bilan to'ldirish
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  RPC:  sync_aros_title(p_data jsonb, p_dry_run boolean default false) -> jsonb
--
--  NEGA KERAK:
--    cachier-transfers da sender uchun FAQAT NOM keladi, id kelmaydi.
--    Aros nomi Provodka nomiga mos emas:
--        Aros "Chilonzor"  ≠  Provodka "Chilanzar kassa"
--    Shuning uchun nom bo'yicha bog'lash ishlamaydi.
--
--    Yechim: har kassaning `aros_title` ustuniga Aros'dagi AYNAN o'sha nom
--    yoziladi. Bog'lovchi kalit — `filial_ref` (Aros cachier id), u bizda
--    allaqachon bor va ishonchli:
--
--        accounts.filial_ref  ==  Aros cachiers[].id
--        accounts.aros_title  <-  Aros cachiers[].title_uz
--
--    Shundan keyin `aros_kassa_topish()` 2-qadami (aros_title, nom_norm bilan)
--    sender_title ni to'g'ri kassaga bog'laydi.
--
--  NEGA SQL, n8n EMAS:
--    Ma'lumot baribir Aros'dan keladi, ya'ni n8n bitta HTTP so'rov qilishi
--    shart. Lekin taqqoslash/xavfsizlik mantig'i (dublikat nom, to'qnashuv,
--    o'zgarish tarixi) SQL'da bo'lgani ma'qul: n8n faqat javobni uzatadi,
--    qaror baza tomonda. n8n tomonda ish: 2 ta node.
--
--       [HTTP GET billing/cachiers/?page_size=500]
--                     |
--       [Supabase RPC sync_aros_title]  body: {"cachiers": {{ $json }} }
--
--  IDEMPOTENT: qayta RUN xavfsiz — o'zgarmagan nom qayta yozilmaydi.
--
--  QANCHALIK TEZ-TEZ:
--    Alohida workflow SHART EMAS — transfer sync workflow'ining boshiga
--    qo'ysa ham bo'ladi (o'zgarmasa hech narsa yozmaydi).
--    Lekin har 30 daqiqada KERAK EMAS: kassa nomlari deyarli o'zgarmaydi.
--    Yetarli: KUNIGA BIR MARTA, yoki yangi filial qo'shilganda qo'lda.
--    Sabab: bog'lash kaliti `filial_ref` (id), nom faqat sender uchun kerak;
--    yangi filial qo'shilmasa yangilanadigan narsa yo'q.
--
--  XAVFSIZLIK:
--    • Faqat `filial_ref` mos kelgan kassaga tegadi (nom bo'yicha taxmin YO'Q).
--    • To'qnashuv (ikki kassaga bir xil nom) — YOZILMAYDI, ogohlantiriladi.
--      Sabab: bir xil nomli ikki kassa `aros_kassa_topish()` ni "noaniq"
--      holatga tushiradi va transfer IKKALASIGA ham yozilmay qoladi.
--    • Bu funksiya PUL YOZMAYDI — faqat `accounts.aros_title` ustunini
--      yangilaydi. Xato bo'lsa ta'siri: transfer bog'lanmaydi (yozilmaydi),
--      noto'g'ri kassaga yozilmaydi.
-- =====================================================================


-- ---------------------------------------------------------------------
--  KUTILADIGAN JSON
-- ---------------------------------------------------------------------
--  Aros javobini qanday bo'lsa shundayligicha uzatsa bo'ladi:
--    { "results": [ {...}, {...} ] }        <- billing/cachiers/ javobi
--  yoki
--    { "cachiers": [ ... ] }   yoki   [ ... ]
--
--  Har element:
--    { "id": 3, "title_uz": "Chilonzor", ... }
--
--  Nom maydoni sinonimlari (birinchi bo'shmasi olinadi):
--       title_uz | title | name | title_ru | title_en
--  Id maydoni sinonimlari:
--       id | cachier_id | pk
-- ---------------------------------------------------------------------


create or replace function sync_aros_title(p_data jsonb, p_dry_run boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_list      jsonb;
  v_el        jsonb;
  v_ref       text;
  v_title     text;
  v_nrm       text;

  v_id        uuid;
  v_code      text;
  v_name      text;
  v_eski      text;
  v_n         int;
  v_band      text;

  n_jami      int := 0;
  n_yangi     int := 0;   -- bo'sh edi, to'ldirildi
  n_ozgardi   int := 0;   -- boshqa nom edi, yangilandi
  n_bir_xil   int := 0;   -- allaqachon to'g'ri
  n_topilmadi int := 0;   -- bu cachier id bilan kassa yo'q
  n_toqnash   int := 0;   -- nom boshqa kassada band
  v_ogoh      jsonb := '[]'::jsonb;
  v_tafsil    jsonb := '[]'::jsonb;
  v_qolgan    text;
begin
  perform pg_advisory_xact_lock(hashtext('sync_aros_title'));

  -- ---- 1. Kirish ----------------------------------------------------
  if p_data is null then
    return jsonb_build_object('ok', false, 'error', 'p_data bo''sh');
  end if;

  if jsonb_typeof(p_data) = 'object' and p_data ? 'results' then
    v_list := p_data -> 'results';
  elsif jsonb_typeof(p_data) = 'object' and p_data ? 'cachiers' then
    v_list := p_data -> 'cachiers';
  elsif jsonb_typeof(p_data) = 'object' and p_data ? 'kassalar' then
    v_list := p_data -> 'kassalar';
  else
    v_list := p_data;
  end if;

  if jsonb_typeof(v_list) <> 'array' then
    return jsonb_build_object('ok', false,
      'error', 'JSON massiv kutilgan edi (yoki {results:[...]}), keldi: ' || jsonb_typeof(v_list));
  end if;

  -- ---- 2. Har cachier -----------------------------------------------
  for v_el in select * from jsonb_array_elements(v_list)
  loop
    n_jami := n_jami + 1;

    v_ref := nullif(btrim(coalesce(v_el ->> 'id',
                                   v_el ->> 'cachier_id',
                                   v_el ->> 'pk', '')), '');
    v_title := nullif(btrim(coalesce(v_el ->> 'title_uz',
                                     v_el ->> 'title',
                                     v_el ->> 'name',
                                     v_el ->> 'title_ru',
                                     v_el ->> 'title_en', '')), '');

    if v_ref is null or v_title is null then
      v_ogoh := v_ogoh || jsonb_build_object(
        'cachier', v_ref, 'nom', v_title,
        'sabab', 'id yoki nom bo''sh — o''tkazildi');
      continue;
    end if;

    -- ---- Kassani filial_ref bo'yicha topamiz (nom bo'yicha TAXMIN yo'q) ----
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

    if v_n = 0 then
      n_topilmadi := n_topilmadi + 1;
      continue;                       -- Aros'da bor, bizda yo'q — normal holat
    elsif v_n > 1 then
      n_toqnash := n_toqnash + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'cachier', v_ref, 'nom', v_title,
        'sabab', 'filial_ref=' || v_ref || ' bir nechta kassada — avval dublikatni hal qiling');
      continue;
    end if;

    select code, name, aros_title into v_code, v_name, v_eski
      from accounts where id = v_id;

    -- Allaqachon aynan shu nom bo'lsa — tegmaymiz
    if v_eski is not distinct from v_title then
      n_bir_xil := n_bir_xil + 1;
      continue;
    end if;

    -- ---- TO'QNASHUV: shu nom BOSHQA kassada bandmi ----
    -- Bir xil (normallashgan) nomli ikki kassa bo'lsa, aros_kassa_topish
    -- "noaniq" deb null qaytaradi va transfer IKKALASIGA ham yozilmaydi.
    -- Shuning uchun yozmaymiz, faqat aytamiz.
    v_nrm := aros_nom_norm(v_title);
    select string_agg(a.code || ' ' || a.name, ' | ')
      into v_band
      from accounts a
     where a.section = 'pul' and a.is_active and a.parent_id is null
       and a.id <> v_id
       and aros_nom_norm(a.aros_title) = v_nrm;

    if v_band is not null then
      n_toqnash := n_toqnash + 1;
      v_ogoh := v_ogoh || jsonb_build_object(
        'cachier', v_ref, 'nom', v_title, 'kassa', v_code || ' ' || v_name,
        'sabab', 'bu nom allaqachon boshqa kassada: ' || v_band
                 || ' — YOZILMADI (aks holda ikkovi ham noaniq bo''lib qolardi)');
      continue;
    end if;

    v_tafsil := v_tafsil || jsonb_build_object(
      'cachier', v_ref,
      'kassa', v_code || ' ' || v_name,
      'eski', v_eski,
      'yangi', v_title,
      'amal', case when v_eski is null then 'to''ldirildi' else 'yangilandi' end);

    if v_eski is null then
      n_yangi := n_yangi + 1;
    else
      n_ozgardi := n_ozgardi + 1;
    end if;

    if not p_dry_run then
      update accounts set aros_title = v_title where id = v_id;
    end if;
  end loop;

  -- ---- 3. Hali ham aros_title'siz kassalar (qo'lda hal qilinadi) -----
  select string_agg(x, ' | ' order by x)
    into v_qolgan
    from (select a.code || ' ' || a.name
                 || case when a.filial_ref is null then ' (filial_ref yo''q)' else '' end as x
            from accounts a
           where a.section = 'pul' and a.is_active and a.parent_id is null
             and coalesce(a.currency, 'UZS') = 'UZS'
             and coalesce(a.kassa_turi, '') <> 'xarajat_guruh'
             and nullif(btrim(coalesce(a.aros_title, '')), '') is null
           limit 20) s;

  return jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'kelgan', n_jami,
    'toldirildi', n_yangi,
    'yangilandi', n_ozgardi,
    'ozgarmadi', n_bir_xil,
    'bizda_yoq', n_topilmadi,
    'toqnashuv', n_toqnash,
    'aros_titlesiz_qolgan', v_qolgan,
    'ogohlantirishlar', v_ogoh,
    'tafsilot', v_tafsil);
end $$;

revoke all on function sync_aros_title(jsonb, boolean) from public, anon, authenticated;
grant execute on function sync_aros_title(jsonb, boolean) to service_role;

comment on function sync_aros_title(jsonb, boolean) is
  'Aros billing/cachiers/ javobidan accounts.aros_title ni to''ldiradi. '
  'Kalit: filial_ref = cachiers[].id, qiymat: title_uz. Nom bo''yicha taxmin QILMAYDI. '
  'Bir xil nom ikki kassada bo''lsa yozmaydi (noaniqlik oldini olish). service_role only.';


-- ---------------------------------------------------------------------
--  MARKAZIY KASSALAR — filial_ref bo'lmasa qo'lda (faqat BO'SHINI to'ldiradi)
-- ---------------------------------------------------------------------
-- Markaziy kassalar Aros cachiers ro'yxatida bo'lsa va filial_ref'i to'ldirilgan
-- bo'lsa — yuqoridagi RPC ularni ham qamrab oladi, bu blok hech narsa qilmaydi.
-- Aks holda transfer RECEIVER tomoni nom bo'yicha bog'lanadi, shuning uchun
-- aros_title kerak.
--
-- ⚙️ Aros'dagi AYNAN nom bilan to'g'rilang (tekshiring: transfer javobidagi
--    receiver_title nima deb kelyapti).
-- ⚠️ Mavjud qiymat HECH QACHON ustiga yozilmaydi.
do $mar$
declare
  r        record;
  n_toldi  int := 0;
  v_band   text;
begin
  for r in
    select * from (values ('5011', 'Toshkent Kassa'),
                          ('5012', 'Qashqadaryo Kassa')) m(kod, nom)
  loop
    -- Faqat bo'sh bo'lsa
    if not exists (select 1 from accounts
                    where code = r.kod and is_active and parent_id is null
                      and nullif(btrim(coalesce(aros_title, '')), '') is null) then
      continue;
    end if;

    -- Bu nom boshqa kassada bandmi
    select string_agg(a.code || ' ' || a.name, ' | ')
      into v_band
      from accounts a
     where a.section = 'pul' and a.is_active and a.parent_id is null
       and a.code <> r.kod
       and aros_nom_norm(a.aros_title) = aros_nom_norm(r.nom);

    if v_band is not null then
      raise notice 'O''TKAZILDI: "%" nomi allaqachon band (%) — % ga yozilmadi',
        r.nom, v_band, r.kod;
      continue;
    end if;

    update accounts set aros_title = r.nom
     where code = r.kod and is_active and parent_id is null
       and nullif(btrim(coalesce(aros_title, '')), '') is null;

    if found then
      n_toldi := n_toldi + 1;
      raise notice 'TO''LDIRILDI: % -> aros_title = "%"', r.kod, r.nom;
    end if;
  end loop;

  raise notice '--- Markaziy kassalar: % ta to''ldirildi', n_toldi;
end
$mar$;


-- ---------------------------------------------------------------------
--  TEKSHIRUV
-- ---------------------------------------------------------------------

-- T.1 ⬅️ ASOSIY: qaysi kassada aros_title bor/yo'q
select code, name, kassa_turi, filial_ref, aros_title,
       aros_nom_norm(aros_title) as normal_shakl,
       case when nullif(btrim(coalesce(aros_title, '')), '') is null
            then '❌ YO''Q — transfer nom bo''yicha bog''lanmaydi'
            else '✅' end as holat
  from accounts
 where section = 'pul' and is_active and parent_id is null
   and coalesce(currency, 'UZS') = 'UZS'
   and coalesce(kassa_turi, '') <> 'xarajat_guruh'
 order by kassa_turi, code;

-- T.2 Bir xil normallashgan aros_title (BO'SH chiqishi SHART).
--     Bo'sh bo'lmasa: o'sha nomdagi transferlar hech qaysi kassaga
--     bog'lanmaydi (aros_kassa_topish "noaniq" deb null qaytaradi).
select aros_nom_norm(aros_title) as normal_nom, count(*) as nechta,
       string_agg(code || ' ' || name, ' | ') as kassalar
  from accounts
 where section = 'pul' and is_active and parent_id is null
   and nullif(btrim(coalesce(aros_title, '')), '') is not null
 group by aros_nom_norm(aros_title)
having count(*) > 1;

-- T.3 Dry-run bilan sinash (hech narsa yozmaydi):
-- select jsonb_pretty(sync_aros_title('{"results":[
--   {"id": 3,  "title_uz": "Chilonzor"},
--   {"id": 19, "title_uz": "Yunusobod Universam"}
-- ]}'::jsonb, true));

-- T.4 Bog'lanishni sinash — Aros nomi to'g'ri kassani topyaptimi:
-- select aros_kassa_topish(null, 'Chilonzor');
-- Kutilgan: {"ok": true, "code": "52xx", "usul": "aros_title"}

-- T.5 Transfer sender'lari bog'lanadimi — Aros'dan kelgan nomlar ro'yxatini
--     shu yerga qo'ying va hammasi ok:true ekanini tekshiring:
-- select nom, aros_kassa_topish(null, nom) as natija
--   from unnest(array['Chilonzor','Yunusobod Universam','Karshi Bahor']) as nom;
