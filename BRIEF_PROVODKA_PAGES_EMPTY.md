# PROVODKA — "bo'sh allowed_pages = HECH QANDAY ruxsat" (semantika teskari aylandi)

Bu brief PROVODKA repo Claude Code'si uchun. Admin tomoni (arosmarket-dashboard / `admin-dev.html`)
allaqachon o'zgartirildi — **endpoint kontrakti o'zgarmadi**, faqat talqin (semantika) o'zgardi.

---

## 1. NIMA UCHUN

Userlarning ~80% i Provodka'ga umuman kirmaydi — ular faqat `hodim.html` (xarajat kiritish)
sahifasini ishlatadi. Hozirgi qoida (`user_perms.allowed_pages` bo'sh = HAMMA sahifa ochiq)
buni imkonsiz qiladi: adminda "hech qaysi sahifa" degan holat yo'q — bo'shatsang, aksincha,
hammasi ochilib ketadi.

**Yangi qoida:**

| `allowed_pages` | Eski talqin | Yangi talqin |
|---|---|---|
| `{}` (bo'sh) | hamma 12 sahifa ochiq | **hech qaysi sahifa ochiq emas** |
| `{kassa,jurnal}` | faqat shu 2 tasi | faqat shu 2 tasi (o'zgarmadi) |
| 12 tasi to'liq | hammasi | hammasi (o'zgarmadi) |

`is_admin` / `role='admin'` — hech qachon cheklanmaydi (mavjud qoida saqlanadi).

**MUHIM:** `hodim.html` bu 12 sahifa ro'yxatiga KIRMAYDI va `allowed_pages` bilan
cheklanmasligi kerak. Bo'sh ro'yxatli user ham `hodim.html` ga bemalol kiradi —
butun o'zgarishning maqsadi shu.

---

## 2. ADMIN TOMONDA NIMA QILINDI (ma'lumot uchun, o'zgartirish shart emas)

`admin-dev.html` → "Provodka sozlamalari" ekrani:
- "Cheklovsiz" tugmasi → "Tozalash" (ro'yxatni bo'shatadi = ruxsat yo'q).
- Izoh matni: "Hech qaysi sahifa belgilanmagan = userga hech qaysi sahifa ochiq emas".
- Bo'sh holda saqlansa toast ogohlantiradi.
- Filiallar bloki to'lov turi bo'yicha guruhlandi (pastda, 5-bo'lim).

`aros-provodka-perms-save` payload'i **aynan avvalgidek**:
```json
{ "user_id":"...", "allowed_pages":[], "kassa_scope":"all", "view_kassa_ids":[],
  "op_kassa_ids":[], "filial_scope":"all", "filial_ids":[], "can_convert":true }
```
Ya'ni n8n va RPC imzosi o'zgarmaydi — faqat Provodka `{}` ni qanday o'qishi o'zgaradi.

---

## 3. SQL (PROVODKA repo)

### 3.1 `my_perms()`
Hozir: user_perms'da satr topilmasa yoki `allowed_pages` bo'sh bo'lsa — "hammasi ochiq" default qaytaradi.
Kerak: **satr yo'q bo'lsa ham, bo'sh bo'lsa ham → `allowed_pages: []` (ruxsat yo'q)**.
Boshqa maydonlar defaulti o'zgarmaydi (`kassa_scope='all'`, `can_convert=true` — pul cheklovi
alohida masala, uni buzmaymiz).

Javobga qulaylik uchun bitta hisoblangan bayroq qo'shilsa yaxshi bo'ladi (frontend takror
hisoblamasligi uchun):
```
"is_admin": true|false,      -- profiles.role='admin'
"has_provodka": true|false   -- is_admin OR array_length(allowed_pages,1) > 0
```

### 3.2 MIGRATSIYA — bu qadam majburiy, aks holda hamma user Provodka'dan chiqib qoladi
Semantika teskari bo'lgani uchun, hozir user_perms satri yo'q (yoki bo'sh) bo'lgan
HAMMA user avtomatik "ruxsat yo'q" ga tushadi. Shu sabab deploy'dan OLDIN hozir
Provodka'dan haqiqatan foydalanayotgan userlarga 12 sahifa yozib qo'yiladi:

```sql
-- Hozirgi holat (bo'sh = hammasi) ni yangi semantikaga aynan ko'chirish
insert into user_perms (user_id, allowed_pages)
select p.id,
       array['kassa','jurnal','professional','hisobot','balans','cashflow',
             'qarzdor','filial','valyuta','konvert','sozlama','provodka']
from profiles p
where p.id not in (select user_id from user_perms)
on conflict (user_id) do nothing;

update user_perms
set allowed_pages = array['kassa','jurnal','professional','hisobot','balans','cashflow',
                          'qarzdor','filial','valyuta','konvert','sozlama','provodka']
where coalesce(array_length(allowed_pages,1),0) = 0;
```

⚠️ Bu "hech kimdan hech narsa olib qo'yilmasin" varianti. Agar Laziz aksincha —
"hammani yopib, keyin 20% ga qo'lda ochib chiqaman" desa, bu blokni umuman
ishlatmaslik kerak (unda deploy'dan keyin admin-dev'dan qo'lda belgilanadi).
**Qaysi variant kerakligini so'rab ol.**

### 3.3 `admin_set_provodka_perms(p_data jsonb)`
- Bo'sh `allowed_pages` massivini **shundayligicha yozsin** — "bo'sh kelsa 12 tasini to'ldirish"
  kabi eski "himoya" mantiqi bo'lsa, olib tashlansin.
- `role='admin'` userga cheklov yozilmaydi — mavjud qoida saqlanadi.

### 3.4 Server guard (ixtiyoriy, lekin tavsiya)
Sahifa ruxsati asosan UI masalasi, lekin ma'lumot o'qish RPC'lari bo'lsa —
`allowed_pages` bo'sh userga Provodka ma'lumotini qaytarmaslik uchun
`perm_has_page(p_key text) returns boolean` yordamchisi qo'shilsa bo'ladi.
Pul yozuvlari guardi (`op_kassa_ids`, `can_convert`) allaqachon bor — u tegilmaydi.

---

## 4. FRONTEND (Provodka, 12 sahifa + kirish oqimi)

1. **Boot** — `my_perms()` → global `PERMS` (mavjud naqsh).
2. **Nav** — `allowed_pages` da yo'q sahifa sidebar/bnav'da ko'rinmaydi. Bo'sh bo'lsa —
   sidebar/bnav butunlay bo'sh qolmasin, uni yashirish yoki faqat "Chiqish" qoldirish.
3. **To'g'ridan URL bilan kirsa** — "Ruxsat yo'q" ekrani (mavjud naqsh). Bo'sh ro'yxatli
   user uchun bu ekran chalg'itmasligi kerak: matn aniq bo'lsin —
   *"Sizga Provodka sahifalari ochilmagan. Xarajat kiritish uchun hodim sahifasiga o'ting."*
   + `hodim.html` ga tugma.
4. **Kirish/landing oqimi (eng muhimi)** — login'dan keyin yoki index'ga kirganda
   `has_provodka === false` bo'lsa **darhol `hodim.html` ga redirect**. 80% user
   "Ruxsat yo'q" ekranini umuman ko'rmasligi kerak.
5. **`hodim.html` cheklanmaydi** — `allowed_pages` tekshiruvi bu sahifaga QO'YILMASIN.
   (Agar kelajakda hodim sahifasini ham yopish kerak bo'lsa — alohida `hodim` kaliti
   qo'shiladi, hozir emas.)
6. **Admin** — `is_admin` bo'lsa hamma tekshiruv chetlab o'tiladi.
7. **Kesh** — `PERMS` sessiyada 1 marta (mavjud naqsh); sozlama o'zgarsa relogin yetarli.

---

## 5. FILIALLAR — kichik qo'shimcha (admin tomonda qilindi, Provodka'da tekshirish kerak)

Muammo: accounts'da bitta filial to'lov turiga qarab bir necha kassaga bo'lingan —
"Izza Showroom Naqd", "Izza Showroom Click", "Izza Showroom Terminal". Admin ekranida
ular alohida-alohida checkbox bo'lib chiqayotgan edi; hodim esa FILIALNI tanlaydi,
to'lov turini emas.

Admin tomonda: ro'yxat filial nomi bo'yicha guruhlandi (nom oxiridagi to'lov turi
so'zi kesiladi), bitta filial = bitta checkbox. Belgilansa — o'sha filialning
**hamma kassa id'lari** `filial_ids` ga yoziladi. Ya'ni `filial_ids uuid[]`
kontrakti o'zgarmadi, faqat to'plam to'liqroq bo'ladi.

Provodka tomonda tekshirilsin:
- `hodim.html` / `professional.html` filial multiselect'i qaysi manbadan keladi?
  Agar `v_filial_tanlov` ham to'lov turi bo'yicha bo'lingan bo'lsa — hodim ham
  "Izza Showroom Naqd/Click" ni alohida ko'radi, bu ham noto'g'ri. U holda view
  filial nomi bo'yicha DISTINCT qilinsin (yoki `filial_ids` bir nechta id'ga
  moslab guruhlansin).
- Filtr mantig'i `filial_ids.includes(id)` bo'lgani uchun, admin hamma id'ni
  yozayotgani bilan hech narsa buzilmaydi.

---

## 6. SINOV SENARIYSI

1. Test user A — admin-dev'da hamma sahifa checkbox'i tozalangan, saqlangan.
   → login → `hodim.html` ga tushadi; sidebar'da Provodka sahifalari yo'q;
   `kassa.html` ni URL bilan ochsa → "Ruxsat yo'q" + hodim sahifasiga tugma.
   → xarajat kiritish ishlaydi (kassa/filial cheklovlari o'z holicha).
2. Test user B — faqat `kassa` + `jurnal` belgilangan → shu 2 sahifa ochiq, qolgani yo'q.
3. Admin — hech narsa o'zgarmaydi, hammasi ochiq.
4. Migratsiya tekshiruvi — deploy'dan keyin hozirgi faol Provodka userlari sahifalarini
   yo'qotmaganini tasdiqla (3.2 dagi variantga qarab).

## Tartib
`my_perms()` → migratsiya → frontend nav/landing → sinov. Har bosqich alohida commit.
