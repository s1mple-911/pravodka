# BRIEF — «5 kunlik» sahifasi

Manba: Asilbekning `Jami qarz.xlsx` faylidagi **`5 kunlik`** varag'i.
Formulalar shu fayldan aynan o'qib olindi (2026-09-11), quyida ularning
Provodkadagi muqobili yozilgan.

## Maqsad

> Shu kunga kelib biznesda qancha pul bo'ladi va qancha qarz olsa bo'ladi.

Ta'minotchi bilan to'lov sanasi shunga qarab kelishiladi — sahifaning butun
mavjudlik sababi shu.

## 🔴 Yangi qaror (Asilbek, 2026-09-12): BITTA platforma

Aksessuar/Zapchast profillari **endi ikkiga bo'linmaydi** — hamma filial
bitta platformada savdo qiladi. Sahifa endi **bitta blok** (avvalgi ikki
tomonlama 27-ustunli jadval emas):

```
Sana │ ──── Savdo · Yig'ilma · Qarz · Qoldi pul · Prognoz (15 ustun) ────
```

| Guruh | Ustunlar |
|-------|----------|
| Savdo | Reja · Uzgaradi · Fakt |
| Yig'ilma | Reja · Uzga · Fakt |
| Qarz | Qarzmiz · Berdik · Raznitsa |
| Qoldi pul | Reja · Uzga · Fakt · Raznitsa |
| Prognoz | Kutilgan pul · Qarz olsa bo'ladi |

Reja/Uzgardi profili endi `'umumiy'` (`beshkunlik_reja_profil_chk` kengaytirildi:
`'aksessuar'|'zapchast'|'umumiy'`; eski ikki profilning yig'indisi bir martalik
SQL bilan `'umumiy'`ga ko'chirilgan — eski qatorlar SAQLANADI). Qarz bloki ham
profilsiz (`beshkunlik_qarz_v2`/`beshkunlik_qarz_detal_v2`). `beshkunlik_kun`
(Fakt) hamon **profil bo'yicha muhrlanadi** (aksessuar/zapchast) — Fakt ustuni
ikkalasining YIG'INDISI, hover ikkiga bo'lib ko'rsatadi (filial kesimi bilan).

## Hisob formulalari (Excel bilan aynan, 2026-09-12 TUZATILDI)

`kecha` = oldingi kunning o'sha ustuni. Yig'ilma **UZLUKSIZ REKURSIYA**:
har kun kechagi **Qoldi**dan boshlanadi — kechagi Qarzmiz/Berdik shu bilan
avtomatik keyingi kunga o'tadi. 🔴 Eski kod xato edi: Yig'ilmani kunlik
qiymatlar yig'indisi (kumulyativ summa) qilib hisoblardi, Qoldi.Reja/Uzga/Fakt
esa alohida — natijada kechagi qarz/to'lov ta'siri keyingi kunga tushmasdi
(qarz 0 bo'lgan davrda sezilmagan, chunki farq yo'q edi). Tuzatilgan:

| Ustun | Formula | Izoh |
|-------|---------|------|
| Reja | `oylik_reja / oy_kunlari` | oyning **hamma** kuniga teng bo'linadi (yakshanba ham) |
| Uzgaradi | **avtomatik** (qo'lda D≥bugun uchun ustidan yozish mumkin) | pastdagi "Samarali Uzgaradi" bo'limiga qara |
| Fakt | Aros'dan | Aksessuar+Zapchast yig'indisi, avtomatik |
| Yig'.Reja(t) | `Qoldi.Reja(t−1) + Reja(t)` | REKURSIYA — kunlik yig'indi EMAS |
| Yig'.Uzga(t) | `Qoldi.Uzga(t−1) + SamaraliUzgaradi(t)` | REKURSIYA |
| Yig'.Fakt(t) | `Qoldi.Fakt(t−1) + Fakt(t)` | REKURSIYA |
| Qarzmiz | deadline shu kunga tushgan qarzlar (manfiy) | |
| Berdik | shu kuni haqiqatda to'langan (musbat) | 2026-09-12: HAMMA yuk to'lovi, deadline shart emas (pastga qara) |
| Raznitsa | `Qarzmiz + Berdik` | to'liq to'lansa 0 |
| Qoldi.Reja(t) | `Yig'.Reja(t) + Qarzmiz(t)` | |
| Qoldi.Uzga(t) | `Yig'.Uzga(t) + Qarzmiz(t)` | |
| Qoldi.Fakt(t) | `Yig'.Fakt(t) − Berdik(t)` | |
| Qoldi.Raznitsa(t) | `Qoldi.Uzga(t) − Qoldi.Fakt(t)` | Formula O'ZGARMAGAN, lekin Uzgaradi endi prognoz bo'lgani uchun bu amalda **qarz farqini** ko'rsatadi |

🔴 Yig'ilma **uzluksiz** — hech qachon nolga tushmaydi. «5 kunlik» faqat nom.

## Samarali Uzgaradi — avtomatik prognoz (Asilbek qarori A, 2026-09-12)

«Uzgaradi» endi asosan AVTOMATIK: ertalab (kelajak/bugun) — oxirgi 10 kunlik
savdo o'rtachasi, kun o'tgach — o'sha kunning Fakt'i. Bazaga faqat "qo'lda
yozildimi" bayrog'i qo'shildi (`beshkunlik_reja.uzgardi_qolda`) — `uzgardi`
ustunining o'zi eskisidek qoladi, faqat qo'lda yozilganda mazmunli.

`A(x)` = `[x−10, x−1]` (10 KALENDAR kun, yakshanba ham) oralig'idagi Fakt ($)
qiymatlarining o'rtachasi — faqat Fakt'i MA'LUM kunlar bo'yicha (0 savdo —
ma'lum, kiradi; Fakt yo'q/noma'lum kun — o'rtachaga kirmaydi, maxrajga ham).
Ma'lum kun 0 bo'lsa `A(x)` yo'q.

Samarali Uzgaradi(D), `T` = bugun (Toshkent):

| Holat | Formula |
|-------|---------|
| D < T, Fakt(D) ma'lum | `Fakt(D)` |
| D < T, Fakt(D) noma'lum | `A(D)`, u ham yo'q bo'lsa `Reja(D)` |
| D ≥ T, qo'lda yozilgan (`uzgardi_qolda=true`) | saqlangan `uzgardi` |
| D ≥ T, qo'lda yozilmagan | `A(T)` (kelajakdagi HAMMA kun bir xil — bugungi 10 kunlik o'rtacha), u ham yo'q bo'lsa `Reja(D)` |

«Ertalabki prognoz»(D) = `A(D)` — bazaga YOZILMAYDI, muhrlangan Fakt'dan har
doim qayta hisoblanadi (deterministik). `A(T)` uchun oxirgi 10 kunning Fakt'i
HAR DOIM olinadi — ko'rsatilgan oy boshqa bo'lsa ham: muhrlangan qatorlar +
kerak bo'lsa alohida kichik webhook chaqiruvi (`ensureFaktWindow()`), mavjud
token/race himoyasini buzmasdan.

Tahrir: Uzgaradi katagi faqat `D ≥ T` bo'lsa tahrirlanadi (o'tgan kun — faqat
o'qish; tanlash/sudrab to'ldirish/paste ularni o'tkazib yuboradi). Qo'lda
yozish (Enter, sudrab to'ldirish, Ctrl+D, paste) → `uzgardi` + `uzgardi_qolda
=true` yoziladi. Katakni bo'shatib saqlash → `uzgardi_qolda=false` (avtomatikaga
qaytadi), `uzgardi=0`. «Reja qo'yish» modali endi FAQAT `reja`ni yozadi —
`uzgardi`ga tegmaydi.

Samarali Uzgaradi ishlatiladigan joylar: Yig'.Uzga, Qoldi.Uzga, Qoldi.Raznitsa,
Prognoz (kelajak kunlari) — `buildRun()`/`computePrognoz()` shundan oladi.

Ko'rinish: avtomatik qiymat — xira/kursiv + `title` (manba: Fakt/o'rtacha/reja);
qo'lda yozilgan — oddiy + kichik nuqta belgisi, `title` «Qo'lda yozilgan».

`uzgardi_qolda` ustuni bazada yo'q bo'lsa (SQL hali RUN qilinmagan, 42703) —
sahifa yiqilmaydi: eski select'ga tushadi, hamma qator "qo'lda emas" (avtomatik)
deb olinadi, yozishda kalit yuborilmaydi.

## Fakt rangi va filtr — Reja bilan solishtiriladi (Asilbek qarori B, 2026-09-12)

`Fakt` katagining rangi (yashil/qizil, foiz `title`) endi **Reja(D)**ga
nisbatan (avval Uzgaradi'ga nisbatan edi — endi u prognoz, solishtirish uchun
mos emas). Reja 0/bo'sh bo'lsa rang yo'q. «Farqi bor kunlar» filtri: Fakt ≠
Reja. Fakt hover popover'ining yuqorisida qisqa xulosa qator: «Reja $R ·
Ertalabki prognoz $A(D) (N kun o'rtachasi) · Fakt $F · farq ±%» (`A(D)` yo'q
bo'lsa bu qator umuman chiqmaydi).

**Amalga oshirish (5kunlik-dev.html, `buildRun()`):** rekursiya bitta uzluksiz
kunli qator sifatida hisoblanadi — `START` (`beshkunlik_sozlama.boshlanish`,
bo'lmasa ma'lumotdagi eng erta sana, bo'lmasa ko'rsatilgan oy boshi) dan
`H = max(ko'rsatilgan oy oxiri, bugun+60 kun)` gacha. Boshlang'ich qoldiq
(`beshkunlik_sozlama.boshlangich_usd`) START kunidan oldingi "Qoldi" sifatida
uchala ustunga (Reja/Uzga/Fakt) qo'shiladi. Ko'rsatilgan oy — shu qatorning bir
bo'lagi; oy boshidagi ko'rsatiladigan qoldiq — oy boshidan oldingi kunning
Qoldi'si. Ko'rsatilgan oydan tashqaridagi (STARTdan buyon) muhrlanmagan o'tgan
kunlar Fakt=0 deb hisoblanadi (kichik ogohlantirish bilan) — kechasi
`beshkunlik_muhrla` ularni to'ldiradi.

## Prognoz (Kutilgan pul · Qarz olsa bo'ladi)

Maqsad: «shu kunga biznesda qancha pul bo'ladi va qancha qarz olsa bo'ladi»
savolining o'zi — Qoldi pul zanjiridan KELAJAKKA qaraydi. `T` = bugun (UZ).

| Belgi | Formula | Izoh |
|-------|---------|------|
| `B` | `Qoldi.Fakt(T)` | bugungi haqiqiy qoldiq |
| `O` | `Σ Qarzmiz(t)` t=START..T | hali to'lanmagan, muddati kelgan qarz (manfiy) |
| `K(T)` | `B + O` | |
| `K(D)`, D>T | `K(D−1) + Uzgaradi(D) + Qarzmiz(D)` | kelajakda Fakt/haqiqiy to'lov yo'q — Uzgaradi ULARNING O'RNIDA |
| Kutilgan pul(D) | D<T → `—`; D≥T → `K(D)` | |
| Qarz olsa bo'ladi(D) | D<T → `—`; D≥T → `max(0, min` `_{t=D..H} K(t))` | eng past nuqtagacha pul yetishi kerak; manfiy bo'lsa 0 + qizil + "$X yetishmaydi" |

`H` — 60 kunlik gorizont (yuqoridagi `RUN_H`). Jadval ustida qisqa xulosa:
«Bugun kutilgan: $X · 60 kun ichida eng past: $Y (sana) · Bugun qarz olsa
bo'ladi: $Z» + kelajakda reja kiritilmagan kunlar soni haqida ogohlantirish.
«Qarz olsa bo'ladi» katagi hover: qaysi kun cheklab turgani («Eng past nuqta:
24 sen — $X»).

## Ma'lumot manbalari

| Nima | Qayerdan |
|------|----------|
| **Fakt** (kunlik savdo) | `cache_calendar_daily` (n8n `Aros Market - Calendar Cache Builder`, har soat). `bajarilgan = tushum − qaytarilgan`, **so'mda** |
| **Profil** (Aksessuar/Zapchast) | `cache_filial.data->>'profil'` |
| **Qarzmiz** | Aros yuklari (`aros-provodka-yuklar` webhook) + `yuk_deadline.deadline` |
| **Berdik** | Provodkaning o'zi — `entry_yuk` (qaysi yukka qancha berildi) |
| **Reja** | `beshkunlik_reja` (qo'lda kiritiladi) |
| **Uzgardi** | `beshkunlik_reja` — asosan avtomatik hisoblanadi, qo'lda faqat D≥bugun ustidan yozilganda (2026-09-12, "Samarali Uzgaradi" bo'limiga qara) |

## Valyuta

Sahifa **dollarda**. Aros so'mda beradi.

- Kurs Provodkadan (`conv_baza_kurs`) — u faqat **joriy** kursni beradi, sanali emas.
- Shuning uchun har kun `beshkunlik_kun(savdo_uzs, savdo_usd, kurs_uzs, frozen_at)`
  ga **muhrlanadi**. Kurs keyin o'zgarsa eski kunlar o'zgarmaydi.
- Jadvalda `so'm · kurs · dollar` — so'm va kurs sukut bo'yicha **yopiq**,
  ustun sarlavhasidan ochiladi.

## Ruxsat

Repodagi mavjud `FLAGS` naqshi (`ehson_kirim` kabi):

- `beshkunlik` — sahifa, **ko'rish**
- `beshkunlik_edit` — bayroq, **tahrir** (Reja/Uzgardi yozish)

Foydalanuvchilar: CEO va ROP lar.

## Kechasi avtomatik muhrlash — vaqt tanlash sababi (2026-09-12)

n8n `cache_calendar_daily` (Aros Market - Calendar Cache Builder) har kechasi
**~01:00–01:11 (Toshkent)** oxirgi kunlarni QAYTA hisoblab chiqadi — ya'ni
"kecha"gi kun faqat shundan keyin **to'liq**. Shu sababli:

- `beshkunlik_muhrla(p_data)` (n8n, service_role, soat **02:00**da chaqiriladi)
  `sana < bugun` shartini ishlatadi — bu paytda "kecha" allaqachon to'liq.
- Sahifaning o'zi (`computeAndFreeze()`, ertalab ham ochilishi mumkin) esa
  ehtiyotkorroq: faqat `sana <= bugun−2 kun` bo'lgan kunni muhrlaydi —
  "kecha"ni tunggi RPC'ga qoldiradi, ertalabki chala raqam bilan qotib
  qolmaydi.

n8n workflow: **`Aros Provodka - 5 Kunlik Muhrlash`** (`ArNGlzjFDz3mOUd0`), cron
`0 0 21 * * *` UTC = 02:00 Toshkent. Oxirgi 60 kun (kechagacha) — sahifa ishlatadigan
AYNI webhook'dan (`aros-provodka-5kunlik-savdo`) oladi, raqamlar bir xil bo'lsin.
Javob noto'g'ri/bo'sh bo'lsa XATO beradi (jimgina 0 yo'q). Birinchi ishga tushishi
backfill ham qiladi (60 kun). Faollashtirish: SQL RUN → «Muhrla» node'ga Supabase API
(service_role) krediti → Publish.

## Kelishilgan qarorlar (2026-09-11, Asilbek)

1. **Yuk bo'lmagan qarz yo'q.** Hamma qarz — yuk. Yuklar sahifasida tannarx
   qo'shilsa, bu yerdagi Qarzmiz ham o'zgarishi kerak → qarz **jonli**
   hisoblanadi (`narx + tannarx − to'langan`), muhrlanmaydi.
2. **Omborlar Fakt'da qoladi** (`Aksessuar ombor`, `Asosiy ombor`, `1C chiqim`,
   `Distribyutsiya markazi`, `Xitoy`) — ular savdo qilmaydi, zarari yo'q.
   Excel ularni chiqarib tashlagan edi, bizda shart emas.
3. **Yig'ilma uzluksiz** — 5 kunda nolga tushmaydi.
4. **Reja oyning hamma kuniga teng bo'linadi**, yakshanba ajratilmaydi.
5. **Deadline yuklar sahifasida qo'yiladi**, 5 kunlik uni faqat o'qiydi.
   Excelda bu `Tuldiriladi!K` (`Qaytadi`) ustuni edi.
6. **Bitta platforma (2026-09-12).** Aksessuar/Zapchast profillari ikkiga
   bo'linmaydi — Reja/Uzgardi/Qarz endi profilsiz (`umumiy`), Fakt esa
   ikkalasining yig'indisi (yuqoriga qara).

## Kelishilgan qarorlar (2026-09-12, Asilbek)

7. **Uzgaradi avtomatik.** Yuqoridagi "Samarali Uzgaradi" bo'limi — 10 kunlik
   o'rtacha / Fakt / Reja zanjiri, faqat D≥bugun qo'lda ustidan yozib bo'ladi.
   Bazada yagona yangi ustun: `beshkunlik_reja.uzgardi_qolda`.
8. **Fakt rangi/filtri endi Reja bilan.** Yuqoridagi "Fakt rangi va filtr"
   bo'limi — avval Uzgaradi bilan solishtirilardi.
9. **Berdik — hamma yuk to'lovi.** `beshkunlik_qarz_v2`ning Berdik qismi endi
   `yuk_deadline` bilan JOIN QILINMAYDI — muddati qo'yilmagan yuk to'lovi ham
   kiradi (pul baribir chiqib ketgan). Qarzmiz qismi o'zgarmaydi.

## Excel bilan farqlar (ataylab)

| Excel | Bizda | Nega |
|-------|-------|------|
| Fakt qo'lda kiritilgan (534 ta qiymat) | Aros'dan avtomatik | xato kamayadi |
| Qarz ro'yxati `Tuldiriladi` da qo'lda | Aros yuklaridan jonli | tannarx qo'shilsa o'zi yangilanadi |
| Reja `NEW.` varag'idan (tashqi fayl, hozir `#REF!`) | `beshkunlik_reja` jadvali | manba ichkarida |
| Omborlar rejadan chiqarilgan | chiqarilmaydi | qaror №2 |

## Bosqichlar

| № | Bosqich | Holat |
|---|---------|-------|
| 1 | Skelet + ruxsat + SQL | ✅ `db2117f` |
| 2 | Jadval: bitta sheet, 27 ustun, keng | ✅ |
| 3 | Kunlik savdo (Fakt) + hover'da filial kesimi | ✅ |
| 4 | Reja / Uzgardi tahriri | ✅ |
| 5 | Excel funksiyalari (sudrab to'ldirish, filtr, rang) | ✅ |
| 6 | Qarz bloki + yuk deadline UI | ✅ |
| 7 | **Bitta platforma** (27→15 ustun) + Yig'ilma rekursiya tuzatish + Prognoz + boshlang'ich qoldiq + hover-scroll bug fix | ✅ (SQL RUN kutilmoqda, n8n muhrlash workflow keyingi qadam) |
| 8 | Regression test | ✅ (statik tahlil — node --check, formula qo'l bilan tekshiruv) |
| 9 | Samarali Uzgaradi (avtomatik) + Fakt rangi/filtri Reja bilan + Berdik hamma yuk to'lovi | ✅ (SQL RUN kutilmoqda) |
