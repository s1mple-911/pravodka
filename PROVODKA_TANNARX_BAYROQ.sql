-- ============================================================================
--  PROVODKA_TANNARX_BAYROQ.sql — 2026-09-15 (Asilbek)
--  «Tovar tannarxi tanlanganda Filial (majburiy) va Chek/hujjat (majburiy)
--  kerak emas ekan.»
--
--  Bu talablar kodda emas — moddaning o'z bayroqlarida (Sozlamalar → moddalar):
--  filial_majburiy, chek_majburiy, ai_tekshir, spidometr_ai. Ular «Tovar tannarxi»
--  (9110) va «Tovar tannarxi (yo'ldagi)» (9110-1) hisoblarida yoqilgan edi.
--  Bu fayl ularni O'CHIRADI. Faqat ma'lumot o'zgaradi — ustun/funksiya yo'q.
--  (Xohlasangiz xuddi shuni Sozlamalar sahifasidagi katakchalardan ham qilsa bo'ladi.)
--  Izoh majburiyligi TEGILMAYDI — tovar tannarxida izoh baribir shart
--  (PROVODKA_TANNARX_IZOH.sql server qorovuli).
--  Ikki marta RUN qilinsa ham xato bermaydi.
-- ============================================================================

-- Oldingi holat (natija oynasida ko'rinadi)
select code, name, filial_majburiy, chek_majburiy,
       coalesce((to_jsonb(a) ->> 'ai_tekshir')::boolean, false)   as ai_tekshir,
       coalesce((to_jsonb(a) ->> 'spidometr_ai')::boolean, false) as spidometr_ai
  from accounts a
 where code in ('9110', '9110-1');

do $upd$
declare
  v_n int;
begin
  update accounts
     set filial_majburiy = false,
         chek_majburiy   = false
   where code in ('9110', '9110-1');
  get diagnostics v_n = row_count;
  raise notice 'filial_majburiy / chek_majburiy o''chirildi: % ta hisob', v_n;

  -- ai_tekshir / spidometr_ai — ustun bor bazada (PROVODKA_RASM_DETECT.sql)
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'accounts' and column_name = 'ai_tekshir') then
    execute 'update accounts set ai_tekshir = false where code in (''9110'', ''9110-1'')';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'accounts' and column_name = 'spidometr_ai') then
    execute 'update accounts set spidometr_ai = false where code in (''9110'', ''9110-1'')';
  end if;
  raise notice 'TAYYOR';
end
$upd$;

-- Yangi holat
select code, name, filial_majburiy, chek_majburiy,
       coalesce((to_jsonb(a) ->> 'ai_tekshir')::boolean, false)   as ai_tekshir,
       coalesce((to_jsonb(a) ->> 'spidometr_ai')::boolean, false) as spidometr_ai
  from accounts a
 where code in ('9110', '9110-1');
