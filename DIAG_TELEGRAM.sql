-- =====================================================================
--  DIAG_TELEGRAM.sql — «Hodim -> Telegram» bog'lash xatosi (text = uuid)
--  FAQAT O'QISH. Hech narsa o'zgartirmaydi. Natija — BITTA qator, bitta
--  JSON ustun: shuni to'liq nusxalab yuboring.
-- =====================================================================
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
