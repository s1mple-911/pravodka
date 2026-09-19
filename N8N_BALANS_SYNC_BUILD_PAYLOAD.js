// n8n «Aros Provodka - Balans Sync» (5TB7ekGcBlU5qVZ0) → «Build Payload» Code node.
// 2026-09-19: Aros cachier detail `balances[]` shakli o'zgardi. Ikkala shakl ham o'qiladi:
//   ESKI:  {label: 'cash_balance'|'click_balance'|'payme_balance'|'dollar_balance', balance}
//   YANGI: {label: {code: 'cash_balance'|'click_balance'|'dollar_balance'|'terminal', title...}, balance: '0.00', currency_name}
// 🔴 Pul yo'lida JIMGINA 0 YO'Q: noma'lum label (summasi 0 dan katta) bo'lsa XATO — sync to'xtaydi, ko'rinadi.
const rows = $input.all().map(function(i){ return i.json; });
function num(v){ if (v === null || v === undefined || v === '') return null; const n = parseFloat(String(v)); return isNaN(n) ? null : n; }
let usdRate = null;
try {
  const rd = $('Get Currency Rates').all().map(function(i){ return i.json; });
  let rlist = [];
  for (let k = 0; k < rd.length; k++) {
    const r = rd[k];
    if (r && Array.isArray(r.results)) { rlist = rlist.concat(r.results); }
    else if (r && Array.isArray(r)) { rlist = rlist.concat(r); }
    else if (r && r.rate != null) { rlist.push(r); }
  }
  for (let m = 0; m < rlist.length; m++) {
    const it = rlist[m];
    const bc = it && it.base_currency ? it.base_currency.name : '';
    const tc = it && it.target_currency ? it.target_currency.name : '';
    if (bc === 'USD' && tc === 'UZS') { const rr = num(it.rate); if (rr) { usdRate = rr; break; } }
  }
} catch (e) { usdRate = null; }

const MAP = { cash_balance: 'cash', click_balance: 'click', payme_balance: 'payme', terminal_balance: 'terminal',
              terminal: 'terminal', dollar_balance: 'dollar_usd', cash: 'cash', click: 'click', payme: 'payme', dollar: 'dollar_usd' };
const filiallar = [];
const nomalum = {};
let tanildi = 0;
for (let i = 0; i < rows.length; i++) {
  const c = rows[i];
  if (!c || c.id == null) { continue; }
  const row = { filial_ref: c.id };
  const bals = Array.isArray(c.balances) ? c.balances : [];
  let hasDollar = false;
  for (let j = 0; j < bals.length; j++) {
    const b = bals[j] || {};
    // YANGI shakl (2026-09-19 tasdiqlandi): label = {id, code:'cash_balance'|'click_balance'|'terminal'|'dollar_balance', title...}, balance:'0.00'
    const lraw = (b.label && typeof b.label === 'object') ? (b.label.code || b.label.label_code || '') : (b.label_code || b.label || b.code || b.type || '');
    const lbl = String(lraw).trim();
    const val = num(b.balance !== undefined ? b.balance : b.amount);
    if (val === null) { continue; }
    const key = MAP[lbl];
    if (!key) { if (val !== 0) { const nk = lbl || '(bo\'sh)'; nomalum[nk] = (nomalum[nk] || 0) + 1; } continue; }
    row[key] = val; tanildi++;
    if (key === 'dollar_usd') { hasDollar = true; }
  }
  if (hasDollar && usdRate) { row.dollar_rate = usdRate; }
  filiallar.push(row);
}
const nk = Object.keys(nomalum);
if (nk.length) {
  throw new Error('Aros balances[] da NOMALUM label (summasi 0 dan katta): ' + nk.map(function(k){ return k + ' x' + nomalum[k]; }).join(', ')
                  + '. Build Payload MAP ga qo\'shing (N8N_BALANS_SYNC_BUILD_PAYLOAD.js).');
}
if (filiallar.length > 0 && tanildi === 0) {
  const namuna = rows.find(function(r){ return r && Array.isArray(r.balances) && r.balances.length; });
  throw new Error('Aros balances[] dan BIRORTA tur tanilmadi (' + filiallar.length + ' kassa) — shakl o\'zgargan. Namuna: '
                  + JSON.stringify(namuna ? namuna.balances : []).slice(0, 300));
}
return [{ json: { filiallar: filiallar, usd_rate: usdRate, tanildi: tanildi } }];
