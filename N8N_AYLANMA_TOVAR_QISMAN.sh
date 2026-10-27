#!/usr/bin/env bash
# =====================================================================
# N8N_AYLANMA_TOVAR_QISMAN.sh — 2026-10-27 — «Aros Provodka - Aylanma Snapshot» (o3BZP8uYatGkRu8b)
# V2 (`--wh-param warehouse`) QO'LLANGANDAN KEYIN ishlatiladi.
#
# SABAB (exec 1444708, 27.10 03:00): per-ombor profit-summary so'rovlarining 16 tasi Aros'da 60 s ichida javob
# bermadi («timeout of 60000ms exceeded», AxiosError) — `total_stock_value yoq`. Build Payload «hammasi yoki hech
# biri» qoidasi bilan (`whBad.length === 0`) umumiy javobga qaytdi → [1] tovar faqat «Barcha omborlar (umumiy)»
# bitta qator (17.10 dan beri har kuni shunday), filial kesimi yo'q. Muvaffaqiyatli 24 ombor yig'indisi umumiy
# bilan AYNAN teng edi (2 481 591.09 vs 2 481 591.10) — ya'ni ma'lumot to'g'ri, faqat tashlab yuborilgan.
#
# NIMA O'ZGARADI:
#   * Get Profit WH / Get Profit Foyda — timeout 60 s → 150 s, batch 2 / 1500 ms (Aros'ga yumshoqroq).
#   * Build Payload — QISMAN per-ombor: javobsiz omborlar o'tkaziladi (ogohlantirish bilan), agar muvaffaqiyatli
#     ODDIY omborlar tovar yig'indisi umumiy `total_stock_value` ga ±1% mos kelsa per-ombor SAQLANADI;
#     brak omborlar yig'indisi umumiy `total_broken_value` dan farq qilsa farq «Brak (javobsiz omborlar, umumiy
#     farq)» sintetik qatori (id -1) bilan to'ldiriladi — jami o'zgarmaydi. Mos kelmasa — eskicha umumiy javob.
#     «Javob umumiy bilan AYNAN bir xil» (filtr ishlamayapti) himoyasi O'ZGARMAGAN.
#   * Foyda Payload TEGILMAYDI (u allaqachon xato omborlarni o'tkazib, qolganini yozadi).
#
#   ssh root@37.27.15.184 'bash -s' < /Users/s1mple/Projects/pravodka/N8N_AYLANMA_TOVAR_QISMAN.sh
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
for need in ("Profit Prep", "Get Profit WH", "Get Profit Foyda", "Build Payload", "Foyda Payload"):
    assert need in by, "V1/V2 patch qo'llanmagan (node yo'q: %s)" % need
assert "var WH_PARAM = 'warehouse'; // WH_PARAM_CFG" in by["Profit Prep"]["parameters"]["jsCode"], \
    "WH_PARAM 'warehouse' yoqilmagan — avval N8N_AYLANMA_PROFIT_API_V2.sh --wh-param warehouse"

changed = False

# ---- 1. HTTP node'lar: timeout + batching ----
for nm in ("Get Profit WH", "Get Profit Foyda"):
    p = by[nm]["parameters"]
    opt = p.setdefault("options", {})
    new_opt = dict(opt)
    new_opt["timeout"] = 150000
    new_opt["batching"] = {"batch": {"batchSize": 2, "batchInterval": 1500}}
    if new_opt != opt:
        p["options"] = new_opt
        changed = True

# ---- 2. Build Payload: qisman per-ombor ----
bp = by["Build Payload"]["parameters"]["jsCode"]
OLD = """var perWh = useWh && pJami && whBad.length === 0 && whOk > 0;
if (useWh && !perWh) {
  profitOgoh.push('profit_api: per-ombor ishlamadi (' + whBad.length + ' xato' + (whBad.length ? ': ' + whBad.slice(0, 3).join(' | ') : '') + ') — umumiy javob ishlatildi');
}
if (perWh) {
  farq('tovar (total_stock_value)', sumNorm, num(pJami.total_stock_value));
  farq('brak (total_broken_value)', sumBrk, num(pJami.total_broken_value));
  farq('foyda (total_profit)', sumProfit, num(pJami.total_profit));
} else if (pJami) {"""
NEW = """// 2026-10-27 QISMAN per-ombor (N8N_AYLANMA_TOVAR_QISMAN.sh): javobsiz (timeout) omborlar o'tkaziladi —
// muvaffaqiyatli ODDIY omborlar yig'indisi umumiy total_stock_value ga ±1% mos kelsa per-ombor saqlanadi,
// brak farqi sintetik qator bilan to'ldiriladi (jami o'zgarmaydi). Mos kelmasa — eskicha umumiy javob.
var jamiSt = pJami ? num(pJami.total_stock_value) : 0, jamiBr = pJami ? num(pJami.total_broken_value) : 0;
var stMos = !!pJami && whOk > 0 && Math.abs(sumNorm - jamiSt) <= Math.max(Math.abs(jamiSt) * 0.01, 1);
var perWh = useWh && !!pJami && whOk > 0 && (whBad.length === 0 || stMos);
if (useWh && whBad.length) {
  profitOgoh.push('profit_api: ' + whBad.length + ' ombor javobsiz (' + whBad.slice(0, 3).join(' | ') + ')'
    + (perWh ? ' — tovar yig\\'indisi umumiyga mos, per-ombor saqlandi' : ' — umumiy javob ishlatildi'));
}
if (useWh && !perWh && !whBad.length) profitOgoh.push('profit_api: per-ombor ishlamadi — umumiy javob ishlatildi');
if (perWh) {
  farq('tovar (total_stock_value)', sumNorm, jamiSt);
  var brFarq = r2(jamiBr - sumBrk);
  if (whBad.length && Math.abs(brFarq) > 1) {
    omborlar.push({ id: -1, nom: 'Brak (javobsiz omborlar, umumiy farq)', is_broken: true, is_active: true, usd: brFarq, soni: null, tr_yolda_uzs: null, broken_id: null });
    sumBrk += brFarq;
  }
  farq('brak (total_broken_value)', sumBrk, jamiBr);
  farq('foyda (total_profit)', sumProfit, num(pJami.total_profit));
} else if (pJami) {"""
if NEW in bp:
    pass
else:
    assert bp.count(OLD) == 1, "Build Payload: V2 per-ombor bloki topilmadi (%d)" % bp.count(OLD)
    bp = bp.replace(OLD, NEW)
    by["Build Payload"]["parameters"]["jsCode"] = bp
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
code = by["Build Payload"]["parameters"]["jsCode"]
assert code.count("{") == code.count("}"), "Build Payload: qavslar balansi buzildi"
assert "whBad.length === 0 || stMos" in code
json.dump(nodes, open(os.environ["AYL_NODES_OUT"], "w"), ensure_ascii=False)
json.dump(conn, open(os.environ["AYL_CONN_OUT"], "w"), ensure_ascii=False)
print("patch tayyor: Get Profit WH/Foyda timeout 150 s + batch 2/1500ms; Build Payload qisman per-ombor")
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
select "versionId", id, 'Asilbek (tovar qisman per-ombor 2026-10-27)', now(), now(), nodes, connections
  from workflow_entity where id = 'o3BZP8uYatGkRu8b';
commit;
select "versionId" as yangi_versiya, "activeVersionId" as faol_versiya from workflow_entity where id = 'o3BZP8uYatGkRu8b';
SQLEOF
docker cp /tmp/ayl_upd.sql n8n-postgres:/tmp/ayl_upd.sql
$PG -f /tmp/ayl_upd.sql
echo "TAYYOR — n8n UI da «Aros Provodka - Aylanma Snapshot» ni ochib Publish bosing, keyin «Qolda ishga tushirish» (bugungi snapshot qayta hisoblanadi)."
