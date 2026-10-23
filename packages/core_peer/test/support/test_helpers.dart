import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';

PeerId peerId(int seed) => PeerId(
  Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xFF)),
);

Future<void> waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
  Duration step = const Duration(milliseconds: 10),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('waitUntil timeout${reason == null ? '' : ': $reason'}');
    }
    await Future<void>.delayed(step);
  }
}
