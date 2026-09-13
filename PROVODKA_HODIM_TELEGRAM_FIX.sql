-- =====================================================================
--  PROVODKA_HODIM_TELEGRAM_FIX.sql — «Hodim -> Telegram» tuzatishi (2026-09-13)
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).
--
--  XATO: Sozlamalar «Avtomatik bog'lash» -> operator does not exist: text = uuid.
--  SABAB: bazada accounts.taskfix_user_id ustuni UUID (TaskFix uni oldinroq
--  shunday yaratgan; PROVODKA_HODIM_TELEGRAM.sql dagi add column if not exists
--  text mavjud ustunni o'zgartirmagan). Aros users.id esa INTEGER (1-3 xonali).
--  Demak TaskFix uuid Aros foydalanuvchisiga hech qachon mos kelmaydi — n8n
--  «Hodim Notify» ham hodimni topolmay xabarni FAQAT adminlarga yuborardi.
--
--  YECHIM (additive):
--    1-BO'LIM — yangi ustun accounts.aros_user_id integer (Aros users.id).
--               taskfix_user_id ga TEGILMAYDI (TaskFix o'zi ishlatadi).
--    2-BO'LIM — hodim_tg_royxat / hodim_tg_bogla / hodim_tg_avto_bogla qayta
--               e'lon (imzo bir xil) — endi aros_user_id bilan ishlaydi.
--    3-BO'LIM — hodim_notify_pending qayta e'lon (imzo bir xil, tana
--               PROVODKA_JADVAL_NOTIFY.sql dagi eng oxirgi versiyadan
--               so'zma-so'z) — javobdagi taskfix_user_id kaliti endi avval
--               aros_user_id ni beradi. n8n kodiga tegish SHART EMAS.
--    4-BO'LIM — yakuniy tekshiruv.
--  Idempotent: qayta RUN qilish xavfsiz. Anonim do bloki yo'q.
--  SQL'ni ASILBEK RUN qiladi.
-- =====================================================================


-- #####################################################################
-- ##  1-BO'LIM — accounts.aros_user_id                                ##
-- #####################################################################

alter table accounts add column if not exists aros_user_id integer;

comment on column accounts.aros_user_id is
  'Aros PG users.id (integer) — hodim xarajat kassasi Telegram uchun shu foydalanuvchiga '
  'bog''lanadi (Sozlamalar «Hodim -> Telegram»). n8n Hodim Notify hodim_notify_pending '
  'orqali shu qiymat bilan telegram_id ni topadi. taskfix_user_id (TaskFix uuid) bilan aralashmasin.';


-- #####################################################################
-- ##  1b-BO'LIM — hodim_tg_translit: sikl o'rniga translate() (tezlik) ##
-- #####################################################################
-- Imzo va natija AYNAN o'sha (butun kirill bloki bo'yicha tekshirilgan):
-- avval plpgsql sikli 36 ta replace qilardi; endi 9 ta ko'p harfli replace +
-- bitta translate(). Faqat hodim_tg_* funksiyalari ishlatadi.
create or replace function hodim_tg_translit(p_text text)
returns text
language sql
immutable
as $fn$
  select translate(
           replace(replace(replace(replace(replace(replace(replace(replace(replace(
             lower(coalesce(p_text, '')),
             'ё', 'yo'), 'ж', 'j'), 'ц', 'ts'), 'ч', 'ch'), 'ш', 'sh'), 'щ', 'sh'),
             'ъ', ''), 'ю', 'yu'), 'я', 'ya'),
           'ыэқғҳўабвгдезийклмнопрстуфх',
           'ieqghoabvgdeziyklmnoprstufx');
$fn$;

-- #####################################################################
-- ##  2-BO'LIM — Telegram bog'lash funksiyalari (aros_user_id)        ##
-- #####################################################################

create or replace function hodim_tg_royxat()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not hodim_tg_page_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;

  return (
    with kassalar_raw as (
      -- 2026-09-13 FIX: bog'lash endi accounts.aros_user_id (integer) da; CTE ustun nomi
      -- (taskfix_user_id) ataylab saqlandi — quyidagi tana o'zgarmasin.
      select a.id, a.code, a.name, a.subtitle, a.aros_user_id::text as taskfix_user_id
        from accounts a
        join accounts g on g.id = a.parent_id and g.kassa_turi = 'xarajat_guruh'
       where a.kassa_turi = 'xarajat'
         and a.pul_turi is null
         and coalesce(a.currency, 'UZS') = 'UZS'
         and coalesce(a.is_active, true)
    ),
    kassalar_link as (
      select k.*,
             t.ism as bogl_ism, t.lavozim as bogl_lavozim,
             case
               when k.taskfix_user_id is null or btrim(k.taskfix_user_id) = '' then 'yoq'
               when t.user_id is not null then 'boglangan'
               else 'topilmadi'
             end as holat
        from kassalar_raw k
        left join aros_tg_user t
          on t.user_id = k.taskfix_user_id and t.faol
    ),
    users_faol as (
      select t.user_id, t.ism, t.lavozim, t.warehouse_name, t.telefon, t.worker_id
        from aros_tg_user t
       where t.faol
    ),
    -- ⚡ 2026-09-13 TEZLIK: ism/telefon HAR QATOR uchun BIR MARTA normallashtiriladi
    --    (k_nm / u_nm / s_nm), juftliklarda faqat tayyor satrlar solishtiriladi.
    --    Avval hodim_tg_ball() har juftlikda (38 x 129) 12 martagacha translit
    --    (36 ta replace sikli) chaqirardi — so'rov vaqt chegarasidan oshib,
    --    brauzerda "Failed to fetch" chiqardi. Ball mantiqi AYNAN o'sha:
    --    ikkalasidan biri bo'sh -> 0; norm teng -> 3; so'zlar to'plami teng -> 2
    --    (+ aros_staff ko'prigi worker_id/telefon bilan tasdiqlasa -> 3).
    k_nm as materialized (
      select k.id, hodim_tg_norm(k.name) as nm, hodim_tg_words(k.name) as wd
        from kassalar_link k
       where k.holat <> 'boglangan'
    ),
    u_nm as materialized (
      select u.user_id, u.worker_id, hodim_tg_tel_norm(u.telefon) as tel9,
             hodim_tg_norm(u.ism) as nm, hodim_tg_words(u.ism) as wd
        from users_faol u
    ),
    s_nm as materialized (
      select s.staff_id, hodim_tg_tel_norm(s.telefon) as tel9, hodim_tg_norm(s.toliq_nom) as nm
        from aros_staff s
       where s.is_active
    ),
    staff_bridge as (
      -- Kassa nomi <-> aros_staff.toliq_nom TO'LIQ teng bo'lsagina ko'prik ishonchli
      -- (fuzzy ko'prik — Telegram xabari begona odamga ketishi mumkin).
      select k.id as kassa_id, s.staff_id, s.tel9 as staff_tel9
        from k_nm k
        join s_nm s on s.nm = k.nm and k.nm <> ''
    ),
    ball0 as (
      select k.id as kassa_id, u.user_id, u.worker_id, u.tel9,
             case when k.nm = '' or u.nm = '' then 0
                  when k.nm = u.nm then 3
                  when k.wd = u.wd then 2
                  -- ball 1 = «o'xshash» (FAQAT TAKLIF, avto-bog'lashga KIRMAYDI):
                  -- kassa nomidagi kamida 2 so'z foydalanuvchi ismidagi so'zga teng
                  -- yoki birinchi 4 harfi bir xil ("obidjon"~"obid", "murtazayev"~"murtzayev").
                  when (select count(*) from unnest(k.wd) kw
                         where length(kw) >= 3
                           and exists (select 1 from unnest(u.wd) uw
                                        where uw = kw
                                           or (length(kw) >= 4 and length(uw) >= 4
                                               and left(kw, 4) = left(uw, 4)))) >= 2 then 1
                  else 0 end as b
        from k_nm k
        cross join u_nm u
    ),
    taklif_raw as (
      select b0.kassa_id, b0.user_id,
             case when b0.b = 2 and exists (
                         select 1 from staff_bridge sb
                          where sb.kassa_id = b0.kassa_id
                            and (sb.staff_id::text = b0.worker_id
                                 or (sb.staff_tel9 is not null and sb.staff_tel9 = b0.tel9)))
                  then 3 else b0.b end as ball
        from ball0 b0
       where b0.b >= 1
    )
    select jsonb_build_object(
      'ok', true,
      'kassalar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', kl.id, 'code', kl.code, 'name', kl.name, 'subtitle', kl.subtitle,
                 'taskfix_user_id', kl.taskfix_user_id,
                 'bogl_ism', kl.bogl_ism, 'bogl_lavozim', kl.bogl_lavozim, 'holat', kl.holat)
               order by kl.code)
        from kassalar_link kl), '[]'::jsonb),
      'users', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'user_id', u.user_id, 'ism', u.ism, 'lavozim', u.lavozim,
                 'warehouse_name', u.warehouse_name, 'telefon', u.telefon)
               order by u.ism)
        from users_faol u), '[]'::jsonb),
      'taklif', coalesce((
        select jsonb_agg(jsonb_build_object('kassa_id', tr.kassa_id, 'user_id', tr.user_id, 'ball', tr.ball)
               order by tr.kassa_id, tr.ball desc)
        from taklif_raw tr where tr.ball >= 1), '[]'::jsonb)
    )
  );
end
$fn$;

revoke all on function hodim_tg_royxat() from public, anon;
grant execute on function hodim_tg_royxat() to authenticated;

create or replace function hodim_tg_bogla(p_kassa uuid, p_user_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_kassa accounts%rowtype;
  v_uid   text := nullif(btrim(coalesce(p_user_id, '')), '');
  v_ctx   text;
begin
  if not hodim_tg_page_ok() then
    raise exception 'Sozlamalar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;
  if p_kassa is null then
    raise exception 'Kassa tanlanmadi' using errcode = '22000';
  end if;

  select * into v_kassa from accounts where id = p_kassa and kassa_turi = 'xarajat';
  if not found then
    raise exception 'Hodim xarajat kassasi topilmadi (kassa_turi=xarajat bo''lishi shart)'
      using errcode = '22023';
  end if;

  if v_uid is null then
    update accounts set aros_user_id = null where id = p_kassa;
    return jsonb_build_object('ok', true, 'kassa_id', p_kassa, 'user_id', null);
  end if;

  if not exists (select 1 from aros_tg_user where user_id = v_uid and faol) then
    raise exception 'Bu foydalanuvchi Telegram ro''yxatida topilmadi yoki nofaol'
      using errcode = '22023';
  end if;

  if v_uid !~ '^[0-9]+$' then
    raise exception 'Aros foydalanuvchi id raqam bolishi kerak' using errcode = '22023';
  end if;

  update accounts set aros_user_id = v_uid::integer where id = p_kassa;
  return jsonb_build_object('ok', true, 'kassa_id', p_kassa, 'user_id', v_uid);
exception when others then
  -- Xato JOYI xabarga qo'shiladi (qaysi so'rov/trigger) — tashxis uchun.
  get stacked diagnostics v_ctx = pg_exception_context;
  raise exception '% [joy: %]', sqlerrm, left(coalesce(v_ctx, ''), 400) using errcode = sqlstate;
end
$fn$;

revoke all on function hodim_tg_bogla(uuid, text) from public, anon;
grant execute on function hodim_tg_bogla(uuid, text) to authenticated;

create or replace function hodim_tg_avto_bogla()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_out jsonb;
  v_ctx text;
begin
  if not hodim_tg_page_ok() then
    raise exception 'Sozlamalar sahifasiga ruxsat yoq' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('hodim_tg_avto_bogla'));

  with unbound as (
    select a.id as kassa_id, a.name, a.code,
           (a.aros_user_id is not null
            and exists (select 1 from aros_tg_user t where t.user_id = a.aros_user_id::text and t.faol)
           ) as boglangan
      from accounts a
      join accounts g on g.id = a.parent_id and g.kassa_turi = 'xarajat_guruh'
     where a.kassa_turi = 'xarajat'
       and a.pul_turi is null
       and coalesce(a.currency, 'UZS') = 'UZS'
       and coalesce(a.is_active, true)
  ),
  unbound_only as (
    select kassa_id, name, code from unbound where not boglangan
  ),
  users_faol as (
    select t.user_id, t.ism, t.telefon, t.worker_id from aros_tg_user t where t.faol
  ),
  -- ⚡ 2026-09-13 TEZLIK: ism/telefon HAR QATOR uchun BIR MARTA normallashtiriladi
  --    (k_nm / u_nm / s_nm), juftliklarda faqat tayyor satrlar solishtiriladi.
  --    Avval hodim_tg_ball() har juftlikda (38 x 129) 12 martagacha translit
  --    (36 ta replace sikli) chaqirardi — so'rov vaqt chegarasidan oshib,
  --    brauzerda "Failed to fetch" chiqardi. Ball mantiqi AYNAN o'sha:
  --    ikkalasidan biri bo'sh -> 0; norm teng -> 3; so'zlar to'plami teng -> 2
  --    (+ aros_staff ko'prigi worker_id/telefon bilan tasdiqlasa -> 3).
  k_nm as materialized (
    select u.kassa_id, u.name, hodim_tg_norm(u.name) as nm, hodim_tg_words(u.name) as wd
      from unbound_only u
  ),
  u_nm as materialized (
    select uf.user_id, uf.ism, uf.worker_id, hodim_tg_tel_norm(uf.telefon) as tel9,
           hodim_tg_norm(uf.ism) as nm, hodim_tg_words(uf.ism) as wd
      from users_faol uf
  ),
  s_nm as materialized (
    select s.staff_id, hodim_tg_tel_norm(s.telefon) as tel9, hodim_tg_norm(s.toliq_nom) as nm
      from aros_staff s
     where s.is_active
  ),
  staff_bridge as (
    select k.kassa_id, s.staff_id, s.tel9 as staff_tel9
      from k_nm k
      join s_nm s on s.nm = k.nm and k.nm <> ''
  ),
  kandidat as (
    select k.kassa_id, k.name as kassa_nom, u.user_id, u.ism,
           case when k.nm = '' or u.nm = '' then 0
                when k.nm = u.nm then 3
                when k.wd = u.wd and exists (
                       select 1 from staff_bridge b
                        where b.kassa_id = k.kassa_id
                          and (b.staff_id::text = u.worker_id
                               or (b.staff_tel9 is not null and b.staff_tel9 = u.tel9))) then 3
                when k.wd = u.wd then 2
                else 0 end as ball
      from k_nm k
      cross join u_nm u
  ),
  top3 as (
    select * from kandidat where ball = 3
  ),
  per_kassa as (
    select kassa_id, min(kassa_nom) as kassa_nom, count(*) as n,
           array_agg(user_id order by user_id) as uids,
           jsonb_agg(jsonb_build_object('user_id', user_id, 'ism', ism) order by ism) as nomzodlar
      from top3
     group by kassa_id
  ),
  tanho as (
    select p.kassa_id, p.uids[1] as user_id from per_kassa p
     where p.n = 1 and p.uids[1] ~ '^[0-9]+$'
  ),
  chalk as (
    select p.kassa_id, p.kassa_nom, p.nomzodlar from per_kassa p where p.n > 1
  ),
  yoz as (
    update accounts a
       set aros_user_id = t.user_id::integer
      from tanho t
     where a.id = t.kassa_id
    returning a.id as kassa_id, a.code, a.name, t.user_id
  )
  select jsonb_build_object(
           'ok', true,
           'boglandi', (select count(*) from yoz),
           'chalkash', coalesce((select jsonb_agg(jsonb_build_object(
                          'kassa_id', c.kassa_id, 'kassa_nom', c.kassa_nom, 'nomzodlar', c.nomzodlar)
                          order by c.kassa_nom) from chalk c), '[]'::jsonb),
           'topilmadi', (select count(*) from unbound_only)
                        - (select count(*) from yoz)
                        - (select count(*) from chalk))
    into v_out;

  return v_out;
exception when others then
  get stacked diagnostics v_ctx = pg_exception_context;
  raise exception '% [joy: %]', sqlerrm, left(coalesce(v_ctx, ''), 400) using errcode = sqlstate;
end
$fn$;

revoke all on function hodim_tg_avto_bogla() from public, anon;
grant execute on function hodim_tg_avto_bogla() to authenticated;


-- #####################################################################
-- ##  3-BO'LIM — hodim_notify_pending: hodim kaliti aros_user_id      ##
-- #####################################################################

create or replace function hodim_notify_pending(p_limit int default 50)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_ids   bigint[] := '{}';
  v_items jsonb;
  v_admin jsonb;
  v_r     record;   -- 🔴 `r` EMAS: pastda `join accounts r` taxallusi bor,
                    --    ikkalasi ziddiyatga tushib 42702 berardi
begin
  -- (a) TOZALASH: 30 soniya ichida o'chirilgan/bekor qilingan yozuvlarning
  --     qatorlari hech qachon tanlanmaydi va navbatda abadiy osilib qolardi.
  update hodim_notify n
     set sent_at = now(),
         last_error = 'yozuv o''chirilgan yoki posted emas'
    from entry e
   where e.id = n.entry_id
     and n.sent_at is null
     and coalesce(n.hodisa, '') <> 'ochirildi'
     and (e.is_deleted or e.status is distinct from 'posted');

  -- (b) Navbatdan olish
  for v_r in
    select n.id
      from hodim_notify n
      join entry e on e.id = n.entry_id
     where n.sent_at is null
       and n.attempts < 30
       and n.created_at < now() - interval '30 seconds'
       and e.status = 'posted'
       and (e.is_deleted = false or n.hodisa = 'ochirildi')
     order by n.id
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update of n skip locked
  loop
    v_ids := array_append(v_ids, v_r.id);
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
           'telegram_id', telegram_id, 'ism', coalesce(ism, '')
         )), '[]'::jsonb)
    into v_admin
    from hodim_notify_admin
   where is_active;

  if array_length(v_ids, 1) is null then
    return jsonb_build_object('items', '[]'::jsonb, 'adminlar', v_admin);
  end if;

  update hodim_notify set attempts = attempts + 1 where id = any(v_ids);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb) into v_items
  from (
    select
      n.id,
      n.entry_id,
      n.kassa_id,
      -- Tur: maxsus hodisa bo'lmasa qarshi tomondan aniqlanadi.
      -- 🔴 `section='pul'` bo'yicha — kod prefiksi (5xxx) bilan EMAS
      --    (jurnal-dev.html klass() bilan bir xil qoida).
      coalesce(n.hodisa,
        case when n.delta > 0
             then case when coalesce(q.qarshi_pul, false) then 'transfer_kirim' else 'kirim' end
             else case when coalesce(q.qarshi_pul, false) then 'transfer_chiqim' else 'chiqim' end
        end)                                  as hodisa,
      (n.delta > 0)                           as kirimmi,
      abs(n.delta)::numeric                   as summa,
      abs(coalesce(n.fc, 0))::numeric         as fc_summa,
      n.qoldiq_oldin,
      n.qoldiq_keyin,
      r.code                                  as kassa_kod,
      r.name                                  as kassa_nom,
      -- to_jsonb(...)->> : ustun yo'q bo'lsa ham so'rov yiqilmaydi
      to_jsonb(r) ->> 'subtitle'              as subtitle,
      -- 🔴 2026-09-13 FIX: n8n «Hodim Notify» hodimni shu kalit bilan Aros users.id
      --    (integer) orqali topadi. Eski accounts.taskfix_user_id — TaskFix uuid,
      --    Aros users.id bilan HECH QACHON mos kelmasdi -> xabar faqat adminlarga.
      --    Endi Sozlamalar «Hodim -> Telegram» da bog'langan aros_user_id ustun,
      --    bo'lmasa eski qiymat (n8n kodiga tegilmaydi).
      coalesce(to_jsonb(r) ->> 'aros_user_id',
               to_jsonb(r) ->> 'taskfix_user_id')   as taskfix_user_id,
      to_jsonb(r) ->> 'aros_user_id'          as aros_user_id,
      to_jsonb(a) ->> 'pul_turi'              as pul_turi,
      coalesce(a.currency, 'UZS')             as valyuta,
      q.qarshi_kod,
      q.qarshi_nom,
      e.entry_date::text                      as sana,
      -- 🔴 YANGI (2026-08-26): hodisa VAQTI. `n.created_at` — bu qator navbatga
      --    tushgan payt, ya'ni amal HAQIQATDA sodir bo'lgan lahza (tahrir/tasdiq
      --    uchun ham to'g'ri). `sana` esa BUXGALTERIYA sanasi (qo'lda tanlanadi)
      --    va hodisa sanasidan farq qilishi mumkin — shuning uchun ikkalasi ham.
      to_char(n.created_at + interval '5 hours', 'DD.MM.YYYY') as hodisa_sana,
      to_char(n.created_at + interval '5 hours', 'HH24:MI')   as vaqt,
      e.description                           as izoh,
      -- 🆕 2026-09-02 (jadval): Excel'dan nusxalangan ro'yxat endi `entry.jadval` jsonb da
      --    (PROVODKA_JADVAL.sql). Telegram'ga faqat XULOSA: qator soni + jami.
      --    `to_jsonb(e)` naqshi ataylab — ustun hali yo'q bazada ham RPC yiqilmaydi (null).
      (to_jsonb(e) -> 'jadval' ->> 'n')::int          as jadval_n,
      (to_jsonb(e) -> 'jadval' ->> 'jami')::numeric   as jadval_jami,
      e.source                                as manba,
      -- 🔴 `full_name_or_email()` ga BOG'LANMAYDI: PROVODKA_ISM.sql RUN
      --    qilinmagan bazada butun RPC 42883 bilan yiqilardi.
      coalesce(
        nullif(to_jsonb(e)  ->> 'created_by_name', ''),
        nullif(to_jsonb(pr) ->> 'full_name', ''),
        '')                                   as kim
    from hodim_notify n
    join entry e    on e.id = n.entry_id
    join accounts r on r.id = n.kassa_id
    left join accounts a on a.id = n.acc_id
    -- ⚠️ `created_by` turi bazada aniqlanmagan (PROVODKA_ISM.sql 7.5) — uuid ham,
    --    matn ham bo'lishi mumkin. `::uuid` cast FAQAT to'liq uuid shaklida
    --    bajariladi; aks holda bitta buzuq qiymat 22P02 bilan BUTUN RPC ni
    --    yiqitardi (PROVODKA_AI_HISOBOT.sql dagi qat'iy shakl).
    left join profiles pr
      on pr.id = case when (to_jsonb(e) ->> 'created_by') ~ '^[0-9a-fA-F-]{36}$'
                      then (to_jsonb(e) ->> 'created_by')::uuid end
    left join lateral (
      select bool_or(a2.section = 'pul')        as qarshi_pul,
             string_agg(distinct a2.code, ', ') as qarshi_kod,
             string_agg(distinct a2.name, ', ') as qarshi_nom
        from entry_line l2
        join accounts a2 on a2.id = l2.account_id
       where l2.entry_id = n.entry_id
         -- 🔴 Yon ASL yo'nalishdan (n.dt_yon), `delta` ishorasidan EMAS:
         --    o'chirish va summani kamaytiruvchi tahrirda delta teskari
         --    bo'lib, qarshi tomon sifatida kassaning O'ZI chiqardi.
         and case when n.dt_yon then l2.credit else l2.debit end > 0
         -- Shu kassa daraxtining satrlari qarshi tomon emas
         and hodim_kassa_root(l2.account_id) is distinct from n.kassa_id
    ) q on true
   where n.id = any(v_ids)
  ) x;

  return jsonb_build_object('items', v_items, 'adminlar', v_admin);
end $fn$;

revoke all on function hodim_notify_pending(int) from public, anon, authenticated;
grant execute on function hodim_notify_pending(int) to service_role;

notify pgrst, 'reload schema';


-- #####################################################################
-- ##  4-BO'LIM — YAKUNIY TEKSHIRUV                                     ##
-- #####################################################################

do $tg_fix_final$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'accounts'
                    and column_name = 'aros_user_id') then
    raise exception 'YAKUNIY TEKSHIRUV: accounts.aros_user_id ustuni yaralmadi';
  end if;
  if to_regprocedure('public.hodim_tg_avto_bogla()') is null
     or to_regprocedure('public.hodim_tg_bogla(uuid,text)') is null
     or to_regprocedure('public.hodim_tg_royxat()') is null
     or to_regprocedure('public.hodim_notify_pending(integer)') is null then
    raise exception 'YAKUNIY TEKSHIRUV: funksiyalardan biri yoq';
  end if;
  raise notice 'PROVODKA_HODIM_TELEGRAM_FIX.sql: tayyor — endi Sozlamalar da Avtomatik bog''lash ishlaydi';
end
$tg_fix_final$;

-- Tekshirish (ixtiyoriy): nechta hodim kassasi bog'langan
-- select count(*) filter (where aros_user_id is not null) as boglangan,
--        count(*) as jami
--   from accounts where kassa_turi = 'xarajat' and pul_turi is null;


-- #####################################################################
-- ##  5-BO'LIM — TASHXIS (faqat o'qish). Natijani to'liq nusxalab yuboring. ##
-- #####################################################################
select jsonb_pretty(jsonb_build_object(
  -- 1) Tuzatish (PROVODKA_HODIM_TELEGRAM_FIX.sql) haqiqatan bazada turibdimi?
  'fix_avto_bogla', (select pg_get_functiondef('public.hodim_tg_avto_bogla()'::regprocedure) ilike '%aros_user_id%'),
  'fix_bogla',      (select pg_get_functiondef('public.hodim_tg_bogla(uuid,text)'::regprocedure) ilike '%aros_user_id%'),
  'fix_royxat',     (select pg_get_functiondef('public.hodim_tg_royxat()'::regprocedure) ilike '%aros_user_id%'),
  'fix_pending',    (select pg_get_functiondef('public.hodim_notify_pending(integer)'::regprocedure) ilike '%aros_user_id%'),
  -- 2) Ustun turlari
  'ustunlar', (select jsonb_object_agg(table_name || '.' || column_name, data_type)
                 from information_schema.columns
                where table_schema = 'public'
                  and ((table_name = 'accounts' and column_name in ('id', 'taskfix_user_id', 'aros_user_id', 'parent_id'))
                    or (table_name = 'aros_tg_user' and column_name in ('user_id', 'worker_id'))
                    or (table_name = 'aros_staff' and column_name in ('staff_id', 'telefon')))),
  -- 3) accounts ustidagi triggerlar (repoda faqat trg_hodim_kassa_turlar bor)
  'accounts_triggerlar', (select coalesce(jsonb_agg(pg_get_triggerdef(t.oid)), '[]'::jsonb)
                            from pg_trigger t
                           where t.tgrelid = 'public.accounts'::regclass and not t.tgisinternal),
  -- 4) accounts ustidagi RLS qoidalari (update)
  'accounts_policy', (select coalesce(jsonb_agg(jsonb_build_object('nom', policyname, 'cmd', cmd,
                                                                    'using', qual, 'check', with_check)), '[]'::jsonb)
                        from pg_policies where schemaname = 'public' and tablename = 'accounts'),
  -- 5) Funksiya egasi RLS'ni chetlab o'ta oladimi
  'egasi', (select jsonb_build_object('rol', r.rolname, 'bypassrls', r.rolbypassrls, 'super', r.rolsuper)
              from pg_proc p join pg_roles r on r.oid = p.proowner
             where p.oid = 'public.hodim_tg_avto_bogla()'::regprocedure),
  -- 6) is_admin() ta'rifi (sahifa ruxsati shu orqali)
  'is_admin', (select left(pg_get_functiondef(p.oid), 600)
                 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'is_admin' limit 1)
)) as natija;
