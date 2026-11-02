#!/usr/bin/env bash
# =====================================================================
# N8N_AYLANMA_EXECUTE_ONCE.sh — 2026-11-02 — «Aros Provodka - Aylanma Snapshot» (o3BZP8uYatGkRu8b)
#
# SABAB (exec 1499575, 02.11 03:00): «To'liq emas — transfers: xato — K3b/K4: manba.transfers=xato».
# Zanjir: Profit Prep (53 qator) → Get Profit WH (53) → Get Tr OnWay → Get Tr Created → Get Ord Created → Get Ord Send
# → Get Cachiers. Bu 5 node GLOBAL so'rov (URL $json ga bog'liq emas), lekin kiruvchi 53 qator uchun 53 MARTA ishlaydi —
# har kecha 5 × 53 = 265 ta bir xil Aros so'rovi. Build Payload `results()` faqat `.first()` ni o'qiydi: birinchi so'rov
# 60 s timeout bo'lsa (02.11: «timeout of 60000ms exceeded», qolgan 52 tasi muvaffaqiyatli!) bo'lim «xato» bo'ladi.
# 27.10 da ham shu («transfers xato» bir marta).
#
# NIMA O'ZGARADI (5 node, kod/ulanish tegilmaydi):
#   * executeOnce = true (bitta so'rov; keyingi node ham 1 qator oladi — Kassa IDs/PI Sahifalar $('…').first() bilan o'qiydi, ta'sir yo'q);
#   * retryOnFail = true, maxTries 3, waitBetweenTries 5000 ms (timeout bo'lsa qayta uriniladi, keyin continueRegularOutput);
#   * options.timeout 60000 → 120000.
#   Build Payload o'zgarmaydi. Aros yuklamasi: 265 → 5 so'rov.
#
#   ssh root@37.27.15.184 'bash -s' < /Users/s1mple/Projects/pravodka/N8N_AYLANMA_EXECUTE_ONCE.sh
#   ssh root@37.27.15.184 'bash -s -- --rollback' < ...            (oxirgi zaxiradan qaytarish)
#   ssh root@37.27.15.184 'bash -s -- --rollback /root/n8n-backups/<fayl>.json' < ...
# Keyin n8n UI: «Aros Provodka - Aylanma Snapshot» → Publish → «Qo'lda ishga tushirish» (bugungi snapshot K3b/K4 bilan qayta).
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
TARGETS = ["Get Tr OnWay", "Get Tr Created", "Get Ord Created", "Get Ord Send", "Get Cachiers"]
for t in TARGETS:
    assert t in by, "node yo'q: " + t
    assert by[t]["type"] == "n8n-nodes-base.httpRequest", t + ": httpRequest emas"
    url = str(by[t]["parameters"].get("url", ""))
    assert "$json" not in url, t + ": URL $json ga bog'liq — executeOnce xavfli"
# zanjir tekshiruvi: Get Profit WH -> Get Tr OnWay (sabab shu)
assert any(x["node"] == "Get Tr OnWay" for outs in conn.get("Get Profit WH", {}).get("main", []) for x in outs), \
    "ulanish o'zgargan: Get Profit WH -> Get Tr OnWay topilmadi"

changed = False
for t in TARGETS:
    n = by[t]
    if n.get("executeOnce") is not True:
        n["executeOnce"] = True; changed = True
    if n.get("retryOnFail") is not True or n.get("maxTries") != 3 or n.get("waitBetweenTries") != 5000:
        n["retryOnFail"] = True; n["maxTries"] = 3; n["waitBetweenTries"] = 5000; changed = True
    opts = n["parameters"].setdefault("options", {})
    if opts.get("timeout") != 120000:
        opts["timeout"] = 120000; changed = True
    n.setdefault("onError", "continueRegularOutput")

if not changed:
    print("allaqachon qo'llangan (o'zgarish yo'q)")
    sys.exit(3)

# ---- verify ----
names = [n["name"] for n in nodes]
assert len(names) == len(set(names)), "node nomlari takrorlanadi"
for src, v in conn.items():
    assert src in names, "connections: manba node yo'q: " + src
    for outs in v.get("main", []):
        for x in outs:
            assert x["node"] in names, "connections: nishon node yo'q: " + x["node"]
for t in TARGETS:
    n = by[t]
    assert n["executeOnce"] is True and n["retryOnFail"] is True and n["parameters"]["options"]["timeout"] == 120000
json.dump(nodes, open(os.environ["AYL_NODES_OUT"], "w"), ensure_ascii=False)
json.dump(conn, open(os.environ["AYL_CONN_OUT"], "w"), ensure_ascii=False)
print("patch tayyor: 5 node executeOnce + retry 3x5s + timeout 120s (" + ", ".join(TARGETS) + ")")
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
select "versionId", id, 'Asilbek (global nodelar executeOnce + retry 2026-11-02)', now(), now(), nodes, connections
  from workflow_entity where id = 'o3BZP8uYatGkRu8b';
commit;
select "versionId" as yangi_versiya, "activeVersionId" as faol_versiya from workflow_entity where id = 'o3BZP8uYatGkRu8b';
SQLEOF
docker cp /tmp/ayl_upd.sql n8n-postgres:/tmp/ayl_upd.sql
$PG -f /tmp/ayl_upd.sql
echo "TAYYOR — n8n UI da «Aros Provodka - Aylanma Snapshot» → Publish → «Qo'lda ishga tushirish» (bugungi snapshot transferlar bilan qayta hisoblanadi)."
