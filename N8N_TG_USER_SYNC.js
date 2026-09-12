// ============================================================================
// «Aros Provodka - Telegram User Sync» — n8n Workflow SDK kodi (2026-09-12)
// ----------------------------------------------------------------------------
// Bu fayl — REPO NUSXASI (manba). n8n'da yaratilgan (2026-09-12, MCP):
// `4OYBi80CdY2q6XcI` — hozircha NOFAOL. «Aros Userlar» ga Postgres account 3
// avtomatik ulandi; «sync_aros_tg_user» ga Supabase API krediti qo'lda ulanadi.
//
// NIMA UCHUN: hodim xarajat kassasi (54xx) `accounts.taskfix_user_id`
// orqali Aros userga bog'lanadi (PROVODKA_HODIM_TELEGRAM.sql,
// `hodim_tg_bogla`/`hodim_tg_avto_bogla`, sozlama-dev.html «Hodim →
// Telegram» kartasi). Bog'lash uchun avval Aros userlar ro'yxati
// Supabase'da bo'lishi kerak — bu workflow shu ro'yxatni har soat
// sinxronlaydi (`aros_tg_user`, `sync_aros_tg_user` RPC, service_role ONLY).
//
// 🔴 MAXFIY USTUNLAR KO'CHIRILMAYDI: Aros PG `users` jadvalida bor
// `password_hash`, `password_set_at`, `reset_code`, `reset_expires`,
// `telegram_id` — bularning BIRORTASI so'ralmaydi/yuborilmaydi. Bog'lash
// `users.id` (matn) orqali — n8n «Aros Provodka - Hodim Notify»
// (N8N_HODIM_NOTIFY.js `byKey`) buni `telegram_id`ga o'zi aylantiradi
// (`byKey[String(u.id)] = tg`), `telegram_id` bu workflow'ga UMUMAN KERAK
// EMAS.
//
// Tuzilma:
//   Har soat ──────────────┐
//   Qolda ishga tushirish  ┴─> Aros Userlar (Postgres) -> Payload yasash
//                              -> Qatorlar bormi? --true--> sync_aros_tg_user
//
// Asilbek qo'lda qiladi (yaratilgan workflow'da):
//   - «Aros Userlar» -> Postgres krediti («Postgres account 3» — mavjud,
//     N8N_AROS_QARZDOR_SYNC.js / N8N_HODIM_NOTIFY.js bilan bir xil kredit).
//   - «sync_aros_tg_user» -> Supabase API krediti (🔴 SERVICE ROLE kaliti —
//     RPC authenticated/anon'dan revoke qilingan, boshqa rol 42501 oladi).
//   - PROVODKA_HODIM_TELEGRAM.sql RUN qilingach -> Activate.
//   - «Qolda ishga tushirish» bilan bir marta test: oxirgi HTTP javobida
//     {ok:true, yozildi, yangilandi, nofaol, tashlandi} kelishi kerak.
//
// SDK qoidalari: faqat `const` (var taqiq — jsCode ICHIDA emas, tashqarida),
// template string, kredit `newCredential('Nom')`, oxirida `export default wf`.
// jsCode ichida arrow function YO'Q (CLAUDE.md) — faqat `function` sintaksisi
// va `var` (n8n Code node VM ichida ishlaydi, tashqi kod bilan izchillik uchun
// jsCode ham shu uslubda).
// ============================================================================

const USERLAR_SQL = `select id::text as user_id,
       ism,
       lavozim,
       warehouse_name,
       telefon,
       worker_id::text as worker_id,
       status::text as status
  from users`;

const YIGISH_JSCODE = `var items = $input.all();
var rows = [];
for (var i = 0; i < items.length; i++) {
  var r = items[i].json || {};
  if (r.user_id === null || r.user_id === undefined || String(r.user_id) === '') {
    continue;
  }
  rows.push({
    user_id: String(r.user_id),
    ism: r.ism || '',
    lavozim: r.lavozim || null,
    warehouse_name: r.warehouse_name || null,
    telefon: r.telefon || null,
    worker_id: (r.worker_id === null || r.worker_id === undefined) ? null : String(r.worker_id),
    status: r.status || null
  });
}
return [{ json: { rows: rows, count: rows.length } }];`;

const wf = workflow('aros-provodka-telegram-user-sync', 'Aros Provodka - Telegram User Sync');

const schedule = node({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.2,
  config: {
    name: 'Har Soat',
    parameters: { rule: { interval: [{ field: 'hours', hoursInterval: 1 }] } },
    position: [0, 0]
  }
});

const manual = node({
  type: 'n8n-nodes-base.manualTrigger',
  version: 1,
  config: { name: 'Qolda ishga tushirish', parameters: {}, position: [0, 200] }
});

const userlar = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Aros Userlar',
    parameters: { operation: 'executeQuery', query: USERLAR_SQL, options: { largeNumbersOutput: 'text' } },
    credentials: { postgres: newCredential('Postgres account 3') },
    alwaysOutputData: true,
    position: [260, 100]
  }
});

const yigish = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Payload Yasash',
    parameters: { jsCode: YIGISH_JSCODE },
    position: [520, 100]
  }
});

const bormi = ifElse({
  version: 2.3,
  config: {
    name: 'Qatorlar Bormi',
    parameters: {
      conditions: {
        options: { caseSensitive: true, typeValidation: 'loose' },
        conditions: [{
          leftValue: '={{ $json.count }}',
          operator: { type: 'number', operation: 'gt' },
          rightValue: 0
        }],
        combinator: 'and'
      },
      looseTypeValidation: true
    },
    position: [780, 100]
  }
});

const httpSync = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.2,
  config: {
    name: 'sync_aros_tg_user',
    parameters: {
      method: 'POST',
      url: 'https://kxzerccdpcltmzrxutlo.supabase.co/rest/v1/rpc/sync_aros_tg_user',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'supabaseApi',
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify({ p_rows: $json.rows }) }}',
      options: { timeout: 30000 }
    },
    credentials: { supabaseApi: newCredential('Supabase API') },
    position: [1040, 40]
  }
});

wf.add(schedule).to(userlar);
wf.add(manual).to(userlar);
wf.add(userlar).to(yigish);
wf.add(yigish).to(bormi.onTrue(httpSync));

export default wf;
