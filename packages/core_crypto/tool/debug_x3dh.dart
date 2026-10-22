import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:core_crypto/core_crypto.dart';

List<int> hexToBytes(String hex) {
  return List<int>.generate(hex.length ~/ 2, (i) => int.parse(hex.substring(i*2, i*2+2), radix: 16));
}
String bytesToHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2,'0')).join('');

void main() async {
  final x3dh = X3DH();
  final aliceBundle = await x3dh.generateKeyBundle();
  final bobBundle = await x3dh.generateKeyBundle();

  final senderResult = await x3dh.sender(remoteBundle: bobBundle.toPublicBundle());
  final senderShared = (senderResult as Ok<X3DHSenderResult, CryptoError>).value;
  final senderBytes = await senderShared.sharedKey.extractBytes();
  print('sender SK: ${bytesToHex(senderBytes)}');

  // Alice's independent computation
  final aliceIkPriv = await aliceBundle.identityPrivateKey.extractBytes();
  final aliceSpkPriv = await aliceBundle.signedPrekeyPrivateKey.extractBytes();

  final aliceIkPair = SimpleKeyPairData(aliceIkPriv, publicKey: aliceBundle.identityKey as SimplePublicKey, type: KeyPairType.x25519);
  final aliceSpkPair = SimpleKeyPairData(aliceSpkPriv, publicKey: aliceBundle.signedPrekey as SimplePublicKey, type: KeyPairType.x25519);

  final x25519 = X25519();
  final dh2 = await x25519.sharedSecretKey(keyPair: aliceIkPair, remotePublicKey: senderShared.ephemeralPublicKey);
  final dh3 = await x25519.sharedSecretKey(keyPair: aliceSpkPair, remotePublicKey: senderShared.ephemeralPublicKey);
  final dh2Bytes = Uint8List.fromList(await dh2.extractBytes());
  final dh3Bytes = Uint8List.fromList(await dh3.extractBytes());

  print('Alice IK DH2: ${bytesToHex(dh2Bytes)}');
  print('Alice SPK DH3: ${bytesToHex(dh3Bytes)}');

  // Now Bob's side - we can't get ephemeral priv, but let's verify via receiver
  final receiverShared = await x3dh.receiver(bundle: aliceBundle, senderEphemeralPublicKey: senderShared.ephemeralPublicKey);
  final receiverBytes = await receiverShared.extractBytes();
  print('receiver SK: ${bytesToHex(receiverBytes)}');

  // HKDF from Alice's side
  final combined = Uint8List.fromList([...dh2Bytes, ...dh3Bytes]);
  final hkdf = GroupHkdf();
  const info = 'opensink/x3dh/shared-key';
  final indepSk = await hkdf.derive(secret: SecretKey(combined), salt: Uint8List(32), info: Uint8List.fromList(utf8.encode(info)), outputLength: 32);
  final indepBytes = await indepSk.extractBytes();
  print('independent SK: ${bytesToHex(indepBytes)}');
  print('match sender: ${bytesToHex(senderBytes) == bytesToHex(indepBytes)}');
  print('match receiver: ${bytesToHex(receiverBytes) == bytesToHex(indepBytes)}');
}
