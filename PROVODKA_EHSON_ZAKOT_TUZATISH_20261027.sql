-- ============================================================================
--  PROVODKA_EHSON_ZAKOT_TUZATISH_20261027.sql — Zakot kassa qoldig'i −474 000 -> +476 000
--  Sabab: Zakot kassaning «dollar» pul turiga dollar miqdorsiz, so'mda −950 000 kirim (tuzatish)
--  yozilgan. Haqiqiy qoldiq 476 000 so'm (naqd). Shu bitta yozuv soft-delete qilinadi
--  (is_deleted=true) — v_ehson_kassa_pul / v_ehson_kassa is_deleted=false'ni o'qiydi, qoldiq o'zi tuzaladi.
--  ADDITIVE: hech narsa drop/hard-delete qilinmaydi. IDEMPOTENT: ikkinchi RUN'da yozuv topilmaydi -> hech narsa.
--  Supabase SQL Editor'da RUN qiling (service role, auth.uid() null bo'ladi — tarix 'kim' null).
-- ============================================================================

-- 0) OLDIN — nima bor (ko'rish uchun)
select k.id, ks.nom as kassa, k.pul_turi, k.valyuta, k.summa, k.fc_summa, k.tur, k.sana, k.manba, k.izoh,
       k.created_at, k.is_deleted
  from ehson_kirim k join ehson_kassa ks on ks.id = k.kassa_id
 where lower(ks.nom) like '%zakot%' and k.is_deleted = false
 order by k.created_at;

-- 1) TUZATISH — faqat: Zakot · pul_turi dollar · summa = −950 000 · dollar miqdori 0/null
do $zk$
declare
  r record;
  v_n int := 0;
begin
  for r in
    select k.id, k.summa, k.pul_turi, k.izoh
      from ehson_kirim k join ehson_kassa ks on ks.id = k.kassa_id
     where lower(ks.nom) like '%zakot%'
       and k.is_deleted = false
       and k.pul_turi = 'dollar'
       and k.summa = -950000
       and coalesce(k.fc_summa, 0) = 0
  loop
    update ehson_kirim
       set is_deleted = true,
           deleted_at = now(),
           deleted_by = auth.uid(),
           izoh = coalesce(izoh, '') || ' | 2026-10-27 bekor: dollar pul turiga so''mda manfiy tuzatish xato yozilgan, Zakot haqiqiy qoldiq 476 000'
     where id = r.id;
    perform _ehson_tarix_yoz('kirim', r.id, 'balans_togrilandi_bekor',
      jsonb_build_object('summa', r.summa, 'pul_turi', r.pul_turi, 'sabab', 'Zakot -474000 -> 476000 (2026-10-27)'));
    v_n := v_n + 1;
  end loop;
  raise notice 'Zakot tuzatish: % ta yozuv bekor qilindi', v_n;
  if v_n > 1 then
    raise exception 'Kutilgan 1 ta yozuv, topildi % — tekshiring (rollback)', v_n;
  end if;
end
$zk$;

-- 2) KEYIN — Zakot qoldiq (kutiladi: naqd/UZS 476 000, dollar yo'q yoki 0)
select ks.nom as kassa, p.pul_turi, p.valyuta, p.kirim, p.berildi, p.qoldiq, p.fc_qoldiq
  from v_ehson_kassa_pul p join ehson_kassa ks on ks.id = p.kassa_id
 where lower(ks.nom) like '%zakot%'
 order by p.pul_turi;

select nom, kirim, berildi, qoldiq
  from v_ehson_kassa
 where lower(nom) like '%zakot%';
