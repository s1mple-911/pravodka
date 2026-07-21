# PROVODKA — hodim/jurnal/hisobot yaxshilash (dropdown search, jurnal chek, CEO kategoriya hisobot + Excel)

Kontekst: hodim.html (chek/tez summa/oy jami), sozlama (chek_majburiy), jurnal ishlayapti. entry insert yo'li o'zgarmaydi; guard trigger (perm+qoldiq) mavjud; boot() modul oxirida; node --check; perms. Storage: private bucket xarajat-cheklari, yo'l {kassa_id}/{entry_id}.jpg.

## 1. hodim.html — xarajat modda dropdown'ga qidiruv
Modda ro'yxati uzun. Dropdown ichiga qidiruv input: yozgan sari kod yoki nom bo'yicha filtr (masalan "trans" → 9414 Transport). Mobil-friendly (katta input, tepada). Tanlangач yopiladi. "➕ Yangi tur" tugmasi qidiruvдан pastда qolsin.

## 2. jurnal.html — chek rasmi ko'rinsin
Hozir chek faqat hodim "Bugungi"да ochilardi. Jurnalда ham:
- Chek biriktirilgan yozувда 📎 belgi. Aniqlash: storage'да `xarajat-cheklari/{kassa_id}/{entry_id}.jpg` bor-yo'qligини tekshир (yoki agar V3'да chek borлиги entry'га belgилаб qo'йилган bo'lса — o'шандан). Bor bo'lса 📎.
- 📎 bosилса → signed URL (createSignedUrl) bilan rasm modalда ochилади (zoom/yopиш).
- Perms: admin/CEO hamma chekни, cheklанган user o'зиникини (mavjud jurnal perm filtri).

## 3. hisobot.html — kategoriya bo'yicha oy hisoboti (CEO)
CEO panelда (hisobot.html — mavjud sahifа yoki yo'q bo'lса yangи):
- Davr tanlаш (oy/yil yoki sana oralиg'и).
- **Kategoriya bo'yича xarajат jamи**: har xarajат moddаси (type='xarajat') bo'yича shu davrда jamи chиққан summа, kamayиш tartибида. "Transport: 5 000 000, Ijara: 3 000 000..." + umumий jamи.
- Ixtiyorий: kassа bo'yича ham (qaysи hodим/filial ko'п sarflади).
- View yoki RPC: hodim_kategoriya_hisobot(p_from, p_to) → [{code, name, jami}]. SECURITY DEFINER, REVOKE anon, admin/CEO ko'ради (perms).

## 4. hisobot.html — Excel eksport (CEO)
- Yuqoridagi hisobотni Excel/CSV yuклаб olиш. Sodda: CSV (Excel ochади) — kutubxonаsiz, klиent tomонда Blob bilan. Ustunlar: Kod, Nomи, Summа (+ kerак bo'лса kassа/sana breakdown).
- Yoki to'liq xarajат ro'yxати eksport (har yozув: sana, kassа, modда, summа, izoh, kim) — CEO tahlил uchun. Ikkаласини ber: "Xulоsа (kategoriya)" va "To'liq ro'yxат".
- Tugма: "⬇ Excel" → CSV fayl (UTF-8 BOM bilan, Excel kirил to'g'ри ko'рсатсин).

## SQL
Yangи: hodim_kategoriya_hisobot() RPC (+ kerак bo'лса to'liq ro'yxат RPC/view). → PROVODKA_HODIM_V4.sql (idempotent, security_invoker, REVOKE anon). Asilbek RUN qилади.

## Tartиб
1 (search — tez) → 2 (jurnal chek) → 3 (kategoriya hisobот) → 4 (Excel). Har bosqич commit; push Asilbekда. Oxирида: fayllar + SQL + sinov.

## Eslатма (bu brief'да EMAS, keyинги ish)
- Telegram xabar (xarajат 500k+ → yangи bot → admin): alohида n8n ishи, keyин quriladi. Hozир tegмa.
