-- =====================================================================
-- PROVODKA_XARAJAT_KASSA_YARAT.sql  (2026-09-03)
-- Kassa sahifasidan QO'LDA xarajat kassasi ochish (admin).
-- Asilbek QO'LDA RUN qiladi. ADDITIVE — bitta yangi RPC, hech narsa
-- o'zgartirilmaydi/o'chirilmaydi. Idempotent (create or replace).
--
-- NIMA UCHUN: hozir hodim xarajat kassasi (54xx, ota = 5400 konteyner)
-- FAQAT TaskFix orqali (`upsert_hodim_kassa`, service_role) ochiladi.
-- TaskFix'da bo'lmagan odam/maqsad uchun kassa ochishning yo'li yo'q edi.
-- Endi `kassa-dev.html` → 5400 guruh sarlavhasidagi «Kassa qo'shish» tugmasi
-- → shu RPC. Natija TaskFix ochgan kassa bilan AYNAN bir xil shaklda:
--   code 54xx · type aktiv · section pul · kassa_turi xarajat · currency UZS
--   · parent_id = 5400 · subtitle = "Filial · Lavozim" (ixtiyoriy).
-- Pul turlari (naqd/click/payme/karta) O'ZI ochiladi:
--   1) `trg_hodim_kassa_turlar` (PROVODKA_TURLAR_AVTO.sql, AFTER INSERT) —
--      asosiy yo'l, kassa qayerdan ochilsa ham ishlaydi;
--   2) zaxira: trigger o'rnatilmagan bazada ham RPC o'zi
--      `_pul_turi_child_ich` ni idempotent chaqiradi (bor bo'lsa qaytaradi).
--   Ikkalasi ham yo'q bo'lsa — kassa baribir ochiladi, `turlar` bo'sh qaytadi,
--   admin «+» modalidagi «Standart turlar» bilan keyin ochadi.
-- Qarz hisobi (6721+) — lazy, `hodim_qarz_hisob` birinchi kerak bo'lganda
-- ochadi (PROVODKA_XARAJAT_TOSIQ.sql), bu yerda tegilmaydi.
-- `taskfix_user_id` YOZILMAYDI — qo'lda ochilgan kassa TaskFix hodimiga
-- bog'lanmaydi (hodim.html u orqali kirmaydi; provodka/professional/jurnal
-- tanlagichlarida odatdagidek ko'rinadi).
--
-- RUXSAT: faqat admin (profiles.role='admin'), auth.uid() NULL bo'lsa ham
-- RAD (service_role uchun zarurat yo'q — TaskFix o'z RPC'sini ishlatadi).
-- p_guruh — mijoz bosgan guruh sarlavhasining id'si (ixtiyoriy; null → birinchi 5400).
-- Qaytishi (jsonb):
--   {ok:true,  id, code, name, turlar:['naqd','click','payme','karta']}
--   {ok:false, kod:'takror', id, code, name}   — shu nomli faol kassa bor
--   xato → raise exception (mijoz error.message ni ko'rsatadi)
--
-- ⚠️ Izohda dollar-qavs yozilmaydi (CLAUDE.md). Tana nomlangan teg bilan.
-- =====================================================================

create or replace function xarajat_kassa_yarat(p_name text, p_subtitle text default null,
                                               p_guruh uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_role     text;
  v_name     text := btrim(coalesce(p_name, ''));
  v_sub      text := nullif(btrim(coalesce(p_subtitle, '')), '');
  v_guruh    accounts%rowtype;
  v_takror   accounts%rowtype;
  v_max      int;
  v_code     text;
  v_id       uuid;
  v_turlar   text[] := '{}';
  t          text;
begin
  -- 1) faqat admin
  if auth.uid() is null then
    raise exception 'Kirish talab qilinadi';
  end if;
  select role into v_role from profiles where id = auth.uid();
  if v_role is distinct from 'admin' then
    raise exception 'Faqat admin kassa ocha oladi';
  end if;

  -- 2) kiritma
  if length(v_name) < 2 then
    raise exception 'Kassa nomi kamida 2 belgi bo''lsin';
  end if;
  if length(v_name) > 80 then
    raise exception 'Kassa nomi 80 belgidan oshmasin';
  end if;
  if v_sub is not null and length(v_sub) > 120 then
    raise exception 'Izoh (Filial · Lavozim) 120 belgidan oshmasin';
  end if;

  -- 3) konteyner (kassa_turi='xarajat_guruh'). Mijoz guruh id'sini beradi
  --    (bir nechta guruh bo'lsa to'g'risiga tushsin); bermasa — birinchisi (5400).
  if p_guruh is not null then
    select * into v_guruh
      from accounts
     where id = p_guruh and kassa_turi = 'xarajat_guruh' and coalesce(is_active, true);
    if not found then
      raise exception 'Berilgan guruh xarajat konteyneri emas yoki faol emas: %', p_guruh;
    end if;
  else
    select * into v_guruh
      from accounts
     where kassa_turi = 'xarajat_guruh' and coalesce(is_active, true)
     order by code
     limit 1;
    if not found then
      raise exception 'Hodim xarajat kassalari konteyneri (5400, kassa_turi=xarajat_guruh) topilmadi';
    end if;
  end if;

  -- 4) bir vaqtda ikki admin bossa kod to'qnashmasin
  perform pg_advisory_xact_lock(hashtext('xarajat_kassa_yarat'));

  -- 5) takror nom (faol, shu guruh ichida, katta-kichik harf farqsiz)
  select * into v_takror
    from accounts
   where parent_id = v_guruh.id
     and coalesce(is_active, true)
     and pul_turi is null
     and coalesce(currency, 'UZS') = 'UZS'
     and lower(name) = lower(v_name)
   limit 1;
  if found then
    return jsonb_build_object('ok', false, 'kod', 'takror',
      'id', v_takror.id, 'code', v_takror.code, 'name', v_takror.name);
  end if;

  -- 6) kod: 54xx blokidagi eng kattasi + 1 (nofaol ham sanaladi — kod
  --    unikal). Tur bolalari boshqa shaklda (54xx emas) — regex ularni
  --    o'tkazmaydi. 5400 ning o'zi konteyner → boshlanish 5401.
  select max(code::int) into v_max
    from accounts
   where code ~ '^54[0-9]{2}$' and code <> '5400';
  v_code := (coalesce(v_max, 5400) + 1)::text;
  if v_code::int > 5499 then
    raise exception 'Xarajat kassalari kod bloki (5401–5499) to''ldi';
  end if;

  -- 7) insert — TaskFix kassasi bilan bir xil shakl.
  --    AFTER INSERT trigger (trg_hodim_kassa_turlar) bor bo'lsa turlarni
  --    o'zi ochadi; xato bo'lsa u faqat warning beradi (kassa qoladi).
  insert into accounts (code, name, subtitle, type, section, kassa_turi,
                        currency, parent_id, is_active)
  values (v_code, v_name, v_sub, 'aktiv', 'pul', 'xarajat',
          'UZS', v_guruh.id, true)
  returning id into v_id;

  -- 8) zaxira: trigger yo'q bazada ham standart turlar ochilsin.
  --    _pul_turi_child_ich idempotent — trigger ochgan bo'lsa qaytadan
  --    ochmaydi, mavjudini qaytaradi. Xato kassani buzmasin.
  --    Har tur O'Z exception blokida — biri yiqilsa oldin ochilganlari
  --    rollback bo'lmasin (bitta umumiy blok hammasini qaytarib yuborardi).
  if to_regprocedure('public._pul_turi_child_ich(uuid,text)') is not null
     and to_regprocedure('public.pul_turi_standart()') is not null then
    for t in execute 'select unnest(pul_turi_standart())' loop
      begin
        execute 'select _pul_turi_child_ich($1, $2)' using v_id, t;
      exception when others then
        raise warning 'xarajat_kassa_yarat: tur ochilmadi (% % · %): %', v_code, v_name, t, sqlerrm;
      end;
    end loop;
  end if;

  -- 9) haqiqatda ochilgan turlar (trigger yoki zaxira — farqi yo'q)
  select coalesce(array_agg(pul_turi order by
           case pul_turi when 'naqd' then 1 when 'click' then 2 when 'payme' then 3
                         when 'terminal' then 4 when 'karta' then 5 when 'plastik' then 6 else 9 end),
         '{}')
    into v_turlar
    from accounts
   where parent_id = v_id and pul_turi is not null and coalesce(is_active, true);

  return jsonb_build_object('ok', true, 'id', v_id, 'code', v_code,
                            'name', v_name, 'turlar', to_jsonb(v_turlar));
end $fn$;

revoke all on function xarajat_kassa_yarat(text, text, uuid) from public, anon;
grant execute on function xarajat_kassa_yarat(text, text, uuid) to authenticated;

comment on function xarajat_kassa_yarat(text, text, uuid) is
  'Admin: 5400 konteyner ostiga qo''lda xarajat kassasi (54xx) ochadi; standart pul '
  'turlari avtomat (trigger yoki zaxira). Takror nom → {ok:false,kod:takror}.';


-- ---------------------------------------------------------------------
-- TEKSHIRUV (ixtiyoriy) — RUN dan keyin:
--   select proname, prosecdef from pg_proc where proname = 'xarajat_kassa_yarat';
-- Sinov (admin sessiyasida, Supabase SQL editorida auth.uid() NULL → rad etadi,
-- shuning uchun sinovni kassa-dev.html dan qiling).
-- ---------------------------------------------------------------------
