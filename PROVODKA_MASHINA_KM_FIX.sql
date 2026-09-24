-- ============================================================================
--  PROVODKA_MASHINA_KM_FIX.sql — 2026-09-24 — spidometr km: AI o'qigani ustun + so'm/km to'g'ri
--  Asilbek: (1) «tablo deb user yozganini olyapti, aslida AI o'zi o'qiganini qo'ysin»;
--  (2) «90 ming gaz quydi, tablo 1000 km; keyingi safar 1200 km, 92 000 → 200 km yurgan,
--      90 ming gaz 200 km ga ketdi → 1 km necha so'm».
--  Eski mantiq: joriy yozuv summasi / (joriy km − oldingi km) — ya'ni YANGI quyilgan gazning
--  pulini OLDIN yurilgan km ga bo'lardi (92 000 / 200). To'g'risi: OLDINGI quyish (90 000)
--  shu 200 km ni yurdi → oldingi yozuvga yurgan_km=200, som_per_km=450 yoziladi; joriy yozuv
--  keyingi tablo kelguncha ochiq (yurgan_km null).
--  Additive: 2 ustun (km_manba, km_qolda), mashina_km_yoz imzosi bir xil, qayta hisob RPC + bir
--  martalik backfill. v_mashina_samara o'zgarmaydi (Σsumma/Σyurgan — yangi semantika bilan to'g'ri).
-- ============================================================================

alter table mashina_km add column if not exists km_manba text;     -- 'ai' | 'qolda'
alter table mashina_km add column if not exists km_qolda int;      -- hodim yozgan raqam (AI bilan farq qilsa ko'rish uchun)
comment on column mashina_km.km_manba is 'km qayerdan: ai (rasm_tahlil.ai_km, aniq) yoki qolda (hodim yozgani).';
comment on column mashina_km.yurgan_km is
  '2026-09-24 dan: SHU quyishdan keyin yurilgan km (keyingi tablo − shu tablo). Keyingi tablo kelguncha null.';
comment on column mashina_km.som_per_km is 'Shu yozuv summasi / yurgan_km (keyingi tablo kelganda hisoblanadi).';

-- ---------------------------------------------------------------- 1) bitta mashina uchun qayta hisob (ichki)
create or replace function _mashina_km_qayta(p_mashina uuid)
returns int
language plpgsql
security definer
set search_path = public
as $mkq$
declare
  r      record;
  v_prev record := null;
  v_n    int := 0;
begin
  -- tartib: sana, keyin yaratilgan vaqt. Har yozuvga: oldingi_km = avvalgisining km;
  -- avvalgi yozuvga: yurgan_km = km − avvalgi km, som_per_km = avvalgi summa / yurgan.
  for r in
    select mk.id, mk.entry_id, mk.km, mk.sana, mk.created_at,
           (select coalesce(sum(l.debit), 0) from entry_line l join accounts a on a.id = l.account_id
             where l.entry_id = mk.entry_id and l.debit > 0 and a.type = 'xarajat') as summa
      from mashina_km mk
      join entry e on e.id = mk.entry_id and e.is_deleted = false
     where mk.mashina_element_id = p_mashina
     order by mk.sana, mk.created_at
  loop
    if v_prev is not null then
      update mashina_km
         set yurgan_km  = case when r.km - v_prev.km > 0 then r.km - v_prev.km else null end,
             som_per_km = case when r.km - v_prev.km > 0 then round(v_prev.summa / (r.km - v_prev.km), 2) else null end
       where id = v_prev.id;
      update mashina_km set oldingi_km = v_prev.km where id = r.id;
    else
      update mashina_km set oldingi_km = null where id = r.id;
    end if;
    -- oxirgi yozuv: keyingi tablo hali yo'q
    update mashina_km set yurgan_km = null, som_per_km = null where id = r.id;
    v_prev := r;
    v_n := v_n + 1;
  end loop;
  return v_n;
end
$mkq$;
revoke all on function _mashina_km_qayta(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 2) mashina_km_yoz — imzo bir xil
create or replace function mashina_km_yoz(p_entry uuid, p_mashina uuid, p_km int, p_tahlil uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_sana   date;
  v_km     int := p_km;
  v_manba  text := 'qolda';
  v_ai_km  int;
  v_aniq   boolean;
  v_birlik text;
  v_id     uuid;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if p_entry is null or p_mashina is null then
    raise exception 'Yozuv va mashina kerak' using errcode = '22000';
  end if;
  if not exists (select 1 from xarajat_royxat_element where id = p_mashina and is_active) then
    raise exception 'Mashina topilmadi yoki ochirilgan' using errcode = '22000';
  end if;
  if not xm_entry_yoz_ok(p_entry) then
    raise exception 'Bu yozuvga km yozish huquqingiz yoq' using errcode = '42501';
  end if;
  select entry_date into v_sana from entry where id = p_entry;
  if not found then
    raise exception 'Yozuv topilmadi' using errcode = '22000';
  end if;

  -- 🔴 AI o'qigan tablo USTUN: rasm_tahlil.ai_km aniq (ishonch ≥ 0.7, muammosiz) bo'lsa hodim
  --    yozgani emas, AI raqami saqlanadi (hodimniki km_qolda da qoladi). Mil bo'lsa km ga.
  if p_tahlil is not null then
    select rt.ai_km, coalesce(rt.aniq, false), rt.natija ->> 'birlik'
      into v_ai_km, v_aniq, v_birlik
      from rasm_tahlil rt where rt.id = p_tahlil and rt.tur = 'spidometr';
    if v_ai_km is not null and v_ai_km > 0 and v_aniq then
      v_km := case when v_birlik = 'mil' then round(v_ai_km * 1.609) else v_ai_km end;
      v_manba := 'ai';
    end if;
  end if;
  if v_km is null then
    raise exception 'Km kerak (tablo oqilmadi va qolda kiritilmagan)' using errcode = '22000';
  end if;
  if v_km < 0 then
    raise exception 'Km manfiy bololmaydi' using errcode = '22000';
  end if;

  insert into mashina_km (entry_id, mashina_element_id, km, sana, rasm_tahlil_id, user_id, km_manba, km_qolda)
  values (p_entry, p_mashina, v_km, coalesce(v_sana, current_date), p_tahlil, v_uid, v_manba, p_km)
  on conflict (entry_id) do update
     set mashina_element_id = excluded.mashina_element_id,
         km                 = excluded.km,
         sana               = excluded.sana,
         rasm_tahlil_id     = excluded.rasm_tahlil_id,
         km_manba           = excluded.km_manba,
         km_qolda           = excluded.km_qolda
  returning id into v_id;

  -- oldingi_km / yurgan_km / som_per_km — shu mashinaning butun zanjiri bo'yicha
  perform _mashina_km_qayta(p_mashina);
  perform rasm_shubhali_hisobla(p_entry);
  return v_id;
end $fn$;
revoke all on function mashina_km_yoz(uuid, uuid, int, uuid) from public, anon;
grant execute on function mashina_km_yoz(uuid, uuid, int, uuid) to authenticated;
comment on function mashina_km_yoz(uuid, uuid, int, uuid) is
  'Km yozuvi (entry ustiga upsert). AI o''qigan km (rasm_tahlil.ai_km, aniq) USTUN; hodimniki km_qolda. '
  'yurgan_km/som_per_km OLDINGI quyish yozuviga yoziladi (keyingi tablo − oldingi). ENG OXIRGI: PROVODKA_MASHINA_KM_FIX.sql';

-- ---------------------------------------------------------------- 3) AI tahlil KEYIN kelsa (fonda) — km yangilansin
-- rasm_tahlil qatori spidometr uchun keyin yoziladi (EF fonda). Shu paytda mashina_km qatori
-- km_manba='qolda' bo'lsa va AI aniq o'qigan bo'lsa — AI km ga almashtiriladi.
create or replace function trg_rasm_tahlil_km()
returns trigger
language plpgsql
security definer
set search_path = public
as $t$
declare
  r record;
  v_km int;
begin
  if new.tur is distinct from 'spidometr' or new.ai_km is null or new.ai_km <= 0 or not coalesce(new.aniq, false) then
    return new;
  end if;
  v_km := case when (new.natija ->> 'birlik') = 'mil' then round(new.ai_km * 1.609) else new.ai_km end;
  for r in select mk.id, mk.mashina_element_id, mk.entry_id from mashina_km mk
            where mk.rasm_tahlil_id = new.id and coalesce(mk.km_manba, 'qolda') <> 'ai' loop
    update mashina_km set km = v_km, km_manba = 'ai' where id = r.id;
    perform _mashina_km_qayta(r.mashina_element_id);
    perform rasm_shubhali_hisobla(r.entry_id);
  end loop;
  return new;
end
$t$;
drop trigger if exists trg_rasm_tahlil_km on rasm_tahlil;
create trigger trg_rasm_tahlil_km
  after insert or update of ai_km, aniq on rasm_tahlil
  for each row execute function trg_rasm_tahlil_km();

-- ---------------------------------------------------------------- 4) bir martalik: mavjud yozuvlar qayta hisoblanadi
do $backfill$
declare
  m uuid; n int := 0; t int := 0;
begin
  -- AI aniq o'qigan, lekin qo'lda km saqlangan yozuvlar → AI km
  update mashina_km mk
     set km_qolda = coalesce(mk.km_qolda, mk.km),
         km       = case when (rt.natija ->> 'birlik') = 'mil' then round(rt.ai_km * 1.609) else rt.ai_km end,
         km_manba = 'ai'
    from rasm_tahlil rt
   where rt.id = mk.rasm_tahlil_id and rt.tur = 'spidometr' and rt.ai_km > 0 and coalesce(rt.aniq, false)
     and coalesce(mk.km_manba, '') <> 'ai' and mk.km <> rt.ai_km;
  get diagnostics n = row_count;
  update mashina_km set km_manba = 'qolda' where km_manba is null;
  for m in select distinct mashina_element_id from mashina_km loop
    t := t + _mashina_km_qayta(m);
  end loop;
  raise notice 'MASHINA KM: % yozuv AI km ga almashdi, % yozuv qayta hisoblandi', n, t;
end
$backfill$;

select el.nom as mashina, mk.sana, mk.km, mk.km_manba, mk.km_qolda, mk.oldingi_km, mk.yurgan_km, mk.som_per_km
  from mashina_km mk join xarajat_royxat_element el on el.id = mk.mashina_element_id
 order by el.nom, mk.sana desc, mk.created_at desc limit 40;
