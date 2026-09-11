# BRIEF — «5 kunlik» sahifasi

Manba: Asilbekning `Jami qarz.xlsx` faylidagi **`5 kunlik`** varag'i.
Formulalar shu fayldan aynan o'qib olindi (2026-09-11), quyida ularning
Provodkadagi muqobili yozilgan.

## Maqsad

> Shu kunga kelib biznesda qancha pul bo'ladi va qancha qarz olsa bo'ladi.

Ta'minotchi bilan to'lov sanasi shunga qarab kelishiladi — sahifaning butun
mavjudlik sababi shu.

## Ko'rinish

Bitta jadval, ikkala profil yonma-yon (tab YO'Q):

```
Sana │ ──── AKSESSUAR (13 ustun) ──── │ ──── ZAPCHAST (13 ustun) ────
```

Har profil uchun 4 guruh:

| Guruh | Ustunlar |
|-------|----------|
| Savdo | Reja · Uzgaradi · Fakt |
| Yig'ilma | Reja · Uzga · Fakt |
| Qarz | Qarzmiz · Berdik · Raznitsa |
| Qoldi pul | Reja · Uzga · Fakt · Raznitsa |

## Hisob formulalari (Excel bilan aynan)

`kecha` = oldingi kunning o'sha ustuni.

| Ustun | Formula | Izoh |
|-------|---------|------|
| Reja | `oylik_reja / oy_kunlari` | oyning **hamma** kuniga teng bo'linadi (yakshanba ham) |
| Uzgaradi | qo'lda | boshida Reja bilan bir xil, keyin kunma-kun tahrirlanadi |
| Fakt | Aros'dan | Excelda qo'lda edi — bizda avtomatik |
| Yig'.Reja | `Qoldi.Reja(kecha) + Reja` | |
| Yig'.Uzga | `Qoldi.Uzga(kecha) + Uzgaradi` | |
| Yig'.Fakt | `Qoldi.Fakt(kecha) + Fakt` | |
| Qarzmiz | deadline shu kunga tushgan qarzlar (manfiy) | |
| Berdik | shu kuni haqiqatda to'langan (musbat) | |
| Raznitsa | `Qarzmiz + Berdik` | to'liq to'lansa 0 |
| Qoldi.Reja | `Yig'.Reja + Qarzmiz` | |
| Qoldi.Uzga | `Yig'.Uzga + Qarzmiz` | |
| Qoldi.Fakt | `Yig'.Fakt − Berdik` | |
| Qoldi.Raznitsa | `Qoldi.Uzga − Qoldi.Fakt` | **Uzga** bilan solishtiriladi, Reja bilan emas |

🔴 Yig'ilma **uzluksiz** — hech qachon nolga tushmaydi. «5 kunlik» faqat nom.

## Ma'lumot manbalari

| Nima | Qayerdan |
|------|----------|
| **Fakt** (kunlik savdo) | `cache_calendar_daily` (n8n `Aros Market - Calendar Cache Builder`, har soat). `bajarilgan = tushum − qaytarilgan`, **so'mda** |
| **Profil** (Aksessuar/Zapchast) | `cache_filial.data->>'profil'` |
| **Qarzmiz** | Aros yuklari (`aros-provodka-yuklar` webhook) + `yuk_deadline.deadline` |
| **Berdik** | Provodkaning o'zi — `entry_yuk` (qaysi yukka qancha berildi) |
| **Reja / Uzgardi** | `beshkunlik_reja` (qo'lda kiritiladi) |

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
| 2 | Jadval: bitta sheet, 27 ustun, keng | 🔄 |
| 3 | Kunlik savdo (Fakt) + hover'da filial kesimi | |
| 4 | Reja / Uzgardi tahriri | |
| 5 | Excel funksiyalari (sudrab to'ldirish, filtr, rang) | |
| 6 | Qarz bloki + yuk deadline UI | |
| 7 | Qoldi pul + prognoz | |
| 8 | Regression test | |
