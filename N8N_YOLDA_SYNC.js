// ============================================================================
// «Aros Provodka - Yolda Sync» — n8n Workflow SDK kodi (2026-09-06)
// ----------------------------------------------------------------------------
// n8n'da YARATILGAN: workflow id xRARQu9MiZmQ1sAO
//   https://n8n.arosmarket.com/workflow/xRARQu9MiZmQ1sAO
// validate_workflow ✅ (5 node). Bu fayl — repo nusxasi (qayta yaratish uchun).
//
// ALOHIDA workflow. Mavjud «Transfer Sync v2» (iqtB5Jk2NHW2r82J) ga
// TEGILMAGAN — u pul yozadi (sync_transfer_balans), bu esa faqat REGISTR
// (aros_transfer_yolda, PROVODKA_YOLDA.sql) to'ldiradi. PUL HARAKATI YO'Q.
//
// Har 5 daqiqada Aros mirror (n8n Postgres, «Postgres account 3»)
// cachier_transfers dan: status != received (yo'lda) + so'nggi 14 kunda
// received bo'lganlar. Har transfer uchun sotuvchi sanagan
// (items[].document.seller_*) VA qabulda tasdiqlangan (items[].confirmed_*)
// summalar → sync_transfer_yolda RPC (service_role ONLY).
//
// Tuzilma:
//   Har 5 daqiqa ─────────┐
//   Qolda ishga tushirish ┴─> Transferlarni oqish (Aros PG) -> Payload yasash
//                              -> sync_transfer_yolda (HTTP POST)
//
// Asilbek qo'lda qiladi (yaratilgan workflow'da):
//   - Postgres node → «Postgres account 3» (yaratishda AVTOMAT ulandi)
//   - HTTP node «sync_transfer_yolda» → Supabase API krediti (🔴 SERVICE ROLE
//     kaliti — RPC authenticated'dan revoke qilingan, anon/user JWT 42501 oladi)
//   - PROVODKA_YOLDA.sql RUN qilingach → Activate.
//   - «Qolda ishga tushirish» bilan bir marta test: HTTP javobida
//     {ok:true, yozildi, yangilandi, nomalum, ogoh} kelishi kerak.
//
// SDK qoidalari: faqat `const` (var taqiq), template string (`.join` taqiq),
// kredit `newCredential('Nom')`, oxirida `export default wf`.
// jsCode ichida arrow function YO'Q (CLAUDE.md).
// `responsible` = cachiers.responsible (jo'natuvchi kassa mas'uli) deb olindi.
// ============================================================================

const YOLDA_SQL = `select t.id,
       t.status,
       t.sender_title,
       t.receiver_title,
       sc.id as sender_ref,
       rc.id as receiver_ref,
       sc.responsible as responsible,
       to_char(t.sent_at, 'YYYY-MM-DD"T"HH24:MI:SS') as sent_at,
       to_char(t.received_at, 'YYYY-MM-DD"T"HH24:MI:SS') as received_at,
       (select coalesce(sum(coalesce(((i->'document')->>'seller_cash')::numeric, 0)), 0)
          from jsonb_array_elements(t.items) i) as s_cash,
       (select coalesce(sum(coalesce(((i->'document')->>'seller_click')::numeric, 0)), 0)
          from jsonb_array_elements(t.items) i) as s_click,
       (select coalesce(sum(coalesce(((i->'document')->>'seller_payme')::numeric, 0)), 0)
          from jsonb_array_elements(t.items) i) as s_payme,
       (select coalesce(sum(coalesce(((i->'document')->>'seller_dollar')::numeric, 0)), 0)
          from jsonb_array_elements(t.items) i) as s_usd,
       (select coalesce(sum(coalesce((i->>'confirmed_cash')::numeric, 0)), 0)
          from jsonb_array_elements(t.items) i) as c_cash,
       (select coalesce(sum(coalesce((i->>'confirmed_click')::numeric, 0)), 0)
          from jsonb_array_elements(t.items) i) as c_click,
       (select coalesce(sum(coalesce((i->>'confirmed_payme')::numeric, 0)), 0)
          from jsonb_array_elements(t.items) i) as c_payme,
       (select coalesce(sum(coalesce((i->>'confirmed_dollar')::numeric, 0)), 0)
          from jsonb_array_elements(t.items) i) as c_usd,
       (select max(((i->'document')->>'currency_rate')::numeric)
          from jsonb_array_elements(t.items) i) as dollar_rate
  from cachier_transfers t
  left join cachiers sc on sc.title = t.sender_title and sc.is_kassa = false
  left join cachiers rc on rc.title = t.receiver_title and rc.is_kassa = true
 where t.status <> 'received'
    or (t.received_at is not null
        and t.received_at >= (now() at time zone 'Asia/Tashkent') - interval '14 days')
 order by t.id`;

const BUILD_PAYLOAD_JSCODE = `function fixTz(v) {
  if (v === null || v === undefined || v === "") return null;
  var s = String(v);
  if (/[Zz]|[+-]\\d{2}:?\\d{2}$/.test(s)) return s;
  return s + "+05:00";
}
function num(v) {
  if (v === null || v === undefined || v === "") return 0;
  var n = Number(v);
  return isNaN(n) ? 0 : n;
}
var rows = $input.all();
var transferlar = [];
for (var i = 0; i < rows.length; i++) {
  var r = rows[i].json || {};
  var status = String(r.status || "nomalum").toLowerCase();
  var isReceived = status === "received";
  var item = {
    id: r.id,
    status: status,
    sender_title: r.sender_title || null,
    receiver_title: r.receiver_title || null,
    sender_ref: (r.sender_ref !== null && r.sender_ref !== undefined) ? String(r.sender_ref) : null,
    receiver_ref: (r.receiver_ref !== null && r.receiver_ref !== undefined) ? String(r.receiver_ref) : null,
    sent_at: fixTz(r.sent_at),
    received_at: fixTz(r.received_at),
    seller: { cash: num(r.s_cash), click: num(r.s_click), payme: num(r.s_payme), dollar_usd: num(r.s_usd) },
    confirmed: isReceived ? { cash: num(r.c_cash), click: num(r.c_click), payme: num(r.c_payme), dollar_usd: num(r.c_usd) } : null,
    dollar_rate: (r.dollar_rate !== null && r.dollar_rate !== undefined && r.dollar_rate !== "") ? Number(r.dollar_rate) : null,
    responsible: r.responsible || null
  };
  transferlar.push(item);
}
return [{ json: { transferlar: transferlar, soni: transferlar.length } }];`;

const wf = workflow('aros-provodka-yolda-sync', 'Aros Provodka - Yolda Sync');

const schedule = node({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.2,
  config: {
    name: 'Har 5 daqiqa',
    parameters: { rule: { interval: [ { field: 'minutes', minutesInterval: 5 } ] } },
    position: [0, 0]
  }
});

const manual = node({
  type: 'n8n-nodes-base.manualTrigger',
  version: 1,
  config: { name: 'Qolda ishga tushirish', parameters: {}, position: [0, 200] }
});

const pg = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Transferlarni oqish (Aros PG)',
    parameters: { operation: 'executeQuery', query: YOLDA_SQL, options: { largeNumbersOutput: 'text' } },
    credentials: { postgres: newCredential('Postgres account 3') },
    position: [260, 100]
  }
});

const buildPayload = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: { name: 'Payload yasash', parameters: { jsCode: BUILD_PAYLOAD_JSCODE }, position: [520, 100] }
});

const http = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'sync_transfer_yolda',
    parameters: {
      method: 'POST',
      url: 'https://kxzerccdpcltmzrxutlo.supabase.co/rest/v1/rpc/sync_transfer_yolda',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'supabaseApi',
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify({ p_data: $json.transferlar }) }}',
      options: { timeout: 60000 }
    },
    credentials: { supabaseApi: newCredential('Supabase API') },
    position: [780, 100]
  }
});

wf.add(schedule).to(pg);
wf.add(manual).to(pg);
wf.add(pg).to(buildPayload);
wf.add(buildPayload).to(http);

export default wf;
