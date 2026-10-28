#!/usr/bin/env bash
# =====================================================================
# N8N_AYLANMA_BRAK_JUFT.sh — 2026-10-28 — «Aros Provodka - Aylanma Snapshot» (o3BZP8uYatGkRu8b)
# N8N_AYLANMA_TOVAR_QISMAN.sh + N8N_AYLANMA_NOFAOL_OMBOR.sh dan KEYIN ishlatiladi.
#
# SABAB: «profit-summary brak (total_broken_value): omborlar jami 15.18 <> umumiy 5134.24 (>1%)».
# Aros profit-summary per-ombor javobida BRAK qiymati ODDIY omborning `total_broken_value` maydonida keladi
# (masalan Qarshi Bahor: total_broken_value 1181.23), Brak_* omborning o'z javobi esa 0/0. Build Payload brakni faqat
# `is_broken` omborlar javobidan yig'ardi → T5 «Brak tovar» ≈ 0 (182 160 so'm), umumiy esa ~5 134 USD (~61 mln so'm).
# Avval bu ko'rinmasdi: 16 javobsiz ombor bo'lganida farq sintetik qatorga yozilardi; nofaol omborlar o'tkazilgach
# (whBad=0) sintetik qator ham qo'shilmay, farq ogohlantirishga chiqdi.
#
# NIMA O'ZGARADI (faqat Build Payload, brak bloki):
#   * oddiy omborning `total_broken_value` qiymati uning Brak_ juftiga (`broken_warehouse.id`) yoziladi (juft javobi 0/null bo'lsa);
#   * qolgan farq (umumiy − omborlar) har doim sintetik «Brak (boshqa omborlar, umumiy farq)» qatori (id -1) bilan to'ldiriladi —
#     T5 jami = Aros umumiy `total_broken_value` (ogohlantirish yo'qoladi). Tovar [1] mantiqi TEGILMAYDI.
#
#   ssh root@37.27.15.184 'bash -s' < /Users/s1mple/Projects/pravodka/N8N_AYLANMA_BRAK_JUFT.sh
#   ssh root@37.27.15.184 'bash -s -- --rollback' < ...            (oxirgi zaxiradan qaytarish)
#   ssh root@37.27.15.184 'bash -s -- --rollback /root/n8n-backups/<fayl>.json' < ...
# Keyin n8n UI: «Aros Provodka - Aylanma Snapshot» → Publish → «Qo'lda ishga tushirish». Qayta ishga tushirish xavfsiz.
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
assert "Build Payload" in by, "Build Payload node yo'q"
bp = by["Build Payload"]["parameters"]["jsCode"]
assert "whBad.length === 0 || stMos" in bp, "N8N_AYLANMA_TOVAR_QISMAN.sh qo'llanmagan — avval uni ishga tushiring"

OLD = """  var brFarq = r2(jamiBr - sumBrk);
  if (whBad.length && Math.abs(brFarq) > 1) {
    omborlar.push({ id: -1, nom: 'Brak (javobsiz omborlar, umumiy farq)', is_broken: true, is_active: true, usd: brFarq, soni: null, tr_yolda_uzs: null, broken_id: null });
    sumBrk += brFarq;
  }
"""
NEW = """  // 2026-10-28 (N8N_AYLANMA_BRAK_JUFT.sh): Aros brak qiymatini ODDIY ombor javobida (total_broken_value) beradi,
  // Brak_ ombor javobi 0 — oddiy omborning braki uning Brak_ juftiga (broken_id) yoziladi; qolgan farq sintetik qator.
  for (var bi = 0; bi < omborlar.length; bi++) {
    var ow = omborlar[bi];
    if (ow.is_broken || !(ow.usd_broken > 0) || ow.broken_id == null) continue;
    var bw = whById[ow.broken_id];
    if (!bw || !bw.is_broken || bw.usd > 0) continue;
    bw.usd = r2(ow.usd_broken); bw.brak_manba = 'juft'; sumBrk += bw.usd;
  }
  var brFarq = r2(jamiBr - sumBrk);
  if (Math.abs(brFarq) > 1) {
    omborlar.push({ id: -1, nom: 'Brak (boshqa omborlar, umumiy farq)', is_broken: true, is_active: true, usd: brFarq, soni: null, tr_yolda_uzs: null, broken_id: null });
    sumBrk += brFarq;
  }
"""
if NEW in bp:
    print("allaqachon qo'llangan (o'zgarish yo'q)")
    sys.exit(3)
assert bp.count(OLD) == 1, "Build Payload: brak bloki topilmadi (%d)" % bp.count(OLD)
bp = bp.replace(OLD, NEW)
by["Build Payload"]["parameters"]["jsCode"] = bp

# ---- verify ----
names = [n["name"] for n in nodes]
assert len(names) == len(set(names)), "node nomlari takrorlanadi"
for src, v in conn.items():
    assert src in names, "connections: manba node yo'q: " + src
    for outs in v.get("main", []):
        for t in outs:
            assert t["node"] in names, "connections: nishon node yo'q: " + t["node"]
assert bp.count("{") == bp.count("}"), "Build Payload: qavslar balansi buzildi"
assert "bw.brak_manba = 'juft'" in bp
json.dump(nodes, open(os.environ["AYL_NODES_OUT"], "w"), ensure_ascii=False)
json.dump(conn, open(os.environ["AYL_CONN_OUT"], "w"), ensure_ascii=False)
print("patch tayyor: Build Payload — brak qiymati Brak_ juftga, farq sintetik qator (T5 = umumiy total_broken_value)")
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
select "versionId", id, 'Asilbek (brak juft ombor 2026-10-28)', now(), now(), nodes, connections
  from workflow_entity where id = 'o3BZP8uYatGkRu8b';
commit;
select "versionId" as yangi_versiya, "activeVersionId" as faol_versiya from workflow_entity where id = 'o3BZP8uYatGkRu8b';
SQLEOF
docker cp /tmp/ayl_upd.sql n8n-postgres:/tmp/ayl_upd.sql
$PG -f /tmp/ayl_upd.sql
echo "TAYYOR — n8n UI da «Aros Provodka - Aylanma Snapshot» → Publish → «Qolda ishga tushirish» (bugungi snapshot qayta hisoblanadi, brak ogohlantirishi yo'qoladi)."
