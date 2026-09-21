-- ============================================================================
--  PROVODKA_RUXSAT_KOPLIK.sql — 2026-09-21 — bitta xarajat turiga BIR NECHA ochiq ruxsat so'rovi
--  Asilbek: «userlar so'rov yuborsa bitta xarajat turi uchun keyin yubora olmayapti — 1-so'rov
--  tasdiqlansa/rad etilsagina yana yubora olyapti. Xohlagancha yuboraversin.»
--  Sabab: ruxsat_ochiq_uniq (hodim_id, modda_id) where status='pending' indeksi + ruxsat_yarat 9-tekshiruv.
--  O'zgarish: indeks o'chiriladi; ruxsat_yarat tanasi VERBATIM (PROVODKA_RUXSAT_SOROV.sql), faqat 9-blok olib
--  tashlandi. ruxsat_yarat_v2 (ENG OXIRGI: PROVODKA_EXCEL_IXTIYORIY_2.sql) ichidan ruxsat_yarat ni chaqiradi —
--  unga tegilmaydi. Takror-bosish himoyasi (ext_ref unique, kod 'takror') saqlanadi. Asilbek RUN qiladi.
-- ============================================================================

drop index if exists ruxsat_ochiq_uniq;

create or replace function ruxsat_yarat(
  p_kassa   uuid,
  p_modda   uuid,
  p_summa   numeric,
  p_izoh    text,
  p_kimdan  uuid,
  p_ext_ref text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_ext    text := nullif(btrim(coalesce(p_ext_ref, '')), '');
  v_izoh   text := nullif(btrim(coalesce(p_izoh, '')), '');
  v_modda  accounts;
  v_kassa  accounts;
  v_up     user_perms;
  v_of     uuid;
  v_ruxsat uuid;
begin
  perform set_config('lock_timeout', '5s', true);

  -- 1) Auth
  if v_uid is null then
    raise exception 'Avtorizatsiya kerak' using errcode = '42501';
  end if;

  -- 2) Summa
  if p_summa is null or p_summa <= 0 or p_summa <> round(p_summa, 2) then
    raise exception 'Summa musbat bolishi kerak' using errcode = '22000';
  end if;
  if p_summa > 100000000 then
    raise exception 'Sorov summasi juda katta — tekshirib qayta yozing' using errcode = '22000';
  end if;

  -- 3) Izoh — majburiy
  if v_izoh is null or length(v_izoh) < 3 then
    raise exception 'Izoh majburiy (kamida 3 belgi)' using errcode = '22000';
  end if;
  if length(v_izoh) > 200 then
    raise exception 'Izoh 200 belgidan oshmasin' using errcode = '22000';
  end if;

  -- 4) ext_ref shakli (sorov_yarat 6.3 bilan bir xil)
  if v_ext is not null and (length(v_ext) < 8 or length(v_ext) > 120) then
    raise exception 'ext_ref token 8..120 belgi bolishi kerak' using errcode = '22000';
  end if;

  -- 5) Modda — mavjud, faol, xarajat VA aynan YOPIQ bolsin
  select * into v_modda from accounts where id = p_modda;
  if not found or v_modda.is_active is distinct from true then
    raise exception 'Xarajat moddasi topilmadi yoki faol emas' using errcode = '22000';
  end if;
  if v_modda.type <> 'xarajat' then
    raise exception 'Tanlangan hisob xarajat moddasi emas' using errcode = '22000';
  end if;
  -- 🔴 Ochiq moddaga ruxsat sorab bolmaydi — bunday sorov mantiqsiz
  --    (xarajatni oddiy yolda yozish mumkin).
  if rbac_modda_ok(p_modda) then
    raise exception 'Bu modda sizga ochiq — ruxsat kerak emas, xarajatni oddiy yozing'
      using errcode = '22000';
  end if;

  -- 6) Kassa — sorov_yarat 6.5 bilan bir xil qoida + oila chegarasi
  select * into v_kassa from accounts where id = p_kassa;
  if not found or v_kassa.is_active is distinct from true then
    raise exception 'Kassa topilmadi yoki faol emas' using errcode = '22000';
  end if;
  if v_kassa.type <> 'aktiv' or v_kassa.code not like '5%'
     or v_kassa.kassa_turi is not distinct from 'xarajat_guruh' then
    raise exception 'Bu hisob kassa emas' using errcode = '22000';
  end if;
  if coalesce(v_kassa.currency, 'UZS') <> 'UZS' then
    raise exception 'Ruxsat sorovi faqat som kassasida ishlaydi' using errcode = '22000';
  end if;
  if not perm_check_accounts(array[p_kassa]) then
    raise exception 'Ruxsat yoq: bu kassada amaliyot qilish huquqingiz yoq'
      using errcode = '42501';
  end if;
  -- 🔴 OILA CHEGARASI (sorov_yarat 6.5b naqshi) — admin uchun otkazib
  --    yuboriladi (unda biriktirilgan kassa yoq).
  if not is_admin() then
    v_of := sorov_kassa_of(v_uid);
    select * into v_up from user_perms where user_id = v_uid;
    if v_of is null or not found or v_up.kassa_scope <> 'list' then
      raise exception 'Sizga kassa biriktirilmagan — ruxsat sorovi ishlamaydi'
        using errcode = '42501';
    end if;
    if not (
      perm_op_key(p_kassa) = perm_op_key(v_of)
      or perm_op_key(p_kassa) = any (coalesce(v_up.op_kassa_ids, '{}'::uuid[]))
    ) then
      raise exception 'Bu hisob sizning kassangiz emas' using errcode = '42501';
    end if;
  end if;

  -- 7) PUL YETADIMI (Asilbek qarori) — kassangizda pul yetmasa ruxsat emas,
  --    "Pul sorash" orqali sorash kerak. Klient PUL_YETMAYDI prefiksini ushlaydi.
  if sorov_kassa_bal(p_kassa) < p_summa then
    raise exception 'PUL_YETMAYDI: tanlangan hisobda pul yetmaydi — boshqa hisobni (Naqd/Click/Payme) tanlang yoki «Pul sorash» orqali pul sorang'
      using errcode = '22000';
  end if;

  -- 8) Kimdan (tasdiqlovchi)
  if p_kimdan is null then
    raise exception 'Kimdan sorash tanlanmagan' using errcode = '22000';
  end if;
  if p_kimdan = v_uid then
    raise exception 'Ozingizdan ruxsat sorab bolmaydi' using errcode = '22000';
  end if;
  if not sorov_nomzod_ok(p_kimdan) then
    raise exception 'Bu odamdan ruxsat sorab bolmaydi (kassasi yoki sorovlar ruxsati yoq)'
      using errcode = '22000';
  end if;

  -- 9) (2026-09-21, Asilbek: «xohlagancha yuboraversin») — bitta moddaga bir necha ochiq
  --    so'rov RUXSAT. Eski «javob kutayotgan sorovingiz bor» tekshiruvi va ruxsat_ochiq_uniq
  --    indeksi olib tashlandi (PROVODKA_RUXSAT_KOPLIK.sql). Takror himoyasi ext_ref (unique) da qoladi.

  insert into ruxsat_sorov (hodim_id, kimdan_id, kassa_id, modda_id, summa, izoh, ext_ref)
  values (v_uid, p_kimdan, p_kassa, p_modda, p_summa, v_izoh, v_ext)
  returning id into v_ruxsat;

  return jsonb_build_object('ok', true,
                            'ruxsat_id', v_ruxsat,
                            'status',    'pending',
                            'turi',      'ruxsat');

exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'kod', 'takror');
end $fn$;


revoke all on function ruxsat_yarat(uuid, uuid, numeric, text, uuid, text) from public, anon;
grant execute on function ruxsat_yarat(uuid, uuid, numeric, text, uuid, text) to authenticated;

select 'ruxsat_ochiq_uniq' as indeks,
       case when exists (select 1 from pg_indexes where indexname = 'ruxsat_ochiq_uniq') then '❌ hali bor' else '✅ ochirildi' end as holat,
       case when pg_get_functiondef('public.ruxsat_yarat(uuid,uuid,numeric,text,uuid,text)'::regprocedure) like '%javob kutayotgan%' then '❌ eski tana' else '✅ yangi tana' end as funksiya;
