-- ============================================================================
--  PROVODKA_OZIQ_ROYXAT.sql — 2026-09-29 — «Katta ro'yxat» masalliqlari va birliklari BAZADA
--  Asilbek: «ro'yxatni o'zgartirib turish imkoniyati kerak — birliklar ichida bog', shisha o'chirish,
--  quti ham o'chirmoqchi yoki qo'shmoqchi bo'lganimda». hodim-dev.html dagi qattiq ro'yxat o'rniga
--  oziq_royxat jadvali: tur = 'mahsulot' | 'birlik'. O'qish — hamma (authenticated), qo'shish/o'chirish —
--  FAQAT admin (profiles.role='admin'), RPC orqali. Jadval yo'q bo'lsa klient o'z sukut ro'yxatiga tushadi.
--  Asilbek RUN qiladi.
-- ============================================================================

create table if not exists oziq_royxat (
  id         uuid        primary key default gen_random_uuid(),
  tur        text        not null check (tur in ('mahsulot', 'birlik')),
  nom        text        not null check (btrim(nom) <> '' and length(nom) <= 80),
  tartib     int         not null default 0,
  created_at timestamptz not null default now(),
  created_by uuid
);
create unique index if not exists oziq_royxat_tur_nom_uq on oziq_royxat (tur, lower(btrim(nom)));
comment on table oziq_royxat is
  'hodim.html «Katta ro''yxat» (oziq-ovqat jadvali): tur=mahsulot — masalliqlar, tur=birlik — kg/dona/... '
  'Yozish faqat admin (oziq_royxat_qosh / oziq_royxat_ochir). Jadvaldagi nomlar matn bo''lib saqlanadi (FK yo''q).';

alter table oziq_royxat enable row level security;
drop policy if exists oziq_royxat_sel on oziq_royxat;
create policy oziq_royxat_sel on oziq_royxat for select to authenticated using (true);
-- yozish policy'si YO'Q — faqat security definer RPC

create or replace function _oziq_admin_ok()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin');
$fn$;
revoke all on function _oziq_admin_ok() from public, anon;
grant execute on function _oziq_admin_ok() to authenticated;

create or replace function oziq_royxat_qosh(p_tur text, p_nom text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_nom text := btrim(coalesce(p_nom, ''));
  v_id  uuid;
begin
  if not _oziq_admin_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Faqat admin');
  end if;
  if p_tur not in ('mahsulot', 'birlik') then
    return jsonb_build_object('ok', false, 'kod', 'tur', 'error', 'Tur noto''g''ri');
  end if;
  if v_nom = '' or length(v_nom) > 80 then
    return jsonb_build_object('ok', false, 'kod', 'nom', 'error', 'Nom bo''sh yoki juda uzun');
  end if;
  select id into v_id from oziq_royxat where tur = p_tur and lower(btrim(nom)) = lower(v_nom);
  if v_id is not null then
    return jsonb_build_object('ok', true, 'id', v_id, 'takror', true);
  end if;
  insert into oziq_royxat (tur, nom, tartib, created_by)
  values (p_tur, v_nom, coalesce((select max(tartib) from oziq_royxat where tur = p_tur), 0) + 1, auth.uid())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end
$fn$;
revoke all on function oziq_royxat_qosh(text, text) from public, anon;
grant execute on function oziq_royxat_qosh(text, text) to authenticated;

create or replace function oziq_royxat_ochir(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_n int;
begin
  if not _oziq_admin_ok() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat', 'error', 'Faqat admin');
  end if;
  delete from oziq_royxat where id = p_id;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'ochirildi', v_n);
end
$fn$;
revoke all on function oziq_royxat_ochir(uuid) from public, anon;
grant execute on function oziq_royxat_ochir(uuid) to authenticated;

-- Boshlang'ich ro'yxat (Asilbek bergan masalliqlar, takrorsiz). Qayta RUN — takror qo'shilmaydi.
insert into oziq_royxat (tur, nom, tartib)
select 'mahsulot', v.nom, v.n
  from (values
    ('Kartoshka',1),('Piyoz',2),('Sabzi',3),('Karam',4),('Karam (salat)',5),('Lavlagi',6),('Baqlajon',7),
    ('Bolgar qalampir',8),('Pomidor',9),('Bodring',10),('Sarimsoq (chisnok)',11),('Ko''kat',12),('Zelen',13),
    ('Kashnich',14),('Ezilgan kashnich',15),('Limon',16),('Makkajo''xori (Bonduelle)',17),
    ('Mol go''shti',18),('Farsh',19),('Tovuq farsh',20),('Tovuq go''shti',21),('Tovuq oyoqchasi',22),
    ('Tovuq qanotcha',23),('Quyruq',24),
    ('Guruch',25),('Guruch lazer',26),('Guruch alanga',27),('Grechka',28),('Mosh',29),('No''xot',30),('Loviya',31),
    ('Makaron',32),('Lapsha',33),('Funchoza (fintuza)',34),
    ('Un',35),('Lavash hamir',36),('Buxanka (non)',37),('Tuxum',38),('Smetana',39),('Mayonez',40),('Saryog''',41),
    ('Yog''',42),('Zig''ir yog''i',43),
    ('Tomat',44),('Soya',45),('Uksus',46),('Limon sous',47),('Shedroy leto',48),
    ('Tuz',49),('Koreya tuzi',50),('Murch',51),('Zira',52),('Qalampir',53),('Ezilgan qalampir',54),('Paprika',55),
    ('Drojji',56),('Choyniy soda',57),
    ('Shakar',58),('Qand',59),('Novvot',60),('Talqon',61),('Pryannik',62),('Pereprava',63),('Choy',64)
  ) as v(nom, n)
on conflict do nothing;

-- Birliklar: Asilbek 2026-09-29 — bog' va shisha YO'Q
insert into oziq_royxat (tur, nom, tartib)
select 'birlik', v.nom, v.n
  from (values ('kg',1),('g',2),('dona',3),('litr',4),('pachka',5),('quti',6)) as v(nom, n)
on conflict do nothing;

notify pgrst, 'reload schema';

-- tekshiruv
select tur, count(*) as soni, string_agg(nom, ', ' order by tartib) filter (where tur = 'birlik') as birliklar
  from oziq_royxat group by tur order by tur;
