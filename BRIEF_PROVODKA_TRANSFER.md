# PROVODKA — Transfer sync (2-bosqich: filial→markaziy, tur bo'yicha, delta bilan)

Kontekst: 1-bosqich (delta balans sync) ISHLAYAPTI — sync_filial_balans, kassa child'larga to'g'ri yozadi. Endi transfer qo'shiladi. Provodka project (kxzerccdpcltmzrxutlo). Faqat SQL/RPC. entry.created_by TEXT.

## Muammo
Filial→markaziy transfer (masalan Yunusobod click 5mln → Toshkent Kassa). Aros filial balansi buni HISOBGA OLGAN (yuborilsa filial balansi kamaygan). Hozir faqat delta sync bor → u buni "chiqim" (Dt 9010) deb yozadi, va markaziyda "savdo tushumi" deb — IKKALASI XATO (transfer, savdo emas). Hisobot buziladi.

## Aros manba
- `GET /api/admin/billing/cachier-transfers/?page_size=N` — ro'yxat: id, sender_title (filial), receiver_title (markaziy), status (sent|received|canceled), sent_at, received_at.
- `GET /api/admin/billing/cachier-transfers/{id}/` — detal: items[].document.seller_cash / seller_click / seller_payme / seller_dollar (TUR bo'yicha summa), currency_rate.

## Model
1. **Receiver mapping** (nom bo'yicha):
   - "Toshkent Kassa" → 5011
   - "Qashqadaryo Kassa" → 5012
2. **Sender** (filial) — sender_title yoki transfer'ning filial_ref'i orqali → Provodka kassa. Aniq kalit: Aros transfer'da sender cachier id bormi (detalда)? Bo'lsa filial_ref bilan mos. Bo'lmasa nom bo'yicha (ehtiyot: "Karshi"/"Qarshi").
3. **Yozuv (received bo'lganda), tur bo'yicha** — har tur (cash/click/payme/dollar) summa > 0:
   ```
   Dt <receiver markaziy.tur child> / Kt <sender filial.tur child>
   ```
   Ya'ni pul filialdan markaziyga o'tdi (tur saqlanadi: click→click).
4. **sent** (hali received emas) = yo'ldagi pul — HOZIRCHA yozilmaydi (received bo'lganda yoziladi). Yoki alohida "yo'ldagi" hisobda ko'rsatiladi — CC eng sodda to'g'ri yo'lni tanlasin.
5. **canceled** — yozilmaydi.

## ⚠️ ENG MUHIM — delta bilan ikki marta yozmaslik
Aros filial balansi transfer'ni hisobga olgan. Delta sync buni ko'radi (filial kamaydi). Transfer ham yozadi. IKKI MARTA. Yechim variantlari (CC eng to'g'risini tanlasin):
- **Variant A**: sync_filial_balans ichida — delta hisoblanganда, o'sha davr transfer summasini delta'dan AYIR: `haqiqiy_savdo = delta − (o'sha turdan ketgan transfer)`. Shunda filial delta faqat haqiqiy savdo/xarajatni yozadi, transfer alohida.
- **Variant B**: transfer'ni alohida yozib, delta'ni transfer YOZILMAGAN "xom balans"dan hisoblash. 
- Variant A sodda ko'rinadi. CC tahlil qilib tanlasin va izohlasin.

## RPC
- `sync_transfer_balans(p_data jsonb, p_dry_run boolean default false)` — transfer ro'yxati keladi (id, sender, receiver, status, tur summalar), received bo'lganlarni tur bo'yicha yozadi.
- ext_ref / takrorlanmaslik: har transfer id BIR MARTA yozilsin (ikkinchi sync o'sha transfer'ni qayta yozmasin). `entry` da transfer id saqlansin (ext_ref yoki izoh), keyingi sync tekshirsin.
- Idempotent, advisory lock, SECURITY DEFINER service_role.

## Tartib
1. CC avval o'qish/tahlil: hozirgi sync_filial_balans delta qanday hisoblaydi, transfer'ni qanday ayirish mumkin (Variant A/B).
2. `PROVODKA_TRANSFER.sql` — sync_transfer_balans RPC + delta tuzatish (ikki marta yozmaslik).
3. Dry_run bilan test.
4. Men n8n'ga transfer workflow qo'shaman (cachier-transfers o'qib RPC'ga).

CC: avval tahlil qil (delta vs transfer ikki marta yozilishini qanday oldini olamiz) — menga variant A/B tavsiyasini ber, KEYIN yoz. Bu pul harakati, ehtiyot. Push men qilaman.
