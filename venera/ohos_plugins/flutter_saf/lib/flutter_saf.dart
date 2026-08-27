import 'dart:io';

class SAFTaskWorker {
  static final SAFTaskWorker _instance = SAFTaskWorker._();

  SAFTaskWorker._();

  factory SAFTaskWorker() => _instance;

  Future<void> init() async {}
}

class AndroidDirectory implements Directory {
  AndroidDirectory._();

  static Future<AndroidDirectory?> pickDirectory() async => null;

  static AndroidDirectory? fromPathSync(String path) => null;

  @override
  String get path => '';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('SAF directories are not supported on OHOS');
}

class AndroidFile implements File {
  AndroidFile._();

  static AndroidFile? fromPathSync(String path) => null;

  @override
  String get path => '';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('SAF files are not supported on OHOS');
}
