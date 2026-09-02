// ============================================================================
// Aros Provodka — Qarz Notify · Xabar Tuz (n8n Code node, version 2)
//
// QAYERGA: yangi workflow «Aros Provodka - Qarz Notify» (alohida, kichik):
//   Schedule (5 daq) -> Navbat (Supabase RPC qarz_notify_pending, service_role)
//   -> Xabar Tuz (SHU KOD) -> Telegram Yubor (parse_mode HTML)
//   -> Belgila (Supabase RPC qarz_notify_belgila {p_ids:[...]})
//   Kunlik eslatma: Schedule (09:00 Toshkent) -> RPC qarz_eslatma_navbat -> (o'sha navbat oladi).
//
// Kirish: Navbat (qarz_notify_pending) — { items:[...], adminlar:[{telegram_id, ism}] }.
// Chiqish: { nid, chat_id, text } — HAR admin uchun HAR item (faqat adminlar oladi).
// ⚠️ Arrow function YO'Q, faqat function (n8n Code node qoidasi).
// ⚠️ HTML rejim: har foydalanuvchi matni (ism, kassa nomi, izoh) esc().
// PROVODKA_QARZ.sql 21-bo'lim: item = {id, hodisa, qarz_id, tolov_id, vaqt} + data
//   (qarzdor_ism, qarzdor_familya, qarzdor_tur, kassa_kod, kassa_nom, summa, currency,
//    muddat_matni, qolgan, kim_nom, tolov_summa?, tolov_kassa_nom?) ;
//   hodisa='eslatma' -> data = {items:[{qarzdor_ism, qarzdor_familya, qarzdor_tur,
//    kassa_kod, kassa_nom, sana, summa, holat}], soni}.
// ============================================================================

var payload = $('Navbat').first().json || {};
if (payload.body && !payload.items) payload = payload.body;   // HTTP node o'rami
var items = payload.items || [];
var adminlar = payload.adminlar || [];

function money(n) {
  var v = Math.round(Number(n) || 0);
  var neg = v < 0; if (neg) v = -v;
  var s = String(v);
  var out = '';
  while (s.length > 3) { out = ' ' + s.slice(-3) + out; s = s.slice(0, -3); }
  out = s + out;
  return (neg ? '−' : '') + out;
}
function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function ism(it) {
  var t = [it.qarzdor_ism, it.qarzdor_familya].filter(function (x) { return x; }).join(' ');
  return esc(t || '—');
}
function tur(it) { return it.qarzdor_tur === 'ichki' ? 'hodim' : 'tashqi'; }
function kassa(it) {
  return (it.kassa_kod ? esc(it.kassa_kod) + ' ' : '') + esc(it.kassa_nom || '');
}
function sana(s) {
  // 'YYYY-MM-DD' -> 'DD.MM.YYYY'
  var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(s || ''));
  return m ? (m[3] + '.' + m[2] + '.' + m[1]) : esc(s);
}

var SARL = {
  draft_yaratildi: '📝 <b>Qarz — tilxat kutilmoqda</b>',
  tilxat_yuklandi: '🖊️ <b>Tilxat yuklandi</b>',
  berildi:         '💸 <b>Qarz berildi</b>',
  tolov:           '💵 <b>Qarz to\'lovi tushdi</b>',
  yopildi:         '✅ <b>Qarz to\'liq yopildi</b>',
  bekor:           '🚫 <b>Qarz so\'rovi bekor qilindi</b>',
  eslatma:         '⏰ <b>Qarz eslatmasi</b>'
};

function tuz(it) {
  var t = '';
  function add(s) { t += s + '\n'; }
  var h = it.hodisa || '';
  add(SARL[h] || ('ℹ️ <b>Qarz: ' + esc(h) + '</b>'));

  if (h === 'eslatma') {
    var rows = (it.items || []);
    var kech = [], bugun = [];
    for (var i = 0; i < rows.length; i++) {
      (rows[i].holat === 'kechikkan' ? kech : bugun).push(rows[i]);
    }
    if (!rows.length) { add('Bugun muddati kelgan qarz yo\'q.'); return t; }
    if (bugun.length) {
      add('');
      add('📅 <b>Bugun muddati:</b> ' + bugun.length + ' ta');
      for (var b = 0; b < bugun.length; b++) {
        add('• ' + ism(bugun[b]) + ' (' + tur(bugun[b]) + ') — <b>' + money(bugun[b].summa) + '</b> so\'m');
      }
    }
    if (kech.length) {
      add('');
      add('🔴 <b>Kechikkan:</b> ' + kech.length + ' ta');
      for (var k = 0; k < kech.length; k++) {
        add('• ' + ism(kech[k]) + ' (' + tur(kech[k]) + ') — <b>' + money(kech[k].summa) + '</b> so\'m · ' + sana(kech[k].sana));
      }
    }
    return t;
  }

  add('👤 ' + ism(it) + ' · ' + tur(it));
  add('');
  if (h === 'tolov' || h === 'yopildi') {
    if (it.tolov_summa != null) add('💰 <b>+' + money(it.tolov_summa) + ' so\'m</b>' + (it.tolov_kassa_nom ? ' → ' + esc(it.tolov_kassa_nom) : ''));
    add('Qarz: ' + money(it.summa) + ' so\'m · Qoldi: <b>' + money(it.qolgan) + '</b> so\'m');
  } else {
    add('💰 <b>' + money(it.summa) + ' so\'m</b>');
    add('🏦 ' + kassa(it));
  }
  if (it.muddat_matni) add('📆 ' + esc(it.muddat_matni));
  if (h === 'draft_yaratildi') add('Tilxat rasmi yuklanmaguncha pul chiqmaydi.');
  if (h === 'bekor' && it.sabab) add('Sabab: ' + esc(it.sabab));
  add('');
  add('🕒 ' + esc(it.vaqt || '') + (it.kim_nom ? ' · ✍️ ' + esc(it.kim_nom) : ''));
  return t;
}

var out = [];
for (var i = 0; i < items.length; i++) {
  var it = items[i];
  var text = tuz(it);
  var seen = {};
  for (var a = 0; a < adminlar.length; a++) {
    var at = String(adminlar[a].telegram_id || '');
    if (!at || seen[at]) continue;
    seen[at] = true;
    out.push({ json: { nid: it.id, chat_id: at, text: text } });
  }
}
return out;
