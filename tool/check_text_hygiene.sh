#!/usr/bin/env bash
# Проверяет текстовый мусор в packages/, apps/, docs/:
#   - CJK: \p{Han}|\p{Hiragana}|\p{Katakana}
#   - латиница с диакритикой: [À-ÖØ-öø-ÿ]
#   - смешение кириллицы и латиницы без разделителя
# Строки с маркером "hygiene-allow" и бинарные файлы игнорируются.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CJK='\p{Han}|\p{Hiragana}|\p{Katakana}'
DIACRITIC='[À-ÖØ-öø-ÿ]'
MIXED='\p{Cyrillic}[A-Za-z]|[A-Za-z]\p{Cyrillic}'

FOUND=0

check_pattern() {
  local name="$1"; local pattern="$2"; shift 2
  while IFS= read -r -d '' file; do
    # Бинарные файлы (wasm, dill и т.п.) не являются текстом.
    grep -Iq . "$file" 2>/dev/null || continue
    # Экранированный \n в JSON не должен выглядеть как смешение алфавитов.
    local matches
    matches="$(sed 's/\\n/ /g' "$file" \
      | grep -nP "$pattern" 2>/dev/null \
      | grep -v 'hygiene-allow' || true)"
    if [[ -n "$matches" ]]; then
      printf '[%s] %s:\n%s\n' "$name" "$file" "$matches" >&2
      FOUND=1
    fi
  done < <(find "$@" -type f -not -path '*/.dart_tool/*' -not -path '*/build/*' -print0 2>/dev/null)
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
