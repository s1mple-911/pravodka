# PROVODKA — Login/Auth (index.html) + Dashboard + eslab qolish

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first (-dev.html → promote.sh). 🔴 Eski buzilmasin. UI/UX Apple (login IDEAL — pravodka.com kirish yuzi). Push Asilbek.

## Muammo
- Hozir har sahifa o'zi auth tekshiradi (Supabase), alohida login YO'Q.
- `pravodka.com` (root) 404 — index.html yo'q.
- Kerak: index.html = LOGIN sahifa → user kiradi → dashboard (ruxsatli sahifalar) → eslab qoladi.

## 1. index.html = Login/Auth sahifa
- `pravodka.com` ochilganda — LOGIN sahifa (index.html).
- Supabase auth (email/parol) — mavjud auth tizimiga mos (har sahifa ishlatayotgan supabase auth).
- 🔴 UI IDEAL — pravodka.com birinchi yuzi, professional, sotувga tayyor (login audit fixlari: Enter ishlasin, focus ko'rinsin, role=alert, mobil, autocomplete).
- Login muvaffaqiyatli → dashboard.
- Agar user allaqачon kirgan (sessiya bор) → to'g'ridan dashboard (login ko'rsatmasdan).

## 2. Dashboard — ruxsatli sahifalar
- Login'дан keyin → dashboard: user ko'ra oladigan sahifalar ro'yxati (permission bo'yicha).
- Permission: mavjud perms.js / my_perms() / allowed_pages (op_kassa_ids emas — SAHIFA ruxsati).
- Har sahifa uchun karta/tugma (kassa, jurnal, hisobot, ai, ...) — faqat RUXSATLI sahifalar ko'rinsin.
- Ruxsat yo'q sahifa — ko'rsatilmaydi (yoki disabled).
- Dashboard'дан sahifага o'tadi.
- ⚠️ CC mavjud perms tizimini ko'rsin (perms.js PAGES, my_perms, allowed_pages) — o'shanga mos.

## 3. Eslab qolish (sessiya)
- User kirgач — 🔴 ESLAB QOLINSIN (keyingi safar login shart emas, agar sessiya amal qilsa).
- Supabase sessiya (localStorage/cookie) — mavjud. Sessiya bор bo'lsa index.html to'g'ridan dashboard.
- Logout tugma (dashboard'да) — sessiyani tugatadi.

## 4. Har sahifa auth guard (mavjud + yaxshilash)
- Har sahifa (kassa, jurnal...) — auth tekshiradi (mavjud). Agar login yo'q → index.html (login) ga redirect.
- Agar user o'sha sahifага ruxsati yo'q → dashboard yoki "ruxsat yo'q".
- ⚠️ Mavjud auth guard buzilmasin — faqat login yo'q bo'lsa index.html ga yo'naltirish qo'shilsin.

## 🔴 CNAME + promote.sh (MUHIM)
- Custom domain uchun repo'да `CNAME` fayl (ichида `pravodka.com`) bор bo'lsin.
- 🔴 promote.sh CNAME faylni O'CHIRMASIN (aks holда har promote'да domain uziladi).
- index.html ham dev-first (index-dev.html) — promote.sh index'ни ham ko'chirsin.
- CC promote.sh ni tekshirib, CNAME saqlanishini + index.html ko'chishini ta'minlasin.

## DB
- Yangi jadval SHART EMAS (mavjud auth + perms). Faqat index.html (login+dashboard) + guard.
- Agar kerak bo'lsa — minimal.

## Fable oqimi
coder (index.html login+dashboard, auth, perms integratsiya, guard, promote.sh+CNAME), designer (login IDEAL + dashboard chиroyли — Apple, sotувga tayyor), tester (login ishlaydi, permission to'g'ri sahifa, eslab qoladi, ruxsatsiz sahifa to'silади, CNAME saqlanadi). 🔴 Eski har sahifa buzilmasin. Dev-first. Push men. To'liq hisobot.

## Tartib
1. index.html = login (UI ideal, auth).
2. Dashboard (ruxsatli sahifalar, perms).
3. Eslab qolish (sessiya) + logout.
4. Guard (login yo'q → index.html).
5. CNAME + promote.sh (domain uzilmasin).
