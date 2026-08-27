# PROVODKA — Role-Based Access Control (RBAC) + kechki ovqat

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first. 🔴 Eski buzilmasin. Pul — fail-closed. SQL additive. Push Asilbek. Prod: tasdiqlagach. 🔴 TEZLIK — ilova sekinlashmasin (asosiy talab).

## 0. KECHKI OVQAT (kichik fix)
- Hozir ovqat: obed + zavtrak. Kechki (uzhin) TUSHIB QOLGAN.
- 🔴 3 tur: zavtrak, obed, KECHKI (har biri narx).
- provodka_config: ovqat_zavtrak_narx=7000, ovqat_obed_narx=30000, ovqat_kechki_narx=<narx> (Asilbek beradi yoki config).
- entry_ovqat tur check: obed|zavtrak|kechki. Takror: kuniga 1 obed + 1 zavtrak + 1 kechki (har biri 1 marta).
- Panel: 3 toggle (zavtrak/obed/kechki). Counter 3 tur bo'yicha.

## 1. RBAC — to'liq tizim 🔴
Admin rollar yaratadi, har rolga amallar + tafsilot biriktiradi, hodimlarga rol beradi.

### 1.1 Rol yaratish
- Admin rol yaratadi: unique nom (masalan "Sotuvchi", "Bugalter", "Filial boshlig'i").
- Rol tahrir/o'chirish (o'chirilsa — biriktirilган hodimlar?).

### 1.2 Amallar (permissions) biriktirish
- Har rolga amallar: harajat yoza oladi, jurnal ko'ra oladi, kassa ko'ra oladi, so'rov, hisobot, sozlama... (mavjud sahifalar/amallar).
- Checkbox — rolga qaysi amal.

### 1.3 Tafsilot — xarajat turi + ovqat 🔴
- "Harajat yoza oladi" tanlansa → QAYSI xarajat turlari (box'lar):
  - Hozir hammada barcha xarajat turi ochiq. Keyin har hodimda 3-4 ta.
  - Rolga: qaysi xarajat turlari (multiselect box) — faqat o'shalar ochiladi.
- Ovqat ham tanlanadi (box):
  - 🔴 Qaysi ovqat: obed / zavtrak / kechki (har biri alohida box).
  - Masalan: kimga kompaniya FAQAT obed beradi → rolда faqat obed box → faqat obed chiqadi.
  - Qolganlari (zavtrak/kechki) — o'sha rolда yo'q → yoza olmaydi.

### 1.4 Hodimga rol berish
- Hodim (foydalanuvchi) → rol biriktiriladi (admin).
- Hodim faqat rolидаgi amallar + xarajat turlari + ovqatni ko'radi/yozadi.

## 2. 🔴 XAVFSIZLIK — chetlab o'tish MUMKIN EMAS
- 🔴 Cheklov QAT'IY — chetlab o'tish umuman mumkin bo'lmasligi kerak.
- Faqat UI emas — SERVER (RPC/RLS) darajasida:
  - Hodim rolидa yo'q xarajat turini yozsa → server RAD etadi (RPC tekshiradi).
  - Ovqat: rolда yo'q ovqat turi (masalan kechki) → server rad.
  - UI yashiradi + server bloklaydi (ikki qatlam, fail-closed).
- Ya'ni: rolда faqat obed bor → hodim boshqa (zavtrak/kechki/boshqa xarajat) yoza OLMAYDI (UI ham, server ham).

## 3. 🔴 TEZLIK — ilova sekinlashmasin (ASOSIY)
- 🔴 RBAC tekshiruvi ilovani SEKINLASHTIRMASIN.
- Permission tekshiruvi tez (indeks, cache, InitPlan naqshi — CLAUDE.md `(select auth.uid())`).
- Har amalda RBAC so'rovi — optimal (bir marta yuklab, keshlab).
- 🔴 Sahifa yuklanishida sekinlik bo'lmasin. CC tezlikni o'lchasin (oldin/keyin).

## 4. admin-dev → asosiy sahifaga ko'chirish
- Hozir RBAC (yoki shunga o'xshash) admin-dev.html da.
- 🔴 Bu funksiyani ASOSIY sahifaga (index yoki sozlama) ko'chir — admin asosiy sahifadan rol boshqaradi.
- ⚠️ CC aniqlasin: hozir admin-dev'да nima bor (perms?), qanday ko'chiriladi.

## DB (additive)
- roles (id, nom unique, izoh).
- role_permissions (role_id, amal — jurnal/kassa/harajat...).
- role_xarajat (role_id, hisob_id — qaysi xarajat turlari).
- role_ovqat (role_id, tur — obed/zavtrak/kechki).
- user_roles (user_id, role_id).
- Ovqat kechki: entry_ovqat tur check + config narx.
- 🔴 Tezlik: indekslar, permission view (keshlanadigan), RLS optimal.
- CC eng toza sxema. Fail-closed (server tekshiradi).

## ⚠️ MUHIM
- 🔴 CC AVVAL mantiq/arxitektura taklif qilsin (kod yozmasdan) — RBAC katta, xavfsizlik + tezlik muhim. Asilbek ko'radi, keyin quradi.
- Chetlab o'tish mumkin emas (server darajasi).
- Tezlik — asosiy (sekinlashmasin).
- Eski (hozirgi permission) buzilmasin — RBAC ustiga yoki almashtirish (CC eng toza).

## Fable oqimi
coder (RBAC: rol/amal/xarajat/ovqat, server tekshiruv RPC/RLS, tezlik optimal, kechki ovqat), designer (rol boshqaruv UI, xarajat/ovqat box, asosiy sahifada — Apple), tester (🔴 chetlab o'tish yo'q server darajasi, rolда yo'q xarajat/ovqat rad, tezlik sekinlashmadi, fail-closed, eski buzilmagan). 🔴 Tezlik. Dev-first. SQL additive (men RUN). Push men.

## Tartib
1. Kechki ovqat (3-tur).
2. 🔴 CC AVVAL RBAC arxitektura (mantiq + tezlik + xavfsizlik) → Asilbek ko'radi.
3. Rol yaratish + amal + xarajat/ovqat box.
4. Hodimga rol.
5. Server tekshiruv (chetlab o'tish yo'q).
6. admin-dev → asosiy sahifaga.
7. Tezlik o'lchash.
