#!/usr/bin/env bash
# =====================================================================
# promote.sh — dev fayllarni prod'ga ko'chirish
# ---------------------------------------------------------------------
# Har `X-dev.html` -> `X.html` ga nusxalanadi va nusxa ichidagi
# `NAME-dev.html` havolalari `NAME.html` ga qaytariladi (dev->prod).
# perms.js / vendor / data: URI'lar tegilmaydi (ular -dev bo'lmaydi).
#
# Ishlatish:
#   bash promote.sh              # hamma dev faylni prod'ga ko'chiradi
#   bash promote.sh hodim kassa  # faqat tanlanganlarini
#
# DIQQAT: prod fayl ustiga yozadi. Avval `git status` bilan tekshiring.
# =====================================================================
set -euo pipefail

PAGES="kassa jurnal professional hodim hisobot balans cashflow qarzdor filial valyuta konvert sozlama provodka"

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

echo "---"
echo "$promoted ta fayl prod'ga ko'chirildi."
echo "Endi tekshiring: git diff, so'ng commit + push."
