-- ============================================================================
--  PROVODKA_EHSON_QARZ_TUZATISH_BEKOR_20261017.sql — 2026-10-17 — 'b' balans to'g'irlashni BEKOR qilish
--  PROVODKA_EHSON_QARZ_ROYXAT_20261017.sql ning birinchi versiyasi qarzlardan keyin balansni maqsadga qaytargan edi
--  (marker balans_togrilandi_20261017b, izoh «... (Asilbek, qarzlardan keyin)»). Faraz xato: maqsad qoldiqlar qarzlardan
--  OLDINGI. Bu fayl faqat o'sha 'b' tuzatish qatorlarini bekor qiladi (soft-delete, ehson_kirim.is_deleted — balans view'lari
--  is_deleted=false ni sanaydi) va ehson_tarix ga bekor izi yozadi. Natija: qoldiq = maqsad − qarzlar.
--  TEGILMAYDI: birinchi to'g'irlash (balans_togrilandi_20261017 / «Balans to'g'irlash 2026-10-17 (Asilbek)»), qarzlar.
--  Idempotent: faqat hali bekor qilinmagan 'b' qatorlar o'zgaradi. Hech narsa o'chirilmaydi. Asilbek RUN qiladi.
--  Oxirida kassa qoldiqlari jadvali chiqadi.
-- ============================================================================

do $eqb_pre$
begin
  if to_regclass('public.ehson_kirim') is null or to_regclass('public.v_ehson_kassa_pul') is null then
    raise exception 'ehson_kirim / v_ehson_kassa_pul yoq — avval ehson SQL fayllari';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ehson_kirim' and column_name = 'tur') then
    raise exception 'ehson_kirim.tur yoq — avval PROVODKA_EHSON_KIRIM.sql';
  end if;
end
$eqb_pre$;

do $eqb_bekor$
declare
  r record;
begin
  for r in
    select id, kassa_id, pul_turi, summa, fc_summa from ehson_kirim
     where tur = 'tuzatish' and is_deleted = false
       and izoh = 'Balans to''g''irlash 2026-10-17 (Asilbek, qarzlardan keyin)'
  loop
    update ehson_kirim set is_deleted = true, deleted_at = now(), deleted_by = null where id = r.id;
    perform _ehson_tarix_yoz('kirim', r.id, 'bekor',
      jsonb_build_object('sabab', 'balans_togrilandi_20261017b bekor: maqsad qoldiq qarzlardan OLDINGI edi',
                         'pul_turi', r.pul_turi, 'summa', r.summa, 'fc_summa', r.fc_summa));
    perform _ehson_tarix_yoz('kassa', r.kassa_id, 'balans_togrilandi_20261017b_bekor',
      jsonb_build_object('pul_turi', r.pul_turi, 'kirim_id', r.id));
  end loop;
end
$eqb_bekor$;

-- NATIJA: kassa qoldiqlari (UZS -> qoldiq, USD -> fc_qoldiq)
select k.nom as kassa, p.pul_turi, p.valyuta,
       case when p.valyuta = 'USD' then p.fc_qoldiq else p.qoldiq end as qoldiq
  from v_ehson_kassa_pul p join ehson_kassa k on k.id = p.kassa_id
 where p.pul_turi in ('naqd', 'dollar')
 order by k.nom, p.pul_turi;
