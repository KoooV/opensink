import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../result.dart';
import 'identifiers.dart';

/// Домен подписи доверенных метаданных группы.
const String groupMetadataAuthDomain = 'opensink/group/metadata/v2|';

/// Источник доверия для группы.
enum GroupOrigin {
  /// Группа создана локально; genesis ещё может быть не записан.
  created('created'),

  /// Группа открыта по инвайту; genesis известен из ссылки.
  invited('invited');

  const GroupOrigin(this.value);

  final String value;

  static GroupOrigin? fromValue(String value) {
    for (final origin in values) {
      if (origin.value == value) return origin;
    }
    return null;
  }
}

/// Доменные ошибки метаданных группы.
sealed class GroupMetadataError {
  const GroupMetadataError();

  @override
  String toString() => runtimeType.toString();
}

/// Сохранённые метаданные повреждены или несовместимы.
class CorruptedGroupMetadata extends GroupMetadataError {
  const CorruptedGroupMetadata(this.reason);

  final String reason;

  @override
  String toString() => 'CorruptedGroupMetadata($reason)';
}

/// Инфраструктурная ошибка хранилища метаданных.
class GroupMetadataStorageFailure extends GroupMetadataError {
  const GroupMetadataStorageFailure(this.reason);

  final String reason;

  @override
  String toString() => 'GroupMetadataStorageFailure($reason)';
}

/// Доверенный корень группы.
///
/// [groupId] и [genesisEventId] не выбираются из лога: create сохраняет
/// сгенерированный id до genesis, invite приносит оба значения из ссылки.
/// Для `created` до записи genesis [genesisEventId] равен `null`.
@immutable
class GroupMetadata {
  const GroupMetadata({
    required this.groupId,
    required this.origin,
    required this.createdAt,
    this.genesisEventId,
    this.inviterId,
    this.signerId,
    this.signature,
  });

  final GroupId groupId;
  final EventId? genesisEventId;
  final GroupOrigin origin;
  final int createdAt;

  /// Кто выдал инвайт; заполняется для `invited`-групп.
  final UserId? inviterId;

  /// Локальный ключ, которым подписаны метаданные.
  final UserId? signerId;

  /// Ed25519-подпись канонического представления метаданных.
  final String? signature;

  bool get isReady => genesisEventId != null;

  bool get isAuthenticated => signerId != null && signature != null;

  GroupMetadata withGenesis(EventId genesis) {
    return GroupMetadata(
      groupId: groupId,
      genesisEventId: genesis,
      origin: origin,
      createdAt: createdAt,
      inviterId: inviterId,
      signerId: signerId,
      signature: signature,
    );
  }

  GroupMetadata withAuth({
    required UserId signerId,
    required String signature,
  }) {
    return GroupMetadata(
      groupId: groupId,
      genesisEventId: genesisEventId,
      origin: origin,
      createdAt: createdAt,
      inviterId: inviterId,
      signerId: signerId,
      signature: signature,
    );
  }

  /// Канонические байты для Ed25519-подписи.
  Uint8List signingBytes(UserId signerId) {
    final buffer = StringBuffer(groupMetadataAuthDomain)
      ..write(groupId.value)
      ..write('|')
      ..write(genesisEventId?.value ?? '')
      ..write('|')
      ..write(origin.value)
      ..write('|')
      ..write(createdAt)
      ..write('|')
      ..write(inviterId?.value ?? '')
      ..write('|')
      ..write(signerId.value);
    return Uint8List.fromList(utf8.encode(buffer.toString()));
  }

  Map<String, Object?> toJson() => {
    'version': 2,
    'group_id': groupId.value,
    if (genesisEventId != null) 'genesis_event_id': genesisEventId!.value,
    'origin': origin.value,
    'created_at': createdAt,
    if (inviterId != null) 'inviter_id': inviterId!.value,
    if (signerId != null) 'signer_id': signerId!.value,
    if (signature != null) 'signature': signature,
  };

  static Result<GroupMetadata, GroupMetadataError> fromJson(Object? json) {
    if (json is! Map) {
      return const Err(CorruptedGroupMetadata('metadata is not an object'));
    }
    final version = json['version'];
    if (version != 1 && version != 2) {
      return const Err(CorruptedGroupMetadata('unsupported version'));
    }
    final groupId = json['group_id'];
    if (groupId is! String || groupId.isEmpty) {
      return const Err(CorruptedGroupMetadata('missing group_id'));
    }
    final originValue = json['origin'];
    if (originValue is! String) {
      return const Err(CorruptedGroupMetadata('missing origin'));
    }
    final origin = GroupOrigin.fromValue(originValue);
    if (origin == null) {
      return const Err(CorruptedGroupMetadata('unknown origin'));
    }
    final createdAt = json['created_at'];
    if (createdAt is! int) {
      return const Err(CorruptedGroupMetadata('invalid created_at'));
    }
    final genesis = json['genesis_event_id'];
    if (genesis != null && (genesis is! String || genesis.isEmpty)) {
      return const Err(CorruptedGroupMetadata('invalid genesis_event_id'));
    }
    if (origin == GroupOrigin.invited && genesis == null) {
      return const Err(CorruptedGroupMetadata('invited group without genesis'));
    }
    final inviter = json['inviter_id'];
    if (inviter != null && (inviter is! String || inviter.isEmpty)) {
      return const Err(CorruptedGroupMetadata('invalid inviter_id'));
    }
    final signer = json['signer_id'];
    if (signer != null && (signer is! String || signer.isEmpty)) {
      return const Err(CorruptedGroupMetadata('invalid signer_id'));
    }
    final signature = json['signature'];
    if (signature != null && (signature is! String || signature.isEmpty)) {
      return const Err(CorruptedGroupMetadata('invalid signature'));
    }
    if ((signer == null) != (signature == null)) {
      return const Err(CorruptedGroupMetadata('incomplete metadata auth'));
    }
    return Ok(
      GroupMetadata(
        groupId: GroupId(groupId),
        genesisEventId: genesis == null ? null : EventId(genesis as String),
        origin: origin,
        createdAt: createdAt,
        inviterId: inviter == null ? null : UserId(inviter as String),
        signerId: signer == null ? null : UserId(signer as String),
        signature: signature as String?,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupMetadata &&
          runtimeType == other.runtimeType &&
          groupId == other.groupId &&
          genesisEventId == other.genesisEventId &&
          origin == other.origin &&
          createdAt == other.createdAt &&
          inviterId == other.inviterId &&
          signerId == other.signerId &&
          signature == other.signature;

  @override
  int get hashCode => Object.hash(
    groupId,
    genesisEventId,
    origin,
    createdAt,
    inviterId,
    signerId,
    signature,
  );

  @override
  String toString() =>
      'GroupMetadata(groupId=${groupId.value}, '
      'genesisEventId=${genesisEventId?.value}, origin=${origin.value})';
}
