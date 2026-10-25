import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';

/// Проверяет, что пакет относится к доверенной группе.
///
/// Личный E2E-канал аутентифицирует отправителя, а [GroupMetadataStore]
/// подтверждает доверенный корень группы. Пакет без готовых метаданных или с
/// чужим groupId в verified-кэш не попадает.
class TrustedGroupSenderKeyVerifier implements SenderKeyPackageVerifier {
  const TrustedGroupSenderKeyVerifier(this._metadata);

  final GroupMetadataStore _metadata;

  @override
  Future<Result<void, SenderKeyPackageError>> verify(
    SenderKeyPackage package,
  ) async {
    final loaded = await _metadata.load(package.groupId);
    if (loaded.isErr) {
      return Err(
        SenderKeyPackageStoreFailure(
          'group metadata unavailable: ${loaded.unwrapErr()}',
        ),
      );
    }
    final metadata = loaded.unwrap();
    if (metadata == null || !metadata.isReady) {
      return const Err(
        InvalidSenderKeyPackage('group metadata is not trusted'),
      );
    }
    if (!metadata.isAuthenticated) {
      return const Err(
        InvalidSenderKeyPackage('group metadata is not authenticated'),
      );
    }
    return const Ok(null);
  }
}
