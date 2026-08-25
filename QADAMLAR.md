# QADAMLAR — SQL RUN tartibi va qolgan ishlar

Holat: 2026-08-26. Har qadam bajarilgach ✅ qo'ying.

🔴 **Umumiy qoida:** SQL dev va prod uchun **bitta baza** — RUN qilingan zahoti
prodga ta'sir qiladi. HTML esa faqat `promote.sh` dan keyin chiqadi.

⚠️ **So'rovlar tizimi PRODDA jonli** (`49999e8`). Shu sababli A-guruh shoshilinch.

---

## A. 🔴 SHOSHILINCH — proddagi pul xavfini yopadi

| # | Fayl | Nima beradi |
|---|------|-------------|
| A1 | `PROVODKA_SOROVLAR.sql` | kumulyativ chegara · limit qorovuli · Telegram xabari |
| A2 | `PROVODKA_SOROV_TOPUP.sql` | 🔴 **A1 dan KEYIN** — u `sorov_yarat` ni qayta yozadi |

Keyin **11.11** va **11.12** tekshiruvlarini RUN qiling — hamma ustun `true`.

**Nima tuzatildi:**
1. **Kumulyativ chegara** — qisman jo'natilgandan keyin "qolganini so'rash" jo'natilganni
   ayirmasdi → bitta xarajat uchun pul ortiqcha chiqishi mumkin edi.
2. **Limit qorovuli** — `pending → posted` o'tishda oylik limit umuman tekshirilmasdi.
   Endi ikki joyda, lekin **predikat bitta** (`sorov_post_tosiq`).
3. **Telegram** — so'rovlar oqimidan o'tgan xarajat hech qachon xabar bermasdi.

⚠️ A1/A2 gacha: **qisman tasdiqlashdan saqlaning** — to'liq tasdiqlang yoki rad eting.

Hozirgi holatni ko'rish:
```sql
select s.xarajat_entry_id,
       sum(s.jonatilgan_summa) as jami_jonatilgan,
       max(s.xarajat_summa)    as xarajat
  from sorovlar s
 where s.xarajat_entry_id is not null and s.status in ('qisman','tasdiq')
 group by s.xarajat_entry_id
having sum(s.jonatilgan_summa) > max(s.xarajat_summa);
```

---

## B. Universal maxsus maydon

| # | Fayl | Izoh |
|---|------|------|
| B1 | `PROVODKA_XARAJAT_MAYDON.sql` | 🔴 `uuid = uuid[]` tuzatilgan — **qayta RUN** |
| B2 | `PROVODKA_STORAGE_MAYDON.sql` | bucket policy (tirnoqsiz nomlar) |
| B3 | `PROVODKA_HISOBOT_MAYDON.sql` | `hodim_xarajat_royxat_v2` (additiv) |
| B4 | `PROVODKA_MAYDON_QOROVUL.sql` | 🔴 **B1 dan KEYIN** — yozish/o'qish qorovullari |

🔴 **B1 qayta RUN qilinsa B4 ni ham qayta RUN qiling** — aks holda qattiqlashtirish tiklanmaydi.

**Bucket:** Dashboard → Storage → `xarajat-maydon` — **Public = ON** (tekshirildi: `public=true`).

---

## C. Qolgan yangi xususiyatlar

| # | Fayl | Nima |
|---|------|------|
| C1 | `PROVODKA_BAL_GUARD_PENDING.sql` | balans qorovuli pending'ni o'tkazadi |
| C2 | `PROVODKA_YOZUV_ATOMIK.sql` | yetim sarlavha ildizi yopiladi |
| C3 | `PROVODKA_JURNAL_QOLDIQ.sql` | jurnal Boshlang'ich + Tugash |
| C4 | `PROVODKA_HODIM_AMALLAR.sql` | hodim amallar tarixi |

---

## D. Sozlash

- **Top-up chegarasi** — `PROVODKA_SOROV_TOPUP.sql` dagi tayyor blok
  (`insert into provodka_config ... on conflict do update`).
  ⚠️ `set_sorov_topup_chegara()` RPC si SQL editorda **ishlamaydi** (`auth.uid()` null).
- **Maydonni "Moshina Benzin" ga ham ulang** — konstruktordagi "ulash" tugmasi.
  🔴 Yangi maydon **yaratmang**, bittasini ikki moddaga ulang.
- **Maydon nomi** hozir "Ro'yxatdan tanlang" — uni `Mashina` ga o'zgartiring.
- **Element nom/qiymat** ajrating: `DAMAS` + `01O244RB`, `TRACKER` + `01W182OC`.

---

## E. Bu repoda bajarib bo'lmaydi

🔴 **`admin-dev.html`** — TaskFix repozitoriyasida. `PVS_PAGES` ga:
```js
{key:'sorovlar', label:"So'rovlar"}
```
Busiz admin `sorovlar` sahifa ruxsatini **hech kimga bera olmaydi**.

---

## F. Diagnostika (faqat o'qiydi)

| Fayl | Nima aniqlaydi |
|------|----------------|
| `DIAG_BOT.sql` | 🔴 Telegram bot ishlaydimi — **hali RUN qilinmagan** |
| `DIAG_YETIM.sql` / `DIAG_YETIM_DETAL.sql` | satrsiz sarlavhalar (13 ta, hali turibdi) |
| `DIAG_MAYDON_RASM.sql` | rasm zanjiri |
| `DIAG_YAKUN.sql` | yakuniy holat tasdiqi |

---

## G. Ochiq qarorlar

| # | Masala | Holat |
|---|--------|-------|
| G1 | 13 ta yetim sarlavha — atomik yozuv ildizni yopdi, mavjudlari hali turibdi | qaror kerak |
| G2 | `DIAG_BOT.sql` natijasi | siz RUN qilasiz |
| G3 | `kassa_scope` sukuti `'all'` — `hodim_amallar` va boshqa 3 funksiyada "hamma hodim kassasi" degani | alohida bosqich |

---

## H. PROD'GA CHIQARISH

1. `DEV_SINOV.md` bo'yicha sinov — **admin va cheklangan hodim** bilan.
2. `bash promote.sh` (yoki tanlab).
3. Commit + push (siz).

🔴 `promote.sh` `perms-dev.js` ni **argumentdan qat'i nazar** prodga ko'chiradi.
