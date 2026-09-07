// ============================================================================
// «Aros Provodka - Aros Qarzdor Sync» — n8n Workflow SDK kodi (2026-09-07)
// n8n'da YARATILGAN (2026-09-07): workflow id KwYNPuJss2tAwi7w — https://n8n.arosmarket.com/workflow/KwYNPuJss2tAwi7w
// validate_workflow OK (9 node; v1 i91Kfmp7Orm55leW arxivlandi — kesh limit nodelari qoshildi). Asilbek kreditlarni (Aros Basic Auth, Supabase API
// service_role) qo'lda ulaydi, SQL RUN qilgach Publish qiladi.
// Bu fayl — repo nusxasi (qayta yaratish/tahrirlash uchun manba).
// ----------------------------------------------------------------------------
// Brief: ARX_PROVODKA_AROS_QARZDOR.md 4-BO'LIM. ALOHIDA workflow — mavjud
// «Aros Provodka - Yuk Bojxona Sync» / «Aros Provodka - Yolda Sync» ga
// TEGILMAGAN. Faqat YANGI jadval `aros_qarzdor` ga yozadi (PUL HARAKATI YOQ).
//
// Nima qiladi: har 30 daqiqada Aros mijoz qarzlari ro'yxatini oladi
// (v3/report/debtors-list, bugungi report_date, page_size=1000, 3 sahifa
// yetadi — ~2459 mijoz), sahifalarni bitta ro'yxatga yig'adi va
// sync_aros_qarzdor RPC (service_role ONLY) orqali yozadi.
//
// Tuzilma:
//   Har 30 daqiqa ─────────┐
//   Qolda ishga tushirish  ┴─> Sana -> Sahifalar -> Get Debtors (batch 3/1500ms)
//                              -> Yig' -> Kesh Limit PG -> Birlashtir -> sync_aros_qarzdor
//
// 🔴 TAKRORIY SOROV YOQ (Asilbek 2026-09-07): arosmarket-dashboard allaqachon
// «Aros Market - Debtors Cache» (0mY2RmaOYGtX1Jho) bilan soatlik n8n PG
// cache_debtors jadvalini toldiradi (debtors-by-warehouse: debt_limit,
// debt_allowed_days, most_outdated_deadline). Biz Aros users API ni
// CHAQIRMAYMIZ — «Kesh Limit PG» shu jadvaldan oqiydi (Postgres account 3),
// «Birlashtir» rows ga qoshadi. Kesh yoq/xato -> ogoh, sync davom etadi.
// debtors-list (aging bucketlar, summary) dashboard keshida YOQ — shuning
// uchun u alohida olinadi (3 sorov / 30 daq, dashboard 69 sorov / soat).
//
// Asilbek qolda qiladi (yaratilgan workflow'da):
//   - «Get Debtors» -> Aros Basic Auth krediti (genericCredentialType/
//     httpBasicAuth, api.aros.uz uchun — mavjud kredit qayta ishlatiladi).
//   - «sync_aros_qarzdor» -> Supabase API krediti (🔴 SERVICE ROLE kaliti —
//     RPC authenticated/anon'dan revoke qilingan, boshqa rol 42501 oladi).
//   - PROVODKA_AROS_QARZDOR.sql RUN qilingach -> Activate.
//   - «Qolda ishga tushirish» bilan bir marta test: oxirgi HTTP javobida
//     {ok:true, yozildi, yangilandi, nofaol, tashlandi, ogoh:[]} kelishi kerak.
//
// 🔴 n8n BUG (2026-09-07, CLAUDE.md "Andijon yo'qolishi" + batch=1 saboqi):
// HTTP Request node «Items per Batch = 1» da ABADIY osilib qolishi mumkin —
// shuning uchun «Get Debtors» batch 3 ta / 1500ms interval bilan chaqiriladi
// (3 sahifa — bittasi osilib qolsa ham onError butun oqimni to'xtatmaydi).
// Batch 1 ga QAYTARMA.
// SDK qoidalari: faqat `const` (var taqiq — jsCode ICHIDA emas, tashqarida),
// template string, kredit `newCredential('Nom')`, oxirida `export default wf`.
// jsCode ichida arrow function YOQ (CLAUDE.md) — faqat `function` sintaksisi
// va `var` (jsCode brauzer/n8n VM ichida ishlaydi, SDK qoidasi tashqi kodga
// tegishli, lekin izchillik uchun jsCode ham shu uslubda yozilgan).
// ============================================================================

const SANA_JSCODE = `function pad(n) {
  return n < 10 ? "0" + n : String(n);
}
function fmt(d) {
  return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate());
}
// Toshkent vaqti (UTC+5) — CLAUDE.md getUTC* naqshi bilan.
var now = new Date(Date.now() + 5 * 3600 * 1000);
return [{ json: { report_date: fmt(now), t0: Date.now() } }];`;

const SAHIFALAR_JSCODE = `var src = $input.first().json || {};
var reportDate = src.report_date;
var out = [];
for (var i = 1; i <= 3; i++) {
  out.push({ json: { report_date: reportDate, page: i } });
}
return out;`;

const YIGISH_JSCODE = `function num(v) {
  if (v === null || v === undefined || v === "") return null;
  var n = Number(v);
  return isNaN(n) ? null : n;
}

var items = $input.all();
var rows = [];
var summary = null;
var count = null;
var ogoh = [];

for (var i = 0; i < items.length; i++) {
  var it = items[i] || {};
  var j = it.json || {};

  if (j.error) {
    ogoh.push("sahifa " + (i + 1) + " xato: " + String(j.error).slice(0, 200));
    continue;
  }

  var results = j.results;
  if (!Array.isArray(results)) {
    ogoh.push("sahifa " + (i + 1) + ": results massiv emas (kelmagan/xato javob)");
    continue;
  }

  if (summary === null && j.summary) {
    summary = j.summary;
  }
  if (count === null) {
    var c = num(j.count);
    if (c !== null) {
      count = c;
    }
  }

  for (var k = 0; k < results.length; k++) {
    rows.push(results[k]);
  }
}

if (count !== null && rows.length !== count) {
  ogoh.push("rows.length (" + rows.length + ") != count (" + count + ")");
}

var sanaNode = $("Sana").first();
var reportDate = (sanaNode && sanaNode.json) ? sanaNode.json.report_date : null;
var t0 = (sanaNode && sanaNode.json && sanaNode.json.t0 !== undefined) ? sanaNode.json.t0 : null;
var davomiylikMs = t0 !== null ? (Date.now() - t0) : null;

return [{ json: {
  report_date: reportDate,
  summary: summary,
  rows: rows,
  count: count,
  ogoh: ogoh,
  davomiylik_ms: davomiylikMs
} }];`;

const KESH_LIMIT_SQL = `select (d->>'id')::bigint as user_id,
       max(nullif(d->>'debt_limit', '')::numeric) as debt_limit,
       max(nullif(d->>'debt_allowed_days', '')::int) as debt_allowed_days,
       max(nullif(left(d->>'most_outdated_deadline', 10), '')) as most_outdated_deadline
  from cache_debtors c, jsonb_array_elements(c.data->'debtors') d
 where c.updated_at > now() - interval '3 days'
   and (d->>'id') ~ '^[0-9]+$'
 group by 1`;

const BIRLASHTIR_JSCODE = `var base = $("Yig'").first().json || {};
var items = $input.all();
var map = {};
for (var i = 0; i < items.length; i++) {
  var j = items[i].json || {};
  if (j.error || j.user_id === null || j.user_id === undefined) {
    continue;
  }
  map[String(j.user_id)] = j;
}
var rows = Array.isArray(base.rows) ? base.rows : [];
var n = 0;
for (var k = 0; k < rows.length; k++) {
  var m = map[String(rows[k].user_id)];
  if (m) {
    rows[k].debt_limit = m.debt_limit;
    rows[k].debt_allowed_days = m.debt_allowed_days;
    rows[k].most_outdated_deadline = m.most_outdated_deadline;
    n = n + 1;
  }
}
base.rows = rows;
base.limit_n = n;
if (Object.keys(map).length === 0) {
  base.ogoh = (Array.isArray(base.ogoh) ? base.ogoh : []).concat(["cache_debtors (dashboard keshi) dan limit kelmadi"]);
}
return [{ json: base }];`;

const wf = workflow('aros-provodka-aros-qarzdor-sync', 'Aros Provodka - Aros Qarzdor Sync');

const schedule = node({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.2,
  config: {
    name: 'Har 30 daqiqa',
    parameters: { rule: { interval: [ { field: 'minutes', minutesInterval: 30 } ] } },
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
  config: {
    name: 'Sana',
    parameters: { jsCode: SANA_JSCODE },
    position: [260, 100]
  }
});

const sahifalar = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Sahifalar',
    parameters: { jsCode: SAHIFALAR_JSCODE },
    position: [520, 100]
  }
});

const getDebtors = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'Get Debtors',
    parameters: {
      method: 'GET',
      url: '={{ "https://api.aros.uz/api/admin/v3/report/debtors-list/?report_date=" + $json.report_date + "&page=" + $json.page + "&page_size=1000" }}',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpBasicAuth',
      options: {
        batching: { batch: { batchSize: 3, batchInterval: 1500 } },
        timeout: 60000
      }
    },
    credentials: { httpBasicAuth: newCredential('Aros Basic Auth') },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [780, 100]
  }
});

const yigish = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Yig\'',
    parameters: { jsCode: YIGISH_JSCODE },
    position: [1040, 100]
  }
});

const keshLimit = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Kesh Limit PG',
    parameters: { operation: 'executeQuery', query: KESH_LIMIT_SQL, options: { largeNumbersOutput: 'text' } },
    credentials: { postgres: newCredential('Postgres account 3') },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [1300, 100]
  }
});

const birlashtir = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Birlashtir',
    parameters: { jsCode: BIRLASHTIR_JSCODE },
    position: [1560, 100]
  }
});

const httpSync = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'sync_aros_qarzdor',
    parameters: {
      method: 'POST',
      url: 'https://kxzerccdpcltmzrxutlo.supabase.co/rest/v1/rpc/sync_aros_qarzdor',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'supabaseApi',
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify({ p_data: $json }) }}',
      options: { timeout: 30000 }
    },
    credentials: { supabaseApi: newCredential('Supabase API') },
    position: [1820, 100]
  }
});

wf.add(schedule).to(sana);
wf.add(manual).to(sana);
wf.add(sana).to(sahifalar);
wf.add(sahifalar).to(getDebtors);
wf.add(getDebtors).to(yigish);
wf.add(yigish).to(keshLimit);
wf.add(keshLimit).to(birlashtir);
wf.add(birlashtir).to(httpSync);

export default wf;
