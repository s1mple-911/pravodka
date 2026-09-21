-- ============================================================================
--  PROVODKA_KASSA_ASOSIY.sql — 2026-09-21 — «Asosiy kassa» bayrog'i (kassa sahifasi)
--  Asilbek: har kassa (markaziy, filial, hodim xarajat kassasi) oldida «Asosiy» toggle;
--  tepada 4 ta jami: Umumiy · Asosiy kassalar · Yo'ldagi pullar · Umumiy asosiy (asosiy + yo'lda).
--  Additive: accounts.asosiy ustuni + admin RPC. v_kassa_card TEGILMAYDI — klient bayroqni
--  accounts dan alohida o'qiydi (id, asosiy). Asilbek RUN qiladi.
-- ============================================================================

alter table accounts add column if not exists asosiy boolean not null default false;
comment on column accounts.asosiy is
  'Kassa sahifasi: «Asosiy kassa» belgisi. Faqat ildiz kassa (parent_id null yoki hodim kassasi) uchun; '
  'jami hisobda bola-hisoblar ota bayrog''iga ergashadi. set_kassa_asosiy() bilan admin yoqadi.';

create or replace function set_kassa_asosiy(p_account uuid, p_bool boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_ok boolean;
begin
  if not is_admin() then
    return jsonb_build_object('ok', false, 'kod', 'ruxsat');
  end if;
  select (section = 'pul' and is_active and pul_turi is null and coalesce(currency, 'UZS') = 'UZS'
          and kassa_turi is distinct from 'xarajat_guruh')
    into v_ok from accounts where id = p_account;
  if v_ok is null then
    return jsonb_build_object('ok', false, 'kod', 'topilmadi');
  end if;
  if not v_ok then
    return jsonb_build_object('ok', false, 'kod', 'kassa_emas');
  end if;
  update accounts set asosiy = coalesce(p_bool, false) where id = p_account;
  return jsonb_build_object('ok', true, 'asosiy', coalesce(p_bool, false));
end
$fn$;
revoke all on function set_kassa_asosiy(uuid, boolean) from public, anon;
grant execute on function set_kassa_asosiy(uuid, boolean) to authenticated;
comment on function set_kassa_asosiy(uuid, boolean) is
  'Admin: kassaning «Asosiy» bayrog''ini yoqadi/o''chiradi (faqat ildiz pul kassasi, guruh emas).';

select count(*) filter (where asosiy) as asosiy_kassalar, count(*) as pul_kassalari
  from accounts where section = 'pul' and is_active and pul_turi is null and coalesce(currency,'UZS') = 'UZS';
