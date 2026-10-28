#!/usr/bin/env bash
# =====================================================================
# N8N_AYLANMA_NOFAOL_OMBOR.sh — 2026-10-28 — «Aros Provodka - Aylanma Snapshot» (o3BZP8uYatGkRu8b)
# N8N_AYLANMA_TOVAR_QISMAN.sh dan KEYIN ishlatiladi.
#
# SABAB (exec 1453904, 28.10 03:00): «profit_api: 16 ombor javobsiz (… total_stock_value yoq)» ogohlantirishi.
# Tekshirildi: bu TIMEOUT EMAS — Aros 16 ombor uchun {"warehouse":["You don't have permission to access this
# warehouse"]} qaytargan va 16 tasi ham NOFAOL (is_active=false, yopilgan filiallar: Sergeli Yarmarka, Aviasozlar,
# Farhod bozori, Buxoro Kitoblar Olami, Chorsu, Kattaqo'rg'on Eski shahar, Buyuk Ipak Yo'li metro, Farg'ona Oltiariq
# + Brak juftlari). Tovari 0 — faol omborlar yig'indisi umumiy bilan aynan mos (2 540 136 USD).
#
# NIMA O'ZGARADI:
#   * Profit Prep — `is_active === false` omborlarga so'rov YUBORILMAYDI (16 so'rov kam, ogohlantirish yo'qoladi).
#   * Build Payload — pErr(): Aros `warehouse: [...]` xatosi (ruxsat yo'q) matni ko'rsatiladi («total_stock_value yoq» o'rniga),
#     kelajakda faol ombor uchun ruxsat yo'q bo'lsa sabab aniq ko'rinadi.
#   Build Payload'dagi omborlar ro'yxati (whR.rows) o'zgarmaydi — nofaol omborlar avvalgidek usd=null qator bo'lib qoladi.
#
#   ssh root@37.27.15.184 'bash -s' < /Users/s1mple/Projects/pravodka/N8N_AYLANMA_NOFAOL_OMBOR.sh
#   ssh root@37.27.15.184 'bash -s -- --rollback' < ...            (oxirgi zaxiradan qaytarish)
#   ssh root@37.27.15.184 'bash -s -- --rollback /root/n8n-backups/<fayl>.json' < ...
# Keyin n8n UI: «Aros Provodka - Aylanma Snapshot» → Publish. Qayta ishga tushirish xavfsiz (o'zgarish yo'q bo'lsa yozilmaydi).
# =====================================================================
set -euo pipefail
WF=o3BZP8uYatGkRu8b
PG="docker exec n8n-postgres psql -U n8n -d n8n"
MODE=apply
RB_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rollback) MODE=rollback; shift; RB_FILE="${1:-}"; [ -n "$RB_FILE" ] && shift; continue ;;
    *) echo "noma'lum argument: $1"; exit 2 ;;
  esac
done

RUNNING=$($PG -Atc "select count(*) from execution_entity where \"workflowId\"='$WF' and status in ('running','new','waiting')")
if [ "$RUNNING" != "0" ]; then echo "XATO: workflow hozir ishlayapti ($RUNNING execution) — tugashini kuting."; exit 1; fi

mkdir -p /root/n8n-backups
if [ "$MODE" = "rollback" ]; then
  [ -n "$RB_FILE" ] || RB_FILE=$(ls -t /root/n8n-backups/${WF}_*.json | head -1)
  [ -f "$RB_FILE" ] || { echo "zaxira topilmadi: $RB_FILE"; exit 1; }
  echo "qaytarish: $RB_FILE"
  python3 - "$RB_FILE" <<'PYEOF'
import json, sys
w = json.load(open(sys.argv[1]))
json.dump(w["nodes"], open("/tmp/ayl_nodes_new.json", "w"), ensure_ascii=False)
json.dump(w["connections"], open("/tmp/ayl_conn_new.json", "w"), ensure_ascii=False)
print("zaxira o'qildi: node", len(w["nodes"]))
PYEOF
else
  $PG -Atc "select row_to_json(w) from workflow_entity w where id='$WF'" > /root/n8n-backups/${WF}_$(date +%Y%m%d_%H%M%S).json
  echo "zaxira: $(ls -t /root/n8n-backups/${WF}_*.json | head -1)"
  $PG -Atc "select nodes::text from workflow_entity where id='$WF'" > /tmp/ayl_nodes.json
  $PG -Atc "select connections::text from workflow_entity where id='$WF'" > /tmp/ayl_conn.json
  set +e
  AYL_NODES=/tmp/ayl_nodes.json AYL_CONN=/tmp/ayl_conn.json \
  AYL_NODES_OUT=/tmp/ayl_nodes_new.json AYL_CONN_OUT=/tmp/ayl_conn_new.json python3 - <<'PYEOF'
import json, os, sys

nodes = json.load(open(os.environ["AYL_NODES"]))
conn = json.load(open(os.environ["AYL_CONN"]))
by = {n["name"]: n for n in nodes}
for need in ("Profit Prep", "Get Profit WH", "Build Payload"):
    assert need in by, "V1/V2 patch qo'llanmagan (node yo'q: %s)" % need
assert "whBad.length === 0 || stMos" in by["Build Payload"]["parameters"]["jsCode"], \
    "N8N_AYLANMA_TOVAR_QISMAN.sh qo'llanmagan — avval uni ishga tushiring"

changed = False

# ---- 1. Profit Prep: nofaol omborlarga so'rov yo'q ----
pp = by["Profit Prep"]["parameters"]["jsCode"]
OLD_PP = "    var w = wh[i]; if (!w || w.id == null) continue;\n"
NEW_PP = ("    var w = wh[i]; if (!w || w.id == null) continue;\n"
          "    if (w.is_active === false) continue; // 2026-10-28: nofaol (yopilgan) ombor — Aros «permission» xatosi qaytaradi, tovari 0\n")
if NEW_PP in pp:
    pass
else:
    assert pp.count(OLD_PP) == 1, "Profit Prep: ombor sikli topilmadi (%d)" % pp.count(OLD_PP)
    by["Profit Prep"]["parameters"]["jsCode"] = pp.replace(OLD_PP, NEW_PP)
    changed = True

# ---- 2. Build Payload: pErr() ruxsat xatosini ko'rsatadi ----
bp = by["Build Payload"]["parameters"]["jsCode"]
OLD_BP = "function pErr(j) { return String((j && (j.detail || j.error || j.message)) || 'total_stock_value yoq').slice(0, 80); }"
NEW_BP = ("function pErr(j) { var wmsg = (j && Array.isArray(j.warehouse)) ? j.warehouse.join(' ') : null; "
          "return String((j && (j.detail || j.error || j.message)) || wmsg || 'total_stock_value yoq').slice(0, 80); }")
if NEW_BP in bp:
    pass
else:
    assert bp.count(OLD_BP) == 1, "Build Payload: pErr topilmadi (%d)" % bp.count(OLD_BP)
    by["Build Payload"]["parameters"]["jsCode"] = bp.replace(OLD_BP, NEW_BP)
    changed = True

if not changed:
    print("allaqachon qo'llangan (o'zgarish yo'q)")
    sys.exit(3)

# ---- verify ----
names = [n["name"] for n in nodes]
assert len(names) == len(set(names)), "node nomlari takrorlanadi"
for src, v in conn.items():
    assert src in names, "connections: manba node yo'q: " + src
    for outs in v.get("main", []):
        for t in outs:
            assert t["node"] in names, "connections: nishon node yo'q: " + t["node"]
for nm in ("Profit Prep", "Build Payload"):
    code = by[nm]["parameters"]["jsCode"]
    assert code.count("{") == code.count("}"), nm + ": qavslar balansi buzildi"
json.dump(nodes, open(os.environ["AYL_NODES_OUT"], "w"), ensure_ascii=False)
json.dump(conn, open(os.environ["AYL_CONN_OUT"], "w"), ensure_ascii=False)
print("patch tayyor: Profit Prep nofaol omborlarni o'tkazadi; Build Payload pErr ruxsat xatosini ko'rsatadi")
PYEOF
  RC=$?
  set -e
  if [ "$RC" = "3" ]; then echo "O'zgarish yo'q — workflow'ga tegilmadi."; exit 0
  elif [ "$RC" != "0" ]; then echo "XATO: patch bajarilmadi (kod $RC) — workflow'ga tegilmadi."; exit "$RC"; fi
fi

docker cp /tmp/ayl_nodes_new.json n8n-postgres:/tmp/ayl_nodes_new.json
docker cp /tmp/ayl_conn_new.json n8n-postgres:/tmp/ayl_conn_new.json
cat > /tmp/ayl_upd.sql <<'SQLEOF'
\set nodes `cat /tmp/ayl_nodes_new.json`
\set conn `cat /tmp/ayl_conn_new.json`
begin;
update workflow_entity
   set nodes = :'nodes'::json, connections = :'conn'::json, "versionId" = gen_random_uuid(), "updatedAt" = now()
 where id = 'o3BZP8uYatGkRu8b';
insert into workflow_history ("versionId","workflowId",authors,"createdAt","updatedAt",nodes,connections)
select "versionId", id, 'Asilbek (nofaol omborlar o''tkazildi 2026-10-28)', now(), now(), nodes, connections
  from workflow_entity where id = 'o3BZP8uYatGkRu8b';
commit;
select "versionId" as yangi_versiya, "activeVersionId" as faol_versiya from workflow_entity where id = 'o3BZP8uYatGkRu8b';
SQLEOF
docker cp /tmp/ayl_upd.sql n8n-postgres:/tmp/ayl_upd.sql
$PG -f /tmp/ayl_upd.sql
echo "TAYYOR — n8n UI da «Aros Provodka - Aylanma Snapshot» ni ochib Publish bosing (keyingi cron 03:00 da ogohlantirishsiz o'tadi; xohlasangiz «Qolda ishga tushirish»)."
