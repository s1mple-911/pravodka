-- =====================================================================
--  ⚠️⚠️  SUPABASE SQL EDITOR — QANDAY RUN QILINADI (avval SHUNI o'qing)
-- ---------------------------------------------------------------------
--   1) Bu faylda `do` bloki UMUMAN YO'Q va izohlarda dollar-quote belgisi
--      (ikki dollar yonma-yon) ham YO'Q. Supabase SQL Editor anonim
--      `do` blokini bo'lib yuborar va o'zgaruvchini jadval deb izlar edi
--      (ERROR: 42P01: relation "v_..." does not exist). Shuning uchun
--      hamma tekshiruv oddiy `select` (✅/❌ ustuni bilan).
--      Funksiya tanasidagi dollar-quote (`as` dan keyin) — normal, ishlaydi.
--
--   2) Har bo'lak ⬇⬇⬇ va ⬆⬆⬆ belgilari orasida. AYNAN o'sha oraliqni
--      belgilab RUN qiling. Tartib bilan: 1 → 2 → 3 → … → 10.
--      Butun faylni birdaniga RUN qilsa ham bo'ladi (hech qanday pul
--      harakati yo'q), lekin bo'lak-bo'lak RUN qilish tavsiya etiladi.
--
--   3) Bo'lak diapazonlari:
--        0-BO'LIM   — old shart tekshiruvi (hech narsa yozmaydi)
--        1-BO'LIM   — yuk_tannarx_sabab jadvali + seed + RLS
--        2-BO'LIM   — yuk_tannarx jadvali + indekslar + RLS
--        3-BO'LIM   — perm_pages() — 'tannarx' kaliti qo'shiladi (14 → 15)
--        4-BO'LIM   — yuk_tannarx_ruxsat() / yuk_tannarx_admin() — guardlar
--        5-BO'LIM   — yuk_tannarx_qosh()
--        6-BO'LIM   — yuk_tannarx_ochir()
--        7-BO'LIM   — yuk_tannarx_jami()      ⭐ eng ko'p ishlatiladigan
--        8-BO'LIM   — yuk_tannarx_sabab_qosh() / _sabab_ochir()
--        9-BO'LIM   — TEKSHIRUVLAR (faqat select, ✅/❌)
--       10-BO'LIM   — notify pgrst (PostgREST sxema keshini yangilash)
--       11-BO'LIM   — ROLLBACK (izohda, qo'lda ishlatiladi)
--
--      ⚠️ TARTIB MUHIM: `perm_pages()` (3-BO'LIM) guarddan (4-BO'LIM) OLDIN
--         turadi. Guard fail-CLOSED: `perm_pages()` da 'tannarx' kaliti
--         bo'lmasa hech kim tannarx yoza olmaydi. Ya'ni 3-BO'LIM o'tkazib
--         yuborilsa sahifa "faqat o'qish" bo'lib qoladi (avvalgidek "hamma
--         yoza oladi" EMAS).
-- =====================================================================

-- =====================================================================
--  PROVODKA_YUK_TANNARX.sql
--  Yuk tannarxini oshirish — qo'shimcha xarajatlar qatlami
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  #####  NIMA QILADI  #################################################
--
--  Yuklar Aros'dan keladi (`narx` + `valyuta`), qiymat klientda
--  `narx × kurs` bilan hisoblanadi. Endi ustiga PROVODKA tomonidagi
--  qo'shimcha xarajatlar qatlami qo'shiladi: yo'l puli, bojxona,
--  valyuta farqi, abusaxiy va h.k.
--
--        yuk qiymati = (narx × kurs)  +  yuk_tannarx yig'indisi
--                       ^Aros'dan        ^shu fayl beradi
--
--  #####  🔴 PUL HARAKATI YO'Q (Asilbek qarori)  #######################
--
--  Tannarx qo'shilishi `entry` / `entry_line` YOZMAYDI. Bu faqat yukning
--  QIYMAT QATLAMI (metadata), double-entry'ga umuman tegilmaydi:
--     • Dt=Kt triggeri bu yerda ishtirok etmaydi;
--     • `trg_perm_guard_entry_line` guardi ham tegishli emas (satr yo'q);
--     • balans / P&L / cashflow raqamlari O'ZGARMAYDI.
--  Haqiqiy to'lov keyin `professional` sahifasida ALOHIDA yoziladi.
--  Ya'ni bu jadval bilan pul yozuvi o'rtasida bog'lanish YO'Q — ataylab.
--
--  #####  ESLATMA — "hech narsa o'chirilmaydi"  ########################
--
--  CLAUDE.md qoidasi: o'chirish = `is_deleted = true` + kim/qachon.
--  `yuk_tannarx` da hard-delete YO'Q, `yuk_tannarx_sabab` da ham
--  o'chirish emas — `is_active = false` (passivlashtirish).
--
--  #####  ADDITIVE  ####################################################
--
--  Mavjud jadval / ustun / view / funksiya O'ZGARTIRILMAYDI. Yangi:
--     jadval    yuk_tannarx_sabab, yuk_tannarx
--     funksiya  yuk_tannarx_ruxsat, yuk_tannarx_admin, yuk_tannarx_qosh,
--               yuk_tannarx_ochir, yuk_tannarx_jami, yuk_tannarx_sabab_qosh,
--               yuk_tannarx_sabab_ochir
--  Yagona istisno — `perm_pages()`: `create or replace`, eski 14 kalit
--  TARTIBI SAQLANIB, oxiriga 'tannarx' QO'SHILADI (hech biri olinmaydi).
--
--  🔴 KLIENT TOMONI: `perms.js` / `perms-dev.js` dagi `PAGES` massiviga
--     ham 'tannarx' qo'shilishi SHART (aynan bir xil ro'yxat bo'lsin),
--     aks holda `admin_set_provodka_perms` bu kalitni "noma'lum" deb
--     jimgina tashlab yuboradi va admin sahifani hech kimga bera olmaydi.
--
--  TALAB: PROVODKA_PERMS.sql (profiles, user_perms) — bo'lmasa ham fayl
--         ishlaydi, faqat ruxsat guardi "hamma ochiq" holatga tushadi.
-- =====================================================================


-- #####################################################################
--  0-BO'LIM — OLD SHART TEKSHIRUVI.  HECH NARSA YOZMAYDI.
-- #####################################################################
--  Hammasi ✅ bo'lishi shart emas: 0.2 ⚠️ bo'lsa ham fayl ishlaydi
--  (ruxsat tizimi umuman yo'q bo'lsa guard ochiq qoladi — 4-BO'LIM izohiga qara).

-- 0.1 profiles jadvali (created_by_name shundan olinadi)
select 'profiles.full_name' as tekshiruv,
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'profiles'
                            and column_name = 'full_name')
            then '✅ OK' else '❌ YO''Q — PROVODKA_ISM.sql ni RUN qiling' end as natija;

-- 0.2 Ruxsat tizimi bormi (bo'lmasa yozuvchi RPC'lar authenticated'ga ochiq)
select 'perm_has_page(text)' as tekshiruv,
       case when to_regprocedure('public.perm_has_page(text)') is not null
            then '✅ BOR — tannarx sahifa ruxsati bilan tekshiriladi'
            else '⚠️ YO''Q — guard ochiq (har authenticated yoza oladi)' end as natija
union all
select 'perm_pages()',
       case when to_regprocedure('public.perm_pages()') is not null
            then '✅ BOR — 3-BO''LIM unga tannarx qo''shadi'
            else '⚠️ YO''Q — 3-BO''LIMni OTKAZIB YUBORING' end
union all
select 'profiles.role (admin guardi)',
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'profiles'
                            and column_name = 'role')
            then '✅ BOR — sabab boshqaruvi va ochirish admin bilan tekshiriladi'
            else '❌ YO''Q — admin guardi hech kimni otkazmaydi' end;

-- 0.3 Bu fayl ilgari RUN qilinganmi (bo'sh natija = yangi o'rnatish)
select 'yuk_tannarx_sabab' as obyekt,
       case when to_regclass('public.yuk_tannarx_sabab') is not null
            then 'allaqachon bor' else 'yo''q (yangi yaratiladi)' end as holat
union all
select 'yuk_tannarx',
       case when to_regclass('public.yuk_tannarx') is not null
            then 'allaqachon bor' else 'yo''q (yangi yaratiladi)' end;


-- #####################################################################
--  1-BO'LIM — yuk_tannarx_sabab — tahrirlanadigan sabablar ro'yxati
-- #####################################################################
--  Sabablar QATTIQ KODLANMAGAN: admin yangisini qo'shishi va eskisini
--  passivlashtirishi mumkin (8-BO'LIM RPC'lari — faqat admin). Klient dropdowni shu
--  jadvaldan `is_active = true` qatorlarni `tartib, nom` bo'yicha o'qiydi.
--
--  `tartib` — ko'rsatish tartibi (kichigi yuqorida). Seed qatorlar
--  10/20/30/40/90; qo'lda qo'shilgani default 100 bilan ularning ostiga
--  tushadi, "➕ Boshqa" (90) esa har doim oxiriga yaqin turadi.

-- ⬇⬇⬇  1-BO'LIM: SHU QATORDAN 1-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create table if not exists yuk_tannarx_sabab (
  id         serial      primary key,
  nom        text        not null unique,
  ikonka     text,
  tartib     int         not null default 100,
  is_active  boolean     not null default true,
  created_at timestamptz not null default now()
);

comment on table yuk_tannarx_sabab is
  'Yuk tannarxiga qoshimcha sabablari (yol puli, bojxona...). Ochirilmaydi — is_active=false.';
comment on column yuk_tannarx_sabab.ikonka is 'Emoji (ixtiyoriy). Klient nom oldida korsatadi.';
comment on column yuk_tannarx_sabab.tartib is 'Korsatish tartibi, kichigi yuqorida. Qolda qoshilgani 100.';

-- Bir xil nom ikki xil registrda kirmasin ("Bojxona" / "bojxona").
-- unique(nom) faqat aynan bir xil matnni to'sadi, bu indeks registrni ham.
create unique index if not exists yuk_tannarx_sabab_nom_uniq
  on yuk_tannarx_sabab (lower(nom));

create index if not exists yuk_tannarx_sabab_faol_idx
  on yuk_tannarx_sabab (tartib, nom) where is_active;

-- Seed — takror RUN qilinsa hech narsa o'zgarmaydi (do nothing).
-- Nomlari o'zgartirilsa/passivlashtirilsa qayta tiklanmaydi — ataylab.
insert into yuk_tannarx_sabab (nom, ikonka, tartib) values
  ('Yo''l puli',     '🚚', 10),
  ('Valyuta farqi',  '💱', 20),
  ('Bojxona',        '🛃', 30),
  ('Abusaxiy',       '📋', 40),
  ('Boshqa',         '➕', 90)
on conflict do nothing;

-- RLS: o'qish — har authenticated (dropdown uchun kerak).
-- YOZISH POLICY'SI UMUMAN YO'Q — faqat SECURITY DEFINER RPC yozadi
-- (user_perms bilan bir xil naqsh). Anon butunlay yopiq.
alter table yuk_tannarx_sabab enable row level security;

drop policy if exists yuk_tannarx_sabab_sel on yuk_tannarx_sabab;
create policy yuk_tannarx_sabab_sel on yuk_tannarx_sabab
  for select to authenticated using (true);

revoke all on yuk_tannarx_sabab from public, anon;
grant select on yuk_tannarx_sabab to authenticated;
-- ⬆⬆⬆  1-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  2-BO'LIM — yuk_tannarx — yukka qo'shilgan xarajatlar
-- #####################################################################
--  `yuk_id` — Aros product-income id (integer). `entry.yuk_ids` va
--  `entry_yuk.yuk_id` bilan AYNAN bir xil ma'noda (foreign key yo'q:
--  yuklar Aros'da, Provodka bazasida yuk jadvali umuman yo'q).
--
--  🔴 Bu jadval `entry` bilan BOG'LANMAGAN — pul harakati yo'q
--     (fayl boshidagi izohga qara).

-- ⬇⬇⬇  2-BO'LIM: SHU QATORDAN 2-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create table if not exists yuk_tannarx (
  id              bigserial   primary key,
  yuk_id          integer     not null,
  sabab_id        int         not null references yuk_tannarx_sabab(id),
  summa_uzs       numeric     not null check (summa_uzs > 0),
  izoh            text,
  kalit           text,
  is_deleted      boolean     not null default false,
  created_by      uuid,
  created_by_name text,
  created_at      timestamptz not null default now(),
  deleted_by_name text,
  deleted_at      timestamptz
);

comment on table yuk_tannarx is
  'Yuk tannarxiga qoshimcha xarajat (UZS). PUL HARAKATI YOQ — faqat qiymat qatlami. '
  'Ochirish = is_deleted true (hech narsa ochirilmaydi).';
comment on column yuk_tannarx.yuk_id is 'Aros product-income id. entry.yuk_ids bilan bir xil manoda.';
comment on column yuk_tannarx.summa_uzs is 'Somda, doim musbat. Valyutada bolsa klient kurs bilan somga aylantiradi.';
comment on column yuk_tannarx.kalit is
  'Idempotentlik kaliti (klient bir martalik UUID beradi). Bir xil kalit ikkinchi marta kelsa yozilmaydi.';
comment on column yuk_tannarx.created_by is
  'auth.uid() — ochirish ruxsati shunga qaraydi (admin yoki qatorni yaratgan odam).';

-- ⭐ Asosiy indeks — yuk_tannarx_jami() shundan o'qiydi (partial: o'chirilgani kirmaydi)
create index if not exists yuk_tannarx_yuk_idx
  on yuk_tannarx (yuk_id) where not is_deleted;

-- Sabab bo'yicha hisobot / "bu sabab ishlatilganmi" tekshiruvi uchun
create index if not exists yuk_tannarx_sabab_id_idx
  on yuk_tannarx (sabab_id) where not is_deleted;

-- ⭐ TAKRORLANISH HIMOYASI. Tarmoq timeout bo'lib foydalanuvchi "Saqlash" ni
-- ikkinchi marta bosgan holat: bir xil `kalit` bilan kelgan yozuv ikkinchi marta
-- kirmaydi va yuk qiymati ikki barobar oshmaydi.
-- (kalit, yuk_id) — chunki BITTA chaqiruv bir kalit bilan bir nechta yukka yozadi;
-- o'chirilgan qator kirmaydi, ya'ni o'chirgandan keyin qayta kiritsa bo'ladi.
create unique index if not exists yuk_tannarx_kalit_uniq
  on yuk_tannarx (kalit, yuk_id) where kalit is not null and not is_deleted;

-- Kim yozgani bo'yicha qidiruv (ochirish ruxsati tekshiruvi va shaxsiy tarix)
create index if not exists yuk_tannarx_created_by_idx
  on yuk_tannarx (created_by) where not is_deleted;

-- RLS: o'qish — har authenticated. Yozish policy'si YO'Q (faqat RPC).
alter table yuk_tannarx enable row level security;

drop policy if exists yuk_tannarx_sel on yuk_tannarx;
create policy yuk_tannarx_sel on yuk_tannarx
  for select to authenticated using (true);

revoke all on yuk_tannarx from public, anon;
grant select on yuk_tannarx to authenticated;
-- ⬆⬆⬆  2-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  3-BO'LIM — perm_pages() ga 'tannarx' (14 → 15 kalit)
-- #####################################################################
--  ⚠️ BU BO'LIM GUARDDAN (4-BO'LIM) OLDIN TURADI — ataylab. Guard
--     fail-CLOSED: `perm_pages()` da 'tannarx' kaliti bo'lmasa hech kim
--     tannarx yoza olmaydi. Shuning uchun kalit avval qo'shiladi.
--
--  ADDITIVE: eski 14 kalit AYNAN o'sha tartibda qoladi, oxiriga
--  'tannarx' qo'shiladi. Hech bir kalit olib tashlanmaydi.
--
--  🔴 `perms.js` / `perms-dev.js` dagi PAGES massiviga ham 'tannarx'
--     qo'shilsin — aks holda admin_set_provodka_perms uni "noma'lum
--     kalit" deb jimgina tashlab yuboradi.
--
--  'hodim' bu ro'yxatda YO'Q va bo'lmasligi kerak (cheklanmaydigan sahifa).
--
--  ⚠️ 0.2 da `perm_pages()` YO'Q chiqqan bo'lsa — bu bo'limni O'TKAZIB
--     YUBORING (ruxsat tizimi hali o'rnatilmagan; guard ham `perm_has_page`
--     yo'qligini ko'rib ochiq holatga tushadi). PROVODKA_PERMS.sql yoki
--     PROVODKA_PAGES_EMPTY.sql KEYIN RUN qilinsa ular `perm_pages()` ni
--     14 kalitga qaytaradi va 'tannarx' YO'QOLADI — o'shanda tannarx
--     yozuvi TO'SILIB qoladi, bu bo'limni QAYTA RUN qiling (9.5 tekshiruvi).

-- ⬇⬇⬇  3-BO'LIM: SHU QATORDAN 3-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function perm_pages()
returns text[]
language sql
immutable
as $$
  select array['kassa','jurnal','professional','hisobot','balans','cashflow',
               'qarzdor','filial','valyuta','konvert','sozlama','provodka',
               'yuklar','standart','tannarx']::text[];
$$;

revoke all on function perm_pages() from public, anon;
grant execute on function perm_pages() to authenticated, service_role;

comment on function perm_pages() is
  'Provodka sahifa kalitlari (15 ta). perms.js dagi PAGES bilan bir xil. '
  'hodim.html bu royxatga KIRMAYDI — u hech qachon cheklanmaydi.';
-- ⬆⬆⬆  3-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  4-BO'LIM — GUARDLAR: yuk_tannarx_ruxsat() va yuk_tannarx_admin()
-- #####################################################################
--  yuk_tannarx_ruxsat() — "kim tannarx yozadi" (qosh / ochir uchun asos).
--  Qoida — FAIL-CLOSED (noto'g'ri o'rnatishda ochilib ketmaydi):
--     • service_role / n8n (auth.uid() null)   → ruxsat bor;
--     • `perm_has_page(text)` UMUMAN YO'Q      → ruxsat bor (ruxsat tizimi
--       hali o'rnatilmagan baza sinmasin — eski, ma'lum holat);
--     • ruxsat tizimi BOR, lekin `perm_pages()` da 'tannarx' YO'Q →
--       ruxsat YO'Q. Sababi: `perm_has_page()` ro'yxatga kirmaydigan
--       kalitni "cheklanmaydigan sahifa" deb HAMMAGA `true` qaytaradi
--       (masalan 'hodim'). Ya'ni 3-BO'LIM o'tkazib yuborilsa yoki
--       PROVODKA_PAGES_EMPTY.sql qayta RUN qilinib ro'yxat 14 ga qaytsa,
--       har qanday authenticated user yuk qiymatini o'zgartira olardi.
--       Endi bunday holatda yozuv butunlay to'siladi (o'qish ochiq qoladi).
--     • qolgan holatda → `perm_has_page('tannarx')` nima desa shu
--       (admin doim o'tadi, ro'yxatsiz user o'tmaydi).
--
--  yuk_tannarx_admin() — faqat admin ishi uchun (sabab qo'shish/passivlash,
--  o'zganing qatorini o'chirish). `profiles.role='admin'` dan o'qiydi;
--  `auth.uid()` null (service_role) o'tadi — mavjud naqsh.
--
--  `to_regprocedure` naqshi konvertdagidek: shu tufayli bu fayl bilan
--  PROVODKA_PERMS.sql ning ishga tushirilish TARTIBI muhim emas.
--
--  ⚠️ Bu guard XAVFSIZLIK CHEGARASI EMAS, faqat "kim tannarx kiritadi"
--     nazorati. Pul yozuvining haqiqiy to'sig'i — entry_line triggeri,
--     va u bu yerda umuman ishtirok etmaydi (satr yozilmaydi).

-- ⬇⬇⬇  4-BO'LIM: SHU QATORDAN 4-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function yuk_tannarx_ruxsat()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v     boolean;
  v_bor boolean;
begin
  if auth.uid() is null then return true; end if;          -- service_role (n8n)
  if to_regprocedure('public.perm_has_page(text)') is null then
    return true;                                            -- ruxsat tizimi yo'q
  end if;
  -- Ruxsat tizimi bor: 'tannarx' kaliti ro'yxatda bo'lishi SHART
  if to_regprocedure('public.perm_pages()') is null then
    return false;                                           -- noto'g'ri o'rnatish
  end if;
  execute 'select ''tannarx'' = any(perm_pages())' into v_bor;
  if not coalesce(v_bor, false) then
    return false;                                           -- 3-BO'LIM RUN qilinmagan
  end if;
  execute 'select perm_has_page($1)' into v using 'tannarx';
  return coalesce(v, false);
end $$;

revoke all on function yuk_tannarx_ruxsat() from public, anon;
grant execute on function yuk_tannarx_ruxsat() to authenticated, service_role;

comment on function yuk_tannarx_ruxsat() is
  'Yuk tannarx yozish ruxsati (fail-closed): perm_pages da tannarx bolmasa ruxsat YOQ.';


create or replace function yuk_tannarx_admin()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_role text;
begin
  if auth.uid() is null then return true; end if;          -- service_role (n8n)
  select role into v_role from profiles where id = auth.uid();
  return coalesce(v_role, '') = 'admin';
end $$;

revoke all on function yuk_tannarx_admin() from public, anon;
grant execute on function yuk_tannarx_admin() to authenticated, service_role;

comment on function yuk_tannarx_admin() is
  'Joriy foydalanuvchi admin mi (profiles.role). service_role (auth.uid null) otadi.';
-- ⬆⬆⬆  4-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  5-BO'LIM — yuk_tannarx_qosh() — BIR NECHTA YUKKA BIRDAN
-- #####################################################################
--  IMZO:
--     yuk_tannarx_qosh(p_data jsonb, p_sabab_id int, p_izoh text default null,
--                      p_kalit text default null) returns jsonb
--
--  ⚠️ `p_kalit` OXIRIDA va `default null` — eski uch argumentli chaqiruv
--     (p_data, p_sabab_id, p_izoh) hech narsa o'zgartirmasdan ishlayveradi.
--     Pastdagi `drop function ... (jsonb, int, text)` faqat shu faylning
--     OLDINGI nusxasidan qolgan 3 argumentli variantni olib tashlaydi —
--     ikkalasi yonma-yon qolsa PostgREST nomlangan argument bilan
--     "function is not unique" (PGRST203) berardi. Bu funksiya hali
--     prod'da ishlatilmagan (jadval ham yangi), shuning uchun xavfsiz.
--
--  p_data = [{"yuk_id":1204,"summa":5000000},{"yuk_id":1205,"summa":2000000}]
--     Har yuk_id → BITTA yuk_tannarx qatori (bir xil sabab, bir xil izoh).
--     Ixtiyoriy: element ichida "izoh" bo'lsa, u shu qator uchun p_izoh
--     o'rniga ishlatiladi (qo'shimcha imkoniyat, kontraktni buzmaydi).
--     Bir xil yuk_id ikki marta kelsa — SUMMALARI QO'SHILADI va bitta
--     qator yoziladi (izoh: birinchi bo'sh bo'lmagani). Sababi: satr soni
--     kiritish niyatiga emas, klient massividagi tasodifiy takrorga bog'liq
--     bo'lib qolmasin; bundan tashqari `(kalit, yuk_id)` unique indeksi
--     bir kalit ichida ikkita bir xil yuk_id ga baribir yo'l qo'ymaydi.
--     Nechta element birlashtirilgani `birlashtirildi` da va
--     `ogohlantirishlar` da ochiq yoziladi.
--
--  p_kalit — IDEMPOTENTLIK kaliti (klient modal ochilganda bir martalik
--     UUID yasaydi). Bir xil kalit ikkinchi marta kelsa hech narsa
--     yozilmaydi: {ok:true, takror:true, qatorlar:[mavjudlari]}. Tarmoq
--     timeout bo'lganda ikki marta bosish yuk qiymatini ikki barobar
--     oshirib yubormasin. null bo'lsa — himoya yo'q (eski xatti-harakat).
--
--  QAYTISHI:
--     {ok:true, qoshildi:N, otkazildi:M, birlashtirildi:K, takror:false,
--      sabab:'Bojxona', qatorlar:[{yuk_id, id, summa_uzs}],
--      ogohlantirishlar:[...]}
--     Xato holatda: {ok:false, error:'...'} — konvert RPC'laridagidek,
--     ya'ni exception emas (klient `data.ok` ni tekshiradi).
--
--  summa <= 0, yaxlitlangach 0 bo'lgan yoki yuk_id noto'g'ri element —
--  O'TKAZIB YUBORILADI (sababi `ogohlantirishlar` da), qolganlari yoziladi.
--  ⚠️ Yaxlitlash TEKSHIRUVDAN OLDIN: 0 < summa < 0.005 bo'lsa round() 0.00
--     beradi va `check (summa_uzs > 0)` tutilmagan 23514 xatosini berardi
--     (butun chaqiruv rollback bo'lardi) — endi element jimgina skip bo'ladi.

-- ⬇⬇⬇  5-BO'LIM: SHU QATORDAN 5-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
drop function if exists yuk_tannarx_qosh(jsonb, int, text);

create or replace function yuk_tannarx_qosh(p_data jsonb, p_sabab_id int,
                                            p_izoh text default null,
                                            p_kalit text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_who    text;
  v_uid    uuid := auth.uid();
  v_kalit  text;
  v_sabab  yuk_tannarx_sabab;
  el       jsonb;
  v_yuk    integer;
  v_sum    numeric;
  v_izoh   text;
  v_xato   text;
  v_id     bigint;
  v_ok     int   := 0;
  v_skip   int   := 0;
  v_dup    int   := 0;
  v_rows   jsonb := '[]'::jsonb;
  v_warn   jsonb := '[]'::jsonb;
  v_map    jsonb := '{}'::jsonb;
  v_key    text;
  v_val    jsonb;
  v_n      int;
begin
  if not yuk_tannarx_ruxsat() then
    return jsonb_build_object('ok', false, 'error', 'Tannarx kiritish ruxsati yoq');
  end if;

  if p_data is null or jsonb_typeof(p_data) <> 'array' then
    return jsonb_build_object('ok', false, 'error',
      'p_data massiv bolishi kerak: [{"yuk_id":1204,"summa":5000000}]');
  end if;

  v_n := jsonb_array_length(p_data);
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'Birorta yuk tanlanmagan');
  end if;
  if v_n > 500 then
    return jsonb_build_object('ok', false, 'error',
      'Bir marta eng kopi 500 ta yuk. Hozir: ' || v_n);
  end if;

  select * into v_sabab from yuk_tannarx_sabab where id = p_sabab_id;
  if v_sabab.id is null then
    return jsonb_build_object('ok', false, 'error', 'Sabab topilmadi');
  end if;
  if not v_sabab.is_active then
    return jsonb_build_object('ok', false, 'error',
      'Bu sabab passiv qilingan: ' || v_sabab.nom);
  end if;

  -- ===== IDEMPOTENTLIK: shu kalit bilan allaqachon yozilganmi =====
  v_kalit := nullif(btrim(coalesce(p_kalit, '')), '');
  if v_kalit is not null then
    if length(v_kalit) > 80 then
      return jsonb_build_object('ok', false, 'error', 'p_kalit juda uzun (80 belgigacha)');
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
             'yuk_id', t.yuk_id, 'id', t.id, 'summa_uzs', t.summa_uzs)
             order by t.id), '[]'::jsonb)
      into v_rows
      from yuk_tannarx t
     where t.kalit = v_kalit and not t.is_deleted;

    if jsonb_array_length(v_rows) > 0 then
      return jsonb_build_object(
        'ok',              true,
        'takror',          true,
        'qoshildi',        0,
        'otkazildi',       0,
        'birlashtirildi',  0,
        'sabab',           v_sabab.nom,
        'qatorlar',        v_rows,
        'ogohlantirishlar',
          jsonb_build_array('Bu saqlash allaqachon bajarilgan — qayta yozilmadi'));
    end if;
    v_rows := '[]'::jsonb;
  end if;

  select coalesce(full_name, 'foydalanuvchi') into v_who
    from profiles where id = v_uid;
  v_who := coalesce(v_who, 'tizim');

  -- ===== 1-BOSQICH: tekshirish + bir xil yuk_id larni birlashtirish =====
  for el in select value from jsonb_array_elements(p_data) loop
    v_yuk  := null;
    v_sum  := null;
    v_xato := null;

    -- Cast xatolari butun so'rovni yiqitmasin. Har maydon ALOHIDA tekshiriladi,
    -- aks holda buzuq `summa` yuzasidan "yuk_id notogri" deb yozilardi.
    begin
      v_yuk := nullif(el ->> 'yuk_id', '')::integer;
    exception when others then
      v_xato := 'yuk_id';
    end;
    begin
      v_sum := nullif(el ->> 'summa', '')::numeric;
    exception when others then
      v_xato := coalesce(v_xato || ' va summa', 'summa');
    end;

    v_izoh := nullif(btrim(coalesce(el ->> 'izoh', p_izoh, '')), '');

    if v_xato is not null then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('notogri qiymat (' || v_xato || '): '
                                   || coalesce(el::text, 'null'));
      continue;
    end if;

    if v_yuk is null then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('yuk_id yoq: ' || coalesce(el::text, 'null'));
      continue;
    end if;

    if v_sum is null or v_sum <= 0 then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('yuk ' || v_yuk || ': summa 0 yoki manfiy — otkazildi');
      continue;
    end if;

    -- ⚠️ Yaxlitlash TEKSHIRUVDAN OLDIN (jadvalda check summa_uzs > 0)
    v_sum := round(v_sum, 2);
    if v_sum <= 0 then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('yuk ' || v_yuk
                                   || ': summa yaxlitlangach 0 boldi — otkazildi');
      continue;
    end if;

    v_key := v_yuk::text;
    if v_map ? v_key then
      v_dup  := v_dup + 1;
      v_sum  := v_sum + coalesce((v_map -> v_key ->> 'summa')::numeric, 0);
      v_izoh := coalesce(nullif(v_map -> v_key ->> 'izoh', ''), v_izoh);
    end if;
    v_map := v_map || jsonb_build_object(v_key,
               jsonb_build_object('summa', v_sum, 'izoh', v_izoh));
  end loop;

  if v_dup > 0 then
    v_warn := v_warn || to_jsonb(v_dup
      || ' ta element bir xil yuk uchun kelgan — summalari qoshib birlashtirildi');
  end if;

  -- ===== 2-BOSQICH: yozish =====
  for v_key, v_val in select key, value from jsonb_each(v_map) order by key::integer loop
    v_yuk  := v_key::integer;
    v_sum  := (v_val ->> 'summa')::numeric;
    v_izoh := nullif(v_val ->> 'izoh', '');
    v_id   := null;

    -- Poyga holati (ikki so'rov bir vaqtda, bir xil kalit): unique indeks
    -- to'sadi, `do nothing` uni jimgina o'tkazadi va v_id null qoladi.
    insert into yuk_tannarx (yuk_id, sabab_id, summa_uzs, izoh, kalit,
                             created_by, created_by_name)
    values (v_yuk, v_sabab.id, v_sum, v_izoh, v_kalit, v_uid, v_who)
    on conflict (kalit, yuk_id) where kalit is not null and not is_deleted
    do nothing
    returning id into v_id;

    if v_id is null then
      v_skip := v_skip + 1;
      v_warn := v_warn || to_jsonb('yuk ' || v_yuk
                                   || ': shu kalit bilan allaqachon yozilgan — otkazildi');
      continue;
    end if;

    v_ok   := v_ok + 1;
    v_rows := v_rows || jsonb_build_object('yuk_id', v_yuk, 'id', v_id,
                                           'summa_uzs', v_sum);
  end loop;

  return jsonb_build_object(
    'ok',              true,
    'takror',          false,
    'qoshildi',        v_ok,
    'otkazildi',       v_skip,
    'birlashtirildi',  v_dup,
    'sabab',           v_sabab.nom,
    'qatorlar',        v_rows,
    'ogohlantirishlar', v_warn);
end $$;

revoke all on function yuk_tannarx_qosh(jsonb, int, text, text) from public, anon;
grant execute on function yuk_tannarx_qosh(jsonb, int, text, text) to authenticated;

comment on function yuk_tannarx_qosh(jsonb, int, text, text) is
  'Bir nechta yukka birdan tannarx qoshadi. PUL HARAKATI YOQ. '
  'p_data=[{yuk_id,summa}], p_kalit — idempotentlik kaliti (takror bosish himoyasi). '
  'Qaytishi: ok/takror/qoshildi/otkazildi/birlashtirildi/qatorlar/ogohlantirishlar.';
-- ⬆⬆⬆  5-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  6-BO'LIM — yuk_tannarx_ochir() — SOFT-DELETE
-- #####################################################################
--  IMZO: yuk_tannarx_ochir(p_id bigint) returns jsonb
--  Qator BAZADAN O'CHIRILMAYDI: is_deleted=true + kim/qachon yoziladi
--  (CLAUDE.md: "Hech narsa o'chirilmaydi").
--  Allaqachon o'chirilgan qatorga {ok:false} qaytadi — takror bosishda
--  deleted_by_name/deleted_at ustiga yozilmasin.
--
--  KIM O'CHIRA OLADI (ikki bosqichli):
--     1) `yuk_tannarx_ruxsat()` — tannarx sahifasi ruxsati bo'lsin;
--     2) ADMIN yoki QATORNI YARATGAN odam (`created_by = auth.uid()`).
--  Ya'ni sahifasi ochiq oddiy user o'zganing yozuvini o'chira olmaydi.
--  `created_by` null bo'lgan eski/tashqi qatorlar — faqat admin (yozgan
--  odam noma'lum, ehtiyot tomon). service_role (auth.uid null) o'tadi.

-- ⬇⬇⬇  6-BO'LIM: SHU QATORDAN 6-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function yuk_tannarx_ochir(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r     yuk_tannarx;
  v_who text;
  v_uid uuid := auth.uid();
begin
  if not yuk_tannarx_ruxsat() then
    return jsonb_build_object('ok', false, 'error', 'Tannarx ochirish ruxsati yoq');
  end if;

  select * into r from yuk_tannarx where id = p_id;
  if r.id is null then
    return jsonb_build_object('ok', false, 'error', 'Qator topilmadi');
  end if;
  if r.is_deleted then
    return jsonb_build_object('ok', false, 'error', 'Bu qator allaqachon ochirilgan',
      'id', r.id, 'yuk_id', r.yuk_id);
  end if;

  if not yuk_tannarx_admin() and (r.created_by is null or r.created_by <> v_uid) then
    return jsonb_build_object('ok', false, 'error',
      'Faqat admin yoki qatorni kiritgan odam ochira oladi');
  end if;

  select coalesce(full_name, 'foydalanuvchi') into v_who
    from profiles where id = v_uid;

  update yuk_tannarx
     set is_deleted      = true,
         deleted_at      = now(),
         deleted_by_name = coalesce(v_who, 'tizim')
   where id = p_id;

  return jsonb_build_object('ok', true, 'id', r.id, 'yuk_id', r.yuk_id,
    'summa_uzs', r.summa_uzs);
end $$;

revoke all on function yuk_tannarx_ochir(bigint) from public, anon;
grant execute on function yuk_tannarx_ochir(bigint) to authenticated;

comment on function yuk_tannarx_ochir(bigint) is
  'Yuk tannarx qatorini soft-delete qiladi (is_deleted + kim/qachon). Hech narsa ochirilmaydi. '
  'Faqat admin yoki qatorni kiritgan odam (created_by).';
-- ⬆⬆⬆  6-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  7-BO'LIM — ⭐ yuk_tannarx_jami() — ENG KO'P ISHLATILADIGAN RPC
-- #####################################################################
--  IMZO: yuk_tannarx_jami(p_ids integer[]) returns jsonb
--  Uni `yuklar`, `professional`, `tannarx` sahifalari o'qiydi.
--
--  QAYTISHI (kalit = yuk_id, MATN ko'rinishida — jsonb obyekt kaliti):
--    {"1204": {"jami_uzs": 7000000,
--              "qatorlar": [{"id":12, "sabab":"Bojxona", "ikonka":"🛃",
--                            "summa_uzs":5000000, "izoh":"...",
--                            "sana":"2026-08-13", "kim":"Asilbek"}]}, ...}
--
--  ⚠️ QATORI YO'Q yuk umuman KALIT BO'LMAYDI (bo'sh obyekt qaytmaydi).
--     Klientda: `const t = map[String(y.id)]; const jami = t ? t.jami_uzs : 0;`
--  ⚠️ `sana` — Toshkent vaqtida (CLAUDE.md: NOW() AT TIME ZONE 'Asia/Tashkent').
--  ⚠️ O'chirilgan qatorlar KIRMAYDI (`where not is_deleted`) — partial
--     indeks `yuk_tannarx_yuk_idx` aynan shu so'rov uchun.
--
--  TEZLIK: bitta so'rov, bitta indeks skani. Guard YO'Q — o'qish hamma
--  authenticated uchun ochiq (sahifa ruxsati klientda hal bo'ladi).
--
--  ⚠️ SECURITY INVOKER (definer EMAS — eng kam imtiyoz qoidasi). Ikkala
--     jadvalning RLS `select` policy'si `to authenticated using (true)`,
--     ya'ni chaqiruvchi o'z huquqi bilan ham hammasini ko'radi — natija
--     bir xil, lekin funksiya egasining huquqi bilan ishlamaydi.
--     `anon` ga execute berilmagan, shuning uchun tashqaridan ochiq emas.

-- ⬇⬇⬇  7-BO'LIM: SHU QATORDAN 7-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function yuk_tannarx_jami(p_ids integer[])
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(jsonb_object_agg(x.yuk_id::text,
           jsonb_build_object('jami_uzs', x.jami, 'qatorlar', x.qatorlar)), '{}'::jsonb)
    from (
      select t.yuk_id,
             sum(t.summa_uzs)::numeric as jami,
             jsonb_agg(jsonb_build_object(
               'id',        t.id,
               'sabab',     s.nom,
               'ikonka',    s.ikonka,
               'summa_uzs', t.summa_uzs,
               'izoh',      t.izoh,
               'sana',      to_char(t.created_at at time zone 'Asia/Tashkent',
                                    'YYYY-MM-DD'),
               'kim',       t.created_by_name)
               order by t.created_at, t.id) as qatorlar
        from yuk_tannarx t
        join yuk_tannarx_sabab s on s.id = t.sabab_id
       where not t.is_deleted
         and t.yuk_id = any(coalesce(p_ids, '{}'::integer[]))
       group by t.yuk_id
    ) x;
$$;

revoke all on function yuk_tannarx_jami(integer[]) from public, anon;
grant execute on function yuk_tannarx_jami(integer[]) to authenticated;

comment on function yuk_tannarx_jami(integer[]) is
  'Har yuk uchun tannarx jamisi + qatorlari (kalit = yuk_id matn). '
  'Qatori yoq yuk kalit bolmaydi. Ochirilgani kirmaydi.';
-- ⬆⬆⬆  7-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  8-BO'LIM — SABAB BOSHQARUVI  (FAQAT ADMIN)
-- #####################################################################
--  🔴 Ikkala RPC ham ADMIN-ONLY (`yuk_tannarx_admin()`), chunki sabab
--     ro'yxati — butun tizim uchun umumiy lug'at: bitta user qo'shgan
--     sabab hammaning dropdownida chiqadi, passivlashtirgani esa
--     hammadan yo'qoladi. Klient ham "Sabablar" tugmasini faqat adminga
--     ko'rsatadi (`loadRole` → `isAdmin`); UI yashirish hech qachon
--     yetarli emas — RPC to'g'ridan chaqirilishi mumkin, shuning uchun
--     to'siq server tomonda ham bor. Tannarx QO'SHISH/O'CHIRISH esa
--     admin-only EMAS — u sahifa ruxsatiga bog'liq (5/6-BO'LIM).
--
--  yuk_tannarx_sabab_qosh(p_nom text, p_ikonka text default null) → jsonb
--     IDEMPOTENT: nom bo'yicha (registrga qaramay) qidiradi. Bor bo'lsa
--     yangi qator YARATMAYDI — mavjudini qaytaradi, passiv bo'lsa QAYTA
--     FAOLLASHTIRADI va ikonka berilgan bo'lsa yangilaydi.
--     {ok:true, id, nom, ikonka, yangi:true|false}
--
--  yuk_tannarx_sabab_ochir(p_id int) → jsonb
--     is_active=false. Jadval qatori O'CHIRILMAYDI — ishlatilgan sabab
--     `yuk_tannarx.sabab_id` orqali bog'langan, uni yo'qotsa eski
--     qatorlar sababsiz qolardi. Javobda `ishlatilgan` soni ham keladi.

-- ⬇⬇⬇  8-BO'LIM: SHU QATORDAN 8-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function yuk_tannarx_sabab_qosh(p_nom text, p_ikonka text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nom   text;
  v_ik    text;
  v_id    int;
  v_yangi boolean := false;
  r       yuk_tannarx_sabab;
begin
  if not yuk_tannarx_admin() then
    return jsonb_build_object('ok', false, 'error', 'Sabab qoshish faqat admin ishi');
  end if;

  v_nom := btrim(coalesce(p_nom, ''));
  v_ik  := nullif(btrim(coalesce(p_ikonka, '')), '');

  if v_nom = '' then
    return jsonb_build_object('ok', false, 'error', 'Sabab nomi bosh');
  end if;
  if length(v_nom) > 60 then
    return jsonb_build_object('ok', false, 'error', 'Sabab nomi juda uzun (60 belgigacha)');
  end if;

  -- Registrga qaramay mavjudmi
  select * into r from yuk_tannarx_sabab where lower(nom) = lower(v_nom);

  if r.id is null then
    -- Poyga holatida (ikki klient bir vaqtda) unique indekslar to'sadi —
    -- shuning uchun do nothing + qayta o'qish
    insert into yuk_tannarx_sabab (nom, ikonka)
    values (v_nom, v_ik)
    on conflict do nothing
    returning id into v_id;

    if v_id is null then
      select id into v_id from yuk_tannarx_sabab where lower(nom) = lower(v_nom);
    else
      v_yangi := true;
    end if;
  else
    v_id := r.id;
  end if;

  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'Sabab saqlanmadi');
  end if;

  -- Passiv bo'lsa qaytadan yoqiladi, ikonka berilgan bo'lsa yangilanadi
  update yuk_tannarx_sabab
     set is_active = true,
         ikonka    = coalesce(v_ik, ikonka)
   where id = v_id;

  select * into r from yuk_tannarx_sabab where id = v_id;

  return jsonb_build_object('ok', true, 'id', r.id, 'nom', r.nom,
    'ikonka', r.ikonka, 'tartib', r.tartib, 'yangi', v_yangi);
end $$;

revoke all on function yuk_tannarx_sabab_qosh(text, text) from public, anon;
grant execute on function yuk_tannarx_sabab_qosh(text, text) to authenticated;

comment on function yuk_tannarx_sabab_qosh(text, text) is
  'Tannarx sababini qoshadi (FAQAT ADMIN, idempotent, nom unique). Passivini qayta faollashtiradi.';


create or replace function yuk_tannarx_sabab_ochir(p_id int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r   yuk_tannarx_sabab;
  v_n int;
begin
  if not yuk_tannarx_admin() then
    return jsonb_build_object('ok', false, 'error', 'Sabab passivlashtirish faqat admin ishi');
  end if;

  select * into r from yuk_tannarx_sabab where id = p_id;
  if r.id is null then
    return jsonb_build_object('ok', false, 'error', 'Sabab topilmadi');
  end if;

  select count(*) into v_n from yuk_tannarx
   where sabab_id = p_id and not is_deleted;

  if not r.is_active then
    return jsonb_build_object('ok', true, 'id', r.id, 'nom', r.nom,
      'ishlatilgan', v_n, 'ozgardi', false,
      'note', 'Bu sabab allaqachon passiv');
  end if;

  update yuk_tannarx_sabab set is_active = false where id = p_id;

  return jsonb_build_object('ok', true, 'id', r.id, 'nom', r.nom,
    'ishlatilgan', v_n, 'ozgardi', true,
    'note', 'Sabab ochirilmadi, passiv qilindi — eski qatorlar joyida qoladi');
end $$;

revoke all on function yuk_tannarx_sabab_ochir(int) from public, anon;
grant execute on function yuk_tannarx_sabab_ochir(int) to authenticated;

comment on function yuk_tannarx_sabab_ochir(int) is
  'Sababni passivlashtiradi (FAQAT ADMIN, is_active=false). Jadvaldan ochirilmaydi.';
-- ⬆⬆⬆  8-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  9-BO'LIM — TEKSHIRUVLAR.  HECH BIRI YOZMAYDI.
-- #####################################################################
--  Har `select` ni alohida belgilab RUN qiling. Hammasi ✅ bo'lsa tayyor.

-- ---------------------------------------------------------------------
-- 9.1 Jadvallar va funksiyalar joyidami
-- ---------------------------------------------------------------------
select 'yuk_tannarx_sabab jadvali' as tekshiruv,
       case when to_regclass('public.yuk_tannarx_sabab') is not null
            then '✅ OK' else '❌ YARATILMADI' end as natija
union all
select 'yuk_tannarx jadvali',
       case when to_regclass('public.yuk_tannarx') is not null
            then '✅ OK' else '❌ YARATILMADI' end
union all
select 'yuk_tannarx_ruxsat()',
       case when to_regprocedure('public.yuk_tannarx_ruxsat()') is not null
            then '✅ OK' else '❌ YARATILMADI' end
union all
select 'yuk_tannarx_admin()',
       case when to_regprocedure('public.yuk_tannarx_admin()') is not null
            then '✅ OK' else '❌ YARATILMADI' end
union all
select 'yuk_tannarx_qosh(jsonb,int,text,text)',
       case when to_regprocedure('public.yuk_tannarx_qosh(jsonb,int,text,text)') is not null
            then '✅ OK' else '❌ YARATILMADI' end
union all
select 'eski 3 argumentli qosh qolmaganmi',
       case when to_regprocedure('public.yuk_tannarx_qosh(jsonb,int,text)') is null
            then '✅ OK — bitta imzo'
            else '❌ IKKITA IMZO — klient PGRST203 (function is not unique) oladi' end
union all
select 'yuk_tannarx_ochir(bigint)',
       case when to_regprocedure('public.yuk_tannarx_ochir(bigint)') is not null
            then '✅ OK' else '❌ YARATILMADI' end
union all
select 'yuk_tannarx_jami(integer[])',
       case when to_regprocedure('public.yuk_tannarx_jami(integer[])') is not null
            then '✅ OK' else '❌ YARATILMADI' end
union all
select 'yuk_tannarx_sabab_qosh(text,text)',
       case when to_regprocedure('public.yuk_tannarx_sabab_qosh(text,text)') is not null
            then '✅ OK' else '❌ YARATILMADI' end
union all
select 'yuk_tannarx_sabab_ochir(int)',
       case when to_regprocedure('public.yuk_tannarx_sabab_ochir(int)') is not null
            then '✅ OK' else '❌ YARATILMADI' end;

-- ---------------------------------------------------------------------
-- 9.2 Seed sabablar (5 ta faol bo'lishi kerak)
-- ---------------------------------------------------------------------
select id, ikonka, nom, tartib, is_active
  from yuk_tannarx_sabab
 order by tartib, nom;

select 'Seed sabablar' as tekshiruv,
       count(*) as faol_sabab,
       case when count(*) >= 5 then '✅ OK'
            else '❌ KAM — 1-BO''LIM insert bloki RUN qilinmagan' end as natija
  from yuk_tannarx_sabab where is_active;

-- ---------------------------------------------------------------------
-- 9.3 Indekslar (jami RPC tezligi shularga bog'liq)
-- ---------------------------------------------------------------------
select indexname, indexdef
  from pg_indexes
 where schemaname = 'public'
   and tablename in ('yuk_tannarx', 'yuk_tannarx_sabab')
 order by tablename, indexname;

select 'yuk_id partial indeksi' as tekshiruv,
       case when exists (select 1 from pg_indexes
                          where schemaname = 'public'
                            and indexname = 'yuk_tannarx_yuk_idx')
            then '✅ OK' else '❌ YO''Q — jami RPC sekin ishlaydi' end as natija
union all
select 'takror himoyasi (kalit, yuk_id) unique',
       case when exists (select 1 from pg_indexes
                          where schemaname = 'public'
                            and indexname = 'yuk_tannarx_kalit_uniq')
            then '✅ OK'
            else '❌ YO''Q — ikki marta bosilsa qiymat ikki barobar oshadi' end;

-- 9.3b Yangi ustunlar (takror himoyasi va ochirish ruxsati shularga tayanadi)
select c.column_name as ustun, '✅ OK' as natija
  from information_schema.columns c
 where c.table_schema = 'public' and c.table_name = 'yuk_tannarx'
   and c.column_name in ('kalit', 'created_by')
union all
select 'kalit + created_by',
       case when (select count(*) from information_schema.columns
                   where table_schema = 'public' and table_name = 'yuk_tannarx'
                     and column_name in ('kalit', 'created_by')) = 2
            then '✅ IKKALASI BOR'
            else '❌ KAM — 2-BO''LIMni RUN qiling' end;

-- ---------------------------------------------------------------------
-- 9.4 RLS yoqilgan va YOZISH policy'si YO'Q (faqat RPC yozadi)
-- ---------------------------------------------------------------------
select c.relname as jadval,
       c.relrowsecurity as rls_yoqilgan,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as policy_soni,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname
           and p.cmd <> 'SELECT') as yozish_policy,
       case when c.relrowsecurity
             and (select count(*) from pg_policies p
                   where p.schemaname = 'public' and p.tablename = c.relname
                     and p.cmd <> 'SELECT') = 0
            then '✅ OK' else '❌ TEKSHIRING' end as natija
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relname in ('yuk_tannarx', 'yuk_tannarx_sabab')
 order by c.relname;

-- ---------------------------------------------------------------------
-- 9.5 perm_pages() — 15 kalit va 'tannarx' bor
--     🔴 ENG MUHIM TEKSHIRUV. Guard fail-closed: ro'yxatda 'tannarx'
--     bo'lmasa hech kim tannarx yoza olmaydi (sahifa faqat o'qish bo'lib
--     qoladi). Bu holat PROVODKA_PERMS.sql yoki PROVODKA_PAGES_EMPTY.sql
--     KEYIN RUN qilinganda yuz beradi — ular ro'yxatni 14 ga qaytaradi.
--     Davosi: 3-BO'LIMni QAYTA RUN qilish + 10-BO'LIM (notify pgrst).
-- ---------------------------------------------------------------------
select 'perm_pages kalitlari' as tekshiruv,
       array_length(perm_pages(), 1) as kalit_soni,
       ('tannarx' = any(perm_pages())) as tannarx_bor,
       case when array_length(perm_pages(), 1) = 15
             and 'tannarx' = any(perm_pages())
             and 'yuklar'  = any(perm_pages())
             and 'standart' = any(perm_pages())
            then '✅ OK'
            when not ('tannarx' = any(perm_pages()))
            then '❌ tannarx YOQ — guard HAMMANI TOSADI (yozib bolmaydi). 3-BOLIMni RUN qiling'
            else '❌ 15 EMAS — 3-BO''LIMni RUN qiling (yoki eski royxat ustiga yozilgan)' end as natija;

select unnest(perm_pages()) as sahifa_kaliti;

-- 9.5b Guard qanday javob beradi (o'z sessiyangiz uchun).
--      Admin bo'lsangiz `true` kutiladi; `perm_pages` da 'tannarx' bo'lmasa
--      admin uchun ham `false` chiqadi — aynan shu fail-closed xatti-harakat.
select 'yuk_tannarx_ruxsat()' as tekshiruv, yuk_tannarx_ruxsat() as natija
union all
select 'yuk_tannarx_admin()', yuk_tannarx_admin();

-- ---------------------------------------------------------------------
-- 9.6 Smoke test — bo'sh ro'yxatda jami RPC (yozmaydi)
--     Kutilgan natija: bo'sh obyekt  {}
-- ---------------------------------------------------------------------
select jsonb_pretty(yuk_tannarx_jami('{}'::integer[])) as bosh_royxat;

-- ---------------------------------------------------------------------
-- 9.7 Jonli holat — kiritilgan tannarxlar (yozgandan keyin qarash uchun)
-- ---------------------------------------------------------------------
select t.yuk_id, s.ikonka, s.nom as sabab, t.summa_uzs, t.izoh,
       t.created_by_name as kim, t.kalit,
       to_char(t.created_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI') as sana,
       t.is_deleted
  from yuk_tannarx t
  join yuk_tannarx_sabab s on s.id = t.sabab_id
 order by t.created_at desc
 limit 50;

-- ---------------------------------------------------------------------
-- 9.8 🔴 PUL HARAKATI YO'QLIGI — bu fayl balansga tegmaganini tasdiqlaydi.
--     Farq 0 bo'lishi shart (o'rnatishdan oldin ham 0 edi).
-- ---------------------------------------------------------------------
select 'Balans tengligi' as tekshiruv,
       sum(case when bolim = 'AKTIV' then amount else 0 end)
     - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end) as farq,
       case when abs(sum(case when bolim = 'AKTIV' then amount else 0 end)
                   - sum(case when bolim in ('PASSIV','KAPITAL') then amount else 0 end)) <= 0.01
            then '✅ OK — tannarx qatlami pulga tegmaydi'
            else '❌ TEKSHIRING (sababi bu fayl EMAS — u entry yozmaydi)' end as natija
  from balans(current_date);


-- #####################################################################
--  10-BO'LIM — PostgREST sxema keshini yangilash
-- #####################################################################
--  Busiz yangi RPC'lar klientdan "function not found" (PGRST202) beradi.

-- ⬇⬇⬇  10-BO'LIM  ⬇⬇⬇
notify pgrst, 'reload schema';
-- ⬆⬆⬆  10-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  11-BO'LIM — ROLLBACK (kerak bo'lsa, QO'LDA)
-- #####################################################################
--  Ataylab izohda turibdi — tasodifan RUN bo'lmasin.
--
--  ⚠️ Jadvallarni tashlashdan oldin `select count(*) from yuk_tannarx`
--     qiling: qatorlar bo'lsa, ular ham ketadi (tiklab bo'lmaydi).
--  ⚠️ perm_pages() ni qaytarish — faqat klient PAGES massivi ham
--     eskisiga qaytarilgan bo'lsa.

-- 11.1 Nima yo'qoladi (bu select xavfsiz)
-- select (select count(*) from yuk_tannarx)        as tannarx_qatorlar,
--        (select count(*) from yuk_tannarx_sabab)  as sabablar;

-- 11.2 Funksiyalarni olib tashlash
-- drop function if exists yuk_tannarx_sabab_ochir(int);
-- drop function if exists yuk_tannarx_sabab_qosh(text, text);
-- drop function if exists yuk_tannarx_jami(integer[]);
-- drop function if exists yuk_tannarx_ochir(bigint);
-- drop function if exists yuk_tannarx_qosh(jsonb, int, text, text);
-- drop function if exists yuk_tannarx_admin();
-- drop function if exists yuk_tannarx_ruxsat();

-- 11.3 Jadvallarni olib tashlash (MA'LUMOT YO'QOLADI)
-- drop table if exists yuk_tannarx;
-- drop table if exists yuk_tannarx_sabab;

-- 11.4 perm_pages() ni 14 kalitga qaytarish
-- create or replace function perm_pages()
-- returns text[]
-- language sql
-- immutable
-- as 'select array[''kassa'',''jurnal'',''professional'',''hisobot'',''balans'',''cashflow'',
--                  ''qarzdor'',''filial'',''valyuta'',''konvert'',''sozlama'',''provodka'',
--                  ''yuklar'',''standart'']::text[]';

-- 11.5 notify pgrst, 'reload schema';
