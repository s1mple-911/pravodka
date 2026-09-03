-- =====================================================================
-- PROVODKA_KONVERT_KASSA_RUXSAT.sql  (2026-09-03)
-- Konvert ruxsati: KASSA sahifasi ruxsati = konvert ruxsati.
-- Asilbek QO'LDA RUN qiladi. ADDITIVE — bitta funksiya `create or replace`,
-- imzo/returns O'ZGARMAGAN (perm_can_convert() -> boolean). Idempotent.
--
-- MUAMMO: kassa-dev.html dagi «Konvert» tugmasi (va convert_start_v2 ichidagi
-- server to'sig'i) `user_perms.can_convert` bayrog'iga bog'langan edi — u
-- admin-dev'dagi alohida «Konvert» katakchasi. Amalda hech kimga bu
-- katakcha berilmaydi, natijada kassa ruxsati bor user ham konvert qila
-- olmasdi (tugma yashirin, server 42501).
--
-- YANGI QOIDA (Asilbek qarori 2026-09-03):
--   konvert ruxsati = admin
--                  OR 'kassa' ∈ allowed_pages     ← YANGI
--                  OR can_convert = true          (eski bayroq — buzilmasin)
-- Ya'ni kassa sahifasi ochiq bo'lgan HAR user konvert qila oladi. can_convert
-- ustuni saqlanadi (admin_set_provodka_perms / n8n payload kontrakti
-- o'zgarmaydi), faqat endi u YOLG'IZ manba emas.
--
-- Qamrov: convert_start_v2 (sotib olish/sotish) shu funksiyani chaqiradi —
-- shuning uchun UI'siz to'g'ridan RPC chaqiruvi ham bir xil qoidaga tushadi.
-- convert_approve/reject admin-only — tegilmagan.
-- Klient juftligi: perms-dev.js `convOk()` (permConvert + konvert sahifasi
-- ko'rinishi) — AYNAN shu qoida.
--
-- ⚠️ Izohda dollar-qavs yozilmaydi (CLAUDE.md). Tana nomlangan teg bilan.
-- =====================================================================

create or replace function perm_can_convert()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare p user_perms;
begin
  -- Eski xulq saqlanadi: service_role (auth.uid() null) va admin — ochiq.
  if auth.uid() is null then return true; end if;
  if is_admin() then return true; end if;
  select * into p from user_perms where user_id = auth.uid();
  -- Qatorsiz user — eski sukut (true). Sahifa ruxsati baribir allowed_pages
  -- bo'sh (= my_perms da hech qaysi sahifa) bo'lgani uchun UI'ga yetib kelmaydi.
  if not found then return true; end if;
  -- YANGI: kassa sahifasi ochiq bo'lsa konvert ham ochiq.
  if 'kassa' = any(coalesce(p.allowed_pages, '{}'::text[])) then return true; end if;
  return p.can_convert;
end $fn$;

revoke all on function perm_can_convert() from public, anon;
grant execute on function perm_can_convert() to authenticated, service_role;

comment on function perm_can_convert() is
  'Konvert ruxsati: admin OR kassa sahifasi ruxsati (allowed_pages) OR can_convert. '
  'convert_start_v2 shuni chaqiradi. 2026-09-03: kassa ruxsati qo''shildi.';


-- ---------------------------------------------------------------------
-- TEKSHIRUV (ixtiyoriy): kassa ruxsati bor, can_convert=false userlar —
-- endi ular konvert qila oladi.
-- ---------------------------------------------------------------------
select u.user_id, pr.full_name, u.can_convert,
       ('kassa' = any(u.allowed_pages)) as kassa_ruxsat
  from user_perms u
  left join profiles pr on pr.id = u.user_id
 where 'kassa' = any(u.allowed_pages) and not u.can_convert;
