#!/usr/bin/env bash
# Проверяет дрейф документации относительно кода:
#   (a) пакеты, упомянутые в docs/DESIGN.md, есть в pubspec.yaml workspace;
#   (b) идентификаторы дефектов D-xx, упомянутые в docs/DESIGN.md, есть в таблице docs/DEFECTS.md;
#   (c) число записей Q-xx в docs/OPEN_QUESTIONS.md vs число TODO(verify) в коде (отчёт, не блокер).
# Возвращает ненулевой код при дрейфе в (a) или (b).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESIGN="$REPO_ROOT/docs/DESIGN.md"
DEFECTS="$REPO_ROOT/docs/DEFECTS.md"
OPEN_Q="$REPO_ROOT/docs/OPEN_QUESTIONS.md"
PUBSPEC="$REPO_ROOT/pubspec.yaml"

FAIL=0

echo "== Проверка (a): пакеты в DESIGN.md vs pubspec.yaml workspace =="

# Рабочие пакеты из workspace (имена без префикса packages/ / apps/)
WORKSPACE_PKGS=$(grep -E '^\s+- (packages|apps)/' "$PUBSPEC" \
  | sed 's/^\s*- //; s|^packages/||; s|^apps/||' \
  | sort -u)

# Пакетные пути в DESIGN.md: packages/<name>, platform_<name>, apps/app
DESIGN_PKGS=$(grep -oE '(packages/|apps/)?[a-z0-9_]+(/[a-z0-9_]+)?' "$DESIGN" \
  | grep -E '^(packages/|apps/)?(core_[a-z0-9_]+|platform_[a-z0-9_]+|app)$' \
  | sed 's|^packages/||; s|^apps/||' \
  | sort -u)

echo "Рабочие пакеты из pubspec.yaml:"
echo "$WORKSPACE_PKGS"
echo ""
echo "Пакеты, найденные в DESIGN.md:"
echo "$DESIGN_PKGS"

for pkg in $DESIGN_PKGS; do
  if ! echo "$WORKSPACE_PKGS" | grep -qx "$pkg"; then
    echo "DRIFT (a): пакет '$pkg' упомянут в DESIGN.md, но отсутствует в pubspec.yaml workspace" >&2
    FAIL=1
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo "OK (a): все пакеты из DESIGN.md присутствуют в workspace"
fi

echo ""
echo "== Проверка (b): D-xx в DESIGN.md vs DEFECTS.md =="

# Все D-xx в DESIGN.md (с префиксом D-)
DESIGN_DEFECTS=$(grep -oE 'D-[0-9]+' "$DESIGN" | sort -u)

# Все D-xx в таблице DEFECTS.md (с префиксом D-)
DEFECTS_TABLE_IDS=$(grep -oE '\| D-[0-9]+ \|' "$DEFECTS" | tr -d ' |' | sort -u)

echo "D-xx в DESIGN.md:"
echo "$DESIGN_DEFECTS"
echo ""
echo "D-xx в таблице DEFECTS.md:"
echo "$DEFECTS_TABLE_IDS"

for d in $DESIGN_DEFECTS; do
  if ! echo "$DEFECTS_TABLE_IDS" | grep -qx "$d"; then
    echo "DRIFT (b): дефект $d упомянут в DESIGN.md, но отсутствует в таблице docs/DEFECTS.md" >&2
    FAIL=1
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo "OK (b): все D-xx из DESIGN.md есть в DEFECTS.md"
fi

echo ""
echo "== Проверка (c): Q-xx в OPEN_QUESTIONS.md vs TODO(verify) в коде =="

Q_COUNT=$(grep -cE '^## Q[0-9]+' "$OPEN_Q" || true)
TODO_COUNT=$(grep -rn "TODO(verify)" "$REPO_ROOT/packages" "$REPO_ROOT/apps" --include="*.dart" 2>/dev/null | wc -l)

echo "Q-xx записей в OPEN_QUESTIONS.md: $Q_COUNT"
echo "TODO(verify) в dart-коде: $TODO_COUNT"

# Q1-Q11 — общие вопросы (не привязаны к конкретным TODO(verify)),
# Q12-Q19 — 8 TODO(verify) в stub-пакетах, 2 TODO(verify) в bip39_integrity_test.dart ссылаются на существующие Q.
# Несоответствие не является блокером, но требует осознанного отношения.
if [ "$Q_COUNT" -ne "$TODO_COUNT" ]; then
  echo "INFO (c): числа не совпадают ($Q_COUNT Q-записей vs $TODO_COUNT TODO(verify)) — это допустимо, если избыточные Q относятся к закрытым/отложенным вопросам без маркера в коде."
else
  echo "OK (c): числа совпадают ($Q_COUNT = $TODO_COUNT)"
fi

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "check_docs_drift: ОБНАРУЖЕН ДРЕЙФ ДОКУМЕНТАЦИИ (a или b)" >&2
  exit 1
fi

echo "check_docs_drift: OK — критических расхождений не обнаружено"
exit 0