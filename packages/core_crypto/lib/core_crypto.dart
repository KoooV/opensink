library core_crypto;

export 'src/identity.dart';
export 'src/signer.dart';
// SecureKeyStore и IdentityBundle живут в core_domain; core_crypto не дублирует
// контракт, а использует его через package:core_domain.
