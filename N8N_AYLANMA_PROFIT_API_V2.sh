#!/usr/bin/env bash
# =====================================================================
# N8N_AYLANMA_PROFIT_API_V2.sh — 2026-10-17 — «Aros Provodka - Aylanma Snapshot» (o3BZP8uYatGkRu8b)
# V1 (N8N_AYLANMA_PROFIT_API.sh) QO'LLANGANDAN KEYIN ishlatiladi. Sabab: Aros prod'da `warehouse_id` parametrini E'TIBORGA OLMAYDI —
# har ombor so'rovi ham UMUMIY javob qaytardi (exec 1376230) -> tovar 33 x 2.6M, brak 35 x 2.6M, har filial foydasi = umumiy nusxa.
# V2 = SUMMARY-ONLY: kundalik atigi 1 + 4 = 5 so'rov (warehouse_id siz).
#   * Profit Prep      — faqat 1 ta umumiy so'rov (kecha). Per-ombor so'rovlar `WH_PARAM` konstantasi bilan (hozir null = yuborilmaydi).
#   * Build Payload    — [1] tovar = umumiy total_stock_value, [5] brak = umumiy total_broken_value (ikkita sintetik "ombor" qatori:
#                        id 0 «Barcha omborlar (umumiy)» va id -1 «Brak omborlar (umumiy)»); manba.profit_api=ok FAQAT umumiy javob yaroqli bo'lsa.
#   * Foyda URL/Payload — faqat JAMI: oldingi 4 kun (+ BACKFILL kunlar). Per-ombor qator YO'Q.
#   * WH_PARAM yoqilganda HIMOYA: ombor javobi umumiy javob bilan AYNAN teng (stock+broken+profit) bo'lsa rad etiladi,
#     ogohlantirish beriladi va umumiy javob ishlatiladi (per-ombor qiymat yozilmaydi).
# TARTIB: 1) PROVODKA_AYLANMA_PROFIT_API_TOZALASH.sql RUN  2) shu skript  3) Publish  4) «Qolda ishga tushirish» bir marta  5) --backfill-off
#
#   ssh root@37.27.15.184 'bash -s' < /Users/s1mple/Projects/pravodka/N8N_AYLANMA_PROFIT_API_V2.sh
#   ssh root@37.27.15.184 'bash -s -- --backfill-off' < ...          (backfill o'chirish; --backfill-on yoqish)
#   ssh root@37.27.15.184 'bash -s -- --wh-param warehouse' < ...     (Aros to'g'ri parametr nomini aytganda; --wh-param-off qaytarish)
# Zaxira: /root/n8n-backups. Qayta ishga tushirish xavfsiz (o'zgarish yo'q bo'lsa hech narsa yozilmaydi).
# =====================================================================
set -euo pipefail
WF=o3BZP8uYatGkRu8b
PG="docker exec n8n-postgres psql -U n8n -d n8n"
MODE=apply
ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --backfill-off) MODE=bfoff ;;
    --backfill-on)  MODE=bfon ;;
    --wh-param-off) MODE=whoff ;;
    --wh-param)     MODE=whon; shift; ARG="${1:-}"; [ -n "$ARG" ] || { echo "--wh-param NOM kerak"; exit 2; } ;;
    *) echo "noma'lum argument: $1"; exit 2 ;;
  esac
  shift
done
mkdir -p /root/n8n-backups
$PG -Atc "select row_to_json(w) from workflow_entity w where id='$WF'" > /root/n8n-backups/${WF}_$(date +%Y%m%d_%H%M%S).json
echo "zaxira: $(ls -t /root/n8n-backups/${WF}_*.json | head -1)"
$PG -Atc "select nodes::text from workflow_entity where id='$WF'" > /tmp/ayl_nodes.json
$PG -Atc "select connections::text from workflow_entity where id='$WF'" > /tmp/ayl_conn.json

set +e
AYL_MODE="$MODE" AYL_ARG="$ARG" AYL_NODES=/tmp/ayl_nodes.json AYL_CONN=/tmp/ayl_conn.json \
AYL_NODES_OUT=/tmp/ayl_nodes_new.json AYL_CONN_OUT=/tmp/ayl_conn_new.json python3 - <<'PYEOF'
import json, os, re, sys

MODE = os.environ["AYL_MODE"]
ARG = os.environ.get("AYL_ARG", "")
nodes = json.load(open(os.environ["AYL_NODES"]))
conn = json.load(open(os.environ["AYL_CONN"]))
by = {n["name"]: n for n in nodes}
BACKFILL_RE = re.compile(r"var BACKFILL_FROM = (null|'\d{4}-\d{2}-\d{2}'); // BACKFILL_CFG")
WH_RE = re.compile(r"var WH_PARAM = (null|'[a-z_]+'); // WH_PARAM_CFG")


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


for need in ("Profit Prep", "Get Profit WH", "Get Profit Foyda", "Foyda URL", "Foyda Payload", "Build Payload"):
    assert need in by, "V1 patch qo'llanmagan (node yo'q: %s) — avval N8N_AYLANMA_PROFIT_API.sh" % need

V2 = "WH_PARAM_CFG" in by["Profit Prep"]["parameters"]["jsCode"]


def flip(node, rx, repl):
    c = by[node]["parameters"]["jsCode"]
    assert len(rx.findall(c)) == 1, node + ": konstanta qatori topilmadi"
    new = rx.sub(lambda m: repl, c)
    by[node]["parameters"]["jsCode"] = new
    return new != c


if MODE != "apply":
    assert V2, "avval V2 ni oddiy rejimda qo'llang (argumentsiz)"
    if MODE in ("bfon", "bfoff"):
        ch = flip("Foyda URL", BACKFILL_RE, "var BACKFILL_FROM = " + ("null" if MODE == "bfoff" else "'2026-10-03'") + "; // BACKFILL_CFG")
    else:
        if MODE == "whon":
            assert re.fullmatch(r"[a-z_]+", ARG), "parametr nomi faqat a-z va _"
            val = "'" + ARG + "'"
        else:
            val = "null"
        c1 = flip("Profit Prep", WH_RE, "var WH_PARAM = " + val + "; // WH_PARAM_CFG")
        c2 = flip("Foyda URL", WH_RE, "var WH_PARAM = " + val + "; // WH_PARAM_CFG")
        ch = c1 or c2
    if not ch:
        print("allaqachon shunday (o'zgarish yo'q)")
        sys.exit(3)
    verify()
    save()
    print("rejim: " + MODE + " " + ARG)
    sys.exit(0)

if V2:
    print("V2 allaqachon qo'llangan (o'zgarish yo'q)")
    sys.exit(3)

# ----------------------------------------------------------------------------
PREP_JS = r"""// Aros profit-summary (kecha). SUMMARY-ONLY: warehouse_id prod'da E'TIBORGA OLINMAYDI (2026-10-17 tekshirildi — har so'rov umumiy javob qaytardi).
// Per-ombor so'rovlar faqat WH_PARAM (Aros aytgan to'g'ri parametr nomi) berilganda yuboriladi.
var WH_PARAM = null; // WH_PARAM_CFG
function pad(n) { return n < 10 ? '0' + n : String(n); }
function fmt(d) { return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate()); }
var BASE = 'https://api.aros.uz/api/admin/v2/report/profit-summary/';
var kecha = fmt(new Date(Date.now() + 5 * 3600 * 1000 - 86400000));
var q = '?start_date=' + kecha + '&end_date=' + kecha;
var out = [{ json: { kind: 'jami', sana: kecha, wh_id: null, wh_nom: 'JAMI', is_broken: false, url: BASE + q } }];
if (WH_PARAM) {
  var wh = [];
  try {
    var r = $('Get Warehouses').first().json || {};
    if (Array.isArray(r.results)) wh = r.results;
  } catch (e) { wh = []; }
  for (var i = 0; i < wh.length; i++) {
    var w = wh[i]; if (!w || w.id == null) continue;
    out.push({ json: { kind: 'wh', sana: kecha, wh_id: parseInt(w.id), wh_nom: w.name_uz || w.name || ('Ombor ' + w.id),
                       is_broken: w.is_broken === true, url: BASE + q + '&' + WH_PARAM + '=' + parseInt(w.id) } });
  }
}
return out;"""

FOYDA_URL_JS = r"""// Kunlik foyda — Aros profit-summary, SUMMARY-ONLY. Kecha 'Get Profit WH' dan olingan; bu yerda: kechadan oldingi 4 kun JAMI
// (hisobot kechikib tuzalsa keyingi kunlarda o'zi yangilanadi) + BACKFILL bo'lsa har kun JAMI. Per-ombor faqat WH_PARAM berilganda.
var BACKFILL_FROM = '2026-10-03'; // BACKFILL_CFG
var WH_PARAM = null; // WH_PARAM_CFG
function pad(n) { return n < 10 ? '0' + n : String(n); }
function fmt(d) { return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate()); }
function addDays(s, n) { return fmt(new Date(new Date(s + 'T00:00:00Z').getTime() + n * 86400000)); }
var BASE = 'https://api.aros.uz/api/admin/v2/report/profit-summary/';
var prep = $('Profit Prep').all();
var kecha = prep[0].json.sana;
var whs = [];
for (var i = 0; i < prep.length; i++) {
  var m = prep[i].json;
  if (WH_PARAM && m.kind === 'wh' && !m.is_broken) whs.push(m);
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
                         url: BASE + q + '&' + WH_PARAM + '=' + whs[w].wh_id } });
    }
  }
}
return out;"""

PAYLOAD_JS = r"""// Aros profit-summary javoblari -> sync_aylanma_foyda payload. Hozir faqat JAMI qatorlar (warehouse_id prod'da ishlamaydi).
// Per-ombor qator (WH_PARAM yoqilganda) faqat o'sha kun umumiy javobidan FARQ qilsagina yoziladi — aks holda filtr ishlamayapti.
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
var jamiResp = {};
for (var a = 0; a < src.length; a++) { if (src[a].m.kind === 'jami' && has(src[a].j)) jamiResp[src[a].m.sana] = src[a].j; }
var rows = [], bosh = {}, jamiBor = {}, filtrYoq = 0;
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
    var jr = jamiResp[m.sana];
    if (jr && num(jr.total_profit) === num(j.total_profit) && num(jr.total_selling_price) === num(j.total_selling_price)
        && num(jr.total_sold_quantity) === num(j.total_sold_quantity)) { filtrYoq++; continue; }
    rows.push(o);
  }
}
if (filtrYoq) xato.push('warehouse filtri ishlamayapti: ' + filtrYoq + ' ombor javobi umumiy javob bilan bir xil — per-ombor qator yozilmadi');
rows = rows.filter(function (o) { return jamiBor[o.sana] && !bosh[o.sana]; });
// JIMGINA 0 YO'Q: kechaning JAMI qatori bo'lmasa (API yiqilgan / javob shakli o'zgargan) — xato
if (!kecha || !jamiBor[kecha]) {
  throw new Error('Aros profit-summary: kecha (' + kecha + ') JAMI kelmadi. ' + xato.slice(0, 8).join(' | '));
}
return [{ json: { rows: rows, soni: rows.length, xato: xato.slice(0, 40) } }];"""

BP_NEW = r"""// ---- 2. Aros profit-summary (kecha) — SUMMARY: [1] tovar = umumiy total_stock_value, [5] brak = umumiy total_broken_value ----
// (warehouse_id prod'da E'TIBORGA OLINMAYDI; per-ombor faqat Profit Prep da WH_PARAM yoqilgan bo'lsa va javob umumiydan farq qilsa)
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
var pJami = null, useWh = false, whBad = [], whOk = 0;
if (pResp.length !== pPrep.length) profitOgoh.push('profit-summary: javoblar soni mos emas ' + pResp.length + '/' + pPrep.length);
var sumNorm = 0, sumBrk = 0, sumProfit = 0;
for (var pi = 0; pi < pPrep.length; pi++) {
  var pm = pPrep[pi].json || {};
  var pj = (pResp[pi] && pResp[pi].json) || null;
  if (pm.kind === 'jami') {
    if (pValid(pj)) pJami = pj; else profitOgoh.push('profit-summary umumiy: ' + pErr(pj));
    continue;
  }
  useWh = true;
  var tw = whById[pm.wh_id];
  if (!tw) continue;
  if (!pValid(pj)) { whBad.push(tw.nom + ': ' + pErr(pj)); continue; }
  var st = num(pj.total_stock_value), br = num(pj.total_broken_value);
  if (pJami && st === num(pJami.total_stock_value) && br === num(pJami.total_broken_value) && num(pj.total_profit) === num(pJami.total_profit)) {
    whBad.push(tw.nom + ': javob umumiy bilan AYNAN bir xil (warehouse filtri ishlamayapti)');
    continue;
  }
  tw.usd_stock = r2(st); tw.usd_broken = r2(br);
  // brak ombor javobida qiymat qaysi maydonda kelishi noma'lum — kattasi olinadi; oddiy omborda faqat stock
  tw.usd = r2(tw.is_broken ? Math.max(st, br) : st);
  tw.soni = null; tw.tr_yolda_uzs = null;
  whOk++;
  if (tw.is_broken) sumBrk += tw.usd; else { sumNorm += tw.usd; sumProfit += num(pj.total_profit); }
}
var perWh = useWh && pJami && whBad.length === 0 && whOk > 0;
if (useWh && !perWh) {
  profitOgoh.push('profit_api: per-ombor ishlamadi (' + whBad.length + ' xato' + (whBad.length ? ': ' + whBad.slice(0, 3).join(' | ') : '') + ') — umumiy javob ishlatildi');
}
if (perWh) {
  farq('tovar (total_stock_value)', sumNorm, num(pJami.total_stock_value));
  farq('brak (total_broken_value)', sumBrk, num(pJami.total_broken_value));
  farq('foyda (total_profit)', sumProfit, num(pJami.total_profit));
} else if (pJami) {
  omborlar = [
    { id: 0, nom: 'Barcha omborlar (umumiy)', is_broken: false, is_active: true, usd: r2(num(pJami.total_stock_value)), soni: null, tr_yolda_uzs: null, broken_id: null },
    { id: -1, nom: 'Brak omborlar (umumiy)', is_broken: true, is_active: true, usd: r2(num(pJami.total_broken_value)), soni: null, tr_yolda_uzs: null, broken_id: null }
  ];
}
for (var po = 0; po < profitOgoh.length; po++) ogoh.push(profitOgoh[po]);
manba.profit_api = pJami ? 'ok' : 'xato';
manba.metabase = manba.profit_api; // PROVODKA_AYLANMA_PROFIT_API.sql RUN bo'lmagan eski RPC shu kalitni o'qiydi"""

# ---- Build Payload ----
bp = by["Build Payload"]["parameters"]["jsCode"]
S = "// ---- 2. Aros profit-summary (kecha): har ombor"
E = "manba.metabase = manba.profit_api; // PROVODKA_AYLANMA_PROFIT_API.sql RUN bo'lmagan eski RPC shu kalitni o'qiydi"
assert bp.count(S) == 1 and bp.count(E) == 1, "Build Payload: V1 bo'limi topilmadi"
a = bp.index(S); b = bp.index(E) + len(E)
bp = bp[:a] + BP_NEW + bp[b:]
by["Build Payload"]["parameters"]["jsCode"] = bp

# ---- Foyda URL: BACKFILL holatini saqlab qol ----
old = by["Foyda URL"]["parameters"]["jsCode"]
m = BACKFILL_RE.search(old)
assert m, "Foyda URL: BACKFILL_CFG topilmadi"
by["Foyda URL"]["parameters"]["jsCode"] = BACKFILL_RE.sub(lambda _m: m.group(0), FOYDA_URL_JS, count=1)
assert m.group(0) in by["Foyda URL"]["parameters"]["jsCode"]
by["Profit Prep"]["parameters"]["jsCode"] = PREP_JS
by["Foyda Payload"]["parameters"]["jsCode"] = PAYLOAD_JS
verify()
save()
print("V2: summary-only (Profit Prep, Build Payload, Foyda URL, Foyda Payload); BACKFILL saqlandi: " + m.group(0))
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
select "versionId", id, 'Asilbek (profit-summary V2 2026-10-17)', now(), now(), nodes, connections
  from workflow_entity where id = 'o3BZP8uYatGkRu8b';
commit;
select "versionId" as yangi_versiya, "activeVersionId" as faol_versiya from workflow_entity where id = 'o3BZP8uYatGkRu8b';
SQLEOF
docker cp /tmp/ayl_upd.sql n8n-postgres:/tmp/ayl_upd.sql
$PG -f /tmp/ayl_upd.sql
echo "TAYYOR — endi n8n UI da «Aros Provodka - Aylanma Snapshot» ni ochib Publish bosing (faol_versiya yangi_versiya ga teng bo'lsin)."
