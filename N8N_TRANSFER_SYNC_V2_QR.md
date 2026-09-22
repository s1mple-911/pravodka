# n8n tuzatish — Aros yangi to'lov turi `qr_code` (2026-09-22)

## Hodisa

Aros `items[].document.amounts[].label_code` ga yana bir tur qo'shdi: **`qr_code`**
(«QR code», UZS) — mavjud `cash_balance | click_balance | dollar_balance | terminal`
yonida. `Transfer Sync v2` (`iqtB5Jk2NHW2r82J`) va `Yolda Sync` (`xRARQu9MiZmQ1sAO`)
buni **NOMALUM** deb ko'rib, «Payload yasash» node'i XATO berib to'xtadi (2026-09-09
qoidasi ishladi — jimgina 0 yozilmadi, sinxron qizil bo'lib ko'rindi):

```
Problem in node 'Payload yasash': 1593, 1585, 1597. Maydon xaritasi yangilanishi
kerak - sinxron TO'XTATILDI
```

Bu fayl faqat **`Aros Provodka - Transfer Sync v2`** (`iqtB5Jk2NHW2r82J`) ikkita
node'ining YANGILANGAN matnini beradi. `Yolda Sync` (`N8N_YOLDA_SYNC.js`) va
`Balans Sync` (`N8N_BALANS_SYNC_BUILD_PAYLOAD.js`) alohida — repo fayllarida
JOYIDA yangilangan.

⚠️ **MCP orqali update QILINMAYDI** — `update_workflow` kreditlarni uzadi
(CLAUDE.md). Node'ni n8n'da ochib, matnni **qo'lda** almashtiring.

🔴 **TARTIB: avval `PROVODKA_QR_TUR.sql` RUN qilinsin, keyin bu ikki node.**
SQL RUN qilinmasa `sync_transfer_balans` `qr` turini qattiq ro'yxatdan
o'qimaydi va pul yana jimgina yo'qoladi (2026-09-09 saboqi).

---

## 1-QADAM — «Transferlarni oqish (Aros PG)» node'i

Diff joriy matnga nisbatan (n8n DB'dan olingan, 2026-09-22): `tur` CTE'ga
`when 'qr_code' then 'qr'` shoxi, `agg`/yakuniy select'ga `qr` ustuni.

```sql
-- Aros PG mirror. 14 kunlik oyna.
-- 🔴 2026-09-09: Aros items[] SHAKLINI O'ZGARTIRDI (adminka yangilanishi).
--    ESKI:  items[].confirmed_cash | confirmed_click | confirmed_payme | confirmed_dollar
--    YANGI: items[].document.amounts[] = {label_code, currency, amount, confirmed_amount}
--           label_code: cash_balance | click_balance | dollar_balance | terminal | qr_code
--    document.currency_rate O'ZGARMAGAN — shuning uchun sinxronda FAQAT kurs
--    to'g'ri kelib, qolgan hamma summa 0 bo'lgan va 5 kun pul yozilmagan.
--    Quyidagi so'rov IKKALA shaklni ham tushunadi (14 kunlik oynada ikkalasi
--    ham uchraydi), shuning uchun eski transferlar ham to'g'ri qoladi.
-- 🔴 2026-09-22: yangi to'lov turi `qr_code` (QR code, UZS) — 'qr' turiga xaritalandi.
-- 🔴 Summa manbai: confirmed_amount (qabulda TASDIQLANGAN), yo'q bo'lsa amount.
-- 🔴 Bitta transferda bir necha item bo'ladi va HAR birining O'Z currency_rate i
--    bor (1445: 11850 va 11900) — dollar kursi OG'IRLIKLI o'rtacha olinadi.
--    Eski koddagi max(currency_rate) dollarni noto'g'ri baholardi.
-- 🔴 nomalum_summa: xaritada yo'q label_code. 0 dan katta bo'lsa keyingi node
--    XATO beradi — jimgina yo'qolmaydi.
with it as (
  select t.id, t.sender_title, t.receiver_title, t.status, t.received_at,
         i as item,
         nullif(i->'document'->>'currency_rate', '')::numeric as kurs
    from cachier_transfers t,
         jsonb_array_elements(t.items) i
   where t.status = 'received'
     and t.received_at is not null
     and t.received_at >= (now() at time zone 'Asia/Tashkent') - interval '14 days'
),
tur as (
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
         coalesce(nullif(a->>'confirmed_amount', '')::numeric,
                  nullif(a->>'amount', '')::numeric, 0) as summa
    from it, jsonb_array_elements(it.item->'document'->'amounts') a
   where it.item->'document' ? 'amounts'
  union all
  select it.id, it.kurs, x.tur, x.summa
    from it
    cross join lateral (values
      ('cash',       coalesce(nullif(it.item->>'confirmed_cash', '')::numeric, 0)),
      ('click',      coalesce(nullif(it.item->>'confirmed_click', '')::numeric, 0)),
      ('payme',      coalesce(nullif(it.item->>'confirmed_payme', '')::numeric, 0)),
      ('dollar_usd', coalesce(nullif(it.item->>'confirmed_dollar', '')::numeric, 0))
    ) as x(tur, summa)
   where not (it.item->'document' ? 'amounts')
)
select b.id, b.sender_title, b.receiver_title, b.status,
       to_char(b.received_at, 'YYYY-MM-DD"T"HH24:MI:SS') as received_at,
       coalesce(sum(u.summa) filter (where u.tur = 'cash'), 0)       as cash,
       coalesce(sum(u.summa) filter (where u.tur = 'click'), 0)      as click,
       coalesce(sum(u.summa) filter (where u.tur = 'payme'), 0)      as payme,
       coalesce(sum(u.summa) filter (where u.tur = 'terminal'), 0)   as terminal,
       coalesce(sum(u.summa) filter (where u.tur = 'qr'), 0)         as qr,
       coalesce(sum(u.summa) filter (where u.tur = 'dollar_usd'), 0) as dollar_usd,
       round(sum(u.summa * u.kurs) filter (where u.tur = 'dollar_usd')
             / nullif(sum(u.summa) filter (where u.tur = 'dollar_usd'), 0), 2) as dollar_rate,
       coalesce(sum(u.summa) filter (where u.tur = 'NOMALUM'), 0)    as nomalum_summa
  from (select distinct id, sender_title, receiver_title, status, received_at from it) b
  join tur u on u.id = b.id
 group by b.id, b.sender_title, b.receiver_title, b.status, b.received_at
 order by b.received_at asc
```

---

## 2-QADAM — «Payload yasash» node'i

Diff joriy matnga nisbatan (n8n DB'dan olingan, 2026-09-22): `qr` o'qiladi,
nol-summa tekshiruviga qo'shildi, `row.qr` chiqadi.

```js
function num(v){ var n = parseFloat(String(v)); return isNaN(n) ? 0 : n; }
var rows = $input.all().map(function(i){ return i.json; });
var transferlar = [];
var nol = [];
var nomalum = [];
for (var k = 0; k < rows.length; k++) {
  var t = rows[k] || {};
  if (t.id == null || !t.received_at) continue;
  if (num(t.nomalum_summa) > 0) { nomalum.push(String(t.id)); }
  var cash = num(t.cash), click = num(t.click), payme = num(t.payme),
      terminal = num(t.terminal), qr = num(t.qr), dollar = num(t.dollar_usd);
  if (cash <= 0 && click <= 0 && payme <= 0 && terminal <= 0 && qr <= 0 && dollar <= 0) { nol.push(String(t.id)); continue; }
  var row = {
    id: t.id,
    sender_title: t.sender_title || '',
    receiver_title: t.receiver_title || '',
    status: 'received',
    received_at: String(t.received_at) + '+05:00',
    cash: cash, click: click, payme: payme, terminal: terminal, qr: qr, dollar_usd: dollar
  };
  if (dollar > 0) { row.dollar_rate = num(t.dollar_rate) || null; }
  transferlar.push(row);
}
// 🔴 2026-09-09 SABOG'I — JIMGINA 0 YOZMASLIK.
// Aros items[] shaklini o'zgartirganda sinxron 5 kun "muvaffaqiyatli" ishlab,
// bironta transfer yozmagan. Endi bunday holat XATO beradi va n8n da qizil
// ko'rinadi.
if (nomalum.length) {
  throw new Error("Aros JSON da NOMALUM label_code (summasi 0 dan katta). Transferlar: " + nomalum.join(", ") + ". Maydon xaritasi yangilanishi kerak - sinxron TO'XTATILDI.");
}
if (rows.length > 0 && transferlar.length === 0) {
  throw new Error("Oynada " + rows.length + " ta qabul qilingan transfer bor, LEKIN hammasining summasi 0. Aros JSON shakli yana o'zgargan bo'lishi mumkin - sinxron TO'XTATILDI.");
}
return [{ json: { transferlar: transferlar, soni: transferlar.length, nol_summa: nol, nomalum: nomalum } }];
```

`sync_transfer_balans` node'i (HTTP) o'zgarmaydi — `p_data: $json.transferlar`ni
o'zi jo'natadi, endi har elementda `qr` kaliti ham bor bo'ladi.

---

## Tekshirish

1. `PROVODKA_QR_TUR.sql` RUN qilingan bo'lsin (avval).
2. Ikki node matnini yuqoridagilar bilan almashtiring, saqlang.
3. «Qo'lda ishga tushirish» trigger bilan bir marta ishga tushiring.
4. `sync_transfer_balans` javobida xato yo'qligini, `yozuvlar` soni oshganini tekshiring:

```sql
select count(*), sum(l.debit)
  from entry e join entry_line l on l.entry_id = e.id and l.debit > 0
 where e.ext_ref like 'aros_tr:%:qr' and e.is_deleted = false
   and e.created_at > now() - interval '1 hour';
```
