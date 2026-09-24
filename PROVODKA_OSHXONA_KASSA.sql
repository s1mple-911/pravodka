-- ============================================================================
--  PROVODKA_OSHXONA_KASSA.sql — 2026-09-24 — 3 ta filial kassa: oshxonalar (Asilbek)
--  «Yunusobod oshxona», «Qarshi oshxona», «Izza oshxona» — Provodka'ning o'z filial kassalari
--  (Aros cachier EMAS: filial_ref yo'q, Balans/Transfer Sync tegmaydi). kassa_turi='filial',
--  kod 52xx (eng kattasi + 1), tur bola-hisoblari: naqd, click, terminal (_pul_turi_child_ich —
--  idempotent). v_filial_tanlov (xarajat filial tanlovi) va kassa sahifasi «Filial kassalari»
--  guruhida avtomat chiqadi. Takror RUN xavfsiz (nom bo'yicha tekshiriladi). Asilbek RUN qiladi.
-- ============================================================================

do $oshxona$
declare
  v_nom   text;
  v_code  text;
  v_id    uuid;
  v_tur   text;
  v_n     int := 0;
begin
  foreach v_nom in array array['Yunusobod oshxona', 'Qarshi oshxona', 'Izza oshxona'] loop
    select id into v_id from accounts
     where lower(name) = lower(v_nom) and section = 'pul' and parent_id is null limit 1;
    if v_id is not null then
      raise notice 'bor: % (%)', v_nom, v_id;
    else
      select lpad((coalesce(max(code::int), 5200) + 1)::text, 4, '0') into v_code
        from accounts where code ~ '^52[0-9]{2}$';
      insert into accounts (code, name, subtitle, type, section, kassa_turi, currency, parent_id, is_active)
        values (v_code, v_nom, 'Oshxona', 'aktiv', 'pul', 'filial', 'UZS', null, true)
        returning id into v_id;
      v_n := v_n + 1;
      raise notice 'ochildi: % kod %', v_nom, v_code;
    end if;
    -- pul turlari (bor bo'lsa qayta ochilmaydi)
    foreach v_tur in array array['naqd', 'click', 'terminal'] loop
      begin
        perform _pul_turi_child_ich(v_id, v_tur);
      exception when others then
        raise notice '  tur % ochilmadi: %', v_tur, sqlerrm;
      end;
    end loop;
  end loop;
  raise notice 'OSHXONA: % ta yangi kassa', v_n;
end
$oshxona$;

select k.code, k.name, k.subtitle, k.kassa_turi,
       (select string_agg(c.pul_turi, ', ' order by c.code) from accounts c where c.parent_id = k.id and c.pul_turi is not null) as turlar
  from accounts k
 where k.section = 'pul' and k.parent_id is null and lower(k.name) like '%oshxona%'
 order by k.code;
