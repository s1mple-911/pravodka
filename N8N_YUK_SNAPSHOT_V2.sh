#!/usr/bin/env bash
# =====================================================================
# N8N_YUK_SNAPSHOT_V2.sh — 2026-10-27 — «Aros Provodka - Yuk Snapshot Sync» (CBRqq1bF6e2RcC6Q) → V2 (TO'LIQ KESH)
#
# Nega: sahifalar (yuklar, professional «Tovar tannarxi») har ochilishda n8n→Aros'ga borardi; Aros 1 sahifa = 500 yuk
# chegarasi keng oynada ENG ESKI yuklarni jimgina yutardi (90 kunlik soatlik sync ham ~450 yuk — chegaraga yaqin).
# V2:
#   * Oraliq  — oynani ≤20 KUNLIK BO'LAKLARGA bo'ladi (30 kunda ~155 yuk kuzatilgan; 20 kun ≈ 100, 500 chegarasidan 5x pastda;
#                har bo'lak alohida Aros so'rovi, baribir 500 ga to'lsa XATO — yo'qotish yo'q)
#   * 2 trigger: «Har Soat» (oxirgi 90 kun) + YANGI webhook `aros-provodka-yuk-refresh` (GET):
#         ?days=7                      — oxirgi 7 kun (sahifadagi «Aros'dan yangilash» tugmasi, default)
#         ?date_from=2024-01-01&date_to=2024-12-31&key=KALIT — BIR MARTALIK BACKFILL, YIL-YIL (400 kundan katta oraliq FAQAT
#                kalit bilan; kalit skript ishga tushganda yaratilib `Oraliq` kodiga yoziladi va ekranga chiqadi; eng ko'pi 1100 kun)
#     Javob: sync_aros_yuk_snapshot natijasi {ok, korildi, yozildi, yangilandi, ochirildi, …}
#   * Payload — yangi maydonlar ham ketadi: ombor_id, yetkazuvchi_tel, delivery_status, post_at, sana_vaqt
#     (PROVODKA_YUK_KESH.sql RPC'ni shu maydonlarga o'rgatadi — AVVAL u RUN bo'lsin, aks holda maydonlar e'tiborsiz qoladi,
#     sync baribir ishlaydi).
#   * «Aros Yuklar» HTTP: batch 2 / 1500 ms (n8n «Items per Batch = 1» abadiy osiladi — CLAUDE.md 2026-09-07).
# TARTIB: 1) PROVODKA_YUK_KESH.sql RUN  2) shu skript  3) n8n UI → workflow → Publish  4) backfill (pastda)  5) sahifani sinash
#
#   ssh root@37.27.15.184 'bash -s' < /Users/s1mple/Projects/pravodka/N8N_YUK_SNAPSHOT_V2.sh
#   ssh root@37.27.15.184 'bash -s -- --rollback' < …      (OXIRGI zaxiradan nodes/connections qaytariladi; keyin Publish)
#   ssh root@37.27.15.184 'bash -s -- --rollback /root/n8n-backups/CBRqq1bF6e2RcC6Q_<vaqt>.json' < …   (aniq zaxira — V1 ga qaytish
#       uchun BIRINCHI zaxirani tanlang: har apply yangi zaxira yozadi)
#
# Backfill (Publish'dan keyin, bir marta, YIL-YIL — har chaqiruv ~18 bo'lak, ~30 s; KALIT skript oxirida chiqadi):
#   curl -s 'https://n8n.arosmarket.com/webhook/aros-provodka-yuk-refresh?date_from=2024-01-01&date_to=2024-12-31&key=KALIT'
#   curl -s 'https://n8n.arosmarket.com/webhook/aros-provodka-yuk-refresh?date_from=2025-01-01&date_to=2025-12-31&key=KALIT'
#   curl -s 'https://n8n.arosmarket.com/webhook/aros-provodka-yuk-refresh?date_from=2026-01-01&key=KALIT'
# Zaxira: /root/n8n-backups/CBRqq1bF6e2RcC6Q_*.json. Qayta ishga tushirish xavfsiz (bir xil JSON → "o'zgarish yo'q").
# =====================================================================
set -euo pipefail
WF=CBRqq1bF6e2RcC6Q
PG="docker exec n8n-postgres psql -U n8n -d n8n"
MODE=apply
RB_FILE=""
[ "${1:-}" = "--rollback" ] && { MODE=rollback; RB_FILE="${2:-}"; }
[ -n "${1:-}" ] && [ "$MODE" = "apply" ] && { echo "noma'lum argument: $1"; exit 2; }
# Refresh webhook kaliti (400 kundan katta backfill uchun). Mavjud Oraliq kodida bo'lsa saqlanadi, bo'lmasa yangi.
NEW_KEY=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')

mkdir -p /root/n8n-backups

if [ "$MODE" = "rollback" ]; then
  B="$RB_FILE"; [ -n "$B" ] || B=$(ls -t /root/n8n-backups/${WF}_*.json 2>/dev/null | head -1)
  [ -n "$B" ] && [ -f "$B" ] || { echo "zaxira topilmadi: ${RB_FILE:-/root/n8n-backups/${WF}_*.json}"; exit 1; }
  echo "qaytarilmoqda: $B"
  python3 - "$B" <<'PYEOF'
import json, sys
w = json.load(open(sys.argv[1]))
json.dump(w["nodes"], open("/tmp/ys_nodes_new.json", "w"), ensure_ascii=False)
json.dump(w["connections"], open("/tmp/ys_conn_new.json", "w"), ensure_ascii=False)
PYEOF
else
  $PG -Atc "select row_to_json(w) from workflow_entity w where id='$WF'" > /root/n8n-backups/${WF}_$(date +%Y%m%d_%H%M%S).json
  echo "zaxira: $(ls -t /root/n8n-backups/${WF}_*.json | head -1)"
  $PG -Atc "select nodes::text from workflow_entity where id='$WF'" > /tmp/ys_nodes.json

  set +e
  YS_NEW_KEY="$NEW_KEY" python3 - <<'PYEOF'
import json, sys, os, re

old = json.load(open("/tmp/ys_nodes.json"))
by = {n["name"]: n for n in old}
# kalit: avvalgi Oraliq kodida bo'lsa o'sha (qayta ishga tushirishda o'zgarmasin)
KEY = os.environ.get("YS_NEW_KEY", "")
if "Oraliq" in by:
    m = re.search(r"var KEY = '([0-9a-f]{32})'; // REFRESH_KEY", by["Oraliq"]["parameters"].get("jsCode", ""))
    if m: KEY = m.group(1)
assert re.fullmatch(r"[0-9a-f]{32}", KEY), "kalit yaratilmadi"

def keep_id(name, default):
    return by[name]["id"] if name in by else default

ORALIQ_JS = r"""// Toshkent (UTC+5). Oynani <=45 KUNLIK bo'laklarga bo'lamiz: Aros product-incomes bitta sahifada eng ko'pi 500 yuk
// beradi (Yuklar API page_size=500) — keng oynada ENG ESKI yuklar jimgina yo'qolardi (2026-10-27).
// Trigger: «Har Soat» -> oxirgi 90 kun; «Webhook Refresh» -> ?days=N (default 7) yoki ?date_from=…&date_to=…
var DAY = 86400000, CHUNK = 20, MAX_DAYS = 1100, MAX_DAYS_KALITSIZ = 400;
var KEY = '__KEY__'; // REFRESH_KEY
function iso(d) { return d.toISOString().slice(0, 10); }
var now = new Date(Date.now() + 5 * 3600 * 1000);
var q = {}, manba = 'soat';
try {
  if ($('Webhook Refresh').isExecuted) { q = ($('Webhook Refresh').first().json || {}).query || {}; manba = 'webhook'; }
} catch (e) { manba = 'soat'; }
var to = iso(now), from = null;
if (/^\d{4}-\d{2}-\d{2}$/.test(String(q.date_to || ''))) { to = String(q.date_to); }
if (to > iso(now)) { to = iso(now); }
if (/^\d{4}-\d{2}-\d{2}$/.test(String(q.date_from || ''))) {
  from = String(q.date_from);
} else {
  var days = Number(q.days) || (manba === 'webhook' ? 7 : 90);
  days = Math.max(1, Math.min(MAX_DAYS, Math.floor(days)));
  from = iso(new Date(Date.parse(to + 'T00:00:00Z') - (days - 1) * DAY));
}
var a = Date.parse(from + 'T00:00:00Z'), b = Date.parse(to + 'T00:00:00Z');
if (!(a <= b)) { throw new Error('date_from (' + from + ') > date_to (' + to + ')'); }
if ((b - a) / DAY > MAX_DAYS) { throw new Error('oraliq ' + MAX_DAYS + ' kundan katta — bo\'lib chaqiring'); }
if (manba === 'webhook' && (b - a) / DAY > MAX_DAYS_KALITSIZ && String(q.key || '') !== KEY) {
  throw new Error('oraliq ' + MAX_DAYS_KALITSIZ + ' kundan katta — faqat key= bilan (backfill)');
}
var out = [], s = a;
while (s <= b) {
  var e = Math.min(b, s + (CHUNK - 1) * DAY);
  out.push({ json: { date_from: iso(new Date(s)), date_to: iso(new Date(e)), oyna_from: from, oyna_to: to, manba: manba } });
  s = e + DAY;
}
return out;
"""

PAYLOAD_JS = r"""// JIMGINA 0 YO'Q (2026-09-09 sabog'i): javob noto'g'ri bo'lsa XATO. Har bo'lak 500 ga to'lsa ham XATO —
// Aros sahifa chegarasi yuklarni yutgan bo'lishi mumkin (hech narsa yozilmaydi, oraliqni kichraytiring).
var items = $input.all();
var o = $('Oraliq').first().json;
var seen = {}, rows = [];
for (var k = 0; k < items.length; k++) {
  var j = items[k].json || {};
  if (j.ok === false || !Array.isArray(j.yuklar)) {
    throw new Error('Aros yuklar webhook javobi noto\'g\'ri: ' + JSON.stringify(j).slice(0, 300));
  }
  if (j.yuklar.length >= 500) {
    throw new Error('Bo\'lak 500 ga to\'ldi (Aros sahifa chegarasi) — yuklar yo\'qolmasin deb TO\'XTATILDI');
  }
  for (var i = 0; i < j.yuklar.length; i++) {
    var y = j.yuklar[i] || {};
    if (y.id === null || y.id === undefined) { continue; }
    var id = Number(y.id);
    if (seen[id]) { continue; }
    seen[id] = true;
    rows.push({
      id: id,
      narx: (y.narx === null || y.narx === undefined || y.narx === '') ? null : Number(y.narx),
      valyuta: y.valyuta || null,
      status: y.status || null,
      ombor: y.ombor || null,
      ombor_id: (y.ombor_id === null || y.ombor_id === undefined || y.ombor_id === '') ? null : Number(y.ombor_id),
      yetkazuvchi: y.yetkazuvchi || null,
      yetkazuvchi_tel: y.yetkazuvchi_tel || null,
      sana: y.sana ? String(y.sana).slice(0, 10) : null,
      sana_vaqt: y.sana || null,
      delivery_status: y.delivery_status || null,
      post_at: y.post_at || null
    });
  }
}
if (rows.length === 0) {
  throw new Error('Aros yuklar: oraliqda birorta yuk kelmadi (' + o.oyna_from + '..' + o.oyna_to + ') — sinxron TO\'XTATILDI');
}
return [{ json: { p_data: { oyna_from: o.oyna_from, oyna_to: o.oyna_to, manba: o.manba, yuklar: rows } } }];
"""

NATIJA_JS = r"""var r = $input.first().json || {};
if (r.ok !== true) {
  throw new Error('sync_aros_yuk_snapshot xato: ' + JSON.stringify(r).slice(0, 300));
}
return [{ json: r }];
"""

nodes = [
  {"id": keep_id("Har Soat", "b6e1d9fe-bc77-4886-ac32-da92c4d1c250"), "name": "Har Soat",
   "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.3, "position": [0, -112],
   "parameters": {"rule": {"interval": [{"field": "hours"}]}}},
  {"id": "7c1e2b5a-9d3f-4e6a-8b21-5f0a3c9d7e41", "name": "Webhook Refresh",
   "type": "n8n-nodes-base.webhook", "typeVersion": 2.1, "position": [0, 112],
   "webhookId": "4f8d2c6b-3a1e-4b7d-9c05-2e6f8a1b3d57",
   "parameters": {"path": "aros-provodka-yuk-refresh", "options": {"allowedOrigins": "*"}, "responseMode": "responseNode"}},
  {"id": keep_id("Oraliq", "d375de9a-dd48-4409-baf9-41547da86dda"), "name": "Oraliq",
   "type": "n8n-nodes-base.code", "typeVersion": 2, "position": [224, 0],
   "parameters": {"jsCode": ORALIQ_JS.replace('__KEY__', KEY)}},
  {"id": keep_id("Aros Yuklar", "c4473370-8ad2-4bbf-a149-6aace2dfa0c0"), "name": "Aros Yuklar",
   "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.4, "position": [448, 0],
   "parameters": {"url": "https://n8n.arosmarket.com/webhook/aros-provodka-yuklar", "sendQuery": True,
                  "queryParameters": {"parameters": [{"name": "date_from", "value": "={{ $json.date_from }}"},
                                                     {"name": "date_to", "value": "={{ $json.date_to }}"}]},
                  "options": {"timeout": 120000, "batching": {"batch": {"batchSize": 2, "batchInterval": 1000}}}}},
  {"id": keep_id("Payload", "03639f5b-777b-414b-9bd5-d745d286f3a3"), "name": "Payload",
   "type": "n8n-nodes-base.code", "typeVersion": 2, "position": [672, 0],
   "parameters": {"jsCode": PAYLOAD_JS}},
  {"id": keep_id("sync_aros_yuk_snapshot", "a8bb65aa-96b2-4b7b-ade2-bdd258759fed"), "name": "sync_aros_yuk_snapshot",
   "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.4, "position": [896, 0],
   "credentials": by["sync_aros_yuk_snapshot"]["credentials"] if "sync_aros_yuk_snapshot" in by else {"supabaseApi": {"id": "EYCiBXDeCAQoumkE", "name": "Supabase account 2"}},
   "parameters": {"method": "POST", "url": "https://kxzerccdpcltmzrxutlo.supabase.co/rest/v1/rpc/sync_aros_yuk_snapshot",
                  "authentication": "predefinedCredentialType", "nodeCredentialType": "supabaseApi",
                  "sendBody": True, "specifyBody": "json", "jsonBody": "={{ JSON.stringify({ p_data: $json.p_data }) }}",
                  "options": {"timeout": 300000}}},
  {"id": keep_id("Natija", "44f23367-2f0a-4fff-973f-9fb2bbebd7f1"), "name": "Natija",
   "type": "n8n-nodes-base.code", "typeVersion": 2, "position": [1120, 0],
   "parameters": {"jsCode": NATIJA_JS}},
  {"id": "9b4d6e2f-1c8a-4f3b-a7d5-6e2c0b9f4a18", "name": "Webhook'mi?",
   "type": "n8n-nodes-base.if", "typeVersion": 2.2, "position": [1344, 0],
   "parameters": {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
                                 "conditions": [{"id": "c-webhook", "leftValue": "={{ $('Webhook Refresh').isExecuted }}",
                                                 "rightValue": "", "operator": {"type": "boolean", "operation": "true", "singleValue": True}}],
                                 "combinator": "and"},
                  "options": {}}},
  {"id": "e3a7c5d1-8f2b-4a6e-b9c4-1d5f7e3a2b86", "name": "Respond Refresh",
   "type": "n8n-nodes-base.respondToWebhook", "typeVersion": 1.5, "position": [1568, -96],
   "parameters": {"respondWith": "json", "responseBody": "={{ JSON.stringify($json) }}",
                  "options": {"responseHeaders": {"entries": [
                      {"name": "Access-Control-Allow-Origin", "value": "*"},
                      {"name": "Access-Control-Allow-Methods", "value": "GET, OPTIONS"},
                      {"name": "Access-Control-Allow-Headers", "value": "Content-Type"}]}}}},
]
conn = {
  "Har Soat":        {"main": [[{"node": "Oraliq", "type": "main", "index": 0}]]},
  "Webhook Refresh": {"main": [[{"node": "Oraliq", "type": "main", "index": 0}]]},
  "Oraliq":          {"main": [[{"node": "Aros Yuklar", "type": "main", "index": 0}]]},
  "Aros Yuklar":     {"main": [[{"node": "Payload", "type": "main", "index": 0}]]},
  "Payload":         {"main": [[{"node": "sync_aros_yuk_snapshot", "type": "main", "index": 0}]]},
  "sync_aros_yuk_snapshot": {"main": [[{"node": "Natija", "type": "main", "index": 0}]]},
  "Natija":          {"main": [[{"node": "Webhook'mi?", "type": "main", "index": 0}]]},
  "Webhook'mi?":     {"main": [[{"node": "Respond Refresh", "type": "main", "index": 0}], []]},
}
if json.dumps(old, sort_keys=True) == json.dumps(nodes, sort_keys=True):
    print("o'zgarish yo'q"); sys.exit(3)
json.dump(nodes, open("/tmp/ys_nodes_new.json", "w"), ensure_ascii=False)
json.dump(conn, open("/tmp/ys_conn_new.json", "w"), ensure_ascii=False)
open("/tmp/ys_key.txt", "w").write(KEY)
print("V2 tayyor: %d node (Webhook Refresh + Webhook'mi? + Respond Refresh yangi)" % len(nodes))
PYEOF
  RC=$?
  set -e
  if [ "$RC" = "3" ]; then echo "O'zgarish yo'q — workflow'ga tegilmadi."; exit 0
  elif [ "$RC" != "0" ]; then echo "XATO: JSON qurilmadi (kod $RC) — workflow'ga tegilmadi."; exit "$RC"; fi
fi

docker cp /tmp/ys_nodes_new.json n8n-postgres:/tmp/ys_nodes_new.json
docker cp /tmp/ys_conn_new.json n8n-postgres:/tmp/ys_conn_new.json
cat > /tmp/ys_upd.sql <<'SQLEOF'
\set nodes `cat /tmp/ys_nodes_new.json`
\set conn `cat /tmp/ys_conn_new.json`
begin;
update workflow_entity
   set nodes = :'nodes'::json, connections = :'conn'::json, "versionId" = gen_random_uuid(), "updatedAt" = now()
 where id = 'CBRqq1bF6e2RcC6Q';
insert into workflow_history ("versionId","workflowId",authors,"createdAt","updatedAt",nodes,connections)
select "versionId", id, 'Asilbek (Yuk Snapshot V2 — to''liq kesh, 2026-10-27)', now(), now(), nodes, connections
  from workflow_entity where id = 'CBRqq1bF6e2RcC6Q';
commit;
select "versionId" as yangi_versiya, "activeVersionId" as faol_versiya from workflow_entity where id = 'CBRqq1bF6e2RcC6Q';
SQLEOF
docker cp /tmp/ys_upd.sql n8n-postgres:/tmp/ys_upd.sql
$PG -f /tmp/ys_upd.sql
echo "TAYYOR — n8n UI: «Aros Provodka - Yuk Snapshot Sync» ni ochib Publish bosing (faol_versiya = yangi_versiya bo'lsin)."
if [ "$MODE" = "apply" ] && [ -f /tmp/ys_key.txt ]; then
  K=$(cat /tmp/ys_key.txt)
  echo "Keyin BACKFILL (bir marta, yil-yil):"
  echo "  curl -s 'https://n8n.arosmarket.com/webhook/aros-provodka-yuk-refresh?date_from=2024-01-01&date_to=2024-12-31&key=$K'"
  echo "  curl -s 'https://n8n.arosmarket.com/webhook/aros-provodka-yuk-refresh?date_from=2025-01-01&date_to=2025-12-31&key=$K'"
  echo "  curl -s 'https://n8n.arosmarket.com/webhook/aros-provodka-yuk-refresh?date_from=2026-01-01&key=$K'"
fi
