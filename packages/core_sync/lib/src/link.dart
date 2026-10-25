import 'dart:async';
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

/// Пакет, доставленный общим синхронизационным транспортом.
class SyncPacket {
  const SyncPacket({required this.src, required this.payload});

  /// Стабильный идентификатор источника (hex Ed25519 public key).
  final String src;

  final Uint8List payload;
}

/// Минимальный порт пакетного транспорта для [PacketSyncLink].
///
/// Реализуется на уровне приложения поверх relay-транспорта: `core_sync` не
/// зависит от `core_relay`. Владение транспортом остаётся у вызывающего.
abstract class SyncPacketTransport {
  Stream<SyncPacket> get incoming;

  Future<void> send(String dst, Uint8List bytes);
}

/// [SyncLink] поверх общего [SyncPacketTransport].
///
/// Входящие пакеты фильтруются по [peerId], поэтому несколько линков могут
/// делить один транспорт. [close] отписывается и закрывает только собственный
/// поток: общий транспорт остаётся открытым.
class PacketSyncLink implements SyncLink {
  PacketSyncLink({required this.transport, required this.peerId}) {
    _subscription = transport.incoming
        .where((packet) => packet.src == peerId)
        .listen(
          (packet) => _incoming.add(Uint8List.fromList(packet.payload)),
          onError: (Object error, StackTrace stackTrace) {
            if (!_incoming.isClosed) {
              _incoming.addError(error, stackTrace);
            }
          },
        );
  }

  final SyncPacketTransport transport;

  @override
  final String peerId;

  // Одиночная подписка с буфером: кадр, пришедший между созданием линка и
  // `attach` в движке, не теряется.
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  StreamSubscription<SyncPacket>? _subscription;
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List bytes) {
    if (_closed) {
      return Future<void>.error(StateError('sync link is closed'));
    }
    return transport.send(peerId, bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    if (!_incoming.isClosed) {
      unawaited(_incoming.close());
    }
  }
}
