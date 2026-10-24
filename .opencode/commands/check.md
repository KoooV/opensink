---
description: Guard, анализатор и тесты пакета. Пример - /check core_sync
---
!`bash tool/guard.sh 2>&1 | tail -20`
!`cd packages/$ARGUMENTS && dart analyze 2>&1 | tail -30 && dart test 2>&1 | tail -30`

Исправь только реальные ошибки из вывода выше. Не рефакторь.
