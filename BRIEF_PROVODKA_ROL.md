# PROVODKA ROL TIZIMI — ikki repo, ikki prompt

Maqsad: har Provodka foydalanuvchisiga alohida: (1) qaysi kassalarni KO'RADI, (2) qaysi kassalar o'rtasida AMALIYOT (transfer/kirim/chiqim) qila oladi, (3) KONVERT ruxsati, (4) qaysi SAHIFALAR ochiq. Sozlash — admin-dev.html'da "Provodka sozlamalari" bo'limida. Bajarilish — Provodka'da (UI yashirish + server guard).

Oqim: admin-dev → n8n GET webhook (service key n8n credential'da) → Provodka Supabase.
n8n qismini Asilbek Claude bilan alohida quradi — quyidagi KONTRAKT bo'yicha.

---

## n8n ENDPOINT KONTRAKTI (uchchala tomon shunga tayanadi)

GET `/webhook/aros-provodka-users?uid={admin_uid}`
→ `{ok, users:[{id, full_name, role}]}` — Provodka profiles ro'yxati

GET `/webhook/aros-provodka-perms?uid={admin_uid}&user_id={uuid}`
→ `{ok, perms:{user_id, allowed_pages, kassa_scope, view_kassa_ids, op_kassa_ids, can_convert}, kassalar:[{id,code,name,subtitle,kassa_turi}]}`
(kassalar — checkbox ro'yxati uchun: section='pul', is_active, 5400 guruh chiqmaydi)

GET `/webhook/aros-provodka-perms-save?uid={admin_uid}&data={encodeURIComponent(JSON.stringify(perms))}`
→ `{ok}` — Provodka RPC `admin_set_provodka_perms(p_data jsonb)` chaqiradi

Hamma endpoint n8n ichida admin_uid'ni mavjud RBAC bilan tekshiradi (admin-check naqshi).

---

## PROMPT 1 — PROVODKA repo Claude Code'siga

Kontekst: accounts (54xx hodim kassalari, 5400 guruh, subtitle), profiles(id, full_name, role), auth Supabase. Xavfsizlik qoidalari: yangi view → security_invoker=on; yangi funksiya → REVOKE FROM public, anon; SECURITY DEFINER'da auth guard. boot(); modul oxirida.

Vazifa — foydalanuvchi ruxsatlari (SQL → PROVODKA_PERMS.sql + frontend):

1) Jadval:
```sql
CREATE TABLE IF NOT EXISTS user_perms (
  user_id        UUID PRIMARY KEY,           -- auth.users
  allowed_pages  TEXT[] NOT NULL DEFAULT '{}',   -- bo'sh = HAMMASI (admin/cheklanmagan)
  kassa_scope    TEXT NOT NULL DEFAULT 'all',    -- 'all' | 'list'
  view_kassa_ids UUID[] NOT NULL DEFAULT '{}',   -- scope='list' bo'lsa: ko'radigan kassalari
  op_kassa_ids   UUID[] NOT NULL DEFAULT '{}',   -- amaliyot qiladigan kassalari (view ichida)
  can_convert    BOOLEAN NOT NULL DEFAULT true,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by     UUID
);
```
RLS: o'qish — o'zi yoki admin; yozish — hech kim (faqat RPC).
Sahifa kalitlari (12): kassa, jurnal, professional, hisobot, balans, cashflow, qarzdor, filial, valyuta, konvert, sozlama, provodka.

2) RPClar:
- `my_perms()` → o'z ruxsatlari jsonb (yo'q bo'lsa default: hammasi ochiq). SECURITY DEFINER, faqat authenticated.
- `admin_set_provodka_perms(p_data jsonb)` — SECURITY DEFINER, service_role ONLY (n8n chaqiradi). Ichida: op_kassa_ids ⊆ view_kassa_ids majburlash (ortiqchasini kesib tashla), profiles.role='admin' bo'lgan userga cheklov YOZILMAYDI (admin doim to'liq).

3) SERVER GUARD — yozuv nuqtalariga tekshiruv qo'sh (asosiysi shu, UI yashirish yetarli emas):
- Tezkor kirim/chiqim/transfer yozadigan RPC/yo'l: ishlatilayotgan pul-hisoblar op ro'yxatida ekanini tekshir (scope='list' bo'lsa)
- `convert_start`: can_convert=false → xato "Konvert ruxsati yo'q"
- Professional insert: satrlardagi section='pul' hisoblar op ro'yxatida bo'lsin
- Tekshiruv yordamchisi: `perm_check_accounts(p_ids uuid[]) returns boolean` — RPClarda qayta ishlat

4) FRONTEND (barcha 12 sahifa):
- boot'da `my_perms()` → global PERMS
- Nav: allowed_pages bo'sh emas bo'lsa — ro'yxatda yo'q sahifalar sidebar/bnav'dan yashirinadi; to'g'ridan URL ochilsa "Ruxsat yo'q" ekrani
- kassa.html: scope='list' → faqat view_kassa_ids kartalari (guruh ichida ham); jami summalar faqat ko'ringanlardan
- Tanlagichlar (transfer/kirim/chiqim/professional/jurnal filtri): scope='list' → faqat op_kassa_ids (jurnal filtri uchun view_kassa_ids)
- Konvert tugma/sahifa: can_convert=false → yashirin
- Server xato qaytarsa (guard) — toast aniq matn bilan
- Kesh: PERMS sessiyada 1 marta; sozlama o'zgarsa relogin/refresh yetarli (real-time shart emas)

Sinov senariysi yoz: test user → faqat 2 kassa view, 1 kassa op, konvert yo'q, faqat kassa+jurnal sahifalar → har chekni tekshir.

---

## PROMPT 2 — arosmarket-dashboard repo Claude Code'siga (admin-dev.html)

Kontekst: admin-dev.html naqshlari — sidebar `data-screen` + `goto()` + `renderScreen` switch; `api('endpoint',{uid:UID,...})` hamma GET; `topbar()`, `escapeHtml`, skeleton, `cache` obyekt; RBAC ekrani (renderRoles/renderRolesUI) — vizual namuna. Tabler ikonlar.

Vazifa — yangi ekran "Provodka sozlamalari":

1) Sidebar: "Boshqaruv" guruhiga `data-screen="provodka-sozlama"` (ikon: ti-cash-register yoki ti-adjustments-dollar), renderScreen switch'ga case.
2) Ekran tuzilishi (renderRoles naqshidek ikki panel):
   - Chapda: Provodka userlar ro'yxati — `api('aros-provodka-users',{uid:UID})`; har userda ism + rol badge; admin'lar "to'liq huquq" belgisi bilan, tanlanmaydi
   - O'ngda tanlangan user sozlamalari — `api('aros-provodka-perms',{uid:UID,user_id})`:
     a. SAHIFALAR — 12 checkbox (kassa, jurnal, professional, hisobot, balans, cashflow, qarzdor, filial, valyuta, konvert, sozlama, provodka) + "Hammasi" tez tugma. Bo'sh = hammasi ochiq (izoh ko'rsat)
     b. KASSA KO'RISH — radio: "Barcha kassalar" / "Faqat tanlanganlar" → checkbox ro'yxat (javobdagi kassalar: guruhlab — Markaziy/Filial/Xarajat; hodim kassalari "Ism · Filial · Lavozim")
     c. AMALIYOT KASSALARI — xuddi shu ro'yxat, faqat KO'RISH'da belgilanganlar ichidan (view'dan olib tashlansa op'dan ham avtomatik o'chadi)
     d. KONVERT — bitta toggle
3) Saqlash: `api('aros-provodka-perms-save',{uid:UID,data:encodeURIComponent(JSON.stringify(perms))})` → muvaffaqiyatda toast, xatoda matn
4) Diqqat: bu ekran faqat mavjud `hasPerm` tizimida tegishli ruxsati borlarga (masalan yangi 'provodka_settings' permission kaliti — RBAC ro'yxatiga qanday qo'shilishini renderRoles ma'lumotidan aniqla; agar server tomonsiz bo'lmasa, hozircha has_admin_access yetarli, izoh qoldir)
5) Endpointlar hali tayyor bo'lmasligi mumkin — xato holatida chiroyli empty-state ("n8n endpoint hali ulanmagan")

Yangi ID prefiks: pvs*. Sintaksis tekshiruv (fayl vanilla JS bitta HTML).
