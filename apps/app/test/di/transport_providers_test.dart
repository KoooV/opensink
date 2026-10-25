import 'dart:async';
import 'dart:typed_data';

import 'package:app/di/providers.dart';
import 'package:app/group/group_secret_store.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_peer/core_peer.dart';
import 'package:core_signaling/core_signaling.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRichSignalingChannel implements RichSignalingChannel {
  final List<String> joined = <String>[];
  final StreamController<SignalingMessage> _incoming =
      StreamController<SignalingMessage>.broadcast();
  final StreamController<SignalingPacket> _packets =
      StreamController<SignalingPacket>.broadcast();
  final StreamController<PeerPresence> _presence =
      StreamController<PeerPresence>.broadcast();

  @override
  Stream<SignalingMessage> get incoming => _incoming.stream;

  @override
  Stream<SignalingPacket> get packets => _packets.stream;

  @override
  Stream<PeerPresence> get presence => _presence.stream;

  @override
  Future<void> join(String topic) async {
    joined.add(topic);
  }

  @override
  Future<void> publish(String topic, List<int> bytes) async {}

  @override
  Future<void> publishTo(
    String topic, {
    required SignalingKind kind,
    PeerId? to,
    required List<int> bytes,
  }) async {}

  @override
  Future<void> close() async {
    await _incoming.close();
    await _packets.close();
    await _presence.close();
  }
}

void main() {
  const groupId = GroupId('di-transport');

  test(
    'transportProvider строит WebRtcTransport и входит в тему группы',
    () async {
      final identity = await generateIdentity();
      final channel = _FakeRichSignalingChannel();
      addTearDown(channel.close);
      const topic = 'group-topic-under-test';
      final container = ProviderContainer(
        overrides: <Override>[
          localIdentityProvider.overrideWith(
            (ref) async => LocalIdentity(
              userId: identity.userId,
              signer: CryptoSigner(identity.ed25519PrivateKey),
            ),
          ),
          signalingChannelProvider(groupId)
              .overrideWith((ref) async => channel),
          groupTopicProvider(groupId).overrideWith((ref) async => topic),
        ],
      );
      addTearDown(container.dispose);

      final transport = await container.read(transportProvider(groupId).future);

      expect(transport, isA<WebRtcTransport>());
      expect(channel.joined, contains(topic));
      expect(transport.statsFor(PeerId(Uint8List(32))), isNull);
    },
  );

  test(
    'GroupSecret читается из SecureKeyStore и отсутствие fail-closed',
    () async {
      final keyStore = MemorySecureKeyStore();
      final secretStore = SecureGroupSecretStore(keyStore);
      final secret = List<int>.generate(32, (index) => index);
      await secretStore.save(groupId, secret);
      final container = ProviderContainer(
        overrides: <Override>[
          secureKeyStoreProvider.overrideWithValue(keyStore),
        ],
      );
      addTearDown(container.dispose);

      final loaded = await container.read(groupSecretProvider(groupId).future);

      expect(await loaded.topicHex(), isNotEmpty);
      expect((await secretStore.load(groupId)).unwrap(), secret);

      const missing = GroupId('missing-secret');
      await expectLater(
        container.read(groupSecretProvider(missing).future),
        throwsA(isA<StateError>()),
      );
    },
  );
}
