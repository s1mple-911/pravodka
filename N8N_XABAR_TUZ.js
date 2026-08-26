// ============================================================================
// Aros Provodka — Hodim Notify · Xabar Tuz (n8n Code node, version 2)
//
// QAYERGA: https://n8n.arosmarket.com/workflow/CuIA9H5oW4VrtnJv
//          -> Xabar Tuz node -> JavaScript maydoni: HAMMASINI tanlab,
//          shu faylning TO'LIQ mazmuni bilan almashtiriladi (bu izoh ham).
//
// NEGA QO'LDA, MCP orqali emas: update_workflow har chaqirilganda qo'lda
// ulangan kreditlarni uzadi (CLAUDE.md — "n8n bilan ishlash"). Bu workflow'da
// 3 ta Supabase HTTP node (Navbat, Yuborildi Belgila, Xato Yoz) va
// Postgres node (Aros Userlar) bor — bitta matn o'zgarishi uchun ularni
// qayta ulash arzimaydi. Repodagi nusxa: N8N_HODIM_NOTIFY.js ichidagi
// xabarTuz.jsCode — ayni shu matn (bayt-ma-bayt).
//
// Kirish: Navbat (hodim_notify_pending) + Aros Userlar (telegram_id).
// Chiqish: { nid, chat_id, text } — Telegram Yubor parse_mode: HTML.
// ⚠️ Arrow function YO'Q, faqat function (n8n Code node qoidasi).
// ⚠️ HTML rejim: har foydalanuvchi matni (izoh, ism, kassa/hisob nomi) esc().
// ============================================================================

// Provodka navbati + Aros userlari -> Telegram xabarlari
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
  var m = String(s || '').match(/^(\d{4})-(\d{2})-(\d{2})/);
  return m ? (m[3] + '.' + m[2] + '.' + m[1]) : String(s || '');
}
// <code> ustunlarini tekislash uchun. right=true -> o'ngga tekislanadi.
function pad(s, w, right) {
  var r = String(s == null ? '' : s);
  while (r.length < w) { r = right ? (' ' + r) : (r + ' '); }
  return r;
}

// Sarlavha: rangli nuqta (yo'nalish) + amal ikonkasi (nima bo'ldi) + qalin
// matn. Ranglar Provodka jurnali tasnifi bilan bir xil: yashil kirim,
// qizil chiqim, ko'k transfer.
var BOSH = {
  kirim:           '🟢 📥 <b>Kirim</b>',
  chiqim:          '🔴 📤 <b>Chiqim</b>',
  transfer_kirim:  '🔵 🔁 <b>Transfer · kirim</b>',
  transfer_chiqim: '🔵 🔁 <b>Transfer · chiqim</b>',
  tahrir:          '🟡 ✏️ <b>Tahrir</b>',
  ochirildi:       '⚫ 🗑 <b>O\'chirildi</b>'
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
  var ishora = kirimmi ? '+' : '−';
  var t = '';
  function add(s) { t += s + '\n'; }

  // 1) Sarlavha + kim/qayer
  add(BOSH[it.hodisa] || ('⚪ 🔔 <b>' + esc(it.hodisa) + '</b>'));
  var who = esc(it.kassa_nom || '');
  if (it.subtitle) who += ' · ' + esc(it.subtitle);
  add('👤 ' + who);
  add('');

  // 2) Summa -- eng katta raqam, qalin.
  // Valyuta hisobi (USD...): asosiy raqam VALYUTADA -- hodim o'z ekranida
  // ham dollarni ko'radi (hodim-dev renderHero). So'm ekvivalenti pastda,
  // u TARIXIY kursda hisoblangan, joriy kursda emas.
  // Tahrir/o'chirishda summa yozuv summasi emas, QOLDIQ FARQI -- shuning
  // uchun ikonka boshqa (🔄) va izohi pastdagi <code> yorlig'ida ("O'zgardi").
  var maxsus = (it.hodisa === 'tahrir' || it.hodisa === 'ochirildi');
  var iko = maxsus ? '🔄' : '💰';
  var val = it.valyuta || 'UZS';
  var fcq = Number(it.fc_summa) || 0;
  if (val !== 'UZS' && fcq > 0) {
    add(iko + ' <b>' + ishora + money2(fcq) + ' ' + esc(val) + '</b>');
    add('   ≈ ' + money(it.summa) + ' so\'m');
  } else {
    add(iko + ' <b>' + ishora + money(it.summa) + ' so\'m</b>');
  }

  // 3) Qarshi tomon + pul turi -- BITTA qator. Bittasi bo'lmasa o'zi tushib
  //    qoladi, ikkalasi ham yo'q bo'lsa qator umuman chizilmaydi.
  var qism = [];
  if (it.qarshi_nom) {
    qism.push('📂 ' + (it.qarshi_kod ? esc(it.qarshi_kod) + ' ' : '') + esc(it.qarshi_nom));
  }
  if (it.pul_turi) qism.push(TURI[it.pul_turi] ? TURI[it.pul_turi] : esc(it.pul_turi));
  if (qism.length) add(qism.join(' · '));
  if (it.izoh) add('📝 ' + esc(it.izoh));
  add('');

  // 4) "shuncha bor edi -- shuncha ketti -- shuncha qoldi"
  // 🔴 Ustunlar TEKIS: yorliq o'ngdan bo'sh joy bilan, raqam chapdan --
  //    <code> monoshrift, shuning uchun uch qator bir chiziqda turadi.
  //    Bu blok jadval -- ichiga ikonka QO'YILMAYDI (tekislik buziladi).
  var q2 = maxsus ? (it.hodisa === 'ochirildi' ? (kirimmi ? 'Qaytdi' : 'Chiqdi') : 'O\'zgardi')
                  : (kirimmi ? 'Keldi' : 'Ketti');
  var yorliq = ['Bor edi', q2, 'Qoldi'];
  var raqam = [money(it.qoldiq_oldin), ishora + money(it.summa), money(it.qoldiq_keyin)];
  var yw = 0, rw = 0;
  for (var y = 0; y < 3; y++) {
    if (yorliq[y].length > yw) yw = yorliq[y].length;
    if (raqam[y].length > rw) rw = raqam[y].length;
  }
  for (var r2 = 0; r2 < 3; r2++) {
    add('<code>' + pad(yorliq[r2], yw, false) + '    ' + pad(raqam[r2], rw, true) + '</code>');
  }
  add('');

  // 5) Oyoq: hodisa sanasi + vaqti · kim.
  // 🔴 hodisa_sana/vaqt — PROVODKA_NOTIFY_TOLIQ.sql bilan qo'shiladi. SQL
  //    hali RUN qilinmagan bo'lsa ular undefined keladi -> eski xatti-harakat
  //    (buxgalteriya sanasi, vaqtsiz). Shakl ham tekshiriladi: xom qiymat
  //    ("undefined", null, bo'sh...) xabarga hech qachon tushmaydi.
  // 🔴 sana (entry_date) QO'LDA tanlanadi va hodisa kunidan farq qilishi
  //    mumkin -> farq bo'lsa alohida yoziladi (jurnal-dev .j-oth naqshi),
  //    aks holda "25.08.2026 14:30" yolg'on juftlik bo'lib ko'rinardi.
  var hodSana = /^\d{2}\.\d{2}\.\d{4}$/.test(String(it.hodisa_sana || '')) ? String(it.hodisa_sana) : '';
  var soat = /^\d{2}:\d{2}$/.test(String(it.vaqt || '')) ? String(it.vaqt) : '';
  var buxSana = sana(it.sana);
  // 🔴 Ikonka VAQT bor-yo'qligiga qarab: soat ko'rsatilsa 🕒, faqat sana bo'lsa
  //    📅. Aks holda "soat ikonkasi bor, soat yo'q" degan chalkash holat chiqardi
  //    (SQL hali RUN qilinmagan bazada aynan shunday bo'ladi).
  var oyoq = (soat && hodSana ? '🕒 ' : '📅 ')
           + esc(hodSana ? (hodSana + (soat ? ' ' + soat : '')) : buxSana);
  if (hodSana && buxSana && buxSana !== hodSana) oyoq += ' · hisob sanasi ' + esc(buxSana);
  if (it.kim) oyoq += ' · ✍️ ' + esc(it.kim);
  add(oyoq);

  var text = t.replace(/\n+$/, '');

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
return out;
