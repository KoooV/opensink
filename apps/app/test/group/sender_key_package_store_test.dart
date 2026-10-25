import 'dart:typed_data';

import 'package:app/group/sender_key_package_store.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';
import 'package:flutter_test/flutter_test.dart';

const _groupId = GroupId('group-a');

StoredSenderKeyPackage _entry(
  UserId recipient,
  SenderKeyPackageState state, {
  String? reason,
}) {
  return StoredSenderKeyPackage(
    package: SenderKeyPackage(
      groupId: _groupId,
      epoch: 2,
      sender: const UserId('alice'),
      recipient: recipient,
      keyPackage: Uint8List.fromList(<int>[1, 2, 3]),
    ),
    state: state,
    reason: reason,
  );
}

void main() {
  test('пакеты и индексы переживают пересоздание store', () async {
    final keyStore = MemorySecureKeyStore();
    final first = SecureSenderKeyPackageStore(keyStore);
    await first.save(
      _entry(const UserId('bob'), SenderKeyPackageState.verified),
    );
    await first.save(
      _entry(const UserId('carol'), SenderKeyPackageState.pending),
    );

    final restarted = SecureSenderKeyPackageStore(keyStore);
    final verified = await restarted.load(
      _groupId,
      SenderKeyPackageState.verified,
    );
    final pending = await restarted.load(
      _groupId,
      SenderKeyPackageState.pending,
    );

    expect(verified.unwrap().single.package.recipient, const UserId('bob'));
    expect(verified.unwrap().single.package.keyPackage, [1, 2, 3]);
    expect(pending.unwrap().single.package.recipient, const UserId('carol'));
  });

  test('карантин хранит причину', () async {
    final store = SecureSenderKeyPackageStore(MemorySecureKeyStore());
    await store.save(
      _entry(
        const UserId('bob'),
        SenderKeyPackageState.quarantined,
        reason: 'bad signature',
      ),
    );

    final quarantined = await store.load(
      _groupId,
      SenderKeyPackageState.quarantined,
    );
    expect(quarantined.unwrap().single.reason, 'bad signature');
  });
}
