#!/usr/bin/env bash
# =====================================================================
# N8N_CACHE_BUILDER_STOCK_API.sh — 2026-11-07 — «Aros Market - Cache Builder» (xgfB2F52mXZ5tJJk)
# Ombor summasi (ombor_summa_usd) manbasi: Metabase karta → Aros profit-summary API.
#
# MUAMMO: Metabase stock kartasi (4f729857) javob bermayapti, Build Cache `fallback_cache` ga tushadi —
#   «Get Last Ombor PG» esa cache_filial + history bo'yicha TARIXIY MAX qiymatni beradi (eskirgan, ortiqcha).
#   07.11: barcha 34 filial fallback_cache; C8-Do'kon 127 724 $ (haqiqiy ~79 900 $), jami 2.75 mlrd so'm
#   ortiqcha. Pravodka «Tovar Sync» shu keshdan o'qib daftar 29xx ni shunga tenglaydi → Balans tovar noto'g'ri.
#
# YECHIM: «Get Metabase Stock» node'i → «Get Stock API»: GET api.aros.uz/api/admin/v2/report/profit-summary/
#   ?start_date=bugun&end_date=bugun&warehouse={api_warehouse_id} (AROS Basic Auth — «Get Debtors» bilan bir
#   xil kredensial). Javob: total_stock_value (USD, joriy qoldiq, sanaga qaramaydi), total_broken_value.
#   Build Cache: ombor_summa_usd = total_stock_value, ombor_source='profit_api', yangi ombor_brak_usd;
#   API bo'lmasa eski fallback_cache (faqat shunda). ombor_mahsulot_soni API'da yo'q — oxirgi keshdan.
#   Ulanishlar saqlanadi (node nomi almashtiriladi). Boshqa node'larga tegilmaydi.
#
#   ssh root@37.27.15.184 'bash -s' < /Users/s1mple/Projects/pravodka/N8N_CACHE_BUILDER_STOCK_API.sh
#   ssh root@37.27.15.184 'bash -s -- --rollback' < ...        (oxirgi zaxiradan qaytarish)
# Keyin n8n UI: «Aros Market - Cache Builder» → Publish; bir soatdan keyin cache_filial.ombor_source='profit_api'
#   bo'lishi kerak; Pravodka «Tovar Sync» (har soat) daftarni avtomatik to'g'rilaydi (kirim/COGS yozuvi).
# =====================================================================
set -euo pipefail
WF=xgfB2F52mXZ5tJJk
PG="docker exec n8n-postgres psql -U n8n -d n8n"
MODE=apply
RB_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rollback) MODE=rollback; shift; RB_FILE="${1:-}"; [ -n "$RB_FILE" ] && shift; continue ;;
    *) echo "noma'lum argument: $1"; exit 2 ;;
  esac
done

mkdir -p /root/n8n-backups
if [ "$MODE" = "rollback" ]; then
  [ -n "$RB_FILE" ] || RB_FILE=$(ls -t /root/n8n-backups/${WF}_*.json | head -1)
  [ -f "$RB_FILE" ] || { echo "zaxira topilmadi: $RB_FILE"; exit 1; }
  echo "qaytarish: $RB_FILE"
  python3 - "$RB_FILE" <<'PYEOF'
import json, sys
w = json.load(open(sys.argv[1]))
json.dump(w["nodes"], open("/tmp/cb_nodes_new.json", "w"), ensure_ascii=False)
json.dump(w["connections"], open("/tmp/cb_conn_new.json", "w"), ensure_ascii=False)
print("zaxira o'qildi: node", len(w["nodes"]))
PYEOF
else
  $PG -Atc "select row_to_json(w) from workflow_entity w where id='$WF'" > /root/n8n-backups/${WF}_$(date +%Y%m%d_%H%M%S).json
  echo "zaxira: $(ls -t /root/n8n-backups/${WF}_*.json | head -1)"
  $PG -Atc "select nodes::text from workflow_entity where id='$WF'" > /tmp/cb_nodes.json
  $PG -Atc "select connections::text from workflow_entity where id='$WF'" > /tmp/cb_conn.json
  set +e
  CB_NODES=/tmp/cb_nodes.json CB_CONN=/tmp/cb_conn.json \
  CB_NODES_OUT=/tmp/cb_nodes_new.json CB_CONN_OUT=/tmp/cb_conn_new.json python3 - <<'PYEOF'
import json, os, sys

nodes = json.load(open(os.environ["CB_NODES"]))
conn  = json.load(open(os.environ["CB_CONN"]))
OLD, NEW = "Get Metabase Stock", "Get Stock API"
by = {n["name"]: n for n in nodes}
if NEW in by and OLD not in by:
    print("allaqachon patch qilingan (Get Stock API bor)"); sys.exit(3)
for req in (OLD, "Get Debtors", "Build Cache", "Loop Over Filials"):
    if req not in by:
        print("node topilmadi:", req); sys.exit(1)

# 1) HTTP node: Metabase -> Aros profit-summary (per filial)
st = by[OLD]
deb = by["Get Debtors"]
st["name"] = NEW
st["parameters"] = {
    "url": "=https://api.aros.uz/api/admin/v2/report/profit-summary/?start_date={{new Date(new Date().getTime()+5*60*60*1000).toISOString().split('T')[0]}}&end_date={{new Date(new Date().getTime()+5*60*60*1000).toISOString().split('T')[0]}}&warehouse={{$('Loop Over Filials').item.json.api_warehouse_id}}",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpBasicAuth",
    "options": {"response": {"response": {"neverError": True}}, "timeout": 90000},
}
st["credentials"] = json.loads(json.dumps(deb.get("credentials", {})))
st["onError"] = "continueRegularOutput"
if not st["credentials"]:
    print("Get Debtors kredensiali topilmadi"); sys.exit(1)

# 2) ulanishlar: nom almashuvi
if OLD in conn:
    conn[NEW] = conn.pop(OLD)
for k, v in conn.items():
    for out in v.get("main", []):
        for c in out or []:
            if c.get("node") == OLD:
                c["node"] = NEW

# 3) Build Cache: ombor bloki
bc = by["Build Cache"]
code = bc["parameters"]["jsCode"]
a = code.index("let omborSummaUsd = 0;")
b_marker = "const whContacts = {};"
b = code.index(b_marker, a)
new_block = """let omborSummaUsd = 0;
let omborMahsulotSoni = 0;
let omborBrakUsd = 0;
let omborSource = 'profit_api';
let apiOk = false;
// 2026-11-07: Metabase stock kartasi ishlamay qolgan edi (fallback_cache = tarixiy MAX, eskirgan).
// Manba endi Aros profit-summary API: total_stock_value (USD, joriy qoldiq) — Pravodka Aylanma Snapshot bilan bir xil.
try {
  const st = safeFirst('Get Stock API', {});
  if (st && st.total_stock_value !== undefined && st.total_stock_value !== null) {
    apiOk = true;
    omborSummaUsd = Math.round((parseFloat(st.total_stock_value) || 0) * 100) / 100;
    omborBrakUsd = Math.round((parseFloat(st.total_broken_value) || 0) * 100) / 100;
  }
} catch(e) { apiOk = false; }
try {
  const omborRows = $('Get Last Ombor PG').all();
  for (const r of omborRows) {
    if (String(r.json.warehouse_id) === String(warehouseId)) {
      const fbUsd = parseFloat(r.json.ombor_usd) || 0;
      const fbSoni = parseInt(r.json.ombor_soni) || 0;
      omborMahsulotSoni = fbSoni;               // API mahsulot sonini bermaydi — oxirgi keshdan
      if (!apiOk && fbUsd > 0) { omborSummaUsd = fbUsd; omborSource = 'fallback_cache'; }
      break;
    }
  }
} catch(e) {}

"""
code = code[:a] + new_block + code[b:]
old_out = "  ombor_source: omborSource,\n"
if code.count(old_out) != 1:
    print("Build Cache chiqish qatori topilmadi"); sys.exit(1)
code = code.replace(old_out, "  ombor_source: omborSource,\n  ombor_brak_usd: omborBrakUsd,\n")
if "safeFirst" not in code.split("let omborSummaUsd")[0]:
    print("safeFirst yordamchisi topilmadi"); sys.exit(1)
bc["parameters"]["jsCode"] = code

json.dump(nodes, open(os.environ["CB_NODES_OUT"], "w"), ensure_ascii=False)
json.dump(conn,  open(os.environ["CB_CONN_OUT"],  "w"), ensure_ascii=False)
print("patch tayyor: node", len(nodes))
PYEOF
  RC=$?
  set -e
  if [ "$RC" = "3" ]; then echo "O'zgarish yo'q — workflow'ga tegilmadi."; exit 0
  elif [ "$RC" != "0" ]; then echo "XATO: patch bajarilmadi (kod $RC) — workflow'ga tegilmadi."; exit "$RC"; fi
fi

docker cp /tmp/cb_nodes_new.json n8n-postgres:/tmp/cb_nodes_new.json
docker cp /tmp/cb_conn_new.json n8n-postgres:/tmp/cb_conn_new.json
cat > /tmp/cb_upd.sql <<'SQLEOF'
\set nodes `cat /tmp/cb_nodes_new.json`
\set conn `cat /tmp/cb_conn_new.json`
begin;
update workflow_entity
   set nodes = :'nodes'::json, connections = :'conn'::json, "versionId" = gen_random_uuid(), "updatedAt" = now()
 where id = 'xgfB2F52mXZ5tJJk';
insert into workflow_history ("versionId","workflowId",authors,"createdAt","updatedAt",nodes,connections)
select "versionId", id, 'Asilbek (ombor summasi profit-summary API 2026-11-07)', now(), now(), nodes, connections
  from workflow_entity where id = 'xgfB2F52mXZ5tJJk';
commit;
select "versionId" as yangi_versiya, "activeVersionId" as faol_versiya from workflow_entity where id = 'xgfB2F52mXZ5tJJk';
SQLEOF
docker cp /tmp/cb_upd.sql n8n-postgres:/tmp/cb_upd.sql
$PG -f /tmp/cb_upd.sql
echo "TAYYOR — n8n UI: «Aros Market - Cache Builder» → Publish. Tekshiruv (1 soatdan keyin):"
echo "  docker exec n8n-postgres psql -U n8n -d aros -Atc \"select warehouse_id, data->>'ombor_source', round((data->>'ombor_summa_usd')::numeric) from cache_filial order by 1\""
