import 'package:core_crypto/core_crypto.dart';
import 'package:core_signaling/core_signaling.dart';
import 'package:test/test.dart';

void main() {
  test('presence hello carries an optional E2E key bundle', () async {
    final bundle = await X3DH().generateKeyBundle();
    final capabilities = NodeCapabilities(e2eBundle: bundle.toPublicBundle());

    final encoded = SecureSignalingCodec.encodeHello(capabilities);
    final decoded = SecureSignalingCodec.decodeHello(encoded);

    expect(decoded, isNotNull);
    expect(decoded!.e2eBundle, isNotNull);
    const codec = X3dhBundleCodec();
    expect(
      codec.encode(decoded.e2eBundle!),
      orderedEquals(codec.encode(bundle.toPublicBundle())),
    );
  });

  test('legacy presence without a bundle still decodes', () {
    final encoded = SecureSignalingCodec.encodeHello(
      const NodeCapabilities(canRelay: true),
    );
    final decoded = SecureSignalingCodec.decodeHello(encoded);
    expect(decoded, isNotNull);
    expect(decoded!.canRelay, isTrue);
    expect(decoded.e2eBundle, isNull);
  });
}
