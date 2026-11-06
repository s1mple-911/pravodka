-- ============================================================================
--  PROVODKA_FILIAL_YOPISH_20261106.sql — 2026-11-06 — YOPILGAN FILIAL KASSALARINI NOFAOL QILISH
--  Asilbek ro'yxati (06.11.2026): Aviasozlar Bozori, Farhod bozori, Kattaqorgon Eski shahar, Nukus,
--  Nukus Markaziy bozori, Fargona Oltiariq, Chorsu Bozori, Buyuk Ipak Yoli metro, Buxoro Kitoblar Olami.
--
--  Nima qiladi (bitta tranzaksiya, takror RUN xavfsiz):
--   0) Zaxira jadvali accounts_filial_yopish_20261106_zaxira (to'liq qator jsonb) — qaytarish uchun.
--   1) Filial kassalari (accounts.filial_ref = Aros cachier id: 21 22 23 27 29 30 31 7) va ularning HAMMA
--      bola-hisoblari (Naqd/Click/Payme/Terminal/USD/Xarajat) → is_active = false.
--   2) Shu filiallarning tovar (ombor) hisoblari 2922 2933 2934 2935 2936 2937 2938 2939 2940 → is_active = false.
--  Nega O'CHIRILMAYDI: hisoblarda yozuvlar bor (entry_line FK) — jismonan o'chirish mumkin emas va tarix buzilardi.
--  is_active=false bo'lgach: v_filial_sync_mapping (Balans Sync / Transfer Sync) ularni KO'RMAYDI, v_filial_tanlov,
--  v_filial_royxat, kassa.html «Filial kassalari» ro'yxatidan chiqadi. Eski yozuvlar jurnalda qoladi.
--  ⚠️ Nukus Markaziy bozori (5229, ref 23) — Aros'da 05.11.2026 gacha kassa hujjati bor va Pravodka daftarida
--     52 026 900 so'm qoldiq turibdi. Yopilmasin desangiz pastdagi ro'yxatdan '23' va 2935 ni olib tashlang.
--  Asilbek RUN qiladi (Supabase SQL editor).
-- ============================================================================

begin;

create table if not exists accounts_filial_yopish_20261106_zaxira (
  account_id uuid primary key,
  qator      jsonb not null,
  saqlandi   timestamptz not null default now()
);

do $yop$
declare
  v_refs   text[] := array['21','22','23','27','29','30','31','7'];
  v_tovar  text[] := array['2922','2933','2934','2935','2936','2937','2938','2939','2940'];
  v_ids    uuid[];
  v_n      int;
begin
  -- kassalar (parent) + bolalari + tovar hisoblari
  select array_agg(id) into v_ids
    from accounts a
   where a.is_active
     and ( btrim(a.filial_ref::text) = any(v_refs)
        or a.parent_id in (select id from accounts p where btrim(p.filial_ref::text) = any(v_refs))
        or a.code = any(v_tovar) );
  if v_ids is null or array_length(v_ids, 1) is null then
    raise notice 'Nofaol qilinadigan faol hisob topilmadi (allaqachon bajarilgan?)';
    return;
  end if;

  insert into accounts_filial_yopish_20261106_zaxira (account_id, qator)
  select a.id, to_jsonb(a) from accounts a where a.id = any(v_ids)
  on conflict (account_id) do nothing;

  update accounts set is_active = false where id = any(v_ids);
  get diagnostics v_n = row_count;
  raise notice 'Nofaol qilindi: % ta hisob', v_n;
end
$yop$;

commit;

-- Tekshiruv
select code, name, filial_ref, is_active
  from accounts
 where id in (select account_id from accounts_filial_yopish_20261106_zaxira)
 order by code;

-- ---------------------------------------------------------------- QAYTARISH (kerak bo'lsa)
-- update accounts a set is_active = true
--   from accounts_filial_yopish_20261106_zaxira z
--  where a.id = z.account_id and (z.qator->>'is_active')::boolean;
