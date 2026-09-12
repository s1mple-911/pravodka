# n8n tuzatish — «Aros Provodka - Yolda Sync» (2026-09-12)

Workflow: https://n8n.arosmarket.com/workflow/xRARQu9MiZmQ1sAO

**Nega:** Aros 2026-09-09 da `items[]` shaklini o'zgartirgan (`document.amounts[]`, `terminal` turi).
Yolda Sync eski maydonlarni o'qigani uchun kassa sahifasidagi «Yo'ldagi pullar» 0 ko'rsatardi.
2026-09-12 holatiga yo'lda 10 ta transfer — **317 453 990 so'm + $8 495** (Aros PG'da sinab ko'rildi).

**Tartib:** avval `PROVODKA_YOLDA_TERMINAL.sql` ni RUN qiling (busiz ham ishlaydi, faqat terminal
summasi registrga tushmaydi), keyin quyidagi ikki node'ni **qo'lda** almashtiring (MCP bilan
yangilanmadi — kreditlar uzilmasin). Kreditlarga tegilmaydi.

## 1-node: «Transferlarni oqish (Aros PG)» → Query maydoni (hammasini almashtiring)

```sql
-- Aros PG mirror. Oyna: status<>received (yo'lda) + received so'nggi 14 kun.
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
         coalesce(sum(s_summa) filter (where tur = 'dollar_usd'), 0) as s_usd,
         sum(c_summa) filter (where tur = 'cash')       as c_cash,
         sum(c_summa) filter (where tur = 'click')      as c_click,
         sum(c_summa) filter (where tur = 'payme')      as c_payme,
         sum(c_summa) filter (where tur = 'terminal')   as c_terminal,
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
       a.s_cash, a.s_click, a.s_payme, a.s_terminal, a.s_usd,
       a.c_cash, a.c_click, a.c_payme, a.c_terminal, a.c_usd,
       a.dollar_rate,
       a.nomalum_summa
  from cachier_transfers t
  join agg a on a.id = t.id
  left join cachiers sc on sc.title = t.sender_title and sc.is_kassa = false
  left join cachiers rc on rc.title = t.receiver_title and rc.is_kassa = true
 where t.status <> 'received'
    or (t.received_at is not null
        and t.received_at >= (now() at time zone 'Asia/Tashkent') - interval '14 days')
 order by t.id
```

## 2-node: «Payload yasash» → JavaScript maydoni (hammasini almashtiring)

```js
function fixTz(v) {
  if (v === null || v === undefined || v === "") return null;
  var s = String(v);
  if (/[Zz]|[+-]\d{2}:?\d{2}$/.test(s)) return s;
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
      sTerminal = num(r.s_terminal), sUsd = num(r.s_usd);
  if (status === "sent") {
    sentCount = sentCount + 1;
    if (sCash > 0 || sClick > 0 || sPayme > 0 || sTerminal > 0 || sUsd > 0) {
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
    seller: { cash: sCash, click: sClick, payme: sPayme, terminal: sTerminal, dollar_usd: sUsd },
    confirmed: isReceived ? { cash: num(r.c_cash), click: num(r.c_click), payme: num(r.c_payme), terminal: num(r.c_terminal), dollar_usd: num(r.c_usd) } : null,
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
return [{ json: { transferlar: transferlar, soni: transferlar.length, nomalum: nomalum } }];
```

## Tekshirish

1. Saqlang → «Qolda ishga tushirish» bilan bir marta ishga tushiring.
2. «sync_transfer_yolda» javobida `ok: true` bo'lsin.
3. `kassa-dev.html` → «Yo'ldagi pullar» — 10 ta transfer va summalar ko'rinsin.
4. Aros shakli yana o'zgarsa workflow endi QIZIL xato beradi (jimgina 0 yozmaydi).
