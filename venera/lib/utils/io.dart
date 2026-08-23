import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/ext.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart' as s;
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:venera/utils/file_type.dart';

export 'dart:io';
export 'dart:typed_data';

class IO {
  /// A global flag used to indicate whether the app is selecting files.
  ///
  /// Select file and other similar file operations will launch external programs,
  /// causing the app to lose focus. AppLifecycleState will be set to paused.
  static bool get isSelectingFiles => _isSelectingFiles;

  static bool _isSelectingFiles = false;
}

class FilePath {
  const FilePath._();

  static String join(String path1, String path2,
      [String? path3, String? path4, String? path5]) {
    return p.join(path1, path2, path3, path4, path5);
  }
}

extension FileSystemEntityExt on FileSystemEntity {
  /// Get the base name of the file or directory.
  String get name {
    return p.basename(path);
  }

  /// Delete the file or directory and ignore errors.
  Future<void> deleteIgnoreError({bool recursive = false}) async {
    try {
      await delete(recursive: recursive);
    } catch (e) {
      // ignore
    }
  }

  /// Delete the file or directory if it exists.
  Future<void> deleteIfExists({bool recursive = false}) async {
    if (existsSync()) {
      await delete(recursive: recursive);
    }
  }

  /// Delete the file or directory if it exists.
  void deleteIfExistsSync({bool recursive = false}) {
    if (existsSync()) {
      deleteSync(recursive: recursive);
    }
  }
}

extension FileExtension on File {
  /// Get the file extension, not including the dot.
  String get extension => path.split('.').last;

  /// Copy the file to the specified path using memory.
  ///
  /// This method prevents errors caused by files from different file systems.
  Future<void> copyMem(String newPath) async {
    var newFile = File(newPath);
    // Stream is not usable since [AndroidFile] does not support [openRead].
    await newFile.writeAsBytes(await readAsBytes());
  }

  /// Get the base name of the file without the extension.
  String get basenameWithoutExt {
    return p.basenameWithoutExtension(path);
  }
}

extension DirectoryExtension on Directory {
  /// Calculate the size of the directory.
  Future<int> get size async {
    if (!existsSync()) return 0;
    int total = 0;
    for (var f in listSync(recursive: true)) {
      if (FileSystemEntity.typeSync(f.path) == FileSystemEntityType.file) {
        total += await File(f.path).length();
      }
    }
    return total;
  }

  /// Change the base name of the directory.
  Directory renameX(String newName) {
    newName = sanitizeFileName(newName);
    return renameSync(path.replaceLast(name, newName));
  }

  File joinFile(String name) {
    return File(FilePath.join(path, name));
  }

  /// Delete the contents of the directory.
  void deleteContentsSync({recursive = true}) {
    if (!existsSync()) return;
    for (var f in listSync()) {
      f.deleteIfExistsSync(recursive: recursive);
    }
  }

  /// Delete the contents of the directory.
  Future<void> deleteContents({recursive = true}) async {
    if (!existsSync()) return;
    for (var f in listSync()) {
      await f.deleteIfExists(recursive: recursive);
    }
  }

  /// Create the directory. If the directory already exists, delete it first.
  void forceCreateSync() {
    if (existsSync()) {
      deleteSync(recursive: true);
    }
    createSync(recursive: true);
  }
}

/// Sanitize the file name. Remove invalid characters and trim the file name.
String sanitizeFileName(String fileName, {String? dir, int? maxLength}) {
  while (fileName.endsWith('.')) {
    fileName = fileName.substring(0, fileName.length - 1);
  }
  var length = maxLength ?? 255;
  if (dir != null) {
    if (!dir.endsWith('/') && !dir.endsWith('\\')) {
      dir = "$dir/";
    }
    length -= dir.length;
  }
  final invalidChars = RegExp(r'[<>:"/\\|?*]');
  final sanitizedFileName = fileName.replaceAll(invalidChars, ' ');
  var trimmedFileName = sanitizedFileName.trim();
  if (trimmedFileName.isEmpty) {
    throw Exception('Invalid File Name: Empty length.');
  }
  if (length <= 0) {
    throw Exception('Invalid File Name: Max length is less than 0.');
  }
  if (trimmedFileName.length > length) {
    trimmedFileName = trimmedFileName.substring(0, length);
  }
  return trimmedFileName;
}

/// Copy the **contents** of the source directory to the destination directory.
Future<void> copyDirectory(Directory source, Directory destination) async {
  List<FileSystemEntity> contents = source.listSync();
  for (FileSystemEntity content in contents) {
    String newPath = FilePath.join(destination.path, content.name);

    if (content is File) {
      var resultFile = File(newPath);
      resultFile.createSync();
      var data = content.readAsBytesSync();
      resultFile.writeAsBytesSync(data);
    } else if (content is Directory) {
      Directory newDirectory = Directory(newPath);
      newDirectory.createSync();
      copyDirectory(content.absolute, newDirectory.absolute);
    }
  }
}

/// Copy the **contents** of the source directory to the destination directory.
/// This function is executed in an isolate to prevent the UI from freezing.
Future<void> copyDirectoryIsolate(
    Directory source, Directory destination) async {
  await Isolate.run(() => overrideIO(() => copyDirectory(source, destination)));
}

String findValidDirectoryName(String path, String directory) {
  var name = sanitizeFileName(directory);
  var dir = Directory("$path/$name");
  var i = 1;
  while (dir.existsSync() && dir.listSync().isNotEmpty) {
    name = sanitizeFileName("$directory($i)");
    dir = Directory("$path/$name");
    i++;
  }
  return name;
}

class DirectoryPicker {
  /// Pick a directory.
  ///
  /// The directory may not be usable after the instance is GCed.
  DirectoryPicker();

  static final _finalizer = Finalizer<String>((path) {
    if (path.startsWith(App.cachePath)) {
      Directory(path).deleteIgnoreError();
    }
    if (App.isIOS || App.isMacOS) {
      _methodChannel.invokeMethod("stopAccessingSecurityScopedResource");
    }
  });

  static const _methodChannel = MethodChannel("venera/method_channel");

  Future<Directory?> pickDirectory({bool directAccess = false}) async {
    IO._isSelectingFiles = true;
    try {
      String? directory;
      if (App.isWindows || App.isLinux) {
        directory = await file_selector.getDirectoryPath();
      } else if (App.isAndroid) {
        directory = (await AndroidDirectory.pickDirectory())?.path;
        if (directory != null && directAccess) {
          // Native library does not have access to the directory. Copy it to cache.
          var cache = FilePath.join(App.cachePath, "selected_directory");
          if (Directory(cache).existsSync()) {
            Directory(cache).deleteSync(recursive: true);
          }
          Directory(cache).createSync();
          await copyDirectoryIsolate(Directory(directory), Directory(cache));
          directory = cache;
        }
      } else {
        // ios, macos
        directory =
            await _methodChannel.invokeMethod<String?>("getDirectoryPath");
      }
      if (directory == null) return null;
      _finalizer.attach(this, directory);
      return Directory(directory);
    } finally {
      Future.delayed(const Duration(milliseconds: 100), () {
        IO._isSelectingFiles = false;
      });
    }
  }
}

class IOSDirectoryPicker {
  static const MethodChannel _channel = MethodChannel("venera/method_channel");

  // 调用 iOS 目录选择方法
  static Future<String?> selectDirectory() async {
    IO._isSelectingFiles = true;
    try {
      final String? path = await _channel.invokeMethod('selectDirectory');
      return path;
    } catch (e) {
      // 返回报错信息
      return e.toString();
    } finally {
      Future.delayed(const Duration(milliseconds: 100), () {
        IO._isSelectingFiles = false;
      });
    }
  }
}

Future<FileSelectResult?> selectFile({required List<String> ext}) async {
  IO._isSelectingFiles = true;
  try {
    var extensions = App.isMacOS || App.isIOS ? null : ext;
    file_selector.XTypeGroup typeGroup = file_selector.XTypeGroup(
      label: 'files',
      extensions: extensions,
    );
    FileSelectResult? file;
    if (App.isAndroid) {
      const selectFileChannel = MethodChannel("venera/select_file");
      String mimeType = "*/*";
      if (ext.length == 1) {
        mimeType = FileType.fromExtension(ext[0]).mime;
        if (mimeType == "application/octet-stream") {
          mimeType = "*/*";
        }
      }
      var filePath = await selectFileChannel.invokeMethod(
        "selectFile",
        mimeType,
      );
      if (filePath == null) return null;
      file = FileSelectResult(filePath);
    } else {
      var xFile = await file_selector.openFile(
        acceptedTypeGroups: <file_selector.XTypeGroup>[typeGroup],
      );
      if (xFile == null) return null;
      file = FileSelectResult(xFile.path);
    }
    if (!ext.contains(file.path.split(".").last)) {
      App.rootContext.showMessage(
        message: "Invalid file type: ${file.path.split(".").last}",
      );
      return null;
    }
    return file;
  } finally {
    Future.delayed(const Duration(milliseconds: 100), () {
      IO._isSelectingFiles = false;
    });
  }
}

Future<String?> selectDirectory() async {
  IO._isSelectingFiles = true;
  try {
    var path = await file_selector.getDirectoryPath();
    return path;
  } finally {
    Future.delayed(const Duration(milliseconds: 100), () {
      IO._isSelectingFiles = false;
    });
  }
}

// selectDirectoryIOS
Future<String?> selectDirectoryIOS() async {
  return IOSDirectoryPicker.selectDirectory();
}

Future<void> saveFile(
    {Uint8List? data, required String filename, File? file}) async {
  if (data == null && file == null) {
    throw Exception("data and file cannot be null at the same time");
  }
  IO._isSelectingFiles = true;
  try {
    if (data != null) {
      var cache = FilePath.join(App.cachePath, filename);
      if (File(cache).existsSync()) {
        File(cache).deleteSync();
      }
      await File(cache).writeAsBytes(data);
      file = File(cache);
    }
    if (App.isMobile) {
      final params = SaveFileDialogParams(sourceFilePath: file!.path);
      await FlutterFileDialog.saveFile(params: params);
    } else if (App.isWindows) {
      // Custom in-app save dialog. The native Windows file dialog can load
      // third-party shell extensions (Baidu Netdisk / OneDrive ...), which may
      // throw RPC_S_SERVER_UNAVAILABLE (0x6BA) and cause the app to exit.
      await saveFileOnWindows(file!, filename);
    } else {
      final result = await file_selector.getSaveLocation(
        suggestedName: filename,
      );
      if (result != null) {
        var xFile = file_selector.XFile(file!.path);
        await xFile.saveTo(result.path);
      }
    }
  } finally {
    Future.delayed(const Duration(milliseconds: 100), () {
      IO._isSelectingFiles = false;
    });
  }
}

/// Saves [file] on Windows using the native Explorer save dialog, but running
/// the dialog in a separate PowerShell process so third-party shell-extension
/// failures (e.g. Baidu Netdisk / OneDrive RPC 0x6BA) cannot crash Venera.
/// If the native dialog cannot be used, falls back to the in-app dialog.
Future<void> saveFileOnWindows(File file, String filename) async {
  var dest = await _pickNativeWindowsSavePath(filename);
  if (dest == null || dest.isEmpty) {
    dest = await showWindowsSaveDialog(filename);
  }
  if (dest == null || dest.isEmpty) {
    return;
  }
  if (!p.isAbsolute(dest)) {
    var home = Platform.environment['USERPROFILE'] ?? '';
    dest = p.join(home, 'Documents', p.basename(dest));
  }
  try {
    await file.copy(dest);
  } catch (e) {
    App.rootContext.showMessage(message: e.toString());
  }
}

/// Picks a save path using a native Windows SaveFileDialog inside an isolated
/// PowerShell process. Returns null when cancelled or the helper fails.
Future<String?> _pickNativeWindowsSavePath(String filename) async {
  File? out;
  try {
    out = File(p.join(Directory.systemTemp.path, 'venera_save_path.txt'));
    if (out.existsSync()) {
      out.deleteSync();
    }
    final safeName = filename.replaceAll("'", "''");
    final script = '''
Add-Type -AssemblyName System.Windows.Forms
\$out = '${out.path.replaceAll("'", "''")}'
\$dlg = New-Object System.Windows.Forms.SaveFileDialog
\$dlg.FileName = '$safeName'
\$dlg.Filter = 'All files (*.*)|*.*'
\$dlg.OverwritePrompt = \$true
\$dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
if (\$dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  \$dlg.FileName | Out-File -FilePath \$out -Encoding ASCII
} else {
  'CANCEL' | Out-File -FilePath \$out -Encoding ASCII
}
''';
    final b64 = base64Encode(utf8.encode(script));
    // Use the absolute path so the packaged app does not depend on PATH.
    const psExe = r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';
    final exe = File(psExe).existsSync() ? psExe : 'powershell.exe';
    final res = await Process.run(exe, [
      '-NoProfile',
      '-STA',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      b64,
    ]);
    Log.info(
        'SaveDialogHelper exit=${res.exitCode} stdout=${res.stdout.toString().trim().isEmpty ? '<empty>' : res.stdout.toString().trim()} stderr=${res.stderr.toString().trim()}');
    if (res.exitCode == 0 && out.existsSync()) {
      var content = (await out.readAsString()).trim();
      out.deleteSync();
      if (content.isNotEmpty && content != 'CANCEL') {
        return content;
      }
      Log.info('SaveDialogHelper cancelled or empty output');
    } else {
      Log.error('SaveDialogHelper failed',
          'exit=${res.exitCode} outputExists=${out.existsSync()}');
    }
  } catch (e, s) {
    Log.error('SaveDialogHelper exception', e, s);
  }
  return null;
}

/// Shows a simple in-app "Save As" dialog and returns the chosen path.
Future<String?> showWindowsSaveDialog(String filename) async {
  final userProfile = Platform.environment['USERPROFILE'] ?? '';
  final defaultPath =
      userProfile.isNotEmpty ? p.join(userProfile, 'Documents', filename) : filename;
  final controller = TextEditingController(text: defaultPath);
  String? result;
  await showDialog<void>(
    context: App.rootContext,
    builder: (ctx) => AlertDialog(
      title: const Text('Save As'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Enter full path to save the file',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) {
            result = v;
            Navigator.of(ctx).pop();
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            result = controller.text;
            Navigator.of(ctx).pop();
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

final class _IOOverrides extends IOOverrides {
  @override
  Directory createDirectory(String path) {
    if (App.isAndroid) {
      var dir = AndroidDirectory.fromPathSync(path);
      if (dir == null) {
        return super.createDirectory(path);
      }
      return dir;
    } else {
      return super.createDirectory(path);
    }
  }

  @override
  File createFile(String path) {
    if (path.startsWith("file://")) {
      path = path.substring(7);
    }
    if (App.isAndroid) {
      var f = AndroidFile.fromPathSync(path);
      if (f == null) {
        return super.createFile(path);
      }
      return f;
    } else {
      return super.createFile(path);
    }
  }
}

T overrideIO<T>(T Function() f) {
  return IOOverrides.runWithIOOverrides<T>(
    f,
    _IOOverrides(),
  );
}

class Share {
  static void shareFile({
    required Uint8List data,
    required String filename,
    required String mime,
  }) {
    if (!App.isWindows) {
      s.Share.shareXFiles(
        [s.XFile.fromData(data, mimeType: mime)],
        fileNameOverrides: [filename],
      );
    } else {
      // write to cache
      var file = File(FilePath.join(App.cachePath, filename));
      file.writeAsBytesSync(data);
      s.Share.shareXFiles([s.XFile(file.path)]);
    }
  }

  static void shareText(String text) {
    s.Share.share(text);
  }
}

String bytesToReadableString(int bytes) {
  if (bytes < 1024) {
    return "$bytes B";
  } else if (bytes < 1024 * 1024) {
    return "${(bytes / 1024).toStringAsFixed(2)} KB";
  } else if (bytes < 1024 * 1024 * 1024) {
    return "${(bytes / 1024 / 1024).toStringAsFixed(2)} MB";
  } else {
    return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }
}

class FileSelectResult {
  final String path;

  static final _finalizer = Finalizer<String>((path) {
    if (path.startsWith(App.cachePath)) {
      File(path).deleteIgnoreError();
    }
  });

  FileSelectResult(this.path) {
    _finalizer.attach(this, path);
  }

  Future<void> saveTo(String path) async {
    await File(this.path).copy(path);
  }

  Future<Uint8List> readAsBytes() {
    return File(path).readAsBytes();
  }

  String get name => File(path).name;
}
