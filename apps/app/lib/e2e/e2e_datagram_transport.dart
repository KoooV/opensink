import 'dart:async';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_relay/core_relay.dart';

/// Входящий личный E2E-пакет с аутентифицированным отправителем.
class E2eDatagram {
  const E2eDatagram({required this.from, required this.bytes});

  final PeerId from;
  final Uint8List bytes;
}

/// Минимальный транспорт для личных E2E-пакетов.
///
/// Реализация обязана доставлять пакет только адресату и сообщать
/// аутентифицированный [E2eDatagram.from].
abstract class E2eDatagramTransport {
  Future<void> start();

  Stream<E2eDatagram> get incoming;

  Future<void> send(PeerId dst, Uint8List bytes);

  Future<void> close();
}

/// Адаптер [RelayTransport] (direct + relay) к [E2eDatagramTransport].
///
/// Прямые пакеты идут в служебном канале `control`, релейные — через
/// [RelayTransport.incoming]. Перед отправкой адаптер гарантирует подписку на
/// прямой линк, иначе direct-ответ был бы потерян.
class TransportE2eDatagramTransport implements E2eDatagramTransport {
  TransportE2eDatagramTransport(this._transport);

  static const String _channel = 'control';

  final RelayTransport _transport;
  final StreamController<E2eDatagram> _incoming =
      StreamController<E2eDatagram>.broadcast();
  final Map<PeerId, StreamSubscription<Incoming>> _links =
      <PeerId, StreamSubscription<Incoming>>{};
  final Set<PeerId> _pending = <PeerId>{};
  StreamSubscription<PeerLinkEvent>? _events;
  StreamSubscription<RelayInbound>? _relay;
  bool _started = false;
  bool _closed = false;

  @override
  Stream<E2eDatagram> get incoming => _incoming.stream;

  @override
  Future<void> start() async {
    if (_started || _closed) return;
    _started = true;
    _relay = _transport.incoming.listen(
      (frame) => _emit(frame.src, Uint8List.fromList(frame.payload)),
      onError: (Object _) {},
    );
    _events = _transport.events.listen((event) {
      final peer = event.peerId;
      if (peer == null) return;
      switch (event.type) {
        case 'connected':
          unawaited(_watch(peer));
        case 'disconnected':
        case 'error':
          unawaited(_forget(peer));
      }
    }, onError: (Object _) {});
    for (final peer in <PeerId>{
      ..._transport.topology.localNeighbors,
      ..._transport.topology.knownPeerIds,
    }) {
      unawaited(_watch(peer));
    }
  }

  @override
  Future<void> send(PeerId dst, Uint8List bytes) async {
    try {
      await _watch(dst).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Медленный direct не должен блокировать relay fallback.
    }
    await _transport.send(dst, bytes);
  }

  Future<void> _watch(PeerId peer) async {
    if (_closed || _links.containsKey(peer) || !_pending.add(peer)) return;
    try {
      final link = await _transport.connect(peer);
      if (_closed) {
        await link.close();
        return;
      }
      final previous = _links.remove(peer);
      await previous?.cancel();
      _links[peer] = link.incoming
          .where((incoming) => incoming.channel == _channel)
          .listen(
            (incoming) => _emit(peer, Uint8List.fromList(incoming.bytes)),
            onError: (Object _) {},
          );
    } catch (_) {
      // Direct недоступен: отправка уйдёт через relay fallback.
    } finally {
      _pending.remove(peer);
    }
  }

  Future<void> _forget(PeerId peer) async {
    final subscription = _links.remove(peer);
    await subscription?.cancel();
  }

  void _emit(PeerId from, Uint8List bytes) {
    if (_closed || _incoming.isClosed) return;
    _incoming.add(E2eDatagram(from: from, bytes: bytes));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _events?.cancel();
    await _relay?.cancel();
    for (final link in _links.values) {
      await link.cancel();
    }
    _links.clear();
    _pending.clear();
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }
}
