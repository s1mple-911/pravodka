#!/usr/bin/env bash
# filial_yop.sh — Aros dashboard/bot (n8n PG `aros`) dan yopilgan filiallarni olib tashlash. 2026-11-06.
# Ishlatish (Asilbek, o'z terminalida):
#   ssh root@37.27.15.184 'bash -s' < filial_yop.sh              # bajarish
#   ssh root@37.27.15.184 'bash -s' < filial_yop.sh -- --rollback # qaytarish (zaxira jadvallaridan)
# Filiallar (Aros warehouse_id): 65 Aviasozlar, 67 Farhod, 69 Nukus Markaziy, 77 Buxoro Kitoblar, 79 Chorsu,
#   81 Kattaqorgon Eski shahar, 83 Buyuk Ipak Yoli, 85 Fargona Oltiariq, 25 Nukus.
# Nima bo'ladi: warehouse_contacts (Cache Builder ro'yxati), cache_filial (Debtors Cache / Calendar / MML / SLA /
#   5 kunlik / Tovar Sync ro'yxati), cache_debtors, filial_location, filial_plan_half — O'CHIRILADI;
#   users (shu filial xodimlari, 8 kishi) — status='rejected', warehouse_id/warehouse_name NULL (bot «Get Branches»
#   users dan filial ro'yxatini quradi — shuning uchun). Arxivlar (cache_filial_history, kassa_history_daily,
#   hodim_kpi_history) TEGILMAYDI. Zaxira: /root/n8n-backups/filial_yop_<vaqt>.sql + *_bak_20261106 jadvallar.
set -euo pipefail
TS=$(date +%Y%m%d_%H%M%S)
WIDS="'65','67','69','77','79','81','83','85','25'"
C=n8n-postgres
mkdir -p /root/n8n-backups

if [ "${1:-}" = "--rollback" ]; then
  cat > /tmp/filial_yop_rb.sql <<'SQL'
begin;
insert into warehouse_contacts select * from warehouse_contacts_bak_20261106 on conflict do nothing;
insert into cache_filial       select * from cache_filial_bak_20261106       on conflict do nothing;
insert into cache_debtors      select * from cache_debtors_bak_20261106      on conflict do nothing;
insert into filial_location    select * from filial_location_bak_20261106    on conflict do nothing;
insert into filial_plan_half   select * from filial_plan_half_bak_20261106   on conflict do nothing;
update users u set status = b.status, warehouse_id = b.warehouse_id, warehouse_name = b.warehouse_name
  from users_bak_20261106 b where b.telegram_id = u.telegram_id;
commit;
SQL
  docker cp /tmp/filial_yop_rb.sql $C:/tmp/filial_yop_rb.sql
  docker exec $C psql -U n8n -d aros -v ON_ERROR_STOP=1 -f /tmp/filial_yop_rb.sql
  echo "ROLLBACK bajarildi"; exit 0
fi

echo "== zaxira (pg_dump) → /root/n8n-backups/filial_yop_$TS.sql"
docker exec $C pg_dump -U n8n -d aros -t warehouse_contacts -t cache_filial -t cache_debtors -t filial_location -t filial_plan_half -t users > /root/n8n-backups/filial_yop_$TS.sql
ls -la /root/n8n-backups/filial_yop_$TS.sql

cat > /tmp/filial_yop.sql <<SQL
begin;
create table if not exists warehouse_contacts_bak_20261106 as select * from warehouse_contacts where false;
create table if not exists cache_filial_bak_20261106       as select * from cache_filial       where false;
create table if not exists cache_debtors_bak_20261106      as select * from cache_debtors      where false;
create table if not exists filial_location_bak_20261106    as select * from filial_location    where false;
create table if not exists filial_plan_half_bak_20261106   as select * from filial_plan_half   where false;
create table if not exists users_bak_20261106              as select * from users              where false;

insert into warehouse_contacts_bak_20261106 select * from warehouse_contacts where warehouse_id::text in ($WIDS);
insert into cache_filial_bak_20261106       select * from cache_filial       where warehouse_id::text in ($WIDS);
insert into cache_debtors_bak_20261106      select * from cache_debtors      where warehouse_id::text in ($WIDS);
insert into filial_location_bak_20261106    select * from filial_location    where warehouse_id::text in ($WIDS);
insert into filial_plan_half_bak_20261106   select * from filial_plan_half   where warehouse_id::text in ($WIDS);
insert into users_bak_20261106              select * from users              where warehouse_id::text in ($WIDS);

delete from warehouse_contacts where warehouse_id::text in ($WIDS);
delete from cache_filial       where warehouse_id::text in ($WIDS);
delete from cache_debtors      where warehouse_id::text in ($WIDS);
delete from filial_location    where warehouse_id::text in ($WIDS);
delete from filial_plan_half   where warehouse_id::text in ($WIDS);
update users set status = 'rejected', warehouse_id = null, warehouse_name = null
 where warehouse_id::text in ($WIDS);
commit;

\\echo === qoldi (0 bo'lishi kerak)
select 'warehouse_contacts', count(*) from warehouse_contacts where warehouse_id::text in ($WIDS)
union all select 'cache_filial', count(*) from cache_filial where warehouse_id::text in ($WIDS)
union all select 'cache_debtors', count(*) from cache_debtors where warehouse_id::text in ($WIDS)
union all select 'users', count(*) from users where warehouse_id::text in ($WIDS);
\\echo === zaxira jadvallari
select 'warehouse_contacts_bak', count(*) from warehouse_contacts_bak_20261106
union all select 'cache_filial_bak', count(*) from cache_filial_bak_20261106
union all select 'users_bak', count(*) from users_bak_20261106;
SQL
docker cp /tmp/filial_yop.sql $C:/tmp/filial_yop.sql
docker exec $C psql -U n8n -d aros -v ON_ERROR_STOP=1 -f /tmp/filial_yop.sql
echo "TAYYOR. Keyingi Cache Builder/Debtors Cache ishlashida bu filiallar uchun so'rov ketmaydi."
