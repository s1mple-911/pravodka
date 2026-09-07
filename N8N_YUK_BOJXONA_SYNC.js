// ============================================================================
// «Aros Provodka - Yuk Bojxona Sync» — n8n Workflow SDK kodi (2026-09-06)
// n8n'da YARATILGAN (2026-09-06): workflow id yFKvjPrdBWCciaTK — https://n8n.arosmarket.com/workflow/yFKvjPrdBWCciaTK
// validate_workflow OK (8 node). Kreditlar (Aros Basic Auth x2, Supabase API service_role) — Asilbek qo'lda ulaydi, keyin Activate.
// ----------------------------------------------------------------------------
// Fable validate_workflow bilan tekshiradi -> create_workflow_from_code bilan
// yaratadi. Asilbek kreditlarni (Aros Basic Auth, Supabase API) tekshirib
// Activate qiladi. Bu fayl — repo nusxasi (qayta yaratish/tahrirlash uchun).
//
// ALOHIDA workflow. Mavjud «Aros Provodka - Yuklar API» (yuklar rojxatini
// olib turadigan workflow) ga TEGILMAGAN — bu faqat bitta yangi jadvalga
// (`aros_yuk_bojxona`, PROVODKA_YUK_BOJXONA.sql) yozadi. PUL HARAKATI YOQ.
//
// Nima qiladi: har 30 daqiqada Aros product-income ro'yxatini oladi (oxirgi
// 30 kun, faqat 'posted'), har biri uchun DETAIL API'ni chaqiradi
// (product_income_items ichida bojxona/yol foizi bor), bojxona (+ yol foizi)
// summasini hisoblaydi va sync_yuk_bojxona RPC (service_role ONLY) orqali
// yozadi. Bu summa keyin yuk_tannarx_qosh() ichida LIMIT sifatida
// ishlatiladi (PROVODKA_YUK_BOJXONA.sql 6-BOLIM).
//
// Tuzilma:
//   Har 30 daqiqa ─────────┐
//   Qolda ishga tushirish  ┴─> Sana Oraligi -> Get Product Incomes
//                              -> Split Ids -> Get Detail (batch 5/2500ms)
//                              -> Hisobla -> sync_yuk_bojxona (HTTP POST)
//
// Asilbek qolda qiladi (yaratilgan workflow'da):
//   - «Get Product Incomes» va «Get Detail» -> Aros Basic Auth krediti
//     (genericCredentialType/httpBasicAuth, api.aros.uz uchun).
//   - «sync_yuk_bojxona» -> Supabase API krediti (🔴 SERVICE ROLE kaliti —
//     RPC authenticated'dan revoke qilingan, anon/user JWT 42501 oladi).
//   - PROVODKA_YUK_BOJXONA.sql RUN qilingach -> Activate.
//   - «Qolda ishga tushirish» bilan bir marta test: oxirgi HTTP javobida
//     {ok:true, yozildi, yangilandi, ogoh:[]} kelishi kerak.
//
// 🔴 Aros rate-limit sabogi (CLAUDE.md, "Andijon yoqolishi"): api.aros.uz
// tez-tez so'ralsa "Request was throttled" (jimgina "bosh" natija bolib
// otib ketishi mumkin) qaytarishi mumkin — shuning uchun «Get Detail»
// batch 5 ta / 2500ms interval bilan chaqiriladi va onError bilan bitta
// yukning xatosi butun oqimni toxtatmaydi.
//
// 🔴 n8n BUG (2026-09-07): HTTP Request node «Items per Batch = 1» da ABADIY osilib qoladi —
// 49 id bilan 2 daqiqada ham tugamadi, prod executionlar 15 soat «running» turdi. Batch 5 / 2500ms
// bilan 49 detail ~25 soniyada keladi (48 yuk yozildi, 2794 = 600 000). Batch 1 ga QAYTARMA.
// n8n UI da qo'lda tuzatilgan (kreditlar saqlanib qoldi); bu fayl shu holatga moslangan.
// SDK qoidalari: faqat `const` (var taqiq), template string (`.join` taqiq),
// kredit `newCredential('Nom')`, oxirida `export default wf`.
// jsCode ichida arrow function YOQ (CLAUDE.md).
// ============================================================================

const SANA_ORALIGI_JSCODE = `function pad(n) {
  return n < 10 ? "0" + n : String(n);
}
function fmt(d) {
  return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate());
}
// Toshkent vaqti (UTC+5) — CLAUDE.md getUTC* naqshi bilan.
var now = new Date(Date.now() + 5 * 3600 * 1000);
var from = new Date(now.getTime() - 30 * 24 * 3600 * 1000);
return [{ json: { date_from: fmt(from), date_to: fmt(now) } }];`;

const SPLIT_IDS_JSCODE = `function num(v) {
  if (v === null || v === undefined || v === "") return null;
  var n = Number(v);
  return isNaN(n) ? null : n;
}
var body = $input.first().json || {};
var results = body.results || body.data || [];
if (!Array.isArray(results)) {
  results = [];
}
var out = [];
for (var i = 0; i < results.length; i++) {
  var r = results[i] || {};
  var status = String(r.status || "").toLowerCase();
  if (status !== "posted") {
    continue;
  }
  var id = num(r.id);
  if (id === null) {
    continue;
  }
  out.push({ json: { id: id } });
}
return out;`;

const HISOBLA_JSCODE = `function num(v) {
  if (v === null || v === undefined || v === "") return 0;
  var n = Number(v);
  return isNaN(n) ? 0 : n;
}
function numOrNull(v) {
  if (v === null || v === undefined || v === "") return null;
  var n = Number(v);
  return isNaN(n) ? null : n;
}

var rows = $input.all();
var splitRows = $("Split Ids").all();
var yuklar = [];
var tashlandi = 0;

for (var i = 0; i < rows.length; i++) {
  try {
    var r = rows[i].json || {};
    var srcId = (splitRows[i] && splitRows[i].json) ? splitRows[i].json.id : null;
    var id = numOrNull(r.id);
    if (id === null) {
      id = srcId;
    }
    if (id === null || id === undefined) {
      tashlandi = tashlandi + 1;
      continue;
    }

    var items = r.product_income_items;
    if (!Array.isArray(items)) {
      items = [];
    }

    var qtyJami = 0;
    var itemBojxona = 0;
    var fareCur = 0;
    var maxFarePct = null;

    for (var j = 0; j < items.length; j++) {
      var it = items[j] || {};
      var qty = num(it.quantity);
      qtyJami = qtyJami + qty;
      itemBojxona = itemBojxona + num(it.custom_clearance_uzs) * qty;
      var diff = num(it.price_after_fare_percent) - num(it.income_price);
      fareCur = fareCur + diff * qty;
      var fp = numOrNull(it.fare_percent);
      if (fp !== null && (maxFarePct === null || fp > maxFarePct)) {
        maxFarePct = fp;
      }
    }

    // Hujjat darajasidagi qiymatlar — hammaga bir xil bolganda (ba'zi
    // yuklarda item darajasi bosh keladi).
    var docCustom = numOrNull(r.custom_clearance_uzs);
    var docFarePct = numOrNull(r.fare_percent);

    var bojxonaUzs = 0;
    var rejim = "yoq";
    if (itemBojxona > 0) {
      bojxonaUzs = itemBojxona;
      rejim = "item";
    } else if (docCustom !== null && docCustom > 0) {
      // Zaxira: hujjat darajasidagi bojxona bir dona narx deb olinadi.
      bojxonaUzs = docCustom * qtyJami;
      rejim = "doc";
    }

    var farePercent = docFarePct !== null ? docFarePct : maxFarePct;
    var currency = (r.currency && r.currency.name) ? String(r.currency.name) : null;

    yuklar.push({
      yuk_id: id,
      currency: currency,
      document_price: numOrNull(r.document_price),
      qty_jami: qtyJami,
      items_n: items.length,
      bojxona_uzs: Math.round(bojxonaUzs * 100) / 100,
      fare_cur: Math.round(fareCur * 100) / 100,
      fare_percent: farePercent,
      doc_custom_uzs: docCustom,
      rejim: rejim,
      status: r.status || null,
      delivery_status: r.delivery_status || null,
      post_at: r.post_at || null
    });
  } catch (e) {
    tashlandi = tashlandi + 1;
    continue;
  }
}

return [{ json: { yuklar: yuklar, soni: yuklar.length, tashlandi: tashlandi } }];`;

const wf = workflow('aros-provodka-yuk-bojxona-sync', 'Aros Provodka - Yuk Bojxona Sync');

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

const sanaOraligi = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Sana Oraligi',
    parameters: { jsCode: SANA_ORALIGI_JSCODE },
    position: [260, 100]
  }
});

const getList = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'Get Product Incomes',
    parameters: {
      method: 'GET',
      url: '={{ "https://api.aros.uz/api/admin/v3/product-incomes/?page=1&page_size=500&search=&ordering=-1&date_from=" + $json.date_from + "&date_to=" + $json.date_to }}',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpBasicAuth',
      options: { timeout: 30000 }
    },
    credentials: { httpBasicAuth: newCredential('Aros Basic Auth') },
    position: [520, 100]
  }
});

const splitIds = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Split Ids',
    parameters: { jsCode: SPLIT_IDS_JSCODE },
    position: [780, 100]
  }
});

const getDetail = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'Get Detail',
    parameters: {
      method: 'GET',
      url: '={{ "https://api.aros.uz/api/admin/v3/product-incomes/" + $json.id + "/" }}',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpBasicAuth',
      options: {
        batching: { batch: { batchSize: 5, batchInterval: 2500 } },
        timeout: 30000
      }
    },
    credentials: { httpBasicAuth: newCredential('Aros Basic Auth') },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [1040, 100]
  }
});

const hisobla = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Hisobla',
    parameters: { jsCode: HISOBLA_JSCODE },
    position: [1300, 100]
  }
});

const httpSync = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'sync_yuk_bojxona',
    parameters: {
      method: 'POST',
      url: 'https://kxzerccdpcltmzrxutlo.supabase.co/rest/v1/rpc/sync_yuk_bojxona',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'supabaseApi',
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify({ p_data: { yuklar: $json.yuklar } }) }}',
      options: { timeout: 30000 }
    },
    credentials: { supabaseApi: newCredential('Supabase API') },
    position: [1560, 100]
  }
});

wf.add(schedule).to(sanaOraligi);
wf.add(manual).to(sanaOraligi);
wf.add(sanaOraligi).to(getList);
wf.add(getList).to(splitIds);
wf.add(splitIds).to(getDetail);
wf.add(getDetail).to(hisobla);
wf.add(hisobla).to(httpSync);

export default wf;
