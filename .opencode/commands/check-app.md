---
description: Анализ и тесты Flutter-приложения apps/app
---
!`bash tool/guard.sh 2>&1 | tail -20`
!`cd apps/app && flutter analyze --no-pub 2>&1 | tail -30 && flutter test --no-pub 2>&1 | tail -30`

Исправь только реальные ошибки из вывода выше. Не рефакторь.
