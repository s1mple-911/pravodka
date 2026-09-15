-- ============================================================================
--  PROVODKA_TANNARX_IZOH.sql — 2026-09-15 (Asilbek)
--  «Tovar tannarxida izoh majburiy emas ekan — to'lov turini tanlab, izohsiz
--  saqlab ko'rdim, saqlandi.»
--
--  Klient tomonda izoh modalda majburiy qilingan edi, lekin (a) prod
--  professional.html da yangi modal hali yo'q, (b) izoh maydonining inline
--  handleri window'da bo'lmagan funksiyani chaqirardi. Klientga tayanib
--  qolmaslik uchun qoida SERVERGA ham qo'yiladi — qaysi sahifadan yozilsa ham.
--
--  Qoida: foydalanuvchi (auth.uid() bor) tomonidan YANGI yozilayotgan
--  Tovar tannarxi (9110 yoki 9110-1) Dt satri bo'lsa, yozuvning izohi
--  (entry.description) bo'sh bo'lmasin.
--    • faqat INSERT — yukka bog'lash (9110-1 → 9110, UPDATE) eski izohsiz
--      yozuvlarni ham bog'lay oladi;
--    • service_role / n8n (auth.uid() null) — tekshirilmaydi (Aros sinxroni
--      tannarx satrlarini izohsiz yozishi mumkin).
--  Yozuv sarlavhasi (entry) satrlardan OLDIN yoziladi (provodka_yoz ham,
--  zaxira yo'l ham) — shuning uchun izoh satr yozilayotganda ma'lum.
--
--  Additive: yangi funksiya + trigger. Ikki marta RUN qilinsa ham xato bermaydi.
-- ============================================================================

create or replace function _tannarx_izoh_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_code text;
  v_desc text;
begin
  if auth.uid() is null then return new; end if;                     -- service_role / n8n
  if coalesce(new.debit, 0) <= 0 then return new; end if;              -- faqat Dt satri
  select a.code into v_code from accounts a where a.id = new.account_id;
  if v_code is null or v_code not in ('9110', '9110-1') then
    return new;                                                      -- boshqa hisob — tegilmaydi
  end if;
  select e.description into v_desc from entry e where e.id = new.entry_id;
  if nullif(btrim(coalesce(v_desc, '')), '') is null then
    raise exception 'Tovar tannarxi uchun izoh majburiy — kimdan / nima olinganini yozing'
      using errcode = '22000';
  end if;
  return new;
end
$fn$;

revoke all on function _tannarx_izoh_guard() from public, anon, authenticated;

drop trigger if exists trg_tannarx_izoh_guard on entry_line;
create trigger trg_tannarx_izoh_guard
  before insert on entry_line
  for each row execute function _tannarx_izoh_guard();

comment on function _tannarx_izoh_guard() is
  'entry_line BEFORE INSERT: foydalanuvchi yozayotgan 9110/9110-1 Dt satrida entry.description bosh bolmasin '
  '(Tovar tannarxi — izoh majburiy, Asilbek 2026-09-15). service_role otadi; UPDATE (yukka boglash) tekshirilmaydi.';


-- ============================================================================
--  DIAG
-- ============================================================================
do $diag$
begin
  if exists (select 1 from pg_trigger
              where tgrelid = 'public.entry_line'::regclass
                and tgname = 'trg_tannarx_izoh_guard' and not tgisinternal) then
    raise notice 'trg_tannarx_izoh_guard: OK (9110/9110-1 — izoh majburiy)';
  else
    raise exception 'YAKUNIY TEKSHIRUV: trg_tannarx_izoh_guard yaratilmadi';
  end if;
end
$diag$;
