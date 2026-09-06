// «Aros Provodka - Yuk Detail API» — n8n Workflow SDK kodi (2026-09-06)
// n8n'da YARATILGAN: yZkGLRDs1ujk8EFo — https://n8n.arosmarket.com/workflow/yZkGLRDs1ujk8EFo
// GET /webhook/aros-provodka-yuk-detail?id=2794 → {ok:true, detail:{…Aros product-incomes/{id}/ xom javobi…}}
// Maqsad: hujjat tafsiloti (bojxona qatorlari) ni ko'rish — AROS_YUK_DETAIL_API.md.
// Kredit: «Get Product Income» → Aros Basic Auth (Asilbek uladi). Kredit nomi n8n'da boshqacha bo'lsa qo'lda tanlanadi.
// SDK qoidalari: const, template string, newCredential, export default.

const wf = workflow('aros-provodka-yuk-detail', 'Aros Provodka - Yuk Detail API');

const hook = node({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: {
    name: 'Webhook Yuk Detail',
    parameters: { path: 'aros-provodka-yuk-detail', responseMode: 'responseNode', options: { allowedOrigins: '*' } },
    position: [0, 0]
  }
});

const prep = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Prep Id',
    parameters: { jsCode: `var q = $('Webhook Yuk Detail').first().json.query || {};
var id = String(q.id || '').replace(/[^0-9]/g, '');
if (!id) { return [{ json: { ok: false, error: 'id kerak', id: '' } }]; }
return [{ json: { ok: true, id: id } }];` },
    position: [220, 0]
  }
});

const get = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Get Product Income',
    parameters: {
      url: "={{ 'https://api.aros.uz/api/admin/v3/product-incomes/' + $json.id + '/' }}",
      authentication: 'genericCredentialType',
      genericAuthType: 'httpBasicAuth',
      options: { timeout: 60000 }
    },
    credentials: { httpBasicAuth: newCredential('Aros Basic Auth') },
    position: [440, 0]
  }
});

const build = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Detail',
    parameters: { jsCode: `var d = $input.first().json || {};
return [{ json: { ok: true, detail: d } }];` },
    position: [660, 0]
  }
});

const respond = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Respond Detail',
    parameters: {
      respondWith: 'json',
      responseBody: '={{ JSON.stringify($json) }}',
      options: { responseHeaders: { entries: [ { name: 'Access-Control-Allow-Origin', value: '*' }, { name: 'Access-Control-Allow-Methods', value: 'GET, OPTIONS' }, { name: 'Access-Control-Allow-Headers', value: 'Content-Type' } ] } }
    },
    position: [880, 0]
  }
});

wf.add(hook).to(prep);
wf.add(prep).to(get);
wf.add(get).to(build);
wf.add(build).to(respond);

export default wf;
