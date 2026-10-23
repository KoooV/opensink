/// Ошибки peer-слоя, которые не являются бизнес-результатом Result.
///
/// В доменной логике используется Result; здесь — инфраструктурные сбои,
/// поэтому исключения допустимы.
sealed class PeerException implements Exception {
  const PeerException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

class PeerCapacityExceeded extends PeerException {
  const PeerCapacityExceeded(int limit)
    : super('connection limit reached ($limit)');
}

class PeerConnectTimeout extends PeerException {
  const PeerConnectTimeout() : super('peer connection timeout');
}

class PeerSignalingError extends PeerException {
  const PeerSignalingError(super.message);
}

class PeerClosed extends PeerException {
  const PeerClosed() : super('peer link is closed');
}

class PeerChannelUnavailable extends PeerException {
  const PeerChannelUnavailable(String channel)
    : super('data channel is unavailable: $channel');
}
