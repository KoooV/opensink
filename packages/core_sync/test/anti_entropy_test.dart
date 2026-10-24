import 'package:test/test.dart';

import 'support/simulator.dart';

void main() {
  group('anti-entropy', () {
    test('two replicas converge after a partition heals', () async {
      final sim = SyncSimulator(seed: 7, replicas: 2);
      await sim.setup();

      await sim.nodes[0].engine.postMessage(sim.groupId, sim.channelId, 'a');
      await sim.nodes[1].engine.postMessage(sim.groupId, sim.channelId, 'b');
      await sim.pump();
      await sim.verifyConvergence();

      sim.network.setPartition(0, 1, partitioned: true);
      final isolatedA = await sim.nodes[0].engine.postMessage(
        sim.groupId,
        sim.channelId,
        'c',
      );
      final isolatedB = await sim.nodes[1].engine.postMessage(
        sim.groupId,
        sim.channelId,
        'd',
      );
      expect(isolatedA.isOk, isTrue);
      expect(isolatedB.isOk, isTrue);
      await sim.pump();

      final left = (await sim.nodes[0].engine.allEvents(sim.groupId))
          .map((event) => event.id.value)
          .toSet();
      final right = (await sim.nodes[1].engine.allEvents(sim.groupId))
          .map((event) => event.id.value)
          .toSet();
      expect(left.difference(right), isNotEmpty);
      expect(right.difference(left), isNotEmpty);

      await sim.healAndConverge();
      await sim.verifyConvergence();
      await sim.close();
    });

    test('summaries detect missing ranges after packet loss', () async {
      final sim = SyncSimulator(seed: 11, replicas: 2);
      await sim.setup();

      sim.network.loss = 1.0;
      for (var i = 0; i < 20; i++) {
        final result = await sim.nodes[0].engine.postMessage(
          sim.groupId,
          sim.channelId,
          'x$i',
        );
        expect(result.isOk, isTrue);
      }
      await sim.pump();
      expect(sim.nodes[1].store.length, lessThan(sim.nodes[0].store.length));

      sim.network.loss = 0;
      await sim.healAndConverge();
      await sim.verifyConvergence();
      await sim.close();
    });
  });
}
