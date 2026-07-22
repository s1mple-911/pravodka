# PROVODKA V6 — xarajatga filial+davr, sozlama 2 checkbox, balans layout

Kontekst: hodim.html/sozlama/jurnal/balans ishlayapti. entry insert yo'li (2 entry_line, pul kassadan) O'ZGARMAYDI — filial va davr faqat QO'SHIMCHA metadata (buxgalteriya emas). boot() modul oxirida; node --check; perms; guard trigger mavjud. Ranglar Aros brend (mavjud CSS o'zgaruvchilaridan — yangi rang o'ylab topma, --accent/--primary va h.k. ishlat).

## DB (PROVODKA_V6.sql — Asilbek RUN qiladi)
- entry jadvaliga 3 ustun:
  - `filial_ids UUID[] NOT NULL DEFAULT '{}'` — tanlangan filial(lar). MULTISELECT. MUHIM: bu faqat metadata (biz uchun — qaysi filialга tegishli); pul FAQAT tanlangan kassadan yechiladi, entry_line O'ZGARMAYDI.
  - `davr_start DATE`, `davr_end DATE` — sana oralig'i (ixtiyoriy, checkbox majburiy qilsa to'ldiriladi).
- accounts jadvaliga 2 checkbox ustun (chek_majburiy naqshi — bu allaqachon bor):
  - `izoh_majburiy BOOLEAN NOT NULL DEFAULT false`
  - `davr_majburiy BOOLEAN NOT NULL DEFAULT false`  (kalendar/sana oralig'i majburiy)
- RPC yangilash: xarajat saqlash RPC/yo'li (hodim.html va professional.html ishlatadigan insert) endi filial_ids, davr_start, davr_end ni ham qabul qilib entry'ga yozsin. Agar insert to'g'ridan frontend'dan bo'lsa (entry insert), shu ustunlarni qo'sh.
- set_izoh_majburiy(p_account, p_bool) va set_davr_majburiy(p_account, p_bool) — admin only (is_admin), SECURITY DEFINER, REVOKE anon. (yoki mavjud set_chek_majburiy'ni umumlashtir: set_modda_flag(p_account, p_flag text, p_bool) — 'chek'|'izoh'|'davr'. Toza bo'lsa shu.)
- Filiallar ro'yxati: accounts kassa_turi='filial' (yoki filial_ref bor) — nomi bilan. Frontend shundan multiselect to'ldiradi.

## 1. sozlama.html — 2 yangi checkbox (Xarajat tabида)
Hozir har xarajat moddasida "Chek" checkbox bor. Yoniga 2 ta:
- "Izoh" — tanlansa o'sha modда uchun izoh MAJBURIY.
- "Sana" (yoki "Davr") — tanlansa o'sha modда uchun sana oralig'i (start–end) MAJBURIY.
Har biri darrov saqlanadi (RPC), xatoда revert. Chek checkbox naqshini takrorla.

## 2. hodim.html — filial multiselect + shartli izoh/kalendar
Modда tanlangandan keyin (uning flaglarига qараб):
- **Filial (multiselect)**: har doim ko'rsat (yoki agar filial_majburiy degan alohида flag xohласанг — lekin Asilbek "filialни sozlамада checkbox" demadi, filial har xarajатда tanlаnadi. Hozирча: filial tanlash HAR DOIM mavjud, lekin ixtiyoriy — modда flag'и yo'q. Faqat izoh va davr sozlамада checkbox bilan majburий). 
  - Multiselect UI: filiallarни chip sifatида ko'rsат, bosса tanlanadi (ko'p tanlash), Aros brend rangда belgиланади. Tanlanган filiallar entry.filial_ids ga.
- **Izoh**: agar modда.izoh_majburiy=true → izoh maydoni majburий (bo'sh bo'lса Saqlash disabled + "Izoh shart").
- **Kalendar (davr)**: agar модда.davr_majburiy=true → start va end sana tanlagich chиqсин (2 date input yoki oralиq picker), majburий (to'lмаса Saqlash disabled). entry.davr_start/end ga.
- Saqlаш: entry'га summа/modда/kassа + filial_ids + davr_start/end. Pul faqat kassадан (o'zгармайди).

## 3. professional.html — xuddi shu (agar oson bo'lsa)
Professional oddiy rejimда ham filial multiselect + shartли izoh/davr. Agar vaqт ketса — hodim.html birinchi, professional keyин. Lekin DB/RPC ikkаласини qo'llаб-quvvатласин.

## 4. jurnal.html — filial + davr ko'rinsin
- Har xarajат yozувида (chek 📎 yonида): tanlangan filial(lar) nomи + davr (start–end) ko'ринсин. Ustига bosса yoki qatор ostида — "Filiallar: X, Y · Davr: 01.07–15.07".
- Ma'lумот entry.filial_ids (→ accounts nomlарига map) + davr_start/end.

## 5. balans.html — layout qayta (aktiv + pul/tovar yonma-yon)
Hozир: yuqорида Aktiv, pastида filialдаги pullar, yana pastида filialдаги tovarlar (ustma-ust, uzun).
Kerак: **Aktiv bitta keng row**, ostида **Pul** va **Tovar** YONMA-YON (2 ustun, yonma-yon kartалар) — ixchamroq, chиройliroq view. Mobилда bir ustunга tushсин (responsive). Ma'lумот/hisоб o'zгармайди — faqat joylашuv (layout/grid). Aros brend ranglар.

## Tartиб
DB (V6.sql) → 1 (sozlama checkbox) → 2 (hodim filial/izoh/kalendar) → 4 (jurnal ko'rсатиш) → 5 (balans layout) → 3 (professional — vaqt bo'lса). Har bosqич commit; push Asilbekда. Oxирida: fayllar + SQL + sinov (filial multiselect tanla, izoh/davr majburий modда sinа, jurnalда ko'рин, balans yangi layout).
