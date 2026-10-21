import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto_pkg;
import 'bip39_wordlist.dart';
import 'crypto_provider.dart';

/// BIP-39 mnemonic phrase utilities.
///
/// Implemented without the bip39 package to avoid an external dependency.
/// Uses the embedded English wordlist from bip39_wordlist.dart.
/// SHA-256 is implemented in pure Dart since package:cryptography v2.9.0
/// does not expose a synchronous hash API.
class Bip39 {
  Bip39._();

  static const int _entropyBitsPerWord = 11;
  static const int _pbkdf2Iterations = 2048;
  static const int _pbkdf2KeyBits = 512;

  /// Mapping from word to its index in the wordlist.
  static final Map<String, int> _wordIndex = {
    for (var i = 0; i < bip39EnglishWordlist.length; i++)
      bip39EnglishWordlist[i]: i,
  };

  /// Generates a BIP-39 mnemonic phrase of [strength] bits (128 or 256).
  ///
  /// Default strength is 128 bits, producing a 12-word mnemonic.
  static String generateMnemonic({int strength = 128}) {
    if (strength != 128 && strength != 256) {
      throw ArgumentError('strength must be 128 or 256');
    }

    final entropyBytes = Uint8List(strength ~/ 8);
    final random = Random.secure();
    for (var i = 0; i < entropyBytes.length; i++) {
      entropyBytes[i] = random.nextInt(256);
    }

    return entropyToMnemonic(entropyBytes).join(' ');
  }

  /// Validates a BIP-39 mnemonic phrase (wordlist membership + checksum).
  static bool isValidMnemonic(String mnemonic) {
    final words = mnemonic.trim().split(RegExp(r'\s+'));
    if (words.isEmpty || words.any((w) => w.isEmpty)) {
      return false;
    }
    if (words.length % 3 != 0 || words.length < 3 || words.length > 24) {
      return false;
    }

    try {
      final entropy = mnemonicToEntropy(words);
      final regenerated = entropyToMnemonic(entropy);
      return regenerated.length == words.length &&
          regenerated.asMap().entries.every(
            (e) => e.value == words[e.key],
          );
    } on ArgumentError {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Converts a list of BIP-39 words to entropy bytes (checksum verified).
  static Uint8List mnemonicToEntropy(List<String> words) {
    final wordCount = words.length;
    if (wordCount % 3 != 0 || wordCount < 3 || wordCount > 24) {
      throw ArgumentError('Invalid word count: $wordCount');
    }

    final checksumBits = wordCount ~/ 3;
    final totalBits = wordCount * _entropyBitsPerWord;
    final entropyBits = totalBits - checksumBits;

    // Read all bits from words into a flat bit list.
    final allBits = <bool>[];
    for (final word in words) {
      final index = _wordIndex[word];
      if (index == null) {
        throw ArgumentError('Unknown word: $word');
      }
      for (var b = 10; b >= 0; b--) {
        allBits.add((index >> b) & 1 == 1);
      }
    }

    // Split into entropy + checksum.
    final entropyBitsList = allBits.sublist(0, entropyBits);
    final checksumBitsList = allBits.sublist(entropyBits);

    // Convert entropy bits to bytes.
    final entropyBytes = Uint8List(entropyBits ~/ 8);
    for (var i = 0; i < entropyBits; i++) {
      if (entropyBitsList[i]) {
        final byteIdx = i ~/ 8;
        final bitOffset = 7 - (i % 8);
        entropyBytes[byteIdx] |= (1 << bitOffset);
      }
    }

    // Verify checksum: first checksumBits bits of SHA-256(entropy).
    final hash = _sha256(entropyBytes);
    final expectedChecksum = _readBits(hash, 0, checksumBits);
    final actualChecksum = _bitsToInt(checksumBitsList);
    if (expectedChecksum != actualChecksum) {
      throw ArgumentError('Invalid mnemonic checksum');
    }

    return entropyBytes;
  }

  /// Converts entropy bytes to a list of BIP-39 words (checksum appended).
  static List<String> entropyToMnemonic(Uint8List entropy) {
    final entropyBits = entropy.length * 8;
    final checksumBits = entropyBits ~/ 32;
    final totalBits = entropyBits + checksumBits;

    if (totalBits % _entropyBitsPerWord != 0) {
      throw ArgumentError('Invalid entropy length: ${entropy.length} bytes');
    }

    // Compute checksum.
    final hash = _sha256(entropy);
    final checksum = _readBits(hash, 0, checksumBits);

    // Build bit stream: entropy bits followed by checksum bits.
    final allBits = <bool>[];
    for (var i = 0; i < entropyBits; i++) {
      final byteIdx = i ~/ 8;
      final bitOffset = 7 - (i % 8);
      allBits.add((entropy[byteIdx] >> bitOffset) & 1 == 1);
    }
    for (var i = 0; i < checksumBits; i++) {
      allBits.add((checksum >> (checksumBits - 1 - i)) & 1 == 1);
    }

    // Split into 11-bit groups and map to words.
    final words = <String>[];
    for (var i = 0; i < totalBits; i += _entropyBitsPerWord) {
      var index = 0;
      for (var b = 0; b < _entropyBitsPerWord; b++) {
        if (allBits[i + b]) {
          index |= (1 << (_entropyBitsPerWord - 1 - b));
        }
      }
      words.add(bip39EnglishWordlist[index]);
    }

    return words;
  }

  /// Derives a 512-bit BIP-39 seed from a mnemonic phrase via
  /// PBKDF2-HMAC-SHA-512 (2048 iterations, salt = "mnemonic" + passphrase).
  static Future<Uint8List> mnemonicToSeed(
    String mnemonic, {
    String passphrase = '',
  }) async {
    // Dart стандартная библиотека не предоставляет Unicode нормализации (NFKD).
    // Чтобы избежать различных семян для одной и той же парольной фразы в
    // разных представлениях (NFC/NFD), не-ASCII парольные фразы отклоняются.
    // См. DESIGN.md §NFKD.
    final passphraseBytes = utf8.encode(passphrase);
    if (passphraseBytes.any((b) => b > 0x7f)) {
      throw ArgumentError('Non-ASCII passphrase is not supported');
    }

    final password = Uint8List.fromList(utf8.encode(mnemonic));
    final salt = Uint8List.fromList(utf8.encode('mnemonic$passphrase'));

    final pbkdf2 = CryptoProvider.instance.pbkdf2(
      macAlgorithm: CryptoProvider.instance.hmac(CryptoProvider.instance.sha512),
      iterations: _pbkdf2Iterations,
      bits: _pbkdf2KeyBits,
    );
    final key = await pbkdf2.deriveKey(
      secretKey: crypto_pkg.SecretKey(password),
      nonce: salt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  static List<int> _sha256(List<int> data) {
    // SHA-256 initial hash values (first 32 bits of fractional parts of
    // cube roots of first 8 primes 2..19).
    var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
    var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;

    // Round constants (first 32 bits of fractional parts of cube roots of
    // first 64 primes 2..311).
    const k = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
      0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
      0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
      0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
      0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
      0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    // Pre-processing: padding.
    final bitLen = data.length * 8;
    final padded = List<int>.from(data)..add(0x80);
    while ((padded.length * 8 + 64) % 512 != 0) {
      padded.add(0);
    }
    // Append original length as 64-bit big-endian.
    for (var i = 56; i >= 0; i -= 8) {
      padded.add((bitLen >> i) & 0xff);
    }

    int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

    // Process 512-bit chunks.
    for (var chunkOffset = 0; chunkOffset < padded.length; chunkOffset += 64) {
      final w = List<int>.filled(64, 0);
      for (var i = 0; i < 16; i++) {
        w[i] = (padded[chunkOffset + i * 4] << 24) |
            (padded[chunkOffset + i * 4 + 1] << 16) |
            (padded[chunkOffset + i * 4 + 2] << 8) |
            padded[chunkOffset + i * 4 + 3];
      }
      for (var i = 16; i < 64; i++) {
        final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
      }

      var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, hh = h7;
      for (var i = 0; i < 64; i++) {
        final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        final ch = (e & f) ^ (~e & g);
        final temp1 = (hh + s1 + ch + k[i] + w[i]) & 0xffffffff;
        final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (s0 + maj) & 0xffffffff;
        hh = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }

      h0 = (h0 + a) & 0xffffffff;
      h1 = (h1 + b) & 0xffffffff;
      h2 = (h2 + c) & 0xffffffff;
      h3 = (h3 + d) & 0xffffffff;
      h4 = (h4 + e) & 0xffffffff;
      h5 = (h5 + f) & 0xffffffff;
      h6 = (h6 + g) & 0xffffffff;
      h7 = (h7 + hh) & 0xffffffff;
    }

    final result = <int>[];
    for (final v in [h0, h1, h2, h3, h4, h5, h6, h7]) {
      result.add((v >> 24) & 0xff);
      result.add((v >> 16) & 0xff);
      result.add((v >> 8) & 0xff);
      result.add(v & 0xff);
    }
    return result;
  }

  static int _readBits(List<int> data, int offset, int count) {
    var result = 0;
    for (var i = 0; i < count; i++) {
      final bitPos = offset + i;
      final byteIdx = bitPos ~/ 8;
      final bitOffset = 7 - (bitPos % 8);
      if ((data[byteIdx] >> bitOffset) & 1 == 1) {
        result |= (1 << (count - 1 - i));
      }
    }
    return result;
  }

  static int _bitsToInt(List<bool> bits) {
    var result = 0;
    for (var i = 0; i < bits.length; i++) {
      if (bits[i]) {
        result |= (1 << (bits.length - 1 - i));
      }
    }
    return result;
  }
}
