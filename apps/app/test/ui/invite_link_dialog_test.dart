import 'package:app/ui/group_screen.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  testWidgets('диалог инвайта показывает QR и ссылку для share', (
    tester,
  ) async {
    final identity = await generateIdentity();
    final link = await InviteLink.issue(
      signer: CryptoSigner(identity.ed25519PrivateKey),
      groupId: const GroupId('g'),
      genesisEventId: EventId('a' * 64),
      inviteId: 'invite-1',
      secret: encodeGroupSecretToken(List<int>.filled(32, 7)),
      inviterId: identity.userId,
      expiresAt: DateTime.now()
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InviteLinkDialog(link: link)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text(link.toUriString()), findsOneWidget);
    expect(find.text('Копировать'), findsOneWidget);
  });
}
