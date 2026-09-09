# Ruxsat so'rovida modda talablari (2026-09-09)

**Fayllar:** `PROVODKA_RUXSAT_TALAB.sql` · `hodim-dev.html` · `sorovlar-dev.html`
**Holat:** dev'da tayyor, SQL **RUN kutilmoqda** (Asilbek).

## 1. Muammo (prodda topildi, Asilbek)

Ikkita alohida teshik:

**(a) Excel/jadval hech qayerda majburiy emas edi.** `hodim.html` da yorliq ochiq-oydin
«Jadval *(ixtiyoriy)*» deb turardi — asosiy formada ham, Ruxsat so'rash tabida ham.
Yagona tekshiruv `jdCheck()`: jadval jami summadan **ko'p** bo'lsa bloklardi; jadval
**umuman yo'q** bo'lsa hech kim so'ramasdi. Natija: hodimlar oziq-ovqat ro'yxatini
biriktirmasdan xarajat yuborishardi.

**(b) «Ruxsat so'rash» (Tab 2) modda bayroqlarini UMUMAN bilmasdi.** Tabda bor-yo'g'i
5 maydon bor edi: xarajat turi · qaysi hisobdan · kimdan · summa · izoh (+ixtiyoriy jadval).
`chek_majburiy` / `ai_tekshir` / `spidometr_ai` / `filial_majburiy` / `davr_majburiy` /
kommunal turi / maxsus maydonlar — **hech biri so'ralmasdi**.

Sabab arxitekturaviy: provodkani `ruxsat_tasdiq` **serverda o'zi** yozadi, forma orqali emas.
`PROVODKA_RUXSAT_SOROV.sql` ichida buni tan olgan izoh ham bor edi — *«ruxsat so'rovida
FILIAL tushunchasi yo'q, shuning uchun `filial_ids` bo'sh»*. Ya'ni yopiq moddaga ruxsat
so'rash — moddaning HAMMA talabini chetlab o'tadigan yo'l edi. Tab 1 («Pul so'rash») esa
asosiy formani ishlatgani uchun barcha tekshiruvdan o'tadi — farq shundan.

## 2. Qaror

Talablar **so'rov paytida** yig'iladi, **server majburlaydi**, **tasdiqda `entry` ga ko'chadi**.

### Chek fayli — ko'chirish YO'Q (asosiy nozik joy)

Chek yo'li `xarajat-cheklari/{kassa_id}/{entry_id}.jpg`. So'rov paytida `entry` hali yo'q.
Storage `insert` policy'si `perm_check_accounts([kassa_id])` talab qiladi — ya'ni
**tasdiqlovchi hodimning kassa papkasiga yoza olmaydi**, demak «tasdiqdan keyin ko'chirish»
ishlamaydi.

Yechim: **klient entry id'sini OLDINDAN yaratadi** (`genUuid()` → `ruxsat_sorov.entry_uid`),
chekni odatdagi yo'lga o'sha id bilan yuklaydi, `ruxsat_tasdiq` esa `entry` ni **aynan shu id
bilan** yaratadi. Shu tufayli:
- storage policy'ga tegilmaydi,
- fayl ko'chirilmaydi,
- `jurnal-dev` papkani ro'yxatlab chekni odatdagidek topadi.

Id band bo'lib qolgan bo'lsa (amalda imkonsiz) yangi id olinadi va javobda `chek_uzildi:true`.

### Ovqat va spidometr — RAD etiladi

`ovqat_modda` (hodimma-hodim taqsimot ro'yxati) va `spidometr_ai` (mashina tablosi surati +
km + AI) talablarini so'rov shakli ifodalay olmaydi. Bunday moddaga ruxsat so'rash
**server tomonda ham** rad etiladi (`ruxsat_talab().bloklangan`), UI da esa sabab yozib
ko'rsatiladi. Chetlab o'tish yo'li qolmasin — yarim qo'llab-quvvatlashdan ko'ra ochiq rad.
(Ovqat asosiy formada ham «Pul so'rash» uchun taqiq — ayni sabab.)

## 3. SQL — `PROVODKA_RUXSAT_TALAB.sql` (ADDITIVE)

| Bo'lim | Nima |
|---|---|
| 1 | `ruxsat_sorov` + `entry_uid`, `filial_ids`, `davr_start/end`, `kommunal_turi`, `chek_bor`, `maydonlar` |
| 2 | `ruxsat_talab(uuid)` — **YAGONA manba**: moddaning talab bayroqlari + `bloklangan` |
| 3 | `ruxsat_yopiq_moddalar()` — har elementga `talab` obyekti (`excel` kaliti ESKI JOYIDA qoladi) |
| 4 | `ruxsat_yarat_v2(jsonb)` — **YANGI**, eski `ruxsat_yarat` ni ICHIDAN chaqiradi |
| 5 | `ruxsat_qator(...)` — `chek_bor/chek_uid/filial_ids/filial_nom/davr/kommunal_turi/maydon_n` |
| 6 | `ruxsat_tasdiq(uuid)` — metadata `entry` ga ko'chadi, `entry.id = entry_uid` |

**🔴 Eski `ruxsat_yarat(uuid,uuid,numeric,text,uuid,text)` TEGILMAYDI** — prod `hodim.html`
aynan uni chaqiradi. `ruxsat_yarat_v2` uni ichidan chaqiradi: kassa/summa/kimdan/pul yetishi
qoidalari **bir joyda** qoladi va hech qachon ikkiga ajramaydi. Bitta funksiya chaqiruvi =
bitta tranzaksiya, shuning uchun so'rov va metadatasi **atomar** yoziladi.

**Nega jadvaldagi «keyin biriktirish» naqshi (`ruxsat_jadval_yoz`) qayta ishlatilmadi:**
u ixtiyoriy ma'lumot uchun edi. Metadata endi MAJBURIY — yarim yozilgan (chek talab qiladigan,
lekin cheksiz) so'rov qolib ketmasligi kerak.

**⚠️ Ongli o'zgarish:** `filial_ids` endi bo'sh emas → `sorov_post_tosiq` ning **limit shoxi**
bu yozuvga ham ishlaydi. Ataylab: ruxsat berilgani filial-modda oylik limitini bekor qilmasligi kerak.

## 4. Klient

### `hodim-dev.html`

**Excel majburiy (uchala yo'lda):** `jdRequired()` = `jadvalOk() && !jadval`; `JD_REQ_MSG`;
`#jdReq` / `#rxJdReq` qizil satri; `updateSave()` da `needJd`; qorovullar `saveHodim` /
`srvSave` / `rxSave` da. Yorliqlar «(ixtiyoriy)» → «majburiy».

**Tab 2 talab bloklari** (`rxTalabUI` / `rxTalabYoq` / `rxTalabReset`):
kommunal segmenti · filial chiplari (`rxFilials`, `selFilials` dan **mustaqil**) ·
davr `<input type=date>` ikkitasi · chek (`rxChekBlob`, `compressImage()` yadrosi) ·
`#rxBlok` (ovqat/spidometr sababi).
Boshqaruvlar modalga sig'sin deb soddaroq (kalendar va qidiruvli dropdown emas), **qoida esa
asosiy forma bilan bir xil**.

**Maxsus maydonlar — blok NUSXALANMAYDI.** Mxd dvigateli uchala faylda aynan bir xil bo'lishi
shart, shuning uchun `#mxdSect` **elementining O'ZI** modalga ko'chiriladi
(`rxMxdEnter`/`rxMxdExit`, `#rxMxdSlot`), yopilganda joyiga qaytariladi. Yagona tikuv joyi —
blok oxiridagi ikki adapter:
```js
const mxdModdaId=()=>(rxMxdAktiv?(rxModda||''):(selModda||''));
const mxdAfterChange=()=>{ if(rxMxdAktiv){ rxUI(); return; } updateSave(); updateAiUI(); };
```
`mxdVals` bitta — kontekst almashganda asosiy formaning qiymatlari saqlanadi/tiklanadi
(`mxdValsMain`/`mxdCurMain`), aks holda modalni ochib yopgan hodimning to'ldirgan maydonlari
jimgina yo'qolardi. `rxMxdExit()` **`srvClose()` da `rxReset()` dan OLDIN** va `srvTab(1)` da
chaqiriladi. `rxPane2Ochiq()` qorovuli: `rxUI()` modal yopiq holatda ham chaqiriladi
(init, `rxModdaLoad`) — o'shanda blok o'g'irlanmasin.

**`rxSave`:** chek RPC dan **OLDIN** yuklanadi (yuklanmasa so'rov umuman yaratilmaydi);
`entry_uid` tokenga bog'lab bir marta yaratiladi — «Qayta urinish» ayni faylni qayta yozadi
(`upsert`), storage'da yetim nusxa qolmaydi. `talab` obyekti bo'lsa `ruxsat_yarat_v2`,
bo'lmasa (SQL hali RUN qilinmagan) eski `ruxsat_yarat` — **fail-open ataylab**, aks holda
SQL RUN bo'lguncha ruxsat so'rash butunlay ishlamay qolardi. v2 da jadval RPC ichida
yoziladi, `ruxsat_jadval_yoz` chaqirilmaydi.

**AI chek tahlili ruxsat yo'lida YO'Q:** `entry_ai_bogla` mavjud yozuvni talab qiladi, so'rovda
esa yozuv hali yo'q. Chek rasmi baribir majburiy — talab chetlab o'tilmaydi, faqat AI xulosasi
bo'lmaydi.

### `sorovlar-dev.html`

Ruxsat kartasida: **Chek** chipi (`rxOpenChek` → signed URL) + jadval chipi bitta qatorda;
`rxTalabMetaHtml` — filial nomlari / davr / kommunal. Filial NOMI serverda yig'iladi
(`ruxsat_qator.filial_nom`) — bu sahifada filiallar ro'yxati yuklanmaydi, uuid ko'rsatishdan
ma'no yo'q. Bu faylda `toast()` **yo'q** — mavjud `qarorXabar()`/`banner()` qatlami ishlatiladi.
`jdChipHtml` → `jdChipBtn` + o'ram: pul so'rovi kartasi ko'rinishi **o'zgarmagan**.

## 5. Sinov ro'yxati (dev)

1. `sozlama-dev` da biror **yopiq** moddaga «Chek» + «Excel» yoqing.
2. `hodim-dev` → Ruxsat so'rash → o'sha tur: chek va Excel so'ralsin, ikkalasisiz
   «So'rov yuborish» yopiq bo'lsin.
3. Filial/davr majburiy moddada — chiplar va sanalar chiqsin, tanlanmasa bloklasin.
4. Maxsus maydonli moddada: blok modal ichiga tushsin, modal yopilganda **asosiy formaga
   qaytsin** va formadagi eski qiymatlar joyida tursin.
5. `sorovlar-dev`: tasdiqlovchi chekni ochsin, filial/davr ko'rinsin, tasdiqlasin.
6. `jurnal-dev`: yozuv chek belgisi bilan chiqsin (fayl ko'chirilmagan — boshidanoq to'g'ri yo'lda).
7. Ovqat / spidometr moddasi: «ruxsat so'rab bo'lmaydi» sababi chiqsin, tugma yopiq bo'lsin.
8. Prod `hodim.html` (eski klient) hamon `ruxsat_yarat` bilan ishlayotganini tekshiring.
