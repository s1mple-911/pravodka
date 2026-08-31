-- =====================================================================
--  PROVODKA_IZOH_TEKSHIR.sql — izoh <-> xarajat moddasi AI tekshiruvi
--  (Jurnal V3, 2026-08-31). Supabase SQL editorida RUN qilinadi.
-- ---------------------------------------------------------------------
--  FAQAT ADDITIVE: entry'ga 3 ustun + bitta RPC + bitta reset-trigger.
--  Hech narsa DROP qilinmaydi, mavjud imzo o'zgarmaydi.
--
--  Oqim: jurnal-dev (admin) -> EF `izoh-tekshir` (Claude Haiku, ha/yoq
--  tasnifi) -> shu fayldagi izoh_tekshir_yoz() RPC (foydalanuvchi JWT,
--  service_role YO'Q) -> entry.izoh_mos/izoh_sabab/izoh_tekshir_at.
--  Har yozuv BIR MARTA tekshiriladi; izoh tahrirlansa verdict avtomat
--  eskiradi (reset-trigger) va keyingi jurnal ochilishida qayta ketadi.
--
--  Eslatma: bu fayl rasm-AI shubhasiga (entry.shubhali, PROVODKA_RASM_DETECT.sql)
--  TEGMAYDI — izoh verdikti alohida ustunlarda, klient ikkalasini birga chizadi.
-- =====================================================================

-- ## 1-BO'LIM — entry ustunlari ---------------------------------------

alter table entry
  add column if not exists izoh_mos        boolean,
  add column if not exists izoh_sabab      text,
  add column if not exists izoh_tekshir_at timestamptz;

comment on column entry.izoh_mos is
  'AI (EF izoh-tekshir) verdikti: izoh xarajat moddasiga mosmi. '
  'true=mos, false=ANIQ zid, null=tekshirilmagan yoki aniqlab bolmadi.';
comment on column entry.izoh_sabab is
  'izoh_mos=false bolganda qisqa ozbekcha sabab (<=300 belgi), aks holda null.';
comment on column entry.izoh_tekshir_at is
  'Oxirgi AI tekshiruv vaqti. NULL = hali tekshirilmagan (klient shu boyicha '
  'nomzodlarni tanlaydi). Izoh tahrirlansa trigger NULL ga qaytaradi.';

-- Jurnal "Faqat shubhali" kelajakda serverga kochsa kerak boladi — arzon partial index.
create index if not exists entry_izoh_nomos_idx
  on entry (izoh_mos) where izoh_mos = false;

-- ## 2-BO'LIM — izoh_tekshir_yoz() RPC --------------------------------
--  EF foydalanuvchi JWT si bilan chaqiradi. SECURITY DEFINER — entry'da
--  to'g'ridan update policy'siga tayanmaydi; ichida QATTIQ admin tekshiruvi
--  (EF'dagi my_perms tekshiruvi bilan birga IKKI qavat, fail-closed).

create or replace function izoh_tekshir_yoz(p_entry uuid, p_mos boolean, p_sabab text)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    raise exception 'avtorizatsiya kerak';
  end if;
  if not exists (select 1 from profiles where id = auth.uid() and role = 'admin') then
    raise exception 'faqat admin';
  end if;
  update entry
     set izoh_mos        = p_mos,
         -- sabab faqat nomoslikda saqlanadi; 300 belgidan qirqiladi (DB shishmasin)
         izoh_sabab      = case when p_mos = false then left(p_sabab, 300) else null end,
         izoh_tekshir_at = now()
   where id = p_entry;
end $fn$;

revoke all on function izoh_tekshir_yoz(uuid, boolean, text) from public, anon;
grant execute on function izoh_tekshir_yoz(uuid, boolean, text) to authenticated;

comment on function izoh_tekshir_yoz(uuid, boolean, text) is
  'EF izoh-tekshir natijasini entry ga yozadi. Faqat admin (profiles.role). '
  'p_mos null bolishi mumkin — "urinildi, aniqlab bolmadi" (izoh_tekshir_at baribir yoziladi).';

-- ## 3-BO'LIM — izoh tahrirlansa verdict eskiradi ---------------------
--  BEFORE UPDATE OF description: izoh ozgargan bolsa verdict NULL ga
--  qaytadi — keyingi jurnal ochilishida yozuv qayta tekshiriladi.
--  izoh_tekshir_yoz() ning oz update'i descriptionga TEGMAYDI -> trigger
--  unda otmaydi (sikl yoq).

create or replace function trg_entry_izoh_reset_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if new.description is distinct from old.description then
    new.izoh_mos        := null;
    new.izoh_sabab      := null;
    new.izoh_tekshir_at := null;
  end if;
  return new;
end $fn$;

drop trigger if exists trg_entry_izoh_reset on entry;
create trigger trg_entry_izoh_reset
  before update of description on entry
  for each row execute function trg_entry_izoh_reset_fn();

-- ## 4-BO'LIM — ROLLBACK (faqat kerak bolsa, qolda) -------------------
--  Klient va EF bu ustunlarsiz ham ishlaydi (42703 zaxirasi bor), shuning
--  uchun rollback odatda KERAK EMAS. Butunlay olib tashlash uchun:
--    drop trigger if exists trg_entry_izoh_reset on entry;
--    drop function if exists trg_entry_izoh_reset_fn();
--    drop function if exists izoh_tekshir_yoz(uuid, boolean, text);
--    drop index if exists entry_izoh_nomos_idx;
--    alter table entry drop column if exists izoh_mos,
--      drop column if exists izoh_sabab, drop column if exists izoh_tekshir_at;
--  (ustun DROP — umumiy taqiq ostida: faqat dev va prod jurnal bu ustunlarni
--   ishlatmasligiga ishonch hosil qilib, alohida bosqichda.)
