-- ============================================================================
--  PROVODKA_MODDA_BIRLASHTIR.sql — 2026-09-15 (Asilbek)
--  «Yo'l harajati turi bilan Transport va yetkazib berish turi aslida bitta
--  narsa. Yo'l harajatini o'chiramiz, oldin yozilgan provodkalarni Transport va
--  yetkazib berishga o'tkazamiz, keyin Transport va yetkazib berishni «Yo'l
--  harajati» deb nomlaymiz. Rollarda shu tur ulangan — nom o'zgarganda qayta
--  ulashga to'g'ri kelmasligi kerak.»
--
--  NIMA QILADI (hammasi BITTA tranzaksiyada — biror joyi yiqilsa HECH NARSA
--  o'zgarmaydi):
--    ESKI  = «Yo'l harajati»                 → yopiladi (is_active=false,
--                                               nomiga «(eski — birlashtirildi)»)
--    YANGI = «Transport va yetkazib berish»  → SAQLANADI (id/kod o'zgarmaydi) va
--                                               «Yo'l harajati» deb nomlanadi
--    1) entry_line: ESKI dagi hamma satrlar → YANGI (tarix ham, kutilayotgan
--       pul so'rovlari ham). Har yozuvga entry_history izi.
--    2) Rollar (rbac_role_modda): ESKI biriktirilgan har rol YANGI ni oladi.
--       Ikkalasi bor rolda oylik limit QO'SHILADI (Asilbek qarori); birortasi
--       cheksiz (null) bo'lsa — cheksiz.
--    3) Filial limitlari (standart_xarajat): xuddi shu qoida — yig'indi.
--    4) Maxsus maydonlar (xarajat_maydon_modda): ESKI dagi maydonlar YANGI ga
--       ham biriktiriladi (birortasida majburiy bo'lsa — majburiy).
--    5) Ochiq ruxsat so'rovlari (ruxsat_sorov, status='pending') → YANGI.
--
--  NEGA ROLLAR QAYTA ULANMAYDI: rol, limit, qorovul (rbac_guard_entry_line),
--  maxsus maydon — HAMMASI moddani UUID bo'yicha taniydi, nom bo'yicha emas.
--  YANGI ning id si o'zgarmaydi, faqat nomi — shuning uchun unga ulangan hamma
--  narsa o'zi ishlayveradi. ESKI ning bog'lanishlari esa YANGI ga ko'chiriladi.
--
--  XAVFSIZLIK:
--    • Moddalar NOM bo'yicha topiladi (katta-kichik harf, apostrof turi, x/h
--      farqi hisobga olinmaydi). Har biridan AYNAN BITTA faol xarajat moddasi
--      topilmasa — hech narsa qilmay, sababini yozib to'xtaydi.
--    • Ovqat / ehson moddasi bo'lsa, ESKI ning bola hisoblari bo'lsa yoki bitta
--      hodimda ikkala turga ochiq ruxsat so'rovi bo'lsa — to'xtaydi.
--    • Qilingan har o'zgarish `modda_birlashtir_log` jadvaliga yoziladi
--      (orqaga qaytarish kerak bo'lsa shu yerdan).
--    • Qayta RUN qilinsa: «allaqachon bajarilgan» deb chiqadi, hech narsa qilmaydi.
--
--  ⚠️ DIQQAT — oylik limit: birlashgach YANGI ning shu oydagi sarfi ikkala
--    turning yig'indisi bo'ladi. Rol/filial limitlari yig'ilgani uchun odatda
--    muammo bo'lmaydi, lekin faqat BITTA turga limit qo'yilgan rolda hodim
--    darhol limitga urilishi mumkin — RUN dan keyin DIAG ro'yxatiga qarang.
-- ============================================================================


-- ----------------------------------------------------------------------------
--  LOG JADVALI (orqaga qaytarish uchun) — faqat admin/servis ko'radi
-- ----------------------------------------------------------------------------
create table if not exists modda_birlashtir_log (
  id          bigserial   primary key,
  batch       text        not null,
  tur         text        not null,          -- accounts | entry_line | rbac | standart | maydon | ruxsat
  malumot     jsonb       not null,
  created_at  timestamptz not null default now()
);
alter table modda_birlashtir_log enable row level security;
revoke all on table modda_birlashtir_log from public, anon, authenticated;


-- ----------------------------------------------------------------------------
--  NOM NORMALLASHTIRISH — 1-urinish «Yo'l harajati» ni topa olmadi (0 ta mos):
--  bazadagi nom boshqacha yozilgan (masalan «Yul harajati», kirillcha
--  «Йўл харажати», «Yo'l xarajatlari»). Endi: kichik harf, kirill → lotin
--  (o'zbek harflari bilan), apostrof turlari o'chiriladi, x → h, bo'shliqlar
--  bittaga. Natija faqat [a-z0-9 ].
-- ----------------------------------------------------------------------------
create or replace function _modda_norm(p text)
returns text
language sql
immutable
as $fn$
  select btrim(regexp_replace(regexp_replace(
           translate(
             translate(lower(coalesce(p, '')),
                       'абвгдежзийклмнопрстуфхцўқғҳэё' || chr(39) || '`ʻʼ’‘',
                       'abvgdejziyklmnoprstufxcoqghee'),
             'x', 'h'),
           '[^a-z0-9 ]', '', 'g'), '\s+', ' ', 'g'))
$fn$;
revoke all on function _modda_norm(text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
--  BIRLASHTIRISH (atomik)
-- ----------------------------------------------------------------------------
do $mig$
declare
  c_batch    constant text := 'yol_harajati_2026_09_15';
  v_old      uuid;
  v_new      uuid;
  v_old_name text;
  v_new_name text;
  v_old_code text;
  v_new_code text;
  v_n        int;
  v_lines    int;
  v_entries  int;
  v_list     text;
  r          record;
begin
  -- 0) Qayta RUN — allaqachon bajarilganmi
  if exists (select 1 from modda_birlashtir_log where batch = c_batch and tur = 'yakun') then
    raise notice 'Bu birlashtirish ALLAQACHON bajarilgan (modda_birlashtir_log, batch=%) — hech narsa qilinmadi', c_batch;
    return;
  end if;

  -- 1) Moddalarni NOM bo'yicha topish (_modda_norm), har biridan AYNAN BITTA faol xarajat moddasi.
  --    ESKI : «yol/yul harajat…» bilan boshlanadi (Yo'l harajati, Yul xarajatlari, Йўл харажати …)
  --    YANGI: nomida ham «transport», ham «(y)etkaz» bor (Transport va yetkazib berish …)
  declare
    v_n_old int;
    v_n_new int;
  begin
    select count(*), min(a.id::text)::uuid into v_n_old, v_old
      from accounts a
     where a.type = 'xarajat' and a.is_active
       and _modda_norm(a.name) ~ '^y[ou]l h?arajat';
    select count(*), min(a.id::text)::uuid into v_n_new, v_new
      from accounts a
     where a.type = 'xarajat' and a.is_active
       and _modda_norm(a.name) ~ 'transport' and _modda_norm(a.name) ~ 'y?etkaz';

    if v_n_old <> 1 or v_n_new <> 1 then
      -- Nomzodlar HAMMA tur va holatdan (xarajat bo'lmasa ham, nofaol bo'lsa ham) —
      -- xato matnining o'zidan bazada aynan nima borligi ko'rinsin.
      select string_agg(a.code || ' · ' || a.name || ' [' || coalesce(a.type, '?')
                        || case when a.is_active then '' else ', nofaol' end || ']', '; ' order by a.code)
        into v_list
        from (select * from accounts a
               where _modda_norm(a.name) ~ '(^| )y[ou]l( |$)|transport|etkaz'
               order by a.code limit 30) a;
      raise exception 'Moddalar aniq topilmadi: «Yo''l harajati» — % ta, «Transport va yetkazib berish» — % ta mos (har biridan 1 ta kerak). Nomzodlar: %',
        v_n_old, v_n_new, coalesce(v_list, 'yo''q');
    end if;
  end;

  if v_old = v_new then
    raise exception 'Ikkala nom bitta moddaga tushdi — to''xtatildi';
  end if;

  select name, code into v_old_name, v_old_code from accounts where id = v_old;
  select name, code into v_new_name, v_new_code from accounts where id = v_new;
  raise notice 'ESKI  (yopiladi) : % · %  [%]', v_old_code, v_old_name, v_old;
  raise notice 'YANGI (qoladi)   : % · %  [%]', v_new_code, v_new_name, v_new;

  -- 2) To'siqlar — biror holat bo'lsa HECH NARSA qilmasdan to'xtaymiz
  if exists (select 1 from accounts a where a.id in (v_old, v_new)
              and coalesce((to_jsonb(a) ->> 'ovqat_modda')::boolean, false)) then
    raise exception 'Moddalardan biri OVQAT moddasi — bu skript ovqat moddasini birlashtirmaydi';
  end if;
  if exists (select 1 from accounts a where a.id in (v_old, v_new)
              and nullif(to_jsonb(a) ->> 'ehson_kassa_id', '') is not null) then
    raise exception 'Moddalardan biri EHSON moddasi — bu skript ehson moddasini birlashtirmaydi';
  end if;
  if exists (select 1 from accounts a where a.parent_id = v_old) then
    raise exception 'ESKI moddaning bola hisoblari bor — avval ularni hal qiling';
  end if;
  if to_regclass('public.entry_ovqat') is not null then
    execute 'select count(*) from entry_line l
               where l.account_id = $1
                 and exists (select 1 from entry_ovqat eo
                              where eo.entry_id = l.entry_id
                                and not coalesce((to_jsonb(eo) ->> ''is_deleted'')::boolean, false))'
      into v_n using v_old;
    if v_n > 0 then
      raise exception 'ESKI moddada % ta ovqat taqsimotli satr bor — ovqat qorovuli ularni ko''chirishga yo''l qo''ymaydi', v_n;
    end if;
  end if;
  if to_regclass('public.ruxsat_sorov') is not null then
    select string_agg(distinct x.hodim_id::text, ', ') into v_list
      from (select hodim_id from ruxsat_sorov
             where status = 'pending' and modda_id in (v_old, v_new)
             group by hodim_id having count(distinct modda_id) > 1) x;
    if v_list is not null then
      raise exception 'Bu hodim(lar)da ikkala turga ham OCHIQ ruxsat so''rovi bor: % — avval birini tasdiqlang/rad eting', v_list;
    end if;
  end if;

  -- 3) LOG: ikkala moddaning to'liq nusxasi
  insert into modda_birlashtir_log (batch, tur, malumot)
  select c_batch, 'accounts', to_jsonb(a) from accounts a where a.id in (v_old, v_new);

  -- Hodimga "hisobingizdan pul chiqdi" xabari ketmasin (bu pul harakati emas)
  perform set_config('provodka.notify_off', '1', true);

  -- 4) PROVODKALAR: ESKI → YANGI
  insert into modda_birlashtir_log (batch, tur, malumot)
  select c_batch, 'entry_line', jsonb_build_object('id', l.id, 'entry_id', l.entry_id, 'account_id', l.account_id)
    from entry_line l where l.account_id = v_old;

  select count(*), count(distinct entry_id) into v_lines, v_entries
    from entry_line where account_id = v_old;

  insert into entry_history (entry_id, action, snapshot, changed_by_name)
  select d.entry_id, 'edit',
         jsonb_build_object('note', 'Xarajat turi birlashtirildi: «' || v_old_name || '» → «'
                                    || v_new_name || '» (keyin «' || v_old_name || '» deb nomlandi)',
                            'old_account_id', v_old, 'new_account_id', v_new),
         'tizim (birlashtirish)'
    from (select distinct entry_id from entry_line where account_id = v_old) d;

  update entry_line set account_id = v_new where account_id = v_old;
  raise notice 'Provodkalar ko''chirildi: % satr, % yozuv', v_lines, v_entries;

  -- 5) ROLLAR: ESKI biriktirilgan rollar YANGI ni oladi; ikkalasi bor bo'lsa limit yig'indisi
  insert into modda_birlashtir_log (batch, tur, malumot)
  select c_batch, 'rbac', to_jsonb(m) from rbac_role_modda m where m.account_id in (v_old, v_new);

  update rbac_role_modda n
     set limit_uzs = case when n.limit_uzs is null or o.limit_uzs is null then null
                          else n.limit_uzs + o.limit_uzs end
    from rbac_role_modda o
   where o.role_id = n.role_id and o.account_id = v_old and n.account_id = v_new;
  get diagnostics v_n = row_count;
  raise notice 'Rollar (ikkalasi ham bor, limit qo''shildi): %', v_n;

  insert into rbac_role_modda (role_id, account_id, limit_uzs)
  select o.role_id, v_new, o.limit_uzs from rbac_role_modda o where o.account_id = v_old
  on conflict (role_id, account_id) do nothing;
  get diagnostics v_n = row_count;
  raise notice 'Rollar (faqat eskisi bor edi, YANGI biriktirildi): %', v_n;

  delete from rbac_role_modda where account_id = v_old;

  -- 6) FILIAL LIMITLARI (standart_xarajat): xuddi shu qoida — yig'indi
  if to_regclass('public.standart_xarajat') is not null then
    insert into modda_birlashtir_log (batch, tur, malumot)
    select c_batch, 'standart', to_jsonb(s) from standart_xarajat s where s.modda_id in (v_old, v_new);

    update standart_xarajat n
       set limit_uzs = n.limit_uzs + o.limit_uzs,
           updated_by = 'birlashtirish'
      from standart_xarajat o
     where o.filial_id = n.filial_id and o.modda_id = v_old and n.modda_id = v_new;
    get diagnostics v_n = row_count;
    raise notice 'Filial limitlari (ikkalasi ham bor, qo''shildi): %', v_n;

    delete from standart_xarajat o
     where o.modda_id = v_old
       and exists (select 1 from standart_xarajat n where n.filial_id = o.filial_id and n.modda_id = v_new);
    update standart_xarajat set modda_id = v_new, updated_by = 'birlashtirish' where modda_id = v_old;
  end if;

  -- 7) MAXSUS MAYDONLAR: ESKI dagi maydonlar YANGI ga ham biriktiriladi
  if to_regclass('public.xarajat_maydon_modda') is not null then
    insert into modda_birlashtir_log (batch, tur, malumot)
    select c_batch, 'maydon', to_jsonb(m) from xarajat_maydon_modda m where m.modda_id in (v_old, v_new);

    update xarajat_maydon_modda n
       set required = case when n.required is true or o.required is true then true
                           else coalesce(n.required, o.required) end
      from xarajat_maydon_modda o
     where o.maydon_id = n.maydon_id and o.modda_id = v_old and n.modda_id = v_new;

    insert into xarajat_maydon_modda (maydon_id, modda_id, required)
    select o.maydon_id, v_new, o.required from xarajat_maydon_modda o where o.modda_id = v_old
    on conflict (maydon_id, modda_id) do nothing;

    delete from xarajat_maydon_modda where modda_id = v_old;
  end if;

  -- 8) OCHIQ RUXSAT SO'ROVLARI → YANGI (tasdiqlanganda ESKI nofaol bo'ladi)
  if to_regclass('public.ruxsat_sorov') is not null then
    insert into modda_birlashtir_log (batch, tur, malumot)
    select c_batch, 'ruxsat', jsonb_build_object('id', s.id, 'modda_id', s.modda_id)
      from ruxsat_sorov s where s.status = 'pending' and s.modda_id = v_old;
    update ruxsat_sorov set modda_id = v_new where status = 'pending' and modda_id = v_old;
    get diagnostics v_n = row_count;
    raise notice 'Ochiq ruxsat so''rovlari ko''chirildi: %', v_n;
  end if;

  -- 9) NOMLAR: avval ESKI yopiladi (nom bo'shaydi), keyin YANGI «Yo'l harajati» bo'ladi
  update accounts
     set is_active = false,
         name = v_old_name || ' (eski — birlashtirildi 2026-09-15)'
   where id = v_old;
  update accounts set name = v_old_name where id = v_new;

  -- 10) YAKUNIY TEKSHIRUV — birortasi buzilsa HAMMASI bekor
  if exists (select 1 from entry_line where account_id = v_old) then
    raise exception 'YAKUNIY TEKSHIRUV: ESKI moddada satr qolib ketdi';
  end if;
  if exists (select 1 from rbac_role_modda where account_id = v_old) then
    raise exception 'YAKUNIY TEKSHIRUV: ESKI modda rolda qolib ketdi';
  end if;

  insert into modda_birlashtir_log (batch, tur, malumot)
  values (c_batch, 'yakun', jsonb_build_object('old', v_old, 'new', v_new, 'old_name', v_old_name,
                                               'new_name_avval', v_new_name, 'satrlar', v_lines,
                                               'yozuvlar', v_entries));

  raise notice '✅ TAYYOR: «%» (% ) endi «%» — eski modda yopildi', v_new_name, v_new_code, v_old_name;
end
$mig$;


-- ----------------------------------------------------------------------------
--  DIAG — natijani ko'rish (faqat o'qish)
-- ----------------------------------------------------------------------------
-- 1) Ikkala modda hozirgi holati
select a.code, a.name, a.is_active,
       (select count(*) from entry_line l where l.account_id = a.id) as satrlar,
       (select count(*) from rbac_role_modda m where m.account_id = a.id) as rollar
  from accounts a
 where a.id in (select (malumot ->> 'id')::uuid from modda_birlashtir_log
                 where batch = 'yol_harajati_2026_09_15' and tur = 'accounts');

-- 2) ESKI moddaga hali ham ishora qilayotgan jadvallar (tarixiy yozuvlar — masalan
--    tasdiqlangan ruxsat so'rovlari — qolishi normal; faol bog'lanishlar bo'lmasligi kerak)
do $refs$
declare
  v_old uuid;
  r     record;
  v_n   bigint;
begin
  select (malumot ->> 'old')::uuid into v_old
    from modda_birlashtir_log where batch = 'yol_harajati_2026_09_15' and tur = 'yakun'
   order by id desc limit 1;
  if v_old is null then
    raise notice 'Birlashtirish bajarilmagan — tekshiradigan narsa yo''q';
    return;
  end if;
  for r in
    select c.conrelid::regclass as tbl, a.attname as col
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f' and c.confrelid = 'public.accounts'::regclass
       and array_length(c.conkey, 1) = 1
  loop
    execute format('select count(*) from %s where %I = $1', r.tbl, r.col) into v_n using v_old;
    if v_n > 0 then
      raise notice 'ESKI moddaga ishora: %.% — % qator', r.tbl, r.col, v_n;
    end if;
  end loop;
  raise notice 'Ishoralar tekshiruvi tugadi';
end
$refs$;

-- 3) Faqat BITTA turga limit qo'yilgan rollar — birlashgach shu oy limitga urilishi mumkin
select r.nom as rol, m.limit_uzs
  from rbac_role_modda m
  join rbac_role r on r.id = m.role_id
 where m.account_id = (select (malumot ->> 'new')::uuid from modda_birlashtir_log
                        where batch = 'yol_harajati_2026_09_15' and tur = 'yakun'
                        order by id desc limit 1)
   and m.limit_uzs is not null
 order by m.limit_uzs;


-- ============================================================================
--  ORQAGA QAYTARISH (qo'lda, faqat kerak bo'lsa) — log jadvalidan:
--    entry_line:  update entry_line l set account_id = (g.malumot->>'account_id')::uuid
--                   from modda_birlashtir_log g
--                  where g.batch='yol_harajati_2026_09_15' and g.tur='entry_line'
--                    and l.id = (g.malumot->>'id')::uuid;
--    accounts:    nomlar va is_active — tur='accounts' qatorlaridagi nusxadan;
--    rbac/standart/maydon: tur='rbac'/'standart'/'maydon' qatorlari — birlashtirishdan
--                 OLDINGI to'liq nusxa (ikkala modda uchun).
-- ============================================================================
