# Состояние
## Сделано
- core_group: роли, инвайты, конфликты, ротация, genesis/цепочка в apply и GroupController, дедуп после фильтра группы; 52 теста + HMAC-адаптер в app.
## Дальше
- Ревью core_group: 2 blocker (reorder/fork в GroupController, курсор не двигается при семантическом Err) и 3 major (топопорядок fromEvents, курсоры в публичной фабрике, дедуп по телу в apply).
## Открытые вопросы
- Legacy GroupState; trusted time (принятый риск Q36); сериализация genesis/cursors; ротация GroupSecret при удалении; затем SyncEventKind и интеграция.
