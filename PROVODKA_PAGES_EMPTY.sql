-- =====================================================================
-- PROVODKA — "bo'sh allowed_pages = HECH QANDAY ruxsat" (semantika teskari)
-- ---------------------------------------------------------------------
-- Eski qoida: allowed_pages bo'sh = HAMMA sahifa ochiq.
-- Yangi qoida: allowed_pages bo'sh = HECH QAYSI sahifa ochiq emas.
--
-- Sabab: userlarning ~80% i faqat hodim.html (xarajat kiritish) ni ishlatadi.
-- Eski qoidada adminda "hech qaysi sahifa" degan holat umuman yo'q edi —
-- bo'shatsang, aksincha, hammasi ochilib ketardi.
--
-- hodim.html bu ro'yxatga KIRMAYDI va hech qachon cheklanmaydi (perm_pages()
-- ichida 'hodim' kaliti yo'q — butun o'zgarishning maqsadi shu).
--
-- ---------------------------------------------------------------------
-- MIGRATSIYA QARORI: (b) — HAMMANI YOPIB, KEYIN QO'LDA OCHISH
-- ---------------------------------------------------------------------
-- Laziz (2026-08-11) shu variantni tanladi. Ya'ni bu faylda "hozirgi
-- userlarga 14 sahifa yozib qo'yish" bloki YO'Q. Deploy'dan keyin
-- admin-dev.html dan kerakli userlarga qo'lda beriladi.
--
-- DIQQAT — orqaga qaytish uchun 7-BO'LIMdagi rollback blokidan boshqa yo'l
-- yo'q: eski admin_set_provodka_perms "hamma sahifa belgilangan" userni ham
-- allowed_pages='{}' qilib saqlagan, ya'ni "cheklovsiz" va "hammasi
-- belgilangan" userlar bazada BIR XIL ko'rinadi — ularni ajratib bo'lmaydi.
--
-- ---------------------------------------------------------------------
-- BU FAYL O'ZI HECH KIMNI YOPMAYDI
-- ---------------------------------------------------------------------
-- my_perms() ilgari ham qatorsiz userga allowed_pages: [] qaytargan. O'zgargani —
-- javobga has_provodka bayrog'i qo'shildi, ya'ni "bo'sh" ni QANDAY TALQIN QILISH
-- klientda hal bo'ladi. Hozirgi prod perms.js bo'shni "hammasi ochiq" deb o'qiydi.
-- Haqiqiy yopilish perms-dev.js -> perms.js ga promote qilinganda sodir bo'ladi.
-- Ya'ni tartib: (1) shu SQL RUN -> hech narsa o'zgarmaydi, (2) dev'da sinov,
-- (3) promote -> shu daqiqada semantika teskari aylanadi.
--
-- Qoidalar (PROVODKA_PERMS.sql naqshi):
--   * ADDITIVE — ustun/funksiya o'chirilmaydi, imzo o'zgarmaydi
--   * idempotent — qayta-qayta ishga tushirsa bo'ladi
--   * xato holat -> RAISE EXCEPTION
--   * REVOKE anon  * SECURITY DEFINER da auth guard
--
-- PROVODKA_PERMS.sql va PROVODKA_FILIAL_PERM.sql dan KEYIN ishga tushiriladi.
-- =====================================================================


-- =====================================================================
-- 1-BO'LIM — Old shartlar
-- =====================================================================

do $$
begin
  if to_regclass('public.user_perms') is null then
    raise exception 'user_perms jadvali yoq — avval PROVODKA_PERMS.sql ni bajaring';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='user_perms'
                    and column_name='filial_scope') then
    raise exception 'user_perms.filial_scope yoq — avval PROVODKA_FILIAL_PERM.sql ni bajaring';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='accounts'
                    and column_name='pul_turi') then
    raise exception 'accounts.pul_turi yoq — avval PROVODKA_VALYUTA.sql ni bajaring';
  end if;
end $$;


-- =====================================================================
-- 2-BO'LIM — perm_pages() — 12 emas, 14 kalit
-- ---------------------------------------------------------------------
-- TUZATISH: 'yuklar' va 'standart' sahifalari keyin qo'shilgan, lekin bu
-- funksiyaga tushmagan. Natijada admin_set_provodka_perms ularni "noma'lum
-- kalit" deb JIMGINA TASHLAB YUBORARDI — admin belgilasa ham saqlanmasdi.
-- Eski semantikada bu sezilmasdi (bo'sh = hammasi ochiq), yangisida esa
-- user o'sha ikki sahifani umuman ololmay qolardi.
--
-- Ro'yxat perms.js dagi PAGES bilan AYNAN bir xil bo'lishi shart.
-- 'hodim' bu yerda YO'Q va bo'lmasligi ham kerak — u cheklanmaydigan sahifa.
-- =====================================================================

create or replace function perm_pages()
returns text[]
language sql
immutable
as $$
  select array['kassa','jurnal','professional','hisobot','balans','cashflow',
               'qarzdor','filial','valyuta','konvert','sozlama','provodka',
               'yuklar','standart']::text[];
$$;

revoke all on function perm_pages() from public, anon;
grant execute on function perm_pages() to authenticated, service_role;

comment on function perm_pages() is
  'Provodka sahifa kalitlari (14 ta). perms.js dagi PAGES bilan bir xil. '
  'hodim.html bu royxatga KIRMAYDI — u hech qachon cheklanmaydi.';


-- =====================================================================
-- 3-BO'LIM — my_perms() — has_provodka bayrog'i
-- ---------------------------------------------------------------------
-- Imzo o'zgarmaydi (returns jsonb), mavjud kalitlar joyida qoladi —
-- prod frontend sinmaydi. Qo'shilgani:
--   is_admin      (avval ham bor edi, endi hamma tarmoqda aniq)
--   has_provodka  = is_admin OR allowed_pages bo'sh emas
--
-- has_provodka=false -> klient login'dan keyin to'g'ridan hodim sahifasiga
-- olib o'tadi ("Ruxsat yo'q" ekranini ko'rsatmasdan).
--
-- Qatori yo'q user: allowed_pages [] (avvalgidek) + has_provodka=false.
-- Boshqa defaultlar TEGILMAYDI: kassa_scope='all', can_convert=true,
-- filial_scope='all' — pul cheklovi alohida masala, bu o'zgarish unga kirmaydi.
-- =====================================================================

create or replace function my_perms()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare p user_perms; v_admin boolean; v_has boolean;
begin
  if auth.uid() is null then
    raise exception 'Avtorizatsiya kerak';
  end if;

  v_admin := is_admin();

  -- Admin har doim to'liq huquqli — user_perms qatori bo'lsa ham e'tiborga olinmaydi.
  -- allowed_pages ataylab bo'sh qaytadi: klient avval is_admin ni tekshiradi.
  if v_admin then
    return jsonb_build_object(
      'user_id',        auth.uid(),
      'allowed_pages',  '[]'::jsonb,
      'kassa_scope',    'all',
      'view_kassa_ids', '[]'::jsonb,
      'op_kassa_ids',   '[]'::jsonb,
      'can_convert',    true,
      'filial_scope',   'all',
      'filial_ids',     '[]'::jsonb,
      'is_admin',       true,
      'has_provodka',   true);
  end if;

  select * into p from user_perms where user_id = auth.uid();

  -- Qatori yo'q: sahifa ruxsati YO'Q (yangi semantika), qolgan cheklovlar ochiq.
  if not found then
    return jsonb_build_object(
      'user_id',        auth.uid(),
      'allowed_pages',  '[]'::jsonb,
      'kassa_scope',    'all',
      'view_kassa_ids', '[]'::jsonb,
      'op_kassa_ids',   '[]'::jsonb,
      'can_convert',    true,
      'filial_scope',   'all',
      'filial_ids',     '[]'::jsonb,
      'is_admin',       false,
      'has_provodka',   false);
  end if;

  v_has := coalesce(array_length(p.allowed_pages, 1), 0) > 0;

  return jsonb_build_object(
    'user_id',        p.user_id,
    'allowed_pages',  to_jsonb(p.allowed_pages),
    'kassa_scope',    p.kassa_scope,
    'view_kassa_ids', to_jsonb(p.view_kassa_ids),
    'op_kassa_ids',   to_jsonb(p.op_kassa_ids),
    'can_convert',    p.can_convert,
    'filial_scope',   p.filial_scope,
    'filial_ids',     to_jsonb(p.filial_ids),
    'is_admin',       false,
    'has_provodka',   v_has);
end $$;

revoke all on function my_perms() from public, anon;
grant execute on function my_perms() to authenticated;


-- =====================================================================
-- 4-BO'LIM — perm_has_page() — server tomonda sahifa tekshiruvi
-- ---------------------------------------------------------------------
-- Sahifa ruxsati asosan UI masalasi (pul guardi alohida va u tegilmaydi),
-- lekin kelajakda hisobot RPC'lariga qo'yish uchun yordamchi tayyor tursin.
-- HOZIR HECH QAYERDA CHAQIRILMAYDI — qo'shilsa alohida qadamda.
-- =====================================================================

create or replace function perm_has_page(p_key text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare p user_perms;
begin
  if auth.uid() is null then return true; end if;      -- service_role (n8n)
  if is_admin() then return true; end if;
  -- Ro'yxatga kirmaydigan sahifa (masalan 'hodim') hech qachon cheklanmaydi
  if not (p_key = any(perm_pages())) then return true; end if;
  select * into p from user_perms where user_id = auth.uid();
  if not found then return false; end if;              -- qatorsiz = ruxsat yo'q
  return p_key = any(p.allowed_pages);
end $$;

revoke all on function perm_has_page(text) from public, anon;
grant execute on function perm_has_page(text) to authenticated, service_role;

comment on function perm_has_page(text) is
  'Sahifa ruxsati (yangi semantika: bosh royxat = ruxsat yoq). Hozircha faqat yordamchi.';


-- =====================================================================
-- 5-BO'LIM — admin_set_provodka_perms — bo'sh massiv shundayligicha yoziladi
-- ---------------------------------------------------------------------
-- OLIB TASHLANDI:
--   if array_length(v_pages,1) = array_length(perm_pages(),1) then v_pages := '{}';
--
-- Bu blok "hammasi belgilangan" ni "bo'sh" ga aylantirardi (eski semantikada
-- ikkalasi bir xil ma'noda edi). Yangi semantikada bu TESKARI natija berardi:
-- admin hamma sahifani belgilaydi -> bazaga bo'sh tushadi -> user hech qayerga
-- kira olmaydi. Endi nima belgilangan bo'lsa — o'shanday saqlanadi.
--
-- Qolgani o'zgarmadi: op ⊆ view, scope='all' -> ro'yxat bo'shatiladi,
-- noma'lum sahifa kaliti tashlanadi, admin userga cheklov yozilmaydi.
-- Imzo va qaytish shakli ham o'zgarmadi — n8n tomonda hech narsa qilinmaydi.
-- =====================================================================

create or replace function admin_set_provodka_perms(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role   text;
  v_uid    uuid;
  v_scope  text;
  v_pages  text[];
  v_view   uuid[];
  v_op     uuid[];
  v_conv   boolean;
  v_fscope text;
  v_fids   uuid[];
  v_by     uuid;
  v_target text;
  v_bad    int;
begin
  -- service_role ONLY. GRANT ham shuni beradi, bu ikkinchi qavat.
  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  v_uid := nullif(p_data ->> 'user_id', '')::uuid;
  if v_uid is null then
    raise exception 'user_id kerak';
  end if;

  select role into v_target from profiles where id = v_uid;
  if v_target is null then
    raise exception 'Bunday Provodka foydalanuvchisi yoq: %', v_uid;
  end if;

  -- Admin doim to'liq huquqli — unga cheklov saqlanmaydi.
  if v_target = 'admin' then
    delete from user_perms where user_id = v_uid;
    return jsonb_build_object('ok', true, 'skipped', 'admin',
      'note', 'Admin doim toliq huquqli — cheklov saqlanmadi');
  end if;

  v_scope := coalesce(p_data ->> 'kassa_scope', 'all');
  if v_scope not in ('all','list') then
    raise exception 'kassa_scope faqat all yoki list bolishi mumkin: %', v_scope;
  end if;

  v_fscope := coalesce(p_data ->> 'filial_scope', 'all');
  if v_fscope not in ('all','list') then
    raise exception 'filial_scope faqat all yoki list bolishi mumkin: %', v_fscope;
  end if;

  v_conv := coalesce((p_data ->> 'can_convert')::boolean, true);
  v_by   := nullif(p_data ->> 'updated_by', '')::uuid;

  -- Sahifalar: faqat ma'lum kalitlar. Bo'sh kelsa BO'SH saqlanadi = ruxsat yo'q.
  select coalesce(array_agg(x order by x), '{}')
    into v_pages
    from (select distinct jsonb_array_elements_text(coalesce(p_data -> 'allowed_pages','[]'::jsonb)) as x) s
   where x = any(perm_pages());

  select coalesce(array_agg(distinct x::uuid), '{}') into v_view
    from jsonb_array_elements_text(coalesce(p_data -> 'view_kassa_ids','[]'::jsonb)) as x;
  select coalesce(array_agg(distinct x::uuid), '{}') into v_op
    from jsonb_array_elements_text(coalesce(p_data -> 'op_kassa_ids','[]'::jsonb)) as x;

  if v_scope = 'all' then
    -- Cheklov yo'q — ro'yxatlarni saqlab o'tirmaymiz (yarim-holat qolmasin)
    v_view := '{}';
    v_op   := '{}';
  else
    -- op ⊆ view majburlash: ortiqchasini kesib tashlaymiz
    select coalesce(array_agg(x), '{}') into v_op
      from unnest(v_op) as x where x = any(v_view);

    -- Mavjud bo'lmagan hisob id'lari kelib qolmasin
    select count(*) into v_bad
      from unnest(v_view) as x where not exists (select 1 from accounts a where a.id = x);
    if v_bad > 0 then
      raise exception 'view_kassa_ids ichida % ta notanish hisob id bor', v_bad;
    end if;
  end if;

  -- Filial ro'yxati (metadata) — kelgan id'lardan FAQAT mavjud filial hisoblari qoladi.
  -- Qattiq rad etmaymiz: admin-dev ro'yxati bilan farq bo'lsa ham save o'tishi kerak.
  select coalesce(array_agg(distinct x::uuid), '{}') into v_fids
    from jsonb_array_elements_text(coalesce(p_data -> 'filial_ids','[]'::jsonb)) as x;

  if v_fscope = 'all' then
    v_fids := '{}';                       -- cheklov yo'q — ro'yxat saqlanmaydi
  else
    select coalesce(array_agg(a.id), '{}') into v_fids
      from accounts a
     where a.id = any(v_fids) and a.kassa_turi = 'filial';
  end if;

  insert into user_perms(user_id, allowed_pages, kassa_scope, view_kassa_ids,
                         op_kassa_ids, can_convert, filial_scope, filial_ids,
                         updated_at, updated_by)
  values (v_uid, v_pages, v_scope, v_view, v_op, v_conv, v_fscope, v_fids, now(), v_by)
  on conflict (user_id) do update
     set allowed_pages  = excluded.allowed_pages,
         kassa_scope    = excluded.kassa_scope,
         view_kassa_ids = excluded.view_kassa_ids,
         op_kassa_ids   = excluded.op_kassa_ids,
         can_convert    = excluded.can_convert,
         filial_scope   = excluded.filial_scope,
         filial_ids     = excluded.filial_ids,
         updated_at     = now(),
         updated_by     = excluded.updated_by;

  return jsonb_build_object('ok', true, 'user_id', v_uid,
    'allowed_pages', to_jsonb(v_pages), 'kassa_scope', v_scope,
    'view_kassa_ids', to_jsonb(v_view), 'op_kassa_ids', to_jsonb(v_op),
    'can_convert', v_conv,
    'filial_scope', v_fscope, 'filial_ids', to_jsonb(v_fids),
    'has_provodka', coalesce(array_length(v_pages,1),0) > 0);
end $$;

revoke all on function admin_set_provodka_perms(jsonb) from public, anon, authenticated;
grant execute on function admin_set_provodka_perms(jsonb) to service_role;


-- =====================================================================
-- 6-BO'LIM — v_filial_tanlov — to'lov turi bolalari chiqmasin
-- ---------------------------------------------------------------------
-- MUAMMO: create_pul_turi_child() bola-hisobga parentning kassa_turi'sini
-- NUSXALAYDI (PROVODKA_VALYUTA.sql). Ya'ni "Izza Showroom · Naqd",
-- "· Click", "· Payme" hisoblarida ham kassa_turi='filial' turadi va ular
-- v_filial_tanlov'ga tushib qoladi. Natijada hodim bitta filialni uch marta
-- ko'radi va qaysi birini tanlashini bilmaydi — u FILIALNI tanlaydi,
-- to'lov turini emas (pul baribir kassadan chiqadi, bu faqat metadata).
--
-- YECHIM: bola-hisoblarni chiqarib tashlash. Nom bo'yicha DISTINCT emas —
-- to'lov turi nomda emas, `pul_turi` ustunida; valyuta bolalari esa
-- currency <> 'UZS'. Ikkovi ham parent filialga qaytadi.
--
-- Shakl (id, code, name, subtitle) O'ZGARMAYDI — hodim.html, professional.html
-- va standart.html `select('*')` qiladi, ular tegilmaydi.
--
-- filial_ids kontrakti ham buzilmaydi: admin filialning HAMMA kassa id'sini
-- yozadi (parent ham ichida), permFilterFilials esa endi faqat parent id'ni
-- tekshiradi — u to'plamda bor.
-- =====================================================================

create or replace view v_filial_tanlov
with (security_invoker = on) as
  select id, code, name, subtitle
    from accounts
   where kassa_turi = 'filial'
     and coalesce(is_active, true) = true
     and pul_turi is null                      -- · Naqd / · Click / · Payme bolalari
     and coalesce(currency, 'UZS') = 'UZS'     -- valyuta bolalari (56xx USD …)
   order by name, code;

comment on view v_filial_tanlov is
  'Xarajat metadata uchun filial kassalari (hodim.html multiselect; accounts.id). '
  'Har filial BITTA qator — pul turi va valyuta bola-hisoblari chiqarib tashlanadi.';


-- =====================================================================
-- 7-BO'LIM — Tekshiruv va hisobot
-- ---------------------------------------------------------------------
-- Promote'dan KEYIN kim Provodka'dan chiqib qolishini oldindan ko'rsatadi.
-- =====================================================================

do $$
declare
  v_pages   int;
  v_yopiq   int;
  v_ochiq   int;
  v_admin   int;
  v_dubl    int;
begin
  -- perm_pages 14 talikmi
  select array_length(perm_pages(), 1) into v_pages;
  if v_pages <> 14 then
    raise exception 'perm_pages() % ta kalit qaytardi, 14 kutilgandi', v_pages;
  end if;

  -- Eski "hammasi belgilangan -> bo'sh" bloki chindan olib tashlanganmi
  if (select position('array_length(v_pages, 1) = array_length(perm_pages(), 1)' in prosrc)
        from pg_proc where proname = 'admin_set_provodka_perms' limit 1) > 0 then
    raise exception 'admin_set_provodka_perms ichida eski "hammasi -> bosh" bloki qolib ketdi';
  end if;

  -- my_perms yangilanganmi
  if (select position('has_provodka' in prosrc)
        from pg_proc where proname = 'my_perms' limit 1) = 0 then
    raise exception 'my_perms() ichida has_provodka yoq — yangilanmadi';
  end if;

  -- v_filial_tanlov'da dublikat qolmadimi (bitta filial = bitta qator)
  select count(*) into v_dubl from (
    select name from v_filial_tanlov group by name having count(*) > 1
  ) s;
  if v_dubl > 0 then
    raise notice 'DIQQAT: v_filial_tanlov''da % ta nom hali ham takrorlanyapti — tekshiring',
      v_dubl;
  end if;

  select count(*) into v_admin from profiles where role = 'admin';
  select count(*) into v_ochiq from user_perms
   where coalesce(array_length(allowed_pages, 1), 0) > 0;
  select count(*) into v_yopiq from profiles p
   where coalesce(p.role, 'user') <> 'admin'
     and not exists (select 1 from user_perms u
                      where u.user_id = p.id
                        and coalesce(array_length(u.allowed_pages, 1), 0) > 0);

  raise notice '--------------------------------------------------------';
  raise notice 'SEMANTIKA TESKARI AYLANDI (bosh royxat = ruxsat yoq)';
  raise notice 'Admin (cheklanmaydi) ............ % ta', v_admin;
  raise notice 'Sahifa royxati BOR .............. % ta', v_ochiq;
  raise notice 'Promote''dan keyin YOPILADI ..... % ta', v_yopiq;
  raise notice '--------------------------------------------------------';
  raise notice 'Bu SQL ozi hech kimni yopmaydi — yopilish perms-dev.js';
  raise notice 'perms.js ga promote qilinganda boshlanadi.';
  raise notice 'Kim yopilishini korish uchun 7.1 dagi SELECT ni ishlating.';
end $$;


-- ---------------------------------------------------------------------
-- 7.1 — KIM YOPILADI (ro'yxat). Alohida ishga tushiring:
-- ---------------------------------------------------------------------
-- select p.id, p.full_name, p.role,
--        coalesce(u.allowed_pages, '{}') as hozirgi_sahifalar
--   from profiles p
--   left join user_perms u on u.user_id = p.id
--  where coalesce(p.role,'user') <> 'admin'
--    and coalesce(array_length(u.allowed_pages,1), 0) = 0
--  order by p.full_name;


-- =====================================================================
-- 8-BO'LIM — ROLLBACK (ataylab IZOHDA — o'zi ishlamaydi)
-- ---------------------------------------------------------------------
-- Agar promote'dan keyin yopilish kutilganidan qattiqroq chiqsa — quyidagi
-- blok HAMMA cheklanmagan userga 14 sahifani yozib beradi, ya'ni eski
-- xatti-harakatni tiklaydi (brief'dagi (a) varianti). Frontendni qaytarish
-- shart emas: ro'yxat to'lgach yangi semantika ham "hammasi ochiq" beradi.
--
-- Faqat kerak bo'lganda, izohni olib tashlab ishga tushiring:
--
-- insert into user_perms (user_id, allowed_pages)
-- select p.id, perm_pages()
--   from profiles p
--  where coalesce(p.role,'user') <> 'admin'
--    and not exists (select 1 from user_perms u where u.user_id = p.id)
-- on conflict (user_id) do nothing;
--
-- update user_perms u
--    set allowed_pages = perm_pages(), updated_at = now()
--  where coalesce(array_length(u.allowed_pages,1), 0) = 0
--    and exists (select 1 from profiles p
--                 where p.id = u.user_id and coalesce(p.role,'user') <> 'admin');
--
-- Bitta userni tezda ochish (id ni qo'ying):
-- insert into user_perms (user_id, allowed_pages) values ('<uuid>', perm_pages())
-- on conflict (user_id) do update set allowed_pages = perm_pages(), updated_at = now();
-- =====================================================================
