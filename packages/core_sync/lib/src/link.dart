import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';

import 'bytes.dart';

/// Транспортная абстракция, достаточная для anti-entropy и gossip.
abstract class SyncLink {
  /// Стабильный идентификатор удалённого узла (hex Ed25519 public key).
  String get peerId;

  /// Входящие бинарные кадры.
  Stream<Uint8List> get incoming;

  Future<void> send(Uint8List bytes);

  Future<void> close();
}

/// Адаптер [PeerLink] (core_peer) к [SyncLink] через канал `sync`.
class PeerLinkSyncLink implements SyncLink {
  PeerLinkSyncLink(this._link);

  final PeerLink _link;

  @override
  String get peerId => hexEncode(_link.remotePeerId.publicKey);

  @override
  Stream<Uint8List> get incoming => _link.incoming
      .where((incoming) => incoming.channel == 'sync')
      .map((incoming) => Uint8List.fromList(incoming.bytes));

  @override
  Future<void> send(Uint8List bytes) => _link.send('sync', bytes);

  @override
  Future<void> close() => _link.close();
}
