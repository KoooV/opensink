import 'package:test/test.dart';

import 'support/simulator.dart';

void main() {
  test(
    '1000 seeded runs: random order, loss and partitions converge',
    () async {
      for (var seed = 0; seed < 1000; seed++) {
        final sim = SyncSimulator(
          seed: seed,
          replicas: 3,
          priorityWindow: 4,
          maxBatchSize: 2,
        );
        try {
          await sim.setup();
          await sim.runChaos(rounds: 6);
          await sim.healAndConverge();
          await sim.verifyConvergence();
        } finally {
          await sim.close();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
