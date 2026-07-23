# PROVODKA — dev fayllar tuzilmasi + hodim.html tezligi

Provodka bugundan haqiqiy foydalanuvchilarga topshirilyapti. Endi hech qanday o'zgarish to'g'ridan prod fayllarga chiqmasligi kerak.

---

## 1. DEV FAYLLAR (Aros naqshi: `-dev.html`)

Har prod fayl uchun dev nusxasi:
```
kassa.html        → kassa-dev.html
jurnal.html       → jurnal-dev.html
professional.html → professional-dev.html
hodim.html        → hodim-dev.html
hisobot.html      → hisobot-dev.html
balans.html       → balans-dev.html
cashflow.html     → cashflow-dev.html
qarzdor.html      → qarzdor-dev.html
filial.html       → filial-dev.html
valyuta.html      → valyuta-dev.html
konvert.html      → konvert-dev.html
sozlama.html      → sozlama-dev.html
provodka.html     → provodka-dev.html
```

**Muhim qoidalar:**
- **Linklar dev→dev**: dev fayl ichidagi har bir navigatsiya/sidebar/redirect boshqa dev faylga ketsin (`kassa-dev.html`, `jurnal-dev.html`...). Prod fayllar prod'ga. Aralashib ketmasin — bu eng ko'p xato qilinadigan joy.
- `perms.js` va boshqa umumiy JS/CSS fayllar **ikkalasi uchun bitta** — nusxalanmaydi (agar dev'da o'zgartirish kerak bo'lsa, alohida `perms-dev.js` va faqat dev fayllar undan foydalansin; hozircha bitta yetadi).
- Backend (Supabase) **bitta** — dev va prod bir xil DB.

**Ish tartibi (CLAUDE.md ga yoz):**
1. Har qanday yangi ish FAQAT `-dev.html` fayllarda qilinadi. Prod fayllarga TEGILMAYDI.
2. Asilbek dev URL'da sinaydi (`.../kassa-dev.html`).
3. Tasdiqlangach: dev → prod ko'chiriladi (fayl mazmuni nusxalanadi + ichidagi `-dev.html` linklari prod nomlariga qaytariladi).
4. **SQL faqat additive** (bitta DB, prod ishlab turibdi): `add column if not exists`, yangi funksiya/view, `create or replace` eski imzoni saqlab. Ustun/funksiya o'chirish yoki imzo o'zgartirish — TAQIQ, prod frontendni sindiradi. Tozalash alohida bosqichda, dev prod'ga chiqqandan keyin.

**dev→prod ko'chirish skripti** (repo ildizida `promote.sh` yoki shunga o'xshash) yozib qo'y — qo'lda nusxalash xatoga moyil:
- har `X-dev.html` → `X.html` ga nusxalanadi
- nusxa ichidagi `-dev.html` havolalari `.html` ga almashtiriladi
- qaysi fayllar ko'chirilganini chiqarib beradi
Asilbek `bash promote.sh` bilan ishlatadi (yoki tanlab: `bash promote.sh kassa hodim`).

---

## 2. hodim.html TEZLIGI (shikoyat: ochilish 3s+, saqlash 3s+)

Sabab ehtimoli: bootstrap va saqlashda so'rovlar **ketma-ket** (my_perms → kassalar → moddalar → qoldiq → oy jami → bugungi ro'yxat), har biri 300–600 ms → jami 3s+.

Tuzat (hodim-dev.html da):

**Ochilish:**
- Mustaqil so'rovlarni **parallel** qil: `Promise.all([...])` — perms, kassalar, moddalar, qoldiq, oy jami, bugungi ro'yxat bir vaqtda ketsin. Faqat haqiqatan bog'liq bo'lganlari ketma-ket qolsin.
- **Progressiv ko'rsatish**: forma darrov chiqsin (skeleton/placeholder), ma'lumot kelgani sari to'lsin — foydalanuvchi bo'sh ekranga qaramasin. Kassa/modda kelmaguncha Saqlash disabled.
- **Kesh**: modda ro'yxati va kassalar sessiya davomida o'zgarmaydi — `sessionStorage`da (yoki JS o'zgaruvchida) saqlab, qayta ochilganda darrov ko'rsat, fonda yangila (stale-while-revalidate).
- Keraksiz so'rovlarni olib tashla: bir xil ma'lumot ikki marta so'ralayotgan bo'lsa birlashtir.

**Saqlash:**
- Saqlashdan keyingi yangilanishlar (qoldiq, oy jami, bugungi ro'yxat) **javobni kutmasin**: yozuv muvaffaqiyatli bo'lgach darrov toast + forma tozalansin, qolgan yangilanishlar fonda ketsin.
- Optimistik yangilash: qoldiqdan summani darrov ayirib ko'rsat, fonda haqiqiy qiymat kelganda to'g'rila.
- Chek rasmi upload'i saqlashni bloklamasin (allaqachon shunday bo'lsa — tekshir).
- Ketma-ket insert/select zanjirini kamaytir: agar entry + 2 entry_line + keyin qayta o'qish bo'lsa, `select` ni `insert ... returning` bilan birlashtir yoki umuman tashlab yubor.

**O'lchov:** tuzatishdan oldin va keyin `console.time` bilan ochilish va saqlash vaqtini o'lchab, natijani yoz (masalan "ochilish 3.2s → 0.8s").

---

## Tartib
1 (dev fayllar + promote skript) → 2 (hodim-dev.html tezligi). Har bosqich commit; push Asilbekda.
