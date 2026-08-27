import 'dart:async';

class AppLinks {
  final Stream<Uri> uriLinkStream = const Stream.empty();

  Stream<Uri> get allUriLinkStream => const Stream.empty();

  Future<Uri?> getInitialLink() async => null;

  Future<Uri?> getLatestLink() async => null;
}
