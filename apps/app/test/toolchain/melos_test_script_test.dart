import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Регрессия: Melos 8.9.0 собирает команду скрипта через `run.split(' ')`,
/// выбрасывает пустые аргументы (`startCommand`) и склеивает их обратно через
/// пробел, поэтому любые двойные пробелы в тексте скрипта схлопываются до
/// запуска shell. Паттерн `^  flutter:$` превращается в `^ flutter:$` и
/// перестаёт матчить pubspec, из-за чего Flutter-тесты запускаются через
/// `dart test` и падают на компиляции flutter/src/painting.
String normalizeLikeMelos(String script) =>
    script.split(' ').where((part) => part.trim().isNotEmpty).join(' ');

String findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('\nworkspace:\n')) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('repo root not found');
    }
    dir = parent;
  }
}

String _dedent(List<String> lines) {
  final nonEmpty = lines.where((line) => line.trim().isNotEmpty).toList();
  if (nonEmpty.isEmpty) {
    return '';
  }
  final indent = nonEmpty
      .map((line) => line.length - line.trimLeft().length)
      .reduce((a, b) => a < b ? a : b);
  return lines
      .map((line) => line.length >= indent ? line.substring(indent) : line)
      .join('\n');
}

class MelosTestScript {
  const MelosTestScript({required this.command, required this.usesExec});

  final String command;
  final bool usesExec;
}

/// Разбирает `melos.scripts.test` из корневого pubspec.
MelosTestScript parseMelosTestScript(String pubspec) {
  final lines = pubspec.split('\n');
  final testIndex = lines.indexWhere(
    (line) => RegExp(r'^    test:\s*(\|\s*)?$').hasMatch(line),
  );
  expect(testIndex, isNonNegative, reason: 'melos.scripts.test не найден');

  final block = <String>[];
  for (var i = testIndex + 1; i < lines.length; i++) {
    final line = lines[i];
    final indent = line.length - line.trimLeft().length;
    if (line.trim().isEmpty || indent > 4) {
      block.add(line);
      continue;
    }
    break;
  }

  final commandIndex = block.indexWhere(
    (line) => RegExp(r'^\s*command:\s*\|').hasMatch(line),
  );
  final usesExec = block.any((line) => RegExp(r'^\s*exec:').hasMatch(line));
  final command = commandIndex < 0
      ? _dedent(block)
      : _dedent(block.sublist(commandIndex + 1));
  return MelosTestScript(command: command, usesExec: usesExec);
}

String extractGrepPattern(String command) {
  final match = RegExp(r"grep -qE '([^']+)'").firstMatch(command);
  expect(match, isNotNull, reason: 'паттерн grep -qE не найден');
  return match!.group(1)!;
}

Future<bool> grepMatches(String pattern, String content) async {
  final process = await Process.start('grep', ['-qE', pattern]);
  process.stdin.write(content);
  await process.stdin.close();
  await process.stdout.drain<void>();
  await process.stderr.drain<void>();
  return await process.exitCode == 0;
}

const _flutterPackage =
    'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n';
const _flutterWorkspaceRoot =
    'name: opensink\ndependencies:\n  flutter:\n    sdk: flutter\n';
const _dartPackage =
    'name: core_domain\ndependencies:\n  core_protocol:\n    path: ../core_protocol\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MelosTestScript script;
  late String melosCommand;

  setUpAll(() {
    final root = findRepoRoot();
    final pubspec = File('$root/pubspec.yaml').readAsStringSync();
    script = parseMelosTestScript(pubspec);
    expect(script.command, isNotEmpty);
    melosCommand = normalizeLikeMelos(script.command);
  });

  test('melos test runs once per package via exec', () {
    expect(
      script.usesExec,
      isTrue,
      reason: 'melos 8 выполняет `run`-скрипт только в корне workspace',
    );
  });

  test('Flutter packages select flutter test', () async {
    final pattern = extractGrepPattern(melosCommand);
    expect(await grepMatches(pattern, _flutterPackage), isTrue);
    expect(await grepMatches(pattern, _flutterWorkspaceRoot), isTrue);
    expect(melosCommand, contains('flutter test'));
  });

  test('pure Dart packages select dart test', () async {
    final pattern = extractGrepPattern(melosCommand);
    expect(await grepMatches(pattern, _dartPackage), isFalse);
    expect(melosCommand, contains('dart test'));
  });

  test('web-only and test-less packages are skipped', () {
    expect(melosCommand, contains('-d test'));
    expect(melosCommand, contains('MELOS_PACKAGE_NAME'));
    expect(melosCommand, contains('platform_web'));
  });

  test('Flutter painting toolchain compiles', () {
    expect(clampDouble(5, 0, 3), 3);
    final painter = TextPainter(
      text: const TextSpan(text: 'opensink', style: TextStyle(fontSize: 14)),
      textDirection: TextDirection.ltr,
    )..layout();
    final position = painter.getPositionForOffset(const Offset(1, 1));
    expect(position.offset, greaterThanOrEqualTo(0));
    painter.dispose();
  });
}
