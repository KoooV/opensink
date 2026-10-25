import 'package:app/di/providers.dart';
import 'package:app/ui/home_screen.dart';
import 'package:core_domain/core_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('главный экран показывает пустое состояние', (tester) async {
    await tester.pumpWidget(
      _app(
        const HomeScreen(),
        overrides: [
          groupSummariesProvider.overrideWith(
            (ref) async => const <GroupSummary>[],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Групп пока нет'), findsOneWidget);
    expect(find.text('Создать группу'), findsOneWidget);
  });

  testWidgets('список групп показывает имя и происхождение', (tester) async {
    final summary = GroupSummary(
      groupId: GroupId('a' * 64),
      name: 'Команда',
      origin: GroupOrigin.created,
    );
    await tester.pumpWidget(
      _app(
        const HomeScreen(),
        overrides: [
          groupSummariesProvider.overrideWith(
            (ref) async => <GroupSummary>[summary],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Команда'), findsOneWidget);
    expect(find.text('Создана на этом устройстве'), findsOneWidget);
  });

  testWidgets('пустое имя группы не создаёт группу', (tester) async {
    await tester.pumpWidget(
      _app(
        const HomeScreen(),
        overrides: [
          groupSummariesProvider.overrideWith(
            (ref) async => const <GroupSummary>[],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Создать группу'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Создать'));
    await tester.pumpAndSettle();

    expect(find.text('Название группы не может быть пустым.'), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('невалидная инвайт-ссылка показывает ошибку', (tester) async {
    await tester.pumpWidget(
      _app(
        const HomeScreen(),
        overrides: [
          groupSummariesProvider.overrideWith(
            (ref) async => const <GroupSummary>[],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Войти по инвайту'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not-a-link');
    await tester.tap(find.text('Войти'));
    await tester.pumpAndSettle();

    expect(find.text('Ссылка не распознана.'), findsOneWidget);
  });
}
