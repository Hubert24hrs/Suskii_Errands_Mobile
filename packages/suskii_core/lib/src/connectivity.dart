/// Connectivity status abstraction. A connectivity_plus-backed implementation
/// plugs in at the app layer; mocks and tests drive this directly.
enum ConnectivityStatus { online, offline }

abstract interface class ConnectivityWatcher {
  Stream<ConnectivityStatus> watch();
  Future<ConnectivityStatus> current();
}
