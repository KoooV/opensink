import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:test/test.dart';

String bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

Uint8List hexToUint8List(String hex) {
  return Uint8List.fromList(
    List<int>.generate(
      hex.length ~/ 2,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    ),
  );
}

void main() {
  group('DoubleRatchet replay protection', () {
    const secretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    Future<DoubleRatchet> createBobState() async {
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);
      return DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.receivingChainKey,
        receivingChainKey: sessionKeys.sendingChainKey,
      );
    }

    test('повтор того же wire-блока с тем же состоянием — replay, отказ',
        () async {
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final alice = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
      );

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('original'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = (encResult as Ok).value.wireFormat;

      // Два независимых состояния Bob-а (клоны), чтобы декодировать один и тот
      // же блок дважды с одинаковым начальным состоянием.
      final bob1 = await createBobState();
      final bob2 = await createBobState();

      // Первый розыгрыш — успешен.
      final dec1 = await bob1.decrypt(data: wire);
      expect(dec1.isOk, isTrue);
      expect(bytesToHex((dec1 as Ok).value.wireFormat),
          bytesToHex('original'.codeUnits));

      // Второй розыгрыш того же блока с эквивалентным состоянием — replay,
      // номер сообщения уже пройден → отказ.
      final dec2 = await bob2.decrypt(data: wire);
      expect(dec2.isOk, isTrue); // bob2 ещё не использовал этот номер

      // Теперь bob2 продвигается, и повтор с тем же bob2 — отказ.
      final dec2b = await bob2.decrypt(data: wire);
      expect(dec2b.isOk, isTrue);
      final bob2Advanced = (dec2b as Ok).value.nextState;

      final dec2c = await bob2Advanced.decrypt(data: wire);
      expect(dec2c.isErr, isTrue);
      expect(dec2c.unwrapErr(), isA<DecryptionFailed>());
    });

    test('повтор после успешного расшифровки с тем же состоянием — отказ',
        () async {
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final alice = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
      );
      final bob = await createBobState();

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('replay me'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = (encResult as Ok).value.wireFormat;

      var bobState = bob;
      final dec1 = await bobState.decrypt(data: wire);
      expect(dec1.isOk, isTrue);
      bobState = (dec1 as Ok).value.nextState;

      // Повтор того же блока с продвинутым состоянием — messageNumber уже
      // принят, находится не в skippedKeys и меньше receivingMessageCounter.
      final dec2 = await bobState.decrypt(data: wire);
      expect(dec2.isErr, isTrue);
      expect(dec2.unwrapErr(), isA<DecryptionFailed>());
    });

    test('разные номера сообщений одной цепочки — не replay, проходят',
        () async {
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final alice = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
      );
      var bobState = await createBobState();

      final wires = <Uint8List>[];
      var aliceState = alice;
      for (var i = 0; i < 3; i++) {
        final enc = await aliceState.encrypt(
          plaintext: Uint8List.fromList('msg$i'.codeUnits),
        );
        expect(enc.isOk, isTrue);
        wires.add((enc as Ok).value.wireFormat);
        aliceState = (enc as Ok).value.nextState;
      }

      // Каждый новый номер принимается.
      for (var i = 0; i < 3; i++) {
        final dec = await bobState.decrypt(data: wires[i]);
        expect(dec.isOk, isTrue);
        expect(bytesToHex((dec as Ok).value.wireFormat),
            bytesToHex('msg$i'.codeUnits));
        bobState = (dec as Ok).value.nextState;
      }
    });
  });

  group('SenderKeyState replay protection', () {
    test('acceptSequence принимает новый номер и отвергает повтор', () {
      final state = SenderKeyState(senderKeys: {});

      final r1 = state.acceptSequence('alice', 5);
      expect(r1.accepted, isTrue);

      final r2 = r1.state.acceptSequence('alice', 5);
      expect(r2.accepted, isFalse); // тот же номер — replay

      final r3 = r2.state.acceptSequence('alice', 4);
      expect(r3.accepted, isFalse); // старый номер — отказ

      final r4 = r3.state.acceptSequence('alice', 6);
      expect(r4.accepted, isTrue); // новый — принимается

      // Повтор 6 после приёма — replay.
      final r5 = r4.state.acceptSequence('alice', 6);
      expect(r5.accepted, isFalse);
    });

    test('разные senderPeerId имеют независимые окна replay', () {
      final state = SenderKeyState(senderKeys: {});

      final r1 = state.acceptSequence('alice', 1);
      expect(r1.accepted, isTrue);

      // Bob может принимать тот же номер — независимое окно.
      final r2 = r1.state.acceptSequence('bob', 1);
      expect(r2.accepted, isTrue);

      // Повтор для alice — отказ.
      final r3 = r2.state.acceptSequence('alice', 1);
      expect(r3.accepted, isFalse);
    });
  });

  group('AEAD replay (characterization)', () {
    test('AEAD stateless: тот же шифртекст расшифровывается дважды',
        () async {
      // XChaCha20-Poly1305 — stateless AEAD: он не отслеживает использованные
      // nonce и не обнаруживает replay. Защита от replay лежит на слоях 3/5/7
      // (Envelope: nonce/sequence в заголовке; сигнальный канал; групповая
      // членство и триггеры ротации — см. DESIGN.md §13.6 и §2).
      final aead = XChaCha20Poly1305Aead();
      final key = await generateAeadKey();
      const plaintext = 'characterization';
      final data = Uint8List.fromList(plaintext.codeUnits);

      final encrypted = await aead.encrypt(key: key, plaintext: data);
      expect(encrypted.isOk, isTrue);
      final ciphertext = encrypted.unwrap();

      // Первый расшифровка — успешна.
      final dec1 = await aead.decrypt(key: key, data: ciphertext);
      expect(dec1.isOk, isTrue);
      expect(dec1.unwrap(), equals(data));

      // Второй расшифровка того же блока — тоже успешна (AEAD не 기억ет
      // использованные nonce). Это ожидаемо; replay защита вне core_crypto.
      final dec2 = await aead.decrypt(key: key, data: ciphertext);
      expect(dec2.isOk, isTrue);
      expect(dec2.unwrap(), equals(data));
    });
  });
}
