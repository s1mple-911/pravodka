-- ============================================================================
--  PROVODKA_EHSON_KIRIM.sql — 2026-10-17 — Ehson ICHIDA qo'lda pul kirim + balans to'g'irlash
--  Asilbek talabi: (1) Ehson sahifasi ichida «Kirim qilish» (faqat ehson kassalariga, izoh MAJBURIY, server ham tekshiradi);
--  kirim kassa balansiga tushadi, lekin BOSHQA HECH QAYERDA ko'rinmaydi. (2) Alohida «Ehson: pul kirim qilish» ruxsati
--  (bayroq 'ehson_pul_kirim'), ehson sahifasi ruxsati bilan KELMAYDI. (3) 3 ta ehson kassa balansini maqsad qiymatga to'g'irlash.
--
--  YECHIM (nega jurnal/hisobot/aylanma/kassa/Excel/bot funksiyalariga TEGILMAYDI):
--  Ehson balansi butunlay ehson_* jadvallarida (v_ehson_kassa_pul = kirim - berildi - qarz ...). Yangi kirim ham
--  FAQAT ehson_kirim ga yoziladi — entry / entry_line / accounts ga UMUMAN yozuv yo'q. Shuning uchun jurnal_v2_baza, jurnal_dash,
--  pnl, balans, cashflow, aylanma_*, v_kassa_*, Excel eksportlar ularni ko'rmaydi (ular entry_line dan o'qiydi, bu yozuvlar
--  u yerda yo'q). 'texnik' tokeni kabi serverdagi filtr kerak emas — yozuv avval ham u jadvallarda bo'lmagan.
--  Balans (v_ehson_kassa_pul / v_ehson_kassa) ehson_kirim dan sum qiladi — o'zgarishsiz, qo'lda kirim avtomat hisobga olinadi.
--
--  Bo'limlar:
--   0  old shart tekshiruvi
--   1  ruxsat: perm_pages() ga 'ehson_pul_kirim' (dinamik, mavjud ro'yxat saqlanadi) + ehson_pul_kirim_ok()
--   2  ehson_kirim: ustun `tur` (null=jurnaldan | 'qolda' | 'tuzatish') + check'lar (tuzatish manfiy bo'lishi mumkin)
--   3  ehson_kirim_qolda(p jsonb) — RPC: ruxsat, kassa (faqat ehson), pul turi, izoh >= 3, USD kursi
--   4  ehson_kirim_royxat(jsonb) — QAYTA (imzo bir xil), qatorga 'tur' qo'shildi
--   5  balans to'g'irlash — _ehson_balans_togrila_20261017() (IDEMPOTENT: tarix belgisi) va uni chaqirish
--   6  PostgREST kesh + o'z-o'zini tekshiruv
--  ADDITIVE: hech narsa drop qilinmaydi (faqat ehson_kirim.summa check'i yumshatiladi: summa>0 YOKI tuzatish).
--  Asilbek RUN qiladi. 5-bo'lim oxirida natija jadvali chiqadi (har kassa+pul turi: oldin / maqsad / farq / holat).
--  Oldingi RUN talab: PROVODKA_EHSON.sql, PROVODKA_EHSON_ZAKOT.sql, PROVODKA_EHSON_QARZ.sql.
-- ============================================================================


-- #####################################################################
-- ##  0-BOLIM — OLD SHART                                             ##
-- #####################################################################
do $ek_pre$
begin
  if to_regclass('public.ehson_kirim') is null then raise exception 'ehson_kirim yoq — avval PROVODKA_EHSON.sql'; end if;
  if to_regclass('public.ehson_pul_turi') is null then raise exception 'ehson_pul_turi yoq — avval PROVODKA_EHSON_ZAKOT.sql'; end if;
  if to_regclass('public.ehson_qarz') is null then raise exception 'ehson_qarz yoq — avval PROVODKA_EHSON_QARZ.sql (v_ehson_kassa_pul ning oxirgi versiyasi shu yerda)'; end if;
  if to_regprocedure('public.perm_pages()') is null then raise exception 'perm_pages() yoq'; end if;
  if to_regprocedure('public._ehson_is_admin()') is null then raise exception '_ehson_is_admin() yoq — avval PROVODKA_EHSON.sql'; end if;
  if to_regprocedure('public._ehson_tarix_yoz(text,uuid,text,jsonb)') is null then raise exception '_ehson_tarix_yoz yoq'; end if;
  if to_regclass('public.v_ehson_kassa_pul') is null then raise exception 'v_ehson_kassa_pul yoq'; end if;
end
$ek_pre$;


-- #####################################################################
-- ##  1-BOLIM — RUXSAT: 'ehson_pul_kirim' bayrog'i                    ##
-- #####################################################################
-- 🔴 Bu BAYROQ (sahifa emas): allowed_pages ichida saqlanadi (perms-dev.js FLAGS). 'ehson_kirim' (Professional'da
--    Dt «Ehson jamg'armasi» yozish) bilan ARALASHTIRMANG: u kompaniya pulini jamg'armaga o'tkazadi, bu esa Ehson ichida
--    pulni qo'lda kirim qiladi. Alohida beriladi; 'ehson' sahifasi ham, 'ehson_kirim' ham buni BERMAYDI.
-- perm_pages() — joriy ro'yxat o'qiladi va OXIRIGA qo'shiladi (boshqa SQL fayllar qo'shgan kalitlar tushib qolmasin).
-- Imzo/til/immutable o'zgarmaydi; grant'lar create or replace da saqlanadi.
do $ek_perm$
declare
  v_list text[] := perm_pages();
begin
  if not ('ehson_pul_kirim' = any(v_list)) then
    v_list := v_list || array['ehson_pul_kirim']::text[];
    execute 'create or replace function perm_pages() returns text[] language sql immutable as $ek_pp$ select '
            || quote_literal(v_list::text) || '::text[] $ek_pp$';
  end if;
end
$ek_perm$;

revoke all on function perm_pages() from public, anon;
grant execute on function perm_pages() to authenticated, service_role;

create or replace function ehson_pul_kirim_ok()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then return false; end if;
  if _ehson_is_admin() then return true; end if;
  return coalesce(
    (select 'ehson_pul_kirim' = any(coalesce(allowed_pages, '{}'::text[]))
       from user_perms where user_id = v_uid),
    false);
end
$fn$;

revoke all on function ehson_pul_kirim_ok() from public, anon;
grant execute on function ehson_pul_kirim_ok() to authenticated;

comment on function ehson_pul_kirim_ok() is
  'Ehson ichida qo''lda pul kirim qilish ruxsati: admin YOKI allowed_pages ∋ ehson_pul_kirim. ehson sahifasi / ehson_kirim buni BERMAYDI.';


-- #####################################################################
-- ##  2-BOLIM — ehson_kirim.tur + check'lar                           ##
-- #####################################################################
-- tur: null = jurnaldan (trigger), 'qolda' = Ehson ichida qo'lda kirim, 'tuzatish' = balans to'g'irlash (summa manfiy
-- bo'lishi mumkin). Eski qatorlar null — hech narsa o'zgarmaydi.
alter table ehson_kirim add column if not exists tur text;
comment on column ehson_kirim.tur is 'null = jurnaldan (trigger) | qolda = Ehson ichida qo''lda kirim | tuzatish = balans to''g''irlash (manfiy bo''lishi mumkin).';

do $ek_chk$
declare
  v_name text;
begin
  -- eski «summa > 0» check'i (nomi avto) -> «summa > 0 YOKI (tuzatish va summa <> 0)». Boshqa qatorlar uchun qoida o'sha-o'sha.
  for v_name in
    select conname from pg_constraint
     where conrelid = 'public.ehson_kirim'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) like '%summa%'
       and pg_get_constraintdef(oid) not like '%fc_summa%'
       and pg_get_constraintdef(oid) not like '%tuzatish%'
  loop
    execute format('alter table ehson_kirim drop constraint %I', v_name);
  end loop;

  if not exists (select 1 from pg_constraint where conrelid = 'public.ehson_kirim'::regclass and conname = 'ehson_kirim_summa_check') then
    alter table ehson_kirim add constraint ehson_kirim_summa_check
      check (summa > 0 or (tur = 'tuzatish' and summa <> 0));
  end if;

  if not exists (select 1 from pg_constraint where conrelid = 'public.ehson_kirim'::regclass and conname = 'ehson_kirim_tur_check') then
    alter table ehson_kirim add constraint ehson_kirim_tur_check
      check (tur is null or tur in ('qolda', 'tuzatish'));
  end if;

  -- izoh MAJBURIY (server tomonda, RPC'dan tashqari to'g'ridan yozishda ham): qo'lda va tuzatish qatorlarida >= 3 belgi
  if not exists (select 1 from pg_constraint where conrelid = 'public.ehson_kirim'::regclass and conname = 'ehson_kirim_qolda_izoh_check') then
    alter table ehson_kirim add constraint ehson_kirim_qolda_izoh_check
      check (tur is null or length(btrim(coalesce(izoh, ''))) >= 3);
  end if;
end
$ek_chk$;


-- #####################################################################
-- ##  3-BOLIM — ehson_kirim_qolda(p jsonb) — qo'lda kirim              ##
-- #####################################################################
-- p: {kassa_id, pul_turi, summa (so'm pul turi uchun) | fc_summa (dollar pul turi uchun), izoh (>=3), sana?, ext_ref?}
-- Javob: {ok:true,id} | {ok:false,kod}. kod: izoh_kerak · kassa_kerak · kassa_topilmadi · kassa_konteyner · pul_turi_kerak ·
-- summa_notogri · kurs_yoq · sana_notogri · takror. Ruxsat yo'q -> 42501 (exception).
-- 🔴 entry/entry_line/accounts ga YOZILMAYDI — shuning uchun jurnal/hisobot/kassa/aylanma/Excel'da ko'rinmaydi.
create or replace function ehson_kirim_qolda(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid     uuid    := auth.uid();
  v_kassa   uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_pt_kod  text    := nullif(p->>'pul_turi', '');
  v_summa   numeric := nullif(p->>'summa', '')::numeric;
  v_fc      numeric := nullif(p->>'fc_summa', '')::numeric;
  v_bugun   date    := (now() at time zone 'Asia/Tashkent')::date;
  v_sana    date    := coalesce(nullif(p->>'sana', '')::date, (now() at time zone 'Asia/Tashkent')::date);
  v_izoh    text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_ext     text    := nullif(btrim(coalesce(p->>'ext_ref', '')), '');
  v_kassa_r ehson_kassa;
  v_pt      ehson_pul_turi;
  v_kurs    numeric;
  v_id      uuid;
  v_exist   uuid;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_pul_kirim_ok() then
    raise exception 'Ehson kirim qilish uchun «Ehson: pul kirim qilish» ruxsati kerak' using errcode = '42501';
  end if;

  if v_ext is not null then
    select id into v_exist from ehson_kirim where ext_ref = v_ext;
    if found then
      return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
    end if;
  end if;

  if v_izoh is null or length(v_izoh) < 3 then
    return jsonb_build_object('ok', false, 'kod', 'izoh_kerak');
  end if;
  if v_sana > v_bugun then
    return jsonb_build_object('ok', false, 'kod', 'sana_notogri');
  end if;

  if v_kassa is null then
    return jsonb_build_object('ok', false, 'kod', 'kassa_kerak');
  end if;
  select * into v_kassa_r from ehson_kassa where id = v_kassa and is_active;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi');
  end if;
  if v_kassa_r.is_container then
    return jsonb_build_object('ok', false, 'kod', 'kassa_konteyner');
  end if;

  if v_pt_kod is null then
    return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak');
  end if;
  select * into v_pt from ehson_pul_turi where kassa_id = v_kassa and kod = v_pt_kod and is_active;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'pul_turi_kerak');
  end if;

  if v_pt.valyuta = 'USD' then
    if v_fc is null or v_fc <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
    end if;
    v_kurs := null;
    if exists (
      select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
       where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs'
         and oidvectortypes(pr.proargtypes) = 'text'
    ) then
      execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
    end if;
    if v_kurs is null or v_kurs <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'kurs_yoq');
    end if;
    v_summa := round(v_fc * v_kurs);
    if v_summa <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
    end if;
  else
    v_fc := null;
    if v_summa is null or v_summa <= 0 then
      return jsonb_build_object('ok', false, 'kod', 'summa_notogri');
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || v_kassa::text));

  insert into ehson_kirim (kassa_id, summa, sana, manba, izoh, created_by, pul_turi, valyuta, fc_summa, ext_ref, tur)
  values (v_kassa, v_summa, v_sana, 'Ehson kirim', v_izoh, v_uid, v_pt.kod, coalesce(v_pt.valyuta, 'UZS'), v_fc, v_ext, 'qolda')
  returning id into v_id;

  perform _ehson_tarix_yoz('kirim', v_id, 'qolda_kirim',
    jsonb_build_object('kassa_id', v_kassa, 'pul_turi', v_pt.kod, 'summa', v_summa, 'fc_summa', v_fc));

  return jsonb_build_object('ok', true, 'id', v_id);
exception when unique_violation then
  select id into v_exist from ehson_kirim where ext_ref = v_ext;
  return jsonb_build_object('ok', false, 'kod', 'takror', 'id', v_exist);
end
$fn$;

revoke all on function ehson_kirim_qolda(jsonb) from public, anon;
grant execute on function ehson_kirim_qolda(jsonb) to authenticated;

comment on function ehson_kirim_qolda(jsonb) is
  'Ehson ichida qo''lda kirim (faqat ehson_kassa child + faol pul turi, izoh >= 3). Ruxsat: ehson_pul_kirim_ok(). '
  'Faqat ehson_kirim ga yozadi (tur=qolda) — entry/entry_line/accounts ga TEGMAYDI, jurnal/hisobot/kassa/aylanma/Excel ko''rmaydi.';


-- #####################################################################
-- ##  4-BOLIM — ehson_kirim_royxat QAYTA (+ 'tur')                    ##
-- #####################################################################
-- Imzo (jsonb -> jsonb) va barcha eski kalitlar o'zgarmagan; qatorga faqat 'tur' qo'shildi.
-- Tana PROVODKA_EHSON_ZAKOT.sql dagi ENG OXIRGI versiyadan verbatim. 🔴 ENG OXIRGI versiya endi SHU faylda.

create or replace function ehson_kirim_royxat(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid    := auth.uid();
  v_from   date    := nullif(p->>'from', '')::date;
  v_to     date    := nullif(p->>'to', '')::date;
  v_q      text    := nullif(btrim(coalesce(p->>'q', '')), '');
  v_bekor  boolean := coalesce((p->>'bekor')::boolean, true);
  v_kassa  uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_pt     text    := nullif(p->>'pul_turi', '');
  v_limit  int     := greatest(1, least(coalesce(nullif(p->>'limit', '')::int, 50), 200));
  v_offset int     := greatest(0, coalesce(nullif(p->>'offset', '')::int, 0));
  v_rows   jsonb;
  v_jami   int;
  v_summa  numeric;
  v_all    boolean := false;
  v_ok_ids uuid[]  := '{}';
  v_view   uuid[];
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  if _ehson_is_admin() then
    v_all := true;
  else
    select u.view_kassa_ids into v_view from user_perms u where u.user_id = v_uid and u.kassa_scope = 'list';
    if not found then
      v_all := true;
    elsif exists (
      select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
       where ns.nspname = 'public' and pr.proname = 'perm_op_key' and oidvectortypes(pr.proargtypes) = 'uuid'
    ) then
      execute 'select coalesce(array_agg(a.id), ''{}''::uuid[]) from accounts a where perm_op_key(a.id) = any($1)'
         into v_ok_ids using coalesce(v_view, '{}'::uuid[]);
    end if;
  end if;

  select count(*), coalesce(sum(k.summa) filter (where not k.is_deleted), 0)
    into v_jami, v_summa
    from ehson_kirim k
    left join accounts pa on pa.id = k.pul_kassa_id
   where (v_from  is null or k.sana >= v_from)
     and (v_to    is null or k.sana <= v_to)
     and (v_bekor or not k.is_deleted)
     and (v_kassa is null or k.kassa_id = v_kassa)
     and (v_pt    is null or k.pul_turi = v_pt)
     and (v_q is null or k.manba ilike '%' || v_q || '%' or k.izoh ilike '%' || v_q || '%'
                      or pa.name ilike '%' || v_q || '%');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', k.id, 'sana', k.sana, 'summa', k.summa, 'manba', k.manba, 'izoh', k.izoh,
           'kassa_id', k.kassa_id, 'kassa_nom', ks.nom,
           'pul_turi', k.pul_turi, 'valyuta', k.valyuta, 'fc_summa', k.fc_summa,
           'pul_kassa_id', case when v_all or k.pul_kassa_id = any(v_ok_ids) then k.pul_kassa_id end,
           'pul_kassa_nom', case when k.pul_kassa_id is null then null
                                 when v_all or k.pul_kassa_id = any(v_ok_ids) then pa.name
                                 else 'Kompaniya kassasi' end,
           'pul_kassa_kod', case when v_all or k.pul_kassa_id = any(v_ok_ids) then pa.code end,
           'entry_id', k.entry_id,
           'tur', k.tur,
           'kim', coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum'),
           'created_at', k.created_at,
           'is_deleted', k.is_deleted, 'deleted_at', k.deleted_at,
           'bekor_kim', case when k.is_deleted then coalesce(nullif(btrim(pd.full_name), ''), 'Jurnal') end,
           'bekor_sabab', case when k.is_deleted then coalesce(t.sabab, 'Jurnalda o''chirildi') end
         ) order by k.sana desc, k.created_at desc), '[]'::jsonb)
    into v_rows
    from (
      select k.* from ehson_kirim k
      left join accounts pa on pa.id = k.pul_kassa_id
       where (v_from  is null or k.sana >= v_from)
         and (v_to    is null or k.sana <= v_to)
         and (v_bekor or not k.is_deleted)
         and (v_kassa is null or k.kassa_id = v_kassa)
         and (v_pt    is null or k.pul_turi = v_pt)
         and (v_q is null or k.manba ilike '%' || v_q || '%' or k.izoh ilike '%' || v_q || '%'
                          or pa.name ilike '%' || v_q || '%')
       order by k.sana desc, k.created_at desc
       limit v_limit offset v_offset
    ) k
    left join ehson_kassa ks on ks.id = k.kassa_id
    left join accounts pa on pa.id = k.pul_kassa_id
    left join profiles pr on pr.id = k.created_by
    left join profiles pd on pd.id = k.deleted_by
    left join lateral (
      select x.data->>'sabab' as sabab
        from ehson_tarix x
       where x.obyekt = 'kirim' and x.obyekt_id = k.id and x.hodisa = 'bekor'
       order by x.vaqt desc limit 1
    ) t on true;

  return jsonb_build_object('rows', coalesce(v_rows, '[]'::jsonb), 'jami', v_jami, 'jami_summa', v_summa);
end
$fn$;

revoke all on function ehson_kirim_royxat(jsonb) from public, anon;
grant execute on function ehson_kirim_royxat(jsonb) to authenticated;

comment on function ehson_kirim_royxat(jsonb) is
  'Kirim tarixi. + pul_turi/valyuta/fc_summa qatorda, filtr kassa_id/pul_turi ixtiyoriy (2026-09-07 zakot); + tur (null=jurnaldan, qolda, tuzatish; 2026-10-17). Qolgan shakl o''zgarmagan.';




-- #####################################################################
-- ##  5-BOLIM — BALANS TO'G'IRLASH 2026-10-17 (Asilbek)               ##
-- #####################################################################
-- Maqsad (jamg'arma kassa -> pul turi -> qiymat):
--   Ehson asosiy : naqd (UZS) 52 775 000  · dollar (USD) 25 730
--   Ehson soliq  : naqd (UZS) 107 449 000 · dollar (USD) 48 715
--   Zakot        : naqd (UZS) 476 000     · dollar (USD) 0
-- Hozirgi qoldiq v_ehson_kassa_pul dan o'qiladi (UZS -> qoldiq, USD -> fc_qoldiq), FARQ ehson_kirim ga tur='tuzatish'
-- sifatida yoziladi (manfiy bo'lishi mumkin). Boshqa joyda ko'rinmaydi — kirim bilan bir xil sabab (entry yo'q).
-- IDEMPOTENT: har kassa+pul turi uchun ehson_tarix ga 'balans_togrilandi_20261017' belgisi qo'yiladi (farq 0 bo'lsa ham) —
-- qayta RUN qilinsa o'sha juftlik o'tkaziladi. (Faqat farq bo'yicha emas: aks holda orada berilgan haqiqiy pul qayta «to'g'irlanib» qolardi.)
-- Kassa NOM bo'yicha topiladi (child, faol, konteyner emas) — bu bazada boshqa ishonchli belgi yo'q (kassalar seed'da nom bilan
-- ochilgan, id'lari tasodifiy uuid). Topilmasa yoki bir nechta bo'lsa o'sha qator o'tkaziladi va holatda ko'rsatiladi (xato bermaydi).
-- USD uchun so'm ekvivalenti conv_baza_kurs('USD') bilan (ehson_ber kabi); kurs yo'q bo'lsa USD qatorlari o'tkaziladi — kurs
-- kiritilgach shu faylni qayta RUN qiling.
create or replace function _ehson_balans_togrila_20261017()
returns table (o_kassa text, o_pul_turi text, o_valyuta text, o_oldin numeric, o_maqsad numeric, o_farq numeric, o_holat text, o_eslatma text)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_izoh  constant text := 'Balans to''g''irlash 2026-10-17 (Asilbek)';
  v_hodisa constant text := 'balans_togrilandi_20261017';
  v_bugun date := (now() at time zone 'Asia/Tashkent')::date;
  v_kurs  numeric;
  v_t     record;
  v_cnt   int;
  v_kassa uuid;
  v_pt    ehson_pul_turi;
  v_cur   numeric;
  v_farq  numeric;
  v_summa numeric;
  v_fc    numeric;
  v_null  numeric;
  v_id    uuid;
begin
  if exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs' and oidvectortypes(pr.proargtypes) = 'text'
  ) then
    execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
  end if;

  for v_t in
    select * from (values
      ('ehson asosiy', 'Ehson asosiy', 'naqd',   'UZS', 52775000::numeric),
      ('ehson asosiy', 'Ehson asosiy', 'dollar', 'USD', 25730::numeric),
      ('ehson soliq',  'Ehson soliq',  'naqd',   'UZS', 107449000::numeric),
      ('ehson soliq',  'Ehson soliq',  'dollar', 'USD', 48715::numeric),
      ('zakot',        'Zakot',        'naqd',   'UZS', 476000::numeric),
      ('zakot',        'Zakot',        'dollar', 'USD', 0::numeric)
    ) as x(nom_key, nom, pul_kod, valyuta, maqsad)
  loop
    o_kassa := v_t.nom; o_pul_turi := v_t.pul_kod; o_valyuta := v_t.valyuta;
    o_oldin := null; o_maqsad := v_t.maqsad; o_farq := null; o_eslatma := null;

    select count(*), min(k.id::text)::uuid into v_cnt, v_kassa
      from ehson_kassa k
     where k.parent_id is not null and not k.is_container and k.is_active
       and lower(btrim(k.nom)) = v_t.nom_key;
    if v_cnt <> 1 then
      o_holat := case when v_cnt = 0 then 'O''TKAZILDI: kassa nomi bo''yicha topilmadi' else 'O''TKAZILDI: bir nechta kassa shu nomda' end;
      return next; continue;
    end if;

    select * into v_pt from ehson_pul_turi where kassa_id = v_kassa and kod = v_t.pul_kod and is_active;
    if not found then
      o_holat := 'O''TKAZILDI: faol pul turi yoq'; return next; continue;
    end if;

    if exists (select 1 from ehson_tarix where obyekt = 'kassa' and obyekt_id = v_kassa
                  and hodisa = v_hodisa and data->>'pul_turi' = v_t.pul_kod) then
      o_holat := 'allaqachon qo''llangan (o''tkazildi)'; return next; continue;
    end if;

    perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || v_kassa::text));

    if v_t.valyuta = 'USD' then
      select coalesce(sum(fc_qoldiq), 0) into v_cur from v_ehson_kassa_pul where kassa_id = v_kassa and pul_turi = v_t.pul_kod;
    else
      select coalesce(sum(qoldiq), 0) into v_cur from v_ehson_kassa_pul where kassa_id = v_kassa and pul_turi = v_t.pul_kod;
    end if;
    o_oldin := v_cur;
    v_farq := v_t.maqsad - v_cur;
    o_farq := v_farq;

    -- pul turi belgilanmagan (eski) qatorlardagi qoldiq bu hisobga kirmaydi — faqat eslatma
    select coalesce(sum(qoldiq), 0) into v_null from v_ehson_kassa_pul where kassa_id = v_kassa and pul_turi is null;
    if v_null <> 0 then
      o_eslatma := 'pul turi belgilanmagan qoldiq: ' || v_null::text;
    end if;

    if v_farq = 0 then
      perform _ehson_tarix_yoz('kassa', v_kassa, v_hodisa,
        jsonb_build_object('pul_turi', v_t.pul_kod, 'oldin', v_cur, 'maqsad', v_t.maqsad, 'farq', 0));
      o_holat := 'farq 0 — yozuv kerak emas'; return next; continue;
    end if;

    if v_t.valyuta = 'USD' then
      if v_kurs is null or v_kurs <= 0 then
        o_holat := 'O''TKAZILDI: USD kursi yoq (Valyuta bo''limida kurs kiriting, so''ng qayta RUN)'; return next; continue;
      end if;
      v_fc := v_farq;
      v_summa := round(v_farq * v_kurs);
      if v_summa = 0 then v_summa := sign(v_farq); end if;
    else
      v_fc := null;
      v_summa := v_farq;
    end if;

    insert into ehson_kirim (kassa_id, summa, sana, manba, izoh, created_by, pul_turi, valyuta, fc_summa, tur)
    values (v_kassa, v_summa, v_bugun, 'Balans to''g''irlash', v_izoh, null, v_t.pul_kod, v_t.valyuta, v_fc, 'tuzatish')
    returning id into v_id;

    perform _ehson_tarix_yoz('kirim', v_id, 'balans_togrilandi',
      jsonb_build_object('pul_turi', v_t.pul_kod, 'oldin', v_cur, 'maqsad', v_t.maqsad, 'farq', v_farq, 'summa', v_summa));
    perform _ehson_tarix_yoz('kassa', v_kassa, v_hodisa,
      jsonb_build_object('pul_turi', v_t.pul_kod, 'oldin', v_cur, 'maqsad', v_t.maqsad, 'farq', v_farq, 'kirim_id', v_id));

    o_holat := 'YOZILDI';
    return next;
  end loop;
  return;
end
$fn$;

-- Faqat SQL editor (postgres/service_role) — brauzerdan chaqirilmaydi
revoke all on function _ehson_balans_togrila_20261017() from public, anon, authenticated;

comment on function _ehson_balans_togrila_20261017() is
  'Bir martalik: 3 ehson kassa (asosiy/soliq/zakot) x naqd/dollar balansini maqsadga tenglaydi (tur=tuzatish). Idempotent (ehson_tarix belgisi).';

-- NATIJA JADVALI (har juftlik: oldin / maqsad / farq / holat)
select * from _ehson_balans_togrila_20261017();


-- #####################################################################
-- ##  6-BOLIM — PostgREST kesh + o'z-o'zini tekshiruv                 ##
-- #####################################################################
notify pgrst, 'reload schema';

do $ek_check$
begin
  if to_regprocedure('public.ehson_kirim_qolda(jsonb)') is null then raise exception 'ehson_kirim_qolda yaratilmadi'; end if;
  if to_regprocedure('public.ehson_pul_kirim_ok()') is null then raise exception 'ehson_pul_kirim_ok yaratilmadi'; end if;
  if not ('ehson_pul_kirim' = any(perm_pages())) then raise exception 'perm_pages() da ehson_pul_kirim yoq'; end if;
  if not ('ehson_kirim' = any(perm_pages())) then raise exception 'perm_pages() dan eski kalit tushib qoldi'; end if;
  if not exists (select 1 from information_schema.columns where table_name = 'ehson_kirim' and column_name = 'tur') then
    raise exception 'ehson_kirim.tur yoq';
  end if;
  if pg_get_functiondef('public.ehson_kirim_royxat(jsonb)'::regprocedure) not like '%''tur'', k.tur%' then
    raise exception 'ehson_kirim_royxat da tur yoq';
  end if;
  raise notice 'PROVODKA_EHSON_KIRIM.sql: hammasi joyida.';
end
$ek_check$;
