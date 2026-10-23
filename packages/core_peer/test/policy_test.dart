import 'package:core_domain/core_domain.dart';
import 'package:core_peer/core_peer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_helpers.dart';

void main() {
  group('StaticPeerPriorityPolicy', () {
    final active = peerId(10);
    final voice = peerId(20);
    final idle = peerId(30);

    test('returns configured priorities and protection', () {
      final policy = StaticPeerPriorityPolicy(
        protectedPeers: <PeerId>{voice},
        priorities: <PeerId, int>{active: 10, voice: 5},
      );

      expect(policy.isProtected(voice), isTrue);
      expect(policy.isProtected(active), isFalse);
      expect(policy.priorityOf(active), 10);
      expect(policy.priorityOf(voice), 5);
      expect(policy.priorityOf(idle), 0);
    });

    test('replace updates priorities and protected set', () {
      final policy = StaticPeerPriorityPolicy(
        priorities: <PeerId, int>{active: 10},
      );

      policy.replace(
        protectedPeers: <PeerId>{active},
        priorities: <PeerId, int>{voice: 20},
      );

      expect(policy.isProtected(active), isTrue);
      expect(policy.priorityOf(active), 0);
      expect(policy.priorityOf(voice), 20);
    });
  });
}
