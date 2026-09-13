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

🔴 **2026-09-13 TUZATILDI (Asilbek qarori B)** — boshlanish nuqtasi endi
`Qoldi.Fakt` (savdo-asosli taxmin) EMAS, **haqiqiy kassa puli** (`Haqiqiy`,
quyidagi "Haqiqiy pul" bo'limiga qara); `O` va kelajak rekursiyasi endi
`Qarzmiz` emas, `Raznitsa` bilan (muddatdan oldin to'langan qism allaqachon
kassadan chiqib ketgan bo'ladi — takror ayirilmasin):

| Belgi | Formula | Izoh |
|-------|---------|------|
| `B` | `Haqiqiy(T)` | bugungi HAQIQIY kassa puli (`beshkunlik_kassa_qoldiq`); RPC/kurs topilmasa taxminiy `Qoldi.Fakt`ga tushiladi (fail-open) |
| `O` | `Σ Raznitsa(t)` t=START..T | hali to'lanmagan, muddati kelgan qarz (manfiy) |
| `K(T)` | `B + O` | |
| `K(D)`, D>T | `K(D−1) + Uzgaradi(D) + Raznitsa(D)` | kelajakda haqiqiy to'lov yo'q — Uzgaradi ORNIDA; Raznitsa (Qarzmiz emas) — muddatdan oldin to'langan qism qayta ayirilmasin |
| Kutilgan pul(D) | D<T → `—`; D≥T → `K(D)` | |
| Qarz olsa bo'ladi(D) | D<T → `—`; D≥T → `max(0, min` `_{t=D..H} K(t))` | eng past nuqtagacha pul yetishi kerak; manfiy bo'lsa 0 + qizil + "$X yetishmaydi" |

`H` — 60 kunlik gorizont (yuqoridagi `RUN_H`). Jadval ustida qisqa xulosa:
«Bugun kutilgan: $X · 60 kun ichida eng past: $Y (sana) · Bugun qarz olsa
bo'ladi: $Z» + kelajakda reja kiritilmagan kunlar soni haqida ogohlantirish.
«Qarz olsa bo'ladi» katagi hover: qaysi kun cheklab turgani («Eng past nuqta:
24 sen — $X»).

## Haqiqiy pul (Qoldi pul → «Haqiqiy» ustuni) — Asilbek qarori A, 2026-09-13

«Haqiqiy» endi **kassalardagi haqiqiy pul** (avval `Yig'.Fakt − Berdik` —
savdo/to'lov'dan derivatsiya qilingan taxmin edi, endi haqiqiy hisob
qoldig'i): `beshkunlik_kassa_qoldiq(p_from,p_to)` — shu kun OXIRIDAGI barcha
pul hisoblari qoldig'i (`section='pul'`), hodim xarajat kassalari
(`kassa_turi in ('xarajat','xarajat_guruh')`) DAN TASHQARI; filial/markaziy
kassalar + ularning pul turi (Naqd/Click/Payme/Terminal) va valyuta (USD…)
bolalari KIRADI (`kassa_turi` bolalarga parentdan NUSXALANADI — alohida
`parent_id` rekursiyasi shart emas). Yo'ldagi pul avtomatik kiradi (qabul
qilinmaguncha daftarda filial kassasida turadi). Faqat `posted`, o'chirilmagan,
`entry_date<=sana`. Dollarga o'girish: `uzs/kurs(sana) + usd` (sanali kurs,
`beshkunlik_kurslar`). **Kelajak kunlarda (D>bugun) — `—`** (haqiqiy pul
kelajakda mavjud emas). Ustun `title`: «Kassalardagi haqiqiy pul (hodim
xarajat kassalarisiz, yo'ldagi pul bilan)». «Farq» = Prognoz bo'yicha −
Haqiqiy (kelajakda ham `—`).

RPC/kurs topilmasa (SQL hali RUN qilinmagan yoki sanali kurs yo'q) —
sahifa sinmaydi: shu kun uchun Haqiqiy/Farq `—`, Prognoz `B` taxminiy
`Qoldi.Fakt`ga tushadi (fail-open, yuqoridagi jadvalga qara).

## To'lov grafigi — Qarzmiz/Berdik/Raznitsa (Asilbek qarorlari C/D, 2026-09-13)

🔴 **BEKOR QILINGAN eski qaror (2026-09-12, pastdagi "Kelishilgan qarorlar"
9-band)**: "Berdik = hamma yuk to'lovi" (bitta muddat, JONLI qoldiq).
O'RNIGA — **bitta yukka bir nechta to'lov muddati** (`yuk_tolov_grafik`,
`PROVODKA_5KUNLIK_GRAFIK.sql`), grafikni **`yuklar-dev.html`** tahrirlaydi
(RPC `yuk_grafik_saqla`), «5 kunlik» faqat o'qiydi (`beshkunlik_qarz_v3` /
`beshkunlik_qarz_detal_v3`):

- **Grafik qatori** (`sana + summa + izoh`) — summa YUK HUJJAT VALYUTASIDA.
  Σ summa (bir yuk bo'yicha) = **butun tannarx** (±1 birlik, `yuk_grafik_maqsad`):
  `hujjat narxi + (qo'shilgan tannarx_uzs + bojxona_uzs) / kurs(valyuta)`
  (UZS bo'lsa kurs 1). Hujjat narxi bazada yo'q (Aros webhook'dan) — klient
  `p_narx`/`p_valyuta` beradi (`yuk_deadline.narx/valyuta` surati naqshi).
- **Berdik/Raznitsa** — yukning to'lovlari (`entry_yuk.summa_uzs`, posted,
  o'chirilmagan, `entry_date` bo'yicha) shu yukning grafik qatorlariga ENG
  ESKI MUDDATDAN boshlab FIFO taqsimlanadi (to'lov qachon qilinganidan
  qat'i nazar — u yopgan qatorning MUDDAT KUNIGA yoziladi).
  `Qarzmiz(D)` = D kuniga tushgan grafik qatorlari summasi (so'mda, manfiy;
  to'langan-to'lanmaganidan qat'i nazar — bu ENDI JONLI qoldiq emas, xom
  jadval qiymati). `Berdik(D)` = shu qatorlarga taqsimlangan to'lov.
  `Raznitsa(D) = Qarzmiz + Berdik` (to'lanmagan qoldiq).
- **Kech** — grafik qatoriga taqsimlangan to'lovlardan birortasi
  `sana(to'lov) > muddat` bo'lsa; aks holda (muddatda yoki oldin) — o'z
  vaqtida. Berdik katagi foni: o'z vaqtida — **yashil**, kech — **qizil**.
- **Qarzmiz hover 0 bo'lganda ham ishlaydi** (Asilbek qarori E) — o'sha
  kunga grafik qatori bo'lsa (qaysi yuk, summa, to'langan, holat: o'z
  vaqtida yashil / kech qizil / to'lanmagan kulrang, to'lov sanalari,
  kelishuv matni) ko'rsatiladi.
- **«Muddat qo'yilmagan: N ta yuk · $X»** — jadval ustida xulosa (qarzi
  bor, lekin grafigi yo'q Aros yuklari). Manba AYNAN `yuklar-dev.html`
  dagi «Muddat qo'yilmagan» chipi bilan bir xil: `aros-provodka-yuklar`
  webhook (oxirgi 30 kun), `yuk_tannarx_jami`+`yuk_tolangan_summa` bilan
  `qoldiq = max(0, narx_uzs+qo'shilgan_tannarx_uzs − to'langan_uzs)`,
  `yuk_deadline.deadline` yo'qligi = "muddat qo'yilmagan". Bosilsa
  `yuklar-dev.html` ga olib boradi.

## Ma'lumot manbalari

| Nima | Qayerdan |
|------|----------|
| **Fakt** (kunlik savdo) | `cache_calendar_daily` (n8n `Aros Market - Calendar Cache Builder`, har soat). `bajarilgan = tushum − qaytarilgan`, **so'mda** |
| **Profil** (Aksessuar/Zapchast) | `cache_filial.data->>'profil'` |
| **Qarzmiz/Berdik/Raznitsa** | `yuk_tolov_grafik` (to'lov grafigi, `yuklar-dev.html` tahrirlaydi) + `entry_yuk` (FIFO taqsimot) — `beshkunlik_qarz_v3`/`_detal_v3` |
| **Haqiqiy** (Qoldi pul) | `beshkunlik_kassa_qoldiq` — haqiqiy kassa qoldig'i (`entry`/`entry_line`, ledger) |
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
   🔴 **BEKOR (2026-09-13, pastdagi bo'limga qara)** — endi to'lov grafigi
   (`yuk_tolov_grafik`) + FIFO taqsimot bilan almashtirildi (`beshkunlik_qarz_v3`).
   `beshkunlik_qarz_v2` klientda ZAXIRA sifatida qoladi (SQL RUN qilinmagan holat).

## Kelishilgan qarorlar (2026-09-13, Asilbek)

10. **A — Haqiqiy = kassa puli.** «Haqiqiy» (Qoldi pul) endi haqiqiy kassa
    qoldig'i (`beshkunlik_kassa_qoldiq`), avvalgi savdo-asosli taxmin emas.
    Batafsil — yuqoridagi "Haqiqiy pul" bo'limi.
11. **B — Prognoz boshlanishi = haqiqiy kassa puli.** `K(T)=Haqiqiy(T)+ΣRaznitsa`,
    kelajakda `+Uzgaradi+Raznitsa` (Qarzmiz emas). Batafsil — yuqoridagi
    "Prognoz" bo'limi.
12. **C — To'lov grafigi.** Bitta yukka bir nechta muddat (`yuk_tolov_grafik`),
    Σ summa = butun tannarx. Batafsil — yuqoridagi "To'lov grafigi" bo'limi.
13. **D — Berdik/Raznitsa yangi qoida.** FIFO taqsimot, "kech" muddat qatori
    darajasida. 9-band (hamma yuk to'lovi) BEKOR qilindi.
14. **E — Qarzmiz hover 0'da ham + "Muddat qo'yilmagan" xulosasi.** Batafsil
    — yuqoridagi "To'lov grafigi" bo'limi.

## Excel bilan farqlar (ataylab)

| Excel | Bizda | Nega |
|-------|-------|------|
| Fakt qo'lda kiritilgan (534 ta qiymat) | Aros'dan avtomatik | xato kamayadi |
| Qarz ro'yxati `Tuldiriladi` da qo'lda | Aros yuklaridan jonli | tannarx qo'shilsa o'zi yangilanadi |
| Reja `NEW.` varag'idan (tashqi fayl, hozir `#REF!`) | `beshkunlik_reja` jadvali | manba ichkarida |
| Omborlar rejadan chiqarilgan | chiqarilmaydi | qaror №2 |

**Tarixiy Fakt Excel bilan mos KELMAYDI — bu kutilgan (2026-09-13, Asilbek).** 12.08–06.09
solishtiruvi: Excel jami ≈ $1.153M, Aros keshi (Aks+Zap, sof) ≈ $0.89M (77%); Aksessuar
atigi 23%. Sabab: aksessuar filiallari shu paytgacha **1C da** ishlagan, Aros'ga endi
bosqichma-bosqich o'tyapti — ularning 1C savdosi Aros keshida yo'q. O'tish tugagach Fakt
to'liq bo'ladi; ungacha Aksessuar Fakt'i haqiqiydan kam ko'rinadi. Zapchast ~92% mos.
(Zapchast qaytarilgan tovar shu oyda ≈ 10.5% — Fakt sof, qaytarilgan ayirilgan.)

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
| 10 | UI/UX: ustunlarni boshqarish + Excel filtr/saralash + tahrir UX + jami qatori | ✅ (pastdagi bo'limga qara) |
| 11 | To'lov grafigi (`yuk_tolov_grafik` + `yuk_grafik_*`, `PROVODKA_5KUNLIK_GRAFIK.sql`, `yuklar-dev.html` tahrirlaydi) + Qarz v3 (FIFO/kech) + Haqiqiy kassa puli (`beshkunlik_kassa_qoldiq`) + Prognoz B formulasi + "Muddat qo'yilmagan" xulosasi | ✅ (SQL RUN kutilmoqda) |

## 10-bosqich — UI/UX (2026-09-13, faqat `5kunlik-dev.html`, hisob mantiqiga tegilmagan)

Asilbek/Ravshan izohi: "Reja, Uzgaradi, Fakt 2 martadan bo'lib qolgan" — sabab Yig'ilma va
Qoldi pul guruhlari bir xil nomli ustunlar edi. Bu bosqich faqat **ko'rinish** qatlami —
`buildRun`/`computePrognoz`/`effectiveUzgaradi`/`avgFakt`/`computeAndFreeze` tegilmagan.

- **Ustunlarni boshqarish**: sarlavhada «Ustunlar» tugmasi → popover (guruh bo'yicha
  checkbox'lar, «Sukut» / «Hammasini ko'rsatish»). **Yig'ilma guruhi sukut bo'yicha
  yashirin** (hisobda qolaveradi). Tanlov `localStorage` (`prov-5k-cols`). Qoldi pul
  sub-sarlavhalari aniqlashtirildi: **Reja bo'yicha · Prognoz bo'yicha · Haqiqiy · Farq**
  (avval Reja/Uzga/Fakt/Raznitsa — Savdo guruhi bilan bir xil ko'rinardi); har sub-sarlavhada
  formula izohi bilan `title`.
- **Har ustunda Excel uslubidagi filtr** (`list-filter` belgisi): saralash (bitta ustun,
  qaytadan bosilsa bekor), shart (`=,≠,>,≥,<,≤,oraliqda,bo'sh,bo'sh emas,manfiy,musbat`),
  Sana ustunida sana oralig'i + hafta kunlari. Holat `sessionStorage` (`prov-5k-filters`,
  oy almashsa ham qoladi). Faol filtrlar jadval ustida chip bo'lib chiqadi + «Hammasini
  tozalash»; mavjud tezkor chiplar bilan AND. **Faqat ko'rinishni o'zgartiradi** — navigatsiya/
  sudrab to'ldirish/paste/Ctrl+D endi `dayList()` orqali KO'RINADIGAN tartibga (`VISIBLE_ROWS`)
  tayanadi, yashirin qatorga yozilmaydi. «N / M kun ko'rsatilmoqda» hisoblagichi.
- **Tahrir UX**: xavfsiz ifoda parseri (`evalSafeExpr` — eval/Function YO'Q) — `=1200/30`,
  `500*1.1`, `12 500`, `12,5` tushuniladi; noto'g'ri kiritish qizil kontur + xabar, saqlanmaydi.
  Excel klaviaturasi kengaytirildi: Delete/Backspace (tanlangan diapazonni tozalaydi),
  Shift+klik/Shift+↑↓ (diapazon), Ctrl+Enter (diapazonga bitta qiymat), Ctrl+Z (sessiya
  ichida ≥20 qadam, qaytarish serverga ham yoziladi). Qo'lda yozilgan Uzgaradi katagida
  hover'da «× avtomatikaga qaytarish». Har katakda saqlash indikatori (✓ 1s / xato konturi).
  Mobil (≤899px): katak bosilganda pastdan sheet (raqamli klaviatura, Saqlash/Bekor/
  Avtomatikaga qaytarish) — inline input o'rniga.
- **Jami qatori** (sticky bottom, faqat ko'rinadigan kunlar bo'yicha): Savdo/Qarz — yig'indi,
  Qoldi pul/Prognoz/Yig'ilma — oxirgi ko'rinadigan kun qiymati. Bo'sh holat: «Filtrga mos
  kun yo'q» + «Filtrlarni tozalash».
