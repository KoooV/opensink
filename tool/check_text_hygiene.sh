#!/usr/bin/env bash
# Проверяет текстовый мусор в packages/, apps/, docs/:
#   - CJK: \p{Han}|\p{Hiragana}|\p{Katakana}
#   - латиница с диакритикой: [À-ÖØ-öø-ÿ]
#   - смешение кириллицы и латиницы без разделителя: \p{Cyrillic}[A-Za-z]|[A-Za-z]\p{Cyrillic}
# Через дефис (например, X25519-ключ) — не ошибка, скрипт игнорирует дефис между ними.
# Возвращает ненулевой код при находках.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CJK='\p{Han}|\p{Hiragana}|\p{Katakana}'
DIACRITIC='[À-ÖØ-öø-ÿ]'
MIXED='\p{Cyrillic}[A-Za-z]|[A-Za-z]\p{Cyrillic}'

FOUND=0

check_pattern() {
  local name="$1"; local pattern="$2"; shift 2
  while IFS= read -r -d '' file; do
    # Игнорируем дефис между кириллицей и латиницей (допустимо: X25519-ключ)
    if grep -qnP "$pattern" "$file" 2>/dev/null; then
      echo "[$name] $file:" >&2
      grep -nP "$pattern" "$file" 2>/dev/null >&2 || true
      FOUND=1
    fi
  done < <(find "$@" -type f -not -path '*/.dart_tool/*' -print0 2>/dev/null)
}

echo "== Проверка CJK =="
check_pattern "CJK" "$CJK" packages/ apps/ docs/

echo "== Проверка диакритики латиницы =="
check_pattern "DIACRITIC" "$DIACRITIC" packages/ apps/ docs/

echo "== Проверка смешения кириллицы и латиницы =="
check_pattern "MIXED" "$MIXED" packages/ apps/ docs/

if [ "$FOUND" -ne 0 ]; then
  echo "check_text_hygiene: найден текстовый мусор" >&2
  exit 1
fi

echo "check_text_hygiene: OK — текстовый мусор не найден"
exit 0
