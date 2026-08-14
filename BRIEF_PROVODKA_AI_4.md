# PROVODKA — AI 4-bosqich: streaming + thinking + Aros kontekst + Provodka DB

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Edge Function `ai-chat` (Claude Sonnet 5, web_search). Dev-first. 🔴 Eski buzilmasin. SQL additive. Push Asilbek.

## 1. STREAMING (SSE) — javob yozilib kelsin
Hozir: user javobni kutib qoladi (10-100s), ishlayaptimi bilinmaydi. Yomon UX.
- Edge Function → Claude API **streaming** (SSE, `stream: true`).
- Mijoz javobni SO'ZMA-SO'Z ko'rsatsin (Claude/ChatGPT kabi — token kelgani sari yozilib boradi).
- Timeout muammosi HAL bo'ladi (birinchi so'z 2 soniyada, user kutmaydi).
- ⚠️ pause_turn (web_search) + manba yig'ish streamда ham ishlasin — qidiruv paytida "qidiryapman" ko'rinsin, keyin javob yozilsin.

## 2. THINKING ko'rinsin (jarayon)
- AI o'ylayotganda / qidirayotganda — jarayon KO'RINSIN (Claude kabi).
- "🔍 Qidiryapman: 2026 QQS..." / "💭 O'ylayapman..." / "📖 buxgalter.uz o'qiyapman" kabi holat.
- Deeper thinking: murakkab savolда AI ko'proq o'ylasin (extended thinking / effort — savolga qarab). Oddiy savol → tez, murakkab (soliq hisobi, tahlil) → chuqurroq.
- Thinking bloki ko'rinsin (yig'iladigan/ochiladigan — "O'ylash jarayoni" bosilса ko'rinadi), lekin asosiy javob alohida.

## 3. AROS KONTEKST — biznes + moliya (system prompt)
Agent Aros'ga MOSLASHGAN bo'lsin. System prompt kengaytir:
- **Aros biznes**: Aros Market — O'zbekistonda 24 filialli chakana savdo tarmog'i (avto ehtiyot qismlar + elektronika). Filiallar, kassalar, transferlar, qarzdorlar tizimi bor.
- **Maslahatchi**: user qonun/soliq so'raganда — AI uni **Aros'ga bog'lab** javob bersin. Masalan "bu qonun Aros'ga foydali/foydasiz" — AGAR aloqasi bo'lsa. Aloqasi yo'q bo'lsa — Aros'ni majburan tiqиштирмаsin (kerak bo'lmasa aytmaydi).
- Moliya/buxgalteriya: Aros double-entry (Provodka), kassa/tur (naqd/click/payme/dollar), transfer, qarzdor kontekstini bilsin.
- ⚠️ System prompt aniq: "Sen Aros Market moliya/buxgalteriya yordamchisisan. O'zbekiston qonuni + Aros biznesini bilasan. Qonun so'ralса Aros'ga ta'sirини ayt (agar bor bo'lsa). Kerak bo'lmasa majburan bog'lама."

## 4. PROVODKA DB — doim bilib tursin (kontekst)
🔴 MUHIM: AI Provodka ma'lumotini DOIM bilsin (kassa, qoldiq, transfer, qarzdor).
- User "Yunusobod kassада qancha pul?" / "bu oy qancha transfer?" so'raса → AI DB'дан o'qиб javob.
- 🔴 XAVFSIZLIK: AI FAQAT user permission'idagi ma'lumotni ko'rsin (op_kassa_ids — ko'ra oladigan kassalar). Boshqa kassa SIZMASIN.
- Texnik: EF Provodka DB'дан (RPC/view) user ruxsatidagi ma'lumotni oladi → Claude'ga kontekst sifatida beradi. Yoki tool (function calling): AI kerak bo'lganда "kassa_qoldiq(kassa)" chaqiradi, EF permission tekshirib javob beradi.
- CC eng xavfsiz + toza yo'l: tool/function calling afzal (AI kerakли ma'lumotni so'raydi, EF permission bilan beradi) — har safar hamma DB'ni yubormaslik.
- Masalan: "Yunusobod qancha?" → AI kassa_qoldiq tool chaqiradi → EF: user Yunusobodни ko'ra oladimi? ha → qoldiq; yo'q → "ruxsatingiz yo'q".

## Tartib
1 (streaming — eng muhим, UX) → 2 (thinking ko'rinsin) → 3 (Aros system prompt) → 4 (Provodka DB tool, xavfsiz).
Fable oqimi: coder (SSE streaming EF+mijoz, thinking UI, Aros prompt, Provodka tool+permission), designer (streaming/thinking UI Claude kabi — chиroyли), tester (🔴 XAVFSIZLIK: Provodka permission sizmasin, streaming to'g'ri, tool auth). 🔴 Eski buzilmasin. Dev-first. SQL additive. Push men. To'liq hisobot.
Katta bosqich — streaming qayta yozish. Bosqichма-bosqич.
