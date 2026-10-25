import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart' show hexDecode;
import 'package:meta/meta.dart';

/// Домен подписи sender-key пакета.
const String senderKeyPackageSigningDomain =
    'opensink/group/sender-key-package/v1';

/// Пакет нового sender key для доставки оставшимся участникам.
@immutable
class GroupKeyRotation {
  const GroupKeyRotation({
    required this.groupId,
    required this.epoch,
    required this.sender,
    required this.recipients,
    required this.keyPackage,
    this.signature,
  });

  final GroupId groupId;
  final int epoch;
  final UserId sender;
  final Set<UserId> recipients;
  final Uint8List keyPackage;

  /// Подпись пакета для конкретного получателя; заполняется при приёме
  /// удалённой ротации. Локальная рассылка подписывает каждый пакет отдельно.
  final String? signature;

  @override
  String toString() =>
      'GroupKeyRotation(groupId=$groupId, epoch=$epoch, '
      'recipients=${recipients.length}, keyPackage=<hidden>)';
}

/// Доставка новых sender keys по E2E-зашифрованным личным сообщениям.
abstract class GroupKeyDistributor {
  Future<void> distribute(GroupKeyRotation rotation);
}

/// In-memory fake для тестов: запоминает ротации, ничего не шифрует.
class InMemoryGroupKeyDistributor implements GroupKeyDistributor {
  final _rotations = <GroupKeyRotation>[];

  List<GroupKeyRotation> get rotations => List.unmodifiable(_rotations);

  @override
  Future<void> distribute(GroupKeyRotation rotation) async {
    _rotations.add(rotation);
  }
}

/// Пакет sender key, адресованный одному участнику группы.
@immutable
class SenderKeyPackage {
  const SenderKeyPackage({
    required this.groupId,
    required this.epoch,
    required this.sender,
    required this.recipient,
    required this.keyPackage,
    this.signature,
  });

  final GroupId groupId;
  final int epoch;
  final UserId sender;
  final UserId recipient;
  final Uint8List keyPackage;

  /// Ed25519-подпись [signingBytes] ключом отправителя.
  final String? signature;

  /// Стабильный ключ дедупликации в кэше/карантине.
  String get id => '${groupId.value}/$epoch/${sender.value}/${recipient.value}';

  /// Канонические байты для Ed25519-подписи.
  ///
  /// Поля кодируются с префиксом длины, поэтому подпись связывает группу,
  /// эпоху, отправителя, получателя и сам ключевой пакет.
  Uint8List signingBytes() {
    final builder = BytesBuilder(copy: false);
    void addField(List<int> bytes) {
      final length = ByteData(4)..setUint32(0, bytes.length);
      builder.add(length.buffer.asUint8List());
      builder.add(bytes);
    }

    addField(utf8.encode(senderKeyPackageSigningDomain));
    addField(utf8.encode(groupId.value));
    final epochBytes = ByteData(8)..setInt64(0, epoch);
    addField(epochBytes.buffer.asUint8List());
    addField(utf8.encode(sender.value));
    addField(utf8.encode(recipient.value));
    addField(keyPackage);
    return builder.toBytes();
  }

  SenderKeyPackage withSignature(String signature) {
    return SenderKeyPackage(
      groupId: groupId,
      epoch: epoch,
      sender: sender,
      recipient: recipient,
      keyPackage: Uint8List.fromList(keyPackage),
      signature: signature,
    );
  }

  SenderKeyPackage copyWith({
    GroupId? groupId,
    int? epoch,
    UserId? sender,
    UserId? recipient,
    Uint8List? keyPackage,
    String? signature,
  }) {
    return SenderKeyPackage(
      groupId: groupId ?? this.groupId,
      epoch: epoch ?? this.epoch,
      sender: sender ?? this.sender,
      recipient: recipient ?? this.recipient,
      keyPackage: keyPackage ?? Uint8List.fromList(this.keyPackage),
      signature: signature ?? this.signature,
    );
  }

  /// Проверяет структурные инварианты пакета до проверки подписи/сессии.
  SenderKeyPackageError? validate({int maxPackageBytes = 64 * 1024}) {
    if (groupId.value.trim().isEmpty) {
      return const InvalidSenderKeyPackage('group id is empty');
    }
    if (epoch <= 0) {
      return const InvalidSenderKeyPackage('epoch must be positive');
    }
    if (sender.value.trim().isEmpty) {
      return const InvalidSenderKeyPackage('sender is empty');
    }
    if (recipient.value.trim().isEmpty) {
      return const InvalidSenderKeyPackage('recipient is empty');
    }
    if (sender == recipient) {
      return const InvalidSenderKeyPackage('sender cannot be the recipient');
    }
    if (keyPackage.isEmpty) {
      return const InvalidSenderKeyPackage('key package is empty');
    }
    if (keyPackage.length > maxPackageBytes) {
      return const InvalidSenderKeyPackage('key package is too large');
    }
    return null;
  }

  @override
  String toString() =>
      'SenderKeyPackage(groupId=$groupId, epoch=$epoch, sender=$sender, '
      'recipient=$recipient, keyPackage=<hidden>)';
}

/// Доменные ошибки пакета/кэша sender keys.
sealed class SenderKeyPackageError {
  const SenderKeyPackageError();

  @override
  String toString() => runtimeType.toString();
}

class InvalidSenderKeyPackage extends SenderKeyPackageError {
  const InvalidSenderKeyPackage(this.reason);

  final String reason;

  @override
  String toString() => 'InvalidSenderKeyPackage($reason)';
}

class SenderKeyPackageStoreFailure extends SenderKeyPackageError {
  const SenderKeyPackageStoreFailure(this.reason);

  final String reason;

  @override
  String toString() => 'SenderKeyPackageStoreFailure($reason)';
}

/// Ошибки E2E-доставки пакета.
sealed class SenderKeyDeliveryError {
  const SenderKeyDeliveryError();

  @override
  String toString() => runtimeType.toString();
}

class SenderKeyRecipientUnavailable extends SenderKeyDeliveryError {
  const SenderKeyRecipientUnavailable(this.recipient);

  final UserId recipient;

  @override
  String toString() => 'SenderKeyRecipientUnavailable(${recipient.value})';
}

class SenderKeyDeliveryRejected extends SenderKeyDeliveryError {
  const SenderKeyDeliveryRejected(this.reason);

  final String reason;

  @override
  String toString() => 'SenderKeyDeliveryRejected($reason)';
}

/// Порт доставки пакета конкретному участнику по личному E2E-каналу.
abstract class SenderKeyDelivery {
  Future<Result<void, SenderKeyDeliveryError>> deliver(
    SenderKeyPackage package,
  );
}

/// Fail-closed доставка: пока E2E-сессия не установлена, пакет остаётся
/// в pending и может быть повторён через [ProductionGroupKeyDistributor].
class UnavailableSenderKeyDelivery implements SenderKeyDelivery {
  const UnavailableSenderKeyDelivery();

  @override
  Future<Result<void, SenderKeyDeliveryError>> deliver(
    SenderKeyPackage package,
  ) async {
    return const Err(SenderKeyDeliveryRejected('E2E channel unavailable'));
  }
}

/// Проверка пакета после расшифровки личного E2E-канала.
///
/// Реализация связывает пакет с доверенными метаданными группы и проверяет
/// подпись/ключ отправителя. `core_group` не знает формат sender key.
abstract class SenderKeyPackageVerifier {
  Future<Result<void, SenderKeyPackageError>> verify(SenderKeyPackage package);
}

/// Состояние записи в кэше пакетов.
enum SenderKeyPackageState { pending, delivered, verified, quarantined }

@immutable
class StoredSenderKeyPackage {
  const StoredSenderKeyPackage({
    required this.package,
    required this.state,
    this.reason,
  });

  final SenderKeyPackage package;
  final SenderKeyPackageState state;
  final String? reason;

  @override
  String toString() =>
      'StoredSenderKeyPackage(package=$package, state=$state, reason=$reason)';
}

sealed class SenderKeyPackageStoreError {
  const SenderKeyPackageStoreError();

  @override
  String toString() => runtimeType.toString();
}

class SenderKeyPackageStoreUnavailable extends SenderKeyPackageStoreError {
  const SenderKeyPackageStoreUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'SenderKeyPackageStoreUnavailable($reason)';
}

/// Персистентный кэш пакетов sender keys.
///
/// В production хранится в защищённом хранилище; записи `verified` должны
/// перечитываться и перепроверяться при старте.
abstract class SenderKeyPackageStore {
  Future<Result<void, SenderKeyPackageStoreError>> save(
    StoredSenderKeyPackage entry,
  );

  Future<Result<List<StoredSenderKeyPackage>, SenderKeyPackageStoreError>> load(
    GroupId groupId,
    SenderKeyPackageState state,
  );
}

/// In-memory реализация для тестов и локальной проверки.
class MemorySenderKeyPackageStore implements SenderKeyPackageStore {
  final Map<String, Map<String, StoredSenderKeyPackage>> _entries = {};

  @override
  Future<Result<void, SenderKeyPackageStoreError>> save(
    StoredSenderKeyPackage entry,
  ) async {
    final group = _entries.putIfAbsent(entry.package.groupId.value, () => {});
    group[entry.package.id] = entry;
    return const Ok(null);
  }

  @override
  Future<Result<List<StoredSenderKeyPackage>, SenderKeyPackageStoreError>> load(
    GroupId groupId,
    SenderKeyPackageState state,
  ) async {
    final group = _entries[groupId.value] ?? const {};
    return Ok(
      List<StoredSenderKeyPackage>.unmodifiable(
        group.values.where((entry) => entry.state == state),
      ),
    );
  }
}

class SenderKeyRetryReport {
  const SenderKeyRetryReport({required this.delivered, required this.failed});

  final int delivered;
  final int failed;

  @override
  String toString() =>
      'SenderKeyRetryReport(delivered=$delivered, failed=$failed)';
}

/// Production-рассылка sender keys с verified-кэшем и карантином.
///
/// Локальный автор рассылает пакет каждому получателю через [delivery].
/// Неудачная доставка остаётся `pending` и повторяется [retryPending] после
/// восстановления E2E-сессии/рестарта. Входящий пакет проверяется
/// [verifier] и только после этого попадает в `verified`; отклонённый —
/// в `quarantined` с причиной. [restore] перечитывает verified-кэш и
/// повторно проверяет его при старте.
class ProductionGroupKeyDistributor implements GroupKeyDistributor {
  ProductionGroupKeyDistributor({
    required this.localUser,
    this.signer,
    required this.delivery,
    required this.store,
    required this.verifier,
    this.maxPackageBytes = 64 * 1024,
  });

  final UserId localUser;

  /// Подписчик локальной identity. Без него рассылка и приём подписанных
  /// пакетов fail-closed: пакеты не подписываются и не попадают в verified.
  final Signer? signer;
  final SenderKeyDelivery delivery;
  final SenderKeyPackageStore store;
  final SenderKeyPackageVerifier verifier;
  final int maxPackageBytes;

  SenderKeyPackageError? _lastError;

  /// Последняя структурная/карантинная ошибка, если `distribute`/`receive`
  /// не смогли обработать пакет. Ошибки доставки остаются в `pending`.
  SenderKeyPackageError? get lastError => _lastError;

  @override
  Future<void> distribute(GroupKeyRotation rotation) async {
    _lastError = null;
    if (rotation.sender != localUser) {
      await _acceptRemoteRotation(rotation);
      return;
    }
    if (rotation.groupId.value.trim().isEmpty) {
      _lastError = const InvalidSenderKeyPackage('group id is empty');
      return;
    }
    if (rotation.epoch <= 0) {
      _lastError = const InvalidSenderKeyPackage('epoch must be positive');
      return;
    }
    if (rotation.keyPackage.isEmpty) {
      _lastError = const InvalidSenderKeyPackage('key package is empty');
      return;
    }
    if (rotation.recipients.contains(localUser)) {
      _lastError = const InvalidSenderKeyPackage(
        'sender cannot be the recipient',
      );
      return;
    }

    for (final recipient in rotation.recipients) {
      final package = SenderKeyPackage(
        groupId: rotation.groupId,
        epoch: rotation.epoch,
        sender: rotation.sender,
        recipient: recipient,
        keyPackage: Uint8List.fromList(rotation.keyPackage),
      );
      final invalid = package.validate(maxPackageBytes: maxPackageBytes);
      if (invalid != null) {
        _lastError = invalid;
        continue;
      }
      if (await _isDelivered(package)) continue;

      final signed = await _signSafely(package);
      if (signed == null) continue;

      final saved = await store.save(
        StoredSenderKeyPackage(
          package: signed,
          state: SenderKeyPackageState.pending,
        ),
      );
      if (saved.isErr) {
        _lastError = SenderKeyPackageStoreFailure(saved.unwrapErr().toString());
        continue;
      }
      await _deliver(signed);
    }
  }

  /// Принимает пакет, полученный по личному E2E-каналу.
  Future<Result<SenderKeyPackage, SenderKeyPackageError>> receive(
    SenderKeyPackage package,
  ) async {
    _lastError = null;
    final invalid = package.validate(maxPackageBytes: maxPackageBytes);
    if (invalid != null) {
      await _quarantine(package, invalid.toString());
      _lastError = invalid;
      return Err(invalid);
    }
    if (package.recipient != localUser) {
      const error = InvalidSenderKeyPackage('recipient mismatch');
      await _quarantine(package, error.reason);
      _lastError = error;
      return const Err(error);
    }
    final signatureError = await _signatureError(package);
    if (signatureError != null) {
      await _quarantine(package, signatureError.toString());
      _lastError = signatureError;
      return Err(signatureError);
    }

    final Result<void, SenderKeyPackageError> verified;
    try {
      verified = await verifier.verify(package);
    } catch (error) {
      final failure = InvalidSenderKeyPackage('verifier failed: $error');
      await _quarantine(package, failure.reason);
      _lastError = failure;
      return Err(failure);
    }
    if (verified.isErr) {
      final error = verified.unwrapErr();
      await _quarantine(package, error.toString());
      _lastError = error;
      return Err(error);
    }

    final saved = await store.save(
      StoredSenderKeyPackage(
        package: package,
        state: SenderKeyPackageState.verified,
      ),
    );
    if (saved.isErr) {
      final error = SenderKeyPackageStoreFailure(saved.unwrapErr().toString());
      _lastError = error;
      return Err(error);
    }
    return Ok(package);
  }

  /// Восстанавливает verified-кэш после старта, перепроверяя каждый пакет.
  ///
  /// Испорченные/чужие пакеты переводятся в карантин и не возвращаются.
  Future<Result<List<SenderKeyPackage>, SenderKeyPackageError>> restore(
    GroupId groupId,
  ) async {
    _lastError = null;
    final loaded = await store.load(groupId, SenderKeyPackageState.verified);
    if (loaded.isErr) {
      final error = SenderKeyPackageStoreFailure(loaded.unwrapErr().toString());
      _lastError = error;
      return Err(error);
    }

    final restored = <SenderKeyPackage>[];
    for (final entry in loaded.unwrap()) {
      final package = entry.package;
      final invalid = package.validate(maxPackageBytes: maxPackageBytes);
      if (invalid != null) {
        await _quarantine(package, invalid.toString());
        _lastError = invalid;
        continue;
      }
      if (package.recipient != localUser) {
        const error = InvalidSenderKeyPackage('recipient mismatch');
        await _quarantine(package, error.reason);
        _lastError = error;
        continue;
      }
      final signatureError = await _signatureError(package);
      if (signatureError != null) {
        await _quarantine(package, signatureError.toString());
        _lastError = signatureError;
        continue;
      }
      final verified = await _verifySafely(package);
      if (verified.isErr) {
        final error = verified.unwrapErr();
        await _quarantine(package, error.toString());
        _lastError = error;
        continue;
      }
      restored.add(package);
    }
    return Ok(List<SenderKeyPackage>.unmodifiable(restored));
  }

  /// Повторяет доставку pending-пакетов (например, после рестарта).
  Future<Result<SenderKeyRetryReport, SenderKeyPackageError>> retryPending(
    GroupId groupId,
  ) async {
    _lastError = null;
    final loaded = await store.load(groupId, SenderKeyPackageState.pending);
    if (loaded.isErr) {
      final error = SenderKeyPackageStoreFailure(loaded.unwrapErr().toString());
      _lastError = error;
      return Err(error);
    }

    var delivered = 0;
    var failed = 0;
    for (final entry in loaded.unwrap()) {
      final result = await _deliver(entry.package);
      if (result) {
        delivered++;
      } else {
        failed++;
      }
    }
    return Ok(SenderKeyRetryReport(delivered: delivered, failed: failed));
  }

  Future<void> _acceptRemoteRotation(GroupKeyRotation rotation) async {
    if (rotation.keyPackage.isEmpty) return;
    if (!rotation.recipients.contains(localUser)) return;
    final package = SenderKeyPackage(
      groupId: rotation.groupId,
      epoch: rotation.epoch,
      sender: rotation.sender,
      recipient: localUser,
      keyPackage: Uint8List.fromList(rotation.keyPackage),
      signature: rotation.signature,
    );
    final received = await receive(package);
    if (received.isErr) _lastError = received.unwrapErr();
  }

  Future<bool> _isDelivered(SenderKeyPackage package) async {
    final loaded = await store.load(
      package.groupId,
      SenderKeyPackageState.delivered,
    );
    if (loaded.isErr) return false;
    return loaded.unwrap().any((entry) => entry.package.id == package.id);
  }

  Future<bool> _deliver(SenderKeyPackage package) async {
    final Result<void, SenderKeyDeliveryError> result;
    try {
      result = await delivery.deliver(package);
    } catch (_) {
      return false;
    }
    if (result.isErr) return false;
    final saved = await store.save(
      StoredSenderKeyPackage(
        package: package,
        state: SenderKeyPackageState.delivered,
      ),
    );
    return saved.isOk;
  }

  Future<SenderKeyPackage?> _signSafely(SenderKeyPackage package) async {
    final signer = this.signer;
    if (signer == null) {
      _lastError = const InvalidSenderKeyPackage('signer is not configured');
      return null;
    }
    try {
      final bytes = package.signingBytes();
      final signature = await signer.sign(bytes);
      if (signature.isEmpty) {
        _lastError = const InvalidSenderKeyPackage('empty signature');
        return null;
      }
      final senderBytes = hexDecode(localUser.value);
      if (senderBytes == null || senderBytes.length != 32) {
        _lastError = const InvalidSenderKeyPackage('local user key is invalid');
        return null;
      }
      final valid = await signer.verify(bytes, signature, PeerId(senderBytes));
      if (!valid) {
        _lastError = const InvalidSenderKeyPackage(
          'signer does not match local user',
        );
        return null;
      }
      return package.withSignature(signature);
    } catch (error) {
      _lastError = InvalidSenderKeyPackage('signing failed: $error');
      return null;
    }
  }

  Future<SenderKeyPackageError?> _signatureError(
    SenderKeyPackage package,
  ) async {
    final signer = this.signer;
    if (signer == null) {
      return const InvalidSenderKeyPackage('signer is not configured');
    }
    final signature = package.signature;
    if (signature == null || signature.isEmpty) {
      return const InvalidSenderKeyPackage('missing signature');
    }
    final signatureBytes = hexDecode(signature);
    if (signatureBytes == null || signatureBytes.length != 64) {
      return const InvalidSenderKeyPackage('signature is invalid');
    }
    final senderBytes = hexDecode(package.sender.value);
    if (senderBytes == null || senderBytes.length != 32) {
      return const InvalidSenderKeyPackage('sender key is invalid');
    }
    try {
      final valid = await signer.verify(
        package.signingBytes(),
        signature,
        PeerId(senderBytes),
      );
      if (!valid) {
        return const InvalidSenderKeyPackage('signature mismatch');
      }
    } catch (error) {
      return InvalidSenderKeyPackage('signature verification failed: $error');
    }
    return null;
  }

  Future<Result<void, SenderKeyPackageError>> _verifySafely(
    SenderKeyPackage package,
  ) async {
    try {
      return await verifier.verify(package);
    } catch (error) {
      return Err(InvalidSenderKeyPackage('verifier failed: $error'));
    }
  }

  Future<void> _quarantine(SenderKeyPackage package, String reason) async {
    await store.save(
      StoredSenderKeyPackage(
        package: package,
        state: SenderKeyPackageState.quarantined,
        reason: reason,
      ),
    );
  }
}
