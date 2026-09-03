# BRIEF — Xarajatga JADVAL biriktirish (Excel nusxasi / .xlsx) — 2026-09-02

## Muammo
`hodim-dev.html` Izoh maydoni bir qatorli `<input>`. Hodim Excel'dan oziq-ovqat ro'yxatini
(40 qator × 5 ustun, ikki blok yonma-yon) nusxalab qo'yganda brauzer qator/tab belgilarini
bo'sh joyga aylantiradi → `entry.description` bitta 1500 belgilik blob. Telegram xabari va
jurnal hunuk, jadval strukturasi kiritish paytidayoq yo'qoladi.

## Yechim (Asilbek tasdiqladi 2026-09-02): jadval IZOHDAN ALOHIDA saqlanadi
- `entry.jadval jsonb` — bitta ADDITIVE ustun.
- Kiritishda: paste (tab+qator) yoki `.xlsx` yuklash → jadval kartasi; izoh qisqa qoladi.
- Jurnalda chip «📋 Jadval · N qator» → modal (toza jadval + Excel). (2-bosqich)
- Telegram: «📋 Jadval: N qator · jami X so'm». (3-bosqich, n8n qo'lda)

## JSON shakli (`entry.jadval`) — 2/3-bosqich shunga tayanadi, o'zgartirma
```json
{
  "v": 1,
  "manba": "paste" | "xlsx",
  "fayl": "ovqat.xlsx" | null,
  "cols": ["№", "Махсулот номи", "Улчов бирлиги", "сони", "суммаси"],
  "rows": [["1", "ёг 5л", "гр", 10000, 210000], ["2", "картошка", "гр", 33000, 150000]],
  "jami": 5719500,
  "n": 38
}
```
- `cols` — birinchi qator agar unda raqamli katak YO'Q bo'lsa (sarlavha), aks holda `cols`
  bo'sh massiv va hamma qator `rows` ga. Ustun soni = eng uzun qator; qisqa qatorlar `""` bilan to'ldiriladi.
- Katak: raqamga o'xshasa (`^-?[\d\s ]+([.,]\d+)?$`, bo'sh joylar olib tashlanib,
  vergul → nuqta) **number**, aks holda trim qilingan **string**. Butunlay bo'sh qatorlar/ustunlar tashlanadi.
- `jami`: kataklaridan biri `/жами|хаммаси|hammasi|jami|итого|всего|total/i` ga mos kelgan
  qatorlar ichidan **eng katta raqam** (ХАММАСИ qatori). Topilmasa `null`.
- `n` = `rows.length` (jami/sarlavha qatorlari ham `rows` ichida qoladi — hech narsa o'chirilmaydi).
- Chegaralar (klient + server): ≤ 500 qator, ≤ 16 ustun, JSON ≤ 100 000 bayt, katak matni ≤ 200 belgi
  (kesiladi). Oshsa klientda toast, jadval qabul qilinmaydi.

## 1-BOSQICH ishlari

### A. SQL — `PROVODKA_JADVAL.sql` (Asilbek RUN qiladi; faqat ADDITIVE)
1. `alter table entry add column if not exists jadval jsonb;` + `comment on column`.
2. Check constraint (mavjud bo'lsa qo'shilmasin — anonim `do` bloki bilan `pg_constraint` tekshir):
   `jadval is null or (jsonb_typeof(jadval)='object' and pg_column_size(jadval) <= 120000)`.
3. `xarajat_saqlash_taqsim(p_data jsonb)` — **PROVODKA_TOSIQ_OCHIR.sql (2.1, 262-qator) dagi
   ENG OXIRGI versiya** bayt-ma-bayt ko'chiriladi, faqat `insert into entry (...)` ga `jadval`
   qo'shiladi: `case when jsonb_typeof(p_data->'jadval')='object' then p_data->'jadval' end`.
   Har filial yozuviga BIR XIL jadval. Imzo/returns/grant/comment o'zgarmaydi.
4. `xarajat_saqlash_ovqat(p_data jsonb)` — **PROVODKA_RBAC_LIMIT.sql (632-qator atrofi) dagi
   ENG OXIRGI versiya** — xuddi shunday, faqat `jadval` qo'shiladi.
   🔴 Boshqa fayllardagi eski versiyalarni OLMA (EXT_REF/XARAJAT_QARZ/OVQAT/OVQAT_KECHKI/RBAC_STAFF eskiroq).
5. YANGI `entry_jadval_yoz(p_ext_ref text, p_jadval jsonb) returns jsonb` — security definer,
   `authenticated` ga grant, `anon/public` dan revoke. "Pul so'rash" yo'li uchun: u yerda entry
   `sorov_yarat` RPC ichida yaratiladi, imzosini o'zgartirib bo'lmaydi (taqiq), shuning uchun
   jadval keyin alohida yoziladi. Shartlar (birortasi buzilsa `{ok:false,error:...}`):
   `auth.uid()` null emas; `entry.ext_ref = p_ext_ref` topildi; yozuv `created_by` = auth.uid()
   (🔴 `created_by` turi noaniq — `to_jsonb(e)->>'created_by'` naqshi, PROVODKA_HODIM_NOTIFY.sql
   565–571 qatorlarga qara); `created_at > now() - interval '30 minutes'`; `jadval is null`
   (bir marta); `jsonb_typeof(p_jadval)='object'`; hajm ≤ 120000. Muvaffaqiyat `{ok:true}`.
   Bu RPC `entry` ustidagi tahrir RLS'ini chetlab o'tadi — shuning uchun FAQAT `jadval` ustunini
   yozadi, boshqa hech narsa.
6. 🔴 Dollar-teg: har funksiya tanasi NOMLANGAN teg (`$fn$`), `--` izohlarda `$`+`$` yonma-yon YO'Q.
   Fayl oxirida tekshiruv `select`i (ustun bor-yo'qligi, 3 funksiya `to_regprocedure`).

### B. `hodim-dev.html` — kiritish (FAQAT dev fayl; prod `hodim.html` ga TEGILMAYDI)
Prefiks `.jd-*`. Mavjud tokenlar (`--surface-2`, `--line`, `--r-md`, `--s*`, `--muted`, `--amber`)
— yangi CSS o'zgaruvchi YO'Q. `</script>` soni 4 bo'lib qolsin (hodim-dev'da widget yo'q).

1. **Holat**: `let jadval=null;` (module ichida). Karta `#izoh` sect'i ostida (`#jdCard`, `display:none`).
2. **Paste ushlash**: `#izoh` ga `paste` hodisasi. `clipboardData.getData('text/plain')` ichida
   `\n` bor VA (`\t` bor YOKI ≥3 qatorda raqam bor) bo'lsa → `preventDefault()`, `jadvalParse(text)`
   → `jadval` ga, karta chiziladi, `#izoh` **o'zgarmaydi** (bo'sh qolsa placeholder
   "masalan: Oziq-ovqat 22.08–05.09" ko'rsatib qisqa izoh so'raydi). Tab bo'lmasa ajratgich —
   2+ ketma-ket bo'sh joy. Oddiy bir qatorli paste — avvalgidek.
3. **Excel yuklash**: Izoh yorlig'i yonida kichik tugma «Excel yuklash» (`file-spreadsheet` lucide)
   → yashirin `<input type=file accept=".xlsx,.xls,.csv">`. `vendor/xlsx-0.18.5.min.js` **LAZY**
   (`ai-dev.html` 946-qator `ACH_XLSX_SRC` naqshi — `<script>` tegi HEAD'da YO'Q, birinchi bosishda
   `script` yaratiladi). Birinchi varaq, `sheet_to_json(ws,{header:1,raw:true})` → bo'sh
   qator/ustunlar olib tashlanib, yuqoridagi JSON shakliga. `fayl` = fayl nomi. Fayl ≤ 2 MB.
   Kutubxona yuklanmasa toast «Excel o'qib bo'lmadi — nusxalab qo'ying».
4. **Karta** (`#jdCard`): sarlavha «📋 Jadval · 38 qator · jami 5 719 500 so'm» (jami null bo'lsa
   faqat qator soni) + `.xlsx` bo'lsa fayl nomi; ostida oldindan ko'rish jadvali (`<table>`,
   `max-height:220px; overflow:auto`, raqamlar o'ngda `tabular-nums`, sarlavha `cols` bo'lsa
   `<thead>`); o'ng burchakda ✕ «Olib tashlash» (`jadval=null`, karta yashirinadi).
   **Summa mosligi**: `jadval.jami` bor va summa maydonidagi qiymatga teng bo'lmasa kartada
   sariq satr «Jadval jami 5 719 500, yozilgan summa 5 000 000 — tekshiring» (BLOKLAMAYDI).
   Summa maydoni o'zgarganda qayta hisoblanadi. Summa bo'sh bo'lsa va jami bor bo'lsa —
   summa maydoniga jami **avtomatik to'ldiriladi** (foydalanuvchi o'zgartira oladi).
5. **Saqlash — 4 yo'l**:
   - Oddiy (`entryPayload`, ~3305-qator): `if(jadval) entryPayload.jadval=jadval;`
   - Taqsim (`xarajat_saqlash_taqsim`, ~3668): `p_data.jadval=jadval`.
   - Ovqat (`xarajat_saqlash_ovqat`, ~3434): `p_data.jadval=jadval`.
   - Pul so'rash (`sorov_yarat`, 4742/4877 — 4821 "qolganini so'rash" mavjud entry, unga
     kerak emas): muvaffaqiyatdan KEYIN `sb.rpc('entry_jadval_yoz',{p_ext_ref:token,p_jadval:jadval})`;
     xato bo'lsa toast «So'rov yuborildi, lekin jadval biriktirilmadi» — so'rov o'zi buzilmaydi.
     RPC yo'q (42883/PGRST202) bo'lsa ham shu toast.
   Muvaffaqiyatli saqlashdan keyin `jadval=null`, karta yashirinadi (forma tozalanadigan joyda).
   🔴 `tokenBoshla` kalitiga jadval KIRMAYDI (takror-himoya kaliti o'zgarmasin).
   🔴 Mavjud saqlash tartibi/kompensatsiya `delete`/23505 mantiqi O'ZGARMAYDI — faqat payloadga
   bitta maydon qo'shiladi.
6. **Server ustun hali yo'q (42703) bo'lsa** oddiy yo'lda insert yiqiladi. Buni ushlash:
   `e1.code==='42703'` va xabarda `jadval` bo'lsa — jadvalsiz QAYTA insert qilmaslik (ext_ref
   takror bo'lib ketadi); o'rniga toast «Jadval hali ulanmagan (SQL run qilinmagan)» va saqlash
   to'xtaydi, kalit tozalanadi (`tokenTugat()`), foydalanuvchi ✕ bilan jadvalni olib tashlab
   qayta saqlaydi. Oddiy izohli xarajatlar ta'sir ko'rmaydi.
7. Mobil: karta to'liq kenglikda, jadval gorizontal skroll (`overflow:auto`), ekran siljimaydi.

### Tekshiruv
- `sed -n '/<script type="module">/,/<\/script>/p' hodim-dev.html | sed '1d;$d' > /tmp/x.mjs && node --check /tmp/x.mjs`
- `grep -c "</script>" hodim-dev.html` → 4.
- Parser birlik testi (node, alohida faylga ko'chirib): Asilbek bergan namuna (ikki blok yonma-yon,
  `210 000,00` formatli raqamlar, ХАММАСИ qatori) → `jami=5719500`, raqam kataklari number.
- SQL: dollar-teg juftligi, `--` izohlarda `$$` yo'q.

## 2-BOSQICH — `jurnal-dev.html` (FAQAT dev; `jurnal.html` ga TEGILMAYDI)
Prefiks `.jd-*`. `</script>` soni 5 qolsin. Yangi CSS o'zgaruvchi yo'q.

1. **Yengil o'qish**: `refreshMeta()` dagi `entry` select'iga (2034-qator) to'liq `jadval` EMAS,
   faqat `jd_n:jadval->n,jd_jami:jadval->jami` qo'shiladi (PostgREST JSON yo'li; 100 qatorda
   50 KB×100 yuklanmasin). 🔴 Ustun hali yo'q (42703) bo'lsa mavjud so'rov YIQILMASIN:
   avval jadvalli select, 42703 kelsa jadvalsiz qayta so'ra (`aiSel()` naqshi, 2024-qator).
2. **Chip**: `izohCell()` (2477) ichida description'dan OLDIN, `jd_n` bor bo'lsa:
   `<button class="jd-chip">📋 Jadval · 38 qator · 5 719 500</button>` (jami null bo'lsa faqat qator).
   Lucide `table-2` ikonkasi, `.jchip-chala` o'lchamida, bosilsa `openJadval(entryId)`.
   Description o'z joyida qoladi (qisqa izoh). Mobil `.jc-row` "Izoh" qatorida ham shu chip.
3. **Modal** `#jdModal` — `.chekov/.chekbox` naqshi (335-qator: fixed, z-index 200, 90vh, flex ustun),
   lekin ALOHIDA id/klass (`.jd-ov/.jd-box`), chek modaliga tegilmaydi. Sarlavha: «Jadval · <izoh>
   · <sana>», ostida meta satr (manba: «Excel nusxasi» / «fayl.xlsx», N qator). Tana: `overflow:auto`
   ikkala yo'nalishda, `<table class="jd-t">` — `cols` bo'lsa `<thead>` (sticky top), raqam
   kataklari o'ngda `tabular-nums` va `money()` formatida (probel), matn chapda; `jami` topilgan
   qator (kataklarida `/жами|hammasi|jami|итого|всего|total/i`) **qalin** + `--surface-2` fon.
   Pastda tugmalar: «📥 Excel» (mavjud `loadXlsx()` 3576-qator, `aoa_to_sheet([cols,...rows])`,
   fayl nomi `jadval_<sana>_<id8>.xlsx`, yiqilsa CSV zaxira — BOM + `sep=;`) va «Yopish».
   Ma'lumot bosilganda olinadi: `sb.from('entry').select('jadval,description,entry_date').eq('id',id).single()`;
   yuklanguncha «Yuklanmoqda…», xato bo'lsa modal ichida xato matni. Esc yopadi.
   Dark mavzu + print (`@media print` — modal yashirin, mavjud qoida) tekshirilsin.
4. **`autoIssues()`** («izoh <5 belgi» qoidasi): `jd_n` bor bo'lsa bu qoida O'TKAZIB yuboriladi —
   jadvalli xarajatda izoh ataylab qisqa.
5. Excel eksport (`xlsRows`, ~3689/3703) O'ZGARMAYDI.

## 3-BOSQICH — Telegram xabari (n8n `Xabar Tuz`, qo'lda)
1. SQL (`PROVODKA_JADVAL.sql` ga 2-bo'lim yoki alohida fayl): `hodim_notify_pending(p_limit int)` —
   **PROVODKA_NOTIFY_TOLIQ.sql (104-qator) dagi ENG OXIRGI versiya** ko'chiriladi, `items` select'iga
   ikki maydon qo'shiladi: `(to_jsonb(e)->'jadval'->>'n')::int as jadval_n`,
   `(to_jsonb(e)->'jadval'->>'jami')::numeric as jadval_jami`. `to_jsonb(e)` naqshi ataylab —
   ustun bo'lmasa ham RPC yiqilmaydi (null). Imzo/returns o'zgarmaydi.
2. `N8N_HODIM_NOTIFY.js` → `xabarTuz.jsCode` (repo nusxasi = n8n'dagi matn, bayt-ma-bayt):
   `📝` izoh qatoridan KEYIN: `if (it.jadval_n) add('📋 Jadval: ' + it.jadval_n + ' qator' +
   (jami ? ' · jami ' + money(jami) + ' so\'m' : ''))`. Qo'shimcha himoya: izoh 300 belgidan uzun
   bo'lsa kesilib `…` qo'yiladi (eski uslubdagi blob xabarni to'ldirmasin). Arrow function YO'Q.
   🔴 MCP `update_workflow` ISHLATILMAYDI (kreditlar uziladi) — Asilbek matnni n8n'da qo'lda almashtiradi.

## 4–5-BOSQICH (Asilbek 2026-09-02): Excel — modda bayrog'i + Ruxsat so'rash + tasdiqlovchi ko'radi
Asilbek: «Excel ko'p narsaga kerak bo'lishi mumkin — sozlamalarga Excel katakchasi qo'sh,
yoqilsa hozirgidek ishlasin; Ruxsat so'rash modalida ham shu turga Excel yoqiq bo'lsa yuklash
imkoni bo'lsin va so'rovni qabul qiluvchi uni ko'ra olsin.»

### 4A. SQL — `PROVODKA_JADVAL_2.sql` (ADDITIVE; old shart: PROVODKA_JADVAL.sql)
1. `alter table accounts add column if not exists excel_jadval boolean not null default false;` + comment
   («Xarajat moddasi: Excel/jadval biriktirish yoqilgan. sozlama → Excel katakchasi»).
2. `set_modda_flag(p_account uuid, p_flag text, p_bool boolean)` — **PROVODKA_RASM_DETECT.sql dagi
   ENG OXIRGI versiya** (7 bayroq) ko'chiriladi + `elsif p_flag = 'excel' then update accounts set
   excel_jadval = coalesce(p_bool,false)`. Imzo o'zgarmaydi.
3. `alter table ruxsat_sorov add column if not exists jadval jsonb;` + check constraint (entry naqshi,
   `do` bloki bilan, ≤120000 bayt, `jsonb_typeof='object'`).
4. `ruxsat_yopiq_moddalar()` — PROVODKA_RUXSAT_SOROV.sql (186) versiyasi + `jsonb_build_object` ga
   `'excel', coalesce(a.excel_jadval, false)` kaliti.
5. YANGI `ruxsat_jadval_yoz(p_ext_ref text, p_jadval jsonb) returns jsonb` — `entry_jadval_yoz` ning
   aynan naqshi, faqat `ruxsat_sorov` uchun: `ext_ref = p_ext_ref`, `hodim_id = auth.uid()`,
   `created_at > now() - 30 min`, `jadval is null`, `status='pending'`, hajm. security definer,
   authenticated grant, anon/public revoke.
6. `ruxsat_qator(r ruxsat_sorov, p_uid uuid)` — PROVODKA_RUXSAT_SOROV.sql (386) + ikki kalit:
   `'jadval_n', (r.jadval->>'n')::int`, `'jadval_jami', (r.jadval->>'jami')::numeric`
   (to'liq jadval ro'yxatga KIRMAYDI — bosilganda `ruxsat_sorov.jadval` RLS bilan o'qiladi).
7. `sorov_qator(...)` — **PROVODKA_SOROVLAR.sql 573-qator** (yagona versiya) + xarajat entry'sidan
   `'jadval_n'`/`'jadval_jami'` (`xarajat_entry_id` bo'yicha `entry` dan, `to_jsonb(e)` naqshi
   bilan — ustun yo'q bo'lsa null). Imzo/boshqa kalitlar o'zgarmaydi.
8. `ruxsat_tasdiq(p_id uuid)` — PROVODKA_RUXSAT_SOROV.sql (549) versiyasi; `insert into entry (...)`
   ga `jadval` ustuni + `r.jadval` qiymati. Boshqa hech narsa o'zgarmaydi (tartib izohi saqlanadi).
9. Dollar-teg qoidasi, tekshiruv select'i (ustunlar + 5 funksiya).

### 4B. `sozlama-dev.html` — Excel katakchasi
`renderList` chiplar qatoriga (`spidometr_ai` dan keyin, `mxdBtn` dan oldin), **faqat
`a.excel_jadval!==undefined`** bo'lsa (ustun RUN qilinmaguncha chip chiqmaydi — mavjud naqsh):
`<label class="chekopt …" title="Excel/jadval biriktirish — hodim Excel ro'yxatini qo'yadi yoki .xlsx yuklaydi">…Excel</label>`,
`setFlag(id,'excel',…)`. `FLAG_COL.excel='excel_jadval'`. Faqat xarajat ro'yxatida (`showChek` bloki ichida).

### 4C. `hodim-dev.html` — bayroq bilan gating + Ruxsat so'rash Tab 2
1. `jadvalOk()` = `!!(moddaObj() && moddaObj().excel_jadval)`. `updateJdUI()` — `updateModdaUI()` dan
   chaqiriladi: Excel tugmasi (`.jdxbtn`) faqat `jadvalOk()` da ko'rinadi; modda almashib bayroq
   yo'q bo'lsa mavjud `jadval` tozalanadi (karta yashirinadi, toast «Bu turda jadval yo'q»).
   `#izoh` paste handler: `jadvalOk()` bo'lmasa oddiy paste (hech narsa ushlanmaydi).
   Saqlash yo'llari o'zgarmaydi (jadval null bo'ladi).
2. **Tab 2 (Ruxsat so'rash)** — `#rxIzoh` maydonidan keyin `#rxJdWrap` (display:none): «Excel yuklash»
   tugmasi + yashirin `#rxJdFile` + `#rxJdCard`. Ko'rinadi FAQAT tanlangan `rxModda` ning `excel===true`
   bo'lsa (`rxModdalar` dan; `ruxsat_yopiq_moddalar` javobida `excel` kaliti yo'q = false).
   `#rxIzoh` paste ham shu shart bilan. Alohida holat `rxJadval`. 🔴 Mavjud `jdRender/jdApply/onJdFile`
   ni ikki holatga xizmat qiladigan qilib **parametrlash** (`jdApplyTo(state)`, `jdRenderInto(cardEl, obj, onRemove)`)
   — kodni nusxalama. Summa avto-to'ldirish Tab 2 da `#rxAmt` uchun ham (bo'sh bo'lsa jami), `rxUI()` chaqiriladi.
   Modda almashsa va yangi moddada excel yo'q → `rxJadval=null`. `rxReset()` ham tozalaydi.
3. `rxSave()`: `ruxsat_yarat` muvaffaqiyatidan KEYIN (`data.ok===true && turi==='ruxsat'`) `rxJadval` bo'lsa
   `sb.rpc('ruxsat_jadval_yoz',{p_ext_ref:token, p_jadval:rxJadval})`; xato → toast «So'rov yuborildi,
   lekin jadval biriktirilmadi». `tokenTugat()` dan OLDIN token qiymatini oling (const bor).
4. Tab 2 intro matni «Tasdiqlovchi faqat shu matnni ko'radi» → jadval bo'lsa «… va jadvalni ko'radi».
5. `</script>` 4, `node --check`, LF, `hodim.html` ga tegilmaydi.

### 5. `sorovlar-dev.html` — tasdiqlovchi ko'radi
1. `rxCardHtml(r)` va `cardHtml(r)` (pul so'rash) — `.srv-izoh` dan keyin `r.jadval_n` bo'lsa chip
   `<button class="jd-chip">` «Jadval · N qator · jami» (jurnal-dev naqshi, `table-2` lucide),
   `openJadval(r.id, r.turi)`.
2. Modal `#jdModal` — jurnal-dev.html dagi `.jd-*` CSS + `renderJdModal` + Excel/CSV eksporti **ko'chiriladi**
   (o'sha ko'rinish). Ma'lumot: `turi==='ruxsat'` → `sb.from('ruxsat_sorov').select('jadval,izoh,created_at').eq('id',id).single()`;
   aks holda (pul so'rash) `entry_id` bo'yicha `sb.from('entry').select('jadval,description,entry_date')`.
   Lazy SheetJS loader (`vendor/xlsx-0.18.5.min.js`) sorovlar-dev'da yo'q bo'lsa qo'shiladi (`loadXlsx` naqshi).
3. `</script>` soni sorovlar-dev'da qancha bo'lsa shuncha qoladi (avval sanab ol), `sorovlar.html` ga tegilmaydi.

## 6-BOSQICH (Asilbek 2026-09-03): erkin Excel/paste o'rniga BITTA UMUMIY SHABLON
Muammo: har hodim istalgan Excel'ni yuklayapti — tuzilish har xil, tekshirib bo'lmaydi.
Qaror: modda `excel_jadval=true` bo'lsa —
- izoh oddiy matn (paste → jadval yo'li O'CHIRILDI, `manba:'paste'` endi yaratilmaydi; eski yozuvlar jurnalda o'qiladi);
- «Shablonni yuklab olish» → xlsx (`jdShablonYuklab`, SheetJS lazy): A1 marker `AROS-PROVODKA-XARAJAT-V1`,
  A2–B4 Modda/Hodim/Sana, 6-qator sarlavha `№ | Nomi | Miqdor | Birlik | Narx | Summa`, 7–46 qatorlar
  (F = Miqdor×Narx formula), 47 `JAMI` (SUM);
- «To'ldirilgan shablonni yuklash» → FAQAT shu shablon qabul qilinadi (marker + sarlavha tekshiruvi), Nomi bo'sh
  qator tashlanadi, Summa bo'sh bo'lsa Miqdor×Narx, `jami` = Summa yig'indisi (shablondagi JAMI kataki emas);
- JSON shakli O'ZGARMAGAN (`{v:1,manba:'xlsx',fayl,cols,rows,jami,n}` + ixtiyoriy `shablon:'xarajat-v1'`) —
  jurnal-dev/sorovlar-dev/Telegram eskicha ko'rsatadi;
- 🔴 **jadval jami > xarajat summasi → QIZIL, saqlash BLOKLANADI** (4 saqlash yo'li + Ruxsat so'rash);
  jami < summa → sariq (bloklamaydi); summa bo'sh → jami avtomat (UZS).
Shablon tuzilishi Asilbek ko'rib chiqadi («kamchilik bo'lsa aytaman»).
