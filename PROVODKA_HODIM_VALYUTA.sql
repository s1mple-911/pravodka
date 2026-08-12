-- =====================================================================
-- PROVODKA_HODIM_VALYUTA.sql
-- Hodim xarajati valyuta kassasidan: so'm summasi + KURS bilan fc_amount
-- =====================================================================
-- Muammo: xarajat_saqlash_taqsim (filial bo'yicha taqsimot) valyuta
-- kassasida fc_amount = summa deb yozardi, ya'ni "635 000 so'm" chiqsa
-- dollar hisobidan ham 635 000 dollar ayirilardi.
--
-- Yechim: p_data ichiga IXTIYORIY `kassa_kurs` kaliti (1 birlik valyuta
-- necha so'm). Berilsa fc = round(summa / kurs, 2), berilmasa — ESKI
-- xatti-harakat (fc = summa) saqlanadi.
--
-- ⚠️ IMZO O'ZGARMAYDI: xarajat_saqlash_taqsim(jsonb) — eski chaqiruvlar
--    (hodim.html prod, professional.html) shundayligicha ishlayveradi.
-- ⚠️ ADDITIVE: ustun ham, funksiya ham o'chirilmaydi.
--
-- Bir martalik xarajat (bitta filial / filialsiz) klientdan to'g'ridan
-- entry+entry_line bilan yoziladi — u yerda kurs klientda hisoblanadi
-- (hodim-dev.html → calcAmounts). Bu fayl FAQAT taqsimot RPC'si uchun.
-- =====================================================================

create or replace function xarajat_saqlash_taqsim(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  it       jsonb;
  v_entry  uuid;
  v_ids    uuid[] := '{}';
  v_dt     uuid := nullif(p_data->>'dt_account','')::uuid;
  v_kt     uuid := nullif(p_data->>'kt_account','')::uuid;
  v_kassa  uuid := nullif(p_data->>'kassa_account','')::uuid;
  v_cur    text := nullif(p_data->>'kassa_currency','');
  -- YANGI: 1 birlik valyuta necha so'm. null → eski xatti-harakat (fc = summa).
  v_kurs   numeric := nullif(p_data->>'kassa_kurs','')::numeric;
  v_summa  numeric;
  v_filial uuid;
  v_fc     numeric;
  v_fc_dt  numeric;
  v_fc_kt  numeric;
begin
  if v_dt is null or v_kt is null then
    raise exception 'dt/kt hisob berilmadi' using errcode = '22000';
  end if;
  if p_data->'taqsim' is null or jsonb_typeof(p_data->'taqsim') <> 'array'
     or jsonb_array_length(p_data->'taqsim') = 0 then
    raise exception 'Taqsimot bo''sh' using errcode = '22000';
  end if;
  if v_kurs is not null and v_kurs <= 0 then
    raise exception 'Kurs musbat bo''lishi kerak' using errcode = '22000';
  end if;

  for it in select * from jsonb_array_elements(p_data->'taqsim') loop
    v_summa  := (it->>'summa')::numeric;
    v_filial := nullif(it->>'filial_id','')::uuid;
    if v_summa is null or v_summa <= 0 then
      raise exception 'Har filial summasi musbat bo''lishi kerak' using errcode = '22000';
    end if;

    insert into entry (entry_date, description, source, status, filial_ids,
                       davr_start, davr_end, kommunal_turi, fc_rate)
    values (
      nullif(p_data->>'entry_date','')::date,
      nullif(p_data->>'description',''),
      coalesce(nullif(p_data->>'source',''), 'manual'),
      coalesce(nullif(p_data->>'status',''), 'posted'),
      case when v_filial is null then '{}'::uuid[] else array[v_filial] end,
      nullif(p_data->>'davr_start','')::date,
      nullif(p_data->>'davr_end','')::date,
      nullif(p_data->>'kommunal_turi',''),
      case when v_cur is not null and v_cur <> 'UZS' then v_kurs end
    )
    returning id into v_entry;

    -- fc_amount faqat valyuta kassasi satriga (client bilan bir xil mantiq).
    -- Kurs berilgan bo'lsa so'm ulushi valyutaga aylantiriladi.
    v_fc := case when v_kurs is not null then round(v_summa / v_kurs, 2) else v_summa end;
    v_fc_dt := case when v_cur is not null and v_cur <> 'UZS' and v_kassa = v_dt then v_fc else null end;
    v_fc_kt := case when v_cur is not null and v_cur <> 'UZS' and v_kassa = v_kt then v_fc else null end;

    insert into entry_line (entry_id, account_id, debit, credit, fc_amount)
    values (v_entry, v_dt, v_summa, 0, v_fc_dt),
           (v_entry, v_kt, 0, v_summa, v_fc_kt);

    v_ids := v_ids || v_entry;
  end loop;

  return jsonb_build_object('ok', true,
                            'count', coalesce(array_length(v_ids, 1), 0),
                            'entry_ids', to_jsonb(v_ids));
end $$;

revoke all on function xarajat_saqlash_taqsim(jsonb) from public, anon;
grant execute on function xarajat_saqlash_taqsim(jsonb) to authenticated;

comment on function xarajat_saqlash_taqsim(jsonb) is
  'Filial bo''yicha alohida provodka: har filialga bitta entry (atomik). perm guard har satrga ishlaydi. '
  'kassa_kurs berilsa valyuta kassasida fc = summa/kurs (aks holda fc = summa — eski xatti-harakat).';

-- PostgREST sxema keshini yangilash (yangi kalit p_data ichida — imzo o'zgarmagan, lekin odat)
notify pgrst, 'reload schema';

-- Tekshiruv: funksiya joyidami va imzo saqlanganmi
do $$
begin
  if to_regprocedure('xarajat_saqlash_taqsim(jsonb)') is null then
    raise exception 'xarajat_saqlash_taqsim(jsonb) topilmadi — imzo buzilgan!';
  end if;
  if to_regclass('entry') is null then
    raise exception 'entry jadvali yo''q';
  end if;
  raise notice 'OK: xarajat_saqlash_taqsim(jsonb) + kassa_kurs tayyor';
end $$;


-- =====================================================================
-- TEKSHIRUV (Asilbek uchun — ixtiyoriy, faqat SELECT)
-- =====================================================================
-- 1) Hodim kassalarining bola-hisoblari: qaysi kassada qaysi tur/valyuta bor.
--    "Dollar ko'rinmayapti" — shu ro'yxatda USD qatori bormi, shundan ma'lum.
--
-- select p.code as kassa_kod, p.name as kassa, p.subtitle,
--        c.code as bola_kod, c.name as bola, c.pul_turi, c.currency, c.is_active
--   from accounts p
--   left join accounts c on c.parent_id = p.id and c.is_active
--  where p.kassa_turi = 'xarajat' and p.is_active
--  order by p.code, c.code;
--
-- 2) USD bolasi yo'q bo'lsa — admin ochadi (idempotent):
--    select create_valyuta_child('<kassa uuid>', 'USD');
--
-- 3) USD kursi bormi (null bo'lsa hodim dollarda xarajat yoza olmaydi):
--    select conv_baza_kurs('USD');
