#!/usr/bin/env bash
# =====================================================================
# N8N_5KUNLIK_KASSA.sh — 2026-11-03 — «Aros Provodka - 5 Kunlik Savdo» (Prov5KunlikSavdo) ga
# YANGI webhook: GET /webhook/aros-provodka-5kunlik-kassa?date_from=YYYY-MM-DD&date_to=YYYY-MM-DD
#
# Asilbek: 5 kunlikda Fakt oldida «Kassa» ustuni — o'sha kuni YOPILGAN kassalar (filial hujjatlari,
# plan_to_cachier = kassaga topshiriladigan summa), bosilganda qaysi filial yopgan/yopmagan.
# Manba — n8n `aros` bazasi (Aros'ga qayta BORMAYDI): filial_documents (Bugalter Sync, 90 kun) +
# kassa_history_daily (eski kunlar, documents jsonb ichida plan_to_cachier). Kun = stopped_at sanasi (Toshkent).
#
# + REJA (Asilbek, 03.11): 5 kunlik Reja ustuni ham shu keshdan — `filial_plan_half` (yarim oylik filial rejasi,
#   kundalik bot manbasi, plan_source=sheets) Aksessuar+Zapchast; javobda `reja: {"YYYY-MM": {yarim1_uzs, yarim2_uzs, filiallar}}`.
#
# Mavjud 5 ta node NUSXALANADI (typeVersion/sozlamalar mos bo'lsin): Webhook Kassa → Prep Dates Kassa →
# Get Kunlik Kassa (Postgres account 3, aros) → Get Reja (executeOnce) → Build Kassa → Respond Kassa. Eski oqim tegilmaydi.
#
#   ssh root@37.27.15.184 'bash -s' < /Users/s1mple/Projects/pravodka/N8N_5KUNLIK_KASSA.sh
#   ssh root@37.27.15.184 'bash -s -- --rollback' < ...        (oxirgi zaxiradan qaytarish)
# Keyin n8n UI: «Aros Provodka - 5 Kunlik Savdo» → Publish (yangi webhook ro'yxatga tushadi) →
#   curl 'https://n8n.arosmarket.com/webhook/aros-provodka-5kunlik-kassa?date_from=2026-11-01&date_to=2026-11-03'
# =====================================================================
set -euo pipefail
WF=Prov5KunlikSavdo
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
json.dump(w["nodes"], open("/tmp/k5_nodes_new.json", "w"), ensure_ascii=False)
json.dump(w["connections"], open("/tmp/k5_conn_new.json", "w"), ensure_ascii=False)
print("zaxira o'qildi: node", len(w["nodes"]))
PYEOF
else
  $PG -Atc "select row_to_json(w) from workflow_entity w where id='$WF'" > /root/n8n-backups/${WF}_$(date +%Y%m%d_%H%M%S).json
  echo "zaxira: $(ls -t /root/n8n-backups/${WF}_*.json | head -1)"
  $PG -Atc "select nodes::text from workflow_entity where id='$WF'" > /tmp/k5_nodes.json
  $PG -Atc "select connections::text from workflow_entity where id='$WF'" > /tmp/k5_conn.json
  set +e
  K5_NODES=/tmp/k5_nodes.json K5_CONN=/tmp/k5_conn.json \
  K5_NODES_OUT=/tmp/k5_nodes_new.json K5_CONN_OUT=/tmp/k5_conn_new.json python3 - <<'PYEOF'
import json, os, sys, copy, uuid

nodes = json.load(open(os.environ["K5_NODES"]))
conn = json.load(open(os.environ["K5_CONN"]))
by = {n["name"]: n for n in nodes}
for t in ["Webhook 5kunlik", "Prep Dates", "Get Kunlik Savdo", "Build Javob", "Respond 5kunlik"]:
    assert t in by, "node yo'q: " + t
if "Get Reja" in by:
    print("allaqachon qo'llangan (Webhook Kassa + Get Reja bor)")
    sys.exit(3)
UPGRADE = "Webhook Kassa" in by   # 03.11 birinchi versiya (5 node, rejasiz) qo'llangan — faqat Get Reja qo'shiladi

PREP = r'''// Sana oralig'i — 5kunlik savdo bilan bir xil (UTC+5)
const q = $('Webhook Kassa').first().json.query || {};
function iso(d){ return d.toISOString().slice(0,10); }
const now = new Date(new Date().getTime() + 18000000);
let df = String(q.date_from || '');
let dt = String(q.date_to   || '');
if (dt.length !== 10) { dt = iso(now); }
if (df.length !== 10) { df = iso(new Date(now.getTime() - 2592000000)); }
if (df > dt) { const t = df; df = dt; dt = t; }
return [{ json: { date_from: df, date_to: dt, bugun: iso(now) } }];'''

SQL = r'''WITH live AS (
  SELECT fd.stopped_at::date AS sana, fd.cachier_id, fd.cachier_title AS title, fd.cachier_warehouse AS warehouse_id,
         SUM(COALESCE(fd.plan_to_cachier,0))::numeric AS kassa,
         SUM(COALESCE(fd.seller_total,0))::numeric    AS sotuvchi,
         COUNT(*)::int AS doc_count, MAX(fd.stopped_at) AS vaqt
    FROM filial_documents fd
   WHERE fd.status = 'closed' AND fd.stopped_at IS NOT NULL
     AND fd.stopped_at::date BETWEEN $1::date AND $2::date
   GROUP BY 1,2,3,4
), hist AS (
  SELECT h.sana, h.filial_cachier_id AS cachier_id, h.filial_title AS title, h.warehouse_id,
         COALESCE((SELECT SUM(NULLIF(d->>'plan_to_cachier','')::numeric) FROM jsonb_array_elements(COALESCE(h.documents,'[]'::jsonb)) d), h.sotuvchi, 0)::numeric AS kassa,
         COALESCE(h.sotuvchi,0)::numeric AS sotuvchi,
         COALESCE(h.doc_count,0)::int AS doc_count,
         (SELECT MAX(NULLIF(d->>'stopped_at','')::timestamp) FROM jsonb_array_elements(COALESCE(h.documents,'[]'::jsonb)) d) AS vaqt
    FROM kassa_history_daily h
   WHERE h.sana BETWEEN $1::date AND $2::date
     AND NOT EXISTS (SELECT 1 FROM live l WHERE l.sana = h.sana AND l.cachier_id = h.filial_cachier_id)
), yopgan AS (
  SELECT * FROM live UNION ALL SELECT * FROM hist
), kutilgan AS (
  SELECT c.id AS cachier_id, c.title, c.warehouse_id
    FROM cachiers c
   WHERE c.is_kassa = FALSE
     AND (EXISTS (SELECT 1 FROM filial_documents fd WHERE fd.cachier_id = c.id AND fd.status = 'closed'
                     AND fd.stopped_at::date BETWEEN ($1::date - 30) AND $2::date)
       OR EXISTS (SELECT 1 FROM kassa_history_daily h WHERE h.filial_cachier_id = c.id
                     AND h.sana BETWEEN ($1::date - 30) AND $2::date))
)
SELECT 'yopgan' AS tur, y.sana::text AS sana, y.cachier_id, y.title, y.warehouse_id,
       y.kassa, y.sotuvchi, y.doc_count, to_char(y.vaqt, 'YYYY-MM-DD"T"HH24:MI:SS') AS vaqt
  FROM yopgan y
UNION ALL
SELECT 'kutilgan', NULL, k.cachier_id, k.title, k.warehouse_id, NULL, NULL, NULL, NULL
  FROM kutilgan k
ORDER BY 1, 2, 4'''

REJA_SQL = r'''WITH prof AS (
  SELECT DISTINCT ON (warehouse_id) warehouse_id::text AS wid, data->>'profil' AS profil,
         COALESCE(data->>'filial', warehouse_id::text) AS filial
    FROM cache_filial ORDER BY warehouse_id, updated_at DESC
)
SELECT p.yil, p.oy, p.oy_yarim, p.warehouse_id, pr.filial, pr.profil, COALESCE(p.plan,0)::numeric AS plan
  FROM filial_plan_half p
  JOIN prof pr ON pr.wid = p.warehouse_id::text
 WHERE pr.profil IN ('Aksessuar','Zapchast')
   AND make_date(p.yil, p.oy, 1) <= $2::date
   AND (make_date(p.yil, p.oy, 1) + interval '1 month')::date > $1::date
 ORDER BY 1, 2, 3, 6, 5'''

BUILD = r'''// Kunlik yopilgan kassa: sana -> jami + filial kesimi (yopgan / yopmagan). Summalar SO'MDA —
// dollarga o'girish Provodka tomonida (Fakt bilan bir xil kurs). + reja: oy -> yarim oylik Aks+Zap rejasi.
const rows = $('Get Kunlik Kassa').all().map(function(i){ return i.json; }).filter(function(r){ return r && r.tur; });
const rejaRows = $input.all().map(function(i){ return i.json; }).filter(function(r){ return r && r.yil && r.oy; });
const d = $('Prep Dates Kassa').first().json;
const reja = {};
for (let i = 0; i < rejaRows.length; i++) {
  const r = rejaRows[i];
  const ym = String(r.yil) + '-' + (Number(r.oy) < 10 ? '0' : '') + String(Number(r.oy));
  if (!reja[ym]) reja[ym] = { yarim1_uzs: 0, yarim2_uzs: 0, filiallar: [] };
  const plan = Number(r.plan || 0);
  if (Number(r.oy_yarim) === 1) reja[ym].yarim1_uzs += plan; else reja[ym].yarim2_uzs += plan;
  reja[ym].filiallar.push({ warehouse_id: Number(r.warehouse_id), filial: String(r.filial || ''), profil: String(r.profil || ''),
    oy_yarim: Number(r.oy_yarim), plan_uzs: plan });
}
Object.keys(reja).forEach(function(k){ reja[k].yarim1_uzs = Math.round(reja[k].yarim1_uzs); reja[k].yarim2_uzs = Math.round(reja[k].yarim2_uzs); });
const kutilgan = [];
const kutMap = {};
const kun = {};
for (let i = 0; i < rows.length; i++) {
  const r = rows[i];
  if (r.tur === 'kutilgan') {
    const k = { cachier_id: Number(r.cachier_id), title: String(r.title || ''), warehouse_id: r.warehouse_id == null ? null : Number(r.warehouse_id) };
    kutilgan.push(k); kutMap[String(k.cachier_id)] = k;
    continue;
  }
  const sana = String(r.sana || '').slice(0, 10);
  if (!sana) continue;
  if (!kun[sana]) kun[sana] = { sana: sana, kassa_uzs: 0, sotuvchi_uzs: 0, yopgan: [] };
  const kassa = Number(r.kassa || 0), sot = Number(r.sotuvchi || 0);
  kun[sana].kassa_uzs += kassa;
  kun[sana].sotuvchi_uzs += sot;
  kun[sana].yopgan.push({ cachier_id: Number(r.cachier_id), title: String(r.title || ''),
    warehouse_id: r.warehouse_id == null ? null : Number(r.warehouse_id),
    kassa_uzs: kassa, sotuvchi_uzs: sot, doc_count: Number(r.doc_count || 0), vaqt: r.vaqt || null });
}
const kunlar = [];
const detal = {};
Object.keys(kun).sort().forEach(function(s){
  const k = kun[s];
  const yopganIds = {};
  k.yopgan.forEach(function(y){ yopganIds[String(y.cachier_id)] = true; });
  const yopmagan = kutilgan.filter(function(x){ return !yopganIds[String(x.cachier_id)]; });
  kunlar.push({ sana: s, kassa_uzs: Math.round(k.kassa_uzs), sotuvchi_uzs: Math.round(k.sotuvchi_uzs),
    yopgan: k.yopgan.length, kutilgan: kutilgan.length, bugun: s === d.bugun });
  detal[s] = { yopgan: k.yopgan.sort(function(a, b){ return b.kassa_uzs - a.kassa_uzs; }), yopmagan: yopmagan };
});
return [{ json: { ok: true, date_from: d.date_from, date_to: d.date_to, bugun: d.bugun, valyuta: 'UZS',
  kutilgan: kutilgan, kunlar: kunlar, detal: detal, reja: reja, count: kunlar.length } }];'''

def clone(src_name, new_name, dx=0, dy=420):
    n = copy.deepcopy(by[src_name])
    n["name"] = new_name
    n["id"] = str(uuid.uuid4())
    pos = n.get("position") or [0, 0]
    n["position"] = [pos[0] + dx, pos[1] + dy]
    return n

if UPGRADE:
    for t in ["Prep Dates Kassa", "Get Kunlik Kassa", "Build Kassa", "Respond Kassa"]:
        assert t in by, "upgrade: node yo'q: " + t
    get = by["Get Kunlik Kassa"]
    build = by["Build Kassa"]
    yangi = []
else:
    wh = clone("Webhook 5kunlik", "Webhook Kassa")
    wh["parameters"]["path"] = "aros-provodka-5kunlik-kassa"
    wh["webhookId"] = str(uuid.uuid4())
    prep = clone("Prep Dates", "Prep Dates Kassa")
    prep["parameters"]["jsCode"] = PREP
    get = clone("Get Kunlik Savdo", "Get Kunlik Kassa")
    get["parameters"]["query"] = SQL
    build = clone("Build Javob", "Build Kassa", dx=440)
    resp = clone("Respond 5kunlik", "Respond Kassa", dx=440)
    yangi = [wh, prep, get, build, resp]
assert "queryReplacement" in (get["parameters"].get("options") or {}), "Get Kunlik Kassa: queryReplacement yo'q"
assert get.get("credentials", {}).get("postgres", {}).get("name") == "Postgres account 3", "kredit nomi o'zgargan"
get["alwaysOutputData"] = True            # qator chiqmasa ham zanjir uzilmasin (Build Kassa javob bersin)
reja = clone("Get Kunlik Savdo", "Get Reja", dx=220)
reja["parameters"]["query"] = REJA_SQL
reja["parameters"]["options"]["queryReplacement"] = "={{ $('Prep Dates Kassa').first().json.date_from }},{{ $('Prep Dates Kassa').first().json.date_to }}"
reja["executeOnce"] = True                 # kiruvchi N qator uchun BIR MARTA (Aylanma 53× saboqi)
reja["alwaysOutputData"] = True
build["parameters"]["jsCode"] = BUILD      # upgrade'da ham: Get Kunlik Kassa + Get Reja ni birlashtiradigan yangi kod
yangi.append(reja)

for n in yangi:
    assert n["name"] not in by
    nodes.append(n)
conn["Webhook Kassa"]     = {"main": [[{"node": "Prep Dates Kassa", "type": "main", "index": 0}]]}
conn["Prep Dates Kassa"]  = {"main": [[{"node": "Get Kunlik Kassa", "type": "main", "index": 0}]]}
conn["Get Kunlik Kassa"]  = {"main": [[{"node": "Get Reja", "type": "main", "index": 0}]]}
conn["Get Reja"]          = {"main": [[{"node": "Build Kassa", "type": "main", "index": 0}]]}
conn["Build Kassa"]       = {"main": [[{"node": "Respond Kassa", "type": "main", "index": 0}]]}

names = [n["name"] for n in nodes]
assert len(names) == len(set(names)), "node nomlari takrorlanadi"
for src, v in conn.items():
    assert src in names, "connections: manba node yo'q: " + src
    for outs in v.get("main", []):
        for x in outs:
            assert x["node"] in names, "connections: nishon node yo'q: " + x["node"]
json.dump(nodes, open(os.environ["K5_NODES_OUT"], "w"), ensure_ascii=False)
json.dump(conn, open(os.environ["K5_CONN_OUT"], "w"), ensure_ascii=False)
print("patch tayyor: +6 node (Webhook Kassa → Prep Dates Kassa → Get Kunlik Kassa → Get Reja → Build Kassa → Respond Kassa)")
PYEOF
  RC=$?
  set -e
  if [ "$RC" = "3" ]; then echo "O'zgarish yo'q — workflow'ga tegilmadi."; exit 0
  elif [ "$RC" != "0" ]; then echo "XATO: patch bajarilmadi (kod $RC) — workflow'ga tegilmadi."; exit "$RC"; fi
fi

docker cp /tmp/k5_nodes_new.json n8n-postgres:/tmp/k5_nodes_new.json
docker cp /tmp/k5_conn_new.json n8n-postgres:/tmp/k5_conn_new.json
cat > /tmp/k5_upd.sql <<'SQLEOF'
\set nodes `cat /tmp/k5_nodes_new.json`
\set conn `cat /tmp/k5_conn_new.json`
begin;
update workflow_entity
   set nodes = :'nodes'::json, connections = :'conn'::json, "versionId" = gen_random_uuid(), "updatedAt" = now()
 where id = 'Prov5KunlikSavdo';
insert into workflow_history ("versionId","workflowId",authors,"createdAt","updatedAt",nodes,connections)
select "versionId", id, 'Asilbek (5kunlik kassa webhook 2026-11-03)', now(), now(), nodes, connections
  from workflow_entity where id = 'Prov5KunlikSavdo';
commit;
select "versionId" as yangi_versiya, "activeVersionId" as faol_versiya from workflow_entity where id = 'Prov5KunlikSavdo';
SQLEOF
docker cp /tmp/k5_upd.sql n8n-postgres:/tmp/k5_upd.sql
$PG -f /tmp/k5_upd.sql
echo "TAYYOR — n8n UI: «Aros Provodka - 5 Kunlik Savdo» → Publish. Keyin: curl 'https://n8n.arosmarket.com/webhook/aros-provodka-5kunlik-kassa?date_from=2026-11-01&date_to=2026-11-03'"
