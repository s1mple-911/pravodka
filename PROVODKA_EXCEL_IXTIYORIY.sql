-- ============================================================================
--  PROVODKA_EXCEL_IXTIYORIY.sql — 2026-09-15 (Asilbek)
--  «Oziq-ovqat turida Excel yuklash majburiy bo'lib qolibdi — ixtiyoriy qilish
--  kerak: xohlasa izoh yozsin, xohlasa Excel yuklasin.»
--
--  Klient (hodim-dev.html) allaqachon «izoh YOKI jadval» qoidasiga o'tdi. Server
--  qatlamida Excel talabi faqat ruxsat_yarat_v2 da bor edi — shu yerda ham
--  xuddi shu qoida: izoh ham, jadval ham bo'sh bo'lsagina rad etiladi.
--
--  Imzo O'ZGARMAYDI (create or replace, bitta jsonb argument). Tana
--  PROVODKA_RUXSAT_TALAB.sql 4-BO'LIMdan AYNAN ko'chirilgan — YAGONA farq
--  Excel shartida. 🔴 Keyingi safar ruxsat_yarat_v2 o'zgartirilsa ENG OXIRGI
--  versiya SHU faylda.
--  Ikki marta RUN qilinsa ham xato bermaydi.
-- ============================================================================

create or replace function ruxsat_yarat_v2(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_modda  uuid;
  v_talab  jsonb;
  v_euid   uuid;
  v_fil    uuid[] := '{}'::uuid[];
  v_ds     date;
  v_de     date;
  v_komm   text;
  v_jadval jsonb;
  v_mayd   jsonb;
  v_chek   boolean;
  v_res    jsonb;
  v_id     uuid;
  v_yoq    text;
begin
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;
  if jsonb_typeof(p_data) is distinct from 'object' then
    raise exception 'Malumot formati notogri' using errcode = '22000';
  end if;

  v_modda := nullif(p_data->>'modda', '')::uuid;
  if v_modda is null then
    raise exception 'Xarajat turi tanlanmagan' using errcode = '22000';
  end if;

  -- ---- 1) Moddaning talablari (YAGONA manba) -------------------------
  v_talab := ruxsat_talab(v_modda);
  if not coalesce((v_talab->>'bor')::boolean, false) then
    raise exception 'Xarajat moddasi topilmadi' using errcode = '22000';
  end if;
  if coalesce((v_talab->>'bloklangan')::boolean, false) then
    raise exception '%', coalesce(v_talab->>'blok_sabab', 'Bu turga ruxsat sorab bolmaydi')
      using errcode = '22000';
  end if;

  -- ---- 2) Maydonlarni o'qish ----------------------------------------
  v_euid   := nullif(p_data->>'entry_uid', '')::uuid;
  v_chek   := coalesce((p_data->>'chek_bor')::boolean, false);
  v_ds     := nullif(p_data->>'davr_start', '')::date;
  v_de     := nullif(p_data->>'davr_end', '')::date;
  v_komm   := nullif(btrim(coalesce(p_data->>'kommunal_turi', '')), '');
  v_jadval := case when jsonb_typeof(p_data->'jadval')    = 'object' then p_data->'jadval'    end;
  v_mayd   := case when jsonb_typeof(p_data->'maydonlar') = 'array'  then p_data->'maydonlar' end;

  if jsonb_typeof(p_data->'filial_ids') = 'array' then
    select coalesce(array_agg(distinct x::uuid), '{}'::uuid[])
      into v_fil
      from jsonb_array_elements_text(p_data->'filial_ids') x
     where nullif(btrim(x), '') is not null;
  end if;

  -- ---- 3) TALABLARNI MAJBURLASH (server qatlami) ---------------------
  -- 🔴 Bu tekshiruvlar UI dagi bilan bir xil, lekin UI dan MUSTAQIL:
  --    yangi klient yozilsa ham teshik ochilmasin.
  if coalesce((v_talab->>'chek')::boolean, false) and not v_chek then
    raise exception 'Bu xarajat uchun chek surati shart' using errcode = '22000';
  end if;
  -- 🔴 2026-09-15 (Asilbek): Excel IXTIYORIY — izoh YOKI jadval yetarli.
  --    Ruxsat so'rovida izoh baribir ruxsat_yarat ichida majburiy, shuning
  --    uchun bu tekshiruv faqat izoh ham, jadval ham bo'sh kelsa ishlaydi.
  if coalesce((v_talab->>'excel')::boolean, false) and v_jadval is null
     and nullif(btrim(coalesce(p_data->>'izoh', '')), '') is null then
    raise exception 'Izoh yozing yoki Excel jadvalini yuklang' using errcode = '22000';
  end if;
  if coalesce((v_talab->>'filial')::boolean, false) and coalesce(array_length(v_fil, 1), 0) = 0 then
    raise exception 'Bu xarajat uchun filial tanlanishi shart' using errcode = '22000';
  end if;
  if coalesce((v_talab->>'davr')::boolean, false) and (v_ds is null or v_de is null) then
    raise exception 'Bu xarajat uchun davr sanasi shart' using errcode = '22000';
  end if;
  if v_ds is not null and v_de is not null and v_de < v_ds then
    raise exception 'Davr oxiri boshidan oldin bolmaydi' using errcode = '22000';
  end if;
  if coalesce((v_talab->>'kommunal')::boolean, false) and v_komm is null then
    raise exception 'Kommunal turini tanlang' using errcode = '22000';
  end if;

  -- Maxsus maydonlar: har MAJBURIY maydon uchun bosh bolmagan qiymat kelsin.
  if coalesce((v_talab->>'maydon_req')::boolean, false) then
    select string_agg(m.nom, ', ' order by m.tartib, m.nom)
      into v_yoq
      from xarajat_maydon m
      join xarajat_maydon_modda mm on mm.maydon_id = m.id
     where m.is_active
       and mm.modda_id = v_modda
       and coalesce(mm.required, m.required)
       and not exists (
             select 1 from jsonb_array_elements(coalesce(v_mayd, '[]'::jsonb)) x
              where (x->>'maydon_id')::uuid = m.id
                and (nullif(x->>'element_id', '') is not null
                     or nullif(btrim(coalesce(x->>'qiymat', '')), '') is not null));
    if v_yoq is not null then
      raise exception 'Toldirilmagan majburiy maydon: %', v_yoq using errcode = '22000';
    end if;
  end if;

  -- Jadval hajmi (ruxsat_sorov_jadval_chk bilan bir xil chegara).
  if v_jadval is not null and pg_column_size(v_jadval) > 120000 then
    raise exception 'Jadval hajmi juda katta' using errcode = '22000';
  end if;

  -- entry_uid band bolmasin (chek fayli boshqa yozuvga yopishmasin).
  if v_euid is not null then
    if exists (select 1 from entry where id = v_euid)
       or exists (select 1 from ruxsat_sorov where entry_uid = v_euid) then
      raise exception 'Yozuv kaliti band — sahifani yangilab qayta urining' using errcode = '22000';
    end if;
  end if;

  -- ---- 4) Sorovning ozi — ESKI RPC (qoidalar bir joyda) --------------
  v_res := ruxsat_yarat(
             nullif(p_data->>'kassa', '')::uuid,
             v_modda,
             nullif(p_data->>'summa', '')::numeric,
             p_data->>'izoh',
             nullif(p_data->>'kimdan', '')::uuid,
             nullif(p_data->>'ext_ref', ''));

  if not coalesce((v_res->>'ok')::boolean, false) then
    return v_res;                       -- kod=takror va boshqalar ozgarmasdan qaytadi
  end if;

  v_id := (v_res->>'ruxsat_id')::uuid;

  -- ---- 5) Metadata — AYNI tranzaksiyada ------------------------------
  update ruxsat_sorov
     set entry_uid     = v_euid,
         chek_bor      = v_chek,
         filial_ids    = v_fil,
         davr_start    = v_ds,
         davr_end      = v_de,
         kommunal_turi = v_komm,
         jadval        = v_jadval,
         maydonlar     = v_mayd
   where id = v_id;

  return v_res || jsonb_build_object('v', 2);
end $fn$;

revoke all on function ruxsat_yarat_v2(jsonb) from public, anon;
grant execute on function ruxsat_yarat_v2(jsonb) to authenticated;

comment on function ruxsat_yarat_v2(jsonb) is
  'Ruxsat sorovi + moddaning HAMMA talabi (chek/filial/davr/kommunal/excel/maxsus maydon) '
  'BITTA tranzaksiyada. Eski ruxsat_yarat ni ichidan chaqiradi (qoidalar bir joyda). '
  'Ovqat va spidometr moddalari RAD etiladi — sorov shakli ularni ifodalay olmaydi.';

-- ============================================================================
--  DIAG — funksiya yangilanganini tekshirish (tanada yangi matn bormi)
-- ============================================================================
do $diag$
begin
  if position('Izoh yozing yoki Excel' in pg_get_functiondef('public.ruxsat_yarat_v2(jsonb)'::regprocedure)) > 0 then
    raise notice 'ruxsat_yarat_v2: Excel IXTIYORIY (izoh yoki jadval) — OK';
  else
    raise exception 'YAKUNIY TEKSHIRUV: ruxsat_yarat_v2 yangilanmadi';
  end if;
end
$diag$;
