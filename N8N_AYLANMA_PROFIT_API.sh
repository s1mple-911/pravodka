#!/usr/bin/env bash
# ⚠️ V1 — ESKIRGAN/XATOLI: Aros `warehouse_id` ni e'tiborga olmaydi (2026-10-17). Qo'llangan bo'lsa N8N_AYLANMA_PROFIT_API_V2.sh ishlating; yangi o'rnatishda ham avval V1, keyin V2.
# =====================================================================
# N8N_AYLANMA_PROFIT_API.sh — 2026-10-17 — «Aros Provodka - Aylanma Snapshot» (o3BZP8uYatGkRu8b)
# Metabase O'RNIGA Aros yangi API: GET /api/admin/v2/report/profit-summary/ (AROS_API_PROFIT_SUMMARY.md).
# Sabab: Metabase «Profit report» 03.10.2026 dan to'xtagan -> 04.10 dan beri aylanma_foyda ga hech narsa yozilmagan.
# Postgres orqali patch (n8n MCP update_workflow ISHLATILMAYDI). O'zgarishlar:
#   * MB Prep + Get Metabase        -> Profit Prep + Get Profit WH   (kecha: har ombor + bitta umumiy, warehouse_id siz;
#                                      tovar = total_stock_value, brak = total_broken_value, kecha foyda shu javoblardan)
#   * Foyda URL / Get Metabase Foyda / Foyda Payload -> Foyda URL / Get Profit Foyda / Foyda Payload
#                                      (kechadan oldingi 4 kun JAMI + BACKFILL: 03.10 dan har kun JAMI + har ombor)
#   * Build Payload                 -> manba.profit_api (+ eski RPC uchun manba.metabase nusxasi), profit_ogoh
# TARTIB: 1) PROVODKA_AYLANMA_PROFIT_API.sql RUN  2) shu skript  3) n8n UI da Publish  4) «Qolda ishga tushirish» BIR MARTA
#         5) foyda to'lgach:  bash -s -- --backfill-off   (BACKFILL o'chiriladi, yana Publish)
#
# ISHLATISH (Asilbek):
#   ssh root@37.27.15.184 'bash -s' < /Users/s1mple/Projects/pravodka/N8N_AYLANMA_PROFIT_API.sh
#   ssh root@37.27.15.184 'bash -s -- --backfill-off' < /Users/s1mple/Projects/pravodka/N8N_AYLANMA_PROFIT_API.sh
#   (ixtiyoriy: --backfill-on — backfill'ni qayta yoqadi, sana 2026-10-03)
# Zaxira: /root/n8n-backups/o3BZP8uYatGkRu8b_<vaqt>.json. Qayta ishga tushirish xavfsiz (o'zgarish yo'q bo'lsa hech narsa yozilmaydi).
# =====================================================================
set -euo pipefail
WF=o3BZP8uYatGkRu8b
PG="docker exec n8n-postgres psql -U n8n -d n8n"
MODE=apply
for a in "$@"; do
  case "$a" in
    --backfill-off) MODE=off ;;
    --backfill-on)  MODE=on ;;
    *) echo "noma'lum argument: $a (kutilgan: --backfill-off | --backfill-on)"; exit 2 ;;
  esac
done
mkdir -p /root/n8n-backups
$PG -Atc "select row_to_json(w) from workflow_entity w where id='$WF'" > /root/n8n-backups/${WF}_$(date +%Y%m%d_%H%M%S).json
echo "zaxira: $(ls -t /root/n8n-backups/${WF}_*.json | head -1)"
$PG -Atc "select nodes::text from workflow_entity where id='$WF'" > /tmp/ayl_nodes.json
$PG -Atc "select connections::text from workflow_entity where id='$WF'" > /tmp/ayl_conn.json

set +e
AYL_MODE="$MODE" AYL_NODES=/tmp/ayl_nodes.json AYL_CONN=/tmp/ayl_conn.json \
AYL_NODES_OUT=/tmp/ayl_nodes_new.json AYL_CONN_OUT=/tmp/ayl_conn_new.json python3 - <<'PYEOF'
import json, os, re, sys, uuid

MODE = os.environ["AYL_MODE"]
nodes = json.load(open(os.environ["AYL_NODES"]))
conn = json.load(open(os.environ["AYL_CONN"]))
by = {n["name"]: n for n in nodes}
BACKFILL_RE = re.compile(r"var BACKFILL_FROM = (null|'\d{4}-\d{2}-\d{2}'); // BACKFILL_CFG")
BACKFILL_DEFAULT = "2026-10-03"


def save():
    json.dump(nodes, open(os.environ["AYL_NODES_OUT"], "w"), ensure_ascii=False)
    json.dump(conn, open(os.environ["AYL_CONN_OUT"], "w"), ensure_ascii=False)


def verify():
    names = [n["name"] for n in nodes]
    assert len(names) == len(set(names)), "node nomlari takrorlanadi"
    for src, v in conn.items():
        assert src in names, "connections: manba node yo'q: " + src
        for outs in v.get("main", []):
            for t in outs:
                assert t["node"] in names, "connections: nishon node yo'q: " + t["node"]
    # hamma node triggerdan erishiladigan bo'lsin (yetim qolmasin)
    seen, stack = set(), ["08:00 Toshkent", "Qolda ishga tushirish"]
    while stack:
        x = stack.pop()
        if x in seen:
            continue
        seen.add(x)
        for outs in conn.get(x, {}).get("main", []):
            stack.extend(t["node"] for t in outs)
    assert seen == set(names), "yetim node: %s" % sorted(set(names) - seen)
    for gone in ("MB Prep", "Get Metabase", "Get Metabase Foyda"):
        assert gone not in names, gone + " qolib ketdi"


PATCHED = "Get Profit WH" in by

if MODE in ("on", "off"):
    assert PATCHED, "avval patch qilinmagan — oddiy rejimda ishga tushiring (argumentsiz)"
    n = by["Foyda URL"]
    c = n["parameters"]["jsCode"]
    assert len(BACKFILL_RE.findall(c)) == 1, "Foyda URL: BACKFILL_CFG qatori topilmadi"
    val = "null" if MODE == "off" else "'" + BACKFILL_DEFAULT + "'"
    new = BACKFILL_RE.sub("var BACKFILL_FROM = " + val + "; // BACKFILL_CFG", c)
    if new == c:
        print("BACKFILL allaqachon " + MODE)
        sys.exit(3)
    n["parameters"]["jsCode"] = new
    verify()
    save()
    print("BACKFILL " + MODE)
    sys.exit(0)

if PATCHED:
    print("Aylanma allaqachon Aros profit-summary ga o'tkazilgan (o'zgarish yo'q)")
    sys.exit(3)

for need in ("Get Warehouses", "MB Prep", "Get Metabase", "Get Tr OnWay", "Foyda URL",
             "Get Metabase Foyda", "Foyda Payload", "Build Payload"):
    assert need in by, "kutilgan node yo'q: " + need

# ----------------------------------------------------------------------------
PREP_JS = r"""// Aros profit-summary (kecha): har ombor uchun BITTA so'rov (kecha foyda + joriy tovar/brak qoldig'i) + bitta umumiy (warehouse_id siz).
function pad(n) { return n < 10 ? '0' + n : String(n); }
function fmt(d) { return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate()); }
var BASE = 'https://api.aros.uz/api/admin/v2/report/profit-summary/';
var kecha = fmt(new Date(Date.now() + 5 * 3600 * 1000 - 86400000));
var wh = [];
try {
  var r = $('Get Warehouses').first().json || {};
  if (Array.isArray(r.results)) wh = r.results;
} catch (e) { wh = []; }
var q = '?start_date=' + kecha + '&end_date=' + kecha;
var out = [{ json: { kind: 'jami', sana: kecha, wh_id: null, wh_nom: 'JAMI', is_broken: false, url: BASE + q } }];
for (var i = 0; i < wh.length; i++) {
  var w = wh[i]; if (!w || w.id == null) continue;
  out.push({ json: { kind: 'wh', sana: kecha, wh_id: parseInt(w.id), wh_nom: w.name_uz || w.name || ('Ombor ' + w.id),
                     is_broken: w.is_broken === true, url: BASE + q + '&warehouse_id=' + parseInt(w.id) } });
}
return out;"""

FOYDA_URL_JS = r"""// Kunlik foyda — Aros profit-summary. Kecha (JAMI + har ombor) 'Get Profit WH' dan olingan; bu yerda: kechadan oldingi 4 kun JAMI
// (hisobot kechikib tuzalsa keyingi kunlarda o'zi yangilanadi) + BACKFILL bo'lsa har kun uchun JAMI + har ombor.
var BACKFILL_FROM = '2026-10-03'; // BACKFILL_CFG
function pad(n) { return n < 10 ? '0' + n : String(n); }
function fmt(d) { return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate()); }
function addDays(s, n) { return fmt(new Date(new Date(s + 'T00:00:00Z').getTime() + n * 86400000)); }
var BASE = 'https://api.aros.uz/api/admin/v2/report/profit-summary/';
var prep = $('Profit Prep').all();
var kecha = prep[0].json.sana;
var whs = [];
for (var i = 0; i < prep.length; i++) {
  var m = prep[i].json;
  if (m.kind === 'wh' && !m.is_broken) whs.push(m);
}
var jami = {}, withWh = {};
for (var k = 2; k <= 5; k++) jami[addDays(kecha, 1 - k)] = true;
if (BACKFILL_FROM) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(BACKFILL_FROM)) throw new Error('BACKFILL_FROM noto\'g\'ri: ' + BACKFILL_FROM);
  var cur = BACKFILL_FROM, guard = 0;
  while (cur < kecha && guard < 40) { jami[cur] = true; withWh[cur] = true; cur = addDays(cur, 1); guard++; }
  if (cur < kecha) throw new Error('BACKFILL oraligi 40 kundan oshdi: ' + BACKFILL_FROM + ' .. ' + kecha);
}
var out = [];
var days = Object.keys(jami).sort();
for (var d = 0; d < days.length; d++) {
  var s = days[d];
  var q = '?start_date=' + s + '&end_date=' + s;
  out.push({ json: { kind: 'jami', sana: s, wh_id: null, wh_nom: 'JAMI', is_broken: false, url: BASE + q } });
  if (withWh[s]) {
    for (var w = 0; w < whs.length; w++) {
      out.push({ json: { kind: 'wh', sana: s, wh_id: whs[w].wh_id, wh_nom: whs[w].wh_nom, is_broken: false,
                         url: BASE + q + '&warehouse_id=' + whs[w].wh_id } });
    }
  }
}
return out;"""

PAYLOAD_JS = r"""// Aros profit-summary javoblari -> sync_aylanma_foyda payload. Kecha: Profit Prep / Get Profit WH (JAMI + har ombor);
// oldingi kunlar (+ BACKFILL): Foyda URL / Get Profit Foyda. filial = ombor nomi (name_uz), JAMI = warehouse_id siz umumiy javob.
function num(v) { var n = parseFloat(v); return isFinite(n) ? n : 0; }
function has(j) { return !!j && j.total_profit !== undefined && j.total_profit !== null && isFinite(parseFloat(j.total_profit)); }
function errText(j) { return String((j && (j.detail || j.error || j.message)) || 'total_profit yoq').slice(0, 100); }
var src = [];
var pp = $('Profit Prep').all(), pw = $('Get Profit WH').all();
var fu = $('Foyda URL').all(), fr = $input.all();
var xato = [];
if (pw.length !== pp.length) xato.push('Get Profit WH: ' + pw.length + ' javob / ' + pp.length + ' so\'rov');
if (fr.length !== fu.length) xato.push('Get Profit Foyda: ' + fr.length + ' javob / ' + fu.length + ' so\'rov');
for (var i = 0; i < pp.length; i++) src.push({ m: pp[i].json, j: pw[i] ? pw[i].json : null });
for (var f = 0; f < fu.length; f++) src.push({ m: fu[f].json, j: fr[f] ? fr[f].json : null });
var kecha = pp.length ? pp[0].json.sana : null;
var rows = [], bosh = {}, jamiBor = {};
for (var s = 0; s < src.length; s++) {
  var m = src[s].m, j = src[s].j;
  var isJ = (m.kind === 'jami');
  if (!has(j)) { xato.push(m.sana + ' ' + m.wh_nom + ': ' + errText(j)); continue; }
  var o = { sana: m.sana, filial: isJ ? 'JAMI' : m.wh_nom, warehouse_id: isJ ? null : m.wh_id,
            sotilgan: Math.round(num(j.total_sold_quantity)), qaytarilgan: Math.round(num(j.total_return_quantity)),
            kirim_usd: num(j.total_income_price), sotuv_usd: num(j.total_selling_price),
            keshbek_usd: num(j.total_cashback_price), foyda_usd: num(j.total_profit), manba: 'aros_api' };
  var nol = (o.sotilgan === 0 && o.qaytarilgan === 0 && o.kirim_usd === 0 && o.sotuv_usd === 0 && o.foyda_usd === 0);
  if (isJ) {
    // butun kompaniya uchun hamma raqam 0 bo'lishi mumkin emas — kun hali hisoblanmagan, eski ma'lumot ustiga 0 yozilmasin
    if (nol) { bosh[m.sana] = true; xato.push(m.sana + ': JAMI hamma raqam 0 (hali hisoblanmagan) — yozilmadi'); continue; }
    jamiBor[m.sana] = true;
    rows.push(o);
  } else {
    if (m.is_broken || nol) continue;
    rows.push(o);
  }
}
rows = rows.filter(function (o) { return jamiBor[o.sana] && !bosh[o.sana]; });
// JIMGINA 0 YO'Q: kechaning JAMI qatori bo'lmasa (API yiqilgan / javob shakli o'zgargan) — xato
if (!kecha || !jamiBor[kecha]) {
  throw new Error('Aros profit-summary: kecha (' + kecha + ') JAMI kelmadi. ' + xato.slice(0, 8).join(' | '));
}
return [{ json: { rows: rows, soni: rows.length, xato: xato.slice(0, 40) } }];"""

# Build Payload: Metabase bo'limi -> Aros profit-summary
BP_NEW = r"""// ---- 2. Aros profit-summary (kecha): har ombor -> joriy tovar/brak qoldig'i (USD, tannarx); umumiy javob = tekshiruv ----
function r2(v) { return Math.round(v * 100) / 100; }
function pValid(j) { return !!j && j.total_stock_value !== undefined && j.total_stock_value !== null && isFinite(parseFloat(j.total_stock_value)); }
function pErr(j) { return String((j && (j.detail || j.error || j.message)) || 'total_stock_value yoq').slice(0, 80); }
function farq(nom, a, b) {
  if (Math.abs(a - b) > Math.max(Math.abs(b) * 0.01, 1)) profitOgoh.push('profit-summary ' + nom + ': omborlar jami ' + r2(a) + ' <> umumiy ' + r2(b) + ' (>1%)');
}
var profitOgoh = [];
var pPrep = [], pResp = [];
try { pPrep = $('Profit Prep').all(); } catch (e) { pPrep = []; }
try { pResp = $('Get Profit WH').all(); } catch (e) { pResp = []; }
var pJami = null, pOk = 0, pBad = [];
if (pResp.length !== pPrep.length) pBad.push('javoblar soni mos emas: ' + pResp.length + '/' + pPrep.length);
var sumNorm = 0, sumBrk = 0, sumNormBrokenField = 0, sumProfit = 0, sumProfitN = 0;
for (var pi = 0; pi < pPrep.length; pi++) {
  var pm = pPrep[pi].json || {};
  var pj = (pResp[pi] && pResp[pi].json) || null;
  if (pm.kind === 'jami') {
    if (pValid(pj)) pJami = pj; else profitOgoh.push('profit-summary umumiy: ' + pErr(pj));
    continue;
  }
  var tw = whById[pm.wh_id];
  if (!tw) continue;
  if (!pValid(pj)) { pBad.push(tw.nom + ': ' + pErr(pj)); continue; }
  var st = num(pj.total_stock_value), br = num(pj.total_broken_value);
  tw.usd_stock = r2(st); tw.usd_broken = r2(br);
  // brak ombor javobida qiymat qaysi maydonda kelishi noma'lum — kattasi olinadi; oddiy omborda faqat stock
  // (brak omborning o'z so'rovi alohida sanaladi, oddiy ombordagi total_broken_value ikki marta qo'shilmaydi)
  tw.usd = r2(tw.is_broken ? Math.max(st, br) : st);
  tw.soni = null; tw.tr_yolda_uzs = null;
  pOk++;
  if (tw.is_broken) sumBrk += tw.usd; else { sumNorm += tw.usd; sumNormBrokenField += br; }
  if (!tw.is_broken && isFinite(parseFloat(pj.total_profit))) { sumProfit += num(pj.total_profit); sumProfitN++; }
}
if (pOk === 0 && pBad.length === 0) pBad.push('birorta ombor javobi kelmadi');
if (pJami && pBad.length === 0) {
  farq('tovar (total_stock_value)', sumNorm, num(pJami.total_stock_value));
  farq('brak (total_broken_value)', sumBrk, num(pJami.total_broken_value));
  if (profitOgoh.length && sumNormBrokenField > 0) profitOgoh.push('diagnostika: oddiy omborlar total_broken_value yig\'indisi ' + r2(sumNormBrokenField));
  if (isFinite(parseFloat(pJami.total_profit))) farq('foyda (total_profit)', sumProfit, num(pJami.total_profit));
}
if (pBad.length) ogoh.push('profit_api: ' + pBad.length + ' xato — ' + pBad.slice(0, 5).join(' | '));
for (var po = 0; po < profitOgoh.length; po++) ogoh.push(profitOgoh[po]);
manba.profit_api = (pBad.length === 0 && pOk > 0) ? 'ok' : 'xato';
manba.metabase = manba.profit_api; // PROVODKA_AYLANMA_PROFIT_API.sql RUN bo'lmagan eski RPC shu kalitni o'qiydi"""

# ---- Build Payload ----
bp = by["Build Payload"]["parameters"]["jsCode"]
a = bp.find("var mb = safeFirst('Get Metabase', null);")
b_marker = "manba.metabase = mbOk ? 'ok' : 'xato';"
assert bp.count("var mb = safeFirst('Get Metabase', null);") == 1, "Build Payload: Metabase boshlanishi topilmadi"
assert bp.count(b_marker) == 1, "Build Payload: Metabase oxiri topilmadi"
b = bp.find(b_marker) + len(b_marker)
assert a < b
bp = bp[:a] + BP_NEW + bp[b:]
old_ogoh = "  ogoh: ogoh,\n"
assert bp.count(old_ogoh) == 1, "Build Payload: payload.ogoh qatori topilmadi"
bp = bp.replace(old_ogoh, old_ogoh + "  profit_ogoh: profitOgoh,\n")
old_stat = "metabase_qator: omborlar.filter(function (o) { return o.usd !== null; }).length,"
assert bp.count(old_stat) == 1, "Build Payload: stat.metabase_qator topilmadi"
bp = bp.replace(old_stat, "profit_qator: omborlar.filter(function (o) { return o.usd !== null; }).length,")
assert "Get Metabase" not in bp and "mbOk" not in bp
by["Build Payload"]["parameters"]["jsCode"] = bp

# ---- yangi node'lar ----
cred = json.loads(json.dumps(by["Get Warehouses"]["credentials"]))


def http(name, pos, batch):
    return {
        "parameters": {
            "url": "={{ $json.url }}",
            "authentication": "genericCredentialType",
            "genericAuthType": "httpBasicAuth",
            "options": {
                "batching": {"batch": {"batchSize": batch[0], "batchInterval": batch[1]}},
                "response": {"response": {"neverError": True}},
                "timeout": 60000,
            },
        },
        "id": str(uuid.uuid4()), "name": name, "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
        "position": pos, "alwaysOutputData": True, "credentials": cred, "onError": "continueRegularOutput",
    }


def code(name, pos, js):
    return {"parameters": {"jsCode": js}, "id": str(uuid.uuid4()), "name": name,
            "type": "n8n-nodes-base.code", "typeVersion": 2, "position": pos}


# n8n HTTP «Items per Batch = 1» abadiy osiladi (Get Incomes izohi) — shuning uchun 2 / 3 (ketma-ket emas, kichik partiya)
prep = code("Profit Prep", by["MB Prep"]["position"], PREP_JS)
getwh = http("Get Profit WH", by["Get Metabase"]["position"], (2, 500))
getfoy = http("Get Profit Foyda", by["Get Metabase Foyda"]["position"], (3, 300))
by["Foyda URL"]["parameters"]["jsCode"] = FOYDA_URL_JS
by["Foyda Payload"]["parameters"]["jsCode"] = PAYLOAD_JS

new_nodes = []
for n in nodes:
    nm = n["name"]
    if nm == "MB Prep":
        new_nodes.append(prep)
    elif nm == "Get Metabase":
        new_nodes.append(getwh)
    elif nm == "Get Metabase Foyda":
        new_nodes.append(getfoy)
    else:
        new_nodes.append(n)
nodes[:] = new_nodes

# ---- connections ----
ren = {"MB Prep": "Profit Prep", "Get Metabase": "Get Profit WH", "Get Metabase Foyda": "Get Profit Foyda"}
newc = {}
for src, v in conn.items():
    s2 = ren.get(src, src)
    outs = [[dict(t, node=ren.get(t["node"], t["node"])) for t in o] for o in v["main"]]
    newc[s2] = {"main": outs}
conn.clear()
conn.update(newc)
assert conn["Get Warehouses"]["main"][0][0]["node"] == "Profit Prep"
assert conn["Profit Prep"]["main"][0][0]["node"] == "Get Profit WH"
assert conn["Get Profit WH"]["main"][0][0]["node"] == "Get Tr OnWay"
assert conn["Foyda URL"]["main"][0][0]["node"] == "Get Profit Foyda"
assert conn["Get Profit Foyda"]["main"][0][0]["node"] == "Foyda Payload"
verify()
save()
print("patched: Profit Prep, Get Profit WH, Get Profit Foyda, Build Payload, Foyda URL, Foyda Payload (BACKFILL_FROM=" + BACKFILL_DEFAULT + ")")
PYEOF
RC=$?
set -e
if [ "$RC" = "3" ]; then
  echo "O'zgarish yo'q — workflow'ga tegilmadi."
  exit 0
elif [ "$RC" != "0" ]; then
  echo "XATO: patch bajarilmadi (kod $RC) — workflow'ga tegilmadi."
  exit "$RC"
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
select "versionId", id, 'Asilbek (profit-summary API 2026-10-17)', now(), now(), nodes, connections
  from workflow_entity where id = 'o3BZP8uYatGkRu8b';
commit;
select "versionId" as yangi_versiya, "activeVersionId" as faol_versiya from workflow_entity where id = 'o3BZP8uYatGkRu8b';
SQLEOF
docker cp /tmp/ayl_upd.sql n8n-postgres:/tmp/ayl_upd.sql
$PG -f /tmp/ayl_upd.sql
echo "TAYYOR — endi n8n UI da «Aros Provodka - Aylanma Snapshot» ni ochib Publish bosing (faol_versiya yangi_versiya ga teng bo'lsin)."
