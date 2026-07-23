# PROVODKA — hodim qaysi filiallarga xarajat qila oladi (perm)

Kontekst: V6'da xarajatga filial multiselect qo'shildi (entry.filial_ids — faqat metadata, pul kassadan). Hozir hodim HAMMA 31 filialni ko'radi. Kerak: admin har userga ko'rinadigan filiallarni belgilaydi.

Bu `op_kassa_ids`dan ALOHIDA: op_kassa = qaysi kassadan pul chiqaradi; filial = xarajat qaysi filialga tegishli (metadata).

Filiallar manbai: accounts `kassa_turi='filial'` (5201–5231) — V6'dagi `v_filial_tanlov` view.

---

## 1. PROVODKA — SQL (PROVODKA_FILIAL_PERM.sql)
`user_perms` jadvaliga 2 ustun:
```sql
alter table user_perms add column if not exists filial_scope text not null default 'all';   -- 'all' | 'list'
alter table user_perms add column if not exists filial_ids uuid[] not null default '{}';
```
- `my_perms()` javobiga `filial_scope`, `filial_ids` qo'shilsin.
- `admin_set_provodka_perms(p_data jsonb)` yangi maydonlarni qabul qilsin (mavjud naqsh: noma'lum kalitni tashlaydi, admin'ga cheklov yozmaydi — shu qoidalar saqlansin).
- Server guard KERAK EMAS: filial faqat metadata, pul harakati emas. UI filtri yetarli. (Xohlasang entry insert'da filial_ids ⊆ ruxsat tekshiruvi qo'shsa bo'ladi, lekin majburiy emas — izoh qoldir.)

## 2. PROVODKA — frontend
- `hodim.html` va `professional.html` (oddiy rejim): filial multiselect `PERMS.filial_scope==='list'` bo'lsa faqat `filial_ids` filiallarini ko'rsatsin. 'all' → hammasi (hozirgidek).
- Ruxsat berilgan filial yo'q bo'lsa: multiselect o'rniga "Sizga filial biriktirilmagan" (yoki filial maydonini butunlay yashir — xarajat filialsiz saqlanaversin, chunki filial ixtiyoriy).
- Admin (is_admin) — hech qachon cheklanmaydi.

## 3. ADMIN-DEV (arosmarket-dashboard repo, admin-dev.html)
"Provodka sozlamalari" ekraniga yangi blok — mavjud "Ko'rish kassalari" naqshining aynan o'zi:
- Sarlavha: **FILIALLAR** (Konvert bloki oldidan yoki Amaliyot kassalaridan keyin).
- Radio: "Barcha filiallar" / "Faqat tanlanganlar · N"
- 'list' tanlansa — checkbox ro'yxat. Ma'lumot: endpoint javobidagi `kassalar` massividan `kassa_turi === 'filial'` filtri (yangi endpoint KERAK EMAS — filiallar allaqachon shu ro'yxatda, 5201–5231).
- Saqlashda `perms` obyektiga `filial_scope` va `filial_ids` qo'shilsin (mavjud save chaqiruvi o'zgarmaydi — n8n p_data ni shundayligicha RPC'ga uzatadi).
- ID prefiks `pvs*` (mavjud naqsh).

## Tartib
SQL → Provodka frontend → admin-dev. Har bosqich commit; push Asilbekda.
Sinov: admin-dev → userga 2 filial belgila → saqla → o'sha user hodim.html'da faqat 2 filial ko'rsin; admin hammasini ko'rsin.
