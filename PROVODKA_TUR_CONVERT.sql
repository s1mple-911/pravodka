-- =====================================================================
--  PROVODKA_TUR_CONVERT.sql — bir kassa ichida TUR ↔ TUR o'tkazish
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  RPC:  tur_convert(p_from uuid, p_to uuid, p_amount numeric,
--                    p_note text default null) -> jsonb
--
--  Misol: Yunusobod · Click  1 000 000  →  Yunusobod · Naqd
--         Dt <maqsad tur>  /  Kt <manba tur>   — ikkovi ham so'm.
--
--  ⚠️⚠️ BU VALYUTA KONVERTI EMAS. Chalkashtirmang:
--     • convert_start_v2  — so'm ↔ valyuta. KURS bor, koridor bor,
--       koridordan chiqsa admin tasdig'i (convert_request) kerak.
--     • tur_convert (shu fayl) — so'm ↔ so'm, bitta kassa ichida.
--       KURS YO'Q, koridor YO'Q, tasdiq YO'Q. Bu shunchaki ko'chirish:
--       kassaning jami qoldig'i O'ZGARMAYDI, faqat taqsimoti o'zgaradi.
--     Shuning uchun alohida funksiya — convert_start_v2 ga tegilmaydi
--     (u ishlab turgan, pul yozadigan RPC).
--
--  QOIDALAR (hammasi serverda tekshiriladi):
--     1. Ikkala hisob ham section='pul', faol, currency='UZS'.
--        Valyuta hisobi berilsa RAD ETILADI -> "Konvert" tugmasiga yo'naltiradi.
--     2. Ikkalasi ham AYNI kassaga tegishli (ildiz bir xil).
--        Ildiz: pul_turi to'ldirilgan bo'lsa parent_id, aks holda hisobning o'zi.
--        Ya'ni parent kassa ↔ o'z tur bolasi ham mumkin (5211 ↔ 5211·Naqd),
--        lekin Izza·Naqd → Yunusobod·Naqd MUMKIN EMAS (bu kassalararo
--        transfer — u provodka.html "Transfer" orqali yoziladi).
--     3. p_amount > 0 va manba turining qoldig'idan oshmasin.
--     4. 5400 (xarajat_guruh) — konteyner, tanlanmaydi.
--
--  ⚠️ FILIAL KASSALARI HAQIDA OGOHLANTIRISH (bloklanmagan, ataylab):
--     Filial kassasining har turi (naqd/click/payme) Aros bilan ALOHIDA
--     sinxronlanadi (sync_filial_balans: delta = aros − daftar, har tur uchun).
--     Provodka'da tur o'tkazsangiz va Aros'da o'sha o'tkazma bo'lmasa,
--     keyingi soatlik sinxron ikkala turni ham "tuzatadi": bir turga soxta
--     tushum, ikkinchisiga soxta chiqim (Kt/Dt 9010) yozadi. Pul yo'qolmaydi,
--     lekin P&L chalg'iydi.
--     Shuning uchun: filial kassasida tur o'tkazish FAQAT Aros'da ham
--     shunday qilingan bo'lsa ma'noli. RPC buni to'smaydi (ba'zan
--     daftarni Aros'ga qo'lda tenglashtirish kerak bo'ladi), lekin
--     javobda `ogohlantirish` qaytaradi va UI uni ko'rsatadi.
--
--  RUXSAT: entry_line ustidagi trg_perm_guard_entry_line HAR DOIM ishlaydi
--     (SECURITY DEFINER auth.uid() ni o'zgartirmaydi). Qo'shimcha ravishda
--     RPC boshida perm_check_accounts() chaqiriladi — bo'lsa. Ya'ni
--     "amaliyot" ruxsati yo'q kassada tur o'tkazib bo'lmaydi.
--     Konvert ruxsati (can_convert) BU YERDA TEKSHIRILMAYDI — bu valyuta
--     konverti emas, oddiy ichki ko'chirish.
--
--  ATOMIK: bitta plpgsql tranzaksiyasi — entry va ikkala satr birga
--     yoziladi yoki umuman yozilmaydi (klientdagi "avval entry, keyin
--     satrlar, xato bo'lsa entry'ni delete" kompensatsiyasi kerak emas).
--
--  TALAB: PROVODKA_VALYUTA.sql (accounts.pul_turi).
-- =====================================================================


create or replace function tur_convert(p_from uuid, p_to uuid, p_amount numeric,
                                       p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f accounts%rowtype;
  t accounts%rowtype;
  v_who    text;
  v_bal    numeric;
  v_froot  uuid;
  v_troot  uuid;
  v_entry  uuid;
  v_ogoh   text := null;
  v_ok     boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'Avtorizatsiya kerak');
  end if;

  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('ok', false, 'error', 'Summa noto''g''ri');
  end if;
  if p_from is null or p_to is null then
    return jsonb_build_object('ok', false, 'error', 'Manba va maqsad turini tanlang');
  end if;
  if p_from = p_to then
    return jsonb_build_object('ok', false, 'error', 'Manba va maqsad bir xil');
  end if;

  select * into f from accounts where id = p_from;
  select * into t from accounts where id = p_to;
  if f.id is null or t.id is null then
    return jsonb_build_object('ok', false, 'error', 'Hisob topilmadi');
  end if;
  if not f.is_active or not t.is_active then
    return jsonb_build_object('ok', false, 'error', 'Hisob faol emas');
  end if;
  if coalesce(f.section, '') <> 'pul' or coalesce(t.section, '') <> 'pul' then
    return jsonb_build_object('ok', false, 'error', 'Faqat pul hisoblari o''rtasida');
  end if;
  if coalesce(f.kassa_turi, '') = 'xarajat_guruh' or coalesce(t.kassa_turi, '') = 'xarajat_guruh' then
    return jsonb_build_object('ok', false,
      'error', 'Guruh hisobiga (5400) pul yozilmaydi — hodim kassasini tanlang');
  end if;

  -- Valyuta hisobi bu yerga tushmasin: kurs kerak bo'ladi, u esa boshqa RPC'da
  if coalesce(f.currency, 'UZS') <> 'UZS' or coalesce(t.currency, 'UZS') <> 'UZS' then
    return jsonb_build_object('ok', false,
      'error', 'Bu so''m turlari orasidagi o''tkazma. Valyuta uchun "Konvert" tugmasidan foydalaning');
  end if;

  -- Ildiz kassa: tur bolasi bo'lsa parenti, aks holda o'zi.
  -- ⚠️ parent_id ko'p ma'noli (hodim kassasining parenti 5400 konteyner),
  --    shuning uchun shart aynan pul_turi bo'yicha — parent_id bo'yicha emas.
  v_froot := case when f.pul_turi is not null then f.parent_id else f.id end;
  v_troot := case when t.pul_turi is not null then t.parent_id else t.id end;
  if v_froot is null or v_troot is null or v_froot <> v_troot then
    return jsonb_build_object('ok', false,
      'error', 'Ikkala tur ham AYNI kassaga tegishli bo''lishi kerak. '
               'Kassadan kassaga ko''chirish uchun "Transfer" ishlating');
  end if;

  -- Amaliyot ruxsati (PROVODKA_PERMS.sql). Ruxsat tizimi o'rnatilmagan bo'lsa
  -- funksiya yo'q — chaqirilmaydi (fayllar bir-birining tartibiga bog'lanmasin).
  -- entry_line trigger'i baribir ikkinchi to'siq bo'lib turadi.
  if to_regprocedure('public.perm_check_accounts(uuid[])') is not null then
    execute 'select perm_check_accounts($1)' into v_ok using array[p_from, p_to];
    if not coalesce(v_ok, true) then
      return jsonb_build_object('ok', false, 'error', 'Bu kassada amaliyot ruxsati yo''q');
    end if;
  end if;

  -- Manba turining qoldig'i (posted + o'chirilmagan). Kassani minusga
  -- tushirish deyarli har doim kiritish xatosi — to'xtatamiz.
  select coalesce(sum(l.debit - l.credit), 0)
    into v_bal
    from entry_line l
    join entry e on e.id = l.entry_id
   where l.account_id = p_from
     and e.status = 'posted'
     and e.is_deleted = false;

  if p_amount > v_bal then
    return jsonb_build_object('ok', false,
      'error', 'Qoldiq yetarli emas: ' || f.name || ' — ' || to_char(v_bal, 'FM999G999G999G999'),
      'qoldiq', v_bal);
  end if;

  -- Filial ogohlantirishi — yozuvni TO'SMAYDI (fayl boshidagi izohga qarang)
  if coalesce(f.kassa_turi, '') = 'filial' or coalesce(t.kassa_turi, '') = 'filial' then
    v_ogoh := 'Filial kassasi Aros bilan sinxronlanadi. Aros''da ham shu o''tkazma '
              || 'qilinmagan bo''lsa, keyingi sinxron uni qaytarib qo''yadi.';
  end if;

  select coalesce(full_name, 'foydalanuvchi') into v_who from profiles where id = auth.uid();

  insert into entry(entry_date, description, source, status, created_by)
  values (current_date,
          'Tur o''tkazish: ' || f.name || ' → ' || t.name || coalesce(' · ' || p_note, ''),
          'manual', 'posted', v_who)
  returning id into v_entry;

  -- Dt maqsad tur / Kt manba tur. fc_amount YO'Q — ikkovi ham so'm.
  insert into entry_line(entry_id, account_id, debit, credit)
  values (v_entry, p_to, p_amount, 0);
  insert into entry_line(entry_id, account_id, debit, credit)
  values (v_entry, p_from, 0, p_amount);

  return jsonb_build_object(
    'ok', true,
    'entry_id', v_entry,
    'summa', p_amount,
    'manba', f.name,
    'maqsad', t.name,
    'qoldiq_edi', v_bal,
    'ogohlantirish', v_ogoh);
end $$;

revoke all on function tur_convert(uuid, uuid, numeric, text) from public, anon;
grant execute on function tur_convert(uuid, uuid, numeric, text) to authenticated;

comment on function tur_convert(uuid, uuid, numeric, text) is
  'Bir kassa ichida tur ↔ tur o''tkazish (naqd/click/payme, faqat so''m). '
  'Dt maqsad / Kt manba. Kurs yo''q, tasdiq yo''q — kassa jami qoldig''i o''zgarmaydi. '
  'Valyuta uchun convert_start_v2 ishlatiladi.';


-- ---------------------------------------------------------------------
--  TEKSHIRUV
-- ---------------------------------------------------------------------

-- T.1 Bitta kassaning turlari va qoldiqlari (o'tkazishdan oldin/keyin)
-- select c.code, c.name, c.pul_turi, c.currency,
--        coalesce((select sum(l.debit - l.credit)
--                    from entry_line l join entry e on e.id = l.entry_id
--                   where l.account_id = c.id
--                     and e.status = 'posted' and e.is_deleted = false), 0) as qoldiq
--   from accounts k
--   join accounts c on c.id = k.id or c.parent_id = k.id
--  where k.code = '5217' and c.is_active
--  order by c.code;

-- T.2 Rad etilishi KERAK bo'lgan holatlar (hammasi ok:false qaytadi):
--   • boshqa kassaning turi   -> 'AYNI kassaga tegishli bo'lishi kerak'
--   • USD hisobi              -> '"Konvert" tugmasidan foydalaning'
--   • qoldiqdan katta summa    -> 'Qoldiq yetarli emas'
--   • p_from = p_to            -> 'Manba va maqsad bir xil'

-- T.3 Yozuv jurnalda TRANSFER bo'lib ko'rinishi kerak (ko'k ⇄, ishorasiz):
--     ikkala satr ham section='pul' — jurnal.html klass() shuni beradi.
-- select e.description, a.code, a.name, l.debit, l.credit
--   from entry e
--   join entry_line l on l.entry_id = e.id
--   join accounts a on a.id = l.account_id
--  where e.description like 'Tur o''tkazish:%' and e.is_deleted = false
--  order by e.created_at desc, l.debit desc
--  limit 20;

-- T.4 Kassa jami qoldig'i O'ZGARMAGANINI tekshirish (eng muhim):
--     o'tkazishdan oldin va keyin bir xil son chiqishi SHART.
-- select jami from v_kassa_card where code = '5217';
