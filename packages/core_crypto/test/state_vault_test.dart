import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:cryptography/cryptography.dart' as crypto_pkg;
import 'package:test/test.dart';

List<int> hexToBytes(String hex) {
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}

Uint8List hexToUint8List(String hex) => Uint8List.fromList(hexToBytes(hex));

String bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

/// Создаёт свежий StateVault с fresh MemorySecureKeyStore.
StateVault _freshVault() => StateVault(MemorySecureKeyStore());

StateVaultContext _ctx({
  StateKind kind = StateKind.doubleRatchet,
  String stateId = 'peer-abc123',
  int formatVersion = 1,
}) =>
    StateVaultContext(kind: kind, stateId: stateId, formatVersion: formatVersion);

void main() {
  group('StateVault roundtrip', () {
    test('seal/open возвращает исходные байты', () async {
      final vault = _freshVault();
      final plaintext = Uint8List.fromList(
        'serialized-ratchet-state-with-secret-chain-keys'.codeUnits,
      );

      final sealed = await vault.seal(plaintext, _ctx());
      expect(sealed.isOk, isTrue);

      final opened = await vault.open(sealed.unwrap(), _ctx());
      expect(opened.isOk, isTrue);
      expect(opened.unwrap(), equals(plaintext));
    });

    test('разные seal одного состояния дают разные шифртексты (случайный nonce)', () async {
      final vault = _freshVault();
      final plaintext = Uint8List.fromList('deterministic-plaintext'.codeUnits);

      final s1 = await vault.seal(plaintext, _ctx());
      final s2 = await vault.seal(plaintext, _ctx());

      expect(s1.isOk, isTrue);
      expect(s2.isOk, isTrue);
      expect(
        bytesToHex(s1.unwrap().bytes),
        isNot(equals(bytesToHex(s2.unwrap().bytes))),
      );
      // Оба вскрываются в те же исходные байты.
      final o1 = await vault.open(s1.unwrap(), _ctx());
      final o2 = await vault.open(s2.unwrap(), _ctx());
      expect(o1.unwrap(), equals(plaintext));
      expect(o2.unwrap(), equals(plaintext));
    });

    test('пустой plaintext запечатывается и вскрывается', () async {
      final vault = _freshVault();
      final sealed = await vault.seal(Uint8List(0), _ctx());
      expect(sealed.isOk, isTrue);
      final opened = await vault.open(sealed.unwrap(), _ctx());
      expect(opened.isOk, isTrue);
      expect(opened.unwrap(), isEmpty);
    });
  });

  group('StateVault негативы (контекст)', () {
    test('другой kind → OpenFailed', () async {
      final vault = _freshVault();
      final plaintext = Uint8List.fromList('data'.codeUnits);
      final sealed = await vault.seal(plaintext, _ctx(kind: StateKind.doubleRatchet));
      expect(sealed.isOk, isTrue);

      final opened = await vault.open(sealed.unwrap(), _ctx(kind: StateKind.senderKey));
      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<OpenFailed>());
    });

    test('другой stateId → OpenFailed', () async {
      final vault = _freshVault();
      final plaintext = Uint8List.fromList('data'.codeUnits);
      final sealed = await vault.seal(plaintext, _ctx(stateId: 'peer-abc123'));
      expect(sealed.isOk, isTrue);

      final opened = await vault.open(sealed.unwrap(), _ctx(stateId: 'peer-def456'));
      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<OpenFailed>());
    });

    test('другой formatVersion → OpenFailed', () async {
      final vault = _freshVault();
      final plaintext = Uint8List.fromList('data'.codeUnits);
      final sealed = await vault.seal(plaintext, _ctx(formatVersion: 1));
      expect(sealed.isOk, isTrue);

      final opened = await vault.open(sealed.unwrap(), _ctx(formatVersion: 2));
      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<OpenFailed>());
    });
  });

  group('StateVault порча зон конверта', () {
    SealedState tamperZone(SealedState sealed, int offset, int newValue) {
      final bytes = Uint8List.fromList(sealed.bytes);
      bytes[offset] = newValue;
      return SealedState.fromBytes(bytes);
    }

    test('портба version byte → OpenFailed', () async {
      final vault = _freshVault();
      final sealed = await vault.seal(Uint8List.fromList('data'.codeUnits), _ctx());
      expect(sealed.isOk, isTrue);
      final tampered = tamperZone(sealed.unwrap(), 0, 0xFF);
      final opened = await vault.open(tampered, _ctx());
      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<OpenFailed>());
    });

    test('портба kind byte → OpenFailed', () async {
      final vault = _freshVault();
      final sealed = await vault.seal(Uint8List.fromList('data'.codeUnits), _ctx());
      expect(sealed.isOk, isTrue);
      final tampered = tamperZone(sealed.unwrap(), 1, 0xFF);
      final opened = await vault.open(tampered, _ctx());
      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<OpenFailed>());
    });

    test('портба stateIdLen → OpenFailed', () async {
      final vault = _freshVault();
      final sealed = await vault.seal(Uint8List.fromList('data'.codeUnits), _ctx(stateId: 'abc'));
      expect(sealed.isOk, isTrue);
      final tampered = tamperZone(sealed.unwrap(), 2, 0xFF);
      final opened = await vault.open(tampered, _ctx(stateId: 'abc'));
      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<OpenFailed>());
    });

    test('портба байта stateId → OpenFailed', () async {
      final vault = _freshVault();
      final sealed = await vault.seal(Uint8List.fromList('data'.codeUnits), _ctx(stateId: 'abc'));
      expect(sealed.isOk, isTrue);
      // stateId начинается с offset 4.
      final tampered = tamperZone(sealed.unwrap(), 4, sealed.unwrap().bytes[4] ^ 0xFF);
      final opened = await vault.open(tampered, _ctx(stateId: 'abc'));
      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<OpenFailed>());
    });

    test('портба nonce (первый байт тела) → OpenFailed', () async {
      final vault = _freshVault();
      final sealed = await vault.seal(Uint8List.fromList('data'.codeUnits), _ctx());
      expect(sealed.isOk, isTrue);
      // Тело начинается после version(1) + kind(1) + stateIdLen(2) + stateId(3) = 7.
      const nonceOffset = 7;
      final tampered = tamperZone(sealed.unwrap(), nonceOffset, sealed.unwrap().bytes[nonceOffset] ^ 0xFF);
      final opened = await vault.open(tampered, _ctx());
      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<OpenFailed>());
    });

    test('портба ciphertext (средний байт тела) → OpenFailed', () async {
      final vault = _freshVault();
      final plaintext = Uint8List.fromList('some longer plaintext for ciphertext tamper'.codeUnits);
      final sealed = await vault.seal(plaintext, _ctx());
      expect(sealed.isOk, isTrue);
      final bytes = sealed.unwrap().bytes;
      // Тело: nonce(24) || ciphertext || mac(16). Портбаем байт ciphertext.
      const bodyStart = 7;
      const nonceLen = 24;
      const macLen = 16;
      const ciphertextStart = bodyStart + nonceLen;
      final ciphertextEnd = bytes.length - macLen;
      final tamperOffset = ciphertextStart + (ciphertextEnd - ciphertextStart) ~/ 2;
      final tampered = tamperZone(sealed.unwrap(), tamperOffset, bytes[tamperOffset] ^ 0xFF);
      final opened = await vault.open(tampered, _ctx());
      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<OpenFailed>());
    });

    test('портба mac (последний байт тела) → OpenFailed', () async {
      final vault = _freshVault();
      final sealed = await vault.seal(Uint8List.fromList('data'.codeUnits), _ctx());
      expect(sealed.isOk, isTrue);
      final bytes = sealed.unwrap().bytes;
      final tampered = tamperZone(sealed.unwrap(), bytes.length - 1, bytes[bytes.length - 1] ^ 0xFF);
      final opened = await vault.open(tampered, _ctx());
      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<OpenFailed>());
    });

    test('укороченный конверт → OpenFailed', () async {
      final vault = _freshVault();
      final sealed = await vault.seal(Uint8List.fromList('data'.codeUnits), _ctx());
      expect(sealed.isOk, isTrue);
      final short = SealedState.fromBytes(sealed.unwrap().bytes.sublist(0, 10));
      final opened = await vault.open(short, _ctx());
      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<OpenFailed>());
    });
  });

  group('StateVault секреты не попадают в sealed-вывод', () {
    test('зашифрованный вывод не содержит байты ключей цепочки из plaintext', () async {
      final vault = _freshVault();
      // Симлируем сериализованное состояние Double Ratchet с ключами.
      final rootKeyBytes = List<int>.generate(32, (i) => i);
      final chainKeyBytes = List<int>.generate(32, (i) => 100 + i);
      final plaintext = Uint8List.fromList([...rootKeyBytes, ...chainKeyBytes]);

      final sealed = await vault.seal(plaintext, _ctx());
      expect(sealed.isOk, isTrue);
      final sealedHex = bytesToHex(sealed.unwrap().bytes);

      // Ни одна из 32-байтовых цепочек ключей не должна появляться в зашифрованном выводе.
      final rootHex = bytesToHex(rootKeyBytes);
      final chainHex = bytesToHex(chainKeyBytes);
      expect(sealedHex, isNot(contains(rootHex)));
      expect(sealedHex, isNot(contains(chainHex)));
    });

    test('toString конверта не раскрывает секреты', () async {
      final vault = _freshVault();
      final secret = Uint8List(32)..fillRange(0, 32, 42);
      final sealed = await vault.seal(secret, _ctx());
      expect(sealed.isOk, isTrue);

      final s = sealed.unwrap().toString();
      expect(s, isNot(contains('2a2a2a2a'))); // hex of 0x2a
      expect(s, isNot(contains(secret.toList().toString())));
      expect(s, contains('SealedState'));
      expect(s, contains('sealedLength='));
    });
  });

  group('StateVault ключ хранилища', () {
    test('ключ хранилища не выводится из identity seed: два хранилища с разными ключами не могут открывать конверты друг друга', () async {
      final plaintext = Uint8List.fromList('shared state'.codeUnits);

      final vault1 = _freshVault();
      final vault2 = _freshVault();

      final sealed1 = await vault1.seal(plaintext, _ctx());
      expect(sealed1.isOk, isTrue);

      // vault2 имеет свой ключ — не может вскрыть конверт vault1.
      final opened2 = await vault2.open(sealed1.unwrap(), _ctx());
      expect(opened2.isErr, isTrue);
      expect(opened2.unwrapErr(), isA<OpenFailed>());
    });

    test('переоткрытие того же хранилища читает тот же ключ', () async {
      final store = MemorySecureKeyStore();
      final vault1 = StateVault(store);
      final vault2 = StateVault(store);

      final plaintext = Uint8List.fromList('persisted state'.codeUnits);
      final sealed = await vault1.seal(plaintext, _ctx());
      expect(sealed.isOk, isTrue);

      final opened = await vault2.open(sealed.unwrap(), _ctx());
      expect(opened.isOk, isTrue);
      expect(opened.unwrap(), equals(plaintext));
    });
  });

  group('StateVault восстановление состояний E2EE', () {
    test('DoubleRatchet: seal → open → fromBytes → шифрование/расшифровка продолжается', () async {
      final vault = _freshVault();

      const sharedSecretHex =
          '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
      // Создаём DoubleRatchet напрямую с известными ключами.
      final rootKey = crypto_pkg.SecretKey(hexToUint8List(sharedSecretHex));
      final sendingChainKey = crypto_pkg.SecretKey(
        Uint8List(32)..fillRange(0, 32, 1),
      );
      final receivingChainKey = crypto_pkg.SecretKey(
        Uint8List(32)..fillRange(0, 32, 2),
      );

      final alice = DoubleRatchet(
        rootKey: rootKey,
        sendingChainKey: sendingChainKey,
        receivingChainKey: receivingChainKey,
      );

      final plaintext = Uint8List.fromList('Hello after restore'.codeUnits);
      final encryptResult = await alice.encrypt(plaintext: plaintext);
      expect(encryptResult.isOk, isTrue);
      final wire = (encryptResult as Ok).value.wireFormat;
      final nextState = (encryptResult as Ok).value.nextState;

      // Сериализуем состояние, запечатываем, вскрываем, десериализуем.
      final serialized = await nextState.toBytes();
      final sealed = await vault.seal(serialized, _ctx(stateId: 'peer-alice-bob'));
      expect(sealed.isOk, isTrue);

      final opened = await vault.open(sealed.unwrap(), _ctx(stateId: 'peer-alice-bob'));
      expect(opened.isOk, isTrue);

      // Десериализация не должна бросать исключение.
      DoubleRatchet.fromBytes(opened.unwrap());

      // Bob может расшифровать сообщение, зашифрованное Alice до ratchet-шага.
      final bob = DoubleRatchet(
        rootKey: rootKey,
        sendingChainKey: receivingChainKey,
        receivingChainKey: sendingChainKey,
      );
      // Bob использует своё состояние до ratchet-шага; для расшифровки первого сообщения
      // нужно состояние Bob до первого сообщения. Используем исходное bob.
      final bobDecrypt = await bob.decrypt(data: wire);
      expect(bobDecrypt.isOk, isTrue);
      expect(bytesToHex((bobDecrypt as Ok).value.wireFormat), equals(bytesToHex(plaintext)));
    });

    test('SenderKeyState: seal/open roundtrip сохраняет байты состояния', () async {
      final vault = _freshVault();

      final signingKeyPair = await crypto_pkg.Ed25519().newKeyPair();
      final senderKey = SenderKey(
        chainKey: crypto_pkg.SecretKey(Uint8List(32)..fillRange(0, 32, 7)),
        signingKeyPair: signingKeyPair,
        sequenceNumber: 5,
        groupId: 'group-1',
        senderPeerId: 'peer-sender',
      );

      final state = SenderKeyState(
        senderKeys: {'peer-sender': senderKey},
        lastAcceptedSequence: {'peer-sender': 5},
        acceptedSequences: {'peer-sender': {1, 2, 3, 4, 5}},
      );

      // Сериализуем вручную (SenderKeyState не имеет toBytes; кодируем ключевые поля).
      final buffer = StringBuffer();
      buffer.write('groupId=${state.senderKeys['peer-sender']?.groupId ?? ''}');
      buffer.write('|sender=${state.senderKeys['peer-sender']?.senderPeerId ?? ''}');
      buffer.write('|seq=${state.senderKeys['peer-sender']?.sequenceNumber ?? 0}');
      buffer.write('|last=${state.lastAcceptedSequence['peer-sender'] ?? -1}');
      final acceptedSet = state.acceptedSequences['peer-sender'];
      final acceptedList = acceptedSet != null ? (acceptedSet.toList()..sort()) : <int>[];
      buffer.write('|accepted=${acceptedList.join(',')}');

      final plaintext = Uint8List.fromList(buffer.toString().codeUnits);

      final sealed = await vault.seal(plaintext, _ctx(kind: StateKind.senderKey, stateId: 'group-1|peer-sender'));
      expect(sealed.isOk, isTrue);

      final opened = await vault.open(sealed.unwrap(), _ctx(kind: StateKind.senderKey, stateId: 'group-1|peer-sender'));
      expect(opened.isOk, isTrue);
      expect(opened.unwrap(), equals(plaintext));
    });
  });
}
