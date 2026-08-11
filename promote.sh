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
PAGES="kassa jurnal professional hodim hisobot balans cashflow qarzdor filial valyuta konvert sozlama provodka standart yuklar"

# Ko'chiriladigan sahifalar: argument berilsa o'shalar, aks holda hammasi.
if [ "$#" -gt 0 ]; then
  targets="$*"
else
  targets="$PAGES"
fi

# Barcha sahifa nomlari uchun: NAME-dev.html -> NAME.html
# perl ishlatiladi (sed EMAS): CRLF/LF qator oxirlarini saqlaydi — aks holda
# butun fayl "o'zgargan" bo'lib ko'rinadi (katta, foydasiz git diff).
expr=""
for p in $PAGES; do
  expr="${expr}s/\\Q${p}-dev.html\\E/${p}.html/g;"
done
# Umumiy klient fayli (sahifa emas — ro'yxatga kirmaydi, alohida qatorda)
expr="${expr}s/\\Qperms-dev.js\\E/perms.js/g;"

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
fi

echo "---"
echo "$promoted ta fayl prod'ga ko'chirildi."
echo "Endi tekshiring: git diff, so'ng commit + push."
