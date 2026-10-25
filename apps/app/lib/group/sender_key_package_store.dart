import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';

/// Кэш sender key пакетов в платформенном [SecureKeyStore].
///
/// Каждый пакет хранится отдельной записью; индекс группы позволяет
/// восстановить verified-кэш после рестарта. Ключевой материал остаётся
/// внутри защищённого хранилища платформы.
class SecureSenderKeyPackageStore implements SenderKeyPackageStore {
  const SecureSenderKeyPackageStore(this._store);

  static const String _entryPrefix = 'opensink.sender_key_package.v1:';
  static const String _indexPrefix = 'opensink.sender_key_package_index.v1:';

  final SecureKeyStore _store;

  String _indexKey(GroupId groupId) => '$_indexPrefix${groupId.value}';

  String _entryKey(GroupId groupId, String packageId) {
    final encoded = base64Url.encode(utf8.encode(packageId));
    return '$_entryPrefix${groupId.value}:$encoded';
  }

  @override
  Future<Result<void, SenderKeyPackageStoreError>> save(
    StoredSenderKeyPackage entry,
  ) async {
    final package = entry.package;
    final key = _entryKey(package.groupId, package.id);
    final bytes = utf8.encode(
      jsonEncode(<String, Object?>{
        'version': 1,
        'groupId': package.groupId.value,
        'epoch': package.epoch,
        'sender': package.sender.value,
        'recipient': package.recipient.value,
        'keyPackage': base64Encode(package.keyPackage),
        'state': entry.state.name,
        'reason': entry.reason,
      }),
    );
    final stored = await _store.storeKey(key, bytes);
    if (stored.isErr) {
      return Err(
        SenderKeyPackageStoreUnavailable(stored.unwrapErr().toString()),
      );
    }

    final index = await _loadIndex(package.groupId);
    if (index.isErr) return Err(index.unwrapErr());
    final ids = index.unwrap();
    if (!ids.contains(package.id)) {
      ids.add(package.id);
      final savedIndex = await _store.storeKey(
        _indexKey(package.groupId),
        utf8.encode(jsonEncode(ids)),
      );
      if (savedIndex.isErr) {
        return Err(
          SenderKeyPackageStoreUnavailable(savedIndex.unwrapErr().toString()),
        );
      }
    }
    return const Ok(null);
  }

  @override
  Future<Result<List<StoredSenderKeyPackage>, SenderKeyPackageStoreError>> load(
    GroupId groupId,
    SenderKeyPackageState state,
  ) async {
    final index = await _loadIndex(groupId);
    if (index.isErr) return Err(index.unwrapErr());
    final loaded = <StoredSenderKeyPackage>[];
    for (final packageId in index.unwrap()) {
      final bytes = await _store.loadKey(_entryKey(groupId, packageId));
      if (bytes.isErr) {
        if (bytes.unwrapErr() is IdentityNotFound) continue;
        return Err(
          SenderKeyPackageStoreUnavailable(bytes.unwrapErr().toString()),
        );
      }
      final entry = _decode(groupId, bytes.unwrap());
      if (entry == null) {
        return const Err(
          SenderKeyPackageStoreUnavailable(
            'stored sender key package is corrupted',
          ),
        );
      }
      if (entry.state == state) loaded.add(entry);
    }
    return Ok(List<StoredSenderKeyPackage>.unmodifiable(loaded));
  }

  Future<Result<List<String>, SenderKeyPackageStoreError>> _loadIndex(
    GroupId groupId,
  ) async {
    final loaded = await _store.loadKey(_indexKey(groupId));
    if (loaded.isErr) {
      if (loaded.unwrapErr() is IdentityNotFound) {
        return Ok(List<String>.empty(growable: true));
      }
      return Err(
        SenderKeyPackageStoreUnavailable(loaded.unwrapErr().toString()),
      );
    }
    try {
      final decoded = jsonDecode(utf8.decode(loaded.unwrap()));
      if (decoded is! List) {
        return const Err(
          SenderKeyPackageStoreUnavailable('sender key index is corrupted'),
        );
      }
      return Ok(decoded.whereType<String>().toList(growable: true));
    } on FormatException {
      return const Err(
        SenderKeyPackageStoreUnavailable('sender key index is corrupted'),
      );
    }
  }

  StoredSenderKeyPackage? _decode(GroupId groupId, List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, Object?>) return null;
      if (decoded['version'] != 1) return null;
      if (decoded['groupId'] != groupId.value) return null;
      final epoch = decoded['epoch'];
      final sender = decoded['sender'];
      final recipient = decoded['recipient'];
      final keyPackage = decoded['keyPackage'];
      final state = decoded['state'];
      if (epoch is! int ||
          sender is! String ||
          recipient is! String ||
          keyPackage is! String ||
          state is! String) {
        return null;
      }
      SenderKeyPackageState? stateValue;
      for (final value in SenderKeyPackageState.values) {
        if (value.name == state) {
          stateValue = value;
          break;
        }
      }
      if (stateValue == null) return null;
      return StoredSenderKeyPackage(
        package: SenderKeyPackage(
          groupId: groupId,
          epoch: epoch,
          sender: UserId(sender),
          recipient: UserId(recipient),
          keyPackage: Uint8List.fromList(base64Decode(keyPackage)),
        ),
        state: stateValue,
        reason: decoded['reason'] as String?,
      );
    } on FormatException {
      return null;
    }
  }
}
