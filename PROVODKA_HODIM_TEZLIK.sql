-- =====================================================================
-- PROVODKA_HODIM_TEZLIK.sql
-- hodim-dev.html tezligi: qoldiq + oylik jami BITTA so'rovda + indekslar
-- =====================================================================
-- Muammo: hodim sahifasi ochilganda "Umumiy qoldiq" uzoq kutadi.
--   • qoldiq har hisob uchun alohida so'rov / yoki v_hisob_bal (RLS invoker)
--   • "Bu oy sarflandi" har bola-hisob uchun alohida hodim_oy_jami chaqiruvi
-- Yechim: ikkita to'plamli (set-based) SECURITY DEFINER RPC + indekslar.
--
-- ⚠️ ADDITIVE: mavjud funksiya/view/ustun o'zgartirilmaydi, o'chirilmaydi.
--    v_hisob_bal va hodim_oy_jami joyida qoladi (klient fallback sifatida
--    ularni ishlatadi — RPC bo'lmasa sahifa avvalgidek ishlayveradi).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Indekslar — ALOHIDA faylda: PROVODKA_HODIM_INDEKS.sql
-- ---------------------------------------------------------------------
-- `create index concurrently` tranzaksiya ichida ishlamaydi, Supabase SQL Editor
-- esa butun skriptni bitta tranzaksiyada bajaradi. Shuning uchun indekslar shu
-- fayldan CHIQARILDI — ular PROVODKA_HODIM_INDEKS.sql da, bitta-bittadan RUN qilinadi.
-- Indekslarsiz ham bu fayldagi funksiyalar ishlaydi (shunchaki sekinroq).


-- ---------------------------------------------------------------------
-- 2. hodim_qoldiqlar — bir nechta hisob qoldig'i BITTA chaqiruvda
-- ---------------------------------------------------------------------
-- Qaytishi: { "<account_id>": {"uzs": 123, "fc": 4.5}, ... }
-- Ro'yxatda bor, lekin yozuvi yo'q hisob ham chiqadi (nol bilan) — klient
-- "qoldiq noma'lum" bilan "qoldiq nol" ni ajrata olishi uchun.
-- SECURITY DEFINER: hodim o'z kassasi qoldig'ini ishonchli ko'rsin (RLS to'smasin) —
-- hodim_oy_jami bilan bir xil naqsh. Qoldiq ko'rsatish pul harakati emas.
create or replace function hodim_qoldiqlar(p_accounts uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_ids uuid[];
begin
  -- RUXSAT: SECURITY DEFINER RLS'ni chetlab o'tadi, shuning uchun kim qaysi hisobni
  -- so'rayotgani TEKSHIRILADI. Aks holda har authenticated user bitta chaqiruv bilan
  -- barcha kassalarning qoldig'ini olardi (accounts id'lari klientda ochiq).
  -- perm_check_accounts: admin / scope<>'list' → true; 'list' → perm_op_key bo'yicha.
  --
  -- XATO EMAS, FILTR: ruxsatsiz hisob natijadan jimgina chiqib ketadi. Sababi —
  -- `perm_op_key` ustunlarga tayanadi va eski, ustunsiz tur hisoblari (5351 "· Naqd")
  -- ruxsat kalitini parentdan olmaydi. Xato qaytarsak butun hero "—" bo'lib qolardi;
  -- filtrda esa qolgan kassalar qoldig'i baribir ko'rinadi.
  -- (PROVODKA_TUR_BOGLASH.sql ustunlarni to'ldirgach bu holat yo'qoladi.)
  if to_regprocedure('perm_check_accounts(uuid[])') is not null
     and not perm_check_accounts(p_accounts) then
    select array_agg(x) into v_ids
      from unnest(p_accounts) as t(x)
     where perm_check_accounts(array[x]);
    p_accounts := coalesce(v_ids, '{}'::uuid[]);
  end if;

  return (
  select coalesce(
    jsonb_object_agg(x.id::text, jsonb_build_object('uzs', x.uzs, 'fc', x.fc)),
    '{}'::jsonb)
  from (
    -- LEFT JOIN: yozuvi yo'q hisob ham qatorda qoladi (nol bilan).
    -- Satr hisobga kiradimi-yo'qmi — e.id null emasligidan bilinadi (posted + o'chirilmagan).
    select a.id,
           coalesce(sum(case when e.id is not null then l.debit - l.credit end), 0) as uzs,
           coalesce(sum(case when e.id is null then null
                             when l.debit > 0 then coalesce(l.fc_amount, 0)
                             else - coalesce(l.fc_amount, 0) end), 0) as fc
      from unnest(p_accounts) as a(id)
      left join entry_line l on l.account_id = a.id
      left join entry e on e.id = l.entry_id
                       and e.status = 'posted' and e.is_deleted = false
     group by a.id
  ) x);
end $$;

revoke all on function hodim_qoldiqlar(uuid[]) from public, anon;
grant execute on function hodim_qoldiqlar(uuid[]) to authenticated;

comment on function hodim_qoldiqlar(uuid[]) is
  'Bir nechta hisob qoldig''i bitta chaqiruvda: {id: {uzs, fc}}. '
  'v_hisob_bal bilan bir xil mantiq (posted + o''chirilmagan), lekin definer va to''plamli.';


-- ---------------------------------------------------------------------
-- 3. hodim_oy_jami_kop — kassa + bola-hisoblari bo'yicha davr jamisi
-- ---------------------------------------------------------------------
-- hodim_oy_jami(uuid,...) bitta hisobni biladi; kassaning naqd/Click/Payme/USD
-- bolalari bo'lsa klient N marta chaqirishga majbur edi. Bu esa bitta so'rov.
-- Mantiq hodim_oy_jami bilan AYNAN bir xil: Kt yig'indisi, qarshi tomoni type='xarajat'.
create or replace function hodim_oy_jami_kop(p_accounts uuid[], p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(el.credit), 0)
    from entry_line el
    join entry e on e.id = el.entry_id
   where el.account_id = any(p_accounts)
     and el.credit > 0
     and e.status = 'posted'
     and e.is_deleted = false
     and e.entry_date >= p_from
     and e.entry_date <= p_to
     and exists (
       select 1
         from entry_line dl
         join accounts a on a.id = dl.account_id
        where dl.entry_id = e.id
          and dl.debit > 0
          and a.type = 'xarajat'
     );
$$;

revoke all on function hodim_oy_jami_kop(uuid[], date, date) from public, anon;
grant execute on function hodim_oy_jami_kop(uuid[], date, date) to authenticated;

comment on function hodim_oy_jami_kop(uuid[], date, date) is
  'Kassa va bola-hisoblaridan davr ichida chiqqan xarajat jami (hodim_oy_jami ning to''plamli varianti).';


notify pgrst, 'reload schema';

do $$
begin
  if to_regprocedure('hodim_qoldiqlar(uuid[])') is null then
    raise exception 'hodim_qoldiqlar yaratilmadi';
  end if;
  if to_regprocedure('hodim_oy_jami_kop(uuid[],date,date)') is null then
    raise exception 'hodim_oy_jami_kop yaratilmadi';
  end if;
  raise notice 'OK: hodim tezlik RPC lari + indekslar tayyor';
end $$;
