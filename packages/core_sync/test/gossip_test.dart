import 'package:test/test.dart';

import 'support/simulator.dart';

void main() {
  group('gossip', () {
    test('new event reaches all neighbors and is not amplified', () async {
      final sim = SyncSimulator(seed: 21, replicas: 4);
      await sim.setup();
      sim.network.sent = 0;
      sim.network.dropped = 0;

      final created = await sim.nodes[0].engine.postMessage(
        sim.groupId,
        sim.channelId,
        'gossip',
      );
      expect(created.isOk, isTrue);
      await sim.pump();
      await sim.verifyConvergence();

      for (final node in sim.nodes) {
        expect(node.store.length, sim.nodes[0].store.length);
      }
      // Дедупликация не даёт экспоненциального шторма.
      expect(
        sim.network.sent,
        lessThanOrEqualTo(sim.replicas * sim.replicas * 2),
      );
      await sim.close();
    });

    test('duplicate gossip does not create duplicate events', () async {
      final sim = SyncSimulator(seed: 22, replicas: 3);
      await sim.setup();
      final created = await sim.nodes[0].engine.postMessage(
        sim.groupId,
        sim.channelId,
        'once',
      );
      await sim.pump();
      final before = sim.nodes[1].store.length;
      await sim.nodes[0].engine.runAntiEntropy();
      await sim.pump();
      expect(sim.nodes[1].store.length, before);
      expect(
        (await sim.nodes[1].engine.eventById(created.unwrap().id.value)),
        isNotNull,
      );
      await sim.close();
    });
  });
}
