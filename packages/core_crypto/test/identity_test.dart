import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';

String bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

List<int> hexToBytes(String hex) {
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}

/// Официальный вектор BIP-39 (источник: https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki,
/// тестовые векторы английского wordlist, passphrase "TREZOR").
const _bip39Mnemonic12 =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _bip39SeedHexTrezor =
    'c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04';

void main() {
  group('CryptoIdentity structure', () {
    test('userId = hex(Ed25519 public key), 64 hex chars', () async {
      final identity = await generateIdentity();
      final edPubHex = bytesToHex(
          (identity.ed25519PublicKey as SimplePublicKey).bytes);

      expect(identity.userId.value, equals(edPubHex));
      expect(identity.userId.value, hasLength(64));
    });

    test('peerId.publicKey = 32 байта, совпадает с Ed25519 public key', () async {
      final identity = await generateIdentity();
      final edPubBytes = (identity.ed25519PublicKey as SimplePublicKey).bytes;

      expect(identity.peerId.publicKey, hasLength(32));
      expect(identity.peerId.publicKey, equals(edPubBytes));
    });

    test('X25519 public key = 32 байта', () async {
      final identity = await generateIdentity();
      final xPubBytes = (identity.x25519PublicKey as SimplePublicKey).bytes;

      expect(xPubBytes, hasLength(32));
    });

    test('generateIdentity и recover дают согласованные структуры',
        () async {
      final generated = await generateIdentity();
      final recovered = await recoverIdentityFromMnemonic(
        mnemonic: generateMnemonic(strength: 128),
      );

      expect(generated.userId, isA<UserId>());
      expect(recovered.userId, isA<UserId>());
      expect(generated.peerId, isA<PeerId>());
      expect(recovered.peerId, isA<PeerId>());
      expect(generated.ed25519PublicKey, isA<PublicKey>());
      expect(recovered.ed25519PublicKey, isA<PublicKey>());
      expect(generated.x25519PublicKey, isA<PublicKey>());
      expect(recovered.x25519PublicKey, isA<PublicKey>());
      expect(generated.x25519BindingSignature, isNotNull);
      expect(recovered.x25519BindingSignature, isNotNull);
    });
  });

  group('CryptoIdentity mnemonic recovery', () {
    test('одна мнемоника → те же ключи (детерминизм)', () async {
      const mnemonic = _bip39Mnemonic12;

      final id1 = await recoverIdentityFromMnemonic(mnemonic: mnemonic);
      final id2 = await recoverIdentityFromMnemonic(mnemonic: mnemonic);

      final ed1 = (id1.ed25519PublicKey as SimplePublicKey).bytes;
      final ed2 = (id2.ed25519PublicKey as SimplePublicKey).bytes;
      final x1 = (id1.x25519PublicKey as SimplePublicKey).bytes;
      final x2 = (id2.x25519PublicKey as SimplePublicKey).bytes;

      expect(ed1, equals(ed2));
      expect(x1, equals(x2));
      expect(id1.userId.value, equals(id2.userId.value));
      expect(id1.peerId.publicKey, equals(id2.peerId.publicKey));
      expect(id1.mnemonic, equals(id2.mnemonic));
    });

    test('разные мнемоники → разные ключи', () async {
      final mnemonic1 = generateMnemonic(strength: 128);
      final mnemonic2 = generateMnemonic(strength: 128);

      final id1 = await recoverIdentityFromMnemonic(mnemonic: mnemonic1);
      final id2 = await recoverIdentityFromMnemonic(mnemonic: mnemonic2);

      final ed1 = (id1.ed25519PublicKey as SimplePublicKey).bytes;
      final ed2 = (id2.ed25519PublicKey as SimplePublicKey).bytes;

      expect(ed1, isNot(equals(ed2)));
      expect(id1.userId.value, isNot(equals(id2.userId.value)));
    });

    test('восстановленная identity подписывает и верифицирует', () async {
      const mnemonic = _bip39Mnemonic12;
      final identity = await recoverIdentityFromMnemonic(mnemonic: mnemonic);
      final signer = CryptoSigner(identity.ed25519PrivateKey);

      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final signature = await signer.sign(data);

      final valid = await signer.verify(data, signature, identity.peerId);
      expect(valid, isTrue);
    });

    test('восстановленная identity считает общий секрет X25519 с другой identity',
        () async {
      const mnemonicA = _bip39Mnemonic12;
      final mnemonicB = generateMnemonic(strength: 128);

      final identityA = await recoverIdentityFromMnemonic(mnemonic: mnemonicA);
      final identityB = await recoverIdentityFromMnemonic(mnemonic: mnemonicB);

      // Собираем KeyPair из приватных ключей для X25519 DH.
      final xAlgo = X25519();
      final aKeyPair = SimpleKeyPairData(
        await identityA.x25519PrivateKey.extractBytes(),
        publicKey: identityA.x25519PublicKey as SimplePublicKey,
        type: KeyPairType.x25519,
      );
      final bKeyPair = SimpleKeyPairData(
        await identityB.x25519PrivateKey.extractBytes(),
        publicKey: identityB.x25519PublicKey as SimplePublicKey,
        type: KeyPairType.x25519,
      );

      final secretA = await xAlgo.sharedSecretKey(
        keyPair: aKeyPair,
        remotePublicKey: identityB.x25519PublicKey,
      );
      final secretB = await xAlgo.sharedSecretKey(
        keyPair: bKeyPair,
        remotePublicKey: identityA.x25519PublicKey,
      );

      final bytesA = await secretA.extractBytes();
      final bytesB = await secretB.extractBytes();

      expect(bytesA, hasLength(32));
      expect(bytesB, hasLength(32));
      expect(bytesA, equals(bytesB));
    });
  });

  group('CryptoIdentity binding (X25519 подписан Ed25519)', () {
    test('verifyBinding возвращает true для корректного binding', () async {
      final identity = await generateIdentity();
      expect(await identity.verifyBinding(), isTrue);

      final recovered = await recoverIdentityFromMnemonic(
        mnemonic: generateMnemonic(strength: 128),
      );
      expect(await recovered.verifyBinding(), isTrue);
    });

    test('подмена X25519 ключа делает binding неверным', () async {
      final identity = await generateIdentity();

      // Создаём подмену: тот же Ed25519 ключ, другой X25519 ключ,
      // но старая binding-подпись.
      final tampered = CryptoIdentity(
        peerId: identity.peerId,
        userId: identity.userId,
        ed25519PublicKey: identity.ed25519PublicKey,
        ed25519PrivateKey: identity.ed25519PrivateKey,
        x25519PublicKey: SimplePublicKey(
          Uint8List.fromList(List<int>.filled(32, 0xab)),
          type: KeyPairType.x25519,
        ),
        x25519PrivateKey: SecretKey(Uint8List.fromList(List<int>.filled(32, 0xab))),
        x25519BindingSignature: identity.x25519BindingSignature,
        mnemonic: identity.mnemonic,
      );

      expect(await tampered.verifyBinding(), isFalse);
    });

    test('verifyBinding возвращает false при отсутствии подписи', () async {
      final identity = CryptoIdentity(
        peerId: PeerId(Uint8List.fromList(List<int>.filled(32, 0))),
        userId: UserId('test'),
        ed25519PublicKey: SimplePublicKey(
          Uint8List.fromList(List<int>.filled(32, 0)),
          type: KeyPairType.ed25519,
        ),
        ed25519PrivateKey: SecretKey(Uint8List.fromList(List<int>.filled(32, 0))),
        x25519PublicKey: SimplePublicKey(
          Uint8List.fromList(List<int>.filled(32, 0)),
          type: KeyPairType.x25519,
        ),
        x25519PrivateKey: SecretKey(Uint8List.fromList(List<int>.filled(32, 0))),
        x25519BindingSignature: null,
      );

      expect(await identity.verifyBinding(), isFalse);
    });
  });

  group('BIP-39 тестовые векторы', () {
    test('mnemonicToSeed совпадает с официальным вектором (abandon×11+about, TREZOR)',
        () async {
      // Источник: BIP-39 spec, тестовый вектор English wordlist,
      // passphrase "TREZOR" — https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki
      final seed = await Bip39.mnemonicToSeed(
        _bip39Mnemonic12,
        passphrase: 'TREZOR',
      );

      expect(bytesToHex(seed), equals(_bip39SeedHexTrezor));
    });

    test('BIP-39 seed без passphrase детерминистичен', () async {
      const mnemonic = _bip39Mnemonic12;

      final seed1 = await Bip39.mnemonicToSeed(mnemonic);
      final seed2 = await Bip39.mnemonicToSeed(mnemonic);

      expect(seed1, equals(seed2));
      expect(seed1, hasLength(64)); // 512 бит
    });

    test('разные passphrase дают разные seed', () async {
      const mnemonic = _bip39Mnemonic12;

      final seed1 = await Bip39.mnemonicToSeed(mnemonic, passphrase: '');
      final seed2 = await Bip39.mnemonicToSeed(mnemonic, passphrase: 'TREZOR');

      expect(seed1, isNot(equals(seed2)));
    });
  });

  group('BIP-39 валидация', () {
    const valid12 = _bip39Mnemonic12;
    const valid24 =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art';

    test('принимает корректную 12-словную мнемонику', () {
      expect(isValidMnemonic(valid12), isTrue);
    });

    test('принимает корректную 24-словную мнемонику', () {
      expect(isValidMnemonic(valid24), isTrue);
    });

    test('отклоняет неизвестное слово', () {
      expect(
        isValidMnemonic('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon unknownword'),
        isFalse,
      );
    });

    test('отклоняет неверную длину (не кратно 3)', () {
      expect(isValidMnemonic('abandon abandon'), isFalse);
      expect(isValidMnemonic('abandon abandon abandon abandon'), isFalse);
    });

    test('отклоняет неверную контрольную сумму', () {
      // Меняем последнее слово — нарушается контрольная сумма.
      expect(
        isValidMnemonic(
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon',
        ),
        isFalse,
      );
    });

    test('нормализует пробелы и регистр', () {
      final withExtraSpaces = '  $_bip39Mnemonic12  ';
      final mixedCase = _bip39Mnemonic12.toUpperCase();

      // isValidMnemonic trim'ит и split'ит по \s+, поэтому лишние пробелы ок.
      expect(isValidMnemonic(withExtraSpaces), isTrue);
      // Регистр важен: wordlist в нижнем регистре, uppercase слова не найдутся.
      expect(isValidMnemonic(mixedCase), isFalse);
    });

    test('отклоняет пустую строку', () {
      expect(isValidMnemonic(''), isFalse);
    });
  });

  group('CryptoIdentity toString не раскрывает секреты', () {
    test('toString не содержит приватных ключей и мнемоники', () async {
      final identity = await recoverIdentityFromMnemonic(
        mnemonic: _bip39Mnemonic12,
      );

      final edPrivBytes = await identity.ed25519PrivateKey.extractBytes();
      final xPrivBytes = await identity.x25519PrivateKey.extractBytes();
      final mnemonic = identity.mnemonic!;

      final str = identity.toString();

      expect(str, isNot(contains(bytesToHex(edPrivBytes))));
      expect(str, isNot(contains(bytesToHex(xPrivBytes))));
      expect(str, isNot(contains(mnemonic)));
      expect(str, isNot(contains('SecretKey')));
    });

    test('toString содержит только публичную информацию', () async {
      final identity = await generateIdentity();
      final str = identity.toString();

      expect(str, contains(identity.userId.value));
      expect(str, contains(bytesToHex((identity.ed25519PublicKey as SimplePublicKey).bytes)));
    });
  });
}