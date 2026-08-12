# PROVODKA — 2 ish (tur konvert + filial UI)

Repo: pravodka (Supabase `kxzerccdpcltmzrxutlo`). Dev-first: `-dev.html`, promote.sh → prod. SQL additive. entry.created_by TEXT. Qoidalar: {error}, double-entry (Dt=Kt), qoldiq entry_line'dan, tur child (naqd/click/payme/USD).

## 1. Tur konvert (bir kassa ичida tur↔tur)
Kassa ичida bir turdan boshqasiga. Masalan Yunusobod: Click 1.000.000 → Naqd.
- Bir kassa ичida (kassalar aro EMAS). Oddiy ko'chirish: bir tur kamayadi, boshqasi ko'payadi, jami O'ZGARMAYDI (som↔som, kurssiz).
- USD konvert allaqачon bor (convert_start) — chalkаshтирма. Bu YANGI: som tur ↔ som tur (naqd/click/payme).
- Provodkaga double-entry: `Dt maqsad tur / Kt manba tur / summa`. Masalan click→naqd 1mln: Dt naqd 1mln / Kt click 1mln.
- UI: kassa sahifasида (kassa-dev/professional) "Tur o'tkazish" tugma. Modal: manba tur (qoldiq ko'rsatilsin) → maqsad tur → summa. summa auto-000.
- Validatsiya: manba turда yetarli qoldiq ({error}). Aros'ga tegilmaydi.
- SQL: RPC `kassa_tur_convert(kassa, manba_tur, maqsad_tur, summa)` yoki mavjud yozish mexanizmi. Double-entry.

## 2. Filial UI — bitta filial
Hozir: kassa tanlanadi → har tur (naqd/click/payme) ALOHIDA chiqadi. Chalkash.
Kerak: bitta FILIAL tanlansin, tur alohida ro'yxatда chiqmasin. Yunusobod tanlaganda — faqat Yunusobod (bitta), tur ичкari detal.
- CC avval hozirgi UI'ни ko'rsin (qaysi sahifa/dropdown), keyin filial darajasига keltir (bitta filial = bitta element).
- Asilbek: "provodka yozguncha filial tanlanadi, kassa emas; har filialни click/payme/naqd alohida ko'rsatyapti — bitta filial bo'lsin".

## Tartib
CC avval ANIQ joyni (kod) topsin — pul harakati, ehtiyot. Har ish alohida commit. SQL → `PROVODKA_TUR_CONVERT.sql`. Dev-first. Push Asilbek. Savol bo'lsa so'rasin.
