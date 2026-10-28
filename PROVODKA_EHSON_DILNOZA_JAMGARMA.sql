-- ============================================================================
--  PROVODKA_EHSON_DILNOZA_JAMGARMA.sql — Ehson jamg'armasi KO'P DARAJALI daraxt (2026-10-28, Asilbek)
--
--  Asilbek: «Dilnoza Nazarova uchun 3 ta child kassa, har biriga naqd/karta/$ turlari —
--  Dilnoza Nazarovaning o'zi jamg'arma bo'ladi».
--  Model: ildiz «Ehson jamg'armasi» (konteyner) -> child (konteyner BO'LISHI MUMKIN) -> ... -> BARG kassa -> pul turi.
--  Kirim / berish / qarz / o'tkazma / konvert FAQAT barg (is_container=false) kassada.
--
--  ADDITIVE: faqat `create or replace` (eski imzolar saqlangan), yangi yordamchi funksiyalar, bir migratsiya bloki.
--  Hech narsa drop / delete qilinmaydi. IDEMPOTENT: qayta RUN xavfsiz.
--  RUN tartibi: EHSON -> ZAKOT -> QARZ -> KIRIM -> TRANSFER -> KONVERT_QARZ_GURUH -> SHU fayl (eng oxirgi).
--  Eski fayllar (ZAKOT/TRANSFER) QAYTA RUN qilinsa — shu faylni ham qayta RUN qiling (ular eski funksiya tanasini qaytaradi).
--
--  BO'LIMLAR
--   1  old shart tekshiruvi
--   2  yordamchilar: _ehson_kassa_yol / _yol_matn / _modda_nom / _avlod / _json / _daraxt_tugun
--   3  _ehson_xarajat_modda (butun yo'l bilan nom, konteynerga modda ochilmaydi)
--   4  ehson_kassa_daraxt() — rekursiv daraxt ('kassalar' yassi ro'yxat + 'daraxt' ichma-ich, eski kalitlar saqlangan)
--   5  ehson_kassa_saqla(p) — parent_id / is_container / sikl himoyasi
--   6  ehson_pul_turi_saqla / ehson_dash / ehson_kirim_royxat / ehson_berish_royxat / ehson_transfer_royxat
--   7  MIGRATSIYA: «Dilnoza Nazarova» -> konteyner + 3 child (vaqtincha nomlar «Dilnoza Nazarova · 1/2/3»)
--   8  tekshiruv
--
--  O'ZGARTIRILMAGAN (allaqachon `is_container` ga tayanadi, ixtiyoriy chuqurlikda ishlaydi):
--   ehson_ber, ehson_kirim_qolda, ehson_qarz_ber, ehson_qarz_tolov, ehson_transfer_yoz, ehson_konvert_yoz -> kod 'kassa_konteyner'.
-- ============================================================================


-- #####################################################################
-- ##  1-BOLIM — OLD SHART TEKSHIRUVI                                  ##
-- #####################################################################
do $dj_pre$
begin
  if to_regclass('public.ehson_pul_turi') is null then
    raise exception 'ehson_pul_turi yoq — avval PROVODKA_EHSON_ZAKOT.sql ni bajaring';
  end if;
  if to_regclass('public.ehson_transfer') is null then
    raise exception 'ehson_transfer yoq — avval PROVODKA_EHSON_TRANSFER.sql ni bajaring';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'ehson_transfer' and column_name = 'to_summa') then
    raise exception 'ehson_transfer.to_summa yoq — avval PROVODKA_EHSON_KONVERT_QARZ_GURUH.sql ni bajaring';
  end if;
  if to_regclass('public.ehson_qarz') is null then
    raise exception 'ehson_qarz yoq — avval PROVODKA_EHSON_QARZ.sql ni bajaring';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'ehson_kirim' and column_name = 'tur') then
    raise exception 'ehson_kirim.tur yoq — avval PROVODKA_EHSON_KIRIM.sql ni bajaring';
  end if;
end
$dj_pre$;


-- #####################################################################
-- ##  2-BOLIM — YORDAMCHILAR (ichki; authenticated'ga yopiq)          ##
-- #####################################################################

-- Ildizdan shu kassagacha bo'lgan nomlar massivi. Child nomi ota nomi + ' · ' bilan boshlansa
-- («Dilnoza Nazarova · 1» ota «Dilnoza Nazarova» ostida) takror ko'rinmasin deb prefiks olib tashlanadi.
create or replace function _ehson_kassa_yol(p_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_arr  text[] := '{}';
  v_cur  uuid   := p_id;
  v_nom  text;
  v_par  uuid;
  v_pnom text;
  v_seen uuid[] := '{}';
begin
  while v_cur is not null and coalesce(array_length(v_seen, 1), 0) < 10 and not (v_cur = any(v_seen)) loop
    v_seen := v_seen || v_cur;
    select k.nom, k.parent_id into v_nom, v_par from ehson_kassa k where k.id = v_cur;
    exit when not found;
    if v_par is not null then
      select pk.nom into v_pnom from ehson_kassa pk where pk.id = v_par;
      if v_pnom is not null and length(v_nom) > length(v_pnom) + 3
         and left(v_nom, length(v_pnom) + 3) = v_pnom || ' · ' then
        v_nom := substr(v_nom, length(v_pnom) + 4);
      end if;
    end if;
    v_arr := array_prepend(v_nom, v_arr);
    v_cur := v_par;
  end loop;
  return v_arr;
end
$fn$;

revoke all on function _ehson_kassa_yol(uuid) from public, anon, authenticated;

-- UI uchun yo'l: ildiz KIRMAYDI («Dilnoza Nazarova › 1»); ildizning o'zi uchun uning nomi.
create or replace function _ehson_kassa_yol_matn(p_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_arr text[] := _ehson_kassa_yol(p_id);
begin
  if coalesce(array_length(v_arr, 1), 0) = 0 then return null; end if;
  if array_length(v_arr, 1) = 1 then return v_arr[1]; end if;
  return array_to_string(v_arr[2:array_length(v_arr, 1)], ' › ');
end
$fn$;

revoke all on function _ehson_kassa_yol_matn(uuid) from public, anon, authenticated;

-- O'zi + barcha avlodlari (DFS tartibida: tartib, nom). p_faol=true -> faqat faol zanjir
-- (nofaol tugun va uning ostidagilar tushmaydi). Chuqurlik 10 bilan cheklangan (sikl himoyasi).
create or replace function _ehson_kassa_avlod(p_id uuid, p_faol boolean default false)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $fn$
  with recursive t(id, d, ord) as (
    select k.id, 0,
           array[to_char(k.tartib + 100000, 'FM000000') || '|' || lower(k.nom) || '|' || k.id::text]
      from ehson_kassa k
     where k.id = p_id and (not p_faol or k.is_active)
    union all
    select c.id, t.d + 1,
           t.ord || (to_char(c.tartib + 100000, 'FM000000') || '|' || lower(c.nom) || '|' || c.id::text)
      from t
      join ehson_kassa c on c.parent_id = t.id
     where t.d < 10 and (not p_faol or c.is_active)
  )
  select coalesce(array_agg(t.id order by t.ord), '{}'::uuid[]) from t
$fn$;

revoke all on function _ehson_kassa_avlod(uuid, boolean) from public, anon, authenticated;

-- Bitta kassa (tugun) uchun JSON — daraxt() ning ham yassi, ham ichma-ich qismi shundan.
create or replace function _ehson_kassa_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select jsonb_build_object(
           'id', k.id, 'nom', k.nom, 'izoh', k.izoh, 'is_active', k.is_active, 'tartib', k.tartib,
           'parent_id', k.parent_id, 'is_container', k.is_container,
           'daraja', greatest(coalesce(array_length(_ehson_kassa_yol(k.id), 1), 1) - 1, 0),
           'yol', _ehson_kassa_yol_matn(k.id),
           'modda', case when a.id is not null then jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name) end,
           'qoldiq', coalesce(vk.qoldiq, 0),
           'pul_turlari', case when k.is_container then '[]'::jsonb else coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', pt.id, 'kod', pt.kod, 'nom', pt.nom, 'valyuta', pt.valyuta,
                      'is_active', pt.is_active, 'tartib', pt.tartib,
                      'qoldiq', coalesce(vp.qoldiq, 0), 'fc_qoldiq', coalesce(vp.fc_qoldiq, 0)
                    ) order by pt.tartib, pt.nom)
               from ehson_pul_turi pt
               left join v_ehson_kassa_pul vp on vp.kassa_id = pt.kassa_id and vp.pul_turi = pt.kod
              where pt.kassa_id = k.id and pt.is_active
           ), '[]'::jsonb) end
         )
    from ehson_kassa k
    left join accounts a on a.id = k.xarajat_account_id
    left join v_ehson_kassa vk on vk.id = k.id
   where k.id = p_id
$fn$;

revoke all on function _ehson_kassa_json(uuid) from public, anon, authenticated;

-- Tugun + childlar (rekursiv). jami_qoldiq = shu tugun va barcha faol avlodlari so'm ekvivalenti yig'indisi;
-- jami_fc_qoldiq = ulardagi USD pul turlari (dollar miqdori) yig'indisi.
create or replace function _ehson_daraxt_tugun(p_id uuid, p_d int default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_ids  uuid[] := _ehson_kassa_avlod(p_id, true);
  v_node jsonb  := _ehson_kassa_json(p_id);
  v_kids jsonb;
  v_jami numeric;
  v_fc   numeric;
begin
  if v_node is null then return null; end if;
  select coalesce(sum(vk.qoldiq), 0) into v_jami from v_ehson_kassa vk where vk.id = any(v_ids);
  select coalesce(sum(vp.fc_qoldiq), 0) into v_fc
    from v_ehson_kassa_pul vp where vp.kassa_id = any(v_ids) and vp.valyuta = 'USD';

  if p_d < 10 then
    select coalesce(jsonb_agg(_ehson_daraxt_tugun(c.id, p_d + 1) order by c.tartib, c.nom), '[]'::jsonb)
      into v_kids
      from ehson_kassa c where c.parent_id = p_id and c.is_active;
  else
    v_kids := '[]'::jsonb;
  end if;

  return v_node || jsonb_build_object('children', v_kids, 'jami_qoldiq', v_jami, 'jami_fc_qoldiq', v_fc);
end
$fn$;

revoke all on function _ehson_daraxt_tugun(uuid, int) from public, anon, authenticated;


-- #####################################################################
-- ##  3-BOLIM — _ehson_xarajat_modda: butun yo'l bilan nom             ##
-- #####################################################################
-- IMZO SAQLANADI (uuid -> uuid). Tana PROVODKA_EHSON_ZAKOT.sql dagi versiyadan verbatim, farqi:
--  (1) konteyner kassa va modda yo'q -> modda OCHILMAYDI (null qaytadi); ildizning eski moddasi bor — uni qaytaradi;
--  (2) chuqurligi 2+ bo'lgan kassa nomi butun yo'l bilan: «Ehson jamg'armasi · Dilnoza Nazarova · 1».
--      1-daraja child uchun eski qoida («<ildiz> · <child>») o'zgarmagan.
create or replace function _ehson_xarajat_modda(p_kassa uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_acc        uuid;
  v_nom        text;
  v_parent_id  uuid;
  v_parent_nom text;
  v_cont       boolean;
  v_yol        text[];
  v_max        int;
  v_code       text;
  v_modda_nom  text;
begin
  select k.xarajat_account_id, k.nom, k.parent_id, k.is_container into v_acc, v_nom, v_parent_id, v_cont
    from ehson_kassa k where k.id = p_kassa;

  if v_cont and v_acc is null then
    return null;
  end if;

  if v_parent_id is not null then
    select p.nom into v_parent_nom from ehson_kassa p where p.id = v_parent_id;
  end if;

  v_yol := _ehson_kassa_yol(p_kassa);

  if coalesce(array_length(v_yol, 1), 0) >= 3 then
    v_modda_nom := array_to_string(v_yol, ' · ');
  elsif v_parent_nom is not null then
    v_modda_nom := v_parent_nom || ' · ' || coalesce(v_nom, 'jamg''arma');
  elsif lower(coalesce(v_nom, '')) like '%ehson%' then
    v_modda_nom := v_nom;
  else
    v_modda_nom := 'Ehson: ' || coalesce(v_nom, 'jamg''arma');
  end if;

  if v_acc is not null and exists (select 1 from accounts a where a.id = v_acc and coalesce(a.is_active, true)) then
    update accounts set ehson_kassa_id = p_kassa where id = v_acc and ehson_kassa_id is distinct from p_kassa;
    return v_acc;
  end if;
  -- Nomi bo'yicha mavjud modda (qayta RUN / qo'lda ochilgan bo'lsa)
  select a.id into v_acc from accounts a
   where a.type = 'xarajat' and coalesce(a.is_active, true)
     and lower(a.name) = lower(v_modda_nom)
   limit 1;
  if v_acc is null then
    perform pg_advisory_xact_lock(hashtext('ehson_xarajat_modda'));
    select max(code::int) into v_max from accounts where code ~ '^94[0-9]{2}$';
    v_code := (coalesce(v_max, 9420) + 1)::text;
    if v_code::int > 9499 then
      raise exception 'Xarajat moddalari kod bloki (9421–9499) to''ldi';
    end if;
    insert into accounts (code, name, type, section, is_active, ehson_kassa_id)
    values (v_code, v_modda_nom, 'xarajat', 'operatsion', true, p_kassa)
    returning id into v_acc;
  end if;
  update accounts set ehson_kassa_id = p_kassa where id = v_acc and ehson_kassa_id is distinct from p_kassa;
  update ehson_kassa set xarajat_account_id = v_acc where id = p_kassa;
  return v_acc;
end
$fn$;

revoke all on function _ehson_xarajat_modda(uuid) from public, anon, authenticated;

comment on function _ehson_xarajat_modda(uuid) is
  'ICHKI: jamg''arma uchun xarajat moddasi (94xx) — bor bo''lsa qaytaradi, yo''q bo''lsa ochadi. Konteynerga (moddasi yo''q bo''lsa) ochmaydi. '
  'Chuqurligi 2+ kassa nomi butun yo''l bilan ("<ildiz> · <konteyner> · <child>"); 1-daraja child "<ildiz> · <child>".';


-- #####################################################################
-- ##  4-BOLIM — ehson_kassa_daraxt(): rekursiv daraxt                  ##
-- #####################################################################
-- ESKI KALITLAR SAQLANGAN: 'ildiz' {id,nom}, 'kassalar'[] (faol BARG kassalar; endi har darajadan, ildiz tartibida)
-- har elementda eski maydonlar (id, nom, izoh, is_active, tartib, modda, qoldiq, pul_turlari) o'zgarmagan.
-- YANGI: kassalar[].parent_id/is_container/daraja/yol; 'daraxt' = ildiz tugun, ichma-ich 'children'[]
-- (har tugunda jami_qoldiq / jami_fc_qoldiq); 'versiya' = 2.
create or replace function ehson_kassa_daraxt()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_root  ehson_kassa;
  v_ids   uuid[];
  v_list  jsonb;
  v_tree  jsonb;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not (ehson_page_ok() or ehson_kirim_ok()) then
    raise exception 'Ehson kaskadini ko''rish ruxsatingizda yo''q' using errcode = '42501';
  end if;

  select * into v_root from ehson_kassa
   where is_container and is_active and parent_id is null
   order by created_at limit 1;

  if v_root.id is not null then
    v_ids  := _ehson_kassa_avlod(v_root.id, true);
    v_tree := _ehson_daraxt_tugun(v_root.id, 0);
  else
    select coalesce(array_agg(k.id order by k.tartib, k.nom), '{}'::uuid[]) into v_ids
      from ehson_kassa k where k.is_active;
  end if;

  select coalesce(jsonb_agg(_ehson_kassa_json(x.id) order by x.ord), '[]'::jsonb)
    into v_list
    from unnest(v_ids) with ordinality as x(id, ord)
    join ehson_kassa k on k.id = x.id
   where not k.is_container;

  return jsonb_build_object(
    'ildiz', case when v_root.id is not null then jsonb_build_object('id', v_root.id, 'nom', v_root.nom) end,
    'kassalar', v_list,
    'daraxt', v_tree,
    'versiya', 2
  );
end
$fn$;

revoke all on function ehson_kassa_daraxt() from public, anon;
grant execute on function ehson_kassa_daraxt() to authenticated;

comment on function ehson_kassa_daraxt() is
  'Professional/Ehson kaskadi: ildiz + kassalar[] (faol BARG kassalar, yol bilan) + daraxt (ichma-ich children[], jami_qoldiq). Ruxsat: ehson_page_ok() YOKI ehson_kirim_ok().';


-- #####################################################################
-- ##  5-BOLIM — ehson_kassa_saqla(p): parent_id / is_container         ##
-- #####################################################################
-- Admin. p: {id?, nom, izoh?, is_active?, tartib?, parent_id?, is_container?}
-- YANGI (id yo'q): parent_id berilmasa = ildiz (eski xatti-harakat); parent faol KONTEYNER bo'lishi shart;
--   is_container=true -> konteyner (modda va pul turlari ochilmaydi), aks holda barg: modda + 4 sukut pul turi.
-- TAHRIR (id bor): nom/izoh/is_active/tartib; parent_id boshqa bo'lsa ko'chiriladi (sikl himoyasi, ildiz ko'chmaydi);
--   is_container o'zgarsa: barg->konteyner faqat balans 0, faol pul turi YO'Q, faol qarz YO'Q, moddada jurnal yozuvi YO'Q;
--   konteyner->barg faqat child YO'Q bo'lsa. Nom unikal ota kesimida. Deaktiv faqat qoldiq 0; konteynerda faol child bo'lmasa.
-- kod: nom_kerak · topilmadi · takror · ildiz_topilmadi · parent_topilmadi · parent_konteyner_emas · parent_nofaol · sikl ·
--      ildiz_ozgarmaydi · chuqurlik · kassa_konteyner · farzand_faol · farzand_bor · pul_turi_faol · qoldiq_bor · qarz_bor · modda_yozuv_bor
create or replace function ehson_kassa_saqla(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid        uuid    := auth.uid();
  v_id         uuid    := nullif(p->>'id', '')::uuid;
  v_nom        text    := nullif(btrim(coalesce(p->>'nom', '')), '');
  v_izoh       text    := nullif(btrim(coalesce(p->>'izoh', '')), '');
  v_active     boolean := coalesce((p->>'is_active')::boolean, true);
  v_tartib     int     := coalesce(nullif(p->>'tartib', '')::int, 0);
  v_has_parent boolean := (p ? 'parent_id');
  v_parent     uuid    := nullif(p->>'parent_id', '')::uuid;
  v_has_cont   boolean := (p ? 'is_container');
  v_cont       boolean := coalesce((p->>'is_container')::boolean, false);
  v_root       uuid;
  v_row        ehson_kassa;
  v_par        ehson_kassa;
  v_new_parent uuid;
  v_new_cont   boolean;
  v_qoldiq     numeric;
  v_x          uuid;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not _ehson_is_admin() then
    raise exception 'Faqat admin jamg''arma kassalarini boshqaradi' using errcode = '42501';
  end if;
  if v_nom is null then
    return jsonb_build_object('ok', false, 'kod', 'nom_kerak');
  end if;

  if v_id is not null then
    select * into v_row from ehson_kassa where id = v_id;
    if not found then
      return jsonb_build_object('ok', false, 'kod', 'topilmadi');
    end if;

    -- ota: ko'chirish faqat boshqa ota berilganda
    v_new_parent := v_row.parent_id;
    if v_has_parent and v_parent is distinct from v_row.parent_id then
      if v_row.parent_id is null then
        return jsonb_build_object('ok', false, 'kod', 'ildiz_ozgarmaydi');
      end if;
      if v_parent is null then
        return jsonb_build_object('ok', false, 'kod', 'parent_topilmadi');
      end if;
      select * into v_par from ehson_kassa where id = v_parent;
      if not found then
        return jsonb_build_object('ok', false, 'kod', 'parent_topilmadi');
      end if;
      if v_parent = v_id or v_parent = any(_ehson_kassa_avlod(v_id)) then
        return jsonb_build_object('ok', false, 'kod', 'sikl');
      end if;
      if not v_par.is_container then
        return jsonb_build_object('ok', false, 'kod', 'parent_konteyner_emas');
      end if;
      if not v_par.is_active then
        return jsonb_build_object('ok', false, 'kod', 'parent_nofaol');
      end if;
      if coalesce(array_length(_ehson_kassa_yol(v_parent), 1), 0) >= 6 then
        return jsonb_build_object('ok', false, 'kod', 'chuqurlik');
      end if;
      v_new_parent := v_parent;
    end if;

    if v_new_parent is not null and exists (
      select 1 from ehson_kassa
       where id <> v_id and parent_id = v_new_parent and lower(nom) = lower(v_nom)
    ) then
      return jsonb_build_object('ok', false, 'kod', 'takror');
    end if;

    -- konteyner belgisi
    v_new_cont := v_row.is_container;
    if v_has_cont and v_cont <> v_row.is_container then
      if v_row.parent_id is null then
        return jsonb_build_object('ok', false, 'kod', 'ildiz_ozgarmaydi');
      end if;
      if v_cont then
        if exists (select 1 from ehson_pul_turi where kassa_id = v_id and is_active) then
          return jsonb_build_object('ok', false, 'kod', 'pul_turi_faol');
        end if;
        select qoldiq into v_qoldiq from v_ehson_kassa where id = v_id;
        if coalesce(v_qoldiq, 0) <> 0 or exists (
          select 1 from v_ehson_kassa_pul where kassa_id = v_id
             and (coalesce(qoldiq, 0) <> 0 or coalesce(fc_qoldiq, 0) <> 0)
        ) then
          return jsonb_build_object('ok', false, 'kod', 'qoldiq_bor');
        end if;
        if exists (select 1 from ehson_qarz where kassa_id = v_id and holat = 'faol') then
          return jsonb_build_object('ok', false, 'kod', 'qarz_bor');
        end if;
        if v_row.xarajat_account_id is not null
           and exists (select 1 from entry_line where account_id = v_row.xarajat_account_id) then
          return jsonb_build_object('ok', false, 'kod', 'modda_yozuv_bor');
        end if;
      else
        if exists (select 1 from ehson_kassa where parent_id = v_id) then
          return jsonb_build_object('ok', false, 'kod', 'farzand_bor');
        end if;
      end if;
      v_new_cont := v_cont;
    end if;

    if v_row.is_active and not v_active then
      if v_new_cont then
        if v_row.parent_id is null then
          return jsonb_build_object('ok', false, 'kod', 'kassa_konteyner');
        end if;
        if exists (select 1 from ehson_kassa where parent_id = v_id and is_active) then
          return jsonb_build_object('ok', false, 'kod', 'farzand_faol');
        end if;
      end if;
      select qoldiq into v_qoldiq from v_ehson_kassa where id = v_id;
      if coalesce(v_qoldiq, 0) <> 0 then
        return jsonb_build_object('ok', false, 'kod', 'qoldiq_bor');
      end if;
    end if;
    if v_new_cont and v_row.parent_id is null and not v_active then
      return jsonb_build_object('ok', false, 'kod', 'kassa_konteyner');
    end if;
    if not v_row.is_active and v_active and v_new_parent is not null
       and not exists (select 1 from ehson_kassa where id = v_new_parent and is_active) then
      return jsonb_build_object('ok', false, 'kod', 'parent_nofaol');
    end if;

    -- barg -> konteyner: moddani ajratib, nofaol qilamiz (unda jurnal yozuvi yo'qligi yuqorida tekshirilgan)
    if v_new_cont and not v_row.is_container and v_row.xarajat_account_id is not null then
      update accounts set is_active = false where id = v_row.xarajat_account_id;
      update ehson_kassa set xarajat_account_id = null where id = v_id;
    end if;

    update ehson_kassa
       set nom = v_nom, izoh = v_izoh, is_active = v_active,
           tartib = case when p ? 'tartib' then v_tartib else tartib end,
           parent_id = v_new_parent, is_container = v_new_cont
     where id = v_id;

    if not v_new_cont then
      perform _ehson_xarajat_modda(v_id);
      -- konteyner -> barg: sukut pul turlari
      if v_row.is_container then
        insert into ehson_pul_turi (kassa_id, kod, nom, valyuta, tartib)
        select v_id, x.kod, x.nom, x.valyuta, x.tartib
          from (values
            ('naqd',   'Naqd',   'UZS', 1),
            ('dollar', 'Dollar', 'USD', 2),
            ('karta',  'Karta',  'UZS', 3),
            ('click',  'Click',  'UZS', 4)
          ) as x(kod, nom, valyuta, tartib)
         on conflict (kassa_id, kod) do nothing;
      end if;
    end if;

    -- nom/ota o'zgarsa chuqurligi 2+ moddalar nomi yo'lga moslanadi (1-daraja moddalar nomiga tegilmaydi)
    if v_nom is distinct from v_row.nom or v_new_parent is distinct from v_row.parent_id then
      for v_x in select unnest(_ehson_kassa_avlod(v_id)) loop
        if coalesce(array_length(_ehson_kassa_yol(v_x), 1), 0) >= 3 then
          update accounts a
             set name = array_to_string(_ehson_kassa_yol(v_x), ' · ')
            from ehson_kassa k
           where k.id = v_x and a.id = k.xarajat_account_id and not k.is_container;
        end if;
      end loop;
    end if;

    perform _ehson_tarix_yoz('kassa', v_id, 'yangilandi', p);
    return jsonb_build_object('ok', true, 'id', v_id);
  end if;

  -- YANGI
  if v_parent is null then
    select id into v_root from ehson_kassa
     where is_container and is_active and parent_id is null order by created_at limit 1;
    v_parent := v_root;
  end if;
  if v_parent is null then
    return jsonb_build_object('ok', false, 'kod', 'ildiz_topilmadi');
  end if;
  select * into v_par from ehson_kassa where id = v_parent;
  if not found then
    return jsonb_build_object('ok', false, 'kod', 'parent_topilmadi');
  end if;
  if not v_par.is_container then
    return jsonb_build_object('ok', false, 'kod', 'parent_konteyner_emas');
  end if;
  if not v_par.is_active then
    return jsonb_build_object('ok', false, 'kod', 'parent_nofaol');
  end if;
  if coalesce(array_length(_ehson_kassa_yol(v_parent), 1), 0) >= 6 then
    return jsonb_build_object('ok', false, 'kod', 'chuqurlik');
  end if;
  if exists (select 1 from ehson_kassa where parent_id = v_parent and lower(nom) = lower(v_nom)) then
    return jsonb_build_object('ok', false, 'kod', 'takror');
  end if;

  insert into ehson_kassa (nom, izoh, is_active, parent_id, is_container, tartib, created_by)
  values (v_nom, v_izoh, v_active, v_parent, v_cont, v_tartib, v_uid)
  returning id into v_id;

  if not v_cont then
    perform _ehson_xarajat_modda(v_id);

    insert into ehson_pul_turi (kassa_id, kod, nom, valyuta, tartib)
    select v_id, x.kod, x.nom, x.valyuta, x.tartib
      from (values
        ('naqd',   'Naqd',   'UZS', 1),
        ('dollar', 'Dollar', 'USD', 2),
        ('karta',  'Karta',  'UZS', 3),
        ('click',  'Click',  'UZS', 4)
      ) as x(kod, nom, valyuta, tartib)
     on conflict (kassa_id, kod) do nothing;
  end if;

  perform _ehson_tarix_yoz('kassa', v_id, 'yaratildi', p);
  return jsonb_build_object('ok', true, 'id', v_id);
end
$fn$;

revoke all on function ehson_kassa_saqla(jsonb) from public, anon;
grant execute on function ehson_kassa_saqla(jsonb) to authenticated;

comment on function ehson_kassa_saqla(jsonb) is
  'Admin: jamg''arma kassa qo''shish/tahrir (ko''p darajali). Yangi -> parent_id (sukut ildiz, konteyner bo''lishi shart), is_container ixtiyoriy; '
  'barg bo''lsa modda + 4 sukut pul turi. Tahrirda ko''chirish (sikl himoyasi) va konteyner belgisi o''zgartirish (shartlar bilan). Deaktiv faqat qoldiq 0.';


-- #####################################################################
-- ##  6-BOLIM — qolgan RPC'lar (tanalar ENG OXIRGI versiyadan verbatim) ##
-- #####################################################################

-- 6.1 ehson_pul_turi_saqla — faqat konteynerga yangi pul turi qo'shishda kod 'kassa_konteyner' (avval 'kassa_topilmadi')
create or replace function ehson_pul_turi_saqla(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid    := auth.uid();
  v_id     uuid    := nullif(p->>'id', '')::uuid;
  v_kassa  uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_kod    text    := lower(nullif(btrim(coalesce(p->>'kod', '')), ''));
  v_nom    text    := nullif(btrim(coalesce(p->>'nom', '')), '');
  v_val    text    := coalesce(nullif(upper(btrim(coalesce(p->>'valyuta', ''))), ''), 'UZS');
  v_active boolean := coalesce((p->>'is_active')::boolean, true);
  v_tartib int     := coalesce(nullif(p->>'tartib', '')::int, 0);
  v_row    ehson_pul_turi;
  v_qoldiq numeric;
  v_fc     numeric;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not _ehson_is_admin() then
    raise exception 'Faqat admin pul turlarini boshqaradi' using errcode = '42501';
  end if;
  if v_nom is null then
    return jsonb_build_object('ok', false, 'kod', 'nom_kerak');
  end if;

  if v_id is not null then
    select * into v_row from ehson_pul_turi where id = v_id;
    if not found then
      return jsonb_build_object('ok', false, 'kod', 'topilmadi');
    end if;
    if v_row.is_active and not v_active then
      select qoldiq, fc_qoldiq into v_qoldiq, v_fc
        from v_ehson_kassa_pul where kassa_id = v_row.kassa_id and pul_turi = v_row.kod;
      if coalesce(v_qoldiq, 0) <> 0 or coalesce(v_fc, 0) <> 0 then
        return jsonb_build_object('ok', false, 'kod', 'qoldiq_bor');
      end if;
    end if;

    update ehson_pul_turi set nom = v_nom, valyuta = v_val, is_active = v_active, tartib = v_tartib
     where id = v_id;

    perform _ehson_tarix_yoz('pul_turi', v_id, 'yangilandi', p);
    return jsonb_build_object('ok', true, 'id', v_id);
  end if;

  if v_kassa is null then
    return jsonb_build_object('ok', false, 'kod', 'kassa_kerak');
  end if;
  if not exists (select 1 from ehson_kassa where id = v_kassa) then
    return jsonb_build_object('ok', false, 'kod', 'kassa_topilmadi');
  end if;
  if exists (select 1 from ehson_kassa where id = v_kassa and is_container) then
    return jsonb_build_object('ok', false, 'kod', 'kassa_konteyner');
  end if;
  if v_kod is null or v_kod !~ '^[a-z_]{2,20}$' then
    return jsonb_build_object('ok', false, 'kod', 'kod_notogri');
  end if;
  if exists (select 1 from ehson_pul_turi where kassa_id = v_kassa and kod = v_kod) then
    return jsonb_build_object('ok', false, 'kod', 'takror');
  end if;

  insert into ehson_pul_turi (kassa_id, kod, nom, valyuta, is_active, tartib, created_by)
  values (v_kassa, v_kod, v_nom, v_val, v_active, v_tartib, v_uid)
  returning id into v_id;

  perform _ehson_tarix_yoz('pul_turi', v_id, 'yaratildi', p);
  return jsonb_build_object('ok', true, 'id', v_id);
end
$fn$;

revoke all on function ehson_pul_turi_saqla(jsonb) from public, anon;
grant execute on function ehson_pul_turi_saqla(jsonb) to authenticated;

-- 6.2 ehson_dash — kassalar[] ga yol/daraja qo'shildi (qolgan kalitlar o'zgarmagan)
create or replace function ehson_dash()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_uid        uuid := auth.uid();
  v_kassalar   jsonb;
  v_moddalar   jsonb;
  v_oila_holat jsonb;
  v_muhtojlik  jsonb;
  v_bu_oy      date := date_trunc('month', (now() at time zone 'Asia/Tashkent'))::date;
  v_oy_reja    numeric;
  v_oy_fakt    numeric;
  v_jami_yil   numeric;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', k.id, 'nom', k.nom, 'is_active', k.is_active,
           'kirim', vk.kirim, 'berildi', vk.berildi, 'qoldiq', vk.qoldiq,
           'parent_id', k.parent_id, 'is_container', k.is_container, 'tartib', k.tartib,
           'yol', _ehson_kassa_yol_matn(k.id),
           'daraja', greatest(coalesce(array_length(_ehson_kassa_yol(k.id), 1), 1) - 1, 0),
           'pul_turlari', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'kod', pt.kod, 'nom', pt.nom, 'valyuta', pt.valyuta,
                      'qoldiq', coalesce(vp.qoldiq, 0), 'fc_qoldiq', coalesce(vp.fc_qoldiq, 0)
                    ) order by pt.tartib, pt.nom)
               from ehson_pul_turi pt
               left join v_ehson_kassa_pul vp on vp.kassa_id = pt.kassa_id and vp.pul_turi = pt.kod
              where pt.kassa_id = k.id and pt.is_active
           ), '[]'::jsonb)
         ) order by k.tartib, k.nom), '[]'::jsonb)
    into v_kassalar
    from ehson_kassa k
    join v_ehson_kassa vk on vk.id = k.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'kassa_id', k.id, 'id', a.id, 'code', a.code, 'name', a.name
         ) order by a.code), '[]'::jsonb)
    into v_moddalar
    from ehson_kassa k join accounts a on a.id = k.xarajat_account_id;

  select coalesce(jsonb_object_agg(holat, soni), '{}'::jsonb)
    into v_oila_holat
    from (select holat, count(*) as soni from ehson_oila group by holat) x;

  select coalesce(jsonb_object_agg(coalesce(muhtojlik_daraja, 'belgilanmagan'), soni), '{}'::jsonb)
    into v_muhtojlik
    from (
      select muhtojlik_daraja, count(*) as soni
        from ehson_oila where holat <> 'yopildi'
       group by muhtojlik_daraja
    ) x;

  select coalesce(sum(oylik_summa), 0) into v_oy_reja
    from ehson_reja where holat = 'faol';

  select coalesce(sum(summa), 0) into v_oy_fakt
    from ehson_berish
   where holat = 'berildi' and date_trunc('month', sana) = v_bu_oy;

  select coalesce(sum(summa), 0) into v_jami_yil
    from ehson_berish
   where holat = 'berildi'
     and date_trunc('year', sana) = date_trunc('year', (now() at time zone 'Asia/Tashkent'));

  return jsonb_build_object(
    'kassalar',      v_kassalar,
    'moddalar',      v_moddalar,
    'oilalar_holat', v_oila_holat,
    'muhtojlik',     v_muhtojlik,
    'bu_oy_reja',    v_oy_reja,
    'bu_oy_fakt',    v_oy_fakt,
    'jami_oy',       v_oy_fakt,
    'jami_yil',      v_jami_yil
  );
end
$fn$;

revoke all on function ehson_dash() from public, anon;
grant execute on function ehson_dash() to authenticated;

-- 6.3 ehson_kirim_royxat — kassa filtri konteyner bo'lsa barcha avlodlar; qatorga kassa_yol (PROVODKA_EHSON_KIRIM.sql versiyasi)
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
     and (v_kassa is null or k.kassa_id = any(_ehson_kassa_avlod(v_kassa)))
     and (v_pt    is null or k.pul_turi = v_pt)
     and (v_q is null or k.manba ilike '%' || v_q || '%' or k.izoh ilike '%' || v_q || '%'
                      or pa.name ilike '%' || v_q || '%');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', k.id, 'sana', k.sana, 'summa', k.summa, 'manba', k.manba, 'izoh', k.izoh,
           'kassa_id', k.kassa_id, 'kassa_nom', ks.nom, 'kassa_yol', _ehson_kassa_yol_matn(k.kassa_id),
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
         and (v_kassa is null or k.kassa_id = any(_ehson_kassa_avlod(v_kassa)))
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

-- 6.4 ehson_berish_royxat — xuddi shunday
create or replace function ehson_berish_royxat(p jsonb default '{}'::jsonb)
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
  v_oila   uuid    := nullif(p->>'oila_id', '')::uuid;
  v_tur    text    := nullif(p->>'tur', '');
  v_holat  text    := nullif(p->>'holat', '');
  v_kim    uuid    := nullif(p->>'kim', '')::uuid;
  v_kassa  uuid    := nullif(p->>'kassa_id', '')::uuid;
  v_pt     text    := nullif(p->>'pul_turi', '');
  v_q      text    := nullif(btrim(coalesce(p->>'q', '')), '');
  v_limit  int     := greatest(1, least(coalesce(nullif(p->>'limit', '')::int, 50), 200));
  v_offset int     := greatest(0, coalesce(nullif(p->>'offset', '')::int, 0));
  v_rows   jsonb;
  v_jami   int;
  v_summa  numeric;
  v_tur_j  jsonb;
  v_masul  jsonb;
  v_ids    uuid[];
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if not ehson_page_ok() then
    raise exception 'Ehson sahifasi ruxsatingizda yo''q' using errcode = '42501';
  end if;
  if v_tur is not null and v_tur not in ('pul','oziq_ovqat','kiyim','dori','boshqa') then
    return jsonb_build_object('ok', false, 'kod', 'tur_notogri');
  end if;
  if v_holat is not null and v_holat not in ('berildi','bekor') then
    return jsonb_build_object('ok', false, 'kod', 'holat_notogri');
  end if;

  select coalesce(array_agg(b.id), '{}'::uuid[]) into v_ids
    from ehson_berish b
    join ehson_oila o on o.id = b.oila_id
   where (v_from  is null or b.sana >= v_from)
     and (v_to    is null or b.sana <= v_to)
     and (v_oila  is null or b.oila_id = v_oila)
     and (v_tur   is null or b.tur = v_tur)
     and (v_holat is null or b.holat = v_holat)
     and (v_kim   is null or b.created_by = v_kim)
     and (v_kassa is null or b.kassa_id = any(_ehson_kassa_avlod(v_kassa)))
     and (v_pt    is null or b.pul_turi = v_pt)
     and (v_q is null or o.fio ilike '%' || v_q || '%' or o.oila_kod ilike '%' || v_q || '%'
                      or b.izoh ilike '%' || v_q || '%');

  select count(*), coalesce(sum(b.summa) filter (where b.holat = 'berildi'), 0)
    into v_jami, v_summa
    from ehson_berish b where b.id = any(v_ids);

  select coalesce(jsonb_object_agg(tur, s), '{}'::jsonb) into v_tur_j
    from (select b.tur, sum(b.summa) as s
            from ehson_berish b where b.id = any(v_ids)
             and b.holat = 'berildi' group by b.tur) x;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom) order by nom), '[]'::jsonb) into v_masul
    from (select distinct b.created_by as id,
                 coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') as nom
            from ehson_berish b
            left join profiles pr on pr.id = b.created_by
           where b.created_by is not null) m;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'sana', b.sana, 'summa', b.summa, 'tur', b.tur, 'izoh', b.izoh,
           'holat', b.holat, 'reja_id', b.reja_id, 'oila_id', b.oila_id,
           'oila_kod', o.oila_kod, 'fio', o.fio,
           'kassa_id', b.kassa_id, 'kassa_nom', ks.nom, 'kassa_yol', _ehson_kassa_yol_matn(b.kassa_id),
           'pul_turi', b.pul_turi, 'valyuta', b.valyuta, 'fc_summa', b.fc_summa,
           'kim', coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum'),
           'created_at', b.created_at, 'keyingi_korib_chiqish', b.keyingi_korib_chiqish,
           'bekor_sabab', case when b.holat = 'bekor' then b.bekor_sabab end,
           'bekor_kim', case when b.holat = 'bekor' then coalesce(nullif(btrim(pd.full_name), ''), 'Noma''lum') end,
           'deleted_at', b.deleted_at
         ) order by b.sana desc, b.created_at desc), '[]'::jsonb)
    into v_rows
    from (
      select b.* from ehson_berish b where b.id = any(v_ids)
       order by b.sana desc, b.created_at desc
       limit v_limit offset v_offset
    ) b
    join ehson_oila o on o.id = b.oila_id
    left join ehson_kassa ks on ks.id = b.kassa_id
    left join profiles pr on pr.id = b.created_by
    left join profiles pd on pd.id = b.deleted_by;

  return jsonb_build_object('rows', coalesce(v_rows, '[]'::jsonb), 'jami', v_jami,
                            'jami_summa', v_summa, 'tur_jami', v_tur_j, 'masullar', v_masul);
end
$fn$;

revoke all on function ehson_berish_royxat(jsonb) from public, anon;
grant execute on function ehson_berish_royxat(jsonb) to authenticated;

-- 6.5 ehson_transfer_royxat — filtr avlodlar bo'yicha; from_kassa_yol / to_kassa_yol (PROVODKA_EHSON_KONVERT_QARZ_GURUH.sql versiyasi)
create or replace function ehson_transfer_royxat(p jsonb default '{}'::jsonb)
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
  v_turi   text    := nullif(p->>'turi', '');
  v_limit  int     := greatest(1, least(coalesce(nullif(p->>'limit', '')::int, 50), 200));
  v_offset int     := greatest(0, coalesce(nullif(p->>'offset', '')::int, 0));
  v_rows   jsonb; v_jami int;
begin
  if v_uid is null or not ehson_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  with f as (
    select t.*,
           fk.nom as from_kassa_nom, tk.nom as to_kassa_nom,
           (select pt.nom from ehson_pul_turi pt where pt.kassa_id = t.from_kassa_id and pt.kod = t.from_pul_turi) as from_pul_nom,
           (select pt.nom from ehson_pul_turi pt where pt.kassa_id = t.to_kassa_id   and pt.kod = t.to_pul_turi)   as to_pul_nom
      from ehson_transfer t
      join ehson_kassa fk on fk.id = t.from_kassa_id
      join ehson_kassa tk on tk.id = t.to_kassa_id
     where (v_from is null or t.sana >= v_from)
       and (v_to   is null or t.sana <= v_to)
       and (v_bekor or not t.is_deleted)
       and (v_kassa is null or t.from_kassa_id = any(_ehson_kassa_avlod(v_kassa)) or t.to_kassa_id = any(_ehson_kassa_avlod(v_kassa)))
       and (v_turi is null or t.turi = v_turi)
       and (v_q is null or fk.nom ilike '%' || v_q || '%' or tk.nom ilike '%' || v_q || '%' or coalesce(t.izoh, '') ilike '%' || v_q || '%')
  )
  select coalesce((
           select jsonb_agg(jsonb_build_object(
                    'id', x.id, 'sana', x.sana, 'turi', x.turi,
                    'from_kassa_id', x.from_kassa_id, 'from_kassa_nom', x.from_kassa_nom, 'from_kassa_yol', _ehson_kassa_yol_matn(x.from_kassa_id), 'from_pul_turi', x.from_pul_turi, 'from_pul_nom', x.from_pul_nom,
                    'to_kassa_id',   x.to_kassa_id,   'to_kassa_nom',   x.to_kassa_nom, 'to_kassa_yol', _ehson_kassa_yol_matn(x.to_kassa_id),   'to_pul_turi',   x.to_pul_turi,   'to_pul_nom',   x.to_pul_nom,
                    'valyuta', x.valyuta, 'summa', x.summa, 'fc_summa', x.fc_summa,
                    'kurs', x.kurs, 'to_valyuta', coalesce(x.to_valyuta, x.valyuta), 'to_summa', coalesce(x.to_summa, x.summa),
                    'to_fc_summa', case when coalesce(x.to_valyuta, x.valyuta) = 'USD' then coalesce(x.to_fc_summa, x.fc_summa) end,
                    'izoh', x.izoh,
                    'kim', (select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = x.created_by),
                    'created_at', x.created_at, 'is_deleted', x.is_deleted, 'deleted_at', x.deleted_at, 'bekor_sabab', x.bekor_sabab,
                    'bekor_kim', (select coalesce(nullif(btrim(pr.full_name), ''), 'Noma''lum') from profiles pr where pr.id = x.deleted_by)
                  ) order by x.sana desc, x.created_at desc)
             from (select * from f order by sana desc, created_at desc limit v_limit offset v_offset) x
         ), '[]'::jsonb),
         (select count(*) from f)
    into v_rows, v_jami;

  return jsonb_build_object('ok', true, 'rows', v_rows, 'jami', v_jami);
end
$fn$;

revoke all on function ehson_transfer_royxat(jsonb) from public, anon;
grant execute on function ehson_transfer_royxat(jsonb) to authenticated;


-- #####################################################################
-- ##  7-BOLIM — MIGRATSIYA: «Dilnoza Nazarova» -> konteyner + 3 child  ##
-- #####################################################################
-- Asilbek nomlarni aytmadi -> VAQTINCHA «Dilnoza Nazarova · 1», «· 2», «· 3» (admin UI «Jamg'arma kassalari»da qayta nomlanadi).
-- Dilnozaning MAVJUD yozuvlari (kirim, berish, qarz, to'lov, o'tkazma/konvert, pul turlari) 1-childga KO'CHIRILADI; eski moddasi (94xx)
-- ham 1-childga o'tadi (jurnal -> ehson_kirim sinxroni buzilmasin), konteynerda modda qolmaydi.
-- Qayta RUN: Dilnoza allaqachon konteyner bo'lsa ko'chirish ham, qayta nomlash ham QILINMAYDI (faqat yetishmagan childlar qo'shiladi).
do $dj_mig$
declare
  v_root    uuid;
  v_dil     ehson_kassa;
  v_k1      uuid;
  v_kid     uuid;
  v_n       int;
  v_cnt     int;
  v_f       record;
  v_i       int;
  v_nom     text;
  v_acc     uuid;
  v_mname   text;
begin
  select id into v_root from ehson_kassa
   where is_container and is_active and parent_id is null order by created_at limit 1;
  if v_root is null then
    raise notice 'Ildiz (konteyner) jamg''arma topilmadi — Dilnoza migratsiyasi o''tkazib yuborildi';
    return;
  end if;

  select * into v_dil from ehson_kassa
   where parent_id = v_root and lower(btrim(nom)) = 'dilnoza nazarova'
   order by created_at limit 1;
  if v_dil.id is null then
    raise notice '«Dilnoza Nazarova» kassasi topilmadi — avval PROVODKA_EHSON_TRANSFER.sql; migratsiya o''tkazib yuborildi';
    return;
  end if;

  -- 3 ta child — FAQAT Dilnozaning childi hali yo'q bo'lsa (admin qayta nomlagan/o'chirgan bo'lsa qayta RUN ularni tiklamaydi)
  if not exists (select 1 from ehson_kassa where parent_id = v_dil.id) then
    for v_i in 1..3 loop
      v_nom := v_dil.nom || ' · ' || v_i;
      insert into ehson_kassa (nom, is_active, parent_id, is_container, tartib)
      values (v_nom, true, v_dil.id, false, v_i);
      raise notice 'Child yaratildi: %', v_nom;
    end loop;
  end if;

  select id into v_k1 from ehson_kassa
   where parent_id = v_dil.id and not is_container
   order by tartib, created_at limit 1;
  if v_k1 is null then
    raise notice '«%» ostida barg child topilmadi — migratsiya o''tkazib yuborildi', v_dil.nom;
    return;
  end if;

  if not v_dil.is_container then
    -- a) mavjud yozuvlar -> 1-child (FK bo'yicha avtomatik: kirim, berish, qarz, qarz_tolov, transfer from/to, pul turi)
    for v_f in
      select c.conrelid::regclass::text as tbl, a.attname as col
        from pg_constraint c
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
       where c.contype = 'f' and c.confrelid = 'public.ehson_kassa'::regclass
         and array_length(c.conkey, 1) = 1
         and c.conrelid <> 'public.ehson_kassa'::regclass
       order by 1, 2
    loop
      execute format('update %s set %I = $1 where %I = $2', v_f.tbl, v_f.col, v_f.col) using v_k1, v_dil.id;
      get diagnostics v_n = row_count;
      if v_n > 0 then
        raise notice 'Dilnoza yozuvlari 1-childga ko''chirildi: % . % = % ta', v_f.tbl, v_f.col, v_n;
      end if;
    end loop;

    -- jurnaldan kelgan kirimlarning ext_ref'idagi kassa uuid'si yangilanadi (tartib uchun; sinxron entry_id+kassa_id bo'yicha)
    update ehson_kirim
       set ext_ref = replace(ext_ref, v_dil.id::text, v_k1::text)
     where kassa_id = v_k1 and ext_ref like 'entry:%:' || v_dil.id::text;

    -- b) eski modda -> 1-child (nomi butun yo'l bilan)
    if v_dil.xarajat_account_id is not null then
      v_acc := v_dil.xarajat_account_id;
      update ehson_kassa set xarajat_account_id = null where id = v_dil.id;
      update ehson_kassa set xarajat_account_id = v_acc where id = v_k1;
      update accounts set ehson_kassa_id = v_k1 where id = v_acc;
      v_mname := array_to_string(_ehson_kassa_yol(v_k1), ' · ');
      update accounts set name = v_mname where id = v_acc;
      raise notice 'Eski modda 1-childga o''tdi: % -> %', v_acc, v_mname;
    end if;

    -- c) Dilnoza konteyner
    update ehson_kassa set is_container = true where id = v_dil.id;
    perform _ehson_tarix_yoz('kassa', v_dil.id, 'konteynerga_aylandi',
      jsonb_build_object('manba', 'PROVODKA_EHSON_DILNOZA_JAMGARMA.sql', 'child_1', v_k1));
    raise notice '«%» konteyner bo''ldi (%)', v_dil.nom, v_dil.id;
  else
    raise notice '«%» allaqachon konteyner — ko''chirish o''tkazib yuborildi', v_dil.nom;
  end if;

  -- konteynerda qolgan faol pul turlari (masalan, eski fayl qayta RUN qilingan) — balans 0 bo'lsa nofaol
  update ehson_pul_turi pt set is_active = false
   where pt.kassa_id = v_dil.id and pt.is_active
     and not exists (select 1 from v_ehson_kassa_pul vp
                      where vp.kassa_id = pt.kassa_id and vp.pul_turi = pt.kod
                        and (coalesce(vp.qoldiq, 0) <> 0 or coalesce(vp.fc_qoldiq, 0) <> 0));

  -- d) har childga modda + sukut pul turlari (1-childda ko'chirilgan pul turlari qoladi, yetishmagani qo'shiladi)
  for v_kid in select id from ehson_kassa where parent_id = v_dil.id and not is_container and is_active order by tartib loop
    perform _ehson_xarajat_modda(v_kid);
    insert into ehson_pul_turi (kassa_id, kod, nom, valyuta, tartib)
    select v_kid, x.kod, x.nom, x.valyuta, x.tartib
      from (values
        ('naqd',   'Naqd',   'UZS', 1),
        ('dollar', 'Dollar', 'USD', 2),
        ('karta',  'Karta',  'UZS', 3),
        ('click',  'Click',  'UZS', 4)
      ) as x(kod, nom, valyuta, tartib)
     on conflict (kassa_id, kod) do nothing;
  end loop;
end
$dj_mig$;

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  8-BOLIM — TEKSHIRUV                                             ##
-- #####################################################################
-- 8.1 daraxt: kassa, ota, konteyner belgisi, modda, pul turlari soni
select repeat('  ', greatest(coalesce(array_length(_ehson_kassa_yol(k.id), 1), 1) - 1, 0)) || k.nom as kassa,
       k.is_container as konteyner, k.is_active as faol,
       (select a.code || ' ' || a.name from accounts a where a.id = k.xarajat_account_id) as modda,
       (select count(*) from ehson_pul_turi pt where pt.kassa_id = k.id and pt.is_active) as faol_pul_turi,
       vk.qoldiq
  from ehson_kassa k join v_ehson_kassa vk on vk.id = k.id
 order by array_position((select _ehson_kassa_avlod(r.id) from ehson_kassa r where r.parent_id is null and r.is_container order by r.created_at limit 1), k.id) nulls last, k.created_at;

-- 8.2 Dilnoza ostidagi childlar (kutiladi: 3 qator, har birida 4 faol pul turi, o'z moddasi)
select k.nom, _ehson_kassa_yol_matn(k.id) as yol, k.tartib,
       (select a.code || ' ' || a.name from accounts a where a.id = k.xarajat_account_id) as modda,
       (select string_agg(pt.kod, ',' order by pt.tartib) from ehson_pul_turi pt where pt.kassa_id = k.id and pt.is_active) as pul_turlari,
       vk.qoldiq
  from ehson_kassa k join v_ehson_kassa vk on vk.id = k.id
 where k.parent_id in (select id from ehson_kassa where lower(btrim(nom)) = 'dilnoza nazarova' and is_container)
 order by k.tartib;

-- 8.3 yo'qolgan yozuv yo'qligi: konteyner Dilnozada (o'zida) FAOL yozuv/pul turi/modda qolmasligi kerak (kutiladi: 0 qator)
select k.nom,
       (select count(*) from ehson_kirim  x where x.kassa_id = k.id and not x.is_deleted) as kirim,
       (select count(*) from ehson_berish x where x.kassa_id = k.id and x.holat = 'berildi') as berish,
       (select count(*) from ehson_qarz   x where x.kassa_id = k.id) as qarz,
       (select count(*) from ehson_pul_turi x where x.kassa_id = k.id and x.is_active) as faol_pul_turi,
       k.xarajat_account_id
  from ehson_kassa k
 where lower(btrim(k.nom)) = 'dilnoza nazarova' and k.is_container
   and ((select count(*) from ehson_kirim  x where x.kassa_id = k.id) > 0
     or (select count(*) from ehson_berish x where x.kassa_id = k.id) > 0
     or (select count(*) from ehson_qarz   x where x.kassa_id = k.id) > 0
     or (select count(*) from ehson_pul_turi x where x.kassa_id = k.id and x.is_active) > 0
     or k.xarajat_account_id is not null);
