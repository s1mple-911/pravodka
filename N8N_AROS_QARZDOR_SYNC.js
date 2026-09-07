// ============================================================================
// «Aros Provodka - Aros Qarzdor Sync» — n8n Workflow SDK kodi (2026-09-07)
// n8n'da YARATILGAN (2026-09-07): workflow id i91Kfmp7Orm55leW — https://n8n.arosmarket.com/workflow/i91Kfmp7Orm55leW
// validate_workflow OK (7 node). Asilbek kreditlarni (Aros Basic Auth, Supabase API
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
//                              -> Yig' -> sync_aros_qarzdor (HTTP POST)
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
    position: [1300, 100]
  }
});

wf.add(schedule).to(sana);
wf.add(manual).to(sana);
wf.add(sana).to(sahifalar);
wf.add(sahifalar).to(getDebtors);
wf.add(getDebtors).to(yigish);
wf.add(yigish).to(httpSync);

export default wf;
