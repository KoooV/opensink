import 'package:core_group/core_group.dart';

import '../group/group_invite_service.dart';

String lifecycleErrorMessage(GroupLifecycleError error) {
  return switch (error) {
    GroupNotFound() => 'Группа не найдена.',
    GroupMetadataUnavailable() =>
      'Метаданные группы повреждены или недоступны.',
    GroupCreateFailed() => 'Не удалось создать группу.',
    GroupOpenFailed() => 'Не удалось открыть группу.',
    GroupRootConflict() => 'Конфликт корня группы: группа не изменена.',
    GroupInviteUnsupported() => 'Вход по инвайту не поддерживается.',
    GroupInviteRejected() =>
      'Инвайт отклонён: подпись или срок недействительны.',
    GroupSecretStorageFailed() => 'Не удалось сохранить секрет группы.',
  };
}

String inviteErrorMessage(GroupInviteFailure failure) {
  return switch (failure) {
    InviteGroupNotReady() => 'Группа ещё не готова к выдаче инвайта.',
    InviteSecretUnavailable() => 'Секрет группы недоступен.',
    InvitePublishFailed(:final error) =>
      error is ControllerFailure && error.error is Forbidden
          ? 'Нет прав на выдачу инвайта.'
          : 'Не удалось опубликовать инвайт.',
    InviteJoinFailed(:final error) => lifecycleErrorMessage(error),
    InviteMembershipPending() =>
      'Группа добавлена. Вход в участники завершится после загрузки истории.',
    InviteMembershipFailed() => 'Не удалось отправить запрос на вход.',
    InviteNotPending() => 'Заявка на вход не найдена.',
    InviteApproveFailed() => 'Не удалось подтвердить заявку.',
  };
}
