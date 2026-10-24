#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
fail=0

# убирает строки, где код начинается с комментария (//, ///, *, /*)
nocomment() { grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|/\*|\*)'; }

check() {
  if [ -n "$2" ]; then echo "FAIL: $1"; echo "$2" | head -10; fail=1; fi
}

check "platform/flutter import in core_*" \
  "$(grep -rEn "^[[:space:]]*(import|export)[[:space:]]+['\"](dart:(io|html|ui)|package:flutter/)" packages/core_*/lib 2>/dev/null)"

check "core_domain imports other internal packages" \
  "$(grep -rEn "^[[:space:]]*(import|export)[[:space:]]+['\"]package:core_(crypto|protocol|storage|signaling|peer|sync|group|relay|media)" packages/core_domain/lib 2>/dev/null)"

check "print/debugPrint in core" \
  "$(grep -rEn '\b(print|debugPrint)\(' packages/core_*/lib 2>/dev/null | nocomment)"

[ $fail -eq 0 ] && echo "guard OK"
exit $fail