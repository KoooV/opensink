import '../models/group_metadata.dart';
import '../models/identifiers.dart';
import '../result.dart';

/// Хранилище доверенных метаданных групп.
///
/// Не секрет: используется для восстановления корня группы и активной группы.
/// Реализации платформенные (core_storage) или in-memory для тестов.
abstract class GroupMetadataStore {
  /// Загружает метаданные группы или `Ok(null)`, если группы нет.
  Future<Result<GroupMetadata?, GroupMetadataError>> load(GroupId groupId);

  /// Все сохранённые метаданные групп.
  Future<Result<List<GroupMetadata>, GroupMetadataError>> list();

  /// Создаёт или заменяет метаданные группы.
  Future<Result<void, GroupMetadataError>> save(GroupMetadata metadata);

  /// Удаляет метаданные группы.
  Future<Result<void, GroupMetadataError>> delete(GroupId groupId);

  /// Активная группа приложения или `null`.
  Future<Result<GroupId?, GroupMetadataError>> loadActiveGroup();

  /// Сохраняет активную группу; `null` очищает выбор.
  Future<Result<void, GroupMetadataError>> saveActiveGroup(GroupId? groupId);
}
