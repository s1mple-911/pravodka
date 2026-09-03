# ARXITEKTURA — Qarz (kredit) boshqaruvi · 2026-09-02 · TAKLIF (kod yozilmagan)

`BRIEF_PROVODKA_QARZ.md` asosida. Asilbek ko'radi → tasdiqlagach qurish boshlanadi.
Tamoyillar: dev-first, eski buzilmasin, pul fail-closed, SQL additive, hech narsa o'chirilmaydi.

---

## 0. Mavjud tizimga qanday o'tiradi (tekshirilgan faktlar)

| Nima | Mavjud | Qarzda qayta ishlatiladi |
|---|---|---|
| Kassa qoldig'i | `sorov_kassa_bal(uuid)` — posted + o'chirilmagan, pending kirmaydi | Berishda "yetadimi" tekshiruvi |
| Pul guardi | `trg_perm_guard_entry_line` — Kt kassaga `op_kassa_ids` ruxsati, admin o'tadi, `auth.uid()` null o'tadi | Qarz RPC'lari **user JWT** bilan (service_role emas) → guard avtomat ishlaydi |
| Hodimlar | `aros_staff` (staff_id, ism, familiya, toliq_nom, lavozim, branch_nomi, photo_url, is_active) — authenticated o'qiydi | ICHKI qarzdor = `staff_id` |
| Rasm saqlash | `xarajat-cheklari` bucket, private, `createSignedUrl(…,300)`, path `<kassa>/<entry>.jpg`, RLS `perm_check_accounts` | Tilxat uchun **yangi bucket** `qarz-tilxat`, o'sha naqsh |
| Konteyner hisob | 6720 «Hisobdor shaxslarga qarz» (5400 naqshi) — `kassa_turi` null, section 6010 dan nusxa | 47xx qarz hisoblari — section **4010 dan nusxa** (balans/`v_hisob_royxat` guruhlashi buzilmasin) |
| Jurnal tasnifi | `section='pul'` bo'yicha: Dt pul/Kt pul emas = Kirim, teskarisi = Chiqim | Qarz berish avtomat **Chiqim**, qaytarish **Kirim** — jurnalga tegilmaydi |
| Ext_ref / takror | `entry.ext_ref` unique, `xarajat_holat` naqshi | `qarz:<id>` / `qarz_tolov:<id>` |
| Sahifa ruxsati | `perm_pages()` = `perms-dev.js PAGES` = `index-dev CARDS` = `promote.sh PAGES` (19 sahifa) | Pastdagi 1-qarorga bog'liq |

🔴 **5xxx kodlar ISHLATILMAYDI** — klientda `isKassa()` = `code.startsWith('5')`, 56–59xx valyuta bloklari.
Buxgalteriya rejasidagi 5830 «Qisqa muddatli berilgan qarzlar» shuning uchun **mos kelmaydi**.

---

## 1. Joylashuv — QAROR KERAK

**Variant A (tavsiya): `qarzdor-dev.html` ichida** — sahifa nomi allaqachon «Qarzdorlar», 570 qator, kichik.
Ustiga tab qatori: **Qarz berish · Kutilayotgan · Tilxat kutilmoqda · Kontragentlar (eski 4010/6010 + yuk)**.
Ruxsat kaliti `qarzdor` — mavjud. Nav/perm/index/promote **tegilmaydi**.
Narx: 1 fayl. Xavf: eski tarkib 4-tabga ko'chadi (mantiq o'zgarmaydi, faqat o'ram).

**Variant B: yangi `qarz-dev.html`** — toza sahifa, lekin **19 dev faylning sidebar/sheet'i + `perm_pages()`
+ `perms-dev.js` + `index-dev.html CARDS` + `promote.sh` + `admin-dev PVS_PAGES`** o'zgaradi (AI sahifasi
qo'shilgandagi yo'l). Narx: ~25 fayl, regression maydoni katta.

---

## 2. Hisob rejasi (additive, SQL idempotent)

```
4700  Berilgan qarzlar                 aktiv · KONTEYNER (unga yozilmaydi)   section = 4010 niki
4710  Xodimlarga berilgan qarzlar      aktiv · parent 4700   ← ICHKI
4720  Boshqa shaxslarga berilgan qarzlar aktiv · parent 4700 ← TASHQI
9040  Qarz bo'yicha foiz daromadi      daromad (FAQAT foiz yoqilsa — 6-savol)
9480  Kechirilgan (undirilmagan) qarz  xarajat (FAQAT kechirish yoqilsa — 7-savol)
```
- **Har qarzdorga alohida hisob OCHILMAYDI.** 62 hodim kassasi tajribasi: bola-hisoblar view'larni
  og'irlashtiradi. Qarzdor kesimi `qarz` jadvalining o'zidan olinadi (har qarz → o'z `entry_id`).
- Balans: 4710/4720 AKTIV tomonda «Berilgan qarzlar» sifatida avtomat chiqadi (`balans()` type/section
  bo'yicha — yangi kod yo'q). Cashflow: berish CHIQIM, qaytarish KIRIM — avtomat.
- 4010 «Xaridorlar qarzi» **tegilmaydi** — u savdo debitorligi, bu esa berilgan qarz.

---

## 3. Ma'lumotlar modeli (hammasi yangi jadval — eski jadvallarga ustun qo'shilmaydi)

### `qarzdor` — kim
```
id uuid pk · tur text ('ichki'|'tashqi') · staff_id int null (ichki: aros_staff.staff_id, unique)
ism text · familya text · telefon text null · izoh text null · is_active bool
created_by uuid · created_at
CHECK: (tur='ichki' and staff_id is not null) or (tur='tashqi' and staff_id is null)
```
Ichki qarzdor `aros_staff` dan **bir marta** yaratiladi (ism/familya nusxa — staff o'chsa ham tarix qolsin).
Tashqi — qo'lda. Bitta odamning bir nechta qarzi bo'lishi mumkin (1:N).

### `qarz` — bitta qarz (shartnoma)
```
id uuid pk · qarzdor_id → qarzdor · kassa_id → accounts (5xxx, kassa_turi<>'xarajat_guruh')
summa numeric >0 · currency text default 'UZS'
muddat_turi text ('oylik'|'bir_martalik')
oylik_summa numeric null · oylar_soni int null · boshlanish date (birinchi to'lov sanasi)
tugash date (hisoblanadi: bir martalik = boshlanish; oylik = boshlanish + (oylar_soni−1) oy)
foiz_yillik numeric default 0            -- 6-savol; 0 = foizsiz
status text ('tilxat_kutilmoqda'|'faol'|'yopildi'|'bekor'|'kechirildi')
tilxat_kerak bool (tashqi=true, ichki=false — yaratishda qotiriladi)
tilxat_shablon_id → tilxat_shablon null · tilxat_matn text null (shablon to'ldirilgan holati — tarix)
tilxat_rasm_path text null               -- bucket `qarz-tilxat`, `<qarz_id>/tilxat.jpg`
entry_id → entry null                    -- FAQAT 'faol' bo'lganda to'ladi (pul harakati)
izoh text · ext_ref text unique          -- takror himoyasi (xarajat naqshi)
created_by uuid · created_at · faol_at · yopilgan_at
CHECK: muddat_turi='oylik' → oylik_summa>0 and oylar_soni>0 ; 'bir_martalik' → ikkalasi null
CHECK: status='faol' → entry_id is not null (pul harakatsiz "faol" bo'lolmaydi)
CHECK: tilxat_kerak and status in ('faol','yopildi') → tilxat_rasm_path is not null   🔴 fail-closed
```

### `qarz_jadval` — to'lov grafigi (muddat)
```
id · qarz_id · n int (1..N) · sana date · summa numeric · tolangan numeric default 0
status hisoblanadi (view): 'kutilmoqda' | 'qisman' | 'tolandi' | 'kechikkan' (sana < bugun and tolangan < summa)
```
Yaratilishi: bir martalik → 1 qator; oylik → N qator, **oxirgi qator qoldiqni oladi**
(500 000 × 6 = 3 000 000; summa 3 100 000 bo'lsa oxirgisi 600 000). Oy oxiri (31 → 28/30) `+ interval '1 month'` bilan.
«Moslashuvchan»: berishdan keyin admin grafikni **qayta tuzishi** mumkin (`qarz_jadval_qayta`) — faqat
to'lanmagan qatorlar, tarix `qarz_tarix` da qoladi.

### `qarz_tolov` — qaytarish
```
id · qarz_id · kassa_id (pul QAYSI kassaga tushdi) · summa · sana · izoh
entry_id → entry (Dt kassa / Kt 471x) · ext_ref unique · created_by · created_at · is_deleted (soft)
```
Taqsimot: to'lov **eng eski to'lanmagan** grafik qatoridan boshlab yopadi (FIFO) — `qarz_jadval.tolangan`
yangilanadi. Ortiqcha to'lov rad etiladi (qolgandan ko'p qaytarib bo'lmaydi). Oxirgi so'm tushganda
`qarz.status='yopildi'` avtomat.

### `tilxat_shablon`
```
id · nom · matn text · is_default bool · is_active · created_by · updated_at
```
Matnda joy-tutuvchilar: `{ism} {familya} {summa} {summa_soz} {valyuta} {sana} {muddat} {oylik_summa}
{oylar_soni} {tugash} {kompaniya}`. Bitta sukut shablon SQL bilan seed qilinadi (o'zbek tilxat matni).

### `qarz_tarix` — audit (append-only)
```
id · qarz_id · hodisa ('yaratildi','tilxat_yuklandi','faollashdi','tolov','jadval_qayta','bekor','kechirildi') · data jsonb · kim · vaqt
```

### Viewlar
- `v_qarz_holat` — har qarz: berilgan, to'langan, **qolgan**, kechikkan summa, keyingi to'lov sanasi/summasi, kun kechikish.
- `v_qarz_shu_oy` — shu oy: (a) muddati keladigan qatorlar, (b) oylik to'lov kutilayotganlar — ikki alohida ro'yxat.
- `v_qarzdor_jami` — qarzdor kesimi: nechta qarz, jami qolgan, kechikkan bormi.

---

## 4. Qarz oqimi (holat mashinasi) — pul FAQAT `faol` da harakat qiladi

```
                 ICHKI (tilxat shart emas)
 [yaratish] ──────────────────────────────────► faol ──(to'lovlar)──► yopildi
     │                                            ▲
     │ TASHQI (tilxat majburiy)                   │ tilxat rasmi yuklangach
     └──► tilxat_kutilmoqda ──────────────────────┘
              │ (draft: kassa/qarzdor/summa/muddat/tilxat matni tayyor,
              │  PUL HARAKATI YO'Q, entry YO'Q, kassa qoldig'i band QILINMAYDI)
              └──► bekor (draft bekor — hech narsa o'zgarmaydi)

 faol ──► bekor: TAQIQ (pul chiqqan). Faqat qaytarish yoki (7-savol) kechirish.
```
Server tekshiruvlari (`qarz_faollashtir` ichida, tranzaksiya):
1. `auth.uid()` bor, sahifa ruxsati, kassa `op` ruxsati (guard).
2. `sorov_kassa_bal(kassa) >= summa` — yetmasa **xato**, hech narsa yozilmaydi.
3. `tilxat_kerak` → `tilxat_rasm_path` bor va bucket'da obyekt mavjud (`storage.objects` dan tekshiriladi).
4. `entry` (Dt 471x / Kt kassa, `source='qarz'`, `ext_ref='qarz:<id>'`, description «Qarz: Ism Familya · muddat»)
   + 2 `entry_line` + `qarz_jadval` generatsiya + `status='faol'` + `qarz_tarix`.
🔴 Draft'ni ochgan odam bilan faollashtirgan odam boshqa bo'lishi mumkin — ikkalasi ham tarixda.

---

## 5. Tilxat

1. **Shablonlar** (Sozlamalar ichida yangi karta «Tilxat shablonlari» — admin): nom + matn, joy-tutuvchilar
   ro'yxati ko'rsatiladi, «Sukut» belgisi. Sahifa: `sozlama-dev.html` (mavjud kartalar naqshi).
2. **Tayyorlash** (Qarz berish formasida, tashqi qarzda majburiy qadam): shablon tanlanadi → matn
   to'ldirilgan holda ko'rinadi (tahrirlab bo'ladi) → «Chop etish» (brauzer print, A4, imzo joyi) →
   qarz `tilxat_kutilmoqda` holatida **saqlanadi**.
3. **Rasm yuklash**: «Tilxat kutilmoqda» subsection'ida har draft kartasida «Rasm yuklash» — mavjud chek
   kichraytirish naqshi (`canvas`, jpeg) → bucket `qarz-tilxat/<qarz_id>/tilxat.jpg` → `qarz_tilxat_yuklandi`
   RPC → so'ng «Qarzni berish» tugmasi faollashadi → `qarz_faollashtir`.
4. Ichki qarzda tilxat **ixtiyoriy**: xohlasa shablon/rasm biriktiradi, bo'lmasa darrov `faol`.
5. Bucket RLS: `select` — authenticated; `insert/update` — faqat `qarz` yaratuvchisi yoki admin
   (`qarz_rasm_ok(qarz_id)` funksiyasi orqali, `xarajat-cheklari` naqshi). Signed URL 300 s.

---

## 6. RPC'lar (hammasi `security definer`, `set search_path`, `authenticated` grant, anon revoke, user JWT)

| RPC | Nima | Fail-closed |
|---|---|---|
| `qarzdor_yarat(p jsonb)` | ichki (staff_id) / tashqi (ism, familya) | ichki takror staff → xato; tashqi bir xil ism+familya → ogohlantirish qaytaradi (bloklamaydi) |
| `qarzdor_royxat(p_q text)` | qidiruv, jami qolgan bilan | — |
| `qarz_yarat(p jsonb)` | draft yoki darrov faol (ichki) | kassa faol+op ruxsat, summa>0, muddat validatsiya |
| `qarz_tilxat_yuklandi(p_id, p_path)` | rasm yo'lini yozadi | obyekt bucket'da bormi |
| `qarz_faollashtir(p_id)` | pul chiqadi (4-bo'lim) | qoldiq, tilxat, takror (ext_ref) |
| `qarz_tolov(p_qarz, p_kassa, p_summa, p_sana, p_izoh)` | qaytarish (qisman/to'liq) | summa ≤ qolgan; kassa op ruxsat; FIFO taqsimot; oxirgisi → yopildi |
| `qarz_jadval_qayta(p_id, p_jadval jsonb)` | grafikni qayta tuzish (admin) | yig'indi = qolgan |
| `qarz_bekor(p_id, p_sabab)` | faqat draft | faol → xato |
| `qarz_kechir(p_id, p_sabab)` | (7-savol) admin, Dt 9480 / Kt 471x | — |
| `qarz_royxat(p_holat, p_qarzdor)` / `qarz_kart(p_id)` | ro'yxat + bitta qarz (grafik, to'lovlar, tarix) | — |
| `qarz_dash()` | 3 subsection sarlavha raqamlari: jami berilgan/qolgan/kechikkan, shu oy muddati, shu oy oylik, tilxat kutilayotgan soni | — |

Tahrir: `entry` **tahrir qilinmaydi** (jurnal qoidasi — qarz yozuvi 2 satrli bo'lsa ham qalam chiqmasin:
`source='qarz'` bo'lsa jurnalda ✏️ yashiriladi, 🗑 admin — o'chirsa `qarz_tolov.is_deleted` / qarz holati
**sinxron** trigger bilan qaytariladi. Bu 4-bosqichda alohida ko'riladi).

---

## 7. Ruxsat

- **Sahifa**: Variant A → `qarzdor` kaliti; B → yangi `qarz` kaliti (3 joy + admin-dev).
- **Pul**: qarz beradigan/qabul qiladigan kassa uchun mavjud `op_kassa_ids` — guard trigger. Admin cheklanmaydi.
- **Tashqi qarz berish** — 5-savol: hamma `qarzdor` ruxsatlimi yoki faqat admin?
- **Shablon tahriri, grafik qayta tuzish, kechirish** — faqat admin.
- Qarzdor ma'lumotlari (ism/telefon) — sahifa ruxsati bilan; RLS `select` authenticated + `qarzdor` sahifa tekshiruvi RPC ichida.

---

## 8. UI (designer — Apple darajasi, mavjud tokenlar)

**Sarlavha kartasi** (dash): Jami berilgan · Qolgan · Kechikkan (qizil) · Shu oy kutilmoqda.

**Tab 1 — Qarz berish** (forma, hodim-dev uslubi):
Qarzdor (ichki: aros_staff qidiruv, foto+lavozim; tashqi: mavjuddan tanlash / yangi ism-familya-telefon) →
Kassa (ruxsatli kassalar, qoldiq ko'rinadi, yetmasa qizil) → Summa → Muddat (segment: Bir martalik / Oyma-oy;
oylik: «har oy … so'm × … oy», jami avtomat solishtiriladi; bir martalik: sana) → Izoh →
Tilxat (tashqi: majburiy blok — shablon, matn, chop etish; ichki: yig'iladigan «Tilxat qo'shish») →
Tugma: ichki «Qarz berish» / tashqi «Tilxatga saqlash» (draft).

**Tab 2 — Kutilayotgan qarz**: uch bo'lim:
(a) «Shu oy muddati» — sana bo'yicha ro'yxat (kechikkanlar tepada, qizil kun soni);
(b) «Shu oy oylik to'lov» — kimdan qancha kutilmoqda;
(c) «Hamma qarzdorlar» — qarzdor kartasi: jami qolgan, progress (to'langan/berilgan), keyingi to'lov.
Karta bosilsa → modal: grafik jadvali (qator holati rangli), to'lovlar tarixi, «To'lov qabul qilish»
(kassa + summa, qisman/to'liq), tilxat rasmi, audit.

**Tab 3 — Tilxat kutilmoqda**: draft kartalari — «Chop etish» / «Rasm yuklash» / «Qarzni berish» / «Bekor».

Mobil: tab → segment, kartalar bitta ustun; Excel eksport (mavjud lazy SheetJS) — ro'yxatlar uchun.

---

## 9. Hisobotlarga ta'siri (kod o'zgarmaydi, tekshiriladi)
Balans: 4700 guruh AKTIV. Cashflow: qarz berish CHIQIM «Berilgan qarzlar», qaytarish KIRIM. Jurnal:
`source='qarz'`, chip «Qarz» (maqsad ustunida) — jurnal-dev'ga kichik qo'shimcha. P&L: faqat foiz/kechirish bo'lsa.
AI tahlilchi (`ai_rep_*`) — o'z-o'zidan `entry` orqali ko'radi.

---

## 10. Telegram (v2, ixtiyoriy)
n8n kunlik: bugun/ertaga muddati kelgan va kechikkan qarzlar → admin/qarz beruvchiga xabar. Alohida kichik workflow.

---

## 11. SAVOLLAR (Asilbek) — javob bo'lmasa qavsdagi sukut bilan qurilaman
1. **Joylashuv**: Variant A (`qarzdor-dev` tablari) mi, B (yangi sahifa) mi? *(A)*
2. **Foiz** kerakmi? Kerak bo'lsa: oylik foiz to'lovga qo'shiladimi (annuitet) yoki oxirida? *(v1 foizsiz; `foiz_yillik` ustuni 0 bo'lib turadi)*
3. **Valyuta**: faqat so'mmi, yoki USD kassadan dollar qarz ham? *(v1 UZS; `currency` ustuni bor)*
4. **Ichki qarz** — hodim maoshidan ushlab qolish Provodka'da yo'q, shunchaki qaytarish kassaga tushadi, to'g'rimi? *(ha)*
5. **Tashqi qarz berish** — faqat adminmi yoki `qarzdor` sahifasi ruxsatli hamma? *(admin + op ruxsatli)*
6. **Kechirish** (undirib bo'lmadi → xarajatga) kerakmi? *(v1 yo'q, RPC keyin)*
7. **Grafikni qayta tuzish** (muddat uzaytirish) admin uchun kerakmi? *(ha, v1 da)*
8. **Kechikish** — qancha kundan «kechikkan» (sana o'tgan kundan boshlabmi, 3–5 kun imtiyozmi)? *(0 kun)*
9. **Telegram eslatma** — v1 damı, keyinmi? *(keyin)*

---

## 11a. QARORLAR (Asilbek, 2026-09-02) — TASDIQLANDI
- Joylashuv **A** (`qarzdor-dev.html` tablari). Foizsiz (`foiz_yillik` 0). Faqat UZS. Tashqi qarz: admin + kassa op ruxsatli.
- **Kechirish YO'Q** («kechiksa undirma yo'q») — `qarz_kechir`/9480 hisobi QURILMAYDI; kechikkan qarz faqat ko'rsatiladi.
- Kechikish 0 kundan. Grafik qayta tuzish (admin) — v1 da.
- 🔴 **Telegram v1 da**: (a) kunlik eslatma — bugun muddati kelgan + kechikkanlar; (b) **har qarz hodisasi**
  (berildi / to'lov tushdi / tilxat yuklandi / draft yaratildi / yopildi / bekor) — **3 adminga**
  (`hodim_notify_admin` jadvali, mavjud). Navbat: yangi `qarz_notify` jadvali + `qarz_notify_pending()`
  (service_role) + `qarz_notify_belgila()`; kunlik eslatma qatorlarini `qarz_eslatma_navbat()` (kuniga bir marta,
  `qarz_notify` ga `hodisa='eslatma'`) qo'yadi. n8n: **alohida kichik workflow** «Aros Provodka - Qarz Notify»
  (5 daqiqada: pending → Telegram → belgila). `hodim_notify` jadvaliga TEGILMAYDI.
  ✅ Yaratildi (2026-09-02): **`pVAu9s0bL4yJGfGH`** — https://n8n.arosmarket.com/workflow/pVAu9s0bL4yJGfGH.
  Xabar Tuz kodi = repo `N8N_QARZ_NOTIFY.js` (bayt-ma-bayt). Faollashtirishdan oldin Asilbek:
  (1) `PROVODKA_QARZ.sql` RUN, (2) 5 ta HTTP node'da «Supabase API» (service_role) kreditini ulash
  (Navbat, Yuborildi Belgila, Xato Yoz, Eslatma Navbatga; Telegram Yubor kreditsiz — URL'da bot token,
  Hodim Notify bilan bir xil), (3) workflow sozlamalarida timezone `Asia/Tashkent` (kunlik 09:00 uchun),
  (4) Activate. 🔴 Keyin `update_workflow` ISHLATILMAYDI — matn o'zgarsa qo'lda.

## 12. Bosqichlar (har biri alohida commit + tester)
1. SQL 1: hisoblar (4700/4710/4720), `qarzdor`, `qarz`, `qarz_jadval`, `qarz_tolov`, `tilxat_shablon`, `qarz_tarix`, RLS, bucket, viewlar, RPC'lar (hammasi bitta `PROVODKA_QARZ.sql`).
2. Qarzdorlar ro'yxati (ichki/tashqi) + qarz berish formasi (kassa, summa, muddat) — ichki yo'l to'liq (faol).
3. Tilxat: shablon kartasi (sozlama), tayyorlash/chop etish, rasm yuklash, tashqi yo'l (draft → faol).
4. 3 subsection + qarz kartasi modal (grafik, tarix), dash raqamlari — designer pardozi.
5. To'lash (qisman/to'liq, FIFO), kechikkan, yopilish; jurnalda `source='qarz'` chip + ✏️ yashirish.
6. (ixtiyoriy) grafik qayta tuzish, kechirish, Telegram.

## 13. 3-BOSQICH — Asilbek fikri (2026-09-03), TASDIQLANGAN o'zgarishlar
1. **Tab nomlari/tuzilishi**: «Qarz berish» · «Kutilayotgan» · **«Tilxatlar»** · **«Biz qarzdormiz»**
   (eski Kontragentlar tarkibi — 4010/6010 + yuklar — «Biz qarzdormiz» nomi bilan, mantiq tegilmaydi).
2. **«Tilxatlar»** tabi ichida 3 bo'lim (segment): **Tilxat kutilmoqda** (draftlar — rasm yuklash → qarzni berish),
   **Tilxat yuklagan mijozlar** (rasmi bor qarzlar: qarzdor, summa, holat, sana, thumbnail → to'liq ko'rish),
   **Shablon tilxatlar** (admin: shablon ro'yxati, chop etish/yuklab olish, tahrir, fayl (pdf/jpg/png) yuklash;
   `sozlama-dev` dagi karta OLIB TASHLANADI — bitta joy). Seed: **2 shablon** (bir martalik, oyma-oy) — SQL da.
3. **Tilxat QO'LDA YOZILMAYDI**: forma ichidagi textarea/preview/«Chop etish» OLIB TASHLANADI. Oqim: shablonni
   chop etadi (Tilxatlar → Shablon) → imzolatadi → **rasm/fayl yuklaydi**. Formada (tashqi) ixtiyoriy fayl maydoni:
   fayl tanlansa saqlashda darrov yuklanadi va `qarz_faollashtir` chaqiriladi (bitta bosishda faol);
   tanlanmasa draft → «Tilxat kutilmoqda». `tilxat_matn` endi faqat shablon nomi/ID uchun (ixtiyoriy).
4. **Kassa tanlash — eski mantiq**: avval **parent kassa** (markaziy/filial ildizlari, qidiruv maydoni bilan),
   keyin **child pul turi** segmenti (Naqd/Click/Payme — `v_kassa_tanlov.pul_turi`, hodim-dev `renderTurSeg()` naqshi);
   bola yo'q bo'lsa parentning o'zi. Qoldiq tanlangan hisobniki. To'lov formasida ham shu.
5. Dizayn/UX — designer to'liq o'tadi (asosiy e'tibor).
SQL: `PROVODKA_QARZ.sql` hali RUN qilinmagan → o'sha faylning o'zida: `tilxat_shablon.fayl_path text`,
storage policy `shablon/<id>.<ext>` (admin insert/update, authenticated select), `qarz_royxat` ga
`p_tilxat boolean default null` (true = rasmi bor), seed 2 shablon.

## 14. 4-BOSQICH — «KATTA O'ZGARISH» (Asilbek, 2026-09-03), TASDIQLANGAN
1. **Bo'lim nomi «Qarzdorlar» → «Qarz»** (16 dev fayl nav + sozlama xaritasi + index kartasi). Kalit `qarzdor` va
   `href` O'ZGARMAGAN (ruxsat tizimi tegilmadi).
2. **Kirganda 2 bo'lim** (yuqori segment, `localStorage` `qz-top`): **«Bizdan qarzdor»** — yangi qarz tizimi
   (sub-tablar: Qarz berish · Kutilayotgan · Tilxatlar); **«Biz qarzdor»** — eski mantiq (`#tab-kontr`: 4010/6010 +
   Aros yuklari kelaveradi), mantiqi tegilmagan. «Biz qarzdormiz» sub-tabi olib tashlandi.
3. **«Ichki/tashqi» tushunchasi UI'da YO'Q.** Qarzdor tanlash: **«Mavjud ro'yxatdan»** (aros_staff + avval
   qo'shilgan shaxslar bitta ro'yxatda, «avval qo'shilgan» chipi) yoki **«Yangi qarzdor»** (ism/familya/telefon).
   DB'da `qarzdor.tur` qoladi va o'zi hosil bo'ladi: staff → 'ichki' (4710), shaxs → 'tashqi' (4720) — hisob
   rejasi va guardlar o'zgarmadi.
4. **Tilxat rasmi**: staff bo'lmagan qarzdorga (yangi ham, avval qo'shilgan shaxs ham) **MAJBURIY** — formada
   faylsiz saqlab bo'lmaydi (klient + server `tilxat_kerak`); staff'ga **ixtiyoriy** (fayl bo'lsa `faol` qarzga
   ham yuklanadi — `qarz_tilxat_yuklandi` endi `faol` holatni qabul qiladi, holat o'zgarmaydi).
   «Tilxat kutilmoqda» drafti faqat yuklash yiqilganda qoladi (zaxira yo'l).
5. **TaskFix havola**: `qarz.taskfix_link text` (CHECK `^https?://`, ≤500), `qarz_yarat` `p.taskfix_link`
   (xato kodi `taskfix_link_notogri`), `qarz_qator`/`qarz_kart` qaytaradi; formada «TaskFix havola (ixtiyoriy)»,
   Kutilayotgan kartasi va qarz modalida chip (faqat http(s) chiziladi).
6. Kassa tanlash — 13.4 dagidek (parent → pul turi), tegilmadi.
