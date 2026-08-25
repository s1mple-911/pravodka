drop policy if exists xm_rasm_oqish on storage.objects;
create policy xm_rasm_oqish on storage.objects
  for select to public
  using (bucket_id = 'xarajat-maydon');

drop policy if exists xm_rasm_yozish on storage.objects;
create policy xm_rasm_yozish on storage.objects
  for insert to authenticated
  with check (bucket_id = 'xarajat-maydon' and public.is_admin());

drop policy if exists xm_rasm_yangilash on storage.objects;
create policy xm_rasm_yangilash on storage.objects
  for update to authenticated
  using (bucket_id = 'xarajat-maydon' and public.is_admin())
  with check (bucket_id = 'xarajat-maydon' and public.is_admin());

drop policy if exists xm_rasm_ochirish on storage.objects;
create policy xm_rasm_ochirish on storage.objects
  for delete to authenticated
  using (bucket_id = 'xarajat-maydon' and public.is_admin());
