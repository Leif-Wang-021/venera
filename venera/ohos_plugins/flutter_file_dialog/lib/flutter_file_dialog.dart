class LoadFileDialogParams {
  final List<String> fileFilter;
  final String? fileName;

  const LoadFileDialogParams({this.fileFilter = const [], this.fileName});
}

class SaveFileDialogParams {
  final String sourceFilePath;
  final String? fileName;
  final String? localDirectory;

  const SaveFileDialogParams(
      {required this.sourceFilePath, this.fileName, this.localDirectory});
}

class FlutterFileDialog {
  static Future<String?> saveFile({required SaveFileDialogParams params}) async {
    throw UnsupportedError('FlutterFileDialog.saveFile is not supported on OHOS yet');
  }

  static Future<String?> loadFile({required LoadFileDialogParams params}) async {
    throw UnsupportedError('FlutterFileDialog.loadFile is not supported on OHOS yet');
  }
}
