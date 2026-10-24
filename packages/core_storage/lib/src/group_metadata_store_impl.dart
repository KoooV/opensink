import 'dart:convert';

import 'package:core_domain/core_domain.dart';

import 'database/app_database.dart';

/// Drift-реализация [GroupMetadataStore] поверх таблицы `group_settings`.
///
/// Схема не меняется: метаданные группы — JSON в `key = group.meta.v1`,
/// активная группа — отдельная запись в служебном `group_id`.
class DriftGroupMetadataStore implements GroupMetadataStore {
  DriftGroupMetadataStore(this._db, {int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const String metadataKey = 'group.meta.v1';
  static const String activeKey = 'active_group';
  static const String activeScope = '__app__';

  final AppDatabase _db;
  final int Function() _nowMs;

  @override
  Future<Result<GroupMetadata?, GroupMetadataError>> load(
    GroupId groupId,
  ) async {
    try {
      final row = await _db.selectGroupSetting(
        groupId: groupId.value,
        key: metadataKey,
      );
      if (row == null) return const Ok(null);
      final decoded = _decode(row['value']);
      if (decoded.isErr) return Err(decoded.unwrapErr());
      final metadata = decoded.unwrap();
      if (metadata.groupId != groupId) {
        return const Err(
          CorruptedGroupMetadata('stored group_id does not match key'),
        );
      }
      return Ok(metadata);
    } on Object {
      return const Err(GroupMetadataStorageFailure('load failed'));
    }
  }

  @override
  Future<Result<List<GroupMetadata>, GroupMetadataError>> list() async {
    try {
      final rows = await _db.selectGroupSettingsByKey(metadataKey);
      final result = <GroupMetadata>[];
      for (final row in rows) {
        final decoded = _decode(row['value']);
        if (decoded.isErr) return Err(decoded.unwrapErr());
        result.add(decoded.unwrap());
      }
      result.sort((a, b) => a.groupId.value.compareTo(b.groupId.value));
      return Ok(result);
    } on Object {
      return const Err(GroupMetadataStorageFailure('list failed'));
    }
  }

  @override
  Future<Result<void, GroupMetadataError>> save(GroupMetadata metadata) async {
    try {
      await _db.upsertGroupSetting(
        id: 'group.meta:${metadata.groupId.value}',
        groupId: metadata.groupId.value,
        key: metadataKey,
        value: jsonEncode(metadata.toJson()),
        updatedAt: _nowMs(),
      );
      return const Ok(null);
    } on Object {
      return const Err(GroupMetadataStorageFailure('save failed'));
    }
  }

  @override
  Future<Result<void, GroupMetadataError>> delete(GroupId groupId) async {
    try {
      await _db.deleteGroupSetting(groupId: groupId.value, key: metadataKey);
      return const Ok(null);
    } on Object {
      return const Err(GroupMetadataStorageFailure('delete failed'));
    }
  }

  @override
  Future<Result<GroupId?, GroupMetadataError>> loadActiveGroup() async {
    try {
      final row = await _db.selectGroupSetting(
        groupId: activeScope,
        key: activeKey,
      );
      if (row == null) return const Ok(null);
      final value = row['value'];
      if (value is! String || value.isEmpty) {
        return const Err(CorruptedGroupMetadata('invalid active group'));
      }
      return Ok(GroupId(value));
    } on Object {
      return const Err(GroupMetadataStorageFailure('load active failed'));
    }
  }

  @override
  Future<Result<void, GroupMetadataError>> saveActiveGroup(
    GroupId? groupId,
  ) async {
    try {
      if (groupId == null) {
        await _db.deleteGroupSetting(groupId: activeScope, key: activeKey);
        return const Ok(null);
      }
      await _db.upsertGroupSetting(
        id: 'app:$activeKey',
        groupId: activeScope,
        key: activeKey,
        value: groupId.value,
        updatedAt: _nowMs(),
      );
      return const Ok(null);
    } on Object {
      return const Err(GroupMetadataStorageFailure('save active failed'));
    }
  }

  Result<GroupMetadata, GroupMetadataError> _decode(Object? value) {
    if (value is! String) {
      return const Err(CorruptedGroupMetadata('metadata is not text'));
    }
    try {
      return GroupMetadata.fromJson(jsonDecode(value));
    } on FormatException {
      return const Err(CorruptedGroupMetadata('metadata is not JSON'));
    }
  }
}
