-- =====================================================================
--  ⚠️⚠️  SUPABASE SQL EDITOR — QANDAY RUN QILINADI (avval SHUNI o'qing)
-- ---------------------------------------------------------------------
--   1) Bu faylda `do` bloklari NOMLANGAN dollar-quote bilan yozilgan
--      (tekshir / sinov / ai_touch teglari bilan). Nomsiz variantni
--      Supabase SQL Editor blokni ikkiga bo'lib yuborardi
--      (PROVODKA_YUK_TANNARX saboqi). Shu sababdan IZOHLARDA dollar
--      belgisi UMUMAN YO'Q — bu faylga izoh qo'shsangiz ham dollar
--      yozmang (shu qatorning o'zida ham yo'q).
--
--   2) Har bo'lak ⬇⬇⬇ va ⬆⬆⬆ belgilari orasida. AYNAN o'sha oraliqni
--      belgilab RUN qiling. Tartib bilan: 0 → 1 → 2 → … → 7.
--
--      🔴 BUTUN FAYLNI BIRDANIGA RUN QILISH TAVSIYA ETILMAYDI: 6-BO'LIM
--      (tirik RLS sinovi) nomuvofiqlikda `raise exception` qiladi, va
--      editor butun skriptni bitta tranzaksiyada yuborsa 1–4-BO'LIMlar
--      ham QAYTIB KETADI (jadval yaratilmay qoladi). Bo'lak-bo'lak RUN
--      qilsangiz — o'rnatish o'rnida qoladi, faqat sinov qizil beradi.
--
--   3) Bo'lak diapazonlari:
--        0-BO'LIM — old shart tekshiruvi (HECH NARSA YOZMAYDI)
--        1-BO'LIM — ai_conversations jadvali + indeks + RLS yoqish
--        2-BO'LIM — ai_messages jadvali + indeks + RLS yoqish
--        3-BO'LIM — ai_touch_conversation() triggeri (updated_at)
--        4-BO'LIM — 🔴 RLS POLICY'lari + GRANT/REVOKE (eng muhim bo'lim)
--        5-BO'LIM — STATIK TEKSHIRUV (do bloki, nomuvofiqlikda exception)
--        6-BO'LIM — 🔴 TIRIK RLS SINOVI (ikki foydalanuvchi, o'zi tozalaydi)
--        7-BO'LIM — notify pgrst (PostgREST sxema keshini yangilash)
--        8-BO'LIM — ROLLBACK (izohda, qo'lda ishlatiladi)
--        9-BO'LIM — MIJOZ TOMONI UCHUN SHARTNOMA (faqat izoh)
--
--   4) 🔴 SQL ni ASILBEK o'zi RUN qiladi. Agent bajarmaydi.
-- =====================================================================

-- =====================================================================
--  PROVODKA_AI_CHAT.sql
--  AI yordamchi — SUHBAT TARIXI (3-bosqich, 2-ish)
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo). TaskFix EMAS.
--
--  #####  NIMA QILADI  #################################################
--
--  Hozir `ai-dev.html` chat tarixini FAQAT XOTIRADA saqlaydi — sahifa
--  yopilsa hammasi yo'qoladi. Bu fayl uni bazaga ko'chiradi:
--
--     ai_conversations  — suhbatlar (yon paneldagi ro'yxat)
--     ai_messages       — xabarlar (user / assistant)
--
--  ChatGPT / Claude naqshi: chapda eski suhbatlar, "+" bilan yangisi,
--  eskisini ochib davom ettirish mumkin.
--
--  #####  🔴 XAVFSIZLIK — BOSHQA USERNING SUHBATI SIZMASIN  ############
--
--  Ikkala jadvalda ham RLS YOQILGAN va har biriga 4 tadan policy bor
--  (select / insert / update / delete), hammasi `user_id = auth.uid()`.
--  `ai_messages` da qo'shimcha qorovul: xabar yozilayotgan suhbat ham
--  o'zimniki bo'lishi SHART (insert/update `with check` ichidagi
--  `exists (... ai_conversations ...)`). Ya'ni `user_id` ni to'g'ri
--  qo'yish YETARLI EMAS — begona suhbatga xabar qo'shib bo'lmaydi.
--  6-BO'LIM buni TIRIK sinaydi (ikki xil auth.uid() ostida).
--
--  #####  🔴 PUL HARAKATI YO'Q  ########################################
--
--  Bu fayl `entry` / `entry_line` ga umuman tegmaydi: balans, P&L,
--  cashflow raqamlari O'ZGARMAYDI. Dt=Kt triggeri ham, `trg_perm_guard_
--  entry_line` guardi ham bu yerda ishtirok etmaydi (satr yozilmaydi).
--
--  #####  ADDITIVE  ####################################################
--
--  Mavjud jadval / ustun / view / funksiya / policy O'ZGARTIRILMAYDI.
--  Faqat YANGI obyektlar:
--     jadval    ai_conversations, ai_messages
--     funksiya  ai_touch_conversation()   (trigger funksiyasi)
--     trigger   ai_messages_touch_trg
--     indeks    ai_conversations_user_idx, ai_messages_conv_idx
--     policy    8 ta (4 + 4), nomlari `ai_` bilan boshlanadi
--  `perm_pages()` ga TEGILMAYDI — 'ai' kaliti allaqachon
--  PROVODKA_AI_AGENT.sql da qo'shilgan.
--
--  Idempotent: `create table if not exists`, `create index if not exists`,
--  `drop policy if exists` + `create policy`, `create or replace function`.
--  Qayta RUN qilish xavfsiz, ma'lumot yo'qolmaydi.
--
--  #####  "HECH NARSA O'CHIRILMAYDI" (CLAUDE.md)  ######################
--
--  `ai_conversations.is_deleted` — soft-delete. Mijoz o'chirganda qator
--  bazadan ketmaydi, faqat `is_deleted = true` bo'ladi va yon panel
--  ro'yxatidan chiqib qoladi. Xabarlar ham joyida qoladi.
--
--  TALAB: PROVODKA_AI_AGENT.sql (perm_pages ga 'ai') — bu fayl uchun
--         SHART EMAS, lekin sahifaning o'zi busiz ochilmaydi.
-- =====================================================================


-- #####################################################################
--  0-BO'LIM — OLD SHART TEKSHIRUVI.  HECH NARSA YOZMAYDI.
-- #####################################################################

-- ⬇⬇⬇  0-BO'LIM  ⬇⬇⬇
-- 0.1 Zarur asoslar
select 'auth.users jadvali' as tekshiruv,
       case when to_regclass('auth.users') is not null
            then '✅ BOR — user_id shunga boglanadi'
            else '❌ YO''Q — bu Supabase bazasi emasmi?' end as natija
union all
select 'auth.uid() funksiyasi',
       case when to_regprocedure('auth.uid()') is not null
            then '✅ BOR — RLS va DEFAULT shunga tayanadi'
            else '❌ YO''Q — RLS ishlamaydi' end
union all
select 'gen_random_uuid()',
       case when to_regprocedure('gen_random_uuid()') is not null
            then '✅ BOR — id defaulti'
            else '❌ YO''Q — create extension pgcrypto kerak' end
union all
-- ⚠️ perm_pages() ATAYLAB CHAQIRILMAYDI — funksiya yo'q bazada `case`
--    shoxi baribir rejalashtiriladi va butun select "function does not
--    exist" bilan yiqilardi. Shuning uchun manba matni tekshiriladi.
select 'perm_pages() da ai kaliti',
       case when to_regprocedure('public.perm_pages()') is null
            then '⚠️ perm_pages() YO''Q — PROVODKA_PERMS.sql RUN qilinmagan'
            when exists (select 1 from pg_proc
                          where oid = to_regprocedure('public.perm_pages()')::oid
                            and prosrc like '%''ai''%')
            then '✅ BOR — AI sahifasi ruxsat tizimida'
            else '⚠️ YO''Q — PROVODKA_AI_AGENT.sql ni RUN qiling (bu fayl baribir ishlaydi)' end;

-- 0.2 Bu fayl ilgari RUN qilinganmi (bo'sh natija = yangi o'rnatish)
select 'ai_conversations' as obyekt,
       case when to_regclass('public.ai_conversations') is not null
            then 'allaqachon bor' else 'yo''q (yangi yaratiladi)' end as holat
union all
select 'ai_messages',
       case when to_regclass('public.ai_messages') is not null
            then 'allaqachon bor' else 'yo''q (yangi yaratiladi)' end;
-- ⬆⬆⬆  0-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  1-BO'LIM — ai_conversations — suhbatlar (yon panel ro'yxati)
-- #####################################################################
--  `user_id` DEFAULT `auth.uid()`:
--     • mijoz uni UMUMAN YUBORMAYDI — o'zi to'ladi;
--     • qo'lda boshqa odamning id'si yuborilsa insert policy
--       (`with check user_id = auth.uid()`) uni TO'SADI — ya'ni default
--       qulaylik uchun, himoya esa policy'da (6-BO'LIM tirik sinaydi);
--     • ⚠️ service_role / SQL editor'dan yozilganda `auth.uid()` NULL
--       bo'ladi va `not null` xato beradi — server tomondan yozilsa
--       `user_id` ANIQ berilishi kerak. Edge Function esa foydalanuvchi
--       JWT'si bilan ishlaydi (CLAUDE.md), ya'ni default to'g'ri to'ladi.
--
--  `on delete cascade` — foydalanuvchi auth'dan o'chirilsa suhbatlari
--  ham ketadi (yetim qator qolmasin). Bu "hech narsa o'chirilmaydi"
--  qoidasiga zid emas: u pul yozuvlari (entry) haqida.
--
--  `is_deleted` — mijoz "o'chirdi" degani. Qator joyida qoladi.
--
--  🔴 `updated_at` — yon panel tartibi (oxirgi suhbat tepada).
--     Xabar qo'shilganda TRIGGER yangilaydi (3-BO'LIM). Sarlavha
--     o'zgartirilganda esa mijoz o'zi `updated_at` yozadi (trigger
--     faqat `ai_messages` insert'ida ishlaydi — 9-BO'LIM shartnomasi).

-- ⬇⬇⬇  1-BO'LIM: SHU QATORDAN 1-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create table if not exists ai_conversations (
  id         uuid        primary key default gen_random_uuid(),
  user_id    uuid        not null default auth.uid()
                         references auth.users(id) on delete cascade,
  title      text        not null default 'Yangi suhbat'
                         check (char_length(title) <= 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  is_deleted boolean     not null default false
);

comment on table ai_conversations is
  'AI chat suhbatlari (ai-dev.html yon paneli). Har user FAQAT ozinikini koradi (RLS). '
  'Ochirish = is_deleted true, qator bazadan ketmaydi.';
comment on column ai_conversations.user_id is
  'Egasi. DEFAULT auth.uid() — mijoz yubormaydi. Begona qiymat insert policy bilan tosiladi.';
comment on column ai_conversations.title is
  'Sarlavha (max 200 belgi). Birinchi savoldan avtomat yasaladi, keyin tahrirlanishi mumkin.';
comment on column ai_conversations.updated_at is
  'Yon panel tartibi (yangisi tepada). Xabar qoshilganda ai_touch_conversation triggeri yangilaydi.';
comment on column ai_conversations.is_deleted is
  'Soft-delete (CLAUDE.md: hech narsa ochirilmaydi). Royxatda korinmaydi, bazada qoladi.';

-- ⭐ Yon panel so'rovi aynan shu indeksdan o'qiydi:
--    where user_id = auth.uid() and not is_deleted order by updated_at desc
--    (is_deleted — arzon qayta tekshiruv, ustun ro'yxatga kirmaydi)
create index if not exists ai_conversations_user_idx
  on ai_conversations (user_id, updated_at desc);

-- RLS DARROV yoqiladi. Policy'lar 4-BO'LIMda — ya'ni 1-BO'LIM yolg'iz
-- RUN qilinsa jadval HAMMAGA YOPIQ bo'lib qoladi (xavfsiz nosozlik),
-- ochiq emas.
alter table ai_conversations enable row level security;
-- ⬆⬆⬆  1-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  2-BO'LIM — ai_messages — xabarlar
-- #####################################################################
--  🔴 `user_id` ATAYLAB TAKRORLANADI (denormalizatsiya). Sababi: RLS
--     `ai_conversations` ga JOIN qilmasdan ishlaydi — har qator uchun
--     subquery emas, oddiy ustun solishtiruvi. Tez va sodda.
--     Ikkalasi MOS kelishi `insert`/`update` policy'sidagi `exists`
--     qorovuli bilan kafolatlanadi (4-BO'LIM) — alohida trigger kerak
--     emas, chunki qorovul yozuv yo'lining YAGONA darvozasi.
--
--  `role` — TEXT + CHECK, ENUM EMAS (CLAUDE.md qoidasi: ENUM ga yangi
--  qiymat qo'shish prod'da og'riqli). Kelajakda 'system' kerak bo'lsa
--  CHECK ni `create or replace` emas, `alter table ... drop constraint`
--  + yangi CHECK bilan qo'shiladi (additive qadam).
--
--  `content` — 1..200000 belgi. Bo'sh xabar yozilmaydi; yuqori chegara
--  EF limiti (20000 belgi) dan ancha katta — bu faqat "portlab ketmasin"
--  qorovuli.
--
--  `sources` — web_search manbalari (1-ish qaytaradi), jsonb, NULL
--  bo'lishi mumkin (eski xabarlar va user xabarlari). Shakli mijoz
--  bilan shartnoma: [{"title":"...","url":"..."}].
--
--  `model` — javob bergan model ('claude-sonnet-5'), NULL bo'lishi
--  mumkin. Kelajakda model almashsa eski javoblar qaysi model ekani
--  bilinib turadi.
--
--  `on delete cascade` — suhbat HAQIQATAN o'chirilsa (masalan user
--  auth'dan o'chdi) xabarlar ham ketadi. Oddiy "o'chirish" esa
--  `is_deleted` bilan bo'ladi va bu cascade umuman ishlamaydi.

-- ⬇⬇⬇  2-BO'LIM: SHU QATORDAN 2-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create table if not exists ai_messages (
  id              uuid        primary key default gen_random_uuid(),
  conversation_id uuid        not null
                              references ai_conversations(id) on delete cascade,
  user_id         uuid        not null default auth.uid(),
  role            text        not null check (role in ('user','assistant')),
  content         text        not null
                              check (char_length(content) between 1 and 200000),
  sources         jsonb,
  model           text,
  created_at      timestamptz not null default now()
);

comment on table ai_messages is
  'AI chat xabarlari. RLS user_id boyicha (ai_conversations ga JOIN qilmasdan). '
  'Begona suhbatga yozib bolmaydi — insert policy ichidagi exists qorovuli.';
comment on column ai_messages.user_id is
  'Egasi. ai_conversations.user_id bilan MOS bolishi policy exists qorovuli bilan kafolatlanadi. '
  'JOIN siz RLS uchun ataylab takrorlangan.';
comment on column ai_messages.role is
  'user yoki assistant. TEXT + CHECK (ENUM emas — CLAUDE.md).';
comment on column ai_messages.content is
  'Xabar matni, 1..200000 belgi. EF limiti bundan ancha kichik.';
comment on column ai_messages.sources is
  'web_search manbalari: [{"title":"...","url":"..."}]. NULL bolishi mumkin.';
comment on column ai_messages.model is
  'Javob bergan model (masalan claude-sonnet-5). User xabarida NULL.';

-- ⭐ Suhbatni ochish so'rovi:
--    where conversation_id = ... order by created_at
create index if not exists ai_messages_conv_idx
  on ai_messages (conversation_id, created_at);

alter table ai_messages enable row level security;
-- ⬆⬆⬆  2-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  3-BO'LIM — ai_touch_conversation() — updated_at triggeri
-- #####################################################################
--  Yon panelda oxirgi yozilgan suhbat TEPADA tursin: `ai_messages` ga
--  insert bo'lganda ota `ai_conversations.updated_at = now()`.
--
--  🔴 SECURITY DEFINER EMAS — ataylab. Funksiya faqat CHAQIRUVCHINING
--     O'Z qatorini yangilaydi, ya'ni `ai_conversations` UPDATE policy'si
--     (`user_id = auth.uid()`) uni bemalol o'tkazadi. `definer` qilinsa
--     RLS chetlab o'tilardi va begona suhbatning `updated_at` ini
--     o'zgartirish yo'li ochilardi (xabarni yozib bo'lmasa ham, "bu
--     suhbat bor" degan signal sizardi).
--
--  `updated_at < now()` sharti: bitta tranzaksiyada bir necha xabar
--  yozilganda (savol + javob) ota qator ikki marta yangilanmasin —
--  `now()` tranzaksiya boshlanish vaqti, ya'ni ikkinchisida qiymat
--  allaqachon to'g'ri turadi.
--
--  RLS tufayli begona qator TOPILMAYDI va update jimgina 0 qator
--  qaytaradi — xato bermaydi, oqim buzilmaydi.
--
--  ⚠️ Funksiyaga alohida GRANT/REVOKE berilmaydi: `returns trigger`
--     turidagi funksiyani PostgREST ham, oddiy SQL ham to'g'ridan
--     chaqira olmaydi ("trigger functions can only be called as
--     triggers"), ya'ni tashqi yuza yo'q.

-- ⬇⬇⬇  3-BO'LIM: SHU QATORDAN 3-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
create or replace function ai_touch_conversation()
returns trigger
language plpgsql
set search_path = public
as $ai_touch$
begin
  update ai_conversations
     set updated_at = now()
   where id = new.conversation_id
     and updated_at < now();
  return null;                       -- after trigger: qaytish qiymati ishlatilmaydi
end
$ai_touch$;

comment on function ai_touch_conversation() is
  'ai_messages insertida ota ai_conversations.updated_at ni now() ga suradi (yon panel tartibi). '
  'SECURITY INVOKER — ozgalar qatoriga tegmaydi (RLS otkazmaydi).';

drop trigger if exists ai_messages_touch_trg on ai_messages;
create trigger ai_messages_touch_trg
  after insert on ai_messages
  for each row execute function ai_touch_conversation();
-- ⬆⬆⬆  3-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  4-BO'LIM — 🔴 RLS POLICY'LARI + GRANT / REVOKE  (ENG MUHIM BO'LIM)
-- #####################################################################
--  HAR JADVALGA 4 TA POLICY: select / insert / update / delete.
--  Hammasi bitta shartga tayanadi: `user_id = (select auth.uid())`.
--
--  ⚠️ NEGA `(select auth.uid())` VA YALANG'OCH `auth.uid()` EMAS:
--     yalang'och chaqiruv har QATOR uchun qayta hisoblanadi, `select`
--     bilan o'ralgani esa BIR MARTA (InitPlan) — PROVODKA_SCALE /
--     Supabase tavsiya qilgan naqsh. Xavfsizlik bir xil, tezlik boshqa.
--
--  ⚠️ REKURSIYA YO'Q: `ai_conversations` policy'lari `ai_messages` ga
--     UMUMAN murojaat qilmaydi (faqat teskarisi: ai_messages →
--     ai_conversations). Ikki tomonlama bo'lsa 42P17 (infinite
--     recursion in policy) chiqardi — TaskFix'dagi mashhur xato.
--
--  ⚠️ `ai_messages` policy'si ichidagi `exists` subquery'si
--     `ai_conversations` RLS'ini ham hisobga oladi (policy ichidan qilingan so'rov
--     RLS'dan ozod EMAS) — ya'ni qorovul ikki qavat: subquery begona
--     suhbatni ko'rmaydi ham, `c.user_id = auth.uid()` sharti ham bor.
--     Ikkinchisi ataylab yozilgan: kelajakda SELECT policy kengaysa
--     (masalan "admin hammasini ko'rsin") yozuv darvozasi ochilib
--     ketmasin.
--
--  ⚠️ SELECT policy'da `is_deleted` FILTRI YO'Q — ataylab. Policy —
--     EGALIK chegarasi, ko'rinish esa mijoz ishi (`.eq('is_deleted',
--     false)`). Aks holda "o'chirilgan"ni qaytarib bo'lmasdi.
--
--  ⚠️ `anon` ga HECH NARSA berilmaydi. `service_role` esa Supabase'da
--     `bypassrls` — u bilan yozsangiz RLS UMUMAN ishlamaydi, shuning
--     uchun Edge Function foydalanuvchi JWT'si bilan ishlashi SHART
--     (CLAUDE.md, 2-bosqich qarori).

-- ⬇⬇⬇  4-BO'LIM: SHU QATORDAN 4-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇

-- ---------- ai_conversations: 4 policy ----------
drop policy if exists ai_conversations_sel on ai_conversations;
create policy ai_conversations_sel on ai_conversations
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists ai_conversations_ins on ai_conversations;
create policy ai_conversations_ins on ai_conversations
  for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists ai_conversations_upd on ai_conversations;
create policy ai_conversations_upd on ai_conversations
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));   -- egasini almashtirib bolmaydi

drop policy if exists ai_conversations_del on ai_conversations;
create policy ai_conversations_del on ai_conversations
  for delete to authenticated
  using (user_id = (select auth.uid()));

-- ---------- ai_messages: 4 policy ----------
drop policy if exists ai_messages_sel on ai_messages;
create policy ai_messages_sel on ai_messages
  for select to authenticated
  using (user_id = (select auth.uid()));

-- 🔴 QO'SHIMCHA KAFOLAT: suhbat ham o'zimniki bo'lsin.
--    Faqat `user_id = auth.uid()` bo'lsa, begona suhbatning id'sini
--    bilgan odam u yerga xabar YOZIB QO'YA olardi (o'qiy olmasa ham —
--    keyin egasi o'sha xabarni ko'rmasdi, chunki user_id boshqa, lekin
--    trigger orqali `updated_at` siljirdi va yon panel "yangilandi" deb
--    turaverardi). Endi bu yo'l butunlay yopiq.
drop policy if exists ai_messages_ins on ai_messages;
create policy ai_messages_ins on ai_messages
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from ai_conversations c
       where c.id = conversation_id
         and c.user_id = (select auth.uid())
    )
  );

drop policy if exists ai_messages_upd on ai_messages;
create policy ai_messages_upd on ai_messages
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from ai_conversations c
       where c.id = conversation_id
         and c.user_id = (select auth.uid())
    )
  );

drop policy if exists ai_messages_del on ai_messages;
create policy ai_messages_del on ai_messages
  for delete to authenticated
  using (user_id = (select auth.uid()));

-- ---------- Huquqlar ----------
revoke all on table ai_conversations from public, anon;
revoke all on table ai_messages      from public, anon;

grant select, insert, update, delete on table ai_conversations to authenticated;
grant select, insert, update, delete on table ai_messages      to authenticated;
-- ⬆⬆⬆  4-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  5-BO'LIM — STATIK TEKSHIRUV.  HECH NARSA YOZMAYDI.
-- #####################################################################
--  🔴 Nomuvofiqlik JIMGINA O'TMAYDI — `raise exception` bilan to'xtaydi.
--  Tekshiriladi:
--     1) ikkala jadval bor;
--     2) RLS YOQILGAN (pg_class.relrowsecurity);
--     3) har jadvalda AYNAN 4 ta policy va 4 xil cmd;
--     4) `anon` da hech qanday huquq yo'q;
--     5) ai_messages INSERT policy matnida `exists` qorovuli bor;
--     6) trigger o'rnatilgan;
--     7) (ogohlantirish) policy'lar `(select auth.uid())` naqshida.

-- ⬇⬇⬇  5-BO'LIM: SHU QATORDAN 5-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
do $tekshir$
declare
  v_n     int;
  v_chk   text;
  t       text;
begin
  -- 5.1 Jadvallar
  foreach t in array array['ai_conversations','ai_messages'] loop
    if to_regclass('public.' || t) is null then
      raise exception 'Jadval YARATILMADI: % — 1/2-BOLIMni RUN qiling', t;
    end if;

    -- 5.2 RLS yoqilganmi (pg_class.relrowsecurity)
    if not exists (select 1 from pg_class c
                     join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public' and c.relname = t
                      and c.relrowsecurity) then
      raise exception 'RLS YOQILMAGAN: % — begona user hamma suhbatni korardi!', t;
    end if;

    -- 5.3 Policy soni va turlari
    select count(*) into v_n
      from pg_policies where schemaname = 'public' and tablename = t;
    if v_n <> 4 then
      raise exception '% jadvalida % ta policy bor, 4 kutilgandi (select/insert/update/delete)',
        t, v_n;
    end if;

    select count(distinct cmd) into v_n
      from pg_policies
     where schemaname = 'public' and tablename = t
       and cmd in ('SELECT','INSERT','UPDATE','DELETE');
    if v_n <> 4 then
      raise exception '% jadvalida 4 xil cmd yoq (select/insert/update/delete), topildi: %', t, v_n;
    end if;

    -- 5.4 anon da huquq qolmaganmi
    if exists (select 1 from pg_roles where rolname = 'anon') then
      if has_table_privilege('anon', 'public.' || t, 'select,insert,update,delete') then
        raise exception 'anon roli % jadvaliga huquqli — REVOKE ishlamagan!', t;
      end if;
    end if;
  end loop;

  -- 5.5 🔴 ai_messages insert policy'sida exists qorovuli
  select with_check into v_chk
    from pg_policies
   where schemaname = 'public' and tablename = 'ai_messages' and cmd = 'INSERT'
   limit 1;

  if v_chk is null then
    raise exception 'ai_messages INSERT policy topilmadi';
  end if;
  if position('exists' in lower(v_chk)) = 0
     or position('ai_conversations' in lower(v_chk)) = 0 then
    raise exception
      'ai_messages INSERT policy da exists(ai_conversations ...) qorovuli YOQ — begona suhbatga xabar yozish mumkin! Joriy matn: %',
      v_chk;
  end if;

  -- 5.6 Trigger
  if not exists (select 1 from pg_trigger
                  where tgname = 'ai_messages_touch_trg' and not tgisinternal) then
    raise exception 'ai_messages_touch_trg triggeri yoq — updated_at yangilanmaydi (yon panel tartibi buziladi)';
  end if;

  -- 5.7 Tezlik naqshi (ogohlantirish — xavfsizlikka tegishli emas)
  select count(*) into v_n
    from pg_policies
   where schemaname = 'public'
     and tablename in ('ai_conversations','ai_messages')
     and position('select auth.uid()' in lower(coalesce(qual, '') || ' ' || coalesce(with_check, ''))) = 0;
  if v_n > 0 then
    raise notice 'DIQQAT: % ta policy da (select auth.uid()) naqshi korinmadi — xavfsiz, lekin sekinroq', v_n;
  end if;

  raise notice '✅ STATIK TEKSHIRUV OK — 2 jadval, RLS yoqilgan, 8 policy, exists qorovuli va trigger joyida';
end
$tekshir$;

-- 5.8 Ko'z bilan ko'rish uchun (yozmaydi)
select c.relname as jadval,
       c.relrowsecurity as rls_yoqilgan,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as policy_soni,
       case when c.relrowsecurity
             and (select count(*) from pg_policies p
                   where p.schemaname = 'public' and p.tablename = c.relname) = 4
            then '✅ OK' else '❌ TEKSHIRING' end as natija
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relname in ('ai_conversations','ai_messages')
 order by c.relname;

select tablename as jadval, policyname as policy_nomi, cmd, roles::text as rollar,
       coalesce(qual, '—') as using_sharti,
       coalesce(with_check, '—') as with_check_sharti
  from pg_policies
 where schemaname = 'public'
   and tablename in ('ai_conversations','ai_messages')
 order by tablename, cmd, policyname;
-- ⬆⬆⬆  5-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  6-BO'LIM — 🔴 TIRIK RLS SINOVI (ikki foydalanuvchi)
-- #####################################################################
--  Statik tekshiruv "policy BOR" deydi, bu bo'lim esa "policy ISHLAYDI"
--  deb ISBOTLAYDI. Ikki HAQIQIY auth.users id'si olinadi (A va B),
--  `set local role authenticated` + `request.jwt.claims` bilan navbatma-
--  navbat "kirib", quyidagilar sinaladi:
--
--     A: suhbat + 2 xabar yaratadi, updated_at triggeri ishlaydi
--     B: o'sha suhbatni KO'RA OLMAYDI      (select)
--     B: xabarlarini KO'RA OLMAYDI         (select)
--     B: sarlavhasini O'ZGARTIRA OLMAYDI   (update — 0 qator)
--     B: O'CHIRA OLMAYDI                   (delete — 0 qator)
--     B: unga XABAR YOZA OLMAYDI           (insert — exists qorovuli)
--     B: A nomiga suhbat YARATA OLMAYDI    (insert — with check)
--     A: hammasi joyida, sarlavha o'zgarmagan
--
--  ⚠️ SINOV O'ZIDAN KEYIN TOZALAYDI: yaratgan qatorlarini (title
--     'SINOV RLS%') o'chiradi. Nomuvofiqlik topilsa `raise exception`
--     qiladi — u holda TRANZAKSIYA butunlay qaytadi va sinov qatorlari
--     baribir qolmaydi.
--
--  ⚠️ AGAR `set role authenticated` ga huquq bo'lmasa (yoki bazada 2 ta
--     foydalanuvchi bo'lmasa) — sinov O'TKAZIB YUBORILADI (`raise
--     notice`), o'rnatish buzilmaydi. Bunday holatda 6.2 dagi QO'LDA
--     tekshirish SQL'ini ishlating.
--
--  ⚠️ Sinov HECH QANDAY mavjud ma'lumotga tegmaydi: faqat o'zi yaratgan
--     ai_conversations / ai_messages qatorlari bilan ishlaydi.

-- ⬇⬇⬇  6-BO'LIM: SHU QATORDAN 6-BO'LIM oxirigacha BELGILANG  ⬇⬇⬇
do $sinov$
declare
  v_a      uuid;
  v_b      uuid;
  v_conv   uuid;
  v_n      int;
  v_txt    text;
  v_upd    timestamptz;
  v_ok     boolean := true;
  v_xato   text[] := array[]::text[];
begin
  -- --- 6.0 Rol almashtira olamizmi (SQL editor huquqi) ---
  begin
    execute 'set local role authenticated';
    execute 'reset role';
  exception when others then
    v_ok := false;
  end;

  if not v_ok then
    raise notice '⚠️ TIRIK SINOV OTKAZIB YUBORILDI: authenticated roliga otib bolmadi.';
    raise notice '   6.2 dagi QOLDA tekshirish SQL ini ishlating.';
    return;
  end if;

  -- --- 6.0b Ikki foydalanuvchi (postgres huquqi bilan o'qiladi) ---
  select id into v_a from auth.users order by created_at nulls last, id limit 1;
  select id into v_b from auth.users where id is distinct from v_a
   order by created_at nulls last, id limit 1;

  if v_a is null or v_b is null then
    raise notice '⚠️ TIRIK SINOV OTKAZIB YUBORILDI: auth.users da kamida 2 ta foydalanuvchi kerak.';
    raise notice '   6.2 dagi QOLDA tekshirish SQL ini ishlating.';
    return;
  end if;

  -- =================== A BO'LIB KIRISH ===================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- user_id ATAYLAB berilmaydi — default auth.uid() to'ldirsin
  insert into ai_conversations (title) values ('SINOV RLS A')
    returning id into v_conv;

  insert into ai_messages (conversation_id, role, content)
    values (v_conv, 'user', 'sinov savoli');

  -- Trigger sinovi: updated_at ni orqaga surib, yangi xabar qo'shamiz
  update ai_conversations set updated_at = now() - interval '1 day'
   where id = v_conv;

  insert into ai_messages (conversation_id, role, content, model)
    values (v_conv, 'assistant', 'sinov javobi', 'claude-sonnet-5');

  select updated_at into v_upd from ai_conversations where id = v_conv;
  if v_upd < now() - interval '1 minute' then
    v_xato := v_xato || 'ai_touch_conversation triggeri ISHLAMADI (updated_at yangilanmadi)';
  end if;

  -- =================== B BO'LIB KIRISH ===================
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_b::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- 6.1a SELECT sizmasin
  select count(*) into v_n from ai_conversations where id = v_conv;
  if v_n <> 0 then
    v_xato := v_xato || 'B begona SUHBATNI KORDI (select sizdi)';
  end if;

  select count(*) into v_n from ai_messages where conversation_id = v_conv;
  if v_n <> 0 then
    v_xato := v_xato || 'B begona XABARLARNI KORDI (select sizdi)';
  end if;

  -- 6.1b UPDATE sizmasin
  update ai_conversations set title = 'BUZILDI' where id = v_conv;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    v_xato := v_xato || 'B begona suhbat sarlavhasini OZGARTIRDI (update sizdi)';
  end if;

  -- 6.1c DELETE sizmasin
  delete from ai_conversations where id = v_conv;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    v_xato := v_xato || 'B begona suhbatni OCHIRDI (delete sizdi)';
  end if;

  -- 6.1d Begona suhbatga XABAR yozib bo'lmasin (exists qorovuli)
  begin
    insert into ai_messages (conversation_id, role, content)
      values (v_conv, 'user', 'begona xabar');
    v_xato := v_xato || 'B begona suhbatga XABAR YOZDI (exists qorovuli sizdi)';
  exception when others then
    if sqlstate <> '42501' then
      raise notice 'INFO: begona insert 42501 emas, % (%) bilan tosildi — natija bir xil', sqlerrm, sqlstate;
    end if;
  end;

  -- 6.1e Boshqa odam nomiga suhbat yaratib bo'lmasin (with check)
  begin
    insert into ai_conversations (user_id, title) values (v_a, 'SINOV RLS B-hack');
    v_xato := v_xato || 'B BOSHQA USER NOMIGA suhbat yaratdi (insert with check sizdi)';
  exception when others then
    if sqlstate <> '42501' then
      raise notice 'INFO: begona user_id insert 42501 emas, % (%) bilan tosildi', sqlerrm, sqlstate;
    end if;
  end;

  -- =================== YANA A ===================
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  select count(*), max(title) into v_n, v_txt
    from ai_conversations where id = v_conv;
  if v_n <> 1 then
    v_xato := v_xato || 'A OZ suhbatini KORMADI (select policy juda qattiq)';
  end if;
  if v_txt is distinct from 'SINOV RLS A' then
    v_xato := v_xato || 'A ning sarlavhasi OZGARIB KETGAN: ' || coalesce(v_txt, 'null');
  end if;

  select count(*) into v_n from ai_messages where conversation_id = v_conv;
  if v_n <> 2 then
    v_xato := v_xato || ('A oz xabarlarini kormadi — kutilgan 2, keldi ' || v_n);
  end if;

  -- =================== TOZALASH (jadval egasi huquqi bilan) ===================
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  delete from ai_conversations where title like 'SINOV RLS%';   -- xabarlar cascade bilan

  -- =================== HUKM ===================
  if array_length(v_xato, 1) is not null then
    raise exception '🔴 RLS SINOVI YIQILDI: %', array_to_string(v_xato, ' | ');
  end if;

  raise notice '✅ TIRIK RLS SINOVI OK — begona user KORMADI / OZGARTIRMADI / OCHIRMADI / YOZMADI.';
  raise notice '   Sinov qatorlari tozalandi (title SINOV RLS%%).';
end
$sinov$;

-- 6.1f Sinovdan keyin hech narsa qolmaganini tasdiqlash (yozmaydi)
select 'Sinov qoldigi' as tekshiruv,
       count(*) as qator,
       case when count(*) = 0 then '✅ TOZA' else '❌ QOLDI — qolda ochiring' end as natija
  from ai_conversations where title like 'SINOV RLS%';
-- ⬆⬆⬆  6-BO'LIM shu yerda tugadi  ⬆⬆⬆

-- ---------------------------------------------------------------------
--  6.2 — QO'LDA TEKSHIRISH (agar 6-BO'LIM o'tkazib yuborilgan bo'lsa)
-- ---------------------------------------------------------------------
--  Sabab: Supabase SQL Editor ba'zi loyihalarda `set role authenticated`
--  ga ruxsat bermasligi mumkin (editor roli `authenticated` a'zosi
--  bo'lmasa), yoki bazada atigi bitta foydalanuvchi bor.
--
--  Eng ishonchli qo'lda usul — ILOVADAN: ikki xil brauzer profilida
--  ikki xil user bilan `ai-dev.html` ni oching, biri suhbat yaratsin,
--  ikkinchisi Network panelida uning `id` sini qo'lga olib
--  `sb.from('ai_messages').select().eq('conversation_id', <begona id>)`
--  qilib ko'rsin — natija BO'SH massiv bo'lishi shart (xato ham emas,
--  ma'lumot ham emas: RLS shunday ishlaydi).
--
--  SQL bilan (id larni qo'yib, ALOHIDA-ALOHIDA ishga tushiring):
--
--  begin;
--    -- avval claims, keyin rol (tartib shunday bo'lsin)
--    set local request.jwt.claims = '{"sub":"<A-USER-UUID>","role":"authenticated"}';
--    set local role authenticated;
--    insert into ai_conversations (title) values ('SINOV RLS A') returning id;
--    -- yuqoridagi id ni <CONV-ID> ga qo'ying
--    reset role;
--    set local request.jwt.claims = '{"sub":"<B-USER-UUID>","role":"authenticated"}';
--    set local role authenticated;
--    select count(*) as korinadimi from ai_conversations where id = '<CONV-ID>';  -- 0 bolishi SHART
--    update ai_conversations set title = 'BUZILDI' where id = '<CONV-ID>';        -- 0 qator
--    insert into ai_messages (conversation_id, role, content)
--      values ('<CONV-ID>', 'user', 'begona');                                    -- 42501 XATO berishi SHART
--  rollback;
--
--  ⚠️ Oxirida ROLLBACK — sinov qatorlari bazada qolmasin.


-- #####################################################################
--  7-BO'LIM — PostgREST sxema keshini yangilash
-- #####################################################################
--  Busiz yangi jadvallar klientdan "relation does not exist" (PGRST205)
--  beradi.

-- ⬇⬇⬇  7-BO'LIM  ⬇⬇⬇
notify pgrst, 'reload schema';
-- ⬆⬆⬆  7-BO'LIM shu yerda tugadi  ⬆⬆⬆


-- #####################################################################
--  8-BO'LIM — ROLLBACK (kerak bo'lsa, QO'LDA)
-- #####################################################################
--  Ataylab izohda turibdi — tasodifan RUN bo'lmasin.
--  TARTIB MUHIM: policy → trigger → funksiya → jadval (bola avval).
--
--  ⚠️ Jadvallarni tashlashdan oldin 8.1 ni ishlating: qatorlar bo'lsa
--     BUTUN SUHBAT TARIXI yo'qoladi (tiklab bo'lmaydi).
--  ⚠️ Bu fayl boshqa hech narsaga tegmagani uchun rollback ham hech
--     qanday mavjud funksiyani qaytarmaydi (perm_pages tegilmagan).

-- 8.1 Nima yo'qoladi (bu select xavfsiz)
-- select (select count(*) from ai_conversations) as suhbatlar,
--        (select count(*) from ai_messages)      as xabarlar;

-- 8.2 Policy'larni olib tashlash
-- drop policy if exists ai_messages_del      on ai_messages;
-- drop policy if exists ai_messages_upd      on ai_messages;
-- drop policy if exists ai_messages_ins      on ai_messages;
-- drop policy if exists ai_messages_sel      on ai_messages;
-- drop policy if exists ai_conversations_del on ai_conversations;
-- drop policy if exists ai_conversations_upd on ai_conversations;
-- drop policy if exists ai_conversations_ins on ai_conversations;
-- drop policy if exists ai_conversations_sel on ai_conversations;

-- 8.3 Trigger va funksiya
-- drop trigger  if exists ai_messages_touch_trg on ai_messages;
-- drop function if exists ai_touch_conversation();

-- 8.4 Jadvallar (MA'LUMOT YO'QOLADI — avval 8.1 ni ko'ring)
-- drop table if exists ai_messages;
-- drop table if exists ai_conversations;

-- 8.5 notify pgrst, 'reload schema';


-- #####################################################################
--  9-BO'LIM — MIJOZ TOMONI UCHUN SHARTNOMA  (faqat izoh, RUN qilinmaydi)
-- #####################################################################
--  `ai-dev.html` ni yozadigan agent AYNAN shu so'rovlarga tayansin.
--  🔴 Har so'rovda `{ data, error }` — supabase-js THROW QILMAYDI,
--     `error` DOIM tekshiriladi (CLAUDE.md 6-qoida). Xato bo'lsa
--     foydalanuvchiga o'zbekcha xabar, jimgina yutish TAQIQ.
--
--  ---------------------------------------------------------------
--  1) YON PANEL — suhbatlar ro'yxati (yangisi tepada)
--  ---------------------------------------------------------------
--     sb.from('ai_conversations')
--       .select('id, title, updated_at')
--       .eq('is_deleted', false)
--       .order('updated_at', { ascending: false })
--       .limit(50)
--     ⚠️ `.eq('user_id', ...)` YOZISH SHART EMAS — RLS o'zi filtrlaydi.
--        (yozsa ham zarar yo'q, lekin ortiqcha).
--
--  ---------------------------------------------------------------
--  2) SUHBATNI OCHISH — xabarlar
--  ---------------------------------------------------------------
--     sb.from('ai_messages')
--       .select('id, role, content, sources, model, created_at')
--       .eq('conversation_id', convId)
--       .order('created_at', { ascending: true })
--
--  ---------------------------------------------------------------
--  3) YANGI SUHBAT ("+" tugmasi)
--  ---------------------------------------------------------------
--     sb.from('ai_conversations')
--       .insert({ title: sarlavha })      // user_id YUBORILMAYDI
--       .select('id, title, created_at, updated_at')
--       .single()
--     ⚠️ `user_id` ni QO'LDA YUBORMANG: default auth.uid() to'ldiradi,
--        boshqa qiymat yuborilsa RLS 42501 bilan rad etadi.
--     ⚠️ `title` — birinchi savoldan, 200 belgigacha (mijozda kesing,
--        aks holda CHECK 23514 beradi).
--     Tavsiya: suhbatni BIRINCHI savol yuborilgandan keyin yarating —
--     bo'sh suhbatlar yon panelni to'ldirmasin.
--
--  ---------------------------------------------------------------
--  4) XABAR QO'SHISH (savol va javob — ikkitasi alohida qator)
--  ---------------------------------------------------------------
--     sb.from('ai_messages').insert({
--       conversation_id: convId,
--       role: 'user',                     // yoki 'assistant'
--       content: matn,                    // 1..200000 belgi, bo'sh bo'lmasin
--       sources: manbalar,                // faqat assistant; yo'q bo'lsa null
--       model: model                      // faqat assistant; yo'q bo'lsa null
--     })
--     ⚠️ `user_id` YUBORILMAYDI. `conversation_id` o'zingizniki bo'lishi
--        SHART — begona suhbatga yozilsa RLS 42501 qaytaradi.
--     ⚠️ Insert bo'lgach `ai_conversations.updated_at` TRIGGER bilan
--        yangilanadi — mijoz uni qo'lda yozmasin.
--     Tavsiya: `role:'user'` qatorini EF chaqiruvidan OLDIN, javobni
--     EF muvaffaqiyatli qaytgach yozing (EF xato bersa chatda soxta
--     javob qolmaydi — 2-bosqich qoidasi).
--
--  ---------------------------------------------------------------
--  5) SARLAVHANI O'ZGARTIRISH
--  ---------------------------------------------------------------
--     sb.from('ai_conversations')
--       .update({ title: yangi, updated_at: new Date().toISOString() })
--       .eq('id', convId)
--       .select('id')                     // RLS jimgina tosmasin
--     ⚠️ Trigger FAQAT xabar insertida ishlaydi — sarlavha tahririda
--        `updated_at` ni MIJOZ yozadi (aks holda suhbat yon panelda
--        pastda qolib ketadi).
--
--  ---------------------------------------------------------------
--  6) O'CHIRISH — SOFT (hech narsa o'chirilmaydi)
--  ---------------------------------------------------------------
--     sb.from('ai_conversations')
--       .update({ is_deleted: true })
--       .eq('id', convId)
--       .select('id')
--     ⚠️ `.delete()` ISHLATMANG. Qator o'chsa xabarlari ham cascade
--        bilan ketadi va tiklab bo'lmaydi.
--     ⚠️ `.select('id')` — qaytgan massiv BO'SH bo'lsa qator yangilanmagan
--        (RLS to'sgan yoki id noto'g'ri): "O'chirildi" deb YOZMANG.
--
--  ---------------------------------------------------------------
--  7) EDGE FUNCTION bilan aloqasi
--  ---------------------------------------------------------------
--     EF `ai-chat` ga hamon `{ messages: [...] }` yuboriladi (kontrakt
--     O'ZGARMAGAN). Tarixni DB dan o'qib, oxirgi N xabarni EF ga uzatish
--     MIJOZ ishi. EF bu jadvallarga YOZMAYDI — u foydalanuvchi JWT'si
--     bilan ishlaydi va service_role ishlatmaydi (service_role RLS ni
--     BYPASS qiladi, ya'ni himoya yo'qolardi).
-- =====================================================================
