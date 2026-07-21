-- =====================================================================
-- PROVODKA — HODIM V3
-- ---------------------------------------------------------------------
-- 2) accounts.chek_majburiy ustuni + set_chek_majburiy() (admin)
-- 3) xarajat-cheklari PRIVATE storage bucket + RLS (employee-photos naqshi)
-- 5) hodim_oy_jami() — hodim kassasidan joriy oyda chiqqan jami
--
-- Idempotent. Asilbek qo'lda RUN qiladi. REVOKE anon. Xatoda RAISE EXCEPTION.
-- entry insert yo'li o'zgarmaydi.
-- =====================================================================


-- =====================================================================
-- 2-BO'LIM — chek_majburiy
-- ---------------------------------------------------------------------
-- Xarajat moddasiga "chek majburiy" bayrog'i. Ustun umumiy (accounts),
-- lekin faqat xarajat moddalari uchun ma'noli. Default false —
-- add_xarajat_turi (V2) bilan qo'shilganlar avtomat false bo'ladi.
-- =====================================================================

alter table accounts
  add column if not exists chek_majburiy boolean not null default false;

comment on column accounts.chek_majburiy is
  'Xarajat moddasi: hodim yozuvida chek surati majburiymi (hodim.html tekshiradi).';

-- Admin bayroqni o'zgartiradi (sozlama.html). SECURITY DEFINER — RLS'siz update.
create or replace function set_chek_majburiy(p_account uuid, p_majburiy boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Faqat admin chek sozlamasini o''zgartira oladi' using errcode = '42501';
  end if;
  update accounts set chek_majburiy = coalesce(p_majburiy, false) where id = p_account;
  if not found then
    raise exception 'Hisob topilmadi' using errcode = 'P0001';
  end if;
end $$;

revoke all on function set_chek_majburiy(uuid, boolean) from public, anon;
grant execute on function set_chek_majburiy(uuid, boolean) to authenticated;


-- =====================================================================
-- 3-BO'LIM — xarajat-cheklari PRIVATE bucket + RLS
-- ---------------------------------------------------------------------
-- Yo'l naqshi: {kassa_id}/{entry_id}.jpg. Signed URL bilan ko'riladi.
-- RLS (TaskFix employee-photos naqshi): authenticated o'qiydi/yozadi,
-- anon umuman ko'rmaydi. O'chirish berilmaydi (audit — chek qolsin;
-- kerak bo'lsa admin service_role orqali o'chiradi).
-- =====================================================================

insert into storage.buckets (id, name, public)
values ('xarajat-cheklari', 'xarajat-cheklari', false)
on conflict (id) do nothing;

-- o'qish (signed URL yaratish uchun ham select kerak)
drop policy if exists "xarajat_cheklari_select" on storage.objects;
create policy "xarajat_cheklari_select" on storage.objects
  for select to authenticated
  using (bucket_id = 'xarajat-cheklari');

-- yozish — FAQAT o'z kassa yo'liga. Yo'l: {kassa_id}/{entry_id}.jpg → 1-papka = kassa_id.
-- perm_check_accounts([kassa_id]) op_kassa_ids'ni tekshiradi (admin/service_role → true).
-- Eslatma: 1-papka yaroqli uuid bo'lishi shart (klient doim kassa.id yozadi).
drop policy if exists "xarajat_cheklari_insert" on storage.objects;
create policy "xarajat_cheklari_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'xarajat-cheklari'
    and perm_check_accounts(array[ ((storage.foldername(name))[1])::uuid ])
  );

-- qayta saqlash (upsert) — bir xil entry_id ustiga, xuddi shu kassa cheki
drop policy if exists "xarajat_cheklari_update" on storage.objects;
create policy "xarajat_cheklari_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'xarajat-cheklari'
    and perm_check_accounts(array[ ((storage.foldername(name))[1])::uuid ])
  )
  with check (
    bucket_id = 'xarajat-cheklari'
    and perm_check_accounts(array[ ((storage.foldername(name))[1])::uuid ])
  );


-- =====================================================================
-- 5-BO'LIM — hodim_oy_jami() — davr bo'yicha chiqqan jami (xarajat)
-- ---------------------------------------------------------------------
-- Berilgan kassadan davr ichida chiqqan (Kt) va qarshi tomoni xarajat
-- modda bo'lgan yozuvlar yig'indisi. hodim.html "Bu oy" ko'rsatkichi.
-- SECURITY DEFINER — hodim o'z kassasi jamisini ishonchli ko'rsin
-- (RLS to'smasin). REVOKE anon.
-- =====================================================================

create or replace function hodim_oy_jami(p_account uuid, p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(el.credit), 0)
    from entry_line el
    join entry e on e.id = el.entry_id
   where el.account_id = p_account
     and el.credit > 0
     and e.status = 'posted'
     and e.is_deleted = false
     and e.entry_date >= p_from
     and e.entry_date <= p_to
     and exists (
       select 1
         from entry_line dl
         join accounts a on a.id = dl.account_id
        where dl.entry_id = e.id
          and dl.debit > 0
          and a.type = 'xarajat'
     );
$$;

revoke all on function hodim_oy_jami(uuid, date, date) from public, anon;
grant execute on function hodim_oy_jami(uuid, date, date) to authenticated;

comment on function hodim_oy_jami(uuid, date, date) is
  'Kassadan davr ichida chiqqan xarajat jami (Kt yig''indisi, qarshi tomoni type=xarajat).';
