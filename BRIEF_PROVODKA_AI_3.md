# PROVODKA — AI 3-bosqich: web_search + suhbat tarixi + fayl + floating button

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Edge Function `ai-chat` bor (Claude Sonnet 5). Dev-first. 🔴 Eski buzilmasin. SQL additive. Push Asilbek.

## 1. web_search — AI o'zi qidirsin (real-time qonun)
Hozir AI "lex.uz'ga boring" deb MASLAHAT beryapti — bu NOTO'G'RI. AI O'ZI borib, o'qib, javob berishi kerak.
- Edge Function `ai-chat` dagi Claude API'ga **web_search tool** qo'sh (`{"type":"web_search_20250305","name":"web_search"}`).
- System prompt: qonun/soliq/pul aylanma savolда AI web_search ISHLATSIN (lex.uz, soliq.uz, buxgalter.uz, gazeta.uz), o'qиб, aniq javob bersin + manba (URL) ko'rsatsin. "Boring" demasin — o'zi borib kelsin.
- ⚠️ CC eslatmasi (o'zi yozgan): Sonnet 5 thinking:disabled holatda toolни kam chaqiradi. web_search qo'shilganda thinking'ni adaptive qil yoki effort'ni ko'tar — aks holda qidirmasdan xotiradan javob beradi (real-time qonunда eng yomon). Buni hal qil.
- Javob: qonun matnи + manba havolasi. Eng yangi (2026) ma'lumot.

## 2. Suhbat tarixi — DB, har user o'zi (ChatGPT/Claude kabi)
- Suhbatlar **DB'да saqlansin** (xotirada emas — hozir yopsa yo'qoladi).
- Har user FAQAT o'z suhbatlarini ko'rsin (RLS — user_id = auth.uid()).
- **Yon panel** (ChatGPT/Claude kabi): chapda eski suhbatlar ro'yxati, har biri sarlavha bilan (birinchi savoldan avtomat).
- Yangi suhbat tugmasi (+) → yangisi ochiladi, eskisi ro'yxatда qoladi.
- Suhbatni ochish → o'sha suhbat xabarlari ko'rinadi (davom etish mumkin).
- SQL: `ai_conversations` (id, user_id, title, created_at, updated_at) + `ai_messages` (id, conversation_id, role, content, created_at). RLS: user_id = auth.uid(). CC eng toza sxema.
- 🔴 XAVFSIZLIK: RLS — boshqa userning suhbati SIZMASIN.

## 3. Fayl + rasm yuklash (chatда)
- Bitta chatда **max 10 rasm** va **10 MB gacha fayl**.
- Rasm → Claude API'ga base64 (image blok). Claude rasmni ko'radi/tahlil qiladi (masalan chek rasmi, hisobot).
- Fayl (PDF va h.k.) → Claude API document blok (base64).
- UI: yuklash tugmasi (📎), rasm preview, fayl nomi. Limit tekshiruv (10 rasm, 10 MB — oshsa {error}).
- ⚠️ Katta fayl base64 EF limit — CC tekshirsin (10 MB request hajmi). Kerak bo'lsa Supabase Storage orqali.

## 4. Floating AI button — har sahifada
- Boshqa Provodka sahifalarida (professional, kassa, hisobot...) — kичik dumaloq **AI button** (o'ng past burchak, floating).
- Bosilganda → AI chat ochiladi (modal yoki panel) — boshqa sahifада turgan holда AI bilan gaplashish.
- ⚠️ Faqat "AI agent" ruxsati bор userга ko'rinsin (permission).
- ⚠️ 15 sahifага qo'shiladi — CC eng toza yo'l (umumiy JS komponenti, har faylга kам qo'shiladi). ai-dev.html to'liq sahifa qoladi, floating — qisqa versiя yoki o'sha panelга havola.

## Tartib
1 (web_search — eng muhим, AI o'zi qidirsin) → 2 (suhbat tarixi DB + yon panel) → 3 (fayl/rasm) → 4 (floating button).
Fable oqimi: coder (EF web_search, DB suhbat, fayl, floating), designer (chat panel ChatGPT kabi, floating button, fayl preview — Apple), tester (🔴 RLS suhbat sizmasin, web_search real-time keladi, fayl limit, permission). 🔴 Eski buzilmasin. Dev-first. SQL additive (men RUN). Push men. Menga to'liq hisobot.
