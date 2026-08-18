#!/usr/bin/env bash
# =====================================================================
# promote.sh — dev fayllarni prod'ga ko'chirish
# ---------------------------------------------------------------------
# Har `X-dev.html` -> `X.html` ga nusxalanadi va nusxa ichidagi
# `NAME-dev.html` havolalari `NAME.html` ga qaytariladi (dev->prod).
# vendor / data: URI'lar tegilmaydi (ular -dev bo'lmaydi).
#
# `perms-dev.js` MAVJUD BO'LSA u ham `perms.js` ustiga ko'chiriladi va
# fayllardagi `perms-dev.js` havolasi `perms.js` ga qaytariladi. DIQQAT:
# perms.js hamma prod sahifa uchun BITTA — u ko'chishi bilan ruxsat
# semantikasi HAMMA prod sahifada bir vaqtda o'zgaradi (tanlab bo'lmaydi).
#
# `ai-widget-dev.js` (floating AI tugmasi) ham xuddi shunday umumiy fayl —
# `ai-widget.js` ustiga ko'chiriladi va havolasi qaytariladi. U SAHIFA EMAS,
# shuning uchun `PAGES` ro'yxatiga QO'SHILMAYDI (`ai` u yerda allaqachon bor
# va u `ai-dev.html` sahifasiga tegishli — ikkalasi boshqa-boshqa narsa).
#
# Ishlatish:
#   bash promote.sh              # hamma dev faylni prod'ga ko'chiradi
#   bash promote.sh hodim kassa  # faqat tanlanganlarini
#
# DIQQAT: prod fayl ustiga yozadi. Avval `git status` bilan tekshiring.
# =====================================================================
set -euo pipefail

# DIQQAT: yangi sahifa qo'shilganda uni shu ro'yxatga QO'SHISH SHART. Ikki sabab:
#  1) ro'yxatda yo'q sahifa umuman prod'ga ko'chmaydi;
#  2) undan ham xatarlisi — boshqa fayllardagi `NAME-dev.html` havolalari
#     qaytarilmaydi, ya'ni PROD sahifalar DEV fayllarga havola qilib qoladi.
#
# `index` — login + dashboard hub sahifasi (pravodka.com ning birinchi yuzi).
# U ham oddiy sahifa: `index-dev.html` -> `index.html`.
PAGES="index kassa jurnal professional hodim hisobot balans cashflow qarzdor filial valyuta konvert sozlama provodka standart yuklar tannarx ai"

# Ko'chiriladigan sahifalar: argument berilsa o'shalar, aks holda hammasi.
if [ "$#" -gt 0 ]; then
  targets="$*"
else
  targets="$PAGES"
fi

# ---------------------------------------------------------------------
# 🔴 index.html KAFOLATI — perms.js login guard bilan bog'liq
# ---------------------------------------------------------------------
# `perms-dev.js -> perms.js` pastda TARGETS'dan QAT'I NAZAR bajariladi (u sahifa
# emas, umumiy fayl). Yangi perms.js da login guard bor: sessiya tokeni yo'q
# bo'lsa HAR prod sahifa `index.html` ga yo'naltiradi. Ya'ni tanlab ko'chirishda
# (masalan `bash promote.sh jurnal`) index.html yo'q bo'lsa BUTUN PROD uziladi.
# Shuning uchun kerak bo'lsa `index` ni targets'ga o'zimiz qo'shamiz.
if [ -f "perms-dev.js" ] && [ ! -f "index.html" ]; then
  if [ -f "index-dev.html" ]; then
    case " $targets " in
      *" index "*) ;;                       # allaqachon ro'yxatda
      *) targets="index $targets"
         echo "QO'SHILDI: index (perms.js login guard index.html'siz prodni uzardi)" ;;
    esac
  else
    echo "XATO: perms-dev.js login guard bilan ko'chiriladi, lekin index.html ham,"
    echo "      index-dev.html ham yo'q. Prod sahifalar mavjud bo'lmagan index.html"
    echo "      ga yo'naltirilardi — to'xtatildi."
    exit 1
  fi
fi

# Barcha sahifa nomlari uchun: NAME-dev.html -> NAME.html
# perl ishlatiladi (sed EMAS): CRLF/LF qator oxirlarini saqlaydi — aks holda
# butun fayl "o'zgargan" bo'lib ko'rinadi (katta, foydasiz git diff).
expr=""
for p in $PAGES; do
  expr="${expr}s/\\Q${p}-dev.html\\E/${p}.html/g;"
done
# Umumiy klient fayllari (sahifa emas — ro'yxatga kirmaydi, alohida qatorda).
# Tartib muhim emas: bu ikki naqsh yuqoridagi `NAME-dev.html` naqshlari bilan
# kesishmaydi (`.js` va `.html` — boshqa qo'shimcha).
expr="${expr}s/\\Qperms-dev.js\\E/perms.js/g;"
expr="${expr}s/\\Qai-widget-dev.js\\E/ai-widget.js/g;"

promoted=0
for t in $targets; do
  src="${t}-dev.html"
  dst="${t}.html"
  if [ ! -f "$src" ]; then
    echo "SKIP: $src topilmadi"
    continue
  fi
  perl -pe "$expr" "$src" > "$dst"
  echo "PROMOTED: $src -> $dst"
  promoted=$((promoted + 1))
done

# ---------------------------------------------------------------------
# perms-dev.js -> perms.js
# ---------------------------------------------------------------------
# perms.js dev va prod uchun BITTA fayl (CLAUDE.md). Semantika o'zgargani
# uchungina perms-dev.js ochilgan. U ko'chgan zahoti yangi qoida hamma prod
# sahifaga tarqaladi — shuning uchun alohida ogohlantiramiz.
if [ -f "perms-dev.js" ]; then
  perl -pe "$expr" "perms-dev.js" > "perms.js"
  echo "PROMOTED: perms-dev.js -> perms.js"
  echo ""
  echo "  !!! DIQQAT — ruxsat semantikasi HOZIR o'zgardi (hamma prod sahifada):"
  echo "      bo'sh allowed_pages endi HAMMASI-OCHIQ emas, RUXSAT-YOQ degani."
  echo "      Sahifa ro'yxati bo'sh userlar hodim.html ga yo'naltiriladi."
  echo "      Orqaga qaytarish: PROVODKA_PAGES_EMPTY.sql 8-BO'LIM (rollback)."
  echo ""
  echo "  !!! DIQQAT — perms.js endi LOGIN GUARD bilan keladi: sessiya tokeni yo'q"
  echo "      bo'lsa HAR prod sahifa index.html ga yo'naltiradi. Shuning uchun"
  echo "      index.html SHU PROMOTE'da ko'chirilishi SHART (bash promote.sh"
  echo "      argumentsiz, yoki ro'yxatga 'index' qo'shib). Aks holda prod"
  echo "      sahifalar mavjud bo'lmagan index.html ga yuboradi — BUTUN SAYT ISHLAMAYDI."
  echo ""
  if [ ! -f "index.html" ]; then
    echo "  XATO: index.html YO'Q, lekin perms.js login guard bilan ko'chirildi!"
    echo "        Darhol ishga tushiring:  bash promote.sh index"
    echo ""
  fi
fi

# ---------------------------------------------------------------------
# ai-widget-dev.js -> ai-widget.js
# ---------------------------------------------------------------------
# Floating AI tugmasi — 15 sahifa uchun BITTA umumiy fayl (perms.js naqshi).
# Ichida `NAME-dev.html` matni yo'q (havola suf() bilan quriladi), shuning
# uchun nusxa amalda bayt-ma-bayt bir xil chiqadi.
if [ -f "ai-widget-dev.js" ]; then
  perl -pe "$expr" "ai-widget-dev.js" > "ai-widget.js"
  echo "PROMOTED: ai-widget-dev.js -> ai-widget.js"
fi

# ---------------------------------------------------------------------
# CNAME tekshiruvi (faqat OGOHLANTIRISH — fayl yaratilmaydi/o'chirilmaydi)
# ---------------------------------------------------------------------
# Bu skript CNAME faylga HECH QACHON TEGMAYDI: u yuqoridagi `PAGES` ro'yxatiga
# kirmaydi (u sahifa emas) va alohida nusxalanmaydi ham. Ya'ni promote domenni
# uzmaydi. Lekin CNAME repo'dan tasodifan o'chib ketsa GitHub Pages custom
# domenni tashlab yuboradi (pravodka.com ishlamay qoladi) — shuning uchun
# har promote'da borligini tekshirib, ko'rinarli ogohlantirish beramiz.
# Faylni O'ZI YARATMAYDI: domen sozlamasi qo'lda, ongli ravishda qo'yiladi.
if [ ! -f "CNAME" ]; then
  echo ""
  echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "  !!! CNAME fayli YO'Q — pravodka.com uzilishi mumkin!"
  echo "  !!! GitHub Pages custom domen shu fayldan o'qiladi."
  echo "  !!! Repo ildizida CNAME yarating, ichida bitta qator: pravodka.com"
  echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo ""
fi

echo "---"
echo "$promoted ta fayl prod'ga ko'chirildi."
echo "Endi tekshiring: git diff, so'ng commit + push."
