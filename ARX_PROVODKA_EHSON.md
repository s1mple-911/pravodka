# ARX — Ehson (xayriya) bo'limi — MUSTAQIL (2026-09-03)

Brief: `BRIEF_PROVODKA_EHSON.md`. Namuna: `Ehson_oilalar_jadvali_togrilangan.xlsx` (3 varaq).
Bu hujjat — Asilbek tasdiqlashi uchun ARXITEKTURA. Tasdiqlangach bosqichma-bosqich quriladi.

---

## 0. Bosh qaror — IZOLYATSIYA QANDAY

**Ehson tizimi Provodka'ning buxgalteriyasiga (double-entry) UMUMAN KIRMAYDI.**

| Nima | Qaror | Nega |
|---|---|---|
| `accounts` (hisob rejasi) | ❌ Ehson uchun hisob OCHILMAYDI (5xxx/9xxx yo'q) | Jurnal, hisobot, balans, cashflow, kassa sahifasi, AI kontekst — HAMMASI `accounts` + `entry` dan o'qiydi. Hisob yo'q = u yerlarda ko'rinishning imkoni yo'q. Filtr qo'shishga hojat yo'q. |
| `entry` / `entry_line` | ❌ Yozilmaydi (`source='ehson'` varianti ham RAD) | `source` filtri 15 sahifa + 20 RPC + n8n + AI'da unutilishi mumkin — bitta joy o'tib ketsa kompaniya foydasi buziladi. Fail-closed yo'l — umuman yozmaslik. |
| Pul harakati | Faqat `ehson_kirim` (kassaga kirdi) va `ehson_berish` (oilaga chiqdi) jadvallarida, RPC ichida | Balans = sum(kirim) − sum(berish). Kapitalga, kassalarga, P&L'ga ta'sir nol. |
| Ruxsat | Yangi sahifa kaliti **`ehson`** (allowed_pages), RLS `ehson_page_ok()` = admin yoki `'ehson' ∈ allowed_pages` | Qarz (`qarz_page_ok`) naqshi. 80% hodim `allowed_pages` bo'sh → ular umuman ko'rmaydi. |
| Yozish | RLS'da **insert/update policy YO'Q** — faqat `security definer` RPC'lar (user JWT) | Xarajat/qarz naqshi. Mijoz to'g'ridan yozolmaydi. |
| Tester nazorati | Ehson SQL'ida `entry`, `entry_line`, `accounts` so'zi **umuman bo'lmasin** (faqat `profiles`, `user_perms`) — grep bilan | Izolyatsiya isboti mexanik. |

Kompaniya kassasidan ehson jamg'armasiga pul o'tkazish kerak bo'lsa — bu **ikki alohida amal**: Provodka'da
xarajat («Xayriya» moddasi, oddiy yo'l) + Ehson bo'limida «Kirim» (manba: «Kompaniya»). Avtomat bog'lanmaydi
(brief: har amal shu yerda qoladi). Asilbek xohlasa keyin `ext_ref` bilan ixtiyoriy bog'lash — v2.

---

## 1. Joylashuv — yangi sahifa `ehson-dev.html`

Alohida sahifa (qarzdor-dev'ga tab qilib qo'shilmaydi — mustaqillik + ruxsat alohida). Qo'shilish joylari:
1. `perm_pages()` SQL → 18-kalit `ehson`; 2. `perms-dev.js` `PAGES`; 3. `index-dev.html` `CARDS` (karta «Ehson», `heart-handshake`);
4. 15 dev faylda sidebar (16-element) + «Ko'proq» sheet; 5. `promote.sh` `PAGES`; 6. 🔴 admin-dev `PVS_PAGES` (TaskFix repo — Asilbek).
Sahifa ichi — 6 tab: **Bosh** · **Oilalar** · **Ehson berish** · **Bu oy** · **Kirim** · **Tarix**.

---

## 2. Ma'lumotlar modeli (hammasi yangi `ehson_*` jadval, `PROVODKA_EHSON.sql`, additive)

### `ehson_kassa` — jamg'arma
```
id uuid pk · nom text · izoh text · is_active bool · created_by · created_at
```
Seed: bitta «Ehson jamg'armasi». Bir nechta jamg'arma (masalan «Ramazon», «Qish») kerak bo'lsa — qator qo'shiladi, tuzilma o'zgarmaydi.
**Balans hisoblanadi** (ustun emas): `v_ehson_kassa(id, nom, kirim, berildi, qoldiq)`.

### `ehson_kirim` — jamg'armaga pul kelishi
```
id · kassa_id → ehson_kassa · summa numeric >0 · sana date · manba text (kimdan: «Kompaniya», «Xayriyachi: …»)
izoh text · created_by · created_at · is_deleted bool (soft) · deleted_by · deleted_at
```

### `ehson_oila` — Excel «Oilalar» varag'i + kengaytirish
```
id · oila_kod text unique ('OILA-001' — Excel ID) · fio text (ehson oluvchi) · telefon · manzil
tavsiya text (kim tavsiya qildi) · oilaviy_holat · uyjoy_holat · oylik_daromad numeric
muhtojlik_sabab · yordam_turi · yordam_miqdor · muhtojlik_daraja text ('yuqori'|'orta'|'past')
kiritilgan_sana date · tekshirgan text · tekshirilgan_sana date · izoh
— kengaytirish —
holat text ('faol'|'kuzatuv'|'yopildi') · hudud text (filial/tuman) · keyingi_korib_chiqish date
hujjat_path text (bucket `ehson-hujjat/<oila_id>/…`, ixtiyoriy) · created_by · created_at · updated_at · updated_by
```
### `ehson_azo` — Excel «Oila a'zolari»
```
id · oila_id → ehson_oila · azo_kod text ('AZO-001', oila ichida unique) · qarindosh text
fio · tugilgan_sana date · sogliq text · sogliq_izoh · ish_oqish · kasb_sinf · oylik_daromad numeric
qaramogida bool · izoh · created_at · updated_at
```
🔴 **Yosh SAQLANMAYDI** — `v_ehson_azo` view'ida `age(current_date, tugilgan_sana)` → `yosh_yil, yosh_oy, yosh_kun, yosh_matn`
("7 yil 3 oy"). Excel'dagi 4 «Yoshi» ustuni importda e'tiborsiz (tug'ilgan sanadan qayta hisoblanadi).
Oila kartasida: a'zolar soni, bolalar soni (<18), qaramog'idagilar, sog'lig'i «yomon» bo'lganlar — hisoblanadi.

### `ehson_berish` — pul/yordam berish (Excel «Ehson tarixi»)
```
id · oila_id · kassa_id → ehson_kassa · summa numeric >0 · sana date
tur text ('pul'|'oziq_ovqat'|'kiyim'|'dori'|'boshqa') · izoh text NOT NULL, CHECK length(btrim) >= 3  🔴 MAJBURIY
reja_id → ehson_reja null (oylik reja bo'yicha berilgan bo'lsa) · holat text ('berildi'|'bekor')
keyingi_korib_chiqish date · created_by (mas'ul) · created_at · is_deleted · deleted_by · deleted_at · bekor_sabab
```
🔴 `summa` har turda **jamg'armadan chiqadi** (oziq-ovqat bo'lsa ham uning pul qiymati). Server: `qoldiq >= summa` bo'lmasa XATO
(fail-closed, hech narsa yozilmaydi). Tahrir YO'Q — faqat soft-bekor (`ehson_berish_bekor`, sabab majburiy) → qoldiq qaytadi.

### `ehson_reja` — oyma-oy majburiyat
```
id · oila_id · oylik_summa numeric >0 · boshlanish date (oyning 1-kuni) · oylar_soni int null (null = muddatsiz)
tugash date (hisoblanadi: boshlanish + oylar_soni−1 oy; null = ochiq) · holat ('faol'|'tugadi'|'toxtatildi')
izoh · created_by · created_at · toxtatilgan_at · toxtat_sabab
```
Bir oilada bir vaqtda **bitta faol reja** (unique partial index). Yangi reja = eskisi to'xtatiladi.

### Reja vs fakt — alohida jadval YO'Q, view: `v_ehson_oy(oy, oila_id, oila_kod, fio, reja_summa, fakt_summa, farq, holat)`
`generate_series(boshlanish, coalesce(tugash, oy), '1 month')` × faol rejalar ⟂ `ehson_berish` (o'sha oy, o'sha oila, `is_deleted=false`).
`holat`: `berildi` (fakt ≥ reja) · `qisman` · `kutilmoqda` (oy hali tugamagan) · `qoldi` (oy o'tdi, kam berildi).
RPC `ehson_oy(p_oy date)` shu view'dan + rejasiz lekin shu oy berilganlar («reja'dan tashqari»).

### `ehson_tarix` — audit (append-only)
```
id · obyekt ('oila'|'azo'|'berish'|'kirim'|'reja'|'kassa') · obyekt_id · hodisa · data jsonb · kim · vaqt
```

### Viewlar
`v_ehson_kassa`, `v_ehson_azo`, `v_ehson_oy`, `v_ehson_oila_jami(oila_id, azo_soni, bola_soni, jami_olgan, oxirgi_sana, faol_reja)`.
Hammasi `security_invoker = on` + RLS `ehson_page_ok()`.

---

## 3. RPC'lar (security definer · set search_path · authenticated grant · anon revoke · user JWT · `ehson_page_ok()`)

| RPC | Nima | Fail-closed |
|---|---|---|
| `ehson_dash()` | Bosh: jamg'arma(lar) balansi, oilalar soni (holat bo'yicha), bu oy reja/fakt, jami berilgan (oy/yil), muhtojlik taqsimoti | — |
| `ehson_kirim_yoz(p jsonb)` | kassaga kirim (summa, sana, manba, izoh) | summa>0, kassa faol |
| `ehson_kirim_bekor(p_id, p_sabab)` | soft-delete | qoldiq manfiy bo'lib qolsa RAD (berilgan puldan ko'p kirimni o'chirib bo'lmaydi) |
| `ehson_oila_saqla(p jsonb)` | insert/update (id bo'lsa update), `oila_kod` avtomat (`OILA-` + max+1) yoki berilgan | kod takror → `{ok:false,kod:'takror'}` |
| `ehson_azo_saqla(p jsonb)` / `ehson_azo_ochir(p_id)` | a'zo insert/update/ochirish | oila mavjud, `azo_kod` oila ichida unique |
| `ehson_import(p jsonb)` | Excel: `{oilalar:[…], azolar:[…]}` → **upsert** `oila_kod`/`azo_kod` bo'yicha, ≤500+≤2000 qator, natija `{oila_yangi, oila_yangilandi, azo_yangi, azo_yangilandi, xato:[{qator, sabab}]}` | tranzaksiya: bitta qator xato → hammasi qaytadi? ❌ YO'Q — xato qatorlar ro'yxatga tushadi, qolgani saqlanadi (Asilbek 500 qatorni qayta yuklamasin). Kod bo'sh → RAD. |
| `ehson_ber(p jsonb)` | berish: oila, kassa, summa, sana, tur, **izoh (≥3 belgi)**, reja_id?, keyingi_korib_chiqish? · `ext_ref` (takror himoyasi, qarz naqshi) | izoh bo'sh → xato; `qoldiq < summa` → xato «Jamg'armada yetarli mablag' yo'q»; oila `yopildi` → xato |
| `ehson_berish_bekor(p_id, p_sabab)` | soft-bekor | sabab majburiy |
| `ehson_reja_saqla(p jsonb)` | oyma-oy reja (oila, oylik_summa, boshlanish, oylar_soni?) — eskisi avtomat to'xtatiladi | summa>0 |
| `ehson_reja_toxtat(p_id, p_sabab)` | to'xtatish | — |
| `ehson_oy(p_oy date)` | Bu oy: reja vs fakt ro'yxati + jami | — |
| `ehson_oila_kart(p_id)` | Oila kartasi: oila + a'zolar (yosh bilan) + berishlar + reja + tarix | — |
| `ehson_royxat(p jsonb)` | Oilalar ro'yxati: qidiruv (fio/kod/telefon), filtr (muhtojlik, holat, hudud, «bu oy kutilmoqda»), sahifalash | — |

Klientda RPC yo'q (PGRST202) → sahifa «SQL RUN qilinmagan» bannerini ko'rsatadi, buzilmaydi.

---

## 4. Excel import / eksport

- **Import** (Oilalar tabi, admin): `vendor/xlsx` LAZY. Varaq nomlari «Oilalar» / «Oila a'zolari» + sarlavha qatori
  aynan namunadagidek bo'lishi shart (marker) — aks holda RAD (xarajat shabloni qoidasi). Sana Excel serial (46266) →
  ISO klientda. «Yoshi» ustunlari tashlanadi. Bo'sh `Oila ID` qator o'tkazib yuboriladi. Import oldidan **oldindan ko'rish**
  (nechta yangi / yangilanadi / xato) → tasdiq → `ehson_import`. «Ehson tarixi» varag'i importda **o'qilmaydi** (v1) —
  eski tarix bo'lsa alohida bosqich (izoh majburiy qoidasi bilan zid qatorlar bo'lishi mumkin).
- **Eksport**: 3 varaqli xlsx aynan namuna shaklida (Oilalar / Oila a'zolari (yosh hisoblangan) / Ehson tarixi) —
  Asilbek tashqarida ishlashi uchun; qayta import qilsa upsert.

---

## 5. UI — `ehson-dev.html` (designer: Apple darajasi, mavjud tokenlar, dark/print)

- **Bosh**: 4 karta (Jamg'arma qoldig'i · Jami to'plandi · Jami berildi · Bu oy reja/fakt %), muhtojlik bo'yicha
  taqsimot (yuqori/o'rta/past soni), «Bu oy kutilayotgan» ro'yxat (5 ta) + «Hammasi», oxirgi 5 berish.
- **Oilalar**: qidiruv + filtr chiplari (muhtojlik · holat · hudud · «rejali») · karta ro'yxati (fio, kod, muhtojlik
  rangli nishon, a'zo soni/bolalar, jami olgan, oxirgi berish, faol reja) → **Oila kartasi** (modal/sahifa ichi):
  ma'lumotlar · a'zolar jadvali (qarindosh, yosh avtomat, sog'liq, qaramog'ida) · tarix · reja · «Ehson berish»
  tugmasi · tahrir (admin). «Yangi oila» forma · «Excel import» · «Excel eksport».
- **Ehson berish**: oila picker (qidiruv) → jamg'arma (bitta bo'lsa yashirin) → summa (katta) → tur segmenti →
  sana → **Izoh (majburiy, qizil belgi)** → Muddat: «Bir martalik» / «Oyma-oy» (oylik summa + boshlanish + oylar
  soni yoki muddatsiz → reja yaratiladi va birinchi oy berilishi shu yerda); qoldiq ko'rsatiladi, yetmasa tugma o'chiq.
- **Bu oy**: oy tanlash (← →), jadval: oila · reja · berildi · farq · holat (rang) · «Berish» tugmasi (qatorda,
  summa reja bilan to'ldirilgan) · jami satri. «Rejadan tashqari berilganlar» bo'limi.
- **Kirim**: forma (summa, sana, manba, izoh) + tarix; jamg'arma balansi.
- **Tarix**: hamma berishlar (filtr: oila, tur, oy, mas'ul), bekor qilinganlar ustma-ust, Excel.
- Mobil: bnav'ga qo'shilmaydi (6 ta band), «Ko'proq» sheet'ga tushadi; sahifa ichi tablari mobil'da segment.

---

## 6. Ruxsat va xavfsizlik

- Sahifa: `ehson` kaliti (3 joy + nav + promote + admin-dev). Admin cheklanmaydi.
- Tahrir/bekor/import/reja to'xtatish — **faqat admin**; berish va kirim — `ehson` ruxsatli har user (Asilbek: ❓ yoki faqat admin?).
- RLS: select `ehson_page_ok()`; insert/update/delete policy yo'q. Bucket `ehson-hujjat` (private, signed URL 300s).
- Hech qanday Telegram/n8n (v1). AI `ai_ctx_*` ehson jadvallarini bilmaydi — sizmaydi.
- Barcha summalar UZS (valyuta yo'q).

---

## 7. Bosqichlar (har biri alohida commit + tester)

1. **SQL + skelet**: `PROVODKA_EHSON.sql` (jadvallar, RLS, view, seed, RPC'lar), `perm_pages` 18-kalit, `perms-dev.js`,
   `index-dev` karta, 15 dev faylda nav, `promote.sh`; `ehson-dev.html` skelet (6 tab, gate, banner).
2. **Jamg'arma + Kirim** (balans kartasi, kirim formasi/tarixi).
3. **Oilalar + a'zolar** (ro'yxat, karta, forma, yosh avtomat) + **Excel import/eksport**.
4. **Ehson berish** (izoh majburiy, qoldiq to'sig'i, bir martalik / oyma-oy → reja).
5. **Bu oy** (reja vs fakt, muddat kelganlar, qatordan berish).
6. **Tarix + Bosh statistika + designer to'liq pardoz** + tester izolyatsiya isboti.

---

## 8. SAVOLLAR (Asilbek) — javob bo'lmasa qavsdagi sukut bilan qurilaman
1. Jamg'arma nechta? (sukut: BITTA «Ehson jamg'armasi», keyin qo'shsa bo'ladi)
2. Berish/kirimni kim yozadi — `ehson` ruxsatli har user yoki faqat admin? (sukut: ruxsatli user yozadi, tahrir/bekor/import admin)
3. Ehson turlari: pul · oziq-ovqat · kiyim · dori · boshqa — yetarlimi? Hammasi jamg'armadan pul qiymati bilan chiqadimi? (sukut: ha)
4. Muhtojlik darajasi: yuqori / o'rta / past — yoki 1–5 ball? (sukut: 3 daraja)
5. Oilaga hujjat/rasm (ma'lumotnoma, foto) biriktirish kerakmi? (sukut: ha, ixtiyoriy)
6. Excel «Ehson tarixi» varag'ida eski yozuvlar bormi — import kerakmi? (sukut: v1 da yo'q)
7. Kompaniya kassasidan jamg'armaga o'tkazish — avtomat bog'lansinmi? (sukut: YO'Q, ikki alohida amal — izolyatsiya)

## 16. Qaror o'zgarishi (2026-09-04 kech) — kirim faqat kompaniya kassasidan

Asilbek: «jamg'armaga pul birorta kassamizdan kirishi kerak, shu bilan bu pul Aros tizimidan chiqadi, jurnalda ham 1 marta
provodkasi tushadi; shundan keyin Ehson ichida nima qilinsa ham faqat Ehson ichida qoladi, Ehsondagi pul kompaniya
kapitaliga kirmaydi». Yechim — `PROVODKA_EHSON.sql` 12-BO'LIM: `ehson_kirim_yoz` bitta `entry` yozadi (Dt xarajat moddasi
«Ehson jamg'armasi (<nom>)» 94xx / Kt kassa, `source='ehson'`), `ehson_kirim.entry_id` bog'lanadi; bekor — ikkalasi soft-delete.
Berish/reja — avvalgidek faqat `ehson_*`. 4-bo'limdagi «avtomat bog'lanmaydi» bandi shu bilan bekor.
