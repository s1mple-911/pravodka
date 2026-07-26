# PROVODKA V8 — 8 ta ish (hisobot, professional tuzatish, limit reset, kommunal, xarajat hisoblari, konvert, koridor, qarzdorlar)

Umumiy: har ish UI/UX jihatdan mukammal (senior daraja), mobil-first, aniq matnlar, xato/bo'sh holatlar ko'rinadi, hech qayerda qotmasin. Aros brend ranglari.

Qoidalar (hammasi uchun):
- Faqat `-dev.html` fayllar. **Prod fayllarga TEGILMAYDI.**
- SQL additive (bitta DB, prod ishlayapti): `add column if not exists`, yangi funksiya/view, `create or replace` eski imzoni saqlab. O'chirish/imzo o'zgartirish TAQIQ.
- `boot()` modul oxirida (TDZ). Har o'zgarishdan keyin `node --check` + `</script>` soni.
- Yangi RPC: SECURITY DEFINER + `set search_path=public` + REVOKE anon.
- `entry.created_by` = TEXT (ism), profiles bilan join QILINMAYDI (faqat auth.uid() UUID bilan).
- Supabase `{ error }` doim tekshirilsin; muvaffaqiyat xabari faqat rostdan o'tsa.

---

## 2-ISH (AVVAL — bug) 🔴 professional "Ijara" saqlanmaydi
`professional-dev.html`da xarajat turi **"Ijara" (9411)** tanlanganda **Saqlash bosib bo'lmaydi** (disabled qolyapti yoki xato).
- Sabab ehtimoli: 9411 uchun biror shart (chek/izoh/davr/yuk majburiy) noto'g'ri qo'llanyapti, yoki modda flag tekshiruvi xato.
- Topib tuzat. Boshqa oddiy moddalar (masalan 9412) ishlaydi-yu 9411 ishlamasa — farqni solishtir.
- **Qo'shimcha**: professional-dev.html'ga **sana oralig'i (date range)** tanlash qo'shilsin — aynan `hodim-dev.html`dagidek (davr majburiy modda uchun start–end). Agar allaqachon bor bo'lsa, hodim bilan bir xil UX'ga keltir.

## 5-ISH — Xarajat hisoblarini xarajatga o'tkazish (kichik, DB)
Quyidagi hisoblar hozir boshqa type'da, ular **xarajat** ro'yxatida chiqishi kerak (professional/hodim modda tanlagichlarida). `type='xarajat'` qilinsin:
- 0130 Mashina va uskunalar
- 0140 Mebel va jihozlar
- 0150 Transport vositalari
- 0200 Amortizatsiya
- 2910 Tovarlar
SQL: `update accounts set type='xarajat' where code in ('0130','0140','0150','0200','2910');`
⚠️ Ehtiyot: bu hisoblar balansda "aktiv" bo'lgani uchun turgan bo'lishi mumkin. Type o'zgartirilsa balans/hisobot ularni xarajat deb ko'rsatadi — Asilbek shuni xohlaydi, lekin CC balans/aylanma yiqilmasligini tekshirsin (masalan v_hisob_qoldiq type bo'yicha qoldiq ishorasini hisoblaydi — o'zgarishi mumkin). Agar biror hisobot buzilsa — flag qil, izoh qoldir.

## 3-ISH — Standart limit har oy reset
Savol javobi: **limitlar har oy boshida 0 dan boshlanadi** (limit summasi qoladi, sarflangan 0 ga tushadi).
- `standart_holat(p_oy)` allaqachon **oylik** hisoblaydi (date_trunc month) — ya'ni sarflangan faqat shu oyники. Ya'ni mantiq TAYYOR, har oy avtomat reset bo'ladi.
- CC tekshirsin: `standart-dev.html` sarflangan/qoldini `standart_holat` dan **joriy oy** bo'yicha oladimi. Oy tanlagich bo'lsa — default joriy oy. Limit summasi (`limit_uzs`) o'zgarmaydi, faqat "sarflandi" oydan oyga yangilanadi.
- `limit_guard` trigger ham oylik oynadan foydalanadi (tekshirilgan) — ya'ni sept'da avgust xarajati hisobga olinmaydi. Tasdiqlab, izoh qoldir.

## 4-ISH — Kommunalga "Suv" qo'shish
Hozir kommunal turlari: gaz, svet, musor. **suv** qo'shilsin.
- DB: `entry.kommunal_turi` CHECK constraint yangilanadi:
  ```sql
  alter table entry drop constraint if exists entry_kommunal_turi_check;
  alter table entry add constraint entry_kommunal_turi_check
    check (kommunal_turi is null or kommunal_turi in ('gaz','svet','musor','suv'));
  ```
- Frontend (professional/hodim modal + jurnal teg): 4-tugma "Suv" 💧. Ro'yxat kodda massiv — `['gaz','svet','musor','suv']`.
- `kommunal_hisobot` avtomat qamraydi (group by turi).

## 6-ISH — Konvertdan izohni olib tashlash
`konvert-dev.html`: hozir ruxsat etilgan kurs (koridor lo/hi) ko'rsatiladi — **olib tashlansin**.
- Foydalanuvchi ruxsat etilgan kurs oralig'ини ko'rmasin (kirish nazorati uchun — kim kurs koridorini bilса, chetiga yaqin yozadi).
- Kurs kiritish, sotib olish/sotish, tasdiq oqimi — hammasi qoladi, faqat "ruxsat etilgan: X–Y" matni yashiriladi.
- Koridordan chiqsa baribir pending'ga tushadi (server tekshiradi), lekin foydalanuvchi oldindan chegarani ko'rmaydi.

## 7-ISH — Koridor foizini sozlashda o'zgartirish (admin)
Hozir koridor `conv_koridor_foiz()` = qattiq 5 (yoki hozirgi qiymat). Kerak: **admin sozlamada o'zgartira olsin**, hozircha **0.7%** ga tushsin.
- DB: kichik sozlama jadvali yoki mavjud config:
  ```sql
  create table if not exists provodka_config (key text primary key, val text not null, updated_by text, updated_at timestamptz default now());
  insert into provodka_config(key,val) values ('konvert_koridor_foiz','0.7') on conflict (key) do nothing;
  ```
- `conv_koridor_foiz()` ni shu jadvaldan o'qiydigan qilib qayta yoz (topilmasa default 0.7):
  ```sql
  create or replace function conv_koridor_foiz() returns numeric language sql stable security definer set search_path=public as $$
    select coalesce((select val::numeric from provodka_config where key='konvert_koridor_foiz'), 0.7);
  $$;
  ```
- RPC `set_koridor_foiz(p_foiz numeric)` — admin only, val yangilaydi. `sozlama-dev.html`ga input: "Konvert koridori (%)" + saqlash.
- ⚠️ Hozirgi qiymatni 5 dan 0.7 ga tushirish — sinovda konvertlar ko'proq pending'ga tushishini bил (0.7% juda tor). Asilbek shuni xohlaydi.

## 1-ISH — Hisobot sahifasini to'liq ishlatish (KATTA)
`hisobot-dev.html` — Aros hisobotiga o'xshash to'liq hisobot:
- **Filtrlar (tepada):**
  - Filial/kassa tanlash (bitta yoki barcha) — `v_pul_hisoblar` dan
  - Sana oralig'i (date range) — Aros uslubida (start–end + tez tugmalar: Bugun/Hafta/Oy/O'tgan oy)
  - Status/tur tanlash (multiselect): **kirim, chiqim, xarajat, kassa tushum, transfer** (foyda HOZIRCHA KERAK EMAS)
- **Tepada o'ng burchak — xarajat turlari total:**
  - Bitta xarajat turi total ko'rsatiladi (masalan "Ijara: 5 000 000")
  - **[+] tugma** → yana xarajat turi tanlanadi → o'sha yerda qo'shiladi, har biri total bilan
  - Hammasi filtrларга bo'ysunadi (filial/sana/status o'zgarsa — totallar ham)
- **Pastda — jurnal ko'rinishidagi ro'yxat:**
  - Aynan jurnaldagidek (V7 dizayni): #, Sana, Kt (qayerdan), Dt (qayerga), Summa, Maqsad + ikonlar/teglar
  - Har yozuv alohida row
  - Filtrlarga bo'ysunadi
- Yangi RPC yoki mavjud jurnal so'rovини filtr parametrlari bilan kengaytir. Xarajat turi total uchun alohida yengil so'rov.
- Mobil: filtrlar yig'iladigan (collapse), ro'yxat karta ko'rinishida.
- Perms: cheklangan user faqat o'z kassalarини (mavjud jurnal perm filtri).

## 8-ISH — Qarzdorlar sahifasi (KATTA)
`qarzdor-dev.html`. Qarzdor = **barcha to'lanmagan yuklar** (Aros product-incomes, to'lanmagan/qisman).
- Manba: n8n `aros-provodka-yuklar` endpoint (yuk narxi, valyuta) + Provodka `yuk_tolangan_summa` (qancha to'langan). To'lanmagan qoldiq = narx − to'langan.
- **Asosiy ko'rinish — bitta valyutada ($ USD)**: barcha qarzlar USD ekvivalentida jami. Kurs `valyuta-dev` / `v_current_rate` dan (yoki `conv_baza_kurs`).
  - Katta raqam: "Jami qarz: 45 000 USD"
- **USD ustiga bosilsa → har valyutada ajratib ko'rsat**: "USD: 30 000 · CNY: 80 000 · AED: 5 000 · UZS: 120 000 000" (har biri o'z valyutasida).
- **Valyuta ustiga bosilsa → o'sha valyutadagi dokumentlar ro'yxati**: qaysi yuklar shu valyutada qarz (id, ombor, yetkazuvchi, narx, to'langan, qoldi).
- **Dokument ustiga bosilsa → professional-dev.html'ga o'tadi**, avto to'ldirilgan:
  - Modda: 9110 Tovar tannarxi
  - Yuk: o'sha dokument tanlangan (yuk modalida)
  - Summa: qolgan qarz (yoki foydalanuvchi kiritadi)
  - Kassa: userда 1 ta bo'lsa default tanlangan; 1+ bo'lsa o'zi tanlaydi
  - Kurs: valyuta sectiondan (joriy)
- Filtr: valyuta bo'yicha, yetkazuvchi bo'yicha, to'lanmagan/qisman.
- Bo'sh: "Qarzdorlik yo'q" (yashil).
- Perms: agar kerak bo'lsa cheklov (aks holda hamma ko'radi — Asilbek aytadi).

---

## Tartib
2 (bug) → 5 (hisob type) → 3 (limit reset tekshir) → 4 (suv) → 6 (konvert izoh) → 7 (koridor sozlama) → 1 (hisobot — katta) → 8 (qarzdorlar — katta).
SQL'lar bitta faylga: `PROVODKA_V8.sql` (bosqichlar izoh bilan, idempotent, RAISE bilan tekshiruv). Har ish alohida commit. Push Asilbekda.
Oxirida: fayllar + SQL + har ish uchun sinov ssenariysi.
