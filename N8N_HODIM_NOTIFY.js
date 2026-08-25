import { workflow, node, trigger, ifElse } from '@n8n/workflow-sdk';

const harDaqiqa = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.3,
  config: {
    name: 'Har Daqiqa',
    parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } },
    position: [-460, 0]
  },
  output: [{}]
});

const navbat = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Navbat',
    parameters: {
      method: 'POST',
      url: 'https://kxzerccdpcltmzrxutlo.supabase.co/rest/v1/rpc/hodim_notify_pending',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'supabaseApi',
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify({ p_limit: 50 }) }}',
      options: { timeout: 30000 }
    },
    alwaysOutputData: true,
    position: [-460, 220]
  },
  output: [{ items: [], adminlar: [] }]
});

const bormi = ifElse({
  version: 2.3,
  config: {
    name: 'Xabar Bormi',
    parameters: {
      conditions: {
        options: { caseSensitive: true, typeValidation: 'loose' },
        conditions: [{
          leftValue: '={{ ($json.items || []).length }}',
          operator: { type: 'number', operation: 'gt' },
          rightValue: 0
        }],
        combinator: 'and'
      },
      looseTypeValidation: true
    },
    position: [-240, 220]
  }
});

const userlar = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Aros Userlar',
    parameters: {
      operation: 'executeQuery',
      query: 'SELECT to_jsonb(u) AS u FROM users u WHERE u.telegram_id IS NOT NULL',
      options: {}
    },
    alwaysOutputData: true,
    position: [-20, 220]
  },
  output: [{ u: {} }]
});

const xabarTuz = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Xabar Tuz',
    parameters: {
      jsCode: `// Provodka navbati + Aros userlari -> Telegram xabarlari
var payload = $('Navbat').first().json || {};
var items = payload.items || [];
var adminlar = payload.adminlar || [];

// --- Aros users: taskfix_user_id -> telegram_id ---
// taskfix_user_id users.id bo'lishi ham, telegram_id bo'lishi ham mumkin.
// Ikkalasini ham indekslaymiz -- qaysi biri bo'lsa ham topiladi.
var byKey = {};
var uRows = $input.all();
for (var i = 0; i < uRows.length; i++) {
  var u = (uRows[i].json && uRows[i].json.u) ? uRows[i].json.u : uRows[i].json;
  if (!u || !u.telegram_id) continue;
  var tg = String(u.telegram_id);
  byKey[tg] = tg;
  if (u.id !== undefined && u.id !== null) byKey[String(u.id)] = tg;
  if (u.user_id !== undefined && u.user_id !== null) byKey[String(u.user_id)] = tg;
}

// Pul formati: probel bilan (Provodka uslubi) -- 12 100
function money(n) {
  var v = Math.round(Number(n) || 0);
  var neg = v < 0;
  var s = String(Math.abs(v));
  var out = '';
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 === 0) out += ' ';
    out += s[i];
  }
  return (neg ? '−' : '') + out;
}
// Valyuta uchun: tiyingacha (dollar sentlari yo'qolmasin)
function money2(n) {
  var v = Number(n) || 0;
  var neg = v < 0;
  v = Math.abs(v);
  var w = Math.floor(v);
  var f = Math.round((v - w) * 100);
  if (f === 100) { w += 1; f = 0; }
  var s = money(w);
  if (f > 0) s += '.' + (f < 10 ? '0' + f : String(f));
  return (neg ? '−' : '') + s;
}
// parse_mode HTML -- foydalanuvchi izohi teg bo'lib ketmasin
function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function sana(s) {
  var m = String(s || '').match(/^(\\d{4})-(\\d{2})-(\\d{2})/);
  return m ? (m[3] + '.' + m[2] + '.' + m[1]) : String(s || '');
}
var BOSH = {
  kirim:           '📥 <b>Kassaga pul kirdi</b>',
  chiqim:          '📤 <b>Kassadan pul chiqdi</b>',
  transfer_kirim:  '🔁 <b>Transfer — pul keldi</b>',
  transfer_chiqim: '🔁 <b>Transfer — pul ketdi</b>',
  tahrir:          '✏️ <b>Yozuv tahrirlandi</b>',
  ochirildi:       '🗑 <b>Yozuv o\\'chirildi</b>'
};
// Pul turi belgisi -- jurnal/kassa sahifalaridagi TURI_IKO bilan bir xil
var TURI = {
  naqd:     '💵 Naqd',
  click:    '💳 Click',
  payme:    '📱 Payme',
  terminal: '🏧 Terminal',
  karta:    '🏦 Karta',
  plastik:  '🏦 Plastik'
};

var out = [];
for (var k = 0; k < items.length; k++) {
  var it = items[k];
  var kirimmi = !!it.kirimmi;
  var t = '';
  function add(s) { t += s + '\\n'; }

  add(BOSH[it.hodisa] || ('🔔 <b>' + esc(it.hodisa) + '</b>'));

  var who = esc(it.kassa_nom || '');
  if (it.subtitle) who += ' · ' + esc(it.subtitle);
  add('👤 ' + who);
  add('');

  // Valyuta hisobi (USD...): asosiy raqam VALYUTADA -- hodim o'z ekranida
  // ham dollarni ko'radi (hodim-dev renderHero). So'm ekvivalenti qavsda,
  // u TARIXIY kursda hisoblangan, joriy kursda emas.
  // Tahrir/o'chirishda summa maydoni YOZUV summasi emas, QOLDIQ FARQI. Uni
  // "Summa" deb atash yolg'on bo'lardi (100k -> 50k tahririda farq 50k).
  var maxsus = (it.hodisa === 'tahrir' || it.hodisa === 'ochirildi');
  var lbl = (it.hodisa === 'ochirildi') ? (kirimmi ? 'Qaytdi' : 'Chiqdi')
          : (it.hodisa === 'tahrir') ? "O'zgarish" : 'Summa';
  var iko = maxsus ? '🔄' : '💰';

  var val = it.valyuta || 'UZS';
  var fcq = Number(it.fc_summa) || 0;
  if (val !== 'UZS' && fcq > 0) {
    add(iko + ' ' + lbl + ': <b>' + (kirimmi ? '+' : '−') + money2(fcq) + ' ' + esc(val) + '</b>');
    add('   ≈ ' + money(it.summa) + ' so\\'m');
  } else {
    add(iko + ' ' + lbl + ': <b>' + (kirimmi ? '+' : '−') + money(it.summa) + '</b> so\\'m');
  }
  if (it.qarshi_nom) {
    add('📂 ' + (it.qarshi_kod ? esc(it.qarshi_kod) + ' ' : '') + esc(it.qarshi_nom));
  }
  if (it.pul_turi) add(TURI[it.pul_turi] ? TURI[it.pul_turi] : esc(it.pul_turi));
  if (it.izoh) add('📝 ' + esc(it.izoh));
  add('');

  // "shuncha bor edi — shuncha ketti — shuncha qoldi"
  var q2 = maxsus ? (it.hodisa === 'ochirildi' ? (kirimmi ? 'Qaytdi  ' : 'Chiqdi  ')
                                               : "O'zgardi")
                  : (kirimmi ? 'Keldi   ' : 'Ketti   ');
  add('<code>Bor edi : ' + money(it.qoldiq_oldin) + '</code>');
  add('<code>' + q2 + ': ' + (kirimmi ? '+' : '−') + money(it.summa) + '</code>');
  add('<code>Qoldi   : ' + money(it.qoldiq_keyin) + '</code>');
  add('');

  var oyoq = '📅 ' + esc(sana(it.sana));
  if (it.kim) oyoq += ' · ✍️ ' + esc(it.kim);
  add(oyoq);

  var text = t.replace(/\\n+$/, '');

  // Qabul qiluvchilar: hodimning o'zi + adminlar (dublikatsiz)
  var chats = [];
  var seen = {};
  var hodimTg = it.taskfix_user_id ? byKey[String(it.taskfix_user_id)] : null;
  if (hodimTg) { chats.push(hodimTg); seen[hodimTg] = 1; }
  for (var a = 0; a < adminlar.length; a++) {
    var at = String(adminlar[a].telegram_id || '');
    if (at && !seen[at]) { chats.push(at); seen[at] = 1; }
  }

  for (var c = 0; c < chats.length; c++) {
    out.push({ json: { nid: it.id, chat_id: chats[c], text: text } });
  }
}

// Hech kimga yuborilmasa ham navbat qatorini yopamiz (aks holda 5 marta
// qayta urinilib, keyin jimgina qotib qolardi).
if (out.length === 0) {
  var bosh = [];
  for (var z = 0; z < items.length; z++) bosh.push(items[z].id);
  return [{ json: { __yoq: true, nid: null, bosh_ids: bosh } }];
}
return out;`
    },
    position: [200, 220]
  },
  output: [{ nid: 1, chat_id: '123', text: '...' }]
});

const yubor = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Telegram Yubor',
    parameters: {
      method: 'POST',
      url: 'https://api.telegram.org/bot8242619971:AAGKPdUtDSok_Ecw-fkblFUQJ8mGbLIeXxA/sendMessage',
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify({ chat_id: $json.chat_id, text: $json.text, parse_mode: "HTML", disable_web_page_preview: true }) }}',
      options: { timeout: 15000, response: { response: { neverError: true } } }
    },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [420, 220]
  },
  output: [{ ok: true }]
});

const natija = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Natija',
    parameters: {
      jsCode: `// Telegram javoblarini xabarlar bilan INDEKS bo'yicha juftlaymiz
// (HTTP node 1:1 chiqaradi, tartib saqlanadi).
var built = $('Xabar Tuz').all();
var res = $input.all();

// Hech kimga yuborilmagan hol: navbatni baribir yopamiz
if (built.length === 1 && built[0].json && built[0].json.__yoq) {
  return [{ json: {
    p_ids: built[0].json.bosh_ids || [],
    fail_ids: [],
    err: 'qabul qiluvchi topilmadi (taskfix_user_id -> telegram_id yoq, admin royxati bosh)'
  } }];
}

var ok = {}, bad = {}, err = '';
for (var i = 0; i < built.length; i++) {
  var nid = built[i].json.nid;
  if (nid === null || nid === undefined) continue;
  var r = res[i] ? res[i].json : null;
  var good = !!(r && (r.ok === true || r.result));
  if (good) { ok[nid] = 1; }
  else {
    bad[nid] = 1;
    if (!err) err = (r && (r.description || r.message || (r.error && r.error.message))) || 'telegram javob bermadi';
  }
}

// KAMIDA BITTA yuborilgan bo'lsa 'sent' qilamiz. Aks holda 5 urinishda
// ishlagan qabul qiluvchiga 5 ta bir xil xabar ketardi (Telegram xatosi
// odatda doimiy: user botga /start bosmagan -> 403).
var sent = [];
var fail = [];
for (var s in ok) sent.push(Number(s));
for (var f in bad) fail.push(Number(f));
return [{ json: { p_ids: sent, fail_ids: fail, err: String(err).slice(0, 300) } }];`
    },
    position: [640, 220]
  },
  output: [{ p_ids: [], fail_ids: [], err: '' }]
});

const belgila = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Yuborildi Belgila',
    parameters: {
      method: 'POST',
      url: 'https://kxzerccdpcltmzrxutlo.supabase.co/rest/v1/rpc/hodim_notify_sent',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'supabaseApi',
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify({ p_ids: $json.p_ids }) }}',
      options: { timeout: 30000 }
    },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [860, 220]
  },
  output: [{}]
});

const xato = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Xato Yoz',
    parameters: {
      method: 'POST',
      url: 'https://kxzerccdpcltmzrxutlo.supabase.co/rest/v1/rpc/hodim_notify_fail',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'supabaseApi',
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify({ p_ids: $(\'Natija\').first().json.fail_ids, p_err: $(\'Natija\').first().json.err }) }}',
      options: { timeout: 30000 }
    },
    onError: 'continueRegularOutput',
    alwaysOutputData: true,
    position: [1080, 220]
  },
  output: [{}]
});

export default workflow('aros-provodka-hodim-notify', 'Aros Provodka - Hodim Notify')
  .add(harDaqiqa)
  .to(navbat)
  .to(bormi.onTrue(userlar.to(xabarTuz.to(yubor.to(natija.to(belgila.to(xato)))))));

// ============================================================================
// Bu fayl BRAUZERGA YUKLANMAYDI — n8n Workflow SDK manbasi (versiya nazorati
// uchun repoda saqlanadi). Jonli workflow:
//   https://n8n.arosmarket.com/workflow/CuIA9H5oW4VrtnJv
// O'rnatish tartibi: HODIM_NOTIFY_DEPLOY.txt
// ⚠️ update_workflow kreditlarni uzadi — o'zgartirgandan keyin n8n'da
//    HAMMA node kreditini qayta tekshiring (Postgres ham).
// ⚠️ jsCode template literal ichida BACKTICK ishlatmang — u literalni yopadi.
// ============================================================================
