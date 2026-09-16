/// Success/failure result for repository calls that should not throw.
sealed class Result<T> {
  const Result();

  R when<R>({
    required R Function(T value) ok,
    required R Function(AppErrorView error) err,
  }) {
    final self = this;
    return switch (self) {
      Ok<T>() => ok(self.value),
      Err<T>() => err(self.error),
    };
  }
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);
  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.error);
  final AppErrorView error;
}

/// Lightweight view of an error to avoid a package cycle with errors.dart
/// being unnecessary — holds the stable code and localization key.
class AppErrorView {
  const AppErrorView(this.code, {this.messageKey});

  final String code;
  final String? messageKey;

  @override
  String toString() => 'AppErrorView($code)';
}
