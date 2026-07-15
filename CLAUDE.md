# Aros Provodka

Ikki tomonlama buxgalteriya (double-entry) web-app. Aros Market'ning ichki pul-hisobi.
Aros'dan **faqat o'qiydi**, hech qachon yozmaydi.

## Stack

- Frontend: statik HTML fayllar, GitHub Pages. Build yo'q, framework yo'q.
- Backend: Supabase (`kxzerccdpcltmzrxutlo.supabase.co`) — PostgreSQL + Auth + RLS.
- Aros bilan bog'lanish: n8n webhooklar (`n8n.arosmarket.com`), Aros API `api.aros.uz`.
- Til: interfeys o'zbekcha (lotin). Kod izohlari ham o'zbekcha.

## Fayllar

| Fayl | Vazifa |
|------|--------|
| `provodka.html` | Kiritish: Kirim / Chiqim / Transfer + jurnal |
| `professional.html` | Qo'lda ko'p satrli Dt/Kt yozuv |
| `hisobot.html` | P&L zinapoyasi (`pnl()`), xarajat taqsimoti, aylanma-saldo |
| `balans.html` | Balans sanaga: Aktiv \| Passiv+Kapital (`balans()`) |
| `cashflow.html` | Pul oqimi davrga: boshi/oxiri + Kirim/Chiqim (`cashflow()`, `pul_qoldiq()`) |
| `qarzdor.html` | Debitor (4010) / kreditor (6010) |
| `filial.html` | Filiallarda turgan jonli pul |
| `valyuta.html` | Valyuta kurslari (juftlik: from → to) |
| `sozlama.html` | Hisob rejasi boshqaruvi |

Har fayl mustaqil: o'z login gate'i, sidebar/bnav navigatsiyasi, Supabase klienti bor.
Dizayn tizimi hamma faylda takrorlanadi (CSS o'zgaruvchilari bir xil).

Navigatsiya 9 faylda ham bir xil bo'lishi shart: **sidebar 9 ta**, **bnav 6 ta + "Ko'proq"**.
Faqat `active` klassi farq qiladi.

**Sidebar `min-width:900px` da ko'rinadi — mobil'da u umuman yo'q.** Shuning uchun bnav'ga
sig'magan sahifalar (Professional, Valyuta, Sozlamalar) `#moreModal` sheet'iga tushadi
("Ko'proq" tugmasi, `openMore()`/`closeMore()`). Bnav'dan sahifa olib tashlansa, u sheet'ga
qo'shilishi **shart** — aks holda telefonda umuman ochilmaydi. Joriy sahifa sheet ichida
bo'lsa, "Ko'proq" o'zi `active` bo'ladi.

Sheet CSS'i ataylab `.mmodal`/`.msheet` deb nomlangan — `provodka.html`/`valyuta.html`dagi
mavjud `.modal`/`.sheet` bilan to'qnashmasligi uchun.

## Baza modeli

- `accounts` — hisob rejasi. `code`, `name`, `type` (aktiv/passiv/kapital/daromad/xarajat).
  - `5xxx` = pul hisoblari (kassalar). `52xx` = filial kassalari.
  - `filial_ref` — Aros cachier id (filiallar uchun). Bu hisoblar kassa chiplarida ko'rinmaydi, faqat dropdownda.
  - `aros_title` — markaziy kassalar Aros nomiga bog'langan ('Toshkent Kassa', 'Qashqadaryo Kassa').
  - Muhim kodlar: `4010` xaridorlar qarzi, `6010` yetkazib beruvchilar, `5011` Toshkent markaziy kassa,
    `9010` savdo tushumi, `8000` — `provodka.html`da kirim manbasi sifatida tanlanadi.
  - Yangi kod `sozlama.html`da avtomatik beriladi: kassa `50xx` (5011dan), xarajat `94xx` (9421dan),
    daromad `90xx` (9011dan) — diapazondagi eng kattasi + 1.
  - Klientda kassa = `type==='aktiv' && code.startsWith('5')` (`isKassa()`) — filial kassalari ham kiradi,
    shuning uchun ular dropdownda ko'rinadi. Chiplar esa `v_kassa_qoldiq`dan keladi, u filiallarni chiqarib tashlaydi.
- `entry` — provodka sarlavhasi. `is_deleted` (soft-delete), `edited_at`/`edited_by_name`, `ext_ref` (unique — takrorlanishni to'sadi).
- `entry_line` — satrlar. **Cheklov:** `debit`/`credit` manfiy bo'lolmaydi; bir satrda faqat bittasi > 0.
- `currency_rate` — `from_code` → `to_code` juftligi, `rate`, `rate_at`.
- `entry_history` — tahrir/o'chirishdan oldingi nusxa.
- `profiles` — rol (`admin` / `user`).
- `sync_state` — `transfers_from` (avtomatik sinxron qayerdan boshlangani).
- `filial_snapshot` — **bitta qator**, `id=1`. `data` jsonb (`{rows, rate}`), `total`, `synced_by_name`,
  `synced_at`. `filial.html` shu yerdan o'qiydi va "Yangilash"da upsert qiladi.

Viewlar: `v_hisob_qoldiq`, `v_kassa_qoldiq` (filiallarni chiqarib tashlaydi),
`v_current_rate` (har juftlik uchun eng oxirgisi), `v_aylanma_saldo`.

RPC: `sync_filial_balances(jsonb)`, `sync_received_transfers(jsonb)`, `acc_balance(uuid)`.

Hisobot RPC'lari (`sb.rpc()` orqali, SECURITY INVOKER — anon o'qiy olmaydi):
- `balans(p_date)` → `bolim` ('AKTIV'|'PASSIV'|'KAPITAL'), `section`, `code`, `name`, `amount`.
  AKTIV = debit−kredit (amortizatsiya **manfiy** — kontr-aktiv). PASSIV/KAPITAL = kredit−debit, musbat.
  `8710 Yigilgan sof foyda` — sintetik qator. sum(AKTIV) = sum(PASSIV)+sum(KAPITAL) matematik kafolat.
- `pnl(p_from,p_to)` → `bolim` ('TUSHUM'|'TANNARX'|'OPERATSION'|'SOLIQ'|'BOSHQA'), `section`, `code`, `name`, `amount`.
  **Xarajatlar musbat keladi.** **Subtotal qaytarmaydi** — faqat barg qatorlar, zinapoya klientda yig'iladi:
  Yalpi = TUSHUM−TANNARX; Operatsion foyda = Yalpi−OPERATSION; Sof = Operatsion foyda−SOLIQ−BOSHQA.
- `cashflow(p_from,p_to)` → `yonalish` ('KIRIM'|'CHIQIM'), `section`, `code`, `name`, `amount`.
  **Ikkalasi ham musbat.** Kassalararo transfer chiqib ketadi (net=0).
- `pul_qoldiq(p_date)` → numeric. Davr boshi = `pul_qoldiq(p_from − 1 kun)`, `p_from` emas.
  Tekshiruv: `pul_qoldiq(p_to) − pul_qoldiq(p_from−1)` = sum(KIRIM) − sum(CHIQIM).

## Qat'iy qoidalar

- **Dt = Kt** har doim. Trigger `check_entry_balanced` teng bo'lmasa saqlatmaydi.
- **Hech narsa o'chirilmaydi.** O'chirish = `is_deleted=true`, jurnalda usti chizilib qoladi + kim o'chirgani.
  Eski nusxa `entry_history`ga tushadi.
- **Tahrir/o'chirish faqat admin.** RLS darajasida ham himoyalangan.
- **Balans hisobi** faqat `status='posted' AND is_deleted=false` yozuvlardan.
- **Vaqt zonasi:** UZB (UTC+5). `new Date(Date.now()+5*3600*1000)`.
- **Pul formati:** probel bilan ajratiladi (`12 100`), `font-variant-numeric: tabular-nums`.
- **Yozuv tranzaksiyada emas.** Tartib: `entry` insert → `entry_line`lar insert → satrlar xato bersa
  `entry` qo'lda `delete` qilinadi. Saqlash kodini o'zgartirganda shu kompensatsiya `delete`ni yo'qotma —
  aks holda yetim sarlavha qolib ketadi.
- **Tahrir faqat 2 satrli yozuvga.** Qalam tugmasi `entry_line.length===2` bo'lsagina chiqadi.
  `professional.html`dagi ko'p satrli yozuvni o'chirish mumkin, tahrirlash mumkin emas.

## Avtomatik sinxron (n8n)

`Aros Provodka - Auto Sync` (`7MSHrXnz9cGAFBTh`), har 30 daqiqada:
1. Qabul qilingan transferlar → `Dt markaziy kassa / Kt filial kassa`.
   Summa = `items[].confirmed_total` yig'indisi (**reja emas** — `total_amount` ustuni rejani saqlaydi).
2. Filial balansi o'sgan bo'lsa → `Dt filial kassa / Kt savdo tushumi`.
   **Kamayish e'tiborsiz qoldiriladi** — u transfer bilan yoziladi, ikki marta tushmasin.

Boshqa workflowlar: `aros-filial-live` + `aros-currencies` (`lco21f7pUcKPpNVU`),
`aros-currency-rates` (`VDezk7eRnwktu2AX`), `aros-dollar-rate` (`7VyISbPe0ZJqIH0Z`).

## n8n bilan ishlash

- `update_workflow` **har doim** qo'lda ulangan kreditlarni uzadi. "Postgres account 3" o'zi qayta ulanadi,
  HTTP kreditlar (Aros Basic Auth, Supabase API) — yo'q. Update qilishdan oldin ogohlantir.
- Yangi endpoint = **alohida kichik workflow**. Katta ishlab turgan workflowlarni qayta qurma.
- `jsCode` ichida arrow function ishlatma — `function` sintaksisi.
- SDK: `workflow('id','Nom')`, `node({type, version, config:{name, parameters, position}})`, `.add(x).to(y)`.
  `.join()` kabi metodlar taqiqlangan — matnni to'g'ridan-to'g'ri yoz.

## Aros API tuzilishi (o'rganilgan)

- `billing/cachiers/` — ro'yxat. `warehouse` bor = filial, yo'q = markaziy kassa.
- `billing/cachiers/{id}/` — `balances[]`: `cash_balance`, `click_balance`, `payme_balance`, `dollar_balance`.
  **Balanslar filiallar uchun ham qaytadi** (Bugalter Sync ularni olmaydi, faqat kassalar uchun oladi).
- `currencies/` — faqat valyutalar lug'ati (`name`, `is_main`). **Kurs yo'q.**
- `currency-rates/` — kurslar: `base_currency.name`, `target_currency.name`, `rate`, `created_datetime`.
- n8n PG: `cachier_transfers` (`sender_title`, `receiver_title`, `receiver_id` **NULL**, `items` jsonb),
  `cachiers` (`title`, `warehouse_name`, `warehouse_id`, `is_kassa`, `responsible`).
  Vaqtlar naive, Toshkent vaqtida saqlanadi.

## Ish uslubi

- HTML tahrir qilganda **butun faylni qayta yozma** — kerakli joyini o'zgartir.
- `<script type="module">` ichida `onclick`dan chaqiriladigan funksiya **`window.`ga yozilishi shart** —
  modulda top-level funksiya global bo'lmaydi.
- `innerHTML` bilan qayta chizgandan keyin `icons()` (`lucide.createIcons()`) chaqir,
  aks holda `<i data-lucide>` ikonkalari yo'qoladi.
- Tuzilishni buzmaslik uchun: o'zgartirgandan keyin `<div>` balansini tekshir.
- **JS sintaksisini `node --check` bilan tekshir** (Node o'rnatilgan), brauzer/Edge bilan emas.
  Module skriptni ajratib ol va tekshir:
  ```sh
  sed -n '/<script type="module">/,/<\/script>/p' fayl.html | sed '1d;$d' > /tmp/x.mjs
  node --check /tmp/x.mjs
  ```
- Dizaynni bir faylda o'zgartirsang, qolgan 6 tasiga ham tushir (aks holda ular ajralib qoladi).
- SQL DDL'ni Asilbek o'zi RUN qiladi — SQL yozib ber, o'zing bajarma.
