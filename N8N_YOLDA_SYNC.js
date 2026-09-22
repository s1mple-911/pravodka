// ============================================================================
// «Aros Provodka - Yolda Sync» — n8n Workflow SDK kodi (2026-09-22 yangilandi)
// ----------------------------------------------------------------------------
// n8n'da YARATILGAN: workflow id xRARQu9MiZmQ1sAO
//   https://n8n.arosmarket.com/workflow/xRARQu9MiZmQ1sAO
// Bu fayl — repo nusxasi (qayta yaratish uchun). n8n'da MCP orqali update
// QILINMAYDI (kreditlar uziladi) — node'lar Asilbek tomonidan qo'lda ulanadi.
//
// ALOHIDA workflow. Mavjud «Transfer Sync v2» (iqtB5Jk2NHW2r82J) ga
// TEGILMAGAN — u pul yozadi (sync_transfer_balans), bu esa faqat REGISTR
// (aros_transfer_yolda, PROVODKA_YOLDA.sql + PROVODKA_YOLDA_TERMINAL.sql)
// to'ldiradi. PUL HARAKATI YO'Q.
//
// 🔴 2026-09-12 — Aros items[] YANGI SHAKLI (CLAUDE.md "AROS items[] SHAKLI
// O'ZGARDI", N8N_TRANSFER_YANGI_SHAKL.md 1-qadam). `YOLDA_SQL` endi IKKALA
// shaklni ham o'qiydi (`it`/`tur`/`agg` CTE naqshi — Transfer Sync v2 dagi
// bilan bir xil):
//   YANGI: items[].document.amounts[] = {label_code, amount, confirmed_amount}
//          label_code: cash_balance | click_balance | payme_balance | terminal
//          | dollar_balance. amount -> s_* (sotuvchi sanadi), confirmed_amount
//          -> c_* (qabulda tasdiqlangan; 'sent' holatda HAMMASI null).
//   ESKI:  items[].document.seller_* -> s_*, items[].confirmed_* -> c_*.
// `terminal` — yangi tur (eski `payme` o'rniga uchraydi, lekin payme_balance
// ham xaritalanadi — ikkalasi ham bo'lishi mumkin). Dollar kursi OG'IRLIKLI
// o'rtacha (s_usd bo'yicha — pastda BUILD_PAYLOAD izohida asosi bor).
// 🔴 JIMGINA 0 YO'Q: noma'lum label_code (summasi>0) yoki oynadagi HAMMA
// sent-transfer summasi 0 bo'lsa — Payload yasash node'i XATO beradi
// (2026-09-09 hodisasi — 5 kun jim turgan sinxron — takrorlanmasin).
//
// 🔴 2026-09-22 — Aros yana bitta to'lov turi qo'shdi: `document.amounts[].label_code
// = 'qr_code'` (QR code, UZS). `YOLDA_SQL` endi buni ham `qr` turiga xaritalaydi
// (s_qr/c_qr — PROVODKA_QR_TUR.sql), Payload yasash `seller`/`confirmed` obyektiga
// `qr` kalitini qo'shadi.
//
// Har 5 daqiqada Aros mirror (n8n Postgres, «Postgres account 3»)
// cachier_transfers dan: status != received (yo'lda) + so'nggi 14 kunda
// received bo'lganlar. Har transfer uchun sotuvchi sanagan VA qabulda
// tasdiqlangan summalar → sync_transfer_yolda RPC (service_role ONLY).
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
//   - PROVODKA_YOLDA.sql + PROVODKA_YOLDA_TERMINAL.sql RUN qilingach → Activate.
//   - «Qolda ishga tushirish» bilan bir marta test: HTTP javobida
//     {ok:true, yozildi, yangilandi, nomalum, ogoh} kelishi kerak.
//
// SDK qoidalari: faqat `const` (var taqiq), template string (`.join` taqiq),
// kredit `newCredential('Nom')`, oxirida `export default wf`.
// jsCode ichida arrow function YO'Q (CLAUDE.md).
// `responsible` = cachiers.responsible (jo'natuvchi kassa mas'uli) deb olindi.
// ============================================================================

const YOLDA_SQL = `-- Aros PG mirror. Oyna: status<>received (yo'lda) + received so'nggi 14 kun.
-- 🔴 2026-09-12: items[] YANGI shakli (document.amounts[]) + terminal turi.
--    IKKALA shaklni o'qiydi (Transfer Sync v2 bilan bir xil naqsh,
--    N8N_TRANSFER_YANGI_SHAKL.md): amount -> s_*, confirmed_amount -> c_*
--    (sent holatda hammasi null). ESKI: seller_* -> s_*, confirmed_* -> c_*.
--    Dollar kursi OG'IRLIKLI o'rtacha, s_usd (sotuvchi) bo'yicha — u har
--    ikkala holatda (sent va received) bor, confirmed esa faqat received'da.
with it as (
  select t.id, t.status, t.sender_title, t.receiver_title, t.sent_at, t.received_at,
         i as item,
         nullif(i->'document'->>'currency_rate', '')::numeric as kurs
    from cachier_transfers t,
         jsonb_array_elements(t.items) i
   where t.status <> 'received'
      or (t.received_at is not null
          and t.received_at >= (now() at time zone 'Asia/Tashkent') - interval '14 days')
),
tur as (
  -- YANGI shakl: document.amounts[] = {label_code, amount, confirmed_amount}
  select it.id, it.kurs,
         case a->>'label_code'
           when 'cash_balance'   then 'cash'
           when 'click_balance'  then 'click'
           when 'payme_balance'  then 'payme'
           when 'terminal'       then 'terminal'
           when 'qr_code'        then 'qr'
           when 'dollar_balance' then 'dollar_usd'
           else 'NOMALUM'
         end as tur,
         coalesce(nullif(a->>'amount', '')::numeric, 0) as s_summa,
         nullif(a->>'confirmed_amount', '')::numeric as c_summa
    from it, jsonb_array_elements(it.item->'document'->'amounts') a
   where it.item->'document' ? 'amounts'
  union all
  -- ESKI shakl (oynada hali qolgan eski transferlar uchun)
  select it.id, it.kurs, x.tur, x.s_summa, x.c_summa
    from it
    cross join lateral (values
      ('cash',       coalesce(nullif(it.item->'document'->>'seller_cash',   '')::numeric, 0), nullif(it.item->>'confirmed_cash',   '')::numeric),
      ('click',      coalesce(nullif(it.item->'document'->>'seller_click',  '')::numeric, 0), nullif(it.item->>'confirmed_click',  '')::numeric),
      ('payme',      coalesce(nullif(it.item->'document'->>'seller_payme',  '')::numeric, 0), nullif(it.item->>'confirmed_payme',  '')::numeric),
      ('dollar_usd', coalesce(nullif(it.item->'document'->>'seller_dollar', '')::numeric, 0), nullif(it.item->>'confirmed_dollar', '')::numeric)
    ) as x(tur, s_summa, c_summa)
   where not (it.item->'document' ? 'amounts')
),
agg as (
  select id,
         coalesce(sum(s_summa) filter (where tur = 'cash'), 0)       as s_cash,
         coalesce(sum(s_summa) filter (where tur = 'click'), 0)      as s_click,
         coalesce(sum(s_summa) filter (where tur = 'payme'), 0)      as s_payme,
         coalesce(sum(s_summa) filter (where tur = 'terminal'), 0)   as s_terminal,
         coalesce(sum(s_summa) filter (where tur = 'qr'), 0)         as s_qr,
         coalesce(sum(s_summa) filter (where tur = 'dollar_usd'), 0) as s_usd,
         sum(c_summa) filter (where tur = 'cash')       as c_cash,
         sum(c_summa) filter (where tur = 'click')      as c_click,
         sum(c_summa) filter (where tur = 'payme')      as c_payme,
         sum(c_summa) filter (where tur = 'terminal')   as c_terminal,
         sum(c_summa) filter (where tur = 'qr')         as c_qr,
         sum(c_summa) filter (where tur = 'dollar_usd') as c_usd,
         round(sum(s_summa * kurs) filter (where tur = 'dollar_usd')
               / nullif(sum(s_summa) filter (where tur = 'dollar_usd'), 0), 2) as dollar_rate,
         coalesce(sum(s_summa) filter (where tur = 'NOMALUM'), 0)
           + coalesce(sum(c_summa) filter (where tur = 'NOMALUM'), 0) as nomalum_summa
    from tur
   group by id
)
select t.id,
       t.status,
       t.sender_title,
       t.receiver_title,
       sc.id as sender_ref,
       rc.id as receiver_ref,
       sc.responsible as responsible,
       to_char(t.sent_at, 'YYYY-MM-DD"T"HH24:MI:SS') as sent_at,
       to_char(t.received_at, 'YYYY-MM-DD"T"HH24:MI:SS') as received_at,
       a.s_cash, a.s_click, a.s_payme, a.s_terminal, a.s_qr, a.s_usd,
       a.c_cash, a.c_click, a.c_payme, a.c_terminal, a.c_qr, a.c_usd,
       a.dollar_rate,
       a.nomalum_summa
  from cachier_transfers t
  join agg a on a.id = t.id
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
var nomalum = [];
var sentCount = 0;
var sentNonZero = false;
for (var i = 0; i < rows.length; i++) {
  var r = rows[i].json || {};
  var status = String(r.status || "nomalum").toLowerCase();
  var isReceived = status === "received";
  if (Number(r.nomalum_summa) > 0) {
    nomalum.push(String(r.id));
  }
  var sCash = num(r.s_cash), sClick = num(r.s_click), sPayme = num(r.s_payme),
      sTerminal = num(r.s_terminal), sQr = num(r.s_qr), sUsd = num(r.s_usd);
  if (status === "sent") {
    sentCount = sentCount + 1;
    if (sCash > 0 || sClick > 0 || sPayme > 0 || sTerminal > 0 || sQr > 0 || sUsd > 0) {
      sentNonZero = true;
    }
  }
  var item = {
    id: r.id,
    status: status,
    sender_title: r.sender_title || null,
    receiver_title: r.receiver_title || null,
    sender_ref: (r.sender_ref !== null && r.sender_ref !== undefined) ? String(r.sender_ref) : null,
    receiver_ref: (r.receiver_ref !== null && r.receiver_ref !== undefined) ? String(r.receiver_ref) : null,
    sent_at: fixTz(r.sent_at),
    received_at: fixTz(r.received_at),
    seller: { cash: sCash, click: sClick, payme: sPayme, terminal: sTerminal, qr: sQr, dollar_usd: sUsd },
    confirmed: isReceived ? { cash: num(r.c_cash), click: num(r.c_click), payme: num(r.c_payme), terminal: num(r.c_terminal), qr: num(r.c_qr), dollar_usd: num(r.c_usd) } : null,
    dollar_rate: (r.dollar_rate !== null && r.dollar_rate !== undefined && r.dollar_rate !== "") ? Number(r.dollar_rate) : null,
    responsible: r.responsible || null
  };
  transferlar.push(item);
}
// 🔴 2026-09-12 SABOG'I (2026-09-09 hodisasi, "Transfer Sync v2" 5 kun jim
// turdi, CLAUDE.md) — JIMGINA 0 YO'Q. Aros items[] shaklini yana o'zgartirsa
// registr "yo'lda pul yo'q" deb jim ko'rsatmasin — sinxron XATO berib to'xtaydi.
if (nomalum.length) {
  throw new Error("Aros JSON da NOMALUM label_code (summasi 0 dan katta). Transferlar: "
    + nomalum.join(", ") + ". Maydon xaritasi yangilanishi kerak - sinxron TO'XTATILDI.");
}
if (sentCount > 0 && !sentNonZero) {
  throw new Error("Oynada " + sentCount + " ta yo'lda (sent) transfer bor, LEKIN hammasining "
    + "sotuvchi summasi 0. Aros JSON shakli yana o'zgargan bo'lishi mumkin - sinxron TO'XTATILDI.");
}
return [{ json: { transferlar: transferlar, soni: transferlar.length, nomalum: nomalum } }];`;

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
