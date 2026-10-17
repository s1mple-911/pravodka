-- ============================================================================
--  PROVODKA_EHSON_SOLIQ_ZAKOT_20261017.sql — 2026-10-17 — Ehson soliq ikki musbat qator + Zakot pul turisiz qoldiq
--  Asilbek yakuniy holat: Asosiy $12 230 / naqd 275 000 (TEGILMAYDI); Soliq $715 / naqd 449 000; Zakot $0 / naqd 476 000 va
--  UMUMIY qoldiq ham 476 000.
--  a) Ehson soliq: Excel'dagi ikki MUSBAT qator qo'lda kirim sifatida (ehson_kirim, tur='qolda'):
--       BEGZOT QARSHI SHOVRUM +1 500 000 UZS (naqd), NURIDDIN +$500 (dollar, fc_summa + conv_baza_kurs). Soliq: -1 051 000 -> 449 000, $215 -> $715.
--  b) Zakot: pul_turi NULL bo'lgan eski yozuvlar net'i (jami -950 000) umumiy qoldiqni -474 000 qilyapti. Ular o'chirilmaydi
--     (berish/kirim tarixi saqlanadi) — shu net'ning TESKARISI pul_turi NULL bilan 'tuzatish' yozuvi bilan neytrallanadi
--     (har valyuta alohida; net 0 bo'lsa hech narsa yozilmaydi). Natija: Zakot umumiy = naqd = 476 000.
--  IDEMPOTENT: kirimlar ext_ref bilan (unique), Zakot tuzatish net-ga qarab (net 0 -> yozuv yo'q).
--  Oxirida bitta natija jadvali: ESKI (Zakot pul turisiz yozuvlar) · KIRIM · ZAKOT · QOLDIQ (naqd / dollar / umumiy, uch kassa).
--  Old shart: PROVODKA_EHSON_KIRIM.sql (ehson_kirim.tur). Asilbek RUN qiladi. entry/accounts ga TEGILMAYDI.
-- ============================================================================

do $esz_pre$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ehson_kirim' and column_name = 'tur') then
    raise exception 'ehson_kirim.tur yoq — avval PROVODKA_EHSON_KIRIM.sql RUN qiling';
  end if;
  if to_regclass('public.v_ehson_kassa_pul') is null or to_regclass('public.v_ehson_kassa') is null then
    raise exception 'v_ehson_kassa_pul / v_ehson_kassa yoq — avval ehson SQL fayllari';
  end if;
  if to_regclass('public.ehson_qarz') is null or to_regclass('public.ehson_qarz_tolov') is null then
    raise exception 'ehson_qarz yoq — avval PROVODKA_EHSON_QARZ.sql';
  end if;
  if to_regprocedure('public._ehson_tarix_yoz(text,uuid,text,jsonb)') is null then
    raise exception '_ehson_tarix_yoz yoq';
  end if;
end
$esz_pre$;

create or replace function _ehson_soliq_zakot_20261017()
returns table (o_bolim text, o_nom text, o_kassa text, o_pul_turi text, o_valyuta text, o_summa numeric, o_holat text)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_bugun  date := (now() at time zone 'Asia/Tashkent')::date;
  v_kurs   numeric;
  v_soliq  uuid;
  v_zakot  uuid;
  v_cnt    int;
  v_t      record;
  v_pt     ehson_pul_turi;
  v_ext    text;
  v_fc     numeric;
  v_summa  numeric;
  v_id     uuid;
  r        record;
begin
  if exists (
    select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
     where ns.nspname = 'public' and pr.proname = 'conv_baza_kurs' and oidvectortypes(pr.proargtypes) = 'text'
  ) then
    execute 'select conv_baza_kurs($1)' into v_kurs using 'USD';
  end if;

  select count(*), min(k.id::text)::uuid into v_cnt, v_soliq from ehson_kassa k
   where k.parent_id is not null and not k.is_container and k.is_active and lower(btrim(k.nom)) = 'ehson soliq';
  if v_cnt <> 1 then raise exception 'Ehson soliq kassasi nomi bo''yicha topilmadi yoki bir nechta (%)', v_cnt; end if;
  select count(*), min(k.id::text)::uuid into v_cnt, v_zakot from ehson_kassa k
   where k.parent_id is not null and not k.is_container and k.is_active and lower(btrim(k.nom)) = 'zakot';
  if v_cnt <> 1 then raise exception 'Zakot kassasi nomi bo''yicha topilmadi yoki bir nechta (%)', v_cnt; end if;

  -- ---------- ESKI: Zakot, pul_turi NULL yozuvlar (nima ekanini ko'rish uchun) ----------
  for r in
    select 'kirim' as src, id, sana, summa, coalesce(valyuta, 'UZS') as valyuta,
           (case when is_deleted then 'BEKOR ' else '' end) || coalesce(tur, 'jurnal') || ' / ' || coalesce(manba, '') || ' / ' || coalesce(izoh, '') as nota
      from ehson_kirim where kassa_id = v_zakot and pul_turi is null
    union all
    select 'berish', id, sana, -summa, coalesce(valyuta, 'UZS'), holat || ' / ' || coalesce(izoh, '')
      from ehson_berish where kassa_id = v_zakot and pul_turi is null
    union all
    select 'qarz', id, sana, -summa, coalesce(valyuta, 'UZS'), holat || ' / ' || coalesce(ism, '') || ' / ' || coalesce(izoh, '')
      from ehson_qarz where kassa_id = v_zakot and pul_turi is null
    union all
    select 'qarz_tolov', id, sana, summa, coalesce(valyuta, 'UZS'), (case when is_deleted then 'BEKOR ' else '' end) || coalesce(izoh, '')
      from ehson_qarz_tolov where kassa_id = v_zakot and pul_turi is null
    order by 3, 1
  loop
    o_bolim := 'ESKI'; o_nom := r.src || ' ' || left(r.id::text, 8) || ' ' || r.sana::text; o_kassa := 'Zakot';
    o_pul_turi := null; o_valyuta := r.valyuta; o_summa := r.summa; o_holat := r.nota;
    return next;
  end loop;

  -- ---------- a) EHSON SOLIQ: ikki musbat Excel qatori -> qo'lda kirim ----------
  for v_t in
    select * from (values
      (1, 'BEGZOT QARSHI SHOVRUM', 'naqd',   'UZS', 1500000::numeric),
      (2, 'NURIDDIN',              'dollar', 'USD', 500::numeric)
    ) as x(n, ism, pul_kod, valyuta, miqdor)
    order by n
  loop
    o_bolim := 'KIRIM'; o_nom := v_t.ism; o_kassa := 'Ehson soliq'; o_pul_turi := v_t.pul_kod; o_valyuta := v_t.valyuta; o_summa := v_t.miqdor;

    select * into v_pt from ehson_pul_turi where kassa_id = v_soliq and kod = v_t.pul_kod and is_active;
    if not found then
      o_holat := 'O''TKAZILDI: faol pul turi yoq'; return next; continue;
    end if;
    v_ext := 'excel_kirim_20261017:soliq:' || v_t.n::text;
    if exists (select 1 from ehson_kirim where ext_ref = v_ext) then
      o_holat := 'allaqachon yozilgan (o''tkazildi)'; return next; continue;
    end if;
    if v_t.valyuta = 'USD' then
      if v_kurs is null or v_kurs <= 0 then
        o_holat := 'O''TKAZILDI: USD kursi yoq (Valyuta bo''limida kurs kiriting, so''ng qayta RUN)'; return next; continue;
      end if;
      v_fc := v_t.miqdor; v_summa := round(v_fc * v_kurs);
    else
      v_fc := null; v_summa := v_t.miqdor;
    end if;

    perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || v_soliq::text));
    insert into ehson_kirim (kassa_id, summa, sana, manba, izoh, created_by, pul_turi, valyuta, fc_summa, ext_ref, tur)
    values (v_soliq, v_summa, v_bugun, 'Ehson kirim',
            'Excel ro''yxati 2026-10-17: ' || v_t.ism || ' (qarz qaytishi)', null, v_pt.kod, v_t.valyuta, v_fc, v_ext, 'qolda')
    returning id into v_id;
    perform _ehson_tarix_yoz('kirim', v_id, 'qolda_kirim',
      jsonb_build_object('kassa_id', v_soliq, 'pul_turi', v_pt.kod, 'summa', v_summa, 'fc_summa', v_fc, 'manba', 'excel_20261017'));
    o_holat := 'YOZILDI';
    return next;
  end loop;

  -- ---------- b) ZAKOT: pul_turi NULL net'ini neytrallash ----------
  for r in
    select valyuta, sum(qoldiq) as q, sum(fc_qoldiq) as fcq
      from v_ehson_kassa_pul where kassa_id = v_zakot and pul_turi is null
     group by valyuta
  loop
    o_bolim := 'ZAKOT'; o_nom := 'pul turisiz net'; o_kassa := 'Zakot'; o_pul_turi := null; o_valyuta := r.valyuta; o_summa := r.q;
    if coalesce(r.q, 0) = 0 then
      o_holat := 'net 0 — yozuv kerak emas'; return next; continue;
    end if;
    perform pg_advisory_xact_lock(hashtext('ehson_kassa:' || v_zakot::text));
    insert into ehson_kirim (kassa_id, summa, sana, manba, izoh, created_by, pul_turi, valyuta, fc_summa, tur)
    values (v_zakot, -r.q, v_bugun, 'Balans to''g''irlash',
            'Zakot: pul turisiz eski yozuvlar neytrallashtirildi 2026-10-17 (Asilbek)', null, null, r.valyuta,
            case when coalesce(r.fcq, 0) <> 0 then -r.fcq end, 'tuzatish')
    returning id into v_id;
    perform _ehson_tarix_yoz('kirim', v_id, 'balans_togrilandi',
      jsonb_build_object('pul_turi', null, 'oldin_net', r.q, 'summa', -r.q, 'manba', 'zakot_null_neytral_20261017'));
    o_summa := -r.q;
    o_holat := 'YOZILDI (net ' || r.q::text || ' -> 0)';
    return next;
  end loop;

  -- ---------- QOLDIQ: uch kassa — naqd / dollar / umumiy ----------
  for r in
    select k.id, k.nom from ehson_kassa k
     where k.parent_id is not null and not k.is_container and k.is_active order by k.tartib, k.nom
  loop
    o_bolim := 'QOLDIQ'; o_nom := null; o_kassa := r.nom; o_holat := null;
    o_pul_turi := 'naqd'; o_valyuta := 'UZS';
    select coalesce(sum(qoldiq), 0) into o_summa from v_ehson_kassa_pul where kassa_id = r.id and pul_turi = 'naqd';
    return next;
    o_pul_turi := 'dollar'; o_valyuta := 'USD';
    select coalesce(sum(fc_qoldiq), 0) into o_summa from v_ehson_kassa_pul where kassa_id = r.id and pul_turi = 'dollar';
    return next;
    o_pul_turi := 'umumiy'; o_valyuta := 'UZS';
    select coalesce(qoldiq, 0) into o_summa from v_ehson_kassa where id = r.id;
    return next;
  end loop;
  return;
end
$fn$;

-- Faqat SQL editor (postgres/service_role) — brauzerdan chaqirilmaydi
revoke all on function _ehson_soliq_zakot_20261017() from public, anon, authenticated;

comment on function _ehson_soliq_zakot_20261017() is
  'Bir martalik: Ehson soliq ikki qo''lda kirim (BEGZOT +1 500 000, NURIDDIN +$500) + Zakot pul turisiz net neytrallash. Idempotent.';

-- NATIJA JADVALI: ESKI (Zakot pul turisiz yozuvlar) · KIRIM · ZAKOT · QOLDIQ (naqd / dollar / umumiy)
select * from _ehson_soliq_zakot_20261017();

do $esz_check$
begin
  if to_regprocedure('public._ehson_soliq_zakot_20261017()') is null then raise exception '_ehson_soliq_zakot_20261017 yaratilmadi'; end if;
  raise notice 'PROVODKA_EHSON_SOLIQ_ZAKOT_20261017.sql: hammasi joyida.';
end
$esz_check$;
