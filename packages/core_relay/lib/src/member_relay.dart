import 'package:core_domain/core_domain.dart' as domain;

import 'relay_topology.dart';
import 'relay_transport.dart';

/// Адаптер [RelayTransport] к доменному порту [domain.Relay].
///
/// Контракт origin-only: [domain.RelayFrame.src] обязан совпадать с
/// `localPeerId`. Чужой origin не переподписывается локальным ключом, ошибки
/// отправки пробрасываются вызывающему.
class MemberRelay implements domain.Relay {
  MemberRelay({required this.transport, required this.topology});

  final RelayTransport transport;
  final RelayTopology topology;

  @override
  bool routes(domain.PeerId dst) =>
      topology.routes(transport.localPeerId, dst);

  @override
  Future<void> forward(domain.RelayFrame frame) async {
    if (frame.src != transport.localPeerId) {
      throw StateError('relay frame origin is not local');
    }
    await transport.send(frame.dst, frame.payload);
  }

  @override
  int get capacity => transport.config.perSourceBytesPerSecond;

  @override
  Future<void> close() => transport.close();
}
