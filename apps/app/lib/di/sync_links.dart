import 'dart:async';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_relay/core_relay.dart';
import 'package:core_sync/core_sync.dart';

/// Какой транспорт сейчас обслуживает sync-линк пира.
enum SyncLinkMode { direct, relay }

/// [SyncPacketTransport] поверх [RelayTransport].
///
/// Отправка идёт тем же путём, что и остальной relay-трафик: сначала прямое
/// соединение, затем релейный fallback. Входящие кадры уже прошли проверку
/// подписи origin в [RelayTransport].
class RelayPacketTransport implements SyncPacketTransport {
  RelayPacketTransport({required this.relay});

  final RelayTransport relay;

  @override
  Stream<SyncPacket> get incoming => relay.incoming.map(
    (frame) => SyncPacket(
      src: hexEncode(frame.src.publicKey),
      payload: Uint8List.fromList(frame.payload),
    ),
  );

  @override
  Future<void> send(String dst, Uint8List bytes) {
    final raw = hexDecode(dst);
    if (raw == null || raw.length != 32) {
      return Future<void>.error(
        ArgumentError.value(dst, 'dst', 'invalid peer id'),
      );
    }
    return relay.send(PeerId(raw), bytes);
  }
}

/// Держит по одному sync-линку на пира и переключает direct ↔ relay.
///
/// Линки сеются из presence-топологии, а затем обновляются по событиям
/// прямого транспорта и входящим relay-кадрам. Владение [RelayTransport] и
/// его `direct` остаётся у вызывающего: [close] отцепляет и закрывает только
/// созданные здесь линки.
class SyncLinkConnector {
  SyncLinkConnector({
    required this.transport,
    required this.attach,
    required this.detach,
  });

  final RelayTransport transport;
  final Future<void> Function(SyncLink link) attach;
  final Future<void> Function(String peerId) detach;

  final Map<String, SyncLink> _links = <String, SyncLink>{};
  final Map<String, SyncLinkMode> _modes = <String, SyncLinkMode>{};

  // ignore: cancel_subscriptions
  StreamSubscription<PeerLinkEvent>? _events;
  // ignore: cancel_subscriptions
  StreamSubscription<RelayInbound>? _incoming;
  Future<void> _tail = Future<void>.value();
  bool _started = false;
  bool _closed = false;

  SyncLinkMode? modeOf(PeerId peerId) => _modes[hexEncode(peerId.publicKey)];

  Future<void> start() {
    return _serialize(_start);
  }

  Future<void> _start() async {
    if (_started || _closed) return;
    _started = true;
    _events = transport.events.listen(
      (event) => unawaited(_serialize(() => _onEvent(event))),
      onError: (Object _) {},
    );
    _incoming = transport.incoming.listen(
      (frame) => unawaited(_serialize(() => _ensure(frame.src))),
      onError: (Object _) {},
    );

    for (final peer in _sorted(transport.topology.knownPeerIds)) {
      await _ensure(peer);
    }
    for (final peer in _sorted(transport.topology.localNeighbors)) {
      await _ensureDirect(peer);
    }
  }

  Future<void> _onEvent(PeerLinkEvent event) async {
    if (_closed) return;
    final peer = event.peerId;
    if (peer == null || peer == transport.localPeerId) return;
    switch (event.type) {
      case 'connected':
        await _ensureDirect(peer);
      case 'disconnected':
      case 'error':
        await _ensureRelay(peer);
    }
  }

  Future<void> _ensure(PeerId peer) {
    if (peer == transport.localPeerId) return Future<void>.value();
    if (transport.topology.localNeighbors.contains(peer)) {
      return _ensureDirect(peer);
    }
    return _ensureRelay(peer);
  }

  Future<void> _ensureDirect(PeerId peer) async {
    if (_closed || peer == transport.localPeerId) return;
    final id = hexEncode(peer.publicKey);
    if (_modes[id] == SyncLinkMode.direct) return;
    if (_links.containsKey(id)) {
      await _drop(id);
    }
    PeerLinkSyncLink? syncLink;
    try {
      final link = await transport.connect(peer);
      if (_closed) {
        await link.close();
        return;
      }
      syncLink = PeerLinkSyncLink(link);
      await attach(syncLink);
      if (_closed) {
        await detach(id);
        await syncLink.close();
        return;
      }
      _links[id] = syncLink;
      _modes[id] = SyncLinkMode.direct;
    } catch (_) {
      await syncLink?.close();
      if (!_closed) {
        await _ensureRelay(peer);
      }
    }
  }

  Future<void> _ensureRelay(PeerId peer) async {
    if (_closed || peer == transport.localPeerId) return;
    final id = hexEncode(peer.publicKey);
    if (_modes[id] == SyncLinkMode.relay) return;
    if (_links.containsKey(id)) {
      await _drop(id);
    }
    final syncLink = PacketSyncLink(
      transport: RelayPacketTransport(relay: transport),
      peerId: id,
    );
    try {
      await attach(syncLink);
      if (_closed) {
        await detach(id);
        await syncLink.close();
        return;
      }
      _links[id] = syncLink;
      _modes[id] = SyncLinkMode.relay;
    } catch (_) {
      await syncLink.close();
      rethrow;
    }
  }

  Future<void> _drop(String peerId) async {
    final link = _links.remove(peerId);
    _modes.remove(peerId);
    if (link == null) return;
    try {
      await detach(peerId);
    } finally {
      await link.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final events = _events;
    final incoming = _incoming;
    _events = null;
    _incoming = null;
    await events?.cancel();
    await incoming?.cancel();
    await _serialize(() async {
      for (final peerId in _links.keys.toList()) {
        await _drop(peerId);
      }
    });
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  List<PeerId> _sorted(Iterable<PeerId> peers) {
    return peers.toList()..sort(
      (a, b) => hexEncode(a.publicKey).compareTo(hexEncode(b.publicKey)),
    );
  }
}
