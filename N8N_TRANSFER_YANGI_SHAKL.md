# n8n tuzatish — Aros `items[]` yangi shakli (2026-09-09)

## Ildiz sabab (tasdiqlangan)

Pul yozadigan workflow — **`Aros Provodka - Transfer Sync v2`** (`iqtB5Jk2NHW2r82J`, faol,
har 30 daqiqa). Uning SQL'i summani shundan oladi:

```
items[].confirmed_cash | confirmed_click | confirmed_payme | confirmed_dollar
```

Aros bu maydonlarni **`document.amounts[]` massiviga ko'chirgan**. Endi ular yo'q →
`coalesce(..., 0)` → hamma tur 0.

Keyin «Payload yasash» node'i:

```js
if (cash <= 0 && click <= 0 && payme <= 0 && dollar <= 0) {
  tashlandi.push({...}); continue;     // ← JIMGINA tashlab yuboradi
}
```

`tashlandi` hech qayerga yozilmaydi. Shuning uchun `aros_transfer_dropped` da ham iz yo'q,
n8n ham «muvaffaqiyatli» deb ko'rsatadi. **Sinxron 30 daqiqada bir marta muvaffaqiyatli
ishlab, hech nima yozmay turgan.**

## 🔴 Yana bitta topilma

**`Aros Provodka - Auto Sync`** (`7MSHrXnz9cGAFBTh`) — **`active: false`**, o'chirilgan.
U eski v1 (`sync_received_transfers`) va **filial balans sinxroni** (`sync_filial_balances`)
ni ham o'z ichiga olgan. Filial balansi endi alohida **`Balans Sync`** (`5TB7ekGcBlU5qVZ0`,
faol) bilan ketyapti — ya'ni o'chirilgani to'g'ri. Tegmang, faqat bilib qo'ying.

---

# 1-QADAM — «Transfer Sync v2» → «Transferlarni oqish (Aros PG)» node'i

⚠️ **MCP orqali update QILINMAYDI** — `update_workflow` kreditlarni uzadi (CLAUDE.md).
Node'ni n8n'da ochib, SQL matnini **qo'lda** almashtiring.

```sql
-- Aros PG mirror. 14 kunlik oyna.
-- 🔴 2026-09-09: Aros items[] shaklini O'ZGARTIRDI.
--    ESKI: items[].confirmed_cash | confirmed_click | confirmed_payme | confirmed_dollar
--    YANGI: items[].document.amounts[] = {label_code, currency, amount, confirmed_amount}
--           label_code: cash_balance | click_balance | dollar_balance | terminal
--    document.currency_rate O'ZGARMAGAN.
--    Quyidagi so'rov IKKALA shaklni ham tushunadi (14 kunlik oynada
--    ikkalasi ham uchraydi), shuning uchun eski transferlar ham to'g'ri qoladi.
-- 🔴 Summa manbai: confirmed_amount (qabulda TASDIQLANGAN). Yo'q bo'lsa amount.
--    seller/reja ISHLATILMAYDI.
-- 🔴 Bitta transferda bir necha item bo'lishi mumkin va HAR birining O'Z
--    currency_rate i bor (1445: 11850 va 11900). Shuning uchun dollar kursi
--    OG'IRLIKLI o'rtacha qilib olinadi — eski `max(currency_rate)` dollarni
--    noto'g'ri baholardi.
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
  -- YANGI shakl: document.amounts[]
  select it.id, it.kurs,
         case a->>'label_code'
           when 'cash_balance'   then 'cash'
           when 'click_balance'  then 'click'
           when 'payme_balance'  then 'payme'
           when 'terminal'       then 'terminal'   -- Provodkada «Terminal» tur-hisobi ochildi
           when 'dollar_balance' then 'dollar_usd'
           else 'NOMALUM'
         end as tur,
         coalesce(nullif(a->>'confirmed_amount', '')::numeric,
                  nullif(a->>'amount', '')::numeric, 0) as summa
    from it, jsonb_array_elements(it.item->'document'->'amounts') a
   where it.item->'document' ? 'amounts'
  union all
  -- ESKI shakl (oynada hali qolgan transferlar uchun)
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

# 2-QADAM — o'sha workflow → «Payload yasash» node'i

🔴 **Eng muhim o'zgarish:** endi jimgina 0 yozmaydi. Aros shakli yana o'zgarsa
sinxron **XATO berib to'xtaydi** va n8n'da qizil ko'rinadi — bugungidek 5 kun
sezilmay ketmaydi.

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
      terminal = num(t.terminal), dollar = num(t.dollar_usd);
  if (cash <= 0 && click <= 0 && payme <= 0 && terminal <= 0 && dollar <= 0) { nol.push(String(t.id)); continue; }
  var row = {
    id: t.id,
    sender_title: t.sender_title || '',
    receiver_title: t.receiver_title || '',
    status: 'received',
    received_at: String(t.received_at) + '+05:00',
    cash: cash, click: click, payme: payme, terminal: terminal, dollar_usd: dollar
  };
  if (dollar > 0) { row.dollar_rate = num(t.dollar_rate) || null; }
  transferlar.push(row);
}
// 🔴 2026-09-09 SABOG'I — JIMGINA 0 YOZMASLIK.
// Aros items[] shaklini o'zgartirganda sinxron 5 kun davomida "muvaffaqiyatli"
// ishlab, bironta transfer yozmagan. Endi bunday holat XATO beradi.
if (nomalum.length) {
  throw new Error('Aros JSON da NOMALUM label_code (summasi 0 dan katta). Transferlar: '
    + nomalum.join(', ') + '. Maydon xaritasi yangilanishi kerak — sinxron TO\'XTATILDI.');
}
if (rows.length > 0 && transferlar.length === 0) {
  throw new Error('Oynada ' + rows.length + ' ta qabul qilingan transfer bor, LEKIN hammasining '
    + 'summasi 0. Aros JSON shakli yana o\'zgargan bo\'lishi mumkin — sinxron TO\'XTATILDI.');
}
return [{ json: { transferlar: transferlar, soni: transferlar.length,
                  nol_summa: nol, nomalum: nomalum } }];
```

---

# 3-QADAM — «Yolda Sync» (`xRARQu9MiZmQ1sAO`) ham xuddi shunday

`N8N_YOLDA_SYNC.js` dagi `YOLDA_SQL` ham eski maydonlarni o'qiydi. U **pul yozmaydi**
(faqat registr), shuning uchun shoshilinch emas — lekin `kassa-dev` dagi «Yo'ldagi pullar»
0 ko'rsatib turibdi. Transfer Sync tuzalgach shuni ham yangilaymiz.

---

# 4-QADAM — tekshirish

1. «Transfer Sync v2» ni **qo'lda** ishga tushiring («Qo'lda ishga tushirish» trigger).
2. `sync_transfer_balans` javobida `yozildi` soni 0 dan katta bo'lsin.
3. Supabase'da tekshiring:

```sql
select count(*), sum(l.debit)
  from entry e join entry_line l on l.entry_id = e.id and l.debit > 0
 where e.ext_ref like 'aros_tr:%' and e.is_deleted = false
   and e.created_at > now() - interval '1 hour';
```

4. `kassa.html` da Toshkent kassa qoldig'ini hodim aytgan raqam bilan solishtiring.

## Nega tiklash skripti kerak emas (ehtimol)

`Transfer Sync v2` **14 kunlik oyna** bilan ishlaydi va `ext_ref` bo'yicha takrorlanmaydi.
Ya'ni SQL tuzatilgach, u **09-08 va 09-09 dagi hamma transferni o'zi qayta ko'radi va
yozadi** — qo'lda tiklash shart emas. Cutoff POL (2026-08-12) ularni to'smaydi, chunki
ular poldan keyin.

Faqat 14 kundan eski transferlar uchun alohida tiklash kerak bo'lardi — hozircha unday
holat yo'q (buzilish 09-04 dan keyin boshlangan).


---

# 🔴 QO'SHIMCHA — Provodka tomoni SHART, n8n dan OLDIN

n8n `terminal` yuborsa ham, Provodka uni **jimgina e'tiborsiz qoldirardi**:
`sync_transfer_balans` turlarni qattiq ro'yxatdan o'qirdi —
`array['cash','click','payme','dollar_usd']`. Ya'ni pul yana yo'qolardi.

Shuning uchun **`PROVODKA_TERMINAL_TUR.sql` AVVAL RUN qilinadi**:
1. Transferda qatnashadigan har kassaga «Terminal» tur bola-hisobi
   (`terminal_tur_toldir()`, idempotent);
2. `aros_tur_hisob` `terminal` ni taniydi;
3. `sync_transfer_balans` `terminal` turini ham yozadi.

**TARTIB: SQL → n8n node'lari → qo'lda ishga tushirish.**
