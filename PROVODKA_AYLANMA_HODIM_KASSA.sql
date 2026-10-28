-- =====================================================================
-- PROVODKA — AYLANMA: HODIM KASSALARI (H bo'limi) + BACKFILL (2026-10-28, Asilbek)
-- ---------------------------------------------------------------------
-- ## MUAMMO
--   Sof aylanma kapital (SAK) snapshot'ida A «Pul» faqat markaziy (5011/5012) + filial kassalarini
--   olardi. 5400 «Hodim xarajat kassalari» ostidagi hodim kassalari (54xx, kassa_turi='xarajat',
--   bola valyuta/tur hisoblari bilan) ATAYLAB kirmasdi. Toshkent kassa -> «5669 G'iyos · USD» ga
--   15+ mlrd o'tgach SAK 15,7 mlrd (30.09) -> -1,2 mlrd (28.10) bo'ldi — pul yo'qolmagan, G'iyos
--   kassalarida ~17,3 mlrd (1 211 364 USD + 1 600 000 CHY, 28.10 daftar) turibdi.
--   Asilbek: «G'iyosni kassasini ham asosiy qilish kerak va barcha hodim kassalarni ham aylanmada
--   ko'rsatishimiz kerak, keyin oldingi sanalarni ham to'g'irlash kerak».
--   (5415 G'iyos `asosiy=true` ALLAQACHON — kassa-dev «Asosiy» tugmasi; shu fayl unga tegmaydi.)
--
-- ## NIMA O'ZGARADI (ADDITIVE; imzolar saqlanadi)
--   1-BO'LIM  aylanma_hodim_kassa(p_sana date, p_vaqt timestamptz) -> jsonb {uzs, usd, soni, rows[]}
--             5400 konteyner(lar)i ostidagi hodim kassalari (REKURSIV barcha avlodlari bilan) balansi.
--             p_sana null = JONLI daftar (v_hisob_bal bilan bir xil: posted + is_deleted=false).
--             p_sana berilsa TARIXIY: entry_date < p_sana, yoki entry_date = p_sana va created_at <= p_vaqt
--             (08:00 snapshot = kun boshi; shu kunning o'zida snapshotdan OLDIN yozilgan yozuvlar kiradi).
--             uzs — tarixiy kursdagi so'm ekvivalenti (debit−credit, A daftar qatorlari bilan bir xil ma'no),
--             usd — USD bola-hisoblar fc yig'indisi; meta.valyutalar — har valyuta bo'yicha qoldiq.
--   2-BO'LIM  sync_aylanma_snapshot(jsonb) qayta e'lon (imzo bir xil; tana PROVODKA_AYLANMA_PROFIT_API.sql
--             dan VERBATIM, 4 hunk): declare'da v_h_*; [A] dan keyin YANGI [H] bloki (alohida exception,
--             manfiy kassa xatolar[] ga); JAMI = A+H+B+T1+T5+Y3a+K3b+K4+B6+Q2a−Q2b. n8n payload O'ZGARMAYDI
--             (manba Supabase daftari) — n8n patch KERAK EMAS. Bu fayl PROFIT_API/BIR_KUN/Q2A_FIX ni o'z ichiga oladi.
--   3-BO'LIM  aylanma_hodim_kassa_backfill(p_from, p_to) — mavjud HAR snapshot uchun H ni o'sha sanadagi
--             tarixiy qoldiq bilan to'ldiradi: bolimlar.H, jami_uzs (+H, eski H bo'lsa ayirib), jami_usd
--             (jami/kurs_usd), aylanma_qator H qatorlari (faqat H qatorlari almashadi, boshqa bo'limlarga TEGILMAYDI).
--             IDEMPOTENT — qayta RUN dublikat bermaydi. Fayl oxirida bir marta chaqiriladi.
--   Kunlik hisobot (aylanma_hisobot, kumulyativ): boshlang'ich kun jami ham, har kun jami ham H bilan o'sadi ->
--   raznitsa = jami − kerak H(kun) − H(boshlanish) ga siljiydi, ya'ni Toshkent -> hodim kassa o'tkazmasi endi
--   raznitsa bermaydi. Hodim kassasidan chiqqan XARAJAT kerak'ga faqat kassa `asosiy` bo'lsa kiradi
--   (aylanma_kun_xarajat) — G'iyos asosiy, qolgan 43 kassa (jami ~0,28 mlrd) emas (Asilbek qarori).
--
-- ## RUN TARTIBI
--   1) shu fayl (Supabase SQL editor, bitta RUN — oxirida backfill o'zi ishlaydi, 51 snapshot ~ bir necha soniya)
--   2) aylanma-dev.html ni yangilash (Ctrl+F5) — zinapoyada «Hodim kassalari» qatori
--   3) ixtiyoriy: pastdagi TEKSHIRUV so'rovlari
-- Idempotent. Pul harakati YO'Q. Funksiya tanalari NOMLI dollar-teg bilan (hk_pre / hk_fn / ayl_sync / hk_bf).
-- =====================================================================

do $hk_pre$
begin
  if to_regclass('public.aylanma_snapshot') is null or to_regclass('public.aylanma_qator') is null then
    raise exception 'aylanma_snapshot/aylanma_qator yoq — avval PROVODKA_AYLANMA.sql ni bajaring';
  end if;
  if to_regprocedure('public.sync_aylanma_snapshot(jsonb)') is null then
    raise exception 'sync_aylanma_snapshot(jsonb) yoq — avval PROVODKA_AYLANMA.sql ni bajaring';
  end if;
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'is_admin() yoq — asosiy migratsiya bajarilmagan';
  end if;
  if not exists (select 1 from accounts where code = '5400' or kassa_turi = 'xarajat_guruh') then
    raise notice '5400 «Hodim xarajat kassalari» konteyneri topilmadi — H bo''limi 0 bo''ladi';
  end if;
end
$hk_pre$;


-- #####################################################################
-- ##  1-BO'LIM — aylanma_hodim_kassa(p_sana, p_vaqt)                  ##
-- #####################################################################
-- Hodim kassalari = 5400 (yoki kassa_turi='xarajat_guruh') konteynerning BEVOSITA bolalari.
-- Har hodim kassasi uchun uning o'zi + REKURSIV barcha avlodlari (USD/CHY/CNY/AED valyuta
-- bolalari, naqd/click/payme tur bolalari) yig'iladi — v_kassa_card.jami mantig'i, lekin
-- is_active ga qaramaydi (nofaol kassada pul qolsa ham ko'rinadi; nofaol va 0 bo'lsa qator yo'q).
-- Konteynerning O'Z balansi (unga pul yozilmasligi kerak) nolga teng bo'lmasa alohida qator.
create or replace function aylanma_hodim_kassa(p_sana date default null, p_vaqt timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $hk_fn$
declare
  v_rows jsonb := '[]'::jsonb;
  v_uzs  numeric := 0;
  v_usd  numeric := 0;
  v_soni int := 0;
  r record;
begin
  -- sync (service_role, auth.uid() null) / SQL editor / admin
  if auth.uid() is not null and not is_admin() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  for r in
    with recursive kont as (
      select a.id, a.code, a.name
        from accounts a
       where a.code = '5400' or a.kassa_turi = 'xarajat_guruh'
    ),
    hodim as (
      select a.id, a.code, a.name, a.is_active, coalesce(a.asosiy, false) as asosiy, a.subtitle
        from accounts a
        join kont k on a.parent_id = k.id
    ),
    avlod as (
      select h.id as hodim_id, h.id as acc_id from hodim h
      union all
      select v.hodim_id, a.id from avlod v join accounts a on a.parent_id = v.acc_id
    ),
    bal as (
      select v.hodim_id,
             coalesce(a.currency, 'UZS') as cur,
             sum(l.debit - l.credit) as uzs,
             sum(case when l.debit > 0 then coalesce(l.fc_amount, 0) else -coalesce(l.fc_amount, 0) end) as fc
        from avlod v
        join accounts a   on a.id = v.acc_id
        join entry_line l on l.account_id = v.acc_id
        join entry e      on e.id = l.entry_id
       where e.status = 'posted' and e.is_deleted = false
         and (p_sana is null
              or e.entry_date < p_sana
              or (e.entry_date = p_sana and p_vaqt is not null and e.created_at <= p_vaqt))
       group by v.hodim_id, coalesce(a.currency, 'UZS')
    )
    select h.id, h.code, h.name, h.is_active, h.asosiy, h.subtitle,
           coalesce(sum(b.uzs), 0)                                   as uzs,
           coalesce(sum(b.fc) filter (where b.cur = 'USD'), 0)       as usd,
           coalesce(jsonb_object_agg(b.cur,
                      round(case when b.cur = 'UZS' then b.uzs else b.fc end, 2))
                    filter (where b.cur is not null and (b.uzs <> 0 or b.fc <> 0)), '{}'::jsonb) as valyutalar,
           (select count(*) from avlod v where v.hodim_id = h.id) - 1 as bola_n
      from hodim h
      left join bal b on b.hodim_id = h.id
     group by h.id, h.code, h.name, h.is_active, h.asosiy, h.subtitle
     order by h.code
  loop
    if not r.is_active and r.uzs = 0 and r.usd = 0 and r.valyutalar = '{}'::jsonb then
      continue;                                   -- nofaol va bo'sh — qator yo'q
    end if;
    v_rows := v_rows || jsonb_build_object(
      'bolim', 'H', 'ref', r.id::text, 'nom', r.name, 'uzs', r.uzs, 'usd', r.usd,
      'soni', null, 'hisobga', true,
      'meta', jsonb_build_object('manba', 'daftar', 'kod', r.code, 'subtitle', r.subtitle,
                                 'valyutalar', r.valyutalar, 'asosiy', r.asosiy,
                                 'nofaol', not r.is_active, 'manfiy', r.uzs < 0, 'bola_n', r.bola_n));
    v_uzs  := v_uzs + r.uzs;
    v_usd  := v_usd + r.usd;
    v_soni := v_soni + 1;
  end loop;

  -- Konteynerning o'z balansi (bo'lmasligi kerak) — xavfsizlik uchun
  for r in
    select k.id, k.code, k.name, coalesce(sum(l.debit - l.credit), 0) as uzs
      from accounts k
      join entry_line l on l.account_id = k.id
      join entry e      on e.id = l.entry_id
     where (k.code = '5400' or k.kassa_turi = 'xarajat_guruh')
       and e.status = 'posted' and e.is_deleted = false
       and (p_sana is null
            or e.entry_date < p_sana
            or (e.entry_date = p_sana and p_vaqt is not null and e.created_at <= p_vaqt))
     group by k.id, k.code, k.name
    having coalesce(sum(l.debit - l.credit), 0) <> 0
  loop
    v_rows := v_rows || jsonb_build_object(
      'bolim', 'H', 'ref', r.id::text, 'nom', r.name || ' (konteyner)', 'uzs', r.uzs, 'usd', 0,
      'soni', null, 'hisobga', true,
      'meta', jsonb_build_object('manba', 'daftar', 'kod', r.code, 'konteyner', true, 'manfiy', r.uzs < 0));
    v_uzs  := v_uzs + r.uzs;
    v_soni := v_soni + 1;
  end loop;

  return jsonb_build_object('ok', true, 'uzs', v_uzs, 'usd', v_usd, 'soni', v_soni, 'rows', v_rows,
                            'sana', p_sana, 'vaqt', p_vaqt);
end
$hk_fn$;
revoke all on function aylanma_hodim_kassa(date, timestamptz) from public, anon;
grant execute on function aylanma_hodim_kassa(date, timestamptz) to authenticated, service_role;
comment on function aylanma_hodim_kassa(date, timestamptz) is
  'SAK H bo''limi: 5400 konteyneri ostidagi hodim kassalari balansi (rekursiv avlodlar bilan). '
  'p_sana null = jonli daftar; p_sana/p_vaqt = tarixiy (entry_date < p_sana yoki = p_sana va created_at <= p_vaqt). '
  'Admin/service_role/SQL editor. PROVODKA_AYLANMA_HODIM_KASSA.sql (2026-10-28).';


-- #####################################################################
-- ##  2-BO'LIM — sync_aylanma_snapshot (imzo bir xil; PROFIT_API tanasi + [H])
-- #####################################################################

create or replace function sync_aylanma_snapshot(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $ayl_sync$
declare
  v_role         text;
  v_sana         date;
  v_rejim        text;
  v_manba        jsonb;
  v_omborlar     jsonb;
  v_yuklar       jsonb;
  v_transferlar  jsonb;
  v_buyurtmalar  jsonb;
  v_order_ids    int[];
  v_yuk_ids      int[];
  v_curs         text[];
  v_kurs_map     jsonb;
  v_kurs_usd     numeric;
  v_paid         jsonb;
  v_paid_map     jsonb;
  v_boj          numeric;
  v_row_val      numeric;
  v_tolangan     numeric;
  v_hisobga      boolean;
  v_q2b_missing  jsonb;
  v_curkey       text;
  v_curcnt       numeric;

  v_toliq        boolean := true;
  v_xatolar      text[] := '{}';
  v_bolimlar     jsonb := '{}'::jsonb;
  v_qatorlar     jsonb := '[]'::jsonb;
  v_snapshot_id  uuid;
  v_jami_uzs     numeric;
  v_jami_usd     numeric;

  -- umumiy loop/scratch o'zgaruvchilari (bo'limlar KETMA-KET, parallel emas)
  v_el   jsonb;
  v_ref  text;
  v_nom  text;
  v_num  numeric;
  v_num2 numeric;
  v_bool boolean;
  v_txt  text;
  v_meta jsonb;

  -- har bo'lim uchun alohida jamlovchilar
  v_a_uzs   numeric; v_a_usd   numeric; v_a_soni   int; v_a_rows   jsonb;
  v_bola_uzs numeric; v_bola_usd numeric; v_bola_n int; v_farq numeric;   -- A: filial = Aros jonli
  v_kas_map jsonb; v_kas_ref text;
  v_b_uzs   numeric; v_b_usd   numeric; v_b_soni   int; v_b_rows   jsonb;
  v_t1_uzs  numeric;                    v_t1_soni  int; v_t1_rows  jsonb;
  v_t5_uzs  numeric;                    v_t5_soni  int; v_t5_rows  jsonb;
  v_y3a_uzs numeric;                    v_y3a_soni int; v_y3a_rows jsonb;
  v_k3b_uzs numeric;                    v_k3b_soni int; v_k3b_rows jsonb;
  v_k4_uzs  numeric;                    v_k4_soni  int; v_k4_rows  jsonb;
  v_b6_uzs  numeric;                    v_b6_soni  int; v_b6_rows  jsonb;
  v_q2a_uzs numeric;                                     v_q2a_rows jsonb;
  v_q2b_uzs numeric;                    v_q2b_soni int; v_q2b_rows jsonb;
  v_d_rows  jsonb;
  v_h_uzs   numeric; v_h_usd   numeric; v_h_soni   int; v_h_rows   jsonb; v_h jsonb;   -- H: hodim kassalari (2026-10-28)
begin
  -- ---- service_role ONLY (sync_transfer_yolda/sync_aros_qarzdor bilan bir xil naqsh) ----
  if auth.uid() is not null then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  v_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role');
  if v_role is not null and v_role is distinct from 'service_role' then
    raise exception 'Faqat service_role chaqira oladi (n8n webhook)' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('sync_aylanma_snapshot'));

  -- ---- kirish validatsiyasi ----
  if p_data is null or jsonb_typeof(p_data) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'error', 'p_data object kutilgan edi');
  end if;

  begin
    v_sana := nullif(p_data ->> 'sana', '')::date;
  exception when others then
    v_sana := null;
  end;
  if v_sana is null then
    return jsonb_build_object('ok', false, 'error', 'sana (YYYY-MM-DD) kerak/notogri formatda');
  end if;

  v_rejim := lower(btrim(coalesce(p_data ->> 'rejim', '')));
  if v_rejim not in ('cron', 'qolda') then
    return jsonb_build_object('ok', false, 'error', 'rejim ''cron'' yoki ''qolda'' bolishi kerak');
  end if;

  v_manba := coalesce(p_data -> 'manba', '{}'::jsonb);
  if jsonb_typeof(v_manba) is distinct from 'object' then v_manba := '{}'::jsonb; end if;

  v_omborlar := p_data -> 'omborlar';
  if jsonb_typeof(v_omborlar) is distinct from 'array' then v_omborlar := '[]'::jsonb; end if;
  v_yuklar := p_data -> 'yuklar';
  if jsonb_typeof(v_yuklar) is distinct from 'array' then v_yuklar := '[]'::jsonb; end if;
  v_transferlar := p_data -> 'transferlar';
  if jsonb_typeof(v_transferlar) is distinct from 'array' then v_transferlar := '[]'::jsonb; end if;
  v_buyurtmalar := p_data -> 'buyurtmalar';
  if jsonb_typeof(v_buyurtmalar) is distinct from 'array' then v_buyurtmalar := '[]'::jsonb; end if;

  -- K3b/K4 uchun: order_id B6 (buyurtmalar) ichida bormi — ikki marta sanalmasin
  v_order_ids := '{}';
  begin
    select coalesce(array_agg((x ->> 'id')::int), '{}')
      into v_order_ids
      from jsonb_array_elements(v_buyurtmalar) x
     where nullif(x ->> 'id', '') ~ '^[0-9]+$';
  exception when others then
    v_order_ids := '{}';
  end;

  -- ---- kurs_usd (bir marta, hamma USD hisob shundan) ----
  v_kurs_usd := null;
  begin
    if _aylanma_fn_bor('aros_usd_rate', '') then
      execute 'select aros_usd_rate()' into v_kurs_usd;
    end if;
  exception when others then
    v_kurs_usd := null;
  end;
  if v_kurs_usd is null then
    begin
      if _aylanma_fn_bor('conv_baza_kurs', 'text') then
        execute 'select conv_baza_kurs($1)' into v_kurs_usd using 'USD';
      end if;
    exception when others then
      v_kurs_usd := null;
    end;
  end if;
  if v_kurs_usd is null then
    -- 🔴 USD ga bog'liq bo'limlar (A.usd/B/T1/T5) so'mga to'liq o'tolmaydi -> toliq=false.
    v_toliq := false;
    v_xatolar := array_append(v_xatolar,
      'USD kursi topilmadi (aros_usd_rate/conv_baza_kurs) — USD qiymatlar hisobga olinmadi');
  end if;

  -- =====================================================================
  -- [A] Pul (markaziy + filial kassalar) — v_kassa_card
  -- =====================================================================
  begin
    v_a_rows := '[]'::jsonb; v_a_uzs := 0; v_a_usd := 0; v_a_soni := 0;

    -- Aros jonli balans xaritasi (n8n payload kassalar[]): cachier_id -> qator
    v_kas_map := '{}'::jsonb;
    if jsonb_typeof(p_data -> 'kassalar') = 'array' then
      for v_el in select value from jsonb_array_elements(p_data -> 'kassalar') loop
        if (v_el ->> 'cachier_id') is not null then
          v_kas_map := v_kas_map || jsonb_build_object(btrim(v_el ->> 'cachier_id'), v_el);
        end if;
      end loop;
    end if;

    -- 🔴 2026-09-08 (DIAG bilan tasdiqlangan, Asilbek):
    --   * MARKAZIY kassalar (5011/5012, filial_ref NULL) — PROVODKA DAFTARI (v_kassa_card.jami):
    --     Aros'da yo'q chiqimlar shu yerda. Balans Sync ularga tegmaydi.
    --   * FILIAL kassalar (filial_ref bor) — daftar = Aros'ning soatlik nusxasi (parent 0, bolalar
    --     Aros'ga tenglashtiriladi). Jo'natish/qabul oralig'ida (1 soatgacha) daftar VAQTINCHA
    --     MANFIY bo'ladi (5213 −75 mln snapshot'da, DIAG'da +57 750). Shuning uchun filial uchun
    --     AROS JONLI balans (payload kassalar[]) olinadi = tenglashtirilgandan keyingi daftar.
    --     Aros qatori kelmasa — daftar (meta.manba='daftar').
    for v_ref, v_nom, v_num, v_num2, v_bola_n, v_kas_ref in
      select k.code, k.name, coalesce(k.jami, 0)::numeric, coalesce(k.usd, 0)::numeric,
             case when a.filial_ref is not null then 1 else 0 end, btrim(a.filial_ref::text)
        from v_kassa_card k
        left join accounts a on a.id = k.id
       where k.kassa_turi in ('markaziy', 'filial')
         and coalesce((to_jsonb(k) ->> 'is_active')::boolean, true)   -- nofaol kassa yo'q (kassa-dev filtri); ustun bo'lmasa true
    loop
      v_el := null;
      if v_bola_n = 1 and v_kas_ref is not null then v_el := v_kas_map -> v_kas_ref; end if;
      if v_el is not null then
        v_bola_usd := coalesce(nullif(v_el ->> 'dollar_usd', '')::numeric, 0);
        v_bola_uzs := coalesce(nullif(v_el ->> 'cash', '')::numeric, 0)
                    + coalesce(nullif(v_el ->> 'click', '')::numeric, 0)
                    + coalesce(nullif(v_el ->> 'payme', '')::numeric, 0)
                    + case when coalesce(v_kurs_usd, 0) > 0 then v_bola_usd * v_kurs_usd else 0 end;
        v_farq := v_num - v_bola_uzs;                 -- daftar − Aros (transient yoki kurs farqi)
        v_a_rows := v_a_rows || jsonb_build_object(
          'bolim', 'A', 'ref', v_ref, 'nom', v_nom, 'uzs', v_bola_uzs, 'usd', v_bola_usd,
          'soni', null, 'hisobga', true,
          'meta', jsonb_build_object('manba', 'aros', 'daftar_jami', v_num, 'daftar_usd', v_num2,
                                     'farq', v_farq, 'cash', v_el ->> 'cash', 'click', v_el ->> 'click',
                                     'payme', v_el ->> 'payme', 'manfiy', v_bola_uzs < 0));
        v_num := v_bola_uzs; v_num2 := v_bola_usd;
      else
        v_a_rows := v_a_rows || jsonb_build_object(
          'bolim', 'A', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', v_num2,
          'soni', null, 'hisobga', true,
          'meta', jsonb_build_object('manba', 'daftar', 'manfiy', v_num < 0));
      end if;
      if v_num < 0 then
        v_xatolar := array_append(v_xatolar, 'A: ' || v_nom || ' manfiy (' || round(v_num) || ')');
      end if;
      v_a_uzs  := v_a_uzs + v_num;
      v_a_usd  := v_a_usd + v_num2;
      v_a_soni := v_a_soni + 1;
    end loop;

    v_bolimlar := v_bolimlar || jsonb_build_object('A',
      jsonb_build_object('uzs', v_a_uzs, 'usd', v_a_usd, 'soni', v_a_soni));
    v_qatorlar := v_qatorlar || v_a_rows;
  exception when others then
    v_a_uzs := null; v_a_usd := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('A', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'A: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [H] Hodim kassalari (xaridor/hodim pullari) — 2026-10-28, Asilbek:
  --     «G'iyosni kassasini ham asosiy qilish kerak va barcha hodim kassalarni
  --     ham aylanmada ko'rsatishimiz kerak». 5400 «Hodim xarajat kassalari»
  --     konteyneri ostidagi BARCHA kassalar (54xx, kassa_turi='xarajat') —
  --     valyuta (USD/CHY/CNY/AED) va tur (naqd/click/payme) bola-hisoblari bilan.
  --     Avval A bo'limidan ATAYLAB chiqarilgan edi — shu sabab Toshkent kassa →
  --     G'iyos (5669 USD) o'tkazmalari SAK ni ~15 mlrd «yo'qotardi» (27.10: −1,2 mlrd).
  --     Hisob: aylanma_hodim_kassa(null, null) = JONLI daftar (v_hisob_bal semantikasi,
  --     PROVODKA_AYLANMA_HODIM_KASSA.sql). uzs — tarixiy kursdagi so'm ekvivalenti
  --     (A daftar qatorlari bilan bir xil), usd — USD bola-hisoblar fc yig'indisi.
  --     Alohida bo'lim (A ichiga qo'shilmagan): Asilbek «ko'rsatishimiz kerak» —
  --     zinapoyada ko'rinsin, A ning tarixiy ma'nosi (markaziy+filial) buzilmasin.
  -- =====================================================================
  begin
    v_h_rows := '[]'::jsonb; v_h_uzs := 0; v_h_usd := 0; v_h_soni := 0;
    v_h := aylanma_hodim_kassa(null, null);
    if coalesce((v_h ->> 'ok')::boolean, false) is not true then
      raise exception '%', coalesce(v_h ->> 'kod', v_h ->> 'error', 'aylanma_hodim_kassa xato');
    end if;
    v_h_uzs  := coalesce((v_h ->> 'uzs')::numeric, 0);
    v_h_usd  := coalesce((v_h ->> 'usd')::numeric, 0);
    v_h_soni := coalesce((v_h ->> 'soni')::int, 0);
    v_h_rows := coalesce(v_h -> 'rows', '[]'::jsonb);
    for v_el in select value from jsonb_array_elements(v_h_rows) loop
      if coalesce((v_el ->> 'uzs')::numeric, 0) < 0 then
        v_xatolar := array_append(v_xatolar,
          'H: ' || coalesce(v_el ->> 'nom', '?') || ' manfiy (' || round((v_el ->> 'uzs')::numeric) || ')');
      end if;
    end loop;

    v_bolimlar := v_bolimlar || jsonb_build_object('H',
      jsonb_build_object('uzs', v_h_uzs, 'usd', v_h_usd, 'soni', v_h_soni, 'manba', 'daftar'));
    v_qatorlar := v_qatorlar || v_h_rows;
  exception when others then
    v_h_uzs := null; v_h_usd := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('H', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'H: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [B] Yo'ldagi pul — aros_transfer_yolda status='sent'
  -- =====================================================================
  begin
    v_b_rows := '[]'::jsonb; v_b_uzs := 0; v_b_usd := 0; v_b_soni := 0;

    if to_regclass('public.aros_transfer_yolda') is not null then
      for v_ref, v_nom, v_num, v_num2, v_meta in
        select t.transfer_id,
               coalesce(t.sender_title, '?') || ' -> ' || coalesce(t.receiver_title, '?'),
               coalesce(t.s_cash, 0) + coalesce(t.s_click, 0) + coalesce(t.s_payme, 0)
                 + coalesce(t.s_usd, 0) * coalesce(v_kurs_usd, 0),
               coalesce(t.s_usd, 0),
               case when v_kurs_usd is null and coalesce(t.s_usd, 0) <> 0
                    then jsonb_build_object('kurs_yoq', true) else '{}'::jsonb end
          from aros_transfer_yolda t
         where t.status = 'sent'
      loop
        v_b_uzs  := v_b_uzs + v_num;
        v_b_usd  := v_b_usd + v_num2;
        v_b_soni := v_b_soni + 1;
        v_b_rows := v_b_rows || jsonb_build_object(
          'bolim', 'B', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', v_num2,
          'soni', null, 'hisobga', true, 'meta', v_meta);
      end loop;
    end if;

    v_bolimlar := v_bolimlar || jsonb_build_object('B',
      jsonb_build_object('uzs', v_b_uzs, 'usd', v_b_usd, 'soni', v_b_soni));
    v_qatorlar := v_qatorlar || v_b_rows;
  exception when others then
    v_b_uzs := null; v_b_usd := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('B', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'B: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [T1]/[T5] Tovar + brak omborlarda (Aros profit-summary, USD tannarx, payload orqali)
  -- =====================================================================
  begin
    v_t1_rows := '[]'::jsonb; v_t1_uzs := 0; v_t1_soni := 0;
    v_t5_rows := '[]'::jsonb; v_t5_uzs := 0; v_t5_soni := 0;

    if coalesce(v_manba ->> 'profit_api', v_manba ->> 'metabase', '') = 'xato' or coalesce(v_manba ->> 'warehouses', '') = 'xato' then
      v_t1_uzs := null; v_t5_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('T1', null, 'T5', null);
      v_toliq := false;
      if coalesce(v_manba ->> 'profit_api', v_manba ->> 'metabase', '') = 'xato' then
        v_xatolar := array_append(v_xatolar, 'T1/T5: manba.profit_api=xato — otkazib yuborildi');
      end if;
      if coalesce(v_manba ->> 'warehouses', '') = 'xato' then
        v_xatolar := array_append(v_xatolar, 'T1/T5: manba.warehouses=xato — otkazib yuborildi');
      end if;
    else
      for v_el in select * from jsonb_array_elements(v_omborlar) loop
        v_ref  := coalesce(v_el ->> 'id', '');
        v_nom  := coalesce(v_el ->> 'nom', '');
        v_bool := coalesce((v_el ->> 'is_broken')::boolean, false);
        v_num  := nullif(v_el ->> 'usd', '')::numeric;      -- ombor tannarxi (USD)

        if v_num is null then
          v_num2 := 0;
          v_meta := jsonb_build_object('yoq', true);
        elsif v_kurs_usd is null then
          v_num2 := 0;
          v_meta := jsonb_build_object('kurs_yoq', true);
        else
          v_num2 := round(v_num * v_kurs_usd, 2);
          v_meta := '{}'::jsonb;
        end if;

        if nullif(v_el ->> 'tr_yolda_uzs', '') is not null then
          v_meta := v_meta || jsonb_build_object('tr_yolda_uzs', (v_el ->> 'tr_yolda_uzs')::numeric);
        end if;

        if v_bool then
          v_t5_uzs  := v_t5_uzs + v_num2;
          v_t5_soni := v_t5_soni + 1;
          v_t5_rows := v_t5_rows || jsonb_build_object(
            'bolim', 'T5', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num2, 'usd', v_num,
            'soni', null, 'hisobga', true, 'meta', v_meta);
        else
          v_t1_uzs  := v_t1_uzs + v_num2;
          v_t1_soni := v_t1_soni + 1;
          v_t1_rows := v_t1_rows || jsonb_build_object(
            'bolim', 'T1', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num2, 'usd', v_num,
            'soni', null, 'hisobga', true, 'meta', v_meta);
        end if;
      end loop;

      v_bolimlar := v_bolimlar || jsonb_build_object(
        'T1', jsonb_build_object('uzs', v_t1_uzs, 'usd', null, 'soni', v_t1_soni),
        'T5', jsonb_build_object('uzs', v_t5_uzs, 'usd', null, 'soni', v_t5_soni));
      v_qatorlar := v_qatorlar || v_t1_rows || v_t5_rows;
    end if;
  exception when others then
    v_t1_uzs := null; v_t5_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('T1', null, 'T5', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'T1/T5: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [Y3a] Yo'ldagi yuklar — status=posted, delivery_status=on_way
  -- =====================================================================
  begin
    v_y3a_rows := '[]'::jsonb; v_y3a_uzs := 0; v_y3a_soni := 0;

    if coalesce(v_manba ->> 'incomes', '') = 'xato' then
      v_y3a_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('Y3a', null);
      v_toliq := false;
      v_xatolar := array_append(v_xatolar, 'Y3a: manba.incomes=xato — otkazib yuborildi');
    else
      select coalesce(array_agg(distinct upper(btrim(x ->> 'valyuta'))), '{}')
        into v_curs
        from jsonb_array_elements(v_yuklar) x
       where nullif(btrim(coalesce(x ->> 'valyuta', '')), '') is not null;

      v_kurs_map := '{}'::jsonb;
      if coalesce(array_length(v_curs, 1), 0) > 0
         and _aylanma_fn_bor('yuk_kurslar', 'text[]') then
        begin
          v_kurs_map := yuk_kurslar(v_curs);
        exception when others then
          v_kurs_map := '{}'::jsonb;
        end;
      end if;
      if v_kurs_usd is not null then
        v_kurs_map := v_kurs_map || jsonb_build_object('USD', v_kurs_usd);
      end if;

      for v_el in
        select * from jsonb_array_elements(v_yuklar) x
         where x ->> 'status' = 'posted' and x ->> 'delivery_status' = 'on_way'
      loop
        v_ref := coalesce(v_el ->> 'id', '');
        v_nom := coalesce(v_el ->> 'ombor', '')
          || case when nullif(v_el ->> 'yetkazuvchi', '') is not null
                  then ' · ' || (v_el ->> 'yetkazuvchi') else '' end;
        v_txt  := upper(btrim(coalesce(v_el ->> 'valyuta', '')));
        v_num  := nullif(v_kurs_map ->> v_txt, '')::numeric;
        v_num2 := coalesce(nullif(v_el ->> 'narx', '')::numeric, 0);

        if v_num is null then
          v_row_val := 0;
          v_meta := jsonb_build_object('kurs_yoq', true, 'valyuta', v_txt);
          v_xatolar := array_append(v_xatolar,
            'Y3a: yuk ' || coalesce(v_ref, '?') || ' kursi topilmadi (' || coalesce(v_txt, '?') || ')');
        else
          v_row_val := round(v_num2 * v_num, 2);
          v_meta := '{}'::jsonb;
        end if;

        -- bojxona (aros_yuk_bojxona) — mavjud bo'lsa qo'shiladi
        v_boj := 0;
        if to_regclass('public.aros_yuk_bojxona') is not null and v_ref ~ '^[0-9]+$' then
          begin
            select coalesce(bojxona_uzs, 0) into v_boj from aros_yuk_bojxona where yuk_id = v_ref::int;
          exception when others then
            v_boj := 0;
          end;
        end if;
        v_row_val := coalesce(v_row_val, 0) + coalesce(v_boj, 0);

        v_y3a_uzs  := v_y3a_uzs + v_row_val;
        v_y3a_soni := v_y3a_soni + 1;
        v_y3a_rows := v_y3a_rows || jsonb_build_object(
          'bolim', 'Y3a', 'ref', v_ref, 'nom', v_nom, 'uzs', v_row_val, 'usd', null,
          'soni', null, 'hisobga', true, 'meta', v_meta);
      end loop;

      v_bolimlar := v_bolimlar || jsonb_build_object('Y3a',
        jsonb_build_object('uzs', v_y3a_uzs, 'usd', null, 'soni', v_y3a_soni));
      v_qatorlar := v_qatorlar || v_y3a_rows;
    end if;
  exception when others then
    v_y3a_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('Y3a', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'Y3a: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [K3b]/[K4] Ko'chirish yo'lda (on_way) / yaratilgan (created)
  -- =====================================================================
  begin
    v_k3b_rows := '[]'::jsonb; v_k3b_uzs := 0; v_k3b_soni := 0;
    v_k4_rows  := '[]'::jsonb; v_k4_uzs  := 0; v_k4_soni  := 0;

    if coalesce(v_manba ->> 'transfers', '') = 'xato' then
      v_k3b_uzs := null; v_k4_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('K3b', null, 'K4', null);
      v_toliq := false;
      v_xatolar := array_append(v_xatolar, 'K3b/K4: manba.transfers=xato — otkazib yuborildi');
    else
      for v_el in select * from jsonb_array_elements(v_transferlar) loop
        v_ref  := coalesce(v_el ->> 'id', '');
        v_nom  := coalesce(v_el ->> 'from_nom', '?') || ' -> ' || coalesce(v_el ->> 'to_nom', '?');
        v_num  := coalesce(nullif(v_el ->> 'tannarx_uzs', '')::numeric,
                            nullif(v_el ->> 'price_uzs', '')::numeric, 0);
        v_txt  := v_el ->> 'status';
        v_bool := coalesce((v_el ->> 'to_brak')::boolean, false);
        v_num2 := nullif(v_el ->> 'order_id', '')::numeric;

        v_meta := '{}'::jsonb;
        if v_bool then v_meta := v_meta || jsonb_build_object('to_brak', true); end if;

        v_hisobga := true;
        if v_num2 is not null and v_num2::int = any(v_order_ids) then
          v_hisobga := false;              -- B6 (ochiq buyurtma) ichida — ikki marta sanalmasin
          v_meta := v_meta || jsonb_build_object('order_qoshildi', true);
        end if;

        if v_txt = 'on_way' then
          v_k3b_soni := v_k3b_soni + 1;
          if v_hisobga then v_k3b_uzs := v_k3b_uzs + v_num; end if;
          v_k3b_rows := v_k3b_rows || jsonb_build_object(
            'bolim', 'K3b', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', null,
            'soni', null, 'hisobga', v_hisobga, 'meta', v_meta);
        elsif v_txt = 'created' then
          v_k4_soni := v_k4_soni + 1;
          if v_hisobga then v_k4_uzs := v_k4_uzs + v_num; end if;
          v_k4_rows := v_k4_rows || jsonb_build_object(
            'bolim', 'K4', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', null,
            'soni', null, 'hisobga', v_hisobga, 'meta', v_meta);
        end if;
      end loop;

      v_bolimlar := v_bolimlar || jsonb_build_object(
        'K3b', jsonb_build_object('uzs', v_k3b_uzs, 'usd', null, 'soni', v_k3b_soni),
        'K4',  jsonb_build_object('uzs', v_k4_uzs,  'usd', null, 'soni', v_k4_soni));
      v_qatorlar := v_qatorlar || v_k3b_rows || v_k4_rows;
    end if;
  exception when others then
    v_k3b_uzs := null; v_k4_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('K3b', null, 'K4', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'K3b/K4: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [B6] Ochiq buyurtmalar — sotuv narxida (total_uzs)
  -- =====================================================================
  begin
    v_b6_rows := '[]'::jsonb; v_b6_uzs := 0; v_b6_soni := 0;

    if coalesce(v_manba ->> 'orders', '') = 'xato' then
      v_b6_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('B6', null);
      v_toliq := false;
      v_xatolar := array_append(v_xatolar, 'B6: manba.orders=xato — otkazib yuborildi');
    else
      for v_el in select * from jsonb_array_elements(v_buyurtmalar) loop
        v_ref := coalesce(v_el ->> 'id', '');
        v_nom := coalesce(v_el ->> 'warehouse', '');
        v_num := coalesce(nullif(v_el ->> 'total_uzs', '')::numeric, 0);

        v_b6_uzs  := v_b6_uzs + v_num;
        v_b6_soni := v_b6_soni + 1;
        v_b6_rows := v_b6_rows || jsonb_build_object(
          'bolim', 'B6', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', null,
          'soni', null, 'hisobga', true, 'meta', jsonb_build_object('status', v_el ->> 'status'));
      end loop;

      v_bolimlar := v_bolimlar || jsonb_build_object('B6',
        jsonb_build_object('uzs', v_b6_uzs, 'usd', null, 'soni', v_b6_soni));
      v_qatorlar := v_qatorlar || v_b6_rows;
    end if;
  exception when others then
    v_b6_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('B6', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'B6: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [Q2a] Bizdan qarzdor — Provodka qarz + Aros mijozlar
  -- ---------------------------------------------------------------------
  -- 🔴 `qarz_umumiy_dash()`/`qarz_dash()`/`aros_qarzdor_dash()` CHAQIRILMAYDI —
  -- ularning ICHIDA `qarz_dash()` `auth.uid() is null` bo'lsa "Avtorizatsiya
  -- kerak" bilan RAISE qiladi va `sorov_page_ok()` (qarz_page_ok orqali)
  -- ATAYLAB fail-closed (auth.uid() null -> false) — bu funksiyalar
  -- service_role/cron kontekstidan UMUMAN chaqirilishga mo'ljallanmagan
  -- (PROVODKA_SOROVLAR.sql/PROVODKA_QARZ.sql tanasi tegilmaydi). Shuning
  -- uchun bir xil raqam FORMULASI to'g'ridan jadval/view'dan takrorlanadi:
  --   Provodka = qarz_dash() dagi "jami_qolgan"  = sum(v_qarz_holat.qolgan) faol qarzlar
  --   Aros     = qarz_umumiy_dash() dagi "aros.total_debt" = aros_qarzdor_sync.summary->>'total_debt'
  --              (aros_qarzdor qatorlari YIG'INDISI EMAS — n8n bergan xom Aros summary).
  -- =====================================================================
  begin
    v_q2a_rows := '[]'::jsonb; v_q2a_uzs := 0;
    v_num := 0; v_num2 := 0;

    if to_regclass('public.qarz') is not null and to_regclass('public.v_qarz_holat') is not null then
      select coalesce(sum(h.qolgan), 0) into v_num
        from qarz q
        join v_qarz_holat h on h.qarz_id = q.id
       where q.status = 'faol';
    end if;

    -- 🔴 2026-09-09 TUZATISH (Asilbek: «qarzni noto'g'ri ko'rsatyapti, faqat
    --    hamyon balansni ko'rsatyaptimi deyman»).
    --    ESKI XATO: Aros qarzi FAQAT `summary ->> 'total_debt'` dan olinardi va
    --    u yo'q bo'lsa (summary null / kalit yo'q / sync qatori yo'q) JIMGINA 0
    --    bo'lardi — hamyon esa BARIBIR ayirilardi. Natija:
    --        Q2a = provodka + 0 − hamyon   → aslida «minus hamyon» ko'rinardi.
    --    Bu shu faylning O'Z qoidasini buzardi: «manba yo'q → bo'lim null +
    --    toliq=false + xatolar[]; JIMGINA 0 YO'Q».
    --    ENDI: manba aniq tanlanadi va qarz bilan hamyon AYNI manbadan olinadi
    --    (summary bilan jadval aralashmaydi — ular boshqa-boshqa qamrov).
    --      1) summary bo'lsa: qarz = summary.total_debt, hamyon = summary.total_wallet_balance
    --      2) bo'lmasa jadval: qarz = Σ total_debt (faol), hamyon = Σ wallet_balance (faol)
    --      3) ikkalasi ham yo'q: Q2a = null + toliq=false + xatolar[]  (0 EMAS)
    v_txt := null;                                  -- qaysi manba ishlatilgani
    v_num2 := null; v_bola_uzs := null;

    if to_regclass('public.aros_qarzdor_sync') is not null then
      select (s.summary ->> 'total_debt')::numeric,
             (s.summary ->> 'total_wallet_balance')::numeric
        into v_num2, v_bola_uzs
        from aros_qarzdor_sync s where s.id = 1;
      if v_num2 is not null then
        v_txt := 'summary';
        v_bola_uzs := coalesce(v_bola_uzs, 0);      -- qarz bor, hamyon kaliti yo'q → 0
      end if;
    end if;

    if v_txt is null and to_regclass('public.aros_qarzdor') is not null then
      -- Jadval zaxirasi: ARX bo'yicha Σ total_debt = summary.total_debt.
      select coalesce(sum(a.total_debt), 0), coalesce(sum(a.wallet_balance), 0)
        into v_num2, v_bola_uzs
        from aros_qarzdor a
       where coalesce((to_jsonb(a) ->> 'faol')::boolean, true);
      if v_num2 is not null then
        v_txt := 'jadval';
      end if;
    end if;

    if v_txt is null then
      -- Aros manbasi umuman yo'q — 0 deb ko'rsatmaymiz, ochiq xato beramiz.
      raise exception 'Aros mijozlar qarzi manbasi yoq (aros_qarzdor_sync.summary ham, aros_qarzdor jadvali ham)';
    end if;

    -- Hamyon: mijoz hamyonidagi pul bizga allaqachon berilgan pul, umumiy
    -- qarzdan ayiriladi (Asilbek 2026-09-08). cashback hamyon emas — ayirilmaydi.
    v_q2a_uzs := coalesce(v_num, 0) + v_num2 - coalesce(v_bola_uzs, 0);

    v_q2a_rows := v_q2a_rows
      || jsonb_build_object('bolim', 'Q2a', 'ref', 'provodka', 'nom', 'Provodka qarz (bizdan qarzdor)',
           'uzs', v_num, 'usd', null, 'soni', null, 'hisobga', true, 'meta', '{}'::jsonb)
      || jsonb_build_object('bolim', 'Q2a', 'ref', 'aros', 'nom', 'Aros mijozlar qarzi (umumiy)',
           'uzs', v_num2, 'usd', null, 'soni', null, 'hisobga', true,
           'meta', jsonb_build_object('manba', v_txt))
      || jsonb_build_object('bolim', 'Q2a', 'ref', 'aros_hamyon', 'nom', 'Aros mijozlar hamyoni (bizga berilgan pul) — ayiriladi',
           'uzs', -coalesce(v_bola_uzs, 0), 'usd', null, 'soni', null, 'hisobga', true,
           'meta', jsonb_build_object('hamyon', true, 'manba', v_txt));

    v_bolimlar := v_bolimlar || jsonb_build_object('Q2a',
      jsonb_build_object('uzs', v_q2a_uzs, 'usd', null, 'soni', 3, 'manba', v_txt));
    v_qatorlar := v_qatorlar || v_q2a_rows;
  exception when others then
    v_q2a_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('Q2a', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'Q2a: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [Q2b] Biz qarzdormiz — Qarz sahifasi formulasi: yuk status=posted,
  --       narx × kurs − yuk_tolangan_summa, max(0, …)
  -- =====================================================================
  begin
    v_q2b_rows := '[]'::jsonb; v_q2b_uzs := 0; v_q2b_soni := 0;

    if coalesce(v_manba ->> 'incomes', '') = 'xato' then
      v_q2b_uzs := null;
      v_bolimlar := v_bolimlar || jsonb_build_object('Q2b', null);
      v_toliq := false;
      v_xatolar := array_append(v_xatolar, 'Q2b: manba.incomes=xato — otkazib yuborildi');
    else
      select coalesce(array_agg((x ->> 'id')::int), '{}')
        into v_yuk_ids
        from jsonb_array_elements(v_yuklar) x
       where x ->> 'status' = 'posted' and (x ->> 'id') ~ '^[0-9]+$';

      v_paid := '[]'::jsonb;
      if coalesce(array_length(v_yuk_ids, 1), 0) > 0
         and _aylanma_fn_bor('yuk_tolangan_summa', 'integer[]') then
        begin
          v_paid := yuk_tolangan_summa(v_yuk_ids);
        exception when others then
          v_paid := '[]'::jsonb;
        end;
      end if;
      v_paid_map := '{}'::jsonb;
      for v_el in select * from jsonb_array_elements(v_paid) loop
        v_paid_map := v_paid_map || jsonb_build_object(v_el ->> 'yuk_id', v_el ->> 'tolangan_uzs');
      end loop;

      select coalesce(array_agg(distinct upper(btrim(x ->> 'valyuta'))), '{}')
        into v_curs
        from jsonb_array_elements(v_yuklar) x
       where x ->> 'status' = 'posted'
         and nullif(btrim(coalesce(x ->> 'valyuta', '')), '') is not null;

      v_kurs_map := '{}'::jsonb;
      if coalesce(array_length(v_curs, 1), 0) > 0
         and _aylanma_fn_bor('yuk_kurslar', 'text[]') then
        begin
          v_kurs_map := yuk_kurslar(v_curs);
        exception when others then
          v_kurs_map := '{}'::jsonb;
        end;
      end if;
      if v_kurs_usd is not null then
        v_kurs_map := v_kurs_map || jsonb_build_object('USD', v_kurs_usd);
      end if;

      -- 🔴 kurs yo'q yuk — qator DOIM qo'shiladi (uzs=null, hisobga=true, meta.kurs_yoq) —
      -- yashirin nol emas (ARX 2-BO'LIM / qarzdor-dev qoidasi). Faqat TO'LIQ TO'LANGAN
      -- (qoldiq=0, kurs BOR) yuklar qatordan tashlab yuboriladi — bu ataylab.
      v_q2b_missing := '{}'::jsonb;
      for v_el in select * from jsonb_array_elements(v_yuklar) x where x ->> 'status' = 'posted' loop
        v_ref  := coalesce(v_el ->> 'id', '');
        v_txt  := upper(btrim(coalesce(v_el ->> 'valyuta', '')));
        v_num  := nullif(v_kurs_map ->> v_txt, '')::numeric;
        v_num2 := coalesce(nullif(v_el ->> 'narx', '')::numeric, 0);
        v_tolangan := coalesce(nullif(v_paid_map ->> v_ref, '')::numeric, 0);
        v_nom := coalesce(v_el ->> 'yetkazuvchi', '')
          || case when nullif(v_el ->> 'ombor', '') is not null then ' · ' || (v_el ->> 'ombor') else '' end;

        if v_num is null then
          v_q2b_soni := v_q2b_soni + 1;
          v_q2b_rows := v_q2b_rows || jsonb_build_object(
            'bolim', 'Q2b', 'ref', v_ref, 'nom', v_nom, 'uzs', null, 'usd', null,
            'soni', null, 'hisobga', true, 'meta', jsonb_build_object('kurs_yoq', true, 'valyuta', v_txt));
          v_q2b_missing := v_q2b_missing
            || jsonb_build_object(v_txt, coalesce((v_q2b_missing ->> v_txt)::int, 0) + 1);
        else
          v_row_val := greatest(0, round(v_num2 * v_num, 2) - v_tolangan);
          if v_row_val > 0 then
            v_q2b_uzs  := v_q2b_uzs + v_row_val;
            v_q2b_soni := v_q2b_soni + 1;
            v_q2b_rows := v_q2b_rows || jsonb_build_object(
              'bolim', 'Q2b', 'ref', v_ref, 'nom', v_nom, 'uzs', v_row_val, 'usd', null,
              'soni', null, 'hisobga', true, 'meta', '{}'::jsonb);
          end if;
          -- qoldiq = 0 (to'liq to'langan) -> qatorga qo'shilmaydi (ataylab)
        end if;
      end loop;

      if v_q2b_missing <> '{}'::jsonb then
        v_toliq := false;
        for v_curkey, v_curcnt in select key, value::numeric from jsonb_each_text(v_q2b_missing) loop
          v_xatolar := array_append(v_xatolar,
            'Q2b: ' || coalesce(v_curkey, '?') || ' kursi yo''q (' || v_curcnt::int || ' yuk)');
        end loop;
      end if;

      v_bolimlar := v_bolimlar || jsonb_build_object('Q2b',
        jsonb_build_object('uzs', v_q2b_uzs, 'usd', null, 'soni', v_q2b_soni));
      v_qatorlar := v_qatorlar || v_q2b_rows;
    end if;
  exception when others then
    v_q2b_uzs := null;
    v_bolimlar := v_bolimlar || jsonb_build_object('Q2b', null);
    v_toliq := false;
    v_xatolar := array_append(v_xatolar, 'Q2b: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- [D] Daftar 4010/6010 — QO'SHIMCHA MA'LUMOT, jamiga KIRMAYDI
  -- =====================================================================
  begin
    v_d_rows := '[]'::jsonb;

    if to_regclass('public.v_hisob_qoldiq') is not null then
      for v_ref, v_nom, v_num in
        select h.code, h.code || ' daftar qoldigi', coalesce(h.qoldiq, 0)::numeric
          from v_hisob_qoldiq h
         where h.code in ('4010', '6010')
      loop
        v_d_rows := v_d_rows || jsonb_build_object(
          'bolim', 'D', 'ref', v_ref, 'nom', v_nom, 'uzs', v_num, 'usd', null,
          'soni', null, 'hisobga', false, 'meta', '{}'::jsonb);
      end loop;
    end if;

    v_bolimlar := v_bolimlar || jsonb_build_object('D',
      jsonb_build_object('uzs', null, 'usd', null, 'soni', jsonb_array_length(v_d_rows)));
    v_qatorlar := v_qatorlar || v_d_rows;
  exception when others then
    -- D jamiga kirmaydi — toliq bu sabab bilan false qilinmaydi, faqat qayd etiladi.
    v_bolimlar := v_bolimlar || jsonb_build_object('D', null);
    v_xatolar := array_append(v_xatolar, 'D: ' || left(sqlerrm, 200));
  end;

  -- =====================================================================
  -- JAMI: SAK = A+H+B+T1+T5+Y3a+K3b+K4+B6+Q2a − Q2b  (null = 0)   -- H qo'shildi 2026-10-28
  -- =====================================================================
  v_jami_uzs := coalesce(v_a_uzs, 0) + coalesce(v_h_uzs, 0) + coalesce(v_b_uzs, 0) + coalesce(v_t1_uzs, 0)
    + coalesce(v_t5_uzs, 0) + coalesce(v_y3a_uzs, 0) + coalesce(v_k3b_uzs, 0)
    + coalesce(v_k4_uzs, 0) + coalesce(v_b6_uzs, 0) + coalesce(v_q2a_uzs, 0)
    - coalesce(v_q2b_uzs, 0);
  -- USD: jami va usd'si bo'sh bo'limlar so'mdan kurs bilan (2026-09-08 tuzatish —
  -- avval jami_usd faqat A+B yig'indisi edi: 11,98 mlrd so'mga $199 ming chiqardi).
  if coalesce(v_kurs_usd, 0) > 0 then
    v_jami_usd := round(v_jami_uzs / v_kurs_usd, 2);
    for v_ref, v_el in select key, value from jsonb_each(v_bolimlar) loop
      if v_el is not null and jsonb_typeof(v_el) = 'object'
         and (v_el ->> 'usd') is null and (v_el ->> 'uzs') is not null then
        v_bolimlar := jsonb_set(v_bolimlar, array[v_ref, 'usd'],
                        to_jsonb(round((v_el ->> 'uzs')::numeric / v_kurs_usd, 2)));
      end if;
    end loop;
  else
    v_jami_usd := null;
  end if;

  -- ---- yozish: HAR KUN UCHUN BITTA QATOR (2026-09-09, Asilbek: «2 snapshot
  -- bo'p qoldi, faqat 1 ta kerak — eng oxirgi»). Rejimdan QAT'I NAZAR o'sha
  -- kunning eski qatori o'chiriladi (cascade `aylanma_qator` ni ham oladi).
  --   ESKI xatti-harakat: faqat 'cron' o'chirilardi, 'qolda' esa HAR DOIM
  --   yangi qator qo'shardi — qo'lda ikki marta ishga tushirilsa bir kunda
  --   ikki snapshot qolardi va sahifadagi ro'yxat select'i ikkalasini
  --   ko'rsatardi.
  --   OQIBAT: qo'lda hisob o'sha kunning cron qatorini ham almashtiradi —
  --   ONGLI, chunki oxirgi hisob eng to'g'risi. Tarix kun kesimida saqlanadi.
  -- 2026-10-17: profit-summary yig'indi tekshiruvi (omborlar jami <> umumiy javob >1%) — banner (toliq o'zgarmaydi)
  if jsonb_typeof(p_data -> 'profit_ogoh') = 'array' then
    v_xatolar := v_xatolar || array(select left(x, 200) from jsonb_array_elements_text(p_data -> 'profit_ogoh') x limit 10);
  end if;

  delete from aylanma_snapshot where sana = v_sana;

  insert into aylanma_snapshot (
    sana, rejim, hisoblangan_at, kurs_usd, jami_uzs, jami_usd, toliq, bolimlar, manba_holati, xatolar)
  values (
    v_sana, v_rejim, now(), v_kurs_usd, v_jami_uzs, v_jami_usd, v_toliq, v_bolimlar, v_manba, v_xatolar)
  returning id into v_snapshot_id;

  if jsonb_array_length(v_qatorlar) > 0 then
    insert into aylanma_qator (snapshot_id, bolim, ref, nom, usd, uzs, soni, hisobga, meta)
    select v_snapshot_id,
           q ->> 'bolim', q ->> 'ref', q ->> 'nom',
           nullif(q ->> 'usd', '')::numeric, nullif(q ->> 'uzs', '')::numeric,
           nullif(q ->> 'soni', '')::numeric, coalesce((q ->> 'hisobga')::boolean, true),
           coalesce(q -> 'meta', '{}'::jsonb)
      from jsonb_array_elements(v_qatorlar) q;
  end if;

  return jsonb_build_object(
    'ok', true, 'id', v_snapshot_id, 'sana', v_sana, 'rejim', v_rejim,
    'jami_uzs', v_jami_uzs, 'jami_usd', v_jami_usd, 'toliq', v_toliq,
    'bolimlar', v_bolimlar, 'xatolar', to_jsonb(v_xatolar));
end
$ayl_sync$;
revoke all on function sync_aylanma_snapshot(jsonb) from public, anon, authenticated;
grant execute on function sync_aylanma_snapshot(jsonb) to service_role;
comment on function sync_aylanma_snapshot(jsonb) is
  'service_role ONLY (n8n «Aros Provodka - Aylanma Snapshot»). Har bo''lim ALOHIDA exception '
  'blokida. PUL HARAKATI YO''Q. Q2a qarz va hamyon AYNI manbadan (Q2A_FIX); HAR KUN UCHUN BITTA qator (BIR_KUN); '
  'tovar/brak manbai Aros profit-summary (PROFIT_API). '
  'YANGI (PROVODKA_AYLANMA_HODIM_KASSA.sql, 2026-10-28): [H] hodim kassalari (5400 ostidagi barcha 54xx, '
  'aylanma_hodim_kassa) — SAK = A+H+B+T1+T5+Y3a+K3b+K4+B6+Q2a−Q2b.';


-- #####################################################################
-- ##  3-BO'LIM — aylanma_hodim_kassa_backfill(p_from, p_to)           ##
-- #####################################################################
-- Mavjud snapshotlarni H bilan qayta to'ldiradi. Har snapshot uchun:
--   H = aylanma_hodim_kassa(sana, hisoblangan_at)  (tarixiy qoldiq, kurs = snapshot kurs_usd)
--   jami_uzs = jami_uzs − eski H.uzs (bo'lsa) + yangi H.uzs      -> IDEMPOTENT
--   jami_usd = round(jami_uzs / kurs_usd, 2)  (kurs bo'lsa)
--   bolimlar.H = {uzs, usd, soni, manba:'backfill'}
--   aylanma_qator: faqat bolim='H' qatorlari o'chirilib qayta yoziladi; boshqa bo'limlar TEGILMAYDI.
-- Har snapshot alohida exception — bittasi yiqilsa qolganlari yoziladi, sabab javobda.
create or replace function aylanma_hodim_kassa_backfill(p_from date default null, p_to date default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $hk_bf$
declare
  s        record;
  v_h      jsonb;
  v_old    numeric;
  v_new    numeric;
  v_jami   numeric;
  v_n      int := 0;
  v_xato   int := 0;
  v_err    text[] := '{}';
  v_kunlar text[] := '{}';
begin
  if auth.uid() is not null and not is_admin() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  -- cron sync bilan bir vaqtda yozmaslik uchun o'sha qulf
  perform pg_advisory_xact_lock(hashtext('sync_aylanma_snapshot'));

  for s in
    select id, sana, hisoblangan_at, kurs_usd, jami_uzs, bolimlar
      from aylanma_snapshot
     where (p_from is null or sana >= p_from)
       and (p_to   is null or sana <= p_to)
     order by sana, hisoblangan_at
  loop
    begin
      v_h := aylanma_hodim_kassa(s.sana, s.hisoblangan_at);
      if coalesce((v_h ->> 'ok')::boolean, false) is not true then
        raise exception '%', coalesce(v_h ->> 'kod', v_h ->> 'error', 'aylanma_hodim_kassa xato');
      end if;

      v_old  := nullif(s.bolimlar #>> '{H,uzs}', '')::numeric;      -- qayta RUN: eski H ayiriladi
      v_new  := coalesce((v_h ->> 'uzs')::numeric, 0);
      v_jami := coalesce(s.jami_uzs, 0) - coalesce(v_old, 0) + v_new;

      delete from aylanma_qator where snapshot_id = s.id and bolim = 'H';
      insert into aylanma_qator (snapshot_id, bolim, ref, nom, usd, uzs, soni, hisobga, meta)
      select s.id, q ->> 'bolim', q ->> 'ref', q ->> 'nom',
             nullif(q ->> 'usd', '')::numeric, nullif(q ->> 'uzs', '')::numeric,
             nullif(q ->> 'soni', '')::numeric, coalesce((q ->> 'hisobga')::boolean, true),
             coalesce(q -> 'meta', '{}'::jsonb)
        from jsonb_array_elements(coalesce(v_h -> 'rows', '[]'::jsonb)) q;

      update aylanma_snapshot
         set bolimlar = coalesce(bolimlar, '{}'::jsonb) || jsonb_build_object('H',
               jsonb_build_object('uzs', v_new,
                                  'usd', coalesce((v_h ->> 'usd')::numeric, 0),
                                  'soni', coalesce((v_h ->> 'soni')::int, 0),
                                  'manba', 'backfill')),
             jami_uzs = v_jami,
             jami_usd = case when coalesce(kurs_usd, 0) > 0 then round(v_jami / kurs_usd, 2) else jami_usd end
       where id = s.id;

      v_n := v_n + 1;
      v_kunlar := array_append(v_kunlar, s.sana::text || ': ' || round(v_new / 1e6) || ' mln');
    exception when others then
      v_xato := v_xato + 1;
      v_err := array_append(v_err, s.sana::text || ': ' || left(sqlerrm, 150));
    end;
  end loop;

  return jsonb_build_object('ok', true, 'yangilandi', v_n, 'xato', v_xato,
                            'xatolar', to_jsonb(v_err), 'h_mln', to_jsonb(v_kunlar));
end
$hk_bf$;
revoke all on function aylanma_hodim_kassa_backfill(date, date) from public, anon;
grant execute on function aylanma_hodim_kassa_backfill(date, date) to authenticated, service_role;
comment on function aylanma_hodim_kassa_backfill(date, date) is
  'Admin/SQL editor: mavjud aylanma_snapshot qatorlariga H (hodim kassalari) bo''limini tarixiy qoldiq bilan '
  'to''ldiradi, jami_uzs/jami_usd ni yangilaydi, aylanma_qator H qatorlarini almashtiradi. Idempotent.';


-- #####################################################################
-- ##  4-BO'LIM — PostgREST keshi + BACKFILL (bir marta, hammasi)      ##
-- #####################################################################
notify pgrst, 'reload schema';

-- Hamma mavjud snapshot (sana chegarasiz). Qayta RUN xavfsiz.
select aylanma_hodim_kassa_backfill(null, null) as backfill_natija;


-- #####################################################################
-- ##  TEKSHIRUV (faqat select)                                        ##
-- #####################################################################

-- 1) Jonli H: kutilgan ~17,59 mlrd (28.10), G'iyos ~17,31 mlrd = 1 211 364 USD + 1 600 000 CHY + 2 mln UZS
select (h ->> 'uzs')::numeric as h_uzs, (h ->> 'usd')::numeric as h_usd, (h ->> 'soni')::int as soni
  from aylanma_hodim_kassa(null, null) h;

select q ->> 'nom' as nom, (q ->> 'uzs')::numeric as uzs, (q ->> 'usd')::numeric as usd, q -> 'meta' -> 'valyutalar' as valyutalar
  from jsonb_array_elements(aylanma_hodim_kassa(null, null) -> 'rows') q
 order by (q ->> 'uzs')::numeric desc
 limit 10;

-- 2) Snapshotlar: H to'ldirildi, jami o'sdi (28.10: −1,16 mlrd -> ~16,4 mlrd kutiladi)
select sana, rejim, kurs_usd, round(jami_uzs / 1e6) as jami_mln,
       round((bolimlar #>> '{A,uzs}')::numeric / 1e6) as a_mln,
       round((bolimlar #>> '{H,uzs}')::numeric / 1e6) as h_mln,
       bolimlar #>> '{H,manba}' as h_manba,
       (select count(*) from aylanma_qator q where q.snapshot_id = s.id and q.bolim = 'H') as h_qator
  from aylanma_snapshot s
 order by sana desc
 limit 40;

-- 3) H siz qolgan snapshot bo'lmasin (BO'SH chiqsin)
select sana, rejim from aylanma_snapshot where bolimlar -> 'H' is null order by sana;
