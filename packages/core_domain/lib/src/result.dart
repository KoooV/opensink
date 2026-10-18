// Result<T, E> — замена исключениям в доменной логике.
// Используется для всех операций, которые могут завершиться ошибкой бизнеса
// (ошибки валидации, дублирование события, отсутствие прав и т.п.).
// Unexpected (инфраструктурные) ошибки — это исключения, они не попадают в Result.

sealed class Result<T, E> {
  const Result();

  bool get isOk => this is Ok<T, E>;
  bool get isErr => this is Err<T, E>;

  T unwrap() {
    if (this is Ok<T, E>) return (this as Ok<T, E>).value;
    throw StateError('Called unwrap on an Err: $this');
  }

  E unwrapErr() {
    if (this is Err<T, E>) return (this as Err<T, E>).error;
    throw StateError('Called unwrapErr on an Ok: $this');
  }

  R when<R>({
    required R Ok(T value),
    required R Err(E error),
  }) {
    if (this is Ok<T, E>) return Ok((this as Ok<T, E>).value);
    return Err((this as Err<T, E>).error);
  }

  R? mapOrElse<R>(R Function(T) ok, R Function(E) err) => when(ok: ok, err: err);
}

class Ok<T, E> extends Result<T, E> {
  const Ok(this.value);
  final T value;
  @override
  String toString() => 'Ok($value)';
}

class Err<T, E> extends Result<T, E> {
  const Err(this.error);
  final E error;
  @override
  String toString() => 'Err($error)';
}
