-- =====================================================================
-- PROVODKA_VALYUTA_ALIAS.sql — valyuta kodi ALIASLARI (CHY = CNY)
-- ---------------------------------------------------------------------
-- MUAMMO (2026-08-19, Asilbek):
--   Valyuta bo'limida qo'lda "CHY → UZS" kursi qo'shilgan, lekin
--   Tannarx (yuklar) sahifasi va Professional'da yuk tanlanganda
--   "kurs yo'q" chiqadi.
--
-- SABAB:
--   Kurs izlashning YAGONA joyi — conv_baza_kurs(p_cur):
--       select rate from currency_rate where from_code = p_cur and to_code='UZS'
--   yuk_kurslar(p_curs) esa Aros kodini QATTIQ kod bilan o'giradi:
--       CHY -> CNY   (PROVODKA_YUK_QISMAN.sql, 110-qator)
--   Ya'ni yuk valyutasi 'CHY' bo'lsa server 'CNY → UZS' qatorini izlaydi,
--   bazada esa 'CHY → UZS' turibdi → topilmaydi → null → "kurs yo'q".
--   valyuta-dev.html dagi kod ro'yxati Aros'dan keladi ('CHY'), ya'ni
--   qo'lda 'CNY' deb yozib ham bo'lmaydi — UI hech qachon serverni
--   qoniqtiradigan kodni bera olmaydi.
--
-- YECHIM:
--   Alias jadvali + ekvivalentlik sinfi, va u conv_baza_kurs ICHIGA
--   qo'yiladi — ya'ni bitta choke point. Shu bilan CHY va CNY hamma
--   joyda bir xil valyuta bo'ladi: tannarx, professional, jurnal,
--   hodim, kassa (konvert koridori), qarzdor.
--
-- ADDITIVE: yangi jadval + yangi funksiya + 2 ta `create or replace`.
--   ESKI IMZO SAQLANGAN — conv_baza_kurs(text), yuk_kurslar(text[]).
--   Ustun/funksiya o'chirilmaydi.
--
-- RUN: Asilbek (Supabase SQL editor). `do $$` bloki YO'Q.
-- =====================================================================


-- =====================================================================
-- 1-BO'LIM — valyuta_alias jadvali
-- ---------------------------------------------------------------------
-- alias -> kanonik kod. Ikkalasi ham currency_rate / accounts.currency
-- da uchrashi mumkin, farqi yo'q: qidiruv ikki tomonlama ishlaydi.
-- Yangi moslik kerak bo'lsa shu jadvalga bitta qator qo'shiladi,
-- kod o'zgarmaydi.
-- =====================================================================

create table if not exists valyuta_alias (
  alias      text primary key,
  kod        text not null,
  izoh       text,
  created_at timestamptz not null default now()
);

insert into valyuta_alias(alias, kod, izoh) values
  ('CHY', 'CNY', 'Aros valyuta lugatida yuan CHY deb yuritiladi, ISO kodi CNY')
on conflict (alias) do nothing;

alter table valyuta_alias enable row level security;
drop policy if exists valyuta_alias_read on valyuta_alias;
create policy valyuta_alias_read on valyuta_alias for select to authenticated using (true);
revoke all on valyuta_alias from public, anon;
grant select on valyuta_alias to authenticated;

comment on table valyuta_alias is
  'Valyuta kodi aliaslari (CHY=CNY). conv_baza_kurs ekvivalentlik sinfi shundan quriladi.';


-- =====================================================================
-- 2-BO'LIM — cur_ekvivalent(p_cur) — bitta valyutaning HAMMA kodi
-- ---------------------------------------------------------------------
-- 'CHY' -> {CHY, CNY};  'CNY' -> {CNY, CHY};  'USD' -> {USD}
-- Kirish kodi HAR DOIM natijada bo'ladi (alias jadvali bo'sh bo'lsa ham
-- xatti-harakat avvalgidek qoladi — fail-safe).
-- =====================================================================

create or replace function cur_ekvivalent(p_cur text)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
-- 🔴 Bu yerda quyi-so'rov (`select ... union select k`) ISHLATILMAYDI.
--    plpgsql'da FROM'siz `select <o'zgaruvchi>` ni Postgres jadval nomi deb
--    o'qiydi va 42P01 "relation k does not exist" beradi. Shuning uchun
--    massiv sikl bilan yig'iladi. O'zgaruvchilar `v_` prefiksli — ustun
--    nomlari (alias, kod) bilan aralashib ketmasin.
declare v_c text; v_k text; v_res text[]; v_row record;
begin
  v_c := upper(nullif(trim(coalesce(p_cur, '')), ''));
  if v_c is null then return null; end if;

  -- kanonik shakl: kirish alias bo'lsa uning kodi, aks holda o'zi
  select upper(a.kod) into v_k from valyuta_alias a where upper(a.alias) = v_c limit 1;
  if v_k is null then v_k := v_c; end if;

  v_res := array[v_c];                                        -- kirish kodi HAR DOIM ichida
  if v_k <> v_c then v_res := array_append(v_res, v_k); end if;

  for v_row in
    select upper(a.alias) as x from valyuta_alias a where upper(a.kod) = v_k
  loop
    if not (v_row.x = any(v_res)) then v_res := array_append(v_res, v_row.x); end if;
  end loop;

  return v_res;
end $$;

revoke all on function cur_ekvivalent(text) from public, anon;
grant execute on function cur_ekvivalent(text) to authenticated;

comment on function cur_ekvivalent(text) is
  'Valyuta kodining ekvivalentlik sinfi (CHY <-> CNY). Kirish kodi har doim ichida.';


-- =====================================================================
-- 3-BO'LIM — conv_baza_kurs(p_cur) — ALIAS bilan
-- ---------------------------------------------------------------------
-- IMZO O'ZGARMAGAN: conv_baza_kurs(text) -> numeric.
-- Mantiq avvalgidek: USD -> aros_usd_rate(); so'ng X->UZS; so'ng UZS->X
-- ning teskarisi. YAGONA farq — `= p_cur` o'rniga `= any(ekvivalent)`.
-- =====================================================================

create or replace function conv_baza_kurs(p_cur text)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare v numeric; ekv text[];
begin
  ekv := cur_ekvivalent(p_cur);
  if ekv is null or array_length(ekv, 1) is null then
    return null;
  end if;

  -- USD uchun avval Aros kursi (eski xatti-harakat, tegilmagan)
  if 'USD' = any(ekv) then
    v := aros_usd_rate();
    if v is not null then return v; end if;
  end if;

  select rate into v from currency_rate
   where upper(from_code) = any(ekv) and upper(to_code) = 'UZS'
   order by rate_at desc, created_at desc limit 1;
  if v is not null then return v; end if;

  select case when rate > 0 then 1 / rate end into v from currency_rate
   where upper(from_code) = 'UZS' and upper(to_code) = any(ekv)
   order by rate_at desc, created_at desc limit 1;
  return v;
end $$;

revoke all on function conv_baza_kurs(text) from public, anon;
grant execute on function conv_baza_kurs(text) to authenticated;  -- UI koridorni ko'rsatadi

comment on function conv_baza_kurs(text) is
  'Tayanch kurs (1 birlik valyuta necha som). USD -> aros_usd_rate(), boshqasi currency_rate '
  '(teskari juftlik bolsa 1/rate). Kod valyuta_alias boyicha normallashtiriladi (CHY=CNY). Topilmasa null.';


-- =====================================================================
-- 4-BO'LIM — yuk_kurslar(p_curs) — qattiq kodlangan CHY->CNY olib tashlandi
-- ---------------------------------------------------------------------
-- Endi normallashtirish conv_baza_kurs ichida, ya'ni BITTA joyda.
-- Javob kaliti avvalgidek KIRISH kodi ('CHY') — mijozdagi
-- rateMap[y.valyuta] qidiruvi buzilmasin.
-- =====================================================================

create or replace function yuk_kurslar(p_curs text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare c text; r numeric; out jsonb := '{}'::jsonb;
begin
  if p_curs is null then return out; end if;
  foreach c in array p_curs loop
    if c is null or c = '' then continue; end if;
    if upper(c) = 'UZS' then
      r := 1;
    else
      begin
        r := conv_baza_kurs(c);   -- alias normallashtirish ichida
      exception when others then r := null;
      end;
    end if;
    out := out || jsonb_build_object(c, r);
  end loop;
  return out;
end $$;

revoke all on function yuk_kurslar(text[]) from public, anon;
grant execute on function yuk_kurslar(text[]) to authenticated;

comment on function yuk_kurslar(text[]) is
  'Valyuta kodlari -> UZS kursi (conv_baza_kurs; alias valyuta_alias dan). UZS=1, topilmasa null.';


-- =====================================================================
-- 5-BO'LIM — TEKSHIRUV (RUN dan keyin natijalarni ko'ring)
-- =====================================================================

-- 5.1 Ekvivalentlik sinfi to'g'rimi
select 'cur_ekvivalent' as test, 'CHY' as kirish, cur_ekvivalent('CHY') as natija
union all select 'cur_ekvivalent', 'CNY', cur_ekvivalent('CNY')
union all select 'cur_ekvivalent', 'USD', cur_ekvivalent('USD');

-- 5.2 Kurs endi topiladimi (CHY va CNY bir xil raqam berishi SHART)
select 'conv_baza_kurs' as test, 'CHY' as kod, conv_baza_kurs('CHY') as kurs
union all select 'conv_baza_kurs', 'CNY', conv_baza_kurs('CNY')
union all select 'conv_baza_kurs', 'USD', conv_baza_kurs('USD');

-- 5.3 Tannarx / Professional aynan shuni chaqiradi
select yuk_kurslar(array['CHY','CNY','USD','UZS']) as yuk_kurslar_natija;

-- 5.4 Bazadagi mavjud kurs qatorlari (nima yozilganini ko'rish uchun)
select from_code, to_code, rate, rate_at, source, created_by_name
  from currency_rate
 where upper(from_code) in ('CHY','CNY') or upper(to_code) in ('CHY','CNY')
 order by rate_at desc limit 20;

-- 5.5 CHY va CNY nomli hisoblar YONMA-YON bormi (bo'lsa alohida tozalash kerak)
select currency, count(*) as hisob_soni, min(code) as eng_kichik_kod
  from accounts
 where upper(currency) in ('CHY','CNY')
 group by currency;


-- =====================================================================
-- ROLLBACK (kerak bo'lsa)
-- ---------------------------------------------------------------------
-- Aliasni o'chirish yetarli — funksiyalar o'z-o'zidan eski xatti-harakatga
-- qaytadi (ekvivalentlik sinfi bitta kodga qisqaradi):
--     delete from valyuta_alias where alias = 'CHY';
-- Diqqat: undan keyin yuk_kurslar CHY ni CNY ga o'girmaydi (eski qattiq
-- kod olib tashlangan), ya'ni 'CHY -> UZS' qatori TO'G'RIDAN ishlatiladi.
-- =====================================================================
