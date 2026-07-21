# PROVODKA professional.html — soddalashtirilgan yozuv (avtomatik Dt/Kt)

Kontekst: professional.html hozir 2-qatorli (foydalanuvchi Dt va Kt ni qo'lda tanlaydi). Yangi oqim: foydalanuvchi FAQAT (1) o'z kassasini bosib tanlaydi, (2) modda tanlaydi, (3) summa kiritadi. Ikki tomonli yozuvning ikkinchi tomoni (kassa) modda turidan avtomatik aniqlanadi.

Qat'iy: node --check; boot() modul oxirida; hozirgi to'liq (advanced) rejim SINMASIN — bu yangi soddalashtirilgan rejim yonида, yoki almashtirsa ham eski funksional yo'qolmasin. Perms (PERMS.op_kassa_ids / view_kassa_ids) hisobga olinsin.

## Mantiq — modda turi yo'nalishni belgilaydi
- Modda `type`:
  - **xarajat** (masalan 9110, 94xx, 9810): pul chiqadi → **Dt = xarajat modda, Kt = kassa**
  - **daromad** (9010, 9020): pul kiradi → **Dt = kassa, Kt = daromad modda**
  - **boshqa/aktiv** (01xx "Mashina va uskunalar" kabi): bu kapital xarajat — pul chiqadi → **Dt = aktiv modda, Kt = kassa** (xarajatdek). Agar boshqa `type`lar bo'lsa (passiv/kapital) — o'zing ko'r, lekin asosiysi: pul kassadan chiqsa Kt=kassa, kirsa Dt=kassa. Modda ro'yxatida `type` bor (v_hisob_royxat / accounts.type) — shundan aniqla.
- Ya'ni foydalanuvchi Dt/Kt tanlamaydi — faqat modda + kassa + summa. Yo'nalish `type`dan.

## Kassa tanlash — chip/karta, dropdown EMAS
- Foydalanuvchining ruxsat berilgan kassalari (amaliyot uchun — `op_kassa_ids`; scope='all' bo'lsa hammasi) sahifada KO'RINIB turadi — bosiladigan chip/karta ro'yxati sifatida (dropdown emas).
- Bittasini bosib tanlaydi (tanlangani belgilanadi). Bitta bo'lsa — avtomatik tanlangan.
- Bu kassalar `op_kassa_ids` bo'yicha (yozuv = amaliyot). scope='all' → hamma pul kassalari (5400 guruh chiqmaydi, filial asosiy kassasi — o'zing hal qil: professional xarajat filialга yoziladimi? Hozirgi qoidada filialда konvert yo'q, lekin xarajat/yozuv bo'lishi mumkin — mavjud xatti-harakatni buzma).

## Forma (soddalashtirilgan)
Sana | Izoh | [Kassa chiplari — bittasini tanla] | Modda tanla | Summa | Saqlash
- Modda tanlagichi hozirgi optgroup ro'yxati (Xarajatlar/Daromadlar/Boshqa) — o'zgarmaydi.
- Saqlash: type'ga qarab entry + 2 entry_line yoz (Dt/Kt avtomatik). Hozirgi insert mantig'ini (entry/entry_line, source, created_by) qayta ishlat — faqat Dt/Kt tomonlarini type'dan hisobla.

## Server guard
- Yozuvda kassa `op_kassa_ids`da bo'lishi kerak (mavjud entry_line trigger buni allaqachon tekshiradi — soddalashtirilgan rejim ham xuddi shu insert yo'lidan ketsin, guard avtomat ishlaydi).

## Advanced rejim
- Agar hozirgi qo'lda Dt/Kt tanlash kerak bo'lib qolsa (murakkab yozuv, masalan kassadan-kassaga emas transfer) — "Kengaytirilgan" tugma/rejim ostida saqla. Yoki jurnal/kiritish (provodka.html) o'sha vazifani bajaradi — agar shunday bo'lsa, izohда ayt. Oddiy foydalanuvchi soddalashtirilganini ko'radi.

## Sinov
- Test user (op = 1-2 kassa): professional ochsin → o'z kassalari chip sifatida → birini bos → xarajat modda (9412) + summa → Saqlash → jurnalда Dt=9412, Kt=kassa to'g'ri; daromad (9010) → Dt=kassa, Kt=9010.
- Ruxsatsiz kassaга yozib bo'lmasin (chipда yo'q + server rad).

Har bosqichда commit; push foydalanuvchida. Oxиrida: o'zgargan fayllar + sinov natijаси.
