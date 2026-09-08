// ============================================================================
// «Aros Provodka - Aylanma Snapshot» — n8n Workflow SDK kodi (2026-09-08)
// n8n'da YARATILGAN: o3BZP8uYatGkRu8b — https://n8n.arosmarket.com/workflow/o3BZP8uYatGkRu8b
// validate_workflow OK (14 node), kreditsiz. Asilbek kreditlarni ulaydi, SQL RUN qilgach Publish qiladi.
// Brief: ARX_PROVODKA_AYLANMA.md (2–3-bo'lim). SQL: PROVODKA_AYLANMA.sql.
// Bu fayl — repo nusxasi (qayta yaratish/tahrirlash uchun manba).
// ----------------------------------------------------------------------------
// Nima qiladi: HAR KUNI 08:00 (Toshkent = 03:00 UTC, n8n server UTC) «Sof
// aylanma kapital» uchun Aros manbalarini BIR MARTA o'qiydi va
// sync_aylanma_snapshot RPC (service_role ONLY) ga beradi. Provodka ichidagi
// bo'limlarni (pul, yo'ldagi pul, qarzlar, yuk to'lovlari, kurs) RPC O'ZI
// hisoblaydi — bu yerda faqat Aros/Metabase qismi. PUL HARAKATI YO'Q.
//
// Tuzilma (chiziqli — har HTTP node 1 ta item oladi, natija keyingi code
// node'da $('Node').first().json bilan o'qiladi, hammasi neverError):
//   08:00 / Qo'lda -> Sana -> Get Warehouses -> MB Prep -> Get Metabase
//   -> Get Tr OnWay -> Get Tr Created -> Get Ord Created -> Get Ord Send
//   -> PI Sahifalar (4 item) -> Get Incomes (batch 2/1500ms)
//   -> Build Payload -> sync_aylanma_snapshot
//
// Manbalar (0-bosqich sinovi 2026-09-08, haqiqiy javoblardan):
//   * products/warehouses/?module=warehouse&page_size=500 -> 68 ombor
//     (33 oddiy + 35 brak, is_broken/broken_warehouse maydonlari), 1 so'rov.
//   * Metabase public card 4f729857-… «materialreport total»: warehouse_filter
//     ga HAMMA id massiv bilan -> 64 qator (nomlari unikal), 12 s, «Oxirgi summa»
//     = qty × average_price (KIRIM narxi, USD) — tannarx. Aros API emas.
//   * v2/transfers?status=on_way|created (warehouse'siz, global) -> 222 + 60.
//     document_price = transfer_items[].price × qty (SO'MDA, tannarx EMAS —
//     Metabase kartasi bo'lgach tannarx_uzs to'ldiriladi). 229/282 transfer
//     buyurtma uchun tizim yasagan (comment «… 463750 ID raqamli buyurtma …»)
//     -> order_id ajratiladi, RPC ochiq buyurtma bilan ikki marta sanamaydi.
//   * orders/?status=created|send&created_datetime_after=-90 kun: server
//     filtri ISHLAYDI (100/100 mos), total_price = SOTUV narxi (Asilbek qarori).
//   * v3/product-incomes 365 kun: 1230 hujjat, 3 sahifa × 500 (4 so'raladi,
//     bo'sh/404 sahifa neverError bilan o'tadi). Qarz sahifasi bilan bir xil
//     ro'yxat -> RPC undan «biz qarzdormiz» (narx×kurs − to'langan) va
//     «yo'ldagi yuklar» (posted + on_way) ni hisoblaydi.
//   Aros API jami: 1 + 2 + 2 + 4 = 9 so'rov/kun. Rate-limit xavfi yo'q.
//
// Asilbek qo'lda qiladi (yaratilgan workflow'da):
//   - Aros HTTP nodelari (5 ta) -> Aros Basic Auth krediti.
//   - «sync_aylanma_snapshot» -> Supabase API krediti (🔴 SERVICE ROLE).
//   - PROVODKA_AYLANMA.sql RUN qilingach -> Activate. «Qolda ishga tushirish»
//     bilan bir marta test: oxirgi javobda {ok:true, id, jami_uzs, toliq}.
//
// 🔴 n8n BUG: HTTP Request «Items per Batch = 1» abadiy osiladi — Get Incomes
//    batch 2/1500ms. Batch 1 ga QAYTARMA.
// SDK qoidalari: tashqarida faqat const/template string, newCredential,
// export default wf. jsCode ichida arrow function YO'Q (function + var).
// ============================================================================

const SANA_JSCODE = `function pad(n) { return n < 10 ? "0" + n : String(n); }
function fmt(d) { return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate()); }
// Toshkent vaqti (UTC+5) — CLAUDE.md getUTC* naqshi.
var now = new Date(Date.now() + 5 * 3600 * 1000);
var rejim = 'qolda';
try { if ($prevNode && $prevNode.name === '08:00 Toshkent') rejim = 'cron'; } catch (e) {}
var d365 = new Date(now.getTime() - 365 * 86400000);
var d90 = new Date(now.getTime() - 90 * 86400000);
var d30 = new Date(now.getTime() - 30 * 86400000);
return [{ json: {
  sana: fmt(now), rejim: rejim, t0: Date.now(),
  pi_from: fmt(d365), ord_after: fmt(d90), mb_start: fmt(d30), mb_end: fmt(now)
} }];`;

// Metabase karta parametrlari: hamma ombor id massiv bilan. URL GET ?parameters=<json>.
const MB_PREP_JSCODE = `var sana = $('Sana').first().json;
var wh = [];
var whErr = null;
try {
  var r = $('Get Warehouses').first().json || {};
  if (Array.isArray(r.results)) wh = r.results;
  else whErr = String(r.detail || r.error || 'results yoq');
} catch (e) { whErr = 'Get Warehouses: ' + e.message; }
var ids = [];
for (var i = 0; i < wh.length; i++) { if (wh[i] && wh[i].id != null) ids.push(parseInt(wh[i].id)); }
var params = [
  { id: 'b9cd8b82-6374-4d97-a4df-80cbe9e9d0f4', value: ids },
  { id: '93e15b92-63d0-4fd9-bbe3-ebba4d00d474', value: sana.mb_start },
  { id: 'b0f587fe-e763-4cbf-8175-043b6323522e', value: sana.mb_end }
];
var url = 'https://metabase.aros.uz/api/public/card/4f729857-27e4-4f6e-8b5b-811688f16d8d/query?parameters=' + encodeURIComponent(JSON.stringify(params));
return [{ json: { mb_url: url, wh_n: wh.length, wh_err: whErr, ids_n: ids.length } }];`;

// product-incomes sahifalari: 365 kun ~1230 hujjat -> 4 × 500 (oxirgisi bo'sh bo'lishi mumkin).
const PI_SAHIFALAR_JSCODE = `var sana = $('Sana').first().json;
var out = [];
for (var p = 1; p <= 4; p++) {
  out.push({ json: { page: p, pi_from: sana.pi_from, pi_to: sana.sana } });
}
return out;`;

const BUILD_JSCODE = `function safeFirst(name, dflt) {
  try { var j = $(name).first().json; return (j === undefined || j === null) ? dflt : j; } catch (e) { return dflt; }
}
function num(v) { var n = parseFloat(v); return isFinite(n) ? n : 0; }
function results(node) {
  var j = safeFirst(node, null);
  if (!j) return { ok: false, rows: [], err: 'javob yoq' };
  if (Array.isArray(j.results)) return { ok: true, rows: j.results, count: j.count };
  return { ok: false, rows: [], err: String(j.detail || j.error || j.message || 'results yoq').slice(0, 200) };
}
var sana = $('Sana').first().json;
var manba = {};
var ogoh = [];

// ---- 1. Omborlar ----
var whR = results('Get Warehouses');
manba.warehouses = whR.ok ? 'ok' : 'xato';
if (!whR.ok) ogoh.push('warehouses: ' + whR.err);
var whById = {};
var whByName = {};
var omborlar = [];
for (var i = 0; i < whR.rows.length; i++) {
  var w = whR.rows[i]; if (!w || w.id == null) continue;
  var nom = w.name_uz || w.name || ('Ombor ' + w.id);
  var o = { id: parseInt(w.id), nom: nom, is_broken: w.is_broken === true, is_active: w.is_active !== false,
            usd: null, soni: null, tr_yolda_uzs: null,
            broken_id: (w.broken_warehouse && w.broken_warehouse.id != null) ? parseInt(w.broken_warehouse.id) : null };
  whById[o.id] = o;
  whByName[nom] = o;
  if (w.name && !whByName[w.name]) whByName[w.name] = o;
  omborlar.push(o);
}

// ---- 2. Metabase (tannarx, USD) ----
var mb = safeFirst('Get Metabase', null);
var mbOk = false;
try {
  var cols = (mb && mb.data && mb.data.cols) ? mb.data.cols : [];
  var rows = (mb && mb.data && mb.data.rows) ? mb.data.rows : [];
  var iN = -1, iS = -1, iQ = -1, iT = -1;
  for (var c = 0; c < cols.length; c++) {
    var nm = String(cols[c].name || '');
    if (nm === 'Ombor') iN = c;
    if (nm === 'Oxirgi summa') iS = c;
    if (nm === 'Oxirgi miqdori') iQ = c;
    if (nm === 'Transfer yolda summa') iT = c;
  }
  if (cols.length > 0 && iN >= 0 && iS >= 0 && rows.length > 0) {
    mbOk = true;
    var topilmadi = [];
    for (var r = 0; r < rows.length; r++) {
      var row = rows[r];
      var target = whByName[String(row[iN])];
      if (!target) { topilmadi.push(String(row[iN])); continue; }
      target.usd = Math.round(num(row[iS]) * 100) / 100;
      target.soni = iQ >= 0 ? num(row[iQ]) : null;
      target.tr_yolda_uzs = iT >= 0 ? num(row[iT]) : null;
    }
    if (topilmadi.length) ogoh.push('metabase: ombor nomi mos kelmadi: ' + topilmadi.join(', '));
  } else {
    ogoh.push('metabase: ' + String((mb && (mb.error || mb.message)) || 'bosh javob').slice(0, 200));
  }
} catch (e) { ogoh.push('metabase: ' + e.message); }
manba.metabase = mbOk ? 'ok' : 'xato';

// ---- 3. Transferlar (on_way + created) ----
var trOn = results('Get Tr OnWay');
var trCr = results('Get Tr Created');
manba.transfers = (trOn.ok && trCr.ok) ? 'ok' : 'xato';
if (!trOn.ok) ogoh.push('transfers on_way: ' + trOn.err);
if (!trCr.ok) ogoh.push('transfers created: ' + trCr.err);
if (trOn.ok && trOn.count > trOn.rows.length) ogoh.push('transfers on_way: ' + trOn.count + ' > ' + trOn.rows.length + ' (sahifa sigmadi)');
if (trCr.ok && trCr.count > trCr.rows.length) ogoh.push('transfers created: ' + trCr.count + ' > ' + trCr.rows.length + ' (sahifa sigmadi)');
var ORDER_RE = /(\\d{3,})\\s*ID\\s*raqamli\\s*buyurtma/i;
var transferlar = [];
var seenTr = {};
var trRows = trOn.rows.concat(trCr.rows);
for (var t = 0; t < trRows.length; t++) {
  var x = trRows[t]; if (!x || x.id == null || seenTr[x.id]) continue;
  seenTr[x.id] = true;
  if (x.status !== 'on_way' && x.status !== 'created') continue;
  var fromId = (x.from_warehouse && x.from_warehouse.id != null) ? parseInt(x.from_warehouse.id) : null;
  var toId = (x.to_warehouse && x.to_warehouse.id != null) ? parseInt(x.to_warehouse.id) : null;
  var toW = toId != null ? whById[toId] : null;
  var m = ORDER_RE.exec(String(x.comment || ''));
  transferlar.push({
    id: parseInt(x.id), status: x.status,
    from_id: fromId, from_nom: (x.from_warehouse && (x.from_warehouse.name_uz || x.from_warehouse.name)) || '',
    to_id: toId, to_nom: (x.to_warehouse && (x.to_warehouse.name_uz || x.to_warehouse.name)) || '',
    to_brak: toW ? toW.is_broken === true : false,
    price_uzs: num(x.document_price || x.total_price),
    tannarx_uzs: null,
    order_id: m ? parseInt(m[1]) : null,
    created: x.created_datetime || null, sent: x.sent_at || null
  });
}

// ---- 4. Ochiq buyurtmalar (created + send) — SOTUV narxi ----
var oCr = results('Get Ord Created');
var oSe = results('Get Ord Send');
manba.orders = (oCr.ok && oSe.ok) ? 'ok' : 'xato';
if (!oCr.ok) ogoh.push('orders created: ' + oCr.err);
if (!oSe.ok) ogoh.push('orders send: ' + oSe.err);
if (oCr.ok && oCr.count > oCr.rows.length) ogoh.push('orders created: ' + oCr.count + ' > ' + oCr.rows.length + ' (sahifa sigmadi)');
if (oSe.ok && oSe.count > oSe.rows.length) ogoh.push('orders send: ' + oSe.count + ' > ' + oSe.rows.length + ' (sahifa sigmadi)');
var buyurtmalar = [];
var seenOrd = {};
var ordRows = oCr.rows.concat(oSe.rows);
for (var q = 0; q < ordRows.length; q++) {
  var od = ordRows[q]; if (!od || od.id == null || seenOrd[od.id]) continue;
  seenOrd[od.id] = true;
  if (od.status !== 'created' && od.status !== 'send') continue;
  buyurtmalar.push({
    id: parseInt(od.id), status: od.status,
    warehouse_id: (od.warehouse && od.warehouse.id != null) ? parseInt(od.warehouse.id) : null,
    warehouse: (od.warehouse && (od.warehouse.name_uz || od.warehouse.name)) || '',
    total_uzs: num(od.total_price || od.total_amount || (od.payment && od.payment.total_amount)),
    user_id: (od.user && od.user.id != null) ? parseInt(od.user.id) : null,
    created: od.created_datetime || null
  });
}

// ---- 5. Yuklar (product-incomes, 365 kun, hamma status) ----
var piItems = [];
try { piItems = $('Get Incomes').all(); } catch (e) { piItems = []; }
var yuklar = [];
var seenPi = {};
var piOk = false;
var piCount = null;
for (var p = 0; p < piItems.length; p++) {
  var pj = piItems[p].json || {};
  if (!Array.isArray(pj.results)) continue;
  if (p === 0 || piCount === null) piCount = pj.count;
  piOk = true;
  for (var k = 0; k < pj.results.length; k++) {
    var y = pj.results[k]; if (!y || y.id == null || seenPi[y.id]) continue;
    seenPi[y.id] = true;
    yuklar.push({
      id: parseInt(y.id), narx: num(y.document_price), valyuta: (y.currency && y.currency.name) || '',
      status: y.status || '', delivery_status: y.delivery_status || '',
      ombor_id: (y.warehouse && y.warehouse.id != null) ? parseInt(y.warehouse.id) : null,
      ombor: (y.warehouse && (y.warehouse.name_uz || y.warehouse.name)) || '',
      yetkazuvchi: (y.provider && y.provider.name) || '',
      sana: y.created_datetime || null, post_at: y.post_at || null
    });
  }
}
manba.incomes = piOk ? 'ok' : 'xato';
if (!piOk) ogoh.push('product-incomes: birorta sahifa kelmadi');
if (piOk && piCount != null && yuklar.length < piCount) ogoh.push('product-incomes: ' + piCount + ' > ' + yuklar.length + ' (sahifa yetmadi)');

var payload = {
  sana: sana.sana, rejim: sana.rejim,
  manba: manba,
  omborlar: omborlar, yuklar: yuklar, transferlar: transferlar, buyurtmalar: buyurtmalar,
  ogoh: ogoh,
  stat: { omborlar: omborlar.length, metabase_qator: omborlar.filter(function (o) { return o.usd !== null; }).length,
          transferlar: transferlar.length, buyurtmalar: buyurtmalar.length, yuklar: yuklar.length,
          ms: Date.now() - (sana.t0 || Date.now()) }
};
return [{ json: payload }];`;

const wf = workflow('aros-provodka-aylanma-snapshot', 'Aros Provodka - Aylanma Snapshot');

const schedule = node({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.2,
  config: {
    name: '08:00 Toshkent',
    parameters: { rule: { interval: [ { field: 'cronExpression', expression: '0 3 * * *' } ] } },
    position: [0, 0]
  }
});

const manual = node({
  type: 'n8n-nodes-base.manualTrigger',
  version: 1,
  config: { name: 'Qolda ishga tushirish', parameters: {}, position: [0, 200] }
});

const sana = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: { name: 'Sana', parameters: { jsCode: SANA_JSCODE }, position: [260, 100] }
});

const getWarehouses = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'Get Warehouses',
    parameters: {
      method: 'GET',
      url: 'https://api.aros.uz/api/admin/products/warehouses/?page=1&page_size=500&module=warehouse',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpBasicAuth',
      options: { timeout: 60000, response: { response: { neverError: true } } }
    },
    credentials: { httpBasicAuth: newCredential('Aros Basic Auth') },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [520, 100]
  }
});

const mbPrep = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: { name: 'MB Prep', parameters: { jsCode: MB_PREP_JSCODE }, position: [780, 100] }
});

const getMetabase = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'Get Metabase',
    parameters: {
      method: 'GET',
      url: '={{ $json.mb_url }}',
      options: { timeout: 180000, response: { response: { neverError: true } } }
    },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [1040, 100]
  }
});

const getTrOnWay = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'Get Tr OnWay',
    parameters: {
      method: 'GET',
      url: 'https://api.aros.uz/api/admin/v2/transfers?page=1&page_size=1000&ordering=-id&status=on_way',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpBasicAuth',
      options: { timeout: 60000, response: { response: { neverError: true } } }
    },
    credentials: { httpBasicAuth: newCredential('Aros Basic Auth') },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [1300, 100]
  }
});

const getTrCreated = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'Get Tr Created',
    parameters: {
      method: 'GET',
      url: 'https://api.aros.uz/api/admin/v2/transfers?page=1&page_size=1000&ordering=-id&status=created',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpBasicAuth',
      options: { timeout: 60000, response: { response: { neverError: true } } }
    },
    credentials: { httpBasicAuth: newCredential('Aros Basic Auth') },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [1560, 100]
  }
});

const getOrdCreated = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'Get Ord Created',
    parameters: {
      method: 'GET',
      url: '={{ "https://api.aros.uz/api/admin/orders/?page=1&page_size=1000&ordering=-id&status=created&created_datetime_after=" + $(\'Sana\').first().json.ord_after }}',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpBasicAuth',
      options: { timeout: 60000, response: { response: { neverError: true } } }
    },
    credentials: { httpBasicAuth: newCredential('Aros Basic Auth') },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [1820, 100]
  }
});

const getOrdSend = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'Get Ord Send',
    parameters: {
      method: 'GET',
      url: '={{ "https://api.aros.uz/api/admin/orders/?page=1&page_size=1000&ordering=-id&status=send&created_datetime_after=" + $(\'Sana\').first().json.ord_after }}',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpBasicAuth',
      options: { timeout: 60000, response: { response: { neverError: true } } }
    },
    credentials: { httpBasicAuth: newCredential('Aros Basic Auth') },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [2080, 100]
  }
});

const piSahifalar = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: { name: 'PI Sahifalar', parameters: { jsCode: PI_SAHIFALAR_JSCODE }, position: [2340, 100] }
});

const getIncomes = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'Get Incomes',
    parameters: {
      method: 'GET',
      url: '={{ "https://api.aros.uz/api/admin/v3/product-incomes/?page=" + $json.page + "&page_size=500&search=&ordering=-1&date_from=" + $json.pi_from + "&date_to=" + $json.pi_to }}',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpBasicAuth',
      options: {
        batching: { batch: { batchSize: 2, batchInterval: 1500 } },
        timeout: 90000,
        response: { response: { neverError: true } }
      }
    },
    credentials: { httpBasicAuth: newCredential('Aros Basic Auth') },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [2600, 100]
  }
});

const build = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: { name: 'Build Payload', parameters: { jsCode: BUILD_JSCODE }, position: [2860, 100] }
});

const httpSync = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'sync_aylanma_snapshot',
    parameters: {
      method: 'POST',
      url: 'https://kxzerccdpcltmzrxutlo.supabase.co/rest/v1/rpc/sync_aylanma_snapshot',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'supabaseApi',
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify({ p_data: $json }) }}',
      options: { timeout: 60000 }
    },
    credentials: { supabaseApi: newCredential('Supabase API') },
    position: [3120, 100]
  }
});

wf.add(schedule).to(sana);
wf.add(manual).to(sana);
wf.add(sana).to(getWarehouses);
wf.add(getWarehouses).to(mbPrep);
wf.add(mbPrep).to(getMetabase);
wf.add(getMetabase).to(getTrOnWay);
wf.add(getTrOnWay).to(getTrCreated);
wf.add(getTrCreated).to(getOrdCreated);
wf.add(getOrdCreated).to(getOrdSend);
wf.add(getOrdSend).to(piSahifalar);
wf.add(piSahifalar).to(getIncomes);
wf.add(getIncomes).to(build);
wf.add(build).to(httpSync);

export default wf;
