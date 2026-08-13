# PROVODKA — AI Agent (moliya + O'zbekiston qonunchiligi chat)

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first (-dev.html → promote.sh). 🔴 Eski buzilmasin. SQL additive. Push Asilbek. Katta feature — bosqichma-bosqich.

## Umumiy
Provodka ichida AI chat agent. User u bilan chat orqali gaplashadi. Ikki vazifa:
1. **Provodka ma'lumoti** — kassalar, transferlar, qoldiqlar, transactionlar haqida savol-javob (user permission bo'yicha cheklangan).
2. **O'zbekiston qonunchiligi** — soliq, pul aylanma, buxgalteriya qonunlari. REAL-TIME (web search — lex.uz, buxgalter.uz, gazeta.uz). Har kunlik qonunlardan xabardor, ayniqsa soliq va pul aylanma.

## Texnik — Claude API
- Chat oyna (Provodka sahifasida, masalan alohida "AI" tab yoki tugma).
- Har xabar → Claude API (`claude-sonnet-4-6`, max_tokens 1000+). System prompt: "Sen Provodka moliya yordamchisi, O'zbekiston soliq/buxgalteriya/pul aylanma eksperti. O'zbekcha javob ber. Aniq, qonunga asoslangan."
- ⚠️ API key HIMOYALANGAN bo'lsin — frontend'да ochiq EMAS. Supabase Edge Function orqali (API key server tomonda, n8n EMAS — Provodka'да Edge Function afzal). Frontend → Edge Function → Claude API → javob.
- **web_search tool** — Claude API'да yoqilsin (real-time qonun uchun). lex.uz, buxgalter.uz, gazeta.uz, soliq.uz.
- Suhbat tarixi — session (yoki DB'да saqlansa yaxshi, keyingi safar davom).

## Provodka konteksti (xavfsiz)
- Agent user savol berganда — kerak bo'lsa Provodka DB'дан ma'lumot oladi (kassa qoldiq, transfer, transaction).
- 🔴 XAVFSIZLIK: agent FAQAT user ko'ra oladigan ma'lumotni ko'rsin (permission bo'yicha). CC eng xavfsizini tanlasin:
  - User permission (op_kassa_ids, ko'ra oladigan kassalar) bo'yicha cheklangan.
  - Boshqa user/kassa ma'lumoti SIZMASIN.
  - Edge Function user auth'ини tekshirsin, faqat uning ruxsatidagi ma'lumotni Claude'ga bersin.
- Masalan: "Yunusobod kassada qancha pul bor?" → agar user Yunusobodни ko'ra olsa → javob; ko'ra olmasa → "ruxsatingiz yo'q".

## Permission — admin-dev
- admin-dev.html sozlamада har user uchun **"AI agent"** permission (boshqa ruxsatlar kabi — checkbox/toggle).
- Yoqilган user → Provodka'да AI chat ko'radi/ishlatadi. Yoqilмаган → ko'rmaydi.
- DB: permission tizimига qo'shiladi (op_* kabi, masalan `op_ai_agent` yoки profiles/perms'да).
- CC mavjud permission tizimini (admin_set_provodka_perms, perms.js) ko'rib, o'shanga qo'shsin.

## Bosqichlar
1. **Chat UI** — Provodka'да chat oyna (AI tab/tugma), permission bilan ko'rinadi.
2. **Edge Function** — Claude API proxy (API key server, web_search yoqilgan).
3. **Qonunchilik** — web_search bilan real-time (test: "2026 QQS stavkasi necha foiz?").
4. **Provodka konteksti** — user savolига DB'дан (permission bo'yicha) ma'lumot qo'shish (xavfsiz).
5. **Permission** — admin-dev'да AI agent toggle.

## Amalga oshirish
- coder — Edge Function (Claude API + web_search + auth/permission tekshiruv), chat UI, permission qo'shish. API key Supabase secret'да.
- designer — chat UI chiroyli (Apple, message bubbles, typing indicator).
- tester — 🔴 XAVFSIZLIK ENG MUHIM: agent boshqa user ma'lumotini sizdirmaydimi (permission), API key ochiq emasmi, prompt injection (user "boshqa kassani ko'rsat" desa permission tekshirilsinmi). Qonunchilik javobi real-time keladimi.

## Tartib
1 (chat UI + permission) → 2 (Edge Function + Claude API) → 3 (web_search qonun) → 4 (Provodka kontekst xavfsiz).
🔴 XAVFSIZLIK — API key server, permission bo'yicha ma'lumot, boshqa user sizmasin. n8n EMAS (Edge Function). Dev-first. SQL additive. Push men. Menга to'liq hisobot: nima qilindi, xavfsizlik qanday, test.
